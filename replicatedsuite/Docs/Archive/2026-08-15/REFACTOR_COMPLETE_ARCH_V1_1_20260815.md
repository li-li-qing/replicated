# Replicated Suite Architecture v1.1 一次性重构完成报告

> **后续深审更新：** 本文记录 OneShot 初版完成状态；最终测试请以 `REFACTOR_AUDIT4_DEEP_CHECK_20260815.md` 与 `VALIDATION_ARCH_V1_1_AUDIT4_20260815.json` 为准。


日期：2026-08-15  
Suite 版本：`1.0.0-architecture-v1.1`  
保存结构版本：`17`

## 1. 本轮目标

本轮不是阶段性测试版，而是按 `Replicated Suite Architecture Final v1.1` 完成一次性架构收口，再进入游戏实测。

最终公开 Addon 根目录只保留：

- `globals`
- `replicatedsuite`
- `z_api_functions`

历史独立运行目录 `replicatedgear / replicatedplates / replicatedhealer / replicateddps` 已从最终包移除。四套成熟业务 Domain 迁入 `replicatedsuite/modules/professional/`，由 Suite 统一管理生命周期，但仍保留各自业务状态与持久化职责，避免形成超级 Core。

## 2. Authority 收口

### 2.1 Module Authority

新增并落地 `core/rs_module_manager.lua`：

- Suite Module Manager 是模块启停的唯一生命周期 Authority。
- 专业模块默认关闭。
- 启用时才启动模块 Runtime、事件订阅与需要的 Observation。
- 禁用时停止 Runtime、事件与 Scheduler Owner，但不清空业务配置和统计数据。
- 模块异常隔离，不允许单个模块故障拖垮 Suite。
- 设置入口与模块运行状态分离，模块关闭后仍可进入设置。

### 2.2 HUD Authority

新增并完善 `core/rs_hud_manager.lua`：

- `Module Enabled`、`HUD Visible`、`Collapsed` 三个状态严格分离。
- 长驻 HUD 不提供 `×` 作为销毁入口。
- 缩放只在 HUD 编辑模式中提供。
- HUD 编辑支持临时解锁、临时隐藏、屏幕边缘吸附与 HUD 对 HUD 吸附。
- 普通游戏拖动不强制硬吸附。
- 字体大小不随窗口尺寸自动联动。
- 背景透明度只作用背景，不把文字一起透明。
- 支持全局与单 HUD 的字体、背景、紧凑模式继承。
- “找回 HUD”只纠正到屏幕可见区域，不破坏用户大小、字体、背景等外观配置。
- 全局紧急恢复及单 HUD 全部恢复采用二次确认。

### 2.3 API Capability Authority

新增 `core/rs_api_capabilities.lua`：

- 当前静态 API 基线为 2026-08-15 的 `z_api_functions`。
- 区分 Official / Static / Runtime 能力状态。
- 本轮直接官方 API 静态扫描未发现未登记方法调用。
- 不因旧版本曾开放 API 而自动假设当前仍可用。

## 3. 专业模块迁移

### 3.1 Gear

- 迁入 Suite Professional Module。
- 默认禁用，不再因为 Lua 文件加载就自动出现快捷按钮。
- Runtime 增加显式 Enable / Disable 生命周期。
- 禁用时可终止进行中的换装事务并释放 Driver。
- 快捷 HUD 纳入 Suite HUD 可见性管理。
- 拖动时只在 HUD 编辑模式走 Suite 吸附。
- 保留成熟的换装 Domain 与角色方案数据，不在本轮重写业务事务状态机。

### 3.2 Plates

- 迁入 Suite Professional Module。
- 默认禁用时主 Driver 与 Watchdog 不启动，也不执行初始 `ForceAll()`。
- 禁用会真正停止主循环。
- 基础单位读取开始复用共享 Observation 短 TTL 缓存。
- 保留 BUFF/PVP 业务判断在 Plates Domain 内，不把业务结论提升到公共 Core。

### 3.3 Healer

- 迁入 Suite Professional Module。
- 推荐排名计算可继续服务团队高亮/头顶标记。
- Suite 嵌入模式不再呈现独立的推荐排行榜 HUD，避免重复产品表面。
- 启停完全由 Module Manager 控制。
- `UnitName / UnitHealth / UnitMaxHealth / UnitDistance` 等轻量事实使用共享 Observation；BUFF 等业务读取仍由 Healer 自己拥有。
- 保留已确认治疗优先级、BUFF/血量规则语义，不在架构迁移时强制修改业务模型。

### 3.4 DPS

- 迁入 Suite Professional Module，取消独立 Addon 自启动与独立 ESC 注册。
- Suite Module Manager 成为唯一启动/停止 Authority。
- 新增数据范围模式：`附近` / `团队`。
- 默认 `附近`，保持原有广域统计行为。
- `团队`模式正式排行榜只接受 SELF / TEAM；非团队事件保留为 Context Fact，不进入正式排行榜。
- 团队模式关闭广域 Sight 扫描，降低大规模场景额外开销。
- 切换范围模式不清空既有统计。
- 诊断增加范围模式、团队人数、广域扫描状态、Context-only 计数。
- 友军/敌军排行榜 HUD 纳入 Suite HUD 编辑与可见性 Authority。
- 最小高度改为技术下限，不再被“一行高度”变相锁死。
- 保留 DPS 的事件事实、PVP/PVE 分类、累计统计、Boss、持久化分片等成熟 Domain 逻辑，不在架构重构中重写统计定义。

## 4. Module Sandbox

新增 `core/rs_module_sandbox.lua`，四个专业模块 Lua 文件全部进入独立模块环境：

- 读可回退 Root 环境。
- 模块写入默认留在自己的 Sandbox。
- 跨模块只通过显式 Export / Suite Service 协作。
- 减少历史全局变量相互覆盖造成的隐性耦合。

静态检查结果：Gear 6、Plates 7、Healer 4、DPS 24 个 Lua 文件均已接入 Sandbox。

## 5. World Observation

`core/rs_observation.lua` 已从注册骨架扩展为真实共享 Fact 层：

- 模块按 Owner + Field 订阅。
- 模块禁用时释放订阅。
- 对 UnitName、ID、血量、距离等基础事实提供短 TTL read-through cache。
- `target / targettarget / mouseover` 等高波动别名不会跨时间复用陈旧目标身份。
- 提供 cache、subscriber、hit/miss 诊断。
- PVP/PVE、治疗优先级、BUFF价值、敌我结论仍留在各自 Domain，不由 Observation 越权裁决。

这实现了共享基础读取去重，同时避免为了“中心化”强行替换已经实测过的各 Domain 枚举/事件流水线。

## 6. 统一设置、方案、常用入口

新增：

- `core/rs_settings_registry.lua`
- `core/rs_profiles.lua`
- `core/rs_favorites.lua`
- `core/rs_diagnostics.lua`

功能包括：

- 模块统一搜索与设置入口。
- 功能方案：只保存模块启用状态。
- HUD 方案：保存 HUD 布局与外观。
- 组合方案：显式组合功能方案与 HUD 方案。
- 页面 / 模块 / HUD 均可加入常用入口。
- 常用入口支持移除、上移、下移；首页只显示用户主动收藏的项目。
- 首页更新提示可跳转诊断查看本版重点。

## 7. 主 UI

主窗口不再使用旧“四个专业插件顶部页签”结构，改为 Suite 左侧导航，并新增独立页面：

- 首页/生活 Dashboard
- 活动
- 战斗
- 模块
- HUD
- 快捷
- 设置
- 诊断

保留原生活综合 Dashboard 的使用效率，同时把模块、HUD、诊断 Authority 显式暴露给用户。

## 8. 文本溢出规则

- 公共与专业通用 UI 已移除 `SetEllipsis(true)` 自动省略策略。
- DPS 名称在极窄宽度下采用 UTF-8 安全裁切，不追加 `...`。
- 保留业务状态本身需要的“……”或加载指示语义，不把它们视为布局溢出。
- 后续实机仍需在 1024×768 与窄 HUD 场景检查每个窗口的真实字体度量。

## 9. 数据与迁移边界

新增 `core/rs_migration.lua`：

- 迁移不会为了读取旧数据重新启动旧 Runtime。
- 现有专业 Domain 会继续尝试读取其历史持久化 Key。
- 官方 `ADDON:LoadData(key)` 当前文档没有提供“显式指定另一个 Addon 命名空间”的参数，因此如果客户端存储按 Addon 目录做强命名空间隔离，Suite 不能安全伪造跨 Addon 读取。
- 因此最终包不保留旧独立 Runtime 作为兼容桥，避免双 Authority；是否能自动读到历史独立 Addon 数据由客户端实际持久化作用域决定，需要首次实机加载确认。
- 重构优先保持已验证业务 Domain 格式，未做未经实机验证的强制数据格式改写。

## 10. Public Release 约束

最终包根目录包含 `Build-PublicRelease.ps1`：

- 发布白名单仅允许 `globals / replicatedsuite / z_api_functions`。
- 检测到额外 Addon 顶级目录会阻止发布。
- 检测到 `modules_private / private_extension / autopotion / auto_potion` 路径会阻止发布。
- 私人自动吃药等功能不进入公开 Suite。

## 11. 静态验收

最终封包前执行：

- Suite Lua：107 个，语法失败 0。
- `toc.g`：111 个加载项，缺失 0。
- 直接官方 API 调用：163 处引用、51 个唯一方法，当前 `api_functions2.lua` 未登记方法 0。
- `SetEllipsis(true)`：0。
- 旧 `rs_combat_bridge` / 独立 Addon 路径引用：0。
- 旧专业独立 Addon 顶级目录：0。
- 私人模块路径命中：0。
- 专业 Lua Sandbox 缺失：0。

静态验收只能证明结构、加载清单、Lua 语法和当前 API 索引一致性；ArcheRage 客户端运行时、UI 尺寸、事件签名和存储命名空间必须进入游戏验证。

## 12. 首轮实机测试重点

建议按以下顺序测试，便于快速定位：

1. 首次加载：Suite 主按钮、主窗口、左侧导航是否正常。
2. 默认状态：Gear / Plates / Healer / DPS 是否全部保持关闭且不偷偷出现旧 HUD。
3. 模块页：逐个启用/禁用四个专业模块，确认 Runtime 与 HUD 同步停止/恢复。
4. HUD 编辑：拖动、缩放、临时解锁、吸附、找回、单 HUD 恢复、全局紧急恢复。
5. 生活模块：任务、资源、跑商、债券、活动、藏宝、钓鱼、团队辅助。
6. Gear：非战斗换装、战斗武器切换、方案按钮、打断与再次切换。
7. Plates：BUFF追踪、PVP发现、重要冷却、名称/职业/装等/距离布局。
8. Healer：团队血量/Buff颜色、距离、校准与拖动、头顶与团队高亮。
9. DPS：PVE/PVP、友军/敌军、治疗、Boss、详细面板、清空、人工纠错。
10. DPS 范围：分别验证“附近”和“团队”，确认团队模式不把附近非团队玩家纳入正式排行。
11. 大规模：5 人 Boss → 50/100 人 → 200 人附近场景，观察 UI、统计完整性与卡顿。
12. 重登/重启：模块状态、HUD布局、收藏、方案、专业 Domain 数据是否正确恢复。

## 13. 安装测试注意

最终包已经不包含旧独立专业 Addon。实际游戏目录中如果仍残留旧的：

- `replicatedgear`
- `replicatedplates`
- `replicatedhealer`
- `replicateddps`

请在测试前删除这些旧目录，否则客户端仍可能同时加载旧 Runtime，破坏本轮“唯一 Authority”的验证结论。
