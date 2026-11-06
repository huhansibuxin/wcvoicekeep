// SBKeepAlive — SpringBoard 侧（2.0.0「后台保活」）
//
// 唯一职责：daemon 发现 wxkb_plugin（微信输入法键盘扩展）不在了，发一条 Darwin 通知过来，
// 这里就在 SpringBoard 里弹一下键盘 —— 系统收到真实键盘请求才会去 spawn 键盘扩展，
// 扩展起来后立刻收键盘。扩展一起来，daemon 就能在它的新 pid 上重新挂退出事件监视。
//
// 2.0.0 相对 1.9.x 的删除项（老板 2026-11-06 定案）：
//   * 微信输入法主程序（com.tencent.wetype）PiP 保活 / FBScene 拦截 / scene 保活 —— 整套删除
//     （输入法更新后不再需要，主程序完全不管）
//   * 隐藏键盘那一整套（KbdForceHide* / KbdDumpWindows / alpha 压制 / 挪屏外）—— 实测无效，
//     桌面弹键盘无解，接受它弹
//   * alert 备选通道 / PKHost 无头 spawn 探测 / 键盘私有 API dump —— 实验代码全部删除
//
// 关键实测结论（保留备查）：
//   * 键盘只能由「有真实输入焦点的前台宿主 + SpringBoard 自己的 scene」发起；
//     connectedScenes 无序，必须先取 keyWindow.windowScene，否则会选中
//     SBSystemAperture* 这种没有显示层的辅助 scene，窗口 isKeyWindow=1 但键盘永不出（8/8 失败）
//   * 窗口必须 windowLevel = Normal+1 且 makeKeyAndVisible；2pt 高会被判定不可见

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <UIKit/UIKit.h>
#import <sys/sysctl.h>
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

#import <string.h>
#import <fcntl.h>
#import <unistd.h>
#import <time.h>
#import <stdio.h>
#import <stdlib.h>   // calloc / free
#import <dlfcn.h>    // dlopen/dlsym：v2.0.18 原生前台激活用

#define WCVK_BUILD_TAG "v2.0.21-roothide"

// 键盘扩展进程的精确特征：可执行文件路径以 /wxkb_plugin.appex/wxkb_plugin 结尾
static NSString *const kKbdExtPathSuffix = @"/wxkb_plugin.appex/wxkb_plugin";

// ===== 日志（纯净版编译期整体剥离：WCVK_NO_LOG=1）=====
#ifndef WCVK_NO_LOG
#define WCVK_NO_LOG 0
#endif

#if WCVK_NO_LOG
#define SBLog(...) do {} while (0)
#else
static void SBLog(NSString *fmt, ...) {
    static NSString *path = @"/var/mobile/wetypekeepalive.log";
    va_list ap; va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSDictionary *attr = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
    if ([attr[NSFileSize] unsignedLongLongValue] > 2 * 1024 * 1024) {
        [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
    }
    NSString *line = [NSString stringWithFormat:@"[%@] %@\n", [NSDate date], msg];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!fh) {
        [line writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
        fh = [NSFileHandle fileHandleForWritingAtPath:path];
        if (!fh) return;
    }
    @try {
        [fh seekToEndOfFile];
        [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [fh closeFile];
    } @catch (NSException *e) {}
}
#endif

// 加载自证（纯净版不写）
static void WCVKMarker(const char *tag) {
#if !WCVK_NO_LOG
    char buf[256];
    int n = snprintf(buf, sizeof(buf), "t=%ld pid=%d build=%s tag=%s\n",
                     (long)time(NULL), getpid(), WCVK_BUILD_TAG, tag);
    if (n <= 0) return;
    static const char *paths[] = {
        "/var/mobile/wcvk_sb_marker.txt",
        "/var/mobile/Documents/wcvk_sb_marker.txt",
        NULL
    };
    for (int i = 0; paths[i]; i++) {
        int fd = open(paths[i], O_WRONLY | O_CREAT | O_APPEND, 0644);
        if (fd >= 0) {
            ssize_t wr = write(fd, buf, (size_t)n);
            (void)wr;
            close(fd);
        }
    }
#else
    (void)tag;
#endif
}

// ===== Darwin 通知 =====
static void WCVKPostDarwin(const char *name) {
    CFStringRef n = CFStringCreateWithCString(NULL, name, kCFStringEncodingUTF8);
    if (!n) return;
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         n, NULL, NULL, true);
    CFRelease(n);
}

// ===== 进程检测（精确到可执行文件路径，不靠 16 字符截断的进程名）=====
static BOOL KbdExtRunning(void) {
    int n = proc_listallpids(NULL, 0);
    if (n <= 0) return NO;
    pid_t *pids = (pid_t *)calloc((size_t)n + 64, sizeof(pid_t));
    if (!pids) return NO;
    int cnt = proc_listallpids(pids, (int)((size_t)(n + 64) * sizeof(pid_t)));
    BOOL found = NO;
    for (int i = 0; i < cnt; i++) {
        char path[PROC_PIDPATHINFO_MAXSIZE] = {0};
        if (proc_pidpath(pids[i], path, sizeof(path)) <= 0) continue;
        NSString *p = [NSString stringWithUTF8String:path];
        if ([p hasSuffix:kKbdExtPathSuffix]) { found = YES; break; }
    }
    free(pids);
    return found;
}
#define KbdProcRunning() KbdExtRunning()

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
static BOOL         gUpPosted = NO;   // v2.0.1：本次预热是否已发过 kbd.up（去抖）
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
        // v2.0.1：DidShow 在一次预热里会被系统连发很多次（实测 12 次/秒级），
        // 每次都要 daemon 遍历进程表重挂 —— 纯浪费。这里按「新 pid + 3s 去抖」只发一次。
        static time_t sLastUpAt = 0;
        time_t nowT = time(NULL);
        if (!gUpPosted || nowT - sLastUpAt >= 3) {
            gUpPosted  = YES;
            sLastUpAt  = nowT;
            WCVKPostDarwin("com.wcvoicekeep.kbd.up");
        } else {
            SBLog(@"[KBDWARM] kbd.up 去抖：本次预热已发过，忽略重复 DidShow");
        }
        // v2.0.4（老板要求）：**键盘一弹出来就立刻收**。
        // 扩展进程这时已经在内存里了，收键盘不会把它带走（它靠 exit timeout=3 才回收），
        // 所以没必要让键盘在屏幕上多待。放到下一轮 runloop 再收，避开键盘正在 setup 的瞬间。
        if (gWarmBusy && gWarmField) {
            dispatch_async(dispatch_get_main_queue(), ^{
                KbdWarmupFinish(@"DidShow-immediate");
                SBLog(@"[KBDWARM] DidShow 即刻收键盘 -> wxkb_plugin_running=%d", KbdProcRunning());
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
    // v2.0.2：收尾顺序重排。以前是 resign 之后**立刻**把窗口 hidden + 销毁 + 恢复 keyWindow，
    // 键盘收起动画被打断，键盘就留在屏幕上了（老板实测"注销后键盘一直在桌面"）。
    // 现在：resign 生效 -> 让动画先走完 -> 再销毁窗口、恢复 key window。幂等，可重复调用。
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
        gUpPosted = NO;              // v2.0.1：新一轮预热，允许发一次 kbd.up

        if (KbdProcRunning()) {
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

        // T+0.6s：确认键盘是否真弹（只记日志，不再用它决定要不要收）
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            SBLog(@"[KBDWARM] T+0.6s keyboardShown=%d wxkb_plugin_running=%d",
                  gDidShow, KbdProcRunning());
            // 只补一次：真没弹出来再 become 一次。绝不再做 3 连重试 ——
            // 那会让键盘在桌面上反复闪、且迟迟不收（老板实测"注销后键盘一直留在桌面"）。
            if (!gDidShow && gWarmField && !gWarmField.isFirstResponder) {
                @try { [gWarmField becomeFirstResponder]; } @catch (NSException *e) {}
            }
        });

        // T+1.2s：**兜底**收键盘（正常路径在 DidShow 那一刻就收掉了）。
        // 以前这里写的是 `if (!gDidShow) return;` —— 而 SpringBoard 里 UIKeyboardDidShow
        // 经常收不到，结果"键盘弹出来了却永远不收"，一直挂在桌面上。
        // 所以无论有没有收到 DidShow，到点都无条件收一遍。
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            KbdWarmupFinish(@"T+1.2s-fallback");
            SBLog(@"[KBDWARM] T+1.2s 兜底收键盘完成 wxkb_plugin_running=%d", KbdProcRunning());
        });

        // T+1.1s 的"补收"已并入上面的 T+1.2s 兜底（KbdWarmupFinish 本身幂等）

        // T+3s：最终判定 + 释放 busy（无论成败都要释放，否则下次预热会被 busy 挡住）
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            BOOL running = KbdProcRunning();
            SBLog(@"[KBDWARM] T+3s FINAL keyboardShown=%d wxkb_plugin_running=%d (%@)",
                  gDidShow, running, running ? @"成功" : @"失败");
            KbdWarmupFinish(@"T+3s-final");
            gWarmBusy = NO;
        });
    });
}

// ===== Darwin 通知入口（daemon -> SpringBoard）=====
static void WCVKNotifyCallback(CFNotificationCenterRef center, void *observer,
                               CFStringRef name, const void *object,
                               CFDictionaryRef userInfo) {
    NSString *n = (__bridge NSString *)name;
    if ([n isEqualToString:@"com.wcvoicekeep.kbd.warmup"]) {
        KbdWarmupRun(@"darwin-notify");
    }
}

// 微信侧 wcprewarmfix.dylib 的 ctor 探针回调（见 WCVKInit 里的注册说明）。
// 只写一行日志，不做任何其它动作，零副作用。
static void WCVKPrewarmNotifyCallback(CFNotificationCenterRef center, void *observer,
                                      CFStringRef name, const void *object,
                                      CFDictionaryRef userInfo) {
    SBLog(@"[PREWARM] ctor reached —— 微信侧 wcprewarmfix.dylib 已注入并执行");
    WCVKMarker("prewarm-ctor");
}

// ===== reveal 通道（v2.0.19 起降级为「只记录」）=====
// v2.0.18 曾在这里用 SBSLaunchApplicationWithIdentifier(bid, false) 做前台激活，
// 想让微信走「用户点图标」的原生路径自愈。实测判死（原因见 WCVKRevealRun 里注释）：
// 该私有 API 在 SpringBoard 主线程同步阻塞 11 秒、rc=11 未被受理、且导致全系统卡死。
// 现在保留通道本身（方便将来换成非阻塞方案时复用），但绝不调用任何启动 API。
static CFAbsoluteTime gWCVKLastReveal = 0;

static void WCVKRevealRun(const char *bid) {
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - gWCVKLastReveal < 2.0) {
        SBLog(@"[REVEAL] 去重：2s 内已收到过，忽略");
        return;
    }
    gWCVKLastReveal = now;
    if (!bid || !bid[0]) bid = "com.tencent.xin";

    // ⛔⛔ v2.0.19：**这里绝对不能调 SBSLaunchApplicationWithIdentifier**。
    // 2026-11-07 02:58 老板实测：直接进微信后整个系统卡死，切后台都切不了，很久才闪退重启。
    // 本机日志铁证（/var/mobile/wetypekeepalive.log）：
    //   [18:56:46] [REVEAL] 收到原生激活请求
    //   [18:56:56] [REVEAL] 原生前台激活 com.tencent.xin rc=11（0=已受理）
    //   —— 中间整整 11 秒，这个私有 API 在 SpringBoard 主线程**同步阻塞**，
    //      SpringBoard 主线程一卡，全系统就跟着卡（Home/切后台全部无响应）；
    //      而且 rc=11 说明这次启动根本没被受理，等于白卡。
    //      微信侧同一时刻的复查也被从 1.5s 拖到 10s（02:57:43.364 → 02:57:53.675），
    //      两边互锁：SB 等微信响应，微信主线程在等 SB。
    // 现在这条通道只留「收到即记录」，不做任何系统调用、不阻塞任何线程。
    // 微信侧 v2.0.19 起也不再发这个 notify（见 WCPrewarmFix.m 的 kWPFSafeMode）。
    SBLog(@"[REVEAL] 收到请求 %s —— v2.0.19 只记录，不调用任何启动 API（避免阻塞 SpringBoard）", bid);
}

// userInfo 里带 bundleId 就用它，不带默认微信
static void WCVKRevealNotifyCallback(CFNotificationCenterRef center, void *observer,
                                     CFStringRef name, const void *object,
                                     CFDictionaryRef userInfo) {
    // 微信侧只发裸 notify（不带 payload），目标固定是微信
    SBLog(@"[REVEAL] 收到原生激活请求");
    WCVKRevealRun("com.tencent.xin");
}

__attribute__((constructor))
static void WCVKInit(void) {
    WCVKMarker("ctor");
    SBLog(@"[KBDWARM] dylib loaded pid=%d build=%s", getpid(), WCVK_BUILD_TAG);
    // 键盘显示/隐藏观察先装好（daemon 侧靠 kbd.up 重新挂监视）
    dispatch_async(dispatch_get_main_queue(), ^{ KbdInstallObservers(); });

    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                    NULL, WCVKNotifyCallback,
                                    CFSTR("com.wcvoicekeep.kbd.warmup"),
                                    NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
    SBLog(@"[KBDWARM] darwin notify com.wcvoicekeep.kbd.warmup registered");

    // ★ 微信侧 wcprewarmfix.dylib 的「我被执行了」探针（v2.0.14）。
    //   微信是沙盒 App，它的日志写不写得出来受容器/权限影响，这条走 darwin notify 完全
    //   不碰文件系统：只要 wcprewarmfix 的 %ctor 跑到，这里就一定落一行 [PREWARM]。
    //   有这行 = dylib 确实被注入并执行；没这行 = 注入链路本身没走通。
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                    NULL, WCVKPrewarmNotifyCallback,
                                    CFSTR("com.wcvoicekeep.prewarm.ctor"),
                                    NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
    SBLog(@"[KBDWARM] prewarm probe registered (com.wcvoicekeep.prewarm.ctor)");

    // ★ v2.0.18：原生「黑屏转显示」通道。
    //   微信侧检测到黑屏就发 com.wcvoicekeep.prewarm.reveal，这里用 SpringBoard 原生
    //   前台激活接口把微信重新激活一次 —— 等价于用户点图标，让微信自己把界面显示出来，
    //   全程不碰 window / windowScene，微信内部状态保持一致。
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                    NULL, WCVKRevealNotifyCallback,
                                    CFSTR("com.wcvoicekeep.prewarm.reveal"),
                                    NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
    SBLog(@"[KBDWARM] reveal channel registered (com.wcvoicekeep.prewarm.reveal)");
}
