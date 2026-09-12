#!/bin/bash
# opensnitch-ebpf-modules —— opensnitch 的 eBPF 内核态模块
#
# 由 scripts/build-go-deb.sh 的 build_script 机制调用。
#
# 为什么必须自建：上游 release 只发 opensnitch / python3-opensnitch-ui 的 .deb，
# eBPF 模块只在它自己的 CI 里编成 artifact，不是发布资产。（Debian 官方是把它拆成
# 独立二进制包 opensnitch-ebpf-modules。）
#
# 关键约束：
#   1. ebpf_prog/Makefile 走 clang -emit-llvm → llc -march=bpf 两步编译，
#      **不是 CO-RE**：结构体偏移在编译期由内核头文件固化，所以必须用"发行版内核"
#      的头文件编，且换内核大版本要重编。
#   2. 需要 clang（含 BPF 后端）+ 内核头文件。llc / llvm-strip 缺失时用 tools/ 下的
#      适配脚本替代（clang -target bpf 直接 codegen、编译期去掉 -g 控体积）。
#   3. 只有部分架构支持：上游白名单是 amd64/arm64/riscv64/s390x/loong64/ppc64
#      （i386/armhf 不构建）。且 eBPF 模块的目标架构必须与构建机一致
#      （Makefile 的 KERNEL_ARCH 取自 uname -m，头文件也是按本机架构取的）。
#      因此本脚本只构建"构建机原生架构"对应的包，其余如实跳过。
#   4. daemon 默认配置 ProcMonitorMethod=ebpf，缺这个包进程监控会退化。
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./common.sh
. "$HERE/common.sh"

TOOLS="$HERE/tools"
PKG_ROOT_NAME="opensnitch-ebpf-modules"

# 上游支持的架构白名单（见 Debian debian/rules 与 ebpf_prog/Makefile）
ebpf_supported() {
  case "$1" in
    amd64|arm64|riscv64|s390x|loong64|ppc64) return 0 ;;
    *) return 1 ;;
  esac
}

# 目标架构 → 构建机需要满足的 uname -m
host_arch_for() {
  case "$1" in
    amd64)   echo x86_64 ;;
    arm64)   echo aarch64 ;;
    riscv64) echo riscv64 ;;
    s390x)   echo s390x ;;
    loong64) echo loongarch64 ;;
    ppc64)   echo ppc64le ;;
    *)       echo "" ;;
  esac
}

# 内核头文件候选：输出 "版本 内核目录 头文件目录" 三元组。
# 优先显式 KERNEL_VER；否则按 /lib/modules 的版本倒序，凡是能解析出
# include/linux/kconfig.h 的都算候选（构建时逐个试，第一个编过的采用）。
#
# 排序分两档：发行版自带的头文件（Debian/Ubuntu 的 linux-headers-* 会建
# /lib/modules/<v>/source 软链）排前面，第三方内核（xanmod/cachyos 之类，
# 通常只有 build 软链）排后面。原因：这个包对内核结构体布局敏感，
# 用第三方新内核头文件编出来的模块偏移量是按那个内核固化的，
# 装到 Debian 6.12 上可能挂不上去；而"发布到 Debian 仓库"的目标机器
# 绝大多数跑的是发行版内核。
kernel_candidates() {
  # 输出 "版本<TAB>内核目录<TAB>头文件目录"，按优先级排序：
  #   官方头文件（/lib/modules/<v>/source → 与运行内核同代，最可靠）排在前面，
  #   其次是 build 软链与 /usr/src 下的其它目录。
  # 显式给了 KERNEL_VER 时只认它。
  #
  # 为什么要额外扫 /usr/src：
  #   某些环境（典型是 CI 里 apt install linux-headers-generic）只装头文件、不装
  #   对应内核，于是 /usr/src/linux-headers-<v> 存在而 /lib/modules/<v> 根本没有 ——
  #   只按 /lib/modules 枚举版本会把这种可用头文件整个漏掉。
  local -a seen=() primary=() fallback=()
  local kv kd kh d v

  add_cand() {  # $1=版本 $2=内核目录 $3=头文件目录 $4=是否官方(1/0)
    local i
    for i in "${seen[@]}"; do [[ "$i" == "$1" ]] && return 0; done
    seen+=("$1")
    if (( ${4:-0} )); then primary+=("$(printf '%s\t%s\t%s' "$1" "$2" "$3")")
    else                    fallback+=("$(printf '%s\t%s\t%s' "$1" "$2" "$3")")
    fi
  }

  local vers
  if [[ -n "${KERNEL_VER:-}" ]]; then
    vers="$KERNEL_VER"
  else
    vers="$(ls -1 /lib/modules 2>/dev/null | sort -Vr)"
  fi

  while IFS= read -r kv; do
    [[ -z "$kv" ]] && continue
    for kd in "/lib/modules/$kv/source" "/lib/modules/$kv/build" "/usr/src/linux-headers-$kv"; do
      if [[ -f "$kd/include/linux/kconfig.h" ]]; then
        kh="/usr/src/linux-headers-$kv/"
        [[ -d "$kh" ]] || kh="$kd/"
        if [[ "$kd" == "/lib/modules/$kv/source" ]]; then
          add_cand "$kv" "$kd" "$kh" 1
        else
          add_cand "$kv" "$kd" "$kh" 0
        fi
        break
      fi
    done
  done <<< "$vers"

  # 兜底：扫 /usr/src 下不在 /lib/modules 里的头文件目录。
  # 带 -common/-headers 后缀的是辅助目录（只有 include/ 的一部分），跳过。
  if [[ -z "${KERNEL_VER:-}" ]]; then
    while IFS= read -r d; do
      [[ -z "$d" || "$d" == *-common ]] && continue
      [[ -f "$d/include/linux/kconfig.h" ]] || continue
      v="$(basename "$d")"; v="${v#linux-headers-}"
      [[ -z "$v" ]] && continue
      add_cand "$v" "$d/" "$d/" 0
    done <<< "$(ls -1d /usr/src/linux-headers-* 2>/dev/null | sort -Vr)"
  fi

  if (( ${#primary[@]} )); then printf '%s\n' "${primary[@]}"; fi
  if (( ${#fallback[@]} )); then printf '%s\n' "${fallback[@]}"; fi
  return 0
}

TS="$(_ts)"
TMPROOT="$(tmpabs)"
SRC="$TMPROOT/${PKG_NAME}-src-${TS}"
BASE="$TMPROOT/build-${PKG_NAME}-${TS}"
cleanup() {
  # KEEP_TMP=1 保留临时区，用于排查编译/校验问题
  [[ -n "${KEEP_TMP:-}" ]] && { echo "🔍 KEEP_TMP=1，保留临时区: $TMPROOT" >&2; return 0; }
  rm -rf "$SRC" "$BASE" 2>/dev/null || true
}
trap cleanup EXIT

# ---------- 依赖自检 ----------
command -v clang >/dev/null || { echo "❌ 需要 clang（含 BPF 后端）：apt install clang" >&2; exit 1; }
if ! clang -print-targets 2>/dev/null | grep -qE '^\s*bpf(-el|-eb)?\s'; then
  echo "❌ 当前 clang 没有 BPF 后端，无法编译 eBPF 模块" >&2
  exit 1
fi

clone_upstream "$SRC"
cd "$SRC"

# 克隆完整性自检：clone_upstream 只看 git 的退出码，而这台机器上偶发出现
# "克隆成功但检出失败"（工作树是空的）。少了这个检查，后面的 make 只会在
# 每个内核候选上失败一次，最后报一句含糊的"所有候选都编译失败"。
if [[ ! -d "$SRC/ebpf_prog" ]]; then
  echo "❌ 源码树不完整：$SRC/ebpf_prog 不存在（克隆/检出失败）" >&2
  echo "   常见原因：临时区所在文件系统异常，试试 BUILD_TMPDIR 指到别处" >&2
  exit 1
fi

# ---------- 逐架构构建 ----------
OK_COUNT=0
FAILED_ARCHES=()
SKIPPED_ARCHES=()

IFS=',' read -ra WANT <<< "${ARCHS_CSV:-amd64}"
for ARCH in "${WANT[@]}"; do
  ARCH="$(echo "$ARCH" | tr -d ' ')"
  [[ -z "$ARCH" ]] && continue

  if ! ebpf_supported "$ARCH"; then
    echo "⚠️  eBPF 模块不支持 ${ARCH}（上游白名单：amd64 arm64 riscv64 s390x loong64 ppc64）；跳过" >&2
    SKIPPED_ARCHES+=("$ARCH"); continue
  fi
  need_host="$(host_arch_for "$ARCH")"
  if [[ "$(uname -m)" != "$need_host" ]]; then
    echo "⚠️  ${ARCH} 的 eBPF 模块需要在 ${need_host} 机器上构建（头文件与 KERNEL_ARCH 都按构建机取）；当前是 $(uname -m)，跳过" >&2
    SKIPPED_ARCHES+=("$ARCH"); continue
  fi

  # 本机没有 /dev/fd，`< <(...)` 不可用；候选列表一次性取到变量里再用 here-string
  CANDIDATES="$(kernel_candidates)"
  if [[ -z "$CANDIDATES" ]]; then
    echo "❌ 找不到可用的内核头文件（需要 include/linux/kconfig.h）。" >&2
    echo "   Debian/Ubuntu: apt install linux-headers-\$(dpkg --print-architecture)" >&2
    FAILED_ARCHES+=("$ARCH"); continue
  fi

  ( cd "$SRC/ebpf_prog" && make clean >/dev/null 2>&1 || true )

  built_kv=""
  while IFS=$'\t' read -r kv kd kh; do
    [[ -z "$kv" ]] && continue
    echo "🔨 eBPF (${ARCH}): KERNEL_VER=$kv" >&2
    echo "   KERNEL_DIR=$kd" >&2
    echo "   KERNEL_HEADERS=$kh" >&2
    ( cd "$SRC/ebpf_prog" && make clean >/dev/null 2>&1 || true )
    if ( cd "$SRC/ebpf_prog" && \
         make KERNEL_VER="$kv" KERNEL_DIR="$kd" KERNEL_HEADERS="$kh" \
              CC="$TOOLS/cc-nog.sh" LLC="$TOOLS/llc-shim.sh" LLVM_STRIP=true \
              > "$BASE-ebpf-$ARCH.log" 2>&1 ); then
      built_kv="$kv"
      break
    fi
    echo "⚠️  用内核 $kv 的头文件编译失败，试下一个候选（日志: $BASE-ebpf-$ARCH.log）" >&2
  done <<< "$CANDIDATES"

  if [[ -z "$built_kv" ]]; then
    echo "❌ 所有内核头文件候选都编译失败" >&2
    tail -20 "$BASE-ebpf-$ARCH.log" >&2 2>/dev/null || true
    FAILED_ARCHES+=("$ARCH"); continue
  fi

  MODS=( "$SRC"/ebpf_prog/opensnitch*.o )
  if (( ${#MODS[@]} == 0 )) || [[ ! -f "${MODS[0]}" ]]; then
    echo "❌ 没有产出 .o 文件" >&2
    FAILED_ARCHES+=("$ARCH"); continue
  fi

  # 产物校验：每个 .o 都要有程序段（kprobe/ / uprobe/ / tracepoint/ …），
  # 否则 daemon 加载时挂不上去。opensnitch-dns.o 用的是 uprobe/uretprobe/，
  # 别按"只有 kprobe"来判。
  if ! bpf_sections "${MODS[@]}"; then
    echo "❌ eBPF 模块校验失败（有 .o 不含任何程序段）" >&2
    FAILED_ARCHES+=("$ARCH"); continue
  fi

  ROOT="$BASE-$ARCH/deb-root"
  rm -rf "$ROOT"
  mkdir -p "$ROOT/usr/lib/opensnitchd/ebpf"
  cp "${MODS[@]}" "$ROOT/usr/lib/opensnitchd/ebpf/"
  chmod 0644 "$ROOT"/usr/lib/opensnitchd/ebpf/*.o

  # 记录编译所用的内核头文件版本：这个包对内核 ABI 敏感，出问题时这是第一手线索
  mkdir -p "$ROOT/usr/share/doc/$PKG_ROOT_NAME"
  {
    echo "opensnitch-ebpf-modules 编译信息"
    echo "  上游:        ${REPO_LINE} @ ${COMMIT_HASH:-unknown}"
    echo "  目标架构:    ${ARCH}"
    echo "  构建机架构:  $(uname -m)"
    echo "  构建机内核:  $(uname -r)"
    echo "  编译用内核头文件版本: ${built_kv}"
    echo "  头文件目录:  $(awk -F'\t' -v v="$built_kv" '$1==v{print $2}' <<< "$CANDIDATES")"
    echo ""
    echo "注意：eBPF 模块不是 CO-RE 编译的，结构体偏移在编译期由上述内核头文件固化。"
    echo "在差异较大的内核上运行时可能加载失败，此时可改用 daemon 的 proc 监控方式："
    echo "  编辑 /etc/opensnitchd/default-config.json，把 \"ProcMonitorMethod\" 改为 \"proc\""
  } > "$ROOT/usr/share/doc/$PKG_ROOT_NAME/BUILD-KERNEL"

  deb_write_control "$ROOT" "$ARCH" \
    "GNU/Linux interactive application firewall eBPF modules" \
    "opensnitch-ebpf-modules provides the eBPF modules used by the opensnitch" \
    "daemon to intercept connections at kernel level, which offers better" \
    "performance and reliability than the userspace process monitor." \
    "." \
    "The modules are installed into /usr/lib/opensnitchd/ebpf/ and loaded by" \
    "opensnitchd when ProcMonitorMethod is set to \"ebpf\" (the default)."
  deb_apply_extra "$ROOT"
  deb_finalize "$ROOT" "$ARCH"
  OK_COUNT=$((OK_COUNT+1))
done

# ---------- 汇总 ----------
if (( OK_COUNT == 0 )); then
  if (( ${#SKIPPED_ARCHES[@]} > 0 )) && (( ${#FAILED_ARCHES[@]} == 0 )); then
    echo "⏭️  所有目标架构都被跳过（${SKIPPED_ARCHES[*]}）：eBPF 模块只支持在原生架构上构建" >&2
    exit 2
  fi
  echo "💥 eBPF 模块构建失败: ${FAILED_ARCHES[*]}" >&2
  exit 1
fi
if (( ${#FAILED_ARCHES[@]} > 0 )); then
  echo "⚠️  部分架构失败: ${FAILED_ARCHES[*]}" >&2
fi
echo "🎉 opensnitch-ebpf-modules 完成: ${OK_COUNT} 个架构" >&2
