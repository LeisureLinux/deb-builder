#!/bin/bash
# xepub —— EPUB reader (Python + GTK3 + WebKitGTK 4.1, XApp)，Architecture: all
#
# 由 scripts/build-go-deb.sh 的 build_script 机制调用。
# 上游是标准 meson 项目，构建 = meson setup/compile/install 到包根（DESTDIR）。
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./common.sh
. "$HERE/common.sh"

TS="$(_ts)"
TMPROOT="$(tmpabs)"
SRC="$TMPROOT/${PKG_NAME}-src-${TS}"
ROOT="$TMPROOT/build-${PKG_NAME}-all-${TS}/deb-root"
MESON_BUILD="$TMPROOT/build-${PKG_NAME}-meson-${TS}"
cleanup() { rm -rf "$SRC" "$MESON_BUILD" "$TMPROOT/build-${PKG_NAME}-all-${TS}" 2>/dev/null || true; }
trap cleanup EXIT

# 0. 自包含装构建依赖。
#    build.yml 的 "Install build dependencies" 只装了 Go/eBPF 相关
#    （含 libglib2.0-dev，提供 glib-compile-schemas），没装 meson/ninja/gettext/
#    gtk-update-icon-cache 这一套。这里确保 CI runner（ubuntu-24.04，有免密 sudo）
#    和本机一致。已存在则跳过，不重复装。
if ! command -v meson >/dev/null 2>&1 || ! command -v ninja >/dev/null 2>&1 \
   || ! command -v msgfmt >/dev/null 2>&1 || ! command -v gtk-update-icon-cache >/dev/null 2>&1; then
  echo "🔧 安装 meson 构建依赖（meson/ninja-build/gettext/gtk-update-icon-cache）…" >&2
  sudo apt-get update -qq
  sudo apt-get install -y -qq meson ninja-build gettext gtk-update-icon-cache pkg-config >/dev/null \
    || echo "⚠️  安装失败，若本机已具备这些工具则可继续，否则后续步骤会失败" >&2
fi

clone_upstream "$SRC"
cd "$SRC"

# 完整性自检
if [[ ! -f "$SRC/xepub/main.py" ]]; then
  echo "❌ 源码树不完整：$SRC/xepub/main.py 不存在（克隆/检出失败）" >&2
  exit 1
fi

# 1. meson 构建并装进包根
#    --prefix=/usr 必须，否则默认装到 /usr/local。
#    DESTDIR 指向包根，meson install 把所有文件落到 $ROOT/usr/...
mkdir -p "$ROOT"
rm -rf "$MESON_BUILD"
meson setup "$MESON_BUILD" --prefix=/usr --buildtype=plain >/dev/null
meson compile -C "$MESON_BUILD" >/dev/null
DESTDIR="$ROOT" meson install -C "$MESON_BUILD" >/dev/null

# 2. 清理构建期生成的缓存文件（交给目标系统 dpkg trigger 重算，Debian 惯例）
#    - gschemas.compiled：glib_compile_schemas 产物，多包同目录会冲突
#    - icon-theme.cache：gtk-update-icon-cache 产物，hicolor 目录多包会冲突
rm -f "$ROOT/usr/share/glib-2.0/schemas/gschemas.compiled"
rm -f "$ROOT/usr/share/icons/hicolor/icon-theme.cache"
# 不随包发 .pyc（与 opensnitch-ui 约定一致）
find "$ROOT" -name '__pycache__' -type d -prune -exec rm -rf {} + 2>/dev/null || true
find "$ROOT" -name '*.pyc' -delete 2>/dev/null || true

# 3. /usr/bin/xepub 由 meson 从 data/xepub.in 生成（exec python3 /usr/share/xepub/main.py），无需改

# 4. control
deb_write_control "$ROOT" all \
  "Secure, paginated EPUB reader for the Linux desktop" \
  "Xepub is an XApp EPUB reader built with Python, PyGObject, GTK 3, XApp" \
  "and WebKitGTK 4.1. It enforces a strict Content-Security-Policy on book" \
  "resources and offers a comfortable, paginated reading experience that" \
  "works in any desktop environment and any distribution."

deb_apply_extra "$ROOT"
deb_finalize "$ROOT" all
