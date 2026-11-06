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

#define WCVK_BUILD_TAG "v2.0.0-roothide"

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
static id           gShowObs = nil;
static id           gHideObs = nil;

static void KbdWarmupFinish(NSString *tag);

static void KbdRetryTick(int attempt) {
    if (gDidShow || !gWarmField) return;
    if (attempt > 3) {
        SBLog(@"[KBDWARM] retry 用尽 3 次，键盘仍未弹出（本次拉起失败）");
        return;
    }
    @try { [gWarmField resignFirstResponder]; } @catch (NSException *e) {}
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (!gWarmField || gDidShow) return;
        BOOL b = [gWarmField becomeFirstResponder];
        SBLog(@"[KBDWARM] retry#%d becomeFirstResponder=%d", attempt, b);
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.1 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        SBLog(@"[KBDWARM] retry#%d keyboardShown=%d wxkb_plugin_running=%d",
              attempt, gDidShow, KbdProcRunning());
        if (!gDidShow) KbdRetryTick(attempt + 1);
    });
}

static void KbdInstallObservers(void) {
    if (gShowObs) return;
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    gShowObs = [nc addObserverForName:UIKeyboardDidShowNotification object:nil
                                queue:[NSOperationQueue mainQueue]
                           usingBlock:^(NSNotification *n) {
        gDidShow = YES;
        SBLog(@"[KBDWARM] *** UIKeyboardDidShow 收到 = 键盘弹出来了，扩展应已被系统 spawn");
        // 告诉 daemon：扩展已经起来，去新 pid 上重新挂退出事件（事件驱动，零轮询）
        WCVKPostDarwin("com.wcvoicekeep.kbd.up");
    }];
    gHideObs = [nc addObserverForName:UIKeyboardDidHideNotification object:nil
                                queue:[NSOperationQueue mainQueue]
                           usingBlock:^(NSNotification *n) {
        gDidShow = NO;
        SBLog(@"[KBDWARM] *** UIKeyboardDidHide 收到");
    }];
}

static void KbdWarmupFinish(NSString *tag) {
    if (gWarmField) {
        BOOL ok = [gWarmField resignFirstResponder];
        SBLog(@"[KBDWARM] %@ resignFirstResponder=%d", tag, ok);
        [gWarmField removeFromSuperview];
        gWarmField = nil;
    }
    if (gWarmWindow) {
        gWarmWindow.hidden = YES;
        gWarmWindow.rootViewController = nil;
        gWarmWindow = nil;
    }
    if (gPrevKeyWindow) {
        [gPrevKeyWindow makeKeyWindow];   // 返回 void
        gPrevKeyWindow = nil;
    }
}

static void KbdWarmupRun(NSString *reason) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (gWarmBusy) { SBLog(@"[KBDWARM] skip, busy (%@)", reason); return; }
        gWarmBusy = YES;

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

        // T+0.6s：确认键盘是否真弹
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            SBLog(@"[KBDWARM] T+0.6s keyboardShown=%d wxkb_plugin_running=%d",
                  gDidShow, KbdProcRunning());
            if (!gDidShow) KbdRetryTick(1);
        });

        // T+1.0s：弹出来了就收键盘（扩展已被系统拉起，收键盘不影响它继续活着）
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (!gDidShow) return;
            KbdWarmupFinish(@"T+1.0s");
            SBLog(@"[KBDWARM] T+1.0s 收键盘完成 wxkb_plugin_running=%d", KbdProcRunning());
            gWarmBusy = NO;
        });

        // T+5s：最终判定
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            BOOL running = KbdProcRunning();
            SBLog(@"[KBDWARM] T+5s FINAL keyboardShown=%d wxkb_plugin_running=%d (%@)",
                  gDidShow, running, running ? @"成功" : @"失败");
            if (!running) KbdWarmupFinish(@"T+5s-fallback");
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
}
