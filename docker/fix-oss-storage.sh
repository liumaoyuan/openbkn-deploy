#!/bin/sh
# 存量 docker 部署的补丁：补默认 OSS 存储（含 MinIO 桶），恢复 SKILL 包上传。
#
# 适用场景：已经用旧包部署、没有 oss-storage-init 服务的环境。
# 新部署直接 docker compose up -d 就会自动执行，不需要本脚本。
#
# 用法（把本文件与 init-oss-storage.py 一起拷到部署目录）：
#     cd jiuge-bkn-deploy/docker
#     sh fix-oss-storage.sh
#
# 不改 .env / compose / config/，不重启任何服务；可重复执行。
set -eu

cd "$(dirname "$0")"

if [ ! -f .env ]; then
  echo "失败：当前目录没有 .env，请在 jiuge-bkn-deploy/docker 目录下执行" >&2
  exit 1
fi
if [ ! -f init-oss-storage.py ]; then
  echo "失败：缺少 init-oss-storage.py（需与本脚本放在同一目录）" >&2
  exit 1
fi

# 借 sandbox-control-plane 容器执行：它在编排网络内，且自带 boto3 和 MinIO 账号环境变量。
# 覆盖默认入口，不会启动常驻服务。
exec docker compose --env-file .env run --rm --no-deps -T \
  -e "BKN_OSS_BUCKET=${OSS_DEFAULT_BUCKET:-jiuge-bkn-objects}" \
  -e "BKN_OSS_STORAGE_NAME=${OSS_DEFAULT_STORAGE_NAME:-minio-default}" \
  -v "$(pwd)/init-oss-storage.py:/init-oss-storage.py:ro" \
  --entrypoint python sandbox-control-plane /init-oss-storage.py
