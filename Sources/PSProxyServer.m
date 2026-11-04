//
//  PSProxyServer.m — SOCKS5 + HTTP CONNECT 双协议代理服务器
//
//  监听局域网端口，把客户端请求转成对目标主机的直连。
//  因为本机开着全局 VPN（utun + 默认路由），这里的 connect() 会自然走隧道，
//  所以「共享出去」= 别的设备用本机作为跳板，出口就是本机代理的出口。
//

#import "PSCommon.h"
#import "PSProxyServer.h"

#include <sys/socket.h>
#include <sys/select.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <arpa/inet.h>
#include <netdb.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <string.h>
#include <strings.h>

static const int kConnectTimeoutSec = 20;
static const int kIdleTimeoutSec    = 600;
static const size_t kBufSize        = 32768;

#pragma mark - 小工具

static BOOL PSSetNonBlocking(int fd, BOOL nb)
{
    int flags = fcntl(fd, F_GETFL, 0);
    if (flags < 0) return NO;
    flags = nb ? (flags | O_NONBLOCK) : (flags & ~O_NONBLOCK);
    return fcntl(fd, F_SETFL, flags) == 0;
}

static void PSCloseFD(int *fd)
{
    if (*fd >= 0) { close(*fd); *fd = -1; }
}

// 带超时的 read，返回读到的字节数，<0 表示出错/超时
static ssize_t PSReadFull(int fd, void *buf, size_t want, int timeoutSec)
{
    size_t got = 0;
    while (got < want) {
        fd_set rs; FD_ZERO(&rs); FD_SET(fd, &rs);
        struct timeval tv = { timeoutSec, 0 };
        int r = select(fd + 1, &rs, NULL, NULL, &tv);
        if (r <= 0) return -1;
        ssize_t n = read(fd, (char *)buf + got, want - got);
        if (n <= 0) return (n == 0) ? (ssize_t)got : -1;
        got += (size_t)n;
    }
    return (ssize_t)got;
}

// 非阻塞 connect + 超时（走系统路由，因而走 VPN 隧道）
static int PSConnectWithTimeout(const char *host, uint16_t port, int timeoutSec)
{
    struct addrinfo hints, *res = NULL;
    memset(&hints, 0, sizeof(hints));
    hints.ai_family   = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;

    char portstr[8];
    snprintf(portstr, sizeof(portstr), "%u", (unsigned)port);

    int gai = getaddrinfo(host, portstr, &hints, &res);
    if (gai != 0 || !res) {
        PSSharedStats().lastError =
            [NSString stringWithFormat:@"DNS 失败 %s: %s", host, gai_strerror(gai)];
        return -1;
    }

    int fd = -1;
    for (struct addrinfo *ai = res; ai; ai = ai->ai_next) {
        fd = socket(ai->ai_family, ai->ai_socktype, ai->ai_protocol);
        if (fd < 0) continue;

        PSSetNonBlocking(fd, YES);
        int r = connect(fd, ai->ai_addr, ai->ai_addrlen);
        if (r == 0) { PSSetNonBlocking(fd, NO); break; }

        if (errno == EINPROGRESS) {
            fd_set ws; FD_ZERO(&ws); FD_SET(fd, &ws);
            struct timeval tv = { timeoutSec, 0 };
            r = select(fd + 1, NULL, &ws, NULL, &tv);
            if (r > 0) {
                int err = 0; socklen_t len = sizeof(err);
                if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len) == 0 && err == 0) {
                    PSSetNonBlocking(fd, NO);
                    break;   // 成功
                }
            }
        }
        close(fd);
        fd = -1;
    }

    freeaddrinfo(res);
    if (fd < 0)
        PSSharedStats().lastError = [NSString stringWithFormat:@"连接失败 %s:%u", host, port];

    int one = 1;
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
    return fd;
}

#pragma mark - 双向转发

static void PSPump(int a, int b)
{
    char *buf = malloc(kBufSize);
    if (!buf) return;

    BOOL aOpen = YES, bOpen = YES;
    time_t lastActive = time(NULL);

    while (aOpen || bOpen) {
        if (time(NULL) - lastActive > kIdleTimeoutSec) break;

        fd_set rs; FD_ZERO(&rs);
        int maxfd = -1;
        if (aOpen) { FD_SET(a, &rs); maxfd = MAX(maxfd, a); }
        if (bOpen) { FD_SET(b, &rs); maxfd = MAX(maxfd, b); }

        struct timeval tv = { 5, 0 };
        int r = select(maxfd + 1, &rs, NULL, NULL, &tv);
        if (r < 0) break;
        if (r == 0) continue;

        if (aOpen && FD_ISSET(a, &rs)) {
            ssize_t n = read(a, buf, kBufSize);
            if (n <= 0) { aOpen = NO; if (bOpen) shutdown(b, SHUT_WR); }
            else {
                ssize_t sent = 0;
                while (sent < n) {
                    ssize_t w = write(b, buf + sent, (size_t)(n - sent));
                    if (w <= 0) { bOpen = NO; break; }
                    sent += w;
                }
                PSSharedStats().bytesUp += (uint64_t)n;
                lastActive = time(NULL);
                if (!bOpen) aOpen = NO;
            }
        }
        if (bOpen && FD_ISSET(b, &rs)) {
            ssize_t n = read(b, buf, kBufSize);
            if (n <= 0) { bOpen = NO; if (aOpen) shutdown(a, SHUT_WR); }
            else {
                ssize_t sent = 0;
                while (sent < n) {
                    ssize_t w = write(a, buf + sent, (size_t)(n - sent));
                    if (w <= 0) { aOpen = NO; break; }
                    sent += w;
                }
                PSSharedStats().bytesDown += (uint64_t)n;
                lastActive = time(NULL);
                if (!aOpen) bOpen = NO;
            }
        }
    }
    free(buf);
}

#pragma mark - SOCKS5

static void PSServeSOCKS5(int client)
{
    unsigned char buf[512];

    // --- 握手 ---
    if (PSReadFull(client, buf, 2, 10) != 2 || buf[0] != 0x05) return;
    int nMethods = buf[1];
    if (nMethods <= 0 || PSReadFull(client, buf, (size_t)nMethods, 10) != nMethods) return;

    // 只用「无认证」，且强制局域网限制在服务层用配置控制
    unsigned char authReply[2] = { 0x05, 0x00 };
    if (write(client, authReply, 2) != 2) return;

    // --- 请求 ---
    if (PSReadFull(client, buf, 4, 10) != 4 || buf[0] != 0x05) return;
    if (buf[1] != 0x01) {                        // 只支持 CONNECT
        unsigned char rep[2] = { 0x05, 0x07 };
        write(client, rep, 2);
        return;
    }

    char host[256] = {0};
    uint16_t port = 0;

    switch (buf[3]) {
        case 0x01: {   // IPv4
            unsigned char a[4];
            if (PSReadFull(client, a, 4, 10) != 4) return;
            snprintf(host, sizeof(host), "%u.%u.%u.%u", a[0], a[1], a[2], a[3]);
            break;
        }
        case 0x03: {   // 域名
            unsigned char len;
            if (PSReadFull(client, &len, 1, 10) != 1 || len == 0) return;
            if (PSReadFull(client, host, len, 10) != (ssize_t)len) return;
            host[len] = 0;
            break;
        }
        case 0x04: {   // IPv6
            unsigned char a[16];
            if (PSReadFull(client, a, 16, 10) != 16) return;
            inet_ntop(AF_INET6, a, host, sizeof(host));
            break;
        }
        default: {
            unsigned char rep[2] = { 0x05, 0x08 };
            write(client, rep, 2);
            return;
        }
    }

    unsigned char pb[2];
    if (PSReadFull(client, pb, 2, 10) != 2) return;
    port = (uint16_t)((pb[0] << 8) | pb[1]);

    int remote = PSConnectWithTimeout(host, port, kConnectTimeoutSec);
    if (remote < 0) {
        unsigned char rep[10] = { 0x05, 0x05, 0x00, 0x01, 0,0,0,0, 0,0 };
        write(client, rep, 10);
        PSLog(@"[SOCKS5] 失败 %s:%u", host, port);
        return;
    }

    unsigned char ok[10] = { 0x05, 0x00, 0x00, 0x01, 0,0,0,0, 0,0 };
    if (write(client, ok, 10) != 10) { close(remote); return; }

    PSLog(@"[SOCKS5] %s:%u 已连通", host, port);
    PSPump(client, remote);
    close(remote);
}

#pragma mark - HTTP 代理

// 解析 "CONNECT host:port HTTP/1.1" 或 "GET http://host/path HTTP/1.1"
static BOOL PSParseHTTPHeader(const char *hdr, char *hostOut, size_t hostLen,
                              uint16_t *portOut, BOOL *isConnect,
                              char *rewritten, size_t rewLen)
{
    const char *lineEnd = strstr(hdr, "\r\n");
    if (!lineEnd) return NO;

    char method[16] = {0}, target[1024] = {0}, version[16] = {0};
    int n = sscanf(hdr, "%15s %1023s %15s", method, target, version);
    if (n < 2) return NO;

    *isConnect = (strcasecmp(method, "CONNECT") == 0);

    const char *hostStart = NULL;
    if (*isConnect) {
        hostStart = target;
    } else {
        // http://host:port/path  ->  去掉 scheme
        const char *p = strstr(target, "://");
        if (!p) return NO;
        hostStart = p + 3;
    }

    // 取 host 部分（到 : 或 / 为止）
    size_t i = 0;
    while (hostStart[i] && hostStart[i] != ':' && hostStart[i] != '/' &&
           i < hostLen - 1) {
        hostOut[i] = hostStart[i];
        i++;
    }
    hostOut[i] = 0;
    if (i == 0) return NO;

    // 端口
    uint16_t port = *isConnect ? 0 : 80;
    if (hostStart[i] == ':') {
        port = (uint16_t)atoi(hostStart + i + 1);
    }
    if (port == 0) port = (*isConnect) ? 443 : 80;
    *portOut = port;

    // 非 CONNECT：把请求行改写成 origin-form，并补 Host 头
    if (!*isConnect && rewritten) {
        const char *path = strchr(hostStart, '/');
        if (!path) path = "/";
        // path 到行尾（不含 \r\n）
        char pathBuf[1024] = {0};
        size_t pi = 0;
        while (path[pi] && path[pi] != '\r' && path[pi] != '\n' &&
               pi < sizeof(pathBuf) - 1) {
            pathBuf[pi] = path[pi];
            pi++;
        }
        pathBuf[pi] = 0;
        snprintf(rewritten, rewLen, "%s %s %s\r\n", method, pathBuf, version);
    }
    return YES;
}

static void PSServeHTTP(int client, const char *firstBytes, size_t firstLen)
{
    char hdr[8192];
    size_t used = 0;
    if (firstLen > sizeof(hdr) - 1) firstLen = sizeof(hdr) - 1;
    memcpy(hdr, firstBytes, firstLen);
    used = firstLen;

    // 读满 header
    while (used < sizeof(hdr) - 1) {
        char *end = strstr(hdr, "\r\n\r\n");
        if (end) break;
        ssize_t n = read(client, hdr + used, sizeof(hdr) - 1 - used);
        if (n <= 0) break;
        used += (size_t)n;
        hdr[used] = 0;
    }
    hdr[used] = 0;

    char host[256] = {0}, newLine[1200] = {0};
    uint16_t port = 0;
    BOOL isConnect = NO;

    if (!PSParseHTTPHeader(hdr, host, sizeof(host), &port, &isConnect,
                           newLine, sizeof(newLine))) {
        const char *bad = "HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\n";
        write(client, bad, strlen(bad));
        return;
    }

    int remote = PSConnectWithTimeout(host, port, kConnectTimeoutSec);
    if (remote < 0) {
        const char *err = "HTTP/1.1 502 Bad Gateway\r\nConnection: close\r\n\r\n";
        write(client, err, strlen(err));
        PSLog(@"[HTTP] 失败 %s:%u", host, port);
        return;
    }

    if (isConnect) {
        const char *ok = "HTTP/1.1 200 Connection Established\r\n\r\n";
        if (write(client, ok, strlen(ok)) != (ssize_t)strlen(ok)) {
            close(remote); return;
        }
        PSLog(@"[HTTP] CONNECT %s:%u 已连通", host, port);
        PSPump(client, remote);
        close(remote);
        return;
    }

    // 普通 HTTP：重写请求行后整体转发（header 之后的 body 交给 PSPump）
    const char *hdrEnd = strstr(hdr, "\r\n\r\n");
    char full[16384];
    size_t hdrBodyLen = 0;
    if (hdrEnd) hdrBodyLen = used - (size_t)(hdrEnd + 4 - hdr);

    // 找到原请求行的长度，替换成改写后的
    const char *origLineEnd = strstr(hdr, "\r\n");
    if (!origLineEnd) { close(remote); return; }
    size_t origLineLen = (size_t)(origLineEnd - hdr);

    int need = snprintf(full, sizeof(full), "%s%s", newLine, origLineEnd + 2);
    if (need <= 0) { close(remote); return; }
    size_t headerLen = (size_t)need;
    (void)origLineLen;

    ssize_t w = write(remote, full, headerLen);
    if (w != (ssize_t)headerLen) { close(remote); return; }
    PSSharedStats().bytesUp += (uint64_t)headerLen;

    if (hdrBodyLen > 0) {
        ssize_t bw = write(remote, hdrEnd + 4, hdrBodyLen);
        if (bw > 0) PSSharedStats().bytesUp += (uint64_t)bw;
    }

    PSLog(@"[HTTP] %s:%u 已转发", host, port);
    PSPump(client, remote);
    close(remote);
}

#pragma mark - 连接分派

static void PSHandleClient(int client)
{
    PSSharedStats().activeConnections++;
    @autoreleasepool {
        // 嗅探第一个字节：0x05 = SOCKS5，否则按 HTTP 处理
        unsigned char first = 0;
        fd_set rs; FD_ZERO(&rs); FD_SET(client, &rs);
        struct timeval tv = { 10, 0 };
        if (select(client + 1, &rs, NULL, NULL, &tv) > 0) {
            ssize_t n = recv(client, &first, 1, MSG_PEEK);
            if (n == 1) {
                if (first == 0x05) {
                    PSServeSOCKS5(client);
                } else {
                    char b[8192];
                    ssize_t m = read(client, b, sizeof(b));   // 先读掉一部分
                    if (m > 0) PSServeHTTP(client, b, (size_t)m);
                }
            }
        }
    }
    close(client);
    PSSharedStats().activeConnections--;
}

#pragma mark - 监听

@implementation PSProxyServer {
    int _socksFD;
    int _httpFD;
    dispatch_queue_t _queue;
    BOOL _running;
}

- (instancetype)init
{
    if ((self = [super init])) {
        _socksFD = -1;
        _httpFD = -1;
        _queue = dispatch_queue_create("com.axs.proxyshare.accept",
                                       DISPATCH_QUEUE_CONCURRENT);
    }
    return self;
}

static int PSListenOn(uint16_t port, NSString *bindAddr, NSString **errOut)
{
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) { if (errOut) *errOut = @"socket() 失败"; return -1; }

    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port   = htons(port);

    // 默认 0.0.0.0（局域网可达）；可配置成 127.0.0.1 只给本机用
    if (bindAddr.length && ![bindAddr isEqualToString:@"0.0.0.0"]) {
        if (inet_pton(AF_INET, bindAddr.UTF8String, &addr.sin_addr) != 1) {
            if (errOut) *errOut = [NSString stringWithFormat:@"绑定地址无效: %@", bindAddr];
            close(fd);
            return -1;
        }
    } else {
        addr.sin_addr.s_addr = htonl(INADDR_ANY);
    }

    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        if (errOut) *errOut = [NSString stringWithFormat:@"bind :%u 失败 (%s)",
                               port, strerror(errno)];
        close(fd);
        return -1;
    }
    if (listen(fd, 128) < 0) {
        if (errOut) *errOut = [NSString stringWithFormat:@"listen :%u 失败", port];
        close(fd);
        return -1;
    }
    return fd;
}

- (void)acceptLoopOnFD:(int)fd name:(NSString *)name
{
    while (_running && fd >= 0) {
        struct sockaddr_in peer;
        socklen_t plen = sizeof(peer);
        int c = accept(fd, (struct sockaddr *)&peer, &plen);
        if (c < 0) {
            if (errno == EINTR) continue;
            if (!_running) break;
            usleep(50 * 1000);
            continue;
        }

        int one = 1;
        setsockopt(c, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
        setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));

        char ip[64] = {0};
        inet_ntop(AF_INET, &peer.sin_addr, ip, sizeof(ip));

        // ACL：不在白名单内的直接拒绝
        if (!PSACLAllowsPeer(ip)) {
            PSSharedStats().rejectedConnections++;
            PSLog(@"[ACL] 拒绝来自 %s 的连接", ip);
            close(c);
            continue;
        }

        PSSharedStats().acceptedConnections++;

        int clientFD = c;
        dispatch_async(_queue, ^{
            PSHandleClient(clientFD);
        });
        (void)name; (void)ip;
    }
}

- (BOOL)startWithSOCKS:(uint16_t)socksPort http:(uint16_t)httpPort error:(NSString **)err
{
    if (_running) return YES;

    NSString *bind = PSConfigString(@"bindAddress", PS_DEFAULT_BIND);
    // 命令行 --bind 会设置该环境变量，优先级最高
    const char *ov = getenv("PS_BIND_OVERRIDE");
    if (ov && *ov) bind = @(ov);
    NSString *e1 = nil, *e2 = nil;
    _socksFD = PSListenOn(socksPort, bind, &e1);

    if (_socksFD < 0) {
        if (err) *err = e1 ?: @"SOCKS 端口监听失败";
        return NO;
    }

    if (httpPort > 0 && httpPort != socksPort) {
        _httpFD = PSListenOn(httpPort, bind, &e2);
        if (_httpFD < 0) {
            PSLog(@"HTTP 端口监听失败：%@（SOCKS 仍可用）", e2);
        }
    }

    _running = YES;

    if (_socksFD >= 0) {
        int fd = _socksFD;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            [self acceptLoopOnFD:fd name:@"socks"];
        });
    }
    if (_httpFD >= 0) {
        int fd = _httpFD;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            [self acceptLoopOnFD:fd name:@"http"];
        });
    }

    PSLog(@"开始监听：SOCKS5 :%u  HTTP :%u", socksPort, httpPort);
    return YES;
}

- (void)stop
{
    _running = NO;
    PSCloseFD(&_socksFD);
    PSCloseFD(&_httpFD);
    PSLog(@"已停止监听");
}

@end
