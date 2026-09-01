# Replicated Suite RSUI 架构（统一权威）

> **Authority Level**: ARCHITECTURE
> **范围**: RSUI（Replicated Suite UI）—— ArcheAge 有限原生 UI API 之上的 UMG 风格 Widget 基础层。
> 本文由 9 个阶段性框架文档（Phase 3–8 + M6 审计）收敛而成，保留全部原始知识，仅做结构归一。
> 当前 RSUI 是正式 UI 底层（见《重建基础架构蓝图》§6）。

## 当前交互 Authority（2026-08-28）

以下规则覆盖本文后续历史阶段记录中与之冲突的旧描述：

- **严格构建 First-Failure Contract（M1.16.0.18.42）**：`page:` / `widget:` / `modal_host` / `main_shell` 等 strict BuildScope 中，required RSUI 组件只要 Preflight、Factory 或 Native 创建失败，ComponentCore 必须立刻中止同步构建事务；禁止继续把 nil parent/control 传给后续组件再制造二次错误。只有 `buildOptional=true` 可以显式降级并返回 `nil, reason`。BuildTransaction 的主错误必须保留第一次 `scope.failure`，后续 callback exception 只能作为 secondary context。共享页面含动态逻辑 ID 时，封包 Gate 必须检查 route 展开后的 identity 唯一性。
- **Windowing 最小尺寸**：RSUI Foundation 不再给顶层窗口设置任意 UX 最小宽高；默认仅保留 Native `1px` 技术下限。只有业务存在真实语义需求时，调用方才允许显式提供 `minWidth/minHeight`。极小窗口下由 Layout Compression / Ellipsis / Clipping Contract 负责退化，不允许通过偷偷 Clamp 窗口尺寸掩盖布局问题。
- **Table/Grid 列拖动**：`TableView` 的 Header Separator 已属于公共交互能力。拖动开始冻结当前 resolved widths；Preview 采用稳定的相邻列边界事务，只改变被拖列与补偿列，不允许每帧重新运行完整 Fill solver 让无关列“呼吸”。宽度按逻辑整数像素采样，仅重排真正发生几何变化的 Cell/GridLine；不重绑业务数据、不 SaveData、不建立永久 Tick；松手后把 Preview 中的列宽对一次性 Commit。
- **拖动必须实时反馈**：任何拖动/缩放手势如果视觉结果只在 `OnDragStop` 才出现，视为 Framework Bug。Preview 必须在交互期间直接刷新已建立 Geometry，而不能只留下 dirty flag 等待提交。
- **透明度分通道**：顶层 Windowing 拥有 `overallOpacity`；RSUI Component Tree 拥有 `backgroundOpacity` 与 `textOpacity`。最终视觉为整体 Alpha 与局部通道相乘。背景通道只修改 Theme 自有 Drawable，文字通道只修改 styled text；新建/虚拟化子节点继承当前局部通道，不做每帧树扫描。
- **策略默认值的零值语义**：FloatingSurface 读取 `defaultOverallOpacity`、`defaultBackgroundOpacity`、`defaultTextOpacity` 及兼容 alias 时必须按 `nil` 判定缺省，不能使用会吞掉显式 `0` 的真假值 fallback；归一化仍负责把字体倍率等字段限制在各自合法范围。
- **持久化边界**：交互 Preview 只改临时 Presentation Geometry；窗口/列宽/外观等需要持久化的状态只能在对应 Domain/Store Authority 中提交，禁止交互高频路径直接 `SaveData`。
- **FloatingSurface / HUD 状态绑定**：`RSUI.FloatingSurface` 只能作为 `WindowShellV3 + Windowing` 上方的薄绑定层，不得成为第二 Window Authority。`Windowing` 继续拥有 Native 拖动/缩放事务，`WindowShellV3` 拥有公共 Chrome，Feature Store 拥有持久化状态；FloatingSurface 只负责 placement/size/minimized/locked/overall/background/text opacity 的标准映射与 StateAdapter。HUD 默认采用 `compact` 最小化：保留 `normalWidth/normalHeight`，视觉只留下约 32×32 恢复方块；`collapse` 仅作兼容模式；可选 ScreenSnap 只允许在 Drag Stop 提交。Activities/Tasks 是首批迁移样例。M1.15.2H2 起 FloatingSurface 额外负责关闭后的 `visible` 三态同步，并暴露 `surface:Close()` 作为与 X 同一契约的编程关闭入口（详见文末 M1.15.2H2 章节）。
- **DataView ViewState**：ListView / TileView / TableView 的 Loading / Ready / Empty / Error / Unavailable / Stale 必须走 `RSUI.ViewState`；业务层只决定状态与文案，虚拟化 Row/Scrollbar 的显隐由 DataView 统一处理。`SetItems` 只允许自动处理 Empty/Ready，不得覆盖业务显式 Error/Unavailable。
- **ActionRunner**：用户触发的可失败操作优先通过 `S.ActionRunner` 进入 Busy / 同 ID 重入 / exception fence / Diagnostics 边界。ActionRunner 只拥有 Presentation 临时状态，不拥有业务事务；如果业务在执行期间已经刷新 Button 的最终 text/enabled，runner 必须通过 revision 判定并尊重新状态。
- **Persistent Setting Binding**：精确数值、Toggle 等设置通过 `RSUI:Binding({storeId=...})` 连接 Persistence。Domain setter 只负责内存事实，Binding 负责 Normalize / Validate / MarkDirty / Commit；Store `writeFenced=true` 时必须在 Domain mutation 前拒绝。禁止 NumericField/Toggle 各自直接 `SaveData`。
- **M1.14.5 Adoption Rule**：以上能力不是“可选示例”，而是 Active V3 的默认开发路径。标准 DataView 必须优先复用 ViewState；可失败/可重入的用户命令必须优先进入 ActionRunner；受 Store 管理的 Numeric/Toggle/Appearance 设置必须使用 Domain-only apply + Persistent Binding。`WidgetHost` / FloatingSurface 的旧公共 setter 默认 `persist=true` 保持兼容，但 Settings Binding 调用必须显式 `persist=false`，避免一项设置出现 Host Save + Binding Save 两个 Authority。仅 UI-only 的筛选、页签、展开/收起等无失败 Domain 事务不强制套 ActionRunner。
- **Foundation 可观测性**：ViewState / ActionRunner / Binding / FloatingSurface / ScreenSnap 必须提供按需 Snapshot 给 Diagnostics；注册表必须使用弱引用或显式生命周期；可能跨 `ReloadAddon` 保留 Lua Root 的注册表必须按 `S.Generation` 隔离，不允许为了诊断建立永久 Tick/全树扫描。
- **类型注册即公共 API（M1.16.0.7）**：`RSUI:RegisterType/ReplaceType(name, factory)` 是 Component Type 与 `RSUI:<name>(spec)` 公共创建入口的唯一 Authority；禁止维护第二份手写“已支持组件类型”名单。FoundationGate 必须检查所有已注册 Factory 都有可调用公共入口，避免 `types[name]` 存在但页面调用方法为 nil。
- **导航幂等（M1.16.0.7）**：`WidgetSwitcher:SetActiveWidget()` 的“目标已经激活”属于成功 no-op，不是拒绝；PageHost 重复导航当前 route 不允许重复释放/获取 Feature Consumer，也不应产生 switch failure。只有目标不存在才是 reject。
- **字体缩放参与 Measure（M1.16.0.7）**：RSUI Spec 保留 base font size，Theme 统一解析实际 Native font size；TextLayout 必须按 Native 物理字号测量。任何 `fontScale/addonScale` 改变都应事件式 invalid Measure→Arrange，而不是只改 Native Font 后继续沿用旧 DesiredSize。Form Field 的 label/control/hint 高度由实际文字行高计算；历史固定高度只能作为 `minHeight`，除明确业务语义外不得把提示文字压入固定槽。
- **Text alignment Native 类型**：Theme 是文本样式进入 RU Native 的唯一公共边界；`StyleLabel` 必须把字符串别名（如 `left`、`center`、`right`、`top-left`）转换为客户端数值对齐常量后再调用 `SetAlign`，不允许把 Presentation 语义字符串直接穿透到 Native。
- **Floating logical content parent（M1.16.0.8）**：`FloatingSurface:GetContentRoot()` 对 RSUI 业务必须返回 WindowShell 的逻辑 body Component，而不是 `.root` Native widget。只有 adapter/native glue 才允许调用显式 `GetNativeContentRoot()`。否则物理控件虽然存在，逻辑 `parentComponent/children` 会断链，Shell 的 Measure/Arrange/Release/opacity propagation 都无法覆盖该子树。
- **Native LABEL 单行契约（M1.16.0.8）**：当前 RU 已核 API 的 `LABEL` 不提供可靠 word-wrap/line-spacing；禁止把包含 `\n` 的手工 Wrap 结果直接 `SetText` 到一个 LABEL。`Text overflow=wrap` 必须使用 WrappedText Composite：一个非绘制 Host + 有界单行 LABEL 池，每条 Label 只接收一行。池默认 6、硬上限 8；超出按 TextLayout ellipsis；创建/更新/布局均事件驱动，不允许永久 Tick。
- **紧凑分段选择契约（M1.16.0.9）**：HUD/工具条需要在 2~8 个互斥视图间切换时，优先使用 `RSUI:SegmentedSelector`，不要在业务 Widget 内手写一组互不知情的 Button。Selector 复用 Persistent Setting Binding、统一 selected visual 和幂等点击；当前值再次点击必须是成功 no-op，不得重复写 Store。该控件只拥有 Presentation 选择交互，不拥有业务数据；例如 DPS 的 PVE/PVP、友/敌、伤/承/治仍由 DPS Feature settings/Domain Projection 决定。
- **特殊 WindowShell 布局所有权（M1.16.0.10）**：WindowShell 的 root 是 title/body/footer Chrome compositor，不是普通 Overlay 页面根。必须设置 `autoRelayout=false`，并通过 `layoutHost` 将后代 Measure/Layout invalidation 路由回 WindowShell 专用 `Layout()`；禁止通用 RSUI layout queue 重新 Arrange 该 root，否则 body 的 fill slot 会覆盖 titleBar。高频内容变化只能使用有界 one-shot 合并重排，不允许常驻 Tick。
- **Floating 局部字体契约（M1.16.0.10）**：FloatingSurface 可拥有持久化 `fontScale`，但全局 UI/font scale 仍由 Theme Authority 决定。最终 Native 字号必须统一为 `Theme.ResolveFontSize(base, localScale)`，TextLayout Measure 与 Render 必须消费同一 localScale；后创建的虚拟化子组件从逻辑父级继承。局部倍率不得通过全局 Typography 设置实现，也不得在业务 Widget 中手工遍历 Native children。
- **Floating compact chrome（M1.16.0.12）**：HUD 型 FloatingSurface 默认使用紧凑 WindowShell profile（title/footer/padding/control width），但 WindowShell 本身仍是唯一 Chrome Authority；业务 Widget 不允许自行画第二套标题栏。普通 Modal/Dialog 的历史默认不受该 profile 影响。

- **Compact Numeric Row（M1.16.0.18.14）**：有限范围设置可使用 `D:CompactNumericSetting()`，其底层仍是单一 `NumericField + Binding`，只改变排列为 `Label | Slider | NumericInput`。Slider preview 只同步显示，最终 commit/persistence 仍由同一 Binding Authority 执行；无有限 `max` 的自由窗口宽高等字段继续使用精确输入，不伪造 Slider 范围。
- **Compact Floating Minimize（M1.16.0.18.14）**：HUD FloatingSurface 默认 `minimizeMode=compact`，WindowShell 折叠 title/close 并缩成约 32×32 恢复按钮；业务 Widget 不得各自实现迷你标题条。普通 Dialog/Modal 的 WindowShell 默认不变。
- **Narrow Numeric Space Priority（M1.16.0.18.16）**：`NumericField inline` 的 label/input 下限不得在窄 HUD 中无条件吞掉 Slider；v2 提供 `labelMinWidth / labelMaxShare / inputMinWidth / sliderMinWidth`。默认值继续兼容普通设置页；只有知道标签短、精确输入可安全收窄的 Consumer（如 Floating Appearance）才覆盖这些约束。布局压缩时优先保证 Slider 仍有可操作轨道，再让 NumericInput 向其声明的 minimum 收缩。
- **Floating Appearance Stability（M1.16.0.18.17）**：`NumericInlineContractVersion=3` 增加 `sliderPreferredShare`；紧凑 Consumer 可显式优先保证 Slider 拖动面积，输入框只保留 Native 安全最小宽度。WindowShell 的 lazy Appearance 若本 Generation 构建失败必须闩锁失败状态，不允许以相同 Native identity 立即重试；业务 Floating Widget 禁止再自建第二套透明度/字号编辑器。

- **Floating Title Appearance（M1.16.0.18.15）**：所有 `FloatingSurface` 默认由 WindowShell 标题栏提供统一“外”入口；整体/背景/文字 alpha 与 local fontScale 最终仍通过 `WindowShell -> FloatingSurface state -> persist` 单 Authority。为避免每个关闭 HUD 预分配 Slider/Edit，外观面板必须按首次点击 lazy 构建；视觉 preview 不直接 Save，最终 NumericField commit 才进入既有 state/persist。业务 Widget 禁止再创建自己的透明度/字号设置弹层。
- **Overlay Scrollbar / Responsive HUD Table（M1.16.0.18.15）**：窄 HUD TableView 可显式 `overlayScrollbar=true`，此时 ListView 的可用列宽不得扣除 scrollbar reserve，窄轨道叠在 viewport 右缘；普通表格默认行为不变。可缩放 HUD 的列应使用 `fill + absoluteMinWidth` 由 `ResolveColumnWidths` 每次 Layout 重算；若业务不需要用户保存列宽，关闭 `columnResize`，避免极窄窗口继承旧 manualWidth。
- **Viewport owns visible count（M1.16.0.12）**：可竖向 Resize 的 ListView/TableView 必须拿到完整的**有界业务 Projection**，由实际 `Layout(height)` 计算 `visibleCapacity`、虚拟池和 scrollbar。业务层不得先用“显示行数”裁掉数据再交给 DataView，否则窗口变高也无法展示更多行。`desiredRows` 只允许影响 DesiredSize，不得成为 runtime data cap。
- **Floating→Modal wake contract（M1.16.0.12）**：Modal 仍属于应用级 `ModalHost`，Floating Widget 不创建私有 Modal Host。从隐藏的主 Shell 发起 Modal/Toast 前必须经 `ModalHost:EnsureApplicationVisible()` 唤醒应用宿主；`Push()` 自身也要做防御性 wake。缺少 Quest/Instance detail 时显示明确 unavailable 状态，不允许“点击无反应”或在隐藏 Shell 中静默显示。
- **Page Construction Recovery（M1.16.0.18.1）**：DataView 的同步 Normalize 阶段只允许读取当前数据参数；`columnRef/routeRef/handleDefinition` 一类 iteration-local 变量只用于真正延迟执行的 Native callback closure。`TableView`/Shared Scrollbar 等严格拥有的 Native Widget 在创建后的运行期显隐必须经 `UI:SetVisible`，禁止直接 `Show()` 让 Diff cache 与 Native 状态分叉。Generic WindowShell 开启 BuildScope 后，无论成功还是 Windowing 失败都必须 Commit/Rollback；任何成功路径遗留 Active BuildScope 都是 Foundation Blocker。
- **Strict V3 Build Failure Fence（M1.16.0.18.3）**：Page/Widget/Modal/Main Shell 的 BuildScope 遇到非可选 RSUI 组件创建失败时必须拒绝 Commit；`EndBuildScope(..., true)` 会转为逆序 Release/Detach/Hide 回滚并返回失败，Host 随后记录当前 Generation quarantine。仅明确标记 `buildOptional=true` 的能力允许降级；表单 Label/Validation/Toggle/NumericInput/Dropdown 等关键节点必须在构造阶段向上传递具体错误，禁止返回带 nil 关键子节点的半成品组件。
- **Dropdown Lua 5.1 回调捕获契约（M1.16.0.11）**：Option pool 在 `for/ipairs` 中绑定事件时必须把当前 Button/Index 复制到 iteration-local 变量后再建立 closure。目标 Runtime 是 Lua 5.1，禁止假设循环变量会按每次迭代自动捕获；否则所有 Option 可能最终指向循环末项，表现为“排序/下拉点了没反应”。`DropdownContractVersion>=2` 为 Foundation 门禁。


## Foundation Regression Gate / BuildTransaction（M1.16.0.18.18）

- `BuildScopeContractVersion=3`：close-order violation 不能继续污染整个 Generation；框架必须 fail-closed 回滚 requested scope 与所有 leaked descendants，恢复 stack depth，并记录 `buildScopeCloseOrderRecoveries`。Fresh Generation 该指标非 0 即 Foundation Blocker。
- `BuildTransactionContractVersion=1`：PageHost / WidgetHost / ModalHost 使用 `RSUI:WithBuildScope(label, fn)`，异常、nil/false 返回、strict component failure 都自动 Rollback；业务 Host 禁止再复制 Begin/End/xpcall 模板。
- `PreflightContractVersion=1` + `LogicalIdGenerationFenceVersion=1`：`RSUI:Create()` 在 component factory 前先 `ValidateSpec()`；logical ID 一旦通过前检就视为本 Generation consumed，即使后续 rollback/release 也不允许重建同一 Native identity。id/parent 缺失、Table columns 无效、SegmentedSelector items 无效、Numeric slider 无有限 range 必须在 Native allocation 前拒绝。
- 开发封包必须执行 `python3 replicatedsuite/tools/rs_foundation_audit.py`。它补足 Lua Parse 无法发现的 undefined-global / Presentation boundary / Raw Native constructor / raw BuildScope / Lua5.1 stable-capture 回归。新增全局或新的低层 raw-scope 使用需要显式审计与白名单更新，不能靠运行期崩溃发现。
- 低层 WindowShell/MainShell 暂保留 raw BuildScope，是受审计白名单保护的 Foundation builder；任何新 Page/Widget/Modal 不得加入该白名单。
- 全页面真实构建序列（M1.16.0.18.19 follow-up）：`UIV3Acceptance.migratedPresentation` 是当前已迁移页面/悬浮窗/Modal 关联矩阵；Foundation Sequence `v3_37_migrated_page_build_matrix` 在客户端逐路由调用 `Shell:Navigate()` 实际构建当前迁移页面，并遍历 FeatureRegistry 当前 Active Route（planned 路由使用 fallback），再对已迁移 Widget 调用 `WidgetHost:EnsureInstance()`。`v3_39_modal_build_matrix` 另外实际构建两个已迁移 Modal，并对换装设置 Modal 执行 Open/Close 栈事务。Factory 注册和 Lua Parse 只能证明静态覆盖，不能替代这些序列。

## 目录

1. [Replicated Suite RSUI UMG-style Primitive & Panel Framework v1](#sec-1)
2. [Replicated Suite RSUI Adaptive Layout Framework v1](#sec-2)
3. [Replicated Suite RSUI Component Framework v1](#sec-3)
4. [Replicated Suite — RSUI Data View Framework v1](#sec-4)
5. [Replicated Suite RSUI Form Component System v1](#sec-5)
6. [Replicated Suite — RSUI Selection / Tile Data View Framework v1](#sec-6)
7. [Replicated Suite — RSUI Layout Safety / Debugging v1](#sec-7)
8. [Replicated Suite RSUI Foundation Graduation v1](#sec-8)
9. [Replicated Suite RSUI Foundation Audit — M6-v10](#sec-9)

<a id="sec-1"></a>
## 1. Replicated Suite RSUI UMG-style Primitive & Panel Framework v1

> 来源（已合并至本权威文档，原文件已收口）：`replicatedsuite\Docs\Architecture\RSUI\REPLICATED_SUITE_RSUI_UMG_LAYOUT_FRAMEWORK_v1_20260826.md`

## Replicated Suite RSUI UMG-style Primitive & Panel Framework v1

> 日期：2026-08-26  
> BuildTag：`foundation-v2-rsui-umg-layout-p3`  
> 阶段：RSUI Phase 3 — UMG-style Primitive & Panel Framework

### 1. 目标

Phase 3 把 RSUI 的底层开发体验正式调整为接近 Unreal Engine UMG 的“少量基础 Widget + Panel/Slot 自由组合”模型。

重点不是继续增加页面级 Composite，而是先解决长期反复出现的 UI 基础问题：

- 不同分辨率下固定坐标导致重叠；
- 中文/俄文/英文文本宽度不同导致越界；
- 手工 `x = x + ... / y = y + ...` 难以维护；
- 控件宽度变化后相邻控件没有重新分配空间；
- 大窗口看起来松散，小窗口又被挤爆；
- HUD / 设置页各自重新实现布局策略。

正式目标：

```text
业务模块描述 Widget Tree / Slot
            ↓
RSUI Measure
            ↓
DesiredSize
            ↓
Panel Arrange
            ↓
最终 Rect
            ↓
UI Framework Diff
            ↓
ArcheAge Native UI Write
```

### 2. Authority 分层

```text
Native ArcheAge / ArcheRage UI API
        ↓
UI Factory / Native Adapter
        ↓
UI Framework v1
Diff / Lifecycle / Owner / Native Cache
        ↓
RSUI Component Runtime
        ↓
Text Measurement + UMG-like Panel / Slot
        ↓
Primitive / Composite
        ↓
Healer / DPS / Plates / Activity / Trade / ...
```

Phase 3 不建立第二套 Native UI Authority，不绕开现有 `UI:SetExtent / SetAnchor / SetText / Lifecycle`。

### 3. 官方 API 依据

本阶段实现前已核对项目 `z_api_functions/ui_functions.lua`。

文字测量优先使用真实客户端接口：

```text
TextStyle:GetTextWidth(text)
TextStyle:GetLineHeight()
```

RU UI 同时公开：

```text
SetAutoWordwrap
GetTextHeight
GetLineCount
GetLongestLineWidth
SetAutoResize
SetExtent
GetWidth / GetHeight
```

RSUI 当前没有假定所有 Label 都稳定支持同一 Textbox 方法，因此：

1. 单行宽度优先 `TextStyle:GetTextWidth()`；
2. 获取失败时才使用 UTF-8-safe 宽度估算；
3. Wrap 当前由 RSUI 自己生成换行，不依赖某个 RU build 的 Label word-wrap 行为；
4. 不依赖 Native `SetEllipsis(true)` 作为核心正确性机制。

### 4. Component Runtime v3

当前：

```text
RSUI.version = 3
RSUI.apiVersion = 2.0
```

Base Component 新增：

```lua
Component:Measure(AvailableWidth, AvailableHeight)
Component:GetDesiredSize(AvailableWidth, AvailableHeight)
Component:SetSlot(Slot)
```

语义：

```text
Measure
- 只计算 DesiredSize
- 不允许产生 Native Layout Write

Layout / Arrange
- 接收父 Panel 最终分配的 Rect
- 通过现有 Diff Framework 写 Native
```

这是 Phase 3 最重要的布局 Contract。

### 5. 当前 UMG-like 基础 Widget

#### 5.1 Leaf / Primitive

```text
Text
Image
Button
IconButton
Spacer
ProgressBar
Slider
Toggle
SegmentedSelector
NumericInput
Dropdown
```

`Icon` 继续兼容；新业务更推荐语义更接近 UMG 的 `Image`。

#### 5.2 Content / Constraint

```text
Border
SizeBox
```

#### 5.3 Panel

```text
HorizontalBox
VerticalBox
Grid
Overlay
```

#### 5.4 Existing Composite

```text
Card
Section
Form
SettingsPage
...
```

Composite 后续应该逐步变成 Primitive/Panel 的消费者，而不是继续扩张自己的布局 Authority。

### 6. Slot Contract

Panel 子控件使用 `slot = { ... }` 描述布局意图。

通用字段：

```lua
slot = {
    size = "auto" | "fill" | "fixed",
    fill = 1,

    width = 80,
    height = 24,

    minWidth = 1,
    minHeight = 1,

    padding = 4,

    hAlign = "left" | "center" | "right" | "fill",
    vAlign = "top" | "center" | "bottom" | "fill",
}
```

`padding` 也支持：

```lua
padding = {
    left = 4,
    top = 2,
    right = 4,
    bottom = 2,
}
```

### 7. HorizontalBox / VerticalBox

示例：

```lua
local Row = RSUI:HorizontalBox({
    id = "damage_row",
    parent = Parent,
    gap = 6,
    padding = 4,
})

RSUI:Image({
    id = "class_icon",
    parent = Row,
    width = 24,
    height = 24,
    slot = {
        size = "fixed",
        width = 24,
        vAlign = "center",
    },
})

RSUI:Text({
    id = "player_name",
    parent = Row,
    text = Name,
    overflow = "ellipsis",
    slot = {
        size = "fill",
        fill = 1,
        vAlign = "center",
    },
})

RSUI:Text({
    id = "damage_value",
    parent = Row,
    text = DamageText,
    slot = {
        size = "fixed",
        width = 80,
        vAlign = "center",
    },
})
```

结果：

```text
[Icon 24] [Name Fill................] [Damage 80]
```

窗口缩小时：

1. Fixed 保持明确的尺寸语义；
2. Fill 使用剩余空间；
3. Auto 在空间不足时允许压缩到 Min；
4. Text 拿到更窄的最终 Width 后执行安全 Fit；
5. 子控件不再靠业务代码重新计算 x。

### 8. Grid

当前 Grid 支持：

```lua
slot = {
    row = 1,
    column = 1,
    rowSpan = 1,
    columnSpan = 2,
}
```

以及：

```text
columns
columnGap / gapX
rowGap / gapY
padding
```

适用于：

- 活动卡片；
- 设置项多列布局；
- HUD 小块信息；
- 状态面板。

### 9. Overlay

Overlay 所有 Child 使用同一内容区域，并分别按 Alignment 排列。

典型 Aura：

```text
Overlay
├─ Image       图标 / Fill
├─ Text        Stack / Right Bottom
├─ Text        Remaining / Center Bottom
└─ Border      Danger Frame
```

这将成为后续 `AuraSlot / SkillSlot / EquipmentSlot / BossMechanicSlot` 的基础。

### 10. Border

Border 是单 Child Content Widget：

```text
Border
├─ Background / Theme Variant
├─ Padding
└─ Child
```

以后：

```text
Card
Tooltip
Badge
StatusCard
Panel Surface
```

都应该优先由 Border + Panel 组合，而不是各自造布局规则。

### 11. SizeBox

支持：

```text
widthOverride
heightOverride
minWidth
maxWidth
minHeight
maxHeight
hAlign
vAlign
```

它负责表达“这个区域应该有尺寸约束”，从而减少业务模块直接 `SetExtent()`。

### 12. Text Safety Authority

Phase 3 新增 `RSUI.TextLayout`。

当前 Overflow Policy：

```text
ellipsis   默认；UTF-8-safe 宽度拟合
shrink     从 preferredFontSize 降到 minFontSize，仍放不下再 ellipsis
wrap       按真实/估算字体宽度切行，可限制 maxLines
clip       保留原文字，由给定 Widget Rect 裁切
```

#### 12.1 为什么不再按字符数截断

以下文本视觉宽度完全不同：

```text
IIIIIIII
WWWWWWWW
治疗推荐
Replicated
```

因此 Authority 必须是字体宽度，而不是 `#text`。

#### 12.2 UTF-8

Fallback 以 UTF-8 codepoint 遍历，不允许从中文/俄文字符字节中间截断。

#### 12.3 热路径约束

Text fitting / Wrap 只应在：

```text
创建
文本改变
字体改变
布局宽度改变
```

时发生。

禁止为了“保险”在 Tick 中持续调用 `GetTextWidth()` 或重新 Wrap。

### 13. ProgressBar

公共接口：

```lua
local Bar = RSUI:ProgressBar({
    id = "health",
    parent = Parent,
    percent = 0.72,
})

Bar:SetPercent(0.65)
```

Fill Width 继续通过 UI Diff Cache 更新；相同 Percent + 相同 Layout 不重复写 Native。

### 14. Declarative Composition

Phase 2 的 Recursive Builder 继续支持 Slot：

```lua
RSUI:Build(Parent, {
    {
        type = "VerticalBox",
        id = "root",
        children = {
            {
                type = "Text",
                id = "title",
                text = "Replicated Suite",
                slot = { size = "auto" },
            },
            {
                type = "HorizontalBox",
                id = "buttons",
                slot = { size = "fill", fill = 1 },
                children = {
                    {
                        type = "Button",
                        id = "ok",
                        text = "确定",
                        slot = { size = "fill", fill = 1 },
                    },
                    {
                        type = "Button",
                        id = "cancel",
                        text = "取消",
                        slot = { size = "fill", fill = 1 },
                    },
                },
            },
        },
    },
})
```

这不是 Virtual DOM。

创建后 Runtime 仍然更新已有 Component，不允许每帧重建 Descriptor Tree。

### 15. 分辨率策略

Phase 3 的核心原则：

```text
不要通过“为 1024×768 写一套坐标，为 1920×1080 再写一套坐标”解决适配。
```

而应该：

```text
Window / Safe Area 给 Available Size
        ↓
Panel Measure
        ↓
Auto / Fill / Fixed + Min/Max
        ↓
Arrange
        ↓
Text Fit / Wrap
```

1024×768 与 2K 的差异应主要体现在 Available Size，而不是业务控件树完全分叉。

### 16. Diagnostics

`RSUI:GetSnapshot()` 现在额外包含：

```text
layoutCompressionEvents
layoutOverflowEvents
text.measures
text.wraps
text.fits
text.overflows
```

这些是数字 Counter，不在布局热路径拼接日志字符串。

`layoutOverflowEvents` 不应被理解成所有视觉错误；它专门用于发现 Linear Panel 在 Fixed/Min 约束下仍无法容纳内容的情况。

### 17. Phase 3 验证

Mock 已验证：

```text
RSUI registered types = 30

Text Ellipsis Width Safety = PASS
Text Wrap Desired Height = PASS

HorizontalBox 320px = no overlap
HorizontalBox 180px = no overlap
Measure = 0 Native writes
Identical Layout = 0 Native writes

VerticalBox = no overlap
Grid columns/span = PASS
Overlay alignment = PASS
Border padding = PASS
SizeBox bounds = PASS
ProgressBar repeated layout = 0 Native writes
Recursive Builder + Slot = PASS
```

Phase 2 Form Regression：PASS。  
Phase 1 Controls Regression：PASS。  
UI Phase B Slider Preview / Responsive Regression：PASS。  
Healer Settings Preview Purity：PASS。

### 18. 下一阶段

优先继续 UMG 基础层，而不是立即回到业务页面。

推荐 Phase 4：

```text
ScrollBox
UniformGrid
WrapBox
WidgetSwitcher
ScaleBox
CanvasPanel（谨慎使用）

TextBlock advanced wrapping
Rich/Colored inline strategy（只在 RU API 能安全支持时）

Panel invalidation / layout dirty propagation
Layout inspector / overflow diagnostics
```

之后再建设：

```text
VirtualList
Table
AuraSlot
PlayerRow
StatusCard
HUD primitives
```

最终原则：复杂组件必须尽量通过基础 Widget 组合得到。



<a id="sec-2"></a>
## 2. Replicated Suite RSUI Adaptive Layout Framework v1

> 来源（已合并至本权威文档，原文件已收口）：`replicatedsuite\Docs\Architecture\RSUI\REPLICATED_SUITE_RSUI_ADAPTIVE_LAYOUT_FRAMEWORK_v1_20260826.md`

## Replicated Suite RSUI Adaptive Layout Framework v1

> 日期：2026-08-26  
> BuildTag：`foundation-v2-rsui-adaptive-layout-p4`  
> 作用：在 Phase 3 UMG-style Primitive/Panel 基础上补齐跨分辨率自适应 Panel、Viewport、Layout Invalidation 与按需 Layout Inspector。

---

### 1. 本阶段为什么存在

Phase 3 已经建立：

```text
Widget
Panel / Slot
Measure / Arrange
HorizontalBox / VerticalBox
Grid / Overlay
Border / SizeBox
Text / Image / Button / ProgressBar / Slider
```

但实际插件 UI 还需要解决几类高频问题：

1. 小分辨率下图标/按钮应该自动换行，而不是互相覆盖；
2. 卡片型内容应该自动改变列数；
3. 页面过长时必须有安全滚动容器；
4. 多页面内容不能让非活动页继续参与显示；
5. 复杂内容需要 Scale-to-fit 能力；
6. Slot 运行时变化应该自动触发布局重算；
7. UI 出现越界时需要可诊断，而不是靠肉眼猜。

因此 Phase 4 不新增业务页面，而继续完善 RSUI Foundation。

---

### 2. Authority 边界

```text
ArcheAge / ArcheRage Native UI
        ↓
UI Factory / Native Adapter
        ↓
UI Framework Diff / Lifecycle / Native Cache
        ↓
RSUI Component Runtime
        ↓
UMG-like Primitive + Panel + Slot
        ↓
Adaptive Panels / Viewport / Inspector
        ↓
Composite UI / Domain UI
```

规则：

- Adaptive Panel 不能直接绕过 `UI:SetExtent / SetAnchor / SetVisible / SetScale` Diff Authority；
- 不建立第二套 Window Authority；
- 不建立第二套 Settings/Persistence Authority；
- 不在 Tick 中执行 Layout Inspector；
- ScrollBox 不假设 RU 客户端存在未验证的通用 clipping rectangle；
- 所有复杂 UI 仍应优先通过基础 Widget 组合产生。

---

### 3. 新增组件

Phase 4 新增 5 个公共类型：

```text
UniformGrid
WrapBox
ScrollBox
WidgetSwitcher
ScaleBox
```

当前 RSUI 注册类型总数：

```text
35
```

---

### 4. UniformGrid

面向活动卡片、技能格、装备格、图标阵列等“每个 Cell 尺寸统一”的场景。

示例：

```lua
local Grid = RSUI:UniformGrid({
    id = "activity_grid",
    parent = Parent,
    minCellWidth = 120,
    maxColumns = 4,
    columnGap = 8,
    rowGap = 8,
})
```

当父区域变窄时：

```text
大宽度：4 列
中宽度：3 列
小宽度：2 列
更小：1 列
```

不要求业务层自己计算：

```lua
column = index % columns
x = startX + column * width
```

支持：

```text
columns（显式固定列数）
minCellWidth（自动列数）
minCellHeight
maxColumns
cellWidth / cellHeight
row / column（可选显式 Slot）
Padding
Alignment
```

---

### 5. WrapBox

适合：

```text
Buff 图标
技能按钮
标签 Chips
快捷入口
动态数量按钮组
```

示例：

```lua
local Wrap = RSUI:WrapBox({
    id = "buff_wrap",
    parent = Parent,
    itemGap = 6,
    lineGap = 6,
})
```

子项无法继续放入当前行时自动换行。

默认：

```text
hideOverflow = true
```

这是为了适配 RU UI 没有经过验证的通用 Panel clipping 行为：当父容器高度严重不足时，宁可隐藏完整溢出行，也不允许其直接绘制到邻近 UI 上。

如果业务明确希望允许溢出：

```lua
hideOverflow = false
```

---

### 6. ScrollBox

当前实现为：

```text
safe item-snapped viewport
```

而不是假设存在类似 Slate `SScrollBox` 的完整像素裁剪。

RU 官方 allowlist 已确认存在：

```text
EnableScroll(enable)
OnWheelUp / OnWheelDown handler
```

但没有足够项目证据证明所有 Widget 类型都提供稳定、统一的任意矩形裁剪。

因此当前 ScrollBox 采取更安全的方式：

```text
逻辑 child.visible = true
        ↓
ScrollBox viewportVisible = false/true
        ↓
Native Show(false/true)
```

也就是说：

> “滚出视口”不会改变业务层的 Visible 语义。

公开接口：

```lua
Scroll:SetScrollOffset(index)
Scroll:ScrollBy(delta)
Scroll:ScrollToTop()
Scroll:ScrollToBottom()
Scroll:EnsureChildVisible(childOrId)
Scroll:GetMaxOffset()
```

滚动由事件驱动，不存在 Tick Poll。

Bottom Offset 会根据当前视口重新计算，避免滚到最后时只剩一条内容而上方空出大块区域。

---

### 7. WidgetSwitcher

对应 UMG 常见的 WidgetSwitcher 思维。

```lua
local Pages = RSUI:WidgetSwitcher({
    id = "pages",
    parent = Parent,
    activeIndex = 1,
})
```

切换：

```lua
Pages:SetActiveIndex(2)
Pages:SetActiveWidget("settings_page")
```

关键规则：

```text
Logical Visible
!=
Viewport Visible
```

非活动页只做 Presentation Hide，不篡改业务层 Visible 状态。

支持：

```text
measureMode = "active"
measureMode = "largest"
```

---

### 8. ScaleBox

支持：

```text
scaleToFit
scaleToFitX
scaleToFitY
fill
none
```

以及：

```text
scaleDirection = both
scaleDirection = downOnly
scaleDirection = upOnly
```

RU allowlist 已确认 UiObject 存在：

```text
SetScale(scale)
```

UI Framework 新增缓存：

```lua
UI:SetScale(widget, scale, owner)
```

因此相同 ScaleBox 布局再次执行：

```text
0 duplicate SetScale native writes
```

如果某一特定 Widget 类型没有 `SetScale`，ScaleBox 会退化到安全 Layout Fit，而不是直接放任内容越界。

仍需 ArcheRage RU 客户端实测不同原生 Widget 类型的 Scale anchor 行为。

---

### 9. Panel Slot 现在是运行时 Contract

Phase 3 的 `slot={...}` 主要在创建阶段读取。

Phase 4 后：

```lua
Child:SetSlot({
    size = "fill",
    fill = 1,
    hAlign = "fill",
})
```

会通知父 Panel：

```text
UpdateChildSlot
    ↓
InvalidateMeasure
    ↓
Parent propagation
    ↓
下一次 Layout 使用新 Slot
```

这是 UMG/Slate 风格布局体验的重要基础。

---

### 10. Layout Invalidation

Component 新增：

```lua
Component:InvalidateLayout(reason)
Component:InvalidateMeasure(reason)
Component:IsLayoutDirty()
```

失效沿父组件树向上传播，但只有从 clean → dirty 时才增加主要 invalidation Counter，避免重复失效制造无意义诊断噪音。

会触发 Measure Invalidation 的典型操作：

```text
AddChild
Slot change
Logical Visibility change
Text change
Font size change
WidgetSwitcher active page change
```

这是后续实现“只重新布局真正 Dirty 的树”的前置基础。

本阶段没有引入每帧自动 reconciliation。

---

### 11. Viewport Visibility

Component 现在区分：

```text
visible          = 业务/逻辑可见性
viewportVisible  = 当前容器允许显示
```

最终 Native 可见性：

```text
visible && viewportVisible
```

使用者通常不应直接操作 `viewportVisible`。

它由：

```text
ScrollBox
WidgetSwitcher
WrapBox safe overflow
```

等容器负责。

---

### 12. Text Measurement 修正

RU `TextStyle:GetTextWidth(text)` 按当前 Native Font 测量。

Phase 3 的 `ShrinkToFit` 在探测候选更小 FontSize 时，如果直接重复调用 `GetTextWidth()`，原生样式尚未切换字号，可能得到相同宽度。

Phase 4 修正为：

```text
Native measured width
× requestedFont / appliedFont
```

因此 `ShrinkToFit` 现在真正按候选字号估算宽度，同时仍然不会为了 Measure 临时反复写 Native FontSize。

Text Component 也会记录：

```text
state.textOverflow
state.displayText
state.wrappedLines
```

供 Inspector 使用。

---

### 13. Layout Inspector

新增按需接口：

```lua
local Report = RSUI:InspectLayout(Component, {
    maxNodes = 160,
    maxDepth = 16,
})
```

返回：

```text
rows
issues
nodeCount
issueCount
truncated
```

每个节点可看到：

```text
id / kind
x / y / width / height
desiredWidth / desiredHeight
logical visible
viewport visible
measureDirty / layoutDirty
overflow
invalidationReason
```

当前 Issue 类型包括：

```text
overflow
text_overflow
x_out_of_bounds
y_out_of_bounds
```

ScaleBox 子项会按实际 appliedScale 计算有效边界，避免 Inspector 把“缩放后的安全内容”误报为越界。

Inspector 是纯读取：

```text
0 Native UI writes
```

严禁从 Tick 自动扫描完整 UI Tree。

后续可以在 Diagnostics Debug Mode 上做可视化边框 Overlay，但那应是显式开启的调试工具。

---

### 14. Diagnostics

`RSUI:GetSnapshot()` 新增/继续提供：

```text
layoutCompressionEvents
layoutOverflowEvents
invalidations
inspectorScans
wrapEvents
scrollChanges
switchChanges
text.measures
text.wraps
text.fits
text.overflows
```

Diagnostics 页面和完整诊断报告现在直接展示：

```text
RSUI 压缩
越界
失效
滚动
```

依然只在事件/布局路径增加数字 Counter，不在热路径拼接复杂文本。

---

### 15. Phase 4 Mock 验证

验证结果：

```text
RSUI types = 35

Panel Slot runtime mutation = PASS
Slot mutation invalidates parent = PASS

UniformGrid responsive columns = PASS
UniformGrid child bounds = PASS

WrapBox auto wrap = PASS
WrapBox narrow layout no overlap = PASS

WidgetSwitcher active visibility = PASS
Logical Visible preserved = PASS

ScaleBox scaleToFit = PASS
Identical ScaleBox layout = 0 Native writes

ScrollBox item viewport = PASS
Offscreen child hidden = PASS
Logical Visible preserved = PASS
Wheel event changes offset = PASS

Text → parent Measure invalidation propagation = PASS
Layout Inspector = PASS
Inspector native writes = 0
```

回归：

```text
RSUI Phase 1 Controls = PASS
RSUI Phase 2 Forms = PASS
UI Phase B Responsive / Slider Preview = PASS
Healer Settings Preview Purity = PASS
```

完整 Suite Lua：

```text
161
syntax failure = 0
```

---

### 16. 当前 UMG-like Foundation 状态

现在基础积木已覆盖：

```text
Leaf
├─ Text
├─ Image
├─ Button / IconButton
├─ Spacer
├─ ProgressBar
├─ Slider
├─ NumericInput
└─ Toggle / Dropdown

Single Child / Decorator
├─ Border
├─ SizeBox
└─ ScaleBox

Panel
├─ HorizontalBox
├─ VerticalBox
├─ Grid
├─ UniformGrid
├─ WrapBox
├─ Overlay
├─ ScrollBox
└─ WidgetSwitcher
```

后续复杂组件应优先由这些基础组件组合：

```text
Card
Section
Field
AuraSlot
SkillSlot
PlayerRow
StatusCard
ListRow
```

而不是直接新增特殊 Native UI 代码。

---

### 17. 下一阶段建议

基础 Panel 已接近可用状态，下一步建议继续完成“布局可靠性”而非马上大规模迁移业务：

#### Phase 5 — Layout Safety / Debugging

```text
CanvasPanel（限定用途）
SafeZone / Resolution Root
Min/Max / AspectRatioBox
Visibility: Visible / Hidden / Collapsed 语义
Layout invalidation execution helper
Layout Inspector Debug Overlay
Screen-bound / overflow assert helpers
Text wrap word-boundary improvement
```

然后进入：

#### Phase 6 — Data / HUD Composition

```text
VirtualList
Reusable List Row Pool
Table
AuraSlot
PlayerRow
StatusRow
HUD IconSlot
CastBar / HealthBar
```

原则保持不变：

> 先把 UI Foundation 做到“组合简单、跨分辨率稳定、出了问题能诊断”，再让 Healer / Plates / DPS 等业务大量迁入。



<a id="sec-3"></a>
## 3. Replicated Suite RSUI Component Framework v1

> 来源（已合并至本权威文档，原文件已收口）：`replicatedsuite\Docs\Architecture\RSUI\REPLICATED_SUITE_RSUI_COMPONENT_FRAMEWORK_v1_20260826.md`

## Replicated Suite RSUI Component Framework v1

> 日期：2026-08-26  
> BuildTag：`foundation-v2-rsui-components-p1`  
> 阶段：RSUI Component Framework Phase 1

### 1. 目标

RSUI 的目标不是为某一个 Healer / DPS / Plates 页面做“统一皮肤”，而是在 ArcheAge / ArcheRage RU 有限的 Native UI API 上建立一套 Replicated Suite 自己长期复用的 UI 组件平台。

业务模块的目标调用方式：

```lua
local Button = ReplicatedSuite.RSUI:Button({
    id = "example_apply",
    parent = Parent,
    text = "应用",
    onClick = function(Component)
        -- business action
    end,
})
```

而不是继续在每个模块中重复：

```text
CreateChildWidget
SetExtent
AddAnchor
SetText
Show
Enable
SetHandler
```

### 2. Authority 分层

正式分层：

```text
ArcheAge / RU Native UI API
        ↓
UI Factory / Native Adapter
        ↓
UI Framework v1
Diff / Lifecycle / Owner / Native State Cache
        ↓
UI Framework v2
Tokens / Layout / Binding / WindowShell / Bound Fields
        ↓
RSUI Component Runtime
        ↓
Primitive / Controls / Containers / Future HUD & Data Components
        ↓
Healer / DPS / Plates / Activity / Trade / ...
```

#### 2.1 UI Factory 继续是 Native Widget Adapter

`rs_ui_factory.lua` 不被 RSUI 替代。

Phase 1 新增 `CreateEmptyWidget()`，目的是让无样式 Primitive Host 也继续经过 Factory 的：

- physical id；
- owner inheritance；
- registration；
- pickability；
- NativeState Diff priming。

#### 2.2 UI Framework v1 继续是 Diff / Lifecycle Authority

RSUI 不创建第二套 Diff Cache，也不假装存在通用 Native Destroy。

组件的 `Release()` 只负责逻辑释放 / 隐藏；最终 Handler Release 与 owner teardown 仍由现有 UI Lifecycle 负责。

#### 2.3 Theme / Tokens 继续是视觉 Authority

业务组件只使用 semantic tone / component tokens。

不鼓励业务页继续散落 RGBA、固定高度、固定间距。

### 3. 公共入口

```lua
ReplicatedSuite.RSUI
ReplicatedSuite.UI.RSUI
```

当前 API Version：

```text
1.0
```

Component Framework Version：

```text
1
```

### 4. Phase 1 标准组件

当前注册 13 种标准类型：

```text
Primitive
├─ Text
├─ Panel
├─ Divider
└─ Icon

Action
├─ Button
└─ IconButton

Controls
├─ Toggle
├─ NumericInput
├─ Slider
└─ Dropdown

Containers
├─ Card
├─ Section
└─ SettingsPage
```

统一构造方式：

```lua
RSUI:Create("Button", Spec)
```

以及 convenience API：

```lua
RSUI:Text(Spec)
RSUI:Panel(Spec)
RSUI:Divider(Spec)
RSUI:Icon(Spec)
RSUI:Button(Spec)
RSUI:IconButton(Spec)
RSUI:Toggle(Spec)
RSUI:NumericInput(Spec)
RSUI:Slider(Spec)
RSUI:Dropdown(Spec)
RSUI:Card(Spec)
RSUI:Section(Spec)
RSUI:SettingsPage(Spec)
```

除 `SettingsPage` 可自动创建 WindowShell 外，普通组件必须显式提供：

```text
id
parent
```

禁止依赖随机 ID / 创建顺序生成 ID。

### 5. Component Contract

标准 Component 最低拥有：

```text
id
kind
root
parent
owner
visible
enabled
released
children
state
```

基础方法：

```lua
Component:GetRoot()
Component:GetOwner()
Component:SetVisible(Value)
Component:SetEnabled(Value)
Component:SetSemanticState(State)
Component:SetBounds(X, Y, Width, Height)
Component:Layout(X, Y, Width, Height)
Component:Render(State)
Component:AddChild(Child)
Component:Release()
Component:Describe()
```

统一 Semantic State vocabulary：

```text
normal
selected
disabled
error
readonly
```

Native Button 自身的 Hover / Pressed 动画仍由客户端按钮实现负责，RSUI 不在 Tick 中重复做 Hover 动画。

### 6. Event Contract

组件事件必须经过：

```text
Component:On()
    ↓
UI:SafeHandler()
    ↓
Generation Guard
Performance Monitor
xpcall / SafeTraceback
Lifecycle Handler Registry
```

因此业务组件不应该自行对标准组件 root 再直接 `SetHandler()`。

### 7. Binding Contract

Controls 支持：

```lua
binding = ExistingBinding
```

或：

```lua
get = function() ... end
set = function(Value, Final, Source) ... end
normalize = ...
validate = ...
commit = ...
autoCommit = ...
```

RSUI 继续调用现有 `CreateSettingBinding()`；不建立第二套 Setting State Authority。

#### 7.1 Slider Preview Fence

标准 `RSUI:Slider()` 明确保持：

```text
Drag Preview (final=false)
    → 只更新组件预览
    → onPreview
    → 0 Binding Set
    → 0 Domain Write

Drag Final (final=true)
    → Binding Set once
    → optional Commit
    → onChanged
```

这条规则与 Phase B1 Numeric Field 一致，避免 50ms 拖动采样变成 Persistence 热路径。

### 8. Dropdown Lifecycle / Native Authority

M1.16.0.3 起，Active V3 `RSUI:Dropdown()` **禁止依赖** Legacy `S.Dropdown` / `CreateEmptyWindow`。标准结构为：

```text
RSUI Dropdown Component
├─ Trigger        -> parent page/card，NativeObjectFactory
└─ Popup          -> physical parent = UIParent
   ├─ Option pool -> 固定上限，按需复用
   ├─ Scroll up
   └─ Scroll down
```

Popup 物理 parent 到 `UIParent` 是 z-order / clipping 的 Presentation 需求，不代表其逻辑 Authority 变成全局：

```text
Trigger.rsUiOwner (v3:...)
    ↓ explicit owner
UI:CreatePanel(UIParent, ..., { owner = Trigger owner })
    ↓ Register(strict V3 identity)
Popup.rsUiOwner = Trigger owner
    ↓
Option children inherit same owner
```

关键约束：

- `UI:CreatePanel()` 必须在 `Register()` **之前**应用 explicit owner；禁止先以无 owner/Legacy 身份注册再补 owner。
- Popup geometry/text/visible/enabled/pickable 走 `UI Diff Authority`；不允许业务页直接反复写 Native 状态。
- Option rows 使用创建时固定池（当前 `maxVisible` 上限 16），`SetItems()` 只重绑内容并保留当前 top anchor；刷新不会制造 Native widget churn。
- Option pool 的 OnClick closure 必须捕获 `optionButton/optionIndex` 的 iteration-local 副本，不能直接闭包引用 Lua 5.1 的 `for` 循环变量；这是 Dropdown Contract v2 的组成部分。
- Dropdown 交互完全事件驱动；禁止 Tick/OnUpdate 常驻轮询。
- **RU root-parent 构造契约（M1.16.0.5）**：业务/RSUI 可以传 `UIParent` object 或 `"UIParent"`，但进入 NativeObjectFactory 后必须归一为字面量 `"UIParent"` 再调用 `UIParent:CreateWidget()`；禁止各 Primitive 自行猜测 RU root 参数形态。
- **Active UI Adapter 契约（M1.16.0.6）**：V3 不能依赖未加载的 Legacy `rs_ui_factory.lua` 方法。`TrySetUILayer` 属于 Active Native Primitive Adapter 的可选 capability：先检查方法存在，再以 `pcall` 调 `widget:SetUILayer()`；失败只返回 `false`，Dropdown 继续使用 DrawPriority/普通层级，不得回滚整个页面。
- **功能降级契约**：Dropdown trigger 已成功创建后，popup/滚动按钮/option pool 任一失败不得让页面 Factory 返回 nil；组件改为 `rsUiDegraded` 单按钮循环选择并记录 `RSUI_DROPDOWN_DEGRADED`。只有 trigger 本身无法 Native 构造时才允许 Dropdown 创建失败。
- `RSUI.DropdownService` 使用弱引用登记实例；打开一个会关闭其他 popup；PageHost 路由切换以及 Shell 关闭/最小化都会关闭 transient popup。
- RSUI Component ID 与 FloatingSurface/Page 控件 ID 必须全局唯一；`id` 是 V3 逻辑 ownership identity，不是显示标签。

### 9. Icon Diff

新增：

```lua
UI:SetIconTexture(Drawable, Path, Owner)
```

RU IconDrawable 常用：

```text
ClearAllTextures
AddTexture
```

RSUI 将 texture path 放入现有 NativeState Cache；同一路径重复 Render 不再次 Clear/Add。

这为后续 AuraSlot / SkillRow / PlayerRow / HUD IconSlot 提供底层准备。

### 10. SettingsPage

`RSUI:SettingsPage()` 是第一版平台级页面容器。

无 parent 时：

```text
SettingsPage
    ↓
WindowShellV2
    ↓
ManagedWindow
```

因此继续复用：

- placement；
- safe screen bounds；
- resize；
- title bar；
- close；
- footer/status；
- lifecycle。

它不会建立第二个 Window Authority。

示例：

```lua
local Page = RSUI:SettingsPage({
    id = "demo_settings",
    title = "Demo Settings",
    width = 620,
    height = 520,
})

local General = Page:AddSection({
    id = "demo_general",
    title = "常用",
    height = 160,
})

General:Add(RSUI:Toggle({
    id = "demo_enabled",
    parent = General.root,
    get = function() return Model.enabled end,
    set = function(Value)
        return Presenter:SetEnabled(Value)
    end,
}))
```

### 11. Declarative Build

Phase 1 提供轻量 descriptor builder：

```lua
local Items = RSUI:Build(Parent, {
    {
        type = "Text",
        id = "demo_title",
        text = "标题",
    },
    {
        type = "Button",
        id = "demo_button",
        text = "确定",
    },
})
```

它只做创建分发，不引入 React/Vue 式虚拟树，也不会每帧重建 descriptor tree。

### 12. Diagnostics

`UI:GetFrameworkSnapshot().design` 新增：

```text
rsui.version
rsui.apiVersion
rsui.registeredTypes
rsui.created
rsui.rendered
rsui.layouts
rsui.events
rsui.releases
rsui.errors
rsui.byType
```

完整诊断报告与 Diagnostics Page 已展示 RSUI 创建量 / 类型数 / 错误数。

热路径仍只累计数字 Counter，不在 Render 中拼大型字符串。

### 13. 性能规则

RSUI Phase 1 明确禁止：

- 在 Tick 中重新创建标准 Component；
- 为 Hover/Pressed 建立持续 Lua 动画；
- Slider Preview 每 50ms 写 Domain / SaveData；
- 相同 Icon Path 重复 Clear/Add texture；
- 绕过 Diff 反复 SetText / Anchor / Extent；
- 用 UI Component 保存业务 Authority State；
- 让 SettingsPage 建立第二套 Window Manager。

Component tree 创建属于低频 UI construction；Runtime/HUD 高频状态必须更新现有组件，而不是重建组件。

### 14. 与 Phase B1 Bound Fields 的关系

Phase B1 没有废弃。

它验证了：

- BindingV2；
- ResponsiveGrid；
- Numeric Preview Fence；
- Settings Model Validate；
- Field Error State。

但是其 `CreateToggleFieldV2/CreateNumericFieldV2/...` 当前仍属于旧 v2 composition API。

新的长期方向是：

```text
RSUI = public reusable component API
Healer = first consumer / regression sample
```

后续阶段会逐步把 Bound Field、Form、HUD、List 等也接入 RSUI public facade，而不是继续扩大两套并行 API。

### 15. 下一阶段

推荐 Phase 2：

```text
RSUI Form Components
├─ Field
├─ ToggleField
├─ NumericField
├─ DropdownField
├─ ValidationMessage
├─ FieldGroup
└─ FormSection
```

并把 B1 Bound Fields 通过 adapter 收敛到 RSUI public facade。

随后 Phase 3：

```text
Data / Collection
├─ Row
├─ StatusRow
├─ StatCard
├─ ScrollList
└─ VirtualList
```

Phase 4：

```text
HUD
├─ HUDText
├─ IconSlot
├─ AuraSlot
├─ Marker
├─ CastBar
├─ HealthBar
└─ OverlayGroup
```

### 16. 当前结论

Phase 1 完成的是“组件平台入口”，而不是某个页面的视觉重构。

从现在开始，新业务 UI 应先检查 RSUI 是否已有标准组件；只有 RSUI 缺失能力时才扩展 Framework，避免 Healer / DPS / Plates 各自继续造同类控件。



<a id="sec-4"></a>
## 4. Replicated Suite — RSUI Data View Framework v1

> 来源（已合并至本权威文档，原文件已收口）：`replicatedsuite\Docs\Architecture\RSUI\REPLICATED_SUITE_RSUI_DATA_VIEW_FRAMEWORK_v1_20260826.md`

## Replicated Suite — RSUI Data View Framework v1

> 日期：2026-08-26  
> BuildTag：`foundation-v2-rsui-data-views-p6`  
> 阶段：RSUI Phase 6 — ListView / VirtualList / Row Pool / Table Layout

### 1. 目标

Phase 6 把 UE5 UMG `ListView` 一类“大数据、小可见窗口”的开发方式引入 RSUI。

核心目标不是做更多业务页面，而是解决以下基础问题：

- DPS / 玩家 / 任务 / Aura Manager 等列表可能拥有几十到数百条数据；
- 不能因为数据有 500 条就创建 500 个 Native Widget；
- 滚动时不应该整表重建；
- 同一列在 Header 与各 Row 之间必须保持稳定宽度；
- 小分辨率压缩时必须优先缩列并让 Text Ellipsis，而不是互相覆盖；
- 数据刷新与 UI 创建/绑定要显式、可诊断，不能偷偷进入 Tick。

因此正式建立：

```text
Data Source
    ↓
VirtualList / ListView
    ↓
Bounded Row Pool
    ↓
Visible + small Overscan window
    ↓
RSUI Row Components
    ↓
Native Diff / Lifecycle
```

### 2. Authority

#### 2.1 数据 Authority 不属于 ListView

`ListView` 只保存数据表引用或读取回调：

```lua
items = Items
```

或：

```lua
getCount = function()
    return Model:GetCount()
end

getItem = function(Index)
    return Model:Get(Index)
end
```

RSUI 不复制业务数据，也不成为第二份 Model。

#### 2.2 Row Pool 是 Presentation Authority

Row Pool 只负责：

- 创建有限数量的 Row；
- 保存 Pool Slot → Logical Item Index 映射；
- 滚动后复用 Row；
- 调用 `bindRow` 更新可见数据；
- 隐藏不在 Viewport 的 Pool Row。

业务状态仍属于 Domain / Presenter。

### 3. 固定行高 v1

Phase 6 v1 明确采用固定 `rowHeight`。

原因：

```text
index → y
```

可以 O(1) 计算，并且：

- 不需要扫描所有历史 Row 高度；
- 不需要维护大型 prefix-sum table；
- ScrollOffset 可以稳定使用 Item Index；
- 1024×768 下更容易保证无重叠；
- Row Pool Capacity 可以直接从 Viewport 计算。

变量行高可在未来单独设计，不能破坏当前固定行高快速路径。业务自定义 Row 也必须服从 ListView 分配的固定高度；长文本应使用 Ellipsis/Shrink 或在进入列表前整理展示数据，不能让单个 Row 自行撑高后覆盖下一行。

### 4. Row Pool

假设：

```text
数据：500 条
Viewport：可见 12 行
Overscan：1
```

理论 Pool 只需要约：

```text
12 + 1 + 1 = 14 Rows
```

而不是：

```text
500 Rows
```

Phase 6 默认：

```text
overscan    = 1
maxPoolSize = 96
```

并设置硬上限，避免异常配置导致一次创建大量 Native Widget。

### 5. 滚动复用

VirtualList 不按 Pool Index 固定绑定数据。

它维护：

```text
Logical Index → Pool Slot
```

当：

```text
1..12
```

滚到：

```text
2..13
```

仍在目标窗口中的 Row 会继续保留原绑定。

只有新进入窗口的数据才需要重新绑定。

因此滚动 1 行时，目标是：

```text
大部分 Row = Reuse
新 Row       = 约 1 Bind
```

而不是让 12 个 Row 全部重新写一次。

### 6. Data Revision

RSUI 不对大型 Item Table 做 Deep Compare。

数据原地修改后，由 Presenter 显式调用：

```lua
List:RefreshVisible(Revision)
```

或者只刷新一项：

```lua
List:InvalidateItem(Index)
```

`SetItems()` 也会推进 revision。

原则：

> 大数据同步使用显式 Revision / Dirty Signal，而不是每帧遍历比较所有数据。

### 7. ListView API

简单文本列表：

```lua
local List = RSUI:ListView({
    id = "activity_list",
    parent = Parent,
    items = Activities,
    rowHeight = 28,
    overscan = 1,
    itemText = function(Item)
        return Item.name
    end,
})
```

复杂 Row：

```lua
local List = RSUI:ListView({
    id = "player_list",
    parent = Parent,
    items = Players,
    rowHeight = 32,

    rowFactory = function(ListView, PoolIndex)
        return RSUI:HorizontalBox({
            id = "player_pool_row_" .. PoolIndex,
            parent = ListView,
        })
    end,

    bindRow = function(Row, Item, Index)
        Row.Name:SetText(Item.name)
        Row.Damage:SetText(Item.damageText)
    end,
})
```

主要运行时 API：

```text
SetItems
SetDataSource
RefreshVisible
InvalidateItem
SetScrollOffset
ScrollBy
ScrollToTop
ScrollToBottom
ScrollToIndex
EnsureIndexVisible
ForEachPooledRow
GetPoolStats
```

### 8. Logical Visibility 与 Viewport Visibility

Pool Row 进入/离开 Viewport 时使用：

```text
SetViewportVisible()
```

不会调用：

```text
SetVisible(false) → Collapsed
```

因此滚动不会篡改业务控制的 `Visible / Hidden / Collapsed` 状态。

该规则与 Phase 4 ScrollBox / WidgetSwitcher 保持一致。

### 9. TableView

Phase 6 在 VirtualList 上建立 TableView：

```text
TableView
├─ TableRow (Header)
└─ ListView
   ├─ pooled TableRow
   ├─ pooled TableRow
   └─ ...
```

示例：

```lua
local Table = RSUI:TableView({
    id = "dps_table",
    parent = Parent,
    rowHeight = 28,

    columns = {
        { id = "rank", title = "#", width = 36 },
        { id = "name", title = "玩家", size = "fill", minWidth = 80 },
        { id = "damage", title = "伤害", width = 100, field = "damageText" },
        { id = "percent", title = "%", width = 60, field = "percentText" },
    },

    items = Rows,
})
```

### 10. Column Width Authority

列宽只由 TableView 父级统一解析。

```text
TableView Available Width
        ↓
ResolveColumnWidths()
        ↓
Resolved Width Array
        ↓
Header + every pooled Row
```

不能让每一个 Row 根据自己的字符串重新决定列宽。

否则会出现：

- Header 与 Row 错位；
- 滚动后列宽抖动；
- 长名字突然把其他列推走；
- 不同分辨率下重叠。

Column 支持：

```text
fixed
fill
auto
minWidth
maxWidth
absoluteMinWidth
fillWeight
```

空间不足时先做有界压缩，Text 继续使用 RSUI Ellipsis。若极端宽度连正常最小列宽之和都放不下，Table 会进入 emergency clamp：宁可把列压到正常最小值以下，也不允许列互相覆盖。

### 11. Table Row 文本策略

Table v1 的默认 Cell 是 `RSUI.Text`：

```text
overflow = ellipsis
```

因此列宽 Authority 稳定后，过长内容只影响自己：

```text
ReplicatedVeryLongName → ReplicatedVery…
```

不会把右侧数值列顶出窗口。

高级图标、进度条、按钮等 Cell 后续可以通过自定义 `rowFactory / bindRow` 扩展，不需要把 TableView 变成业务 Authority。

### 12. 性能规则

严格禁止：

```text
Tick → 遍历全部 Item
Tick → 创建 Row
Tick → 全部重新 Bind
Scroll → Destroy/Create Row
```

允许：

```text
SetItems       → Reconcile visible pool
Scroll         → Reconcile bounded pool
Resize/Layout  → recompute viewport capacity
Revision       → rebind currently pooled rows
```

整个数据集可以很大，但 Native Widget 数量由 Viewport 控制。

### 13. Diagnostics

新增 RSUI Metrics：

```text
virtualPoolRowsCreated
virtualRowBinds
virtualRowReuses
virtualReconciles
virtualDataRefreshes
virtualVisibleRowsPeak
tableColumnResolves
tableEmergencyClamps
```

用于判断：

- 有没有因为滚动反复创建 Row；
- 滚动一步是不是整池重绑；
- Pool 是否异常膨胀；
- 可见行峰值是多少；
- Table 是否在异常频率重算列宽。

这些仍然只是轻量 Counter，不在热路径构造大型字符串。

### 14. 与现有 ScrollBox 的关系

`ScrollBox` 与 `ListView` 都继续保留。

#### ScrollBox

适合：

```text
少量、异构、真实 Child Widget
```

例如设置页面中 20 个不同 Section。

#### ListView / VirtualList

适合：

```text
大量、同构 Row 数据
```

例如：

- DPS 排行；
- 玩家列表；
- 技能伤害明细；
- Activity/Quest 大列表；
- Aura Manager；
- Diagnostics 长列表。

不要为了“统一”把 ScrollBox 删除。

### 15. 后续方向

Phase 6 后可以继续：

```text
TileView / VirtualGrid
Selection Model
Keyboard Navigation
Sortable Table Header
Resizable Column Grip
Row Hover / Alternating Background
EmptyState / LoadingState
```

但必须继续遵守：

> Native Widget 数量由 Viewport 决定，数据量不能直接决定 Native Widget 数量。



<a id="sec-5"></a>
## 5. Replicated Suite RSUI Form Component System v1

> 来源（已合并至本权威文档，原文件已收口）：`replicatedsuite\Docs\Architecture\RSUI\REPLICATED_SUITE_RSUI_FORM_COMPONENT_SYSTEM_v1_20260826.md`

## Replicated Suite RSUI Form Component System v1

> 日期：2026-08-26  
> BuildTag：`foundation-v2-rsui-forms-p2`  
> 阶段：RSUI Component Framework Phase 2

### 1. 目标

Phase 2 把设置页常用的“字段 / 表单 / 校验 / 响应式布局”正式提升为 **RSUI 平台公共能力**。

业务模块的目标代码不再直接处理：

```text
CreatePanel / CreateLabel / CreateButton / CreateSlider
Anchor / Extent / Label Width / Feedback Width
Binding Error / Dirty / Preview / Responsive Columns
```

而是声明：

```lua
local Form = RSUI:Form({
    id = "example_form",
    parent = Page,
    sections = {
        {
            id = "general",
            title = "常用",
            fields = {
                {
                    type = "ToggleField",
                    id = "enabled",
                    label = "启用",
                    binding = EnabledBinding,
                },
                {
                    type = "NumericField",
                    id = "distance",
                    label = "治疗距离",
                    min = 10,
                    max = 50,
                    step = 1,
                    binding = DistanceBinding,
                },
                {
                    type = "DropdownField",
                    id = "curve",
                    label = "距离曲线",
                    options = CurveOptions,
                    binding = CurveBinding,
                },
            },
        },
    },
})
```

### 2. Authority 分层不变

```text
ArcheAge / RU Native UI
        ↓
UI Factory / Native Adapter
        ↓
UI Framework v1 Diff + Lifecycle + Native Cache
        ↓
Tokens / LayoutV2 / BindingV2 / WindowShellV2
        ↓
RSUI Component Runtime
        ↓
RSUI Form Component System
        ↓
Domain Modules
```

Phase 2 **没有**建立：

- 第二套 Window Authority；
- 第二套 Binding State；
- 第二套 Native Diff Cache；
- 每帧 Virtual DOM / reconciliation；
- Form 自己的 Persistence Store。

### 3. RSUI Runtime v2

Phase 2 将：

```text
RSUI.version = 2
RSUI.apiVersion = 1.1
```

#### 3.1 Component 可以直接作为 parent

现在允许：

```lua
local Panel = RSUI:Panel({
    id = "example_panel",
    parent = NativeParent,
})

local Text = RSUI:Text({
    id = "example_text",
    parent = Panel,
    text = "Hello",
})
```

业务层不再需要：

```lua
parent = Panel.root
```

RSUI 内部通过：

```text
Component parent
    ↓
GetContentRoot()
    ↓
Native parent
```

解析真实 Native parent，同时自动保存：

```text
child.parentComponent
parent.children
```

用于 Release / Diagnostics / 后续组合布局。

#### 3.2 Declarative Builder 支持 children

```lua
RSUI:Build(Parent, {
    {
        type = "Panel",
        id = "root",
        children = {
            {
                type = "Text",
                id = "title",
                text = "标题",
            },
        },
    },
})
```

这是 **低频创建期 Builder**，不是每帧生成 descriptor tree。

### 4. Phase 2 新增标准组件

Phase 1：13 种。

Phase 2 新增 8 种：

```text
ValidationMessage
Field
ToggleField
NumericField
DropdownField
FieldGroup
FormSection
Form
```

当前总注册类型：

```text
21
```

### 5. Field Contract

所有标准 Field 统一提供：

```text
label
feedback
hint (optional)
binding
control
semanticState
```

公共能力：

```lua
Field:SetLabel(Text)
Field:SetHint(Text, Tone)
Field:SetFeedback(Text, Tone)
Field:ClearTransientFeedback()
Field:GetError()
Field:IsDirty()
Field:IsValid()
Field:SetEnabled(Value)
Field:Render()
Field:Layout(X, Y, Width, Height)
```

Feedback 优先级：

```text
Binding Error / Local Input Error
        ↓
Transient Preview / Status
        ↓
Explicit statusText
        ↓
Optional Dirty State
        ↓
Empty
```

因此 Validation Feedback 不再由业务页面各自拼装。

### 6. ToggleField

```lua
RSUI:ToggleField({
    id = "enabled",
    parent = FormSection,
    label = "启用",
    binding = Binding,
    onText = "已开启",
    offText = "已关闭",
})
```

内部组合：

```text
Field Frame
├─ Label
├─ ValidationMessage
└─ RSUI Toggle
```

Binding 写入仍由 BindingV2 裁决。

### 7. NumericField

默认组合：

```text
Field Frame
├─ Label
├─ ValidationMessage
└─ Control Row
   ├─ Minus Button
   ├─ Slider
   ├─ NumericInput
   └─ Plus Button
```

支持：

```text
min / max / step / integer
unit / suffix
format
slider=false
commitOnFinal
onPreview
onApplied
onInvalid
```

#### 7.1 Preview Fence

Slider 拖动期间：

```text
Slider preview
    ↓
更新 Slider / NumericInput 显示
    ↓
ValidationMessage = 预览
    ↓
0 Binding Set
    ↓
0 Domain Write
```

final=true 后：

```text
Binding:Set once
    ↓
Domain / Settings Model
    ↓
Dirty + Debounce
```

#### 7.2 非法文本

例如：

```text
abc%
```

不会进入 Domain。

Field 记录 Local Input Error，Form 的 `errors` 也会包含该错误；用户提交合法值后自动恢复。

### 8. DropdownField

```lua
RSUI:DropdownField({
    id = "curve",
    parent = Section,
    label = "距离曲线",
    options = {
        { value = 1, label = "线性" },
        { value = 2, label = "平滑" },
    },
    binding = Binding,
})
```

RSUI 会把常用：

```text
label / name / text
```

归一到现有 Dropdown Service 所需显示文本。

Popup 仍使用 Phase 1 已修复的 owner/lifecycle 逻辑。

### 9. FieldGroup

FieldGroup 是表单字段集合的响应式 Layout Authority。

默认：

```text
minCellWidth = 240
minColumns = 1
maxColumns = 2
```

使用现有：

```text
LayoutV2.ResponsiveGrid
```

而不是自己重新发明 Grid。

Mock 基准：

```text
Form width 520 → 2 columns
Form width 500 → 1 column
```

字段支持：

```text
colSpan
```

用于需要横跨整行的特殊 Field。

### 10. FormSection

FormSection = 标准 Section 外观 + FieldGroup。

```lua
local Section = Form:AddSection({
    id = "general",
    title = "常用",
})

Section:AddField({
    type = "ToggleField",
    id = "enabled",
    ...
})
```

支持：

```lua
Section:GetFields()
Section:FindField(Id)
```

高度根据 FieldGroup 实际 UsedHeight 计算，不要求页面手算每一行 Y。

### 11. Form

Form 是设置数据与组件树之间的 Form Composition Authority，但 **不是 Setting State Authority**。

支持：

```lua
Form:AddSection(Spec)
Form:AddField(Section, Spec)
Form:FindField(Id)
Form:GetFields()
Form:Render()
Form:Refresh()
Form:Layout(...)
Form:GetState()
Form:IsDirty()
Form:IsValid()
Form:CommitDirty(Source)
```

#### 11.1 Form State

统一输出：

```lua
{
    dirty = 3,
    errors = 1,
    fields = 14,
    valid = false,
}
```

这为后续统一 Footer 提供稳定接口，例如：

```text
已保存
有 3 项修改待持久化
1 项输入错误
```

但 Form 自己不会直接 SaveData。

### 12. SettingsPage 集成

现在：

```lua
local Page = RSUI:SettingsPage({...})
local Form = Page:AddForm({...})
```

SettingsPage 继续复用：

```text
WindowShellV2
ManagedWindow
Lifecycle / Placement / Safe Bounds
```

页面可以同时保留旧：

```lua
Page:AddSection(...)
```

因此 Phase 2 不要求一次性迁移所有旧页面。

### 13. Binding Callback 边界修复

Phase 1 `RSUI:Binding(Spec)` 会把 Component 的：

```text
onChanged
```

同时传给 Binding，并且 Control 自己也会调用 Component `onChanged`，存在将同一次交互回调两次的风险。

Phase 2 明确分离：

```text
onChanged         = Component-level callback
onBindingChanged  = Binding-level callback
```

并完整透传：

```text
markDirty
dirtyKey
onErrorChanged
onRejected
onCommitted
onRefreshed
commitOnUnchanged
```

### 14. 性能规则

Form System 只在以下时机工作：

```text
创建
窗口 Layout / Resize
设置刷新
用户输入
显式 Render / Refresh
```

禁止：

```text
Tick 中重建 Form
Tick 中生成 descriptor tree
Tick 中复杂 Tag 匹配
Slider Preview 连续 SaveData
重复 Native SetText / SetAnchor / SetExtent
```

相同 Form 状态重复：

```text
Render + Layout
```

Mock 结果：

```text
0 additional Native UI writes
```

### 15. Compatibility

以下旧接口继续保留：

```text
UI.ComponentsV2
UI:CreateToggleFieldV2
UI:CreateChoiceFieldV2
UI:CreateNumericFieldV2
UI:CreateCardV2
UI:CreateSectionV2
```

它们目前仍服务已经迁移的 Healer Phase B1 页面。

Phase 2 **没有强制迁移 Healer**，因为当前优先目标是先把 RSUI 平台组件能力做完整，再让业务模块消费。

### 16. 验证结果

```text
ReplicatedSuite Lua：158
Syntax failures：0

RSUI types：21
Component parent resolution：PASS
Automatic logical child ownership：PASS
Recursive Build children：PASS
Declarative Form creation：PASS
520 width → 2 columns：PASS
500 width → 1 column：PASS
NumericField preview → 0 Domain writes：PASS
NumericField final → 1 Domain write：PASS
Binding validation reject：PASS
Local invalid input error：PASS
Validation recovery：PASS
Form dirty/errors/valid summary：PASS
SettingsPage:AddForm：PASS
Repeated Form Render+Layout → 0 Native writes：PASS
Phase 1 RSUI mock regression：PASS
Phase B1 Bound Field mock regression：PASS
Healer Settings Preview purity regression：PASS
```

### 17. 下一阶段

RSUI 已经具备：

```text
Primitive
Controls
Containers
Forms
Binding
Responsive Layout
Window Shell
```

下一阶段优先补“成熟平台 UI”最常用的 Container / Navigation 能力：

```text
TabView
TabButton
Toolbar
ScrollView
Collapsible
Header / Footer Actions
EmptyState
```

完成后再建立 Data Components / VirtualList 与 HUD Components。



<a id="sec-6"></a>
## 6. Replicated Suite — RSUI Selection / Tile Data View Framework v1

> 来源（已合并至本权威文档，原文件已收口）：`replicatedsuite\Docs\Architecture\RSUI\REPLICATED_SUITE_RSUI_SELECTION_TILE_FRAMEWORK_v1_20260826.md`

## Replicated Suite — RSUI Selection / Tile Data View Framework v1

> 日期：2026-08-26  
> BuildTag：`foundation-v2-rsui-selection-tiles-p7`  
> 阶段：RSUI Phase 7 — SelectionModel / TileView / VirtualGrid / Table Header Interaction

### 1. 目标

Phase 7 继续沿用 UE5 UMG `ListView / TileView` 的数据驱动思路，补齐三类平台级能力：

1. **SelectionModel**：选择状态独立于某一个可见 Row；
2. **TileView / VirtualGrid**：大量同构卡片/图标只创建可见区域所需 Widget；
3. **Table Header Interaction**：Header 负责排序意图和列宽 Authority，但不成为业务排序 Authority。

主要使用场景：

- BUFF / Debuff 图标库；
- 装备格 / 技能格；
- 活动卡片；
- Aura Manager；
- DPS / 玩家 /技能 Table；
- 后续搜索结果、收藏、管理器等数据视图。

### 2. Selection Authority

#### 2.1 Key-based，而不是 Index-based

SelectionModel 保存的是稳定 Key：

```text
item_42
player:Replicated
buff:25875
```

而不是：

```text
第 7 行
```

因为排序后：

```text
Index 7 -> Item A
```

可能变成：

```text
Index 7 -> Item B
```

如果 Selection 绑定 Index，会把选择错误转移到另一项。

正式结构：

```text
Domain Data
   ↓
Stable Item Key
   ↓
SelectionModel
   ↓
ListView / TileView / TableView
   ↓
Visible Pool Presentation
```

#### 2.2 SelectionModel 不扫描数据源

Multi-selection 只保存实际被选择的 Key：

```text
Data = 10000 Items
Selected = 3 Items
Selection Storage = 3 Keys
```

不创建 10000 长度的布尔数组。

当前模式：

```text
none
single
multi
```

主要 API：

```lua
local Selection = RSUI:CreateSelectionModel({
    id = "aura_selection",
    mode = "multi",
})

Selection:SetSelected(Key, true)
Selection:SelectOnly(Key)
Selection:Toggle(Key)
Selection:Clear()
Selection:IsSelected(Key)
Selection:GetSelectedKeys()
```

SelectionModel 支持轻量订阅；View Release 时会解除自己的订阅，避免共享 SelectionModel 长生命周期持有已经释放的 View。

M1.16.0.6 起 DataView Selection Contract v2 统一为：`onSelectionChanged(index, previousIndex, view, model, reason, key, selected, context)`。Presentation **优先只读 `view:GetSelectedKey()`**，不得依赖 `model` 位于第几个回调参数；TableView 必须把外层 TableView 作为 `view`，不能泄漏内部 ListView。稳定 Key 可以在行不位于当前虚拟池时继续成立，而 selected index 只保证本地/可解析时可用。

### 3. TileView / VirtualGrid

#### 3.1 不按数据量创建 Native Widget

TileView 使用：

```text
Viewport Columns
× Visible Rows
+ Small Overscan Rows
= Bounded Tile Pool
```

而不是：

```text
Item Count
= Widget Count
```

例如：

```text
10000 Buff Records
Viewport 4 Columns × 3 Rows
Overscan 1 Row
```

只需要视口级 Tile Pool。

#### 3.2 固定 Tile Height

Phase 7 使用固定：

```text
tileHeight
```

Column 宽度可根据 Viewport 自动变化。

原因与 ListView 固定 Row Height 一致：

- index -> row/column 为 O(1)；
- 不维护大型位置缓存；
- 快速 `ScrollToIndex()`；
- 跨分辨率更容易保证不重叠。

#### 3.3 Responsive Columns

没有显式指定 `columns` 时：

```text
Available Width
÷ minTileWidth
→ Columns
```

并受：

```text
maxColumns
maxPoolSize
```

约束。

分辨率变化导致列数变化时，TileView 尽量保持原首个可见 Logical Item 附近，而不是无条件跳回顶部。

#### 3.4 Pool Safety

Pool 约束优先级：

```text
1. 可见 Item 必须有真实 Pool Widget
2. Visible 优先于 Overscan
3. Pool 不超过 maxPoolSize
4. Overscan 在顶部/底部被裁掉时，从另一侧借用，首次 Layout 即完成 Warm Pool
```

因此不会出现：

```text
Logical Visible = true
但没有 Tile Widget 可显示
```

### 4. Tile Selection

默认 Tile 在启用 Selection 时使用可点击 Button Presentation。

单选：

```text
Click
→ SelectOnly(Key)
```

多选：

```text
Click
→ Toggle(Key)
```

自定义 `tileFactory` 仍可以构造更复杂的：

```text
SizeBox
└─ Overlay
   ├─ Image
   ├─ Stack Text
   └─ Cooldown Text
```

业务自定义 Tile 可调用：

```lua
View:SetSelectedIndex(Index)
View:SetItemSelected(Index, true)
View:ToggleSelection(Index)
```

### 5. ListView Selection Upgrade

ListView 继续保留 Phase 6 Row Pool，同时可以接入同一个 SelectionModel：

```lua
local Selection = RSUI:CreateSelectionModel({ mode = "single" })

local List = RSUI:ListView({
    selectionModel = Selection,
})

local Tiles = RSUI:TileView({
    selectionModel = Selection,
})
```

两个 View 共享同一个 Selection Authority。

默认 List Row 在 `selectable=true` 时采用可点击 Button；自定义 Row Factory 不被强制注入 Native OnClick，避免覆盖业务自己的 Handler。

### 6. Table Header Interaction

Phase 7 新增：

```text
TableHeader
```

TableView 使用：

```lua
headerInteractive = true
```

时 Header Cell 使用标准 RSUI Button。

点击排序循环：

```text
none
 ↓
asc
 ↓
desc
 ↓
none
```

Header 显示：

```text
伤害 ↑
伤害 ↓
```

#### 6.1 Table 不负责排序业务数据

这是 Authority 边界。

点击只调用：

```lua
onSortChanged(ColumnId, Direction, Table)
```

业务 Presenter / Model 决定：

- 是否真的排序；
- 排序字段；
- 稳定排序规则；
- PVP/PVE 等业务语义；
- 数据 Revision。

TableView 不调用 `table.sort()` 修改用户数据。

#### 6.2 Column Width Authority

当前公共 API：

```lua
Table:SetColumnWidth("damage", 110)
Table:AdjustColumnWidth("damage", 10)
Table:SetColumnSizeMode("name", "fill", 1)
```

最终仍统一进入 Phase 6：

```text
Table Available Width
→ ResolveColumnWidths()
→ Header + Visible Rows 共用同一 Width Array
```

当前实现已经接入 Header Separator 拖拽。它不依赖未经确认的全局 Mouse Delta API，而是复用已验证的 Native `StartMoving/StopMovingOrSizing`，由中央 Scheduler 的 interactive lane 在手势期间采样 Separator 的有效位置。拖动开始时必须冻结 `resolvedWidths` 基线；Preview 只移动当前边界并以右侧补偿列保持 Table 总宽稳定，禁止每个采样点重新执行完整 `ResolveColumnWidths()`，否则多个 Fill Column 会同时反复分配宽度，导致池化 Row 的 Label 连续改 Anchor/Extent/ellipsis 并在 RU Native UI 中产生明显文字抖动。Preview 宽度必须量化到逻辑整数像素，Row/GridLine 对未变化几何必须跳过 Native Write；`OnDragStop` 一次 Commit Preview 中的列宽对，不再进行第二次 Fill 求解。

### 7. 性能规则

明确禁止：

```text
Tick → 扫 10000 Items
Tick → 重建 Tile Descriptor Tree
Scroll → 重建全部 Tile Widgets
Selection Change → 遍历全部 Data Source
Table Header Click → 复制/排序业务大表
```

允许的工作：

```text
Layout Change → O(Pool)
Scroll → O(新进入 Pool 的 Tile)
RefreshVisible → O(Pool)
Selection Change → O(Visible Pool + Selected Key Count)
Column Resolve → O(Column Count)
```

### 8. Diagnostics

新增 Counter：

```text
selectionModelsCreated
selectionChanges

tilePoolItemsCreated
tileItemBinds
tileItemReuses
tileReconciles
tileColumnChanges
tileVisibleItemsPeak

tableHeaderClicks
tableSortChanges
tableColumnWidthChanges
```

全部为轻量 Counter，不在热路径构造诊断字符串。

### 9. Mock 验证重点

Phase 7 Mock 覆盖：

```text
SelectionModel single/multi/key selection
10,000 Tile Data bounded pool
Scroll one row bounded rebind
ScrollToIndex(9000) pool does not scale with data
Responsive column change
Tile click selection
ListView + TileView shared SelectionModel
10,000 ListView jump / bounded RefreshVisible
Table Header asc/desc/none cycle
Table does not mutate source data
Column width central Authority
Repeated Table Layout = 0 Native Write
```

### 10. 后续

Phase 7 后 RSUI 的核心 UI Foundation 已经覆盖：

```text
Primitive
Panel / Slot
Adaptive Layout
Layout Safety
Form
ListView
TableView
TileView
Selection
```

下一阶段应优先做收尾型 Foundation，而不是继续无限扩张组件种类：

- Focus / Keyboard Navigation（仅在 RU API 验证可靠时）；
- Tooltip / Context Menu 平台层；
- Composite Row/Tile 样板；
- RSUI Playground / Gallery / Layout Stress Test；
- 然后开始迁移真实 Healer / DPS / Plates UI。



<a id="sec-7"></a>
## 7. Replicated Suite — RSUI Layout Safety / Debugging v1

> 来源（已合并至本权威文档，原文件已收口）：`replicatedsuite\Docs\Architecture\RSUI\REPLICATED_SUITE_RSUI_LAYOUT_SAFETY_v1_20260826.md`

## Replicated Suite — RSUI Layout Safety / Debugging v1

> 日期：2026-08-26  
> BuildTag：`foundation-v2-rsui-layout-safety-p5`  
> 阶段：RSUI Phase 5  
> Authority：本文件是 RSUI 跨分辨率布局安全、Visibility、Dirty Layout 与 Layout Debug 的当前专项规则。

---

### 1. 为什么 Phase 5 优先于业务 UI 迁移

当前项目最常见的 UI 风险不是“控件不够多”，而是：

- 1024×768 下文字越界；
- 1080P 正常、1K 重叠；
- 分辨率/UI Scale 改变后窗口仍按旧尺寸布局；
- 隐藏一个控件后布局突然跳动，或本应腾空间却仍占位；
- 页面刷新时重复 Measure / Layout 整棵树；
- HUD 绝对定位后跑出屏幕；
- 出现重叠时只能通过截图人工猜哪一级布局出错。

因此 Phase 5 的目标不是新增业务页面，而是让 RSUI 具备接近 UE5 UMG 的布局安全语义：

```text
Viewport Authority
    ↓
ResolutionRoot
    ↓
SafeZone
    ↓
Measure / DesiredSize
    ↓
Panel Slot
    ↓
Arrange
    ↓
Visibility / Viewport Visibility
    ↓
Native Diff
```

同时建立显式 Debug 工具：

```text
Component Tree
    ↓
InspectLayout()
    ↓
Absolute Rect / Overflow / Boundary Check
    ↓
Layout Debug Overlay（手动刷新）
```

---

### 2. Authority 规则

#### 2.1 Viewport Authority

屏幕逻辑尺寸统一使用：

```lua
S.Api:GetUiMetrics()
```

其内部已经以 `UIParent:GetExtent()` 作为 RU 客户端逻辑坐标优先 Authority，并只在不可用时回退到 `GetScreenWidth/GetScreenHeight`。

RSUI 不重新实现第二套屏幕尺寸算法。

#### 2.2 Native UI Authority

Phase 5 仍然不绕过：

```text
rs_ui_factory.lua
rs_ui_framework.lua
```

所有 Extent / Anchor / Visible / Color / Scale 仍走已有 Native Diff / Lifecycle。

#### 2.3 Layout Authority

业务模块不得在同一组件树里同时让：

```text
RSUI Panel
和
业务手算 x/y
```

竞争布局 Authority。

如果使用 `HorizontalBox / VerticalBox / Grid / WrapBox ...`，子控件位置由 Panel/Slot 决定。

只有明确的 HUD/Debug screen-space 场景才使用 `CanvasPanel`。

---

### 3. Visibility：Visible / Hidden / Collapsed

Phase 5 正式引入 UMG 风格 Visibility：

```text
Visible
Hidden
Collapsed
```

#### Visible

```text
参与 Measure
参与 Arrange
Native 显示
```

#### Hidden

```text
参与 Measure
参与 Arrange
Native 隐藏
```

用于“暂时不显示，但页面不能跳动”的场景。

例如：

```text
[名称] [状态] [数值]
```

状态暂时没有内容时，如果使用 Hidden：

```text
[名称] [    ] [数值]
```

左右布局仍稳定。

#### Collapsed

```text
不参与 Measure
不参与 Arrange
Native 隐藏
```

用于真正移除布局空间。

#### 兼容旧 API

旧代码：

```lua
Widget:SetVisible(false)
```

继续等价于：

```lua
Widget:SetVisibility(RSUI.Visibility.Collapsed)
```

这样不会悄悄改变历史页面语义。

新代码如需要 Hidden，必须明确：

```lua
Widget:SetVisibility(RSUI.Visibility.Hidden)
```

---

### 4. Dirty-only Measure / Arrange

Phase 4 已经建立 Invalidation propagation：

```text
Child Dirty
    ↓
Parent Dirty
    ↓
Root Dirty
```

Phase 5 开始真正消费这套 Dirty 状态。

#### Measure Cache

Panel 内部的 Measure helper 记录：

```text
lastMeasureAvailableW
lastMeasureAvailableH
desiredWidth
desiredHeight
measureDirty
```

当：

```text
measureDirty == false
且
availableW/H 未变化
```

则直接返回缓存 DesiredSize。

#### LayoutIfNeeded

标准组件现在可以：

```lua
Root:LayoutIfNeeded(X, Y, Width, Height)
```

只有下列情况执行真正 Layout：

- Measure/Layout Dirty；
- bounds 改变；
- `force=true`。

否则直接跳过。

#### Panel 子节点 Arrange

Panel 不再无条件：

```lua
Child:Layout(...)
```

而使用共享 Arrange helper：

```text
Parent Layout
    ↓
Arrange Child
    ↓
Child:LayoutIfNeeded()
```

因此父层需要重排时，不代表每个后代都必须重复执行 Layout。

#### 禁止方式

不要在 Tick 中：

```lua
Root:LayoutIfNeeded(...)
```

更不能：

```lua
Root:Layout(...)
```

跨分辨率更新应该由明确事件、窗口打开、Resize/设置变化或显式 viewport refresh 驱动。

---

### 5. ResolutionRoot

新增：

```lua
RSUI:ResolutionRoot({...})
```

用途：

> 把一棵 RSUI 页面树绑定到当前 RU 客户端“逻辑 viewport”，而不是绑定到某个写死的 1920×1080 假设。

示例：

```lua
local Root = RSUI:ResolutionRoot({
    id = "suite_root",
    parent = UIParent,
    designWidth = 1024,
    designHeight = 768,
})
```

读取：

```lua
local W, H, UIScale = Root:GetViewportMetrics()
```

显式刷新：

```lua
Root:RefreshViewport(true)
```

或刷新所有已登记 Root：

```lua
RSUI:RefreshResolutionRoots()
```

#### Breakpoint

当前提供轻量语义：

```text
compact
normal
wide
```

默认：

```text
width < 1100   → compact
width >= 1800  → wide
其他           → normal
```

可通过 spec 修改阈值。

Breakpoint 只是布局决策信息，不自动改变业务状态。

#### 不做 Tick Poll

ResolutionRoot 不注册 OnUpdate。

分辨率变化检测由显式 `RefreshViewport()` 完成。

---

### 6. SafeZone

新增：

```lua
RSUI:SafeZone({...})
```

基本结构：

```text
ResolutionRoot
└─ SafeZone
   └─ Page Content
```

示例：

```lua
local Safe = RSUI:SafeZone({
    id = "safe",
    parent = Root,
    safePadding = {
        left = 12,
        top = 10,
        right = 12,
        bottom = 10,
    },
})
```

支持：

```text
safePadding / padding / margin
edgePercent
horizontalPercent
verticalPercent
```

例如：

```lua
edgePercent = 0.02
```

表示每侧额外保留 viewport 对应比例的安全边距。

#### 极端小窗口保护

如果左右或上下 Insets 已经大于可用尺寸：

```text
不会得到负宽度/负高度
```

RSUI 会按比例夹紧边距，并记录：

```text
safeZoneClamps
```

---

### 7. AspectRatioBox

新增：

```lua
RSUI:AspectRatioBox({...})
```

用途类似 UMG AspectRatioBox / ScaleBox 中常见的比例约束：

```lua
local Box = RSUI:AspectRatioBox({
    id = "preview",
    parent = Parent,
    aspectRatio = 16 / 9,
    mode = "fit",
})
```

默认 `fit`：

```text
完整内容优先
不越过父容器
允许 Letterbox 空白
```

`fill`：

```text
填满父区域
可能产生超出父区域的视觉尺寸
```

因此普通设置页/HUD 优先 `fit`。

---

### 8. CanvasPanel：严格限定用途

新增：

```lua
RSUI:CanvasPanel({...})
```

它不是普通页面的首选布局。

推荐用途：

```text
HUD screen-space marker
Calibration overlay
Layout Inspector
特殊 Boss 机制 screen-space 图层
```

不推荐：

```text
Settings Page
普通列表
DPS Row
Activity Card
Form
```

这些应继续使用 Box/Grid/Wrap。

#### Slot

Canvas Slot 支持：

```text
x / left
y / top
width
height
```

示例：

```lua
Canvas:AddChild(Marker, {
    x = 420,
    y = 180,
    width = 32,
    height = 32,
})
```

#### 默认 Screen-safe Clamp

默认：

```lua
clampChildren = true
```

请求：

```text
x=180 width=70
Canvas width=200
```

不会得到：

```text
180..250
```

而会夹紧到 Canvas 内。

出现夹紧时记录 `screenBoundaryIssues`。

确实需要允许越界时才显式：

```lua
allowOverflow = true
```

---

### 9. Screen Bounds Helper

新增按需 API：

```lua
RSUI:GetAbsoluteRect(Component)
```

以及：

```lua
local Ok, Issues, Rect, Viewport = RSUI:CheckScreenBounds(Component)
```

Issues：

```text
left
top
right
bottom
```

该检查只在显式调用时运行。

不会在 Tick 中遍历 UI。

`GetAbsoluteRect()` 同时考虑直接 `ScaleBox` content 的 Applied Scale，以便 Debug footprint 更接近实际显示范围。

---

### 10. Layout Debug Overlay

Phase 4 的：

```lua
RSUI:InspectLayout(Root)
```

继续是只读数据检查器。

Phase 5 新增：

```lua
local Overlay = RSUI.LayoutDebug:CreateOverlay({
    parent = UIParent,
    id = "rsui_debug",
    maxNodes = 80,
})
```

需要检查时：

```lua
Overlay:Refresh(Root)
```

效果：

```text
每个组件显示 Rect 边界
普通节点 = 普通 Debug Tone
有 Inspector Issue = Error Tone
Label = Kind:Id
```

#### 非常重要

Debug Overlay：

```text
不注册 Tick
不自动扫描
只在 Refresh() 时运行
```

Native Debug widgets 使用 Pool/Hide，不假设 RU 存在安全通用 DestroyWidget。

这与现有 Lifecycle 原则一致。

---

### 11. Text Wrap：单词边界改进

Phase 3/4 的 Wrap 是 UTF-8 安全字符换行。

Phase 5 改为：

```text
Latin / Cyrillic
→ 优先在空格、-、/ 边界换行

中文/没有空格的语言
→ UTF-8 字符边界 fallback
```

因此俄文/英文设置说明不会优先切成：

```text
Replicat
ed Suite
```

而更倾向：

```text
Replicated
Suite
```

同时中文仍然可以正常按字符宽度换行。

记录：

```text
wordBoundaryBreaks
```

---

### 12. Diagnostics

RSUI Snapshot 新增：

```text
measurePasses
measureSkips
layoutPasses
layoutSkips
viewportRefreshes
safeZoneClamps
screenBoundaryIssues
visibilityChanges
debugOverlayRefreshes
```

仍然遵守：

> 热路径只记 Counter；字符串诊断在读取页面/完整报告时生成。

---

### 13. 推荐页面根结构

以后普通自适应页面推荐：

```text
ResolutionRoot
└─ SafeZone
   └─ SizeBox / Border
      └─ VerticalBox
         ├─ Header
         ├─ ScrollBox / Content
         └─ Footer
```

列表/卡片：

```text
VerticalBox
HorizontalBox
Grid
UniformGrid
WrapBox
```

图标叠层：

```text
SizeBox
└─ Overlay
   ├─ Image
   ├─ Text
   └─ ProgressBar / Border
```

HUD 绝对定位：

```text
ResolutionRoot
└─ SafeZone（需要屏幕安全时）
   └─ CanvasPanel
      └─ Marker / Overlay
```

---

### 14. 跨分辨率原则

业务 UI 不再写：

```lua
if screenWidth == 1024 then ...
elseif screenWidth == 1920 then ...
```

优先级：

```text
Auto / Fill / Fixed Slot
→ Wrap / Grid / UniformGrid
→ Min/Max
→ ResolutionRoot Breakpoint
→ 最后才做极少量模块级特殊规则
```

也不要用全局 ScaleBox 粗暴把整个 Settings UI 缩成很小的字。

`ScaleBox` 更适合：

```text
图标区域
预览区域
固定比例 HUD 组合
```

普通文字页面应优先重新布局/换行。

---

### 15. 性能原则

Phase 5 明确禁止：

```text
Tick 中 RefreshResolutionRoots
Tick 中 InspectLayout
Tick 中 DebugOverlay:Refresh
Tick 中全树 Layout
```

正确方式：

```text
创建窗口
Resize
分辨率/UI Scale 事件
设置改变
内容改变
开发者主动诊断
```

才触发布局。

Dirty-only Layout 的目标是：

```text
改一个 Text
→ 只污染必要祖先链
→ 不变的兄弟组件 Measure/Arrange 可跳过
```

---

### 16. Canvas 与高频 HUD 的额外约束

CanvasPanel 本身不是高频坐标更新的许可证。

例如 Plates 头顶标记每帧/高频位置更新时，现有 Presentation/FrameBudget/Diff 规则仍然有效。

RSUI 只是统一组件和布局 Contract，不接管 Observation 或 Runtime 调度 Authority。

不能因为有 CanvasPanel 就把：

```text
Native target scan
Aura scan
复杂 Tag 匹配
数据排序
```

塞进 UI 更新路径。

---

### 17. 本阶段验证

最终交付前最低验证：

```text
全 Suite Lua Syntax
TOC 文件存在/顺序
Phase 1 Controls 回归
Phase 2 Forms 回归
Phase 3/4 UMG/Adaptive 回归
B1 Responsive Field 回归
Healer Preview purity
Visibility Hidden/Collapsed
Dirty Measure/Arrange Skip
ResolutionRoot 1024×768 → compact viewport change
SafeZone extreme margin clamp
AspectRatioBox fit
Canvas child clamp
word-boundary Wrap
Layout Debug Overlay explicit refresh
Patch overlay restore
ZIP structure
```

详细数字以本轮最终交付说明为准。

---

### 18. 下一阶段

完成 Layout Safety 后，建议开始：

#### RSUI Phase 6 — Data / HUD Composition

```text
VirtualList
Reusable Row Pool
Table / Column Model
AuraSlot
PlayerRow
StatusRow
HUD IconSlot
HealthBar
CastBar
```

但第一批业务迁移应继续作为 RSUI 的 Consumer Verification，而不是让 RSUI 重新围绕某一个模块定制。

---

### 19. 当前一句话结论

> RSUI Phase 5 的重点不是再增加“漂亮组件”，而是把 UE5 UMG 中非常关键的 Viewport、Visibility、Safe Layout、Dirty Prepass 和 Debug Rect 思维落实到 ArcheAge RU 的受限 Native UI 环境里，让后续模块可以放心组合控件，而不是继续依赖每个页面手算坐标和人工排查越界。



<a id="sec-8"></a>
## 8. Replicated Suite RSUI Foundation Graduation v1

> 来源（已合并至本权威文档，原文件已收口）：`replicatedsuite\Docs\Architecture\RSUI\REPLICATED_SUITE_RSUI_FOUNDATION_GRADUATION_v1_20260826.md`

## Replicated Suite RSUI Foundation Graduation v1

> 日期：2026-08-26  
> BuildTag：`foundation-v2-rsui-foundation-complete-p8`  
> 范围：RSUI Phase 8 — Interaction Services / Playground / Foundation Graduation

### 1. 本阶段定位

Phase 8 是 RSUI Foundation 的收尾阶段，而不是继续扩充大量业务 Widget。

Phase 1–7 已经建立：

- Component Runtime / Diff / Lifecycle；
- Text / Image / Button / Slider / ProgressBar 等 Primitive；
- HorizontalBox / VerticalBox / Grid / Overlay / Border / SizeBox；
- UniformGrid / WrapBox / ScrollBox / WidgetSwitcher / ScaleBox；
- ResolutionRoot / SafeZone / AspectRatioBox / 受限 CanvasPanel；
- Visible / Hidden / Collapsed；
- Measure / Arrange / Dirty-only Layout；
- Layout Inspector / Debug Overlay；
- Form / Field；
- ListView / TileView / TableView；
- bounded Row/Tile Pool；
- Key-based SelectionModel；
- Table Header sort intent / centralized column width Authority。

Phase 8 的目标是补齐平台交互与开发者验证能力，并冻结 RSUI Foundation 的核心 Contract。

### 2. Event Multiplexer

#### 2.1 问题

Native Widget 的 `SetHandler(eventName, fn)` 本质上是单入口。

如果业务代码先绑定：

```text
OnEnter -> 业务 Hover
```

随后 Tooltip 又绑定：

```text
OnEnter -> Tooltip
```

后一次绑定可能覆盖前一次绑定。

组件化程度越高，这种问题越危险。

#### 2.2 新 Contract

`Component:On(widget, eventName, fn, label)` 现在建立 RSUI Event Multiplexer：

```text
Native OnEnter
      ↓
RSUI Multiplexer（Native 只注册 1 次）
      ├─ 业务 Hover
      ├─ Tooltip
      ├─ Selection
      └─ 诊断/其他订阅
```

同一 Native Event 可以存在多个逻辑订阅者。

提供：

```lua
Component:On(widget, "OnEnter", callback, "label")
Component:Off(widget, "OnEnter", "label")
```

派发过程中新增的订阅不会在当前这次派发中立即执行，避免回调列表动态增长造成不可预测行为。

#### 2.3 Authority

- Native Handler 注册仍由 `S.UI:SafeHandler()` 管理；
- Generation / Lifecycle Handler Release 仍由 UI Framework v1 管理；
- RSUI Event Multiplexer 只负责一个 Component 内的逻辑订阅分发；
- 不建立第二套 Native Handler 生命周期。

### 3. TooltipService

入口：

```lua
RSUI.Tooltip:Bind(Component, {
    text = "说明文本",
})
```

或动态 Provider：

```lua
RSUI.Tooltip:Bind(Component, {
    provider = function(Component)
        return BuildTooltipText(Component)
    end,
})
```

#### 3.1 Native 优先

RU 客户端当前工程已经存在稳定使用：

```lua
SetTooltip(text, widget)
```

因此 TooltipService 优先使用 Native `SetTooltip`，让客户端负责最终 Tooltip 展示与鼠标安全定位。

#### 3.2 Fallback

如果当前 RU 构建没有导出 `SetTooltip`，RSUI 才使用单个池化 Tooltip Panel：

- 物理 parent：`UIParent`；
- 单例复用；
- TextLayout Wrap；
- Viewport Clamp；
- 不每次 Hover 创建新 Widget；
- 不运行 Tick。

#### 3.3 Raw Native 安全规则

原生 Widget 没有 RSUI Event Multiplexer。

因此：

```lua
RSUI.Tooltip:Bind(rawNative, {...})
```

默认拒绝。

迁移代码明确确认该 Native Event 没有其他 Handler 时，才能：

```lua
allowRaw = true
```

避免 Tooltip 覆盖旧模块业务事件。

### 4. ContextMenuService

ContextMenu 使用一个 Suite 级池化 Popup：

```text
ContextMenuService
├─ pooled Button 1
├─ pooled Button 2
├─ pooled Button 3
└─ ... bounded max rows
```

打开：

```lua
RSUI.ContextMenu:Open(Component, {
    { id="refresh", text="刷新", onClick=... },
    { separator=true },
    { id="delete", text="删除", tone="danger", onClick=... },
})
```

也可以绑定到已经确认的组件事件：

```lua
RSUI.ContextMenu:Bind(Button, provider, "OnClick")
```

#### 4.1 不猜右键 API

当前 `z_api_functions/ui_functions.lua` 没有确认通用的：

```text
OnRightClick
OnMouseButtonDown
pointer delta
```

Contract。

因此 Phase 8 不伪造“右键菜单”。ContextMenu 是一个明确的 Popup Service；业务可以通过 `...` Button 或已确认的具体事件打开。

未来如果 RU API 验证得到稳定 Right Mouse Event，只需要增加 Gesture Adapter，不修改 ContextMenu Authority。

#### 4.2 屏幕安全

Menu 会：

- 自动限制宽度；
- 根据 Viewport 高度限制本次可展示行数；
- 超出右侧时向左回弹；
- 超出底部时向上回弹；
- 最终 Clamp 在屏幕内；
- Row Widget 使用 Pool，重复 Open 不持续创建。

### 5. FocusService

工程 API 已确认：

```text
Button:SetFocus()
Edit:SetFocus()
Edit:ClearFocus()
GetFocusedWidgetId()
```

因此 RSUI 提供：

```lua
RSUI.Focus:Set(Component)
RSUI.Focus:Clear(Component)
RSUI.Focus:GetFocusedWidgetId()
RSUI.Focus:GetCapabilities()
```

但是 `ui_functions.lua` 没有确认通用 `OnKeyDown / OnKeyUp` Widget Event。

所以：

```text
keyboardNavigationSupported = false
```

Phase 8 不猜 Tab / Arrow / Escape 导航实现。

### 6. Composite Samples

Phase 8 刻意不继续增加大量 Standard Component Type。

标准 Registry 保持：

```text
47 types
```

新增的是组合示例：

```lua
RSUI.Composite.StatusCard(...)
RSUI.Composite.AuraSlot(...)
```

它们分别由现有基础积木组合：

```text
StatusCard
Border
└─ VerticalBox
   ├─ HorizontalBox
   │  ├─ Text
   │  └─ Text
   ├─ ProgressBar
   └─ Text
```

```text
AuraSlot
SizeBox
└─ Overlay
   ├─ Image
   ├─ Stack Text
   └─ Time Text
```

这证明后续业务组件应优先组合 Primitive/Panel，而不是继续增加新的 Native Factory。

### 7. Playground

显式开发接口：

```lua
RSUI.Playground:Build(parent, spec)
```

Playground 展示：

- Text Safety；
- Border / Box / UniformGrid；
- StatusCard Composite；
- ListView；
- TileView；
- Selection；
- Tooltip；
- ContextMenu。

它只有开发者主动调用时才创建 UI。

正常插件启动不会自动创建 Playground。

### 8. Stress Harness

显式调用：

```lua
RSUI.Playground:RunStress(parent, {
    count = 10000,
})
```

Stress 数据源采用：

```text
getCount()
getItem(index)
```

而不是预先创建 10000 个数据 table。

验证重点是：

```text
10,000 logical items
      ↓
ListView bounded Row Pool
TileView bounded Tile Pool
```

Stress Harness 不注册 Tick，也不在正常运行路径自动执行。

### 9. Phase 8 Diagnostics

新增轻量 Counter：

```text
eventSubscriptions
eventDispatches

tooltipBindings
tooltipShows
tooltipHides

contextMenuOpens
contextMenuCloses
contextMenuActions
contextMenuRowsCreated

focusChanges

playgroundBuilds
playgroundStressRuns
```

仍然遵守 Foundation 原则：

> 热路径记录数字，不在交互事件里构造大型诊断字符串。

### 10. RSUI Foundation 完成后的层级

```text
ArcheAge / ArcheRage Native UI
            ↓
UI Factory / Native Adapter
            ↓
UI Framework v1
Diff / Lifecycle / Native State Cache
            ↓
RSUI Core
Component / Event Multiplexer / Visibility
            ↓
Text + Layout Foundation
Measure / Arrange / Slot / Resolution Safety
            ↓
Primitive / Panel
            ↓
Form / Data View / Interaction Services
            ↓
Composite Components
            ↓
Healer / DPS / Plates / Activity / Trade / ...
```

### 11. Foundation Freeze

从 Phase 8 开始，RSUI Foundation 默认进入稳定期。

后续原则：

1. 不因为某一个业务页面缺控件就立刻增加新的底层 Primitive；
2. 优先使用现有 Primitive / Panel 组合；
3. 新增底层组件必须至少被两个业务场景复用，或解决明确的 Foundation 缺口；
4. Healer / DPS / Plates 开始逐步迁移；
5. 迁移过程发现真实缺口，再通过小版本扩展 RSUI；
6. 不重构已经稳定的 Diff / Lifecycle / Persistence / FrameBudget Authority。

### 12. 下一步

RSUI Foundation 完成后，下一阶段应该从业务迁移验证开始。

推荐顺序：

```text
1. Healer Settings / Raid UI
2. DPS List / Table
3. Plates AuraSlot / TileView / Manager
4. Activity Card / Grid
5. Trade / Quest / Diagnostics
```

迁移目标不是单纯“视觉重做”，而是逐步消灭业务模块中的：

```text
手工 x/y
重复 SetExtent/AddAnchor
页面私有 Scroll/List
页面私有 Tooltip
页面私有 Row Pool
页面私有分辨率判断
```

最终业务层只描述数据、状态和组合结构。



<a id="sec-9"></a>
## 9. Replicated Suite RSUI Foundation Audit — M6-v10

> 来源（已合并至本权威文档，原文件已收口）：`replicatedsuite\Docs\Architecture\RSUI\REPLICATED_SUITE_RSUI_FOUNDATION_AUDIT_M6_V10_20260827.md`

## Replicated Suite RSUI Foundation Audit — M6-v10

> Date: 2026-08-27  
> Scope: RSUI layout invalidation, linear layout allocation, layout inspector coverage, Dashboard live inspection.  
> Reason: in-game M6-v9 screenshot showed a large stale blank region inside the trade card and multiple overlap/clipping symptoms.

### 1. Finding: dirty propagation existed, but dirty layout had no automatic flush

RSUI `SetVisible(false)` correctly maps to `Collapsed` and calls `InvalidateMeasure()`. The invalidation then propagates to the logical root, but the old contract required an external page caller to arrange that root again.

This is unsafe for data-driven composites because a common sequence is:

1. page performs its first layout;
2. `Refresh()` receives real data;
3. a placeholder/status block changes from Visible to Collapsed;
4. measure/layout is marked dirty;
5. no later layout pass occurs;
6. the old slot remains visible as empty space.

This matched the trade Dashboard defect: the status/empty-hint blocks were collapsed after first layout, while the already-arranged vertical slots stayed reserved.

#### Fix

M6-v10 adds an **event-driven one-shot layout invalidation queue** to RSUI.

- only the top-most established logical RSUI root is queued;
- creation-time dirty state is not scheduled;
- the existing central Suite Scheduler executes one bounded flush;
- no permanent Tick/OnUpdate is introduced;
- a new invalidation raised while a flush is running schedules the next bounded pass;
- roots can opt out with `spec.autoRelayout = false`.

The Dashboard trade card also performs an immediate local reflow when its status/empty-hint visibility actually changes, so this specific high-value page does not need to wait for the deferred flush.

### 2. Finding: LinearBox Measure/Layout disagreed about Fill minimum sizes

The old HorizontalBox/VerticalBox layout distributed remaining space to Fill children without first reserving their minimum primary-axis size. Under pressure it could therefore arrange a Fill child below `minWidth/minHeight`, despite Measure reporting a larger desired/minimum size.

This disagreement is a source of clipping and sibling collision in dense layouts.

#### Fix

The LinearBox allocator now:

- reserves Fill minimum primary size;
- shrinks Auto slots toward their minimum before violating Fill minimums;
- keeps Fixed semantics fixed;
- applies child/slot min/max constraints consistently;
- reports unavoidable shortage as `lastOverflow` instead of silently compressing below the contract;
- counts gaps only between visible children.

### 3. Finding: Inspector did not detect sibling overlap

The previous `RSUI:InspectLayout()` checked overflow, screen bounds and text overflow, but did not detect intersecting siblings in layout panels. The documented acceptance target included `Sibling Overlap = 0`, so the implementation did not match the acceptance contract.

#### Fix

For non-overlay layout containers, the inspector now checks arranged child rectangles for intersections and reports `sibling_overlap` issues. Overlay/Canvas-style intentional overlap is not treated as a defect.

New metric: `siblingOverlapIssues`.

### 4. Finding: Dashboard logical card roots were outside live inspector coverage

The Dashboard creates its six cards as independent logical RSUI roots hosted under the native page root. `UIAcceptance:InspectLive()` previously inspected only `page.component`, so those cards could be invisible to the live inspector.

#### Fix

Dashboard now exposes `GetInspectionRoots()`. UI Acceptance inspects the page component plus all declared inspection roots with deduplication.

Before an explicit live acceptance scan, the pending one-shot layout queue is synchronously flushed. Any roots that remain queued afterward are treated as hard issues.

### 5. New diagnostics

RSUI snapshot/diagnostics now include:

- `layoutRootsQueued`
- `layoutFlushes`
- `layoutRootsReflowed`
- `layoutFlushDeferrals`
- `siblingOverlapIssues`

These are diagnostic counters only and do not add hot-path logging.

### 6. Verification

Local Lua smoke harness with mocked native UI verified:

```text
RSUI_FOUNDATION_SMOKE PASS fillH=20.0 overflow=23 reflow=1
RSUI_INSPECTOR_OVERLAP PASS 2
```

The first test confirms that collapsing a child after initial layout triggers a one-shot root reflow and that a tight Fill child retains its minimum size while the parent reports overflow. The second confirms sibling intersections are surfaced by the inspector.

Full addon Lua syntax validation is also required before packaging.

### 7. Deferred / intentionally not changed in M6-v10

This audit does **not** introduce a second layout framework or expand the standard widget taxonomy. It also does not guess unsupported native capabilities.

Items left for later targeted work if real pages still require them:

- Grid row/column user resizing policies beyond existing TableView column sizing;
- true pixel clipping/scissor behavior if the ArcheAge RU native API does not expose a reliable clipping primitive;
- intentional overlay/canvas collision diagnostics (these need semantic ownership, not generic rectangle intersection);
- new animation systems.

The M6-v10 principle is: **repair layout contracts and observability first, then resume visual polishing on top of a trustworthy foundation.**

## 10. 当前交互 Authority（2026-08-28）

### 10.1 拖动组件统一事务

当前 V3 TOC 中所有需要“拖动过程中驱动二次布局”的组件统一遵循：

```text
OnDragStart
→ Native StartMoving / StartSizing
→ Scheduler Interactive Lane（约 16ms）
→ 实时 Preview / Layout
→ OnDragStop
→ 最终 Commit
→ 释放交互任务
```

若 Scheduler 在 Early Boot / Reload 阶段不可用或拒绝任务，专用 Drag Surface / Resize Handle 可临时绑定 `OnUpdate`；该 fallback 只允许存在于当前手势期间，必须在 `OnDragStop` / `Release` 中释放，禁止形成永久 Tick。

覆盖组件：

- Window Resize
- Slider
- ScrollBar
- SplitView
- Table Column Resize

整窗移动和 Launcher Button 移动本身由 Native `StartMoving()` 直接改变可见几何，不需要额外 Preview 轮询。

### 10.2 尺寸约束语义

Framework 默认不得替 Feature 发明业务最小尺寸。

- 顶层 Window / SettingsPage 默认只保留 Native 1px 技术下限。
- SplitView 默认允许 Pane 收缩至 0；业务模块需要最小空间时必须显式声明 `minPrimary` / `minSecondary`。
- Table `minWidth` = Auto/Fill 的布局推荐最小值。
- Table `absoluteMinWidth` = 用户手动缩列时的硬安全下限。
- 用户把 Fixed Column 缩到 `minWidth` 以下后，后续 Layout 不得偷偷把它恢复到 `minWidth`。
- `maxWidth` / `maxPrimary` 等显式业务上限仍必须尊重。

### 10.3 小视口 ScrollBar

ScrollBar 的默认 Thumb 不得大到在正常的小视口中完全吃掉 Track，从而导致 `travel = 0`。默认 Thumb 推荐值为 12px、技术硬底线 6px；调用方若明确需要更大的最小 Thumb 可以显式指定。



## M1.15.2H1：Floating Window Close Contract

从 M1.15.2H1 起，所有基于 `WindowShellV3 + FloatingSurface + WidgetHost` 的用户悬浮窗采用统一关闭事务：

```text
用户点击 X
    ↓
WindowShell:Close()
    ↓
视觉 Hide（默认 fail-open）
    ↓
onClosed
    ↓
WidgetHost:NotifyWindowClosed()
    ↓
Feature/Widget 释放 Consumer、退订 Presentation、保存 visibility preference
```

约束：

1. `onClose` 默认不能因为 `return false` 或业务清理异常让普通用户窗口永久无法关闭。只有明确声明 `allowCloseVeto=true` 的特殊交互窗口才允许 veto。
2. 业务模块不得在 Shell `onClose` 里反向执行 `WidgetHost:SetVisible(false)` 形成递归式关闭链；Native X 的状态同步统一放到 `onClosed → WidgetHost:NotifyWindowClosed`。
3. 用户可见窗口已经隐藏后，如果 Consumer/资源清理失败，必须记录 Diagnostics；视觉关闭不回滚成“窗口重新出现”。
4. `WidgetHost.visible` 必须跟 Native Window 真实关闭同步，不能只依赖通过 Host API 发起的 Show/Hide。
5. Floating DataView 空状态不得和同一 Surface 的摘要/状态栏重复表达同一句内容；窄尺寸下优先保留单一信息层，避免文字覆盖。

## M1.15.2H2：三态一致 + Domain/Presentation 边界

### 关闭后的三态一致

M1.15.2H1 只同步了 `WidgetHost.visible`。`FloatingSurface` 实例自身的 `visible` 字段在 X 关闭后仍是 `true`，因为 `WindowShell:Close` 直接调 `shell:Show(false)`，绕过了 `surface:Show()`。这会让 `ResetLayout` / 响应式重排去驱动一个已经不在屏幕上的窗口。

M1.15.2H2 起，一次关闭必须让三层状态同时落到 `false`：

| 层 | 字段 | 同步位置 |
|---|---|---|
| Native Window | `window.visible` | `WindowShell:Close → Show(false)` |
| FloatingSurface | `surface.visible` | FloatingSurface 的 `onClosed` 包装器（先于 `spec.onClosed`） |
| WidgetHost | `Host.visible[id]` | `NotifyWindowClosed` |
| Widget 实例 | `instance.visible` | `instance:OnWindowClosed` |

验收断言（`v3_m15_2h_death_review_widget_close`）：一次 `Close()` 只能让 `nativeCloseNotifications` +1，且四层状态全部为 `false`。

### 编程关闭入口

- `surface:Close(reason)` — 与 X 同一契约；`allowCloseVeto` 未声明时 fail-open（业务回调失败也强制关闭并继续 `onClosed`）。
- `Host:RequestClose(id, context)` — 优先走 `instance.shell:Close()`，无 shell 时退回 `SetVisible(false)`；`context.allowVeto=true` 才允许返回失败。

### Feature ↔ Presentation 边界（移除 Domain → WidgetHost 边）

此前 Activities / Tasks / Gear 的 `Enable/Disable` 直接调用 `WidgetHost:SetVisible`，形成 Domain → Presentation 反向依赖。M1.15.2H2 起改由共享底层承担：

```text
FeatureRuntime:Enable/Disable
    ↓ Publish("v3.feature.lifecycle", featureId, state, reason)
WidgetHost:BindFeatureLifecycle(id, { enabled(), preference(), onShowFailed() })
    ↓
Host:SetVisible(id, ...)        ← 只发生在 Presentation 侧
```

- `FeatureRuntime.LifecycleTopic = "v3.feature.lifecycle"`，由 `FeatureRuntime v3` 在 Enable/Disable 成功后广播。
- 悬浮窗在 Presentation 侧调用 `Host:BindFeatureLifecycle` 声明偏好来源；Host 只调用一次内部订阅，不为每个 Feature 复制一套逻辑。
- Domain 侧的用户动作（显示/隐藏、行数、尺寸）改为发布事实事件（`v3.activities.widget_visibility`、`v3.activities.widget_projection`、`v3.tasks.widget_visibility`、`v3.gear.quick.visibility`），Presentation 侧通过 `Host:NotifyProjectionChanged(id, kind)` 或直接 `SetVisible` 响应。
- Feature 必须提供 `F.Commands`（含 `ResetWidgetVisibility`），使 Presentation 在自动显示失败时能回滚持久化偏好，而不是自己改 Domain 状态。
- Domain 代码不得再出现 `S.UIV3.WidgetHost`。`features/*_acceptance.lua` 校验 Presentation 契约属诊断范畴，不受此限。
- M1.15.5 `combat_stats`（DPS）悬浮窗 `rs_v3_dps_widget.lua` 与页 `rs_v3_dps_page.lua` 沿用同一边界：`WidgetHost:Register("combat.dps", {...})` 走 `CreateStateAdapter` 持久化 + `BindFeatureLifecycle` 生命周期桥；Page 经 `PageHost:RegisterFactory("combat.stats", Build)`；两者只消费 `DPS:GetProjection` / `DPS:GetActorDetail` / `DPS.Commands`，不触达 Domain 内部；覆盖不全时 `surface:SetStatus("覆盖不完整", "warn")`。RSUI 新增共享 `TextInput`（Native EditBox + committed Binding + Draft→Submit/校验契约），DPS 用它恢复 Boss 名称添加；按钮与 Enter 共享 Submit 路径，避免焦点仍在输入框时读取旧 Binding 值；排行榜选择后通过 Feature 明细 Projection 展示技能与目标/来源，不在 Presentation 重算战斗数据。


## M1.16.0.4：同步构建事务与 Generation Quarantine

V3 页面、悬浮组件、WindowShell、Modal 与 Main Shell 的懒构建必须视为一个同步事务。RU 客户端没有项目已验证的通用 `DestroyWidget`，因此 Native 构造一旦成功提交，后续 Lua 初始化失败时不得通过“释放 Physical ID 后再创建”伪造销毁。

标准失败链：`BeginBuildScope → 构建 Component/Native → 失败 → Detach/Release Component + Hide Native → 记录原始错误 → 当前 Generation quarantine`。新 Generation（完整 Reload）才允许重新尝试同一逻辑身份。正常路径 `EndBuildScope(..., true)` 后 `activeBuildScopes` 必须归零；该机制只发生在同步创建阶段，不引入 Tick/后台扫描。

## Lua 5.1 延迟回调捕获契约（M1.16.0.13）

ArcheAge 运行环境按 Lua 5.1 语义处理闭包。任何在 `for ... in ipairs/pairs` 中安装、但在循环结束后才触发的 Native/RSUI 回调，都不得直接捕获 generic-for 控制变量。必须先创建稳定局部引用，例如 `routeRef`、`columnRef`、`handleDefinition`。当前已覆盖 V3 导航、TableView 交互表头与 Windowing 八向缩放 Handle。

Floating 逻辑内容与 Native 内容根必须显式区分：Presentation 使用 `FloatingSurface:GetContentRoot()` 获取逻辑 RSUI Component；只有 Adapter/Native 代码才使用 `GetNativeContentRoot()`。状态 setter 对相同值必须按成功 no-op 处理，不重复 Dirty/Save。
