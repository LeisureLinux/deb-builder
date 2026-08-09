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
# 若设置了 TARGET_ARCHS 环境变量，则用它覆盖所有来源（用于全局只构建某架构）
if [[ -n "${TARGET_ARCHS:-}" ]]; then ARCH_LIST="$TARGET_ARCHS"; fi

RECIPE="recipes/${PKG_NAME}.yaml"
OUTPUT_DIR="${OUTPUT_DIR:-dist}"
OUTPUT_DIR="$(cd "$(dirname "$OUTPUT_DIR")" 2>/dev/null && pwd)/$(basename "$OUTPUT_DIR")"  # 转为绝对路径

MAINTAINER="LeisureLinux <albertxu@freelamp.com>"
SECTION="utils"

# ---- 从 recipe 读取配置 ----
strip_q() { sed -e 's/^["'"'"']//' -e 's/["'"'"']$//'; }
if [[ -f "$RECIPE" ]]; then
    repo_line=$(grep -E '^repo:' "$RECIPE" | head -n1 | awk '{print $2}' | strip_q)
    lt=$(grep -E '^latest_tag:' "$RECIPE" | awk '{print $2}' | strip_q)
    if [[ -n "$lt" && "$lt" != '""' ]]; then VERSION="$lt"; fi
    commit_hash=$(grep -E '^commit_hash:' "$RECIPE" | awk '{print $2}' | strip_q)
    upstream_version=$(grep -E '^upstream_version:' "$RECIPE" | awk '{print $2}' | strip_q)
    [[ -z "$ARCH_LIST" ]] && ARCH_LIST=$(grep -A20 '^target_arches:' "$RECIPE" | grep -oE '^\s*-\s*[a-z0-9]+' | awk '{print $2}' | paste -sd, -)
    # Section / Homepage / Description（遵循 Debian 原生包元数据）
    sec=$(grep -E '^section:' "$RECIPE" | head -n1 | awk '{print $2}' | strip_q)
    [[ -n "$sec" ]] && SECTION="$sec"
    hp=$(grep -E '^homepage:' "$RECIPE" | head -n1 | awk '{print $2}' | strip_q)
    [[ -n "$hp" ]] && HOMEPAGE="$hp"
    # 读取 description 多行块（去 2 空格缩进）
    DESC=$(awk '/^description:/{f=1;next} /^[a-z_][a-z0-9_]*:/{if(f) exit} f{sub(/^  /,""); print}' "$RECIPE")
fi
HOMEPAGE="${HOMEPAGE:-https://github.com/${repo_line:-LeisureLinux/${PKG_NAME}}}"
if [[ -z "$DESC" ]]; then
    DESC="${PKG_NAME} - Go utility"
fi

# 默认 commit hash（从 recipe 或由 clone 时解析；用户也可显式传入）
COMMIT_HASH="${commit_hash:-}"
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

# ---- 解析 commit hash（若 recipe 未提供，则从 ls-remote 取最新 tag 的 SHA）----
if [[ -z "$COMMIT_HASH" && -n "${repo_line:-}" ]]; then
    echo "🔎 解析 ${repo_line} 的最新 commit hash..."
    # VERSION 可能形如 v1.3.1；确保以 v 开头用于 ls-remote 查询
    fulltag="$VERSION"
    [[ "$fulltag" != v* ]] && fulltag="v$fulltag"
    COMMIT_HASH=$(git ls-remote "https://github.com/${repo_line}.git" "refs/tags/${fulltag}" 2>/dev/null | awk '{print $1}' | head -1)
    if [[ -z "$COMMIT_HASH" ]]; then
        # tag 不存在（可能版本号不含 v），取默认分支 HEAD
        COMMIT_HASH=$(git ls-remote "https://github.com/${repo_line}.git" HEAD 2>/dev/null | awk '{print $1}' | head -1)
    fi
fi
[[ -z "$COMMIT_HASH" ]] && COMMIT_HASH="unknown"

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

# ---- 解析 commit 日期（YYYYMMDD）用于 Source 版本串 ----
if [[ "$COMMIT_HASH" != "unknown" && -d "$SRC_DIR" ]]; then
    GITDATE=$(cd "$SRC_DIR" && git log -1 --format=%cs "$COMMIT_HASH" 2>/dev/null | tr -d '-')
fi
[[ -z "$GITDATE" ]] && GITDATE=$(date +%Y%m%d)
SHORT_SHA="${COMMIT_HASH:0:7}"
[[ "$COMMIT_HASH" == "unknown" ]] && SHORT_SHA="unknown"

# ---- 构建号 NN（本地为 1，可被 BUILD_NUMBER 环境变量覆盖）----
BUILD_NUMBER="${BUILD_NUMBER:-1}"

# ---- Source 字段：pkg (上游版本+gitYYYYMMDD.sha7-NN) ----
UPVER="${upstream_version:-$VERSION}"
SOURCE_STR="${PKG_NAME} (${UPVER}+git${GITDATE}.${SHORT_SHA}-${BUILD_NUMBER})"

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
        -o "$OUTPUT_DIR/${PKG_NAME}-${arch}" "./${pkg_path}") \
    || { echo "❌ [${arch}] 编译失败"; exit 1; }

    # ---- 组装 .deb 目录结构 ----
    pkg_dir="$OUTPUT_DIR/${PKG_NAME}_${VERSION}_${deblarch}"
    echo "📁 组装 .deb: $pkg_dir"
    rm -rf "$pkg_dir"
    mkdir -p "$pkg_dir/DEBIAN" "$pkg_dir/usr/bin"
    cp "$OUTPUT_DIR/${PKG_NAME}-${arch}" "$pkg_dir/usr/bin/${PKG_NAME}"
    chmod 755 "$pkg_dir/usr/bin/${PKG_NAME}"

    installed_size=$(du -sk "$pkg_dir" | cut -f1)

    # Description：原生描述 + 署名；首行不带缩进，续行每行前导一个空格
    # 若 recipe 描述以 "X - " 开头则保留；末尾追加 (built by LeisureLinux deb-builder)
    desc_lines="$(printf '%s\n' "$DESC" | grep -v 'Phase 1 auto-built')"
    desc_first=$(printf '%s\n' "$desc_lines" | head -n1)
    desc_rest=$(printf '%s\n' "$desc_lines" | tail -n +2 | sed 's/^/ /')
    # 用 printf 组装 Description 多行（避免 heredoc 的 \n 不转义）
    printf '%s\n' \
      "Package: ${PKG_NAME}" \
      "Version: ${VERSION}" \
      "Architecture: ${deblarch}" \
      "Maintainer: ${MAINTAINER}" \
      "Section: ${SECTION}" \
      "Priority: optional" \
      "Installed-Size: ${installed_size}" \
      "Homepage: ${HOMEPAGE}" \
      "Source: ${SOURCE_STR}" \
      "Description: ${desc_first}" > "$pkg_dir/DEBIAN/control"
    [[ -n "$desc_rest" ]] && printf '%s\n' "$desc_rest" >> "$pkg_dir/DEBIAN/control"
    printf '%s\n' \
      " (built by LeisureLinux deb-builder)" >> "$pkg_dir/DEBIAN/control"


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
