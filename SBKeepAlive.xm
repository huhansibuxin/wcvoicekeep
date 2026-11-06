// SBKeepAlive — SpringBoard 侧注入：让微信输入法(com.tencent.wetype)保持前台态
//
// v1.9.27（修 v1.9.26 篡改式失败，根因来自 SSH 日志铁证）：
//   v1.9.26 篡改式（清 deactivationReasons 再 %orig）实测双失败：
//     1) 保活退化：PiP 打断后恢复慢（15:11:00 lost -> 15:11:56 才 built，56s）
//     2) 锁屏还是不行：FBScene 日志显示 wetype 的 deactivationReasons 恒 0x20，
//        被清 0 后系统认为 wetype 在播"活跃内容" -> idle timer 暂停 -> 不锁屏
//
//   v1.9.23 对照（完全拦截 + 无全局 hook）= 锁屏正常 -> 锁屏不依赖单 App scene，
//   只拦 wetype 的 deactivation 不影响锁屏。所以：
//
//   v1.9.27 组合：
//   1) FBScene 完全拦截（回 v1.9.24/25 保活主路径）：wetype 非过渡更新直接 return
//      不 %orig -> scene 永 active -> 保活完整（PiP 打断秒级恢复）
//   2) setDeactivationReasons 从"全局拦"改"标记拦"：FBScene 拦截时把 wetype 的
//      settings 打 associated object 标记；hook 里只拦带标记的（wetype），
//      微信/其他 App 完全放行 -> 锁屏恢复（不再猜锁屏 bit，v1.9.23 实证）
//   3) 文件日志 /var/mobile/wetypekeepalive.log（3M 上限）

#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>   // objc_setAssociatedObject
#import <UIKit/UIKit.h>
#import <sys/sysctl.h>
#import <string.h>
#import <fcntl.h>
#import <unistd.h>
#import <time.h>
#import <stdio.h>

// theos SDK 无 SpringBoard 私有头，声明存根类即可（运行时真实类名匹配）
@interface FBScene : NSObject
@end
@interface FBProcess : NSObject
@end

static NSString *const kWetypeBundleID = @"com.tencent.wetype";

// ===== 文件日志（SB 进程 mobile 用户写 /var/mobile/，3M 上限）=====
static void SBLog(NSString *fmt, ...) {
    static NSString *path = @"/var/mobile/wetypekeepalive.log";
    va_list ap; va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSDictionary *attr = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
    if ([attr[NSFileSize] unsignedLongLongValue] > 3 * 1024 * 1024) {
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

// ===== 加载自证（v1.9.35 三通道）=====
// v1.9.34 教训（老板 CocoaTop 截图铁证）：wetypekeepalive.dylib 确实已被
// ElleKit 加载进 SpringBoard（地址 1019EC000 可见于映射表），但
//   /var/mobile/wcvk_sb_marker.txt
//   /var/mobile/Documents/wcvk_sb_marker.txt
//   /var/mobile/Library/Logs/wcvk_sb_marker.txt
//   /var/mobile/wetypekeepalive.log
// 四个文件一个都没生成 —— 说明不是"dylib 没注入"，而是 SpringBoard 的沙盒
// 拒绝它在 /var/mobile 下创建文件（root LaunchDaemon 能写，SB 不能）。
// 故改为三通道并行取证，任一通路成功即可判定 constructor 是否执行：
//   通道 1  open/write  —— 原始文件（保留，若沙盒放行最直观）
//   通道 2  CFPreferences —— SB 必然有权写自己的 prefs domain
//   通道 3  Darwin 通知 —— 由 root 的 wcvoicekeep daemon 收到后落盘（必定成功）
#define WCVK_BUILD_TAG "v1.9.40-roothide"

// 通道 3：Darwin 通知（名字区分阶段，daemon 侧监听后写自己的日志）
static void WCVKPostNotify(const char *name) {
    CFStringRef n = CFStringCreateWithCString(NULL, name, kCFStringEncodingUTF8);
    if (!n) return;
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         n, NULL, NULL, true);
    CFRelease(n);
}

// 通道 2：CFPreferences（AnyUser + CurrentUser 双写，覆盖 SB 以 root/mobile 跑的情况）
static void WCVKPrefsMark(const char *tag) {
    CFStringRef val = CFStringCreateWithFormat(NULL, NULL,
                        CFSTR("%s pid=%d ts=%ld build=%s"),
                        tag, getpid(), (long)time(NULL), WCVK_BUILD_TAG);
    if (!val) return;
    const void *users[2] = { kCFPreferencesAnyUser, kCFPreferencesCurrentUser };
    for (int i = 0; i < 2; i++) {
        CFPreferencesSetValue(CFSTR("lastLoad"), val, CFSTR("com.wcvoicekeep.sb"),
                              (CFStringRef)users[i], kCFPreferencesCurrentHost);
        CFPreferencesAppSynchronize(CFSTR("com.wcvoicekeep.sb"));
    }
    CFRelease(val);
}

static void WCVKMarkerRaw(const char *tag) {
    static const char *paths[] = {
        "/var/mobile/wcvk_sb_marker.txt",
        "/var/mobile/Documents/wcvk_sb_marker.txt",
        "/var/mobile/Library/Logs/wcvk_sb_marker.txt",
        "/var/mobile/Library/Caches/wcvk_sb_marker.txt",
        "/var/mobile/Library/Preferences/wcvk_sb_marker.txt",
        NULL
    };
    char buf[320];
    int n = snprintf(buf, sizeof(buf), "t=%ld pid=%d build=%s tag=%s\n",
                     (long)time(NULL), getpid(), WCVK_BUILD_TAG, tag);
    if (n <= 0) return;
    // 通道 1：原始文件
    for (int i = 0; paths[i]; i++) {
        int fd = open(paths[i], O_WRONLY | O_CREAT | O_APPEND, 0644);
        if (fd >= 0) {
            ssize_t wr = write(fd, buf, (size_t)n);
            (void)wr;
            close(fd);
        }
    }
    // 通道 2：prefs
    WCVKPrefsMark(tag);
    // 通道 3：通知（阶段用不同名字，便于 daemon 区分）
    if (strcmp(tag, "ctor-enter") == 0) {
        WCVKPostNotify("com.wcvoicekeep.sb.enter");
    } else if (strcmp(tag, "ctor-bundleid-ok") == 0) {
        WCVKPostNotify("com.wcvoicekeep.sb.ready");
    }
}

// wetype 的 settings 标记（FBScene 拦截时打上，setDeactivationReasons 据此只拦 wetype）
static char kIsWetypeSettingsKey;

%hook FBScene

// wetype 的非过渡更新（挂起/去激活动作）：完全拦截不 %orig（scene 永 active），
// 并标记 settings 供 setDeactivationReasons 精准判断。其他 App / 过渡更新放行。
- (void)updateSettings:(id)arg1 withTransitionContext:(id)arg2 completion:(id)arg3 {
    id process = ((id (*)(id, SEL))objc_msgSend)(self, NSSelectorFromString(@"clientProcess"));
    NSString *bid = @"?";
    if (process) {
        bid = ((NSString *(*)(id, SEL))objc_msgSend)(process, NSSelectorFromString(@"bundleIdentifier"));
    }
    if ([bid isEqualToString:kWetypeBundleID] && arg2 == nil) {
        objc_setAssociatedObject(arg1, &kIsWetypeSettingsKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        SBLog(@"FBScene wetype non-transition update BLOCKED (keep active)");
        return; // 完全拦截：不 %orig，scene 保持 active
    }
    %orig;
}

%end

// 只拦 wetype 的 deactivationReasons（带标记的 settings）——微信/其他 App 完全放行，
// 锁屏恢复正常（v1.9.23 实证：只拦 wetype 的 deactivation 不影响系统锁屏）。
%hook UIMutableApplicationSceneSettings

- (void)setDeactivationReasons:(unsigned long long)arg1 {
    NSNumber *isWetype = objc_getAssociatedObject(self, &kIsWetypeSettingsKey);
    if ([isWetype boolValue] && arg1 != 0) {
        SBLog(@"setDeactivationReasons 0x%llx BLOCKED (wetype settings only)", arg1);
        return;
    }
    %orig;
}

%end

// ============================================================================
// 键盘扩展预热实验（v1.9.33 诊断构建）
//
// 背景（SSH 实测结论）：
//   微信输入法键盘进程是 appex 扩展 com.tencent.wetype.keyboard
//   (extension point = com.apple.keyboard-service)，由 launchd 托管，
//   type = Extension，spawn reason = launch job demand。
//   - 外部不可拉起：launchctl kickstart 在 user/501、user/foreground、system
//     三个域全部返回 102 "Operation not supported on socket"。
//   - 被 jetsam 杀掉后不会自恢复（Killed:9，PID 列为 "-"），
//     要等下一次真实键盘请求才冷启动。
//
// 本实验验证 B 路线：在 SpringBoard（前台进程）里制造一次真实键盘请求，
//   看能否让 launchd 把 wxkb_plugin 拉起来，并观察 resign 之后进程是否留存。
//   留存是关键：launchd 对该扩展 exit timeout = 3s，没有活跃连接就会退。
//
// 触发方式：
//   1) 注入后 25s 自动跑一次（诊断版，便于装完立刻验证）
//   2) 手动反复触发：notifyutil -p com.wcvoicekeep.kbd.warmup
// ============================================================================

static const char *kWXKBPluginComm = "wxkb_plugin";

// 用 sysctl 精确匹配 p_comm 判断扩展进程是否在跑（wxkb != wxkb_plugin）
static BOOL KbdProcRunning(void) {
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0};
    size_t sz = 0;
    if (sysctl(mib, 4, NULL, &sz, NULL, 0) != 0 || sz == 0) return NO;
    struct kinfo_proc *procs = (struct kinfo_proc *)malloc(sz);
    if (!procs) return NO;
    BOOL found = NO;
    if (sysctl(mib, 4, procs, &sz, NULL, 0) == 0) {
        int n = (int)(sz / sizeof(struct kinfo_proc));
        for (int i = 0; i < n; i++) {
            if (strcmp(procs[i].kp_proc.p_comm, kWXKBPluginComm) == 0) { found = YES; break; }
        }
    }
    free(procs);
    return found;
}

// 取 SpringBoard 真正"有显示"的 windowScene（iOS 16 建 window 需要 scene）
//
// v1.9.40 关键修正（前 8 次全失败的疑似根因）：
//   SpringBoard 有 3 个 UIWindowScene：SBWindowScene（真正承载桌面/App 的）、
//   SBSystemApertureWindowScene、SBSystemApertureCurtainWindowScene。
//   后两个是"灵动岛/刘海"辅助 scene，也是 UIWindowScene 子类。旧代码只看
//   activationState==ForegroundActive 就返回第一个命中的 —— connectedScenes 是
//   无序集合，很可能一开始就选中 Aperture/Curtain scene。
//   把窗口建在那种 scene 上：窗口 isKeyWindow 可以为 1、textfield 也能成为
//   firstResponder（日志正是这样：isKeyWindow=1 / isFirstResponder=1），
//   但那个 scene 根本没有正常显示层，系统永远不会为它发起键盘请求
//   -> keyboardShown 恒 0。与实测日志完全吻合。
// 新顺序：① key window 所属 scene（一定是有显示的那个）
//        ② 窗口里含 HomeScreen/Switcher/CoverSheet/Main 字样的 scene
//        ③ 兜底：任意 active UIWindowScene，但排除 Aperture/Curtain
static NSString *KbdSceneTag(UIWindowScene *s) {
    if (!s) return @"nil";
    NSMutableString *m = [NSMutableString stringWithFormat:@"%s(%lu windows:",
                          NSStringFromClass([s class]).UTF8String,
                          (unsigned long)s.windows.count];
    for (UIWindow *w in s.windows) {
        [m appendFormat:@" %s", NSStringFromClass([w class]).UTF8String];
    }
    [m appendString:@")"];
    return m;
}

static UIWindowScene *KbdWarmScene(void) {
    UIApplication *app = [UIApplication sharedApplication];

    // ① SpringBoard 当前 key window 所属 scene
    UIWindow *kw = app.keyWindow;
    if (kw && kw.windowScene) return kw.windowScene;

    // ② 含真实 UI 窗口的 scene
    for (UIScene *s in app.connectedScenes) {
        if (![s isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *w in ((UIWindowScene *)s).windows) {
            NSString *cn = NSStringFromClass([w class]);
            if ([cn containsString:@"HomeScreen"] || [cn containsString:@"Switcher"] ||
                [cn containsString:@"CoverSheet"] || [cn containsString:@"Main"]) {
                return (UIWindowScene *)s;
            }
        }
    }

    // ③ 兜底：排除 Aperture / Curtain
    for (UIScene *s in app.connectedScenes) {
        if (![s isKindOfClass:[UIWindowScene class]]) continue;
        if (s.activationState != UISceneActivationStateForegroundActive) continue;
        NSString *cn = NSStringFromClass([s class]);
        if ([cn containsString:@"Aperture"] || [cn containsString:@"Curtain"]) continue;
        return (UIWindowScene *)s;
    }
    return nil;
}

static UIWindow *gKbdWarmWindow = nil;
static UITextField *gKbdWarmField = nil;
static UIWindow *gKbdPrevKeyWindow = nil;
static BOOL gKbdWarmBusy = NO;
static UIAlertController *gKbdAlert = nil;

// ===== v1.9.37：键盘是否真的弹出来了（实测判据，不再靠猜）=====
// v1.9.36 的日志写死了"(键盘已弹)"，但那是字符串不是检测结果，
// 结果就分不清"键盘弹了但扩展没起"和"键盘压根没弹"。这里用系统通知做真判据。
static BOOL gKbdDidShow = NO;
static id   gKbdShowObs = nil;
static id   gKbdHideObs = nil;

static void KbdStartKbWatch(void) {
    if (gKbdShowObs) return;
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    gKbdShowObs = [nc addObserverForName:UIKeyboardDidShowNotification
                                  object:nil queue:[NSOperationQueue mainQueue]
                              usingBlock:^(NSNotification *n) {
        gKbdDidShow = YES;
        SBLog(@"[KBDWARM] *** UIKeyboardDidShow 收到 = 键盘真的弹出来了");
    }];
    gKbdHideObs = [nc addObserverForName:UIKeyboardDidHideNotification
                                  object:nil queue:[NSOperationQueue mainQueue]
                              usingBlock:^(NSNotification *n) {
        SBLog(@"[KBDWARM] *** UIKeyboardDidHide 收到");
    }];
    SBLog(@"[KBDWARM] keyboard show/hide observers installed");
}

// ===== v1.9.39：环境诊断 + 键盘重试 =====
// 设备实测（2026-11-06）：同一份代码 19:30:04 那次 keyboardShown=1 且成功拉起
// wxkb_plugin，19:35:04 那次 keyboardShown=0 完全弹不出来。说明"程序化弹键盘"
// 在 SpringBoard 里本身就不稳定，必须重试 + 记录当时环境才能定位规律。
static void KbdLogEnv(NSString *tag) {
    UIApplication *app = [UIApplication sharedApplication];
    NSArray *scenes = app.connectedScenes.allObjects;
    NSMutableString *sb = [NSMutableString string];
    for (UIScene *s in scenes) {
        [sb appendFormat:@"[%s act=%ld]", NSStringFromClass([s class]).UTF8String,
                        (long)s.activationState];
    }
    UIWindow *kw = app.keyWindow;
    SBLog(@"[KBDWARM][ENV] %@ appState=%ld keyWindow=%s windows=%lu scenes=%lu %s",
          tag, (long)app.applicationState,
          kw ? NSStringFromClass([kw class]).UTF8String : "nil",
          (unsigned long)app.windows.count, (unsigned long)scenes.count,
          sb.UTF8String ?: "");
}

// 键盘第一次常常不弹：resign -> 再 becomeFirstResponder，最多 3 次
static void KbdWarmRetryTick(int attempt) {
    if (gKbdDidShow || !gKbdWarmField) return;
    if (attempt > 3) {
        SBLog(@"[KBDWARM] retry 用尽 3 次，键盘仍未弹出");
        return;
    }
    @try {
        [gKbdWarmField resignFirstResponder];
    } @catch (NSException *e) {}
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (!gKbdWarmField || gKbdDidShow) return;
        BOOL b = [gKbdWarmField becomeFirstResponder];
        KbdLogEnv([NSString stringWithFormat:@"retry#%d", attempt]);
        SBLog(@"[KBDWARM] retry#%d becomeFirstResponder=%d", attempt, b);
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.1 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        SBLog(@"[KBDWARM] retry#%d keyboardShown=%d wxkb_plugin_running=%d",
              attempt, gKbdDidShow, KbdProcRunning());
        if (!gKbdDidShow) KbdWarmRetryTick(attempt + 1);
    });
}

static void KbdWarmupFinish(NSString *tag) {
    if (gKbdWarmField) {
        BOOL ok = [gKbdWarmField resignFirstResponder];
        SBLog(@"[KBDWARM] %@ resignFirstResponder=%d", tag, ok);
        [gKbdWarmField removeFromSuperview];
        gKbdWarmField = nil;
    }
    if (gKbdAlert) {
        [gKbdAlert dismissViewControllerAnimated:NO completion:nil];
        gKbdAlert = nil;
    }
    if (gKbdWarmWindow) {
        gKbdWarmWindow.hidden = YES;
        gKbdWarmWindow.rootViewController = nil;
        gKbdWarmWindow = nil;
    }
    // 恢复原本的 key window，避免 SpringBoard 触摸/手势因 key 转移而异常
    if (gKbdPrevKeyWindow) {
        [gKbdPrevKeyWindow makeKeyWindow];   // 返回 void，不能取返回值
        SBLog(@"[KBDWARM] %@ restored prev keyWindow", tag);
        gKbdPrevKeyWindow = nil;
    }
}

// ===== v1.9.37 备选通道：UIAlertController + UITextField =====
// 说明：SpringBoard 里自建 window 弹键盘未必被系统接受（2pt 高的窗口可能被视为
// 不可见而不发起键盘请求）。alert 是系统标准 UI，其中的 textField 成为
// firstResponder 后键盘必然要显示，用它来判定"SpringBoard 这个宿主能不能拉起
// 微信键盘扩展"，两个通道的结论分开记录。
static void KbdWarmupRunAlert(void) {
    UIWindowScene *scene = KbdWarmScene();
    if (!scene) { SBLog(@"[KBDWARM][ALERT] ABORT no scene"); gKbdWarmBusy = NO; return; }
    UIWindow *host = nil;
    for (UIWindow *w in scene.windows) {
        if (w.isKeyWindow) { host = w; break; }
    }
    if (!host) host = scene.windows.firstObject;
    if (!host) { SBLog(@"[KBDWARM][ALERT] ABORT no host window"); gKbdWarmBusy = NO; return; }

    gKbdDidShow = NO;
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"wcvk"
                                                               message:@"warm"
                                                        preferredStyle:UIAlertControllerStyleAlert];
    __block UITextField *tf = nil;
    [ac addTextFieldWithConfigurationHandler:^(UITextField *t) { tf = t; }];
    gKbdAlert = ac;
    [host.rootViewController presentViewController:ac animated:NO completion:^{
        BOOL became = [tf becomeFirstResponder];
        SBLog(@"[KBDWARM][ALERT] becomeFirstResponder=%d isFirstResponder=%d", became, tf.isFirstResponder);
    }];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        SBLog(@"[KBDWARM][ALERT] T+1.5s keyboardShown=%d wxkb_plugin_running=%d",
              gKbdDidShow, KbdProcRunning());
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        SBLog(@"[KBDWARM][ALERT] T+4s keyboardShown=%d wxkb_plugin_running=%d",
              gKbdDidShow, KbdProcRunning());
        KbdWarmupFinish(@"ALERT-end");
        gKbdWarmBusy = NO;
        SBLog(@"[KBDWARM][ALERT] ===== end =====");
    });
}

// 预热：建最小 window + textfield -> becomeFirstResponder 触发键盘加载
static void KbdWarmupRun(NSString *reason) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (gKbdWarmBusy) { SBLog(@"[KBDWARM] skip, busy (%@)", reason); return; }
        gKbdWarmBusy = YES;

        BOOL before = KbdProcRunning();
        SBLog(@"[KBDWARM] ===== start (%@) wxkb_plugin_running_before=%d =====", reason, before);

        // v1.9.36：扩展已经在跑就绝不打扰（不弹键盘、不建窗口）。
        // 老板明确：扩展平时能一直活着，只有内存压力大才被杀；
        // 本功能唯一职责 = 发现它不在时把它拉回来。
        if (before) {
            SBLog(@"[KBDWARM] skip: wxkb_plugin already running, nothing to do");
            gKbdWarmBusy = NO;
            return;
        }

        UIWindowScene *scene = KbdWarmScene();
        if (!scene) {
            SBLog(@"[KBDWARM] ABORT: no foregroundActive UIWindowScene");
            gKbdWarmBusy = NO;
            return;
        }
        SBLog(@"[KBDWARM] host scene = %@", KbdSceneTag(scene));

        // v1.9.36 关键修正（v1.9.33/34 失败的根因）：
        // 上一版为了"不干扰"设了 windowLevel = Normal-1 且不 makeKeyAndVisible，
        // 结果 UITextField 虽拿到 firstResponder，但键盘根本没被真正请求
        // （日志实证：becomeFirstResponder=1 而 wxkb_plugin_running 全程 0）。
        // v1.9.37 再修：窗口 2pt 高很可能被系统当作不可见、依然不发起键盘请求，
        // 改成屏幕内正常尺寸窗口 + 文本框放在可见位置，并用 UIKeyboardDidShow
        // 通知做实测判据（不再用写死的"(键盘已弹)"字符串冒充结论）。
        gKbdDidShow = NO;
        UIWindow *w = [[UIWindow alloc] initWithWindowScene:scene];
        w.frame = CGRectMake(20, 100, 180, 44);      // 屏幕可见区域内的小窗口
        w.windowLevel = UIWindowLevelNormal + 1;
        w.backgroundColor = [UIColor clearColor];
        w.rootViewController = [[UIViewController alloc] init];
        w.rootViewController.view.backgroundColor = [UIColor clearColor];
        gKbdPrevKeyWindow = [[UIApplication sharedApplication] keyWindow];
        [w makeKeyAndVisible];                        // 必须：可见且 key，键盘才会真弹

        UITextField *tf = [[UITextField alloc] initWithFrame:CGRectMake(0, 0, 160, 40)];
        tf.autocorrectionType = UITextAutocorrectionTypeNo;
        tf.spellCheckingType = UITextSpellCheckingTypeNo;
        tf.textColor = [UIColor clearColor];          // 视觉上尽量不干扰
        tf.tintColor = [UIColor clearColor];
        tf.backgroundColor = [UIColor clearColor];
        tf.inputAssistantItem.leadingBarButtonGroups = @[];
        tf.inputAssistantItem.trailingBarButtonGroups = @[];
        [w.rootViewController.view addSubview:tf];
        BOOL became = [tf becomeFirstResponder];
        BOOL attached = tf.isFirstResponder;
        // v1.9.40：把"窗口是否真在显示层"也记下来。isKeyWindow=1 只说明在
        // 自己的 scene 里是 key；若 w.hidden=1 或 tf.window=nil，说明窗口根本
        // 没进显示的窗口层级，键盘当然不会被请求。
        SBLog(@"[KBDWARM] becomeFirstResponder=%d isFirstResponder=%d isKeyWindow=%d hidden=%d alpha=%.1f tf.window=%d tf.superview=%d",
              became, attached, (int)w.isKeyWindow, (int)w.hidden, w.alpha,
              tf.window != nil, tf.superview != nil);

        gKbdWarmWindow = w;
        gKbdWarmField = tf;
        KbdLogEnv(reason);

        // 600ms：够系统走完键盘显示流程，用通知判据确认键盘到底弹没弹
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            SBLog(@"[KBDWARM] T+0.6s keyboardShown=%d wxkb_plugin_running=%d",
                  gKbdDidShow, KbdProcRunning());
            if (!gKbdDidShow) KbdWarmRetryTick(1);   // v1.9.39：不弹就重试
        });

        // 收键盘：只有确实弹出来了才在 1.0s 收；没弹的交给重试链
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (!gKbdDidShow) return;               // 交给 retry / fallback
            KbdWarmupFinish(@"T+1.0s");
            SBLog(@"[KBDWARM] T+1.0s after resign keyboardShown=%d wxkb_plugin_running=%d",
                  gKbdDidShow, KbdProcRunning());
            gKbdWarmBusy = NO;   // 先放开，下面 fallback 需要
        });

        // 窗口法没弹键盘 -> 换 alert 通道再验一次（重试链走完才判失败）
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.6 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            BOOL running = KbdProcRunning();
            SBLog(@"[KBDWARM] T+4.6s keyboardShown=%d wxkb_plugin_running=%d",
                  gKbdDidShow, running);
            if (!gKbdDidShow && !running) {
                SBLog(@"[KBDWARM] window+retry 都未弹键盘 -> 切 alert 通道");
                KbdWarmupFinish(@"T+4.6s");
                if (!gKbdWarmBusy) { gKbdWarmBusy = YES; KbdWarmupRunAlert(); }
            }
        });

        // 最终判定
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(9.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            SBLog(@"[KBDWARM] T+9.5s FINAL keyboardShown=%d wxkb_plugin_running=%d",
                  gKbdDidShow, KbdProcRunning());
            gKbdWarmBusy = NO;
            SBLog(@"[KBDWARM] ===== end =====");
        });
    });
}

// ===== v1.9.40：UIKit 键盘私有 API 探测（只读，不改任何状态）=====
// 为什么探：程序化弹键盘 8/8 失败后，剩下唯一"真无头"的可能就是
// 直接命令 keyboard arbiter 预热/分配键盘（不需要任何 UI）。但 arbiter 的
// 入口签名是私有的、iOS 16 与老资料不一定一致，盲写必错。
// 所以先把 SpringBoard 进程里所有 Keyboard* 相关类的方法签名 dump 出来看。
// 触发：wcvoicekeep --kbd-api-probe （daemon 发 com.wcvoicekeep.kbd.probe）
static void KbdApiProbe(void) {
    const char *path = "/var/mobile/wcvk_kbdapi.log";
    FILE *fp = fopen(path, "w");
    if (!fp) return;
    setvbuf(fp, NULL, _IONBF, 0);          // 无缓冲：即使进程崩，已写内容也不丢

    fprintf(fp, "=== kbd api probe build=v1.9.40 pid=%d ===\n", getpid());

    static const char *keys[] = {
        "KeyboardArbiter", "KeyboardArbitration", "KeyboardScene", "KeyboardState",
        "KeyboardAutomatic", "KeyboardImpl", "KeyboardWindow", "KeyboardLayout",
        "KeyboardHost", "InputMode", "TextInput", "PKHost", "PKManager"
    };
    const int keyCount = (int)(sizeof(keys) / sizeof(keys[0]));

    unsigned int nClasses = 0;
    Class *classes = objc_copyClassList(&nClasses);
    fprintf(fp, "total classes = %u\n", nClasses);
    if (!classes) { fclose(fp); return; }

    int hit = 0;
    for (unsigned int i = 0; i < nClasses; i++) {
        Class c = classes[i];
        const char *cn = class_getName(c);
        if (!cn) continue;
        BOOL match = NO;
        for (int k = 0; k < keyCount; k++) {
            if (strstr(cn, keys[k])) { match = YES; break; }
        }
        if (!match) continue;
        hit++;

        Class sup = class_getSuperclass(c);
        fprintf(fp, "\n### %s : %s\n", cn, sup ? class_getName(sup) : "-");

        // 只 dump 本类自己实现的方法（不含继承），避免刷屏
        unsigned int mc = 0;
        Method *ims = class_copyMethodList(c, &mc);
        for (unsigned int j = 0; j < mc && j < 160; j++) {
            fprintf(fp, "  - %s  %s\n", sel_getName(method_getName(ims[j])),
                    method_getTypeEncoding(ims[j]) ?: "");
        }
        if (ims) free(ims);

        Class meta = object_getClass((id)c);
        unsigned int cmc = 0;
        Method *cms = meta ? class_copyMethodList(meta, &cmc) : NULL;
        for (unsigned int j = 0; j < cmc && j < 160; j++) {
            fprintf(fp, "  + %s  %s\n", sel_getName(method_getName(cms[j])),
                    method_getTypeEncoding(cms[j]) ?: "");
        }
        if (cms) free(cms);
    }
    free(classes);
    fprintf(fp, "\n=== done, matched classes = %d ===\n", hit);
    fclose(fp);
    SBLog(@"[KBDAPI] probe done, matched=%d -> /var/mobile/wcvk_kbdapi.log", hit);
}

static void KbdApiProbeCallback(CFNotificationCenterRef center, void *observer,
                                CFStringRef name, const void *object,
                                CFDictionaryRef userInfo) {
    dispatch_async(dispatch_get_main_queue(), ^{ KbdApiProbe(); });
}

static void KbdWarmNotifyCallback(CFNotificationCenterRef center, void *observer,
                                  CFStringRef name, const void *object,
                                  CFDictionaryRef userInfo) {
    KbdWarmupRun(@"darwin-notify");
}

// 诊断：强制走 alert 通道（一次 respring 内两条路都能验，不用重新编译）
static void KbdWarmAlertNotifyCallback(CFNotificationCenterRef center, void *observer,
                                       CFStringRef name, const void *object,
                                       CFDictionaryRef userInfo) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (gKbdWarmBusy) { SBLog(@"[KBDWARM][ALERT] skip, busy"); return; }
        gKbdWarmBusy = YES;
        SBLog(@"[KBDWARM][ALERT] ===== start (forced) wxkb_plugin_running_before=%d =====",
              KbdProcRunning());
        KbdWarmupRunAlert();
    });
}

__attribute__((constructor)) static void SBKeepAliveInit(void) {
    // 第一件事：留最原始的加载痕迹（不依赖任何 Foundation 设施）
    WCVKMarkerRaw("ctor-enter");
    @autoreleasepool {
        NSString *proc = [[NSBundle mainBundle] bundleIdentifier] ?: @"?";
        WCVKMarkerRaw("ctor-bundleid-ok");
        SBLog(@"[wetypekeepalive] CTOR loaded into %@", proc);

        // 仅 SpringBoard 内注册键盘预热（其他进程无前台 scene，做了也没用）
        if ([proc isEqualToString:@"com.apple.springboard"]) {
            // v1.9.36：去掉"注入后 25s 自动跑一次"的诊断触发。
            // 那会在每次 respring 后都弹一次键盘骚扰老板；改为一律由 daemon
            // 在发现 wxkb_plugin 不在时才发通知触发。
            CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                            NULL, KbdWarmNotifyCallback,
                                            CFSTR("com.wcvoicekeep.kbd.warmup"),
                                            NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
            SBLog(@"[KBDWARM] darwin notify com.wcvoicekeep.kbd.warmup registered");

            // v1.9.37：装上键盘显示/隐藏通知观察者，用于判定键盘是否真弹
            dispatch_async(dispatch_get_main_queue(), ^{
                KbdStartKbWatch();
            });

            // 诊断通道：com.wcvoicekeep.kbd.warmup.alert 强制走 alert 通道，
            // 便于一次 respring 内把两条路都验完（不需要重新编译）
            CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                            NULL, KbdWarmAlertNotifyCallback,
                                            CFSTR("com.wcvoicekeep.kbd.warmup.alert"),
                                            NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
            SBLog(@"[KBDWARM] darwin notify ....alert registered");

            // v1.9.40：键盘私有 API 探测通道（只读 dump，不改任何状态）
            CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                            NULL, KbdApiProbeCallback,
                                            CFSTR("com.wcvoicekeep.kbd.probe"),
                                            NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
            SBLog(@"[KBDAPI] darwin notify com.wcvoicekeep.kbd.probe registered");
        }
    }
}
