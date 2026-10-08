# 战斗识别数据框架扩充

用户明确要求先把 Raid Framer 的技能 ID、状态 ID、沉默及其它识别数据全部纳入现有插件。本轮只扩充静态数据及查询框架，不实现外置程序、传输、扫描、排行或新的统计规则。

| 编号 | 归属 / 工作与验收 | 状态 |
|---|---|---|
| RF-001 | Data / 固定 RF246 源码版本，转换全部 definitions 与 Lua 采集端的识别 ID、名称、关系、分类；记录逐文件校验、来源及覆盖清单 | 完成；35 个输入逐一匹配固定 Git blob，另核查 42 个 core 源文件 |
| RF-002 | Data / 技能、状态、名称分别索引；重复 ID 保留多候选；职业组合与技能树查询；所有参考规则标记 RU 未验证 | 完成；733 条记录、581 个技能 ID、681 个状态 ID |
| RF-003 | CombatAbilityCatalog / 提供统一参考查询入口并登记 TOC；原确认分类、状态极性、统计默认值及存档不变 | 完成；两个数据文件进入 TOC，统一查询及只读验收接入 |
| RF-004 | Tools / 原始字段覆盖核对、序号与游戏 ID 区分、冲突与未知、安全加载、重载、现有战斗回归及真实 Lua 5.1 编译 | 离线完成；305 个 TOC Lua 编译及 8 项脚本通过，RU 实机 not_run |

来源：`barcodeguild/raid-framer-desktop`，RF246 / commit `fd006560ce2ac968709b263a1a6a8eb6289ec712`。参考源仅作为数据输入，不执行 Kotlin/Lua，不复制其采集、文件通信或统计工程代码。外部原始源码缓存位于 Windows 临时研究目录，不进入 TOC。

实现原则：技能 ID 与状态 ID 分离；技能列表序号、技能树 gameId、职业组合保留独立命名空间；参考项目同一状态的不同分类、图表排除策略、采集白名单均分开保留；不根据参考名称把未知状态升级为确认 Buff/Debuff，不把 NA/参考服规则标为 RU 实测。只编译一次静态索引，查询不遍历全目录、不读 Native、不创建订阅或周期任务。

本轮无新 Native API，静态数据接入不改变 API 能力边界。现有自身模式、助攻政策及个人历史保持当前行为。

## 实际数据覆盖

输入为 28 个 definitions 文件、3 个 Lua 采集文件，以及补充内联规则的 4 个 Kotlin 文件。全部匹配固定提交的 Git blob SHA1，逐文件 SHA256、字节数、源码行号随数据保存。其余 core helpers/interactor/model/serialization 一共 42 个文件均检查过明确技能/状态 ID 字段，未发现遗漏的正数 ID。

| 数据类别 | 记录数 |
|---|---:|
| 技能树技能及施法变体 | 168 |
| 专项效果 ID 集合 / 控制条目 | 36 / 47 |
| 装备与道具效果 / 滑翔翼 / 药水 | 33 / 8 / 16 |
| 团队增益 / 战利品增益 | 25 / 187 |
| 宠物技能与伤害关联 / 玩家行为技能 | 14 / 160 |
| 地面效果 / 阵营提示 / 采集白名单 | 2 / 3 / 3 |
| 参考图表排除 / 演奏别名 / 开战技能名称 | 4 / 1 / 1 |
| 分析代码内联 ID 规则 | 25 |

此外保留 14 个技能树的独立 gameId、364 个三技能树职业组合和参考职业角色分组。`Skill.id` 的槽位序号保存在 `slotIndex`，只有 `possibleCastIDs` 进入技能 ID 索引；宠物数据类中真正的技能 id 单独处理。状态 ID 包括全部 52 个沉默、6 个魅惑、5 个 Distressed，以及冻结、倒地、禁止用药/滑翔等集合。名称、参考冷却、持续时间、掉落加成、宠物类型与关联伤害、增益等级子集均保留；缺失的数据不伪造。

## 加载与消费

加载顺序：`rs_skill_effects.lua` → `rs_combat_recognition_data.lua` → `rs_combat_recognition_catalog.lua` → `rs_combat_ability_catalog.lua`。参考数据不会混入原 `BySkillId/ByBuffId` 已确认库，原中文名称、控制/辅助指标及 Buff/Debuff 极性权威没有被参考表覆盖。

```lua
local ability = ReplicatedSuite.Data.CombatAbilityCatalog
local candidates = ability:GetRecognitionMatches("buff", 24543)
local silence = ability:GetRecognitionGroup("silencedDebuffIds")
local names = ability:GetRecognitionByName("生命乐章")
local reference = ReplicatedSuite.Data.CombatRecognitionCatalog
local spec = reference:GetSpec({ "BATTLERAGE", "DEFENSE", "AURAMANCY" })
local tree = reference:GetTree("SPELLDANCE")
local health = reference:GetHealth()
```

`GetMatches` 按技能/状态 ID 分别查找，`GetByName` 做去首尾空白、英文大小写归一后的精确别名查询，均返回多候选 borrowed 静态对象。调用方不得修改对象；药水记录的 `nameMatchEnabled=false`、演奏的 `nameMatchMode=contains` 等原始策略字段保留供后续显式消费，不会自动影响现有统计。资源键是参考项目的资源身份，不是可以直接调用的 RU 图标路径。

所有参考条目为 `reference_unverified_ru`；同一 ID 多种用途、施法次数与实际生效次数、宠物所有权、职业推断、阵营提示均没有被自动裁定。职业角色分组及图表排除列表只保留参考策略，不成为新的业务权威。

源项目冲突记录：咒舞文件的 `tree=AURAMANCY` 与 `SkillTreeType.SPELLDANCE(SpelldanceDefinition)` 冲突，按明确的枚举绑定保留为 SPELLDANCE，同时保存 declaredTree；33820 玩家行为定义重复，两条均保留，不用后写覆盖。其它跨类别 ID 的多候选也全部保留。

## 验证证据

日志：`.workbuddy/tmp/combat_recognition_verification_2026-10-05.log`；转换覆盖清单：`.workbuddy/tmp/combat_recognition_manifest.json`。运行时数据自身保存来源清单，临时测试材料无需进入发布运行时。

- 固定源核对：35 个转换输入及 42 个 core 文件的 Git blob 验证，逐命名空间字段覆盖，重复转换结果一致。
- 静态框架：真实 Lua 5.1.5 验证所有条目的技能/状态索引、多候选、无效 ID、技能序号隔离、职业组合顺序、重载、原名称与极性保留；静态加载/查询没有 Native、Events、Scheduler 或 Persistence 调用。
- Foundation：`v3_combat_recognition_reference_contract` 正式注册并执行，缺失目录时失败。健康投影只含固定规模计数与来源状态，不复制全部规则。
- 编译：当前 TOC 的 305 个 Lua 文件由真实 Lua 5.1 编译器通过；两个新文件均已登记。
- 回归：8 项 Lua 脚本全部通过，覆盖现有自身/全员范围、DPS 共享指标、个人历史、启停/回滚、统一人物行、实际导出存档回放、服务边界 5 项及 Core 解耦 128 项。

RU 实机尚未运行：重载后检查新增识别数据门禁正常、原统计与历史可用；参考 ID 的服务器适用性和团战帧耗仍需实测。数据导入不代表新控制/道具/职业统计已经启用；外置程序和实时传输属于后续范围。
