#!/bin/sh
# save-handoff.sh — 提交并推送一篇交接文档到 hub（含碰撞兜底、凭据扫描、INDEX CAS）
# 用法:
#   bash scripts/save-handoff.sh <项目slug> <任务简述> <交接文档内容文件> [agent名]
# 说明: 内容文件为已按模板写好的交接文档（中文 Markdown）。本脚本负责
#       安全扫描、命名防碰撞、写入项目文件夹、更新 INDEX（CAS）、推送。
set -eu

die() { printf '错误：%s\n' "$*" >&2; exit 1; }
[ $# -ge 3 ] || die "用法: save-handoff.sh <项目slug> <任务简述> <内容文件> [agent名]"

SLUG="$1"; TASK="$2"; CONTENT_FILE="$3"; AGENT="${4:-${AGENT_NAME:-unknown}}"
[ -f "$CONTENT_FILE" ] || die "内容文件不存在：$CONTENT_FILE"

CONFIG="$HOME/.agent-handoff/config"
HUB_LOCAL=""
[ -f "$CONFIG" ] && HUB_LOCAL="$(grep -E '^hub_local=' "$CONFIG" | head -1 | cut -d= -f2-)"
HUB_LOCAL="${HUB_LOCAL:-$HOME/.agent-handoff/hub}"
[ -d "$HUB_LOCAL/.git" ] || die "hub 未就绪（$HUB_LOCAL）。请先运行 scripts/init-hub.sh。"

CONTENT="$(cat "$CONTENT_FILE")"

# ── 安全扫描（grep -E 必须显式 -E；扫描全文）──
SECRET_RE='(ghp_[A-Za-z0-9]{36}|gho_[A-Za-z0-9]{36}|github_pat_[A-Za-z0-9_]{22,}|sk-[A-Za-z0-9_-]{20,}|sk_live_[A-Za-z0-9]{10,}|rk_live_[A-Za-z0-9]{10,}|AKIA[A-Z0-9]{16}|xox[baprs]-[A-Za-z0-9-]{10,}|AIza[A-Za-z0-9_-]{35}|eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{5,}|-----BEGIN [A-Z ]*PRIVATE KEY-----|PuTTY-User-Key-File|://[^/@[:space:]]*:[^/@[:space:]]+@|Bearer [A-Za-z0-9._~-]{10,}|(access_token|_authToken|api[_-]?key|secret|password|passwd|aws_secret_access_key)[[:space:]]*[=:][[:space:]]*[^[:space:]]+)'
if printf '%s' "$CONTENT" | grep -Eq "$SECRET_RE"; then
  die "交接内容命中疑似凭据/密钥，拒写。请改为引用（如「凭据在环境变量 XXX」）后重试。"
fi

cd "$HUB_LOCAL"
git fetch --prune origin >/dev/null 2>&1 || true
git pull --ff-only >/dev/null 2>&1 || true

# ── 项目文件夹定位/新建 ──
PROJ_DIR=""
for d in "${SLUG}"*/; do
  [ -d "$d" ] && { PROJ_DIR="${d%/}"; break; }
done
if [ -z "$PROJ_DIR" ]; then
  PROJ_DIR="$SLUG"
  mkdir -p "$PROJ_DIR"
  printf '# 项目：%s\n\n> 由 agent-handoff 创建。\n\n## 关键信息\n\n- **slug**：%s\n- **工作分支**：dev\n' "$SLUG" "$SLUG" > "$PROJ_DIR/README.md"
fi

# ── 交接文档命名 + 碰撞兜底 ──
TS="$(date +%Y%m%d-%H%M%S)"
f="$PROJ_DIR/$TS-$AGENT-$TASK.md"
while [ -e "$f" ]; do f="${f%.md}-$(openssl rand -hex 2).md"; done
printf '%s\n' "$CONTENT" > "$f"
git add "$f"
# 顺序约束：交接文档先 commit（INDEX 后于文档）
git commit -m "交接($SLUG): $TASK by $AGENT" >/dev/null

# ── 更新 INDEX（CAS：比对 blob SHA，变了重判，上限 3 次）──
update_index() {
  NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  REL="${f#./}"
  # 取该项目当前最大 seq
  MAXSEQ=$(grep -E '^\| [0-9]+ \|' INDEX.md 2>/dev/null | grep -F "[$SLUG" | \
           sed -E 's/^\| ([0-9]+) \|.*/\1/' | sort -n | tail -1)
  MAXSEQ="${MAXSEQ:-0}"; SEQ=$((MAXSEQ+1))
  LINE="| $SEQ | [$SLUG]($PROJ_DIR/) | $TASK | [$TS]($REL) | $NOW | 进行中 | $AGENT |"
  # 插入到活跃任务表表头之后（第 5 个以 | 开头的分隔行之后）
  awk -v line="$LINE" '
    /^## 活跃任务/ {insec=1}
    insec && /^\|---/ && !done {print; print line; done=1; next}
    {print}
  ' INDEX.md > INDEX.md.tmp && mv INDEX.md.tmp INDEX.md
}

tries=0
while [ $tries -lt 3 ]; do
  REMOTE_BLOB="$(git rev-parse origin/main:INDEX.md 2>/dev/null || true)"
  update_index
  git add INDEX.md
  if git commit -m "索引($SLUG): 更新活跃任务 seq by $AGENT" >/dev/null 2>&1; then
    if git push origin main >/dev/null 2>&1; then
      break
    fi
  fi
  # CAS 失败：远端变了，回退本地 INDEX 改动，重新拉取重判
  git fetch origin >/dev/null 2>&1 || true
  git reset --hard origin/main >/dev/null 2>&1 || true
  tries=$((tries+1))
done
[ $tries -lt 3 ] || die "INDEX CAS 重试 3 次仍冲突，请人工合并（文档已 commit 于本地，未丢失：$f）。"

# 若前面文档 commit 因 reset 被回退，确保文档与 INDEX 都已推送
git push origin main >/dev/null 2>&1 || true

printf '交接已保存：%s\n' "$f"
