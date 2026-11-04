//
//  PSDaemon.m — 守护进程入口
//
//  launchd 以 root 身份拉起，监听 0.0.0.0 上的 SOCKS5 / HTTP 端口。
//  出站 connect() 走系统默认路由，因而自动经过本机已开启的 VPN 隧道。
//

#import "PSCommon.h"
#import "PSProxyServer.h"

#include <signal.h>
#include <unistd.h>

static PSProxyServer *gServer;

static void PSWriteRuntimeState(BOOL running, NSString *err)
{
    PSStats *s = PSSharedStats();
    NSMutableDictionary *d = [@{
        @"running"        : @(running),
        @"socksPort"      : @(PSConfigInt(@"socksPort", PS_DEFAULT_SOCKS_PORT)),
        @"httpPort"       : @(PSConfigInt(@"httpPort",  PS_DEFAULT_HTTP_PORT)),
        @"pid"            : @(getpid()),
        @"startedAt"      : s.startedAt ?: @"",
        @"connections"    : @(s.acceptedConnections),
        @"active"         : @(s.activeConnections),
        @"bytesUp"        : @(s.bytesUp),
        @"bytesDown"      : @(s.bytesDown),
        @"lastError"      : s.lastError ?: @"",
        @"updatedAt"      : @([[NSDate date] timeIntervalSince1970]),
    } mutableCopy];
    if (err) d[@"bindError"] = err;
    PSWriteState(d);
}

int main(int argc, char *argv[])
{
    signal(SIGPIPE, SIG_IGN);

    @autoreleasepool {
        // 先无条件写一条到 stderr，确认进程真的起来了
        fprintf(stderr, "[psd] main() entered, pid=%d\n", getpid());
        fflush(stderr);

        mkdir("/var/mobile/Library/ProxyShare", 0755);

        // 首次运行：写默认配置（不覆盖已有）
        if (access("/var/mobile/Library/ProxyShare/config.plist", F_OK) != 0) {
            NSDictionary *def = @{
                @"enabled"     : @YES,
                @"socksPort"   : @(PS_DEFAULT_SOCKS_PORT),
                @"httpPort"    : @(PS_DEFAULT_HTTP_PORT),
                @"bindAddress" : PS_DEFAULT_BIND,
            };
            [def writeToFile:@"/var/mobile/Library/ProxyShare/config.plist" atomically:YES];
            chmod("/var/mobile/Library/ProxyShare/config.plist", 0644);
            fprintf(stderr, "[psd] 已生成默认 config.plist\n");
        }

        PSLog(@"===== ProxyShare 守护进程启动 (pid %d) =====", getpid());

        // 未启用则直接退出，交给 launchd 的 KeepAlive 判断
        if (!PSConfigBool(@"enabled", YES)) {
            PSLog(@"配置为未启用，退出");
            PSWriteRuntimeState(NO, nil);
            return 0;
        }

        uint16_t socksPort = (uint16_t)PSConfigInt(@"socksPort", PS_DEFAULT_SOCKS_PORT);
        uint16_t httpPort  = (uint16_t)PSConfigInt(@"httpPort",  PS_DEFAULT_HTTP_PORT);
        PSLog(@"读取配置：SOCKS=:%u  HTTP=:%u", socksPort, httpPort);

        gServer = [PSProxyServer new];
        NSString *err = nil;
        if (![gServer startWithSOCKS:socksPort http:httpPort error:&err]) {
            PSLog(@"启动失败：%@", err);
            PSWriteRuntimeState(NO, err);
            return 1;
        }
        PSWriteRuntimeState(YES, nil);

        // 每 5 秒刷一次状态文件，供设置面板显示
        dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                                        dispatch_get_main_queue());
        dispatch_source_set_timer(timer,
                                  dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC),
                                  5 * NSEC_PER_SEC, NSEC_PER_SEC);
        dispatch_source_set_event_handler(timer, ^{
            PSWriteRuntimeState(YES, nil);
        });
        dispatch_resume(timer);

        // 配置变化时重载（端口/开关）
        dispatch_source_t cfgTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                                           dispatch_get_main_queue());
        dispatch_source_set_timer(cfgTimer,
                                  dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC),
                                  10 * NSEC_PER_SEC, NSEC_PER_SEC);
        // 用当前配置初始化，避免首次 tick 就误判为「变更」
        static BOOL inited = NO;
        static NSInteger lastHash = 0;
        if (!inited) {
            inited = YES;
            lastHash = (PSConfigBool(@"enabled", YES) ? 1000000 : 0)
                     + PSConfigInt(@"socksPort", PS_DEFAULT_SOCKS_PORT) * 1000
                     + PSConfigInt(@"httpPort", PS_DEFAULT_HTTP_PORT);
        }
        dispatch_source_set_event_handler(cfgTimer, ^{
            BOOL on = PSConfigBool(@"enabled", YES);
            NSInteger sp = PSConfigInt(@"socksPort", PS_DEFAULT_SOCKS_PORT);
            NSInteger hp = PSConfigInt(@"httpPort", PS_DEFAULT_HTTP_PORT);
            NSInteger h = (on ? 1000000 : 0) + sp * 1000 + hp;
            if (h == lastHash) return;
            lastHash = h;

            if (!on) {
                PSLog(@"配置关闭，退出进程（launchd 将不再拉起）");
                [gServer stop];
                PSWriteRuntimeState(NO, nil);
                exit(0);
            }
            PSLog(@"配置变更（SOCKS=:%ld HTTP=:%ld），重启监听", (long)sp, (long)hp);
            [gServer stop];
            NSString *e = nil;
            if (![gServer startWithSOCKS:(uint16_t)sp http:(uint16_t)hp error:&e]) {
                PSWriteRuntimeState(NO, e);
            } else {
                PSWriteRuntimeState(YES, nil);
            }
        });
        dispatch_resume(cfgTimer);

        dispatch_main();
    }
    return 0;
}
