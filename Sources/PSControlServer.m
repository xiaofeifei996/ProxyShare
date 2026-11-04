#import "PSCommon.h"
#import "PSControlServer.h"

#include <sys/socket.h>
#include <sys/un.h>
#include <sys/select.h>
#include <sys/stat.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <errno.h>
#include <string.h>

static PSReloadHandler gReloadHandler = nil;
static PSExitHandler   gExitHandler   = nil;

void PSControlSetReloadHandler(PSReloadHandler handler) { gReloadHandler = [handler copy]; }
void PSControlSetExitHandler(PSExitHandler handler)     { gExitHandler   = [handler copy]; }

// 读取一行（到 \n 或 EOF），最多 cap 字节
static ssize_t PSReadLine(int fd, char *buf, size_t cap, int timeoutSec)
{
    size_t n = 0;
    while (n < cap - 1) {
        fd_set rs; FD_ZERO(&rs); FD_SET(fd, &rs);
        struct timeval tv = { timeoutSec, 0 };
        int r = select(fd + 1, &rs, NULL, NULL, &tv);
        if (r <= 0) return -1;
        ssize_t got = read(fd, buf + n, 1);
        if (got <= 0) break;
        if (buf[n] == '\n') { buf[n] = 0; return (ssize_t)n; }
        n++;
    }
    buf[n] = 0;
    return (ssize_t)n;
}

static BOOL PSWriteAll(int fd, const char *data, size_t len)
{
    size_t off = 0;
    while (off < len) {
        ssize_t w = write(fd, data + off, len - off);
        if (w <= 0) return NO;
        off += (size_t)w;
    }
    return YES;
}

// 处理一条指令，返回响应字典
static NSDictionary *PSHandleCommand(NSDictionary *req)
{
    NSString *cmd = req[@"cmd"];
    if (![cmd isKindOfClass:[NSString class]])
        return @{ @"ok": @NO, @"error": @"缺少 cmd" };

    PSStats *st = PSSharedStats();

    if ([cmd isEqualToString:@"status"]) {
        NSMutableDictionary *d = [@{
            @"ok"        : @YES,
            @"running"   : @YES,
            @"pid"       : @(getpid()),
            @"socksPort" : @(PSConfigInt(@"socksPort", PS_DEFAULT_SOCKS_PORT)),
            @"httpPort"  : @(PSConfigInt(@"httpPort",  PS_DEFAULT_HTTP_PORT)),
            @"bind"      : PSConfigString(@"bindAddress", PS_DEFAULT_BIND) ?: PS_DEFAULT_BIND,
            @"aclEnabled": @(PSConfigBool(@"aclEnabled", NO)),
            @"aclList"   : PSConfigACLList(),
            @"connections": @(st.acceptedConnections),
            @"active"    : @(st.activeConnections),
            @"rejected"  : @(st.rejectedConnections),
            @"bytesUp"   : @(st.bytesUp),
            @"bytesDown" : @(st.bytesDown),
            @"lastError" : st.lastError ?: @"",
            @"startedAt" : st.startedAt ?: @"",
            @"version"   : @(PSConfigVersion()),
        } mutableCopy];
        return d;
    }

    if ([cmd isEqualToString:@"setConfig"]) {
        NSDictionary *values = req[@"values"];
        if (![values isKindOfClass:[NSDictionary class]])
            return @{ @"ok": @NO, @"error": @"缺少 values" };

        BOOL needReload = NO;
        for (NSString *k in values) {
            id v = values[k];
            if (![k isKindOfClass:[NSString class]]) continue;

            // 端口/绑定地址变化需要重启监听
            if ([k isEqualToString:@"socksPort"] ||
                [k isEqualToString:@"httpPort"]  ||
                [k isEqualToString:@"bindAddress"]) {
                needReload = YES;
            }
            // ACL 相关即时生效，无需重启
            PSConfigSet(k, v);
        }

        BOOL saved = PSConfigSaveToFile();

        if (needReload && gReloadHandler) gReloadHandler();

        return @{ @"ok": @YES, @"saved": @(saved), @"reloaded": @(needReload) };
    }

    if ([cmd isEqualToString:@"resetStats"]) {
        st.acceptedConnections = 0;
        st.bytesUp = 0;
        st.bytesDown = 0;
        st.rejectedConnections = 0;
        return @{ @"ok": @YES };
    }

    if ([cmd isEqualToString:@"reload"]) {
        if (gReloadHandler) gReloadHandler();
        return @{ @"ok": @YES };
    }

    if ([cmd isEqualToString:@"shutdown"]) {
        if (gExitHandler) gExitHandler();
        return @{ @"ok": @YES };
    }

    return @{ @"ok": @NO, @"error": [NSString stringWithFormat:@"未知指令: %@", cmd] };
}

@implementation PSControlServer {
    int _fd;
    BOOL _running;
}

- (instancetype)init
{
    if ((self = [super init])) _fd = -1;
    return self;
}

- (BOOL)startOnPort:(uint16_t)port error:(NSString **)err
{
    if (_running) return YES;
    (void)port;

    mkdir(PS_STATE_DIR_C, 0777);

    // 清理上一次的残留 socket
    unlink(PS_CTRL_SOCKET_PATH);

    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) { if (err) *err = @"socket(AF_UNIX) 失败"; return NO; }

    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));

    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, PS_CTRL_SOCKET_PATH, sizeof(addr.sun_path) - 1);

    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        if (err) *err = [NSString stringWithFormat:@"控制 socket 绑定失败 (%s)",
                         strerror(errno)];
        close(fd);
        return NO;
    }
    // 关键：让 mobile 用户（设置面板）也能连
    chmod(PS_CTRL_SOCKET_PATH, 0666);

    if (listen(fd, 32) < 0) {
        if (err) *err = @"控制 socket listen 失败";
        close(fd);
        return NO;
    }

    _fd = fd;
    _running = YES;

    int lfd = fd;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        while (self->_running && lfd >= 0) {
            int c = accept(lfd, NULL, NULL);
            if (c < 0) {
                if (errno == EINTR) continue;
                if (!self->_running) break;
                usleep(50 * 1000);
                continue;
            }

            int one = 1;
            setsockopt(c, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
            setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));

            char line[8192];
            ssize_t n = PSReadLine(c, line, sizeof(line), 10);
            if (n <= 0) { close(c); continue; }

            @autoreleasepool {
                NSDictionary *resp;
                NSString *errMsg = nil;

                NSData *data = [NSData dataWithBytes:line length:(NSUInteger)n];
                id obj = nil;
                if (data.length) {
                    obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
                }

                if (![obj isKindOfClass:[NSDictionary class]]) {
                    resp = @{ @"ok": @NO, @"error": @"请求不是合法 JSON 对象" };
                } else {
                    @try {
                        resp = PSHandleCommand(obj);
                    } @catch (NSException *e) {
                        errMsg = e.reason ?: @"内部异常";
                        resp = @{ @"ok": @NO, @"error": errMsg };
                    }
                }

                NSData *out = [NSJSONSerialization dataWithJSONObject:resp
                                                              options:0 error:NULL];
                if (out) {
                    PSWriteAll(c, out.bytes, out.length);
                    PSWriteAll(c, "\n", 1);
                }
            }
            close(c);
        }
    });

    PSLog(@"[CTRL] 控制通道已就绪 %s (mode 0666)", PS_CTRL_SOCKET_PATH);
    return YES;
}

- (void)stop
{
    _running = NO;
    if (_fd >= 0) { close(_fd); _fd = -1; }
}

@end
