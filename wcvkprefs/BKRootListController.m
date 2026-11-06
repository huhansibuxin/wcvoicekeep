#import "BKRootListController.h"
#import <Preferences/PSSpecifier.h>
#import <dlfcn.h>

// v2.0.5：**不再有独立的「查看拉起记录」子页面**。
// 老板实测那页永远显示 "There was an error loading the preference bundle for 查看拉起记录: (null)"，
// 而记录文件本身是好的（daemon --status 每次都有 60 条、19KB 还在增长）。
// 结论：roothide 环境下 PreferenceLoader 把「同一个 bundle 里的第二层 controller」加载不起来，
// 跟我们的读取逻辑无关。改成把记录直接渲染在**根页面**的分组 footer 里 ——
// 根页面本来就能正常显示（同样的 footerText 机制，静态说明文字一直是好的），零导航、零第二个 bundle。

// 设置「实时生效」：设置 App 的开关是经 cfprefsd 写的，落盘有延迟（老板实测「勾了要注销一次才生效」）。
// 所以每次改动都直接给 daemon 发一个 Darwin 通知，daemon 收到 0.6s 后重读并重建目标。
extern uint32_t notify_post(const char *name);
static void BKPostPrefsChanged(void) {
    notify_post("com.wcvoicekeep.prefs.changed");
}

// ===== 记录读取 =====
// 读法照搬彩虹键盘 / 通知常驻岛（两个在老板机器上都读得正常的项目）：
// 硬编码 /var/mobile/Library/Preferences/<domain>.plist + 直读文件，不走 NSUserDefaults。
// 三条通道依次兜底：直读文件 -> CFPreferences -> NSUserDefaults suite。

static NSString *const kRecDomain   = @"com.wcvoicekeep.bgkeep.records";
static NSString *const kRecName     = @"com.wcvoicekeep.bgkeep.records.plist";
static NSString *const kPrefsDomain = @"com.wcvoicekeep.bgkeep";

static NSArray<NSString *> *BKRecCandidates(void) {
    return @[
        [NSString stringWithFormat:@"/var/mobile/Library/Preferences/%@", kRecName],
        [NSString stringWithFormat:@"/private/var/mobile/Library/Preferences/%@", kRecName],
        [NSString stringWithFormat:@"/rootfs/private/var/mobile/Library/Preferences/%@", kRecName],
        @"/var/mobile/wcvoicekeep.records.plist",
    ];
}

static NSArray *BKParseRows(id obj) {
    if ([obj isKindOfClass:[NSDictionary class]]) {
        id r = ((NSDictionary *)obj)[@"rows"];
        return [r isKindOfClass:[NSArray class]] ? r : nil;
    }
    if ([obj isKindOfClass:[NSArray class]]) return obj;   // v2.0.0 旧格式
    return nil;
}

static NSArray *BKReadRows(NSString **fromOut, NSString **diagOut) {
    NSMutableString *diag = [NSMutableString string];
    for (NSString *p in BKRecCandidates()) {
        NSDictionary *attr = [[NSFileManager defaultManager] attributesOfItemAtPath:p error:nil];
        if (!attr) { [diag appendFormat:@"✘ %@\n", p]; continue; }
        NSArray *r = BKParseRows([NSDictionary dictionaryWithContentsOfFile:p]);
        if (!r) r = BKParseRows([NSArray arrayWithContentsOfFile:p]);
        [diag appendFormat:@"✔ %@ (%lluB) rows=%lu\n", p,
         (unsigned long long)[attr[NSFileSize] unsignedLongLongValue], (unsigned long)r.count];
        if (r) { if (fromOut) *fromOut = p; if (diagOut) *diagOut = diag; return r; }
    }
    if (diagOut) *diagOut = diag.length ? diag : @"（所有候选路径都不存在）";
    return nil;
}

static NSArray *BKReadRowsFromCFPrefs(void) {
    CFPropertyListRef v = CFPreferencesCopyValue(CFSTR("rows"),
                                                (__bridge CFStringRef)kRecDomain,
                                                kCFPreferencesAnyUser, kCFPreferencesAnyHost);
    if (!v) v = CFPreferencesCopyValue(CFSTR("rows"),
                                       (__bridge CFStringRef)kRecDomain,
                                       kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    if (!v) return nil;
    return BKParseRows((__bridge_transfer id)v);
}

static NSArray *BKReadRowsFromUserDefaults(void) {
    @try {
        NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:kRecDomain];
        return BKParseRows([d objectForKey:@"rows"]);
    } @catch (NSException *e) {}
    return nil;
}

// 保证拿到的永远是 NSString（NSNull / 异常类型一律回落默认值）—— 页面上出现过 "null"，
// 就是有地方把 nil 塞进了 %@。
static NSString *BKSafeStr(id v, NSString *fallback) {
    if ([v isKindOfClass:[NSString class]] && [(NSString *)v length]) return v;
    if ([v isKindOfClass:[NSNumber class]]) return [(NSNumber *)v stringValue];
    return fallback;
}

// 把记录拼成一段多行文本（塞进分组 footerText）
static NSString *BKRecordsFooterText(void) {
    NSDateFormatter *df = [[NSDateFormatter alloc] init];
    // 固定 locale：不设的话在设置进程里可能按用户区域格式失败，stringFromDate 返回 nil（页面出现过 null）
    df.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    df.dateFormat = @"MM-dd HH:mm:ss";

    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:
        [NSString stringWithFormat:@"/var/mobile/Library/Preferences/%@.plist", kPrefsDomain]];
    BOOL recordOn = prefs[@"record"] ? [prefs[@"record"] boolValue] : YES;
    if (!recordOn) {
        return @"「记录拉起动作」开关是关闭状态：插件不写任何记录（零写入、零 CPU）。"
                "要记录请把上面那个开关打开。";
    }

    NSString *from = nil;
    NSString *diag = nil;
    NSArray *rows = BKReadRows(&from, &diag);
    if (!rows) { rows = BKReadRowsFromCFPrefs(); if (rows) from = @"CFPreferences"; }
    if (!rows) { rows = BKReadRowsFromUserDefaults(); if (rows) from = @"NSUserDefaults"; }
    if (!rows) rows = @[];

    if (!rows.count)
        return [NSString stringWithFormat:
                @"暂时没有记录。杀掉键盘扩展或勾选的 App 后会出现在这里。\n\n诊断：\n%@", diag];

    NSMutableString *out = [NSMutableString string];
    NSUInteger n = MIN(rows.count, (NSUInteger)14);
    for (NSUInteger i = 0; i < n; i++) {
        id r = rows[i];
        if (![r isKindOfClass:[NSDictionary class]]) continue;
        NSString *when = @"--";
        if ([r[@"t"] isKindOfClass:[NSDate class]]) {
            NSString *s = [df stringFromDate:r[@"t"]];
            if (s.length) when = s;
        }
        NSString *nm  = BKSafeStr(r[@"name"], BKSafeStr(r[@"bid"], @"?"));
        NSString *det = BKSafeStr(r[@"detail"], @"");
        // 名字太长会把 footer 撑爆，截一下
        if (nm.length > 18) nm = [[nm substringToIndex:18] stringByAppendingString:@"…"];
        [out appendFormat:@"%@  %@  %@\n", when, [r[@"ok"] boolValue] ? @"✔" : @"✘", nm];
        if (det.length) [out appendFormat:@"              %@\n", det];
    }
    if (rows.count > n) [out appendFormat:@"…… 还有 %lu 条（文件内保留最近 60 条）\n",
                         (unsigned long)(rows.count - n)];
    [out appendFormat:@"\n读取自 %@", from ?: @"?"];
    return out;
}

// ===== AltList 运行时加载 =====
// bundle 对 AltList 零链接依赖（dyld 加载永不失败），进页面时把系统安装的那份 AltList.framework
// dlopen 进设置进程，ATL 类即注册可用。路径不硬编码：先用 dladdr 拿本 bundle 真实路径掐出越狱根
// （roothide 随机 jbroot 自动适配），失败再试两个符号链接兜底。
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
    if (s.count) [self bkRefreshRecordFooterIn:s reload:NO];
    return s;
}

// 把记录文本写进 id=recGroup 那个分组的 footerText。
// PSGroupCell 是在 cellForRow 时才去读 footerText 的，所以改完属性再让表格重画就生效；
// 绝不调用 reloadSpecifiers（那会重新读 Root.plist 把改动冲掉，v2.0.2 踩过这个坑）。
- (void)bkRefreshRecordFooterIn:(NSArray *)specs reload:(BOOL)reload {
    NSString *txt = BKRecordsFooterText();
    BOOL touched = NO;
    for (PSSpecifier *sp in specs) {
        id sid = [sp propertyForKey:@"id"];
        if ([sid isKindOfClass:[NSString class]] && [(NSString *)sid isEqualToString:@"recGroup"]) {
            [sp setProperty:txt forKey:@"footerText"];
            touched = YES;
            break;
        }
    }
    if (!touched || !reload) return;
    id tv = nil;
    @try { tv = [self valueForKey:@"table"]; } @catch (NSException *e) {}
    if ([tv isKindOfClass:[UITableView class]]) [(UITableView *)tv reloadData];
}

// 每次进页面重读一遍记录（在别处杀了进程、再回来看就是最新的）
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    @try { [self bkRefreshRecordFooterIn:[self specifiers] reload:YES]; } @catch (NSException *e) {}
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
