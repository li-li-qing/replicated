# Replicated Suite 重构复核与修复报告

日期：2026-09-30  
基线：`Addon(20260929-172837).zip`  
基线 SHA256：`54e16d9bf2b61691f1b2f3064cbfd264cc40a96f0f7a832d9e9bce46af9a996f`  
补丁标记：`refactor-live-gate-1`；沿用提交包 BuildTag，不制造 Store/schema 升级。

## 结论

本轮确认并修复了验收调用链、默认值恢复、旧测试和文档入口问题，离线回归通过。**这不是“整份重构计划全部完成、RU 实机验收通过”的签字。**

提交包主规划 §19 的状态表把 Phase 0–3 标为完成，Phase 4–7 仍标为未开始；Phase 2 的 Trade 第二轮深拆也保留 RU 前置验收。后面的局部拆分记录和 `architecture audit=0` 不能自动替代这些阶段的 Exit Criteria。本轮没有擅自勾选它们，也没有重做已完成阶段。

当前环境的真实 Lua 5.1 编译门禁明确 **BLOCKED（exit 2）**；实际执行的 Lua 回归/语法检查使用 **Lua 5.4 兼容环境**。未运行 ArcheRage RU 客户端，不能据此声称 Native、帧耗、分辨率或交货价格实测通过。

## 1. 已修复问题与根因

### R1｜高：Buff 验收在冷启动时全部丢失

原 `toc.g` 第 160 行载入 Buff acceptance，FoundationGate 到第 285 行才创建。Buff 文件看到 Gate 不存在就 return，三个 case 根本没有注册。离线测试预先放入假的 Gate，因此没有抓到真实 TOC 顺序问题。

修复：只调整这一条 TOC 的相对位置到 Foundation 后。TOC 成员集合不变，仍是 298 个运行时文件。新增按真实 TOC 相对顺序装载真实 Gate/acceptance 的回归，固定三个 Buff case 都存在。

涉及：`toc.g`、`tools/rs_refactor_live_gate_tests.lua`。

### R2｜高：迁移后的业务门禁没有进入玩家诊断

`core/rs_self_check_report.lua` 的 `RunSelfCheck()` 和 Gate 的 `BuildCopyText()` 都使用 `skipSequences=true`。Phase 3 将 AddCheck 中的业务条件搬成 sequence case 后，这些条件被一起跳过；“sequence 失败也会成为 blocker”只在实际执行序列时成立，不能证明玩家诊断等价。

修复：在原 FoundationGate 的同一注册入口增加可选 `{runtime=true}`。只有逐项审过的只读 case 才声明此资格；业务条件仍由 Feature acceptance 持有，Core 不重新点名业务实现，也不复制一套业务判定。

`RunRuntimeContracts(report)` 调用同一回调的只读模式，分别输出 `runtime_contract:<case id>` 的检查与原因。只接受显式 true；false、nil、异常均失败，单个异常保留原因并且不阻止其他检查。重复注册不会重复计数，取消资格后不再在玩家诊断执行。

本轮接回 **23 份 Feature acceptance 中的 27 项业务检查**。混合型 Activities/Tasks/Bonds 在结构检查后、取得 Consumer 或刷新/选择之前只读返回；Buff/DeathReview 的合成恢复探针与预算/投影压力样本仍留给完整离线序列。DPS 技能归属序列会清空统计，因此明确不进入玩家诊断。

不新增 Scheduler、OnUpdate、Events 或持久化 Authority。新增成本只出现在主动执行诊断时，没有新建常驻轮询任务。

涉及：`core/rs_foundation_gate.lua`、23 份 `*_acceptance.lua`、回归 runner 与新回归文件。

### R3｜高：DPS 实现缺失会导致检查也一起消失

DPS acceptance 原来在文件顶部因 `F == nil` return，无法报告“实现未注册”。Buff 主检查虽然保留了注册，但没有在解引用前明确检查实现缺失。

修复：DPS 缺失仍注册检查；DPS/Buff 主检查给出明确的 `implementation_not_registered`。新增缺失实现矩阵验证全部 27 项检查仍注册且失败，而不是零检查伪装正常。

### R4｜中：通用存档 apply 丢失布尔 false 默认值

`features/shared/rs_feature_slice_factory.lua` 用两层 `and/or` 模拟三元选择。默认值本身为 false 时被转换为 nil；旧保存缺字段时无法按声明恢复 false。这是值语义缺陷，并不意味着本轮已证明玩家某个 UI 故障一定由它引起。

修复：显式判断 `saved == nil` 才读取默认值，再 DeepCopy。保存的 false/0/空串保留；nullable 字段缺失仍清空；默认和已保存表仍是深拷贝，不共享可变引用。

回归覆盖缺字段 + false 默认、显式 false 覆盖 true、0/空串、nullable 清空、嵌套表隔离。未变更 Store ID、schema、字段白名单或写保护逻辑。

### R5｜中：独立测试没有跟随已批准的职责迁移

三个原有 Python 脚本在原包中也失败：

- `rs_bonds_auroria_regression_tests.py`
- `rs_trade_auto_refresh_watchdog_tests.py`
- `rs_trade_optimization_tests.py`

它们继续要求业务字段出现在 Core，和 Phase 3 的职责分配冲突。修复后业务条件查对应 Feature acceptance，Service/UIV3 条件仍查 Core，并断言只读运行时接线仍存在；另补真实 Gate 的旧版本、缺命令、禁止刷新/询价/取得 Consumer 行为测试，不靠删断言变绿。

Trade optimization 还残留 `anomalyRatio=8` 的历史断言。提交包中的服务和 2026-09-28 SWR 行为测试已将其收紧为 2.5，并覆盖 559→1499 的候选、二次确认与回归已知价格。这里只修正过时静态断言，**没有修改服务、材料价格、毛利、新鲜度或跑商公式**。原有 SWR 行为测试另行执行通过。

### R6｜中：Docs 入口指向不存在的主计划，并停留在旧起点

README / WORKBUDDY_START_HERE 使用带 `_Workbuddy执行版` 的文件名，但磁盘实际主计划是 `Replicated_Suite_底层框架重构规划_v1.md`；旧入口还要求从 .329 重做 Phase 0。

修复：三个入口文档统一实际路径，并指向本轮报告和当前待验项。长期主规划及兼容副本没有改写，不创建第二份施工合同，不拿新的复核报告取代原阶段规范。

## 2. 验证结果

| 检查 | 结果 | 边界 |
|---|---|---|
| 默认 Full Runner | PASS，exit 0 | Lua 5.4 兼容运行时；未删 required fixture |
| Feature Split | 66 passed / 0 failed | 原有拆分契约 |
| Core–Feature Decoupling | 128 passed / 0 failed | 原有迁移契约 |
| 本轮 Live Gate 回归 | 17 passed / 0 failed | 真实 Gate/TOC，外部依赖按用例替身 |
| 10 个独立 Python 测试脚本 | 全部 exit 0 | 范围、钓鱼/寻宝、债券、跑商、生命周期、编辑框诊断 |
| Material Price SWR / Backoff / Cache Recovery | PASS | 原有行为脚本；本轮未改其生产实现 |
| Lua 语法 | 420 files PASS | 明确是 Lua 5.4，不是 Lua 5.1 编译 |
| 安装清单 | 298 / 298 PASS | 无缺失、空文件、运行时冲突标记 |
| Architecture Audit | 0 known issues | 规则审计，不是运行正确性的充分条件 |
| Native Dependency Audit | 0 errors / 0 blockers / 0 warnings | 声明一致性，不是 Native 实机认证 |
| Test Dependency Audit | PASS，26 reachable files | 该独立审计入口自身的可达范围 |
| 真正 Lua 5.1 编译 | **BLOCKED，exit 2** | 环境没有 luac5.1 / luac-5.1 |
| RU 客户端运行 | **NOT RUN** | 尚需本地验收 |

先在原包运行本轮最初 12 条回归，结果 2 passed / 10 failed，证明旧的全绿测试确实漏掉本轮问题；最终扩充到 17 条后全通过。原包三个独立脚本的失败日志、原包 Full Runner 日志和最终日志均保留在证据包中。

额外字节比对确认：Persistence 主文件与 Transport、NativeContract、Trade/Bonds 生产实现、MaterialPriceService、历史数值 fixture 和主规划均与提交包相同。TOC 成员只换序，不增删。

## 3. 安装与回滚

这是增量补丁，不是完整插件。先退出游戏，备份当前插件目录及自己的存档。把补丁中的 `replicatedsuite/` 合并覆盖到原 Addon 目录下的同名目录，覆盖包内同名文件；**不要先删除整个旧目录，也不要删除用户配置**。

本轮改了 TOC 顺序，首次验证请完整退出并重新启动客户端，不把仅热重载成功当作冷启动验收。若需要回滚，恢复安装前备份；补丁不迁移存档 schema，不要求清档。

## 4. 本地 Agent 下一步（不扩展重构范围）

先读取实际主规划、本文和当前源码。确认补丁所有文件完整覆盖，再从 `replicatedsuite` 根目录执行并保存完整输出：

```text
luac5.1 -v
lua5.1 -v
python tools/rs_lua51_compile_gate.py
python tools/rs_status_refactor_test_runner.py --core-feature-decoupling
python tools/rs_status_refactor_test_runner.py
python tools/rs_architecture_audit.py
python tools/rs_native_dependency_audit.py
python tools/rs_check_installation.py .
```

不得使用改名的 Lua 5.4 编译器或改 gate 返回码绕过真 Lua 5.1 要求；记录工具真实版本与命令退出码。

RU 冷启动后先运行正常玩家诊断并逐页保留报告。检查能看到本轮 `runtime_contract:` 失败证据（若存在），而不是“序列未执行”就推定健康；确认点击诊断没有清空已有 DPS、改变任务/债券选择、启动刷新/询价、移动 HUD 或写配置。然后验证原有开关、功能方案和重新登录保持配置的行为。

新增检查可能揭露旧版本诊断漏掉的 blocker；遇到它们先保留具体 case ID 和原因，不删除检查、不强改 true、不启动完整破坏性序列来给玩家诊断补数。

本轮没有声称 Phase 4–7 完成。后续推进以原主规划和真实退出条件为准，先交回当前补丁的 Lua 5.1 与 RU 证据，不借此顺手重写价格/存档/调度框架。

## 5. 修改文件

本轮共 **35 个文件**，其中 33 个修改、2 个新增。

| 路径 | 类型 |
|---|---|
| `Docs/DOCS_FILE_INDEX.md` | 修改 |
| `Docs/README.md` | 修改 |
| `Docs/REFACTOR_REVIEW_2026-09-30.md` | 新增 |
| `Docs/WORKBUDDY_START_HERE.md` | 修改 |
| `core/rs_foundation_gate.lua` | 修改 |
| `features/combat/boss_alerts/rs_boss_alerts_acceptance.lua` | 修改 |
| `features/combat/buff_cap/rs_buff_cap_acceptance.lua` | 修改 |
| `features/combat/buff_display/rs_buff_display_acceptance.lua` | 修改 |
| `features/combat/death_review/rs_death_review_acceptance.lua` | 修改 |
| `features/combat/dps/rs_dps_acceptance.lua` | 修改 |
| `features/combat/gear/rs_gear_acceptance.lua` | 修改 |
| `features/combat/healer/rs_healer_aura_acceptance.lua` | 修改 |
| `features/combat/raid_readiness/rs_raid_readiness_acceptance.lua` | 修改 |
| `features/combat/range_assist/rs_range_assist_acceptance.lua` | 修改 |
| `features/combat/target_monitor/rs_target_monitor_acceptance.lua` | 修改 |
| `features/combat/team_tools/rs_team_tools_acceptance.lua` | 修改 |
| `features/combat/unit_lines/rs_unit_lines_acceptance.lua` | 修改 |
| `features/life/activities/rs_activity_acceptance.lua` | 修改 |
| `features/life/bonds/rs_bonds_acceptance.lua` | 修改 |
| `features/life/fishing/rs_fishing_acceptance.lua` | 修改 |
| `features/life/tasks/rs_task_acceptance.lua` | 修改 |
| `features/life/trade/rs_trade_acceptance.lua` | 修改 |
| `features/life/treasure/rs_treasure_acceptance.lua` | 修改 |
| `features/shared/rs_feature_slice_factory.lua` | 修改 |
| `features/tools/auction/rs_auction_acceptance.lua` | 修改 |
| `features/tools/bag/rs_bag_acceptance.lua` | 修改 |
| `features/tools/craft/rs_craft_acceptance.lua` | 修改 |
| `features/tools/market_analysis/rs_market_analysis_acceptance.lua` | 修改 |
| `features/tools/reinforce_analysis/rs_reinforce_analysis_acceptance.lua` | 修改 |
| `toc.g` | 修改 |
| `tools/rs_bonds_auroria_regression_tests.py` | 修改 |
| `tools/rs_refactor_live_gate_tests.lua` | 新增 |
| `tools/rs_status_refactor_test_runner.py` | 修改 |
| `tools/rs_trade_auto_refresh_watchdog_tests.py` | 修改 |
| `tools/rs_trade_optimization_tests.py` | 修改 |

所有文件的原/新 SHA256 以及统一 diff 见证据包 `patch_manifest.json` / `changes.diff`。补丁中的报告与单独提供的 Markdown 是同一内容。
