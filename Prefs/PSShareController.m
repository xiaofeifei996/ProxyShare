//
//  PSShareController.m — 设置面板（只读展示）
//
//  背景：RootHide 下 root 守护进程与 Settings（mobile）的文件系统、网络栈
//  都是隔离的（/var/tmp 在两边是不同目录；回环端口互不可见），
//  面板无法把配置可靠地传给守护进程。
//
//  因此面板只做三件事：
//    1. 展示当前配置（读 LaunchDaemon plist，两用户都可读）
//    2. 展示本机可用的代理地址，方便复制
//    3. 给出改配置的正确命令（psctl）
//

#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import <UIKit/UIKit.h>

#include <ifaddrs.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <string.h>

#define DAEMON_PLIST @"/Library/LaunchDaemons/com.axs.proxyshare.plist"

@interface PSShareController : PSListController
@property (nonatomic, strong) NSDictionary *cfg;
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
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:DAEMON_PLIST];
    NSArray *args = d[@"ProgramArguments"];
    NSMutableDictionary *m = [NSMutableDictionary dictionary];

    if ([args isKindOfClass:[NSArray class]]) {
        m[@"socks"] = [self valueAfterFlag:@"--socks" in:args] ?: @"47680";
        m[@"http"]  = [self valueAfterFlag:@"--http"  in:args] ?: @"47681";
        m[@"bind"]  = [self valueAfterFlag:@"--bind"  in:args] ?: @"0.0.0.0";
        m[@"enabled"] = [args containsObject:@"--off"] ? @"否" : @"是";
    } else {
        m[@"error"] = @"未找到守护进程配置";
    }
    m[@"ip"] = [self primaryIPv4] ?: @"（未连接 Wi-Fi）";

    self.cfg = m;
    [self reloadSpecifiers];
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

// ---------------------------------------------------------------- 展示项

- (id)enabledValue:(PSSpecifier *)sp   { return self.cfg[@"enabled"] ?: @"—"; }
- (id)ipValue:(PSSpecifier *)sp        { return self.cfg[@"ip"] ?: @"—"; }
- (id)socksValue:(PSSpecifier *)sp     { return self.cfg[@"socks"] ?: @"—"; }
- (id)httpValue:(PSSpecifier *)sp      { return self.cfg[@"http"] ?: @"—"; }
- (id)bindValue:(PSSpecifier *)sp      { return self.cfg[@"bind"] ?: @"—"; }

- (id)socksAddr:(PSSpecifier *)sp {
    return [NSString stringWithFormat:@"%@:%@", self.cfg[@"ip"] ?: @"?", self.cfg[@"socks"] ?: @"?"];
}
- (id)httpAddr:(PSSpecifier *)sp {
    return [NSString stringWithFormat:@"%@:%@", self.cfg[@"ip"] ?: @"?", self.cfg[@"http"] ?: @"?"];
}

// 点一下复制
- (void)copySocks:(PSSpecifier *)sp {
    [self copy:[self socksAddr:sp]];
}
- (void)copyHTTP:(PSSpecifier *)sp {
    [self copy:[self httpAddr:sp]];
}

- (void)copy:(NSString *)text {
    [UIPasteboard generalPasteboard].string = text;
    UIAlertController *al = [UIAlertController alertControllerWithTitle:nil
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
