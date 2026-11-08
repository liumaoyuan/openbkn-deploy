<#
.SYNOPSIS
  打包本栈所需的全部 Docker 镜像，用于迁移到内网/离线机器。

.DESCRIPTION
  与 package-images.sh 等价，供纯 PowerShell 环境使用。
  镜像清单来自 docker compose config --images；应用镜像由本机工作区的
  bkn-foundry / bkn-studio 源码构建，不使用 GitHub Actions 产物。

.PARAMETER Output
  输出 tar 路径，默认 ..\build\openbkn-images.tar

.PARAMETER SkipBuild
  跳过 docker compose build，直接打包现有镜像

.PARAMETER List
  只列出镜像清单与体积，不导出

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\package-images.ps1 -List
  powershell -ExecutionPolicy Bypass -File .\package-images.ps1
#>
[CmdletBinding()]
param(
  [string]$Output = "..\build\openbkn-images.tar",
  [switch]$SkipBuild,
  [switch]$List
)

$ErrorActionPreference = "Stop"
Set-Location -LiteralPath $PSScriptRoot

if (-not (Test-Path -LiteralPath ".env")) {
  throw "缺少 .env，请先复制 .env.example 为 .env 并填写密码"
}

if (-not $List -and -not $SkipBuild) {
  # compose 里运行期镜像设了 pull_policy: never（离线机缺失时立即报错），
  # 所以打包机要显式拉取一次；--ignore-buildable 跳过本地构建的应用镜像。
  Write-Host "== 拉取运行期镜像 =="
  docker compose --env-file .env pull --ignore-buildable
  if ($LASTEXITCODE -ne 0) { throw "docker compose pull 失败" }

  Write-Host "== 构建应用镜像 =="
  docker compose --env-file .env build
  if ($LASTEXITCODE -ne 0) { throw "docker compose build 失败" }
}

$images = @(docker compose --env-file .env config --images | Sort-Object -Unique)
if ($images.Count -eq 0) { throw "未从 compose 解析到任何镜像" }

if ($List) {
  $total = [int64]0
  foreach ($img in $images) {
    $sizeText = docker image inspect --format '{{.Size}}' $img 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $sizeText) {
      Write-Host ("  缺失  {0}" -f $img)
      continue
    }
    $size = [int64]$sizeText
    $total += $size
    Write-Host ("  {0,-58} {1,8:N0} MB" -f $img, ($size / 1MB))
  }
  Write-Host ("共 {0} 个镜像，约 {1:N1} GB（解压后口径）" -f $images.Count, ($total / 1GB))
  return
}

$outDir = Split-Path -Parent $Output
if ([string]::IsNullOrWhiteSpace($outDir)) { $outDir = "." }
if (-not (Test-Path -LiteralPath $outDir)) {
  New-Item -ItemType Directory -Path $outDir | Out-Null
}

$manifest = Join-Path $outDir "images.txt"
Write-Host ("== 导出 {0} 个镜像 ==" -f $images.Count)
$images | Set-Content -LiteralPath $manifest -Encoding ASCII

docker save -o $Output $images
if ($LASTEXITCODE -ne 0) { throw "docker save 失败" }

$hash = (Get-FileHash -LiteralPath $Output -Algorithm SHA256).Hash.ToLower()
Set-Content -LiteralPath "$Output.sha256" -Value ("{0}  {1}" -f $hash, (Split-Path -Leaf $Output)) -Encoding ASCII

Write-Host "== 完成 =="
Get-Item -LiteralPath $Output | Select-Object FullName, @{n = 'SizeGB'; e = { [math]::Round($_.Length / 1GB, 2) } } | Format-List
Write-Host "把镜像 tar、.sha256、images.txt 与本目录一起拷贝到内网机器，"
Write-Host "在内网机器上执行: powershell -ExecutionPolicy Bypass -File .\load-images.ps1"
