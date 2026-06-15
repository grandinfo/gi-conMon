#!/usr/bin/env bash
# =============================================================================
# deploy/uninstall.sh — conMon 卸载脚本
#
# 用法：
#   sudo bash deploy/uninstall.sh           # 交互式卸载（保留数据）
#   sudo bash deploy/uninstall.sh --all     # 完全清除（含数据）
#   sudo bash deploy/uninstall.sh --dry-run # 预览将执行的操作
# =============================================================================
set -euo pipefail

REMOVE_DATA=false
DRY_RUN=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --all)     REMOVE_DATA=true ;;
    --dry-run) DRY_RUN=true ;;
    -h|--help)
      echo "用法: sudo bash uninstall.sh [--all] [--dry-run]"
      echo ""
      echo "  --all      同时删除所有数据和配置（不可恢复）"
      echo "  --dry-run  仅显示将执行的操作"
      exit 0 ;;
    *) echo "未知参数: $1" ;;
  esac
  shift
done

# ---- 颜色 -------------------------------------------------------------------
GREEN='\033[0;32m'; CYAN='\033[0;36m'; YELLOW='\033[1;33m'
RED='\033[0;31m'; BOLD='\033[1m'; RESET='\033[0m'
info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
dryrun()  { echo -e "  ${YELLOW}[DRY-RUN]${RESET} $*"; }
section() { echo -e "\n${BOLD}>>> $*${RESET}"; }

run() {
  if $DRY_RUN; then dryrun "$*"
  else eval "$*"
  fi
}

# ---- 权限检查 ---------------------------------------------------------------
[[ $EUID -eq 0 ]] || { warn "建议使用 root 权限运行"; }

echo -e "${BOLD}"
echo "╔══════════════════════════════════════════════════════╗"
echo "║              conMon 卸载脚本                         ║"
echo "╚══════════════════════════════════════════════════════╝"
echo -e "${RESET}"

$DRY_RUN && warn "DRY-RUN 模式，不执行实际操作"

if ! $DRY_RUN; then
  echo -e "${RED}警告: 此操作将卸载 conMon！${RESET}"
  $REMOVE_DATA && echo -e "${RED}--all 标志: 所有数据和配置将被永久删除！${RESET}"
  echo ""
  read -r -p "确认卸载? 输入 'yes' 继续: " confirm
  [[ $confirm == "yes" ]] || { info "取消卸载"; exit 0; }
fi

# ---- 停止并禁用 systemd 服务 ------------------------------------------------
section "停止 systemd 服务"

if systemctl is-active conmon &>/dev/null 2>&1; then
  run "systemctl stop conmon"
  success "服务已停止"
else
  info "服务未运行"
fi

if systemctl is-enabled conmon &>/dev/null 2>&1; then
  run "systemctl disable conmon"
  success "开机自启已禁用"
fi

if [[ -f /etc/systemd/system/conmon.service ]]; then
  run "rm -f /etc/systemd/system/conmon.service"
  run "systemctl daemon-reload"
  success "systemd unit 文件已删除"
fi

# ---- 停止 Docker 容器 -------------------------------------------------------
section "清理 Docker 资源"

if command -v docker &>/dev/null; then
  # 停止并删除容器
  for container in conmon conmon-server; do
    if docker ps -aq -f name="^/${container}$" 2>/dev/null | grep -q .; then
      run "docker stop $container 2>/dev/null || true"
      run "docker rm $container 2>/dev/null || true"
      success "Docker 容器已删除: $container"
    fi
  done

  # Docker Compose 资源
  if [[ -f "deployments/compose/docker-compose.yml" ]]; then
    if docker compose -f deployments/compose/docker-compose.yml ps 2>/dev/null | grep -q conmon; then
      run "docker compose -f deployments/compose/docker-compose.yml down"
      success "Docker Compose 服务已停止"
    fi
  fi

  $REMOVE_DATA && {
    info "清理 Docker 数据卷..."
    for vol in conmon-data conmon-logs; do
      if docker volume inspect "$vol" &>/dev/null 2>&1; then
        run "docker volume rm $vol"
        success "数据卷已删除: $vol"
      fi
    done
  }
fi

# ---- 删除二进制 -------------------------------------------------------------
section "删除二进制文件"

for bin_path in /usr/local/bin/conmon /usr/bin/conmon; do
  if [[ -f $bin_path ]]; then
    run "rm -f $bin_path"
    success "已删除: $bin_path"
  fi
done

# ---- 删除配置（可选）--------------------------------------------------------
if $REMOVE_DATA; then
  section "删除配置和数据（--all 模式）"

  warn "以下目录将被永久删除："
  for dir in /etc/conmon /var/lib/conmon /var/log/conmon; do
    [[ -d $dir ]] && echo "  - $dir ($(du -sh $dir 2>/dev/null | cut -f1))"
  done

  if ! $DRY_RUN; then
    read -r -p "最后确认删除所有数据? [y/N] " final_confirm
    [[ $final_confirm =~ ^[Yy]$ ]] || { warn "跳过数据删除"; REMOVE_DATA=false; }
  fi

  if $REMOVE_DATA; then
    for dir in /etc/conmon /var/lib/conmon /var/log/conmon; do
      if [[ -d $dir ]]; then
        run "rm -rf $dir"
        success "已删除: $dir"
      fi
    done
  fi
fi

# ---- 删除系统用户（可选）---------------------------------------------------
if $REMOVE_DATA && id conmon &>/dev/null 2>&1; then
  section "删除系统用户"
  run "userdel conmon 2>/dev/null || true"
  success "系统用户 conmon 已删除"
fi

# ---- 汇总 -------------------------------------------------------------------
section "卸载完成"
echo ""

if $DRY_RUN; then
  echo -e "${YELLOW}[DRY-RUN] 以上为将执行的操作，实际卸载请去掉 --dry-run 参数${RESET}"
else
  echo -e "${GREEN}✓ conMon 卸载成功${RESET}"
  echo ""

  if ! $REMOVE_DATA; then
    echo -e "  ${BOLD}保留的数据：${RESET}"
    [[ -d /etc/conmon ]]       && echo "  配置文件:  /etc/conmon"
    [[ -d /var/lib/conmon ]]   && echo "  数据目录:  /var/lib/conmon"
    [[ -d /var/log/conmon ]]   && echo "  日志目录:  /var/log/conmon"
    echo ""
    echo -e "  如需完全清除: ${BOLD}sudo bash deploy/uninstall.sh --all${RESET}"
  fi
fi
