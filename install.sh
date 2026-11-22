#!/usr/bin/env bash
# 落地节点一键部署（二合一）：Xray 与 sing-box 落地节点一键安装
#   第一步先选核心：[1] Xray（VLESS + WS + TLS 单协议，成熟稳定）
#                  [2] sing-box（VLESS / Trojan / VMess / Shadowsocks / Hysteria2 / TUIC 六协议合一）
# 用法：
#   本地：bash install.sh [域名]
#   远程一键：curl -fsSL https://raw.githubusercontent.com/nbbk/landing-node/main/install.sh | bash -s [域名]
#   （不给域名则交互询问；直接回车用 IP + 明文跑）
#   核心可预设：CORE=xray bash install.sh [域名] 或 CORE=sing-box bash install.sh [域名]
#   追加节点：bash install.sh --add-node [新子域名]
#   删除单个节点：bash install.sh --del-node [子域名或编号]
#   端口可预设：HTTPS_PORT=8443 bash install.sh [域名]（TLS 模式，默认 443）
#              WS_PORT=9080 bash install.sh（Xray 明文模式，默认 8080）
#              sing-box 端口预设见 README“自定义端口”一节
#   证书方式可预设：CERT_METHOD=dns CLOUDFLARE_API_TOKEN=你的令牌 bash install.sh [域名]
# 一台机器只能装一种核心（都占 443/80/8080）；想换核心先跑 bash stop.sh --remove 停掉旧的再装。
# 老机器接管：已有 ~/tiktok-node-kit 或 ~/sing-box-node-kit 安装的机器，运行本脚本会问要不要接管
#   （把新版管理脚本装进旧目录，节点记录原样保留，之后继续在旧目录里管理）。
# 架构：有域名 -> Caddy 在 HTTPS 端口终止 TLS，反代本机核心的 WS 入站
#        无域名 -> 核心直接在 WS 端口跑明文 WS（Xray：8080；sing-box：8080/8081/8082 + SS 8388）
# 多节点：一台落地机可跑多个节点，共用一个 Caddy 的 443，按域名分流；各节点凭据、后端容器都独立。
# DNS 防泄漏设计与速度设计见 README（Xray：DoH + TCP 兜底；sing-box：只走加密 DNS + BBR）。
set -euo pipefail

# 工作目录：本地跑 bash install.sh 时用脚本所在目录；
# 远程一键（curl | bash 或 bash <(...)）时用 ~/landing-node-kit
if [ -f "$0" ]; then
  cd "$(dirname "$0")"
else
  mkdir -p "$HOME/landing-node-kit"
  cd "$HOME/landing-node-kit"
fi
REG_FILE="nodes.conf"

DRY_RUN="${DRY_RUN:-0}"
TLS_MODE=1
HY2_ENABLED=1
DOMAIN="${DOMAIN:-}"
SERVER_IP="${SERVER_IP:-}"
CORE="${CORE:-}"
CORE_ENV="$CORE"
CORE_NAME="xray"
CADDY_CTR="tiktok-caddy"

# ---------- 参数解析 ----------
ADD_NODE=0
DEL_NODE=0
DEL_TARGET=""
ADD_ARG=""
DOMAIN_ARG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --add-node)
      ADD_NODE=1
      if [ $# -ge 2 ]; then ADD_ARG="$2"; shift; fi
      ;;
    --del-node)
      DEL_NODE=1
      if [ $# -ge 2 ]; then DEL_TARGET="$2"; shift; fi
      ;;
    --add-node=*) ADD_NODE=1; ADD_ARG="${1#--add-node=}" ;;
    --del-node=*) DEL_NODE=1; DEL_TARGET="${1#--del-node=}" ;;
    --dry-run) DRY_RUN=1 ;;
    -h|--help)
      echo "用法：bash install.sh [域名]"
      echo "     bash install.sh --add-node [新子域名]   追加一个节点"
      echo "     bash install.sh --del-node [子域名或编号] 删除单个节点"
      echo "     CORE=xray|sing-box bash install.sh [域名]  预设核心（不问）"
      exit 0
      ;;
    *)
      [ -z "$DOMAIN_ARG" ] && DOMAIN_ARG="$1"
      ;;
  esac
  shift
done
CLI_DOMAIN="$DOMAIN_ARG"
MODE="fresh"
MODE_ARG=""
if [ "$ADD_NODE" = "1" ]; then MODE="add"; MODE_ARG="$ADD_ARG"; fi
if [ "$DEL_NODE" = "1" ]; then MODE="del"; MODE_ARG="$DEL_TARGET"; fi

if [ "$DRY_RUN" = "1" ]; then
  echo "[dry-run] 只生成配置并打印，不启动容器、不改系统"
  [ -n "$SERVER_IP" ] || SERVER_IP="203.0.113.1"
fi


ask() {
  local prompt="$1" varname="$2" default="${3:-}"
  if [ -n "${!varname:-}" ]; then return 0; fi
  local ans=""
  if [ -t 0 ]; then
    read -rp "$prompt" ans || true
  elif [ -r /dev/tty ]; then
    read -rp "$prompt" ans </dev/tty 2>/dev/null || true
  fi
  [ -z "$ans" ] && ans="$default"
  printf -v "$varname" '%s' "$ans"
}

read_line() {
  local _var="$1" _prompt="$2" _a=""
  if [ -t 0 ]; then
    read -rp "$_prompt" _a || true
  elif [ -r /dev/tty ]; then
    read -rp "$_prompt" _a </dev/tty 2>/dev/null || true
  fi
  printf -v "$_var" '%s' "$_a"
}

section() {
  echo ""
  echo "============================================================"
  echo "  $1"
  echo "============================================================"
  echo ""
}

valid_port() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$((10#$1))" -ge 1 ] && [ "$((10#$1))" -le 65535 ]
}

port_used() {
  case " $2 " in *" $1 "*) return 0 ;; *) return 1 ;; esac
}

valid_domain() {  # 子域名格式：us1.example.com 这种
  case "$1" in
    *..*|*.-*|*-.*) return 1 ;;
  esac
  printf '%s' "$1" | grep -qE '^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$'
}

base_domain() {
  local d="$1"
  case "$d" in *.*.*) printf '%s' "${d#*.}" ;; *) printf '%s' "$d" ;; esac
}

reg_get() {  # reg_get KEY -> 值（找不到为空）
  local k="$1" line=""
  [ -f "$REG_FILE" ] || return 0
  line="$(grep -m1 "^${k}=" "$REG_FILE" || true)"
  printf '%s' "${line#*=}"
}

reg_set() {  # reg_set KEY VALUE：存在则整行重写，不存在则追加（不用 sed 替换，值里有 & 也不怕）
  local k="$1" v="$2"
  touch "$REG_FILE"
  grep -v "^${k}=" "$REG_FILE" > "$REG_FILE.tmp" || true
  printf '%s=%s\n' "$k" "$v" >> "$REG_FILE.tmp"
  mv "$REG_FILE.tmp" "$REG_FILE"
}

node_indices() {  # 全部节点编号（每行一个，数字升序）
  [ -f "$REG_FILE" ] || return 0
  grep -oE '^NODE_[0-9]+_DOMAIN=' "$REG_FILE" | grep -oE '[0-9]+' | sort -n -u || true
}

node_field() { reg_get "NODE_${1}_${2}"; }   # node_field 编号 字段名

node_count() { node_indices | wc -l | tr -d ' '; }

next_index() {  # 下一个可用编号 = 现有最大编号 + 1（删过的编号不复用）
  local max=0 i
  for i in $(node_indices); do [ "$i" -gt "$max" ] && max="$i"; done
  echo $((max + 1))
}

find_node_by_domain() {  # find_node_by_domain 域名 -> 编号（找不到返回 1）
  local d="$1" i
  for i in $(node_indices); do
    [ "$(node_field "$i" DOMAIN)" = "$d" ] && { echo "$i"; return 0; }
  done
  return 1
}

port_in_use() {
  local port="$1"
  if command -v ss >/dev/null 2>&1; then
    ss -tln 2>/dev/null | grep -qE "[:.]${port}[[:space:]]"
  elif command -v netstat >/dev/null 2>&1; then
    netstat -tln 2>/dev/null | grep -qE "[:.]${port}[[:space:]]"
  else
    local hex
    hex=$(printf '%04X' "$port")
    grep -qiE "^[[:space:]]*[0-9]+:[[:space:]]+[0-9A-Fa-f]+:${hex}[[:space:]]" /proc/net/tcp /proc/net/tcp6 2>/dev/null
  fi
}

port_in_use_any() {
  local port="$1" hex
  if command -v ss >/dev/null 2>&1; then
    ss -tln 2>/dev/null | grep -qE "[:.]${port}[[:space:]]" && return 0
    ss -uln 2>/dev/null | grep -qE "[:.]${port}[[:space:]]" && return 0
    return 1
  elif command -v netstat >/dev/null 2>&1; then
    netstat -tln 2>/dev/null | grep -qE "[:.]${port}[[:space:]]" && return 0
    netstat -uln 2>/dev/null | grep -qE "[:.]${port}[[:space:]]" && return 0
    return 1
  else
    # 无 ss/netstat 时回退读 /proc/net/*（端口为 16 进制，匹配监听地址字段）
    hex=$(printf '%04X' "$port")
    grep -qiE "^[[:space:]]*[0-9]+:[[:space:]]+[0-9A-Fa-f]+:${hex}[[:space:]]" /proc/net/tcp /proc/net/tcp6 /proc/net/udp /proc/net/udp6 2>/dev/null
  fi
}

show_port_owner() {
  local port="$1" line=""
  if command -v ss >/dev/null 2>&1; then
    line="$(ss -tlnp 2>/dev/null | grep -E "[:.]${port}[[:space:]]" | head -1)"
    [ -z "$line" ] && line="$(ss -ulnp 2>/dev/null | grep -E "[:.]${port}[[:space:]]" | head -1)"
    if [ -n "$line" ]; then echo "  端口 $port 被占用：$line"; else echo "  端口 $port 被占用（查不到占用进程，可能是权限不足）"; fi
  elif command -v netstat >/dev/null 2>&1; then
    line="$(netstat -tlnp 2>/dev/null | grep -E "[:.]${port}[[:space:]]" | head -1)"
    [ -z "$line" ] && line="$(netstat -ulnp 2>/dev/null | grep -E "[:.]${port}[[:space:]]" | head -1)"
    if [ -n "$line" ]; then echo "  端口 $port 被占用：$line"; else echo "  端口 $port 被占用（查不到占用进程）"; fi
  else
    echo "  端口 $port 被占用（本机无 ss/netstat，查不到占用进程）"
  fi
}

port_owner() {  # 打印占用指定端口的进程（ss 能看到时）
  if command -v ss >/dev/null 2>&1; then
    ss -tlnp 2>/dev/null | grep -E "[:.]${1}[[:space:]]" | sed 's/^/    /' || true
  fi
}

ask_cert_method() {
  local ans=""
  while :; do
    echo "证书签发方式（Caddy 自动签 TLS 证书，两种方式选一种）："
    echo ""
    echo "  [1] 默认走 80 端口（HTTP-01）← 默认，直接回车就是 1"
    echo "      最简单，什么都不用准备，装完 Caddy 自己签证书、到期自己续。"
    echo "      前提：80 端口必须空闲，域名要指向这台落地机。"
    echo "      适合：单节点、80 没被占的情况。"
    echo ""
    echo "  [2] DNS 验证（Cloudflare，DNS-01）"
    echo "      不用 80 端口，域名不用改来改去，续签全自动，不怕忘。"
    echo "      前提：域名 DNS 在 Cloudflare，要去 Cloudflare 后台开一个只给改 DNS 权限的 API 令牌。"
    echo "      适合：80 被占了、多节点、怕忘续签的情况。"
    echo ""
    echo "请输入你的选择："
    read_line ans "证书签发方式（1=走 80，2=DNS 验证；默认 1，直接回车就是 1）： "
    [ -z "$ans" ] && ans="1"
    case "$ans" in
      1|http) CERT_METHOD="http"; return 0 ;;
      2|dns) CERT_METHOD="dns"; return 0 ;;
      *) echo "输入不合法：$ans（只能填 1 或 2），请重新输入。" ;;
    esac
  done
}

ask_cf_token() {
  local ans=""
  while :; do
    echo "请填写 Cloudflare API 令牌："
    echo "  去 Cloudflare 后台开：My Profile → API Tokens → Create Token → 用“Edit zone DNS”模板，"
    echo "  只给改 DNS 的权限（Zone:DNS:Edit），不要用 Global API Key。"
    echo "  详细步骤见 CLOUDFLARE_TOKEN.md（新版令牌以 cfut_ 开头）。"
    if [ -t 0 ]; then
      read -rsp "Cloudflare API 令牌（输入时不显示，粘贴后回车）： " ans || true
    elif [ -r /dev/tty ]; then
      read -rsp "Cloudflare API 令牌（输入时不显示，粘贴后回车）： " ans </dev/tty 2>/dev/null || true
    fi
    echo ""
    if [ -z "$ans" ]; then echo "令牌不能为空，请重新输入。"; continue; fi
    # 新版令牌以 cfut_ 开头，旧版是 40 位十六进制；两者都接受，格式不对只提醒、不拦
    case "$ans" in
      cfut_*) ;;
      *) if [ "${#ans}" -ne 40 ]; then echo "提醒：新版令牌以 cfut_ 开头，旧版是 40 位；你填的是 ${#ans} 位，请核对一下（确认无误就继续用，错了证书会签不下来）。"; fi ;;
    esac
    printf -v CLOUDFLARE_API_TOKEN '%s' "$ans"
    return 0
  done
}

ask_port() {
  local varname="$1" prompt_line="$2" default="$3" used="${4:-}"
  local preset="${!varname:-}"
  if [ -n "$preset" ]; then
    if ! valid_port "$preset"; then echo "环境变量 $varname=$preset 不是合法端口（1-65535），请修正后重跑。"; exit 1; fi
    preset="$((10#$preset))"
    if [ "$varname" = "HTTPS_PORT" ] && [ "$preset" = "80" ]; then
      if [ "${CERT_METHOD:-http}" = "dns" ]; then echo "环境变量 HTTPS_PORT 不能是 80（80 是 HTTP 端口，HTTPS 跑在 80 上客户端连不上），请修正后重跑。";
      else echo "环境变量 HTTPS_PORT 不能是 80（80 要留给 Caddy 签证书用），请修正后重跑。"; fi
      exit 1
    fi
    if port_used "$preset" "$used"; then echo "环境变量 $varname=$preset 与前面选的端口重复了，请修正后重跑。"; exit 1; fi
    printf -v "$varname" '%s' "$preset"
    return 0
  fi
  local _tty=0 ans=""
  if [ -t 0 ] || [ -r /dev/tty ]; then _tty=1; fi
  if [ "$_tty" = "0" ] && port_used "$default" "$used"; then
    echo "默认值 $default 与已选端口重复，且当前没有可交互的终端，请用环境变量指定 $varname 后重跑。"; exit 1
  fi
  echo "$prompt_line"
  while :; do
    if port_used "$default" "$used"; then
      read_line ans "默认值 $default 已被占用，请另外输入一个端口（1-65535）： "
      if [ -z "$ans" ]; then echo "默认值 $default 已被占用，直接回车选不了，必须另外输入一个端口。"; continue; fi
    else
      read_line ans "端口（默认 $default，直接回车就是 $default）： "
      if [ -z "$ans" ]; then ans="$default"; fi
    fi
    if ! valid_port "$ans"; then echo "端口不合法：$ans（必须是 1-65535 的数字），请重新输入。"; ans=""; continue; fi
    ans="$((10#$ans))"
    if [ "$varname" = "HTTPS_PORT" ] && [ "$ans" = "80" ]; then
      if [ "${CERT_METHOD:-http}" = "dns" ]; then echo "HTTPS 端口不能是 80（80 是 HTTP 端口，HTTPS 跑在 80 上客户端连不上），请换一个端口。";
      else echo "HTTPS 端口不能是 80（80 要留给 Caddy 签证书用），请换一个端口。"; fi
      ans=""; continue
    fi
    if port_used "$ans" "$used"; then echo "端口 $ans 已经被前面选的端口占用了，请换一个。"; ans=""; continue; fi
    break
  done
  printf -v "$varname" '%s' "$ans"
}

ask_node_port() {
  local varname="$1" prompt_line="$2" default="$3" used="${4:-}"
  while :; do
    ask_port "$varname" "$prompt_line" "$default" "$used"
    if [ "$DRY_RUN" != "1" ] && port_in_use_any "${!varname}"; then
      echo "端口 ${!varname} 已被占用："
      show_port_owner "${!varname}"
      echo "请换一个端口。"
      printf -v "$varname" '%s' ""
      continue
    fi
    break
  done
}

gen_singbox_json() {
  local n="$1"
  local dom tls cm base wsb pv pt pm uv um ut ptr pss phy ptu ss hp tu hy2en cfg
  dom="$(node_field "$n" DOMAIN)"; tls="$(node_field "$n" TLS_MODE)"; cm="$(node_field "$n" CERT_METHOD)"
  base="$(reg_get GLOBAL_BASE_DOMAIN)"
  wsb="$(node_field "$n" WS_BASE)"; pv="$(node_field "$n" PATH_VLESS)"; pt="$(node_field "$n" PATH_TROJAN)"; pm="$(node_field "$n" PATH_VMESS)"
  uv="$(node_field "$n" UUID_VLESS)"; um="$(node_field "$n" UUID_VMESS)"; ut="$(node_field "$n" UUID_TUIC)"
  ptr="$(node_field "$n" PASS_TROJAN)"; pss="$(node_field "$n" PASS_SS)"; phy="$(node_field "$n" PASS_HY2)"; ptu="$(node_field "$n" PASS_TUIC)"
  ss="$(node_field "$n" SS_PORT)"; hp="$(node_field "$n" HY2_PORT)"; tu="$(node_field "$n" TUIC_PORT)"
  hy2en="$(node_field "$n" HY2_ENABLED)"; cfg="$(node_field "$n" CONFIG)"
  local crt key
  if [ "$cm" = "dns" ]; then
    crt="/caddy-data/certificates/acme-v02.api.letsencrypt.org-directory/*.${base}/*.${base}.crt"
    key="/caddy-data/certificates/acme-v02.api.letsencrypt.org-directory/*.${base}/*.${base}.key"
  else
    crt="/caddy-data/certificates/acme-v02.api.letsencrypt.org-directory/${dom}/${dom}.crt"
    key="/caddy-data/certificates/acme-v02.api.letsencrypt.org-directory/${dom}/${dom}.key"
  fi
  local hy2_block="" tuic_block=""
  if [ "$tls" = "1" ] && [ "$hy2en" = "1" ]; then
    hy2_block=",
    { \"type\": \"hysteria2\", \"tag\": \"hy2\", \"listen\": \"0.0.0.0\", \"listen_port\": $hp,
      \"users\": [ { \"password\": \"$phy\" } ],
      \"tls\": { \"enabled\": true, \"server_name\": \"$dom\", \"alpn\": [\"h3\"],
               \"certificate_path\": \"$crt\", \"key_path\": \"$key\" } }"
    tuic_block=",
    { \"type\": \"tuic\", \"tag\": \"tuic\", \"listen\": \"0.0.0.0\", \"listen_port\": $tu,
      \"users\": [ { \"uuid\": \"$ut\", \"password\": \"$ptu\" } ],
      \"congestion_control\": \"bbr\",
      \"tls\": { \"enabled\": true, \"server_name\": \"$dom\", \"alpn\": [\"h3\"],
               \"certificate_path\": \"$crt\", \"key_path\": \"$key\" } }"
  fi
  cat > "$cfg" <<EOF
{
  "log": { "level": "warn" },
  "dns": {
    "servers": [
      { "type": "https", "tag": "doh-cf", "server": "1.1.1.1" },
      { "type": "https", "tag": "doh-google", "server": "8.8.8.8" },
      { "type": "https", "tag": "doh-quad9", "server": "9.9.9.9" },
      { "type": "tls", "tag": "dot-cf", "server": "1.1.1.1" },
      { "type": "tls", "tag": "dot-google", "server": "8.8.8.8" }
    ],
    "final": "doh-cf",
    "strategy": "ipv4_only",
    "disable_cache": false
  },
  "inbounds": [
    { "type": "vless", "tag": "vless-ws", "listen": "0.0.0.0", "listen_port": $wsb,
      "users": [ { "uuid": "$uv" } ],
      "transport": { "type": "ws", "path": "/$pv" } },
    { "type": "trojan", "tag": "trojan-ws", "listen": "0.0.0.0", "listen_port": $((wsb + 1)),
      "users": [ { "password": "$ptr" } ],
      "transport": { "type": "ws", "path": "/$pt" } },
    { "type": "vmess", "tag": "vmess-ws", "listen": "0.0.0.0", "listen_port": $((wsb + 2)),
      "users": [ { "uuid": "$um", "alterId": 0 } ],
      "transport": { "type": "ws", "path": "/$pm" } },
    { "type": "shadowsocks", "tag": "ss", "listen": "0.0.0.0", "listen_port": $ss,
      "method": "2022-blake3-aes-128-gcm", "password": "$pss" }$hy2_block$tuic_block
  ],
  "outbounds": [ { "type": "direct", "tag": "direct" } ],
  "route": {
    "final": "direct",
    "default_domain_resolver": { "server": "doh-cf", "strategy": "ipv4_only" }
  }
}
EOF
}

gen_caddyfile_xray() {
  local i dom cm hp ws intp has_tls=0
  for i in $(node_indices); do
    [ "$(node_field "$i" TLS_MODE)" = "1" ] && has_tls=1
  done
  if [ "$has_tls" = "0" ]; then rm -f Caddyfile; return 0; fi
  : > Caddyfile
  for i in $(node_indices); do
    [ "$(node_field "$i" TLS_MODE)" = "1" ] || continue
    dom="$(node_field "$i" DOMAIN)"
    cm="$(node_field "$i" CERT_METHOD)"
    hp="$(reg_get GLOBAL_HTTPS_PORT)"
    ws="$(node_field "$i" WSPATH)"
    intp="$(node_field "$i" INTERNAL_PORT)"
    {
      echo "$dom:$hp {"
      if [ "$cm" = "dns" ]; then
        echo "    tls {"
        echo "        dns cloudflare {env.CLOUDFLARE_API_TOKEN}"
        echo "    }"
      fi
      echo "    handle /$ws {"
      echo "        reverse_proxy $(svc_name "$i"):$intp"
      echo "    }"
      echo "    handle {"
      echo "        respond \"ok\" 200"
      echo "    }"
      echo "}"
    } >> Caddyfile
  done
}

gen_caddyfile_singbox() {
  local has_tls=0 i
  for i in $(node_indices); do
    [ "$(node_field "$i" TLS_MODE)" = "1" ] && has_tls=1
  done
  if [ "$has_tls" = "0" ]; then rm -f Caddyfile; return 0; fi
  local cm hp base
  cm="$(reg_get GLOBAL_CERT_METHOD)"; hp="$(reg_get GLOBAL_HTTPS_PORT)"; base="$(reg_get GLOBAL_BASE_DOMAIN)"
  if [ "$cm" = "dns" ]; then
    {
      # 泛域名 site：所有 TLS 节点的 WS 路径按路径分流到各自后端
      echo "*.${base}:${hp} {"
      echo "    tls {"
      echo "        dns cloudflare {env.CLOUDFLARE_API_TOKEN}"
      echo "    }"
      for i in $(node_indices); do
        [ "$(node_field "$i" TLS_MODE)" = "1" ] || continue
        echo "    handle /$(node_field "$i" PATH_VLESS) {"
        echo "        reverse_proxy $(svc_name "$i"):$(node_field "$i" WS_BASE)"
        echo "    }"
        echo "    handle /$(node_field "$i" PATH_TROJAN) {"
        echo "        reverse_proxy $(svc_name "$i"):$(( $(node_field "$i" WS_BASE) + 1 ))"
        echo "    }"
        echo "    handle /$(node_field "$i" PATH_VMESS) {"
        echo "        reverse_proxy $(svc_name "$i"):$(( $(node_field "$i" WS_BASE) + 2 ))"
        echo "    }"
      done
      echo "    handle {"
      echo "        respond \"ok\" 200"
      echo "    }"
      echo "}"
      # 有节点直接用父域名本身（如 example.com）：再加一个父域名 site 块（同款 handle）
      local has_apex=0
      for i in $(node_indices); do
        [ "$(node_field "$i" DOMAIN)" = "$base" ] && has_apex=1
      done
      if [ "$has_apex" = "1" ]; then
        echo "${base}:${hp} {"
        echo "    tls {"
        echo "        dns cloudflare {env.CLOUDFLARE_API_TOKEN}"
        echo "    }"
        for i in $(node_indices); do
          [ "$(node_field "$i" TLS_MODE)" = "1" ] || continue
          echo "    handle /$(node_field "$i" PATH_VLESS) {"
          echo "        reverse_proxy $(svc_name "$i"):$(node_field "$i" WS_BASE)"
          echo "    }"
          echo "    handle /$(node_field "$i" PATH_TROJAN) {"
          echo "        reverse_proxy $(svc_name "$i"):$(( $(node_field "$i" WS_BASE) + 1 ))"
          echo "    }"
          echo "    handle /$(node_field "$i" PATH_VMESS) {"
          echo "        reverse_proxy $(svc_name "$i"):$(( $(node_field "$i" WS_BASE) + 2 ))"
          echo "    }"
        done
        echo "    handle {"
        echo "        respond \"ok\" 200"
        echo "    }"
        echo "}"
      fi
    } > Caddyfile
  else
    {
      for i in $(node_indices); do
        [ "$(node_field "$i" TLS_MODE)" = "1" ] || continue
        echo "$(node_field "$i" DOMAIN):${hp} {"
        echo "    handle /$(node_field "$i" PATH_VLESS) {"
        echo "        reverse_proxy $(svc_name "$i"):$(node_field "$i" WS_BASE)"
        echo "    }"
        echo "    handle /$(node_field "$i" PATH_TROJAN) {"
        echo "        reverse_proxy $(svc_name "$i"):$(( $(node_field "$i" WS_BASE) + 1 ))"
        echo "    }"
        echo "    handle /$(node_field "$i" PATH_VMESS) {"
        echo "        reverse_proxy $(svc_name "$i"):$(( $(node_field "$i" WS_BASE) + 2 ))"
        echo "    }"
        echo "    handle {"
        echo "        respond \"ok\" 200"
        echo "    }"
        echo "}"
      done
    } > Caddyfile
  fi
}

gen_compose_xray() {
  local i dom tls_mode cm cfg ctr hp wsp intp has_tls=0
  for i in $(node_indices); do
    [ "$(node_field "$i" TLS_MODE)" = "1" ] && has_tls=1
  done
  {
    echo "services:"
    for i in $(node_indices); do
      cfg="$(node_field "$i" CONFIG)"
      ctr="$(node_field "$i" CONTAINER)"
      tls_mode="$(node_field "$i" TLS_MODE)"
      intp="$(node_field "$i" INTERNAL_PORT)"
      echo "  $(svc_name "$i"):"
      echo "    image: ghcr.io/xtls/xray-core:latest"
      echo "    container_name: $ctr"
      echo "    restart: unless-stopped"
      echo "    logging:"
      echo "      driver: json-file"
      echo "      options:"
      echo "        max-size: \"10m\""
      echo "        max-file: \"3\""
      if [ "$tls_mode" = "0" ]; then
        wsp="$(node_field "$i" WS_PORT)"
        echo "    ports:"
        echo "      - \"$wsp:$intp\""
      fi
      echo "    volumes:"
      echo "      - ./$cfg:/usr/local/etc/xray/config.json:ro"
    done
    if [ "$has_tls" = "1" ]; then
      cm="$(reg_get GLOBAL_CERT_METHOD)"
      hp="$(reg_get GLOBAL_HTTPS_PORT)"
      echo "  caddy:"
      if [ "$cm" = "dns" ]; then
        echo "    image: caddy-cloudflare:latest"
      else
        echo "    image: caddy:2"
      fi
      echo "    container_name: tiktok-caddy"
      echo "    restart: unless-stopped"
      echo "    logging:"
      echo "      driver: json-file"
      echo "      options:"
      echo "        max-size: \"10m\""
      echo "        max-file: \"3\""
      if [ "$cm" = "dns" ]; then
        echo "    environment:"
        echo '      - CLOUDFLARE_API_TOKEN=${CLOUDFLARE_API_TOKEN}'
      fi
      echo "    ports:"
      if [ "$cm" != "dns" ]; then
        echo '      - "80:80"'
      fi
      echo "      - \"$hp:$hp\""
      echo "    volumes:"
      echo "      - ./Caddyfile:/etc/caddy/Caddyfile:ro"
      echo "      - caddy_data:/data"
      echo "      - caddy_config:/config"
      echo "    depends_on:"
      for i in $(node_indices); do
        [ "$(node_field "$i" TLS_MODE)" = "1" ] && echo "      - $(svc_name "$i")"
      done
      echo "volumes:"
      echo "  caddy_data:"
      echo "  caddy_config:"
    fi
  } > docker-compose.yml
}

gen_compose_singbox() {
  local i dom tls_mode cm cfg ctr hp has_tls=0
  for i in $(node_indices); do
    [ "$(node_field "$i" TLS_MODE)" = "1" ] && has_tls=1
  done
  {
    echo "services:"
    for i in $(node_indices); do
      cfg="$(node_field "$i" CONFIG)"
      ctr="$(node_field "$i" CONTAINER)"
      tls_mode="$(node_field "$i" TLS_MODE)"
      echo "  $(svc_name "$i"):"
      echo "    image: ghcr.io/sagernet/sing-box:latest"
      echo "    container_name: $ctr"
      echo "    restart: unless-stopped"
      echo "    logging:"
      echo "      driver: json-file"
      echo "      options:"
      echo "        max-size: \"10m\""
      echo "        max-file: \"3\""
      echo "    command: run -c /etc/sing-box/config.json"
      echo "    volumes:"
      echo "      - ./$cfg:/etc/sing-box/config.json:ro"
      if [ "$tls_mode" = "1" ]; then
        echo "      - caddy_data:/caddy-data:ro"
        echo "    ports:"
        echo "      - \"$(node_field "$i" SS_PORT):$(node_field "$i" SS_PORT)\""
        echo "      - \"$(node_field "$i" SS_PORT):$(node_field "$i" SS_PORT)/udp\""
        if [ "$(node_field "$i" HY2_ENABLED)" = "1" ]; then
          echo "      - \"$(node_field "$i" HY2_PORT):$(node_field "$i" HY2_PORT)/udp\""
          echo "      - \"$(node_field "$i" TUIC_PORT):$(node_field "$i" TUIC_PORT)/udp\""
        fi
      else
        echo "    ports:"
        echo "      - \"$(node_field "$i" VLESS_PORT):$(node_field "$i" WS_BASE)\""
        echo "      - \"$(node_field "$i" TROJAN_PORT):$(( $(node_field "$i" WS_BASE) + 1 ))\""
        echo "      - \"$(node_field "$i" VMESS_PORT):$(( $(node_field "$i" WS_BASE) + 2 ))\""
        echo "      - \"$(node_field "$i" SS_PORT):$(node_field "$i" SS_PORT)\""
        echo "      - \"$(node_field "$i" SS_PORT):$(node_field "$i" SS_PORT)/udp\""
      fi
    done
    if [ "$has_tls" = "1" ]; then
      cm="$(reg_get GLOBAL_CERT_METHOD)"
      hp="$(reg_get GLOBAL_HTTPS_PORT)"
      echo "  caddy:"
      if [ "$cm" = "dns" ]; then
        echo "    image: caddy-cloudflare:latest"
      else
        echo "    image: caddy:2"
      fi
      echo "    container_name: singbox-caddy"
      echo "    restart: unless-stopped"
      echo "    logging:"
      echo "      driver: json-file"
      echo "      options:"
      echo "        max-size: \"10m\""
      echo "        max-file: \"3\""
      if [ "$cm" = "dns" ]; then
        echo "    environment:"
        echo '      - CLOUDFLARE_API_TOKEN=${CLOUDFLARE_API_TOKEN}'
      fi
      echo "    ports:"
      if [ "$cm" != "dns" ]; then
        echo '      - "80:80"'
      fi
      echo "      - \"$hp:$hp\""
      echo "    volumes:"
      echo "      - ./Caddyfile:/etc/caddy/Caddyfile:ro"
      echo "      - caddy_data:/data"
      echo "      - caddy_config:/config"
      echo "volumes:"
      echo "  caddy_data:"
      echo "  caddy_config:"
    fi
  } > docker-compose.yml
  # DNS 验证模式要用的带插件 Caddy Dockerfile（现场编，只编一次）
  if [ "$has_tls" = "1" ] && [ "$(reg_get GLOBAL_CERT_METHOD)" = "dns" ]; then
    cat > Dockerfile.caddy <<'DCEOF'
# 带 Cloudflare DNS 插件的 Caddy：官方 caddy:2-builder 现场编，插件源码来自 github.com/caddy-dns/cloudflare
FROM caddy:2-builder AS builder
RUN xcaddy build --with github.com/caddy-dns/cloudflare
FROM caddy:2
COPY --from=builder /usr/bin/caddy /usr/bin/caddy
DCEOF
  fi
}

write_xray_files() {
  local cfg="$NODE_CONFIG" clash="$NODE_CLASH"
  cat > "$cfg" <<EOF
{
  "log": { "loglevel": "warning" },
  "dns": {
    "servers": [
      { "address": "https+local://1.1.1.1/dns-query" },
      { "address": "https+local://8.8.8.8/dns-query" },
      { "address": "tcp://1.1.1.1", "port": 53 }
    ],
    "queryStrategy": "UseIPv4",
    "disableCache": false
  },
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": $NODE_INTERNAL_PORT,
      "protocol": "vless",
      "settings": {
        "clients": [ { "id": "$NODE_UUID" } ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": { "path": "/$NODE_WSPATH" }
      },
      "sniffing": { "enabled": true, "destOverride": ["http", "tls"] }
    }
  ],
  "outbounds": [ { "protocol": "freedom", "tag": "direct" } ]
}
EOF
  if [ "$NODE_TLS_MODE" = "1" ]; then
    cat > "$clash" <<EOF
port: 7890
socks-port: 7891
allow-lan: false
mode: rule
log-level: info
ipv6: false
dns:
  enable: true
  ipv6: false
  listen: 0.0.0.0:1053
  enhanced-mode: redir-host
  nameserver:
    - https://dns.cloudflare.com/dns-query
    - https://dns.google/dns-query
  proxy-server-nameserver:
    - https://dns.cloudflare.com/dns-query
  nameserver-policy:
    "+.tiktok.com":
      - https://dns.cloudflare.com/dns-query
proxies:
  - name: "TikTok-Node"
    type: vless
    server: $NODE_DOMAIN
    port: $NODE_HTTPS_PORT
    uuid: $NODE_UUID
    tls: true
    servername: $NODE_DOMAIN
    network: ws
    ws-opts:
      path: /$NODE_WSPATH
      headers:
        Host: $NODE_DOMAIN
proxy-groups:
  - name: "PROXY"
    type: select
    proxies:
      - "TikTok-Node"
rules:
  - MATCH,PROXY
EOF
    NODE_LINK="vless://$NODE_UUID@$NODE_DOMAIN:$NODE_HTTPS_PORT?encryption=none&security=tls&type=ws&host=$NODE_DOMAIN&path=%2F$NODE_WSPATH#TikTok-Node"
  else
    cat > "$clash" <<EOF
port: 7890
socks-port: 7891
allow-lan: false
mode: rule
log-level: info
ipv6: false
dns:
  enable: true
  ipv6: false
  listen: 0.0.0.0:1053
  enhanced-mode: redir-host
  nameserver:
    - https://dns.cloudflare.com/dns-query
    - https://dns.google/dns-query
  proxy-server-nameserver:
    - https://dns.cloudflare.com/dns-query
  nameserver-policy:
    "+.tiktok.com":
      - https://dns.cloudflare.com/dns-query
proxies:
  - name: "TikTok-Node"
    type: vless
    server: $NODE_SERVER_IP
    port: $NODE_WS_PORT
    uuid: $NODE_UUID
    tls: false
    network: ws
    ws-opts:
      path: /$NODE_WSPATH
proxy-groups:
  - name: "PROXY"
    type: select
    proxies:
      - "TikTok-Node"
rules:
  - MATCH,PROXY
EOF
    NODE_LINK="vless://$NODE_UUID@$NODE_SERVER_IP:$NODE_WS_PORT?encryption=none&security=none&type=ws&path=%2F$NODE_WSPATH#TikTok-Node"
  fi
  NODE_SUB=$(printf '%s' "$NODE_LINK" | base64 -w0)
}

write_singbox_files() {
  local n="$1"
  local dom tls cm wsb pv pt pm uv um ut ptr pss phy ptu ss hp tu vp tp mp hy2en clash cfg server_ip
  dom="$(node_field "$n" DOMAIN)"; tls="$(node_field "$n" TLS_MODE)"; cm="$(node_field "$n" CERT_METHOD)"
  wsb="$(node_field "$n" WS_BASE)"; pv="$(node_field "$n" PATH_VLESS)"; pt="$(node_field "$n" PATH_TROJAN)"; pm="$(node_field "$n" PATH_VMESS)"
  uv="$(node_field "$n" UUID_VLESS)"; um="$(node_field "$n" UUID_VMESS)"; ut="$(node_field "$n" UUID_TUIC)"
  ptr="$(node_field "$n" PASS_TROJAN)"; pss="$(node_field "$n" PASS_SS)"; phy="$(node_field "$n" PASS_HY2)"; ptu="$(node_field "$n" PASS_TUIC)"
  ss="$(node_field "$n" SS_PORT)"; hp="$(node_field "$n" HY2_PORT)"; tu="$(node_field "$n" TUIC_PORT)"
  vp="$(node_field "$n" VLESS_PORT)"; tp="$(node_field "$n" TROJAN_PORT)"; mp="$(node_field "$n" VMESS_PORT)"
  hy2en="$(node_field "$n" HY2_ENABLED)"; clash="$(node_field "$n" CLASH)"
  server_ip="$(reg_get GLOBAL_SERVER_IP)"
  gen_singbox_json "$n"
  local https_port
  https_port="$(reg_get GLOBAL_HTTPS_PORT)"; [ -n "$https_port" ] || https_port=443

  local vless_port trojan_port vmess_port vless_tls trojan_tls vmess_tls srv
  if [ "$tls" = "1" ]; then
    vless_port="$https_port"; trojan_port="$https_port"; vmess_port="$https_port"
    vless_tls=true; trojan_tls=true; vmess_tls=true; srv="$dom"
  else
    vless_port="$vp"; trojan_port="$tp"; vmess_port="$mp"
    vless_tls=false; trojan_tls=false; vmess_tls=false; srv="$server_ip"
  fi

  cat > "$clash" <<EOF
port: 7890
socks-port: 7891
allow-lan: false
mode: rule
log-level: info
ipv6: false
dns:
  enable: true
  ipv6: false
  listen: 0.0.0.0:1053
  enhanced-mode: redir-host
  nameserver:
    - https://dns.cloudflare.com/dns-query
    - https://dns.google/dns-query
  proxy-server-nameserver:
    - https://dns.cloudflare.com/dns-query
  fallback:
    - https://dns.cloudflare.com/dns-query
    - https://dns.google/dns-query
  fallback-filter:
    geoip-code: CN
    ipcidr:
      - 240.0.0.0/4
      - 0.0.0.0/32
  nameserver-policy:
    "+.tiktok.com":
      - https://dns.cloudflare.com/dns-query
proxies:
  - name: "SingBox-VLESS"
    type: vless
    server: $srv
    port: $vless_port
    uuid: $uv
    tls: $vless_tls
    servername: $srv
    network: ws
    ws-opts:
      path: /$pv
      headers:
        Host: $srv
  - name: "SingBox-Trojan"
    type: trojan
    server: $srv
    port: $trojan_port
    password: $ptr
    sni: $srv
    network: ws
    ws-opts:
      path: /$pt
      headers:
        Host: $srv
  - name: "SingBox-VMess"
    type: vmess
    server: $srv
    port: $vmess_port
    uuid: $um
    alterId: 0
    cipher: auto
    tls: $vmess_tls
    servername: $srv
    network: ws
    ws-opts:
      path: /$pm
      headers:
        Host: $srv
  - name: "SingBox-SS"
    type: ss
    server: $srv
    port: $ss
    cipher: 2022-blake3-aes-128-gcm
    password: $pss
    udp: true
EOF
  if [ "$tls" = "1" ] && [ "$hy2en" = "1" ]; then
    cat >> "$clash" <<EOF
  - name: "SingBox-HY2"
    type: hysteria2
    server: $dom
    port: $hp
    password: $phy
    sni: $dom
    alpn:
      - h3
  - name: "SingBox-TUIC"
    type: tuic
    server: $dom
    port: $tu
    uuid: $ut
    password: $ptu
    congestion-controller: bbr
    alpn:
      - h3
    sni: $dom
EOF
  fi
  local proxy_list='      - "SingBox-VLESS"
      - "SingBox-Trojan"
      - "SingBox-VMess"
      - "SingBox-SS"'
  if [ "$tls" = "1" ] && [ "$hy2en" = "1" ]; then
    proxy_list="$proxy_list
      - \"SingBox-HY2\"
      - \"SingBox-TUIC\""
  fi
  cat >> "$clash" <<EOF
proxy-groups:
  - name: "PROXY"
    type: url-test
    url: http://www.gstatic.com/generate_204
    interval: 300
    tolerance: 50
    proxies:
$proxy_list
  - name: "MANUAL"
    type: select
    proxies:
$proxy_list
rules:
  - MATCH,PROXY
EOF

  # 各协议节点链接
  if [ "$tls" = "1" ]; then
    NODE_LINK_VLESS="vless://$uv@$dom:$https_port?encryption=none&security=tls&type=ws&host=$dom&path=%2F$pv#SingBox-VLESS"
    NODE_LINK_TROJAN="trojan://$ptr@$dom:$https_port?security=tls&type=ws&host=$dom&path=%2F$pt#SingBox-Trojan"
    local vmess_json="{\"v\":\"2\",\"ps\":\"SingBox-VMess\",\"add\":\"$dom\",\"port\":\"$https_port\",\"id\":\"$um\",\"aid\":\"0\",\"scy\":\"auto\",\"net\":\"ws\",\"type\":\"none\",\"host\":\"$dom\",\"path\":\"/$pm\",\"tls\":\"tls\",\"sni\":\"$dom\"}"
  else
    NODE_LINK_VLESS="vless://$uv@$server_ip:$vp?encryption=none&security=none&type=ws&path=%2F$pv#SingBox-VLESS"
    NODE_LINK_TROJAN="trojan://$ptr@$server_ip:$tp?security=none&type=ws&path=%2F$pt#SingBox-Trojan"
    local vmess_json="{\"v\":\"2\",\"ps\":\"SingBox-VMess\",\"add\":\"$server_ip\",\"port\":\"$mp\",\"id\":\"$um\",\"aid\":\"0\",\"scy\":\"auto\",\"net\":\"ws\",\"type\":\"none\",\"host\":\"$server_ip\",\"path\":\"/$pm\",\"tls\":\"\"}"
  fi
  NODE_LINK_VMESS="vmess://$(printf '%s' "$vmess_json" | base64 -w0)"
  local ss_userinfo
  ss_userinfo="$(printf '%s' "2022-blake3-aes-128-gcm:$pss" | base64 -w0 | tr '+/' '-_' | tr -d '=')"
  NODE_LINK_SS="ss://$ss_userinfo@$srv:$ss#SingBox-SS"
  if [ "$tls" = "1" ] && [ "$hy2en" = "1" ]; then
    NODE_LINK_HY2="hysteria2://$phy@$dom:$hp?sni=$dom&alpn=h3#SingBox-HY2"
    NODE_LINK_TUIC="tuic://$ut:$ptu@$dom:$tu?congestion_control=bbr&alpn=h3&sni=$dom#SingBox-TUIC"
  else
    NODE_LINK_HY2=""; NODE_LINK_TUIC=""
  fi
  local sub_links="$NODE_LINK_VLESS
$NODE_LINK_TROJAN
$NODE_LINK_VMESS
$NODE_LINK_SS"
  if [ -n "$NODE_LINK_HY2" ]; then
    sub_links="$sub_links
$NODE_LINK_HY2
$NODE_LINK_TUIC"
  fi
  NODE_SUB="$(printf '%s' "$sub_links" | base64 -w0)"
}

make_qr() {  # make_qr 链接 文件名
  local link="$1" file="$2"
  if command -v qrencode >/dev/null 2>&1; then
    qrencode -o "$file" -s 8 "$link" 2>/dev/null && return 0
  fi
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$link" "$file" <<'PY' 2>/dev/null
import sys
try:
    import qrcode
except ImportError:
    sys.exit(1)
qrcode.make(sys.argv[1]).save(sys.argv[2])
PY
    return $?
  fi
  return 1
}

test_node_ws() {
  local proto="$1" host="$2" port="$3" path="$4" code=""
  code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 -H "Connection: Upgrade" -H "Upgrade: websocket" -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" -H "Sec-WebSocket-Version: 13" "$proto://$host:$port/$path" || true)
  echo "  WS 握手：$proto://$host:$port/$path -> HTTP ${code:-无响应}"
  echo "  （101 = 正常；200 = Caddy 没转给 ${CORE_NAME}；400 = ${CORE_NAME} 拒绝握手）"
}

check_ports() {
  local occupied="" p
  if [ "$TLS_MODE" = "1" ] && [ "${CERT_METHOD:-http}" = "dns" ]; then
    echo "DNS 验证模式：80 端口不用空闲，跳过 80 预检。"
  elif [ "$TLS_MODE" = "1" ] && port_in_use_any 80 && ! port_owned_by_us 80; then
    echo ""
    echo "80 端口已被占用，TLS 模式装不了："
    show_port_owner 80
    echo "Caddy 签证书走 HTTP-01 验证，必须用 80 端口；80 被占就签不下证书。"
    echo "办法：停掉占用 80 的程序再跑，或换一台服务器；"
    echo "也可以重跑并选 [2] DNS 验证（要 Cloudflare API 令牌），80 被占也能装；"
    echo "也可以不带域名跑明文模式（临时测试，HY2/TUIC 不启用）。"
    exit 1
  fi
  local -a want=()
  if [ "$TLS_MODE" = "1" ]; then
    want=( "$HTTPS_PORT" "$SS_PORT" "$HY2_PORT" "$TUIC_PORT" )
  else
    want=( "$VLESS_PORT" "$TROJAN_PORT" "$VMESS_PORT" "$SS_PORT" )
  fi
  for p in "${want[@]}"; do
    if port_in_use_any "$p" && ! port_owned_by_us "$p"; then occupied="$occupied $p"; fi
  done
  if [ -n "$occupied" ]; then
    echo ""
    echo "端口已被占用：$occupied"
    for p in $occupied; do show_port_owner "$p"; done
    if [ "$TLS_MODE" = "1" ]; then
      echo "TLS 模式需要这些端口空闲才能装。如果是 HTTPS 端口被占（比如这台机上已有另一个核心的节点占了 443），"
      echo "重跑安装、把 HTTPS 端口改成高位端口（如 8443）就能装；也可以先停掉占用的程序再跑："
      echo "  如果是本机上另一个核心的旧安装占了端口，先在那个安装目录跑 bash stop.sh 停掉它再重跑"
    else
      echo "明文模式需要这些端口空闲才能装。重跑安装、把被占的端口改成高位端口就能装；"
      echo "也可以先停掉占用它的程序再跑，或换一台服务器。"
    fi
    exit 1
  fi
}

check_ports_add() {
  local occupied="" p
  local -a want=()
  if [ "$TLS_MODE" = "1" ]; then
    want=( "$SS_PORT" "$HY2_PORT" "$TUIC_PORT" )
  else
    want=( "$VLESS_PORT" "$TROJAN_PORT" "$VMESS_PORT" "$SS_PORT" )
  fi
  for p in "${want[@]}"; do
    if port_in_use_any "$p"; then occupied="$occupied $p"; fi
  done
  if [ -n "$occupied" ]; then
    echo ""
    echo "新节点的端口已被占用：$occupied"
    for p in $occupied; do show_port_owner "$p"; done
    echo "办法：重跑 --add-node 并把被占的端口改成高位端口，或先停掉占用它的程序。"
    exit 1
  fi
}

migrate_legacy_xray() {
  [ -f "$REG_FILE" ] && return 0
  [ -f .env ] || return 1
  [ -f config.json ] || { echo "旧版安装记录不完整（找不到 config.json），请先重跑 bash install.sh 装首节点。"; return 1; }
  local _uuid=""
  _uuid="$(grep -oE '"id": *"[^"]+"' config.json | head -1 | cut -d'"' -f4)"
  [ -n "$_uuid" ] || { echo "旧版安装记录不完整（config.json 里找不到 UUID），请先重跑 bash install.sh 装首节点。"; return 1; }
  set -a; . ./.env 2>/dev/null; set +a
  {
    echo "# landing-node 节点注册表（install.sh --add-node / --del-node 维护；不要手动改）"
    echo "GLOBAL_TLS_MODE=${TLS_MODE:-1}"
    echo "GLOBAL_CERT_METHOD=${CERT_METHOD:-http}"
    echo "GLOBAL_HTTPS_PORT=${HTTPS_PORT:-443}"
    echo "GLOBAL_SERVER_IP=${SERVER_IP:-}"
    echo "NODE_1_DOMAIN=${DOMAIN:-}"
    echo "NODE_1_TLS_MODE=${TLS_MODE:-1}"
    echo "NODE_1_CERT_METHOD=${CERT_METHOD:-http}"
    echo "NODE_1_WS_PORT=${WS_PORT:-}"
    echo "NODE_1_INTERNAL_PORT=10000"
    echo "NODE_1_UUID=$_uuid"
    echo "NODE_1_WSPATH=${WSPATH:-}"
    echo "NODE_1_CONFIG=config.json"
    echo "NODE_1_CONTAINER=tiktok-xray"
    echo "NODE_1_CLASH=clash.yaml"
    echo "NODE_1_QR=qr.png"
  } > "$REG_FILE"
  chmod 600 "$REG_FILE"
  echo "已把旧版单节点安装迁移成节点注册表（首节点信息不变）。"
  return 0
}

migrate_legacy_singbox() {
  [ -f .env ] || return 1
  [ -f nodes.conf ] && return 1
  [ -f sing-box.json ] || return 1
  echo "检测到旧版单节点（只有 .env，没有 nodes.conf），正在迁移到节点注册表..."
  set -a; . ./.env; set +a
  local base
  base="$(base_domain "${DOMAIN:-}")"
  python3 - "$PWD/sing-box.json" > /tmp/sb-migrate.env <<'PY' || return 1
import json, os, sys
p = sys.argv[1]
d = json.load(open(p))
by_tag = {i.get("tag"): i for i in d.get("inbounds", [])}
def ws_path(tag):
    t = by_tag.get(tag, {}).get("transport", {})
    return t.get("path", "").lstrip("/")
def first_user(tag, key):
    u = by_tag.get(tag, {}).get("users", [{}])
    return u[0].get(key, "") if u else ""
def listen(tag):
    return str(by_tag.get(tag, {}).get("listen_port", ""))
vals = {
 "UUID_VLESS": first_user("vless-ws", "uuid"),
 "UUID_VMESS": first_user("vmess-ws", "uuid"),
 "UUID_TUIC": first_user("tuic", "uuid"),
 "PASS_TROJAN": first_user("trojan-ws", "password"),
 "PASS_SS": first_user("ss", "password"),
 "PASS_HY2": first_user("hy2", "password"),
 "PASS_TUIC": first_user("tuic", "password"),
 "PATH_VLESS": ws_path("vless-ws"),
 "PATH_TROJAN": ws_path("trojan-ws"),
 "PATH_VMESS": ws_path("vmess-ws"),
 "HY2_ENABLED": "1" if "hy2" in by_tag else "0",
}
for k, v in vals.items():
    print(f"{k}={v}")
PY
  set -a; . /tmp/sb-migrate.env; set +a
  rm -f /tmp/sb-migrate.env
  reg_set "GLOBAL_TLS_MODE" "${TLS_MODE:-1}"
  reg_set "GLOBAL_CERT_METHOD" "${CERT_METHOD:-http}"
  reg_set "GLOBAL_HTTPS_PORT" "${HTTPS_PORT:-443}"
  reg_set "GLOBAL_SERVER_IP" "${SERVER_IP:-}"
  reg_set "GLOBAL_BASE_DOMAIN" "$base"
  reg_set "NODE_1_DOMAIN" "${DOMAIN:-}"
  reg_set "NODE_1_TLS_MODE" "${TLS_MODE:-1}"
  reg_set "NODE_1_CERT_METHOD" "${CERT_METHOD:-http}"
  reg_set "NODE_1_WS_BASE" "10000"
  reg_set "NODE_1_PATH_VLESS" "$PATH_VLESS"
  reg_set "NODE_1_PATH_TROJAN" "$PATH_TROJAN"
  reg_set "NODE_1_PATH_VMESS" "$PATH_VMESS"
  reg_set "NODE_1_UUID_VLESS" "$UUID_VLESS"
  reg_set "NODE_1_UUID_VMESS" "$UUID_VMESS"
  reg_set "NODE_1_UUID_TUIC" "$UUID_TUIC"
  reg_set "NODE_1_PASS_TROJAN" "$PASS_TROJAN"
  reg_set "NODE_1_PASS_SS" "$PASS_SS"
  reg_set "NODE_1_PASS_HY2" "$PASS_HY2"
  reg_set "NODE_1_PASS_TUIC" "$PASS_TUIC"
  reg_set "NODE_1_SS_PORT" "${SS_PORT:-8388}"
  reg_set "NODE_1_HY2_PORT" "${HY2_PORT:-8443}"
  reg_set "NODE_1_TUIC_PORT" "${TUIC_PORT:-8444}"
  reg_set "NODE_1_VLESS_PORT" "${VLESS_PORT:-8080}"
  reg_set "NODE_1_TROJAN_PORT" "${TROJAN_PORT:-8081}"
  reg_set "NODE_1_VMESS_PORT" "${VMESS_PORT:-8082}"
  reg_set "NODE_1_HY2_ENABLED" "$HY2_ENABLED"
  reg_set "NODE_1_CONTAINER" "singbox-node"
  reg_set "NODE_1_CONFIG" "sing-box.json"
  reg_set "NODE_1_CLASH" "clash.yaml"
  chmod 600 "$REG_FILE"
  echo "迁移完成：旧节点已登记为节点 1（${DOMAIN:-明文}）。"
  return 0
}

deploy_xray_node() {
  local mode="$1"
  section "部署节点 $N（${NODE_DOMAIN:-明文}）"
  # 注册（存在则整行重写，不存在则追加；追加的节点不碰已有节点记录）
  reg_set "NODE_${N}_DOMAIN" "$NODE_DOMAIN"
  reg_set "NODE_${N}_TLS_MODE" "$NODE_TLS_MODE"
  reg_set "NODE_${N}_CERT_METHOD" "$NODE_CERT_METHOD"
  reg_set "NODE_${N}_WS_PORT" "$NODE_WS_PORT"
  reg_set "NODE_${N}_INTERNAL_PORT" "$NODE_INTERNAL_PORT"
  reg_set "NODE_${N}_UUID" "$NODE_UUID"
  reg_set "NODE_${N}_WSPATH" "$NODE_WSPATH"
  reg_set "NODE_${N}_CONFIG" "$NODE_CONFIG"
  reg_set "NODE_${N}_CONTAINER" "$NODE_CONTAINER"
  reg_set "NODE_${N}_CLASH" "$NODE_CLASH"
  reg_set "NODE_${N}_QR" "$NODE_QR"
  chmod 600 "$REG_FILE"
  write_node_files
  gen_caddyfile
  gen_compose
  if [ "$mode" = "fresh" ] && [ "$N" = "1" ]; then
    # 首节点安装记录（.env）：域名、模式、端口、WS 路径、证书方式，供 check.sh / stop.sh 读
    # .env 里有 Cloudflare API 令牌时只限本机 root 读（600），绝不在输出里打印
    {
      echo "# landing-node 安装记录（install.sh 生成；重跑时域名与端口默认沿用上次的）"
      echo "DOMAIN=$DOMAIN"
      echo "TLS_MODE=$TLS_MODE"
      if [ "$TLS_MODE" = "1" ]; then
        echo "HTTPS_PORT=$HTTPS_PORT"
        echo "CERT_METHOD=$CERT_METHOD"
        if [ "$CERT_METHOD" = "dns" ]; then echo "CLOUDFLARE_API_TOKEN=$CLOUDFLARE_API_TOKEN"; fi
      else
        echo "WS_PORT=$WS_PORT"
      fi
      echo "SERVER_IP=$SERVER_IP"
      echo "WSPATH=$WSPATH"
    } > .env
    chmod 600 .env
  fi
  if [ "$DRY_RUN" != "1" ]; then
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
      if [ "$NODE_TLS_MODE" = "1" ]; then
        if [ "$NODE_CERT_METHOD" = "http" ]; then ufw allow 80/tcp >/dev/null; fi
        ufw allow "$NODE_HTTPS_PORT"/tcp >/dev/null
      else ufw allow "$NODE_WS_PORT"/tcp >/dev/null; fi
      echo "ufw 已放行对应端口"
    fi
    # DNS 验证模式：先编带 Cloudflare 插件的 Caddy（官方 builder 镜像现场编，只编一次；已有镜像就跳过）
    if [ "$NODE_TLS_MODE" = "1" ] && [ "$NODE_CERT_METHOD" = "dns" ]; then
      if docker image inspect caddy-cloudflare:latest >/dev/null 2>&1; then
        echo "已找到本地 caddy-cloudflare 镜像，跳过编译"
      else
        echo "正在编译带 Cloudflare 插件的 Caddy（官方 builder 镜像现场编，第一次约 1-3 分钟）..."
        docker build -t caddy-cloudflare:latest -f Dockerfile.caddy . || { echo "Caddy 编译失败：检查本机能否访问 Docker Hub 与 proxy.golang.org，或稍后重跑"; exit 1; }
        echo "Caddy 编译完成：caddy-cloudflare:latest"
      fi
    fi
    if [ "$mode" = "fresh" ]; then
      # 只重建本节点服务（重跑换了 UUID/路径时旧容器必须重建才生效）；
      # TLS 时再起 Caddy（已在跑就 reload 新 Caddyfile，不重建，已有其他节点不断连）
      docker compose up -d --force-recreate "$(svc_name "$N")"
      if [ "$NODE_TLS_MODE" = "1" ]; then
        docker compose up -d caddy
        caddy_reload
      fi
      sleep 3
    else
      docker compose up -d
      sleep 3
      if [ "$NODE_TLS_MODE" = "1" ]; then caddy_reload; fi
    fi
    if [ "$NODE_TLS_MODE" = "1" ]; then
      CODE=""
      for i in $(seq 1 30); do
        CODE=$(curl -s -o /dev/null -w "%{http_code}" "https://$NODE_DOMAIN:$NODE_HTTPS_PORT/" || true)
        [ "$CODE" = "200" ] && break
        sleep 3
      done
      echo "  首页：https://$NODE_DOMAIN:$NODE_HTTPS_PORT/ -> HTTP ${CODE:-无响应}"
      echo "  （200 = Caddy 与证书正常）"
      test_node_ws "https" "$NODE_DOMAIN" "$NODE_HTTPS_PORT" "$NODE_WSPATH"
    else
      test_node_ws "http" "$NODE_SERVER_IP" "$NODE_WS_PORT" "$NODE_WSPATH"
    fi
  else
    echo "[dry-run] 跳过启动与拨测"
  fi
  # 二维码（qrencode 没有时尝试安装；实在没有就提示手动生成）
  QR_OK=0
  if ! command -v qrencode >/dev/null 2>&1 && [ "$DRY_RUN" != "1" ]; then
    echo "本机没有 qrencode，尝试安装..."
    if command -v apt-get >/dev/null 2>&1; then
      timeout 180 apt-get update -qq >/dev/null 2>&1 || true
      timeout 180 apt-get install -y -qq qrencode >/dev/null 2>&1 || true
    elif command -v yum >/dev/null 2>&1; then
      timeout 180 yum install -y -q qrencode >/dev/null 2>&1 || true
    fi
  fi
  if make_qr "$NODE_LINK" "$NODE_QR"; then QR_OK=1; fi
  if [ "$mode" = "fresh" ]; then
    section "部署完成"
  else
    section "节点 $N 追加完成"
  fi
  if [ "$NODE_TLS_MODE" = "1" ]; then
    if [ "$NODE_CERT_METHOD" = "dns" ]; then
      echo "  证书方式：DNS 验证（Cloudflare），续签全自动，不用管 80 端口"
    else
      echo "  证书方式：默认走 80（HTTP-01）；证书剩余天数用 bash check.sh 看"
    fi
  fi
  echo ""
  echo "  节点链接（小火箭/Clash 可直接导入）："
  echo "$NODE_LINK"
  echo ""
  echo "  订阅内容（base64）："
  echo "$NODE_SUB"
  echo ""
  echo "  Clash 配置已生成：$(pwd)/$NODE_CLASH"
  echo "  （DNS 全走代理、禁 IPv6，直接导入 Clash/Stash）"
  if [ "$QR_OK" = "1" ]; then
    echo "  二维码已生成：$(pwd)/$NODE_QR"
    echo "  （下载到手机扫码即可）"
  else
    echo "  本机没生成二维码：把上面的节点链接发给 Muse，它会回你二维码图片。"
  fi
  echo ""
  echo "  注意：链接里的 UUID 就是密码，不要外传。"
}

deploy_singbox_node() {
  local mode="$1"
  local n="$N"
  section "部署节点 $n（${NODE_DOMAIN:-明文}）"
  # 注册（存在则整行重写，不存在则追加；追加的节点不碰已有节点记录）
  reg_set "NODE_${n}_DOMAIN" "$NODE_DOMAIN"
  reg_set "NODE_${n}_TLS_MODE" "$NODE_TLS_MODE"
  reg_set "NODE_${n}_CERT_METHOD" "$NODE_CERT_METHOD"
  reg_set "NODE_${n}_WS_BASE" "$NODE_WS_BASE"
  reg_set "NODE_${n}_PATH_VLESS" "$NODE_PATH_VLESS"
  reg_set "NODE_${n}_PATH_TROJAN" "$NODE_PATH_TROJAN"
  reg_set "NODE_${n}_PATH_VMESS" "$NODE_PATH_VMESS"
  reg_set "NODE_${n}_UUID_VLESS" "$NODE_UUID_VLESS"
  reg_set "NODE_${n}_UUID_VMESS" "$NODE_UUID_VMESS"
  reg_set "NODE_${n}_UUID_TUIC" "$NODE_UUID_TUIC"
  reg_set "NODE_${n}_PASS_TROJAN" "$NODE_PASS_TROJAN"
  reg_set "NODE_${n}_PASS_SS" "$NODE_PASS_SS"
  reg_set "NODE_${n}_PASS_HY2" "$NODE_PASS_HY2"
  reg_set "NODE_${n}_PASS_TUIC" "$NODE_PASS_TUIC"
  reg_set "NODE_${n}_SS_PORT" "$NODE_SS_PORT"
  reg_set "NODE_${n}_HY2_PORT" "$NODE_HY2_PORT"
  reg_set "NODE_${n}_TUIC_PORT" "$NODE_TUIC_PORT"
  reg_set "NODE_${n}_VLESS_PORT" "$NODE_VLESS_PORT"
  reg_set "NODE_${n}_TROJAN_PORT" "$NODE_TROJAN_PORT"
  reg_set "NODE_${n}_VMESS_PORT" "$NODE_VMESS_PORT"
  reg_set "NODE_${n}_HY2_ENABLED" "$NODE_HY2_ENABLED"
  reg_set "NODE_${n}_CONTAINER" "$NODE_CONTAINER"
  reg_set "NODE_${n}_CONFIG" "$NODE_CONFIG"
  reg_set "NODE_${n}_CLASH" "$NODE_CLASH"
  chmod 600 "$REG_FILE"
  write_node_files "$n"
  gen_caddyfile
  gen_compose
  if [ "$mode" = "fresh" ] && [ "$n" = "1" ]; then
    # 首节点安装记录（.env）：域名、模式、证书方式与最终端口（check.sh / stop.sh 从这里读实际端口与方式）
    # .env 里有 Cloudflare API 令牌时只限本机 root 读（600），绝不在输出里打印
    {
      echo "DOMAIN=$DOMAIN"
      echo "SERVER_IP=$SERVER_IP"
      echo "TLS_MODE=$TLS_MODE"
      echo "CERT_METHOD=${CERT_METHOD:-}"
      if [ "$TLS_MODE" = "1" ] && [ "$CERT_METHOD" = "dns" ]; then
        echo "CLOUDFLARE_API_TOKEN=$CLOUDFLARE_API_TOKEN"
      fi
      echo "HTTPS_PORT=$HTTPS_PORT"
      echo "SS_PORT=$SS_PORT"
      echo "HY2_PORT=$HY2_PORT"
      echo "TUIC_PORT=$TUIC_PORT"
      echo "VLESS_PORT=$VLESS_PORT"
      echo "TROJAN_PORT=$TROJAN_PORT"
      echo "VMESS_PORT=$VMESS_PORT"
    } > .env
    chmod 600 .env
  fi
  if [ "$DRY_RUN" != "1" ]; then
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
      if [ "$NODE_TLS_MODE" = "1" ]; then
        if [ "$NODE_CERT_METHOD" = "http" ]; then ufw allow 80/tcp >/dev/null; fi
        ufw allow "$NODE_HTTPS_PORT"/tcp >/dev/null
        ufw allow "$NODE_SS_PORT"/tcp >/dev/null; ufw allow "$NODE_SS_PORT"/udp >/dev/null
        if [ "$NODE_HY2_ENABLED" = "1" ]; then ufw allow "$NODE_HY2_PORT"/udp >/dev/null; ufw allow "$NODE_TUIC_PORT"/udp >/dev/null; fi
      else
        ufw allow "$NODE_VLESS_PORT"/tcp >/dev/null; ufw allow "$NODE_TROJAN_PORT"/tcp >/dev/null; ufw allow "$NODE_VMESS_PORT"/tcp >/dev/null
        ufw allow "$NODE_SS_PORT"/tcp >/dev/null; ufw allow "$NODE_SS_PORT"/udp >/dev/null
      fi
      echo "ufw 已放行对应端口"
    fi
    # DNS 验证模式：先编带 Cloudflare 插件的 Caddy（官方 builder 镜像现场编，只编一次；已有镜像就跳过）
    if [ "$NODE_TLS_MODE" = "1" ] && [ "$NODE_CERT_METHOD" = "dns" ]; then
      if docker image inspect caddy-cloudflare:latest >/dev/null 2>&1; then
        echo "已找到本地 caddy-cloudflare 镜像，跳过编译"
      else
        echo "正在编译带 Cloudflare 插件的 Caddy（官方 builder 镜像现场编，第一次约 1-3 分钟）..."
        docker build -t caddy-cloudflare:latest -f Dockerfile.caddy . || { echo "Caddy 编译失败：检查本机能否访问 Docker Hub 与 proxy.golang.org，或稍后重跑"; exit 1; }
        echo "Caddy 编译完成：caddy-cloudflare:latest"
      fi
    fi
    # 先起 Caddy（新 Caddyfile 生效，HY2/TUIC 要用 Caddy 签下的证书）；已有其他节点时只 reload，不重建
    if [ "$NODE_TLS_MODE" = "1" ]; then
      if [ "$mode" = "fresh" ]; then
        docker compose up -d caddy
        caddy_reload
      else
        caddy_reload
      fi
      # 等证书（最多 180 秒）：HTTP-01 等本节点域名的证书；DNS-01 等泛域名证书
      local cert_file=""
      if [ "$NODE_CERT_METHOD" = "dns" ]; then
        cert_file="/data/caddy/certificates/acme-v02.api.letsencrypt.org-directory/*.$(reg_get GLOBAL_BASE_DOMAIN)/*.$(reg_get GLOBAL_BASE_DOMAIN).crt"
      else
        cert_file="/data/caddy/certificates/acme-v02.api.letsencrypt.org-directory/$NODE_DOMAIN/$NODE_DOMAIN.crt"
      fi
      echo "等 Caddy 签证书（最多 180 秒）..."
      local cert_ok=0
      for i in $(seq 1 36); do
        if docker exec "$CADDY_CTR" test -f "$cert_file" 2>/dev/null; then cert_ok=1; break; fi
        sleep 5
      done
      if [ "$cert_ok" = "1" ]; then
        echo "证书已就绪，HY2/TUIC 启用"
      else
        echo "警告：180 秒内没拿到证书，HY2/TUIC 暂不启用（VLESS/Trojan/VMess/SS 不受影响）；重跑一次本命令可补上（会换一套新节点）"
        NODE_HY2_ENABLED=0
        reg_set "NODE_${n}_HY2_ENABLED" "0"
        gen_singbox_json "$n"
        gen_compose
      fi
    fi
    # 只起/重建本节点服务（已有其他节点时不碰它们的容器）
    if [ "$mode" = "fresh" ]; then
      docker compose up -d --force-recreate "$(svc_name "$n")"
    else
      docker compose up -d "$(svc_name "$n")"
    fi
    sleep 3
    if [ "$NODE_TLS_MODE" = "1" ]; then
      local code=""
      for i in $(seq 1 30); do
        code=$(curl -s -o /dev/null -w "%{http_code}" "https://$NODE_DOMAIN:$NODE_HTTPS_PORT/" || true)
        [ "$code" = "200" ] && break
        sleep 3
      done
      echo "  首页：https://$NODE_DOMAIN:$NODE_HTTPS_PORT/ -> HTTP ${code:-无响应}"
      echo "  （200 = Caddy 与证书正常）"
      test_node_ws "https" "$NODE_DOMAIN" "$NODE_HTTPS_PORT" "$NODE_PATH_VLESS"
      test_node_ws "https" "$NODE_DOMAIN" "$NODE_HTTPS_PORT" "$NODE_PATH_TROJAN"
      test_node_ws "https" "$NODE_DOMAIN" "$NODE_HTTPS_PORT" "$NODE_PATH_VMESS"
      echo "  SS / HY2 / TUIC 端口（$NODE_SS_PORT / $NODE_HY2_PORT / $NODE_TUIC_PORT）需用客户端实测"
      echo "  （非 HTTP 端口，curl 测不了）"
    else
      test_node_ws "http" "$NODE_SERVER_IP" "$NODE_VLESS_PORT" "$NODE_PATH_VLESS"
      test_node_ws "http" "$NODE_SERVER_IP" "$NODE_TROJAN_PORT" "$NODE_PATH_TROJAN"
      test_node_ws "http" "$NODE_SERVER_IP" "$NODE_VMESS_PORT" "$NODE_PATH_VMESS"
    fi
  else
    echo "[dry-run] 跳过启动与拨测"
  fi
  # 二维码（qrencode 没有时尝试安装；实在没有就提示手动生成）
  local qr_ok=0 qr_prefix=""
  if [ "$n" = "1" ]; then qr_prefix="qr-"; else qr_prefix="qr-$n-"; fi
  if ! command -v qrencode >/dev/null 2>&1 && [ "$DRY_RUN" != "1" ]; then
    echo "本机没有 qrencode，尝试安装..."
    if command -v apt-get >/dev/null 2>&1; then
      timeout 180 apt-get update -qq >/dev/null 2>&1 || true
      timeout 180 apt-get install -y -qq qrencode >/dev/null 2>&1 || true
    elif command -v yum >/dev/null 2>&1; then
      timeout 180 yum install -y -q qrencode >/dev/null 2>&1 || true
    fi
  fi
  if make_qr "$NODE_LINK_VLESS" "${qr_prefix}vless.png" && make_qr "$NODE_LINK_TROJAN" "${qr_prefix}trojan.png" && make_qr "$NODE_LINK_VMESS" "${qr_prefix}vmess.png" && make_qr "$NODE_LINK_SS" "${qr_prefix}ss.png"; then
    qr_ok=1
    if [ -n "$NODE_LINK_HY2" ]; then
      make_qr "$NODE_LINK_HY2" "${qr_prefix}hy2.png" && make_qr "$NODE_LINK_TUIC" "${qr_prefix}tuic.png" || qr_ok=0
    fi
  fi
  if [ "$mode" = "fresh" ]; then
    section "部署完成"
  else
    section "追加完成"
  fi
  if [ "$NODE_TLS_MODE" = "1" ]; then
    if [ "$NODE_CERT_METHOD" = "dns" ]; then
      echo "  证书方式：DNS 验证（Cloudflare），泛域名证书 *.$(reg_get GLOBAL_BASE_DOMAIN)"
      echo "  续签全自动，不用管 80 端口"
    else
      echo "  证书方式：默认走 80（HTTP-01）；证书剩余天数用 bash check.sh 看"
    fi
  fi
  echo ""
  echo "  节点链接（小火箭/Clash 可直接导入）："
  echo "  VLESS："
  echo "$NODE_LINK_VLESS"
  echo "  Trojan："
  echo "$NODE_LINK_TROJAN"
  echo "  VMess："
  echo "$NODE_LINK_VMESS"
  echo "  SS："
  echo "$NODE_LINK_SS"
  if [ -n "$NODE_LINK_HY2" ]; then
    echo "  HY2："
    echo "$NODE_LINK_HY2"
    echo "  TUIC："
    echo "$NODE_LINK_TUIC"
  fi
  echo ""
  echo "  订阅内容（base64，含全部可用协议）："
  echo "$NODE_SUB"
  echo ""
  echo "  Clash 配置已生成：$(pwd)/$(node_field "$n" CLASH)"
  echo "  （DNS 全走代理、禁 IPv6，直接导入 Clash/Stash）"
  if [ "$qr_ok" = "1" ]; then
    echo "  二维码已生成，位置：$(pwd)/（下载到手机扫码即可）"
    echo "  ${qr_prefix}vless.png  ${qr_prefix}trojan.png  ${qr_prefix}vmess.png  ${qr_prefix}ss.png"
    if [ -n "$NODE_LINK_HY2" ]; then
      echo "  ${qr_prefix}hy2.png  ${qr_prefix}tuic.png（TLS 模式）"
    fi
  else
    echo "  本机没生成二维码：把上面的节点链接发给 Muse，它会回你二维码图片。"
  fi
  echo ""
  echo "  注意：链接里的 UUID/密码等同于密码，不要外传。"
}

add_node_flow_xray() {
  section "追加节点"
  if [ ! -f "$REG_FILE" ]; then
    migrate_legacy || { echo "还没装过节点：先跑 bash install.sh 装第一个节点，再追加。"; exit 1; }
  fi
  local g_tls g_cm g_hp g_ip
  g_tls="$(reg_get GLOBAL_TLS_MODE)"; [ -n "$g_tls" ] || g_tls=1
  g_cm="$(reg_get GLOBAL_CERT_METHOD)"; [ -n "$g_cm" ] || g_cm=http
  g_hp="$(reg_get GLOBAL_HTTPS_PORT)"; [ -n "$g_hp" ] || g_hp=443
  g_ip="$(reg_get GLOBAL_SERVER_IP)"
  if [ -z "$g_ip" ] && [ -f .env ]; then set -a; . ./.env 2>/dev/null; set +a; g_ip="${SERVER_IP:-}"; fi
  N="$(next_index)"
  NODE_TLS_MODE="$g_tls"
  NODE_CERT_METHOD="$g_cm"
  NODE_HTTPS_PORT="$g_hp"
  NODE_SERVER_IP="$g_ip"
  NODE_INTERNAL_PORT=$((10000 + N - 1))
  if [ "$N" = "1" ]; then
    NODE_CONFIG="config.json"; NODE_CONTAINER="tiktok-xray"; NODE_CLASH="clash.yaml"; NODE_QR="qr.png"
  else
    NODE_CONFIG="config-$N.json"; NODE_CONTAINER="tiktok-xray-$N"; NODE_CLASH="clash-$N.yaml"; NODE_QR="qr-$N.png"
  fi
  if [ "$NODE_TLS_MODE" = "1" ]; then
    echo "再加一个节点（和已有节点共用一个 Caddy 的 $NODE_HTTPS_PORT，按域名分流）："
    echo "  各节点 UUID、WS 路径、后端容器都独立。"
    echo "  域名解析：推荐先把泛域名 *.example.com 解析到这台机（一条 A 记录）。"
    echo "  以后加节点不用再动 DNS。"
    echo "  证书方式沿用首次安装选的，追加时不再重问："
    echo "  $([ "$NODE_CERT_METHOD" = "dns" ] && echo "DNS 验证（Cloudflare），每个子域名自动签" || echo "默认走 80（HTTP-01），每个子域名自动签")"
    # 新域名可用环境变量 ADD_DOMAIN 预设，或 --add-node 后面直接跟（只认追加参数，不认首装的命令行域名）
    NEW_DOMAIN="${ADD_DOMAIN:-${ADD_ARG:-}}"
    ADD_ARG=""
    while :; do
      echo "请填写新节点的子域名："
      ask "新节点子域名（例如 us2.example.com，必须是已解析到本机的子域名）： " NEW_DOMAIN
      if [ -z "$NEW_DOMAIN" ]; then echo "子域名不能为空，请重新输入。"; NEW_DOMAIN=""; continue; fi
      if ! valid_domain "$NEW_DOMAIN"; then echo "子域名格式不对：$NEW_DOMAIN（例如 us2.example.com），请重新输入。"; NEW_DOMAIN=""; continue; fi
      if find_node_by_domain "$NEW_DOMAIN" >/dev/null 2>&1; then echo "子域名 $NEW_DOMAIN 已经被节点占用了，请换一个子域名。"; NEW_DOMAIN=""; continue; fi
      break
    done
    NODE_DOMAIN="$NEW_DOMAIN"
    NODE_WS_PORT=""
    echo "新节点域名：$NODE_DOMAIN（TLS 模式，共用 $NODE_HTTPS_PORT 端口）"
  else
    echo "再加一个节点（明文模式，不用域名；各节点用不同 WS 端口，UUID、WS 路径、后端容器都独立）："
    # 新端口可用环境变量 ADD_WS_PORT 预设；默认前一节点端口 +1（如 8080、8081）
    local prev_ws=8080
    prev_ws="$(node_field $((N - 1)) WS_PORT)"; [ -n "$prev_ws" ] || prev_ws=8080
    local sugg_ws=$((prev_ws + 1))
    NEW_WS_PORT="${ADD_WS_PORT:-}"
    while :; do
      echo "请填写新节点的 WS 端口："
      ask_port "新节点 WS 端口（默认 $sugg_ws，直接回车就是 $sugg_ws；被占或和已有节点重复时会重问）： " NEW_WS_PORT "$sugg_ws"
      NEW_WS_PORT="${NEW_WS_PORT:-$sugg_ws}"
      local clash=0 i
      for i in $(node_indices); do
        [ "$(node_field "$i" WS_PORT)" = "$NEW_WS_PORT" ] && clash=1
      done
      if [ "$clash" = "1" ]; then echo "端口 $NEW_WS_PORT 已经被已有节点用了，请换一个。"; NEW_WS_PORT=""; continue; fi
      if [ "$DRY_RUN" != "1" ] && port_in_use "$NEW_WS_PORT"; then echo "端口 $NEW_WS_PORT 已被占用："; port_owner "$NEW_WS_PORT"; echo "请换一个端口。"; NEW_WS_PORT=""; continue; fi
      break
    done
    NODE_WS_PORT="$NEW_WS_PORT"
    NODE_DOMAIN=""
    echo "新节点 WS 端口：$NODE_WS_PORT（明文模式）"
  fi
  NODE_UUID="$(cat /proc/sys/kernel/random/uuid)"
  NODE_WSPATH="$(tr -dc 'a-z0-9' </dev/urandom | head -c 16 || true)"
  echo "UUID: $NODE_UUID"
  echo "WS 路径: /$NODE_WSPATH"
  deploy_node add
}

add_node_flow_singbox() {
  migrate_legacy || true
  if [ ! -f "$REG_FILE" ]; then
    echo "还没装过节点：请先跑 bash install.sh 装第一个节点，再用 --add-node 追加。"
    exit 1
  fi
  local g_tls g_cm g_hp g_ip g_base
  g_tls="$(reg_get GLOBAL_TLS_MODE)"; [ -n "$g_tls" ] || g_tls=1
  g_cm="$(reg_get GLOBAL_CERT_METHOD)"; [ -n "$g_cm" ] || g_cm=http
  g_hp="$(reg_get GLOBAL_HTTPS_PORT)"; [ -n "$g_hp" ] || g_hp=443
  g_ip="$(reg_get GLOBAL_SERVER_IP)"
  g_base="$(reg_get GLOBAL_BASE_DOMAIN)"
  # 清掉上一个节点残留的 NODE_* 端口变量：ask_port 会把已设置的同名变量当环境变量预设，
  # 同一进程内装完首节点再追问追加时，节点 1 的端口会误当成新节点的预设而报错退出
  unset NODE_SS_PORT NODE_HY2_PORT NODE_TUIC_PORT NODE_VLESS_PORT NODE_TROJAN_PORT NODE_VMESS_PORT
  N="$(next_index)"
  NODE_TLS_MODE="$g_tls"; NODE_CERT_METHOD="$g_cm"; NODE_HTTPS_PORT="$g_hp"; NODE_SERVER_IP="$g_ip"
  NODE_HY2_ENABLED=1
  NODE_WS_BASE=$((10000 + (N - 1) * 10))

  if [ "$g_tls" = "1" ]; then
    if [ "$g_cm" = "dns" ]; then
      section "追加节点 $N（TLS 模式）"
      echo "  证书方式沿用首次安装的选择：DNS 验证（Cloudflare），泛域名证书 *.${g_base} 通吃所有子域名"
    else
      section "追加节点 $N（TLS 模式）"
      echo "  证书方式沿用首次安装的选择：默认走 80（HTTP-01），Caddy 逐个子域名自动签"
    fi
    echo "每个节点一个子域名；推荐先在 DNS 加一条泛域名 A 记录："
    echo "  *.${g_base} -> 落地机 IP，一次配好，以后加节点不用再改 DNS。"
    local sugg="us${N}.${g_base}"
    local new_domain="${MODE_ARG:-}"
    while :; do
      if [ -z "$new_domain" ]; then
        echo "请填写新节点的子域名："
        read_line new_domain "新节点域名（默认 $sugg，直接回车就是 $sugg）： "
        [ -z "$new_domain" ] && new_domain="$sugg"
      fi
      if ! valid_domain "$new_domain"; then echo "域名不合法：$new_domain"; echo "要是小写字母/数字/点/连字符，至少一个点，请重新输入。"; new_domain=""; continue; fi
      if find_node_by_domain "$new_domain" >/dev/null 2>&1; then echo "域名 $new_domain 已经被节点占用了，请换一个子域名。"; new_domain=""; continue; fi
      if [ "$g_cm" = "dns" ]; then
        case "$new_domain" in
          "$g_base"|*".$g_base") ;;
          *) echo "DNS 验证模式下新节点域名必须是泛域名证书覆盖的范围（$g_base 或它下面的子域名）"; echo "$new_domain 不在范围内，请换一个。"; new_domain=""; continue ;;
        esac
      fi
      break
    done
    NODE_DOMAIN="$new_domain"
  else
    section "追加节点 $N（明文模式）"
    echo "  不用域名，各节点用不同 WS 端口"
    NODE_DOMAIN=""
  fi

  # 已有节点占用的直连端口（追加时新端口不能撞）
  local used_ports="" i
  for i in $(node_indices); do
    used_ports="$used_ports $(node_field "$i" SS_PORT) $(node_field "$i" HY2_PORT) $(node_field "$i" TUIC_PORT) $(node_field "$i" VLESS_PORT) $(node_field "$i" TROJAN_PORT) $(node_field "$i" VMESS_PORT)"
  done
  local prev=$((N - 1))
  if [ "$g_tls" = "1" ]; then
    echo "直连端口默认在前一节点端口上加 10000（SS/HY2/TUIC 各节点必须不同）；直接回车就是默认值。"
    ask_node_port NODE_SS_PORT "请填写新节点 Shadowsocks 端口：" "$(( $(node_field "$prev" SS_PORT) + 10000 ))" "$used_ports"
    used_ports="$used_ports $NODE_SS_PORT"
    ask_node_port NODE_HY2_PORT "请填写新节点 Hysteria2 端口：" "$(( $(node_field "$prev" HY2_PORT) + 10000 ))" "$used_ports"
    used_ports="$used_ports $NODE_HY2_PORT"
    ask_node_port NODE_TUIC_PORT "请填写新节点 TUIC 端口：" "$(( $(node_field "$prev" TUIC_PORT) + 10000 ))" "$used_ports"
    used_ports="$used_ports $NODE_TUIC_PORT"
    NODE_VLESS_PORT="$g_hp"; NODE_TROJAN_PORT="$g_hp"; NODE_VMESS_PORT="$g_hp"
  else
    echo "明文端口默认在前一节点端口上加 10000（各节点必须不同）；直接回车就是默认值。"
    ask_node_port NODE_VLESS_PORT "请填写新节点 VLESS 端口：" "$(( $(node_field "$prev" VLESS_PORT) + 10000 ))" "$used_ports"
    used_ports="$used_ports $NODE_VLESS_PORT"
    ask_node_port NODE_TROJAN_PORT "请填写新节点 Trojan 端口：" "$(( $(node_field "$prev" TROJAN_PORT) + 10000 ))" "$used_ports"
    used_ports="$used_ports $NODE_TROJAN_PORT"
    ask_node_port NODE_VMESS_PORT "请填写新节点 VMess 端口：" "$(( $(node_field "$prev" VMESS_PORT) + 10000 ))" "$used_ports"
    used_ports="$used_ports $NODE_VMESS_PORT"
    ask_node_port NODE_SS_PORT "请填写新节点 Shadowsocks 端口：" "$(( $(node_field "$prev" SS_PORT) + 10000 ))" "$used_ports"
    used_ports="$used_ports $NODE_SS_PORT"
    NODE_HY2_PORT="$(( $(node_field "$prev" HY2_PORT) + 10000 ))"; NODE_TUIC_PORT="$(( $(node_field "$prev" TUIC_PORT) + 10000 ))"
  fi
  # 最终预检（覆盖环境变量预设的端口）
  TLS_MODE="$g_tls"; HTTPS_PORT="$g_hp"; SS_PORT="$NODE_SS_PORT"; HY2_PORT="$NODE_HY2_PORT"; TUIC_PORT="$NODE_TUIC_PORT"
  VLESS_PORT="$NODE_VLESS_PORT"; TROJAN_PORT="$NODE_TROJAN_PORT"; VMESS_PORT="$NODE_VMESS_PORT"
  CERT_METHOD="$g_cm"
  check_ports_add

  # 凭据（每次追加都生成全新一套，不碰已有节点）
  NODE_UUID_VLESS="$(cat /proc/sys/kernel/random/uuid)"
  NODE_UUID_VMESS="$(cat /proc/sys/kernel/random/uuid)"
  NODE_UUID_TUIC="$(cat /proc/sys/kernel/random/uuid)"
  NODE_PASS_TROJAN="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 16 || true)"
  NODE_PASS_SS="$(head -c 16 /dev/urandom | base64 -w0)" # 2022-blake3 密码必须是 base64 编码的 16 字节密钥
  NODE_PASS_HY2="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 16 || true)"
  NODE_PASS_TUIC="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 16 || true)"
  NODE_PATH_VLESS="$(tr -dc 'a-z0-9' </dev/urandom | head -c 16 || true)"
  NODE_PATH_TROJAN="$(tr -dc 'a-z0-9' </dev/urandom | head -c 16 || true)"
  NODE_PATH_VMESS="$(tr -dc 'a-z0-9' </dev/urandom | head -c 16 || true)"
  if [ "$N" = "1" ]; then
    NODE_CONFIG="sing-box.json"; NODE_CONTAINER="singbox-node"; NODE_CLASH="clash.yaml"
  else
    NODE_CONFIG="sing-box-$N.json"; NODE_CONTAINER="singbox-node-$N"; NODE_CLASH="clash-$N.yaml"
  fi
  echo "新节点凭据已生成（UUID 与 WS 路径全新，与已有节点不同）。"
  deploy_node add
  if [ "$DRY_RUN" != "1" ]; then
    echo ""
    bash check.sh || true
  fi
}

del_node_flow_xray() {
  section "删除单个节点"
  if [ ! -f "$REG_FILE" ]; then
    migrate_legacy || { echo "还没装过节点：没有可删除的节点。"; exit 1; }
  fi
  local total i
  total="$(node_count)"
  if [ "$total" = "0" ]; then echo "没有可删除的节点。"; exit 1; fi
  echo "本机已有节点（共 $total 个）："
  for i in $(node_indices); do
    local d u hp wsp
    d="$(node_field "$i" DOMAIN)"; u="$(node_field "$i" UUID)"
    if [ "$(node_field "$i" TLS_MODE)" = "1" ]; then
      hp="$(reg_get GLOBAL_HTTPS_PORT)"
      echo "  [$i] $d（TLS，共用 $hp 端口）UUID ${u:0:8}... WS 路径 /$(node_field "$i" WSPATH)"
    else
      wsp="$(node_field "$i" WS_PORT)"
      echo "  [$i] 明文节点（WS 端口 $wsp）UUID ${u:0:8}... WS 路径 /$(node_field "$i" WSPATH)"
    fi
  done
  local pick=""
  if [ -n "$DEL_TARGET" ]; then
    pick="$DEL_TARGET"
  else
    echo "请输入你的选择："
    ask "要删除的节点编号（输编号；直接回车取消）： " DEL_PICK ""
    pick="$DEL_PICK"
    [ -z "$pick" ] && { echo "已取消，没删任何节点。"; exit 0; }
  fi
  local target=""
  if printf '%s' "$pick" | grep -qE '^[0-9]+$'; then
    [ -n "$(node_field "$pick" CONTAINER)" ] && target="$pick"
  else
    target="$(find_node_by_domain "$pick" || true)"
  fi
  if [ -z "$target" ]; then
    echo "找不到节点：$pick（编号或子域名不对）。上面列出的是已有节点，请核对后重跑。"
    exit 1
  fi
  local d_dom d_uuid d_tls d_cm d_hp d_wsp d_cfg d_ctr d_clash d_qr d_wspath
  d_dom="$(node_field "$target" DOMAIN)"
  d_uuid="$(node_field "$target" UUID)"
  d_tls="$(node_field "$target" TLS_MODE)"
  d_cm="$(node_field "$target" CERT_METHOD)"
  d_hp="$(reg_get GLOBAL_HTTPS_PORT)"
  d_wsp="$(node_field "$target" WS_PORT)"
  d_cfg="$(node_field "$target" CONFIG)"
  d_ctr="$(node_field "$target" CONTAINER)"
  d_clash="$(node_field "$target" CLASH)"
  d_qr="$(node_field "$target" QR)"
  d_wspath="$(node_field "$target" WSPATH)"
  echo ""
  echo "将删除以下节点（留底用）："
  if [ "$d_tls" = "1" ]; then
    echo "  域名：$d_dom（TLS，共用 $d_hp 端口；证书方式：$d_cm）"
  else
    echo "  明文节点（WS 端口 $d_wsp）"
  fi
  echo "  UUID：$d_uuid"
  echo "  WS 路径：/$d_wspath"
  echo "  配置文件：$d_cfg / $d_clash / $d_qr"
  echo "  容器：$d_ctr"
  echo "删除后其他节点不受影响。确认删除吗？[y/N，默认 N]"
  local confirm="${DEL_NODE_CONFIRM:-}"
  if [ "$confirm" != "y" ]; then
    ask "确认删除（y=删，N=不删，直接回车就是 N）： " DEL_CONFIRM "N"
    confirm="$DEL_CONFIRM"
  fi
  if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
    echo "已取消，没删任何节点。"
    exit 0
  fi
  echo "正在删除节点 $target（$d_dom）..."
  if [ "$DRY_RUN" != "1" ]; then
    docker rm -f "$d_ctr" >/dev/null 2>&1 || true
    echo "已删除容器 $d_ctr"
  else
    echo "[dry-run] 跳过删除容器 $d_ctr"
  fi
  rm -f "$d_cfg" "$d_clash" "$d_qr"
  echo "已删除配置文件 $d_cfg / $d_clash / $d_qr"
  grep -v "^NODE_${target}_" "$REG_FILE" > "$REG_FILE.tmp" || true
  mv "$REG_FILE.tmp" "$REG_FILE"
  echo "已从节点注册表删除节点 $target"
  if [ "$(node_count)" = "0" ]; then
    echo ""
    echo "已删完最后一个节点。"
    if [ "$DRY_RUN" != "1" ]; then
      docker rm -f "$CADDY_CTR" >/dev/null 2>&1 || true
    fi
    rm -f Caddyfile docker-compose.yml nodes.conf .env
    echo "Caddyfile、docker-compose.yml、nodes.conf、.env 已清理。彻底清理残留请跑 bash stop.sh --remove。"
    echo ""
    echo "已删除节点：$d_dom（UUID $d_uuid）"
    exit 0
  fi
  gen_caddyfile
  gen_compose
  if [ "$DRY_RUN" != "1" ]; then
    # 还有 TLS 节点就 reload 新 Caddyfile；一个 TLS 节点都没了就停掉 Caddy（否则它还用旧配置对外服务）
    _any_tls=0
    for _i2 in $(node_indices); do [ "$(node_field "$_i2" TLS_MODE)" = "1" ] && _any_tls=1; done
    if [ "$_any_tls" = "1" ]; then
      caddy_reload
    else
      docker rm -f "$CADDY_CTR" >/dev/null 2>&1 || true
    fi
    docker compose up -d >/dev/null 2>&1 || true
  else
    echo "[dry-run] 跳过 caddy reload"
  fi
  echo ""
  echo "已删除节点：$d_dom（UUID $d_uuid）"
  echo "逐个核查剩余节点："
  local ok=1 i2
  for i2 in $(node_indices); do
    local r_dom r_tls r_hp r_wsp r_path r_ctr
    r_dom="$(node_field "$i2" DOMAIN)"
    r_tls="$(node_field "$i2" TLS_MODE)"
    r_path="$(node_field "$i2" WSPATH)"
    r_ctr="$(node_field "$i2" CONTAINER)"
    if [ "$DRY_RUN" = "1" ]; then
      if [ -f "$(node_field "$i2" CONFIG)" ] && { [ "$r_tls" = "0" ] || grep -q "$r_dom" Caddyfile 2>/dev/null; }; then
        echo "  [通过] 节点 $i2（$r_dom）：配置文件与 Caddyfile 正常"
      else
        echo "  [风险] 节点 $i2（$r_dom）：配置文件或 Caddyfile 异常"
        ok=0
      fi
      continue
    fi
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$r_ctr"; then
      echo "  [通过] 节点 $i2（$r_dom）：容器 $r_ctr 在运行"
    else
      echo "  [风险] 节点 $i2（$r_dom）：容器 $r_ctr 没在运行"
      ok=0
    fi
    if [ "$r_tls" = "1" ]; then
      r_hp="$(reg_get GLOBAL_HTTPS_PORT)"
      test_node_ws "https" "$r_dom" "$r_hp" "$r_path"
    else
      r_wsp="$(node_field "$i2" WS_PORT)"
      test_node_ws "http" "$(reg_get GLOBAL_SERVER_IP)" "$r_wsp" "$r_path"
    fi
  done
  if [ "$ok" = "1" ]; then
    echo "剩余节点全部正常。"
  else
    echo "注意：有剩余节点异常，上面标了 [风险]，请核对。"
  fi
}

del_node_flow_singbox() {
  migrate_legacy || true
  if [ ! -f "$REG_FILE" ] || [ "$(node_count)" = "0" ]; then
    echo "没有可删除的节点（还没装过节点，或 nodes.conf 不在）。"
    exit 1
  fi
  section "删除单个节点"
  echo "  其他节点不受影响"
  echo "当前节点："
  local i
  for i in $(node_indices); do
    local d t
    d="$(node_field "$i" DOMAIN)"; t="$(node_field "$i" TLS_MODE)"
    if [ "$t" = "1" ]; then
      echo "  [$i] $d（TLS，SS $(node_field "$i" SS_PORT) / HY2 $(node_field "$i" HY2_PORT) / TUIC $(node_field "$i" TUIC_PORT)，容器 $(node_field "$i" CONTAINER)）"
    else
      echo "  [$i] 明文（VLESS $(node_field "$i" VLESS_PORT) / Trojan $(node_field "$i" TROJAN_PORT) / VMess $(node_field "$i" VMESS_PORT) / SS $(node_field "$i" SS_PORT)，容器 $(node_field "$i" CONTAINER)）"
    fi
  done
  local pick="${MODE_ARG:-}" target=""
  if [ -n "$pick" ]; then
    if valid_domain "$pick"; then
      target="$(find_node_by_domain "$pick" || true)"
      [ -z "$target" ] && { echo "找不到域名为 $pick 的节点。"; exit 1; }
    elif valid_port "$pick"; then
      target="$pick"
      [ -z "$(node_field "$target" DOMAIN)" ] && [ "$(node_field "$target" TLS_MODE)" != "0" ] && [ -z "$(node_field "$target" CONTAINER)" ] && { echo "找不到编号为 $pick 的节点。"; exit 1; }
    else
      echo "参数 $pick 既不是域名也不是节点编号。"; exit 1
    fi
  else
    echo "请选择要删除的节点编号："
    read_line pick "节点编号： "
    target="$pick"
    if ! valid_port "$target" || { [ -z "$(node_field "$target" DOMAIN)" ] && [ "$(node_field "$target" TLS_MODE)" != "0" ] && [ -z "$(node_field "$target" CONTAINER)" ]; }; then
      echo "编号 $target 没有对应节点。"; exit 1
    fi
  fi
  local d_dom d_tls d_uuid d_cfg d_clash d_ctr
  d_dom="$(node_field "$target" DOMAIN)"; d_tls="$(node_field "$target" TLS_MODE)"
  d_uuid="$(node_field "$target" UUID_VLESS)"; d_cfg="$(node_field "$target" CONFIG)"
  d_clash="$(node_field "$target" CLASH)"; d_ctr="$(node_field "$target" CONTAINER)"
  echo ""
  echo "将删除节点 $target，信息如下（请留底）："
  if [ "$d_tls" = "1" ]; then
    echo "  域名：$d_dom"
  else
    echo "  模式：明文（无域名）"
  fi
  echo "  VLESS UUID：$d_uuid"
  if [ "$d_tls" = "1" ]; then
    echo "  端口：SS $(node_field "$target" SS_PORT) / HY2 $(node_field "$target" HY2_PORT) / TUIC $(node_field "$target" TUIC_PORT)"
  else
    echo "  端口：VLESS $(node_field "$target" VLESS_PORT) / Trojan $(node_field "$target" TROJAN_PORT) / VMess $(node_field "$target" VMESS_PORT) / SS $(node_field "$target" SS_PORT)"
  fi
  echo "  容器：$d_ctr"
  echo "  配置：$d_cfg、$d_clash"
  echo "删除后该节点的链接立即失效，其他节点不受影响。"
  local confirm=""
  read_line confirm "确定删除节点 $target？[y/N，默认 N]： "
  if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
    echo "已取消，未删除任何节点。"
    exit 0
  fi
  echo ""
  echo "正在删除节点 $target..."
  if [ "$DRY_RUN" != "1" ]; then
    docker rm -f "$d_ctr" >/dev/null 2>&1 || true
    echo "  已删除容器 $d_ctr"
  else
    echo "  [dry-run] 跳过删除容器 $d_ctr"
  fi
  rm -f "$d_cfg" "$d_clash" "qr-${target}-vless.png" "qr-${target}-trojan.png" "qr-${target}-vmess.png" "qr-${target}-ss.png" "qr-${target}-hy2.png" "qr-${target}-tuic.png" 2>/dev/null
  if [ "$target" = "1" ]; then
    rm -f qr-vless.png qr-trojan.png qr-vmess.png qr-ss.png qr-hy2.png qr-tuic.png 2>/dev/null
  fi
  echo "  已删除配置文件 $d_cfg、$d_clash 与二维码"
  grep -v "^NODE_${target}_" "$REG_FILE" > "$REG_FILE.tmp" || true
  mv "$REG_FILE.tmp" "$REG_FILE"
  echo "  已删除节点记录"
  if [ "$(node_count)" = "0" ]; then
    echo ""
    echo "已删完最后一个节点。"
    if [ "$DRY_RUN" != "1" ]; then
      docker rm -f "$CADDY_CTR" >/dev/null 2>&1 || true
    fi
    rm -f Caddyfile docker-compose.yml nodes.conf .env
    echo "Caddyfile、docker-compose.yml、nodes.conf、.env 已清理。彻底清理残留请跑 bash stop.sh --remove。"
    echo ""
    echo "已删除节点 $target：${d_dom:-明文}，VLESS UUID $d_uuid"
    exit 0
  fi
  gen_caddyfile
  gen_compose
  echo "  Caddyfile 与 docker-compose.yml 已更新（去掉节点 $target 的配置段）"
  if [ "$DRY_RUN" != "1" ]; then
    # 还有 TLS 节点就 reload 新 Caddyfile；一个 TLS 节点都没了就停掉 Caddy（否则它还用旧配置对外服务）
    _any_tls=0
    for _i2 in $(node_indices); do [ "$(node_field "$_i2" TLS_MODE)" = "1" ] && _any_tls=1; done
    if [ "$_any_tls" = "1" ]; then
      caddy_reload
    else
      docker rm -f "$CADDY_CTR" >/dev/null 2>&1 || true
    fi
    docker compose up -d >/dev/null 2>&1 || true
  else
    echo "  [dry-run] 跳过 reload Caddy"
  fi
  # 逐个核查剩余节点仍正常
  echo ""
  echo "核查剩余节点："
  local ok=1 i2 r_dom r_tls r_cfg
  for i2 in $(node_indices); do
    r_dom="$(node_field "$i2" DOMAIN)"; r_tls="$(node_field "$i2" TLS_MODE)"; r_cfg="$(node_field "$i2" CONFIG)"
    if [ "$DRY_RUN" = "1" ]; then
      if [ -f "$r_cfg" ] && { [ "$r_tls" = "0" ] || grep -q "$(node_field "$i2" PATH_VLESS)" Caddyfile 2>/dev/null; }; then
        echo "  [通过] 节点 $i2（${r_dom:-明文}）：配置文件与 Caddyfile 正常"
      else
        echo "  [风险] 节点 $i2（${r_dom:-明文}）：配置文件或 Caddyfile 异常"
        ok=0
      fi
      continue
    fi
    if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$(node_field "$i2" CONTAINER)"; then
      echo "  [风险] 节点 $i2（${r_dom:-明文}）：容器 $(node_field "$i2" CONTAINER) 不在运行"
      ok=0
      continue
    fi
    if [ "$r_tls" = "1" ]; then
      test_node_ws "https" "$r_dom" "$(reg_get GLOBAL_HTTPS_PORT)" "$(node_field "$i2" PATH_VLESS)"
    else
      test_node_ws "http" "$(reg_get GLOBAL_SERVER_IP)" "$(node_field "$i2" VLESS_PORT)" "$(node_field "$i2" PATH_VLESS)"
    fi
  done
  echo ""
  if [ "$ok" = "1" ]; then
    echo "删除完成，剩余节点核查正常。"
  else
    echo "删除完成，但剩余节点核查有风险（见上面），请跑 bash check.sh 再看一次。"
  fi
  echo "已删除节点 $target：${d_dom:-明文}，VLESS UUID $d_uuid"
}

ask_add_more() {
  local ans=""
  while :; do
    echo ""
    read_line ans "还要再加一个节点吗？[y/N，默认 N]： "
    case "$ans" in
      y|Y|yes) MODE_ARG=""; ADD_ARG=""; add_node_flow ;;
      *) break ;;
    esac
  done
}

# ---------- 核心判定与分发 ----------
# CORE：xray | sing-box。$CORE 变量优先（安装时 ask_core 或环境变量定下）；否则读注册表 GLOBAL_CORE；
# 注册表也没有时按 1 号节点的容器名/配置文件名推断（接管旧安装时用）；都推断不出默认 xray。
reg_core() {
  local c=""
  c="$(reg_get GLOBAL_CORE)"
  if [ -n "$c" ]; then printf '%s' "$c"; return 0; fi
  local ctr cfg
  ctr="$(node_field 1 CONTAINER)"
  cfg="$(node_field 1 CONFIG)"
  case "$ctr" in
    tiktok-*) printf 'xray'; return 0 ;;
    singbox-*) printf 'sing-box'; return 0 ;;
  esac
  case "$cfg" in
    sing-box*) printf 'sing-box'; return 0 ;;
    config*) printf 'xray'; return 0 ;;
  esac
  printf 'xray'
}
core() {
  if [ -n "${CORE:-}" ]; then printf '%s' "$CORE"; return 0; fi
  reg_core
}
core_name() {
  if [ "$(core)" = "sing-box" ]; then printf 'sing-box'; else printf 'xray'; fi
}
caddy_ctr() {  # Caddy 容器名：xray 核心用 tiktok-caddy，sing-box 核心用 singbox-caddy
  if [ "$(core)" = "sing-box" ]; then printf 'singbox-caddy'; else printf 'tiktok-caddy'; fi
}
set_core_vars() {
  CORE_NAME="$(core_name)"
  CADDY_CTR="$(caddy_ctr)"
}
svc_name() {  # compose 服务名：xray 核心节点 1 叫 xray、节点 N 叫 xrayN；sing-box 核心节点 1 叫 sing-box、节点 N 叫 sing-box-N
  if [ "$(core)" = "sing-box" ]; then
    if [ "$1" = "1" ]; then echo "sing-box"; else echo "sing-box-$1"; fi
  else
    if [ "$1" = "1" ]; then echo "xray"; else echo "xray$1"; fi
  fi
}
port_owned_by_us() {  # port_owned_by_us 端口 -> 0=被本包两个核心之一的容器占用
  local port="$1"
  [ "$DRY_RUN" = "1" ] && return 1
  command -v docker >/dev/null 2>&1 || return 1
  docker ps --format '{{.Names}} {{.Ports}}' 2>/dev/null | grep -E '^(tiktok-(xray(-[0-9]+)?|caddy)|singbox-(node(-[0-9]+)?|caddy)) ' | grep -q ":${port}->"
}
caddy_reload() {  # Caddy 改了配置后 reload（已有节点连接不断）；reload 不成就重启 Caddy 容器
  local ctr=""
  ctr="$(caddy_ctr)"
  if [ "$DRY_RUN" = "1" ]; then echo "[dry-run] 跳过 caddy reload"; return 0; fi
  if docker exec "$ctr" caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile 2>/dev/null; then
    echo "Caddy 已 reload（已有节点连接不断）"
    return 0
  fi
  echo "caddy reload 没成功，改重启 Caddy 容器..."
  docker compose restart caddy 2>/dev/null || docker compose up -d caddy
}
gen_caddyfile() { if [ "$(core)" = "sing-box" ]; then gen_caddyfile_singbox; else gen_caddyfile_xray; fi; }
gen_compose() { if [ "$(core)" = "sing-box" ]; then gen_compose_singbox; else gen_compose_xray; fi; }
write_node_files() {  # 按核心分发：xray 用调用方设好的全局 NODE_* 变量，sing-box 传编号读注册表
  if [ "$(core)" = "sing-box" ]; then write_singbox_files "$1"; else write_xray_files; fi
}
deploy_node() { if [ "$(core)" = "sing-box" ]; then deploy_singbox_node "$1"; else deploy_xray_node "$1"; fi; }
add_node_flow() { if [ "$(core)" = "sing-box" ]; then add_node_flow_singbox; else add_node_flow_xray; fi; }
del_node_flow() { if [ "$(core)" = "sing-box" ]; then del_node_flow_singbox; else del_node_flow_xray; fi; }
migrate_legacy() {
  if [ -f .env ] && [ -f sing-box.json ] && [ ! -f "$REG_FILE" ]; then
    migrate_legacy_singbox && { reg_set "GLOBAL_CORE" "sing-box"; return 0; }
    return 1
  fi
  if [ -f .env ] && [ -f config.json ] && [ ! -f "$REG_FILE" ]; then
    migrate_legacy_xray && { reg_set "GLOBAL_CORE" "xray"; return 0; }
    return 1
  fi
  return 1
}
check_ports_fresh() {  # 首装/重跑的端口预检，按核心分发
  if [ "$(core)" = "sing-box" ]; then check_ports; else check_ports_xray; fi
}
check_ports_xray() {  # Xray 核心的首装/重跑端口预检（TLS 查 80 + HTTPS 端口，明文查 WS 端口；自己容器占的不拦）
  local hp="${HTTPS_PORT:-443}" wp="${WS_PORT:-8080}"
  if [ "$TLS_MODE" = "1" ]; then
    if [ "$CERT_METHOD" = "dns" ]; then
      echo "DNS 验证模式：80 端口不用空闲（签证书走 DNS 验证），80 被占也不拦。"
    elif port_in_use 80 && ! port_owned_by_us 80; then
      echo "80 端口已被占用，TLS 装不了（Caddy 签证书走 HTTP-01 验证必须用 80）："
      port_owner 80
      echo "建议：换一台 80 空闲的服务器，或不填域名重跑走明文模式；"
      echo "也可以重跑并选 [2] DNS 验证（要 Cloudflare API 令牌），80 被占也能装。"
      exit 1
    fi
    if port_in_use "$hp" && ! port_owned_by_us "$hp"; then
      echo "$hp 端口已被占用，装不了："
      port_owner "$hp"
      echo "建议：停掉占用它的程序，或重跑并把 HTTPS 端口改成别的（如 8443、24443）。"
      exit 1
    fi
    if [ "$CERT_METHOD" = "dns" ]; then
      echo "$hp 端口空闲（80 不用查，DNS 验证模式不走 80）。"
    else
      echo "80 与 $hp 端口空闲。"
    fi
  else
    if port_in_use "$wp" && ! port_owned_by_us "$wp"; then
      echo "$wp 端口已被占用，装不了："
      port_owner "$wp"
      echo "建议：停掉占用它的程序，或重跑并把 WS 端口改成别的（如 9080、30000）。"
      exit 1
    fi
    echo "$wp 端口空闲。"
  fi
}

# ---------- 选择核心 ----------
ask_core() {
  # 环境变量 CORE 预设：xray|sing-box 或 1|2（已在注册表里定下的核心也会走到这里，直接返回）
  case "${CORE:-}" in
    1|xray) CORE="xray"; return 0 ;;
    2|sing-box) CORE="sing-box"; return 0 ;;
    "") ;;
    *) echo "CORE=$CORE 不合法（只能是 xray/1 或 sing-box/2），请修正后重跑。"; exit 1 ;;
  esac
  if [ "$DRY_RUN" = "1" ]; then CORE="xray"; return 0; fi
  while :; do
    echo "先选一种核心（装完不能混装，一台机器只能装一种；想换核心要先停掉旧的再装）："
    echo ""
    echo "  [1] Xray（VLESS + WS + TLS 单协议）← 默认，直接回车就是 1"
    echo "      最成熟的 VLESS 方案，只跑一个协议，配置最简单，出问题最容易查。"
    echo "      适合：只做 TikTok、只要一个协议够用、求稳的情况。"
    echo "      代价：只有一个协议，客户端只能用 VLESS；想多协议要重装 sing-box。"
    echo ""
    echo "  [2] sing-box（VLESS / Trojan / VMess / Shadowsocks / Hysteria2 / TUIC 六协议合一）"
    echo "      一个核心同时跑 6 个协议，弱网有 Hysteria2/TUIC，走 QUIC 更快；Clash 自动选延迟最低的协议。"
    echo "      适合：想多协议备用、弱网用户多、要 HY2/TUIC 的情况。"
    echo "      代价：直连端口多 3 个（SS 8388、HY2 8443、TUIC 8444），配置比 Xray 复杂一点。"
    echo ""
    echo "请输入你的选择："
    ask "核心（1=Xray，2=sing-box；默认 1，直接回车就是 1）： " CORE_ANS "1"
    case "$CORE_ANS" in
      1|xray) CORE="xray"; return 0 ;;
      2|sing-box) CORE="sing-box"; return 0 ;;
      *) echo "输入不合法：$CORE_ANS（只能填 1 或 2），请重新输入。"; CORE_ANS="" ;;
    esac
  done
}

# ---------- 已有安装检测与接管 ----------
# 本目录已有 nodes.conf：按注册表核心继续（重跑只换首节点，与旧版行为一致）；
# 本目录没有、但 $HOME 下有旧版安装目录：问要不要接管（把新版脚本装进旧目录），不要静默覆盖。
detect_existing() {
  if [ -f "$REG_FILE" ]; then
    local rc=""
    rc="$(reg_core)"
    if [ -n "${CORE_ENV:-}" ] && [ "$CORE_ENV" != "$rc" ]; then
      echo "CORE 环境变量选的是 $CORE_ENV，和已安装的核心 $rc 不一致，装不了。"
      echo "想换核心：先在安装目录跑 bash stop.sh --remove 停掉旧安装，再重跑。"
      exit 1
    fi
    CORE="$rc"
    echo "检测到本目录已有 $rc 核心安装（节点 $(node_count) 个），将按该核心继续。"
    return 0
  fi
  local legacy="" legacy_core=""
  if [ -f "$HOME/tiktok-node-kit/nodes.conf" ]; then
    legacy="$HOME/tiktok-node-kit"; legacy_core="xray"
  elif [ -f "$HOME/sing-box-node-kit/nodes.conf" ]; then
    legacy="$HOME/sing-box-node-kit"; legacy_core="sing-box"
  fi
  [ -z "$legacy" ] && return 0
  echo ""
  echo "检测到这台机上已有旧版安装：$legacy（$legacy_core 核心），节点还在跑。"
  echo "新版安装目录是 $PWD，一台机器只能装一种核心，不能直接在新目录再装一套。"
  echo ""
  echo "  [1] 接管已有安装 ← 推荐"
  echo "      把新版管理脚本（install.sh、stop.sh、check.sh）装进旧目录，在旧 nodes.conf 里记下核心，"
  echo "      节点、容器、证书原样保留，之后继续在旧目录里管理（追加、删除、停止都用新版脚本）。"
  echo ""
  echo "  [2] 取消"
  echo "      先去旧目录跑 bash stop.sh --remove 停掉旧安装，再回来重跑新版安装。"
  echo ""
  ask "你的选择（1=接管，2=取消；默认 1，直接回车就是 1）： " TAKEOVER_ANS "1"
  if [ "$TAKEOVER_ANS" = "1" ]; then
    echo ""
    echo "正在把新版管理脚本装进 $legacy ..."
    if [ -f ./install.sh ]; then
      cp ./install.sh "$legacy/install.sh"
    else
      curl -fsSL https://raw.githubusercontent.com/nbbk/landing-node/main/install.sh -o "$legacy/install.sh" || {
        echo "下载 install.sh 失败（网络问题），接管没做成，旧安装原样不动。"
        exit 1
      }
    fi
    if [ -f ./stop.sh ]; then cp ./stop.sh "$legacy/stop.sh";
    else curl -fsSL https://raw.githubusercontent.com/nbbk/landing-node/main/stop.sh -o "$legacy/stop.sh" 2>/dev/null || echo "stop.sh 下载失败：旧目录里的旧版 stop.sh 还能用，之后手动从仓库取新版。"; fi
    if [ -f ./check.sh ]; then cp ./check.sh "$legacy/check.sh";
    else curl -fsSL https://raw.githubusercontent.com/nbbk/landing-node/main/check.sh -o "$legacy/check.sh" 2>/dev/null || echo "check.sh 下载失败：下次安装时会自动重新生成。"; fi
    chmod +x "$legacy/install.sh" "$legacy/stop.sh" "$legacy/check.sh" 2>/dev/null || true
    if ! grep -q "^GLOBAL_CORE=" "$legacy/nodes.conf" 2>/dev/null; then
      printf '%s\n' "GLOBAL_CORE=$legacy_core" >> "$legacy/nodes.conf"
    fi
    echo ""
    echo "已接管：新版管理脚本已装进 $legacy，核心已记为 $legacy_core，节点记录原样保留。"
    echo "之后在旧目录里管理：cd $legacy && bash install.sh --add-node"
    exit 0
  fi
  echo "已取消。先去旧目录停掉旧安装再重跑：cd $legacy && bash stop.sh --remove"
  exit 0
}


# ---------- 日志上限（防爆盘：journald） ----------
# journald 默认能用到磁盘 10%（20G 盘就是 2G）；本机 node-agent 与系统日志都走 journald。
# docker 容器日志不用这里管：compose 里每个服务都已限 10m x 3 份。
# 与 relay-node 的 panel-install.sh 里 setup_log_limits 的第 2) 步同一份逻辑（两边改动要同步）。
setup_journald_limit() {
  if [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then
    local jc="/etc/systemd/journald.conf"
    if grep -Eq '^[[:space:]]*SystemMaxUse=' "$jc" 2>/dev/null; then
      echo "journald 上限已配过（$jc 里已有 SystemMaxUse），不动。"
    elif [ "$DRY_RUN" = "1" ]; then
      echo "[dry-run] 会在 $jc 末尾加 [Journal] SystemMaxUse=100M，并重启 systemd-journald、跑 journalctl --vacuum-size=100M"
    else
      printf '\n[Journal]\nSystemMaxUse=100M\n' >> "$jc"
      systemctl restart systemd-journald 2>/dev/null || true
      journalctl --vacuum-size=100M >/dev/null 2>&1 || true
      echo "journald 上限已设为 100M（旧日志已按 100M 清过一次）。"
    fi
  else
    echo "本机没有 systemd，跳过 journald 上限。"
  fi
}

# ================= 主流程 =================
# --add-node / --del-node：按已安装的核心走（先迁移旧版单节点，再按注册表定核心）
if [ "$MODE" = "add" ] || [ "$MODE" = "del" ]; then
  if [ "$DRY_RUN" != "1" ]; then
    if ! command -v docker >/dev/null 2>&1; then
      echo "未检测到 Docker，正在安装..."
      curl -fsSL https://get.docker.com | sh
    fi
    docker compose version >/dev/null 2>&1 || { echo "缺少 Docker Compose 插件，请先安装 docker-compose-plugin"; exit 1; }
  fi
  migrate_legacy || true
  if [ ! -f "$REG_FILE" ]; then
    echo "还没装过节点（找不到 $REG_FILE，也没有可迁移的旧版单节点）。"
    echo "先跑一次全新安装：bash install.sh [域名]"
    exit 1
  fi
  CORE="$(reg_core)"
  if [ -n "${CORE_ENV:-}" ] && [ "$CORE_ENV" != "$CORE" ]; then
    echo "CORE 环境变量选的是 $CORE_ENV，和已安装的核心 $CORE 不一致。"
    echo "追加/删除节点按已安装的核心走，不用传 CORE；想换核心先跑 bash stop.sh --remove。"
    exit 1
  fi
  set_core_vars
  if [ "$MODE" = "add" ]; then add_node_flow; else del_node_flow; fi
  exit $?
fi

# 全新安装 / 重跑（非 dry-run 时先检测已有安装与旧版接管）
if [ "$DRY_RUN" != "1" ]; then
  detect_existing
fi

section "1/7 选择核心"
ask_core
set_core_vars
if [ "$(core)" = "sing-box" ]; then
  echo "核心：sing-box（VLESS / Trojan / VMess / Shadowsocks / Hysteria2 / TUIC 六协议合一）"
else
  echo "核心：Xray（VLESS + WS + TLS 单协议）"
fi

section "2/7 检查 Docker"
if [ "$DRY_RUN" != "1" ]; then
  if ! command -v docker >/dev/null 2>&1; then
    echo "未检测到 Docker，正在安装..."
    curl -fsSL https://get.docker.com | sh
  fi
  docker compose version >/dev/null 2>&1 || { echo "缺少 Docker Compose 插件，请先安装 docker-compose-plugin"; exit 1; }
fi

section "3/7 域名与证书方式"
# 端口：环境变量可预设（写进 .env 之前先把环境变量的值存起来）；.env 里的端口不继承，重跑时重新问
declare -A _env_ports=()
for _pv in HTTPS_PORT WS_PORT SS_PORT HY2_PORT TUIC_PORT VLESS_PORT TROJAN_PORT VMESS_PORT; do
  [ -n "${!_pv:-}" ] && _env_ports[$_pv]="${!_pv}"
done
ENV_CERT_METHOD="${CERT_METHOD:-}"
ENV_CF_TOKEN="${CLOUDFLARE_API_TOKEN:-}"
if [ -f .env ]; then set -a; . ./.env; set +a; fi
for _pv in HTTPS_PORT WS_PORT SS_PORT HY2_PORT TUIC_PORT VLESS_PORT TROJAN_PORT VMESS_PORT; do
  if [ -n "${_env_ports[$_pv]:-}" ]; then printf -v "$_pv" '%s' "${_env_ports[$_pv]}"; else unset "$_pv"; fi
done
unset _env_ports _pv
DOMAIN="${CLI_DOMAIN:-${DOMAIN:-}}"
if [ -z "$DOMAIN" ] && [ "$DRY_RUN" != "1" ]; then
  echo "请填写你的域名："
  if [ "$(core)" = "sing-box" ]; then
    ask "域名（已解析到本机；没有直接回车，用 IP 明文跑，HY2/TUIC 不启用）： " DOMAIN
  else
    ask "域名（已解析到本机；没有直接回车，用 IP 明文跑）： " DOMAIN
  fi
fi
if [ -z "$DOMAIN" ]; then
  TLS_MODE=0
  if [ "$(core)" = "sing-box" ]; then
    HY2_ENABLED=0
    echo "无域名：明文 WS 模式（VLESS 8080 / Trojan 8081 / VMess 8082 + SS 8388），HY2/TUIC 不启用，建议之后补域名重跑以启用 TLS 和全部协议"
  else
    echo "无域名：明文 WS 模式，建议之后补域名重跑以启用 TLS"
  fi
else
  TLS_MODE=1
  echo "域名：$DOMAIN（TLS 模式）"
fi
if [ "$TLS_MODE" = "1" ]; then
  CERT_METHOD="${ENV_CERT_METHOD:-${CERT_METHOD:-}}"
  case "$CERT_METHOD" in
    1|http) CERT_METHOD="http" ;;
    2|dns) CERT_METHOD="dns" ;;
    "")
      if [ "$DRY_RUN" != "1" ]; then ask_cert_method; else CERT_METHOD="http"; fi ;;
    *) echo "CERT_METHOD=$CERT_METHOD 不合法（只能是 http/1 或 dns/2），请修正后重跑。"; exit 1 ;;
  esac
  if [ "$CERT_METHOD" = "dns" ]; then echo "证书方式：DNS 验证（Cloudflare）"; else echo "证书方式：默认走 80（HTTP-01）"; fi
  CLOUDFLARE_API_TOKEN="${ENV_CF_TOKEN:-${CLOUDFLARE_API_TOKEN:-}}"
  if [ "$CERT_METHOD" = "dns" ] && [ -z "$CLOUDFLARE_API_TOKEN" ]; then
    if [ "$DRY_RUN" != "1" ]; then ask_cf_token; else echo "[dry-run] DNS 验证模式：未预设 CLOUDFLARE_API_TOKEN，.env 里令牌为空（实装时会问）"; fi
  fi
fi

echo "端口预检："
# Xray 核心：预检在问端口之前（原 tiktok 顺序，用环境变量/默认值查）
if [ "$(core)" = "xray" ]; then check_ports_fresh; fi

section "4/7 公开端口（可自定义）"
if [ "$(core)" = "sing-box" ]; then
  if [ "$TLS_MODE" = "1" ]; then
    echo "TLS 模式：HTTPS 端口默认 443，SS 默认 8388，HY2 默认 8443，TUIC 默认 8444。"
    echo "如果端口已被占，会自动提示你改；也可以现在直接改。"
    _used=""
    ask_port HTTPS_PORT "请填写 HTTPS 端口（WS 走的那个端口，例如被占时可改高位端口 8443）：" 443 "$_used"; _used="$_used $HTTPS_PORT"
    ask_port SS_PORT "请填写 Shadowsocks 直连端口（默认 8388）：" 8388 "$_used"; _used="$_used $SS_PORT"
    ask_port HY2_PORT "请填写 Hysteria2 直连端口（默认 8443）：" 8443 "$_used"; _used="$_used $HY2_PORT"
    ask_port TUIC_PORT "请填写 TUIC 直连端口（默认 8444）：" 8444 "$_used"; _used="$_used $TUIC_PORT"
    VLESS_PORT="$HTTPS_PORT"; TROJAN_PORT="$HTTPS_PORT"; VMESS_PORT="$HTTPS_PORT"
    echo "公开端口：HTTPS $HTTPS_PORT，SS $SS_PORT，HY2 $HY2_PORT，TUIC $TUIC_PORT"
  else
    echo "明文模式：VLESS 默认 8080，Trojan 默认 8081，VMess 默认 8082，SS 默认 8388。"
    echo "如果端口已被占，会自动提示你改；也可以现在直接改。"
    _used=""
    ask_port VLESS_PORT "请填写 VLESS 直连端口（默认 8080）：" 8080 "$_used"; _used="$_used $VLESS_PORT"
    ask_port TROJAN_PORT "请填写 Trojan 直连端口（默认 8081）：" 8081 "$_used"; _used="$_used $TROJAN_PORT"
    ask_port VMESS_PORT "请填写 VMess 直连端口（默认 8082）：" 8082 "$_used"; _used="$_used $VMESS_PORT"
    ask_port SS_PORT "请填写 Shadowsocks 直连端口（默认 8388）：" 8388 "$_used"; _used="$_used $SS_PORT"
    HTTPS_PORT=443; HY2_PORT=8443; TUIC_PORT=8444
    echo "公开端口：VLESS $VLESS_PORT，Trojan $TROJAN_PORT，VMess $VMESS_PORT，SS $SS_PORT"
  fi
else
  if [ "$TLS_MODE" = "1" ]; then
    echo "HTTPS 端口用默认 443 还是自定义？（443 被占时可改高位端口，如 8443、24443）："
    ask_port HTTPS_PORT "HTTPS 端口（默认 443，直接回车就是 443）： " "443" ""
    echo "HTTPS 端口：$HTTPS_PORT"
  else
    echo "WS 端口用默认 8080 还是自定义？（8080 被占时可改高位端口，如 9080、30000）："
    ask_port WS_PORT "WS 端口（默认 8080，直接回车就是 8080）： " "8080" ""
    echo "WS 端口：$WS_PORT"
  fi
fi

# sing-box 核心：预检在问完端口之后（原 sing-box 顺序，按最终选定的端口查）
if [ "$(core)" = "sing-box" ]; then echo "端口预检："; check_ports_fresh; fi

section "5/7 生成凭据与 WS 路径"
N=1
NODE_DOMAIN="$DOMAIN"
NODE_TLS_MODE="$TLS_MODE"
NODE_CERT_METHOD="${CERT_METHOD:-http}"
NODE_HTTPS_PORT="${HTTPS_PORT:-443}"
NODE_SERVER_IP="$SERVER_IP"
if [ "$(core)" = "sing-box" ]; then
  NODE_WS_BASE=10000
  NODE_UUID_VLESS="$(cat /proc/sys/kernel/random/uuid)"
  NODE_UUID_VMESS="$(cat /proc/sys/kernel/random/uuid)"
  NODE_UUID_TUIC="$(cat /proc/sys/kernel/random/uuid)"
  NODE_PASS_TROJAN="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 16 || true)"
  NODE_PASS_SS="$(head -c 16 /dev/urandom | base64 -w0)" # 2022-blake3 密码必须是 base64 编码的 16 字节密钥
  NODE_PASS_HY2="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 16 || true)"
  NODE_PASS_TUIC="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 16 || true)"
  NODE_PATH_VLESS="$(tr -dc 'a-z0-9' </dev/urandom | head -c 16 || true)"
  NODE_PATH_TROJAN="$(tr -dc 'a-z0-9' </dev/urandom | head -c 16 || true)"
  NODE_PATH_VMESS="$(tr -dc 'a-z0-9' </dev/urandom | head -c 16 || true)"
  NODE_SS_PORT="$SS_PORT"; NODE_HY2_PORT="$HY2_PORT"; NODE_TUIC_PORT="$TUIC_PORT"
  NODE_VLESS_PORT="$VLESS_PORT"; NODE_TROJAN_PORT="$TROJAN_PORT"; NODE_VMESS_PORT="$VMESS_PORT"
  NODE_HY2_ENABLED="$HY2_ENABLED"
  NODE_CONFIG="sing-box.json"
  NODE_CONTAINER="singbox-node"
  NODE_CLASH="clash.yaml"
  echo "VLESS UUID: $NODE_UUID_VLESS"
  echo "VMess UUID: $NODE_UUID_VMESS"
  echo "WS 路径: /$NODE_PATH_VLESS /$NODE_PATH_TROJAN /$NODE_PATH_VMESS"
else
  NODE_WS_PORT="${WS_PORT:-}"
  NODE_INTERNAL_PORT=10000
  NODE_UUID="$(cat /proc/sys/kernel/random/uuid)"
  NODE_WSPATH="$(tr -dc 'a-z0-9' </dev/urandom | head -c 16 || true)"
  WSPATH="$NODE_WSPATH"
  NODE_CONFIG="config.json"
  NODE_CONTAINER="tiktok-xray"
  NODE_CLASH="clash.yaml"
  NODE_QR="qr.png"
  echo "UUID: $NODE_UUID"
  echo "WS 路径: /$NODE_WSPATH"
fi
reg_set "GLOBAL_CORE" "$(core)"
reg_set "GLOBAL_TLS_MODE" "$TLS_MODE"
reg_set "GLOBAL_CERT_METHOD" "${CERT_METHOD:-http}"
reg_set "GLOBAL_HTTPS_PORT" "${HTTPS_PORT:-443}"
reg_set "GLOBAL_SERVER_IP" "$SERVER_IP"
if [ "$TLS_MODE" = "1" ] && [ "$(core)" = "sing-box" ]; then
  reg_set "GLOBAL_BASE_DOMAIN" "$(base_domain "$DOMAIN")"
fi
if [ "$TLS_MODE" = "1" ] && [ "$CERT_METHOD" = "dns" ]; then
  cat > Dockerfile.caddy <<'DCEOF'
# 带 Cloudflare DNS 插件的 Caddy：官方 caddy:2-builder 现场编，插件源码来自 github.com/caddy-dns/cloudflare
FROM caddy:2-builder AS builder
RUN xcaddy build --with github.com/caddy-dns/cloudflare
FROM caddy:2
COPY --from=builder /usr/bin/caddy /usr/bin/caddy
DCEOF
fi

section "6/7 禁用 IPv6 + 网络加速"
if [ "$DRY_RUN" != "1" ]; then
  if [ "$(core)" = "sing-box" ]; then
    cat > /etc/sysctl.d/99-landing-node.conf <<'SYSCTL'
# landing-node（sing-box）：禁用 IPv6（堵死 IPv6 泄漏口）+ BBR 加速 + TCP 缓冲 + TFO
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864
net.ipv4.tcp_fastopen = 3
SYSCTL
    sysctl -p /etc/sysctl.d/99-landing-node.conf >/dev/null
    echo "IPv6 已禁用：$(sysctl -n net.ipv6.conf.all.disable_ipv6)"
    if sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q bbr; then
      echo "BBR 已启用（$(sysctl -n net.ipv4.tcp_congestion_control)）"
    else
      echo "BBR 未启用（内核不支持或未加载，节点仍可用，速度稍慢）"
    fi
  else
    cat > /etc/sysctl.d/99-landing-node.conf <<'SYSCTL'
# landing-node（Xray）：禁用 IPv6，堵死 IPv6 泄漏口
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
SYSCTL
    sysctl -p /etc/sysctl.d/99-landing-node.conf >/dev/null
    echo "IPv6 已禁用：$(sysctl -n net.ipv6.conf.all.disable_ipv6)"
  fi
else
  echo "[dry-run] 跳过写 /etc/sysctl.d"
fi

section "7/7 写入配置并启动"
deploy_node fresh
# 日志上限（防爆盘：journald 封顶 100M；重跑也走同一逻辑，函数内已配过的不动、幂等）
echo ""
echo "设置日志上限（防爆盘：journald 封顶 100M）..."
setup_journald_limit
echo ""
echo "下一步：运行 bash check.sh 做泄漏自检，再按 README 配手机端。"

# check.sh 由 install.sh 内嵌生成（远程一键时只有一个文件）
cat > check.sh <<'CHECK_EOF'
#!/usr/bin/env bash
# 落地节点泄漏自检：在节点服务器上运行，检查 IP 纯净度、地区、IPv6、DNS、TikTok 可达性、节点端口
# 手机端的 DNS/WebRTC 泄漏需在手机上验证（脚本末尾会给出检查方法）
# 多节点：有 nodes.conf（install.sh --add-node 维护）时逐节点检查；没有就按旧版单节点（.env / clash.yaml）检查
# 两种核心都支持：按 nodes.conf 里的 GLOBAL_CORE 分发（Xray 查 WS 握手，sing-box 查端口监听）；
# 旧安装没有 GLOBAL_CORE 时按容器名/配置文件名推断
set -uo pipefail

pass() { echo "  [通过] $1"; }
warn() { echo "  [注意] $1"; }
fail() { echo "  [风险] $1"; }

# section 标题：统一分节横幅（前空一行，60 列分隔线，标题独占一行，再分隔线，后空一行）
section() {
  echo ""
  echo "============================================================"
  echo "  $1"
  echo "============================================================"
  echo ""
}

# ---------- 节点注册表（只读） ----------
CK_DIR="$(cd "$(dirname "$0")" && pwd)"
CK_REG="$CK_DIR/nodes.conf"
ck_reg_get() {
  local k="$1" line=""
  [ -f "$CK_REG" ] || return 0
  line="$(grep -m1 "^${k}=" "$CK_REG" || true)"
  printf '%s' "${line#*=}"
}
ck_node_field() { ck_reg_get "NODE_${1}_${2}"; }
ck_node_indices() {
  [ -f "$CK_REG" ] || return 0
  grep -oE '^NODE_[0-9]+_DOMAIN=' "$CK_REG" | grep -oE '[0-9]+' | sort -n -u || true
}

# 核心判定：GLOBAL_CORE 优先；旧安装没有时按 1 号节点的容器名/配置文件名推断；都推断不出默认 xray
ck_core() {
  local c=""
  c="$(ck_reg_get GLOBAL_CORE)"
  if [ -n "$c" ]; then printf '%s' "$c"; return 0; fi
  local ctr cfg
  ctr="$(ck_node_field 1 CONTAINER)"
  cfg="$(ck_node_field 1 CONFIG)"
  case "$ctr" in
    tiktok-*) printf 'xray'; return 0 ;;
    singbox-*) printf 'sing-box'; return 0 ;;
  esac
  case "$cfg" in
    sing-box*) printf 'sing-box'; return 0 ;;
    config*) printf 'xray'; return 0 ;;
  esac
  printf 'xray'
}
CK_CORE="$(ck_core)"
if [ "$CK_CORE" = "sing-box" ]; then CK_CORE_NAME="sing-box"; else CK_CORE="xray"; CK_CORE_NAME="xray"; fi

section "1/7 节点 IP 与地区"
IPJSON="$(curl -s --max-time 10 "https://ip-api.org/json/" || true)"
if [ -z "$IPJSON" ]; then
  warn "ip-api.org 查不到，改用 ipinfo.io"
  IPJSON="$(curl -s --max-time 10 "https://ipinfo.io/json" || true)"
fi
if command -v python3 >/dev/null 2>&1 && [ -n "$IPJSON" ]; then
  python3 - "$IPJSON" <<'PY'
import json, sys
try:
    d = json.loads(sys.argv[1])
except Exception:
    print("  [注意] IP 查询返回异常"); sys.exit(0)
ip = d.get("query") or d.get("ip", "?")
country = d.get("country") or d.get("countryCode", "?")
cc = d.get("countryCode") or ""
city = d.get("city") or d.get("region", "?")
isp = d.get("isp") or d.get("org", "?")
hosting = d.get("hosting")
print(f"  节点 IP：{ip}")
print(f"  地区：{country} {cc} / {city}")
print(f"  运营商/机房：{isp}")
if hosting is True:
    print("  [风险] 机房 IP（hosting=true），TikTok 风控更严，容易限流/0播放")
    print("       如果之后播放量异常，优先换住宅/ISP 的干净 IP。")
elif hosting is False:
    print("  [通过] 看起来是住宅/ISP IP（hosting=false），TikTok 风控相对友好。")
else:
    print("  [注意] 查不到 hosting 标记，可在 https://ipinfo.io 再核对一次。")
PY
else
  echo "  原始结果：$IPJSON"
fi

section "2/7 IPv6 是否禁用"
V6="$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null || echo "?")"
if [ "$V6" = "1" ]; then
  pass "IPv6 已禁用（disable_ipv6=1）"
else
  fail "IPv6 未禁用（disable_ipv6=$V6），install.sh 会自动禁用"
  echo "       手动执行："
  echo "       echo 'net.ipv6.conf.all.disable_ipv6 = 1' >> /etc/sysctl.d/99-landing-node.conf && sysctl -p"
fi
if ip -6 addr show scope global 2>/dev/null | grep -q "inet6"; then
  fail "本机仍有全局 IPv6 地址，存在 IPv6 泄漏口"
else
  pass "本机无全局 IPv6 地址"
fi

section "3/7 DNS 解析路径"
if command -v dig >/dev/null 2>&1; then
  RESOLVER="$(dig +short whoami.akamai.net @1.1.1.1 2>/dev/null | head -1)"
  [ -n "$RESOLVER" ] && echo "  经 1.1.1.1 解析的出口解析器 IP：$RESOLVER（应为 Cloudflare 的 IP，非国内运营商）"
  [ -z "$RESOLVER" ] && warn "dig 查询无返回，检查本机出站 UDP/TCP 53 是否被墙"
else
  warn "本机无 dig，跳过解析器核对（apt install dnsutils 可装）"
fi
if [ "$CK_CORE" = "xray" ]; then
  echo "  xray 已配置 DoH(1.1.1.1/8.8.8.8)+TCP 兜底、只解析 IPv4，服务端不再走明文 UDP 53"
else
  echo "  sing-box 已配置 DoH(1.1.1.1/8.8.8.8/9.9.9.9)+DoT、只解析 IPv4，服务端不再走明文 UDP 53"
fi

section "4/7 TikTok 可达性（从节点 IP 出口测）"
TT_CODE="$(curl -s -o /dev/null -w "%{http_code}" --max-time 15 "https://www.tiktok.com/" || true)"
API_CODE="$(curl -s -o /dev/null -w "%{http_code}" --max-time 15 "https://api16-normal-c-useast1a.tiktokv.com/" || true)"
echo "  tiktok.com -> HTTP $TT_CODE"
echo "  TikTok API 域名 -> HTTP $API_CODE"
if [ "$TT_CODE" = "200" ] || [ "$TT_CODE" = "301" ] || [ "$TT_CODE" = "302" ]; then
  pass "TikTok 主站从节点 IP 可达"
else
  fail "TikTok 主站从节点 IP 不可达（HTTP $TT_CODE），检查节点 IP 是否被 TikTok 拉黑或出站被墙"
fi

section "5/7 手机端自查（在手机上开着节点做）"
echo "  节点只能管服务端这一半，手机端泄漏要这样验："
echo "  1) 打开 https://www.dnsleaktest.com，点 Extended test"
echo "     全部 DNS 服务器 IP 应是节点所在国家/机房的，出现中国运营商 DNS = 泄漏"
echo "  2) 打开 https://browserleaks.com/ip"
echo "     不能出现你的真实 IP，不能出现 IPv6 地址，时区/语言要和节点地区一致"
echo "  3) TikTok 里刷几个视频，再看个人主页地区"
echo "     应与节点地区一致"
echo "  4) 手机设置核对（见 README）"
echo "     已拔国内 SIM 卡，时区语言=节点地区，定位已关"
section "6/7 节点端口连通性"
if [ "$CK_CORE" = "xray" ]; then
# Xray 核心：逐节点做 WS 握手拨测
ck_ws_handshake() {  # ck_ws_handshake 节点名 协议 地址 端口 路径
  local name="$1" proto="$2" host="$3" port="$4" path="$5" code=""
  echo "  节点 $name：$proto://$host:$port/$path"
  code="$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 -H "Connection: Upgrade" -H "Upgrade: websocket" -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" -H "Sec-WebSocket-Version: 13" "$proto://$host:$port/$path" || true)"
  echo "  WS 握手 -> HTTP $code"
  if [ "$code" = "101" ]; then
    pass "节点 $name：WS 握手 101，节点端口正常"
  elif [ "$code" = "400" ]; then
    pass "节点 $name：WS 端口已响应（400 = xray 已响应，正常）"
  elif [ "$code" = "200" ]; then
    fail "节点 $name：WS 握手返回 200，Caddy 没把请求转给 xray"
    echo "       重建：docker compose down && docker compose up -d"
  else
    fail "节点 $name：WS 握手无响应（HTTP $code）"
    echo "       检查端口 $port 是否放行、容器是否在跑"
  fi
}
if [ -f "$CK_REG" ]; then
  CK_HTTPS="$(ck_reg_get GLOBAL_HTTPS_PORT)"; [ -n "$CK_HTTPS" ] || CK_HTTPS=443
  CK_IP="$(ck_reg_get GLOBAL_SERVER_IP)"
  for _ni in $(ck_node_indices); do
    _tls="$(ck_node_field "$_ni" TLS_MODE)"
    _dom="$(ck_node_field "$_ni" DOMAIN)"
    _path="$(ck_node_field "$_ni" WSPATH)"
    if [ "$_tls" = "1" ]; then
      ck_ws_handshake "节点 $_ni（$_dom）" "https" "$_dom" "$CK_HTTPS" "$_path"
    else
      _wp="$(ck_node_field "$_ni" WS_PORT)"
      ck_ws_handshake "节点 $_ni（明文）" "http" "${CK_IP:-127.0.0.1}" "$_wp" "$_path"
    fi
  done
  unset _ni _tls _dom _path _wp
else
  # 旧版单节点：读安装记录（install.sh 写下的实际端口），没有就读 clash.yaml，再没有回退默认
  CK_TLS=""; CK_PORT=""; CK_HOST=""; CK_PATH=""; CK_PROTO="http"
  if [ -f "$CK_DIR/.env" ]; then set -a; . "$CK_DIR/.env" 2>/dev/null; set +a; fi
  if [ "${TLS_MODE:-}" = "1" ]; then
    CK_TLS=1; CK_PORT="${HTTPS_PORT:-443}"; CK_HOST="${DOMAIN:-}"; CK_PROTO="https"; CK_PATH="/${WSPATH:-}"
  elif [ "${TLS_MODE:-}" = "0" ]; then
    CK_TLS=0; CK_PORT="${WS_PORT:-8080}"; CK_HOST="${SERVER_IP:-}"; CK_PROTO="http"; CK_PATH="/${WSPATH:-}"
  elif [ -f "$CK_DIR/clash.yaml" ]; then
    CK_PORT="$(grep -m1 -E '^    port: ' "$CK_DIR/clash.yaml" | awk '{print $2}')"
    CK_TLS_TXT="$(grep -m1 -E '^    tls: ' "$CK_DIR/clash.yaml" | awk '{print $2}')"
    CK_HOST="$(grep -m1 -E '^    server: ' "$CK_DIR/clash.yaml" | awk '{print $2}')"
    CK_PATH="$(grep -m1 -E '^      path: ' "$CK_DIR/clash.yaml" | awk '{print $2}')"
    if [ "$CK_TLS_TXT" = "true" ]; then CK_TLS=1; CK_PROTO="https"; else CK_TLS=0; CK_PROTO="http"; fi
    [ -n "$CK_PORT" ] || CK_PORT=443
  fi
  if [ -z "$CK_HOST" ] || [ -z "$CK_PORT" ]; then
    warn "没找到节点端口记录（.env / clash.yaml 都不在），跳过端口自检"
    echo "       按默认端口 443（TLS）/ 8080（明文）核对即可"
  elif [ -n "$CK_PATH" ] && [ "$CK_PATH" != "/" ]; then
    ck_ws_handshake "节点 1" "$CK_PROTO" "$CK_HOST" "$CK_PORT" "${CK_PATH#/}"
  else
    echo "  节点地址：$CK_PROTO://$CK_HOST:$CK_PORT/"
    CK_CODE="$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "$CK_PROTO://$CK_HOST:$CK_PORT/" || true)"
    echo "  首页 -> HTTP $CK_CODE"
    if [ "$CK_CODE" = "200" ]; then pass "节点端口 $CK_PORT 可达"; else fail "节点端口 $CK_PORT 不可达（HTTP $CK_CODE）"; fi
  fi
fi
else
# sing-box 核心：逐节点查公开端口是否在监听
port_listening_tcp() {
  local port="$1" hex
  if command -v ss >/dev/null 2>&1; then
    ss -tln 2>/dev/null | grep -qE "[:.]${port}[[:space:]]"
  else
    hex=$(printf '%04X' "$port")
    grep -qiE "^[[:space:]]*[0-9]+:[[:space:]]+[0-9A-Fa-f]+:${hex}[[:space:]]" /proc/net/tcp /proc/net/tcp6 2>/dev/null
  fi
}
port_listening_udp() {
  local port="$1" hex
  if command -v ss >/dev/null 2>&1; then
    ss -uln 2>/dev/null | grep -qE "[:.]${port}[[:space:]]"
  else
    hex=$(printf '%04X' "$port")
    grep -qiE "^[[:space:]]*[0-9]+:[[:space:]]+[0-9A-Fa-f]+:${hex}[[:space:]]" /proc/net/udp /proc/net/udp6 2>/dev/null
  fi
}
check_port() { # check_port 名字 端口 tcp|udp|both
  local name="$1" port="$2" proto="$3" ok=1
  case "$proto" in
    tcp) port_listening_tcp "$port" || ok=0 ;;
    udp) port_listening_udp "$port" || ok=0 ;;
    both) { port_listening_tcp "$port" && port_listening_udp "$port"; } || ok=0 ;;
  esac
  if [ "$ok" = "1" ]; then pass "$name 正在监听（端口 $port/$proto）"; else fail "$name 未监听（端口 $port/$proto），容器可能没起来，或端口被别的程序占了"; fi
}
if [ -f "$CK_REG" ]; then
  echo "  端口配置来自 $CK_REG（逐节点检查）"
  CK_HTTPS="$(ck_reg_get GLOBAL_HTTPS_PORT)"; [ -n "$CK_HTTPS" ] || CK_HTTPS=443
  _any_tls=0
  for _ni in $(ck_node_indices); do
    [ "$(ck_node_field "$_ni" TLS_MODE)" = "1" ] && _any_tls=1
  done
  [ "$_any_tls" = "1" ] && check_port "HTTPS(WS，共用)" "$CK_HTTPS" tcp
  for _ni in $(ck_node_indices); do
    _tls="$(ck_node_field "$_ni" TLS_MODE)"
    _dom="$(ck_node_field "$_ni" DOMAIN)"
    if [ "$_tls" = "1" ]; then
      check_port "节点 $_ni（$_dom）Shadowsocks" "$(ck_node_field "$_ni" SS_PORT)" both
      if [ "$(ck_node_field "$_ni" HY2_ENABLED)" = "1" ]; then
        check_port "节点 $_ni（$_dom）Hysteria2" "$(ck_node_field "$_ni" HY2_PORT)" udp
        check_port "节点 $_ni（$_dom）TUIC" "$(ck_node_field "$_ni" TUIC_PORT)" udp
      else
        echo "  节点 $_ni（$_dom）Hysteria2/TUIC 未启用"
        echo "       证书没拿到时自动去掉的，重跑 install.sh 可补上"
      fi
    else
      check_port "节点 $_ni（明文）VLESS" "$(ck_node_field "$_ni" VLESS_PORT)" tcp
      check_port "节点 $_ni（明文）Trojan" "$(ck_node_field "$_ni" TROJAN_PORT)" tcp
      check_port "节点 $_ni（明文）VMess" "$(ck_node_field "$_ni" VMESS_PORT)" tcp
      check_port "节点 $_ni（明文）Shadowsocks" "$(ck_node_field "$_ni" SS_PORT)" both
    fi
  done
  unset _ni _tls _dom _any_tls
else
  # 旧版单节点：端口从安装目录的 .env 读（install.sh 安装时写入实际端口）；没有 .env 就用默认端口
  if [ -f "$CK_DIR/.env" ]; then
    set -a; . "$CK_DIR/.env"; set +a
    echo "  端口配置来自 $CK_DIR/.env"
  else
    echo "  未找到 .env，按默认端口检查"
    echo "       TLS：HTTPS 443 / SS 8388 / HY2 8443 / TUIC 8444；明文：8080/8081/8082/8388"
  fi
  TLS_MODE="${TLS_MODE:-1}"
  HTTPS_PORT="${HTTPS_PORT:-443}"; SS_PORT="${SS_PORT:-8388}"; HY2_PORT="${HY2_PORT:-8443}"; TUIC_PORT="${TUIC_PORT:-8444}"
  VLESS_PORT="${VLESS_PORT:-8080}"; TROJAN_PORT="${TROJAN_PORT:-8081}"; VMESS_PORT="${VMESS_PORT:-8082}"
  if [ "$TLS_MODE" = "1" ]; then
    check_port "HTTPS(WS)" "$HTTPS_PORT" tcp
    check_port "Shadowsocks" "$SS_PORT" both
    check_port "Hysteria2" "$HY2_PORT" udp
    check_port "TUIC" "$TUIC_PORT" udp
  else
    check_port "VLESS" "$VLESS_PORT" tcp
    check_port "Trojan" "$TROJAN_PORT" tcp
    check_port "VMess" "$VMESS_PORT" tcp
    check_port "Shadowsocks" "$SS_PORT" both
  fi
fi
fi

section "7/7 证书与续签"
# 证书方式与到期天数：TLS 节点逐个查；有 nodes.conf 时逐节点读，没有就按旧版单节点（.env）读
# DNS 验证用一张泛域名证书，所有 TLS 节点共用，只查一次（sing-box 核心）
ck_cert_days() {  # ck_cert_days 节点名 域名 HTTPS端口 证书方式
  local name="$1" dom="$2" hp="$3" cm="$4"
  if [ "$cm" = "dns" ]; then
    local _base
    _base="$(ck_reg_get GLOBAL_BASE_DOMAIN)"
    if [ "$CK_CORE" = "sing-box" ] && [ -n "$_base" ]; then
      echo "  节点 $name（$dom）：证书方式 DNS 验证（Cloudflare），泛域名证书 *.${_base}，续签全自动，不用管 80 端口"
    else
      echo "  节点 $name（$dom）：证书方式 DNS 验证（Cloudflare），续签全自动，不用管 80 端口"
    fi
  else
    echo "  节点 $name（$dom）：证书方式默认走 80（HTTP-01），续签要走 80 端口"
    warn "如果域名现在指向中转、且 80 没转到这台机，续签会失败"
    echo "       见 README“手动续签”一节"
  fi
  if command -v openssl >/dev/null 2>&1; then
    local end="" end_epoch="" now_epoch="" days=""
    end="$(timeout 10 openssl s_client -connect "127.0.0.1:$hp" -servername "$dom" </dev/null 2>/dev/null | openssl x509 -noout -enddate 2>/dev/null | sed 's/^notAfter=//')"
    if [ -n "$end" ]; then
      end_epoch="$(date -d "$end" +%s 2>/dev/null || echo "")"
      now_epoch="$(date +%s)"
      if [ -n "$end_epoch" ]; then
        days="$(( (end_epoch - now_epoch) / 86400 ))"
        echo "  证书到期日：$end（剩余约 $days 天）"
        if [ "$days" -lt 0 ]; then
          fail "节点 $name：证书已过期 $(( -days )) 天，节点已不可用"
          echo "       立即按 README“手动续签”处理"
        elif [ "$days" -le 14 ]; then
          warn "节点 $name：证书 14 天内到期，Caddy 会在到期前 30 天内自动续签"
          echo "       到期还没续上就按 README“手动续签”处理"
        elif [ "$days" -le 30 ]; then
          pass "节点 $name：证书剩余 $days 天，Caddy 会自动续签"
        else
          pass "节点 $name：证书剩余 $days 天，Caddy 会在到期前 30 天内自动续签"
        fi
      else
        warn "节点 $name：读到证书但解析不到期日：$end"
      fi
    else
      warn "节点 $name：读不到证书（Caddy 可能没起来，或证书还没签好）；等几分钟再跑 check.sh"
    fi
  else
    warn "本机无 openssl，看不到证书剩余天数（apt install openssl 可装）"
  fi
}
if [ -f "$CK_REG" ]; then
  CK_HTTPS="$(ck_reg_get GLOBAL_HTTPS_PORT)"; [ -n "$CK_HTTPS" ] || CK_HTTPS=443
  CK_CM="$(ck_reg_get GLOBAL_CERT_METHOD)"; [ -n "$CK_CM" ] || CK_CM=http
  _any_tls=0; _dns_checked=0
  for _ni in $(ck_node_indices); do
    if [ "$(ck_node_field "$_ni" TLS_MODE)" = "1" ]; then
      _any_tls=1
      if [ "$CK_CM" = "dns" ] && [ "$CK_CORE" = "sing-box" ]; then
        # 泛域名证书所有节点共用，只查一次（用第一个 TLS 节点的域名去握手，拿到的是同一张泛域名证书）
        if [ "$_dns_checked" = "0" ]; then
          ck_cert_days "节点 $_ni（泛域名证书，所有 TLS 节点共用）" "$(ck_node_field "$_ni" DOMAIN)" "$CK_HTTPS" "dns"
          _dns_checked=1
        fi
      else
        ck_cert_days "节点 $_ni" "$(ck_node_field "$_ni" DOMAIN)" "$CK_HTTPS" "$(ck_node_field "$_ni" CERT_METHOD)"
      fi
    else
      echo "  节点 $_ni（明文）：没有证书（补域名重跑 install.sh 可升级 TLS）"
    fi
  done
  [ "$_any_tls" = "0" ] && echo "  全部节点都是明文模式，没有证书（补域名重跑 install.sh 可升级 TLS）"
  unset _ni _any_tls _dns_checked
elif [ "${TLS_MODE:-}" != "1" ]; then
  echo "  明文模式，没有证书（补域名重跑 install.sh 可升级 TLS）"
else
  if [ "${CERT_METHOD:-http}" = "dns" ]; then
    echo "  证书方式：DNS 验证（Cloudflare），续签全自动，不用管 80 端口"
  else
    echo "  证书方式：默认走 80（HTTP-01），续签要走 80 端口"
    warn "如果域名现在指向中转、且 80 没转到这台机，续签会失败"
    echo "       见 README“手动续签”一节"
  fi
  if [ -n "${DOMAIN:-}" ]; then
    ck_cert_days "节点 1" "${DOMAIN:-}" "${HTTPS_PORT:-443}" "${CERT_METHOD:-http}"
  else
    warn "没找到域名（.env 不在），看不到证书剩余天数"
  fi
fi

section "自检完成"
CHECK_EOF
chmod +x check.sh

if [ "$DRY_RUN" != "1" ]; then
  echo ""
  bash check.sh || true
fi

ask_add_more
