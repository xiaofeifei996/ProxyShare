#import "PSCommon.h"
#import <sys/stat.h>
#import <pthread.h>
#include <string.h>
#include <errno.h>
#include <stdio.h>
#include <time.h>
#include <unistd.h>
#include <arpa/inet.h>

// ================================================================ 配置
//
//  优先级：内存（控制端口下发）> config.plist > cfprefsd > 默认值
//  内存层是为了绕开 RootHide 的文件视图隔离：设置面板（mobile）
//  无法可靠地让 root 守护进程读到它写的文件，所以改走控制端口下发。

static NSMutableDictionary *gMemConfig = nil;
static pthread_mutex_t     gCfgMutex  = PTHREAD_MUTEX_INITIALIZER;
static int                 gCfgVersion = 0;

static void PSConfigEnsureMem(void)
{
    if (!gMemConfig) gMemConfig = [NSMutableDictionary dictionary];
}

// RootHide 下 Settings（mobile）写的偏好，真实位置在 AppGroup 里：
//   /rootfs/private/var/mobile/Containers/Shared/AppGroup/.jbroot-XXXX/var/mobile/Library/Preferences/
// 文件名里带 .jbroot-XXXX，每台设备不同，所以启动时扫一次缓存。
static NSArray *PSPrefsCandidatesRaw(void)
{
    static NSArray *cached = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableArray *arr = [NSMutableArray array];

        // 常规路径（非 RootHide 环境）
        [arr addObject:@"/var/mobile/Library/Preferences/com.axs.proxyshare.plist"];

        // RootHide：扫 AppGroup 下的 .jbroot-* 目录
        NSString *base = @"/private/var/mobile/Containers/Shared/AppGroup";
        NSArray *dirs = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:base
                                                                            error:NULL];
        for (NSString *d in dirs) {
            if (![d hasPrefix:@".jbroot-"]) continue;
            NSString *p = [NSString stringWithFormat:
                @"%@/%@/var/mobile/Library/Preferences/com.axs.proxyshare.plist", base, d];
            // 面板用 NSUserDefaults 写，权限常是 0600；psd 是 root + 沙盒，
            // 读不到就打不开。这里以 root 身份兜底修正。
            if ([[NSFileManager defaultManager] fileExistsAtPath:p]) {
                chmod(p.fileSystemRepresentation, 0644);
            }
            [arr addObject:p];
        }

        cached = arr;
    });
    return cached;
}

static NSArray *PSPrefsCandidates(void)
{
    NSArray *list = PSPrefsCandidatesRaw();
    // 每次读取前修一次权限：面板用 NSUserDefaults 写，权限常为 0600，
    // 而 psd 是 root + 沙盒身份，读不到就打不开配置。
    for (NSString *p in list) {
        if (access(p.fileSystemRepresentation, F_OK) == 0) {
            chmod(p.fileSystemRepresentation, 0644);
        }
    }
    return list;
}

static id PSConfigFromFile(NSString *key)
{
    // 1) 设置面板写入的偏好**优先**——这是用户刚在界面上改的值，
    //    必须盖过下面 config.plist 里的历史值，否则关开关没反应。
    for (NSString *p in PSPrefsCandidates()) {
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:p];
        if ([d isKindOfClass:[NSDictionary class]] && d[key]) return d[key];
    }

    // 2) 专用配置文件（psctl 写的 / 首次运行的默认值）
    NSDictionary *cfg = [NSDictionary dictionaryWithContentsOfFile:PS_CONFIG_FILE];
    if (cfg && cfg[key]) return cfg[key];

    // 3) cfprefsd
    CFPropertyListRef v = CFPreferencesCopyAppValue((__bridge CFStringRef)key,
                                                    (__bridge CFStringRef)PS_PREFS_DOMAIN);
    if (v) return CFBridgingRelease(v);

    return nil;
}

static id PSConfigValue(NSString *key)
{
    pthread_mutex_lock(&gCfgMutex);
    PSConfigEnsureMem();
    id mem = gMemConfig[key];
    pthread_mutex_unlock(&gCfgMutex);
    if (mem) return mem;
    return PSConfigFromFile(key);
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

void PSConfigSet(NSString *key, id value)
{
    if (!key) return;
    pthread_mutex_lock(&gCfgMutex);
    PSConfigEnsureMem();
    if (value) gMemConfig[key] = value;
    else       [gMemConfig removeObjectForKey:key];
    gCfgVersion++;
    pthread_mutex_unlock(&gCfgMutex);
}

int PSConfigVersion(void)
{
    pthread_mutex_lock(&gCfgMutex);
    int v = gCfgVersion;
    pthread_mutex_unlock(&gCfgMutex);
    return v;
}

void PSConfigLoadFromFile(void)
{
    NSDictionary *cfg = [NSDictionary dictionaryWithContentsOfFile:PS_CONFIG_FILE];
    if (![cfg isKindOfClass:[NSDictionary class]]) return;
    pthread_mutex_lock(&gCfgMutex);
    PSConfigEnsureMem();
    [gMemConfig addEntriesFromDictionary:cfg];
    pthread_mutex_unlock(&gCfgMutex);
}

BOOL PSConfigSaveToFile(void)
{
    pthread_mutex_lock(&gCfgMutex);
    PSConfigEnsureMem();
    NSDictionary *snap = [gMemConfig copy];
    pthread_mutex_unlock(&gCfgMutex);

    mkdir(PS_STATE_DIR_C, 0777);
    BOOL ok = [snap writeToFile:PS_CONFIG_FILE atomically:YES];
    if (ok) chmod(PS_CONFIG_FILE_C, 0644);
    return ok;
}

// ================================================================ ACL
//
//  规则格式（逗号分隔）：
//    192.168.1.5          单个 IP
//    192.168.1.0/24       CIDR
//    192.168.1.*          通配（等价 /24）
//    10.*                 通配（前两段）

NSArray<NSString *> *PSConfigACLList(void)
{
    NSString *raw = PSConfigString(@"aclList", @"");
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *part in [raw componentsSeparatedByString:@","]) {
        NSString *t = [part stringByTrimmingCharactersInSet:
                       [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (t.length) [out addObject:t];
    }
    return out;
}

void PSConfigSetACLList(NSArray<NSString *> *list)
{
    NSString *joined = [list componentsJoinedByString:@","];
    PSConfigSet(@"aclList", joined ?: @"");
}

// 把 a.b.c.d/n 或 a.b.c.* 解析成 (网络号, 掩码)，成功返回 YES
static BOOL PSParseCIDR(const char *rule, uint32_t *netOut, uint32_t *maskOut)
{
    char buf[64];
    strncpy(buf, rule, sizeof(buf) - 1);
    buf[sizeof(buf) - 1] = 0;

    char *slash = strchr(buf, '/');

    // 通配形式：把 * 转成 0，并算出前缀长度
    char *star = strchr(buf, '*');
    if (star) {
        int dots = 0;
        for (char *p = buf; p < star; p++) if (*p == '.') dots++;
        memset(star, '0', strlen(star));
        // a.b.c.* -> dots=3 -> /24
        int prefix = dots * 8;
        if (slash) { prefix = atoi(slash + 1); *slash = 0; }
        struct in_addr a;
        if (inet_pton(AF_INET, buf, &a) != 1) return NO;
        uint32_t mask = prefix == 0 ? 0 : (prefix >= 32 ? 0xFFFFFFFFu
                                                        : (0xFFFFFFFFu << (32 - prefix)));
        *netOut  = ntohl(a.s_addr) & mask;
        *maskOut = mask;
        return YES;
    }

    int prefix = 32;
    if (slash) {
        *slash = 0;
        prefix = atoi(slash + 1);
        if (prefix < 0 || prefix > 32) return NO;
    }
    struct in_addr a;
    if (inet_pton(AF_INET, buf, &a) != 1) return NO;
    uint32_t mask = prefix == 0 ? 0 : (prefix >= 32 ? 0xFFFFFFFFu
                                                    : (0xFFFFFFFFu << (32 - prefix)));
    *netOut  = ntohl(a.s_addr) & mask;
    *maskOut = mask;
    return YES;
}

BOOL PSACLValidRule(NSString *rule)
{
    if (!rule.length) return NO;
    uint32_t n, m;
    return PSParseCIDR(rule.UTF8String, &n, &m);
}

BOOL PSACLAllowsPeer(const char *ipStr)
{
    if (!PSConfigBool(@"aclEnabled", NO)) return YES;
    NSArray<NSString *> *list = PSConfigACLList();
    if (list.count == 0) return YES;   // 开了但没规则 = 不限制

    struct in_addr a;
    if (!ipStr || inet_pton(AF_INET, ipStr, &a) != 1) return NO;
    uint32_t ip = ntohl(a.s_addr);
    // 本机回环永远放行（面板/自测要用）
    if ((ip >> 24) == 127) return YES;

    for (NSString *rule in list) {
        uint32_t net, mask;
        if (!PSParseCIDR(rule.UTF8String, &net, &mask)) continue;
        if ((ip & mask) == net) return YES;
    }
    return NO;
}

// ================================================================ 状态

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
        // 兜底：纯 C 写一份最小状态
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

// ================================================================ 日志

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

// ================================================================ 统计

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
