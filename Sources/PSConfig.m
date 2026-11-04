#import "PSCommon.h"
#import <sys/stat.h>
#import <pthread.h>
#include <string.h>
#include <errno.h>
#include <stdio.h>

// ---------------------------------------------------------------- 配置

// 依次尝试：共享状态文件（沙盒外）→ cfprefsd → 默认值。
// 每次调用都重新读盘，避免长驻守护进程拿到过期快照。
static id PSConfigValue(NSString *key)
{
    // 1) 专用配置文件优先（面板/用户写的，程序从不覆盖它）
    NSDictionary *cfg = [NSDictionary dictionaryWithContentsOfFile:PS_CONFIG_FILE];
    if (cfg && cfg[key]) return cfg[key];

    // 2) 兼容：老版本曾把配置写在 state.plist 里
    NSDictionary *shared = [NSDictionary dictionaryWithContentsOfFile:PS_STATE_FILE];
    if (shared && shared[key]) return shared[key];

    // 3) cfprefsd
    CFPropertyListRef v = CFPreferencesCopyAppValue((__bridge CFStringRef)key,
                                                    (__bridge CFStringRef)PS_PREFS_DOMAIN);
    if (v) return CFBridgingRelease(v);

    // 4) 直读偏好 plist（cfprefsd 可能没有镜像）
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:
                           @"/var/mobile/Library/Preferences/com.axs.proxyshare.plist"];
    if (prefs && prefs[key]) return prefs[key];

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
    mkdir(PS_STATE_DIR_C, 0755);
    [state writeToFile:PS_STATE_FILE atomically:YES];
    chmod(PS_STATE_FILE.fileSystemRepresentation, 0644);
}

// ---------------------------------------------------------------- 日志

// 用纯 C 实现，避免 ARC / autoreleasepool 在 launchd 早期环境下的坑
void PSLog(NSString *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);

    NSDateFormatter *df = [[NSDateFormatter alloc] init];
    df.dateFormat = @"MM-dd HH:mm:ss";
    NSString *line = [NSString stringWithFormat:@"%@  %@\n",
                      [df stringFromDate:[NSDate date]], msg];

    const char *utf8 = line.UTF8String;

    // stderr
    fputs(utf8, stderr);
    fflush(stderr);

    // 文件：纯 C，append 模式
    static pthread_mutex_t m = PTHREAD_MUTEX_INITIALIZER;
    pthread_mutex_lock(&m);
    FILE *fp = fopen(PS_LOG_FILE_C, "a");
    if (fp) {
        fputs(utf8, fp);
        fclose(fp);
    } else {
        // 日志文件打不开时，把原因写到 stderr（至少不丢信息）
        fprintf(stderr, "[psd] 无法写 proxy.log: %s\n", strerror(errno));
        fflush(stderr);
    }
    pthread_mutex_unlock(&m);
}

// 统计

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
