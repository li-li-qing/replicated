# Replicated Suite Phase 0 第四轮：Native Dependency Ownership

## 范围

本轮仍属于 Phase 0。由 `.18.327` 跑商实机 `host_global_missing` 触发 FND-016，目标是把 Feature / Shared Service 的 Native dependency ownership 从“启动顺序碰巧可用”变成可审计契约。

不拆 Business Bridge / Life Bundle，不改 Persistence/Scheduler/EventBus 语义，不改任何 Store ID/Schema。

## 已完成

1. 新增 `tools/rs_native_dependency_audit.py`。
2. `rs_status_refactor_test_runner.py` 新增 `--native-dependency`。
3. 审计范围：42 Registry Features、28 个显式 implementation dependency override、16 个直接使用 Native 的 Shared Services、24 个当前 NativeContract namespace。
4. 首批 Standalone Bootstrap hard matrix 覆盖：
   - `life_trade`：X2Store / X2Ability / X2Equipment / X2Craft / X2Auction；
   - `life_bonds`：X2Resident / X2Bag / X2Quest。
5. 修复 `life_bonds -> QuestProgressV3 -> X2Quest` 隐式借用：Bonds 实现层和 Registry 均声明活动任务索引与完成/可交付状态所需 X2Quest namespace。
6. Build 推进到 `v3-m1.16.0.18.328-native-dependency-audit`。

## 当前审计结论

修复后：

```text
implementation / Registry namespace parity: 0 ERROR
standalone hard matrix: 0 ERROR
NativeContract blocker: 1
warning debt: 4
```

唯一 BLOCKER：

```text
X2Skill
  used by CooldownObservationV3
  used by SkillMetadataV3
  NativeContract has no verified namespace/API_TYPE row
```

当前项目能够证明 RU method capability 存在，但当前交付物内没有可证明 `ADDON:ImportAPI` 的 X2Skill 数字 namespace ID。禁止猜数值加入 `rs_native_contract.lua`。

WARNING（需 required / optional / lazy 分类后处理）：

- `combat_buff_display` 直接存在 X2Ability / X2Equipment fallback/诊断路径；
- `combat_buff_display -> CooldownObservationV3 -> X2Skill`；
- `combat_buff_display -> GearV3` 的 Native 使用范围需要按实际调用方法切片，而不是把 GearV3 全部 X2Bag/X2Player 依赖直接硬塞给 BuffDisplay；
- `combat_stats -> SkillMetadataV3 -> X2Skill`。

`tools_auction -> DailyAuctionMaterialsV3 -> QuestProgressV3 / TradeMaterialIdentityV3` 也属于后续 service ownership 候选。今日任务标签是子能力，不能为了消灭 warning 把 Quest/Craft 直接变成整个 Auction Feature 的 hard dependency。

## 测试

```text
Native Dependency Audit: 0 ERROR / 1 BLOCKER / 4 WARNING
Unfinished Closure: 14 isolated suites PASS
Bonds Auroria Regression: PASS
Feature Consumer Lifecycle: PASS
Trade Optimization Regression: PASS
Lua compatibility syntax: 378 files PASS (Lua 5.4 compatibility runtime)
Install Integrity: 261/261 PASS, conflict=0
Architecture Audit: 49 known debt, hard failure=0
Default Full Runner: BLOCKED only by 2 historical evidence fixtures
Lua 5.1 Compile Gate: BLOCKED (real compiler unavailable)
```

历史 evidence fixture 仍为：

```text
tools/fixtures/trade_native_numeric_20260912.lua
tools/rs_status_schema5_fixtures.lua
```

## 结论

FND-016 已进入长期规划并建立首个可执行门禁。Trade 与 Bonds 两个已证明的隐式借用已修复。Phase 0 仍不能结束：除历史 fixture / Lua5.1 compiler 外，现在还必须解决或取得 `X2Skill` ImportAPI namespace 的真实 ABI 证据。
