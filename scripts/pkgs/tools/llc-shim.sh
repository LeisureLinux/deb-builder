#!/bin/sh
# llc 适配层：把上游 ebpf_prog/Makefile 的 llc 调用翻译成 clang 的 BPF 后端。
#
# 上游是两步编译：clang -emit-llvm -c prog.c → prog.bc，再 llc -march=bpf → prog.o。
# 本机/CI 上可能只装了 clang（没装 llvm 包的 llc），此时用 clang -target bpf 直接
# 从 bitcode 生成 BPF 目标文件，产物等价。
#
# 调用形如: llc -march=bpf -mcpu=generic -filetype=obj -o OUT IN.bc
set -eu

out=""; inp=""; mcpu="generic"
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="${2:-}"; shift 2 ;;
    -mcpu=*) mcpu="${1#-mcpu=}"; shift ;;
    -march=*|-filetype=*|-O[0-9]*) shift ;;
    *) inp="$1"; shift ;;
  esac
done

if [ -z "$out" ] || [ -z "$inp" ]; then
  echo "llc-shim: 参数不完整 (out='$out' in='$inp')" >&2
  exit 1
fi

# -c 必须加：否则 clang 会走链接阶段，把 EM_BPF 目标文件喂给 ld 而报
# "Relocations in generic ELF (EM: 247)"。
exec clang -target bpf -mcpu="$mcpu" -O2 -c -o "$out" "$inp"
