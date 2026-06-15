#!/usr/bin/env bash
# =============================================================================
# deploy/backup.sh — conMon 数据备份脚本
#
# 用法：
#   bash deploy/backup.sh                          # 执行全量备份
#   bash deploy/backup.sh --dest /backup/path      # 指定备份目录
#   bash deploy/backup.sh --keep 30                # 保留最近 N 天备份
#   bash deploy/backup.sh --restore 20260615_030000 # 从指定备份恢复
#   bash deploy/backup.sh --list                   # 列出所有备份
#
# 建议通过 cron 定期执行：
#   0 3 * * * /bin/bash /opt/conmon/deploy/backup.sh --dest /backup/conmon >> /var/log/conmon-backup.log 2>&1
# =============================================================================
set -euo pipefail

# ---- 默认配置 ---------------------------------------------------------------
BACKUP_DEST="${BACKUP_DEST:-/var/backups/conmon}"
DATA_DIR="${CONMON_DATA_DIR:-/var/lib/conmon}"
CONFIG_DIR="${CONMON_CONFIG_DIR:-/etc/conmon}"
LOG_DIR="${CONMON_LOG_DIR:-/var/log/conmon}"
KEEP_DAYS="${BACKUP_KEEP_DAYS:-30}"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_NAME="conmon_backup_${TIMESTAMP}"
RESTORE_TS=""
LIST_ONLY=false

# ---- 颜色 -------------------------------------------------------------------
GREEN='\033[0;32m'; CYAN='\033[0;36m'; YELLOW='\033[1;33m'
RED='\033[0;31m'; BOLD='\033[1m'; RESET='\033[0m'
info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; exit 1; }
section() { echo -e "\n${BOLD}>>> $*${RESET}"; }

# ---- 解析参数 ---------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case $1 in
    --dest=*)    BACKUP_DEST="${1#--dest=}" ;;
    --dest)      shift; BACKUP_DEST="$1" ;;
    --keep=*)    KEEP_DAYS="${1#--keep=}" ;;
    --keep)      shift; KEEP_DAYS="$1" ;;
    --restore=*) RESTORE_TS="${1#--restore=}" ;;
    --restore)   shift; RESTORE_TS="$1" ;;
    --list)      LIST_ONLY=true ;;
    -h|--help)
      echo "用法: bash backup.sh [选项]"
      echo ""
      echo "选项:"
      echo "  --dest DIR        备份目录（默认: /var/backups/conmon）"
      echo "  --keep N          保留最近 N 天的备份（默认: 30）"
      echo "  --restore TS      从指定时间戳备份恢复（格式: 20260615_030000）"
      echo "  --list            列出所有可用备份"
      exit 0 ;;
    *) warn "未知参数: $1" ;;
  esac
  shift
done

# ---- 列出备份 ---------------------------------------------------------------
if $LIST_ONLY; then
  echo -e "${BOLD}=== 可用备份列表 ===${RESET}"
  if [[ ! -d $BACKUP_DEST ]]; then
    info "备份目录不存在: $BACKUP_DEST"
    exit 0
  fi
  find "$BACKUP_DEST" -maxdepth 1 -name "conmon_backup_*" -type d \
    | sort -r \
    | while read -r dir; do
        size=$(du -sh "$dir" 2>/dev/null | cut -f1)
        ts=$(basename "$dir" | sed 's/conmon_backup_//')
        echo "  $ts  ($size)  →  $dir"
      done
  exit 0
fi

# ---- 恢复备份 ---------------------------------------------------------------
if [[ -n $RESTORE_TS ]]; then
  section "从备份恢复: $RESTORE_TS"

  RESTORE_DIR="${BACKUP_DEST}/conmon_backup_${RESTORE_TS}"
  [[ -d $RESTORE_DIR ]] || error "备份不存在: $RESTORE_DIR"

  warn "这将覆盖当前的配置和数据！"
  read -r -p "确认恢复? [y/N] " confirm
  [[ $confirm =~ ^[Yy]$ ]] || { info "取消"; exit 0; }

  # 停止服务
  if systemctl is-active conmon &>/dev/null 2>&1; then
    info "停止 conmon 服务..."
    sudo systemctl stop conmon
    RESTART_SERVICE=true
  else
    RESTART_SERVICE=false
  fi

  # 恢复配置
  if [[ -d "${RESTORE_DIR}/config" ]]; then
    sudo cp -r "${RESTORE_DIR}/config/." "$CONFIG_DIR/"
    success "配置已恢复"
  fi

  # 恢复数据库
  if [[ -f "${RESTORE_DIR}/conmon.db" ]]; then
    sudo cp "${RESTORE_DIR}/conmon.db" "${DATA_DIR}/conmon.db"
    success "SQLite 数据库已恢复"
  fi

  # 重启服务
  if $RESTART_SERVICE; then
    sudo systemctl start conmon
    sleep 2
    systemctl is-active conmon &>/dev/null && success "服务已重启" || warn "服务重启失败"
  fi

  success "恢复完成: $RESTORE_TS"
  exit 0
fi

# =============================================================================
# 全量备份
# =============================================================================
section "开始备份: $BACKUP_NAME"

mkdir -p "${BACKUP_DEST}/${BACKUP_NAME}"
DEST="${BACKUP_DEST}/${BACKUP_NAME}"

ERRORS=0

# ---- 备份配置文件 -----------------------------------------------------------
info "备份配置文件..."
if [[ -d $CONFIG_DIR ]]; then
  cp -r "$CONFIG_DIR" "${DEST}/config"
  # 脱敏处理（替换密码字段为 ***）
  if [[ -f "${DEST}/config/conmon.yaml" ]]; then
    sed -i 's/\(password\|secret\|token\|key\):\s*.*/\1: "***REDACTED***"/gI' \
      "${DEST}/config/conmon.yaml" 2>/dev/null || true
  fi
  success "配置文件已备份（已脱敏）"
else
  warn "配置目录不存在: $CONFIG_DIR"
fi

# ---- 备份 SQLite 数据库 -----------------------------------------------------
info "备份 SQLite 数据库..."
DB_PATH="${DATA_DIR}/conmon.db"
if [[ -f $DB_PATH ]]; then
  # 使用 SQLite 的备份命令确保一致性（即使数据库正在使用）
  if command -v sqlite3 &>/dev/null; then
    sqlite3 "$DB_PATH" ".backup '${DEST}/conmon.db'"
    success "SQLite 数据库已备份（在线一致性备份）"
  else
    cp "$DB_PATH" "${DEST}/conmon.db"
    success "SQLite 数据库已备份（文件复制）"
  fi
else
  info "SQLite 数据库不存在: $DB_PATH（可能使用 PostgreSQL）"
fi

# ---- 备份 PostgreSQL（如果已配置）------------------------------------------
PG_DSN="${DB_DSN:-}"
if [[ -z $PG_DSN && -f "${CONFIG_DIR}/conmon.env" ]]; then
  PG_DSN=$(grep "^DB_PASSWORD=" "${CONFIG_DIR}/conmon.env" 2>/dev/null | cut -d= -f2-)
fi

if command -v pg_dump &>/dev/null; then
  # 尝试从配置读取 PostgreSQL 连接信息
  if [[ -f "${CONFIG_DIR}/conmon.yaml" ]]; then
    PG_DSN_FROM_CONF=$(grep "dsn:" "${CONFIG_DIR}/conmon.yaml" 2>/dev/null | head -1 | awk '{print $2}' | tr -d '"')
  fi

  if [[ -n "${PG_DSN_FROM_CONF:-}" && "$PG_DSN_FROM_CONF" == postgres://* ]]; then
    info "备份 PostgreSQL 数据库..."
    pg_dump "${PG_DSN_FROM_CONF}" -Fc -f "${DEST}/conmon_pg.dump" 2>/dev/null \
      && success "PostgreSQL 已备份: conmon_pg.dump" \
      || { warn "PostgreSQL 备份失败（可能权限不足）"; ((ERRORS++)); }
  fi
fi

# ---- 备份最近日志 -----------------------------------------------------------
info "备份最近日志..."
if [[ -d $LOG_DIR ]]; then
  find "$LOG_DIR" -name "*.log" -mtime -7 -exec cp {} "${DEST}/" \; 2>/dev/null
  success "最近 7 天日志已备份"
elif command -v journalctl &>/dev/null; then
  journalctl -u conmon --since "7 days ago" --no-pager -o json-pretty \
    > "${DEST}/conmon-journal.json" 2>/dev/null \
    && success "systemd journal 日志已备份" || true
fi

# ---- 记录备份元信息 ---------------------------------------------------------
cat > "${DEST}/backup-info.json" << JSON
{
  "backup_name": "${BACKUP_NAME}",
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "hostname": "$(hostname -f 2>/dev/null || hostname)",
  "conmon_version": "$(conmon version 2>/dev/null | grep -oP 'v[\d.]+' | head -1 || echo 'unknown')",
  "os": "$(uname -srm)",
  "backup_size": "$(du -sh ${DEST} 2>/dev/null | cut -f1)"
}
JSON

# ---- 压缩备份 ---------------------------------------------------------------
info "压缩备份..."
tar -czf "${BACKUP_DEST}/${BACKUP_NAME}.tar.gz" -C "$BACKUP_DEST" "$BACKUP_NAME"
rm -rf "${DEST}"
ARCHIVE="${BACKUP_DEST}/${BACKUP_NAME}.tar.gz"
ARCHIVE_SIZE=$(du -sh "$ARCHIVE" | cut -f1)
success "备份已压缩: $ARCHIVE ($ARCHIVE_SIZE)"

# ---- 清理过期备份 -----------------------------------------------------------
section "清理过期备份（保留最近 ${KEEP_DAYS} 天）"
DELETED=0
while IFS= read -r old_file; do
  rm -f "$old_file"
  info "删除: $(basename "$old_file")"
  ((DELETED++))
done < <(find "$BACKUP_DEST" -maxdepth 1 -name "conmon_backup_*.tar.gz" -mtime "+${KEEP_DAYS}" 2>/dev/null)

[[ $DELETED -eq 0 ]] && info "无过期备份需要清理" || success "清理了 $DELETED 个过期备份"

# ---- 汇总 -------------------------------------------------------------------
section "备份完成"
echo ""
echo -e "  备份文件: ${BOLD}${ARCHIVE}${RESET}"
echo -e "  备份大小: ${ARCHIVE_SIZE}"
echo -e "  保留策略: 最近 ${KEEP_DAYS} 天"
echo ""

# 列出所有备份
echo -e "${BOLD}当前备份列表:${RESET}"
find "$BACKUP_DEST" -maxdepth 1 -name "conmon_backup_*.tar.gz" -printf "%T@ %p\n" 2>/dev/null \
  | sort -rn | head -10 \
  | while read -r mtime file; do
      size=$(du -sh "$file" | cut -f1)
      echo "  $(basename "$file")  ($size)"
    done

echo ""
[[ $ERRORS -gt 0 ]] && warn "备份完成（${ERRORS} 个警告）" || success "备份全部成功！"

# ---- 恢复提示 ---------------------------------------------------------------
echo ""
echo -e "  ${BOLD}恢复命令:${RESET}"
echo "    bash deploy/backup.sh --restore ${TIMESTAMP}"
echo ""
echo -e "  ${BOLD}查看备份列表:${RESET}"
echo "    bash deploy/backup.sh --list"
