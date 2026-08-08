#!/bin/bash
# build-one.sh: 为单个 recipe 构建 .deb
PKG_NAME="${1:?Usage: $0 <package_name>}"
set -euo pipefail

recipe="recipes/${PKG_NAME}.yaml"
if [[ ! -f "$recipe" ]]; then
    echo "❌ Recipe not found for $PKG_NAME at $recipe" >&2
    exit 1
fi

echo "🏗️  Building ${PKG_NAME}..."
repo=$(grep "^repo:" "$recipe" | awk '{print $2}')
version=$(grep "^version_tag:" "$recipe" | head -n1 | awk '{print $2}' || echo "")
go_version=$(grep "^go_version:" "$recipe" | awk '{print $2}' || echo "latest")

# 调用构建脚本（传递必要的参数）
# build-go-deb.sh 用法: <repo-name> <version> <binary-path> [output-dir]
# BINARY_PATH 未设置时传空串，由 build-go-deb.sh 内部默认处理。
bash scripts/build-go-deb.sh "$PKG_NAME" "${version:-}" "${BINARY_PATH:-}"
echo "✅ Built ${PKG_NAME}"
