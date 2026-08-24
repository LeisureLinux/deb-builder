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

# depends: join list items, default "none"
DEPENDS="none"
if grep -q '^depends:' "$RECIPE"; then
  raw=$(awk '/^depends:/{flag=1; next} /^[a-zA-Z]/ && flag{exit} flag && /^- /{sub(/^- /,""); printf "%s,", $0}' "$RECIPE")
  raw="${raw%,}"
  [[ -n "$raw" ]] && DEPENDS="$raw"
fi

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

# --- Determine target arches (from $2, else recipe target_arches, else amd64) ---
if [[ -z "$ARCHS_CSV" ]]; then
  ARCHS_CSV=$(awk '/^target_arches:/{flag=1; next} /^[^[:space:]]/ && flag{exit} flag && /^[[:space:]]*- /{sub(/^[[:space:]]*- /,""); print $1}' "$RECIPE" | paste -sd, -)
fi
if [[ -z "$ARCHS_CSV" ]]; then
  ARCHS_CSV="amd64"
fi

declare -a ARCH_LIST=()
while IFS= read -r a; do
  [[ -z "$a" ]] && continue
  case "$a" in
    loongarch64) a=loong64 ;;
    armhf) a=armhf ;;
  esac
  ARCH_LIST+=("$a")
done < <(echo "$ARCHS_CSV" | tr ',' '\n')

echo "📦 Building ${PKG_NAME} v${VERSION} (final: ${FINAL_VERSION})" >&2
echo "🏗️  Target architectures: ${ARCH_LIST[*]}" >&2

# --- Clone via HTTPS (works in CI without SSH keys) ---
TIMESTAMP="$(date +%Y%m%d%H%M%S)"
SOURCE_DIR="/tmp/${PKG_NAME}-src-${TIMESTAMP}"
rm -rf "$SOURCE_DIR"
mkdir -p "$SOURCE_DIR"
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
    detected=$(cd "$SOURCE_DIR" && grep -rl "^package main" --include="*.go" . 2>/dev/null | sed 's#/[^/]*$##' | sort -u | head -1)
    if [[ -n "$detected" ]]; then
      BUILD_PATH="$detected"
      echo "🔍 Auto-detected build_path: $BUILD_PATH" >&2
    fi
  fi
fi

# cgo 构建支持：recipe 声明 cgo: true 时启用 CGO 并配置对应架构的交叉编译器
CGO_BUILD=$(grep '^cgo:' "$RECIPE" 2>/dev/null | head -n1 | awk '{print $2}' | tr -d '"' || true)

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


# go module setup (only if upstream has no go.mod)
if [[ ! -f go.mod ]]; then
  # 已知历史模块改名（大小写问题）：自动修正源码 import，避免 go mod tidy 解析失败
  grep -rl 'github.com/Sirupsen/logrus' --include='*.go' . 2>/dev/null \
    | xargs -r sed -i 's#github\.com/Sirupsen/logrus#github.com/sirupsen/logrus#g' || true

  echo "💡 No go.mod found; running 'go mod init' + 'go mod tidy'" >&2
  go mod init "github.com/${repo_line}" || true
  go mod tidy || true
fi

# 依赖版本微调：recipe 中每条 go_get: <module>@<version> 在模块就绪后执行
while IFS= read -r g; do
  [[ -z "$g" ]] && continue
  echo "📌 go get $g" >&2
  go get "$g" || echo "⚠️  go get $g failed (continuing)" >&2
done < <(grep '^go_get:' "$RECIPE" 2>/dev/null | sed 's/^go_get:[[:space:]]*//' | tr -d '"')

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

  BUILD_PREFIX="/tmp/build-${PKG_NAME}-${ARCH}-${TIMESTAMP}"
  mkdir -p "$BUILD_PREFIX"
  BIN="${BUILD_PREFIX}/${PKG_NAME}"

  BUILD_RC=0
  BUILD_LOG=$(go build -trimpath ${LDFLAGS:+-ldflags="$LDFLAGS"} -o "$BIN" "$BUILD_PATH" 2>&1) || BUILD_RC=$?
  if (( BUILD_RC != 0 )); then
    # vendor/modules.txt 与 go.mod 不同步的老项目：改用 -mod=mod 忽略 vendor 重试一次
    if echo "$BUILD_LOG" | grep -q 'modules.txt'; then
      echo "⚠️  vendor/ inconsistent with go.mod; retrying with -mod=mod ..." >&2
      if ! BUILD_LOG=$(go build -mod=mod -trimpath ${LDFLAGS:+-ldflags="$LDFLAGS"} -o "$BIN" "$BUILD_PATH" 2>&1); then
        echo "$BUILD_LOG" >&2
        echo "❌ go build failed for ${ARCH}" >&2
        FAILED_ARCHES+=("$ARCH")
        continue
      fi
    else
      echo "$BUILD_LOG" >&2
      echo "❌ go build failed for ${ARCH}" >&2
      FAILED_ARCHES+=("$ARCH")
      continue
    fi
  fi
  if [[ ! -f "$BIN" ]]; then
    echo "❌ Binary not created: $BIN" >&2
    exit 1
  fi

  DEB_ROOT="${BUILD_PREFIX}/deb-root"
  rm -rf "$DEB_ROOT"
  mkdir -p "$DEB_ROOT/usr/bin"
  cp "$BIN" "$DEB_ROOT/usr/bin/"

  # Description field (support multi-line "description: |")
  if grep -q '^description: |' "$RECIPE"; then
    DESCRIPTION=$(awk '/^description: \|/{flag=1; next} flag && /^[[:space:]]/{print; next} flag{exit}' "$RECIPE" | sed 's/^[[:space:]]*//; s/^/ /' || true)
  else
    DESCRIPTION=$(grep '^description:' "$RECIPE" 2>/dev/null | sed 's/^description:[ ]*//' | tr -d '"' || true)
  fi

  mkdir -p "$DEB_ROOT/DEBIAN"
  cat > "$DEB_ROOT/DEBIAN/control" << EOF
Package: ${PKG_NAME}
Version: ${FINAL_VERSION}
Section: ${SECTION}
Priority: optional
Architecture: ${ARCH}
Depends: ${DEPENDS}
Maintainer: ${MAINTAINER}
Homepage: ${HOMEPAGE:-https://github.com/${repo_line}}
Source: ${PKG_NAME} (${UPGRADE_VERSION}+git${GITDATE}.${SHORT_SHA})
Description: ${DESCRIPTION:-Auto-built Go package from ${repo_line}}
EOF

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
