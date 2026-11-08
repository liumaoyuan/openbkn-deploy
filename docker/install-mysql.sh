#!/usr/bin/env bash
# 在内网 Linux（麒麟 V10 / 其他 glibc 发行版）上离线安装 MySQL 8。
#
# 安装包默认从 app/<架构>/ 下读取：
#   app/amd64/mysql-8.0.45-linux-glibc2.28-x86_64.tar.xz
#   app/arm64/mysql-8.0.45-linux-glibc2.28-aarch64.tar.xz
#
# 用法：
#   sudo bash install-mysql.sh                    # 自动按 CPU 架构选择安装包
#   bash install-mysql.sh --check                 # 只打印识别结果，不安装
#   sudo bash install-mysql.sh <tar.xz 路径>      # 手动指定
#
# 可选环境变量：
#   MYSQL_PORT            端口，默认 3306
#   OPENBKN_DB_NAME       数据库名，默认 openbkn
#   OPENBKN_DB_USER       业务账号，默认 openbkn
#   MYSQL_ROOT_PASSWORD   root 密码；不提供则随机生成
#   MYSQL_PASSWORD        业务账号密码；不提供则随机生成
#
# 密码和连接信息会写到 /root/openbkn-mysql-credentials.txt（权限 0600）。
#
# 注意：本脚本安装的是**宿主机上的 MySQL**，与 docker compose 栈自带的
# mariadb 容器互相独立。只有需要外部数据库时才会用到它。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

MYSQL_VERSION="8.0.45"
BASE_DIR="/opt/mysql-${MYSQL_VERSION}"
DATA_DIR="/var/lib/mysql"
CONFIG_FILE="/etc/openbkn-mysql.cnf"
SERVICE_FILE="/etc/systemd/system/openbkn-mysql.service"
ERROR_LOG="/var/log/mysql/error.log"
SOCKET_PATH="/run/mysqld/mysqld.sock"
CREDENTIALS_FILE="/root/openbkn-mysql-credentials.txt"

PORT="${MYSQL_PORT:-3306}"
DB_NAME="${OPENBKN_DB_NAME:-openbkn}"
DB_USER="${OPENBKN_DB_USER:-openbkn}"

usage() {
  sed -n '2,27p' "$0"
  exit 2
}

CHECK_ONLY=0
ARGS=()
for arg in "$@"; do
  case "$arg" in
    -h | --help) usage ;;
    --check) CHECK_ONLY=1 ;;
    *) ARGS+=("$arg") ;;
  esac
done
if [[ ${#ARGS[@]} -gt 1 ]]; then
  usage
fi

case "$(uname -m)" in
  x86_64)
    APP_DIR="amd64"
    MYSQL_ARCH="x86_64"
    ;;
  aarch64 | arm64)
    APP_DIR="arm64"
    MYSQL_ARCH="aarch64"
    ;;
  *)
    echo "不支持的 CPU 架构: $(uname -m)" >&2
    exit 1
    ;;
esac

ARCHIVE="${ARGS[0]:-${SCRIPT_DIR}/app/${APP_DIR}/mysql-${MYSQL_VERSION}-linux-glibc2.28-${MYSQL_ARCH}.tar.xz}"
MYSQLD="${BASE_DIR}/bin/mysqld"
MYSQL="${BASE_DIR}/bin/mysql"
MYSQL_TZINFO="${BASE_DIR}/bin/mysql_tzinfo_to_sql"

if [[ "$CHECK_ONLY" == "1" ]]; then
  echo "架构        : $(uname -m) (app/${APP_DIR}, ${MYSQL_ARCH})"
  echo "MySQL 安装包: $ARCHIVE"
  [[ -f "$ARCHIVE" ]] && echo "状态        : 文件存在" || echo "状态        : 文件不存在"
  exit 0
fi

if [[ "$(id -u)" -ne 0 ]]; then
  echo "请用 root 运行: sudo bash $0" >&2
  exit 1
fi

if [[ ! -f "$ARCHIVE" ]]; then
  echo "找不到 MySQL 安装包: $ARCHIVE" >&2
  exit 1
fi

for command in tar xz systemctl openssl awk seq; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "缺少命令: $command" >&2
    exit 1
  fi
done

if [[ -e "$SERVICE_FILE" || -f "$CONFIG_FILE" ]]; then
  echo "检测到已存在的 openbkn-mysql 配置，拒绝覆盖。" >&2
  exit 1
fi

if [[ -d "$DATA_DIR" ]] && [[ -n "$(find "$DATA_DIR" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
  echo "数据目录非空（可能已有 MySQL/MariaDB 数据）: $DATA_DIR" >&2
  echo "如确认可覆盖，请先备份并清空该目录。" >&2
  exit 1
fi

if [[ -d "$BASE_DIR" ]] && [[ -n "$(find "$BASE_DIR" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
  echo "安装目录非空: $BASE_DIR" >&2
  exit 1
fi

if (exec 3<>"/dev/tcp/127.0.0.1/${PORT}") 2>/dev/null; then
  echo "端口 ${PORT} 已被占用，确认没有其他数据库在运行。" >&2
  exit 1
fi

mkdir -p "$BASE_DIR" "$DATA_DIR" /run/mysqld /var/log/mysql

echo "== 解压 ${ARCHIVE} =="
tar -xJf "$ARCHIVE" -C "$BASE_DIR" --strip-components=1

if [[ ! -x "$MYSQLD" || ! -x "$MYSQL" ]]; then
  echo "解压后未找到 MySQL 可执行文件。" >&2
  exit 1
fi

# Ubuntu 24.04+ 把 libaio 换成了 t64 ABI，MySQL 通用包仍依赖 libaio.so.1。
if ldd "$MYSQLD" 2>/dev/null | grep -q 'libaio\.so\.1.*not found'; then
  LIBAIO_T64="$(find /usr/lib /lib -type f -name 'libaio.so.1t64*' -print -quit 2>/dev/null)"
  if [[ -z "$LIBAIO_T64" ]]; then
    echo "MySQL 需要 libaio.so.1，但系统没有可用的 libaio 库。" >&2
    echo "请先安装 libaio（麒麟: yum install libaio / apt: apt install libaio1）。" >&2
    exit 1
  fi
  LIBAIO_LINK="$(dirname "$LIBAIO_T64")/libaio.so.1"
  ln -sfn "$(basename "$LIBAIO_T64")" "$LIBAIO_LINK"
  command -v ldconfig >/dev/null 2>&1 && ldconfig
fi

if ! getent group mysql >/dev/null 2>&1; then
  groupadd --system mysql
fi
if ! id mysql >/dev/null 2>&1; then
  useradd --system --gid mysql --home-dir /nonexistent --shell /usr/sbin/nologin mysql
fi

chown -R mysql:mysql "$BASE_DIR" "$DATA_DIR" /run/mysqld /var/log/mysql
chmod 0750 "$DATA_DIR" /run/mysqld /var/log/mysql

: >"$ERROR_LOG"
chown mysql:mysql "$ERROR_LOG"
chmod 0640 "$ERROR_LOG"

echo "== 写入配置 =="
cat >"$CONFIG_FILE" <<EOF
[mysqld]
basedir=${BASE_DIR}
datadir=${DATA_DIR}
socket=${SOCKET_PATH}
pid-file=/run/mysqld/mysqld.pid
port=${PORT}
bind-address=0.0.0.0
mysqlx=0
skip-name-resolve
character-set-server=utf8mb4
collation-server=utf8mb4_0900_ai_ci
lower_case_table_names=1
log-error=${ERROR_LOG}

[client]
socket=${SOCKET_PATH}
port=${PORT}
EOF
chmod 0644 "$CONFIG_FILE"

cat >"$SERVICE_FILE" <<EOF
[Unit]
Description=OpenBKN MySQL 8
After=network.target

[Service]
Type=simple
User=mysql
Group=mysql
RuntimeDirectory=mysqld
RuntimeDirectoryMode=0750
ExecStart=${MYSQLD} --defaults-file=${CONFIG_FILE}
Restart=on-failure
RestartSec=5
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

echo "== 初始化数据目录 =="
"$MYSQLD" --defaults-file="$CONFIG_FILE" --initialize --user=mysql

TEMP_ROOT_PASSWORD="$(
  sed -n 's/.*temporary password is generated for root@localhost: //p' "$ERROR_LOG" | tail -n 1
)"
if [[ -z "$TEMP_ROOT_PASSWORD" ]]; then
  echo "无法从 ${ERROR_LOG} 读取临时 root 密码。" >&2
  exit 1
fi

ROOT_PASSWORD="${MYSQL_ROOT_PASSWORD:-$(openssl rand -hex 24)}"
PROJECT_PASSWORD="${MYSQL_PASSWORD:-$(openssl rand -hex 24)}"

systemctl daemon-reload
systemctl enable --now openbkn-mysql

echo "== 等待 MySQL 就绪 =="
READY="false"
for _ in $(seq 1 60); do
  if (exec 3<>"/dev/tcp/127.0.0.1/${PORT}") 2>/dev/null; then
    READY="true"
    break
  fi
  sleep 2
done
if [[ "$READY" != "true" ]]; then
  echo "MySQL 未能在预期时间内启动，请查看 ${ERROR_LOG}" >&2
  exit 1
fi

echo "== 创建数据库与账号 =="
MYSQL_PWD="$TEMP_ROOT_PASSWORD" "$MYSQL" --defaults-file="$CONFIG_FILE" -hlocalhost \
  --connect-expired-password -uroot <<SQL
ALTER USER 'root'@'localhost'
  IDENTIFIED WITH caching_sha2_password BY '${ROOT_PASSWORD}';

CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\`
  CHARACTER SET utf8mb4
  COLLATE utf8mb4_0900_ai_ci;

CREATE USER IF NOT EXISTS '${DB_USER}'@'%'
  IDENTIFIED WITH caching_sha2_password BY '${PROJECT_PASSWORD}';

ALTER USER '${DB_USER}'@'%'
  IDENTIFIED WITH caching_sha2_password BY '${PROJECT_PASSWORD}';

GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'%';
FLUSH PRIVILEGES;
SQL

if [[ -d /usr/share/zoneinfo ]]; then
  echo "== 导入时区数据 =="
  "$MYSQL_TZINFO" /usr/share/zoneinfo 2>/dev/null |
    MYSQL_PWD="$ROOT_PASSWORD" "$MYSQL" --defaults-file="$CONFIG_FILE" -hlocalhost -uroot mysql

  TZ_CHECK="$(
    MYSQL_PWD="$ROOT_PASSWORD" "$MYSQL" --defaults-file="$CONFIG_FILE" -hlocalhost -uroot \
      --batch --skip-column-names \
      -e "SELECT CONVERT_TZ('2026-01-01 00:00:00', 'UTC', 'Asia/Shanghai');"
  )"
  if [[ "$TZ_CHECK" != "2026-01-01 08:00:00" ]]; then
    echo "时区数据校验失败（Asia/Shanghai）。" >&2
    exit 1
  fi
else
  echo "未找到 /usr/share/zoneinfo，跳过时区数据导入。" >&2
fi

ADVERTISE_HOST="$(
  hostname -I 2>/dev/null |
    tr ' ' '\n' |
    awk '/^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ {print; exit}'
)"
if [[ -z "$ADVERTISE_HOST" ]]; then
  ADVERTISE_HOST="<Linux-VM-IP>"
fi

umask 077
mkdir -p "$(dirname "$CREDENTIALS_FILE")"
cat >"$CREDENTIALS_FILE" <<EOF
MYSQL_HOST=${ADVERTISE_HOST}
MYSQL_PORT=${PORT}
MYSQL_DATABASE=${DB_NAME}
MYSQL_USER=${DB_USER}
MYSQL_PASSWORD=${PROJECT_PASSWORD}
MYSQL_ROOT_PASSWORD=${ROOT_PASSWORD}
MYSQL_USER_HOST=%
EOF
chmod 0600 "$CREDENTIALS_FILE"

echo "== 配置防火墙（如已启用） =="
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
  ufw allow "${PORT}/tcp"
elif command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
  firewall-cmd --permanent --add-port="${PORT}/tcp"
  firewall-cmd --reload
else
  echo "未检测到已启用的 ufw/firewalld，请自行确认安全组/防火墙放行 TCP ${PORT}。" >&2
fi

echo ""
echo "MySQL 安装完成。"
echo "服务名   : openbkn-mysql"
echo "安装目录 : ${BASE_DIR}"
echo "数据目录 : ${DATA_DIR}"
echo "地址     : ${ADVERTISE_HOST}:${PORT}"
echo "数据库   : ${DB_NAME}"
echo "账号     : ${DB_USER}@%"
echo "凭据文件 : ${CREDENTIALS_FILE}"
echo ""
echo "提示：本脚本安装的是宿主机 MySQL，当前 docker compose 栈默认仍使用内置的"
echo "mariadb 容器，不会自动改用它。需要外部数据库的场景（例如与 k3s 部署共用）"
echo "再使用本机地址与上面的账号密码。"
