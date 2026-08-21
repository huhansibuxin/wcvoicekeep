// WCIntrospect — 只读探针：枚举微信输入法主App自身可执行镜像里、含关键字的 selector，写文件日志。
// 不改任何行为（%orig 原样返回），仅打印。配合 wcvoicekeep daemon 在开机拉起主App 时于
// applicationDidFinishLaunching 触发，真机跑一遍把「进悬浮窗 / 语音启动」的入口 selector 捞出来。
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

static NSString *const kLogPath = @"/var/mobile/wcvoicekeep_introspect.log";

static void ILog(NSString *fmt, ...) {
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

// 只关心和「悬浮窗 / 语音 / 保活 / 前后台」相关的名字
static NSArray<NSString *> *kKeywords = @[
    @"float", @"floating", @"window", @"voice", @"asr", @"record", @"keep",
    @"alive", @"background", @"enter", @"present", @"show", @"hide",
    @"foreground", @"speech", @"audio", @"mic", @"input", @"keyboard",
    @"suspend", @"resume", @"active", @"launch", @"floatwindow", @"floatingwindow"
];

%hook UIApplication
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    BOOL r = %orig;
    ILog(@"=== WCIntrospect start (bid=%@) ===", [[NSBundle mainBundle] bundleIdentifier]);

    // 仅扫描主App可执行镜像里定义的类（排除系统框架，降噪）
    const char *mainImg = [[[NSBundle mainBundle] executablePath] fileSystemRepresentation];
    unsigned int classCount = 0;
    Class *classes = objc_copyClassList(&classCount);
    NSUInteger matched = 0;
    for (unsigned int i = 0; i < classCount; i++) {
        Class cls = classes[i];
        const char *img = class_getImageName(cls);
        if (!img || strcmp(img, mainImg) != 0) continue;

        unsigned int methodCount = 0;
        Method *methods = class_copyMethodList(cls, &methodCount);
        NSString *clsName = NSStringFromClass(cls);
        NSString *clsLower = clsName.lowercaseString;
        for (unsigned int j = 0; j < methodCount; j++) {
            NSString *selName = NSStringFromSelector(method_getName(methods[j]));
            NSString *selLower = selName.lowercaseString;
            for (NSString *kw in kKeywords) {
                if ([selLower containsString:kw] || [clsLower containsString:kw]) {
                    ILog(@"[MATCH] -[%@ %@]", clsName, selName);
                    matched++;
                    break;
                }
            }
        }
        if (methods) free(methods);
    }
    if (classes) free(classes);
    ILog(@"=== WCIntrospect done, matched=%lu ===", (unsigned long)matched);
    return r;
}
%end
