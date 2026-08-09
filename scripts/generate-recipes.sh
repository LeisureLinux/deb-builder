#!/bin/bash
# generate-recipes.sh: 从扫描器候选生成 recipes/*.yaml
# 用法: bash scripts/generate-recipes.sh [candidates.json] [output_dir]
#   对每个 Homepage=github.com + Go 的包：
#     - 解析最新版本 tag（git ls-remote，排除预发布）
#     - 解析该 tag 对应的 commit hash（注入 control Description）
#     - 生成 recipes/<name>.yaml，target_arches = amd64,arm64,loong64,riscv64
set -euo pipefail

CAND="${1:-candidates.json}"
OUT_DIR="${2:-recipes}"
mkdir -p "$OUT_DIR"

command -v jq >/dev/null 2>&1 || { echo "❌ 需要 jq（apt install jq）" >&2; exit 1; }

total=$(jq 'length' "$CAND")
echo "📦 共 $total 个候选，生成 recipes → $OUT_DIR/"

declare -A seen
generated=0
skipped=0

# 每个候选输出为一行 JSON，交给 jq 逐条解析（避免 summary 含空格破坏 read）
jq -c '.[]' "$CAND" | while IFS= read -r line; do
    repo=$(jq -r '.repo' <<<"$line")
    name=$(jq -r '.name' <<<"$line")
    homepage=$(jq -r '.homepage' <<<"$line")
    summary=$(jq -r '.summary' <<<"$line")
    description=$(jq -r '.description // .summary' <<<"$line")
    section=$(jq -r '.section' <<<"$line")

    # 只处理合法 github.com 仓库（owner/repo）
    [[ "$homepage" == https://github.com/* ]] || continue
    [[ "$repo" == */* ]] || continue
    [[ "$repo" != *" "* ]] || continue
    [[ -z "$name" || "$name" == "null" ]] && continue
    # 跳过 Go 库包（-dev 结尾，无独立可执行二进制，无法打成可运行的 .deb）
    if [[ "$name" == *-dev ]]; then
        skipped=$((skipped+1)); continue
    fi
    if [[ -n "${seen[$repo]:-}" ]]; then
        skipped=$((skipped+1)); continue
    fi
    seen[$repo]=1

    # ---- 解析最新 tag 与 commit hash ----
    lsref=$(git ls-remote "https://github.com/${repo}.git" 'refs/tags/*' 2>/dev/null || true)
    # 排除带 ^{} 的 peeled 行与预发布（后缀），仅匹配 v1.2.3 形式
    tag=$(echo "$lsref" | awk '{print $2}' | grep -v '\^{}' \
        | grep -oE 'v?[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -1 || true)
    if [[ -z "$tag" ]]; then
        echo "   ⚠️  无稳定版本 tag，跳过: $repo"
        skipped=$((skipped+1)); continue
    fi
    # 优先取 peeled ref（^{}，即真实 commit SHA）；支持路径前缀 tag（如 codec/v1.3.2）
    sha=$(echo "$lsref" | awk -v t="$tag" '{
        r=$2; peeled=(index(r,"^{}")>0);
        if (peeled) r=substr(r,1,length(r)-3);
        n=split(r,a,"/"); base=a[n];
        if (base==t && peeled) { print $1; exit }
    }' | head -1)
    if [[ -z "$sha" ]]; then
        sha=$(echo "$lsref" | awk -v t="$tag" '{
            r=$2; if (index(r,"^{}")>0) r=substr(r,1,length(r)-3);
            n=split(r,a,"/"); base=a[n];
            if (base==t) { print $1; exit }
        }' | head -1)
    fi
    [[ -z "$sha" ]] && sha="unknown"
    # 版本号去掉前导 v（.deb 版本惯例）
    debver="${tag#v}"

    pkg="$name"
    cat > "$OUT_DIR/${pkg}.yaml" <<YAML
# ${pkg} 构建配方 (Phase 1 自动生成)
repo: ${repo}
package: ${pkg}
summary: "${summary}"
description: |
  $(printf '%s\n' "$description" | sed 's/^/  /')
homepage: ${homepage}
section: ${section:-utils}

# 版本策略：锁定上游最新稳定 tag，并在 control 里记录 commit hash
version_tag: "${tag}"
latest_tag: "${tag}"
commit_hash: "${sha}"
upstream_version: "${debver}"

# Go 构建配置
ldflags: "-s -w"

# 全架构打包
target_arches:
  - amd64
  - arm64
  - loong64
  - riscv64

maintainer: "LeisureLinux <albertxu@freelamp.com>"
depends: []
YAML
    generated=$((generated+1))
    echo "   ✅ ${pkg}  ${repo}  tag=${tag}  sha=${sha:0:8}"
done

echo ""
echo "✅ 生成 $generated 个 recipes（跳过 $skipped 个重复/无效）→ $OUT_DIR/"
