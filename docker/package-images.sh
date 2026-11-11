#!/usr/bin/env bash
# JiugeBKN —— 镜像打包（按架构构建应用镜像并导出）
#
# 只负责"构建 + 导出"，不拉取镜像。所需镜像请先执行 pull-images.sh。
#
# 用法:
#   bash package-images.sh --arch amd64        # 打 x86 包
#   bash package-images.sh --arch arm64        # 打 ARM 包
#   bash package-images.sh --arch both         # 依次打两个包
#   bash package-images.sh --arch arm64 --list        # 只看清单和本地架构
#   bash package-images.sh --arch arm64 --build-only  # 只构建
#   bash package-images.sh --arch arm64 --save-only   # 只校验并导出
#
# 产物:
#   ../build/jiuge-bkn-images-amd64.tar  + .sha256 + images-amd64.txt
#   ../build/jiuge-bkn-images-arm64.tar  + .sha256 + images-arm64.txt
#
# 镜像 tag:
#   - 包内 tag 与 .env 的 JIUGEBKN_IMAGE_TAG 一致（默认 local），目标机无需改配置。
#   - 打包完成后，应用镜像会额外打上 <tag>-<arch> 标签，
#     例如 jiuge-bkn/bkn-safe:local-amd64 / :local-arm64，
#     这样两套架构可以同时留在本机，互不覆盖。
#   - 第三方镜像（mariadb、postgres 等）本身支持多架构并存，不需要额外处理。
#
# 环境要求:
#   - 目标架构与本机一致时：原生构建，只需 docker + compose 插件。
#   - 目标架构与本机不同时：需要 docker buildx + QEMU 模拟（Docker Desktop 默认具备）。

if [ -z "${BASH_VERSION:-}" ]; then
  if command -v bash >/dev/null 2>&1; then
    exec bash "$0" "$@"
  fi
  echo "请用 bash 运行: bash $0" >&2
  exit 1
fi

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

BUILD_DIR="../build"
OVERRIDE=".compose-arch.override.yml"

# 应用镜像的前缀：这些是本机构建的，需要按架构区分 tag
APP_PREFIX="jiuge-bkn/"

step() { printf '\n== %s ==\n' "$*"; }
info() { printf '  %s\n' "$*"; }
warn() { printf '  ! %s\n' "$*" >&2; }
die()  { printf '\n错误: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 参数
# ---------------------------------------------------------------------------
ARCH_SPEC=""
MODE="all"          # all | list | build | save

while (( $# )); do
  case "$1" in
    --arch)    ARCH_SPEC="${2:-}"; shift 2 ;;
    --list)    MODE="list";  shift ;;
    --build-only) MODE="build"; shift ;;
    --save-only)  MODE="save";  shift ;;
    -h|--help) awk 'NR==1{next} /^# 兼容/{exit} {print}' "$0"; exit 0 ;;
    *) die "未知参数: $1（见 --help）" ;;
  esac
done

[[ -f .env ]] || die "缺少 .env，请先复制 .env.example 为 .env 并填写密码"

# 未指定架构时按本机架构
host_arch=$(docker version --format '{{.Server.Arch}}' 2>/dev/null || uname -m)
case "$host_arch" in
  x86_64|amd64)           host_arch="amd64" ;;
  aarch64|arm64|arm64/v8) host_arch="arm64" ;;
esac

if [[ -z "$ARCH_SPEC" ]]; then
  ARCH_SPEC="$host_arch"
  info "未指定 --arch，按本机架构处理: $ARCH_SPEC"
fi

case "$ARCH_SPEC" in
  amd64|arm64) ARCHS=("$ARCH_SPEC") ;;
  both)        ARCHS=(amd64 arm64) ;;
  *) die "--arch 只支持 amd64 / arm64 / both，收到: $ARCH_SPEC" ;;
esac

# 基础 tag：来自 .env，包内镜像用它命名，目标机不需要改配置
BASE_TAG=$(awk -F= '/^JIUGEBKN_IMAGE_TAG=/{sub(/\r$/,"",$2); print $2; exit}' .env 2>/dev/null || true)
BASE_TAG="${BASE_TAG:-local}"

info "本机架构: $host_arch    目标架构: ${ARCHS[*]}    镜像 tag: $BASE_TAG"

# 交叉构建的环境检查（只在需要时）
for arch in "${ARCHS[@]}"; do
  [[ "$arch" == "$host_arch" ]] && continue
  docker buildx version >/dev/null 2>&1 \
    || die "交叉构建需要 docker buildx 插件（原生构建不需要）"
  platforms=$(docker buildx inspect --bootstrap 2>/dev/null \
    | awk '/^Platforms:/{sub(/^Platforms:[[:space:]]*/,"");print;exit}')
  [[ "$platforms" == *"linux/$arch"* ]] \
    || die "构建器不支持 linux/$arch，请先启用 QEMU 模拟（binfmt / qemu-user-static）"
  warn "linux/$arch 与本机不同，构建走 QEMU 模拟，耗时明显增加"
  break
done

# ---------------------------------------------------------------------------
# 清单
# ---------------------------------------------------------------------------
mapfile -t IMAGES < <(docker compose --env-file .env config --images | sort -u)
(( ${#IMAGES[@]} )) || die "未从 compose 解析到任何镜像"

APP_IMAGES=()
RUNTIME_IMAGES=()
for img in "${IMAGES[@]}"; do
  case "$img" in
    "$APP_PREFIX"*) APP_IMAGES+=("$img") ;;
    *)              RUNTIME_IMAGES+=("$img") ;;
  esac
done
info "共 ${#IMAGES[@]} 个镜像：应用镜像 ${#APP_IMAGES[@]} 个，第三方镜像 ${#RUNTIME_IMAGES[@]} 个"

image_arch() {
  docker image inspect --platform "linux/$1" \
    --format '{{.Architecture}}' "$2" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# 各阶段
# ---------------------------------------------------------------------------
list_arch() {
  local arch="$1" img a size total=0
  step "镜像清单（linux/$arch）"
  for img in "${IMAGES[@]}"; do
    a=$(image_arch "$arch" "$img")
    size=$(docker image inspect --format '{{.Size}}' "$img" 2>/dev/null || echo 0)
    (( size > 0 )) && total=$((total + size))
    printf '  %-58s %-8s %s\n' "$img" "${a:--}" \
      "$( (( size > 0 )) && numfmt --to=iec --suffix=B "$size" 2>/dev/null || echo 缺失 )"
  done
  echo "共 ${#IMAGES[@]} 个镜像，约 $(numfmt --to=iec --suffix=B "$total" 2>/dev/null || echo "$total")（解压后口径）"
  echo "架构列显示 - 表示本地还没有 linux/$arch 版本，先执行 pull-images.sh"
}

write_override() {
  local arch="$1" svc
  mapfile -t services < <(docker compose --env-file .env config --services)
  {
    echo "# 由 package-images.sh 生成，仅用于注入构建平台，退出时自动删除。"
    echo "services:"
    for svc in "${services[@]}"; do
      printf '  %s:\n    platform: linux/%s\n' "$svc" "$arch"
    done
  } > "$OVERRIDE"
}

build_arch() {
  local arch="$1" start=$SECONDS
  step "构建应用镜像（linux/$arch）"
  # 显式指定 tag：保证包内镜像名与 .env 一致，且不受外部环境影响
  JIUGEBKN_IMAGE_TAG="$BASE_TAG" docker compose --env-file .env \
    -f compose.yml -f "$OVERRIDE" build --progress plain \
    || die "构建失败（linux/$arch）"
  info "构建完成，耗时 $(( (SECONDS - start) / 60 )) 分钟"
}

verify_arch() {
  local arch="$1" bad=() img a
  step "校验架构（目标 $arch）"
  for img in "${IMAGES[@]}"; do
    a=$(image_arch "$arch" "$img")
    if [[ -z "$a" ]]; then
      bad+=("$img  （本地没有 linux/$arch 版本）")
    elif [[ "$a" != "$arch" ]]; then
      bad+=("$img  ($a)")
    fi
  done
  if (( ${#bad[@]} )); then
    printf '\n以下镜像不是 %s，导出后无法在目标机运行:\n' "$arch" >&2
    printf '  ✗ %s\n' "${bad[@]}" >&2
    echo "先执行: bash pull-images.sh --arch $arch" >&2
    exit 1
  fi
  info "${#IMAGES[@]} 个镜像全部为 linux/$arch"
}

save_arch() {
  local arch="$1" out="$BUILD_DIR/jiuge-bkn-images-$arch.tar" img a
  step "导出镜像包（linux/$arch）"
  mkdir -p "$BUILD_DIR"

  # 带 --platform：本机可能同时存有同一 tag 的另一个架构，不带会一起导出
  docker save --platform "linux/$arch" -o "$out" "${IMAGES[@]}" \
    || die "docker save 失败"

  {
    printf '%-58s %s\n' "# image" "architecture"
    for img in "${IMAGES[@]}"; do
      printf '%-58s %s\n' "$img" "$(image_arch "$arch" "$img")"
    done
  } > "$BUILD_DIR/images-$arch.txt"

  if command -v sha256sum >/dev/null 2>&1; then
    hash=$(sha256sum "$out" | awk '{print $1}')
  else
    hash=$(shasum -a 256 "$out" | awk '{print $1}')
  fi
  printf '%s  %s\n' "$hash" "$(basename "$out")" > "$out.sha256"

  info "产物: $out"
  ls -lh "$out" | awk '{print "  体积: " $5}'
}

# 给应用镜像加架构后缀 tag，让两套架构在本地并存
retag_arch() {
  local arch="$1" img dst
  step "标注架构标签（$BASE_TAG-$arch）"
  for img in "${APP_IMAGES[@]}"; do
    dst="${img%:*}:$BASE_TAG-$arch"
    docker tag "$img" "$dst"
  done
  info "应用镜像已打上 :$BASE_TAG-$arch，amd64 / arm64 两套可同时保留"
  info "（compose 用的 :$BASE_TAG 仍指向本次构建的架构）"
}

# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------
cleanup() { rm -f "$OVERRIDE"; }
trap cleanup EXIT

for arch in "${ARCHS[@]}"; do
  case "$MODE" in
    list)  list_arch "$arch" ;;
    build) write_override "$arch"; build_arch "$arch" ;;
    save)  verify_arch "$arch"; save_arch "$arch"; retag_arch "$arch" ;;
    all)
      write_override "$arch"
      build_arch "$arch"
      verify_arch "$arch"
      save_arch "$arch"
      retag_arch "$arch"
      ;;
  esac
done

if [[ "$MODE" == "all" || "$MODE" == "save" ]]; then
  step "完成"
  for arch in "${ARCHS[@]}"; do
    echo "  build/jiuge-bkn-images-$arch.tar  → 拷贝到目标机后执行:"
    echo "    bash load-images.sh ../build/jiuge-bkn-images-$arch.tar"
  done
fi
exit 0
