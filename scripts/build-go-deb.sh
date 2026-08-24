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
repo_line=$(grep '^repo:' "$RECIPE" | awk '{print $2}' | tr -d '"' | tr -d "'")
if [[ -z "$repo_line" ]]; then
  echo "❌ Missing 'repo:' in $RECIPE" >&2
  exit 1
fi

HOMEPAGE=$(grep '^homepage:' "$RECIPE" | sed 's/^homepage:[ ]*//' | tr -d '"' || true)

UPGRADE_VERSION_RAW=$(grep '^upstream_version:' "$RECIPE" 2>/dev/null | head -n1)
if [[ -z "$UPGRADE_VERSION_RAW" ]]; then
  UPGRADE_VERSION="0.0.1"
else
  UPGRADE_VERSION=$(echo "$UPGRADE_VERSION_RAW" | sed 's/^upstream_version:[ ]*//' | tr -d '"' | sed 's/^v//')
fi

VERSION_RAW=$(grep '^latest_tag:' "$RECIPE" 2>/dev/null | head -n1)
if [[ -n "$VERSION_RAW" ]]; then
  VERSION=$(echo "$VERSION_RAW" | sed 's/^latest_tag:[ ]*//' | tr -d '"' | sed 's/^v//')
else
  VERSION="${UPGRADE_VERSION}"
fi

# build_path (optional, default ".")
BUILD_PATH=$(grep '^build_path:' "$RECIPE" 2>/dev/null | sed 's/^build_path:[ ]*//' | tr -d '"' || true)
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
git clone --depth 1 "https://github.com/${repo_line}.git" "$SOURCE_DIR"

cd "$SOURCE_DIR"
if [[ -n "$COMMIT_HASH" ]]; then
  echo "🔖 Fetching & checking out ${COMMIT_HASH}" >&2
  git fetch --depth 1 origin "$COMMIT_HASH"
  git checkout "$COMMIT_HASH"
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

# go module setup (only if upstream has no go.mod)
if [[ ! -f go.mod ]]; then
  echo "💡 No go.mod found; running 'go mod init' + 'go mod tidy'" >&2
  go mod init "github.com/${repo_line}"
  go mod tidy
fi

for ARCH in "${ARCH_LIST[@]}"; do
  echo "🚀 Building for ${ARCH}..." >&2
  GOARCH="$ARCH"
  GOARM=""
  if [[ "$ARCH" == "armhf" ]]; then GOARCH=arm; GOARM=7; fi
  # CGO_ENABLED=0 yields static binaries that build on clean CI runners; cgo-only packages fail honestly here.
  export GOOS=linux GOARCH="$GOARCH" GOARM="${GOARM:-}" CGO_ENABLED=0

  BUILD_PREFIX="/tmp/build-${PKG_NAME}-${ARCH}-${TIMESTAMP}"
  mkdir -p "$BUILD_PREFIX"
  BIN="${BUILD_PREFIX}/${PKG_NAME}"

  if ! go build -trimpath ${LDFLAGS:+-ldflags="$LDFLAGS"} -o "$BIN" "$BUILD_PATH" ; then
    echo "❌ go build failed for ${ARCH}" >&2
    exit 1
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
    DESCRIPTION=$(awk '/^description: \|/{flag=1; next} flag && /^[[:space:]]/{print; next} flag{exit}' "$RECIPE" | sed 's/^[[:space:]]*//; s/^/ /')
  else
    DESCRIPTION=$(grep '^description:' "$RECIPE" | sed 's/^description:[ ]*//' | tr -d '"')
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
    exit 1
  fi
  echo "✅ Created: $DEB_FILE" >&2
done

echo "🎉 Done: $(ls -1 "$OUTPUT_DIR"/${PKG_NAME}_${FINAL_VERSION}_*.deb 2>/dev/null | wc -l) .deb file(s) in dist/" >&2
