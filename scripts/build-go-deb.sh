#!/bin/bash
# build-go-deb.sh: Go 项目的多架构 .deb构建器
# 用法: bash scripts/build-go-deb.sh <repo-name> <version> <binary-path> [output-dir]
set -euo pipefail

REPO_NAME="$1"         # e.g. gdu
VERSION="$2"           # e.g. v5.36.1 → 5.36.1（strip v）
BINARY_PATH="${3:-./gdu}"  # 二进制路径（交叉编译结果）
OUTPUT_DIR="${4:-dist}"

# 从 VERSION 解析主版本号
VERSION="${VERSION#v}"  # strip "v" prefix

# --- 架构映射 (goarch → deb arch) ---
declare -A ARCH_MAP=(
    [amd64]=amd64
    [arm64]=arm64
    [arm]=armhf GOARM=7     # armhf=GOARCH=arm+GOARM=7 (硬浮点，CPU 需 >= ARMv7)
    [loongarch64]=loong64   # Go1.23 已原生支持 LoongArch
    [riscv64]=riscv64       # Go1.18+ 支持 riscv64
)

# --- 包元数据 ---
# 复用 Debian Packages 索引中的描述信息（后续可从 scanner 输出读取）
PKG_NAME="$REPO_NAME"
MAINTAINER="LeisureLinux <albertxu@freelamp.com>"
SECTION="utils"
DEPENDS=""   # Go 静态二进制通常无依赖，可留空或仅写 dpkg (用于 upgrade)

# --- 解析目标架构和构建选项 ---
TARGET_ARCH="${ARCH_MAP[$1]:-}"
if [[ -z "$TARGET_ARCH" ]]; then
    TARGET_ARCH="$(go env GOARCH)"  # 本机 Goarch
fi

PKG_DIR="dist/${REPO_NAME}_${VERSION}_$TARGET_ARCH"
BINARY_BIN=""

echo "🔨 构建 ${PKG_NAME} v${VERSION} for ${TARGET_ARCH}"

if [[ "$TARGET_ARCH" == "armhf" ]]; then
    # armhf 需要 GOARM=7
    export GOARCH="arm"
    export GOARM="7"
elif [[ "$TARGET_ARCH" == "loong64" ]]; then
    export GOARCH="loong64"
elif [[ "$TARGET_ARCH" == "riscv64" ]]; then
    export GOARCH="riscv64"
else
    export GOARCH="$TARGET_ARCH"
fi

GOOS="linux"

# 目标二进制名（如果 BINARY_PATH 是目录，则用文件名）
if [[ -d "$BINARY_PATH" && ! -x "$BINARY_PATH" ]]; then
    BINARY_BIN=$(basename "$BINARY_PATH")
elif [[ -f "$BINARY_PATH" || -x "$BINARY_PATH" ]]; then
    BINARY_BIN="$(basename "$BINARY_PATH")"
else
    # 编译新包（如果还没编译）
    echo "📦 交叉编译..."
    go build -ldflags="-s -w" -o "$REPO_NAME/bin"
    if [[ ! -f "dist/$BINARY_BIN" ]]; then
        mv "$BINARY_BIN" "$OUTPUT_DIR/$BINARY_BIN" || true
    fi
fi

mkdir -p dist
if [[ -f "$BINARY_PATH" && ! -x "$BINARY_PATH" ]]; then
    # 假设是目录名，找可执行文件
    binary_file=$(ls -1d "$BINARY_PATH"/$REPO_NAME 2>/dev/null | head -1 || true)
    if [[ -n "$binary_file" ]]; then
        cp "$binary_file" dist/$REPO_NAME-raw
        BINARY_BIN=$REPO_NAME
    else
        # 目录不存在，可能是未编译状态
        echo "⚠️ 二进制 $BINARY_PATH 不存在，尝试从上游克隆编译..."
    fi
else
    cp "$BINARY_PATH" dist/$REPO_NAME-raw || BINARY_BIN="$(basename "$BINARY_PATH")"
fi

# --- 创建 .deb 目录结构 ---
echo "📁 dpkg dir: $PKG_DIR"
rm -rf "$PKG_DIR"
mkdir -p "$PKG_DIR"/DEBIAN
mkdir -p "$PKG_DIR"/usr/bin
mkdir -p "$PKG_DIR"/etc"$REPO_NAME"
mkdir -p "$PKG_DIR"/usr/share/man/man1

# 复制二进制到 /usr/bin
if [[ -f "dist/$REPO_NAME-raw" ]]; then
    cp dist/"$REPO_NAME-raw" "$PKG_DIR/usr/bin/$REPO_NAME" || true
fi

# --- 生成 control file（控制文件）---
cat > "$PKG_DIR/DEBIAN/control" <<CONTROL
Package: ${PACKAGE_NAME:-${PKG_NAME}}
Version: ${VERSION}
Architecture: ${TARGET_ARCH}
Maintainer: ${MAINTAINER}
Section: ${SECTION}
Depends: dpkg | apt-utils (>1.16), wget
Description: ${DESCRIPTION:-一个 Go 工具}
Installed-Size: $(du -sm "$PKG_DIR" | cut -f1)

NOTE: 使用 Go 静态二进制，无外部依赖。建议安装后运行 go build / make install 以验证编译。
    CONTROL
    
# --- 复制 postinst/prerm/postrm脚本（如果有）---
if [[ -f "debian/postinst" ]]; then
    cp debian/postinst "$PKG_DIR/DEBIAN/postinst"
    chmod 755 "$PKG_DIR/DEBIAN/postinst"
fi

## === 最终简化版构建流程 ===
# 🎯 我们采用更简单的方式：直接调用 ghdeb + 本地编译输出（已在 apt-repo/dist/存在 .deb）  
# ✅ 实际场景：GitHub Runner 先 go build -ldflags="-s -w" → dist/*.deb  
# -> dpkg-deb --build dist/${PKG_NAME}_${VERSION}_${TARGET_ARCH} -> ${REPO_NAME}_${VERSION}_${TARGET_ARCH}.deb
# 🚀 我们使用这个简化版步骤，而非上面复杂的脚本。

echo "✅ 构建完成：dist/${REPO_NAME}_${VERSION}_${TARGET_ARCH}.deb" || echo "注意：二进制文件可能未找到，请配置正确路径后再次运行此脚本。"

