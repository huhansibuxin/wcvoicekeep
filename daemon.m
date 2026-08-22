//
//  wcvoicekeep daemon
//  目标：微信输入法（Wetype, bundle id com.tencent.wetype）主 App。
//
//  === 架构（老板 2026-08-22 拍板：TF 注入 + daemon 触发）===
//  微信主 App 有反注入自杀：MobileSubstrate/dlopen 运行时注入被检测 → 闪退。
//  改走 TrollFools 注入 dylib（dylib 成为 app 签名一部分，绕过检测）。
//  分工：
//    - dylib(inject.m, 由 TF 注入进主 App)：让主 App「自己拉一次悬浮窗」=
//      建立原生 PiP standby。监听 app active + 监听本 daemon 的 Darwin 通知。
//    - daemon(本文件, 后台常驻)：注销/重启/重越狱后，① 前台拉起主 App 一次，
//      ② 发 Darwin 通知 kTriggerName 让 dylib 去建 PiP standby（兜底）。
//  standby 一旦活，键盘扩展 requireJumpToMainAppForRecording 恒 0 → 零跳转。
//
//  daemon 生命周期：LaunchDaemon RunAtLoad + KeepAlive。
//

#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <unistd.h>
#import <notify.h>

// ===== 配置 =====
static NSString *const kTargetBundleID = @"com.tencent.wetype";
// dylib <-> daemon 约定的 Darwin 通知名（两边必须一致）
static const char *const kTriggerName = "com.wcvoicekeep.pip.trigger";
static const int kCheckIntervalSec = 60;   // 存活轮询间隔
static const int kBootDelaySec = 10;        // 开机等 SpringBoard 就绪
static const Boolean kLaunchSuspended = FALSE; // 前台拉起才能建 PiP standby
static NSString *const kLogPath = @"/var/mobile/wcvoicekeep.log";

// ===== SpringBoardServices 动态加载 =====
static int (*SBSLaunchApplicationWithIdentifier)(CFStringRef, Boolean) = NULL;
static mach_port_t (*SBSSpringBoardServerPort)(void) = NULL;
static int (*SBSSpringBoardServerGetProcessIDForDisplayIdentifier)(mach_port_t, CFStringRef, int *) = NULL;

static BOOL sbs_init(void) {
    static dispatch_once_t once; static void *sb = NULL; static BOOL ok = NO;
    dispatch_once(&once, ^{
        sb = dlopen("/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices", RTLD_LAZY);
        if (sb) {
            SBSLaunchApplicationWithIdentifier = dlsym(sb, "SBSLaunchApplicationWithIdentifier");
            SBSSpringBoardServerPort = dlsym(sb, "SBSSpringBoardServerPort");
            SBSSpringBoardServerGetProcessIDForDisplayIdentifier =
                dlsym(sb, "SBSSpringBoardServerGetProcessIDForDisplayIdentifier");
            ok = (SBSLaunchApplicationWithIdentifier && SBSSpringBoardServerPort &&
                  SBSSpringBoardServerGetProcessIDForDisplayIdentifier);
        }
    });
    return ok;
}

static void LOG(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSString *line = [NSString stringWithFormat:@"[%@][daemon] %@\n", [NSDate date], msg];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:kLogPath];
    if (!fh) { [line writeToFile:kLogPath atomically:YES encoding:NSUTF8StringEncoding error:nil]; return; }
    @try { [fh seekToEndOfFile]; [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]]; }
    @catch (NSException *e) {}
    [fh closeFile];
}

static BOOL isAppRunning(NSString *bundleID) {
    if (!sbs_init()) return NO;
    mach_port_t port = SBSSpringBoardServerPort();
    if (!port) return NO;
    int pid = 0;
    int r = SBSSpringBoardServerGetProcessIDForDisplayIdentifier(port, (__bridge CFStringRef)bundleID, &pid);
    return (r == 0 && pid > 0);
}

static void launchForeground(NSString *bundleID) {
    if (!sbs_init()) { LOG(@"[ERR] SBS init failed"); return; }
    int r = SBSLaunchApplicationWithIdentifier((__bridge CFStringRef)bundleID, kLaunchSuspended);
    LOG(@"launchForeground %@ (suspended=%d) -> SBS %d", bundleID, kLaunchSuspended, r);
}

// 发 Darwin 通知，dylib 侧收到就建 PiP standby（兜底路 B）
static void postTrigger(void) {
    notify_post(kTriggerName);
    LOG(@"posted darwin trigger %s", kTriggerName);
}

static void checkAndLaunch(void) {
    if (isAppRunning(kTargetBundleID)) { LOG(@"%@ alive", kTargetBundleID); postTrigger(); return; }
    LOG(@"%@ NOT running -> foreground launch", kTargetBundleID);
    launchForeground(kTargetBundleID);
    // 拉起后等它起来再发一次触发，dylib 建 PiP
    sleep(3);
    postTrigger();
}

int main(int argc, char *argv[]) {
    @autoreleasepool {
        LOG(@"daemon started (uid=%d, target=%@)", getuid(), kTargetBundleID);
        sleep(kBootDelaySec);
        while (1) {
            @autoreleasepool { checkAndLaunch(); }
            sleep(kCheckIntervalSec);
        }
    }
    return 0;
}
