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
#   tag 直接等于架构名，例如 jiuge-bkn/bkn-safe:amd64 / :arm64。
#   两个 tag 天然并存，不会出现"后一次构建覆盖前一次"的问题。
#
#   ⚠ 目标机部署时必须在 .env 里设置对应的值：
#       JIUGEBKN_IMAGE_TAG=amd64    # 用 x86 包
#       JIUGEBKN_IMAGE_TAG=arm64    # 用 ARM 包
#   与拿到的镜像包不一致时，compose 会找不到镜像。
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

# 镜像 tag 直接等于架构名：jiuge-bkn/<服务>:amd64 / :arm64。
# 两个 tag 天然并存，不再需要 <tag>-<arch> 那种额外标签，
# 也不会出现"最后一次构建把 :local 覆盖掉"的问题。
# 目标机在 .env 里写 JIUGEBKN_IMAGE_TAG=<架构> 即可。
info "本机架构: $host_arch    目标架构: ${ARCHS[*]}    镜像 tag: <架构名>"

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
# 按架构解析镜像清单：compose 通过 JIUGEBKN_IMAGE_TAG 拼出镜像名，
# 所以每个架构都要重新解析一次，得到的才是 :amd64 / :arm64。
compute_images() {
  local arch="$1"
  export JIUGEBKN_IMAGE_TAG="$arch"
  mapfile -t IMAGES < <(docker compose --env-file .env config --images | sort -u)
  (( ${#IMAGES[@]} )) || die "未从 compose 解析到任何镜像（arch=$arch）"

  APP_IMAGES=()
  RUNTIME_IMAGES=()
  local img
  for img in "${IMAGES[@]}"; do
    case "$img" in
      "$APP_PREFIX"*) APP_IMAGES+=("$img") ;;
      *)              RUNTIME_IMAGES+=("$img") ;;
    esac
  done
  info "linux/$arch：共 ${#IMAGES[@]} 个镜像（应用 ${#APP_IMAGES[@]}，第三方 ${#RUNTIME_IMAGES[@]}）"
}

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
  # JIUGEBKN_IMAGE_TAG 已由 compute_images 导出为架构名，
  # 产物直接是 jiuge-bkn/<服务>:amd64 或 :arm64
  JIUGEBKN_IMAGE_TAG="$arch" docker compose --env-file .env \
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

# 目标机 .env 需要与包内 tag 一致，导出后提示一次
remind_env_tag() {
  local arch="$1"
  info "目标机 .env 需设置: JIUGEBKN_IMAGE_TAG=$arch"
}

# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------
cleanup() { rm -f "$OVERRIDE"; }
trap cleanup EXIT

for arch in "${ARCHS[@]}"; do
  compute_images "$arch"
  case "$MODE" in
    list)  list_arch "$arch" ;;
    build) write_override "$arch"; build_arch "$arch" ;;
    save)  verify_arch "$arch"; save_arch "$arch"; remind_env_tag "$arch" ;;
    all)
      write_override "$arch"
      build_arch "$arch"
      verify_arch "$arch"
      save_arch "$arch"
      remind_env_tag "$arch"
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
