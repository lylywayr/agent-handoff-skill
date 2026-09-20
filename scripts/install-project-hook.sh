#!/bin/sh
# install-project-hook.sh — 幂等安装 post-commit hook 到【项目 repo】
# 用法: bash scripts/install-project-hook.sh [项目repo路径]
# 默认路径 ~/.agent-handoff/projects/<slug>/；未指定时探测当前目录（若为 git 仓库）
set -eu

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HOOK_SRC="$SKILL_DIR/templates/post-commit-hook"

PROJ="${1:-}"

# 未指定路径 → 用当前目录（若为 git 仓库）
if [ -z "$PROJ" ]; then
  if git rev-parse --git-dir >/dev/null 2>&1; then
    PROJ="$(git rev-parse --show-toplevel)"
  else
    echo "错误：未指定项目路径，且当前目录不是 git 仓库。" >&2
    echo "用法: bash scripts/install-project-hook.sh <项目repo路径>" >&2
    exit 1
  fi
fi

[ -d "$PROJ/.git" ] || { echo "错误：$PROJ 不是 git 仓库（缺 .git）" >&2; exit 1; }

HOOK_DST="$PROJ/.git/hooks/post-commit"

if [ -f "$HOOK_DST" ] && ! grep -q "agent-handoff" "$HOOK_DST" 2>/dev/null; then
  echo "警告：$HOOK_DST 已存在且非本 Skill 安装，跳过（保留用户自定义 hook）。" >&2
  exit 0
fi

cp "$HOOK_SRC" "$HOOK_DST"
chmod +x "$HOOK_DST"
echo "已安装 post-commit hook → $HOOK_DST"
