#import "BKRecordsController.h"
#import <Preferences/PSSpecifier.h>
#import <dlfcn.h>

// 「拉起记录」页面：读 daemon 写的记录文件并列表展示。
// 记录文件：<jbroot>/var/mobile/Library/Preferences/com.wcvoicekeep.bgkeep.records.plist
//   结构：数组，每项 { t: NSDate, name: 显示名, bid: bundle id, kind: "kbd"/"app",
//                      ok: BOOL, detail: 说明 }
// 设置项 record=0 时 daemon **完全不写**（零写入零开销），本页只提示"记录已关闭"。

static NSString *const kPrefsDomain  = @"com.wcvoicekeep.bgkeep";
static NSString *const kRecordsName  = @"com.wcvoicekeep.bgkeep.records.plist";

// 越狱根定位：从本 bundle 真实加载路径掐出 <jbroot>/Library/PreferenceBundles/ 之前那一段。
static NSString *BKJbroot(void) {
    static NSString *root = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Dl_info info;
        if (dladdr((void *)&BKJbroot, &info) && info.dli_fname) {
            NSString *selfPath = [NSString stringWithUTF8String:info.dli_fname];
            NSRange r = [selfPath rangeOfString:@"/Library/PreferenceBundles/"];
            if (r.location != NSNotFound) root = [selfPath substringToIndex:r.location];
        }
        if (!root) root = @"";
    });
    return root;
}

static NSArray<NSString *> *BKPrefsDirCandidates(void) {
    NSString *jb = BKJbroot();
    NSMutableArray *a = [NSMutableArray array];
    if (jb.length) [a addObject:[jb stringByAppendingString:@"/var/mobile/Library/Preferences"]];
    [a addObject:@"/var/mobile/Library/Preferences"];
    if (![jb isEqualToString:@"/rootfs"])
        [a addObject:@"/rootfs/private/var/mobile/Library/Preferences"];
    return a;
}

// 找"存在且最新"的那份文件
static NSString *BKFindFile(NSString *name) {
    NSString *best = nil;
    double bestM = -1;
    for (NSString *dir in BKPrefsDirCandidates()) {
        NSString *p = [dir stringByAppendingFormat:@"/%@", name];
        NSDictionary *attr = [[NSFileManager defaultManager] attributesOfItemAtPath:p error:nil];
        if (!attr) continue;
        double m = [attr[NSFileModificationDate] timeIntervalSince1970];
        if (m > bestM) { bestM = m; best = p; }
    }
    return best;
}

static NSDictionary *BKReadPrefs(void) {
    NSString *p = BKFindFile([NSString stringWithFormat:@"%@.plist", kPrefsDomain]);
    if (!p) return nil;
    return [NSDictionary dictionaryWithContentsOfFile:p];
}

@implementation BKRecordsController

- (NSArray *)bkBuildSpecifiers {
    NSMutableArray *specs = [NSMutableArray array];

    NSDictionary *prefs = BKReadPrefs();
    BOOL recordOn = prefs[@"record"] ? [prefs[@"record"] boolValue] : YES;

    if (!recordOn) {
        PSSpecifier *g = [PSSpecifier groupSpecifierWithName:@"记录已关闭"];
        [g setProperty:@"「记录拉起动作」开关当前是关闭状态，插件不会写任何记录文件（不产生任何写入与 CPU 开销）。要查看记录请先回到上一页打开该开关。"
                forKey:@"footerText"];
        [specs addObject:g];
        return specs;
    }

    NSString *path = BKFindFile(kRecordsName);
    NSArray *rows = path ? [NSArray arrayWithContentsOfFile:path] : nil;
    if (![rows isKindOfClass:[NSArray class]] || rows.count == 0) {
        PSSpecifier *g = [PSSpecifier groupSpecifierWithName:@"暂无记录"];
        [g setProperty:@"还没有发生过拉起动作。被杀掉键盘扩展、或你勾选的 App 被杀之后，这里会出现一条记录。"
                forKey:@"footerText"];
        [specs addObject:g];
        return specs;
    }

    PSSpecifier *head = [PSSpecifier groupSpecifierWithName:
                         [NSString stringWithFormat:@"最近 %lu 条（新→旧）", (unsigned long)rows.count]];
    [head setProperty:@"时间 · 目标 · 结果。键盘扩展的拉起请求与 App 的后台拉起都会记录在这里。"
               forKey:@"footerText"];
    [specs addObject:head];

    NSDateFormatter *df = [[NSDateFormatter alloc] init];
    df.dateFormat = @"MM-dd HH:mm:ss";

    for (NSDictionary *r in rows) {
        if (![r isKindOfClass:[NSDictionary class]]) continue;
        NSString *name = r[@"name"] ?: r[@"bid"] ?: @"?";
        NSString *kind = [r[@"kind"] isEqualToString:@"kbd"] ? @"键盘" : @"App";
        BOOL ok = [r[@"ok"] boolValue];
        NSDate *t = [r[@"t"] isKindOfClass:[NSDate class]] ? r[@"t"] : nil;
        NSString *when = t ? [df stringFromDate:t] : @"--";
        NSString *detail = [r[@"detail"] isKindOfClass:[NSString class]] ? r[@"detail"] : @"";
        NSString *value = [NSString stringWithFormat:@"%@ · %@ %@%@", when, kind,
                           ok ? @"成功" : @"失败",
                           detail.length ? [NSString stringWithFormat:@" · %@", detail] : @""];
        PSSpecifier *s = [PSSpecifier preferenceSpecifierNamed:name
                                                        target:self
                                                           set:nil
                                                           get:nil
                                                        detail:nil
                                                          cell:PSStaticTextCell
                                                          edit:nil];
        [s setProperty:value forKey:@"value"];
        [specs addObject:s];
    }

    PSSpecifier *btn = [PSSpecifier preferenceSpecifierNamed:@"清空记录"
                                                      target:self
                                                         set:nil
                                                         get:nil
                                                      detail:nil
                                                        cell:PSButtonCell
                                                        edit:nil];
    [btn setProperty:@(YES) forKey:@"enabled"];
    [btn setButtonAction:@selector(bkClearRecords)];
    [specs addObject:btn];
    return specs;
}

- (NSArray *)specifiers {
    NSArray *s = [super specifiers];
    if (s.count == 0) {
        s = [self bkBuildSpecifiers];
        if (s.count) [self setValue:s forKey:@"specifiers"];
    }
    return s;
}

- (void)bkClearRecords {
    for (NSString *dir in BKPrefsDirCandidates()) {
        NSString *p = [dir stringByAppendingFormat:@"/%@", kRecordsName];
        [[NSFileManager defaultManager] removeItemAtPath:p error:nil];
    }
    // 重建并刷新列表
    [self setValue:[self bkBuildSpecifiers] forKey:@"specifiers"];
    [self reloadSpecifiers];
}

@end
