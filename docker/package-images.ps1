<#
.SYNOPSIS
  打包 JiugeBKN 镜像：按架构构建应用镜像并导出 tar。

.DESCRIPTION
  只负责"构建 + 导出"，不拉取镜像。所需镜像请先执行 pull-images.ps1。
  与 package-images.sh 等价，供 Windows 环境使用（Windows 为主路径）。

  镜像 tag：
    - 包内 tag 与 .env 的 JIUGEBKN_IMAGE_TAG 一致（默认 local），目标机无需改配置。
    - 打包完成后，应用镜像会额外打上 <tag>-<arch> 标签，
      例如 jiuge-bkn/bkn-safe:local-amd64 / :local-arm64，
      这样两套架构可以同时留在本机，互不覆盖。

.PARAMETER Arch
  amd64 / arm64 / both。

.PARAMETER List
  只列出镜像清单和本地架构，不构建、不导出。

.PARAMETER BuildOnly
  只构建应用镜像。

.PARAMETER SaveOnly
  只校验并导出（构建已完成时用）。

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\package-images.ps1 -Arch amd64
  powershell -ExecutionPolicy Bypass -File .\package-images.ps1 -Arch both
  powershell -ExecutionPolicy Bypass -File .\package-images.ps1 -Arch arm64 -List
#>
[CmdletBinding()]
param(
  [ValidateSet("amd64", "arm64", "both")]
  [string]$Arch = "",
  [switch]$List,
  [switch]$BuildOnly,
  [switch]$SaveOnly
)

# 原生命令写 stderr 在 Stop 模式下会变成终止异常，这里改为 Continue，
# 统一用 $LASTEXITCODE 判断，出错时显式 throw。
$ErrorActionPreference = "Continue"
Set-Location -LiteralPath $PSScriptRoot

$BuildDir = "..\build"
$Override = ".compose-arch.override.yml"
$AppPrefix = "jiuge-bkn/"

function Write-Step([string]$Message) { Write-Host ""; Write-Host "== $Message ==" }
function Write-Info([string]$Message) { Write-Host "  $Message" }
function Write-Warn([string]$Message) { Write-Host "  ! $Message" -ForegroundColor Yellow }

if (-not (Test-Path -LiteralPath ".env")) {
  throw "缺少 .env，请先复制 .env.example 为 .env 并填写密码"
}

# 本机架构
$hostArch = (docker version --format '{{.Server.Arch}}' 2>$null | Out-String).Trim()
if ([string]::IsNullOrWhiteSpace($hostArch) -or $hostArch -eq "unknown") {
  $hostArch = (uname -m 2>$null | Out-String).Trim()
}
switch -Regex ($hostArch) {
  '^(x86_64|amd64)$'  { $hostArch = "amd64" }
  '^(aarch64|arm64)' { $hostArch = "arm64" }
}

if ([string]::IsNullOrWhiteSpace($Arch)) {
  $Arch = $hostArch
  Write-Info "未指定 -Arch，按本机架构处理: $Arch"
}
$archs = if ($Arch -eq "both") { @("amd64", "arm64") } else { @($Arch) }

# 基础 tag：来自 .env，包内镜像用它命名，目标机不需要改配置
$envLine = Select-String -LiteralPath ".env" -Pattern '^JIUGEBKN_IMAGE_TAG=' | Select-Object -First 1
$baseTag = if ($envLine) { ($envLine.Line -split '=', 2)[1].Trim() } else { "local" }
if ([string]::IsNullOrWhiteSpace($baseTag)) { $baseTag = "local" }

Write-Info "本机架构: $hostArch    目标架构: $($archs -join ',')    镜像 tag: $baseTag"

# 交叉构建的环境检查
foreach ($archName in $archs) {
  if ($archName -eq $hostArch) { continue }
  docker buildx version *> $null
  if ($LASTEXITCODE -ne 0) { throw "交叉构建需要 docker buildx 插件（原生构建不需要）" }
  $platforms = (docker buildx inspect --bootstrap 2>$null | Select-String '^Platforms:').Line
  if ($platforms -notmatch [regex]::Escape("linux/$archName")) {
    throw "构建器不支持 linux/$archName，请先启用 QEMU 模拟（binfmt / qemu-user-static）"
  }
  Write-Warn "linux/$archName 与本机不同，构建走 QEMU 模拟，耗时明显增加"
  break
}

# 镜像清单
$images = @(docker compose --env-file .env config --images | Sort-Object -Unique)
if ($images.Count -eq 0) { throw "未从 compose 解析到任何镜像" }

$appImages = @($images | Where-Object { $_ -like "$AppPrefix*" })
$runtimeImages = @($images | Where-Object { $_ -notlike "$AppPrefix*" })
Write-Info ("共 {0} 个镜像：应用镜像 {1} 个，第三方镜像 {2} 个" -f $images.Count, $appImages.Count, $runtimeImages.Count)

function Get-ImageArch {
  param([string]$Image, [string]$ArchName)
  $a = (docker image inspect --platform "linux/$ArchName" --format '{{.Architecture}}' $Image 2>$null | Out-String).Trim()
  if ($LASTEXITCODE -ne 0) { return "" }
  return $a
}

function Show-List {
  param([string]$ArchName)

  Write-Step "镜像清单（linux/$ArchName）"
  $total = [int64]0
  foreach ($img in $images) {
    $a = Get-ImageArch -Image $img -ArchName $ArchName
    $sizeText = (docker image inspect --format '{{.Size}}' $img 2>$null | Out-String).Trim()
    $size = 0
    if ($sizeText) { $size = [int64]$sizeText }
    $total += $size
    $human = if ($size -gt 0) { "{0:N0} MB" -f ($size / 1MB) } else { "缺失" }
    $shown = if ($a) { $a } else { "-" }
    Write-Host ("  {0,-58} {1,-8} {2}" -f $img, $shown, $human)
  }
  Write-Host ("共 {0} 个镜像，约 {1:N1} GB（解压后口径）" -f $images.Count, ($total / 1GB))
  Write-Host "架构列显示 - 表示本地还没有 linux/$ArchName 版本，先执行 pull-images.ps1"
}

function Write-Override {
  param([string]$ArchName)

  $services = @(docker compose --env-file .env config --services)
  $lines = @(
    "# 由 package-images.ps1 生成，仅用于注入构建平台，退出时自动删除。"
    "services:"
  )
  foreach ($svc in $services) {
    $lines += "  ${svc}:"
    $lines += "    platform: linux/$ArchName"
  }
  Set-Content -LiteralPath $Override -Value $lines -Encoding ASCII
}

function Invoke-Build {
  param([string]$ArchName)

  Write-Step "构建应用镜像（linux/$ArchName）"
  # 显式指定 tag：保证包内镜像名与 .env 一致，且不受外部环境影响
  $env:JIUGEBKN_IMAGE_TAG = $baseTag
  $start = Get-Date
  docker compose --env-file .env -f compose.yml -f $Override build --progress plain
  if ($LASTEXITCODE -ne 0) { throw "构建失败（linux/$ArchName）" }
  $mins = [int]((Get-Date) - $start).TotalMinutes
  Write-Info "构建完成，耗时 $mins 分钟"
}

function Test-ImageArch {
  param([string]$ArchName)

  Write-Step "校验架构（目标 $ArchName）"
  $bad = @()
  foreach ($img in $images) {
    $a = Get-ImageArch -Image $img -ArchName $ArchName
    if ([string]::IsNullOrWhiteSpace($a)) {
      $bad += "$img  （本地没有 linux/$ArchName 版本）"
    }
    elseif ($a -ne $ArchName) {
      $bad += "$img  ($a)"
    }
  }
  if ($bad.Count -gt 0) {
    Write-Host ""
    Write-Host "以下镜像不是 $ArchName，导出后无法在目标机运行:" -ForegroundColor Red
    $bad | ForEach-Object { Write-Host "  ✗ $_" -ForegroundColor Red }
    throw "先执行: powershell -ExecutionPolicy Bypass -File .\pull-images.ps1 -Arch $ArchName"
  }
  Write-Info "$($images.Count) 个镜像全部为 linux/$ArchName"
}

function Save-Images {
  param([string]$ArchName)

  Write-Step "导出镜像包（linux/$ArchName）"
  if (-not (Test-Path -LiteralPath $BuildDir)) {
    New-Item -ItemType Directory -Path $BuildDir | Out-Null
  }

  $out = Join-Path $BuildDir "jiuge-bkn-images-$ArchName.tar"

  # 带 --platform：本机可能同时存有同一 tag 的另一个架构，不带会一起导出
  docker save --platform "linux/$ArchName" -o $out $images
  if ($LASTEXITCODE -ne 0) { throw "docker save 失败" }

  $manifest = Join-Path $BuildDir "images-$ArchName.txt"
  $rows = @(("{0,-58} {1}" -f "# image", "architecture"))
  foreach ($img in $images) {
    $rows += ("{0,-58} {1}" -f $img, (Get-ImageArch -Image $img -ArchName $ArchName))
  }
  # 显式 LF：Set-Content 会写 CRLF，Linux 上读文件名会带 \r
  $manifestPath = [System.IO.Path]::Combine((Get-Location).ProviderPath, $manifest)
  [System.IO.File]::WriteAllText($manifestPath, ($rows -join "`n") + "`n", (New-Object System.Text.UTF8Encoding($false)))

  $hash = (Get-FileHash -LiteralPath $out -Algorithm SHA256).Hash.ToLower()
  $shaPath = [System.IO.Path]::Combine((Get-Location).ProviderPath, "$out.sha256")
  [System.IO.File]::WriteAllText($shaPath, ("{0}  {1}`n" -f $hash, (Split-Path -Leaf $out)), (New-Object System.Text.ASCIIEncoding))

  $info = Get-Item -LiteralPath $out
  Write-Info ("产物: {0}  ({1:N2} GB)" -f $info.FullName, ($info.Length / 1GB))
}

function Set-ArchTag {
  param([string]$ArchName)

  Write-Step "标注架构标签（$baseTag-$ArchName）"
  foreach ($img in $appImages) {
    $base = $img -replace ':[^:]*$', ''
    docker tag $img "${base}:$baseTag-$ArchName"
  }
  Write-Info "应用镜像已打上 :$baseTag-$ArchName，amd64 / arm64 两套可同时保留"
  Write-Info "（compose 用的 :$baseTag 仍指向本次构建的架构）"
}

# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------
try {
  foreach ($archName in $archs) {
    if ($List) {
      Show-List -ArchName $archName
      continue
    }
    if (-not $SaveOnly) {
      Write-Override -ArchName $archName
      Invoke-Build -ArchName $archName
      if ($BuildOnly) { continue }
    }
    Test-ImageArch -ArchName $archName
    Save-Images -ArchName $archName
    Set-ArchTag -ArchName $archName
  }
}
finally {
  if (Test-Path -LiteralPath $Override) { Remove-Item -LiteralPath $Override -Force }
}

if (-not $List) {
  Write-Step "完成"
  foreach ($archName in $archs) {
    Write-Host "  build\jiuge-bkn-images-$archName.tar  → 拷贝到目标机后执行:"
    Write-Host "    bash load-images.sh ../build/jiuge-bkn-images-$archName.tar"
  }
}
