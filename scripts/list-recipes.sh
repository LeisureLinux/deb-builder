#!/bin/bash
# list-recipes.sh: 列出所有 recipe 名称（不含 .yaml）
for f in recipes/*.yaml; do
    [[ -f "$f" ]] || continue
    basename "$f" .yaml
done | sort
