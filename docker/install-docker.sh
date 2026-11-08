#!/usr/bin/env bash
# 在最简化的 Linux（麒麟 V10 / 其他 glibc 发行版）上安装 Docker Engine + Compose 插件。
#
# 安装包默认从 app/<架构>/ 自动识别：
#   app/amd64/docker-*.tgz
#   app/amd64/docker-compose-linux-x86_64
#   app/arm64/docker-*.tgz
#   app/arm64/docker-compose-linux-aarch64
#
# 用法：
#   sudo bash install-docker.sh                          # 自动识别架构和安装包
#   sudo bash install-docker.sh --check                  # 只打印识别结果，不安装
#   sudo bash install-docker.sh <docker.tgz> [compose]   # 手动指定（兼容旧用法）
#
# 脚本做四件事：
#   1. 把 docker / dockerd / containerd / runc 等装到 /usr/local/bin
#   2. 把 compose 插件装到 /usr/local/lib/docker/cli-plugins
#   3. 写入 systemd 服务与日志轮转配置（已存在则不覆盖）
#   4. 启动 docker 并做版本自检
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  sed -n '2,22p' "$0"
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
if [[ ${#ARGS[@]} -gt 2 ]]; then
  usage
fi
TGZ="${ARGS[0]:-}"
COMPOSE="${ARGS[1]:-}"

case "$(uname -m)" in
  x86_64)
    APP_DIR="amd64"
    COMPOSE_ARCH="x86_64"
    ;;
  aarch64 | arm64)
    APP_DIR="arm64"
    COMPOSE_ARCH="aarch64"
    ;;
  *)
    echo "不支持的 CPU 架构: $(uname -m)" >&2
    exit 1
    ;;
esac

if [[ -z "$TGZ" ]]; then
  # 同目录下可能有多个版本，按版本号取最新的一个。
  mapfile -t CANDIDATES < <(ls -1 "${SCRIPT_DIR}/app/${APP_DIR}"/docker-*.tgz 2>/dev/null | sort -V)
  if [[ ${#CANDIDATES[@]} -eq 0 ]]; then
    echo "未找到 Docker 静态包，请确认存在: ${SCRIPT_DIR}/app/${APP_DIR}/docker-<版本>.tgz" >&2
    exit 1
  fi
  TGZ="${CANDIDATES[${#CANDIDATES[@]} - 1]}"
fi

if [[ -z "$COMPOSE" ]]; then
  for candidate in \
    "${SCRIPT_DIR}/app/${APP_DIR}/docker-compose-linux-${COMPOSE_ARCH}" \
    "${SCRIPT_DIR}/app/${APP_DIR}/docker-compose"; do
    if [[ -f "$candidate" ]]; then
      COMPOSE="$candidate"
      break
    fi
  done
fi

if [[ -z "$COMPOSE" ]]; then
  echo "未找到 compose 插件，请确认存在: ${SCRIPT_DIR}/app/${APP_DIR}/docker-compose-linux-${COMPOSE_ARCH}" >&2
  exit 1
fi

[[ -f "$TGZ" ]] || { echo "找不到 Docker 静态包: $TGZ" >&2; exit 1; }
[[ -f "$COMPOSE" ]] || { echo "找不到 compose 插件: $COMPOSE" >&2; exit 1; }

if [[ "$CHECK_ONLY" == "1" ]]; then
  echo "架构        : $(uname -m) (app/${APP_DIR})"
  echo "Docker 包   : $TGZ"
  echo "Compose 插件: $COMPOSE"
  exit 0
fi

if [[ $EUID -ne 0 ]]; then
  echo "请用 root 运行: sudo bash $0" >&2
  exit 1
fi

echo "== 安装 Docker 到 /usr/local/bin =="
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
tar -xzf "$TGZ" -C "$tmpdir"
install -m 0755 "$tmpdir"/docker/docker "$tmpdir"/docker/dockerd "$tmpdir"/docker/containerd \
  "$tmpdir"/docker/containerd-shim-runc-v2 "$tmpdir"/docker/runc "$tmpdir"/docker/ctr \
  "$tmpdir"/docker/docker-init "$tmpdir"/docker/docker-proxy /usr/local/bin/

echo "== 安装 docker compose 插件 =="
install -d /usr/local/lib/docker/cli-plugins
install -m 0755 "$COMPOSE" /usr/local/lib/docker/cli-plugins/docker-compose

echo "== 配置 systemd 服务 =="
if [[ ! -f /etc/systemd/system/docker.service ]]; then
  cat > /etc/systemd/system/docker.service <<'UNIT'
[Unit]
Description=Docker Application Container Engine
Documentation=https://docs.docker.com
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
ExecStart=/usr/local/bin/dockerd
ExecReload=/bin/kill -s HUP $MAINPID
TimeoutSec=0
RestartSec=2
Restart=always
StartLimitBurst=3
StartLimitInterval=60s
LimitNOFILE=infinity
LimitNPROC=infinity
LimitCORE=infinity
TasksMax=infinity
Delegate=yes
KillMode=process
OOMScoreAdjust=-500

[Install]
WantedBy=multi-user.target
UNIT
  echo "  已写入 /etc/systemd/system/docker.service"
else
  echo "  /etc/systemd/system/docker.service 已存在，保持不动"
fi

if [[ ! -f /etc/docker/daemon.json ]]; then
  mkdir -p /etc/docker
  cat > /etc/docker/daemon.json <<'JSON'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "100m", "max-file": "3" }
}
JSON
  echo "  已写入 /etc/docker/daemon.json（日志轮转）"
else
  echo "  /etc/docker/daemon.json 已存在，保持不动"
fi

if ! getent group docker >/dev/null 2>&1; then
  groupadd docker
fi
if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
  usermod -aG docker "$SUDO_USER" || true
  echo "  已把 ${SUDO_USER} 加入 docker 组（重新登录后生效）"
fi

echo "== 启动 docker =="
systemctl daemon-reload
systemctl enable docker >/dev/null 2>&1 || true
if ! systemctl restart docker; then
  echo "docker 启动失败，查看日志：journalctl -u docker -n 100 --no-pager" >&2
  exit 1
fi

sleep 2
echo "== 自检 =="
docker version --format 'Docker Engine {{.Server.Version}} ({{.Server.Os}}/{{.Server.Arch}})' || {
  echo "docker 未正常响应，查看日志：journalctl -u docker -n 100 --no-pager" >&2
  exit 1
}
docker compose version

cat <<'TIP'

安装完成。
如果启动容器时出现 iptables/nftables 或 KySec 相关报错，先看：
  journalctl -u docker -n 100 --no-pager
麒麟 V10 请确认 KySec 没有拦截 dockerd / containerd / 内核模块。
TIP
