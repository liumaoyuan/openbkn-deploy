<#
.SYNOPSIS
  在离线/内网机器上导入镜像，并核对完整性与 CPU 架构。

.DESCRIPTION
  与 load-images.sh 等价，供纯 PowerShell 环境使用。
  依次执行：校验 sha256 → docker load → 按 compose 清单核对镜像是否存在、架构是否与本机一致。

  架构不一致会直接失败。docker load 与 docker compose up 都不校验架构，
  放行的话容器一启动就 exec format error，表现为所有容器 Restarting (255)。

.PARAMETER Tar
  镜像 tar 路径。不指定时自动挑选 ../build 下带架构后缀的包，其次旧的通用包名。

.PARAMETER AllowArchMismatch
  跳过架构校验。只有宿主机装了 binfmt/QEMU 模拟、确实要跨架构运行时才用。

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\load-images.ps1
  powershell -ExecutionPolicy Bypass -File .\load-images.ps1 -Tar ..\build\jiuge-bkn-images-arm64.tar
#>
[CmdletBinding()]
param(
  [string]$Tar = "",
  [switch]$AllowArchMismatch
)

$ErrorActionPreference = "Stop"
Set-Location -LiteralPath $PSScriptRoot

# 没指定时自动挑选：优先带架构后缀的包，其次旧的通用包名。
if ([string]::IsNullOrWhiteSpace($Tar)) {
  $candidates = @(Get-ChildItem -Path "..\build" -Filter "jiuge-bkn-images-*.tar" -ErrorAction SilentlyContinue) +
                @(Get-Item -LiteralPath "..\build\jiuge-bkn-images.tar" -ErrorAction SilentlyContinue)
  if ($candidates.Count -gt 0) { $Tar = $candidates[0].FullName }
}

if ([string]::IsNullOrWhiteSpace($Tar) -or -not (Test-Path -LiteralPath $Tar)) {
  throw "找不到镜像包: $Tar（用法: .\load-images.ps1 -Tar <tar 文件>）"
}
Write-Host "== 镜像包: $Tar =="

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

# 宿主机架构归一化：uname 的 aarch64 与 docker 的 arm64 指的是同一件事。
$hostArch = (docker version --format '{{.Server.Arch}}' 2>$null | Out-String).Trim()
if ([string]::IsNullOrWhiteSpace($hostArch) -or $hostArch -eq "unknown") {
  $hostArch = (uname -m 2>$null | Out-String).Trim()
}
switch ($hostArch) {
  { $_ -in @("x86_64", "amd64") }          { $hostArch = "amd64" }
  { $_ -in @("aarch64", "arm64", "arm64/v8") } { $hostArch = "arm64" }
}

$envArgs = @()
if (Test-Path -LiteralPath ".env") { $envArgs = @("--env-file", ".env") }

# 核对一律按本机架构：镜像 tag 就是架构名（jiuge-bkn/xxx:arm64），
# 与本机 uname -m 一一对应，不依赖 .env 里可能没改的 JIUGEBKN_IMAGE_TAG。
$env:JIUGEBKN_IMAGE_TAG = $hostArch

# 但启动时 compose 读的是 .env，所以仍要提醒把它改成一致的。
$envLine = Select-String -LiteralPath ".env" -Pattern '^JIUGEBKN_IMAGE_TAG=' | Select-Object -First 1
$envTag = if ($envLine) { ($envLine.Line -split '=', 2)[1].Trim() } else { "" }
if ($envTag -and $envTag -ne $hostArch) {
  Write-Host ""
  Write-Host ("  ! .env 的 JIUGEBKN_IMAGE_TAG={0} 与本机架构 {1} 不一致" -f $envTag, $hostArch) -ForegroundColor Yellow
  Write-Host "    本次核对已按本机架构进行；启动前请把 .env 改成:" -ForegroundColor Yellow
  Write-Host ("      JIUGEBKN_IMAGE_TAG={0}" -f $hostArch) -ForegroundColor Yellow
  Write-Host "    否则 docker compose up 会找不到镜像。" -ForegroundColor Yellow
  Write-Host ""
}

$images = @(docker compose @envArgs config --images | Sort-Object -Unique)
if ($images.Count -eq 0) { throw "未从 compose 解析到任何镜像" }

Write-Host "== 核对该栈所需的镜像（本机架构: linux/$hostArch）=="
$missing = @()
$mismatched = @()
foreach ($img in $images) {
  $null = docker image inspect $img 2>$null
  if ($LASTEXITCODE -ne 0) {
    Write-Host ("  ✗ 缺失 {0}" -f $img)
    $missing += $img
    continue
  }

  # 带 --platform 优先：containerd 镜像存储下同一 tag 可能同时存在多架构，
  # 不带该参数拿到的是宿主机架构那一份。取不到时退回普通 inspect。
  $arch = (docker image inspect --platform "linux/$hostArch" --format '{{.Architecture}}' $img 2>$null | Out-String).Trim()
  if ([string]::IsNullOrWhiteSpace($arch)) {
    $arch = (docker image inspect --format '{{.Architecture}}' $img 2>$null | Out-String).Trim()
    if ([string]::IsNullOrWhiteSpace($arch)) { $arch = "?" }
  }

  if ($arch -eq $hostArch) {
    Write-Host ("  ✓ {0,-58} linux/{1}" -f $img, $arch)
  }
  else {
    Write-Host ("  ✗ {0,-58} linux/{1}" -f $img, $arch)
    $mismatched += ("{0}  (linux/{1})" -f $img, $arch)
  }
}

$failed = $false

if ($missing.Count -gt 0) {
  Write-Host "镜像不完整，请重新打包或检查 tar 包" -ForegroundColor Red
  Write-Host "若 tar 包内容正确，检查 .env 的 JIUGEBKN_IMAGE_TAG 是否与包一致" -ForegroundColor Red
  Write-Host "（x86 包应为 amd64，ARM 包应为 arm64；镜像名由它拼出）" -ForegroundColor Red
  $failed = $true
}

if ($mismatched.Count -gt 0) {
  if ($AllowArchMismatch) {
    Write-Host ""
    Write-Host "  ! 以下镜像架构与本机不符，按 -AllowArchMismatch 继续导入:"
    $mismatched | ForEach-Object { Write-Host ("      {0}" -f $_) }
  }
  else {
    Write-Host ""
    Write-Host "以下镜像架构与本机（linux/$hostArch）不符:" -ForegroundColor Red
    $mismatched | ForEach-Object { Write-Host ("  ✗ {0}" -f $_) -ForegroundColor Red }
    Write-Host ""
    Write-Host "镜像能 load、能 up，但容器启动时会 exec format error，"
    Write-Host "表现为所有容器 Restarting (255)——这不是配置问题，是镜像包拿错了架构。"
    Write-Host ""
    Write-Host "请在打包机上用对应的脚本重新出包:"
    Write-Host "  x86 机器:  bash pull-images.sh --arch amd64 && bash package-images.sh --arch amd64"
    Write-Host "  ARM 机器:  bash pull-images.sh --arch arm64 && bash package-images.sh --arch arm64"
    Write-Host "确实需要跨架构运行（宿主机已装 binfmt/QEMU 模拟）时，"
    Write-Host "再加 -AllowArchMismatch 重跑本脚本。"
    $failed = $true
  }
}

if ($failed) { throw "镜像导入未通过校验" }

Write-Host "== 全部镜像就绪 =="
Write-Host "下一步: 确认 .env 与 config/ 已填写 → docker compose --env-file .env up -d"
