//
//  PSShareController.m — 设置面板
//
#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import <Preferences/PSTextFieldSpecifier.h>

#define PS_DOMAIN @"com.axs.proxyshare"
#define PS_STATE  @"/Library/ProxyShare/state.plist"

@interface PSShareController : PSListController
@end

@implementation PSShareController

- (NSArray *)specifiers {
    if (!_specifiers) {
        _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    }
    return _specifiers;
}

- (id)readPreferenceValue:(PSSpecifier *)specifier {
    // 共享状态文件优先（守护进程写的那份）
    NSDictionary *st = [NSDictionary dictionaryWithContentsOfFile:PS_STATE];
    NSString *key = specifier.properties[@"key"];
    if (st[key]) return st[key];

    id v = [[NSUserDefaults standardUserDefaults] objectForKey:key];
    return v ?: specifier.properties[@"default"];
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    NSString *key = specifier.properties[@"key"];

    // 写两份：UserDefaults（面板回显）+ 共享状态文件（守护进程读）
    NSMutableDictionary *st = [NSMutableDictionary dictionaryWithContentsOfFile:PS_STATE] ?: [NSMutableDictionary dictionary];
    st[key] = value;
    [st writeToFile:PS_STATE atomically:YES];
    [[NSFileManager defaultManager] setAttributes:@{NSFilePosixPermissions: @0644}
                                     ofItemAtPath:PS_STATE error:NULL];

    [super setPreferenceValue:value specifier:specifier];

    // 立即重启守护进程让新端口生效
    [self reloadDaemon];
}

- (void)reloadDaemon {
    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        system("/bin/launchctl bootout system /Library/LaunchDaemons/com.axs.proxyshare.plist 2>/dev/null");
        usleep(300000);
        system("/bin/launchctl bootstrap system /Library/LaunchDaemons/com.axs.proxyshare.plist 2>/dev/null");
    });
}

// 显示当前运行状态
- (id)statusValue:(PSSpecifier *)specifier {
    NSDictionary *st = [NSDictionary dictionaryWithContentsOfFile:PS_STATE];
    if (![st[@"running"] boolValue]) {
        return st[@"bindError"] ? [NSString stringWithFormat:@"未运行：%@", st[@"bindError"]]
                                : @"未运行";
    }
    return [NSString stringWithFormat:@"运行中 (pid %@)  连接 %@  活跃 %@",
            st[@"pid"] ?: @"?", st[@"connections"] ?: @0, st[@"active"] ?: @0];
}

- (id)trafficValue:(PSSpecifier *)specifier {
    NSDictionary *st = [NSDictionary dictionaryWithContentsOfFile:PS_STATE];
    double up = [st[@"bytesUp"] doubleValue];
    double down = [st[@"bytesDown"] doubleValue];
    return [NSString stringWithFormat:@"↑ %.1f KB   ↓ %.1f KB", up / 1024.0, down / 1024.0];
}

- (id)localIPValue:(PSSpecifier *)specifier {
    // 拿 en0 的 IPv4，给用户直接抄的地址
    NSDictionary *st = [NSDictionary dictionaryWithContentsOfFile:PS_STATE];
    NSString *ip = st[@"localIP"];
    if (ip.length) return ip;
    return @"（见下方说明）";
}

@end
