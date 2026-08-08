#!/bin/bash
# build-go-deb.sh: Go 项目多架构 .deb 构建器
# 用法: bash scripts/build-go-deb.sh <package-name> [version] [binary-path] [arch1,arch2,...]
#   package-name  : recipe 名 / Debian 包名，如 gdu（会读取 recipes/<name>.yaml）
#   version       : 版本号，如 v5.36.1（可选，默认从 recipe latest_tag/version_tag 推断）
#   binary-path   : 已编译二进制路径（可选；默认走源码交叉编译）
#   archs         : 逗号分隔的目标架构，如 amd64,arm64,loong64,riscv64（可选，默认读取 recipe target_arches）
set -euo pipefail

PKG_NAME="${1:?Usage: build-go-deb.sh <package-name> [version] [binary-path] [archs]}"
VERSION="${2:-}"
BINARY_PATH="${3:-}"
ARCH_LIST="${4:-}"

RECIPE="recipes/${PKG_NAME}.yaml"
OUTPUT_DIR="${OUTPUT_DIR:-dist}"

MAINTAINER="LeisureLinux <albertxu@freelamp.com>"
SECTION="utils"

# ---- 从 recipe 读取配置 ----
if [[ -f "$RECIPE" ]]; then
    repo_line=$(grep -E '^repo:' "$RECIPE" | head -n1 | awk '{print $2}')
    [[ -z "$VERSION" ]] && VERSION=$(grep -E '^latest_tag:' "$RECIPE" | awk '{print $2}')
    [[ -z "$ARCH_LIST" ]] && ARCH_LIST=$(grep -A20 '^target_arches:' "$RECIPE" | grep -oE '^\s*-\s*[a-z0-9]+' | awk '{print $2}' | paste -sd, -)
fi

# 从上游 git 仓库解析最新 tag（如果 recipe 指定了 repo 且 version 仍为空）
if [[ -z "$VERSION" && -n "${repo_line:-}" ]]; then
    echo "🔎 从 ${repo_line} 解析最新版本标签..."
    VERSION=$(git ls-remote --tags "https://github.com/${repo_line}.git" 2>/dev/null \
        | grep -oE 'refs/tags/v?[0-9]+\.[0-9]+\.[0-9]+$' \
        | sed 's#refs/tags/##; s#^v##' \
        | sort -V | tail -1)
fi
[[ -z "$VERSION" ]] && VERSION="0.0.0"
VERSION="${VERSION#v}"

# 默认架构
[[ -z "$ARCH_LIST" ]] && ARCH_LIST="amd64,arm64"

echo "📦 构建 ${PKG_NAME} v${VERSION} 目标架构: ${ARCH_LIST}"
echo "    recipe: ${RECIPE:-<无>}  源码: ${repo_line:-<未指定>}"

# goarch/deb 架构映射
arch_to_go() {
    case "$1" in
        amd64)      echo amd64 ;;
        arm64)      echo arm64 ;;
        armhf)      echo arm ;;
        loong64|loongarch64) echo loong64 ;;
        riscv64)    echo riscv64 ;;
        *)          echo "$1" ;;
    esac
}
arch_to_deb() {
    case "$1" in
        amd64|loongarch64) echo amd64 ;;
        arm64)      echo arm64 ;;
        arm|armhf)  echo armhf ;;
        loong64)    echo loong64 ;;
        riscv64)    echo riscv64 ;;
        *)          echo "$1" ;;
    esac
}

# ---- 准备源码目录（优先使用已存在的目录，否则克隆上游）----
if [[ -d "${repo_line##*/}" ]]; then
    SRC_DIR="${repo_line##*/}"
    echo "📂 使用已存在源码目录: $SRC_DIR"
elif [[ -n "${repo_line:-}" ]]; then
    SRC_DIR="${repo_line##*/}"
    echo "⬇️  克隆 https://github.com/${repo_line}.git"
    git clone --depth 1 --branch "v${VERSION}" "https://github.com/${repo_line}.git" "$SRC_DIR" 2>/dev/null \
        || git clone --depth 1 "https://github.com/${repo_line}.git" "$SRC_DIR"
else
    SRC_DIR="."
fi

# 为每个架构构建
mkdir -p "$OUTPUT_DIR"
IFS=',' read -ra ARCHES <<< "$ARCH_LIST"
for arch in "${ARCHES[@]}"; do
    arch=$(echo "$arch" | xargs)   # 去除空白
    [[ -z "$arch" ]] && continue
    goarch=$(arch_to_go "$arch")
    deblarch=$(arch_to_deb "$arch")

    echo ""
    echo "🔨 [${arch}] 交叉编译 GOOS=linux GOARCH=${goarch}..."
    # 定位 main 包：优先 cmd/<name>、cmd/，其次仓库根，最后子目录自动探测
    pkg_path=""
    for cand in "cmd/${PKG_NAME}" "cmd" "${PKG_NAME}" "main" "."; do
        if [[ -n "$(ls "$SRC_DIR/$cand"/*.go 2>/dev/null | grep -v _test)" ]] \
           && grep -lq 'package main' "$SRC_DIR"/"$cand"/*.go 2>/dev/null; then
            pkg_path="$cand"
            break
        fi
    done
    if [[ -z "$pkg_path" ]]; then
        pkg_path=$(cd "$SRC_DIR" && grep -rl 'package main' --include='*.go' . 2>/dev/null \
                    | grep -v _test | xargs -r dirname | head -1)
        pkg_path="${pkg_path#./}"
        pkg_path="${pkg_path:-.}"
    fi
    echo "      main 包: ./${SRC_DIR}/${pkg_path}"
    (cd "$SRC_DIR" && GOOS=linux GOARCH="$goarch" GOARM=7 \
        go build -trimpath -ldflags="-s -w" \
        -o "../$OUTPUT_DIR/${PKG_NAME}-${arch}" "./${pkg_path}") \
    || { echo "❌ [${arch}] 编译失败"; exit 1; }

    # ---- 组装 .deb 目录结构 ----
    pkg_dir="$OUTPUT_DIR/${PKG_NAME}_${VERSION}_${deblarch}"
    echo "📁 组装 .deb: $pkg_dir"
    rm -rf "$pkg_dir"
    mkdir -p "$pkg_dir/DEBIAN" "$pkg_dir/usr/bin"
    cp "$OUTPUT_DIR/${PKG_NAME}-${arch}" "$pkg_dir/usr/bin/${PKG_NAME}"
    chmod 755 "$pkg_dir/usr/bin/${PKG_NAME}"

    installed_size=$(du -sk "$pkg_dir" | cut -f1)
    cat > "$pkg_dir/DEBIAN/control" <<CONTROL
Package: ${PKG_NAME}
Version: ${VERSION}
Architecture: ${deblarch}
Maintainer: ${MAINTAINER}
Section: ${SECTION}
Priority: optional
Installed-Size: ${installed_size}
Description: ${PKG_NAME} - Go utility (built by LeisureLinux deb-builder)
 Homepage: https://github.com/${repo_line:-LeisureLinux/${PKG_NAME}}
CONTROL

    # ---- 打包 ----
    if (command -v dpkg-deb >/dev/null 2>&1); then
        dpkg-deb --build --root-owner-group "$pkg_dir" "$OUTPUT_DIR" 2>/dev/null \
            || dpkg-deb --build "$pkg_dir"
        echo "✅ [${arch}] 完成: $OUTPUT_DIR/${PKG_NAME}_${VERSION}_${deblarch}.deb"
    else
        echo "⚠️  [${arch}] 未安装 dpkg-deb，仅生成目录结构: $pkg_dir"
    fi
    rm -f "$OUTPUT_DIR/${PKG_NAME}-${arch}"
done

echo ""
echo "✅ 全部构建完成，产物在: $OUTPUT_DIR/"
ls -lh "$OUTPUT_DIR"/*.deb 2>/dev/null || true
