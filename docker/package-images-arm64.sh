#!/usr/bin/env bash
# 打包 JiugeBKN 的 arm64 镜像包，供鲲鹏/飞腾等 ARM 机器离线部署。
#
# 为什么需要单独的脚本:
#   compose.yml 里的镜像名不含任何架构信息，docker load 也不校验架构。
#   在 x86 机器上按默认流程打包，产物是 amd64 的：导入 ARM 机器后能 load、能 up，
#   但容器一启动就 exec format error，runc 返回 255，配合 restart: unless-stopped
#   就是无限重启（日志里只有 exec format error，很容易被当成配置问题）。
#   本脚本固定以 linux/arm64 为目标平台产出，产物名自带架构后缀，不会和 x86 包混淆。
#
# 用法:
#   bash package-images-arm64.sh                 # 全流程：拉取 → 构建 → 校验 → 导出
#   bash package-images-arm64.sh --list          # 只列出镜像清单、当前架构和体积
#   bash package-images-arm64.sh --pull-only     # 只拉第三方镜像
#   bash package-images-arm64.sh --build-only    # 只交叉构建应用镜像
#   bash package-images-arm64.sh --save-only     # 只校验并导出（断点续跑）
#   bash package-images-arm64.sh <输出文件>       # 指定输出路径
#
# 环境变量:
#   SKIP_PULL=1 / SKIP_BUILD=1 / SKIP_SAVE=1     分阶段跳过，可与上面的开关混用
#
# 产物:
#   ../build/jiuge-bkn-images-arm64.tar           镜像包（docker load 可直接导入）
#   ../build/jiuge-bkn-images-arm64.tar.sha256    校验和
#   ../build/images-arm64.txt                     镜像清单（含架构列）
#   ../build/package-arm64.log                    全流程日志
#
# 耗时:
#   在 ARM 机器上执行：原生构建，速度与普通 x86 构建相当（推荐）。
#   在 x86 机器上执行：应用镜像走 QEMU 模拟交叉构建，14 个镜像预计数小时；
#   产物本身就是原生 arm64，部署到 ARM 机器上不存在模拟损耗。

# 兼容被 sh/dash 直接执行：本脚本使用 bash 特性，自动切回 bash。
if [ -z "${BASH_VERSION:-}" ]; then
  if command -v bash >/dev/null 2>&1; then
    exec bash "$0" "$@"
  fi
  echo "请用 bash 运行: sudo bash $0" >&2
  exit 1
fi

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

TARGET_PLATFORM="linux/arm64"
TARGET_ARCH="arm64"

BUILD_DIR="../build"
OUT="$BUILD_DIR/jiuge-bkn-images-arm64.tar"
MANIFEST="$BUILD_DIR/images-arm64.txt"
LOG="$BUILD_DIR/package-arm64.log"
# 构建时临时注入 platform，退出时删除；不进版本库。
OVERRIDE=".compose-arm64.override.yml"

# 第三方镜像换源表：镜像名 -> 实际拉取来源。
# 国内代理不收录的镜像在这里改成项目自己的镜像仓库，拉完再打回原名，
# compose.yml 不需要为此改动。
declare -A PULL_SOURCES=(
  # docker.m.daocloud.io 对该镜像返回 403「不在白名单」，改走组织仓库。
  ["oryd/hydra:v26.2.0"]="ghcr.io/openbkn-ai/oryd/hydra:v26.2.0"
)

# 构建期基础镜像换源表：Dockerfile 里写死、国内又直连不通的镜像。
# 先从代理拉下来、在本地打成原名，BuildKit 会直接从本地镜像存储取用，不再回源。
# （实测：只把镜像放本地不打标签无效，BuildKit 仍会去 gcr.io 解析 tag。）
declare -A BASE_IMAGE_SOURCES=(
  # agent-observability 的运行阶段基础镜像，gcr.io 国内直连超时。
  ["gcr.io/distroless/static-debian12:nonroot"]="m.daocloud.io/gcr.io/distroless/static-debian12:nonroot"
)

# 四个阶段各自独立开关，方便中断后分段续跑。
DO_PULL=1
DO_BUILD=1
DO_VERIFY=1
DO_SAVE=1
LIST_ONLY=0

for arg in "$@"; do
  case "$arg" in
    --list)       LIST_ONLY=1 ;;
    --pull-only)  DO_BUILD=0; DO_VERIFY=0; DO_SAVE=0 ;;
    --build-only) DO_PULL=0; DO_VERIFY=0; DO_SAVE=0 ;;
    --save-only)  DO_PULL=0; DO_BUILD=0 ;;
    -h|--help)    awk 'NR==1{next} /^# 兼容被 sh\/dash/{exit} {print}' "$0"; exit 0 ;;
    -*)           echo "未知参数: $arg（见 --help）" >&2; exit 1 ;;
    *)            OUT="$arg" ;;
  esac
done
[[ "${SKIP_PULL:-0}"  == "1" ]] && DO_PULL=0
[[ "${SKIP_BUILD:-0}" == "1" ]] && DO_BUILD=0
[[ "${SKIP_SAVE:-0}"  == "1" ]] && DO_SAVE=0

step() { printf '\n== %s ==\n' "$*"; }
info() { printf '  %s\n' "$*"; }
warn() { printf '  ! %s\n' "$*" >&2; }
die()  { printf '\n错误: %s\n' "$*" >&2; exit 1; }

mkdir -p "$BUILD_DIR"
# 全流程留痕：QEMU 构建可能跑几个小时，中途断掉要能从日志里看卡在哪。
exec > >(tee -a "$LOG") 2>&1

cleanup() { rm -f "$OVERRIDE"; }
trap cleanup EXIT

# ---------------------------------------------------------------------------
# 第 0 步：环境检查
# ---------------------------------------------------------------------------
step "环境检查"
command -v docker >/dev/null 2>&1 || die "未找到 docker"
docker info >/dev/null 2>&1 || die "无法连接 Docker 守护进程"
[[ -f .env ]] || die "缺少 .env，请先复制 .env.example 为 .env 并填写密码"

host_arch=$(docker version --format '{{.Server.Arch}}' 2>/dev/null || uname -m)
case "$host_arch" in
  x86_64|amd64)           host_arch="amd64" ;;
  aarch64|arm64|arm64/v8) host_arch="arm64" ;;
esac
info "本机架构: $host_arch    目标平台: $TARGET_PLATFORM"

if [[ "$host_arch" == "$TARGET_ARCH" ]]; then
  # 原生 arm64：直接构建，不需要 buildx，也不存在模拟损耗。
  info "本机即 arm64，原生构建，耗时与普通 x86 构建相当"
else
  # 交叉构建：必须有 buildx + QEMU，否则 arm64 的 RUN 步骤跑不起来。
  warn "本机不是 arm64，应用镜像将走 QEMU 模拟交叉构建，预计数小时；产物本身是原生 arm64。"
  docker buildx version >/dev/null 2>&1 \
    || die "交叉构建需要 docker buildx 插件（原生 arm64 机器不需要）"
  platforms=$(docker buildx inspect --bootstrap 2>/dev/null \
    | awk '/^Platforms:/{sub(/^Platforms:[[:space:]]*/,"");print;exit}')
  if [[ "$platforms" != *"$TARGET_PLATFORM"* ]]; then
    die "当前构建器不支持 $TARGET_PLATFORM，请先启用 QEMU 模拟（binfmt / qemu-user-static）"
  fi
fi

# ---------------------------------------------------------------------------
# 第 1 步：解析镜像清单
# ---------------------------------------------------------------------------
step "解析镜像清单"
mapfile -t IMAGES < <(docker compose --env-file .env config --images | sort -u)
(( ${#IMAGES[@]} )) || die "未从 compose 解析到任何镜像"

# 约定：jiuge-bkn/* 是本地构建的应用镜像，其余是可直接拉取的第三方镜像。
APP_IMAGES=()
RUNTIME_IMAGES=()
for img in "${IMAGES[@]}"; do
  case "$img" in
    jiuge-bkn/*) APP_IMAGES+=("$img") ;;
    *)           RUNTIME_IMAGES+=("$img") ;;
  esac
done
info "共 ${#IMAGES[@]} 个镜像：应用镜像 ${#APP_IMAGES[@]} 个，第三方镜像 ${#RUNTIME_IMAGES[@]} 个"

# 取某个镜像的架构；本地没有该平台版本时输出空。
image_arch() {
  docker image inspect --platform "$TARGET_PLATFORM" \
    --format '{{.Architecture}}' "$1" 2>/dev/null || true
}

if (( LIST_ONLY )); then
  total=0
  for img in "${IMAGES[@]}"; do
    size=$(docker image inspect --format '{{.Size}}' "$img" 2>/dev/null || echo 0)
    arch=$(image_arch "$img")
    human="缺失"
    if (( size > 0 )); then
      total=$((total + size))
      human=$(numfmt --to=iec --suffix=B "$size" 2>/dev/null || echo "$size")
    fi
    printf '  %-58s %-8s %s\n' "$img" "${arch:--}" "$human"
  done
  echo "共 ${#IMAGES[@]} 个镜像，约 $(numfmt --to=iec --suffix=B "$total" 2>/dev/null || echo "$total")（解压后口径）"
  echo "架构列显示 - 表示本地还没有 $TARGET_PLATFORM 版本，需要先拉取/构建"
  exit 0
fi

# ---------------------------------------------------------------------------
# 第 2 步：拉取第三方镜像
# ---------------------------------------------------------------------------
pull_runtime() {
  step "拉取第三方镜像（$TARGET_PLATFORM）"
  local failed=() img src
  for img in "${RUNTIME_IMAGES[@]}"; do
    src="${PULL_SOURCES[$img]:-$img}"
    printf '  → %s' "$img"
    if [[ "$src" != "$img" ]]; then
      printf '（来源: %s）' "$src"
    fi
    printf '\n'
    # 不能用 docker compose pull：compose.yml 给运行期镜像设了 pull_policy: never，
    # compose 会直接打印 Skipped 跳过，这一步等于空跑。
    if docker pull --quiet --platform "$TARGET_PLATFORM" "$src"; then
      if [[ "$src" != "$img" ]]; then
        docker tag "$src" "$img"
      fi
    else
      warn "拉取失败: $img"
      failed+=("$img")
    fi
  done
  if (( ${#failed[@]} )); then
    printf '\n以下镜像没有可用的 %s 版本，打包中止:\n' "$TARGET_PLATFORM" >&2
    printf '  ✗ %s\n' "${failed[@]}" >&2
    echo "若是国内代理不收录，请在脚本顶部的 PULL_SOURCES 里补一条换源记录。" >&2
    exit 1
  fi
  info "第三方镜像就绪"
}

# ---------------------------------------------------------------------------
# 第 3 步：交叉构建应用镜像
# ---------------------------------------------------------------------------
write_override() {
  local svc
  {
    echo "# 由 package-images-arm64.sh 生成，仅用于交叉构建，退出时自动删除。"
    echo "services:"
    for svc in "$@"; do
      printf '  %s:\n    platform: %s\n' "$svc" "$TARGET_PLATFORM"
    done
  } > "$OVERRIDE"
}

# Dockerfile 里写死的受限基础镜像（如 gcr.io/distroless）先把 arm64 版本备到本地，
# 否则 BuildKit 解析 FROM 时会直接连 gcr.io，在国内必然超时。
prepare_base_images() {
  step "准备构建期基础镜像"
  local img src
  for img in "${!BASE_IMAGE_SOURCES[@]}"; do
    src="${BASE_IMAGE_SOURCES[$img]}"
    if docker image inspect --platform "$TARGET_PLATFORM" "$img" >/dev/null 2>&1; then
      info "$img 已在本地"
      continue
    fi
    info "预拉 $img"
    info "  ← $src"
    docker pull --quiet --platform "$TARGET_PLATFORM" "$src" \
      || die "预拉失败: $src（可在脚本顶部 BASE_IMAGE_SOURCES 里换源）"
    docker tag "$src" "$img"
  done
}

build_app_images() {
  step "交叉构建应用镜像（$TARGET_PLATFORM）"
  prepare_base_images

  # 从 dry-run 的 "naming to" 行取出真正带 build 段的服务，避免手写服务名列表。
  local services=()
  mapfile -t services < <(
    docker compose --env-file .env --dry-run build 2>/dev/null \
      | awk -F' ==> ' '/naming to /{gsub(/^ +/,"",$1); print $1}' | sort -u
  )
  if (( ${#services[@]} == 0 )); then
    warn "未能从 dry-run 识别可构建服务，退化为对所有服务注入 platform"
    mapfile -t services < <(docker compose --env-file .env config --services)
  fi
  info "待构建 ${#services[@]} 个服务: ${services[*]}"
  write_override "${services[@]}"

  local start=$SECONDS
  # compose 只把 platform 传给带 build 的服务；第三方镜像不会被重拉。
  if ! docker compose --env-file .env \
        -f compose.yml -f "$OVERRIDE" \
        build --progress plain; then
    printf '\n构建失败，完整输出见 %s\n' "$LOG" >&2
    echo "可先用单服务冒烟定位:" >&2
    echo "  docker compose --env-file .env -f compose.yml -f $OVERRIDE build <服务名>" >&2
    exit 1
  fi
  info "构建完成，耗时 $(( (SECONDS - start) / 60 )) 分钟"
}

# ---------------------------------------------------------------------------
# 第 4 步：架构校验
# ---------------------------------------------------------------------------
verify_arch() {
  step "校验镜像架构（目标 $TARGET_ARCH）"
  local bad=() img arch
  for img in "${IMAGES[@]}"; do
    # 必须带 --platform：containerd 镜像存储下同一 tag 可能同时存在多架构，
    # 不带该参数会拿到宿主机架构那一份，校验会误判。
    arch=$(image_arch "$img")
    if [[ -z "$arch" ]]; then
      bad+=("$img  （本地没有 $TARGET_ARCH 版本）")
    elif [[ "$arch" != "$TARGET_ARCH" ]]; then
      bad+=("$img  ($arch)")
    fi
  done
  if (( ${#bad[@]} )); then
    printf '\n以下镜像不是 %s，继续导出会在 ARM 机器上 exec format error:\n' "$TARGET_ARCH" >&2
    printf '  ✗ %s\n' "${bad[@]}" >&2
    echo "请先执行 --pull-only / --build-only 补齐。" >&2
    exit 1
  fi
  info "${#IMAGES[@]} 个镜像全部为 $TARGET_PLATFORM"
}

# ---------------------------------------------------------------------------
# 第 5 步：导出
# ---------------------------------------------------------------------------
save_images() {
  step "导出镜像包"
  mkdir -p "$(dirname "$OUT")"

  # 带 --platform：本机可能同时存有同名 tag 的 amd64 版本，
  # 不带会把两套架构一起导出，包体翻倍且导入端选哪份不确定。
  docker save --platform "$TARGET_PLATFORM" -o "$OUT" "${IMAGES[@]}"

  {
    printf '%-58s %s\n' "# image" "architecture"
    for img in "${IMAGES[@]}"; do
      printf '%-58s %s\n' "$img" "$(image_arch "$img")"
    done
  } > "$MANIFEST"

  if command -v sha256sum >/dev/null 2>&1; then
    file_hash=$(sha256sum "$OUT" | awk '{print $1}')
  else
    file_hash=$(shasum -a 256 "$OUT" | awk '{print $1}')
  fi
  printf '%s  %s\n' "$file_hash" "$(basename "$OUT")" > "$OUT.sha256"

  step "完成"
  ls -lh "$OUT"
  echo "把 $OUT、$OUT.sha256、images-arm64.txt 与本目录一起拷贝到 ARM 机器，"
  echo "在 ARM 机器上执行: bash load-images.sh $(basename "$OUT")"
}

# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------
if (( DO_PULL ));   then pull_runtime;   fi
if (( DO_BUILD ));  then build_app_images; fi
if (( DO_VERIFY )); then verify_arch;    fi
if (( DO_SAVE ));   then save_images;    fi
exit 0
