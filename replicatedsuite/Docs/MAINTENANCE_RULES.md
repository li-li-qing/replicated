# Replicated Suite 长期维护强制规则（修改前必读）

> **Authority: MANDATORY**
>
> 从 `v3-m1.16.0.18.190` 起，任何 AI、Agent、维护者在开始修改 Replicated Suite 之前，必须先阅读本文件与 `CURRENT_ARCHITECTURE.md`。`.18.191` 再次确认：**“已阅读本文件”属于每轮修改的发布前置条件，不得因为任务看似局部而跳过**。若本文件与用户当轮明确要求冲突，以用户当轮要求为最高优先级，并在同一轮同步修正文档。

## 1. 中文代码注释强制规则

- 从 `.18.190` 起，**所有新增或修改的代码行都必须附带中文维护注释**。
- 注释必须说明该行为什么存在、属于哪个 Authority/生命周期/安全边界，以及未来修改时不能破坏什么；禁止只写“赋值”“调用函数”“结束判断”这类无信息量注释。
- 对 `if / for / while / function / return / end / else / elseif` 等控制流行，也应在该行或紧邻位置写清楚中文语义；新代码不得以“语法很简单”为理由省略。
- 未被本轮修改的历史代码不要求为了满足注释规则而全仓机械重写；一旦某行在后续轮次被修改，就必须同时补齐详细中文注释。
- 注释不能代替架构契约。关键规则仍必须同步写入 `CURRENT_ARCHITECTURE.md`、对应 Architecture 文档、CHANGELOG 与验收文档。
- 注释不得引入 Tick、轮询、日志洪泛或运行时分支；注释只服务长期维护，不改变性能模型。

## 2. 修改前阅读顺序

每次修改前至少按以下顺序检查：

1. `Docs/MAINTENANCE_RULES.md`
2. `Docs/CURRENT_ARCHITECTURE.md`
3. 与目标模块直接相关的 `Docs/Architecture/*.md`
4. `z_api_functions/api_functions.lua` / `z_api_functions/ui_functions.lua` 中对应 RU API 证据
5. 真实运行代码与调用链
6. 相关 Harness / Foundation Gate / Acceptance

禁止根据文件名、旧版本描述或历史聊天直接猜测修改。

## 3. UI 坐标强制规则

- ArcheAge RU UI 使用左上角为 `(0,0)`，X 向右为正，Y 向下为正。
- 所有 detached Popup 必须经过统一 Popup Positioning Authority。
- `.18.191` 起，**Suite-owned detached Popup 的最终位置禁止再由插件反推 UIParent 绝对坐标**：顶层 transient Window 必须通过 Native `AddAnchor`/`UI:EnsureAnchor` 直接相对 Trigger Native Widget 锚定；`NativeStateCache` 完整父链/Effective Geometry 仅可用于诊断、尺寸预算或外部原生控件，不再拥有 Suite-owned Popup 的最终位置。
- 显式鼠标/屏幕点 Popup 仍属于 `popup-point` 车道，可使用一次 viewport-logical 绝对坐标；真正的外部原生控件才允许进入 Effective Geometry 校准车道。
- 相对 Trigger Anchor 完成后，屏幕边缘适配优先使用 RU 已验证 `UIBounds:CorrectOffsetByScreen()`；禁止业务页面为 1024/1280/1920 等分辨率各写一套 magic offset。
- 禁止业务模块手写固定分辨率偏移、`x * uiScale`、`x / uiScale`、Shell origin 拼接或 1920×1080 比例换算。
- 世界投影、外部游戏窗口跟随、持久化窗口与 detached Popup 属于不同坐标 Authority，不得为了“统一”混用。

## 4. 发布前最低门禁

- 运行全部项目 Harness。
- Foundation Audit 必须通过。
- Lua Parse / TOC 双向完整性必须通过。
- 涉及持久化时必须检查 Schema / migration / fingerprint 兼容。
- 涉及 UI 时必须至少覆盖 1024×768、1280×768、1366×768、1920×1080 的逻辑验收矩阵，并在 RU 实机继续验证。
- 涉及 detached Popup 时，发布前必须同时验证“`RSUI Popup定位` 可见按钮 + 可复制专项报告”；如果修复仍失败，下一轮必须先读取该报告中的 Trigger/Popup Native 原始几何再修改，禁止继续只凭截图猜坐标。
- 未完成最终门禁时不得把中间包描述为最终可测试版本。
