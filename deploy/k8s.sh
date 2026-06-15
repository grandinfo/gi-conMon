#!/usr/bin/env bash
# =============================================================================
# deploy/k8s.sh — conMon Kubernetes 部署助手
#
# 用法：
#   bash deploy/k8s.sh install   [--namespace NS] [--version V]
#   bash deploy/k8s.sh upgrade   [--version V]
#   bash deploy/k8s.sh status
#   bash deploy/k8s.sh uninstall [--namespace NS]
#   bash deploy/k8s.sh port-forward
#   bash deploy/k8s.sh apply     # 应用 YAML 清单（不使用 Helm）
# =============================================================================
set -euo pipefail

# ---- 默认配置 ---------------------------------------------------------------
NAMESPACE="conmon-system"
RELEASE="conmon"
VERSION="v2.0.0"
HELM_REPO="https://grandinfo.github.io/gi-conMon/charts"
CHART="conmon/conmon"
LOCAL_PORT="11080"
MANIFESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../deployments/kubernetes"

# ---- 颜色 -------------------------------------------------------------------
GREEN='\033[0;32m'; CYAN='\033[0;36m'; YELLOW='\033[1;33m'
RED='\033[0;31m'; BOLD='\033[1m'; RESET='\033[0m'
info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; exit 1; }
section() { echo -e "\n${BOLD}>>> $*${RESET}"; }

# ---- 解析全局参数 -----------------------------------------------------------
while [[ $# -gt 0 && $1 == --* ]]; do
  case $1 in
    --namespace=*) NAMESPACE="${1#--namespace=}" ;;
    --namespace)   shift; NAMESPACE="$1" ;;
    --version=*)   VERSION="${1#--version=}" ;;
    --version)     shift; VERSION="$1" ;;
    --release=*)   RELEASE="${1#--release=}" ;;
    --release)     shift; RELEASE="$1" ;;
  esac
  shift
done

SUBCOMMAND="${1:-help}"
[[ $# -gt 0 ]] && shift

# ---- 检查工具 ---------------------------------------------------------------
check_kubectl() {
  command -v kubectl &>/dev/null || error "kubectl 未安装"
  kubectl cluster-info &>/dev/null 2>&1 || error "无法连接 Kubernetes 集群，请检查 kubeconfig"
}

check_helm() {
  command -v helm &>/dev/null || error "Helm 未安装（https://helm.sh/docs/intro/install/）"
}

# ---- install ----------------------------------------------------------------
cmd_install() {
  section "Helm 安装 conMon"
  check_kubectl; check_helm

  # 创建命名空间
  if ! kubectl get namespace "$NAMESPACE" &>/dev/null; then
    kubectl create namespace "$NAMESPACE"
    success "创建命名空间: $NAMESPACE"
  fi

  # 添加 Helm 仓库
  info "添加 Helm 仓库..."
  helm repo add conmon "$HELM_REPO" 2>/dev/null || true
  helm repo update

  # 生成 values 文件（如不存在）
  VALUES_FILE="$(mktemp /tmp/conmon-values-XXXXXX.yaml)"
  trap "rm -f $VALUES_FILE" EXIT

  cat > "$VALUES_FILE" << YAML
replicaCount: 2

image:
  tag: "${VERSION}"

server:
  externalUrl: "http://conmon.example.com"

ingress:
  enabled: false

postgresql:
  enabled: true
  auth:
    password: "$(openssl rand -hex 16 2>/dev/null || echo 'change-me')"

resources:
  requests:
    cpu: "200m"
    memory: "128Mi"
  limits:
    cpu: "1000m"
    memory: "512Mi"

probe:
  enabled: true
  daemonset: false
YAML

  info "安装 Helm Chart（版本 ${VERSION}）..."
  helm upgrade --install "$RELEASE" "$CHART" \
    --namespace "$NAMESPACE" \
    --version "${VERSION#v}" \
    --values "$VALUES_FILE" \
    --wait --timeout 5m

  success "Helm 安装完成！"
  cmd_status
}

# ---- apply（不使用 Helm，直接 kubectl apply）--------------------------------
cmd_apply() {
  section "kubectl apply 部署 conMon"
  check_kubectl

  [[ -d $MANIFESTS_DIR ]] || error "K8s 清单目录不存在: $MANIFESTS_DIR"

  # 创建命名空间
  kubectl apply -f - <<YAML
apiVersion: v1
kind: Namespace
metadata:
  name: ${NAMESPACE}
  labels:
    app.kubernetes.io/name: conmon
YAML

  # 生成 ConfigMap
  kubectl create configmap conmon-config \
    --from-file=conmon.yaml="$(dirname "$MANIFESTS_DIR")/../configs/conmon.yaml" \
    --namespace "$NAMESPACE" \
    --dry-run=client -o yaml | kubectl apply -f -
  success "ConfigMap 已创建"

  # 生成 Secret（如不存在）
  if ! kubectl get secret conmon-secret -n "$NAMESPACE" &>/dev/null; then
    JWT_SECRET=$(openssl rand -hex 32 2>/dev/null || echo "change-me-jwt-secret")
    kubectl create secret generic conmon-secret \
      --from-literal=jwt-secret="$JWT_SECRET" \
      --namespace "$NAMESPACE"
    success "Secret 已创建（JWT_SECRET 已随机生成）"
  else
    info "Secret 已存在，跳过"
  fi

  # 应用所有 YAML 清单
  if ls "$MANIFESTS_DIR"/*.yaml &>/dev/null 2>&1; then
    kubectl apply -f "$MANIFESTS_DIR/" --namespace "$NAMESPACE"
    success "所有清单已应用"
  else
    # 内联生成最小部署清单
    info "使用内联最小清单..."
    kubectl apply -f - << YAML
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: conmon-server
  namespace: ${NAMESPACE}
  labels:
    app: conmon-server
spec:
  replicas: 2
  selector:
    matchLabels:
      app: conmon-server
  template:
    metadata:
      labels:
        app: conmon-server
    spec:
      containers:
        - name: conmon
          image: conmon/conmon:${VERSION}
          ports:
            - containerPort: 11080
              name: http
            - containerPort: 11090
              name: grpc
          env:
            - name: JWT_SECRET
              valueFrom:
                secretKeyRef:
                  name: conmon-secret
                  key: jwt-secret
          volumeMounts:
            - name: config
              mountPath: /etc/conmon
          readinessProbe:
            httpGet:
              path: /ready
              port: 11080
            initialDelaySeconds: 5
            periodSeconds: 10
          livenessProbe:
            httpGet:
              path: /health
              port: 11080
            initialDelaySeconds: 10
            periodSeconds: 30
          resources:
            requests:
              cpu: "200m"
              memory: "128Mi"
            limits:
              cpu: "1000m"
              memory: "512Mi"
      volumes:
        - name: config
          configMap:
            name: conmon-config
---
apiVersion: v1
kind: Service
metadata:
  name: conmon-server
  namespace: ${NAMESPACE}
spec:
  selector:
    app: conmon-server
  ports:
    - name: http
      port: 11080
      targetPort: 11080
    - name: grpc
      port: 11090
      targetPort: 11090
  type: ClusterIP
YAML
    success "内联清单已应用"
  fi

  info "等待 Deployment 就绪..."
  kubectl rollout status deployment/conmon-server -n "$NAMESPACE" --timeout=120s
  success "部署完成！"
}

# ---- upgrade ----------------------------------------------------------------
cmd_upgrade() {
  section "升级 conMon"
  check_kubectl

  if command -v helm &>/dev/null && helm status "$RELEASE" -n "$NAMESPACE" &>/dev/null 2>&1; then
    info "使用 Helm 升级..."
    helm upgrade "$RELEASE" "$CHART" \
      --namespace "$NAMESPACE" \
      --set "image.tag=${VERSION}" \
      --reuse-values \
      --wait --timeout 5m
  else
    info "使用 kubectl 滚动更新..."
    kubectl set image deployment/conmon-server \
      conmon="conmon/conmon:${VERSION}" \
      -n "$NAMESPACE"
    kubectl rollout status deployment/conmon-server -n "$NAMESPACE" --timeout=120s
  fi

  success "升级完成: ${VERSION}"
  cmd_status
}

# ---- status -----------------------------------------------------------------
cmd_status() {
  section "conMon 集群状态"
  check_kubectl

  echo -e "${BOLD}Pods:${RESET}"
  kubectl get pods -n "$NAMESPACE" -l app=conmon-server \
    -o wide 2>/dev/null || kubectl get pods -n "$NAMESPACE" 2>/dev/null

  echo ""
  echo -e "${BOLD}Services:${RESET}"
  kubectl get svc -n "$NAMESPACE" 2>/dev/null

  echo ""
  echo -e "${BOLD}Deployment:${RESET}"
  kubectl get deployment -n "$NAMESPACE" 2>/dev/null

  # 显示 Ingress（如果有）
  local ing
  ing=$(kubectl get ingress -n "$NAMESPACE" 2>/dev/null | grep -v "^NAME" | head -5)
  if [[ -n $ing ]]; then
    echo ""
    echo -e "${BOLD}Ingress:${RESET}"
    kubectl get ingress -n "$NAMESPACE"
  fi
}

# ---- port-forward -----------------------------------------------------------
cmd_port_forward() {
  check_kubectl
  info "端口转发: localhost:${LOCAL_PORT} → conmon-server:11080"
  info "按 Ctrl+C 停止"
  echo ""
  kubectl port-forward -n "$NAMESPACE" \
    svc/conmon-server "${LOCAL_PORT}:11080"
}

# ---- logs -------------------------------------------------------------------
cmd_logs() {
  check_kubectl
  local follow="${1:-}"
  local pod
  pod=$(kubectl get pods -n "$NAMESPACE" -l app=conmon-server \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  [[ -n $pod ]] || error "未找到 conmon-server Pod"

  if [[ $follow == "-f" ]]; then
    kubectl logs -f "$pod" -n "$NAMESPACE" -c conmon
  else
    kubectl logs "$pod" -n "$NAMESPACE" -c conmon --tail=100
  fi
}

# ---- uninstall --------------------------------------------------------------
cmd_uninstall() {
  section "卸载 conMon"
  check_kubectl

  warn "这将删除 conMon 的所有 Kubernetes 资源！"
  read -r -p "确认卸载? [y/N] " confirm
  [[ $confirm =~ ^[Yy]$ ]] || { info "取消"; exit 0; }

  if command -v helm &>/dev/null && helm status "$RELEASE" -n "$NAMESPACE" &>/dev/null 2>&1; then
    helm uninstall "$RELEASE" -n "$NAMESPACE"
    success "Helm 卸载完成"
  else
    kubectl delete deployment conmon-server -n "$NAMESPACE" 2>/dev/null || true
    kubectl delete svc conmon-server -n "$NAMESPACE" 2>/dev/null || true
    kubectl delete configmap conmon-config -n "$NAMESPACE" 2>/dev/null || true
    success "资源已删除"
  fi

  read -r -p "是否同时删除命名空间 ${NAMESPACE}? [y/N] " confirm2
  if [[ $confirm2 =~ ^[Yy]$ ]]; then
    kubectl delete namespace "$NAMESPACE"
    success "命名空间已删除"
  fi
}

# ---- 帮助 -------------------------------------------------------------------
usage() {
  echo "用法: bash deploy/k8s.sh [全局选项] <命令>"
  echo ""
  echo "全局选项:"
  echo "  --namespace NS   K8s 命名空间（默认: conmon-system）"
  echo "  --version  V     镜像版本（默认: v2.0.0）"
  echo "  --release  NAME  Helm Release 名称（默认: conmon）"
  echo ""
  echo "命令:"
  echo "  install          使用 Helm 安装（需要 Helm）"
  echo "  apply            使用 kubectl apply 安装（不需要 Helm）"
  echo "  upgrade          升级到新版本"
  echo "  status           查看集群状态"
  echo "  logs [-f]        查看 Pod 日志"
  echo "  port-forward     本地端口转发（调试用）"
  echo "  uninstall        卸载 conMon"
  echo ""
  echo "示例:"
  echo "  bash deploy/k8s.sh --version v2.0.0 install"
  echo "  bash deploy/k8s.sh --namespace monitoring apply"
  echo "  bash deploy/k8s.sh status"
  echo "  bash deploy/k8s.sh port-forward"
  echo "  bash deploy/k8s.sh logs -f"
}

# ---- 主入口 -----------------------------------------------------------------
case "$SUBCOMMAND" in
  install)      cmd_install ;;
  apply)        cmd_apply ;;
  upgrade)      cmd_upgrade ;;
  status)       cmd_status ;;
  logs)         cmd_logs "${1:-}" ;;
  port-forward) cmd_port_forward ;;
  uninstall)    cmd_uninstall ;;
  help|-h|--help) usage ;;
  *) error "未知命令: $SUBCOMMAND，使用 help 查看帮助" ;;
esac
