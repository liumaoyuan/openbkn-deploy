<#
.SYNOPSIS
  存量 docker 部署的补丁：补默认 OSS 存储（含 MinIO 桶），恢复 SKILL 包上传。

.DESCRIPTION
  与 fix-oss-storage.sh 等价，供纯 PowerShell 环境使用。
  需要 init-oss-storage.py 与本脚本放在同一目录（随部署目录一起交付）。

  新部署直接 docker compose up -d 会自动执行 oss-storage-init 服务，不需要本脚本。

  不改 .env / compose / config\，不重启任何服务；可重复执行。

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\fix-oss-storage.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
Set-Location -LiteralPath $PSScriptRoot

if (-not (Test-Path -LiteralPath ".env")) {
  throw "当前目录没有 .env，请在 jiuge-bkn-deploy\docker 目录下执行"
}
if (-not (Test-Path -LiteralPath "init-oss-storage.py")) {
  throw "缺少 init-oss-storage.py（需与本脚本放在同一目录）"
}

$bucket = if ($env:OSS_DEFAULT_BUCKET) { $env:OSS_DEFAULT_BUCKET } else { "jiuge-bkn-objects" }
$storageName = if ($env:OSS_DEFAULT_STORAGE_NAME) { $env:OSS_DEFAULT_STORAGE_NAME } else { "minio-default" }

# 借 sandbox-control-plane 容器执行：它在编排网络内，且自带 boto3 和 MinIO 账号环境变量。
# 挂载用正斜杠路径，避免盘符里的冒号与 -v 的 source:target 语法冲突。
$mount = ((Resolve-Path -LiteralPath "init-oss-storage.py").Path -replace '\\', '/') + ":/init-oss-storage.py:ro"

docker compose --env-file .env run --rm --no-deps -T `
  -e "BKN_OSS_BUCKET=$bucket" `
  -e "BKN_OSS_STORAGE_NAME=$storageName" `
  -v $mount --entrypoint python sandbox-control-plane /init-oss-storage.py
if ($LASTEXITCODE -ne 0) {
  exit $LASTEXITCODE
}
