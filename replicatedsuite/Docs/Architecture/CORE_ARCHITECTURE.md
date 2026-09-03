# Replicated Suite Core 架构（统一权威）

> **Authority Level**: ARCHITECTURE
> **范围**: 产品与模块规范、UI/HUD 规范、200人 Runtime 与 API 治理、Foundation Decisions、Runtime/Frame Budget、UI Framework v1/v2、Engineering 硬规则、Architecture Changelog。
> 本文由 Core/ 下 10 个 v1 规范文档 + UI Framework v2 Phase B1 收敛而成，保留全部原始知识。
> Persistence 独立成 `PERSISTENCE_ARCHITECTURE.md`。


## 目录

1. [Replicated Suite 产品与模块架构规范 v1.1](#sec-1)
2. [Replicated Suite UI / HUD 统一规范 v1](#sec-2)
3. [Replicated Suite 200人数据、Runtime 与 API 治理规范 v1.1](#sec-3)
4. [Replicated Suite Foundation Decisions v2](#sec-4)
5. [Replicated Suite Runtime / Frame Budget Framework v1](#sec-5)
6. [Replicated Suite UI Framework v1](#sec-6)
7. [Replicated Suite UI Framework v2 — Design System Foundation](#sec-7)
8. [Replicated Suite UI Framework v2 — Phase B1 Bound Fields](#sec-8)
9. [Replicated Suite Engineering](#sec-9)
10. [Replicated Suite Architecture v1.1 Amendment](#sec-10)
11. [Shared Runtime Foundation v1](#sec-11)

<a id="sec-1"></a>
## 1. Replicated Suite 产品与模块架构规范 v1.1

> 来源（已合并至本权威文档，原文件已收口）：`replicatedsuite\Docs\Architecture\Core\Replicated_Suite_Product_Architecture_v1.md`

## Replicated Suite 产品与模块架构规范 v1.1

> 日期：2026-08-15  
> 状态：**产品侧正式基线**  
> v1.1：新增 DPS 团队模式 / 范围模式  
> 适用范围：Replicated Suite 公共发行版及其内部所有公开模块。  
> 说明：本规范冻结的是产品行为、模块边界、用户体验和迁移原则。底层 API 可用性、Unknown 身份恢复证据等技术细节仍必须以 RU 服官方 API、当前代码和实测为准。

---

## 1. 最终产品目标

Replicated 项目最终不再以多个独立 Addon 的形式让用户逐个勾选。

玩家侧目标：

```text
☑ Replicated Suite
```

所有公开功能都在一个 Suite 中完成：

- 启用 / 禁用
- HUD 显示 / 隐藏
- 参数设置
- 布局管理
- 诊断
- 配置方案
- 更新提示

内部仍必须模块化：

```text
Replicated Suite
│
├─ Bootstrap
├─ Common
├─ Module Manager
├─ HUD Manager
├─ Storage
├─ Diagnostics
├─ Search / Settings Router
│
└─ Modules
   ├─ DPS
   ├─ Healer
   ├─ Gear
   ├─ Plates
   ├─ Activities
   ├─ Buff Tracker
   ├─ Bonds
   ├─ Trade
   ├─ Fishing
   ├─ Resources
   └─ Future Modules
```

**单一 Addon 不等于单一巨型 Core。**

---

## 2. Authority 规则

合并为单 Addon 后，Authority 仍然必须严格区分。

### 2.1 Suite Authority

Suite 负责：

- Module 注册
- Module 生命周期
- 功能总开关
- HUD 显示 Authority
- 统一设置入口
- 通用 UI / Theme
- 通用 Storage 基础设施
- 通用 Diagnostics
- 配置搜索
- 布局方案
- 功能方案
- 组合快捷方式

Suite 不直接拥有各模块业务状态。

禁止：

```text
Suite.State.Damage
Suite.State.HealerTargets
Suite.State.GearSets
Suite.State.PlateActors
```

### 2.2 Module Domain Authority

各 Module 自己拥有业务 Authority。

#### DPS

负责：

- Combat Event
- Actor
- Identity
- PVP / PVE 分类
- Damage / Taken / Heal 等统计
- Boss 投影
- 人工纠错
- Unknown Actor 与历史回填
- 排行 Domain

#### Healer

负责：

- 治疗条件
- 团队成员健康 / Buff 规则
- 高亮状态
- 治疗辅助业务判断

#### Gear

负责：

- Gear Profile
- 当前方案
- 换装事务
- 装备状态机

#### Plates

负责：

- Plate 相关状态
- Buff / Debuff Tracking
- 可见单位对应 Plate 业务信息

其它 Module 同理。

---

## 3. Module Manager

所有公开功能必须通过统一 Module Manager 注册。

建议 Contract：

```lua
ModuleManager:Register({
    Id = "dps",
    Name = "DPS统计",
    Category = "combat",

    DefaultEnabled = false,

    Initialize = ...,
    Enable = ...,
    Disable = ...,
    Shutdown = ...,

    OpenSettings = ...,
    DescribeRuntime = ...,
})
```

### 3.1 生命周期

```text
Loaded
  ↓
Initialized
  ↓
Enabled
  ↓
Disabled
  ↓
Shutdown
```

### 3.2 Disable 的正式语义

`Disable` 不能只做：

```lua
window:Show(false)
```

而必须尽可能停止该模块的业务 Runtime：

- 停止不再需要的 Event Handler
- 停止 OnUpdate / Scheduler Job
- 停止单位扫描
- 停止 Buff 扫描
- 停止周期 API Query
- 停止排序 / 重建 / 投影
- 停止 HUD 刷新
- 保留用户配置
- 保留已存在业务数据，除非用户显式执行清空

### 3.3 Disable 不等于 Clear

模块关闭时：

- **不清空 DPS**
- **不删除 Gear 方案**
- **不删除 Tracking**
- **不重置 HUD 布局**

清空数据必须是独立、明确的操作。

---

## 4. 新安装默认策略

目标：**Quiet by Default**。

第一次安装后，屏幕上原则上只出现 Replicated Suite 的统一入口。

### 4.1 默认启用

Suite 原本的基础生活 / 活动能力可以默认启用，例如：

- 活动
- 债券
- 跑商
- 日常
- 资源统计

但其长期 HUD 默认隐藏。

### 4.2 默认关闭

专业模块默认关闭，例如：

- DPS
- Gear
- Healer
- Plates
- 专业 Buff Tracking
- 未来高频扫描模块

### 4.3 新增模块

版本升级新增模块时：

- 默认关闭
- 首页提供非打扰的“新增功能”提示
- 用户看过后消失
- 不强制弹窗
- 不自动往屏幕增加 HUD

---

## 5. Suite 首页与导航

Suite 主界面采用：

> **左侧分类导航 + 生活综合 Dashboard 首页 + 自定义常用入口**

### 5.1 首页

保留当前生活综合面板的优势：

- 一打开就能看到大量日常需要的信息
- 不为了“架构整齐”破坏现有好用体验

首页可增加：

- 模块简要状态
- 新功能提示
- 更新重要变化
- 常用入口
- HUD 状态摘要

首页只显示简要模块状态。

例如：

```text
DPS       ON
Gear      ON
Healer    OFF
Plates    ON
```

详细 Runtime 状态进入模块详情 / 诊断。

### 5.2 左侧导航

建议分类：

```text
首页
生活
活动
战斗
模块
HUD
设置
诊断
```

未来可扩展。

### 5.3 常用入口

用户可将页面 / 模块 / HUD 管理入口标记为常用。

规则：

- 使用星标或等价操作加入 / 移除
- 支持排序
- 首页常用区只显示用户自己加入的内容
- 新模块不得偷偷进入常用区

### 5.4 默认启动页

用户可选择：

- 生活首页
- 战斗
- 活动
- 模块管理
- 上次打开页面
- 其它已注册页面

默认仍以现有生活综合首页为优先。

---

## 6. Module Enabled 与 HUD Visible 必须分离

统一状态必须区分：

```text
Module Enabled
HUD Visible
HUD DisplayState
```

不能把三者混为一个布尔值。

### 6.1 Module Enabled

控制业务 Runtime 是否运行。

### 6.2 HUD Visible

控制 HUD 是否参与显示。

### 6.3 DisplayState

至少有：

```text
Expanded
Collapsed
```

`Hidden` 不应替代长期保存的 Visible 偏好。

推荐 Effective 状态模型：

```text
ModuleEnabled = false
    → EffectiveVisible = false
    → 但保留 HUD 的 Visible / Expanded / Collapsed 原状态

ModuleEnabled = true
Visible = false
    → HUD 不显示

ModuleEnabled = true
Visible = true
DisplayState = Collapsed
    → 显示缩小栏

ModuleEnabled = true
Visible = true
DisplayState = Expanded
    → 正常显示
```

重新启用 Module 后应恢复之前的 HUD 状态。

---

## 7. 多 HUD Module

一个 Module 可以拥有多个 HUD。

例如 DPS 未来可能有：

- 主排行
- Boss 排行
- 简化排行
- 死亡记录提示
- 其它独立 HUD

模块页只显示摘要：

```text
DPS
3个HUD / 当前1个显示
```

进入详情后逐个管理。

同时统一 HUD 管理中心也能管理所有模块 HUD。

两个入口必须操作同一份 Authority。

---

## 8. 专业模块首次启用

生活 / 活动基础模块不需要打扰用户。

专业模块第一次启用时，可以显示一次极简说明。

例如：

```text
DPS 已启用。
排名 HUD 当前未显示，可在 HUD 管理中开启。
```

不同 Module 的首次 HUD 行为由 Module Descriptor 声明，而不是散落硬编码。

---

## 9. DPS 数据范围

DPS 设置提供：

```text
数据范围
● 团队模式
○ 范围模式
```

### 9.1 团队模式

适合副本、固定团队、联合团队，以及更重视准确率和低开销的玩家。

正式统计对象：

```text
SELF + TEAM
```

非团队单位不进入完整排行榜，但仍可作为目标、承伤来源以及 PVP/PVE 判断上下文。

因此团队模式不会因为“只统计团队”而破坏：
- Boss / NPC PVE 分类
- 团队成员承伤来源
- 技能 / 目标 / 来源明细

团队模式应显著降低范围扫描和身份推断开销。

### 9.2 范围模式

适合开放世界、世界 Boss、大规模 PVP，以及需要统计团队外友军 / 敌军 / NPC 的玩家。

范围模式尝试统计：
- SELF / TEAM
- 团队外友军
- 敌军玩家
- NPC / Boss
- 召唤物等已确认实体
- 后续解析成功的 Unknown

范围模式仍把 TEAM 当作高可靠 Authority；其它 Actor 再使用 API、战斗关系、辅助证据和人工纠错判断。

### 9.3 默认

为了保持现有 Replicated DPS “尽可能统计所有可见单位”的产品目标：

```text
默认：范围模式
```

已有用户配置优先保留。

### 9.4 模式切换

团队模式 / 范围模式切换：
- 不自动清空统计
- 不伪造切换前未采集的数据
- 只影响后续事件的采集与正式 Actor Admission

如用户希望得到一份纯团队 / 纯范围统计，应由用户显式清空。

---

## 10. Healer 产品范围修正

删除：

- “第1推荐治疗玩家”
- “第2推荐治疗玩家”
- “第3推荐治疗玩家”
- 独立的“哪些玩家需要治疗”推荐列表 HUD
- 如果排名结果没有其它消费者，则删除对应全队排名计算

原因：

> 看到列表但无法便捷选择该玩家，实际价值较低，反而占屏幕和计算成本。

保留有实际价值的能力：

- 团队列表高亮
- 玩家 / 团队状态颜色
- 血量规则
- Buff / Debuff 规则
- 治疗距离
- 紧急状态
- 其它能够直接帮助玩家判断的治疗辅助能力

---

## 11. 设置体系

复杂模块的设置不能全部平铺。

统一层级：

```text
常用
外观
高级
诊断
```

### 10.1 设置搜索

Suite 提供全局搜索。

例如：

```text
透明度
排行榜人数
治疗距离
Buff颜色
背景
```

搜索结果必须能直接跳转到：

- 对应 Module
- 对应设置页
- 对应具体设置项

即使 Module 当前关闭，也必须能被搜索到。

### 10.2 关闭模块后仍可配置

Module Disabled 时：

- 设置页仍可打开
- 静态配置仍可修改
- 页面顶部明确提示“当前模块未启用”
- 真正依赖 Runtime 的动作按钮单独禁用

例如：

- 开始校准
- 立即扫描
- 当前目标测试
- Runtime Debug

---

## 12. 功能方案

独立于 HUD 布局方案。

示例：

```text
大型团战
  DPS       ON
  Plates    ON
  Gear      ON
  活动      ON
  跑商      OFF
  钓鱼      OFF

生活
  DPS       OFF
  Plates    OFF
  Gear      ON
  活动      ON
  跑商      ON
  钓鱼      ON
```

支持：

- 多个功能方案
- 复制当前 Module 状态创建方案
- 用户主动切换

---

## 13. 组合快捷方式

功能方案与 HUD 布局方案保持独立。

但允许用户显式创建组合快捷方式：

```text
大型团战
功能方案：大型团战
HUD方案：团战HUD
```

点击一次才同时切换。

规则：

- 系统不能偷偷自动绑定
- 用户必须明确创建
- 不根据战斗状态自动切换
- 可以预留未来“建议切换”能力，但不得自动替用户执行

---

## 14. 多角色 / Account Scope

采用：

> **全局基础配置 + Character Override**

每个 Module 声明数据作用域。

适合 Account：

- Theme
- 全局 HUD 字体
- 全局背景默认值
- 标题栏按钮默认值
- 活动通用设置

适合 Character：

- Gear 方案
- 职业治疗规则
- 角色相关业务设置

HUD 布局：

- 可默认 Account 共享
- 允许 Character 覆盖

禁止所有数据强制使用同一个 Scope。

---

## 15. 危险操作

根据风险分级。

### 普通

例如：

- 恢复单个 HUD 位置
- 恢复字体
- 恢复背景

直接执行。

### 中风险

例如：

- 删除一个布局方案
- 删除某个自定义方案

简短确认。

### 高风险

例如：

- 清空全部 DPS
- 删除全部 Gear 方案
- 重置整个 Suite
- 恢复所有 Module 默认设置

必须明确二次确认。

如果可以自动备份，则高风险操作执行前优先创建临时恢复点。

---

## 16. 故障隔离

一个 Module 失败不能拖死整个 Suite。

例如 Plates 初始化失败：

```text
Suite       正常
DPS         正常
Gear        正常
Activities  正常
Plates      Safe Disabled
```

失败 Module：

- 进入安全禁用
- 停止重复报错
- 保留错误上下文
- 允许用户手动重试
- 诊断页显示失败阶段

---

## 17. 日志与诊断

正式版默认不刷聊天框。

只提示真正需要用户处理的问题，例如：

```text
Plates 启动失败，请打开 Suite → 诊断
配置迁移有 2 项需要检查
```

不要打印：

- 扫描了多少单位
- 排行刷新
- 缓存清理
- 普通 Scheduler 状态
- 高频 Debug

诊断日志等级：

```text
关闭
错误
警告
调试
详细
```

正式版默认：

```text
错误 + 必要警告
```

---

## 18. 一键诊断摘要

提供：

- 模块级诊断摘要
- 完整 Suite 诊断摘要

例如：

```text
Replicated Suite Version
Client Language
Module States
HUD States
Schema Versions
Migration State
API Capability State
Runtime Backlog State
Recent Errors
```

必须过滤：

- 聊天内容
- 不相关个人信息
- 无关账号数据
- 其它隐私信息

---

## 19. 更新提示

检测到版本变化后：

首页显示一次：

```text
Replicated Suite vX 已更新
[查看重要变化]
```

只突出影响用户操作的变化，例如：

- HUD 关闭按钮已移除
- 新模块默认关闭
- 某设置迁移
- 某入口变化

普通代码修复进入完整 Changelog。

用户看过一次后首页提示消失。

诊断 / 关于页仍可查看完整版本历史。

---

## 20. 旧 Addon 迁移策略

正式单 Suite 发布时：

- 用户直接删除旧的独立 Replicated DPS / Gear / Healer / Plates 等 Addon
- 不开发长期“新旧两套 Runtime 共存”兼容层
- 不允许新旧两套 Authority 同时运行

旧配置迁移是独立技术任务：

- 能安全读取则尽量自动迁移
- 迁移失败必须有摘要
- 如果技术成本或风险过高，可单独调整策略
- 不为了迁移旧数据重新保留旧 Runtime

---

## 21. 私人模块

私人功能不得进入公共发行包。

例如用户明确要求不公开的自动吃药功能。

推荐：

```text
modules/
modules_private/
```

或独立：

```text
Replicated Private Extension
```

公共发布流程必须自动排除私人代码、设置入口和文档。

禁止依赖“发布前人工删除”。

---

## 22. 重构顺序

推荐：

1. Freeze 当前稳定行为
2. Common / Module Contract / HUD Contract
3. Suite 原生功能模块化
4. Gear
5. Plates
6. Healer
7. DPS 外围 UI / Integration / Storage
8. DPS Runtime / Domain 渐进拆分
9. 删除旧 Bridge / 重复 Framework

**不要从 DPS Domain 重写开始。**

---

## 23. 不允许的伪重构

以下不算重构完成：

### 只拆文件

```text
9554行 core.lua
→ 20个文件
```

如果 Authority 和 State 仍混乱，不算完成。

### 超级 Core

禁止：

```text
SuiteCore.lua 30000行
```

### 全局可写 State

禁止：

```text
ReplicatedGlobalState
```

让所有 Module 任意互改。

---

## 24. 产品侧硬规则

1. 对外一个公开 Suite。
2. 对内严格 Module 化。
3. Module 自己拥有 Domain Authority。
4. Suite 管生命周期，不接管业务 Authority。
5. Disabled 真正停止 Runtime。
6. Disable 不清数据。
7. Module Enabled / HUD Visible / Collapsed 分离。
8. 新安装 Quiet by Default。
9. 专业模块默认关闭。
10. 新模块升级后默认关闭。
11. 首页保留生活综合 Dashboard。
12. 设置可搜索。
13. 专业模块故障必须隔离。
14. 正式版日志不能刷屏。
15. 私人模块绝不混入公共发行。
16. DPS 提供团队模式 / 范围模式；默认范围模式以保持当前“尽可能统计所有可见单位”的产品目标。
17. 团队模式不把非团队单位提升为完整排行 Actor，但必须保留分类与承伤/目标所需 Context。
18. 切换 DPS 数据范围不得自动清空统计。
19. 重构不得未经验证改变已确认业务语义。



<a id="sec-2"></a>
## 2. Replicated Suite UI / HUD 统一规范 v1

> 来源（已合并至本权威文档，原文件已收口）：`replicatedsuite\Docs\Architecture\Core\Replicated_Suite_UI_HUD_Spec_v1.md`

## Replicated Suite UI / HUD 统一规范 v1

> 日期：2026-08-15  
> 状态：**UI / HUD 正式产品基线**

---

## 1. UI 分类

统一分三类。

### 1.1 Main / Config Window

例如：

- Suite 主菜单
- DPS 高级设置
- Gear 编辑器
- Healer 规则设置

允许：

- 关闭按钮
- Resize
- Tabs
- Scroll
- 表单

### 1.2 HUD / Floating Window

例如：

- 活动时间
- DPS 排行
- Gear 快捷栏
- Buff HUD
- 钓鱼状态
- 资源统计

特点：

- 长期存在于游戏画面
- **不提供 × 关闭按钮**
- **保留 +/- 快捷缩小 / 展开**
- 支持独立字体和背景
- 支持极小尺寸
- 显示 / 隐藏由 Suite 主菜单 Authority 管理

### 1.3 Dialog / Tool Window

例如：

- Buff 选择器
- 颜色编辑器
- 详细信息
- 临时诊断工具

可以有关闭按钮。

---

## 2. HUD 显示状态

长期 HUD 状态：

```text
Expanded
Collapsed
Hidden（由 Visible / EffectiveVisible 决定）
```

### 2.1 Collapsed

保留。

这是高频快捷能力，不应删除。

缩小后的 HUD：

- 可以收成单行 / 标题栏
- 可以显示摘要
- 再次点击恢复原展开尺寸
- Collapsed 状态跨重启保存

### 2.2 Close

长期 HUD 不显示 `×`。

真正隐藏只能从：

- Suite 主菜单
- HUD 管理
- 其它统一管理入口

避免玩家误关闭后不知道如何恢复。

---

## 3. 标题栏快捷按钮

采用：

> **全局默认 + 单 HUD 覆盖 + Capability-aware**

HUD 只显示自身支持的按钮。

可支持：

- 字体 -
- 字体 +
- 背景透明度
- 锁定
- 缩小 / 展开
- 设置齿轮

不支持的能力不显示对应选项。

### 3.1 多入口同 Authority

HUD 外观设置可以从：

- HUD 管理
- Module 设置
- HUD 编辑模式现场快捷入口

进入。

三个入口必须修改同一份配置。

---

## 4. 标题栏显示策略

HUD 标题栏允许：

- 默认显示
- 默认隐藏
- 用户覆盖

由每个 HUD 声明推荐默认值。

正常模式允许完全隐藏标题栏。

进入 HUD 编辑模式时：

> 标题栏临时恢复显示，确保用户可以识别和编辑窗口。

### 4.1 标题文本

每个 HUD 提供：

- 正式标题
- 短标题

用户可以覆盖显示名称。

禁止依赖自动字符截断作为主要标题缩写方案。

---

## 5. HUD 编辑模式

Suite 提供：

```text
[编辑 HUD 布局]
```

进入后：

- 所有可编辑 HUD 显示编辑边界
- 标题栏临时出现
- Resize Handle 可见
- 吸附启用（若全局允许）
- 可调整位置 / 尺寸
- 可进入当前 HUD 设置

退出方式：

- 屏幕顶部“完成编辑”
- 再次点击 Suite 的“编辑 HUD 布局”

不依赖 ESC。

---

## 6. 锁定

锁定主要控制位置移动。

规则：

- 锁定后正常模式不能拖动
- HUD 编辑模式仍尊重锁定状态
- 编辑模式提供“临时解锁全部 HUD”
- Resize 只在 HUD 编辑模式处理

不建议将“锁位置”和“锁尺寸”暴露成两个常驻复杂设置。

---

## 7. 鼠标穿透

每个 HUD 可声明/配置：

- 锁定后内容穿透，标题按钮仍可点击
- 锁定后完全穿透
- 不适合完全穿透

例如 Gear 快捷栏属于可交互 HUD，不应强制套纯信息 HUD 的穿透策略。

---

## 8. 战斗中编辑

默认：

> 战斗中允许进入 HUD 编辑模式。

只有某个具体 API / Widget 经实测在战斗中受限时，才禁用那个具体操作。

禁止人为做：

```text
if inCombat then
    禁止整个HUD编辑
end
```

---

## 9. 自由尺寸原则

这是硬规则。

### 9.1 不设置内容级最小尺寸

禁止因为：

- 文本完整
- 布局好看
- 控件默认高度

而设置很大的：

```lua
minWidth = 300
minHeight = 220
```

只允许极小的：

```text
Technical Safe Minimum
```

用于避免：

- 0 尺寸
- 负尺寸
- 原生 Widget 异常
- 无法恢复

### 9.2 Resize Handle

即使 HUD 已经缩得非常小，也应尽可能保证：

> 用户仍然能找到一个可靠的 Resize Handle 或通过 HUD 管理恢复。

### 9.3 用户尺寸 Authority

用户可以把窗口缩得非常小。

允许：

- 挤压
- 裁切
- 重叠
- 列靠得很近

不要为了“看起来漂亮”阻止用户继续缩小。

---

## 10. Auto Size 与 Manual Size

### 10.1 初始

HUD 可以：

```text
SizeMode = Auto
```

根据内容提供合理初始尺寸，避免空白区。

### 10.2 用户手动 Resize

立即切换：

```text
SizeMode = Manual
```

之后：

- 内容减少，不自动缩小
- 内容增加，不自动放大
- 不偷偷改变用户摆好的布局

只有用户主动：

```text
[自动适应内容]
```

才恢复 Auto。

---

## 11. 小窗口的信息策略

窗口缩小时：

1. 减少 Padding
2. 减少列间距
3. 减少控件间距
4. 使用短标题
5. 使用关键词缩写
6. 使用紧凑数值 / 时间
7. 允许裁切
8. 最后允许局部重叠

**尽量不要出现 `...`。**

禁止为了适配小窗口自动删除重要业务字段。

---

## 12. 文字省略号规则

开发中经常出现：

```text
文字超出 → ...
```

以后必须严格检查。

### 12.1 正常推荐尺寸

原则：

> **禁止无意出现 `...`。**

出现省略号必须能解释为经过设计的行为，否则视为布局 Bug。

### 12.2 极端手动缩小

用户主动把 HUD 压得极小时：

- 可以裁切
- 可以拥挤
- 可以使用更短文案

但仍优先：

> 关键词缩写 > `...`

---

## 13. 文案缩写

模块为常用文本提供：

- Long Label
- Short Label
- Compact Label（必要时）

例如：

```text
恢复所有悬浮窗口默认位置
→ 恢复HUD位置

鲸鱼海湾战争阶段剩余1小时16分钟
→ 鲸鱼 战争 1:16

Replicated DPS 伤害统计
→ DPS
```

禁止完全依赖 UI 控件自动截字。

---

## 14. 玩家名与关键数字

RU 服实际环境：

- 玩家名主要是俄文 / 英文
- 玩家不允许中文名
- 中文客户端大量 NPC 名称为中文

UI 压力测试必须覆盖：

```text
中文NPC名称
VeryLongEnglishPlayerName
ОченьДлинноеРусскоеИмя
```

### 14.1 排行表

名字列：

- 弹性最大
- 实在不够时允许裁切
- Hover 可查看完整名字

关键数值列：

- 伤害
- 治疗
- 承伤
- 名次
- 时间

尽量完整显示。

不要让一个长名字把：

```text
12.85M
```

挤成：

```text
12...
```

---

## 15. 数值显示

默认：

- HUD 使用短格式
- Detail 使用完整值

用户可选择：

```text
完整
短格式
```

例如：

```text
12,845,392
→ 12.85M
```

---

## 16. 时间显示

支持：

```text
简洁时间
中文时间
```

默认 HUD 使用简洁格式。

例如：

```text
1小时16分钟
→ 1:16
```

详细页可使用：

```text
1时16分
```

---

## 17. 字体

统一：

```text
Global HUD Font Scale
Per-HUD Font Scale
```

单 HUD 可：

- 继承全局
- 使用独立设置
- 恢复继承

全局修改只影响仍在“继承”状态的 HUD。

### 17.1 字体与窗口尺寸独立

禁止：

```text
窗口缩小
→ 自动缩字体
```

用户可以自由选择：

- 小窗口 + 大字体
- 小窗口 + 小字体
- 大窗口 + 大字体

---

## 18. 背景透明度

统一：

```text
Global Background Alpha
Per-HUD Background Alpha
```

单 HUD 同样支持：

- 继承
- 独立
- 恢复继承

必须区分：

```text
Background Alpha
Text Alpha
```

背景 0% 时：

- 背景透明
- 文字仍正常显示

禁止通过整个 Window Alpha 模拟背景透明。

---

## 19. 紧凑模式

支持：

```text
Global Compact Mode
Per-HUD Override
```

紧凑模式只允许影响：

- 文案缩写
- Padding
- 间距
- 行距

不得自动：

- 修改用户窗口尺寸
- 修改字体大小
- 隐藏业务字段

---

## 20. Collapsed 摘要

每个 Module 自己定义缩小摘要。

支持：

- 多个摘要模板
- 所有 HUD 通用“仅标题”
- 复杂 HUD 可允许用户勾选摘要字段

例如 DPS：

```text
名次 + 自己伤害
前3名
总伤害
仅标题
```

活动：

```text
下一个重要活动
所有紧急倒计时
仅标题
```

---

## 21. 吸附

HUD 编辑模式支持：

- 屏幕边缘吸附
- HUD 与 HUD 之间吸附

全局可关闭。

只在 HUD 编辑模式生效。

正常游戏拖动（如果解锁）不应突然强吸附导致窗口跳动。

---

## 22. 分辨率 / UI Scale 变化

目标：

1. 优先按相对位置恢复布局
2. 如果计算后完全离屏，执行安全救援
3. 至少保留可操作区域在屏幕内

不要简单把所有 HUD 强制 Clamp 到同一个角落。

---

## 23. 首次显示位置

每个 HUD 声明推荐 Anchor。

例如：

```text
活动 → 右上
DPS → 右侧
Gear → 左下
```

HUD Manager 检查已有窗口，尽量避免完全重叠。

如果当前正在使用 HUD 布局方案：

> 优先寻找当前方案中的空闲区域。

---

## 24. 临时隐藏全部 HUD

Suite 提供：

```text
[临时隐藏全部]
[恢复全部]
```

行为：

- 不修改长期 Visible 配置
- 不关闭 Module
- 不修改 Expanded / Collapsed 长期状态
- 不跨重启

恢复时精确恢复隐藏前：

- Expanded
- Collapsed
- Hidden

如果临时隐藏期间用户主动修改某个 HUD 的长期配置，则以新配置为准。

---

## 25. HUD 布局方案

支持多方案：

```text
日常
副本
大型团战
跑商
钓鱼
```

保存：

- 位置
- 大小
- 字体
- 透明度
- 标题栏
- Visible
- Collapsed
- 其它纯 UI 状态

不保存：

- Module Enabled

支持：

- 复制当前布局创建方案
- 主菜单快捷切换
- 可选的小型“布局切换器 HUD”

布局切换器默认关闭。

---

## 26. HUD 管理与恢复

每个 HUD 提供：

- 恢复位置
- 恢复尺寸
- 恢复字体
- 恢复背景
- 恢复标题栏按钮
- 全部恢复

单项恢复不要求确认。

“全部恢复”需要二次确认。

### 26.1 找回 HUD

每个 HUD 提供：

```text
[找回这个HUD]
```

只做：

- 移回屏幕
- 恢复可操作尺寸

不改变字体、背景等其它配置。

### 26.2 紧急恢复全部 HUD

提供：

```text
[紧急恢复全部HUD]
```

需要二次确认。

---

## 27. UI 文本压力测试

所有公共 UI 组件必须使用长文本测试：

- Button
- Label
- Table
- Tab
- Edit
- HUD Title
- Tooltip
- List Item

至少覆盖：

- 中文
- 英文
- 俄文
- 数字
- 百分比
- 长时间字符串

---

## 28. UI 验收硬规则

每个 HUD / 公共窗口至少验证：

- [ ] 新安装不会自动冒出陌生 HUD
- [ ] HUD 无 `×` 关闭按钮
- [ ] HUD 有统一 `- / +` 缩小展开
- [ ] Collapsed 跨重启保留
- [ ] 可隐藏标题栏
- [ ] 编辑模式标题栏临时出现
- [ ] 锁定行为正确
- [ ] 鼠标穿透按 HUD 正确工作
- [ ] 战斗中能编辑，除非实测有具体限制
- [ ] 可以缩到极小
- [ ] 不存在内容级大 minWidth/minHeight
- [ ] Resize Handle / 找回机制可靠
- [ ] Manual Size 不被内容变化覆盖
- [ ] 字体与尺寸独立
- [ ] 背景透明不影响文字
- [ ] 正常推荐尺寸不出现无意 `...`
- [ ] 短文案保留关键字
- [ ] 俄文 / 英文 / 中文长文本压力测试
- [ ] 关键数值优先完整
- [ ] 分辨率变化后窗口不会永久丢失
- [ ] 临时隐藏全部能精确恢复
- [ ] 设置跨重启保存



<a id="sec-3"></a>
## 3. Replicated Suite 200人数据、Runtime 与 API 治理规范 v1.1

> 来源（已合并至本权威文档，原文件已收口）：`replicatedsuite\Docs\Architecture\Core\Replicated_Suite_Runtime_Data_API_v1.md`

## Replicated Suite 200人数据、Runtime 与 API 治理规范 v1.1

> 日期：2026-08-15  
> 状态：**技术架构基线 + 待验证事项清单**  
> v1.1：新增 DPS 团队模式 / 范围模式 Scope Policy  
> 重要说明：本文件中的“产品优先级”和“架构方向”已确认；具体 API 名称、可用状态、身份恢复证据、时间阈值等必须在正式重构前通过 RU 官方 API、当前 `z_api_functions`、其它 DPS 源码和实测验证后落地。

---

## 1. 容量基线

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

## 2. 核心问题：可观测上限与 Unknown

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

2026-08-29 M1.15.1 已把这条原则落为 `CombatEventBusV3 + UnitIdentityV3`：CombatEventBus 只标准化 Native combat fact，UnitIdentity 只做保守 endpoint identity；任何 PVP/PVE/敌我/排名结论都不能回流到底层。全局 COMBAT_MSG 桥也不是常驻基础成本，只有 `scope=all` Consumer 存在时才启用。

先确认：

```text
发生了什么
```

再确认：

```text
是谁
```

---

## 3. World Observation Service

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

## 4. Observation Subscription

采用按需订阅。

例如只有 DPS 开启时：

- 不查询 Healer 专用昂贵数据
- 不查询 Plates 专用昂贵数据

Healer 开启后：

- 增加 Health / Buff 等需求

Module Disabled 后：

- 自动释放对应 Subscription

---

## 5. 数据分层

### 5.1 轻量全体

尽可能覆盖所有当前可观测单位：

- Unit Reference
- Name
- Distance
- Basic Health
- Basic Type Clue
- Visible / Last Seen
- 基础关系线索

### 5.2 昂贵按需

例如：

- 完整 Buff
- 装备
- 职业扩展
- 复杂 Tag
- 深层 UnitInfo
- 其它高成本 Query

只对热点 Actor 做预算更新。

---

## 6. 热点优先级

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

## 7. Runtime 优先级

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

## 8. Backlog

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

## 9. Observation TTL 与 Domain Lifetime

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

## 10. Event Fact

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

## 11. Unknown Actor

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

## 12. Identity Resolver

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

## 13. 人工纠错

人工规则拥有更高 Authority。

如果未来支持 Unknown → Player 手动绑定：

- 必须可撤销
- 必须触发历史重新投影
- 自动推断不得覆盖人工规则
- 删除人工规则后才允许重新自动判断

---

## 14. 召唤物

方向：

- 无主人信息时作为独立 Actor
- 确认主人后，主排行可合并给主人
- Detail 保留召唤物来源
- 历史数据允许回填

具体 Owner API 必须先验证。

---

## 15. 名字规则

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

## 16. DPS 数据范围模式（Scope Policy）

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

### 16.1 团队模式

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

#### 团队模式不是完全忽略非团队单位

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

#### 团队模式性能规则

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

### 16.2 范围模式

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

### 16.3 范围模式继续使用现有判断体系

范围模式继续使用现有、已验证并可人工纠错的证据体系，包括：
- 有效治疗关系 → 友军强证据
- 对自己造成有效伤害 → 敌军强证据
- 自己对某单位造成有效伤害 → 敌对强证据
- 团队成员 → 明确友军 / 玩家 Authority
- 人工设置友军 / 敌军 / 玩家 / NPC / 召唤物 → 高 Authority
- 中文名 → 当前中文客户端环境中的 NPC 强线索，但不是唯一证据
- 俄文 / 英文名称不得直接等价为玩家

具体权重、冲突解决、自动合并阈值属于技术验证项，不要求用户拍脑袋决定。

### 16.4 两种模式必须共享同一 Domain Pipeline

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

### 16.5 模式切换

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

### 16.6 UI 文案

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

### 16.7 默认与迁移

当前 Replicated DPS 的既定目标是“尽可能统计客户端可见的所有单位”，因此无旧配置可迁移时：

```text
默认：范围模式
```

已有明确用户配置时，以用户配置为 Authority。未来默认值改变也不得静默覆盖用户选择。

---

## 17. DPS PVP / PVE 规则

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

## 18. DPS Accuracy Priority

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

## 19. Event 去重

需要区分：

### Strong Dedup

如果 API 有明确：

- EventId
- SequenceId
- 唯一事件标识

则可强去重。

### Heuristic Dedup

没有唯一 ID 时：

- 只能非常谨慎
- 使用短窗口
- 结合 Source / Target / Skill / Amount / Type / Time

高风险“疑似重复”不应直接永久丢弃。

具体算法必须在其它 DPS 和实际 Event 样本基础上验证。

---

## 20. 原始事件分层

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

## 21. State 四分法

所有大型 Module 逐步统一：

```text
Config
Runtime
Domain
Cache
```

### Config

持久配置。

### Runtime

Session Handler / Job / Queue / Dirty State。

### Domain

业务 Authority。

### Cache

可重建：

- 排行
- Name Index
- UI Projection
- Sort Result
- Lookup

禁止 Cache 清理误删 Domain。

---

## 22. Scheduler

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

### 22.1 M1.15.7 Scheduler / Events 生命周期补强

- Scheduler 的**静态** `taskModules` 映射可跨 Service 停启保留；递增名称/临时 one-shot 必须使用 transient ownership，并在 RemoveTask / RemoveOwner / Stop 时回收，禁止长期积累死键。
- `RefreshCoordinator` 的 `refresh_coordinator_<sequence>` 属 transient task；它不得把每次请求留下永久 Module metadata。
- Core Events 的 Native `RegisterEvent` 是 Subscribe/Start **事务的一部分**：注册失败不得提交 listener；批量启动中任一注册失败必须回滚已注册事件和 Handler。
- Event/Service 的 `subscribed=true` 只能在真实 Subscribe 返回 true 后设置；下游 Lease/任务已经取得但后续订阅失败时必须回滚。

---

## 23. API 治理

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

## 24. API Capability Registry

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

## 25. API 证据来源

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

## 26. Runtime Probe

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

## 27. 其它 DPS 对照研究

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

## 28. 技术侧待验证项目

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

## 29. 性能验收场景

正式重构后至少验证：

### 小队

- 5 人副本
- Boss 连续战斗

### 中型

- 50 人团队
- 高频 Buff / Heal

### 大型

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

## 30. 技术架构硬规则

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



<a id="sec-4"></a>
## 4. Replicated Suite Foundation Decisions v2

> 来源（已合并至本权威文档，原文件已收口）：`replicatedsuite\Docs\Architecture\Core\REPLICATED_SUITE_FOUNDATION_DECISIONS_v2_20260826.md`

## Replicated Suite Foundation Decisions v2

日期：2026-08-26  
状态：**已决定 / 后续重构必须遵守**

本文记录 Replicated Suite 进入大型工程阶段后的基础架构约束。目标不是单纯减少文件或代码行数，而是让重复机制只有一个 Authority，让业务模块只保留业务规则，并保证长期开发期间可以诊断、恢复、迁移和验证。

---

### 1. 总原则：Mechanism 与 Policy 分离

公共层只拥有可复用机制，业务 Domain 继续拥有业务规则。

- Core / Shared Infrastructure：生命周期、调度、诊断、存储策略、UI 组件、Game Data Registry、API Gateway。
- Domain：Quest、Event、DPS、Healer、Gear、Plates、Trade 等业务规则与业务状态。
- Projection / ViewModel：给 UI 的只读/派生数据，不反向成为 Domain Authority。

禁止为了“少几行”把不同 Domain 的业务规则塞进万能 Helper。

---

### 2. Diagnostics 是 P0 基础设施

#### 2.1 目标

Bug 不可避免，但必须做到：

1. 能确定哪个模块、哪个阶段、哪个错误码发生问题；
2. 高频错误不会把日志刷爆并反过来制造卡顿；
3. 性能问题可以通过计数/采样追踪，而不是凭感觉猜；
4. 一键诊断内容必须有界，不能无限增长；
5. 不记录不必要的聊天、账号或隐私数据。

#### 2.2 结构化事件

新代码优先使用：

```lua
Diagnostics:Warn("healer", "INVALID_TEAM_INDEX", "团队索引不可用", {
    teamIndex = teamIndex,
    memberIndex = memberIndex,
})
```

标准字段：

- `level`
- `source`
- `code`
- `message`
- `context`
- `at`
- `count`

错误码使用稳定的大写语义名，例如：

- `REGISTRY_VALIDATION_ISSUES`
- `SAVE_FAILED`
- `MIGRATION_FAILED`
- `INVALID_TEAM_INDEX`
- `UI_DUPLICATE_WIDGET`
- `RUNTIME_BUDGET_EXCEEDED`

不要把变化的参数写进错误码。

#### 2.3 高频问题必须限频

高频回调、扫描循环、UI 刷新路径中的重复告警必须使用 RateLimited 接口。

```lua
Diagnostics:WarnRateLimited(
    "healer",
    "INVALID_TEAM_INDEX",
    5000,
    "团队索引不可用",
    { teamIndex = teamIndex }
)
```

相同 `source + code` 在限频窗口内只累计次数，不持续写 Chat/Log。

#### 2.4 只需要统计、不需要日志的事件

使用有界 Counter：

```lua
Diagnostics:Count("ui", "SET_TEXT", 1)
Diagnostics:Count("healer", "BUFF_SCAN_UNIT", 1)
```

后续 UI Framework、Persistence、Runtime Budget 都必须把关键计数接入 Diagnostics。

---

### 3. Game Data Registry：任务/技能/Buff/物品等 ID 的唯一公共入口

#### 3.1 禁止新的 Magic ID 散落到业务代码

错误：

```lua
if questId == 2941 then
end
```

正确方向：

```lua
local Q = ReplicatedSuite.GameIds.Quest
local stageIds = Q.Activity.crimson.stage1
```

所有跨功能复用的 ID 都应分类集中：

- Quest
- Skill
- Buff / Debuff
- Item
- Instance
- Zone
- NPC
- Boss

#### 3.2 Catalog 与 Relationship 分离

Game Data Catalog 回答：**“它是谁 / ID 是什么”**。

Relationship 回答：**“这些 ID 在某个功能中是什么关系”**。

例如：

- `data/ids/rs_quest_ids.lua`：任务 ID 集合和稳定语义 Key；
- `data/rs_quest_data.lua`：Activity 的 objective / relatedObjective 关系；
- `data/rs_skill_effects.lua`：Skill -> Buff/Debuff 关系；
- Registry：ById / ByKey / ByName / ByTag / ByFamily 索引。

不要把 Quest 完成规则、Healer 优先级、DPS 分类规则放进 Registry。

#### 3.3 Registry 查询必须预建索引

高频 Runtime 禁止每次遍历全表或做复杂 Tag 匹配。

Registry 在加载阶段建立：

- `byId`
- `byKey`
- `byName`
- `byTag`
- `byFamily`

热路径只能做 O(1) 查表。

`Registry:List()` 只允许用于加载、显式导入、诊断等低频路径，不能放进 Tick/扫描循环。

#### 3.4 数据可信度

记录允许包含：

- `source`
- `confidence`
- `verified`
- `verifiedAt`
- `notes`

不知道的 ID 不允许猜。

例如红龙/卡杜姆当前没有通过所用 Addon API 验证稳定数字 Instance ID，因此只集中已验证的名称别名/入口上限，不伪造数字 ID。

#### 3.5 当前已迁移范围

本阶段已经：

- 建立 `GameDataRegistry`；
- 集中蓝盐债券物品 ID；
- 集中居民债券任务 ID；
- 集中 `rs_quest_data.lua` 当前 Daily / Weekly / Activity Quest ID；
- 红龙、卡杜姆 Instance 识别定义集中；
- 将现有 `rs_skill_effects.lua` 的所有 Skill/Buff 在加载阶段导入 Registry；
- Plates 的“导入内置实战库”改为通过 Registry 读取 Buff ID，而不是直接依赖另一数据文件内部表。

后续新增功能不得再引入新的可复用裸 ID。

---

### 4. Persistence：先定义数据生命周期，再决定怎么保存

存储必须区分至少五类 Lifetime。

#### 4.1 Permanent

长期永久保留：

- 用户设置；
- 窗口位置/大小；
- 人工友敌名单；
- Gear 方案；
- 自定义追踪 Buff；
- 收藏与用户规则。

#### 4.2 Daily

服务器日周期刷新：

- 每日任务状态；
- 今日荣誉/生活点等日统计；
- 今日居民板收入；
- 其他明确以服务器每日重置为边界的数据。

#### 4.3 Weekly

服务器周周期刷新：

- 周常进度；
- 周统计；
- 其他服务器周重置数据。

#### 4.4 Session

只存在当前登录/当前 Runtime：

- 当前目标；
- Buff 扫描缓存；
- DPS 排序缓存；
- 临时队列；
- Hover / 临时 UI 状态。

**Session 不写 SaveData。**

#### 4.5 Checkpoint

只为 ReloadAddon、短期异常恢复、未提交编辑状态服务。

Checkpoint 不是永久业务数据；后续需要定义过期/恢复规则。

#### 4.6 Daily / Weekly 不能只判断本地日期

不允许简单依赖：

```lua
os.date("%d")
```

长期目标必须使用服务器 Reset Policy / PeriodId：

- Daily PeriodId
- Weekly PeriodId
- Server timezone/reset hour

加载和在线跨周期时都要检测 Period 边界。

#### 4.7 Dirty + Debounce

拖动 UI、输入设置等连续变化不能每次立即 SaveData。

统一方向：

```text
Change -> MarkDirty -> Debounce -> Save
```

Reload / Disable / Shutdown 时再执行 Critical Flush。

#### 4.8 Schema / Migration

持久数据必须有 SchemaVersion，迁移失败时：

1. 不覆盖原数据；
2. Runtime 使用安全默认值；
3. Diagnostics 报 `MIGRATION_FAILED`；
4. 保持写保护，直到确定可以安全保存。

---

### 5. UI Framework：在有限 ArcheAge UI API 上构建强上层能力

底层 UI API 有限不代表每个模块都要直接重复 Create/Anchor/Show/SetText。

长期 UI Framework 分层：

```text
RSUI
├─ WidgetLifetime
├─ DiffRenderer
├─ Layout / Placement
├─ Input / Drag / Resize
├─ ZOrder / WindowManager
├─ Theme
└─ Components
   ├─ Button
   ├─ Label
   ├─ Toggle
   ├─ Slider
   ├─ Dropdown
   ├─ ScrollList
   ├─ Card
   ├─ Tooltip
   └─ Modal
```

#### 5.1 Diff Rendering 是默认规则

禁止无条件高频：

```lua
label:SetText(text)
window:Show(visible)
RemoveAllAnchors()
AddAnchor(...)
```

Framework 需要缓存旧值，只在真实变化时写 Native UI。

目标是直接降低 `MakeSprite - too many sprite update` 风险。

#### 5.2 UI 生命周期统一

WindowManager 最终负责：

- 创建/销毁；
- Reload generation；
- 显示/隐藏；
- 层级；
- Anchor；
- 屏幕边界；
- 分辨率变化；
- 位置保存；
- Lazy Create。

Domain 不能同时成为 Window Lifecycle Authority。

#### 5.3 UI 写操作接入 Diagnostics

后续 Framework 应统计：

- SetText
- Show/Hide
- SetColor
- SetExtent
- Anchor changes

从而可以定位哪个模块产生异常 Sprite 更新量。

---

### 6. Runtime / 性能规则

1. 不在 Tick/高频循环里做全表 ID 搜索；
2. 不在 Tick 中创建大型临时 Table；
3. 大 Raid 扫描优先分片，不在同一帧扫描全部成员；
4. UI 使用 Diff；
5. 多 Runtime 统一服从 Frame Budget Policy；v1 已接管 Suite Scheduler，Professional Runtime 按 Domain 增量迁移；
6. Diagnostics 自身必须有界且限频；
7. 数据丰富度可以高，但 Runtime 查询必须轻。

---

### 7. Authority 约束

后续重构必须明确：

- Native Game State Authority：ArcheAge X2 API；
- External Proxy / Observation：统一缓存游戏读取；Feature 需要额外 Native 边界时使用能力门治理的 `S.Api:CallCapability`（见 [`../CURRENT_ARCHITECTURE.md`](../CURRENT_ARCHITECTURE.md) 附录 §D 能力门）；
- Domain Authority：各 Feature 自己的 store/authority；
- Lifecycle Authority：FeatureRuntime（旧 ModuleManager 已删除）；
- Diagnostics Authority：DiagnosticsManager；
- Game Identity Authority：GameDataRegistry / `GameIds`；
- Persistence Policy Authority：Persistence Framework（`P:RegisterV3Store`，见 [`../CURRENT_ARCHITECTURE.md`](../CURRENT_ARCHITECTURE.md) 附录 §C 持久化契约）；
- Runtime Budget Policy Authority：FrameBudget v1；主动治理 Suite Scheduler，各 Feature 按需接入；
- UI Lifecycle Authority：RSUI Diff/Lifecycle v1；UI Design/Composition Authority：UI Framework v2；WindowManager 已由 V3 UIHostManager + WindowShell 取代（旧 ManagedWindow / HudManager 已删除）；
- 旧 `S.State` / `S.Storage` 已删除（replicatedsuite.lua 显式置 nil + foundation_gate 断言）；业务状态只走各自 Feature Store。

---

### 8. 后续实施顺序

1. Common / ReUse：已开始；
2. Diagnostics Foundation：基础结构已落地，继续迁移稳定 Code/Context；
3. Game Data Registry：基础结构已落地，Quest/Skill/Buff/Item/Instance 已开始集中；
4. Persistence Framework：基础结构已落地，首批 `suite.daily_counters` / `suite.favorites` 已接管，详见 `REPLICATED_SUITE_PERSISTENCE_FRAMEWORK_v1_20260826.md`；
5. UI Framework：Diff Rendering + Lifecycle + WindowManager facade 已稳定；v2 已增加 Design Tokens、Layout Primitives、Window Shell、Binding 与 Composition 基础层，详见 `REPLICATED_SUITE_UI_FRAMEWORK_v1_20260826.md` 与 `REPLICATED_SUITE_UI_FRAMEWORK_v2_DESIGN_SYSTEM_20260826.md`；
6. Runtime / Frame Budget：基础结构已落地，Suite Scheduler 已接入 soft budget + starvation protection，详见 `REPLICATED_SUITE_RUNTIME_FRAME_BUDGET_v1_20260826.md`；
7. 逐 Domain 迁移：Healer Runtime v1 已完成 Health/Status Generation / Atomic Commit / Slice / Diff / FrameBudget；第二批完成 Native API Gateway + Roster Generation + Role 读取收口；第三批已把 Status Cache、Recommendation、Marker、Raid Overlay 从历史 Core 拆成独立 Domain / Presenter；第四批完成 Recommendation List / Buff Observer Presenter 与 Permanent Settings Store 的 Dirty/Debounce；第五批已完成 Settings Model、Historical Migration、Read-only Bootstrap、Suite Settings Presenter，并消除 UI/Domain 设置范围漂移。详见 `REPLICATED_HEALER_DOMAIN_RUNTIME_v1_20260826.md`、`REPLICATED_HEALER_ROSTER_API_GATEWAY_v1_20260826.md`、`REPLICATED_HEALER_DOMAIN_SPLIT_v1_20260826.md`、`REPLICATED_HEALER_GLUE_PERSISTENCE_v1_20260826.md`、`REPLICATED_HEALER_SETTINGS_ARCHITECTURE_v1_20260826.md`。Plates 架构审计与 Phase 11A/11B/11C 已完成：修复 Effect ID 完整扫描与 Aura Factory Reset，接入 FrameBudget/Watchdog Diagnostics，并完成 Lines/Circle Active Range 与 Effect Slot UI Diff；在继续 Aura Observation Domain 前，先完成 UI Framework v2 Design System 基础层，随后恢复 Plates Domain 迁移。DPS 仍只迁移明确可延期的派生维护路径。

大型模块不得一次性推倒重写；必须保持可运行、可诊断、可回滚的增量迁移。

---

### 9. 新功能进入开发前的检查表

每个新功能开始编码前必须回答：

1. 使用了哪些 Game IDs？是否已经进入 Registry？
2. 数据 Authority 是谁？
3. 数据 Lifetime 是 Permanent / Daily / Weekly / Session / Checkpoint 中哪一种？
4. Reset Policy 是什么？
5. 关键失败路径的 Diagnostics Code 是什么？
6. 高频错误是否 RateLimited？
7. UI 是否通过公共组件和 Diff Rendering？
8. 是否存在每帧全量扫描、全量排序、全量 SetText/Show？
9. ReloadAddon 后是否能安全恢复/释放？
10. Migration 失败是否会保护旧数据？

只有这些问题有明确答案，功能才可以继续扩展。



<a id="sec-5"></a>
## 5. Replicated Suite Runtime / Frame Budget Framework v1

> 来源（已合并至本权威文档，原文件已收口）：`replicatedsuite\Docs\Architecture\Core\REPLICATED_SUITE_RUNTIME_FRAME_BUDGET_v1_20260826.md`

## Replicated Suite Runtime / Frame Budget Framework v1

> 日期：2026-08-26  
> 状态：Foundation v2 已落地基础实现  
> Build：`foundation-v2-runtime-budget-v1`

---

### 1. 目标

Replicated Suite 已经拥有多个 Runtime 来源：

- Suite Scheduler；
- DPS 独立 Runtime；
- Healer 独立 Runtime；
- Plates 独立 Runtime / Watchdog；
- Gear 独立 Runtime；
- 少量可见态 Native `OnUpdate` fallback。

单个模块分别做节流并不能保证整帧稳定。多个模块可能在同一帧同时进入较重路径，形成瞬时 CPU / UI / Native API 峰值。

因此 Foundation v2 增加统一的 **Frame Budget Policy Authority**：

```text
Native frame interval / Scheduler backlog
                 │
                 ▼
          FrameBudget Broker
                 │
      ┌──────────┼──────────┐
      ▼          ▼          ▼
   Critical    Normal      Low
   P0/P1       P2/P3       P4/P5
      │          │          │
      └──── soft admission ─┘
                 │
                 ▼
        Suite Scheduler Tasks
```

v1 的核心目标是 **削峰，而不是减少正确性**。

---

### 2. Authority 边界

#### 2.1 FrameBudget 负责

- 根据原生帧间隔和 Scheduler Backlog 判断压力；
- 为 Suite Scheduler 的可延期任务提供软预算；
- 统计任务通行、延期、关键通行和饥饿保底；
- 提供统一诊断快照；
- 为后续 Professional Runtime 迁移提供同一个 Policy API。

#### 2.2 FrameBudget 不负责

- 不执行业务 callback；
- 不创建新的 `OnUpdate`；
- 不成为 Domain State Authority；
- 不替代 ModuleManager 生命周期；
- 不修改 DPS / Healer / Plates / Gear 的业务正确性规则；
- 不把独立 Professional Runtime 强行改写成 Scheduler Task。

#### 2.3 v1 的主动执行范围

**v1 主动治理 Suite Scheduler。**

Professional Runtime 已经拥有自己的 Native `OnUpdate` 和成熟的局部预算逻辑，后续按模块逐步接入，禁止为了“统一”一次性推倒重写。

因此：

```text
FrameBudget = 全局 Policy Authority
Scheduler   = v1 已接入的 Execution Authority
Professional runtimes = 后续增量接入
```

---

### 3. Priority Contract

沿用 Scheduler 已有 P0–P5：

| Priority | 含义 | FrameBudget 行为 |
|---|---|---|
| P0 | 必须立即执行的正确性/事务边界 | 永不因预算拒绝 |
| P1 | 用户操作、关键动作 | 永不因预算拒绝 |
| P2 | 重要 Domain Refresh | 可短暂延期 |
| P3 | 普通周期刷新 | 可延期 |
| P4 | UI / Projection / 次要刷新 | 优先延期 |
| P5 | Maintenance / Watchdog / Prune | 最容易延期 |

关键原则：

> **Priority 表示业务紧迫度，不等于耗时。**

任务耗时由独立 `costUnits` 表达。

---

### 4. Cost Units

`Scheduler:AddTask()` 增加可选第七参数：

```lua
S.Scheduler:AddTask(
    "task_name",
    500,
    Callback,
    false,
    Owner,
    "P3",
    2
)
```

最后一个参数是抽象工作量：

```text
1 = cheap
2 = moderate
3+ = heavy
```

它**不是毫秒数**。

这样做是因为 RU 客户端 Lua 环境不保证存在可靠的单调执行计时器。`PerformanceMonitor` 如果能取得 `os.clock`，仍用于诊断真实耗时；FrameBudget 本身不能依赖这个能力才能工作。

默认 Cost = `1`，现有调用完全兼容。

---

### 5. Frame Pressure

FrameBudget 每个 Scheduler frame 根据两类输入取更严重者：

#### 5.1 Native Frame Delta

```text
< 24ms       Normal
24–39.999ms  Busy
40–69.999ms  Heavy
>= 70ms      Critical
```

#### 5.2 Scheduler Backlog

```text
Normal          -> Normal
Delayed         -> Busy
Heavy Backlog   -> Heavy
Critical        -> Critical
```

最终压力：

```text
max(NativeFramePressure, BacklogPressure)
```

因此即使 FPS 暂时恢复，只要后台已经明显积压，也不会立刻让所有低优先级任务一起补跑。

---

### 6. Budget Profiles

v1 使用抽象 Credit：

| Pressure | Credits | 普通任务最大执行数 |
|---|---:|---:|
| Normal | 10 | 10 |
| Busy | 8 | 8 |
| Heavy | 5 | 6 |
| Critical | 3 | 4 |

P0/P1 可突破普通执行上限，它们会被统计为 `criticalGranted`，但不会被预算拒绝。

这样可以保证：

- 背包移动事务；
- 用户明确触发的关键动作；
- 必须立即完成的状态边界；

不会因为一个后台 UI 刷新而失效。

---

### 7. 延期不是丢弃

预算拒绝时 Scheduler **不消费该周期**：

```text
pending 保留
elapsed 保留
original dueSince 保留
consecutive defer +1
```

下一帧继续参与排序。

由于 Scheduler 排序优先看 Priority，再看 `dueSinceMs`，已经延期的同优先级任务会自然排在刚刚到期的任务之前。

因此不存在：

```text
budget deny -> task lost
```

正确语义是：

```text
budget deny -> deferred work
```

---

### 8. Starvation Protection

如果只有固定预算而没有饥饿保护，低优先级任务可能永久得不到运行机会。

v1 采用两种触发条件：

- 连续延期帧数；
- 相对于自身 interval 的 lateness ratio。

大致策略：

```text
P2  3 frames / late 1.5x
P3  5 frames / late 2.0x
P4  8 frames / late 3.0x
P5 12 frames / late 4.0x
```

但每个 rendered frame 最多允许 **1 个 starvation escape**。

这是非常重要的限制：

> 不能让所有“饿了很久”的任务在同一帧同时突破预算，否则会重新制造长帧。

---

### 9. Scheduler Integration

原 Scheduler 已经有：

- monotonic Suite clock；
- due queue；
- P0–P5 排序；
- hitch 后不多次 catch-up；
- fault isolation。

FrameBudget 不重复这些功能。

新流程：

```text
OnUpdate
  │
  ├─ Begin Performance Frame
  ├─ Advance Suite Clock
  ├─ collect due tasks
  ├─ calculate Scheduler backlog
  ├─ FrameBudget:BeginFrame(...)
  │
  ├─ sorted due tasks
  │    ├─ Request budget
  │    ├─ granted -> RunTask
  │    └─ denied  -> keep pending
  │
  ├─ FrameBudget:EndFrame(...)
  └─ End Performance Frame
```

只有一个 Scheduler `OnUpdate`，没有新增 Driver。

---

### 10. Diagnostics

Diagnostics Snapshot 新增：

```text
FrameBudget.version
FrameBudget.pressure
FrameBudget.frameDtMs
FrameBudget.creditsTotal
FrameBudget.creditsRemaining
FrameBudget.granted
FrameBudget.deferred
FrameBudget.criticalGranted
FrameBudget.starvationRuns
FrameBudget.pendingBefore
FrameBudget.pendingAfter
```

累计统计：

```text
frames
requests
granted
deferred
criticalGranted
starvationRuns
```

并记录最高延期 Owner：

```text
owner
requests
granted
deferred
starvationRuns
maxConsecutiveDefers
```

#### 热路径限制

`FrameBudget:Request()` 禁止：

- 每次写结构化日志；
- 每次创建诊断字符串；
- 全表排序；
- 大量临时 Table。

热路径只更新有界 Counter。

排序和 Top Deferred 只在 Diagnostics `Describe()` 时生成。

---

### 11. 与 PerformanceMonitor 的关系

两者不能合并：

#### PerformanceMonitor

回答：

> “发生了什么？”

负责：

- Frame delta；
- jank；
- optional callback timing；
- 模块热点；
- 未归因长帧。

#### FrameBudget

回答：

> “这一帧允许多少可延期工作？”

负责：

- admission policy；
- defer；
- starvation protection。

因此：

```text
PerformanceMonitor = Observation / Diagnostics
FrameBudget        = Runtime Policy Authority
Scheduler          = Execution Authority
```

---

### 12. Professional Runtime 迁移规则

#### 2026-08-26 Consumer Update

Healer Runtime v1 已成为第一个外部 Professional consumer：

- Health / Recommendation Slice：P1 / cost 1；每帧最多 20 成员，同时最多 8 个 targeted Status refresh；
- Status Slice：P2 / cost 2；Health 工作帧不与其叠加执行，避免两类大量 Buff 读取同帧爆发；
- Roster Slice：P2 / cost 1；Native membership invalidation 立即生效，900ms settle 后的 16-slot / 8-role 扫描分片可延期；
- Visual：P2 / cost 2；
- Settings：P4；
- 分片中的 staging 数据不会因为 Budget 延期而丢失或提前发布。

详见 `REPLICATED_HEALER_DOMAIN_RUNTIME_v1_20260826.md` 与 `REPLICATED_HEALER_ROSTER_API_GATEWAY_v1_20260826.md`。

Plates Runtime Foundation v1 已成为第二个 Professional consumer：

- position / health / casting：P1，保持高优先级响应；
- effects / alerts / distance：P2，延期时保留 accumulator；
- metadata / equipment / cooldown / watch / magic-circle：P3；
- capture / lines / circle / buffcap：P4；
- discovery / manager / watchdog：P5；
- Watchdog 不再 `ForceAll()` 或直接调用 Runtime，而是在正常渲染帧温和恢复。

详见 `REPLICATED_PLATES_RUNTIME_FOUNDATION_v1_20260826.md`。

后续接入顺序建议：

1. Plates UI Diff / Aura Observation；
2. Gear 非事务性维护；
3. DPS 仅接入已经明确可延期的 maintenance lane。

#### 禁止做法

禁止：

```text
FrameBudget says busy
    -> drop combat event
```

DPS 事实事件、治疗关键状态、装备事务等不能因为 Budget 丢失。

正确方向：

```text
Critical facts
   -> always capture

Derived rebuild / sort / UI / persistence
   -> defer / slice
```

这保持项目长期确定的：

> **准确率优先于性能，性能优化通过延后派生工作而不是丢失事实完成。**

---

### 13. Large Raid 规则

FrameBudget 不是“允许一帧扫描 200 人然后下帧休息”的理由。

200 人级 Runtime 仍必须：

- Dirty / Event-first；
- 分片扫描；
- bounded queue；
- incremental rebuild；
- Diff UI；
- 避免 Tick 中大型临时表；
- 避免 Tick 中复杂 Tag 搜索。

FrameBudget 是最后一道削峰层，不替代正确的数据结构。

---

### 14. v1 已完成范围

- `core/rs_frame_budget.lua`；
- Scheduler active integration；
- Scheduler task optional `costUnits`；
- budget deferral accounting；
- bounded starvation protection；
- Diagnostics Snapshot / 全量日志；
- Diagnostics UI；
- Foundation 文档同步。

### 15. v1 明确未做

> 下列条目描述 FrameBudget v1 初始落地边界；Healer 后续接入情况以上述 Consumer Update 和 Healer 专项文档为准。

- 没有强制删除 Professional Module 独立 `OnUpdate`；
- 没有重构 DPS Runtime；
- 没有改 Healer 业务算法；
- 没有改 Plates 目标 Authority；
- 没有改 Gear 装备事务；
- 没有通过“限制事实采集”换取性能。

这些将在后续 Domain Migration 中逐步进行。



<a id="sec-6"></a>
## 6. Replicated Suite UI Framework v1

> 来源（已合并至本权威文档，原文件已收口）：`replicatedsuite\Docs\Architecture\Core\REPLICATED_SUITE_UI_FRAMEWORK_v1_20260826.md`

## Replicated Suite UI Framework v1

日期：2026-08-26  
状态：Foundation v2 已落地第一版，后续模块增量迁移  
版本说明：**Diff/Lifecycle 底层 Contract 继续有效；Design/Composition 当前入口已升级为 `REPLICATED_SUITE_UI_FRAMEWORK_v2_DESIGN_SYSTEM_20260826.md`。**  
实现入口：`ui/rs_ui_framework.lua`

---

### 1. 目标

ArcheAge / ArcheRage RU 提供的 Native UI API 能力有限，而且不同 RU 构建之间存在行为差异。Replicated Suite 不通过猜测不存在的 Native 能力来“做强 UI”，而是在已经验证的 API 表面上建立稳定的上层框架。

UI Framework v1 的目标：

1. 统一高频 UI 写操作，默认使用 Diff Rendering；
2. 减少重复 `SetText / Show / SetExtent / RemoveAllAnchors + AddAnchor`；
3. 建立 Widget/Handler 生命周期登记，降低 Reload / Dialog 重建后的幽灵 Handler 风险；
4. 把 UI 写入量纳入 Diagnostics，但不能让诊断本身成为热路径开销；
5. 继续复用已有 `Layout / HudManager / ManagedWindow / Theme` Authority，不建立第二套相互竞争的窗口系统；
6. 为以后公共组件体系提供统一底座。

---

### 2. Authority 边界

```text
Domain State / Projection
        │
        ▼
       RSUI
        │
        ├─ DiffRenderer
        ├─ Widget Lifecycle
        ├─ UI Metrics
        └─ WindowManager facade
        │
        ▼
ArcheAge Native UI API
```

必须保持：

- Domain 决定“显示什么”；
- RSUI 决定“是否真的需要写 Native UI”；
- Theme 决定颜色、按钮皮肤、字体视觉规则；
- Layout 决定逻辑坐标、Safe Area、分辨率适配；
- HudManager 决定 HUD 显示/锁定/布局 Authority；
- Persistence 决定需要持久化的 UI Placement/Settings 生命周期；
- UI Framework 不能反向成为业务状态 Authority。

---

### 3. Diff Rendering

#### 3.1 默认规则

迁移后的刷新代码不得无条件执行：

```lua
label:SetText(text)
window:Show(visible)
widget:SetExtent(width, height)
widget:RemoveAllAnchors()
widget:AddAnchor(...)
```

应使用：

```lua
S.UI:SetText(label, text, owner)
S.UI:SetVisible(window, visible, owner)
S.UI:SetExtent(widget, width, height, owner)
S.UI:SetAnchor(widget, parent, x, y, owner)
```

Framework 为每个 Native Widget 保存弱引用 Presentation Cache。值没有变化时直接跳过 Native 写调用。

#### 3.2 v1 支持的 Diff 字段

- `SetText`
- `SetVisible`
- `SetExtent`
- `SetAnchor`（TOPLEFT 单锚点公共路径）
- `SetEnabled`
- `SetPickable`
- `SetFontSize`
- `SetAlpha`
- `SetLabelTone`
- `SetButtonActive`
- `SetEllipsis`

复杂多锚点布局仍可直接使用 Native API，但如果同一 Widget 后续交给 DiffRenderer 管理对应字段，必须先调用：

```lua
S.UI:InvalidateNativeState(widget, "anchorTopLeft")
```

或在完全未知时：

```lua
S.UI:InvalidateNativeState(widget)
```

禁止在同一热路径中一半直接 Native 写、一半依赖旧 Diff Cache，否则缓存可能无法知道外部修改。

---

### 4. 初始化状态 Prime

`rs_ui_factory.lua` 创建常用 Panel / Label / Button / EditBox / Slider 时，会把刚刚写入的初始 Text、Extent、Visibility、Anchor 等状态 Prime 给 DiffRenderer。

目的：第一次 Refresh 如果值没有变化，不应因为 Cache 为空再重复写一次 Native UI。

Prime 只描述 Presentation State，不保存业务数据。

---

### 5. Theme 同步去重

Theme 仍然是视觉 Authority，但以下函数现在本身也做状态去重并返回是否发生真实重绘：

- `Theme:SetLabelTone`
- `Theme:SetButtonActive`
- `Theme:SetEllipsis`
- `Theme:SetOpacity`
- `Theme:RefreshTypography`

因此即使尚未迁移到 `S.UI:SetLabelTone` 的旧页面，也能获得一部分重复写减少收益。

---

### 6. Widget Lifecycle

#### 6.1 为什么不是 DestroyWidget

当前已验证的 RU UI 表面没有可靠、通用、可安全调用的 Native `DestroyWidget` Contract。

因此 Framework v1 的 Release 语义是：

```text
Release Handler
    ↓
Hide Native Widget
    ↓
Clear Diff Cache
    ↓
Remove Suite logical reference
    ↓
Generation 隔离旧 Native ID
```

不能为了“代码看起来完整”猜测或调用不存在/未验证的 Destroy API。

#### 6.2 Owner Scope

Framework 提供：

```lua
local Scope = S.UI:CreateScope("module:example")
Scope:Adopt(widget, "logical_id")
Scope:Bind(widget, "OnClick", fn, "example:click")
Scope:Release()
```

以及：

```lua
S.UI:ReleaseOwner(ownerId)
```

`SafeHandler` 成功绑定后会自动登记 Handler；ManagedWindow 真正 Destroy 时会优先释放对应 Owner。

HUD 仅仅 Hide/Disable 时不能 Release Owner，因为用户可能重新打开该 HUD；Release 只用于真正的生命周期终止。

---

### 7. WindowManager

Framework v1 不新造第二套窗口布局实现。

```lua
S.UI.WindowManager:Create(spec)
```

委托现有：

```lua
S.UI:CreateManagedWindow(spec)
```

`Attach` 同理委托 `AttachManagedWindow`。

长期原则：

- Managed Dialog → ManagedWindow；
- Persistent HUD → WidgetBase + HudManager；
- Professional Domain 自有存储窗口 → AttachManagedWindow；
- 所有窗口最终通过统一 RSUI 入口使用这些 Authority。

---

### 8. UI Diagnostics

高频 UI API 不能每次调用 `Diagnostics:Count()` 或写日志，因为字符串标准化、Table 操作和日志格式化本身会制造新的热路径。

因此 UI Framework 使用内部轻量数值计数：

- Attempts
- Writes
- Skips
- NativeCalls
- ByOp
- ByOwner
- Adopted Widgets
- Handler Bindings
- Released Owners / Handlers

Diagnostics 读取 Snapshot 时才排序和格式化。开发测试需要重新计数时可显式调用：

```lua
S.UI:ResetFrameworkMetrics()
```

它只清 UI Framework 计数，不修改 Widget、业务状态或持久化数据。

诊断页现在显示：

```text
UI Framework｜Diff ... · Native写 ... · 跳过 ... · Cache ...
```

“打印全部日志”也会附带 UI Framework 摘要和 Top UI 操作。

#### 8.1 评价指标

Diff Skip Ratio 越高不一定代表 UI 越好，但在稳定画面中重复 Refresh 时：

- `SetText` 应有较高 Skip；
- `Show` 应有较高 Skip；
- `SetAnchor / SetExtent` 不应随着普通数据 Refresh 持续增长；
- 如果 NativeCalls 在窗口完全静止时仍高速增加，应继续定位调用者。

---

### 9. 第一批迁移

本阶段实际迁移：

#### Diagnostics Page

- 文本、显示、Enable、Extent、Anchor 使用 DiffRenderer；
- 新增 UI Framework Snapshot 展示。

#### Event Widget

活动悬浮窗是优先目标，因为它存在可见时的实时倒计时刷新。

已迁移：

- Row Visibility；
- Name / State / Progress Text；
- Tone；
- Pickability；
- Font Size；
- Row Extent；
- Row Anchor；
- Mini Summary。

因此每秒 Refresh 不再意味着每一行都重新调用全部 Native UI 写操作。

#### Healer Professional HUD（Phase 6 增量）

Healer 已成为第一批 Professional consumer：

- Head Marker 的 Visibility / Text / Color / Extent / Anchor / Font 使用 Diff；
- Raid Overlay 的可见性与高亮写入开始统一走 Diff；
- `SetColor` 已加入 Framework；
- 对仅暴露 `SetVisible()` 的复合 Drawable 支持统一 Visibility Diff；
- 高频 Color / Anchor 缓存使用标量字段，避免每次动画/移动创建临时缓存 table；
- Marker Geometry 依据 Shape / Size / Extra 开关缓存，镜头移动不重复执行完整 Layout。

详见 `REPLICATED_HEALER_DOMAIN_RUNTIME_v1_20260826.md`。

---

### 10. 与 `MakeSprite - too many sprite update` 的关系

Framework 不能保证该 Native Warning 一定来自 Replicated Suite，也不能掩盖游戏资源/Native UI 自身问题。

但 Suite 侧必须做到：

1. 数据没变不重复 `SetText`；
2. Visibility 没变不重复 `Show`；
3. 普通数据刷新不重复 Layout；
4. Anchor/Extent 只在 Layout/分辨率/窗口尺寸真正变化时更新；
5. 高频 HUD 的 UI 写数量可诊断。

这样可以把 Suite 自身可控的 Sprite 更新压力降到最低，并为后续 Healer 大规模 UI 优化提供统一工具。

---

### 11. 后续迁移顺序

UI Framework v1 落地后，不进行一次性全工程机械替换。

当前进度：Runtime / FrameBudget 已落地，Healer 高频 Marker / Raid Overlay 与 Health/Status Slice 已完成第一批迁移。

后续建议：

1. 完成 Healer 游戏内压力验证并继续迁移剩余低风险 UI；
2. Task / Trade / Bond 等 Built-in HUD 分批迁移；
3. Plates 已完成第一批公共 UI Metrics / Diff：Lines/Circle Active Range + Effect Slot Diff；后续继续迁移剩余 Presenter；
4. DPS 只迁移明确的 Presentation / maintenance，不影响事实采集；
5. 最后清理仍直接重复 Native UI 写的低频设置页面。

每一批迁移必须做游戏内 Reload、窗口开关、Resize、1024×768、1920×1080 以及长文本压力测试。

---

### 12. 开发硬规则

以后新 UI 默认遵循：

1. 创建控件优先 `S.UI` Factory / Components；
2. 高频刷新使用 DiffRenderer；
3. 不在 OnUpdate 中创建 Widget/Drawable；
4. 不在普通数据 Refresh 中重新 Layout；
5. 不猜测 Native Destroy/API；
6. 所有 Handler 必须进入可释放生命周期；
7. UI 不拥有业务 Authority；
8. UI 写入异常使用结构化、限频 Diagnostics；
9. 新组件必须考虑 1024×768 和 UI Scale；
10. 高频列表必须预创建 Row，再增量更新，不在循环中反复创建/删除。



<a id="sec-7"></a>
## 7. Replicated Suite UI Framework v2 — Design System Foundation

> 来源（已合并至本权威文档，原文件已收口）：`replicatedsuite\Docs\Architecture\Core\REPLICATED_SUITE_UI_FRAMEWORK_v2_DESIGN_SYSTEM_20260826.md`

## Replicated Suite UI Framework v2 — Design System Foundation

日期：2026-08-26  
状态：**已落地 / UI Framework v1 的增量上层，不替换 Diff/Lifecycle Authority**  
BuildTag：`foundation-v2-ui-design-v2`

### 1. 为什么现在做 v2

UI Framework v1 已解决最危险的底层问题：Native 写入 Diff、Widget/Handler 生命周期、WindowManager facade 与 UI Metrics。项目进入模块迁移期后，新的主要成本变成“每个页面仍然自己决定间距、字号、布局、窗口壳和设置写入语义”。

v2 的目标不是另造第二套 UI，而是在 v1 上增加统一 Design System：

```text
Domain / ViewModel
       ↓
Binding / Validation
       ↓
Components / Layout / Window Shell
       ↓
Theme Tokens
       ↓
UI Framework v1 Diff + Lifecycle
       ↓
ArcheAge RU Native UI
```

### 2. Authority 不变

- `S.UI` DiffRenderer：决定某次 Presentation 更新是否真正写 Native；
- `S.UI.Lifecycle`：拥有 Handler Release / Hide / logical reference cleanup；
- `S.UI.WindowManager`：继续委托现有 ManagedWindow / AttachManagedWindow；
- `S.Layout`：仍是屏幕安全区、Addon Scale、Placement Authority；
- `S.Theme`：仍是 Native Drawable / Typography 视觉 Authority；
- **v2 Tokens/Layout/Shell/Binding 只提供更高层语义，不接管 Domain State。**

禁止模块因为 v2 出现后重新直接维护另一份 Placement、SaveData 或 Native Widget State Cache。

### 3. Design Tokens

入口：`ui/framework/rs_ui_tokens.lua`

统一定义：

- `spacing`: xxs/xs/sm/md/lg/xl/xxl；
- `font`: caption/small/body/bodyLarge/section/title/hero；
- `size`: control/button/input/titlebar/section/footer/row/icon/hit target；
- `alpha`；
- semantic `tone`: default/muted/accent/info/success/warning/caution/danger；
- component defaults：window/card/form/grid；
- button state palette。

调用：

```lua
local T = S.UITokens
local gap = T:Number("spacing.sm", 8)
local danger = T:Color("danger")
```

Theme 已开始反向消费 Token：新旧页面继续调用 `S.Theme`，但默认字号、按钮高度、按钮状态色、语义 Tone 由 Token 统一。

**规则：新 UI 不允许在业务页面新增一套全局 spacing/font/button-height 常量。** 特殊尺寸可以局部传参，但必须说明它是业务布局例外。

### 4. Layout Primitives

入口：`ui/framework/rs_ui_layout_v2.lua`

提供：

```lua
S.UI.LayoutV2:VStack(parent, spec)
S.UI.LayoutV2:HStack(parent, spec)
S.UI.LayoutV2:Grid(parent, spec)
S.UI.LayoutV2:Form(parent, spec)
```

这些对象只计算和提交 Presentation Placement，最终仍走：

```lua
S.UI:SetAnchor(...)
S.UI:SetExtent(...)
```

所以重复 Layout Pass 中相同坐标仍由 v1 Diff 跳过 Native 写入。

旧 `CreateFormLayout():Next()` 保持兼容，并新增 `AsV2(parent)` 适配入口。旧页面无需一次性重写。

#### Layout 硬规则

1. 不在普通数据 Refresh 中无条件重新创建布局对象/Native Widget；
2. Layout 可以重复计算，但相同结果必须通过 Diff 变成 0 Native 写；
3. 屏幕 Clamp/安全区仍由 `S.Layout` 管理，LayoutV2 不复制这套逻辑；
4. 高密度动态 HUD 可以保留专门的 Presenter Layout，不强制套 Form/Grid。

### 5. Binding v2

入口：`ui/framework/rs_ui_binding_v2.lua`

统一管线：

```text
Get
 ↓
Normalize
 ↓
Validate
 ↓
Equals / Skip
 ↓
Set Domain/Settings Model
 ↓
MarkDirty / onChanged
 ↓
显式 Commit 或 autoCommit=true
```

支持：

- `normalize`
- `validate`
- `equals`
- `markDirty` / `dirtyKey`
- `onChanged`
- `commit`
- `autoCommit`
- Error state
- Binding metrics

默认 `Set(..., final=true)` **不会自动 Commit**，以保持 v1 控件合约；只有显式 `autoCommit=true` 才自动提交。

本阶段同时修复旧 `CreateNumericSettingControl` 的 Binding 调用问题：过去把 `binding.Set` 抽成普通函数后调用，会丢失 Lua method 的 `self`；现在明确使用 `options.binding:Set(...)`。

### 6. Managed Window Shell v2

入口：`ui/framework/rs_ui_shell_v2.lua`

```lua
local shell = S.UI:CreateWindowShell({
    id = "example.settings",
    title = "示例设置",
    width = 420,
    height = 520,
    resizable = true,
    footer = true,
})

local body = shell:GetContentRoot()
shell:SetStatus("已保存", "success")
shell:Show(true)
```

统一拥有：

- Header/Title；
- Close Button；
- Content Card；
- 可选 Footer/Status；
- Token spacing；
- ManagedWindow drag/placement/resize contract；
- Owner/Lifecycle；
- 全部重排写入走 Diff。

Shell **不创建新的窗口 Persistence Authority**。它只是现有 `WindowManager:Create()` 的 Composition Layer。

### 7. Composition Primitives

入口：`ui/framework/rs_ui_components_v2.lua`

第一批：

- `CreateCardV2`
- `CreateSectionV2`
- `CreateFormRowV2`

它们用于建立统一视觉语言，但保持 Native 能力保守：不假装 RU 客户端拥有未验证的圆角、模糊、CSS 或任意动画能力。

### 8. Diagnostics

`GetFrameworkSnapshot()` v2 新增 `design`：

- Token version；
- Layout passes / placements；
- Binding created/writes/skips/rejected/commits；
- WindowShell created/shown/closed/destroyed/layout passes。

诊断页与“打印全部日志”都会显示 Design System 摘要。

目标不是追求 Layout Pass 数绝对为零，而是：**静止 UI 重复 Layout 后 NativeCalls 应接近零。**

### 9. Compatibility

本阶段不进行全工程页面机械迁移：

- 原 `CreatePanel/CreateLabel/CreateButton/CreateSlider/...` 保持；
- 原 `CreateManagedWindow/AttachManagedWindow` 保持；
- 原 `CreateSettingBinding` 名称保持，现在委托 Binding v2；
- 原 `CreateFormLayout` 合约保持；
- UI Framework v1 Diff/Lifecycle 接口保持。

因此 Phase 11C Plates、Healer、DPS 和生活模块不需要因为 UI v2 立即改代码。

### 10. 后续 UI 迁移顺序

1. **Healer Settings**：作为 Form/Binding/Section 的复杂设置页样板；
2. **Plates Manager / Diagnostics**：验证 Search/List/Editor/Scroll 组合；
3. Suite Settings / Professional Pages；
4. 高频 HUD 只迁移适合的 Composition，不机械套 Settings Form；
5. 最后清理页面级重复视觉常量。

每次迁移继续执行：1024×768、1920×1080、窗口开关、拖动、Resize、长文本、ReloadAddon、UI Native 写入诊断。

### 11. 本阶段验证

- Suite Lua 全量语法检查；
- Token semantic lookup；
- VStack 坐标/使用高度；
- Binding Normalize / Reject / Dirty / Commit；
- WindowShell Create/Close/Destroy；
- WindowShell 连续相同 Layout：第二次 `NativeCalls = 0`；
- v1 Compatibility API 保持。

### 12. 文档版本关系

`REPLICATED_SUITE_UI_FRAMEWORK_v1_20260826.md` 继续保留，作为 Diff/Lifecycle 第一阶段历史与底层 Contract；本文件是当前 UI Design/Composition 的更高版本入口。发生 UI Framework 实现冲突时，以 v2 为准。



<a id="sec-8"></a>
## 8. Replicated Suite UI Framework v2 — Phase B1 Bound Fields

> 来源（已合并至本权威文档，原文件已收口）：`replicatedsuite\Docs\Architecture\Historical\REPLICATED_SUITE_UI_FRAMEWORK_v2_PHASE_B1_BOUND_FIELDS_20260826.md`

## Replicated Suite UI Framework v2 — Phase B1 Bound Fields

日期：2026-08-26  
状态：**已落地 / UI Phase B 第一批真实页面迁移**  
BuildTag：`foundation-v2-ui-phase-b1-fields`

### 1. 本阶段目标

UI Framework v2 Design System 已经拥有 Tokens、Layout、Binding、WindowShell 和基础 Composition，但真实设置页仍大量通过页面级 `AddNumericControl/AddControl` 自己拼装控件。

Phase B1 补齐中间缺失的一层：**Bound Field Composition**。

```text
Healer Settings Presenter
        ↓
Settings Model Preview / Validate
        ↓
BindingV2
        ↓
Toggle / Choice / Numeric Bound Field
        ↓
Responsive LayoutV2
        ↓
UI Framework v1 Diff / Lifecycle
        ↓
ArcheAge RU Native UI
```

第一套真实样板是 Healer Settings 的“常用”页。它只迁移 Presentation，不改变 Healer 推荐、团队扫描、Buff 扫描、100 人分片或 Persistence 语义。

### 2. Authority 边界

#### 2.1 Domain / Persistence Authority 不变

Healer 设置最终写入仍必须经过 `Feature.Commands`（V3 契约，见 [`HEALER_ARCHITECTURE.md`](HEALER_ARCHITECTURE.md)）：

```text
UI Field
  → BindingV2
  → Feature.Commands:SetSetting()
  → Store Normalize/MarkDirty
  → Persistence Dirty + Debounce
```

Bound Field 不能直接写 `Store.State`、`SaveData` 或绕过能力门。旧 `ReplicatedHealerModule` 已删除。

#### 2.2 Preview 不等于 Commit

新增：

```lua
Feature.Commands:PreviewSetting(key, value)
```

Preview 复用 Settings Model 的真实规格与耦合阈值规则，但：

- 不修改 Healer state；
- 不触发 Native UI；
- 不触发 SaveState；
- 不污染正式 settingCoercions / settingRejects 计数。

最终 `SetSuiteSetting()` 仍再次执行正式 Coerce，Domain Authority 没有下放给 UI。

### 3. BindingV2 2.1

`rs_ui_binding_v2.lua` 升级到 2.1。

新增/强化：

- `Get()` 读取计数；
- Normalize / Validate 错误状态；
- `SetError()` / `GetError()`；
- `Refresh()`；
- revision；
- dirty 状态；
- skipped/rejected/error/commit metrics；
- `Describe()`；
- callback 异常隔离与 Diagnostics 报告。

默认行为仍保持：

```text
Set(final=true) != 自动 Commit
```

只有显式 `autoCommit=true` 或组件明确调用 `Commit()` 才执行 Binding commit，以保证旧 API 兼容。

### 4. Bound Field 组件

`rs_ui_components_v2.lua` 升级到 2.1，新增：

```lua
S.UI:CreateToggleFieldV2(parent, id, spec)
S.UI:CreateChoiceFieldV2(parent, id, spec)
S.UI:CreateNumericFieldV2(parent, id, spec)
S.UI.ComponentsV2:LayoutFieldGrid(parent, fields, spec)
```

每个 Field 统一拥有：

- label；
- control；
- validation/status feedback；
- enabled/alpha 状态；
- Diff Render；
- Layout；
- Binding 错误反馈；
- 组件级 Diagnostics metrics。

#### 4.1 Numeric Field

Numeric Field 支持：

- minus / plus；
- horizontal slider；
- edit box；
- min/max/step；
- integer；
- unit/suffix；
- normalize；
- validation feedback。

最重要的写入规则：

```text
Slider dragging (final=false)
    → 只 Preview UI
    → 0 Domain writes
    → 0 Persistence dirty writes

Slider release (final=true)
    → Binding Set
    → Presenter / Settings Model
    → Domain write once
    → Persistence Dirty + Debounce
```

因此不会因为 50 ms 拖动采样把 SaveState/Dirty 链路变成热路径。

#### 4.2 Choice Field

Choice Field 使用明确的 `{value, label}` 列表，不再用页面自己猜枚举范围。

Healer 样板已按 Settings Model 实际范围使用：

- `healthCurveMode`: 1–2；
- `healthAccelMode`: 1–3；
- `distanceCurveMode`: 1–2。

这修复了旧“常用”页曾用同一个 `{1,2,3,4}` 循环三个枚举、再依赖 Model 回夹的 UI 语义问题。

### 5. Responsive LayoutV2 2.1

新增：

```lua
LayoutV2:ResolveResponsiveColumns(availableWidth, spec)
LayoutV2:ResponsiveGrid(parent, spec)
```

它只负责纯布局数学，不复制 `S.Layout` 的屏幕安全区 Authority。

样板页规则：

- 可用宽度不足时自动 1 列；
- 宽度足够时自动 2 列；
- cell width 由实际剩余空间计算；
- 相同 Layout Pass 仍通过 v1 Diff 跳过重复 Native Anchor/Extent 写入。

Healer 常用页当前使用：

```text
minCellWidth = 250 × addonScale
maxColumns   = 2
fieldHeight  = 52 × addonScale
```

目标是在 1024×768 保持紧凑可用，同时避免高分辨率下控件无限横向拉散。

### 6. Design Tokens 扩展

`component.form` 新增：

```text
fieldH
compactFieldH
feedbackW
```

业务页不再为 Bound Field 自己创建另一套全局高度/反馈宽度常量。

### 7. Healer Settings 第一批迁移

迁移范围仅为：

```text
Healer Settings → 常用
```

当前 14 个 Bound Fields：

```text
Numeric × 10
Toggle  × 1
Choice  × 3
```

包括最大治疗距离、进入/退出候选血量、自己/紧急/低血量阈值、Health/Buff 扫描间隔、候选保持、评分领先切换、治疗范围底色以及三种曲线模式。

未迁移的救援评分、颜色、BUFF 条件组、团队显示、职责覆盖、校准等继续使用现有成熟 UI，避免一次性大范围改写。

### 8. Diagnostics

`GetFrameworkSnapshot().design` 现在增加：

```text
layout.responsive
components.version
components.created
components.renders
components.layouts
components.validationErrors
```

Diagnostics 页面与完整诊断报告会显示：

- Responsive Layout 次数；
- Bound Field 创建/渲染；
- Validation Error；
- 原有 Binding write/reject/commit；
- Shell metrics。

Validation Error 只在错误状态发生变化时累加，不会因同一错误重复 Render 无限刷计数。

### 9. 性能 Contract

Phase B1 明确禁止：

- Slider drag 每 50 ms 写 Domain；
- Slider drag 每 50 ms SaveData；
- Field Render 重建 Native Widget；
- 静止页面每次 Refresh 无条件写 Text/Anchor/Extent；
- 为响应式布局另建第二套 Window/Placement Authority；
- 为“高级 UI”增加持续动画或 Tick Alpha 写入。

允许 Layout 重算；**要求相同结果由 Diff 转换成 0 Native writes。**

### 10. Compatibility

保留：

- `CreateSettingBinding()`；
- `CreateFormLayout()`；
- `CreateNumericSettingControl()`；
- `CreateManagedWindow()`；
- 所有 UI Framework v1 Diff/Lifecycle API；
- 尚未迁移的 Professional Pages。

Phase B1 是增量能力，不要求旧模块立即机械迁移。

### 11. 本阶段验证

源码 / Mock 已验证：

```text
Suite Lua：153
语法失败：0

Responsive 500px：1 列
Responsive 520px：2 列
Slider preview：0 Domain writes
Slider final：1 Domain write
相同 Field Render + Layout 第二次：0 Native writes
Binding reject / error state：PASS
```

还需 ArcheRage RU 游戏内实测：

- 1024×768 实际窗口内容宽度与 2 列落点；
- 自定义 Horizontal Slider 拖动/释放；
- EditBox Enter/LostFocus；
- 长中文标签；
- ReloadAddon 后设置持久化；
- Healer 页面切 Tab 后 Widget 可见性；
- 1920×1080 / 2K 的视觉密度。

### 12. 下一步

Phase B2 推荐继续迁移 Healer Settings 的：

```text
救援评分
团队显示
职责覆盖
```

同时补齐：

```text
Bound Section / Group
Field-level disabled reason
统一 Footer / Dirty / Saved 状态投影
```

颜色编辑器和 BUFF Collection Editor 不应硬塞进普通 Field；它们应等待 UI Phase D 的 CollectionEditor / InspectorPanel 抽象。



<a id="sec-9"></a>
## 9. Replicated Suite Engineering

> 来源（已合并至本权威文档，原文件已收口）：`replicatedsuite\Docs\Architecture\Core\REPLICATED_SUITE_ENGINEERING_SKILL.md`

---
name: replicated-suite-engineering
description: Engineering baseline for the user's ArcheRage RU Replicated Suite project. Use when continuing development, refactoring multiple Replicated addons into one Suite, changing shared UI/HUD behavior, modifying DPS/Healer/Gear/Plates architecture, handling 200-player performance, API capability changes, migrations, diagnostics, or release behavior.
---

## Replicated Suite Engineering

> Baseline revision: v1.1 (2026-08-15) — includes DPS Team/Range scope policies.

### Mandatory startup

When this skill is used for a new page or continuation:

1. Read all reference documents in this skill:
   - `references/PRODUCT_ARCHITECTURE.md`
   - `references/UI_HUD_SPEC.md`
   - `references/RUNTIME_DATA_API.md`
2. Inspect the newest full Addon package supplied by the user.
3. If API work is relevant, inspect the newest supplied `z_api_functions` / official API package.
4. Treat the uploaded current Addon as implementation truth.
5. Treat the reference documents as product/architecture constraints.
6. Never assume that a target architecture described in the documents is already implemented.

### Project context

- Game: ArcheAge / ArcheRage RU private server.
- User runs a Chinese client.
- Public project brand: Replicated Suite.
- User's public author/character identifier: Replicated.
- Public product target: one Addon entry, internally modular.
- Existing major systems include DPS, Healer, Gear, Plates, activities, Buff tracking, bonds, trade/cargo, fishing and resources.
- The project has a real user base; compatibility, migration, diagnostics and quiet defaults matter.
- ArcheRage large-scale runtime must treat ~200 players within observable range as a normal workload, not an exotic benchmark.

### Product decisions are frozen unless user changes them

#### One public addon

The end state is one public:

```text
Replicated Suite
```

Do not keep a long-term architecture where players must enable many Replicated addons separately.

Do not build a monolithic mega-core. Keep Modules isolated.

#### Authority

Suite owns:

- Module lifecycle
- shared settings navigation
- HUD visibility authority
- common infrastructure

Each Module owns its Domain.

Never move DPS/Healer/Gear/Plates mutable Domain State into a global Suite state bag.

#### Module disable

Disabling a Module must stop its business runtime as much as practical.

Disable must not clear accumulated data or delete user configuration.

Clear/reset is a separate explicit action.

#### Quiet defaults

Fresh install:

- only minimal Suite entry should normally appear
- base Suite life/activity capabilities may be enabled
- long-lived HUDs default hidden
- professional modules default disabled
- new modules introduced by updates default disabled

#### Home page

Preserve the current useful life/dashboard style.

Use left-side categorized navigation plus user-customizable favorites.

Allow a configurable default start page.

### HUD hard rules

Read `UI_HUD_SPEC.md` before changing shared HUD behavior.

Critical rules:

- Long-lived HUDs have no `×` close button.
- Keep unified `- / +` collapse/restore.
- Collapsed state persists across restart.
- Hiding is controlled by Suite/HUD management.
- Module Enabled, HUD Visible and Expanded/Collapsed are separate.
- Title bars may be hidden; editing mode temporarily restores them.
- Title buttons use global defaults plus per-HUD override.
- Only show controls the HUD actually supports.
- Resize is handled through HUD edit mode.
- Locked HUD behavior must be respected.
- Provide temporary unlock-all in edit mode.
- Support per-HUD mouse-through behavior.
- Editing is allowed in combat unless a concrete client/API restriction is proven.
- Do not impose large content-driven minimum sizes.
- Keep only a tiny technical safety minimum.
- Users may intentionally make HUDs extremely small.
- Cropping/crowding/overlap is acceptable for deliberately extreme sizes.
- Do not automatically hide important business fields to make small layouts look clean.
- Prefer keyword-preserving short labels over `...`.
- Normal recommended sizes must not show accidental ellipsis.
- Font size and window size are independent.
- Background alpha must not fade text when only the background is changed.
- Global defaults + per-HUD inheritance apply to font/background/compact preferences.
- Manual size overrides auto-size until the user explicitly re-enables auto-size.
- Support HUD layout profiles.
- HUD layout profiles do not control Module Enabled.

### Text overflow rules

This is a recurring project bug and must be actively checked.

During every UI change:

1. Test Chinese, English and Russian long strings.
2. Inspect labels, buttons, tabs, table columns and HUD titles for unintended `...`.
3. Prefer:
   - shorter meaningful labels
   - module-provided short names
   - compact numbers
   - compact time
   - flexible column allocation
4. In tables, protect important numeric columns before long names.
5. Long names may be cropped only when space is genuinely constrained; hover/detail should preserve the full value where practical.
6. Accidental ellipsis at normal size is a release blocker.

### Healer scope

Remove the independent ranked “players needing healing” HUD and unnecessary rank computation if no other consumer needs it.

Keep useful direct assistance such as:

- party/raid frame highlighting
- health rules
- Buff/Debuff rules
- color states
- distance/urgency conditions

Do not reintroduce a ranked healing list unless the user explicitly asks.

### Settings UX

Use:

- Common
- Appearance
- Advanced
- Diagnostics

Provide global settings search.

Closed modules remain configurable.

Runtime-dependent action buttons may be disabled while the module is off.

### HUD and function profiles

Keep separate:

#### HUD Layout Profile

Stores UI state:

- position
- size
- font
- background
- title state
- Visible
- Expanded/Collapsed

Does not store Module Enabled.

#### Function Profile

Stores Module Enabled states.

#### Combined Shortcut

The user may explicitly bind one function profile and one HUD profile into a one-click scenario shortcut such as:

```text
大型团战
生活
跑商
```

Never auto-link them without explicit user configuration.

### Character/account scope

Use account defaults plus character overrides.

Let each module declare scope.

Examples:

- theme/global font: account
- gear profile: character
- class-specific healer rules: character
- HUD layout: account default with optional character override

### Diagnostics and fault isolation

A failing Module must not crash the whole Suite.

On module startup/runtime failure:

- safely disable that module if needed
- stop repeated error spam
- keep other modules alive
- record module/stage/error context
- allow retry where safe

Release builds should not spam chat.

Default visible logs: only user-actionable errors/warnings.

Diagnostics page may expose:

- Off
- Error
- Warning
- Debug
- Verbose

Provide module-level and full Suite diagnostic summaries while filtering unrelated/private data.

### Dangerous actions

Classify risk.

High-risk operations such as:

- clear all DPS data
- reset whole Suite
- delete all Gear profiles

require explicit confirmation.

Create a temporary recoverable backup first when technically feasible.

### Large-scale runtime

Read `RUNTIME_DATA_API.md` before touching DPS/Plates/Healer shared observation or high-frequency runtime.

#### 200 players is normal

Do not design around a hard `MAX_ACTORS = 200`.

There may also be NPCs, summons, pets, vehicles and unknown actors.

#### Shared observation, separate domain

Use a shared observation layer to avoid every module rescanning all 200 units.

Observation may cache basic game facts.

DPS/Healer/Plates still own their own business interpretation.

#### Subscription-driven data

Do not query expensive Healer/Plates/Buff data when those modules are disabled.

#### Priority

Under load:

1. raw combat/key events
2. authoritative Domain accumulation
3. identity/business interpretation
4. ranking/detail projection
5. HUD refresh
6. diagnostics/cosmetic work

Prefer delayed UI over lost/incorrect combat facts.

### DPS data scope modes

DPS has two explicit scope policies:

```text
Team mode
Range mode
```

Do not implement them as two separate DPS systems.

Shared pipeline:

```text
Combat Event
→ Event Fact
→ Identity / Relation Resolution
→ Scope Policy
→ PVP/PVE Classification
→ Stats Domain
```

#### Team mode

Formal ranking actors are:

```text
SELF + TEAM
```

Team/raid membership is authoritative.

Non-team units may still exist as `ContextOnly` for:
- PVP/PVE classification
- boss/target identification
- damage-taken source details
- skill/target/source relationships

Do not promote those Context actors into the full ranking by default.

When Team mode is active, stop or greatly reduce full-range world scanning. Focus on:
- roster
- combat-event context actors
- current target / necessary hotspots
- low-frequency roster reconciliation

If no team exists, SELF remains a formal actor.

#### Range mode

Range mode tries to formally track every relevant observable actor:
- SELF
- TEAM
- friendly players outside the team
- hostile players
- NPCs/Bosses
- summons/pets/vehicles when identifiable
- resolved Unknown actors

TEAM remains a strong identity anchor inside Range mode.

Range mode may enable:
- shared World Observation
- broader actor cache
- hot-actor queries
- Unknown resolver
- existing relation inference/manual correction logic

Current product default is Range mode to preserve the project's established “all observable units” goal.

#### Switching modes

Switching Team ↔ Range:
- must not clear existing statistics
- must not silently reinterpret missing history
- affects subsequent event admission / observation behavior
- should show a short confirmation
- clearing remains a separate explicit user action

Do not fabricate pre-switch Range data that was never observed.

#### Diagnostics

Useful diagnostics:
- ScopeMode
- TeamRosterCount
- ObservedActorCount
- ResolvedActorCount
- UnresolvedActorCount
- ObservationBacklog

Do not expose internal confidence formulas to normal users.


### DPS non-regression

Accuracy is more important than immediate UI freshness.

Per-event PVP/PVE classification is mandatory.

Example:

```text
Player1 -> Player2 = PVP
Player1 -> NPC1    = PVE
```

Never classify an entire actor permanently into one panel.

Preserve other verified DPS semantics when touching them, including manual correction, clear behavior and Boss cumulative history.

### Unknown actor handling

Large battles may produce combat facts where the API cannot currently identify source/target.

Do not:

- drop these events
- merge every unknown source into one permanent actor

Direction:

- preserve Event Facts
- assign separate temporary ActorKeys where possible
- allow later identity resolution
- reproject history when identity becomes known
- expose unresolved totals to UI in a readable aggregated form if needed

The exact resolver evidence is NOT a product decision. Verify it technically.

### API governance

Do not trust the current bundled `z_api_functions` as timeless truth.

ArcheRage RU may open, close, re-open, restrict or remove API functions.

Before relying on an API in architecture:

1. inspect the user's latest bundled API
2. compare official RU update information when necessary
3. inspect current addon code usage
4. use runtime evidence where safe
5. record capability state centrally

Move toward a capability registry rather than scattered per-module guesses.

Potential states include:

- OfficialEnabled
- OfficialDisabled
- Removed
- RuntimeVerified
- RuntimeFailed
- CombatRestricted
- CooldownLimited
- CrashRisk
- Unknown

Do not auto-probe side-effectful APIs at startup.

### Technical decisions the user should not be asked to choose blindly

Do not ask the user to choose:

- cache TTL without evidence
- dedup fingerprint thresholds
- identity confidence weights
- event retention windows
- queue budgets
- API capability truth
- summon owner resolution technique

Investigate these from:

- official API
- current source
- other DPS implementations the user supplies
- actual runtime sampling

Only ask the user when a technical limitation changes visible product behavior.

### Release/migration

For the final consolidated Suite release:

- the user plans to tell users to remove obsolete standalone Replicated addons
- do not build a long-term dual-runtime coexistence layer

Old settings migration may be attempted as a separate technical task if safe.

Do not keep old runtime architecture alive solely to preserve migration.

Private-only modules must never enter the public release.

### Default refactor order

1. Freeze behavior and create acceptance checklists.
2. Build Common contracts, Module Manager, HUD Manager and Diagnostics foundations.
3. Migrate Suite-native modules.
4. Migrate Gear.
5. Migrate Plates.
6. Migrate Healer.
7. Migrate DPS peripheral UI/integration/storage.
8. Split DPS runtime/domain gradually.
9. Remove duplicated bridges/frameworks last.

Do not start with a wholesale DPS rewrite.

### New-page workflow

When continuing in a new chat:

1. Read this skill and all references.
2. Inspect the newest full Addon zip.
3. Identify which target architecture pieces are already implemented versus still planned.
4. Inspect the exact files touched by the requested feature.
5. Preserve verified current behavior unless explicitly targeted.
6. Prefer incremental migration and compatibility adapters.
7. Verify load paths, initialization order, handlers, persistence and UI.
8. Check long-text overflow on every changed UI.
9. Check Module Enabled vs HUD Visible semantics.
10. Check that disabled modules stop unnecessary runtime.
11. Run syntax/static checks on modified Lua files where possible.
12. Return the exact file/package format requested by the user.

### Review checklist

Before finishing any shared architectural change, ask internally:

- Did Suite accidentally gain a module's Domain Authority?
- Did a disabled module continue high-frequency work?
- Did Disable clear data?
- Did HUD close buttons reappear?
- Did collapse/restore become confused with hide/disable?
- Did a large minWidth/minHeight reappear?
- Did responsive layout hide business fields?
- Did accidental `...` appear at normal size?
- Did font resizing become coupled to window resizing?
- Did background alpha fade text?
- Did a new module become enabled by default?
- Did a migration re-enable an explicitly disabled setting?
- Did one module error threaten the whole Suite?
- Did shared observation become a global writable business state?
- Did a performance optimization reduce DPS accuracy?
- Did Team mode accidentally keep full-range high-frequency observation enabled?
- Did Team mode promote non-team Context actors into the formal ranking?
- Did Range mode stop treating TEAM as authoritative evidence?
- Did a Team/Range mode switch clear or fabricate historical statistics?
- Did Team and Range modes fork into duplicated DPS business pipelines?
- Did unverified API assumptions enter critical code?
- Did private functionality leak into the public package?

### Documentation maintenance

If the user changes a frozen product rule:

1. update the relevant reference document
2. update this skill if the rule is repeated here
3. record the change date/version
4. do not leave contradictory old guidance in place



<a id="sec-10"></a>
## 10. Replicated Suite Architecture v1.1 Amendment

> 来源（已合并至本权威文档，原文件已收口）：`replicatedsuite\Docs\Architecture\Core\ARCHITECTURE_CHANGELOG_v1.1.md`

## Replicated Suite Architecture v1.1 Amendment

日期：2026-08-15

### DPS 数据范围模式

- 新增“团队模式 / 范围模式”。
- 团队模式正式统计 `SELF + TEAM`，非团队 Actor 仅作为必要 Context。
- 范围模式继续识别团队外友军、敌军、NPC、召唤物和 Unknown，TEAM 仍是强 Authority。
- 团队模式必须停止或显著收缩 100m 全范围扫描。
- 范围模式才启用完整 World Observation / Unknown Resolver。
- 两种模式共享 Event Fact、PVP/PVE、Stats Domain、Boss、Detail、人工纠错等同一业务管线。
- 切换模式不清空历史统计，不伪造切换前未采集的数据。
- 默认范围模式，以保持当前 Replicated DPS 的产品目标。




<a id="sec-11"></a>
## 11. Shared Runtime Foundation v1

> 2026-08-28 · M1.14.2

### 11.1 Demand

`core/rs_demand.lua` 统一 Consumer Reference Counting。业务/Service 只声明 reconcile；底层负责 token 幂等、Options 更新、计数投影和失败反向回滚。禁止 Feature 再自行复制 `consumers + consumerCount + first/last consumer` 状态机。

### 11.2 RefreshCoordinator

`core/rs_refresh_coordinator.lua` 统一有限事件的 debounce/coalesce，并严格复用单一 Scheduler。Identity 使用 `owner + stable key`；不得把每次新建的 callback closure 当作 Authority。

### 11.3 RuntimeScope 扩展

`S.Reuse.OwnerScope.Release()` 除 Event/Scheduler/Observation 外，会取消 RefreshCoordinator owner pending work。Runtime Stop 同时清空 RefreshCoordinator 与 Demand，Bootstrap 新 Generation 清空对应 Lua Authority 和 `S.Features`，避免热重载跨代引用。

### 11.3.1 M1.15.2H Shutdown / Preference Hardening

- Demand v2 的 Runtime Shutdown 按创建顺序逆序释放；普通 reconcile 失败时调用可选 `quiesce` 做 best-effort Native/Service 静默，再清除逻辑 Consumer 投影。ForceQuiesce 不是业务事务成功，而是 Shutdown 的最后安全边界，失败必须进入 Diagnostics。
- Demand owner 只能拿 Consumer Snapshot/Query，不能持有 Authority 内部 consumer table 引用。
- Feature preference 是 lifecycle + persistence 的一个事务：写保护必须在 Enable/Disable 前 fail-closed；MarkDirty 失败必须恢复旧 preference 与旧 lifecycle。
- Combat 这类 Native 高频入口禁止执行持久化和 Presentation；callback 内只做 bounded fact capture/queue。

### 11.4 性能硬约束

- Demand / Refresh 不新增 Tick。
- 高频事实共享优先走有界缓存和按需 Consumer。
- 缓存必须表达 coverage/可靠性，禁止浅缓存冒充完整数据。
- Capability Gate 应在合理的 lane/batch 边界做一次；已通过 Gate 的热循环使用受保护低级调用，避免重复 Registry 成本。


### M1.16.0 Events v3 Optional Native Event

Core Events 在 v2 required RegisterEvent 事务上增加 Optional Native Event：增强事件失败不阻断 Foundation，但进入 `optionalRegisterFailures/optionalUnavailable` 健康状态。Required listener 只有 Native 注册成功后才提交；Topic required/optional 分类由当前已提交 listener 集合重新计算，避免失败的 Required 尝试污染已有 Optional Topic。业务代码不得用 `a and optionalCall() or requiredCall()` 模拟事务分支。
