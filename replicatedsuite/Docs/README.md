# Replicated Suite — 项目背景与框架

> **这是本仓库唯一的文档。** 刻意只保留一份：前半是背景，后半是框架。
> 目的：让维护者在**定位问题之前**能在一处读完"这是什么、怎么组织、有哪些坑"，而不是在十几份文档里翻找。

---

## 0. 工作流程（固定四步）

1. **读本文的背景信息**（§一、§二、§五 是定位问题的关键）
2. **定位问题**（读真实代码/日志，不靠印象；禁止凭文件名或历史聊天猜）
3. **修复问题**（改代码 + 写中文维护注释）
4. **交给用户实测并反馈**（本地门禁只证明契约，不证明 RU 实机行为）

> 修复过程中**不需要**同步更新文档与版本号——那是负担，不是产出。

---

## 一、背景

### 1.1 这是什么

Replicated Suite 是 **ArcheRage RU**（`ru.archerage.to`，ArcheAge 俄语客户端私服）的一个综合辅助 Addon。

- 客户端 addon 目录：`C:\ArcheRage\Documents\Addon`
- 引擎按 **目录树 + `toc.g`** 加载：**没有** `require` / `dofile` / `loadfile`
- 每个 `.lua` 文件在**顶层自行注册**（如 `S.Services.Alerts = {...}`），加载顺序由 `toc.g` 决定
- 因此：**不要凭文件名猜"孤儿文件"**——在 `toc.g` 上就是运行时责任；磁盘上有但 `toc.g` 没有的 `.lua` 是死文件
- 工程目标语言是 **Lua 5.1**（本机可能只有 5.4，见 §六）

外部参考仓库：`github.com/belovres/ArcheRage-addons`（第三方 addon 集合，仅作参考，**永不复制进本工程**）。

### 1.2 仓库结构与边界

| 目录 | 性质 |
|---|---|
| `replicatedsuite/` | **唯一运行时 Addon**，`toc.g` 只加载这里 |
| `z_api_functions/` | 开发期 API 参考/证据库，**不进 `toc.g`、不进运行时** |
| `参考的项目/` | 外部参考（只提供产品行为证据，**不提供实现**） |
| `wiki检索工具/` | 本地检索工具，与运行时无关 |

**旧版（Legacy / Professional）源码与 `globals/` 已全部物理删除**，插件树内绝不重新引入。

### 1.3 技术栈约束

- Lua **5.1** 语义（`unpack`、`table.getn` 等）；本机若只有 5.4，`tools/rs_lua_runner.py` 已在共享层用 `LUA_INIT` 注入幂等垫片
- `luac -p` 只作语法门禁，不能替代 RU 运行时
- RU 只有**有限的原生 UI/游戏 API**，所有能力必须按 `core/rs_api_capabilities.lua` 登记并经受能力门调用

---

## 二、框架总览

### 2.1 分层与依赖方向

```text
V3 Application Shell / Router / PageHost / WidgetHost / ModalHost
                         │
                         ▼
             Presentation / RSUI Consumers
                         │
                         ▼
           Feature Projection + Commands Facade
                         │
                         ▼
          Feature Domain / Authority / Store
                         │
                         ▼
              Shared V3 Services
                         │
                         ▼
 Demand / Scheduler / Events / Observation / Persistence / Diagnostics
                         │
                         ▼
       Native Contract / Imports / Object Factory / Write Fence
```

**依赖只能沿受控方向向下。** 明确禁止：

- Presentation 直接读 `Feature.State`、Store 私有字段或 Service 私有缓存
- Presentation 直接执行业务 Native 写操作
- Domain / Service 直接控制 Page / Widget / Modal 可见性
- Feature 之间直接互相调用形成强耦合（共享事实应进 Service / EventBus）
- 为了 UI 便利复制第二份业务 Authority

### 2.2 各层职责速查

| 层 | 目录 | 职责 |
|---|---|---|
| Core / Runtime Foundation | `core/` | 启动编排、Demand、Scheduler、Events、Persistence、API 能力门、Diagnostics、Foundation Gate |
| Native Foundation | `native/` | 原生对象/API 的唯一治理层：Contract、Imports、Object Factory、Capabilities、Recovery |
| Shared Services | `services/` | 跨 Feature 共享事实（见 §3.3） |
| Feature | `features/` | 独立启停的业务垂直切片：Store + Domain + Projection + Commands + Demand |
| Presentation / RSUI | `presentation/`, `ui/` | V3 Shell / Router / PageHost / WidgetHost + RSUI UI 基础层 |
| 静态数据 | `data/` | 已封存的静态 ID 表（运行期只读） |
| 开发工具 | `tools/` | 门禁与 Harness，**不进运行时** |

---

## 三、分层详述

### 3.1 Core / Runtime Foundation

`core/` 提供跨功能共享但不含业务结论的基础能力：

- `rs_runtime.lua` — 统一启动/停止与运行阶段编排
- `rs_demand.lua` — Consumer Lease / Demand 生命周期
- `rs_scheduler.lua` — 共享调度与 one-shot / 周期任务
- `rs_events.lua` — Native 事件桥与 Suite 内事件分发
- `rs_observation.lua` — 按需 Observation 基础设施
- `rs_persistence.lua` — Store / Lifetime / Dirty / Write Fence / Integrity
- `rs_api.lua` / `rs_api_capabilities.lua` — Runtime API 调用与能力门
- `rs_diagnostics.lua` — 结构化诊断
- `rs_foundation_gate.lua` — 封包级架构回归门禁

**Core 不承载 DPS、治疗推荐、跑商利润、团队判定等业务事实。**

### 3.2 Native Foundation

`native/` 是所有原生对象、能力导入和写入边界的唯一治理层：

- `rs_native_contract.lua` — API / Object / Event 身份契约（**只在迁移后的 Feature 真正需要、且客户端契约已验证时才加条目**）
- `rs_native_imports.lua` — `ADDON:ImportAPI` / `ImportObject` 的唯一 Authority（Foundation 只导入最小集合，Feature 惰性获取业务 API）
- `rs_native_object_factory.lua` — 唯一的裸 Widget 构造边界
- `rs_native_esc_bridge.lua` — generation-local 幂等 Proxy，只拥有 transport/retry 状态，**从不拥有 feature/window 可见性状态**
- `rs_native_capabilities.lua` — 就绪/诊断面，供 Foundation Gate 消费
- `rs_native_recovery.lua` — 两个独立 bootstrap 恢复入口（紧凑 `R` 启动器 + `RS>` 命令栏）。命令栏只用已验证的 EditBox `OnEnterPressed`，**不发明 chat Slash API**；两个安装器都必须暴露 throw 与逻辑 `false` 结果而不污染整个 Runtime boot

**Native 层硬规则：**

1. Active V3 代码**不得**依赖根级 `globals/` 文件
2. Active V3 代码**不得**读取 `API_TYPE` / `OBJECT_TYPE` / `UIEVENT_TYPE` / `CreateEmptyWindow` / `CreateWindow` / `CreateSimpleButton` / `ReplicatedEscMenuPolicy`
3. 新的裸 Native Widget 构造**必须**经 `NativeObjectFactory`
4. Feature **只声明** API 依赖，**不自己调用** `ADDON:ImportAPI`
5. 导入的 API 是进程级、不可卸载；Runtime disable 仍必须释放事件、Scheduler 任务、缓存与 Widget
6. Legacy 源码只是迁移证据，**永不作为 Runtime Authority**

关键契约：

- **逻辑 ID 与物理 Native ID 分离**；物理 ID 不持久化、不反向解析为业务身份
- Native 对象必须经 Object Factory / Parent Fence / Build Scope 创建
- **未验证 RU 参数、返回结构、权限或 cooldown 时 fail-closed**，不猜字段、不猜写法

### 3.3 Shared Services（19 个 Active）

| 服务 | 责任 |
|---|---|
| `SkillMetadataV3` / `BuffMetadataV3` | 名称/Icon 懒解析与有界缓存 |
| `StatusClassificationV3` | **Buff / Debuff 分类唯一 Authority** |
| `AuraObservationV3` | 按需 Aura 状态事实 |
| `UnitIdentityV3` | 保守单位身份事实 |
| `CombatEventBusV3` | **Combat Fact 唯一共享入口** |
| `CombatAnalyticsV3` | 单 `scope=all` Consumer + Metric 分发 |
| `TeamRosterV3` | 团队/成员快照事实 |
| `CombatRelationV3` | SELF / TEAM / FRIENDLY / OPPONENT / UNKNOWN |
| `InstanceCatalogV3` | 运行时副本目录事实 |
| `QuestProgressV3` | 任务进度共享读取 |
| `GearServiceV3` | 装备读取/换装受控能力 |
| `InventorySnapshotV3` | 背包/仓储的显式有界只读快照；不拥有业务规则或写动作 |
| `AlertsService` | 短生命周期 Alert 状态 |
| `ScreenProjectionV3` | Native world/screen → **UIParent 屏幕坐标 Authority** |
| `AuctionQueryV3` | 当前挂单查询、事件所有权、串行化与限速 |
| `AuctionSearchBridgeV3` | 显式拍卖查询桥；原生搜索栏只做 bounded/readback 增强同步，失败自动降级到 `AuctionQueryV3` |
| `DailyAuctionMaterialsV3` | 按需读取当前居民做货任务；历史 QuestId 表作为兼容线，RU 实机明确“地区+特产类型”标题可直接解析已核配方；多候选必须显式选择，绝不累加 |
| `AuctionSessionListV3` | 纯 Session 临时材料组 CRUD；无 Persistence Store，重载自动清空 |
| `PriceQuoteQueueV3` | 共享按需报价队列与 bounded quote read-model |
| `AuctionSurfaceV3` / `CraftSurfaceV3` | 只读观察原生窗口可见性/几何，不拥有业务状态 |

**Service 只提供共享事实，不拥有 Consumer 的业务判定和 Presentation。**

### 3.4 Feature Runtime

- `features/rs_feature_registry.lua` — Feature 元数据 Authority
- `features/rs_feature_runtime.lua` — Feature 生命周期

Feature 的标准责任边界：

```text
Store / Settings + Domain / Authority + Projection + Commands + Demand lifecycle
```

长期规则：

- 高消耗模块必须**独立监听、独立缓存、独立生命周期**；关闭后释放资源
- 低消耗模块不得依赖 DPS 等高性能模块才能运行
- **`Feature Enabled ≠ Presentation Visible`**：隐藏窗口不等于关闭 Feature，关闭 Feature 也不等于删除永久配置
- Runtime Blocked / Partial **必须保留真实 blocker**，不允许用空壳页面冒充完成
- **Lua lexical-local 规则**：只在单文件使用的 helper 必须 `local function`；一个值若要在 `if/elseif/else` 之后继续消费，local 必须声明在共同父作用域。禁止依靠"同名全局恰好为空"维持正确性

### 3.5 Combat 共享架构

- `CombatEventBusV3` 是 `COMBAT_MSG` / `UNIT_DEAD_NOTICE` 的共享入口
- `CombatAnalyticsV3` 只持有一个 `scope=all` Consumer，把事实分发给独立 Metric
- DPS 通过隐藏 `dps_core` adapter 复用该入口；Death Review 保持独立 `scope=self` 低开销链路
- **技能代理归属 fail-closed**：玩家放置技能实体若缺可靠 proxy→caster owner link，必须显式保留为"未归属技能代理"，**禁止按最近施法者/距离/目标/唯一候选猜主人**
- **Healer** 复用 `TeamRosterV3 + AuraObservationV3`，自身拥有治疗优先级判定；`RaidTeam（成员身份） ≠ RaidPanel（屏幕容器） ≠ Calibration（面板几何）`

### 3.6 Presentation / RSUI

**当前只有 V3 Presentation Host：**

| 角色 | 文件 |
|---|---|
| Router | `presentation/v3/navigation/rs_v3_router.lua` |
| Page | `PageHost` |
| Floating Widget | `WidgetHost` |
| Modal | `ModalHost` |
| Shell | `rs_v3_shell.lua` / `rs_v3_host.lua` |

**RSUI 是唯一通用 UI Foundation**，页面应优先组合：DataView/TableView/List/Tile、Binding/ViewState、ActionRunner、WindowShell/FloatingSurface、声明式 Form/Layout Templates、Workspace Composition 模板（MasterDetail / InspectorWorkbench / SettingsWorkbench / CommandCenter / ResponsiveInspector）、Composite Foundation（StatusChip / PickerModel / SearchablePicker / IconPicker / TreeModel / TreeView）。

重要规则：

- **UI 默认 Diff Rendering**，不循环重复写相同 Native 状态
- 大量数据必须 bounded / pooled / virtualized
- 严格 BuildScope 对 required component **fail-fast**，失败即 Generation quarantine，不提交半成品
- 窗口几何/外观持久化属于统一窗口体系，**不允许每个模块复制第二套位置状态**
- 可复用交互（悬浮、颜色、数值）优先沉到 RSUI，不在业务页重复手写
- RSUI Component **只有一个逻辑 Parent**；RU 没有已验证的通用 Reparent API，跨 Parent 重挂载一律 fail-closed

### 3.7 Persistence

先定义 Lifetime，再决定是否保存：**Permanent / Daily / Weekly / Session / Checkpoint**。

统一采用 Store Contract、Dirty + Debounce、Schema Migration、Write Fence、失败 rollback。

```text
SaveData 物理边界
   ├─ EncodeValue            → 业务 canonical（含 section 前缀）
   ├─ CanonicalIntegrityValue→ Store 自己的 canonical 投影（encode() 或 normalize）
   ├─ FingerprintCanonicalValue → encodedFingerprint（在 transport 编码**之前**计算）
   ├─ Envelope Seal          → envelopeFingerprint（只覆盖 metadata）
   └─ EncodePhysicalEnvelope → Transport 物理层（v1/v2 哨兵）
LoadData 校验顺序
   Envelope Seal → metadata/schema → current canonical exact →
   Store exact historical canonical → Store exact known old/new pair →
   budget → migrate → apply →（必要时）立即重盖章
```

**未知 mismatch 始终 fail-closed。** 恢复候选没有信任权，必须逐字命中旧 `encodedFingerprint`。

#### 状态显示持久化边界（.18.243+）

`v3.buff_display` 已降级为 **LegacyMigrationSourceOnly**，只允许首次升级读取，禁止作为正常运行时写 Authority。当前持久化拆分为：

- `v3.buff_display.settings`：小型显示/窗口设置；
- `v3.buff_display.layout`：自身/目标 HUD 布局、校准、复制自身→目标、Reset；
- `v3.buff_display.tracking.player.a|b` / `target.a|b` / `meta.a|b`：追踪数据 inactive A/B；
- `v3.buff_display.tracking.manifest`：唯一 active slot / generation 提交点。

Tracking 修改必须先 durable 写入并回读验证 inactive 的 player/target/meta 三个 Store，**全部成功后**才允许提交 manifest。inactive 写失败或 manifest 写失败都不得改变上一代 Authority；active slot 损坏则 fail-closed，禁止偷偷回退到 inactive 猜用户配置。HUD/settings 保存不得触碰 tracking Store，更不得重新写旧 `v3.buff_display`。

首次迁移的方案 A 是一次性兼容例外：仅当旧 schema8/Transport5 的 `player.auto` 已是实证残片、`target.auto` 为完整 dense 列表且新 manifest 尚不存在时，允许以完整 target Auto 作为 player Auto 迁移基线；迁移完成后该规则退出日常数据流，**不得扩展成 Twin Authority、模糊恢复或 Hash 猜 ID**。

### 3.8 Static Data / ID

静态身份命名空间**必须分离，互不可替**：

| 命名空间 | 含义 |
|---|---|
| `trade_craft.craftId` | Commerce 制作公式 ID |
| `trade_good.productItemId` | 产出货物 Item ID |
| `trade_material.compactId` | 旧版材料兼容编号 1..74 |
| `trade_material.itemId` | 服务器物品 ID |
| `instance.databaseZoneId` | 数据库 Map Zone ID |
| `instance.runtimeInstanceId` | 客户端 `X2BattleField` 运行时副本类型 |
| `quest.id` | Quest ID |
| `combat_source_proxy` | 玩家放置技能实体 → proxy family / 已核 ability IDs |

**禁止用编号规律推测未核 ID**；新增未核 ID 会触发 Foundation Gate 告警。`data/` 下的表运行期只读（封存）。

---

## 四、硬规则（改代码前必读）

1. **Authority 与 Presentation 永远分离**：业务结论不提升到公共 Core；UI 不自己决定功能归属
2. **Module Enabled ≠ HUD Visible ≠ Collapsed**：三者严格分离；禁用模块不清空业务配置
3. **Quiet by Default**：新安装默认关闭专业模块；不偷偷出现旧 HUD/快捷按钮
4. **Diagnostics 是 P0 基础设施**：高频问题必须限频；热路径只统计不落盘
5. **Native Identity 严格分离**：`pcall` 只处理可恢复参数异常，不是架构补丁
6. **Persistence 先定义生命周期再保存**；Daily/Weekly 不能只判断本地日期
7. **禁止伪重构**：只拆文件、超级 Core、全局可写 State 都不允许
8. **API 治理**：以 `core/rs_api_capabilities.lua` 为静态基线；不因旧版本曾开放就假设当前可用
9. **故障隔离**：单个模块异常不拖垮 Suite
10. **中文维护注释强制**：所有新增/修改代码行必须说明"为什么存在、属于哪个 Authority/生命周期/安全边界、未来不能破坏什么"

### 4.1 高风险 Native 能力（安全护栏，不得绕过事务）

以下能力必须由各自 Authority 的显式契约保护；不得因为旧版“曾经能用”就绕过 Capability / 生命周期 / 恢复边界：

| 能力 | 当前状态 |
|---|---|
| Fishing full R source-slot enumeration/snapshot | `HotkeyContractVersion = 3`，只在钓鱼 Demand 激活且非战斗时读取；首次写键前必须 durable 保存恢复快照 |
| Fishing R write/restore/error recovery | `FishingHotkeyV3.TransactionContractVersion = 3`，逐次写入后 readback，关闭/切区/重载恢复失败时保留 recovery 并 fail-closed |
| Reinforcement slot levels/materials/set effects | SPECIFIC_RUNTIME_BLOCKED |

中文维护：Fishing 不再使用 `HotkeyRuntimeBlocked=true` 的全局硬禁用；它仍保持 `migrated_partial`，直到 RU 10.0 Fresh Reload 实钓完成源槽、五动作、ZoneGroup 49、战斗延迟恢复和异常重载恢复验收。离线测试不能升级为“实机完成”。

---

## 五、RU 平台已知怪癖（定位问题的钥匙）

### 5.1 持久化：RU SaveData serializer 会"吃掉"假值

**这是本项目最高频的故障源。** RU 的原生 serializer 在 `SaveData → LoadData` 往返时会**省略某些合法值**：

| 值 | Transport v1 | Transport v2 |
|---|---|---|
| `boolean false` | 已被哨兵保护 | 保护 |
| 空 table | 已被哨兵保护 | 保护 |
| **数值 `0`** | ❌ **会被省略** | ✅ 保护 |
| **空字符串 `""`** | ❌ **会被省略** | ✅ 保护 |
| 保留前缀字符串 | 转义保护 | 转义保护 |

后果：字段消失 → 读取时被 fallback 成**默认值** → canonical 变化 → `integrity_failed:fingerprint_mismatch` → Store 被 write fence。

**判断要点**：

- 只有"**fallback 与真实值不同**"的字段才会造成 mismatch。例如 `minDamage = 0` 的 fallback 也是 0 → 安全；但 `overallOpacity` 的 fallback 是 0.94 → 用户设为 0 就中招
- **放大机制**：`FloatingSurface:NormalizeState` 的 `free` 分支要求 `tonumber(value.x) ~= nil and tonumber(value.y) ~= nil`。窗口贴左/上边缘时 `x` 或 `y` 合法为 `0`，被省略后 `free` 判定失败，`x/y/coordinateSpace/savedLogicalWidth/Height/normalizedCenterX/Y` **整组字段一起塌成 nil**，故障面远大于单个字段
- 修复方向：能结构化证明的（补回被省略的 0）就用**结构化 exact recovery**；物理已丢失、无法反推的才用 known-pair 白名单
- 恢复成功的 Store 应立即**重写为当前 Transport 版本**，否则每次启动都要重跑恢复；但**健康**的旧版本 Store 走惰性升级，避免一次更新触发几十个 SaveData fan-out

### 5.2 RU 表形漂移

RU 往返可能让 Lua 表的 sequence 变成稀疏/map。正常 `ipairs()` 会少读仍存在的行。**恢复候选**才允许用 `pairs()` 收集并重建（必须 bounded，且仍要 exact hash 验证）。

### 5.3 UI 坐标与 Popup 定位

- ArcheAge/CryEngine UI 原点在**左上角**：`+X→右`、`+Y→下`（与直觉相反，页面上写"向上"要减 Y）
- **detached Popup**（Dropdown / ColorField / Tooltip / ContextMenu）逻辑归属 trigger，但物理 root 挂在 `UIParent`。RU 的 `GetEffectiveOffset` 在不同控件/父级下语义不稳定，**禁止业务自己拼绝对坐标**、禁止 `*uiScale` / `/uiScale` 补偿
- Suite-owned Popup 必须先由统一 `PopupPositioning` 解析 Trigger 几何，但**最终 Anchor 车道按控件类型选择**：Dropdown/Tooltip/ContextMenu 可走 Native-relative；ColorField V2 因 RU 顶层 Window 跨层级 Anchor 到页面 Button 会出现“成功但仍停在(0,0)”的实机故障，必须走 `ResolveAnchorRect → ResolveAnchored → UIParent` 的 viewport-resolved 车道
- **坐标 lane 必须显式**：`popup-native-relative-v1`（适合 Native-relative 的 detached popup）、`popup-viewport-resolved-v1`（ColorField V2 顶层 Window）、`external-native-window-v1`（跟随游戏窗口）、`world-projection`（ScreenProjectionV3）、persistent/free-window 互不替代
- `Addon Scale` 只影响控件尺寸，**禁止乘到世界投影位置**
- 屏幕边缘适配用 `UIBounds:CorrectOffsetByScreen()`，**禁止**为 1024/1280/1920 各写一套 magic offset

### 5.3.1 ColorField V2

- 共享颜色选择器统一使用 `300×270` 的可读布局：当前颜色预览、常用色、0..255 的红/绿/蓝、恢复默认/取消/应用
- 业务 `get/set` 仍保持 `{r,g,b}` 的 0..1 数据契约，UI 只在 Presentation 层转换成 0..255，禁止为了界面改存档格式
- 打开颜色面板时建立 Draft；滑块/预设只修改 Draft，**不写 Persistence**；只有点击“应用”才提交一次业务写入
- “取消”、点击外部关闭、再次点击 Trigger、页面释放都必须丢弃 Draft；“恢复默认”也只是预览，仍需“应用”确认
- ColorField popup body 不属于普通页面 Layout Tree，构建后和每次打开时都必须显式 `Layout()`，禁止再依赖 1×1 Host 的隐式布局

### 5.4 输入与焦点

- 所有 Suite 键盘输入按 Native physical id 登记；`ClearFocus` 只有在"global focused id → 已登记 Suite input → 属于正在停用子树"三条同时成立时才执行，**不得误清游戏聊天输入**
- RU **尚未验证** generic `OnKeyDown` / `OnKeyUp` / `OnTextChanged`，Foundation Audit 直接禁止 Active Runtime 绑定这三类事件
- **DraftSession V2**：`draftActive`（Lua 草稿事务）与 Native `focused/keyboardArmed` 必须分离。带“应用/添加/搜索”等明确确认动作的输入在 `LostFocus` 时只捕获草稿并释放键盘，不得写 Feature/Store，也不得恢复 Authority 文本；只有 Apply/Enter/业务动作才提交，Cancel/页面 Release 才丢弃。
- `NumericField` 有 Apply 按钮时必须使用 explicit draft；Slider/± 属于同字段的另一条明确 Authority 写路径，可以显式取代该字段未应用草稿。高频 Feature Presentation 刷新必须查询 `draftActive`，禁止用 Native Focus 判断用户是否仍有未提交输入。
- Draft 诊断只允许输出 active/focused 数量、控件 logical id 与生命周期计数，**禁止输出用户正在输入的草稿文本**。
- `StartMoving/StartSizing/StopMovingOrSizing` 是实际 capture/geometry Authority，不允许页面用 Tick + raw mouse delta 建第二套

### 5.5 其它

- RU 缺少已验证的通用 `DestroyWidget`；Release 采用解绑、隐藏、Lua 引用释放与 Generation 隔离
- 物理 ID 不透明，不可持久化、不可反向解析为业务身份

---

## 六、工程操作手册

### 6.1 门禁（改完必跑）

```bash
cd replicatedsuite

# 1) 语法（排除 toc.g，它是 TOC 清单不是 Lua）
for f in $(find . -name "*.lua" -not -path "./.workbuddy/*"); do luac -p "$f" || echo "FAIL $f"; done

# 2) TOC ↔ 磁盘 Lua 双向对账（0 差异才算通过）
python - <<'PY'
import os
toc=[l.strip() for l in open('toc.g',encoding='utf-8') if l.strip() and not l.strip().startswith('#')]
allf={os.path.relpath(os.path.join(r,f),'.').replace('\\','/')
      for r,d,fs in os.walk('.') if '.git' not in r and '.workbuddy' not in r
      for f in fs if f.endswith('.lua')}
print("TOC",len(toc),"MISSING",[t for t in toc if t not in allf],"NOT IN TOC",len(allf-set(toc)))
PY

# 3) Foundation Audit（约 3 分钟；改代码前后各跑一次）
python tools/rs_foundation_audit.py

# 4) 全量 Harness（以退出码为准，不要用 grep 判定）
pass=0; fail=0
for f in tools/*harness*.py; do python "$f" >/dev/null 2>&1 && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL $f"; }; done
echo "PASS=$pass FAIL=$fail"
```

**判据**：Audit 输出 `FOUNDATION_AUDIT PASS | toc=N activeLua=N allLua=N`，且 globals/presentation/rawNative/rawScope 等结构违规全为 0。

### 6.2 诊断框架（模块优先 + 系统维护）

1. **业务模块默认入口**：每个 Feature 页面右上角统一提供「诊断」。入口由 `PageHost buildContext -> UIV3Design:ModuleDiagnosticsButton()` 自动注入；普通页面禁止自己复制诊断窗口/分页逻辑。少数自定义抬头页面也只能调用同一个 Design helper。
2. **模块错误 Authority**：`DiagnosticsManager` 仍是全局结构化错误唯一 Authority；`ModuleDiagnosticsHub` 只把可证明归属的错误投影到模块有界环（每模块最多 32 条）。历史 `buff_display_v3` / `dps_v3` 等 source 只能由 `FeatureRegistry.diagnosticSources` 显式精确声明，Hub 禁止模糊猜模块。无法证明归属的共享错误只留在 `system`，不能污染业务报告。用户点击「生成诊断」时才读取 Feature health / 所属 Store / Provider，翻页只消费一次固定 snapshot，不重新采集。
3. **诊断专用复制框**：模块诊断使用 `DiagnosticCopyBox`。底层仍是已验证的 `EDITBOX_MULTILINE`，但它不进入 DraftSession，也不调用 `BindDeferredInputActivation`；迟到 `OnLostFocus` 只计数，不撤销 Keyboard、不改文本。只有窗口关闭/模块切换/Owner Release 才 Deactivate。**禁止为了修诊断复制修改普通 EditBox/MultiEditBox 生命周期。**
4. **系统诊断**：`system.diagnostics` 只作为 Core / Foundation / 完整维护报告入口；全量 `RS-SELF-CHECK` 协议继续保留，但普通业务故障优先使用模块诊断，避免复制其它模块无关内容。
5. **Store 归属**：模块报告只显示 `Persistence:Describe()` 中可由 Store owner / Feature authority 证明属于当前模块的 Store。任何 Store 写保护或连续保存失败仍由 Persistence 自己负责事实状态；模块诊断只读，不解除 Fence、不 Load/Save Store。
6. **磁盘取证（最强）**：存档在 `C:\Users\23118\Documents\ArcheRage\USERcb92…/udf\`（RocksDB 文本格式：`str_/num_/bool_/isTable`，数字为 float32）；只有模块报告不足以定位物理传输故障时，才升级到完整系统报告/磁盘原始取证。

**模块诊断维护红线**：无新 Tick；Provider 只能在用户点击时调用；禁止诊断启动关闭中的 Feature/Acquire Consumer；禁止翻页重新采集；禁止业务模块自己持有第二个诊断窗口；禁止把报告正文或 moduleId 写入业务 Store。

### 6.3 环境坑

- 本机可能没有 `texlua`：`tools/rs_lua_runner.py` 会回落到 `lua5.4`，并已在共享层注入 Lua 5.1 兼容垫片（`unpack` / `table.getn` / `math.mod` / `loadstring`）。**不要给单个 harness 手加垫片，也不要硬编码 `texlua`**
- 工程全 CRLF；跨平台比对文本前先归一 `\r\n → \n`
- `replicatedsuite/.workbuddy/tmp/` 里的 `.lua` 会被 Audit 计入 `allLua` 并报 `Disk Lua not in Active TOC`——放探针前先 `mkdir -p`，跑 Audit 前先清掉
- 这是**多 Agent 工作区**：`git status` 的 M 数会随后台会话变化。开工前和收尾时各跑一次，并用 `stat -c '%y'` 看 mtime 是否成批（同一秒 = 批量写入，通常不是你的改动）

---

## 七、当前状态快照

| 项 | 值 |
|---|---|
| Architecture | V3-only |
| BuildTag | 见 `replicatedsuite.lua` 的 `S.BuildTag` |
| Active TOC Lua | 见 §6.1 对账输出（当前 245） |
| 运行时 Addon | 仅 `replicatedsuite/` |
| 门禁 | Lua Parse / Foundation Audit / Python Harness 全绿 |

> 该表格刻意只放"随时可自查"的项。逐版本历史、能力完成度、待办队列、RU 验收清单不再单独维护文档——**需要时直接看代码、看诊断输出、看用户实测反馈**。
