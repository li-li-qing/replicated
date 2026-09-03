# Audit5.3 Hotfix — 恢复游戏内插件代码重载

## 用户反馈

Audit5.1 为修复 R 左键误触完整 UI reload，撤掉了旧刷新链；结果开发时覆盖 Addon 目录中的最新 Lua 文件后，游戏内没有明确入口重新读取磁盘代码，只能退出角色/重新进入。

## 修复原则

将三个概念彻底分离：

1. **R 左键**：只打开/关闭 Replicated Suite；永不重载代码。
2. **刷**：只刷新 Suite 当前内存中的数据与 UI 布局；不重新读取 Lua 文件。
3. **载 / 重载插件代码**：显式调用官方允许的 `ADDON:ReloadAddon(name)`，从磁盘重新加载当前 `replicatedsuite`。

R 右键保留为紧急/开发代码重载入口，便于后续某个页面或 Runtime 启动失败时，覆盖修复文件后仍能在游戏内再次加载。

## 重载安全栅栏

代码重载不是直接在按钮回调中执行：

- 先保存脏配置；
- 创建独立一次性 `code_reload_host`；
- 等按钮回调返回后再进入重载阶段；
- 调用 `Runtime:Stop()`，停止 ModuleManager、事件、Scheduler 和 Suite UI；
- 再调用 `ADDON:ReloadAddon(currentAddonName)`；
- 每个 generation 只有一个 Code Reload Authority，禁止快速重复触发；
- 新 generation bootstrap 会主动释放旧 reload host 并清除 pending gate；
- 如果发出 ReloadAddon 后 3 秒当前 generation 仍未被替换，则判定未生效并尝试恢复旧 Runtime，避免黑屏/空 UI。

## UI

主窗口标题栏现在明确区分：

- `刷`：数据/UI刷新
- `载`：重新读取插件代码
- `动/锁`
- `—`
- `×`

设置页最后一行改为：

- `刷新数据 / UI`
- `重载插件代码`
- `恢复默认布局 / 大小`

同时保留 Audit5.2 的 `main_content_host` 页面隔离修复。

## 验证

- 104 个 Suite Lua：语法失败 0
- TOC 111 项：缺失 0
- VSync 重载调用：0
- `ADDON:ReloadAddon` Runtime 调用：1 个，唯一入口在 `ReloadCodeFromDisk`
- R 左键不会进入 ReloadAddon：PASS
- R 右键显式进入代码重载：PASS
- 标题栏“刷/载”分离：PASS
- 设置页“刷新数据/UI / 重载插件代码”分离：PASS
- Reload 延迟、Runtime Stop、下一 generation pending gate 清理行为仿真：PASS
- Audit5.2 右侧 `content host`：保留
