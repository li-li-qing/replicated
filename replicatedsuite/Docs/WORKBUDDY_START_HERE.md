# Workbuddy / DeepSeek 4.1 — Replicated Suite 重构启动提示词

你现在负责继续维护并执行 **Replicated Suite 底层框架重构**。

## 唯一主计划

先完整阅读：

```text
Replicated_Suite_底层框架重构规划_v1.md
```

这份文档是本轮施工的唯一主计划和边界合同。

不要只读取 Phase 标题；必须同时阅读：

```text
21. 本地 Agent 施工总规范
22. Phase 0 剩余工作
23~29. 各后续 Phase 施工手册
30. 测试判定规则
31. Feature 前后对照模板
32. 最终交付要求
33. 自动执行策略
```

## 当前起点（2026-09-30 复核后）

先读 `REFACTOR_REVIEW_2026-09-30.md`，再对照本地主规划和真实代码；不要重演旧入口的 Phase 0 开工流程。

本轮审查基线是 `Addon(20260929-172837).zip`，提交包 BuildTag 为 `.18.332-phase2-life-bundle-slice-complete`。
已叠加 `refactor-live-gate-1` 复核补丁：修复验收加载顺序、接回 27 项只读业务检查、缺失实现漏检与 false 默认值恢复。
这是缺陷修复，不是新的存档版本；BuildTag 未人为升级，补丁范围见复核报告与 SHA256 清单。

主规划现有状态表把 Phase 0–3 标为完成、Phase 4–7 标为未开始，Phase 2 深拆仍有待验项；不要因为架构 audit 为零就把整份规划勾完。
先完成当前补丁的真实 Lua 5.1 编译与 RU 实机只读诊断回归。既有历史报告不能代替当前字节的验证，也不要从旧 .329 基线覆盖回来。

## 执行方式

1. 先读取真实源码、toc、Registry、FeatureRuntime、相关 Services、测试与当前 git/worktree 状态。
2. 先验证当前提交包与复核补丁的累计 baseline，不重做已完成的 Phase；未过验收不得进入下一阶段。
3. 按文档规定的 Phase / Work Package 顺序持续执行。
4. 普通文件读取、搜索、编译、测试、git diff 等本地只读/正常开发命令无需反复向我询问确认；在已有权限允许范围内直接执行。
5. 不要每完成一个小修改就停下来汇报。一个 Work Package 完整完成并验证后继续；命中 STOP 条件才停止。
6. 不要因为任务长就扩大范围，也不要因为方便而跳过门禁。

## 绝对禁止

- 不猜 Native API / API_TYPE 数字；尤其禁止猜 X2Skill numeric id。
- 不暴力枚举 ImportAPI id。
- 不删 Full Runner required fixture 来制造绿色。
- 不根据测试 expected 反造历史 fixture。
- 不把 Lua 5.4 syntax PASS 当成 Lua 5.1 compile PASS。
- 不改 Store ID / Schema 来配合源码移动。
- 不改变用户旧配置兼容性。
- 不顺手修改 Trade 售价、货率、freshness、材料报价算法。
- 不顺手重写 Persistence / Scheduler / EventBus。
- 不新增第二个 OnUpdate / Scheduler / EventBus / Persistence / Native Import Authority。
- 不通过 raw global 绕过 Native dependency ownership。
- 不把 optional/lazy capability 为了消 warning 全部升级成 Feature hard dependency。
- 不使用 `git reset --hard`、`git clean -fd` 或覆盖我的未提交修改。

## 当前复核待验项

本地必须运行真实 `luac5.1` / `luac-5.1` 编译门禁及默认回归，并交回命令、版本和退出码。
本轮离线环境只有 Lua 5.4 兼容运行时，真实 Lua 5.1 门禁明确 BLOCKED；不能改脚本绕过。
RU 实机需要冷启动后检查诊断不会取得 Consumer、刷新行情、清空 DPS 或写入配置，再验证原功能正常。

Phase 0 的 Native ABI 与历史 fixture 闭合证据保留在主规划 §22 及第六轮报告中，本轮未篡改这些文件；不要再把旧入口中的三项缺件视为当前已证实缺失，也不能拿历史闭合冒充当前编译通过。

## 测试失败处理

任何失败先判断：

```text
生产回归？
旧测试断言漂移？
test host 缺正式接口？
pre-existing failure？
```

只有有真实 Authority/历史证据时才允许更新测试。禁止 `expected = actual` 式修测试。

## 跨 Phase 规则

```text
当前 Phase Exit Criteria 全部满足
    -> 才允许进入下一 Phase
```

不能以“应该没问题”“以后补测试”“这个 blocker 和下一阶段无关”为理由自行跨 Phase。

## 最终交付

完成一个 Phase 或命中 STOP 时，一次性输出：

1. 完成内容
2. 修改文件（新增/修改/删除）
3. 性能影响
4. 兼容风险
5. 测试结果（必须写具体命令与 PASS/FAIL/BLOCKED）
6. 未解决阻断
7. 规划文档状态更新

同时保留并交付：

```text
完整当前工程
更新后的主规划文档
测试日志
changed files / git diff 证据
本轮 Agent 报告
```

现在开始：**先阅读本轮复核报告、主计划和当前代码，完成当前补丁的 Lua 5.1 与 RU 验收，再按真实阶段状态继续。**
