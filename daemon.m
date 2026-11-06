// wcvoicekeep daemon — v2.0.31「只负责拉起」
//
// 职责（老板 2026-11-07 定案）：本工程**不再注入任何 App 进程**，daemon 只做两件事：
//   1) 键盘扩展 wxkb_plugin —— 必须保活（不可关闭、永不熔断）。它一退出，发 Darwin 通知
//      请 SpringBoard 弹一下键盘，系统才会重新 spawn 它。
//   2) 用户勾选的 App —— 被杀后在**后台**无头拉起（SBSLaunchApplicationWithIdentifier
//      flag=Background，不切前台）。
//   每次拉起写一条记录（log/pure 都写，受设置里的记录开关控制）。
//
// ★ 拉起语义一个数没动（老板 2026-11-07 定案，禁止再改）：
//   任何 EXIT 事件 -> 固定 1s 立刻拉起，不引入任何指数退避；
//   键盘 3s 防抖、App 失败 15s 冷却、连续 3 次失败熔断（**键盘豁免**）、
//   拉起后 1.5s 按真实 pid 校验、失败按 5s/15s 重试两次、挂监视重试 2/5/10/20/40s。
//
// ===== v2.0.31 优化：不卡事件队列 / 无多余开销 / 鲁棒性 / 精准命中 =====
//  ① 线程拆分（gQueue 只做轻量状态判断，不再被同步 IO/IPC 卡住）：
//     gQueue       —— 唯一状态队列，所有 target/prefs/事件回调
//     gLogQueue    —— 日志写盘（持久 fd，一次 open 之后只 write）
//     gRecordQueue —— 拉起记录 plist 读写（串行保序）
//     gLaunchQueue —— SBSLaunch 同步 Mach IPC（这玩意儿会等 SpringBoard）
//     gScanQueue   —— 全进程表扫描（唯一的重活，全部搬离 gQueue）
//  ② pid 全缓存（老板「能缓存就用缓存，不要每次全局扫描/遍历」）：
//     每个 target 的 pid 就是缓存；命中时只做 1 次单点校验（kbd: proc_pidpath；
//     app: KERN_PROCARGS2 按 NUL 分段前缀匹配），**零全表扫描**。
//     只有缓存失效才进 gScanQueue，且一次扫描同时解析所有目标（原来每个 target 各扫一遍）。
//     kbd 的新 pid 由 SpringBoard 通过 com.wcvoicekeep.kbd.up 的 notify state 直接递过来，
//     连那一次扫描都省了；state 无效时才回退扫描。
//  ③ 精准命中：env 不再全缓冲逐字节 memcmp（可能在任意偏移误命中），改成按 \0 分段、
//     只匹配段首 "XPC_SERVICE_NAME=UIKitApplication:<bid>["；微信 / 企业微信路径相同也能精确区分。
//  ④ 去重：退出事件不再和 1.5s 校验各挂一次监视（实机日志每次拉起 "watch ARMED" 打两遍的根因）；
//     同一 pid 已挂监视直接 return；拉起链进行中（relaunching）不再并发启动挂监视重试链。
//  ⑤ generation 令牌：target 被移除 / 熔断 / 总开关关闭 / 设置重建时 gen++，
//     所有 dispatch_after 回调先校验 gen + 仍在新目标表，失效就什么都不做
//     —— 已取消勾选的 App 不会再被旧回调拉起来。
//  ⑥ VNODE 自愈：Preferences 目录被 rename/delete 后自动重挂，不会因为一次原子替换就永久失聪。

#import <Foundation/Foundation.h>
#import <MobileCoreServices/MobileCoreServices.h>
#import <objc/message.h>
#include <sys/sysctl.h>
#include <sys/stat.h>
#include <stdint.h>
#include <dlfcn.h>
#include <dispatch/dispatch.h>
#include <notify.h>
#include <fcntl.h>
#include <unistd.h>
#include <string.h>
#include <time.h>
#include <stdlib.h>
#include <stdio.h>

// iOS SDK 没有 macOS 的 libproc.h —— 只声明用到的两个 libproc 函数（iOS 上在 libSystem 里）
#ifndef PROC_PIDPATHINFO_MAXSIZE
#define PROC_PIDPATHINFO_MAXSIZE 4096
#endif
#ifdef __cplusplus
extern "C" {
#endif
extern int proc_listallpids(void *buffer, int buffersize);
extern int proc_pidpath(int pid, void *buffer, uint32_t buffersize);
#ifdef __cplusplus
}
#endif

#ifndef KERN_PROCARGS2
#define KERN_PROCARGS2 49
#endif

// ===== 日志（纯净版编译期整体剥离；日志版强制后台队列，pure 版连参数都不求值）=====
#ifndef WCVK_NO_LOG
#define WCVK_NO_LOG 0
#endif

static NSString *const kLogPath     = @"/var/mobile/wcvoicekeep.daemon.log";
static NSString *const kPrefsDomain = @"com.wcvoicekeep.bgkeep";
static NSString *const kRecordsName = @"com.wcvoicekeep.bgkeep.records.plist";

#if WCVK_NO_LOG
#define LOG(...) do {} while (0)
#else
static dispatch_queue_t WCVKLogQueue(void) {
    static dispatch_queue_t q = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        q = dispatch_queue_create("com.wcvoicekeep.daemon.log", DISPATCH_QUEUE_SERIAL);
    });
    return q;
}
static int gLogFd = -1;

static void LOG(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    // 时间戳在调用线程生成，后台写盘也不会错序
    NSString *line = [NSString stringWithFormat:@"[%@][daemon] %@\n", [NSDate date], msg];
    NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
    dispatch_async(WCVKLogQueue(), ^{
        if (gLogFd < 0)
            gLogFd = open(kLogPath.fileSystemRepresentation,
                          O_WRONLY | O_CREAT | O_APPEND, 0644);
        if (gLogFd < 0) return;
        struct stat st;
        if (fstat(gLogFd, &st) == 0 && st.st_size > 2 * 1024 * 1024)
            ftruncate(gLogFd, 0);
        (void)write(gLogFd, data.bytes, data.length);
    });
}
#endif

// ===== 队列 =====
static dispatch_queue_t WCVKQueue(void) {
    static dispatch_queue_t q = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ q = dispatch_queue_create("com.wcvoicekeep.bgkeep", DISPATCH_QUEUE_SERIAL); });
    return q;
}
static dispatch_queue_t WCVKRecordQueue(void) {
    static dispatch_queue_t q = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ q = dispatch_queue_create("com.wcvoicekeep.bgkeep.record", DISPATCH_QUEUE_SERIAL); });
    return q;
}
static dispatch_queue_t WCVKLaunchQueue(void) {
    static dispatch_queue_t q = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ q = dispatch_queue_create("com.wcvoicekeep.bgkeep.launch", DISPATCH_QUEUE_SERIAL); });
    return q;
}
static dispatch_queue_t WCVKScanQueue(void) {
    static dispatch_queue_t q = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ q = dispatch_queue_create("com.wcvoicekeep.bgkeep.scan", DISPATCH_QUEUE_SERIAL); });
    return q;
}

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
static BOOL     gEnabled = YES;
static BOOL     gLogging = NO;
static BOOL     gRecord  = YES;
static NSArray *gAppBIDs = nil;

// 返回「值是否有变化」：com.apple.preferences-changed 是系统级广播，
// 任何 App 改任何偏好都会打过来，值没变就跳过重建（不做全量 LaunchServices 解析）。
static BOOL WCVKReadPrefs(void) {
    BOOL    oldEnabled = gEnabled, oldLogging = gLogging, oldRecord = gRecord;
    NSArray *oldBIDs   = gAppBIDs;
    NSString *p = WCVKPrefsPath();

    // 优先走 CFPreferences（cfprefsd 的内存值），盘上 plist 可能还没 flush（v2.0.2 实测）
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
    (void)oldLogging;
    LOG(@"prefs loaded (%s): enabled=%d record=%d apps=%@ changed=%d",
        viaCF ? "cfprefs" : "file", gEnabled, gRecord, gAppBIDs, changed);
    return changed;
}

// ===== 拉起记录（纯净版也写；设置页「拉起记录」读它）=====
static NSMutableArray *WCVKLoadRecords(NSString *path) {
    id o = [NSDictionary dictionaryWithContentsOfFile:path];
    if ([o isKindOfClass:[NSDictionary class]] && [o[@"rows"] isKindOfClass:[NSArray class]])
        return [o[@"rows"] mutableCopy];
    o = [NSArray arrayWithContentsOfFile:path];
    if ([o isKindOfClass:[NSArray class]]) return [o mutableCopy];
    return [NSMutableArray array];
}

// 只在 gRecordQueue 上执行：整份读 + 整份写 + 属主修正，全部不占事件队列
static void WCVKRecordWrite(NSString *path, NSDictionary *row) {
    NSMutableArray *arr = WCVKLoadRecords(path);
    [arr insertObject:row atIndex:0];
    while (arr.count > 20) [arr removeLastObject];   // v2.0.6：20 条约 2KB
    NSDictionary *out = @{ @"rows": arr };
    NSString *writtenPath = path;
    BOOL wrote = [out writeToFile:path atomically:YES];
    if (!wrote) {
        NSString *alt = @"/var/mobile/wcvoicekeep.records.plist";
        wrote = [out writeToFile:alt atomically:YES];
        if (wrote) writtenPath = alt;
        LOG(@"record write fallback -> %@ (%d)", alt, wrote);
    }
    if (wrote) {
        // 属主必须是 mobile（设置页要能清空）；已正确就不再 syscall
        struct stat sb;
        if (stat(writtenPath.fileSystemRepresentation, &sb) != 0 ||
            sb.st_uid != 501 || (sb.st_mode & 07777) != 0644) {
            chown(writtenPath.fileSystemRepresentation, 501, 501);
            chmod(writtenPath.fileSystemRepresentation, 0644);
        }
    }
}

static void WCVKRecord(NSString *display, NSString *ident, NSString *kind, BOOL ok, NSString *detail) {
    // 记录开关关掉时**直接返回**：不读文件、不写文件、不进队列，零 syscall、零 CPU
    if (!gRecord) return;
    NSString *path = WCVKRecordsPath();     // 目录缓存在调用线程解析好，后台线程不读共享状态
    NSMutableDictionary *row = [NSMutableDictionary dictionary];
    row[@"t"] = [NSDate date];
    row[@"name"] = display ?: ident ?: @"?";
    row[@"bid"] = ident ?: @"";
    row[@"kind"] = kind ?: @"app";
    row[@"ok"] = @(ok);
    if (detail.length) row[@"detail"] = detail;
    dispatch_async(WCVKRecordQueue(), ^{ WCVKRecordWrite(path, row); });
}

// ===== App 可执行文件 / 显示名解析（LaunchServices，只用于显示，不参与 pid 匹配）=====
static void WCVKEnsureLSLoaded(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dlopen("/System/Library/Frameworks/MobileCoreServices.framework/MobileCoreServices", RTLD_LAZY);
        dlopen("/System/Library/PrivateFrameworks/LaunchServices.framework/LaunchServices", RTLD_LAZY);
    });
}
static NSString *WCVKProxyString(id proxy, NSArray<NSString *> *sels);

static id WCVKLSProxyForBID(NSString *bid) {
    WCVKEnsureLSLoaded();
    @try {
        Class P = NSClassFromString(@"LSApplicationProxy");
        if (P) {
            SEL s = sel_registerName("applicationProxyForIdentifier:");
            if ([(id)P respondsToSelector:s]) {
                id r = ((id (*)(id, SEL, id))objc_msgSend)((id)P, s, bid);
                if (r) {
                    NSString *own = WCVKProxyString(r, @[@"bundleIdentifier", @"applicationIdentifier"]);
                    if (!own.length || [own isEqualToString:bid]) return r;
                }
            }
        }
    } @catch (NSException *e) {}
    @try {
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

// 有缓存：只在启动 / 设置真变时解析一次，常态零 LaunchServices 开销。
// 解析失败不缓存（App 之后装回来还能重新解析），且**不影响保活**（pid 匹配只认 bundle id）。
static NSMutableDictionary *gMetaCache = nil;
static NSDictionary *WCVKAppMeta(NSString *bid) {
    if (!gMetaCache) gMetaCache = [NSMutableDictionary dictionary];
    NSDictionary *cached = gMetaCache[bid];
    if (cached) return cached;
    id proxy = WCVKLSProxyForBID(bid);
    if (!proxy) return nil;

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
        ![appDir isKindOfClass:[NSString class]] || !appDir.length) return nil;

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
static int WCVKHeadlessLaunch(NSString *bid) {
    if (!WCVKSBSReady() || !g_SBSLaunch) return -1;
    int r = g_SBSLaunch((__bridge CFStringRef)bid, 1);   // flag 1 = Background
    LOG(@"headless launch %@ -> %d (0=ok)", bid, r);
    return r;
}

// ===== 进程识别（精确 + 缓存优先）=====
static const char kKbdExtSuffix[] = "/wxkb_plugin.appex/wxkb_plugin";
static const size_t kKbdExtSuffixLen = sizeof(kKbdExtSuffix) - 1;

static BOOL WCVKPathHasKbdSuffix(const char *path, int len) {
    return len > 0 && (size_t)len >= kKbdExtSuffixLen &&
           memcmp(path + len - kKbdExtSuffixLen, kKbdExtSuffix, kKbdExtSuffixLen) == 0;
}

// KERN_PROCARGS2：前 4 字节 argc，之后是 exec_path / argv / envp，全部 NUL 分隔。
// 按「段」比对段首，而不是在整个缓冲里逐字节 memcmp —— 更快也更精准（不会在任意偏移误命中）。
static BOOL WCVKEnvHasNeedle(const char *buf, size_t size, const char *needle, size_t nlen) {
    if (!buf || size <= sizeof(int) || !nlen) return NO;
    const char *p = buf + sizeof(int);
    const char *end = buf + size;
    while (p < end) {
        const char *e = (const char *)memchr(p, 0, (size_t)(end - p));
        if (!e) break;
        if ((size_t)(e - p) >= nlen && memcmp(p, needle, nlen) == 0) return YES;
        p = e + 1;
    }
    return NO;
}

static char *WCVKProcEnv(pid_t pid, size_t *outSize) {
    int mib[3] = { CTL_KERN, KERN_PROCARGS2, (int)pid };
    size_t size = 0;
    if (sysctl(mib, 3, NULL, &size, NULL, 0) != 0 || size == 0 || size > (4u << 20)) return NULL;
    char *buf = (char *)malloc(size);
    if (!buf) return NULL;
    if (sysctl(mib, 3, buf, &size, NULL, 0) != 0) { free(buf); return NULL; }
    *outSize = size;
    return buf;
}

static size_t WCVKFillNeedle(char *buf, size_t cap, NSString *bid) {
    const char *s = bid.UTF8String;
    if (!s) return 0;
    int n = snprintf(buf, cap, "XPC_SERVICE_NAME=UIKitApplication:%s[", s);
    return (n > 0 && (size_t)n < cap) ? (size_t)n : 0;
}

typedef struct {
    char   needle[512];
    size_t needleLen;
    BOOL   isKbd;
} WCVKScanSpec;

// 一次进程表扫描，同时解析所有目标（原来每个 target 各扫一遍）。
// 绝大多数进程只花 1 次 proc_pidpath；只有 ".app/" 路径才做 sysctl 取 env。
static void WCVKScanTargetsSync(const WCVKScanSpec *specs, int n, int *outPids) {
    int remaining = 0;
    for (int i = 0; i < n; i++)
        if (outPids[i] == 0 && (specs[i].isKbd || specs[i].needleLen)) remaining++;
    if (remaining <= 0) return;

    int total = proc_listallpids(NULL, 0);
    if (total <= 0) return;
    int cap = total + 64;
    pid_t *pids = (pid_t *)calloc((size_t)cap, sizeof(pid_t));
    if (!pids) return;
    int cnt = proc_listallpids(pids, cap * (int)sizeof(pid_t));
    // 进程数在两次调用之间涨过预留量 -> 扩容重扫一次（鲁棒性）
    if (cnt >= cap) {
        free(pids);
        total = proc_listallpids(NULL, 0);
        if (total <= 0) return;
        cap = total + 128;
        pids = (pid_t *)calloc((size_t)cap, sizeof(pid_t));
        if (!pids) return;
        cnt = proc_listallpids(pids, cap * (int)sizeof(pid_t));
    }

    for (int j = 0; j < cnt && remaining > 0; j++) {
        pid_t p = pids[j];
        if (p <= 1) continue;
        char path[PROC_PIDPATHINFO_MAXSIZE] = {0};
        int plen = proc_pidpath(p, path, sizeof(path));
        if (plen <= 0) continue;

        for (int i = 0; i < n; i++) {
            if (specs[i].isKbd && outPids[i] == 0 && WCVKPathHasKbdSuffix(path, plen)) {
                outPids[i] = p; remaining--;
            }
        }
        // App 进程的 env 才有 XPC_SERVICE_NAME；非 .app/ 路径直接跳过，省掉每个 pid 两次 sysctl
        if (strstr(path, ".app/") == NULL) continue;
        BOOL needEnv = NO;
        for (int i = 0; i < n; i++)
            if (!specs[i].isKbd && specs[i].needleLen && outPids[i] == 0) { needEnv = YES; break; }
        if (!needEnv) continue;

        size_t esize = 0;
        char *env = WCVKProcEnv(p, &esize);
        if (!env) continue;
        for (int i = 0; i < n; i++) {
            if (!specs[i].isKbd && specs[i].needleLen && outPids[i] == 0 &&
                WCVKEnvHasNeedle(env, esize, specs[i].needle, specs[i].needleLen)) {
                outPids[i] = p; remaining--;
            }
        }
        free(env);
    }
    free(pids);
}

// ===== 目标 =====
static const int kRelaunchDelaySec = 1;      // EXIT -> 固定 1s，绝不退避
static const int kShortLifeSec     = 60;     // 仅用于日志措辞，不影响延迟
static const int kFailCooldownSec  = 15;
static const int kKbdDebounceSec   = 3;
static const int kArmRetrySecs[]   = {2, 5, 10, 20, 40};
static const int kFuseFailLimit    = 3;
static const int kVerifyDelayMs    = 1500;
static const int kAppRetryDelay[]  = { 5, 15 };

@interface WCVKTarget : NSObject
@property (nonatomic, copy)   NSString *ident;
@property (nonatomic, copy)   NSString *display;
@property (nonatomic, copy)   NSString *kind;       // @"kbd" / @"app"
@property (nonatomic, copy)   NSString *exeSuffix;  // 仅 --status 显示
@property (nonatomic, assign) int pid;              // ★ pid 缓存
@property (nonatomic, assign) unsigned gen;         // ★ 作废异步回调的令牌
@property (nonatomic, assign) unsigned armedGen;    // ★ 挂监视时的 gen，重建后必须重挂
@property (nonatomic, assign) BOOL relaunching;     // ★ 拉起链进行中
@property (nonatomic, assign) time_t lastRelaunch;
@property (nonatomic, assign) int fails;
@property (nonatomic, assign) BOOL disabled;
@property (nonatomic, assign) time_t armedAt;
@property (nonatomic, assign) int shortLives;
@property (nonatomic, strong) dispatch_source_t src;
@end
@implementation WCVKTarget
@end

static NSMutableArray<WCVKTarget *> *gTargets = nil;

static BOOL WCVKIsKbd(WCVKTarget *t) { return [t.kind isEqualToString:@"kbd"]; }

// 前置声明：退出事件 handler（定义在下面）要调它
static void WCVKDoRelaunch(WCVKTarget *t, unsigned gen);

// 所有 target 状态只在 gQueue 上读写
static BOOL WCVKTargetValid(WCVKTarget *t, unsigned gen) {
    if (!t || t.gen != gen || !gEnabled) return NO;
    if (t.disabled) return NO;                    // 键盘的 disabled 永远是 NO
    return [gTargets containsObject:t];
}

static void WCVKStopTarget(WCVKTarget *t) {
    t.gen++;                                     // 作废旧 dispatch_after 回调
    if (t.src) { dispatch_source_cancel(t.src); t.src = nil; }
    t.pid = 0;
    t.relaunching = NO;
}

// ★ 单点校验：缓存的是「上次找到的 pid」，**识别键永远是 bundle id（t.ident）**。
//   命中缓存时只有 1 次 syscall（kbd）或 1 次 env 读取（app），零全表扫描；
//   进程一死 / pid 被复用成别的 App，这里立刻返回 NO -> 缓存清零 ->
//   下一次 WCVKResolvePids 用 bundle id 重新扫出新 pid，绝不会拿旧 pid 挂错监视。
static BOOL WCVKValidatePid(WCVKTarget *t, int pid) {
    if (pid <= 1) return NO;
    if (WCVKIsKbd(t)) {
        char path[PROC_PIDPATHINFO_MAXSIZE] = {0};
        int plen = proc_pidpath(pid, path, sizeof(path));
        return WCVKPathHasKbdSuffix(path, plen);
    }
    char needle[512];
    size_t nlen = WCVKFillNeedle(needle, sizeof(needle), t.ident);
    if (!nlen) return NO;
    size_t esize = 0;
    char *env = WCVKProcEnv(pid, &esize);
    if (!env) return NO;
    BOOL ok = WCVKEnvHasNeedle(env, esize, needle, nlen);
    free(env);
    return ok;
}

// ★ 解析 pid：先吃缓存（单点校验），只有未命中的才进 gScanQueue 一次批量全表扫描。
//   done 一定在 gQueue 上执行；调用方负责校验 gen / 目标表。
static void WCVKResolvePids(NSArray<WCVKTarget *> *targets,
                            void (^done)(NSArray<NSNumber *> *pids)) {
    NSUInteger n = targets.count;
    if (!n) { done(@[]); return; }
    int *cached = (int *)calloc(n, sizeof(int));
    if (!cached) { done(@[]); return; }
    NSUInteger missing = 0;
    for (NSUInteger i = 0; i < n; i++) {
        WCVKTarget *t = targets[i];
        if (t.pid > 0 && WCVKValidatePid(t, t.pid)) cached[i] = t.pid;
        else missing++;
    }
    if (missing == 0) {
        NSMutableArray *arr = [NSMutableArray arrayWithCapacity:n];
        for (NSUInteger i = 0; i < n; i++) [arr addObject:@(cached[i])];
        free(cached);
        done(arr);                                 // 零扫描、零线程切换
        return;
    }

    WCVKScanSpec *specs = (WCVKScanSpec *)calloc(n, sizeof(WCVKScanSpec));
    if (!specs) { free(cached); done(@[]); return; }
    for (NSUInteger i = 0; i < n; i++) {
        if (cached[i] != 0) continue;             // 已命中：spec 全 0，扫描时跳过
        WCVKTarget *t = targets[i];
        if (WCVKIsKbd(t)) specs[i].isKbd = YES;
        else specs[i].needleLen = WCVKFillNeedle(specs[i].needle, sizeof(specs[i].needle), t.ident);
    }
    // 快照：后台线程不碰 ObjC 目标对象，只读这块纯 C 数据
    dispatch_async(WCVKScanQueue(), ^{
        int *found = (int *)calloc(n, sizeof(int));
        if (found) {
            memcpy(found, cached, n * sizeof(int));
            WCVKScanTargetsSync(specs, (int)n, found);
        }
        NSMutableArray *arr = [NSMutableArray arrayWithCapacity:n];
        for (NSUInteger i = 0; i < n; i++) [arr addObject:@(found ? found[i] : cached[i])];
        free(found); free(specs); free(cached);
        dispatch_async(WCVKQueue(), ^{ done(arr); });
    });
}

// ===== 挂退出事件 =====
static void WCVKArmTarget(WCVKTarget *t, unsigned gen, int attempt);
static void WCVKArmRetry(WCVKTarget *t, unsigned gen, int attempt);

static void WCVKArmPid(WCVKTarget *t, int pid) {
    // ★ 同一个 pid + 同一个 gen 已经挂过就不再重复 cancel/resume
    //   （实机日志每次拉起 "watch ARMED" 打两遍的根因）。
    //   gen 变了（设置重建/熔断恢复）说明旧 handler 已被作废，即使 pid 没变也必须重挂，
    //   否则会以为「监视还在」而永久失聪。
    if (t.src && t.pid == pid && pid > 0 && t.armedGen == t.gen) return;
    if (t.src) { dispatch_source_cancel(t.src); t.src = nil; }
    if (pid <= 0) return;
    t.pid = pid;
    t.armedAt = time(NULL);
    dispatch_source_t src = dispatch_source_create(DISPATCH_SOURCE_TYPE_PROC, (uintptr_t)pid,
                                                   DISPATCH_PROC_EXIT, WCVKQueue());
    if (!src) { t.pid = 0; t.src = nil; return; }
    unsigned gen = t.gen;
    __weak WCVKTarget *wt = t;
    dispatch_source_set_event_handler(src, ^{
        WCVKTarget *st = wt;
        if (!st || st.gen != gen) return;
        // 纯事件驱动：任何退出 -> 固定 1s 立刻拉起（短命只做日志统计，绝不改延迟）
        time_t life = (st.armedAt > 0) ? (time(NULL) - st.armedAt) : -1;
        if (!WCVKIsKbd(st) && life >= 0 && life < kShortLifeSec) {
            st.shortLives++;
            LOG(@"### %@ (pid=%d) 退出（只活了 %lds，累计短命 %d 次）-> %ds 后立刻拉起",
                st.display, st.pid, (long)life, st.shortLives, kRelaunchDelaySec);
        } else if (st.shortLives > 0) {
            LOG(@"### %@ 这次活了 %lds -> 短命计数清零（原连击 %d 次）",
                st.display, (long)life, st.shortLives);
            st.shortLives = 0;
        }
        st.armedAt = 0;
        st.pid = 0;                               // 缓存失效
        if (st.src) { dispatch_source_cancel(st.src); st.src = nil; }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kRelaunchDelaySec * NSEC_PER_SEC)),
                       WCVKQueue(), ^{
            if (!WCVKTargetValid(st, gen)) return;
            WCVKDoRelaunch(st, gen);               // ★ 只拉起；挂监视交给校验/kbd.up，不再重复
            // ★ 兜底（鲁棒性）：如果这次拉起被冷却挡掉了，旧监视已取消、又没人重挂，
            //   这个 target 会永久收不到退出事件。2s 后仅当「仍无监视」才启动挂监视重试；
            //   正常路径 1.5s 校验已挂上 src，这里直接 return，零额外扫描。
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)),
                           WCVKQueue(), ^{
                if (!WCVKTargetValid(st, gen) || st.src) return;
                LOG(@"%@ 退出后仍无监视 -> 启动挂监视兜底", st.display);
                WCVKArmRetry(st, gen, 0);
            });
        });
    });
    t.src = src;
    t.armedGen = gen;
    dispatch_resume(src);
    // 键盘重新挂上监视 = 上次拉起已成功 -> 清 3s 防抖，下次退出立刻处理
    if (WCVKIsKbd(t)) t.lastRelaunch = 0;
    LOG(@"watch ARMED: %@ (pid=%d)", t.display, pid);
}

// 挂监视重试链（只在「没有拉起链在跑」时才启动，避免两套链并发重复拉起）
static void WCVKArmRetry(WCVKTarget *t, unsigned gen, int attempt) {
    // 已有监视就别再挂；拉起链自己会挂，这里不并发抢
    if (!WCVKTargetValid(t, gen) || t.relaunching || t.src) return;
    if (attempt >= (int)(sizeof(kArmRetrySecs) / sizeof(kArmRetrySecs[0]))) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kArmRetrySecs[attempt] * NSEC_PER_SEC)),
                   WCVKQueue(), ^{
        if (!WCVKTargetValid(t, gen) || t.relaunching || t.src) return;
        WCVKResolvePids(@[t], ^(NSArray<NSNumber *> *pids) {
            if (!WCVKTargetValid(t, gen)) return;
            int pid = pids.firstObject.intValue;
            if (pid > 0) WCVKArmPid(t, pid);
            else WCVKArmRetry(t, gen, attempt + 1);
        });
    });
}

static void WCVKArmTarget(WCVKTarget *t, unsigned gen, int attempt) {
    if (!WCVKTargetValid(t, gen)) return;
    WCVKResolvePids(@[t], ^(NSArray<NSNumber *> *pids) {
        if (!WCVKTargetValid(t, gen)) return;
        int pid = pids.firstObject.intValue;
        if (pid > 0) WCVKArmPid(t, pid);
        else WCVKArmRetry(t, gen, attempt);
    });
}

// ===== 拉起 =====
static void WCVKRelaunchAttempt(WCVKTarget *t, int attempt, unsigned gen) {
    if (!WCVKTargetValid(t, gen)) return;
    t.relaunching = YES;
    NSString *ident = t.ident;
    NSString *disp = t.display ?: t.ident;
    NSString *kind = t.kind;

    // ★ 同步 Mach IPC 搬到 gLaunchQueue，不占事件队列（SpringBoard 忙时不会拖住退出事件）
    dispatch_async(WCVKLaunchQueue(), ^{
        int r = WCVKHeadlessLaunch(ident);
        LOG(@"headless launch %@ rc=%d (attempt %d)", ident, r, attempt);
    });

    // 结果一律以「进程真实存在」为准，不信 API 返回值
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kVerifyDelayMs * NSEC_PER_MSEC)),
                   WCVKQueue(), ^{
        if (!WCVKTargetValid(t, gen)) return;
        WCVKResolvePids(@[t], ^(NSArray<NSNumber *> *pids) {
            if (!WCVKTargetValid(t, gen)) return;
            int pid = pids.firstObject.intValue;
            if (pid > 0) {
                t.fails = 0;
                t.lastRelaunch = 0;
                t.relaunching = NO;
                WCVKRecord(disp, ident, kind, YES,
                           [NSString stringWithFormat:@"后台拉起成功 (pid=%d)", pid]);
                WCVKArmPid(t, pid);               // ★ 唯一一次挂监视
                return;
            }
            int retries = (int)(sizeof(kAppRetryDelay) / sizeof(kAppRetryDelay[0]));
            if (attempt < retries) {
                int d = kAppRetryDelay[attempt];
                LOG(@"%@ 未起来 -> %ds 后重试", disp, d);
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(d * NSEC_PER_SEC)),
                               WCVKQueue(), ^{
                    if (WCVKTargetValid(t, gen)) WCVKRelaunchAttempt(t, attempt + 1, gen);
                });
                return;
            }
            t.fails++;
            t.relaunching = NO;
            // 熔断只对 App：键盘扩展是必需项，永不熔断、永不因失败停看护（老板 2026-11-07）
            if (!WCVKIsKbd(t) && t.fails >= kFuseFailLimit) {
                t.disabled = YES;
                LOG(@"%@ 连续失败 %d 次 -> 熔断，停止看护（改设置后恢复）", disp, t.fails);
                WCVKRecord(disp, ident, kind, NO,
                           [NSString stringWithFormat:@"连续失败 %d 次，已暂停保活（改设置后恢复）", t.fails]);
                WCVKStopTarget(t);
                return;
            }
            WCVKRecord(disp, ident, kind, NO,
                       [NSString stringWithFormat:@"后台拉起失败（已重试 %d 次）", retries]);
        });
    });
}

static void WCVKDoRelaunch(WCVKTarget *t, unsigned gen) {
    time_t now = time(NULL);
    int cooldown = WCVKIsKbd(t) ? kKbdDebounceSec : kFailCooldownSec;
    if (t.lastRelaunch && now - t.lastRelaunch < cooldown) {
        LOG(@"%@ 冷却中（%lds 前刚处理过，冷却 %ds），跳过", t.display,
            (long)(now - t.lastRelaunch), cooldown);
        return;
    }
    t.lastRelaunch = now;

    if (WCVKIsKbd(t)) {
        // 键盘扩展没有别的门路：让 SpringBoard 弹一次键盘，系统才会 spawn 它
        notify_post("com.wcvoicekeep.kbd.warmup");
        NSString *disp = t.display ?: @"键盘";
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kVerifyDelayMs * NSEC_PER_MSEC)),
                       WCVKQueue(), ^{
            if (!WCVKTargetValid(t, gen)) return;
            WCVKResolvePids(@[t], ^(NSArray<NSNumber *> *pids) {
                if (!WCVKTargetValid(t, gen)) return;
                int pid = pids.firstObject.intValue;
                if (pid > 0) {
                    WCVKRecord(disp, @"wxkb_plugin", @"kbd", YES,
                               [NSString stringWithFormat:@"键盘扩展已拉起 (pid=%d)", pid]);
                    WCVKArmPid(t, pid);
                } else {
                    // ★ 键盘不熔断、不累计 fails、不停看护：只记一条，下次退出事件照常再拉
                    WCVKRecord(disp, @"wxkb_plugin", @"kbd", NO, @"键盘预热已发出但扩展未起来");
                    LOG(@"%@ 键盘扩展未起来（不熔断，等下次事件）", disp);
                }
            });
        });
        return;
    }
    WCVKRelaunchAttempt(t, 0, gen);
}

// ===== 按当前设置重建目标表 =====
static void WCVKRebuildTargets(void) {
    if (!gTargets) gTargets = [NSMutableArray array];

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
        t.display = meta[@"display"] ?: bid;   // 解析不到也照常保活（只认 bundle id）
        t.kind = @"app";
        t.exeSuffix = meta[@"exeSuffix"];
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
            exist.gen++;                       // 作废所有旧异步回调（精准命中）
            exist.relaunching = NO;
            exist.disabled = NO;              // 键盘永远 NO；App 改设置后恢复
            exist.fails = 0;
            [merged addObject:exist];
        } else {
            [merged addObject:n];
        }
    }
    gTargets = merged;
    LOG(@"targets 重建：共 %lu 个（键盘扩展 + App %lu）",
        (unsigned long)gTargets.count, (unsigned long)(gTargets.count ? gTargets.count - 1 : 0));

    // v2.0.7：重建时目标不在运行就必须主动拉起（否则没有退出事件，永远等不到触发点）
    for (WCVKTarget *t in gTargets) {
        if (WCVKIsKbd(t)) continue;            // 键盘那条链是好的，不碰
        if (t.disabled || t.pid > 0 || t.src || t.lastRelaunch) continue;
        LOG(@"%@ 重建时不在运行 -> 主动后台拉起", t.display);
        WCVKDoRelaunch(t, t.gen);
    }

    // ★ 一次批量解析所有目标（原来每个 target 各扫一遍进程表）；
    //   正在拉起的 target 跳过（它的 1.5s 校验会自己解析），避免重复扫描。
    NSArray<WCVKTarget *> *snapshot = [gTargets copy];
    NSMutableArray<NSNumber *> *gens = [NSMutableArray arrayWithCapacity:snapshot.count];
    for (WCVKTarget *t in snapshot) [gens addObject:@(t.gen)];
    NSMutableArray *toResolve = [NSMutableArray array];
    NSMutableIndexSet *skip = [NSMutableIndexSet indexSet];
    for (NSUInteger i = 0; i < snapshot.count; i++) {
        if (snapshot[i].relaunching) [skip addIndex:i];
        else [toResolve addObject:snapshot[i]];
    }
    if (!toResolve.count) return;
    WCVKResolvePids(toResolve, ^(NSArray<NSNumber *> *pids) {
        NSUInteger k = 0;
        for (NSUInteger i = 0; i < snapshot.count; i++) {
            if ([skip containsIndex:i]) continue;
            WCVKTarget *t = snapshot[i];
            int pid = (k < pids.count) ? pids[k++].intValue : 0;
            unsigned gen = gens[i].unsignedValue;
            if (!WCVKTargetValid(t, gen)) continue;   // 重建/取消/关闭后旧结果一律作废
            if (pid > 0) WCVKArmPid(t, pid);
            else WCVKArmRetry(t, gen, 0);
        }
    });
}

// ===== 设置热生效 =====
static void WCVKArmPrefsWatch(void);
static void WCVKHandlePrefsChanged(void);
static NSMutableArray *gPrefsSources = nil;

static void WCVKHandlePrefsChanged(void) {
    if (!WCVKReadPrefs()) {                    // 值没变就跳过重建（系统级广播很杂）
        LOG(@"prefs 通知：值与当前一致，跳过重建");
        return;
    }
    LOG(@"prefs 变更 -> 重建目标");
    WCVKRebuildTargets();
}

static void WCVKArmPrefsWatch(void) {
    // 重挂前先取消旧的，避免目录 rename 后叠加出多个监听
    if (!gPrefsSources) gPrefsSources = [NSMutableArray array];
    for (dispatch_source_t s in gPrefsSources) dispatch_source_cancel(s);
    [gPrefsSources removeAllObjects];

    int armed = 0;
    for (NSString *dir in WCVKPrefsDirCandidates()) {
        int fd = open([dir fileSystemRepresentation], O_RDONLY);
        if (fd < 0) continue;
        dispatch_source_t src = dispatch_source_create(DISPATCH_SOURCE_TYPE_VNODE, (uintptr_t)fd,
            DISPATCH_VNODE_WRITE | DISPATCH_VNODE_RENAME | DISPATCH_VNODE_DELETE,
            WCVKQueue());
        if (!src) { close(fd); continue; }
        armed++;
        NSString *dirPath = [dir copy];
        __block time_t lastM = 0;
        NSDictionary *a = [[NSFileManager defaultManager]
            attributesOfItemAtPath:[dirPath stringByAppendingFormat:@"/%@.plist", kPrefsDomain] error:nil];
        if (a) lastM = (time_t)[a[NSFileModificationDate] timeIntervalSince1970];

        dispatch_source_set_event_handler(src, ^{
            unsigned long flags = dispatch_source_get_data(src);
            if (flags & (DISPATCH_VNODE_DELETE | DISPATCH_VNODE_RENAME)) {
                // cfprefsd 原子替换目录会踢掉 fd：延迟 1s 全部重挂（鲁棒性）
                LOG(@"prefs 目录 %@ 被 rename/delete -> 重挂 VNODE", dirPath);
                dispatch_source_cancel(src);
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)),
                               WCVKQueue(), ^{ WCVKArmPrefsWatch(); });
                return;
            }
            NSString *p = [dirPath stringByAppendingFormat:@"/%@.plist", kPrefsDomain];
            NSDictionary *attr = [[NSFileManager defaultManager] attributesOfItemAtPath:p error:nil];
            if (!attr) return;
            time_t m = (time_t)[attr[NSFileModificationDate] timeIntervalSince1970];
            if (m == lastM) return;           // 目录里任何写入都会唤醒，只看我们自己的 plist
            lastM = m;
            WCVKHandlePrefsChanged();
        });
        dispatch_source_set_cancel_handler(src, ^{ close(fd); });
        [gPrefsSources addObject:src];
        dispatch_resume(src);
    }
    LOG(@"prefs watch armed on %d 个目录", armed);
}

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
        gPrefsDirCached = nil;
        WCVKHandlePrefsChanged();
    });
}

static void WCVKRegisterPrefsNotify(void) {
    notify_register_dispatch("com.wcvoicekeep.prefs.changed", &gPrefsNotifySelf,
                             WCVKQueue(), ^(int t) { WCVKSchedulePrefsReload("self"); });
    notify_register_dispatch("com.apple.preferences-changed", &gPrefsNotifySys,
                             WCVKQueue(), ^(int t) { WCVKSchedulePrefsReload("system"); });
    LOG(@"prefs notify registered (self + system)");
}

// ===== 键盘扩展拉起成功：SpringBoard 把新 pid 放进 notify state 直接递过来 =====
static int gKbdUpToken = 0;
static void WCVKRegisterKbdUp(void) {
    notify_register_dispatch("com.wcvoicekeep.kbd.up", &gKbdUpToken, WCVKQueue(), ^(int token) {
        uint64_t state = 0;
        if (notify_get_state(token, &state) != 0) state = 0;
        int pid = (int)state;
        for (WCVKTarget *t in gTargets) {
            if (!WCVKIsKbd(t)) continue;
            if (pid > 1 && WCVKValidatePid(t, pid)) {
                LOG(@"kbd.up state pid=%d -> 直接挂监视（零全表扫描）", pid);
                WCVKArmPid(t, pid);           // 同 pid 已挂时 ArmPid 自己会 return
            } else {
                LOG(@"kbd.up state 无效(%d) -> 回退一次解析", pid);
                WCVKArmTarget(t, t.gen, 0);
            }
            break;
        }
    });
}

// ===== 子命令 =====
static void WCVKPrintStatus(void) {
    WCVKReadPrefs();
    printf("prefs   : %s\n", WCVKPrefsPath().UTF8String);
    printf("records : %s\n", WCVKRecordsPath().UTF8String);
    printf("enabled=%d logging=%d record=%d\n", gEnabled, gLogging, gRecord);

    // 一次批量扫描搞定所有目标（子命令是独立进程，直接走同步版）
    NSMutableArray *ts = [NSMutableArray array];
    WCVKTarget *k = [WCVKTarget new]; k.kind = @"kbd"; k.ident = @"wxkb_plugin";
    [ts addObject:k];
    for (NSString *bid in gAppBIDs) {
        WCVKTarget *t = [WCVKTarget new]; t.kind = @"app"; t.ident = bid;
        [ts addObject:t];
    }
    int n = (int)ts.count;
    WCVKScanSpec *specs = (WCVKScanSpec *)calloc((size_t)n, sizeof(WCVKScanSpec));
    int *pids = (int *)calloc((size_t)n, sizeof(int));
    for (int i = 0; i < n; i++) {
        WCVKTarget *t = ts[i];
        if (WCVKIsKbd(t)) specs[i].isKbd = YES;
        else specs[i].needleLen = WCVKFillNeedle(specs[i].needle, sizeof(specs[i].needle), t.ident);
    }
    WCVKScanTargetsSync(specs, n, pids);
    printf("  [kbd] wxkb_plugin pid=%d\n", pids[0]);
    for (int i = 1; i < n; i++) {
        NSString *bid = ((WCVKTarget *)ts[i]).ident;
        NSDictionary *m = WCVKAppMeta(bid);
        printf("  [app] %-34s %-14s pid=%-6d exe=%s\n", bid.UTF8String,
               [(m[@"display"] ?: bid) UTF8String], pids[i],
               [(m[@"exeSuffix"] ?: @"(解析失败, 仍按 bid 保活)") UTF8String]);
    }
    free(specs); free(pids);

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
                dispatch_sync(WCVKRecordQueue(), ^{});   // 等记录落盘再退出
                printf("headless launch %s -> %d (0=ok)\n", argv[i + 1], r);
                return 0;
            }
            if (strcmp(argv[i], "--ls-probe") == 0) {
                WCVKEnsureLSLoaded();
                Class P = NSClassFromString(@"LSApplicationProxy");
                Class WS = NSClassFromString(@"LSApplicationWorkspace");
                printf("LSApplicationProxy=%s LSApplicationWorkspace=%s\n", P ? "yes" : "no", WS ? "yes" : "no");
                const char *sels[] = {"applicationProxyForIdentifier:",
                                      "applicationProxyForBundleIdentifier:",
                                      "applicationProxyForBundleID:",
                                      "allApplications", "defaultWorkspace"};
                for (unsigned k = 0; k < sizeof(sels) / sizeof(sels[0]); k++) {
                    SEL s2 = sel_registerName(sels[k]);
                    printf("  +[LSApplicationProxy      %-38s] %d\n", sels[k],
                           (P && [(id)P respondsToSelector:s2]) ? 1 : 0);
                    printf("  -[LSApplicationWorkspace  %-38s] %d\n", sels[k],
                           (WS && [WS instancesRespondToSelector:s2]) ? 1 : 0);
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
        WCVKRegisterPrefsNotify();
        WCVKArmPrefsWatch();
        LOG(@"daemon ready: 事件驱动看护中（缓存优先，常态零全表扫描）");

        dispatch_main();
    }
    return 0;
}
