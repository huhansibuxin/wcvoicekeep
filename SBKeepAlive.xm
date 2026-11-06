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
#define WCVK_BUILD_TAG "v1.9.36-roothide"

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

// 取 SpringBoard 当前前台激活的 windowScene（iOS 16 建 window 需要 scene）
static UIWindowScene *KbdWarmScene(void) {
    for (UIScene *s in [[UIApplication sharedApplication] connectedScenes]) {
        if ([s isKindOfClass:[UIWindowScene class]] &&
            s.activationState == UISceneActivationStateForegroundActive) {
            return (UIWindowScene *)s;
        }
    }
    return nil;
}

static UIWindow *gKbdWarmWindow = nil;
static UITextField *gKbdWarmField = nil;
static UIWindow *gKbdPrevKeyWindow = nil;
static BOOL gKbdWarmBusy = NO;

static void KbdWarmupFinish(NSString *tag) {
    if (gKbdWarmField) {
        BOOL ok = [gKbdWarmField resignFirstResponder];
        SBLog(@"[KBDWARM] %@ resignFirstResponder=%d", tag, ok);
        [gKbdWarmField removeFromSuperview];
        gKbdWarmField = nil;
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

        // v1.9.36 关键修正（v1.9.33/34 失败的根因）：
        // 上一版为了"不干扰"设了 windowLevel = Normal-1 且不 makeKeyAndVisible，
        // 结果 UITextField 虽拿到 firstResponder，但键盘根本没被真正请求
        // （日志实证：becomeFirstResponder=1 而 wxkb_plugin_running 全程 0）。
        // 键盘扩展只在「系统真的要显示键盘」时才会被 spawn，所以必须让窗口
        // 可见 + 成为 key window，键盘才真的弹一次。
        UIWindow *w = [[UIWindow alloc] initWithWindowScene:scene];
        w.frame = CGRectMake(0, 0, 320, 2);          // 屏幕内、仅 2pt 高，尽量减少视觉干扰
        w.windowLevel = UIWindowLevelNormal + 1;
        w.rootViewController = [[UIViewController alloc] init];
        gKbdPrevKeyWindow = [[UIApplication sharedApplication] keyWindow];
        [w makeKeyAndVisible];                        // 必须：可见且 key，键盘才会真弹

        UITextField *tf = [[UITextField alloc] initWithFrame:CGRectMake(0, 0, 2, 2)];
        tf.autocorrectionType = UITextAutocorrectionTypeNo;
        tf.spellCheckingType = UITextSpellCheckingTypeNo;
        tf.inputAssistantItem.leadingBarButtonGroups = @[];
        tf.inputAssistantItem.trailingBarButtonGroups = @[];
        [w.rootViewController.view addSubview:tf];
        BOOL became = [tf becomeFirstResponder];
        BOOL attached = tf.isFirstResponder;
        SBLog(@"[KBDWARM] becomeFirstResponder=%d isFirstResponder=%d keyWindow=%@",
              became, attached, NSStringFromClass([[w class] class]));

        gKbdWarmWindow = w;
        gKbdWarmField = tf;

        // 350ms：只留够系统发出键盘请求并 spawn 扩展的时间，然后立刻收掉
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            SBLog(@"[KBDWARM] T+0.35s (键盘已弹) wxkb_plugin_running=%d", KbdProcRunning());
        });

        // v1.9.36：收键盘（对应"用户收起键盘"），之后扩展应靠已有连接常驻
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.75 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            KbdWarmupFinish(@"T+0.75s");
            SBLog(@"[KBDWARM] T+0.75s after resign wxkb_plugin_running=%d", KbdProcRunning());
        });

        // 复检：验证拉起后能否常驻（老板预期：能一直活，只有内存压力才被杀）
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            SBLog(@"[KBDWARM] T+3s (resign+2.3s) wxkb_plugin_running=%d", KbdProcRunning());
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(9.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            SBLog(@"[KBDWARM] T+9s (resign+8.3s) wxkb_plugin_running=%d", KbdProcRunning());
            gKbdWarmBusy = NO;
            SBLog(@"[KBDWARM] ===== end =====");
        });
    });
}

static void KbdWarmNotifyCallback(CFNotificationCenterRef center, void *observer,
                                  CFStringRef name, const void *object,
                                  CFDictionaryRef userInfo) {
    KbdWarmupRun(@"darwin-notify");
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
        }
    }
}
