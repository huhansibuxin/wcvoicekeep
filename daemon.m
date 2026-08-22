//
//  wcvoicekeep daemon
//  目标：微信输入法（Wetype, bundle id com.tencent.wetype）主 App。
//
//  === 逆向结论（capstone 静态分析 wxkb 主二进制，2026-08-22）===
//  微信输入法语音「免跳转」= 键盘扩展检测到主 App 的 PiP standby 活着就不跳转：
//    -[WBVoiceInputService requireJumpToMainAppForRecording]:
//       if (isMainAppVoiceStandbyActive) return 0;   // standby 活 → 不跳
//    -[WBVoiceInputService isMainAppVoiceStandbyActive]:
//       return [WBVoiceStateProbe pictureInPictureActive]  (= appAlive && mask.bit1)
//    状态经 WBWormhole（App Group group.com.tencent.wetype 共享）由主 App 心跳上报。
//
//  PiP standby 只能在主 App「前台激活」后建立（findAnchorWindow 需 foreground scene，
//  isPictureInPicturePossible 需前台）—— suspended 后台冷启动建立不了 PiP。
//  故采用 Plan B：注销/重启后【前台拉起主 App 一次】，让它自建 PiP standby，
//  之后主 App 原生 UIBackgroundModes:audio + PiP 常驻后台，键盘侧零跳转。
//
//  daemon 三件事：
//   1. 开机自启 -> LaunchDaemon RunAtLoad:true
//   2. daemon 自身死亡重建 -> LaunchDaemon KeepAlive:true
//   3. 注销/重启后【前台拉起主 App 一次】-> SBSLaunchApplicationWithIdentifier(bid, FALSE)
//      配套 tweak（注入主 App）在 didBecomeActive 时强制建立 PiP standby。
//
//  本 daemon 不注入、不 hook，只让系统启动主 App。
//

#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <unistd.h>

// ===== 配置：微信输入法 主 App 的 bundle id =====
static NSString *const kTargetBundleID = @"com.tencent.wetype";
// 前台拉起后的存活轮询间隔（秒）：主 App 建立 PiP+audio 后应常驻，
// 只有被系统整个回收时才需要再拉一次，故用较长间隔，避免频繁打扰。
static const int kCheckIntervalSec = 60;
// 开机后等 SpringBoard 就绪的延迟（秒）
static const int kBootDelaySec = 10;
// 拉起模式：Plan B 必须前台拉起（suspended=FALSE）才能建立 PiP standby。
static const Boolean kLaunchSuspended = FALSE;
// 日志文件路径（SSH 可读）
static NSString *const kLogPath = @"/var/mobile/wcvoicekeep.log";

// ===== SpringBoardServices 动态加载（避免直接链接私有框架）=====
static int (*SBSLaunchApplicationWithIdentifier)(CFStringRef identifier, Boolean suspended) = NULL;
static mach_port_t (*SBSSpringBoardServerPort)(void) = NULL;
static int (*SBSSpringBoardServerGetProcessIDForDisplayIdentifier)(mach_port_t port,
                                                                  CFStringRef identifier,
                                                                  int *pid) = NULL;

static BOOL sbs_init(void) {
    static dispatch_once_t once;
    static void *sb = NULL;
    static BOOL ok = NO;
    dispatch_once(&once, ^{
        sb = dlopen("/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices",
                    RTLD_LAZY);
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

// ===== 简易文件日志（daemon 里 NSLog 不一定进 oslog，写文件最稳）=====
static void LOG(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSString *line = [NSString stringWithFormat:@"[%@] %@\n", [NSDate date], msg];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:kLogPath];
    if (!fh) {
        [line writeToFile:kLogPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
        return;
    }
    @try {
        [fh seekToEndOfFile];
        [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
    } @catch (NSException *e) { }
    [fh closeFile];
}

// ===== 判断目标 App 是否在运行 =====
static BOOL isAppRunning(NSString *bundleID) {
    if (!sbs_init()) return NO;
    mach_port_t port = SBSSpringBoardServerPort();
    if (!port) return NO;
    int pid = 0;
    int r = SBSSpringBoardServerGetProcessIDForDisplayIdentifier(port,
                                                                (__bridge CFStringRef)bundleID,
                                                                &pid);
    return (r == 0 && pid > 0);
}

// ===== 前台拉起主 App（suspended=FALSE：Plan B 必须前台才能建 PiP standby）=====
static void launchForeground(NSString *bundleID) {
    if (!sbs_init()) {
        LOG(@"[ERR] SpringBoardServices init failed, cannot launch %@", bundleID);
        return;
    }
    int r = SBSLaunchApplicationWithIdentifier((__bridge CFStringRef)bundleID, kLaunchSuspended);
    LOG(@"launchForeground %@ (suspended=%d) -> SBS return %d", bundleID, kLaunchSuspended, r);
}

// ===== 检查并在需要时拉起 =====
static void checkAndLaunch(void) {
    if (isAppRunning(kTargetBundleID)) {
        LOG(@"%@ alive, skip", kTargetBundleID);
        return;
    }
    LOG(@"%@ NOT running -> foreground launch to establish PiP standby", kTargetBundleID);
    launchForeground(kTargetBundleID);
}

int main(int argc, char *argv[]) {
    @autoreleasepool {
        LOG(@"wcvoicekeep daemon started (uid=%d, target=%@)", getuid(), kTargetBundleID);

        // 开机延迟，等 SpringBoard / launchd 就绪
        sleep(kBootDelaySec);

        // 主循环：持续监控并保活目标 App（直接后台拉起，不闪）
        while (1) {
            @autoreleasepool {
                checkAndLaunch();
            }
            sleep(kCheckIntervalSec);
        }
    }
    return 0;
}
