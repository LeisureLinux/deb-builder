#!/bin/bash
# build-all.sh: 为所有 recipes 构建 .deb
set -euo pipefail

for recipe in recipes/*.yaml; do
    echo "========================================"
    echo "🏗️  Building $(basename "$recipe" .yaml)..."
    
    # 使用 YAML 解析器提取信息（需要 yq，这里用基础文本操作）
    repo=$(grep "^repo:" "$recipe" | awk '{print $2}')
    package_name=$(grep "^package:" "$recipe" | awk '{print $2}')
    go_version=$(grep "^go_version:" "$recipe" | awk '{print $2}' || echo "latest")
    
    # 调用通用构建函数（简化版）
    bash scripts/build-go-deb.sh "$repo" "${VERSION:-}"
done

echo "✅ 所有包构建完成！"
