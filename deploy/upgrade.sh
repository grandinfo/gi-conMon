#!/usr/bin/env bash
# =============================================================================
# deploy/upgrade.sh — conMon 滚动升级脚本
#
# 自动检测当前部署方式（systemd / docker / compose），并执行无停机升级
#
# 用法：
#   bash deploy/upgrade.sh                  # 升级到最新版本
#   bash deploy/upgrade.sh v2.1.0           # 升级到指定版本
#   bash deploy/upgrade.sh --dry-run        # 预览将执行的操作
# =============================================================================
set -euo pipefail

TARGET_VERSION="${1:-latest}"
DRY_RUN=false
[[ "${1:-}" == "--dry-run" ]] && { DRY_RUN=true; TARGET_VERSION="${2:-latest}"; }

GITHUB_REPO="grandinfo/gi-conMon"
INSTALL_DIR="/usr/local/bin"
BACKUP_DIR="/var/backups/conmon"
CONFIG_DIR="/etc/conmon"
DATA_DIR="/var/lib/conmon"

# ---- 颜色 -------------------------------------------------------------------
GREEN='\033[0;32m'; CYAN='\033[0;36m'; YELLOW='\033[1;33m'
RED='\033[0;31m'; BOLD='\033[1m'; RESET='\033[0m'
info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; exit 1; }
section() { echo -e "\n${BOLD}>>> $*${RESET}"; }
dryrun()  { echo -e "  ${YELLOW}[DRY-RUN]${RESET} $*"; }

# ---- 检测部署方式 -----------------------------------------------------------
detect_deploy_mode() {
  if systemctl is-active conmon &>/dev/null 2>&1; then
    echo "systemd"
  elif docker ps -q -f name="^/conmon$" 2>/dev/null | grep -q .; then
    echo "docker"
  elif [[ -f "deployments/compose/docker-compose.yml" ]] && \
       (docker compose -f deployments/compose/docker-compose.yml ps 2>/dev/null | grep -q "conmon"); then
    echo "compose"
  else
    echo "unknown"
  fi
}

# ---- 获取当前版本 -----------------------------------------------------------
get_current_version() {
  if command -v conmon &>/dev/null; then
    conmon version 2>/dev/null | grep -oP 'v\d+\.\d+\.\d+' | head -1 || echo "unknown"
  elif docker ps -q -f name="^/conmon$" &>/dev/null 2>&1; then
    docker exec conmon conmon version 2>/dev/null | grep -oP 'v\d+\.\d+\.\d+' | head -1 || echo "unknown"
  else
    echo "unknown"
  fi
}

# ---- 获取最新版本 -----------------------------------------------------------
get_latest_version() {
  if command -v curl &>/dev/null; then
    curl -sf "https://api.github.com/repos/${GITHUB_REPO}/releases/latest" \
      | grep '"tag_name"' | head -1 | sed 's/.*"tag_name": "\(.*\)".*/\1/' \
      || echo "v2.0.0"
  else
    echo "v2.0.0"
  fi
}

# ---- 备份 -------------------------------------------------------------------
do_backup() {
  local ts
  ts=$(date +%Y%m%d_%H%M%S)
  local backup_path="${BACKUP_DIR}/${ts}"

  if $DRY_RUN; then
    dryrun "备份配置到: $backup_path"
    dryrun "备份 SQLite 数据库"
    return
  fi

  mkdir -p "$backup_path"

  # 备份配置
  if [[ -d $CONFIG_DIR ]]; then
    cp -r "$CONFIG_DIR" "${backup_path}/config"
    success "配置备份: ${backup_path}/config"
  fi

  # 备份 SQLite 数据库
  local db_path="${DATA_DIR}/conmon.db"
  if [[ -f $db_path ]]; then
    cp "$db_path" "${backup_path}/conmon.db"
    success "数据库备份: ${backup_path}/conmon.db"
  fi

  # 备份当前二进制
  if [[ -f "${INSTALL_DIR}/conmon" ]]; then
    cp "${INSTALL_DIR}/conmon" "${backup_path}/conmon.bak"
    success "二进制备份: ${backup_path}/conmon.bak"
  fi

  echo "$backup_path"
}

# ---- systemd 升级 -----------------------------------------------------------
upgrade_systemd() {
  local version=$1

  section "升级 systemd 服务模式"

  local os arch
  os=$(uname -s | tr '[:upper:]' '[:lower:]')
  arch=$(uname -m); [[ $arch == "x86_64" ]] && arch="amd64" || arch="arm64"
  local url="https://github.com/${GITHUB_REPO}/releases/download/${version}/conmon-${os}-${arch}.tar.gz"

  if $DRY_RUN; then
    dryrun "下载: $url"
    dryrun "备份旧二进制并替换"
    dryrun "systemctl restart conmon"
    return
  fi

  local tmp
  tmp=$(mktemp -d)
  trap "rm -rf $tmp" EXIT

  # 优先使用本地构建
  if [[ -x "./bin/conmon" ]]; then
    info "使用本地构建的二进制"
    cp "./bin/conmon" "$tmp/conmon"
  else
    info "下载 $url"
    curl -L --progress-bar -o "$tmp/conmon.tar.gz" "$url"
    tar -xzf "$tmp/conmon.tar.gz" -C "$tmp/"
  fi

  # 替换二进制
  install -m 755 "$tmp/conmon" "${INSTALL_DIR}/conmon"
  command -v setcap &>/dev/null && setcap cap_net_raw+ep "${INSTALL_DIR}/conmon" || true
  success "二进制已更新"

  # 重启服务
  systemctl restart conmon
  sleep 3

  if systemctl is-active conmon &>/dev/null; then
    success "服务重启成功"
  else
    error "服务重启失败，请检查: journalctl -u conmon -n 50"
  fi
}

# ---- docker 升级 ------------------------------------------------------------
upgrade_docker() {
  local version=$1
  section "升级 Docker 单机模式"

  if $DRY_RUN; then
    dryrun "docker pull conmon/conmon:${version}"
    dryrun "docker stop conmon && docker rm conmon"
    dryrun "docker run ... conmon/conmon:${version}"
    return
  fi

  bash "$(dirname "${BASH_SOURCE[0]}")/docker.sh" update "$version"
}

# ---- compose 升级 -----------------------------------------------------------
upgrade_compose() {
  local version=$1
  section "升级 Docker Compose 模式"

  if $DRY_RUN; then
    dryrun "更新 .env 中 CONMON_VERSION=${version}"
    dryrun "docker compose pull conmon-server"
    dryrun "docker compose up -d --no-deps conmon-server"
    return
  fi

  bash "$(dirname "${BASH_SOURCE[0]}")/compose.sh" upgrade "$version"
}

# =============================================================================
# 主流程
# =============================================================================
echo -e "${BOLD}"
echo "╔══════════════════════════════════════════════════════╗"
echo "║           conMon 升级脚本 v2.0                       ║"
echo "╚══════════════════════════════════════════════════════╝"
echo -e "${RESET}"

$DRY_RUN && warn "DRY-RUN 模式：仅显示将执行的操作，不做实际修改"

# 检测部署方式
section "检测环境"
DEPLOY_MODE=$(detect_deploy_mode)
CURRENT_VERSION=$(get_current_version)

info "部署方式:    $DEPLOY_MODE"
info "当前版本:    $CURRENT_VERSION"

# 解析目标版本
if [[ $TARGET_VERSION == "latest" ]]; then
  info "查询最新版本..."
  TARGET_VERSION=$(get_latest_version)
fi
info "目标版本:    $TARGET_VERSION"

# 版本比较（跳过相同版本）
if [[ $CURRENT_VERSION == "$TARGET_VERSION" && $CURRENT_VERSION != "unknown" ]]; then
  success "当前已是最新版本 ($TARGET_VERSION)，无需升级"
  exit 0
fi

# 确认升级
echo ""
echo -e "  将从 ${BOLD}${CURRENT_VERSION}${RESET} 升级到 ${BOLD}${GREEN}${TARGET_VERSION}${RESET}"
echo ""
if ! $DRY_RUN; then
  read -r -p "确认升级? [Y/n] " confirm
  [[ $confirm =~ ^[Nn]$ ]] && { info "取消升级"; exit 0; }
fi

# 备份
section "备份现有数据"
BACKUP_PATH=$(do_backup)
$DRY_RUN || info "备份完成: $BACKUP_PATH"

# 执行升级
case $DEPLOY_MODE in
  systemd) upgrade_systemd "$TARGET_VERSION" ;;
  docker)  upgrade_docker "$TARGET_VERSION" ;;
  compose) upgrade_compose "$TARGET_VERSION" ;;
  unknown)
    warn "未检测到运行中的 conMon 实例"
    if $DRY_RUN; then
      dryrun "将使用 install.sh 进行全新安装"
    else
      read -r -p "执行全新安装? [Y/n] " confirm
      [[ $confirm =~ ^[Nn]$ ]] || bash "$(dirname "${BASH_SOURCE[0]}")/install.sh" --version "$TARGET_VERSION"
    fi ;;
esac

# 升级后验证
if ! $DRY_RUN; then
  section "验证升级结果"
  sleep 2

  ENDPOINT="http://localhost:8080"
  if curl -sf "${ENDPOINT}/health" &>/dev/null; then
    NEW_VER=$(curl -s "${ENDPOINT}/health" | python3 -c \
      "import sys,json; print(json.load(sys.stdin).get('version','unknown'))" 2>/dev/null || echo "unknown")
    success "升级成功！运行版本: $NEW_VER"
  else
    warn "服务未响应，请手动检查"
    echo "  systemd: sudo journalctl -u conmon -n 50"
    echo "  docker:  docker logs conmon"
    echo "  compose: docker compose logs conmon-server"
    echo ""
    echo -e "  ${YELLOW}如需回滚:${RESET}"
    echo "  sudo cp ${BACKUP_PATH}/conmon.bak ${INSTALL_DIR}/conmon"
    echo "  sudo systemctl restart conmon"
  fi
fi

$DRY_RUN && echo -e "\n${GREEN}[DRY-RUN 完成]${RESET} 以上为将执行的操作，实际升级请去掉 --dry-run 参数"
