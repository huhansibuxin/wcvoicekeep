// SBKeepAlive — SpringBoard 侧（v2.0.31「后台保活 / 只负责拉起」）
//
// 唯一职责：daemon 发现 wxkb_plugin（微信输入法键盘扩展）不在了，发一条 Darwin 通知过来，
// 这里就在 SpringBoard 里弹一下键盘 —— 系统收到真实键盘请求才会去 spawn 键盘扩展，
// 扩展起来后立刻收键盘，并发 kbd.up 让 daemon 在新 pid 上重挂退出事件监视。
//
// v2.0.31 剥离（老板 2026-11-07）：
//   注入微信侧 wcprewarmfix.dylib 整套已删除（黑屏修复已合进 wctweak），随之删掉：
//     * com.wcvoicekeep.prewarm.ctor 探针回调 + 注册（只写日志的自证通道）
//     * com.wcvoicekeep.prewarm.reveal 通道 + WCVKRevealRun（v2.0.19 起已降级为「只记录」）
//     * WCVKMarker 写 marker 文件（每次启动两次 open/write，纯诊断开销）
//   本文件不再引用任何微信侧注入/黑屏逻辑。
//
// v2.0.31 性能（不卡 SpringBoard 主线程，老板要求「能缓存就缓存、别每次全局扫描」）：
//   * 扩展 pid 全程缓存：命中时只做 1 次 proc_pidpath 单点校验（防 pid 复用），
//     只有缓存失效才全表扫一次；扫描用 C 串后缀比较，零 NSString 分配。
//   * T+0.6s / T+1.2s / T+3s / DidShow 里那 4 次进程表扫描纯粹是给日志填数字，全删。
//   * 新 pid 通过 com.wcvoicekeep.kbd.up 的 notify state 直接递给 daemon，两端都不用遍历。
//   * 日志走后台串行队列 + 持久 fd（一次 open，之后只 write），主线程不再做
//     attributesOfItemAtPath / open / seekToEnd / close 这一串同步文件 IO。
//   * pure 版 SBLog 编译期整体剥离，连参数求值都不发生（KbdSceneTag 等不会被调用）。
//
// 关键实测结论（保留备查，别改）：
//   * 键盘只能由「有真实输入焦点的前台宿主 + SpringBoard 自己的 scene」发起；
//     connectedScenes 无序，必须先取 keyWindow.windowScene，否则会选中
//     SBSystemAperture* 这种没有显示层的辅助 scene，窗口 isKeyWindow=1 但键盘永不出（8/8 失败）
//   * 窗口必须 windowLevel = Normal+1 且 makeKeyAndVisible；2pt 高会被判定不可见
//   * 收键盘必须先 resign -> 等 0.35s 动画走完 -> 再拆窗口/恢复 keyWindow，
//     顺序反了键盘会一直留在桌面（v2.0.2 实测）
//   * ⛔ 绝不要调 SBSLaunchApplicationWithIdentifier 做前台激活：该私有 API 在
//     SpringBoard 主线程同步阻塞 11 秒（v2.0.18 实测全系统卡死），v2.0.19 起整条删除

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#include <stdint.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <time.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <notify.h>

// iOS SDK 没有 macOS 的 libproc.h —— 只声明用到的两个 libproc 函数（iOS 上在 libSystem 里）
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

#define WCVK_BUILD_TAG "v2.0.31-roothide"

// 键盘扩展进程的精确特征：可执行文件路径以 /wxkb_plugin.appex/wxkb_plugin 结尾
static const char kKbdExtPathSuffix[] = "/wxkb_plugin.appex/wxkb_plugin";

// ===== 日志（纯净版编译期整体剥离；日志版强制后台队列）=====
#ifndef WCVK_NO_LOG
#define WCVK_NO_LOG 0
#endif

#if WCVK_NO_LOG
#define SBLog(...) do {} while (0)
#else
static dispatch_queue_t SBLogQueue(void) {
    static dispatch_queue_t q = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        q = dispatch_queue_create("com.wcvoicekeep.sb.log", DISPATCH_QUEUE_SERIAL);
    });
    return q;
}

static int gSBLogFd = -1;

static void SBLog(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    // 时间戳在调用线程就生成，投递到后台后才写盘也不会错序
    NSString *line = [NSString stringWithFormat:@"[%@] %@\n", [NSDate date], msg];
    NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
    dispatch_async(SBLogQueue(), ^{
        if (gSBLogFd < 0)
            gSBLogFd = open("/var/mobile/wetypekeepalive.log",
                            O_WRONLY | O_CREAT | O_APPEND, 0644);
        if (gSBLogFd < 0) return;
        struct stat st;
        if (fstat(gSBLogFd, &st) == 0 && st.st_size > 2 * 1024 * 1024)
            ftruncate(gSBLogFd, 0);
        (void)write(gSBLogFd, data.bytes, data.length);
    });
}
#endif

// ===== 进程检测：缓存 pid + 单点校验，缓存失效才全表扫一次 =====
// v2.0.31（老板要求）：能缓存就用缓存，不要每次全局扫描/遍历。
//   * 命中缓存时只做 1 次 proc_pidpath 单点校验（防 pid 复用），零全表扫描
//   * 只有缓存失效（扩展被回收 / pid 被复用）才全表扫一次并写回缓存
//   * 全表扫描用 C 串后缀比较，不再为每个 pid 构造 NSString
static int gKbdPidCache = 0;
static const size_t kKbdSuffixLen = sizeof(kKbdExtPathSuffix) - 1;

static BOOL KbdPidMatches(int pid) {
    if (pid <= 1) return NO;
    char path[PROC_PIDPATHINFO_MAXSIZE] = {0};
    if (proc_pidpath(pid, path, sizeof(path)) <= 0) return NO;
    size_t l = strlen(path);
    return l >= kKbdSuffixLen &&
           memcmp(path + l - kKbdSuffixLen, kKbdExtPathSuffix, kKbdSuffixLen) == 0;
}

static int KbdScanPid(void) {
    int n = proc_listallpids(NULL, 0);
    if (n <= 0) return 0;
    int cap = n + 64;
    pid_t *pids = (pid_t *)calloc((size_t)cap, sizeof(pid_t));
    if (!pids) return 0;
    int cnt = proc_listallpids(pids, cap * (int)sizeof(pid_t));
    // 进程数在两次调用之间涨过预留量时，重扫一次（鲁棒性）
    if (cnt >= cap) {
        free(pids);
        n = proc_listallpids(NULL, 0);
        if (n <= 0) return 0;
        cap = n + 128;
        pids = (pid_t *)calloc((size_t)cap, sizeof(pid_t));
        if (!pids) return 0;
        cnt = proc_listallpids(pids, cap * (int)sizeof(pid_t));
    }
    int found = 0;
    for (int i = 0; i < cnt; i++) {
        char path[PROC_PIDPATHINFO_MAXSIZE] = {0};
        if (proc_pidpath(pids[i], path, sizeof(path)) <= 0) continue;
        size_t l = strlen(path);
        if (l >= kKbdSuffixLen &&
            memcmp(path + l - kKbdSuffixLen, kKbdExtPathSuffix, kKbdSuffixLen) == 0) {
            found = pids[i]; break;
        }
    }
    free(pids);
    gKbdPidCache = found;
    return found;
}

static int KbdExtPid(void) {
    if (gKbdPidCache > 1 && KbdPidMatches(gKbdPidCache)) return gKbdPidCache;
    gKbdPidCache = 0;
    return KbdScanPid();
}

// ===== Darwin 通知：把新扩展 pid 直接放进 notify state 递给 daemon =====
// daemon 收到 kbd.up 后用 notify_get_state 取 pid 直接挂监视，两端都零全表扫描。
// state=0 或单点校验不过时 daemon 回退一次扫描，不影响可靠性。
static int gKbdUpToken = 0;
static void KbdPostUp(void) {
    int pid = KbdExtPid();
    if (gKbdUpToken) notify_set_state(gKbdUpToken, (uint64_t)(pid > 0 ? pid : 0));
    notify_post("com.wcvoicekeep.kbd.up");
    SBLog(@"[KBDWARM] kbd.up posted (state pid=%d)", pid);
}

// ===== 宿主 scene 选择（实测关键：必须拿到有显示层的那个）=====
static UIWindowScene *KbdWarmScene(void) {
    UIApplication *app = [UIApplication sharedApplication];
    // ① key window 所属 scene —— 一定是有显示层的那一个
    UIWindow *kw = app.keyWindow;
    if (kw.windowScene) return kw.windowScene;
    // ② 含桌面/切换器/锁屏窗口的 scene
    for (UIScene *s in app.connectedScenes) {
        if (![s isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *w in ((UIWindowScene *)s).windows) {
            NSString *cn = NSStringFromClass([w class]);
            if ([cn containsString:@"HomeScreen"] || [cn containsString:@"Switcher"] ||
                [cn containsString:@"CoverSheet"]) {
                return (UIWindowScene *)s;
            }
        }
    }
    // ③ 兜底：排除灵动岛辅助 scene（没有正常显示层，键盘永不弹）
    for (UIScene *s in app.connectedScenes) {
        if (![s isKindOfClass:[UIWindowScene class]]) continue;
        NSString *cn = NSStringFromClass([s class]);
        if ([cn containsString:@"Aperture"] || [cn containsString:@"Curtain"]) continue;
        if (s.activationState == UISceneActivationStateForegroundActive) return (UIWindowScene *)s;
    }
    return nil;
}

static NSString *KbdSceneTag(UIWindowScene *sc) {
    NSMutableString *m = [NSMutableString stringWithFormat:@"%s(%lu windows:",
                          NSStringFromClass([sc class]).UTF8String,
                          (unsigned long)sc.windows.count];
    for (UIWindow *w in sc.windows) {
        [m appendFormat:@" %s", NSStringFromClass([w class]).UTF8String];
    }
    [m appendString:@")"];
    return m;
}

// ===== 预热：建最小窗口 + 文本框 -> becomeFirstResponder -> 系统去 spawn 键盘扩展 =====
static UIWindow    *gWarmWindow = nil;
static UITextField *gWarmField = nil;
static UIWindow    *gPrevKeyWindow = nil;
static BOOL         gWarmBusy = NO;
static BOOL         gDidShow = NO;
static BOOL         gUpPosted = NO;   // 本次预热是否已发过 kbd.up（去抖）
static id           gShowObs = nil;
static id           gHideObs = nil;

static void KbdWarmupFinish(NSString *tag);

static void KbdInstallObservers(void) {
    if (gShowObs) return;
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    gShowObs = [nc addObserverForName:UIKeyboardDidShowNotification object:nil
                                queue:[NSOperationQueue mainQueue]
                           usingBlock:^(NSNotification *n) {
        gDidShow = YES;
        SBLog(@"[KBDWARM] *** UIKeyboardDidShow 收到 = 键盘弹出来了，扩展应已被系统 spawn");
        // 告诉 daemon：扩展已经起来，去新 pid 上重新挂退出事件（事件驱动，零轮询）。
        // DidShow 在一次预热里会被系统连发很多次（实测 12 次/秒级），
        // 每次都要 daemon 遍历进程表重挂 —— 纯浪费。按「3s 去抖」只发一次。
        static time_t sLastUpAt = 0;
        time_t nowT = time(NULL);
        if (!gUpPosted || nowT - sLastUpAt >= 3) {
            gUpPosted = YES;
            sLastUpAt = nowT;
            // 稍等 0.25s 再取 pid 发 kbd.up：DidShow 那一刻扩展可能刚被 spawn，
            // 缓存还没建立；这段延迟远小于扩展的 3s 回收窗口。
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ KbdPostUp(); });
        } else {
            SBLog(@"[KBDWARM] kbd.up 去抖：本次预热已发过，忽略重复 DidShow");
        }
        // 键盘一弹出来就立刻收：扩展进程这时已在内存里，收键盘不会把它带走
        // （它靠 exit timeout=3 才回收）。放到下一轮 runloop 避开键盘正在 setup 的瞬间。
        if (gWarmBusy && gWarmField) {
            dispatch_async(dispatch_get_main_queue(), ^{
                KbdWarmupFinish(@"DidShow-immediate");
                SBLog(@"[KBDWARM] DidShow 即刻收键盘");
            });
        }
    }];
    gHideObs = [nc addObserverForName:UIKeyboardDidHideNotification object:nil
                                queue:[NSOperationQueue mainQueue]
                           usingBlock:^(NSNotification *n) {
        gDidShow = NO;
        SBLog(@"[KBDWARM] *** UIKeyboardDidHide 收到");
    }];
}

static void KbdWarmupFinish(NSString *tag) {
    // 收尾顺序（v2.0.2 实测）：resign 生效 -> 让动画先走完 -> 再销毁窗口、恢复 key window。
    // 幂等，可重复调用。
    UITextField *f = gWarmField;
    UIWindow *w = gWarmWindow;
    UIWindow *prev = gPrevKeyWindow;
    gWarmField = nil;
    gWarmWindow = nil;
    gPrevKeyWindow = nil;

    if (f) {
        BOOL ok = NO;
        @try { ok = [f resignFirstResponder]; } @catch (NSException *e) {}
        @try { [f endEditing:YES]; } @catch (NSException *e) {}
        SBLog(@"[KBDWARM] %@ resignFirstResponder=%d", tag, ok);
    }
    if (!f && !w) return;

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (f) @try { [f removeFromSuperview]; } @catch (NSException *e) {}
        if (w) {
            w.hidden = YES;
            w.rootViewController = nil;
        }
        if (prev) [prev makeKeyWindow];   // 返回 void
        SBLog(@"[KBDWARM] %@ 窗口清理完成（键盘收起动画已走完）", tag);
    });
}

static void KbdWarmupRun(NSString *reason) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (gWarmBusy) { SBLog(@"[KBDWARM] skip, busy (%@)", reason); return; }
        gWarmBusy = YES;
        gUpPosted = NO;              // 新一轮预热，允许发一次 kbd.up

        // ★ 缓存优先：命中时只做 1 次 proc_pidpath 单点校验；扩展已在跑就完全没必要弹键盘
        if (KbdExtPid() > 0) {
            SBLog(@"[KBDWARM] skip: wxkb_plugin 已在运行，无需预热");
            gWarmBusy = NO;
            return;
        }
        UIWindowScene *scene = KbdWarmScene();
        if (!scene) {
            SBLog(@"[KBDWARM] ABORT: 没有可用的宿主 UIWindowScene");
            gWarmBusy = NO;
            return;
        }
        SBLog(@"[KBDWARM] ===== start (%@) host scene = %@ =====", reason, KbdSceneTag(scene));

        KbdInstallObservers();
        gDidShow = NO;

        UIWindow *w = [[UIWindow alloc] initWithWindowScene:scene];
        w.frame = CGRectMake(20, 100, 180, 44);
        w.windowLevel = UIWindowLevelNormal + 1;
        w.backgroundColor = [UIColor clearColor];
        w.rootViewController = [[UIViewController alloc] init];
        w.rootViewController.view.backgroundColor = [UIColor clearColor];
        gPrevKeyWindow = [[UIApplication sharedApplication] keyWindow];
        [w makeKeyAndVisible];

        UITextField *tf = [[UITextField alloc] initWithFrame:CGRectMake(0, 0, 160, 40)];
        tf.autocorrectionType = UITextAutocorrectionTypeNo;
        tf.spellCheckingType = UITextSpellCheckingTypeNo;
        tf.textColor = [UIColor clearColor];
        tf.tintColor = [UIColor clearColor];
        tf.backgroundColor = [UIColor clearColor];
        tf.inputAssistantItem.leadingBarButtonGroups = @[];
        tf.inputAssistantItem.trailingBarButtonGroups = @[];
        [w.rootViewController.view addSubview:tf];
        BOOL became = [tf becomeFirstResponder];

        gWarmWindow = w;
        gWarmField = tf;
        SBLog(@"[KBDWARM] becomeFirstResponder=%d isFirstResponder=%d isKeyWindow=%d",
              became, (int)tf.isFirstResponder, (int)w.isKeyWindow);

        // T+0.6s：确认键盘是否真弹，只补一次（绝不做 3 连重试 —— 键盘会在桌面反复闪）
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            SBLog(@"[KBDWARM] T+0.6s keyboardShown=%d", gDidShow);
            if (!gDidShow && gWarmField && !gWarmField.isFirstResponder) {
                @try { [gWarmField becomeFirstResponder]; } @catch (NSException *e) {}
            }
        });

        // T+1.2s：兜底收键盘（正常路径在 DidShow 那一刻已收）。SpringBoard 里
        // UIKeyboardDidShow 经常收不到，所以无论有没有收到，到点都无条件收一遍。
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            KbdWarmupFinish(@"T+1.2s-fallback");
            SBLog(@"[KBDWARM] T+1.2s 兜底收键盘完成");
        });

        // T+3s：释放 busy（无论成败都要释放，否则下次预热会被 busy 永久挡住）
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            SBLog(@"[KBDWARM] T+3s FINAL keyboardShown=%d", gDidShow);
            KbdWarmupFinish(@"T+3s-final");
            gWarmBusy = NO;
        });
    });
}

// ===== Darwin 通知入口（daemon -> SpringBoard）：只此一个通道 =====
static void WCVKNotifyCallback(CFNotificationCenterRef center, void *observer,
                               CFStringRef name, const void *object,
                               CFDictionaryRef userInfo) {
    if ([(__bridge NSString *)name isEqualToString:@"com.wcvoicekeep.kbd.warmup"])
        KbdWarmupRun(@"darwin-notify");
}

__attribute__((constructor))
static void WCVKInit(void) {
    SBLog(@"[KBDWARM] dylib loaded pid=%d build=%s", getpid(), WCVK_BUILD_TAG);
    // 键盘显示/隐藏观察先装好（daemon 侧靠 kbd.up 重新挂监视）
    dispatch_async(dispatch_get_main_queue(), ^{ KbdInstallObservers(); });

    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                    NULL, WCVKNotifyCallback,
                                    CFSTR("com.wcvoicekeep.kbd.warmup"),
                                    NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
    SBLog(@"[KBDWARM] darwin notify com.wcvoicekeep.kbd.warmup registered");

    // kbd.up 的 token 只用来写 notify state（把新扩展 pid 递给 daemon），不注册回调
    notify_register_check("com.wcvoicekeep.kbd.up", &gKbdUpToken);
}
