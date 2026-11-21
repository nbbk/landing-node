# TikTok 运营节点一键包（落地节点，Xray / sing-box 二选一）

**核心二选一**：安装第一步先选核心——[1] Xray（VLESS + WS + TLS 单协议，成熟稳定）或 [2] sing-box（VLESS/Trojan/VMess/Shadowsocks 2022/Hysteria2/TUIC 共 6 个协议，一个核心全管）。一台机器只能装一种核心，选核心的方法见“选核心”一节。

> 更新日志见 [CHANGELOG.md](CHANGELOG.md)。本 README 里不放版本日志。

## 相关仓库

- [landing-node](https://github.com/nbbk/landing-node)（本仓库）：落地节点，Xray 与 sing-box 二选一
- [relay-node](https://github.com/nbbk/relay-node)：中转，realm 纯转发，落地线路不好时提速

在你自己的墙外服务器上跑一条命令，节点即上线。包里已把 DNS 防泄漏做全，装完自带泄漏自检。

## 前置条件

- 一台墙外服务器（你机场现有的机器就行），Ubuntu/Debian，root 权限
- 一个域名，已解析（A 记录）到这台机器，**有域名强烈建议用**，Caddy 会自动签 TLS 证书；443 端口放行
  - 证书签发方式安装时二选一（见“证书签发方式”一节）：默认走 80 方式时 **80 端口必须空闲**（Caddy 签证书走 HTTP-01 验证必须用 80；80 被占 TLS 装不了）；选 DNS 验证时 80 不用空闲
  - **端口可以自定义**：TLS 模式 HTTPS 端口默认 443、明文 WS 端口默认 8080；默认端口被占时安装会让你改一个高位端口（如 8443、24443、30000），直接回车就是默认值
  - 没有域名也能跑：直接回车跳过，用 IP + 明文 WS（能用，但不如 TLS 隐蔽，之后补域名重跑即可升级）。明文模式下 sing-box 的 HY2/TUIC 不启用（需要域名证书），见“协议与端口”一节
- 一台机器只能装一种核心：Xray 与 sing-box 都要占 443/80/8080，不能同机共存。想换核心，先跑 `bash stop.sh --remove` 停掉旧的再装（见“停止 / 删除节点”一节）
- 服务器地区 = 你要做的 TikTok 地区（美区、东南亚、英国……），**节点 IP 的地区必须和运营地区一致**，否则直接限流
- IP 尽量干净：住宅/ISP 的 IP 最好；机房 IP 也能跑，但 TikTok 风控更严，`check.sh` 会告诉你当前 IP 是不是机房 IP

## 使用步骤

### 远程一键安装（推荐，不用传包）

服务器上直接跑一条命令，运行后先选核心、再问域名，输入这台服务器的域名就行：

```
curl -fsSL https://raw.githubusercontent.com/nbbk/landing-node/main/install.sh | bash -s [域名]
```

不带域名也可以跑，安装时会交互询问域名，直接回车就用 IP 明文跑。也可以把域名直接跟在命令后面（比如 `... | bash -s example.com`）。换服务器、换地区时不用改脚本：域名先解析到新服务器，再跑同一条命令、输入新域名即可；每次运行都会生成新的 UUID 和 WS 路径，每个服务器一套独立的节点。

远程一键安装的安装目录统一为 `~/landing-node-kit`。

**重跑会换掉第一个节点**：不带参数重跑 `install.sh` 只换第一个节点的 UUID 和 WS 路径（旧链接失效），已追加的第 2 个及以后节点不受影响。要在一台机上再加一个节点不要重跑，用下面的“多节点”方法（`--add-node`）。

### 本地安装（传包）

1. 把本包传到服务器并解压，进入目录
2. 运行：`bash install.sh`
3. 先选核心（见“选核心”一节），有域名就输入域名，没有直接回车
4. 脚本会自动按下面“共用流程”跑完，最后自动跑一遍 `check.sh` 自检

本地跑 `bash install.sh` 时，用脚本所在目录作为安装目录（不强制改成 `~/landing-node-kit`）。

### 共用流程（两种核心都一样走这几步）

1. 检查 Docker（没有就装）
2. 问域名（可空，直接回车用 IP 明文跑）
3. 证书方式二选一：[1] 默认走 80 HTTP-01，[2] DNS 验证 Cloudflare（见“证书签发方式”一节）
4. 问公开端口（直接回车用默认，见“自定义端口”一节）
5. 生成凭据（UUID/密码与随机 WS 路径）
6. 禁用 IPv6（sing-box 核心另开 BBR/TCP 优化，见“速度”一节）
7. 写入配置并启动
8. 跑 `check.sh` 自检
9. 问要不要再加一个节点（回 `y` 就接着装，见“多节点”一节）

### 安装完输出什么

- Xray 核心：输出节点链接、base64 订阅内容、`clash.yaml`，并在服务器上生成 `qr.png`（没有 qrencode 时自动用 apt/yum 安装；实在装不上就把节点链接发给 Muse，它会回你二维码图片）
- sing-box 核心：输出 6 个协议的节点链接、base64 订阅内容、`clash.yaml`，并在服务器上生成每个协议的二维码（`qr-vless.png`、`qr-trojan.png`、`qr-vmess.png`、`qr-ss.png`，TLS 模式另有 `qr-hy2.png`、`qr-tuic.png`；没有 qrencode 时自动用 apt/yum 安装）

## 选核心（安装第一步，先选再装）

安装第一步会让你二选一，每个选项下面都有解释，直接回车就是默认（默认 [1] Xray）。也可以用环境变量提前预设，安装时不再问：

```
CORE=xray curl -fsSL https://raw.githubusercontent.com/nbbk/landing-node/main/install.sh | bash -s example.com
CORE=sing-box curl -fsSL https://raw.githubusercontent.com/nbbk/landing-node/main/install.sh | bash -s example.com
```

- **[1] Xray（VLESS + WS + TLS 单协议，成熟稳定）**：只跑 VLESS + WS + TLS 一个协议，做法最简单、跑得最稳，出了问题也最好排查。适合只做 TikTok 运营、只要一个协议够用的人。代价是协议只有一个，客户端选择少，换协议要换核心重装。
- **[2] sing-box（VLESS/Trojan/VMess/Shadowsocks 2022/Hysteria2/TUIC 共 6 个协议，一个核心全管）**：一个核心同时跑 6 个协议，手机上哪个协议快就用哪个，弱网还有 Hysteria2/TUIC 的 QUIC 顶着。适合想多协议备用、想在客户端里比速度的人。代价是端口多、配置复杂一些，出问题要查的面也多一点。

### 一台机器只能装一种核心

- Xray 与 sing-box 都要占 443/80/8080，一台机器只能装一种，装第二种会抢端口、起不来。
- 安装前脚本会检测这台机器上是否已有核心安装，检测到会先问清再动手，不会静默覆盖。
- 想换核心：先在安装目录里跑 `bash stop.sh --remove` 停掉并彻底删除旧核心，再重新跑安装命令选新核心。只停不停删（`bash stop.sh`）不够，旧配置还在，换核心前必须彻底删除。

### 老机器接管（已有旧仓安装的机器）

- 已有 `~/tiktok-node-kit` 或 `~/sing-box-node-kit` 安装的机器，直接在那台机上跑新版一键命令，脚本会自动检测到旧安装并问你：`[1] 接管已有安装`（推荐）还是 `[2] 取消`。选 1 就把新版管理脚本（install.sh、stop.sh、check.sh）装进旧目录，在旧 nodes.conf 里记下核心（`~/tiktok-node-kit` 推断为 `xray`，`~/sing-box-node-kit` 推断为 `sing-box`），节点记录原样保留，之后继续在旧目录里管理，不用搬到 `~/landing-node-kit`。选 2 就取消，先去旧目录跑 `bash stop.sh --remove` 停掉旧安装再重跑。
- 接管不换凭据、不动已有节点，只是换管理脚本；之后再加节点、删节点、停节点都在旧目录里跑。

## 协议与端口（默认端口，安装时可自定义）

### Xray 核心

| 模式 | 端口 | 说明 |
|---|---|---|
| TLS 模式（有域名） | HTTPS 端口默认 443（经 Caddy） | VLESS + WS + TLS，TikTok 主用 |
| 明文模式（无域名） | WS 端口默认 8080 | IP + 明文 WS，能用，不如 TLS 隐蔽 |

- 多节点共用一个 Caddy 的 443 端口，Caddy 按域名（Host/SNI）分流到各自的 xray 后端。
- WS 内部端口从 10000 起，按节点递增（第 1 个节点 10000，第 2 个节点 10001，依此类推）。
- 不带参数重跑会换掉第一个节点：重新生成新的 UUID 和 WS 路径，第一个节点的旧链接就失效，手机上要重新导入新的；**已追加的第 2 个及以后节点不受影响**。端口默认是上面这套（443/8080），随机的是 UUID 和 WS 路径。

### sing-box 核心

| 协议 | TLS 模式（有域名） | 明文模式（无域名） | 说明 |
|---|---|---|---|
| VLESS + WS | 443（经 Caddy） | 8080 | TikTok 主用 |
| Trojan + WS | 443（经 Caddy） | 8081 | 简单、兼容好 |
| VMess + WS | 443（经 Caddy） | 8082 | 老客户端兼容 |
| Shadowsocks 2022 | 8388（TCP+UDP） | 8388 | 轻量、速度快 |
| Hysteria2 | 8443/UDP | 不启用 | QUIC，弱网也快 |
| TUIC | 8444/UDP | 不启用 | QUIC + BBR |

- WS 内部端口基数是 10000，每节点加 10（第 1 个节点 10000，第 2 个节点 10010，依此类推；TLS 与明文模式都一样）。
- SS/HY2/TUIC 是直连端口，每节点各用一套不同的端口：直连端口每节点加 10000（比如第 2 个节点的 SS 是 18388、HY2 是 18443、TUIC 是 18444）。
- 不带参数重跑会换掉第一个节点：重新生成新的 UUID/密码和 WS 路径，第一个节点的旧链接就失效，手机上要重新导入新的；**已追加的第 2 个及以后节点不受影响**。端口默认是上面这套（443/8080/8081/8082/8388/8443/8444），随机的是 UUID、密码和 WS 路径；安装时可以把端口改成别的（见下节）。要在一台机上再加一个节点，用下面的“多节点”方法（`--add-node`），不要重跑。

## 自定义端口（默认端口被占时用）

安装时会依次问每个公开端口，直接回车就是默认值；默认端口被占时填个高位端口就能装，不用换服务器。也可以用环境变量预设端口（有就不再问）。

### Xray 核心

- TLS 模式：HTTPS 端口（默认 443，例如改 8443）
- 明文模式：WS 端口（默认 8080，例如改 9080）

```
HTTPS_PORT=8443 curl -fsSL https://raw.githubusercontent.com/nbbk/landing-node/main/install.sh | bash -s example.com
WS_PORT=9080 bash install.sh
```

### sing-box 核心

- TLS 模式：HTTPS 端口（默认 443，例如改 8443）、SS（默认 8388，例如改 18388）、HY2（默认 8443，例如改 18443）、TUIC（默认 8444，例如改 18444）
- 明文模式：VLESS（默认 8080，例如改 18080）、Trojan（默认 8081，例如改 18081）、VMess（默认 8082，例如改 18082）、SS（默认 8388，例如改 18388）

```
HTTPS_PORT=8443 SS_PORT=18388 HY2_PORT=18443 TUIC_PORT=18444 bash install.sh example.com
```

### 两核心都要注意的两点

- 选默认走 80 方式签证书时 **80 端口必须空闲**，Caddy 签证书走 HTTP-01 验证必须用 80，改不了——80 被占时 TLS 装不了，只能停掉占用 80 的程序、换服务器，或改用明文模式，或重跑并选 [2] DNS 验证（要 Cloudflare API 令牌）；选 DNS 验证时 80 不用空闲。HTTPS 端口也不能填 80。
- 改完端口后，节点链接、`clash.yaml`、二维码里的端口都会跟着变，不用手动改。安装完的实际端口记在安装目录的 `.env` 里（`check.sh` / `stop.sh` 从这里读）；重跑安装要换端口时仍会问，不会被上次的值悄悄定死（域名除外，域名会沿用 `.env` 里的，换域名用 `bash install.sh 新域名` 或改 `.env`）。

## 证书签发方式（安装时二选一，默认走 80）

有域名时安装会问一次，每个选项下面都有解释，直接回车就是默认：

- **[1] 默认走 80（HTTP-01）**：最简单，什么都不用准备，装完 Caddy 自己签证书、到期自己续。前提是 80 端口必须空闲、域名要指向这台落地机。适合单节点、80 没被占的情况。
- **[2] DNS 验证（Cloudflare，DNS-01）**：不用 80 端口，域名不用改来改去，续签全自动，不怕忘。前提是域名 DNS 在 Cloudflare，要去 Cloudflare 后台开一个只给改 DNS 权限的 API 令牌。适合 80 被占了、多节点、怕忘续签的情况。

开令牌的详细步骤见 [CLOUDFLARE_TOKEN.md](CLOUDFLARE_TOKEN.md)（按 Cloudflare 最新界面一步一步写，权限只留 Zone:DNS:Edit 和 Zone:Zone:Read，新版令牌以 `cfut_` 开头）。**不要用 Global API Key**（权限太大，泄露了整个账号都危险）。令牌只存在服务器的 `.env` 里（600 权限，只有 root 能读），脚本不会把它打印出来。

也可以提前预设好，安装时不再问（令牌放命令行会进 shell 历史，不放心就安装时交互粘贴，输入时不回显）：

```
CERT_METHOD=dns CLOUDFLARE_API_TOKEN=你的令牌 curl -fsSL https://raw.githubusercontent.com/nbbk/landing-node/main/install.sh | bash -s example.com
```

选 DNS 验证后 80 的变化：Caddy 不再把 80 映射到主机，80 被别的程序占着也不影响安装和续签；Caddy 容器会换成现场编译的带 Cloudflare 插件版本（官方 builder 镜像编，第一次约 1-3 分钟，之后复用），证书续签全自动。

## 多节点（一台落地机多个节点）

一台落地机可以跑多个节点，每个节点一个子域名、自己的凭据（UUID/密码/WS 路径），手机上当成几个独立节点导入。两种核心的多节点共用同一套管理命令，区别只在后端与端口（见“协议与端口”一节）。

节点注册表是安装目录里的 `nodes.conf`，装完会记下 `CORE=xray` 或 `CORE=sing-box`，之后的管理命令按这个值走对应核心的逻辑。

### 泛域名解析（一次配好）

每个节点一个子域名，比如 `us1.example.com`、`us2.example.com`、`us3.example.com`，都指向同一台落地机。最省事是加一条泛域名 A 记录：

- 主机记录：`*`，记录类型：`A`，记录值：落地机 IP（例如 203.0.113.1）

加完之后任意子域名都自动指向这台机，以后加节点不用再改 DNS。也可以每个子域名单独加一条 A 记录，效果一样，就是每次加节点都要多改一次。

第二台落地机示例：域名 `example.net`，A 记录值 203.0.113.2，做法与第一台相同，各自独立安装、各自记自己的 `nodes.conf`。

### 追加节点

两种办法：

1. **装完直接加**：第一个节点装完会问“还要再加一个节点吗？[y/N，默认 N]”，回 `y` 就接着装下一个，再问、再加，可以一直加下去。
2. **事后追加**：在节点目录里跑：

   ```
   bash install.sh --add-node
   ```

   也可以把新子域名直接跟在后面，省一次输入：`bash install.sh --add-node us2.example.com`

追加节点只会问新节点的事（子域名、端口），**不会覆盖已有节点**，也不会重问证书方式：追加沿用第一次安装选的证书方式。

### 追加时两种核心的区别

- **Xray 核心**：多个节点共用一个 Caddy 的 443 端口，Caddy 按域名（Host/SNI）分流到各自的 xray 后端；WS 内部端口从 10000 起按节点递增。
- **sing-box 核心**：WS 三协议（VLESS/Trojan/VMess）共用一个 Caddy 的 443 端口，Caddy 按域名（Host/SNI）分流到各自的 sing-box 后端；SS/HY2/TUIC 是直连端口，每节点各用一套不同的端口（直连端口默认在前一节点端口上加 10000，也可以自己填）。

### 证书两种方式（追加时怎么走）

- **默认走 80（HTTP-01）**：每个子域名 Caddy 单独签一张证书。加节点前确认新子域名的 A 记录已经指向这台落地机（泛域名配好就不用管），Caddy 追加后自动签，签好新节点才上线。sing-box 核心的 HY2/TUIC 要等新子域名的证书签好才起（最多等 180 秒，拿不到就先不启用这两个协议，其他协议不受影响）。
- **DNS 验证（Cloudflare，DNS-01）**：一张泛域名证书 `*.example.com` 通吃所有子域名，签一次就够，加节点不用再签、不用改 DNS、80 也不用空闲。sing-box 核心要求：**各节点必须是同一父域名的子域名**（比如都是 `*.example.com` 下面的）；如果新节点用了别的域名，追加时会直接告诉你换一个。

### 中转侧不用动

同一台落地机的多个节点共用中转一条 443 转发，靠域名区分：中转的 relay.conf 里这台落地机还是一条规则，域名指向中转机后，`us1.example.com` 和 `us2.example.com` 的流量都走同一条转发，到落地后 Caddy 再按域名分给各自的后端。**不用给第二个节点再加中转规则**，也不用改中转配置。

### 续签说明

证书还是 Let's Encrypt 90 天，Caddy 到期前 30 天内自动续签。默认走 80 方式时续签要走 80 端口验证：如果域名现在指向中转机、80 又没转到这台落地机，续签会失败，见下面“手动续签”一节（每个节点都要单独续，续哪个就把哪个子域名的 A 记录临时改回落地机）。选 DNS 验证的节点续签全自动，不用管。

### 删除单个节点

```
bash install.sh --del-node
```

会列出全部节点让你选一个（也可以直接传域名：`bash install.sh --del-node us2.example.com`）。删除前会显示该节点的域名和 UUID 做二次确认（[y/N]，默认 N），确认后删除该节点的后端容器、Caddyfile 里对应的配置段、节点记录，然后 reload Caddy；其他节点不受影响，删除后脚本会逐个核查剩余节点仍正常（端口监听、WS 握手）。删除时会把被删节点的信息打印出来，方便你留底。`bash stop.sh` 还是全停全删，不动单个节点。

### 明文模式（没有域名）

没有域名也能追加节点：追加时不用填域名，各节点用不同的端口。Xray 核心默认在前一个节点端口上加 1（比如 8080、8081；也可以自己填）；sing-box 核心默认在前一节点端口上加 10000（比如第 2 个节点的 VLESS 是 18080、Trojan 是 18081、VMess 是 18082、SS 是 18388；也可以自己填）。证书那一节不适用，明文节点没有证书；sing-box 明文模式下 HY2/TUIC 不启用。

## 手动续签（证书快到期、自动续签失败时）

证书是 Let's Encrypt 的 90 天证书，Caddy 会在到期前 30 天内自动续签，平时不用你管。**只有一种情况要手动续签**：签证书走默认 80 方式（HTTP-01）、且域名现在指向中转机、80 又没转到这台落地机时——也就是中转后面第 2 个及以后的落地。Caddy 续签要走 80 端口验证，验证请求到了中转的 80，却转给了第 1 个落地，续不上。**选了 DNS 验证的落地不需要手动续签**，续签全自动。

手动续签的步骤（到期前 2 周内做，别太早——Caddy 只在到期前 30 天内才开始续）：

1. 先看证书还剩几天：在落地机上跑 `cd ~/landing-node-kit && bash check.sh`（老机器接管的，在旧目录里跑），看“证书与续签”一节（剩 30 天以内才能续）
2. 把域名 A 记录改回指向落地机 IP（在 Cloudflare DNS 里改这条 A 记录）
3. 等 DNS 生效（TTL 一般 5 分钟）；核对：`dig +short example.com` 返回的应该是落地机 IP（例如 203.0.113.1）
4. 重启 Caddy 触发续签：在落地机目录里跑 `docker compose restart caddy`（Xray 核心也可以跑 `docker restart tiktok-caddy`；sing-box 核心也可以跑 `docker restart singbox-caddy`）
5. 核对新到期日：再跑 `bash check.sh`，看“证书与续签”一节，剩余天数应该回到 90 天左右
6. 把域名 A 记录改回指向中转机 IP，完事

## 手机端（关键：节点只解决网络这一半）

TikTok 从 IP、DNS、时区、SIM 卡几个地方一起判断地区，节点配好只算完成一半，手机端必须配套：

1. **拔卡**：拔掉国内 SIM 卡（或用无 SIM 的备用机）；双卡手机只留目标地区卡，没有就空着用 Wi-Fi
2. **时区语言**：手机时区、语言、地区全部改成节点所在地区，和 IP 地区一致
3. **关定位**：关掉 TikTok 的定位权限，系统定位服务也建议关掉
4. **导入节点**：
   - 小火箭（Shadowrocket）：Xray 核心扫 `qr.png`，sing-box 核心扫对应的 `qr-*.png`，或导入脚本输出的链接；然后在配置的 DNS 设置里开启远程解析（通过代理解析），不要用本地 DNS
   - Clash/Stash：直接导入随包生成的 `clash.yaml`，它已经配好全部流量走节点、全部 DNS 走代理 DoH、禁用 IPv6；sing-box 核心的 `PROXY` 组是 url-test，会自动选延迟最低的协议，`MANUAL` 组可以手动指定
5. **验证泄漏**（开着节点，在手机浏览器里做）：
   - 打开 https://www.dnsleaktest.com → Extended test：全部 DNS 服务器 IP 都应该是节点所在国家/机房的，出现中国运营商 DNS = 泄漏
   - 打开 https://browserleaks.com/ip：不能出现你的真实 IP、不能出现 IPv6 地址、时区和语言要和节点地区一致
   - 刷几个 TikTok 视频，看个人主页显示的地区是否和节点地区一致

## 这个包防泄漏是怎么做的

### Xray 核心

- **服务端 xray**：自身解析走 DoH（1.1.1.1/8.8.8.8）+ TCP 兜底，不走明文 UDP 53；`queryStrategy=UseIPv4` 只解析 A 记录，不产生 IPv6 解析路径
- **主机级**：写 sysctl 持久化禁用 IPv6，堵死 IPv6 泄漏口
- **客户端 Clash 配置**：`ipv6: false`；DNS 全部走代理 DoH（`proxy-server-nameserver`），TikTok 域名强制走代理解析；规则 `MATCH,PROXY`，全部流量走节点，不分流
- **自检**：`bash check.sh` 会查节点 IP 的地区、运营商、是不是机房 IP、IPv6 状态、TikTok 从节点出口是否可达

### sing-box 核心（只用加密 DNS，永不回落明文）

- **服务端 sing-box**：自身解析只走加密 DNS——DoH（Cloudflare 1.1.1.1、Google 8.8.8.8、Quad9 9.9.9.9）+ DoT（tls://1.1.1.1、tls://8.8.8.8），失败也不回落明文 UDP/TCP 53（宁可解析失败也不泄露）；`strategy=ipv4_only` 只解析 A 记录；`default_domain_resolver` 指定全部出站解析都走 DoH
- **主机级**：写 sysctl 持久化禁用 IPv6，堵死 IPv6 泄漏口
- **客户端 Clash 配置**：`ipv6: false`；DNS 全部走代理 DoH（`proxy-server-nameserver` + `fallback` 也是 DoH，`fallback-filter` 挡住国内 IP）；TikTok 域名强制走代理解析；规则 `MATCH,PROXY`，全部流量走节点，不分流
- **自检**：`bash check.sh` 会查节点 IP 的地区、运营商、是不是机房 IP、IPv6 状态、TikTok 从节点出口是否可达

### check.sh 自检什么

`bash check.sh` 会查：节点 IP 的地区、运营商、是不是机房 IP、IPv6 是否已禁用、DNS 是否泄漏、TikTok 从节点出口是否可达、端口监听与证书状态。装完脚本会自动跑一遍，平时想复查随时在安装目录里跑 `bash check.sh`。

## 速度

### Xray 核心

- Xray 核心没有单独的速度调优步骤：共用流程里只做禁用 IPv6，不开 BBR/TCP 优化。速度主要靠选对服务器地区与干净 IP，以及 TLS 流量走 443 像普通网站流量一样稳定。

### sing-box 核心

- **主机级**：开 BBR + fq 拥塞控制、加大 TCP 读写缓冲、开 TCP Fast Open（写 sysctl 持久化；内核不支持 BBR 时自动跳过）
- **协议级**：Hysteria2、TUIC 走 QUIC（UDP），弱网、高丢包下也快；TUIC 用 BBR 拥塞控制
- **客户端**：`clash.yaml` 的 `PROXY` 组是 url-test，每 300 秒测一次速，自动用延迟最低的协议，不用手动换

## 排障

- **节点没网、手机全打不开**：先在服务器上测 WS 握手（装完脚本会自动测）：
  `curl -s -i -N --max-time 10 -H "Connection: Upgrade" -H "Upgrade: websocket" -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" -H "Sec-WebSocket-Version: 13" https://example.com:443/example-path`
  （端口是安装时选的 HTTPS 端口，默认 443；用默认端口时 `:443` 可省略；`/example-path` 换成你自己的 WS 路径）返回 `101` = 正常；返回 `200 ok` = Caddy 没把请求转给后端，跑 `docker compose down && docker compose up -d` 重建容器再测；返回 `400` = 后端拒绝握手，核对手机上的 UUID 和 WS 路径跟配置文件是否一致（Xray 看 `config.json`，sing-box 看 `sing-box.json`）。
- **Caddy 拿不到证书**：走 80 方式时核对域名 A 记录指到本机 IP、云厂商安全组放行 80 和 HTTPS 端口、**80 端口没有被别的程序占**；选 DNS 验证时核对 Cloudflare 令牌没错、权限够（Zone:DNS:Edit）、域名 DNS 确实在 Cloudflare；看日志：Xray 核心 `docker logs tiktok-caddy --tail 20`，sing-box 核心 `docker logs singbox-caddy --tail 20`。
- **sing-box 核心 HY2/TUIC 没启用**：装完提示证书未就绪时会出现，重跑一次安装命令即可补上（会换一套新节点）。
- **sing-box 核心起不来**：看日志 `docker logs singbox-node --tail 30`；也可以用 `sing-box check -c sing-box.json` 校验配置。

## 日志上限（防爆盘）

- 每个容器（核心容器、Caddy）的日志都有限制：单个文件最多 10MB、最多留 3 份，写满自动轮转，不会像没上限的 json 日志那样一直长到撑爆磁盘。
- **限制只对重建后的容器生效**：已经在跑的容器要重建一次才限流——在节点目录里跑 `docker compose down && docker compose up -d`（配置不动，只重建容器），或重跑安装命令。
- 定期看一眼各容器日志占了多少：`docker system df`，或 `du -sh /var/lib/docker/containers/* | sort -rh | head`。

## 停止 / 删除节点

- **停止（保留配置，可再启动）**：在节点目录里跑 `bash stop.sh`，会停掉**全部节点**的容器并检查实际用的端口（按 `nodes.conf` 里的记录；旧版单节点按 `.env` 里的记录）是否已释放；再启动跑 `docker compose up -d`。远程一键（不用先下载）：`curl -fsSL https://raw.githubusercontent.com/nbbk/landing-node/main/stop.sh | bash`
- **删除单个节点**：`bash install.sh --del-node`，只删选中的一个节点，其他节点不受影响（见“多节点”一节）。
- **彻底删除**：`bash stop.sh --remove`，会删**全部节点**的容器、数据卷、配置目录，并删除 `/etc/sysctl.d/99-landing-node.conf`（旧版安装留下的 `99-tiktok-node.conf` / `99-singbox-node.conf` 也一并删），IPv6 与网络调优随之恢复。远程一键：`curl -fsSL https://raw.githubusercontent.com/nbbk/landing-node/main/stop.sh | bash -s -- --remove`
- **手动停**：`docker compose down`（保留配置）或 `docker compose down -v`（连数据卷一起删）
- stop.sh 停完会逐个检查端口：如果某个端口仍被占用，会直接列出占用它的进程，照着处理就行；如果占用它的是别的程序，先停掉那个程序或换一台服务器。

## 说明

- 架构：有域名时 Caddy 在 HTTPS 端口（默认 443，可自定义高位端口）终止 TLS，只把随机 WS 路径反代到后端，其余请求返回普通网页响应（伪装）；sing-box 核心的 HY2/TUIC 直接走 UDP，用 Caddy 签下的证书；SS 直连（默认 8388，可自定义）；80 端口只用于证书验证（选 DNS 验证时不用 80，见“证书签发方式”一节）
- 链接里的 UUID/密码等同于密码，不要外传；泄露了重跑脚本即可换一套。示例 UUID `11111111-2222-3333-4444-555555555555` 与示例 WS 路径 `/example-path` 只是示例，不要直接拿来用。
- 如果 `check.sh` 显示 hosting=true（机房 IP）且之后出现 0 播放/限流，优先换住宅/ISP 的干净 IP，换节点比调参数管用

## 老用户须知

- 旧仓 `tiktok-node`（Xray 核心）与 `sing-box-node`（sing-box 核心）已合并到本仓 `landing-node`，两个旧仓的 README 顶部已加合并说明，`install.sh` 已换成转发到新仓的垫片。
- 旧的一键 URL 不会 404：老用户重跑旧的一键命令，能装上新版（安装第一步会先选核心）。
- 已装好的机器不受影响：本地安装目录里的旧版 `install.sh` 不动，已跑起来的节点不用重装；想用新版管理脚本接管旧目录，见“选核心”一节里的“老机器接管”。
- 新装的机器直接用本仓的一键命令，安装目录统一为 `~/landing-node-kit`。
