# Replicated Suite 200人数据、Runtime 与 API 治理规范 v1.1

> 日期：2026-08-15  
> 状态：**技术架构基线 + 待验证事项清单**  
> v1.1：新增 DPS 团队模式 / 范围模式 Scope Policy  
> 重要说明：本文件中的“产品优先级”和“架构方向”已确认；具体 API 名称、可用状态、身份恢复证据、时间阈值等必须在正式重构前通过 RU 官方 API、当前 `z_api_functions`、其它 DPS 源码和实测验证后落地。

---

# 1. 容量基线

ArcheRage 大型开放世界场景必须按：

> **100米内约200名玩家数据是正常容量**

而不是极限压力测试。

同时场景中还可能存在：

- NPC
- Boss
- 召唤物
- 宠物
- 坐骑
- 载具
- 系统实体
- 超出可见 / 可查询上限但仍产生战斗事件的对象

因此：

- 不允许把 Actor 容器硬限制成 200
- 底层数据结构动态增长
- 性能验收必须覆盖 200 玩家 + 大量额外实体

---

# 2. 核心问题：可观测上限与 Unknown

超过客户端 / API 当前可查询范围后，战斗事件可能出现：

```text
未知 攻击了 未知
```

这类事件不能：

- 直接丢弃
- 全部粗暴合并成同一个 Unknown Actor
- 因为暂时无法解析身份就破坏累计总量

正式方向：

> **Event Fact 与 Identity Resolution 分离。**

先确认：

```text
发生了什么
```

再确认：

```text
是谁
```

---

# 3. World Observation Service

为避免：

```text
DPS      扫200
Healer   再扫200
Plates   再扫200
Buff     再扫200
HUD      再扫200
```

Common 层提供统一 Observation Service。

但是：

> **共享 Observation ≠ 共享业务 Authority。**

Observation 只负责游戏世界基础读取、去重、调度和缓存。

Module 自己做业务判断。

---

# 4. Observation Subscription

采用按需订阅。

例如只有 DPS 开启时：

- 不查询 Healer 专用昂贵数据
- 不查询 Plates 专用昂贵数据

Healer 开启后：

- 增加 Health / Buff 等需求

Module Disabled 后：

- 自动释放对应 Subscription

---

# 5. 数据分层

## 5.1 轻量全体

尽可能覆盖所有当前可观测单位：

- Unit Reference
- Name
- Distance
- Basic Health
- Basic Type Clue
- Visible / Last Seen
- 基础关系线索

## 5.2 昂贵按需

例如：

- 完整 Buff
- 装备
- 职业扩展
- 复杂 Tag
- 深层 UnitInfo
- 其它高成本 Query

只对热点 Actor 做预算更新。

---

# 6. 热点优先级

推荐：

```text
P0 当前目标 / 自己
P1 团队成员
P1 最近战斗活跃 Actor
P2 当前可见其它玩家 / NPC
P3 冷单位
```

活跃度可以由：

- 最近造成伤害
- 最近受到伤害
- 最近被治疗
- 当前目标
- Plates 当前使用
- Healer 当前候选
- 团队成员

等信号提升。

---

# 7. Runtime 优先级

高负载时优先级：

```text
P0 原始战斗事件 / 关键游戏事件
   不主动丢

P1 Domain 累计 / 关键业务状态
   尽快处理，可排队

P2 Identity / Buff / 关系业务判断
   允许分帧

P3 排名 / Detail Projection
   允许延迟

P4 HUD Refresh / 动画 / 外观
   最先降频

P5 Diagnostics / 非关键扫描
   高负载时大幅降频
```

目标：

> 高负载时表现为“UI慢一点”，而不是“数据错了”。

---

# 8. Backlog

不使用一个死板的“必须3秒内”作为正确性约束。

采用 Backlog Health：

```text
Normal
Delayed
Heavy Backlog
Critical
```

原则：

- 不主动丢关键 Event
- 队列持续向前消费
- 压力下降后可追平
- UI 可显示“统计处理中”
- 允许最终 Domain 延迟数秒甚至更长

---

# 9. Observation TTL 与 Domain Lifetime

必须分层。

示意：

```text
实时位置 / 血量
→ 很快失效

昂贵 Buff / 装备缓存
→ 短 TTL

轻量身份
→ 长 TTL

DPS Domain 历史
→ 用户明确清空前保留
```

玩家死亡后从复活点回场通常需要约 1～2 分钟。

因此身份缓存不能几十秒就完全遗忘。

具体 TTL 数值：

> 正式重构前根据内存占用和实际回场时间验证后确定。

---

# 10. Event Fact

无法立即解析身份时：

- 仍保存 Event Fact
- Source / Target 使用独立临时 ActorKey
- 不把所有 Unknown 合并

示意：

```text
Event
  SourceRef = Unknown#18372
  TargetRef = NPC#82
  Type      = Damage
  Amount    = 12000
  Skill     = ...
  Timestamp = ...
```

---

# 11. Unknown Actor

底层：

```text
Unknown#17
Unknown#29
Unknown#41
```

必须独立。

UI 可以聚合为：

```text
待识别来源 37.2M (12)
```

点击后展开具体 Unknown。

如果后来恢复身份：

```text
Unknown#17
→ PlayerA
```

则相应历史数据从“待识别”重新投影到 PlayerA。

---

# 12. Identity Resolver

最终 Resolver 需要：

- 明确证据等级
- 置信度
- 可逆合并
- 自动 / 人工来源区分
- 证据记录

但具体证据不得凭经验硬编码。

必须验证：

- 当前 RU API
- UnitId / Object Reference 可用性
- Event 中实际字段
- 其它 DPS 的做法
- 用户实测采样

---

# 13. 人工纠错

人工规则拥有更高 Authority。

如果未来支持 Unknown → Player 手动绑定：

- 必须可撤销
- 必须触发历史重新投影
- 自动推断不得覆盖人工规则
- 删除人工规则后才允许重新自动判断

---

# 14. 召唤物

方向：

- 无主人信息时作为独立 Actor
- 确认主人后，主排行可合并给主人
- Detail 保留召唤物来源
- 历史数据允许回填

具体 Owner API 必须先验证。

---

# 15. 名字规则

当前服务器环境已确认的产品侧事实：

- ArcheRage RU 私服玩家不允许使用中文角色名
- 用户使用中文客户端
- 大量 NPC 被汉化为中文
- 玩家主要使用俄文 / 英文名
- 游戏不允许玩家重名

因此：

> 中文名对 NPC 是强线索。

但不得简单反推：

```text
俄文 / 英文 = 玩家
```

最终类型识别仍应综合其它证据。

---

# 16. DPS 数据范围模式（Scope Policy）

DPS 正式提供两种数据范围模式：

```text
数据范围
● 团队模式
○ 范围模式
```

这不是两套 DPS，也不能分别维护两条统计实现。两种模式共享同一条业务管线：

```text
Combat Event
→ Event Fact
→ Identity / Relation Resolver
→ Scope Policy
→ PVP / PVE Classification
→ Stats Domain
```

`Scope Policy` 只负责决定：
- 哪些 Actor 可以进入正式统计；
- 哪些 Actor 仅作为 Context；
- 当前需要启动多大的 World Observation 工作量。

## 16.1 团队模式

目标：**高准确率、低额外扫描开销。**

正式统计 Actor：

```text
SELF + TEAM
```

其中 TEAM 以客户端明确的团队 / 联合团队单位槽位与团队 API 为 Authority。

参考实现 `Koalazau/ArcheRageAddons/RaidSnapshot` 已实际使用：

```text
team_01_01 ... team_02_50
```

查询双团最多 100 名团队成员，并对这些 Unit 使用 `UnitName`、`UnitGearScore`、`GetTargetAbilityTemplates`。该仓库只作为 Reference 证据；具体 API 当前状态仍以 RU 官方更新 + 本项目 Runtime 实测为准。

### 团队模式不是完全忽略非团队单位

例如：

```text
团队玩家A → Boss
```

仍需要知道目标属于 NPC / Boss，才能正确归入 PVE。

又例如：

```text
敌方玩家X → 团队玩家A
```

仍需要保留 X 作为 Source Context，才能累计 A 的承伤并显示来源明细。

因此非团队单位在团队模式下允许作为：

```text
ContextOnly
```

用于：
- PVP / PVE 分类
- Boss / 目标判断
- 承伤来源
- 技能 / 目标 / 来源明细
- Event Fact 的 Source / Target 关系

但默认不提升为完整排行榜 Actor。

### 团队模式性能规则

团队模式开启后，不得继续维持完整 100 米范围的高频全量扫描。

Runtime 应收缩为：

```text
团队 Roster
+
Combat Event 实际涉及的 Context Actor
+
当前目标 / 必要热点对象
```

团队成员变化应：
- 优先通过可用事件 / Roster 变化信号标记 Dirty；
- 使用低频 Reconcile 纠错；
- 禁止每帧 × 100 人 × 多个昂贵 API 的全量读取。

没有团队时，`SELF` 仍属于正式统计 Actor。

## 16.2 范围模式

目标：**尽可能统计当前能够识别到的所有相关单位。**

范围模式必须继续把 TEAM 作为强身份锚点，而不是进入范围模式后重新猜团队成员身份。

推荐证据层级：

```text
Tier 0  SELF
Tier 1  TEAM / RAID Authority
Tier 2  API 明确识别
Tier 3  Combat Relation / 行为证据
Tier 4  名字 / 客户端环境等辅助证据
Tier 5  人工纠错 Authority
Unknown 暂时无法判断
```

范围模式可正式统计：
- 自己
- 团队成员
- 团队外友军
- 敌方玩家
- NPC / Boss
- 召唤物
- 宠物 / 载具等经确认实体
- 后续成功解析的 Unknown Actor

范围模式需要启用更完整的：

```text
World Observation Service
Combat Event Discovery
范围 Actor Cache
热点 Actor Query
Unknown Identity Resolver
```

但仍遵守：**共享 Observation，Module 独立 Domain Authority。**

## 16.3 范围模式继续使用现有判断体系

范围模式继续使用现有、已验证并可人工纠错的证据体系，包括：
- 有效治疗关系 → 友军强证据
- 对自己造成有效伤害 → 敌军强证据
- 自己对某单位造成有效伤害 → 敌对强证据
- 团队成员 → 明确友军 / 玩家 Authority
- 人工设置友军 / 敌军 / 玩家 / NPC / 召唤物 → 高 Authority
- 中文名 → 当前中文客户端环境中的 NPC 强线索，但不是唯一证据
- 俄文 / 英文名称不得直接等价为玩家

具体权重、冲突解决、自动合并阈值属于技术验证项，不要求用户拍脑袋决定。

## 16.4 两种模式必须共享同一 Domain Pipeline

禁止维护：

```text
TeamDPS.lua
RangeDPS.lua
```

形成两份独立 DPS。

以下能力必须只有一套：
- Combat Event 解析
- Event Fact
- PVP / PVE 分类
- Damage / Taken / Heal 累计
- Boss 历史累计
- 技能明细
- 目标 / 来源明细
- 清空
- 人工纠错
- Unknown 回填
- 排行 Projection

Scope 只决定：

```text
Actor Admission
Observation Budget
Default Projection Scope
```

## 16.5 模式切换

切换：

```text
团队模式 ↔ 范围模式
```

不得自动清空已有统计。

默认语义：

> 新模式从切换之后影响后续 Event 的采集 / Actor Admission；已有累计数据保留。

切换时给短提示，例如：

```text
已切换为团队模式。
现有统计已保留；如需纯团队统计，请手动清空。
```

或：

```text
已切换为范围模式。
现有统计已保留；范围单位将从现在开始补充。
```

禁止在缺少原始 Event Fact 时伪造切换前未采集的数据。

如果近期 Event Fact 仍完整存在，未来可以提供显式“按当前 Scope 重建”能力，但不得作为普通切换的隐式副作用。

## 16.6 UI 文案

设置页名称：

```text
数据范围
```

团队模式：

> 只将自己和团队成员作为正式统计对象。非团队单位仍用于目标、承伤来源及 PVP/PVE 判断。身份更准确，性能开销更低。

范围模式：

> 尝试统计范围内能够识别到的所有单位，包括团队外友军、敌军、NPC 等。覆盖更完整，但部分单位可能需要判断或人工纠正。

建议状态摘要：

```text
当前：团队模式
团队：87 / 100
```

或：

```text
当前：范围模式
已识别：187
待识别：13
```

普通用户界面不显示内部置信度公式。

## 16.7 默认与迁移

当前 Replicated DPS 的既定目标是“尽可能统计客户端可见的所有单位”，因此无旧配置可迁移时：

```text
默认：范围模式
```

已有明确用户配置时，以用户配置为 Authority。未来默认值改变也不得静默覆盖用户选择。

---

# 17. DPS PVP / PVE 规则

这是不可回归规则。

必须按每条 Combat Event 的来源和目标独立分类。

例如：

```text
Player1 → Player2  1000
= PVP

Player1 → NPC1     1000
= PVE
```

同一个 Player 可以同时出现在不同统计链路。

禁止：

```text
Player1 被标记为PVP玩家
→ 所有伤害都进PVP
```

---

# 18. DPS Accuracy Priority

长期原则：

> **Accuracy > Performance**

允许：

- 排行晚刷新
- Detail 晚生成
- UI 延迟
- Background Replay

不允许为了看起来实时：

- 丢战斗事件
- 错分类
- 误合并 Unknown
- 删除正常重复数值事件
- 破坏人工纠错
- 破坏 Boss 历史累计

---

# 19. Event 去重

需要区分：

## Strong Dedup

如果 API 有明确：

- EventId
- SequenceId
- 唯一事件标识

则可强去重。

## Heuristic Dedup

没有唯一 ID 时：

- 只能非常谨慎
- 使用短窗口
- 结合 Source / Target / Skill / Amount / Type / Time

高风险“疑似重复”不应直接永久丢弃。

具体算法必须在其它 DPS 和实际 Event 样本基础上验证。

---

# 20. 原始事件分层

长期 MMO Session 不能无限保留完整 Event。

方向：

```text
近期
→ 完整 Event Fact，可 Identity 回填

较老
→ 压缩为 Actor / Target / Skill 聚合 Block

最终
→ Domain 累计
```

长期未解析 Unknown：

- 保留必要 unresolved reference
- 不因为压缩而失去未来回填能力

具体保留时长 / Block 格式通过实测决定。

---

# 21. State 四分法

所有大型 Module 逐步统一：

```text
Config
Runtime
Domain
Cache
```

## Config

持久配置。

## Runtime

Session Handler / Job / Queue / Dirty State。

## Domain

业务 Authority。

## Cache

可重建：

- 排行
- Name Index
- UI Projection
- Sort Result
- Lookup

禁止 Cache 清理误删 Domain。

---

# 22. Scheduler

一个 Module 内尽量减少独立 OnUpdate。

推荐统一 Driver：

```text
Fast Lane
Normal Lane
Slow Lane
Event Driven
Background Budget
```

高频 Handler 禁止：

- 重型 Tag 匹配
- 全表排序
- 大量字符串格式化
- 重复创建临时大表
- 无意义 API 轮询

---

# 23. API 治理

当前 `z_api_functions` 不能永久作为唯一真相。

原因：

- API 会开放
- API 会关闭
- API 会重新开放
- 某些 API 文档存在时间差
- 某些 API 可能有 Combat Restriction
- 某些 API 有 Cooldown
- 某些 API 实际 Runtime 行为与静态文件不同

正式重构前必须做 API 修复 / Registry。

---

# 24. API Capability Registry

推荐每个能力记录：

```text
Name
Namespace
StaticState
OfficialState
RuntimeState
Since
LastVerified
Cooldown
Restrictions
Source
Risk
Notes
```

状态可以包含：

```text
OfficialEnabled
OfficialDisabled
Removed
Unknown
RuntimeVerified
RuntimeFailed
CombatRestricted
CooldownLimited
CrashRisk
Degraded
```

代码不应在各 Module 里自行猜：

```text
这个函数应该能用吧
```

而应该查询统一 Capability。

---

# 25. API 证据来源

最终能力状态综合：

```text
Static
  当前 z_api_functions / bundled API

Official
  RU 官方更新 / Addon 公告

Runtime
  当前客户端实测
```

三者冲突时：

- 不静默假设
- 记录冲突
- 降级
- 避免高风险调用

---

# 26. Runtime Probe

不能在启动时自动测试所有 API。

Getter 且完全无副作用的能力，可以考虑安全探测。

以下类别禁止无脑 Probe：

- Equip
- Move
- Target
- Auction 操作
- 修改称号
- 其它有副作用 API
- 可能触发 Cooldown / Server Action 的 API
- 历史上存在 Crash 风险的 API

---

# 27. 其它 DPS 对照研究

用户后续会提供其它 DPS。

正式重构前必须重点研究：

1. 超过可观测单位上限后如何处理 Unknown
2. 如何重新绑定身份
3. 使用了哪些我们未利用 API
4. Event 去重策略
5. ActorKey
6. Summon Owner
7. 大规模战斗性能
8. 是否保留 Event Fact / Replay
9. 排行刷新与 Domain 累计是否解耦

不能因为对方插件“能跑”就直接照抄，仍需与官方 API 和实测交叉验证。

---

# 28. 技术侧待验证项目

以下事项不要求用户拍板，由工程侧验证：

- 哪些 API 当前真正开放
- 哪些 API 已移除
- 哪些 API 后来重新开放
- Unit / Actor 唯一标识
- Unknown Identity Resolver 的证据
- Summon Owner
- EventId / Sequence
- 去重窗口
- Observation TTL
- Buff Scan Budget
- 200 人性能预算
- 团队模式 Roster Reconcile 的最优事件/低频校验策略
- 范围模式 Actor Admission / Unknown Resolver 的实际证据链
- 原始 Event 保留时长
- 聚合 Block 格式
- Cache 内存预算

只有当技术限制会改变玩家可见行为时，再向用户提出产品选择。

---

# 29. 性能验收场景

正式重构后至少验证：

## 小队

- 5 人副本
- Boss 连续战斗

## 中型

- 50 人团队
- 高频 Buff / Heal

## 大型

- 100 人
- 200 人
- 100m 内大量可见单位
- 同时存在 NPC / Summon / Boss
- 超出可查询范围出现 Unknown

验收重点：

- Event 不主动丢
- Domain 能最终追平
- UI 可以延迟
- Module Disabled 后对应 Runtime 明显停止
- 不出现多个模块重复扫描同一全量数据
- 不因长时间战斗无限失控增长

---

# 30. 技术架构硬规则

1. 200 玩家是正常负载。
2. Observation 去重，但 Domain Authority 不共享。
3. API 按需订阅。
4. 昂贵数据按需 / 热点优先。
5. 战斗事件优先于 UI。
6. Unknown Event 不直接丢。
7. Unknown Actor 不粗暴合并。
8. Identity 回填必须可重算。
9. 人工纠错高于自动推断。
10. DPS Accuracy 高于实时 UI。
11. DPS 必须支持“团队模式 / 范围模式”两个 Scope Policy。
12. 团队模式只把 SELF + TEAM 作为正式统计 Actor，非团队单位仅保留必要 Context。
13. 范围模式仍以 TEAM 为强 Authority，再扩展到范围观察、推断与人工纠错。
14. 两种 Scope 必须共享同一 Event / Domain Pipeline，禁止复制成两套 DPS。
15. 团队模式不得继续运行完整范围高频扫描。
16. 模式切换不得自动清空统计，也不得伪造切换前未采集的数据。
17. API Capability 必须统一治理。
18. 未验证 API 不进入关键架构假设。
