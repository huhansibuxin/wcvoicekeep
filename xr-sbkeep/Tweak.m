// XRWeChatKeep — v1.6.0（前台过一遍，真机 API 落地）
// 老板 2026-11-19 定案：XR 放屋里、没人解锁，微信掉了必须自动拉起并「一直跑」。
//
// v1.3.0（XR 实机装 v1.2.0 后「日志 0 字节、ctor 疑似没执行」后加的诊断版）：
//   XR 上 launchd 已带 DYLD_INSERT_LIBRARIES=/usr/lib/substitute-inserter.dylib，
//   说明注入链在，但 SpringBoard 里连 ctor 第一行都没落盘。
//   本版把「能否写日志」「ctor 是否执行」变成可观测事实：
//   ① ctor 第一条语句就是纯 C 的 open+write（不碰 NSString/ObjC），带 pid/进程名；
//   ② 日志主路径改为 SpringBoard 自有目录 /var/mobile/Library/SpringBoard/（沙盒内必可写），
//      旧路径 /var/mobile/ 作为第二落点，open 失败的 errno 一并写进能写的那个文件；
//   ③ Filter 额外挂 com.apple.mobilesafari：Safari 里只写一行探针就退出，用来判定
//      「注入整体不通」还是「只有 SpringBoard 特殊」。
//
// v1.2.0（XR 实机装了 v1.0.0 后「零日志、dylib 未加载」后修正）：
//   v1.0.0 用 Logos %hook，编译产物引用 MSHookMessageEx（动态查找），Taurine/amfidebilitate
//   环境下 SpringBoard 里拿不到该符号 → dylib 加载失败、一条日志都没有。
//   现改为纯 ObjC runtime：class_addMethod / method_setImplementation 自己换 IMP，
//   不用 Logos、不引用 substrate.h、不链接 libsubstrate，任何越狱都能加载。
//
// v1.1.0（老板实机反馈「锁屏被拉起来了但没持续跑，手点一次微信才跑」后修正）：
//   headless(suspended) 拉起只让进程「存在」，进程处于 SSTOP 挂起态，
//   App 层任何插件（含音频保活）都还没机会执行，所以救不了。
//   新增：① proc_pidinfo 读 pbi_status + CPU 时间，识别挂起/冻结；
//        ② 冻结 → 断言后 3s 复核，仍未解挂则用 __ActivateSuspended=NO 强制非挂起启动；
//        ③ 断言加第三档 BKSProcessAssertion 兜底（对已 suspend 进程会 task_resume）；
//        ④ FB 启动请求失败时回退 SBSLaunchApplicationWithIdentifier(bid, 0)。
//
// 背景（为什么不是音频、不是有头拉起）：
//   - SBSLaunchApplicationWithIdentifier(bid, 1) = suspended:YES = 无头拉起，锁屏也能成，
//     但进程起来就被 suspend → CocoaTop 里进程在、CPU 为 0，注入的插件不跑。
//   - suspended:NO = 有头拉起，锁屏时被 secure lockscreen 挡住，且需要 __UnlockDevice 这种
//     SpringBoard 特权选项才可能穿透；普通 root daemon 传了也无效。
//   - 静音音频走 App 层 audio session，会被微信自己的通话 session 抢，插件抢不过。
// → 正解是 RunningBoard 层：由 SpringBoard 身份持 RBSAssertion(PreventTaskSuspend)，
//   让系统「不挂起」微信。社区参考 bakgrunnur（udevs, GPLv3, iOS 14.3 实测锁屏可用）。
//
// v1.5.0（老板 2026-11-19 22:11 定案，需求第二次收窄）：
//   不要保活断言、不要场景欺骗，只做「前台过一遍」：
//   微信掉了（息屏下被内存杀也算）→ 免密解锁 → 有头拉起 → 前台停 15s → 回主屏；
//   之后微信靠自己的后台保活继续跑，下次再被杀就再来一遍。跟 wcvoicekeep 把输入法过前台同款。
//   断言路径（RBS/BKS）与场景扶持全部默认关闭，代码保留以便回退。
//
// v1.4.0（老板实测「无头拉起后微信里注入的插件不跑」后新增）：
//   设备不设锁屏密码时，可以真正做到「免密解锁 → 有头拉起 → 常驻前台」，
//   微信才认为自己在跑，内部注入的插件才会持续工作。有密码则自动回落无头模式。
//   模式文件：/var/mobile/Library/SpringBoard/xrkeep.mode（headful / headless）。
//
// 本实现的两个取舍（比 bakgrunnur 保守）：
//   ① 解锁使用期间**不**做场景扶持，只持断言 —— 不抢前台归属，界面零异常；
//   ② 只在锁屏期（isUILocked）才把微信场景强制 foreground，避免和用户操作打架。
//
// 日志：主路径落 SpringBoard 自有数据目录（沙盒内必可写），旧的 /var/mobile 作第二落点，
// 两处都开，哪处能写就写哪处；只在状态变化时写，常态零写入。

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dispatch/dispatch.h>
#import <notify.h>
#import <string.h>
#import <stdlib.h>
#import <time.h>
#import <unistd.h>
#import <fcntl.h>
#import <errno.h>
#import <dlfcn.h>

// 不引用 substrate.h：本工程已完全不用 Logos，hook 走 ObjC runtime 替换 IMP

// ===== libproc（公开 API，在 libSystem 里；不引用头文件，手动声明）=====
extern int proc_listallpids(void *buffer, int buffersize);
extern int proc_pidpath(int pid, void *buffer, uint32_t buffersize);
#define SBK_PIDPATH_MAX 4096

// ===== libproc 补充：进程状态（判断是否处于挂起态）=====
extern int proc_pidinfo(int pid, int flavor, uint64_t arg, void *buffer, int buffersize);
#define SBK_PROC_PIDTBSDINFO 3
#define SBK_SSTOP 4   // stopped / suspended

struct SBKBsdInfo {
    uint32_t pbi_flags;
    uint32_t pbi_status;
    uint32_t pbi_xstatus;
    uint32_t pbi_pid;
    uint32_t pbi_ppid;
    uint32_t pbi_uid;
    uint32_t pbi_gid;
    uint32_t pbi_ruid;
    uint32_t pbi_rgid;
    uint32_t pbi_svuid;
    uint32_t pbi_svgid;
    uint32_t rfu_1;
    char     pbi_comm[16];
    char     pbi_name[32];
    uint32_t pbi_nfiles;
    uint32_t pbi_pgid;
    uint32_t pbi_pjobc;
    uint32_t e_tdev;
    uint32_t e_tpgid;
    int32_t  pbi_nice;
    uint64_t pbi_start_tvsec;
    uint64_t pbi_start_tvusec;
};

// 返回 pbi_status；读不到返回 -1
static int SBKProcStatus(pid_t pid) {
    if (pid <= 0) return -1;
    struct SBKBsdInfo info;
    memset(&info, 0, sizeof(info));
    int rc = proc_pidinfo(pid, SBK_PROC_PIDTBSDINFO, 0, &info, (int)sizeof(info));
    if (rc < (int)sizeof(info)) return -1;
    return (int)info.pbi_status;
}

// ===== CPU 时间（客观判断「到底跑没跑」）=====
#define SBK_PROC_PIDTASKINFO 4
struct SBKTaskInfo {
    uint64_t pti_virtual_size;
    uint64_t pti_resident_size;
    uint64_t pti_total_user;
    uint64_t pti_total_system;
    uint64_t rest[16];
};

// 返回 user+system 累计 CPU 纳秒；读不到返回 0
static uint64_t SBKTaskCPUTime(pid_t pid) {
    if (pid <= 0) return 0;
    struct SBKTaskInfo info;
    memset(&info, 0, sizeof(info));
    int rc = proc_pidinfo(pid, SBK_PROC_PIDTASKINFO, 0, &info, (int)sizeof(info));
    if (rc <= 0) return 0;
    return info.pti_total_user + info.pti_total_system;
}

// ===== 常量 =====
static NSString *const kTargetBID = @"com.tencent.xin";
// A 路：SpringBoard 自有数据目录（首选）；B 路：/var/mobile（旧路径兜底）
static NSString *const kLogPathA = @"/var/mobile/Library/SpringBoard/wcvoicekeep.xrkeep.log";
static NSString *const kLogPathB = @"/var/mobile/wcvoicekeep.xrkeep.log";

// 拉起退避阶梯（秒）；成功一次立即清零
static const NSTimeInterval kLaunchBackoff[] = {3, 8, 20, 45, 60};
static const int kLaunchBackoffCount = 5;

// 健康检查间隔（秒）。真正的退出检测走 DISPATCH_PROC_EXIT 事件，这个只做挂起态/断言复核。
static const int kHealthIntervalSec = 10;

// ===== 日志 =====
// 两路 fd：A = SpringBoard 自有目录（首选），B = /var/mobile（旧路径兜底）
static int gLogFd = -1;    // A 路
static int gLogFdB = -1;   // B 路

// 纯 C 落盘：不碰 ObjC/NSString，ctor 第一行就能用
static void SBKRawLog(const char *s) {
    if (!s) return;
    size_t n = strlen(s);
    if (gLogFd >= 0) { ssize_t ig = write(gLogFd, s, n); (void)ig; }
    if (gLogFdB >= 0) { ssize_t ig = write(gLogFdB, s, n); (void)ig; }
}

static void SBKLog(NSString *fmt, ...) {
    if (gLogFd < 0 && gLogFdB < 0) return;
    va_list ap;
    va_start(ap, fmt);
    NSString *body = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);

    time_t now = time(NULL);
    struct tm tmv;
    localtime_r(&now, &tmv);
    char ts[32];
    strftime(ts, sizeof(ts), "%m-%d %H:%M:%S", &tmv);

    char line[1400];
    int n = snprintf(line, sizeof(line), "[%s] %s\n", ts, body.UTF8String ?: "?");
    if (n > 0) {
        if (gLogFd >= 0) { ssize_t ig = write(gLogFd, line, (size_t)n); (void)ig; }
        if (gLogFdB >= 0) { ssize_t ig = write(gLogFdB, line, (size_t)n); (void)ig; }
    }
}

// ===== 串行队列 =====
static dispatch_queue_t SBKQueue(void) {
    static dispatch_queue_t q;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        q = dispatch_queue_create("com.wcvoicekeep.xrkeep", DISPATCH_QUEUE_SERIAL);
    });
    return q;
}

// ===== 锁屏状态 =====
// v1.3.2 关键修正（安全模式元凶）：绝不能调 +sharedInstance！
//   SBLockScreenManager 在 SpringBoard 启动早期尚未构建，tweak 在启动期（场景设置 hook 里）
//   去 +sharedInstance 会触发它现场 alloc/init，UI 依赖没就绪 → SpringBoard 直接崩 → 安全模式。
//   改用 +sharedInstanceIfExists：只读已存在的实例，不存在就返回 nil（此时必然是开机早期，
//   也不可能处于「锁屏使用中」状态），零副作用。
static BOOL SBKIsLocked(void) {
    static Class cls;
    static SEL selIfExists, selShared, selLocked;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        cls = objc_getClass("SBLockScreenManager");
        selIfExists = sel_registerName("sharedInstanceIfExists");
        selShared   = sel_registerName("sharedInstance");
        selLocked   = sel_registerName("isUILocked");
    });
    if (!cls) return NO;
    @try {
        id inst = nil;
        if (class_respondsToSelector(object_getClass((id)cls), selIfExists)) {
            inst = ((id (*)(id, SEL))objc_msgSend)((id)cls, selIfExists);
        } else {
            inst = ((id (*)(id, SEL))objc_msgSend)((id)cls, selShared);
        }
        if (!inst) return NO;
        return ((BOOL (*)(id, SEL))objc_msgSend)(inst, selLocked);
    } @catch (NSException *e) {
        (void)e;
        return NO;
    }
}

// ===== SpringBoard 实例 & 通用调用助手（v1.6.0 按真机 API 重写）=====
static id SBKSpringBoard(void) {
    static Class cls;
    static SEL sel;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        cls = objc_getClass("UIApplication");   // SpringBoard 是 UIApplication 子类，进程内取到的就是它自己
        sel = sel_registerName("sharedApplication");
    });
    if (!cls) return nil;
    @try { return ((id (*)(id, SEL))objc_msgSend)((id)cls, sel); }
    @catch (NSException *e) { (void)e; return nil; }
}

static BOOL SBKTryVoidSel(id obj, const char *name) {
    if (!obj) return NO;
    SEL s = sel_registerName(name);
    if (![obj respondsToSelector:s]) return NO;
    @try {
        ((void (*)(id, SEL))objc_msgSend)(obj, s);
        return YES;
    } @catch (NSException *e) {
        (void)e;
        return NO;
    }
}

// ===== v1.5.0「前台过一遍」基础设施 =====
// 老板 2026-11-19 定案（第二次收窄需求）：
//   不要保活断言、不要场景欺骗，只做一件事 ——
//   微信掉了就「免密解锁（设备已取消锁屏密码）→ 有头（前台）拉起 → 前台停一会儿 → 交回后台」，
//   跟以前 wcvoicekeep 把微信输入法"从前台过一遍"完全一致的思路。
//   目的：让微信以及它内部注入的插件 / 音频保活真正拿到前台运行态，之后回到后台它自己会继续跑。
//
// 两个刻意的简化：
//   ① 断言（RBS/BKS）全部关闭 —— 老板明确说不需要，少一层出问题的面；
//   ② 不再探测「有没有锁屏密码」（早期初始化 MCProfileConnection 会崩 SpringBoard），
//      直接靠「解锁能不能成」判定：解开了 = 有头模式，解不开 = 回落无头模式。

static int  gHeadfulMode  = -1;   // -1 待判定 / 0 无头 / 1 有头
static BOOL gUseAssert    = NO;   // 保活断言：按老板要求关闭
static int  gPrimeHoldSec = 15;   // 前台停留秒数；0 = 一直留前台不交回后台
static time_t gLastPrimeAt = 0;   // 上次「前台过一遍」时间
static time_t gLastUnlockAt = 0;

// 模式文件：/var/mobile/Library/SpringBoard/xrkeep.mode（headful / headless），可选
// 前台停留秒数：/var/mobile/Library/SpringBoard/xrkeep.prime（整数，0 = 一直留前台）
static void SBKLoadMode(void) {
    NSString *txt = nil;
    @try {
        txt = [NSString stringWithContentsOfFile:@"/var/mobile/Library/SpringBoard/xrkeep.mode"
                                        encoding:NSUTF8StringEncoding error:NULL];
    } @catch (NSException *e) { (void)e; }
    NSString *low = [txt stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]].lowercaseString;
    if (low.length && [low containsString:@"headless"]) gHeadfulMode = 0;
    else if (low.length && [low containsString:@"headful"]) gHeadfulMode = 1;

    NSString *p = nil;
    @try {
        p = [NSString stringWithContentsOfFile:@"/var/mobile/Library/SpringBoard/xrkeep.prime"
                                      encoding:NSUTF8StringEncoding error:NULL];
    } @catch (NSException *e) { (void)e; }
    p = [p stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (p.length) {
        int v = p.intValue;
        if (v >= 0 && v <= 600) gPrimeHoldSec = v;
    }
    SBKLog(@"模式=%@ 前台停留=%ds（mode 文件%@）", 
           gHeadfulMode == 1 ? @"有头(强制)" : (gHeadfulMode == 0 ? @"无头(强制)" : @"待判定"),
           gPrimeHoldSec, low.length ? @"已指定" : @"未指定");
}

// 免密解锁（设备已取消锁屏密码）。真机 API 勘探（v1.5.1）确认 iOS 14 上真实可用的是：
//   SpringBoard -_turnScreenOnAndUnlockWithCompletion:（点亮+解锁一步到位）
//   SpringBoard -requestDeviceUnlock
//   SBLockScreenManager -unlockUIFromSource:withOptions:（注意是 void 返回，之前当 BOOL 用是错的）
static BOOL SBKUnlockDevice(NSString *why) {
    if (!SBKIsLocked()) return YES;
    time_t now = time(NULL);
    if (gLastUnlockAt > 0 && (now - gLastUnlockAt) < 3) return NO;
    gLastUnlockAt = now;

    BOOL ok = NO;
    id sb = SBKSpringBoard();

    // ① 点亮并解锁（最贴合「息屏下被拉起」的场景）
    SEL sOn = sel_registerName("_turnScreenOnAndUnlockWithCompletion:");
    if (sb && [sb respondsToSelector:sOn]) {
        @try { ((void (*)(id, SEL, id))objc_msgSend)(sb, sOn, ^{}); }
        @catch (NSException *e) { (void)e; }
        usleep(300 * 1000);
        ok = !SBKIsLocked();
        if (ok) SBKLog(@"解锁 (%@) 走 _turnScreenOnAndUnlock ✔", why ?: @"?");
    }
    // ② requestDeviceUnlock
    if (!ok && sb && [sb respondsToSelector:sel_registerName("requestDeviceUnlock")]) {
        @try { ((void (*)(id, SEL))objc_msgSend)(sb, sel_registerName("requestDeviceUnlock")); }
        @catch (NSException *e) { (void)e; }
        usleep(300 * 1000);
        ok = !SBKIsLocked();
        if (ok) SBKLog(@"解锁 (%@) 走 requestDeviceUnlock ✔", why ?: @"?");
    }
    // ③ SBLockScreenManager（void 返回，逐个 source 试）
    if (!ok) {
        Class cls = objc_getClass("SBLockScreenManager");
        id mgr = nil;
        @try {
            if (cls && class_respondsToSelector(object_getClass((id)cls), sel_registerName("sharedInstanceIfExists"))) {
                mgr = ((id (*)(id, SEL))objc_msgSend)((id)cls, sel_registerName("sharedInstanceIfExists"));
            }
        } @catch (NSException *e) { (void)e; }
        SEL s2 = sel_registerName("unlockUIFromSource:withOptions:");
        if (mgr && [mgr respondsToSelector:s2]) {
            int sources[3] = { 0, 7, 6 };
            for (int i = 0; i < 3 && !ok; i++) {
                @try { ((void (*)(id, SEL, int, id))objc_msgSend)(mgr, s2, sources[i], nil); }
                @catch (NSException *e) { (void)e; }
                usleep(250 * 1000);
                ok = !SBKIsLocked();
                if (ok) SBKLog(@"解锁 (%@) 走 unlockUIFromSource:%d ✔", why ?: @"?", sources[i]);
            }
        }
    }

    BOOL stillLocked = SBKIsLocked();
    SBKLog(@"解锁 (%@) 结果 locked=%d", why ?: @"?", stillLocked ? 1 : 0);
    if (!stillLocked && gHeadfulMode < 0) {
        gHeadfulMode = 1;
        SBKLog(@"模式判定=有头（免密解锁成功）");
    } else if (stillLocked && gHeadfulMode < 0) {
        gHeadfulMode = 0;
        SBKLog(@"模式判定=无头（解锁不成功，多半还设着密码）");
    }
    return (stillLocked == NO);
}

// 交回后台 / 恢复息屏：真机确认可用 SpringBoard -_simulateLockButtonPress（等价按一下电源键）
static void SBKRelockDevice(NSString *why) {
    if (SBKIsLocked()) return;
    id sb = SBKSpringBoard();
    if (SBKTryVoidSel(sb, "_simulateLockButtonPress")) {
        usleep(300 * 1000);
        SBKLog(@"恢复息屏（%@）_simulateLockButtonPress → locked=%d", why ?: @"?", SBKIsLocked() ? 1 : 0);
        return;
    }
    Class cls = objc_getClass("SBLockScreenManager");
    id mgr = nil;
    @try {
        if (cls && class_respondsToSelector(object_getClass((id)cls), sel_registerName("sharedInstanceIfExists"))) {
            mgr = ((id (*)(id, SEL))objc_msgSend)((id)cls, sel_registerName("sharedInstanceIfExists"));
        }
    } @catch (NSException *e) { (void)e; }
    SEL s = sel_registerName("lockUIFromSource:withOptions:");
    if (mgr && [mgr respondsToSelector:s]) {
        @try { ((void (*)(id, SEL, int, id))objc_msgSend)(mgr, s, 0, nil); }
        @catch (NSException *e) { (void)e; }
        usleep(250 * 1000);
    }
    SBKLog(@"恢复息屏（%@）lockUIFromSource → locked=%d", why ?: @"?", SBKIsLocked() ? 1 : 0);
}

// 微信场景是否前台（由场景 hook 顺带采集，未知 = -1）
static int gTargetSceneFG = -1;

static int SBKSettingsForeground(id settings) {
    if (!settings) return -1;
    SEL a = sel_registerName("isForeground");
    SEL b = sel_registerName("foreground");
    @try {
        if ([settings respondsToSelector:a]) return ((BOOL (*)(id, SEL))objc_msgSend)(settings, a) ? 1 : 0;
        if ([settings respondsToSelector:b]) return ((BOOL (*)(id, SEL))objc_msgSend)(settings, b) ? 1 : 0;
    } @catch (NSException *e) { (void)e; }
    return -1;
}

// ===== 找微信 pid（容器无关：路径后缀匹配）=====
static pid_t SBKPidForTarget(void) {
    int cap = 4096;
    pid_t *pids = (pid_t *)malloc(sizeof(pid_t) * (size_t)cap);
    if (!pids) return -1;
    int got = proc_listallpids(pids, (int)(sizeof(pid_t) * (size_t)cap));
    pid_t found = -1;
    if (got > 0) {
        char path[SBK_PIDPATH_MAX];
        for (int i = 0; i < got; i++) {
            pid_t p = pids[i];
            if (p <= 0) continue;
            memset(path, 0, sizeof(path));
            if (proc_pidpath(p, path, sizeof(path)) <= 0) continue;
            if (strstr(path, "/WeChat.app/WeChat") != NULL) {
                found = p;
                break;
            }
        }
    }
    free(pids);
    return found;
}

// ===== RBS 断言 =====
static id    gAssertion = nil;   // RBSAssertion *
static id    gBKSAssertion = nil; // BKSProcessAssertion *（第三档兜底，老 API，能直接解挂）
static pid_t gAssertPid = 0;
static int   gAssertTier = 0;    // 1 = legacy+grants，2 = 仅 legacy，3 = BKSProcessAssertion

// BKSProcessAssertionFlags：PreventTaskSuspend(1) | PreventTaskThrottleDown(2)
//                          | PreventThrottleDownUI(4) | PreventThrottleDownCPU(8)
static const unsigned long long kLegacyFlags = 1ULL | 2ULL | 4ULL | 8ULL;
static const unsigned long long kLegacyReason = 1ULL;   // BKSProcessAssertionReasonBackgroundUI

static void SBKDropAssertion(NSString *why) {
    if (gAssertion) {
        @try {
            ((void (*)(id, SEL))objc_msgSend)(gAssertion, sel_registerName("invalidate"));
        } @catch (NSException *e) {
            (void)e;
        }
        SBKLog(@"RBS 断言释放 (%@) pid=%d tier=%d", why ?: @"?", gAssertPid, gAssertTier);
    }
    if (gBKSAssertion) {
        @try {
            ((void (*)(id, SEL))objc_msgSend)(gBKSAssertion, sel_registerName("invalidate"));
        } @catch (NSException *e) {
            (void)e;
        }
        SBKLog(@"BKS 断言释放 (%@) pid=%d", why ?: @"?", gAssertPid);
    }
    gAssertion = nil;
    gBKSAssertion = nil;
    gAssertPid = 0;
    gAssertTier = 0;
}

static id SBKBuildAssertion(pid_t pid, BOOL withGrants) {
    Class cAssert = objc_getClass("RBSAssertion");
    Class cTarget = objc_getClass("RBSTarget");
    Class cLegacy = objc_getClass("RBSLegacyAttribute");
    if (!cAssert || !cTarget || !cLegacy) return nil;

    id target = ((id (*)(id, SEL, pid_t))objc_msgSend)((id)cTarget,
                                                       sel_registerName("targetWithPid:"), pid);
    if (!target) return nil;

    NSMutableArray *attrs = [NSMutableArray array];
    id legacy = ((id (*)(id, SEL, unsigned long long, unsigned long long))objc_msgSend)(
        (id)cLegacy, sel_registerName("attributeWithReason:flags:"), kLegacyReason, kLegacyFlags);
    if (legacy) [attrs addObject:legacy];
    if (attrs.count == 0) return nil;

    if (withGrants) {
        Class cGrant = objc_getClass("RBSHereditaryGrant");
        if (cGrant) {
            NSString *srcEnv = @"UIScene:com.apple.frontboard.systemappservices::com.apple.springboard";
            NSArray *namespaces = @[ @"com.apple.boardservices.endpoint-injection",
                                     @"com.apple.frontboard.visibility" ];
            for (NSString *ns in namespaces) {
                id grant = ((id (*)(id, SEL, id, id, id))objc_msgSend)(
                    (id)cGrant, sel_registerName("grantWithNamespace:sourceEnvironment:attributes:"),
                    ns, srcEnv, nil);
                if (grant) [attrs addObject:grant];
            }
        }
    }

    id alloced = ((id (*)(id, SEL))objc_msgSend)((id)cAssert, sel_registerName("alloc"));
    id assertion = ((id (*)(id, SEL, id, id, id))objc_msgSend)(
        alloced, sel_registerName("initWithExplanation:target:attributes:"),
        @"XRWeChatKeep: keep WeChat running for background plugins", target, attrs);
    return assertion;
}

static BOOL SBKTryAcquire(pid_t pid, BOOL withGrants, NSString **errOut) {
    id assertion = SBKBuildAssertion(pid, withGrants);
    if (!assertion) {
        if (errOut) *errOut = @"build failed";
        return NO;
    }
    NSError *err = nil;
    BOOL ok = NO;
    @try {
        ok = ((BOOL (*)(id, SEL, NSError **))objc_msgSend)(
            assertion, sel_registerName("acquireWithError:"), &err);
    } @catch (NSException *e) {
        err = [NSError errorWithDomain:@"xrkeep" code:-1
                              userInfo:@{NSLocalizedDescriptionKey: e.reason ?: @"exception"}];
    }
    if (ok) {
        gAssertion = assertion;
        gAssertPid = pid;
        gAssertTier = withGrants ? 1 : 2;
        SBKLog(@"断言成功 pid=%d tier=%d (%@)", pid, gAssertTier, withGrants ? @"legacy+grants" : @"legacy");
        return YES;
    }
    if (errOut) *errOut = err.localizedDescription ?: @"nil";
    SBKLog(@"断言失败 pid=%d (%@) err=%@", pid, withGrants ? @"legacy+grants" : @"legacy",
           err.localizedDescription ?: @"nil");
    return NO;
}

// 第三档兜底：BKSProcessAssertion（老 BackBoardServices API，iOS 14 上 SpringBoard 里通常可直接生效，
// 而且它对「已 suspend 的进程」会立即做 task_resume，比 RBSLegacyAttribute 更"能解挂"）
static BOOL SBKAcquireBKS(pid_t pid, NSString **errOut) {
    Class cBKS = objc_getClass("BKSProcessAssertion");
    if (!cBKS) {
        if (errOut) *errOut = @"BKSProcessAssertion 类缺失";
        return NO;
    }
    @try {
        id alloced = ((id (*)(id, SEL))objc_msgSend)((id)cBKS, sel_registerName("alloc"));
        // -initWithPID:flags:reason:name:acquire:withHandler:
        SEL selInit = sel_registerName("initWithPID:flags:reason:name:acquire:withHandler:");
        id assertion = nil;
        __block BOOL granted = NO;
        if ([alloced respondsToSelector:selInit]) {
            assertion = ((id (*)(id, SEL, int, unsigned int, unsigned int, id, BOOL, id))objc_msgSend)(
                alloced, selInit, (int)pid, (unsigned int)kLegacyFlags, (unsigned int)kLegacyReason,
                @"XRWeChatKeep", YES, ^(BOOL ok, NSError *e) {
                    granted = ok;
                    if (!ok) SBKLog(@"BKS handler granted=NO err=%@", e.localizedDescription ?: @"nil");
                });
        } else {
            // 退回更老的形态
            SEL selOld = sel_registerName("initWithPID:flags:reason:name:");
            if ([alloced respondsToSelector:selOld]) {
                assertion = ((id (*)(id, SEL, int, unsigned int, unsigned int, id))objc_msgSend)(
                    alloced, selOld, (int)pid, (unsigned int)kLegacyFlags,
                    (unsigned int)kLegacyReason, @"XRWeChatKeep");
                granted = (assertion != nil);
            }
        }
        if (assertion) {
            gBKSAssertion = assertion;
            gAssertion = assertion;
            gAssertPid = pid;
            gAssertTier = 3;
            SBKLog(@"BKS 断言成功 pid=%d flags=%llu granted=%d", pid, kLegacyFlags, granted ? 1 : 0);
            return YES;
        }
        if (errOut) *errOut = @"init 返回 nil";
    } @catch (NSException *e) {
        if (errOut) *errOut = e.reason ?: @"exception";
        SBKLog(@"BKS 断言异常 %@", e.reason ?: @"?");
    }
    return NO;
}

static void SBKEnsureAssertion(pid_t pid) {
    if (pid <= 0) return;
    // v1.5.0：老板明确「不需要保活代码」，断言整条路径默认关闭，只保留代码以备回退。
    if (!gUseAssert) return;

    if (gAssertion) {
        BOOL valid = NO;
        @try {
            valid = ((BOOL (*)(id, SEL))objc_msgSend)(gAssertion, sel_registerName("isValid"));
        } @catch (NSException *e) {
            (void)e;
        }
        // BKSProcessAssertion 没有 isValid，按其存在性当作有效
        if (gAssertTier == 3) valid = YES;
        if (valid && gAssertPid == pid) return;
        SBKDropAssertion(valid ? @"pid 变化" : @"已失效");
    }

    // v1.3.3：grants 档在 iOS 14 必失败（"Hereditary grants must specify a target environment"），
    // 直接跳过，省一次无效 acquire 和一行噪音日志，直接走 legacy 档。
    NSString *err2 = nil;
    if (SBKTryAcquire(pid, NO, &err2)) return;
    NSString *err3 = nil;
    if (SBKAcquireBKS(pid, &err3)) return;
    SBKLog(@"两档断言全部失败 (legacy_err=%@ bks_err=%@)", err2, err3);
}

// ===== 场景扶持（仅锁屏期）=====
static BOOL gForceScene = NO;     // 场景扶持：v1.5.0 起关闭（老板要求只做前台过一遍）
static __thread int gInForce = 0; // 防重入

// 启动静默期：ctor 之后 12s 内不做任何「主动改系统状态」的动作。
// SpringBoard 启动早期各单例/场景都还没就绪，此时强行 setForeground 或建断言都容易炸。
static time_t gCtorAt = 0;
static BOOL SBKSettled(void) {
    if (gCtorAt == 0) return NO;
    return (time(NULL) - gCtorAt) >= 12;
}

static NSString *SBKSceneBID(id scene) {
    if (!scene) return nil;
    @try {
        id proc = [scene valueForKey:@"clientProcess"];
        id identity = [proc valueForKey:@"identity"];
        NSString *bid = [identity valueForKey:@"embeddedApplicationIdentifier"];
        if ([bid isKindOfClass:[NSString class]] && bid.length) return bid;
    } @catch (NSException *e) {
            (void)e;
        }
    @try {
        NSString *sid = [scene valueForKey:@"identifier"];
        if ([sid isKindOfClass:[NSString class]] && sid.length) {
            if ([sid isEqualToString:kTargetBID]) return kTargetBID;
            if ([sid hasPrefix:kTargetBID]) return kTargetBID;
        }
    } @catch (NSException *e) {
            (void)e;
        }
    return nil;
}

static void SBKForceForeground(id settings) {
    if (!settings) return;
    if ([settings respondsToSelector:sel_registerName("setForeground:")]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(settings, sel_registerName("setForeground:"), YES);
    }
    if ([settings respondsToSelector:sel_registerName("setBackgrounded:")]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(settings, sel_registerName("setBackgrounded:"), NO);
    }
    if ([settings respondsToSelector:sel_registerName("setUnderLock:")]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(settings, sel_registerName("setUnderLock:"), NO);
    }
}

// ===== 拉起（SpringBoard 身份 + 解锁语义，穿透锁屏）=====
// 回退路径：SpringBoardServices 的 SBSLaunchApplicationWithIdentifier(bid, suspended)
// suspended=0 会以非挂起方式启动，是「挂起态解不开」时最后的手段。放串行队列，绝不占主线程。
static void SBKLaunchViaSBS(NSString *why) {
    typedef int (*SBKLaunchFn)(CFStringRef, Boolean);
    static SBKLaunchFn fn = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *h = dlopen("/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices",
                         RTLD_LAZY);
        fn = (SBKLaunchFn)dlsym(h ? h : RTLD_DEFAULT, "SBSLaunchApplicationWithIdentifier");
    });
    if (!fn) {
        SBKLog(@"SBS 回退：符号不可用 (%@)", why ?: @"?");
        return;
    }
    dispatch_async(SBKQueue(), ^{
        int rc = fn((__bridge CFStringRef)kTargetBID, (Boolean)0);
        SBKLog(@"SBS 回退拉起 rc=%d (%@)", rc, why ?: @"?");
    });
}

static void SBKLaunch(NSString *why) {
    if (gHeadfulMode != 0) {
        // 有头第一步：把锁屏解掉（息屏/锁屏下必须先解开，否则拉起会被压回后台）。
        SBKUnlockDevice(why ?: @"拉起前");
    }
    Class cPM  = objc_getClass("FBProcessManager");
    Class cReq = objc_getClass("FBSystemServiceOpenApplicationRequest");
    Class cOpt = objc_getClass("FBSOpenApplicationOptions");
    Class cSvc = objc_getClass("FBSystemService");
    Class cWS  = objc_getClass("SBMainWorkspace");
    if (!cPM || !cReq || !cOpt || !cSvc || !cWS) {
        SBKLog(@"拉起失败：FB 类缺失 (%@)", why ?: @"?");
        return;
    }

    id pm = ((id (*)(id, SEL))objc_msgSend)((id)cPM, sel_registerName("sharedInstance"));
    if (!pm) { SBKLog(@"拉起失败：FBProcessManager 空"); return; }
    id sbProcs = ((id (*)(id, SEL, id))objc_msgSend)(
        pm, sel_registerName("applicationProcessesForBundleIdentifier:"), @"com.apple.springboard");
    id sbProc = [sbProcs respondsToSelector:sel_registerName("firstObject")] ? [sbProcs firstObject] : nil;
    if (!sbProc) { SBKLog(@"拉起失败：SpringBoard FBApplicationProcess 空"); return; }

    NSMutableDictionary *opts = [NSMutableDictionary dictionary];
    opts[@"__PayloadOptions"] = @{ @"UIApplicationLaunchOptionsSourceApplicationKey" : @"com.apple.springboard" };
    opts[@"__ActivateSuspended"] = @NO;      // 关键：不要 suspend，否则起来也没 CPU
    opts[@"__PromptUnlockDevice"] = @YES;    // 锁屏期允许穿透
    opts[@"__UnlockDevice"] = @YES;
    opts[@"processLaunchIntent"] = @4;

    id options = ((id (*)(id, SEL, id))objc_msgSend)(
        (id)cOpt, sel_registerName("optionsWithDictionary:"), opts);
    id req = ((id (*)(id, SEL))objc_msgSend)((id)cReq, sel_registerName("request"));
    if (!options || !req) { SBKLog(@"拉起失败：options/request 空"); return; }

    ((void (*)(id, SEL, id))objc_msgSend)(req, sel_registerName("setClientProcess:"), sbProc);
    ((void (*)(id, SEL, BOOL))objc_msgSend)(req, sel_registerName("setTrusted:"), YES);
    ((void (*)(id, SEL, id))objc_msgSend)(req, sel_registerName("setBundleIdentifier:"), kTargetBID);
    ((void (*)(id, SEL, id))objc_msgSend)(req, sel_registerName("setOptions:"), options);

    id svc = ((id (*)(id, SEL))objc_msgSend)((id)cSvc, sel_registerName("sharedInstance"));
    id ws  = ((id (*)(id, SEL))objc_msgSend)((id)cWS, sel_registerName("sharedInstance"));
    if (!svc || !ws) { SBKLog(@"拉起失败：service/workspace 空"); return; }

    SBKLog(@"发起拉起 (%@) mode=%@ locked=%d", why ?: @"?",
           gHeadfulMode == 1 ? @"headful" : (gHeadfulMode == 0 ? @"headless" : @"auto"), SBKIsLocked());
    @try {
        ((void (*)(id, SEL, id, id, id))objc_msgSend)(
            ws, sel_registerName("systemService:handleOpenApplicationRequest:withCompletion:"),
            svc, req, ^(NSError *e) {
                if (e) {
                    SBKLog(@"拉起回调失败 err=%@ (%ld) → 回退 SBSLaunch 前台档",
                           e.localizedDescription, (long)e.code);
                    SBKLaunchViaSBS(why);
                } else {
                    SBKLog(@"拉起回调 ok");
                }
            });
    } @catch (NSException *e) {
        SBKLog(@"拉起异常 %@", e.reason ?: @"?");
    }
}

// ===== 强制非挂起重启（挂起态专用）=====
// 老板 2026-11-19 实测：headless(suspended) 拉起后进程是挂起态，App 层插件根本没机会跑，
// 断言也不一定解挂 → 检测到 SSTOP 就再用 __ActivateSuspended=NO 发起一次启动。
static time_t gLastForceLaunchAt = 0;

// ===== v1.5.1：API 勘探（真机把 SpringBoard 里跟 home/lock/background 相关的方法名打进日志）=====
// 为什么需要：iOS 14 上 SBUIController 的 handleHomeButtonSinglePress、
// SBMainWorkspace 的 dismissAppSwitcherAndReturnToHomeScreen、SBLockScreenManager 的
// lockUIFromSource: 全都不存在（真机实测返回 NO），必须按真机实际方法名来实现「交回后台」。
static void SBKDumpClassAPI(const char *clsName) {
    Class c = objc_getClass(clsName);
    if (!c) { SBKLog(@"API: %s → 类不存在", clsName); return; }
    const char *kws[] = { "home", "lock", "dismiss", "background", "sleep", "button", "unlock", "suspend" };
    const int nkw = 8;

    for (int pass = 0; pass < 2; pass++) {
        Class target = (pass == 0) ? c : object_getClass((id)c);
        unsigned int n = 0;
        Method *ms = class_copyMethodList(target, &n);
        SBKLog(@"API: %s %s方法共 %u 个", clsName, pass == 0 ? "实例" : "类", n);
        for (unsigned i = 0; i < n; i++) {
            const char *nm = sel_getName(method_getName(ms[i]));
            if (!nm) continue;
            BOOL hit = NO;
            for (int k = 0; k < nkw; k++) {
                if (strcasestr(nm, kws[k])) { hit = YES; break; }
            }
            if (hit) SBKLog(@"   %s %s%s  <%s>", clsName, pass == 0 ? "-" : "+", nm,
                            method_getTypeEncoding(ms[i]) ?: "?");
        }
        free(ms);
    }
}

static void SBKDumpAPI(void) {
    SBKLog(@"===== API 勘探开始 =====");
    const char *classes[] = {
        "SBUIController", "SBMainWorkspace", "SBLockScreenManager", "SBBacklightController",
        "SpringBoard", "SBHomeScreenController", "SBHardwareButtonService",
        "SBIdleTimerGlobalCoordinator", "SBScreenWakeAnimationController",
        "SBApplicationController", "SBMainSwitcherControllerCoordinator"
    };
    for (int i = 0; i < 11; i++) SBKDumpClassAPI(classes[i]);
    SBKLog(@"===== API 勘探结束 =====");
}

// ===== v1.5.0：前台过一遍（prime）=====
// 老板定案的最终形态：把微信拉到前台停一会儿 → 回主屏 → 它自己保活；
// 下一次被系统杀掉，再来一遍。不做任何保活断言、不做场景欺骗。

// 回到主屏（让微信用最自然的方式进后台）。真机 API 勘探确认 iOS 14 可用：
//   SpringBoard -_simulateHomeButtonPress（等价按一下 Home）
//   SBUIController -handleHomeButtonSinglePressUp
//   SpringBoard -_resetToHomeScreen
static BOOL SBKGoHome(void) {
    id sb = SBKSpringBoard();
    if (SBKTryVoidSel(sb, "_simulateHomeButtonPress")) {
        usleep(300 * 1000);
        SBKLog(@"回主屏：SpringBoard _simulateHomeButtonPress");
        return YES;
    }
    Class cUI = objc_getClass("SBUIController");
    if (cUI) {
        id ui = nil;
        @try { ui = ((id (*)(id, SEL))objc_msgSend)((id)cUI, sel_registerName("sharedInstance")); }
        @catch (NSException *e) { (void)e; }
        SEL s1 = sel_registerName("handleHomeButtonSinglePressUp");
        if (ui && [ui respondsToSelector:s1]) {
            @try { ((BOOL (*)(id, SEL))objc_msgSend)(ui, s1); }
            @catch (NSException *e) { (void)e; }
            usleep(300 * 1000);
            SBKLog(@"回主屏：SBUIController handleHomeButtonSinglePressUp");
            return YES;
        }
    }
    if (SBKTryVoidSel(sb, "_resetToHomeScreen")) {
        usleep(300 * 1000);
        SBKLog(@"回主屏：SpringBoard _resetToHomeScreen");
        return YES;
    }
    SBKLog(@"回主屏：没有可用入口");
    return NO;
}

static void SBKStartPrime(NSString *why) {
    time_t now = time(NULL);
    if (gLastPrimeAt > 0 && (now - gLastPrimeAt) < 15) return;   // 15s 内不重复过前台
    gLastPrimeAt = now;

    SBKLog(@"===== 前台过一遍开始：%@ (locked=%d) =====", why ?: @"?", SBKIsLocked() ? 1 : 0);
    // 解锁 / 回主屏 / 锁屏都是 SpringBoard 内部状态操作，统一放主线程做（SBKLaunch 自己也会再保险解锁一次）
    dispatch_async(dispatch_get_main_queue(), ^{
        SBKUnlockDevice(@"过前台前");
        SBKLaunch(why);
    });

    if (gPrimeHoldSec <= 0) {
        SBKLog(@"xrkeep.prime=0 → 保持前台，不交回后台");
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(gPrimeHoldSec * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        pid_t p = SBKPidForTarget();
        if (p <= 0) {
            SBKLog(@"前台停留结束，但微信已不在（启动失败？）");
            return;
        }
        int st = SBKProcStatus(p);
        SBKLog(@"前台停留 %ds 结束 pid=%d stat=%d sceneFG=%d → 交回后台",
               gPrimeHoldSec, p, st, gTargetSceneFG);
        BOOL homeOK = SBKGoHome();
        // 默认「过完前台就恢复息屏」（无 xrkeep.stay 时）；息屏后微信自然回后台。
        if (access("/var/mobile/Library/SpringBoard/xrkeep.stay", F_OK) != 0) {
            SBKRelockDevice(homeOK ? @"过完前台恢复息屏" : @"回主屏不可用，直接恢复息屏");
        } else {
            SBKLog(@"xrkeep.stay 存在 → 保持前台不锁屏");
        }
        gLastPrimeAt = time(NULL);
    });
}

static void SBKForceRelaunch(NSString *why) {
    time_t now = time(NULL);
    if (gLastForceLaunchAt > 0 && (now - gLastForceLaunchAt) < 12) return;   // 12s 内不重复
    gLastForceLaunchAt = now;
    SBKLog(@"发起强制非挂起启动 (%@)", why ?: @"?");
    dispatch_async(dispatch_get_main_queue(), ^{ SBKLaunch(why); });
}

// 断言刚建立/刚切换后的 3s 复核：还没解挂就强制非挂起启动
static void SBKSuspendRecheck(NSString *tag) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                   SBKQueue(), ^{
        pid_t p2 = SBKPidForTarget();
        if (p2 <= 0) return;
        int s2 = SBKProcStatus(p2);
        if (s2 == SBK_SSTOP) {
            SBKLog(@"[%@] 断言未解挂 stat=%d → 强制非挂起启动", tag ?: @"?", s2);
            SBKForceRelaunch(tag);
        } else {
            SBKLog(@"[%@] 已解挂 stat=%d，进入持续运行", tag ?: @"?", s2);
        }
    });
}

// ===== 状态机 =====
static int    gFailCount = 0;
static time_t gLastLaunchAt = 0;
static dispatch_source_t gHealthTimer = nil;
static dispatch_source_t gExitSource = nil;
static pid_t  gWatchedPid = 0;
static int    gTick = 0;
static int    gLastProcStatus = -99;
static uint64_t gLastCPUTime = 0;
static int    gStallTicks = 0;       // 连续多少 tick CPU 时间没前进

static void SBKArmExitWatch(pid_t pid);

static void SBKTick(void) {
    pid_t pid = SBKPidForTarget();

    if (pid <= 0) {
        SBKDropAssertion(@"微信不在运行");
        gLastProcStatus = -99;
        if (gExitSource) {
            dispatch_source_cancel(gExitSource);
            gExitSource = nil;
            gWatchedPid = 0;
        }
        time_t now = time(NULL);
        NSTimeInterval wait = kLaunchBackoff[gFailCount < kLaunchBackoffCount ? gFailCount : kLaunchBackoffCount - 1];
        if (gLastLaunchAt > 0 && (now - gLastLaunchAt) < (time_t)wait) return;   // 退避中
        gLastLaunchAt = now;
        if (gFailCount < kLaunchBackoffCount) gFailCount++;
        SBKStartPrime(@"微信不在运行");
        return;
    }

    if (gWatchedPid != pid) {
        gLastCPUTime = 0;
        gStallTicks = 0;
        gLastProcStatus = -99;
        SBKArmExitWatch(pid);
    }

    if (gFailCount != 0) {
        SBKLog(@"微信已在运行 pid=%d，失败计数清零", pid);
        gFailCount = 0;
        gLastLaunchAt = 0;
    }

    // ===== 关键：区分「进程存在但被 suspend」与「真在跑」=====
    int st = SBKProcStatus(pid);
    uint64_t cpu = SBKTaskCPUTime(pid);
    BOOL cpuMoved = (cpu > 0 && cpu != gLastCPUTime);
    if (cpuMoved) {
        gLastCPUTime = cpu;
        gStallTicks = 0;
    } else if (cpu > 0) {
        gStallTicks++;
    }
    if (st != gLastProcStatus) {
        SBKLog(@"微信 pid=%d 状态 stat=%d %@ cpu=%llu", pid, st,
               st == SBK_SSTOP ? @"(SSTOP/挂起)" : (st < 0 ? @"(读取失败)" : @"(非SSTOP)"),
               (unsigned long long)cpu);
        gLastProcStatus = st;
    }
    // 两种判定：内核直接报 SSTOP，或 CPU 时间连续 3 个 tick（≈30s）毫无前进
    BOOL frozen = (st == SBK_SSTOP) || (gStallTicks >= 3);
    if (gStallTicks == 3) {
        SBKLog(@"CPU 时间连续 30s 未前进 (cpu=%llu) → 判定为冻结", (unsigned long long)cpu);
    }

    // v1.5.0：不做断言、不做场景欺骗。进程还在但被冻住 → 再走一遍「前台过一遍」自然解冻。
    // 冻结触发的重拉单独限流 5 分钟：避免「后台被系统冻结 → 频繁唤醒屏幕过前台」的循环。
    if (frozen) {
        time_t nowT = time(NULL);
        if (gLastPrimeAt == 0 || (nowT - gLastPrimeAt) > 300) {
            SBKStartPrime(@"进程存在但被冻结");
        }
    }

    gTick++;
}

static void SBKArmExitWatch(pid_t pid) {
    if (gExitSource) {
        dispatch_source_cancel(gExitSource);
        gExitSource = nil;
    }
    gWatchedPid = pid;
    dispatch_source_t src = dispatch_source_create(DISPATCH_SOURCE_TYPE_PROC, (uintptr_t)pid,
                                                   DISPATCH_PROC_EXIT, SBKQueue());
    if (!src) return;
    __weak typeof(src) weakSrc = src;
    dispatch_source_set_event_handler(src, ^{
        __strong typeof(weakSrc) strongSrc = weakSrc;
        SBKLog(@"微信退出事件 pid=%d", pid);
        SBKDropAssertion(@"进程退出");
        gWatchedPid = 0;
        if (strongSrc) {
            dispatch_source_cancel(strongSrc);
            if (gExitSource == strongSrc) gExitSource = nil;
        }
        // 立刻走一次状态机（会按退避阶梯发起拉起）
        gLastLaunchAt = 0;   // 退出是明确事件，不等退避
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                       SBKQueue(), ^{ SBKTick(); });
    });
    dispatch_resume(src);
    gExitSource = src;
    SBKLog(@"已挂微信退出事件 pid=%d", pid);
}

static void SBKStartHealthTimer(void) {
    if (gHealthTimer) return;
    gHealthTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, SBKQueue());
    if (!gHealthTimer) return;
    uint64_t interval = (uint64_t)kHealthIntervalSec * NSEC_PER_SEC;
    dispatch_source_set_timer(gHealthTimer,
                              dispatch_time(DISPATCH_TIME_NOW, (int64_t)interval),
                              interval, 2 * NSEC_PER_SEC);
    dispatch_source_set_event_handler(gHealthTimer, ^{ SBKTick(); });
    dispatch_resume(gHealthTimer);
}

// ===== 自实现 swizzle（不用 Logos / 不依赖 substrate 的 MSHookMessageEx）=====
// v1.2.0 关键修正：v1.0.0 用 %hook 生成的代码会引用 MSHookMessageEx，而该符号由注入框架
// 提供；Taurine(amfidebilitate) 环境下 SpringBoard 里可能拿不到 → dylib 加载失败、零日志。
// 现在改为纯 ObjC runtime 替换 IMP，零框架依赖，任何越狱都能加载。
typedef void (*SBKApplySettingsFn)(id, SEL, id, id, id, id);
typedef void (*SBKDidExitFn)(id, SEL, id);

static SBKApplySettingsFn gOrigApplySettings = NULL;
static SBKDidExitFn       gOrigDidExit = NULL;

static BOOL SBKHook(Class cls, SEL sel, IMP repl, IMP *origOut) {
    if (!cls || !sel) return NO;
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return NO;
    IMP orig = method_getImplementation(m);
    const char *types = method_getTypeEncoding(m);
    if (class_addMethod(cls, sel, repl, types)) {
        // 说明该方法继承自父类，addMethod 只在本类覆盖，父类原实现保留
        if (origOut) *origOut = orig;
        return YES;
    }
    method_setImplementation(m, repl);
    if (origOut) *origOut = orig;
    return YES;
}

// 场景设置落地前的唯一改动点：锁屏期把微信场景强行按在 foreground
static int gHookNo = 0;
static void SBKApplySettingsHook(id self, SEL _cmd, id settings, id scene, id ctx, id completion) {
    // 埋点：只记前 3 次，确认 hook 是否在启动期就被调用、是否死在半路
    int no = gHookNo < 100 ? ++gHookNo : 100;
    if (no <= 3) { char b[64]; snprintf(b, sizeof(b), "STAGE: h%d-enter\n", no); SBKRawLog(b); }

    if (gForceScene && gInForce == 0 && SBKSettled()) {
        if (no <= 3) { char b[64]; snprintf(b, sizeof(b), "STAGE: h%d-precheck\n", no); SBKRawLog(b); }
        BOOL locked = SBKIsLocked();
        if (no <= 3) { char b[64]; snprintf(b, sizeof(b), "STAGE: h%d-locked=%d\n", no, locked ? 1 : 0); SBKRawLog(b); }
        if (locked) {
            @try {
                NSString *bid = SBKSceneBID(scene);
                if ([bid isEqualToString:kTargetBID]) {
                    static time_t lastLog = 0;
                    time_t nowT = time(NULL);
                    if (nowT - lastLog >= 5) {
                        lastLog = nowT;
                        SBKLog(@"锁屏期微信场景设置 → 强制 foreground");
                    }
                    gInForce = 1;
                    SBKForceForeground(settings);
                    gInForce = 0;
                }
            } @catch (NSException *e) {
                gInForce = 0;
                SBKLog(@"场景扶持异常 %@", e.reason ?: @"?");
            }
        }
    }
    if (no <= 3) { char b[64]; snprintf(b, sizeof(b), "STAGE: h%d-call-orig\n", no); SBKRawLog(b); }
    if (gOrigApplySettings) gOrigApplySettings(self, _cmd, settings, scene, ctx, completion);
    if (no <= 3) { char b[64]; snprintf(b, sizeof(b), "STAGE: h%d-orig-done\n", no); SBKRawLog(b); }

    // 采集微信场景的前台状态（只读，供有头模式的健康复核用）
    if (gHeadfulMode != 0 && SBKSettled()) {
        @try {
            NSString *bid2 = SBKSceneBID(scene);
            if ([bid2 isEqualToString:kTargetBID]) {
                int fg = SBKSettingsForeground(settings);
                if (fg >= 0 && fg != gTargetSceneFG) {
                    gTargetSceneFG = fg;
                    SBKLog(@"微信场景前台状态 → %@ (locked=%d)",
                           fg ? @"前台" : @"非前台", SBKIsLocked() ? 1 : 0);
                }
            }
        } @catch (NSException *e) { (void)e; }
    }
}

static void SBKDidExitHook(id self, SEL _cmd, id ctx) {
    @try {
        id app = (id)self;
        NSString *bid = [app valueForKey:@"bundleIdentifier"];
        if (![bid isKindOfClass:[NSString class]]) {
            bid = ((id (*)(id, SEL))objc_msgSend)(app, sel_registerName("bundleIdentifier"));
        }
        if ([bid isKindOfClass:[NSString class]] && [bid isEqualToString:kTargetBID]) {
            // 退出原因诊断：FBProcessExitContext → exitReason（reason/code/description）是最直接的死因
            NSString *ctxDesc = @"?";
            NSString *reasonDesc = @"?";
            @try { ctxDesc = [ctx description] ?: @"nil"; } @catch (NSException *e) { (void)e; }
            @try {
                id r = [ctx valueForKey:@"exitReason"];
                if (r) {
                    id d = nil;
                    @try { d = [r valueForKey:@"description"]; } @catch (NSException *e) { (void)e; }
                    reasonDesc = [NSString stringWithFormat:@"%@ | status=%d code=%llu domain=%@",
                                  r, (int)[[r valueForKey:@"status"] intValue],
                                  (unsigned long long)[[r valueForKey:@"code"] unsignedLongLongValue],
                                  [r valueForKey:@"domain"] ?: @"-"];
                    if (d) reasonDesc = [reasonDesc stringByAppendingFormat:@" | desc=%@", d];
                }
            } @catch (NSException *e) { (void)e; }
            SBKLog(@"_didExitWithContext 微信退出，清理断言 | reason=%@ | ctx=%@", reasonDesc, ctxDesc);
            dispatch_async(SBKQueue(), ^{
                SBKDropAssertion(@"_didExitWithContext");
                gLastLaunchAt = 0;
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                               SBKQueue(), ^{ SBKTick(); });
            });
        }
    } @catch (NSException *e) {
        SBKLog(@"_didExitWithContext 异常 %@", e.reason ?: @"?");
    }
    if (gOrigDidExit) gOrigDidExit(self, _cmd, ctx);
}

// ===== 入口（普通 constructor，不依赖 Logos）=====
__attribute__((constructor)) static void SBKInit(void) {
    // ① 先开两路日志：纯 C，不依赖 ObjC / NSString，ctor 第一件事就能落盘
    errno = 0;
    gLogFd = open(kLogPathA.fileSystemRepresentation, O_WRONLY | O_CREAT | O_APPEND, 0644);
    int errA = errno;
    errno = 0;
    gLogFdB = open(kLogPathB.fileSystemRepresentation, O_WRONLY | O_CREAT | O_APPEND, 0644);
    int errB = errno;

    char head[512];
    snprintf(head, sizeof(head),
             "\n===== XRWeChatKeep v1.6.0 PROBE pid=%d proc=%s openA=%d(e%d) openB=%d(e%d) =====\n",
             getpid(), getprogname() ?: "?", gLogFd, errA, gLogFdB, errB);
    SBKRawLog(head);
    gCtorAt = time(NULL);

    // 急停开关：存在 /var/mobile/Library/SpringBoard/xrkeep.off 就完全不装 hook
    if (access("/var/mobile/Library/SpringBoard/xrkeep.off", F_OK) == 0) {
        SBKRawLog("KILLSWITCH: xrkeep.off 存在，跳过全部逻辑\n");
        return;
    }

    // ② 只有 SpringBoard 才跑真正的保活逻辑；Safari 等探针进程到这就结束
    NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
    if (![bid isEqualToString:@"com.apple.springboard"]) {
        SBKLog(@"探针进程 bid=%@ ctor 已执行 → 注入通路正常，本进程不做保活", bid ?: @"nil");
        return;
    }

    SBKRawLog("STAGE: springboard-ctor-enter\n");

    Class cSceneMgr = objc_getClass("FBSceneManager");
    BOOL okScene = SBKHook(cSceneMgr,
                           sel_registerName("_applyMutableSettings:toScene:withTransitionContext:completion:"),
                           (IMP)SBKApplySettingsHook, (IMP *)&gOrigApplySettings);
    SBKRawLog("STAGE: hook-scene-done\n");
    Class cApp = objc_getClass("SBApplication");
    BOOL okExit = SBKHook(cApp, sel_registerName("_didExitWithContext:"),
                          (IMP)SBKDidExitHook, (IMP *)&gOrigDidExit);
    SBKLog(@"hook 结果 sceneMgr=%d(FBSceneManager=%s) didExit=%d(SBApplication=%s)",
           okScene ? 1 : 0, cSceneMgr ? "yes" : "nil", okExit ? 1 : 0, cApp ? "yes" : "nil");
    SBKRawLog("STAGE: hook-all-done, load mode\n");

    // 有头 / 无头模式判定（无密码设备默认有头）
    SBKLoadMode();

    // ③ 3s 只做「无副作用」的状态观测（读 pid / 读状态 / 读锁屏），不碰任何系统单例构建
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), SBKQueue(), ^{
        SBKRawLog("STAGE: selfcheck-enter\n");
        @try {
            pid_t pid = SBKPidForTarget();
            SBKRawLog("STAGE: selfcheck-pid-done\n");
            int st = SBKProcStatus(pid);
            SBKRawLog("STAGE: selfcheck-stat-done\n");
            int locked = SBKIsLocked() ? 1 : 0;
            SBKRawLog("STAGE: selfcheck-locked-done\n");
            SBKLog(@"启动自检 pid=%d stat=%d locked=%d", pid, st, locked);
        } @catch (NSException *e) {
            SBKLog(@"自检异常 %@", e.reason ?: @"?");
            SBKRawLog("STAGE: selfcheck-exception\n");
        }
    });

    // ④ 15s 后才开始「动系统」（断言 / 退出监听 / 健康定时器）。给 SpringBoard 充分启动时间。
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(15.0 * NSEC_PER_SEC)), SBKQueue(), ^{
        SBKRawLog("STAGE: active-enter\n");
        @try {
            pid_t pid = SBKPidForTarget();
            if (pid > 0) {
                SBKArmExitWatch(pid);
                SBKRawLog("STAGE: active-watch-done\n");
                SBKEnsureAssertion(pid);
                SBKRawLog("STAGE: active-assert-done\n");
            }
            SBKStartHealthTimer();
            SBKRawLog("STAGE: active-timer-done\n");
            // 诊断开关：/var/mobile/Library/SpringBoard/xrkeep.dump 存在时输出 API 勘探结果
            if (access("/var/mobile/Library/SpringBoard/xrkeep.dump", F_OK) == 0) SBKDumpAPI();
            SBKTick();
            SBKRawLog("STAGE: active-tick-done\n");
        } @catch (NSException *e) {
            SBKLog(@"启动异常 %@", e.reason ?: @"?");
            SBKRawLog("STAGE: active-exception\n");
        }
    });
}
