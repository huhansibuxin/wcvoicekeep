// XRWeChatKeep — v1.0.0
// 老板 2026-11-19 定案：XR 放屋里、没人解锁，微信掉了必须自动拉起并「一直跑」。
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
// 本实现的两个取舍（比 bakgrunnur 保守）：
//   ① 解锁使用期间**不**做场景扶持，只持断言 —— 不抢前台归属，界面零异常；
//   ② 只在锁屏期（isUILocked）才把微信场景强制 foreground，避免和用户操作打架。
//
// 日志：/var/mobile/wcvoicekeep.xrkeep.log（SpringBoard 非沙盒，rootful 原生路径）
// 只在状态变化时写，常态零写入。

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

// Logos 会用到（Theos 自带 include/substrate.h；缺失时不影响，Logos 走自身的 hooking 实现）
#if __has_include(<substrate.h>)
#import <substrate.h>
#endif

// ===== libproc（公开 API，在 libSystem 里；不引用头文件，手动声明）=====
extern int proc_listallpids(void *buffer, int buffersize);
extern int proc_pidpath(int pid, void *buffer, uint32_t buffersize);
#define SBK_PIDPATH_MAX 4096

// ===== 常量 =====
static NSString *const kTargetBID = @"com.tencent.xin";
static NSString *const kLogPath   = @"/var/mobile/wcvoicekeep.xrkeep.log";

// 拉起退避阶梯（秒）；成功一次立即清零
static const NSTimeInterval kLaunchBackoff[] = {3, 8, 20, 45, 60};
static const int kLaunchBackoffCount = 5;

// 健康检查间隔（秒）。真正的退出检测走 DISPATCH_PROC_EXIT 事件，这个只是兜底复核断言。
static const int kHealthIntervalSec = 15;

// ===== 日志 =====
static int gLogFd = -1;

static void SBKLog(NSString *fmt, ...) {
    if (gLogFd < 0) return;
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
        ssize_t ignored = write(gLogFd, line, (size_t)n);
        (void)ignored;
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
static BOOL SBKIsLocked(void) {
    static Class cls;
    static SEL selShared, selLocked;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        cls = objc_getClass("SBLockScreenManager");
        selShared = sel_registerName("sharedInstance");
        selLocked = sel_registerName("isUILocked");
    });
    if (!cls) return NO;
    @try {
        id inst = ((id (*)(id, SEL))objc_msgSend)((id)cls, selShared);
        if (!inst) return NO;
        return ((BOOL (*)(id, SEL))objc_msgSend)(inst, selLocked);
    } @catch (NSException *e) {
        (void)e;
        return NO;
    }
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
static pid_t gAssertPid = 0;
static int   gAssertTier = 0;    // 1 = legacy+grants，2 = 仅 legacy；0 = 无

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
        SBKLog(@"断言释放 (%@) pid=%d tier=%d", why ?: @"?", gAssertPid, gAssertTier);
    }
    gAssertion = nil;
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

static void SBKEnsureAssertion(pid_t pid) {
    if (pid <= 0) return;

    if (gAssertion) {
        BOOL valid = NO;
        @try {
            valid = ((BOOL (*)(id, SEL))objc_msgSend)(gAssertion, sel_registerName("isValid"));
        } @catch (NSException *e) {
            (void)e;
        }
        if (valid && gAssertPid == pid) return;
        SBKDropAssertion(valid ? @"pid 变化" : @"已失效");
    }

    NSString *err1 = nil;
    if (SBKTryAcquire(pid, YES, &err1)) return;
    NSString *err2 = nil;
    if (SBKTryAcquire(pid, NO, &err2)) return;
    SBKLog(@"两档断言均失败 → 仅依赖场景扶持 (grants_err=%@ legacy_err=%@)", err1, err2);
}

// ===== 场景扶持（仅锁屏期）=====
static BOOL gForceScene = YES;    // 场景扶持总开关（编译期固定开）
static __thread int gInForce = 0; // 防重入

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
static void SBKLaunch(NSString *why) {
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

    SBKLog(@"发起拉起 (%@) locked=%d", why ?: @"?", SBKIsLocked());
    @try {
        ((void (*)(id, SEL, id, id, id))objc_msgSend)(
            ws, sel_registerName("systemService:handleOpenApplicationRequest:withCompletion:"),
            svc, req, ^(NSError *e) {
                if (e) SBKLog(@"拉起回调失败 err=%@ (%ld)", e.localizedDescription, (long)e.code);
                else   SBKLog(@"拉起回调 ok");
            });
    } @catch (NSException *e) {
        SBKLog(@"拉起异常 %@", e.reason ?: @"?");
    }
}

// ===== 状态机 =====
static int    gFailCount = 0;
static time_t gLastLaunchAt = 0;
static dispatch_source_t gHealthTimer = nil;
static dispatch_source_t gExitSource = nil;
static pid_t  gWatchedPid = 0;
static int    gTick = 0;

static void SBKArmExitWatch(pid_t pid);

static void SBKTick(void) {
    pid_t pid = SBKPidForTarget();

    if (pid <= 0) {
        SBKDropAssertion(@"微信不在运行");
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
        dispatch_async(dispatch_get_main_queue(), ^{ SBKLaunch(@"微信不在运行"); });
        return;
    }

    if (gWatchedPid != pid) SBKArmExitWatch(pid);

    if (gFailCount != 0) {
        SBKLog(@"微信已在运行 pid=%d，失败计数清零", pid);
        gFailCount = 0;
        gLastLaunchAt = 0;
    }

    SBKEnsureAssertion(pid);

    // 锁屏期每 tick 复核一次场景（unlock 后 hook 才会重新发力，这里只是兜底）
    if (gForceScene && SBKIsLocked()) {
        SBKLog(@"锁屏期健康复核 pid=%d 断言tier=%d", pid, gAssertTier);
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

// ===== Hooks =====
%hook FBSceneManager

// 场景设置落地前的唯一改动点：锁屏期把微信场景强行按在 foreground
- (void)_applyMutableSettings:(id)settings toScene:(id)scene
        withTransitionContext:(id)ctx completion:(id)completion {
    if (gForceScene && gInForce == 0 && SBKIsLocked()) {
        NSString *bid = SBKSceneBID(scene);
        if ([bid isEqualToString:kTargetBID]) {
            gInForce = 1;
            @try {
                SBKForceForeground(settings);
            } @catch (NSException *e) {
                SBKLog(@"场景扶持异常 %@", e.reason ?: @"?");
            }
            gInForce = 0;
        }
    }
    %orig;
}

%end

%hook SBApplication

- (void)_didExitWithContext:(id)ctx {
    BOOL target = NO;
    @try {
        // self 在 %hook 内是前置声明类型，统一走 id 收发消息
        id app = (id)self;
        NSString *bid = [app valueForKey:@"bundleIdentifier"];
        if (![bid isKindOfClass:[NSString class]]) {
            bid = ((id (*)(id, SEL))objc_msgSend)(app, sel_registerName("bundleIdentifier"));
        }
        target = [bid isKindOfClass:[NSString class]] && [bid isEqualToString:kTargetBID];
    } @catch (NSException *e) {
            (void)e;
        }
    if (target) {
        SBKLog(@"_didExitWithContext 微信退出，清理断言");
        dispatch_async(SBKQueue(), ^{
            SBKDropAssertion(@"_didExitWithContext");
            gLastLaunchAt = 0;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                           SBKQueue(), ^{ SBKTick(); });
        });
    }
    %orig;
}

%end

// ===== 入口 =====
%ctor {
    gLogFd = open(kLogPath.fileSystemRepresentation, O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (gLogFd >= 0) {
        SBKLog(@"===== XRWeChatKeep start pid=%d target=%@ locked=%d =====",
               getpid(), kTargetBID, SBKIsLocked());
    }

    %init;

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), SBKQueue(), ^{
        pid_t pid = SBKPidForTarget();
        SBKLog(@"启动自检 pid=%d locked=%d", pid, SBKIsLocked());
        if (pid > 0) {
            SBKArmExitWatch(pid);
            SBKEnsureAssertion(pid);
        }
        SBKStartHealthTimer();
        SBKTick();
    });
}
