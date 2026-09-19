---
name: agent-handoff
description: 跨 AI agent 工作接力。当用户说"交接一下""存档进度""接着上次做""继续之前的任务"，或会话进入收尾/任务切换阶段时使用。将工作状态沉淀到 GitHub 私有交接总仓，或从仓库读取状态无缝恢复工作，支持 DeepSeek Harness / Codex / Claude Code / OpenMinis，IDE agent 优雅降级。
---

# 跨 Agent 接力（agent-handoff）

让任意 agent 把工作状态沉淀到 GitHub 私有交接总仓（hub），另一个 agent（跨平台/跨设备）读取后无缝继续，用户无需重复说明背景。

**三条不可违背的承诺：**
1. **不丢工作**——任何中间态（文档/代码）要么入库、要么留痕，绝不静默丢弃；
2. **不中断**——交接/同步/冲突处理永不因冲突卡住等待用户；无法自动裁决时按规则降级，信息全保留；
3. **凭据零落盘**——任何持久化文档不得含 token/密码/私钥/连接串。

> 本文件自包含。templates/ 与 scripts/ 是加速器；仅凭本文件即可完成交接。
> 完整设计原理见同仓库 `handoff-skill-design.md`（实施规格书）。

## 0. 名词

- **hub**：交接总仓（GitHub 私有 repo），唯一，仅 `main` 单分支，存放全部交接文档。
- **项目 repo**：项目本体 repo，一项目一个，`main`（正式可用版）+ `dev`（一切工作发生地）双分支。
- **沉淀（Save）**：把当前会话上下文写成交接文档推 hub。**接手（Resume）**：读交接、克隆项目继续。**同步（Sync）**：开工第 0 步对齐远端。
- **降级 agent**：无法执行 git/shell 的环境（如部分 IDE），只读、产出建议文件。
- **wip 分支**：`dev-wip/<agent>-<时间>`，代码冲突时本地未推送工作的留痕分支。

## 1. 核心架构

- **双仓分离**：项目代码在项目 repo，交接文档在 hub，永不混淆。
- hub 目录结构：
  ```
  handoff-hub/
  ├── INDEX.md                       # 全局索引（中文）
  ├── pending/                       # 降级 agent 建议暂存区
  ├── unregistered/                  # 未入库项目交接暂存区
  ├── <项目slug>-中文说明/
  │   ├── README.md                  # 中文说明 + 项目 repo 指针 + slug
  │   ├── <YYYYMMDD-HHmmss>-<agent>-<任务>.md
  │   └── archive/<任务>-<首交日期>/
  └── .gitignore                     # .env、*.pem、*.key、secrets* 等
  ```
- 项目 repo 根含 `.handoff-project`（单行：hub slug，建仓时随 README 提交进 main，dev 继承）。

## 2. hub 发现（三层降级，先做）

依次尝试定位 hub：
1. 环境变量 `AGENT_HANDOFF_HUB`（仓库地址）；
2. 配置文件 `~/.agent-handoff/config`（字段 `hub_url`、`hub_local`、`agent_name`；**不含凭据**）；
3. 约定名探测（**显式取登录名，不用 `{owner}`**）：
   ```sh
   gh api "repos/$(gh api user --jq .login)/handoff-hub"
   ```

**`gh api` 失败分级**（解析 HTTP 状态码，非进程退出码——gh 失败统一退出 1）：
```sh
out=$(gh api "repos/$(gh api user --jq .login)/handoff-hub" 2>&1); rc=$?
if [ $rc -ne 0 ]; then
  code=$(printf '%s' "$out" | grep -oE 'HTTP [0-9]{3}' | grep -oE '[0-9]{3}' | head -1)
  case "$code" in
    401)    : # 未登录 → 降级提示 ;;
    403|404): # 无权限/不存在 → 询问建仓/授权 ;;
    429)    : # 限流 → 退避重试 ;;
    422)    : # 校验错 → 询问/人工 ;;
    *)      : # 网络等 → 重试 ;;
  esac
fi
```
三层皆空 → 询问用户一次并写入 config（**原子写：同目录临时文件 + mv**）。hub 统一 clone 于 `~/.agent-handoff/hub`，本地缺失则 clone（已存在**仅 clone 不重建**，幂等）。可用 `scripts/init-hub.sh` 自动完成。

**agent 身份**（三层降级）：`$AGENT_NAME` → config `agent_name` → 自报家名（如 "DeepSeek Harness"）。

## 3. 沉淀（Save）

0. **hub 定位**（§2）。
1. **项目入库检查**：项目唯一标识 = git 远端 repo 名（无 repo 用顶层目录名）。未入库 → 询问建仓；用户拒绝 → 沉淀到 hub `unregistered/`，强制记录本地绝对路径，入库后迁移。
   **建仓步骤**（定死）：`git init`（默认 main）→ 写 README **和 `.handoff-project`（单行 slug）** 一并提交 main → `gh repo create --private`（用户声明公开则 `--public`）→ 推 main → `git checkout -b dev`（dev 继承两文件，无需二次提交）→ 工作内容提交 dev 并推。
   **已有项目**：沉淀前确认当前改动已提交到 `dev` 并推送——未推送的半成品必须先上 dev。
2. **hub 项目文件夹定位/新建**：名取 `.handoff-project` 的 slug 或首次生成（`<稳定slug>-中文说明`，slug 创建后只增不改）；首次写项目 README。
3. **多任务归属判定**：查 INDEX 该项目活跃任务 → 续写对应任务线（项目内最大 seq+1）或新建（seq 从 1）。**内容来源 = 当前会话上下文的结构化摘要**；本会话无任务上下文 → **拒绝沉淀**，提示「先同步接手再交接」。
4. **生成交接文档**（中文，模板见 §9 / `templates/handoff-template.md`）：文件名 `<YYYYMMDD-HHmmss>-<agent>-<任务简述>.md`，碰撞兜底 `while [ -e "$f" ]; do f="${f%.md}-$(openssl rand -hex 2).md"; done`。更新 INDEX（§6）。状态首次「已完成」→ 同 commit 内联动归档（§7）。
5. **安全检查**（§8）：凭据扫描，命中**拒写并提醒**。
6. **提交（顺序约束）**：**交接文档 commit 先于 INDEX 指针 commit push**，保证指针永不指向未上远端的文件。输出一句话摘要 + 路径。

## 4. 接手（Resume）

1. 用户指路（「接着上次做」，可带项目名）。
2. 定位：hub INDEX → 项目文件夹 → 项目 README 取 repo 地址。
3. 读最新交接；多任务列出让用户选。
4. 1–2 句复述「任务 / 项目位置 / 进度 / 下一步」。
5. 确认后 **确保项目 repo 就绪**（幂等）：本地无 `~/.agent-handoff/projects/<slug>/` → clone；有 → `git fetch && git checkout dev && git pull`。开工；随后按新进度更新交接（滚动接力）。
6. **里程碑合并**（§4.6 见下）。

## 5. 同步（Sync）——开工第 0 步，全自动

定死顺序：**fetch → 读最新交接（拓扑）→ 扫 pending → 合并 pending（语义）→ 确保项目 repo 就绪 → 动工**。

1. `git fetch` hub，pull 到最新。
2. **读该项目最新交接**：用拓扑判新旧（§5.1，不比时间戳）。此处确定的项目内最新 seq 供下一步取号。
3. **扫 pending/**：`git ls-files pending/` + `git status --porcelain pending/`（含 untracked）。发现建议 → 按 §5.3 语义合并（LLM 判断同/异）→ 用刚读的 seq 续号 → commit。**注：合并 pending 仅消费 hub 侧 INDEX 数据**（hub 已 fetch，不依赖项目 repo 就绪）。
4. **确保项目 repo 就绪**（同 §4-5）。
5. 他人推进过 → 一句话汇报「谁/何时/推进了什么/下一步」→ 直接续做。
6. **代码冲突**（本地未推送残留 vs 远端）：**不 stash**——按 wip 留痕流程（见下）。
7. **本地 dev 对齐判定**（拓扑）：`is-ancestor 本地dev origin/dev` 为真（本地落后，含远端刚 reset）→ `git checkout -B dev origin/dev` 对齐；本地领先/分叉 → 不对齐，本地工作保留，分叉已在第 6 步 wip 收编。

### 5a. 代码冲突的 wip 留痕流程

**核心原则：**
- 冲突判定**不依赖 `git merge` 退出码**，用 `git merge --no-commit --no-ff` 后显式查 `git ls-files -u`；
- 冲突路径**绝不用 merge commit 语义**（`git add` 冲突文件会清掉未合并状态，下游不再报冲突=状态伪装）；残留以**独立分支**存档；
- **任何 push 失败都不丢工作**。

```sh
git fetch origin dev
git fetch --prune origin "+refs/heads/dev-wip/*:refs/remotes/origin/dev-wip/*" 2>/dev/null || true
git add -A
git commit -m "wip: $AGENT 未提交残留（固化）" || true
LOCAL_WIP_REF=$(git symbolic-ref --short -q HEAD || git rev-parse HEAD)
TS=$(date +%Y%m%d-%H%M)

new_branch_name() {
  local base="$1"
  local w="$base"
  while git show-ref --verify --quiet "refs/remotes/origin/$w" \
     || git show-ref --verify --quiet "refs/heads/$w"; do
    w="${base}-$(openssl rand -hex 2)"
  done
  echo "$w"
}
W=$(new_branch_name "dev-wip/$AGENT-$TS")
RESIDUE=$(new_branch_name "dev-wip/$AGENT-residue-$TS")

if ! git checkout -b "$W" origin/dev; then echo "错误：无法建 wip 分支 $W" >&2; exit 1; fi
git merge --no-commit --no-ff "$LOCAL_WIP_REF" 2>/dev/null
if [ -n "$(git ls-files -u)" ]; then
  if [ -f "$(git rev-parse --git-dir)/MERGE_HEAD" ]; then git merge --abort; else git reset --hard origin/dev; fi
  git branch "$RESIDUE" "$LOCAL_WIP_REF"
  git push origin "$RESIDUE"
else
  git commit --no-edit -m "wip: $AGENT 未推送残留（与远端 dev 冲突，待消化）" 2>/dev/null || true
fi

push_wip() {
  local tries=0
  while [ $tries -lt 3 ]; do
    if git push origin "$W" 2>/dev/null; then return 0; fi
    git fetch --prune origin "+refs/heads/dev-wip/*:refs/remotes/origin/dev-wip/*" 2>/dev/null || true
    W=$(new_branch_name "dev-wip/$AGENT-$TS")
    git branch -m "$W" 2>/dev/null || git checkout -b "$W" 2>/dev/null
    tries=$((tries+1))
  done
  return 1
}
if ! push_wip; then
  git branch -f "$RESIDUE" "$LOCAL_WIP_REF" 2>/dev/null || git branch "$RESIDUE" "$LOCAL_WIP_REF"
  git push origin "$RESIDUE" 2>/dev/null || echo "警告：wip/residue push 失败，工作在本地 $RESIDUE 与 reflog" >&2
fi
git checkout dev && git reset --hard origin/dev
```
交接文档记录 wip 指针（冲突时记 residue 指针）+ `wip-status: pending`。

## 6. INDEX.md 格式

```markdown
# 交接总索引
> 由 agent-handoff 维护，全部中文。

## 活跃任务
| seq | 项目 | 任务 | 最新交接 | 更新时间(UTC) | 状态 | 更新者 |
|---|---|---|---|---|---|---|

## 已完成（最近 20 条）
| 项目 | 任务 | 完成时间 | 归档位置 |

## 冲突记录
| 时间 | 类型 | 说明 |
```
`seq` 仅作 INDEX 内部排序、非唯一标识、不与文档绑定（文档靠时间戳+agent 名标识）。

## 7. 归档（archive）

任务状态首次「已完成」时，**同一次 commit 内**：该任务全部历史交接移入项目文件夹 `archive/<任务简述>-<首次交接日期>/`；INDEX 该行从「活跃」移入「已完成」。只动 hub，不动项目 repo。

## 8. 安全

1. **凭据零落盘**：禁写凭据/token/密码/私钥/cookie/连接串/配置/环境变量样例（只写引用）；**摘要原则**——只写结构化摘要，禁止搬会话原文。
2. **凭据扫描**（写入任何持久化文档前，`grep -E` 必加 `-E`，扫描全文含 frontmatter）：
   ```sh
   SECRET_RE='(ghp_[A-Za-z0-9]{36}|gho_[A-Za-z0-9]{36}|github_pat_[A-Za-z0-9_]{22,}|sk-[A-Za-z0-9_-]{20,}|sk_live_[A-Za-z0-9]{10,}|rk_live_[A-Za-z0-9]{10,}|AKIA[A-Z0-9]{16}|xox[baprs]-[A-Za-z0-9-]{10,}|AIza[A-Za-z0-9_-]{35}|eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{5,}|-----BEGIN [A-Z ]*PRIVATE KEY-----|PuTTY-User-Key-File|://[^/@[:space:]]*:[^/@[:space:]]+@|Bearer [A-Za-z0-9._~-]{10,}|(access_token|_authToken|api[_-]?key|secret|password|passwd|aws_secret_access_key)[[:space:]]*[=:][[:space:]]*[^[:space:]]+)'
   printf '%s' "$CONTENT" | grep -Eq "$SECRET_RE" && { echo "命中疑似凭据，拒写" >&2; exit 1; }
   ```
3. **私有默认 + 转 public 强扫**：建仓默认 `--private`；用户声明公开才 `--public` 并留痕；**任何转 public/建 public 前强制全历史扫描**。
4. **无网络凭据依赖**：git 推送复用本机 git/gh 认证，Skill 不存储、不询问 token；config 不含凭据。
5. **.gitignore 双保险**：hub 初始化加入 `.env`、`*.pem`、`*.key`、`secrets*`。
6. **跨终端可达性（交接的本质前提）**：交接文档/项目 README/notes 里的每条信息，接收 agent 在**另一台机器**上读到后必须能直接使用。规则：
   - **可写**：GitHub 仓库地址、分支名、commit hash、issue/PR 链接、仓库内相对路径、标准约定路径（`~/.agent-handoff/...`，每个 agent 解析自己的 `~`）、复现命令。
   - **禁写**：本机绝对路径（`/vol2/...`、`/home/...`、`C:\...`）、原 agent 的部署/安装位置（如「已装到 DSH 的 dsh-data/...」）、原终端环境状态（如「本机无 gh」「$HOME 不可写」「本机 clone 在某路径」）、依赖会话上下文的引用（如「本会话我们讨论了...」「上一轮的辩论」——接收方没有这段会话）。
   - 描述环境需求时写「**需要某环境具备 X**」，不写「我这台机器没有 X」。
   - commit hash 跨终端有效（指向同一远端仓库）可写；但「本地未推送改动」「本机临时文件」只对本机有效，不写。

## 9. 交接文档模板

见 `templates/handoff-template.md`。要点：front-matter（`origin`、`wip-status`；普通交接省略 `merged`，仅 degraded 建议带 `merged: false`）+ 中文正文（一句话目标 / 项目指针[仓库,工作分支 dev,相关目录,wip 分支] / 当前进度 / 下一步 / 关键决策 / 上下文指针 / 阻塞）。**语言细则**：描述全中文；代码、路径、分支名、repo 地址、commit hash 等标识符**保持原样，严禁翻译**。

### 9a. 过程附件（可选，摘要为主 + 附件为辅）

交接正文始终是**结构化摘要**（不搬会话原文）。但当接收方需要了解工作过程时，允许把**提炼后的**过程记录作为附件存到 hub 本项目文件夹 `notes/` 下：
- 内容：关键讨论结论、被否决的方案及原因、重要的中间产物说明、多轮评审/辩论的要点——**提炼后的记录，不是对话原文**；
- 命名：`notes/<YYYYMMDD>-<主题>.md`；
- 在交接文档「过程附件」节列出文件名，接收方按需取读；
- 附件同样遵守凭据扫描与跨终端可达性规则。

## 10. 并发与一致性（实现时遵循，细节见设计文档）

- **不追求全局时间全序**。拓扑（`git merge-base --is-ancestor`）管已入库文档新旧；语义（LLM 判断）管内容同异。
- **判定优先级**：有公共拓扑先 merge-base，分叉（双失败）各自保留不路由语义；无公共拓扑（pending/INDEX 并发行）直接语义；语义只答同/不同/不确定。
- **语义合并三态**：同 → INDEX 合一行（链接留两条，行尾加 `(合并@时间 by agent，原始见 链A 链B)`）；不同 → 两行并立；不确定 → 两行并立 + `needs-review`。**不引入 UNRESOLVED**，原文档永存。
- **CAS**：INDEX 更新比对 blob SHA（`git rev-parse origin/main:INDEX.md`），变了重判再提交，上限 3 次超限转语义合并；seq 仅 CAS 成功才生效，撞号重取。
- **文档冲突**：双份保留，旧版重命名 `冲突-<YYYYMMDD-HHmm>-<agent>.md` 存档，以远端为准本地存档，不做内容级 merge。

## 11. 里程碑合并与 dev reset

**执行方：**
```sh
git fetch origin dev main
git checkout main && git merge --ff-only origin/main
git checkout dev
if ! git merge-base --is-ancestor main dev; then echo "main 有 dev 未含提交，先同步 main，中止" >&2; exit 1; fi
OLD_DEV=$(git rev-parse origin/dev)
git checkout main && git merge --no-ff dev -m "里程碑 vX：merge dev into main"
git push origin main
git checkout dev && git reset --hard main
if ! git push --force-with-lease=dev:"$OLD_DEV" origin dev; then echo "dev 被并发修改，重新 fetch 判定" >&2; exit 2; fi
# reset 事件记入 hub INDEX 冲突记录节（不进 git 历史）
```
**检测方**：走拓扑双向判定（不依赖 `[dev-reset]` commit 标记）：本地落后 → `checkout -B dev origin/dev`；本地领先/分叉 → 不对齐，分叉交 wip 收编。

## 12. 降级 agent 闭环

降级 agent **只读、不直接写 hub**，产出建议文件，由有 git 能力的 agent/人合并：
- **产出**：对话输出 §9 模板 + front-matter `origin: degraded-agent-suggestion`、`merged: false`，提示用户存为 hub `pending/<YYYYMMDD-HHmmss>-<agent>-建议.md`。
- **合并**：有 git 能力的 agent 在第 0 步扫 pending/（含 untracked）→ 采用（同构几乎不改写）→ 更新 INDEX → commit → 移出 pending/。

详见 `FALLBACK.md`。

## 13. 明确不做

不做实时双向协同；不做对话全量回放；不做代码冲突 auto-merge；不接管任务调度；不追求全局时间全序。
