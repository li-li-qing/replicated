# 制作成本与材料状态实施台账

原始需求及范围以本对话用户明确要求实施的完整方案为准。协作等级 A；实施阶段不提交、不推送、不发布。2026-10-28 用户随后明确要求“提交推送吧”，授权提交本轮制作功能并推送到现有 origin/main，保留其它未提交工作。

## 基线与约束

- 基线 HEAD：99ff637a2262d48906117f9e3a4bb77791276d76，当前 main。
- 本功能开始前已有 Craft Domain、Feature、小窗和测试的未提交修改；它们属于输入，保留并在其上增量修改。宝藏、钓鱼及其它改动不属于本次。
- 准备阶段 Lua 5.1 实测：配方库 66/66、制作助手 19/19、小窗 51/51。
- Ruling：原目录执行并按文件分工，不建仅含 HEAD 的新 worktree，避免丢失本功能既有未提交输入；不按技能模板创建提交。
- Lua 5.1，无新增外部依赖；仅调用现有允许 API。绑定字段枚举未核实，不猜测、不把空搜索当绑定。

## 任务及接口审查

| 编号 | 归属 | 状态 | 交付与验收 |
|---|---|---|---|
| CC-01 | 计算 | 本地完成 | 交易约束、展开与计算解耦、精确双目标求解、16 路劳力与小规模穷举对照 |
| CC-02 | Feature | 本地完成 | purchaseBlocks 事务、facts/projection、异步比较及失效、继续与取消 |
| CC-03 | 小窗 | 本地完成 | 库存行色、独立交易标签与价格色、双目标结果及操作；实机视觉待验 |
| CC-04 | 集成 | 本地完成 | 加载顺序、定向回归、Lua 5.1 语法及独立审查完成；真实链/客户端待验 |

| 共享面 | 生产者 / 消费者 | 裁定 |
|---|---|---|
| 计算 / Feature | 计算提供 job API，Feature 调度 | 固定下述接口，调用方不读取搜索内部栈 |
| Feature / 小窗 | Feature 提供 comparison 与 purchasePolicies | 小窗只发命令和消费投影，不计算购买资格 |
| 计算 / 小窗 | evaluation 与 recommendations | 两种目标显式选择；显示分开，不借默认别名选择目标 |
| 各任务自身 | 实现 / 测试 | 功能先有失败反例；不把合成数据当 RU 实测 |

## 固定共享契约

- `plan.purchaseBlocks[key] = true` 可选；清除时删除键；仅表示用户禁止购买，不伪称 Native 绑定。
- `facts.purchasePolicies[key] = {state='forbidden'|'allowed'|'unknown', source=..., binding='bound'|'unknown'|'unbound'}`。缺失为 unknown；已接受的报价可以支持购买，缺价不能填零。
- `facts.quoteStates` 传递原 quoteItems，库存/价格/交易属性各自独立；投影为 `plan.purchasePolicies`、`plan.quoteItems`。
- `D.CreateCompareJob(plan,facts,options?) -> job`；输入是 detached 值。`D.StepCompareJob(job,maxUnits) -> status,usedUnits`，一个 unit 必须有界。
- `D.GetCompareSnapshot(job) -> {status,states,result={manual,raw,buy,recommendations={cash,combined},recommendation}}`。`recommendation` 仅为现有纯计算消费者的默认视图，UI 必须用显式目标。
- 推荐项为 `{objective,status,available,evaluation,allocations,states,...}`；缺少劳力折价的 combined 为 unavailable；数据不足不能宣称 optimal。
- `D.ResumeCompareJob(job)` 重置单轮状态预算；`D.CancelCompareJob(job,reason)` 终止。保留 `D.Compare` 为纯计算的便捷有界执行入口，运行同一个求解器，不保留旧有限翻转搜索。
- `C:PlanCompare()` 启动任务，返回 `true, envelope`；`C:PlanContinueCompare()`、`C:PlanCancelCompare()`；`C:PlanApplyRecommendation(expected,key,objective)` 的 objective 是 cash/combined，缺省 cash。
- 投影 `plan.comparison = envelope`，envelope `{revision=<输入版本>,status,states,result=...}`；进度发布不能递增输入版本。输入改变立即使旧建议不能采纳。
- `C:PlanSetPurchaseBlocked(key,blocked)` 保存/解除手动限制并使旧推荐失效。
- 普通 Scheduler 50ms、每块最多 200 units、可用计时时 2ms 软上限；每轮 100000 搜索状态或 10 秒后暂停。保留同一快照供显式继续。
- 拓扑搜索枚举每节点所需批次数；共享需求汇总、库存只抵扣一次；安全下界仅已确定成本。报价缺失等未知分支不能排除后伪称全局最优。

## 文件所有权

- 计算任务：Domain、新 solver、新 optimizer tests、已有 craft_library_tests；不改 Feature/小窗。
- Feature 任务：craft_plan_feature、新 feature compare tests；不改 Domain/小窗。
- 小窗任务：craft_sidecar、craft_window_tests；不改 Domain/Feature。
- 集成：TOC、此台账、必要公共色彩能力与最终审查修复协调。

## 验证记录

- CC-04 新增严格 Lua 5.1 制作定向运行器 `replicatedsuite/tools/rs_craft_cost_test_runner.py`，编译实际 TOC 并隔离运行五套测试，无 5.4 兼容回退。
- 实现中集成首次检查：TOC 325 项 Lua 5.1 编译通过；算法新增两项反例已通过；Feature 当时 14/15，撤销拒写反例仍在修正；旧库断言处于同步→异步迁移。不是最终通过记录。
- CC-02/03 独立审查：规范符合，未发现阻断问题；额外 Lua 5.1 宿主复核 Disable、配方变化、最后 Consumer 关闭重开均拒绝旧建议。
- CC-01 独立审查发现实际 P2：劳力累计超过表示上限时错误剪掉现金合法分支并标最优；已交实现方补失败反例修复，仅劳力／综合目标应受影响。
- CC-01 修复轮 1：上述劳力上限反例已从失败转通过；现金分支保留，劳力降为未知，综合目标保持不足数据。另有合法 512 节点边界，作者定向测试 18/18，等待独立复核及最终集成。
- CC-02 修复轮 1：最终整体审查确认 `S.NowMs` 是 OnUpdate 推进的帧时钟，不能测帧内 2ms。裁定复用已存在且已自检的 `S.PerformanceMonitor.timer`；无细粒度计时能力时只按 200 units 运行并显示能力降级，不另调用 Native。Feature 实现方修复中。
- 候选金额上限反例已修：买 10000 件的金额超过上限，而一批制作现金 1 的合法分支仍可找到；不能因首个超价候选终止全部搜索。
- 合成计算片探针：51 节点／410 材料边／300 库存身份，1000 块、每块 200 units，p50=0.104ms、p95=0.272ms、max=0.824ms；当时仍 searching、12533 states。仅本机 Lua 5.1 计算片测量，不包括 UI/Native，不代表完整搜索或真实赤石实测。
- RU 实机：待验；当前没有经过核验的完整赤石真实制作链，不用同名夹具代替。

## 最终本地结果

- root 统一执行 `python -X utf8 -B replicatedsuite/tools/rs_craft_cost_test_runner.py`：**5/5 套件通过**，实际 TOC **325 项 Lua 5.1 编译通过**。
- optimizer **18/18**、Feature **20/20**、配方库 **64/64**、小窗 **56/56**、制作助手 **19/19**，共 **177 项**。optimizer 内另含 80 个固定种子小图的独立穷举对照及用户提供的 16 条劳力路线。
- 原库 66 项减少为 64 项是移除旧单位边际算法的两项专用测试；其余测试保留或迁移为完整整数搜索／异步契约。
- 最终独立复核：劳力越界与帧内计时两项 P2 均 ADDRESSED；CC-01 spec/quality PASS，CC-02/03 spec/quality PASS，无未关闭的阻断发现。
- 本次范围 `git diff --check`、Python runner AST 检查通过。全库检查另有原有钓鱼文件第 500 行尾空格，未修改；该文件 SHA-256 与开始时一致。
- 无关五份输入 SHA-256 全部与开始时一致；未提交、推送、发布，也未修改 Skills 或记忆。
- 最后仅修正小窗旧引导为“可直接比较金币；「管理」可设置劳力折价”，单文件 Lua 5.1 编译通过，不重跑无关套件。

## 实机验收入口

1. 重载插件，打开「配方制作」，对比背包足量、部分已有和仅银行持有的材料行；检查绿色／黄色和“待取”文本。
2. 选中材料点击「禁买」，查看紫色“不可拍卖（手动）”及询价跳过；再点「可买」解除。已核实绑定资料显示绑定，未知枚举不会被猜成绑定。
3. 点击「比较」，分别选择「目标:金币」「目标:含劳」查看及采纳；设置劳力折价后再核对综合目标。预算暂停时点击「继续」，改变数量后确认旧建议不能采纳。
4. 核验完整真实赤石配方链、Native 绑定枚举、游戏内文字可读性及帧体验。尚未取得这些证据，不把本地合成用例当作实机通过。

## 提交推送范围复核

- 用户本轮明确授权提交推送；沿用个人项目现有 main，不创建新分支或 PR。
- 提交前 fetch/readback：本地与 origin/main 同为 `99ff637a2262d48906117f9e3a4bb77791276d76`，ahead/behind 为 0/0。
- 独立只读范围复核：纳入 18 份制作代码、TOC、定向测试及本轮记录；`rs_craft_feature.lua` 的已有品质查询/原生劳力输入是当前实现必需依赖，一并纳入。
- 宝藏、钓鱼、对应切片/宝藏测试和自检证据共五份修改排除，不因本次提交清理或覆盖。
- 本轮重新执行制作定向回归；提交内容使用显式文件清单暂存，并核对暂存差异及索引与工作文件一致性。实机待验边界保持不变。

## 无关输入保护摘要

实现前 SHA-256，仅用于最终比较，不复制工程或覆盖原内容：

- treasure_inventory：6DFA7E5CEE32C933C3B553BFF99BC5BFB694215E98F8C4AB996B87CDA792B026
- fishing_hotkey：A2F0CDB7861873AF2580DC226FC9C1FB0F44C4613CA7CFDB7B14F32F4E83C23F
- self_check_real_evidence：DD59579A1B0E1DBCB4516C51EEDE749C1FB6C586F7123FE6C02B4ED004E5746C
- feature_slice_split_tests：C2E99607166CD5C1B79576E49266AE26CDBEFFD28BF924CFDE085B309BABF893
- test_treasure_inventory：D3A72BCE9E1BBB197C5597071116DD0EBAB1EC060479E563FC9A56C20DFB8F59
