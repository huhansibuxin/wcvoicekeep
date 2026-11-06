#import "BKRootListController.h"
#import <Preferences/PSSpecifier.h>
#import <dlfcn.h>

// v2.0.2：设置「实时生效」。
// 设置 App 的开关是经 cfprefsd 写的，落盘有延迟（老板实测「勾了要注销一次才生效」）。
// 所以每次改动都直接给 daemon 发一个 Darwin 通知，daemon 收到 0.6s 后重读并重建目标，
// 不用等磁盘、也不用注销。
extern uint32_t notify_post(const char *name);
static void BKPostPrefsChanged(void) {
    notify_post("com.wcvoicekeep.prefs.changed");
}

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

// 任何开关改动立刻通知 daemon（不用注销）
- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    [super setPreferenceValue:value specifier:specifier];
    BKPostPrefsChanged();
}

// App 多选子页（AltList 的 ATLApplicationListMultiSelectionController）保存时不走上面的
// setPreferenceValue，所以离开本页时再补发一次，保证勾选立刻生效。
- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    BKPostPrefsChanged();
}

@end
