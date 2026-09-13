# Replicated Suite：新 Agent 交接入口

交接日期：2026-09-13。用途：让没有旧会话上下文的本地开发 Agent，连续推进插件中仍标为“未完成”的工作。

**这是一份交接材料包，不是游戏运行补丁。** 包内不含游戏源码、用户存档或可执行解释器；包含当前技能原样副本、历史代码索引、工作规范和目标提示词。

## 使用

把本文件所在的 `ReplicatedSuite_Agent_Handoff/` 放在 Agent 能读取的位置，推荐放在 Addon 工程旁边。不要将这里的文件加入 `toc.g`，也不要用它覆盖 `replicatedsuite/`。若放在仓库内，交接文件与本轮游戏补丁的打包范围必须分开。

新会话先发送 [03_GOAL_PROMPT.md](03_GOAL_PROMPT.md) 的正文。Agent 应按顺序读取：

1. [01_CONTEXT_AND_RULES.md](01_CONTEXT_AND_RULES.md)：产品语义、工作习惯、不可回退约定与查证流程。
2. [02_UNFINISHED_WORKLIST.md](02_UNFINISHED_WORKLIST.md)：按真实 Registry 生成的历史待办种子及执行顺序。
3. [skills/skillforge-archerage-addon/SKILL.md](skills/skillforge-archerage-addon/SKILL.md)：`2026.09.13-r2`，再按当前问题读取具体参考。
4. [05_EVIDENCE_AND_VERIFICATION.md](05_EVIDENCE_AND_VERIFICATION.md)：基线、命令、真实验证与发布要求。
5. [04_RUN_STATE.md](04_RUN_STATE.md)：每个工作闭环更新一次，供中断或下一会话恢复。

不要一开始把整个技能参考库全部加载，也不要停留在“已经读完，接下来可以开始”。完成基线核对后实际修改、测试和交付。

## 最重要的边界

**用户本机现状尚未在本次交接中读取。** 本包根据本会话的原始项目 ZIP 和后续 9 个补丁建立历史参考树。该树不是强制覆盖目标：有更新的本地改动时，先解释差异、保留改动，不自动回退。

历史参考 Registry 共 40 个功能记录，其中 24 个判为未完成：19 个侧栏可见项、5 个隐藏语义子项。它们并非 24 个空白功能：有些已经实现但等实机验收，有些只有缺少证据的子能力被阻塞。任务队列必须在本地重新核对。

当前目标是“最大限度完成有证据且能安全实施的闭环”，不是把所有标签改成完成。不能绕过禁用 API、伪造游戏数据或把 Lua 模拟测试称为 RU 实测。

包内技能副本可直接读取，不依赖另一产品或联网安装。若宿主已有同名技能，核对修订并只使用一个有效版本；不自动修改宿主全局配置。

本包制作时的结构、清单覆盖与技能工具执行范围见 [handoff_validation.json](evidence/handoff_validation.json)。这些结果不代表新Agent已执行任务，也不代表游戏功能通过验收。
