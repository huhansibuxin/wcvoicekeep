//
//  wcvoicekeep daemon
//  目标：微信输入法（Wetype, bundle id com.tencent.wetype）主 App。
//        用我们的 daemon 替代微信输入法【自身的悬浮窗保活】，从而消除
//        语音免跳转的「首次前台跳转」。与微信(聊天App)无关。
//
//  三件事：
//   1. 开机自启  -> LaunchDaemon plist RunAtLoad:true（系统 launchd 拉起本 daemon）
//   2. 死亡重建  -> LaunchDaemon plist KeepAlive:true（daemon 自身崩了自动重启）
//                 + 主循环监控微信输入法主App，死了就重拉（满足「app 死亡重建」）
//   3. 直接后台拉起 -> SBSLaunchApplicationWithIdentifier(bundleId, suspended=TRUE)
//                    suspended=TRUE = 直接后台拉起，不进前台、不在主屏闪。
//
//  本 daemon 不注入、不 hook 微信输入法任何东西，只是让系统去启动它。
//  因此微信输入法是否加密、Frida 能否附着，与此 daemon 完全无关。
//
//  真正要真机验证的点（非 Frida、黑盒功能测试）：
//   微信输入法被 suspended 后台拉起后，其免跳转语音通道是否能在后台态响应
//   键盘扩展。能 -> 无需 tweak，直接完工；
//   不能(冻结太死) -> 配套 ElleKit tweak 把它唤醒到后台运行态 + 保活 + 强制语音 init。
//

#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <unistd.h>

// ===== 配置：微信输入法 主 App 的 bundle id（如与实际不符，改这里）=====
static NSString *const kTargetBundleID = @"com.tencent.wetype";
// 轮询间隔（秒）
static const int kCheckIntervalSec = 15;
// 开机后等 SpringBoard 起来的延迟（秒）
static const int kBootDelaySec = 8;
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

// ===== 直接后台拉起（suspended=TRUE：不进前台、不在主屏闪）=====
static void launchHeadless(NSString *bundleID) {
    if (!sbs_init()) {
        LOG(@"[ERR] SpringBoardServices init failed, cannot launch %@", bundleID);
        return;
    }
    int r = SBSLaunchApplicationWithIdentifier((__bridge CFStringRef)bundleID, TRUE);
    LOG(@"launchHeadless %@ (suspended) -> SBS return %d", bundleID, r);
}

// ===== 检查并在需要时直接后台拉起 =====
static void checkAndLaunch(void) {
    if (isAppRunning(kTargetBundleID)) {
        LOG(@"%@ alive, skip", kTargetBundleID);
        return;
    }
    LOG(@"%@ NOT running -> direct background launch (no flash)", kTargetBundleID);
    launchHeadless(kTargetBundleID);
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
