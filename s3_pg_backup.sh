#!/usr/bin/env bash
set -Eeuo pipefail

# 获取脚本所在目录
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd -P)
ENV_FILE="${SCRIPT_DIR}/.env"

# 加载环境变量
if [ -f "$ENV_FILE" ]; then
  # shellcheck disable=SC1090
  set -a
  source "$ENV_FILE"
  set +a
else
  echo "[ERR] 找不到配置文件: $ENV_FILE"
  echo "请复制 .env.example 为 .env 并填写配置"
  exit 1
fi

# 检查必要变量是否已设置
REQUIRED_VARS=(
  "DB_HOST" "DB_PORT" "DB_NAME" "DB_USER" "DB_PASS"
  "BACKUP_DIR" "RETENTION_DAYS"
  "S3_BUCKET" "S3_PREFIX" "S3_STORAGE_CLASS"
)

for var in "${REQUIRED_VARS[@]}"; do
  if [ -z "${!var:-}" ]; then
    echo "[ERR] 环境变量 $var 未设置，请检查 .env 文件"
    exit 1
  fi
done

# === 准备 ===
mkdir -p "$BACKUP_DIR"
TS="$(date +'%Y%m%d_%H%M%S')"
DUMP_FILE="${BACKUP_DIR}/${DB_NAME}_${TS}.dump"         # 主库备份
ROLES_FILE="${BACKUP_DIR}/global_roles_${TS}.sql"       # 全局角色备份

command -v pg_dump >/dev/null || { echo "[ERR] 缺少 pg_dump"; exit 1; }
command -v pg_dumpall >/dev/null || { echo "[ERR] 缺少 pg_dumpall"; exit 1; }
command -v aws >/dev/null || { echo "[ERR] 缺少 aws CLI"; exit 1; }

IONICE=""; command -v ionice >/dev/null && IONICE="ionice -c2 -n7"

echo "[$(date -Ins)] Backup start -> $DUMP_FILE"

# === 备份数据库 ===
$IONICE env PGPASSWORD="$DB_PASS" pg_dump \
  -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" \
  -F c -f "$DUMP_FILE" -v

# === 备份全局对象 ===
$IONICE env PGPASSWORD="$DB_PASS" pg_dumpall \
  -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -g > "$ROLES_FILE"

# === 校验文件 ===
if command -v sha256sum >/dev/null; then
  sha256sum "$DUMP_FILE" "$ROLES_FILE" > "${DUMP_FILE%.dump}.sha256"
fi

# === 上传到 S3 ===
S3_BASE="s3://${S3_BUCKET%/}/${S3_PREFIX%/}"
echo "[$(date -Ins)] 上传到 S3 -> $S3_BASE"

aws s3 cp "$DUMP_FILE" "${S3_BASE}/$(basename "$DUMP_FILE")" \
  --storage-class "$S3_STORAGE_CLASS"

aws s3 cp "$ROLES_FILE" "${S3_BASE}/$(basename "$ROLES_FILE")" \
  --storage-class "$S3_STORAGE_CLASS"

SHA_FILE="${DUMP_FILE%.dump}.sha256"
if [ -f "$SHA_FILE" ]; then
  aws s3 cp "$SHA_FILE" "${S3_BASE}/$(basename "$SHA_FILE")" \
    --storage-class "$S3_STORAGE_CLASS"
fi

# === 过期清理 (本地) ===
# 清理 *.dump, *.sql, *.sha256
find "$BACKUP_DIR" -type f -mtime +"$RETENTION_DAYS" -name "${DB_NAME}_*.dump" -delete
find "$BACKUP_DIR" -type f -mtime +"$RETENTION_DAYS" -name "global_roles_*.sql" -delete
find "$BACKUP_DIR" -type f -mtime +"$RETENTION_DAYS" -name "${DB_NAME}_*.sha256" -delete

echo "[$(date -Ins)] Backup done"
