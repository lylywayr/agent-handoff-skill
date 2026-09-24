# agent-handoff-skill

> v1.1.0：同一个、与具体 Agent 无关的 Skill，同时管理**长期项目连续性**与**跨 Agent 工作接力**。已绑定项目的事实以项目 Git 仓库或具备版本保护的知识库为准；GitHub 私有交接 Hub 是按需启用的任务接力通道，不是第二份项目正史。

## 两种任务模式

- **日常项目任务**：确认绑定和工作分支 → 核对远端最新 revision 与本地残留 → 定向检索相关模块的需求、ADR、Bug 与历史提交 → 经授权实施和验证 → 同一提交记录变更原因、证据和风险 → 核验远端同步。只读问题与单纯讨论不自动写文件或推送。
- **新项目**：经用户确认位置、远端所有者、仓库名与可见性后建立本地项目基线；获准时创建远端并首次推送，失败则明确区分本地/远端状态。默认私有、默认 `main`，不强制 `dev` 或 Hub。
- **跨 Agent 接力**：只有项目明确启用 Hub 工作模式时，才使用下文的 Hub、`main/dev`、WIP 留痕和相关脚本。Hub 保存任务/未完工作指针；新 Agent 回项目事实源核实后继续。

项目记录建议格式见 [项目事实源约定](references/project-memory-schema.md)，权限、任务分流与冲突恢复见 [统一任务契约](references/workflow-contract.md)；主行为规范见 [SKILL.md](SKILL.md)。

## 传统 Hub 交接模式（选用时生效）

> 下文展示原有 Hub 双仓模式的用法。未采用 Hub 的项目不要照此切 `dev` 或运行相关脚本。

> 跨 AI Agent 工作接力 Skill：让一个 agent 把工作状态沉淀到 GitHub 私有交接总仓，另一个 agent（跨平台/跨设备）读取后无缝继续，**用户无需重复说明背景**。

今天用 DeepSeek Harness、明天用 Codex、后天用 Claude Code 或 OpenMinis——不再每次换工具都重新解释一遍前因后果。

## 它解决什么问题

多个 AI agent 环境之间无法共享「工作现场」。这个 Skill 定义了一套**与具体 agent 无关**的接力协议：

- **沉淀（Save）**：当前 agent 把任务目标、进度、下一步、关键决策写成中文交接文档，推到私有交接总仓（hub）；
- **接手（Resume）**：下一个 agent 读交接、克隆项目、切到 `dev` 分支，接着干；
- **同步（Sync）**：任何 agent 开工前自动对齐到远端最新——A→B→A 循环接力也不丢进度。

## 三条核心承诺

1. **不丢工作**——任何中间态（文档/代码）要么入库、要么留痕，绝不静默丢弃；
2. **不中断**——冲突处理永不卡住等你裁决，无法自动判时按规则降级、信息全保留；
3. **凭据零落盘**——任何持久化文档不得含 token/密码/私钥/连接串（写入前自动扫描，命中拒写）。

## 支持的 agent

| 环境 | 接入方式 |
|---|---|
| DeepSeek Harness | 本目录放入 skills 路径即可被识别 |
| Claude Code | 复制到 `~/.claude/skills/agent-handoff/` |
| OpenAI Codex | skills 目录，或在 AGENTS.md 中引用 |
| Minis (OpenMinis) | skills 目录（官方兼容 Claude/Codex 技能） |
| Cursor / Windsurf 等 IDE | 降级：SKILL.md 内容入 rules，或按 [FALLBACK.md](FALLBACK.md) 走「建议文件」闭环 |

Skill 是「单文件夹 + `SKILL.md`（YAML frontmatter）」的通用格式（Anthropic Agent Skills 规范），上述前四家原生通用；不支持 Skill 的 agent 把它当普通 Markdown 指令读即可，逻辑不依赖任何专有工具。

## 快速开始

1. **准备一个私有 GitHub 仓库作为交接总仓（hub）**——可让 agent 用 `scripts/init-hub.sh` 自动创建并初始化（幂等），或手动建一个名为 `handoff-hub` 的私有 repo。
2. **把本 Skill 装入你的 agent**（见上表）。
3. 对 agent 说一句「**交接一下**」，它就会：定位/初始化 hub → 把当前工作写成交接文档 → 推送。
4. 换任意 agent，说一句「**接着上次做**」，它就会：读索引 → 复述进度给你确认 → 克隆项目切 `dev` → 继续。

> 交接文档默认全中文；项目代码放在各项目自己的 GitHub 仓库（main 正式版 / dev 工作版），交接文档统一放 hub，双仓分离。

### 本地回归测试

在不连接 GitHub 的情况下，可用临时 bare Git remote 验证核心路径：

```sh
bash tests/run-local-tests.sh
```

测试覆盖单 agent 沉淀、并发沉淀与 INDEX push 重试、凭据拒写，以及全新 hub clone 的项目定位。另运行 `python3 tests/test-project-continuity.py`，在临时本地 Git 裸仓验证非 `dev` 初始化、远端读回与并发拒推保留提交。两者不能替代真实 GitHub 权限、知识库 CAS 或跨 Agent 冷启动验收。

## 仓库内容

```
agent-handoff-skill/
├── SKILL.md                     # 主文件：frontmatter + 全部行为指令（自包含）
├── templates/                   # 中文模板：交接文档 / INDEX / 项目README / config
├── scripts/                     # POSIX shell 脚本：init-hub / save-handoff / list-active
├── tests/
│   ├── run-local-tests.sh        # Hub 本地 bare remote 回归测试
│   └── test-project-continuity.py # 项目初始化/并发 Git 探针
├── references/                  # 项目事实源建议格式与统一任务契约
├── AGENTS.md                    # Agent 无关的项目事实源入口
├── docs/project-memory/         # 本项目的索引、当前态、年度变更日志
├── FALLBACK.md                  # 降级环境（无 git/shell）使用指南
├── handoff-skill-design.md      # 实施规格书（完整设计原理，经多轮评审+真机实测收敛）
└── README.md
```

## 设计要点（详见 [handoff-skill-design.md](handoff-skill-design.md)）

- **双仓分离**：项目代码在项目 repo，交接文档在 hub，永不混淆；
- **main/dev 分支模型**（仅项目 repo）：正式版与工作状态分离，接力永远发生在 dev；
- **并发一致性**：不追求全局时钟，用 git 拓扑（`merge-base --is-ancestor`）定新旧、用语义（LLM）定同异，冲突留痕不丢工作；
- **降级闭环**：无 git 能力的 agent 只读、产出建议文件，由有 git 能力的 agent 安全合并。

## 安全

凭据零落盘是硬规则：交接只写结构化摘要（不搬运会话原文），写入前用扩展正则扫描常见 token/私钥/连接串形态，命中即拒写。hub 默认私有；任何转公开前强制全仓库历史扫描。Skill 本身不存储、不询问任何 token，git 推送复用你本机已有的 git/gh 认证。

## License

[MIT](LICENSE)
