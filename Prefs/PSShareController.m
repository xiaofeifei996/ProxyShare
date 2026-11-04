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
#include <netinet/in.h>
#include <arpa/inet.h>
#include <ifaddrs.h>
#include <unistd.h>
#include <string.h>

#define PS_CTRL_SOCKET "/Library/ProxyShare/control.sock"
#define PS_PREFS_ID   @"com.axs.proxyshare"

// ---------------------------------------------------------------- 控制通道

static NSInteger gCmdSeq = 0;

// 通过文件与守护进程通信：
//   写 command.plist {"id":N,...} → 等 response.plist 里 id==N
static NSDictionary *PSCallControl(NSDictionary *req, NSTimeInterval timeout)
{
    NSString *cmdPath  = @"/Library/ProxyShare/command.plist";
    NSString *respPath = @"/Library/ProxyShare/response.plist";

    // 目录可能还没建（守护进程未运行过）
    [[NSFileManager defaultManager] createDirectoryAtPath:@"/Library/ProxyShare"
                              withIntermediateDirectories:YES attributes:nil error:NULL];

    // 用时间戳做序号，避免与上一次冲突
    NSInteger myID = (NSInteger)([[NSDate date] timeIntervalSince1970] * 1000) + (gCmdSeq++ % 1000);

    NSMutableDictionary *payload = [req mutableCopy];
    payload[@"id"] = @(myID);

    NSError *werr = nil;
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:payload
                                                              format:NSPropertyListXMLFormat_v1_0
                                                             options:0
                                                               error:&werr];
    if (!data || ![data writeToFile:cmdPath atomically:YES]) {
        return @{ @"ok": @NO, @"error": @"无法写入命令文件（权限不足？）" };
    }
    chmod(cmdPath.fileSystemRepresentation, 0666);

    // 轮询等响应
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while ([deadline timeIntervalSinceNow] > 0) {
        NSDictionary *resp = [NSDictionary dictionaryWithContentsOfFile:respPath];
        if ([resp isKindOfClass:[NSDictionary class]] &&
            [resp[@"id"] integerValue] == myID) {
            return resp;
        }
        usleep(120 * 1000);   // 120ms
    }

    // 超时：退一步，看看能不能直接读 state.plist 兜底
    NSDictionary *st = [NSDictionary dictionaryWithContentsOfFile:@"/Library/ProxyShare/state.plist"];
    if ([st isKindOfClass:[NSDictionary class]] && st[@"pid"]) {
        NSMutableDictionary *d = [st mutableCopy];
        d[@"ok"] = @YES;
        return d;
    }
    return @{ @"ok": @NO, @"error": @"守护进程未响应（可能未运行）" };
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
    NSDictionary *s = PSCallControl(@{ @"cmd": @"status" }, 4.0);
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
                                          @"values": @{ key: value } }, 6.0);
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
    PSCallControl(@{ @"cmd": @"resetStats" }, 3.0);
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
