#!/bin/bash
# build-one.sh: 为单个 recipe 构建 .deb（多架构）
# 用法: ./scripts/build-one.sh <package_name>
# 环境变量:
#   OUTPUT_DIR  : 产物目录（默认 dist）
#   BINARY_PATH : 已编译二进制路径（可选）
PKG_NAME="${1:?Usage: $0 <package_name>}"
set -euo pipefail

recipe="recipes/${PKG_NAME}.yaml"
if [[ ! -f "$recipe" ]];then
    echo "❌ Recipe not found for $PKG_NAME at $recipe" >&2
    exit 1
fi

echo "🏗️  Building ${PKG_NAME} ..."
# 全部交由 build-go-deb.sh 从 recipe 读取 latest_tag/commit_hash/target_arches 等
bash scripts/build-go-deb.sh "$PKG_NAME" "" "${BINARY_PATH:-}"
echo "✅ Built ${PKG_NAME}"
