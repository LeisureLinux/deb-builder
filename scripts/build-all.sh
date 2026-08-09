#!/bin/bash
# build-all.sh: 为所有 recipes 构建 .deb（多架构）
# 用法: ./scripts/build-all.sh [skip_build_list]
# 可选参数: 逗号分隔的跳过包名列表，如 "podman,ripgrep"
set -euo pipefail

SKIP_LIST="${1:-}"
build_failed=0
built=0
skipped=0

for recipe in recipes/*.yaml; do
    pkg="$(basename "$recipe" .yaml)"
    if [[ -n "$SKIP_LIST" ]] && [[ ",$SKIP_LIST," == *",$pkg,"* ]]; then
        echo "⏭️  Skipping $pkg (in skip list)"
        skipped=$((skipped+1))
        continue
    fi

    echo "========================================"
    echo "🏗️  Building $pkg ..."
    if bash scripts/build-go-deb.sh "$pkg" "" "${BINARY_PATH:-}"; then
        built=$((built+1))
        echo "✅ $pkg OK"
    else
        build_failed=$((build_failed+1))
        echo "❌ $pkg FAILED"
    fi
done

echo ""
echo "=== 汇总 ==="
echo "成功: $built  失败: $build_failed  跳过: $skipped"
[[ "$build_failed" -eq 0 ]]
