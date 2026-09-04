# 历史交接：待办交接文档（Working Handoff）— 2026-09-03

> **Authority 已退役（2026-09-03）**：本文件中的仍有效待办已全部收拢到 [`../../CURRENT_REBUILD_STATUS.md`](../../CURRENT_REBUILD_STATUS.md) §9。后续不要继续在本文件追加活动 ToDo。本文只保留历史交接证据，本副本已位于 `Docs/Archive/Handoff/`，仅作历史追溯；活动 ToDo 统一以 CURRENT §9 为准。

> 用途：本机（家里）收尾，用户带去公司机器 `git pull` 后继续改。
> 仓库：`github.com/li-li-qing/replicated`（本地路径 `replicatedsuite/`）。
> 当前 BuildTag：`v3-m1.16.0.18.59-tooltip-cursor-follow-overflow`。
> 原则（用户硬约束）：**每个功能先查底层架构是否支持，不支持先完善底层再动手**；UI 布局类（拉伸/位置/层级）优先在蓝图/声明式层修，不下沉到 C++ 运行时。

---

## 0. 本提交（WIP）已包含的文件

本提交把**此前刻意 hold、待 RU 实机验收**的 4 个修复文件 + 本交接文档一起推上去，方便公司机器接力。这 4 个文件均已**录制式 harness 验证通过**，仅缺 RU 真机回归。

| 文件 | 修复内容 | harness 验证 | RU 验收待办 |
|------|----------|--------------|--------------|
| `features/combat/healer/rs_healer_health_v3.lua` | 治疗辅助团队覆盖层「成员进出颜色闪烁」：原 `OnRosterUpdated` 全量 `Reset` 清空已提交代→空窗→视觉闪灭；改为 `AbortCycles()` + 保留已提交代 + 立即重启 health cycle | 桩 harness 加人/减人 0 空发布、投影持续非空 PASS | PVP 实机进/退团员回归 |
| `presentation/v3/widgets/rs_v3_healer_raid_overlay.lua` | ①「点击闪烁」：section root 原 `CreateEmptyWidget`（emptywidget 类型）调 `SetUILayer("system")` 被 RU 白名单静默拒绝→从未进 system 层→点击被原生框架盖住；改走 `CreateRootWindow`(window 类型) 创建即常驻 system 层。②「副本内(5人)不显示」：`rosterCount > 5` gate 把 5 人副本排除；改为 `> 1` | 桩 harness 两环境对照 6/6 + 三规模可见性 3/3 PASS | 实机点击 raid 覆盖层不闪、副本 5 人出现、校准拖拽正常 |
| `services/rs_screen_projection_v3.lua` | 头标「凭空贴在屏幕」：`ProjectUnit` 加屏幕边界 gate（`NormalizeScreenPoint` 后超 `[-16, logicalW+16]×[-16, logicalH+16]` 视为失败返回 nil+err），吸收 stale/depth=1 缓存坐标 | 10 case 矩阵 baseline(8/10 放行屏外)→post-fix 10/10 拦截 PASS | 确认无效 token 返回形态（`stale_origin(0,0)` 仍在界内，可能需 `(0,0)` 特判） |
| `presentation/v3/pages/rs_v3_gear_page.lua` | `.18.57` WU1 遗留：4 个像素钉死原生控件（createEdit/nameEdit/createButton/saveName）→ RSUI `TextInput`/`Button`；`SafeNativeClick` 绑 `.root` OnClick；`SetNativeText`/`GetNativeText` helper | 桩 harness 20/20 PASS | gear TextInput/Button 交互、tab 切换 |

> 同源扫荡结论（已查证，未改，待实机）：head_marker / bag_quick_overlay / alert_hud / combat_visual_guides 同为 emptywidget root + `TrySetUILayer("system")`，按 RU 白名单同样静默失败。用户未报症状则不动；若实机出现被原生 UI 盖住/闪烁，套用「root 改走 CreateRootWindow(window)」同法。

---

## 1. 已推送完成（GitHub main，本机已验证）

| 里程碑 | commit | 内容 |
|--------|--------|------|
| M1.16.0.18.57 | `150a4c2` | V3 页面布局优化（gear/healer/business 迁 RSUI 模版）+ 底层 2 个预存在全局泄漏修复 |
| M1.16.0.18.58 | `cb92465` | ColorField 基础组件 + 单位连线/范围辅助线条颜色（issue #1+#3）；录制 harness 捕获并修复 1 个真实生产 Bug（`Clamp01` 前向局部全局绑定崩溃） |
| M1.16.0.18.59 | `c8d7ca3` | 截断文字悬浮提示跟随光标（issue #2） |

issue 进度：#1 ✅ #3 ✅ #2 ✅（均待 RU Fresh Reload 目测）。

---

## 2. 待处理 issue（尚未开工）

### #4 换装/称号「设置位置 UI」丑陋 — 卡在缺原始截图
- **已做架构核查（未动代码）**：读 `rs_v3_gear_page.lua` 与 `rs_v3_gear_quick_settings_modal.lua`。
  - 左栏管理 rail **已经**是 6 个 titled `GroupBox`（方案库/当前方案/参与范围/屏幕快捷与吸附/顺序与删除/状态与反馈）包在 `ScrollBox` 里——代码注释明说这是把原「flat 14 控件 VerticalBox 杂乱」改掉的。所以左栏已不是 soup。
  - 吸附设置弹窗结构干净（header + hint + 2 个 `NumericField` 滑块 + 恢复默认/完成）。
  - **最可疑剩余源**：右侧 `dualHost` `HorizontalBox` 两个 `Border` 各含 10 行 `TableView`（防具/时装 vs 饰品/武器/称号），信息密度最高、列宽最紧（参与40+部位48+状态44 固定，装备/属性 剩 ~200px）。
- **阻塞点**：原始 `@image` 截图不在本机上下文，且用户规则「禁止空想根因后动代码」。
- **公司接力动作**：用户提供截图或指定聚焦区域（左栏 / 右侧双栏 / 吸附弹窗）→ 按「查架构→改→编译/harness→验证」落地。

### #5 跑商（trade）下拉框不弹 / 按钮切换笨重 / 售价用金银铜 / 缺识别材料按钮
- 未开工。入口疑似 `presentation/v3/pages/rs_v3_business_pages.lua` 的 trade 区块 + `features/.../trade` 相关 feature。
- 先查：下拉框组件是 `RSUI:Dropdown` 还是原生；售价格式化现状（金银铜 vs 纯数字）；识别材料按钮是否在 feature 命令里缺 UI 绑定。

### #6 整理背包按钮点击没反应
- 未开工。对应 `tools_bag`（`features/rs_business_bridge.lua` 已有 `BagBatchRunning`/类别批量整理命令 + `rs_v3_business_pages.lua` 的「高级整理/开始整理」按钮）。
- 先查：按钮的 `OnClick` 是否真正绑到 `Feature.Commands:StartCategoryBatch`；是否因 feature 未 AcquireConsumer / 按钮被其它 handler 吞掉导致「没反应」。

### #7 拍卖收藏 UX（参考项目可借鉴）
- 未开工。`tools_auction` 已有规范化持久化关键词/收藏（上限 20，M1.16.0.18.33）。
- 先查：当前收藏入口/删除/分页交互痛点；对照 `参考的addon/`（本机 `../参考的addon/`，注意它**不在本仓库**、不要误 commit）的吸收点。

---

## 3. 验证门禁 & 工具链（公司机器照做）

- **Foundation Audit**（提交前必须全绿）：`python tools/rs_foundation_audit.py --root .` → 期望 `FOUNDATION_AUDIT PASS | ... globals=0 presentation=0 rawNative=0 rawScope=0 ...`。
- **录制式 harness**：放 `.workbuddy/tmp/`，loadfile 真实源码 + stub 客户端，baseline-FAIL→fix→PASS；**harness 不入 git**（确认 `.gitignore` 覆盖 `.workbuddy/`）。
- **Lua 陷阱备忘**（本机已踩）：
  - 闭包引用晚声明的 `local function` → 绑定到全局（真崩溃）。
  - 冒号调用 `obj:Method(a)` 展开为 `obj.Method(obj,a)`，stub 必须 `function(self,...)`。
  - `S.Api:GetMouseLogicalPosition()` 返回 `(x,y,nil)`，坐标取前两个返回值。
  - `RSUI:IsComponent(v)` 查 `type(v.GetRoot)=="function" and v.kind~=nil`。
- **提交纪律**：每个 WU 独立完成 读→审计→改造→编译→测试→出结果；WIP 修复先 harness 验证再 commit；终态用「修复总结」表（Bug/根因/修复/验证）。

---

## 4. 公司机器接手步骤
1. `git pull`（拿到本提交的 4 个 WIP 文件 + 本交接文档）。
2. 跑 `python tools/rs_foundation_audit.py --root .` 确认门禁仍绿。
3. 先做 4 个 WIP 文件的 RU Fresh Reload 实机验收（见 §0 各文件待办）；通过后记「已 RU 验证」并落 Skill/笔记（**验证前不写 Skill**）。
4. 再开 #4（需截图）→ #5 → #6 → #7，每步先查底层架构。
