//
//  PSControlServer.m — 基于文件的命令通道
//
//  RootHide 下 root 与 mobile 的网络栈隔离（回环端口互不可见），
//  Unix socket 也会被沙盒重定向，实测都不可用。
//  但 /var/tmp/ProxyShare 目录是两用户真正共享的（已验证双向可读写）。
//
//  所以改用一个最简单的协议：
//    设置面板写入 command.plist  {"id":N, "cmd":"...", "values":{...}}
//    守护进程每 1 秒轮询，发现 id 变化就执行，并把结果写回 response.plist
//

#import "PSCommon.h"
#import "PSControlServer.h"

#include <sys/stat.h>
#include <unistd.h>
#include <string.h>
#include <errno.h>

static PSReloadHandler gReloadHandler = nil;
static PSExitHandler   gExitHandler   = nil;

void PSControlSetReloadHandler(PSReloadHandler handler) { gReloadHandler = [handler copy]; }
void PSControlSetExitHandler(PSExitHandler handler)     { gExitHandler   = [handler copy]; }

#define PS_CMD_FILE   @"/var/tmp/ProxyShare/command.plist"
#define PS_RESP_FILE  @"/var/tmp/ProxyShare/response.plist"

static NSInteger gLastCmdID = -1;

static NSDictionary *PSHandleCommand(NSDictionary *req)
{
    NSString *cmd = req[@"cmd"];
    if (![cmd isKindOfClass:[NSString class]])
        return @{ @"ok": @NO, @"error": @"缺少 cmd" };

    PSStats *st = PSSharedStats();

    if ([cmd isEqualToString:@"status"]) {
        return [@{
            @"ok"        : @YES,
            @"running"   : @YES,
            @"pid"       : @(getpid()),
            @"socksPort" : @(PSConfigInt(@"socksPort", PS_DEFAULT_SOCKS_PORT)),
            @"httpPort"  : @(PSConfigInt(@"httpPort",  PS_DEFAULT_HTTP_PORT)),
            @"bind"      : PSConfigString(@"bindAddress", PS_DEFAULT_BIND) ?: PS_DEFAULT_BIND,
            @"aclEnabled": @(PSConfigBool(@"aclEnabled", NO)),
            @"aclList"   : PSConfigACLList(),
            @"connections": @(st.acceptedConnections),
            @"active"    : @(st.activeConnections),
            @"rejected"  : @(st.rejectedConnections),
            @"bytesUp"   : @(st.bytesUp),
            @"bytesDown" : @(st.bytesDown),
            @"lastError" : st.lastError ?: @"",
            @"startedAt" : st.startedAt ?: @"",
        } mutableCopy];
    }

    if ([cmd isEqualToString:@"setConfig"]) {
        NSDictionary *values = req[@"values"];
        if (![values isKindOfClass:[NSDictionary class]])
            return @{ @"ok": @NO, @"error": @"缺少 values" };

        BOOL needReload = NO;
        for (NSString *k in values) {
            if (![k isKindOfClass:[NSString class]]) continue;
            if ([k isEqualToString:@"socksPort"] ||
                [k isEqualToString:@"httpPort"]  ||
                [k isEqualToString:@"bindAddress"]) {
                needReload = YES;
            }
            PSConfigSet(k, values[k]);
        }

        BOOL saved = PSConfigSaveToFile();
        if (needReload && gReloadHandler) gReloadHandler();

        return @{ @"ok": @YES, @"saved": @(saved), @"reloaded": @(needReload) };
    }

    if ([cmd isEqualToString:@"resetStats"]) {
        st.acceptedConnections = 0;
        st.bytesUp = 0;
        st.bytesDown = 0;
        st.rejectedConnections = 0;
        return @{ @"ok": @YES };
    }

    if ([cmd isEqualToString:@"reload"]) {
        if (gReloadHandler) gReloadHandler();
        return @{ @"ok": @YES };
    }

    if ([cmd isEqualToString:@"shutdown"]) {
        if (gExitHandler) gExitHandler();
        return @{ @"ok": @YES };
    }

    return @{ @"ok": @NO, @"error": [NSString stringWithFormat:@"未知指令: %@", cmd] };
}

// 轮询一次
static void PSPollOnce(void)
{
    @autoreleasepool {
        NSDictionary *req = [NSDictionary dictionaryWithContentsOfFile:PS_CMD_FILE];
        if (![req isKindOfClass:[NSDictionary class]]) return;

        NSInteger cid = [req[@"id"] integerValue];
        if (cid == gLastCmdID) return;
        gLastCmdID = cid;

        NSDictionary *resp;
        @try {
            resp = PSHandleCommand(req);
        } @catch (NSException *e) {
            resp = @{ @"ok": @NO, @"error": e.reason ?: @"内部异常" };
        }

        NSMutableDictionary *out = [resp mutableCopy];
        out[@"id"] = @(cid);
        out[@"ts"] = @([[NSDate date] timeIntervalSince1970]);

        [out writeToFile:PS_RESP_FILE atomically:YES];
        chmod("/var/tmp/ProxyShare/response.plist", 0666);
    }
}

@implementation PSControlServer {
    dispatch_source_t _timer;
    BOOL _running;
}

- (BOOL)startOnPort:(uint16_t)port error:(NSString **)err
{
    if (_running) return YES;
    (void)port;

    mkdir(PS_STATE_DIR_C, 0777);

    // 清掉上一次的残留
    unlink("/var/tmp/ProxyShare/command.plist");
    unlink("/var/tmp/ProxyShare/response.plist");

    // 先写一份初始响应，让面板启动就能拿到状态
    gLastCmdID = -1;

    _running = YES;

    _timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                    dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    // 200ms 轮询一次，面板操作基本感觉不到延迟；开销可忽略
    dispatch_source_set_timer(_timer,
                              dispatch_time(DISPATCH_TIME_NOW, 200 * NSEC_PER_MSEC),
                              200 * NSEC_PER_MSEC, 100 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(_timer, ^{
        PSPollOnce();
    });
    dispatch_resume(_timer);

    PSLog(@"[CTRL] 命令通道已就绪 %s", "/var/tmp/ProxyShare/command.plist");
    return YES;
}

- (void)stop
{
    _running = NO;
    if (_timer) { dispatch_source_cancel(_timer); _timer = nil; }
}

@end
