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

## 已验证（真机 iPhone 11 / iOS 26.0.1 / RootHide）

| 项目 | 结果 |
|---|---|
| SOCKS5 握手 + CONNECT | ✅ |
| HTTP CONNECT | ✅ |
| HTTP 普通代理（GET http://…） | ✅ |
| HTTPS 端到端（TLS 1.3, google / cloudflare） | ✅ |
| 出口 IP 与主机一致（38.60.133.221 HK） | ✅ |
| IP 白名单（CIDR / 通配） | ✅ |

## 安装

```sh
dpkg -i ProxyShare_1.1.0_roothide.deb
```

或手动部署：

```sh
dpkg-deb -R ProxyShare_1.1.0_roothide.deb /tmp/ps
install -m 0755 /tmp/ps/usr/libexec/psd          /usr/libexec/
install -m 0755 /tmp/ps/usr/libexec/psd-launcher /usr/libexec/
install -m 0755 /tmp/ps/usr/bin/psctl            /usr/bin/
install -m 0644 /tmp/ps/Library/LaunchDaemons/com.axs.proxyshare.plist \
                /Library/LaunchDaemons/
cp -R /tmp/ps/Library/PreferenceBundles/ProxySharePrefs /Library/PreferenceBundles/
cp /tmp/ps/Library/PreferenceLoader/Preferences/ProxyShare.plist \
   /Library/PreferenceLoader/Preferences/
launchctl bootstrap system /Library/LaunchDaemons/com.axs.proxyshare.plist
```

## 使用

1. **保持代理软件运行**（共享依赖它的隧道）
2. 打开 **设置 → ProxyShare**，面板会显示本机地址与端口，点一下即可复制
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

用 **`psctl`**（需要 root）：

```sh
sudo psctl status                          # 查看配置与进程状态
sudo psctl set socks 47690 && sudo psctl restart
sudo psctl set http  47691 && sudo psctl restart
sudo psctl set bind  127.0.0.1 && sudo psctl restart   # 只给本机用
sudo psctl off                             # 临时关闭
sudo psctl on                              # 重新启用
```

### IP 白名单

```sh
sudo psctl acl 192.168.1.0/24,10.0.0.5 && sudo psctl restart
sudo psctl acl off && sudo psctl restart
```

支持 `192.168.1.5`（单 IP）、`192.168.1.0/24`（CIDR）、`192.168.1.*`（通配）。
回环地址永远放行，方便本机自测。

> `psctl` 是 **shell 脚本**，不是编译的二进制——因为编译出来的进程在 RootHide 下
> `/Library` 会被 dyldhook 重定向，且写操作被沙盒拦截；而 bash 已被 patch 过，
> 看到的是真实路径，能正常改写 LaunchDaemon 的 plist。

## 排查

```sh
sudo psctl status                          # 端口 / 状态
launchctl list | grep proxyshare           # 进程是否存在
/usr/libexec/psd --selftest                # 自检：目录写入、端口可绑、ACL 规则合法
```

日志在 `/var/tmp/ProxyShare/launchd.err.log`（由 launchd 写入）。

## 设计说明：为什么面板是只读的

RootHide 越狱下，**root 守护进程与 Settings（mobile 用户）之间是完全隔离的**：

| 通道 | 实测结果 |
|---|---|
| 回环端口 127.0.0.1 | ❌ 互不可见（各自独立的网络栈） |
| `/var/tmp` | ❌ 是两个不同的目录（root 侧被重定向到 `.jbroot-XXXX/var/tmp`） |
| `/Library` | ❌ launchd 会改写成 `.jbroot-XXXX/Library` |
| Unix domain socket | ❌ 会被沙盒重定向，文件不出现 |
| **启动参数** | ✅ **唯一可靠的通道** |

所以面板只做展示与复制，真正改配置走 `psctl`（改启动参数 + 重启服务）。

顺带一个陷阱：**编译出来的 psctl 也不行**。它读 plist 时能看到 jammed 进
`.jbroot-XXXX/Library` 的路径（能读），但写会被拒；改用管道喂给 bash 也不行。
只有 **shell 脚本**（`#!/var/jb/usr/bin/bash`）能正常改写，因为 bash 被 RootHide
打了 patch。

## 技术要点（踩坑记录）

1. **必须签名 entitlements**。root 守护进程默认受 iOS 沙盒限制，`mkdir`/`fopen`
   全报 `Operation not permitted`。关键是 `platform-application` +
   `com.apple.private.security.no-sandbox` + `container-required: false`。

2. **端口不要用 1080 / 1086 / 8118 / 7890**。这些常被代理软件自己占用，会报
   `bind: Address already in use`，而设备上没有 `ps` / `lsof` / `netstat` 查不到占用者。
   默认改用 47680 / 47681。

3. **`ldid` 对已签名的 fat 二进制会 assert 崩溃**（`ldid.cpp(852)`）。
   CI 里改用 macOS 原生 `codesign --force --sign - --entitlements`。
   另外 `psd_CODESIGN_FLAGS` 对 tool 目标不生效，必须在 build.sh 里后置签名。

4. **`/dev/tcp` 在 root 的 bash 里会 segfault**，别用它做连通性测试，
   用真实二进制（`git ls-remote`、`curl`）或写个小程序。

5. **Theos 的 `RESOURCE_DIRS` 对 bundle 目标不可靠**，资源直接在 build.sh 里 `cp` 更省事。

## 构建

推送到 `main` 触发 GitHub Actions（macos-14 + roothide/theos + iPhoneOS16.5 SDK），
产物在 Actions artifacts。

## 目录

```
Daemon/main.m             守护进程入口（参数解析、自检、定时器）
Sources/PSCommon.h        公共定义（路径、默认值、ACL、统计）
Sources/PSConfig.m        配置读写、ACL 匹配、日志、状态
Sources/PSProxyServer.m   SOCKS5 + HTTP CONNECT 服务器核心
Sources/PSControlServer.m 预留接口（运行期控制通道，当前停用）
PSCTL/main.m              psctl 命令行工具
Prefs/                    设置面板（只读展示 + 复制地址）
layout/                   安装布局（LaunchDaemon、启动器、PreferenceLoader 入口）
psd.entitlements          沙盒豁免签名配置
build.sh                  打包脚本
```
