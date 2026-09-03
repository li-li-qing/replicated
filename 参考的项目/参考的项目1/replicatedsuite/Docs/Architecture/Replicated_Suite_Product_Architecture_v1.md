# Replicated Suite 产品与模块架构规范 v1.1

> 日期：2026-08-15  
> 状态：**产品侧正式基线**  
> v1.1：新增 DPS 团队模式 / 范围模式  
> 适用范围：Replicated Suite 公共发行版及其内部所有公开模块。  
> 说明：本规范冻结的是产品行为、模块边界、用户体验和迁移原则。底层 API 可用性、Unknown 身份恢复证据等技术细节仍必须以 RU 服官方 API、当前代码和实测为准。

---

# 1. 最终产品目标

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

# 2. Authority 规则

合并为单 Addon 后，Authority 仍然必须严格区分。

## 2.1 Suite Authority

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

## 2.2 Module Domain Authority

各 Module 自己拥有业务 Authority。

### DPS

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

### Healer

负责：

- 治疗条件
- 团队成员健康 / Buff 规则
- 高亮状态
- 治疗辅助业务判断

### Gear

负责：

- Gear Profile
- 当前方案
- 换装事务
- 装备状态机

### Plates

负责：

- Plate 相关状态
- Buff / Debuff Tracking
- 可见单位对应 Plate 业务信息

其它 Module 同理。

---

# 3. Module Manager

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

## 3.1 生命周期

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

## 3.2 Disable 的正式语义

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

## 3.3 Disable 不等于 Clear

模块关闭时：

- **不清空 DPS**
- **不删除 Gear 方案**
- **不删除 Tracking**
- **不重置 HUD 布局**

清空数据必须是独立、明确的操作。

---

# 4. 新安装默认策略

目标：**Quiet by Default**。

第一次安装后，屏幕上原则上只出现 Replicated Suite 的统一入口。

## 4.1 默认启用

Suite 原本的基础生活 / 活动能力可以默认启用，例如：

- 活动
- 债券
- 跑商
- 日常
- 资源统计

但其长期 HUD 默认隐藏。

## 4.2 默认关闭

专业模块默认关闭，例如：

- DPS
- Gear
- Healer
- Plates
- 专业 Buff Tracking
- 未来高频扫描模块

## 4.3 新增模块

版本升级新增模块时：

- 默认关闭
- 首页提供非打扰的“新增功能”提示
- 用户看过后消失
- 不强制弹窗
- 不自动往屏幕增加 HUD

---

# 5. Suite 首页与导航

Suite 主界面采用：

> **左侧分类导航 + 生活综合 Dashboard 首页 + 自定义常用入口**

## 5.1 首页

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

## 5.2 左侧导航

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

## 5.3 常用入口

用户可将页面 / 模块 / HUD 管理入口标记为常用。

规则：

- 使用星标或等价操作加入 / 移除
- 支持排序
- 首页常用区只显示用户自己加入的内容
- 新模块不得偷偷进入常用区

## 5.4 默认启动页

用户可选择：

- 生活首页
- 战斗
- 活动
- 模块管理
- 上次打开页面
- 其它已注册页面

默认仍以现有生活综合首页为优先。

---

# 6. Module Enabled 与 HUD Visible 必须分离

统一状态必须区分：

```text
Module Enabled
HUD Visible
HUD DisplayState
```

不能把三者混为一个布尔值。

## 6.1 Module Enabled

控制业务 Runtime 是否运行。

## 6.2 HUD Visible

控制 HUD 是否参与显示。

## 6.3 DisplayState

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

# 7. 多 HUD Module

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

# 8. 专业模块首次启用

生活 / 活动基础模块不需要打扰用户。

专业模块第一次启用时，可以显示一次极简说明。

例如：

```text
DPS 已启用。
排名 HUD 当前未显示，可在 HUD 管理中开启。
```

不同 Module 的首次 HUD 行为由 Module Descriptor 声明，而不是散落硬编码。

---

# 9. DPS 数据范围

DPS 设置提供：

```text
数据范围
● 团队模式
○ 范围模式
```

## 9.1 团队模式

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

## 9.2 范围模式

适合开放世界、世界 Boss、大规模 PVP，以及需要统计团队外友军 / 敌军 / NPC 的玩家。

范围模式尝试统计：
- SELF / TEAM
- 团队外友军
- 敌军玩家
- NPC / Boss
- 召唤物等已确认实体
- 后续解析成功的 Unknown

范围模式仍把 TEAM 当作高可靠 Authority；其它 Actor 再使用 API、战斗关系、辅助证据和人工纠错判断。

## 9.3 默认

为了保持现有 Replicated DPS “尽可能统计所有可见单位”的产品目标：

```text
默认：范围模式
```

已有用户配置优先保留。

## 9.4 模式切换

团队模式 / 范围模式切换：
- 不自动清空统计
- 不伪造切换前未采集的数据
- 只影响后续事件的采集与正式 Actor Admission

如用户希望得到一份纯团队 / 纯范围统计，应由用户显式清空。

---

# 10. Healer 产品范围修正

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

# 11. 设置体系

复杂模块的设置不能全部平铺。

统一层级：

```text
常用
外观
高级
诊断
```

## 10.1 设置搜索

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

## 10.2 关闭模块后仍可配置

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

# 12. 功能方案

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

# 13. 组合快捷方式

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

# 14. 多角色 / Account Scope

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

# 15. 危险操作

根据风险分级。

## 普通

例如：

- 恢复单个 HUD 位置
- 恢复字体
- 恢复背景

直接执行。

## 中风险

例如：

- 删除一个布局方案
- 删除某个自定义方案

简短确认。

## 高风险

例如：

- 清空全部 DPS
- 删除全部 Gear 方案
- 重置整个 Suite
- 恢复所有 Module 默认设置

必须明确二次确认。

如果可以自动备份，则高风险操作执行前优先创建临时恢复点。

---

# 16. 故障隔离

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

# 17. 日志与诊断

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

# 18. 一键诊断摘要

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

# 19. 更新提示

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

# 20. 旧 Addon 迁移策略

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

# 21. 私人模块

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

# 22. 重构顺序

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

# 23. 不允许的伪重构

以下不算重构完成：

## 只拆文件

```text
9554行 core.lua
→ 20个文件
```

如果 Authority 和 State 仍混乱，不算完成。

## 超级 Core

禁止：

```text
SuiteCore.lua 30000行
```

## 全局可写 State

禁止：

```text
ReplicatedGlobalState
```

让所有 Module 任意互改。

---

# 24. 产品侧硬规则

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
