// wcvoicekeep lite —— 只保活微信（com.tencent.xin），rootful iOS 14+（iPhone XR）
//
// 老板 2026-11-19 定案：XR 上只要「拉起微信」这一件事。
//   不做：设置页 / PreferenceLoader / AltList / SpringBoard 注入 / 键盘扩展 wxkb_plugin /
//         记录 plist / 任何第三方依赖（Depends 只有 firmware >= 14.0）。
//
// 设计要点：
//   * 事件驱动：给微信进程挂 DISPATCH_PROC_EXIT，只有它真的退出才回调，平时零轮询、零 CPU。
//   * 零主线程阻塞：SBSLaunchApplicationWithIdentifier 是同步 Mach IPC（会等 SpringBoard），
//     一律放到独立的 launch 串行队列，状态机仍在我们自己的 state 队列上串行推进。
//   * 鲁棒性：拉起 -> 1.5s 按真实 pid 校验 -> 没起来走 2/5/10/20/40s 阶梯重挂 ->
//     连续 3 次失败进 60s 冷却；单次只处理一次 EXIT 事件（gen 递增作废旧回调）。
//   * iOS 14 兼容：libproc 私有函数只做 extern 声明（iOS 上在 libSystem 里），
//     SpringBoardServices 走 dlopen/dlsym 运行时解析，不引入任何链接期符号依赖。

#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

// ===== libproc（不 include 头，避免不同 SDK 的头差异；iOS 上与 libSystem 同库）=====
extern int proc_listallpids(void *buffer, int buffersize);
extern int proc_pidpath(int pid, void *buffer, uint32_t buffersize);

static NSString *const kBID = @"com.tencent.xin";
static const char kExeSuffix[]     = "/WeChat.app/WeChat";
static const size_t kExeSuffixLen  = sizeof(kExeSuffix) - 1;

static NSString *const kLogPath = @"/var/mobile/wcvoicekeep.lite.log";

// 时序常量
static const int kStartDelaySec       = 2;    // 开机后等 SpringBoard 就绪
static const int kExitRelaunchDelaySec = 5;   // 微信退出后等 5s 再拉（避免崩溃连拉）
static const int kLaunchVerifyMs      = 1500; // 拉起后按真实 pid 校验
static const int kFuseLimit           = 3;    // 连续失败 N 次进冷却
static const int kCooldownSec         = 60;   // 冷却时长
static const int kArmRetrySecs[]      = {2, 5, 10, 20, 40};

// ===== 日志（事件驱动，只在事件发生时写一行；常态零写入）=====
static int gLogFd = -1;
static void WCLog(NSString *fmt, ...) {
    if (gLogFd < 0) return;
    char ts[32];
    time_t now = time(NULL);
    struct tm tmv;
    localtime_r(&now, &tmv);
    strftime(ts, sizeof(ts), "%Y-%m-%d %H:%M:%S", &tmv);

    va_list ap;
    va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);

    const char *m = msg.UTF8String ?: "";
    char buf[1024];
    int n = snprintf(buf, sizeof(buf), "[%s][lite] ", ts);
    size_t len = strlen(m);
    if (n > 0 && (size_t)n + len + 1 < sizeof(buf)) {
        memcpy(buf + n, m, len);
        n += (int)len;
        buf[n++] = '\n';
        ssize_t ignored = write(gLogFd, buf, (size_t)n);
        (void)ignored;
    }
}

// ===== 队列（状态机串行 / 拉起串行，均非主线程）=====
static dispatch_queue_t WCVKQueue(void) {
    static dispatch_queue_t q = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        q = dispatch_queue_create("com.wcvoicekeep.lite.state", DISPATCH_QUEUE_SERIAL);
    });
    return q;
}
static dispatch_queue_t WCVKLaunchQueue(void) {
    static dispatch_queue_t q = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        q = dispatch_queue_create("com.wcvoicekeep.lite.launch", DISPATCH_QUEUE_SERIAL);
    });
    return q;
}

// ===== SpringBoardServices：运行时解析，零链接依赖 =====
static int (*g_SBSLaunch)(CFStringRef, int) = NULL;
static BOOL WCVKSBSReady(void) {
    static dispatch_once_t once;
    static BOOL ok = NO;
    dispatch_once(&once, ^{
        void *h = dlopen("/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices",
                         RTLD_LAZY);
        if (h) {
            g_SBSLaunch = (int (*)(CFStringRef, int))dlsym(h, "SBSLaunchApplicationWithIdentifier");
        }
        ok = (g_SBSLaunch != NULL);
        WCLog(@"SpringBoardServices %@，SBSLaunchApplicationWithIdentifier=%p",
              h ? @"已加载" : @"dlopen 失败", (void *)g_SBSLaunch);
    });
    return ok;
}

// ===== 解析微信主进程 pid（一次性扫进程表；只在事件后调用，平时不扫）=====
static int WCVKFindWeChatPid(void) {
    int n = proc_listallpids(NULL, 0);
    if (n <= 0) {
        WCLog(@"proc_listallpids 预估失败 rc=%d", n);
        return 0;
    }
    int cap = n + 64;
    pid_t *pids = (pid_t *)malloc(sizeof(pid_t) * (size_t)cap);
    if (!pids) return 0;
    n = proc_listallpids(pids, (int)(sizeof(pid_t) * (size_t)cap));
    int found = 0;
    for (int i = 0; i < n; i++) {
        char path[4096];
        int r = proc_pidpath(pids[i], path, sizeof(path) - 1);
        if (r <= 0) continue;
        path[r] = '\0';
        size_t len = strlen(path);
        if (len >= kExeSuffixLen &&
            memcmp(path + len - kExeSuffixLen, kExeSuffix, kExeSuffixLen) == 0) {
            found = pids[i];
            break;
        }
    }
    free(pids);
    return found;
}

// ===== 状态（全部只在 WCVKQueue 上读写）=====
static int              gPid            = 0;
static dispatch_source_t gSrc           = nil;
static unsigned         gGen            = 0;   // 每次状态切换自增，作废旧 dispatch_after
static int              gFails          = 0;   // 连续拉起失败次数
static BOOL             gLaunching      = NO;
static time_t           gCooldownUntil  = 0;

static void WCVKArmWatch(int pid, unsigned gen);
static void WCVKLaunch(unsigned gen);
static void WCVKVerifyAndArm(unsigned gen);
static void WCVKArmRetryStep(int idx, unsigned gen);

static void WCVKStopWatch(void) {
    if (gSrc) {
        dispatch_source_cancel(gSrc);
        gSrc = nil;
    }
    gPid = 0;
}

// 已确认进程在跑：挂内核退出事件，之后完全被动等待
static void WCVKArmWatch(int pid, unsigned gen) {
    if (pid <= 0 || gen != gGen) return;
    WCVKStopWatch();
    gPid = pid;
    dispatch_source_t s = dispatch_source_create(DISPATCH_SOURCE_TYPE_PROC, (uintptr_t)pid,
                                                 DISPATCH_PROC_EXIT, WCVKQueue());
    if (!s) {
        WCLog(@"挂监视失败 pid=%d", pid);
        return;
    }
    gSrc = s;
    __block unsigned myGen = gen;
    dispatch_source_set_event_handler(s, ^{
        if (myGen != gGen) return;
        WCLog(@"WeChat (pid=%d) 已退出 -> %ds 后后台拉起", pid, kExitRelaunchDelaySec);
        WCVKStopWatch();
        unsigned g = ++gGen;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     (int64_t)kExitRelaunchDelaySec * NSEC_PER_SEC),
                       WCVKQueue(), ^{
            if (g != gGen) return;
            WCVKLaunch(g);
        });
    });
    dispatch_resume(s);
    WCLog(@"watch ARMED: WeChat (pid=%d)", pid);
}

// 后台拉起（flag=1 -> Background，不切前台）
static void WCVKLaunch(unsigned gen) {
    if (gen != gGen) return;
    if (gLaunching) {
        WCLog(@"已在拉起中，跳过重复请求");
        return;
    }
    time_t now = time(NULL);
    if (gCooldownUntil > now) {
        int wait = (int)(gCooldownUntil - now);
        WCLog(@"熔断冷却中，%ds 后再试", wait);
        unsigned g = gen;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)wait * NSEC_PER_SEC),
                       WCVKQueue(), ^{
            if (g != gGen) return;
            WCVKLaunch(g);
        });
        return;
    }
    if (!WCVKSBSReady()) {
        WCLog(@"SBSLaunch 不可用，5s 后重试");
        unsigned g = gen;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)5 * NSEC_PER_SEC),
                       WCVKQueue(), ^{
            if (g != gGen) return;
            WCVKLaunch(g);
        });
        return;
    }

    gLaunching = YES;
    WCLog(@"后台拉起 WeChat（累计失败 %d 次）", gFails);
    unsigned g = gen;
    dispatch_async(WCVKLaunchQueue(), ^{
        int rc = g_SBSLaunch((__bridge CFStringRef)kBID, 1);
        dispatch_async(WCVKQueue(), ^{
            gLaunching = NO;
            if (g != gGen) return;
            if (rc == 0) {
                WCLog(@"SBSLaunch rc=0，%dms 后按真实 pid 校验", kLaunchVerifyMs);
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                             (int64_t)kLaunchVerifyMs * NSEC_PER_MSEC),
                               WCVKQueue(), ^{
                    if (g != gGen) return;
                    WCVKVerifyAndArm(g);
                });
            } else {
                gFails++;
                WCLog(@"SBSLaunch rc=%d（失败 %d/%d）", rc, gFails, kFuseLimit);
                if (gFails >= kFuseLimit) {
                    gCooldownUntil = time(NULL) + kCooldownSec;
                    gFails = 0;
                    WCLog(@"连续失败达上限 -> 进入 %ds 冷却", kCooldownSec);
                }
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)15 * NSEC_PER_SEC),
                               WCVKQueue(), ^{
                    if (g != gGen) return;
                    WCVKLaunch(g);
                });
            }
        });
    });
}

// 拉起后校验：拿到真实 pid 才算成功
static void WCVKVerifyAndArm(unsigned gen) {
    if (gen != gGen) return;
    int pid = WCVKFindWeChatPid();
    if (pid > 0) {
        gFails = 0;
        gCooldownUntil = 0;
        WCLog(@"拉起成功 pid=%d", pid);
        WCVKArmWatch(pid, gen);
    } else {
        WCLog(@"拉起后未发现进程，走重挂阶梯");
        WCVKArmRetryStep(0, gen);
    }
}

// 阶梯重挂：2/5/10/20/40s；用完再做一次完整拉起（受熔断约束）
static void WCVKArmRetryStep(int idx, unsigned gen) {
    if (gen != gGen) return;
    int count = (int)(sizeof(kArmRetrySecs) / sizeof(kArmRetrySecs[0]));
    if (idx >= count) {
        WCLog(@"重挂阶梯耗尽，重新发起拉起");
        WCVKLaunch(gen);
        return;
    }
    int wait = kArmRetrySecs[idx];
    unsigned g = gen;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)wait * NSEC_PER_SEC),
                   WCVKQueue(), ^{
        if (g != gGen) return;
        int pid = WCVKFindWeChatPid();
        if (pid > 0) {
            gFails = 0;
            gCooldownUntil = 0;
            WCLog(@"阶梯第 %d 次（%ds）命中 pid=%d", idx + 1, wait, pid);
            WCVKArmWatch(pid, gen);
        } else {
            WCVKArmRetryStep(idx + 1, gen);
        }
    });
}

// 启动：在跑就只挂监视，没跑就拉起
static void WCVKStart(unsigned gen) {
    if (gen != gGen) return;
    int pid = WCVKFindWeChatPid();
    if (pid > 0) {
        WCLog(@"启动：WeChat 已在运行 (pid=%d) -> 只挂监视，不重复拉起", pid);
        WCVKArmWatch(pid, gen);
    } else {
        WCLog(@"启动：WeChat 未运行 -> 后台拉起");
        WCVKLaunch(gen);
    }
}

int main(int argc, char *argv[]) {
    (void)argc;
    (void)argv;
    @autoreleasepool {
        gLogFd = open(kLogPath.fileSystemRepresentation, O_WRONLY | O_CREAT | O_APPEND, 0644);
        WCLog(@"===== wcvoicekeep lite start (pid=%d) =====", getpid());

        WCVKSBSReady();
        unsigned g = ++gGen;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)kStartDelaySec * NSEC_PER_SEC),
                       WCVKQueue(), ^{
            WCVKStart(g);
        });
        dispatch_main();
    }
    return 0;
}
