## 2026-09-04 — `.18.104` RU Native Boolean Setter Return + V3 Startup Hotfix

- **RU 实机 P0 启动回归**：用户 Fresh Reload 后只剩早期恢复入口 `R`，点击无法打开主界面，同时 ESC 插件面板项消失。沿 `toc.g → bootstrap recovery → UIHostManager → V3 NativeAdapter → Runtime Ready → ESC register` 实际调用链确认：`R` 在完整 Runtime 之前创建，而 ESC 注册只发生在 V3 Host 成功建立之后，因此该组合症状指向 Host 创建阶段 fail-closed，而不是单独的 R/ESC 页面问题。
- **根因**：`.18.103` 为状态事务增加 Native 返回值检查时，把 `result == false` 一律解释成“Native 拒绝”。RU Widget setter 没有可依赖的统一 success-return 契约，布尔 Setter 可能返回**应用后的状态值**。主 V3 root 初始化恰好调用 `EnablePick(false) / Clickable(false) / Show(false) / SetCloseOnEscape(false) / SetWindowModal(false)`；合法的 false-state return 因此被误判为失败，Root 被隔离，Runtime 无法进入 `Ready=true`，最终只留下早期 `R`。
- **底层修复，不下沉页面**：UI Framework v10 新增 `NativeBooleanSetterReturnContractVersion=1`。Native 布尔 Setter 仅在“请求 false 且返回 false”时把该返回视为**状态值而非拒绝**；请求 true 仍显式返回 false 时继续 fail-closed。`rsUiSetEnabledAdapter` 属于 Lua Composite 事务回调，其 `false` 继续保持明确 veto 语义，不与 Native return 混淆。Primitive Native helper 同样只对白名单 boolean state setter 的 false-state 调用放宽，`StartMoving` 等 Action 方法返回 false 仍是失败。
- **V3 Root policy 修复**：NativeAdapter Root Interaction Policy 升 v2。`SetCloseOnEscape(false)` / `SetWindowModal(false)` 允许 false-state return；`SetUILayer("system")` 等非布尔 policy 若显式 false 仍拒绝 Root，保留 `.18.103` 的事务/fail-closed 强度。
- **防回归**：Interactive Draft Harness 增加真实 Lua 启动形态：模拟 RU Setter “返回所应用的 bool”，验证隐藏/禁用命中、Composite false veto 以及完整 V3 root 创建，升为 `110/110`；Foundation Gate 升 v99 并要求 Native boolean setter contract/Interaction v4/Root Policy v2，Foundation Audit 同步增加 boolean setter return fence 与 NativeAdapter policy v2 检查。最终本地验证：TOC Runtime Lua `210/210` Parse、Foundation Audit、RSUI Component API、Presentation Feature API、Workspace Smoke、Persistence v3-v7/Acceptance、Bag Queue、Screen Projection、Unit Line Sampling 全部 PASS；RU 客户端下一 Gate 为 Fresh Reload 后确认主界面和 ESC 项恢复。
- **BuildTag**：`v3-m1.16.0.18.104-native-bool-setter-startup-hotfix`。

## 2026-09-04 — `.18.103` RSUI State Transaction + Full Feature Interaction Hardening

- **从“可绘制”继续收敛到“状态真实成立”**：在 `.18.102` Native Interaction ABI 修复后继续扫描 Active V3 页面、悬浮窗与共享 Composite，确认另一类共同根因：Native Show/Hide、Enable/Pick、Alpha、UseResizing、Popup/Window 状态改变失败时，部分 Lua Authority 仍可能先发布 `visible/open/locked/minimized/opacity`，导致诊断与屏幕真实状态分叉。本轮把这些低频状态迁移统一改为事务式——先确认 Native/Composite 成功，再发布逻辑状态；失败则回滚或 fail-closed。
- **UI State / Geometry Transaction Facade**：新增 `UI:EnsureAlpha()`，并补齐 `EnsureAnchor/EnsureExtent`，与既有 `EnsureVisible/EnsureEnabled/EnsurePickable` 统一区分 changed/no-op/rejected。Windowing v16 新增 `StateMutationTransactionContractVersion=1 + GeometryCallbackTransactionContractVersion=1`，`SetLocked/SetResizeEnabled/SetOpacity`、resize handle 的 Geometry/Visible/Enabled/Pickable 以及 geometry commit callback 都必须真实成功；callback 明确拒绝会中止 Commit，不再把失败的 Domain/Persistence 投影当成窗口提交成功。
- **WindowShell / FloatingSurface**：WindowShell v22 增加 `visibilityTransactionContract=1 + stateMutationTransactionContract=1 + stateCallbackTransactionContract=1`；Show/Hide、Minimize、Lock、Overall/Background/Text opacity、FontScale、Appearance drawer、geometry callback 都改为 Native/Layout/业务 State callback 全部成功后才完成提交。FloatingSurface v10 的 Feature-owned state 写入统一经 `CommitState`；Persistence/Domain callback 失败会反向回滚 Shell Native 状态，修复此前 WindowShell `NotifyState()` 用 `pcall` 吞掉 `false` 的最后一处事务断点。
- **Popup/Modal/Context 统一**：Dropdown、ColorField、Tooltip fallback、ContextMenu 与 ModalHost 都使用事务式 popup visibility；`open=true` 只在 popup 真正显示后发布，关闭失败不会提前清空逻辑状态。Dropdown/ColorField 子控件半构建继续 fail-closed，Modal Push/Pop 只有在目标/宿主显隐事务全部完成后才提交 stack。
- **Presentation Visible 状态修复**：Activities、Tasks、Life Economy、Buff Display、Death Review、DPS、Quest Detail 的 Floating Widget 不再在 `surface:Show/Close` 成功前修改 `self.visible`；Hide 先确认视觉关闭，再释放订阅/Consumer，避免窗口实际没关但 Host 已认为关闭。
- **编辑器/滚动交互安全**：SelectionOverlay 与 Layout Debug 的可见状态改为事务式；Scrollbar 的 track/thumb/dragProxy 显隐改为确认式，隐藏时同时关闭真实 dragProxy 的 Enable/Pick，防止透明/残留命中面继续拦截鼠标。Window resize handles 同样同步 Visible/Enabled/Pickable。
- **Binding/Persistence/Action/Composite 累计收敛**：本交付同时包含上一轮尚未正式交付的 Button 单一 Native OnClick Authority、动态 Action Contract、Persistent Binding 创建 fail-closed、Read-Before-Render、写入失败回滚、ColorField 嵌套事务、WidgetHost 偏好 Load-before-show、DataView/Scrollbar/SplitView/LayoutEditor 关键事件 fail-closed 等修改。没有新增 Tick 或常驻轮询。
- **防回归门禁**：Foundation Gate 升 v98；Foundation Audit 增加 Popup/Interaction/WindowShell/FloatingSurface/ModalHost/Windowing state/geometry transaction 静态契约，并检查 Application Shell 几何回滚与 NativeAdapter 初始显隐/几何事务；Interactive Draft Harness 扩展为 104/104。最终本地回归包含 210/210 texluac Parse、Foundation Audit、RSUI Component API、Presentation Feature API、Workspace Smoke、Persistence v3-v7、Acceptance Snapshot、Bag Queue、Screen Projection、Unit Line Sampling。
- **BuildTag**：`v3-m1.16.0.18.103-rsui-state-transaction-hardening`。RU 客户端仍需 Fresh Reload 执行真实鼠标/窗口/存档矩阵；`SPECIFIC_RUNTIME_BLOCKED` 能力保持证据门禁，不因静态修复擅自解除。

## 2026-09-04 — `.18.102` RSUI Native Interaction ABI + Fail-Closed Hardening

- **系统性底层审计**：在 `.18.101` Gear TextInput 实机问题之后继续扫描全部 Active Lua，确认“诊断全绿”仍漏掉一类 Native Interaction ABI 回归：多个 Slider/Scrollbar/Table 列宽拖动/SplitView Divider/Runtime Host 使用 `EnablePick(value, true)` / `Clickable(value, true)`，而项目本地 RU API Authority 明确为单参数 `EnablePick(enable)` / `Clickable(clickable)`。这些调用位于 `pcall` 内时，严格 Native binding 可以静默拒绝，最终表现为“控件画出来但点不动/拖不动”。本轮统一收敛为已验证的一参数 ABI，并把 UI 层命中状态写入 `UI:SetPickable` Diff Authority。
- **Edit 原语完整交互契约**：`CreateMultiEditBox()` 与单行 EditBox 对齐，显式开启 `Enable / EnableFocus / EnableKeyboard / EnablePick / Clickable` 并 `SetReadOnly(false)`；Multiline 不调用 RU 参考中未确认的 `SetReClickable`。所有 TextInput/NumericInput/多行编辑 Consumer 继承同一 Native Interaction Contract v2。
- **Composite Enabled 修复**：自定义横向 Slider 的真实命中面是透明 drag child。旧 `UI:SetEnabled()` 优先调用 Native root `Enable()`，会绕过 Slider 自定义 `SetEnabled()`，造成“视觉禁用但拖动层仍可交互”。新增显式 `rsUiSetEnabledAdapter`，禁用时同步停止当前拖动、释放临时 OnUpdate/Scheduler、关闭 drag child 的 Enable/Pick，恢复未提交 Preview；无常驻 Tick。
- **Primitive/Build fail-closed**：Native primitive 初始化 pcall 失败后仍会注册物理 identity 以避免同 Generation 重用，但不再把 degraded widget 作为可用控件返回；`RSUI:Create()` 再增加 native root usability fence，custom factory 若返回 degraded/rejected/stale root 会在 attachment 前以 `component_root_unusable` 失败并进入 strict BuildScope rollback，避免“页面构建成功但关键控件死亡”的假绿状态。
- **事件绑定与错误可观测性**：Slider 的 OnDragStart/OnDragStop 现在属于必需构造能力，绑定失败直接让 Primitive fail-closed；所有 primitive pcall 失败保留有界 Native 错误文本，不再只有泛化 `configuration_failed`。同时修复 `WarnOnce` 的 dot/colon 调用 ABI 错误；RSUI event mux 首次 SetHandler 失败时会移除无法 dispatch 的订阅，后续重试成功不会把失败订阅一起执行造成重复动作。
- **Diff cache 修复**：`UI:SetPickable()` 在 Native widget 完全没有 `EnablePick/Clickable` 能力时不再提前缓存成功值，防止后续真实 adapter/method 出现后被错误 cache-hit 跳过。
- **防回归门禁**：Foundation Gate 升 v93，新增 `v3_native_interaction_contract`；Foundation Audit 新增 RU hit-test 方法参数个数扫描、NativeSafe 多参数扫描、Edit/Slider/degraded-root contract coherence；Interactive Draft Harness 扩展为 42/42，并加入真实 Lua 行为用例验证 composite disable、unsupported pickable cache、degraded root 拒绝与 handler 首次绑定失败后的无重复恢复。
- **BuildTag**：`v3-m1.16.0.18.102-rsui-native-interaction-hardening`。

## 2026-09-04 — RU Gear TextInput Mouse Focus Hotfix

- **RU 实机反馈**：换装/称号页面的“新建方案”和“改名”输入框可以正常绘制，但鼠标点击后无法进入编辑状态。该问题对应 `.18.57` WU1 当时明确标记为“Gear TextInput 交互仍待 RU 实机验证”的未验收项。
- **根因**：共享 `UIX:CreateEditBox()` 只调用 `EnableFocus(true)`，没有像 Button 原语一样显式开启 `EnablePick(true)` / `Clickable(true)`；同时没有应用 `ui_functions.lua` 已确认的 Edit 专用 `SetReClickable(true)`。RU `CreateChildWidgetByType` 创建出的 EditBox 因而可能处于“可绘制、不可鼠标命中”的状态。
- **共享底层修复**：单行 EditBox 在 Native Primitive 边界统一启用 `Enable / EnableFocus / EnableKeyboard / EnablePick / Clickable / SetReClickable`，并显式 `SetReadOnly(false)`；Native state cache 同步标记 `enabled=true / pickable=true`。不在 Gear 页面维护第二套点击/Focus 特例。所有 `RSUI:TextInput` 与 `RSUI:NumericInput` 自动继承该修复。
- **性能/输入边界**：0 Tick / 0 轮询 / 0 新 Scheduler；没有引入未验证的 `OnTextChanged / OnKeyDown / OnKeyUp`。仍由原生 EditBox 负责鼠标命中与 Focus，提交继续只走已验证的 Enter/EditEnter/LostFocus。
- **防回归**：`rs_interactive_draft_harness.py` 由 13/13 扩展为 17/17，增加 EditBox pickable/clickable/re-clickable + native-state contract。
- **BuildTag**：`v3-m1.16.0.18.101-rsui-editbox-interaction`。

## 2026-09-04 — `.18.100` Persistence Reliability v7 Generation Reload Fence + Deferred Dirty Commit

- **继续沿保存调用链审计**：确认 v6 仍有三个底层失效窗口：普通 Store `SaveData=true` 后会进入 `needsBarrierVerify`，但在显式 Flush/Reload barrier 前若业务再次直接 `LoadStore()`，旧物理值仍可能覆盖当前较新的健康 Domain；migration/period reset 在最终 Apply 成功前就留下 dirty intent，若 Apply 失败可形成“terminal/write-fenced + dirty”的矛盾状态；Tick 对这类 dirty terminal Store 仍可能周期性重复进入 SaveStore。
- **Generation Reload Fence**：Reliability Contract 升 v7。Persistent Store 只要 `needsBarrierVerify=true`，普通 `LoadStore()` 一律 fail-closed 为 `unverified store reload rejected`，并记录 `STORE_UNVERIFIED_RELOAD_REJECTED`；只有明确的 destructive recovery 才可使用 `discardUnverified=true`。这保证本 generation 内已经写过但尚未完成 durability proof 的新 Domain 不会被潜在旧磁盘值重新 Apply。
- **Deferred Dirty Commit**：schema migration 与 Daily/Weekly load-time reset 不再在 business transform 阶段提前 MarkDirty；只有最终 Domain budget 通过且 `ApplyValue(...,"load")` 成功后才提交 dirty metadata，并记录 `deferredLoadResaves`。Apply 失败保持 terminal/write-fenced，但不会留下自动保存义务。
- **Terminal Auto-Retry Suppression**：Persistence Tick 只对 healthy-ready 且未 write-fenced 的 dirty Store执行原有 debounce SaveStore。terminal/fenced Store 保留 dirty evidence 供诊断/显式 Flush 处理，但 cadence 只把 `dueAt` 有界后移并增加 `terminalAutoRetrySuppressions`，避免失败 Store 每个保存周期持续打 Native SaveData/日志。无新增 Tick、Scheduler 或额外 Native 读取。
- **门禁/回归**：UIV3 Acceptance v64；Foundation Gate v92 新增 `persistence_reliability_v7`，正常路径要求 `unverifiedReloadRejects=0`。新增真实 Lua `rs_persistence_reliability_v7_harness.py`，覆盖 pending durability write 的 LoadStore 拒绝/Domain 保持、Flush 后正常 reload、migration Apply failure 不遗留 dirty、write-fenced dirty Tick 不重复 Native Save，以及 Contract v7 描述。v3/v4/v5/v6 harness 继续通过。
- **BuildTag**：`v3-m1.16.0.18.100-persistence-v7-generation-reload-fence`。由于 `.18.99` 未单独形成用户可下载包，本轮交付包相对 `.18.98` 累计包含 v6 + v7 必需修改；NEXT 为 RU Fresh Reload/完整退出重进，任何 `unverifiedReloadRejects>0` 都视为调用链错误证据而不是正常用户路径。

## 2026-09-04 — `.18.99` Persistence Reliability v6 Envelope Seal + Durable Commit + Character Scope Binding

- **继续沿保存底层而非 Gear 单点补丁审计**：确认 v5 仍有四个机械缺口：`durable=true` 的 `MutateStore()` 实际没有强制 immediate readback；v4/v5 `encodedFingerprint` 故意排除 `__rsmeta`，因此 schema/owner/scope 等 metadata-only 截断无法被业务指纹覆盖；custom decoder/migration 可把小型 encoded payload 膨胀为超预算 Domain 后再 Apply；Character Store 的 world-qualified identity 每次 Save 都重新解析，缺少“已加载 Domain 属于哪个角色”的强绑定。
- **Reliability v6 Envelope Seal**：新写入继续保留 Integrity v1 business fingerprint，并新增 `envelopeIntegrityVersion=1/envelopeFingerprint`。Envelope Seal 覆盖 framework/store/owner/contract/lifetime/scope/schema/period/reliability/integrity/business fingerprint/scope identity；v6 load/readback 在任何 business decoder 前先验证 seal。v4/v5 stamped save 保持向前兼容。
- **Decoded Domain Budget**：custom decode 后、migration/period transform 后分别按 Store Domain budget 检查；膨胀/循环/非法形状进入 `decoded_load_rejected`，绝不 Apply。Gear recoverable inactive bank 允许在 verified full-replacement 条件下修复该类确认损坏。
- **Durable Commit 语义修正**：`MutateStore(...,{durable=true})` 现在必定传递 `durable + verifyAfterSave`；SaveData 后同 key readback 未通过则事务回滚 Domain，并保留 durability barrier obligation。新增 `durableVerifyAttempts/Failures`。
- **Character Scope Binding**：Character Store 保存 v6 exact world-qualified identity fingerprint；loaded Domain 绑定 `resolvedKey + resolvedScopeFingerprint`。当前角色变化后 `IsStoreLoaded` fail-closed，`PrepareWrite` 仅在旧 scope 无 dirty/barrier obligation 时先 Load 当前角色再允许 mutation；debounce/Flush 对旧 dirty Domain 使用 bound old key，禁止跨角色误写。历史物理 key 算法暂不变以避免升级丢档；若两个 exact identity 因历史 lossy normalization 落到同一 key，v6 identity mismatch 直接 fence，绝不覆盖。
- **门禁/回归**：UIV3 Acceptance v63；Foundation 新增 `persistence_reliability_v6`。新增真实 Lua `rs_persistence_reliability_v6_harness.py`，覆盖 metadata-only truncation pre-decode rejection、decoded expansion budget、durable immediate verify/rollback、v5 compatibility、A/B Character scope rebind 与 lossy-key collision fence。v3/v4/v5 harness 继续兼容 v6。
- **BuildTag**：`v3-m1.16.0.18.99-persistence-v6-envelope-scope-durable`。NEXT 仍是 RU Fresh Reload/完整退出重进，新增健康要求：`envelopeIntegrityLoadFailures=0 / decodedLoadRejects=0 / durableVerifyFailures=0 / scopeBindingMismatches=0`。

## 2026-09-04 — `.18.98` Persistence Reliability v5 Durability Barrier + Verified Clear

- **继续审计保存底层**：确认 `.18.97` 仍有三个真实机械缺口：普通 Store 在本进程较早时 SaveData 成功后会变 clean，随后用户点 Reload 时旧 `Flush()` 只处理 dirty，因此不会再证明这个已写 key 的物理内容完整；v4 integrity check 的源码顺序实际仍在 custom decoder 之后，损坏表可先进入业务 decode；`ClearStore()` 只信 `ClearData=true`，若物理清理未生效会出现“本进程像是重置成功、Reload 后旧配置复活”。
- **Reliability v5 durability barrier**：普通 Store 继续保持低开销 `SaveData ×1`，成功后仅记 runtime-only `needsBarrierVerify=true`。显式 Reload/Runtime Stop 的 `Flush()` 现在分两阶段：先保存 dirty，再对本 generation 已触碰但尚未证明耐久的 key 做一次 `LoadData + metadata/integrity/decode/Domain fingerprint` 验证。任何 mismatch 都让 Flush 返回失败并阻止用户主动 Reload；Store 保持/重新进入 dirty，以当前健康 Domain 做 5s bounded retry，不把瞬时 read visibility 问题升级成永久 write fence。Critical `verifyAfterSave` Store 已即时回读成功时不会被 Flush 二次读取。
- **跨版本 integrity 兼容**：`ReliabilityContractVersion=5`，但 Integrity v1 的读取兼容下限固定为 v4；`.18.97` 已写入的 v4 fingerprint save 在 v5 下继续可读。future reliability contract 仍 fail-closed。encoded fingerprint 校验正式前移到任何 custom decoder/migrate/apply 之前。
- **Verified Clear**：`ClearData=true` 后必须立即 `LoadData(key)==nil` 才允许把默认值 Apply 到 Domain；fake-success/non-empty 或 read error 进入 `clear_verify_failed`，保留当前 Domain 并 write-fence，避免设置“暂时消失、重载复活”。
- **健康状态统一**：Persistence Core 的 `CanWrite/PrepareWrite/SaveStore/MarkDirty/period reset/Describe/RuntimeAcceptanceSnapshot` 与 Persistent UI Binding 统一消费健康 `IsStoreLoaded()` 语义；terminal failure 不再被 UI/通用写路径当成 ready。新增 `barrierVerify* / clearVerify* / barrierPending` 诊断。
- **门禁/回归**：Foundation Gate v91 / UIV3 Acceptance v62；新增 `rs_persistence_reliability_v5_harness.py`，覆盖 v4→v5 兼容、integrity-before-decode、普通 Store barrier 检出静默截断→requeue→恢复、Critical Store 无重复 readback、ClearData fake-success fail-closed。v3 22/22、v4 35/35、Snapshot 19/19 继续通过。
- **BuildTag**：`v3-m1.16.0.18.98-persistence-v5-durability-barrier`。NEXT 仍是 RU Fresh Reload/完整退出重进，但验收口径升级为 v5：重载前 `barrierPending` 可非 0，真正触发重载时必须 barrier 全部通过；`barrierVerifyFailures/clearVerifyFailures/integrityLoadFailures/readbackVerifyFailures=0`。

## 2026-09-04 — `.18.97` Persistence Reliability v4 Cross-Reload Integrity + Gear Journal Self-Heal

- **继续追查保存底层，不只盯 Gear UI**：审计发现 `.18.95` 的 immediate readback 只能证明“刚写完马上读”一致，无法证明下一次 Reload/完整重启后仍完整；另外 `IsStoreLoaded()` 把 `decode_failed/metadata_mismatch/future_schema` 等终态也暴露成“已加载”，Feature 可能把空缓存当成健康 Domain；Gear A/B active bank 损坏后虽然能回退 backup，但被 Persistence write-fence 的损坏 inactive bank 会阻止下一次 A/B 自愈写回。
- **Persistence Reliability v4**：所有新持久化写入在 `__rsmeta` 增加 `reliabilityContract=4 / integrityVersion=1 / encodedFingerprint`。Fingerprint 对**编码后的业务 envelope（排除 `__rsmeta`）**计算，而不是对当前 decoder 产物计算，因此既能检测跨 Reload 字段截断，又不会因未来合法 decoder/schema migration 变化产生假损坏。普通 Store 不增加 readback I/O；Critical Store 仍保留 v3 的 immediate decode-only readback。
- **Load 边界前置完整性**：`LoadStore()` 先按 `encodedBudget` 检查磁盘 envelope，再校验 v4 encoded fingerprint，全部通过后才进入业务 decode/migrate/apply。损坏表进入 `encoded_load_rejected` 或 `integrity_failed` 并 write-fence；pre-v4 未带 reliability marker 的历史存档继续可读，下一次正常保存自然升级。
- **健康 loaded 语义修复**：`IsStoreLoaded()` 现在只对 `loaded/empty/saved/session` 返回 true；“LoadData 已结束但失败”的内部 terminal state 不再伪装成业务可用状态。该修复直接封住 Gear Payload failed-load 后复用空 cache 的路径。
- **Gear A/B 自愈补链**：A/B bank 注册为 `recoverableReplacement`。只有 `decode_failed / metadata_mismatch / integrity_failed / encoded_load_rejected` 这类已确认损坏的**完整 journal shard**，且单次写入显式 `replaceCorrupt=true + verifyAfterSave=true` 时，才允许覆盖 fenced inactive bank；必须 SaveData + readback 全通过后才清 fence。`future_schema` 与瞬时 `load_failed` 永远不能用此路径覆盖。
- **诊断/门禁**：Foundation Gate v90 / UIV3 Acceptance v61 新增 Reliability v4 + Integrity v1 contract；统计 `integrityStampedSaves / integrityLoadChecks / integrityLoadFailures / integrityLegacyLoads / encodedLoadRejects / verifiedReplacementRecoveries`。新增真实 Lua 故障注入 `PERSISTENCE_RELIABILITY_V4_HARNESS PASS 35/35`，覆盖 later-process truncation、legacy unstamped、malformed envelope、failed-load healthy semantics 与 verified replacement recovery；v3 22/22 和 Snapshot 19/19 继续通过。
- **BuildTag**：`v3-m1.16.0.18.97-persistence-v4-cross-reload-integrity`。NEXT 仍为 RU Fresh Reload；现在首要观察 v4 `integrityLoadChecks` 是否随 Reload 增长且 `integrityLoadFailures/encodedLoadRejects/readbackVerifyFailures=0`。

## 2026-09-04 — `.18.96` Unit Lines Coordinate Consistency + Team Auto-Role Ranged Hotfix

- **RU 实机反馈（P0 回归）**：`.18.88` 已能剔除相机背后的镜像端点，但用户在真实战斗截图中继续确认前方单位连线仍会指向明显不属于单位的位置。重新沿 `UnitLines → ScreenProjectionV3 → X2Unit` 检查后确认两个薄弱点：① batch 对 `player` 单独传 `isLocal=true`、其它 token 传 `false`，Camera Frame 却只在一个世界空间内计算，存在混合空间端点；② `GetUnitScreenPosition` 的坐标即使实际处于 physical/UI-scale 空间，只要数值仍落在 logical viewport 内，旧阈值归一化就会把它误判为合法 logical 坐标。
- **ScreenProjectionV3 v5**：Unit Line batch 统一用 `GetUnitWorldPositionByTarget(token, false)` 获取同一全局空间坐标；在既有一次 Camera Frame + world read 上增加 bounded Native/Camera consistency gate。Native 点先与 camera-world logical 点比较；UI scale 候选明显更接近时使用 `native_scale_reconciled`，仍超出容差则使用 `camera_consistency_fallback`。behind-camera 仍在 Native screen read 前拒绝；不增加第二次 world/camera 查询，也不改变 Healer/Buff Display 的普通 `ProjectUnit()` 行为。新增 `nativeScaleReconciles/nativeConsistencyFallbacks` 诊断。
- **Unit Lines 契约**：`combat_unit_lines` 仅在 `ProjectUnitBatch` 调用上启用 `validateNativeAgainstCamera + reconcileNativeScale`，保持 Feature Demand/P1 cadence、`.18.87` adaptive sampling、viewport clipping 与 Presenter diff 不变。新增 `ProjectionConsistencyContractVersion=1`。
- **团队自动职责修复**：静态职责目录升 v2。`name_6_8_9`（用户报告的 吟游+暗杀+野性）从普通 `dealer` 更正为 `ranged`；同时把目录中所有明确 `classType="Archer"` 的 7 个精确职业组合统一映射到 `TMROLE_RANGED_DEALER`，Gunner 原有 ranged 规则不变。没有按“只要含野性就远程”做模糊推断，Songer/Tank 等既有精确组合不受影响。
- **防回归**：Foundation Gate v89 / UIV3 Acceptance v60 要求 ScreenProjectionV3 v5 consistency contract 与 TeamAutoRoleCatalog v2；Foundation Audit 禁止 `Archer → dealer` 回归，并锁定 Unit Lines 的 consistency options。`SCREEN_PROJECTION_FRONT_HEMISPHERE_HARNESS PASS 14/14`（新增 same-world、UI-scale reconciliation、valid-but-stale in-bounds fallback）；Team catalog 本地检查 7/7 Archer 全部 ranged。
- **BuildTag**：`v3-m1.16.0.18.96-unit-lines-projection-team-role-hotfix`。RU Fresh Reload 仍是下一 Gate；本轮是用户实机 blocker 修复，不提前开启新的业务 UI 迁移。

## 2026-09-04 — `.18.95` Persistence Reliability v3 + Gear A/B Payload Journal

- **真实 RU 回归提升为 P0**：用户确认换装方案名称在 Reload 后仍存在，但方案内部装备数据无法继续换装。代码核查确认 Gear 本来就是“轻量 Index + 独立 Payload shard”双层保存：名称/顺序保存在 `v3.gear.index`，19 槽装备身份与称号保存在 `v3.gear.payload.N`。旧路径只信任 `SaveData=true`，没有回读证明，因此“Index 还在、Payload 已截断/损坏”能够形成用户看到的精确症状。RU 客户端是否就是 SaveData 静默截断仍需 Fresh Reload 证据，但该失效模式现在被底层明确封死。
- **Persistence Reliability Contract v3**：新增 opt-in `verifyAfterSave` / `VerifyPersistedValue()`。Critical Store 在 `SaveData` 返回成功后立即以同一 resolved key `LoadData`，只做 metadata + decode + Domain fingerprint 校验，**不调用 `store.apply()`**，因此不会形成第二 Domain Authority。回读缺失、schema/meta 不匹配或内容指纹不同都记为 `readback_verify_failed`，本次写入不计为可靠 commit；普通 Store 默认不启用，避免所有设置双倍 I/O。
- **Gear Payload Journal**：Gear Index 升 schema 5，Payload 升 schema 2。每个方案新增 A/B 两个 payload bank；保存时只写当前 active bank 的另一侧，写入成功且回读验证通过后才更新 Index 指针/指纹。Index commit 失败时不再把旧 payload 覆盖回去，旧 Index 仍指向上一份已验证 payload；active bank 异常时可按 Index 保存的 backup bank + fingerprint 回退。Gear Index 自身也启用 readback verification。
- **Compact Payload**：新 payload 使用短键编码，并从固定的 19 槽 `GearV3.EquipmentSlots` 重新构造 slotName/key/alternative，避免每个装备重复保存静态字段，显著降低 SaveData 节点/字符串压力。旧 schema 1 单 bank key 永久保留只读兼容；读取正常旧 payload 后，下一次用户保存自然迁移到 A/B，不做破坏性批量迁移。
- **损坏分片 fail-closed + 可重建**：configured payload 若只剩空壳、managed 装备缺 slot/name、或启用称号却缺 effect id，会直接标记为分片不可用，不再把残缺数据交给 Apply/Validate。已经在旧版本中丢失的真实装备明细无法由方案名称反推；用户可选中该方案，执行一次“获取当前”再“保存方案”，显式按当前穿戴重建并进入 A/B journal。Start/Validate 永远不会自动覆盖历史方案。
- **诊断/测试**：Foundation `persistence_reliability_v3` 追加 `verify success/attempt/fail`；readback failure 进入 incident warning。UIV3 Acceptance 升 v59 并声明 `PersistenceReliabilityV3ContractVersion=1`。新增 `rs_persistence_reliability_v3_harness.py`，真实 Lua 故障注入覆盖成功回读、`SaveData=true` 但 payload 静默缺字段、decode-only 不 Apply、普通 Store 不增加 readback，`22/22 PASS`。Gear Acceptance 同步锁定 schema 5/2、A/B、compact roundtrip、configured-empty corruption rejection。
- **BuildTag**：`v3-m1.16.0.18.95-persistence-v3-gear-journal`。NEXT 仍是 RU Fresh Reload，但 Gear Persistence v3 现在是首要验收项；通过前不宣告保存系统已完成。

## 2026-09-04 — `.18.94` Trade/DPS Fresh Reload Preflight Contract

- **继续执行 CURRENT §9，而不是跳过 RU Gate**：`.18.93` 已修复 DPS Reload 自动弹窗与 Trade Dropdown/Quote；本轮不新增业务功能，只把这两条实机回归升级为封包前 package-coherence + runtime acceptance preflight，确保下一次 RU Fresh Reload 测到的是完整修复包，而不是“代码已改但某个文件漏包”的状态。
- **DPS 可见性一致性门禁**：UIV3 Acceptance v58 新增 `TradeDpsFreshReloadPreflightContractVersion=1`。运行时只读检查 `v3.dps` Store schema 4、Feature `widgetVisible`/公开 Command，以及 WidgetHost `combat.dps` lifecycle `preference()` 的真实返回值必须与 `GetWidgetVisible()` 一致；若再次回退成无条件 auto-show，直接报 `dps_widget_visibility_preference_contract`。
- **Trade Dropdown/Quote 一致性门禁**：运行时 preflight 要求 Trade Feature 暴露 `GetRouteSettings / SetFrom / SetTo / QuotePendingMaterials`，Projection 保持 `zones/sellableZones/pendingQuoteCount`，Life Economy Widget 版本满足当前 Dropdown/Quote Consumer 契约；缺失时报 `trade_dropdown_quote_preflight_contract`。这只证明公开链路与封包一致，Native popup 是否真正展开仍必须由 RU 点击验证。
- **Foundation package-coherence**：`rs_foundation_audit.py` 新增 `.18.94` 精确检查：DPS schema/visibility/lifecycle 不得漂移；Trade 页面/HUD 必须保持两级 Dropdown + 材料询价；四个起终点循环按钮及 Presentation `CycleFrom/CycleTo` 调用不得回归；静态 Zone 仅作候选，服务器 `GetSpecialtyRatioBetween` 仍为路线 Authority；报价完成必须重建受影响材料投影。
- **验证**：Foundation Audit PASS；Workspace Smoke 27/27；Presentation→Feature API self-test 5/5；Persistence Snapshot 19/19；Interactive Draft 13/13；Bag 4/4；Unit Lines 11/11；Front-Hemisphere 10/10。
- **BuildTag**：`v3-m1.16.0.18.94-fresh-reload-preflight`。NEXT 仍是 **RU Fresh Reload + Persistence Reliability v2 Runtime Acceptance**；通过前不进入下一业务 UI Gate。

## 2026-09-04 — `.18.93` DPS Visibility + Trade Dropdown/Quote RU Hotfix

- **DPS reload 自动弹窗根因修复**：`combat.dps` WidgetHost lifecycle 之前把 `preference()` 硬编码为 `true`，因此只要 DPS Feature 偏好启用，每次 reload 都会自动 `Show()`，与用户是否关闭悬浮窗无关。`v3.dps` Store 升 schema 4，新增 durable `widgetVisible`；Show/Hide/Native Close 只在 `persist~=false` 时写入该偏好，auto lifecycle 只读取该字段。旧 schema 1–3 无字段会迁移为 `false`，因此本次升级不会继续继承“永远弹出”的旧行为。
- **Trade 下拉可用性**：`Trade.Authority:RefreshZones()` 不再在 RU `X2Store:GetProductionZoneGroups` 调用失败时直接 `unavailable + return`；与既有 empty-payload policy 一致，失败时也可使用 sealed 34-zone candidates，并保留 error/fallback 诊断。最终路线仍只由 `GetSpecialtyRatioBetween` 服务器返回判定，静态数据不升级成 Authority。
- **Trade 页面布局**：删除 `起点◀/起点▶/终点◀/终点▶` 四个冗余按钮及 Presentation 对 `CycleFrom/CycleTo` 的契约依赖。主页面改为“起点 / 目的地”两行 Dropdown-only 布局，状态行移到路线控件之后，降低 1024 宽度下的拥挤。兼容 Feature cycle Commands 保留，不删除旧 API。
- **Trade HUD 补齐询价**：Floating Widget 同样改成两行 Dropdown-only 路线布局，并在目的地行新增“材料询价”。页面与 HUD 不再各自遍历业务材料，统一调用 `Trade:QuotePendingMaterials()`，批量提交仍受 `PriceQuoteQueueV3.maxQueue` 与显式用户动作约束，普通 Refresh 不产生 Auction fan-out。
- **材料成本/利润真实回写修复**：修复 `BuildTradeMaterialProjection` 的 `complete` 初始值错误及 quoted/excluded 小计从未累加的问题；报价 callback 不再只加 revision，而是只查找引用该 `materialKey` 的当前路线行并重建其材料投影。所有必需材料完成报价后，`materialCostCopper/profit` 才转为完整值，未完成项继续明确显示未知。
- **静态门禁**：DPS Acceptance 要求 Store schema 4 + visibility public facade；Presentation→Feature API Audit PASS（calls=358），RSUI Component API Audit PASS（calls=470）。
- **BuildTag**：`v3-m1.16.0.18.93-trade-dps-runtime-ux-hotfix`。RU NEXT：Fresh Reload 验证 DPS 关闭后不再自弹、Trade 两级下拉 popup、HUD 询价与异步成本/毛利回写。

## 2026-09-04 — `.18.92` Presentation→Feature API Contract Audit + Missing Command Repair

- **继续 Foundation First，不跳过 RU Gate**：CURRENT §9 的 NEXT 仍是 RU Fresh Reload；本轮只完成 Fresh Reload 前还能由本地真实代码证明的 Public API 收口，不提前进入下一业务 UI Gate。
- **新增 Presentation→Feature Public API 封包门禁**：`tools/rs_presentation_feature_api_audit.py` 从真实 Feature provider 提取公开方法与 `Commands`，覆盖 split Feature、`S.Features.Name = LocalFeature` bundle、以及 `NewFeature("id", spec)` business provider，再扫描 `presentation/v3` 的静态 Feature consumer。Lua 语法合法但 provider 未导出的 `Feature:Method()` / `Feature.Commands:Method()` 现在会直接阻断 Foundation Audit；显式 capability guard 继续允许。动态 `S.Features[expr]` 仅计数，不猜表达式，仍由既有 BusinessPages/Acceptance 证明。
- **首轮审计直接发现 3 个真实漏接**：Tasks 与 Activities 悬浮窗均把 `setState` 绑定到 `Feature.Commands:SetWidgetWindowState`，但 Commands facade 从未导出该方法；Gear Quick Settings Modal 调用 `Feature.Commands:ResetQuickSnapSettings`，而 Gear Commands 同样缺失。三条都可能在页面已能打开之后，于拖动/缩放悬浮窗或点击 Gear 重置时才报 `attempt to call method ... nil`，因此旧 Lua Parse/Component API Audit 无法覆盖。现分别补齐只转发到既有 Feature Authority 的 Commands，不新增第二状态。
- **Runtime/package coherence**：Tasks/Activities/Gear 各自 Acceptance 同步要求新 Command；Foundation Gate 升 v88 并新增 `v3_presentation_feature_api_contract[tasksWindow/activitiesWindow/gearReset]`，避免未来增量包漏文件时只靠开发机静态工具发现。
- **Auditor self-test**：新增 `tools/rs_presentation_feature_api_audit_harness.py`，覆盖 valid static provider、missing command 必须失败、explicit guard 允许、`NewFeature` spec command、bundle export 五类，`5/5 PASS`。当前真实工程扫描：`providers=36 / usedProviders=25 / aliases=45 / calls=353 / dynamicAliases=5`，**0 缺失静态 Feature API**。
- **验证**：210/210 Active Lua Parse、Foundation Audit PASS（新增 `presentationFeatureApi=1`）、Component API Audit PASS、Presentation Feature API Audit PASS、Workspace 27/27、Persistence 19/19、Interactive Draft 13/13、Bag 4/4、Unit Lines 11/11、Front-Hemisphere 10/10。
- **BuildTag**：`v3-m1.16.0.18.92-presentation-feature-api-contract-audit`。RU NEXT 不变：Fresh Reload 后重点验证状态显示/Persistence，同时新增 Tasks/Activities 浮窗拖动保存与 Gear Quick Settings Reset 三条 spot-check。

## 2026-09-04 — `.18.91` RSUI Prepackage Contract Audit

- **同类页面崩溃继续扫描**：不是继续给某个页面写 `nil` 特判，而是新增 `tools/rs_rsui_component_api_audit.py` 扫描全部 `presentation/v3` 的已识别 RSUI Component 构造与方法调用；公共 Base API 从运行时代码提取，类型特有 Public API 显式列入 reviewed contract。未知方法若没有 `type(component.Method)=="function"` capability guard，Foundation Audit 直接失败。当前基线：29 个 Presentation 文件 / 501 构造 / 466 方法调用 / 5 guarded，**0 未保护 API 越界**。
- **Workspace 真构建覆盖扩大**：`RSUI_WORKSPACE_SMOKE_HARNESS` 从 LayoutEditor 单一路径扩展为 MasterDetail / InspectorWorkbench / ResponsiveInspector / LayoutEditor / SettingsWorkbench / CommandCenter 六类公共模板，真实 texlua 构建 `27/27 PASS`；Button mock 继续故意不实现 `Show()`，确保 scaffold 不能依赖未声明 convenience method。
- **TOC 依赖顺序硬门禁**：Foundation Audit 新增 RSUI top-level fail-closed dependency provider-before-consumer 检查；Framework 若在加载时要求 `RSUI.ListView/Windowing/...` 已存在，则 provider 必须在 toc.g 更早。用于阻止 `.18.81` TreeView/ListView 类“文件都在但顺序使组件未注册”的回归。
- **发现并修复开发 Gate 自身缺陷**：`rs_unit_line_sampling_harness.py` 与 `rs_screen_projection_front_hemisphere_harness.py` 的默认 `--root=replicatedsuite` 依赖当前工作目录，从工程根执行会错误查找双重 `replicatedsuite/`。现改为脚本文件位置解析工程根；从 `replicatedsuite/` 与其父目录调用均分别通过 `11/11`、`10/10`。
- **运行时影响**：除 BuildTag 更新外不改变 Feature/Store/TOC/RSUI Runtime 行为；新增检查均为 developer-only prepackage tools。RU Fresh Reload 仍是下一 P0 Gate。
- **BuildTag**：`v3-m1.16.0.18.91-rsui-prepackage-contract-audit`。

## 2026-09-04 — `.18.90` RSUI Component API + Package Coherence RU Hotfix

- **第六次“页面打不开”根因收口**：RU 堆栈确认 `ui/framework/rs_ui_workspace_templates.lua:341` 对标准 `Button` Component 调用了不存在的 `Show()`。这不是 Native 失败，而是 Lua 动态 method lookup 在语法检查阶段无法发现的 Public API 漂移；BuildTransaction 因异常正确 rollback/quarantine，但用户仍无法进入页面。
- **RSUI Component API Contract v1**：RSUI 升至 v44 / API 12.8。Base Component 统一提供 `Show/Hide → SetVisible` facade；新增 `RequireComponentMethods()`，Composite/Workspace 在构建边界显式校验真实调用方法。`RSUI:Create()` 同时验证所有组件的公共 `GetRoot/SetVisible/Show/Hide/SetEnabled/Release` 契约，不新增 Tick/Render 扫描。
- **WorkspaceTemplates v6 / LayoutEditorWorkspace v4**：Inspector Toggle 改用共享 `SetVisible(drawer)`，并对 ResponsiveInspector、Toggle、StatusChip、LayoutEditorOverlay、TransformInspector、EditorCommandBar 做构建期 Public API fence。新增真实 Lua `RSUI_WORKSPACE_SMOKE_HARNESS`，Button mock 故意不实现 `Show()`，因此同类回归会在封包前失败。
- **Persistence package-coherence 修复**：用户诊断同时暴露 `persistence_runtime_acceptance_snapshot[contract=0/fingerprint=false/snapshot=false]`。检查完整工程确认 `.18.84` 的 Gate/Docs 已存在，但 `core/rs_persistence.lua` 的 `RuntimeAcceptanceSnapshotContractVersion/FingerprintPayload/BuildRuntimeAcceptanceSnapshot` 以及诊断页“输出存档验收”实现未进入当前完整包。`.18.90` 恢复这些运行时实现，并新增 Foundation Audit package-coherence fence + `PERSISTENCE_ACCEPTANCE_SNAPSHOT_HARNESS`，禁止以后再次出现“文档/Gate 已升级但实现漏包”。
- **验证**：Foundation Gate v87、UIV3 Acceptance v57、Workspace v6、LayoutEditorWorkspace v4。新增 non-destructive Sequence `v3_56_ui_component_api_contract`；封包前必须通过 210/210 Lua Parse、Foundation Audit、Workspace Smoke、Persistence Snapshot、Interactive Draft、Bag/Unit Lines/Front-Hemisphere 回归。

## 2026-09-04 — `.18.89` RSUI Interactive Draft + Compact Layout Inspector RU Hotfix

- **RU 实机反馈**：状态显示 HUD 布局在当前窗口宽度下没有可见的 X/Y/宽高等参数入口；Slider 拖动时每帧在预览值与旧值之间来回跳；Numeric/EditBox 删除或输入字符后会立即恢复旧文本。代码核查确认参数模型并未缺失，而是 Compact ResponsiveInspector 把唯一 TransformInspector 收进 Drawer 后，LayoutEditorWorkspace 漏了打开 Drawer 的用户入口；同时共享 Control `Render()` 会在 Aura/页面环境刷新时把尚未 Commit 的 Slider Preview / focused Edit draft 用旧 Binding 值覆盖。
- **RSUI Interactive Draft Contract v1**：RSUI 升至 v43 / API 12.7，TextInput/NumericInput 在 Native EditBox 获得焦点期间拒绝 ambient binding refresh 覆盖草稿；Slider 在 active drag 期间拒绝 ambient Render 回灌旧值。显式 API、interaction preview 与 final commit 仍可覆盖。未引入猜测的 `OnTextChanged/OnKeyDown/OnKeyUp`，继续复用已验证 Focus identity 与现有 drag state。
- **NumericField v4**：`SyncControls(value, source)` 显式传播 `binding_refresh / interaction / commit` 来源；Slider Preview 只同步当前 draft，最终 Commit 才推进 Binding，避免父 Field 刷新重新引入旧值。
- **LayoutEditorWorkspace v3 / WorkspaceTemplates v5**：Compact/Drawer 模式在稳定 Toolbar 增加 `[属性] / [收起属性]` 按钮，调用 SAME ResponsiveInspector Drawer，不 reparent、不复制 Inspector；状态显示进入 HUD 布局时在 Compact 模式自动打开属性 Drawer，选中元素也允许自动打开，从而恢复 X/Y（左-/右+、上-/下+）、宽高、Anchor/Pivot、Snap 等共享 TransformInspector 参数。
- **状态显示刷新边界**：`v3.buff_display.updated` 只在 `追踪管理` 页刷新 Aura Table；HUD Layout 的 isolated Working 不再被 Aura cadence 重绘。其他必要页面刷新仍由共享 Interactive Draft fence 保护，因此修复不依赖页面级“正在输入”第二份状态。
- **防回归/验证**：Foundation Gate v86、UIV3 Acceptance v56、Workspace v5 静态门禁要求 compact inspector affordance；Audit 还要求 BuffDisplay compact auto-open 与 Aura refresh boundary。新增 `RS_INTERACTIVE_DRAFT_HARNESS PASS 13/13`，真实加载 controls 并验证 focused text/numeric draft、slider preview、commit/resync。
- **BuildTag**：`v3-m1.16.0.18.89-rsui-interactive-draft-layout-inspector`。RU 下一步重点实测 Compact HUD 属性 Drawer、X/Y 精确输入、Slider 连续拖动与 Aura 高频刷新期间的输入草稿稳定性，再继续 Fresh Reload 矩阵。

## 2026-09-04 — `.18.88` Unit Lines Front-Hemisphere Cull RU Hotfix

- **RU 实机反馈**：目标位于玩家视野背后时，单位连线会错误指向屏幕边角。`.18.87` 已解决长线采样与 viewport clipping，但仍信任 `GetUnitScreenPosition` 的正 depth；RU 某些背后角度会返回正 depth + 镜像/边角屏幕点，因此 Presenter 正常裁剪反而把错误端点保留下来。
- **投影 Authority 修复**：`ScreenProjectionV3` 升至 v4，新增 `ProjectUnitBatch()` / `FrontHemisphereBatchContractVersion=1`。Unit Lines 每次 Demand refresh 只构建一次 Camera Frame，对启用 pair 所需 `player/target/targettarget/watchtarget/watchtargettarget` token 去重后读取世界坐标，并以 `dot(unit-camera, cameraForward)` 判定前半球；`forward<=epsilon` 返回 `behind_camera`，在 Native screen projection 与 Presentation clipping 前 fail-closed。
- **前方屏外兼容**：若单位在相机前半球但 Native unit screen point 出界，batch 使用同一 Camera Frame 做 logical world fallback，保留真实超屏坐标，继续交给 `.18.87` Liang-Barsky 裁剪。不会用“靠近屏幕边角就隐藏”的启发式误杀正常前方目标。
- **性能/生命周期**：Camera Pos/Dir/Fov 每 batch 各读取一次，不按 4 条 pair 重复抓取；unit token 去重，最多处理当前四条关系实际涉及的 5 个 token。无新 Tick/Scheduler/Store/schema；HighFrequency P1、adaptive density、pressure budget、Native Diff、progressive pool 全部保持 `.18.87` 契约。
- **防回归/验证**：Foundation Gate v85、UIV3 Acceptance v55、Foundation Audit 增加 ScreenProjection v4 + front-hemisphere batch fence，并禁止 Unit Lines 回退逐端点 `ProjectUnitFlexible()`。`SCREEN_PROJECTION_FRONT_HEMISPHERE_HARNESS PASS 10/10`，模拟“behind + positive depth + corner coordinate”确认在 Native screen read 前拒绝；`UNIT_LINE_SAMPLING_HARNESS PASS 11/11` 保持通过。
- **BuildTag**：`v3-m1.16.0.18.88-unit-lines-front-hemisphere-cull`。

## 2026-09-04 — `.18.87` Unit Lines Adaptive Density + Crowd Smooth Refresh RU Hotfix

- **RU 两次连续实机反馈**：①近距离 dots 很密，但距离拉远后固定点数被摊开，某些斜角/屏幕边缘甚至整段看不见；②多人场景线条刷新“一卡一卡”。代码核查确认两个独立根因：旧 Presenter 把 `pointCount` 当最终点数且不先裁 viewport；Unit Line 虽使用 HighFrequency lane，却显式注册成 P3，FrameBudget 在拥挤/低帧时会不规则延后整次刷新。
- **自适应密度 + 可见段裁剪**：`CombatVisualGuidesV3 v5` 保留旧 `pointCount/pairPoints(8..48)` Store 作为基础密度，不迁移 schema。先用 bounded Liang-Barsky 裁剪 logical viewport 可见段，再按 240 logical px 参考长度换算 spacing；短线保持基础密度，长线自动补点，单 Edge hard cap=160。端点远离屏幕但关系线穿屏时仍绘制；整段确实不经过 viewport 或 depth<=0 才 fail-closed。
- **Crowd Smooth Refresh**：`UNIT_LINE_TASK` 从 P3 改为 P1 visual cadence，避免压力场景整批 refresh 被 Scheduler 延后。负载控制改到 Presenter 内部：Normal/Busy/Heavy/Critical 对 adaptive extra 使用 100%/82%/68%/55% budget，但永远不低于用户 persisted base density；不会用“整帧不更新”换性能。
- **Native Diff**：新增 Presenter-local per-dot render cache。稳定几何/外观下不再重复调用 RSUI 的 Extent/Color/Visible/Anchor compatibility path；移动线通常只发生 Anchor 写。这个局部缓存不替代 RSUI Authority，只用于高频 HUD 在调用 RSUI 前判断“值根本没变”，避免几百个 dot 每帧触发 Native getter 验证。
- **渐进点池**：长线首次出现/距离突然拉长时，不再单帧创建上百个 Native Widget；点池按压力每 Render 最多增长 48/32/24/16，后续帧继续补齐并复用。Feature Disable/Consumer release 仍只隐藏/停止原有 Demand 资源，不新增 Tick/Scheduler。
- **设置/诊断兼容**：设置页“点数”继续显示为“基础密度”，提示更新为多人压力只削减额外补点。Feature projection 增加 runtime `pointBudgetMode=cadence_pressure_bounded / refreshPriority=P1_visual`；Presenter `Describe()` 暴露 `unitPressure/requestedDots/visibleDots/poolGrowth/anchorWrites/styleWrites/visibilityWrites`，便于 RU 二次定位。Store/schema/key 不变。
- **防回归**：`UnitLines.VisualGuideContractVersion=4 / AdaptiveDensityContractVersion=2 / SmoothRefreshContractVersion=1`；Presenter `AdaptiveUnitLineSamplingContractVersion=2` + clipping/pressure-budget/diff/progressive-pool contracts；Foundation Gate v84、UIV3 Acceptance、`v3_55_unit_line_adaptive_sampling_contract` 同步升级。Foundation Audit 禁止固定最终 8..48 点和 Unit Line HighFrequency 回退 P3。
- **验证**：`UNIT_LINE_SAMPLING_HARNESS PASS 11/11`，覆盖 near/long/clipping/offscreen、1ms/100ms budget、Critical extra shedding、Critical progressive growth≤16、Normal growth≤48、稳定帧零冗余属性写、移动帧仅 Anchor 更新；Foundation Audit PASS。
- **BuildTag**：`v3-m1.16.0.18.87-unit-lines-adaptive-smooth-render`。RU 下一步重点验证 1024×768/1080P/2K 的近远距离与斜角可见性，以及主城/团战多人压力下刷新连续性。

## 2026-09-04 — `.18.86` Bag Dynamic Source Resolution RU Hotfix

- **RU 实机根因修复**：用户确认“存放/放同类每点一次只移动一个物品”。旧 quick/category queue 预存 `slot`，但 `MoveToEmpty*` 成功后客户端会压缩/重投影源容器，导致同类物品补进刚清空的槽；旧 verifier 将“原槽仍有同类物品”误判为移动失败并停止，后续预计算 slot 也失效。
- **Bag Move Contract v5**：quick queue 只保存稳定 `itemType` 意图，category batch 只保存稳定 `category` 意图；每个 250ms Scheduler step 在 Action 前调用统一 `BagMoveRuntime.FindLiveMoveSource()` 重新解析当前源槽，并在 live row 上再次执行 blacklist。slot 只存在于“本次写入 + 下一拍验证”的 transient pending，不再跨多个队列步骤充当身份。
- **压缩槽位验证**：正常情况下原槽为空/身份变化即可确认成功；若另一件同类物品补到原槽，才调用 `CountLiveMatches()` 做 bounded source-population decrease 验证。源数量下降则继续队列；数量不变仍 fail-closed，保留 RU 2026-06-02 intermittent move fix 之后的失败防护。Category batch 同样处理非空补位，不再要求原槽绝对为空。
- **生命周期/性能不变**：Quick/Category 继续互斥；每步最多一条写操作；仍使用 250ms P1 Scheduler、40 次 hard cap、240 槽 scan bound；无 Tick/新 OnUpdate。完整扫描只出现在初始计划或 post-write 槽位歧义路径，常规每步只扫描到首个 live match。窗口关闭/切换、用户取消、Feature Disable 仍释放任务和运行态。
- **防回归**：`BagMoveContractVersion=5 / BatchLifecycleContractVersion=5 / NativeWindowQuickContractVersion=3 / DynamicSourceResolutionContractVersion=1`；Foundation Gate/UIV3 Acceptance 升级到 bag v5。`rs_foundation_audit.py` 明确禁止 serial plan 再保存 transient slot；新增 `tools/rs_bag_move_queue_harness.py`，quick same-type compaction / mixed type / category+blacklist / failed-write 四类测试 `4/4 PASS`。
- **BuildTag**：`v3-m1.16.0.18.86-bag-dynamic-source-resolution`。RU 下一步仍为 CURRENT §9.2 Fresh Reload，同时优先复验一次点击“放同类/高级整理”是否能连续处理多件。

# Replicated Suite 变更记录（Changelog）

## 2026-09-04 — `.18.85` Buff Display Coordinate-Space RU Hotfix

- **用户实机阻断**：状态显示无法打开，诊断稳定报告 `layout_editor_overlay_coordinate_space_required`，并触发 Page quarantine / BuildTransaction rollback / preflight fail。
- **真实根因**：`rs_v3_buff_display_page.lua` 的首个真实 `LayoutEditorWorkspace v2` Consumer 声明 `coordinateSpace="local"`，但遗漏 `pointerToLocal`；PointerService 采样的是 viewport-logical 坐标，因此共享 Overlay Validator 正确 fail-closed。没有放宽 Foundation，也没有把 local 错标为 viewport。
- **修复**：新增 `ViewportPointerToEditorLocal()`。手势采样时从 Gesture Controller 的 SelectionOverlay 追溯唯一 LayoutEditorOverlay native root，调用 `Layout:GetLogicalRect()` 获取实时 logical origin/extent，再按声明的 640×320 editor canvas 映射 viewport pointer；不缓存 geometry，避免窗口移动、Responsive reflow、ScaleBox、UI Scale 后拖动漂移/比例失真。Native/root 不可用时返回 nil，由 Gesture 契约继续 fail-closed。
- **回归门禁**：Foundation Audit 新增 Buff Display local coordinate Consumer fence，要求 `coordinateSpace="local"` 与显式 `pointerToLocal` 成对存在，并验证转换仍基于 live editor root logical rect。
- **兼容性**：不改 Store/schema/TOC/Feature 生命周期/共享 LayoutEditorOverlay Contract；只修 Presentation 坐标适配和静态门禁。
- **BuildTag**：`v3-m1.16.0.18.85-buff-display-coordinate-space-hotfix`。RU 下一步仍为 CURRENT §9.2 Fresh Reload；重点先验证状态显示页面可打开、Build Transaction 计数清零及 HUD 拖动/缩放方向正确。

## 2026-09-04 — `.18.84` Persistence Fresh Reload Fingerprint

- **Fresh Reload 内容证据**：Persistence 新增 `RuntimeAcceptanceSnapshotContractVersion=1`、`FingerprintPayload()` 与 `BuildRuntimeAcceptanceSnapshot()`。指纹直接基于 Store `get()` 的 Domain save snapshot，先走现有 SaveData budget，再按稳定 key 顺序计算；table 插入顺序不会导致假差异，字段变化会改变指纹。
- **严格只读边界**：Snapshot 不自动 Load、不 Flush、不 Save、不改 dirty/fence，也不读取 `payload/__rsmeta` 编码 envelope；冷 Store 明确输出 `store_not_loaded`，避免默认值冒充真实回读。Persistence Core 保持业务 ID 无关。
- **诊断 UI**：`诊断与维护` 新增独立第三行“输出存档验收”。当前验收清单覆盖 Buff Display、Healer、Gear Index、Activities、Tasks、DPS、Trade；已注册的 `v3.gear.payload.*` 动态进入 `ALL` 总指纹，详细 payload 行最多 8 条，剩余只报数量。输出同时包含 loaded/dirty/fence/schema/dirtyRevision/lastSavedRevision。
- **Gate**：Foundation Gate 升 v82，新增 `persistence_runtime_acceptance_snapshot` blocker contract；没有 Snapshot API 或 contract version 不足时拒绝宣告 Foundation Ready。
- **兼容性**：没有新增 Store、没有 SaveData key/schema/metadata 变化、没有 TOC 新文件；旧用户配置与升级路径不变。
- **验证**：`PERSISTENCE_ACCEPTANCE_SNAPSHOT_HARNESS PASS 14/14`；全量 Lua Parse PASS（210/210）；Foundation Audit PASS（`toc=210 activeLua=210 allLua=210 globals=0 presentation=0 rawNative=0 rawScope=0 detachedWidgetState=0 apiDependency=0 apiCapability=0 businessIds=0 auctionEventOwners=0 retiredUiLayer=0`）；Markdown 相对链接 58 条、0 断链。RU Fresh Reload/完整退出重进仍是 §9.2 唯一 NEXT，本轮不把本地指纹工具冒充实机回读通过。
- **BuildTag**：`v3-m1.16.0.18.84-persistence-fresh-reload-fingerprint`。

## 2026-09-04 — `.18.83` Persistence Runtime Acceptance Diagnostics

- **NEXT 对齐**：继续执行 CURRENT §9.2 的 RU Fresh Reload / Persistence Reliability v2 Runtime Acceptance，不抢跑下一业务 UI Gate。
- **单一 Reload/Flush Authority**：删除诊断页“重新加载文件”按钮的额外预 `Persistence:Flush()`；页面现在只调用 `ReloadCodeFromDisk()`，避免一次点击双写、双失败计数以及首个失败原因被吞。
- **可复制 Store 故障证据**：`Persistence:Flush()` 保存最近一次 runtime-only `lastFlush { at, ok, owner, failures }`，`Describe()` 暴露 `RuntimeAcceptanceDiagnosticsContractVersion=1`。该快照不持久化、不参与重试/写策略，Store dirty/fence 仍是唯一 Authority。
- **Foundation/Diagnostics**：Foundation Gate v81 新增 `persistence_runtime_acceptance_diagnostics`；一键摘要在 Flush/Fence 异常时直接附带最多 3 条 `store id:reason`，Recent Fault 也保留 `context.store/context.failures`；诊断页新增“最近存档落盘”行。
- **文档收口**：更新 `RU_RUNTIME_ACCEPTANCE.md` 的旧 `.18.60` BuildTag，新增 Buff Display/Healer/Gear/Activities/Tasks/DPS/Trade 的 Persistence Fresh Reload 矩阵，并删除对不存在的 `.workbuddy/tmp` harness 路径依赖。
- **验证**：changed-file Lua Parse PASS；全量 Lua Parse PASS（210/210）；Foundation Audit PASS（210/210，全部结构越界 0）；`PERSISTENCE_RUNTIME_ACCEPTANCE_HARNESS PASS` 验证失败 Flush 保留 exact store+reason、后续成功 Flush 覆盖失败 evidence；Markdown 相对链接检查 58 条、0 断链。
- **BuildTag**：`v3-m1.16.0.18.83-persistence-runtime-acceptance-diagnostics`。

## 2026-09-04 — `.18.82` Persistence 迁移收口 + §9.3 业务回归（本地）

- **Persistence 剩余 mutation→MarkDirty 收敛**（`.18.80` NEXT 的延续）：
  - `rs_feature_runtime.lua SetPreferredEnabled`：显式偏好写入改走 `MutateStore`（快照/回滚覆盖偏好表），Enable/Disable 生命周期副作用保留手动回滚；
  - `rs_life_m16_bundle Trade:SetFrom`：起点选择改走统一事务，删除手写 `RestoreTable` 回滚；`Fishing ArmAuto` 命令持久化失败时 fail-closed（自动回滚已装备的热键会话），删除遗留裸 `Save()` helper；
  - 删除死代码 `MarkAnalyticsStoreDirty`（唯一真实写入已走 `MutateAnalyticsStore`）。
- **§9.3 Bag 整理"点击没反应"根因修复**：整条链所有 `return false, err` 均为静默。修复：`BatchMove`/`StartBagQuick` 前置失败现在写入 `State.batch`/overlay 状态（stopped + 原因）并发布刷新；页面 `开始整理`/`取放` 失败直接写状态文本，未启用时提示"功能未启用"；`SafeHandler` 绑定失败不再静默——写 Diagnostics `UI_HANDLER_BIND_FAILED` + WarnOnce 提示（该控件点击将无响应）。互斥与 200ms 冷却逻辑未改动。
- **§9.3 Trade 回归**：金额列（预计售价/毛利/材料单价/小计）全部接入 `S.Utils.FormatMoney` 金银铜格式；`RefreshSellable` 增加会话级 per-zone 缓存（◀▶ 循环不再每次点击重发 `GetSellableZoneGroups`，`RefreshZones` 时失效）；新增 `Trade:QuoteMaterial(materialKey)` 显式接入 `PriceQuoteQueueV3`，页面新增"材料询价"按钮（按当前路线行的 `explicit_quote_required` 材料去重提交）；下拉因地区未读取被禁用时状态行给出原因提示。
- **§9.3 Auction 收藏/报价**：`AuctionProjection` 暴露 `PriceQuoteQueueV3` 快照（`quoteStatus/quotePrice/quoteError`），demand 0→1 时订阅 `v3.price_quote.completed` 实现询价完成自动刷新；页面新增"结果询价"按钮（选中带 `itemType` 的结果行启用）；删除收藏改为两击确认；选中结果行回填关键词输入框；状态行显示"最低价：…/未询价"。
- **RSUI Composite 收尾（Foundation v5）**：落地 ROADMAP 三个本地 Contract。①`RSUI:ResolveStatusSemantic` 成为 Pending/Success/Warning/Blocked 等 status→tone/默认文案的唯一语义 Authority（`StatusSemanticsContractVersion 1`）；②`StateNotice` 统一 Empty/Loading/Error/Blocked 组合态视觉（chip + message + 可选 hint，fail-closed validator 拒绝未知状态）；③`DetailHeader` 提供 Breadcrumb（`A › B`）+ 标题 + 可选 StatusChip 的标准详情头。design_system `EmptyState` 保持静态"尚未迁移"占位职责并注释防第二 Authority 分叉。Foundation Audit 的 Composite version Gate 同步升至 5。
- **验证**：`RSUI_COMPOSITE_STATE_HARNESS PASS 24/24`（真实加载 component_core→primitives→panels→data_views→controls→composite_foundation 全链，mock 原生 widget）；`LAYOUT_EDIT_SESSION_MODEL_HARNESS PASS 24/24`（真实加载 History/Session 模型：partial contract 拒绝、Reset/Revert 零持久化、Apply 唯一持久化边界、失败不推进 Baseline、History Undo/Redo 回放）；`PERSISTENCE_V2_MIGRATION_TEST PASS 20/20`（MutateStore 提交/拒绝回滚/durable 失败回滚/冷库 corrupt payload 拒绝并 fence/dirty reload 拒绝/rollback 失败 fence，全部针对真实 `rs_persistence.lua`）；`BUSINESS_BRIDGE_BAG_TRADE_TEST PASS 9/9`（批量前置失败可见化、Trade SetFrom 事务、Flush 失败保留 dirty 重试、QuoteMaterial 拒绝未验证身份）；Foundation Audit PASS（210/210，全部结构计数 0）。
- **BuildTag**：`v3-m1.16.0.18.82-local-continuation-mutation-tx`。

## 2026-09-04 — `.18.81` RU Hotfix + Persistence Reliability v2

- **状态显示页面崩溃根因**：RU 日志 `rs_v3_buff_display_page.lua:273 attempt to call method '?'` 精确对应 `RSUI:TreeView()`。`rs_ui_composite_foundation.lua` 原在 `rs_ui_data_views.lua / rs_ui_controls.lua` 之前加载，而 Composite 顶部要求 `RSUI.ListView` 已存在，否则静默 return；因此 `StatusChip/Picker/TreeView` 全部未注册。已调整 Active TOC 依赖顺序，并在 Foundation Audit 增加 prerequisite-order Gate；Buff Display 页面增加 SelectionModel/TreeView preflight，依赖异常改为明确 build error，不再 nil method。
- **Foundation Gate 修复**：`v3_advanced_ui_contract` 正确绑定 `S.UITokens`；`StatusClassificationV3.presentationBoundary = service_only`；UI Acceptance 删除早已退役的 `Persistence.ReadLegacy` 假契约，改为 Reliability v2 API。
- **Persistence v2 根因修复**：业务 Domain `budget` 与 Persistence 编码 `encodedBudget` 正式分离。`payload/__rsmeta` 的框架固定外壳拥有独立 bounded overhead，合法业务数据不会再因框架自己追加 metadata 触发 `encoded_payload_rejected → WriteFence → FlushFail`。注册期同时检查 default Domain + default envelope。
- **事务契约**：新增 `Persistence:MutateStore()`，统一 `PrepareWrite → snapshot → mutate → MarkDirty/Save → rollback`；mutation、commit 或 durable SaveData 失败均恢复 Domain 与 dirty metadata，只有 rollback 本身失败才 write-fence。Foundation `persistence_v2` 只看当前结构健康/fence，历史 reject 计数移入 incident warning。
- **业务迁移**：Buff Display、Healer、DPS、Combat Analytics、Raid Readiness、Tasks、Activities、Gear Quick HUD 关键命令、Death Review 关键 index、Life M16 通用 mutation、Business Bridge blacklist/craft context 已接入 v2 transaction；Buff Display full import 保留 bool/数字兼容并禁止事务内逐字段 publish。
- **验证**：`PERSISTENCE_RELIABILITY_V2_HARNESS PASS`；Foundation Audit PASS：`toc=210 activeLua=210 allLua=210 globals=0 presentation=0 rawNative=0 rawScope=0 detachedWidgetState=0 apiDependency=0 apiCapability=0 businessIds=0 auctionEventOwners=0`；210/210 Lua `texluac -p` PASS。RU Fresh Reload / 退出重进 SaveData 回读仍为下一硬验收。
- **BuildTag**：`v3-m1.16.0.18.81-ru-hotfix-persistence-reliability-v2`。

## M1.16.0.18.80 — Persistence Reliability v1 + Buff Display UI_IMPLEMENTING（2026-09-03）

- **用户 P0 反馈**：配置经常在重载/下一次进入游戏后丢失。审计确认至少两类底层危险链真实存在：Runtime Stop 过去可能在 Feature teardown 后才 Flush；Persistent Store 过去允许未 Load 就进入写意图。两者都会把 default/teardown 状态覆盖旧 SaveData。
- **Persistence Reliability Contract v1**：新增 `ReliabilityContractVersion=1`、`PrepareWrite()`、Load-before-Write fence、dirty reload fence、corrupt-nonempty protection、true debounce + max delay、SaveData failure dirty retention + bounded retry，以及对应 Diagnostics/Stats。普通 `SaveStore` 不再绕过 loaded/write fence；只有完整分片替换可显式 `allowUnloadedWrite=true`。
- **Runtime/Reload durability**：`Runtime:Stop()` 改为 `Flush → Feature Disable → Resource Quiescence`，且不会 teardown 后二次 Flush；用户主动 `ReloadCodeFromDisk()` 只有全部 dirty Store 安全保存后才触发原生 UI reload，否则明确取消。
- **Persistent Binding transaction**：设置控件在 Domain mutation 前 `PrepareWrite`，Store 冷态会先 Load+Apply；`MarkDirty` 失败时 best-effort 回滚 Domain value/revision，避免“页面看似成功、Reload 必回退”。
- **Direct-store call audit**：DPS boss list、Gear index/payload、DeathReview index/record 等立即保存路径补齐 load preflight；Gear Payload 与 DeathReview Record Slot 仅作为完整独立分片替换使用 `allowUnloadedWrite=true`。
- **Buff Display UI_IMPLEMENTING**：兼容四页签正式收敛为 `追踪管理 / HUD 布局 / 导入导出`；player+target 使用单一虚拟 Tracking Table；HUD 使用 `Element Tree + LayoutEditorWorkspace v2 + LayoutEditSession`。页面构造前读 Store，HUD Working Snapshot 与 Persistence getter 隔离；Preview/Undo/Redo/Reset/Revert 零持久化，只有 Apply 才 synchronous durable SaveStore。
- **Acceptance 修复**：最终 Foundation Audit 发现新增 BuffDisplay Acceptance 误用了未定义全局 `Fail()`；已改为标准 `return false, reason`，恢复 `globals=0`。
- **验证**：`PERSISTENCE_RELIABILITY_HARNESS PASS contract=1 unsafeReject=2 dirtyReload=1 retry=1 corrupt=1 autoLoads=1`；Foundation Audit PASS：`toc=210 activeLua=210 allLua=210 globals=0`；210/210 Lua `texluac -p` PASS。真实 SaveData 跨 Reload/重新登录仍需 RU Fresh Reload。
- **NEXT**：Persistence Reliability v2 / Mutation Transaction Audit，继续把剩余 public mutation 统一为 `PrepareWrite → mutate → MarkDirty/Save → rollback`；业务 UI 大规模迁移暂不抢占。
- **BuildTag**：`v3-m1.16.0.18.80-persistence-reliability-buff-display-ui-implementing`。

## M1.16.0.18.79 — Buff Display UI_APPROVED / Authority Cleanup（2026-09-03）

- **Gate**：用户确认“按照文档继续”，状态显示由 `UI_REVIEW → UI_APPROVED`。产品方向固定为 `追踪管理 / HUD 布局 / 导入导出` 三个任务；player/target 共用同一 HUD 几何模板；主手+副手在左、背部在右；远程 Fresh Default 为 OFF，启用时放左侧外层；Layout Reset 不清追踪。
- **装备布局 Authority**：`BuffHeadMarkersV3` 升 Contract 6，左侧顺序按“靠血条→外侧”为 `offHand → mainHand → ranged(optional)`，右侧只保留 `wings/back`；Acceptance 同步，不再与 Renderer 分叉。
- **默认值修复**：`COMPONENT_DEFAULTS.ranged.enabled=false`；`NormalizeComponent` 改为缺字段继承组件自己的 default，修复旧 `value.enabled ~= false` 会把所有缺失组件强制开启的问题。明确保存过的旧用户值继续保留。
- **字段 Authority 收口**：`headIconSize/headMaxIcons` 从 normalized live settings、页面控件、Projection/legacy accessor、导出策略中移除；旧 schema-4 存档和旧导入文本仍可兼容映射到 `components.buffs/debuffs.size/maxPerRow`。图标容量统一由 `maxPerRow × maxRows`（hard cap 64）决定。
- **Reset 语义**：新增 `ResetLayoutSettings`，只恢复 HUD components/head policy/plate/info 默认；tracked、classification、Tracking filters/rows、floating window 均保留。旧 `ResetAllSettings` 命令保留为同语义兼容 alias，禁止再执行破坏性清空。
- **导入导出兼容**：修复完整导入仍以 32/category 截断追踪 ID 的旧限制，统一为 Store 的 1024/category；完整导出/导入新增 Buff/Debuff `spacing/maxPerRow/maxRows` 与 CastBar `width/showText` round-trip，避免“导出后再导入”丢布局细节。
- **Store/Schema**：仍为 schema 4，无 schema bump；新增 `LayoutAuthorityContractVersion=1` 与默认设置 detached snapshot，供 Acceptance 和下一阶段 LayoutEditSession 使用。
- **验证**：Foundation Audit PASS：`toc=210 activeLua=210 allLua=210`，全部结构越界计数 0；BuffDisplay Acceptance 增加 40-ID import cap regression、component-specific export round-trip 与 fresh-default single-authority checks。
- **NEXT**：进入 `UI_IMPLEMENTING`，迁移三页签、单虚拟 Tracking Table，并把 HUD 布局接入 `Element Tree + LayoutEditorWorkspace v2 + LayoutEditSession`；本轮不抢跑大规模页面迁移。
- **BuildTag**：`v3-m1.16.0.18.79-buff-display-ui-approved-authority-cleanup`。

## UI REVIEW — Buff Display / 状态显示 v3（2026-09-03）

- **执行范围**：按 CURRENT §9.2 从 Foundation 进入第一个业务页面评审；只做真实代码审查 + 产品 UI_REVIEW，**不修改 Runtime / TOC / Store schema / 用户配置 / BuildTag**。Runtime 基线仍为 `.18.78`。
- **真实代码审查**：读取 Store schema 4、BuffDisplay Feature/Projection/Commands、当前四页签页面、BuffHeadMarkers Renderer、Aura/Metadata/Classification Services 与 `.18.75~.18.78` Layout Editor Foundation。
- **页面收敛**：当前 `状态追踪 / 头顶显示 / 布局外观 / 导入导出` 四页签评审为 `追踪管理 / HUD 布局 / 导入导出` 三个用户任务；头顶显示与布局外观合并，避免同一 HUD Template 的重复设置入口。
- **Tracking Review**：利用已有 `GetProjection("all") / GetTrackedList()`，设计为单一虚拟 Table + 来源筛选，不再在 1024×768 下并排“自己/目标”两张表；行点击仍是一键追踪/取消。
- **Layout Review**：指定 `Element Tree + LayoutEditorWorkspace v2`；player/target 共用一套 HUD 几何模板，只分别控制显示/Preview Scope；原生血条只作为不可见对齐基准，不虚构 Gameplay HealthBar Widget。
- **Persistence Review**：Tracking/Classification 仍可作为明确业务操作即时持久化；布局编辑必须 staged Working，Undo/Redo/Revert/Reset 不写 Store，只有 Apply 跨越 durable persistence boundary；Layout Reset 不得清 tracked/classification/window state。
- **运行时事实边界**：当前只批准 `player / target`；WatchTarget/Cooldown/Name 不因参考插件存在而进入当前 UI。目标装备图标因 RU scope API 证据不足继续 fail-closed，页面必须显示能力状态而非伪造可用。
- **发现的实现分叉**：Renderer 当前装备分组为左 `offHand/mainHand`、右 `wings/ranged`；Acceptance 却断言左 `ranged/offHand/mainHand`、右 `wings`；Store 注释“ranged 默认 OFF”与实际默认 `true` 冲突；Page 注释出现 schema 5 而真实 Store 仍为 schema 4；`headIconSize/headMaxIcons` 与 component 字段重复；现有 `ResetAllSettings` 作用域过大。
- **当前 Gate**：状态显示已从 `UI_DRAFT → UI_REVIEW`；下一步必须由用户确认 Review 中 4 个产品决策后进入 `UI_APPROVED`，再开始代码迁移。

## M1.16.0.18.78 — UI LayoutEditorWorkspace Integration（2026-09-03）

- **执行范围**：继续 Foundation First，零业务 Feature 页面迁移；完成 CURRENT §9.2 第 4/5 项，把 `.18.75~.18.77` 的 History / CommandBar / Session 正式接回共享 Workspace，并同步回写 Roadmap/Architecture。
- **RSUI v42 / API 12.6 / WorkspaceTemplates v4 / LayoutEditorWorkspace v2**：Workspace 创建唯一 bounded `LayoutEditHistoryModel` 并注入 PreviewAdapter；新增稳定 Command Host + `EditorCommandBar v2`，不再要求页面自己拼接 Undo/Redo/Reset/Revert/Apply。
- **Session Preflight**：`editSession=nil` 保留 history-only 兼容模式；一旦传入 Session 边界，必须同时提供 `getWorkingSnapshot / getPersistedSnapshot / getDefaultSnapshot / applyWorkingSnapshot / persistSnapshot`，partial contract 在构造 Native editor 前 fail-closed。
- **Authority Refresh Chain**：History `record/undo/redo` 只从 Adapter 刷新 Overlay/Inspector；Reset/Revert/Rebase 才从 Feature Working 显式 `RefreshFromSource`；caller 主动 Source Refresh 同步 `Session:RefreshWorking()`，不维护第二份 dirty/can* 状态。
- **Persistence Boundary**：Workspace 静态门禁禁止直接出现 `S.Persistence / SaveData / ClearData / SaveStore / MarkDirty`；durable Apply 仍只由 Feature callback 确认，Workspace 只负责绑定。
- **Lifecycle**：CommandBar/Session/History 全部事件订阅；root Release 先释放 UI 子组件，再解绑/释放 Session 与 History，避免关闭编辑器后残留监听或有界历史对象。
- **Compact UI**：CommandBar 默认 46px 紧凑按钮 + 84px 状态区，保持 1024 宽内容区可用；PreviewHost/Overlay/SAME TransformInspector 的 wide/drawer 单实例结构不变。
- **Gate / Acceptance / Sequence / Audit**：FoundationGate v78、UIV3Acceptance v53；新增 `LayoutEditorOverlayHistoryBindingContract v1`、`LayoutEditorWorkspaceContract v2`、`WorkspaceSessionBindingContract v1` 与 `v3_54_ui_layout_editor_workspace_integration_contract`；Audit 增加 no-sampling、no-direct-persistence、History injection、Session source refresh、lifecycle cleanup fence。
- **验证**：`LAYOUT_EDITOR_WORKSPACE_HARNESS PASS adapterRefresh=3 sourceRefresh=3 persist=1 historyOnly=true partialRejected=true`（非 Native 模拟，真实加载 History/Session/WorkspaceTemplates，覆盖 Record/Undo/Reset/Revert/外部刷新/Apply/Release）；210 个 Active Lua 额外使用 LuaTeX Lua 5.3 `texluac -p` 全量编译 PASS；Foundation Audit PASS（`toc=210 activeLua=210 allLua=210`，全部结构越界 0）；Sequence 的 pure Session preflight 已写入 Gate。Lua 5.3 编译仅为辅助语法证据，项目目标仍为 RU Lua 5.1；Workspace 实际按钮/输入/Z-order 仍以 RU Fresh Reload 为最终证据。
- **下一层**：CURRENT §9.2 进入**状态显示 UI_REVIEW**；先审 UI/交互/设置组织，再决定业务 Feature 重构，不跳过 UI_APPROVED Gate。
- **BuildTag**：`v3-m1.16.0.18.78-ui-layout-editor-workspace-integration`。

## M1.16.0.18.77 — UI Layout Edit Session / Reset-Revert-Apply Persistence Boundary（2026-09-03）

- **执行范围**：继续 Foundation First，零业务 Feature 页面迁移；完成 CURRENT §9.2 第 3 项 `Reset / Revert / Apply Session Semantics + Persistence Boundary`。
- **RSUI v41 / API 12.5 / LayoutEditSession Contract v1**：新增 `ui/framework/rs_ui_layout_edit_session.lua`，建立 `Persisted / SessionBaseline / Working / Defaults` 四态。SessionBaseline 是本次编辑起点/最近 Apply 基线，允许与 Persisted 不同。
- **命令语义**：`Revert` 只恢复 SessionBaseline；`Reset` 只把 Defaults staged 到 Working；二者都不调用 Store/ClearData。只有 `Apply` 调 caller `persistSnapshot`，且必须在 durable write 明确返回 true 后才推进 Persisted/Baseline。
- **Dirty 分离**：`dirty = Working != Persisted`；`sessionChanged = Working != SessionBaseline`。因此当前 Working 尚未持久化但本次 Session 未产生额外编辑时，Apply 可用而 Revert 仍禁用。
- **History Barrier / Integrity Fence**：Session 观察 History Record/Undo/Redo 事件刷新 Working；成功 Revert/Reset/Apply 清 History。Reset/Revert barrier 异常会 best-effort 回滚；durable Apply 后 barrier 异常不伪装回滚 Persistence，而进入 blocked，CommandBar v2 五命令 fail-closed。
- **Persistence Authority**：Session 文件静态门禁禁止直接出现 Runtime `S.Persistence / S.Api / SaveData / ClearData / SaveStore / MarkDirty` 调用；未来 Workspace/Feature Adapter 负责 durable callback。
- **Gate / Acceptance / Sequence**：FoundationGate v77、UIV3Acceptance v52；新增 `v3_ui_layout_edit_session_contract` 与 `v3_53_ui_layout_edit_session_contract`；EditorCommandBar Contract/Session Projection 升 v2 支持 blocked fence。
- **验证**：`LAYOUT_EDIT_SESSION_HARNESS PASS 2 30 1 2`；`LAYOUT_EDIT_SESSION_FOUR_STATE PASS 1 50`；`LAYOUT_EDIT_SESSION_FAILURE_HARNESS PASS 3 3 true`；Foundation Audit PASS（`toc=210 activeLua=210 allLua=210`，全部结构越界 0）。
- **下一层**：CURRENT §9.2 第 4 项 `LayoutEditorWorkspace Integration`，把 History/Session/CommandBar 接入同一 Workspace，不提前迁移业务 Feature。
- **BuildTag**：`v3-m1.16.0.18.77-ui-layout-edit-session-foundation`。

## M1.16.0.18.76 — UI Editor Command Bar Foundation（2026-09-03）

- **执行范围**：继续 Foundation First，零业务 Feature 页面迁移；完成 CURRENT §9.2 第 2 项 `Editor Command Bar`。
- **RSUI v40 / API 12.4 / Command Bar Contract v1**：新增 `ui/framework/rs_ui_editor_command_bar.lua`，固定 `Undo / Redo / Revert / Reset / Apply` 五命令入口。组件只做 Authority Projection，不拥有 Feature Store、Persistence 或 dirty/can* 第二份状态。
- **History Observable Extension v1**：`LayoutEditHistoryModel` 新增 `Subscribe/Unsubscribe`；成功 Record/Undo/Redo/Clear 才事件通知，Preview/Drag Pulse/Cancel 仍不产生 History/CommandBar 更新事件；无 Tick/OnUpdate。
- **Session Fail-Closed**：本轮刻意不定义 Reset/Revert/Apply 语义。Session Authority 未接入时三按钮全部 disabled；未来 Session 必须提供 `GetCommandSnapshot / ExecuteCommand / Subscribe / Unsubscribe`。
- **Busy Fence**：History 或 Session 任一 busy，五命令统一不可执行，避免 Undo 与 Apply/Reset 并发导致半事务。
- **Pure Projection**：新增 `ProjectEditorCommandState()`，允许 Gate/Sequence 不构造 Native Widget 就验证无 Session、Dirty Session 与 Busy 状态。
- **Gate / Acceptance / Audit**：FoundationGate v76、UIV3Acceptance v51；新增 `v3_ui_editor_command_bar_contract` 与 `v3_52_ui_editor_command_bar_contract`；Foundation Audit 增加 Active TOC、observable、no-sampling 与 session-command contract fence。
- **验证**：Foundation Audit PASS（`toc=209 activeLua=209 allLua=209`，全部结构越界 0）；当前容器无独立 Lua runtime，因此新 Sequence 已写入 Gate，最终运行结果继续以 RU/on-demand Gate 为准。
- **下一层**：CURRENT §9.2 第 3 项 `Reset / Revert / Apply Session Semantics + Persistence Boundary`，随后才接回 `LayoutEditorWorkspace`。
- **BuildTag**：`v3-m1.16.0.18.76-ui-editor-command-bar-foundation`。

## M1.16.0.18.75 — UI Layout Edit History / Undo-Redo Foundation（2026-09-03）

- **执行范围**：继续 Foundation First，零业务 Feature 页面迁移；完成 CURRENT §9.2 第 1 项共享 `LayoutEditHistoryModel / Undo-Redo`。
- **RSUI v39 / API 12.3 / History Contract v1**：新增 `ui/framework/rs_ui_layout_edit_history.lua`。History 只记录成功 Commit，Preview/Drag Pulse/Cancel 不入历史；before/after 以 stable key set 为身份边界，duplicate/missing/key-set drift 全部 fail-closed。
- **Bounded Session Memory**：默认 64 条命令、hard cap 256；每条 item 默认 128、hard cap 512；可选非 Rect state 使用 depth/node bound 深拷贝，避免 History 持有 live table 或无限增长。
- **Undo/Redo Transaction**：外部 `apply` 接受后才移动 cursor；异常/拒绝时 cursor 保持不变，并调用 rollback callback（未提供时复用 apply）恢复当前 side；rollback 失败单独计指标，不把半失败伪装成成功。
- **Anchor/Pivot 可逆性**：preserve-visual 锚点修改可能 before/after Rect 相同，因此 Adapter 只记录 `parentRect + rect + anchorX/Y + pivotX/Y` 的最小恢复快照；revision/lastSource 等瞬态字段不进入 History，避免伪 command。
- **PreviewAdapter 集成**：新增 `historyEnabled/historyModel`、`EnableHistory/GetHistoryModel/ApplyHistoryState`；Gesture Commit、Inspector Rect Commit、Single Anchor Commit 在外部 Commit 成功后才 Record；History replay 走受控 Commit 但不再次 Record。多选仍按 stable-key group projection 原子恢复。
- **Gate / Acceptance / Sequence**：FoundationGate v75、UIV3Acceptance v50；新增 `v3_ui_layout_edit_history_contract` 与 `v3_51_ui_layout_edit_history_contract`，Foundation Audit 增加 History Active TOC / bounded / rollback / no-sampling source fence。
- **验证**：`HISTORY_HARNESS PASS 1 1`；`ADAPTER_HISTORY_HARNESS PASS 2 1 10 0`；`MULTI_HISTORY_HARNESS PASS 1 10 210`；Foundation Audit PASS（`toc=208 activeLua=208 allLua=208`，全部结构越界 0）。
- **下一层**：CURRENT §9.2 第 2 项 `Editor Command Bar`，随后定义 `Reset / Revert / Apply` 的 Session/Persistence 语义并接回 `LayoutEditorWorkspace`。
- **BuildTag**：`v3-m1.16.0.18.75-ui-layout-edit-history-foundation`。

## Documentation Authority Consolidation — ToDo 单一入口（2026-09-03）

- 将 `CURRENT_REBUILD_STATUS.md` §9 明确为唯一活动 ToDo / 当前施工队列 Authority；Foundation、用户遗留事项、Product Matrix 后续入口与 RU Fresh Reload 验收统一在同一节管理。
- `PRODUCT_COMPLETION_MATRIX.md` 保留 125 项产品能力库存/完成度 Authority，但移除独立施工优先级，避免与 CURRENT 双 Authority；当前 Foundation Audit 证据同步为 `207/207`。
- `README.md` 新增 ToDo 权威导航和冲突优先级。
- `2026-09-03-pending-handoff.md` 的 #4–#7 已收拢进入 CURRENT §9；生成 `Archive/Handoff/WORKING_HANDOFF_20260903.md` 历史副本。旧 `Docs/Handoff/2026-09-03-pending-handoff.md` 路径应在覆盖后手动删除。
- 本轮仅文档治理，不修改 Runtime/TOC/Store/Schema/Feature 行为，不变更 BuildTag。

## M1.16.0.18.74 — UI Layout Editor Workspace Foundation（2026-09-03）

- **执行范围**：继续 Foundation First，零业务 Feature 页面迁移；把 `.18.71` 的独立 Transform 数学层组合成可复用 Editor Transaction / Overlay / Responsive Workspace。
- **RSUI v38 / API 12.2**：新增 `LayoutEditorPreviewAdapter v1` 与 `LayoutEditorOverlay v1`；`WorkspaceTemplates v3` 新增 `CreateLayoutEditorWorkspace()`。Canvas 统一为 `PreviewHost + EditorOverlay`，Feature Preview 不再负责 Handle/Guide。
- **Transaction v2**：`LayoutEditorGesture v2` 支持 Gesture Begin 动态尺寸约束、`onBegin/onAbort` 与 strict Preview/Commit rejection；`AnchorPivot v2` 增加完整 Snapshot Restore；`TransformInspector v2` 改为 `rectModel + optional anchorModel`，同一实例覆盖 single/multi。
- **Single/Multi Adapter**：Selection revision 是手势 fence；single 使用 AnchorPivot，multi 使用 MultiSelection ProjectionSession；Preview 只更新 working projection，Feature/Persistence Commit 拒绝会恢复 start items/anchor snapshot，不允许半事务。
- **Responsive Workspace**：Wide 右侧 inline Inspector；Compact 使用同一个 Inspector 作为 Drawer，只改变 Geometry/Visibility/Layer，不复制 Binding/Selection/Scroll，不使用未经验证 Native reparent。Toolbar 明示 `左上(0,0) · X→右 · Y→下`。
- **性能**：正常游戏态 0 editor sampling；candidate 只在 Gesture Begin 有界冻结，alignment 关闭时 candidate discovery=0；Pulse 只做 pointer/rect/snap math；Adapter/Multi projection O(selected) 且有 hard cap。
- **Gate / Acceptance / Sequence**：新增 PreviewAdapter / Overlay / Workspace Contract 门禁，并把 Gesture/Anchor/TransformInspector 最低契约提升到 v2；Sequence 新增 Adapter transaction/anchor rollback 与 composition contract。
- **下一层**：先补 `LayoutEditHistory / Undo-Redo + Editor Command Bar + Reset/Revert/Apply` 的共享可恢复编辑语义，再进入状态显示 `UI_REVIEW`。
- **BuildTag**：`v3-m1.16.0.18.74-ui-layout-editor-workspace-foundation`。


## M1.16.0.18.71 — UI Multi Selection Transform Foundation（2026-09-03）

- **执行范围**：继续 Foundation First，零业务 Feature 页面迁移；在 SelectionGeometry/Gesture 与 AnchorPivot 之间补齐 2+ selection 的 Group Bounds → per-child Rect 映射，解决完整 LayoutEditorOverlay 的最后一个核心数学/事务边界。
- **RSUI v35 / API 11.9 / MultiSelectionTransform Contract v1**：新增 `ui/framework/rs_ui_multi_selection_transform.lua`。模型只接受 2+ stable-key rect，默认 maxItems=256、hard cap=1024；single/duplicate/超上限全部 fail-closed，不静默截断 selection。
- **Authority 不重叠**：Group Bounds 的 move/resize/snap 仍由 `RectTransformTransaction + LayoutEditorGesture + GuideResolver` 负责；MultiSelectionTransform 不创建第二个 RectTransform，只把最终/snap-resolved Group Rect 投影回每个 Child。Feature/Store 仍只允许在外层 Commit 后持久化。
- **Projection Session**：`BeginProjectionSession → Project → Commit/Cancel`。Begin 冻结 start child rects/start bounds/base revision；Project 只生成 preview，不改 committed model；Commit 做 revision check 后一次性替换全部 child rect；Cancel 保持 committed model 完全不变。Session 活跃时 SetItems fail-closed，防止手势期间 selection 数据漂移。
- **比例 Resize**：按 Group `scaleX/scaleY` 映射每个 Child 的相对位置和尺寸；纯 Move 等价 scale=1。Session 根据所有 Child 的 minChildWidth/minChildHeight 反推出 `minGroupWidth/minGroupHeight`，未来 Gesture 从 Group 层限制 resize，而不是逐 child clamp 破坏比例。
- **Snap/Inspector 收紧**：`.18.70` SnapSettings 增加输入类型预检，非法值在 commit 前拒绝并保留旧 revision；TransformInspector 新增 TypeValidator，且自定义 SetEnabled 保留 Base Component enabled/alpha/revision 语义。
- **Gate / Acceptance / Audit**：FoundationGate v71、UIV3Acceptance v46；新增 `v3_ui_multi_selection_transform_contract` / `v3_48_ui_multi_selection_transform_contract`；Foundation Audit 门禁 `.18.69~.71` model/inspector/multi source 必须处于 Active TOC，并禁止纯 model 文件拥有 OnUpdate/InteractiveTask。
- **下一层**：允许开始 `LayoutEditorOverlay`，但只能作为 Coordinator：组合 SelectionOverlay/GuideOverlay/Gesture/Single-Multi Transform Adapter/Inspector，不得再造 Pointer Capture、Snap Resolver 或 Rect 数学。
- **BuildTag**：`v3-m1.16.0.18.71-ui-multi-selection-transform-foundation`。最终验证数字见本轮交付记录。

## M1.16.0.18.70 — UI Transform Inspector Foundation（2026-09-03）

- **执行范围**：继续 Foundation First，零业务 Feature 页面迁移；把 `.18.69` Anchor/Pivot + Snap Settings 模型接成可复用 Transform Inspector，但仍不组合完整 `LayoutEditorOverlay`，先避免把“单元素变换”误当成未来“多选整体变换”的最终 Authority。
- **RSUI v34 / API 11.8 / TransformInspector Contract v1**：新增 `ui/framework/rs_ui_transform_inspector.lua`，统一“变换 / 锚点与轴心 / 吸附与参考线”三段 Inspector；默认宽约 286px、两列字段、NumericField 精确输入，X/Y 标签明确 `左-/右+`、`上-/下+`，继续遵守 ArcheAge/CryEngine 左上原点坐标。
- **单一状态 Authority**：Inspector 不保存独立 Transform/Snap 副本；所有字段直接 Binding 到 `AnchorPivotModel` / `LayoutEditorSnapSettingsModel`。`onTransformChanged/onSnapChanged` 仅作为提交后的通知，不拥有 mutation Authority；通知异常只进 Diagnostics，不把已成功的模型提交伪装成半事务失败。
- **Preflight / Enabled 语义**：新增 `TransformInspector` TypeValidator，在创建 Native Root 前验证 Anchor/Snap Model 契约；自定义 `SetEnabled` 继续调用 Base Component `SetEnabled`，保持 Root enabledRevision、Native enabled 与 disabled alpha 一致，再递归驱动字段状态。
- **Snap Settings 输入完整性**：`SetPatch()` 在任何写入前验证布尔/数值字段类型；非法输入 fail-closed 并记录 `lastError`，不会把无效字符串悄悄 Clamp 成 1/0 等合法值。Snapshot 增加 `lastSource/lastError`，成功提交清除错误。
- **Gate / Acceptance / Sequence**：FoundationGate v70、UIV3Acceptance v45；新增 `v3_ui_transform_inspector_contract` / `v3_47_ui_transform_inspector_contract`，门禁 RSUI v34、TransformInspector v1 与 Anchor/Snap 共享模型依赖。
- **架构边界**：完整 `LayoutEditorOverlay` 仍刻意延后。下一层先定义 `MultiSelectionTransformModel`：单元素 Anchor/Pivot、Group Bounds、子元素相对变换、Commit/Rollback 必须先有明确 Authority，避免 Overlay 先落地后再返工多选语义。
- **BuildTag**：`v3-m1.16.0.18.70-ui-transform-inspector-foundation`。最终验证数字见本轮交付记录。

## M1.16.0.18.69 — UI Anchor / Pivot / Snap Settings Model Foundation（2026-09-03）

- **执行范围**：继续 Foundation First；新增纯 Lua editor state model，不创建 Native Widget、不注册 Tick、不修改业务 Store。
- **AnchorPivot Contract v1**：新增 `ui/framework/rs_ui_layout_editor_models.lua`。v1 只支持 9 个常用 Point Anchor + 自定义 normalized anchor `(0..1)` 与 Pivot `(0..1)`；明确暂不引入 UMG Stretch Min/Max Anchor，避免重新解释当前 top-left Rect 持久化。
- **视觉位置稳定**：切换 Anchor/Pivot 默认 preserve visual rect，只重新计算 anchor-relative `positionX/positionY`；Parent resize 则由 Caller 显式选择 `preserveVisual=true` 或 follow-anchor。公式统一为 `anchorAbs + position - size*pivot`，防止不同页面自己发明位置换算。
- **方向语义**：模型提供 `MoveUp/MoveDown/MoveLeft/MoveRight`；其中 `MoveUp(8)` 明确等价 `Y-8`，继续把 CryEngine `+Y=向下` 约束固化到语义 API。
- **Snap Settings Model v1**：统一 `enabled/gridEnabled/alignmentEnabled/canvasEnabled/showGuides/gridSize/threshold/maxCandidates`；`maxCandidates` hard cap=1024。`ToResolverOptions()` 是 GuideResolver 的唯一 Projection，不让页面散落吸附参数。
- **Gesture 性能收紧**：当对象对齐关闭时，Gesture Begin 不调用 `getSnapCandidates()`；只启用 Grid Snap 时 candidate discovery 次数为 0。GuideResolver 在 `enabled=false` 时直接返回 unchanged rect / scanned=0。
- **Gate / Acceptance / Sequence**：FoundationGate v69、UIV3Acceptance v44；新增 `v3_ui_layout_editor_model_contract` / `v3_46_ui_layout_editor_model_contract`，门禁 Anchor/Pivot、Snap Settings、方向语义与 grid-only bounded behavior。
- **BuildTag 过渡**：`.18.69` 为模型层里程碑；同轮继续收敛到 `.18.70` Transform Inspector 后统一交付。

## M1.16.0.18.68 — UI Layout Editor Gesture Transaction Foundation（2026-09-03）

- **执行范围**：继续 Foundation First，零业务 Feature 页面迁移；把 `.18.67` Selection/Guide Surface 接到项目已验证的 Native drag capture，而不是新建 generic pointer capture。
- **RSUI v32 / API 11.6 / Gesture Contract v1**：新增 `ui/framework/rs_ui_layout_editor_gesture.lua`。SelectionOverlay 的整框 `moveHit` 与 8 resize handle 统一走 `OnDragStart → StartMoving → gesture-only InteractiveTask/OnUpdate fallback → OnDragStop`；Controller 不拥有 Store/Persistence，只有 Caller `onCommit` 可以进入业务写入。
- **RectTransform Transaction v2**：增加 `OverridePreview()`；`PreviewDelta → GuideResolver → OverridePreview → Commit` 保证视觉 Snap 与最终提交坐标一致，并继续保持 left/top resize clamp 时 opposite edge 固定。
- **坐标空间 Fence**：Pointer 固定为 viewport-logical。只有 `coordinateSpace="viewport"` 可以 identity conversion；Canvas/Panel local editor 必须提供 `pointerToLocal`，否则创建 fail-closed。方向仍遵循 top-left：`+Y=下 / -Y=上`。
- **Bounded Gesture Performance**：Snap options/candidates 只在 Begin 调用一次并冻结，hard cap=1024；16ms pulse 只做 pointer delta + bounded pure math + 现有 overlay diff write；Scheduler 拒绝时才临时绑定 capture-surface `OnUpdate`，Commit/Cancel/Release 立即解除。Native Geometry Lease 防止 DiffRenderer 与 `StartMoving` 抢 capture surface。
- **Gate / Acceptance / Sequence**：FoundationGate v68、UIV3Acceptance v43；`v3_ui_layout_editor_gesture_contract` / `v3_45_ui_layout_editor_gesture_contract` 门禁 RSUI v32、Gesture v1、RectTransform v2、no-generic-capture；Foundation Audit 同步要求 gesture source 在 Active TOC、candidate freeze/lease/bounded contract 存在。
- **验证**：全量 `202/202 Lua Parse PASS`；Foundation Audit PASS（`toc=202 activeLua=202 allLua=202`，全部结构越界计数 0）；`RSUI_RECT_TRANSFORM_V2_HARNESS PASS upY=92 commit=92,87,88,73`；`RSUI_LAYOUT_EDITOR_GESTURE_HARNESS PASS x=100 y=95 candidates=1 preview=3 leases=1/1`；`RSUI_LAYOUT_EDITOR_FALLBACK_HARNESS PASS x=5 y=12 fallback=1`；`RSUI_LAYOUT_EDITOR_SAMPLING_FAIL_HARNESS PASS leases=0 begins=0`；`RSUI_SELECTION_OVERLAY_MOVE_HARNESS PASS moveIndex=3 handleIndex=4 upY=92`；`RSUI_SELECTION_GEOMETRY_BOUND_HARNESS PASS source=1100 bounded=1024 canvasBound=1024`。
- **BuildTag**：`v3-m1.16.0.18.68-ui-layout-editor-gesture-foundation`。

## M1.16.0.18.67 — UI Selection Geometry / Handle / Snap Foundation + Baseline Recovery（2026-09-03）

- **执行范围**：以用户重新上传的最新整包为唯一基线重新读 Docs/TOC/Foundation；继续零业务 Feature 迁移。
- **覆盖回流修复**：确认 `.18.63` 的历史 UI 文件组在多轮覆盖中局部回流：`UI.ComponentsV2`/旧 TOC、旧 Dropdown degraded behavior、旧 Popup/Z-layer 契约重新出现，而 `.18.64~.18.66` 新层仍存在。按真实调用链恢复 `ComponentsV2 retirement + ContainerSurface + Dropdown fail-closed + PopupCoordinator + UITokens v4`，不使用旧整包覆盖新工程。
- **更强防回流 Audit**：Foundation Audit 新增 Disk Lua ↔ Active TOC 双向门禁；任何磁盘 `.lua` 未列入 Active TOC 都直接 FAIL，使 retired source 不能以“暂时没加载”的方式残留等待未来复活。
- **RSUI v31 / API 11.5**：新增 `rs_ui_selection_geometry.lua`，`SelectionGeometryModel` 与 SelectionModel 分权；提供 multi-selection bounds、8-way handle geometry/hit test、`SelectionOverlay`、`LayoutGuideOverlay` 和有界 `LayoutGuideResolver`。
- **Snap/Guide**：支持 candidate/Grid/Canvas alignment；default candidate budget=256、hard cap=1024；最多 X/Y 各一条 guide；Resolver 不扫描 Widget Tree、不读取业务 metadata。
- **SelectionOverlay**：Root 使用 handleSize/hitSlop inset，确保 resize hit surface 不伸出物理 Parent；`.18.68` 增加整框 Move Hit Surface，创建顺序位于 resize handles 之前以保持边缘 Handle 命中优先。
- **Gate / Acceptance / Sequence**：FoundationGate v67、UIV3Acceptance v42；新增 `v3_ui_selection_geometry_contract` / `v3_44_ui_selection_geometry_contract`，静态 Audit 门禁 SelectionGeometry/GuideResolver/Overlay 与 1024 candidate hard cap。
- **验证**：Selection pure-math harness：`handles=8 alignX=200 grid=100,120 scan=1024`；SelectionOverlay mock：`root=113,83 xGuide=200 yGuide=150`；恢复后 Foundation Audit PASS，并作为 `.18.68` 202/202 全量回归基线继续验证。

## M1.16.0.18.66 — UI Coordinate / Pointer / RectTransform Foundation（2026-09-03）

- **执行范围**：继续 Foundation First，零业务 Feature 页面迁移；先把 ArcheAge/CryEngine 左上原点、Pointer delta 与 editor RectTransform 数学统一成共享 Authority，再进入 Selection/Handle/Snap。
- **RSUI v30 / API 11.4**：`S.Layout.CoordinateSystemContract v1` 明确 `(0,0)=左上`、`+X=右`、`+Y=下`，因此 `MoveUp(distance)` 语义等价于 `Y-distance`。新增 `OffsetPoint/MoveRect/GetCoordinateSystemSnapshot`，页面不得自行猜方向正负。
- **RectTransform Transaction v1**：纯数学 `Begin → PreviewDelta → Commit/Cancel`，支持 move + 8-way resize、min/max extent 与完整 rollback；delta 始终相对 Begin rect，避免逐帧累计漂移。它不捕获 Pointer、不直接写 Native Geometry，因此不会成为第二套 Windowing Authority。
- **Pointer Contract v1**：`RSUI.Pointer` 统一 `GetMouseLogicalPosition` 采样与 start→current delta；`captureSupported=false`，Native `StartMoving/StartSizing` 继续归 Windowing/已有控件。Tooltip 同样复用该 Pointer sampling path。
- **Overlay 审计**：确认 Application `ModalHost` 已拥有唯一 modal scrim。ResponsiveInspector drawer 默认保持非模态 Stable Host；当前不新增第二 Application Scrim Authority。
- **Gate / Acceptance / Sequence**：FoundationGate v66、UIV3Acceptance v41；新增 `v3_ui_geometry_pointer_contract` 与 `v3_43_ui_geometry_pointer_contract`，门禁 top-left coordinate、RectTransform transaction、Pointer v1 与 no-generic-capture policy；Foundation Audit 同步检查 source contract。
- **性能**：无 Tick/常驻 OnUpdate/业务扫描。坐标 helper 为 O(1)；RectTransform 只在显式 editor transaction 内做常数级数学；Pointer 只在事件/手势需要时采样。
- **兼容**：没有 Store Schema/Feature/页面迁移；只把过去隐含的 CryEngine 坐标方向变成显式共享契约。
- **验证**：全量 `200/200 Lua Parse PASS`；Foundation Audit PASS（全部结构越界计数 0）；Workspace/Container/Popup/Composite/Tree/Picker/Focus/Host-Slot/SearchablePicker/IconPicker 全部旧 Harness 回归 PASS；新增 `RSUI_GEOMETRY_POINTER_HARNESS PASS upY=92 resize=90,85,90,75`；Markdown 相对链接 `checked=52 bad=0`。
- **BuildTag**：`v3-m1.16.0.18.66-ui-geometry-pointer-foundation`。

## M1.16.0.18.65 — UI Host / Slot / Responsive Picker Foundation（2026-09-03）

- **执行范围**：继续 Foundation First，零业务 Feature 页面迁移；先审计 Host/Slot/Native Parent/Release 调用链，再补稳定响应式 Inspector 与 SearchablePicker Presentation。
- **RSUI v29 / API 11.3**：新增 `AttachmentContract v1`、`ReparentPolicyContract v1`，公开 `NativeReparentSupported=false`。Component 只有一个 logical parent；跨 Parent、self/ancestor cycle、Native creation parent mismatch 全部 fail-closed。`RemoveChild` 为 terminal release；Child 独立 Release 会先从 Parent `children/slots` 解除强引用。
- **Native Reparent Fence**：当前 RU 没有已验证通用 Reparent；`tools/rs_foundation_audit.py` 新增 Active Runtime 静态 fence，禁止未经证据的 `RemoveFromParent / Reparent / SetParent`。每次 attach 都核对 immutable Native Parent 与目标 `GetContentRoot()`，防止 logical/native Authority 分裂。
- **ResponsiveInspector v1 / WorkspaceTemplates v2**：Content + Inspector 在同一 Stable Host 下一次创建。wide 模式 inline 右栏；compact 模式右侧 drawer，只改 Geometry/Visibility/Raise，不重建、不复制 Binding/Selection/Scroll、不 reparent。新增 `CreateResponsiveInspectorWorkspace()`。
- **Composite Foundation v4 / SearchablePicker v1 / IconPicker v1**：SearchablePicker 复用 `.18.64` PickerModel，组合 TextInput + Search/Clear + StatusChip + virtual ListView；IconPicker 在同一 Model 上组合 virtual TileView + Image + selected preview。两者都只由 Enter/EditEnter 或显式按钮提交 Query，不绑定未验证 OnTextChanged/OnKeyDown/OnKeyUp，不注册 Tick；Icon bind 只消费 Caller 投影的 icon path，不调用业务 Metadata/Native 查询。
- **Gate / Acceptance / Sequence**：FoundationGate v65、UIV3Acceptance v40；新增 `v3_42_ui_host_slot_picker_contract`，门禁 RSUI v29、Attachment/Reparent、ResponsiveInspector/Workspace v2、SearchablePicker v1、IconPicker v1。Snapshot 增加 Attachment/Reparent/ResponsiveInspector/SearchablePicker contract 与相关 metrics。
- **性能**：无业务扫描、无常驻 OnUpdate。ResponsiveInspector 仅 layout/visibility 变化时工作；SearchablePicker/IconPicker 只有显式 Query/Selection 才更新，结果分别使用 ListView/TileView virtual pool；Icon tile bind 只写已投影纹理路径；Host/Slot 校验为有限祖先链（guard 64）+ O(1) Native-parent identity 比较。
- **验证**：`RSUI_HOST_SLOT_HARNESS PASS attachRejects=3 mode=drawer`；`RSUI_WORKSPACE_18_65_HARNESS PASS contract=2`；`RSUI_SEARCHABLE_PICKER_HARNESS PASS results=2 selected=fire`；`RSUI_ICON_PICKER_HARNESS PASS results=2 selected=fire binds=8`；最终全量 Gate/旧 Harness/Markdown 验证见本轮封包记录。BuildTag：`v3-m1.16.0.18.65-ui-host-slot-picker-foundation`。
- **RU 实机边界**：没有业务页面迁移，因此主要 Fresh Reload 风险集中于 Native Parent identity、compact drawer 的真实 Z-order/clip、TextInput Enter 事件与 Focus。未经验证 Native Reparent 仍明确禁止。

## M1.16.0.18.64 — UI Model Integrity Foundation：Transactional Tree / PickerModel / Focus Contract v2（2026-09-03）

- **执行范围**：继续 Foundation First，本轮仍不新增或重排业务 Feature。重点反向审计 `.18.63` Tree/Input/Focus 基础，先消除复杂编辑器未来最危险的稳定身份、半事务状态、默认展开语义和能力误报，再为 SearchablePicker/IconPicker 建共享数据模型。
- **RSUI v27 / API 11.1 / Composite Foundation v2**：`rs_ui_composite_foundation.lua` 升级，新增 `PickerModel v1`，TreeModel 内部升级 v2；`StatusChip v1 / TreeView v1 / PopupCoordinator v1` 保持单一现有 Authority。
- **Tree Stable Identity Contract v1**：节点必须提供 `key/id` 或 caller `getKey()`；彻底删除 path/index fallback。缺 Key → `tree_key_required:<path>`；`getKey/getChildren` 异常、children 非 table、duplicate key 全部显式 fail-closed，禁止排序/插入后 selection/expanded identity 漂移。
- **Tree Mutation Transaction Contract v2**：`SetNodes / SetExpanded / ToggleExpanded / ExpandAll / CollapseAll` 统一使用 staged candidate → build/validate → commit；失败完整保留旧 nodes/rows/maps/expansion/revision，只更新错误信息。专项验证覆盖“duplicate key 隐藏在折叠子树，展开后才暴露”场景，确认操作失败不产生半提交。
- **Tree expansion 三态与长期内存界限**：`true=显式展开 / false=显式折叠 / nil=defaultExpandedDepth`，修复默认展开节点被用户折叠后 Rebuild 又自动展开的问题。新增 `maxExpansionState`（默认 maxNodes×2、hard cap 32768）和 `treeExpansionStatePrunes`，动态树长期切换时旧 key 不无限积累。原 frame-cursor DFS / maxNodes bounded projection 保持。
- **PickerModel v1**：为 Buff/Skill/Item/Route/Icon 等大量选择场景建立 UI-agnostic shared model：稳定 key、transactional SetItems/SetQuery、显式 query、AND token plain match、caller `getSearchText`、stable selectedKey、duplicate/missing key fail-closed；`maxScan` 8192(default)/32768(hard)、`maxResults` 128(default)/512(hard)、token/query 长度均有界，并在 snapshot 暴露 truncation。SearchablePicker/IconPicker 后续只能消费该 Model，不得各造过滤/选择 Authority。
- **Focus Contract v2**：`CanSet / CanClear / GetTargetWidgetId / IsFocused` 改为 target-aware；`GetCapabilities(target)` 不再硬编码 `setFocus=true`，Set/Clear 只有目标 Native 真正支持方法时才宣告能力。逻辑 identity 不能冒充物理 focused widget id。
- **Input Event Fence**：由于 RU 当前仅验证 SetFocus/ClearFocus/GetFocusedWidgetId、Enter/EditEnter/LostFocus，Foundation Audit 新增 Active Runtime fence，禁止在证据不足时绑定 `OnKeyDown / OnKeyUp / OnTextChanged`。未来获得 RU/官方证据后必须升级 Input Contract 再移除 fence，而不是页面 Agent 自行猜事件名。
- **Gate / Acceptance / Sequence**：FoundationGate v64、UIV3Acceptance v39 要求 RSUI>=27、Composite v2、PickerModel v1、Tree Stable Identity v1、Tree Transaction v2、Tree Expansion Bound v1、Focus v2；新增 `v3_41_ui_model_integrity_contract` 覆盖 missing key、hidden duplicate rollback、default-expanded explicit collapse 与 Picker AND-token 投影。`tools/rs_foundation_audit.py` 同步增加 source contract 与回归 fence。
- **性能**：没有新增 Tick/OnUpdate/业务扫描。Tree projection 仍按 maxNodes 有界，frame-cursor traversal 临时内存按深度增长；长期 expansion override 有 cap。Picker 仅显式 SetItems/SetQuery 重建，scan/results/query/token 全有硬上限；Focus 为 O(1) capability/read 操作。
- **验证**：`RSUI_TREE_TRANSACTION_HARNESS PASS contract=2 stable=1`；`RSUI_TREE_DEFAULT_COLLAPSE_HARNESS PASS overrides=2 bounded=3`；`RSUI_PICKER_MODEL_HARNESS PASS contract=1 scan=10`；`RSUI_FOCUS_SERVICE_HARNESS PASS contract=2`；既有 Composite/Tree bounded/Popup/Container/Workspace harness 全部回归通过；全量 **200/200 Lua Parse PASS**；Foundation Audit PASS（`toc=200 activeLua=200 allLua=200 globals=0 presentation=0 rawNative=0 rawScope=0 detachedWidgetState=0 apiDependency=0 apiCapability=0 businessIds=0 auctionEventOwners=0`）；Markdown 相对链接 **0 断链**；Product Matrix 仍为 77/35/2/11，共 125。BuildTag：`v3-m1.16.0.18.64-ui-model-integrity-foundation`。
- **RU 实机边界**：本轮新 Model 尚未接入生产 Feature，所以无业务配置/页面迁移风险。通用 KeyDown/TextChanged 仍明确视为未验证；SearchablePicker 首版必须使用已证实 Edit/Enter/LostFocus 能力或显式提交模式。

## M1.16.0.18.63 — UI Composite Foundation：TreeView / StatusChip + ComponentsV2 退休 + Dropdown Fail-Closed（2026-09-03）

- **执行范围**：继续 Foundation First，本轮不新增、不重排任何业务 Feature 页面；目标是检查 RSUI 底层真实调用链，优先删除第二套 Presentation surface、补跨 Feature 高复用 Composite，并同步完善统一能力/UI 路线图。
- **RSUI v26 / API 11.0**：新增 `ui/framework/rs_ui_composite_foundation.lua`。`StatusChip v1` 统一 neutral/info/pending/success/warning/error/blocked/unavailable 状态语义；Feature 只提供 semantic status，不再各页自造红黄绿协议。
- **TreeModel / TreeView v1**：TreeModel 为 UI-agnostic 纯层级 projection，使用稳定 `key/id`、独立展开态、迭代式 bounded flatten（默认 4096 / hard cap 16384）、duplicate-key fail-fast；宽树审计进一步改为 frame-cursor DFS，不再 push-all-children，临时内存按遍历深度有界。TreeView 复用现有 `ListView` virtual pool、SelectionModel 与 stable key，只为可见行创建/绑定 indent + chevron + label，不注册 Tick/OnUpdate。
- **Dropdown degraded fail-closed**：Popup 构建失败时保留当前值并显示 `⚠`，Native control 禁用，`Open/ToggleOpen/Scroll/click` 均不改变值；删除旧“弹层失败后单按钮循环切换选项”的隐式交互变形。正常 Popup 路径不变。
- **PopupCoordinator v1 / UITokens v4**：Dropdown、ColorField、ContextMenu 统一到一个 weak registry；Open 前 `CloseAll(except)`，ColorField Disable/Release 自动关闭并 unregister，ContextMenu 统一 system layer / popup priority。`DropdownService` 仅为同一 coordinator 的兼容 alias。`UITokens.layer.popupPriority=10000` 成为唯一 Popup Z priority token，静态 Audit 禁止当前 popup surface 重新写 magic literal。
- **Input/Focus 结论**：当前 RU 证据支持 SetFocus/ClearFocus/GetFocusedWidgetId 与 Enter/EditEnter/LostFocus，但未验证 generic OnKeyDown/OnKeyUp 或实时 OnTextChanged；因此 SearchablePicker/IconPicker 暂不伪造桌面键盘交互，后续先做 evidence-safe 的显式搜索提交。
- **`UI.ComponentsV2` 退休**：调用链确认剩余真实 Consumer 仅为 RSUI 自身 Card/Section/FormSection。Card 改由 RSUI 直接创建，Section/FormSection 收敛到 `RSUI.ContainerSurface:CreateSection()`；同时保留旧 Native root 的 `_card` / `_section` identity 规则，避免清理底层顺带改变物理控件身份。`ui/framework/rs_ui_components_v2.lua` 从 Active TOC 与物理工程删除，`rs_ui_framework.lua` 同步删除 ComponentsV2 metrics/snapshot 钩子。历史文档保留旧接口作为演进证据，但明确标记 SUPERSEDED。
- **防回流 Gate**：`FoundationGate v63`、`UIV3Acceptance v38` 增加 Composite Foundation / StatusChip / TreeView / Dropdown fail-closed Contract；`tools/rs_foundation_audit.py` 新增 retired UI layer 静态 fence，禁止 `UI.ComponentsV2` / `Create*V2` component helper 或旧文件重新进入 Active Runtime，并要求 composite source 在 TOC。
- **Sequence / Harness**：新增 `v3_40_ui_composite_foundation_pure_contract`，覆盖 TreeModel 初始折叠、展开/折叠、duplicate key、bounded/truncated projection；开发 harness `RSUI_COMPOSITE_MODEL_HARNESS PASS rows=2 treeRebuilds=4`；`RSUI_TREE_BOUNDED_MEMORY_HARNESS PASS rows=64 siblings=20000 peakFrames=2 exactTruncated=true`；`RSUI_POPUP_COORDINATOR_HARNESS PASS closed=b`；`RSUI_CONTAINER_SURFACE_HARNESS PASS created=7` 验证 Section/Card 物理 ID 兼容、标题更新与 extent/layout 路径。
- **文档同步**：`CURRENT_ARCHITECTURE`、`CURRENT_REBUILD_STATUS`、`RSUI_ARCHITECTURE`、`CORE_ARCHITECTURE` 与 `REBUILD_REFERENCE_ADDON_CAPABILITY_ROADMAP` 同步更新；路线图将 TreeView/StatusChip 标记为 Foundation v1 已实现，并明确下一批先审计 Input/Focus/Popup 生命周期，再考虑 SearchablePicker/IconPicker、ResponsiveInspector/Drawer、LayoutEditorOverlay。
- **验证**：全量 **200** 个 Lua `texluac -p` PASS；Foundation Audit PASS（`toc=200 activeLua=200 allLua=200 globals=0 presentation=0 rawNative=0 rawScope=0 detachedWidgetState=0 apiDependency=0 apiCapability=0 businessIds=0 auctionEventOwners=0`）；Markdown 相对链接 **0 断链**。BuildTag：`v3-m1.16.0.18.63-ui-composite-foundation`。
- **RU 实机边界**：TreeView/StatusChip 尚未接入生产 Feature，业务行为风险低；但 Card/Section/FormSection 的 Native root 创建路径已收敛，Fresh Reload 应遍历现有页面确认几何/标题/Form section 无视觉回归。另需在开发环境故障注入 Dropdown Popup 创建失败，确认只读 `⚠` 路径不误改配置。

## M1.16.0.18.62 — UI Workspace Foundation：页面级组合模板 + 详细页面设计路线图（2026-09-03）

- **执行策略**：正式切换为 Foundation First。现有 RSUI Primitive/Panel/DataView/Form/Windowing 保留为唯一 UI Authority，不推倒重来；先补跨页面重复的 Workspace Composition，再逐页把 UI 从 `UI_DRAFT` 讨论到 `UI_APPROVED`，最后进入业务页面重排。
- **RSUI v25**：新增 `ui/framework/rs_ui_workspace_templates.lua`，只组合已有 `VerticalBox / HorizontalBox / UniformGrid / SplitView`，不读业务数据、不持久化 Feature 状态、不注册 Tick/OnUpdate。
- **四个首批 Workspace Template**：`CreateMasterDetailWorkspace`（主从/列表详情）、`CreateInspectorWorkbench`（左 Navigator + 中 Preview + 右 Inspector）、`CreateSettingsWorkbench`（分类设置工作台）、`CreateCommandCenterWorkspace`（Status Strip + Overview/Exception Queue + Evidence）。
- **统一页面策略**：`UITokens v3` 新增 Breakpoint（720/980/1180）与 Workspace Rail/Inspector/Preview 几何 token；新增 `WorkspaceTemplates.BreakpointPolicy` 与 `DensityPolicy`，页面不再各自发明 compact/wide 决策。
- **Foundation Gate**：`v3_advanced_ui_contract` 升级为 RSUI v25 + WorkspaceTemplates v1 必须存在，四个公共构建入口缺失即 blocker。
- **设计文档**：`REBUILD_REFERENCE_ADDON_CAPABILITY_ROADMAP.md` 扩充为能力 + 页面 UI 单一讨论总表；Gear、Buff Display、Unit Lines、Range Assist、Healer/Raid、Boss、DPS/Analytics/Death Review、Activities/Tasks、Bonds、Trade/Craft、Treasure/Fishing、Title/Profile、Diagnostics 均补充组件树、栏宽/行高、对齐、compact 降级和 Foundation 依赖。明确下一批候选 `TreeView/OutlineView / SearchablePicker / IconPicker / ResponsiveInspector/Drawer / StatusChip / LayoutEditorOverlay`，缺组件时优先下沉 Foundation，禁止页面临时复制。
- **验证**：全量 **200** 个 Lua `texluac -p` PASS；`RSUI_WORKSPACE_TEMPLATE_MOCK PASS`（四模板构造 + Breakpoint Policy）；Foundation Audit PASS（`toc=200 activeLua=200 allLua=200 globals=0 presentation=0 rawNative=0 rawScope=0 detachedWidgetState=0 apiDependency=0 apiCapability=0 businessIds=0 auctionEventOwners=0`）；Docs Markdown 相对链接 0 断链。BuildTag：`v3-m1.16.0.18.62-ui-workspace-foundation`。
- **RU 实机边界**：本轮没有把四个模板强行替换进现有生产页面，因此不改变 Gear/Healer/DPS 等业务行为；后续实际页面采用模板后仍需要 1024×768 / 1080p 拖动、缩放、Scroll、Split divider 与视觉密度 Fresh Reload 目测。

## M1.16.0.18.61 — Runtime Recovery：换装事务 / 单位连线布局 / 范围颜色 / 居民板识别（2026-09-03）

- **换装**：`GearV3` 升 v3。移除“bagId 0/1 视图不一致即整单取消”的错误安全门，按 RU 已验证 gearswap 行为固定以 `bagId=1` 作为物理槽候选 Authority，`X2Bag:Capacity()` 只决定有界扫描上限（150 fallback / 240 hard cap）。战斗中不再整单拒绝：只构建 16/17/18/19 武器优先队列并逐件重读验证；防具/饰品/称号显式延后，脱战再次执行补齐。
- **单位连线**：四个关系开关与公共参数改为 2 列 UniformGrid；四类每线外观改为独立卡片（标题 / 点数+大小 / ColorField），不再把标签、两个 NumericSetting 和颜色压进 28px 单行。
- **范围辅助**：`color` 正式加入 Permanent default/state contract，修复 SetColor 只改内存、Reload 后丢失；`ColorField` 触发器始终显示“标签 + #RRGGBB”，即便 RU Native 未提供 `CreateColorDrawable` 也能发现并操作颜色。`RangeAssist.VisualGuideContractVersion=3`，`UIV3Acceptance v37` 门禁 SetColor。
- **债券 / 居民板**：Board 1..7 每类只读取一次；归一化 `contents/content/rows/items` 与稀疏数字索引；位置识别恢复 RU 已验证规则（3+4 非空=大陆，5/6 非空=原大陆），只投影真实非空内容；`unavailable` 与“当前位置无内容”明确分离，并把 scope/faction/error 暴露给页面诊断。
- **验证**：`GEAR_SERVICE_V3_HARNESS PASS`（bagId1/bagId0 内容冲突不再误阻断；战斗仅切武器并留下 pending；脱战补齐防具）；全量 199 个 Active Lua `texluac -p` 通过；Foundation Audit PASS（`toc=199 activeLua=199 allLua=199 globals=0 presentation=0 rawNative=0 rawScope=0 detachedWidgetState=0 apiDependency=0 apiCapability=0 businessIds=0 auctionEventOwners=0`）；`BONDS_BOARD_SHAPE_HARNESS PASS`；`VISUAL_CONFIG_CONTRACT PASS`；Markdown 相对链接 0 断链。BuildTag：`v3-m1.16.0.18.61-runtime-recovery`。

> **⚠️ 架构变更声明（2026-09-01/02）**：旧版（Legacy/Professional）源码已全部物理删除（163 文件、−10.3 万行，commit 09010c0）。本文件是历史变更日志，早期条目（M1.16.0.18.x 及之前）可能引用已删文件（`rp_*`/`rh_*`/`rg_*`/`rdps_*`/`modules/professional/`/`S.State`/`S.Storage`/`rs_state`/`rs_storage`/`rs_module_manager`/`rs_module_sandbox`/`ReplicatedSuiteModuleSandbox`/`ReplicatedHealerModule`/`ReplicatedPlatesModule`/`ReplicatedDps` 等）。这些引用仅作历史记录，不代表当前代码。当前架构以 [`CURRENT_ARCHITECTURE.md`](CURRENT_ARCHITECTURE.md) 为准。

## M1.16.0.18.60 — 治疗辅助 团队名单识别 / 色块覆盖 / 校准 / 设置 重构：RaidTeam≠RaidPanel≠Calibration 解耦（2026-09-03）

- **背景（先查架构后动手）**：原实现把团队身份（`teamIndex`）与屏幕 `sections[4]` 四个固定区域强绑定——即"列表 A 永远等于团队 1"的反模式，且 50 个槽位用固定坐标写死，切换团队必须重新校准。这违背「谁拥有这个事实」原则：`RaidTeam`（数据身份）≠ `RaidPanel`（屏幕列表容器）≠ `Calibration`（面板几何）。
- **架构解耦（核心）**：引入 `panels{A,B}` 矩形模型。每个 Panel 拥有自己的 `{x,y,width,height}` 整面板包围盒，槽位由几何**派生**（非 50 个固定坐标）；`team` 绑定挂在 Panel 上、可运行时切换而**不触碰几何**。身份权威仍复用 `TeamRosterV3`（成员 `teamIndex` 0/1/2、`memberIndex` 1..50、`isSelf`）。overlay 按 `member.teamIndex` 映射到绑定该团队的 Panel；`team==0 && isOnly` 时归 Panel A（玩家自身）。
- **三模式**：`auto`（由 TeamRosterV3 实际在场团队派生）、`single`（Panel A 显示 singleTeamId 指定团队、唯一面板、切换不重校准）、`dual`（Panel A/B 显示任意团队组合）；`GetEffectivePanelBindings()` 解析出有序绑定列表 `{id,team,geometry,isOnly}`。
- **文件改动**：
  - `features/combat/healer/rs_healer_store.lua`：SCHEMA 3→4；弃用 `sections[4]`/`calibrationSection`/`calibrationScope`，改为 `panels{A,B}` + `mode`/`singleTeamId`/`testColors`/`slotNumbers`/`showMyself`；新增 `DefaultRaidPanel(s)`/`MigrateSectionsToPanels`/`NormalizeRaidPanel` 及 `SetRaidPanelRect/SetRaidPanelTeam/SetRaidMode/SetRaidSingleTeam/SetRaidTestSetting/ResetRaidLayout`。
  - `features/combat/healer/rs_healer_feature.lua`：`GetEffectivePanelBindings()`（auto/single/dual 解析）、`LocateSelf()`、`Commands` 面板门面。
  - `features/combat/healer/rs_healer_recommendation_v3.lua`：`GetRaidDisplayProjection` 行身份改为 `teamIndex`/`isSelf`/`memberIndex`（对齐 Healer.Roster 投影）。
  - `presentation/v3/widgets/rs_v3_healer_raid_overlay.lua`：全量重写——2 面板×50 槽位对象池、矩形 `LayoutPanel` 派生网格、按 team 绑定映射、`v3.healer.updated`/`v3.healer.locate_self` 事件驱动（非逐帧全扫）、测试色模式、`locate_self` 闪烁。
  - `presentation/v3/pages/rs_v3_healer_page.lua`：新增「团队/面板」组（模式下拉、单团队选择、A/B 团队绑定、测试色/槽位号开关、定位自身按钮），`ApplyRaidTeamVisibility` 按模式显隐对应控件。
  - `core/rs_foundation_gate.lua` + `features/combat/healer/rs_healer_aura_acceptance.lua`：契约由 `SetRaidSectionRect`→`SetRaidPanelRect`、SCHEMA 3→4、`visual_store_contract` 校验 `raid.panels.A/B`。
- **配置迁移**：旧 `sections[4]` 在 `NormalizePresentation` 中由 `MigrateSectionsToPanels` 折叠为 `panels{A,B}` 两个整面板包围盒，用户校准布局以矩形整体保留（非丢失）；全新存档走默认 `panels` 矩形。向后兼容、无人工迁移步骤。
- **验证（本轮回测实测数字）**：面板绑定 harness `.workbuddy/tmp/healer_raid_panel_harness.lua` **55/55 PASS**（默认面板模型 / 旧 sections→panels 迁移 / Set* 命令 / 钳制与非法输入守卫 / Commands 门面委派 / GetEffectivePanelBindings auto·single·dual 11 个子例）；全量 Lua 5.1 `luac -p` 语法门禁 8 文件全 PASS；Foundation Audit **PASS**（`toc=199 activeLua=199 allLua=199 globals=0 presentation=0 rawNative=0 rawScope=0 detachedWidgetState=0 apiDependency=0 apiCapability=0 businessIds=0 auctionEventOwners=0`）。
- **未验证项（RU 实机）**：覆盖色块实绘与坐标投影精确度、事件驱动 100 人刷新手感、双列布局目测、`locate_self` 闪烁、`testColors`/`slotNumbers` 实际呈现——需 Fresh Reload 目测；矩形校准几何已静态确认（派生网格、非 50 固定坐标）。
- BuildTag：`v3-m1.16.0.18.60-healer-raid-panel-model`。

## M1.16.0.18.59 — 截断文字悬浮提示跟随光标（issue #2，2026-09-02）

- **背景（先查架构后动手）**：用户反馈②文字显示不全时悬浮提示窗口不在鼠标位置出现。按「每个功能前先查底层架构是否支持」原则核查 `RSUI.Tooltip`（`ui/framework/rs_ui_interactions.lua`，v3）：其 `Show` 优先走原生 `SetTooltip(text, widget)`（由客户端导出、把提示锚定到所绑定的 widget 单元格、而非光标），命中即 `return`，而**真正读取 `PointerPosition()` 做光标跟随的逻辑只存在于 pooled fallback 分支**（lines 177–194 的 `AnchorRect`+`SetAnchor`）。所以"提示不出现在鼠标位置"的根因是：截断类提示走了原生 `SetTooltip`，被钉在单元格而非跟随光标。底层架构其实已具备光标跟随能力，只是对 hover/overflow 类提示未启用。
- **修复（`rs_ui_interactions.lua`）**：
  1. `Show` 在选路前先采样 `local mouseX, mouseY = PointerPosition()`；当 `options.cursorFollow == true` 时，跳过原生 `SetTooltip` 分支，直接进入带光标跟随的 fallback（与下方 fallback 分支一致读取 `PointerPosition` 并在 `mouseX~=nil` 时 `px,py = mouseX+gap, mouseY+gap` 并在越界时翻转）。默认（非 cursorFollow）行为不变，仍优先原生。
  2. `BindOverflowText`（截断文字路径）在落 binding 时显式 `binding.cursorFollow = true`，使所有 `GetOverflowTooltipText` 类提示强制走光标跟随 fallback，不再钉在单元格。
- **架构接口核对**：`PointerPosition()` 经 `S.Api:GetMouseLogicalPosition()` 取坐标；已核对真实 `rs_api.lua` 契约——该函数返回 `(x, y, nil)`（坐标取前两个返回值），与 fallback 分支的 `tonumber(x)` 用法对齐；`SetTooltip` 为原生全局导出，在 RU 客户端常态可用，故此前路径恒定命中原生、提示恒钉单元格，与用户观察一致。`RSUI:IsComponent(value)`（`rs_ui_component_core.lua:1155`）检查 `type(value.GetRoot)=="function" and value.kind~=nil`，已据此校正 harness fixture（原 stub 用 `__isComp` 且按位置取参，触发 colon-call 陷阱）。
- **验证（录制式 harness 实测）**：`tooltip_cursor_follow_harness.lua` 加载真实 `rs_ui_interactions.lua` + 桩 `S.UI/S.RSUI/S.Api`，三用例全 PASS：`TOOLTIP_CURSOR_FOLLOW_HARNESS_PASS cursorFollowSkipNative=true overflowBindsCursorFollow=true`——A) `cursorFollow=true` 跳过原生 `SetTooltip`、fallback 在光标 (110,110) 打开；B) 默认路径仍走原生（返回 `"native"`）；C) `BindOverflowText` 强制 `cursorFollow=true`，进入提示时跳过原生、在光标 (110,110) 打开 fallback。Foundation Audit 全 PASS（`toc=199 activeLua=199 allLua=199 globals=0 presentation=0 rawNative=0 rawScope=0 detachedWidgetState=0 apiDependency=0 apiCapability=0 businessIds=0 auctionEventOwners=0`）。BuildTag：`v3-m1.16.0.18.59-tooltip-cursor-follow-overflow`。
- **未验证项（RU 实机）**：fallback 提示在真实客户端下弹层位置/层级/鼠标坐标采样是否稳定、OnEnter 一次性采样 vs 拖动跟随手感——需 Fresh Reload 目测（fallback 仅 OnEnter 采样一次，不做 OnUpdate 跟随，符合原生 tooltip 行为）；`SetTooltip` 原生路径在无鼠标坐标的设备上仍作为兜底保留。

## M1.16.0.18.58 — ColorField 基础组件 + 单位连线/范围辅助线条颜色（issue #1+#3，2026-09-02）

- **背景（先查架构后动手）**：用户反馈①单位连线面板设置太杂乱（不像高端 UI 布局）、③范围辅助与单位连线都缺线条颜色设置。按「每个功能前先查底层架构是否支持」原则核查：RSUI 声明式组件库中没有颜色选择器，因此第一步是完善底层基础组件 `RSUI:ColorField`，再以新组件去落地两层线条颜色，而非在页面层硬塞一堆原生滑块。
- **新基础组件 `RSUI:ColorField`（`ui/framework/rs_ui_controls.lua`）**：点击色块（实时颜色预览）+ 弹层内 R/G/B 三个 Slider + hex 文本输入（提交走 `onSubmit`）。get/set 携带 `{r,g,b}`（0..1），复用 `RSUI:Binding` 的提交链，弹层用 `UIParent` 物理层 + `system` 层级避免被 ScrollBox/卡片裁剪。`c:ApplyColor` 经 `:Render()` 把通道 Slider 视图从 `c.color` 重新同步（不二次提交），hex 输入经 `ParseHex` 解析。
- **单位连线去杂乱（`presentation/v3/pages/rs_v3_business_pages.lua`）**：四种关系（target/targettarget/focus/focustarget）原来每行内联 3 个 `CompactNumericSetting` R/G/B 滑块（用户指的"杂乱"）→ 各替换为单个 `ColorField`；swatch 默认色取 presenter `UNIT_COLORS` 同款调色板（`UNIT_LINE_PALETTE`），未持久化前即与渲染线条一致。set → `feature.Commands:SetPairColor(pairKey, r, g, b)`。
- **范围辅助补颜色控件**：范围辅助原**完全没有**线条颜色控件 → 新增 `ColorField` 写入 `feature.Commands:SetColor`。配套在 `features/rs_business_bridge.lua` 补 `SetColor` Command（clamp 0..1，经 `PersistStateMutation` 持久化）并暴露 `color` 投影；presenter `presentation/v3/widgets/rs_v3_combat_visual_guides.lua` 的 `RenderRange` 读 `projection.color` 落点给 `PlaceDot`（缺省回退原 `(0.20, 0.82, 1.00)`）。
- **录制式 harness 验收发现并修复 1 个真实生产 Bug**：`business_page_color_harness.lua` 加载真实 `rs_ui_controls.lua` 构建真实 ColorField，模拟拖动 R 通道 → 触发 `rs_ui_controls.lua:908 attempt to call a nil value (global 'Clamp01')`。根因：内部每通道 Slider 的 `set` 闭包引用 `Clamp01`，而 `Clamp01` 在 Lua 中声明为 Slider 循环**之后**的 `local function`——Lua 闭包不会捕获晚声明的局部，该名被解析为全局，用户拖动任一颜色通道即崩溃。修复：将 `Clamp01` 声明上移到 Slider 循环之前（同作用域、循环前可见）。经小样本 Lua 复现确认该前向局部引用语义确为全局绑定（非本机工具链之误），即真实 RU 客户端同样会崩。
- **验证（本轮回测实测数字）**：录制 harness `BUSINESS_PAGE_COLOR_HARNESS_PASS unit=4 range=1 oldSlidersRemoved=true refreshOk=true`（4 个 per-pair ColorField 的 set 确调用 `SetPairColor`、1 个 range ColorField 的 set 确调用 `SetColor`、旧 3×R/G/B 滑块确认移除、两页 `Refresh()` 不崩）；Foundation Audit 全 PASS（`toc=199 activeLua=199 allLua=199 globals=0 presentation=0 rawNative=0 rawScope=0 detachedWidgetState=0 apiDependency=0 apiCapability=0 businessIds=0 auctionEventOwners=0`）。`rawNative=0 rawScope=0` 证明新组件零原生泄漏。BuildTag：`v3-m1.16.0.18.58-colorfield-foundation-unitlines-range-color`。
- **未验证项（RU 实机）**：ColorField 弹层在真实客户端的位置/层级/鼠标跟随、拖拽手感、hex 输入交互、范围辅助落点颜色实绘——需 Fresh Reload 目测；`Clamp01` 修复为纯作用域移动、已静态确认。

## M1.16.0.18.57 — V3 页面布局优化（gear/healer 迁 RSUI 模版）+ 底层预存在全局泄漏修复（2026-09-02）

- **背景**：用户要求用新增的底层 UI 框架/模版优化布局。本轮落地两块页面级迁移（WU1/WU2），并在验证门禁（Foundation Audit）中发现并修复两个预存在的全局泄漏（属未动过的旧文件，与布局改动无关，但阻塞门禁变绿）。
- **WU1 `rs_v3_gear_page.lua`（4 个像素钉死原生控件 → RSUI 声明式组件）**：`createEdit`/`createButton`/`nameEdit`/`saveName` 由手写 `Border`+`Text`+像素 `x/width` 钉位改为 `RSUI:TextInput`/`RSUI:Button`，统一进 `RSUI:HorizontalBox`（slot 宽度 54/55 为 RSUI 槽宽，非像素钉死）。新增 `SetNativeText`/`GetNativeText` helper 在 `widget:SetValue`/`widget:GetDraftValue` 之间路由（组件 API 优先、原生 `S.UI:SetText` 兜底）；`SafeNativeClick` 改为在 `widget.root` 上绑 `OnClick`。旧像素钉（x=4/137/138、width 130/129）经 grep 确认仅残留在注释中，源码已无。
- **WU2 `rs_v3_healer_page.lua`（4 个手写标题分组框 → RSUI:GroupBox）**：`settings_panel`/`visual_panel`/`advanced_panel`/`calibration_panel` 由 `variant="card"` 的 `RSUI:Border` + 独立标题 `Text` 改为 `RSUI:GroupBox`（title 移入 spec、原标题 `Text` 物理删除、内容 `VerticalBox` 作为首个 child 成为 content）。`visual_panel` 初始 `visible=false` 保留（tab 默认落在策略页）；`advancedHeader` + `advancedCloseButton` 保留并正确 parented（关闭按钮 onClick 链路不动）；现有 `SetVisibility` tab/显隐接线完整保留。判定用 GroupBox 而非 CollapsibleGroup——4 个均为 tab/按钮显隐的带标题框，无"点标题折叠"需求。
- **WU3 `rs_v3_business_pages.lua`（表视图状态覆盖）**：逐行盘点结论——本文件**不存在手写 label→value 展示行**，原 WU3 设想"把 `fill=1` 行换成 `RSUI:KeyValueRow`"对这份文件不成立：其 `fill=1` 槽位绝大多数是 `D:CompactNumericSetting` 滑块（控件）、动态状态 `RSUI:Text`（`SetText`+`SetLabelTone` 手搓的复合状态行）、`RSUI:TextInput`/`Dropdown`/`Toggle`（输入控件），数据展示走 `TableView`。真正的缺口是 **`tableView` 从不调用 `SetViewState`**（全文件 0 次），而所有兄弟 V3 表格页（activity/buff_display/death_review/task/life_economy…）都驱动空态/加载/不可用遮罩。在 `root:Refresh()` 末尾按既有的 `enabled`/`#rows` 信号补 `tableView:SetViewState`：`enabled~=true → "unavailable"`（带标题"功能已关闭"）、`#rows==0 → "empty"`（标题"暂无数据"）、否则 `"ready"`。桩 harness `business_pages_wu3_test.lua` **10/10 PASS**（disabled→unavailable / enabled+0rows→empty / enabled+rows→ready / boss_alerts 同路径 / unavailable 带 title，基线先 FAIL 证明缺口后 PASS）。`hint` 复合状态行保留不动（非 KV 对，StatusRow 不适用）。
- **验证门禁（Foundation Audit 前置修复）**：重跑审计 FAIL（`globals=2 presentation=1`）。根因均为预存在且非本轮引入：
  - `presentation/v3/widgets/rs_v3_buff_head_markers.lua:334` `function ComputePlateLayout(...)` 是非 local 全局函数定义（line 434 才 `P.ComputePlateLayout = ComputePlateLayout` 暴露）；改为 `local function`，table 赋值照常生效，全局泄漏消除。
  - `features/combat/buff_display/rs_buff_display_acceptance.lua:227` `if rows[1].name ~= "A"` 在第二个 `RegisterSequenceCase` 闭包里引用 `rows`，但该 `rows` 定义在第一个闭包（line 74）的 local 作用域——跨闭包孤儿引用，运行时 `rows[1]` 直接抛 "attempt to index a nil value"（plate_geometry 验收用例会崩溃）。改为在第二个闭包内自包含重投影（buff 条目 101 "A"），消除崩溃并保留 name 透传断言。
  - 重跑审计 **PASS**：`toc=199 activeLua=199 allLua=199 globals=0 presentation=0 rawNative=0 rawScope=0 detachedWidgetState=0 apiDependency=0 apiCapability=0 businessIds=0 auctionEventOwners=0`。
- **验证（本轮回测实测数字）**：WU1 桩 harness `.workbuddy/tmp/gear_page_wu1_test.lua` **20/20 PASS**（4 控件为 RSUI TextInput/Button、maxLength 32/36、OnClick 绑 `.root`、LoadDraft 经 SetValue 非原生、CreateSet/RenameOnly/Save 经 GetDraftValue+SetValue）；WU2 桩 harness `.workbuddy/tmp/healer_page_wu2_test.lua` **28/28 PASS**（4 面板为 GroupBox 且 title 正确、content child 已挂、visualPanel visible=false 保留、4 标题 Text 删除、advancedHeader/closeButton parented 完好、SetVisibility tab 接线驱动分组）；`luac -p` 布局+门禁 4 文件语法全 PASS；Foundation Audit 全 PASS（见上）。`rawNative=0 rawScope=0` 证明布局改动零原生泄漏、零新增 presentation 逃逸。
- **未验证项（RU 实机）**：GroupBox 原生 Border+标题条构建、`gear` TextInput/Button 交互行为、tab 切换显隐动画——需 Fresh Reload 目测；ComputePlateLayout 为纯几何函数无 native 副作用、已静态确认（audit 的 presentation-escape 仅因全局定义，改 local 后零残留）。

## M1.16.0.18.56 — tools_social 社交名单完善：保守归一化 + 诚实状态聚合 + IsFriend 点查（2026-09-02）

- **背景**：`tools_social`（社交名单，registry `migrated_m16_18`、能力门 8 API 全 OfficialEnabled、`RU_RUNTIME_ACCEPTANCE.md` Social 验收路线）此前 read 仅 11 行——`pairs` 直读名单表、无形态守卫、无行数上限、失败与空名单不可区分（三读全败仍报 `empty`，违反 §30 Unknown vs Empty / UI-STATE-001），且 `SetOnClick` 式猜形态渲染会把 table 地址当名字显示。本轮按「Better, not copied」在 V3 框架内补齐（参考工程仅作功能灵感；X2Friend 调用形态以 `api_functions.lua` Allowed functions 为签名权威）。
- **读侧重构（`rs_business_bridge.lua`）**：
  - 保守多形态归一化 `NormalizeSocialList`：数组-表（`name`/`characterName`/`memberName`/`charName`）、数组-名字串、名字键表三形态皆收；`count` 等标量哈希字段按元数据跳过；纯键表回退按 key 排序保证确定性；数组段优先（ipairs 语义）。
  - 无可用名字的条目渲染为显式「未识别条目」行（memberName=nil、muted），绝不伪造名字，并把状态降级 `partial`（RU 契约待实证的诚实信号）。
  - 每名单有界 `SOCIAL_LIST_MAX_ROWS=200` + 截断显式注记（`SOCIAL_LIST_SCAN_LIMIT=1000` 扫描护栏），超大名单不再冲爆投影。
  - 诚实状态聚合：单名单失败逐一名单进 error；三读全败 → `unavailable`（0 行不再伪装 empty），部分失败或存在未识别 → `partial`，全 ok 空 → `empty`，否则 `ready`。
  - 行身份字段：`memberName`/`listKind` + 保守可选事实（`online`/`isOnline`/`loggedIn` 布尔、`level`/`growLevel` 数值；未知显示「在线状态未知」，不猜）。
  - **native arity 纪律**：`GetFriendList(allMember=true)`（清单签名带布尔）显式传参；`GetBlockList()/GetMuteList()` 零参——旧代码路径存在给零参方法传 nil 改变 native arity 的隐患，已按清单签名修正。
- **新增 `IsFriend` 命令**：消费已登记但零使用的 `X2Friend:IsMyFriend(charName)` 点查；返回三态文案「是好友/非好友/好友状态未知（返回形态待 RU 实证）」，能力门拒绝/冷却原样透传。
- **页面（`rs_v3_business_pages.lua`）**：tools_social 列表行可选（行点击载入名字进操作框，未识别行惰性跳过，`SetValue` 签名与拍卖收藏行先例一致）；新增「查好友」按钮（info 命令只报事实、不 Refresh 不脏 Authority）；`socialInput/socialStatus` 提升作用域；提示文案更新（写操作遵守官方 1 秒冷却）。
- **验收**：`rs_v3_acceptance.lua` `social_action_contract` 增加对 `Commands.IsFriend` 的存在性要求。
- **验证**：新 harness `social_feature_harness.lua` **31/31 PASS**（加载**真实** bridge、脚本化 S.Api 驱动真实 read/commands 路径：三形态归一化/元数据跳过/确定性 key/未识别 partial/全败 unavailable/部分败 partial/空名单/200 截断/零参 arity 断言/写 false 透传/空名拒绝不入门/IsFriend 三态+门失败）；回归 RSUI **68/68**、price_quote **14/14 + 8/8**；`luac -p` 三改动文件通过；Foundation Audit **PASS**（`toc=199 activeLua=199 allLua=199 globals=0 presentation=0 rawNative=0 rawScope=0 detachedWidgetState=0 apiDependency=0 apiCapability=0 businessIds=0 auctionEventOwners=0`，toc 双向 0 差异）。
- **未验证项（RU 实机）**：X2Friend 名单真实返回字段（名字/在线/等级字段名）待 Fresh Reload 实证——归一化已把未知字段降级为「未知」展示，实证后仅需补字段名白名单；四写命令 native `false` 的细分语义（名字不存在 vs 已在名单）未区分，按「returned false」原样透传；行点击载入的 TextInput 行为沿用拍卖收藏先例，未单独实机构建。

## M1.16.0.18.55 — 底层框架可观测性审计：metrics 三件套补齐 + 游离开发目录清理（2026-09-02）

- **背景**：按维护技能流程对底层框架（`ui/framework/` 全部 25 文件 + core）做同型脆弱点扫描——逗号优先级陷阱多值赋值全库复查（**无残留**：现存 `local x, y = tonumber(x) or 0, tonumber(y) or 0` 均为每值独立完整表达式，仅 .53/.54 修过的 CollapsibleGroup/HeaderBodyFooter 属真实陷阱）；`toc.g` ↔ 磁盘双向 0 差异核验（**发现并清理** addon 树内游离 `.workbuddy/tmp/`）。扫描暴露 RSUI 全局 metrics 记账的 **init/snapshot/reset 三件套登记缺口**，本轮补齐。
- **metrics 三件套缺口（真实可观测性债务）**：机械对账（非目测）发现 4 个字段**有写入 + 有 init 默认但 GetSnapshot 从未读出**（诊断不可见）：`duplicateTypeRegistrations` / `externalLayoutInvalidations` / `typographyInvalidations` / `fontScaleApplications`；14 个字段 **ResetMetrics 未归零**（"重置后观察增量"工作流失真）：buildScope 全家（`buildScopesStarted/Committed/RolledBack`、`buildScopeComponentsReleased/WidgetsHidden/CleanupFailures/CloseOrderRecoveries`）、`buildTransactions/buildTransactionFailures`、`preflightFailures`、`strictBuildFailFast`、以及上述 `duplicateTypeRegistrations/externalLayoutInvalidations/fontScaleApplications`。`byType` 经子索引循环展开属正常豁免。均纯登记补齐，零行为变更。
- **清理**：删除 addon 树内遗留游离开发目录 `replicatedsuite/.workbuddy/tmp/`（19 个文件：9 个 09-01 历史 bugfix .zip + 10 个旧验证脚本；非 git 跟踪、不属于 toc 加载、违反红线 §12.4「测试/调试脚本一律放项目根 `.workbuddy/tmp/`，绝不放插件树内」）。删除后 toc 对账死文件归零。
- **验证**：`luac -p` 通过；Foundation Audit **PASS**（`toc=199 activeLua=199 allLua=208 globals=0 presentation=0 rawNative=0 rawScope=0 detachedWidgetState=0 apiDependency=0 apiCapability=0 businessIds=0 auctionEventOwners=0`）；RSUI layout templates harness **68/68 PASS**；toc 双向 0 差异。
- **未验证项**：无行为变更，无 RU 客户端新增依赖；诊断页展示新字段属下游展示，无需单独实机验证。

## M1.16.0.18.54 — RSUI 高级布局模版：外部独立审查（P2/P3）收口（2026-09-02）

- **背景**：.53 交付后交由另一 AI 做独立复审，结论「有条件通过」：2 个 bug 修复正确、其余 3 类无 bug、harness/audit 实跑通过；但提出 **3 项 P2 条件 + 5 项 P3 建议**。本轮全部落实（`LayoutTemplates.version` 2 → 3，行为契约有变）。
- **P2-1 SplitToolbar 窄窗 spacer 重叠零报告**：`SplitToolbarPolicy:Resolve` 命中 `spacerMinWidth` 钳制分支时 spacer 矩形会真实伸入右组（fail-closed 设计意图），但此前无任何记账。改为**返回第二值 `clamped`**（单返回值调用方不受影响，向后兼容），`Layout` 在 `clamped` 时计入 `RSUI.metrics.splitToolbarSpacerClamped`，注释明示「重叠可见是退化信号」。
- **P2-2 `SafeHandler` 返回值未检查**：`CollapsibleGroup` headerHit 绑定改为 `local bound = UI:SafeHandler(...)`，绑定失败（widget 不可用 / SetHandler 被拒 / 返回 false）计入 `RSUI.metrics.collapsibleHeaderBindFailed`。绑定丢失在运行时完全不可见（标题条照常渲染、只是点了没反应），不能假定成功。
- **P2-3 Steps 的 `state` 枚举无消费方**：文件头注释宣称「视觉层只需渲染三种色调」，但 `Layout` 只用 `step.width/x`。确立**可选消费契约**：子项暴露 `SetStepState(state, index)` 即由 `Layout` 调用（`"done"/"active"/"pending"`），按 `rsUiStepState` 做 **diff**（状态未变不重入，重复布局零开销；标记先于调用，抛错消费方不会被反复重试）；无该方法的子项是纯几何容器、零耦合不被触碰。注释同步改写。
- **P3 低风险项一并收口**：
  - `HeaderBodyFooter:Measure` 消除首批遗留的同型坑形（`local hw, hh = header and Measure(...) or 0, 0` + 纠正行），改 CollapsibleGroup 同款显式双值，三区高度一次算准（旧写法功能正确但依赖纠正行，脆弱）。
  - `SetExpanded` 内 `local next` 遮蔽全局 `next()` 迭代器 → 改名 `nextState`。
  - headerHit 按钮 `titleFontSize` 回退由 `font.small/10` 对齐为 `font.section/13`（与 title Label 同字段一致；按钮文本为空，零行为影响）。
  - 审查文档行号漂移（Steps 751 → 764 等）与 §2.3 措辞已修正。
- **metrics 登记补齐**：`rs_ui_component_core.lua` 新增 `collapsibleHeaderUnavailable`（此前被引用但漏登记）/ `collapsibleHeaderBindFailed` / `splitToolbarSpacerClamped` 三字段的**初始化、快照、ResetMetrics** 三处登记，沿用全库 `(tonumber(...) or 0) + 1` 记账惯例。
- **harness 50 → 68 断言，并修复一处会令断言空转的 mock 缺陷（重要）**：所有 `Create*/Set*` mock 此前是**点号声明但被冒号调用**，`self` 落进 `parent`，参数整体错位一位——widget id 取成了父对象，且所有 `SetExtent`/`SetAnchor` 写都落到 `UI` 表而非 widget 上。即 harness 看着全绿，实际**从未验证任何原生写入**。全部签名补显式 `self` 后（并对非 table 入参返回 false 以暴露错位），新增断言：headerHit 的真实 id/几何 `createArgs`、SafeHandler 标签、主题背景清零调用、绑定失败计数、无 Button 表面 fail-open 计数、Steps 状态交付/diff/变更重投、窄窗 clamp 计数、HeaderBodyFooter 三区高度求和、重展开后 `viewportVisible==true` 与 Measure 回到 106。
- **验证**：harness **68/68 PASS**；`luac -p` 三个文件语法通过；Foundation Audit **PASS**（`toc=199 activeLua=199 allLua=208 globals=0 presentation=0 rawNative=0 rawScope=0 detachedWidgetState=0 apiDependency=0 apiCapability=0 businessIds=0 auctionEventOwners=0`）。
- **未验证项**：`SetStepState` 契约尚无首个业务消费方（首个接入者需自带断言）；Button 覆盖层 z-order 与 0-alpha 背景仍需 RU 实机目测；harness 组件核仍是简化重实现，非 dofile 真实组件核。

## M1.16.0.18.53 — RSUI 高级布局模版（第二批：DetailRow / Steps / CollapsibleGroup / SplitToolbar）审查修复收口（2026-09-02）

- **背景**：第二批 4 类模版（CollapsibleGroup/DetailRow/Steps/SplitToolbar，随 Request J 已落盘 `rs_ui_layout_templates.lua` v2、toc.g 已注册）此前处于「未审查、含真实 bug、CHANGELOG/审查文档/memory 仍停留在第一批 .52」的半成品状态。本轮按审查文档 §8 候选清单完成逐行审查 + 修复 + harness 扩展 + 文档收口。
- **审查结论（其余 3 类）**：`DetailRow`（label 区 + 等宽右对齐 value 列，窄窗先让 label 收缩）几何一致；`Steps`（末格吸收余数，3×94+2×8 余量收敛到 96，末格到行尾零尾缝）正确，Measure 第 751 行 `math.max(0, N(spec.width,0)) or 0` 的 `or 0` 冗余无害；`SplitToolbar` 复用 `ToolbarPolicy:Partition` 三区，左右组距相消正确（`iw-leftUsed-rightUsed`），spacer 失败收敛到 `spacerMinWidth` 为 fail-closed 设计。无同类 bug。
- **修复 bug 1（CollapsibleGroup:Measure 展开高度恒缺内容）**：`local dw, dh = self.expanded and Measure(...) or 0, 0` 是 Lua 逗号优先级陷阱——`or` 优先级高于 `,`，实际解析为 `dw = (expanded and Measure(...) or 0); dh = 0`，**dh 恒为 0**，展开态测量永远不含内容高度（折叠/展开在同一父容器内切换时容器高度不会随内容伸缩）。改为显式 `if expanded and content ~= nil ... then dw, dh = Measure(...) end` 双值赋值。
- **修复 bug 2（headerHit 折叠点击在 RU 静默失效）**：旧实现用 `UI:CreateEmptyWidget(..., pickable=true)` + `SetOnClick/OnClick`，但全代码库该二方法零使用、EmptyWidget 面在 RU 客户端收不到 OnClick（权威注释见 `rs_ui_data_views.lua`），真实客户端折叠点击永远不触发。改为框架标准点击绑定：`UI:CreateButton`（空文本、置于 title/chevron Label 之下，Label 不抢点击）+ `UI:SafeHandler(headerHit, "OnClick", ..., "<id>:collapsible_header")`（generation/崩溃保护 + 随 owner 释放）；按钮主题背景经 `S.Theme:SetBackgroundOpacity(headerHit, 0)` 清零（pcall + 存在性守卫，视觉与 GroupBox 头部一致，chevron 承担可点暗示）。CreateButton 失败走 fail-open 降级（记录 `RSUI.metrics.collapsibleHeaderUnavailable`，组件照常渲染、`SetExpanded` API 仍可用）。
- **验证**：harness 扩展至 **50/50 PASS**（`.workbuddy/tmp/rsui_layout_templates_harness.lua`，不入包）——新增断言覆盖：展开态 Measure 含内容高度（10+28+8+50+10=106）、spec 固定宽保持、headerHit 为 native Button 表面、SafeHandler 绑定存在、header 点击→折叠（Measure 收缩到仅 header+padding=48、content viewport 隐藏）、再次点击→展开，配合 SafeHandler spy + `FireWidgetClick` 走真实绑定路径；`luac -p` 语法通过；Foundation Audit 全 PASS（`toc=199 activeLua=199 allLua=208 globals=0 presentation=0 rawNative=0 rawScope=0 ...`，toc 双向 0 差异）。mock UI 的 `SafeHandler` spy 修正为冒号调用兼容（补收隐式 self）。
- **未验证项**：Button 覆盖层 + 0-alpha 背景需 RU 实机构建目测（z-order：Button 在底、Label 在上不抢点击；点击热区高度 `headerHeight` 整条）；`CreateButton` 以 border Panel 为父的成功率依赖 Factory `CreateChild(type="button")`，与 data_views 行按钮同一路径（实机先行模式）。

## M1.16.0.18.52 — RSUI 高级布局模版（FormRow / KeyValueRow / Toolbar / HeaderBodyFooter / GroupBox）（2026-09-02）

- **背景**：RSUI 底层已有齐全的 UMG-like 基础积木（HorizontalBox/VerticalBox/Grid/UniformGrid/WrapBox/ScrollBox/SplitView/ScaleBox/SafeZone 等），但缺一层「组合式、跨分辨率稳定」的高级布局模版——每个 Feature 页面仍在手写 label/control 行、工具栏左/右分栏、页头/页体/页脚三区堆叠、带标题分组框等重复模式。
- **新增 `ui/framework/rs_ui_layout_templates.lua`（5 类注册类型 + 4 个纯策略函数）**：
  - `FormRow`：label | control | (hint) 单行；label 有 `labelShare` 占比，窄行先压 label 到 `labelMinWidth`、再压 control、最后丢 hint，绝不产生负宽。纯策略 `RSUI.FormRowPolicy:Resolve(...)`。
  - `KeyValueRow`：label ...... value（value 右对齐、受 `valueMaxShare` 上限）；纯策略 `RSUI.KeyValueRowPolicy:Resolve(...)`。
  - `Toolbar`：`slot.group = "left" | "right" | "spacer"` 三区；left 靠左、right 靠右、spacer 填中间；每项 auto 宽（不再被 fill 撑满整条）；纯策略 `RSUI.ToolbarPolicy:Partition(...)`。
  - `HeaderBodyFooter`：页头(auto)/页体(fill)/页脚(auto) 三区堆叠；纯策略 `RSUI.HeaderBodyFooterPolicy:Resolve(...)`。
  - `GroupBox`：带标题分组框（Border 面 + 标题条 + content + 可选 footer），由 Border 组合而成、继承完整 Measure/Arrange 路径。
- **设计约定**：全部由现有 primitives 组合，不建第二套布局 Authority；纯策略函数与类型并存（`SplitViewPolicy` 先例），tiny-window/序列测试可零 Native 副作用地跑纯数学；事件/布局驱动，无 Tick/OnUpdate/轮询；Measure 不写 Native 布局，Layout 只走既有 Diff/Anchor 权威。
- **修复 harness 暴露的 Toolbar 布局 bug**：初版 Toolbar 对每项 `Align(start, iw, dw, slot.hAlign)`，默认 `hAlign="fill"` 导致每个按钮被撑满整条工具栏宽度（left 项 width=400）。改为每项按自身测得宽度 auto 布局（`Align(start, dw, dw, "left")`）。
- **注册**：`toc.g` 在 `ui/framework/rs_ui_adaptive_panels.lua` 之后新增 `ui/framework/rs_ui_layout_templates.lua`（依赖 `RSUI.LayoutUtil` 与面板类型，需在其后加载）。
- **验证**：`luac -p` 语法通过（用内置 `luabin/luac.exe`）；Foundation Audit（`toc=199 activeLua=199 allLua=208 globals=0 presentation=0 rawNative=0 rawScope=0 ...`，toc 双向 0 差异；Audit 的 Lua parse FAIL 仅因审计工具未找到 texluac/luac 到 PATH，非代码问题）；自定义 harness `rsui_layout_templates_harness.lua` 20/20 PASS（`.workbuddy/tmp/`，不入包）——4 个纯策略 + 5 类模版的 measure/arrange/responsive/no-overlap/right-align/fill-remainder/Measure-purity 断言。
- **未验证项**：5 类模版尚未在 RU 客户端实机构建（Factory 注册与 Lua 静态覆盖无法替代真实构建序列）；`GroupBox` 的标题条 Drawable accentStrip 视觉需 RU 实测；纯策略函数依赖 `RSUI.LayoutUtil` 已加载（`rs_ui_panels.lua` 先行）。

## M1.16.0.18.51 — 共享限速报价队列 PriceQuoteQueueV3（共享前置 #1 落地）（2026-09-02）

- **背景**：REBUILD_ROADMAP 共享前置 #1——Trade/CraftAssist/AuctionFavorites 三个域都需要显式 `X2Auction:GetLowestPrice` 报价，但该 API 是 `Cooldown=500ms` 的 server_query，普通 Refresh 绝不能 fan-out。此前三域均已移除自动 fan-out（M1.16.0.18.39），但缺一个统一、限速、显式触发的报价服务。
- **新增 `services/rs_price_quote_queue_v3.lua`（`S.Services.PriceQuoteQueueV3`）**：
  - `RequestQuote(requester, itemType, itemGrade, callback)`：显式+异步报价入口。入队后由单一 Scheduler 串行 lane（`intervalMs=560ms ≥ 官方 500ms 冷却`）逐个 drain，一次只发一个原生调用，规避冷却冲突。
  - 异步回调：每请求完成通过内部事件总线 topic `v3.price_quote.completed` 广播 + 可选 `callback(snapshot)` 回传；requester 级快照（`GetSnapshot`）供投影只读回读，不重复发服务器请求。
  - fail-closed：能力门拒绝/返回不可读一律产出 `status`（`failed`/`unavailable`/`capability_unavailable`），绝不在 `GetLowestPrice` 返回形态未验证时伪造价格；`NormalizeQuote` 保守接受 number/string/若干常见字段，未验证字段不作为成交样本。
  - 上限 `maxQueue=64`、去重由 requester 快照覆盖、空队列自动停 lane（`_StopLane`）。
- **收敛直接调用**：`features/rs_business_bridge.lua` 中两处报价调用收敛到共享服务——`auctionCommands.Quote`（AuctionFavorites，原先直接 `Call GetLowestPrice`）与新增 `CraftCommands().QuoteMaterial`（CraftAssist 显式单材料报价命令）均改走 `PriceQuoteQueueV3:RequestQuote`；`CraftQuote` 桩保持「Refresh 不自动报价」诚实语义（注释指向共享服务）。
- **注册**：`toc.g` 在 `services/rs_auction_query_v3.lua` 之后新增 `services/rs_price_quote_queue_v3.lua`（双向 0 差异）。
- **报价快照接回投影 + itemType 索引 + 修复 `_FailPending` 丢弃失败快照 bug**：
  - 新增 `pricesByItemType[itemType]` 跨 Feature 读模型 + `GetPriceByItemType(itemType, itemGrade)`（grade 软过滤、omit-grade 返回最近价、未知返回 nil 而非 0）；`CompletePending` 仅在 `status=="ready"` 时写入索引（失败/不可读不覆盖好价，fail-closed）。
  - Trade `BuildTradeMaterialProjection` 材料循环改为读共享读模型：itemType 已有完成报价时填 `unitCostCopper`/`costCopper`（status=`quoted`），否则保持 `explicit_quote_required`；**只读不发服务器请求**。
  - CraftAssist `CraftQuote` 从「恒返回 explicit_quote_required 桩」改为读共享读模型：有价返回 `price, "quoted"`，无价保持桩语义。
  - **修复 bug**：`_FailPending` 原先先清 `Q.pending` 再调 `CompletePending`，导致 `CompletePending` 读到 nil 静默丢弃失败快照（第二次报价失败时 `GetSnapshot` 仍返回 `queued`）。改为交 `CompletePending` 单点清空。
- **验证**：`luac -p` 语法通过；Foundation Audit 全 PASS（`toc=198 activeLua=198 allLua=207 globals=0 ...`）；自定义 harness `price_quote_drain_harness.lua`（14/14）+ `price_quote_read_model_harness.lua`（8/8）全 PASS（`.workbuddy/tmp/`，不入包）。
- **未验证项**：`GetLowestPrice` 在 RU 客户端的真实返回形态需 RU 实机 Fresh Reload 验证；`pricesByItemType` 为会话级内存索引（重载清空，未做自动重建以避免重载 fan-out）；Trade Feature 尚无 `QuoteMaterial` 命令（成本依赖用户在 CraftAssist/Auction 先询价）。

## M1.16.0.18.50 — StatusDisplay 头顶全显（headShowAll）+ 勾选即见联动（参考 addon show-all 精华）（2026-08-31）

- **用户报告 Bug（延续）**：.49 修复渲染器 `HasTracked` 总开关后，勾选"头顶显示"且已追踪若干状态时图标仍不出现。深挖发现残留门禁：`ProjectPlates` 的 `BoundedTracked` 在投影层按 tracked 行过滤，tracked 列表为空（或玩家身上的 Buff 不在追踪列表）时 buffs/debuffs lane 产出 0 行——渲染器虽已启动但无行可画，表现为"任何图标都不出现"。对照 GitHub 同类 addon（belovres/ArcheRage-addons，RU 同客户端）精华：`targetdebufftracker/self.lua` 用 `target_buffs[strBuffId] ~= nil or showAllBuffs` 做**全显开关**，空 tracked 列表时用户开箱即可看到全部在场 Buff/Debuff；`buffcaptracker.lua` 单窗口容器 + OnUpdate；`distracker.lua`/`gstracker.lua` nil 时移屏 (5000,5000) + z>0 深度门禁。
- **修复 1（show-all 下沉投影层）**：`rs_buff_display_projection.lua` `BoundedTracked` 尊重新设置 `headShowAll`：`showAll == true or isTracked == true` 才收集行（仍受 `headMaxIcons` 有界限制）。tracked 语义从"行来源唯一门禁"降级为"可选过滤"——追踪列表为空或未命中时，在场 Buff/Debuff 照常投影显示，对齐参考 addon 开箱即见语义。
- **修复 2（设置默认开 + 归一化）**：`rs_buff_display_store.lua` `NormalizeSettings` 增加 `headShowAll = value.headShowAll ~= false`（默认开启，旧存档无损兼容）。
- **修复 3（导入导出链同步）**：`rs_buff_display_feature.lua` `ExportAll`/`SerializeExport` policy 白名单加入 `headShowAll`；`ImportAll` 布尔归一分支加入 `headShowAll`——导入导出往返不丢新设置。
- **修复 4（勾选即见联动）**：`rs_v3_buff_display_page.lua` Tab2 新增"全部显示：开/关"开关（`AddHeadToggle("headShowAll", ...)`，默认开）；`AddHeadToggle` 增加联动：`headEnabled` 从关→开时若 Feature 未启用则自动 `SetPreferredEnabled(true)` + `AcquireConsumer`（对齐参考 addon 开箱即用——用户无需先到总开关启用功能）；hint 文本同步"全部显示（不受追踪限制）/仅显示已追踪"。
- **验证**：自定义 Harness `17/17 PASS`（`.workbuddy/tmp/head_showall_harness.lua`：showAll=true 时空 tracked 列表仍全显 buffs/debuffs、showAll=false 时回到 tracked 过滤、maxIcons 有界截断、按 category 分 lane、feature 导入导出往返含 headShowAll、NormalizeSettings 默认值）；Foundation Audit 全 PASS（`toc=196 activeLua=196 allLua=353 globals=0 presentation=0 rawNative=0 rawScope=0 detachedWidgetState=0 apiDependency=0 apiCapability=0 businessIds=0 auctionEventOwners=0`）；全量 Lua `luac -p` 语法检查 352/352 通过。BuildTag：`v3-m1.16.0.18.50-statusdisplay-head-showall`（同步修正 `S.BuildTag` 版本一致性：此前停在 .48 而 CHANGELOG 已至 .49，本轮一并升到 .50）。
- **语义收口**：`headShowAll` 只影响 buffs/debuffs 头顶行的收集门限；distance/class/gearScore/装备/cast 等 6 个非 tracked 组件本就按组件 enabled 渲染不受影响；`headEnabled=false` 仍为主开关整体关闭。参考 addon 的"全显"与"z>0 深度门禁/移屏兜底"中，深度门禁本项目已由 `RenderScope` 的 `depth<=0` 检查覆盖，移屏 (5000,5000) 为 RU 特有 API 兜底不适用（本项目 anchor 缺失走 `metrics.anchorFailures` 诊断），不凭推断新增。

## M1.16.0.18.49 — StatusDisplay 头顶图标门禁修复（参考 addon 精华）（2026-08-31）

- **用户报告 Bug**：勾选"头顶显示"后玩家/目标身上不出现任何悬浮图标。GitHub 调研同类实现（belovres/ArcheRage-addons，RU 同客户端：disttracker/gearscoretracker/targetdebufftracker(self/enemy/tracktarget)/hiddendebufftracker 共 6 文件）吸取精华后定位根因。
- **根因（业务门禁不对称）**：`BuffHeadMarkersV3` 渲染器 `Start/VisualTick/Reconcile` 三处用 `HasTracked()`（tracked.buff/debuff 列表非空）作**总开关**，而 Feature 侧 `HeadScopeActive()` 只用 `headEnabled + AnyHeadComponent + headPlayer/headTarget`（无 HasTracked）。用户追踪列表为空时：position/distance/metadata/equipment/cast lane 全部在跑、投影与事件正常，但渲染器在 `EnsurePools` 之前就被 `not HasTracked` 拦死、永不启动——**distance/class/gearScore/装备/cast 等不依赖 tracked 的组件被连带隐藏**，表现为"任何图标都不出现"。属 10 组件重写（.46）时门禁未同步放宽的回归。
- **修复（对齐参考 addon show-all 语义）**：新增 `HasRenderableComponents()`（10 组件任一 enabled 即真），替换三处 `HasTracked` 总开关；`HasTracked` 保留但仅约束 buffs/debuffs 行数（`ProjectPlates` 的 `BoundedTracked` 天然按 tracked 过滤，tracked 为空渲染 0 行，其余组件照常显示）。`headEnabled=false`/无组件启用的空转防护保留。
- **诊断兜底**：`RenderScope` 在 anchor 缺失/depth<=0 时记录 `metrics.anchorFailures[scope]`（count/lastAt/lastErr）；新增 `BuffHeadMarkersV3:GetDiagnostics()`（running/consumerHeld/poolsAllocated/ticks/projections/anchorFailures/source/anchor/projectError）供 RU 实机排查；Feature `ProjectScope` 投影失败时 err 不再丢弃，写入 `lane.projectErr`（原静默清空 lane.x/y/depth）。
- **坐标空间裁决**：参考 addon 全部零 scale 直锚 `UIParent`，本项目 `ScreenProjectionV3` 归一化到 RSUI logical 坐标有 `rs_api.lua:133 GetUiMetrics` 权威注释背书（1024×768 除 scale 教训），**保留不改**；但 `NormalizeScreenPoint` 启发式（值落在 `(logicalW+2, screenW+2]` 区间才除 scale）在 4K/UI scale>1 下有误除风险，本轮不凭推断改共享投影服务（影响 Healer markers/range circles），通过 `GetDiagnostics().source/anchor` 暴露 + RU 手测 checklist 验证。
- **验证**：自定义 Harness `72 passed / 0 failed`（原 54 + 新增 18 条渲染器门禁/诊断断言：EMPTY tracked 时渲染器正常 Start、VisualTick 不短路、RenderScope 照常投影、anchor 丢失记录诊断且渲染器保持运行、headEnabled 主开关仍可启停）；Foundation Audit 全 PASS（`toc=196 activeLua=196 allLua=353 globals=0 presentation=0 rawNative=0 rawScope=0 detachedWidgetState=0 apiDependency=0 apiCapability=0 businessIds=0 auctionEventOwners=0`）；全量 Lua `luac -p` 语法检查 352/352 通过。BuildTag：`v3-m1.16.0.18.49-statusdisplay-head-gate-fix`。
- **契约收口**：`BuffHeadMarkerContractVersion` 2→3（门禁解耦 tracked + GetDiagnostics 诊断面 + anchorFailures 痕迹）；`rs_v3_acceptance.lua` 契约断言升 `buffHeadMarkers.version >= 2` + `GetDiagnostics`/`metrics.anchorFailures` 存在性；`rs_buff_display_acceptance.lua` `feature_contract` 升 `BuffHeadMarkerContractVersion >= 3` + 新增 `head_marker_gate_contract` 序列（Start/Stop/Reconcile/VisualTick/GetDiagnostics/anchorFailures 五面齐全）。全项目渲染器同源扫荡：combat_visual_guides（IsEnabled 门禁 + 渲染失败释放）、healer_head_marker（settings.enabled 门禁 + 已有 projectionFailures 诊断）、healer_raid_overlay（calibration/runtime 双模式）均为"功能开关"语义，数据空只隐藏不拦截启动，无 HasTracked 类总开关残留。

## M1.16.0.18.48 — StatusDisplay 全面重新审计（规范驱动）（2026-08-31）

- **审计性质**：本轮为纯审计轮，按 100 步规范对状态显示执行完整重新审计；**无代码改动**（审计确认 HY3 六项修复在位且正确，未发现新运行时 Bug，故不改代码）。BuildTag 提升至 `v3-m1.16.0.18.48-statusdisplay-full-reaudit` 以标记审计版本。
- **Phase 1 文档阅读**：`Docs/README`、`Docs/CURRENT_REBUILD_STATUS.md`、`Docs/Architecture/SERVICE_ARCHITECTURE.md`、`toc.g`（196 个 Active 条目）。
- **Phase 2 Authority 审计（逐文件读真实代码）**：`services/rs_aura_observation_v3.lua`（377 行）、`services/rs_status_classification_v3.lua`（212 行）、`services/rs_screen_projection_v3.lua`（198 行）、`services/rs_unit_identity_v3.lua`（331 行）、`features/rs_feature_runtime.lua`（367 行）、`core/rs_scheduler.lua`（389 行）、`core/rs_refresh_coordinator.lua`（169 行）、`features/combat/buff_display/rs_buff_display_feature.lua`（57.8KB）、`rs_buff_display_store.lua`（419 行）、`rs_buff_display_projection.lua`（165 行）、`rs_buff_display_acceptance.lua`（84 行）、`presentation/v3/pages/rs_v3_buff_display_page.lua`（550 行）、`presentation/v3/widgets/rs_v3_buff_display_widget.lua`（124 行）、`presentation/v3/widgets/rs_v3_buff_head_markers.lua`（370 行）。结论：AuraObservationV3=共享事实层（GetSnapshot 显式读取 + TTL 120ms + Demand reconcile）、StatusClassificationV3=全项目唯一"效果是什么" Authority、ScreenProjectionV3=共享只读投影（RSUI logical 空间）、UnitIdentityV3=保守身份事实但不在 StatusDisplay 链、Scheduler=单一 OnUpdate driver（highfrequency ≥1ms 不计 backlog）、RefreshCoordinator=仅 debounce/coalesce 且 StatusDisplay 未用（符合规范第 29 节"周期任务归 Scheduler"）、FeatureRuntime=三方法契约（.47 已补 Initialize）。
- **Phase 3 Prior-Agent 时间戳交叉核对收口**：基线 10:39 未动 = `rs_feature_runtime.lua` / `rs_refresh_coordinator.lua` / `rs_aura_observation_v3.lua` / `rs_unit_identity_v3.lua`；Prior-Agent 窗口 17:33–23:35 = `rs_screen_projection_v3.lua`(17:33) → `rs_status_classification_v3.lua`(18:26) / `rs_scheduler.lua`(18:25) / `rs_v3_buff_head_markers.lua`(18:32) / `rs_buff_display_acceptance.lua`(18:54) / `rs_v3_buff_display_page.lua`(18:55) / `rs_buff_display_projection.lua`(22:29) / `rs_v3_buff_display_widget.lua`(22:30) / `rs_buff_display_feature.lua`+`rs_buff_display_store.lua`(23:35)。全部文件已在本轮逐行读取，无未审新版本。
- **Phase 5 Native Capability 审计**：确认 `GetUnitsInSight` 不进入 StatusDisplay 链（状态显示使用 Tracked 集合，不做视野扫描），规范第 19 节 Visible Unit Observation 记录为"当前不适用"。
- **Phase 6 共享发现审计**：`UnitIdentityV3` 提供保守身份事实（ParseExplicitKind/GetById/ResolveCombatEndpoint/RefreshPlayerIdentity，bounded cache，只读 target-token 不扫描），但在 StatusDisplay 的 6 条 lane 中无任何消费，规范第 99 节记 N/A。
- **Foundation 使用情况（规范第 99 节）**：FeatureRuntime=使用（三方法契约 + lifecycle topic + DisableAll ForceQuiesce）；Demand=使用（`v3.aura_observation` lease，0→1/options-change/1→0 reconcile）；Scheduler=使用（aura 400ms / head 100ms / metadata 1000ms / equipment 2000ms / highfrequency 1ms 位置 lane）；FrameBudget=经 Scheduler 内置集成（Scheduler 每个 due task 调 `frameBudget:Request`，feature 不直用）；AuraObservationV3=使用（GetSnapshot/GetStatusMap）；UnitIdentityV3=N/A（不在链上）；Visible Unit Observation=N/A（Tracked 集合而非视野扫描）；Persistence=使用（RegisterV3Store schema 4 + MigrateState 1/2/3→4 + MarkStoreDirty write-fence）；RSUI=使用（Page/Widget 消费 detached Projection + `Feature.Commands`）；ViewState=经 RSUI 页面机制（四页签 Switcher 路由）；ActionRunner=经 Commands 可失败操作；RefreshCoordinator=N/A（周期位置 lane 归 Scheduler，仅事件路径一次性 `_QueueEventRefresh`）；Diagnostics=使用（feature health 快照 + FoundationGate 检查）；统一 candidate capture（规范 68-69 节）=尚未实现，文档层概念，无可用能力缺口。
- **验证**：Foundation Audit 全 PASS（`toc=196 activeLua=196 allLua=353 globals=0 presentation=0 rawNative=0 rawScope=0 detachedWidgetState=0 apiDependency=0 apiCapability=0 businessIds=0 auctionEventOwners=0`）；全量 Lua `luac -p` 语法检查通过；自定义 Harness `44 passed / 0 failed`（`.workbuddy/tmp/status_display_harness.lua`，开发工具不入包）。BuildTag：`v3-m1.16.0.18.48-statusdisplay-full-reaudit`。

## M1.16.0.18.47 — StatusDisplay HY3 收口修复（2026-08-31）

- **Feature 补上 Initialize() 完成 FeatureRuntime 三方法契约**：`combat_buff_display` 此前缺 `Initialize()` 导致 FeatureRuntime 注册失败（`IsImplemented=false`、AcquireConsumer 直接拒绝、Refresh 报 "buff display aura lease not held"），整个状态显示在 Fresh Reload 后报废。现补齐 `Initialize()`：EnsureStoreLoaded → 校验 AuraObservationV3（GetSnapshot/GetStatusMap）→ StatusClassificationV3（ClassifyEntry）→ ScreenProjectionV3（ProjectUnit）→ ProjectStatusMap/ProjectPlates → 构建 trackedIndex，一切下游 lane/demand/投影接通。
- **FoundationGate 陈旧契约修正**：`buff_display_v3_statusmap_contract` 仍要求 `schemaVersion==3`，而 Store 已是 schema 4，导致每次 Fresh Reload 门禁必 FAIL。已改 `== 4`。
- **Foundation Audit 白名单补登记 2 个真实 RU API**：`X2Locale`、`UnitDistance`（api_functions.lua 有签名），Audit globals 归零。
- **非官方 API 面改安全读取**：`UnitDistance`/`X2Locale`/`COMBINED_ABILITY_NAME_TEXT`/`ES_MAINHAND`/`ES_OFFHAND`/`ES_RANGED`/`ES_BACKPACK` 均改经 `Global()` 安全读取（load 时不存在则永久禁用对应调用路径，能力宿主由 `S.Api:ResolveCapabilityHost` 解析），不再裸全局访问。
- **ReadEquippedIcon 增加 scope 参数**：`targetEquippedItem` 在 target 上下文中传 `true`（对齐 rg_api/rg_core/rg_gear_service_v3 同源模式），修复目标装备信息显示成自身装备的 bug。
- **Store 迁移兜底 schema 3 扁平 tracked 数组**：原 MigrateState 只找 `settings.trackedIds`/`value.trackedIds`，丢失 `settings.tracked = { 101, 102, 103 }` 扁平形态；新增循环遍历该形态，无损迁移。
- **MarkStoreDirty 成为缓存失效唯一钩子**：所有设置写路径（SetSettingValue/SetComponentField/SetTrackedId/ClearTrackedIds/SetClassification/ClearClassification/import）统一经 MarkStoreDirty → `F:InvalidateSettingsCache()`，消除投影读到过期设置的窗口。
- **GetSettingsProjection 接入 detached 快照缓存**：settingsCache/settingsCacheRevision/SettingsRevision() 惰性深拷贝 + 失效计数，投影不再直接引用 live store 表。
- **ProjectPlates 修复投影边界违规**：`out.components` 此前直接引用 live store 表，现经 CopyComponents 深拷贝（Harness 断言 `plates.components ~= F.State.settings.components` 实证通过）。
- **Widget Refresh 去冗余**：原 3 次 GetProjection 调用（"all"+player+target）收敛为 1 次 `GetProjection("all", 24)`，遍历 rows 按 scope 统计 playerCount/targetCount。
- **验证**：自定义 Harness `44 passed / 0 failed`（`.workbuddy/tmp/status_display_harness.lua`，开发工具不入包）；Foundation Audit 全 PASS（`toc=196 activeLua=196 allLua=353 globals=0 presentation=0 rawNative=0 rawScope=0 detachedWidgetState=0 apiDependency=0 apiCapability=0 businessIds=0 auctionEventOwners=0`）；全量 Lua 语法检查通过（排除 toc.g）；真实 `S.Api:Call` 低级原语确认存在于 `core/rs_api.lua:105`（Aura/Unit/CombatEventBus V3 服务共用，热路径先 Gate 后走 Call，与架构文档一致）。BuildTag：`v3-m1.16.0.18.47-statusdisplay-hy3-fix`。

## M1.16.0.18.46 — Buff Display Schema 4 / Four-Tab Page（2026-08-31）

- **Scheduler 增加高频 Lane**：允许 1ms 下限的调度任务，为头顶标记的位置刷新与单位连线提供 1ms 档位，不再被旧的低频下限钳制（`refreshMs/headRefreshMs` 永不上钳）。
- **新建 StatusClassificationV3 共享分类服务**：全项目唯一"效果是什么"Authority，用户可见分类只有 buff/debuff，hidden/special_rule 收敛为 detection source；解析顺序 = 用户覆盖 → 种子库（Buff ID 库 + Plates 兼容集）→ 快照来源启发式 → 默认（未知 hidden 归 debuff）。`ClassifyEntry/ClassifyId/SetOverride/ApplyOverrides/GetRegistrySnapshot/GetHealth` 全部公开。
- **Store 升 schema 4**：tracked 按 `{ buff = {...}, debuff = {...} }` 分桶；hidden 不再作为用户分类；10 个头顶组件（buffs/debuffs/distance/class/gearScore/mainHand/offHand/ranged/wings/castBar）各带 enabled/x/y/size/fontSize/alpha；从 schema 1/2/3 无损迁移，历史追踪 ID 经分类服务落入正确分桶。
- **Projection/Plates 改造**：状态行携带 `category/detectionSource`，tracked 查找走预建 O(1) 索引；Plates 投影只返回启用组件 + 按 headMaxIcons 有界追踪行；`ProjectPlatesContractVersion=1`。
- **头顶显示重写为 10 组件渲染器**：`BuffHeadMarkersV3` 覆盖全部 10 个组件，按组件 enabled 启停渲染；Focus 目标行修复。
- **Feature 增加 Runtime Lane**：按组件启停消费运行时数据（buffRows/debuffRows/distance/class/gearScore/主副手/远程/翅膀/cast），Demand=0 释放；事件驱动 + 低频兜底。
- **单位连线 1ms 刷新**：视觉引导刷新频率下限降到 1ms，与高频 Scheduler Lane 对齐。
- **`combat.buff_display` 页面重构为四页签**：状态追踪（Buff/Debuff/只看隐藏筛选 + 关键词搜索 + 行点击 Toggle 追踪）/ 头顶显示（5 个开关 + 图标大小/数量/位置/刷新 4 个数值）/ 布局外观（10 个组件卡片，每卡启用开关 + x/y/size/fontSize/alpha 5 个数值，滚动承载）/ 导入导出（快速 ID 导入 合并/覆盖 + 完整导出/导入文本）。所有写入走 `Feature.Commands`：`SetTrackedId(id, category, enabled)` 显式传 category（修复旧 2 参调用误把布尔当 category 落入 debuff 桶的隐患）、`SetComponentField`、`ImportTrackedIds/ExportAll/SerializeExport/ParseImportText/ImportAll`。行点击 = 先选中后激活（`HandleRowClick` 契约），单击即切换追踪。
- **"隐藏"按钮语义修正（schema 4 对齐）**：hidden 不再是用户分类后旧"隐藏"开关对投影无效果；页面改为"只看隐藏"视图过滤器，仅显示 `detectionSource=="hidden"` 的行，与覆盖率 Hidden 计数一致。
- **toc.g 补登记 `services/rs_status_classification_v3.lua`**：该共享服务此前未被加载清单包含，游戏内为 nil 时自动分类会静默降级。
- **验收/门禁同步 schema 4**：`rs_buff_display_acceptance.lua` 升到 store schemaVersion==4，新增分类服务契约、schema 4 确定性投影断言（hidden 来源行归类 debuff）、10 组件投影与 Plates 投影契约、完整 Commands 面检查；`rs_v3_acceptance.lua` 的 buff 观察契约要求 `SchemaVersion==4` 与分类服务在场；`FoundationGate v62`。
- 本地验证：Foundation Audit 静态检查（toc/activeLua/globals/presentation/rawNative/businessIds）全 PASS；Lua 5.1 `luac` 语法门禁补齐（新增本机 luac 工具链）；`luaparser` 对四页签页面语法校验 OK。BuildTag：`v3-m1.16.0.18.46-buff-display-schema4-four-tab-page`。

## M1.16.0.18.45 — Product Usability Recovery（2026-08-31）

- **治疗校准重新接真实团队事实**：校准模式通过独立 Preview Consumer 读取 Team/Aura detached projection；治疗功能本体关闭时仍可显示真实团队成员颜色，退出校准立即释放 Preview Demand，不用推荐名单悬浮窗维持数据源。
- **状态显示恢复“追踪 Buff → 玩家/目标头顶标记”产品能力**：`v3.buff_display` Store schema 升到 3，保存最多 32 个精确 Buff ID 与玩家/目标、图标大小、数量、Y 偏移、刷新、层数/剩余时间设置；新增 `BuffHeadMarkersV3` bounded icon pool。收口时同步修正 `BuffDisplayAcceptance/FoundationGate` 仍要求 schema 2 的旧门禁，防止静态 Audit 绿灯而运行 Sequence 失败。
- **ScreenProjectionV3 v3 / Combat Visual Guides**：统一逻辑 UI 坐标与 Camera fallback，范围圆不再直接混用物理像素；Unit Lines 支持“自己↔目标、目标↔目标的目标、自己↔焦点、焦点↔焦点的目标”四条有界关系，并允许 50–1000ms 刷新频率。无 Tick，Feature Demand 归零后释放 Scheduler/视觉资源。
- **团队自动职责**：新增 86 个精确职业组合的静态职责目录，Ability Set / TeamRoster 变化时只对当前玩家调用已验证的 `X2Team:SetRole(role)`；不把读取任意成员职责错误扩张成任意成员写入。
- **生活 HUD 回收**：Trade FloatingSurface 可直接选择/循环起点终点，RU zone boolean-set/静态候选兼容继续由服务器 ratio 作为路线真实性 Authority；Treasure/Fishing 恢复独立悬浮窗，Treasure 主页面行选择真正调用 Feature Command。
- **制作规划/制作台去 raw ID**：普通用户改为选择已核制作物，由 Feature 内部解析 CraftID/ItemID；页面不再要求输入 `itemType/craftType/doodadId`。内部 ID 只留诊断/兼容入口，材料/持有/缺口状态使用中文产品语义。
- **背包旧版高价值交互迁回 V3**：新增跟随原生背包的 `取同类 / 放同类 / 停止` 快捷条；银行/箱子打开时按已验证的同类物品语义串行移动。类别批量整理保留为高级操作，快速任务与类别批量任务互斥；Scheduler 创建失败、仓储关闭、Feature Disable 都会回滚/停止，不留下僵尸移动任务。
- **AuctionQueryV3 v2 成为无 token 拍卖搜索唯一事件 Authority**：统一 9 参数 `SearchAuctionArticle`、串行 pending、超时清理、bounded current-listing rows。`tools.auction` 收藏与 `tools.market_analysis` 当前挂单行情共享该 Service；“当前挂单”不冒充历史成交价。Foundation Audit 新增 `AUCTION_ITEM_SEARCHED` 单一 Authority 静态门禁。
- `UIV3Acceptance v35 / FoundationGate v61`。最终 Foundation Audit 目标/结果：`195/195 Active TOC + 351/351 Lua`，`globals/presentation/rawNative/rawScope/detachedWidgetState/apiDependency/apiCapability/businessIds/auctionEventOwners=0`。专项回归：AuctionQuery、Bag task mutex、Healer calibration、ScreenProjection batch、Trade zone-shape、VisualGuide rollback、Alerts duration 全部 PASS。
- Product Capability Matrix 重新扩展被旧版/用户要求重新发现的能力后为 125 条：`77 IMPLEMENTED / 35 PARTIAL / 2 TODO / 11 SPECIFIC_RUNTIME_BLOCKED / 0 UNREVIEWED`。BuildTag：`v3-m1.16.0.18.45-product-usability-recovery`。


## M1.16.0.18.44 — DPS Skill Proxy Source Classification（2026-08-31）

- 修复 RU 老问题：`治愈之泉` 是玩家放置技能实体，不是玩家。旧 DPS shared-heal ledger 直接以 `sourceName` 建 Actor，导致该技能以独立治疗者进入排行榜，并可能把技能实体送入 CombatRelation。
- 新增 `CombatSourceProxyCatalog v1`，首个 family 精确覆盖治愈之泉 11948 / 41224 / 41225；DPS Domain 升 v7。代理 source 在关系学习与 Actor 创建之前 fail-closed：不进玩家榜、不写 CombatRelation，治疗量进入 `proxySourceHeals/proxySourceHealAmount` 显式诊断。
- 复核 bundled RU API 后确认没有可靠 generic proxy→caster owner link；因此最终实现**没有**使用本机施法时间、最近施法者、唯一已观察候选、距离或目标来猜主人。多人可同时放置治愈之泉，任何这类推断都可能把他人治疗算给自己。真实 `sourceName=玩家` 的同技能事件仍正常计入玩家。
- DPS 页面待确认诊断增加“技能代理未归属”，避免为了去掉假玩家而静默吞掉无法可靠归属的治疗量。`UIV3Acceptance v33 / FoundationGate v59` 新增 proxy source blocker。
- 本地验证目标：Foundation Audit `191/191 Active TOC + 347/347 Lua`；texlua Domain 故障注入验证 proxy source 不成 Actor、不触发 Relation 记录、真实玩家 source 的治愈之泉仍能统计。BuildTag：`v3-m1.16.0.18.44-dps-skill-proxy-source-classification`。

## M1.16.0.18.43 — Combat / Life Usability Recovery（2026-08-31）

- 根据 RU 实机负面证据收缩战斗页面信息密度：DPS 与 Death Review 默认折叠高级设置/诊断，把纵向空间优先让给排行、明细与死亡时间线；Healer 页面不再创建推荐名单/成员详情表，旧 `combat.healer` 推荐悬浮 Widget 从 Active TOC 移除，治疗辅助产品出口收敛为规则/颜色设置、Head Marker 与团队色块校准/覆盖。
- 修复 Healer 团队校准“打开无反应”：Raid Overlay 的 calibration 现在可以在 `combat_healer` Feature 关闭时独立运行，显示 4×25 校准色块且持有 **0 个 Healer Consumer**；退出校准或切回 live overlay 时按模式转移资源。旧 Healer sequence acceptance 同步改为禁止重新注册已删除的推荐 Widget，并验证 standalone calibration 生命周期。
- `combat.buff_display` 从低频快照补成 Demand-scoped `BUFF_UPDATE` / `TARGET_CHANGED` 观察；Buff burst 通过 120ms one-shot 合并后读取，Consumer=0 解除事件/任务；Presentation 明确区分“确实为空”和“状态事实不可读”。
- Boss 机制页按真实 `BossAlerts` 字段 `alert/kind/names/debuffId/style` 重建说明，接入共享 `AlertsService` + 新 `AlertHudV3`，增加 HUD 开关/锚点/字号/持续时间与“大字/倒计时”测试；修复不同 Alert 文本错误继承旧较长 expiry 的问题。自动机制匹配仍保持 Partial，禁止恢复 `CHAT_MESSAGE` 猜测。
- 新增共享 `ScreenProjectionV3 v2` 与受能力治理的 global-call primitive。`combat.unit_lines` 解除整项 Runtime Blocked，但只承诺“自己 ↔ 当前目标”的有界点状连线；`combat.range_assist` 只承诺用户自定义自身半径圆。两者均 Demand-scoped、无 Tick，范围圆用 `ProjectWorldBatch()` 一次捕获 Camera basis，避免每个点重复读取相机状态；新 `CombatVisualGuidesV3 v2` 只负责 bounded dot pool Diff 渲染并在分配失败时回滚刚取得的 Consumer。
- Trade 兼容 RU 生产/可售地区 `{[zoneId]=true}` 返回形态与 numeric-string/id-name map；可售列表为空时只以生产地区作为**候选 UI 列表**，真正路线货率仍由 `GetSpecialtyRatioBetween` 服务器结果作为 Authority。Trade/Bonds 新增独立 `life.trade` / `life.bonds` FloatingSurface，窗口自行持有/释放 Feature Consumer；普通 Trade/Craft Refresh 仍不会批量询价。
- `UIV3Acceptance v32` / `FoundationGate v58` 增加 ScreenProjection、Boss HUD、Visual Guides、Life Economy Widgets、Buff observation 与 removed-healer-widget usability contract。产品 Matrix 因用户明确移除 Healer 推荐悬浮能力缩减为 122 条，并根据最新 RU 负面证据重新降级为 `77 IMPLEMENTED / 31 PARTIAL / 3 TODO / 11 SPECIFIC_RUNTIME_BLOCKED / 0 UNREVIEWED`，不把本地修复提前宣称为 RU 完成。
- 本地验证：Foundation Audit `190/190 Active TOC + 346/346 Lua` PASS；Healer standalone calibration、Alert expiry/rearm、ScreenProjection batch、VisualGuide Consumer rollback、RU-style Trade zone shape 专项均 PASS。BuildTag：`v3-m1.16.0.18.43-combat-life-usability-recovery`。

## M1.16.0.18.42 — Business Page Logical ID / Strict Build Fail-Fast Recovery（2026-08-31）

- 修复 RU Fresh Reload 暴露的 `tools.social` 页面构建阻断：Business 通用工具条 `v3_business_<id>_actions` 在 `tools_social` 展开后与 Social 专用 `v3_business_tools_social_actions` 完全同名，导致第一个 Preflight 拒绝 Social Row，随后输入/按钮因 `parent=nil` 再产生两次 Preflight，最终 `button.onClick` 对 nil 的二次异常覆盖了真正根因。Social 专用 Row 已改为独立逻辑 ID `v3_business_tools_social_member_actions`。
- `RSUI ComponentCore` 新增 Strict Build Fail-Fast contract：严格 Page/Widget/Modal BuildScope 内，任何非 `buildOptional` 的 required 组件创建失败都会在第一次失败立即中止事务，保留原始 component/id/reason；显式 `buildOptional=true` 继续允许安全降级。BuildTransaction 在 callback 二次异常存在时优先保留 `scope.failure` 作为主因。
- Foundation Audit 新增 Business 共享页逻辑 ID 展开扫描：同时检查字面量重复与 `"..." .. id .. "..."` 对 Registry route id 展开后的固定 ID 冲突；故障注入恢复旧 Social ID 时门禁必定失败。`UIV3Acceptance v31` / `FoundationGate v57` 要求 Business component-id contract 与 Strict Build Fail-Fast contract。
- 本地验证：Foundation Audit `186/186 Active TOC + 342/342 Lua` PASS，`businessIds=0`；Business ID 故障注入 PASS；Strict BuildScope 行为测试 `required=1 / optional=1` PASS。BuildTag：`v3-m1.16.0.18.42-business-page-id-build-failfast-recovery`。

## M1.16.0.18.41 — Bag / Team / Persistence Integrity（2026-08-31）

- 修复 Bag 单槽存入方向的真实业务错误：`DepositBank/DepositCoffer` 现在始终读取背包源槽，再独立应用 bank/coffer 目标黑名单策略；不再把目标仓储同编号槽位误当源物品。四方向 source mapping 已通过专项契约测试；同时修复 Bag 投影 `tone` 运算优先级会返回布尔 `true` 的 Lua 表达式错误。
- 强化 Bag category batch 生命周期：Scheduler 创建失败立即回滚，Cancel/Feature Disable 都强制移除任务并清空 queue/runtime；页面只报告“任务已启动 + 队列数”，不再在异步任务刚入队时伪称“批量操作已完成”。
- 修正 Team Role 能力语义：bundled API 的写签名是单参数 `X2Team:SetRole(role)`，因此 Active V3 只承诺“当前玩家职责设置”，全队职责保持只读；TeamTools 在 Demand 存在时订阅 `v3.team_roster.updated`，解决 TeamRoster 延迟首刷/后续变化后职责投影长期停留旧快照的问题。
- Buff Cap 从一次快照升级为 Demand-scoped `BUFF_UPDATE` observation，高频事件以 150ms one-shot 合并后仅重读普通/隐藏数量；Consumer=0 解除事件并删除任务，不使用 Tick，也仍不猜测 RU 容量/顶替阈值。
- 修复 Activity/Tasks 专用持久化写入的 memory/store 分裂：任务追踪、scope、悬浮窗显隐，以及活动隐藏、HUD 行数/尺寸/最小化等 mutation 在 `MarkDirty` 失败时恢复原状态；复核确认公共 `Demand v2` 已自带失败反向 reconcile，因此没有重复增加一套 Demand 回滚实现。Craft 页面同时移除 Command 成功后重复执行第二次完整 Authority Refresh。
- `UIV3Acceptance v30` + `FoundationGate v56` 新增 Bag action/batch、Team role、Buff dynamic observation 与 specialized persistence mutation contract；Foundation Audit 保持 `186/186 Active TOC + 342/342 Lua`、所有静态越界计数为 0。BuildTag：`v3-m1.16.0.18.41-bag-team-persistence-integrity`。

## M1.16.0.18.40 — Demand Observation / Capability Cooldown Integrity（2026-08-31）

- 将 `ApiCapabilities.Cooldown` 从“仅元数据”提升为中央执行契约：`S.Api:CallCapability/ActionCapability` 在 Native 调用前统一消费 capability 级冷却，失败/异常调用同样不能立即重试打穿原生接口；新增可观测 cooldown state，普通无冷却能力不受影响。 Raid Applicant 的快速重复刷新在 1000ms 查询冷却内保留上一份已证明投影并显示 pacing 状态，不再因节流把列表瞬间清空。
- 修复页面生命周期遗漏：Housing / Butler / Random Shop / Instance Browser 不再在页面进入时直接 `FeatureRuntime:Enable()`，用户关闭状态保持关闭；启停只允许显式 `SetPreferredEnabled()`，页面只 Acquire/Release Consumer。开发静态门禁新增 Active V3 Presentation 直接 Enable/Disable 禁止规则。
- 修复动态功能“只有一次快照”的问题：Target Monitor 监听 `TARGET_CHANGED` 并在 Consumer 存在时以 500ms 低频刷新距离；Treasure 以 500ms Demand Scheduler 更新玩家位置/方向/距离；Fishing 对 `TARGET_CHANGED` 即时刷新，对高频 `BUFF_UPDATE` 以 100ms one-shot 合并后执行最多 128 Buff 的有界扫描。全部在 Consumer=0 时释放，无 Tick。
- Generic Business Demand 的自定义观察资源与通用事件订阅现在按同一获取事务处理；事件订阅失败会反向撤销刚创建的 Scheduler 资源，避免 Acquisition 失败留下后台任务。Business/Life Authority 更新统一发布 Feature update topic，页面订阅 detached read-model 更新；删除 AcquireConsumer 后再次 Commands.Refresh 的重复首刷路径。
- 修复真实业务闭环：Trade 异步货率结果会主动通知页面；Bonds 排序/过滤/重复优先级写入采用回滚安全持久化并触发真实 Authority 刷新；Treasure 选择、Bag batch 设置、Auction 关键词/收藏等设置在 `MarkDirty` 失败时恢复内存状态。Craft 的 Active implementation 补齐实际使用的 `X2Bag` API dependency。
- `UIV3Acceptance v29` + `FoundationGate v55` 新增 capability cooldown 与 Target/Treasure/Fishing dynamic observation contract；Foundation Audit 保持 `186/186 Active TOC + 342/342 Lua` 且所有静态越界计数为 0。BuildTag：`v3-m1.16.0.18.40-demand-observation-cooldown-integrity`。

## M1.16.0.18.39 — Feature Truth / Lifecycle Recovery（2026-08-31）

- 修正 `v3_live_ui` 对正常异步 Layout Queue 的误报：RSUI 记录 queued age / scheduler state，Foundation 只在 `hard>0`、stale root 或 unscheduled root 时告警；普通 50ms reflow 的 fresh `pending=1` 不再单独产生 Warning。
- 收紧 Business/Life 页面生命周期：打开一个用户明确关闭的 Feature 不再自动 Enable；显式开关统一走 `FeatureRuntime:SetPreferredEnabled()`，Demand 只在页面 Consumer 存在时建立，关闭后立即释放事件/共享资源。Generic Business event subscription 由 Enable 移到 Demand `0→1`，`1→0` 解除。
- 修复功能真实性与服务器查询边界：Trade/Craft 普通 Refresh 不再在材料循环中调用 cooldown-bound `GetLowestPrice`；Auction 删除错误的一参数 `SearchAuctionArticle` 调用；Team Move、Raid Create/Accept/Reject、Fishing Auto-R 等未验证写操作 fail-closed；Boss Alert 不再把 `CHAT_MESSAGE` 当机制事件；Buff Cap 不再猜测容量阈值。
- 修复 Social `GetFriendList/GetBlockList/GetMuteList` 参数差异，并修复 Lua 5.1 循环闭包捕获导致四个名单按钮可能落到最后一个动作的问题；Team Role 改为真实 `TMROLE_*` 枚举下拉。Generic Business Store 只持久化 default contract 声明字段，运行期 batch/query 状态不会污染永久配置。
- Registry/Completion Matrix 同步为真实能力状态；`UIV3Acceptance v28` + `FoundationGate v54` 新增 `v3_feature_truth_contract`，防止 Partial/Blocked 能力再次被登记为已完成。
- BuildTag：`v3-m1.16.0.18.39-feature-truth-lifecycle-recovery`。

## M1.16.0.18.38 — Life Projection Contract Recovery（2026-08-31）

- 修复 RU Fresh Reload 暴露的 `rs_v3_life_m16_pages.lua:122` 页面激活故障：`Trade` 已有公开 `GetProjection()`，但 `Bonds / Treasure / Fishing` 只实现了 Authority 级投影，导致共享生活页面调用不存在的 Feature facade。三者现在均通过 Feature 公共边界返回 detached Projection，Presentation 不直接读取 Authority。
- `rs_v3_life_m16_pages.lua` 在 `PageRoot` / Native allocation 前预检 exact Feature Projection + Commands 契约；故障注入时 4/4 生活页面均在 Native 分配前 fail-closed，避免再次形成“Factory 已注册但激活时才崩”的半构建页面。功能启停成功后同步刷新按钮/状态，并在 Disable 清空 Demand 后同步 page-local consumer 标记。
- `UIV3Acceptance v27` 新增 Trade/Bonds/Treasure/Fishing 的真实公共契约检查；`FoundationGate v53` 要求 Acceptance v27，因此这类漏导出不再能以“界面工厂存在”伪装成绿色 Foundation Gate。
- 本地专项 `life_m16_projection_contract_test`：`features=4 / detached=1 / preflight=4 / Native allocations=0` PASS；Foundation Audit `186/186 Active TOC + 342/342 Lua` PASS，所有静态越界计数为 0。RU Fresh Reload 仍需逐页打开 `life.trade / life.bonds / life.treasure / life.fishing` 关闭最终实机证据。
- BuildTag：`v3-m1.16.0.18.38-life-projection-contract-recovery`。

## M1.16.0.18.37 — Foundation Runtime Import / Authority Recovery（2026-08-31）

- 修复 RU Fresh Reload 暴露的系统性 API Import 边界错误：Feature 元数据继续使用 `X2Namespace:Method` 能力名，但 `NativeImports v3` 先映射到 namespace-scoped Native Contract 再执行 `ADDON:ImportAPI`；新增 FRIEND/AUCTION/STORE/CRAFT/RESIDENT/HOTKEY/BANK/COFFER 等当前 Active Feature 所需的 Suite-owned namespace 契约，并验证与 bundled `API_TYPE` 证据一致。
- `core/rs_api.lua` 增加调用时 Capability Host 解析；修复 Life/Business 文件在 API lazy import 前捕获 nil host 后永久失效的问题。Bag Registry 不再声明虚构 `DepositBank/WithdrawBank` 能力，改为真实 `MoveToEmpty*Slot` 方法。
- Native Import failure 现在区分 Foundation 与 Feature：单个业务 Feature Import 失败会 fault 该 Feature 并进入 warning/诊断，但不再污染整个 Native Foundation；Foundation Import 失败仍是 Blocker。
- 修复 `UIV3Acceptance` Gear Quick HUD spec ID 漂移（`combat.gear.quick`），并让 Foundation 的 `ui_foundation_matrix` 摘要输出首批失败标签；静态 Audit 新增 exact ApiCapabilities dependency 校验和 lazy-host/authority-scale 回归围栏。
- 修复 Strict Diff Authority cache-hit 的客户端缩放判断：Native extent/anchor getter 只允许额外应用 `uiScale`，不再二次乘 Suite `addonScale`。这是 RU 日志中数千次假 `AUTHORITY_VIOLATION` 的主要系统性来源；新增按 `text/visible/extent/anchor` 字段的违规计数，便于 Fresh Reload 继续定位真实外部写入。
- 本地最终门禁：Foundation Audit `186/186 Active TOC + 342/342 Lua` PASS；全 34 个 FeatureRuntime implementation 的 lazy API Initialize mock PASS，`23` 个 namespace import / `0` failure；Acceptance mock 除无法在纯 mock 复现的 UIParent root identity 外无其它 matrix failure。RU Fresh Reload 仍为最终 Native/Authority 验收 Authority。
- BuildTag：`v3-m1.16.0.18.37-foundation-runtime-recovery`。

## M1.16.0.18.36 — Craft Recursive Known-Record Graph（2026-08-31）

- Active Craft now exposes a bounded recursive graph over complete recipe records already returned by the verified X2Craft getters, with ceil output-batch quantities and visible cycle, ambiguity, missing-material, overflow, depth, and node-limit diagnostics.
- The graph does not enumerate the unverified full catalog or claim complete recursive market cost. Dedicated `craft_v3_recursive_graph_test.lua` and the full local set pass `42/42`; Foundation Audit remains `toc=186 activeLua=186 allLua=342` with all escape counters zero.
- BuildTag is `v3-m1.16.0.18.36-craft-recursive-graph-gate`.

## M1.16.0.18.35 — Bag Window Context / Embedded Quick Actions（2026-08-31）

- Active V3 `tools_bag` now projects four Command-driven embedded quick actions and a capability-gated `ADDON:GetContentMainScriptPosVis` bag-window diagnostic. Native follow remains `diagnostic_only` and unknown embedding remains `fail_closed` because no verified reparent/embed API is available.
- Dedicated `bag_v3_window_context_test.lua` and the full local set pass `41/41`; Foundation Audit remains `toc=186 activeLua=186 allLua=342` with all escape counters zero. RU native reparent/embed and multi-resolution visual follow remain pending.
- BuildTag is `v3-m1.16.0.18.35-bag-window-context-gate`.

## M1.16.0.18.34 — Team Actions / Party Movement（2026-08-31）

- Active V3 `combat_team_tools` now exposes bounded role assignment, numeric member exchange, and move-to-party actions through Feature Commands matching the verified RU Team signatures; Presentation and Command Authority both validate role `1–999` and member/party indices `1–50`.
- Command failure or projection refresh failure is surfaced without false success. Dedicated `team_tools_roster_roles_test.lua` and the full local set pass `40/40`; Foundation Audit remains `toc=186 activeLua=186 allLua=342` with all escape counters zero. RU permission/cooldown/result and visual round-trip remain pending.
- BuildTag is `v3-m1.16.0.18.34-team-actions-gate`.

## M1.16.0.18.33 — Auction Favorite / Context UX（2026-08-31）

- Active V3 `tools_auction` now normalizes and persists a bounded keyword/favorite context (maximum 20 favorites), exposes explicit add/remove/search commands, and provides stable-index 8-row paging with refresh-safe selection.
- Search state is reported as `pending`/`failed`; result fields remain explicitly `unknown` until the RU native result schema is verified. Dedicated `auction_v3_favorite_context_test.lua` and the full local set pass `40/40`; Foundation Audit remains `toc=186 activeLua=186 allLua=342` with all escape counters zero.
- BuildTag is `v3-m1.16.0.18.33-auction-favorite-context-gate`.

## M1.16.0.18.32 — Craft Product / Cost / Shortage Projection（2026-08-31）

- Active Craft now enriches bounded structured product/material rows with Bag held-count aggregation, shortage, grade-aware lowest-price quotes, and line costs through governed API calls; Bag read failures/unknown occupied slots, bad quotes, and opaque/truncated payloads remain `incomplete/unknown`.
- Dedicated `craft_v3_cost_shortage_test.lua` and the full local set pass `39/39`; Foundation Audit remains `toc=186 activeLua=186 allLua=342` with all escape counters zero. Recursive subrecipe expansion, total graph cost, full RU field parity, and Fresh Reload remain pending.
- BuildTag is `v3-m1.16.0.18.32-craft-cost-shortage-gate`.

## M1.16.0.18.31 — Bag Category Batch Deposit（2026-08-31）

- Active V3 `tools_bag` now supports explicit category-based batch deposit to bank or coffer with persisted category/target/limit settings, bounded 1–40 queue, target-window/capacity/empty-slot checks, blacklist fail-closed handling, shared Scheduler step execution, strict source-slot verification, cancel, failure-stop, and status projection/refresh.
- Dedicated `bag_v3_category_batch_test.lua`, the existing Bag action/blacklist harnesses, and the full local set pass `38/38`; Foundation Audit remains `toc=186 activeLua=186 allLua=342` with all escape counters zero. RU category field, storage window, and move timing/return verification remain pending.
- BuildTag is `v3-m1.16.0.18.31-bag-category-batch-gate`.

## M1.16.0.18.30 — Bonds Filter / Duplicate Priority（2026-08-31）

- Active V3 Bonds now persists q20/q60/q100/Auroria filters, quantity/continent sorting, and mainland duplicate priority through the existing Store/Commands path.
- Filtering is applied before projection; reliable west/east row identity selects the configured priority, while unresolved identity preserves duplicate rows and emits an explicit diagnostic. Page controls refresh the table and visibly report enabled/disabled state.
- Dedicated Bonds filter coverage passes; the current full harness set is `37/37`, Foundation Audit remains `toc=186 activeLua=186 allLua=342` with all escape counters zero. RU board-field and visual round-trip verification, plus remaining product capabilities, are still pending.
- BuildTag is `v3-m1.16.0.18.30-bonds-filter-priority-gate`.

## M1.16.0.18.29 — Bonds Completion / Resource Projection（2026-08-31）

- Active V3 Bonds now resolves governed mainland and Auroria bond mappings without loading Legacy Resident service code, and projects `QuestProgressV3` states as completed, turn-in-ready, in-progress, not accepted, or unknown.
- Bonds performs a demand-scoped bounded bag scan (`min(Capacity, 240)`), aggregates verified item/stack field fallbacks, and exposes required quantity, held quantity, shortage, and visible partial/unknown diagnostics. Auroria token quantities remain unknown unless a safe identity is proven.
- Mainland `materialKey:quantity` completion keys are dated and persisted in `S.State.life.bondCache`, so duplicate rows across mainland continents share the same daily completion authority. The page adds resource, shortage, resource-status, and task-status columns.
- Registry dependencies/evidence and the maintenance addendum were synchronized. Dedicated Bonds coverage and the complete local harness set pass: `36/36`; Foundation Audit passes `toc=186 activeLua=186 allLua=342` with all escape counters zero. RU Fresh Reload, real field parity, and remaining filter/priority UX remain pending.
- BuildTag is `v3-m1.16.0.18.29-bonds-completion-resource-gate`.

## M1.16.0.18.28 — Business Feature Migration Closure / Runtime Blocker Fence（2026-08-31）

- 依据当前源码重新审计 34 个 combat/life/tools 业务条目；Trade、Bonds、Treasure、Fishing 完成独立 V3 垂直切片，另外 17 个条目接入独立业务桥与通用 V3 页面，Legacy 只作为规格参考。
- Registry 业务停止统计收敛为 `26 implemented/migrated + 8 runtime_blocked + 0 planned`。Fishing 明确阻塞于完整 R 源槽位枚举、快照、写入/还原和异常恢复契约，不把 `autoArmed` 会话标记当作功能完成。
- 新增注册表完成度契约（34/8/0）与 21 条新增页面工厂闭包/路由契约；修复 Trade 页面循环工厂捕获、业务页面循环工厂捕获，并为 Trade 在材料静态数据与拍卖最低价均可证明时输出材料成本/毛利。
- 最终复跑结果：Foundation Regression Gate `toc=186 activeLua=186 allLua=342 globals=0 presentation=0 rawNative=0 rawScope=0 detachedWidgetState=0`，Active Lua Parse `186/186`，本地 Harness `28/28`；RU Fresh Reload、真实 Native 页面构建/关闭/重开及字段验收仍未被本地门禁替代。

## M1.16.0.18.27 — Foundation Gate / BuffDisplay Schema Parity（2026-08-31）

- 修复 `rs_foundation_gate.lua` 仍以 schema 1 检查 `v3.buff_display` 的门禁漂移，使 Foundation Gate v51 与 BuffDisplay Store schema 2、Feature Acceptance 保持一致。
- 修复后重新执行 Foundation Audit `182/182 + 338/338` 与 24 个本地 Harness，全部通过；RU Fresh Reload 仍待验收。

## M1.16.0.18.26 — Detached Floating State / BuffDisplay Persistence Fence（2026-08-31）

- FloatingSurface 与 CreateStateAdapter 支持 detached getState + setState 提交回调；Surface/适配器的持久化失败路径会恢复旧 snapshot，避免 UI 适配器直接原地修改 Feature Store。
- Activity、Task、DPS、DeathReview、BuffDisplay、Healer 六个 Active Floating Widget 的状态写回统一经 Feature.Commands:SetWidgetWindowState()；Foundation Audit 新增 detached widget state 静态 fence。
- BuffDisplay Store 从 schema 1 升至 schema 2，复用完整 FloatingSurface:NormalizeState()，修复原 NormalizeRect() 丢失 locked/minimized/opacity/fontScale 的持久化缺陷。
- 新增 floating_surface_detached_state_test.lua 7/7；BuffDisplay Feature Harness 扩展为 12/12；最终 Foundation Audit 182/182 + 338/338，24 个本地 Harness 全部通过。

## M1.16.0.18.25 — Active Presentation Command Fence Follow-up（2026-08-31）

- 修复 Foundation/Gear HUD/Gear Snap Modal 直接调用 Feature 写方法的问题；Activity/Gear/Instance/Buff 刷新、显隐、尺寸、外观与 Snap 设置统一经 `Feature.Commands`。
- Gear QuickHud 增加 detached `GetQuickHudProjection()`，Widget 不再保留可写内部状态表；边界 Harness `34/34`、Foundation Audit `182/182 + 338/338`、23 个本地 Harness 全部通过。

## M1.16.0.18.24 — Presentation Private-Field Fence Follow-up（2026-08-31）

- 修复 Foundation 页面对 `Activities.StoreId`、`Gear.IndexStoreId`、`Activities.WidgetWindowSizePolicy` 的直接读取；持久化绑定改用稳定本地 Store ID，窗口策略改走公开 `GetWidgetWindowPolicy()`。
- Foundation Audit 新增 `S.Features.<Feature>.<private>` 形态的静态拦截；当前 Foundation Audit `182/182 + 338/338`、Presentation boundary `34/34`、23 个本地 Harness 全部通过。

## M1.16.0.18.23 — Feature Demand Quiesce Coverage（2026-08-31）

- Activity/Task/Instance/Raid Readiness 的 Feature Demand 增加下游资源 `quiesce` 清理，覆盖 Scheduler、事件、QuestProgress、InstanceCatalog、Roster 与 Aura；Runtime 强制静默成功后同步 implementation/runtime 的 disabled projection，并把 stale demand 记为 shutdown failure。新增 `feature_demand_quiesce_contract_test.lua` `22/22`，shutdown harness 更新为 `14/14`。
- QuestProgress/InstanceCatalog Service Demand 补齐 `quiesce`：停止事件、RefreshCoordinator、Scheduler，并释放 QuestProgress 持有的二级 InstanceCatalog lease；新增 `demand_service_quiesce_contract_test.lua` `9/9`。
- `FeatureRuntime:DisableAll()` 现在同时检查 runtime row 与 implementation-local enabled flag；即使两者失配也会执行 teardown，防止状态投影异常掩盖运行时资源。

## M1.16.0.18.22 — WidgetHost Callback Failure Fence（2026-08-31）

- `WidgetHost` 对 `preference/enabled` 生命周期回调建立逐绑定 `xpcall` 隔离；单个坏绑定不再中断同一事件的其它 Widget，并记录 `V3_WIDGET_LIFECYCLE_CALLBACK_FAILED`。新增 `widget_host_callback_fence_test.lua` `13/13`。

## M1.16.0.18.21 — PageHost Navigation Rollback Fence（2026-08-31）

- `PageHost:Navigate()` 检查 `OnRoute/OnDeactivated` 的显式拒绝；Switcher 拒绝或目标激活失败时恢复旧页面路由、上下文、可见页与激活生命周期，并以旧 route 作为恢复激活来源。新增真实加载 PageHost 源码的 `page_host_navigation_rollback_test.lua` `16/16`。

- `FeatureRuntime:DisableAll()` 聚合失败并暴露 `lastDisableAllFailures`；残留 Feature Demand 会进入 `ForceQuiesce`，即使强制清理成功也会保留 stale-demand failure 诊断，避免隐藏泄漏被报告为绿状态。真实加载 Runtime 源码的 shutdown harness 为 `12/12`。

## M1.16.0.18.19 — Presentation Boundary / Housing Read-only（2026-08-31）

- Active V3 Presentation 的内部字段访问已收紧：页面/悬浮组件不再读取 `Feature.Id`、`enabled`、`revision`、`projections`、`consumerCount`、Store ID、窗口策略或 Quick Button 策略字段；设置读取统一使用 detached `*Projection`，刷新/生命周期写入统一使用 `Feature.Commands`。
- Foundation Audit 新增 Presentation 内部字段、旧 Settings getter 和直接 Refresh getter 静态围栏；强化后的 `v3_presentation_boundary_test.lua` 为 `34/34`，防止“能解析但页面运行时越过 Feature 边界”的回归。
- 新增 `life.housing` V3 只读 Page / Feature / Authority：仅按页面 Consumer、按需调用已登记的四个零参数 `X2House` getter，统一输出 ready/partial/unavailable 投影，不执行住宅写操作、不后台轮询、不猜测住宅上下文数据。
- 住宅、随机商店与管家页已加入已迁移 Presentation 矩阵；最终 Foundation Audit 为 `TOC 182/182`、Active Lua `182/182`、全 Lua `338/338`，Unexpected global / Presentation escape / Raw Native / Raw BuildScope 均为 `0`。
- `tools.reinforce_analysis` 暂不伪装完成：官方 getter 已登记，但槽位参数、返回结构和客户端上下文仍缺 RU 真机证据，因此继续保持 `planned_verified` / Runtime Pending，不创建猜测型页面或强化写操作。
- 新增 `tools.random_shop` 只读 Feature/Authority/Page：仅读取官方刷新次数 getter；商店开启状态、条目列表和刷新动作没有被当前 API 证明，全部不推断。
- 新增 `life.butler` 只读 Feature/Authority/Page：仅读取官方 `GetChargeInfo()`，不接入管家装备、交互或其它写动作。
- 已迁移 Presentation 矩阵现在显式关联 `v3_quest_detail_modal` 与 `v3_gear_quick_settings_modal`；新增 Foundation Sequence `v3_39_modal_build_matrix`，实际构建两个 Modal，换装设置 Modal 额外执行 Open/Close 栈回归，任务详情 Modal 不伪造 RU 任务 key。
- 本轮最终本地门禁目标更新为 Foundation Audit `TOC 182/182`、Active Lua `182/182`、全 Lua `338/338`；Modal 运行序列与全部页面/悬浮窗序列仍需 RU Fresh Reload 实际执行。

## M1.16.0.18.18 follow-up — Local Foundation Re-audit（2026-08-31）

- 重新执行当前本地项目的 Foundation Regression Gate：`FOUNDATION_AUDIT PASS`，Active TOC `170/170`、Active Lua `170/170`、全 Lua `326/326`，Unexpected global / Presentation escape / Raw Native / Raw BuildScope 均为 `0`。
- UIV3Acceptance 升至 v25：已迁移页面路由必须存在专用 PageHost factory；具备悬浮窗的已迁移路由必须存在对应 WidgetHost spec，防止路由静默落入 planned fallback placeholder。
- 新增 Foundation Sequence `v3_37_migrated_page_build_matrix`：在 RU 客户端按矩阵实际调用 10 个已迁移 PageHost factory，并继续遍历 FeatureRegistry 当前 39 个 Active Route（planned 路由走 fallback）；同时对 7 个已迁移悬浮窗执行 WidgetHost `EnsureInstance`。构建失败、Generation quarantine 或可见性恢复失败都会直接成为序列失败。
- 新增 Foundation Sequence `v3_38_floating_policy_zero_defaults`，在客户端运行时直接验证 FloatingSurface 的透明度策略默认值与兼容 alias 能保留显式 `0`。
- 复核 RU 客户端日志发现 `core/rs_theme.lua:219` 的真实类型错误：字符串对齐值会直接传入 Native `SetAlign`。现在由 Theme 统一将 `left/center/right/top-left` 归一化为 RU 数值常量；新增 Theme alignment contract `4/4`。既有日志错误来自本次修复前运行，修复后的 Fresh Reload 仍待执行。
- 修复开发工具 `rs_foundation_audit.py` 对当前运行环境的编译器探测：优先使用 `texluac`，不可用时使用等价的 `luac`，不降低任何审计规则。
- 现有 13 个基础 Lua harness 加上本轮 5 个专项 harness，共 18 个本地 Lua harness 全部复跑通过；其中框架生命周期回归 `112/112`。RU Fresh Reload、逐路由真实 Native 构建与真实 Aura/团队字段仍必须在客户端完成。
- 新增 Persistence migration harness：覆盖空存档、N-1 schema 迁移、future schema 写保护、metadata mismatch 写保护、显式空表和 cyclic payload 拒绝，共 `12/12`。
- 修复 AuraObservationV3 与 HealerAuraBridge 在 Tooltip=nil 时的 Lua 5.1 fallback 截断：不再用包含 nil 的 `{primary, secondary}` 配合 `ipairs`，现在能正确保留 Data Row 的 stack/timeLeft/name/icon；Aura 共享服务与 Healer fallback 回归 `18/18`。
- Foundation Audit 新增同类 Lua 5.1 nil-unsafe fallback list 静态拦截，避免该类回归再次等到页面运行时才暴露。
- 修复公共 `FloatingSurface` 策略默认值对显式 `0` 的误判：透明度策略现在按“非 nil”选择 primary/alias，`0` 不再被 Lua `or` 当作缺失；新增本地策略契约回归 `6/6`。

## M1.16.0.18.18 — Foundation Regression Gate Hardening（2026-08-30）

- 新增开发态 `tools/rs_foundation_audit.py`：Active TOC/全 Lua Parse、bytecode `_ENV` 未声明全局、Presentation 全局/Native/私有边界、Raw Native constructor、Raw BuildScope、已知 Lua5.1 stable capture 一次性封包门禁；负向注入测试可正确拒绝新未定义全局。
- 审计实际发现并修复 `features/combat/healer/rs_healer_feature.lua` 的 `Recommendation()` 未定义全局，改为读取 Feature 持有的 `self.Recommendation`。
- RSUI 升 v24/API 10.9：BuildScope v3、BuildTransaction v1、Preflight v1、LogicalIdGenerationFence v1；close-order 违规会 fail-closed 回滚泄漏 descendant scope 并恢复活动栈；新增 transaction/preflight/close-recovery 指标。
- `PageHost v4 / WidgetHost v13 / ModalHost v5` 统一使用 `WithBuildScope()`；Widget 的 `windowingRequired` 在 Commit 前验证，避免半有效 Surface 被提交后再 quarantine。
- `RSUI:ValidateSpec()` 在 factory/native allocation 前拒绝 logical ID 重复与基础 spec 错误；一旦通过 preflight，logical ID 即标记为本 Generation consumed，rollback/release 后也不允许用相同 Native identity 重建；首批为 Table/TableView、SegmentedSelector、NumericField 增加专属 validator。
- FoundationGate 升 v50 / UIV3Acceptance v24；Fresh Generation 将 close-order recovery、preflight failure、transaction failure、page/widget quarantine 作为 Blocker。BuildTag `v3-m1.16.0.18.18-foundation-regression-gate`。


## M1.16.0.18.17 — Floating Stability / Analytics Recovery（2026-08-30）

- 修复战斗分析页面 `pairs(nil)`：Presentation 错误引用 Feature 私有 `VALUE_OPTIONS`，现改为 Feature detached `GetValueSelectorModels()`。
- 移除 DPS Widget 自建外观编辑器；所有 Floating 外观统一由 WindowShell 标题栏“外”入口管理。
- NumericInline 升 v3：窄 HUD 外观行优先保证 Slider 轨道，标签/精确输入收窄；WindowShell 升 v19 / titleAppearanceContract v3。
- Tasks / DeathReview Widget 补齐 fontScale parity。
- Appearance lazy build 增加同 Generation 失败闩锁，避免失败后重复创建保留 Native id。
- FoundationGate v49 / UIV3Acceptance v23；BuildTag `v3-m1.16.0.18.17-floating-stability-analytics-recovery`。


# 2026-08-30 · M1.16.0.18.16 — Floating Appearance Slider Layout

- 修复公共 Floating 标题栏“外观”面板在极窄 HUD 中 Slider 过短：根因不是业务窗口宽度，而是 `NumericField inline` 固定 44px label floor + 54px input floor，导致两字标签仍占过多空间。
- `NumericInlineContractVersion` 升至 v2，新增 `labelMinWidth / labelMaxShare / inputMinWidth / sliderMinWidth`，默认值保持普通页面历史布局；只有明确的紧凑 Consumer 才能缩小标签/输入下限。
- WindowShell 外观 4 行改为 26–30px 标签、44–48px 精确输入、至少 44px Slider，gap/padding 同步收紧；整体/背景/文字/字号仍共用同一 Binding/持久化 Authority，无新增 Store 或后台任务。
- WindowShell v18、FoundationGate v48、UIV3Acceptance v22；BuildTag `v3-m1.16.0.18.16-floating-appearance-slider-layout`。RU Fresh Reload 仍需确认极窄活动/DPS/Healer 悬浮窗中的 Native Slider 实际拖动宽度与命中。

# 2026-08-30 · M1.16.0.18.15 — Floating Chrome / Activity Responsive / Analytics Value Switch

- WindowShell v17 / FloatingSurface v9 新增统一标题栏外观入口：所有 FloatingSurface 默认显示轻量“外”按钮，整体/背景/文字透明度与局部字号使用 Slider + 精确输入；外观面板按需 lazy 构建，不在每个隐藏 HUD 初始化时预创建 4 组 NumericField，也不新增 Tick/Scheduler。锁定与重置布局一并收敛到该面板。
- Activity HUD 进一步压缩 title/footer/padding，并让 TableView 使用 overlay scrollbar；滚动时不再永久扣除右侧轨道宽度，三列使用 fill + 较低 absoluteMinWidth 随实际 viewport 重新求解，关闭用户列宽拖动，避免缩窄窗口后出现大块无用黑边或旧宽度残留。Activity 同时补齐 WidgetHost fontScale capability。
- Combat Analytics 将“击杀/助攻/死亡”等指标值从二级 Dropdown 改为直接 `SegmentedSelector`；点击即经 `Feature.Commands:SetSelectedValue` 更新唯一 Store Authority。Store 增加 metric/value 白名单校验，拒绝无效 key；新增 `v3_m16_18_15_analytics_value_switch_contract` Sequence Case。
- FoundationGate 升 v47，门禁 WindowShell title appearance、FloatingSurface appearance 与 DataView overlay scrollbar；UIV3Acceptance 升 v21。Active TOC / 全 Lua 与专项 Harness 需以本轮最终封版重跑结果为准；RU 仍需 Fresh Reload 验证实际标题栏层级、透明度预览、Activity 极窄窗口和战斗分析点击。

# 2026-08-30 · M1.16.0.18.14 — UX Interaction Polish / Floating Detail

- FloatingSurface / WindowShell 新增 compact-minimize contract：HUD 标题栏进一步收紧，最小化改为约 32×32 的恢复方块，而不是保留整窗宽度的长条；业务 Widget 继续只使用公共 WindowShell Chrome。
- RSUI 新增 opt-in `NumericField inline` / `UIV3Design:CompactNumericSetting()`：有限范围数值统一复用同一 Binding，按“名称 + Slider + 精确输入框”单行排列；Healer 主设置/显示设置/高级数值、DPS 悬浮外观以及其它有限范围设置开始采用该交互。
- Healer 主页面设置区改为紧凑 UniformGrid，并加入“治疗策略 / 战斗显示”切换，避免两大设置面同时挤占实时推荐区域；Raid Calibration 底色恢复 `artwork` layer 并提高可见 Alpha，保持零额外 Health/Aura 扫描。
- DeathReview 新增单条删除 Command/Store transaction：先事务删除 authoritative history index，再 best-effort 清理 record shard；页面增加“删除选中”，不再只能整批清空。
- Task / Activity 悬浮窗点击行时改用独立 `QuestDetailFloatingV3`；详情只读 `QuestProgressV3` projection，不再调用 `ModalHost:EnsureApplicationVisible()` 唤起主菜单，且不建立第二 Feature/Store Authority。
- 本轮全项目 Lua `326/326`、Active TOC `170/170`；DeathReview 删除事务 Harness PASS，UX contract 静态 Harness `11/11`。真实窗口尺寸、校准底色和 Slider 拖动仍需 ArcheRage RU Fresh Reload 实机验收。

# 2026-08-30 · M1.16.0.18.13 — Active Presentation Mutation Authority

- Active V3 Page/Widget 不再直接调用 Feature 的 Binding setter 或 `MarkStoreDirty`；DPS、DeathReview、Gear、Raid Readiness、Activity、Task、BuffDisplay 的展示写入统一经对应 `Feature.Commands`，保留 Domain/Store 的 Normalize、rollback、dirty 与生命周期语义。
- `v3_presentation_boundary_test.lua` 新增 Active mutation scan、Feature command facade 合同与 Acceptance guard，扩展至 `25/25`；所有 13 个本地 Harness `244/244`，全项目 Lua 解析 `325/325`，Active TOC `169/169`，Active V3 direct State/Authority `0`。
- 本里程碑只收口源码可证明的 Presentation→Feature mutation Authority；RU Fresh Reload、真实规则/设置保存回读、视觉交互与多人性能仍待实机验收。

# 2026-08-30 · M1.16.0.18.12 — Healer Command Authority Boundary

- Healer Active V3 Page/Widget 不再直接调用规则、Tracked Buff、颜色、视觉布局、Roster 刷新或 Store dirty mutation；这些写入统一进入 `v3.healer` 的 `Feature.Commands`，保留 Store Normalize/MarkDirty rollback 与生命周期 lease 语义。
- `rs_healer_aura_acceptance.lua` 新增 Commands facade 合同；Presentation boundary Harness 扩展至 `21/21`，并增加 Healer Page/Widget/Raid Overlay direct mutation 扫描。
- 更新 Healer Architecture 中 schema 3 与 Commands API 文档；本轮全量回归为 13 个本地 Harness `240/240`，全项目 Lua 解析 `325/325`，Active TOC `169/169`，Healer direct writes `0`。
- 本里程碑只收口代码层 Presentation→Feature mutation Authority；RU Fresh Reload、规则保存回读、长文本/下拉降级、Head/Raid 视觉与多人性能仍待实机验收。

# 2026-08-30 · M1.16.0.18.11 — Factory Reset / Aura Store Contract

- `Storage:BuildFactoryResetKeys()` 现在清除 Aura Library manifest 与 `a/b/c × 32` 固定分片空间；Suite-owned Store 仍从 `Persistence:GetPersistentKeys()` 自动纳入，专业模块继续由各自 Authority 提供 bounded key 集合。
- Factory Reset 完成后会清除旧代内存 dirty 状态、设置 one-shot generation fence，并 quiesce ModuleManager/Events/Scheduler，避免 UI reload 前把旧配置写回刚清空的存档。
- P0-1 `GetEffectIds` 重复定义已收口为单一 Authority：Alerts 省略 `scanLimit` 时完整扫描，Manager discovery/capture 继续使用 bounded rolling slice；新增 `.workbuddy/tmp/factory_reset_contract_test.lua` 覆盖两条 P0 契约，共 `13/13`。
- 改动后 13 个本地 Harness 合计 `237/237`，全项目 Lua 解析 `325/325`，Active TOC `169/169`，Active V3 direct State/Authority 与 UI false-show bypass 均为 `0`；RU Fresh Reload 仍待验收。

# 2026-08-30 · M1.16.0.18.10 — Active Presentation Authority Boundary

- 将 Gear、Instance Browser、Raid Readiness 的 Active V3 Page/Widget 从直接持有 `Feature.Authority` 收口到 Feature Projection getter 与 Commands；Gear 的方案/快捷按钮操作、Raid Readiness 的取消扫描都保留原有事务语义。
- Gear Feature 新增公开 Projection/Command 面，Instance/Raid Readiness 新增 rows/row/summary getter；Raid Readiness 的 Aura 释放由 `CancelScan` 统一处理，避免页面自行拆生命周期。
- Presentation boundary Harness 扩展至 `18/18`；改动后 12 个本地 Harness 合计 `224/224`，全项目 Lua 解析 `325/325`，Active TOC `169/169`，Active V3 direct State/Authority 均为 `0`。
- 本里程碑只处理 Active Presentation 对 Feature Authority 的源码边界；更深的 planned Feature、Plates 内部 concern 拆分，以及 RU Fresh Reload/真实视觉/多人证据仍继续保留在待办图中。

# 2026-08-30 · M1.16.0.18.9 — Activity/Task Projection Boundary

- Activity/Task Active V3 Page/Widget 不再直接持有 `Feature.Authority`；读取统一经过 Feature Projection getter，刷新、隐藏活动、恢复隐藏与展开任务统一经过 Feature Commands/Presentation command boundary。
- 保留刷新语义：Activity 页面手动刷新仍执行区域扫描，脏事件刷新只更新已有投影，避免把边界收口变成额外轮询；Task Widget 的显示行数 getter 与任务 projection getter 分离。
- Presentation boundary Harness 扩展至 `14/14`；改动后 12 个本地 Harness 合计 `220/220`，全项目 Lua 解析 `325/325`，Active TOC `169/169`。
- 该里程碑只收口 Activity/Task 可由源码证明的 Authority 越界；其它页面仍有成熟 Authority projection 直连待按业务域继续拆分，RU Fresh Reload 与真实运行证据仍单独验收。

# 2026-08-30 · M1.16.0.18.8 — V3 Presentation Read Models

- 收紧 Active V3 Page/Widget 的 Store 边界：Activity、Task、DeathReview、DPS、BuffDisplay 的窗口几何统一经 `GetWidgetWindowState()`，Activity/Task 的行数与显隐偏好经窄 getter，Task 页面作用域与 Gear 页面方案计数经公开 read model 获取。
- Activity/Task Floating Widget 的显隐持久化统一走 Feature Commands；native close/自动显示失败继续使用 Domain 提供的 reset command，不再由 Presentation 直接改写 `Feature.State`。
- 新增 `.workbuddy/tmp/v3_presentation_boundary_test.lua`，覆盖 18 个 Active V3 Page/Widget 文件的 direct `Feature.State` 禁止、read-model getter 和 Commands 合同，共 `12/12`；改动后 12 个本地 Harness 合计 `218/218`，全项目 Lua 解析 `325/325`，Active TOC `169/169`。
- 本里程碑仅收口当前源码可证明的 Presentation read-model 越界；Page/Widget 仍有部分成熟 Authority projection 调用待更深拆分，RU Fresh Reload、真实 Authority/视觉/多人证据仍单独验收。

# 2026-08-30 · M1.16.0.18.7 — Plates Concern Facades

- 将 Legacy Plates Storage 的只读诊断细化为 Persistence、Tracking、Aura Library 三个 concern 快照；保留原有扁平字段兼容，且所有快照都只读取内存，不调用 `Get()/Load()/Save()`。
- 将 Legacy Plates Manager 的只读诊断细化为 Catalog、Discovery、Capture、Aura Import Staging 四个 concern 快照；Discovery cursor 返回 detached copy，避免诊断调用者反向修改 Manager 会话状态。
- Runtime Diagnostics 新增 `storageConcerns` / `managerConcerns` producer，继续通过已有 Suite Diagnostics 链输出；不改变双 Bank / Shard 协议、Runtime lane、扫描频率或 Legacy 是否进入 Active TOC 的裁定。
- 新增 `.workbuddy/tmp/plates_concern_facade_test.lua`，覆盖 concern composition、无 Load/Save/Scan、cursor 隔离和 Runtime producer，共 `14/14`；本轮 11 个本地 Harness 合计 `206/206`，全项目 Lua 解析 `325/325`，Active TOC `169/169`。
- 更深的 Manager Tracking/Classification/Transfer/Presenter 与 Storage Model/Transaction engine 仍需在不改变成熟协议的前提下继续拆分；RU API/服务器/玩家数据依赖仍不虚构为完成。

# 2026-08-30 · M1.16.0.18.6 — V3 Visibility Authority Cleanup

- 收紧 V3 可见性清理边界：`RSUI:EndBuildScope()` 回滚、`UI:ReleaseOwner()`、重复注册拒绝和 Primitive degraded 隔离统一经过 `UI:SetVisible()` / `SetEnabled()` / `SetPickable()` Authority，不再把 Diff cache 的 `false`（无变化或拒绝）误当作允许原生直写的信号。
- `MarkPrimitiveDegraded()` 先完成统一 Authority 的 fail-closed 隔离，再设置 degraded 标记，避免 degraded 后续调用被状态门禁短路；保留构造阶段的原生初始写入，不扩大改动范围。
- 新增 `.workbuddy/tmp/ui_visibility_authority_test.lua`，覆盖 Owner Release、BuildScope rollback、重复注册拒绝与 degraded 隔离，共 `8/8`；本轮十个本地 Harness 合计 `192/192`，全项目 Lua 解析 `325/325`，Active TOC `169/169`。
- 该里程碑仍只代表代码层收口；RU Fresh Reload、真实 `v3_authority_clean`、页面视觉与多人验收继续单独记录，不把静态契约测试当作实机 PASS。

# 2026-08-30 · M1.16.0.18.5 — Plates GameData Semantic Relations

- 新增 `data/ids/rs_plates_ids.lua`，把 Legacy Plates 已有的 31 个重要冷却探测项、3 个魔法阵候选 Buff、目标护甲/武器状态集合与 22969 计时修正登记到共享 `GameDataRegistry`；全部保留 `curated / verified=false` 元数据，不把兼容 ID 伪装成数据库事实。
- `rp_runtime.lua`、`rp_api.lua`、`rp_storage.lua` 改为读取共享语义集合；移除对应的重复内联 ID Authority。冷却显示仍只读取实时 RU cooldown getter，目标装备仍在白名单未命中时返回未知，魔法阵 ID 仍列为 RU 实机验证项。
- 新增只读 `rp_storage:GetHealth()`、`rp_manager:GetHealth()` 与 Runtime `storage/manager/dataRelations` 诊断 Facade；Suite 诊断摘要现在能显示 Plates Schema、Tracking/Aura 分片、Dirty、write fence、目录/发现/捕获 staging 状态，不触发 LoadData/SaveData 或新的 RU 扫描。
- 新增 `.workbuddy/tmp/plates_game_data_contract_test.lua`，覆盖集合注册、计数、未验证元数据、Registry 完整性、三个 Legacy 消费端无重复内联表与 Manager/Storage Diagnostics Facade；`21/21` 通过。Professional Plates 仍不回接 Active V3 TOC。

# 2026-08-30 · M1.16.0.18.4 — Buff/Plates StatusMap Consumer

- 新增 `combat.buff_display` Active V3 Feature：`AuraObservationV3:GetStatusMap()` 是唯一 Aura 事实入口，Feature Demand 只在 Page/Widget 有 consumer 时持有 Aura lease；player/target 的 Buff、Debuff、Hidden projection 有 bounded row 与 `available/complete/reliable` 覆盖元数据。
- 新增 `v3.buff_display` Store、V3 状态显示 Page 与 Floating Widget；页面只调用 Feature Projection/Commands，Legacy Professional Plates Runtime 未重新接回 Active TOC。
- 新增 `v3_m16_18_4_buff_display_statusmap_contract` acceptance，覆盖 Registry/Store/Aura/Page/Widget/Demand 冷态合同与纯 Lua projection 排序/过滤。
- Diagnostics 快照/摘要与 FoundationGate 新增 BuffDisplay 健康、demand scope 和资源生命周期检查；`.workbuddy/tmp/buff_display_diagnostics_test.lua` `4/4` 验证冷态/启用态诊断投影。该里程碑当时 Active TOC `168/168`、全项目 Lua `324/324`；projection `4/4`、Feature lifecycle `8/8`，证明过滤/排序和 Enable→Acquire→StatusMap→Release 生命周期链通过。RU Fresh Reload、真实 Aura 字段/图标/时间与目标切换仍待验收。
- FoundationGate 升至 v45，新增 BuffDisplay StatusMap contract blocker 与 demand/resource scope warning。
- WindowShell 构建失败的早期隐藏清理统一改走 `UI:SetVisible(window, false, owner)`，不再在 RSUI Authority 外直接调用原生 `window:Show(false)`；新增 `window_shell_authority_test.lua` `5/5` 验证回滚、owner 与原生直写隔离。
- Legacy Plates residual audit 补齐 `SetIconPath` 的 texture-path Diff cache，并新增 `plates_ui_diff_contract_test.lua`；Lines/Circle active-range、Effect Slot geometry/color/visibility 与 `plates:*` owner contract 均由本地门禁锁定，Professional Plates 仍不回接 Active TOC。

## 2026-08-30 · M1.16.0.18.3 — Strict V3 Build Failure Fence
- RSUI BuildScope 为 Page/Widget/Modal/Main Shell 标记严格构建作用域；非 `buildOptional=true` 的组件创建失败会记录原始错误、拒绝成功 Commit，并沿既有逆序 Release/Detach/Hide 回滚。
- PageHost 与 WidgetHost 现在检查严格作用域的 Commit 结果并进入当前 Generation quarantine；ModalHost/Main Shell 同样不再把严格构建失败误报为成功。
- Form Field 的 Label/Validation/Toggle/NumericInput/Dropdown 关键构造失败立即向上返回具体错误，避免页面保留半成品字段后在激活/布局阶段才空指针。Healer 高级编辑器的文本框显式标记为可选降级能力。
- FoundationGate 升至 v44，增加严格 BuildScope contract 门禁。
- 新增 `.workbuddy/tmp/strict_build_scope_test.lua`：required failure、optional degradation、healthy commit 共 `6/6`；在 M1.16.0.18.3 当时 Active TOC `162/162`、Active Lua `162/162`、全项目 Lua `318/318` 通过。

## 2026-08-30 · M1.16.0.18.2 — Healer Advanced Editors / Native Cache Fence
- `v3.healer` Store 新增统一的 `SetRule` / `AddRule` / `RemoveRule`、`SetTrackedBuff` / `AddTrackedBuff` / `RemoveTrackedBuff`、`SetHealerColor` Command；所有输入仍通过同一份 NormalizeSettings，MarkDirty 失败会恢复完整 settings snapshot。
- Healer V3 Page 新增高级编辑工作区：完整 Healing Rule 字段、Tracked Buff 增删改与颜色、范围/低血/紧急三组颜色通道；页面不直接修改 `Feature.State`，不创建第二套 persistence authority。
- NativeImports 的 optional ImportObject 失败（包括 ADDON/ImportObject 不可用）现在都会进入当前 Generation 的负缓存；required 请求仍忽略 optional cache；Generation 变化会清理 imported/cache/failure 状态并重新探测。
- FoundationGate 升至 v43，增加 Rule/Tracked Buff/Color Command Authority 门禁。
- 本地验证：Healer Advanced Command + Native Cache Harness `18/18`；Active TOC `162/162` 文件存在且解析通过；全项目 Lua `318/318` 解析通过。RU Fresh Reload 与新编辑器实机保存回读仍待验收。

## 2026-08-30 · M1.16.0.18.1 — V3 Page / Foundation Recovery
- RU 实机确认多个页面同时失败并非 Healer/DeathReview/Analytics/Tasks 各自 Domain 故障，而是公共 `RSUI:TableView()` 构造链的同一错误：`NormalizeColumn()` 把当前参数 `column` 误写成只在后续 Lua5.1 延迟回调循环存在的 `columnRef`。这会让 TableView 在返回前抛错，随后页面激活才以 `recommendationTable/history/tableView=nil` 形式二次暴露。修复为 `align=column.align`，延迟表头回调仍保留稳定 `columnRef`。当前 9 个 V3 页面 + 5 个 Floating Widget 共 14 个 TableView Consumer 同时受益。
- 修复 Generic WindowShell 构建事务泄漏：`BeginBuildScope("window_shell:...")` 成功路径此前从未 `EndBuildScope(..., true)`；主 Shell 提交因此会遇到 close-order 冲突并留下 `activeBuildScopes=2`。成功路径现在显式 Commit，Windowing Attach 失败改走统一 Rollback。
- 收紧 Strict Native Authority：TableView 列分隔 Handle 与 Shared Scrollbar 的运行期显隐统一改走 `UI:SetVisible()`，不再直接 `widget:Show()` 绕过 Diff cache；此前实机 `v3_authority_clean[viol=3]` 必须在新 Generation 完整 Reload 后重新确认，旧计数不作为新代码结论。
- Native Foundation 与 FoundationGate 契约重新对齐：NativeImports v2 增加 Optional Object negative-cache contract；NativeObjectFactory v3 对 `CreateChildByObject` 强制检查 ImportObject 结果并 fail-closed；NativeCapabilities 同步提升门禁。
- Windowing / WindowShell / FloatingSurface 补齐 same-value 幂等契约；WidgetHost v12 的 Feature lifecycle bind 改为事务式，订阅失败会回滚 binding；Events v4 显式暴露 RU 缺少 Native UnregisterEvent 时的 parked/skipped/owner-release 语义。
- RSUI v23 / API 10.8 补 WrappedText v2 sizing 公共契约、DataView callback-capture contract；V3 Shell 暴露导航 Lua5.1 capture contract。FoundationGate 升 v42，不通过降低门禁掩盖实现漂移。
- 本地封版验证：Active TOC 162/162 文件存在且 162/162 Lua 解析通过；全项目 Lua 318/318 解析通过；TableView Normalize、Native Optional negative cache、Factory Import Fence、Widget lifecycle bind rollback、Events release、WrappedText v2 专项 Harness 全 PASS；关键延迟 callback 捕获变量 `columnRef/routeRef/handleDefinition` 前置误用扫描 0。RU Fresh Reload 仍需重新验收 Foundation blocker、Authority violation 与所有 V3 路由。


## 2026-08-30 · M1.16.0.18 — Healer Head Marker / Raid Overlay Visual Consumers
- 新增 `features/combat/healer/rs_healer_screen_projection.lua`：Feature-side Native screen-position 窄桥，只负责 unitToken→screen x/y/z；Presentation 不直接访问 X2Unit，也不把屏幕位置提升成共享 Service/业务事实。
- 新增 `presentation/v3/widgets/rs_v3_healer_head_marker.lua`：独立 `presentation:healer_head_marker` Demand；Marker pool 在视觉任务外预分配，50ms P4 task 只做屏幕投影与 Diff。Recommendation 文本/设置缓存移出 hot path，visual tick 不创建 Widget、不深拷贝 Store。
- 新增 `presentation/v3/widgets/rs_v3_healer_raid_overlay.lua`：独立 `presentation:healer_raid_overlay` Demand；预分配 4×25 slot/rank/calibration。静态效果纯事件驱动无 Scheduler，动态效果只建一个 100ms P4 alpha task；通过 Recommendation committed Health/Status 生成全团 display projection，恢复范围底色/低血/追踪状态显示，但不复制旧 Native Health/Status scan。
- Head/Raid dormant controller 与 active realtime listener 分离 EventBus owner；Stop 先事务 Release Demand，失败时保持旧显示层完整运行。FeatureRuntime 已先 clear Demand 的 shutdown 路径按幂等收敛处理 token missing，避免假故障/资源泄漏。
- `v3.healer` 升 schema 3，新增 `presentation.head/raid` 与 4 个 Raid section rect；对 schema2 已完成 legacy settings import 的老用户增加一次只读 visual recovery，恢复旧 Marker/Overlay 参数并用 `visualImported` 防止后续重复覆盖。Feature enabled 仍不进入 Healer Store。
- V3 Healer Page 新增 Head/Raid 启停、Marker 数量/形状/文字、Raid rank/字号/校准/布局重置等核心入口，全部复用 Feature Commands/Persistent Binding 单写事务。
- FoundationGate v41 / Acceptance 增加严格 visual lifecycle：Head disabled 必须 0 consumer/task；Raid static effectMode=1 必须 0 animation task，动态模式才要求 task。Feature metadata=`migration_active_visuals_m16_18`；完整 Healing Rule/颜色/Tracked Buff 高级编辑器仍未迁，不标 fully migrated。
- 封版验证：Active TOC 162/162 路径存在且 162/162 Lua 解析通过；全项目 Lua 318/318 解析通过；`HEALER_RAID_PROJECTION_HARNESS`、`HEALER_RAID_SLOT_HARNESS`、`HEALER_VISUAL_LIFECYCLE_HARNESS`、`HEALER_HEAD_HOTPATH_HARNESS`、`HEALER_STORE_SCHEMA3_HARNESS` 全部 PASS；Professional Healer / old workspace Active 引用继续为 0。
- 本里程碑已合并 M1.16.0.17.1 Windowing Bootstrap Hotfix：`LayoutHandles()` 同步八向 Handle 布局使用当前 `definition.key`，不会在覆盖 0.18 文件后重新引入 `handleDefinition` 启动阻断。

## M1.16.0.17.1 — Windowing Bootstrap Hotfix (2026-08-30)

- 修复 `RSUI.Windowing:LayoutHandles()` 把当前循环变量 `definition` 误写为只在后续回调安装循环中存在的 `handleDefinition`，导致默认 V3 Presentation Host 在 `SetResizeEnabled()` 初始化阶段直接报 `attempt to index global 'handleDefinition'`。
- 该修复属于 RSUI Windowing 底层，不在 Shell/Healer 做绕过；所有使用统一八向 Resize Handle 的 V3 顶层窗口共同受益。
- 保留 Lua 5.1 延迟闭包保护：只有安装 Native 延迟拖拽回调的循环继续使用稳定局部 `handleDefinition = definition`；同步布局循环直接使用自己的 `definition`。
- 该 Hotfix 已并入 M1.16.0.18 最终工作树。

## 2026-08-30 · M1.16.0.17 — Healer V3 Presentation / Floating Recommendation
- 新增 `presentation/v3/pages/rs_v3_healer_page.lua`：正式接管 `combat.healer` 路由，只消费 Healer Feature Projection/Commands；提供实时推荐表、成员评分/状态明细、核心阈值/扫描周期/职责评分设置，以及 Feature/团队刷新/悬浮窗入口。状态详情读取已提交 Domain Cache，不因 UI 选中额外触发 Native Aura 扫描。
- 新增 `presentation/v3/widgets/rs_v3_healer_widget.lua`：统一接入 `WidgetHost + FloatingSurface` 的治疗推荐悬浮窗；显隐持有独立 `widget:combat_healer` Consumer，Feature 停用后按幂等语义收敛 Demand，窗口关闭不创建第二套 Runtime。
- `v3.healer` 升 schema 2，仅增加不透明 `widgetWindow` Presentation 持久化块；新增 `GetWidgetWindowState()` 窄接口，Widget 不再直接访问 `Feature.State`。Persistent Setting Binding 使用 Domain-only setter，避免一次用户设置产生重复 `MarkDirty`。
- 修复 schema 2 的 legacy 首次导入兼容：旧 `replicated_healer_recommender_v2` 导入现在重新经过 `NormalizeState()`，不会在重建 `F.State` 时丢掉 `widgetWindow`；专项验证同时确认旧 `trackedBuffs=nil` 仍保持空列表语义。
- Recommendation 新增 `GetMemberProjection()`：返回候选/不可用/Health/Status 的深拷贝明细，按 source/id 稳定排序；Presentation 不读取 Recommendation 私有缓存。
- 页面热路径收敛：推荐发布只刷新实时卡片/表格，不重复 Render 设置控件；设置控件仅在页面激活或 `v3.healer.settings` 变化时重绘。推荐表默认投影前 50 名，悬浮窗显示前 12 名，不改变 Domain 全量统计。
- Head Marker / Raid Overlay **仍未迁移**，继续作为下一阶段独立 Presentation Consumer，禁止恢复旧 `ui/rs_healer_workspace.lua` 或 `modules/professional/healer` Active TOC。Feature metadata=`migration_active_presentation_m16_17`。FoundationGate v40。
- 封版验证：Active TOC 159/159 路径存在、159/159 Lua 解析通过；全项目 315 个 Lua 解析通过；Presentation Store/Projection、Widget 生命周期、设置热路径、legacy schema2 迁移三组专项 harness 全通过；Active TOC 中 Professional Healer/旧 Workspace 为 0。
- BuildTag=`v3-m1.16.0.17-healer-presentation`。

## 2026-08-30 · M1.16.0.16 — Healer V3 Domain Runtime
- 新增 `rs_healer_store.lua / rs_healer_roster_v3.lua / rs_healer_recommendation_v3.lua / rs_healer_health_v3.lua / rs_healer_feature.lua`：`combat_healer` 进入 Active FeatureRuntime，但不恢复 `modules/professional/healer` TOC。
- Roster 只投影 TeamRosterV3；职责评分开启时才读 `X2Team:GetRole`，5 秒刷新、每片 8 人。Health Runtime 只注册一个 Suite Scheduler 50ms P1 任务，Health 每片最多 20、Status 每片最多 8；每个 roster generation 先完整 Status，再发布首次 Recommendation；定向紧急状态刷新保留 health snapshot 跨帧续作。
- Recommendation 原样迁移旧 health/distance/missing/unprotected 评分、rule effect、role score、enter/exit/minHold 滞回与稳定排序，Shared Aura Service 不拥有治疗结论。
- `HealerAuraBridge v2` 增加 `ReadAccurate()`：完整可靠共享 StatusMap 直接使用，否则有界 Native fallback；fallback 发现 Aura 行却无法解析 effect id 时 fail closed，避免“未知”变成“无 Buff”。
- 新 `v3.healer` schema 1 只保存永久治疗策略，不保存 Feature enabled；首次空 V3 Store 可只读导入旧 primary/backup。修复 legacy `trackedBuffs=nil` 被 Lua `and/or` 错误替换为新默认的问题：旧用户保持空列表，新 V3 默认才提供 25875/220。
- Feature Demand 资源按 TeamRoster→Aura→Events→Health 获取、逆序释放。故障注入验证 Aura 启动失败与 Aura 停止失败都能事务回滚，不留下半启动/半关闭状态。
- FoundationGate v39 与 Healer acceptance 增加 Domain/runtime/slice/dormant 契约。验证：Active TOC 157/157 路径存在、157/157 Lua 解析通过；Recommendation/Aura/Health/Feature/Store/Demand Rollback 六组 harness 全通过。
- Presentation 尚未迁移，Feature metadata 使用 `migration_active_domain_m16_16`，避免占位页误报“已完成”。BuildTag=`v3-m1.16.0.16-healer-domain-runtime`。

## 2026-08-30 · M1.16.0.15 — Healer Aura Phase 12B Bridge / Migration Preparation
- 新增 `features/combat/healer/rs_healer_aura_bridge.lua`：Feature-owned、零 Tick 的 Aura Consumer bridge，只负责 Healer Lease 与共享 StatusMap 读取；默认 dormant，不会因为 addon 启动就扫描 Buff。
- Legacy Healer `rh_status_cache.lua` 统一入口改为 `AuraObservationV3:GetSnapshot()+GetStatusMap()` 优先。只有共享覆盖不是 `available+complete+reliable` 才回退历史直接 X2Unit 扫描，准确率优先，不把未知缺口当作状态缺失。
- `ReplicatedHealerModule:EnableRuntime/DisableRuntime` 增加 Aura Lease 事务：启用后续失败会释放；禁用先释放 Aura，Release 失败不会继续伪装成功关闭。运行诊断增加 shared accepted/fallback/error 与 bridge health。
- `combat_healer` 元数据升级为 `migration_prepared_m16_15 / legacy_detached`。本轮明确**不**把 `modules/professional/healer` 重新加入 Active TOC，也不把未完成 Healer 标成 V3 implemented。
- 新增非破坏性 Healer Aura acceptance；FoundationGate v38 增加 bridge/dormant scope 门禁。验证：Active TOC 152/152 路径存在、152/152 Lua loadfile 编译通过；Bridge lifecycle/read Harness 与 StatusCache shared→direct fallback Harness 通过。
- BuildTag=`v3-m1.16.0.15-healer-aura-phase12b-bridge`。

## 2026-08-30 · M1.16.0.14 — Raid Readiness / Aura Phase 12B First Consumer

- `AuraObservationV3 v2` 新增无 Native 读取的 `GetStatusMap(snapshot, options)`：规范化 effect id、stack、timeLeft、name、iconPath 与 Buff/Debuff/Hidden source mask；多个 lane 的同一 effect 合并为单一事实。
- 新增保守 `EvaluateRequiredEffects()`：缺失 effect 只有在请求 lane 全部可用、完整、可靠时才判 `ok=false`；覆盖不完整时返回 `ok=nil`，团队检查显示“待确认”而非伪失败。
- 新增 `combat_raid_readiness` V3 Feature/Store/Authority/Page：页面 Demand 只持有 TeamRoster；手动检查按 50ms one-shot 分片读取职责/装分/距离，关键 Buff 规则存在时每片只处理 1 名成员并临时 Acquire Aura，在完成/取消/离页释放。无 Tick、无常驻 Aura 扫描。
- `TeamRosterV3 v4` 修复 canonical identity 一致性：同一玩家先以 `player/0/0` 种子出现、随后又从真实团队槽位命中时，不再让 lookup map 与 ordered snapshot 指向两张不同 row；改为保留稳定 `player` unit token 并在原 row 上补齐 team/member slot，供职责读取与后续团队 Consumer 复用。
- 新 Store `v3.raid_readiness` schema 1 只保存偏好；结果 Session-only。关键 Buff ID 完全由用户/后续核验数据提供，默认空，不猜 RU ID。
- NativeContract 加入 `TEAM={id=38,nativeName=X2Team}`，由 FeatureRuntime 通过 `ApiDependencies={"TEAM"}` 懒导入；新增非破坏性 Acceptance 与 FoundationGate v37 的 Aura/Raid Readiness 门禁。
- FeatureRegistry 将“团队战备检查”从 planned 升为 `migrated_m16_14 / on_demand_scan`。BuildTag=`v3-m1.16.0.14-raid-readiness-aura-phase12b`。

## 2026-08-30 · M1.16.0.13 — Foundation Lifecycle / Lua5.1 Callback Cleanup

- 扩大 Lua5.1 delayed-callback 审计：TableView 表头、Windowing 八向 Resize Handle、V3 主导航均显式捕获 per-iteration local，消除泛型 for 变量被 Native 延迟回调共享的隐患。
- Events v4 在 RU 缺少原生 Unregister API 时使用 parked registration；Lua listener/Feature consumer 仍正常释放，不再把“客户端没有注销能力”计为业务失败。
- FloatingSurface/WindowShell setter 统一 same-value 幂等成功语义，减少重复 Store dirty / layout / style write；Native/Logical content root 命名进一步分权；活动旧 `widgetRows` 运行时回灌清理。
- FoundationGate v36 新增 Lua5.1 deferred callback contract。BuildTag=`v3-m1.16.0.13-foundation-contract-lifecycle-cleanup`。

## 2026-08-29 · M1.16.0.12 — Floating Activity Interaction / Adaptive Viewport

- 修复 Activities/Tasks Floating Widget 的 Native X 关闭潜在死锁：局部 `ReleaseWidgetConsumer()` 误引用未定义 `self`，会在持久化 `widgetVisible=false` 前抛错并让生命周期桥重新拉起窗口；两处统一捕获具体 `instance`，Feature 已停用时按幂等释放处理。
- FloatingSurface v6 / WindowShell v14 引入 HUD compact chrome profile：悬浮窗默认标题栏 28px、标题字号 12、控制按钮 26px、body padding 6、footer 24px；普通 WindowShell 仍保留历史默认值，不创建第二 Window Authority。
- Activities Floating 不再调用 `GetWidgetRows(widgetRows)` 预截断 Projection，改把 Authority 的完整有界 `GetRows()` 交给 TableView。DataView Viewport Contract v1 明确由实际 Arrange 高度计算 `visibleCapacity`，所以竖向拖动窗口会自动增加/减少可见行并继续使用虚拟化池；旧 `widgetRows` 存档字段保留兼容，但设置 UI 不再把它当显示上限。
- 修复“从悬浮活动点击行没有详情”：ModalHost v4 新增 `EnsureApplicationVisible()`，Floating→Modal 路径会先唤醒/显示 V3 主 Shell，再 Push QuestDetail；即使活动没有核验 Quest/Instance detail，也会在可见宿主上明确 Toast，而不是在隐藏 Shell 中静默失败。GearQuickSettings 同步迁移同一 Modal wake contract。
- DataView 新增 `GetVisibleCapacity()` 公共查询；FoundationGate v35 新增 `v3_floating_interaction_contract` 并提升 WindowShell/FloatingSurface/ModalHost 版本门禁。BuildTag=`v3-m1.16.0.12-floating-activity-interaction-hardening`。

## 2026-08-29 · M1.16.0.11 — DPS Sort / Skill Detail / Combat Analytics UX Hardening

- 修复 Active V3 Dropdown 在 Lua 5.1 下的 option-loop closure bug：每个 option callback 显式捕获对应 Button/Index，避免所有选项最终引用循环末项；`DropdownContractVersion=2` 并纳入 FoundationGate。
- DPS 页面排序升级：主 metric 使用直接可见 `SegmentedSelector`；友/敌排行表头开启交互，伤害/承伤/治疗列切换唯一 Feature metric，名称/DPS 走当前有界 Projection 的本地排序；TableView 第三态 `none` 解释为前一列 ascending，形成 `desc ↔ asc` 两态；摘要显示真实 `显示 n/total`。
- DPS Domain v6 保留经过 CombatFact 语义验证的 skill id：`spell_damage/heal` 可记录 raw skill id；`melee_damage` 的 raw `abilityId` 在 RU 事件中是 damage amount，因此故意显示“—”，禁止制造假技能 ID。玩家技能明细新增 Icon、技能 ID、数值、占比、次数。
- 新增 `SkillMetadataV3 v1`：共享、懒解析、有界 512 缓存，仅在 UI Drilldown 路径调用 `X2Skill:Info/GetSkillTooltip`；正/负结果都缓存，Combat Domain/Bus 热路径零 Native skill lookup。
- `CombatAnalyticsV3 v3` 新增有界 `GetMetricActorDetail()` Projection API；Feature 增加同名 Commands/Projection 边界。Analytics 页面改为玩家可理解的战斗行为工作区：说明每个分析项用途、ActionRunner 明确反馈、中文采集覆盖、空态原因、玩家 A/B 对比及技能/击杀/控制/演奏/辅助/Aura/机制 Drilldown。Presentation 不读取 Metric private state。
- FoundationGate v34 门禁 SkillMetadata v1、Analytics v3 Actor Drilldown、DPS Domain v6、Dropdown v2；RSUI v22。BuildTag=`v3-m1.16.0.11-dps-detail-analytics-ux-hardening`。

## 2026-08-29 · M1.16.0.10 — Floating Shell Layout Ownership / Local Appearance

- 修复 DPS 悬浮窗“首次显示标题消失、内容顶到窗口最上方，拖动一次后标题才恢复”的底层根因：WindowShell 的 `root` 是特殊 Chrome compositor，但后创建的业务子组件会触发 RSUI 通用 invalidation queue；通用 Overlay reflow 随后把 `bodyFrame` stretch 到整个 root（y=0），覆盖 titleBar，而拖动恰好再次执行 WindowShell 专用 `Layout()` 才恢复。WindowShell v13 现在将 root 标记 `autoRelayout=false`，并通过 `layoutHost` 把后代 Measure/Layout invalidation 合并回 Shell 专用 title/body/footer compositor；50ms one-shot 只在内容变化时合并重排，无 Tick。
- FloatingSurface v5 新增标准 `fontScale` 状态通道与 StateAdapter；WindowShell/RSUI 增加局部字体倍率传播。局部倍率继承到后续虚拟化子组件，Theme/TextLayout/Native Render 共用同一物理字号计算，防止全局 Typography Refresh 把悬浮窗局部字号覆盖回去。
- DPS 悬浮窗快捷栏新增紧凑“外观”入口，默认折叠以保持 HUD 清爽；展开后提供精确数值输入：背景透明度 `0–100%`、字体 `80–125%`。两项复用现有 `v3.dps.widgetWindow` 持久化状态，不新增 Store Schema/第二 Authority。
- WidgetHost v11 将 `fontScale` 纳入标准 appearance capability；RSUI v21/api 10.7 新增 `FloatingFontScaleContract v1`；FoundationGate v33 新增 `v3_floating_shell_appearance_contract`，并把 Floating Text Layout 门禁提升到 WindowShell>=13 / FloatingSurface>=5。BuildTag=`v3-m1.16.0.10-floating-shell-layout-appearance`。

## 2026-08-29 · M1.16.0.9 — DPS Floating Quick Filters / SegmentedSelector

- 新增 `RSUI:SegmentedSelector()`（Contract v1）：有界 one-of-many 紧凑选择器，复用 HorizontalBox + Button active state + Persistent Setting Binding；重复点击当前项为幂等成功，不重复写 Store；无 Tick/OnUpdate。
- DPS 悬浮窗新增一行紧凑快捷筛选：`PVE/PVP`、`友方/敌方`、`伤害/承伤/治疗`。三组控件直接绑定 DPS Feature 的唯一 settings Authority，因此与完整 DPS 页面双向同步、持久化一致，不创建 widget-only shadow state，也不会影响后台对所有 PVE/PVP/关系桶的持续累计。
- 悬浮摘要去除与快捷筛选重复的模式文字，改为总伤/承伤/治疗/单位数；Replay/未决技术信息默认折叠，仅存在可能影响排行的待确认数据时显示警告，释放正常战斗 HUD 的垂直空间。
- RSUI 升 v20/api 10.6；FoundationGate 升 v32，新增 `v3_compact_selector_contract`；DPS acceptance 增加 quick-filter framework 契约。BuildTag=`v3-m1.16.0.9-dps-floating-quick-filters`。

## 2026-08-29 — M1.16.0.8 Floating Content / Wrapped Text Hardening

- 修复 DPS 悬浮窗摘要文字重叠的两个底层根因：`FloatingSurface:GetContentRoot()` 过去返回 `WindowShell.body.root` Native 对象，导致业务创建的 `VerticalBox` 虽然物理挂到窗口里，却没有进入 RSUI `parentComponent/children` 逻辑树，因而 Shell Measure/Arrange 无法给它正确内容宽度；`FloatingSurface v4` 现在优先返回 WindowShell v12 的逻辑 `GetContentComponent()`，原生访问保留为显式 `GetNativeContentRoot()`。
- 修复 `Text overflow=wrap` 把 `TextLayout:Wrap()` 产生的换行字符串直接写入 ArcheAge `LABEL` 的错误假设。当前 RU API 的 LABEL 没有可靠多行/行距契约；RSUI v19 的 WrappedText Contract v1 改用 `EMPTY_WIDGET + 有界单行 LABEL 池` 渲染，每个 Native LABEL 永远只收到一行文本，默认最多 6 行、硬上限 8 行，无 Tick/OnUpdate。
- `ApplyOpacityChannels` 增加组件级 `ApplyTextOpacity` hook，使复合 WrappedText 的每条子 Label 继承文本透明度；字体缩放仍由 Theme/TextLayout 的统一物理字号契约驱动。
- 继续审计所有 Active `TextLayout:Wrap` 消费点后发现 Tooltip fallback 也把换行结果写入单个 LABEL；TooltipService v3 已改为复用同一个 WrappedText Composite，Active UI 中只剩 WrappedText 自身调用 `TextLayout:Wrap`。
- DPS 悬浮窗摘要/详情与 DeathReview 悬浮摘要从固定高度改为 `auto + minHeight`，在字体/内容换行时允许真实 DesiredHeight 增长；Table 继续使用 Fill 吃剩余空间。
- FoundationGate 升 v31，WindowShell 门禁>=12、FloatingSurface>=4，并新增 `v3_floating_text_layout_contract`（WrappedText/Shell/Floating/Tooltip 四方契约）。BuildTag=`v3-m1.16.0.8-floating-content-wrapped-text-hardening`。
- 本地验证：Active TOC 144/144 `texluac -p`；WrappedText Harness 验证 120px 宽长摘要被拆成 4 个单行 LABEL，任一 Native `SetText` 都不含 `\n`；静态确认 4 个 V3 Floating Widget 继续只经 `surface:GetContentRoot()` 进入统一逻辑内容树。

## 2026-08-29 — M1.16.0.7 RSUI Public API / Navigation / Form Layout Hardening

- 修复 DPS 实机 `rs_v3_dps_page.lua:247: attempt to call method 'TextInput' (a nil value)`：`TextInput` 类型已在 `rs_ui_controls.lua` 注册，但 Component Core 的手写公共工厂列表遗漏了该类型。RSUI v18 改为 `RegisterType/ReplaceType` 注册时自动安装 `RSUI:<Type>()` 公共工厂，后续新增类型不再依赖人工同步第二份名单；FoundationGate v30 新增 `v3_rsui_public_factory_contract`，逐项检查已注册类型的公开创建入口。
- 修复重复点击当前已选导航项被误报 `widget switcher rejected target page`：`WidgetSwitcher:SetActiveWidget()` 将“目标已激活”定义为幂等成功，`PageHost:Navigate()` 对 same-route/same-page 提前成功返回，不再停用/重启 Feature consumer，也不再产生 `V3_PAGE_SWITCH_FAILED/PAGE_NAVIGATION_FAILED`。
- 修复 NumericField 共用布局在 UI/字体缩放后底部提示文字被裁切：Theme 增加统一物理字号解析；TextLayout v3 按真实 Native 字号测量宽度/行高；Text Primitive 不再在 Render 阶段把字体回写为未缩放 base size。Form Layout Contract v2 用真实 label/feedback/hint 行高计算 DesiredHeight，Numeric/Toggle/DropdownField 与 FieldGroup 统一 Measure→Arrange。
- `UIV3Design v5 NumericSetting` 将历史固定 62px slot 自动迁为 `auto + minHeight`（除非显式 `allowFixedHeight=true`）；系统设置、悬浮组件设置、DPS、死亡回顾与换装快捷设置的外层固定高度同步改为可增长。Border Measure 补齐 min/max 宽高约束。字体或界面缩放变化只触发一次弱引用 typography component Measure invalidation，无常驻 Tick。
- FoundationGate v30 新增 `v3_typography_form_layout_contract`，同时门禁 Theme font resolver、TextLayout v3、Form Contract v2、WidgetSwitcher Contract v2 与 Design v5。BuildTag=`v3-m1.16.0.7-rsui-api-nav-form-layout-hardening`。
- 本地验证：Active TOC 144/144 `loadfile`；Active RSUI `RegisterType/ReplaceType` 49 个、冒号调用 557 处，静态解析无未定义公共入口；Public Factory、WidgetSwitcher 幂等、NumericField Form Layout Harness 均通过。表单 Harness 在 106%/110% 下 DesiredHeight=74px、125%/150% 下=93px，均大于历史 62px 固定容器并完整容纳 hint。


## 2026-08-29 — M1.16.0.6 UI Adapter / Selection Contract Repair

- 修复 M1.16.0.5 实机仍无法打开 DPS/战斗分析的真实原因：Active `rs_ui_native_primitives.lua` 没有 Legacy `TrySetUILayer`，而新版 Dropdown 在 popup 创建成功后直接调用该缺失方法。`TrySetUILayer` 已正式进入 Active Native Primitive Adapter，并在 Dropdown 侧再做 capability guard；RU Widget 不支持 `SetUILayer` 时仅跳过层级调用，不允许页面事务失败。
- DataView Selection Contract 升 v2：ListView / TileView / TableView 统一回调参数；新增 `View:GetSelectedKey()`；TableView 对外返回自身 View 而不是内部 ListView。ListView 程序化选择在同步通知前发布本地 index，修复虚拟池未绑定时的旧 index 观察。
- 修复死亡回顾 `GetPrimaryKey` nil：页面曾把 SelectionChanged 第 3 参数 View 误当 SelectionModel。死亡回顾、换装、副本、活动、任务全部改为只消费 `View:GetSelectedKey()`，消除 Presentation 对 SelectionModel 参数位置的耦合。
- 诊断“运行完整自检”只要成功返回报告即视为动作成功；报告中的 blocker/warning 通过结果 Toast 表示，不再生成误导性的 `ACTION_FAILED`。FoundationGate v29 新增 `v3_ui_adapter_selection_contract`。
- 验证：Active TOC 144/144 `loadfile`；Active UI 调用面静态审计仅剩两个非 S.UI 别名误报，无缺失 S.UI method；TrySetUILayer harness、List/Tile Selection View Contract harness、TableView Public View harness 均通过。BuildTag=`v3-m1.16.0.6-ui-adapter-selection-contract-repair`。


## 2026-08-29 — M1.16.0.5 Root Parent / Diagnostics Recovery
- 修复 M1.16.0.4 RU 实机中 `combat.analytics` / `combat.stats` 仍因 Dropdown popup 创建失败而打不开：根因是 NativeObjectFactory 只把 `nil` 归一成 `"UIParent"`，却会把 `UIParent` userdata/object 原样再次传给 `UIParent:CreateWidget()`；该 RU Build 的 root constructor 可靠接受的是字面量 root token。现在 factory 统一归一 `nil / UIParent object / "UIParent"`。
- Panel / EmptyWidget / Label / Button 顶层 Primitive 统一 root-parent 路径与提交后 fail-open；配置阶段异常标记 `rsUiDegraded` 并进入结构化 Diagnostics，避免 Native 已提交后上层收到 nil、再次构建撞 Physical ID。
- Dropdown 增加功能降级：popup、滚动按钮或 option pool 无法创建时，保留 trigger 并降级成 `↻` 单按钮循环选择；仍可读写 Binding/触发 onChanged，无常驻 Tick。
- PageHost 增加 route/deactivate/switch/activate 四类结构化错误；`UIX:SafeHandler` 的 Native 回调异常也写入 Diagnostics。FoundationGate v28 的复制摘要新增页面失败/隔离/Native失败/事务回滚统计，并附最近 4 条 warning/error 的 code 与关键错误上下文。
- 修复诊断页“运行完整自检”看起来无反应：ActionRunner 改为显式 Toast 成功/失败；Refresh 可直接消费本次 gate report，避免一次点击执行两次 FoundationGate。
- 本地验证：Active TOC 144/144 `loadfile`；root-parent normalization、Dropdown fail-open、诊断摘要 3 个 harness 全通过。BuildTag=`v3-m1.16.0.5-root-parent-diagnostics-recovery`。


## 2026-08-29 — M1.16.0.4 Native Build Transaction Hardening
- RSUI v17 新增同步 BuildScope 事务；失败时逆序 Release/Detach Component 并隐藏本次已提交 Native Widget，不尝试未验证的 DestroyWidget。
- PageHost v3 / WidgetHost v10 / WindowShell v11 / ModalHost v3 / Main Shell / NativeAdapter v3 增加 Generation quarantine，保留第一次真实错误并阻止同 Generation 重建同一 Native identity。
- PageHost 改按 Component identity 切换；Activities/Tasks/Gear/Instance/System 页面补 PageRoot fail-fast。
- Native Primitive 初始化失败改为 degraded 隔离；UI Write Fence 拒绝 degraded widget 后续写入。FoundationGate v27 新增构建事务门禁。
- Active TOC 144/144 `loadfile` 语法通过。BuildTag=`v3-m1.16.0.4-native-build-transaction-hardening`。


> **Authority Level**: CURRENT / GENERATED
> 倒序记录。里程碑级结论以 [`CURRENT_REBUILD_STATUS.md`](CURRENT_REBUILD_STATUS.md) 为准；详细审计见 `Archive/`。

## 2026-08-29 — M1.16.0.3 Native Dropdown / Combat Page Recovery

- 修复 `combat.analytics` 实机 `metric=nil` 与 `combat.stats` 后续 `root=nil`：Active V3 TOC 从未加载 Legacy `ui/components/rs_dropdown.lua`，但 `RSUI:Dropdown()` 仍依赖 `S.Dropdown:Create()`。标准 Dropdown 已改为直接复用 `NativeObjectFactory + UI Diff Authority`，不再需要 `S.Dropdown/CreateEmptyWindow`。
- Dropdown popup 继续物理 parent 到 `UIParent` 防止 ScrollBox/Card 裁剪；`UI:CreatePanel()` 增加可选 logical owner，在 Register 前写入 V3 owner，使 popup 与 option buttons 进入严格 V3 ID/Lifecycle Authority。列表行固定池上限 16；刷新保留 top anchor；滚轮/上下按钮按事件驱动；关闭/切页不留常驻 Tick。
- 新增 `RSUI.DropdownService` 弱引用管理：打开一个 Dropdown 会关闭其他 popup；PageHost 成功路由准备、Shell 关闭或最小化时统一关闭 transient Dropdown，避免 UIParent popup 脱离旧页面或主窗口继续显示。
- 修复严格 V3 logical ID 冲突：DPS/DeathReview 页面动作按钮改为 `v3_dps_widget_toggle` / `v3_death_review_widget_toggle`，FloatingSurface 根继续保持 `v3_dps_widget` / `v3_death_review_widget`。Active TOC literal V3 ID 静态扫描未再发现页面/悬浮窗重复。
- DPS、Combat Analytics、DeathReview 的 PageRoot/关键 Dropdown 增加 fail-fast 错误，底层控件失败时直接报告具体组件，不再继续执行到 `attempt to index ... nil` 的二次错误。Analytics 同步改用标准 `SetSelectedValue()`，删除对旧 `.dropdown` adapter 的探测。
- FoundationGate 升 v26：`combat_relation_contract` 从不存在的 `ResolveName` 检查纠正为 `CombatRelationV3 v4` 实际公开契约 `GetRelationAt(name, at)`；idle `consumer=0/units=0/rosterHeld=false` 不再被错误标成 Blocker。
- 验证：Active TOC 144/144 Lua `loadfile` 通过；Active 文件 0 个 `S.Dropdown/CreateEmptyWindow` 引用；Dropdown 纯 Lua Harness 覆盖创建、选择、滚动、Render、禁用、Release 全通过。BuildTag=`v3-m1.16.0.3-native-dropdown-combat-page-recovery`。

## 2026-08-29 — M1.16.0.2 Combat Page Activation / Navigation Repair

- 修复“伤害统计 / 战斗分析导航按钮点击无可见反馈”的页面激活链。`UIV3Design v4` 的 `PageRoot/ScrollablePageRoot` 现在同时接受字符串 id 与 spec table，战斗分析页的 `{id,padding,gap}` 组合不再绕过共享 Design Root 契约。
- DPS 页对 RU 可选 `X2_EDITBOX/EDITBOX` 改为 fail-open：首领名称输入框创建失败只禁用手动首领名称输入并显示降级提示，不再让整个 `combat.stats` Page Factory 异常退出。
- Shell 导航失败新增 Diagnostics `PAGE_NAVIGATION_FAILED` + 用户点击 Toast/状态栏反馈；页面创建/OnActivated 回滚不再表现为“按钮完全没反应”。
- 修复 `rs_v3_acceptance` 仍要求 `combat_stats=migrated_m15_3 / authority=v3.dps` 的过期契约，更新为 M1.16 shared Analytics authority。FoundationGate 升 v25，并增加 `v3_combat_navigation_contract`；新增 `v3_36_combat_page_navigation_contract` Sequence 真正打开 DPS/Analytics 页面再恢复。
- BuildTag=`v3-m1.16.0.2-combat-page-activation-repair`。

## 2026-08-29 — M1.16.0.1 Combat Analytics Lifecycle Hardening

- `CombatAnalyticsV3` 升 v2：空 Metric Consumer 不再允许占用 Demand；`AcquireConsumer({metrics={}})` 明确拒绝，`UpdateConsumer({metrics={}})` 对已持有 token 执行事务式 Release。公开指标全部关闭后，Combat Analytics Feature 因此真正释放自身 all-scope Lease；若 DPS 的隐藏 `dps_core` 仍启用，只保留 DPS 自己的独立 token。
- 新增公共 `HasConsumer` / `ResetMetrics` / `NotifyMetricChanged` 契约；Feature `ClearAll` 不再调用 Service 私有 `_SchedulePublish`，也不会通过全量 Reset 误清隐藏 `dps_core`。
- Metric Reset 纳入失败传播：Disable/Quiesce/批量清空遇到 `Reset=false/异常` 不再假成功；Demand reconcile 可据此回滚。FoundationGate 升 v24，并把 `emptyConsumers==0` 纳入 Analytics runtime health。
- 回归：纯 Lua Runtime Harness 验证空 Acquire 拒绝、non-empty→empty 释放 Bus、公开批量清空不触碰隐藏 Metric、Reset 失败向上传播。BuildTag=`v3-m1.16.0.1-combat-analytics-lifecycle-hardening`。

## 2026-08-29 — M1.16.0 Combat Analytics Foundation

- 新增 `CombatAnalyticsV3 v1` + Metric Registry：高级分析只持有一个 `CombatEventBusV3 v6 scope=all` Consumer，并按预编译 fact/native plan 分发；DPS 通过隐藏 `dps_core` Adapter 复用该入口，DeathReview 仍独立 self-scope。
- 新增 9 个可独立启停、有界 Session Metric：Encounter/History/Timeline、Kills/Assists/Deaths、Casts/Opener、Performance、Control、Songcraft、Utility、Aura、Boss Mechanics；新增 `CombatAbilityCatalog` 与 `CombatMechanicCatalog` O(1) 热路径索引。
- `Core Events v3` 增加 Optional Native Event 事务；Optional 注册失败只记录 degraded health，Required 失败仍不提交 listener；Required/Optional topic 属性由当前 listener 集合重算。
- 正确性收口：8 秒 Encounter gap 由事件+one-shot 双保险；START 无 STOP 时不计算伪演奏时长；inferred/native 同一施法起手合并证据；控制/Aura open interval 实时 Projection；Boss 机制优先记受影响目标；Utility UI 明确为“技能活动”而非未经证实的成功打断/驱散。
- 性能：MetricCommon v2 使用显式 `head/tail/count` 有界队列；高频队列禁止 `table.remove(1)`；5 秒爆发采用 100ms 时间桶并在 200-hit 压力下完整保留伤害；History 仅 20 场紧凑摘要。
- 验证：Active TOC 144/144 文件存在、144/144 Lua `loadfile` 通过；MetricCommon、Catalog、Metrics、Analytics single-consumer runtime、Events Optional transaction 与 M1.16 final-edge Harness 全通过。BuildTag=`v3-m1.16.0-combat-analytics-foundation`。

## 2026-08-29 — M1.15.7 Foundation Event / Scheduler Contract Hardening
- 完成 M1.15.6 后的底层专项审计，不扩展 DPS 业务。`Scheduler v3` 新增 transient task-module ownership；`RefreshCoordinator` 的递增 one-shot 名称显式标记为 transient，RemoveTask/RemoveOwner/Stop 会回收动态 `taskModules`，修复长时间运行下无界字符串元数据增长。静态 Module→Task 映射继续保留，兼容旧模块停启。
- `Events v2` 把 Native `RegisterEvent` 纳入 Subscribe/Start 事务：运行中注册失败时不提交 listener；启动阶段任一预注册失败会回滚已注册事件和 Handler，不再返回“订阅成功但客户端从未投事件”的假状态。新增 register/unregister/start/subscribe failure 健康指标并进入 FoundationGate。
- `CombatEventBusV3 v5` 的 borrowed+immutable Fence 从“主要语义字段”扩展到全部公开标量字段（raw payload 与 death notice 同步保护），避免前序 Consumer 篡改 `rawAbilityId/rawMore*/subjectName/rawNotice*` 污染后序 Consumer。`GetHealth().scope` 同时识别 Demand projection 的 `consumerOptions`，诊断不再把真实 all-scope 错报成 self。`ENTERED_WORLD` 订阅失败时 CombatBus 启动事务回滚。
- `TeamRosterV3 v3`、`CombatRelationV3 v4`、DPS relation replay subscription、QuestProgress/Activities/Tasks/Instance Browser 等 Active V3 链路全部检查 Event/Internal subscription 返回值；启动失败即回滚已持有 Lease/事件/任务，不再留下 `subscribed=true` 假状态。Gear Quick Widget 的两个 Native 装备事件也改为事务订阅。
- Runtime Foundation 三个周期任务安装改为事务式：Layout/Persistence/Observation 任一注册失败都会移除本轮已安装任务并让 Runtime 启动失败，避免“只启动了一半 Foundation”仍进入 Ready。FoundationGate 升 v22，增加 Scheduler 动态元数据、Core EventBus、TeamRoster/CombatRelation 契约与运行健康检查。
- 本地 Foundation Harness：5000 次动态 Scheduler/RefreshCoordinator one-shot 后 transient/module mapping 不增长；模拟 Native RegisterEvent 失败可验证 Start/Subscribe 回滚；模拟恶意 Combat Consumer 修改 raw/death 字段后后序 Consumer 仍收到原始事实。Active TOC 135/135 文件存在且 Lua 语法通过。BuildTag=`v3-m1.15.7-foundation-event-contract-hardening`。

## 2026-08-29 — M1.15.6 DPS Evidence / Replay / Observability Hardening
- 收紧 damage 阵营反推：只有 SELF/TEAM 可信锚能推导另一端为 OPPONENT；FRIENDLY/OPPONENT 不再递归给第三方 UNKNOWN 贴阵营，修复“敌方攻击中立 NPC → 中立 NPC 被写成友方承伤”的污染。heal 仍按同阵营事实推导。
- `CombatRelationV3 v3` 在 `RecordCombatFact` 应用证据后返回 `relationChanged`；DPS 将其并入 160ms Scheduler Replay 请求。旧待确认事实因此可在后续首击/关系证据建立时重新归类，而不是一直卡在 UNKNOWN。Manual Apply/Clear 的实际变化继续发布 relation updated。
- DPS Domain 升 v5：provisional/side-unknown contribution 可先显示数值，但最终归类前不提交 actor active clock。修复 PVE provisional 后搬到 PVP 时旧 PVE 活动时间无法回滚、长期把 DPS 压低的问题。detail 回滚同时删除零值 row 并归还 skill/counterpart capacity，避免反复 Replay 后虚假触发 128/256 上限。
- `CombatEventBusV3 v4` 把 UI/UIParent 跨 Host 去重从单槽改为每 Host FIFO token 1:1 配对：同 Host 连续相同多段攻击全部保留，两个 Host 的镜像按 multiplicity 精确抵消。token 使用 50ms TTL、256 上限与 backing-order 压缩；新增 pending/evicted 健康指标。Global SELF 过滤/private SELF slice 契约不变。
- `TeamRosterV3 v2` 增加冷启动韧性：瞬时 `UnitName("player")` 失败不再把上一份有效团队快照清空；最多 3 次约 450ms one-shot 重试，成功后取消。仍无 Tick、无 CombatFact 热路径团队扫描。
- DPS 页面新增“查看待确认”：可检查模式未定/阵营未定 actor、当前指标值和事件数；页面/悬浮状态同时暴露 Replay 淘汰、Bus 跨 Host pending/evicted、Relation 与 TeamRoster 健康指标，区分“真正漏事实”和“事实已保留但证据未决”。
- 手动 Boss 名 ASCII 匹配改为大小写不敏感；Store schema 3 不变，不制造无必要迁移。
- 新增/扩展回归：第三方 OPPONENT→neutral 不得制造友方、relationChanged Replay、provisional activity clock、detail Replay capacity、UI/UIParent 1:1 multiplicity/5000 对压缩、TeamRoster 快照保留/恢复。BuildTag=`v3-m1.15.6-dps-evidence-replay-hardening`。

## 2026-08-29 — M1.15.5 DPS Correctness / Replay / Detail Hardening
- 修复 DPS Domain 持有 borrowed CombatFact 的所有权违规：待重放账本只复制分类/显示所需标量字段，不保存共享事实对象；Replay Ledger 改为 active-count 上限 + stale-prefix 压缩，520 条未决压力下 active/slots 均保持 512 上限，溢出只计 `pendingEvicted`。
- 修复首击分类的 Lua 语义 Bug：旧 `sourceFriendly and targetKind or sourceKind` 在 `targetKind=nil` 时会回退到 `sourceKind=PLAYER`，导致 SELF/TEAM 攻击未知 Kind NPC 首击误进 PVP。改为显式 endpoint 分支；首击 provisional PVE 可立即显示，并在 NPC/PLAYER 证据到达后 Replay。
- 治疗从 PVE/PVP backing bucket 解耦为单一 Shared Heal Ledger。每笔 heal 只累计一次，但 PVE/PVP Projection 都能合并查看；切到 PVP 不再“治疗消失”，也不会因为双桶写入而双算。
- 新增有界 actor 明细：技能最多 128、目标/来源最多 256；明细 refs 绑定同一 contribution，重分类时和总榜一起回滚/搬迁。DPS 页面新增伤害/承伤/治疗排序，双排行点击单位展示技能与目标/来源明细；1024×768 下主工作区改为左右双排行 + 下方弹性明细，避免三块纵向等分后每表只剩一两行；悬浮窗沿用同一 Projection。
- `v3.dps` Store 升 schema 3，持久化 `metric` 并继续保留 FloatingSurface `widgetWindow`。修复设置 setter 只改内存不 MarkDirty 的路径：RSUI Persistent Binding 使用 Domain-only `ApplySettingFromBinding`，Command/API 使用 `SetSettingValue` 自己排队持久化并在失败时回滚。
- RSUI 新增共享 `TextInput`（EditBox + committed Binding + Draft→Submit + Enter/Blur/按钮提交/校验），DPS 恢复 Boss 名称输入添加；显示行数继续使用修复后的 NumericField 独立行，不与 Slider 命中区重叠。
- 统计生命周期与 Enabled 解耦：Disable/Quiesce 释放 Consumer/Relation/TeamRoster 与 Replay/Segment 临时态，但保留当前 Session 统计；显式 Clear 才清零。
- `CombatRelationV3` 的 bounded order 增加 stale-prefix 压缩，长期大型战斗不再仅移动 head 而无限累积数组槽。DPS actor key 同步遵循 UnitIdentity 跨服契约：两个明确不同 `Name@World` 不合并，宁可暂时保留短名歧义也不错误合并跨服玩家。
- Acceptance 增加 borrowed fact、512 Replay、首击 NPC、shared heal、metric projection、detail、Disable 保留统计、跨服同名不碰撞等回归。RU 实机仍需确认 all-scope Coverage、真实 Kind 命中率、团队 token 与物理 UI 布局。
- BuildTag 更新为 `v3-m1.15.5-dps-correctness-hardening`，使诊断页/实机日志能明确区分本轮封包与 M1.15.3/1.15.4。

## 2026-08-29 — M1.15.4 DPS Data / UI / Lifecycle Repair
- 修复 M1.15.3 首轮实机暴露的结构性漏数：DPS Domain 不再用“来源是否等于 actor”推导承伤，而是对每条事实分别写入 `source.damage`、`target.taken`、`source.heal`；PVP/PVE、友方/敌方分桶均以事件两端独立贡献累计。
- 新增有界 `unclassified` 保留桶 + 512 条 Replay Ledger：关系/Kind 暂未决时数据先保留而不是静默丢弃；关系或显式 Unit Kind 更新后由 Scheduler 安全点 `ReplayPending` 重分类/搬桶。超出 Ledger 上限只失去最旧事实的“未来重分类能力”，已累计数值不删除，并计 `pendingEvicted`。
- `CombatRelationV3 v2` 修复“建立敌对证据的首击仍返回旧 UNKNOWN 快照”；Unit Kind 与 Relation Authority 分离，NPC/MATE/SLAVE Kind 不再自动制造 OPPONENT；新增按需 `TeamRosterV3` 共享事实服务，使用 `X2Unit:UnitName` 在团队变更后 Scheduler 安全点扫描团队 token，无 Tick、无战斗回调扫描。
- `CombatEventBusV3` 在已验证 raw id→端点绑定后通过 `UnitIdentityV3` 缓存附加 `sourceKind/targetKind`；borrowed+immutable 恢复边界同步覆盖这两个字段，DPS 不再重复做 `GetUnitInfoById`。
- 修复 DPS Feature 调度错误：原代码调用不存在的 `Scheduler:ScheduleOnce`，实际会退化为每条 CombatFact 直接发布 UI 更新；改为真实 `Scheduler:AddOneShot` 400ms 合并 Projection 发布，证据重放使用 160ms one-shot。功能停用/Quiesce 同时释放 CombatRelation/TeamRoster 下游租约与运行统计缓存。
- 修复 `rs_dps_store.lua`：schema 升 2 并保留 `widgetWindow`，解决 FloatingSurface 因 Store Normalize 丢字段而无法打开；新安装悬浮视图默认 `friendly`，旧配置中的合法 `enemy/friendly` 原样迁移；Boss 名去重，删除事务失败可正确恢复旧列表，并消除 `RemoveBossName` 同名覆盖导致的递归。
- DPS 主页面改为同时展示“友方/自己”和“敌方/目标”两张完整排行，列包含伤害/DPS/承伤/治疗；`side` 设置明确只控制悬浮窗，避免用户输出因默认看敌方而表现为“没有数据”。新增覆盖、未归类保留、待重放/重分类状态。启停/悬浮窗/清空/首领删除统一 ActionRunner 反馈。
- DPS 悬浮窗扩大默认/最小尺寸，补齐伤害/DPS/承伤/治疗列，Show/Hide 改为事务式状态同步，并接入共享 `WidgetHost:BindFeatureLifecycle`；修复“逻辑 visible=true 但原生 Show 失败”的漂移。
- RSUI `NumericField` 收紧窄宽布局并把 hint 放到 control 下方；DPS“显示行数”不再塞入 38px 高行，修复 Slider 覆盖字体。
- 验证：修改 Lua 文件使用 LuaTeX `loadfile` 语法校验通过；DPS Domain 独立 Harness 覆盖 PVE 输出、PVP 双向伤害、incoming taken、治疗同侧推导、UNKNOWN 保留，全部通过。仍需 RU 实机确认 all-scope Coverage、TEAM token 布局与真实 CombatFact Kind 命中率。

## 2026-08-29 — M1.15.3 DPS V3 Migration
- `combat_stats`（伤害统计）正式迁入 FeatureRuntime，成为首个 `CombatEventBus scope=all` 业务 Consumer；只订阅 `scope=all`，不注册 `COMBAT_MSG`，不拥有原生战斗 Handler。
- 新增独立 `CombatRelationV3`（Relation / Combat Classification Domain）：只回答「单元是 SELF/TEAM/FRIENDLY/OPPONENT/UNKNOWN」，支持 MANUAL 最高优先、KIND_NPC/KIND_PLAYER 显式类型、Chinese-name 低置信提示（默认关闭）；不拥有身份/Aura/战斗事实/DPS 业务结论。
- `rs_dps_domain.lua`（纯业务 Domain）：PVP/PVE 按「事件来源 × 目标」逐事件分类（同一玩家可同时进 PVE 与 PVP 两张表）；环境伤害恒为 PVE；治疗只按关系决定 PVE/PVP 存储桶，绝不因上下文未决而丢弃/拆分/延迟；手动 Boss 标记可把无名目标判 PVE，但确认 PLAYER 证据仍优先；排行榜人数上限只截断 Projection，累积永不受限；Clear 只清统计，不停 Consumer。
- `rs_dps_store.lua`：`S.Persistence:RegisterV3Store` 只持久化设置与手动 Boss 名集合（Account / Permanent），不持久化运行总量；业务侧一律走 `S.Persistence`，不得直接 `LoadData/SaveData/ClearData`。
- `rs_v3_dps_widget.lua` / `rs_v3_dps_page.lua`：复用 FloatingSurface + WidgetHost + PageHost + ViewState/ActionRunner/Persistent Binding，沿用 DeathReview 的「Feature 生命周期桥」模式；覆盖不全时 `surface:SetStatus("覆盖不完整", "warn")`。RSUI 无 TextInput，Boss 名列表为只读 + 移除按钮。
- 战斗热路径零 Tick/OnUpdate：事实回调只做轻量 `OnCombatFact` + 节流 Projection 发布（400ms `Scheduler:ScheduleOnce`），无 SaveData/UI 创建/整单位扫描。
- 修复 `RecordCombatFact` pcall 误捕获：`pcall` 把 `(true, {table})` 包成 `(ok, true, table)`，旧写法只取 `ok, resolved` 会把成功分类误判为 identity-cold 漏归类；改为取 `ok, r1, r2` 并消费第 3 个返回值。
- 新增验收序列 `v3_m15_3_dps_contract`（meta status=`migrated_m15_3`、store `v3.dps`、Demand、Domain、Commands、relation、bus、page `combat.stats`、widget `combat.dps` featureId `combat_stats`、运行时 scope=all）+ `v3_m15_3_dps_classification`（逐事件 PVP/PVE、显示上限 vs 累积、Clear 不停 Consumer、UNKNOWN、scope=all 订阅）；`rs_v3_acceptance` 升 v19 加入 `dps_feature_contract` / `dps_presentation_contract`。
- Runtime Harness 新增 33 条 DPS 用例（relation+store+domain+feature 经真实总线派发）：全绿；全工程 Lua 语法 290/290、TOC 134 条 0 缺失、静态扫描（Domain→Presentation 边界 / Persistence 逃逸 / 常驻 Tick）通过。
- BuildTag 升为 `v3-m1.15.3-dps-v3-migration`；FoundationGate 升 v21 加入 `dps_v3_contract`(blocker) / `dps_v3_runtime_scope`(warning)。

## 2026-08-29 — M1.15.2H2 Framework Verification / Runtime Lifecycle Hardening
- `CombatEventBusV3 v3`：`_OnCombatRaw/_OnDeathNotice` 增加第二道 `running` 闸门。此前只有 Native 闭包检查 running/Generation，`ForceQuiesce` 之后内部入口（Journal 重放、停放 Host）仍可能把战斗事实派发给已被丢弃租约的 Consumer。
- `CombatEventBusV3 v3` 新增 `quiesce` 强制失活 `_MarkInert()`：Demand 走 ForceQuiesce 时，无论 Native 释放是否成功，总线立即置 `running/globalActive=false` 并清空 Journal/去重表；真实释放错误照常上报（`quiesceFailures`），不静默吞错。
- `CombatEventBusV3 v3` 明确区分两类释放结果并分别计数：`releaseApiMissing`（RU Build 根本不暴露 Release API → 隐藏停放，不算业务失败）与 `releaseCallFailures`（API 存在但调用返回 false/异常 → 真实事务失败并回滚）。新增 `stopFailures/forcedInert` 指标。
- `CombatEventBusV3 v3` 引入 scope 分发契约（新增 `AcceptsTransport()`）：`scope=self` 的 Consumer 只收 private 传输事实，`scope=all` 收 private+global。DPS 未来启用全局桥后，DeathReview 等低成本 Consumer 不再为 all-scope 行付代价；过滤量计 `scopeFiltered`。
- 战斗热路径诊断改为 `RateLimited`：`COMBAT_CONSUMER_CALLBACK_FAILED` / `COMBAT_FACT_MUTATED` 不再每条战斗行直接写日志（原本每秒可达数百行），计数器仍逐条精确。
- `DeathReview Authority v2`：常规 Debuff 采样移出 Native COMBAT_MSG 回调。回调只记录“需要采样”，真正的 Native Aura 读取经共享 Scheduler one-shot 执行（`debuffSampleMinIntervalMs=150` 节流不变）。Finalize 的强制 Aura 读取本来就在 Scheduler 上。新增 `debuffDeferred/debuffDeferFailures` 指标。
- `FloatingSurface v3`：Native X 关闭后同步 `surface.visible=false`，消除“原生窗口已隐藏但 Surface 仍认为可见”的状态漂移；新增 `surface:Close(reason)` 作为与 X 同一契约的编程关闭入口（fail-open，仅 `allowCloseVeto` 可拦截）；新增 `closeRequests/closeVetoes/closedCallbacks` 指标。
- `WidgetHost v9`：新增共享 Feature 生命周期桥 `BindFeatureLifecycle()` + `NotifyProjectionChanged()` + 走同一关闭契约的 `RequestClose()`。
- **移除 Domain → Presentation 边**：`FeatureRuntime v3` 在 Enable/Disable 后统一广播 `v3.feature.lifecycle`；Activities / Tasks / Gear 三个 Feature 不再直接调用 `WidgetHost:SetVisible`，改由各自悬浮窗在 Presentation 侧响应。Activities 新增 `v3.activities.widget_visibility` / `widget_projection`，Tasks 新增 `v3.tasks.widget_visibility`，Gear 新增 `v3.gear.quick.visibility`。三个 Feature 同时补齐 `F.Commands`（含 `ResetWidgetVisibility` 用于自动显示失败时回滚持久化偏好）。
- 修复 Activities / Tasks 悬浮窗“关闭功能后窗口卡在屏幕上”：这两个 Feature 的 `Disable()` 会先 `Demand:Clear()` 清空整条租约（含 `widget:activities` / `widget:tasks` token），随后隐藏窗口时 `ReleaseConsumer` 必然返回 `consumer not held`，`instance:Hide` 直接失败返回，`Host:SetVisible(false)` 提前返回且 `visible` 仍为 true。改为：Feature 已停用时视为“无 consumer 可释放”，隐藏流程不再被阻断。`OnWindowClosed` 同路径修复。
- 修复 `v3_m15_2h_death_review_widget_close` 验收用例恒失败：DeathReview 悬浮窗实例此前没有 `instance.shell`（Activity/Task 有），用例必然返回 `widget_instance_missing`。同时为它补齐 `ApplyLayout/SetSize/ApplyProjection`，使其参与统一响应式重排。
- 新增验收序列 `v3_33_floating_close_contract`、`v3_34_combat_event_bus_lifecycle_contract`、`v3_35_feature_presentation_boundary_contract`；死亡回顾关闭用例增加“surface/instance/host 三态一致”与“一次关闭只触发一次 onClosed”断言。FoundationGate v20 / UIV3Acceptance v18。
- BuildTag 升为 `v3-m1.15.2h2-runtime-lifecycle-hardening`。

## 2026-08-29 — M1.15.2H1 Floating Close / RU Release Compatibility
- `WindowShell v10` 把用户关闭改为 fail-open 默认契约：普通 `onClose` 返回 false 或回调异常不再让 X 失效；只有显式 `allowCloseVeto=true` 的特殊窗口才允许阻止关闭，并增加 `onClosed` 后置清理阶段。
- `FloatingSurface v2` 透传 `onClosed/allowCloseVeto`；`WidgetHost v8` 新增 `NotifyWindowClosed/RequestClose`，Native X 关闭后统一同步逻辑 visible 状态与业务清理，避免 Shell/Host 双向递归隐藏。
- DeathReview / Activities / Tasks 悬浮窗迁到新的关闭链；DeathReview 无记录状态移除 TableView 空态覆盖层，避免摘要/空态文案在窄窗口重叠。
- `CombatEventBusV3` 对 RU 缺少 `UnregisterEvent/ReleaseEventHandler` 的客户端改用 generation-local 隐藏停放兼容模式；若 API 存在但真实 Release 返回失败，仍保持 Demand 事务失败/回滚语义。Diagnostics 增加 Private/Global Park 指标。
- 新增 DeathReview WindowShell 关闭序列验收；FoundationGate v19 / UIV3Acceptance v17 提升 WindowShell>=10、FloatingSurface>=2、WidgetHost>=8。

## 2026-08-29 — M1.15.2H Framework Hardening
- `CombatEventBusV3 v2` 增加 256 条/1500ms Pre-Identity Journal：all-scope 身份冷启动不再静默丢行；Identity Ready 后重放，过期/溢出与单 Host 覆盖通过 `FULL/DEGRADED/IDENTITY_COLD/UNAVAILABLE/INACTIVE` CoverageState 明示。
- CombatFact 改为 borrowed+immutable 契约并使用稳定订阅顺序；错误 Consumer 修改关键字段会恢复并计 `factMutationErrors`，避免污染后续 Consumer，同时不为每个 Subscriber 深拷贝热路径对象。
- DeathReview 的 UNIT_DEAD_NOTICE callback 改为 capture + Scheduler one-shot；强制 Aura、记录构建、Record/Index 持久化与自动弹窗离开 Native callback。auto-show 移到 V3 Presentation；Page/Widget 改读 Feature Projection/Commands。
- `Demand v2` 反向创建顺序 shutdown；Consumer 投影改为副本；Clear 失败可走 `ForceQuiesce` best-effort 静默下游 Native/Service 资源，并诊断 quiesce failure。Aura/Combat Demand 均提供 quiesce。
- Persistence 新增 `ReadLegacy/ClearStore/CanWrite/IsStoreLoaded` 公共机械边界；Gear/DeathReview Store 不再直接 LoadData/ClearData 或修改 Store 内部状态。Feature preference 增加 write-fence preflight 与 MarkDirty 失败 lifecycle+intent 回滚。
- FoundationGate 升级 v18、UIV3Acceptance v16；Diagnostics 增加 Combat Coverage/Journal/FactMutation、Demand Quiesce 与 DeathReview Deferred Finalize 指标。

## 2026-08-29 — M1.15.2 DeathReview V3 Migration
- `combat_death_review` 正式迁入 FeatureRuntime，成为首个 CombatEventBus 业务 Consumer；只申请 `scope=self`，关闭后释放 Combat/Aura Consumer，不依赖 DPS，也不启用 all-scope 全局桥。
- 删除旧死亡回顾的私有 COMBAT_MSG Listener / Suite OnUpdate / Legacy Presenter 依赖；自身受伤由 Combat Fact 事件驱动记录，Debuff 通过 AuraObservationV3 按 150ms 最小间隔采样并在死亡时强制刷新。
- 新增 V3 死亡历史 Page 与 FloatingSurface 最近记录窗口，复用 ViewState / Selection / ActionRunner / Persistent Setting Binding；清空历史要求 5 秒内二次确认。
- 死亡历史改为轻量 Account Index + 31 个固定 Record Slot，最多 30 条被索引引用并保留一个事务备用槽；单条 96 Event/10 Debuff 记录独立有界保存，避免 RU SaveData 大聚合表截断。
- Demand 反向回滚不再清空死亡前临时证据；重复 UNIT_DEAD_NOTICE 在 1.2s 窗口内抑制；`maxHistory` 缩减使用显式 SaveStore 事务，写失败恢复索引与设置。
- 修复 CombatEventBus 跨 Host 去重 `pairSerial` 被重复递增的问题；FoundationGate 升级 v17、UIV3Acceptance 升级 v15，并加入 DeathReview 独立 Acceptance。

## 2026-08-29 — M1.15.1 Combat Foundation
- 完成 M1.15.0 战斗调用链审计；旧 Professional DPS/Healer/Plates/DeathReview 保留为迁移参考，不重新接入 Active TOC，也不在 Foundation 阶段改业务算法。
- 新增 `UnitIdentityV3`：raw COMBAT_MSG unit id 只有在 Native name 与 source/target 唯一匹配时才绑定；显式 kind 冲突 fail-closed；有界 cache、无后台扫描。
- 新增 `CombatEventBusV3`：私有 hidden Host 提供 `scope=self` 低成本切片；只有 `scope=all` Consumer 存在时才注册全局 UI/UIParent COMBAT_MSG 桥；最后 all Consumer 离开立即释放。
- UI/UIParent 去重限定为跨 Host 短窗口成对重复；同一 Host 的连续相同行不去重。Combat Fact 只标准化 damage/heal/miss/death/raw payload，不拥有敌我、PVP/PVE、排名或治疗推荐。
- Demand 负责 Combat Native Handler 启停与失败回滚；同 Generation 私有 Host 隐藏复用，避免重复物理 ID；无 Tick/OnUpdate。Diagnostics、FoundationGate v16、UIV3Acceptance v14 纳入 Combat Foundation Contract。

## 2026-08-28 — M1.14.5 V3 Foundation Adoption / Cleanup
- 不新增第二套框架，完成 Active V3 第一轮 Foundation Adoption：系统悬浮组件/全局设置统一走 Domain-only apply + Persistent Setting Binding，消除 Host/Feature 自存 + Binding 再存的双 Save Authority。
- `WidgetHost v7` / FloatingSurface StateAdapter 增加显式 `persist` 传播；旧公共调用默认仍 `persist=true`，Settings Binding 以 `persist=false` 只应用状态后统一 MarkDirty，兼容旧调用同时保持单 Authority。
- Activities/Tasks 浮窗与 Quest Detail 扩展 ViewState；Instance 筛选改用标准 `SetSelected()` 视觉；Activities/Tasks/系统悬浮组件/全局设置/诊断的可失败操作扩大采用 ActionRunner。
- `ViewState v2`、`Binding v2.3` 增加弱注册表实时 Snapshot；ViewState Registry 按 Runtime Generation 隔离，Diagnostics 汇总 Demand/Refresh/View/Action/Binding/Floating/ScreenSnap 健康状态，不新增 Tick/全树轮询。
- Activities/Tasks 的页面 Feature 开关补齐 Consumer Acquire 失败回滚，并删除 Disable 后对已由 Demand Clear 清理 token 的重复 Release，避免 ActionRunner 把半启动状态误报为成功。
- 安全清理 Active V3 中语义完全一致的重复 helper（Demand DeepCopy、Gear Trim）；不强行合并带过滤/几何/热路径差异的本地 helper。

## 2026-08-28 — M1.14.4 View / Action / Settings Foundation
- 新增 `RSUI.ViewState`：List/Tile/Table 统一 loading/ready/empty/error/unavailable/stale；首批迁移 Activities/Tasks/Instance。
- 新增 `S.ActionRunner`：同步用户操作统一 Busy、同 ID 重入保护、异常隔离、Diagnostics 与可选 Toast；按钮临时状态用 revision 防止覆盖业务新最终状态。
- `UI Binding v2.2` 新增 Persistent Setting Binding：Store write-fence 前置检查、Domain mutation + MarkDirty 边界、Commit/失败回滚；Gear 吸附开关/距离/间距首批迁移。
- Gear 的获取当前/保存方案/检查方案/立即换装首批进入 ActionRunner；DataView 自动 Empty 只在非显式状态下生效，不覆盖 Error/Unavailable。

## 2026-08-28 — M1.14.3 FloatingSurface / HUD Foundation
- 新增 `RSUI.FloatingSurface`：严格位于 `WindowShellV3 + Windowing` 之上，统一悬浮 HUD 的位置/尺寸/最小化/锁定/三路透明度与 Feature Store 持久化映射，不建立第二套 Window Authority。
- `WindowShell v9` 新增 `collapse` 最小化模式并在状态快照中保留 normal width/height；修复最小化后标题栏高度可能污染正常窗口尺寸的问题。
- `WidgetHost v6` 增加公共 minimizable/minimized 状态与 `SetMinimized`；未创建 Widget 通过 FloatingSurface StateAdapter 直接、安全地更新持久化配置。
- Activities/Tasks 悬浮窗首批迁移：删除业务私有 RootWindow/Windowing/Opacity/Geometry 胶水；关闭事务改为 Consumer Release 成功后再隐藏/退订，避免视觉假关闭。
- ScreenSnap 公共层修复禁用目标仍参与候选的问题；FloatingSurface 可选吸附只在 Drag Stop Commit，不在 Resize Stop 触发。
- FloatingSurface 注册表按 Runtime Generation 隔离，避免 Reload 复用上一代 Surface 实例。

## 2026-08-28 — M1.14.2 Shared Runtime Foundation
- 新增 `Demand / Consumer Lease`：统一 Consumer 引用计数、Options 更新与失败反向回滚；Activities / Tasks / Instance Browser / QuestProgressV3 / InstanceCatalogV3 已迁移。
- 新增 `RefreshCoordinator`：基于唯一 Scheduler 合并短时间事件刷新，Identity 为 owner+stable key，不再让 Service 各自复制 debounce one-shot。
- 新增 `AuraObservationV3` Phase 12A：Buff/Debuff/Hidden Buff 共享事实层；无后台扫描、短 TTL/有界 coverage cache、Effect ID 缺失时才做 Tooltip fallback。
- Runtime/Bootstrap 增加 Refresh/Demand Generation 清理；Diagnostics 与 V3 Acceptance 纳入三项新 Foundation Contract。
- 修正文档现状：当前 Active TOC 已为 V3-only Host；Legacy/Professional 源码保留为迁移参考。

## 2026-08-28 — Table 列拖动文字抖动修复
- 修正上一轮实时 Column Preview 的 Fill 反馈回路：拖动开始冻结 resolved widths，Preview 改为稳定的相邻列宽对，不再每 16ms 重新求解全部 Fill Column。
- Preview 宽度量化为整数逻辑像素，并缓存 Row GridLine 位置；未变化 Cell/GridLine 不再重复 Native Anchor/Extent 写入，显著降低 RU Native Label 在拖列时的重排/ellipsis 抖动。
- DragStop 一次性提交 Preview 中的两列最终宽度，避免 Commit 后再次 Fill 求解产生二次跳变；Sequence Contract 新增“无关列不随拖动改变、总列宽保持稳定”验证。

## 2026-08-28 — RSUI 交互修复：透明度通道 / Table 实时列拖动 / 自由最小尺寸
- `WidgetHost` 与通用 `WindowShell v3` 增加整体/背景/文字三路透明度；活动悬浮窗旧单一 `opacity` 自动迁移到 `overallOpacity`，视觉兼容不丢配置。
- `TableView` Header Separator 改为手势期间实时 Preview：约 16ms interactive lane 只重排 Header + 可见池化 Row + Separator；松手只提交一次，修复列宽“松手瞬变”。
- 活动悬浮窗开启公共列拖动能力；主窗口、活动悬浮窗、未来 `WindowShell v3` 默认最小尺寸统一降为 Native 1px 技术下限，不再用 Framework/Store/Caller 三层业务 Clamp 浪费空间。
- 新增 Sequence Contract 覆盖三路透明度、精确数值设置、活动页/活动悬浮窗列拖动能力与无隐藏窗口上限。
- 全量审计当前 V3 TOC 中所有拖动型组件：Window Resize、Slider、ScrollBar、SplitView、Table Column Resize 均采用“手势期实时 Preview + 最终 Commit”；Scheduler 不可用或拒绝任务时，专用拖动 Surface/Handle 临时接管 `OnUpdate`，松手立即释放。
- 修正 Table 列宽语义：`minWidth` 只作为自动布局/推荐最小值，`absoluteMinWidth` 才是用户手动拖动的硬下限；固定列不再被布局系统强行膨胀回 `minWidth`。
- 去除 `SplitView` 默认 120px/120px 隐式最小值与 `SettingsPage` 默认 360×280 隐式窗口下限；显式 Feature 业务约束仍保持有效。
- ScrollBar 默认 Thumb 技术最小值从 28px 收敛为 12px（硬底线 6px），避免小视口下拖块填满轨道而失去可拖动行程。

## 2026-08-28 — M1.14.1 Native Identity / UI Crash Guard
- 逻辑 ID 与原生 ID 严格分离（`S.PhysicalId()` 投影，物理 ID 预算 23 ASCII、含完整 Generation Hash）。
- `NativeObjectFactory v2` 成为唯一原生构造边界；Parent Fence 在 C++ 构造前；`UI Framework v7` 统一原生写入安全检查。
- 回归门新增 `FoundationGate v11` / `NativeCapabilities v2` / `NativeObjectFactory v2` / `UI Framework v7` / `UIV3Acceptance v6` / `v3_28_native_identity_contract` / `v3_29_native_parent_fence_contract`。
- 验收：进入世界后日志不再出现 `the widget with the same name already exists` 与 `AddAnchor() expect parameter` 类异常。

## 2026-08-27 — 重建蓝图 + Native 独立 + 静态 ID R2/R3/R4 + UI 信息架构
- 发布 `Rebuild/REBUILD_BLUEPRINT.md`（V3 重建方向总纲，M1.12）。
- M1.5 Native Foundation Independence 完成（Native Contract / Object Authority / ESC / Feature API Import / Foundation Gate / Build-time 审计）。
- 静态 ID 审计 R2→R3→R4：Trade Product ItemID 84/98 → 98/98（无编号规律推测，逐项 wiki 核验）；Quest 214/214；Instance DB Zone 19/19；Runtime Instance verified=0。
- UI 信息架构重构基线：统一 `UICatalog` 为唯一 Presentation Catalog；收敛重复入口；明确 Global/Feature/HUD/Module 设置职责；V3 路由未完成前保留 Legacy。

## 2026-08-26 — Foundation Decisions v2 + 底层框架批
- `FOUNDATION_DECISIONS_v2`：Mechanism/Policy 分离、Diagnostics P0、Game Data Registry、Persistence Lifetime、UI Diff、Runtime/Authority 约束。
- RSUI Phase 3–8 全量落地 + Foundation Graduation（Foundation Freeze）+ M6-v10 审计修复（dirty layout flush / LinearBox Fill / Inspector sibling overlap / Dashboard root coverage）。
- Healer 四阶段迁移（Domain Runtime / Domain Split / Glue Persistence / Roster API Gateway）+ Settings Architecture。
- Plates 架构审计 + Runtime Foundation（P0-1 Effect ID Scan / P0-2 Factory Reset Aura Library）+ UI Diff。
- `PERSISTENCE_FRAMEWORK_v1`、`RUNTIME_FRAME_BUDGET_v1`、`UI_FRAMEWORK_v1/v2`、`Core v1` 规范集定稿。

## 2026-08-24 — Hotfix 红龙巢穴/卡杜姆
- 入场判定由任务判定改为团队副本入场次数判定；同日晚补受管对话框“一条线”渲染修复。详见 `Archive/Hotfixes/`。

## 2026-08-15 — Architecture v1.1 一次性重构完成
- 新增 `rs_module_manager` / `rs_hud_manager` / `rs_api_capabilities` / `rs_module_sandbox` / `rs_observation` / `rs_settings_registry` / `rs_profiles` / `rs_favorites` / `rs_diagnostics` / `rs_migration`。
- 四专业模块迁入 `modules/professional/`，默认关闭、统一生命周期；左侧导航主 UI 替代旧四页签。
- Audits 3–6 深审通过；Hotfix Audit 5.1–5.3；Validation 报告齐备。静态验收：Suite Lua 107、toc.g 111、直接官方 API 引用 163/51、SetEllipsis 0。
- 发布白名单仅 `globals / replicatedsuite / z_api_functions`。

## 约定
- 加新条目：在顶部插入 `## YYYY-MM-DD — 标题`，并同步更新 `CURRENT_REBUILD_STATUS.md` 的里程碑表/下一步。
- 不要在此文件复述已被 `Archive/` 收纳的审计细节。
