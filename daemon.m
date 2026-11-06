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

static NSString *WCVKExistingPrefsDir(void) {
    static NSString *cached = nil;
    if (cached) return cached;
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
    cached = best;
    return cached;
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

static void WCVKReadPrefs(void) {
    NSString *p = WCVKPrefsPath();
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:p];
    if (!d) {
        for (NSString *dir in WCVKPrefsDirCandidates()) {
            NSDictionary *t = [NSDictionary dictionaryWithContentsOfFile:
                               [dir stringByAppendingFormat:@"/%@.plist", kPrefsDomain]];
            if (t) { d = t; break; }
        }
    }
    id en = d[@"enabled"];
    gEnabled = en ? [en boolValue] : YES;
    id lg = d[@"logging"];
    gLogging = lg ? [lg boolValue] : NO;
    id rec = d[@"record"];
    gRecord = rec ? [rec boolValue] : YES;
    id apps = d[@"enabledApps"];
    NSMutableArray *bids = [NSMutableArray array];
    if ([apps isKindOfClass:[NSArray class]]) {
        for (id b in apps) {
            if ([b isKindOfClass:[NSString class]] && [b length]) [bids addObject:b];
        }
    }
    gAppBIDs = bids;
    LOG(@"prefs loaded (%@): enabled=%d logging=%d apps=%@", p, gEnabled, gLogging, gAppBIDs);
}

// ===== 拉起记录（纯净版也写；设置页「拉起记录」读它）=====
static void WCVKRecord(NSString *display, NSString *ident, NSString *kind, BOOL ok, NSString *detail) {
    // 记录开关关掉时**直接返回**：不读文件、不写文件，零 syscall、零 CPU
    if (!gRecord) return;
    NSString *path = WCVKRecordsPath();
    id old = [NSArray arrayWithContentsOfFile:path];
    NSMutableArray *arr = [old isKindOfClass:[NSArray class]] ? [old mutableCopy] : [NSMutableArray array];
    NSMutableDictionary *row = [NSMutableDictionary dictionary];
    row[@"t"] = [NSDate date];
    row[@"name"] = display ?: ident ?: @"?";
    row[@"bid"] = ident ?: @"";
    row[@"kind"] = kind ?: @"app";
    row[@"ok"] = @(ok);
    if (detail.length) row[@"detail"] = detail;
    [arr insertObject:row atIndex:0];
    while (arr.count > 60) [arr removeLastObject];
    if (![arr writeToFile:path atomically:YES]) {
        NSString *alt = @"/var/mobile/wcvoicekeep.records.plist";
        [arr writeToFile:alt atomically:YES];
        LOG(@"record write fallback -> %@", alt);
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

// ===== App 可执行文件 / 显示名解析（LaunchServices）=====
static void WCVKEnsureLSLoaded(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dlopen("/System/Library/Frameworks/MobileCoreServices.framework/MobileCoreServices", RTLD_LAZY);
        dlopen("/System/Library/PrivateFrameworks/LaunchServices.framework/LaunchServices", RTLD_LAZY);
    });
}

static NSDictionary *WCVKAppMeta(NSString *bid) {
    WCVKEnsureLSLoaded();
    Class WS = NSClassFromString(@"LSApplicationWorkspace");
    if (!WS) return nil;
    id ws = nil, proxy = nil;
    @try {
        ws = ((id (*)(id, SEL))objc_msgSend)((id)WS, sel_registerName("defaultWorkspace"));
        if (ws) proxy = ((id (*)(id, SEL, id))objc_msgSend)(ws,
                            sel_registerName("applicationProxyForIdentifier:"), bid);
    } @catch (NSException *e) {}
    if (!proxy) return nil;

    NSString *exe = nil, *appDir = nil, *name = nil;
    @try { exe = ((id (*)(id, SEL))objc_msgSend)(proxy, sel_registerName("bundleExecutable")); } @catch (NSException *e) {}
    @try {
        NSURL *u = ((id (*)(id, SEL))objc_msgSend)(proxy, sel_registerName("bundleURL"));
        appDir = u.lastPathComponent;
    } @catch (NSException *e) {}
    @try {
        NSDictionary *d2 = ((id (*)(id, SEL))objc_msgSend)(proxy, sel_registerName("localizedInfoDictionary"));
        name = d2[@"CFBundleDisplayName"] ?: d2[@"CFBundleName"];
    } @catch (NSException *e) {}
    if (!name) {
        @try { name = ((id (*)(id, SEL))objc_msgSend)(proxy, sel_registerName("localizedName")); } @catch (NSException *e) {}
    }
    if (![exe isKindOfClass:[NSString class]] || ![appDir isKindOfClass:[NSString class]]) return nil;
    return @{ @"exeSuffix": [NSString stringWithFormat:@"/%@/%@", appDir, exe],
              @"display": [name isKindOfClass:[NSString class]] ? name : bid };
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
static const int  kFailCooldownSec  = 45;    // 拉起失败后冷却，避免死循环
static const int  kArmRetrySecs[]   = {2, 5, 10, 20, 40};  // 拉起后找 pid 挂监视的重试点

@interface WCVKTarget : NSObject
@property (nonatomic, copy)   NSString *ident;      // bundle id 或 "wxkb_plugin"
@property (nonatomic, copy)   NSString *display;    // 显示名（写记录用）
@property (nonatomic, copy)   NSString *kind;       // @"kbd" / @"app"
@property (nonatomic, copy)   NSString *exeSuffix;  // App 精确匹配后缀
@property (nonatomic, assign) int pid;
@property (nonatomic, assign) time_t lastRelaunch;
@property (nonatomic, assign) int fails;
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

static int WCVKTargetPid(WCVKTarget *t) {
    if ([t.kind isEqualToString:@"kbd"])
        return WCVKPidForPathSuffix([NSString stringWithUTF8String:kKbdExtSuffix], nil);
    return WCVKPidForPathSuffix(t.exeSuffix, nil);
}

static void WCVKDoRelaunch(WCVKTarget *t) {
    time_t now = time(NULL);
    if (t.lastRelaunch && now - t.lastRelaunch < kFailCooldownSec) {
        LOG(@"%@ 冷却中（%lds 前刚处理过），跳过", t.display, (long)(now - t.lastRelaunch));
        return;
    }
    t.lastRelaunch = now;

    if ([t.kind isEqualToString:@"kbd"]) {
        // 键盘扩展没有别的门路：只能让 SpringBoard 弹一次键盘，系统才会 spawn 它
        uint32_t st = notify_post("com.wcvoicekeep.kbd.warmup");
        LOG(@"kbd warmup notify posted -> %u", st);
        WCVKRecord(t.display, t.ident, t.kind, st == 0, @"键盘预热请求已发出");
        return;
    }
    int r = WCVKHeadlessLaunch(t.ident);
    BOOL ok = (r == 0);
    if (ok) {
        t.fails = 0;
        t.lastRelaunch = 0;              // 成功立刻清冷却
    } else {
        t.fails++;
    }
    WCVKRecord(t.display, t.ident, t.kind, ok,
               ok ? @"后台拉起成功" : [NSString stringWithFormat:@"后台拉起失败 rc=%d", r]);
}

// 在 pid 上挂退出事件；进程一死内核回调（零轮询）
static void WCVKArmPid(WCVKTarget *t, int pid) {
    if (t.src) { dispatch_source_cancel(t.src); t.src = nil; }
    if (pid <= 0) return;
    t.pid = pid;
    dispatch_source_t src = dispatch_source_create(DISPATCH_SOURCE_TYPE_PROC, (uintptr_t)pid,
                                                   DISPATCH_PROC_EXIT, WCVKQueue());
    if (!src) return;
    __weak WCVKTarget *wt = t;
    dispatch_source_set_event_handler(src, ^{
        WCVKTarget *st = wt;
        if (!st) return;
        LOG(@"### %@ (pid=%d) EXIT EVENT -> %ds 后拉起", st.display, st.pid, kRelaunchDelaySec);
        st.pid = 0;
        if (st.src) { dispatch_source_cancel(st.src); st.src = nil; }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kRelaunchDelaySec * NSEC_PER_SEC)),
                       WCVKQueue(), ^{
            WCVKDoRelaunch(st);
            WCVKArmTarget(st, 0);   // 拉起后重新挂监视
        });
    });
    t.src = src;
    dispatch_resume(src);
    LOG(@"watch ARMED: %@ (pid=%d)", t.display, pid);
}

static void WCVKArmTarget(WCVKTarget *t, int attempt) {
    int pid = WCVKTargetPid(t);
    if (pid > 0) { WCVKArmPid(t, pid); return; }
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
        t.display = meta[@"display"] ?: bid;
        t.kind = @"app";
        t.exeSuffix = meta[@"exeSuffix"];
        if (!t.exeSuffix) { LOG(@"skip %@：解析不到可执行路径", bid); continue; }
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
        if (exist) { exist.display = n.display; exist.exeSuffix = n.exeSuffix; [merged addObject:exist]; }
        else       { [merged addObject:n]; }
    }
    gTargets = merged;

    LOG(@"targets 重建：共 %lu 个（键盘扩展 + App %lu）",
        (unsigned long)gTargets.count, (unsigned long)(gTargets.count ? gTargets.count - 1 : 0));
    for (WCVKTarget *t in gTargets) {
        if (t.src && t.pid > 0 && WCVKTargetPid(t) == t.pid) continue;
        WCVKArmTarget(t, 0);
    }
}

// ===== 设置热生效：VNODE 监听 Preferences 目录，不轮询 =====
static void WCVKArmPrefsWatch(void);
static void WCVKHandlePrefsChanged(void);

static void WCVKHandlePrefsChanged(void) {
    LOG(@"prefs 变更 -> 重读并重建目标");
    WCVKReadPrefs();
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
        int pid = m ? WCVKPidForPathSuffix(m[@"exeSuffix"], nil) : 0;
        printf("  [app] %-34s %-14s pid=%d\n", bid.UTF8String,
               [(m[@"display"] ?: @"?") UTF8String], pid);
    }
    NSArray *recs = [NSArray arrayWithContentsOfFile:WCVKRecordsPath()];
    printf("records count=%lu\n", (unsigned long)recs.count);
    for (NSUInteger i = 0; i < recs.count && i < 10; i++) {
        NSDictionary *r = recs[i];
        printf("  %s  %s  %s  %s\n",
               [[r[@"t"] description] UTF8String] ?: "-",
               [r[@"name"] UTF8String] ?: "-",
               [r[@"ok"] boolValue] ? "OK" : "FAIL",
               [r[@"detail"] UTF8String] ?: "");
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
        WCVKArmPrefsWatch();
        LOG(@"daemon ready: 事件驱动看护中（零轮询）");

        dispatch_main();
    }
    return 0;
}
