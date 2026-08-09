#!/bin/bash
# build-all.sh: 为所有 recipes 构建 .deb（多架构）
# 用法: ./scripts/build-all.sh [skip_build_list] [auto_clean]
#   参数1: 逗号分隔的跳过包名列表，如 "podman,ripgrep"
#   参数2: "clean" = 每个包构建完成后自动清理其克隆的源码目录（默认开启）
# 环境变量: KEEP_SRC=1 可关闭源码清理；OUTPUT_DIR 指定产物目录（默认 dist）
set -euo pipefail

SKIP_LIST="${1:-}"
AUTO_CLEAN="${2:-clean}"

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

    # 构建完成后清理该包的源码目录（默认开启，KEEP_SRC=1 可关）
    if [[ "$AUTO_CLEAN" == "clean" && "${KEEP_SRC:-}" != "1" ]]; then
        repo_line=$(grep -E '^repo:' "$recipe" | head -n1 | awk '{print $2}' | sed -e 's/^["'"'"']//' -e 's/["'"'"']$//')
        src_dir="${repo_line##*/}"
        if [[ -n "$src_dir" && -d "$src_dir" ]]; then
            echo "🧹  清理源码目录: $src_dir/"
            find "$src_dir" -depth -delete 2>/dev/null || true
        fi
    fi
done

echo ""
echo "=== 汇总 ==="
echo "成功: $built  失败: $build_failed  跳过: $skipped"
[[ "$build_failed" -eq 0 ]]
