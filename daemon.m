// wcvoicekeep daemon — 2.0.0「后台保活」
//
// 职责（老板 2026-11-06 定案）：
//   1) 键盘扩展 wxkb_plugin —— **必须保活**（不可关闭）。它一退出，立刻请 SpringBoard 弹一下键盘
//      把系统重新 spawn 出来（系统只认真实键盘请求，无其它后门）。
//   2) 用户在设置里勾选的任意 App —— 被杀后在**后台**无头拉起（SBSLaunchApplicationWithIdentifier
//      flag=Background，完全不切前台）。
//   3) 每次拉起都写一条**记录**（纯净版/日志版都写），设置页「拉起记录」里可查。
//
// 事件驱动（老板明确要求，零轮询）：
//   进程退出用内核事件 DISPATCH_SOURCE_TYPE_PROC + DISPATCH_PROC_EXIT 监听，
//   目标进程一死内核立刻回调，我们才动作；平时 CPU 开销为 0，不采样、不定时器扫描。
//   只监听"勾选的目标"，其它进程一概不碰 —— 这就是"精准命中"。
//
// 2.0.0 删除：微信输入法主程序（com.tencent.wetype）PiP 保活/前台预热/僵尸判定整套。

#import <Foundation/Foundation.h>
#import <MobileCoreServices/MobileCoreServices.h>
#import <objc/message.h>
#include <sys/sysctl.h>
#include <sys/stat.h>
// iOS SDK 没有 macOS 的 libproc.h —— 只声明用到的两个 libproc 函数（iOS 上在 libSystem 里）
#include <stdint.h>
#ifndef PROC_PIDPATHINFO_MAXSIZE
#define PROC_PIDPATHINFO_MAXSIZE 4096
#endif
// .xm 按 ObjC++ 编译，C 函数必须 extern "C"，否则链接期符号带 C++ 修饰找不到
#ifdef __cplusplus
extern "C" {
#endif
extern int proc_listallpids(void *buffer, int buffersize);
extern int proc_pidpath(int pid, void *buffer, uint32_t buffersize);
#ifdef __cplusplus
}
#endif

#include <dlfcn.h>
#include <dispatch/dispatch.h>
#include <notify.h>
#include <fcntl.h>
#include <unistd.h>
#include <string.h>
#include <time.h>
#include <stdlib.h>
#include <stdio.h>

// ===== 日志（纯净版编译期整体剥离；记录不走这里，纯净版照样写）=====
#ifndef WCVK_NO_LOG
#define WCVK_NO_LOG 0
#endif

static NSString *const kLogPath     = @"/var/mobile/wcvoicekeep.daemon.log";
static NSString *const kPrefsDomain = @"com.wcvoicekeep.bgkeep";
static NSString *const kRecordsName = @"com.wcvoicekeep.bgkeep.records.plist";

#if WCVK_NO_LOG
#define LOG(...) do {} while (0)
#else
static void LOG(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSDictionary *attr = [[NSFileManager defaultManager] attributesOfItemAtPath:kLogPath error:nil];
    if ([attr[NSFileSize] unsignedLongLongValue] > 2 * 1024 * 1024) {
        [[NSFileManager defaultManager] removeItemAtPath:kLogPath error:nil];
    }
    NSString *line = [NSString stringWithFormat:@"[%@][daemon] %@\n", [NSDate date], msg];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:kLogPath];
    if (!fh) {
        [line writeToFile:kLogPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
        fh = [NSFileHandle fileHandleForWritingAtPath:kLogPath];
        if (!fh) return;
    }
    @try {
        [fh seekToEndOfFile];
        [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [fh closeFile];
    } @catch (NSException *e) {}
}
#endif

// ===== 越狱根定位（roothide 隐根：不硬编码，靠自身路径反推）=====
static NSString *WCVKJbroot(void) {
    static NSString *root = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Dl_info info;
        if (dladdr((void *)&WCVKJbroot, &info) && info.dli_fname) {
            NSString *self = [NSString stringWithUTF8String:info.dli_fname];
            NSRange r = [self rangeOfString:@"/usr/bin/"];
            if (r.location != NSNotFound) root = [self substringToIndex:r.location];
        }
        if (!root) root = @"";
    });
    return root;
}

// prefs / 记录候选路径：roothide 下设置进程把 plist 写进隐根内部，daemon 视角可能不同，
// 因此几个候选都试，取"真实存在且更新"的那份（NIP 项目实测教训：suiteName 通道读不到）。
static NSArray<NSString *> *WCVKPrefsDirCandidates(void) {
    NSString *jb = WCVKJbroot();
    NSMutableArray *a = [NSMutableArray array];
    if (jb.length) [a addObject:[jb stringByAppendingString:@"/var/mobile/Library/Preferences"]];
    [a addObject:@"/var/mobile/Library/Preferences"];
    if (![jb isEqualToString:@"/rootfs"]) [a addObject:@"/rootfs/private/var/mobile/Library/Preferences"];
    return a;
}

static NSString *gPrefsDirCached = nil;

static NSString *WCVKExistingPrefsDir(void) {
    if (gPrefsDirCached) return gPrefsDirCached;
    NSString *best = nil;
    double bestM = -1;
    for (NSString *dir in WCVKPrefsDirCandidates()) {
        NSString *p = [dir stringByAppendingFormat:@"/%@.plist", kPrefsDomain];
        NSDictionary *attr = [[NSFileManager defaultManager] attributesOfItemAtPath:p error:nil];
        if (!attr) continue;
        double m = [attr[NSFileModificationDate] timeIntervalSince1970];
        if (m > bestM) { bestM = m; best = dir; }
    }
    if (!best) best = WCVKPrefsDirCandidates().firstObject;
    gPrefsDirCached = best;
    return gPrefsDirCached;
}

static NSString *WCVKPrefsPath(void) {
    return [WCVKExistingPrefsDir() stringByAppendingFormat:@"/%@.plist", kPrefsDomain];
}
static NSString *WCVKRecordsPath(void) {
    return [WCVKExistingPrefsDir() stringByAppendingFormat:@"/%@", kRecordsName];
}

// ===== 设置读取 =====
static BOOL     gEnabled = YES;   // 总开关
static BOOL     gLogging = NO;    // 日志开关（日志版才有实际作用）
static BOOL     gRecord  = YES;   // 拉起记录开关：关掉后**完全不写**记录（零写入零开销）
static NSArray *gAppBIDs = nil;   // 用户勾选的 App bundle id 数组

// v2.0.5：返回「值是否有变化」。
// 原因：com.apple.preferences-changed 是**系统级**广播，任何 App 改任何偏好都会打过来，
// 以前每来一次就重读 + 全量重建目标（其中还要逐个 bid 走一遍 LaunchServices 解析），
// 白干活。现在值没变就直接跳过，系统里别人改设置跟我们无关。
static BOOL WCVKReadPrefs(void) {
    BOOL    oldEnabled = gEnabled, oldLogging = gLogging, oldRecord = gRecord;
    NSArray *oldBIDs   = gAppBIDs;
    NSString *p = WCVKPrefsPath();

    // v2.0.2：**优先走 CFPreferences（cfprefsd）读，而不是直读文件**。
    // 原因：设置 App 的开关是写到 cfprefsd 的，cfprefsd 有延迟 flush，磁盘上的 plist
    // 可能还是旧的 —— 这就是老板实测「勾了要注销一次才生效」。CFPreferences 读的是
    // cfprefsd 里的最新内存值，改完立刻可见。
    id en = (__bridge_transfer id)CFPreferencesCopyValue(CFSTR("enabled"),
              (__bridge CFStringRef)kPrefsDomain, kCFPreferencesAnyUser, kCFPreferencesAnyHost);
    id lg = (__bridge_transfer id)CFPreferencesCopyValue(CFSTR("logging"),
              (__bridge CFStringRef)kPrefsDomain, kCFPreferencesAnyUser, kCFPreferencesAnyHost);
    id rec = (__bridge_transfer id)CFPreferencesCopyValue(CFSTR("record"),
              (__bridge CFStringRef)kPrefsDomain, kCFPreferencesAnyUser, kCFPreferencesAnyHost);
    id apps = (__bridge_transfer id)CFPreferencesCopyValue(CFSTR("enabledApps"),
              (__bridge CFStringRef)kPrefsDomain, kCFPreferencesAnyUser, kCFPreferencesAnyHost);

    BOOL viaCF = (en || rec || apps);
    if (!viaCF) {
        // 兜底：cfprefsd 拿不到（域完全没建）时读文件
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:p];
        if (!d) {
            for (NSString *dir in WCVKPrefsDirCandidates()) {
                NSDictionary *t = [NSDictionary dictionaryWithContentsOfFile:
                                   [dir stringByAppendingFormat:@"/%@.plist", kPrefsDomain]];
                if (t) { d = t; break; }
            }
        }
        en = d[@"enabled"]; lg = d[@"logging"]; rec = d[@"record"]; apps = d[@"enabledApps"];
    }

    gEnabled = en ? [en boolValue] : YES;
    gLogging = lg ? [lg boolValue] : NO;
    gRecord = rec ? [rec boolValue] : YES;

    NSMutableArray *bids = [NSMutableArray array];
    if ([apps isKindOfClass:[NSArray class]]) {
        for (id b in apps) {
            if ([b isKindOfClass:[NSString class]] && [b length] && ![bids containsObject:b])
                [bids addObject:b];
        }
    }
    gAppBIDs = bids;
    BOOL changed = (oldEnabled != gEnabled) || (oldLogging != gLogging) || (oldRecord != gRecord)
                   || ![oldBIDs isEqualToArray:gAppBIDs];
    LOG(@"prefs loaded (%s): enabled=%d logging=%d apps=%@ changed=%d",
        viaCF ? "cfprefs" : "file", gEnabled, gLogging, gAppBIDs, changed);
    return changed;
}

// ===== 拉起记录（纯净版也写；设置页「拉起记录」读它）=====
// 读取记录（兼容新格式 dict{rows:[...]} 与 v2.0.0 的旧格式 顶层数组）
static NSMutableArray *WCVKLoadRecords(NSString *path) {
    id o = [NSDictionary dictionaryWithContentsOfFile:path];
    if ([o isKindOfClass:[NSDictionary class]] && [o[@"rows"] isKindOfClass:[NSArray class]])
        return [o[@"rows"] mutableCopy];
    o = [NSArray arrayWithContentsOfFile:path];
    if ([o isKindOfClass:[NSArray class]]) return [o mutableCopy];
    return [NSMutableArray array];
}

static void WCVKRecord(NSString *display, NSString *ident, NSString *kind, BOOL ok, NSString *detail) {
    // 记录开关关掉时**直接返回**：不读文件、不写文件，零 syscall、零 CPU
    if (!gRecord) return;
    NSString *path = WCVKRecordsPath();
    NSMutableArray *arr = WCVKLoadRecords(path);
    NSMutableDictionary *row = [NSMutableDictionary dictionary];
    row[@"t"] = [NSDate date];
    row[@"name"] = display ?: ident ?: @"?";
    row[@"bid"] = ident ?: @"";
    row[@"kind"] = kind ?: @"app";
    row[@"ok"] = @(ok);
    if (detail.length) row[@"detail"] = detail;
    [arr insertObject:row atIndex:0];
    // v2.0.6：上层数从 60 收到 20（老板要求）。每次记录都要把整份文件读出来再整份写回去，
    // 条数直接决定单次写盘的大小 —— 20 条大约 2KB，比原来 19KB 少 9 倍。
    while (arr.count > 20) [arr removeLastObject];
    // v2.0.1：改成 dict{rows:[...]} —— 顶层是 dict，cfprefsd 才能当域读；
    // 设置页因此可以走 CFPreferences 兜底（沙箱下直读文件可能被拦）
    NSDictionary *out = @{ @"rows": arr };
    NSString *writtenPath = path;
    BOOL wrote = [out writeToFile:path atomically:YES];
    if (!wrote) {
        NSString *alt = @"/var/mobile/wcvoicekeep.records.plist";
        wrote = [out writeToFile:alt atomically:YES];
        if (wrote) writtenPath = alt;
        LOG(@"record write fallback -> %@ (%d)", alt, wrote);
    }
    // v2.0.2：属主改成 mobile —— daemon 是 root，写出来是 root:mobile，
    // 设置页（mobile 身份）虽然能读，但「清空记录」按钮删不动 root 的文件，
    // cfprefsd 以 mobile 身份也无法把这份文件当成自己的域。统一交给 mobile。
    if (wrote) {
        // v2.0.5：fallback 路径也要 chown/chmod，以前只 chown 了 path（fallback 那份属主不对，
        // 设置页读得到但删不掉）
        // v2.0.6：先 stat 看一眼，属主/权限已经对就不再 syscall（每次记录省 2 个调用）
        struct stat sb;
        if (stat(writtenPath.fileSystemRepresentation, &sb) != 0 ||
            sb.st_uid != 501 || (sb.st_mode & 07777) != 0644) {
            chown(writtenPath.fileSystemRepresentation, 501, 501);
            chmod(writtenPath.fileSystemRepresentation, 0644);
        }
    }
}

// ===== 进程工具（精确到可执行文件路径，不靠 16 字符截断的进程名）=====
static int WCVKPidForPathSuffix(NSString *suffix, NSString *exactPath) {
    int n = proc_listallpids(NULL, 0);
    if (n <= 0) return 0;
    pid_t *pids = (pid_t *)calloc((size_t)n + 64, sizeof(pid_t));
    if (!pids) return 0;
    int cnt = proc_listallpids(pids, (int)((size_t)(n + 64) * sizeof(pid_t)));
    int found = 0;
    for (int i = 0; i < cnt; i++) {
        char path[PROC_PIDPATHINFO_MAXSIZE] = {0};
        if (proc_pidpath(pids[i], path, sizeof(path)) <= 0) continue;
        NSString *p = [NSString stringWithUTF8String:path];
        if (!p.length) continue;
        if (exactPath.length ? [p isEqualToString:exactPath] : [p hasSuffix:suffix]) {
            found = pids[i];
            break;
        }
    }
    free(pids);
    return found;
}

// v2.0.2：**按 bundle id 精确锁进程**。
//
// 为什么不再靠可执行文件路径：设备实测 com.tencent.xin 与 com.tencent.qy.xin（微信 + 企业微信）
// 解析出来的可执行路径**完全相同**（都是 /WeChat.app/WeChat），`--status` 里两个 target 显示同一
// 个 pid。路径匹配无法区分这两个 App ⇒ 企业微信的监视会挂在微信进程上（勾了等于没勾，
// 而微信被杀时会被两个 target 各拉一次）。
//
// 可靠做法：每个 App 进程的 launchd 环境变量里都有
//   XPC_SERVICE_NAME = UIKitApplication:<bundle-id>[xxxx][rb-legacy]
// 直接从进程的 argv/env 区（KERN_PROCARGS2）里精确匹配 "UIKitApplication:<bid>[" 即可，
// 与容器 UUID、可执行名、App 目录名全都无关。
#ifndef KERN_PROCARGS2
#define KERN_PROCARGS2 49
#endif

static BOOL WCVKProcHasEnv(pid_t pid, const char *needle, size_t nlen) {
    int mib[3] = { CTL_KERN, KERN_PROCARGS2, (int)pid };
    size_t size = 0;
    if (sysctl(mib, 3, NULL, &size, NULL, 0) != 0 || size == 0) return NO;
    if (size > (4u << 20)) return NO;                 // 防异常大块
    char *buf = (char *)malloc(size);
    if (!buf) return NO;
    BOOL found = NO;
    if (sysctl(mib, 3, buf, &size, NULL, 0) == 0) {
        if (size > nlen) {
            for (size_t i = 0; i + nlen <= size; i++) {
                if (buf[i] != needle[0]) continue;
                if (memcmp(buf + i, needle, nlen) == 0) { found = YES; break; }
            }
        }
    }
    free(buf);
    return found;
}

// 返回该 bundle id 对应 App 的 pid；不在运行返回 0
static int WCVKPidForBID(NSString *bid) {
    if (!bid.length) return 0;
    char needle[512];
    int n = snprintf(needle, sizeof(needle), "XPC_SERVICE_NAME=UIKitApplication:%s[",
                     bid.UTF8String);
    if (n <= 0 || (size_t)n >= sizeof(needle)) return 0;
    size_t nlen = (size_t)n;

    int total = proc_listallpids(NULL, 0);
    if (total <= 0) return 0;
    pid_t *pids = (pid_t *)calloc((size_t)total + 64, sizeof(pid_t));
    if (!pids) return 0;
    int cnt = proc_listallpids(pids, (int)((size_t)(total + 64) * sizeof(pid_t)));
    int found = 0;
    for (int i = 0; i < cnt; i++) {
        pid_t p = pids[i];
        if (p <= 1) continue;
        if (WCVKProcHasEnv(p, needle, nlen)) { found = p; break; }
    }
    free(pids);
    return found;
}

// ===== App 可执行文件 / 显示名解析（LaunchServices）=====
static void WCVKEnsureLSLoaded(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dlopen("/System/Library/Frameworks/MobileCoreServices.framework/MobileCoreServices", RTLD_LAZY);
        dlopen("/System/Library/PrivateFrameworks/LaunchServices.framework/LaunchServices", RTLD_LAZY);
    });
}

// App 代理解析：iOS 16 设备实测 `-[LSApplicationWorkspace applicationProxyForIdentifier:]`
// **不存在**（日志实证：unrecognized selector sent to instance => v2.0.0 里微信被 skip，
// 用户勾了也永远不挂监视）。真正可用的是类方法 +[LSApplicationProxy applicationProxyForIdentifier:]。
// 这里按可用性逐个试，最后用 allApplications 全量枚举兜底，任何一个能返回就够。
// 取代理上的某个字符串属性（定义在下面，WCVKLSProxyForBID 要用，先声明）
static NSString *WCVKProxyString(id proxy, NSArray<NSString *> *sels);

static id WCVKLSProxyForBID(NSString *bid) {
    WCVKEnsureLSLoaded();
    // v2.0.2：类方法可能返回**不属于该 bid** 的代理（企业微信就是这种情况），
    // 所以拿到之后必须回读它自己的 bundle id 校验，不一致就继续往下找。
    @try {
        Class P = NSClassFromString(@"LSApplicationProxy");
        if (P) {
            SEL s = sel_registerName("applicationProxyForIdentifier:");
            if ([(id)P respondsToSelector:s]) {
                id r = ((id (*)(id, SEL, id))objc_msgSend)((id)P, s, bid);
                if (r) {
                    NSString *own = WCVKProxyString(r, @[@"bundleIdentifier", @"applicationIdentifier"]);
                    if (!own.length || [own isEqualToString:bid]) return r;
                    LOG(@"LS 类方法返回的代理属于 %@，不是 %@ -> 继续找", own, bid);
                }
            }
        }
    } @catch (NSException *e) {}

    @try {
        // ② workspace 实例方法：不同版本命名不一样，逐个确认后再调（不再盲调）
        Class WS = NSClassFromString(@"LSApplicationWorkspace");
        if (WS) {
            id ws = ((id (*)(id, SEL))objc_msgSend)((id)WS, sel_registerName("defaultWorkspace"));
            if (ws) {
                for (NSString *n in @[@"applicationProxyForIdentifier:",
                                      @"applicationProxyForBundleIdentifier:",
                                      @"applicationProxyForBundleID:"]) {
                    SEL s = sel_registerName(n.UTF8String);
                    if (![ws respondsToSelector:s]) continue;
                    id r = ((id (*)(id, SEL, id))objc_msgSend)(ws, s, bid);
                    if (r) return r;
                }
                // ③ 全量枚举兜底（慢一点但只在重建目标时跑一次）
                SEL allSel = sel_registerName("allApplications");
                if ([ws respondsToSelector:allSel]) {
                    id list = ((id (*)(id, SEL))objc_msgSend)(ws, allSel);
                    if ([list isKindOfClass:[NSArray class]]) {
                        for (id pr in list) {
                            id ident = nil;
                            @try {
                                ident = ((id (*)(id, SEL))objc_msgSend)(pr,
                                        sel_registerName("applicationIdentifier"));
                            } @catch (NSException *e) {}
                            if ([ident isKindOfClass:[NSString class]] && [ident isEqualToString:bid])
                                return pr;
                        }
                    }
                }
            }
        }
    } @catch (NSException *e) {}
    return nil;
}

// 取代理上的某个字符串属性（selector 名不同版本可能变，所以给候选列表）
static NSString *WCVKProxyString(id proxy, NSArray<NSString *> *sels) {
    for (NSString *n in sels) {
        @try {
            SEL s = sel_registerName(n.UTF8String);
            if (![proxy respondsToSelector:s]) continue;
            id v = ((id (*)(id, SEL))objc_msgSend)(proxy, s);
            if ([v isKindOfClass:[NSString class]] && [v length]) return v;
        } @catch (NSException *e) {}
    }
    return nil;
}

// v2.0.5：加缓存。以前每次重建目标都要对每个 bid 走一遍 LaunchServices 解析
// （最坏情况枚举 allApplications，几十毫秒级），而显示名/路径基本不变。
// 只在解析成功时缓存；失败不缓存（App 之后装回来还能重新解析）。
static NSMutableDictionary *gMetaCache = nil;
static NSDictionary *WCVKAppMeta(NSString *bid) {
    if (!gMetaCache) gMetaCache = [NSMutableDictionary dictionary];
    NSDictionary *cached = gMetaCache[bid];
    if (cached) return cached;
    id proxy = WCVKLSProxyForBID(bid);
    if (!proxy) {
        LOG(@"AppMeta(%@) 失败：LaunchServices 未返回代理", bid);
        return nil;
    }

    NSString *exe = WCVKProxyString(proxy, @[@"bundleExecutable", @"executableName"]);
    NSString *appDir = nil;
    @try {
        SEL s = sel_registerName("bundleURL");
        if ([proxy respondsToSelector:s]) {
            NSURL *u = ((id (*)(id, SEL))objc_msgSend)(proxy, s);
            if ([u isKindOfClass:[NSURL class]]) appDir = u.lastPathComponent;
        }
    } @catch (NSException *e) {}

    NSString *name = WCVKProxyString(proxy, @[@"localizedName", @"itemName"]);
    if (!name) {
        @try {
            SEL s = sel_registerName("localizedInfoDictionary");
            if ([proxy respondsToSelector:s]) {
                NSDictionary *d2 = ((id (*)(id, SEL))objc_msgSend)(proxy, s);
                if ([d2 isKindOfClass:[NSDictionary class]])
                    name = d2[@"CFBundleDisplayName"] ?: d2[@"CFBundleName"];
            }
        } @catch (NSException *e) {}
    }

    if (![exe isKindOfClass:[NSString class]] || !exe.length ||
        ![appDir isKindOfClass:[NSString class]] || !appDir.length) {
        LOG(@"AppMeta(%@) 失败：exe=%@ appDir=%@", bid, exe, appDir);
        return nil;
    }
    LOG(@"AppMeta(%@) = %@ / %@", bid, name ?: @"?", appDir);
    NSDictionary *out = @{ @"exeSuffix": [NSString stringWithFormat:@"/%@/%@", appDir, exe],
              @"display": [name isKindOfClass:[NSString class]] && name.length ? name : bid };
    gMetaCache[bid] = out;
    return out;
}

// ===== 无头拉起（完全后台，不切前台）=====
static int (*g_SBSLaunch)(CFStringRef, int) = NULL;
static BOOL WCVKSBSReady(void) {
    static dispatch_once_t once;
    static BOOL ok = NO;
    dispatch_once(&once, ^{
        void *h = dlopen("/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices",
                         RTLD_LAZY);
        if (h) {
            g_SBSLaunch = (int (*)(CFStringRef, int))dlsym(h, "SBSLaunchApplicationWithIdentifier");
            void (*portfn)(void) = (void (*)(void))dlsym(h, "SBSSpringBoardServerPort");
            if (portfn) portfn();
            ok = (g_SBSLaunch != NULL);
        }
        LOG(@"SBS ready=%d", ok);
    });
    return ok;
}

// flag 1 = SBSApplicationLaunchFlagBackground -> 后台启动，不激活前台
static int WCVKHeadlessLaunch(NSString *bid) {
    if (!WCVKSBSReady() || !g_SBSLaunch) return -1;
    int r = g_SBSLaunch((__bridge CFStringRef)bid, 1);
    LOG(@"headless launch %@ -> %d (0=ok)", bid, r);
    return r;
}

// ===== 目标（事件驱动看护）=====
static const char *kKbdExtSuffix    = "/wxkb_plugin.appex/wxkb_plugin";
static const int  kRelaunchDelaySec = 1;     // 事件 -> 拉起前等 1s（尊重系统回收动作）
// ★ v2.0.24（老板 2026-11-07 定案）：退避机制已撤销。
//   历史：v2.0.22 为压「5.5 分钟拉起 25 次」的风暴，给 App 加了 1/5/15/60/120s 指数退避；
//   但实机感受是「daemon 半天不拉起、很多时候根本不拉」，反而不如老版本好用，测试也等不到。
//   现在恢复成纯事件驱动：任何退出事件 -> 固定 1s 立刻拉起，不做任何加长延迟。
//   短命次数只保留统计日志（kShortLifeSec 仅用于判定日志措辞）。
static const int  kShortLifeSec     = 60;
static const int  kFailCooldownSec  = 15;    // v2.0.24: 45s→15s，拉起失败(rc≠0)后也尽快重试
static const int  kKbdDebounceSec   = 3;     // 键盘扩展只防抖 3s：拉起成功后必须能立刻再拉
static const int  kArmRetrySecs[]   = {2, 5, 10, 20, 40};  // 拉起后找 pid 挂监视的重试点
// v2.0.6：连续失败熔断上限（改设置即恢复）
static const int  kFuseFailLimit    = 3;

@interface WCVKTarget : NSObject
@property (nonatomic, copy)   NSString *ident;      // bundle id 或 "wxkb_plugin"
@property (nonatomic, copy)   NSString *display;    // 显示名（写记录用）
@property (nonatomic, copy)   NSString *kind;       // @"kbd" / @"app"
@property (nonatomic, copy)   NSString *exeSuffix;  // App 精确匹配后缀
@property (nonatomic, assign) int pid;
@property (nonatomic, assign) time_t lastRelaunch;
@property (nonatomic, assign) int fails;
@property (nonatomic, assign) BOOL disabled;     // v2.0.6：连续失败熔断，摘掉不再看护
@property (nonatomic, assign) time_t armedAt;    // v2.0.22：本次挂上监视（=进程被发现）的时间
@property (nonatomic, assign) int shortLives;    // v2.0.22：连续「短命退出」次数（存活 < kShortLifeSec）
@property (nonatomic, strong) dispatch_source_t src;
@end

@implementation WCVKTarget
@end

static NSMutableArray<WCVKTarget *> *gTargets = nil;
static dispatch_queue_t gQueue = nil;

static dispatch_queue_t WCVKQueue(void) {
    if (!gQueue) gQueue = dispatch_queue_create("com.wcvoicekeep.bgkeep", DISPATCH_QUEUE_SERIAL);
    return gQueue;
}

static void WCVKArmTarget(WCVKTarget *t, int attempt);
static void WCVKStopTarget(WCVKTarget *t);

static int WCVKTargetPid(WCVKTarget *t) {
    if ([t.kind isEqualToString:@"kbd"])
        return WCVKPidForPathSuffix([NSString stringWithUTF8String:kKbdExtSuffix], nil);
    // v2.0.2：App 一律按 bundle id 精确锁（路径匹配会把微信和企业微信认成同一个）
    return WCVKPidForBID(t.ident);
}

// v2.0.2：拉起结果一律**以进程真实存在为准**，不再信 API 返回值。
// SBSLaunchApplicationWithIdentifier 返回 0 只代表"请求已受理"，进程可能几百毫秒后才出现；
// 反过来偶尔返回非 0 但进程其实起来了。所以统一延后校验 pid，失败再按 5s/15s 重试两次。
static const int kVerifyDelayMs   = 1500;
static const int kAppRetryDelay[] = { 5, 15 };

static void WCVKRelaunchAttempt(WCVKTarget *t, int attempt) {
    NSString *disp = t.display ?: t.ident;
    NSString *ident = t.ident;
    NSString *kind = t.kind;
    // 拉起方式只有一种：SBSLaunch(bid, 1) 后台拉起（不切前台、不亮屏）。
    // 曾试过「拉起后立刻 SIGSTOP 造真 prewarm」，实测不可用（0ms 冻结时 dyld 都没跑，
    // 进程成 928K 空壳，点开打不开）—— 那套代码已彻底删除，不要再加回来。
    int r = WCVKHeadlessLaunch(ident);
    LOG(@"headless launch %@ rc=%d (attempt %d)", ident, r, attempt);

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kVerifyDelayMs * NSEC_PER_MSEC)),
                   WCVKQueue(), ^{
        int pid = WCVKPidForBID(ident);
        if (pid > 0) {
            t.fails = 0;
            t.lastRelaunch = 0;                    // 成功立刻清冷却
            WCVKRecord(disp, ident, kind, YES,
                       [NSString stringWithFormat:@"后台拉起成功 (pid=%d)", pid]);
            WCVKArmTarget(t, 0);                   // 立刻在新 pid 上重挂监视
            return;
        }
        int retries = (int)(sizeof(kAppRetryDelay) / sizeof(kAppRetryDelay[0]));
        if (attempt < retries) {
            int d = kAppRetryDelay[attempt];
            LOG(@"%@ 未起来（rc=%d）-> %ds 后重试", disp, r, d);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(d * NSEC_PER_SEC)),
                           WCVKQueue(), ^{ WCVKRelaunchAttempt(t, attempt + 1); });
            return;
        }
        t.fails++;
        // v2.0.6：连续失败熔断 —— 某个勾选的 App 卸了/再也拉不起来时，别无限 45s 冷却重试。
        // 摘掉看护，等用户改设置（rebuild 会清零 fails/disabled）再恢复。
        if (t.fails >= kFuseFailLimit) {
            t.disabled = YES;
            LOG(@"%@ 连续失败 %d 次 -> 熔断，停止看护（改设置后恢复）", disp, t.fails);
            WCVKRecord(disp, ident, kind, NO,
                       [NSString stringWithFormat:@"连续失败 %d 次，已暂停保活（改设置后恢复）", t.fails]);
            WCVKStopTarget(t);
            return;
        }
        WCVKRecord(disp, ident, kind, NO,
                   [NSString stringWithFormat:@"后台拉起失败 rc=%d（已重试 %d 次）", r, retries]);
    });
}

static void WCVKDoRelaunch(WCVKTarget *t) {
    time_t now = time(NULL);
    // 键盘扩展：只做 3 秒防抖（同一次预热可能连着收到多个事件），**绝不能沿用 45s 失败冷却**
    // —— 老板实测「注销后第一次杀掉能拉，紧接着再杀一次就不拉了」，根因就是 kbd 分支
    // 只写 lastRelaunch 却永不清零：拉起是成功的，但冷却照样挡掉了第二、三次。
    int cooldown = [t.kind isEqualToString:@"kbd"] ? kKbdDebounceSec : kFailCooldownSec;
    if (t.lastRelaunch && now - t.lastRelaunch < cooldown) {
        LOG(@"%@ 冷却中（%lds 前刚处理过，冷却 %ds），跳过", t.display,
            (long)(now - t.lastRelaunch), cooldown);
        return;
    }
    t.lastRelaunch = now;

    if ([t.kind isEqualToString:@"kbd"]) {
        // 键盘扩展没有别的门路：只能让 SpringBoard 弹一次键盘，系统才会 spawn 它
        uint32_t st = notify_post("com.wcvoicekeep.kbd.warmup");
        LOG(@"kbd warmup notify posted -> %u", st);
        // v2.0.2：记录改成"预热发出 -> 1.5s 后按进程是否真的在跑写结果"，
        // 以前直接写"请求已发出"，看起来像成功，实际可能没起来。
        NSString *disp = t.display ?: @"键盘";
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kVerifyDelayMs * NSEC_PER_MSEC)),
                       WCVKQueue(), ^{
            int pid = WCVKPidForPathSuffix([NSString stringWithUTF8String:kKbdExtSuffix], nil);
            if (pid > 0)
                WCVKRecord(disp, @"wxkb_plugin", @"kbd", YES,
                           [NSString stringWithFormat:@"键盘扩展已拉起 (pid=%d)", pid]);
            else
                WCVKRecord(disp, @"wxkb_plugin", @"kbd", NO, @"键盘预热已发出但扩展未起来");
        });
        return;
    }
    WCVKRelaunchAttempt(t, 0);
}

// 在 pid 上挂退出事件；进程一死内核回调（零轮询）
static void WCVKArmPid(WCVKTarget *t, int pid) {
    if (t.src) { dispatch_source_cancel(t.src); t.src = nil; }
    if (pid <= 0) return;
    t.pid = pid;
    t.armedAt = time(NULL);   // v2.0.22：记下「第一次看到这个 pid」的时间，用于算存活时长
    dispatch_source_t src = dispatch_source_create(DISPATCH_SOURCE_TYPE_PROC, (uintptr_t)pid,
                                                   DISPATCH_PROC_EXIT, WCVKQueue());
    if (!src) return;
    __weak WCVKTarget *wt = t;
    dispatch_source_set_event_handler(src, ^{
        WCVKTarget *st = wt;
        if (!st) return;
        // ★ v2.0.24（老板 2026-11-07 明确要求）：撤掉短命退避，恢复纯事件驱动。
        //   上一版 1/5/15/60/120s 的退避把 daemon 变成「半天不拉起」，测试时根本等不到；
        //   而且退避本来是为了压「重启风暴」，可风暴的真实影响（会话越滚越多）已经在
        //   scene-session 那一层按条数处理掉了，这里没必要再拖时间。
        //   现在：任何退出事件 -> 固定 kRelaunchDelaySec（1s）立刻拉起。
        //   短命次数仅用于日志统计，不再影响延迟。
        time_t life = (st.armedAt > 0) ? (time(NULL) - st.armedAt) : -1;
        int delay = kRelaunchDelaySec;
        if ([st.kind isEqualToString:@"app"] && life >= 0 && life < kShortLifeSec) {
            st.shortLives++;
            LOG(@"### %@ (pid=%d) 退出（只活了 %lds，累计短命 %d 次）-> %ds 后立刻拉起",
                st.display, st.pid, (long)life, st.shortLives, delay);
        } else {
            if (st.shortLives > 0)
                LOG(@"### %@ 这次活了 %lds -> 短命计数清零（原连击 %d 次）",
                    st.display, (long)life, st.shortLives);
            st.shortLives = 0;
        }
        st.armedAt = 0;
        st.pid = 0;
        if (st.src) { dispatch_source_cancel(st.src); st.src = nil; }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                       WCVKQueue(), ^{
            WCVKDoRelaunch(st);
            WCVKArmTarget(st, 0);   // 拉起后重新挂监视
        });
    });
    t.src = src;
    dispatch_resume(src);
    // 键盘扩展一旦重新挂上监视，说明上一次拉起已成功 -> 清防抖，下次退出立刻处理
    if ([t.kind isEqualToString:@"kbd"]) t.lastRelaunch = 0;
    LOG(@"watch ARMED: %@ (pid=%d)", t.display, pid);
}

static void WCVKArmTarget(WCVKTarget *t, int attempt) {
    if (t.disabled) { LOG(@"%@ 已熔断，跳过看护", t.display); return; }
    int pid = WCVKTargetPid(t);
    if (pid > 0) { WCVKArmPid(t, pid); return; }

    // ⚠️ v2.0.6 回退记录：老板明确要求**不要**在这里加"pid=0 就主动预热拉起"。
    // 实测注销后键盘扩展 pid=0 本来就能被正常拉起（退出事件 + kbd.up + 重试挂监视这条链是好的），
    // 在这条路径上再插主动预热反而会打乱它，导致"注销后反而不拉起了"。保持原样。

    if (attempt >= (int)(sizeof(kArmRetrySecs) / sizeof(kArmRetrySecs[0]))) {
        LOG(@"%@ 重试结束仍未在运行（等下次退出事件/设置变更）", t.display);
        return;
    }
    int delay = kArmRetrySecs[attempt];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                   WCVKQueue(), ^{ WCVKArmTarget(t, attempt + 1); });
}

static void WCVKStopTarget(WCVKTarget *t) {
    if (t.src) { dispatch_source_cancel(t.src); t.src = nil; }
    t.pid = 0;
}

// 按当前设置重建目标表：键盘扩展永远在内（必需），加上用户勾选的 App
static void WCVKRebuildTargets(void) {
    if (!gTargets) gTargets = [NSMutableArray array];

    // v2.0.2：总开关关闭时必须真的停手。以前这里没检查 gEnabled，
    // 用户关掉「后台保活」后其实还在看护 —— 开关等于摆设。
    if (!gEnabled) {
        for (WCVKTarget *old in gTargets) WCVKStopTarget(old);
        if (gTargets.count) LOG(@"总开关已关闭 -> 停止全部看护（%lu 个目标）",
                                (unsigned long)gTargets.count);
        [gTargets removeAllObjects];
        return;
    }

    NSMutableArray *want = [NSMutableArray array];
    WCVKTarget *kbd = [WCVKTarget new];
    kbd.ident = @"wxkb_plugin";
    kbd.display = @"微信输入法键盘扩展";
    kbd.kind = @"kbd";
    [want addObject:kbd];

    for (NSString *bid in gAppBIDs) {
        NSDictionary *meta = WCVKAppMeta(bid);
        WCVKTarget *t = [WCVKTarget new];
        t.ident = bid;
        // v2.0.2：解析不到显示名也**不再 skip**。保活完全依赖 bundle id（见 WCVKPidForBID），
        // 跟可执行路径无关 —— 以前 skip 掉就等于"用户勾了但永远不保活"，太脆弱。
        t.display = meta[@"display"] ?: bid;
        t.kind = @"app";
        t.exeSuffix = meta[@"exeSuffix"];      // 仅用于 --status 显示，不再参与匹配
        if (!meta) LOG(@"%@：LaunchServices 解析失败，仍按 bundle id 保活", bid);
        [want addObject:t];
    }

    for (WCVKTarget *old in gTargets) {
        BOOL keep = NO;
        for (WCVKTarget *n in want) if ([n.ident isEqualToString:old.ident]) { keep = YES; break; }
        if (!keep) { LOG(@"target 移除: %@", old.display); WCVKStopTarget(old); }
    }
    NSMutableArray *merged = [NSMutableArray array];
    for (WCVKTarget *n in want) {
        WCVKTarget *exist = nil;
        for (WCVKTarget *old in gTargets) if ([old.ident isEqualToString:n.ident]) { exist = old; break; }
        if (exist) {
            exist.display = n.display; exist.exeSuffix = n.exeSuffix;
            // v2.0.6：重建只在「启动」或「设置真的变了」时发生 —— 这两种情况都要清零熔断，
            // 即老板要的「连续 3 次失败摘掉，改了设置就恢复」。
            if (exist.disabled || exist.fails)
                LOG(@"%@ 熔断/失败计数清零（设置变更或重启）", exist.display);
            exist.disabled = NO;
            exist.fails = 0;
            [merged addObject:exist];
        }
        else       { [merged addObject:n]; }
    }
    gTargets = merged;

    LOG(@"targets 重建：共 %lu 个（键盘扩展 + App %lu）",
        (unsigned long)gTargets.count, (unsigned long)(gTargets.count ? gTargets.count - 1 : 0));

    // v2.0.7（老板要求）：**重建时目标不在运行，就必须把它拉起来**。
    // 重建发生在：daemon 启动、注销/重启后、设置变更。
    // 以前这里只会向下走 WCVKArmTarget 的 2/5/10/20/40s 重试去找 pid，找不到就放弃 ——
    // 之后再也没有任何触发点（退出事件不存在，因为进程根本没起来），
    // 于是那个 App 就彻底不保活了，直到用户再改一次设置。老板实测就撞到这个。
    // 注意：键盘扩展那条链（退出事件 + kbd.up + 重试挂监视）是好的，这里**不碰**。
    for (WCVKTarget *t in gTargets) {
        if ([t.kind isEqualToString:@"kbd"]) continue;
        if (t.disabled || t.pid > 0 || t.src || t.lastRelaunch) continue;
        LOG(@"%@ 重建时不在运行 -> 主动后台拉起", t.display);
        WCVKDoRelaunch(t);
    }

    for (WCVKTarget *t in gTargets) {
        if (t.src && t.pid > 0 && WCVKTargetPid(t) == t.pid) continue;
        WCVKArmTarget(t, 0);
    }
}

// ===== 设置热生效：VNODE 监听 Preferences 目录，不轮询 =====
static void WCVKArmPrefsWatch(void);
static void WCVKHandlePrefsChanged(void);

static void WCVKHandlePrefsChanged(void) {
    // v2.0.5：值没变就不重建（系统级 preferences-changed 广播非常杂）
    if (!WCVKReadPrefs()) {
        LOG(@"prefs 通知：值与当前一致，跳过重建");
        return;
    }
    LOG(@"prefs 变更 -> 重建目标");
    WCVKRebuildTargets();
}

static void WCVKArmPrefsWatch(void) {
    NSArray<NSString *> *dirs = WCVKPrefsDirCandidates();
    int armed = 0;
    for (NSString *dir in dirs) {
        int fd = open([dir fileSystemRepresentation], O_RDONLY);
        if (fd < 0) continue;
        dispatch_source_t src = dispatch_source_create(DISPATCH_SOURCE_TYPE_VNODE, (uintptr_t)fd,
            DISPATCH_VNODE_WRITE | DISPATCH_VNODE_RENAME | DISPATCH_VNODE_DELETE,
            WCVKQueue());
        if (!src) { close(fd); continue; }
        armed++;
        NSString *dirPath = [dir copy];
        __block time_t lastM = 0;
        {
            NSDictionary *a = [[NSFileManager defaultManager]
                attributesOfItemAtPath:[dirPath stringByAppendingFormat:@"/%@.plist", kPrefsDomain] error:nil];
            if (a) lastM = (time_t)[a[NSFileModificationDate] timeIntervalSince1970];
        }
        dispatch_source_set_event_handler(src, ^{
            // 目录里任何写入都会唤醒：只在我们的 plist 真变了（mtime 变）才重读，零成本
            NSString *p = [dirPath stringByAppendingFormat:@"/%@.plist", kPrefsDomain];
            NSDictionary *a = [[NSFileManager defaultManager] attributesOfItemAtPath:p error:nil];
            if (!a) return;
            time_t m = (time_t)[a[NSFileModificationDate] timeIntervalSince1970];
            if (m == lastM) return;
            lastM = m;
            WCVKHandlePrefsChanged();
        });
        dispatch_source_set_cancel_handler(src, ^{ close(fd); });
        dispatch_resume(src);
    }
    LOG(@"prefs watch armed on %d 个目录", armed);
}

// v2.0.2：设置"实时生效"通道。
//
// 只靠 VNODE 监听 Preferences 目录不可靠：设置 App 的开关是经 cfprefsd 写的，cfprefsd 有
// 延迟 flush（几秒到十几秒，甚至等设置进程离开才落盘），所以老板实测"勾了要注销一次才生效"。
// 这里加两路更及时的通知：
//   ① 我们自己的设置页在保存时 notify_post("com.wcvoicekeep.prefs.changed") —— 立刻；
//   ② 系统 cfprefsd 的 com.apple.preferences-changed —— 兜底（其它入口改了设置也能收到）。
// 收到后 0.6s 去抖再重读，避免连续开关触发多次重建。
static int  gPrefsNotifySelf = 0;
static int  gPrefsNotifySys  = 0;
static BOOL gPrefsReloadPending = NO;

static void WCVKSchedulePrefsReload(const char *why) {
    if (gPrefsReloadPending) return;
    gPrefsReloadPending = YES;
    LOG(@"prefs 通知(%s) -> 0.6s 后重读", why);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)),
                   WCVKQueue(), ^{
        gPrefsReloadPending = NO;
        gPrefsDirCached = nil;      // 让 WCVKExistingPrefsDir 重新挑最新那份
        WCVKHandlePrefsChanged();
    });
}

static void WCVKRegisterPrefsNotify(void) {
    notify_register_dispatch("com.wcvoicekeep.prefs.changed", &gPrefsNotifySelf,
                             WCVKQueue(), ^(int t) { WCVKSchedulePrefsReload("self"); });
    // 系统偏好变更（cfprefsd 广播），任何写入方式都会走这里
    notify_register_dispatch("com.apple.preferences-changed", &gPrefsNotifySys,
                             WCVKQueue(), ^(int t) { WCVKSchedulePrefsReload("system"); });
    LOG(@"prefs notify registered (self + system)");
}

// ===== 键盘扩展拉起成功后，SpringBoard 会发 kbd.up -> 在新 pid 上重挂 =====
static int gKbdUpToken = 0;
static void WCVKRegisterKbdUp(void) {
    notify_register_dispatch("com.wcvoicekeep.kbd.up", &gKbdUpToken, WCVKQueue(), ^(int token) {
        LOG(@"kbd.up received -> 在新 pid 上重挂监视");
        for (WCVKTarget *t in gTargets) {
            if ([t.kind isEqualToString:@"kbd"]) { WCVKArmTarget(t, 0); break; }
        }
    });
}

// ===== 子命令 =====
static void WCVKPrintStatus(void) {
    WCVKReadPrefs();
    printf("prefs   : %s\n", WCVKPrefsPath().UTF8String);
    printf("records : %s\n", WCVKRecordsPath().UTF8String);
    printf("enabled=%d logging=%d record=%d\n", gEnabled, gLogging, gRecord);
    int kpid = WCVKPidForPathSuffix([NSString stringWithUTF8String:kKbdExtSuffix], nil);
    printf("  [kbd] wxkb_plugin pid=%d\n", kpid);
    for (NSString *bid in gAppBIDs) {
        NSDictionary *m = WCVKAppMeta(bid);
        // v2.0.2：按 bundle id 查 pid（以前用 exe 路径，微信和企业微信会显示同一个 pid）
        int pid = WCVKPidForBID(bid);
        printf("  [app] %-34s %-14s pid=%-6d exe=%s\n", bid.UTF8String,
               [(m[@"display"] ?: bid) UTF8String], pid,
               [(m[@"exeSuffix"] ?: @"(解析失败, 仍按 bid 保活)") UTF8String]);
    }
    NSArray *recs = WCVKLoadRecords(WCVKRecordsPath());
    printf("records count=%lu\n", (unsigned long)recs.count);
    NSDateFormatter *df = [[NSDateFormatter alloc] init];
    df.dateFormat = @"yyyy-MM-dd HH:mm:ss";
    for (NSUInteger i = 0; i < recs.count && i < 10; i++) {
        NSDictionary *r = recs[i];
        NSDate *t = [r[@"t"] isKindOfClass:[NSDate class]] ? r[@"t"] : nil;
        printf("  %s  %-18s %-4s %s\n",
               (t ? [df stringFromDate:t] : @"--").UTF8String,
               [(r[@"name"] ?: @"?") UTF8String],
               [r[@"ok"] boolValue] ? "OK" : "FAIL",
               [(r[@"detail"] ?: @"") UTF8String]);
    }
}

int main(int argc, char *argv[]) {
    @autoreleasepool {
        for (int i = 1; i < argc; i++) {
            if (strcmp(argv[i], "--status") == 0) { WCVKPrintStatus(); return 0; }
            if (strcmp(argv[i], "--kbd-warm") == 0) {
                uint32_t s = notify_post("com.wcvoicekeep.kbd.warmup");
                printf("kbd warmup posted -> %u\n", s);
                return 0;
            }
            if (strcmp(argv[i], "--launch") == 0 && i + 1 < argc) {
                NSString *bid = [NSString stringWithUTF8String:argv[i + 1]];
                int r = WCVKHeadlessLaunch(bid);
                WCVKRecord(bid, bid, @"app", r == 0, @"手动测试后台拉起");
                printf("headless launch %s -> %d (0=ok)\n", argv[i + 1], r);
                return 0;
            }
            if (strcmp(argv[i], "--ls-probe") == 0) {
                // 诊断用：打印 LaunchServices 各入口是否真实存在（v2.0.0 就是盲调了不存在的
                // 实例方法，导致勾选的 App 全被 skip）
                WCVKEnsureLSLoaded();
                Class P = NSClassFromString(@"LSApplicationProxy");
                Class WS = NSClassFromString(@"LSApplicationWorkspace");
                printf("LSApplicationProxy=%s LSApplicationWorkspace=%s\n",
                       P ? "yes" : "no", WS ? "yes" : "no");
                const char *sels[] = {"applicationProxyForIdentifier:",
                                      "applicationProxyForBundleIdentifier:",
                                      "applicationProxyForBundleID:",
                                      "allApplications", "defaultWorkspace"};
                for (unsigned k = 0; k < sizeof(sels) / sizeof(sels[0]); k++) {
                    SEL s2 = sel_registerName(sels[k]);
                    printf("  +[LSApplicationProxy      %-38s] %d\n", sels[k],
                           (P && [(id)P respondsToSelector:s2]) ? 1 : 0);
                    printf("  -[LSApplicationWorkspace  %-38s] %d\n", sels[k],
                           (WS && [(id)WS instancesRespondToSelector:s2]) ? 1 : 0);
                }
                NSArray *probe = gAppBIDs.count ? gAppBIDs : @[@"com.tencent.xin"];
                for (NSString *bid in probe) {
                    NSDictionary *m = WCVKAppMeta(bid);
                    printf("  meta %s -> exe=%s display=%s\n", bid.UTF8String,
                           [(m[@"exeSuffix"] ?: @"nil") UTF8String],
                           [(m[@"display"] ?: @"nil") UTF8String]);
                }
                return 0;
            }
            if (strcmp(argv[i], "--clear-records") == 0) {
                [[NSFileManager defaultManager] removeItemAtPath:WCVKRecordsPath() error:nil];
                printf("records cleared: %s\n", WCVKRecordsPath().UTF8String);
                return 0;
            }
        }

        // ===== 常驻守护 =====
        LOG(@"===== daemon start (pid=%d, flavor=%s) =====", getpid(),
            WCVK_NO_LOG ? "pure" : "log");
        WCVKReadPrefs();
        WCVKRebuildTargets();
        WCVKRegisterKbdUp();
        WCVKRegisterPrefsNotify();   // v2.0.2：设置实时生效（自通知 + 系统偏好通知）
        WCVKArmPrefsWatch();
        LOG(@"daemon ready: 事件驱动看护中（零轮询）");

        dispatch_main();
    }
    return 0;
}
