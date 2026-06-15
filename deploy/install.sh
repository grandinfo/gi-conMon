#!/usr/bin/env bash
# =============================================================================
# deploy/install.sh — conMon 二进制一键安装脚本
#
# 用法：
#   sudo bash deploy/install.sh                        # 使用默认配置
#   sudo bash deploy/install.sh --version v2.0.0       # 指定版本
#   sudo bash deploy/install.sh --config /my/conf.yaml # 指定配置文件
#   sudo bash deploy/install.sh --no-service           # 不注册 systemd 服务
#
# 适用系统：Linux（x86_64 / arm64），需要 root 权限
# =============================================================================
set -euo pipefail

# ---- 颜色 -------------------------------------------------------------------
RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; exit 1; }
step()    { echo -e "\n${BOLD}>>> $*${RESET}"; }

# ---- 默认参数 ---------------------------------------------------------------
VERSION="latest"
INSTALL_DIR="/usr/local/bin"
CONFIG_DIR="/etc/conmon"
DATA_DIR="/var/lib/conmon"
LOG_DIR="/var/log/conmon"
CONFIG_SRC=""
NO_SERVICE=false
CONMON_USER="conmon"
GITHUB_REPO="grandinfo/gi-conMon"

# ---- 解析参数 ---------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case $1 in
    --version=*) VERSION="${1#--version=}" ;;
    --version)   shift; VERSION="$1" ;;
    --config=*)  CONFIG_SRC="${1#--config=}" ;;
    --config)    shift; CONFIG_SRC="$1" ;;
    --no-service) NO_SERVICE=true ;;
    -h|--help)
      echo "用法: sudo bash install.sh [选项]"
      echo ""
      echo "选项:"
      echo "  --version VERSION    指定版本号（默认: latest）"
      echo "  --config  PATH       指定配置文件路径（默认: 使用内置示例）"
      echo "  --no-service         跳过 systemd 服务注册"
      exit 0 ;;
    *) warn "未知参数: $1" ;;
  esac
  shift
done

# ---- 权限检查 ---------------------------------------------------------------
[[ $EUID -eq 0 ]] || error "请使用 root 权限运行: sudo bash $0"

# ---- 系统检测 ---------------------------------------------------------------
step "检测系统环境"

OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
ARCH="$(uname -m)"
case $ARCH in
  x86_64)  ARCH_GO="amd64" ;;
  aarch64|arm64) ARCH_GO="arm64" ;;
  *) error "不支持的架构: $ARCH" ;;
esac

[[ $OS == "linux" ]] || error "本脚本仅支持 Linux，当前系统: $OS"
info "操作系统: $OS / $ARCH_GO"

# ---- 解析版本号 -------------------------------------------------------------
step "获取版本信息"

if [[ $VERSION == "latest" ]]; then
  info "查询最新版本..."
  if command -v curl &>/dev/null; then
    VERSION=$(curl -sf "https://api.github.com/repos/${GITHUB_REPO}/releases/latest" \
      | grep '"tag_name"' | head -1 | sed 's/.*"tag_name": "\(.*\)".*/\1/')
  fi
  [[ -n $VERSION ]] || VERSION="v2.0.0"
fi
info "目标版本: $VERSION"

BINARY_URL="https://github.com/${GITHUB_REPO}/releases/download/${VERSION}/conmon-linux-${ARCH_GO}.tar.gz"

# ---- 创建用户和目录 ---------------------------------------------------------
step "创建系统用户和目录"

if ! id "$CONMON_USER" &>/dev/null; then
  useradd -r -s /sbin/nologin -d "$DATA_DIR" -M "$CONMON_USER"
  success "创建系统用户: $CONMON_USER"
else
  info "系统用户 $CONMON_USER 已存在"
fi

for dir in "$CONFIG_DIR" "$DATA_DIR" "$LOG_DIR"; do
  mkdir -p "$dir"
done
chown -R "${CONMON_USER}:${CONMON_USER}" "$DATA_DIR" "$LOG_DIR"
chmod 750 "$DATA_DIR" "$LOG_DIR"
chmod 755 "$CONFIG_DIR"
success "目录创建完成"

# ---- 下载二进制 -------------------------------------------------------------
step "下载 conmon 二进制"

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

# 优先使用本地已构建的二进制
LOCAL_BINARY="./bin/conmon"
if [[ -x "$LOCAL_BINARY" ]]; then
  info "使用本地构建的二进制: $LOCAL_BINARY"
  cp "$LOCAL_BINARY" "$TMP_DIR/conmon"
else
  info "从 GitHub 下载: $BINARY_URL"
  if command -v curl &>/dev/null; then
    curl -L --progress-bar -o "$TMP_DIR/conmon.tar.gz" "$BINARY_URL" \
      || error "下载失败，请检查网络或版本号是否正确"
  else
    wget -O "$TMP_DIR/conmon.tar.gz" "$BINARY_URL" \
      || error "下载失败，请安装 curl 或 wget"
  fi
  tar -xzf "$TMP_DIR/conmon.tar.gz" -C "$TMP_DIR/"
fi

install -m 755 "$TMP_DIR/conmon" "${INSTALL_DIR}/conmon"
success "安装完成: ${INSTALL_DIR}/conmon"

# ---- 设置 ICMP 权限 ---------------------------------------------------------
step "设置 ICMP 探测权限"

if command -v setcap &>/dev/null; then
  setcap cap_net_raw+ep "${INSTALL_DIR}/conmon"
  success "CAP_NET_RAW 权限设置成功（支持 ICMP Ping 探测）"
else
  warn "setcap 未安装，跳过 ICMP 权限配置（ICMP 探测将不可用）"
  warn "可稍后执行: sudo setcap cap_net_raw+ep ${INSTALL_DIR}/conmon"
fi

# ---- 安装配置文件 -----------------------------------------------------------
step "安装配置文件"

if [[ -n $CONFIG_SRC && -f $CONFIG_SRC ]]; then
  cp "$CONFIG_SRC" "${CONFIG_DIR}/conmon.yaml"
  success "使用指定配置: $CONFIG_SRC"
elif [[ ! -f "${CONFIG_DIR}/conmon.yaml" ]]; then
  # 写入内置默认配置
  cat > "${CONFIG_DIR}/conmon.yaml" << 'YAML'
server:
  bind: "0.0.0.0:8080"
  external_url: "http://localhost:8080"
  auth:
    jwt_secret: "CHANGE_ME_USE_STRONG_RANDOM_SECRET"
    token_expire: "24h"

storage:
  type: "sqlite"
  path: "/var/lib/conmon/conmon.db"
  retention:
    raw: "168h"
    events: "2160h"
    alerts: "4320h"

probe:
  id: "probe-local-01"
  name: "本地探针"
  location: "本地"
  concurrency: 100

monitors:
  - name: "自身健康检查"
    target: "localhost"
    protocol: "http"
    port: 8080
    interval: "30s"
    probe_config:
      path: "/health"
      expected_codes: [200]

alerting:
  channels: []
  rules:
    - name: "服务宕机"
      condition: "event.to_status == 'DOWN'"
      channels: []
      severity: "error"
      throttle: "10m"

log:
  level: "info"
  format: "json"
  output: "stdout"
YAML
  chown root:"$CONMON_USER" "${CONFIG_DIR}/conmon.yaml"
  chmod 640 "${CONFIG_DIR}/conmon.yaml"
  success "默认配置已写入: ${CONFIG_DIR}/conmon.yaml"
else
  info "配置文件已存在，跳过（${CONFIG_DIR}/conmon.yaml）"
fi

# 创建环境变量文件（存放敏感信息）
ENV_FILE="${CONFIG_DIR}/conmon.env"
if [[ ! -f $ENV_FILE ]]; then
  cat > "$ENV_FILE" << 'ENV'
# conMon 环境变量文件 — 存放敏感配置
# 修改后执行: sudo systemctl restart conmon

# 数据库密码（PostgreSQL 模式需要）
# DB_PASSWORD=your-database-password

# JWT 密钥（建议使用随机字符串：openssl rand -hex 32）
JWT_SECRET=CHANGE_ME_USE_STRONG_RANDOM_SECRET

# 钉钉 Webhook
# DINGTALK_WEBHOOK_URL=https://oapi.dingtalk.com/robot/send?access_token=xxx
# DINGTALK_SECRET=xxx

# 企业微信 Webhook
# WECOM_WEBHOOK_URL=https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=xxx
ENV
  chown root:"$CONMON_USER" "$ENV_FILE"
  chmod 640 "$ENV_FILE"
  success "环境变量文件: $ENV_FILE"
fi

# ---- 注册 systemd 服务 ------------------------------------------------------
if [[ $NO_SERVICE == false ]] && command -v systemctl &>/dev/null; then
  step "注册 systemd 服务"

  cat > /etc/systemd/system/conmon.service << UNIT
[Unit]
Description=conMon Network Connection Monitor v2.0
Documentation=https://github.com/${GITHUB_REPO}
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${CONMON_USER}
Group=${CONMON_USER}
ExecStart=${INSTALL_DIR}/conmon server -c ${CONFIG_DIR}/conmon.yaml
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=5s
TimeoutStopSec=30s
KillSignal=SIGTERM

# 安全加固
PrivateTmp=true
ProtectSystem=strict
ReadWritePaths=${DATA_DIR} ${LOG_DIR}
NoNewPrivileges=true
AmbientCapabilities=CAP_NET_RAW

# 环境变量
EnvironmentFile=-${ENV_FILE}

# 资源限制
LimitNOFILE=65536
LimitNPROC=4096

StandardOutput=journal
StandardError=journal
SyslogIdentifier=conmon

[Install]
WantedBy=multi-user.target
UNIT

  systemctl daemon-reload
  systemctl enable conmon
  success "systemd 服务已注册并设置开机自启"
fi

# ---- 验证安装 ---------------------------------------------------------------
step "验证安装"

"${INSTALL_DIR}/conmon" version
success "conmon 二进制验证通过"

# ---- 完成提示 ---------------------------------------------------------------
echo
echo -e "${GREEN}${BOLD}"
echo "╔══════════════════════════════════════════════════════╗"
echo "║            conMon 安装完成！                         ║"
echo "╚══════════════════════════════════════════════════════╝"
echo -e "${RESET}"
echo -e "  安装路径:  ${INSTALL_DIR}/conmon"
echo -e "  配置文件:  ${CONFIG_DIR}/conmon.yaml"
echo -e "  数据目录:  ${DATA_DIR}"
echo -e "  日志目录:  ${LOG_DIR}"
echo ""

if [[ $NO_SERVICE == false ]] && command -v systemctl &>/dev/null; then
  echo -e "  ${BOLD}启动服务：${RESET}"
  echo "    sudo systemctl start conmon"
  echo "    sudo systemctl status conmon"
  echo ""
  echo -e "  ${BOLD}查看日志：${RESET}"
  echo "    sudo journalctl -u conmon -f"
fi

echo ""
echo -e "  ${YELLOW}重要：${RESET}请修改以下配置中的默认密钥："
echo "    1. ${ENV_FILE}  →  JWT_SECRET"
echo "    2. ${CONFIG_DIR}/conmon.yaml  →  配置监控目标"
echo ""
echo -e "  ${BOLD}服务地址：${RESET}http://localhost:8080"
echo "  健康检查: curl http://localhost:8080/health"
echo ""
