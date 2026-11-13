<#
.SYNOPSIS
  拉取 JiugeBKN 构建与运行所需的全部镜像（amd64 / arm64 并存）。

.DESCRIPTION
  只负责"拉取"，不构建、不导出。构建与导出见 package-images.ps1。
  与 pull-images.sh 等价，供 Windows 环境使用（Windows 为主路径）。

  拉取策略（国内环境，有代理）：
    1. 先按镜像原名直连（Docker Desktop 配了代理会自动走代理）
    2. 失败再依次尝试国内镜像源：
         gcr.io/xxx  -> m.daocloud.io/gcr.io/xxx
         ghcr.io/xxx -> ghcr.nju.edu.cn/xxx
       拉下来后自动 tag 回原名，compose.yml 不需要改。

.PARAMETER Arch
  amd64 / arm64 / both，默认 both。

.PARAMETER Runtime
  只处理 9 个运行期镜像（会进交付包的那批）。

.PARAMETER BuildBase
  只处理 8 个构建期基础镜像（不进交付包，但构建时必须有）。

.PARAMETER Check
  只核对本地架构，不拉取。

.PARAMETER Clean
  删除清单内全部镜像（含两个架构），用于修复下载中断留下的损坏记录。

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\pull-images.ps1
  powershell -ExecutionPolicy Bypass -File .\pull-images.ps1 -Arch arm64 -Check
#>
[CmdletBinding()]
param(
  [ValidateSet("amd64", "arm64", "both")]
  [string]$Arch = "both",
  [switch]$Runtime,
  [switch]$BuildBase,
  [switch]$Check,
  [switch]$Clean
)

# 原生命令写 stderr（如「镜像不存在」）在 Stop 模式下会变成终止异常，
# 这里改为 Continue，统一用 $LASTEXITCODE 判断，出错时显式 throw。
$ErrorActionPreference = "Continue"
Set-Location -LiteralPath $PSScriptRoot

$script:DockerExe     = (Get-Command docker -ErrorAction Stop).Source
$script:Retries       = 3
$script:GhcrMirror    = if ($env:GHCR_MIRROR) { $env:GHCR_MIRROR } else { "ghcr.nju.edu.cn" }
$script:DaocloudMirror = if ($env:DAOCLOUD_MIRROR) { $env:DAOCLOUD_MIRROR } else { "m.daocloud.io" }

# 换源表：镜像名 -> 优先使用的来源
$script:PullSources = @{
  "oryd/hydra:v26.2.0" = "ghcr.io/openbkn-ai/oryd/hydra:v26.2.0"
}

# 华为云 SWR 上已确认存在的镜像，作为首要来源（国内线路最稳）。
# 只收录实测可用的条目，避免每个镜像都先撞一次 404 再回退。
$script:SwrRegistry = if ($env:SWR_REGISTRY) { $env:SWR_REGISTRY } else { "swr.cn-east-3.myhuaweicloud.com/openbkn-ai" }
$script:SwrSources = @{
  "postgres:16"                                             = "$($script:SwrRegistry)/postgres:16"
  "oryd/hydra:v26.2.0"                                      = "$($script:SwrRegistry)/oryd/hydra:v26.2.0"
  "ghcr.io/openbkn-ai/bitnami/kafka:3.9.0-debian-12-r10"    = "$($script:SwrRegistry)/bitnami/kafka:3.9.0-debian-12-r10"
  "ghcr.io/openbkn-ai/model-factory-base:v2"                = "$($script:SwrRegistry)/model-factory-base:v2"
}

# 一、运行期镜像：compose.yml 里 image: 字段直接引用的（9 个，进交付包）
$script:RuntimeImages = @(
  "alpine:3.20"                                          # config-init 渲染配置
  "mariadb:11.4"                                         # 主数据库
  "postgres:16"                                          # Hydra 的库
  "redis:7.4"                                            # 缓存
  "docker.io/pgsty/silo:RELEASE.2026-10-26T00-00-00Z"    # 对象存储（MinIO 分支）
  "nginx:1.27-alpine"                                    # 网关
  "oryd/hydra:v26.2.0"                                   # OAuth 服务
  "ghcr.io/openbkn-ai/bitnami/kafka:3.9.0-debian-12-r10" # 消息队列
)

# 二、构建期基础镜像：Dockerfile 里 FROM 引用的（10 个，不进交付包）
#     这里必须与各 Dockerfile 的 FROM 默认值逐一对齐，漏一个，
#     package-images.ps1 在构建时就会现拉一次（慢且不可控）。
$script:BuildImages = @(
  "golang:1.26.9"                                        # 8 个 Go 服务的编译环境
  "python:3.12-slim"                                     # bkn-agent
  "python:3.11-slim"                                     # sandbox-control-plane
  "ubuntu:24.04"                                         # bkn-backend / ontology-query / data-migrator / oss-gateway
  "ubuntu:22.04"                                         # agent-retrieval / operator-integration（Dockerfile 里叫 baseImage）
  "node:22-alpine"                                       # studio 前端构建
  "opensearchproject/opensearch:2.19.1"                  # 自建 opensearch 镜像的来源（见 opensearch/Dockerfile）
  "ghcr.io/openbkn-ai/model-factory-base:v2"             # mf-model-api / mf-model-manager（563MB）
  "ghcr.io/openbkn-ai/vega-python-base:0.2.0"            # vega-backend 运行阶段
  "gcr.io/distroless/static-debian12:nonroot"            # agent-observability 运行阶段
)

if ($Runtime -and $BuildBase) { throw "-Runtime 和 -BuildBase 不能同时使用" }
$list = if ($Runtime) { $script:RuntimeImages }
        elseif ($BuildBase) { $script:BuildImages }
        else { $script:RuntimeImages + $script:BuildImages }

$archs = if ($Arch -eq "both") { @("amd64", "arm64") } else { @($Arch) }

function Write-Info([string]$Message) { Write-Host "  $Message" }
function Write-Warn([string]$Message) { Write-Host "  ! $Message" -ForegroundColor Yellow }

# 国内镜像排在最前：直连 gcr.io/ghcr.io 要等 20 秒以上超时才失败，
# 大层镜像中断还要从头下；镜像源实测同一镜像 4 秒 vs 直连 3 秒，
# 快路径优先能省掉大量超时等待。设 DIRECT_FIRST=1 可改回直连优先。
function Get-Candidates {
  param([string]$Image)
  $result = @()
  # 华为云 SWR 优先（仅限实测存在的镜像），其次手工换源表
  if ($script:SwrSources.ContainsKey($Image)) { $result += $script:SwrSources[$Image] }
  if ($script:PullSources.ContainsKey($Image)) { $result += $script:PullSources[$Image] }

  $mirror = ""
  if ($Image -like "gcr.io/*") { $mirror = "$($script:DaocloudMirror)/$Image" }
  elseif ($Image -like "ghcr.io/*") { $mirror = "$($script:GhcrMirror)/" + ($Image -replace "^ghcr\.io/", "") }

  if ($env:DIRECT_FIRST -eq "1") {
    $result += $Image
    if ($mirror) { $result += $mirror }
  }
  else {
    if ($mirror) { $result += $mirror }
    $result += $Image
  }
  return $result | Select-Object -Unique
}

function Invoke-PullOne {
  param([string]$Image, [string]$ArchName)

  foreach ($ref in (Get-Candidates -Image $Image)) {
    Write-Host "    来源: $ref"
    $t0 = Get-Date
    for ($i = 1; $i -le $script:Retries; $i++) {
      # 必须用 Start-Process -NoNewWindow：
      #   1) 函数内的原生命令输出会被收进函数返回值，调用处 if (...) 会整体吞掉；
      #   2) 走 PowerShell 管道时 docker 检测到非 TTY，会把 [==>] 动画进度条
      #      降级成纯文本。
      # Start-Process 让 docker 直接继承控制台，才能看到分层的实时进度。
      $proc = Start-Process -FilePath $script:DockerExe `
        -ArgumentList @('pull', '--platform', "linux/$ArchName", $ref) `
        -NoNewWindow -Wait -PassThru
      if ($proc.ExitCode -eq 0) {
        if ($ref -ne $Image) { docker tag $ref $Image | Out-Null }
        Write-Host ("    ✓ {0}  ({1:N0} 秒)" -f $Image, ((Get-Date) - $t0).TotalSeconds)
        return $true
      }
      if ($i -lt $script:Retries) {
        Write-Warn ("第 {0}/{1} 次失败，10 秒后重试" -f $i, $script:Retries)
        Start-Sleep -Seconds 10
      }
    }
    Write-Warn "✗ $ref 拉取失败"
  }
  return $false
}

function Test-Arch {
  param([string]$ArchName)

  Write-Host ""
  Write-Host "== 核对 linux/$ArchName =="
  $bad = 0
  foreach ($img in $list) {
    $actual = (docker image inspect --platform "linux/$ArchName" --format '{{.Architecture}}' $img 2>$null | Out-String).Trim()
    $sizeText = (docker image inspect --platform "linux/$ArchName" --format '{{.Size}}' $img 2>$null | Out-String).Trim()
    $size = if ($sizeText -match '^\d+$') { [int64]$sizeText } else { 0 }
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($actual)) {
      Write-Host ("  ✗ {0,-58} 缺失" -f $img) -ForegroundColor Red
      $bad++
    }
    elseif ($actual -ne $ArchName) {
      Write-Host ("  ✗ {0,-58} {1}" -f $img, $actual) -ForegroundColor Red
      $bad++
    }
    elseif ($size -lt 1048576) {
      # 只有 manifest/config、没有层：拉取进行中或下载中断留下的残留记录。
      # docker pull 会先登记镜像记录再下载层，所以"能 inspect 到"不等于"能跑"。
      Write-Host ("  ✗ {0,-58} 不完整（{1} 字节，层未下载完）" -f $img, $size) -ForegroundColor Red
      $bad++
    }
    else {
      Write-Host ("  ✓ {0,-58} {1}" -f $img, $actual)
    }
  }
  return ($bad -eq 0)
}

# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------
if ($Clean) {
  Write-Host "== 删除清单内的全部镜像（含两个架构）=="
  foreach ($img in $list) {
    docker image rm -f $img *> $null
    if ($LASTEXITCODE -eq 0) { Write-Info "已删除 $img" }
  }
  Write-Host "完成，可重新执行 .\pull-images.ps1"
  return
}

$status = $true

foreach ($archName in $archs) {
  if ($Check) {
    if (-not (Test-Arch -ArchName $archName)) { $status = $false }
    continue
  }

  Write-Host ""
  Write-Host "== 拉取 linux/$archName（$($list.Count) 个镜像）=="
  $failed = @()
  $idx = 0
  $start = Get-Date
  foreach ($img in $list) {
    $idx++
    # 不用 Write-Progress：它在 PS 5.1 控制台里会抢占同一行，
    # 把 docker 用 \r 刷新的分层下载进度覆盖掉，看起来像卡住不动。
    Write-Host ""
    Write-Host ("[{0}/{1}] {2}" -f $idx, $list.Count, $img)
    if (-not (Invoke-PullOne -Image $img -ArchName $archName)) { $failed += $img }
  }
  Write-Host ""
  Write-Host ("== linux/{0} 结束：成功 {1}，失败 {2}，耗时 {3} 秒 ==" -f `
    $archName, ($list.Count - $failed.Count), $failed.Count, `
    [int]((Get-Date) - $start).TotalSeconds)
  if ($failed.Count -gt 0) {
    Write-Host ""
    Write-Host ("  ✗ {0} 个镜像失败:" -f $failed.Count) -ForegroundColor Red
    $failed | ForEach-Object { Write-Host "      $_" -ForegroundColor Red }
    Write-Host "  可重跑本脚本补拉；若反复卡在同一个镜像，先执行 -Clean" -ForegroundColor Red
    $status = $false
  }
  else {
    Write-Info "linux/$archName 全部就绪"
  }
}

if (-not $status) { exit 1 }

if ($Check) {
  Write-Host "全部镜像在 $($archs -join ', ') 上均已就绪"
}
else {
  Write-Host ""
  Write-Host "下一步: powershell -ExecutionPolicy Bypass -File .\package-images.ps1 -Arch amd64   # 或 arm64 / both"
}
