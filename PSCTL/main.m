//
//  psctl — ProxyShare 命令行管理工具
//
//  用法（需要 root）：
//    psctl status                      查看状态
//    psctl set socks 47690             改 SOCKS 端口
//    psctl set http  47691             改 HTTP 端口
//    psctl set bind  0.0.0.0           改绑定地址
//    psctl acl on                      开启白名单
//    psctl acl off                     关闭白名单
//    psctl acl add 192.168.1.0/24      加一条规则
//    psctl acl del 192.168.1.0/24      删一条规则
//    psctl acl list                    列出规则
//    psctl restart                     重启守护进程（应用改动）
//    psctl stop / start                停止 / 启动
//
//  原理：直接改写 LaunchDaemon plist 的 ProgramArguments，再交给 launchctl 重启。
//  这是 RootHide 下唯一可靠的配置通道（不依赖任何共享文件系统）。
//

#import <Foundation/Foundation.h>

#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <sys/stat.h>
#include <sys/wait.h>

#define DAEMON_PLIST @"/Library/LaunchDaemons/com.axs.proxyshare.plist"
#define LABEL        @"com.axs.proxyshare"
#define SVC_DOMAIN   "system"
#define SHARE_DIR    @"/var/tmp/ProxyShare"

static NSMutableDictionary *LoadPlist(void)
{
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:DAEMON_PLIST];
    if (![d isKindOfClass:[NSDictionary class]]) return nil;
    NSMutableDictionary *m = [d mutableCopy];
    if (![m[@"ProgramArguments"] isKindOfClass:[NSArray class]]) return nil;
    m[@"ProgramArguments"] = [m[@"ProgramArguments"] mutableCopy];
    return m;
}

static BOOL SavePlist(NSDictionary *d)
{
    BOOL ok = [d writeToFile:DAEMON_PLIST atomically:YES];
    if (ok) chmod(DAEMON_PLIST.fileSystemRepresentation, 0644);
    return ok;
}

// 取参数值
static NSString *ArgValue(NSArray *args, NSString *flag)
{
    NSUInteger i = [args indexOfObject:flag];
    if (i == NSNotFound || i + 1 >= args.count) return nil;
    return args[i + 1];
}

static void SetArg(NSMutableArray *args, NSString *flag, NSString *value)
{
    NSUInteger i = [args indexOfObject:flag];
    if (i != NSNotFound) {
        if (i + 1 < args.count) args[i + 1] = value;
        else [args addObject:value];
    } else {
        [args addObject:flag];
        [args addObject:value];
    }
}

static void RemoveArg(NSMutableArray *args, NSString *flag)
{
    NSUInteger i = [args indexOfObject:flag];
    if (i != NSNotFound && i + 1 < args.count) {
        [args removeObjectsInRange:NSMakeRange(i, 2)];
    }
}

static int RunCtl(const char *const argv[])
{
    pid_t pid = fork();
    if (pid == 0) {
        execv("/bin/launchctl", (char *const *)argv);
        _exit(127);
    }
    if (pid < 0) return -1;
    int st = 0;
    waitpid(pid, &st, 0);
    return WIFEXITED(st) ? WEXITSTATUS(st) : -1;
}

static int DoRestart(void)
{
    const char *bootout[] = { "launchctl", "bootout", SVC_DOMAIN, DAEMON_PLIST, NULL };
    RunCtl(bootout);
    usleep(400 * 1000);
    const char *boot[] = { "launchctl", "bootstrap", SVC_DOMAIN, DAEMON_PLIST, NULL };
    int rc = RunCtl(boot);
    if (rc != 0) {
        const char *load[] = { "launchctl", "load", "-w", DAEMON_PLIST, NULL };
        rc = RunCtl(load);
    }
    return rc;
}

static void PrintStatus(void)
{
    NSMutableDictionary *d = LoadPlist();
    if (!d) {
        printf("无法读取 %s（未安装？）\n", DAEMON_PLIST.UTF8String);
        return;
    }
    NSArray *a = d[@"ProgramArguments"];
    printf("SOCKS5 端口 : %s\n", (ArgValue(a, @"--socks") ?: @"(默认 47680)").UTF8String);
    printf("HTTP   端口 : %s\n", (ArgValue(a, @"--http")  ?: @"(默认 47681)").UTF8String);
    printf("绑定地址    : %s\n", (ArgValue(a, @"--bind")  ?: @"(默认 0.0.0.0)").UTF8String);
    printf("状态        : %s\n", ArgValue(a, @"--off") ? "已禁用" : "已启用");

    // 运行态
    NSDictionary *st = [NSDictionary dictionaryWithContentsOfFile:
                        [SHARE_DIR stringByAppendingPathComponent:@"state.plist"]];
    if (st) {
        printf("进程        : pid %@\n", st[@"pid"] ?: @"?");
        printf("连接数      : 总计 %@ / 活跃 %@ / 拒绝 %@\n",
               st[@"connections"] ?: @0, st[@"active"] ?: @0, st[@"rejected"] ?: @0);
        double up = [st[@"bytesUp"] doubleValue], dn = [st[@"bytesDown"] doubleValue];
        printf("流量        : ↑ %.1f KB  ↓ %.1f KB\n", up/1024.0, dn/1024.0);
        if (st[@"bindError"]) printf("错误        : %@\n", st[@"bindError"]);
    } else {
        printf("运行态      : 未获取到（守护进程可能未运行）\n");
        printf("              psd 的 /var/tmp 与 shell 是隔离的，属正常现象\n");
    }
}

int main(int argc, const char *argv[])
{
    @autoreleasepool {
        if (geteuid() != 0) {
            printf("需要 root 权限，请用 sudo 运行\n");
            return 1;
        }

        NSMutableDictionary *plist = LoadPlist();
        if (!plist) {
            printf("无法读取 %s\n", DAEMON_PLIST.UTF8String);
            return 1;
        }
        NSMutableArray *args = plist[@"ProgramArguments"];

        if (argc < 2) {
            printf("psctl — ProxyShare 管理工具\n\n");
            printf("  psctl status              查看状态与端口\n");
            printf("  psctl set socks <端口>    改 SOCKS5 端口\n");
            printf("  psctl set http  <端口>    改 HTTP 端口\n");
            printf("  psctl set bind  <地址>    改绑定地址\n");
            printf("  psctl restart             重启（应用改动）\n");
            printf("  psctl on | off            启用 / 禁用\n\n");
            printf("注意：端口白名单通过设置面板配置，或编辑守护进程配置。\n");
            return 0;
        }

        NSString *cmd = @(argv[1]);

        if ([cmd isEqualToString:@"status"]) {
            PrintStatus();
            return 0;
        }

        if ([cmd isEqualToString:@"restart"]) {
            int rc = DoRestart();
            printf(rc == 0 ? "已重启\n" : "重启返回 %d\n", rc);
            return rc == 0 ? 0 : 1;
        }

        if ([cmd isEqualToString:@"on"] || [cmd isEqualToString:@"off"]) {
            if ([cmd isEqualToString:@"off"]) SetArg(args, @"--off", @"");
            else RemoveArg(args, @"--off");
            if (!SavePlist(plist)) { printf("写 plist 失败\n"); return 1; }
            DoRestart();
            printf([cmd isEqualToString:@"on"] ? "已启用\n" : "已禁用\n");
            return 0;
        }

        if ([cmd isEqualToString:@"set"] && argc >= 4) {
            NSString *what = @(argv[2]);
            NSString *val  = @(argv[3]);
            NSString *flag = nil;
            if      ([what isEqualToString:@"socks"]) flag = @"--socks";
            else if ([what isEqualToString:@"http"])  flag = @"--http";
            else if ([what isEqualToString:@"bind"])  flag = @"--bind";
            else { printf("未知字段: %s（可选 socks/http/bind）\n", argv[2]); return 1; }

            SetArg(args, flag, val);
            if (!SavePlist(plist)) { printf("写 plist 失败\n"); return 1; }
            printf("已设置 %s = %s，执行 psctl restart 生效\n", flag.UTF8String, val.UTF8String);
            return 0;
        }

        printf("未知命令: %s（试试不带参数查看帮助）\n", argv[1]);
        return 1;
    }
}
