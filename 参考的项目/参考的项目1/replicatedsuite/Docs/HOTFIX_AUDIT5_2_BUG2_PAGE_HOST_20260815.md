# Audit5.2 Hotfix — Bug2 页面内容错误覆盖主面板

## 问题现象

点击 `HUD / 快捷 / 设置 / 诊断` 等页面后，页面内容直接出现在主窗口左上区域，覆盖导航区，看起来像“内容堆在整张页面上”，而不是进入右侧内容区域。

## 根因

1. 主窗口缺少独立的右侧 `content host` 容器，页面根节点直接挂在主窗口上。
2. 页面根节点没有统一约束在单独内容容器内，布局失败或初始布局未完全生效时，会退回到 `(0,0)` 位置显示。
3. `MainWindow:ApplyLayout()` 对各页面布局没有逐页错误隔离；一旦某个页面布局异常，后续页面可能保持初始位置。

## 修复

- 主窗口新增独立 `main_content_host`，作为右侧内容框唯一父容器。
- `life / activity / combat / modules / hud / quick / settings / diagnostics` 八个页面全部改为挂载到 `content host`。
- 各页面 `ApplyLayout()` 改为相对 `content host` 从 `(0,0)` 布局，不再直接使用主窗口 `contentX/contentY`。
- `MainWindow:ApplyLayout()` 为每个页面增加独立 `xpcall` 错误隔离，避免单页布局异常拖垮整个页面区。

## 影响范围

- 只修复主界面右侧内容区承载方式。
- 不改模块业务逻辑、不改存档 Schema、不改专业模块数据。
