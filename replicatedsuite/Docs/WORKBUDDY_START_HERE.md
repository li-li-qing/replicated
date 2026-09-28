# Workbuddy / DeepSeek 4.1 — Replicated Suite 重构启动提示词

你现在负责继续维护并执行 **Replicated Suite 底层框架重构**。

## 唯一主计划

先完整阅读：

```text
Replicated_Suite_底层框架重构规划_v1_Workbuddy执行版.md
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

## 当前起点

当前累计施工基线应为：

```text
v3-m1.16.0.18.329-native-dependency-policy
```

它必须累计包含：

```text
.327 Trade 自己拥有 X2Craft / X2Auction Native dependency
.328 Bonds 自己拥有 X2Quest Native dependency
.329 BuffDisplay 直接 Native dependency + required/optional/lazy policy
```

注意：这些是连续增量修改。不要拿最后一个 patch 覆盖旧工程后就认为当前树完整。

**必须以我当前本地实际项目文件为准。**

## 执行方式

1. 先读取真实源码、toc、Registry、FeatureRuntime、相关 Services、测试与当前 git/worktree 状态。
2. 先按执行版文档的 P0-A 重建 baseline，不要直接开始重构。
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

## 当前 Phase 0 已知剩余硬门禁

```text
1. X2Skill numeric API_TYPE ABI 真实证据
2. tools/fixtures/trade_native_numeric_20260912.lua 原始历史 fixture
3. tools/rs_status_schema5_fixtures.lua 原始历史 fixture
4. 真实 luac5.1 / luac-5.1 compile gate
```

找不到真实证据时必须保持 BLOCKED，不允许猜测绕过。

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

现在开始：**先完整阅读主计划与当前本地代码，执行 Phase 0 的 baseline 重建，然后按执行版继续。**
