#!/bin/bash
# 非 Go 包构建脚本（scripts/pkgs/*.sh）的共用工具。
#
# 这些脚本由 scripts/build-go-deb.sh 的 build_script 机制调用，此时以下环境变量已导出：
#   PKG_NAME VERSION FINAL_VERSION ARCHS_CSV OUTPUT_DIR RECIPE REPO_LINE UPGRADE_VERSION
#   SECTION MAINTAINER RECOMMENDS SUGGESTS EXTRA_ROOT CONTROL_DIR HOMEPAGE
#   COMMIT_HASH BINARY_NAME LDFLAGS
#
# 硬约束：脚本只允许写 /tmp 与 $OUTPUT_DIR（仓库的 dist/），
#         不写 /usr /etc /root 等系统目录 —— 所有文件都先落进"包根"（deb-root），
#         由 dpkg-deb 打包，安装期才由 dpkg 落到系统里。

GITHUB_REPO_BASE="${GITHUB_REPO_BASE:-https://github.com}"

_ts() { date +%Y%m%d%H%M%S; }
# 临时区：与 build-go-deb.sh 的 BUILD_TMPDIR 保持一致（默认 /tmp）
tmpbase() { printf '%s' "${TMPBASE:-/tmp}"; }
# 临时区的绝对路径。必须用这个来拼源码树/构建目录的路径：
# 脚本随后会 `cd` 进源码树，之后任何还在用 tmpbase() 相对路径的引用都会解析到
# 源码树内部去（例：cd $SRC 之后再 cd $SRC/ebpf_prog 会变成两份前缀）。
tmpabs() {
  local t; t="$(tmpbase)"
  case "$t" in
    /*) printf '%s' "$t" ;;
    *)  printf '%s/%s' "$PWD" "${t#./}" ;;
  esac
}

# 工作树是否真的检出来了。
# 这台机器上偶发"克隆成功但检出失败"：git 退出码是 0、HEAD 也对，但目录里只有
# .git，没有任何工作树文件。只看 git 的退出码会把这种半成品当成功，
# 后面的 make/编译就只会在每个候选上各失败一次。
_upstream_tree_ok() {
  local d="$1" f
  for f in "$d"/*; do
    [[ -e "$f" ]] && return 0
  done
  return 1
}

# clone_upstream <目标目录>  —— 克隆 $REPO_LINE 并 checkout $COMMIT_HASH（若有声明）
clone_upstream() {
  local dest="$1" repo="${REPO_LINE:?REPO_LINE 未设置}" ok=0 attempt
  for attempt in 1 2 3; do
    rm -rf "$dest"; mkdir -p "$dest"
    if git clone --depth 1 "${GITHUB_REPO_BASE}/${repo}.git" "$dest" 2>/dev/null \
       && _upstream_tree_ok "$dest"; then
      ok=1; break
    fi
    echo "⚠️  克隆第 $attempt 次失败或工作树为空，重试…" >&2
    rm -rf "$dest"; mkdir -p "$dest"; sleep 3
  done
  (( ok == 1 )) || { echo "❌ 克隆 ${GITHUB_REPO_BASE}/${repo}.git 失败（3 次重试）" >&2; return 1; }

  if [[ -n "${COMMIT_HASH:-}" ]]; then
    ( cd "$dest" && git fetch --depth 1 origin "$COMMIT_HASH" && git checkout --quiet "$COMMIT_HASH" ) \
      || { echo "❌ checkout ${COMMIT_HASH} 失败" >&2; return 1; }
    _upstream_tree_ok "$dest" || { echo "❌ checkout 后工作树为空（检出失败）" >&2; return 1; }
  fi
  echo "📌 源码: ${repo} @ $(cd "$dest" && git rev-parse --short HEAD)" >&2
}

# deb_write_control <包根> <架构> <摘要行> [扩展描述行...]
# 依赖：PKG_NAME FINAL_VERSION SECTION MAINTAINER HOMEPAGE REPO_LINE
#       DEPENDS / RECOMMENDS / SUGGESTS（可空，来自调用方脚本变量）
#       SUITES（可空）—— 见下方 XB-Suites 说明
deb_write_control() {
  local root="$1" arch="$2" synopsis="$3"; shift 3
  mkdir -p "$root/DEBIAN"
  {
    echo "Package: ${PKG_NAME}"
    echo "Version: ${FINAL_VERSION}"
    echo "Section: ${SECTION:-utils}"
    echo "Priority: optional"
    echo "Architecture: ${arch}"
    if [[ -n "${DEPENDS:-}" ]];    then echo "Depends: ${DEPENDS}"; fi
    if [[ -n "${RECOMMENDS:-}" ]]; then echo "Recommends: ${RECOMMENDS}"; fi
    if [[ -n "${SUGGESTS:-}" ]];   then echo "Suggests: ${SUGGESTS}"; fi
    # XB-Suites: 限定本包只发布到哪些发行版（逗号分隔 codename），空=全发行版。
    # 用 XB- 前缀是 Debian 政策给自定义字段留的位置，dpkg/aptly 都会原样保留。
    # 发布端（apt-repo/scripts/publish.sh）读这个字段做 per-suite 分流，
    # 这样"只发 trixie"这类信息就跟着 .deb 走，apt-repo 无需知道 recipe 的细节。
    if [[ -n "${SUITES:-}" ]]; then echo "XB-Suites: ${SUITES}"; fi
    echo "Maintainer: ${MAINTAINER:-LeisureLinux <albertxu@freelamp.com>}"
    echo "Homepage: ${HOMEPAGE:-${GITHUB_REPO_BASE}/${REPO_LINE}}"
    echo "Description: ${synopsis}"
    local line
    for line in "$@"; do echo " ${line}"; done
  } > "$root/DEBIAN/control"
}

# deb_apply_extra <包根> —— 叠加 $EXTRA_ROOT 目录树、复制 $CONTROL_DIR 控制文件
deb_apply_extra() {
  local root="$1" cf bn
  if [[ -n "${EXTRA_ROOT:-}" ]]; then
    if [[ -d "$EXTRA_ROOT" ]]; then
      cp -a "$EXTRA_ROOT/." "$root/"
      echo "➕ extra_root overlay: $EXTRA_ROOT" >&2
    else
      echo "⚠️  extra_root 不存在，跳过: $EXTRA_ROOT" >&2
    fi
  fi
  if [[ -n "${CONTROL_DIR:-}" ]]; then
    if [[ -d "$CONTROL_DIR" ]]; then
      for cf in "$CONTROL_DIR"/*; do
        [[ -e "$cf" ]] || continue
        bn="$(basename "$cf")"
        case "$bn" in
          postinst|preinst|prerm|postrm|config|triggers) chmod 0755 "$cf" ;;
        esac
        cp -a "$cf" "$root/DEBIAN/$bn"
      done
      echo "➕ control files from: $CONTROL_DIR" >&2
    else
      echo "⚠️  control_dir 不存在，跳过: $CONTROL_DIR" >&2
    fi
  fi
}

# deb_finalize <包根> <架构> —— 产出 $OUTPUT_DIR/<包名>_<版本>_<架构>.deb
deb_finalize() {
  local root="$1" arch="$2"
  local out="${OUTPUT_DIR:?OUTPUT_DIR 未设置}/${PKG_NAME}_${FINAL_VERSION}_${arch}.deb"
  mkdir -p "$OUTPUT_DIR"
  dpkg-deb --build --root-owner-group "$root" "$out" >/dev/null
  echo "✅ Created: $out" >&2
  echo "$out"
}

# bpf_sections <文件...> —— 解析 eBPF ELF 的挂载点段名（binutils 不认 EM_BPF，用 python 读）
bpf_sections() {
  /usr/bin/python3 - "$@" <<'PY'
import struct, sys
rc = 0
for path in sys.argv[1:]:
    try:
        d = open(path, 'rb').read()
    except OSError as e:
        print(f"{path}: 无法读取: {e}"); rc = 1; continue
    if d[:4] != b'\x7fELF':
        print(f"{path}: 不是 ELF"); rc = 1; continue
    e_shoff, = struct.unpack_from('<Q', d, 0x28)
    e_shentsize, e_shnum, e_shstrndx = struct.unpack_from('<HHH', d, 0x3a)

    # Elf64_Shdr: name, type, flags, addr, offset, size, link, info, addralign, entsize
    def sh(i):
        return struct.unpack_from('<IIQQQQIIQQ', d, e_shoff + i * e_shentsize)

    # .shstrtab 的表头偏移是 shdr[shstrndx].offset（第 5 个字段）
    stroff = sh(e_shstrndx)[4]
    secs = []
    for i in range(e_shnum):
        n = sh(i)[0]
        end = d.index(b'\0', stroff + n)
        secs.append((d[stroff + n:end].decode(), sh(i)[5]))

    # 判定"程序段"用排除法，不用白名单：
    # eBPF 程序的挂载点段名会随 hook 类型变化（kprobe/、tracepoint/、uprobe/、
    # uretprobe/、fentry/、xdp、tc、cgroup/、lsm/ …），上游 opensnitch 就用到了
    # uprobe/ 与 uretprobe/ 来拦 DNS。白名单一漏就会把好模块判成坏模块。
    # 规则：非点号开头、不在已知元数据段里、且长度非 0 的段，就是程序段。
    META = {"license", "version", "license_ext", "maps", "BTF", "BTF.ext", "data", "rodata"}
    progs = [n for n, sz in secs if n and not n.startswith(".") and n not in META and sz > 0]

    print(f"{path}: 段数={e_shnum} 程序段={len(progs)} {progs}")
    if not progs:
        print(f"  ⚠️  {path} 没有任何程序段，编译参数可能不对"); rc = 1
sys.exit(rc)
PY
}
