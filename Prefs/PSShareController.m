//
//  PSShareController.m — 设置面板
//
//  面板运行在 mobile 用户下，不直接读写文件，而是通过
//  127.0.0.1:<ctrlPort> 的 JSON 控制协议与 root 守护进程通信。
//  这样完全绕开 RootHide 的文件视图隔离问题。
//

#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import <UIKit/UIKit.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <ifaddrs.h>
#include <unistd.h>
#include <string.h>

#define PS_CTRL_SOCKET "/var/tmp/ProxyShare/control.sock"
#define PS_PREFS_ID   @"com.axs.proxyshare"

// ---------------------------------------------------------------- 控制通道

static NSDictionary *PSCallControl(NSDictionary *req, NSTimeInterval timeout)
{
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return @{ @"ok": @NO, @"error": @"socket 失败" };

    struct timeval tv = { (time_t)timeout, 0 };
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));

    struct sockaddr_un a;
    memset(&a, 0, sizeof(a));
    a.sun_family = AF_UNIX;
    strncpy(a.sun_path, PS_CTRL_SOCKET, sizeof(a.sun_path) - 1);

    if (connect(fd, (struct sockaddr *)&a, sizeof(a)) < 0) {
        close(fd);
        return @{ @"ok": @NO, @"error": @"无法连接守护进程（可能未运行）" };
    }

    NSData *body = [NSJSONSerialization dataWithJSONObject:req options:0 error:NULL];
    NSMutableData *payload = [body mutableCopy];
    [payload appendBytes:"\n" length:1];

    if (write(fd, payload.bytes, payload.length) != (ssize_t)payload.length) {
        close(fd);
        return @{ @"ok": @NO, @"error": @"发送失败" };
    }

    NSMutableData *resp = [NSMutableData data];
    char buf[4096];
    while (resp.length < 65536) {
        ssize_t n = read(fd, buf, sizeof(buf));
        if (n <= 0) break;
        [resp appendBytes:buf length:(NSUInteger)n];
        if (memchr(buf, '\n', (size_t)n)) break;
    }
    close(fd);

    if (!resp.length) return @{ @"ok": @NO, @"error": @"无响应" };

    id obj = [NSJSONSerialization JSONObjectWithData:resp options:0 error:NULL];
    if (![obj isKindOfClass:[NSDictionary class]])
        return @{ @"ok": @NO, @"error": @"响应格式错误" };
    return obj;
}

// ---------------------------------------------------------------- 面板

@interface PSShareController : PSListController
@property (nonatomic, strong) NSDictionary *status;
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
    [self refreshStatus];
    [self startPolling];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [NSObject cancelPreviousPerformRequestsWithTarget:self];
}

- (void)startPolling {
    [NSObject cancelPreviousPerformRequestsWithTarget:self];
    [self performSelector:@selector(pollTick) withObject:nil afterDelay:3.0];
}

- (void)pollTick {
    if (!self.isViewLoaded || !self.view.window) return;
    [self refreshStatus];
    [self startPolling];
}

- (void)refreshStatus {
    NSDictionary *s = PSCallControl(@{ @"cmd": @"status" }, 2.0);
    self.status = s;

    [self reloadSpecifiers];

    // 顶部状态说明
    NSString *footer;
    if ([s[@"ok"] boolValue]) {
        double up   = [s[@"bytesUp"] doubleValue];
        double down = [s[@"bytesDown"] doubleValue];
        footer = [NSString stringWithFormat:
                  @"运行中 · pid %@\n连接 %@（活跃 %@，拒绝 %@）\n流量 ↑%.1f KB  ↓%.1f KB",
                  s[@"pid"], s[@"connections"], s[@"active"], s[@"rejected"],
                  up / 1024.0, down / 1024.0];
    } else {
        footer = [NSString stringWithFormat:@"未运行：%@\n\n请确认已安装并加载守护进程，或重启设备后重试。",
                  s[@"error"] ?: @"未知"];
    }
    PSSpecifier *sp = [self specifierForID:@"statusGroup"];
    if (sp) [sp setProperty:footer forKey:@"footerText"];
}

// ---------------------------------------------------------------- 取值

- (id)readPreferenceValue:(PSSpecifier *)specifier {
    NSString *key = specifier.properties[@"key"];

    // 优先用控制端口返回的实时值
    if (self.status && self.status[key] && ![self.status[key] isKindOfClass:[NSNull class]])
        return self.status[key];

    id v = [[NSUserDefaults standardUserDefaults] objectForKey:key];
    return v ?: specifier.properties[@"default"];
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    NSString *key = specifier.properties[@"key"];
    if (!key) { [super setPreferenceValue:value specifier:specifier]; return; }

    // 本地存一份让面板回显
    [[NSUserDefaults standardUserDefaults] setObject:value forKey:key];

    NSDictionary *resp = PSCallControl(@{ @"cmd": @"setConfig",
                                          @"values": @{ key: value } }, 3.0);
    if (![resp[@"ok"] boolValue]) {
        UIAlertController *al = [UIAlertController
            alertControllerWithTitle:@"保存失败"
                             message:resp[@"error"] ?: @"守护进程未响应"
                      preferredStyle:UIAlertControllerStyleAlert];
        [al addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault
                                            handler:nil]];
        [self presentViewController:al animated:YES completion:nil];
    }

    [super setPreferenceValue:value specifier:specifier];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [self refreshStatus];
    });
}

// ---------------------------------------------------------------- 状态显示

- (id)statusValue:(PSSpecifier *)specifier {
    NSDictionary *s = self.status;
    if (![s[@"ok"] boolValue]) return s[@"error"] ?: @"未运行";
    return [NSString stringWithFormat:@"运行中（pid %@）", s[@"pid"]];
}

- (id)trafficValue:(PSSpecifier *)specifier {
    NSDictionary *s = self.status;
    if (![s[@"ok"] boolValue]) return @"—";
    double up   = [s[@"bytesUp"] doubleValue];
    double down = [s[@"bytesDown"] doubleValue];
    return [NSString stringWithFormat:@"↑ %.1f KB   ↓ %.1f KB", up/1024.0, down/1024.0];
}

- (id)connValue:(PSSpecifier *)specifier {
    NSDictionary *s = self.status;
    if (![s[@"ok"] boolValue]) return @"—";
    return [NSString stringWithFormat:@"总计 %@ · 活跃 %@ · 拒绝 %@",
            s[@"connections"], s[@"active"], s[@"rejected"]];
}

- (id)localIPValue:(PSSpecifier *)specifier {
    // 取 en0 的 IPv4（面板在 mobile 下，可以正常枚举接口）
    NSString *ip = [self primaryIPv4];
    return ip.length ? ip : @"（未连接 Wi-Fi）";
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

// ---------------------------------------------------------------- 操作按钮

- (void)restartDaemon:(PSSpecifier *)specifier {
    NSDictionary *r = PSCallControl(@{ @"cmd": @"reload" }, 3.0);
    NSString *msg = [r[@"ok"] boolValue] ? @"已重启监听" : (r[@"error"] ?: @"失败");
    [self toast:msg];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ [self refreshStatus]; });
}

- (void)resetStats:(PSSpecifier *)specifier {
    PSCallControl(@{ @"cmd": @"resetStats" }, 2.0);
    [self refreshStatus];
}

- (void)toast:(NSString *)msg {
    UIAlertController *al = [UIAlertController alertControllerWithTitle:nil
                                                               message:msg
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [self presentViewController:al animated:YES completion:^{
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ [al dismissViewControllerAnimated:YES completion:nil]; });
    }];
}

@end
