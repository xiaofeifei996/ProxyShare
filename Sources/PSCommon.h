//
//  PSCommon.h
//  ProxyShare — 把本机的代理隧道共享给同一局域网内的其它设备
//
//  设计要点：
//  1. 这是一个**独立守护进程**（launchd 拉起），不是注入进某进程的 tweak。
//     因为 iOS 的全局代理（Shadowrocket/Clash 等）建立的是 utun 隧道 + 默认路由，
//     对设备上所有进程生效，包括 root 守护进程。因此本进程的 outbound connect()
//     会自动走隧道，无需任何 hook、无需代理软件开端口。
//  2. 本进程只负责：监听局域网端口 -> 解析 SOCKS5 / HTTP CONNECT -> connect 目标 -> 双向转发。
//  3. 配置(config.plist) 与 运行状态(state.plist) **分两个文件**，互不覆盖。
//

#ifndef PS_COMMON_H
#define PS_COMMON_H

#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>

// 共享目录（root 可写，mobile 可读）
// RootHide 下 root 守护进程默认受 iOS 沙盒限制，/Library 不可写；
// 必须给 psd 签名 entitlements(psd.entitlements) 解除沙盒，
// 之后 /var/tmp、/var/root、/private/var/mobile 均可写。这里选 /var/tmp（两用户都可访问）。
#define PS_STATE_DIR        @"/var/tmp/ProxyShare"
#define PS_CONFIG_FILE      @"/var/tmp/ProxyShare/config.plist"
#define PS_STATE_FILE       @"/var/tmp/ProxyShare/state.plist"
#define PS_LOG_FILE         @"/var/tmp/ProxyShare/proxy.log"
#define PS_PREFS_DOMAIN     @"com.axs.proxyshare"

// 同上路径的 C 字符串形式（供 mkdir/fopen 使用）
#define PS_STATE_DIR_C      "/var/tmp/ProxyShare"
#define PS_LOG_FILE_C       "/var/tmp/ProxyShare/proxy.log"
#define PS_CONFIG_FILE_C    "/var/tmp/ProxyShare/config.plist"
#define PS_STATE_FILE_C     "/var/tmp/ProxyShare/state.plist"

// 默认值（避开 1080/1086/8118 等代理软件常用端口）
#define PS_DEFAULT_SOCKS_PORT   47680
#define PS_DEFAULT_HTTP_PORT    47681
#define PS_DEFAULT_BIND         @"0.0.0.0"

// 日志上限（行）
#define PS_LOG_MAX_LINES        600

// 配置读取（每次读盘，避免 launchd 进程缓存旧值）
BOOL        PSConfigBool(NSString *key, BOOL def);
NSInteger   PSConfigInt(NSString *key, NSInteger def);
NSString   *PSConfigString(NSString *key, NSString *def);

// 运行状态（守护进程写，面板读）
NSDictionary *PSReadState(void);
void         PSWriteState(NSDictionary *state);

// 日志（同时写文件与 stderr）
void PSLog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);

// 统计
@interface PSStats : NSObject
@property (atomic, assign) uint64_t acceptedConnections;
@property (atomic, assign) uint64_t activeConnections;
@property (atomic, assign) uint64_t bytesUp;
@property (atomic, assign) uint64_t bytesDown;
@property (atomic, assign) uint64_t rejectedConnections;
@property (atomic, copy)   NSString *lastError;
@property (atomic, copy)   NSString *startedAt;
@end

PSStats *PSSharedStats(void);

#endif /* PS_COMMON_H */
