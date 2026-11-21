# 更新日志

## v1.0.0

### 合并说明

- 旧仓 `tiktok-node`（Xray 核心，VLESS + WS + TLS 单协议）与 `sing-box-node`（sing-box 核心，VLESS/Trojan/VMess/Shadowsocks 2022/Hysteria2/TUIC 共 6 个协议）合并为一个新仓 `nbbk/landing-node`，这是合并后的第一个版本。
- 合并后只留一个一键命令：`curl -fsSL https://raw.githubusercontent.com/nbbk/landing-node/main/install.sh | bash -s [域名]`，不带域名则交互询问，直接回车用 IP 明文跑。
- 两个旧仓的 README 顶部已加合并说明，`install.sh` 已换成转发到新仓的垫片；旧一键 URL 不 404，老用户重跑能装上新版。

### 改了什么

- 安装第一步先选核心：[1] Xray（VLESS + WS + TLS 单协议，成熟稳定），[2] sing-box（6 个协议，一个核心全管）；可用环境变量预设 `CORE=xray|sing-box`。
- 一台机器只能装一种核心（都占 443/80/8080）；安装前会检测已有核心安装，检测到会问清再动手，不静默覆盖；想换核心要先跑 `stop.sh --remove` 停掉旧的再装。
- 安装目录统一为 `~/landing-node-kit`（远程一键时）；本地跑 `bash install.sh` 时用脚本所在目录。
- 老机器接管：已有 `~/tiktok-node-kit` 或 `~/sing-box-node-kit` 安装的机器，新版可把管理脚本装进旧目录接管，节点记录原样保留，`CORE` 按旧仓推断，之后继续在旧目录里管理。
- 共用流程统一为：Docker 检查 → 域名（可空）→ 证书方式二选一（[1] 默认走 80 HTTP-01，[2] DNS 验证 Cloudflare）→ 公开端口 → 生成凭据 → 禁用 IPv6（sing-box 另开 BBR/TCP 优化）→ 写入配置并启动 → `check.sh` 自检 → 问要不要再加节点。
- 多节点统一用 `bash install.sh --add-node` / `--del-node` 管理，注册表为 `nodes.conf`，装完记 `CORE=xray|sing-box`；重跑只换首节点凭据，已追加节点不受影响；证书方式沿用首次安装的选择。
- 端口规则按核心分开写清：Xray 核心 TLS 模式 HTTPS 端口默认 443（可自定义高位），明文 WS 端口默认 8080，多节点共用一个 Caddy 的 443 按域名分流，WS 内部端口 10000 起按节点递增；sing-box 核心 TLS 模式 HTTPS 443、SS 8388（TCP+UDP）、HY2 8443/UDP、TUIC 8444/UDP，明文模式 VLESS 8080、Trojan 8081、VMess 8082、SS 8388，WS 内部端口基数 10000、每节点加 10，直连端口每节点加 10000。
- `stop.sh` 与 `check.sh` 两核心共用：`bash stop.sh` 停全部节点保留配置，`bash stop.sh --remove` 彻底删除；`check.sh` 做泄漏自检（IP 地区、IPv6、DNS、TikTok 可达性、端口/证书）。
- README 按两核心分开写：协议与端口、自定义端口、防泄漏设计、速度、排障里两核心不一样的地方都写了分子节；Xray 核心没有单独的速度调优步骤，BBR/TCP 优化只在 sing-box 核心一侧。

### 升级注意

- 已装好的机器不受影响：本地安装目录里的旧版 `install.sh` 不动，已跑起来的节点不用重装。
- 老用户重跑旧的一键命令会装上新版，安装第一步要先选核心；选错核心不要直接重装，先跑 `bash stop.sh --remove` 停掉旧的再装。
- 新装的机器直接用新仓的一键命令；一台机器只能装一种核心，不要在同一台机器上既装 Xray 又装 sing-box。
- 重跑安装命令只换第一个节点的凭据，已追加的节点不受影响；要加节点用 `--add-node`，不要重跑。

### 未测项

- 真机完整安装未测。
- 真实签证书未测。
- 干净机器未测。
