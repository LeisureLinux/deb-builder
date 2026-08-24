#!/bin/bash
# build-all.sh: 为所有 recipes 构建 .deb（多架构）
# 任一步失败都会让脚本以非零退出，便于 CI 及时发现。
set -euo pipefail

cd "$(dirname "$0")/.." || exit 1

echo "🏗️  Building all GO packages for Freelamp APT Repository"
mkdir -p dist

built=0
failed=0
skipped=0

for recipe in recipes/*.yaml; do
    pkg="$(basename "$recipe" .yaml)"
    echo "========================================"
    echo "📦 Building: $pkg"
    if bash scripts/build-one.sh "$pkg"; then
        built=$((built+1))
        echo "✅ $pkg OK"
    else
        failed=$((failed+1))
        echo "❌ $pkg FAILED"
    fi
done

echo ""
echo "=== 汇总 ==="
echo "成功: $built  失败: $failed  跳过: $skipped"
[[ "$failed" -eq 0 ]]
