#!/bin/bash
# check-updates.sh: 对比每个 recipe 的 latest_tag 与上游 GitHub 最新 release，
# 发现新版本时更新 recipe（latest_tag/version_tag/commit_hash/upstream_version），
# 输出变更包名列表到 $UPDATED_PKGS_FILE（每行一个），供 CI 逐个触发构建。
set -euo pipefail

cd "$(dirname "$0")/.."

UPDATED_FILE="${1:-/tmp/updated-pkgs.txt}"
: > "$UPDATED_FILE"

# 可选：用 GH_TOKEN 提升速率限制（CI 环境自动生效）
AUTH=()
[[ -n "${GH_TOKEN:-}" ]] && AUTH=(-H "Authorization: Bearer $GH_TOKEN")

norm_tag() { echo "${1#v}"; }
ver_gt() { # ver_gt A B: 归一化后 A > B 才返回真（防止向旧版本降级）
  local a b
  a=$(norm_tag "$1"); b=$(norm_tag "$2")
  [[ "$a" == "$b" ]] && return 1
  [[ "$(printf '%s\n%s\n' "$a" "$b" | sort -V | tail -1)" == "$a" ]]
}

for recipe in recipes/*.yaml; do
    pkg="$(basename "$recipe" .yaml)"
    # 跳过禁用的 recipe
    grep -qE '^disabled:[[:space:]]*true' "$recipe" && continue

    repo_line=$(grep '^repo:' "$recipe" | head -1 | awk '{print $2}' | tr -d '"' || true)
    old_tag=$(grep '^latest_tag:' "$recipe" 2>/dev/null | head -1 | sed 's/^latest_tag:[[:space:]]*//' | tr -d '"' || true)
    [[ -z "$repo_line" || -z "$old_tag" ]] && continue

    # 查询上游最新 release（无 release 的仓库跳过；pre-release 不算）
    api="https://api.github.com/repos/${repo_line}/releases/latest"
    new_tag=$(curl -sf --max-time 20 "${AUTH[@]}" "$api" | jq -r '.tag_name // empty' 2>/dev/null || true)
    [[ -z "$new_tag" || "$new_tag" == "null" ]] && continue
    # 仅当新版本确实大于当前锁定版本时才更新（防降级、忽略 v 前缀差异）
    ver_gt "$new_tag" "$old_tag" || continue

    # 取 tag 指向的 commit（annotated tag 需解引用）
    commit=""
    ref=$(curl -sf --max-time 20 "${AUTH[@]}" "https://api.github.com/repos/${repo_line}/git/ref/tags/${new_tag}" || true)
    if [[ -n "$ref" ]]; then
        obj_type=$(echo "$ref" | jq -r '.object.type // empty' 2>/dev/null)
        obj_sha=$(echo "$ref" | jq -r '.object.sha // empty' 2>/dev/null)
        if [[ "$obj_type" == "commit" ]]; then
            commit="$obj_sha"
        elif [[ -n "$obj_sha" ]]; then
            commit=$(curl -sf --max-time 20 "${AUTH[@]}" "https://api.github.com/repos/${repo_line}/git/tags/${obj_sha}" | jq -r '.object.sha // empty' 2>/dev/null || true)
        fi
    fi
    [[ -z "$commit" ]] && { echo "⚠️  ${pkg}: 无法获取 ${new_tag} 的 commit，跳过"; continue; }

    upstream_version="${new_tag#v}"

    echo "⬆️  ${pkg}: ${old_tag} → ${new_tag} (${commit:0:7})"
    python3 - "$recipe" "$new_tag" "$commit" "$upstream_version" <<'PYEOF'
import sys, re
path, new_tag, commit, upver = sys.argv[1:5]
s = open(path).read()
def set_field(s, key, val):
    pat = rf'^{key}:.*$'
    repl = f'{key}: "{val}"'
    return re.sub(pat, repl, s, count=1, flags=re.M) if re.search(pat, s, re.M) else s
s = set_field(s, 'version_tag', new_tag)
s = set_field(s, 'latest_tag', new_tag)
s = set_field(s, 'upstream_version', upver)
s = re.sub(r'^commit_hash:.*$', f'commit_hash: "{commit}"', s, count=1, flags=re.M)
open(path, 'w').write(s)
PYEOF

    echo "$pkg" >> "$UPDATED_FILE"
done

echo ""
echo "=== 更新汇总：$(wc -l < "$UPDATED_FILE") 个包需要重新构建 ==="
