#!/usr/bin/env bash
# =============================================================================
# deploy/docker.sh — conMon Docker 单机部署脚本
#
# 用法：
#   bash deploy/docker.sh start              # 启动容器
#   bash deploy/docker.sh stop               # 停止容器
#   bash deploy/docker.sh restart            # 重启容器
#   bash deploy/docker.sh status             # 查看状态
#   bash deploy/docker.sh logs [-f]          # 查看日志
#   bash deploy/docker.sh update [VERSION]   # 更新到新版本
#   bash deploy/docker.sh remove             # 移除容器（保留数据）
# =============================================================================
set -euo pipefail

# ---- 配置 -------------------------------------------------------------------
CONTAINER_NAME="conmon"
IMAGE="conmon/conmon"
VERSION="${CONMON_VERSION:-latest}"
HTTP_PORT="${CONMON_HTTP_PORT:-8080}"
GRPC_PORT="${CONMON_GRPC_PORT:-9090}"
CONFIG_FILE="${CONMON_CONFIG:-$(pwd)/configs/conmon.yaml}"
DATA_VOLUME="conmon-data"
LOG_VOLUME="conmon-logs"

# ---- 颜色 -------------------------------------------------------------------
GREEN='\033[0;32m'; CYAN='\033[0;36m'; YELLOW='\033[1;33m'
RED='\033[0;31m'; BOLD='\033[1m'; RESET='\033[0m'
info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; exit 1; }

# ---- 检查 Docker ------------------------------------------------------------
check_docker() {
  command -v docker &>/dev/null || error "Docker 未安装，请先安装 Docker"
  docker info &>/dev/null      || error "Docker daemon 未运行，请执行: sudo systemctl start docker"
}

# ---- 命令函数 ---------------------------------------------------------------
cmd_start() {
  check_docker
  echo -e "${BOLD}>>> 启动 conMon 容器${RESET}"

  # 检查配置文件
  if [[ ! -f $CONFIG_FILE ]]; then
    warn "配置文件不存在: $CONFIG_FILE"
    warn "将使用容器内置默认配置"
    CONFIG_MOUNT=""
  else
    CONFIG_MOUNT="-v ${CONFIG_FILE}:/etc/conmon/conmon.yaml:ro"
    info "配置文件: $CONFIG_FILE"
  fi

  # 检查容器是否已运行
  if docker ps -q -f name="^/${CONTAINER_NAME}$" | grep -q .; then
    warn "容器 $CONTAINER_NAME 已在运行"
    echo "  停止: bash deploy/docker.sh stop"
    echo "  重启: bash deploy/docker.sh restart"
    exit 0
  fi

  # 移除已停止的同名容器
  if docker ps -aq -f name="^/${CONTAINER_NAME}$" | grep -q .; then
    info "移除旧容器..."
    docker rm "$CONTAINER_NAME"
  fi

  # 构建 docker run 参数
  RUN_ARGS=(
    "--name" "$CONTAINER_NAME"
    "--restart" "unless-stopped"
    "-p" "${HTTP_PORT}:8080"
    "-p" "${GRPC_PORT}:9090"
    "-v" "${DATA_VOLUME}:/var/lib/conmon"
    "-v" "${LOG_VOLUME}:/var/log/conmon"
  )

  # 注入环境变量
  [[ -n "${JWT_SECRET:-}" ]]       && RUN_ARGS+=("-e" "JWT_SECRET=${JWT_SECRET}")
  [[ -n "${DB_PASSWORD:-}" ]]      && RUN_ARGS+=("-e" "DB_PASSWORD=${DB_PASSWORD}")
  [[ -n "${INFLUXDB_TOKEN:-}" ]]   && RUN_ARGS+=("-e" "INFLUXDB_TOKEN=${INFLUXDB_TOKEN}")
  [[ -n "${DINGTALK_WEBHOOK_URL:-}" ]] && RUN_ARGS+=("-e" "DINGTALK_WEBHOOK_URL=${DINGTALK_WEBHOOK_URL}")
  [[ -n "${WECOM_WEBHOOK_URL:-}" ]] && RUN_ARGS+=("-e" "WECOM_WEBHOOK_URL=${WECOM_WEBHOOK_URL}")

  # 加载 .env 文件（如果存在）
  if [[ -f .env ]]; then
    RUN_ARGS+=("--env-file" ".env")
    info "加载环境变量: .env"
  fi

  [[ -n "${CONFIG_MOUNT:-}" ]] && RUN_ARGS+=($CONFIG_MOUNT)

  docker run -d "${RUN_ARGS[@]}" "${IMAGE}:${VERSION}"

  # 等待健康检查
  info "等待服务就绪..."
  local max_wait=30 waited=0
  while [[ $waited -lt $max_wait ]]; do
    if curl -sf "http://localhost:${HTTP_PORT}/health" &>/dev/null; then
      success "conMon 启动成功！"
      echo ""
      echo -e "  Web UI:      ${BOLD}http://localhost:${HTTP_PORT}${RESET}"
      echo -e "  健康检查:    curl http://localhost:${HTTP_PORT}/health"
      echo -e "  API 状态:    curl http://localhost:${HTTP_PORT}/api/v1/status"
      echo -e "  查看日志:    docker logs -f ${CONTAINER_NAME}"
      return
    fi
    sleep 1
    ((waited++))
  done
  warn "等待超时，请手动检查: docker logs $CONTAINER_NAME"
}

cmd_stop() {
  check_docker
  if docker ps -q -f name="^/${CONTAINER_NAME}$" | grep -q .; then
    docker stop "$CONTAINER_NAME"
    success "容器已停止: $CONTAINER_NAME"
  else
    info "容器未运行"
  fi
}

cmd_restart() {
  cmd_stop
  sleep 1
  cmd_start
}

cmd_status() {
  check_docker
  echo -e "${BOLD}=== 容器状态 ===${RESET}"
  docker ps -a -f name="^/${CONTAINER_NAME}$" --format \
    "table {{.Names}}\t{{.Status}}\t{{.Image}}\t{{.Ports}}" 2>/dev/null || true
  echo ""

  if docker ps -q -f name="^/${CONTAINER_NAME}$" | grep -q .; then
    echo -e "${BOLD}=== 健康检查 ===${RESET}"
    curl -sf "http://localhost:${HTTP_PORT}/health" | python3 -m json.tool 2>/dev/null \
      || curl -sf "http://localhost:${HTTP_PORT}/health" || warn "健康检查失败"
    echo ""
    echo -e "${BOLD}=== 资源使用 ===${RESET}"
    docker stats "$CONTAINER_NAME" --no-stream --format \
      "CPU: {{.CPUPerc}}  内存: {{.MemUsage}}  网络: {{.NetIO}}" 2>/dev/null || true
  fi
}

cmd_logs() {
  check_docker
  if [[ "${1:-}" == "-f" ]]; then
    docker logs -f "$CONTAINER_NAME"
  else
    docker logs --tail=100 "$CONTAINER_NAME"
  fi
}

cmd_update() {
  check_docker
  local new_version="${1:-latest}"
  echo -e "${BOLD}>>> 更新到版本: ${new_version}${RESET}"

  # 拉取新镜像
  info "拉取镜像: ${IMAGE}:${new_version}"
  docker pull "${IMAGE}:${new_version}"

  # 停止旧容器
  cmd_stop

  # 更新版本变量并重启
  VERSION="$new_version"
  cmd_start

  success "更新完成: ${IMAGE}:${new_version}"
}

cmd_remove() {
  check_docker
  warn "这将移除容器（数据卷 ${DATA_VOLUME} 将保留）"
  read -r -p "确认移除? [y/N] " confirm
  [[ $confirm =~ ^[Yy]$ ]] || { info "取消"; exit 0; }

  docker stop "$CONTAINER_NAME" 2>/dev/null || true
  docker rm "$CONTAINER_NAME" 2>/dev/null || true
  success "容器已移除（数据已保留）"
  info "如需清除数据: docker volume rm ${DATA_VOLUME} ${LOG_VOLUME}"
}

cmd_exec() {
  check_docker
  docker exec -it "$CONTAINER_NAME" "${@:-/bin/sh}"
}

# ---- 帮助 -------------------------------------------------------------------
usage() {
  echo "用法: bash deploy/docker.sh <命令> [选项]"
  echo ""
  echo "命令:"
  echo "  start              启动 conMon 容器"
  echo "  stop               停止容器"
  echo "  restart            重启容器"
  echo "  status             查看容器状态和健康信息"
  echo "  logs [-f]          查看日志（-f 实时跟踪）"
  echo "  update [VERSION]   更新到指定版本（默认: latest）"
  echo "  remove             移除容器（保留数据卷）"
  echo "  exec [CMD]         在容器内执行命令"
  echo ""
  echo "环境变量:"
  echo "  CONMON_VERSION     镜像版本（默认: latest）"
  echo "  CONMON_HTTP_PORT   HTTP 端口（默认: 8080）"
  echo "  CONMON_CONFIG      配置文件路径（默认: ./configs/conmon.yaml）"
  echo "  JWT_SECRET         JWT 密钥"
  echo ""
  echo "示例:"
  echo "  bash deploy/docker.sh start"
  echo "  CONMON_VERSION=v2.0.0 bash deploy/docker.sh start"
  echo "  bash deploy/docker.sh logs -f"
  echo "  bash deploy/docker.sh update v2.1.0"
}

# ---- 主入口 -----------------------------------------------------------------
case "${1:-help}" in
  start)   cmd_start ;;
  stop)    cmd_stop ;;
  restart) cmd_restart ;;
  status)  cmd_status ;;
  logs)    shift; cmd_logs "${@}" ;;
  update)  shift; cmd_update "${1:-latest}" ;;
  remove)  cmd_remove ;;
  exec)    shift; cmd_exec "${@}" ;;
  help|-h|--help) usage ;;
  *) error "未知命令: $1，使用 help 查看帮助" ;;
esac
