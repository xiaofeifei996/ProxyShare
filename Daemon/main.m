//
//  main.m — 守护进程入口
//
//  launchd 以 root 身份拉起，监听 0.0.0.0 上的 SOCKS5 / HTTP 端口。
//  出站 connect() 走系统默认路由，因而自动经过本机已开启的 VPN 隧道。
//

#import "PSCommon.h"
#import "PSProxyServer.h"
#import "PSControlServer.h"

#include <signal.h>
#include <unistd.h>
#include <sys/stat.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <string.h>
#include <errno.h>
#include <limits.h>

static PSProxyServer   *gServer;
static PSControlServer *gControl;

static void PSWriteRuntimeState(BOOL running, NSString *err)
{
    PSStats *s = PSSharedStats();
    NSMutableDictionary *d = [@{
        @"running"     : @(running),
        @"socksPort"   : @(PSConfigInt(@"socksPort", PS_DEFAULT_SOCKS_PORT)),
        @"httpPort"    : @(PSConfigInt(@"httpPort",  PS_DEFAULT_HTTP_PORT)),
        @"ctrlPort"    : @(PSConfigInt(@"ctrlPort",  PS_DEFAULT_CTRL_PORT)),
        @"aclEnabled"  : @(PSConfigBool(@"aclEnabled", NO)),
        @"pid"         : @(getpid()),
        @"startedAt"   : s.startedAt ?: @"",
        @"connections" : @(s.acceptedConnections),
        @"active"      : @(s.activeConnections),
        @"rejected"    : @(s.rejectedConnections),
        @"bytesUp"     : @(s.bytesUp),
        @"bytesDown"   : @(s.bytesDown),
        @"lastError"   : s.lastError ?: @"",
        @"updatedAt"   : @([[NSDate date] timeIntervalSince1970]),
    } mutableCopy];
    if (err) d[@"bindError"] = err;
    PSWriteState(d);
}

// 重启监听（控制端口下发新端口时调用）
static void PSRestartListeners(void)
{
    uint16_t sp = (uint16_t)PSConfigInt(@"socksPort", PS_DEFAULT_SOCKS_PORT);
    uint16_t hp = (uint16_t)PSConfigInt(@"httpPort",  PS_DEFAULT_HTTP_PORT);

    PSLog(@"[配置] 重启监听 SOCKS=:%u HTTP=:%u", sp, hp);
    [gServer stop];

    NSString *e = nil;
    if (![gServer startWithSOCKS:sp http:hp error:&e]) {
        PSLog(@"[配置] 重启失败：%@", e);
        PSWriteRuntimeState(NO, e);
    } else {
        PSWriteRuntimeState(YES, nil);
    }
}

static void PSExitNow(void)
{
    PSLog(@"收到 shutdown 指令，退出");
    PSWriteRuntimeState(NO, nil);
    sleep(1);
    exit(0);
}

int main(int argc, char *argv[])
{
    signal(SIGPIPE, SIG_IGN);

    @autoreleasepool {
        // ---- 自检模式：psd --selftest ----
        if (argc > 1 && strcmp(argv[1], "--selftest") == 0) {
            fprintf(stderr, "=== psd 自检 ===\n");

            char probePath[512];
            const char *cands[] = {
                "/Library/ProxyShare",
                "/var/root/ProxyShare",
                "/Library/ProxyShare",
                NULL
            };
            for (int i = 0; cands[i]; i++) {
                int mk = mkdir(cands[i], 0777);
                int mkErr = errno;
                snprintf(probePath, sizeof(probePath), "%s/_st", cands[i]);
                FILE *t = fopen(probePath, "w");
                int opErr = errno;
                fprintf(stderr, "目录 %-32s mkdir=%d(%s) fopen=%s(%s)\n",
                        cands[i], mk, strerror(mkErr),
                        t ? "ok" : "fail", t ? "-" : strerror(opErr));
                if (t) { fclose(t); unlink(probePath); }
            }

            fprintf(stderr, "配置 enabled=%d socks=%ld http=%ld ctrl=%ld acl=%d\n",
                    PSConfigBool(@"enabled", YES),
                    (long)PSConfigInt(@"socksPort", PS_DEFAULT_SOCKS_PORT),
                    (long)PSConfigInt(@"httpPort", PS_DEFAULT_HTTP_PORT),
                    (long)PSConfigInt(@"ctrlPort", PS_DEFAULT_CTRL_PORT),
                    PSConfigBool(@"aclEnabled", NO));

            int ports[] = { 1086, 8118, 47680, 47681, 47682, 38086, 0 };
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
                fprintf(stderr, "bind :%-6d -> %s%s%s\n", ports[i],
                        r == 0 ? "成功" : "失败",
                        r == 0 ? "" : " (", r == 0 ? "" : strerror(errno));
                close(fd);
            }

            // ACL 自测
            NSArray *acl = PSConfigACLList();
            fprintf(stderr, "ACL 启用=%d 规则数=%lu\n",
                    PSConfigBool(@"aclEnabled", NO), (unsigned long)acl.count);
            for (NSString *r in acl) {
                fprintf(stderr, "  规则 %-20s 合法=%d\n", r.UTF8String, PSACLValidRule(r));
            }
            fprintf(stderr, "=== 自检结束 ===\n");
            return 0;
        }

        fprintf(stderr, "[psd] main() entered, pid=%d\n", getpid());
        fflush(stderr);

        // ---- 命令行参数优先（RootHide 下文件视图可能隔离，参数最可靠）----
        NSInteger argSocks = 0, argHttp = 0, argCtrl = 0;
        NSString *argBind = nil;
        BOOL argDisable = NO;
        for (int i = 1; i < argc; i++) {
            if (!strcmp(argv[i], "--socks") && i + 1 < argc)       argSocks = atoi(argv[++i]);
            else if (!strcmp(argv[i], "--http") && i + 1 < argc)   argHttp  = atoi(argv[++i]);
            else if (!strcmp(argv[i], "--ctrl") && i + 1 < argc)   argCtrl  = atoi(argv[++i]);
            else if (!strcmp(argv[i], "--bind") && i + 1 < argc)   argBind  = @(argv[++i]);
            else if (!strcmp(argv[i], "--off"))                    argDisable = YES;
        }
        if (argBind.length) setenv("PS_BIND_OVERRIDE", argBind.UTF8String, 1);

        mkdir(PS_STATE_DIR_C, 0777);

        // 先从磁盘载入配置，再用启动参数覆盖
        PSConfigLoadFromFile();

        if (argSocks > 0) PSConfigSet(@"socksPort", @(argSocks));
        if (argHttp  > 0) PSConfigSet(@"httpPort",  @(argHttp));
        if (argCtrl  > 0) PSConfigSet(@"ctrlPort",  @(argCtrl));

        if (argDisable || !PSConfigBool(@"enabled", YES)) {
            PSLog(@"配置为未启用（%@），退出", argDisable ? @"启动参数 --off" : @"config.plist");
            PSWriteRuntimeState(NO, nil);
            return 0;
        }

        uint16_t socksPort = (uint16_t)PSConfigInt(@"socksPort", PS_DEFAULT_SOCKS_PORT);
        uint16_t httpPort  = (uint16_t)PSConfigInt(@"httpPort",  PS_DEFAULT_HTTP_PORT);
        uint16_t ctrlPort  = (uint16_t)PSConfigInt(@"ctrlPort",  PS_DEFAULT_CTRL_PORT);
        PSLog(@"读取配置：SOCKS=:%u  HTTP=:%u  CTRL=:%u", socksPort, httpPort, ctrlPort);

        // 注册回调（控制端口用）
        PSControlSetReloadHandler(^{ PSRestartListeners(); });
        PSControlSetExitHandler(^{ PSExitNow(); });

        // 控制端口先起来，即使代理端口绑定失败也能查状态
        gControl = [PSControlServer new];
        NSString *ctrlErr = nil;
        if (![gControl startOnPort:ctrlPort error:&ctrlErr]) {
            PSLog(@"控制端口启动失败：%@", ctrlErr);
        }

        gServer = [PSProxyServer new];
        NSString *err = nil;
        if (![gServer startWithSOCKS:socksPort http:httpPort error:&err]) {
            PSLog(@"启动失败：%@", err);
            PSWriteRuntimeState(NO, err);
            return 1;
        }
        PSWriteRuntimeState(YES, nil);

        // ---- 文件通道自诊断 ----
        {
            char real[PATH_MAX] = {0};
            const char *p = PS_STATE_FILE_C;
            ssize_t n = readlink(p, real, sizeof(real) - 1);
            struct stat st;
            int st1 = stat(PS_STATE_DIR_C, &st);
            fprintf(stderr, "[DIAG] 状态文件=%s\n", p);
            fprintf(stderr, "[DIAG] stat(目录)=%d uid=%d mode=%o\n",
                    st1, st1 == 0 ? st.st_uid : -1, st1 == 0 ? (st.st_mode & 07777) : 0);

            FILE *t = fopen("/Library/ProxyShare/_diag", "w");
            fprintf(stderr, "[DIAG] fopen(_diag)=%s\n", t ? "ok" : strerror(errno));
            if (t) fclose(t);

            NSDictionary *probe = [NSDictionary dictionaryWithContentsOfFile:@"/Library/ProxyShare/command.plist"];
            fprintf(stderr, "[DIAG] 读 command.plist=%s\n",
                    probe ? "ok" : "nil/失败");

            BOOL wr = [@{@"x":@1} writeToFile:@"/Library/ProxyShare/_diag.plist" atomically:YES];
            fprintf(stderr, "[DIAG] 写 plist=%s\n", wr ? "ok" : "失败");
            (void)n; (void)real;
        }

        // 每 5 秒刷状态文件
        dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                                        dispatch_get_main_queue());
        dispatch_source_set_timer(timer,
                                  dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC),
                                  5 * NSEC_PER_SEC, NSEC_PER_SEC);
        dispatch_source_set_event_handler(timer, ^{
            PSWriteRuntimeState(YES, nil);
        });
        dispatch_resume(timer);

        // 监视配置版本（控制端口 set 会递增）
        static int lastVer = -1;
        dispatch_source_t cfgTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                                           dispatch_get_main_queue());
        dispatch_source_set_timer(cfgTimer,
                                  dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC),
                                  3 * NSEC_PER_SEC, NSEC_PER_SEC);
        dispatch_source_set_event_handler(cfgTimer, ^{
            int v = PSConfigVersion();
            if (lastVer < 0) { lastVer = v; return; }
            if (v == lastVer) return;
            lastVer = v;

            if (!PSConfigBool(@"enabled", YES)) {
                PSExitNow();
            }
            // 端口变化由控制端口直接触发 PSRestartListeners，这里只刷新状态
            PSWriteRuntimeState(YES, nil);
        });
        dispatch_resume(cfgTimer);

        dispatch_main();
    }
    return 0;
}
