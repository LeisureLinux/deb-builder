#!/bin/bash
# build-one.sh: 为单个 recipe 构建 .deb
PKG_NAME="${1:?Usage: $0 <package_name>}"
set -euo pipefail

recipe="recipes/${PKG_NAME}.yaml"
if [[ ! -f "$recipe" ]]; then
    echo "❌ Recipe not found for $PKG_NAME at $recipe" >&2
    exit 1
fi

# 读取 yaml 值并去除可能的双引号（yaml 里字符串常带引号）
read_yaml() {
    local key="$1"
    grep -E "^${key}:" "$recipe" | head -n1 | awk '{print $2}' \
        | sed 's/^"//; s/"$//; s/^'"'"'//; s/'"'"'$//' || echo ""
}

echo "🏗️  Building ${PKG_NAME}..."
repo=$(read_yaml repo)
go_version=$(read_yaml go_version)

# 版本解析：
#  - 若 recipe 里 latest_tag 是具体版本（如 v5.36.1），则用它；
#  - 若 version_tag 是 ref:* 模式（自动取最新 tag），则交给 build-go-deb.sh 自动探测；
#  - 其余情况传空，由 build-go-deb.sh 决定。
latest_tag=$(read_yaml latest_tag)
version_tag=$(read_yaml version_tag)

if [[ -n "$latest_tag" && "$latest_tag" != "null" ]]; then
    VERSION="$latest_tag"
elif [[ "$version_tag" == ref:* ]]; then
    VERSION=""   # auto-detect from upstream git tags
else
    VERSION="$version_tag"
fi

# 调用构建脚本（传递必要的参数）
# build-go-deb.sh 用法: <package-name> [version] [binary-path] [archs]
# BINARY_PATH 未设置时传空串，由 build-go-deb.sh 内部默认处理。
bash scripts/build-go-deb.sh "$PKG_NAME" "$VERSION" "${BINARY_PATH:-}"
echo "✅ Built ${PKG_NAME}"
