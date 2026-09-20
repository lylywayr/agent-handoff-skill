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

# 只在干净且可安全对齐的 hub/main 上工作。所有可能被回退的本地提交
# 都必须先推送或明确中止，避免 CAS 重试静默丢失交接文档。
CURRENT_BRANCH="$(git symbolic-ref --short -q HEAD || true)"
[ "$CURRENT_BRANCH" = "main" ] || die "hub 当前不在 main 分支（$CURRENT_BRANCH），为避免覆盖其他工作而中止。"
[ -z "$(git status --porcelain)" ] || die "hub 有未提交改动；请先保存或清理后重试。"
git fetch --prune origin main >/dev/null 2>&1 || die "无法同步 hub 的 origin/main。"
git rev-parse --verify origin/main >/dev/null 2>&1 || die "hub 缺少 origin/main。"
if ! git merge-base --is-ancestor HEAD origin/main; then
  die "hub 本地 main 含未推送或分叉提交；为避免覆盖工作而中止。"
fi
git reset --hard origin/main >/dev/null 2>&1

# ── 项目文件夹定位、提交并先推送交接文档 ──
# 文档必须先落到远端；后续 INDEX CAS 重试才允许 reset 到 origin/main。
TS="$(date +%Y%m%d-%H%M%S)"
DOC_PUSHED=0
DOC_COMMIT=""
doc_tries=0
while [ "$doc_tries" -lt 3 ]; do
  git fetch --prune origin main >/dev/null 2>&1 || die "无法刷新 hub 的 origin/main。"
  git reset --hard origin/main >/dev/null 2>&1

  PROJ_DIR=""
  for d in "${SLUG}"*/; do
    [ -d "$d" ] && { PROJ_DIR="${d%/}"; break; }
  done
  NEW_README=0
  if [ -z "$PROJ_DIR" ]; then
    PROJ_DIR="$SLUG"
    mkdir -p "$PROJ_DIR"
    printf '# 项目：%s\n\n> 由 agent-handoff 创建。\n\n## 关键信息\n\n- **slug**：%s\n- **工作分支**：dev\n' "$SLUG" "$SLUG" > "$PROJ_DIR/README.md"
    NEW_README=1
  fi

  f="$PROJ_DIR/$TS-$AGENT-$TASK.md"
  while [ -e "$f" ]; do f="${f%.md}-$(openssl rand -hex 2).md"; done
  printf '%s\n' "$CONTENT" > "$f"
  [ "$NEW_README" -eq 0 ] || git add "$PROJ_DIR/README.md"
  git add "$f"
  git commit -m "交接($SLUG): $TASK by $AGENT" >/dev/null
  DOC_COMMIT="$(git rev-parse HEAD)"

  if git push origin HEAD:refs/heads/main >/dev/null 2>&1; then
    DOC_PUSHED=1
    break
  fi
  # push 被并发更新或网络暂时拒绝时，下一轮从最新远端重建提交。
  # CONTENT_FILE 与 CONTENT 仍在本次进程内，文档内容不会因 reset 丢失。
  doc_tries=$((doc_tries+1))
done
if [ "$DOC_PUSHED" -ne 1 ]; then
  die "交接文档 push 失败；文档提交保留在本地 $DOC_COMMIT（路径：$f），未继续修改 INDEX。"
fi

# ── 更新 INDEX（真实 CAS：blob 比对 + push 非快进兜底）──
update_index() {
  NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  REL="${f#./}"
  # 取该项目当前最大 seq
  MAXSEQ=$(grep -E '^\| [0-9]+ \|' INDEX.md 2>/dev/null | grep -F "[$SLUG" | \
           sed -E 's/^\| ([0-9]+) \|.*/\1/' | sort -n | tail -1)
  MAXSEQ="${MAXSEQ:-0}"
  SEQ=$((MAXSEQ+1))
  LINE="| $SEQ | [$SLUG]($PROJ_DIR/) | $TASK | [$TS]($REL) | $NOW | 进行中 | $AGENT |"
  awk -v line="$LINE" '
    /^## 活跃任务/ {insec=1}
    insec && /^\|---/ && !done {print; print line; done=1; next}
    {print}
  ' INDEX.md > INDEX.md.tmp && mv INDEX.md.tmp INDEX.md
}

index_tries=0
INDEX_PUSHED=0
INDEX_COMMIT=""
while [ "$index_tries" -lt 3 ]; do
  # 文档已经在远端，以下 reset 不会再抹掉唯一副本。
  git fetch --prune origin main >/dev/null 2>&1 || die "无法刷新 hub 的 origin/main。"
  git reset --hard origin/main >/dev/null 2>&1
  BASE_BLOB="$(git rev-parse origin/main:INDEX.md 2>/dev/null || true)"
  update_index
  git add INDEX.md
  git commit -m "索引($SLUG): 更新活跃任务 seq by $AGENT" >/dev/null
  INDEX_COMMIT="$(git rev-parse HEAD)"

  # fetch 后的 blob 变化表示并发 agent 已先更新 INDEX，重新取 seq/重建。
  git fetch --prune origin main >/dev/null 2>&1 || true
  CURRENT_BLOB="$(git rev-parse origin/main:INDEX.md 2>/dev/null || true)"
  if [ "$CURRENT_BLOB" != "$BASE_BLOB" ]; then
    index_tries=$((index_tries+1))
    continue
  fi
  # 比对后仍可能有极短竞态；非快进 push 是最后一道 CAS。
  if git push origin HEAD:refs/heads/main >/dev/null 2>&1; then
    INDEX_PUSHED=1
    break
  fi
  index_tries=$((index_tries+1))
done
if [ "$INDEX_PUSHED" -ne 1 ]; then
  die "INDEX CAS 重试 3 次仍冲突或 push 失败；交接文档已在远端（$f），INDEX 提交保留在本地 $INDEX_COMMIT。"
fi

printf '交接已保存：%s\n文档提交：%s\n索引提交：%s\n' "$f" "$DOC_COMMIT" "$INDEX_COMMIT"
