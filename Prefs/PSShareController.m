//
//  PSShareController.m — 设置面板（只读展示）
//
//  面板只能展示配置，不能修改：RootHide 下 root 守护进程与 Settings
//  的文件系统、网络栈都隔离（详见 README）。改配置用 sudo psctl。
//

#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import <UIKit/UIKit.h>

#include <ifaddrs.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <string.h>
#include <dlfcn.h>

static NSString *const kPlistPath     = @"/Library/LaunchDaemons/com.axs.proxyshare.plist";
static NSString *const kPlistPathAlt  = @"/var/jb/Library/LaunchDaemons/com.axs.proxyshare.plist";

@interface PSShareController : PSListController
@property (nonatomic, strong) NSMutableDictionary *cfg;
@end

@implementation PSShareController

- (NSArray *)specifiers {
    if (!_specifiers) {
        _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    }
    return _specifiers;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reloadConfig];
}

- (void)reloadConfig {
    NSMutableDictionary *m = [NSMutableDictionary dictionary];
    m[@"ip"] = [self primaryIPv4] ?: @"（未连接 Wi-Fi）";

    // 逐个候选路径尝试
    NSMutableArray *tried = [NSMutableArray array];
    NSArray *paths = [self candidatePlistPaths];

    for (NSString *p in paths) {
        NSError *err = nil;
        NSData *data = [NSData dataWithContentsOfFile:p
                                              options:0
                                                error:&err];
        [tried addObject:[NSString stringWithFormat:@"%@:%@", p,
                          data ? [NSString stringWithFormat:@"%luB", (unsigned long)data.length]
                               : (err.localizedDescription ?: @"nil")]];
        if (!data.length) continue;

        id obj = [NSPropertyListSerialization propertyListWithData:data
                                                           options:0
                                                            format:NULL
                                                             error:&err];
        if (![obj isKindOfClass:[NSDictionary class]]) {
            [tried addObject:@"  解析失败"];
            continue;
        }
        NSArray *args = obj[@"ProgramArguments"];
        if (![args isKindOfClass:[NSArray class]]) continue;

        m[@"socks"] = [self valueAfterFlag:@"--socks" in:args] ?: @"47680";
        m[@"http"]  = [self valueAfterFlag:@"--http"  in:args] ?: @"47681";
        m[@"bind"]  = [self valueAfterFlag:@"--bind"  in:args] ?: @"0.0.0.0";
        m[@"acl"]   = [self valueAfterFlag:@"--acl"   in:args] ?: @"未启用";
        m[@"enabled"] = [args containsObject:@"--off"] ? @"已禁用" : @"已启用";
        m[@"source"]  = p;
        break;
    }

    if (!m[@"socks"]) {
        m[@"error"] = [tried componentsJoinedByString:@"\n"];
    }

    // 进程状态：直接看 launchctl 结果（mobile 可执行）
    m[@"proc"] = [self daemonRunning] ? @"运行中" : @"未运行";

    self.cfg = m;
    [self reloadSpecifiers];
}

- (NSArray *)candidatePlistPaths {
    NSMutableArray *arr = [NSMutableArray array];
    [arr addObject:kPlistPath];

    // RootHide: 从 .jbroot-XXXX 目录里找
    NSString *apps = @"/var/containers/Bundle/Application";
    NSArray *dirs = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:apps error:NULL];
    for (NSString *d in dirs) {
        if (![d hasPrefix:@".jbroot-"]) continue;
        [arr addObject:[NSString stringWithFormat:
            @"%@/%@/Library/LaunchDaemons/com.axs.proxyshare.plist", apps, d]];
    }
    [arr addObject:kPlistPathAlt];
    return arr;
}

- (BOOL)daemonRunning {
    // 用 launchctl list 判断（mobile 有权限执行）
    FILE *fp = popen("/bin/launchctl list 2>/dev/null | /usr/bin/grep -c proxyshare", "r");
    if (!fp) return NO;
    char buf[32] = {0};
    BOOL found = NO;
    if (fgets(buf, sizeof(buf), fp)) found = (atoi(buf) > 0);
    pclose(fp);
    return found;
}

- (NSString *)valueAfterFlag:(NSString *)flag in:(NSArray *)args {
    NSUInteger i = [args indexOfObject:flag];
    if (i == NSNotFound || i + 1 >= args.count) return nil;
    return args[i + 1];
}

- (NSString *)primaryIPv4 {
    struct ifaddrs *list = NULL;
    if (getifaddrs(&list) != 0) return nil;
    NSString *found = nil;
    for (struct ifaddrs *p = list; p; p = p->ifa_next) {
        if (!p->ifa_addr || p->ifa_addr->sa_family != AF_INET) continue;
        if (strcmp(p->ifa_name, "en0") != 0) continue;
        char buf[INET_ADDRSTRLEN] = {0};
        struct sockaddr_in *sin = (struct sockaddr_in *)p->ifa_addr;
        inet_ntop(AF_INET, &sin->sin_addr, buf, sizeof(buf));
        if (buf[0]) { found = @(buf); break; }
    }
    freeifaddrs(list);
    return found;
}

// ---------------------------------------------------------------- 展示

- (id)enabledValue:(PSSpecifier *)sp  { return self.cfg[@"enabled"] ?: @"—"; }
- (id)ipValue:(PSSpecifier *)sp       { return self.cfg[@"ip"] ?: @"—"; }
- (id)socksValue:(PSSpecifier *)sp    { return self.cfg[@"socks"] ?: @"—"; }
- (id)httpValue:(PSSpecifier *)sp     { return self.cfg[@"http"] ?: @"—"; }
- (id)bindValue:(PSSpecifier *)sp     { return self.cfg[@"bind"] ?: @"—"; }
- (id)statusValue:(PSSpecifier *)sp   { return self.cfg[@"proc"] ?: @"—"; }

- (NSString *)statusFooter {
    if (self.cfg[@"error"]) {
        return [NSString stringWithFormat:@"读取配置失败：\n%@", self.cfg[@"error"]];
    }
    return [NSString stringWithFormat:@"配置来源：%@", self.cfg[@"source"] ?: @"—"];
}

- (id)socksAddr:(PSSpecifier *)sp {
    return [NSString stringWithFormat:@"%@:%@",
            self.cfg[@"ip"] ?: @"?", self.cfg[@"socks"] ?: @"?"];
}
- (id)httpAddr:(PSSpecifier *)sp {
    return [NSString stringWithFormat:@"%@:%@",
            self.cfg[@"ip"] ?: @"?", self.cfg[@"http"] ?: @"?"];
}

- (void)copySocks:(PSSpecifier *)sp { [self copy:[self socksAddr:sp]]; }
- (void)copyHTTP:(PSSpecifier *)sp  { [self copy:[self httpAddr:sp]]; }

- (void)copy:(NSString *)text {
    [UIPasteboard generalPasteboard].string = text;
    UIAlertController *al = [UIAlertController
        alertControllerWithTitle:nil
                         message:[NSString stringWithFormat:@"已复制 %@", text]
                  preferredStyle:UIAlertControllerStyleAlert];
    [self presentViewController:al animated:YES completion:^{
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [al dismissViewControllerAnimated:YES completion:nil];
        });
    }];
}

@end
