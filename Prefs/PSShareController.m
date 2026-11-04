//
//  PSShareController.m — 设置面板
//
//  开关/端口等配置写入 NSUserDefaults（com.axs.proxyshare），
//  psd 每 2 秒从 AppGroup 真实路径读取，实现实时生效。
//

#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import <UIKit/UIKit.h>

#include <ifaddrs.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <string.h>
#include <sys/stat.h>

static NSString *const kPrefsDomain = @"com.axs.proxyshare";
static NSString *const kPlistPath   = @"/Library/LaunchDaemons/com.axs.proxyshare.plist";

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

- (void)fixPrefsPermissions {
    NSString *base = @"/private/var/mobile/Containers/Shared/AppGroup";
    NSArray *dirs = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:base error:NULL];
    for (NSString *d in dirs) {
        if (![d hasPrefix:@".jbroot-"]) continue;
        NSString *p = [NSString stringWithFormat:
            @"%@/%@/var/mobile/Library/Preferences/com.axs.proxyshare.plist", base, d];
        if ([[NSFileManager defaultManager] fileExistsAtPath:p]) {
            chmod(p.fileSystemRepresentation, 0644);
        }
    }
    // 常规路径也处理一下
    NSString *p2 = @"/var/mobile/Library/Preferences/com.axs.proxyshare.plist";
    if ([[NSFileManager defaultManager] fileExistsAtPath:p2]) {
        chmod(p2.fileSystemRepresentation, 0644);
    }
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reloadConfig];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    // 定时刷新运行状态
    [NSObject cancelPreviousPerformRequestsWithTarget:self];
    [self performSelector:@selector(pollTick) withObject:nil afterDelay:3.0];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [NSObject cancelPreviousPerformRequestsWithTarget:self];
}

- (void)pollTick {
    if (!self.isViewLoaded || !self.view.window) return;
    self.cfg[@"proc"] = [self portListening] ? @"运行中" : @"已停止";
    [self reloadSpecifiers];
    [self performSelector:@selector(pollTick) withObject:nil afterDelay:3.0];
}

- (void)reloadConfig {
    NSMutableDictionary *m = [NSMutableDictionary dictionary];
    m[@"ip"] = [self primaryIPv4] ?: @"（未连接 Wi-Fi）";

    // 端口：优先看 LaunchDaemon 参数，其次 UserDefaults
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:kPlistPath];
    NSArray *args = d[@"ProgramArguments"];

    NSString *socks = [self valueAfterFlag:@"--socks" in:args];
    NSString *http  = [self valueAfterFlag:@"--http"  in:args];

    NSUserDefaults *ud = [[NSUserDefaults alloc] initWithSuiteName:kPrefsDomain];
    if (!socks) socks = [ud objectForKey:@"socksPort"] ? [[ud objectForKey:@"socksPort"] stringValue] : @"47680";
    if (!http)  http  = [ud objectForKey:@"httpPort"]  ? [[ud objectForKey:@"httpPort"]  stringValue] : @"47681";

    m[@"socks"] = socks;
    m[@"http"]  = http;

    self.cfg = m;
    m[@"proc"] = [self portListening] ? @"运行中" : @"已停止";

    [self reloadSpecifiers];
}

- (NSString *)valueAfterFlag:(NSString *)flag in:(NSArray *)args {
    if (![args isKindOfClass:[NSArray class]]) return nil;
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

// 探测端口判断服务是否在跑
- (BOOL)portListening {
    int port = [self.cfg[@"socks"] intValue];
    if (port <= 0) port = 47680;

    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return NO;
    struct timeval tv = { 1, 0 };
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));

    struct sockaddr_in a;
    memset(&a, 0, sizeof(a));
    a.sin_family = AF_INET;
    a.sin_port = htons((uint16_t)port);
    a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);

    BOOL ok = (connect(fd, (struct sockaddr *)&a, sizeof(a)) == 0);
    close(fd);
    return ok;
}

// ---------------------------------------------------------------- 展示

- (id)statusValue:(PSSpecifier *)sp   { return self.cfg[@"proc"] ?: @"—"; }
- (id)ipValue:(PSSpecifier *)sp       { return self.cfg[@"ip"] ?: @"—"; }

- (id)socksAddr:(PSSpecifier *)sp {
    return [NSString stringWithFormat:@"%@:%@", self.cfg[@"ip"] ?: @"?", self.cfg[@"socks"] ?: @"?"];
}
- (id)httpAddr:(PSSpecifier *)sp {
    return [NSString stringWithFormat:@"%@:%@", self.cfg[@"ip"] ?: @"?", self.cfg[@"http"] ?: @"?"];
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

// ---------------------------------------------------------------- 开关与端口

- (id)readPreferenceValue:(PSSpecifier *)specifier {
    NSString *key = specifier.properties[@"key"];
    NSUserDefaults *ud = [[NSUserDefaults alloc] initWithSuiteName:kPrefsDomain];
    id v = [ud objectForKey:key];
    if (v) return v;
    return specifier.properties[@"default"];
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    NSString *key = specifier.properties[@"key"];
    NSUserDefaults *ud = [[NSUserDefaults alloc] initWithSuiteName:kPrefsDomain];
    [ud setObject:value forKey:key];
    [ud synchronize];

    // 关键：NSUserDefaults 写的文件权限是 0600（只有 mobile 能读），
    // 而 psd 以 root 运行且受沙盒限制，读不到 → 放开成 0644。
    // synchronize 之后文件可能仍在异步落盘，所以延时多点补几次。
    [self fixPrefsPermissions];
    for (int i = 1; i <= 4; i++) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     (int64_t)(i * 0.25 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [self fixPrefsPermissions];
        });
    }

    [super setPreferenceValue:value specifier:specifier];

    // 改了端口就更新显示
    if ([key isEqualToString:@"socksPort"] || [key isEqualToString:@"httpPort"]) {
        NSString *s = [[ud objectForKey:@"socksPort"] description] ?: @"47680";
        NSString *h = [[ud objectForKey:@"httpPort"]  description] ?: @"47681";
        self.cfg[@"socks"] = s;
        self.cfg[@"http"]  = h;
    }

    // 稍等让守护进程读到新配置
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        self.cfg[@"proc"] = [self portListening] ? @"运行中" : @"已停止";
        [self reloadSpecifiers];
    });
}

@end
