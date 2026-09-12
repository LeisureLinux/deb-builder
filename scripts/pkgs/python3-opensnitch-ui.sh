#!/bin/bash
# python3-opensnitch-ui —— opensnitch 的图形界面（Python + PyQt6），架构无关（Architecture: all）
#
# 由 scripts/build-go-deb.sh 的 build_script 机制调用。
#
# 为什么不直接重托管上游 release 里的 .deb：
#   upstream 发布的是 python3-opensnitch-ui_1.8.0-1_all.deb，版本号与本仓库自建的
#   opensnitch_1.8.0+LL 不一致。daemon 与 UI 之间做版本校验，版本号不统一会告警，
#   所以这里从同一份源码树、同一个 commit 自建，版本走同一套 +LL 规则。
#
# 不依赖 setuptools/pip：按 ui/setup.py 的 packages/data_files/scripts 定义手工铺包根，
# 结果与上游 deb 的布局一致，但完全可复现、不联网装依赖。
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./common.sh
. "$HERE/common.sh"

TS="$(_ts)"
TMPROOT="$(tmpabs)"
SRC="$TMPROOT/${PKG_NAME}-src-${TS}"
ROOT="$TMPROOT/build-${PKG_NAME}-all-${TS}/deb-root"
cleanup() { rm -rf "$SRC" "$TMPROOT/build-${PKG_NAME}-all-${TS}" 2>/dev/null || true; }
trap cleanup EXIT

clone_upstream "$SRC"
cd "$SRC"

# 克隆完整性自检（同 opensnitch-ebpf-modules.sh：只看 git 退出码不够可靠）
if [[ ! -d "$SRC/ui/opensnitch" ]]; then
  echo "❌ 源码树不完整：$SRC/ui/opensnitch 不存在（克隆/检出失败）" >&2
  exit 1
fi

# ---------- 1. 翻译文件 ----------
# 上游 ui/i18n/ 下已经提交了 25 个语种的 .ts（含 zh_Hans / zh_TW），
# 打包只需要把它们编译成 .qm。加载路径见 opensnitch/utils/languages.py：
#   <pkg>/opensnitch/i18n/<lang>/opensnitch-<lang>.qm
#
# lrelease 从哪来（按优先级探测，全部失败则降级为"只有英文界面"）：
#   $LRELEASE 覆盖 → PATH 上的 lrelease-qt6/lrelease → /usr/lib/qtN/bin/lrelease
#   → python3 装好的 PySide6 自带的那一份（PySide6/lrelease）
# 注意：Debian 的 /usr/bin/lrelease 常常只是 qtchooser 存根（真实二进制在
# qt6-l10n-tools 里），所以必须真的跑一次 -version 验证，不能只看文件是否存在。
#
# 刻意不走 ui/i18n/Makefile：它还会用 pylupdate6 重新生成 .ts，
# 那是上游开发期的事，打包用已提交的 .ts 更可复现（漏翻的串会回落成原文）。
find_lrelease() {
  local cand bin out
  local -a cands=()
  [[ -n "${LRELEASE:-}" ]] && cands+=("$LRELEASE")
  command -v lrelease-qt6 >/dev/null 2>&1 && cands+=("$(command -v lrelease-qt6)")
  command -v lrelease-qt5 >/dev/null 2>&1 && cands+=("$(command -v lrelease-qt5)")
  command -v lrelease     >/dev/null 2>&1 && cands+=("$(command -v lrelease)")
  cands+=(/usr/lib/qt6/bin/lrelease /usr/lib/qt5/bin/lrelease)
  # PySide6 自带的 lrelease（pip/系统包都可能装到奇怪的位置，用 python 问最准）
  local pyside
  pyside="$(/usr/bin/python3 -c 'import PySide6,os;print(os.path.dirname(PySide6.__file__))' 2>/dev/null || true)"
  [[ -n "$pyside" ]] && cands+=("$pyside/lrelease")
  cands+=("$HOME"/.local/lib/python3*/site-packages/PySide6/lrelease)
  cands+=(/home/*/.local/lib/python3*/site-packages/PySide6/lrelease)

  for bin in "${cands[@]}"; do
    [[ -n "$bin" && -x "$bin" ]] || continue
    out="$("$bin" -version 2>&1 | head -n1)"
    # qtchooser 存根会输出 "lrelease: could not exec ..."
    case "$out" in
      *"lrelease version"*) printf '%s' "$bin"; return 0 ;;
    esac
  done
  return 1
}

LREL="$(find_lrelease || true)"
if [[ -n "$LREL" ]]; then
  echo "🌐 lrelease: $LREL ($("$LREL" -version 2>&1 | head -n1))" >&2

  # 用本仓库维护的补全版覆盖上游 zh_Hans。
  # 原因：上游 v1.8.0 的 ui/i18n/locales/zh_Hans/ 基本是空壳——771 条 message 里
  # 只有 2 条真正翻译过，而且有 8 条"已完成"的其实是西班牙语（Habilitar、Protocolo、
  # 30 segundos ...，显然是从 es.ts 误粘过来的），这些会直接进 .qm，界面上一半西语。
  # 本仓库的补全版把简中做到 557 条译文（556 finished），仅数字/路径等 92 条回落英文源串。
  # 若上游将来 bump 版本、新增了字符串，这里的条数对不上时会告警提示需要同步。
  ZH_TS="$HERE/opensnitch/i18n/opensnitch-zh_Hans.ts"
  UP_TS="ui/i18n/locales/zh_Hans/opensnitch-zh_Hans.ts"
  if [[ -f "$ZH_TS" ]]; then
    our_msgs="$(grep -c '<message' "$ZH_TS")"
    if [[ -f "$UP_TS" ]]; then
      up_msgs="$(grep -c '<message' "$UP_TS")"
      if (( up_msgs > our_msgs )); then
        echo "⚠️  上游 zh_Hans 有 $up_msgs 条 message，本仓库补全版只有 $our_msgs 条" >&2
        echo "    上游新增了待翻译字符串，建议同步 scripts/pkgs/opensnitch/i18n/opensnitch-zh_Hans.ts" >&2
      fi
    fi
    install -Dm644 "$ZH_TS" "$UP_TS"
    echo "🌐 zh_Hans 已替换为补全版（${our_msgs} 条 message）" >&2
  fi

  qm=0
  for ts in ui/i18n/locales/*/opensnitch-*.ts; do
    [[ -f "$ts" ]] || continue
    lang="$(basename "$(dirname "$ts")")"
    mkdir -p "ui/opensnitch/i18n/$lang"
    if "$LREL" "$ts" -qm "ui/opensnitch/i18n/$lang/opensnitch-$lang.qm" >/dev/null 2>&1; then
      qm=$((qm+1))
    else
      echo "⚠️  $lang 编译失败，该语种回落为英文" >&2
    fi
  done
  echo "🌐 翻译文件: ${qm} 个语种" >&2
else
  echo "⚠️  找不到可用的 lrelease，本次只提供英文界面（不影响功能）" >&2
  echo "    补齐方式（任一）:" >&2
  echo "      sudo apt install qt6-l10n-tools" >&2
  echo "      pip install PySide6   # 自带 lrelease，脚本会自动发现" >&2
fi

# ---------- 2. Python 包体 ----------
PKGDIR="$ROOT/usr/lib/python3/dist-packages"
mkdir -p "$PKGDIR"
cp -a ui/opensnitch "$PKGDIR/opensnitch"

# 上游 setup.py 用 find_packages() + package_data：没有 __init__.py 的目录不算包，
# 所以 plugins/*/example/（样例 json）不会进包，这里显式剔除以对齐上游产物。
rm -rf "$PKGDIR"/opensnitch/plugins/*/example
find "$PKGDIR" -name '__pycache__' -type d -prune -exec rm -rf {} + 2>/dev/null || true
find "$PKGDIR" -name '*.pyc' -delete 2>/dev/null || true

# opensnitch/utils/languages.py 的 get_all() 里是裸的 os.listdir(i18n)，没有异常保护；
# 目录不存在会让"首选项"对话框直接抛错。所以无论如何都要有这个目录。
mkdir -p "$PKGDIR/opensnitch/i18n"

# ---------- 3. 入口脚本 ----------
install -Dm755 ui/bin/opensnitch-ui "$ROOT/usr/bin/opensnitch-ui"
# 源码里的 shebang 是 /usr/bin/env python3，系统包固定用系统解释器
sed -i '1s|^#!.*|#!/usr/bin/python3|' "$ROOT/usr/bin/opensnitch-ui"

# ---------- 4. data_files（对齐 ui/setup.py 的 data_files）----------
install -Dm644 ui/resources/opensnitch_ui.desktop                       "$ROOT/usr/share/applications/opensnitch_ui.desktop"
install -Dm644 ui/resources/kcm_opensnitch.desktop                      "$ROOT/usr/share/kservices5/kcm_opensnitch.desktop"
install -Dm644 ui/resources/icons/opensnitch-ui.svg                     "$ROOT/usr/share/icons/hicolor/scalable/apps/opensnitch-ui.svg"
install -Dm644 ui/resources/icons/48x48/opensnitch-ui.png               "$ROOT/usr/share/icons/hicolor/48x48/apps/opensnitch-ui.png"
install -Dm644 ui/resources/icons/64x64/opensnitch-ui.png               "$ROOT/usr/share/icons/hicolor/64x64/apps/opensnitch-ui.png"
install -Dm644 ui/resources/io.github.evilsocket.opensnitch.appdata.xml "$ROOT/usr/share/metainfo/io.github.evilsocket.opensnitch.appdata.xml"

# ---------- 5. control ----------
deb_write_control "$ROOT" all \
  "GNU/Linux interactive application firewall GUI" \
  "opensnitch-ui is a GUI for opensnitch written in Python." \
  "It allows the user to view live outgoing connections, as well as search" \
  "for details of the intercepted connections." \
  "." \
  "The user can decide to block outgoing connections based on properties of" \
  "the connection: by port, by uid, by dst ip, by program or a combination" \
  "of them." \
  "." \
  "Once installed alongside opensnitch, rules can be managed from the GUI" \
  "instead of by hand."

deb_apply_extra "$ROOT"
deb_finalize "$ROOT" all
