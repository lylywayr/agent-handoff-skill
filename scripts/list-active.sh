#!/bin/sh
# list-active.sh — 列出 hub 中所有活跃交接任务（解析 INDEX.md）
# 用法: bash scripts/list-active.sh [项目slug过滤]
set -eu

CONFIG="$HOME/.agent-handoff/config"
HUB_LOCAL=""
[ -f "$CONFIG" ] && HUB_LOCAL="$(grep -E '^hub_local=' "$CONFIG" | head -1 | cut -d= -f2-)"
HUB_LOCAL="${HUB_LOCAL:-$HOME/.agent-handoff/hub}"
INDEX="$HUB_LOCAL/INDEX.md"
[ -f "$INDEX" ] || { echo "hub 未就绪或 INDEX.md 不存在：$INDEX" >&2; exit 1; }

FILTER="${1:-}"

git -C "$HUB_LOCAL" fetch --prune origin >/dev/null 2>&1 || true
git -C "$HUB_LOCAL" pull --ff-only >/dev/null 2>&1 || true

echo "# 活跃交接任务"
echo ""
# 提取「活跃任务」表（## 活跃任务 到下一个 ## 之间）的数据行（| seq | ... |）
awk -v filter="$FILTER" '
  /^## 活跃任务/ {insec=1; next}
  /^## / && !/^## 活跃任务/ {insec=0}
  insec && /^\| [0-9]+ \|/ {
    line=$0
    if (filter=="" || index(line, filter)>0) print line
  }
' "$INDEX" | while IFS= read -r row; do
  # 拆分字段：| seq | 项目 | 任务 | 最新交接 | 更新时间 | 状态 | 更新者 |
  seq=$(printf '%s' "$row" | awk -F'|' '{gsub(/ /,"",$2); print $2}')
  proj=$(printf '%s' "$row" | awk -F'|' '{gsub(/^ +| +$/,"",$3); print $3}')
  task=$(printf '%s' "$row" | awk -F'|' '{gsub(/^ +| +$/,"",$4); print $4}')
  upd=$(printf '%s' "$row" | awk -F'|' '{gsub(/^ +| +$/,"",$6); print $6}')
  status=$(printf '%s' "$row" | awk -F'|' '{gsub(/^ +| +$/,"",$7); print $7}')
  who=$(printf '%s' "$row" | awk -F'|' '{gsub(/^ +| +$/,"",$8); print $8}')
  printf '  [%s] %s — %s\n      状态:%s  更新:%s  by %s\n' "$seq" "$proj" "$task" "$status" "$upd" "$who"
done

# 若一行都没有
if ! awk '/^## 活跃任务/{f=1;next}/^## /{if(f)exit}f&&/^\| [0-9]+ \|/{found=1}END{exit !found}' "$INDEX"; then
  echo "  （无活跃任务）"
fi
