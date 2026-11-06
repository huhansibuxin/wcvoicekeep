#import "BKRecordsController.h"
#import <Preferences/PSSpecifier.h>
#import <dlfcn.h>

// 「拉起记录」页面。
//
// 读法完全照搬彩虹键盘 / 通知常驻岛（两个在老板机器上都读得正常的项目）：
//   硬编码路径 + NSDictionary/NSArray dictionaryWithContentsOfFile 直读
//   —— 不用 NSUserDefaults（roothide 下读不到），不猜 jbroot。
//   记录文件：/var/mobile/Library/Preferences/com.wcvoicekeep.bgkeep.records.plist
//   v2.0.1 起格式 dict{ rows: [ {t:NSDate, name, bid, kind, ok, detail} ] }，兼容 v2.0.0 的顶层数组。
//
// 页面结构走 **plist 驱动**（Resources/BKRecords.plist，10 行座位 + 清空按钮），
// 代码只负责把读到的内容填进座位 —— v2.0.0 用代码动态拼 specifier，iOS 16 设置进程里不落屏，
// 所以「杀掉很多次也看不到记录」。plist 驱动是彩虹键盘/通知常驻岛验证过的方式。

static NSString *const kPrefsDomain = @"com.wcvoicekeep.bgkeep";
static NSString *const kRecordsDomain = @"com.wcvoicekeep.bgkeep.records";
static NSString *const kRecordsName = @"com.wcvoicekeep.bgkeep.records.plist";

// 候选文件路径（第一个就是彩虹键盘同款硬编码路径）
static NSArray<NSString *> *BKRecordsCandidates(void) {
    return @[
        [NSString stringWithFormat:@"/var/mobile/Library/Preferences/%@", kRecordsName],
        [NSString stringWithFormat:@"/private/var/mobile/Library/Preferences/%@", kRecordsName],
        [NSString stringWithFormat:@"/rootfs/private/var/mobile/Library/Preferences/%@", kRecordsName],
    ];
}

static NSString *BKPrefsPath(void) {
    return [NSString stringWithFormat:@"/var/mobile/Library/Preferences/%@.plist", kPrefsDomain];
}

// 兼容 dict{rows:[]} 与顶层数组
static NSArray *BKParseRows(id obj) {
    if ([obj isKindOfClass:[NSDictionary class]]) {
        id r = ((NSDictionary *)obj)[@"rows"];
        return [r isKindOfClass:[NSArray class]] ? r : nil;
    }
    if ([obj isKindOfClass:[NSArray class]]) return obj;
    return nil;
}

// 通道①：直读文件（彩虹键盘同款）
static NSArray *BKReadRowsFromFile(NSString **usedOut) {
    for (NSString *p in BKRecordsCandidates()) {
        if (![[NSFileManager defaultManager] fileExistsAtPath:p]) continue;
        NSArray *r = BKParseRows([NSDictionary dictionaryWithContentsOfFile:p]);
        if (!r) r = BKParseRows([NSArray arrayWithContentsOfFile:p]);
        if (r) { if (usedOut) *usedOut = p; return r; }
        if (usedOut) *usedOut = [p stringByAppendingString:@" (读到了但格式不认)"];
    }
    return nil;
}

// 通道②：CFPreferences 域读（走 cfprefsd，沙箱下也能拿到 /var/mobile/Library/Preferences 的域）
static NSArray *BKReadRowsFromCFPrefs(void) {
    CFPropertyListRef v = CFPreferencesCopyValue(CFSTR("rows"),
                                                (__bridge CFStringRef)kRecordsDomain,
                                                kCFPreferencesAnyUser, kCFPreferencesAnyHost);
    if (!v) return nil;
    return BKParseRows((__bridge_transfer id)v);
}

@implementation BKRecordsController

- (NSArray *)specifiers {
    NSArray *s = [super specifiers];
    if (s.count == 0) {
        s = [self loadSpecifiersFromPlistName:@"BKRecords" target:self
                                       bundle:[NSBundle bundleForClass:[self class]]];
        if (s.count) [self setValue:s forKey:@"specifiers"];
    }
    return s;
}

// 把读到的记录填进 plist 里的 10 个座位
- (void)bkFill {
    NSArray *rows = nil;
    NSString *from = nil;

    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:BKPrefsPath()];
    BOOL recordOn = prefs[@"record"] ? [prefs[@"record"] boolValue] : YES;

    if (!recordOn) {
        [self bkSetRows:@[] footer:@"「记录拉起动作」开关是关闭状态，插件不写任何记录（零写入、零 CPU）。要记录请回上一页打开开关。"];
        return;
    }

    rows = BKReadRowsFromFile(&from);
    if (!rows) {
        rows = BKReadRowsFromCFPrefs();
        if (rows) from = @"CFPreferences 域读";
    }

    NSDateFormatter *df = [[NSDateFormatter alloc] init];
    df.dateFormat = @"MM-dd HH:mm:ss";

    NSMutableArray *seq = [NSMutableArray array];
    for (id r in rows) {
        if (![r isKindOfClass:[NSDictionary class]]) continue;
        NSString *name = r[@"name"] ?: r[@"bid"] ?: @"?";
        if (![name isKindOfClass:[NSString class]]) name = @"?";
        NSString *kind = [r[@"kind"] isEqualToString:@"kbd"] ? @"键盘" : @"App";
        BOOL ok = [r[@"ok"] boolValue];
        NSDate *t = [r[@"t"] isKindOfClass:[NSDate class]] ? r[@"t"] : nil;
        NSString *detail = [r[@"detail"] isKindOfClass:[NSString class]] ? r[@"detail"] : @"";
        NSString *when = t ? [df stringFromDate:t] : @"--";
        NSString *value = [NSString stringWithFormat:@"%@ · %@ %@%@", when, kind,
                           ok ? @"成功" : @"失败",
                           detail.length ? [NSString stringWithFormat:@" · %@", detail] : @""];
        [seq addObject:@[name, value]];
        if (seq.count >= 10) break;
    }

    NSString *footer;
    if (seq.count) {
        footer = [NSString stringWithFormat:@"共 %lu 条（最多保留 60 条）。%@",
                  (unsigned long)rows.count, from.length ? [NSString stringWithFormat:@"读取自 %@", from] : @""];
    } else {
        NSMutableString *d = [NSMutableString stringWithString:@"暂时没有记录。杀掉键盘扩展或勾选的 App 后会出现在这里。\n诊断：\n"];
        for (NSString *p in BKRecordsCandidates()) {
            [d appendFormat:@"%@ %@\n", [[NSFileManager defaultManager] fileExistsAtPath:p] ? @"✔" : @"✘", p];
        }
        if (from.length) [d appendFormat:@"格式：%@\n", from];
        footer = d;
    }
    [self bkSetRows:seq footer:footer];
}

// 座位填充 + footer 更新 + 刷新
- (void)bkSetRows:(NSArray<NSArray *> *)seq footer:(NSString *)footer {
    for (int i = 0; i < 10; i++) {
        PSSpecifier *sp = [self specifierForID:[NSString stringWithFormat:@"row%d", i]];
        if (!sp) continue;
        if (i < (int)seq.count) {
            [sp setName:seq[i][0]];
            [sp setProperty:seq[i][1] forKey:@"value"];
            [sp setProperty:@NO forKey:@"hidden"];
        } else {
            [sp setName:@"—"];
            [sp setProperty:@"" forKey:@"value"];
        }
    }
    PSSpecifier *head = [self specifierForID:@"head"];
    if (head) [head setProperty:footer forKey:@"footerText"];

    if ([self respondsToSelector:@selector(reloadSpecifiers)])
        [self performSelector:@selector(reloadSpecifiers)];
}

// 每次进页面重新读：记录是"活的"，缓存首次的空列表会让人以为永远没记录
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    @try { [self bkFill]; } @catch (NSException *e) {}
}

- (void)bkClearRecords {
    for (NSString *p in BKRecordsCandidates())
        [[NSFileManager defaultManager] removeItemAtPath:p error:nil];
    CFPreferencesSetValue(CFSTR("rows"), NULL, (__bridge CFStringRef)kRecordsDomain,
                          kCFPreferencesAnyUser, kCFPreferencesAnyHost);
    CFPreferencesAppSynchronize((__bridge CFStringRef)kRecordsDomain);
    [self bkSetRows:@[] footer:@"已清空。"];
}

@end
