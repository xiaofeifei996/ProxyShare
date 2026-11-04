# ProxyShare

把越狱 iPhone 上已开启的代理隧道**共享给局域网内其它设备**（SOCKS5 + HTTP CONNECT）。

> 适用场景：你的代理软件（Shadowrocket / Stash / Clash 等）没有「共享代理端口」功能，
> 但你想让 iPad、安卓手机、电脑用上同一个代理出口。

## 原理

iOS 的全局代理（VPN）建立的是 **utun 隧道 + 默认路由**，对设备上**所有进程**生效——
包括 launchd 拉起的 root 守护进程。

所以本项目不需要 hook、不需要代理软件配合，只做一件事：

```
局域网设备  →  [你的 iPhone :47680 SOCKS5 / :47681 HTTP]
                        ↓ connect() 自动走 utun
                  代理软件的隧道
                        ↓
                    境外出口
```

守护进程只负责：监听端口 → 解析 SOCKS5 / HTTP → `connect()` 目标 → 双向转发。

## 已验证

| 项目 | 结果 |
|---|---|
| 设备 | iPhone 11 (iPhone12,1), iOS 26.0.1, RootHide |
| SOCKS5 握手 + CONNECT | ✅ |
| HTTP CONNECT | ✅ |
| HTTP 普通代理（GET http://…） | ✅ |
| HTTPS 端到端（TLS 1.3, google/cloudflare） | ✅ |
| 出口 IP 与主机一致（38.60.133.221 HK） | ✅ |

## 安装

```sh
# 下载 deb 后
dpkg -i ProxyShare_1.0.0_roothide.deb
```

或手动部署（绕过 dpkg 架构检查）：

```sh
dpkg-deb -R ProxyShare_1.0.0_roothide.deb /tmp/ps
install -m 0755 /tmp/ps/usr/libexec/psd          /usr/libexec/psd
install -m 0755 /tmp/ps/usr/libexec/psd-launcher /usr/libexec/psd-launcher
install -m 0644 /tmp/ps/Library/LaunchDaemons/com.axs.proxyshare.plist \
                /Library/LaunchDaemons/
launchctl bootstrap system /Library/LaunchDaemons/com.axs.proxyshare.plist
```

## 使用

1. **保持代理软件在运行**（代理共享依赖它的隧道）
2. 查看本机 IP：设置 → 无线局域网 → 当前网络 → IP 地址（如 `192.168.1.2`）
3. 在**其它设备**上配置：

**iOS**
```
Wi-Fi → 当前网络 → 配置代理 → 手动
服务器: 192.168.1.2
端口:   47681
```

**Android / Clash / Surfboard**
```
类型: SOCKS5
服务器: 192.168.1.2
端口:   47680
```

**命令行验证**
```sh
curl --socks5 192.168.1.2:47680 https://ipinfo.io/ip
curl -x http://192.168.1.2:47681 https://ipinfo.io/ip
```

## 配置

端口写在 LaunchDaemon 的启动参数里：

```xml
<string>/usr/libexec/psd-launcher</string>
<string>--socks</string><string>47680</string>
<string>--http</string> <string>47681</string>
<string>--bind</string> <string>0.0.0.0</string>
```

改完执行：
```sh
launchctl bootout system /Library/LaunchDaemons/com.axs.proxyshare.plist
launchctl bootstrap system /Library/LaunchDaemons/com.axs.proxyshare.plist
```

`--bind 127.0.0.1` 可限制为只有本机可用。

## 排查

```sh
# 进程状态
launchctl list | grep proxyshare

# 日志（launchd 写入，root 可读）
cat /var/tmp/ProxyShare/launchd.err.log

# 自检
/usr/libexec/psd --selftest
```

端口被占用时自检会显示具体是哪个端口不通。

## 技术要点（踩坑记录）

1. **必须签名 entitlements**。root 守护进程默认受 iOS 沙盒限制，`mkdir`/`fopen` 全部
   `Operation not permitted`。关键是 `platform-application` +
   `com.apple.private.security.no-sandbox` + `container-required: false`。
   没有这三项，连 `/var/tmp` 都写不了。

2. **端口不要用 1080/1086/8118**。这些常被代理软件自己占用，会导致
   `bind: Address already in use`。默认改用 47680/47681。

3. **RootHide 下文件视图可能隔离**。root 守护进程和 shell 看到的路径不一定是同一个，
   因此端口通过 **命令行参数**传入，不依赖读配置文件。

4. **ldid 对已签名的 fat 二进制会 assert**。CI 里改用 macOS 原生的 `codesign`。

## 构建

推送到 `main` 触发 GitHub Actions（macos-14 + roothide/theos + iPhoneOS16.5 SDK），
产物在 Actions artifacts。

## 目录

```
Daemon/main.m             守护进程入口（参数解析、自检、定时器）
Sources/PSCommon.h        公共定义（路径、默认值、统计类）
Sources/PSConfig.m        配置读取、日志、状态写入
Sources/PSProxyServer.m   SOCKS5 + HTTP CONNECT 服务器核心
layout/                   安装布局（LaunchDaemon、启动器）
psd.entitlements          沙盒豁免签名配置
build.sh                  打包脚本
```
