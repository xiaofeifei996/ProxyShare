#import "PSCommon.h"
#import <sys/stat.h>
#import <pthread.h>

static pthread_mutex_t gLogMutex = PTHREAD_MUTEX_INITIALIZER;

// ---------------------------------------------------------------- 配置

// 依次尝试：共享状态文件（沙盒外）→ cfprefsd → 默认值。
// 每次调用都重新读盘，避免长驻守护进程拿到过期快照。
static id PSConfigValue(NSString *key)
{
    static NSString *candidates[] = {
        @"/var/mobile/Library/ProxyShare/state.plist",
        @"/var/mobile/Library/Preferences/com.axs.proxyshare.plist",
    };
    // 1) 共享状态文件优先
    NSDictionary *shared = [NSDictionary dictionaryWithContentsOfFile:PS_STATE_FILE];
    if (shared && shared[key]) return shared[key];

    // 2) cfprefsd
    CFPropertyListRef v = CFPreferencesCopyAppValue((__bridge CFStringRef)key,
                                                    (__bridge CFStringRef)PS_PREFS_DOMAIN);
    if (v) return CFBridgingRelease(v);

    // 3) 直读偏好 plist（cfprefsd 可能没有镜像）
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:
                           @"/var/mobile/Library/Preferences/com.axs.proxyshare.plist"];
    if (prefs && prefs[key]) return prefs[key];

    (void)candidates;
    return nil;
}

BOOL PSConfigBool(NSString *key, BOOL def)
{
    id v = PSConfigValue(key);
    if (!v) return def;
    if ([v isKindOfClass:[NSNumber class]]) return [v boolValue];
    if ([v isKindOfClass:[NSString class]])
        return ([v boolValue] || [v caseInsensitiveCompare:@"yes"] == NSOrderedSame);
    return def;
}

NSInteger PSConfigInt(NSString *key, NSInteger def)
{
    id v = PSConfigValue(key);
    if (!v) return def;
    if ([v isKindOfClass:[NSNumber class]]) return [v integerValue];
    if ([v isKindOfClass:[NSString class]]) return [v integerValue];
    return def;
}

NSString *PSConfigString(NSString *key, NSString *def)
{
    id v = PSConfigValue(key);
    if ([v isKindOfClass:[NSString class]] && [(NSString *)v length]) return v;
    if ([v isKindOfClass:[NSNumber class]]) return [(NSNumber *)v stringValue];
    return def;
}

// ---------------------------------------------------------------- 状态

NSDictionary *PSReadState(void)
{
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:PS_STATE_FILE];
    return [d isKindOfClass:[NSDictionary class]] ? d : @{};
}

void PSWriteState(NSDictionary *state)
{
    [[NSFileManager defaultManager] createDirectoryAtPath:PS_STATE_DIR
                              withIntermediateDirectories:YES
                                               attributes:@{NSFilePosixPermissions: @(0755)}
                                                    error:NULL];
    [state writeToFile:PS_STATE_FILE atomically:YES];
    // 让 mobile 用户（设置面板 / SSH）也能读到
    chmod(PS_STATE_FILE.fileSystemRepresentation, 0644);
}

// ---------------------------------------------------------------- 日志

void PSLog(NSString *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);

    NSDateFormatter *df = [[NSDateFormatter alloc] init];
    df.dateFormat = @"MM-dd HH:mm:ss";
    NSString *line = [NSString stringWithFormat:@"%@  %@\n", [df stringFromDate:[NSDate date]], msg];

    // stderr（launchd 会写进自己的日志）
    fputs(line.UTF8String, stderr);
    fflush(stderr);

    // 文件日志，带行数上限
    pthread_mutex_lock(&gLogMutex);
    @autoreleasepool {
        NSFileManager *fm = [NSFileManager defaultManager];
        [fm createDirectoryAtPath:PS_STATE_DIR withIntermediateDirectories:YES
                       attributes:@{NSFilePosixPermissions: @(0755)} error:NULL];

        NSMutableArray<NSString *> *lines = [NSMutableArray array];
        NSString *old = [NSString stringWithContentsOfFile:PS_LOG_FILE
                                                  encoding:NSUTF8StringEncoding
                                                     error:NULL];
        if (old.length) [lines addObjectsFromArray:[old componentsSeparatedByString:@"\n"]];

        // 去掉尾部空串后追加
        while (lines.count && [lines.lastObject length] == 0) [lines removeLastObject];
        [lines addObject:[line stringByTrimmingCharactersInSet:
                           [NSCharacterSet newlineCharacterSet]]];

        if ((NSInteger)lines.count > PS_LOG_MAX_LINES) {
            NSUInteger drop = lines.count - PS_LOG_MAX_LINES;
            [lines removeObjectsInRange:NSMakeRange(0, drop)];
        }
        NSString *out = [[lines componentsJoinedByString:@"\n"] stringByAppendingString:@"\n"];
        [out writeToFile:PS_LOG_FILE atomically:YES
                encoding:NSUTF8StringEncoding error:NULL];
        chmod(PS_LOG_FILE.fileSystemRepresentation, 0644);
    }
    pthread_mutex_unlock(&gLogMutex);
}

// ---------------------------------------------------------------- 统计

@implementation PSStats
@end

PSStats *PSSharedStats(void)
{
    static PSStats *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        s = [PSStats new];
        NSDateFormatter *df = [[NSDateFormatter alloc] init];
        df.dateFormat = @"yyyy-MM-dd HH:mm:ss";
        s.startedAt = [df stringFromDate:[NSDate date]];
    });
    return s;
}
