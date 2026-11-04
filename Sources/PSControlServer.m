#import "PSCommon.h"
#import "PSControlServer.h"

// RootHide 下 root 守护进程与 mobile（Settings）之间：
//   · 文件系统隔离（/var/tmp 各有一份，/Library 会被重定向到 .jbroot-XXXX）
//   · 网络栈隔离（回环端口互不可见）
// 所以运行期控制通道不可行。配置改由 LaunchDaemon 启动参数传入，
// 由 /usr/bin/psctl 修改并重启服务。这里保留空实现以维持接口。

static PSReloadHandler gReloadHandler = nil;
static PSExitHandler   gExitHandler   = nil;

void PSControlSetReloadHandler(PSReloadHandler handler) { gReloadHandler = [handler copy]; }
void PSControlSetExitHandler(PSExitHandler handler)     { gExitHandler   = [handler copy]; }

@implementation PSControlServer
- (BOOL)startOnPort:(uint16_t)port error:(NSString **)err
{
    (void)port; (void)err;
    PSLog(@"[CTRL] 运行期控制通道已停用（RootHide 隔离），配置请用 psctl");
    return YES;
}
- (void)stop {}
@end
