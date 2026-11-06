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
        BOOL ok = [gKbdPrevKeyWindow makeKeyWindow];
        SBLog(@"[KBDWARM] %@ restore prev keyWindow=%d", tag, ok);
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

        UIWindowScene *scene = KbdWarmScene();
        if (!scene) {
            SBLog(@"[KBDWARM] ABORT: no foregroundActive UIWindowScene");
            gKbdWarmBusy = NO;
            return;
        }

        UIWindow *w = [[UIWindow alloc] initWithWindowScene:scene];
        w.frame = CGRectMake(-4, -4, 2, 2);
        w.windowLevel = UIWindowLevelNormal - 1;   // 低于 SB 常规层，尽量不挡界面
        w.rootViewController = [[UIViewController alloc] init];
        // 记录原 key window，结束后恢复；不调用 makeKeyAndVisible（避免抢可见层）
        gKbdPrevKeyWindow = [[UIApplication sharedApplication] keyWindow];
        w.hidden = NO;
        [w makeKeyWindow];

        UITextField *tf = [[UITextField alloc] initWithFrame:CGRectMake(0, 0, 2, 2)];
        tf.autocorrectionType = UITextAutocorrectionTypeNo;
        [w.rootViewController.view addSubview:tf];
        BOOL became = [tf becomeFirstResponder];
        BOOL attached = tf.isFirstResponder;
        SBLog(@"[KBDWARM] becomeFirstResponder=%d isFirstResponder=%d (键盘可能闪现约 1.2s)",
              became, attached);

        gKbdWarmWindow = w;
        gKbdWarmField = tf;

        // 700ms 后看进程是否起来（launchd 拉起 + dyld 加载 56MB 需要时间）
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.7 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            SBLog(@"[KBDWARM] T+0.7s wxkb_plugin_running=%d", KbdProcRunning());
        });

        // 1.2s 后撤掉键盘（模拟"收起键盘"），这是关键观察点
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            KbdWarmupFinish(@"T+1.2s");
            SBLog(@"[KBDWARM] T+1.2s after resign wxkb_plugin_running=%d", KbdProcRunning());
        });

        // 撤掉后 3s / 10s 复检：验证 launchd 是否因无活跃连接把扩展回收
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.2 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            SBLog(@"[KBDWARM] T+4.2s (resign+3s) wxkb_plugin_running=%d", KbdProcRunning());
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(11.2 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            SBLog(@"[KBDWARM] T+11.2s (resign+10s) wxkb_plugin_running=%d", KbdProcRunning());
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
    @autoreleasepool {
        NSString *proc = [[NSBundle mainBundle] bundleIdentifier] ?: @"?";
        SBLog(@"[wetypekeepalive] CTOR loaded into %@", proc);

        // 仅 SpringBoard 内注册键盘预热（其他进程无前台 scene，做了也没用）
        if ([proc isEqualToString:@"com.apple.springboard"]) {
            // 用公开的 Darwin 通知中心，避免 libnotify 链接依赖
            CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                            NULL, KbdWarmNotifyCallback,
                                            CFSTR("com.wcvoicekeep.kbd.warmup"),
                                            NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
            SBLog(@"[KBDWARM] darwin notify com.wcvoicekeep.kbd.warmup registered");

            // 诊断版：注入 25s 后自动跑一次，装完即可验证
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(25.0 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                KbdWarmupRun(@"auto-25s");
            });
        }
    }
}
