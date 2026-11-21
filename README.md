# 落地节点一键包（landing-node：Xray / sing-box 二选一）

**核心二选一**：安装第一步先选核心——[1] Xray（VLESS + WS + TLS 单协议，成熟稳定）或 [2] sing-box（VLESS / Trojan / VMess / Shadowsocks 2022 / Hysteria2 / TUIC 共 6 个协议，一个核心全管）。一台机器只能装一种核心。

> 更新日志见 [CHANGELOG.md](CHANGELOG.md)，本 README 里不放版本日志。完整教程见 [TUTORIAL.md](TUTORIAL.md)，Cloudflare 令牌开法见 [CLOUDFLARE_TOKEN.md](CLOUDFLARE_TOKEN.md)。

## 相关仓库

- [landing-node](https://github.com/nbbk/landing-node)（本仓库）：落地节点，Xray 与 sing-box 二选一。
- [relay-node](https://github.com/nbbk/relay-node)：中转，realm 纯转发，落地线路不好时提速；落地不用装任何东西。

旧仓只说这一句：`tiktok-node`（Xray 核心）与 `sing-box-node`（sing-box 核心）已合并到本仓，旧的一键 URL 是转发垫片，不会 404，老用户重跑能装上新版。

## 一键命令

在你自己的墙外服务器上跑一条命令，节点即上线。包里已把 DNS 防泄漏做全，装完自带泄漏自检。

先讲清用途：下面这条命令是在服务器上直接拉取并运行一键安装脚本，运行后先选核心、再问域名：

```bash
curl -fsSL https://raw.githubusercontent.com/nbbk/landing-node/main/install.sh | bash -s [域名]
```

不带域名也可以跑，安装时会交互询问域名，直接回车就用 IP 明文跑。也可以把域名直接跟在命令后面，比如下面这条命令就是带域名 `example.com` 跑一键安装：

```bash
curl -fsSL https://raw.githubusercontent.com/nbbk/landing-node/main/install.sh | bash -s example.com
```

提前预设核心的示例（先讲清用途：下面两条命令分别是提前定好用 Xray 核心、提前定好用 sing-box 核心再跑一键安装，安装时不再问选核心）：

```bash
CORE=xray curl -fsSL https://raw.githubusercontent.com/nbbk/landing-node/main/install.sh | bash -s example.com
CORE=sing-box curl -fsSL https://raw.githubusercontent.com/nbbk/landing-node/main/install.sh | bash -s example.com
```

远程一键安装的安装目录统一为 `~/landing-node-kit`；本地跑 `bash install.sh` 时用脚本所在目录。

## 架构

```text
客户端 → 落地机（landing-node）
  TLS 模式：Caddy 在 HTTPS 端口（默认 443）终止 TLS，只把随机 WS 路径反代到后端，
            其余请求返回普通网页响应（伪装）；sing-box 的 HY2 / TUIC 直接走 UDP，
            用 Caddy 签下的证书；SS 直连（默认 8388）。
  明文模式：没有域名时核心直接在 WS 端口跑明文 WS（Xray：8080；
            sing-box：8080 / 8081 / 8082 + SS 8388），HY2 / TUIC 不启用。
客户端 → 中转机（relay-node，realm 原样转发）→ 落地机（landing-node）
  中转只转发字节流，不解密、不改协议；域名 A 记录改指到中转机后，
  客户端配置一个字都不用改，直连与中转可以同时留着、互为备份。
```

## 协议与端口（默认端口，安装时可自定义）

| 核心 | TLS 模式（有域名） | 明文模式（无域名） |
|---|---|---|
| Xray | HTTPS 443（VLESS + WS + TLS） | WS 8080 |
| sing-box | HTTPS 443（VLESS / Trojan / VMess 共用）+ SS 8388（TCP + UDP）+ HY2 8443 / UDP + TUIC 8444 / UDP | VLESS 8080 + Trojan 8081 + VMess 8082 + SS 8388，HY2 / TUIC 不启用 |

证书签发方式安装时二选一（默认走 80）：[1] 默认走 80（HTTP-01），80 端口必须空闲；[2] DNS 验证（Cloudflare，DNS-01），不用 80，要一个只给改 DNS 权限的 API 令牌。HTTPS 端口不能填 80。Xray 核心 WS 内部端口从 10000 起按节点递增；sing-box 核心 WS 内部端口基数 10000、每节点加 10，直连端口每节点加 10000。

## 日常命令（都在安装目录里跑）

先讲清用途：下面这条命令是跑泄漏自检，查节点 IP、IPv6、DNS、TikTok 可达性、端口与证书：

```bash
bash check.sh
```

先讲清用途：下面这条命令是追加一个节点，只会问新节点的事，不会覆盖已有节点：

```bash
bash install.sh --add-node
```

先讲清用途：下面这条命令是删除单个节点，会先列出全部节点让你选一个，删除前会显示域名和 UUID 做二次确认：

```bash
bash install.sh --del-node
```

先讲清用途：下面这条命令是停止全部节点、保留配置，之后 `docker compose up -d` 可再启动：

```bash
bash stop.sh
```

先讲清用途：下面这条命令是彻底删除全部节点，包括容器、数据卷、配置目录，跑之前先确认全部节点都不要了：

```bash
bash stop.sh --remove
```

不带参数重跑 `bash install.sh` 只换第一个节点的 UUID 和 WS 路径（sing-box 核心还会换一套新密码），旧链接随即失效，已追加的节点不受影响；要加节点用 `--add-node`，不要重跑。

## 文档入口

- 完整教程（部署、日常使用、维护、排查、卸载、注意事项、常见问题）：[TUTORIAL.md](TUTORIAL.md)
- 更新日志：[CHANGELOG.md](CHANGELOG.md)
- Cloudflare API 令牌怎么开（DNS-01 签证书用）：[CLOUDFLARE_TOKEN.md](CLOUDFLARE_TOKEN.md)
- 中转与面板（面板版本 1.3.29）：见 [relay-node](https://github.com/nbbk/relay-node) 仓库的 README 与 TUTORIAL.md
