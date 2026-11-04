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
#include <sys/stat.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <string.h>
#include <errno.h>

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
        // ---- 自检模式：psd --selftest ----
        if (argc > 1 && strcmp(argv[1], "--selftest") == 0) {
            fprintf(stderr, "=== psd 自检 ===\n");

            // 1) 目录写权限
            mkdir(PS_STATE_DIR_C, 0755);
            FILE *t = fopen(PS_STATE_DIR_C "/_selftest", "w");
            if (t) { fputs("ok\n", t); fclose(t); unlink(PS_STATE_DIR_C "/_selftest"); }
            fprintf(stderr, "目录可写: %s\n", t ? "是" : "否");

            // 2) 日志写入
            PSLog(@"自检日志测试");
            FILE *lg = fopen(PS_LOG_FILE_C, "r");
            fprintf(stderr, "proxy.log 可读: %s\n", lg ? "是" : "否");
            if (lg) fclose(lg);

            // 3) 配置读取
            fprintf(stderr, "配置 enabled=%d socks=%ld http=%ld bind=%s\n",
                    PSConfigBool(@"enabled", YES),
                    (long)PSConfigInt(@"socksPort", PS_DEFAULT_SOCKS_PORT),
                    (long)PSConfigInt(@"httpPort", PS_DEFAULT_HTTP_PORT),
                    PSConfigString(@"bindAddress", PS_DEFAULT_BIND).UTF8String);

            // 4) 逐端口试 bind，找出哪个能听
            int ports[] = { 1086, 8118, 47680, 47681, 38086, 0 };
            for (int i = 0; ports[i]; i++) {
                int fd = socket(AF_INET, SOCK_STREAM, 0);
                int one = 1;
                setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
                struct sockaddr_in a;
                memset(&a, 0, sizeof(a));
                a.sin_family = AF_INET;
                a.sin_addr.s_addr = htonl(INADDR_ANY);
                a.sin_port = htons((uint16_t)ports[i]);
                int r = bind(fd, (struct sockaddr *)&a, sizeof(a));
                fprintf(stderr, "bind :%d -> %s%s%s\n", ports[i], r == 0 ? "成功" : "失败",
                        r == 0 ? "" : " (", r == 0 ? "" : strerror(errno));
                close(fd);
            }
            fprintf(stderr, "=== 自检结束 ===\n");
            return 0;
        }

        // 先无条件写一条到 stderr，确认进程真的起来了
        fprintf(stderr, "[psd] main() entered, pid=%d\n", getpid());
        fflush(stderr);
        mkdir(PS_STATE_DIR_C, 0755);

        // 首次运行：写默认配置（不覆盖已有）
        // 注意：RootHide 下 access() 对某些路径可能失效，改用 fopen 试探
        {
            const char *cfgPath = PS_CONFIG_FILE_C;
            BOOL exists = NO;
            FILE *probe = fopen(cfgPath, "r");
            if (probe) { exists = YES; fclose(probe); }

            if (!exists) {
                NSDictionary *def = @{
                    @"enabled"     : @YES,
                    @"socksPort"   : @(PS_DEFAULT_SOCKS_PORT),
                    @"httpPort"    : @(PS_DEFAULT_HTTP_PORT),
                    @"bindAddress" : PS_DEFAULT_BIND,
                };
                BOOL ok = [def writeToFile:PS_CONFIG_FILE
                                 atomically:YES];
                chmod(cfgPath, 0644);
                fprintf(stderr, "[psd] 生成默认 config.plist: %s\n", ok ? "成功" : "失败");
            } else {
                fprintf(stderr, "[psd] 已有 config.plist，保持不动\n");
            }
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
