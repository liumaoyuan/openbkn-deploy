<#
.SYNOPSIS
  在离线/内网机器上导入镜像并核对完整性。

.DESCRIPTION
  与 load-images.sh 等价，供纯 PowerShell 环境使用。
  依次执行：校验 sha256 → docker load → 按 compose 清单核对镜像与架构。

.PARAMETER Tar
  镜像 tar 路径，默认 ..\build\openbkn-images.tar

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\load-images.ps1
#>
[CmdletBinding()]
param(
  [string]$Tar = "..\build\openbkn-images.tar"
)

$ErrorActionPreference = "Stop"
Set-Location -LiteralPath $PSScriptRoot

if (-not (Test-Path -LiteralPath $Tar)) {
  throw "找不到镜像包: $Tar"
}

if (Test-Path -LiteralPath "$Tar.sha256") {
  Write-Host "== 校验 sha256 =="
  $expected = ((Get-Content -LiteralPath "$Tar.sha256" -Raw) -split '\s+')[0].ToLower()
  $actual = (Get-FileHash -LiteralPath $Tar -Algorithm SHA256).Hash.ToLower()
  if ($expected -ne $actual) { throw "sha256 不一致: $Tar" }
  Write-Host "  ✓ 校验通过"
}

Write-Host "== 导入镜像 =="
docker load -i $Tar
if ($LASTEXITCODE -ne 0) { throw "docker load 失败" }

$envArgs = @()
if (Test-Path -LiteralPath ".env") { $envArgs = @("--env-file", ".env") }

$images = @(docker compose @envArgs config --images | Sort-Object -Unique)
if ($images.Count -eq 0) { throw "未从 compose 解析到任何镜像" }

Write-Host "== 核对该栈所需的镜像 =="
$missing = 0
foreach ($img in $images) {
  $arch = docker image inspect --format '{{.Os}}/{{.Architecture}}' $img 2>$null
  if ($LASTEXITCODE -ne 0) {
    Write-Host ("  ✗ 缺失 {0}" -f $img)
    $missing++
  }
  else {
    Write-Host ("  ✓ {0,-58} {1}" -f $img, $arch)
  }
}

if ($missing -gt 0) { throw "镜像不完整，请重新打包或检查 tar 包" }

$server = docker version --format '{{.Server.Os}}/{{.Server.Arch}}'
Write-Host "== 全部镜像就绪（本机架构: $server）=="
Write-Host "下一步: 确认 .env 与 config/ 已填写 → docker compose --env-file .env up -d"
