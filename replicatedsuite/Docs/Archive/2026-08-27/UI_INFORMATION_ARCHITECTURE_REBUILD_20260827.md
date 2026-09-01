# Replicated Suite UI 信息架构重构基线

日期：2026-08-27  
基线：Addon(20260827-075839)  
目标：收敛重复入口、明确功能归属、保持旧配置/旧页面键兼容，并为 V3 Presentation Host 后续迁移建立唯一信息架构 Authority。

## 1. 核心裁决

UI 不再自己决定功能归属。`ui/rs_ui_catalog.lua` 是主窗口导航、页面标题、稳定页面键与兼容别名的唯一 Presentation Catalog。

业务 Authority 不变：

- Quest / Event / Trade / Resident / Resource / Treasure / Fishing 继续由现有 Service 负责；
- ModuleManager 只负责功能生命周期；
- HudManager 只负责 HUD 显示、编辑、位置与尺寸；
- Feature Page 负责对应功能自己的设置；
- Global Settings 只保留 Suite 全局设置；
- Context Tool 不再伪装成主功能入口。

## 2. 新导航结构

```text
首页
└─ 今日总览

战斗
├─ 团队辅助
├─ 伤害统计
├─ 治疗辅助
├─ BUFF显示
└─ 一键换装

生活
├─ 活动
├─ 跑商
├─ 债券 / 居民板
├─ 任务追踪
├─ 寻宝
└─ 钓鱼

工具
├─ 整理背包
└─ 实用工具

系统
├─ 悬浮窗管理
├─ 功能开关 / 方案
├─ 全局设置
└─ 诊断与维护
```

旧页面键没有删除；`activity -> life`、`target -> plates` 继续在 Presentation 边界兼容。

## 3. 首页职责

首页固定收敛为五个真实数据区域：

1. 活动 / 世界状态；
2. 跑商当前路线；
3. 债券 / 居民板；
4. 我的任务追踪；
5. 今日统计。

删除重复的“系统提醒”信息块。活动提醒不再把 EventService 同一快照复制到第二张卡。

首页活动列表固定最多展示 12 条高优先级投影；完整活动页使用虚拟列表展示全部 EventService 结果，`eventMaxRows` 只保留为 HUD Presentation 偏好。

“我的任务追踪”只消费 `dailyTracking`。活动 Objective Tracking 属于活动域，不能与 dailyTracking 混成同一 Authority。当前没有 `weeklyTracking`，因此不会把全部周常伪装成“我的追踪”。

## 4. 设置职责重新分配

### Global Settings

只保留：

- UI 缩放；
- 字体缩放；
- 主窗口/内容透明度；
- 启动页；
- 全局数据刷新周期；
- 主入口/主面板锁定；
- 刷新、重载、恢复布局、出厂重置；
- 跳转 HUD / Module / Tool / Diagnostics 的管理入口。

### Feature Page

- 跑商：排序、自动刷新、刷新周期；
- 活动：提醒模式、恢复隐藏；
- 任务：完成项显示、仅未完成、自定义 dailyTracking；
- 寻宝 / 钓鱼：各自在对应页面管理运行状态；
- 债券：继续由 Resident/HUD 已有筛选 Authority 管理。

### HUD Manager

只负责 HUD 显示、位置、尺寸、编辑状态和 HUD Presentation 设置，不再从“全局设置/实用工具”重复暴露一套按钮。

## 5. 实用工具职责

旧“我的常用”页面改为“实用工具”。不再重复左侧导航和 HUD 快捷开关。

当前只保留有真实上下文价值的工具：

- 传送门显示选项；
- 拍卖收藏夹；
- 制作台助手；
- 整理背包跳转。

跑商路线收藏与拍卖收藏属于各自业务工具，不属于 UI 导航 Favorites。

## 6. Module Center 职责

“模块管理”改为“功能开关 / 方案”。

- 只控制 Runtime 生命周期和 Feature/Combo Profile；
- 每行明确显示模块类别；
- 移除导航收藏按钮，避免再次制造第二套入口体系；
- 具体设置仍跳回对应 Feature Page；
- 关闭模块不删除配置、统计或 HUD 长期偏好。

## 7. V3 迁移边界

V3 Foundation 已在 `toc.g` 加载，但当前 `rs_v3_shell.lua` 只支持：

- `foundation:probe`
- `page:foundation`

其它业务路由仍返回 `route_not_implemented`。

因此本轮不把 V3 强制切为默认 Host。现役 Legacy Host 先消费统一 `UICatalog`，保证玩家功能完整；后续 V3 实现业务路由时应复用同一 Catalog，不再重新定义一份导航树。

## 8. 性能约束

本轮没有新增轮询、Tick、Native API 扫描或第二份数据缓存。

- 首页删除一份 Event reminder 投影和对应 TableView；
- 活动完整页继续使用虚拟 TableView；
- 首页活动池上限固定 12；
- 任务首页不再因 `dirty.events` 重建 dailyTracking 表；
- Feature 设置只修改现有 State/Service 配置，不新增 Scheduler Authority。

## 9. 后续 UI 重构顺序

在此 Catalog 基线上继续迁移时，建议顺序：

1. 把 Life/Combat Workspace 的公共 Header、Toolbar、Table Filter 收敛为标准组件；
2. 逐个统一 HUD Chrome，但保留“列表型 HUD”和“单目标实时 HUD”两类不同模板；
3. 把 Professional Page 的高级设置从旧嵌套页拆成 Feature Workspace 内部 Section；
4. V3 Host 实现完整 semantic routes 后，再进行 Host 切换；
5. 最后删除只承担回滚用途的旧 Presentation 文件。

禁止在 V3 路由未完成时先删除 Legacy Presentation。

## 10. 本轮静态验证

- 12 个修改/新增 Lua 文件通过 Lua `loadfile` 编译级语法检查；
- UI Catalog 独立运行验证：5 个一级分组、18 个稳定页面、无重复 Page Key；
- Settings Registry 路由验证：活动/跑商/债券/任务/寻宝/钓鱼均指向自己的 Feature Page；
- 旧导航 Favorites 文案静态 Fence：`我的常用 / 常用入口 / 尚未添加常用入口` 为 0；
- 现有 `UIAcceptance:RunMatrix()` 纯布局矩阵：90 cases / 0 failures / 0 warnings；
- 1024×768、Addon Scale 120%、Font Scale 150%、最小主窗口场景：content 440.4×642.0，nav 199.2，0 overflow flag。

该验证不替代 ArcheRage RU 客户端中的真实点击、拖拽、Dropdown 层级和 HUD 生命周期回归。
