#!/usr/bin/env bash
# =============================================================================
# deploy/check.sh — conMon 部署前环境预检脚本
# 用法：bash deploy/check.sh [--mode binary|docker|compose|k8s]
# =============================================================================
set -euo pipefail

# ---- 颜色输出 ---------------------------------------------------------------
RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

PASS="${GREEN}[PASS]${RESET}"; WARN="${YELLOW}[WARN]${RESET}"; FAIL="${RED}[FAIL]${RESET}"
INFO="${CYAN}[INFO]${RESET}"

PASS_COUNT=0; WARN_COUNT=0; FAIL_COUNT=0
MODE="${1:-binary}"

log_pass() { echo -e "${PASS} $*"; PASS_COUNT=$((PASS_COUNT+1)); }
log_warn() { echo -e "${WARN} $*"; WARN_COUNT=$((WARN_COUNT+1)); }
log_fail() { echo -e "${FAIL} $*"; FAIL_COUNT=$((FAIL_COUNT+1)); }
log_info() { echo -e "${INFO} $*"; }
section()  { echo -e "\n${BOLD}══ $* ══${RESET}"; }

# ---- 解析参数 ---------------------------------------------------------------
for arg in "$@"; do
  case $arg in
    --mode=*) MODE="${arg#--mode=}" ;;
    --mode)   shift; MODE="${1:-binary}" ;;
  esac
done

echo -e "${BOLD}"
echo "╔══════════════════════════════════════════════════════╗"
echo "║       conMon 部署前环境预检工具  v2.0                ║"
echo "╚══════════════════════════════════════════════════════╝"
echo -e "${RESET}"
log_info "检测模式: ${MODE}"
log_info "操作系统: $(uname -srm)"
log_info "当前用户: $(id -un)"
log_info "工作目录: $(pwd)"

# =============================================================================
# 通用检查
# =============================================================================
section "基础环境"

# Bash 版本
bash_ver="${BASH_VERSION%%.*}"
if [[ $bash_ver -ge 4 ]]; then
  log_pass "Bash 版本 $BASH_VERSION"
else
  log_warn "Bash 版本过低 ($BASH_VERSION)，建议 ≥ 4.0"
fi

# curl / wget
if command -v curl &>/dev/null; then
  log_pass "curl $(curl --version | head -1 | awk '{print $2}')"
else
  log_warn "curl 未安装（下载脚本需要）"
fi

# 磁盘空间（要求 /var/lib 至少 1GB）
avail_kb=$(df /var/lib 2>/dev/null | tail -1 | awk '{print $4}' || echo 0)
avail_gb=$(( ${avail_kb:-0} / 1024 / 1024 ))
if [[ $avail_gb -ge 1 ]]; then
  log_pass "磁盘可用空间: ${avail_gb}GB（/var/lib）"
else
  log_warn "磁盘可用空间不足: ${avail_gb}GB，建议 ≥ 1GB"
fi

# 内存
mem_kb=$(grep MemAvailable /proc/meminfo 2>/dev/null | awk '{print $2}')
mem_mb=$(( ${mem_kb:-0} / 1024 ))
if [[ $mem_mb -ge 256 ]]; then
  log_pass "可用内存: ${mem_mb}MB"
else
  log_warn "可用内存不足: ${mem_mb}MB，建议 ≥ 256MB"
fi

# 端口 8080 是否被占用
if (ss -tlnp 2>/dev/null || netstat -tlnp 2>/dev/null || true) | grep -q ':8080 '; then
  log_warn "端口 8080 已被占用（请确认是否为 conMon 实例）"
else
  log_pass "端口 8080 可用"
fi
if (ss -tlnp 2>/dev/null || netstat -tlnp 2>/dev/null || true) | grep -q ':9090 '; then
  log_warn "端口 9090 已被占用（gRPC 探针端口）"
else
  log_pass "端口 9090 可用"
fi

# =============================================================================
# 按部署模式检查
# =============================================================================

if [[ $MODE == "binary" || $MODE == "all" ]]; then
  section "二进制部署环境"

  # systemd
  if command -v systemctl &>/dev/null; then
    log_pass "systemd 可用（$(systemctl --version | head -1)）"
  else
    log_warn "systemd 未找到，服务管理需手动处理"
  fi

  # setcap（ICMP 权限）
  if command -v setcap &>/dev/null; then
    log_pass "setcap 可用（ICMP 探测权限设置）"
  else
    log_warn "setcap 未安装，ICMP 探测需要 root 运行"
  fi

  # 检查 /etc/conmon 是否存在
  if [[ -d /etc/conmon ]]; then
    log_pass "/etc/conmon 目录已存在"
  else
    log_info "/etc/conmon 不存在，安装时将自动创建"
  fi

  # 检查 conmon 用户
  if id conmon &>/dev/null; then
    log_pass "conmon 系统用户已存在"
  else
    log_info "conmon 用户不存在，安装时将自动创建"
  fi

  # Go 环境（从源码构建时需要）
  if command -v go &>/dev/null; then
    go_ver=$(go version | awk '{print $3}')
    log_pass "Go 已安装: $go_ver"
  else
    log_info "Go 未安装（仅源码构建需要，预编译二进制不需要）"
  fi
fi

if [[ $MODE == "docker" || $MODE == "compose" || $MODE == "all" ]]; then
  section "Docker 环境"

  if command -v docker &>/dev/null; then
    docker_ver=$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo "unknown")
    log_pass "Docker 已安装: $docker_ver"

    # Docker daemon 运行中？
    if docker info &>/dev/null; then
      log_pass "Docker daemon 运行正常"
    else
      log_fail "Docker daemon 未运行，请执行: sudo systemctl start docker"
    fi

    # 当前用户是否在 docker 组
    if groups | grep -qw docker; then
      log_pass "当前用户在 docker 组（无需 sudo）"
    else
      log_warn "当前用户不在 docker 组，运行 docker 命令需要 sudo"
    fi
  else
    log_fail "Docker 未安装（https://docs.docker.com/get-docker/）"
  fi
fi

if [[ $MODE == "compose" || $MODE == "all" ]]; then
  section "Docker Compose 环境"

  if docker compose version &>/dev/null 2>&1; then
    log_pass "Docker Compose 插件: $(docker compose version --short 2>/dev/null)"
  elif command -v docker-compose &>/dev/null; then
    log_pass "docker-compose: $(docker-compose --version)"
  else
    log_fail "Docker Compose 未安装（建议使用 Docker 插件版）"
  fi

  # .env 文件
  if [[ -f deployments/compose/.env ]]; then
    log_pass ".env 文件已存在"
    # 检查关键变量
    for var in DB_PASSWORD JWT_SECRET; do
      val=$(grep "^${var}=" deployments/compose/.env 2>/dev/null | cut -d= -f2-)
      if [[ -z "$val" || "$val" == "change-me"* ]]; then
        log_warn "${var} 使用了默认值，生产环境请修改"
      else
        log_pass "${var} 已配置"
      fi
    done
  else
    log_warn ".env 文件不存在，请复制 deployments/compose/.env.example 后修改"
  fi
fi

if [[ $MODE == "k8s" || $MODE == "all" ]]; then
  section "Kubernetes 环境"

  if command -v kubectl &>/dev/null; then
    kubectl_ver=$(kubectl version --client --short 2>/dev/null || kubectl version --client -o json 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin)['clientVersion']['gitVersion'])" 2>/dev/null || echo "unknown")
    log_pass "kubectl: $kubectl_ver"

    # 集群连通性
    if kubectl cluster-info &>/dev/null 2>&1; then
      log_pass "Kubernetes 集群连接正常"
      node_count=$(kubectl get nodes --no-headers 2>/dev/null | wc -l)
      log_pass "集群节点数: $node_count"
    else
      log_warn "无法连接 Kubernetes 集群（检查 kubeconfig）"
    fi
  else
    log_fail "kubectl 未安装"
  fi

  if command -v helm &>/dev/null; then
    log_pass "Helm: $(helm version --short 2>/dev/null)"
  else
    log_warn "Helm 未安装（使用 Helm Chart 部署时需要）"
  fi
fi

# =============================================================================
# 网络连通性检查
# =============================================================================
section "网络连通性"

check_url() {
  local name=$1 url=$2
  if curl -sf --max-time 5 "$url" &>/dev/null 2>&1; then
    log_pass "$name 可达"
  else
    log_warn "$name 不可达（$url）"
  fi
}

check_url "GitHub（下载二进制）"    "https://github.com"
check_url "Docker Hub（拉取镜像）"  "https://registry-1.docker.io"
check_url "外网 DNS（8.8.8.8）"     "https://dns.google"

# =============================================================================
# 汇总报告
# =============================================================================
section "检查汇总"
echo
total=$(( PASS_COUNT + WARN_COUNT + FAIL_COUNT ))
echo -e "  总计: ${total} 项"
echo -e "  ${GREEN}通过: ${PASS_COUNT} 项${RESET}"
echo -e "  ${YELLOW}警告: ${WARN_COUNT} 项${RESET}"
echo -e "  ${RED}失败: ${FAIL_COUNT} 项${RESET}"
echo

if [[ $FAIL_COUNT -gt 0 ]]; then
  echo -e "${RED}✗ 存在 ${FAIL_COUNT} 个必须解决的问题，请先修复再部署。${RESET}"
  exit 1
elif [[ $WARN_COUNT -gt 0 ]]; then
  echo -e "${YELLOW}⚠ 存在 ${WARN_COUNT} 个警告，建议处理后再部署。${RESET}"
  exit 0
else
  echo -e "${GREEN}✓ 环境检查全部通过，可以开始部署！${RESET}"
  exit 0
fi
