# 拍卖助手：两个做货任务偶尔只显示一个 — 代码修复与回归报告

日期：2026-09-30  
诊断标识：`daily-auction-title-recovery-1`  
范围：当前活动任务事实 → 做货识别 → 静态材料投影 → 拍卖助手“今日任务”。

## 1. 完成内容

### 1.1 核实基线，避免重复修复历史别名

本轮使用真实上传包 `Addon(20260929-172837).zip`，依次叠加本对话此前的 RefactorReview、LiveContract、UI_Position、Auction_UserPriority、Bonds_CrossContinent 五个增量补丁。原档和独立基线副本均保留。

原代码已包含“太初之地 → Zone 93”的历史别名，以及逐 QuestId 保留任务的逻辑。正常情况下，历史两项标题“[特产-西部] 珊瑚海岸的保存特产”和“[特产-西部] 太初之地的标准特产”在未修复代码中就能同时识别。本轮没有新增或猜测 QuestId、地区别名和配方，也没有把旧别名修复重复计入成果。

尚未取得用户本次复现的两项具体标题、任务 ID 或诊断，因此本报告确认的是可复现的代码缺陷，不把其中任何一项宣称为所有玩家的唯一根因。

### 1.2 第二项任务的标题晚于任务 ID 就绪，旧服务没有恢复路径

真实调用链：`QuestProgressV3:GetActiveQuestList()` → `DailyAuctionMaterialsV3:Refresh()` → `TradeMaterialIdentityV3:ResolveStatic()` → `AuctionSidecar`。

QuestProgress 在活动列表中已经记录任务 ID，但原生标题接口暂时返回空值或异常时，会返回“任务 ID”形式的显示兜底；该兜底不是可用于识别地区、货物类型的 Native 标题。若第二任务标题稍后才可读，任务 membership/state 不变，`v3.quest_progress.updated` 就不会再次发布。Daily 旧实现只监听 updated，因而材料清单可能长期停留在第一项。

修复：

- QuestProgress 的 detached 事实增加 `titleAvailable`，保持原标题字符串和业务 revision 语义不变；成功 Native 标题缓存才算就绪。
- Daily 记录当前尚无标题的任务 ID，订阅原来就有的 `v3.quest_progress.refreshed` 成功刷新事件。仅有 pending ID 时补读这些 ID，不增加常驻定时器。
- 复用既有任务事件和 15 秒 safety 刷新；第二标题就绪后重新解析静态材料。没有新任务事件时，不承诺零延迟，恢复仍受既有 safety 周期约束。
- 相同 refreshEpoch 的 updated/refreshed 不重复重建；仍未就绪时不发布无变化 UI，不重复遍历所有材料。
- 最后一个 Daily Consumer 释放时撤销两种订阅并清理 pending；订阅失败回滚、其他消费者存在、关闭后重开、旧 Generation 回调均有回归覆盖。

### 1.3 未能匹配地区或配方的特产任务原来被整体省略

旧逻辑只把标题成功对应到静态配方的任务加入列表。标题含“特产”但地区/配方未匹配时，玩家只看到另一项，无法知道第二项是否存在。

现在保留无材料的待匹配任务标题，并分别显示“地区待匹配”或“配方待匹配”。这不是凭空补齐未知配方：未获证实的条目没有材料行，不允许自动或手动触发材料搜索；普通非特产任务不因标题延迟而被猜成做货任务。已有已核 QuestId 的合法候选列表仍保留，多候选是任选其一，不能把候选材料全部相加。

不同 QuestId 即使使用同一货物和相同材料，也各自保留任务及隐藏/排序作用域。修复的 UI 还区分“已选中配方但材料为空”和“材料已解析”，避免误导。

### 1.4 独立使用拍卖助手时不再借用其他功能的任务 API 导入

原拍卖 Feature 主要声明拍卖能力；Daily 服务使用 QuestProgress，但之前没有在自己的需求入口确保 `X2Quest` 已由 NativeImports 导入。其他功能先运行过时容易掩盖这一问题。模拟 `X2Quest` 尚未导入的独立启动，旧代码能得到空活动列表。

现在仅在 Daily 首个 Consumer 进入时，通过现有唯一导入权威 `S.ApiImports:AcquireApi(self.Id, "X2Quest")` 取得已核命名空间；不直接调用 ADDON 导入，不在文件加载或诊断中导入。导入失败向调用者返回失败，并记录原因，不启动空任务轮询。当前 Generation 的成功导入复用；关闭时释放任务观察，沿用 NativeImports 既有无卸载接口的生命周期。

### 1.5 UI 和诊断不再掩盖缺失原因

- 两项任务分别显示任务标题；待匹配项保留标题但不伪造材料。
- 标题未就绪时显示等待提示，不直接声称“今日没有做货任务”。其计数是所有等待标题的活动任务数，不冒称都是做货任务。
- 底部改为任务数量，并附待匹配/待标题数量，不把材料行数误作任务数。
- 普通报告沿用 `[DAILY_AUCTION_MATERIALS]`；拍卖助手模块诊断新增 `provider.daily_materials`，二者读取同一服务的当前快照，不采集新任务事实、不执行 Native 搜索。
- 诊断包括 pendingTitleCount、最多 6 条 pendingTitles、真实 unresolvedTradeLikeCount 与最多 6 条样本、taskCount、最多 12 条 tasks 与 tasksOmitted、每项材料数/隐藏数/来源/地区/原因、恢复读取次数和 Native 依赖状态。总数不再等于截断后的样本长度。

## 2. 修改文件

共 8 个文件：6 个修改、2 个新增；其中运行时代码 4 个，没有删除文件。以下路径相对于 `replicatedsuite/`。

| 类型 | 文件 | 职责 |
|---|---|---|
| 修改，运行时 | `services/rs_quest_progress_v3.lua` | detached 标题可用性事实 |
| 修改，运行时 | `services/rs_daily_auction_materials_v3.lua` | pending 标题恢复、未匹配保留、按需导入与诊断 |
| 修改，运行时 | `presentation/v3/widgets/rs_v3_auction_sidecar.lua` | 任务行、空态、材料状态及底部计数 |
| 修改，运行时 | `features/tools/auction/rs_auction_feature.lua` | 模块诊断只读提供器 |
| 修改，测试 | `tools/rs_auction_favorites_tests.lua` | 保留原 20 例，新增 5 例 UI/诊断集成 |
| 修改，测试入口 | `tools/rs_status_refactor_test_runner.py` | `--daily-auction` 专项及默认全量入口 |
| 新增，测试 | `tools/rs_daily_auction_title_readiness_tests.lua` | 26 例真实服务与静态数据回归 |
| 新增，文档 | `Docs/DAILY_AUCTION_TWO_TASKS_REVIEW_2026-09-30.md` | 本报告 |

TOC、Store ID、Schema、字段白名单、用户收藏、窗口几何、报价队列、材料价格和新鲜度公式均未修改。测试产生的 `.copy_*` 等瞬态输出不在补丁内。

## 3. 性能影响

没有新增 Tick、OnUpdate、第二条任务轮询或后台拍卖搜索。只在 Daily 持有 Consumer 且仍有未就绪标题时，使用既有成功刷新事件读取 pending ID。完整标题的稳定状态不触发额外材料重建；仍为空的补读也不重复发布材料投影。已有 QuestProgress 事件合并及 15 秒 safety 节流保持不变。

新增一项内部事件订阅、当前 pending ID 列表及少量统计。诊断样本有上限；最后 Consumer 释放后撤销订阅和 pending 列表。未新增持久化写入。客户端 CPU/FPS 未实测，不给出未经测量的提升比例。

## 4. 兼容风险与覆盖方式

这是本对话前五轮累计补丁之后的增量包，不是完整工程。退出游戏并备份后，将 ZIP 内 `replicatedsuite/` 合并覆盖到 Addon 下同名目录；不要先删除旧目录，不要清空配置、材料缓存或追踪记录。首次安装完整重启客户端，再测试热重载。

BuildTag 不变，仍可能是 `.18.332`。通过拍卖助手模块诊断中的 `daily-auction-title-recovery-1` 核实新服务。没有存档迁移，也没有改变临时材料清单的 Session 保存边界。

尚未收录的任务文字仍可能显示“待匹配”；这类信息保留是为了准确取证，并不代表已推断出其实际材料。不能据此猜造配方。需要核对具体标题/任务 ID/诊断后再按真实数据处理。

## 5. 回归与验证

### 5.1 真实服务测试，而非把结果写进替身

新专项加载真实 Demand、QuestProgress、DailyAuctionMaterials、TradeMaterialIdentity、Zone/Quest/Trade 静态数据；模拟的是 RU Native 接口时序、事件宿主与调度时钟。冷启动依赖测试加载真实 NativeContract/NativeImports，仅替换 ADDON 导入边界。测试中的 990011/990012 是合成 ID，不加入任何生产数据表。

最终同一套 26 例放回未修复业务代码：9 例通过、17 例失败；修复后 26/26。最终拍卖 UI/诊断套件放回未修复业务代码：20/25；修复后 25/25。失败包含同一根因的多种边界，不代表有 22 个独立业务故障。

| 验证 | 结果 |
|---|---|
| 新标题恢复/未匹配/冷启动/生命周期专项 | 26/26 |
| 拍卖收藏、搜索、侧栏与模块诊断 | 25/25（原 20 + 新 5） |
| 原双任务别名测试 | 通过 |
| 原拍卖工作区服务 | 7/7 |
| 原任务详情刷新 | 3/3 |
| 默认 Full Runner | 退出码 0 |
| 10 个独立 Python 回归脚本 | 全部退出码 0 |
| 安装完整性 | 298/298，无缺失、空文件或冲突标记 |
| 架构 / Native 依赖审计 | 0 已知架构问题；0 错误、0 阻断、0 警告 |
| 新专项与侧栏测试的递归依赖检查 | 62 个可达文件，无缺失 |
| Lua 语法检查 | 426 个文件，Lua 5.4 |
| 真正 Lua 5.1 编译门禁 | BLOCKED：环境缺少 luac5.1/luac-5.1，退出码 2 |
| RU 客户端实机验收 | 尚未执行 |

此前窗口视口 66/66、重载位置 26/26、功能方案按钮 14/14、拍卖用户优先 27/27、跑商联动 6/6、债券跨大陆 39/39 均保留在默认全量回归中。

覆盖验证在另一份干净累计基线中解压实际交付 ZIP，复验文件清单、默认全量、专项、语法与安装检查。原始运行日志、覆盖验证、统一差异和 SHA256 清单随证据包交付。中途一次将两个命令合并执行触及 200 秒工具超时，日志不作为全量通过证据；之后单独完成的 Full Runner 退出码 0 才是本报告依据。

执行命令（在 `replicatedsuite` 根目录）：

```text
python tools/rs_status_refactor_test_runner.py --daily-auction
python tools/rs_status_refactor_test_runner.py
python tools/rs_status_refactor_test_runner.py --syntax
python tools/rs_check_installation.py .
python tools/rs_architecture_audit.py
python tools/rs_native_dependency_audit.py
python tools/rs_test_dependency_audit.py tools/rs_daily_auction_title_readiness_tests.lua tools/rs_auction_favorites_tests.lua
python tools/rs_lua51_compile_gate.py
```

在具备 Lua 5.1 编译器的本地环境必须补跑最后一条；Lua 5.4 的通过不能替代客户端 Lua 5.1 兼容性验收。

### 5.2 实机必测

1. 同时接两个做货任务，冷登录后尽早打开拍卖助手“今日任务”；分别验证两个标题与各自材料，不应把第二项静默省略。只需等待既有任务事件/安全刷新，无需反复开关功能。
2. 其他生活模块关闭，只使用拍卖助手，确认仍能获取活动任务；暂时不可读的标题要显示等待状态，任务转交/放弃后应移除而不复活。
3. 两个任务材料重叠时，隐藏/排序其中一个的材料不能改动另一个；多候选任务先选择一种，不能累计所有候选材料。
4. 关闭/重开侧栏、切换选项卡、功能禁用和热重载，确认没有重复订阅、重复条目或旧回调写入。
5. 保持原生拍卖行打开并手动搜索、翻页；本次被动材料识别不能发出自动搜索，不得回退此前的“玩家操作优先”修复。
6. 未知标题保留“地区/配方待匹配”行。仍漏识别时保留拍卖助手模块完整诊断，重点看 `pendingTitleCount`、`unresolvedTradeLike`、`tasks`、`nativeQuestLeaseState`；不要先清存档。诊断可能含任务标题等信息，分享前检查隐私。
