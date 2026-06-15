#!/usr/bin/env bash
# =============================================================================
# deploy/compose.sh — conMon Docker Compose 全栈部署脚本
#
# 包含：conmon-server + PostgreSQL + InfluxDB + Grafana + Nginx
#
# 用法：
#   bash deploy/compose.sh init     # 初始化环境（首次部署）
#   bash deploy/compose.sh up       # 启动所有服务
#   bash deploy/compose.sh down     # 停止所有服务
#   bash deploy/compose.sh restart  # 重启
#   bash deploy/compose.sh status   # 查看状态
#   bash deploy/compose.sh logs     # 查看日志
#   bash deploy/compose.sh upgrade  # 升级 conmon 到最新版
#   bash deploy/compose.sh ps       # 等同于 docker compose ps
# =============================================================================
set -euo pipefail

# ---- 路径配置 ---------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
COMPOSE_DIR="${PROJECT_ROOT}/deployments/compose"
COMPOSE_FILE="${COMPOSE_DIR}/docker-compose.yml"
ENV_FILE="${COMPOSE_DIR}/.env"

# ---- 颜色 -------------------------------------------------------------------
GREEN='\033[0;32m'; CYAN='\033[0;36m'; YELLOW='\033[1;33m'
RED='\033[0;31m'; BOLD='\033[1m'; RESET='\033[0m'
info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; exit 1; }
section() { echo -e "\n${BOLD}>>> $*${RESET}"; }

# ---- 检查依赖 ---------------------------------------------------------------
check_deps() {
  command -v docker &>/dev/null || error "Docker 未安装"
  docker info &>/dev/null      || error "Docker daemon 未运行"

  if docker compose version &>/dev/null 2>&1; then
    COMPOSE_CMD="docker compose"
  elif command -v docker-compose &>/dev/null; then
    COMPOSE_CMD="docker-compose"
  else
    error "Docker Compose 未安装（推荐使用 Docker Compose Plugin）"
  fi
  info "使用: $COMPOSE_CMD"
}

compose() {
  $COMPOSE_CMD -f "$COMPOSE_FILE" --env-file "$ENV_FILE" "$@"
}

# ---- init -------------------------------------------------------------------
cmd_init() {
  section "初始化 Docker Compose 环境"

  check_deps

  # 确保 compose 目录存在
  [[ -d $COMPOSE_DIR ]] || error "Compose 目录不存在: $COMPOSE_DIR"

  # 生成 .env 文件
  if [[ -f $ENV_FILE ]]; then
    info ".env 文件已存在，跳过（如需重新生成请删除后重试）"
  else
    info "生成 .env 文件..."
    cp "${COMPOSE_DIR}/.env.example" "$ENV_FILE"

    # 自动生成强随机密钥
    if command -v openssl &>/dev/null; then
      DB_PASS=$(openssl rand -hex 16)
      JWT_KEY=$(openssl rand -hex 32)
      INFLUX_TOKEN=$(openssl rand -hex 32)
    else
      DB_PASS="conmon_$(date +%s)"
      JWT_KEY="jwt_$(date +%s)_secret"
      INFLUX_TOKEN="influx_$(date +%s)_token"
    fi

    sed -i "s|DB_PASSWORD=.*|DB_PASSWORD=${DB_PASS}|" "$ENV_FILE"
    sed -i "s|JWT_SECRET=.*|JWT_SECRET=${JWT_KEY}|" "$ENV_FILE"
    sed -i "s|INFLUXDB_TOKEN=.*|INFLUXDB_TOKEN=${INFLUX_TOKEN}|" "$ENV_FILE"

    success ".env 文件已生成（密钥已自动随机化）"
    warn "请查看并补充 $ENV_FILE 中的告警渠道配置"
  fi

  # 确保 conmon.yaml 存在
  CONF="${PROJECT_ROOT}/configs/conmon.yaml"
  if [[ ! -f $CONF ]]; then
    warn "配置文件不存在: $CONF"
    info "请创建配置文件后重新运行"
    exit 1
  fi

  success "初始化完成，请执行: bash deploy/compose.sh up"
}

# ---- up ---------------------------------------------------------------------
cmd_up() {
  section "启动 conMon 全栈服务"
  check_deps

  [[ -f $ENV_FILE ]] || error ".env 文件不存在，请先执行: bash deploy/compose.sh init"

  info "拉取最新镜像..."
  compose pull --quiet

  info "启动所有服务..."
  compose up -d --remove-orphans

  # 等待 conmon-server 健康
  local http_port
  http_port=$(grep "^CONMON_HTTP_PORT=" "$ENV_FILE" 2>/dev/null | cut -d= -f2 || echo "11080")
  http_port="${http_port:-11080}"

  info "等待 conMon 服务就绪（最长 60 秒）..."
  local waited=0
  while [[ $waited -lt 60 ]]; do
    if curl -sf "http://localhost:${http_port}/health" &>/dev/null; then
      success "所有服务已就绪！"
      echo ""
      echo -e "  conMon:   ${BOLD}http://localhost:${http_port}${RESET}"
      echo -e "  Grafana:  http://localhost:3000  (admin / 见 .env GRAFANA_PASSWORD)"
      echo ""
      cmd_status
      return
    fi
    sleep 2
    ((waited+=2))
  done
  warn "等待超时，请检查日志: bash deploy/compose.sh logs"
}

# ---- down -------------------------------------------------------------------
cmd_down() {
  section "停止服务"
  check_deps
  compose down
  success "所有服务已停止"
}

# ---- restart ----------------------------------------------------------------
cmd_restart() {
  section "重启服务"
  check_deps
  compose restart
  success "重启完成"
}

# ---- status -----------------------------------------------------------------
cmd_status() {
  check_deps
  echo -e "${BOLD}=== 服务状态 ===${RESET}"
  compose ps
  echo ""

  local http_port
  http_port=$(grep "^CONMON_HTTP_PORT=" "$ENV_FILE" 2>/dev/null | cut -d= -f2 || echo "11080")
  http_port="${http_port:-11080}"

  if curl -sf "http://localhost:${http_port}/health" &>/dev/null; then
    echo -e "${BOLD}=== conMon 健康状态 ===${RESET}"
    curl -s "http://localhost:${http_port}/health" | python3 -m json.tool 2>/dev/null \
      || curl -s "http://localhost:${http_port}/health"
    echo ""
    echo -e "${BOLD}=== 监控摘要 ===${RESET}"
    curl -s "http://localhost:${http_port}/api/v1/status" | python3 -m json.tool 2>/dev/null \
      || true
  else
    warn "conMon 服务未响应"
  fi
}

# ---- logs -------------------------------------------------------------------
cmd_logs() {
  check_deps
  local service="${1:-conmon-server}"
  local follow="${2:-}"

  if [[ $follow == "-f" || $follow == "--follow" ]]; then
    compose logs -f --tail=50 "$service"
  else
    compose logs --tail=100 "$service"
  fi
}

# ---- upgrade ----------------------------------------------------------------
cmd_upgrade() {
  section "升级 conMon"
  check_deps

  local new_version="${1:-}"
  if [[ -n $new_version ]]; then
    sed -i "s|^CONMON_VERSION=.*|CONMON_VERSION=${new_version}|" "$ENV_FILE"
    info "目标版本: $new_version"
  else
    info "使用最新版本"
    sed -i "s|^CONMON_VERSION=.*|CONMON_VERSION=latest|" "$ENV_FILE"
  fi

  info "拉取新镜像..."
  compose pull conmon-server

  info "滚动更新 conmon-server..."
  compose up -d --no-deps conmon-server

  sleep 3
  local http_port
  http_port=$(grep "^CONMON_HTTP_PORT=" "$ENV_FILE" 2>/dev/null | cut -d= -f2 || echo "11080")
  http_port="${http_port:-11080}"

  if curl -sf "http://localhost:${http_port}/health" &>/dev/null; then
    local ver
    ver=$(curl -s "http://localhost:${http_port}/health" | python3 -c "import sys,json; print(json.load(sys.stdin).get('version','unknown'))" 2>/dev/null || echo "unknown")
    success "升级完成，当前版本: $ver"
  else
    warn "升级后服务未响应，请检查日志: bash deploy/compose.sh logs"
  fi
}

# ---- cleanup ----------------------------------------------------------------
cmd_cleanup() {
  warn "这将停止所有服务并删除所有数据（不可恢复！）"
  read -r -p "请输入 'DELETE ALL' 确认: " confirm
  [[ $confirm == "DELETE ALL" ]] || { info "取消"; exit 0; }

  check_deps
  compose down -v --remove-orphans
  success "所有服务和数据已清除"
}

# ---- exec -------------------------------------------------------------------
cmd_exec() {
  check_deps
  compose exec conmon-server "${@:-/bin/sh}"
}

# ---- 帮助 -------------------------------------------------------------------
usage() {
  echo "用法: bash deploy/compose.sh <命令> [选项]"
  echo ""
  echo "命令:"
  echo "  init               初始化（生成 .env、检查配置）"
  echo "  up                 启动所有服务"
  echo "  down               停止所有服务"
  echo "  restart            重启所有服务"
  echo "  status             查看服务状态和健康信息"
  echo "  logs [svc] [-f]    查看日志（默认: conmon-server）"
  echo "  upgrade [VERSION]  升级 conmon-server"
  echo "  ps                 显示容器列表"
  echo "  exec [CMD]         在 conmon-server 容器内执行命令"
  echo "  cleanup            停止并删除所有数据（危险！）"
  echo ""
  echo "示例:"
  echo "  bash deploy/compose.sh init"
  echo "  bash deploy/compose.sh up"
  echo "  bash deploy/compose.sh logs conmon-server -f"
  echo "  bash deploy/compose.sh upgrade v2.1.0"
}

# ---- 主入口 -----------------------------------------------------------------
case "${1:-help}" in
  init)    cmd_init ;;
  up)      cmd_up ;;
  down)    cmd_down ;;
  restart) cmd_restart ;;
  status)  cmd_status ;;
  logs)    shift; cmd_logs "${@:-}" ;;
  upgrade) shift; cmd_upgrade "${1:-}" ;;
  ps)      check_deps; compose ps ;;
  exec)    shift; cmd_exec "${@}" ;;
  cleanup) cmd_cleanup ;;
  help|-h|--help) usage ;;
  *) error "未知命令: $1，使用 help 查看帮助" ;;
esac
