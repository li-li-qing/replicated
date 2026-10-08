# Phase 0 第六轮：可信基线闭合报告（2026-09-28）

Build: `v3-m1.16.0.18.330-phase0-trust-baseline`
范围：Phase 0（可信基线 / Native Dependency Ownership / Release Gates）。**未进入 Phase 1。**

---

## 0. 一句话结论

Phase 0 的三项“此前无本地证据”的硬门禁全部取得真实证据并通过；默认 Full Runner 首次端到端 PASS。
§22.5 的七条 Exit Criteria 全部满足，Phase 0 闭合，Phase 1 允许开始（本轮未执行）。

---

## 1. 起始核对（先确认累计工作树，再动手）

`git status` + 真实源码阅读确认当前树是累计基线，三轮 Native ownership 修复**都在**：

| 修复 | 位置 | 状态 |
|---|---|---|
| `.327` life_trade 自己拥有 X2Craft / X2Auction / X2Store / X2Ability / X2Equipment | `features/life/rs_life_m16_bundle.lua` Trade.ApiDependencies | 存在 |
| `.328` life_bonds 自己拥有 X2Resident / X2Bag / X2Quest | 同上，Bonds 段 + `features/rs_feature_registry.lua` | 存在 |
| `.329` combat_buff_display 声明 X2Ability / X2Equipment（且**未**把 GearV3 的 X2Bag/X2Player 升级为 required） | `features/rs_feature_registry.lua:260` | 存在 |

`S.BuildTag` 起始为 `v3-m1.16.0.18.329-native-dependency-policy`，与执行版文档一致。没有出现“只覆盖最后一个补丁”的情况，无需恢复基线。

---

## 2. 门禁从 BLOCKED 到 PASS 的三项关键突破

### 2.1 真实 Lua 5.1 工具链一直存在，只是没进门禁 PATH

```text
C:\Users\llq\.workbuddy\binaries\luabin\
  lua5.1.exe / luac5.1.exe / lua51.dll / lua.exe / luac.exe
```

`luac5.1.exe -v` → `Lua 5.1.5  Copyright (C) 1994-2012 Lua.org, PUC-Rio`

```bash
export PATH="$HOME/.workbuddy/binaries/luabin:$PATH"
python tools/rs_lua51_compile_gate.py
# PASS: Lua 5.1 compile gate: 261 shipped Lua files (…\luabin\luac5.1.EXE)
python tools/rs_status_refactor_test_runner.py --syntax
# SYNTAX PASS: 380 Lua files (runtime=Lua 5.1)
```

**没有修改门禁脚本的判定条件**，也没有把 5.4 结果标成 5.1。侧收益：整套离线回归现在跑在真实 Lua 5.1 上，而不是 5.4 兼容垫片。

### 2.2 两个历史证据 fixture：byte-for-byte 从归档恢复

扫描 `C:\Users\llq` 下 495 个 zip 的 namelist（只列命中，不解压整包）：

```text
C:\Users\llq\Downloads\ReplicatedSuite_18.244_full_project.zip
  replicatedsuite/tools/fixtures/trade_native_numeric_20260912.lua
  replicatedsuite/tools/rs_status_schema5_fixtures.lua
```

| fixture | bytes | SHA-256 | zip mtime | 自述内容 |
|---|---|---|---|---|
| `tools/fixtures/trade_native_numeric_20260912.lua` | 1361 | `4be7953019415b56b97470114df979082ba8a5d75ba097d876e67f506948cf04` | 2026-09-12 04:36 | “User-provided RS-FOCUS-1 ID=1.1；LoadData 快照，不是 authenticated pre-save 快照” |
| `tools/rs_status_schema5_fixtures.lua` | 23180 | `b160de4f8fb4c5b604fd95b64fb16e9eadd14646c80e6154d7c06a165a711a0d` | 2026-09-12 00:00 | “由 .18.208 原始 Store 生成的合成 schema5 兼容样本；历史 canonical/hash 金样，不得随新 normalizer 重新生成” |

恢复方式：从 zip 直接写原始字节，未格式化、未重新序列化、未按 expected 反推。
二者都**不在** `toc.g`，属离线测试资产。恢复后 `rs_test_dependency_audit.py` 由 BLOCKED 变 PASS。

**fixture 版本正确性的额外证明**：测试 `schema5 loads through real integrity verifier and restamps schema8`
用 fixtures[2] 的 raw + 其自带 fingerprint，在**当前** production canonical 计算下校验通过 ——
说明 fixture 与当前代码的 canonical/normalizer 仍自洽，不是过期样本。

### 2.3 X2Skill numeric API_TYPE = 35（真实 ABI 证据）

资产：

```text
C:\Users\llq\Downloads\Addon.zip!globals/apitypes.lua        SHA-256 df8475b7cb31…
C:\Users\llq\Downloads\Addon(1).zip / Addon(2).zip          同一副本
C:\Users\llq\Downloads\Addon1.2.zip!globals/apitypes.lua     SHA-256 08d3f2383908…
```

关键行（两个独立归档版本都有）：

```lua
API_TYPE = {
    ...
    CHAT         = { id = 8,  apiname = "X2Chat" },
    SIEGE_WEAPON = { id = 34, apiname = "X2SiegeWeapon" },
    SKILL        = { id = 35, apiname = "X2Skill" },   -- ← 第 82 行
    UNIT         = { id = 42, apiname = "X2Unit" },
    ...
}
```

交叉验证（这是“不是猜数字”的核心）：

```text
把该文件的 (id ← apiname) 与本工程 native/rs_native_contract.lua 已核的 24 个 namespace 对齐：
  matched = 24 / 24，mismatch = 0，not-in-file = 0
  （UNIT=42、CHAT=8、ABILITY=3、BAG=5、CRAFT=9、EQUIPMENT=13、STORE=37、
    TEAM=38、AUCTION=51、MAP=54、RESIDENT=73、EQUIP_SLOT_REINFORCE=75、BUTLER=82 …）
=> 与当前客户端 ABI 同一世代；对新增行 SKILL 而言是可直接采信的强证据
```

使用侧旁证：

```text
Addon1.2.zip!replicatedsuite/modules/professional/plates/replicatedplates.lua
    function() return ADDON:ImportAPI(API_TYPE.SKILL.id) end,
```

method 权限（第五轮已证）：`X2Skill:GetCooldown / GetMateCooldown / Info / GetSkillTooltip`
—— `z_api_functions/api_functions.lua` 有 X2Skill 段落；`core/rs_api_capabilities.lua` 已登记前两个。

---

## 3. 落地实现（严格限定在 §22.2 允许范围）

```text
native/rs_native_contract.lua            + SKILL = { id = 35, nativeName = "X2Skill", feature = true }
services/rs_cooldown_observation_v3.lua  + C:EnsureNativeSkillLease()，在 AcquireConsumer 时取得 owner
services/rs_skill_metadata_v3.lua        + M:_EnsureNativeSkillLease()，在 native 明细路径取得 owner
tools/rs_cooldown_observation_tests.lua  + lazy ownership 覆盖（取得一次 / 幂等 / 失败 fail-soft）
```

设计要点：

```text
- owner 由 Service 自己持有（service.cooldown_observation_v3 / service.skill_metadata_v3），
  不再让 BuffDisplay / DPS / combat_stats 等消费者代为 Import；
- 没有 consumer / 缓存命中 / 无 skillId 的路径完全不 Import（保持按需加载）；
- 取得失败只写 nativeSkillLeaseState / nativeSkillLeaseError，返回 false 并继续原有降级路径（fail-soft）；
- 不实现不存在的 Native Unimport（ImportAPI 是进程级、不可撤销）；
- S.ApiImports / S.NativeImports 仍是唯一 ImportAPI Authority，没有第二套 registry。
```

诊断可见性：两个服务的 `GetHealth()` 新增 `nativeSkillLease / nativeSkillLeaseState /
nativeSkillLeaseError / nativeSkillOwner`，且**不触发**任何新的 Native 读取。

结果：`Native Dependency Audit` 由 `0 ERROR / 1 BLOCKER / 0 WARN` 收敛为 `0 / 0 / 0`，
`contract_namespaces` 24 → 25。

---

## 4. fixture 恢复后暴露的 20 项失败：逐项分类与处理

默认 Runner 第一次跑到文件末尾后，暴露出此前被“提前阻断”掩盖的失败。全部按 §30 决策树分类，
**没有一处采用 `expected = actual`**，也没有放松任何安全断言。

### 4.1 分类结论表

| # | 现象 | 分类 | Authority 依据 | 处理 |
|---|---|---|---|---|
| 1 | `unknown old fingerprint fails closed…` 中 `write fence bypassed` | B 测试过期 | `.18.243` 起旧 `v3.buff_display` 降级为 LegacyMigrationSourceOnly（`rs_buff_display_store.lua:2857` 的 Runtime Authority 注释 + README §3.7）：manifest 已建立后旧 key 只作证据 | 保留 `not ok` + `writeFenced` + 磁盘字节保护；把“写保护不得绕过”改为在真正的 Authority（tracking manifest 提交点）上验证 |
| 2 | `sequence recovery cannot authenticate changed tracked content` 附带断言 | B 测试过期 | 同上 | 删除已失效的附带断言，注明改由 #1 覆盖 |
| 3 | `writes==before+1` | B 测试过期 | 同上文件顶部已有 `.18.243+` 四写事务断言 | 断言“恰好一个 tracking generation”（delta=4） |
| 4 | `#library_table.items==393` | B 测试过期 | `data/rs_status_tracking_catalog.lua` v2 的 all 包 = 425 effects（与 `result.total==850` 一致） | 断言“行数 == Authority 包条目数”，并显式 pin 425 |
| 5 | `v3_buff_persistence_report` 找不到 | B 测试过期 | 全仓仅测试引用该 id；当前只读取证入口是 `v3_buff_evidence_export` | 仅更正 id，强度不变 |
| 6 | “损坏存档 ⇒ 只读故障页” 用旧大 Store 构造 | B 测试过期 | 当前决定“状态显示是否可用”的是 tracking manifest（`rs_buff_display_store.lua:2863`） | 改为对 manifest 注入 owner/schema 正确但指纹未知的密封 envelope，并断言页面只读、无编辑器、字节不变 |
| 7 | 同上用例里 `状态显示功能未启用` | B 测试过期（同源） | 损坏目标改到当前 Authority 后页面本就是故障页，不再走 `AcquireConsumer` | 随 #6 一并解决 |
| 8 | unit-lines 15 项全红 | **C 宿主不完整** | `core/rs_api.lua` 的 `CallCapability/CallGlobalCapability` 返回形态是 `ok, value, nil, extra…` | 在 `tools/rs_udf_numeric_test_host.lua` 补齐同形态的只读调用路径（含 `select('#',…)` 保持 embedded nil），不模拟限速 |
| 9 | unit-lines 剩 1 项（world fallback 负深度） | **C 宿主不完整** | 同上（`ProjectWorld → ConvertWorldToScreen` 走 `CallGlobalCapability`） | 同上，补齐后 43/43 PASS |
| 10 | home 15 项全红（`ModuleDiagnosticsButton`/`SetViewportVisible`） | **C 宿主不完整** | 真实页面依赖 `UIV3Design:ModuleDiagnosticsButton`（`ui/design_system/rs_ui_design_system_v3.lua:80`）与 RSUI 组件 `Base:SetViewportVisible`（`rs_ui_component_core.lua:910`） | 补齐；并**恢复 `rs_gear_page_test_host.lua` 加载真实 RSUI 框架 + 真实 DesignSystem 的版本**（此前的纯 Node mock 版本使布局/表格类套件不可能通过） |
| 11 | home 剩 6 项（内容卡命令缺失） | **C 宿主不完整** | 内容模块要求 `SetViewMode/ToggleTrackedProduct/QuoteRowMaterials/SetDisplayOrder/SetFilterMask/SetDuplicateMode` 与 `GetDisplayOrderKey/GetFilterMask/GetDuplicateMode`，均已在 `features/life/rs_life_m16_bundle.lua` 确认存在（`.298` 之后的命令集） | 只在宿主补桩 |
| 12 | home 剩 1 项 + overview-v2 1 项：`v3_home_trade_quote` | B 测试过期 | `rs_v3_life_economy_widgets.lua:105` “构建和刷新绝不发出材料询价”、`:443` 只要求单行询价；批量/高级询价在 `rs_v3_business_pages.lua:1002` / `rs_v3_life_m16_pages.lua:198`。核对 `.298` 归档模块后发现当时同样没有该控件 | 改为断言“首页卡不伪造批量/高级询价入口 + 构建/激活不发出询价”，保留原有安全意图 |
| 13 | `integrity probe distinguishes executed historical hook…` 等 12 项 teardown 失败 | **级联** | #1 的 `assert` 抛出后 `Reset` 之前的磁盘残留未恢复，污染后续用例 | #1 修复后全部自动消失，无需单独改 |

### 4.2 生产代码只在两处被改动（均为 FND-016 收口），未动任何业务算法

```text
services/rs_cooldown_observation_v3.lua   +38 行（state + EnsureNativeSkillLease + AcquireConsumer 钩子 + health）
services/rs_skill_metadata_v3.lua         +35 行（state + _EnsureNativeSkillLease + 明细路径钩子 + health）
native/rs_native_contract.lua             +10 行（SKILL 行 + 证据注释）
```

`replicatedsuite/tools/**` 之外的业务文件（`rs_business_bridge.lua`、`rs_life_m16_bundle.lua`、
Scheduler / EventBus / Persistence / Presentation / Store schema）本轮**零修改**。

---

## 5. 最终门禁（真实执行，未执行项一律不写 PASS）

```text
Install Integrity         PASS  261/261，0 conflict
Native Dependency Audit   PASS  0 ERROR / 0 BLOCKER / 0 WARN（registry=42 impl_overrides=28 services=16 contract_namespaces=25）
Architecture Audit        PASS  49 既有债务（41 CORE_FEATURE / 5 PRESENTATION_STATE / 3 GIANT_FILE），无新增
Test Dependency Audit     PASS  25 reachable files
Lua compatibility syntax  PASS  380 Lua files（runtime = 真实 Lua 5.1.5）
Lua 5.1 Compile Gate      PASS  261 shipped Lua files（luac5.1）
Unfinished Closure        PASS  14 isolated suites
Cooldown 专项             PASS  COOLDOWN_OBSERVATION_V4（含新增 lazy ownership 用例）
默认 Full Runner          PASS  exit=0，0 FAIL、0 BLOCKED
```

命令（可复现）：

```bash
cd replicatedsuite
export PATH="$HOME/.workbuddy/binaries/luabin:$PATH"
python tools/rs_check_installation.py .
python tools/rs_native_dependency_audit.py
python tools/rs_architecture_audit.py
python tools/rs_test_dependency_audit.py
python tools/rs_status_refactor_test_runner.py --syntax
python tools/rs_lua51_compile_gate.py
python tools/rs_status_refactor_test_runner.py --unfinished-closure
python tools/rs_status_refactor_test_runner.py --cooldown
python tools/rs_status_refactor_test_runner.py
```

---

## 6. 未解决 / 不阻断 Phase 1 的项

```text
1. X2Skill 的 RU 实机行为验收（不是 ABI 问题，是运行期问题）：
   - 只开 BuffDisplay 时 cooldown 冷读取数是否正常；
   - Fresh Reload 后 lazy owner 是否重新建立；
   - 失败时必须仍是降级，而不是让状态 HUD 初始化失败。
   -> 归入 Phase 3（Native ownership 收口）或用户实机复测清单。

2. Architecture Audit 的 49 项既有债务（Core→Feature 41 项、Presentation→State 5 项、巨型文件 3 项）
   属于 Phase 3 / Phase 5 / Phase 6 的范围，本轮只要求“无新增”。

3. 文档卫生（非代码问题，需用户决策）：
   - Docs 下 `Replicated_Suite_底层框架重构规划_v1.md` 与
     `Replicated_Suite_#U6434#U….md` 是 82KB 两份内容相同的别名副本（git 里还有第三个已删除的乱码名）；
   - 计划文档在工作树中名为 `…_v1.md`，而 WORKBUDDY_START_HERE.md / DOCS_FILE_INDEX.md 引用的是
     `…_v1_Workbuddy执行版.md`（该文件名不存在）。建议用户统一为一个 Authority 文件名。

4. 运行离线套件会在 `replicatedsuite/tools/` 下产生数据残留
   （`.copy_*.bin/.txt`、`.focus_*.txt`、`.self_check_real_evidence.txt`）。
   其中 `.self_check_real_evidence.txt` 是**被读取**的既有证据文件，本轮运行会重写它；
   其余为纯输出。本轮已把 44 个新增残留移出插件树到 `.workbuddy/tmp/tools_run_artifacts/`，
   并把被重写的 `.self_check_real_evidence.txt` 还原为 HEAD 内容。建议长期由 suite 自行清理或 .gitignore。
```

---

## 7. 下一步

Phase 0 完成，Phase 1 允许开始（本轮未执行）。建议的第一步仍是 §23.4：

```text
features/shared/rs_feature_slice_factory.lua
    -> Batch A: tools_social + tools_market_analysis
```

进入 Phase 1 前必须遵守：每拆一个 Feature 先写契约快照（§23.5），改完对比（§31），
一个 Feature 文件失败不得通过共享 chunk 阻断其它实现，Store ID / Feature ID / route / Commands / Projection 全部冻结。
