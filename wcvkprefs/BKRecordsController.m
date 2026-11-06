#import "BKRecordsController.h"
#import <Preferences/PSSpecifier.h>
#import <dlfcn.h>

// 「拉起记录」页面。
//
// 读法照搬彩虹键盘 / 通知常驻岛（两个在老板机器上都读得正常的项目）：
//   硬编码 /var/mobile/Library/Preferences/<domain>.plist + dictionaryWithContentsOfFile 直读，
//   不走 NSUserDefaults。
//
// v2.0.2 关键修复（老板实测「杀掉很多次，记录页一直空白」）：
//   以前是「改 specifier 属性 -> reloadSpecifiers」。但 reloadSpecifiers 会**重新从
//   BKRecords.plist 加载一批全新的 specifier**，我们刚填进去的 name/value 全部被丢掉，
//   页面永远停在 plist 里的占位「—」——记录其实每次都写成功了（daemon --status 能列出 20 条）。
//   现在的做法：
//     ① 自己持有 _specifiers（只在第一次从 plist 加载）；
//     ② 每次进页面把数据**原地写进这批 specifier**；
//     ③ 只让 table 重画（reloadData），绝不调用 reloadSpecifiers。

static NSString *const kRecordsDomain = @"com.wcvoicekeep.bgkeep.records";
static NSString *const kRecordsName = @"com.wcvoicekeep.bgkeep.records.plist";
static NSString *const kPrefsDomain = @"com.wcvoicekeep.bgkeep";

static NSArray<NSString *> *BKRecordsCandidates(void) {
    return @[
        [NSString stringWithFormat:@"/var/mobile/Library/Preferences/%@", kRecordsName],
        [NSString stringWithFormat:@"/private/var/mobile/Library/Preferences/%@", kRecordsName],
        [NSString stringWithFormat:@"/rootfs/private/var/mobile/Library/Preferences/%@", kRecordsName],
        @"/var/mobile/wcvoicekeep.records.plist",
    ];
}

static NSString *BKPrefsPath(void) {
    return [NSString stringWithFormat:@"/var/mobile/Library/Preferences/%@.plist", kPrefsDomain];
}

static NSArray *BKParseRows(id obj) {
    if ([obj isKindOfClass:[NSDictionary class]]) {
        id r = ((NSDictionary *)obj)[@"rows"];
        return [r isKindOfClass:[NSArray class]] ? r : nil;
    }
    if ([obj isKindOfClass:[NSArray class]]) return obj;   // v2.0.0 旧格式
    return nil;
}

// 直读文件（返回 nil 表示没读到）
static NSArray *BKReadRowsFromFile(NSString **usedOut, NSString **diagOut) {
    NSMutableString *diag = [NSMutableString string];
    for (NSString *p in BKRecordsCandidates()) {
        NSDictionary *attr = [[NSFileManager defaultManager] attributesOfItemAtPath:p error:nil];
        if (!attr) { [diag appendFormat:@"✘ %@\n", p]; continue; }
        // 先按 dict{rows:}，再按旧数组
        NSArray *r = BKParseRows([NSDictionary dictionaryWithContentsOfFile:p]);
        if (!r) r = BKParseRows([NSArray arrayWithContentsOfFile:p]);
        [diag appendFormat:@"✔ %@ (%llu B) rows=%lu\n", p,
         (unsigned long long)[attr[NSFileSize] unsignedLongLongValue], (unsigned long)r.count];
        if (r) { if (usedOut) *usedOut = p; if (diagOut) *diagOut = diag; return r; }
    }
    if (diagOut) {
        if (!diag.length) [diag appendString:@"（所有候选路径都不存在）\n"];
        *diagOut = diag;
    }
    return nil;
}

static NSArray *BKReadRowsFromCFPrefs(void) {
    CFPropertyListRef v = CFPreferencesCopyValue(CFSTR("rows"),
                                                (__bridge CFStringRef)kRecordsDomain,
                                                kCFPreferencesAnyUser, kCFPreferencesAnyHost);
    if (!v) return nil;
    return BKParseRows((__bridge_transfer id)v);
}

@implementation BKRecordsController

#pragma mark - specifier 加载（只加载一次，之后原地填数据）

- (NSMutableArray *)specifiers {
    if (!_specifiers) {
        _specifiers = [[self loadSpecifiersFromPlistName:@"BKRecords" target:self] mutableCopy];
    }
    [self bkFillInto:_specifiers];
    return _specifiers;
}

// 把读到的记录原地写进 row0..row9，footer 写进 head
- (void)bkFillInto:(NSMutableArray *)specs {
    if (!specs.count) return;

    NSArray *rows = nil;
    NSString *from = nil;
    NSString *diag = nil;
    NSString *footer = nil;

    NSDateFormatter *df = [[NSDateFormatter alloc] init];
    df.dateFormat = @"MM-dd HH:mm:ss";

    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:BKPrefsPath()];
    BOOL recordOn = prefs[@"record"] ? [prefs[@"record"] boolValue] : YES;

    if (!recordOn) {
        rows = @[];
        footer = @"「记录拉起动作」开关是关闭状态：插件不写任何记录（零写入、零 CPU）。"
                 @"要记录请回上一页打开开关。";
    } else {
        rows = BKReadRowsFromFile(&from, &diag);
        if (!rows) {
            rows = BKReadRowsFromCFPrefs();
            if (rows) from = @"CFPreferences 域读";
        }
        if (!rows) rows = @[];

        if (rows.count) {
            // v2.0.2：除了填 row0..row9，footer 里**再写一份纯文本**。
            // 万一某些 iOS 版本上 PSTitleValueCell 不吃运行时改的 name/value，
            // 记录也一定能在 footer 里看到（老板实测过"页面一直空白"，不能再赌一次）。
            NSMutableString *tail = [NSMutableString string];
            for (NSUInteger i = 0; i < rows.count && i < 6; i++) {
                id r = rows[i];
                if (![r isKindOfClass:[NSDictionary class]]) continue;
                NSString *nm = r[@"name"] ?: r[@"bid"] ?: @"?";
                NSDate *t = [r[@"t"] isKindOfClass:[NSDate class]] ? r[@"t"] : nil;
                [tail appendFormat:@"%@ %@ %@\n",
                 t ? [df stringFromDate:t] : @"--",
                 [r[@"ok"] boolValue] ? @"✔" : @"✘", nm];
            }
            footer = [NSString stringWithFormat:
                      @"共 %lu 条（文件内保留最近 60 条）。%@\n\n最近：\n%@",
                      (unsigned long)rows.count,
                      from.length ? [NSString stringWithFormat:@"读取自 %@", from] : @"",
                      tail.length ? tail : @"（无）"];
        } else {
            footer = [NSString stringWithFormat:
                      @"暂时没有记录。杀掉键盘扩展或勾选的 App 后会出现在这里。\n\n诊断：\n%@",
                      diag.length ? diag : @"（无）"];
        }
    }

    for (PSSpecifier *sp in specs) {
        NSString *sid = [sp propertyForKey:@"id"];
        if (![sid isKindOfClass:[NSString class]]) continue;

        if ([sid isEqualToString:@"head"]) {
            [sp setProperty:footer forKey:@"footerText"];
            continue;
        }
        if (![sid hasPrefix:@"row"]) continue;

        int idx = [[sid substringFromIndex:3] intValue];
        NSString *name = @"—";
        NSString *value = @"";
        if (idx >= 0 && idx < (int)rows.count) {
            id r = rows[idx];
            if ([r isKindOfClass:[NSDictionary class]]) {
                id nm = r[@"name"] ?: r[@"bid"];
                name = [nm isKindOfClass:[NSString class]] && [nm length] ? nm : @"?";
                NSString *kind = [r[@"kind"] isEqualToString:@"kbd"] ? @"键盘" : @"App";
                BOOL ok = [r[@"ok"] boolValue];
                NSDate *t = [r[@"t"] isKindOfClass:[NSDate class]] ? r[@"t"] : nil;
                NSString *detail = [r[@"detail"] isKindOfClass:[NSString class]] ? r[@"detail"] : @"";
                value = [NSString stringWithFormat:@"%@ · %@ %@%@",
                         t ? [df stringFromDate:t] : @"--",
                         kind, ok ? @"成功" : @"失败",
                         detail.length ? [NSString stringWithFormat:@" · %@", detail] : @""];
            }
        }
        [sp setName:name];
        [sp setProperty:value forKey:@"value"];
    }
}

// 每次进页面重读 + 只让表格重画（绝不 reloadSpecifiers，那会重新读 plist 冲掉数据）
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    @try {
        if (!_specifiers) {
            _specifiers = [[self loadSpecifiersFromPlistName:@"BKRecords" target:self] mutableCopy];
        }
        [self bkFillInto:_specifiers];
        id tv = nil;
        @try { tv = [self valueForKey:@"table"]; } @catch (NSException *e) {}
        if ([tv isKindOfClass:[UITableView class]]) [(UITableView *)tv reloadData];
    } @catch (NSException *e) {}
}

- (void)bkClearRecords {
    // 先尝试删文件（daemon 写完后已 chown mobile，正常情况下删得掉）
    for (NSString *p in BKRecordsCandidates())
        [[NSFileManager defaultManager] removeItemAtPath:p error:nil];
    // 再清 cfprefsd 那份，防止它把旧值又写回磁盘
    CFPreferencesSetValue(CFSTR("rows"), NULL, (__bridge CFStringRef)kRecordsDomain,
                          kCFPreferencesAnyUser, kCFPreferencesAnyHost);
    CFPreferencesAppSynchronize((__bridge CFStringRef)kRecordsDomain);

    @try {
        [self bkFillInto:_specifiers];
        id tv = nil;
        @try { tv = [self valueForKey:@"table"]; } @catch (NSException *e) {}
        if ([tv isKindOfClass:[UITableView class]]) [(UITableView *)tv reloadData];
    } @catch (NSException *e) {}
}

@end
