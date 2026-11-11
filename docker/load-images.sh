#!/usr/bin/env bash
# 在离线/内网机器上导入镜像，并核对完整性**与 CPU 架构**。
#
# 用法:
#   bash load-images.sh                        # 自动挑选镜像包
#   bash load-images.sh <tar 文件>
#   bash load-images.sh --allow-arch-mismatch  # 跳过架构校验（已装 binfmt 模拟时才用）
#
# 步骤:
#   1. 若存在 <tar>.sha256，先校验文件完整性
#   2. docker load 导入镜像
#   3. 按 compose 的 image 清单逐个检查镜像是否存在、架构是否与本机一致
#      架构不一致直接失败：docker load 和 docker compose up 都不校验架构，
#      放行的话容器一启动就 exec format error，表现为 Restarting (255)。
#
# 注意:
#   导入完成后仍需在内网机器上生成 .env 与运行时配置:
#     cp .env.example .env   # 或者从原机器带过来
#     修改 JIUGEBKN_BIND_ADDRESS / JIUGEBKN_PUBLIC_BASE_URL
#     确认 docker/.env 与 docker/config/ 已按示例文件填写
#     docker compose --env-file .env up -d     # 不要加 --build

# 兼容被 sh/dash 直接执行：本脚本使用 bash 特性，自动切回 bash。
if [ -z "${BASH_VERSION:-}" ]; then
  if command -v bash >/dev/null 2>&1; then
    exec bash "$0" "$@"
  fi
  echo "请用 bash 运行: sudo bash $0" >&2
  exit 1
fi

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

TAR=""
ALLOW_MISMATCH=0
for arg in "$@"; do
  case "$arg" in
    --allow-arch-mismatch) ALLOW_MISMATCH=1 ;;
    -h|--help)
      awk 'NR==1{next} /^# 兼容被 sh\/dash/{exit} {print}' "$0"
      exit 0
      ;;
    -*) echo "未知参数: $arg（见 --help）" >&2; exit 1 ;;
    *)  TAR="$arg" ;;
  esac
done

# 没指定时自动挑选：优先带架构后缀的包，其次旧的通用包名。
if [[ -z "$TAR" ]]; then
  for candidate in ../build/jiuge-bkn-images-*.tar ../build/jiuge-bkn-images.tar; do
    if [[ -f "$candidate" ]]; then
      TAR="$candidate"
      break
    fi
  done
fi
if [[ -z "$TAR" || ! -f "$TAR" ]]; then
  echo "找不到镜像包: ${TAR:-../build/}" >&2
  echo "用法: bash load-images.sh <tar 文件>" >&2
  exit 1
fi
echo "== 镜像包: $TAR =="

if [[ -f "$TAR.sha256" ]]; then
  echo "== 校验 sha256 =="
  expected=$(awk '{print $1}' "$TAR.sha256")
  if command -v sha256sum >/dev/null 2>&1; then
    actual=$(sha256sum "$TAR" | awk '{print $1}')
  else
    actual=$(shasum -a 256 "$TAR" | awk '{print $1}')
  fi
  if [[ "$expected" != "$actual" ]]; then
    echo "sha256 不一致: $TAR" >&2
    exit 1
  fi
  echo "  ✓ 校验通过"
fi

echo "== 导入镜像 =="
docker load -i "$TAR"

# 宿主机架构归一化：uname 的 aarch64 与 docker 的 arm64 指的是同一件事。
host_arch=$(docker version --format '{{.Server.Arch}}' 2>/dev/null | tr -d '\r')
case "$host_arch" in
  ""|unknown)             host_arch=$(uname -m) ;;
esac
case "$host_arch" in
  x86_64|amd64)           host_arch="amd64" ;;
  aarch64|arm64|arm64/v8) host_arch="arm64" ;;
esac

ENV_ARGS=()
[[ -f .env ]] && ENV_ARGS=(--env-file .env)

# 核对一律按本机架构：镜像 tag 就是架构名（jiuge-bkn/xxx:arm64），
# 与本机 uname -m 一一对应，不依赖 .env 里可能没改的 JIUGEBKN_IMAGE_TAG。
# （环境变量优先于 --env-file，所以下面这一行会覆盖 .env 的值。）
export JIUGEBKN_IMAGE_TAG="$host_arch"

# 启动时 compose 读的是 .env，tag 不一致的话 up 会找不到镜像。
# 与其让人记着改，这里直接改成当前架构（原文件备份为 .env.bak）。
if [[ -f .env ]]; then
  env_tag=$(awk -F= '/^JIUGEBKN_IMAGE_TAG=/{sub(/\r$/,"",$2); print $2; exit}' .env 2>/dev/null || true)
  if [[ "$env_tag" != "$host_arch" ]]; then
    cp -f .env .env.bak 2>/dev/null || true
    if grep -q '^JIUGEBKN_IMAGE_TAG=' .env; then
      sed -i "s|^JIUGEBKN_IMAGE_TAG=.*|JIUGEBKN_IMAGE_TAG=$host_arch|" .env
    else
      printf '\nJIUGEBKN_IMAGE_TAG=%s\n' "$host_arch" >> .env
    fi
    {
      echo
      echo "  ! .env 的 JIUGEBKN_IMAGE_TAG 原为 ${env_tag:-未设置}，与本机架构 $host_arch 不一致"
      echo "    已自动改为 JIUGEBKN_IMAGE_TAG=$host_arch（原文件备份为 .env.bak）"
      echo
    } >&2
  fi
fi

echo "== 核对该栈所需的镜像（本机架构: linux/$host_arch）=="
missing=()
mismatched=()
while IFS= read -r image; do
  if ! docker image inspect "$image" >/dev/null 2>&1; then
    printf '  ✗ 缺失 %s\n' "$image" >&2
    missing+=("$image")
    continue
  fi

  # 带 --platform 优先：containerd 镜像存储下同一 tag 可能同时存在多架构，
  # 不带该参数拿到的是宿主机架构那一份。取不到时退回普通 inspect。
  arch=$(docker image inspect --platform "linux/$host_arch" \
           --format '{{.Architecture}}' "$image" 2>/dev/null || true)
  [[ -z "$arch" ]] && arch=$(docker image inspect --format '{{.Architecture}}' "$image" 2>/dev/null || echo "?")

  if [[ "$arch" == "$host_arch" ]]; then
    printf '  ✓ %-58s linux/%s\n' "$image" "$arch"
  else
    printf '  ✗ %-58s linux/%s\n' "$image" "$arch" >&2
    mismatched+=("$image  (linux/$arch)")
  fi
done < <(docker compose "${ENV_ARGS[@]}" config --images | sort -u)

status=0

if (( ${#missing[@]} )); then
  {
    echo "镜像不完整，请重新打包或检查 tar 包"
    echo "若 tar 包内容正确，检查 .env 的 JIUGEBKN_IMAGE_TAG 是否与包一致"
    echo "（x86 包应为 amd64，ARM 包应为 arm64；镜像名由它拼出）"
  } >&2
  status=1
fi

if (( ${#mismatched[@]} )); then
  if (( ALLOW_MISMATCH )); then
    printf '\n  ! 以下镜像架构与本机不符，按 --allow-arch-mismatch 继续导入:\n'
    printf '      %s\n' "${mismatched[@]}"
  else
    {
      echo
      echo "以下镜像架构与本机（linux/$host_arch）不符:"
      printf '  ✗ %s\n' "${mismatched[@]}"
      echo
      echo "镜像能 load、能 up，但容器启动时会 exec format error，"
      echo "表现为所有容器 Restarting (255)——这不是配置问题，是镜像包拿错了架构。"
      echo
      echo "请在打包机上用对应的脚本重新出包:"
      echo "  x86 机器:  bash pull-images.sh --arch amd64 && bash package-images.sh --arch amd64"
      echo "  ARM 机器:  bash pull-images.sh --arch arm64 && bash package-images.sh --arch arm64"
      echo "确实需要跨架构运行（宿主机已装 binfmt/QEMU 模拟）时，"
      echo "再加 --allow-arch-mismatch 重跑本脚本。"
    } >&2
    status=1
  fi
fi

if (( status != 0 )); then
  exit 1
fi

echo "== 全部镜像就绪 =="
echo "下一步: 确认 .env 与 config/ 已填写 → docker compose --env-file .env up -d"
