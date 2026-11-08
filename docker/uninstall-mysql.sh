#!/usr/bin/env bash
# 卸载由 install-mysql.sh 安装的宿主机 MySQL 8。
#
# 用法：
#   sudo bash uninstall-mysql.sh            # 停服务、删除程序和配置，保留数据目录
#   sudo bash uninstall-mysql.sh --purge    # 连同数据目录一起删除（不可恢复）
#   sudo bash uninstall-mysql.sh --yes      # 跳过交互确认（自动化场景）
#
# 删除内容：
#   systemd 服务 openbkn-mysql
#   /etc/openbkn-mysql.cnf
#   /opt/mysql-8.0.45
#   /root/mysql-credentials.txt（以及旧名 /root/openbkn-mysql-credentials.txt）
#
# --purge 额外删除：
#   /var/lib/mysql（MySQL 数据目录，删除后无法恢复）
#   /var/log/mysql
#
# 说明：
#   - 不删除系统用户/用户组 mysql（可能被其他程序共用）
#   - 不删除 /etc/ld.so.conf 或 libaio 软链接
set -euo pipefail

MYSQL_VERSION="8.0.45"
BASE_DIR="/opt/mysql-${MYSQL_VERSION}"
DATA_DIR="/var/lib/mysql"
LOG_DIR="/var/log/mysql"
CONFIG_FILE="/etc/openbkn-mysql.cnf"
SERVICE_FILE="/etc/systemd/system/openbkn-mysql.service"
SERVICE_NAME="openbkn-mysql"
CREDENTIALS_FILES=("/root/mysql-credentials.txt" "/root/openbkn-mysql-credentials.txt")

usage() {
  sed -n '2,22p' "$0"
  exit 2
}

PURGE=0
ASSUME_YES=0
for arg in "$@"; do
  case "$arg" in
    -h | --help) usage ;;
    --purge) PURGE=1 ;;
    --yes) ASSUME_YES=1 ;;
    *)
      echo "未知参数: $arg" >&2
      usage
      ;;
  esac
done

if [[ "$(id -u)" -ne 0 ]]; then
  echo "请用 root 运行: sudo bash $0" >&2
  exit 1
fi

found=0
[[ -f "$SERVICE_FILE" ]] && found=1
[[ -f "$CONFIG_FILE" ]] && found=1
[[ -d "$BASE_DIR" ]] && found=1

if [[ "$found" -eq 0 ]]; then
  echo "未发现 install-mysql.sh 安装的 MySQL（服务/配置/程序目录都不存在），无需卸载。"
  exit 0
fi

echo "将要删除："
echo "  服务     : ${SERVICE_NAME}"
echo "  配置文件 : ${CONFIG_FILE}"
echo "  程序目录 : ${BASE_DIR}"
for f in "${CREDENTIALS_FILES[@]}"; do
  [[ -e "$f" ]] && echo "  凭据文件 : ${f}"
done

if [[ "$PURGE" == "1" ]]; then
  echo "  数据目录 : ${DATA_DIR}  ← 删除后无法恢复"
  echo "  日志目录 : ${LOG_DIR}"
else
  echo ""
  echo "数据目录 ${DATA_DIR} 将保留；需要彻底删除请加 --purge。"
fi

if [[ "$ASSUME_YES" != "1" ]]; then
  if [[ "$PURGE" == "1" ]]; then
    printf '这会删除全部 MySQL 数据且不可恢复。输入 DELETE 继续: '
    read -r answer
    if [[ "$answer" != "DELETE" ]]; then
      echo "已取消。"
      exit 1
    fi
  else
    printf '确认卸载（保留数据）？[y/N] '
    read -r answer
    case "$answer" in
      y | Y | yes | YES) ;;
      *) echo "已取消。"; exit 1 ;;
    esac
  fi
fi

echo "== 停止并禁用服务 =="
if systemctl list-unit-files 2>/dev/null | grep -q "^${SERVICE_NAME}.service"; then
  systemctl stop "${SERVICE_NAME}" 2>/dev/null || true
  systemctl disable "${SERVICE_NAME}" 2>/dev/null || true
else
  echo "  未注册 systemd 服务，跳过"
fi

echo "== 删除服务与配置 =="
rm -f "$SERVICE_FILE"
rm -f "$CONFIG_FILE"
systemctl daemon-reload 2>/dev/null || true

echo "== 删除程序与凭据 =="
rm -rf "$BASE_DIR"
for f in "${CREDENTIALS_FILES[@]}"; do
  rm -f "$f"
done

if [[ "$PURGE" == "1" ]]; then
  echo "== 删除数据与日志 =="
  if [[ -e "$DATA_DIR/ibdata1" || -e "$DATA_DIR/mysql.ibd" || -d "$DATA_DIR/mysql" ]]; then
    rm -rf "$DATA_DIR"
  else
    echo "  数据目录不像 MySQL 数据目录，跳过: ${DATA_DIR}" >&2
  fi
  rm -rf "$LOG_DIR"
  echo "  数据与日志已删除"
else
  echo "== 数据目录已保留 =="
  echo "  ${DATA_DIR}"
  echo "  需要彻底删除时执行: sudo bash $0 --purge"
fi

echo ""
echo "MySQL 已卸载。"
echo "系统用户 mysql 未删除（可能被其他程序共用）；如需删除: userdel mysql && groupdel mysql"
