---
name: agent-handoff
version: 1.1.0
description: 跨会话、跨 Agent、跨月跨年维护项目事实源与工作接力。用户新建长期项目、接管或继续已绑定项目、提出新需求/优化/Bug 修复/版本变更，或要求交接、存档、恢复任务时使用。可经授权建立本地及远端仓库；开工同步项目仓库或知识库并定向检索历史，完成变更后写回项目记录并核验；需要跨 Agent 交接时另存工作接力信息。协议不限定 Agent、模型或 GitHub。
---

# 跨 Agent 接力与项目连续性（agent-handoff）

这是**单一 Skill、两个工作模式**：①每次已绑定项目任务的「项目连续性」，从项目事实源同步、定向检索并在有实际变更时记账；②明确需要跨 Agent/设备交接时的「工作接力」，沿用本文件原有 hub 流程。只读/仅讨论需求的任务只读取，不写入。任何 Agent 只要具备相应的读写、版本与验证能力即可执行；GitHub hub 是交接模式的可选实现，不是项目事实源的唯一后端。

**优先级与冲突规则**：用户本次明确指令和已有项目规则优先于模板默认值。日常任务、新项目建立与知识库后端走 §15 和 [统一任务契约](references/workflow-contract.md)；§0–§14 是**显式启用 GitHub hub + `main/dev` 的兼容交接模式**，其固定分支、`gh` 建仓与 WIP 脚本仅适用于已绑定该模式的项目。未启用时不得运行这些命令，也不得声称旧脚本支持任意后端。交接 Hub 是 WIP 指针与接力摘要，不是项目决策的第二正史。任何 `reset --hard`、强推和生产/公开变更都受当前权限门槛约束，不得仅因旧脚本含有命令而执行。

让任意 agent 把工作状态沉淀到 GitHub 私有交接总仓（hub），另一个 agent（跨平台/跨设备）读取后无缝继续，用户无需重复说明背景。

**三条不可违背的承诺：**
1. **不丢工作**——任何中间态（文档/代码）要么入库、要么留痕，绝不静默丢弃；
2. **不中断**——交接/同步/冲突处理永不因冲突卡住等待用户；无法自动裁决时按规则降级，信息全保留；
3. **凭据零落盘**——任何持久化文档不得含 token/密码/私钥/连接串。

> 本文件自包含。templates/ 与 scripts/ 是加速器；仅凭本文件即可完成交接。
> 完整设计原理见同仓库 `handoff-skill-design.md`（实施规格书）。

## 0. 名词

- **hub**：交接总仓（GitHub 私有 repo）；仅显式启用 Hub 模式时使用，`main` 单分支，存放交接文档。
- **项目 repo（Hub 模式）**：项目本体 repo；下文旧模式要求 `main`（正式版）+ `dev`（工作分支）。一般项目使用已绑定的实际分支，不套用此约定。
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
6. **提交（顺序约束）**：交接文档（首次建项目时含 README）必须先 commit 并 push 到 hub 远端；远端文档成功后，才生成并 push INDEX 指针。`scripts/save-handoff.sh` 的 INDEX CAS 重试可以 reset 到最新 `origin/main`，但不再依赖未推送的文档提交；文档 push 失败则停止并保留本地提交，不修改 INDEX。

## 4. 接手（Resume）

1. 用户指路（「接着上次做」，可带项目名）。
2. 定位：hub INDEX → 项目文件夹 → 项目 README 取 repo 地址。
3. 读最新交接；多任务列出让用户选。
4. 1–2 句复述「任务 / 项目位置 / 进度 / 下一步」。
5. 确认后 **确保项目 repo 就绪**（幂等）：本地无 `~/.agent-handoff/projects/<slug>/` → clone；有 → `git fetch && git checkout dev && git pull`。开工；随后按新进度更新交接（滚动接力）。
6. **里程碑合并**（§4.6 见下）。

## 5. 同步（Sync）——仅 Hub 模式的开工第 0 步

**适用门禁：**仅在项目已明确绑定 GitHub 私有 Hub 且采用 `main/dev` 工作模型时执行以下流程；其他新建/日常项目任务只执行 §15，禁止运行本节的 checkout/reset/WIP 命令。

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

## 11. 里程碑合并与 dev reset（仅 Hub 双分支模式；高风险，需单独授权）

**执行方仅在确认无未保全工作、目标分支与远端 HEAD 均已核对，且用户明确授权里程碑合并和 `dev` 重写时参考以下示例；示例不是自动执行许可。**
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

不做实时双向协同；不做对话全量回放；不做代码冲突 auto-merge；不接管任务调度；不追求全局时间全序；不做书签增量读（增量定位用 git 原生 `log`/`diff`）。

## 14. 分级提交与推送（项目状态实时上云）

> 目标：项目 repo 的 dev 分支成为「完整真相」，任何状态都在 GitHub。普通提交留痕即可、重要提交必须上云。
> **指令为主、hook 为辅**：下方 §14.1 的规则是所有 agent（含装不了 hook 的）都必须遵守的；hook 只是部分环境的自动加速器，装了更省心，装不了也按指令手做。

### 14.1 三档提交（所有 agent 必须遵守的指令）

| 档位 | 时机 | 动作 |
|---|---|---|
| **普通 commit** | 每个小步（改函数/调通一段/修警告） | 本地 `git commit`；随后**主动 `git push origin dev`**（能推就推，失败可暂缓攒着，不打断工作） |
| **重要 commit** | 功能完成 / bug 修复 / 方案敲定 / 测试通过 / 用户明说「存一下」「存档」/ 交接前 | commit message 加 `[important]` 前缀；**显式 `git push origin dev` 并校验退出码**，失败 → 停下提示「需要 git 认证」，不静默 |
| **交接沉淀** | §3 沉淀流程 | 补推所有攒着的普通 commit（`git push` 天然带上全部未推送提交），**并校验 `git status` 确认 ahead=0** |

> 无法装 hook 的环境，普通 commit 的自动推送就靠这条指令：**agent 每完成一个小步，commit 后顺手 push**；若 push 失败（弱网/无凭据），记在心里，在下一个「重要 commit」或「交接沉淀」时一起补推。交接前无论如何都要校验补推（双保险）。

### 14.2 post-commit hook（可选自动加速器）

- 仅对有 hook 能力的环境生效；hook 装在**项目 repo**（非 hub），由「确保项目 repo 就绪」步骤幂等安装（`scripts/install-project-hook.sh`）。
- hook 仅对 **dev 分支**生效（`git symbolic-ref --short HEAD` 判断，非 dev 跳过）。
- hook 强制非交互（`GIT_TERMINAL_PROMPT=0`、`GIT_ASKPASS=/bin/true`），防止无凭据/弱网时卡死 commit。
- 普通 commit push 失败静默；`[important]` 前缀的 commit push 失败回显警告。
- **hook 不是必需的**：装不了 hook 的环境，靠 §14.1 的指令达成同样的结果。

### 14.4 增量定位（不依赖书签）

A→B→A 场景，A 回归时用 git 原生能力看 B 推进了什么（**无需任何书签机制**）：
```sh
git fetch origin && git log --oneline origin/dev          # B 的提交一览
git diff <某commit>..origin/dev                            # 任意两点间的代码变化
```
全新 agent 则读最新一份交接快照（完整状态）冷启动。

## 15. 项目连续性：新项目初始化与日常任务（跨 Agent）

此模式不要求 hub、GitHub、`gh`、特定模型/运行环境或强制 `main/dev`。项目 Git 仓库（任意托管）是推荐事实源；可用具备 revision/并发校验的知识库。一个项目只绑定一个权威事实源，其余记忆/交接仅作入口。已有项目首次绑定由用户确认项目标识、事实源位置、工作分支、写入权限与同步方式；已有文档体系先映射复用，建议格式见 [project-memory-schema.md](references/project-memory-schema.md)。没有可核实的绑定或事实源不可达时，不以聊天记忆冒充最新记录。

### 15.0 新项目建仓与首次绑定

1. **确认范围与授权**：向用户确认项目名称、存放位置（或采用当前明确指定的目录）、本地/远端、远端托管方与账号或组织、仓库名、私有/公开、初始分支和是否需要 hub 跨 Agent 接力。默认私有、默认 `main`，**不默认创建 `dev` 或 hub**。用户说“新建并托管/上传项目”且已给出准确目标、所有者与可见性时，可视为该项目首次远端创建及推送的授权；仅说“规划/讨论”或“新建本地项目”时不创建远端。许可按本地编辑、commit、创建远端、push 分项判断（见任务契约）；缺少会导致建到错误账号、目录或公开范围的关键事实先询问。已存在同名仓库时停止并核实，不覆盖。
2. **检查与保护现状**：确认目标目录是否已有文件或 Git、目标远端是否存在、凭据/上传内容是否适合提交；已有目录不得用初始化流程覆盖。Git 可用但未配置作者身份时请用户配置或取得许可后为此仓库设置，不捏造身份。知识库后端只有具备版本读取和并发保护才能成为唯一事实源。
3. **建立本地基线**：仅在空目录或确认可安全复用的项目目录 `git init -b <确认分支>`；建立最小 README、`.gitignore`、项目约束与 `docs/project-memory/INDEX.md`、`STATUS.md`、`logs/YYYY.md` 初始条目（目标/范围/待确认项、来源、初始基线、本次执行者和验证）。必要时在项目 `AGENTS.md` 中加入简短的 Agent 无关规则，提示任何接手 Agent 先读项目索引、按需查历史、收尾写回；不得覆盖既有规则。初始内容未获确认的标 `proposed`/待确认，不把推测写成需求正史。安全扫描后仅 stage 本轮应提交文件，完成初始 commit；记录实际 commit SHA。空目录可先创建 README 等文件，避免空仓库历史无可读基线。
4. **建立远端（仅有授权时）**：按托管方选可用的官方 CLI/API/Web 流程，例如 GitHub 可用 `gh repo create <owner>/<repo> --private --source . --remote origin`，用户明确要求公开时才 `--public`。不要求 `gh`，GitLab/Gitea/自建 Git 可用等价官方机制；远端可由用户先创建再提供 URL。创建前再次核对 owner、名称和可见性，不把 token 写进 URL/文件/输出；如远端要求网站或交互确认，给用户明确步骤。远端创建成功但 push 失败时保留仓库地址和本地提交，标 `待首次同步`，不要再次建同名仓库。
5. **首次推送与验收**：在允许的分支 `git push -u <remote> <branch>`；随后 `fetch` 或远端 API 核查目标分支包含本地基线提交，远端项目记录可读。若不能推送，不称“项目已在远端就绪”，明确本地/远端分别处于哪一步以及如何继续。若已存在远端非空历史，先取回并审查，不能强推或盲目合并。选择 hub 模式时，待项目基线建立且项目的分支约定匹配后再初始化或登记 hub；使用 §3 固定 `main/dev` 建仓脚本需单独确认，不把它当所有新项目的通用步骤。

### 15.1 开工：同步并定向取证

1. 核对项目身份、远端/知识库地址、目标分支、当前 revision 和本地未提交/未推送内容。Git 先 `status`/`remote`/`fetch`，仅在安全时 fast-forward；**不自动 reset/stash/覆盖/切换分支**。如需使用 §5 的 wip 收编，先确认项目明确采用 hub 双分支模式、允许该操作且能保全已有工作；冲突时先保护残留，不能把 §5 的 `reset --hard` 当普通同步命令。远端不可达时标明基线并待同步，除非用户明确接受离线继续，否则不做依赖最新状态的变更。
2. 读项目规则、权威索引、当前状态，再按模块/路径/符号/关键词查现行需求、ADR、Bug 和相关日志；结合最近关联提交和代码验证。旧决策查是否被取代；不通读多年日志，不将 hub 摘要凌驾于项目最新已验证提交。需要接力时可先读 hub 定位任务，再回项目事实源核实。
3. 简述本次基线：项目/分支/revision、目标模块、历史决策、当前风险与目标。用户最新明确决定与旧规则冲突时记录取舍；无法判断时询问，不编造事实。

### 15.2 收尾：只对实际获准变更记账

- 只读调查/需求讨论不写文件、不 commit/push；日常任务分类和权限见 [统一任务契约](references/workflow-contract.md)。实施变更后根据真实 diff/验证更新项目当前态、受影响规范和决策；向项目 `docs/` 下按年分卷的日志追加一条有稳定唯一 ID 的记录（模块、基线、改动、原因、验证、遗留风险及关联指针）。重试先查询该 ID，禁止重复记账。日志和改动一起提交；当前提交 SHA 事后由日志 ID 与 Git 历史关联，禁止预填尚不存在的 SHA。未提交/未验证标记 WIP，不能记为已交付。
- 提交或知识库条件写入前，对**所有**持久化内容（项目代码与文档、索引、状态、ADR、Bug、年度日志、交接 Hub 和建议补丁）按 §8 检查凭据及不应传播的私人/客户数据；命中时拒写、不回显内容，先清理再复核。仅在当前任务获得对应写入、commit、远端同步授权且不会覆盖并发进展时执行相应动作；绑定或读权限不推定写权限。推送拒绝则 fetch 审查，保留原提交并标 `CONFLICT/未同步`；离线/认证失败则保留本地状态，不强推、不冒称远端一致。生产变更、公开发布和首次远端写入需要明确授权。
- 校验日志 ID 与实际 diff/测试吻合、现行索引能定位记录、提交包含代码与日志；Git 推送后重新 fetch 并确认远端包含目标提交；知识库通过 revision/ETag 复读。汇报实际验证和「仅本地 / 已提交 / 已同步远端」状态，不把文档完成当成项目验收。

### 15.3 与原交接模式衔接

明确要跨 Agent 交接时，在项目任务记账与安全同步状态核实后再执行 §3 的 Save；交接文档只记录任务指针、WIP/阻塞、项目记录 ID 与可到达的提交或知识库 revision。§3 的「当前会话摘要」仅作为交接补充；新接手者以本节事实源重新取证。若项目并未采用 hub `dev` 工作模式，不要求切换 `dev` 或推送未获准发布的项目变更；记录实际未同步状态和交接限制，不得谎称无缝交接。原脚本仅适用于已采用其约束的 hub 项目，不能用于任意知识库或其它分支模型。
