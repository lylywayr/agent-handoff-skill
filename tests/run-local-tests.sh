#!/bin/sh
# run-local-tests.sh — 不依赖 GitHub 的 agent-handoff 回归测试
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
SAVE="$SCRIPT_DIR/../scripts/save-handoff.sh"
ROOT=$(mktemp -d "${TMPDIR:-/tmp}/agent-handoff-test.XXXXXX")
trap 'rm -rf "$ROOT"' EXIT HUP INT TERM

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*"; }

GIT_CONFIG_GLOBAL="$ROOT/gitconfig"
export GIT_CONFIG_GLOBAL
export GIT_CONFIG_NOSYSTEM=1
git config --global user.name "agent-handoff test"
git config --global user.email "agent-handoff-test@example.invalid"

REMOTE="$ROOT/hub.git"
SEED="$ROOT/seed"
git init --bare "$REMOTE" >/dev/null
git init "$SEED" >/dev/null
git -C "$SEED" checkout -b main >/dev/null 2>&1
cat > "$SEED/INDEX.md" <<'EOF'
# 交接总索引
> 由本地测试生成。

## 活跃任务

| seq | 项目 | 任务 | 最新交接 | 更新时间(UTC) | 状态 | 更新者 |
|---|---|---|---|---|---|---|

## 已完成（最近 20 条）

| 项目 | 任务 | 完成时间 | 归档位置 |
|---|---|---|---|

## 冲突记录

| 时间 | 类型 | 说明 |
|---|---|---|
EOF
git -C "$SEED" add INDEX.md
git -C "$SEED" commit -m 'test: initialize local hub' >/dev/null
git -C "$SEED" remote add origin "$REMOTE"
git -C "$SEED" push origin main >/dev/null

make_home() {
  name="$1"
  home="$ROOT/$name"
  mkdir -p "$home/.agent-handoff"
  git clone "$REMOTE" "$home/.agent-handoff/hub" >/dev/null 2>&1
  git -C "$home/.agent-handoff/hub" checkout -B main origin/main >/dev/null 2>&1
  printf 'hub_url=%s\nhub_local=%s/.agent-handoff/hub\nagent_name=%s\n' \
    "$REMOTE" "$home" "$name" > "$home/.agent-handoff/config"
  printf '%s\n' "$home"
}

run_save() {
  home="$1"; slug="$2"; task="$3"; content="$4"; agent="$5"
  HOME="$home" AGENT_NAME="$agent" sh "$SAVE" "$slug" "$task" "$content" "$agent"
}

HOME_A=$(make_home agent-a)
CONTENT_A="$ROOT/content-a.md"
cat > "$CONTENT_A" <<'EOF'
---
origin: agent
wip-status: none
---
# 交接：本地单 agent 测试
## 一句话目标
验证交接文档先于 INDEX 指针发布。
## 下一步（最重要）
从全新 hub clone 读取本交接。
EOF
run_save "$HOME_A" demo-project first-task "$CONTENT_A" AgentA >/dev/null
VERIFY="$ROOT/verify-one"
git clone --branch main "$REMOTE" "$VERIFY" >/dev/null 2>&1
DOC_COUNT=$(find "$VERIFY/demo-project" -maxdepth 1 -type f -name '*.md' ! -name README.md | wc -l | tr -d ' ')
[ "$DOC_COUNT" -eq 1 ] || fail "单 agent 交接文档数量=$DOC_COUNT"
grep -F '| [demo-project](' "$VERIFY/INDEX.md" >/dev/null || fail 'INDEX 缺少单 agent 项目指针'
pass '单 agent 文档与 INDEX 已发布'

# 让第一个 INDEX push 必定失败，验证重试不会丢失已经发布的文档。
HOOK="$REMOTE/hooks/pre-receive"
cat > "$HOOK" <<'EOF'
#!/bin/sh
while read old new ref; do
  [ "$ref" = refs/heads/main ] || continue
  subject=$(git log -1 --format=%s "$new")
  case "$subject" in
    *'seq by'*)
      marker="$(dirname "$0")/reject-index-once"
      if [ ! -e "$marker" ]; then
        : > "$marker"
        echo 'test hook: reject first INDEX push' >&2
        exit 1
      fi
      ;;
  esac
done
exit 0
EOF
chmod +x "$HOOK"

HOME_B=$(make_home agent-b)
HOME_C=$(make_home agent-c)
CONTENT_B="$ROOT/content-b.md"
CONTENT_C="$ROOT/content-c.md"
printf '%s\n' '---' 'origin: agent' 'wip-status: none' '---' '# 交接：并发 A' '## 一句话目标' '验证并发交接不丢文档。' '## 下一步（最重要）' '继续读取并发交接。' > "$CONTENT_B"
printf '%s\n' '---' 'origin: agent' 'wip-status: none' '---' '# 交接：并发 B' '## 一句话目标' '验证并发交接不丢文档。' '## 下一步（最重要）' '继续读取并发交接。' > "$CONTENT_C"
(
  run_save "$HOME_B" demo-project parallel-a "$CONTENT_B" AgentB >"$ROOT/save-b.log" 2>&1
) & PID_B=$!
(
  run_save "$HOME_C" demo-project parallel-b "$CONTENT_C" AgentC >"$ROOT/save-c.log" 2>&1
) & PID_C=$!
wait "$PID_B" || { cat "$ROOT/save-b.log" >&2; fail '并发 agent-b 保存失败'; }
wait "$PID_C" || { cat "$ROOT/save-c.log" >&2; fail '并发 agent-c 保存失败'; }
VERIFY="$ROOT/verify-concurrent"
git clone --branch main "$REMOTE" "$VERIFY" >/dev/null 2>&1
DOC_COUNT=$(find "$VERIFY/demo-project" -maxdepth 1 -type f -name '*.md' ! -name README.md | wc -l | tr -d ' ')
[ "$DOC_COUNT" -eq 3 ] || fail "并发后文档数量=$DOC_COUNT，期望 3"
INDEX_COUNT=$(grep -F -c '| [demo-project](' "$VERIFY/INDEX.md" || true)
[ "$INDEX_COUNT" -eq 3 ] || fail "并发后 INDEX 项目行=$INDEX_COUNT，期望 3"
[ -e "$REMOTE/hooks/reject-index-once" ] || fail 'INDEX 拒绝钩子未触发'
pass '并发交接与 INDEX 重试均未丢文档'

# 凭据扫描：动态拼接测试串，避免把疑似 token 作为仓库内容保存。
BAD="$ROOT/bad.md"
BAD_TOKEN=$(printf 'ghp_'; printf '%036d' 0 | tr '0' 'x')
printf '说明：%s\n' "$BAD_TOKEN" > "$BAD"
BEFORE=$(git --git-dir="$REMOTE" rev-parse refs/heads/main)
if run_save "$HOME_A" rejected-project credential-check "$BAD" AgentA >/dev/null 2>&1; then
  fail '凭据扫描未拒绝测试内容'
fi
AFTER=$(git --git-dir="$REMOTE" rev-parse refs/heads/main)
[ "$BEFORE" = "$AFTER" ] || fail '凭据拒绝后远端发生变化'
pass '凭据扫描拒写且不改变远端'

# 基本冷启动证据：全新 clone 能由 INDEX 找到项目说明、文档和 dev 约定。
grep -F 'demo-project/' "$VERIFY/INDEX.md" >/dev/null || fail '冷启动 clone 无法定位项目目录'
[ -f "$VERIFY/demo-project/README.md" ] || fail '冷启动 clone 缺少项目 README'
grep -F '**工作分支**：dev' "$VERIFY/demo-project/README.md" >/dev/null || fail '项目 README 缺少 dev 工作分支'
pass '全新 hub clone 可定位项目与 dev 约定'

printf '全部本地 agent-handoff 测试通过。\n'
