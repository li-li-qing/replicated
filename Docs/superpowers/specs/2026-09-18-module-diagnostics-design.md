# Replicated Suite 模块诊断基础设施设计

## 目标

将现有“全局诊断与维护”从业务模块故障的主要入口降级为系统级基础设施诊断；每个 Feature 页面右上角提供独立“诊断”按钮，打开一个共享的模块诊断悬浮窗。报告只包含当前模块的状态、错误、所属 Store 与按需 Provider 证据，并使用与普通业务输入框完全隔离的诊断专用复制框。

## Authority 与边界

- `FeatureRegistry` 是模块身份、route、名称的唯一 Authority；模块诊断不得创建第二套模块目录。
- `DiagnosticsManager` 继续是全局结构化错误 Authority；新增 `ModuleDiagnosticsHub` 只做有界归属路由、模块快照与 Provider 编排，不拥有业务状态。
- `Persistence` 仍是 Store 健康 Authority；模块报告只筛选与当前 Feature 可证明相关的 Store，不复制全局 Store 列表。
- `ModuleDiagnosticsWindowV3` 只负责 Presentation；打开/翻页不得 Enable Feature、Acquire Consumer、Load 业务 Store 或改变配置。
- `DiagnosticCopyBox` 只负责只读文本复制，不进入 DraftSession，不绑定普通输入生命周期，不修改 `CreateEditBox` / `CreateMultiEditBox` / `BindDeferredInputActivation` 的现有语义。

## 模块错误归属

`DiagnosticsManager:_Append()` 在完成全局有界记录后，向 `ModuleDiagnosticsHub:Observe(entry)` 发送 detached entry。

归属优先级：

1. context 中显式 `moduleId` / `feature` / `featureId`；
2. context.route 通过 `FeatureRegistry:GetByRoute()`；
3. context.store / owner 通过 Store→Feature 映射；
4. source 与 Feature id/route 精确匹配；
5. source 与 `FeatureRegistry.diagnosticSources` 中由 Feature 自己声明的历史 source 别名精确匹配；
6. 无法证明归属则只进入 `system` 环，不污染业务模块。

`diagnosticSources` 是 FeatureRegistry 元数据的一部分，不是 Hub 内第二张猜测表。只允许精确字符串别名，禁止去后缀、关键词包含、相似度等模糊推断。

每个模块最多保留 32 条 warning/error/info 结构化记录；达到上限淘汰最旧记录。路由只发生在已有错误事件上，不新增 Tick。

## 模块报告

点击“生成诊断”时冻结一次 immutable snapshot：

- MODULE_HEADER：build、module id/name/route、FeatureRuntime 状态；
- MODULE_STATUS：只读 Feature Health/已注册 Provider；禁用且未初始化 Feature 不被初始化；
- MODULE_ERRORS：该模块环中的有界结构化错误；
- MODULE_STORES：Persistence 当前已知、可证明归属该模块的 Store 健康；
- MODULE_UI：PageHost 当前 route 与该模块页面是否已构建；
- RESULT：provider failures / omitted counts。

报告生成后使用 `ReportCopyTransport:BuildTextPages()` 固定分页。上一页/下一页只读取冻结 session，不重新采集，不重新读取 Store。

## 页面入口

`PageHost:CreatePage()` 在 `WithBuildScope()` 内发布只在当前 factory 调用期间有效的 `{route, feature}` build context。

`UIV3Design:PageHeader()` 读取 build context，并通过统一 `ModuleDiagnosticsButton()` helper 自动在右上角增加“诊断”按钮。少数已有自定义抬头的页面（当前为首页、战斗分析）只负责在自己的抬头容器中放置同一个 helper，禁止复制 Window/Open/Feature 归属逻辑。

按钮在点击时才解析 `ModuleDiagnosticsWindowV3` 并调用 `Open(feature.id)`。Feature 关闭、Runtime Blocked 或页面处于配置保护态时仍可打开诊断。

## 模块诊断悬浮窗

全 Suite 只有一个 `ModuleDiagnosticWindowV3` 实例，复用 `FloatingSurface + AuxWindowStoreV3`：

- 标题：`<模块名> · 模块诊断`；
- 按钮：`生成诊断 / 上一页 / 下一页`；
- 页码：`0 / 0` 或 `n / N`；
- 大型只读 `DiagnosticCopyBox`；
- 模块切换时释放旧 copy keyboard authority，清空旧 snapshot；
- 窗口关闭时释放 copy keyboard authority；
- 打开窗口本身不采集，只有“生成诊断”采集；
- 若 `v3.presentation.aux_windows` 自己损坏，诊断窗口必须 fail-open 到 Session-only 几何状态，仍可生成/复制报告；仅窗口位置无法跨重载保存，绝不能因为 Presentation Store 故障失去诊断入口。

## DiagnosticCopyBox

新增专用组件，底层仍使用已验证 `EDITBOX_MULTILINE`，但生命周期与普通输入完全隔离：

- 构造后 `SetReadOnly(true)`；
- `OnClick`：显式 `EnableKeyboard(true)` 后 `SetFocus()`；
- `OnLostFocus`：只记录 bounded telemetry，不 SetText、不 ClearFocus、不 Disarm、不调度延迟 recheck；
- 仅 `SetPageText()`、`Clear()` 可调用 `SetText()`；
- 同尺寸 Layout 不重复 `SetExtent/AddAnchor`，避免清除 Native selection；
- `Deactivate/Destroy/Owner Release` 才 `EnableKeyboard(false)`；若焦点仍属于自己才清焦点；
- 不注册 DraftSession，不提交任何业务字段。

这样即使 RU 继续发迟到/伪失焦通知，也不会在用户选中报告后延迟撤销 keyboard authority；普通输入框的删除、输入、DraftSession 语义完全不受影响。

## 系统诊断

保留 `system.diagnostics` 作为 Core/Foundation 诊断入口，但默认页面不再承担“所有业务模块完整报告”的职责。原全量自检仍保留给维护者，模块用户路径优先使用各自模块诊断。

## 性能

- 无新 Tick；
- 错误路由 O(模块别名查找) 且只发生在 Diagnostics 事件写入时；
- 每模块 ring 上限 32；Provider 只在用户点击“生成诊断”时调用；
- 报告 snapshot 只保留当前共享悬浮窗的一份。

## 兼容

- 不删除现有 `DiagnosticsManager` / SelfCheck / RS-ERROR-PAGE 协议；
- 不改变普通 RSUI EditBox/MultiEditBox API；
- 不改变 Feature enable、Store、Demand、Scheduler 生命周期；
- 新 AuxWindow policy 仅保存诊断窗 Presentation 几何。

## 强制维护注释

实际修改点必须注明：问题原因、Authority、数据流、兼容边界、实现理由、风险与未来禁止事项。特别禁止：

1. 为修诊断复制去修改普通输入框生命周期；
2. 翻页重新采集报告；
3. Module Provider 启动关闭中的 Feature；
4. 无法证明归属的共享错误塞进任意业务模块；
5. 业务模块自己复制一套诊断窗口/分页器。
