# Replicated Suite Native Foundation 架构（统一权威）

> **Authority Level**: ARCHITECTURE
> **范围**: Native 基础层——Native Identity / Object Authority / Object Factory Fence / Write Fence / ESC 集成 / Feature API Import / Foundation Gate / Crash Guard。
> 由 M1.5 Native Foundation Independence、M1.14.1 Native Identity Crash Guard、native/README 收敛而成。


## 当前 Native Import / Object Fence 补充（M1.16.0.18.1）

- `NativeImports v3` 是唯一 Import Authority。Optional Object 导入失败进入有界 negative cache；同一 Generation 的可选路径不反复跨 Native `ImportObject`，Required 请求仍允许重新确认而不被可选失败永久遮蔽。Feature metadata 可以保持精确的 `X2Namespace:Method` 能力名，但 Import 层必须先经 `NativeContract:ResolveApiKey()` 收敛到 namespace-scoped `ImportAPI` ID。
- `NativeObjectFactory v3` 的 `CreateChildByObject` 必须先确认 `AcquireObject()` 成功；导入失败时 fail-closed，禁止忽略结果继续调用 `CreateChildWidgetByType`。该规则由 `objectImportFenceContractVersion=1` 暴露给 FoundationGate。
- `NativeCapabilities` 与 FoundationGate 同步要求 Imports>=2 / Factory>=3；禁止通过降低版本门槛让文档/代码漂移看起来“通过”。


## M1.16.0.18.18 Definition Preflight 与 Native Allocation 边界

- NativeObjectFactory 仍是唯一 Native constructor Authority；本轮没有把 Native 创建权上移到 RSUI。
- RSUI 在进入 NativeObjectFactory 前新增 Definition Preflight：先拒绝重复 logical id、缺失 parent/id 以及已登记公共组件的结构错误；通过前检的 logical id 在当前 Generation 内永久视为 consumed，避免 rollback 后再次撞进 Native duplicate。该层只减少“创建一半才失败”的机会，不把 Lua rollback 描述为 Native Destroy。
- 开发态 `tools/rs_foundation_audit.py` 扫描 Active V3 raw constructor；除 `native/rs_native_object_factory.lua` 外出现 `UIParent:CreateWidget/CreateChildWidget/CreateChildWidgetByType` 即封包失败。

## 目录

1. [Replicated Suite V3 — M1.5 Native Foundation Independence](#sec-1)
2. [Replicated Suite M1.14.1 — Native Identity / UI Crash Guard](#sec-2)
3. [Replicated Suite Native Foundation](#sec-3)

<a id="sec-1"></a>
## 1. Replicated Suite V3 — M1.5 Native Foundation Independence

> 来源（已合并至本权威文档，原文件已收口）：`replicatedsuite\Docs\Rebuild\M1_5_NATIVE_FOUNDATION_INDEPENDENCE_20260827.md`

## Replicated Suite V3 — M1.5 Native Foundation Independence

日期：2026-08-27

### 目标

在 M2 Quest / Instance Authority 之前，彻底移除 V3 对旧根级 `globals/` 的运行时依赖，建立 Replicated Suite 自己拥有和维护的 Native Foundation。

### 完成结果

Active TOC 已不再加载任何 `../globals/*` 文件。旧 `globals/` 目录已于 2026-09-01/02 随旧版代码一并物理删除（用户持有全量离线备份，插件树内绝不重新引入），不再随包；当前 V3 不再有任何根级 `globals/` 运行时依赖。

新的 Native Foundation 位于：

```text
replicatedsuite/native/
├─ rs_native_contract.lua
├─ rs_native_imports.lua
├─ rs_native_object_factory.lua
├─ rs_native_esc_bridge.lua
├─ rs_native_capabilities.lua
└─ rs_native_recovery.lua
```

### Native Contract

当前只登记已迁移 V3 真正需要的客户端 ABI：

Foundation APIs：

- CHAT
- OPTION
- UNIT
- LOCALE

M1 Activity Feature：

- MAP

没有把旧 `apitypes.lua` 的完整 API 表照搬进新框架。后续 Feature 迁移时，才增加已经核验且真实需要的 API Contract。

### Native Object Authority

Active V3 的原生 Widget 创建统一收敛到 `rs_native_object_factory.lua`。

运行路径中不再读取：

- `OBJECT_TYPE`
- `CreateEmptyWindow`
- `CreateWindow`
- `CreateSimpleButton`
- `ApplyButtonSkin`

旧 UI helper 不再作为新 RSUI 的地基。

### ESC Integration

旧 `ReplicatedEscMenuPolicy` 的 V3 所需行为重新实现为 `S.NativeEscBridge`。

它只负责：

- RegisterContentWidget
- RegisterContentTriggerFunc
- AddEscMenuButton
- 请求可见性的兼容归一化

窗口是否显示仍由 V3 UIHostManager 负责，NativeEscBridge 只是 Proxy。

### Feature API Import

原 `core/rs_api_imports_v3.lua` 已退休并归档。

新的唯一 Import Authority 是 `S.NativeImports`。`S.ApiImports` 只是对同一个对象的 FeatureRuntime 兼容别名，不存在第二套 Import 状态。

Feature 生命周期仍然采用：

```text
Feature Initialize
    ↓
NativeImports:Acquire(feature owner, ApiDependencies)
    ↓
X2Namespace:Method → NativeContract namespace key
    ↓
首次需要时 ImportAPI(namespace id)
    ↓
Feature Enable
```

### Foundation Gate

新增三个 Blocker Gate：

- `native_foundation`
- `native_independence`
- `native_import_authority`

要求 Native Contract / Imports / Factory 均归 Replicated Suite 所有，外部 globals 消费为 0，Legacy UI helper 消费为 0。Foundation import failure 仍是 Blocker；单个 Feature import failure 由 FeatureRuntime fault/诊断隔离，不再把整个 Native Foundation 判坏。

### Build-time 审计

Active TOC 静态扫描必须保持：

```text
API_TYPE                    0
OBJECT_TYPE                 0
UIEVENT_TYPE                0
CreateEmptyWindow           0
CreateSimpleButton          0
ApplyButtonSkin             0
nameMappings                0
ReplicatedEscMenuPolicy     0
```

`UIParent:CreateWidget` / `CreateChildWidget*` 只允许出现在 `native/rs_native_object_factory.lua`。

### 后续

M2 Quest / Instance Authority 只能基于新的 Native Contract 扩展 `QUEST` / `BATTLE_FIELD` 等 API，禁止重新引入旧 globals 或旧 Service Runtime。



<a id="sec-2"></a>
## 2. Replicated Suite M1.14.1 — Native Identity / UI Crash Guard

> 来源（已合并至本权威文档，原文件已收口）：`replicatedsuite\Docs\Rebuild\M1_14_1_NATIVE_IDENTITY_CRASH_GUARD_20260828.md`

## Replicated Suite M1.14.1 — Native Identity / UI Crash Guard

### 背景

2026-08-28 的 ArcheRage RU 实机日志在 V3 首次建树阶段记录了两类 Suite 自身的原生 UI 异常：

- 多条 `the widget with the same name already exists`
- `rs_ui_framework.lua` 的 `AddAnchor()` 参数类型错误

同一份 `.crash` 的最终原生异常为 `0xC0000005`，最后记录在游戏自身 `raidRecruitMgr / RAID_RECRUIT_HUD` 链路。现有证据不能证明 Suite 的建树异常就是数小时后 Raid UI 原生访问冲突的直接原因，因此本轮不把“修复 Raid 崩溃”作为已证实结论。

本轮目标是先消除日志已经证明存在的 Suite Native UI 不安全行为，并在进入 C++ UI 构造/写入之前建立 fail-closed 边界。

### Native Identity Authority

逻辑 ID 与原生 ID 从 M1.14.1 起严格分离：

```text
RSUI logical id
    ↓ NativeIdentity projection
bounded physical id
    ↓ NativeObjectFactory
ArcheAge native widget registry
```

业务、页面、布局继续使用可读逻辑 ID。原生 Widget Name 只作为不透明的物理身份，不允许业务代码解析或持久化。

`S.PhysicalId()` 生成的物理 ID 预算为 23 个 ASCII 字符。23 是项目侧的保守预算，不宣称是 ArcheAge 官方公开的最大长度；RU Addon API 没有向项目提供可验证的原生名称上限。该预算的目的只是彻底避免把几十字符的层级语义路径直接交给原生注册表。

物理 ID 同时包含：

- 当前 `Generation`
- 逻辑 ID 尾部短 Hint（仅便于调试）
- 两个独立的 31-bit 算术 Hash

完整 Generation 参与 Hash，因此即使可见的两位 Base36 generation token 将来回绕，也不会把旧 Generation 映射成同一物理 ID。

### Native Object Factory Fence

`NativeObjectFactory v3` 是 Active V3 唯一允许调用：

- `UIParent:CreateWidget`
- `CreateChildWidget`
- `CreateChildWidgetByType`

的边界。

构造前必须满足：

1. physical id 已由 `S.PhysicalId()` 注册；
2. physical id 长度在预算内；
3. 本 Generation 尚未占用该 physical id；
4. Parent 未被 RSUI 注册拒绝；
5. Parent 若带 `rsNativeGeneration`，必须属于当前 Generation。

特别注意：Parent fence 必须发生在 C++ 构造调用之前。Lua `pcall()` 可以捕获脚本异常，但不能作为原生 access violation 的恢复方案。

原生构造失败会回滚“待创建”预留；同 ID fallback（例如 EditBox 的兼容路径）仍可继续尝试。

### Native Write Fence

`UI Framework v7` 对迁移后的高频原生写入进行统一安全检查：

- stale generation widget：拒绝写入；
- RSUI registration rejected widget：拒绝写入；
- `AddAnchor` parent 如果是 RSUI Component：先解析成 Native Root；
- `RemoveAllAnchors / AddAnchor / SetExtent / SetText / SetVisible / SetColor / Enable / Pick / Font / Alpha / Scale`：原生调用使用受控 `pcall`，失败不提交 Diff Cache；
- `SafeHandler`：绑定与回调时都检查 Generation / Widget usability。

这不是用 `pcall` 掩盖架构问题。Identity / Parent fence 仍负责在进入 C++ 之前阻止已知非法对象；`pcall` 只是处理可恢复的 Lua/native API 参数异常。

### 生命周期原则

RU 客户端没有经项目验证的通用 `DestroyWidget` API，因此：

- 同一 Generation 内已创建的 physical id 不允许重新创建；
- Release 继续采用解绑 Handler + 隐藏 + 释放 Lua 逻辑引用；
- Hot Reload 通过新 Generation 生成不同 physical id；
- 不伪造“已销毁”的 Native Widget 状态。

### 回归门

新增/升级：

- `FoundationGate v11`
- `NativeCapabilities v2`
- `NativeObjectFactory v3`
- `UI Framework v7`
- `UIV3Acceptance v6`
- `v3_28_native_identity_contract`
- `v3_29_native_parent_fence_contract`

Foundation blocker 会检查：

- Native Identity 版本/长度预算/Hash collision；
- duplicate physical id reject；
- invalid/unregistered physical id reject；
- stale/rejected parent reject；
- stale/rejected widget native write；
- native write call failure。

这些检查均为按需验收，不增加 Tick。

### 后续实机观察

M1.14.1 进入世界后的首要验收条件不是“窗口看起来正常”，而是日志中不再出现 M1.14 的：

- `the widget with the same name already exists`
- `rs_ui_framework.lua ... AddAnchor() expect parameter ...`

如果游戏自身 `raidRecruitMgr / raidFrame` 仍单独发生 `0xC0000005`，需要把它作为第二条原生 Raid UI 调查线继续分析，不能把两条问题链强行合并。



<a id="sec-3"></a>
## 3. Replicated Suite Native Foundation

> 来源（已合并至本权威文档，原文件已收口）：`replicatedsuite\native\README.md`

## Replicated Suite Native Foundation

`native/` is the only active boundary between V3 and the ArcheRage RU client object/API ABI.

### Ownership

- `rs_native_contract.lua` — curated API/Object/Event identity contract. Add entries only when a migrated Feature actually needs them and the client contract is verified.
- `rs_native_imports.lua` — sole Authority for `ADDON:ImportAPI` / `ADDON:ImportObject`; Foundation imports the minimum set, Features acquire business APIs lazily.
- `rs_native_object_factory.lua` — sole active raw widget construction boundary (`UIParent:CreateWidget`, child widget constructors).
- `rs_native_esc_bridge.lua` — stateless Proxy for the documented ADDON ESC/content integration.
- `rs_native_capabilities.lua` — readiness/diagnostic surface consumed by Foundation Gate.
- `rs_native_recovery.lua` — installs the minimal recovery launcher immediately after the Native Foundation.

### Hard rules

1. Active V3 code must not depend on root-level `globals/` files.
2. Active V3 code must not read `API_TYPE`, `OBJECT_TYPE`, `UIEVENT_TYPE`, `CreateEmptyWindow`, `CreateWindow`, `CreateSimpleButton`, or `ReplicatedEscMenuPolicy`.
3. New raw native widget construction goes through `NativeObjectFactory`.
4. Features declare API dependencies; they do not call `ADDON:ImportAPI` themselves.
5. Imported APIs are process-global and cannot be unloaded. Runtime disable must still release events, scheduler work, caches and widgets.
6. 旧版源码已于 2026-09-01/02 物理删除，不再随包；历史资料见 `Docs/Archive/`。任何历史源码只作迁移证据与思路参考，绝不作为 Runtime Authority，也绝不重新引入插件树。


