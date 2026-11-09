// wcvoicekeep daemon — v2.0.37「回退 v2.0.36 死因探测，恢复 v2.0.35 基线」
//
// ===== v2.0.37（老板 2026-11-09 定案）=====
//  v2.0.36 试做的「内核退出原因（proc_pidinfo flavor 24/25）」实机读不到，整段回退。
//  实机证据：--probe-exit 自造僵尸能读到 ns=2 code=9（API/权限/结构都对），
//  但真实 App 的 DISPATCH_PROC_EXIT 回调一律 errno=3(ESRCH，launchd 已 reap 僵尸)
//  或 errno=13(EACCES，跨 uid 被 CHECK_SAME_USER 拒) -> 记录恒为「未知」。
//  替代信号源 JetsamEvent-*.ips 只在真实内存事件时落盘、需目录监听 + 解析大 JSON +
//  处理时序竞态，不够简单可靠，按「复杂就算了」放弃。
//  本版代码与 v2.0.35 完全一致，仅版本号顺延便于和手机上旧 deb 区分；记录开关关闭
//  仍是零写入、零额外 syscall。
//
// ===== v2.0.35（老板 2026-11-09 定案）=====
//  修 v2.0.34 回归：设置页取消勾选 App（如 WeType）后 daemon 仍按旧列表拉起。
//  根因：设置页（mobile / CurrentUser 域）写 /var/mobile/Library/Preferences/...，
//  daemon（root）却用 kCFPreferencesAnyUser 读 /private/var/preferences/... 另一份快照；
//  v2.0.34 的卸载清理往该域写过一次 enabledApps 后 viaCF 恒为 YES，文件再也不被读。
//  ① WCVKReadPrefs：文件里存在的键一律以文件为准，AnyUser 域只在缺键时兜底；
//  ② 启动时 WCVKClearLegacyAnyUserApps() 删掉 AnyUser 域那个 enabledApps 僵尸键；
//  ③ 卸载清理只写 plist 文件（三份候选含设置页那份），不再写 AnyUser 域；
//  ④ 键盘 wxkb_plugin 是硬编码 target、不依赖 enabledApps，仍然必拉且永不熔断。
//
// ===== v2.0.34（老板 2026-11-09 定案）=====
//  ① 已卸载的 bundle ID 自动从 prefs 剔除并写回（LaunchServices 解析不到即视为卸载，
//     有「本次至少有一个其它 App 能解析」保护，开机早期 LS 未就绪绝不误删）。
//  ② 监听 SpringBoard 进程退出 = 用户空间重启/注销：清掉所有 target 的 fails/disabled/
//     shortLives/短命冷却/pid 缓存（熔断解除），并按优先级错峰重新拉起。
//  ③ 开机 / 注销统一走「启动序列」：键盘 → 5s → 微信 → 5s → 其它 App（每个 5s），
//     已在运行的只挂监视不拉起，不同时冷启动多个 App（避免内存峰值被 jetsam 立刻杀掉）。
//  ④ 短命连击抑制：同一 App 连续 3 次在 60s 内被杀 -> 暂停 60s 再拉起（在
//     v2.0.33「键盘 1s / App 5s」之上唯一的额外等待；正常路径一个数没动。
//  ⑤ 键盘多阶段确认（1.5/4/8s，4s 未起补发一次 warmup）+ kbd.up 迟到补写成功记录 +
//     SpringBoard 注入端就绪通知（com.wcvoicekeep.sb.ready）触发补发预热，
//     解决「注销后提示拉起失败、实际稍后才起来」。
//  ⑥ 常态依然事件驱动：只看内核进程退出事件，无轮询、无心跳，CPU 占用为 0。
//
// 职责（老板 2026-11-07 定案）：本工程**不再注入任何 App 进程**，daemon 只做两件事：
//   1) 键盘扩展 wxkb_plugin —— 必须保活（不可关闭、永不熔断）。它一退出，发 Darwin 通知
//      请 SpringBoard 弹一下键盘，系统才会重新 spawn 它。
//   2) 用户勾选的 App —— 被杀后在**后台**无头拉起（SBSLaunchApplicationWithIdentifier
//      flag=Background，不切前台）。
//   每次拉起写一条记录（log/pure 都写，受设置里的记录开关控制）。
//
// ★ 拉起语义（老板 2026-11-07 定案）：
//   键盘扩展 EXIT -> 固定 1s 立刻拉起（输入法必需项，不引入任何指数退避）；
//   用户勾选的 App EXIT -> 5s 后再拉（v2.0.33 新增，见下方说明）；
//   键盘 3s 防抖、App 失败 15s 冷却、连续 3 次失败熔断（**键盘豁免**）、
//   拉起后 1.5s 按真实 pid 校验、失败按 5s/15s 重试两次、挂监视重试 2/5/10/20/40s。
//
// ===== v2.0.33：用户勾选的 App 退出后等 5s 再拉（老板 2026-11-07）=====
//   原来 EXIT 事件固定 1s 拉起（键盘/App 共用 kRelaunchDelaySec）。现在拆成两档：
//     · App  -> kAppRelaunchDelaySec = 5，退出后等 5s 才 SBSLaunch；
//     · 键盘 -> 仍 1s 不变（wxkb_plugin 是输入法必需项，慢 5s 键盘就等于废了）。
//   只改「退出事件 -> 拉起」这一个等待；15s 冷却 / 熔断 / 1.5s 校验 /
//   5s·15s 重试 / 挂监视重试链一个数没动。
//   daemon 启动 / 设置重建时「目标不在运行主动补拉」不走 EXIT 事件，也不延迟。
//   5s 等待期间若设置里取消勾选或改了 gen，WCVKTargetValid 会直接作废回调，不会误拉。
//
// ===== v2.0.32：拉起记录改写到固定 /var/mobile（老板 2026-11-07）=====
//   旧实现用 WCVKExistingPrefsDir() 推导记录路径，实机选中的是
//   <jbroot>/var/mobile/Library/Preferences/... —— roothide 随机串会变，且设置页
//   读的是原生 /var/mobile，永远看不到它；设置页再退回 cfprefsd 僵尸缓存，
//   于是「记录停在 4:16:48 再不更新」。现在 daemon 固定写 /var/mobile/wcvoicekeep.records.plist，
//   设置页同路径读 + 按 mtime 取最新 + 不再回退 cfprefsd。拉起语义一个数没动。
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

// WCVKReadPrefs 里的「已剔除 ID 复检」要用，定义在后面
static NSDictionary *WCVKAppMeta(NSString *bid);

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

static NSString *const kLogPath       = @"/var/mobile/wcvoicekeep.daemon.log";
static NSString *const kPrefsDomain   = @"com.wcvoicekeep.bgkeep";
// v2.0.32（老板 2026-11-07）：记录文件**只写固定的 /var/mobile**，绝不写进 jbroot。
// roothide 的 .jbroot-XXXX 随机串每次 bootstrap 都可能变，写进去换环境就丢；
// 而且设置页读的是原生 /var/mobile —— 写在 jbroot 里它根本看不见，
// 这正是「记录一直停在 4:16:48、后面再不更新」的根因。
// 放在 /var/mobile 根目录而非 Library/Preferences：不进 cfprefsd 监视目录，
// 写盘不会触发 com.apple.preferences-changed 广播 -> daemon 不会自己唤醒自己（零多余开销）。
static NSString *const kRecordsPath = @"/var/mobile/wcvoicekeep.records.plist";
static NSString *const kRecordsAlt  = @"/var/mobile/Library/Preferences/com.wcvoicekeep.bgkeep.records.plist";

// ===== v2.0.34 常量（放在文件前部：WCVKReadPrefs / 卸载清理也要用 kWeChatBID）=====
static NSString *const kWeChatBID      = @"com.tencent.xin";
static const int kBootStepIntervalSec   = 5;    // 开机/注销后每个目标之间固定间隔 5s
static const int kBootStartDelaySec     = 2;    // 序列起点：等 SpringBoard 注入端就绪
static const int kShortLifeBurstLimit   = 3;    // 连续短命 3 次触发抑制
static const int kShortLifeCooldownSec  = 60;   // 抑制时长；只作用于异常连击
static const int kKbdConfirmDelaysMs[]  = { 1500, 4000, 8000 };
static const int kSBWatchRetryMax       = 8;    // 开机早期找 SpringBoard 最多重试 8 次（3s 一次，非轮询）
// 已从 prefs 剔除的 ID：防 cfprefsd 旧内存快照回弹造成「反复剔除/反复写盘」。
// 只在 WCVKQueue 上读写；定义在文件前部（WCVKReadPrefs / 卸载清理都要用）。
static NSMutableSet<NSString *> *gPrunedBIDs = nil;

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
// ★ 固定路径，与 roothide 的 jbroot 完全解耦（不再经过 WCVKExistingPrefsDir 推导）。
//   prefs 开关仍从 WCVKExistingPrefsDir 读（那是 cfprefsd 写的地方，只读不受影响）。
static NSString *WCVKRecordsPath(void) {
    return kRecordsPath;
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

    // ===== v2.0.35：prefs 真值 = 设置页写的那份 plist =====
    //  设置页 / AltList 以 mobile 身份写 CurrentUser 域 ->
    //    /var/mobile/Library/Preferences/com.wcvoicekeep.bgkeep.plist
    //  daemon 以 root 跑，旧代码用 kCFPreferencesAnyUser 读的其实是
    //    /private/var/preferences/com.wcvoicekeep.bgkeep.plist —— 完全另一份独立快照。
    //  v2.0.34 的卸载清理往 AnyUser 域写过一次 enabledApps 之后 viaCF 恒为 YES，
    //  设置页再怎么勾/取消勾选 daemon 都看不见（老板 16:01 报「关掉 WeType 还被拉起」）。
    //  现在：文件里存在的键一律以文件为准；CF(AnyUser) 只在该键文件里读不到时兜底。
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:p];
    if (!d) {
        for (NSString *dir in WCVKPrefsDirCandidates()) {
            NSDictionary *t = [NSDictionary dictionaryWithContentsOfFile:
                               [dir stringByAppendingFormat:@"/%@.plist", kPrefsDomain]];
            if (t) { d = t; break; }
        }
    }

    id en   = (__bridge_transfer id)CFPreferencesCopyValue(CFSTR("enabled"),
              (__bridge CFStringRef)kPrefsDomain, kCFPreferencesAnyUser, kCFPreferencesAnyHost);
    id lg   = (__bridge_transfer id)CFPreferencesCopyValue(CFSTR("logging"),
              (__bridge CFStringRef)kPrefsDomain, kCFPreferencesAnyUser, kCFPreferencesAnyHost);
    id rec  = (__bridge_transfer id)CFPreferencesCopyValue(CFSTR("record"),
              (__bridge CFStringRef)kPrefsDomain, kCFPreferencesAnyUser, kCFPreferencesAnyHost);
    id apps = (__bridge_transfer id)CFPreferencesCopyValue(CFSTR("enabledApps"),
              (__bridge CFStringRef)kPrefsDomain, kCFPreferencesAnyUser, kCFPreferencesAnyHost);
    if (d[@"enabled"])     en   = d[@"enabled"];
    if (d[@"logging"])     lg   = d[@"logging"];
    if (d[@"record"])      rec  = d[@"record"];
    if (d[@"enabledApps"]) apps = d[@"enabledApps"];
    BOOL viaFile = (d != nil);

    gEnabled = en ? [en boolValue] : YES;
    gLogging = lg ? [lg boolValue] : NO;
    gRecord = rec ? [rec boolValue] : YES;

    NSMutableArray *bids = [NSMutableArray array];
    if ([apps isKindOfClass:[NSArray class]]) {
        if (!gPrunedBIDs) gPrunedBIDs = [NSMutableSet set];
        for (id b in apps) {
            if (![b isKindOfClass:[NSString class]] || ![b length]) continue;
            // v2.0.34：cfprefsd 可能还持有「已剔除」的旧快照。若这个 ID 现在又能解析到
            // （App 装回来了 / 用户重新勾选），就放它回来；否则一律忽略，防止反复写盘。
            if ([gPrunedBIDs containsObject:b]) {
                if (WCVKAppMeta(b)) {
                    [gPrunedBIDs removeObject:b];
                    LOG(@"prefs: %@ 重新可用 -> 恢复保活", b);
                } else continue;
            }
            if (![bids containsObject:b]) [bids addObject:b];
        }
    }
    gAppBIDs = bids;
    BOOL changed = (oldEnabled != gEnabled) || (oldLogging != gLogging) || (oldRecord != gRecord)
                   || ![oldBIDs isEqualToArray:gAppBIDs];
    (void)oldLogging;
    LOG(@"prefs loaded (source=%@): enabled=%d record=%d apps=%@ changed=%d",
        viaFile ? p : @"cfprefs/AnyUser兜底", gEnabled, gRecord, gAppBIDs, changed);
    return changed;
}

// ===== v2.0.35：清掉 v2.0.34 卸载清理误写进 AnyUser 域的 enabledApps 僵尸快照 =====
//  只删这一个键（enabled / record 不动），只在 daemon 启动时跑一次。
//  留着它虽然新的「文件优先」逻辑已不会再读，但 cfprefsd 内存里那份旧值仍可能
//  在文件暂时读不到时兜底回来，所以启动即根除，两套域从此不再打架。
static void WCVKClearLegacyAnyUserApps(void) {
    CFPreferencesSetValue(CFSTR("enabledApps"), NULL,
                          (__bridge CFStringRef)kPrefsDomain,
                          kCFPreferencesAnyUser, kCFPreferencesAnyHost);
    CFPreferencesSynchronize((__bridge CFStringRef)kPrefsDomain,
                             kCFPreferencesAnyUser, kCFPreferencesAnyHost);
    LOG(@"prefs: 已清除 AnyUser 域 legacy enabledApps 快照（设置页 plist = 唯一真值）");
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
        // 备用同样落在固定 /var/mobile，绝不回退到 jbroot 内部路径
        wrote = [out writeToFile:kRecordsAlt atomically:YES];
        if (wrote) writtenPath = kRecordsAlt;
        LOG(@"record write fallback -> %@ (%d)", kRecordsAlt, wrote);
    }
    if (wrote) {
        LOG(@"record write -> %@ rows=%lu", writtenPath, (unsigned long)arr.count);
        // 属主必须是 mobile（设置页要能读/清空）；已正确就不再 syscall
        struct stat sb;
        if (stat(writtenPath.fileSystemRepresentation, &sb) != 0 ||
            sb.st_uid != 501 || (sb.st_mode & 07777) != 0644) {
            chown(writtenPath.fileSystemRepresentation, 501, 501);
            chmod(writtenPath.fileSystemRepresentation, 0644);
        }
    } else {
        LOG(@"record write FAILED -> %@", path);
    }
}

static void WCVKRecord(NSString *display, NSString *ident, NSString *kind, BOOL ok, NSString *detail) {
    // 记录开关关掉时**直接返回**：不读文件、不写文件、不进队列，零 syscall、零 CPU
    if (!gRecord) return;
    NSString *path = WCVKRecordsPath();     // 固定 /var/mobile 路径，后台线程零共享状态
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

// ===== v2.0.34：已卸载 ID 自动剔除（老板 2026-11-09）=====
//  老板换装 CocoaTop（cn.zqbb... -> ru.domo...）后旧 ID 永久残留在 enabledApps，
//  AltList 里已卸载的条目不再显示、UI 上无法取消勾选，daemon 却每轮都按 bid 拉起 3 次。
//  这里在「建 target 之前」解析一次，解析不到的直接从列表剔除并写回 plist + cfprefsd。
//  ★ 防误删：开机早期 LaunchServices 可能整体不可用 —— 本次一个 App 都解析不到时
//    一律不剔除（序列结束后还会复查一次，那时 LS 必定就绪）。
//  ★ 只在 prefs 变更 / 开机 / 用户空间重启时执行，常态零 LaunchServices 调用、零 CPU。
static void WCVKPruneUninstalledBIDs(void) {
    if (!gAppBIDs.count) return;
    if (!gPrunedBIDs) gPrunedBIDs = [NSMutableSet set];

    NSMutableArray *missing = [NSMutableArray array];
    NSMutableArray *kept    = [NSMutableArray array];
    for (NSString *bid in gAppBIDs) {
        if (WCVKAppMeta(bid)) [kept addObject:bid];
        else [missing addObject:bid];
    }
    if (!missing.count) return;
    // 判据：本次有别的 App 能解析，或者系统自带的微信能解析 => LaunchServices 确实可用。
    // 开机早期 LS 整体不可用时（连微信都查不到）绝不误删用户勾选的 App。
    BOOL lsUsable = (kept.count > 0) || (WCVKAppMeta(kWeChatBID) != nil);
    if (!lsUsable) {
        LOG(@"卸载清理：%lu 个 ID 解析失败，但 LaunchServices 尚不可用（连微信都查不到）-> 不剔除",
            (unsigned long)missing.count);
        return;
    }

    LOG(@"卸载清理：自动剔除 %lu 个已卸载 ID：%@（保留 %lu 个）",
        (unsigned long)missing.count, missing, (unsigned long)kept.count);
    for (NSString *bid in missing) [gPrunedBIDs addObject:bid];
    gAppBIDs = [kept copy];

    // 写盘搬到串行后台队列，不占事件队列；三份候选都写，避免 cfprefsd 从另一份读回旧值。
    NSArray<NSString *> *snapshot = [kept copy];
    NSArray<NSString *> *dirs     = WCVKPrefsDirCandidates();
    dispatch_async(WCVKRecordQueue(), ^{
        for (NSString *dir in dirs) {
            NSString *p = [dir stringByAppendingFormat:@"/%@.plist", kPrefsDomain];
            NSMutableDictionary *d = [[NSDictionary dictionaryWithContentsOfFile:p] mutableCopy];
            if (!d) continue;
            NSArray *old = d[@"enabledApps"];
            if (![old isKindOfClass:[NSArray class]]) continue;
            NSMutableArray *fresh = [NSMutableArray array];
            for (id b in old)
                if ([b isKindOfClass:[NSString class]] && [snapshot containsObject:b]) [fresh addObject:b];
            if ([fresh isEqualToArray:old]) continue;
            d[@"enabledApps"] = fresh;
            if ([d writeToFile:p atomically:YES]) {
                // 设置页（mobile）要能继续写这个 plist
                struct stat st;
                if (stat(p.fileSystemRepresentation, &st) != 0 || st.st_uid != 501 ||
                    (st.st_mode & 07777) != 0644) {
                    chown(p.fileSystemRepresentation, 501, 501);
                    chmod(p.fileSystemRepresentation, 0644);
                }
                LOG(@"卸载清理：prefs 已写回 %@", p);
            }
        }
        // ⚠️ v2.0.35：这里**绝不写 AnyUser 域**。v2.0.34 曾在此用
        //    CFPreferencesSetValue(..., kCFPreferencesAnyUser, ...) 造出一份
        //    /private/var/preferences/ 下的独立快照，导致 daemon 与设置页各读一套，
        //    「取消勾选 App」永远不生效。设置页读的就是上面写回的 plist 文件，
        //    三份候选已覆盖它，无需再碰 cfprefsd 的另一域。
        //    历史遗留的那份快照由启动时 WCVKClearLegacyAnyUserApps() 清掉。
    });
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
static const int kRelaunchDelaySec    = 1;   // 键盘扩展 EXIT -> 1s（老板 11-07，绝不退避）
static const int kAppRelaunchDelaySec = 5;   // ★ 用户勾选的 App EXIT -> 5s 后再拉（老板 11-07）
static const int kShortLifeSec        = 60;
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
// v2.0.34：短命连击抑制 / 键盘多阶段确认状态
@property (nonatomic, assign) time_t shortCooldownUntil;
@property (nonatomic, assign) BOOL kbdAwaitingConfirm;
@property (nonatomic, assign) BOOL kbdConfirmDone;
@property (nonatomic, strong) dispatch_source_t src;
@end
@implementation WCVKTarget
@end

static NSMutableArray<WCVKTarget *> *gTargets = nil;

// ===== v2.0.34 全局状态（只在 WCVKQueue 上读写）=====
static unsigned gBootSeqGen          = 0;    // 启动序列令牌：用户空间重启时 ++ 作废旧序列
static BOOL     gBootSequenceActive  = NO;   // 序列进行中：抑制 Rebuild 的主动拉起/重试链
static int      gSBPid               = 0;    // SpringBoard 进程 pid 缓存
static dispatch_source_t gSBSource  = nil;   // 用户空间重启检测（DISPATCH_PROC_EXIT）

static BOOL WCVKIsKbd(WCVKTarget *t) { return [t.kind isEqualToString:@"kbd"]; }

// 前置声明
static void WCVKDoRelaunch(WCVKTarget *t, unsigned gen);
static void WCVKScheduleExitRelaunch(WCVKTarget *t, unsigned gen);
static void WCVKKbdWarmupWithConfirm(WCVKTarget *t, unsigned gen);
static void WCVKPruneUninstalledBIDs(void);
static void WCVKStartBootSequence(int startDelaySec, NSArray<WCVKTarget *> *only);
static void WCVKOnUserSpaceRestart(void);
static void WCVKSBArmWatch(int attempt);
static int  WCVKFindSpringBoardPidSync(void);

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
        // 纯事件驱动：键盘 EXIT -> 1s 立刻拉起；App EXIT -> 5s 后再拉（老板 11-07 保留）。
        // v2.0.34 唯一额外等待：连续 3 次「活不过 60s」（内存压力下刚拉起就被杀）
        // 才对该 target 暂停 60s，避免拉起→被杀→再拉起的死循环反复吃 CPU/内存。
        time_t life = (st.armedAt > 0) ? (time(NULL) - st.armedAt) : -1;
        if (!WCVKIsKbd(st) && life >= 0 && life < kShortLifeSec) {
            st.shortLives++;
            LOG(@"### %@ (pid=%d) 退出（只活了 %lds，累计短命 %d 次）",
                st.display, st.pid, (long)life, st.shortLives);
            if (st.shortLives >= kShortLifeBurstLimit) {
                st.shortCooldownUntil = time(NULL) + kShortLifeCooldownSec;
                LOG(@"### %@ 连续短命 %d 次 -> 暂停 %ds 再拉起（避免内存压力下反复被杀）",
                    st.display, st.shortLives, kShortLifeCooldownSec);
                WCVKRecord(st.display, st.ident, st.kind, NO,
                           [NSString stringWithFormat:@"连续短命 %d 次，暂停 %ds 再拉起（保护内存）",
                                                      st.shortLives, kShortLifeCooldownSec]);
            }
        } else if (st.shortLives > 0 || st.shortCooldownUntil > 0) {
            LOG(@"### %@ 这次活了 %lds -> 短命计数/冷却清零（原连击 %d 次）",
                st.display, (long)life, st.shortLives);
            st.shortLives = 0;
            st.shortCooldownUntil = 0;
        }
        st.armedAt = 0;
        st.pid = 0;                               // 缓存失效
        if (st.src) { dispatch_source_cancel(st.src); st.src = nil; }
        WCVKScheduleExitRelaunch(st, gen);
    });
    t.src = src;
    t.armedGen = gen;
    dispatch_resume(src);
    // 键盘重新挂上监视 = 上次拉起已成功 -> 清 3s 防抖，下次退出立刻处理
    if (WCVKIsKbd(t)) t.lastRelaunch = 0;
    LOG(@"watch ARMED: %@ (pid=%d)", t.display, pid);
}

// v2.0.34：退出后的统一调度。正常 = 键盘 1s / App 5s（老板 11-07 语义原样保留）；
// 短命连击抑制期间 = 等到冷却结束。一次性 dispatch_after 链，事件驱动绝不轮询。
static void WCVKScheduleExitRelaunch(WCVKTarget *t, unsigned gen) {
    if (!WCVKTargetValid(t, gen)) return;
    time_t now = time(NULL);
    int wait = WCVKIsKbd(t) ? kRelaunchDelaySec : kAppRelaunchDelaySec;
    if (!WCVKIsKbd(t) && t.shortCooldownUntil > now) {
        wait = (int)(t.shortCooldownUntil - now);
        LOG(@"%@ 短命连击冷却中 -> %ds 后再拉起", t.display, wait);
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(wait * NSEC_PER_SEC)),
                   WCVKQueue(), ^{
        if (!WCVKTargetValid(t, gen)) return;      // 重启 / 重建 / 熔断后旧回调一律作废
        if (!WCVKIsKbd(t) && t.shortCooldownUntil > time(NULL)) {
            WCVKScheduleExitRelaunch(t, gen);      // 冷却被延长，继续等（单次定时器，零轮询）
            return;
        }
        WCVKDoRelaunch(t, gen);                    // ★ 只拉起；挂监视交给校验/kbd.up
        // ★ 兜底（鲁棒性）：如果这次拉起被冷却挡掉了，旧监视已取消、又没人重挂，
        //   这个 target 会永久收不到退出事件。2s 后仅当「仍无监视」才启动挂监视重试；
        //   正常路径 1.5s 校验已挂上 src，这里直接 return，零额外扫描。
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)),
                       WCVKQueue(), ^{
            if (!WCVKTargetValid(t, gen) || t.src) return;
            LOG(@"%@ 退出后仍无监视 -> 启动挂监视兜底", t.display);
            WCVKArmRetry(t, gen, 0);
        });
    });
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

// ===== v2.0.34：键盘扩展多阶段确认 =====
//  旧实现只在 warmup 后 1.5s 判一次，而 SpringBoard 侧 DidShow 后还要 +0.25s、
//  注销时注入端甚至还没注册通知 -> 1.5s 必判 FAIL，随后系统自己 spawn 才「实际成功」。
//  现在 1.5/4/8s 三次单点校验（成功即停），4s 未起补发一次 warmup；
//  kbd.up 迟到到达时补写一条成功记录。键盘永不熔断、不累计 fails（老板铁律）。
static void WCVKKbdWarmupWithConfirm(WCVKTarget *t, unsigned gen) {
    NSString *disp = t.display ?: @"键盘";
    t.kbdAwaitingConfirm = YES;
    t.kbdConfirmDone = NO;
    notify_post("com.wcvoicekeep.kbd.warmup");
    LOG(@"%@ 键盘预热已发出（多阶段确认 1.5/4/8s；4s 未起补发一次）", disp);

    int stages = (int)(sizeof(kKbdConfirmDelaysMs) / sizeof(kKbdConfirmDelaysMs[0]));
    for (int i = 0; i < stages; i++) {
        int ms = kKbdConfirmDelaysMs[i];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(ms * NSEC_PER_MSEC)),
                       WCVKQueue(), ^{
            if (!WCVKTargetValid(t, gen) || t.kbdConfirmDone) return;
            WCVKResolvePids(@[t], ^(NSArray<NSNumber *> *pids) {
                if (!WCVKTargetValid(t, gen) || t.kbdConfirmDone) return;
                int pid = pids.firstObject.intValue;
                if (pid > 0) {
                    t.kbdConfirmDone = YES;
                    t.kbdAwaitingConfirm = NO;
                    WCVKRecord(disp, @"wxkb_plugin", @"kbd", YES,
                               [NSString stringWithFormat:@"键盘扩展已拉起 (pid=%d, T+%dms 确认)", pid, ms]);
                    LOG(@"%@ 键盘扩展确认成功 pid=%d (T+%dms)", disp, pid, ms);
                    WCVKArmPid(t, pid);
                } else if (ms >= 4000 && ms < 8000) {
                    LOG(@"%@ T+%dms 未确认 -> 补发一次键盘预热（应对注销后 SB 晚就绪）", disp, ms);
                    notify_post("com.wcvoicekeep.kbd.warmup");
                } else if (ms >= 8000) {
                    t.kbdAwaitingConfirm = NO;
                    WCVKRecord(disp, @"wxkb_plugin", @"kbd", NO,
                               @"键盘预热已发出但扩展未起来（不熔断，等 kbd.up / 下次事件）");
                    LOG(@"%@ 8s 仍未确认（不熔断，等待 kbd.up 迟到确认）", disp);
                }
            });
        });
    }
}

static void WCVKDoRelaunch(WCVKTarget *t, unsigned gen) {
    time_t now = time(NULL);
    // v2.0.34：短命连击冷却（唯一破「固定 1s」的例外，键盘豁免）
    if (!WCVKIsKbd(t) && t.shortCooldownUntil > now) {
        LOG(@"%@ 短命连击冷却中（还剩 %lds），跳过本次拉起", t.display,
            (long)(t.shortCooldownUntil - now));
        return;
    }
    int cooldown = WCVKIsKbd(t) ? kKbdDebounceSec : kFailCooldownSec;
    if (t.lastRelaunch && now - t.lastRelaunch < cooldown) {
        LOG(@"%@ 冷却中（%lds 前刚处理过，冷却 %ds），跳过", t.display,
            (long)(now - t.lastRelaunch), cooldown);
        return;
    }
    t.lastRelaunch = now;

    if (WCVKIsKbd(t)) {
        WCVKKbdWarmupWithConfirm(t, gen);         // 键盘永不熔断、不累计 fails
        return;
    }
    WCVKRelaunchAttempt(t, 0, gen);
}

// ===== 按当前设置重建目标表 =====
static void WCVKRebuildTargets(void) {
    if (!gTargets) gTargets = [NSMutableArray array];
    WCVKPruneUninstalledBIDs();      // v2.0.34：先剔除已卸载 ID，不再为它建 target

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
        if (!meta) {
            // v2.0.34：解析不到 = 已卸载。即便 cfprefsd 旧快照回弹，也不为它建 target，
            // 更不会每轮为它跑 3 次 SBSLaunch + 5s/15s 重试。
            LOG(@"跳过已卸载/无法解析的 ID: %@", bid);
            continue;
        }
        WCVKTarget *t = [WCVKTarget new];
        t.ident = bid;
        t.display = meta[@"display"] ?: bid;
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
    NSMutableArray<WCVKTarget *> *newTargets = [NSMutableArray array];
    for (WCVKTarget *n in want) {
        WCVKTarget *exist = nil;
        for (WCVKTarget *old in gTargets) if ([old.ident isEqualToString:n.ident]) { exist = old; break; }
        if (exist) {
            exist.display = n.display; exist.exeSuffix = n.exeSuffix;
            exist.gen++;                       // 作废所有旧异步回调（精准命中）
            exist.relaunching = NO;
            exist.disabled = NO;              // 键盘永远 NO；App 改设置 / 注销后恢复
            exist.fails = 0;
            [merged addObject:exist];
        } else {
            [merged addObject:n];
            if (!WCVKIsKbd(n)) [newTargets addObject:n];
        }
    }
    gTargets = merged;
    LOG(@"targets 重建：共 %lu 个（键盘扩展 + App %lu）",
        (unsigned long)gTargets.count, (unsigned long)(gTargets.count ? gTargets.count - 1 : 0));

    // v2.0.34：不再「一次性把没在跑的 App 全部拉起」—— 那是内存峰值 / jetsam 连杀的放大器。
    // 开机与注销由 WCVKStartBootSequence 完整错峰覆盖；运行中设置变更只把新增的 App
    // 排进同样的 5s 间隔队列。已在运行的 target 由下面的批量解析直接挂监视。
    if (newTargets.count && !gBootSequenceActive) {
        LOG(@"新增 %lu 个 App -> 排入错峰拉起序列（每个间隔 %ds）",
            (unsigned long)newTargets.count, kBootStepIntervalSec);
        WCVKStartBootSequence(kBootStartDelaySec, newTargets);
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
            unsigned gen = gens[i].unsignedIntValue;
            if (!WCVKTargetValid(t, gen)) continue;   // 重建/取消/关闭后旧结果一律作废
            if (pid > 0) WCVKArmPid(t, pid);
            else if (!gBootSequenceActive) WCVKArmRetry(t, gen, 0);
            // 序列进行中：不启动 2/5/10/20/40s 重试链（会和错峰拉起并发、白扫进程表），
            // 由启动序列每一步自己解析并挂监视。
        }
    });
}

// ===== v2.0.34：开机 / 注销的优先级错峰启动序列 =====
//  老板 2026-11-09 定案：键盘 → 5s → 微信 → 5s → 其它 App（每个再隔 5s）。
//  开机与注销都按这个顺序，绝不同时冷启动多个 App —— 同时拉起是内存/CPU 峰值、
//  刚拉起就被 jetsam 杀掉、杀掉又立刻拉起的根因。
static NSArray<WCVKTarget *> *WCVKOrderedTargets(NSArray<WCVKTarget *> *src) {
    WCVKTarget *kbd = nil, *wechat = nil;
    NSMutableArray<WCVKTarget *> *rest = [NSMutableArray array];
    for (WCVKTarget *t in src) {
        if (WCVKIsKbd(t)) kbd = t;
        else if ([t.ident isEqualToString:kWeChatBID]) wechat = t;
        else [rest addObject:t];
    }
    NSMutableArray<WCVKTarget *> *out = [NSMutableArray arrayWithCapacity:src.count + 2];
    if (kbd) [out addObject:kbd];                 // 第 1 优先：微信输入法键盘扩展
    if (wechat) [out addObject:wechat];           // 第 2 优先：微信
    [out addObjectsFromArray:rest];               // 其余按设置里的顺序，每个间隔 5s
    return out;
}

static void WCVKBootLaunchOne(WCVKTarget *t, unsigned gen) {
    if (!WCVKTargetValid(t, gen)) return;
    WCVKResolvePids(@[t], ^(NSArray<NSNumber *> *pids) {
        if (!WCVKTargetValid(t, gen)) return;
        int pid = pids.firstObject.intValue;
        if (pid > 0) {
            LOG(@"[错峰] %@ 已在运行 (pid=%d) -> 只挂监视，不重复拉起", t.display, pid);
            WCVKArmPid(t, pid);                  // 已在跑就不浪费一次冷启动
            return;
        }
        LOG(@"[错峰] 拉起 %@（kind=%@）", t.display, t.kind);
        if (WCVKIsKbd(t)) WCVKKbdWarmupWithConfirm(t, gen);
        else WCVKRelaunchAttempt(t, 0, gen);
    });
}

static void WCVKBootStep(NSArray<WCVKTarget *> *ordered, NSUInteger idx, unsigned gen, int delaySec) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delaySec * NSEC_PER_SEC)),
                   WCVKQueue(), ^{
        if (gen != gBootSeqGen) return;                // 新序列已接管，旧序列直接退场
        if (!gEnabled) {                               // 总开关关闭：清标志，别让 Rebuild 一直被抑制
            gBootSequenceActive = NO;
            LOG(@"启动序列中止：总开关已关闭");
            return;
        }
        if (idx >= ordered.count) {
            gBootSequenceActive = NO;
            LOG(@"===== 错峰启动序列完成（%lu 步，每步间隔 %ds）=====",
                (unsigned long)ordered.count, kBootStepIntervalSec);
            // 序列结束时 LaunchServices 必定就绪：复查一次卸载清理（一次性，非轮询）
            WCVKPruneUninstalledBIDs();
            return;
        }
        WCVKTarget *t = ordered[idx];
        if ([gTargets containsObject:t]) WCVKBootLaunchOne(t, t.gen);
        else LOG(@"[错峰] 第 %lu 步目标已移除，跳过", (unsigned long)(idx + 1));
        WCVKBootStep(ordered, idx + 1, gen, kBootStepIntervalSec);
    });
}

static void WCVKStartBootSequence(int startDelaySec, NSArray<WCVKTarget *> *only) {
    // 完整序列（开机/注销）推进全局令牌，作废旧序列；设置变更引起的局部序列
    // 复用当前令牌，绝不把正在跑的开机序列打断（否则后面的 App 永远不会被拉起）。
    unsigned gen = only ? gBootSeqGen : ++gBootSeqGen;
    gBootSequenceActive = YES;
    NSArray<WCVKTarget *> *ordered = WCVKOrderedTargets(only ?: [gTargets copy]);
    LOG(@"===== 启动序列 gen=%u：%lu 个目标，%ds 后开始，之后每个间隔 %ds =====",
        gen, (unsigned long)ordered.count, startDelaySec, kBootStepIntervalSec);
    for (NSUInteger i = 0; i < ordered.count; i++)
        LOG(@"  [%lu] %@ (%@)", (unsigned long)(i + 1), ordered[i].display, ordered[i].ident);
    WCVKBootStep(ordered, 0, gen, startDelaySec);
}

// ===== v2.0.34：用户空间重启检测（SpringBoard 进程退出）=====
//  不用 kern.boottime（respring 时它不变）；用内核 proc EXIT 事件，纯事件驱动零轮询。
static int WCVKFindSpringBoardPidSync(void) {
    int total = proc_listallpids(NULL, 0);
    if (total <= 0) return 0;
    int cap = total + 64;
    pid_t *pids = (pid_t *)calloc((size_t)cap, sizeof(pid_t));
    if (!pids) return 0;
    int cnt = proc_listallpids(pids, cap * (int)sizeof(pid_t));
    int found = 0;
    for (int j = 0; j < cnt; j++) {
        pid_t p = pids[j];
        if (p <= 1) continue;
        char path[PROC_PIDPATHINFO_MAXSIZE] = {0};
        int n = proc_pidpath(p, path, sizeof(path));
        if (n <= 0) continue;
        if (strstr(path, "/SpringBoard.app/SpringBoard")) { found = p; break; }
    }
    free(pids);
    return found;
}

static void WCVKSBArmWatch(int attempt) {
    if (attempt > kSBWatchRetryMax) {
        LOG(@"SpringBoard 监视：多次未找到 pid，放弃重挂（不影响启动序列）");
        return;
    }
    dispatch_async(WCVKScanQueue(), ^{
        int pid = WCVKFindSpringBoardPidSync();
        dispatch_async(WCVKQueue(), ^{
            if (pid <= 0) {
                LOG(@"SpringBoard 尚未就绪（第 %d 次）-> 3s 后再找", attempt);
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)),
                               WCVKQueue(), ^{ WCVKSBArmWatch(attempt + 1); });
                return;
            }
            if (gSBSource) { dispatch_source_cancel(gSBSource); gSBSource = nil; }
            gSBPid = pid;
            dispatch_source_t src = dispatch_source_create(DISPATCH_SOURCE_TYPE_PROC,
                                        (uintptr_t)pid, DISPATCH_PROC_EXIT, WCVKQueue());
            if (!src) { gSBPid = 0; return; }
            gSBSource = src;
            dispatch_source_set_event_handler(src, ^{
                LOG(@"===== SpringBoard (pid=%d) 退出 -> 判定注销/用户空间重启 =====", gSBPid);
                if (gSBSource) { dispatch_source_cancel(gSBSource); gSBSource = nil; }
                gSBPid = 0;
                WCVKOnUserSpaceRestart();
            });
            dispatch_resume(src);
            LOG(@"SpringBoard 监视已挂 pid=%d（事件驱动，零轮询）", pid);
        });
    });
}

static void WCVKOnUserSpaceRestart(void) {
    LOG(@"===== 用户空间重启：解除全部熔断 / 清看护状态 / 按优先级错峰重新拉起 =====");
    gBootSeqGen++;                       // 作废旧启动序列的所有回调
    gBootSequenceActive = YES;           // 抑制 Rebuild 的主动拉起 / 重试链
    for (WCVKTarget *t in gTargets) {
        WCVKStopTarget(t);               // gen++ / cancel src / pid=0 / relaunching=NO
        t.fails = 0;
        t.disabled = NO;                 // ★ 老板要求：注销后熔断必须解除
        t.shortLives = 0;
        t.shortCooldownUntil = 0;
        t.lastRelaunch = 0;
        t.kbdAwaitingConfirm = NO;
        t.kbdConfirmDone = NO;
    }
    gMetaCache = nil;                    // 新用户空间重新解析（顺带清掉卸载 ID 的旧缓存）
    WCVKReadPrefs();                     // 注销前改过的设置在这里生效
    WCVKRebuildTargets();                // 按当前 prefs 重建（内部再做一次卸载清理）
    WCVKSBArmWatch(0);                   // 重挂新 SpringBoard 的退出监视
    WCVKStartBootSequence(kBootStartDelaySec, nil);
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
static int gKbdUpToken    = 0;
static int gSBReadyToken  = 0;
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
                // v2.0.34：扩展比 1.5s 判定晚起来时，补写一条成功记录，
                // 不再出现「提示拉起失败、注销后其实成功」的假象。
                if (t.kbdAwaitingConfirm) {
                    t.kbdAwaitingConfirm = NO;
                    t.kbdConfirmDone = YES;
                    WCVKRecord(t.display ?: @"键盘", @"wxkb_plugin", @"kbd", YES,
                               [NSString stringWithFormat:@"键盘扩展已拉起 (kbd.up 迟到确认, pid=%d)", pid]);
                    LOG(@"kbd.up 迟到确认 -> 补写一条成功记录 pid=%d", pid);
                }
            } else {
                LOG(@"kbd.up state 无效(%d) -> 回退一次解析", pid);
                WCVKArmTarget(t, t.gen, 0);
            }
            break;
        }
    });

    // v2.0.34：SpringBoard 注入端每次加载都广播一次就绪。注销时 daemon 发的第一次 warmup
    // 很容易早于它注册通知而丢失 —— 收到就绪信号且键盘仍在待确认状态时补发一次。
    // 事件驱动、只在启动/注销阶段动作，常态零开销。
    notify_register_dispatch("com.wcvoicekeep.sb.ready", &gSBReadyToken, WCVKQueue(), ^(int token) {
        LOG(@"sb.ready: SpringBoard 注入端已就绪");
        for (WCVKTarget *t in gTargets) {
            if (!WCVKIsKbd(t) || !t.kbdAwaitingConfirm) continue;
            if (t.pid > 0 && WCVKValidatePid(t, t.pid)) return;   // 已在跑就别再弹
            LOG(@"sb.ready -> 补发一次键盘预热（注销时第一次 warmup 可能丢了）");
            notify_post("com.wcvoicekeep.kbd.warmup");
            break;
        }
    });
    LOG(@"kbd.up / sb.ready notify registered");
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
    printf("  boot order: 键盘 -> 微信 -> 其它 App（每个间隔 %ds）\n", kBootStepIntervalSec);
    for (int i = 1; i < n; i++) {
        NSString *bid = ((WCVKTarget *)ts[i]).ident;
        NSDictionary *m = WCVKAppMeta(bid);
        printf("  [app] %-34s %-14s pid=%-6d exe=%s\n", bid.UTF8String,
               [(m[@"display"] ?: bid) UTF8String], pids[i],
               [(m[@"exeSuffix"] ?: @"(已卸载, 自动剔除)") UTF8String]);
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
        gBootSequenceActive = YES;     // 开机序列开始前先抑制 Rebuild 的并发拉起 / 重试链
        LOG(@"===== daemon start (pid=%d, flavor=%s) =====", getpid(),
            WCVK_NO_LOG ? "pure" : "log");
        WCVKClearLegacyAnyUserApps();  // v2.0.35：先根除 AnyUser 域僵尸快照
        WCVKReadPrefs();               // 真值 = 设置页 plist（文件优先）
        WCVKRebuildTargets();
        WCVKRegisterKbdUp();
        WCVKRegisterPrefsNotify();
        WCVKArmPrefsWatch();
        WCVKSBArmWatch(0);            // 用户空间重启 / 注销检测（熔断解除的触发源）
        WCVKStartBootSequence(kBootStartDelaySec, nil);
        LOG(@"daemon ready: 事件驱动看护中（开机按 键盘→5s→微信→5s→其它 错峰拉起）");

        dispatch_main();
    }
    return 0;
}
