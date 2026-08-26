#!/bin/bash
# build-one.sh: 为单个 recipe 构建 .deb（多架构）
# 用法: ./scripts/build-one.sh <package_name>
PKG_NAME="${1:?Usage: $0 <package_name>}"
set -euo pipefail

cd "$(dirname "$0")/.." || exit 1

recipe="recipes/${PKG_NAME}.yaml"
if [[ ! -f "$recipe" ]]; then
    echo "⏭️ Recipe not found for $PKG_NAME at $recipe（跳过；如需构建请先补充 recipe）" >&2
    # exit 2 = skipped：CI 中与禁用包同等处理（干净跳过，不报失败）；
    # 扫描器仍会将其作为缺口上报 issue，提醒补 recipe
    exit 2
fi

# 已声明禁用的 recipe：跳过（exit 2 = skipped），不视为失败
if grep -qE '^disabled:[[:space:]]*true' "$recipe"; then
    reason=$(grep '^disabled:' "$recipe" | head -1 | sed 's/^disabled:[[:space:]]*true[[:space:]]*//')
    echo "⏭️  Skipping ${PKG_NAME} (disabled)${reason:+: $reason}" >&2
    exit 2
fi

# 从 recipe 的 target_arches 解析真实架构列表（不再传空 "" 导致不构建）
# 允许用环境变量 ARCHS 覆盖（用于测试指定架构）
ARCHS=$(awk '/^target_arches:/{flag=1; next} /^[^[:space:]]/ && flag{exit} flag && /^[[:space:]]*- /{sub(/^[[:space:]]*- /,""); print $1}' "$recipe" | paste -sd, -)
ARCHS="${ARCHS:-amd64}"
if [[ -n "${ARCHS_OVERRIDE:-}" ]]; then
    echo "⚙️  Arch override from env: ${ARCHS_OVERRIDE}" >&2
    ARCHS="$ARCHS_OVERRIDE"
fi

echo "🏗️  Building ${PKG_NAME} for arches: ${ARCHS} ..." >&2
bash scripts/build-go-deb.sh "$PKG_NAME" "$ARCHS" "${BINARY_PATH:-}"
echo "✅ Built ${PKG_NAME}"
