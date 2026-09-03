# Audit5.1 Hotfix — Bug1：R 入口触发游戏 UI 重载

## 实机现象

进入游戏后只看到浮动 `R`。点击后客户端执行一次 UI/插件重新载入，随后 Suite 没有正常出现。

## 根因链

Audit5 将 bootstrap `R` 在 `S.Ready ~= true` 时接到 `ForceUiReload()`；该函数通过切换 `r_VSync` 制造所谓“安全 UI 刷新”。RU ArcheRage 实机证明该受限 Console Variable 的变化可能触发真实 UI reload，因此该方案不成立。

同时 Audit5 的 `Runtime:Start()` 在进入统一 `xpcall` 之前执行了 `Storage:Load()` 与 Layout 初始化。如果真实旧存档迁移或布局初始化抛出异常，Runtime 会在发布 `BootError` 之前中断，只留下 bootstrap `R`，从而进入上述错误重载链。

## Audit5.1 修复

1. 完全移除 Suite Recovery 对 `r_VSync` 的读写。
2. `R` 左键只允许：
   - Runtime Ready：打开/关闭 Suite 主窗口；
   - Runtime Not Ready：显示已有诊断页并向系统聊天输出 BootStage/BootError。
3. `R` 右键不再执行任何重载；Ready 时只提示该入口不再重载游戏 UI。
4. 原 `ForceUiReload` 名称仅保留为兼容别名，实际行为改为 Suite 内部数据/布局刷新。
5. 设置页“重新加载所有配置”改为“刷新数据 / UI”，仅执行 Suite 数据刷新与响应式布局，不触碰客户端 reload/console variable。
6. Runtime 启动从 `Storage:Load()` 开始全部纳入统一阶段化错误栅栏。
7. 新增 BootStage：`api_validate / storage_load / layout_prime / hud_create / shell_create / event_bus_start / scheduler_tasks / scheduler_start / modules_start / refresh_settings / initial_snapshot / bootstrap_warmup / layout_finalize / esc_register / ready`。
8. 启动失败时重新接管 R 为诊断入口，防止部分 UI 创建后留下旧 handler。

## 实机优先验证

1. 覆盖本版后进入游戏。
2. 单击 R：**不得再出现游戏 UI reload**。
3. 正常情况下应直接打开 Replicated Suite。
4. 如果仍未打开，请记录聊天栏中的：`初始化失败 [阶段]：...` 或 `Suite 尚未就绪；阶段=...`。该信息即可定位剩余启动失败。
5. 若 Suite 正常打开，在“设置”点击“刷新数据 / UI”，确认只刷新 Suite，不重新载入游戏 UI。

## 静态门禁

- Suite Lua：104
- Lua 语法失败：0
- TOC 缺失：0
- `ADDON:ReloadAddon()` 调用：0
- `SetConsoleVariable("r_VSync", ...)` 调用：0
- `GetConsoleVariable("r_VSync")` 调用：0
