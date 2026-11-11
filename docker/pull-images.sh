#!/usr/bin/env bash
# JiugeBKN —— 镜像拉取（amd64 / arm64 并存）
#
# 只负责"拉取"，不构建、不导出。构建与导出见 package-images.sh。
#
# 用法:
#   bash pull-images.sh                      # 拉 amd64 + arm64 全部（17 个镜像 × 2）
#   bash pull-images.sh --arch arm64         # 只拉 arm64
#   bash pull-images.sh --arch amd64 --runtime
#   bash pull-images.sh --arch both --build
#   bash pull-images.sh --check --arch arm64 # 只核对本地架构，不拉取
#   bash pull-images.sh --clean              # 删除清单里的全部镜像（修复损坏记录用）
#
# 拉取策略（国内环境，有代理）:
#   1. 先按镜像原名直连（Docker Desktop 配了代理时会自动走代理）
#   2. 失败再依次尝试国内镜像源：
#        gcr.io/xxx  -> m.daocloud.io/gcr.io/xxx
#        ghcr.io/xxx -> ghcr.nju.edu.cn/xxx
#     拉下来后自动 tag 回原名，compose.yml 不需要改。
#
# 说明:
#   - 拉取的镜像天然支持多架构并存，amd64 和 arm64 互不覆盖。
#   - 单个镜像失败会重试 3 次；仍失败会打印清理提示。
#   - 下载中断会留下"镜像记录存在但缺层"的损坏状态，重试会一直卡住，
#     此时用 --clean 清空后重拉。

if [ -z "${BASH_VERSION:-}" ]; then
  if command -v bash >/dev/null 2>&1; then
    exec bash "$0" "$@"
  fi
  echo "请用 bash 运行: bash $0" >&2
  exit 1
fi

set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

RETRIES=3
# 国内镜像源，可用环境变量覆盖
GHCR_MIRROR="${GHCR_MIRROR:-ghcr.nju.edu.cn}"
DAOCLOUD_MIRROR="${DAOCLOUD_MIRROR:-m.daocloud.io}"

# 换源表：镜像名 -> 优先使用的来源（国内代理不收录的镜像走项目自己的仓库）
declare -A PULL_SOURCES=(
  # docker.m.daocloud.io 对该镜像返回 403「不在白名单」
  ["oryd/hydra:v26.2.0"]="ghcr.io/openbkn-ai/oryd/hydra:v26.2.0"
)

# ---------------------------------------------------------------------------
# 清单
# ---------------------------------------------------------------------------

# 一、运行期镜像：compose.yml 里 image: 字段直接引用的（9 个，进交付包）
RUNTIME_IMAGES=(
  "alpine:3.20"                                          # config-init 渲染配置
  "mariadb:11.4"                                         # 主数据库
  "postgres:16"                                          # Hydra 的库
  "redis:7.4"                                            # 缓存
  "opensearchproject/opensearch:2.19.1"                  # 搜索引擎
  "docker.io/pgsty/silo:RELEASE.2026-10-26T00-00-00Z"    # 对象存储（MinIO 分支）
  "nginx:1.27-alpine"                                    # 网关
  "oryd/hydra:v26.2.0"                                   # OAuth 服务
  "ghcr.io/openbkn-ai/bitnami/kafka:3.9.0-debian-12-r10" # 消息队列
)

# 二、构建期基础镜像：Dockerfile 里 FROM 引用的（8 个，不进交付包）
BUILD_IMAGES=(
  "golang:1.26.9"                                        # 8 个 Go 服务的编译环境
  "python:3.12-slim"                                     # bkn-agent
  "python:3.11-slim"                                     # sandbox-control-plane
  "ubuntu:24.04"                                         # bkn-backend / data-migrator / oss-gateway
  "node:22-alpine"                                       # studio 前端构建
  "ghcr.io/openbkn-ai/model-factory-base:v2"             # mf-model-api / mf-model-manager（563MB）
  "ghcr.io/openbkn-ai/vega-python-base:0.2.0"            # vega-backend 运行阶段
  "gcr.io/distroless/static-debian12:nonroot"            # agent-observability 运行阶段
)

ALL_IMAGES=("${RUNTIME_IMAGES[@]}" "${BUILD_IMAGES[@]}")

# ---------------------------------------------------------------------------
# 参数
# ---------------------------------------------------------------------------
MODE="pull"          # pull | check | clean
SCOPE="all"          # all | runtime | build
ARCHS=()

for arg in "$@"; do
  case "$arg" in
    --arch)
      ;;
    amd64|arm64)
      ARCHS+=("$arg") ;;
    both)
      ARCHS=(amd64 arm64) ;;
    --runtime) MODE="pull"; SCOPE="runtime" ;;
    --build)   MODE="pull"; SCOPE="build" ;;
    --check)   MODE="check" ;;
    --clean)   MODE="clean" ;;
    -h|--help) awk 'NR==1{next} /^# 兼容/{exit} {print}' "$0"; exit 0 ;;
    *) echo "未知参数: $arg（见 --help）" >&2; exit 1 ;;
  esac
done

# 未指定架构时：默认两个都拉
(( ${#ARCHS[@]} )) || ARCHS=(amd64 arm64)

case "$SCOPE" in
  runtime) LIST=("${RUNTIME_IMAGES[@]}") ;;
  build)   LIST=("${BUILD_IMAGES[@]}") ;;
  *)       LIST=("${ALL_IMAGES[@]}") ;;
esac

info() { printf '  %s\n' "$*"; }
warn() { printf '  ! %s\n' "$*" >&2; }

# ---------------------------------------------------------------------------
# 实现
# ---------------------------------------------------------------------------

# 按优先级列出候选来源
candidates() {
  local img="$1"
  {
    [[ -n "${PULL_SOURCES[$img]:-}" ]] && printf '%s\n' "${PULL_SOURCES[$img]}"
    printf '%s\n' "$img"
    case "$img" in
      gcr.io/*)  printf '%s/%s\n' "$DAOCLOUD_MIRROR" "$img" ;;
      ghcr.io/*) printf '%s/%s\n' "$GHCR_MIRROR" "${img#ghcr.io/}" ;;
    esac
  } | awk '!seen[$0]++'
}

pull_one() {
  local img="$1" arch="$2" ref i t0=$SECONDS
  while IFS= read -r ref; do
    printf '    来源: %s\n' "$ref"
    for i in $(seq 1 "$RETRIES"); do
      # 不加 --quiet：让 docker 显示分层下载进度，大镜像才看得出是否在动
      if docker pull --platform "linux/$arch" "$ref"; then
        if [[ "$ref" != "$img" ]]; then
          docker tag "$ref" "$img"
        fi
        printf '    ✓ %s  (%d 秒)\n' "$img" "$(( SECONDS - t0 ))"
        return 0
      fi
      if (( i < RETRIES )); then
        warn "第 $i/$RETRIES 次失败，10 秒后重试"
        sleep 10
      fi
    done
    warn "✗ $ref 拉取失败"
  done < <(candidates "$img")
  return 1
}

pull_arch() {
  local arch="$1" failed=() img idx=0 total=${#LIST[@]} start=$SECONDS
  printf '\n== 拉取 linux/%s（%d 个镜像）==\n' "$arch" "$total"
  for img in "${LIST[@]}"; do
    idx=$(( idx + 1 ))
    printf '\n[%d/%d] %s\n' "$idx" "$total" "$img"
    pull_one "$img" "$arch" || failed+=("$img")
  done
  printf '\n== linux/%s 结束：成功 %d，失败 %d，耗时 %d 秒 ==\n' \
    "$arch" "$(( total - ${#failed[@]} ))" "${#failed[@]}" "$(( SECONDS - start ))"
  if (( ${#failed[@]} )); then
    printf '  ✗ 失败的镜像:\n' >&2
    printf '      %s\n' "${failed[@]}" >&2
    echo "  可重跑本脚本补拉；若反复卡在同一个镜像，先执行: bash pull-images.sh --clean" >&2
    return 1
  fi
  info "linux/$arch 全部就绪"
}

check_arch() {
  local arch="$1" bad=0 img a
  printf '\n== 核对 linux/%s ==\n' "$arch"
  for img in "${LIST[@]}"; do
    a=$(docker image inspect --platform "linux/$arch" \
          --format '{{.Architecture}}' "$img" 2>/dev/null || true)
    if [[ "$a" == "$arch" ]]; then
      printf '  ✓ %-58s %s\n' "$img" "$a"
    else
      printf '  ✗ %-58s %s\n' "$img" "${a:-缺失}" >&2
      bad=1
    fi
  done
  return $bad
}

# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------
case "$MODE" in
  clean)
    echo "== 删除清单内的全部镜像（含两个架构）=="
    for img in "${LIST[@]}"; do
      docker image rm -f "$img" >/dev/null 2>&1 && info "已删除 $img"
    done
    echo "完成，可重新执行 bash pull-images.sh"
    ;;

  check)
    status=0
    for arch in "${ARCHS[@]}"; do
      check_arch "$arch" || status=1
    done
    (( status == 0 )) && echo "全部镜像在 ${ARCHS[*]} 上均已就绪" \
                      || { echo "有镜像缺失或架构不符" >&2; exit 1; }
    ;;

  pull)
    status=0
    for arch in "${ARCHS[@]}"; do
      pull_arch "$arch" || status=1
    done
    if (( status == 0 )); then
      echo
      echo "下一步: bash package-images.sh --arch amd64   # 或 arm64 / both"
    else
      exit 1
    fi
    ;;
esac
