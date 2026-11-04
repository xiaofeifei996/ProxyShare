//
//  psctl — ProxyShare 命令行管理工具
//
//  用法（需要 root）：
//    psctl status              查看状态与端口
//    psctl set socks <端口>    改 SOCKS5 端口
//    psctl set http  <端口>    改 HTTP 端口
//    psctl set bind  <地址>    改绑定地址
//    psctl restart             重启守护进程（应用改动）
//    psctl on | off            启用 / 禁用
//
//  原理：改写 LaunchDaemon plist 的 ProgramArguments，再交给 launchctl 重启。
//  这是 RootHide 下唯一可靠的配置通道（root 与 mobile 文件系统/网络栈均隔离）。
//

#import <Foundation/Foundation.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <limits.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <mach-o/dyld.h>

#define LABEL        @"com.axs.proxyshare"
#define SVC_DOMAIN   "system"
#define PLIST_REL    @"Library/LaunchDaemons/com.axs.proxyshare.plist"

static NSString *gPlistPath = nil;

// 从自身可执行路径倒推 jbroot：
//   <jbroot>/usr/bin/psctl  ->  <jbroot>/Library/LaunchDaemons/xxx.plist
// RootHide 的 dyldhook 会把 /Library 重定向到 .jbroot-XXXX/Library，
// 所以只有按自身路径推导才可靠。
static NSString *ResolvePlistPath(void)
{
    NSMutableArray *cands = [NSMutableArray array];

    uint32_t sz = 0;
    _NSGetExecutablePath(NULL, &sz);
    if (sz > 0) {
        char *buf = malloc(sz + 1);
        if (buf && _NSGetExecutablePath(buf, &sz) == 0) {
            NSString *exe = [NSString stringWithUTF8String:buf];
            // <jbroot>/usr/bin/psctl -> <jbroot>
            NSString *root = [[exe stringByDeletingLastPathComponent]
                                     stringByDeletingLastPathComponent];
            root = [root stringByDeletingLastPathComponent];
            [cands addObject:[root stringByAppendingPathComponent:PLIST_REL]];
        }
        free(buf);
    }

    // .jbroot-XXXX 枚举（部分环境可读）
    NSString *apps = @"/var/containers/Bundle/Application";
    NSArray *dirs = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:apps error:NULL];
    for (NSString *d in dirs) {
        if (![d hasPrefix:@".jbroot-"]) continue;
        [cands addObject:[NSString stringWithFormat:@"%@/%@/%@", apps, d, PLIST_REL]];
    }

    // 真实路径（bash/shell 视角，通常可读写）
    [cands addObject:[@"/" stringByAppendingPathComponent:PLIST_REL]];

    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *p in cands) {
        if ([fm fileExistsAtPath:p]) return p;
    }
    return cands.firstObject ?: [@"/" stringByAppendingPathComponent:PLIST_REL];
}

static NSString *PlistPath(void)
{
    if (!gPlistPath) gPlistPath = ResolvePlistPath();
    return gPlistPath;
}

static NSMutableDictionary *LoadPlist(void)
{
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:PlistPath()];
    if (![d isKindOfClass:[NSDictionary class]]) return nil;
    NSMutableDictionary *m = [d mutableCopy];
    if (![m[@"ProgramArguments"] isKindOfClass:[NSArray class]]) return nil;
    m[@"ProgramArguments"] = [m[@"ProgramArguments"] mutableCopy];
    return m;
}

// 直接写 jbroot 内的 plist 常被系统保护（Operation not permitted）。
// /bin/bash 被 RootHide patch 过，看到的是真实 /Library，因此
// 先写临时文件，再交给 bash 复制过去。
static BOOL SavePlist(NSDictionary *d)
{
    NSString *tmp = @"/var/tmp/.proxyshare_daemon.plist";
    if (![d writeToFile:tmp atomically:YES]) return NO;
    chmod(tmp.fileSystemRepresentation, 0644);

    NSString *target = @"/Library/LaunchDaemons/com.axs.proxyshare.plist";
    NSString *cmd = [NSString stringWithFormat:@"/bin/cp -f '%@' '%@'", tmp, target];

    pid_t pid = fork();
    if (pid == 0) {
        execl("/bin/bash", "bash", "-c", cmd.UTF8String, (char *)NULL);
        _exit(127);
    }
    if (pid < 0) return NO;
    int st = 0;
    waitpid(pid, &st, 0);
    BOOL ok = WIFEXITED(st) && WEXITSTATUS(st) == 0;
    unlink(tmp.fileSystemRepresentation);

    // 让后续读取走真实路径
    gPlistPath = target;
    return ok;
}

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
    NSString *pp = PlistPath();
    const char *path = pp.fileSystemRepresentation;

    const char *bootout[] = { "launchctl", "bootout", SVC_DOMAIN, path, NULL };
    RunCtl(bootout);
    usleep(400 * 1000);

    const char *boot[] = { "launchctl", "bootstrap", SVC_DOMAIN, path, NULL };
    int rc = RunCtl(boot);
    if (rc != 0) {
        const char *load[] = { "launchctl", "load", "-w", path, NULL };
        rc = RunCtl(load);
    }
    return rc;
}

// 运行态：psd 的 /var/tmp 与 shell 隔离，可能读不到，属正常
static NSDictionary *ReadState(void)
{
    NSArray *cands = @[
        @"/var/tmp/ProxyShare/state.plist",
        @"/private/var/tmp/ProxyShare/state.plist",
    ];
    for (NSString *p in cands) {
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:p];
        if ([d isKindOfClass:[NSDictionary class]]) return d;
    }
    return nil;
}

static void PrintStatus(void)
{
    NSMutableDictionary *d = LoadPlist();
    printf("配置文件 : %s\n", PlistPath().UTF8String);

    if (!d) {
        printf("状态     : 未安装或 plist 不可读\n");
        return;
    }

    NSArray *a = d[@"ProgramArguments"];
    NSString *socks = ArgValue(a, @"--socks") ?: @"47680(默认)";
    NSString *http  = ArgValue(a, @"--http")  ?: @"47681(默认)";
    NSString *bind  = ArgValue(a, @"--bind")  ?: @"0.0.0.0(默认)";

    printf("SOCKS5   : %s\n", socks.UTF8String);
    printf("HTTP     : %s\n", http.UTF8String);
    printf("绑定     : %s\n", bind.UTF8String);
    printf("开关     : %s\n", [a containsObject:@"--off"] ? "已禁用" : "已启用");

    NSDictionary *st = ReadState();
    if (st) {
        printf("进程     : pid %ld\n", (long)[st[@"pid"] integerValue]);
        printf("连接     : 总计 %ld / 活跃 %ld / 拒绝 %ld\n",
               (long)[st[@"connections"] integerValue],
               (long)[st[@"active"] integerValue],
               (long)[st[@"rejected"] integerValue]);
        double up = [st[@"bytesUp"] doubleValue], dn = [st[@"bytesDown"] doubleValue];
        printf("流量     : 上行 %.1f KB  下行 %.1f KB\n", up / 1024.0, dn / 1024.0);
        NSString *be = st[@"bindError"];
        if (be.length) printf("错误     : %s\n", be.UTF8String);
    } else {
        printf("运行态   : 读不到（psd 的 /var/tmp 与 shell 隔离，属正常）\n");
        printf("           用 launchctl list | grep proxyshare 确认进程\n");
    }
}

static void PrintHelp(void)
{
    printf("psctl — ProxyShare 管理工具\n\n");
    printf("  psctl status              查看配置与状态\n");
    printf("  psctl set socks <端口>    改 SOCKS5 端口\n");
    printf("  psctl set http  <端口>    改 HTTP 端口\n");
    printf("  psctl set bind  <地址>    改绑定地址\n");
    printf("  psctl restart             重启（应用改动）\n");
    printf("  psctl on | off            启用 / 禁用\n\n");
    printf("例：sudo psctl set socks 47690 && sudo psctl restart\n");
}

int main(int argc, const char *argv[])
{
    @autoreleasepool {
        if (argc < 2) { PrintHelp(); return 0; }

        if (geteuid() != 0) {
            printf("需要 root 权限，请用 sudo 运行\n");
            return 1;
        }

        NSString *cmd = [NSString stringWithUTF8String:argv[1]];

        if ([cmd isEqualToString:@"status"] || [cmd isEqualToString:@"-s"]) {
            PrintStatus();
            return 0;
        }
        if ([cmd isEqualToString:@"help"] || [cmd isEqualToString:@"-h"]) {
            PrintHelp();
            return 0;
        }

        NSMutableDictionary *plist = LoadPlist();
        if (!plist) {
            printf("无法读取 %s\n", PlistPath().UTF8String);
            return 1;
        }
        NSMutableArray *args = plist[@"ProgramArguments"];

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
            printf("%s\n", [cmd isEqualToString:@"on"] ? "已启用" : "已禁用");
            return 0;
        }

        if ([cmd isEqualToString:@"set"] && argc >= 4) {
            NSString *what = [NSString stringWithUTF8String:argv[2]];
            NSString *val  = [NSString stringWithUTF8String:argv[3]];
            NSString *flag = nil;
            if      ([what isEqualToString:@"socks"]) flag = @"--socks";
            else if ([what isEqualToString:@"http"])  flag = @"--http";
            else if ([what isEqualToString:@"bind"])  flag = @"--bind";
            else {
                printf("未知字段: %s（可选 socks / http / bind）\n", argv[2]);
                return 1;
            }
            SetArg(args, flag, val);
            if (!SavePlist(plist)) { printf("写 plist 失败\n"); return 1; }
            printf("已设置 %s = %s\n", flag.UTF8String, val.UTF8String);
            printf("执行 sudo psctl restart 生效\n");
            return 0;
        }

        printf("未知命令: %s\n\n", argv[1]);
        PrintHelp();
        return 1;
    }
}
