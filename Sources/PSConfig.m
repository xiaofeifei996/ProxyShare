#import "PSCommon.h"
#import <sys/stat.h>
#import <pthread.h>
#include <string.h>
#include <errno.h>
#include <stdio.h>
#include <time.h>
#include <unistd.h>

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
    mkdir(PS_STATE_DIR_C, 0777);

    BOOL ok = [state writeToFile:PS_STATE_FILE atomically:YES];
    if (!ok) {
        // 兜底：纯 C 写一份最小状态（RootHide 下 NSData 原子写偶发失败）
        char buf[2048];
        int n = snprintf(buf, sizeof(buf),
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
            "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" "
            "\"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n"
            "<plist version=\"1.0\"><dict>\n"
            "\t<key>running</key><%s/>\n"
            "\t<key>pid</key><integer>%d</integer>\n"
            "\t<key>socksPort</key><integer>%ld</integer>\n"
            "\t<key>httpPort</key><integer>%ld</integer>\n"
            "\t<key>connections</key><integer>%llu</integer>\n"
            "\t<key>bytesUp</key><integer>%llu</integer>\n"
            "\t<key>bytesDown</key><integer>%llu</integer>\n"
            "</dict></plist>\n",
            [state[@"running"] boolValue] ? "true" : "false",
            (int)getpid(),
            (long)PSConfigInt(@"socksPort", PS_DEFAULT_SOCKS_PORT),
            (long)PSConfigInt(@"httpPort", PS_DEFAULT_HTTP_PORT),
            (unsigned long long)PSSharedStats().acceptedConnections,
            (unsigned long long)PSSharedStats().bytesUp,
            (unsigned long long)PSSharedStats().bytesDown);
        FILE *fp = fopen(PS_STATE_FILE_C, "w");
        if (fp && n > 0) { fwrite(buf, 1, (size_t)n, fp); fclose(fp); }
    }
    chmod(PS_STATE_FILE_C, 0644);
}

// ---------------------------------------------------------------- 日志

// 纯 C 实现（时间戳用 strftime），完全避开 ARC / autoreleasepool
void PSLog(NSString *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);

    const char *body = msg.UTF8String ?: "";

    char stamp[32] = {0};
    time_t now = time(NULL);
    struct tm tmv;
    localtime_r(&now, &tmv);
    strftime(stamp, sizeof(stamp), "%m-%d %H:%M:%S", &tmv);

    char line[4096];
    snprintf(line, sizeof(line), "%s  %s\n", stamp, body);

    fputs(line, stderr);
    fflush(stderr);

    static pthread_mutex_t m = PTHREAD_MUTEX_INITIALIZER;
    pthread_mutex_lock(&m);
    mkdir(PS_STATE_DIR_C, 0777);
    FILE *fp = fopen(PS_LOG_FILE_C, "a");
    if (fp) {
        fputs(line, fp);
        fclose(fp);
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
