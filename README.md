# PostgreSQL 数据库自动备份脚本部署指南

本文档介绍了如何部署 `pg_backup_ai_prod.sh` 脚本，实现 PostgreSQL 数据库的自动化备份，并支持上传至 AWS S3 以及本地过期文件自动清理。

## 功能特性

*   **全量备份**：使用 `pg_dump` 对目标数据库进行全量备份（自定义格式 `.dump`）。
*   **全局数据备份**：使用 `pg_dumpall` 备份全局角色和表空间信息。
*   **S3 云存储**：自动将备份文件上传至指定的 AWS S3 存储桶，支持存储类型设置（如 `STANDARD_IA`）。
*   **本地清理**：自动清理本地超过指定天数（默认 3 天）的旧备份文件，节省磁盘空间。
*   **配置分离**：使用 `.env` 文件管理敏感信息和配置参数。

## 1. 前置要求

在部署脚本之前，请确保服务器满足以下条件：

*   **操作系统**：Linux (Ubuntu/Debian/CentOS 等)
*   **PostgreSQL 客户端**：已安装 `pg_dump` 和 `pg_dumpall` 工具。
    *   Ubuntu/Debian: `apt install postgresql-client`
*   **AWS CLI**：已安装并配置好 AWS 命令行工具。
    *   安装: 参考 AWS 官方文档。
    *   配置: 运行 `aws configure` 并输入 Access Key, Secret Key, Region 等信息。
    *   权限: 确保 AWS 账号拥有 S3 的 `PutObject` 和 `ListBucket` 权限。

## 2. 部署步骤

### 2.1 获取脚本

将 `pg_backup_ai_prod.sh` 和 `.env.example` 文件上传至服务器目录，例如 `/opt/scripts/pg_backup/`。

```bash
mkdir -p /opt/scripts/pg_backup
# 上传文件到该目录...
cd /opt/scripts/pg_backup
chmod +x pg_backup_ai_prod.sh
```

### 2.2 配置环境变量

复制示例配置文件并修改：

```bash
cp .env.example .env
vim .env
```

在 `.env` 文件中填入实际的数据库连接信息和 S3 配置：

```ini
# === 数据库连接信息 ===
DB_HOST="127.0.0.1"
DB_PORT="5432"
DB_NAME="ai_prod"       # 你的数据库名
DB_USER="postgres"      # 数据库用户名
DB_PASS="你的数据库密码" # 务必填写正确

# === 备份参数 ===
BACKUP_DIR="/opt/pg_backup/ai_prod" # 备份文件本地存放路径
RETENTION_DAYS=3                    # 本地保留最近 3 天的备份

# === S3 上传配置 ===
S3_BUCKET="prod-pgsql-backup"       # 你的 S3 Bucket 名称
S3_PREFIX="ai-prod"                 # S3 里的路径前缀
S3_STORAGE_CLASS="STANDARD_IA"      # 存储类型：STANDARD 或 STANDARD_IA (低频访问，更省钱)
```

### 2.3 手动测试

配置完成后，先手动运行一次脚本以确保一切正常：

```bash
./pg_backup_ai_prod.sh
```

**预期输出：**
1.  显示 `Backup start`
2.  生成 `.dump` 和 `.sql` 文件
3.  显示 `上传到 S3 -> s3://...`
4.  最后显示 `Backup done`

如果报错，请检查 `.env` 配置、AWS 权限或磁盘空间。

## 3. 设置定时任务 (Crontab)

为了实现自动备份，需要将其添加到 `crontab`。

1.  编辑 crontab：

```bash
crontab -e
```

2.  添加定时任务（例如：每天凌晨 2:00 执行）：

```cron
# 每天凌晨 2:00 备份数据库，并将日志输出到 syslog 或文件
0 2 * * * /opt/scripts/pg_backup/pg_backup_ai_prod.sh >> /var/log/pg_backup.log 2>&1
```

3.  保存并退出。

## 4. 数据恢复指南

### 4.1 从本地文件恢复

如果本地还有备份文件：

```bash
# 恢复主数据库
pg_restore -h 127.0.0.1 -U postgres -d ai_prod -v "/opt/pg_backup/ai_prod/ai_prod_2023xxxx.dump"

# 恢复全局角色（如有需要）
psql -h 127.0.0.1 -U postgres -f "/opt/pg_backup/ai_prod/global_roles_2023xxxx.sql"
```

### 4.2 从 S3 下载并恢复

如果本地文件已清理，需先从 S3 下载：

```bash
# 列出 S3 上的备份
aws s3 ls s3://prod-pgsql-backup/ai-prod/

# 下载指定日期的备份
aws s3 cp s3://prod-pgsql-backup/ai-prod/ai_prod_2023xxxx.dump .

# 执行恢复
pg_restore -h 127.0.0.1 -U postgres -d ai_prod -v ai_prod_2023xxxx.dump
```

## 5. 常见问题 (FAQ)

*   **Q: 脚本提示 `command not found: aws`？**
    *   A: 确保 `aws` cli 已安装并在系统 PATH 中。如果在 crontab 中运行失败，尝试在脚本开头显式添加 PATH，例如 `export PATH=$PATH:/usr/local/bin`。
*   **Q: S3 上传慢或失败？**
    *   A: 检查服务器网络状况，或在 AWS CLI 配置中启用并发上传。如果是跨国传输，考虑开启 S3 Transfer Acceleration。
*   **Q: 如何修改 S3 上的过期策略？**
    *   A: 脚本只负责清理**本地**旧文件。S3 上的文件生命周期请登录 AWS Console，在 S3 Bucket 的 "Management" -> "Lifecycle rules" 中设置（例如：30 天后转入 Glacier，或者 365 天后删除）。
