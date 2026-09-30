# Replicated Suite：两项运行时验收阻断修复

日期：2026-09-30  
补丁标记：`live-contract-state-1`  
基线：`Addon(20260929-172837).zip` **叠加** `ReplicatedSuite_20260930_RefactorReview_Fixes.zip`。  
适用反馈：`BUILD=v3-m1.16.0.18.332-phase2-life-bundle-slice-complete`，`checkCount=177`、`blockers=2` 的六页报告。

## 结论

本次两项 blocker 均能在上述源码基线的离线真实模块宿主中复现：一项将合法的未观察状态当成模块缺失，另一项将内置目录的数据修订号误作固定格式号。**不是通过删除验收、关闭诊断或强行启用功能来消除阻断。**

上轮补丁恢复了这些检查的玩家诊断入口，却漏测了“首领机制从未启动”和“目录已升级至 v2”这两种真实状态。本轮补齐真实模块回归，不再仅凭手工构造的理想实现表判断迁移正确。

本次只改动两个运行时 acceptance 文件，业务实现、配置、存档协议、目录数据、Core、TOC 和 BuildTag 均保持基线字节不变。尚未在 ArcheRage RU 客户端运行本补丁，不能据此宣称整份重构计划或全部功能已完成实机验收。

## 1. 完成内容

### B1：首领机制关闭时误报 `boss_diagnostics_projection_missing`

**实际调用链：**

- `features/combat/boss_alerts/rs_boss_alerts_feature.lua` 的 `BossSyncObservation` 仅在功能启用、有 Consumer、HUD 启用且存在规则需求时启动观察。
- `_bossDiag` 由同文件的 `BossStartObservation` 在取得观察租约、登记任务后首次创建。
- 刚启动客户端且首领机制关闭、或功能已启用但 HUD 被关闭，都可能合法地没有 `_bossDiag`。
- 原 acceptance 无条件要求 `_bossDiag` 是 table，因此把未启动的功能误报为缺失。用户报告中该功能的 `verdict="off"` 与此路径一致；`hud` 字段是另一条 HUD 健康投影，不能与业务观察表混为一谈。

**修复：**保留实现和两项版本门禁，确认 `FeatureHealthProviders` 的诊断提供函数已登记、存在可调用的 `Has` / `Get`。尚未开始观察允许 `_bossDiag=nil`；已经开始观察却缺表仍报原阻断；已有表字段被替换成异常类型也明确阻断。检查不调用 `Get`、不启动功能、不读取游戏事实、不获取租约，也不创建假诊断数据。

**保留的错误证据：**

| 条件 | detail |
|---|---|
| 诊断注册表或提供函数缺失 | `boss_diagnostics_provider_missing` |
| 已经开始观察却没有诊断表 | `boss_diagnostics_projection_missing` |
| 未观察但已有非法类型的诊断值 | `boss_diagnostics_projection_invalid` |
| HUD / 事实桥能力回退 | 原 `hud_contract_version` / `realtime_fact_bridge_contract_version` |

### B2：内置目录 v2 误报 `schema8_tracking_modules_missing`

**实际数据流：**

- `data/rs_status_tracking_catalog.lua` 已声明 `version=2`，并为状态 `853` 声明 `introducedVersion=2`。
- `rs_buff_display_management.lua` 将目录修订号用于内置包增量导入及 `importedPacks` 水位。
- 这不是追踪 Store 的 schema，也不是导入/导出的文本格式版本。
- 原 acceptance 的 `catalog.version ~= 1` 会拒绝正常 v2 目录；在同一真实模块宿主里，仅改变测试状态中的这个值就能越过该误判并完成后续只读检查，证实根因。

**修复：**目录修订号接受有限正整数，独立验证实际消费者依赖的 `ByEffectId`、`ByKey`、`Packs`、`PackOrder` 索引。缺目录、非法修订号、缺索引分别返回明确原因。管理接口、导入命令、预览命令的缺失仍是 blocker。

**没有改变：**Store schema 仍精确要求 8，Transfer 格式仍精确要求 3。生产目录保持 v2，未回退水位、未清空 importedPacks、未重新导入追踪项、未自动补齐用户已经删除的选择。

### B3：回归覆盖补齐

新增 `tools/rs_live_contract_state_tests.lua`，通过真实 Boss Feature/工厂/目录、真实 Buff Store/Feature/目录/UI 声明、真实 FoundationGate 验证上述路径。Native、磁盘及观察事实由受控宿主提供，不能将它当作实机图形和游戏 API 测试。

覆盖范围包括：首领冷启动关闭、功能启用但 HUD 关闭、真实启停再启用、活动中缺诊断表、提供函数丢失、版本回退；Buff 目录 v1/v2/兼容 v3 数据修订、非法修订号、缺索引、缺命令、旧 Store/Transfer；重复诊断不读取或写入存档、不获取租约、不启动观察、不修改目录水位。还验证了 `skipSequences=true` 的正常 Gate 调用仍执行这两个真实 Feature 共三项只读契约。

目录 v1/v3 是在同一消费者结构上注入的修订号边界样本，不是历史目录内容的复原；v2 目录及 853 的 introducedVersion 则来自真实生产源码。

旧 `rs_core_feature_decoupling_tests.lua` 的能力回退宿主补上真实诊断注册表，没有删除旧断言。新增测试接入默认 Full Runner 和 `--core-feature-decoupling`，无需另找隐藏测试入口。

## 2. 修改文件

共 **6 个文件：4 个修改、2 个新增；无删除**。

| 路径（相对 replicatedsuite） | 类型 | 作用 |
|---|---|---|
| `features/combat/boss_alerts/rs_boss_alerts_acceptance.lua` | 修改 | 区分未观察/已观察状态，校验诊断注册 |
| `features/combat/buff_display/rs_buff_display_acceptance.lua` | 修改 | 区分目录数据修订与 schema/格式，补索引检查 |
| `tools/rs_core_feature_decoupling_tests.lua` | 修改 | 补齐 Boss 能力测试宿主的诊断注册 |
| `tools/rs_status_refactor_test_runner.py` | 修改 | 将新回归纳入默认门禁 |
| `tools/rs_live_contract_state_tests.lua` | 新增 | 18 组真实模块/状态矩阵回归 |
| `Docs/LIVE_CONTRACT_BLOCKERS_2026-09-30.md` | 新增 | 本修复报告 |

未改动：`toc.g`、FoundationGate、Feature 工厂、两个 Feature 的生产业务实现、Catalog、持久化主实现与 Transport、跑商公式和材料价格服务。原测试产生的临时 `.copy_*` / `.focus_*` 等文件不进入补丁。

## 3. 性能影响

- **CPU：**只在执行验收时增加少量注册检查和固定四项索引检查；没有增加 Tick、Scheduler 或游戏 API 调用。未提供实机帧耗/耗时测量，不能将其表述为 FPS 优化。
- **内存：**无新增常驻观察缓存或持久化字段；首领机制未启动时不为通过验收而分配诊断表。Buff 的四项索引键临时表仅存在于诊断调用。
- **高频逻辑：**业务观察、HUD 刷新、目录编译及查询路径完全未改；新增测试不进入 TOC。

## 4. 兼容风险与安装

此包是**上轮复核补丁之后的增量补丁**，不是完整 Addon。先退出客户端并备份插件/用户存档，再将 ZIP 内 `replicatedsuite/` 合并覆盖到现有 Addon 下同名目录。不要先删除整个目录，不要清空配置，不需要重新导入 Buff 库。

本次没有 TOC 或 Store 版本升级。完整退出并重新进入客户端后首次验证，可避免旧回调仍在内存中；原 BuildTag 保持 `.18.332` 不变，不能仅用 BuildTag 判断这两个 acceptance 文件是否已覆盖。

回滚使用覆盖前备份。本次未写入或迁移用户存档；若安装后出现别的 blocker，应保留它的具体 ID 和完整报告，不能将所有新阻断一并删除。

## 5. 验证结果与实机建议

### 已执行

| 检查 | 结果 | 边界 |
|---|---|---|
| 新增回归在修复前基线上运行 | 5 组通过 / 13 组失败 | 18 组中包括误报、遗漏反例及错误原因精度，不代表 13 个独立业务缺陷 |
| 新增回归在修复后运行 | **18/18 通过** | 真实生产模块 + 受控外部宿主 |
| 原 Feature Split / Core–Feature / Live Gate | **66/66、128/128、17/17 通过** | 原断言仍保留 |
| 默认 Full Runner | **通过，exit 0** | 含新增回归 |
| 10 个独立 Python 回归脚本 | **全部 exit 0** | 跑商、债券、Consumer、输入/诊断、范围和寻宝/钓鱼 |
| 安装清单 | **298/298** | 无缺失、空文件或冲突标记 |
| Architecture / Native Dependency Audit | **0 已知架构问题；0 错误/阻断/警告** | 静态契约，不代替 Native 实机验收 |
| Test Dependency Audit | **通过** | 该独立审计入口显示 26 个可达文件 |
| Lua 语法 | **421 个文件通过（Lua 5.4）** | **不是 Lua 5.1 编译证据** |
| 真正 Lua 5.1 编译门禁 | **BLOCKED，exit 2** | 环境无 `luac5.1` / `luac-5.1`；尝试取得工具未成功，没有改门禁 |
| 干净基线补丁覆盖验证 | **Full Runner / 语法 / 安装清单均 exit 0** | 原包 + 上轮补丁重新组装，再覆盖本增量包；最终仅更新报告文字，代码与验证副本逐字一致 |
| ArcheRage RU 客户端 | **未执行** | 等待本补丁后的用户复验 |

### 覆盖后必测

1. **保持首领机制关闭**，启动游戏后直接运行玩家诊断；不应再因尚无观察表出现本次首领阻断，且功能不能被诊断自动开启。
2. **首领启用 → HUD 关闭 → 恢复 HUD → 整个功能关闭 → 再启用**，分别诊断；正常状态应通过，关闭后不应新增观察任务或继续计数。
3. **状态显示**：确认自身/目标追踪数量、所选通道、内置包记录和 HUD 校准位置未重置；目录 v2 不应再触发本次 `schema8_tracking_modules_missing`。无需为了测试而重新一键导入。
4. 出现其它具体 blocker 时复制完整分页报告。本次验证目标是修复这两项误报，不把缺失实现、存档异常或版本不兼容伪装成通过。

本地 Agent 可从 `replicatedsuite` 根目录执行：

```text
python tools/rs_status_refactor_test_runner.py --core-feature-decoupling
python tools/rs_status_refactor_test_runner.py
python tools/rs_check_installation.py .
python tools/rs_architecture_audit.py
python tools/rs_native_dependency_audit.py
luac5.1 -v
python tools/rs_lua51_compile_gate.py
```

### 本次未扩大修复范围

用户报告中的单位连线 `partial/degraded`、不可用的目标链端点，以及债券日期 `2026-09-28` 与收支服务器日 `2026-09-30` 的差异，不是上述两项 runtime_contract 的触发条件。仅凭这一份快照不能确定它们分别是未激活/缓存状态还是另一个问题，本次没有猜测修改坐标或日期刷新链路，也没有宣称这些现象已修复。
