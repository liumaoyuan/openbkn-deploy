#!/usr/bin/env bash
# 在离线/内网机器上导入镜像并核对完整性。
#
# 用法:
#   bash load-images.sh                # 默认读取 ../build/openbkn-images.tar
#   bash load-images.sh <tar 文件>
#
# 步骤:
#   1. 若存在 <tar>.sha256，先校验文件完整性
#   2. docker load 导入镜像
#   3. 按 compose 的 image 清单逐个检查镜像是否存在，并打印架构
#
# 注意:
#   导入完成后仍需在内网机器上生成 .env 与运行时配置:
#     cp .env.example .env   # 或者从原机器带过来
#     修改 OPENBKN_BIND_ADDRESS / OPENBKN_PUBLIC_BASE_URL
#     确认 docker/.env 与 docker/config/ 已按示例文件填写
#     docker compose --env-file .env up -d     # 不要加 --build
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

TAR="${1:-../build/openbkn-images.tar}"
if [[ ! -f "$TAR" ]]; then
  echo "找不到镜像包: $TAR" >&2
  exit 1
fi

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

ENV_ARGS=()
[[ -f .env ]] && ENV_ARGS=(--env-file .env)

echo "== 核对该栈所需的镜像 =="
missing=0
while IFS= read -r image; do
  if docker image inspect "$image" >/dev/null 2>&1; then
    arch=$(docker image inspect --format '{{.Os}}/{{.Architecture}}' "$image")
    printf '  ✓ %-58s %s\n' "$image" "$arch"
  else
    printf '  ✗ 缺失 %s\n' "$image" >&2
    missing=1
  fi
done < <(docker compose "${ENV_ARGS[@]}" config --images | sort -u)

if [[ $missing -ne 0 ]]; then
  echo "镜像不完整，请重新打包或检查 tar 包" >&2
  exit 1
fi

echo "== 全部镜像就绪（本机架构: $(docker version --format '{{.Server.Os}}/{{.Server.Arch}}')）=="
echo "下一步: 确认 .env 与 config/ 已填写 → docker compose --env-file .env up -d"
