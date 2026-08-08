#!/bin/bash
# 用法: ./scripts/curate.sh <owner/repo> <debian包名>
# 用 madison + GitHub Releases API 验证某包在目标矩阵里的真实缺口
set -euo pipefail
REPO="$1"
PKG="${2:-$(basename "$REPO")}"
SUITES=(bookworm trixie)
ARCHES=(amd64 arm64 armhf riscv64 loong64)

alias_of() {
    local suite="$1"
    while read -r a c; do
        [[ "$c" == "$suite" ]] && { echo "$a"; return; }
    done < "$(dirname "$0")/../conf/debian-aliases.txt"
}

echo "=== $REPO（Debian 包名: $PKG）==="
REL=$(curl -fsSL --max-time 30 "https://api.github.com/repos/$REPO/releases/latest")
TAG=$(echo "$REL" | jq -r '.tag_name // "无release"')
OFF=$(echo "$REL" | jq -r '[.assets[].name | select(endswith(".deb")) | capture("_(?<a>amd64|arm64|armhf|riscv64|loong64|i386|ppc64el|s390x)\\.").a] | unique | join(",")')
echo "  上游最新: $TAG   官方 .deb 架构: ${OFF:-无}"

declare -A DEBIAN_ARCHS
for suite in "${SUITES[@]}"; do
    alias="$(alias_of "$suite")"
    ARCHS=$(curl -fsSL --max-time 30 "https://api.ftp-master.debian.org/madison?package=$PKG&table=debian" \
        | awk -F'|' -v a="$alias" '$3 ~ a {gsub(/ /,"",$4); print $4; exit}')
    DEBIAN_ARCHS[$suite]="${ARCHS:-无}"
    echo "  Debian $suite 二进制: ${ARCHS:-无}"
done

echo "  缺口:"
for suite in "${SUITES[@]}"; do
    for a in "${ARCHES[@]}"; do
        in_deb="no"; in_off="no"
        [[ "${DEBIAN_ARCHS[$suite]:-}" == *"$a"* ]] && in_deb=yes
        [[ "${OFF:-}" == *"$a"* ]] && in_off=yes
        if [[ "$in_deb" == no && "$in_off" == no ]]; then
            echo "    🟢 $suite/$a"
        fi
    done
done
