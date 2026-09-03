# Replicated Suite Architecture v1.1 — Audit 6 全局发布前审计

版本：`1.0.9-architecture-v1.1-audit6`  
保存结构：`Schema 20`  
日期：2026-08-15  
作者：Replicated

## 结论

本轮以用户 2026-08-15 11:01 提供的完整 Addon 为唯一代码基线，并继续以冻结的 Architecture v1.1 文档为产品与架构裁决。

用户实机基线在进入本轮前已经达到：模块无故障、Storage 正常、Character Scope 已识别、Backlog Normal。因此本轮没有重写已经恢复稳定的 DPS / Healer / Gear / Plates 业务语义，而是重点处理在长期使用、低分辨率、嵌入式专业设置与后续维护中仍可能暴露的问题。

本轮代码、行为仿真和静态门禁已全部通过，可以进入下一轮 ArcheRage 实机验证。

## 本轮完成

### 1. 主菜单专业功能彻底成为一级页面

主菜单左侧正式保留：

- 首页
- 活动
- 伤害统计
- 治疗辅助
- 一键换装
- BUFF显示
- 模块
- HUD
- 快捷
- 设置
- 诊断

删除已经失去产品职责的旧 `rs_combat_page.lua`。专业功能不再先进入一个重复的“战斗中心”再二次跳转。

所有专业页面继续使用主窗口右侧 `content host`，不恢复独立设置窗口作为设置 Authority。

### 2. 专业设置页响应式重构

DPS、Healer、Gear、Plates 的页内二级选项卡不再强制挤在单行，而是根据右侧内容宽度自动换行。

实测行为仿真覆盖：

- 内容区 440 × 550；
- EditBox 可用；
- EditBox 不可用；
- 四专业全部分区逐页切换；
- 所有可见控件均不得越出内容区。

四专业页面均通过。

### 3. DPS 设置继续补全

DPS 高级设置增加持久化周期入口，与现有 Domain 配置保持一致。

Suite 嵌入模式彻底不创建 DPS 旧 Launcher；旧独立配置窗口仍只允许 standalone 兼容路径创建。

`U.ApplyRect()` 增加 nil 安全，避免嵌入模式下旧兼容布局逻辑访问不存在 Launcher 时拖垮 DPS UI。

没有修改：

- PVP / PVE 事件分类语义；
- Team / Range 数据范围语义；
- 排行统计累计语义；
- Boss 投影；
- Actor / Identity / Replay 业务 Authority。

### 4. Healer 设置继续补全并校正默认值

Suite 页面新增头顶标记等级与每等级尺寸设置，并由 Healer Domain Facade 正式读写，不由 Suite 直接拥有业务状态。

同时修正两处 UI 默认回退与 Domain 配置不一致：

- missingSensitivity：`3000` → `30000`；
- Raid Rank X / Y fallback：`0` → `1`。

规则页和观察页在最小窗口下重新压缩布局；Buff 观察动作区改成等宽 5 列，避免窄内容区 4px 越界。

没有恢复已经按架构移除的独立“治疗需求排行榜 HUD”。候选计算仍保留，因为团队高亮和头顶标记继续消费结果。

### 5. Gear Suite 设置收口

方案、参与槽位、快捷/行为继续作为右侧 Suite 设置 Authority。

运行时“切换”按钮现在同时要求：

- 当前方案有效；
- Gear Module 已 Enabled。

模块关闭时仍允许编辑静态配置，但不会触发 Runtime 动作。

新建方案在 EditBox 不可用时仍可使用自动命名方式；需要用户文字输入的命名操作不会因为 EditBox 缺失导致页面崩溃。

### 6. Plates 追踪管理补全

旧 Suite 页面只能管理前 8 个 Buff / Debuff Tracking ID，本轮增加分页：

- 上一页；
- 下一页；
- 每页 8 项；
- 任意页删除；
- 新增后刷新当前投影。

模块 Enabled 时，新增 / 删除追踪 ID 会立即 `ForceScope()`，不需要等待下一轮普通刷新。

显示数量选项与 Plates Domain 真正支持的最大值统一为 12，避免 UI 提供 16 / 20 但 Runtime 最终又截断成 12 的假设置。

### 7. EditBox 能力降级不再破坏 UI

此前 RU 客户端实机出现过 `CreateEditBox()` 返回 nil，进而造成模块页布局异常。

`rs_ui_factory.lua` 现在会依次尝试：

- `UOT_X2_EDITBOX`
- `UOT_EDITBOX`
- `OBJECT_TYPE.X2_EDITBOX`
- `OBJECT_TYPE.EDITBOX`

Modules / HUD / Professional Pages 均增加无 EditBox 降级逻辑。

需要文字输入的按钮会禁用或给出明确提示；不依赖文字输入的浏览、应用、删除已有方案仍可工作。

### 8. Modules / HUD / Quick 三个公共页面重新验收最小尺寸

`ModulesPage`、`HudPage`、`QuickPage` 重新按当前内容区高度计算布局，而不是依赖过去的固定 Y 坐标。

行为仿真覆盖 440 × 550 内容区，并分别测试 EditBox 存在 / 不存在。

### 9. 页面布局错误隔离

`MainWindow:ApplyLayout()` 不再让一个页面的 ApplyLayout 异常阻断后续所有页面。

11 个页面逐个进入独立 `xpcall`：

- 当前页异常会进入 Diagnostics；
- 其它页仍可完成布局；
- 同一错误使用 `WarnOnce` 避免每次布局刷屏。

### 10. 设置搜索与常用入口继续路由到 Suite 页面

专业设置搜索继续扩展：

- DPS：持久化周期等高级项；
- Healer：团队 / 头标 / 职责 / 校准等；
- Gear：方案 / 槽位 / 快捷行为；
- Plates：HUD / 追踪 / 外观 / 诊断。

旧 `page:combat` 常用入口仅作为旧存档兼容别名，实际目标改为 `dps`，不会重新创建旧 Combat Page。

`ShowPage()` 失败时 Router 不再无条件报告成功。

## 生命周期与性能复核

### 专业模块

- DPS Stop：继续无条件执行半启动清理；
- Healer Disable：释放团队事件与 Runtime Update；
- Gear Disable：停止换装 Runtime Driver；
- Plates Disable：释放 Event / Driver / Watchdog Update；
- ModuleManager Disable 幂等：行为测试 PASS。

### Scheduler

继续保持：

- 单一 Suite OnUpdate Authority；
- due scratch 数组复用；
- backlog 原地更新；
- 仅多个到期任务时排序；
- Stop 释放 OnUpdate Handler。

### 广域扫描

整包正式业务中的 `GetUnitsInSight` 仍只由 DPS Range 模式拥有，没有在生活、团队辅助或 Plates 中复制第二套广域扫描。

### Reload

不恢复已经实机证明会导致 Native use-after-free 的：

`OnUpdate Host → ADDON:ReloadAddon()`

当前明确区分：

- `刷`：刷新 Suite 数据 / UI；
- `载`：显式触发 UI / Addon 文件重新读取；
- `R` 左键：只打开 / 关闭 Suite。

代码中活动 `ADDON:ReloadAddon()` 调用为 0，`code_reload_host` Runtime 为 0。

## 存储与角色 Scope

本轮没有升级 Save Schema，继续使用 Schema 20。

保留此前已经验证的：

- Account Base + Character Override；
- Schema19 false 修复；
- Character identity 冷启动；
- 同 generation A → B → A；
- Character Runtime Projection reconcile；
- Future Schema 写保护；
- LoadData 失败写保护；
- DPS / Healer / Gear / Plates 专业 Domain 写保护。

没有擅自修改专业模块历史 SaveKey。

## API Capability

Suite-owned Service 继续统一经过 Capability Registry。

当前验证：

- Suite literal capability 使用：31；
- Registry 能力记录：51；
- Suite 使用的 capability 全部已注册；
- 静态 API 快照均能找到对应方法；
- Suite Service/Core 中直接绕过 Registry 的 raw `S.Api:Call/Action`：0。

专业模块成熟 Adapter 保持自己的 Domain 边界，本轮不做无意义机械改写。

## 机器门禁

Audit6 最终门禁：**57 / 57 PASS**。

主要指标：

- Suite Lua：104；
- Lua 语法失败：0；
- TOC Lua：111；
- TOC 缺失：0；
- TOC 重复：0；
- Suite 孤儿 Lua：0；
- Professional Lua：41；
- Professional Sandbox：41 / 41；
- `SetEllipsis(true)`：0；
- 私有 AutoPotion Runtime：0；
- 活动 `ADDON:ReloadAddon()`：0；
- `code_reload_host`：0；
- Professional Domain 互相直连：0；
- Frozen Architecture：4 / 4 原文 SHA-256 一致。

行为测试：

- Storage Scope：PASS；
- Scheduler：PASS；
- Runtime Character Projection：PASS；
- ModuleManager Lifecycle：PASS；
- Professional Sandbox：PASS；
- Professional Export Contract：PASS；
- Professional Lazy Initialize：PASS；
- 四专业页面最小尺寸（无 EditBox）：PASS；
- 四专业页面最小尺寸（有 EditBox）：PASS；
- 公共页面最小尺寸（无 EditBox）：PASS；
- 公共页面最小尺寸（有 EditBox）：PASS。

## 实机下一轮重点

1. 1024 × 768，UI scale 分别测试 80% / 100% / 120%；
2. 左侧 11 个一级页面逐个切换，确认内容始终留在右侧；
3. 四专业每个二级页逐一切换，确认 tab 自动换行且无重叠；
4. DPS Range ↔ Team，不清空历史，Team 不继续完整范围扫描；
5. Healer 团队高亮、头标 1~4 级尺寸、Buff 追踪、规则、校准；
6. Gear 创建 / 捕获 / 重命名 / 切换 / 战斗中武器优先；
7. Plates Tracking 超过 8 项后的分页、新增/删除即时生效；
8. 角色 A / B / A，检查 Character Scope 不串号；
9. 连续 Enable / Disable 四专业模块；
10. 100 / 200 人长战斗，记录 FPS、Backlog、内存增长和事件追平时间；
11. 覆盖新文件后只在需要重读 Lua 时使用 `载`；普通数据刷新使用 `刷`。

## 本轮明确未做

- 没有清空或重置用户数据；
- 没有升级 Save Schema；
- 没有改变 DPS 统计分类规则；
- 没有恢复 Healer 独立推荐排行榜；
- 没有把专业 Domain 状态搬进 Suite.State；
- 没有恢复旧 Combat Page；
- 没有恢复旧专业设置窗口作为用户入口；
- 没有恢复危险的 `ReloadAddon` OnUpdate Host。
