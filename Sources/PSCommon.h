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
//  4. 运行期配置以内存为准，由控制端口(127.0.0.1)下发——避开 RootHide 的文件视图隔离。
//

#ifndef PS_COMMON_H
#define PS_COMMON_H

#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>

// 共享目录（root 可写，mobile 可读）
// 注意：RootHide 下 root 进程与 mobile 看到的 /var/tmp 是**不同目录**
// （root 侧被重定向到 .jbroot-XXXX/var/tmp），因此这里的文件
// 只对 psd 自己有意义：用于持久化配置、写运行状态、记日志。
// 与控制面板的通信不依赖文件系统（见 psctl）。
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
#define PS_DEFAULT_CTRL_PORT    47682
#define PS_DEFAULT_BIND         @"0.0.0.0"

// 日志上限
#define PS_LOG_MAX_LINES        600

// ---------------------------------------------------------------- 配置

// 读取（内存优先，未命中再回落到文件/cfprefs）
BOOL        PSConfigBool(NSString *key, BOOL def);
NSInteger   PSConfigInt(NSString *key, NSInteger def);
NSString   *PSConfigString(NSString *key, NSString *def);

// 写入内存（线程安全），并使 gConfigVersion 递增
void        PSConfigSet(NSString *key, id value);

// 从磁盘载入初始配置（守护进程启动时调用一次）
void        PSConfigLoadFromFile(void);

// 持久化到磁盘（尽力而为，失败不报错）
BOOL        PSConfigSaveToFile(void);

// 配置版本号：每次 set 递增，定时器靠它判断是否需要重启监听
int         PSConfigVersion(void);

// ACL 列表（逗号分隔字符串 <-> 数组）
NSArray<NSString *> *PSConfigACLList(void);
void                 PSConfigSetACLList(NSArray<NSString *> *list);

// ---------------------------------------------------------------- ACL

// 判断来源 IP 是否允许连接（未启用 ACL 时恒为 YES）
BOOL PSACLAllowsPeer(const char *ipStr);

// 校验单条规则（供面板/控制端口验证）
BOOL PSACLValidRule(NSString *rule);

// ---------------------------------------------------------------- Socket 路径

// RootHide 下 root 与 mobile 的网络栈是隔离的（回环端口互相看不见），
// 但文件系统是共享的，因此控制通道改用 Unix domain socket，放在两用户都可达的 /var/tmp。
#define PS_CTRL_SOCKET_PATH "/var/tmp/ProxyShare/control.sock"

// ---------------------------------------------------------------- 状态

NSDictionary *PSReadState(void);
void         PSWriteState(NSDictionary *state);

// ---------------------------------------------------------------- 日志

void PSLog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);

// ---------------------------------------------------------------- 统计

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
