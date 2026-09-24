# 跨 Agent 接力 Skill — Hub 模式实施规格书（v10.1 修订版）

> 本规格书记录 v1.0.1 的 **GitHub Hub 双分支交接模式**，不是 v1.1.0 日常项目连续性的完整规格。v1.1.0 的新任务路由、授权与项目事实源规则以 [SKILL.md](SKILL.md) §15、[统一任务契约](references/workflow-contract.md) 和 [项目事实源约定](references/project-memory-schema.md) 为准；与本规格书固定 `main/dev` 假设冲突时，不可把旧命令套用于非 Hub 项目。
> 状态：v1.0.1 Hub 模式实现修订，可作为已启用 Hub 项目的实现蓝本。
> v10.1 修订：修复 `save-handoff.sh` 的 INDEX CAS 丢文档风险；保存改为「文档先远端、INDEX 后 CAS」两阶段提交，并补充本地 bare remote 回归测试。
> v10 修订：§4.3a `new_branch_name` 函数 `local base="$1" w="$base"` 拆为两行（修复同行多赋值导致 `$base` 不展开、`w` 恒空、`checkout -b ""` 崩溃的致命 bug，实测确认）。
> v9 修订：§3.10 URL 内嵌凭据正则用户名段 `+`→`*`（修复空用户名形态 `redis://:pwd@` 漏检）。
> v8 修订（v7 全文终审）：§3.5 探测命令改显式取登录名（修复 `{owner}` 误展开）；§3.5 失败分级改解析 HTTP 状态码；§3.10 凭据扫描统一 `grep -E` 并补全高危形态；§3.3 明确 `.handoff-project` 随 README 先于推 main 提交、dev 继承；§5.4 补 blob SHA 命令 `git rev-parse origin/main:INDEX.md`。
> 本文档经三轮独立审查 + 多轮模型对辩（含真机 git 实测验证）收敛而成，规则精确到命令与字段，不留「看情况」。
> v7 修订（经 v6 独立审查 + 辩论收敛）：
> - §4.6 ② 里程碑前置校验方向修正为 `is-ancestor main dev`（原 `dev main` 写反，会致 merge 永不执行）；
> - §4.6 reset 不再产生 `[dev-reset]` commit（避免污染 main 历史），检测改纯拓扑判定（§5.1），消除标记竞态盲区；
> - §4.3a 冲突路径废弃 merge commit 语义（`git add` 冲突文件会造成 git 状态伪装），改残留**独立分支** `dev-wip/<agent>-residue-<ts>` 单独 push（不切工作区、零覆盖）；
> - §4.3a `LOCAL_WIP_REF` 动态解析（兼容 detached/非 dev 分支）、碰撞兜底改用 `show-ref`（不依赖 ls-remote 退出码）；
> - §4.1 提交顺序约束：交接文档 commit 先于 INDEX 指针 commit push；
> - §4.3 注明合并 pending 仅消费 hub 侧 INDEX 数据；
> - 序号更名 `seq`，明确仅作 INDEX 内部排序、不与文档绑定。

## 0. 名词约定

| 名词 | 含义 |
|---|---|
| **hub** | 交接总仓库（GitHub 私有 repo），唯一，存放全部交接文档 |
| **项目 repo** | 项目本体所在的 GitHub repo，一项目一个，与 hub 双仓分离 |
| **交接文档** | 一次工作状态的结构化快照（中文 Markdown） |
| **沉淀（Save）** | 当前 agent 把会话上下文写成交接文档并推 hub |
| **接手（Resume）** | 新 agent 从 hub 读交接、克隆项目、继续工作 |
| **同步（Sync）** | 任何 agent 开工前的第 0 步：对齐 hub 与项目 repo 到远端最新 |
| **降级 agent** | 无法执行 git/shell 的环境（如部分 IDE agent），只读、产出建议文件 |
| **wip 分支** | `dev-wip/<agent名>-<YYYYMMDD-HHmm>`，代码冲突时本地未推送工作的留痕分支 |

## 1. 设计目标与核心承诺

让任意 agent 把工作状态沉淀到 hub，另一 agent（跨平台/跨设备）读取后无缝继续，用户无需重复说明背景。

**三条不可违背的承诺：**
1. **不丢工作**——任何中间态（文档/代码）要么入库、要么留痕，绝不静默丢弃；
2. **不中断**——交接/同步/冲突处理永不因冲突而卡住等待用户；无法自动裁决时按规则降级，信息全保留；
3. **凭据零落盘**——任何持久化文档不得含 token/密码/私钥/连接串。

## 2. 架构总览

```
GitHub 私有空间
├── handoff-hub（交接总仓，唯一，仅 main 单分支）
│   ├── INDEX.md                      # 全局索引（中文）
│   ├── pending/                      # 降级 agent 的建议文件暂存区
│   ├── unregistered/                 # 未入库项目的交接暂存区
│   ├── <项目slug>-中文说明/           # 每项目一文件夹
│   │   ├── README.md                 # 中文详细说明 + 项目 repo 指针 + slug
│   │   ├── <YYYYMMDD-HHmmss>-<agent>-<任务>.md   # 交接文档
│   │   ├── pending/                  # （可选）该项目级建议暂存
│   │   └── archive/<任务>-<首交日期>/  # 已完成任务的交接链
│   └── .gitignore                    # .env、*.pem 等敏感文件名
├── my-web-app（项目 repo，main + dev 双分支）
│   └── .handoff-project              # 内容为 hub 项目文件夹的 slug（main/dev 都提交）
└── nas-tools（项目 repo）
```

**双仓分离**：项目代码在项目 repo，交接文档在 hub，永不混淆。hub 仅 main 单分支；main/dev 双分支模型仅适用项目 repo。

## 3. 协议规则（硬约束）

> 本节规则必须被每个实现精确执行。

### 3.1 格式基线与降级

- Skill = 单文件夹 + `SKILL.md`（YAML frontmatter，Anthropic Agent Skills 规范）。
- **SKILL.md 自包含**：templates/scripts 是加速器，仅凭 SKILL.md 内嵌模板即可完成交接。
- 降级 agent：把 SKILL.md 当普通 Markdown 读（rules/系统提示词/对话粘贴）。

### 3.2 可见性

- 建仓默认 `gh repo create --private`。
- 用户显式声明「公开」→ 用 `--public`，选择写入项目 README「可见性：公开（用户声明确认）」留痕，后续 agent 不再问。
- **任何转 public 或建 public 前**：强制对仓库**全部历史**做一次凭据扫描（不止当前写入），命中即中止并提醒。

### 3.3 项目分支模型（仅项目 repo）

- `main` = 正式可用版本；`dev` = 一切工作发生地（含做到一半的中间态）。
- 新项目首个可用版本前 main 保持不动；所有工作在 dev。
- 跨 agent 接力永远发生在 dev。
- **建仓步骤**（定死，含 `.handoff-project` 时序）：`git init`（默认 main）→ 写 README **和 `.handoff-project`（单行 slug）** → 一并提交进 main → `gh repo create --private` → 推 main → `git checkout -b dev`（**dev 自 main 继承这两个文件，无需二次提交**）→ 工作内容提交 dev 并推。
  > `.handoff-project` 必须在「推 main 之前」随 README 一起提交进 main，dev 从 main 拉出即天然继承，保证两分支该文件**内容一致**（§3.4「并发冲突取远端 dev 版本」的前置）。若建仓时遗漏，则需 main 与 dev 各补提交一次。

### 3.4 项目标识与双向留痕

- 项目唯一标识 = git 远端 repo 名；无 repo 时用顶层目录名。
- hub 项目文件夹名 = `<稳定slug>-<中文说明>`；**slug 创建时生成、只增不改、与显示名解耦**，迁移/fork 时随 `.handoff-project` 一起走。
- `.handoff-project`（单行：slug）建仓时提交进 main 和 dev，是骨架文件，不随功能改动；**内容固定、谁先推谁赢、并发冲突时取远端 dev 版本**。双向反查：hub 项目 README 冗余记录 slug 与 repo 地址。
- **交接序号（`seq`）** = INDEX 活跃任务表该任务行的「序号」列；**仅作 INDEX 内部展示/排序，非唯一标识、不与文档绑定**（文档靠时间戳+agent 名标识）。新交接取该项目最大 seq +1（§5.4：仅在 CAS 写回成功后生效，撞号重取）；文件名保持时间戳命名，不含序号。

### 3.5 hub 发现（三层降级）

定位 hub 依次尝试：
1. 环境变量 `AGENT_HANDOFF_HUB`（仓库地址）；
2. 配置文件 `~/.agent-handoff/config`（字段：`hub_url`、`hub_local`、`agent_name`；**不含凭据**）；
3. 约定名探测：查**当前登录账号**下的 hub repo。命令必须显式取登录名，**不得用 `repos/{owner}/handoff-hub`**——`{owner}` 会被 gh 展开为「当前目录所在 repo 的 owner」，agent 开工时常处在某项目 repo 目录下，会探测到错误位置甚至误命中他人 hub。正确命令：
   ```sh
   gh api "repos/$(gh api user --jq .login)/handoff-hub"
   ```

**`gh api` 失败分级**（**HTTP 状态码**处理，非进程退出码——`gh api` 在 HTTP 失败时统一返回退出码 1，状态码需从输出解析）：
```sh
out=$(gh api "repos/$(gh api user --jq .login)/handoff-hub" 2>&1); rc=$?
if [ $rc -eq 0 ]; then : # 命中 hub
else
  code=$(printf '%s' "$out" | grep -oE 'HTTP [0-9]{3}' | grep -oE '[0-9]{3}' | head -1)
  case "$code" in
    401) : # 未登录 → 按降级处理并提示 ;;
    403|404) : # 无权限/不存在 → 询问用户建仓/授权 ;;
    429) : # 限流 → 退避重试 ;;
    422) : # 校验错 → 询问/人工 ;;
    *) : # 网络或其他错误 → 重试 ;;
  esac
fi
```

三层皆空 → 询问用户一次并写入 config（**原子写：先写同目录临时文件再 mv**，跨文件系统时降级为 cp+fsync；多 agent 并发本地写 config 时需防覆盖）。hub 统一 clone 于 `~/.agent-handoff/hub`，本地缺失则 clone（repo 已存在**仅 clone 不重建**，幂等）。

**项目 repo 本地布局**：统一 clone 于 `~/.agent-handoff/projects/<slug>/`（与 hub `<slug>-中文说明/` 一一对应；slug 归一化：小写、非 `[a-z0-9-]` → `-`、连续 `-` 折叠）。接手（§4.2）与同步（§4.3）的「clone/pull」合并为一条幂等「确保项目 repo 就绪」操作（无则 clone、有则 fetch+pull），不再区分两处。

### 3.6 agent 身份（三层降级）

`$AGENT_NAME` 环境变量 → config 的 `agent_name` → agent 自报家名（如 "DeepSeek Harness"）。用于交接文档署名、INDEX 更新者列、冲突文件命名、wip 分支命名。

### 3.7 交接文档命名与防碰撞

- 文件名：`<YYYYMMDD-HHmmss>-<agent名>-<任务简述>.md`（秒级 + agent 名）。
- **命名碰撞兜底**（本地时钟仍可能秒级撞名）：
  ```sh
  f="<dir>/$(date +%Y%m%d-%H%M%S)-$AGENT-$TASK.md"
  while [ -e "$f" ]; do f="${f%.md}-$(openssl rand -hex 2).md"; done
  ```
  撞名时追加 4 位随机 hex，并同步更新 INDEX 链接。

### 3.8 交接文档模板（中文）

```markdown
---
origin: agent                # agent | degraded-agent-suggestion
wip-status: none             # none | pending | absorbed | abandoned
# 仅 degraded 建议额外带 merged: false（普通交接文档省略 merged 字段）
---

# 交接：<任务名>
> 更新于 <UTC ISO-8601 时间戳> by <agent 名称> | 状态：进行中 / 已完成 / 阻塞
> 序列：<项目内递增序号>
> 交接文件：<与文件名一致>

## 一句话目标
## 项目指针
- 仓库：github.com/<用户>/<repo>（私有/公开）
- 工作分支：dev（接力现场所在；main 仅放正式可用版本）
- 相关目录：<子目录>
- wip 分支：<如有，dev-wip/... 指针 + 状态>
## 当前进度
- [x] 已完成……
- [ ] 未完成……
## 下一步（最重要）
## 关键决策与理由
## 上下文指针（文件路径 / commit hash / issue·PR 链接 / 复现命令）
## 阻塞与注意事项（可选）
```

**语言细则**：描述性文字全中文；代码、路径、分支名、repo 地址、commit hash 等标识符**保持原样，严禁翻译**。

### 3.9 内容边界（硬规则）

| 类别 | 规则 |
|---|---|
| 必写 | 目标 TL;DR、进度（已完成/未完成）、下一步、关键决策与理由 |
| 选写 | 上下文指针（路径/分支/commit/issue 链接/复现命令） |
| 禁写（安全） | 凭据/token/密码/私钥/cookie/**连接串/配置/环境变量样例**——只写引用（「凭据在环境变量 XXX」） |
| 禁写（体积） | 超 ~30 行日志/diff/代码块 → 指向文件或 commit hash |
| 默认警告 | 敏感个人信息、未公开商业信息——默认不写，必要时提醒用户确认 |
| **摘要原则** | **只写结构化摘要，禁止把会话上下文原文搬进文档**（既缩泄露面，又与「不做全量回放」自洽） |

### 3.10 凭据扫描（硬性）

写入任何持久化文档前，用 **`grep -E`（扩展正则，必须显式 `-E`**，否则部分模式在 BRE 下静默漏匹配）扫描常见形态，命中即**拒写并提醒**。扫描范围 = 待写入的结构化摘要**全文**（含 frontmatter 与正文）。

最小模式集（可按需扩充）：
```sh
SECRET_RE='(ghp_[A-Za-z0-9]{36}|gho_[A-Za-z0-9]{36}|github_pat_[A-Za-z0-9_]{22,}|sk-[A-Za-z0-9_-]{20,}|sk_live_[A-Za-z0-9]{10,}|rk_live_[A-Za-z0-9]{10,}|AKIA[A-Z0-9]{16}|xox[baprs]-[A-Za-z0-9-]{10,}|AIza[A-Za-z0-9_-]{35}|eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{5,}|-----BEGIN [A-Z ]*PRIVATE KEY-----|PuTTY-User-Key-File|://[^/@[:space:]]*:[^/@[:space:]]+@|Bearer [A-Za-z0-9._~-]{10,}|(access_token|_authToken|api[_-]?key|secret|password|passwd|aws_secret_access_key)[[:space:]]*[=:][[:space:]]*[^[:space:]]+)'
printf '%s' "$PENDING_CONTENT" | grep -Eq "$SECRET_RE" && { echo "命中疑似凭据，拒写" >&2; exit 1; }
```

模式说明：`ghp_`/`gho_`/`github_pat_`（GitHub token）、`sk-`/`sk_live_`/`rk_live_`（OpenAI/Stripe key）、`AKIA...`（AWS Access Key）、`xox[baprs]-`（Slack token）、`AIza...`（Google API key）、`eyJ...x.y.z`（JWT）、`-----BEGIN ... PRIVATE KEY-----`（各类私钥头）、`://...@`（**任意 URL 内嵌凭据**，用户名段允许为空，含 `gitlab-ci-token:glpat-..@`、`rediss://:pwd@`、`redis://:password@`、`mongodb+srv://user:pw@` 等，覆盖原 `://user:pass@` 漏掉的形态）、`Bearer ...`（Bearer token）、`access_token=/password=/api_key=` 等键值对。

## 4. 行为流程

### 4.1 沉淀（Save）

0. **hub 定位**：按 §3.5 三层降级；本地缺失则 clone（幂等）。
1. **项目入库检查**：以远端 repo 名为标识。未入库 → 询问建仓（§3.3 六步 + 写 `.handoff-project`）；用户拒绝 → 沉淀到 hub `unregistered/`，强制记录本地绝对路径，入库后迁移。
2. **项目文件夹定位/新建**：名取 `.handoff-project` 的 slug 或首次生成；首次写项目 README（中文说明 + repo 指针 + slug）。
3. **多任务归属判定**：查 INDEX 该项目活跃任务 → 续写对应任务线（项目内最大序列号+1）或新建（序列号从 1）。**内容来源 = 当前会话上下文的结构化摘要**；本会话无任务上下文 → **拒绝沉淀**，提示「先同步接手再交接」。
4. **生成**：按 §3.8 模板 + §3.7 命名（含碰撞兜底）；更新 INDEX（§4.5）。状态首次「已完成」→ 同 commit 内联动归档（§4.4）。
5. **安全检查**：§3.10 扫描，命中拒写。
6. **提交（顺序约束）**：交接文档（首次建项目时含 README）必须先 commit 并 push 到 hub 远端；远端文档成功后，才生成并 push INDEX 指针。INDEX CAS 重试允许 reset 到最新 `origin/main`，因为文档提交已在远端；文档 push 失败则停止并保留本地提交，不修改 INDEX。

### 4.2 接手（Resume）

1. 用户指路（「接着上次做」，可带项目名）。
2. 定位：hub INDEX → 项目文件夹 → 项目 README 取 repo 地址。
3. 读最新交接；多任务列出让用户选。
4. 1–2 句复述「任务 / 项目位置 / 进度 / 下一步」。
5. 确认后 clone/pull 项目 repo 并 `git checkout dev`，开工；随后按新进度更新交接（滚动接力）。
6. **里程碑合并**（见 §4.6）。

### 4.3 同步（Sync）——开工第 0 步，全自动

定死顺序：**fetch → 读最新交接（拓扑）→ 扫 pending → 合并 pending（语义）→ 同步代码 → 动工**。

1. `git fetch` hub，pull 到最新。
2. **读该项目最新交接**：用 §5.1 merge-base 判新旧（拓扑，不比时间戳）。此处确定的项目内最新序列号供下一步合并 pending 时取号。
3. **扫 pending/**：`git ls-files pending/` + `git status --porcelain pending/`（含 untracked，降级建议落盘多为 untracked）。发现建议文件 → 按 §5.3 语义合并（LLM 判断同/异）→ 用第 2 步读到的序列号续号 → commit。**注：合并 pending 仅消费 hub 侧 INDEX 数据**（hub 第 1 步已 fetch，数据为最新），不依赖项目 repo 就绪。
4. **确保项目 repo 就绪**（幂等，与接手共用）：本地无 `~/.agent-handoff/projects/<slug>/` → clone；有 → `git fetch && git checkout dev && git pull`。
5. 他人推进过 → 一句话汇报「谁/何时/推进了什么/下一步」→ 直接续做。
6. **代码冲突**（本地未推送残留 vs 远端）：**不 stash**——按 §4.3a wip 流程留痕。
7. **本地 dev 对齐判定**（拓扑，§4.6）：`is-ancestor 本地dev origin/dev` 为真（本地落后，含远端刚 reset）→ `git checkout -B dev origin/dev` 对齐；本地领先/分叉 → 不对齐，本地工作保留，分叉已在第 6 步 wip 收编。

### 4.3a 代码冲突的 wip 留痕流程（实测验证）

核心原则：
- **冲突判定不依赖 `git merge` 退出码**（现代 git `ort` 策略对某些场景会静默取一侧、不报冲突），改用 `git merge --no-commit --no-ff` 后**显式检查 unmerged 条目**（`git ls-files -u`）——跨版本可靠。
- **冲突路径绝不用 merge commit 语义**（`git add` 冲突文件会清掉「未合并」状态，commit 后 git 认为合并已完成，下游不再报冲突——git 状态伪装）。残留以**独立分支**存档，不切工作区、零覆盖。
- **任何 push 失败都不丢工作**（push 检查退出码，失败重试换名或转 residue）。

```sh
# 前置：确保 dev-wip 命名空间的远端引用最新且已 prune（定向 fetch dev 不更新 dev-wip/*；--prune 清本地残留）
git fetch origin dev
git fetch --prune origin "+refs/heads/dev-wip/*:refs/remotes/origin/dev-wip/*" 2>/dev/null || true
# ① 前置固化：未提交残留固化为 ref（已提交/未提交统一处理）
git add -A
git commit -m "wip: $AGENT 未提交残留（固化）" || true   # 无改动时跳过
LOCAL_WIP_REF=$(git symbolic-ref --short -q HEAD || git rev-parse HEAD)
TS=$(date +%Y%m%d-%H%M)

# ② 生成不碰撞的分支名（同时查远端引用和本地分支；wip 与 residue 共用此函数避免同分钟撞名）
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

# ③ 从最新远端 dev 建 wip（检查退出码），预判冲突（不依赖 merge 退出码，用 ls-files -u）
if ! git checkout -b "$W" origin/dev; then
  echo "错误：无法创建 wip 分支 $W" >&2; exit 1
fi
git merge --no-commit --no-ff "$LOCAL_WIP_REF" 2>/dev/null
if [ -n "$(git ls-files -u)" ]; then
  # ④ 有冲突：abort（仅在 merge 状态时），残留独立分支 push 留证
  if [ -f "$(git rev-parse --git-dir)/MERGE_HEAD" ]; then
    git merge --abort
  else
    git reset --hard origin/dev
  fi
  git branch "$RESIDUE" "$LOCAL_WIP_REF"      # 仅命名 ref，不 checkout，零扰动
  git push origin "$RESIDUE"                  # 残留存档，待下游消化
  MERGED_OK=0
else
  # 无冲突：完成 merge（生成真正的 2-parent merge commit）
  git commit --no-edit -m "wip: $AGENT 未推送残留（与远端 dev 冲突，待消化）" 2>/dev/null || true
  MERGED_OK=1
fi

# ⑤ push W，检查退出码；失败（并发撞名/被拒）则换名重试，仍失败转 residue 兜底
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
  # push 持续失败：本地工作不丢，固化到 residue 分支留证
  git branch -f "$RESIDUE" "$LOCAL_WIP_REF" 2>/dev/null || git branch "$RESIDUE" "$LOCAL_WIP_REF"
  git push origin "$RESIDUE" 2>/dev/null || echo "警告：wip/residue push 失败，工作保留在本地分支 $RESIDUE 与 reflog" >&2
fi

# ⑥ 本地 dev 以远端为准继续（此时残留已安全落于 W 或 RESIDUE）
git checkout dev && git reset --hard origin/dev
```

交接文档记录 wip 指针（冲突或 push 失败时同时记 residue 分支指针）+ `wip-status: pending`。下游接手方按 `wip-status: pending` 消化 residue 分支（自行 merge 并解决冲突），消化后更新为 `absorbed` 并可删分支。

### 4.4 归档（archive）

- 触发：沉淀时任务状态首次「已完成」，**同一次 commit 内**完成下列全部动作（原子，防脏状态）。
- 动作：该任务全部历史交接文档移入 `archive/<任务简述>-<首次交接日期>/`；INDEX 该行从「活跃」移入「已完成」（指向 archive 路径）。
- 只动 hub，不动项目 repo。

### 4.5 INDEX.md 格式与更新

```markdown
# 交接总索引
> 由 agent-handoff 维护，全部中文。

## 活跃任务
| seq | 项目 | 任务 | 最新交接 | 更新时间(UTC) | 状态 | 更新者 |
|---|---|---|---|---|---|---|
| 3 | [my-web-app-电商网站重构](...) | 修复登录bug | [08-07-2130](...) | 2026-08-07T13:30Z | 进行中 | DeepSeek Harness |

## 已完成（最近 20 条）
| 项目 | 任务 | 完成时间 | 归档位置 |

## 冲突记录
| 时间 | 类型 | 说明 |
```

更新规则：沉淀即更新对应行（无则新增）；「已完成」同 commit 移表；冲突记录追加末尾。

### 4.6 里程碑合并与 dev reset

- 触发：形成可用版本且用户确认。

**执行方（由触发 agent 负责）：**
```sh
# ① 同步本地分支到远端（merge --ff-only 只快进，本地领先/分叉则报错暴露异常）
git fetch origin dev main
git checkout main && git merge --ff-only origin/main
git checkout dev
# ② 前置校验（merge 前）：dev 领先 main（main 是 dev 祖先）才允许推进里程碑
if ! git merge-base --is-ancestor main dev; then
  echo "main 有 dev 未包含的提交，需先同步 main，中止" >&2; exit 1
fi
# ③ 记录 reset 前远端 dev（必须在 reset 之前取值）
OLD_DEV=$(git rev-parse origin/dev)
# ④ 里程碑合并：dev 合入 main
git checkout main && git merge --no-ff dev -m "里程碑 vX：merge dev into main"
git push origin main
# ⑤ dev 重置到 main 重新出发（不产生 [dev-reset] commit，避免污染 main 历史）
git checkout dev && git reset --hard main
# ⑥ force-with-lease 防吞并发；失败=并发写，重读不静默
if ! git push --force-with-lease=dev:"$OLD_DEV" origin dev; then
  echo "dev 在 reset 期间被并发修改，需重新 fetch 判定" >&2; exit 2
fi
# ⑦ reset 事件记入 hub INDEX 冲突记录节（不进 git 历史）
```

**检测方（其他 agent 开工第 0 步）：**统一走 §5.1 拓扑双向判定，**不依赖 `[dev-reset]` commit 标记**：
- `is-ancestor 本地dev 远端origin/dev` 为真（本地落后）→ `git checkout -B dev origin/dev` 对齐；
- 本地领先或分叉 → 不强行对齐，本地工作保留，分叉交 §4.3a wip 流程收编。

**判定公理**（`git merge-base --is-ancestor A B` 返回 0 ⟺ A 是 B 的祖先）：
- 「dev 领先 main = 可推进里程碑」= `is-ancestor main dev` 为真；
- 「本地落后远端」= `is-ancestor 本地dev 远端origin/dev` 为真 → 才对齐；
- 本地领先/分叉 → 不对齐，分叉交 wip 收编（自洽闭环）。

> `[dev-reset]` 仅是 hub INDEX 冲突记录节里的解释性文本，**不承担 git 触发职责**（避免空提交污染 main 历史、避免检测依赖标记的竞态盲区）。

> 注：git 层并发防护（`--force-with-lease`）与交接层 CAS（§5.4）分属两层、同时存在、互不替代。

## 5. 并发与一致性模型

> 核心原则：**不追求全局时间全序**（跨设备时钟不可靠）。**拓扑管已入库文档的新旧，语义管内容的同异**；信息永保留。

### 5.0 判定优先级（总原则落地）

1. 有公共拓扑（两份都已在 git）→ 先跑 merge-base 判新旧；**分叉（双失败）→ 各自保留，不路由语义**；
2. 无公共拓扑（pending vs 已有、INDEX 并发行）→ 直接语义判断（§5.3）；
3. 语义只回答「同 / 不同 / 不确定」，**不回答新旧**。

### 5.1 新旧判定（拓扑，替代时间戳）

用 `git merge-base --is-ancestor` 双向判定（hub 与项目 repo 同规则）：
- `is-ancestor 本地HEAD 远端HEAD` 真 → 本地旧，需同步，不写；
- `is-ancestor 远端HEAD 本地HEAD` 真 → 本地新，可推进；
- **双失败**（并发分叉）→ 两份各自保留（按 §5.0 第 1 条），是否合行由语义判断（§5.3）决定。

### 5.2 并发分级处理

| 场景 | 处理 |
|---|---|
| 不同交接文档并发 | 文件名天然去重（§3.7），合并即共存，无需定序 |
| INDEX 同项目并发追加不同任务 | CAS 重试（§5.4），后写者写下一行 |
| INDEX 同项目并发写疑似同任务 | CAS 重试时语义判定（§5.3） |
| 代码并发冲突 | §4.3a wip 留痕，不 stash、不 auto-merge |
| 降级建议并发 | 按 §5.3 语义合并 |

### 5.3 语义合并（判定「同一任务」）

- **执行者 = LLM agent**（判断「是不是同一任务」是语义理解，非字符串匹配）；**shell 脚本只在 CAS 冲突时输出两份候选文档路径**，不做相似度计算。
- **不设数值阈值**（difflib 字符级对中文不可靠，如「修复登录超时」vs「解决用户登录请求超时的问题」字符差异大但同义，唯有 LLM 能判）。
- 输入：两份文档正文的「一句话目标」+「下一步」字段。
- **三态默认动作**：判「同任务」→ INDEX 合一行（链接保留两条，行尾加 `(合并@<时间> by <agent>，原始见 <链A> <链B>)`）；判「不同任务」→ 两行并立；判「不确定」→ 两行并立 + 后写 agent 标 `needs-review`。
- **不引入 UNRESOLVED**：两份原始交接文档永存，信息不丢，后续人可纠正。

### 5.4 CAS 重试

INDEX 更新采用「fetch 后比对 **INDEX.md 的 blob SHA**（非整个 hub HEAD，避免无关项目并发触发误重试），变了就重判归属再提交」。取 blob SHA 的命令（已实测）：`git rev-parse origin/main:INDEX.md`（fetch 后返回远端 INDEX.md 的 blob SHA；与本地待提交版本比对，不同则重判）。**重试上限 3 次**，超限转 §5.3 语义合并路径。序列号仅在 CAS 写回 INDEX 成功后生效，撞号时 CAS 冲突重取。

为满足「文档 commit 先于 INDEX 指针」且避免 CAS 失败丢文档，保存实现采用两阶段提交：先将交接文档（首次建项目时含 README）commit 并 push 到 `origin/main`，再基于最新 INDEX 生成指针并 CAS push。INDEX 阶段允许 `reset --hard origin/main`，因为文档副本已经在远端；文档阶段 push 失败则保留本地提交并停止，不修改 INDEX。

### 5.5 文档冲突裁决

hub pull 遇文档冲突：双份保留——旧版重命名 `冲突-<YYYYMMDD-HHmm>-<agent名>.md` 存档；**以远端版本为准、本地版存档，不做内容级 merge**；INDEX 追加冲突记录；下次交互一句话告知。

## 6. 降级 agent 闭环

降级 agent **只读、不直接写 hub**，产出建议文件，由有 git 能力的 agent/人合并。

- **产出**：对话输出精确格式的建议文件（§3.8 模板 + front-matter `origin: degraded-agent-suggestion`、`merged: false`），提示用户存为 hub `pending/<YYYYMMDD-HHmmss>-<agent名>-建议.md`（时间戳用建议内容里的，非存盘时间）。
- **合并**：有 git 能力的 agent 在 §4.3 第 0 步扫 pending/（含 untracked）→ 采用建议（几乎不改写，因同构）→ 更新 INDEX/生成交接 → commit → 建议文件移出 pending/。

## 7. 安全设计

1. **凭据零落盘**：§3.9 禁写 + §3.10 扫描 + **摘要原则**（不搬原文，从源头缩泄露面）。
2. **私有默认 + 转 public 强扫**：§3.2。
3. **无网络凭据依赖**：git 推送复用本机 git/gh 认证，Skill 不存储、不询问 token；config 不含凭据。
4. **.gitignore 双保险**：hub 初始化加入 `.env`、`*.pem`、`*.key`、`secrets*` 等。

## 8. 运维约定（软约定，不入协议主流程）

- **wip 分支清理**：谁创建谁/谁消化谁清理。删除前先验证：`git branch -r --merged origin/dev | grep dev-wip/` 命中才可删（`wip-status` 为 `absorbed`/`abandoned`）。
- **清理日**（批量兜底，定期由用户或 agent 执行）：
  ```sh
  git branch -r --merged origin/dev | grep 'dev-wip/' | sed 's|origin/||' | xargs -r git push origin --delete
  ```
- **config 备份**：`~/.agent-handoff/config` 可入 dotfiles 备份（无凭据，安全）。

## 8b. 分级提交与推送（v11 新增）

> 缘起：实现「项目仓库 = 完整真相、任何状态都在 GitHub」的无缝接力。经 v4-pro 审查 + git 实测收敛。

### 设计取舍（审查结论）

- **放弃书签增量读**：原设想在交接文档记「各 agent 上次读到哪」的书签表，审查发现①书签是可变状态、不能塞进不可变的交接快照（无权威版本）②里程碑 squash/reset 后书签指向孤儿 commit、`git log 书签..dev` 语义错乱③按 agent 记书签维度错（应按任务）④真实收益有限——重读叙事快照才是成本大头，而 git 原生 `log`/`diff` 本就能查任意两点增量。故**增量定位交给 git 原生能力**，不另造书签系统。
- **保留分级提交**：普通 commit（每小步，留痕+静默推）、重要 commit（`[important]` 前缀+显式推+失败停下）、交接沉淀（补推）。

### 关键实现点（均经实测）

**指令为主、hook 为辅**：hook 不是必需组件，只是「有 hook 能力环境」的自动加速器。真正的主体规则写在 SKILL.md §14.1 指令里，所有 agent（含装不了 hook 的）都遵守：普通 commit 后主动 push（失败可暂缓）、重要 commit 显式 push 校验、交接前补推校验。装不了 hook 的环境靠指令达成同样的「普通留痕、重要必上云」结果。



1. post-commit hook 装在**项目 repo**（非 hub），由「确保项目 repo 就绪」幂等安装。
2. hook 仅对 dev 分支生效（`git symbolic-ref --short HEAD` 判断）。
3. hook 强制非交互（`GIT_TERMINAL_PROMPT=0`、`GIT_ASKPASS=/bin/true`），实测无凭据时 commit 不卡死。
4. 普通 commit push 失败静默；`[important]` 前缀 push 失败回显警告（实测正确）。
5. 补推跨 reset 边界：先 `fetch` + `is-ancestor 本地dev origin/dev` 判定，分叉走 §4.3a wip 留痕，不直推。

## 9. 明确不做（Out of Scope）

- 不做实时双向协同（离散快照序列 + §5 并发模型）；
- 不做对话全量回放（只结构化摘要）；
- 不做代码冲突 auto-merge（wip 留痕 + 以远端为准）；
- 不接管任务调度（首次定位需用户指路；已知项目循环接力全自动）；
- 不追求全局时间全序（§5，用 git 拓扑 + 语义替代）。

## 10. 各 agent 安装

| 环境 | 安装 |
|---|---|
| DeepSeek Harness | 目录放入 skills 路径 |
| Claude Code | `~/.claude/skills/agent-handoff/` |
| Codex CLI | skills 目录或 AGENTS.md 引用 |
| Minis (OpenMinis) | skills 目录（兼容 Claude/Codex 技能） |
| Cursor/Windsurf | 降级：SKILL.md 入 rules 或粘贴；按 §6 走建议文件闭环 |

## 11. Skill 目录结构（实现目标）

```
agent-handoff/
├── SKILL.md                        # 自包含主文件（frontmatter + 全部行为指令 + 内嵌模板）
├── templates/
│   ├── handoff-template.md         # 交接文档模板（§3.8）
│   ├── index-template.md           # INDEX 模板（§4.5）
│   ├── project-readme-template.md  # 项目 README 模板（中文 + repo 指针 + slug）
│   └── config-template             # ~/.agent-handoff/config 模板（无凭据）
├── scripts/
│   ├── init-hub.sh                 # 初始化/发现 hub（幂等；§3.5 三层降级）
│   ├── save-handoff.sh             # 提交推送交接（含 §3.7 碰撞兜底 + §3.10 扫描 + §5.4 CAS）
│   └── list-active.sh              # 列出活跃交接（解析 INDEX）
├── tests/
│   └── run-local-tests.sh          # 本地 bare remote 回归测试（无需 GitHub）
└── FALLBACK.md                     # 降级指南（§6 建议文件闭环 + 手填字段级指令）
```

## 12. 实现计划

1. 编写 `SKILL.md`（自包含，覆盖 §3–§6 全部协议规则）；
2. 编写四个模板（中文）；
3. 编写三个 POSIX shell 脚本并本地验证语法（init-hub 幂等；save-handoff 含碰撞兜底/扫描/CAS）；
4. 编写 `FALLBACK.md` 与顶层 `README.md`（中文安装/使用说明）；
5. 自测：用本地临时 git 仓库模拟「沉淀 → 接手 → 回到原 agent 同步 → 并发冲突 → dev reset」全路径，验证目录逻辑、模板渲染、并发规则、安全扫描。
