#!/usr/bin/env bash
# 打包本栈所需的全部 Docker 镜像，用于迁移到内网/离线机器。
#
# 用法:
#   bash 打包镜像.sh                 # 先构建应用镜像，再打包全部镜像
#   bash 打包镜像.sh --list          # 只列出镜像清单和本地体积，不导出
#   bash 打包镜像.sh <输出文件>       # 指定输出路径（默认 ../build/openbkn-images.tar）
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
#   image 字段——应用镜像的 image 名由 compose 固定为 openbkn/<service>:<tag>，
#   构建来源是本机工作区源码（../../bkn-foundry、../../bkn-studio），
#   与 GitHub Actions 发布的镜像无关。
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

OUT="../build/openbkn-images.tar"
LIST_ONLY=0

for arg in "$@"; do
  case "$arg" in
    --list) LIST_ONLY=1 ;;
    -h|--help) sed -n '2,25p' "$0"; exit 0 ;;
    *) OUT="$arg" ;;
  esac
done

if [[ ! -f .env ]]; then
  echo "缺少 .env，请先运行: python3 初始化.py" >&2
  exit 1
fi

if [[ "$LIST_ONLY" != "1" && "${SKIP_BUILD:-0}" != "1" ]]; then
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

if command -v sha256sum >/dev/null 2>&1; then
  sha256sum "$OUT" > "$OUT.sha256"
else
  shasum -a 256 "$OUT" > "$OUT.sha256"
fi

echo "== 完成 =="
ls -lh "$OUT"
echo "把 $OUT、$OUT.sha256、images.txt 与本目录一起拷贝到内网机器，"
echo "在内网机器上执行: bash 导入镜像.sh"
