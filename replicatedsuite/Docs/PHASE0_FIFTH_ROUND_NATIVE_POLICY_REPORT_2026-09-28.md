# Phase 0 第五轮：Native Dependency Policy 收口

Build: `v3-m1.16.0.18.329-native-dependency-policy`

## 1. 本轮目标

继续执行 FND-016，不进入 Business Bridge 拆分。

本轮只处理已经能由真实代码证明的 Native dependency ownership：

- 补齐 Feature 直接 Native 使用但未声明的依赖；
- 把 Feature → Shared Service 的 Native 依赖区分为 required / optional / lazy；
- 禁止因为 Shared Service 文件里存在其它方法路径，就把全部 X2* namespace 扩成 Feature hard dependency；
- X2Skill 继续保持 BLOCKED，直到取得真实 API_TYPE numeric ABI 证据。

## 2. 实际完成

### 2.1 combat_buff_display 直接依赖补齐

源码确认 BuffDisplay 正式直接调用：

- `X2Ability:GetBuffTooltip`
- `X2Equipment:GetEquippedItemType`
- `X2Equipment:GetEquippedItemTooltipInfo`

Registry 原先只声明 X2Unit 系列，现补齐 X2Ability / X2Equipment。

新增 Standalone Bootstrap hard matrix：

```text
combat_buff_display -> X2Ability + X2Equipment
```

### 2.2 Shared Service Native edge policy

新增首批 proven policy：

```text
combat_buff_display -> GearV3
    required: X2Equipment
    optional: X2Bag, X2Player

combat_buff_display -> CooldownObservationV3
    lazy: X2Skill

combat_stats -> SkillMetadataV3
    lazy: X2Skill
```

意义：

- BuffDisplay 使用 GearV3 的 equipped read，不代表必须硬依赖 GearV3 的 bag/title 方法；
- Cooldown 与 Skill Metadata 只在对应子能力/详情路径执行，不能为了消除静态 warning 强制所有消费者启动时导入 X2Skill；
- lazy capability 应最终由 Shared Service 自己持有 Native lease，而不是由某个 Feature 偶然代为导入。

### 2.3 Native audit 结果收敛

第四轮：

```text
0 ERROR / 1 BLOCKER / 4 WARN
```

第五轮：

```text
0 ERROR / 1 BLOCKER / 0 WARN
```

唯一 blocker：

```text
X2Skill
```

原因不是 method 权限未知，而是当前工程仍没有可证明的 `ADDON:ImportAPI` namespace numeric ID。

## 3. X2Skill 证据结论

现有 RU API 资料与公开更新足以证明以下方法已放行：

- `X2Skill:GetSkillTooltip`
- `X2Skill:Info`
- `X2Skill:GetCooldown`
- `X2Skill:GetMateCooldown`

但这些证据不能证明 `ADDON:ImportAPI(<numeric id>)` 中 X2Skill 的 namespace ID。

因此本轮没有向 `rs_native_contract.lua` 猜测加入 X2Skill。

## 4. 验证

- Native Dependency Audit: `0 ERROR / 1 BLOCKER / 0 WARN`
- Unfinished Closure: `14/14 isolated suites PASS`
- Trade Optimization Regression: PASS
- Bonds Auroria Regression: PASS
- Feature Consumer Lifecycle: PASS
- Architecture Audit: 49 known issues，无新增 hard failure
- Lua compatibility syntax: 378 files PASS（Lua 5.4 compatibility runtime）

Phase 0 仍未完成：

1. X2Skill numeric API_TYPE ABI 未验证；
2. 两个历史证据 fixture 仍缺失；
3. 真实 Lua 5.1 compiler gate 仍缺失。
