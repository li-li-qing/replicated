# 死亡回顾状态与图标 Implementation Plan

> **For agentic workers:** 使用 superpowers:executing-plans 按任务执行。用户已确认布局并要求开始加入；本轮直接实现，不提交或推送。

**Goal:** 死亡回顾采用伤害、状态两列，技能及 Buff/Debuff 使用图标列表。

**Architecture:** Authority 从共享 Aura 服务采集死亡通知前的最后快照，收尾时冻结状态并解析技能元数据。Store 保留 schema1 记录的 canonical，新增 schema2 紧凑记录；页面及弹窗复用同一内容构建器。

**Tech Stack:** Lua 5.1、RSUI TableView、AuraObservationV3、SkillMetadataV3、Persistence。

**Spec:** 本轮用户确认的分组方案：左55%伤害；右45%上 Debuff、下 Buff；独立滚动；顶部选择历史；沿用弹窗位置和尺寸入口。

## Global Constraints

- 保存死亡通知前最后快照，标明与死亡的时间差；不能用死亡后空状态覆盖。
- 旧记录未采集 Buff 显示“未采集”；不把不可用或截断采集显示为“无”。
- Native 扫描留在调度器，元数据不在每次界面刷新中查询。
- 保留此前自动弹窗、布局和5.1菜单修改；不提交或推送。

## Review Focus

- 近战伤害的 rawAbilityId 是金额，不能作为技能图标ID。
- 死亡通知之后的空扫描、尚未执行的采样不能覆盖冻结快照。
- Buff API 失败、数量超上限时显示采集状态。
- 旧记录指纹验证与新记录实际字节预算必须通过真实 Core。
- 窄窗两列仍可滚动，历史选择和自定义窗口几何不丢失。

### Task 1: 采集与记录

**Files:** Authority、Feature、Store；新增 tools/rs_death_review_status_tests.lua。
**Interfaces:** SampleDebuffs 保持兼容入口，采集 buff/debuff 两路；CopyDeathStatus(noticeAt) 返回冻结快照；record2 包含 buffs/debuffs/statusSnapshot、事件 abilityId/iconPath。

- [x] 编写并观察失败用例：冻结、可用性、图标语义、schema1读取、schema2回读和预算。
- [x] 实现事件合并采样、死亡边冻结、共享元数据与紧凑 codec2；schema1 canonical 原样保留。
- [x] Lua51 新回归通过，真实 Persistence 回读验证通过。

### Task 2: 共享两列内容

**Files:** 新增 presentation/v3/widgets/rs_v3_death_review_content.lua；修改 toc.g、Page、Widget、现有模型边界。
**Interfaces:** UIV3.DeathReviewContent:Create(parent,id) 返回 summary/timeline/debuffs/buffs 及 Render(rows,record)。

- [x] 加入两列、图标列、未知与部分采集、历史选择的失败用例。
- [x] 构建共享内容，页面顶部选择历史；弹窗展示完整96行并独立滚动。
- [x] 自动弹窗和布局回归仍通过。

### Task 3: 验证

- [x] 执行新增与相邻 Lua51 套件、全部文件语法和 git diff --check。
- [x] 审查事件资源释放、存档完整性及布局尺寸模型；记录实机验证边界。
- [x] 默认全量门禁的现有 FocusReport 两处失败单独报告，不伪称全绿。

## 执行记录

- 采集上限为每路32状态，完整性/可用性不足明确显示；死亡收尾不重读 Native。
- Ruling: 状态变化事件合并保留 forceRefresh — 避免共享120ms缓存吞掉新状态，保留150ms采样节流。
- Ruling: codec2字典用长度前缀，数值行打包为字符串 — 96伤害＋32Buff＋32Debuff在原14336字节边界内保存；不改变旧schema1 canonical。
- Ruling: 弹窗运行时最小420×300，历史Store min=1不变 — 防止表头占满状态表而没有行视口。
- 独立复核修复前发现3项，全部修复并复测；复核41项通过，额外96个不同来源/技能压力样本估算14041字节。
- 专项8套件通过，真实Lua5.1；Native/磁盘由模型替代。RU实机显示、输入与事件顺序待验收。
- 默认门禁止于原有FocusReport 25通过/2失败；feature-profile入口亦有未修改夹具缺IsAccessible的既有失败，已用HEAD版本确认。
- 日志：.workbuddy/tmp/death_status_adjacent_gate_20261010.log、death_status_full_gate_20261010.log、death_status_feature_gate_20261010.log。
