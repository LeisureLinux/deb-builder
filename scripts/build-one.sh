#!/bin/bash
# build-one.sh: 为单个 recipe 构建 .deb（多架构）
# 用法: ./scripts/build-one.sh <package_name>
PKG_NAME="${1:?Usage: $0 <package_name>}"
set -euo pipefail

cd "$(dirname "$0")/.." || exit 1

recipe="recipes/${PKG_NAME}.yaml"
if [[ ! -f "$recipe" ]]; then
    echo "❌ Recipe not found for $PKG_NAME at $recipe" >&2
    exit 1
fi

# 从 recipe 的 target_arches 解析真实架构列表（不再传空 "" 导致不构建）
ARCHS=$(awk '/^target_arches:/{flag=1; next} /^[^[:space:]]/ && flag{exit} flag && /^[[:space:]]*- /{sub(/^[[:space:]]*- /,""); print $1}' "$recipe" | paste -sd, -)
ARCHS="${ARCHS:-amd64}"

echo "🏗️  Building ${PKG_NAME} for arches: ${ARCHS} ..." >&2
bash scripts/build-go-deb.sh "$PKG_NAME" "$ARCHS" "${BINARY_PATH:-}"
echo "✅ Built ${PKG_NAME}"
