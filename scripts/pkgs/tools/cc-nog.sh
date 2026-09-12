#!/bin/sh
# clang 包装层：剔除上游 ebpf_prog/Makefile 里硬编码的 -g。
#
# 为什么需要：上游编完 .o 后会用 `llvm-strip -g` 去掉调试信息；当环境里没有
# llvm-strip（binutils 的 strip/objcopy 不认 EM_BPF，会报
# "Unable to recognise the format of the input file"）时，带 -g 的 .o 会比不带
# 大十倍（opensnitch.o 370KB vs 12KB）。干脆在编译期就不生成调试信息。
args=""
for a in "$@"; do
  case "$a" in
    -g|-g0|-g1|-g2|-g3|-ggdb|-ggdb0|-ggdb1|-ggdb2|-ggdb3) continue ;;
    *) args="$args $a" ;;
  esac
done
# shellcheck disable=SC2086
exec clang $args
