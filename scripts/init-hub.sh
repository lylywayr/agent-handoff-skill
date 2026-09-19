#!/bin/sh
# init-hub.sh — 初始化/发现 agent-handoff 交接总仓（hub）
# 幂等：hub repo 已存在仅 clone 不重建。三层降级定位 hub：
#   1. $AGENT_HANDOFF_HUB  2. ~/.agent-handoff/config  3. gh api 约定名探测
# 用法: bash scripts/init-hub.sh
set -eu

CONFIG_DIR="$HOME/.agent-handoff"
CONFIG="$CONFIG_DIR/config"
HUB_LOCAL_DEFAULT="$CONFIG_DIR/hub"

log() { printf '%s\n' "$*" >&2; }
die() { log "错误：$*"; exit 1; }

# 读取 config 中的某个字段（不存在则空）
cfg_get() {
  [ -f "$CONFIG" ] || { printf ''; return 0; }
  grep -E "^$1=" "$CONFIG" 2>/dev/null | head -1 | cut -d= -f2- || printf ''
}

# 原子写 config（同目录临时文件 + mv）
atomic_write_config() {
  mkdir -p "$CONFIG_DIR"
  tmp="$CONFIG_DIR/.config.tmp.$$"
  cat > "$tmp"
  mv -f "$tmp" "$CONFIG"
  chmod 600 "$CONFIG"
}

# 1. 环境变量
HUB_URL="${AGENT_HANDOFF_HUB:-}"
# 2. config
[ -n "$HUB_URL" ] || HUB_URL="$(cfg_get hub_url)"
# 3. gh api 约定名探测（显式取登录名，不用 {owner}）
if [ -z "$HUB_URL" ]; then
  if command -v gh >/dev/null 2>&1; then
    login="$(gh api user --jq .login 2>/dev/null || true)"
    if [ -n "$login" ]; then
      out="$(gh api "repos/$login/handoff-hub" 2>&1)" && rc=0 || rc=$?
      if [ "$rc" -eq 0 ]; then
        HUB_URL="https://github.com/$login/handoff-hub.git"
      else
        code="$(printf '%s' "$out" | grep -oE 'HTTP [0-9]{3}' | grep -oE '[0-9]{3}' | head -1)"
        case "$code" in
          401) die "gh 未登录（HTTP 401）。请先 gh auth login，或设置 AGENT_HANDOFF_HUB。" ;;
          403|404) log "当前账号 $login 下未找到 handoff-hub（HTTP $code），将为你创建。" ;;
          429) die "gh API 限流（HTTP 429），请稍后重试。" ;;
          *) log "gh 探测失败（HTTP ${code:-网络错误}），将尝试创建。" ;;
        esac
      fi
    fi
  fi
fi

# 三层皆空且无法自动建仓 → 询问用户
if [ -z "$HUB_URL" ] && ! command -v gh >/dev/null 2>&1; then
  die "无法定位 hub（无环境变量、无 config、无 gh）。请设置 AGENT_HANDOFF_HUB=<hub仓库地址> 后重试。"
fi

# 建仓（repo 不存在时）
if [ -z "$HUB_URL" ]; then
  login="$(gh api user --jq .login 2>/dev/null)" || die "gh 未登录。"
  log "用 gh 创建私有仓库 $login/handoff-hub ..."
  gh repo create handoff-hub --private --description "agent-handoff 交接总仓" >/dev/null 2>&1 \
    || die "建仓失败（可能已存在但无权限，或网络问题）。"
  HUB_URL="https://github.com/$login/handoff-hub.git"
fi

HUB_LOCAL="$(cfg_get hub_local)"; HUB_LOCAL="${HUB_LOCAL:-$HUB_LOCAL_DEFAULT}"

# clone（已存在仅复用，不重建）
if [ -d "$HUB_LOCAL/.git" ]; then
  log "hub 已存在于 $HUB_LOCAL，拉取最新。"
  git -C "$HUB_LOCAL" fetch --prune origin >/dev/null 2>&1 || true
  git -C "$HUB_LOCAL" pull --ff-only >/dev/null 2>&1 || log "提示：hub 本地有分叉，保持现状。"
else
  mkdir -p "$(dirname "$HUB_LOCAL")"
  git clone "$HUB_URL" "$HUB_LOCAL" || die "clone hub 失败：$HUB_URL"
fi

# 初始化骨架（INDEX.md / pending / unregistered / .gitignore），幂等
cd "$HUB_LOCAL"
[ -f INDEX.md ] || printf '# 交接总索引\n\n## 活跃任务\n\n| seq | 项目 | 任务 | 最新交接 | 更新时间(UTC) | 状态 | 更新者 |\n|---|---|---|---|---|---|---|\n\n## 已完成（最近 20 条）\n\n| 项目 | 任务 | 完成时间 | 归档位置 |\n|---|---|---|---|\n\n## 冲突记录\n\n| 时间 | 类型 | 说明 |\n|---|---|---|\n' > INDEX.md
mkdir -p pending unregistered
[ -f .gitignore ] || printf '.env\n*.pem\n*.key\nsecrets*\n.env.*\n' > .gitignore

if [ -n "$(git status --porcelain)" ]; then
  git add -A
  git commit -m "chore: 初始化 hub 骨架 (agent-handoff)" >/dev/null
  git push origin main >/dev/null 2>&1 || git push -u origin main >/dev/null
  log "hub 骨架已提交并推送。"
fi

# 写 config（若缺字段）
if [ -z "$(cfg_get hub_url)" ] || [ -z "$(cfg_get hub_local)" ]; then
  an="$(cfg_get agent_name)"; an="${an:-${AGENT_NAME:-}}"
  atomic_write_config <<EOF
hub_url=$HUB_URL
hub_local=$HUB_LOCAL
agent_name=$an
EOF
  log "config 已写入 $CONFIG（不含凭据）。"
fi

log "完成。hub_url=$HUB_URL  hub_local=$HUB_LOCAL"
printf '%s\n' "$HUB_LOCAL"
