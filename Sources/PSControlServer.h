//
//  PSControlServer.h — 本地控制端口
//
//  设置面板（mobile 用户）通过 127.0.0.1:<ctrlPort> 向 root 守护进程下发指令。
//  这样完全绕开 RootHide 的文件视图隔离：两者不共享文件系统，但共享网络栈。
//
//  协议：一行 JSON 请求，一行 JSON 响应。
//    请求  {"cmd":"status"}
//    响应  {"ok":true,"running":true,"socksPort":47680,...}
//

#ifndef PS_CONTROL_SERVER_H
#define PS_CONTROL_SERVER_H

#import <Foundation/Foundation.h>

@interface PSControlServer : NSObject
- (BOOL)startOnPort:(uint16_t)port error:(NSString **)err;
- (void)stop;
@end

// 供守护进程注册「重启监听」回调
typedef void (^PSReloadHandler)(void);
void PSControlSetReloadHandler(PSReloadHandler handler);

// 供守护进程注册「退出」回调
typedef void (^PSExitHandler)(void);
void PSControlSetExitHandler(PSExitHandler handler);

#endif
