#!/usr/bin/env bash
# 打包本栈所需的全部 Docker 镜像，用于迁移到内网/离线机器。
#
# 用法:
#   bash package-images.sh                 # 先构建应用镜像，再打包全部镜像
#   bash package-images.sh --list          # 只列出镜像清单和本地体积，不导出
#   bash package-images.sh <输出文件>       # 指定输出路径（默认 ../build/jiuge-bkn-images.tar）
#
# 环境变量:
#   SKIP_BUILD=1  跳过 docker compose build，直接打包现有镜像
#
# 产物:
#   <输出文件>            镜像 tar 包（docker load 可直接导入）
#   <输出文件>.sha256     校验和
#   images.txt            同一目录下的镜像清单，供导入脚本核对
#
# 说明:
#   镜像清单来自 `docker compose config --images`，即 compose 中所有服务的
#   image 字段——应用镜像的 image 名由 compose 固定为 jiuge-bkn/<service>:<tag>，
#   构建来源是本机工作区源码（../../bkn-foundry、../../bkn-studio），
#   与 GitHub Actions 发布的镜像无关。

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

OUT="../build/jiuge-bkn-images.tar"
LIST_ONLY=0

for arg in "$@"; do
  case "$arg" in
    --list) LIST_ONLY=1 ;;
    -h|--help)   awk 'NR==1{next} /^# 兼容被 sh\/dash/{exit} {print}' "$0"; exit 0 ;;
    *) OUT="$arg" ;;
  esac
done

if [[ ! -f .env ]]; then
  echo "缺少 .env，请先复制 .env.example 为 .env 并填写密码" >&2
  exit 1
fi

if [[ "$LIST_ONLY" != "1" && "${SKIP_BUILD:-0}" != "1" ]]; then
  # compose 里运行期镜像设了 pull_policy: never（离线机缺失时立即报错），
  # 所以打包机要显式拉取一次；--ignore-buildable 跳过本地构建的应用镜像。
  echo "== 拉取运行期镜像 =="
  docker compose --env-file .env pull --ignore-buildable

  echo "== 构建应用镜像 =="
  docker compose --env-file .env build
fi

mapfile -t IMAGES < <(docker compose --env-file .env config --images | sort -u)
if [[ ${#IMAGES[@]} -eq 0 ]]; then
  echo "未从 compose 解析到任何镜像" >&2
  exit 1
fi

if [[ "$LIST_ONLY" == "1" ]]; then
  total=0
  for image in "${IMAGES[@]}"; do
    size=$(docker image inspect --format '{{.Size}}' "$image" 2>/dev/null || echo 0)
    if [[ "$size" == "0" ]]; then
      echo "  缺失  $image"
    else
      total=$((total + size))
      printf '  %-58s %s\n' "$image" "$(numfmt --to=iec --suffix=B "$size" 2>/dev/null || echo "$size")"
    fi
  done
  echo "共 ${#IMAGES[@]} 个镜像，约 $(numfmt --to=iec --suffix=B "$total" 2>/dev/null || echo "$total")"
  exit 0
fi

mkdir -p "$(dirname "$OUT")"
MANIFEST="$(dirname "$OUT")/images.txt"

echo "== 导出 ${#IMAGES[@]} 个镜像 =="
printf '%s\n' "${IMAGES[@]}" | tee "$MANIFEST"

docker save -o "$OUT" "${IMAGES[@]}"

# 只写文件名（不写路径），这样 bash 与 PowerShell 两个打包端、两个导入端都能校验。
if command -v sha256sum >/dev/null 2>&1; then
  file_hash=$(sha256sum "$OUT" | awk '{print $1}')
else
  file_hash=$(shasum -a 256 "$OUT" | awk '{print $1}')
fi
printf '%s  %s\n' "$file_hash" "$(basename "$OUT")" > "$OUT.sha256"

echo "== 完成 =="
ls -lh "$OUT"
echo "把 $OUT、$OUT.sha256、images.txt 与本目录一起拷贝到内网机器，"
echo "在内网机器上执行: bash load-images.sh"
