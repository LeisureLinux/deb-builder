#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.." || exit 1

PKG_NAME="${1:?Usage: bash scripts/build-go-deb.sh <package-name> [archs_csv] [binary_path]}"
ARCHS_CSV="${2:-}"
BINARY_PATH="${3:-}"

RECIPE="$(pwd)/recipes/${PKG_NAME}.yaml"
if [[ ! -f "$RECIPE" ]]; then
  echo "❌ Recipe not found: $RECIPE" >&2
  exit 1
fi

OUTPUT_DIR="$(pwd)/dist"
mkdir -p "$OUTPUT_DIR"

# 临时构建区：默认 /tmp；BUILD_TMPDIR 可覆盖（/tmp 是 tmpfs 且偏小时有用，
# 某些精简容器里 /tmp 上做 git 克隆还会出现"克隆成功但检出失败"）。
TMPBASE="${BUILD_TMPDIR:-/tmp}"
mkdir -p "$TMPBASE" 2>/dev/null || true

# 立刻转成绝对路径。脚本后面会 cd 进源码树，所有以 TMPBASE 为前缀的路径
# （源码树、构建目录、TMPDIR）都必须与当前工作目录无关，否则会解析到源码树内部去。
TMPBASE="$( cd "$TMPBASE" 2>/dev/null && pwd )" || TMPBASE="${BUILD_TMPDIR:-/tmp}"

# 工具链的临时目录也指到 TMPBASE。
# 有的构建机 /tmp 是小容量 tmpfs（本仓库构建机就只有一个 10MB 的 /tmp），
# 而 go 编译时的 $WORK、git 的部分中间文件都落在 TMPDIR 里，
# 空间不够时会以 "no space left on device" 这种和真实原因无关的方式失败。
# 统一成一处配置：改 BUILD_TMPDIR 就能同时管住源码树和工具链临时目录。
export TMPDIR="$TMPBASE"

# 空间自检：临时区太小就说清楚，别等编译到一半才报怪错
_tmp_avail_kb="$(df -Pk "$TMPBASE" 2>/dev/null | awk 'NR==2{print $4}')"
if [[ -n "$_tmp_avail_kb" ]] && (( _tmp_avail_kb < 2*1024*1024 )); then
  echo "⚠️  临时区 $TMPBASE 可用空间仅 $(( _tmp_avail_kb / 1024 )) MiB，构建很可能失败" >&2
  echo "    建议: BUILD_TMPDIR=<有足够空间的目录> bash scripts/build-one.sh <包名>" >&2
fi
unset _tmp_avail_kb

# --- Parse recipe fields ---
repo_line=$(grep '^repo:' "$RECIPE" | awk '{print $2}' | tr -d '"' | tr -d "'" || true)
if [[ -z "$repo_line" ]]; then
  echo "❌ Missing 'repo:' in $RECIPE" >&2
  exit 1
fi

HOMEPAGE=$(grep '^homepage:' "$RECIPE" | sed 's/^homepage:[ ]*//' | tr -d '"' || true)

UPGRADE_VERSION_RAW=$(grep '^upstream_version:' "$RECIPE" 2>/dev/null | head -n1 || true)
if [[ -z "$UPGRADE_VERSION_RAW" ]]; then
  UPGRADE_VERSION="0.0.1"
else
  UPGRADE_VERSION=$(echo "$UPGRADE_VERSION_RAW" | sed 's/^upstream_version:[ ]*//' | tr -d '"' | sed 's/^v//')
fi

VERSION_RAW=$(grep '^latest_tag:' "$RECIPE" 2>/dev/null | head -n1 || true)
if [[ -n "$VERSION_RAW" ]]; then
  VERSION=$(echo "$VERSION_RAW" | sed 's/^latest_tag:[ ]*//' | tr -d '"' | sed 's/^v//')
else
  VERSION="${UPGRADE_VERSION}"
fi

# build_path (optional, default ".")
BUILD_PATH=$(grep '^build_path:' "$RECIPE" 2>/dev/null | head -n1 | sed 's/^build_path:[ ]*//' | tr -d '"' || true)
BUILD_PATH="${BUILD_PATH:-.}"

COMMIT_HASH=$(grep '^commit_hash:' "$RECIPE" 2>/dev/null | awk '{print $2}' | tr -d '"' || true)
LDFLAGS=$(grep '^ldflags:' "$RECIPE" 2>/dev/null | sed 's/^ldflags:[ ]*//' | tr -d '"' || true)
MAINTAINER=$(grep '^maintainer:' "$RECIPE" 2>/dev/null | sed 's/^maintainer:[ ]*//' | tr -d '"' || true)
MAINTAINER="${MAINTAINER:-LeisureLinux <albertxu@freelamp.com>}"
SECTION=$(grep '^section:' "$RECIPE" 2>/dev/null | sed 's/^section:[ ]*//' | tr -d '"' || true)
SECTION="${SECTION:-utils}"

# binary_name: 安装到 /usr/bin/ 下的名字（默认 = 包名）。
# 例：opensnitch 的守护进程在源码里叫 opensnitchd，systemd unit 也按此名字调用。
BINARY_NAME=$(grep '^binary_name:' "$RECIPE" 2>/dev/null | head -n1 | sed 's/^binary_name:[[:space:]]*//' | tr -d '"' || true)
BINARY_NAME="${BINARY_NAME:-$PKG_NAME}"

# 解析 YAML 列表字段（支持块列表 "- item" 与内联 "[a, b]" 两种写法），输出逗号分隔串
parse_list_field() {
  local field="$1" raw="" inline=""
  grep -q "^${field}:" "$RECIPE" || { printf ''; return; }
  # 块列表：字段行之后、缩进的 "- xxx" 行；遇到顶格新键即结束。
  # （注意 YAML 列表项有缩进，正则必须容忍前导空格）
  raw=$(awk -v f="$field" '
    $0 ~ "^"f":"        {flag=1; next}
    flag && /^[^[:space:]]/ {exit}
    flag && /^[[:space:]]*-[[:space:]]*/ {
      sub(/^[[:space:]]*-[[:space:]]*/, ""); gsub(/"/, ""); sub(/[[:space:]]+$/, "")
      printf "%s,", $0
    }
  ' "$RECIPE")
  inline=$(grep "^${field}:" "$RECIPE" | head -n1 | sed "s/^${field}:[[:space:]]*//" | tr -d '"' || true)
  if [[ "$inline" == \[*\]* ]]; then
    inline="${inline#\[}"; inline="${inline%\]}"
    inline=$(echo "$inline" | tr ',' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -v '^$' | paste -sd, - || true)
    [[ -n "$inline" ]] && raw="$inline"
  fi
  printf '%s' "${raw%,}"
}

RECOMMENDS=$(parse_list_field recommends)
SUGGESTS=$(parse_list_field suggests)
# suites: 限定本包只发布到哪些发行版（apt-repo/conf/distros.txt 里的 codename，逗号分隔）。
# 留空 = 全发行版。会写进 control 的 XB-Suites 字段，由 apt-repo 的 publish.sh 分流。
# 用途：有些包只在较新的发行版可用（例如 opensnitch 的界面依赖 PyQt6，只有 trixie 起才有）。
SUITES=$(parse_list_field suites)

# extra_root: 一个目录树（repo 内相对路径），内容按原样叠加进包根。
#   用于放置需要随配方维护的静态文件（systemd unit / init.d / logrotate 等）。
EXTRA_ROOT=$(grep '^extra_root:' "$RECIPE" 2>/dev/null | head -n1 | sed 's/^extra_root:[[:space:]]*//' | tr -d '"' || true)
# control_dir: 一个目录（repo 内相对路径），内容复制进 DEBIAN/（postinst/prerm/postrm/conffiles…）。
CONTROL_DIR=$(grep '^control_dir:' "$RECIPE" 2>/dev/null | head -n1 | sed 's/^control_dir:[[:space:]]*//' | tr -d '"' || true)
# build_script: 非 Go 包的自定义构建逃生舱（见下方校验）。
BUILD_SCRIPT=$(grep '^build_script:' "$RECIPE" 2>/dev/null | head -n1 | sed 's/^build_script:[[:space:]]*//' | tr -d '"' || true)

# extra_root / control_dir 是"相对仓库根"的路径，但脚本后面会 cd 进源码树、
# 甚至 cd 进 nested module（如 opensnitch 的 daemon/）。在基准还正确的时候
# 就把它们转成绝对路径，否则会解析到源码树里面去，结果是静默跳过。
_abs_from_repo_root() {
  local p="$1"
  [[ -z "$p" ]] && { printf ''; return; }
  [[ "$p" == /* ]] && { printf '%s' "$p"; return; }
  printf '%s/%s' "$(pwd)" "${p#./}"
}
EXTRA_ROOT="$(_abs_from_repo_root "$EXTRA_ROOT")"
CONTROL_DIR="$(_abs_from_repo_root "$CONTROL_DIR")"
BUILD_SCRIPT="$(_abs_from_repo_root "$BUILD_SCRIPT")"

# depends：支持块列表（- item）与内联列表（[a, b]）两种格式；
# 为空则不写 Depends 字段（Depends 可选，写成 "none" 会导致安装失败）
DEPENDS=$(parse_list_field depends)

GITDATE="$(date +%Y%m%d)"
SHORT_SHA="unknown"
if [[ -n "$COMMIT_HASH" ]]; then
  SHORT_SHA="${COMMIT_HASH:0:7}"
fi

BUILD_NUMBER="${BUILD_NUMBER:-1}"
if (( BUILD_NUMBER <= 1 )); then
  FINAL_VERSION="${UPGRADE_VERSION}+LL"
else
  FINAL_VERSION="${UPGRADE_VERSION}+LL-${BUILD_NUMBER}"
fi

# 注意：CI 当前仅构建 amd64+arm64（见 receive-trigger.yml / build.yml 的 ARCHS_OVERRIDE）。
# loong64/riscv64 临时禁用，但 recipe 的 target_arches 仍保留其声明（已注释），后续可启用。
# --- Determine target arches (from $2, else recipe target_arches, else amd64) ---
if [[ -z "$ARCHS_CSV" ]]; then
  ARCHS_CSV=$(awk '/^target_arches:/{flag=1; next} /^[^[:space:]]/ && flag{exit} flag && /^[[:space:]]*- /{sub(/^[[:space:]]*- /,""); print $1}' "$RECIPE" | paste -sd, -)
fi
if [[ -z "$ARCHS_CSV" ]]; then
  ARCHS_CSV="amd64"
fi

# 架构声明取交集：recipe 的 target_arches 表达包本身支持的范围，
# 外部传入的列表（CI 发布范围）与其求交，避免对不支持的架构白费构建。
#
# 这一步必须排在 build_script 分支**之前**。CI 现在按架构拆到多台 runner，
# 每台只构建自己那一个架构，"这个包支持哪些架构"得先判定完 ——
# 否则 arch:all 的包（如 python3-opensnitch-ui）会在两台 runner 上各产出一份
# **同名** .deb，artifact 合并时就撞车了。
RECIPE_ARCHES=$(awk '/^target_arches:/{flag=1; next} /^[^[:space:]]/ && flag{exit} flag && /^[[:space:]]*- /{sub(/^[[:space:]]*- /,""); print $1}' "$RECIPE" | paste -sd, -)
if [[ -n "$RECIPE_ARCHES" ]]; then
  FILTERED=""
  IFS=',' read -ra WANT <<< "$ARCHS_CSV"
  IFS=',' read -ra ALLOWED <<< "$RECIPE_ARCHES"
  for w in "${WANT[@]}"; do
    w="$(echo "$w" | tr -d ' ')"
    [[ -z "$w" ]] && continue
    for a in "${ALLOWED[@]}"; do
      if [[ "$w" == "$a" ]]; then FILTERED="${FILTERED:+$FILTERED,}$w"; break; fi
    done
  done
  if [[ -z "$FILTERED" ]]; then
    # 该包在你请求的架构上本就不支持（或 arch:all 已由别的架构负责），
    # 按"跳过"处理而不是失败：exit 2 与"已禁用/无 recipe"同义，CI 视为干净跳过。
    echo "⏭️  ${PKG_NAME}: 请求的架构（$ARCHS_CSV）不在 target_arches（$RECIPE_ARCHES）内，跳过" >&2
    exit 2
  fi
  if [[ "$FILTERED" != "$ARCHS_CSV" ]]; then
    echo "ℹ️  Intersected with recipe target_arches ($RECIPE_ARCHES): $FILTERED" >&2
    ARCHS_CSV="$FILTERED"
  fi
fi

# --- 非 Go 包逃生舱 ---------------------------------------------------------
# recipe 声明 build_script 时，把构建完全交给该脚本（Python / C / eBPF 等）。
# 脚本负责：克隆源码、构建、在 $OUTPUT_DIR 下产出 <包名>_<版本>_<架构>.deb。
# 这样 200+ 个既有 Go recipe 的路径完全不受影响，非 Go 包也不必塞进 Go 逻辑里。
if [[ -n "$BUILD_SCRIPT" ]]; then
  if [[ ! -f "$BUILD_SCRIPT" ]]; then
    echo "❌ build_script not found: $BUILD_SCRIPT" >&2
    exit 1
  fi
  echo "🧩 build_script mode: ${PKG_NAME} v${VERSION} (final: ${FINAL_VERSION}), arches=${ARCHS_CSV}" >&2
  export PKG_NAME VERSION FINAL_VERSION ARCHS_CSV OUTPUT_DIR RECIPE \
         REPO_LINE="$repo_line" UPGRADE_VERSION SECTION MAINTAINER \
         BINARY_NAME RECOMMENDS SUGGESTS SUITES EXTRA_ROOT CONTROL_DIR HOMEPAGE \
         DEPENDS COMMIT_HASH LDFLAGS TMPBASE
  exec bash "$BUILD_SCRIPT"
fi

declare -a ARCH_LIST=()
# 用 for + 逗号转空格切分（而不是 process substitution：某些精简容器/chroot 里
# 没有 /dev/fd，`< <(...)` 会直接失败）
for a in $(echo "$ARCHS_CSV" | tr ',' ' '); do
  [[ -z "$a" ]] && continue
  case "$a" in
    loongarch64) a=loong64 ;;
    armhf) a=armhf ;;
  esac
  ARCH_LIST+=("$a")
done

echo "📦 Building ${PKG_NAME} v${VERSION} (final: ${FINAL_VERSION})" >&2
echo "🏗️  Target architectures: ${ARCH_LIST[*]}" >&2

# --- Clone via HTTPS (works in CI without SSH keys) ---
TIMESTAMP="$(date +%Y%m%d%H%M%S)"
SOURCE_DIR="${TMPBASE}/${PKG_NAME}-src-${TIMESTAMP}"
rm -rf "$SOURCE_DIR"
mkdir -p "$SOURCE_DIR"

# 构建结束（成功或失败）清理临时目录：源码克隆 + 各架构构建前缀。
# 否则全量构建时 166+ 个包的克隆目录会累积撑爆 tmpfs（/tmp 多为 tmpfs）。
cleanup_tmp() {
  rm -rf "${SOURCE_DIR:-}" "${TMPBASE}/build-${PKG_NAME:-}"-*-"${TIMESTAMP:-}" 2>/dev/null || true
}
trap cleanup_tmp EXIT
echo "🔄 Cloning https://github.com/${repo_line}.git ..." >&2
# 克隆重试 3 次（网络抖动容错）
clone_ok=0
for attempt in 1 2 3; do
  if git clone --depth 1 "https://github.com/${repo_line}.git" "$SOURCE_DIR" 2>/dev/null; then
    clone_ok=1
    break
  fi
  echo "⚠️  Clone attempt $attempt failed; retrying..." >&2
  rm -rf "$SOURCE_DIR"; mkdir -p "$SOURCE_DIR"
  sleep 5
done
if (( clone_ok == 0 )); then
  echo "❌ Failed to clone https://github.com/${repo_line}.git after 3 attempts" >&2
  exit 1
fi

cd "$SOURCE_DIR"
if [[ -n "$COMMIT_HASH" ]]; then
  echo "🔖 Fetching & checking out ${COMMIT_HASH}" >&2
  git fetch --depth 1 origin "$COMMIT_HASH"
  git checkout "$COMMIT_HASH"
fi

# 克隆完整性自检：某些构建机上会出现"克隆成功但检出失败"——git 退出码是 0，
# 但工作树里只有 .git。不检查的话，后面所有步骤都会以各种奇怪的方式失败。
if ! ls -A | grep -qv '^\.git$'; then
  echo "❌ clone 后工作树为空（检出失败）: $SOURCE_DIR" >&2
  exit 1
fi

# Go 模块策略：构建机的 `go env -w` 可能把 GO111MODULE 设成 off（本仓库的构建机就是），
# Go 1.16+ 下这等于禁用模块，`go install pkg@version`、`go mod tidy`、`go get` 全部失败。
# 本仓库的 Go 构建一律基于模块（没有 go.mod 的包也会走 go mod init），所以这里显式打开。
export GO111MODULE=on

# 模块代理：不设默认值时，Go 会走构建机的配置（本仓库构建机是 GOPROXY=direct），
# 而 direct 模式对 google.golang.org/* 需要先请求其 ?go-get=1 元数据，该域名在
# 国内网络下不通（实测 Bad Gateway），会让所有 go install / go mod tidy 失败。
# 这里给一条可用链路，仍可用环境变量覆盖：
#   GOPROXY=https://my.proxy bash scripts/build-one.sh <pkg>
export GOPROXY="${GOPROXY:-https://goproxy.cn,direct}"

# 可选的构建前钩子（如生成 embed 资源）；命令在源码根目录执行，无论是否有 go.mod 都运行
# 确保 go install 安装的工具（protoc-gen-go 等）对钩子可见
export PATH="$PATH:$(go env GOPATH 2>/dev/null)/bin"
PRE_BUILD=$(grep '^pre_build:' "$RECIPE" 2>/dev/null | head -n1 | sed 's/^pre_build:[[:space:]]*//' || true)
# 去除 YAML 包裹引号（成对时才去除）
if [[ "${PRE_BUILD:0:1}" == "${PRE_BUILD: -1:1}" && ( "${PRE_BUILD:0:1}" == '"' || "${PRE_BUILD:0:1}" == "'" ) ]]; then
  PRE_BUILD="${PRE_BUILD:1:${#PRE_BUILD}-2}"
fi
if [[ -n "$PRE_BUILD" ]]; then
  echo "🔧 Running pre_build: $PRE_BUILD" >&2
  bash -c "$PRE_BUILD" || { echo "❌ pre_build hook failed" >&2; exit 1; }
fi

# Repo root often isn't the buildable package (e.g. cmd/<pkg>), so auto-detect the main-package dir.
if [[ "$BUILD_PATH" == "." ]]; then
  if ! grep -q "^package main" "$SOURCE_DIR"/*.go 2>/dev/null; then
    detected=$(cd "$SOURCE_DIR" && grep -rl "^package main" --include="*.go" . 2>/dev/null | sed 's#/[^/]*$##' | sort -u | head -1 || true)
    if [[ -n "$detected" ]]; then
      BUILD_PATH="$detected"
      echo "🔍 Auto-detected build_path: $BUILD_PATH" >&2
    fi
  fi
fi

# cgo 构建支持：recipe 声明 cgo: true 时启用 CGO 并配置对应架构的交叉编译器
CGO_BUILD=$(grep '^cgo:' "$RECIPE" 2>/dev/null | head -n1 | awk '{print $2}' | tr -d '"' || true)

# Rust 构建支持：recipe 声明 language: rust 时改用 cargo 构建
RUST_BUILD=$(grep '^language:' "$RECIPE" 2>/dev/null | head -n1 | awk '{print $2}' | tr -d '"' || true)
[[ "$RUST_BUILD" == "rust" ]] || RUST_BUILD=""

# 嵌套模块支持：若 build_path 所在的模块根（向上最近的有 go.mod 的目录）不是仓库根，
# 则进入该模块根构建（如 amazon-ecr-credential-helper 的 ecr-login/）。
if [[ "$BUILD_PATH" != "." ]]; then
  MOD_DIR="$BUILD_PATH"
  while [[ "$MOD_DIR" != "." && ! -f "$MOD_DIR/go.mod" ]]; do
    MOD_DIR="$(dirname "$MOD_DIR")"
  done
  if [[ "$MOD_DIR" != "." && -f "$MOD_DIR/go.mod" ]]; then
    REL="${BUILD_PATH#"$MOD_DIR"/}"
    [[ "$REL" == "$BUILD_PATH" ]] && REL="."
    echo "🔍 Nested Go module at ${MOD_DIR}; building ./${REL} from there" >&2
    cd "$MOD_DIR"
    BUILD_PATH="./${REL#.}"
    BUILD_PATH="${BUILD_PATH%/}"
  fi
fi


# go module setup (Go 项目专用；Rust 项目跳过)
if [[ "$RUST_BUILD" != "rust" ]]; then
  if [[ ! -f go.mod ]]; then
  # 已知历史模块改名（大小写问题）：自动修正源码 import，避免 go mod tidy 解析失败
  grep -rl 'github.com/Sirupsen/logrus' --include='*.go' . 2>/dev/null \
    | xargs -r sed -i 's#github\.com/Sirupsen/logrus#github.com/sirupsen/logrus#g' || true

  echo "💡 No go.mod found; running 'go mod init' + 'go mod tidy'" >&2
  go mod init "github.com/${repo_line}" || true
  go mod tidy || true
  fi
fi

# 依赖版本微调：recipe 中每条 go_get: <module>@<version> 在模块就绪后执行
while IFS= read -r g; do
  [[ -z "$g" ]] && continue
  echo "📌 go get $g" >&2
  go get "$g" || echo "⚠️  go get $g failed (continuing)" >&2
done <<< "$(grep '^go_get:' "$RECIPE" 2>/dev/null | sed 's/^go_get:[[:space:]]*//' | tr -d '"')"

# 构建环境变量：recipe 中每条 build_env: "KEY=VALUE" 导出后供构建使用（如 GOEXPERIMENT=jsonv2）
while IFS= read -r kv; do
  [[ -z "$kv" ]] && continue
  echo "🌍 export $kv" >&2
  export "$kv"
done <<< "$(grep '^build_env:' "$RECIPE" 2>/dev/null | sed 's/^build_env:[[:space:]]*//' | tr -d '"')"

# 按架构容错：单个架构失败不中断，继续建其余架构；
# 只要有一个架构成功就算成功（exit 0），全部失败才 exit 1。
FAILED_ARCHES=()
OK_COUNT=0

for ARCH in "${ARCH_LIST[@]}"; do
  echo "🚀 Building for ${ARCH}..." >&2
  GOARCH="$ARCH"
  GOARM=""
  if [[ "$ARCH" == "armhf" ]]; then GOARCH=arm; GOARM=7; fi

  # cgo 构建：recipe 声明 cgo: true 时启用 CGO 并配置对应架构的编译器
  if [[ "$CGO_BUILD" == "true" ]]; then
    case "$ARCH" in
      amd64)
        export CGO_ENABLED=1 CC=gcc ;;
      arm64)
        if ! command -v aarch64-linux-gnu-gcc >/dev/null; then
          echo "❌ cgo build for arm64 requires aarch64-linux-gnu-gcc (apt install gcc-aarch64-linux-gnu)" >&2
          FAILED_ARCHES+=("$ARCH")
          continue
        fi
        export CGO_ENABLED=1 CC=aarch64-linux-gnu-gcc ;;
      *)
        echo "⚠️  cgo build not supported for ${ARCH}; skipping" >&2
        FAILED_ARCHES+=("$ARCH")
        continue ;;
    esac
  else
    # CGO_ENABLED=0 yields static binaries that build on clean CI runners; cgo-only packages fail honestly here.
    export CGO_ENABLED=0
  fi
  export GOOS=linux GOARCH="$GOARCH" GOARM="${GOARM:-}"

  BUILD_PREFIX="${TMPBASE}/build-${PKG_NAME}-${ARCH}-${TIMESTAMP}"
  mkdir -p "$BUILD_PREFIX"
  BIN="${BUILD_PREFIX}/${PKG_NAME}"

  BUILD_RC=0

  # ---- Rust 分支：cargo 构建，产出多二进制到 target/<triple>/release/ ----
  if [[ "$RUST_BUILD" == "rust" ]]; then
    TRIPLE=""
    case "$ARCH" in
      amd64)
        TRIPLE="x86_64-unknown-linux-gnu" ;;
      arm64)
        TRIPLE="aarch64-unknown-linux-gnu"
        CROSS_CC="aarch64-linux-gnu-gcc"
        if ! command -v "$CROSS_CC" >/dev/null; then
          echo "❌ rust arm64 cross build requires $CROSS_CC (apt install gcc-aarch64-linux-gnu)" >&2
          FAILED_ARCHES+=("$ARCH"); continue
        fi
        export CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_LINKER="$CROSS_CC"
        export CC_aarch64_unknown_linux_gnu="$CROSS_CC"
        rustup target add "$TRIPLE" >/dev/null 2>&1 || { echo "❌ rustup target add $TRIPLE failed" >&2; FAILED_ARCHES+=("$ARCH"); continue; } ;;
      *)
        echo "⚠️  rust build not supported for ${ARCH}; skipping" >&2
        FAILED_ARCHES+=("$ARCH"); continue ;;
    esac
    LOCKED=""
    [[ -f Cargo.lock ]] && LOCKED="--locked"
    echo "🦀 cargo build --release $LOCKED --target $TRIPLE" >&2
    if ! cargo build --release $LOCKED --target "$TRIPLE"; then
      echo "❌ cargo build failed for ${ARCH}" >&2
      FAILED_ARCHES+=("$ARCH"); continue
    fi
    # 从 Cargo.toml 的 [[bin]] 段提取二进制名；缺省用包名（cargo 默认产物）
    RUST_BINS=$(grep -A3 '^\[\[bin\]\]' Cargo.toml 2>/dev/null | sed -n 's/^[[:space:]]*name[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' | sort -u)
    [[ -z "$RUST_BINS" ]] && RUST_BINS="$PKG_NAME"
    for b in $RUST_BINS; do
      if [[ ! -f "target/${TRIPLE}/release/${b}" ]]; then
        echo "❌ binary not found: target/${TRIPLE}/release/${b}" >&2
        FAILED_ARCHES+=("$ARCH"); continue 2
      fi
    done
  else
  # ---- Go 分支 ----
  # 带重试的构建（最多 2 次）：首架构构建常因瞬时网络/磁盘抖动（如 ENOSPC）失败，
  # 重试即可恢复；同时失败时才如实打印完整日志，避免真实错误被 "go: downloading" 行掩盖。
  GO_RC=1
  MODFLAG=""
  for (( attempt=1; attempt<=2; attempt++ )); do
    if (( attempt > 1 )); then
      echo "🔁 go build 重试 (${attempt}/2) for ${ARCH} ${MODFLAG:+(mod=mod)}" >&2
    fi
    if BUILD_LOG=$(go build ${MODFLAG} -trimpath ${LDFLAGS:+-ldflags="$LDFLAGS"} -o "$BIN" "$BUILD_PATH" 2>&1); then
      GO_RC=0
    else
      GO_RC=$?
    fi
    if (( GO_RC == 0 )) && [[ -f "$BIN" ]]; then
      break
    fi
    # 报错涉及 vendor/modules.txt 不一致时，下一轮改用 -mod=mod 重试
    if echo "$BUILD_LOG" | grep -q 'modules.txt'; then
      MODFLAG="-mod=mod"
    fi
  done
  if (( GO_RC != 0 )) || [[ ! -f "$BIN" ]]; then
    echo "❌ go build failed for ${ARCH} (rc=${GO_RC})" >&2
    echo "----- go build 输出 -----" >&2
    echo "$BUILD_LOG" >&2
    echo "------------------------" >&2
    echo "  磁盘空间(/): $(df -h / | tail -1)" >&2
    echo "  内核 OOM: $(sudo dmesg 2>/dev/null | grep -i 'killed process\|out of memory' | tail -2 || echo 无法读取)" >&2
    FAILED_ARCHES+=("$ARCH")
    continue
  fi
  fi

  DEB_ROOT="${BUILD_PREFIX}/deb-root"
  rm -rf "$DEB_ROOT"
  mkdir -p "$DEB_ROOT/usr/bin"
  if [[ "$RUST_BUILD" == "rust" ]]; then
    for b in $RUST_BINS; do
      cp "target/${TRIPLE}/release/${b}" "$DEB_ROOT/usr/bin/"
    done
  else
    cp "$BIN" "$DEB_ROOT/usr/bin/${BINARY_NAME}"
  fi

  # --- recipe 声明的额外文件 -------------------------------------------------
  # deb_files 每行: "<源码树内相对路径> <包内目标目录> [权限]"
  #   源码树 = 克隆下来的仓库根（$SOURCE_DIR），与当前 cwd 是否为嵌套模块无关。
  if grep -q '^deb_files:' "$RECIPE"; then
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      # YAML 列表项是缩进的（"  - \"src dst mode\""），所以顺序必须是：
      # 先去首尾空白 → 再去列表符号 → 再剥引号。反过来会把 "- " 留在串首。
      line="$(echo "$line" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
      line="${line#- }"; line="${line#-}"
      line="$(echo "$line" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
      line="${line%\"}"; line="${line#\"}"     # 去掉可能成对的引号
      set -- $line
      src="${1:-}"; dest_dir="${2:-}"; mode="${3:-}"
      [[ -z "$src" || -z "$dest_dir" ]] && { echo "⚠️  跳过无效 deb_files 行: $line" >&2; continue; }
      if [[ ! -e "$SOURCE_DIR/$src" ]]; then
        echo "⚠️  deb_files 源文件不存在，跳过: $src" >&2
        continue
      fi
      mkdir -p "$DEB_ROOT/$dest_dir"
      cp -a "$SOURCE_DIR/$src" "$DEB_ROOT/$dest_dir/"
      if [[ -n "$mode" ]]; then chmod "$mode" "$DEB_ROOT/$dest_dir/$(basename "$src")"; fi
      echo "➕ extra file: $src → /$dest_dir$(basename "$src")" >&2
    done <<< "$(awk '/^deb_files:/{flag=1; next} /^[a-zA-Z]/{if(flag)exit} flag && /^[[:space:]]*-/{print}' "$RECIPE")"
  fi

  # extra_root: 目录树按原样叠加到包根（用于随配方维护的静态文件）
  if [[ -n "$EXTRA_ROOT" ]]; then
    if [[ -d "$EXTRA_ROOT" ]]; then
      cp -a "$EXTRA_ROOT/." "$DEB_ROOT/"
      echo "➕ extra_root overlay: $EXTRA_ROOT" >&2
    else
      echo "⚠️  extra_root 不存在，跳过: $EXTRA_ROOT" >&2
    fi
  fi

  # Description field (support multi-line "description: |")
  if grep -q '^description: |' "$RECIPE"; then
    DESCRIPTION=$(awk '/^description: \|/{flag=1; next} flag && /^[[:space:]]/{print; next} flag{exit}' "$RECIPE" | sed 's/^[[:space:]]*//; s/^/ /' || true)
  else
    DESCRIPTION=$(grep '^description:' "$RECIPE" 2>/dev/null | sed 's/^description:[ ]*//' | tr -d '"' || true)
  fi

  mkdir -p "$DEB_ROOT/DEBIAN"
  {
    cat << EOF
Package: ${PKG_NAME}
Version: ${FINAL_VERSION}
Section: ${SECTION}
Priority: optional
Architecture: ${ARCH}
EOF
    # Depends 是可选字段：无依赖时不输出，绝不能写 "none"（会被当成包名导致安装失败）
    if [[ -n "${DEPENDS:-}" ]]; then
      echo "Depends: ${DEPENDS}"
    fi
    # 可选控制字段：仅在 recipe 声明时输出
    if [[ -n "$RECOMMENDS" ]]; then echo "Recommends: ${RECOMMENDS}"; fi
    if [[ -n "$SUGGESTS" ]]; then echo "Suggests: ${SUGGESTS}"; fi
    # XB-Suites: 本包只发布到这些发行版（空=全发行版）。XB- 是 Debian 政策给自定义
    # 字段留的前缀，dpkg 与 aptly 都原样保留；apt-repo/scripts/publish.sh 读它做分流。
    if [[ -n "${SUITES:-}" ]]; then echo "XB-Suites: ${SUITES}"; fi
    cat << EOF
Maintainer: ${MAINTAINER}
Homepage: ${HOMEPAGE:-https://github.com/${repo_line}}
Source: ${PKG_NAME} (${UPGRADE_VERSION}+git${GITDATE}.${SHORT_SHA})
Description: ${DESCRIPTION:-Auto-built Go package from ${repo_line}}
EOF
  } > "$DEB_ROOT/DEBIAN/control"

  # control_dir: 把配方目录里的控制文件（postinst/prerm/postrm/conffiles…）复制进 DEBIAN/
  if [[ -n "$CONTROL_DIR" ]]; then
    if [[ -d "$CONTROL_DIR" ]]; then
      for cf in "$CONTROL_DIR"/*; do
        [[ -e "$cf" ]] || continue
        bn="$(basename "$cf")"
        # 文案类文件保留原名；维护脚本必须可执行
        case "$bn" in
          postinst|preinst|prerm|postrm|config|triggers) chmod 0755 "$cf" ;;
        esac
        cp -a "$cf" "$DEB_ROOT/DEBIAN/$bn"
      done
      echo "➕ control files from: $CONTROL_DIR" >&2
    else
      echo "⚠️  control_dir 不存在，跳过: $CONTROL_DIR" >&2
    fi
  fi

  DEB_FILE="${OUTPUT_DIR}/${PKG_NAME}_${FINAL_VERSION}_${ARCH}.deb"
  if ! dpkg-deb --build --root-owner-group "$DEB_ROOT" "$DEB_FILE" >/dev/null; then
    echo "❌ dpkg-deb failed for ${ARCH}" >&2
    FAILED_ARCHES+=("$ARCH")
    continue
  fi
  echo "✅ Created: $DEB_FILE" >&2
  OK_COUNT=$((OK_COUNT+1))
done

if (( OK_COUNT == 0 )); then
  echo "💥 All architectures failed for ${PKG_NAME}: ${FAILED_ARCHES[*]}" >&2
  exit 1
fi
if (( ${#FAILED_ARCHES[@]} > 0 )); then
  echo "⚠️  Partial build for ${PKG_NAME}: ${OK_COUNT} arch(s) OK, failed: ${FAILED_ARCHES[*]}" >&2
fi

echo "🎉 Done: $(ls -1 "$OUTPUT_DIR"/${PKG_NAME}_${FINAL_VERSION}_*.deb 2>/dev/null | wc -l) .deb file(s) in dist/" >&2
