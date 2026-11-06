#import "BKRootListController.h"
#import <dlfcn.h>

// 主列表控制器：页面 specifier 全部由 Resources/Root.plist 静态声明
// （开关走 defaults 域 + 官方机制；App 多选子页由 ATLApplicationListMultiSelectionController 提供；
//  拉起记录子页是 BKRecordsController）。
// 教训（照 notification-island-persist v1.2.25）：不要直访 _specifiers ivar（崩溃），
// 也不需要重载 specifiers——纯 plist 驱动即可。

// AltList 运行时加载：bundle 对 AltList 零链接依赖（dyld 加载永不失败），进页面时把系统安装的
// 那份 AltList.framework dlopen 进设置进程，ATL 类即注册可用。
// 路径不硬编码：先用 dladdr 拿本 bundle 的真实加载路径掐出越狱根（roothide 随机 jbroot 自动适配），
// 失败再试 /.jbroot、/var/jb 两个符号链接兜底。
static void BKEnsureAltListLoaded(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Dl_info info;
        if (dladdr((void *)&BKEnsureAltListLoaded, &info) && info.dli_fname) {
            NSString *selfPath = [NSString stringWithUTF8String:info.dli_fname];
            NSRange range = [selfPath rangeOfString:@"/Library/PreferenceBundles/"];
            if (range.location != NSNotFound) {
                NSString *jbroot = [selfPath substringToIndex:range.location];
                NSString *p = [jbroot stringByAppendingString:@"/Library/Frameworks/AltList.framework/AltList"];
                if (dlopen(p.fileSystemRepresentation, RTLD_LAZY) != NULL) return;
            }
        }
        if (dlopen("/.jbroot/Library/Frameworks/AltList.framework/AltList", RTLD_LAZY) != NULL) return;
        dlopen("/var/jb/Library/Frameworks/AltList.framework/AltList", RTLD_LAZY);
    });
}

@implementation BKRootListController

- (instancetype)init {
    BKEnsureAltListLoaded(); // ATL 类须在本页（及其多选子页）实例化前注册进进程
    return [super init];
}

// Choicy 同款显式加载：默认 specifiers 加载链在 iOS 16 设置进程里可能不落 plist（页面全空），
// 显式指定 bundle 重新 load 一次。_specifiers 不直访，KVC 按名落 ivar。
- (NSArray *)specifiers {
    NSArray *s = [super specifiers];
    if (s.count == 0) {
        s = [self loadSpecifiersFromPlistName:@"Root" target:self
                                       bundle:[NSBundle bundleForClass:[self class]]];
        if (s.count) [self setValue:s forKey:@"specifiers"];
    }
    return s;
}

@end
