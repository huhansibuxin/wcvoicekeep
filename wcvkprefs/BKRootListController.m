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

static NSString *const kRecName     = @"com.wcvoicekeep.bgkeep.records.plist";
static NSString *const kPrefsDomain = @"com.wcvoicekeep.bgkeep";

// v2.0.32（老板 2026-11-07）：daemon 记录固定写在原生 /var/mobile，绝不写 jbroot
// （.jbroot-XXXX 随机串会变）。设置页这里也以同一个固定路径为第一优先。
// 后面两条 /rootfs 是同一文件的「原生根视角」：万一设置进程被 roothide 做了路径重定向，
// /var/mobile 指向 jbroot 内部，/rootfs 仍能读到 daemon 写的原生文件。
static NSArray<NSString *> *BKRecCandidates(void) {
    return @[
        @"/var/mobile/wcvoicekeep.records.plist",
        @"/rootfs/var/mobile/wcvoicekeep.records.plist",
        @"/rootfs/private/var/mobile/wcvoicekeep.records.plist",
        [NSString stringWithFormat:@"/var/mobile/Library/Preferences/%@", kRecName],
        [NSString stringWithFormat:@"/private/var/mobile/Library/Preferences/%@", kRecName],
        [NSString stringWithFormat:@"/rootfs/private/var/mobile/Library/Preferences/%@", kRecName],
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

// 遍历全部候选、按修改时间取**最新**的那份有效记录。
// 旧实现是「命中第一个存在的文件就 return」+ 后面还有 cfprefsd 兜底：roothide 下
// daemon 写在 .jbroot-* 里、设置页的候选路径全落空，于是退回 CFPreferences 读取
// cfprefsd 内存里的僵尸快照 —— 页面就永远停在最后一次缓存的时间（老板看到的 4:16:48）。
static NSArray *BKReadRows(NSString **fromOut, NSString **diagOut) {
    NSMutableString *diag = [NSMutableString string];
    NSArray *best = nil;
    NSString *bestPath = nil;
    double bestM = -1;
    for (NSString *p in BKRecCandidates()) {
        NSDictionary *attr = [[NSFileManager defaultManager] attributesOfItemAtPath:p error:nil];
        if (!attr) { [diag appendFormat:@"✘ %@\n", p]; continue; }
        NSArray *r = BKParseRows([NSDictionary dictionaryWithContentsOfFile:p]);
        if (!r) r = BKParseRows([NSArray arrayWithContentsOfFile:p]);
        [diag appendFormat:@"%@ %@ (%lluB) rows=%lu\n", r ? @"✔" : @"!", p,
         (unsigned long long)[attr[NSFileSize] unsignedLongLongValue], (unsigned long)r.count];
        if (!r) continue;
        double m = [attr[NSFileModificationDate] timeIntervalSince1970];
        if (m > bestM) { bestM = m; best = r; bestPath = p; }
    }
    if (best) {
        if (fromOut) *fromOut = bestPath;
        if (diagOut) *diagOut = diag;
        return best;
    }
    if (diagOut) *diagOut = diag.length ? diag : @"（所有候选路径都不存在）";
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

    // 开关由 cfprefsd 管（可能只存在内存里、还没 flush 到盘），优先问 cfprefsd；
    // 直读文件只作兜底 —— roothide 下 plist 可能落在 jbroot 内而不是原生路径。
    BOOL recordOn = YES;
    CFPropertyListRef v = CFPreferencesCopyValue(CFSTR("record"),
        (__bridge CFStringRef)kPrefsDomain, kCFPreferencesAnyUser, kCFPreferencesAnyHost);
    if (v) {
        id val = (__bridge_transfer id)v;
        recordOn = [val respondsToSelector:@selector(boolValue)] ? [val boolValue] : YES;
    } else {
        NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:
            [NSString stringWithFormat:@"/var/mobile/Library/Preferences/%@.plist", kPrefsDomain]];
        if (prefs[@"record"]) recordOn = [prefs[@"record"] boolValue];
    }
    if (!recordOn) {
        return @"「记录拉起动作」开关是关闭状态：插件不写任何记录（零写入、零 CPU）。"
                "要记录请把上面那个开关打开。";
    }

    NSString *from = nil;
    NSString *diag = nil;
    // ★ 只读真实文件，绝不回退到 CFPreferences / NSUserDefaults：
    //   daemon 是直接写 plist 文件的，cfprefsd 内存里那份是历史快照，永远不刷新，
    //   读它会让页面显示「记录停在某个旧时间点」的假象（v2.0.32 修掉）。
    NSArray *rows = BKReadRows(&from, &diag);
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
    if (rows.count > n) [out appendFormat:@"…… 还有 %lu 条（文件内保留最近 20 条）\n",
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

// v2.0.6：老板实测「记录要划掉设置、再后台打开才更新」。
// 那就是 UIApplicationDidBecomeActive —— 设置 App 回到前台时立刻重读 + 重画，
// 不用再划掉。页面开着的时候也可以看到刚发生的拉起。
- (void)viewDidLoad {
    [super viewDidLoad];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(bkAppBecameActive)
                                                 name:@"UIApplicationDidBecomeActiveNotification"
                                               object:nil];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)bkAppBecameActive {
    @try { [self bkRefreshRecordFooterIn:[self specifiers] reload:YES]; } @catch (NSException *e) {}
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
