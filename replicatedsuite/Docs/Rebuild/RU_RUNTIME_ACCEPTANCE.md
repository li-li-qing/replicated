## `.18.161` Unit Lines Full Numeric Slider / Card Hierarchy — RU 实机验收

BuildTag：`v3-m1.16.0.18.161-settings-numeric-slider-card-layout`。

1. 1280×768 打开单位连线：`显示哪些连线 / 全局显示 / 每条连线样式` 不再出现黄框套黄框；4 张 StyleCard 为 soft surface，宽度足够时 2 列。
2. 每张 StyleCard 的“密度”“点大小”必须各自显示完整 `Slider + 编辑框 + 应用`，不允许只剩 EditBox。
3. 点大小默认 Slider 最大值 10；在编辑框输入 20 并应用后，Slider 最大值应扩展到至少 20，Reload 后仍保留扩展范围；业务值不得超过 hard max 24。
4. 1024×768 若双列不足，应自动变成单列；不得压缩 Slider 到不可操作，也不得出现控件重叠。
5. Toggle 文本使用 `当前目标：开/关` 等 RU 字体安全文本；卡标题使用“自己 与 当前目标”等，不依赖缺失的箭头/勾叉 glyph。
6. `高级 / 诊断` 默认折叠；展开/关闭不得改变 Unit Lines Demand/Scheduler。

## `.18.160` Unit Lines Dense Settings Layout — RU 实机验收

目标：验证 `.159` 截图暴露的两个真实布局问题已关闭，而不是只验证组件创建成功。

1. 1280×768 打开“单位连线”：4 个连线开关必须是紧凑控件，不能再铺满两整列。
2. “全局显示”下方不应出现大面积无内容空白；“每条连线样式”应在当前 viewport 直接可见，或在最小宽度下通过一次正常滚动进入，不允许因单个超高 Section 被整项吸附而看似消失。
3. 每张 Style Card：密度与点大小同一紧凑行，使用精确编辑框+应用；卡内不再重复 Slider。全局显示保留 4 个 Slider。
4. 1024×768：Style Cards 可降为单列并正常滚动；不得控件重叠、截断或丢失应用按钮。
5. 1920×1080 / 2560×1440：Style Cards 保持 2 列，不应横向无限拉伸。
6. 高级/诊断默认折叠；展开后原始 projection error 仍可见。
7. Foundation 摘要要求页面失败/事务失败/ID 冲突均为 0。

BuildTag：`v3-m1.16.0.18.160-unit-lines-dense-settings-layout`。

## `.18.159` Unit Lines SettingsFoundation Consumer — RU 页面布局验收

1. **首个 Consumer 验收**：打开“战斗 → 单位连线”，页头应只有标题/状态、功能开关与刷新；四个连线开关为紧凑网格；“全局显示”“每条连线样式”“高级 / 诊断”层级清晰。不得再看到旧版四个巨型开关块与底部常驻大表格。
2. **1024×768 / 1280×768**：不允许 Slider、精确编辑框、应用按钮互相挤压或裁切；Style Card 可根据实际内容宽度从 2 列自动降 1 列。滚动页面可完整访问全部 4 张卡；不按具体分辨率写补偿。
3. **1920×1080 / 2560×1440**：有足够宽度时 Style Card 保持 2 列，不应拉成四个超宽整行卡；全局设置最多 2 列，视觉密度保持稳定。
4. **输入链保持原 Authority**：删除/修改 Numeric EditBox draft 后等待高频 visual refresh，文本不得被旧 Projection 回灌；点击“应用”后才提交 Feature Command。Slider、EditBox、Apply 与 `.18.156` Keyboard/Focus contract 同时复验。
5. **诊断默认折叠**：无目标或某端点 `unit_projection_unavailable` 时，主摘要只显示“等待目标/部分可用/投影不可用 + 见高级诊断”；展开后才看到 raw failure、尝试/可绘制/端点重合/投影失败与最多 5 行 facts Table。折叠/展开不能改变 UnitLines consumerCount 或高频视觉 Scheduler。
6. **业务行为不变**：四个 Toggle、全局透明度/刷新、每线密度/点大小/颜色修改后 Reload 保持；Unit Lines 头顶位置、刷新节拍、Demand 与 ScreenProjection 不应因为页面重排发生变化。

# Replicated Suite RU Runtime Acceptance Plan

## `.18.158` Settings Page Foundation — 本地门禁 / 下一轮 Unit Lines Consumer

1. `.18.158` 本轮只补底层，不以“单位连线页面已经变漂亮”作为通过条件；首个业务迁移留到下一轮。
2. `FormRow layout=auto`：宽容器保持 label/control 同行；窄容器自动竖排，label/control/hint 不得重叠。
3. 标准 NumericSetting 在窄宽度启用 responsive stack，Slider、exact EditBox、Apply 都必须保持可点击且不越界；Binding/保存链保持单 Authority。
4. DiagnosticsDisclosure 默认折叠，不得常驻占据主设置页面；展开/折叠只改变 Presentation state，不启动业务 Consumer。
5. 禁止新增 Tick/OnUpdate 或分辨率名单；响应式只根据当前 available width。下一轮迁移 `combat.unit_lines` 后再做 1024×768 / 1280×768 / 2K 页面实机验收。


状态：计划文件，不是实机通过证明。执行目标是 ArcheRage RU 中文客户端；每项结果必须在修改后重新 Fresh Reload 采集，不得沿用旧日志。

## 统一前置

1. 备份当前 addon 与用户配置；只加载 `replicatedsuite/`（单一 V3 Host）。`z_api_functions/` 仅作开发期 API 参考，**不进入运行时**；旧 `globals/` 与 Legacy UI/runtime 已于 2026-09-01/02 物理删除，不再随包，绝不重新引入。
2. 使用当前 `replicatedsuite/replicatedsuite.lua` 的 BuildTag 启动新客户端（见 `S.BuildTag`，当前为 `v3-m1.16.0.18.160-unit-lines-dense-settings-layout`），记录 `ArcheRage.log`、`Chat.log` 和崩溃文件。
3. 在 1024×768、1920×1080、2K 逐路由打开首页、战斗、生活、工具、系统页；记录页面/Widget/Modal 是否构建、文本裁切、列宽、黑边和关闭后资源释放。
4. 每次测试前后记录 Foundation：`activeBuildScopes`、page/widget quarantine、Authority violation、Presentation boundary、Raw Native、Unexpected Global 和 Scheduler active tasks。
5. 失败记录格式：时间、BuildTag、路由/动作、API 名、输入、原生返回值（脱敏）、日志错误码、是否可复现、恢复动作。
6. 封包前必须从 `replicatedsuite/` 工程根执行 Foundation Audit；其内部必须连带通过全 Presentation `RSUI_COMPONENT_API_AUDIT`、`PRESENTATION_FEATURE_API_AUDIT` 与 RSUI 顶层依赖 TOC 顺序检查；另执行 `rs_rsui_workspace_smoke_harness.py` 与 `rs_presentation_feature_api_audit_harness.py`，六类公共 Workspace 必须真实构建通过，Feature API auditor 的 valid/missing/guarded/NewFeature/bundle 五类 self-test 必须通过。Unit Lines / Front-Hemisphere 专项 Harness 必须支持从工程根直接运行，不得依赖调用者当前工作目录。

## 通用通过条件

- 只读功能在 API/字段未知时显示 `partial/unavailable/unknown`，不显示伪造的 0 或完成。
- 写操作只经 Feature Commands/API capability，尊重权限和至少 200ms 冷却；失败停止并显示结果，不继续盲发。
- 关闭页面/Feature 后无残留 Scheduler、Event、Demand lease 或隐藏窗口；重新打开能恢复投影和持久化设置。
- 所有 TableView/浮窗在三种分辨率可读，长中文/俄文/英文不重叠、不把数值列裁成省略号。


## `.18.157` Fresh Reload P0 — Resolution / Coordinate Matrix

1. **禁止分辨率补偿表式验收**：任何单一分辨率通过都不代表完成；本轮代码没有 `1280×768 +N` 之类表。先在 2560×1440 记录 Unit Lines/Range 诊断的 `Host=x,y / 视口 / UIScale`，再切 1280×768 对比。若 Host origin 改变，最终视觉仍必须保持头顶/脚下中心。
2. **世界视觉**：至少测试 1024×768、1280×720、1280×768、1280×800、1280×1024、1366×768、1440×1080、1600×900、1680×1050、1920×1080、1920×1200、2560×1440。Unit Lines 点大小 4/15 都不得改变端点；Range 点大小变化不得移动圆心/圆周几何。
3. **悬浮窗口跨分辨率**：在 2560×1440 将 DPS、死亡回顾、状态显示、活动/任务任意三个窗口分别拖到左上/中间/右下；切 1280×768 后窗口应保持相同屏幕区域意图，标题栏仍可拖动，不允许整窗丢到屏外。再切回 2560×1440，同 viewport 的已保存 exact logical 坐标应可稳定恢复。
4. **主 Shell 与 R 按钮**：主菜单自由拖动后切换 4:3/16:10/16:9，至少有顶部拖动区可达；R 不得跑出屏幕。下一次用户拖动后 Store 应携带 responsive placement metadata，但旧 `logical-free-v2` 不要求清档。
5. **Gear 快捷按钮**：把按钮拖到右下，依次切 1280×768、1920×1200、2560×1440；必须保持 RIGHT/BOTTOM 用户边距语义，不按旧绝对 x/y 漂移。
6. **Bag 快捷按钮**：打开银行/箱子，`取/放/停` 应继续跟随当前背包 Native 窗口，切分辨率后重新开窗口仍正确；它不保存物理像素，因此不应受旧分辨率位置污染。
7. **失败证据**：若任一世界视觉仍偏，把整条 Unit Lines/Range 功能诊断复制出来，必须包含 `Host`、`视口`、`UIScale`；若窗口/按钮跑位，记录原分辨率、目标分辨率、控件名、切换前后位置，不添加业务层 magic offset。

## `.18.151` Fresh Reload P0 — Death Review `770CB0B8` 单次迁移

1. **继续禁止 Reset/Clear**：直接覆盖 `.18.151`，保留当前真实 `770CB0B8>368335F2`。首轮目标 `integrityFail=0 / Fence=0`；Persistence 诊断应出现 `knownRecover>=1` 或 Store `known_legacy_canonical_recovery`，随后立即 `integrity_v4_upgrade` 重盖。
2. **A2 覆盖变化**：输出“存档验收”时 Store 总数应从 7 增至至少 8，并包含 `v3.death_review`。若 migration hook 被执行，A2 可出现 `DRProbe=.../knownStamp=770CB0B8/knownShape=ok`；若 shape 被拒，必须看到 `knownShape=reject:<reason>`，不要再依赖被主横幅截断的长错误。
3. **数据核对**：打开死亡回顾，核对历史条目数量/最新记录、windowMs/maxHistory/minDamage、窗口几何。对 Native 已不可逆省略且 exact old-hash solver 无法反演的缺失布尔，`.151` 不伪造旧值；迁移后请按当前 UI 明确设置一次并保存，之后 codec sentinel 必须稳定跨重载。
4. **第二次 Fresh Reload 是硬门**：必须 `verified_canonical`，`knownRecover` 不应再次增长；不得重复 `770CB0B8`，不得出现 `readbackVerifyFail/barrierFail/durableFail`。
5. **未知 Hash 仍 fail-closed**：任何不是 `770CB0B8` 的 v4 mismatch 不应进入 known-stamp bridge。若出现新 fingerprint，不扩白名单，先按新证据分析。

## `.18.150` Fresh Reload P0 — Death Review 历史 sequence/map 精确恢复

1. **禁止 Reset/Clear `v3.death_review`**：必须保留 `.149` 仍报 `770CB0B8>368335F2` 的真实 Store，直接覆盖 `.150` 后 Fresh Reload。页面 Build 事务在 `.149` 已全绿，本轮验收只看 Store：目标 `integrityFail=0 / Fence=0`，并保持 `页面失败0/隔离0/事务回滚0/事务失败0`。
2. **首轮允许一次 historical recovery**：若旧 `history.entries` 确实发生 sequence/map 表形漂移，首轮应出现一次 `historical_canonical_recovery`，旧历史摘要/两个业务开关/窗口状态全部保留，然后写成 `.149+` codec。不得通过清空历史来让 Hash 改变。
3. **第二轮必须普通验证**：再次 Fresh Reload 后 `v3.death_review` 应为 `verified_canonical`，不得重复 historical recovery，不得出现 `barrierFail/readbackVerifyFail/durableFail`。
4. **若仍 mismatch，复制完整错误**：`.150` 会在 `fingerprint_mismatch` 后附 `historical_probe=...`。必须原样复制其中 `histIpairs/histPairs/rawEntryKeys/winKeys/defaultTrueMissing/winRecoverable/bases`；该诊断不含死亡内容，可以直接用于下一轮精确定位。
5. **不要回头修改 UI**：只要页面构建计数继续为 0，就不得为 Death Review 页面增加绕过 Persistence 的 prepare/save 逻辑；Store Fence 是唯一当前 P0。

## `.18.149` Fresh Reload P0 — Death Review 真实旧档恢复 / Stable Codec

1. **禁止 Reset/Clear `v3.death_review`**：直接覆盖 `.18.149`，必须保留刚刚仍报 `770CB0B8>20692C15` 的真实 Store。首轮 Fresh Reload 允许一次 `historical_canonical_recovery`，但最终必须 `integrityFail=0 / Fence=0`；Death Review 页面随后应自然恢复，要求 `pageQ=0 / txFail=0 / 页面失败=0 / 事务回滚=0`。不要给页面绕过 Persistence prepare。
2. **业务设置保真**：进入死亡回顾设置核对“自动显示/显示 Debuff”等当前值，尤其是此前关闭过的开关不得在恢复后自行变回开启。修改两个开关各一次并保存，再 Reload，状态必须一致。
3. **Codec 重盖**：首轮恢复后允许 Store dirty reason `integrity_v4_upgrade` 并立即重盖当前 codec；第二次 Fresh Reload 必须进入普通 `verified_canonical`，不得再次出现同一个 `770CB0B8` historical recovery/fence。
4. **耐久回读**：两个默认真开关分别置 false 后触发一次正常 Flush/Reload；不得出现 `readback_fingerprint_mismatch`、`barrierFail`、`durableFail`。这条验证 numeric disabled sentinel 已消除 Native false omission。
5. **历史/窗口不丢**：旧死亡记录索引、窗口尺寸/位置/透明度继续保留。单条删除/清空历史仍走原事务，不允许因 codec 升级改变 31-slot record shard 结构。
6. **失败证据**：若仍 mismatch，复制完整 Store 行、`old>new fingerprint`、`lastIntegrityStatus/lastIntegrityError` 和当前两个业务开关状态；继续保留原 Store，不要清配置。

## `.18.147` Fresh Reload P0 — Death Review 历史盖章 / NumericRange 注册 / 2560 坐标

1. **禁止清 Death Review Store**：直接覆盖 `.18.147`，保留当前已经报 `770CB0B8>20692C15` 的 `v3.death_review`。第一次 Fresh Reload 目标是 `integrityFail=0 / Fence=0`；允许出现一次 `historical_canonical_recovery`/对应 `v3Upgrade` 后立即重盖。Death Review 设置、窗口状态、历史必须保留。第二次 Reload 应直接验证当前 canonical，不得再次走同一历史恢复。若候选不能精确复现旧 stamped fingerprint，系统仍应 fail-closed；禁止 Reset/Clear 伪造通过。
2. **NumericRange V3 注册**：诊断中不得再出现 `NUMERIC_RANGE_STORE_REGISTER_FAILED` 或 `STORE_REGISTER_INVALID:V3 store owner must use v3.* namespace`。打开范围辅助，把点大小 base 2..10 输入 `15` 后点“应用”，要求 Authority=15、Slider=2..15；Reload 后数值与展示端点仍保留。
3. **2560×1440 UIParent 坐标**：在 2560×1440 打开范围辅助，圆心必须钉在玩家屏幕中心/脚下投影锚点，不能随 `addonScale` 产生向右下或其它按比例放大的偏移；Unit Lines 两端必须落在真实 self/target/focus 屏幕位置。改变 Suite UI/Addon Scale 后，控件尺寸可以变化，但世界视觉的屏幕端点不得因为该 Scale 再次平移。
4. **分辨率矩阵**：在 1024×768、1280×768、1920×1080、2560×1440 至少抽测 Range 圆心与 Unit Lines；Range 原有 EasyPull Camera + player anchor rigid calibration 必须继续生效，不得用新的硬编码分辨率 offset 修补。
5. **交互回归**：TableView 列拖拽继续无双位置闪烁；Numeric“应用”后立即测试 WASD、技能和聊天输入，`.18.144` Focus Fence 不得回归。
6. **本地基线仅作门禁**：当前本地 `37/37 Python Harness PASS`、Foundation Audit PASS、TOC Lua `222/222` Parse PASS。**这些不能替代 RU 实机结论**；完成上述 Fresh Reload 后再更新 CURRENT 状态。


## `.18.129` 真实故障收口 Fresh Reload 专项（当前第一 P0）

1. **单位连线（.18.129d label 点模型）**：选中远距离目标应出现**一排清晰可见的彩色句点**（15px 起，≥8 个，`UnitLines:` 行 uniquePositions ≈ visibleDots）；制造一次渲染失败（切屏）后自动恢复。若仍不可见，此轮已排除点模型问题，剩余嫌疑集中在引擎宿主层级——`UnitLines:` 行必发。
2. **Boss 机制（黑龙 3 天一刷，改为三段式无 Boss 验证；RU 名称以 wbdebuff 数据为事实源，实机名称证据到位前不再盲改）**：
   ① **事实管道**：开启首领机制 → 打任意会读条的普通怪并选中 → `Boss:` 行 `ticks` 增长且 `casting=` 显示该怪的技能名、`seenCast=` 记录真实 RU 名称（这证明四 scope UnitCastingInfo 读取在实机可用）；身上随便中一个可显示 debuff 后 `debuff=/source=player_debuff` 应有反应。
   ② **规则→弹窗链路**：设置页点「仿真读条」→ 应弹出"大地强击"类倒计时；点「仿真Debuff」→ 弹"撞鬼"大字（两者走真实 BossCastIndex 匹配 + AlertsService 推送，与实况同一条管线）。
   ③ **真名对照**：`seenCast=` 累积到真实 RU 名称后与 wbdebuff 表（Сотрясение / Электрические разряды / Сбрасывание чешуи）比对；命中即完成验收，不命中把实机名称发回按证据修表。任何一次真实 Boss 战斗（不必是黑龙）都可完成这一步。
3. **治疗辅助**：开启校准不再触发 healer_v3_visual_lifecycle 失败（校准=previewHeld）；实况开启 head/raid running=true；格距与旧版一致。Reconcile 失败出现 HEAD/RAID_RECONCILE_FAILED 告警（不再静默）。
4. **Gear/Bonds 指纹**：Fresh Reload 后 v3Upgrade 增长、`integrityFail=0`、`Fence=0`；如仍有 mismatch，复制 Store 行的 `lastIntegrityDivergence`（第一个不同字段）。
5. **Gear 顺序**：获取当前 → 保存方案 → Reload 三步顺序全一致（旧序档由指纹桥迁移）。
6. **Trade**：快速 A→B→C / 1→2→3 最终落在 C→3；同路线在飞时点刷新显示排队状态而非无响应。
7. **HUD 布局**：展开 TransformInspector 后下一节顶边 ≥ 上一节底边+间距；1024×768 可滚动。
8. **整理背包**：仓库满格但有未满堆可继续放入；identity 异常跳过继续。
9. **Activity Tooltip**：悬浮说明跟随鼠标。

## `.18.128` 用户复现回归（历史）

1. **换装顺序 + 缺件继续**：同一方案连续执行 `获取当前 → 保存方案 → 获取当前 → 保存 → Reload`，槽位顺序必须稳定；再移走中间一件目标装备，只有该槽记为跳过，其余可证明候选继续换上。`ambiguous/read_error` 仍必须 fail-closed。
2. **`.18.152` Gear 快捷按钮 Fresh Reload**：准备至少 1 个 `quick=显示` 的已配置方案并确认快捷按钮全局可见；Fresh Reload 后**不要先进入换装页、不要手动换装**，按钮应直接出现。若历史 `v3.features.combat_gear=false`，本次允许一次 startup intent repair；随后诊断应显示一键换装工作中。再在功能管理器显式关闭 Gear、Reload，按钮必须继续保持关闭（证明 `runtimePreferenceLink=1` 后不会覆盖用户 disable）。
3. **`.18.162` 整理背包快捷按钮 Fresh Reload（P0）**：Fresh Reload 后不要先进入整理背包页，直接打开背包 + 银行，再单独测试背包 + 箱子；真实 transient WINDOW Host 上的 `取/放/停` 应在 ≤350ms 内出现并跟随背包，关闭仓储窗口后隐藏。窗口事实允许 boolean/0-1/string visible 与四返回值形态；显式 Native hidden 必须关闭，hidden Content proxy + 合法 MainScript geometry 必须仍判 visible（source 可为 `main-script-geometry-over-proxy`）。实际可见期间允许 350ms bounded Presenter retry，但仅打开窗口不得触发 InventorySnapshot 扫描/移动；只有显式点击 `取/放` 才允许建立有界 Move Queue。若用户在功能管理中显式关闭 `tools_bag`，Reload 后 overlay 必须保持关闭。
4. **`.18.154` Unit Lines 头顶中心锚点**：选中目标后分别测试默认点大小 4、较大点大小 10/15；线的首尾必须始终落在 player/target 原生头顶投影中心，改变点大小只改变 glyph 粗细/可见性，不得让整条线随字号向左上或右下漂移。至少在 1280×768 与一个 1080p/2K 分辨率验证；Range Assist 圆心/校准不得发生变化。
2. **治疗辅助真实团队结构**：单团 50 人必须呈现“上 1–25 / 下 26–50”，两个半区均 5×5，整体对齐约 340×400 原生名单。切原生“团队1/团队2”标签时 Auto Panel 必须跟随；启用额外友军团队 UI 后，用 A/B 同时对齐两个完整 50 人团队。Reload 后位置保持，`.18.127` 生成的 670×180 应自动迁回正确尺寸。
3. **Unit Lines + Range Assist 投影恢复**：连续切换 target/focus、360°转镜头、进出室内/副本；Camera Frame 短暂无效后两个功能必须能自行恢复点/线。Camera Frame 正常时背后目标仍应被 front-hemisphere fence 隐藏，禁止永久 Native-only 绕过。
4. **跑商快速切路线**：快速连续切起点 A→B→C 与终点 1→2→3，最终只能显示 C→3。请求期间不得并发发出不可区分的 Native ratio 请求；6.5s timeout 后可继续。若测试环境能观察到 timeout 后极晚旧回调，必须记录时间线，因为 Native 事件无 request-id，Lua 无法完全归因。
5. **债券日快照/去重**：当天首次进入某大陆后记录读取；Reload、切筛选、改排序不应再次读取该大陆居民板。切到当天尚未采集的另一大陆允许读一次。验证西/东“皮革20”只保留优先大陆且完成状态共享，但皮革20/60/100必须仍为三项。跨服务器日期后快照应失效并重新采集。
6. **整理背包 UX + 满仓继续**：鼠标分别悬停 `取/放/停`，应在指针附近显示准确说明。仓库无空槽但 B 物品存在未满同类堆时，A 无法放入只能局部跳过，B 必须继续堆叠；Native 读失败/identity 不可证明仍全局停止。
7. **活动悬浮 Tooltip**：第一列、最后一列以及窗口边缘的活动行分别悬停，说明框应跟随真实鼠标并做屏幕边界约束，不得再跑到左侧远处。
8. **首领机制**：开启 Boss 模块与 HUD，选择一个 Catalog 中有规则的真实 Boss；记录目标开始施法时的本地化技能名、警报是否在施法开始阶段出现、自身获得规则 Debuff 时是否触发。关闭 HUD/Feature 后 Casting/Aura Demand 与 Boss Scheduler 必须释放。若不触发，保存 `CastingObservationV3` / Aura / Boss health 证据，不用聊天字符串兜底。
9. **状态显示 HUD Inspector**：进入 `状态显示 → HUD布局`，依次选 Buff、Debuff、职业、装备等元素；右侧 Transform/Anchor/吸附设置必须按真实 Measure 向下布局，不能再出现控件互相覆盖。Compact Drawer、滚动、Apply/Reload 均需验证。
10. **门禁**：Fresh Reload 记录 Foundation v119 / UIV3 Acceptance v74；当前本地基线为 Active/All Lua 221/221 Parse PASS、Foundation Audit PASS、30/30 Python Harness PASS。


4. **`.18.163` 跑商预计售价实售校准（P0）**：保持“货率：实时 / 熟练：计入”，记录当前经商熟练度，至少选择普通、新鲜/特供、发酵/larder 各 1 个货物，对比插件 `预计售价` 与 NPC 实际出售值；详情悬浮窗必须显示 `熟练×N / 品类×N`。若熟练度 API 不可读，预计售价必须为 `--` 而不能退回少乘熟练倍率的数字。再切“熟练：忽略”确认仅去除熟练倍率、品类倍率仍保留；切“满130%”只改变货率因子。
## `.18.126` Range Assist Global Projection Fresh Reload 专项（历史；范围辅助当前验收走 `.18.129` §1 与 `.18.129d` label 点模型）

1. **圆心/世界空间**：打开 战斗→范围辅助，保持自身移动并依次朝东/西/南/北方向转动相机。范围圆必须持续以自身脚下/角色位置为中心，不得随镜头方向产生固定偏移或漂移。重点对比非 1.0 UI scale。
2. **360° 相机 + 稠密索引**：缓慢旋转相机 360°。圆周位于相机背后的采样点可以隐藏，但后续重新进入前半球的点必须继续显示；不得因为第一个不可见点导致整圆消失或只剩固定短弧。正常视角至少应有 3 个可见点。
3. **分辨率矩阵**：分别在 1024×768、1920×1080、2K 验证半径、点大小、透明度、颜色以及 Apply/Reload；视觉圆心与半径变化方向应一致。
4. **生命周期/诊断**：打开 Range Assist 时才允许存在其 200ms Demand task；关闭页面 Consumer/Feature 后对应任务必须释放。若投影不足，记录 `ScreenProjectionV3:GetHealth()` 与页面 `partial/unavailable` 原因，不允许回退到 local-space 或稀疏 batch。

## `.18.125` Integrity v3 Canonical Fresh Reload 专项（历史；Integrity 部分已被 .18.129a 的 v4 契约取代——以最新横幅 `integrity=4` 与 v3Upgrade 计数为准）

1. **禁止清 `v3.tasks` / `v3.death_review`**：直接覆盖 `.18.125` 后 Fresh Reload。旧 v2 档应出现一次 `v3Upgrade>=1/1`（`integrity_upgrade_recovery` → `integrity_v3_upgrade` 重盖）且 `integrityFail=0 / Fence=0`；第二次 Reload 起应为 `verified_canonical`，不再重复 upgrade recovery。诊断页 Store 行可复制 `完整性 verified_canonical`。
2. **默认恢复范围（2026-09-05 第二份横幅后翻转）**：所有 v2 旧档 mismatch（含 bonds / gear.payload / death_review.record 分片）都应出现一次 `v3Upgrade` 增长并恢复，第二次 Reload 起为 `verified_canonical`；只有显式 `allowIntegrityUpgrade=false` 的 Store 才保持 fail-closed。真实内容损坏（decode/budget/schema 不过）在任何策略下都继续 `STORE_INTEGRITY_FAILED`。
3. **Unit Lines**：连续快速切换目标/焦点并穿插清空目标。`UnitLines:` 诊断行 `aliasKept/aliasReject` 允许增长；注入性验证：制造 3 次调度回调异常后任务应于 2–4s 自动恢复（`GetHealth().faultResumes` 增长），不再需要 reloadui。
4. **Buff 装备证据优先**：开启功能后复制 `BuffGear:` 行。`icons>0`：验证 Self HUD 四开关；`errors>0`：按 lastError 收敛；`itemKeys=...`：说明 RU tooltip 无已知 icon 字段，按样本键名修复（下一轮）。`unresolvedSlots>0` 即 `ES_BACKPACK` 缺失，背部保持 unavailable，不猜 slot。

## `.18.124` RU Hotfix Fresh Reload 专项（历史，被 .18.125 覆盖的 Integrity 部分以 .18.125 为准）

1. **禁止清 `v3.tasks`**：直接覆盖 `.18.124` 后 Fresh Reload。旧 Store 若正是本轮已证明的 tracking-map serializer shape mismatch，可看到 `shapeRepair>=1`，随后 `shapeResave>=1`；必须同时满足 `integrityFail=0 / Fence=0`。再次 Reload 后不应为同一个 Store重复 shape repair。
2. **Service Boundary**：复制 Foundation 诊断，`service_presentation_boundary` 必须通过，不能再出现 `AuctionSurfaceV3:missing` 或 `CraftSurfaceV3:missing`。随后分别打开拍卖行/制作窗口，Sidecar 仍只在原生窗存在时按既有生命周期显示。
3. **Unit Lines World Alias**：打开 self↔target 连线，连续快速选择多个玩家/NPC并穿插清空目标，至少复现原来“只剩自身一个点”的切换节奏。线端点不得再被压到自身；若 RU 提供 stale world fact，`ScreenProjectionV3:GetHealth().worldAliasGuards` 应增长。相机背后目标仍必须隐藏，不能用 alias guard 绕过 front-hemisphere fence。
4. **Buff Display 自身装备**：进入 `状态显示 → HUD 布局`，无需先在树里找元素即可看到 `主手/副手/远程/背部` 四开关。开启主手/副手/远程→Apply，自己的对应图标应出现；换武器后应在事件刷新或 1000ms drift backstop 内更新。关闭→Apply 后图标消失，Reload 后开关保持。
5. **背部 Slot 不猜测**：如果本 RU 客户端导出 `ES_BACKPACK`，开启背部后验证真实背部装备；若没有该常量，记录诊断并保持 unavailable，禁止把 `EST_BACKPACK` 或任意整数当 slot。
6. **失败证据**：若 `v3.tasks` 仍 fence，复制 `oldFingerprint>loadedFingerprint`、`shapeRepair/shapeRepairFail`、Envelope 计数；不要重置任务追踪。若 Unit Line 仍塌缩，记录两个端点 token、Native screen/world reason 与 `worldAliasGuards`。

## `.18.113` Persistence v8 / Integrity v2 Fresh Reload 专项（历史 P0，继续保留）

1. **先保留旧 Store，禁止 Reset/Clear**：直接覆盖 `.18.113` 并 Reload。首个新 generation 必须能读取此前报 `fingerprint_mismatch` 的 ordinary Store；允许看到 `v1Compat>0`，但必须 `integrityFail=0 / envelopeFail=0 / fenced=0`。旧 `death_review/healer/launcher` 不应再因相同 hash mismatch 进入 write fence。
2. **升级落盘**：等待一次正常 Persistence Tick/Flush 后，`v1Resave` 应增加；再次 Reload 后这些已升级 Store 不应重复增加同一批 `v1Compat`，并继续保持 `integrityFail=0`。不要通过清配置让数字归零。
3. **启动写隔离**：若 App/Shell/Launcher 任一 Store 仍因其它真实原因进入 session fallback，本会话导航、拖主菜单、移动 R 都不得继续增加 `writeBeforeLoadReject`。Fresh generation 正常目标是 `writeBeforeLoadReject=0`。
4. **Build Transaction 下游恢复**：依次打开此前失败页面。Fresh generation 要求 `页面失败=0 / 隔离=0 / 事务回滚=0 / 事务失败=0 / pageQ=0 / txFail=0`。若仍失败，复制第一个具体 page transaction reason；禁止给页面绕过 `EnsureStoreLoaded()`。
5. **Startup degradation**：若 `runtime_startup_degradation` 仍为 warning，复制 `startupWarnings` 中首个 `feature id:reason`；v8 只消除由旧 Integrity false fence 引发的降级，不应吞掉真正独立的 Feature 启动故障。
6. **Critical Store 保持 fail-closed**：Gear Index/Payload 等 `verifyAfterSave/recoverableReplacement` Store 不允许使用 v1 compatibility mismatch 逃生。若这些 Store 报 integrity mismatch，仍按 Critical Journal 故障处理并保留证据。

## `.18.112` Input Focus + Drag Hit-Test Fresh Reload 专项（当前第一交互验收）

1. **新进程键盘基线**：完整退出客户端后以当前 `.18.113` 累计包启动，先不要打开 Replicated Suite；测试 WASD、技能快捷键、聊天框输入/发送。插件不得在未打开任何输入页面时占用键盘。
2. **主菜单拖动**：R 左键打开主菜单，从顶部 title bar 空白区域连续拖动至少 5 次；必须每次立即跟随。再从 8 个 resize edge/corner 测试缩放。拖动/缩放结束后不得继续黏鼠标。
3. **Generic WindowShell**：至少打开一个 FloatingSurface/通用 WindowShell，拖 title bar 与 resize handle；验证不是只有主 Shell 特例可拖。
4. **Focus 归还**：点击任意 TextInput/NumericInput 取得编辑焦点，分别执行“切换页面”“关闭主窗口”“关闭所属 Modal/FloatingSurface”。每次动作后立刻测试 WASD/技能键；隐藏控件不得继续吃键盘。
5. **Diff-cache 边界**：重复关闭同一页面/窗口两次（第二次 logical visible 已为 false），键盘仍必须正常；这是验证 focus cleanup 发生在 Ensure* cache early-return 之前。
6. **Hot Reload 旧世代退休**：让 TextInput 保持 focus 时执行恢复 reload；Reload 完成后不打开 Suite，立即测试游戏键盘。旧 generation 的 EditBox 不得残留 keyboard/focus ownership。
7. **Modal Scrim**：打开含 backdrop-dismiss 的 Modal，点击遮罩区域应能命中/关闭；验证 `Border(pickable=true)` 已真实下沉，而不是只在 Lua spec 中存在。
8. **Recovery Failure 模式**：仅在真实 Startup Failure 时 Recovery Command Bar 才允许取得键盘；恢复/隐藏后必须归还。若 Persistence Flush 故障，`reload` 仍应告警并加载覆盖后的新文件，strict durability 路径才允许阻断。
9. **失败证据**：出现“可见但拖不动”“关闭窗口后键盘仍失效”“只有点击聊天框后才恢复”等任一现象，记录具体 Widget/页面、是否刚聚焦 EditBox、BuildTag 与 `BootStage/R/CMD/ESC`；禁止在业务页面再加 `ClearFocus/EnablePick` 特例，继续回到 Input Lifecycle/Windowing Foundation 排查。

## Persistence Reliability v7 Fresh Reload 矩阵（当前 P0）

使用 `.18.100` **新进程**执行，禁止用同一热重载世代的旧状态冒充跨进程回读。**第一步执行下方 `.18.100 Gear Critical Journal + Persistence v7 专项`**，确认换装 Payload 能保存、Reload、完整退出重进并再次应用；通过后再继续状态显示及 `.18.94` Trade/DPS 回归。进入 `combat.buff_display` 时页面必须成功构建，`v3_build_transaction_contract` 的 Page failure/quarantine/transaction/preflight 计数在新 Generation 中保持 0；进入“HUD 布局”后拖动/缩放 Selection Overlay，指针移动与元素变化方向必须一致（左上原点：X+ 向右，Y+ 向下）。当前截图宽度属于 Compact 模式时，Toolbar 必须出现 `[属性]`/`[收起属性]`，进入 HUD 布局后属性 Drawer 应自动打开；选中元素后必须能看到并编辑 X/Y/宽度/高度以及适用的 Anchor/Pivot/Snap 参数。

**`.18.89` Interactive Draft 专项**：保持状态显示功能开启并让 Aura 事实持续更新。① 连续拖动 HUD 页任意 NumericField Slider，滑块必须稳定跟随鼠标，不能一帧预览值、一帧旧值来回闪跳；② 点击同一字段的精确 NumericInput，删除/输入部分字符后停留至少 1 秒，文本必须保持当前 draft，不能被旧 Binding 回灌；按 Enter/EditEnter 或失焦后才按既有规则 Commit/校验并格式化；③ 在 Compact Drawer 开/关、切换选择元素、普通 Refresh 后重复测试。

**`.18.144` Edit Commit / Focus / Table Resize 专项**：① 在任意 NumericInput 输入一个 Domain 可接受的新值（优先用范围辅助/单位连线设置），按 Enter 后数值必须保持为新 Authority 值，不能先变空再回旧值；② Enter 后不点击聊天框或其他控件，立即测试 WASD、技能键和正常聊天输入，Suite EditBox 不得继续吃键盘；③ 连续点击两个输入框，前一个必须完成 Commit/rollback 并释放 ownership，第二个可正常输入；④ 输入非法值并 Enter，允许按业务规则回滚，但游戏键盘仍必须立即恢复；⑤ 在有持续视觉刷新/列表刷新时按住 TableView 列分隔条左右拖动至少 3 秒，Header 与可见 Rows 必须只跟随鼠标 Preview，不得在鼠标位置与旧 committed 位置之间往返闪烁；松手后列宽与最后 Preview 一致。

**`.18.145` Numeric Apply / Dynamic Point Size 专项**：① 打开“范围辅助”，确认“点大小”Slider Fresh base 仍为 2..10；② 点击精确输入框，输入 `15`，不要依赖 Enter，直接点击右侧“应用”；③ 提交后输入框保持 15，Slider 最大端点必须立即扩成 15（最小仍 2），圆点必须明显大于旧 10 档；当前映射 10≈40px、15≈55px；④ Reload 后再次进入同一页面，业务点大小仍为 15，展示 Slider 端点至少覆盖 2..15；⑤ 输入超过硬安全上限的值（当前 24）时 Authority 不得越界，UI 必须按 Domain 回读值重绘；⑥ 在单位连线和其它 Compact Numeric Setting 抽查“应用”按钮，特别是窄卡片/低分辨率，Label/Slider/EditBox/应用不得相互覆盖；⑦ 点击应用或切换输入框后立即测试 WASD/技能/聊天，`.18.144` Focus Fence 不得回归。

| 域 | 重点 Store | 操作 | 必须通过 |
|---|---|---|---|
| Buff Display | `v3.buff_display` | 改追踪/分类；HUD Layout 做 Preview→Reset/Revert→Apply；立即点“重新加载文件” | 未 Apply 的 Working 不进 Store；Apply 后 Reload 回读一致；Flush 失败时应记录 Store+原因并继续 Recovery Reload，未保存修改允许丢失 |
| Healer | `v3.healer` | 改标量/规则/raid panel 几何与团队绑定；Feature Disabled 状态也编辑一次 | disabled 不清永久配置；Reload 后 panel 模型/颜色/设置一致 |
| Gear | `v3.gear.index` + legacy `v3.gear.payload.N` + 新 `v3.gear.payload.N.a/.b` | `获取当前→保存`；本进程应用；Reload 应用；完整退出重进应用；再次保存让 A/B 翻转 | Index 与 active/backup Domain 指纹一致；Critical verifyFail=0；v7 integrity/envelope/decoded/unverified reload failures 均为 0；新 active 只有回读验证后才能提交；Reload 后真实换装仍成功 |
| Activities / Tasks | `v3.activities` / `v3.tasks` | 改悬浮窗尺寸/透明度、追踪/隐藏项，连续拖动后立即重载 | debounce 未完成时 Reload barrier 先安全 Flush；回读保持 |
| DPS | `v3.dps` | 改模式/指标/side/self/rows 后立即重载 | 页面与 Widget 使用同一 Store 结果，不出现当下成功、重载回退 |
| Trade | `v3.life.trade` | 改生产地/售卖地/排序/收藏并重载；退出客户端再进入 | route/favorites 跨进程一致；普通 Refresh 不触发隐式拍卖扇出 |

每轮修改后先到“诊断与维护”观察 **新版存档 / 最近存档落盘**，并点一次 **“输出存档验收”** 保存 Fresh Reload 前的只读 Domain 指纹。随后执行“重新加载文件”或完整退出客户端再进入；进入后先重新打开本轮涉及的 Feature，使它们按正常业务路径完成 Store Load，再次点“输出存档验收”。同一个 Store 的指纹必须一致；`ALL` 只有在 Store coverage 相同（尤其 `v3.gear.payload.*` 注册/Load 数量相同）时才直接比较。连续 Slider/拖动后立即重载的测试允许前置快照 `Dirty=1`，但重载成功后的快照必须 `Dirty=0/Fence=0` 且 Domain 指纹一致。若 `Fence>0`、`FlushFail>0` 或 strict durability 重载被取消，立即点“输出诊断摘要”；`.18.90` 摘要必须直接带出 `存档故障 <store id>:<reason>`。**不要清空 Store、不要重置默认值来让 Gate 变绿**。

### `.18.100` Gear Critical Journal + Persistence v7 Durability/Integrity/Scope/Generation Fence 专项

1. **正常新保存**：选择方案，先穿一套容易辨认的装备，执行“获取当前→保存方案”。诊断中 `readbackVerifyAttempts/readbackVerifySuccesses` 与 `integrityStampedSaves` 应增加，`readbackVerifyFailures=0`。若保存 UI 报 `readback_verify_failed`，不要继续覆盖该方案，复制 `v3.gear.index` 或 `v3.gear.payload.N.a/.b` 的具体 reason。
2. **同进程应用**：换成另一套装备后点击该方案；必须根据保存的装备 name/grade/modifier/itemType 找回真实背包物品，而不是只显示“已配置”。
3. **Reload + 跨进程**：先 Reload 再应用一次；随后完整退出客户端、重新启动、打开 Gear 后再应用一次。两次都必须成功；v4/v5 stamped save 在每次新进程读取后 `integrityLoadChecks` 应增长，`integrityLoadFailures=0 / encodedLoadRejects=0`。方案名称存在但 `LoadPayloadForSet` 报 empty/structure invalid/fingerprint mismatch/integrity_failed 均视为失败。
4. **A/B 翻转与自愈**：在同一方案重新“获取当前→保存”，确认新 revision 写到另一 bank；保存 Index 之前 bank 必须已经 readback verified。Reload 后 active bank 可用。若 active bank 确认损坏而 backup 指纹完整，允许出现 `GEAR_PAYLOAD_BANK_RECOVERED` 并继续使用上一份 verified payload；下一次显式保存可出现一次 `STORE_VERIFIED_REPLACEMENT_RECOVERED`，但只能在新 bank 回读成功后清 fence。`future_schema/load_failed` 不得触发 replacement。
5. **历史损坏方案修复**：如果旧版本已经只剩方案名称，原装备明细无法被代码推导恢复。选中该方案后由用户明确执行“获取当前”，再保存一次；这一步才允许 `GEAR_PAYLOAD_REINITIALIZED`，之后它必须进入 A/B journal。直接点击“换装”或“验证”不得自动以当前装备覆盖历史方案。
6. **性能边界**：readback 只应随显式 Gear/critical save 增长；普通页面刷新、Tick、Gear 快捷按钮 idle 不得持续增加 verify attempts。普通非 Critical Store 正常 debounce 保存仍只增加 bounded integrity stamp，不应立即产生 `LoadData`；但用户显式 Reload/Runtime Stop 时，若 `barrierPending>0`，Flush 必须各做一次 bounded readback。Critical Gear immediate verify 已成功的 Store 不得被 barrier 重复读。
7. **失败证据**：任一 `integrity_failed / encoded_load_rejected / readback_verify_failed` 都视为本轮 P0 失败；立即复制 Foundation 摘要中的 store id + reason，不要 ClearStore/恢复默认。pre-v4 老 Store 首次读取出现 `integrityLegacyLoads` 属兼容路径，不是失败；v4 stamped Store 在 v5 中必须继续可读，它下一次保存自然升级为 v5 stamp。

8. **Durability Barrier 专项**：修改任意普通 Store（例如 DPS/Trade/窗口设置），等待 debounce Save 完成后先观察 `barrierPending>0`，再点击“重新加载文件”。重载前 Flush 必须使 `barrierVerifyAttempts/Successes` 增长；如果回读不一致，必须输出 `barrier_verify_failed:<reason>`，同时该 Store 重新 dirty 等待有界重写；Recovery Reload 仍继续加载新文件，strict durability 路径才取消。不得出现“Flush 认为 clean 所以直接放行”的旧行为。
9. **Envelope Seal 专项**：新保存后诊断应出现 `envelopeIntegrityStampedSaves>0`；Reload/重新登录后 `envelopeIntegrityLoadChecks` 应增长，且 `envelopeIntegrityLoadFailures=0`。若出现 `envelope_integrity_failed:*`，保留原 Store，不 Reset。
10. **Decoded Domain Budget 专项**：正常用户配置要求 `decodedLoadRejects=0`。出现 `decoded_load_rejected:*` 代表磁盘 envelope 虽可读但业务 decode/migration 结果越过 Store budget，必须按具体 Store 调整 codec/budget，不得放宽全局上限掩盖。
11. **True Durable 专项**：所有明确 durable 的 UI 操作（例如 Buff Display HUD Layout Apply、DPS Boss 名单显式 durable mutation）只有 immediate readback 通过后才允许提示保存成功；`durableVerifyAttempts` 应随这些动作增长，`durableVerifyFailures=0`。
12. **Character Scope 专项**：Gear `v3.gear.index` 与 payload bank 的 v6 save 应携带 exact character scope fingerprint。正常单角色 Reload 要求 `scopeBindingMismatches=0 / unverifiedReloadRejects=0`；若同一 Addon generation 发生角色身份变化，旧 dirty/barrier 必须先完成旧 key durability，绝不把旧 Domain 写入新角色。`scope_binding_identity_collision` 属于硬阻断证据，不允许自动覆盖。
13. **Generation Reload Fence 专项**：修改一个普通持久化设置并等待 debounce Save 后，`barrierPending` 可以暂时大于 0，但任何 Consumer 都不应在 barrier 前主动重新 `LoadStore` 同一 Store；正常流程要求 `unverifiedReloadRejects=0`。若该值增加，保留 `STORE_UNVERIFIED_RELOAD_REJECTED + store id`，修调用链，禁止用 `discardUnverified` 掩盖。
14. **Migration/Reset Dirty Commit 专项**：正常加载/migration/reset 后不得出现 terminal Store 同时因 load transform 留下自动 dirty；正常流程 `terminalAutoRetrySuppressions` 应为 0。若真实故障使该计数增加，Native Save 调用不应随 Tick 周期持续增长。`deferredLoadResaves` 只在合法 migration/period reset Apply 成功后增加。
15. **Verified Clear 专项**：仅在有备份的测试 Store 上执行一次明确“重置/清空”命令。`ClearData` 成功后必须出现一次 `clearVerifyAttempts`；正常客户端应 `clearVerifyFailures=0`。若失败，当前 Domain 不得先变默认值，必须保持原设置并报告 `clear_verify_failed`。不要用该步骤处理已经损坏的 Gear 证据。

### `.18.92` Presentation→Feature Command 专项

Fresh Reload 新进程还需验证三条本轮真实漏接链：① 打开 `life.tasks` 悬浮任务追踪并拖动/缩放窗口，`setState` 必须能经 `Tasks.Commands:SetWidgetWindowState` 正常保存，不得出现 nil method；② 对 `life.activities` 悬浮活动窗口做同样拖动/缩放与重载；③ 打开 Gear 快捷设置 Modal，执行“重置吸附/布局相关设置”入口，必须经 `Gear.Commands:ResetQuickSnapSettings` 返回真实结果。Foundation 摘要中的 `v3_presentation_feature_api_contract` 必须为通过。

### `.18.93/.18.94` DPS + Trade Fresh Reload 专项

1. **DPS 可见性**：先打开伤害统计悬浮窗，再通过正常关闭按钮关闭；保持 DPS Feature 本身仍启用。执行“重新加载文件”，随后完整退出客户端再进入各测试一次。两种情况下悬浮窗都不得仅因 Feature Enabled 自动重新出现；只有用户显式打开时才显示。Foundation Acceptance 的 `dps_widget_visibility_preference_contract` 必须通过。
2. **Trade 主页面**：进入主菜单→跑商并启用 Feature。点击“起点”必须真正展开 Native Dropdown；选定起点后“目的地”必须真正展开并列出候选；页面不得再出现 `起点◀/起点▶/终点◀/终点▶`。若 `GetProductionZoneGroups` 在 RU 失败，sealed Zone 只能保证候选可选，最终路线仍必须等 `GetSpecialtyRatioBetween` 服务器事实。`.18.165` 新增：查询一条真实路线后，材料列必须出现真实材料（静态层命中时立即显示，含单价/小计文本），不得整列停留在 `材料待确认`；状态行出现 `· 配方 X/Y`（诊断行同源），未命中行显示 `配方待解析 N`；材料询价按钮在存在待询价材料时必须可点。
3. **Trade HUD**：打开悬浮窗，必须是稳定的起点/目的地两行 Dropdown 布局并存在“材料询价”。选择一条有效路线后点击询价；普通 Refresh 不得自动扇出 Auction Query，显式询价完成后仅受影响路线行的材料成本/毛利应异步更新，未完成报价继续显示 unknown。`.18.164` 新增：询价进行中材料行显示 询价排队中/询价中，页面/HUD 状态行出现“· 询价中 N”；若报价失败，材料行显示 询价失败、详情悬浮窗提示区给出真实原因（如“最低价返回不可读（当前 RU 字段待核）”），且诊断页“报价队列”行可直接复制 `最近=life_trade#<itemType> <status> src=…（错误）`——该行是核对 `GetLowestPrice` 真实返回形态的第一手证据，请在首次实机询价后粘贴回传。Foundation Acceptance 的 `trade_dropdown_quote_preflight_contract` 必须通过。
3b. **Trade 材料身份回传（`.18.165`）**：首次真实路线查询后，把诊断页跑商行整行复制回传，重点三段：`配方 X/Y`（静态层命中数）、`解析中 N`（live 队列是否被触发）、`live读N 缓存a/b`（`X2Craft` 链是否真的读到了材料——`live读>0 且 缓存a>0` 说明货率行携带 itemType 且 live 材料形态可读；`live读>0 且 缓存b>0` 时把 `lastError` 一并回传）。若 `配方 Y` 持续大于 0 且无 `解析中`，说明货率行未携带可读 itemType，此时只能依赖静态层命中，不得猜测 itemType 字段名，需先采集 `GetSpecialtyRatioBetween` 原始返回证据。
4. 若 Native Dropdown 仍不展开，记录点击前后 `Feature:GetProjection().zones/sellableZones` 数量、Dropdown enabled/open 状态、首个 Popup/BuildTransaction 失败原因；不得恢复四个循环按钮作为降级方案。

## 逐域验收

### Combat / Team

| 区域 | 步骤 | 预期事实与日志 | 失败诊断 |
|---|---|---|---|
| DPS / Combat Analytics | 开启每个 Metric，造成伤害、治疗、死亡、控制和演奏事件，再关闭全部 Metric | Encounter、技能、死亡、控制、Aura、演奏状态按事件更新；全部关闭后 lease/task 为 0 | 查 `COMBAT_MSG` topic、Metric consumer、Encounter gap/one-shot 和 `combat_analytics` 诊断 |
| Death Review | 产生两次死亡，打开详情，删除单条、删除全部，重载 | 时间线、最后一击、技能 ID/名称、详情与持久化一致；删除失败回滚 | 查 `DEATH_REVIEW_*`、Store schema、Finalize queue |
| Healer | 50 人名单下启用 Health/Aura/Recommendation/编辑器/Head Marker/Raid Overlay/Calibration | 分片扫描、未知 Aura 显式显示；编辑保存/重载一致；关闭释放 lease | 查 TeamRoster/Aura lease、FrameBudget、marker screen projection |
| Buff / Buff Cap | 切换 player/target、过滤、tooltip、上限阈值和长文本 | 状态、图标/时间、阈值色彩与当前目标一致；未知 tooltip 不误报 | 查 `buff_display` schema、StatusMap、Tooltip 返回结构 |
| Boss / Target | 触发静态 Boss/聊天事件，切换目标和观察仇恨目标 | 匹配、倒计时、目标距离/目标的目标只显示真实返回；无事件不残留旧错误 | 查 alert matcher、TargetService、watch-target 返回字段 |
| Unit Lines | 同一目标依次置于前方、侧方、前方屏外、相机背后，再旋转相机重新看到目标；多人场景保持开启 | 前方屏外但线穿过 viewport 时保留可见段；相机背后必须整条隐藏且不指向边角；重新进入前半球后恢复；高负载刷新连续 | 查 `ScreenProjectionV3:GetHealth().behindCameraRejects/unitBatches/nativeScaleReconciles/nativeConsistencyFallbacks`、Presenter `unitRequestedDots/unitVisibleDots/unitAnchorWrites` |
| Unit Lines / Range Assist | 在 1024×768 / 1920×1080 / 2K 与不同 UI scale 放置已知目标；Unit Lines 分别测试近距离、远距离、端点出屏但线段穿屏、斜角贴边；记录 `CombatVisualGuidesV3:Describe()` 的 visibleDots/visibleEdges/clippedEdges/budget；Range 继续记录世界/屏幕坐标与已知半径 | Unit Lines 近距离保持基础密度，远距离自动增加 dots；端点出屏但可见段穿过 viewport 时只裁剪到边缘而不整段消失；refresh≤16ms 时总 dots≤256，默认 100ms 时≤480；真正整段出屏或 `behind_camera` 继续隐藏。Range 缩放/裁切正确 | 若 watchtarget/屏幕坐标字段不符，保留 blocker；不得为了解除消失问题绕过 ScreenProjectionV3 v6 front-hemisphere/consistency/world-alias fence，也不得重新启用 `GetUnitsInSight` |
| Team Management | 2 个 team、多个成员时刷新职责；再测试 SetRole、MoveMember/party | 每个真实 team/member index 有独立行；写动作按权限/冷却执行并显示成功/失败 | 查 TeamRoster snapshot、`X2Team:GetRole`、写 API result/permission |
| Team Auto Role | 当前玩家切到 吟游+暗杀+野性（catalog key `name_6_8_9`），入团/切职业各触发一次自动职责 | 必须选择“远程输出”/`TMROLE_RANGED_DEALER`，不得落到普通输出；再抽测其它 catalog `classType=Archer` 组合 | 查 `AutoRoleClassKey/AutoRoleLabel`、TeamAutoRoleCatalog v2、`X2Team:SetRole` 返回 |
| Raid Readiness / Recruitment | 50 人名单、角色/装分/距离/Aura；招募创建、关闭、接受、拒绝 | readiness 分片结果和 unknown 覆盖正确；招募列表/动作刷新一致 | 查 roster fields、recruit permission/cooldown/result |

### Gear

| 区域 | 步骤 | 预期事实与日志 | 失败诊断 |
|---|---|---|---|
| Gear Sets / Titles | 创建、保存、切换、重载方案与称号；测试 HUD/Snap/Reset | 装备槽、称号、快捷操作和外观设置可恢复；失败回滚 detached state | 查 Gear Store schema、Command result、WindowShell/FloatingSurface |
| Reinforcement Analysis | 枚举合法装备槽，比较原生强化面板字段 | 只有槽位范围与字段逐项匹配后才显示等级/材料/套效 | 缺字段或槽位不符时记录 `tools_reinforce_analysis` blocker |

### Life

| 区域 | 步骤 | 预期事实与日志 | 失败诊断 |
|---|---|---|---|
| Activity / Tasks | 刷新活动、展开子任务、选择追踪、打开详情/浮窗并重载 | `x/y` 语义、完成/进行中/未知与原生任务一致；关闭释放 Quest lease | 查 `QuestProgressV3`、event refresh、detail floating state |
| Trade | 选择生产地/可售地，触发多货物比例，打开材料/价格/毛利详情 | 所有有界货物、数量、单位成本、总成本、截断状态一致；未知价格不伪造利润 | 查 `Trade:OnRatio`、`materialRows`、auction quote event/recipe identity |
| Bonds | 进入西/东/原大陆居民板，刷新 7 类板；验证 20/60/100 与 Auroria token，完成/待交付后重载 | 每行显示 questId、真实状态、所需/背包数量/缺口；同 material+quantity 每日共享完成正确，日期切换清理 | 查 `Bonds` projection、QuestProgress state、Bag scan、bond cache 日期/保存日志 |
| Treasure | 背包放入多张地图，选择不同地图，在三种坐标/scale 更新位置 | 地图全集有界列出，坐标、方向、距离随选择刷新；无坐标时 unknown | 查 bag slot signature、world position tuple、selectedKey persistence |
| Fishing | 观察鱼动作 Buff；只在非战斗时测试自动 R，注入写入失败并重载 | Buff 推荐正确；R 替换必须完整快照、写入、恢复、失败回滚，否则保持 blocker | 查 Buff IDs、hotkey snapshot/recovery marker、combat guard |
| Craft | 用 itemType 解析多个 craftType，再显式指定 craftType/doodadId；测试空/opaque/失败/超限返回 | 材料/产物每行显示 itemType/name/count 或明确 unknown；上下文保存；不固定首配方 | 查 `GetCraftTypeByItemType` 多返回值、Product/Material schema、doodadId 语义 |
| Housing / Butler | 在住宅/管家上下文打开页面，切换上下文并关闭 | 仅显示已证明的只读字段，离开上下文停止读取 | 查 context detector、getter result 和 Demand release |

### Tools / Resources

| 区域 | 步骤 | 预期事实与日志 | 失败诊断 |
|---|---|---|---|
| Bag Organizer | 分别打开银行/箱子，读取 240+ 槽；准备至少 3 个会在移动后发生源槽补位的同类物品，一次点“放同类/取同类”；再测分类批量、四个单槽移动、黑名单、取消/失败重试 | 一次点击应以 250ms 串行继续移动多件（上限 40），不能每件都要求重新点击；slot 补位不误报失败；真实写失败仍停止；容量/读取失败/截断与黑名单状态可见 | 查 Bag Contract v5 stable itemType/category intent、live source resolution、ambiguous population-decrease verifier、storage window/cooldown |
| Auction | 添加/删除收藏，搜索已知物品，查询最低价，重复搜索并重载 | 收藏持久化；搜索所有返回行；价格字段和历史样本有身份/时间证据 | 缺 `GetSearchedItem*` 字段时只显示 blocker，查 auction event/result |
| Social | 读取好友/屏蔽/静音，执行四类增删动作并重载 | 列表身份正确；写动作结果、冷却、刷新可见 | 查 list schema、permission/cooldown、refresh projection |
| Hotkey Profiles | 枚举完整动作，快照、修改、保存、重载、恢复并在每个失败点注入 | 只有全动作枚举和可恢复事务通过才允许完成 | 缺 action registry 或 snapshot contract 时保持 blocker |
| Portal Profiles | 枚举个人传送候选，选一个、读回、重载、恢复 | 只修改目标 option，不碰其他设置 | 查 `X2Option` optionType/candidate/readback |
| Resource dashboard | 触发金币/经验/荣誉/生活点事件，刷新背包资源与首页 | 日统计 delta、资源数量和日期切换正确；容量/仓库未知不伪造 | 查 Resource event 参数、bag identity/category、首页 refresh |

## 最终采集

执行完上表后重新运行：

1. `replicatedsuite/tools/rs_foundation_audit.py`；
2. 当前交付记录声明的专项 harness（以 `CURRENT_REBUILD_STATUS.md` §5 / `CHANGELOG.md` 为准；临时 harness 不属于运行时包）；
3. 所有 Active TOC/Lua/Presentation/Boundary/Acceptance 检查；
4. 从新客户端日志确认 `unexpected global=0`、`authority violation=0`、`presentation boundary=0`、`quarantine=0`；
5. 将每一项实际结果回填到 `PRODUCT_COMPLETION_MATRIX.md` 的 Runtime verification 列。未执行的项目仍为 PENDING，不能改成 IMPLEMENTED。

### `.18.90` Component API / Package Coherence 专项

1. 使用全新进程打开“状态显示”，页面不得再出现 `rs_ui_workspace_templates.lua:* attempt to call method 'Show' (a nil value)`；`v3_build_transaction_contract` 的 `pageQ/txFail/rollback` 应在新 Generation 恢复为 0。
2. 进入 `HUD 布局`，Compact 模式 `[属性] / [收起属性]` 按钮必须可见且可反复切换 SAME Inspector；不能创建第二 Inspector、不能 reparent。
3. Foundation Gate 的 `persistence_runtime_acceptance_snapshot` 必须恢复通过：`contract>=1/fingerprint=true/snapshot=true`。诊断页必须存在“输出存档验收”按钮。
4. 点击“输出存档验收”只读当前已 Load Domain，不得触发 Flush/Save/Load；Fresh Reload 前后按既有矩阵比较单 Store 与 ALL 指纹。
5. 如果以上任意一项失败，保留完整一键诊断与首个 PAGE_NAVIGATION_FAILED；不要清配置或重置 Store 来规避。


### `.18.156` EditBox Post-Arm Focus Promotion 验收

1. Fresh Reload 后打开任一 TextInput/NumericInput，第一次单击编辑框后直接输入字符；不得出现“边框/Focus 看似已选中但键盘字符不进入 EditBox”。
2. 第一次点击允许 Native caret 因 post-arm `SetFocus` 发生一次定位；随后在同一个仍处于编辑态的输入框内再次点击不同字符位置，必须允许 Native caret 保持鼠标位置，不能每次重复 SetFocus 跳回开头/结尾。
3. 输入后等待页面刷新，Draft 不得被旧 Binding 回灌；Enter/LostFocus 后按既有 Draft Commit 契约提交。
4. 离开输入框、切页、关闭主界面后，WASD/技能/聊天键盘必须恢复；不得为了修复可输入而重新在构造阶段常驻 `EnableKeyboard(true)`。
5. Foundation `v3_native_interaction_contract` 必须包含 `postArmFocus=1`、`inputDiag=1` 且 `caretPlacement>=2`。如仍无法输入，复制“打印全部日志”中的 `UI输入：激活 成功/尝试 · 失败 · PostArmFocus · FocusFast · ArmedNow · Keyboard ...` 行。

### `.18.155` EditBox 基础验收
1. 任意 TextInput/NumericInput 点击后必须看到明显 focus 边框与 Native 闪烁 caret；再次点击字符串中部，caret 不应因 Lua 重复 SetFocus 跳走。
2. 输入已有文本后删除 1 个字符，保持编辑状态至少跨过页面自身刷新周期；字符不得恢复。对状态显示/治疗/DPS/换装/工具页至少各测一个输入框。
3. NumericInput 清空后等待刷新，空 draft 不得被旧数值立刻刷回；点击“应用”或失焦时再按当前校验规则提交/回滚。
4. 切换到另一输入框，前一个必须 Commit/rollback 并释放 Keyboard；关闭/禁用页面后 WASD、技能、聊天不得被隐藏 EditBox 捕获。
5. 不允许出现 Active Runtime `OnTextChanged/OnKeyDown/OnKeyUp` 或新增 Tick/轮询。
