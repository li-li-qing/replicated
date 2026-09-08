## M1.16.0.18.183 — Bag Quick Mutex Self-Heal + Two-Button Surface（"点了没反应"的真实死锁，2026-09-08）

- **用户报告**：① 打开仓库时背包上方的快捷条有 3 个按钮，第三个（`停`）没有用，只要 `存 / 放` 就够了；② 有时点了 `存` 或 `放` 完全没效果，"可能是卡到什么了"。两条不是两个 bug，是**同一个 bug 的两个面**。
- **② 的真实根因（P0，一行顺序问题）**：`BeginBagQuick` 在 `plannedMoves == 0` 早退**之前**就把（空）queue 表赋给 `feature._quickQueue`，而 `BagQuickRunning` 的规则是 `_quickQueue ~= nil` 即"正在运行"。于是——**只要有一次点击没匹配到同类物品**（背包与仓库没有共同同类，首次整理时极其常见）——快捷取放互斥锁就被永久占住：此后每一次 `取/放`、页面直接移动（`CheckedMove`）、类别批量整理（`BatchMove`）都被 `快捷取放已经在运行，请先停止` 拒绝；而被拒绝的那一次点击**仍然 `return true, 0`**，界面什么都不显示。这就是"有时候点了没效果"，也解释了 `停` 为什么看起来既没用又偶尔能救回来：它一直在给这个死锁解锁。
- **为什么 41 个 harness + Gate 全绿也没抓到**：`BagTaskMutexContractVersion=1` 只声明"quick/category 互斥"，从未断言"空计划不得持锁"；文本型 fence 只能看见 token 存在。这是本工程第 5 次同一类失误（`.172` 前向引用、`.174` 第二车道、`.178` 死代码、`.179` 不可达分支、`.182` 无限重试）：**只验证代码存在，不验证它会不会执行**。本轮把取放生命周期状态机写成 **Lua 行为模拟器**（提取真实函数体 + mock Scheduler/容器）：先在未修改的树上跑出 14 条红（`empty plan leaves mutex free [queue=true]`），再改代码。
- **① 产品决定（按用户指令）**：悬浮快捷条与整理背包页面都**只保留 `取` / `放`**。取消不再需要第三个按钮，而由这两个按钮承担：**空闲＝开始；运行中再点同一个＝停止；点另一个＝切换方向**。start/stop/switch 判定全部落在 `tools_bag` Feature（业务权威），Presentation 不再持有分支逻辑。`QuickCancel` 命令保留（诊断与外部调用），但 `quickButtons.actions` 收敛为两个，页面第三个按钮与其遗留的空 `for ... do end` 死循环一并删除。
- **自愈（去掉 `停` 之后必须成立）**：`BagMoveRuntime.ReclaimStaleBagQuickRun`——队列失去执行证据（任务未注册 / 从未执行 / 连续 8 秒无推进 / 调度器熔断）就自动释放互斥锁并把原因写进状态。**复用已有的 350ms 窗口观察任务，不新增 Tick、不新增 Scheduler 任务**（`CheckedMove`/`BatchMove`/`StartBagQuick` 每个入口也各调一次）。证据缺失时**不倒置判定**：拿不到 Scheduler 遥测就退回队列自己的 `_quickLastStepAt` 推进戳——"没有数据"绝不等于"已经卡死"，否则任何停止暴露 `GetTaskState` 的构建都会杀掉正常队列。第二层防御：`QuickQueueActive` 只承认非空队列或在途写。
- **一次点击必须留下可见结果**：状态拆成 `status`（短，≤11 字形，放得进标签）与 `error`（完整技术原因，页面状态行 + 诊断）。悬浮条状态标签宽度 74px → ≥132px（三个按钮时代代理由根本放不下，这也是"看起来没反应"的一部分）；`没有可匹配的同类物品` 改成明确的 `没有同类物品` 并指向「高级整理」；Presenter 改为**该标签的单一写入者**（旧的 `SetText(错误)` 后紧跟 `Refresh()` 会被下一次投影刷新覆盖，等于自己把自己的提示擦掉）。运行中显示进度 `银行 正在放入 3/12`——这就是替代 `停` 的可发现性。
- **本轮自捉第一个 bug（假绿，教训第 6 次）**：`QuickStatusText` 第一版用字符类 `[\1-\127][\128-\191]*` 数"字形"——**该类跳过所有 CJK 首字节**（E4–E9 不在 `\1-\127` 内），纯中文输入返回空串，于是两条"长度合规"断言无脑变绿。行为模拟器直接钉死（`long CJK reason never collapses to empty`）。修复为 `[\1-\127\192-\244][\128-\191]*`。**任何"看起来不可能失败"的断言都要配一个反向破坏用例**：本轮 7 个破坏用例（还原空计划占锁 / 撤掉看门狗 / 窗口设成 0 / 退回 ASCII 字符类 / 分隔符退回字节取反类 / 同向点击不再停止 / 不盖推进戳）逐条跑出红。
- **本轮自捉第二个 bug（同类字节陷阱，破坏用例同样抓红）**：短状态要按标点切出第一子句，第一版写成 `string.match(text, "^[^（，,；;。]*")`。Lua 模式按**字节**工作，取反字符类里放全角标点等于把该标点编码的**每个字节**都列为禁止——汉字 `刻` = `E5 88 BB` 与 `（` = `EF BC 88` 共用 0x88，于是"背包时刻存在读取失败"被从字符中间切断，返回带残半字节的内容，标签直接乱码。现改为对分隔符列表逐个 plain find、取最靠前位置切，切点必在字符边界。破坏用例"分隔符退回字节取反类" → 模拟器红。
- **底层约束记录**：`rs_business_bridge.lua` 的 main chunk 已经顶在 Lua 的 **200 locals/函数**上限（195 条顶层声明）。新增 helper 若写成 `local function` 会把整个文件变成编译错误（`too many local variables (limit is 200)`，本轮真实撞到，第一次 loadfile 就红了）。现在全部挂 `BagMoveRuntime` 字段并把该表声明上移，净增 0。要再往这个文件加业务功能，正确做法是拆分文件，不是压缩注释。
- **不改的边界**：250ms 串行限速、每步黑名单复验、"任一槽读取失败就拒绝整次操作"的保守 fail-closed 全部保持原样——本轮只让**拒绝变得可见**并修掉死锁，不在没有实机证据前放宽安全语义。
- **门禁**：`bag_quick_take_put_contract_v9` 抬到 presenter `version≥6` + `TwoButtonContractVersion≥1` + `BagTaskMutexContractVersion≥2` + `QuickRunSelfHeal/QuickTwoButton/QuickReasonVisibility≥1`；FoundationGate v135→**136**、UIV3Acceptance v89→**90**；registry `tools_bag` 的 window/capabilities 文本同步（`quick_two_button_stop_switch`、`quick_stale_run_self_heal`）；4 处 harness/audit（quick_surface_reload 10 项、bag_move_queue 13 项、runtime_bugfix_18_128 tooltip token、foundation_audit token + 悬浮条按钮数）改写并加"`停` 不得回归"的负向断言。
- **验证**：Lua 行为模拟器 **47/47 PASS**（修复前 14 条红）+ presenter 模拟 45 项 + tooltip 行数模拟 12/12；破坏用例 **15/15 CAUGHT**；node 移植 harness **20/20 PASS**（本机仍无 Python，WindowsApps 只有假可执行，`.py` 需在真 Python 环境复跑）；226/226 Lua Parse OK。
- **用户实机回报（同轮追加）**：重载后打开箱子——第一次报"背包上面没有按钮"，紧接着同一会话的截图里 `取 / 放` 与 `箱子 · 已完成` 已正常出现并跟随背包（说明是开窗瞬间的一次错过，走 `.18.182` 的 retry 路径，本轮未复现；再遇到请抄页面状态行的 `箱子=状态/可见/来源`）。**截图同时暴露一个真缺陷：`放` 的悬浮提示被裁切了。**
- **提示被裁切的根因**：pooled tooltip 的框高来自 `RSUI.TextLayout` 对 native LABEL 的测量。该 Authority 在 RU 上可能缺失或与 native 自己的换行不一致，测量少报时**框比文字矮**，提示就从上/左被切掉。我这一轮把 `放` 的文案从 ~42 字加长到 ~66 字，正好把它撑爆——**是我这次改动把潜在缺陷变成了可见缺陷**。
- **修复（Tooltip v4→v5，两层）**：① 新增 `Tooltip:EstimateWrappedLines`，按字形宽度单位（CJK=1、ASCII=0.6）给出**行数下限**——只会把框垫高，绝不会裁字；② `Show` 用 `max(测量行数, 下限)` 并同时抬 `textComponent.maxLines`（受 `nativeLineLimit=8` 约束），保证"框的高度"和"组件允许画的行数"永远一致，不出现"框高字少"或"框矮字多"；③ 背包两条提示改回两行以内的短句，"点另一个＝切换方向"这类长说明留在页面提示行（那里是真·自动换行 Text，有空间）。
- **追加证据**：tooltip 行数估计模拟器 **12/12**（含"按字节计数"与"撤掉下限"两条新破坏用例）；presenter 加载/显示模拟器 **36 项**——真实文件在 mock UI 下 load、建出 2 个按钮、可见投影显示 `箱子 · …`、运行中显示 `3/12`、点击抵达命令、构建失败经 retry 自愈且不无限循环。破坏用例总数 **13/13 全部 CAUGHT**（含"撤掉 raise 守卫"与"撤掉文案 diff"两条本轮新增）。
- **用户第二次回报（同轮再追加）**：提示一开始确实在最上层，**不到 1 秒又沉下去了**。这不是层级不够，而是**层级被自己的心跳抢走**：presenter 的 `Refresh()` 在 350ms observer 每次发布时无条件重写 anchor/extent/text、`SetVisible(true)`、`TrySetUILayer` 并 `Raise()` —— 于是 2~3 拍之后悬浮条又压回提示之上（同一处也违反本工程硬规则 9「UI Diff Rendering 是默认规则」）。
- **修复（Tooltip v5→v6 + presenter v6→v7）**：① `Tooltip:IsShowing()` 把"提示正在被阅读"变成可查询事实（`Show` 置位、`Hide` 清零，成对写入）；② presenter 改为**差分应用**：几何键 `(x,y,width)` 或首次显示才写 anchor/extent/SetVisible/layer/Raise，文案变化才写一次 label；③ 稳态心跳仍保留"压在原生背包窗之上"的 keep-on-top raise，但**只在没有提示显示时**执行；④ 查询能力缺失或调用异常时**不抬**——宁可少一次 re-assert，也不盲抢看不见的东西的 z-order。
- **第二次追加证据**：presenter 模拟扩到 **36 项**（新增：稳态心跳零 native 写、提示在时不 raise、提示撤走后恢复 raise、进度只改一次标签、背包窗口移动后重新应用几何、无查询能力时不盲抬）；破坏用例新增 2 条（撤掉 raise 守卫 / 撤掉文案 diff）→ 后续批次扩到 **13/13 全部 CAUGHT**。
- **用户第三次回报（同轮，产品歧义）**："目标：银行 / 箱子"那个开关是什么意思？**打开仓库时开不了箱子，打开箱子时开不了仓库**，用户看不懂这个选项；"反正功能是能把东西取出来跟放进去就行了"。判断正确——这是一个**结构性歧义**：让用户在两个不可能同时存在的窗口里选一个目标，选错了只会得到"请先打开对应的窗口"。
- **改法（按用户授权自行判断）**：**高级整理的目标 = 当前真正打开的那个仓储窗口**，与快捷取放共用同一个事实源（`CurrentStorageContext`），不再让用户选。① 新增 `BagMoveRuntime.ResolveBatchTarget()` + 命令 `DepositCategoryCurrent`，`BatchMove(feature, nil, ...)` 表示"用开着的这个"，解析发生在 `BeginBatchMove` 校验目标**之前**；② 页面把 `RSUI:Toggle(目标：银行/箱子)` 换成**只读回显** `目标：银行（当前打开） / 目标：箱子（当前打开） / 目标：请先打开银行或箱子`（新控件 id，不在旧 Toggle id 下换控件类型，避免残留布局状态）；③ 没开任何仓储时的拒绝走既有 preflight-visible 路径，写进批量状态行而不是静默失败。`DepositCategoryBank/Coffer` 与 `SetBatchTarget` **保留**（显式调用方与旧存档兼容），`State.batchTarget` 降级为 legacy 字段，投影新增 `batchTargetMode="auto_open_storage"` + `batchTargetResolved/Label` 说明真相。
- **契约与证据**：`BagTools.BatchTargetAutoContractVersion=1`；registry 能力加 `batch_target_open_storage`；Gate/Acceptance 要求 `Commands.DepositCategoryCurrent` 存在；bag harness 加**顺序断言**（解析必须早于 `BeginBatchMove`）与**负向断言**（`目标：箱子/目标：银行` 文案不得回归）。互斥模拟器新增第 6 组 6 条（箱子开→箱子、银行开→银行、都没开→拒绝且原因可读、短句放得下状态栏）→ **45/45**；破坏用例新增 2 条 → **13/13 全部 CAUGHT**；node 移植 19/19。
- **用户第四次回报（同轮，UI 冗余）**：截图指出悬浮条右侧那句 `银行 · 可快捷取放` 不需要，"只要显示取跟放就行了"，并提醒"要有用户思维，游戏插件简单方便最重要"。判断成立：**常显的 idle 文案不携带任何信息** —— 用户刚点开的窗口就是银行或箱子，不需要我们再播报一遍；而我为了"拒绝必须有可见原因"加的标签，副作用就是它平时也在说话。
- **改法（presenter v7→v8，quiet by default）**：标签默认**空**且隐藏，悬浮条收成**只有两个按钮的宽度（102px）**；只有两类内容会临时把它撑开 —— ① 运行中的进度 ``正在放入 3/12``（这是替代 ``停`` 的可发现性，运行期间永不过期）；② 一次点击的短结论（``没有同类物品`` / ``已停止`` / ``已自动停止`` / 拒绝原因），**6 秒后自动消失并缩回**。过期判定复用既有 350ms 心跳发布，不新增 Tick/任务；为此 Feature 的每一次状态写入都带上 ``statusAt`` 时间戳（新增 ``QuickStatusTimestampContractVersion=1``），存储类型不再进悬浮条文案。
- **破坏用例的一次自我纠正**：第一次写"把 idle 文案改回来"的破坏用例时只删了 idle 字符串过滤，结果**没有变红** —— 因为时间戳闸门同样会把它压成空串。这条 MISSED 暴露的是我那条用例本身不是真回归测试；改成同时移除两道闸门（还原成旧实现）后才 CAUGHT。**"MISSED"要当成用例的失败来修，不能当成无关紧要。**
- **待 RU 实机（不能只靠本地）**：见 `Docs/Rebuild/RU_RUNTIME_ACCEPTANCE.md` `.18.183`。核心一条：**背包与仓库没有同类时点一次 `放`，之后 `取`/`放` 必须仍然可用**（旧版会永久卡死）；以及运行中再点同一按钮必须立刻停。
- **BuildTag**：`v3-m1.16.0.18.183-bag-quick-self-heal-two-button`（本批含 `.18.181/.18.182` 一起发布；诊断横幅带 BuildTag，RU 回报抄回来的那一行必须等于它，否则说明客户端还在跑旧代码 —— 这正是 `.18.183` 三次回报需要区分的）。

## M1.16.0.18.182 — Bag Quick Overlay Retry + Tooltip Layer（整理背包三缺陷，2026-09-08）

- **用户报告**：① 打开仓库/箱子时快捷悬浮按钮不是立即出现、有时等很久、有时整场不出现；② 鼠标悬浮提示层级太低被其他 UI 挡住；③ 列表（TableView）里悬浮提示用不了，希望显示不全的内容能靠它看全。
- **① 根因与修复（`rs_v3_bag_quick_overlay.lua` v4→v5）**：观察器每 350ms 读一次原生窗口几何，storage 可见期间有 heartbeat 重试——但 `Refresh()` 里宿主 WINDOW 构建失败只 `return false`，**没有任何主动重试**；RU 在银行/箱子开窗动画期间会短暂拒绝 transient window 创建，若此时恰好错过 heartbeat（或事件链断一拍），按钮就"迟迟不出/干脆不出"。现改为：可见状态下构建失败 → `ScheduleCreateRetry` 以 64ms 帧级 one-shot 自愈重试（`AddHighFrequencyOneShot`，回调前自动移除，**无常驻 Tick**），连续失败上限 8 次后停止并保留 `lastError` 供诊断；`GetHealth` 新增 `retryScheduled/retryCount`。
- **本轮自捉的第二个 bug（教训第 4 次印证 .172/.174/.178 模式）**：初版把 `retryCount = 0` 写在 `ScheduleCreateRetry` 开头——而该函数正是回调里的 re-arm 入口，每次重排都清零计数，**上限永远打不满，变成无限重试循环**。Lua 行为模拟器（提取真实函数体 + mock Scheduler，one-shot"先移除后执行"语义）第一跑就把它钉死。修复：签名改 `ScheduleCreateRetry(freshCampaign)`，外部调用重置计数、回调内 re-arm 传 `false` 保留计数。文本型 fence 对这类控制流缺陷依旧失明，行为测试是唯一防线。
- **② 根因与修复（`rs_ui_interactions.lua` Tooltip v3→v4）**：pooled fallback 的 root 是**顶层 emptywidget**——本工程自己的原生原语注释已记录"RU 客户端不保证把 root emptywidget 送进 system 层"（Unit Lines 0 可见点、Dropdown 弹层被压同为根因家族）。游戏自身的物品 tooltip 是高层级原生窗口，我们的提示自然被盖住。现对齐 ContextMenu 的既有证明策略：`transientWindow=true` + `SetUILayer("system")` + `layer.popupPriority(10000)` draw priority，并在 Show 之后再 `Raise()`（原生可见性切换会重置 z-slot）。pickable=false 的 fail-closed 契约不变。新契约标记 `TransientLayerContractVersion=1`。
- **③ 排查结论（诚实边界）**：Table 行的截断提示链路本身是全工程默认开启的（`autoTooltip ~= false`，行 hover → 收集被省略号截断的单元格全文 → cursor-follow fallback）。用户在表格里看不到它，**最可能就是吃了 bug② 的层级问题**（提示其实弹了，被压在下面）——本次修复应连带治好。另修一处真实的池化陈旧缺陷：滚动/换绑与原生可见性 diff 之间有一拍间隙，不可见的池行仍可能触发 OnEnter 贡献旧行文本，`GetTruncatedTooltipText` 现在对 `visible~=true or viewportVisible==false` 的行直接返回空。**若 Fresh Reload 后表格悬停仍无提示，那是独立缺陷（RU 不给 EmptyWidget/Button 子树派发 OnEnter 的可能性存在但未证实），需要实机证据再修，不做第二轮猜测。**
- **门禁**：acceptance `bag_quick_take_put_contract_v9` 抬到 version≥5/host≥2/retry≥2；`tooltip_contract` 抬到 version≥4 + TransientLayer≥1；FoundationGate floating_text_layout 同步。两个 Python harness（quick_surface_reload / runtime_bugfix_18_128）补 token 与新切片检查；本机无 Python，node 移植 21/21 + Lua 模拟器 PASS。luacheck 6 文件 0 错误。
- **BuildTag**：未 bump（与 .18.181 同批待发布）。

## M1.16.0.18.181 — Trade Sort: Segmented Selector + Name Mode（2026-09-08）

- **需求（用户提出）**：跑商排序从"点一下换一个"的循环按钮改为单选框式；新增"名字"排序，`[xx]` 前缀货物排在最前。
- **三态闭合集合**：`ratio / price / name` 收敛为 `TRADE_SORT_MODES`，命令校验、Store normalize/apply 三处共用同一集合；旧存档值不变（`price`/`ratio` 原样可读），未知值仍回落 `ratio`。SchemaVersion 不动——纯枚举扩展，无迁移。
- **名字排序语义**：`[` 前缀标志位先比（带括号组整体置顶），组内按本地化显示名字节序；同名字（多品质行常见）以货率降序破平，再按 key 保证重建稳定。**为什么不能直接字节比**：`[`=0x5B 低于 CJK UTF-8 首字节（E4–E9），纯字节比较会把 `[黄金]…` 沉到所有中文名之后——正是用户要避免的行为。模拟器测试用真实提取的 `SortTradeRows` 源码验证了这一点。
- **UI 形态**：主页面与跑商悬浮窗都改用共享 `RSUI:SegmentedSelector`（DPS/HUD 同款单选契约：选中态高亮、点击已选项幂等成功、不重复写持久化）。控件 id 保持 `v3_trade_sort_mode` / `v3_life_trade_widget_sort`，绑定与静态 fence 无缝延续。悬浮窗收藏行放不下三段，排序移到独立一行（routeBox 128→158），Feature 窗口策略 defaultHeight 340→374、minHeight 220→254；老用户已保存的窗口尺寸不受影响（NormalizeState 只 clamp，不强改）。
- **状态行提示**：主页 "· 按名字排序（[]优先）"、HUD "· 名字序（[]优先）"，让排序语义可见而不依赖 tooltip。
- **fence 同步**：trade harness 新增 4 条（闭合集合、`[]` 置顶比较器、Store normalize、两处 SegmentedSelector 字面量）；foundation audit 同步补 token。两条新检查均为换行敏感字面量，harness 读取统一 CRLF→LF 归一（此前该文件没有跨行字面量，属首次暴露的环境耦合）。本机无 Python（仅 WindowsApps stub），全部检查另以 node 移植跑通 37/37；Lua 模拟器 7/7（含确定性、nil 名字安全）。luacheck 3 文件 0 错误。
- **不做**：不加"毛利"排序（当前 RU `GetLowestPrice` 无返回，毛利大面积缺失，排出来是空排序）；债券排序保持双态循环按钮，不在本轮行为冻结范围外顺带改。
- **BuildTag**：未 bump（单轮 UI/排序改动，随下一次发布快照合并）。

## M1.16.0.18.180 — Persistent Reference Price Table（长期价格表，2026-09-08）

- **需求（用户提出）**：每次都要现场搜价太慢。改为「搜到过一次就记下来 → 下次直接显示旧价参与计算 → 后台再搜、拿到新价替换」。本插件面向玩家，等待时间本身就是功能缺陷。
- **三层取价**（材料投影）：① 本次会话已完成的实时报价 → `quoted`；② 否则读持久参考价 → **`quoted_reference`**（新状态）；③ 否则诚实显示 pending / failed / 需询价。**询价中或询价失败时仍继续显示参考价**，不再退回空白等待——这是本方案的关键收益。
- **存储**：新增 Persistence V3 store `v3.trade_reference_prices`（account scope / permanent / schemaVersion 1），沿用工程既有事务式写入 + `MarkDirty(1200ms)` 合并落盘。全部改动收敛在 `PriceQuoteQueueV3` 内部，未新增文件、未新增调度任务。
- **用户锁定的三项决策，均已固化为代码约束**：
  - **永不过期**：拍卖挂单可被人为压价污染，一个极低挂单会带歪所有人的预期。因此不做 TTL 静默失效，而是让**陈旧性显式可见**（见下），旧样本不会冒充当前行情。同时保留有界历史样本（≤6 条，新→旧），便于日后判断某次价格是否为异常低点。
  - **`itemType + grade` 复合键**：品质阶梯本就逐档命中，记录实际成交的 `resolvedGrade` 而非提问档位；grade-0 无差别探测不得覆盖具体品质的记录。
  - **数据不随包分发**：store 是账号运行期产物，每个玩家自己采集。绝不把开发机采到的价格塞进发布包 —— 那会把我们的样本伪装成用户的现实。
- **诚实标注（决策 2A）**：参考价照常计入毛利，但与实时价明确区分：详情浮窗状态列 `已报价`(green) vs **`参考价`(muted)**；表格单元格价格后缀「，参考」；来源由服务层单一入口 `GetPriceWithProvenance()` 给出 `live|reference`，渲染层不再自行猜测。
- **fail-closed 细节**：只有 direct 稳定 ID 成交才写入长期表；名称搜索得到的 `name_search_bid` 是**另一条挂单的估价**，永不进入长期表（防止估价被洗成长期事实）。加载失败只让内存表为空，绝不清写磁盘数据；服务层无原始 `SaveData` 调用。
- **待办计数不误涨**：`quoted_reference` 不在询价 backlog 集合内，按钮数字不会因已有参考价的材料而虚高；玩家仍可主动对单条重新询价刷新。
- **修掉一处我自己引入的错误**：`RecordReferencePrice` 用点号调用冒号定义的 `EnsureStoreLoaded`（self 丢失）。它能碰巧工作只因函数体全用闭包 `Q.` 而非 `self.`，属运气不是设计。已改回 `Q:EnsureStoreLoaded()`，并全工程扫描同类问题：**0 例**。
- **门禁**：quote_state harness 升 **91/91**，新增 10 条锁死上述契约（store 注册、key 含 grade、估价不入表、样本有界、加载失败不清洗磁盘、合并写、live 优先于 reference、参考价状态独立且为 muted、参考价不计入 backlog、服务层禁 raw SaveData）。三条反向破坏测试验证非假绿：删估价拦截 → FAIL；key 去 grade → FAIL；去掉 provenance 区分 → FAIL。
- **hover 高亮 bug 状态说明**：按你的要求本轮一并处理，但**我最初的「off-by-one gap 公式」诊断是错的** —— 数值验证表明我的"修复"与原式在 gap=4 时恒等，已完全撤销，未留下伪修复。真正线索指向 header cell 与 resize handle 的命中层级（handle 最后创建且有 Raise，理论上应在上层），仅靠静态阅读无法定案，需要实机确认，详见 STATUS 待办。
- **BuildTag**：`v3-m1.16.0.18.180-persistent-reference-prices`。

## M1.16.0.18.179 — Fallback Reachability Fix（`.178` 的修复本身是死锁，2026-09-08）

- **`.178` 报告读数**：`已报=0` **且** `失败=0`，队列停在单个请求上轮转。两个计数同时为零排除了「取价失败」也排除了「取价成功」——只可能是**没有任何请求走到终局**。这不是判断错误，是结构性不可达。
- **根因（我 `.178` 亲手引入）**：阶梯耗尽并 `BeginSearchFallback` 成功后，`Q.pending` 仍指向该请求；下一次 `Drain()` 在通用早退 `if Q.pending ~= nil then return end` 处直接返回，而轮询兜底结果的分支写在这行**之后** —— 于是永远执行不到。我把 `.177` 的「重试三次注定失败」改成「等待」，结果让等待变成了**永久停顿**：旧版那三个重试虽然愚蠢，至少还在推进状态机。
- **修复**：兜底轮询本就必须优先于通用 pending 早退（它合法占用 pending 槽）。将 `_CheckFallback` 调用移入 `if Q.pending ~= nil then ... end` 内部、置于 return 之前；删除队列弹出之后的重复分支（那条按新结构已不可能命中）。`stats.attempts` 只在直接探档路径递增，保持"= GetLowestPrice 调用数"的语义。
- **为什么现有 fence 完全没抓到**：`.178` 加的 `fallback_polling_not_counted_as_attempt` 用 `service.index(A) > service.index(B)` 断言顺序，但两处文本都存在于整个文件，跨函数比较毫无意义；可达性问题需要**在 Drain 函数体内比较行位置**。新增三条：`fallback_serviced_before_pending_return`（切出 `local function Drain()` 函数体，要求 `pending 守卫 < fallback 服务 < 队列表头弹出`）、`no_duplicate_fallback_branch`（恰好一处）、`attempts_only_for_direct_probe`。反向破坏测试重演 `.178` 死锁 → 两条同时 FAIL，确认非假绿。同时退役了那条被取代的旧检查。
- **教训（第三次同类）**：连续三轮（`.172` 前向引用、`.174` 第二车道、`.178` 不可达分支）我的错误都不是"想错了"，而是**只验证了代码存在，没验证代码可达/会执行**。文本型 fence 对这类问题天然失明。本轮起：涉及控制流的修复必须断言函数体内的语句顺序，而不是全文件子串存在。
- **BuildTag**：`v3-m1.16.0.18.179-fallback-reachability-fix`。

## M1.16.0.18.178 — Working Name-Search Fallback（真正修复，2026-09-08）

- **用户指出关键事实**：旧版（`参考的项目1`）点击货品→悬浮窗→「查价格」**能查到材料价**。这直接否证 `.177` 的「API 不可用」结论，也把调查方向从「RU 接口坏了」纠正为「我们漏实现了旧版的第二条路径」。
- **旧版真实链路（逐行核实）**：`T:QuoteSelectedPack` → `Auction:QuotePack` → 每材料 `QueueOne` 同时启用 direct 与 search 两条路（L259-260）；`SendDirect` 走完 `BuildGradeCandidates` 阶梯后若全 nil，调用 **`FallbackToSearch`**（L203-217）→ `SendSearch` 以 `displayName`/`name` 作关键词发 `SearchAuctionArticle(1,0,999,1,0,false,query,"0","0")` → `OnSearched` 读首行 → `ExtractFolioReferencePrice` 取 `bidPriceStr`/`bidPrice` → `FinishRequest(price)`。**即：材料成本本来就来自拍卖搜索结果首行的竞拍价，GetLowestPrice 只是优先尝试。**
- **为什么我们一直没走到那一步**：`.172` 写下的兜底链是**必崩的死代码**（`CompletePending` 前向引用，`.174` 才修掉崩溃）。修好崩溃后本轮又查出**三个仍在生效的逻辑缺陷**，任意一个都会让兜底永远拿不到价：
  - **重试逻辑不可能成功**：`_CheckFallback` 在快照仍为 `waiting` 时重新调用 `AuctionQueryV3:Search`，而该方法开头即 `if self.pending ~= nil then return false, "上一个拍卖搜索仍在等待服务器返回"` —— 三次重试全是注定失败的调用，然后宣布「名称搜索无结果」。改为**按墙钟 deadline 等待**（`fallbackDeadlineAt`，12s 上限），不再重复发请求。
  - **身份守卫把自己拒了**：守卫要求首行 `itemType` 与期望值相等，否则判「身份不匹配」；但当前 RU 的 `GetSearchedItemInfo` 并不稳定暴露 itemType，`rowType` 恒为 nil → **每一次真实命中都被自己的守卫拒绝**。改为只在**确证不同**时拒绝，并在关键词与返回行名称都已知且明显不符时才失败（新增「搜索结果名称不符」分支）。
  - **轮询被记成询价尝试**：fallback 每个 tick 都给 `stats.attempts` +1，制造幻影尝试数。移到非 fallback 分支之后计数。
- **搜索关键词来源**：改用与行标签同一个 Localization Authority（`LocalizedTradeItemName(itemType)`），绝不用英文数据键；因 RU 拍卖行措辞可能与本地表漂移，交叉校验只做「确证不符才拒」，避免陈旧条目静默丢弃真实命中。
- **探针结论就地订正**：`RunProtocolProbe` 注释新增 CORRECTION 段，明确「三条控制项全 nil 不能推出无法取价」，并要求与本文件的兜底结果一起解读 —— 防止下一个读代码的人重犯同样的推断错误。
- **防回归**：quote_state harness 升 **79/79**，新增 6 条专门锁这三类缺陷的检查：`fallback_no_retry_while_waiting`、`fallback_waits_on_deadline`、`fallback_identity_guard_allows_unknown_shape`、`fallback_name_cross_check`、`fallback_polling_not_counted_as_attempt`、`legacy_chain_reachable`；另加 `search_keyword_not_english_key`。其中三条做了反向破坏测试（退回 nil 即拒的身份守卫 → FAIL；删除 deadline → FAIL），确认非假绿。
- **本轮方法论教训**：`.172/.174/.177` 连续三轮我都在**没有读完旧版完整链路**的情况下对单个 API 下结论，并且每次都把自己的实现缺陷解释成平台限制。技能 §12 明确要求旧版迁移要 trace 真实链路 —— 正确顺序应是先完整还原旧版两条路径再动手，而不是先修一条路再猜另一条。已把这条写进本条目作为记录。
- **BuildTag**：`v3-m1.16.0.18.178-working-name-search-fallback`。

## M1.16.0.18.177 — Quote Cooldown Fence + Compact Material Cells（2026-09-08）

- ~~**协议探针跑完，给出决定性结论：`GetLowestPrice` 在当前 RU 客户端根本不返回可用价格。**~~ **【本结论已被 `.178` 推翻，见下方条目】**该判断错误的原因：探针只验证了旧版两条取价路径中的**一条**。旧版在品质阶梯全 nil 后会转入名称搜索并采用首行 bidPrice 作为材料成本 —— 也就是说「GetLowestPrice 全 nil」是旧版流程中的**正常中间状态**，不是终局。当时我们的兜底恰是死代码，于是把「自己没实现好」误读成「平台 API 不可用」。保留此段以免同类误判再次发生。
- **修复探针偷取冷却窗口（真实缺陷）**：报告同时出现 `失败=3 · capability cooldown active: 500ms remaining`。根因是 `RunProtocolProbe` 与真实询价在**同一个 drain tick 内两次调用同一 capability**，第二次必然落进第一次的 500ms 官方窗口被能力门拒绝——探针一直在静默消耗用户询价的冷却预算。现改为探针**独占一个 tick**（调用后立即 return，不落到队列表头弹出）。
- **墙钟冷却围栏**：`intervalMs=560` 只是调度 tick 间隔，而任务被 FrameBudget 延迟时（`deferCount++` 路径）相邻两次实际执行的墙钟间距可以远小于 500ms。新增 `Q.lastNativeCallAt`，Drain 入口以单调时钟判定 `(now - lastNativeCallAt) < intervalMs` 即直接跳过本 tick；探针路径与真实询价路径各打一次时间戳（共 2 处，fence 锁定计数）。真实节奏从此由墙钟保证，不再依赖 tick 计数是否被预算打断。
- **材料列拥挤修复（用户截图反馈）**：原先每个材料都带括号状态后缀 —— `木材×2（询价失败）·牛奶×50（询价失败）·柠檬×30…`，四个普通材料就塞满整列并在玩家看完配方前触发截断。表格单元格现在只渲染 `名称×数量`（新 `cellText`，上限 26 字符），完整状态保留在行字段与详情浮窗（其自有 countText/unitText/subtotalText/statusText 列不受影响），逐材料价格明细也仍在诊断报告。玩家扫表看的是需要什么材料，不是每项的询价日志。
- **毛利列诚实化**：`待材料价格` 改为 `缺材料价（拍卖行无返回）`。旧文案暗示数字"马上就来"，但按本轮证据它永远不会来；新文案说明缺失原因，且货率/预计售价两列仍是真实事实，玩家依旧可以用它们选路线。
- **防回归**：quote_state harness 升 **72/72**。新增 `probe_owns_its_tick`（结构化定位 Drain 内调用点，要求其后先 `return` 再出现队列表头弹出）、`wall_clock_cooldown_fence`、`single_native_call_per_tick`（时间戳赋值恰好 2 处）。两条反证测试均验证非假绿：删掉探针后的 `return` → FAIL `probe_owns_its_tick`；把墙钟判定改成恒假 → 同时 FAIL 两项。
- **fence 自身两次返工记录**：`probe_rides_existing_lane` 原锁字面语句，改语义后失配——按 `.171/.174` 惯例改为锁语义而非文本。首版 `_probe_branch_returns` 有两处错误：① 用"窗口内找不到 pop 即视为通过"，导致删掉 `return` 仍判 PASS（假绿，反证当场暴露）；② `text.find("Q:RunProtocolProbe()")` 命中的是函数定义头而非 Drain 调用点。均改为先定位 `local function Drain()` 再在其后搜索调用点、并要求 pop 必须存在且晚于 return。教训：**任何新 fence 必须先做反向破坏测试再宣布通过**，只看绿色数字不算数。
- **BuildTag 协调**：本轮改动落在 `.176-table-resize-dragstop-stability` 之上（该轮为表格列宽拖拽 DragStop 稳定性，与本文件无交集），故本构建号为 `.177`。两处改动互不覆盖，均已核实共存。
- **下一步（需要产品决策，不再是技术猜测）**：材料成本在 RU 当前不可得。可选方向：① 保持现状——货率+预计售价照常工作，毛利列明确标注缺材料价；② 引入玩家可维护的材料参考价（本地记账/手动输入并持久化，来源标注"自定义参考价"而非拍卖行实时价）；③ 探索 `AskMarketPrice` 等替代原生入口（注意：旧版从未使用过它，属未验证路径）。**（此建议随上方结论一并作废：`.178` 证明正确路径来自旧版可证实装，无需新探索。）**
- **BuildTag**：`v3-m1.16.0.18.177-quote-cooldown-fence-and-compact-materials`。

## M1.16.0.18.176 — Table Resize DragStop Stability（2026-09-08）

- **跑商“货物 / 货率”分界松手跳变根因**：主跑商表是 `货物=Fill`、`货率=Fixed`，后面还存在第二个 `材料=Fill`。拖动期间 Preview 正确冻结了全表 resolved widths，但旧 `CommitColumnResizePair()` 只提交被编辑的两列；DragStop 后完整 Fill solver 重新从未触碰的 `材料.minWidth` 起算并再次分配剩余宽度，导致 `货物` 列被二次加宽，视觉上就是“鼠标拖到这里，松手控件突然变动”。连续操作会让 Native resize handle 与逻辑分界逐步失配。
- **完整 resolved snapshot 提交**：`DataViewResizePreviewAuthorityContractVersion=2`。DragStop 先把用户最后看到的 Preview 宽度写成**全列 manual baseline**（保持未编辑列原 size mode），再提交实际编辑列对；同一 viewport 宽度下 `committedResolvedWidths` 直接作为几何 Authority，不允许紧接着再跑一次 Fill solver。窗口/viewport 真正变宽或变窄时自动废弃该快照并恢复响应式求解。
- **分隔命中区恢复**：Table resize handle 的 Native `StartMoving` 现纳入 `BeginNativeGeometryLease/EndNativeGeometryLease`。手势结束后 DiffRenderer cache 被明确失效并重新锚定 14px 命中面；兼容路径使用 `InvalidateNativeState`。解决连续拖动后“鼠标仍放在视觉分界处但已经抓不到 handle”的漂移。
- **性能边界不变**：无永久 Tick、无业务数据重绑、无保存扇出。仍只在拖动手势期间使用既有 16ms interactive lane；DragStop 额外工作为 O(列数)，跑商表仅 4–5 列。
- **门禁**：RSUI v50 / API 13.4；Foundation Gate v135 / UIV3 Acceptance v89。`v3_26_table_resize_contract` 新增真实 Trade 形状（Fill + Fixed + Fixed + Fill + Fixed）的 DragStop 不跳变序列；`rs_input_focus_drag_harness` 新增全列快照、同 viewport Authority、geometry lease 与 Gate v2 fence。
- **BuildTag**：`v3-m1.16.0.18.176-table-resize-dragstop-stability`。

## M1.16.0.18.175 — Player-Facing Naming（2026-09-08）

- **用户思维纠偏（用户直接指出）**：本插件的用户是中文 RU 客户端上的玩家，不是这套 Suite 的开发者。此前大量内部标识符直接渲染到界面与 HUD：材料行显示英文数据键（`Chopped Produce` / `Ground Grain` / `Lumber`）、配方标签显示英文 legacy 配方名或裸 craftType 数字、售价拆解显示 `熟练×0.875 · 品类×1.20` 因子记号、状态回退可能吐出 `explicit_quote_required` 一类代码。玩家只需要知道**这个东西叫什么**。
- **材料行改为官方中文名**：`name` 不再取 `materialKey`，改走 identity 服务新增的显示解析器（Localization Authority 优先 → 静态记录本地化名 → 通用兜底「材料」）。原英文键移到**仅诊断可见**的 `internalKey` 字段。真实映射表校验：**70 个材料键全部命中正确中文名，零缺失**（切碎的蔬菜 / 谷物细粉 / 干净的肉脯 / 晒干的花草 …）。
- **共享显示解析入口**：`TradeMaterialIdentityV3:ResolveMaterialDisplayName(row)` 与 `:ResolveProductDisplayName(itemType, fallback)` 成为身份→文案的唯一出口；`GetName` 合成的 `"ID <n>"` 形式被识别为"没有名字"而非名字，避免把编号当名称显示。m16 侧新增全局辅助 `LocalizedTradeItemName`（定义为全局以避开 Lua 5.1 主 chunk 200 local 上限——该文件实测已 `businessLocals=200/200`）。
- **配方标签中文化**：live 分支不再把 `craftType` 数字当标签（改为本地化产品名，无则「配方已识别」）；静态分支的英文 legacy 名优先替换为本地化品名。两者原始值统一落到新字段 `identityDetail`，仅供诊断面板使用。
- **贸易品详情浮窗**：删除 `name or material.materialKey` 的英文键回退（这是玩家表格上最直接的泄漏点）；倍率因子串改为一句人话「含经商与品类加成」，原始倍率只在诊断面板出现；新增 `PlayerPriceStatusText` 把未知内部码收敛为「暂无法估价」而不是原样回显。
- **诊断面板保持完整开发信息**：本轮不是"删术语"，而是**分层**——玩家面只留中文，开发面（复制报告）额外补上逐行 `材料键[...]` 与 `identitySource;identityDetail`，可读性反而更强。
- **新增常驻 fence（关键）**：`rs_trade_detail_favorites_harness` 升 **44/44**，加入"玩家界面不得输出内部标识符"扫描。首版用裸 token 子串匹配，误报三处合法用法（表格内部 row key、`if status == "quote_failed" then return "询价失败"` 这类读取比较），说明**字面量检查在这里根本不够用**；改为匹配显示位置形态（`name/text/label/title/summary/statusText =` 赋值）并剥离注释后归零。反向破坏测试确认非假绿：把英文键回退注回去即 FAIL。另锁 `ResolveMaterialDisplayName`/`ResolveProductDisplayName` 存在、`PlayerPriceStatusText` 存在、诊断面板仍保留 internal 细节（防止将来"顺手删掉所有术语"毁掉唯一可读状态源）。
- **过程自纠**：本轮多次因 Python↔Lua 嵌套引号转义写出非法字符串、以及一次引用未定义辅助函数（`PlayerPriceStatusText`、`LocalizedTradeItemName`）而中断；均按 `.174` 教训以"写完立即解析+跑门禁"收口，未再产生运行期前向引用。`.174` 引入的 `rs_lua_local_order_audit` 在本轮全程护航（identity/m16/diag/detail 四个改动文件均 0 违规）。
- **BuildTag**：`v3-m1.16.0.18.175-player-facing-naming`。

## M1.16.0.18.174 — Forward-Reference Fix + Standing Local-Order Gate（2026-09-08）

- **`.18.173` 报告自曝其短**：`协议探针: done=false 次=6` 且无任何明细行，同时报价队列 `尝试=0 / 排队=15` —— 探针一次结果都没产出，而真实询价一次都没发出。这不是市场数据问题，是 `.173` 自己把 `Drain()` 打断了。
- **根因（同类 bug 第三次）**：`RunProtocolProbe` 调用了定义在其**之后**的 `ScanPrice` 与 `Publish`。Lua 局部函数不提升，该名字在调用点解析为 nil 全局 → `attempt to call a nil value` → `Drain()` 每 tick 崩在探针那一行，永远走不到下面的真实询价。**`.173` 不但没拿到证据，还回退了 `.172` 已能工作的询价路径。**
- **顺带挖出一个潜伏的同类缺陷**：静态顺序审计发现 `.172` 的名称搜索兜底里 `_CheckFallback` 调用尚未定义的 `CompletePending` —— 即**整条兜底链从写下那刻起就是死代码**。这正好解释两轮报告为何从未出现 `name_search_bid`：不是没触发，是触发了必崩。两处均通过移动到依赖之后修复（`_CheckFallback` → `CompletePending` 之后；探针块 → `Publish` 之后），未改任何语义。
- **新增常驻门禁 `tools/rs_lua_local_order_audit.py`**：静态检出「`local function X` 在其定义行之前被调用」。这是本会话连续三轮栽进去的同一类错误，而 `luaparser` 语法检查与文本 fence 都看不见它（Lua 合法、运行时才炸）。实现要点：剥离注释、跳过定义头行（`local function X(` / `function T:X(`）、剔除 `obj:Method()` / `obj.Method()` 这类带接收者的同名方法调用——后两条是为了消除误报而加，均已用真实样本验证。
- **接入 `rs_foundation_audit`**：作为 `luaLocalOrder=` 汇总项与兄弟 gate 并列，缺失脚本 / 非零退出 / 缺 PASS marker 三种情况都记 failure。当前全工程 **218 个 Lua 文件 0 违规**。
- **误报排查记录**（保留以免被当成漏网）：首版扫描另报两处，逐一核实均为工具误报而非代码缺陷——`rs_combat_event_bus_v3.lua` 命中的是 `function C:AcceptsTransport` 定义头本身；`rs_buff_display_store.lua` 命中的是 `Floating:NormalizeState(...)` 方法调用，与文件内同名 `local function NormalizeState` 无关。修工具后两者归零。
- **防回归**：quote_state harness 升 **69/69**（新增 4 项：探针晚于其全部依赖、兜底晚于 CompletePending、审计脚本存在、审计已接进 foundation audit）。反向破坏测试确认非假绿——把探针挪回 `ScanPrice` 之前会 FAIL `probe_after_its_dependencies`。identity 66/66、craft_modes 25/25、favorites 35/35、presentation API audit PASS、quick_surface 6/6。
- **方法论**：本轮真正的产出不是功能，而是把我个人的重复失误变成机器可检的约束。「改完不回读、基于记忆继续编辑」已经造成三次运行期崩溃级缺陷；现在即使再犯，门禁会在本地阶段拦住，不再消耗一次实机往返。
- **仍未证实**：`GetLowestPrice` 在 RU 的真实语义依旧没有证据——`.173` 的探针从未真正执行过。A 部分的能力拒绝原因透传是有效的（报告已显示 `static=Unavailable`，说明 `X2Craft` 命名空间下该方法确实不是 function），B 部分需本构建重跑。
- **BuildTag**：`v3-m1.16.0.18.174-forward-ref-fix-and-audit`。

## M1.16.0.18.173 — Capability Block Reason + Auction Protocol Probe（2026-09-08）

- **`.18.172` 实机报告结论（假设被证伪）**：探针首次给出决定性读数 `grade 6/7: nil:nil, nil:nil, nil:nil, nil:nil` —— 调用成功（`ok==true`，未走 `call_failed:`），但**四个返回值全是真 nil**。因此 `.172` 补的逗号分组字符串 / gold·silver·copper 复合表解析**不是本次根因**（根本没有值需要解析），"字段名不认识"这条老猜测同时被排除。询价对象是燕麦/稻草捆/鸡蛋/牛奶/红薯这类常年在售的普通交易品，七档全空的市场解释可信度远低于"调用协议不对"。
- **A：能力拒绝原因透传（可观测性）**：live 身份层此前只报自造标签 `能力未放行：GetCraftTypeByItemType`，把 `IsAllowed` 的真实 reason 丢掉了。新增 `CapabilityBlockReason`，透传 registry reason 并附 `static=/official=/runtime=` 三态与**宿主事实**：`host_global_missing`（命名空间全局未建）vs `method_missing_on_host`（表在但方法不是 function）。三者恰好覆盖 `.18.169` 那类"X2Craft 不可用"的盲区。三个 X2Craft getter 改为统一 required-capability 循环守卫。
- **B：有界协议鉴别探针（不再靠猜）**：按技能 §7「不确定时在热循环外加有界诊断探针」新增 `Q:RunProtocolProbe()`——对**必然在售**的控制 itemType（3545 燕麦 / 3712 稻草捆 / 3603 鸡蛋）各发一次 `grade=0` 查询，记录 `ok / err / 四槽 ShapeOf / ScanPrice` 结果。它直接区分三个互斥假设：H1 参数语义不符、H2 需拍卖行/搜索预热服务器缓存、H3 真无挂单。会话内最多 6 次尝试、`done` 后自动停止、**绝不写入 `pricesByItemType`/`quoteStateByItemType`/snapshots**（它是证据，不是报价）。
- **单一车道契约保持**：探针复用既有 drain lane（`Drain` 开头推进，早于 pending 提前返回，避免被单个慢请求拖住），未新增任何 Scheduler 任务；`service_single_lane` / `probe_rides_existing_lane` 双向锁定。
- **报告可达**：`Describe().protocolProbe` → `GetHealth()` → 跑商诊断面板复制报告新增"协议探针:"段（≤6 条逐控制项读数）。下一次实机报告即可判定该继续改协议还是转产品回落逻辑。
- **防回归**：identity harness 66/66（`service_live_gated` 由字面量锁改为语义锁，并新增 `service_gate_reason_propagated`、`service_no_bare_block_label`）；quote_state harness 65/65（新增 9 项探针锁，含"探针永不写读模型"）。两组 fence 均做**反向破坏测试**验证非假绿：移除 reason 透传→FAIL `service_gate_reason_propagated`；绕过能力门→FAIL `service_live_gated`；让探针写价格→FAIL `probe_never_writes_read_model`。
- **仍待实机**：本构建不改变询价成功率，只负责产出可判定的证据。若控制项同样四槽 nil → H1/H2 成立，下一步查 RU 是否需要先 `SearchAuctionArticle`/打开拍卖行填充服务端行缓存（旧版从未使用 `AskMarketPrice`，故不作为候选解）；若控制项返回价格 → H3 成立，转入产品回落（静态底价/`TradePayoutV3` 估算并诚实标注来源）。
- **BuildTag**：`v3-m1.16.0.18.173-capability-reason-protocol-probe`。

## M1.16.0.18.172 — Quote Money Coercion + Name Fallback + TTL Cache（2026-09-08）

- **接力收口 `.18.171` 未完成项**：品质探测协议本身正确，但价格提取与兜底链仍不完整。本轮补齐旧版可证的三段语义，并修掉接力过程中引入的真实缺陷。
- **金额解析完整化（关键）**：新增 `ToMoney`（移植旧版 `rs_auction_service.ToNumber` 完整语义）——支持逗号分组字符串（`"1,234,567"`）、gold/silver/copper 复合表（×10000/×100 合成）、以及 `directPrice/bidPrice/buyoutPrice/lowest_price` 等字段键遍历。此前 `ScanPrice`/`NormalizeQuote` 用裸 `tonumber`，RU 若返回上述形态会被误判为"该档无挂单"，白烧整条品质阶梯。`ScanPrice`、`NormalizeQuote`、兜底取价统一走 `ToMoney`。
- **名称搜索兜底接入**：品质阶梯全部无挂单后，按材料本地化显示名发起**一次**有界拍卖搜索，取首行 `bidPrice`（退化 `directPrice`）作为参考价，来源标记 `name_search_bid`。`AUCTION_ITEM_SEARCHED` 这条无 token 完成边仍由 `AuctionQueryV3` 独占——本服务只调用其 `Search`/`GetSnapshot` 访问器，绝不自行订阅原生事件（共享事实所有权不变量）。兜底保留旧版身份守卫：首行 `itemType` 缺失或不匹配即拒绝，绝不拿相似物品的价格冒充。关键词经 `TrimToKeyword` 限界（1–64 可见字符，剔除控制符）。
- **单一车道契约**：兜底等待复用既有 drain lane（每 paced tick 重入同一请求并由 `_CheckFallback` 推进），不新增第二个 Scheduler 任务。中途曾误加独立看门狗任务，被 `service_single_lane` fence 如实拦下——门禁正确，实现错误，未放宽 fence。
- **会话级 TTL 缓存**：新增 `cache["itemType:grade"]`（TTL 120s，对齐旧版 `cacheTtlMs`）与被动读取入口 `PeekCached`。只有 direct 成交进缓存；`name_search_bid` 参考价不入缓存（估计值不得在后续被动刷新中冒充新报价）。显式 `RequestQuote` 始终绕过缓存——用户主动询价意图优先。失败/无挂单结果一律不缓存。
- **修复接力期真实缺陷（三处）**：① `NormalizeQuote` 前向引用尚未定义的 `ToMoney`（Lua nil 调用，运行必崩）→ 调整定义顺序；② 误插入两份 `ToMoney` 定义 → 去重；③ 重复注释块 → 清理。教训固化为：**连续编辑必须回读文件实跑校验，不得基于记忆继续贴 old_str**。
- **惰性 host 解析**：`CallCapability("X2Auction:GetLowestPrice", nil, ...)` 改为传 `object=nil`，由 `ResolveCapabilityHost` 在调用时解析命名空间全局（同 `.18.169` X2Craft 教训：客户端建全局时机晚于插件加载，捕获期取值会得到永久 nil）。
- **防回归**：quote_state harness 升 **56/56**（原 39 + 17 项新锁：ToMoney 先于使用者定义、扫描路径无裸 tonumber、逗号串/金银铜合成、兜底经 AuctionQueryV3 Authority、不订阅原生事件、身份守卫、估计价来源标记、无第二车道、关键词限界、Trade 传 searchName 且经 Localization、TTL 上界、fallback 不入缓存、PeekCached 存在）。identity 64/64、craft_modes 25/25、favorites 35/35、presentation API audit PASS。
- **仍未证实的假设**：`GetLowestPrice` 在 RU 的真实返回形态依旧没有实机证据——本轮所有形态支持均来自旧版可证实现，不是 RU 实测。`.171` 起 `lastRawReturn` 已带 `grade n/N:` 上下文并对第 2~4 返回值一并 `ShapeOf`，下一份诊断报告应能区分"调用被拒 / 真无挂单 / 返回了未被识别的形态"。
- **BuildTag**：`v3-m1.16.0.18.172-quote-money-fallback-cache`。

## M1.16.0.18.171 — Grade Probe Quotes（2026-09-08）

- **询价失败根因修复（诊断报告实锤：15/15 全部 `nil:nil`）**：`GetLowestPrice(itemType, itemGrade)` 对某一品质返回 nil 是**正常答案（该品质无在售挂单）**，不是错误；静态 grade 提示常与实际最低挂单品质不符。自旧版可证实现恢复品质探测协议：`RequestQuote` 接受有序品质候选（显式 grade → offset+1/offset → 1..6 → 0，去重 ≤8 档），队列对同一请求逐档探测（每档仍守 560ms 服务器冷却），价格可能位于第 2~4 返回值（`ScanPrice` 扫描全部返回槽），全部档位无挂单才落 `unavailable: 全部 N 档品质均无在售挂单`。原始形态记录带 `grade n/N:` 上下文。
- **身份车道 P3→P2**：报告证据 `队列=1 读=0`——P3 维护车道在负载下饿死（`.18.87` 同类前科），live 身份请求永久排队。升至与报价队列同级的 P2。
- **时间成本说明**：15 材料 × 最多 8 档 × 560ms ≈ 最长 1 分钟跑完一批，行随每档成交异步回写；这是服务器查询冷却的固有成本。
- **防回归**：identity harness 升 64/64（品质阶梯、同请求重排、多返回值扫价、无挂单语义、P2 车道）。
- **BuildTag**：`v3-m1.16.0.18.171-grade-probe-quotes`。

## M1.16.0.18.170 — Trade Init Trace（2026-09-08）

- **跑商初始化追踪（用户反馈"重载后点开跑商页很多东西没初始化成功"，静态分析无法定位具体层）**：Trade Feature 新增有界初始化里程碑环（12 条），记录 demand 0→1（consumer/_enabled/storeLoaded/持久化路线）、事件订阅失败、地区/熟练度初始化结果（zones/fallback/commerce 状态）、货率返回行数、enable/disable。诊断面板新增"初始化"汇总行 + 最近里程碑，"复制诊断报告"携带完整追踪。下次复现时报告会直接显示是 store 未恢复、地区 API 失败、还是 Consumer/事件链断裂。
- **BuildTag**：`v3-m1.16.0.18.170-trade-init-trace`。

## M1.16.0.18.169 — Lazy Craft Host Fix（2026-09-08）

- **修复 live 身份层 `X2Craft 不可用`（首份跑商诊断报告证据）**：报告确认静态身份层已实机打通（`配方 7/8`，`[黄金]保存传统特产→Halcyona Preserved Local Specialty` 尾词映射验证正确，15 个待询价材料识别），唯一未解析的 `黄金平原尾毛被子` 走 live 层时报 `X2Craft 不可用`。根因：服务在**加载时**捕获 `rawget(_G, "X2Craft")`，客户端建全局时机晚于插件加载则捕获到 nil 且永不更新。现改为传 `object=nil` 让 `ResolveCapabilityHost` 在**调用时**惰性解析命名空间全局（API 层既有机制）；若全局确实不存在，错误将变为明确的 `capability host unavailable: X2Craft:...`，报告可区分"命名空间缺失"与"原生返回不可读"。
- **BuildTag**：`v3-m1.16.0.18.169-lazy-craft-host-fix`。

## M1.16.0.18.168 — Trade Diagnostics Panel（2026-09-08）

- **跑商专属诊断浮窗**：跑商页面新增"诊断"按钮，打开只读诊断面板（`TradeDiagnosticsV3`，会话级浮窗，无 Consumer、无 Commands、无持久化）。面板包含：三层汇总（路线/身份/live 队列、报价队列统计、最近原生返回形态）、最近 12 条询价逐条记录表（时间/itemType/状态/价格/**原始返回形态或错误**）、"复制诊断报告"按钮（经 SafeChat 输出有界多行报告，含最近询价、live 身份失败、逐行材料明细与首错）。订阅 Feature 更新与报价完成主题实时刷新。
- **报价队列可观测性升级**：`PriceQuoteQueueV3` 记录每次原生调用的**有界原始返回形态**（`ShapeOf`：类型+表字段名列表，≤12 字段）、尝试/成功/失败计数、最近完成环形记录（12 条）。这是回答"RU `GetLowestPrice` 到底返回什么"的第一手探针——询价失败率高的根因（字段形态不匹配）将直接可见。诊断页"报价队列"行追加 尝试/成功/失败 与 形态= 段。
- **身份服务**：live 身份失败环形记录（8 条）进 Describe，诊断报告逐条携带。
- **防回归**：identity harness 升 57/57——新增面板 TOC 顺序、只读边界（无 Commands/Consumer/原生调用/持久化）、复制走 SafeChat、原始形态捕获与统计锁。
- **BuildTag**：`v3-m1.16.0.18.168-trade-diagnostics-panel`。

## M1.16.0.18.167 — Trade Identity Facade Fix（2026-09-08）

- **修复 `.18.165` 静态解析层整体失效（用户实机：全部行"解析中"、按钮禁用）**：`TradeMaterialIdentityV3` 把访问器门面表 `S.Data.TradeStaticV2`（承载 GetRecipeByLegacyName/GetMaterialBy*）误当成注册表 `S.StaticDataV2`（只有 GetCatalog）捕获，`ResolveStatic` 守卫直接返回 nil——三层解析的静态层从未运行，所有行落入 live 分支。本实机症状同时证明 RU 货率行**携带产品 itemType**（live 层激活前提成立）。
- **修复卡死状态机**：live 尝试已终局（失败或空结果）时行仍显示"配方解析中…"。现 `HasLiveAttempt` 区分"排队/在飞（解析中）"与"已终局（配方未匹配）"，且空 ready payload 按失败落账，不再有永久解析中。
- **新增 Real-Lua harness `rs_trade_material_identity_lua_harness.py`**：真加载服务文件 + 真配方/家族/模板数据，按运行时表名注入访问器门面，断言 Gilda/传统特产→Local/特产尾词、家族奶酪行、肥料模板、无地区不解析、未知不伪造等 8 组语义。此类"表可达性"错误文本 fence 抓不住，只有真加载能抓（本机无 Lua 解释器，封包机执行）；静态 fence 同步锁定门面捕获与注册表禁用（43/43）。
- **BuildTag**：`v3-m1.16.0.18.167-trade-identity-facade-fix`。

## M1.16.0.18.166 — Trade Boundary + Diagnostics Hotfix（2026-09-08）

- **修复 `service_presentation_boundary[invalid=TradePayoutV3:missing]` 阻断**：`.18.163` 引入 `TradePayoutV3` 时漏声明 `presentationBoundary`，运行时门禁如实拦截（本地静态门禁不执行该运行时契约，且未主动扫）。已补 `service_only`，并把「凡注册进 `S.Services` 必须声明边界」固化为 `rs_trade_material_identity_harness` 的全 services 目录类级 fence。
- **修复跑商诊断行 `状态机诊断不可用`（历史缺陷）**：诊断读取 `feature.DescribeRequestState`，但该方法只定义在 `Trade.Authority`（TA）上，Feature 表上不可达——该行自加入起就不可能工作。债券行正常恰因 `DescribeDailyCache` 定义在 Feature 表上。现补 `Trade:DescribeRequestState/DescribeIdentityState` 委托，并 fence 锁定所有诊断消费的 describe 助手必须在 Feature 表可达。
- **BuildTag**：`v3-m1.16.0.18.166-trade-boundary-diag-hotfix`。

## M1.16.0.18.165 — Trade Material Identity Recovery（2026-09-08）

- **实机根因修复（用户截图 .18.164）**：RU 服务器返回本地化中文货物名，而静态配方表按英文 legacy 名索引，`GetRecipeByLegacyName(中文名)` 全部落空 → 所有行"材料待确认"、材料行为空、材料询价按钮永久禁用。另发现第二个身份 bug：静态配方材料键为 `material.xxx` 注册键而拍卖元数据表按英文名索引，即使配方匹配材料也无法解析身份。
- **新增共享服务 `TradeMaterialIdentityV3`**（语义自旧版可证实现恢复，不迁旧架构）：三层身份解析。① 共享静态家族：中文名关键字直接命中全地区同配方（肥料特产/陈化蜂蜜/陈化奶酪/陈化药材/时空碎片/蓝盐运输，材料表按 compact id 原样移植）；② 地区 Authority + 中文尾词：`originZoneId → GameIds.Zone(nameEn+tradeQuality)` 选择地区，本地化文本只选家族词（特制特产=Gilda Specialty、传统特产=Local Specialty、特产=Specialty）——**本地化文本永不决定地区**（旧版 [十字星]→Hasla 误映射教训）；③ live craft 事实：`X2Craft:GetCraftTypeByItemType + GetCraftProductInfo(产品侧验证) + GetCraftMaterialInfo`，按货率行携带的产品 itemType 解析（三个能力均已 OfficialEnabled，含 2026-06-02 GetCraftMaterialInfo 崩溃修复注记），250ms 串行队列、会话缓存、requester 取消、fail-closed。
- **行级接入**：货率行捕获产品 itemType（bounded 字段列表，RU 形态未证时退化为纯静态链）；材料投影重写为逐层回退，未解析行诚实显示 `配方未匹配`（无 itemType）或 `配方解析中…`（已提交 live 解析）；解析完成后仅重建受影响行。生命周期：需求归零/功能关闭/路线重查即取消该 Feature 的待处理身份请求。
- **可观测性**：投影新增 `unresolvedIdentityCount`，主页面/HUD 状态行显示"· 配方待解析 N"；诊断页跑商行追加 `配方 X/Y · 解析中 N · live读N 缓存ready/failed`，可直接判断静态层命中数与 live 链真实健康状况。
- **防回归**：新增 `rs_trade_material_identity_harness.py` 36/36，锁定尾词映射、地区 Authority（禁止中文地区前缀映射）、能力门禁、单队列、所有权边界（X2Craft 仅存在于身份服务）与 TOC 顺序。
- **验证**：静态套件本轮可执行项全部 PASS（Foundation Audit toc=225/225、Feature API Audit、RSUI Audit、trade 专项 25/25、35/35、39/39、36/36）；本机无 Lua 编译器，parse 步骤与 Real-Lua harness 在封包机执行，修改文件已 luaparser 补偿解析通过。
- **BuildTag**：`v3-m1.16.0.18.165-trade-material-identity-recovery`。

## M1.16.0.18.164 — Trade Quote State Observability（2026-09-08）

- **材料询价失败可见化**：`PriceQuoteQueueV3` 新增共享按 itemType 报价生命周期读模型 `quoteStateByItemType`（queued/inflight/ready/failed）；失败完成记录真实错误（如"最低价返回不可读（当前 RU 字段待核）"），材料不再永远停留在无解释的"待询价"。fail-closed 语义不变：只有 ready 完成才写入 `pricesByItemType`，失败不清除已有可信价。
- **Trade 材料投影状态**：材料行新增 `quoteState/quoteError`，costStatus 区分 `quote_pending`（询价排队中/询价中）与 `quote_failed`（询价失败）；详情悬浮窗状态列显示对应状态，存在失败时提示区直接显示第一条真实失败原因，底部状态条显示 待询价/询价中/询价失败 计数。
- **命令语义**：`QuotePendingMaterials/QuoteRowMaterials` 把失败材料视为可重试的待询价项，排队/在飞材料自动跳过；`QuoteMaterial` 对同一 itemType 的重复请求返回"已在报价队列中"，不再重复入队。投影新增 `quoteInFlightCount`，主页面与 HUD 状态行显示"· 询价中 N"。
- **诊断面**：诊断页新增独立"报价队列"功能行（运行/在飞/排队/已报价品类/最近一次 requester#itemType 状态、来源与错误），并进入 `Snapshot().priceQuoteQueue`；一键复制行可直接携带 `GetLowestPrice` 失败原因，供 RU 实机核对真实返回形态。
- **防回归**：新增 `rs_trade_quote_state_harness.py` 39/39，锁定服务状态图、投影/命令语义、三个 UI 入口、诊断行与 Presentation 无原生拍卖访问的归属 fence。
- **验证**：静态套件本轮可执行项全部 PASS（含 Foundation Audit 全部契约检查 toc=224/224、Presentation Feature API Audit calls=389、RSUI Component API Audit calls=561）；本机无 texluac/lua 解释器，`Active Lua parse` 步骤与 Real-Lua harness 在封包机执行，7 个本轮修改文件已用 luaparser 语法解析补偿通过。
- **BuildTag**：`v3-m1.16.0.18.164-trade-quote-state-observability`。

## M1.16.0.18.163 — Trade Payout Formula Recovery（2026-09-08）

- **恢复预计售价完整计算链**：新增纯数据 `TradePayoutV3`，继续以 X2Store 实时货率和 X2Ability 经商熟练度为事实 Authority；预计售价恢复为 `静态底价 × 货率 × 经商倍率 × 贸易品类别倍率`。
- **经商倍率**：恢复用户提供旧版中实际使用的 `1 + skill/10000*0.05`；默认“熟练：计入”，显式“忽略”仅用于对比。若计入模式下熟练度读取失败，售价 fail-closed 为 `--`，不再输出少乘一层倍率的误导数字。
- **品类倍率**：恢复 `TradeNameMultipliers`（标准/新鲜/特供/基本发酵/加工发酵/无添加发酵/天然发酵）；原始名称无类别 token 时允许从已验证 canonical price key 回退识别。
- **价格 Key 解析**：恢复别名与奶酪/药材/蜂蜜 larder canonical resolver，优先使用当前路线出发地区，避免服务器显示名与静态 payout key 不完全一致导致 `--`。
- **可观测性**：贸易品行新增 `priceKey/keyMode/baseAtRatio/commerceMultiplier/packMultiplier/priceBreakdown`；详情悬浮窗直接显示熟练与品类倍率。
- **BuildTag**：`v3-m1.16.0.18.163-trade-payout-formula-recovery`。

## M1.16.0.18.162 — Bag Quick Transient Window Recovery（2026-09-08）

- **修复仓库/箱子已打开但“取 / 放 / 停”快捷条不显示的 Presentation 根因**：旧 `rs_v3_bag_quick_overlay.lua` 仍使用 `UIParent` 顶层 `emptywidget + system layer`。项目 Native Primitive 已有 RU 实机结论：该宿主形态不能作为可靠顶层可见 Surface；Unit Lines 曾因同类问题出现“投影有效但屏幕零可见点”。`.162` 将 Bag Quick Overlay 迁为真实 `transient WINDOW` Host，子按钮继续走共享 RSUI/Button 与既有命令链，不建立第二 UI Authority。
- **修正 Bag Native Window Fact 优先级**：`GetContentMainScriptPosVis` 的第 5 返回值现在接受 boolean/0-1/常见 string 形态；显式 Native visible/hidden 为最高 Authority。`ADDON:GetContent` 短父链只提供正向可见证据，hidden proxy 不再覆盖已经存在的合法 MainScript geometry；无显式 visible 时，合法四返回值 geometry 可以证明窗口已打开。`RequireStorageWindow` 与 Quick Overlay 继续消费同一事实函数。
- **首开重试闭环**：Bag Quick transient Host 在模块 admission 时预创建为 hidden；实际 bag+bank/coffer 可见期间，既有 350ms 低成本 observer 发布 bounded visible heartbeat，使首次 Native Window/Handler 构造若临时失败可自动重试，而不会因为 feature state 已经 visible、后续状态未变化而永久不再创建。关闭仓储窗口后 heartbeat 停止。
- **性能边界不变**：Observer 仍只读取 UIC_BAG/UIC_BANK/UIC_COFFER 的窗口事实，不创建 InventorySnapshot、不遍历物品、不移动槽位；重型扫描/Move Queue 仍只允许显式点击“取/放”触发。显式 `tools_bag=false` 仍是最终 FeatureRuntime Authority。
- **门禁**：Bag Native Quick v7 / Reload Observer v3 / RU Four-Value Visibility v2 / Native Visibility Shape v1 / Visible Presenter Retry v1；Bag Quick Presenter v4 / Transient Host v1 / Visible Retry v1。Quick Surface Reload 6/6、Bag Move Queue v8 11/11、全量 41/41 Python Harness、Foundation Audit PASS、Lua Parse 223/223。
- **BuildTag**：`v3-m1.16.0.18.162-bag-quick-transient-window-recovery`。

## M1.16.0.18.161 — Settings Numeric Slider + Unit Lines Card Layout（2026-09-08）

- **纠正 `.160` 的错误取舍**：Unit Lines 4 张样式卡不再为了压高度把 `slider=false`；全局 4 项 + 单线 8 项现在全部通过新增的 `SettingsNumericSlider -> NumericField` 薄策略，统一获得 Slider + 可编辑 NumericInput + Apply。Binding、Draft、动态范围与 Persistence Authority 仍只在 NumericField/NumericRangeStore。
- **动态范围继续成立**：点大小的代码默认 Slider 范围仍为 `2..10`、业务硬上限 `24`；精确输入 20 后共享 NumericField 会把 Slider presentation max 扩至 20 并持久化 range metadata。密度/透明度/刷新间隔使用 fixed business range，避免无意义扩张。
- **SettingsFoundation v3 视觉层级**：SettingsSection 改为 flat title + soft Divider + content，不再用 Card 做“黄框套黄框”；真正需要边界的 StyleCard 默认改为 `soft`、无 accent strip、无默认 gradient。UITokens v8（StyleCard 默认 300×116、Header 20、Page section gap 收紧），Design System v10。
- **Unit Lines Card 重排**：每张卡改为两条完整 NumericSlider 行（密度/点大小）+ 一条 ColorField；删除 `.160` 的双 Numeric 横向挤压行。可见文字去除 RU 字体可能缺失的 `↔/✓/○` 字形，改为中文安全文本与 `：开/：关` 状态。2 列卡片 `minCellWidth=300`，窄宽度自动 1 列，不写分辨率特判。
- **门禁**：SettingsFoundation v3 增加 `SettingsSectionHierarchyContractVersion=1`、`SettingsNumericSliderContractVersion=1`、ScrollSafeCard v2、StyleCard v3；BusinessPages v6 / UnitLine Consumer v3。Unit harness 强制 12/12 数值设置均为完整 slider 组合、8/8 单线 Slider、4/4 点大小保留 10->24 adaptive range，并禁止 Unit Lines 分支重新出现 `slider=false`/ResponsiveNumericSetting/手写 numeric row。
- **验证**：41/41 Python Harness PASS；Settings Page Foundation 35/35；Unit Line Settings Page 43/43；UI Interaction Range 61/61；Interactive Draft 115/115；Foundation Audit PASS；Lua Parse 223/223。
- **BuildTag**：`v3-m1.16.0.18.161-settings-numeric-slider-card-layout`。

## M1.16.0.18.160 — Unit Lines Dense Settings Layout（2026-09-08）

- **修复 `.159` 实机布局与设计目标不一致**：`SettingsToggleGrid` 的 Toggle 不再 `fill` 整个网格单元；标准设置页默认使用紧凑 Toggle 宽度与左对齐，Unit Lines 4 个开关在可用宽度内最多 4 列，窄宽度自动降列。
- **修复 768p 下“样式卡看似消失”的 ScrollBox 组合问题**：RU ScrollBox 使用安全整项吸附；`.159` 将 4 张 StyleCard 包在约 300px+ 的单个 Section 中，当前 viewport 剩余高度不足时整块延后，形成大面积空白。`.160` 收紧 Settings tokens/Section/Card chrome，并把单线样式改为“密度 + 点大小”同一紧凑行（卡内不再重复 Slider，保留精确输入+应用），全局设置继续保留 Slider。
- **SettingsFoundation v2**：新增 `compactToggleContractVersion=1`、`scrollSafeCardContractVersion=1`；StyleCard/Section headerHeight 可配置，UITokens 升 v7，Design System 升 v9。Unit Lines Consumer 契约升 v2 / BusinessPagesContract v5。
- **768p 防复发**：`rs_unit_line_settings_page_harness.py` 增加样式区高度预算，2×2 卡片估算高度必须 `<=250px`；同时验证 4 个紧凑 Toggle、8 个卡内 input-first Numeric、4 个样式卡与默认折叠诊断。
- **验证**：41/41 Python Harness PASS；Unit Line Settings Page 35/35；Settings Page Foundation 30/30；Foundation Audit PASS；Lua Parse 223/223。
- **BuildTag**：`v3-m1.16.0.18.160-unit-lines-dense-settings-layout`。

## M1.16.0.18.159 — Unit Lines Settings Foundation Consumer（2026-09-08）

- **首个正式 SettingsFoundation Consumer**：`combat.unit_lines` 从旧 `PageHeader + 大块 Toggle + CompactNumericSetting + 手写 VerticalBox 卡片 + 常驻 TableView` 迁到 `.18.158` 的共享 `FeatureSettingsHeader / SettingsSection / SettingsToggleGrid / ResponsiveNumericSetting / SettingsStyleCardGrid / SettingsStyleCard / SettingsDiagnosticsDisclosure`。Feature Projection/Commands、Store、Demand、视觉刷新与投影 Authority 均未改变。
- **信息层级重构**：页头只保留功能状态、开关和刷新；四类连线开关进入紧凑 ToggleGrid；全局显示与每条连线样式分区；四条连线改为 2→1 列响应式 Style Card。默认密度/点大小明确标注为旧配置/缺省回退，避免与单线覆盖语义混淆。
- **诊断与普通设置分离**：`unit_projection_unavailable`、端点重合、投影失败及事实 TableView 全部移动到默认折叠“高级 / 诊断”；主摘要只显示正常/部分可用/等待目标等用户状态，不再裸露底层错误串。诊断 TableView 限制 5 行，展开才占页面空间，不启动新 Consumer。
- **响应式策略**：全局数值区按 available width 2→1 列；Style Card `minCellWidth=292`、最多 2 列；每个 Numeric 继续用 exact EditBox + Slider + Apply，并在更窄 Card 内由共享 `responsiveStack` 自动换行。禁止任何 1024/1280/1920/2560 分辨率特判。
- **防复发门禁**：`BusinessPagesContract v4` 新增 `unitLineSettingsFoundationConsumerContractVersion=1`；Foundation Gate v133 / UIV3 Acceptance v87 增加 `v3_unit_line_settings_page_contract`；Foundation Audit 禁止 Unit Lines 分支重新出现 `CompactNumericSetting`、旧 appearance grid 或分辨率魔法数。新增 `rs_unit_line_settings_page_harness.py` 28/28，真实构建形状验证 4 Toggle / 12 Responsive Numeric / 4 Style Card / 4 ColorField / 默认折叠 Diagnostics / Table 归属与主摘要不泄露 raw error。
- **验证**：全量 `41/41` Python Harness PASS；Settings Foundation 28/28、Unit Line Settings Page 28/28、UI Interaction 61/61、Interactive Draft 115/115、Input Focus/Drag 110/110、Unit Line E2E 34/34、Sampling 11/11；Foundation Audit PASS（`toc=223 / activeLua=223 / allLua=223`）；Lua `223/223` Parse PASS。
- **BuildTag**：`v3-m1.16.0.18.159-unit-lines-settings-foundation-consumer`。

## M1.16.0.18.158 — Settings Page Foundation（2026-09-08）

- **先补底层，不先重排单位连线页面**：新增 `RSUI.SettingsFoundation v1`，统一 Feature Header、ToggleGrid、SettingsSection、StyleCard/Grid、Responsive SettingRow、Responsive NumericSetting、默认折叠 DiagnosticsDisclosure。全部由现有 RSUI Measure/Arrange/BuildScope 组合，不建立第二套布局 Authority，不新增 Tick/OnUpdate。
- **FormRow Responsive v1**：修复原 vertical Measure 把 child width 误当 height 的真实 bug；`layout=auto/responsive` 以当前可用宽度切换 horizontal/vertical，窄窗口不再把 label/control/hint 压成一行。
- **Numeric Responsive Stack v1**：NumericField v7 增加 opt-in `responsiveStack`；标准 settings numeric 默认开启，窄宽度下 label 自动上移、Slider + exact input + Apply 留在第二行，Binding/持久化 Authority 不变。旧 `CompactNumericSetting` 默认行为不变，避免一次性改变所有现有页面。
- **统一 Settings Tokens**：UITokens v6 新增 settings 密度/卡片/网格/setting-row/numeric breakpoint；Design System v8 提供薄代理，后续页面不再手写重复 minCellWidth/卡片/诊断区结构。
- **门禁**：新增 `rs_settings_foundation_harness.py` 28/28；Responsive Numeric 回归纳入 `rs_ui_interaction_range_harness.py`；Foundation Gate v132 / UIV3 Acceptance v86。全量 `40/40` Python Harness PASS、Foundation Audit PASS（`toc=223 / activeLua=223 / allLua=223`）、TOC Lua `223/223` Parse PASS。下一步才迁移 Unit Lines 页面消费这套 Foundation。
- **BuildTag**：`v3-m1.16.0.18.158-settings-page-foundation`。

## M1.16.0.18.157 — Resolution / Coordinate Foundation（2026-09-08）

- **不再按分辨率写补偿表**：针对 1280×768 与 2560×1440 之间世界视觉轻微漂移，以及用户在多种 4:3/5:4/5:3/16:10/16:9 分辨率下的悬浮窗口/屏幕按钮位置兼容，统一收敛到 Layout Authority。禁止新增 `1280x768 +N`、`1920x1200 +M` 之类分辨率魔法表。
- **Screen→Overlay Host Contract v1**：`ScreenProjectionV3` 继续只拥有原生 UIParent Screen Coordinate；`Layout:GetUiParentLocalOrigin/ScreenPointToWidgetLocal` 负责把屏幕点转换为当前 Native Overlay Host 的本地坐标。转换先把 Host EffectiveOffset 与 UIParent 自身 EffectiveOffset 归一到同一 logical space，再只减一次 `Host-UIParent` 原点；因此即使 `CorrectOffsetByScreen` 或某分辨率让顶层 WINDOW/UIParent 出现非零原点，也不会二次偏移。CombatVisualGuides 每个渲染批次只读一次 transform，Unit Lines/Range 共用，不增加逐点 Native geometry read。
- **Range Label 几何同源修复**：Range Assist 也使用 1×1 `'.'` Label；旧 `PlaceDot` 仍残留 `x-size/2,y-size/2`。现与 `.154` Unit Lines 一致：font size 只控制 glyph 墨迹，绝不参与坐标。
- **Responsive Placement Intent v1**：`Layout:StorePlacement` 对 free/recoverable Surface 继续保存精确 logical x/y，同时增加 `savedLogicalWidth/Height + normalizedCenterX/Y`。同一 logical viewport 原样恢复；检测到真实分辨率变化时按归一化中心重投影并保证标题/拖动区仍可恢复。旧 `logical-free-v2` 没有 source viewport 时不猜原分辨率，只做 recoverable safety；用户下一次拖动自然补齐新元数据。
- **窗口/按钮覆盖**：RSUI FloatingSurface v11 统一携带响应式位置意图，因此 DPS、状态显示、死亡回顾、活动/任务、跑商/生活浮窗、Auction/Craft Sidecar 等共用处理；主 Shell 同样保留该元数据。小型屏幕按钮统一优先边缘意图：Gear 快捷按钮继续使用 `logical-edge-v1`，R launcher 在用户下一次拖动提交后也由旧 free 坐标升级为 nearest-edge + margin；分辨率改变时保持用户选择的屏幕区域而非旧物理像素。Bag 快捷按钮仍从当前背包窗口实时派生，不持久化物理像素。
- **诊断**：Unit Lines/Range 运行状态新增 `Host=x,y / 视口=WxH / UIScale`，后续实机可直接区分 Native Projection 与 Overlay Host 原点问题。
- **验证**：新增 `rs_resolution_coordinate_harness.py`，覆盖截图所示主流 1024×768、1152×864、1176×664、1280×720/768/800/960/1024/1440、1360/1366×768、1440×1080、1600×900/1024/1200、1680×1050、1920×1080/1200/1440、2560×1440；响应式自由窗口、边缘按钮、Host local conversion 共 `46/46 PASS`（含 non-zero UIParent origin 与 strict edge-store）。Unit Line E2E 额外模拟非零 Host origin，34/34；全量 `39/39` Python Harness、Foundation Audit、222/222 Lua parse PASS。Foundation Gate v131 / UIV3 Acceptance v85。
- **BuildTag**：`v3-m1.16.0.18.157-resolution-coordinate-foundation`。

## M1.16.0.18.156 — EditBox Post-Arm Focus Promotion（2026-09-08）

- **RU 实机根因确认**：`.18.155` 为保护鼠标确定的 caret 位置，`ActivateInputWidget()` 在 `GetFocusedWidgetId()` 已指向当前 EditBox 时跳过 `SetFocus()`。但 RU 的鼠标事件顺序允许“Native 先发布 Focus ID，Lua OnClick 后执行”，此时 EditBox 仍处于 `EnableKeyboard(false)`。随后 Lua 仅把 Keyboard 升为 true，却因“already focused”误判跳过 `SetFocus`，最终形成**外观/Focus ID 都像已选中，但 Native 文本输入通道没有进入键盘编辑模式**的假 Focus。
- **Post-Arm Focus Promotion Contract v1**：`ArmInputWidget()` 的 `changed` 返回值现在参与激活事务。只要本次点击确实发生 `EnableKeyboard(false -> true)`，无论 Global Focus ID 是否已经指向当前 EditBox，都必须在 Keyboard promotion 之后执行一次 `SetFocus()`。只有“Keyboard 已 armed + Focus 已证明属于当前 EditBox”的重复点击才允许跳过 `SetFocus`，继续保护 caret。
- **输入诊断闭环**：UI Framework Snapshot 新增 activation attempt/success/failure、post-arm promotion、focused fast-path、当前 armed input、Keyboard arm/disarm/失败计数；“打印全部日志”增加 `UI输入` 行，若 RU 仍有特殊 Focus 形态可以直接判断失败发生在 Keyboard admission 还是 Focus admission。
- **不回退 Deferred Keyboard 安全边界**：EditBox 构造仍保持 `EnableKeyboard(false)`，不会重新引入 `.18.117` 之前“页面一打开就吞 WASD/技能/聊天键盘”的故障；LostFocus/隐藏/禁用/失去 Pick/Runtime Stop/Release 仍统一 ClearFocus + Disarm。
- **回归**：运行时 Harness 新增“鼠标 Focus 已先成立但 Keyboard 尚未 armed”的真实 RU 时序；第一击必须恰好一次 post-arm `SetFocus`，第二次已 armed 重复点击不得增加 `SetFocus`。UI Framework v15，NativeCaretPlacement v2，PostArmFocusPromotion v1，InputActivationDiagnostics v1，UIV3 Acceptance v84，Foundation Gate v130；Input Focus/Drag 110/110、222/222 Lua parse、Foundation Audit PASS。本地实测 35 / 38 Harness：`interactive_draft`（本轮已扩至 115 断言，仍在失败）/ `recovery_launcher` / `runtime_entry_lifecycle` 三个 Lua 5.4 语义敏感运行时 harness 在本机唯一可用的 Lua 5.4.5 下失败，与 `.18.145` 基线同类环境失败、非本轮引入，按 TEST-001 如实记录；上述三者的通过声明须待统一解释器或 5.4 兼容改造后复验。
- **BuildTag**：`v3-m1.16.0.18.156-editbox-post-arm-focus-promotion`。

## M1.16.0.18.155 — EditBox Foundation Draft / Caret / Focus（2026-09-07）

- **可见编辑状态**：Native EditBox/MultiEditBox 显式配置已验证的 `SetCursorColor/SetCursorHeight`，保留 Native 自己的闪烁；输入获得所有权时共享边框切换为高亮，LostFocus/Commit/Disable/Release 统一恢复。
- **普通编辑体验**：取消全局 `UseSelectAllWhenFocused(true)`，改为 `false`；用户点击具体字符时不再强制全选。`ActivateInputWidget` 若已证明 Native 已聚焦，则不重复 `SetFocus`，避免 RU skin 把刚由鼠标确定的 caret 位置重置。
- **Draft 防回灌 v4**：TextInput/NumericInput 编辑期间改为“只有 `commit/rejected/restore_authority` 可以覆盖”的显式 allowlist；未知未来 refresh source 默认视为 ambient，不能再把删除/修改后的 Native draft 刷回旧 Binding。Slider preview 保留独立的 interaction override。
- **Focus Identity 兼容**：UI Framework v14 同时登记 physical/logical Suite input identity；`GetFocusedWidgetId()` 返回任一种已登记身份都能证明 Focus，但仍绝不触碰无法解析为 Suite input 的游戏/聊天焦点。Focus Contract v3。
- **生命周期清理**：TextInput/NumericInput Disable/Release 新增 CancelEditing，清理 component-local editing、DraftCoordinator、Keyboard/Focus 和 focus visual，并回画业务 Authority，防止隐藏页留下幽灵草稿。
- **输入细节**：TextInput/NumericInput 的 `placeholder` 现在落到 Native `SetGuideText`。Raw multiline 通过 `BindDeferredInputActivation` 继承同一 focus visual。
- **版本**：RSUI v48 / API 13.2，Native Interaction v7，InteractiveDraft v4，InputDraftCommit v2，Foundation Gate v129。
- **BuildTag**：`v3-m1.16.0.18.155-editbox-foundation-draft-caret-focus`。

## M1.16.0.18.154 — Unit Lines Raw Projected Head Anchor（2026-09-07）

- **RU 实机反馈**：单位连线已经能稳定绘制，但整条线相对角色头顶中心有轻微统一偏移。沿 `UnitLines read → ScreenProjectionV3 → CombatVisualGuidesV3` 对账确认投影层返回的原生 `GetUnitScreenPosition` 坐标没有二次缩放；偏移产生在最终 Label 点放置。
- **根因**：Unit Lines 使用 `1×1` 的 `'.'` Label，字号只属于 TextStyle；旧版可用 `rp_ui` 参考直接把这个 1×1 Label 锚在投影 `(x,y)`。当前 `PlaceUnitDot` 却再次执行 `x-size/2, y-size/2`，把**字体大小误当成 Widget extent**。默认点大小 4 → 约 22px 字号，因此全部点统一向左上偏约 11px；点越大偏移越明显。
- **修复**：Unit Lines 的 Label anchor 改为投影坐标 1:1 整数落点，字号只改变字形墨迹，不再改变路径几何。`ScreenProjectionV3`、Native depth、World Alias Guard、采样密度、颜色、刷新节拍均不修改；Range Assist 保持 `.18.141` 已实机通过的独立校准/点放置链，避免无关回归。
- **防复发**：`CombatVisualGuidesV3 v10` 新增 `UnitLineRawProjectedAnchorContractVersion=1`；E2E Harness 从原先允许 ±64px 的宽松范围收紧为首尾点必须与 raw projected endpoints 在 ±1px 内一致，并在 Foundation Audit 禁止 `PlaceUnitDot` 再引入 `size/2` 坐标补偿。
- **BuildTag**：`v3-m1.16.0.18.154-unitline-raw-projected-head-anchor`。

## M1.16.0.18.153 — Bag Native Window Visibility Recovery（2026-09-07）

- **整理背包快捷按钮真实根因**：`.18.152` 解决了默认生命周期，但 `ReadBagWindowContext/ReadStorageWindowContext/RequireStorageWindow` 仍把 `ADDON:GetContentMainScriptPosVis()` 的第 5 返回值 `visible` 强制要求为 boolean。项目内 AuctionSurfaceV3 已有 RU 实机证据：部分 Native Content 只返回 `x/y/width/height` 四值，导致背包/银行/箱子明明已打开仍被 Bag Observer 判为 unknown/hidden，`quickOverlay.visible` 永远无法成立。
- **统一 Native 窗口事实**：Bag/Bank/Coffer 现在优先使用显式 boolean；缺失时读取 `ADDON:GetContent` 的短父链 `IsVisible` 作为更强事实；若内容可见性完全不可得但 MainScript 四值矩形合法，则采用已验证的 RU geometry-open compatibility path。背包 MainScript 几何不可用时还允许从 Content/Parent 的 `Layout:GetLogicalRect` 找到最近合法锚点。未知/非法矩形继续 fail-closed。
- **写动作同源**：`RequireStorageWindow()` 改为复用 `ReadStorageWindowContext()`，观察 Overlay 与实际取/放动作不再使用两套不同 visible 判定。关闭/未知窗口仍拒绝原生移动。
- **诊断**：`quickOverlay` 记录 bag/bank/coffer 的 `status/visible/source/reason`；整理背包页直接显示 `main-script / main-script+content-vis / main-script-geometry / content-hidden` 等来源，若 RU 仍有特殊窗口形态可直接定位。
- **兼容边界**：没有新增 Bag 自动 preference 迁移。`FeatureRuntime:GetPreferredEnabled()` 对显式 `v3.features.tools_bag=false` 仍保持用户设置 Authority；`.18.153` 不会为了显示快捷按钮偷偷重开用户明确关闭的功能。
- **性能**：350ms Observer 仍只读 3 个 Native Window 的几何/可见性；不调用 `InventorySnapshotV3`、不扫描物品、不执行移动。
- **BuildTag**：`v3-m1.16.0.18.153-bag-native-window-visibility-recovery`。

## M1.16.0.18.152 — Quick Surface Reload Reconcile（2026-09-07）

- **`.18.151` RU 复验通过**：Foundation `阻断0/警告0`，`v3.death_review` 已通过 known-stamp migration 并解除 Fence；页面构建失败/隔离/事务回滚/事务失败均为 0。当前新问题与 Persistence 无关，收敛到 Reload 后两个快捷 Surface 生命周期。
- **整理背包 Reload 根因**：`tools_bag` Registry 之前 `defaultEnabled=false`，而 `StartBagQuickObserver()` 只在 Feature Enable 时启动；因此 Fresh Reload 后没有任何 Authority 观察 `UIC_BAG/UIC_BANK/UIC_COFFER`，打开箱子不会发布 `quickOverlay.visible`。`.18.152` 将该 Feature 定位为 `independent_low_cost + defaultEnabled=true`：默认只运行 350ms 的有界 Native 窗口几何/可见性观察，InventorySnapshot/Move 队列仍只在用户显式点击“取/放/整理”后创建；用户显式关闭 Feature 后观察任务立即释放。
- **换装 Reload 根因**：真实诊断为 `一键换装 关闭`。旧版本允许“`quick=true/quickHud.visible=true` 已持久化，但 `v3.features.combat_gear=false`”的历史分叉；页面 `AcquireTransient(page:gear)` 临时启用 Gear 后会触发 `SyncQuickButtonsHost()`，于是表现为“Reload 没按钮，手动换一次后才出现”。FeatureRuntime v4 新增 `StartupEnableIntentContractVersion=1`：Feature 只能提供 store-backed 的一次性启动意图证明，Runtime 自己执行 preference 事务。Gear 对**尚未链接**且已有可见 quick plan 的历史状态执行一次 `false -> true` 修复，并用可选 numeric sentinel `runtimePreferenceLink=1` 标记完成；以后用户再次显式关闭 Gear，Startup 不会偷偷重开。
- **Authority/Proxy 收口**：`ShouldShowQuickButtons()` 现在同时要求 Feature Enabled **和** persistent preference=true；页面临时租约不再能复活被用户关闭的屏幕按钮。`SetQuickHudVisible(true)` 改走 `EnsurePersistentQuickRuntime()`，显示快捷按钮本身即持久运行意图，不再使用 page-like transient lease。Presentation 仍只响应 `v3.gear.quick.visibility`，不直接改 Feature preference。
- **回归/门禁**：新增 `rs_quick_surface_reload_harness.py`，覆盖 legacy Gear split 一次修复、linked 后显式 false 不被覆盖、页面 transient 不复活按钮、Bag idle observer 不扫描/不移动物品。Foundation Gate v128 / UIV3 Acceptance v83；38/38 Python Harness PASS；222/222 Lua parse PASS；Foundation Audit PASS。
- **BuildTag**：`v3-m1.16.0.18.152-quick-surface-reload-reconcile`。

## M1.16.0.18.151 — Death Review Known Legacy Stamp Migration（2026-09-07）

- **`.18.150` RU 复验结论**：`v3.death_review` 仍稳定为旧盖章 `770CB0B8` 对当前 canonical `368335F2`；UI 页面事务继续无新增故障。上传的 `.150` 完整工程确认 `historical_probe` 已在 Store 生成，但 Foundation 的 startup/detail 文本分别被 180/130 字符上限截断，因此用户复制行看不到 probe，不能据此认为 hook 未执行。
- **停止继续无限枚举历史表形**：`.146-.150` 五轮都保持同一个真实旧 v4 stamp，说明它是可识别的历史迁移身份，而不是当前随机损坏 Hash。Persistence Historical Canonical Recovery 升 v3，新增 Store-owned `recoverKnownLegacyCanonical` 最后一级迁移桥；只在当前 v4 校验失败、exact historical reconstruction 也失败、且 Envelope Seal/metadata/schema/decode/budget 已全部通过后才可调用。
- **Death Review 只认一个实机旧盖章**：`KNOWN_LEGACY_V4_INDEX_FINGERPRINTS` 当前只有 `770CB0B8`。Store 对 pre-codec raw payload 再做严格白名单 shape 校验（top/settings/history/summary/widgetWindow 字段、类型、30 条上限、serial/storageId 唯一性）；通过后保留所有仍存在的 history/settings/window，归一成当前 Domain 并立即写成 codec v1。任意其它 stamp（回归用 `770CB0B9`）继续 `integrity_failed + write fence`。
- **Integrity 不是全局放宽**：generic v4 mismatch 默认策略不变；没有显式 Store hook 的 Store 完全不受影响。已知 stamp 迁移仍依赖独立 Envelope Seal，且当前 canonical/budget 在 Apply 前再次验证；恢复后必须 `integrity_v4_upgrade` 重盖，第二次 Reload 必须 `verified_canonical`。
- **诊断闭环**：`v3.death_review` 加入“存档验收 A2”固定覆盖；Snapshot 暴露 runtime-only `historicalRecoveryProbe`，A2 在存在时输出 `DRProbe=`，避免主 Foundation 长横幅截断关键证据。
- **回归**：37/37 Python Harness PASS；Death Review Harness 同时覆盖 exact historical recovery、`770CB0B8` known-stamp recovery→codec restamp→第二次 strict verify、未知 `770CB0B9` 必须 Fence；Foundation Audit PASS；222/222 Lua `loadfile` parse PASS。Foundation Gate v127 / UIV3 Acceptance v82。
- **BuildTag**：`v3-m1.16.0.18.151-death-review-known-stamp-migration`。

## M1.16.0.18.150 — Death Review Historical Sequence Recovery + Shape Probe（2026-09-07）

- **`.18.149` RU 复验已完成故障隔离**：页面构建链已恢复为 `页面失败0/隔离0/事务回滚0/事务失败0`，证明此前 `v3_build_transaction_contract` 红灯是 Death Review Store Fence 的下游级联；本轮不再修改页面/Binding/事务代码。唯一剩余阻断为 `v3.death_review:770CB0B8>368335F2`。`368335F2` 变化同时证明 `.18.149` stable codec 已成为当前 canonical。
- **历史 Hash/算法对账**：本轮只以你上传的完整工程 `Addon.zip`（`.148`）叠加上一轮 `.149` 修改包重建当前实机代码，不再引用 GitHub 作为当前版本依据。当前真实代码确认 `770CB0B8` 仍来自旧 v4 canonical stamp；恢复继续要求候选完整 Hash 精确命中，禁止关闭 Integrity 或近似接受。
- **补齐已观测的 Native 表形漂移类别**：旧 Index 的 `history.entries` 是最多 30 行的 sequence；正常 Domain 继续严格使用 `ipairs()`。Historical recovery 新增只在 mismatch 路径启用的 `pairs()` collector，用于覆盖 RU 已有实机证据中的 sequence/map 表示漂移。collector 按 `serial/storageId` 重新归一排序；恢复出的行**不直接可信**，仍必须连同旧业务设置和 opaque window 组成完整候选，并使完整 fingerprint 精确等于旧 stamp 才允许 Apply。
- **双历史基底、统一 exact search**：先尝试严格 `ipairs` 历史基底；仅当 `pairs` 找到更多有效 summary 行时才增加第二个 recovered-history 基底。每个基底继续复用 `.149` 的 default-TRUE false + legacy window 缺失字段 bounded mutation，单基底最多 12 位/4096 候选。当前 codec envelope 永不进入该历史分支。
- **失败不再盲查**：Store 增加 runtime-only `lastHistoricalRecoveryProbe`，仅记录 `histIpairs/histPairs/rawEntryKeys/winKeys/defaultTrueMissing/winRecoverable/bases` 等形状计数；Core 在最终 mismatch 文本追加 `historical_probe=...`。不输出玩家名、伤害、技能、死亡时间或记录内容。若真实 `770CB0B8` 仍未命中，下一份横幅可直接判断剩余结构类别。
- **回归**：Death Review real-Lua Harness 构造“旧 canonical 有 1 条历史摘要 → Native 将 `entries[1]` 变为 `["1"]` map + 同时省略两个业务 false 与窗口 false → strict `ipairs=0` / historical `pairs=1` → 只有第二基底完整旧 Hash 精确命中 → recovered Domain 保留 history/false → codec 重盖 → 第二次 `verified_canonical`”。Foundation Gate v126 / UIV3 Acceptance v81。
- **BuildTag**：`v3-m1.16.0.18.150-death-review-history-sequence-recovery`。

## M1.16.0.18.149 — Death Review Index Stable Codec + Historical Business-State Recovery（2026-09-07）

- **`.18.148` RU 复验结果**：真实旧 Store 仍稳定复现 `v3.death_review:integrity_failed:fingerprint_mismatch:770CB0B8>20692C15`，并继续级联 `runtime_startup_degradation`、Death Review Persistent Binding prepare 失败与 Page Build rollback/quarantine。由此确认 `.18.148` 的窗口字段 subset 仍不是完整历史形态。
- **遗漏的业务歧义**：`settings.autoShow` / `settings.showDebuffs` 都是“缺失 => true”的默认真布尔值。RU SaveData 若省略旧盖章中的显式 `false`，磁盘 `nil` 经 `NormalizeSettings()` 会被解释为 `true`；`.18.148` 只枚举 `widgetWindow` 缺失字段，因此无论窗口组合是否正确，都无法复现包含这些 `false` 的旧 stamped fingerprint。
- **统一 bounded exact recovery**：Death Review 历史恢复把“缺失 default-TRUE setting 可能为 false”与“缺失 opaque FloatingSurface 字段可由当前 pure normalizer 确定”合并为同一 mutation 集，仍限制最多 12 位（≤4096 候选），每个候选必须完整 Hash **精确等于**既有 stamp 才可恢复。无法命中继续原样 fail-closed + Fence；不清 Store、不关闭 Integrity。
- **恢复值不再丢业务语义**：Persistence `HistoricalCanonicalRecoveryContractVersion=2`。历史 hook 可返回第二个 recovered Domain；Core 在旧 Hash 已认证后，对该 recovered Domain 再跑当前 canonical + budget 后才 Apply。这样 `false` 不会因为 decoded disk 中字段缺失而被当前默认 `true` 静默覆盖。旧 hook 仍兼容；第四参数新增 raw envelope，供 Store 在 decoder 归一化前读取真实历史磁盘形态。
- **稳定持久化而非无限重盖**：Death Review Index 新增 codec v1。默认真布尔值不再直接持久化 `false`，而用 `autoShowDisabled=1 / showDebuffsDisabled=1` 数值 sentinel 表示禁用；missing sentinel 明确等于启用。窗口仍走唯一 `FloatingSurface:NormalizeState()`。旧 V3 key/schema 不变，首次精确恢复后重写为 codec；之后即使 Native 继续省略 Lua `false`，Readback Barrier 与 Fresh Reload 都能稳定验证，不进入反复 restamp。
- **回归**：Death Review real-Lua Harness 新增“旧 partial window + 两个 false 业务设置同时被 RU 省略 → 精确恢复旧 stamp → recovered Domain 保留 false → codec 重盖 → 第二次 verified_canonical”链路，并模拟整个业务 payload 省略 false。Persistence v7/v8/v9、Acceptance Snapshot、Runtime Entry、Startup Isolation、Foundation Audit 均通过；完整全量 Harness 结果以本轮封包记录为准。Foundation Gate v125 / UIV3 Acceptance v80。
- **RU 下一步**：必须继续保留当前真实 `770CB0B8` Store，直接覆盖 `.18.149` Fresh Reload；首轮目标 `integrityFail=0 / Fence=0 / pageQ=0 / txFail=0`，允许一次 `historical_canonical_recovery` + codec restamp；第二次 Reload 必须 `verified_canonical`。禁止 Reset/Clear 后声称通过。
- **BuildTag**：`v3-m1.16.0.18.149-death-review-index-stable-codec-recovery`。

## M1.16.0.18.148 — Death Review Historical Window Subset Recovery（2026-09-07）

- **`.18.147` RU 复验结果**：NumericRange V3 owner 已恢复（Store 总数从 35 增至 40，未再出现 `NUMERIC_RANGE_STORE_REGISTER_FAILED / STORE_REGISTER_INVALID`），但 `v3.death_review` 仍精确复现 `770CB0B8>20692C15`。`historicalCanonical=1` 只证明恢复契约已启用，不代表单一 opaque 候选命中了旧盖章；该 Store 的 Fence 进一步让 `combat.death_review` Persistent Binding prepare 失败，触发 Page Build rollback/quarantine，因此本轮 `v3_build_transaction_contract` 红灯是同一根因的级联结果。
- **真实历史形态补全**：`.18.143-.18.145` Store 对 `widgetWindow` 是 opaque passthrough，而 Feature/FloatingSurface 在不同用户交互阶段可能留下 partial state。RU 跨重载又可能省略 `false` 成员，因此旧盖章形状可能处于“磁盘 partial”与“当前完整 NormalizeState”之间。`PersistenceCanonicalWindowContractVersion=3` 只对 FloatingSurface 已知键做 bounded subset reconstruction：从磁盘 opaque 状态出发，仅补回当前纯 normalizer 可确定的缺失标量字段，最多 12 个（≤4096 候选），并且**每个候选仍必须精确复现现有 stamped fingerprint 才能恢复**。无法命中时继续原样 fail-closed + write fence；不清 Store、不关闭 Integrity、不接受近似 Hash。
- **恢复后的 Authority**：命中历史盖章后仍只应用当前 `NormalizeWidgetWindow` canonical，并走既有 `integrity_v4_upgrade` dirty/restamp；下一次 Reload 必须进入 `verified_canonical`，历史搜索不会成为长期热路径。
- **回归**：Death Review Harness 新增“旧内存 partial window 含 false 字段 → RU 落盘省略 false → raw opaque 与 full current canonical 均不匹配 → subset 精确命中旧 stamp → 重盖 → 第二次 verified”用例；Persistence v7/v8/v9、Acceptance Snapshot、Runtime Entry/Startup Isolation、Range/UnitLine/ScreenProjection 专项均通过。Foundation Gate v124 / UIV3 Acceptance v79。
- **RU 状态**：仍需保留当前真实 `770CB0B8` Store 验证 `.18.148`；禁止 Reset/Clear 后再声称通过。
- **BuildTag**：`v3-m1.16.0.18.148-death-review-historical-window-subset-recovery`。

## M1.16.0.18.147 — Historical Canonical Recovery + NumericRange Namespace + Screen Coordinate Authority（2026-09-07）

- **Death Review `.18.146` 复验失败纠正**：RU Fresh Reload 仍精确复现 `v3.death_review:integrity_failed:fingerprint_mismatch:770CB0B8>20692C15`，证明 `.18.146` 关于“.18.145 旧盖章来自完整 FloatingSurface logical shape”的假设不成立。真实 `.18.145` `NormalizeIndex()` 对 `widgetWindow` 是 opaque passthrough，可能把 `{}`/partial/default-omitted 子树直接参与 Integrity v4 hash。
- **窄口 Historical Canonical Recovery**：Persistence 新增 `HistoricalCanonicalRecoveryContractVersion=1` 与 Store opt-in `rebuildCanonicalForIntegrity`。只有 Envelope Seal、decode、budget、当前 canonical 均已通过，且 Store 显式允许 upgrade 时，才允许重建一个历史 canonical 候选；候选使用当前确定性 fingerprint **精确等于旧 stamped fingerprint** 才接受。Death Review 只重建 `.18.145` 的 opaque-window canonical，成功后实际应用当前 FloatingSurface canonical 并立即走既有 `integrity_v4_upgrade` 重盖；错误 hash/真实内容损坏继续 fail-closed + fence。没有清 Store、关闭 integrity 或无条件吞 mismatch。
- **NumericRange Store 注册修复**：`v3.rsui.numeric_ranges` 的 owner 从非法 `rsui.numeric_ranges` 修正为 `v3.rsui.numeric_ranges`，满足 V3 Store namespace 契约；Foundation/Acceptance 增加精确 owner 门禁，新增真实 Lua registration/roundtrip Harness，防止再次出现 `NUMERIC_RANGE_STORE_REGISTER_FAILED / STORE_REGISTER_INVALID`。
- **2560×1440 视觉偏移根因**：`ScreenProjectionV3` 输出已经是 UIParent 屏幕坐标，而 Visual Guides Presentation 又把 x/y 乘 Suite `addonScale`，形成相对左上原点的二次比例缩放；分辨率/Scale 越高偏移越明显。`ScreenProjectionV3 v13` 新增 `UiParentScreenCoordinateContractVersion=1`，VisualGuides v9 新增 `ScreenCoordinateAuthorityContractVersion=1`，Unit Lines 与 Range Assist 直接 1:1 消费投影 x/y，Suite `addonScale` 只影响 UI 尺寸，禁止再参与世界→屏幕位置换算。Range 的 EasyPull Camera + player anchor rigid calibration 保留。
- **回归**：新增 NumericRange 注册 Harness，并扩展 Death Review/Unit Line/ScreenProjection 专项；2560×1440 模拟中故意设置 `addonScale=1.25`，Unit Line/Range 坐标仍严格落在原投影端点。完整本地回归 `37 / 37 Python Harness PASS`、Foundation Audit PASS、TOC Lua `222 / 222` texluac Parse PASS；`rs_business_bridge.lua` 保持 Lua main-chunk `200/200` local。Foundation Gate v123 / UIV3 Acceptance v78。
- **RU 状态**：本地修复完成，**仍待真实 `.18.147` Fresh Reload**。首轮必须保留现有 `.18.145/.18.146` Death Review Store 证明一次性恢复/重盖；不得通过 Reset/Clear 让 Gate 变绿。
- **BuildTag**：`v3-m1.16.0.18.147-integrity-range-store-screen-coordinate`。

## M1.16.0.18.146 — Death Review Persistence Canonical Window + Terminal Load Memoization（2026-09-07）

- **RU Fresh Reload 阻断根因**：实机横幅 `v3.death_review:integrity_failed:fingerprint_mismatch:770CB0B8>20692C15` 来自 DeathReview Index 的 `widgetWindow` canonical 漏洞。Feature 在写入前已经使用 `FloatingSurface:NormalizeState()` 生成固定逻辑状态，但 Store 的 `NormalizeIndex()` 却把该子表原样透传参与 Integrity v4 hash；RU SaveData/LoadData 只要省略 `false/default/空字段`，窗口业务含义不变，canonical 指纹仍会变化并触发 write fence。
- **单一窗口状态 Authority**：DeathReview Store 新增 `PersistenceCanonicalWindowContractVersion=1` 与唯一 `WidgetWindowSizePolicy`，`NormalizeIndex()` 保存/加载两侧统一调用共享 `FloatingSurface:NormalizeState()`；Feature 的 Get/SetWidgetWindowState 复用同一个 Store-owned policy，禁止 Presentation 与 Persistence 各维护一份 470×330/opacity 默认值。没有清 Store、没有关闭 integrity、没有无条件接受 mismatch。
- **旧 `.18.145` 档兼容逻辑**：旧版本盖章时，Feature 写入 Store 的窗口状态本身已经是 FloatingSurface 固定形状；本轮只是让加载侧在 hash 前重建同一逻辑形状。因此 RU 若仅省略 false/default 表示，旧 v4 stamped fingerprint 可直接重新验证为 `verified_canonical`，无需迁移 key/schema 或破坏性 reset。真实业务字段变化仍继续 `integrity_failed`。
- **重复故障去噪**：Persistence 增加 `TerminalLoadMemoizationContractVersion=1`。同一 Lua generation 内，已经 terminal + write-fenced 的结构性失败再次 `LoadStore()` 时直接返回首个错误，不重复触发 Native LoadData、incident 和 `integrityLoadFailures`。新 generation 会自然重新验证；Clear/verified replacement 等显式恢复路径仍拥有自己的状态重置。解决本次一次实际故障被 Feature Defaults 多次尝试放大成 `integrityFail=10` 的诊断噪声。
- **回归**：新增 `rs_death_review_persistence_harness.py`，真实 Lua 模拟 SaveData 省略 `minimized=false/locked=false/userMoved=false` 后，Flush barrier 与再次 LoadStore 均通过 canonical verification，设置/几何保留；另故障注入证明 terminal Store 只产生一次物理读取/一次 integrity incident。完整本地回归 `36 / 36 Python Harness PASS`、Foundation Audit PASS、TOC Lua `222 / 222` texluac Parse PASS；Foundation Gate v122 / UIV3 Acceptance v77。
- **BuildTag**：`v3-m1.16.0.18.146-death-review-persistence-canonical`。

## M1.16.0.18.145 — Numeric Explicit Apply + Adaptive Visual Point Size（2026-09-07）

- **Range Assist 点大小“输入成功但实际无效”根因**：RSUI `.18.142` 的 Adaptive Range 已能在 Domain 接受后扩展 Slider，但 `combat_range_assist` / `combat_unit_lines` Feature Setter 仍把 `pointSize` 强制 clamp 到 10，Presenter 又把所有 >10 的字号压回 40px。现在统一由 `Constants.VisualGuide` 定义 2..24 安全 envelope；默认 Slider 仍为 2..10，精确输入 15 被 Domain 接受后 Authority 保持 15，Presenter 延续既有 2→16px、10→40px 映射并单调扩展到 15→55px，不再视觉扁平化。
- **显式“应用”提交契约**：RU EditBox 没有已验证的 Enter 提交 API，因此 Compact Numeric Setting 默认在精确编辑框右侧显示“应用”。`NumericExplicitApplyContractVersion=1` / `NumericInputDraftReadContractVersion=1` 让 Apply 直接读取当前 draft 并走原 Binding→Domain→Persistence Authority；Enter/LostFocus 保留兼容路径，但业务提交不再依赖 Enter 是否由客户端派发。
- **RU LostFocus→OnClick 顺序防重写**：若点击“应用”时 Native 先触发 LostFocus 并已提交相同 Authority 值，后续 Button OnClick 只结束输入态/同步控件，不再重复执行 Domain/Persistence 写入。焦点释放继续沿 `.18.144` 的 tracked Focus fence，游戏 WASD/技能/聊天输入不会被 Suite EditBox 长期占用。
- **自适应 Slider 端点**：例如范围辅助点大小初始 2..10，输入 15 后点击“应用”→ Domain=15 → Slider 展示范围自动变为 2..15，并通过既有 `v3.rsui.numeric_ranges` Account/Permanent Store 保存端点。硬安全上限 24；UI 不得绕过 Domain Clamp。
- **布局**：Design System v7 的 `CompactNumericSetting` 默认开启 Apply；Numeric Inline v6 在同一行按宽度响应式分配 Label / Slider / Exact Input / Apply，窄卡片优先收缩 Label/Input floor 而不是产生控件重叠。Range Assist 双列 Grid 的最小单元宽度从 190 调整到 230；不新增第二行或常驻布局 Tick。
- **共享限制单源**：点大小 envelope 收敛到 `core/rs_constants.lua -> Constants.VisualGuide`，Feature/Projection/Presenter 共享同一上限；`rs_business_bridge.lua` 不增加 main-chunk local，保持现有 Lua 200/200 local 上限可编译。
- **RSUI / Gate**：RSUI v47 / API 13.1；Foundation Gate v121，UIV3 Acceptance v76；UnitLines VisualGuide v5、RangeAssist VisualGuide v7。
- **回归**：35 / 35 Python Harness PASS；`UI_INTERACTION_RANGE_HARNESS 61/61`（含 Apply→15→2..15 + LostFocus-before-OnClick 防重复写）、`UNIT_LINE_END_TO_END_HARNESS 32/32`（真实 RangeAssist Command 接受/投影 15）、`INPUT_FOCUS_DRAG_HARNESS 99/99`、`INTERACTIVE_DRAFT_HARNESS 115/115`、`RSUI_WORKSPACE_SMOKE_HARNESS 27/27`；Foundation Audit PASS（`toc=222 / activeLua=222 / allLua=222`）。
- **BuildTag**：`v3-m1.16.0.18.145-numeric-apply-adaptive-point-size`。

## M1.16.0.18.144 — EditBox Commit/Focus Fence + Table Resize Preview Authority（2026-09-07）

- **EditBox 数值回弹根因**：`.18.142` 已阻止 ambient Binding Refresh 覆盖正在编辑的 draft，但 RU 单行 EditBox 在 Enter 路径仍可能先执行 Native `clear-on-enter`，导致 `Submit()` 读取到空文本并按旧 Authority 回滚。`CreateEditBox` 现在显式使用已验证的 `ClearTextOnEnter(false)`；TextInput/NumericInput 的 Enter/EditEnter 改为统一 `CommitAndEndEditing()` 事务。
- **游戏键盘被编辑框长期占用根因**：此前 Enter 只 Commit，不结束 Native 输入生命周期；`EndEditing()` 也只 `EnableKeyboard(false)`，没有释放仍属于 Suite EditBox 的 Focus。UI Framework 新增 `ExplicitInputCommitFocusContractVersion=1` / `DeactivateInputWidget()`：只在 physical focus id 能证明属于当前 Suite 子树时调用现有 `ReleaseFocusWithin()`，随后无条件 Disarm Keyboard；绝不清理聊天框或其他游戏输入焦点。ClearFocus 同步触发 LostFocus 时由 `_endingEdit` fence 阻止二次提交。
- **输入切换生命周期**：Interactive Draft 升 v3 / `InputDraftCommitContractVersion=1`。新增弱引用、纯事件驱动的 DraftCoordinator；点击另一个 Suite 输入框时，前一个输入先 Commit/rollback 并释放 Focus/Keyboard，再让新输入取得所有权。无 Tick、无常驻 OnUpdate、无猜测 OnTextChanged/KeyDown。
- **表格列宽拖拽闪烁根因**：拖拽 Preview 每 16ms 发布鼠标几何，但页面普通 `Layout()` 同时用旧 committed widths 重跑 Fill solver，形成“鼠标位置 ↔ 原位置”争夺。`DataViewResizePreviewAuthorityContractVersion=1` 后，`previewResolvedWidths` 在 gesture 期间是 Header、可见 Row、新绑定 Row 和分隔条的**唯一几何 Authority**；松手后才一次 Commit 成对列宽并恢复普通 Layout。
- **RSUI / Gate**：RSUI 升 v46 / API 13.0；Foundation Gate v120，UIV3 Acceptance v75。历史 Harness 对 Gate/BuildTag 的检查改为最低契约版本/版本族，避免后续正常版本递增造成假失败。
- **回归**：35 / 35 Python Harness 全部 PASS；`INPUT_FOCUS_DRAG_HARNESS 99/99`、`INTERACTIVE_DRAFT_HARNESS 115/115`、`UI_INTERACTION_RANGE_HARNESS 44/44`；Foundation Audit PASS（`toc=222 / activeLua=222 / allLua=222`）。RU Fresh Reload 仍需验证 Enter 提交后数值保持、WASD/技能/聊天立即恢复，以及高频列表刷新时列宽拖拽无双位置闪烁。
- **BuildTag**：`v3-m1.16.0.18.144-input-focus-table-drag-stability`。

## M1.16.0.18.143 — Button Hover 假离开 Fence + 高频设置页刷新隔离（2026-09-07）

- **实机回归根因**：`.18.142` 只解决 Native NORMAL/HIGHLIGHT 内部状态抖动，但 UnitLines / RangeAssist 高频投影刷新会在 RU 上制造假的 `OnLeave -> OnEnter`；v1 在假 `OnLeave` 到达时仍立即清除逻辑 hover，因此这两页继续闪烁。
- **Stable Button Hover Contract v2**：共享 Button-like Component 对 `OnLeave` 使用 120ms one-shot grace；同控件 `OnEnter` 会取消待提交 leave。grace 到期后若 Native Widget 提供已验证 `IsMouseOver()`，再次确认物理指针仍在控件上则拒绝假离开。Component Release/Disable 通过 owner lifetime/显式取消清理任务；无 Tick、无轮询。
- **高频视觉与设置 Presentation 解耦**：`combat_unit_lines` / `combat_range_assist` 仍保持各自世界视觉高频任务（Range 50ms，UnitLines 继续尊重 1-1000ms 用户设置），但 Business Settings Page 对 `visual_tick/visual_tick_error` 只做 160ms bounded one-shot 合并刷新。直接设置命令和非视觉 Authority 更新仍即时刷新。避免高频世界投影强迫 RSUI 控件同频重绘。
- **门禁/回归**：Foundation Gate / UI Acceptance 提升为 Hover v2；`UI_INTERACTION_RANGE_HARNESS 44/44` 覆盖 leave grace、IsMouseOver recheck、高频设置页合并与 deactivation task cleanup。
- **BuildTag**：`v3-m1.16.0.18.143-hover-leave-fence`。

## M1.16.0.18.142 — RSUI 稳定 Hover + 可编辑 Numeric Draft + 自适应滑块范围（2026-09-07）

- **按钮 Hover 闪烁根因收敛**：RU Native `BUTTON` 在父级 Refresh/Layout 期间可能在 NORMAL/HIGHLIGHT 背景间抖动。RSUI 新增 `StableButtonHoverContractVersion=1`，组件通过事件 mux 持有逻辑 hover；hover 期间 Theme 同时把 Native normal/highlight 两张背景绘制成同一 hover 视觉，Native 内部状态抖动因此视觉幂等。Button/Toggle/Dropdown（trigger、滚动、option）/ColorField trigger 共用同一契约，不新增 Tick。
- **编辑框“删掉立即变回原值”修复**：Interactive Draft Contract 升 v2。TextInput/NumericInput 不再只依赖 RU 原生 Focus 回读，而是在明确点击成功后持有 component-local `editing` 生命周期；页面/Projection 的 `binding_refresh/field_sync` 在编辑期间不得把旧 Binding 回灌。Enter/LostFocus 才提交；提交拒绝/非法输入仍显式回滚到业务 Authority。
- **滑块范围由精确输入动态扩展**：NumericField Inline 升 v5，新增 `NumericAdaptiveRangeContractVersion=1`。`min/max` 作为默认**显示范围**；精确输入提交后先由 Feature/Domain Setter 决定是否接受，随后读取真实 Authority 值。若真实值超出当前显示端点，Slider 原地 `SetRange()` 向外扩展（例如 1..10 输入 20 → 1..20；输入 -4 → -4..20），不重建控件、不打断拖动。Domain 明确 Clamp/拒绝的硬边界不会被 UI 绕过；可用 `hardMin/hardMax` 或 `fixedRange=true` 显式声明硬范围。
- **动态范围持久化**：新增 Account/Permanent V3 Store `v3.rsui.numeric_ranges`（`NumericRangePersistenceContractVersion=1`），只保存 stable field id 的展示端点，不复制业务数值。扩展 400ms debounce 保存；Fresh Reload 恢复时只允许向外合并，旧存档永远不能缩小新版本代码定义的 base range；读取失败进入 session-only fallback，禁止覆盖 fenced/失败物理存档。
- **RSUI 版本**：v45 / API 12.9。Foundation Gate/UI Acceptance 同步要求 Draft v2 + Adaptive Range + Range Store + Stable Hover，新增 `UI_INTERACTION_RANGE_HARNESS 34/34`；Interactive Draft Harness 115/115。
- **BuildTag**：`v3-m1.16.0.18.142-ui-hover-adaptive-range`。

## M1.16.0.18.141 — 范围圆 1280×768 圆心自适应校准（2026-09-07）

- **实机反馈复现**：`.18.140` 已恢复完整圆形，但 1280×768 等分辨率下圆心与玩家屏幕锚点错位。历史 `.18.136/.18.137` 已有实机正证据：使用 `GetUnitScreenPosition("player")` 作为屏幕真值后，圆心能够钉在玩家身上；后续因错误归因把该层删除。
- **校准职责下沉 ScreenProjectionV3 v12**：`ProjectWorldBatch` 新增调用级 `anchorUnit + anchorWorld`。仅当 EasyPull 整批落在 Camera fallback（native=0/camera>0）时，用同一 Camera Frame 投影世界圆心，再与原生玩家屏幕锚点求一次 `(dx,dy)`，对整批 camera 点做同一刚性平移。禁止逐点混合、禁止硬编码分辨率常数；mixed native/camera 批次明确跳过校准并记录遥测。
- **1280×768 / UI Scale 自适应**：校准每 50ms 随范围任务更新，分辨率、UI Scale、窗口/相机变化自动重算；异常 delta 有视口级边界保护，坏读不会把圆甩飞。圆的 EasyPull 透视/FOV/半径算法不改。
- **遥测**：范围状态继续显示 `校准=dx,dy`，`projFacts` 新增 `锚校applied/unavailable/rejected/mixed_source_skipped`，可直接判断中心真值是否生效。
- **PVP 50ms 保持**：范围辅助与 PVP 战斗高频策略不回退，生活/PVE 低频策略不变。
- **BuildTag**：`v3-m1.16.0.18.141-range-anchor-calibration`。

## M1.16.0.18.140 — EasyPull WorldToScreen 实机回退 + 范围契约修复（2026-09-07）

- **范围辅助 0 点根因修复**：`.18.139` 错误把 EasyPull 简化成 `ConvertWorldToScreen native-only`。真实 EasyPull 源码是 `ConvertWorldToScreen` 可用则优先，否则回退自带 `WorldToScreen` 相机投影；RU 实机状态已证明原生全局投影不可用，因此 native-only 必然 0 点。范围辅助改为 `ProjectWorldBatch(...,{easyPullCompat=true})`，保持 `player,true` 本地世界空间与 50ms Demand-scoped 高频刷新。
- **逐字对齐 EasyPull Camera 数学**：新增独立 `_BuildEasyPullCameraFrame/_ProjectWithEasyPullCameraFrame`，不复用普通 Camera Frame 的 `camDir` 归一化与 FOV clamp；使用 `UIParent:GetScreenWidth/GetScreenHeight`、原始 camera direction、right-only normalization，与公开 `globals/WorldToScreen.lua` 算法一致。
- **圆周参数对齐**：圆周 Z Offset 调整为 EasyPull 的 `+0.25`；原生返回完整点但 depth<=0 时直接裁剪，不错误切换第二投影器；仅原生点缺失时才进入 WorldToScreen fallback。
- **启动阻断修复**：`RangeAssist.WorldSpaceContractVersion` 从 1 修正为 2，`ProjectionFactsContractVersion` 提升到 4，解除 `.18.139` 引入的 `range_assist_visual_contract` / `visual_guides` 两个自相矛盾验收阻断。
- **失败遥测增强**：范围 0 点时状态行附 `批次=模式/原N/相M/原拒K/相拒J/相机错...`，下一轮可直接判断是世界位置、Native、Camera basis 还是相机后方裁剪。
- **PVP 50ms 保持**：`.18.139` 的 PVP Projection/Pending Replay 50ms 高频策略不回退，PVE/生活仍保持低频。
- **BuildTag**：`v3-m1.16.0.18.140-easypull-worldtoscreen`。

## M1.16.0.18.139 — EasyPull 范围投影对齐 + PVP 50ms（2026-09-07）

- **范围辅助回退纠正**：撤销 `.18.138` 将圆心切到 `isLocal=false` 的错误方向。项目保存的 EasyPull 源码审计明确记录 `easypull.lua:657` 使用 `GetUnitWorldPositionByTarget("player", true)`；范围圆继续使用本地世界空间。
- **EasyPull 投影路径收敛**：范围圆整批使用原生 `ConvertWorldToScreen`，严格 `depth > 0`，不再逐点混入 Camera 手算坐标；移除 `.18.136` 的 `GetUnitScreenPosition` 圆心二次校准，避免把两个屏幕坐标来源叠加。`ProjectWorldBatch` 增加 `nativeOnly` 与调用级 batch facts，其他消费者的历史 fallback 行为不变。
- **范围辅助刷新 200ms → 50ms**：迁移到 demand-scoped HighFrequency P1；只在功能有消费者时运行。投影异常由功能本地隔离，立即清除旧圆并保持 50ms 重试，不再因三连异常让旧点冻结。
- **PVP 战斗读模型刷新 50ms**：CombatEventBus/CombatAnalytics 的事实采集仍是即时事件驱动；DPS 在 PVP 模式下 Projection 发布 debounce 与 pending relation replay 改为 50ms 高频一次性任务。PVE 保持原 400ms/160ms，生活模块完全不提频。
- **BuildTag**：`v3-m1.16.0.18.139-easypull-pvp50`。

## M1.16.0.18.138 — 范围圆 global world 回归修复 + 刷新自愈 + 真实 batch 遥测（2026-09-07）

- **实机反馈复核**：`.18.137` 状态行显示范围圆呈半圆、镜头变化后点位像冻结；但旧遥测存在两个误导：① `tick` 是 `Authority.revision` 在 `read()` 内递增前的旧值，不等价于 Scheduler 执行次数；② Range 在整圈投影后又单独投影 1 个圆心做校准，后者覆盖 `ScreenProjectionV3.lastWorldBatch`，所以 `源原生0/相机1/拒1` 实际描述的是**校准圆心**，不是 35 个圆周点。
- **世界坐标空间回归修复**：撤回 `.18.135` 的 `isLocal=true`。工程自身 `.18.126`、`CURRENT_ARCHITECTURE` 与实际收集到的 ArcheRage `magiccircle` 用法均指向 `GetUnitWorldPositionByTarget("player", false)`；Range 圆周点与 `UIParent` Camera Frame 重新统一到 **global world space**。`RangeAssist.WorldSpaceContractVersion=2`，Foundation Audit 明确禁止再次切回 local-space。
- **ScreenProjectionV3 v11 / batch facts**：`ProjectWorldBatch` 新增第三返回值 `batchFacts`，每次调用把 `total/native/camera/nativeRejected/depth/sample` 作为**调用本地快照**返回；`lastWorldBatch` 仅保留兼容用途。Range 立即保留整圈的 `ringBatch`，后续圆心校准再投影也不会覆盖整圈证据。新增 `WorldBatchFactsContractVersion=1`、`RangeAssist.ProjectionFactsContractVersion=2`。
- **范围刷新自愈**：200ms Demand 任务对 Range 的 Native/Camera read 做 feature-local `pcall` 隔离。瞬时投影异常不再触发共享 Scheduler 的 3 连败熔断/指数退避；发生异常时立即发布空 projection 隐藏旧圆，避免旧点冻结在屏幕坐标上，并继续按 200ms 有界重试，成功后自动恢复。错误 10s 限频进入诊断。
- **Scheduler 可观测性**：新增只读 `GetTaskState()` / `TaskStateDiagnosticsContractVersion=1`，记录每任务 `runCount/failureTotal/consecutive failure/resume/lastSuccess/lastError`；范围状态行改为同时显示 `rev`、`任务=.../run.../失...`、`刷新=尝试.../失.../连续...`，以后可以机械区分“任务没跑 / Scheduler 熔断 / Range read 异常 / 投影几何异常”。
- **回归证据**：ScreenProjection Harness **26/26**（新增 batch facts）；Unit Line/Range e2e **29/29**（新增 global-world、整圈遥测不被圆心覆盖、3 次刷新 revision 增长、注入一次 Range 异常后旧圆隐藏且下一 tick 恢复）；Scheduler Fault Recovery Harness 新增 per-task telemetry 断言。
- **BuildTag**：`v3-m1.16.0.18.138-range-global-refresh-resilience`。

## M1.16.0.18.137 — 投影判定参考对齐 + 投影事实遥测（2026-09-07）

- **实机反馈**：圆心已被校准钉在玩家身上，但呈现为**半圆**且**不随镜头刷新/缩放响应异常**——投影层还有一层事实未知（原生 `ConvertWorldToScreen` 是否可用、深度约定、相机兜底帧尺寸源）。
- **投影判定对齐参考（ScreenProjectionV3 v11）**：
  1. 原生点接受条件改为 easypull.lua:680/旧版 ProjectCirclePoints 的**精确判定**——深度必须是数字且 >0（撤回 v10 的 nil 容忍：nil 深度的原生结果是实机半圆/冻结的候选元凶）；
  2. 相机兜底帧尺寸源改为 `UIParent:GetScreenWidth/GetScreenHeight`（rp_api ProjectWorldToScreen 唯一实机验证过的来源；GetUiMetrics 物理宽高作为回退）——uiScale≠1 时两个来源不同，用错会让圆环整体比例错误。
- **投影事实遥测**：`lastWorldBatch` 记录每批 原生N/相机M/拒K、接受深度带、首点原始坐标与来源；范围辅助 ok 行携带 `源原生/相机/拒 · 深度 · tick · 样本`——半圆来自哪个投影器、刷新 tick 是否在走，下一份状态行直接读出。
- **BuildTag**：`v3-m1.16.0.18.137-projection-facts`。

## M1.16.0.18.136 — 范围圆分辨率自适应（锚点校准）（2026-09-07）

- **实机反馈**：圆圈已渲染，但 1280×768 下圆心偏离玩家——`ConvertWorldToScreen` 的输出空间随分辨率/UI 缩放变化，硬编码换算不可行（`.18.96` 时代的启发式换算正是前期灾难的一部分）。
- **修复：每刷新周期实时锚点校准（read()）**。用全链路唯一已被实机证明落在玩家身上的事实——原生 `GetUnitScreenPosition("player")`（单位连线正确锚定正是靠它）——作为真值：把圆心（本地空间 pz+0.1）经与圆周点**完全相同的投影路径**单独投影一次，差值 `(dx,dy)` 即该客户端此分辨率下的空间偏移，平移全部圆周点。**不硬编码任何分辨率常数**；偏移量超逻辑视口则判定异常并跳过校准（防单次坏读把圆甩飞）。随 200ms 刷新持续重校准，分辨率/UI 缩放/窗口大小变化自动跟随。
- **诊断**：范围辅助 ok 行新增 `校准=dx,dy`——各分辨率下空间偏移量一目了然，也作为空间错配的长期遥测。
- **BuildTag**：`v3-m1.16.0.18.136-circle-anchor-calibration`。

## M1.16.0.18.135 — 画圈坐标空间对齐 + 点大小设置修复（2026-09-07）

- **范围辅助圆不出现（根因实锤）**：两个权威参考一致证明画圈圆心必须用 **`isLocal=true`** 读取——easypull.lua:657 `GetUnitWorldPositionByTarget("player", true)`；旧版可用套件 rp_runtime UpdateCircle 同样 `isLocal=true` 并注释 "easypull-verified space"（即 `ConvertWorldToScreen` 期望的坐标空间）。此前实现用 `isLocal=false`（全局空间），其注释引用的是 .18.96 **单位连线**端点的混合空间 bug——把另一条管线的结论错误套用到画圈上，投影器吃进错配坐标，圆永远画不出来。修复：圆心改 `isLocal=true`；`.18.134` 的逐点原生→相机回退保持（同为本地空间内的自洽双路）。
- **单位连线"设置没有用"（点大小滑条无效）**：设置滑条范围 2–10，`.132b` 的 15px 字号下限把 2–10 全部钳成 15——拖动毫无视觉变化。修复：设置值**单调映射**为字号（2→16px、4→22、6→28、8→34、10→40），连线点与范围圆点同规则；其余设置（密度/颜色/透明度/刷新/分对开关）经链路复核均有效。
- **BuildTag**：`v3-m1.16.0.18.135-circle-local-space`。

## M1.16.0.18.134 — 范围辅助逐点回退 + 探针移除 + 渲染层契约固化（2026-09-07）

- **连线实机确认可用**（用户验证）。本轮收尾三件事：修范围辅助、删测试探针、把这几轮的架构教训固化进框架契约。
- **范围辅助（ScreenProjectionV3 v9→v10）**：`ProjectWorldBatch` 从"第 1 点探测原生、整批二选一"改为**参考架构的逐点双路回退**（rp_api `A:ProjectWorldToScreen` 本就是每点"原生→相机"）：原生 `ConvertWorldToScreen` 逐点尝试（x/y 为数字且深度 nil-或-正 才接受——背后点的原生结果是镜像坐标，不得绘制），失败点立即用**每批一次懒构建**的相机基计算。单一投影器的任何抖动/约定差异不再是整圆消失的来源（"可见点不足 0/3"的架构根因）。
- **测试探针移除**：`StartRenderProbe`/`ProbeTick`/`ProbeActive` 与 `#/S/T` 标记全部删除（用户要求；使命已完成——管线已证明、坐标已校准）。`NativeVisibleReadback` 助手保留（被动诊断，供宿主回读）。
- **渲染层契约固化（防复发）**：
  1. `UI:EnsureFontSize` 新增（与 EnsureVisible/EnsureAnchor 同款 ok/changed/err 三元组），`SetFontSize` 处写明"false 兼具无操作与被拒"的返回契约——.18.133 事故的机制性防再发；
  2. Foundation Audit 新增两条守卫：框架必须有 EnsureFontSize、连线点样式写入必须保持 best-effort（检测到 `~=true then return` 模式即 FAIL）；
  3. 范围辅助 down 行携带投影失败原因 top3（`failuresByReason`）。
- **事后复盘（.18.129→.18.133 五轮连锁的三个结构性根因）**：
  ①**歧义返回值当致命失败**——RSUI setter 的 false 兼具"无操作/被拒"，commit-on-accept 链把无操作当失败，在 SetColor（.129d）和 SetFontSize（.133）两次引爆；修复=样式写入 best-effort + Ensure* 去歧义 API。
  ②**发明的坐标空间对抗原生空间**——逻辑视口换算/一致性 oracle/前置半球门禁都在"纠正"实机本来就正确的原生坐标，proj失败 2831 次全是自伤；修复=原值直用 + 参考对齐。
  ③**单发生命周期无自愈**——事件驱动的租约握手错过一次即永久死局且零告警；修复=1s watchdog + 失败遥测进诊断行。
  过程性教训：**仓库内旧版可用实现（参考的项目1）是最高优先级参考**，外部参考次之；每轮"全绿但不可见"暴露的遥测盲区（尝试计数≠显示事实）已由回读/原因遥测补齐。
- **BuildTag**：`v3-m1.16.0.18.134-range-perpoint-fallback`。

## M1.16.0.18.133 — 连线点 SetFontSize 无操作 bail 修复（根因实锤）（2026-09-07）

- **实机证据链闭合（S 可见但连线点不可见）**：探针 `#`/`S` 标记与连线点走同一宿主/label 管线，唯一差别是连线点经过 `PlaceUnitDot` 的样式写入链。逐环比对旧版可用实现（`参考的项目1/replicatedsuite` rp_runtime/rp_ui——用户指出的权威参考）后定位：
  1. `CreateLabel` 构造时 `PrimeNativeState` 把字号 **15 直接写入 RSUI 缓存**（row.fontSize=15，rs_ui_framework.lua:623）；
  2. `.132b` 把点字号下限提到 15px → `PlaceUnitDot` 首次调用 `SetFontSize(dot,15)`；
  3. `UI:SetFontSize` 发现缓存已是 15 → 返回 **false（无操作，非失败）**（rs_ui_framework.lua:1224）；
  4. `.18.129` 引入的 commit-on-accept 检查把 false 当失败 → **提前 return，`SetUnitDotVisible(true)` 永不执行**；state.size 不提交 → 每 100ms 重复同样的 bail → 24 个点永远隐藏在 (0,0)。
- **为什么之前没暴露**：`.129d`–`.132` 期间点字号钳制后是 8（≠构造时的 15），SetFontSize 真实生效返回 true；`.132b` 提下限到 15 恰好与构造字号相等，触发无操作路径。`点=24(唯一24)` 是**尝试放置**计数（在 bail 之前累计），`回读=6/6` 只覆盖探针——两处遥测都看不到这个 bail，这就是连续几轮"全绿但不可见"的原因。
- **修复**：`PlaceUnitDot` 的 anchor/fontSize/color 写入改为 best-effort（对齐旧版参考的 pcall-从不-bail 模型）；presenter 本地缓存语义保持（同一帧仍然零冗余写入）。RSUI setter 返回 false 兼具"无操作"与"被拒"两种含义，对样式写入而言两者都不该阻止显示。
- **BuildTag**：`v3-m1.16.0.18.133-unitline-noop-bail-fix`。

## M1.16.0.18.132b — 点字号下限 15px + 探针窗口 120s（2026-09-07）

- **实机反馈解读**：探针 `#` 可见（渲染管线确认通过），但 S 缺失——探针 10 秒窗口从**文件加载瞬间**起算，加载动画还没结束就过期了，用户不可能在那 10 秒内选中目标。这是探针设计缺陷，不是新故障。
- **更关键的嫌疑（可能是"看不见"的最后一环）**：真实点的字号链是 点大小设置默认 4 → `max(8,…)` → **8px 字号的 '.' 字形只有 1–2 个像素的墨点**——技术上画了，视觉上在游戏背景里不可见。参考 rp_ui 的默认就是 **15px**（clamp 8..40）。
- **修复**：`PlaceUnitDot`/`PlaceDot` 字号下限 8→**15px**（rp_ui 参考默认）；探针窗口 10s→**120s**（加载完进游戏、选中目标后 S 必然有机会出现），到期自动隐藏。
- **BuildTag**：`v3-m1.16.0.18.132b-visible-dot-floor`。

## M1.16.0.18.132 — 渲染自检探针 + 宿主绘制优先级（2026-09-07）

- **现状**：诊断全绿（消费者持有/投影成功/写入被接受）但屏幕无点。写入成功≠屏幕可见，远程无法继续二分——本轮把"再猜一次"换成"让客户端自己回答"。
- **渲染自检探针（CombatVisualGuidesV3 v7→v8）**：每次加载后 10 秒，经与真实点阵完全相同的宿主/label 管线在屏幕中部横排画 6 个 32px 绿色 `#`：P1-P3 取**物理分辨率** 25/50/75%、L1-L3 取**逻辑分辨率**同比例。两种候选锚定空间一次重载即可肉眼区分——看到部分绿点=渲染管线通（问题在坐标空间，且能看到是哪种空间被渲染）；全部看不到=宿主窗口本身不渲染。聊天栏同步提示。watchdog 每秒重申可见并回读引擎 `IsVisible()`（新增 `UI:NativeVisibleReadback`），结果写入状态行 `自检=N点/回读=…`。
- **宿主策略对齐已验证弹窗模式**：`CreateOverlayWindow` 补 `SetDrawPriority`（CreatePanel/popup 同款）——缺少绘制优先级的窗口可能被压在世界/主窗口之后，是"写入成功但不可见"的具体嫌疑。
- **范围辅助补渲染遥测**：`lastRangeSampling`（首点坐标/缩放/宿主回读）进入范围辅助 ok 行——此前该行只统计投影点数，完全看不到渲染层。
- **BuildTag**：`v3-m1.16.0.18.132-render-selfprobe`。

## M1.16.0.18.131b — 连线去除世界坐标前置门禁（参考对齐收尾）（2026-09-07）

- **实机证据（.18.131 状态行）**：范围辅助已修复（工作中·35 点——v9 原生投影 + 窗口宿主生效）；连线有消费者，但 `自己 ↔ 当前目标（单位在相机背后）` 零行——**玩家自己被 front-hemisphere 门禁判成相机背后**。玩家永远不该在相机背后，说明 `GetViewCameraPos` 基与 `GetUnitWorldPositionByTarget(false)` 世界空间在实机上不一致，世界坐标前置分类不可用。
- **参考事实**：rp_api.lua UnitScreenPoint 画线只用原生 `GetUnitScreenPosition` + `depth>0` 剔除，**不存在任何世界坐标 vs 相机基的前置分类**。v9 已有的原生 depth 剔除就是参考的 behind-cull。
- **修复**：连线 read() 去掉 `requireFrontHemisphere`（服务能力保留，front-hemisphere 专项 harness 继续直接覆盖该路径）；世界坐标别名守卫（.18.129 的 target 切换别名防护）不受影响——它比较的是 token 间世界距离，与相机基无关。`世界→屏幕` 兜底链（原生缺失时 ProjectWorld(wz+1)）与 rp_api UnitScreenPoint 的 fallback 完全同构。
- **BuildTag**：`v3-m1.16.0.18.131b-unitline-native-depth-cull`。

## M1.16.0.18.131 — 连线/画圈对齐参考实现 + 校准持久化修复（2026-09-07）

- **实机证据定案（.18.130b 状态行）**：watchdog 生效（连线有消费者了）、投影产出 1 行，但 `渲染层 0 个可见点` 且 **`proj失败=2831`**——投影服务在实机几乎 100% 失败。本轮按用户要求通读参考项目，确认新版与实机可用参考在三个层级全部相悖：
  1. **宿主**：rp_ui.lua EnsureLinesHost / easypull.lua:257 都用 `CreateEmptyWindow(...,"UIParent")` 顶层窗口（200×200、`CorrectOffsetByScreen`）；新版用根 emptywidget + "system" 层——我们自己的 `CreatePanel` 注释（rs_ui_native_primitives.lua:361）早已记录 **"RU clients do not reliably put root emptywidgets into the system layer"**。宿主不可靠渲染=所有子点不可见。
  2. **坐标**：参考对原生 `GetUnitScreenPosition`/`ConvertWorldToScreen` **原值直用**（仅乘 addonScale、depth>0 剔除背后）；新版有逻辑坐标启发式换算 + 出界拒绝 + "原生 vs 逻辑相机一致性 oracle 不一致就替换成相机坐标"——失败计数全部来自这套与实机坐标空间相悖的门禁。
  3. **相机兜底**：参考用物理 `GetScreenWidth/Height`；新版用逻辑视口，算出的点渲染器无法锚定。
- **ScreenProjectionV3 v8→v9**：原生坐标获胜（一致性 oracle/缩放重整退役，选项保留但忽略）；删除 NormalizeScreenPoint 启发式与出界拒绝；ProjectWorldBatch 原生 ConvertWorldToScreen 优先、相机兜底改物理分辨率；全部拒绝路径带 `failuresByReason/lastFailure` 原因遥测。
- **CombatVisualGuidesV3 v6→v7**：宿主改 `S.UI:CreateOverlayWindow`（新 primitive：真窗口 + system 层 + 免击中 + CorrectOffsetByScreen）；点模型 extent 1×1（rp_ui 模型，字号即点径）；**删除 Liang-Barsky 裁剪**（原始坐标采样，屏外点无害且有池上限）；渲染时宿主 Show（rp_ui 模型）；坐标 ×`S.Layout` addonScale（参考同款）；`lastUnitSampling` 带 `firstRow` 坐标与 addonScale 证据。
- **诊断行**：degraded 分支显示 `行=x,y->x,y · UI=缩放 · 原因:top3` ——下一份粘贴即可定位坐标空间/宿主问题。
- **治疗辅助校准重载复开（用户报告 bug1，根因实锤）**：`ApplyPresentationSettingFromBinding` 只改内存**从不 MarkDirty**，与 `SetPresentationSetting`（走 MutateStore）持久化不对称——经按钮关掉的校准不落盘，重载后 store 里的旧 true 恢复，色块每次重载都回来。两条入口统一走 `SetPresentationSetting`。**注意**：装上本版后需手动关一次校准（这次才会真正落盘），之后不再复现。
- **Harness**：e2e 加 `CreateOverlayWindow` mock；sampling 裁剪断言改为参考模型断言（屏外线段照常采样）；audit 契约 token 同步（v7/AddOnScale/CreateOverlayWindow、移除 ClipSegmentToRect）。
- **BuildTag**：`v3-m1.16.0.18.131-reference-aligned-projection`。

## M1.16.0.18.130b — 渲染租约握手 watchdog + 状态行 BuildTag（2026-09-07）

- **第二轮实机报告**：`.18.130` 后单位连线与范围辅助**同时**"已开启但无消费者"，且横幅**零告警**。全链静态复核（Demand 事务、reconcileDemand、Authority:Refresh→read、Events 派发逐 handler xpcall、CallCapability pcall）证明 acquire 事务不可能失败——剩余两类静默死局都是**握手层**的：①presenter 靠订阅 lifecycle 事件拿渲染租约，错过一次事件即永久 0 且无人告警；②runtime stop/start 的 `Demand:ClearAll` 不发 lifecycle，之后 `F:Enable` 因 row.enabled 已 true 直接返回（无事件），presenter 永远持着死租约（失同步）。boss 功能同一客户端正常，正是因为它的租约在自己的 onEnable 内获取，不依赖跨模块事件。
- **修复（CombatVisualGuidesV3 v5→v6）**：新增 1s P3 lifecycle watchdog（健康时每秒只做几次表读取）：启用但未持有→重试 acquire；持有但 `HasConsumer=false`（外部清空）→失同步自愈重取；acquire 失败不再静默（`UNIT/RANGE_ACQUIRE_FAILED` 限频告警 + `lastAcquireError` 遥测）。lifecycle 处理器记录 `lastLifecycle` 回执。
- **诊断诚实性**：单位连线/范围辅助 consumer=0 行改为携带决定性证据——`生命周期=已收:xx/enabled|未收到 · 接管尝试=N · 失败原因=… · 失同步=presenter仍持有`，四种死因一眼可辨。
- **状态行加 BuildTag**：横幅首段追加当前 `S.BuildTag`——杜绝"两份粘贴各来自不同构建却互相比较"的排查黑洞（本轮两份采样的服务器时间倒退正是这类混乱）。
- **Harness**：e2e 新增失同步自愈用例（租约清空→Pump watchdog→消费者与刷新任务恢复）；`desync_watchdog_ticked` 锁定 watchdog 真实注册并运转。
- **BuildTag**：`v3-m1.16.0.18.130b-unitline-acquire-telemetry`。

## M1.16.0.18.130 — 连线/画圈 label 着色门禁修复 + 诊断诚实性（2026-09-07）

- **根因（.18.129d 遗留，连线实机仍会 0 点）**：`PlaceUnitDot` 把可见化排在 `S.UI:SetColor(dot.root,...)` 成功之后（commit-on-accept 语义），而 **LABEL 没有 widget 级 `SetColor`**——RU 的文字颜色在 TextStyle 上（`ui_functions.lua:1387`），widget 级 `SetColor` 只存在于 drawable。`UI:SetColor` 旧守卫 `type(widget.SetColor)~="function" → false` 使每次着色必然失败 → 提前 return → `SetUnitDotVisible(true)` 永不执行，pool/consumer 全部正常但屏幕 0 点。三处参考证据一致：easypull.lua:267、plates rp_ui.lua:2348、本工程 `ApplyTextColor`（rs_theme.lua:75）均走 `style:SetColor`。
- **修复（UI Framework v12→v13）**：`UI:SetColor` 增加 style 回退——widget 无 `SetColor` 时改写 `widget.style`（与 healer_raid_overlay:375 既有用法一致）；无 style 可写时维持拒绝。drawables/复合组件路径零行为变化。连线四色（含用户自定义 `colors[pairKey]`）与画圈颜色随之生效。
- **诊断诚实性**：单位连线 FeatureRow 接入 presenter 侧 `lastUnitSampling`——投影有行但 `uniquePositions<=0` 时降级为 `degraded`（"投影有 N 行但渲染层 0 个可见点"），不再假绿；ok 行补 `点=X(唯一Y)` 证据。
- **Harness mock 收口**：e2e/sampling 两个 harness 的 `S.UI:SetColor` mock 从"无方法也返回 true"改为与 v13 真实语义一致（widget → style → false），并移除 mock widget 上的非法 widget 级 `SetColor`/无条件 `SetFontSize`——此前的 mock 语义正好掩盖了本 bug（15/15 假绿的来源）。
- **BuildTag**：`v3-m1.16.0.18.130-unitline-label-color-fix`。

## M1.16.0.18.129d — 连线/画圈参考对齐：label 句点模型（2026-09-07）

- **参考研究结论**：通读真实可用的 easypull（画圈，`easypull.lua:245-284/:655-687`）与 plates 旧版连线（`rp_ui.lua:2328-2454`/`rp_api.lua:90-203`）：所有实机可用的点阵都是 **LABEL + '.' 字形**（easypull 22px+SetOutline；plates 15px 池），投影双路（原生 `ConvertWorldToScreen` depth>0 → 相机手算），`isLocal=true` 在 easypull:655 有画圈场景实证。
- **新版不可见根因**：旧实现是 emptywidget + `CreateColorDrawable("overlay")` 4×4 色块——参考生态零先例、4px 在 1080p 近乎不可见、`"overlay"` 层名无画点用法。
- **修复**：`EnsureUnitPairPool`/`EnsurePool` 改用 `S.UI:CreateLabel(... '.' ...)`（15px 起）；`PlaceUnitDot`/`PlaceDot` 改 style 字号缩放 + 着色；`NewColorDrawable` 标记 RETIRED 并注明原因。投影路径不动（两参考各证明一条可用）。端到端 harness 断言更新为 label 模型（text=='.' 且 fontSize>=8）后 15/15；采样 harness 补 label mock 后 11/11。
- **BuildTag**：`v3-m1.16.0.18.129d-unitline-label-dots`。

## M1.16.0.18.129a — Integrity v4：内容盲 canonical 根因收口（2026-09-06 复盘）

- **根因定案（三份横幅链）**：bonds/trade 的 fingerprint_mismatch 来自 Integrity v3 世代的**内容盲 canonical**——life bundle 注册助手 `migrate = default` 把"恒返回全新默认表"的函数当规范化器，盖章哈希的是默认表形状而非内容；`.18.127/.18.128` 改默认形状、`.18.129` 换真规范化函数，两次都把旧盖章判成失配。修复 migrate 后 actual 指纹变化（1EC94F52→1FA5386F）正是 canonical 函数变更的直接证据。
- **IntegrityContractVersion 3→4**：v4 canonical = 修复后的 per-store 纯规范化（内容敏感 + 漂移吸收）；v3 盖章（`ContentBlindCanonicalContractVersion = 3` 登记）不构成完整性证据，走封印+全量业务校验的一次代受控升级并重盖 v4；`integrity_contract_upgrade_recovery` 状态 + 计数。四个 life store 显式传入真 migrate，bonds 预算加深（快照域 21 面板中文文本）。
- **门禁/回归**：v9 harness 新增内容盲恢复用例（含内容完整保留断言）；v3-v9 + task codec + 快照 harness 全绿；Foundation Audit PASS（toc 221/221）。

## M1.16.0.18.129 — 真实故障收口（单位连线单点 / Boss 事实模型 / 治疗生命周期 / 全域修复）（2026-09-06）

- **单位连线"只有一个点"（P0-1）**：三处真实根因同时收口——①端点重合过滤从"两轴各 ≤1px"改为**线段长度 ≤ max(4, 2×点径)**（`rs_business_bridge.lua` read()）：2–4px 近重合段此前漏过过滤，渲染层把 ~24 个点堆进几个像素，视觉上就是"一个点"；②presenter 点位/可见性缓存**只在底层 Native 写入成功后提交**（`rs_v3_combat_visual_guides.lua`）：无条件提交曾让一次被拒的 Show/Anchor 造成永久失同步，所有点卡死在 (0,0) 叠成一个黄点；③多对连线的 pool 增长预算改按剩余 pair 均分（首对独占曾让其余对连续多帧 0 点）。`_ProjectWithCameraFrame` 路径补逻辑视口边界（`viewportRejects` 计数），ReconcileOne 渲染失败不再同拍释放 Consumer（保留自动重试）。诊断新增 `uniquePositions`。
- **Boss/首领机制（P0-2）**：与 wbdebuff 完整对比后确认其可用性来自"player/target/targettarget/watchtarget 四单位施法名轮询 + player debuff 数值 id 轮询"，零事件注册。新版此前施法只看 target 且被未验证的 `showTargetCastingTime` 门静默杀死——本轮 CastingObservationV3 升 v2（四 scope），Boss 观察按 wbdebuff 顺序消费四 scope（每 scope 独立边沿签名）、去掉 showTargetCastingTime 门、施法名索引/查找大小写归一、AuraObservation 的 effectId 提取优先 `buff_id`（唯一实机证据字段，wbdebuff/buffblackdragon.lua:46）。新增 Boss 诊断行（ticks/source/casting/debuff/rule）。**数据事实（23474/25846 + 3 组 RU 技能名）仍全部来自 wbdebuff，未做实机复核**。
- **Persistence（P0-3）**：升级恢复事件携带 canonical 差异诊断（`DescribeCanonicalDivergence`：磁盘域 vs 规范形的第一个不同字段，写入 store.lastIntegrityDivergence），落实验收 §8.4。GearV3 分片加**旧序指纹桥**：旧数字序盖章的存档经 `LegacyPayloadFingerprint` 证明内容完好即接受一次并在下次保存重盖，避免定义序修复把旧方案判成损坏。
- **治疗辅助（P0-4 + P1-5）**：校准模式改为只持 Preview 租约（`previewHeld`），`consumerHeld=false`——此前校准必违反 gate 与 acceptance 的 `enabled_calibration_contract`，是 healer_v3_visual_lifecycle 误报的真因；head/raid overlay 的 Reconcile 失败不再静默（WarnRateLimited 带错误码）。布局常量对齐旧版实测值（outerPad4/titlePad22/groupGap4/rowGap1/sectionGap8 → 默认 340×400 下 sectionH196/cellW63/slotHeight33）。
- **Trade（P1-3）**：`SetFrom` 保留 latest-route（修复"A→B 在飞 → 选C → 换起点D 后 UI 永久空列表"死角）；Request 失败自动重启 pending 路线；无主回调（超时后迟到）计数暴露（无 request-id 不可安全归属，保持丢弃）。新增 `TA:DescribeRequestState` 诊断。
- **Bonds（P1-4）**：widgetWindow 经 FloatingSurface 归一（此前为唯一透传字段、指纹漂移首候选）；boardReads/每日缓存状态诊断（`DescribeDailyCache`）。去重（材料+数量）与每日一次读取逻辑经代码复核确认已符合规则，本轮补齐可观察性。
- **HUD 布局重叠（P1-6）**：根因 = `Form` 无 `Measure`，TransformInspector 测到的是上次 Layout 的陈旧高度，展开锚点节后下一节叠上来。实现 FieldGroup/FormSection/Form 三级纯测量（FieldGroup 高度 = 响应式网格数学的无副作用复制）。
- **Activity Tooltip（P2-2）**：Pointer 增加最后成功采样缓存；退化矩形（0,0,1,1）不再作为锚点；最终回退为视口居中而非左上角。
- **整理背包（P2-3）**：不确定错误（pcall/能力异常文本）同样跳过该 identity 继续——此前只有 "returned false" 才跳过，一次异常文本终止整个队列。取/放/停 tooltip 经复核已走统一 TooltipService（cursorFollow）。
- **Boss 无 Boss 验证路径（黑龙 3 天一刷，用户无法当场验收）**：新增 `SimulateCast`/`SimulateDebuff` 命令与页面按钮（仿真读条/仿真Debuff）——把目录规则注入真实 BossCastIndex 匹配 + AlertsService 推送链（旧参考项目 SimulateAlert 的已验证模式）；`Boss:` 诊断行增加 `seenCast=` 施法名捕获环（最近 8 个去重真名），任意读条怪/未来任意 Boss 战斗都能自动取证 RU 名称，命中 wbdebuff 表即完成验收。
- **门禁**：Foundation Audit PASS（toc 221/221）；luacheck 0 errors；31 个 harness 28 全绿（3 个失败为 .18.104 遗留、已在 HEAD 复现）；新增 `GEAR_SLOT_ORDER_HARNESS`；`.18.128` 契约 harness 随四 scope/归一化更新。BuildTag：`v3-m1.16.0.18.129-real-failure-closeout`。

## M1.16.0.18.128 — Runtime Follow-up + Shared Facts + Layout Repair（2026-09-06）

- **换装顺序稳定**：`Gear Store` 统一使用 `GearV3.EquipmentSlots` 的权威语义顺序归一方案，`获取当前 → 保存方案 → Reload` 不再因 Native slot 数值排序反复变序；`.18.127` 的单槽 `not_found` 跳过/继续契约保持不变。
- **治疗辅助回归真实 50 人团队几何**：撤销 `.18.127` 错误的 10×5/670×180 模型；schema 6 + Raid Overlay v4 固化“单团 50 人 = 上 25 + 下 25，每半区 5×5，约 340×400”。Auto 面板跟随原生团队 1/2 标签当前页；额外友军列表可显式承载另一完整团队。上一版生成的 670×180 自动迁移回 340×400 并保留 x/y。TeamRoster v6 同时修复“成员身份未变但原生团队页切换”不发布的问题。
- **Unit Lines / Range Assist 共同投影自愈**：`ScreenProjectionV3 v8` 在 Camera Frame 暂时不可取得时，对当前有界批次启用 Native Projection fallback；Camera Frame 恢复后仍回到 global-world + front-hemisphere 严格校验。无跨帧坐标缓存、无新 Tick。
- **跑商快速切路线**：由于 `SPECIALTY_RATIO_BETWEEN_INFO` 没有 request-id，路线请求改为 `single-flight + latest-route`。旧请求执行期间只保存最后一次起点/目的地；旧回调不会写入已切换路线，释放单飞通道后立即查询最后选择。6.5s timeout 保留。极晚的“超时后旧回调”仍属于 Native 协议无法完全归因的 RU 实机风险。
- **债券每日快照与正确去重**：居民板按服务器日期 + 大陆持久化 compact snapshot；同日 Reload/筛选/排序不再重复读取已缓存大陆。大陆任务身份改为 `材料 + 数量`：西/东“皮革20”互斥去重，而 20/60/100 保持三个独立每日任务；完成 latch 跨西/东共享。
- **Bag / Activity UX**：整理背包 `取 / 放 / 停` 接入统一 Cursor Tooltip；虚拟表格/活动行自动 Tooltip 改为跟随真实鼠标，避免 pooled row 的旧坐标把说明弹到窗口远端。
- **首领机制真正接入运行时事实**：新增共享只读 `CastingObservationV3`，与既有 `AuraObservationV3` 一起成为 Boss 实时事实源；Boss 模块仅在启用且 HUD 开启时持有 Demand，目标施法 100ms、自身 Debuff 300ms，均走预建精确索引，不在高频路径做模糊 Tag/字符串扫描。`BuffDisplay` 也改复用同一 Casting Service，并修复双 lease 释放时单一失败提前 return 可能残留另一 lease 的生命周期问题。
- **状态显示 HUD Inspector 布局修复**：`TransformInspector Contract v3` 新增真实 `Measure()`，父 Scroll/Layout 能取得展开后的完整高度，修复截图中 Transform/Anchor/吸附设置区域互相覆盖的严重排版错误。
- **门禁/回归**：Foundation Gate v119、UIV3 Acceptance v74；Active/All Lua `221/221` Parse PASS，Foundation Audit PASS，30/30 Python Harness PASS；新增 `.18.128` 专项 Harness，ScreenProjection 25/25、Bag Move v8 11/11、Team Visual 34/34、Trade/Craft 22/22 等既有套件继续通过。
- **BuildTag**：`v3-m1.16.0.18.128-runtime-followup-shared-facts-layout`。

## M1.16.0.18.127 — Runtime Continuation + Native Raid Geometry（2026-09-06）

- **换装继续执行**：`GearV3 v4 / PartialApplyContract v1` 将“背包未找到目标装备”降为单槽可跳过结果；其它可定位装备与称号继续执行。`read_error/ambiguous` 仍 fail-closed，运行中目标消失同样只跳过该槽，最终以“部分完成 + 跳过数量”报告。
- **跑商刷新恢复**：`Trade.Authority v5` 为路线请求增加 6.5s one-shot 超时护栏；手动“刷新”会对当前完整路线显式重发 `GetSpecialtyRatioBetween`，不再只刷新地区列表。关闭 Demand/Feature 时同步撤销 timeout。
- **整理背包满仓继续**：`BagMoveContract v8 / FullStorageContinuation v1` 移除“仓库无空槽=全局拒绝”的错误前置条件。`MoveToEmpty*` 对某一稳定 identity 返回 false 或连续无进展时，仅屏蔽该 identity，继续后续物品；API 缺失、读失败、无稳定 identity 仍立即停止。快捷取放与类别批量均记录 skipped。
- **治疗辅助对齐原生团队名单**：Healer Store schema 5 将旧不可缩放默认 `340x400` 迁移为 full-grid `670x180`（保留 x/y）；Raid Overlay v3 使用原生 5 人/队的列优先映射（1–5 第一列，6–10 第二列），根据 TeamRoster 实际最高 memberIndex 动态裁剪可见列。20 人时逻辑宽约 267px，与实机截图约 268px 对齐。拖动只提交 x/y，不把动态裁剪宽度写回 full-grid geometry。
- **门禁/回归**：Foundation Gate v118、UIV3 Acceptance v73；新增 `.18.127` 四项专项 Harness。220/220 Active Lua parse、Foundation Audit、29/29 Python Harness 全 PASS。
- **BuildTag**：`v3-m1.16.0.18.127-runtime-continuation-native-roster`。

## M1.16.0.18.126 — Range Assist Global World + Dense Batch Projection（2026-09-06）

- **Range Assist 世界坐标空间修复**：审计发现范围辅助仍使用 `ScreenProjectionV3:GetUnitWorldPosition("player", true)` 获取本地空间自身坐标，却把生成的圆周点交给以 `UIParent` 全局 Camera Frame 为基准的 `ProjectWorldBatch`。这与 `.18.96` 已修复的 Unit Lines 混合坐标空间问题同源；本轮统一改为 `isLocal=false`，范围圆中心与 Camera Projection 使用同一全局世界空间。
- **ScreenProjectionV3 v7 稠密批量索引契约**：旧 `ProjectWorldBatch` 只为投影成功点写 `out[index]`，behind-camera/无效点会形成稀疏 Lua 数组；Range Assist 使用 `ipairs` 时会在首个 `nil` 停止，导致整圆消失或只剩短弧。v7 对每个输入索引都返回 `{visible=true,...}` 或 `{visible=false,reason=...}`，并新增 `WorldBatchIndexContractVersion=1`。Range Assist 同时改为 `1..count` 显式索引遍历，双重防止稀疏数组截断回归。
- **门禁补洞**：Foundation Gate v117 / UIV3 Acceptance v72 要求 ScreenProjection v7、WorldBatch index contract、Range global-world contract；Foundation Audit 新增静态检查，禁止 Range Assist 重新使用 player local-space 或 sparse `ipairs` 消费。投影专项 Harness 从 21/21 扩为 **25/25**，覆盖 front/behind/invalid 混合 batch 的稠密索引。
- **当前本地基线复核**：本次用户上传工程的 Foundation Audit PASS（toc/active/all=220/220/220），当前 **28/28 Python Harness 文件全部 PASS**。`.18.125` Changelog 中记载的 3 个历史 Harness 失败保留为当时事实，但在本次 supplied baseline 已无法复现；RU Fresh Reload 仍是 P0，不能用本地绿灯代替真机视觉/Native 证据。
- **BuildTag**：`v3-m1.16.0.18.126-range-global-indexed-projection`。

## M1.16.0.18.125 — Integrity v3 Canonical + UnitLine 自愈 + Buff 装备诊断（2026-09-05）

- **Persistence Integrity v3（canonical）**：`.18.124` 的 strict shape-repair 在 RU 实机仍被拒绝（`v3.tasks` / `v3.death_review` Envelope Seal 健康、指纹却无法被任何重建候选复现）——根因是 v2 原始包封指纹对结构级表示漂移（map→sequence、空表丢失、版本形状漂移）本质脆弱，而"候选必须逐字复现旧 stamp"与"旧 stamp 属于旧代码形状"互相矛盾。本轮按 §14 canonical 管线重做：保存与加载两侧都以 `CanonicalIntegrityValue`（codec encode / migrate 固定形状 normalize）计算指纹（`integrityVersion=3`），逻辑等价的表示漂移被吸收，内容变化仍 fail-closed；v3 加载管线为 Decode → Normalize → Verify → Apply。
- **受控旧档升级通道（默认开启，实机复核后从 opt-in 翻转）**：`integrityVersion=2` 的旧档 mismatch 时，在 Envelope Seal + decode + budget + schema 全部通过后按 `integrity_upgrade_recovery` 接受一代并立即重盖 v3。第一份 `.18.125` 实机横幅证明漂移是序列化器普遍行为（bonds / gear.payload 分片 / death_review.record 分片同轮全部 mismatch，`v3Upgrade=0/1` 证明白名单只救回 1 个健康重盖），逐 Store opt-in 只会逐批封存用户数据，故翻转为默认；journal 分片（gear.payload 等）同样纳入——优于替代的 `replaceCorrupt` 破坏性覆盖；Domain 可显式 `allowIntegrityUpgrade=false` 退出。`rebuildEncodedForIntegrity` 升级为多历史形态候选（pre-codec 裸 Domain 形 + 中间包装形），`DecodeTaskState` 兼容三种历史形态——旧用户数据无需重置。
- **decoder 契约收窄（显式）**：v2 的"损坏数据不进 decoder"收窄为"**损坏数据不进 apply/Domain**"（decode/encode 钩子均为纯规范化 + pcall + 预算检查）；`VerifyPersistedValue` 对 v3 盖章改比 canonical，屏障回读不再因表示漂移假失败。
- **Unit Lines 偶发永久失效根因收口**：除 `.18.124` 的 World Alias Guard 外，本轮闭合残余坍缩路径——alias 候选的 camera 一致性 oracle / camera fallback 是把端点锚到玩家身上的最后通道，现在 alias 候选 native 屏幕证据成功即直接采信（`native_alias_candidate`），native 失败则 fail-closed（`aliasNativeKept/aliasNativeRejects` 计数）；read() 对两端点 ≤1px 重合的 pair 输出 ENDPOINT_COLLAPSED 拒绝而非画点团。**真正"永久失效"的载体是 Scheduler 熔断**：3 连败即永久禁用且无自愈，现在改为指数退避自动恢复（2s→60s 封顶，持续故障每分钟至多一次尝试），`faultResumes` 进入 GetHealth。
- **Buff Display 自身装备可观察化**：`.18.124` 改走 GearV3 后实机图标仍空白，剩余未知（RU tooltip 的 icon 字段名 / lane 是否 tick / 读取是否报错）只能实机回答。`ReadEquippedIcon`/`EquipmentTick` 全链计数（reads/icons/empty/errors/unresolvedSlots/iconField/lastError/sampleItemKeys），诊断面新增 `BuffGear:` 与 `UnitLines:` 单行可复制诊断、Store 行追加完整性状态。背部槽位维持"仅运行时 `ES_BACKPACK`、缺失即跳过并计 unresolvedSlots"，不猜测数值。
- **门禁/回归**：Foundation Audit PASS（toc=220）；持久化 v3-v9 + 任务 codec + 投影 21/21 + Scheduler 恢复 + Buff 装备数据层全部 PASS；`rs_*_harness` 中 25/28 全绿，`rs_interactive_draft_harness` / `rs_recovery_launcher_harness` / `rs_runtime_entry_lifecycle_harness` 为 `.18.104` 遗留失败（HEAD 复现相同，与本轮无关，另开工单）。
- **BuildTag**：`v3-m1.16.0.18.125-integrity-v3-canonical-unitline-recovery`。

## M1.16.0.18.124 — RU Integrity / UnitLine Alias / Buff Equipment Hotfix（2026-09-05）

- **RU 启动阻断修复**：`AuctionSurfaceV3` / `CraftSurfaceV3` 明确声明 `presentationBoundary = service_only`，保持 Native 窗口只读观察在 Service、Sidecar 渲染在 Presentation；UIV3 Acceptance 与 Foundation Audit 同时锁住该边界，避免以后新增 Service 再次因为漏声明把 `service_presentation_boundary` 打成 Blocker。
- **`v3.tasks` 稳定持久化编码**：Task Domain 继续使用 O(1) membership map，但 SaveData 改用 codec v2 的排序字符串序列；不让 RU serializer 自行决定动态 map 的物理表示。已有 pre-codec 存档若发生已观测的 map→sequence 形态变化，只能通过 Store 专属 `rebuildEncodedForIntegrity` 重建候选，而且 Persistence 必须在 Envelope 已验证、非 Critical/Journal 的前提下证明候选**精确复现原 stamped fingerprint**才允许加载；任何业务值变化仍 `integrity_failed` + write fence。成功恢复后立即改写 codec v2。
- **Unit Lines 偶发端点重合**：`ScreenProjectionV3 v6` 增加 batch-local World Alias Guard。不同 Unit Token 若瞬时拿到近乎相同 world fact，但同 batch 的 Native screen point 明确分离，则把该 world fact 判为 stale alias，仅本批次使用 `native_world_alias_guard`，不再让错误 camera consistency fallback 把目标端点覆盖到玩家自身。无新 Tick、无跨帧缓存、仍为 bounded token batch。
- **Buff Display 自身装备**：主手/副手/远程改由共享 `GearV3:GetEquipped()` 读取，消除 Feature 内重复 Native 语义；HUD Layout 增加显式 `主手 / 副手 / 远程 / 背部` 快捷开关，并继续写同一 Layout Working/Apply Authority。背部仍只接受运行时 `ES_BACKPACK`，没有把 `EST_BACKPACK` 或猜测数字当 slot。
- **门禁/回归**：Foundation Gate v116、UIV3 Acceptance v71；Active/All Lua `220/220`。新增 `TASK_PERSISTENCE_CODEC_HARNESS PASS`，`SCREEN_PROJECTION_FRONT_HEMISPHERE_HARNESS 18/18`；25 个 Python Harness 文件全部 PASS，Foundation Audit PASS。
- **BuildTag**：`v3-m1.16.0.18.124-ru-integrity-unitline-buff-equipment-hotfix`。

## M1.16.0.18.123 — Inventory Snapshot V3 + Bag Move Queue v7（2026-09-05）

- **参考项目边界正式固化**：参考旧项目只作为“用户应该能做什么”的行为证据，不迁移旧 Service/全局状态/重复扫描/事件模型。新增架构规则写入 `CURRENT_ARCHITECTURE.md`，后续所有参考功能都必须重新落在 Active V3 Authority/Service/Demand/RSUI 上。
- **InventorySnapshotV3**：新增共享只读背包/银行/箱子快照 Service。物理背包统一沿用 GearV3 已验证 `bagId=1`，仅在首选视图没有可读行时有界回退 `bagId=0`；Native item table 立即归一为 detached primitives，一次遍历同步建立 identity/category count/stack indexes，不拥有黑名单或 Move 业务。
- **Bag Move Queue v7**：Quick 取/放同类由“每个槽一条 queue record”改成 grouped stable identity intent；Category Batch 同样只有一个 `{category, remaining, slotHint}` intent。`slotHint` 只是下一步快速定位，写前必须 live revalidate，失效才绕容器一圈；只有写后同槽仍为同 identity/category 的歧义情况才做 bounded population count，并支持 `stopAt` 提前确认 no-progress。保持 250ms、单队列、单 Native write、最多 2 次 no-op retry、Feature/窗口退出立即释放。
- **bagId 硬编码收敛**：Bag 页面读取与直接移动前黑名单检查均复用 `InventorySnapshotV3`，不再在整理背包路径硬编码 `GetBagItemInfo(0, slot)`；UI 诊断显示当前物理 bagId 与兼容回退状态。
- **门禁/回归**：Foundation Gate v115、UIV3 Acceptance v70；Active/All Lua `220/220`，Foundation Audit PASS。`BAG_MOVE_QUEUE_V7_HARNESS 10/10`；24 个 Python Harness 文件全部通过。Product Matrix 仍为 `80 IMPLEMENTED / 35 PARTIAL / 0 TODO / 11 SPECIFIC_RUNTIME_BLOCKED`，`RU-BAG-01` 在 RU 多堆连续移动证明前保持打开。
- **BuildTag**：`v3-m1.16.0.18.123-inventory-snapshot-bag-queue-v7`。

## M1.16.0.18.122 — Team Sac Highlight + Verified Marker Snapshot（2026-09-05）

- **团队中心继续迁移参考旧版能力**：在既有 `combat_team_tools` 单一 Feature Authority 上新增 `TeamVisuals` 扩展，不新建第二个团队 Runtime/Store 入口。牺牲之舞候选仅在 TeamRoster 变化与 10s safety scan 时读取职业模板，精确沿用参考项目已存在的 Spelldance ability index 14 与 Sac Buff IDs `30098/30137/30141/30142`。
- **共享 Aura / 独立视觉生命周期**：Sac Buff 事实统一复用 `AuraObservationV3`，候选存在时才持有 Aura Consumer，并以 1200ms bounded safety scan + 可选 `BUFF_UPDATE` 120ms coalesced edge 加速；Presentation 才使用 `ScreenProjectionV3:ProjectUnitBatch`，只有真实 active Sac 行存在时创建/运行 50ms visual task，最多 16 个 marker，Domain 无 Tick/屏幕投影。
- **团队头标快照/恢复**：通过已登记的 `X2Unit:GetOverHeadMarker` 保存当前团队已存在的非零头标，最多 16 条、按角色名+markerIndex 去重；显式保存/清空使用 durable Store mutation。恢复不调用旧版 `RemoveAllOverHeadMarker`，而是 1100ms 串行队列；每次写前必须先读当前值，已正确则零写跳过，发生写入后下一拍必须 `GetOverHeadMarker` 回读一致才继续。任何读取/写入/回读失败立即 fail-closed。
- **生命周期事务加固**：TeamRoster/Aura Demand acquire/release 都验证返回；Aura 成功释放后若 Roster release 失败会尝试重新 Acquire Aura 回滚，Feature Disable 只有扩展资源全部释放成功才继续 Base Disable。Sac 开关的 runtime lease 与持久 intent 也做双向 rollback，避免 UI/Store/Service demand 分叉。
- **仍不越过 Runtime Blocker**：`MoveTeamMember/MoveTeamMemberToParty` 继续等待合法队长/权限 getter；本轮没有自动清空头标、没有猜 Skullknight 自动标记索引，也没有把参考旧版权限推断迁入 V3。
- **门禁/回归**：Foundation Gate v114、UIV3 Acceptance v69；Active/All Lua `219/219`。新增 `TEAM_VISUAL_MARKER_HARNESS 34/34`，Foundation Audit / Presentation→Feature API / RSUI Component API 全部 PASS；Product Matrix 仍为 `80 IMPLEMENTED / 35 PARTIAL / 0 TODO / 11 SPECIFIC_RUNTIME_BLOCKED`，团队组合能力保持 PARTIAL，直到 RU 验证 Sac 视觉/头标权限与成员整理契约。
- **BuildTag**：`v3-m1.16.0.18.122-team-sac-marker-snapshot`。

## M1.16.0.18.121 — Craft Multi-Plan + Native Craft Sidecar（2026-09-05）

- **制作规划多配方**：新增 `CraftPlanContract v1`；最多 12 项、每项 1–999，永久 Store 只保存稳定 `recipeKey + quantity`。多个配方的已核材料统一聚合，并复用现有 bounded Bag held facts 计算缺口。
- **计划成本**：新增显式 `QuotePlanMaterials`，仅经 `PriceQuoteQueueV3` 去重/限速询价；投影区分总需求报价与当前缺口报价。普通刷新仍为只读，不后台访问拍卖服务器。
- **制作台 Sidecar**：新增 `CraftSurfaceV3` / `tools.craft_sidecar`，只读观察三种已导出的 Native Craft UIC；400ms 观察只在 `tools_craft` 启用且自动侧窗打开时存在。四值 MainScript 返回必须由 `ADDON:GetContent` 父链可见性补强，否则 fail-closed。
- **生命周期**：Sidecar 复用 `tools_craft` 单 Authority，显示期独立持有 Consumer，关闭/原生窗口退出即释放；用户手动关闭后本次 Native session 不重弹。无未验证 Craft Event、无第二 Store、无隐式 Auction 查询。
- **门禁/回归**：Foundation Gate v113、UIV3 Acceptance v68；Active/All Lua `217/217`。新增 `CRAFT_PLAN_HARNESS 25/25`、`CRAFT_SIDECAR_HARNESS 28/28`；23 个 Python Harness 文件全部 PASS，Foundation Audit PASS。Product Matrix 更新为 `80 IMPLEMENTED / 35 PARTIAL / 0 TODO / 11 SPECIFIC_RUNTIME_BLOCKED`。

## 2026-09-05 — v3-m1.16.0.18.120-trade-detail-favorites-workflow

- **路线收藏恢复（V3 Authority）**：对照旧版 `rs_trade_service.lua` / `rs_trade_widget.lua` 的用户行为，只迁移无需新 Native API 的部分。`life.trade` Store 统一持有数值 `from:to` 路线收藏，去重且最多 12 条；主 Trade 页面与 `life.trade` HUD 共用 `ToggleCurrentFavorite / SelectFavorite / SetSortMode`，没有第二份 Presentation 状态。
- **共享 Trade Detail Floating**：新增 `TradeDetailFloatingV3`。主页面与 HUD 选中贸易品行都会打开同一悬浮详情，展示路线、当前/满货率投影、材料数量/单价/小计/状态；详情几何与 row selection 仅 Session，显示时独立 `AcquireConsumer("floating:trade_detail")`，关闭/失效时释放 Consumer 与内部订阅，不把 HUD 生命周期绑到详情。
- **显式选中行材料询价**：新增 `QuoteRowMaterials(rowKey)`，只遍历当前行 `explicit_quote_required` 材料，去重并受共享 `PriceQuoteQueueV3.maxQueue` 限制，最终仍调用既有 `QuoteMaterial`。普通 Trade Refresh、收藏切换、排序都不会隐式触发 Auction 查询。
- **路线持久化一致性修复**：Origin 真正改变时，在写 Store 之前同步清除旧 Destination，避免 runtime 已清空但 Durable Store 仍保存旧目的地的分叉状态。
- **Product Truth 不越界**：没有恢复旧版猜测的经商熟练度价格倍率，也没有实现缺事件证据的自动制作台刷新/叛乱记录；Fishing Auto-R 与 Reinforcement slot probing 继续 blocked。
- **门禁/回归**：Foundation Gate v112、UIV3 Acceptance v67、`Trade.Authority v4`、`LifeEconomyWidgetsV3 v3`；Active/All Lua `213/213`。新增 `TRADE_DETAIL_FAVORITES_HARNESS 35/35`，全工程 21 个 Python Harness 文件 0 failures，Foundation Audit PASS。
- **BuildTag**：`v3-m1.16.0.18.120-trade-detail-favorites-workflow`。

## 2026-09-05 — v3-m1.16.0.18.119-trade-craft-user-workflow

- **Trade current/full 模式**：`life_trade` Store 新增 `ratioMode=current/full`，保留服务器 `currentRatio` 事实；full 仅以 130% 需求上限做本地价格/毛利对比，不重发服务器货率查询。主页面与悬浮窗均可切换并持久化。
- **Commerce proficiency 只读观察**：Demand 0→1 / 显式刷新时通过已注册 capability `X2Ability:GetAllMyActabilityInfos` 读取 Commerce/经商/贸易/Торговля 的 `point+modifyPoint`。Projection 明确 `priceIncludesCommerce=false / commercePriceFormulaStatus=unverified`，禁止把参考旧版 `5%/10000` 公式当成当前 RU 事实。
- **Craft 显式批量材料询价**：制作规划与制作台助手新增“材料询价”；仅扫描当前已投影材料，按 itemType/grade 去重，最多提交 `PriceQuoteQueueV3.maxQueue`，普通 Refresh 继续零 Auction fan-out。批次回调只在最后一项完成后重建一次 Feature，避免每 560ms 对 Craft+Bag 做全量重扫；材料文本新增单价/小计，页面显示已报价材料数、当前小计和待询价数。
- **Task 自定义追踪可发现性**：父任务投影从空白/勾号改为 `＋ 可添加 / ✓ 已追踪`，追踪列固定 78px；Header、摘要和健康提示明确“选中父任务 → 加入/取消追踪 → 悬浮窗只显示选择项”。不新增第二份追踪状态。
- **Lua 5.1 local budget**：业务 mega-bridge 新逻辑全部复用/嵌套 helper，顶层 locals 保持 200/200；Foundation Audit 新增上限 fence，避免后续 Agent 使整个 chunk 因 local 数超限无法加载。
- **回归**：新增 `rs_trade_craft_modes_harness.py`，22/22 PASS；Foundation Audit PASS（212 Active/All Lua，serviceUpward/productTruth/rawNative/presentation violation 均 0）。
- **BuildTag**：`v3-m1.16.0.18.119-trade-craft-user-workflow`。

## 2026-09-05 — v3-m1.16.0.18.118-top-level-layer-popup-foundation

- **修复共享 Dropdown/Popup 不可见根因**：RU 的 UIParent 级 `emptywidget` 即使尝试 `SetUILayer("system")` 也不能可靠跨过 V3 根 Window；Dropdown/ColorField/ContextMenu 的交互弹层现仅在 root transient 场景创建真实 Native `window`，默认 hidden + unpickable，打开后仍由既有 PopupCoordinator/事务控制。普通页面内 Panel 不受影响。
- **Top-Level Layer Contract v1**：UITokens v5 固定 `Shell(100) < Floating(1000) < Popup(10000) < Modal(12000)`；WindowShell v24 统一进入 `system` layer、关闭 Native modal/ESC ownership，并按 `layerRole` 应用 priority。FloatingSurface 只声明 `floating` role，Feature 不直接控制 Native Z-order。
- **修复“悬浮窗其实打开了但在主菜单后面”**：应用主 Shell 固定 shell priority，独立 HUD/FloatingSurface 使用更高 floating priority，重新显示仍由 WindowShell `BringToFront()` 作为同角色 recency tie-break。
- **任务详情复用收敛**：Activity 主页面与 Activity/Task 悬浮组件统一调用 `QuestDetailFloatingV3`；主菜单不再独占 Modal 子窗口，因此关闭主菜单后详情窗口可继续按独立 Floating 生命周期工作。
- **任务追踪 UX 收敛**：Task 主页面也切到同一 `QuestDetailFloatingV3`；“启用/关闭 + 打开悬浮窗”调整到第一操作位，日常/周常/仅追踪随后，既有逐任务“加入追踪/取消追踪” Store Authority 保持不变。
- **债券悬浮窗可独立操作**：增加紧凑排序、20/60/100、原大陆、去重、东/西优先 Toolbar，全部复用 `life_bonds` 现有 Commands/Store，不复制业务状态。背包材料扫描不再因为无关的未堆叠物品缺少 stackCount 就把所有“有/缺”降为 `?`；只有相关材料自身不可计数或槽位/身份读取失败才保持 partial。
- **债券完成状态防误判**：参考旧版已验证的“同日 mainland material+quantity 正向完成锁存”行为，在 V3 Bonds Store 内新增 server-date completion latch；仅 `COMPLETED` 正向证据可写入，日期未知时不清空，可靠日期跨日才清空。未锁存的 `NOT_ACCEPTED` 对居民日常显示“待确认”，不再把“已交后退出活动列表”错误宣称为“未接”。
- **整理背包 Bag Move Queue v6**：Quick 与 Category Batch 仍保持 250ms 串行与 live source re-resolve；同类识别优先 `itemType`，RU 槽位行缺失 itemType 时只对已读事实保守回退到 `name + grade + category`，解决槽位压缩/同类换槽后队列错误认为“没有同物品”。对 Action true/no-op 仍最多 2 次同节拍有界重试，连续无变化 fail-closed；不引入 Tick/并发写。专项 Harness **6/6 PASS**。
- **团队中心信息架构**：左侧导航将“团队管理 / 战备检查 / 招募助手 / 攻城战备”收敛为一个“团队中心”入口；四条 semantic route 仍保留，并在页面顶部用共享 Tab 互相切换。切换仍由 PageHost 释放旧页 Consumer、进入新页再 Acquire，**没有合并四个 Feature 的 Demand/Cache/生命周期**；攻城战备 Runtime Blocker 原样保留。
- **目标监控产品入口退役**：按用户实机价值评估移除“目标监控”独立左侧导航项，但保留 `combat.target_monitor` route、Feature 和 Demand-scoped 目标事实能力，避免状态显示/单位连线等未来 Consumer 因 UI 去留而断链；没有删除 Store/Service。
- **Auction Sidecar V2（参考旧版行为恢复）**：新增只读 `AuctionSurfaceV3 v2`，观察原生 `UIC_AUCTION` 可见性/几何；兼容 RU `GetContentMainScriptPosVis` 只返回四值，并用 `ADDON:GetContent` 的短父链 `IsVisible`/几何作更强事实。`tools.auction_sidecar` 跟随原生拍卖行左右安全停靠，复用现有 Favorite Store + `AuctionQueryV3`，不建立第二份收藏/搜索状态、不在观察刷新中发服务器查询；手动关闭后只抑制当前拍卖会话。专项 Harness **23/23 PASS**。
- **门禁**：Foundation Gate **v111** / UIV3 Acceptance **v66** 要求 UITokens v5 层级单调性、WindowShell Top-Level Layer、Bag Move Queue v6 与 Auction Sidecar v2 合同；Foundation Audit 当前 `toc=212 / activeLua=212 / allLua=212` PASS，19 个 Python Harness 文件全部 PASS。RU 实机仍需验证下拉、Floating Z-order、Bag 连续移动、Auction Sidecar 与 Bonds 真实数据后才关闭对应 TODO。
- **BuildTag**：`v3-m1.16.0.18.118-top-level-layer-popup-foundation`。

## 2026-09-05 — v3-m1.16.0.18.117-deferred-keyboard-activation

- **修复 DPS 页面打开后整个游戏键盘失效**：真实根因不是 DPS 统计 Authority，而是 `CreateEditBox/CreateMultiEditBox` 在 Native 构造阶段立即 `EnableKeyboard(true)`。ArcheRage RU 可在输入框尚未真实编辑时把 WASD/技能/聊天键盘所有权交给该 EditBox；DPS 的隐藏“首领名称”输入框只是最先触发该底层缺陷的 Consumer。
- **Deferred Keyboard Activation Contract v1**：所有 Suite 单行、数字与多行输入默认 `EnableKeyboard(false)`，仅在用户明确点击输入控件后由 UI Lifecycle `ArmInputWidget -> SetFocus` 临时武装；`OnLostFocus`、隐藏、禁用、失去 Pick、切页、Runtime Quiesce、Component/Owner Release 全部解除 Keyboard。不存在 Tick/键盘轮询。
- **Authority/Fail-closed**：新增 `ArmInputWidget / DisarmInputWidget / ActivateInputWidget / DisarmInputWithin / BindDeferredInputActivation`；只操作已登记的 Suite input。Raw multiline 仍只存在状态显示导入框一个调用点，通过公共 lifecycle helper 接入，Presentation 不直接绑定 Native handler。若点击/失焦事件无法建立，则输入框直接禁用并隐藏，宁可降级也不抢游戏键盘。
- **门禁**：Native Interaction v6、UI Framework v12、Input Focus Lifecycle v2、Hidden Input Isolation v2、Foundation Gate v109；专项 `rs_input_focus_drag_harness.py` 扩为 **88/88 PASS**，Interactive Draft **110/110 PASS**，Foundation Audit 与全部现有 Harness 继续 PASS。
- **BuildTag**：`v3-m1.16.0.18.117-deferred-keyboard-activation`。

## 2026-09-05 — v3-m1.16.0.18.116-product-truth-runtime-block-hardening

- **Fishing Auto-R 收回 Runtime Blocked**：保留 TARGET_CHANGED/BUFF_UPDATE 的 bounded 鱼动作识别与技能栏推荐；删除 Active V3 中全部 `X2Hotkey` 读取/写入链。此前实验性 `State.recovery` 只读隔离，不再把读取失败误判为空绑定并执行 Remove。UI 明确显示 Auto-R 已阻塞，直到 RU Fresh Reload 证明完整源槽位、bound/unbound/read-failed 三态、Durable recovery、写入回读与逐写点故障回滚。
- **强化分析停止猜槽位**：删除 `0..31` `equipSlotIndex` 探测及 `GetReinforceInfo/GetMaterialInfo` 调用；保留无需猜槽位的聚合 Getter（总强化等级、属性系合计、下一套装档位、套装状态、组合效果上限），逐槽位详情显示 Runtime Blocked。
- **Product Truth Gate**：Developer Foundation Audit 新增 locked Product Matrix fence，要求上述 3 条 Matrix 能力继续保持 `SPECIFIC_RUNTIME_BLOCKED`，并静态禁止 Active Runtime 重新引入 Hotkey 写链或 Reinforce guessed slot probe；Runtime Foundation Gate v108 同时校验 `HotkeyRuntimeBlocked` / `SlotProbeRuntimeBlocked` 标记。
- **Service 依赖方向收敛**：`GearServiceV3` 移除 `S.Features.Gear` 反向依赖和 Feature-owned DeepCopy；运行完成只发布 `v3.gear.updated`。Gear Feature 通过 Internal EventBus 自己处理 transient idle lifecycle。Foundation Audit 新增通用 `services/ -> S.Features` 反向依赖门禁。
- **BuildTag**：`v3-m1.16.0.18.116-product-truth-runtime-block-hardening`。

## 2026-09-05 — v3-m1.16.0.18.115-border-click-action-popup-hit-test-quiescence

夜间自主执行（P0 同类问题全工程扫描 + 加固）：

- **`.18.114` 同类扫描结论**：presentation/native/core 层全部事件绑定调用点逐一核验，未发现"Composite 被当 Native Widget 二次 RequireOn"同类真违规；Composite 内部无重复绑定；无 OnUpdate/Tick 键盘轮询；拖动/缩放仍唯一走 Native `StartMoving/StartSizing`。
- **Border Click Action Contract v1**（`BorderClickActionContractVersion=1`）：`RSUI:Border` 现在提供 `SetOnClick/GetOnClick/Click` Public Action（`pickable=true` 时在 factory 内部一次性 `RequireOn` 绑定，模式与 Button action v2 一致）。Modal Host 的 scrim 点击从直接 `RequireOn(scrim.root,"OnClick",...)` 改为走 `SetOnClick`，消除最后一处 Presentation 触碰 Composite 内部 native root 的事件绑定。
- **Popup Hit-Test Quiescence Contract v1**（`PopupHitTestQuiescenceContractVersion=1`）：Dropdown / ColorField popup 关闭时显式 `EnsurePickable(false)`（unpick），`Open()` 时先 re-pick 再显示；ContextMenu 同样 `Open` re-pick、`Close` unpick。隐藏 popup 不再只依赖 native"隐藏即不参与命中"的隐式语义，未来引擎行为变化也不会留下隐形拦截面。失败均 fail-closed 走既有降级事务。
- **静态门禁扩展**：`rs_rsui_component_api_audit.py` 新增 composite-internal bind 规则——presentation 层出现 `:RequireOn(` 即 FAIL（当前 0 处）；`Border` 公共面登记 `SetOnClick/GetOnClick/Click`。`rs_input_focus_drag_harness.py` 扩为 **72/72**：新增 border click action（6 项）+ popup re-pick/unpick（7 项）断言。
- **Diagnostics Snapshot 扩展（Dev Inspector 方向，只读）**：`D:Snapshot()` 补挂 `CombatRelationV3 / TeamRosterV3 / ScreenProjectionV3` 的既有 `GetHealth()` 输出（此前只有 UnitIdentity/CombatEventBus/Aura 等），为 RU 诊断提供 projection/roster/relation facts，无新系统、无写路径。
- **P1 审计结论（记录，不动代码）**：Bag Quick 与 Bag Batch 是 `rs_business_bridge.lua` 内两套高度重复的 move-transaction 状态机，为共享提炼候选；但属高危写路径（250ms 串行/live row 再验证），本轮不动，留待专项。Unit Relation / World Projection / Raid Grid / Rule Registry 均已有共享层且被正确复用，不新建。Healer 50ms health tick 在 200 人团的 native 调用量列为 RU 实测观察项。
- **BuildTag**：`v3-m1.16.0.18.115-border-click-action-popup-hit-test-quiescence`。

## 2026-09-04 — v3-m1.16.0.18.114-colorfield-event-rollback-input-quiescence

- 修复 `ColorField` 将嵌套 RSUI Button Component 作为 Native Widget 重绑 `OnClick`，导致 `required_component_event_bind_failed:*:done` 与页面事务回滚。
- ColorField 隐藏 Popup 移除预创建键盘 TextInput，HEX 改为只读显示，避免隐藏 EditBox 在 RU 客户端抢占游戏键盘。
- BuildScope v4 / BuildTransaction v2：Rollback 对半构建 Native 输入执行 `RetireInputWidget`，并统一关闭 Pick/Enable/Visible，防止失败页面残留输入/命中所有权。Foundation Gate v107，V3 Acceptance v65。

## 2026-09-04 — `.18.113` Persistence Integrity v2 + Serializer Recovery

- **按 RU 实机诊断修复而非清 Store**：用户 Fresh Runtime 报告 `v3.death_review / v3.healer / v3.launcher` 出现 `integrity_failed:fingerprint_mismatch`，同时 `fenced=4 / integrityFail=14 / writeBeforeLoadReject=41 / pageQ=4 / txFail=4 / startupDegraded=1`。调用链确认：旧 Integrity v1 用 Lua `%.17g` 精确二进制 number 表示做跨重载 business hash；包含窗口几何、透明度、缩放等非整数值的普通设置 Store 在 RU SaveData/LoadData 数值表示归一化后可能业务等价但 hash 不同，随后 write fence 又向页面构建与启动降级扩散。
- **Persistence Reliability v8 / Integrity v2**：新 save 的 encoded-business integrity 对整数继续精确（ID/计数/时间戳不降精度），仅对非整数使用 serializer-stable 6 significant digit token；`FingerprintPayload()` 仍保持原 exact Domain 语义，避免改变 Gear A/B journal 自己的业务 fingerprint contract。Critical readback 的 Domain proof 也改用同一 durable numeric fingerprint，避免 `SaveData=true` 后因表示漂移误报 readback mismatch。
- **有界 v1 升级桥**：v6/v7 的 Integrity v1 Store 继续读取。若 v1 普通设置 Store 的 metadata Envelope Seal 完整、encoded budget/metadata/schema 均通过，但旧 exact business fingerprint 发生 representation mismatch，则允许一次 compatibility load，随后必须继续通过 decode → Domain budget → migration/reset → final budget → apply，成功后才排队 `integrity_v2_upgrade` restamp。`verifyAfterSave` / `recoverableReplacement` Critical/Journal Store 不走该桥，仍 fail-closed。真实整数/结构损坏在 v2 继续触发 integrity fence。
- **验收指纹同步收口**：`RuntimeAcceptanceSnapshotContractVersion=2`，Fresh Reload 验收快照改用同一 serializer-stable durable fingerprint；Gear A/B 的 exact business fingerprint 仍不变，避免“Store 已正常兼容读取但人工验收 ALL fingerprint 因微小 float 表示差异又误报变化”。
- **启动 fallback 不再反向写物理 Store**：`v3.app / v3.shell / v3.launcher` 一旦进入 `sessionFallback`，本会话仍可改 UI 状态，但 `Set/MarkDirty` 不再触发 Persistence 写意图；因此 Shell 导航不会把一次保护性 load failure 放大成几十次 `STORE_WRITE_BEFORE_LOAD_REJECTED`。原 Store/fence/evidence 不被清除。
- **Build Transaction 不打业务特例**：`death_review/healer/...` 页面构建失败来自 `EnsureStoreLoaded()` 被 integrity fence 拒绝后的下游 transaction rollback；没有给页面绕过 Store Authority。新 generation 中 Store 通过 v8 compatibility/normal load 后，页面继续按原事务契约构建。
- **启动降级诊断补全**：`runtime_startup_degradation` 现在直接带首条 `stage:detail`（有界 180 字符）。如果 v8 清掉 Store 假 fence 后仍有 `degraded=true`，下一份复制诊断可直接定位真实默认 Feature，而不再只有 `warnings=1`。
- **门禁与故障注入**：Foundation Gate v106，新增 `persistence_reliability_v8`；新增 `rs_persistence_reliability_v8_harness.py`，真实 Lua 模拟 Native 非整数表示漂移，覆盖 v2 durable save/readback、v1 ordinary compatibility + v2 restamp、Critical v1 mismatch 继续 fence、整数真实损坏继续拒绝。Startup Fault Isolation 扩为 `17/17`，覆盖 App/Launcher/Shell fallback no-persist。
- **BuildTag**：`v3-m1.16.0.18.113-persistence-integrity-v2-serializer-recovery`。

## 2026-09-04 — `.18.112` Input Lifecycle + Drag Hit-Test Foundation

- **确认 `.18.111` 只是缓解，不是根因闭环**：继续沿 `Bootstrap → Runtime → RSUI Host → Primitive → Component → Windowing → Modal/Popup` 审计后，定位到同一类底层缺陷——Native Widget 的“可命中 / Focus / Keyboard / teardown”状态缺少统一生命周期 Authority。
- **主菜单拖动真实根因**：`rs_v3_shell.lua` 已声明 `topBar pickable=true`，但 `RSUI:Border` 下沉到 `UI:CreatePanel()` 时没有透传 `pickable/owner`，导致 Native title bar 实际 `EnablePick(false)`；后续即使绑定 `EnableDrag + DC_ALWAYS + OnDragStart` 也收不到鼠标。Border 现在显式透传交互参数；Generic WindowShell title bar 也显式 `pickable=true`；Windowing v18 自己在 Attach 时确认 drag handle `Enabled + Pickable` 后才建立 Native drag gesture，调用者遗漏不再静默形成死控件。该修复同时恢复 Modal Scrim 等依赖 `Border(pickable=true)` 的命中契约。
- **键盘真实根因**：所有 `CreateEditBox/CreateMultiEditBox` 都会启用 Focus/Keyboard，但过去隐藏、禁用、SetPickable(false)、Component/Owner Release 与 hot reload 没有统一释放当前 Suite focus。隐藏输入框因此可能在 RU 保留键盘所有权，表现为进入游戏后 WASD/技能/聊天键盘无响应。UI Framework v11 新增 tracked physical-focus lifecycle：只登记 Suite 自己的 keyboard input physical id；子树隐藏/禁用/失去 pick 时在 cache no-op 之前先检查并只清理该子树内已登记的 Suite focus；Release/old generation 永久 `EnableKeyboard(false)+EnableFocus(false)` 并注销。不会对无法证明属于 Suite 的游戏聊天框/其他原生输入执行 ClearFocus。
- **启动/热重载隔离**：Runtime Ready/Stop 做 generation-local keyboard quiescence；bootstrap 替换旧 generation 前永久退休旧输入对象。Recovery Command Bar 继续保持 `.18.111` 的默认 inert 语义，仅真实 Startup Failure 时临时启用。
- **性能边界**：无 Tick/OnUpdate/键盘轮询。Focus cleanup 只发生在 hide/disable/pick-loss/release/runtime boundary；先由 `rsUiKeyboardInputSubtreeCount` 快速拒绝无输入子树，祖先证明上限 32，且计数在 `UIParent` 根边界停止。Windowing 只在 Attach 时多做一次 Enabled/Pickable 确认。
- **门禁**：Native Interaction v5、UI Framework v11、Runtime v5、Windowing v18、WindowShell v23、Foundation Gate v105；新增 `InputFocusLifecycleContractVersion=1`、`HiddenInputFocusIsolationContractVersion=1`、`BorderInteractionForwardingContractVersion=1`、`DragSurfaceHitTestContractVersion=1`、`InputLifecycleBridgeContractVersion=1`、`inputQuiescenceContractVersion=1`。新增 `rs_input_focus_drag_harness.py`，当前 `48/48 PASS`，并静态禁止 Active Lua 引入未验证 generic `OnKeyDown/OnKeyUp/OnTextChanged/OnChar`。
- **BuildTag**：`v3-m1.16.0.18.112-input-lifecycle-hit-test-foundation`。

## 2026-09-04 — `.18.111` Keyboard Focus Isolation + Main Window Drag Recovery

- **修复进入游戏后键盘疑似被插件吞掉**：Recovery Command Bar 过去在 bootstrap 阶段先创建并 `EnableFocus(true) + EnableKeyboard(true)`，随后 Runtime Ready 再隐藏；RU 客户端存在隐藏 EditBox 仍保留键盘所有权的风险。现在恢复输入框创建时即 `EnableFocus(false) + EnableKeyboard(false)`，正常 bootstrap / hot-reload / Runtime Stop 全程保持 inert；只有真实 Startup Failure 显式调用恢复命令栏时才允许临时启用，隐藏时再次 ClearFocus + 禁用 Keyboard/Focus。
- **修复主菜单标题栏拖不动**：Windowing v17 把顶层窗口标题栏和 8 个 resize handle 统一到项目已验证的 `EnableDrag(true) + SetDragCondition(DC_ALWAYS)` 原生手势契约。RU 某些 WidgetBase 仅 EnableDrag 不会稳定产生 OnDragStart；现在不再依赖该不完整状态。R 启动入口拖动也同步补齐 DC_ALWAYS。
- **Authority 不变**：Native `StartMoving/StartSizing` 仍是鼠标捕获与实际几何移动 Authority；Windowing 只负责建立 gesture、结束 lease、提交一次持久化几何，不新增 Tick 或鼠标轮询。
- **门禁**：新增 `RecoveryInputIsolationContractVersion=1`、`Windowing.ExplicitDragConditionContractVersion=1`，Recovery Command 升 v2，Windowing Critical Interaction 升 v2；Foundation Gate 同步要求新契约。
- **回归**：Foundation Audit PASS；Recovery Command `26/26`、Recovery Launcher `15/15`、Runtime Entry `20/20`、Startup Fault Isolation `14/14`、RSUI Workspace `27/27`。
- **BuildTag**：`v3-m1.16.0.18.111-input-focus-drag-recovery`。

## 2026-09-04 — `.18.110` Recovery Reload / Persistence Save Decoupling

- **修复恢复死锁**：过去 `ReloadCodeFromDisk()` 把 `Persistence:Flush()` 当成硬门禁；任意 Store 保存/耐久验证失败都会直接取消重载，导致“配置保存代码本身出 Bug → 无法覆盖文件后重新加载修复”的闭环死锁。
- **恢复重载改为 best-effort durability**：仍只由 `ReloadCodeFromDisk()` 执行一次 Flush，成功时行为不变；失败时保留 `Persistence.lastFlush` 与 `LastReloadFlushFailure` 的 Store ID/原因，明确提示“未保存修改可能丢失”，随后继续触发经过验证的 `r_VSync` UI generation reload。故障 Store 保持自身 dirty/fence/retry evidence，不在重载前清空或伪造成功。
- **严格模式仍保留**：`ReloadCodeFromDisk(source, { requireDurable = true })` 可继续要求 Flush 全成功才放行，供需要强耐久语义的调用链使用；Runtime Stop 的独立 durability barrier 规则不变。
- **恢复入口一致性**：诊断页“重新加载文件”、R 右键与 `RS> reload` 继续共用同一 Reload Authority，因此主 UI、ESC 或 Persistence 任一局部故障都不能再把文件热修复入口锁死。
- **门禁/可观测性**：新增 `RecoveryReloadContractVersion=1`；Foundation Gate 升 v104，并把 recovery contract 纳入 `v3_reload_authority`。诊断页提示同步改为“保存失败仍继续加载新文件”。
- **BuildTag**：`v3-m1.16.0.18.110-recovery-reload-save-decoupling`。

## 2026-09-04 — `.18.108` Bootstrap Recovery Command Bar

- **命令式恢复入口，但不伪造 Slash API**：RU 当前允许的 Addon API 提供 `ReloadAddon` 等能力，但没有经过验证的“插件注册聊天 Slash 命令”接口；客户端脚本中 EditBox 的 `OnEnterPressed` 有明确使用证据。因此没有引入 WoW `SlashCmdList`、`X2Chat:GetChatCommands()` 或聊天轮询/劫持，而是在 Native Foundation 后立即安装独立 `RS>` Recovery Command Bar。
- **独立于主 Host / ESC / Feature Runtime**：Recovery Command Bar 与 R 分开安装。Runtime 未 Ready、Stop 或 Startup Failure 时显示；正常 Ready 后自动隐藏，避免长期占用输入焦点。即使主菜单/ESC/Feature 生命周期失败，只要 Native Window + EditBox 可用，玩家仍可在游戏内输入恢复命令。
- **命令 Authority**：`reload / rsreload / rs reload`（也接受前导 `/`）统一路由到既有 `ReloadCodeFromDisk("recovery_command")`，保持 Persistence Flush + 已验证 UI Refresh Authority，不在 EditBox 回调中调用 `ADDON:ReloadAddon()`；`diag` 输出 BootStage/R/CMD/BootError，`open` 只在 Runtime Ready 时打开主 Host，`help` 输出最小帮助。
- **Native 输入契约**：只绑定客户端脚本已验证的 `OnEnterPressed`；提交前先清空输入，避免双派发重入。Command Bar 固定 `174×30`，不使用 Tick/OnUpdate/聊天事件轮询。Foundation Gate 升 v103，新增 `bootstrap_recovery_command + recovery_command_contract`，复制诊断增加 `/CMD`。
- **防回归**：新增 `rs_recovery_command_harness.py`，覆盖命令归一化、reload Authority、Enter 提交、输入预清空、未知命令 fail-closed、Show(false) false-state 语义、Runtime show/hide 契约以及禁止 SlashCmdList/GetChatCommands/OnUpdate，`17/17 PASS`；Recovery Launcher `15/15`、Runtime Entry `20/20`、Startup Fault Isolation `14/14`、Interactive Draft `110/110`、Foundation Audit 继续 PASS。
- **BuildTag**：`v3-m1.16.0.18.108-bootstrap-recovery-command-bar`。

## 2026-09-04 — `.18.107` Startup Fault Isolation + Session-Safe Foundation Stores

- **继续自检而非立即要求 RU 重启测试**：在 `.18.106` Recovery Launcher 修复后，重新从 `R → Runtime:Start → App/Shell/Launcher Persistence → Feature defaults → Ready` 做多轮故障注入。确认现有 Recovery/ESC/Native boolean transaction 回归均为绿，但发现两个仍可把可选故障升级为整插件不可用的底层耦合：① `FeatureRuntime:EnableDefaults()` 任意一个默认 Feature（当前包括换装、活动、任务追踪）初始化/API/Store 失败时，Runtime 直接 `error()`；② `v3.app / v3.shell / v3.launcher` 读取异常会阻断主 Host 创建。两者都可表现为 `Ready=false + 只剩 R + ESC 无入口`。
- **Feature 启动故障隔离**：默认 Feature 仍保持各自 fail-closed/faulted 语义，但其失败不再阻断 Core Runtime。Runtime 记录 `startupDegraded/startupWarnings` 并发 Diagnostics `RUNTIME_STARTUP_DEGRADED`，继续进入主界面，让用户可从诊断/功能页查看或关闭故障模块。EventBus/Scheduler/Layout/Host 等 Foundation 失败仍保持 blocker，不把真正核心错误误降级。
- **启动关键 Store 会话降级**：`v3.app`、`v3.shell`、`v3.launcher` 在 Store 缺失、解析/完整性/读取失败时使用**本次会话安全默认值**继续启动，并记录 `sessionFallback + lastLoadError`/对应 Diagnostics。Persistence 自身原有 load-failure write fence 继续保护原物理存档，因此降级启动不会主动用默认值覆盖损坏/未验证数据；后续显式保存仍受 `CanWrite/MutateStore/MarkDirty` 原契约限制。
- **可观测性**：Runtime Describe/复制诊断增加 `startupWarningCount` 与“入口 … /降级N”；Foundation Gate 升 v102，新增 `runtime_startup_degradation` warning。新增 `rs_startup_fault_isolation_harness.py`，真实 Lua 故障注入覆盖 App/Launcher/Shell Store 失败仍有安全默认状态、默认 Feature 故障仍 `Ready=true` 且 BootError 为空，`14/14 PASS`。
- **完整自检**：Startup Fault Isolation `14/14`、Recovery Launcher `15/15`、Runtime Entry `20/20`、Interactive Draft `110/110`、Workspace `27/27`、Persistence Acceptance `19/19`、Persistence v3 `22/22`、v4 `35/35`、v5 `42/42`、v6/v7 PASS、Presentation API、RSUI Component API、Bag、Projection、Unit Lines、Foundation Audit 全部 PASS；TOC Lua Parse `210/210`。
- **BuildTag**：`v3-m1.16.0.18.107-startup-fault-isolation`。

## 2026-09-04 — `.18.106` Recovery Launcher Input + Compact Sizing Hotfix

- **RU 实机继续回归**：`.18.104/.18.105` 后用户仍反馈屏幕 `R` 左键打不开主菜单，且 `R` 变得明显过大。沿真实 bootstrap handler 与 launcher placement 调用链确认两个独立 Foundation 问题，而非业务页面故障。
- **R 点击被拖动抑制误吞**：旧 `OnDragStop` 无条件执行 `rsIgnoreClick=true`。RU 若对普通点击也发出 `OnDragStart/OnDragStop`，后续 `OnClick` 永远只清抑制标记，不进入 `UIHostManager:Toggle()`。现在 DragStart 记录起点，DragStop 只在几何位移超过 2 逻辑/有效像素时认定为真实拖动；零位移 drag 回调不再吞点击。真实拖动仍只抑制紧随其后的那一次 synthetic click。
- **零位移不再污染 Persistence**：只有确认发生真实位移才执行 screen snap / `StorePlacement` / `MarkLauncherStoreDirty`。普通点击即便触发 DragStop 也不写 `v3.launcher` Store，不产生无意义保存。
- **R 尺寸修复**：bootstrap launcher 固定为 `30×30` 逻辑单位，并显式 `SetAutoResize(false)` + `SetExtent/SetWidth/SetHeight`，避免 RU `text_default` 自动尺寸重新撑大。V3 LauncherStore 同样固定 30×30，不再把 Suite content scale 再乘一次到屏幕入口；客户端自身 UI scale 仍由 Native 负责。
- **防回归**：新增 `rs_recovery_launcher_harness.py`，真实 Lua 覆盖“零位移 Drag 回调后点击仍 Toggle”“真实拖动只抑制一次点击”“零位移不写 Store”“addonScale=4 时仍保持 30×30”，`15/15 PASS`。Foundation Gate 升 v101，新增 `recovery_launcher_input_contract`；Foundation Audit 增加拖动阈值、AutoResize、固定尺寸和禁止二次 Suite scale 的硬门禁。原 Runtime Entry `20/20`、Interactive `110/110`、Persistence v3-v7、Workspace、Bag、Projection、Unit Lines 全部继续通过，TOC Lua Parse `210/210`。
- **BuildTag**：`v3-m1.16.0.18.106-recovery-launcher-input-sizing-hotfix`。

## 2026-09-04 — `.18.105` Runtime Entry Lifecycle + ESC Registration Hardening

- **继续检查启动链而非停在 `.18.104` 单点修复**：静态 Foundation、Persistence v3-v7、Workspace、Projection 等既有回归均为绿后，继续沿 `R → Runtime Start → V3 Host → ESC bridge → Ready/Stop` 检查故障边界，确认两个真实底层漏洞：① `Runtime:Start()` 在 `esc_register` 阶段完全忽略 `RegisterEscMenu()` 的失败返回，导致 Runtime 可以宣称 `Ready=true` 但 ESC 中永久没有插件入口；② Runtime 启动失败后，bootstrap 的 `R` 左键与内部 Refresh 会调用 `RevealExistingSuiteShell()`，把已创建但 Events/Scheduler/Features 尚未完整启动的半初始化 V3 Host 暴露给用户，破坏 fail-closed 生命周期。
- **NativeEscBridge v2**：从无状态调用薄层升级为**generation-local 幂等注册 Proxy**，只记录当前 generation 的注册 transport 状态，不接管界面可见性 Authority。`RegisterContentWidget`、`RegisterContentTriggerFunc`、`AddEscMenuButton` 分阶段记录完成度；部分成功后重试只补缺失阶段，不重复注册已经成功的 content；同一 contentId 若尝试绑定另一 Native widget/按钮 identity 直接拒绝。完整注册再次调用零 Native 写，提供 `IsContentRegistered/IsButtonRegistered/IsReady/Describe` 诊断。
- **Runtime v4 入口健康状态**：记录 `escRegistered / escRegistrationAttempts / escRetryScheduled / lastEscError`。首次 ESC 注册失败**不阻断整个插件**（早期 `R` 仍是安全主入口），但会进入 Diagnostics，并在 Runtime 真正 `Ready` 后仅通过共享 Scheduler 安排一次 750ms bounded one-shot 重试；不新增 Tick、轮询或第二调度器。若仍失败，后续用户主动点击 `R` 时可再做一次低频机会性注册，但无论 ESC 是否恢复都不阻塞主窗口 Toggle。
- **半初始化 Host fail-closed**：删除 bootstrap `RevealExistingSuiteShell()`。`Ready ~= true` 时，R 左键和内部刷新只报告 `BootStage/BootError`，绝不打开已经创建但生命周期未完成的 Host；右键显式代码刷新/恢复路径保持原安全边界。继续检查 R 自身又发现同类返回值漏洞：`rs_native_recovery.lua` 过去只看 `pcall` 是否抛异常，`InstallBootstrapRecoveryEntry()` 业务返回 `false`（例如左键 handler 被客户端拒绝）会被静默当成功。现已同时检查 transport + logical result，并维护 `RecoveryEntryHealthy/RecoveryEntryError`；恢复入口 `Show(true)` 也改走确认式 Native 调用。恢复入口失效会进入诊断但**不会设置 BootError 阻断完整 Runtime**，避免 ESC 原本可用时反而把插件整体封死。
- **可观测性与 Gate**：Foundation Gate 升 v100，新增 `native_esc_bridge_contract`、`runtime_entry_lifecycle_contract`、`native_esc_menu_runtime` 与 `bootstrap_recovery_entry`；复制诊断新增 `入口 Ready/Runtime/R/ESC/尝试/重试`，以后 R 或 ESC 单边失效不再被“框架正常”掩盖。Foundation Audit 加入幂等注册、有限重试、Recovery logical-false 与“不得暴露 partial shell”硬门禁。新增 `rs_runtime_entry_lifecycle_harness.py`，真实 Lua 覆盖 content 部分失败→补偿重试、按钮双 ABI 首次失败→重试恢复、完成后幂等零 Native 调用、同 generation identity 冲突拒绝，以及 Recovery installer `false` 必须可见但不得 poison Runtime，`20/20`。
- **BuildTag**：`v3-m1.16.0.18.105-runtime-entry-lifecycle-hardening`。RU 下一步仍需 Fresh Reload，重点观察复制诊断中 `Readytrue/Runtimetrue/Rtrue/ESCtrue`；若 ESC 首次瞬态失败，应看到尝试数增加后恢复而不是 Runtime 假绿。

## 2026-09-04 — `.18.104` RU Native Boolean Setter Return + V3 Startup Hotfix

- **RU 实机 P0 启动回归**：用户 Fresh Reload 后只剩早期恢复入口 `R`，点击无法打开主界面，同时 ESC 插件面板项消失。沿 `toc.g → bootstrap recovery → UIHostManager → V3 NativeAdapter → Runtime Ready → ESC register` 实际调用链确认：`R` 在完整 Runtime 之前创建，而 ESC 注册只发生在 V3 Host 成功建立之后，因此该组合症状指向 Host 创建阶段 fail-closed，而不是单独的 R/ESC 页面问题。
- **根因**：`.18.103` 为状态事务增加 Native 返回值检查时，把 `result == false` 一律解释成“Native 拒绝”。RU Widget setter 没有可依赖的统一 success-return 契约，布尔 Setter 可能返回**应用后的状态值**。主 V3 root 初始化恰好调用 `EnablePick(false) / Clickable(false) / Show(false) / SetCloseOnEscape(false) / SetWindowModal(false)`；合法的 false-state return 因此被误判为失败，Root 被隔离，Runtime 无法进入 `Ready=true`，最终只留下早期 `R`。
- **底层修复，不下沉页面**：UI Framework v10 新增 `NativeBooleanSetterReturnContractVersion=1`。Native 布尔 Setter 仅在“请求 false 且返回 false”时把该返回视为**状态值而非拒绝**；请求 true 仍显式返回 false 时继续 fail-closed。`rsUiSetEnabledAdapter` 属于 Lua Composite 事务回调，其 `false` 继续保持明确 veto 语义，不与 Native return 混淆。Primitive Native helper 同样只对白名单 boolean state setter 的 false-state 调用放宽，`StartMoving` 等 Action 方法返回 false 仍是失败。
- **V3 Root policy 修复**：NativeAdapter Root Interaction Policy 升 v2。`SetCloseOnEscape(false)` / `SetWindowModal(false)` 允许 false-state return；`SetUILayer("system")` 等非布尔 policy 若显式 false 仍拒绝 Root，保留 `.18.103` 的事务/fail-closed 强度。
- **防回归**：Interactive Draft Harness 增加真实 Lua 启动形态：模拟 RU Setter “返回所应用的 bool”，验证隐藏/禁用命中、Composite false veto 以及完整 V3 root 创建，升为 `110/110`；Foundation Gate 升 v99 并要求 Native boolean setter contract/Interaction v4/Root Policy v2，Foundation Audit 同步增加 boolean setter return fence 与 NativeAdapter policy v2 检查。最终本地验证：TOC Runtime Lua `210/210` Parse、Foundation Audit、RSUI Component API、Presentation Feature API、Workspace Smoke、Persistence v3-v7/Acceptance、Bag Queue、Screen Projection、Unit Line Sampling 全部 PASS；RU 客户端下一 Gate 为 Fresh Reload 后确认主界面和 ESC 项恢复。
- **BuildTag**：`v3-m1.16.0.18.104-native-bool-setter-startup-hotfix`。

## 2026-09-04 — `.18.103` RSUI State Transaction + Full Feature Interaction Hardening

- **从“可绘制”继续收敛到“状态真实成立”**：在 `.18.102` Native Interaction ABI 修复后继续扫描 Active V3 页面、悬浮窗与共享 Composite，确认另一类共同根因：Native Show/Hide、Enable/Pick、Alpha、UseResizing、Popup/Window 状态改变失败时，部分 Lua Authority 仍可能先发布 `visible/open/locked/minimized/opacity`，导致诊断与屏幕真实状态分叉。本轮把这些低频状态迁移统一改为事务式——先确认 Native/Composite 成功，再发布逻辑状态；失败则回滚或 fail-closed。
- **UI State / Geometry Transaction Facade**：新增 `UI:EnsureAlpha()`，并补齐 `EnsureAnchor/EnsureExtent`，与既有 `EnsureVisible/EnsureEnabled/EnsurePickable` 统一区分 changed/no-op/rejected。Windowing v16 新增 `StateMutationTransactionContractVersion=1 + GeometryCallbackTransactionContractVersion=1`，`SetLocked/SetResizeEnabled/SetOpacity`、resize handle 的 Geometry/Visible/Enabled/Pickable 以及 geometry commit callback 都必须真实成功；callback 明确拒绝会中止 Commit，不再把失败的 Domain/Persistence 投影当成窗口提交成功。
- **WindowShell / FloatingSurface**：WindowShell v22 增加 `visibilityTransactionContract=1 + stateMutationTransactionContract=1 + stateCallbackTransactionContract=1`；Show/Hide、Minimize、Lock、Overall/Background/Text opacity、FontScale、Appearance drawer、geometry callback 都改为 Native/Layout/业务 State callback 全部成功后才完成提交。FloatingSurface v10 的 Feature-owned state 写入统一经 `CommitState`；Persistence/Domain callback 失败会反向回滚 Shell Native 状态，修复此前 WindowShell `NotifyState()` 用 `pcall` 吞掉 `false` 的最后一处事务断点。
- **Popup/Modal/Context 统一**：Dropdown、ColorField、Tooltip fallback、ContextMenu 与 ModalHost 都使用事务式 popup visibility；`open=true` 只在 popup 真正显示后发布，关闭失败不会提前清空逻辑状态。Dropdown/ColorField 子控件半构建继续 fail-closed，Modal Push/Pop 只有在目标/宿主显隐事务全部完成后才提交 stack。
- **Presentation Visible 状态修复**：Activities、Tasks、Life Economy、Buff Display、Death Review、DPS、Quest Detail 的 Floating Widget 不再在 `surface:Show/Close` 成功前修改 `self.visible`；Hide 先确认视觉关闭，再释放订阅/Consumer，避免窗口实际没关但 Host 已认为关闭。
- **编辑器/滚动交互安全**：SelectionOverlay 与 Layout Debug 的可见状态改为事务式；Scrollbar 的 track/thumb/dragProxy 显隐改为确认式，隐藏时同时关闭真实 dragProxy 的 Enable/Pick，防止透明/残留命中面继续拦截鼠标。Window resize handles 同样同步 Visible/Enabled/Pickable。
- **Binding/Persistence/Action/Composite 累计收敛**：本交付同时包含上一轮尚未正式交付的 Button 单一 Native OnClick Authority、动态 Action Contract、Persistent Binding 创建 fail-closed、Read-Before-Render、写入失败回滚、ColorField 嵌套事务、WidgetHost 偏好 Load-before-show、DataView/Scrollbar/SplitView/LayoutEditor 关键事件 fail-closed 等修改。没有新增 Tick 或常驻轮询。
- **防回归门禁**：Foundation Gate 升 v98；Foundation Audit 增加 Popup/Interaction/WindowShell/FloatingSurface/ModalHost/Windowing state/geometry transaction 静态契约，并检查 Application Shell 几何回滚与 NativeAdapter 初始显隐/几何事务；Interactive Draft Harness 扩展为 104/104。最终本地回归包含 210/210 texluac Parse、Foundation Audit、RSUI Component API、Presentation Feature API、Workspace Smoke、Persistence v3-v7、Acceptance Snapshot、Bag Queue、Screen Projection、Unit Line Sampling。
- **BuildTag**：`v3-m1.16.0.18.103-rsui-state-transaction-hardening`。RU 客户端仍需 Fresh Reload 执行真实鼠标/窗口/存档矩阵；`SPECIFIC_RUNTIME_BLOCKED` 能力保持证据门禁，不因静态修复擅自解除。

## 2026-09-04 — `.18.102` RSUI Native Interaction ABI + Fail-Closed Hardening

- **系统性底层审计**：在 `.18.101` Gear TextInput 实机问题之后继续扫描全部 Active Lua，确认“诊断全绿”仍漏掉一类 Native Interaction ABI 回归：多个 Slider/Scrollbar/Table 列宽拖动/SplitView Divider/Runtime Host 使用 `EnablePick(value, true)` / `Clickable(value, true)`，而项目本地 RU API Authority 明确为单参数 `EnablePick(enable)` / `Clickable(clickable)`。这些调用位于 `pcall` 内时，严格 Native binding 可以静默拒绝，最终表现为“控件画出来但点不动/拖不动”。本轮统一收敛为已验证的一参数 ABI，并把 UI 层命中状态写入 `UI:SetPickable` Diff Authority。
- **Edit 原语完整交互契约**：`CreateMultiEditBox()` 与单行 EditBox 对齐，显式开启 `Enable / EnableFocus / EnableKeyboard / EnablePick / Clickable` 并 `SetReadOnly(false)`；Multiline 不调用 RU 参考中未确认的 `SetReClickable`。所有 TextInput/NumericInput/多行编辑 Consumer 继承同一 Native Interaction Contract v2。
- **Composite Enabled 修复**：自定义横向 Slider 的真实命中面是透明 drag child。旧 `UI:SetEnabled()` 优先调用 Native root `Enable()`，会绕过 Slider 自定义 `SetEnabled()`，造成“视觉禁用但拖动层仍可交互”。新增显式 `rsUiSetEnabledAdapter`，禁用时同步停止当前拖动、释放临时 OnUpdate/Scheduler、关闭 drag child 的 Enable/Pick，恢复未提交 Preview；无常驻 Tick。
- **Primitive/Build fail-closed**：Native primitive 初始化 pcall 失败后仍会注册物理 identity 以避免同 Generation 重用，但不再把 degraded widget 作为可用控件返回；`RSUI:Create()` 再增加 native root usability fence，custom factory 若返回 degraded/rejected/stale root 会在 attachment 前以 `component_root_unusable` 失败并进入 strict BuildScope rollback，避免“页面构建成功但关键控件死亡”的假绿状态。
- **事件绑定与错误可观测性**：Slider 的 OnDragStart/OnDragStop 现在属于必需构造能力，绑定失败直接让 Primitive fail-closed；所有 primitive pcall 失败保留有界 Native 错误文本，不再只有泛化 `configuration_failed`。同时修复 `WarnOnce` 的 dot/colon 调用 ABI 错误；RSUI event mux 首次 SetHandler 失败时会移除无法 dispatch 的订阅，后续重试成功不会把失败订阅一起执行造成重复动作。
- **Diff cache 修复**：`UI:SetPickable()` 在 Native widget 完全没有 `EnablePick/Clickable` 能力时不再提前缓存成功值，防止后续真实 adapter/method 出现后被错误 cache-hit 跳过。
- **防回归门禁**：Foundation Gate 升 v93，新增 `v3_native_interaction_contract`；Foundation Audit 新增 RU hit-test 方法参数个数扫描、NativeSafe 多参数扫描、Edit/Slider/degraded-root contract coherence；Interactive Draft Harness 扩展为 42/42，并加入真实 Lua 行为用例验证 composite disable、unsupported pickable cache、degraded root 拒绝与 handler 首次绑定失败后的无重复恢复。
- **BuildTag**：`v3-m1.16.0.18.102-rsui-native-interaction-hardening`。

## 2026-09-04 — RU Gear TextInput Mouse Focus Hotfix

- **RU 实机反馈**：换装/称号页面的“新建方案”和“改名”输入框可以正常绘制，但鼠标点击后无法进入编辑状态。该问题对应 `.18.57` WU1 当时明确标记为“Gear TextInput 交互仍待 RU 实机验证”的未验收项。
- **根因**：共享 `UIX:CreateEditBox()` 只调用 `EnableFocus(true)`，没有像 Button 原语一样显式开启 `EnablePick(true)` / `Clickable(true)`；同时没有应用 `ui_functions.lua` 已确认的 Edit 专用 `SetReClickable(true)`。RU `CreateChildWidgetByType` 创建出的 EditBox 因而可能处于“可绘制、不可鼠标命中”的状态。
- **共享底层修复**：单行 EditBox 在 Native Primitive 边界统一启用 `Enable / EnableFocus / EnableKeyboard / EnablePick / Clickable / SetReClickable`，并显式 `SetReadOnly(false)`；Native state cache 同步标记 `enabled=true / pickable=true`。不在 Gear 页面维护第二套点击/Focus 特例。所有 `RSUI:TextInput` 与 `RSUI:NumericInput` 自动继承该修复。
- **性能/输入边界**：0 Tick / 0 轮询 / 0 新 Scheduler；没有引入未验证的 `OnTextChanged / OnKeyDown / OnKeyUp`。仍由原生 EditBox 负责鼠标命中与 Focus，提交继续只走已验证的 Enter/EditEnter/LostFocus。
- **防回归**：`rs_interactive_draft_harness.py` 由 13/13 扩展为 17/17，增加 EditBox pickable/clickable/re-clickable + native-state contract。
- **BuildTag**：`v3-m1.16.0.18.101-rsui-editbox-interaction`。

## 2026-09-04 — `.18.100` Persistence Reliability v7 Generation Reload Fence + Deferred Dirty Commit

- **继续沿保存调用链审计**：确认 v6 仍有三个底层失效窗口：普通 Store `SaveData=true` 后会进入 `needsBarrierVerify`，但在显式 Flush/Reload barrier 前若业务再次直接 `LoadStore()`，旧物理值仍可能覆盖当前较新的健康 Domain；migration/period reset 在最终 Apply 成功前就留下 dirty intent，若 Apply 失败可形成“terminal/write-fenced + dirty”的矛盾状态；Tick 对这类 dirty terminal Store 仍可能周期性重复进入 SaveStore。
- **Generation Reload Fence**：Reliability Contract 升 v7。Persistent Store 只要 `needsBarrierVerify=true`，普通 `LoadStore()` 一律 fail-closed 为 `unverified store reload rejected`，并记录 `STORE_UNVERIFIED_RELOAD_REJECTED`；只有明确的 destructive recovery 才可使用 `discardUnverified=true`。这保证本 generation 内已经写过但尚未完成 durability proof 的新 Domain 不会被潜在旧磁盘值重新 Apply。
- **Deferred Dirty Commit**：schema migration 与 Daily/Weekly load-time reset 不再在 business transform 阶段提前 MarkDirty；只有最终 Domain budget 通过且 `ApplyValue(...,"load")` 成功后才提交 dirty metadata，并记录 `deferredLoadResaves`。Apply 失败保持 terminal/write-fenced，但不会留下自动保存义务。
- **Terminal Auto-Retry Suppression**：Persistence Tick 只对 healthy-ready 且未 write-fenced 的 dirty Store执行原有 debounce SaveStore。terminal/fenced Store 保留 dirty evidence 供诊断/显式 Flush 处理，但 cadence 只把 `dueAt` 有界后移并增加 `terminalAutoRetrySuppressions`，避免失败 Store 每个保存周期持续打 Native SaveData/日志。无新增 Tick、Scheduler 或额外 Native 读取。
- **门禁/回归**：UIV3 Acceptance v64；Foundation Gate v92 新增 `persistence_reliability_v7`，正常路径要求 `unverifiedReloadRejects=0`。新增真实 Lua `rs_persistence_reliability_v7_harness.py`，覆盖 pending durability write 的 LoadStore 拒绝/Domain 保持、Flush 后正常 reload、migration Apply failure 不遗留 dirty、write-fenced dirty Tick 不重复 Native Save，以及 Contract v7 描述。v3/v4/v5/v6 harness 继续通过。
- **BuildTag**：`v3-m1.16.0.18.100-persistence-v7-generation-reload-fence`。由于 `.18.99` 未单独形成用户可下载包，本轮交付包相对 `.18.98` 累计包含 v6 + v7 必需修改；NEXT 为 RU Fresh Reload/完整退出重进，任何 `unverifiedReloadRejects>0` 都视为调用链错误证据而不是正常用户路径。

## 2026-09-04 — `.18.99` Persistence Reliability v6 Envelope Seal + Durable Commit + Character Scope Binding

- **继续沿保存底层而非 Gear 单点补丁审计**：确认 v5 仍有四个机械缺口：`durable=true` 的 `MutateStore()` 实际没有强制 immediate readback；v4/v5 `encodedFingerprint` 故意排除 `__rsmeta`，因此 schema/owner/scope 等 metadata-only 截断无法被业务指纹覆盖；custom decoder/migration 可把小型 encoded payload 膨胀为超预算 Domain 后再 Apply；Character Store 的 world-qualified identity 每次 Save 都重新解析，缺少“已加载 Domain 属于哪个角色”的强绑定。
- **Reliability v6 Envelope Seal**：新写入继续保留 Integrity v1 business fingerprint，并新增 `envelopeIntegrityVersion=1/envelopeFingerprint`。Envelope Seal 覆盖 framework/store/owner/contract/lifetime/scope/schema/period/reliability/integrity/business fingerprint/scope identity；v6 load/readback 在任何 business decoder 前先验证 seal。v4/v5 stamped save 保持向前兼容。
- **Decoded Domain Budget**：custom decode 后、migration/period transform 后分别按 Store Domain budget 检查；膨胀/循环/非法形状进入 `decoded_load_rejected`，绝不 Apply。Gear recoverable inactive bank 允许在 verified full-replacement 条件下修复该类确认损坏。
- **Durable Commit 语义修正**：`MutateStore(...,{durable=true})` 现在必定传递 `durable + verifyAfterSave`；SaveData 后同 key readback 未通过则事务回滚 Domain，并保留 durability barrier obligation。新增 `durableVerifyAttempts/Failures`。
- **Character Scope Binding**：Character Store 保存 v6 exact world-qualified identity fingerprint；loaded Domain 绑定 `resolvedKey + resolvedScopeFingerprint`。当前角色变化后 `IsStoreLoaded` fail-closed，`PrepareWrite` 仅在旧 scope 无 dirty/barrier obligation 时先 Load 当前角色再允许 mutation；debounce/Flush 对旧 dirty Domain 使用 bound old key，禁止跨角色误写。历史物理 key 算法暂不变以避免升级丢档；若两个 exact identity 因历史 lossy normalization 落到同一 key，v6 identity mismatch 直接 fence，绝不覆盖。
- **门禁/回归**：UIV3 Acceptance v63；Foundation 新增 `persistence_reliability_v6`。新增真实 Lua `rs_persistence_reliability_v6_harness.py`，覆盖 metadata-only truncation pre-decode rejection、decoded expansion budget、durable immediate verify/rollback、v5 compatibility、A/B Character scope rebind 与 lossy-key collision fence。v3/v4/v5 harness 继续兼容 v6。
- **BuildTag**：`v3-m1.16.0.18.99-persistence-v6-envelope-scope-durable`。NEXT 仍是 RU Fresh Reload/完整退出重进，新增健康要求：`envelopeIntegrityLoadFailures=0 / decodedLoadRejects=0 / durableVerifyFailures=0 / scopeBindingMismatches=0`。

## 2026-09-04 — `.18.98` Persistence Reliability v5 Durability Barrier + Verified Clear

- **继续审计保存底层**：确认 `.18.97` 仍有三个真实机械缺口：普通 Store 在本进程较早时 SaveData 成功后会变 clean，随后用户点 Reload 时旧 `Flush()` 只处理 dirty，因此不会再证明这个已写 key 的物理内容完整；v4 integrity check 的源码顺序实际仍在 custom decoder 之后，损坏表可先进入业务 decode；`ClearStore()` 只信 `ClearData=true`，若物理清理未生效会出现“本进程像是重置成功、Reload 后旧配置复活”。
- **Reliability v5 durability barrier**：普通 Store 继续保持低开销 `SaveData ×1`，成功后仅记 runtime-only `needsBarrierVerify=true`。显式 Reload/Runtime Stop 的 `Flush()` 现在分两阶段：先保存 dirty，再对本 generation 已触碰但尚未证明耐久的 key 做一次 `LoadData + metadata/integrity/decode/Domain fingerprint` 验证。任何 mismatch 都让 Flush 返回失败并阻止用户主动 Reload；Store 保持/重新进入 dirty，以当前健康 Domain 做 5s bounded retry，不把瞬时 read visibility 问题升级成永久 write fence。Critical `verifyAfterSave` Store 已即时回读成功时不会被 Flush 二次读取。
- **跨版本 integrity 兼容**：`ReliabilityContractVersion=5`，但 Integrity v1 的读取兼容下限固定为 v4；`.18.97` 已写入的 v4 fingerprint save 在 v5 下继续可读。future reliability contract 仍 fail-closed。encoded fingerprint 校验正式前移到任何 custom decoder/migrate/apply 之前。
- **Verified Clear**：`ClearData=true` 后必须立即 `LoadData(key)==nil` 才允许把默认值 Apply 到 Domain；fake-success/non-empty 或 read error 进入 `clear_verify_failed`，保留当前 Domain 并 write-fence，避免设置“暂时消失、重载复活”。
- **健康状态统一**：Persistence Core 的 `CanWrite/PrepareWrite/SaveStore/MarkDirty/period reset/Describe/RuntimeAcceptanceSnapshot` 与 Persistent UI Binding 统一消费健康 `IsStoreLoaded()` 语义；terminal failure 不再被 UI/通用写路径当成 ready。新增 `barrierVerify* / clearVerify* / barrierPending` 诊断。
- **门禁/回归**：Foundation Gate v91 / UIV3 Acceptance v62；新增 `rs_persistence_reliability_v5_harness.py`，覆盖 v4→v5 兼容、integrity-before-decode、普通 Store barrier 检出静默截断→requeue→恢复、Critical Store 无重复 readback、ClearData fake-success fail-closed。v3 22/22、v4 35/35、Snapshot 19/19 继续通过。
- **BuildTag**：`v3-m1.16.0.18.98-persistence-v5-durability-barrier`。NEXT 仍是 RU Fresh Reload/完整退出重进，但验收口径升级为 v5：重载前 `barrierPending` 可非 0，真正触发重载时必须 barrier 全部通过；`barrierVerifyFailures/clearVerifyFailures/integrityLoadFailures/readbackVerifyFailures=0`。

## 2026-09-04 — `.18.97` Persistence Reliability v4 Cross-Reload Integrity + Gear Journal Self-Heal

- **继续追查保存底层，不只盯 Gear UI**：审计发现 `.18.95` 的 immediate readback 只能证明“刚写完马上读”一致，无法证明下一次 Reload/完整重启后仍完整；另外 `IsStoreLoaded()` 把 `decode_failed/metadata_mismatch/future_schema` 等终态也暴露成“已加载”，Feature 可能把空缓存当成健康 Domain；Gear A/B active bank 损坏后虽然能回退 backup，但被 Persistence write-fence 的损坏 inactive bank 会阻止下一次 A/B 自愈写回。
- **Persistence Reliability v4**：所有新持久化写入在 `__rsmeta` 增加 `reliabilityContract=4 / integrityVersion=1 / encodedFingerprint`。Fingerprint 对**编码后的业务 envelope（排除 `__rsmeta`）**计算，而不是对当前 decoder 产物计算，因此既能检测跨 Reload 字段截断，又不会因未来合法 decoder/schema migration 变化产生假损坏。普通 Store 不增加 readback I/O；Critical Store 仍保留 v3 的 immediate decode-only readback。
- **Load 边界前置完整性**：`LoadStore()` 先按 `encodedBudget` 检查磁盘 envelope，再校验 v4 encoded fingerprint，全部通过后才进入业务 decode/migrate/apply。损坏表进入 `encoded_load_rejected` 或 `integrity_failed` 并 write-fence；pre-v4 未带 reliability marker 的历史存档继续可读，下一次正常保存自然升级。
- **健康 loaded 语义修复**：`IsStoreLoaded()` 现在只对 `loaded/empty/saved/session` 返回 true；“LoadData 已结束但失败”的内部 terminal state 不再伪装成业务可用状态。该修复直接封住 Gear Payload failed-load 后复用空 cache 的路径。
- **Gear A/B 自愈补链**：A/B bank 注册为 `recoverableReplacement`。只有 `decode_failed / metadata_mismatch / integrity_failed / encoded_load_rejected` 这类已确认损坏的**完整 journal shard**，且单次写入显式 `replaceCorrupt=true + verifyAfterSave=true` 时，才允许覆盖 fenced inactive bank；必须 SaveData + readback 全通过后才清 fence。`future_schema` 与瞬时 `load_failed` 永远不能用此路径覆盖。
- **诊断/门禁**：Foundation Gate v90 / UIV3 Acceptance v61 新增 Reliability v4 + Integrity v1 contract；统计 `integrityStampedSaves / integrityLoadChecks / integrityLoadFailures / integrityLegacyLoads / encodedLoadRejects / verifiedReplacementRecoveries`。新增真实 Lua 故障注入 `PERSISTENCE_RELIABILITY_V4_HARNESS PASS 35/35`，覆盖 later-process truncation、legacy unstamped、malformed envelope、failed-load healthy semantics 与 verified replacement recovery；v3 22/22 和 Snapshot 19/19 继续通过。
- **BuildTag**：`v3-m1.16.0.18.97-persistence-v4-cross-reload-integrity`。NEXT 仍为 RU Fresh Reload；现在首要观察 v4 `integrityLoadChecks` 是否随 Reload 增长且 `integrityLoadFailures/encodedLoadRejects/readbackVerifyFailures=0`。

## 2026-09-04 — `.18.96` Unit Lines Coordinate Consistency + Team Auto-Role Ranged Hotfix

- **RU 实机反馈（P0 回归）**：`.18.88` 已能剔除相机背后的镜像端点，但用户在真实战斗截图中继续确认前方单位连线仍会指向明显不属于单位的位置。重新沿 `UnitLines → ScreenProjectionV3 → X2Unit` 检查后确认两个薄弱点：① batch 对 `player` 单独传 `isLocal=true`、其它 token 传 `false`，Camera Frame 却只在一个世界空间内计算，存在混合空间端点；② `GetUnitScreenPosition` 的坐标即使实际处于 physical/UI-scale 空间，只要数值仍落在 logical viewport 内，旧阈值归一化就会把它误判为合法 logical 坐标。
- **ScreenProjectionV3 v5**：Unit Line batch 统一用 `GetUnitWorldPositionByTarget(token, false)` 获取同一全局空间坐标；在既有一次 Camera Frame + world read 上增加 bounded Native/Camera consistency gate。Native 点先与 camera-world logical 点比较；UI scale 候选明显更接近时使用 `native_scale_reconciled`，仍超出容差则使用 `camera_consistency_fallback`。behind-camera 仍在 Native screen read 前拒绝；不增加第二次 world/camera 查询，也不改变 Healer/Buff Display 的普通 `ProjectUnit()` 行为。新增 `nativeScaleReconciles/nativeConsistencyFallbacks` 诊断。
- **Unit Lines 契约**：`combat_unit_lines` 仅在 `ProjectUnitBatch` 调用上启用 `validateNativeAgainstCamera + reconcileNativeScale`，保持 Feature Demand/P1 cadence、`.18.87` adaptive sampling、viewport clipping 与 Presenter diff 不变。新增 `ProjectionConsistencyContractVersion=1`。
- **团队自动职责修复**：静态职责目录升 v2。`name_6_8_9`（用户报告的 吟游+暗杀+野性）从普通 `dealer` 更正为 `ranged`；同时把目录中所有明确 `classType="Archer"` 的 7 个精确职业组合统一映射到 `TMROLE_RANGED_DEALER`，Gunner 原有 ranged 规则不变。没有按“只要含野性就远程”做模糊推断，Songer/Tank 等既有精确组合不受影响。
- **防回归**：Foundation Gate v89 / UIV3 Acceptance v60 要求 ScreenProjectionV3 v5 consistency contract 与 TeamAutoRoleCatalog v2；Foundation Audit 禁止 `Archer → dealer` 回归，并锁定 Unit Lines 的 consistency options。`SCREEN_PROJECTION_FRONT_HEMISPHERE_HARNESS PASS 14/14`（新增 same-world、UI-scale reconciliation、valid-but-stale in-bounds fallback）；Team catalog 本地检查 7/7 Archer 全部 ranged。
- **BuildTag**：`v3-m1.16.0.18.96-unit-lines-projection-team-role-hotfix`。RU Fresh Reload 仍是下一 Gate；本轮是用户实机 blocker 修复，不提前开启新的业务 UI 迁移。

## 2026-09-04 — `.18.95` Persistence Reliability v3 + Gear A/B Payload Journal

- **真实 RU 回归提升为 P0**：用户确认换装方案名称在 Reload 后仍存在，但方案内部装备数据无法继续换装。代码核查确认 Gear 本来就是“轻量 Index + 独立 Payload shard”双层保存：名称/顺序保存在 `v3.gear.index`，19 槽装备身份与称号保存在 `v3.gear.payload.N`。旧路径只信任 `SaveData=true`，没有回读证明，因此“Index 还在、Payload 已截断/损坏”能够形成用户看到的精确症状。RU 客户端是否就是 SaveData 静默截断仍需 Fresh Reload 证据，但该失效模式现在被底层明确封死。
- **Persistence Reliability Contract v3**：新增 opt-in `verifyAfterSave` / `VerifyPersistedValue()`。Critical Store 在 `SaveData` 返回成功后立即以同一 resolved key `LoadData`，只做 metadata + decode + Domain fingerprint 校验，**不调用 `store.apply()`**，因此不会形成第二 Domain Authority。回读缺失、schema/meta 不匹配或内容指纹不同都记为 `readback_verify_failed`，本次写入不计为可靠 commit；普通 Store 默认不启用，避免所有设置双倍 I/O。
- **Gear Payload Journal**：Gear Index 升 schema 5，Payload 升 schema 2。每个方案新增 A/B 两个 payload bank；保存时只写当前 active bank 的另一侧，写入成功且回读验证通过后才更新 Index 指针/指纹。Index commit 失败时不再把旧 payload 覆盖回去，旧 Index 仍指向上一份已验证 payload；active bank 异常时可按 Index 保存的 backup bank + fingerprint 回退。Gear Index 自身也启用 readback verification。
- **Compact Payload**：新 payload 使用短键编码，并从固定的 19 槽 `GearV3.EquipmentSlots` 重新构造 slotName/key/alternative，避免每个装备重复保存静态字段，显著降低 SaveData 节点/字符串压力。旧 schema 1 单 bank key 永久保留只读兼容；读取正常旧 payload 后，下一次用户保存自然迁移到 A/B，不做破坏性批量迁移。
- **损坏分片 fail-closed + 可重建**：configured payload 若只剩空壳、managed 装备缺 slot/name、或启用称号却缺 effect id，会直接标记为分片不可用，不再把残缺数据交给 Apply/Validate。已经在旧版本中丢失的真实装备明细无法由方案名称反推；用户可选中该方案，执行一次“获取当前”再“保存方案”，显式按当前穿戴重建并进入 A/B journal。Start/Validate 永远不会自动覆盖历史方案。
- **诊断/测试**：Foundation `persistence_reliability_v3` 追加 `verify success/attempt/fail`；readback failure 进入 incident warning。UIV3 Acceptance 升 v59 并声明 `PersistenceReliabilityV3ContractVersion=1`。新增 `rs_persistence_reliability_v3_harness.py`，真实 Lua 故障注入覆盖成功回读、`SaveData=true` 但 payload 静默缺字段、decode-only 不 Apply、普通 Store 不增加 readback，`22/22 PASS`。Gear Acceptance 同步锁定 schema 5/2、A/B、compact roundtrip、configured-empty corruption rejection。
- **BuildTag**：`v3-m1.16.0.18.95-persistence-v3-gear-journal`。NEXT 仍是 RU Fresh Reload，但 Gear Persistence v3 现在是首要验收项；通过前不宣告保存系统已完成。

## 2026-09-04 — `.18.94` Trade/DPS Fresh Reload Preflight Contract

- **继续执行 CURRENT §9，而不是跳过 RU Gate**：`.18.93` 已修复 DPS Reload 自动弹窗与 Trade Dropdown/Quote；本轮不新增业务功能，只把这两条实机回归升级为封包前 package-coherence + runtime acceptance preflight，确保下一次 RU Fresh Reload 测到的是完整修复包，而不是“代码已改但某个文件漏包”的状态。
- **DPS 可见性一致性门禁**：UIV3 Acceptance v58 新增 `TradeDpsFreshReloadPreflightContractVersion=1`。运行时只读检查 `v3.dps` Store schema 4、Feature `widgetVisible`/公开 Command，以及 WidgetHost `combat.dps` lifecycle `preference()` 的真实返回值必须与 `GetWidgetVisible()` 一致；若再次回退成无条件 auto-show，直接报 `dps_widget_visibility_preference_contract`。
- **Trade Dropdown/Quote 一致性门禁**：运行时 preflight 要求 Trade Feature 暴露 `GetRouteSettings / SetFrom / SetTo / QuotePendingMaterials`，Projection 保持 `zones/sellableZones/pendingQuoteCount`，Life Economy Widget 版本满足当前 Dropdown/Quote Consumer 契约；缺失时报 `trade_dropdown_quote_preflight_contract`。这只证明公开链路与封包一致，Native popup 是否真正展开仍必须由 RU 点击验证。
- **Foundation package-coherence**：`rs_foundation_audit.py` 新增 `.18.94` 精确检查：DPS schema/visibility/lifecycle 不得漂移；Trade 页面/HUD 必须保持两级 Dropdown + 材料询价；四个起终点循环按钮及 Presentation `CycleFrom/CycleTo` 调用不得回归；静态 Zone 仅作候选，服务器 `GetSpecialtyRatioBetween` 仍为路线 Authority；报价完成必须重建受影响材料投影。
- **验证**：Foundation Audit PASS；Workspace Smoke 27/27；Presentation→Feature API self-test 5/5；Persistence Snapshot 19/19；Interactive Draft 13/13；Bag 4/4；Unit Lines 11/11；Front-Hemisphere 10/10。
- **BuildTag**：`v3-m1.16.0.18.94-fresh-reload-preflight`。NEXT 仍是 **RU Fresh Reload + Persistence Reliability v2 Runtime Acceptance**；通过前不进入下一业务 UI Gate。

## 2026-09-04 — `.18.93` DPS Visibility + Trade Dropdown/Quote RU Hotfix

- **DPS reload 自动弹窗根因修复**：`combat.dps` WidgetHost lifecycle 之前把 `preference()` 硬编码为 `true`，因此只要 DPS Feature 偏好启用，每次 reload 都会自动 `Show()`，与用户是否关闭悬浮窗无关。`v3.dps` Store 升 schema 4，新增 durable `widgetVisible`；Show/Hide/Native Close 只在 `persist~=false` 时写入该偏好，auto lifecycle 只读取该字段。旧 schema 1–3 无字段会迁移为 `false`，因此本次升级不会继续继承“永远弹出”的旧行为。
- **Trade 下拉可用性**：`Trade.Authority:RefreshZones()` 不再在 RU `X2Store:GetProductionZoneGroups` 调用失败时直接 `unavailable + return`；与既有 empty-payload policy 一致，失败时也可使用 sealed 34-zone candidates，并保留 error/fallback 诊断。最终路线仍只由 `GetSpecialtyRatioBetween` 服务器返回判定，静态数据不升级成 Authority。
- **Trade 页面布局**：删除 `起点◀/起点▶/终点◀/终点▶` 四个冗余按钮及 Presentation 对 `CycleFrom/CycleTo` 的契约依赖。主页面改为“起点 / 目的地”两行 Dropdown-only 布局，状态行移到路线控件之后，降低 1024 宽度下的拥挤。兼容 Feature cycle Commands 保留，不删除旧 API。
- **Trade HUD 补齐询价**：Floating Widget 同样改成两行 Dropdown-only 路线布局，并在目的地行新增“材料询价”。页面与 HUD 不再各自遍历业务材料，统一调用 `Trade:QuotePendingMaterials()`，批量提交仍受 `PriceQuoteQueueV3.maxQueue` 与显式用户动作约束，普通 Refresh 不产生 Auction fan-out。
- **材料成本/利润真实回写修复**：修复 `BuildTradeMaterialProjection` 的 `complete` 初始值错误及 quoted/excluded 小计从未累加的问题；报价 callback 不再只加 revision，而是只查找引用该 `materialKey` 的当前路线行并重建其材料投影。所有必需材料完成报价后，`materialCostCopper/profit` 才转为完整值，未完成项继续明确显示未知。
- **静态门禁**：DPS Acceptance 要求 Store schema 4 + visibility public facade；Presentation→Feature API Audit PASS（calls=358），RSUI Component API Audit PASS（calls=470）。
- **BuildTag**：`v3-m1.16.0.18.93-trade-dps-runtime-ux-hotfix`。RU NEXT：Fresh Reload 验证 DPS 关闭后不再自弹、Trade 两级下拉 popup、HUD 询价与异步成本/毛利回写。

## 2026-09-04 — `.18.92` Presentation→Feature API Contract Audit + Missing Command Repair

- **继续 Foundation First，不跳过 RU Gate**：CURRENT §9 的 NEXT 仍是 RU Fresh Reload；本轮只完成 Fresh Reload 前还能由本地真实代码证明的 Public API 收口，不提前进入下一业务 UI Gate。
- **新增 Presentation→Feature Public API 封包门禁**：`tools/rs_presentation_feature_api_audit.py` 从真实 Feature provider 提取公开方法与 `Commands`，覆盖 split Feature、`S.Features.Name = LocalFeature` bundle、以及 `NewFeature("id", spec)` business provider，再扫描 `presentation/v3` 的静态 Feature consumer。Lua 语法合法但 provider 未导出的 `Feature:Method()` / `Feature.Commands:Method()` 现在会直接阻断 Foundation Audit；显式 capability guard 继续允许。动态 `S.Features[expr]` 仅计数，不猜表达式，仍由既有 BusinessPages/Acceptance 证明。
- **首轮审计直接发现 3 个真实漏接**：Tasks 与 Activities 悬浮窗均把 `setState` 绑定到 `Feature.Commands:SetWidgetWindowState`，但 Commands facade 从未导出该方法；Gear Quick Settings Modal 调用 `Feature.Commands:ResetQuickSnapSettings`，而 Gear Commands 同样缺失。三条都可能在页面已能打开之后，于拖动/缩放悬浮窗或点击 Gear 重置时才报 `attempt to call method ... nil`，因此旧 Lua Parse/Component API Audit 无法覆盖。现分别补齐只转发到既有 Feature Authority 的 Commands，不新增第二状态。
- **Runtime/package coherence**：Tasks/Activities/Gear 各自 Acceptance 同步要求新 Command；Foundation Gate 升 v88 并新增 `v3_presentation_feature_api_contract[tasksWindow/activitiesWindow/gearReset]`，避免未来增量包漏文件时只靠开发机静态工具发现。
- **Auditor self-test**：新增 `tools/rs_presentation_feature_api_audit_harness.py`，覆盖 valid static provider、missing command 必须失败、explicit guard 允许、`NewFeature` spec command、bundle export 五类，`5/5 PASS`。当前真实工程扫描：`providers=36 / usedProviders=25 / aliases=45 / calls=353 / dynamicAliases=5`，**0 缺失静态 Feature API**。
- **验证**：210/210 Active Lua Parse、Foundation Audit PASS（新增 `presentationFeatureApi=1`）、Component API Audit PASS、Presentation Feature API Audit PASS、Workspace 27/27、Persistence 19/19、Interactive Draft 13/13、Bag 4/4、Unit Lines 11/11、Front-Hemisphere 10/10。
- **BuildTag**：`v3-m1.16.0.18.92-presentation-feature-api-contract-audit`。RU NEXT 不变：Fresh Reload 后重点验证状态显示/Persistence，同时新增 Tasks/Activities 浮窗拖动保存与 Gear Quick Settings Reset 三条 spot-check。

## 2026-09-04 — `.18.91` RSUI Prepackage Contract Audit

- **同类页面崩溃继续扫描**：不是继续给某个页面写 `nil` 特判，而是新增 `tools/rs_rsui_component_api_audit.py` 扫描全部 `presentation/v3` 的已识别 RSUI Component 构造与方法调用；公共 Base API 从运行时代码提取，类型特有 Public API 显式列入 reviewed contract。未知方法若没有 `type(component.Method)=="function"` capability guard，Foundation Audit 直接失败。当前基线：29 个 Presentation 文件 / 501 构造 / 466 方法调用 / 5 guarded，**0 未保护 API 越界**。
- **Workspace 真构建覆盖扩大**：`RSUI_WORKSPACE_SMOKE_HARNESS` 从 LayoutEditor 单一路径扩展为 MasterDetail / InspectorWorkbench / ResponsiveInspector / LayoutEditor / SettingsWorkbench / CommandCenter 六类公共模板，真实 texlua 构建 `27/27 PASS`；Button mock 继续故意不实现 `Show()`，确保 scaffold 不能依赖未声明 convenience method。
- **TOC 依赖顺序硬门禁**：Foundation Audit 新增 RSUI top-level fail-closed dependency provider-before-consumer 检查；Framework 若在加载时要求 `RSUI.ListView/Windowing/...` 已存在，则 provider 必须在 toc.g 更早。用于阻止 `.18.81` TreeView/ListView 类“文件都在但顺序使组件未注册”的回归。
- **发现并修复开发 Gate 自身缺陷**：`rs_unit_line_sampling_harness.py` 与 `rs_screen_projection_front_hemisphere_harness.py` 的默认 `--root=replicatedsuite` 依赖当前工作目录，从工程根执行会错误查找双重 `replicatedsuite/`。现改为脚本文件位置解析工程根；从 `replicatedsuite/` 与其父目录调用均分别通过 `11/11`、`10/10`。
- **运行时影响**：除 BuildTag 更新外不改变 Feature/Store/TOC/RSUI Runtime 行为；新增检查均为 developer-only prepackage tools。RU Fresh Reload 仍是下一 P0 Gate。
- **BuildTag**：`v3-m1.16.0.18.91-rsui-prepackage-contract-audit`。

## 2026-09-04 — `.18.90` RSUI Component API + Package Coherence RU Hotfix

- **第六次“页面打不开”根因收口**：RU 堆栈确认 `ui/framework/rs_ui_workspace_templates.lua:341` 对标准 `Button` Component 调用了不存在的 `Show()`。这不是 Native 失败，而是 Lua 动态 method lookup 在语法检查阶段无法发现的 Public API 漂移；BuildTransaction 因异常正确 rollback/quarantine，但用户仍无法进入页面。
- **RSUI Component API Contract v1**：RSUI 升至 v44 / API 12.8。Base Component 统一提供 `Show/Hide → SetVisible` facade；新增 `RequireComponentMethods()`，Composite/Workspace 在构建边界显式校验真实调用方法。`RSUI:Create()` 同时验证所有组件的公共 `GetRoot/SetVisible/Show/Hide/SetEnabled/Release` 契约，不新增 Tick/Render 扫描。
- **WorkspaceTemplates v6 / LayoutEditorWorkspace v4**：Inspector Toggle 改用共享 `SetVisible(drawer)`，并对 ResponsiveInspector、Toggle、StatusChip、LayoutEditorOverlay、TransformInspector、EditorCommandBar 做构建期 Public API fence。新增真实 Lua `RSUI_WORKSPACE_SMOKE_HARNESS`，Button mock 故意不实现 `Show()`，因此同类回归会在封包前失败。
- **Persistence package-coherence 修复**：用户诊断同时暴露 `persistence_runtime_acceptance_snapshot[contract=0/fingerprint=false/snapshot=false]`。检查完整工程确认 `.18.84` 的 Gate/Docs 已存在，但 `core/rs_persistence.lua` 的 `RuntimeAcceptanceSnapshotContractVersion/FingerprintPayload/BuildRuntimeAcceptanceSnapshot` 以及诊断页“输出存档验收”实现未进入当前完整包。`.18.90` 恢复这些运行时实现，并新增 Foundation Audit package-coherence fence + `PERSISTENCE_ACCEPTANCE_SNAPSHOT_HARNESS`，禁止以后再次出现“文档/Gate 已升级但实现漏包”。
- **验证**：Foundation Gate v87、UIV3 Acceptance v57、Workspace v6、LayoutEditorWorkspace v4。新增 non-destructive Sequence `v3_56_ui_component_api_contract`；封包前必须通过 210/210 Lua Parse、Foundation Audit、Workspace Smoke、Persistence Snapshot、Interactive Draft、Bag/Unit Lines/Front-Hemisphere 回归。

## 2026-09-04 — `.18.89` RSUI Interactive Draft + Compact Layout Inspector RU Hotfix

- **RU 实机反馈**：状态显示 HUD 布局在当前窗口宽度下没有可见的 X/Y/宽高等参数入口；Slider 拖动时每帧在预览值与旧值之间来回跳；Numeric/EditBox 删除或输入字符后会立即恢复旧文本。代码核查确认参数模型并未缺失，而是 Compact ResponsiveInspector 把唯一 TransformInspector 收进 Drawer 后，LayoutEditorWorkspace 漏了打开 Drawer 的用户入口；同时共享 Control `Render()` 会在 Aura/页面环境刷新时把尚未 Commit 的 Slider Preview / focused Edit draft 用旧 Binding 值覆盖。
- **RSUI Interactive Draft Contract v1**：RSUI 升至 v43 / API 12.7，TextInput/NumericInput 在 Native EditBox 获得焦点期间拒绝 ambient binding refresh 覆盖草稿；Slider 在 active drag 期间拒绝 ambient Render 回灌旧值。显式 API、interaction preview 与 final commit 仍可覆盖。未引入猜测的 `OnTextChanged/OnKeyDown/OnKeyUp`，继续复用已验证 Focus identity 与现有 drag state。
- **NumericField v4**：`SyncControls(value, source)` 显式传播 `binding_refresh / interaction / commit` 来源；Slider Preview 只同步当前 draft，最终 Commit 才推进 Binding，避免父 Field 刷新重新引入旧值。
- **LayoutEditorWorkspace v3 / WorkspaceTemplates v5**：Compact/Drawer 模式在稳定 Toolbar 增加 `[属性] / [收起属性]` 按钮，调用 SAME ResponsiveInspector Drawer，不 reparent、不复制 Inspector；状态显示进入 HUD 布局时在 Compact 模式自动打开属性 Drawer，选中元素也允许自动打开，从而恢复 X/Y（左-/右+、上-/下+）、宽高、Anchor/Pivot、Snap 等共享 TransformInspector 参数。
- **状态显示刷新边界**：`v3.buff_display.updated` 只在 `追踪管理` 页刷新 Aura Table；HUD Layout 的 isolated Working 不再被 Aura cadence 重绘。其他必要页面刷新仍由共享 Interactive Draft fence 保护，因此修复不依赖页面级“正在输入”第二份状态。
- **防回归/验证**：Foundation Gate v86、UIV3 Acceptance v56、Workspace v5 静态门禁要求 compact inspector affordance；Audit 还要求 BuffDisplay compact auto-open 与 Aura refresh boundary。新增 `RS_INTERACTIVE_DRAFT_HARNESS PASS 13/13`，真实加载 controls 并验证 focused text/numeric draft、slider preview、commit/resync。
- **BuildTag**：`v3-m1.16.0.18.89-rsui-interactive-draft-layout-inspector`。RU 下一步重点实测 Compact HUD 属性 Drawer、X/Y 精确输入、Slider 连续拖动与 Aura 高频刷新期间的输入草稿稳定性，再继续 Fresh Reload 矩阵。

## 2026-09-04 — `.18.88` Unit Lines Front-Hemisphere Cull RU Hotfix

- **RU 实机反馈**：目标位于玩家视野背后时，单位连线会错误指向屏幕边角。`.18.87` 已解决长线采样与 viewport clipping，但仍信任 `GetUnitScreenPosition` 的正 depth；RU 某些背后角度会返回正 depth + 镜像/边角屏幕点，因此 Presenter 正常裁剪反而把错误端点保留下来。
- **投影 Authority 修复**：`ScreenProjectionV3` 升至 v4，新增 `ProjectUnitBatch()` / `FrontHemisphereBatchContractVersion=1`。Unit Lines 每次 Demand refresh 只构建一次 Camera Frame，对启用 pair 所需 `player/target/targettarget/watchtarget/watchtargettarget` token 去重后读取世界坐标，并以 `dot(unit-camera, cameraForward)` 判定前半球；`forward<=epsilon` 返回 `behind_camera`，在 Native screen projection 与 Presentation clipping 前 fail-closed。
- **前方屏外兼容**：若单位在相机前半球但 Native unit screen point 出界，batch 使用同一 Camera Frame 做 logical world fallback，保留真实超屏坐标，继续交给 `.18.87` Liang-Barsky 裁剪。不会用“靠近屏幕边角就隐藏”的启发式误杀正常前方目标。
- **性能/生命周期**：Camera Pos/Dir/Fov 每 batch 各读取一次，不按 4 条 pair 重复抓取；unit token 去重，最多处理当前四条关系实际涉及的 5 个 token。无新 Tick/Scheduler/Store/schema；HighFrequency P1、adaptive density、pressure budget、Native Diff、progressive pool 全部保持 `.18.87` 契约。
- **防回归/验证**：Foundation Gate v85、UIV3 Acceptance v55、Foundation Audit 增加 ScreenProjection v4 + front-hemisphere batch fence，并禁止 Unit Lines 回退逐端点 `ProjectUnitFlexible()`。`SCREEN_PROJECTION_FRONT_HEMISPHERE_HARNESS PASS 10/10`，模拟“behind + positive depth + corner coordinate”确认在 Native screen read 前拒绝；`UNIT_LINE_SAMPLING_HARNESS PASS 11/11` 保持通过。
- **BuildTag**：`v3-m1.16.0.18.88-unit-lines-front-hemisphere-cull`。

## 2026-09-04 — `.18.87` Unit Lines Adaptive Density + Crowd Smooth Refresh RU Hotfix

- **RU 两次连续实机反馈**：①近距离 dots 很密，但距离拉远后固定点数被摊开，某些斜角/屏幕边缘甚至整段看不见；②多人场景线条刷新“一卡一卡”。代码核查确认两个独立根因：旧 Presenter 把 `pointCount` 当最终点数且不先裁 viewport；Unit Line 虽使用 HighFrequency lane，却显式注册成 P3，FrameBudget 在拥挤/低帧时会不规则延后整次刷新。
- **自适应密度 + 可见段裁剪**：`CombatVisualGuidesV3 v5` 保留旧 `pointCount/pairPoints(8..48)` Store 作为基础密度，不迁移 schema。先用 bounded Liang-Barsky 裁剪 logical viewport 可见段，再按 240 logical px 参考长度换算 spacing；短线保持基础密度，长线自动补点，单 Edge hard cap=160。端点远离屏幕但关系线穿屏时仍绘制；整段确实不经过 viewport 或 depth<=0 才 fail-closed。
- **Crowd Smooth Refresh**：`UNIT_LINE_TASK` 从 P3 改为 P1 visual cadence，避免压力场景整批 refresh 被 Scheduler 延后。负载控制改到 Presenter 内部：Normal/Busy/Heavy/Critical 对 adaptive extra 使用 100%/82%/68%/55% budget，但永远不低于用户 persisted base density；不会用“整帧不更新”换性能。
- **Native Diff**：新增 Presenter-local per-dot render cache。稳定几何/外观下不再重复调用 RSUI 的 Extent/Color/Visible/Anchor compatibility path；移动线通常只发生 Anchor 写。这个局部缓存不替代 RSUI Authority，只用于高频 HUD 在调用 RSUI 前判断“值根本没变”，避免几百个 dot 每帧触发 Native getter 验证。
- **渐进点池**：长线首次出现/距离突然拉长时，不再单帧创建上百个 Native Widget；点池按压力每 Render 最多增长 48/32/24/16，后续帧继续补齐并复用。Feature Disable/Consumer release 仍只隐藏/停止原有 Demand 资源，不新增 Tick/Scheduler。
- **设置/诊断兼容**：设置页“点数”继续显示为“基础密度”，提示更新为多人压力只削减额外补点。Feature projection 增加 runtime `pointBudgetMode=cadence_pressure_bounded / refreshPriority=P1_visual`；Presenter `Describe()` 暴露 `unitPressure/requestedDots/visibleDots/poolGrowth/anchorWrites/styleWrites/visibilityWrites`，便于 RU 二次定位。Store/schema/key 不变。
- **防回归**：`UnitLines.VisualGuideContractVersion=4 / AdaptiveDensityContractVersion=2 / SmoothRefreshContractVersion=1`；Presenter `AdaptiveUnitLineSamplingContractVersion=2` + clipping/pressure-budget/diff/progressive-pool contracts；Foundation Gate v84、UIV3 Acceptance、`v3_55_unit_line_adaptive_sampling_contract` 同步升级。Foundation Audit 禁止固定最终 8..48 点和 Unit Line HighFrequency 回退 P3。
- **验证**：`UNIT_LINE_SAMPLING_HARNESS PASS 11/11`，覆盖 near/long/clipping/offscreen、1ms/100ms budget、Critical extra shedding、Critical progressive growth≤16、Normal growth≤48、稳定帧零冗余属性写、移动帧仅 Anchor 更新；Foundation Audit PASS。
- **BuildTag**：`v3-m1.16.0.18.87-unit-lines-adaptive-smooth-render`。RU 下一步重点验证 1024×768/1080P/2K 的近远距离与斜角可见性，以及主城/团战多人压力下刷新连续性。

## 2026-09-04 — `.18.86` Bag Dynamic Source Resolution RU Hotfix

- **RU 实机根因修复**：用户确认“存放/放同类每点一次只移动一个物品”。旧 quick/category queue 预存 `slot`，但 `MoveToEmpty*` 成功后客户端会压缩/重投影源容器，导致同类物品补进刚清空的槽；旧 verifier 将“原槽仍有同类物品”误判为移动失败并停止，后续预计算 slot 也失效。
- **Bag Move Contract v5**：quick queue 只保存稳定 `itemType` 意图，category batch 只保存稳定 `category` 意图；每个 250ms Scheduler step 在 Action 前调用统一 `BagMoveRuntime.FindLiveMoveSource()` 重新解析当前源槽，并在 live row 上再次执行 blacklist。slot 只存在于“本次写入 + 下一拍验证”的 transient pending，不再跨多个队列步骤充当身份。
- **压缩槽位验证**：正常情况下原槽为空/身份变化即可确认成功；若另一件同类物品补到原槽，才调用 `CountLiveMatches()` 做 bounded source-population decrease 验证。源数量下降则继续队列；数量不变仍 fail-closed，保留 RU 2026-06-02 intermittent move fix 之后的失败防护。Category batch 同样处理非空补位，不再要求原槽绝对为空。
- **生命周期/性能不变**：Quick/Category 继续互斥；每步最多一条写操作；仍使用 250ms P1 Scheduler、40 次 hard cap、240 槽 scan bound；无 Tick/新 OnUpdate。完整扫描只出现在初始计划或 post-write 槽位歧义路径，常规每步只扫描到首个 live match。窗口关闭/切换、用户取消、Feature Disable 仍释放任务和运行态。
- **防回归**：`BagMoveContractVersion=5 / BatchLifecycleContractVersion=5 / NativeWindowQuickContractVersion=3 / DynamicSourceResolutionContractVersion=1`；Foundation Gate/UIV3 Acceptance 升级到 bag v5。`rs_foundation_audit.py` 明确禁止 serial plan 再保存 transient slot；新增 `tools/rs_bag_move_queue_harness.py`，quick same-type compaction / mixed type / category+blacklist / failed-write 四类测试 `4/4 PASS`。
- **BuildTag**：`v3-m1.16.0.18.86-bag-dynamic-source-resolution`。RU 下一步仍为 CURRENT §9.2 Fresh Reload，同时优先复验一次点击“放同类/高级整理”是否能连续处理多件。

# Replicated Suite 变更记录（Changelog）

## 2026-09-04 — `.18.85` Buff Display Coordinate-Space RU Hotfix

- **用户实机阻断**：状态显示无法打开，诊断稳定报告 `layout_editor_overlay_coordinate_space_required`，并触发 Page quarantine / BuildTransaction rollback / preflight fail。
- **真实根因**：`rs_v3_buff_display_page.lua` 的首个真实 `LayoutEditorWorkspace v2` Consumer 声明 `coordinateSpace="local"`，但遗漏 `pointerToLocal`；PointerService 采样的是 viewport-logical 坐标，因此共享 Overlay Validator 正确 fail-closed。没有放宽 Foundation，也没有把 local 错标为 viewport。
- **修复**：新增 `ViewportPointerToEditorLocal()`。手势采样时从 Gesture Controller 的 SelectionOverlay 追溯唯一 LayoutEditorOverlay native root，调用 `Layout:GetLogicalRect()` 获取实时 logical origin/extent，再按声明的 640×320 editor canvas 映射 viewport pointer；不缓存 geometry，避免窗口移动、Responsive reflow、ScaleBox、UI Scale 后拖动漂移/比例失真。Native/root 不可用时返回 nil，由 Gesture 契约继续 fail-closed。
- **回归门禁**：Foundation Audit 新增 Buff Display local coordinate Consumer fence，要求 `coordinateSpace="local"` 与显式 `pointerToLocal` 成对存在，并验证转换仍基于 live editor root logical rect。
- **兼容性**：不改 Store/schema/TOC/Feature 生命周期/共享 LayoutEditorOverlay Contract；只修 Presentation 坐标适配和静态门禁。
- **BuildTag**：`v3-m1.16.0.18.85-buff-display-coordinate-space-hotfix`。RU 下一步仍为 CURRENT §9.2 Fresh Reload；重点先验证状态显示页面可打开、Build Transaction 计数清零及 HUD 拖动/缩放方向正确。

## 2026-09-04 — `.18.84` Persistence Fresh Reload Fingerprint

- **Fresh Reload 内容证据**：Persistence 新增 `RuntimeAcceptanceSnapshotContractVersion=1`、`FingerprintPayload()` 与 `BuildRuntimeAcceptanceSnapshot()`。指纹直接基于 Store `get()` 的 Domain save snapshot，先走现有 SaveData budget，再按稳定 key 顺序计算；table 插入顺序不会导致假差异，字段变化会改变指纹。
- **严格只读边界**：Snapshot 不自动 Load、不 Flush、不 Save、不改 dirty/fence，也不读取 `payload/__rsmeta` 编码 envelope；冷 Store 明确输出 `store_not_loaded`，避免默认值冒充真实回读。Persistence Core 保持业务 ID 无关。
- **诊断 UI**：`诊断与维护` 新增独立第三行“输出存档验收”。当前验收清单覆盖 Buff Display、Healer、Gear Index、Activities、Tasks、DPS、Trade；已注册的 `v3.gear.payload.*` 动态进入 `ALL` 总指纹，详细 payload 行最多 8 条，剩余只报数量。输出同时包含 loaded/dirty/fence/schema/dirtyRevision/lastSavedRevision。
- **Gate**：Foundation Gate 升 v82，新增 `persistence_runtime_acceptance_snapshot` blocker contract；没有 Snapshot API 或 contract version 不足时拒绝宣告 Foundation Ready。
- **兼容性**：没有新增 Store、没有 SaveData key/schema/metadata 变化、没有 TOC 新文件；旧用户配置与升级路径不变。
- **验证**：`PERSISTENCE_ACCEPTANCE_SNAPSHOT_HARNESS PASS 14/14`；全量 Lua Parse PASS（210/210）；Foundation Audit PASS（`toc=210 activeLua=210 allLua=210 globals=0 presentation=0 rawNative=0 rawScope=0 detachedWidgetState=0 apiDependency=0 apiCapability=0 businessIds=0 auctionEventOwners=0 retiredUiLayer=0`）；Markdown 相对链接 58 条、0 断链。RU Fresh Reload/完整退出重进仍是 §9.2 唯一 NEXT，本轮不把本地指纹工具冒充实机回读通过。
- **BuildTag**：`v3-m1.16.0.18.84-persistence-fresh-reload-fingerprint`。

## 2026-09-04 — `.18.83` Persistence Runtime Acceptance Diagnostics

- **NEXT 对齐**：继续执行 CURRENT §9.2 的 RU Fresh Reload / Persistence Reliability v2 Runtime Acceptance，不抢跑下一业务 UI Gate。
- **单一 Reload/Flush Authority**：删除诊断页“重新加载文件”按钮的额外预 `Persistence:Flush()`；页面现在只调用 `ReloadCodeFromDisk()`，避免一次点击双写、双失败计数以及首个失败原因被吞。
- **可复制 Store 故障证据**：`Persistence:Flush()` 保存最近一次 runtime-only `lastFlush { at, ok, owner, failures }`，`Describe()` 暴露 `RuntimeAcceptanceDiagnosticsContractVersion=1`。该快照不持久化、不参与重试/写策略，Store dirty/fence 仍是唯一 Authority。
- **Foundation/Diagnostics**：Foundation Gate v81 新增 `persistence_runtime_acceptance_diagnostics`；一键摘要在 Flush/Fence 异常时直接附带最多 3 条 `store id:reason`，Recent Fault 也保留 `context.store/context.failures`；诊断页新增“最近存档落盘”行。
- **文档收口**：更新 `RU_RUNTIME_ACCEPTANCE.md` 的旧 `.18.60` BuildTag，新增 Buff Display/Healer/Gear/Activities/Tasks/DPS/Trade 的 Persistence Fresh Reload 矩阵，并删除对不存在的 `.workbuddy/tmp` harness 路径依赖。
- **验证**：changed-file Lua Parse PASS；全量 Lua Parse PASS（210/210）；Foundation Audit PASS（210/210，全部结构越界 0）；`PERSISTENCE_RUNTIME_ACCEPTANCE_HARNESS PASS` 验证失败 Flush 保留 exact store+reason、后续成功 Flush 覆盖失败 evidence；Markdown 相对链接检查 58 条、0 断链。
- **BuildTag**：`v3-m1.16.0.18.83-persistence-runtime-acceptance-diagnostics`。

## 2026-09-04 — `.18.82` Persistence 迁移收口 + §9.3 业务回归（本地）

- **Persistence 剩余 mutation→MarkDirty 收敛**（`.18.80` NEXT 的延续）：
  - `rs_feature_runtime.lua SetPreferredEnabled`：显式偏好写入改走 `MutateStore`（快照/回滚覆盖偏好表），Enable/Disable 生命周期副作用保留手动回滚；
  - `rs_life_m16_bundle Trade:SetFrom`：起点选择改走统一事务，删除手写 `RestoreTable` 回滚；`Fishing ArmAuto` 命令持久化失败时 fail-closed（自动回滚已装备的热键会话），删除遗留裸 `Save()` helper；
  - 删除死代码 `MarkAnalyticsStoreDirty`（唯一真实写入已走 `MutateAnalyticsStore`）。
- **§9.3 Bag 整理"点击没反应"根因修复**：整条链所有 `return false, err` 均为静默。修复：`BatchMove`/`StartBagQuick` 前置失败现在写入 `State.batch`/overlay 状态（stopped + 原因）并发布刷新；页面 `开始整理`/`取放` 失败直接写状态文本，未启用时提示"功能未启用"；`SafeHandler` 绑定失败不再静默——写 Diagnostics `UI_HANDLER_BIND_FAILED` + WarnOnce 提示（该控件点击将无响应）。互斥与 200ms 冷却逻辑未改动。
- **§9.3 Trade 回归**：金额列（预计售价/毛利/材料单价/小计）全部接入 `S.Utils.FormatMoney` 金银铜格式；`RefreshSellable` 增加会话级 per-zone 缓存（◀▶ 循环不再每次点击重发 `GetSellableZoneGroups`，`RefreshZones` 时失效）；新增 `Trade:QuoteMaterial(materialKey)` 显式接入 `PriceQuoteQueueV3`，页面新增"材料询价"按钮（按当前路线行的 `explicit_quote_required` 材料去重提交）；下拉因地区未读取被禁用时状态行给出原因提示。
- **§9.3 Auction 收藏/报价**：`AuctionProjection` 暴露 `PriceQuoteQueueV3` 快照（`quoteStatus/quotePrice/quoteError`），demand 0→1 时订阅 `v3.price_quote.completed` 实现询价完成自动刷新；页面新增"结果询价"按钮（选中带 `itemType` 的结果行启用）；删除收藏改为两击确认；选中结果行回填关键词输入框；状态行显示"最低价：…/未询价"。
- **RSUI Composite 收尾（Foundation v5）**：落地 ROADMAP 三个本地 Contract。①`RSUI:ResolveStatusSemantic` 成为 Pending/Success/Warning/Blocked 等 status→tone/默认文案的唯一语义 Authority（`StatusSemanticsContractVersion 1`）；②`StateNotice` 统一 Empty/Loading/Error/Blocked 组合态视觉（chip + message + 可选 hint，fail-closed validator 拒绝未知状态）；③`DetailHeader` 提供 Breadcrumb（`A › B`）+ 标题 + 可选 StatusChip 的标准详情头。design_system `EmptyState` 保持静态"尚未迁移"占位职责并注释防第二 Authority 分叉。Foundation Audit 的 Composite version Gate 同步升至 5。
- **验证**：`RSUI_COMPOSITE_STATE_HARNESS PASS 24/24`（真实加载 component_core→primitives→panels→data_views→controls→composite_foundation 全链，mock 原生 widget）；`LAYOUT_EDIT_SESSION_MODEL_HARNESS PASS 24/24`（真实加载 History/Session 模型：partial contract 拒绝、Reset/Revert 零持久化、Apply 唯一持久化边界、失败不推进 Baseline、History Undo/Redo 回放）；`PERSISTENCE_V2_MIGRATION_TEST PASS 20/20`（MutateStore 提交/拒绝回滚/durable 失败回滚/冷库 corrupt payload 拒绝并 fence/dirty reload 拒绝/rollback 失败 fence，全部针对真实 `rs_persistence.lua`）；`BUSINESS_BRIDGE_BAG_TRADE_TEST PASS 9/9`（批量前置失败可见化、Trade SetFrom 事务、Flush 失败保留 dirty 重试、QuoteMaterial 拒绝未验证身份）；Foundation Audit PASS（210/210，全部结构计数 0）。
- **BuildTag**：`v3-m1.16.0.18.82-local-continuation-mutation-tx`。

## 2026-09-04 — `.18.81` RU Hotfix + Persistence Reliability v2

- **状态显示页面崩溃根因**：RU 日志 `rs_v3_buff_display_page.lua:273 attempt to call method '?'` 精确对应 `RSUI:TreeView()`。`rs_ui_composite_foundation.lua` 原在 `rs_ui_data_views.lua / rs_ui_controls.lua` 之前加载，而 Composite 顶部要求 `RSUI.ListView` 已存在，否则静默 return；因此 `StatusChip/Picker/TreeView` 全部未注册。已调整 Active TOC 依赖顺序，并在 Foundation Audit 增加 prerequisite-order Gate；Buff Display 页面增加 SelectionModel/TreeView preflight，依赖异常改为明确 build error，不再 nil method。
- **Foundation Gate 修复**：`v3_advanced_ui_contract` 正确绑定 `S.UITokens`；`StatusClassificationV3.presentationBoundary = service_only`；UI Acceptance 删除早已退役的 `Persistence.ReadLegacy` 假契约，改为 Reliability v2 API。
- **Persistence v2 根因修复**：业务 Domain `budget` 与 Persistence 编码 `encodedBudget` 正式分离。`payload/__rsmeta` 的框架固定外壳拥有独立 bounded overhead，合法业务数据不会再因框架自己追加 metadata 触发 `encoded_payload_rejected → WriteFence → FlushFail`。注册期同时检查 default Domain + default envelope。
- **事务契约**：新增 `Persistence:MutateStore()`，统一 `PrepareWrite → snapshot → mutate → MarkDirty/Save → rollback`；mutation、commit 或 durable SaveData 失败均恢复 Domain 与 dirty metadata，只有 rollback 本身失败才 write-fence。Foundation `persistence_v2` 只看当前结构健康/fence，历史 reject 计数移入 incident warning。
- **业务迁移**：Buff Display、Healer、DPS、Combat Analytics、Raid Readiness、Tasks、Activities、Gear Quick HUD 关键命令、Death Review 关键 index、Life M16 通用 mutation、Business Bridge blacklist/craft context 已接入 v2 transaction；Buff Display full import 保留 bool/数字兼容并禁止事务内逐字段 publish。
- **验证**：`PERSISTENCE_RELIABILITY_V2_HARNESS PASS`；Foundation Audit PASS：`toc=210 activeLua=210 allLua=210 globals=0 presentation=0 rawNative=0 rawScope=0 detachedWidgetState=0 apiDependency=0 apiCapability=0 businessIds=0 auctionEventOwners=0`；210/210 Lua `texluac -p` PASS。RU Fresh Reload / 退出重进 SaveData 回读仍为下一硬验收。
- **BuildTag**：`v3-m1.16.0.18.81-ru-hotfix-persistence-reliability-v2`。

## M1.16.0.18.80 — Persistence Reliability v1 + Buff Display UI_IMPLEMENTING（2026-09-03）

- **用户 P0 反馈**：配置经常在重载/下一次进入游戏后丢失。审计确认至少两类底层危险链真实存在：Runtime Stop 过去可能在 Feature teardown 后才 Flush；Persistent Store 过去允许未 Load 就进入写意图。两者都会把 default/teardown 状态覆盖旧 SaveData。
- **Persistence Reliability Contract v1**：新增 `ReliabilityContractVersion=1`、`PrepareWrite()`、Load-before-Write fence、dirty reload fence、corrupt-nonempty protection、true debounce + max delay、SaveData failure dirty retention + bounded retry，以及对应 Diagnostics/Stats。普通 `SaveStore` 不再绕过 loaded/write fence；只有完整分片替换可显式 `allowUnloadedWrite=true`。
- **Runtime/Reload durability**：`Runtime:Stop()` 改为 `Flush → Feature Disable → Resource Quiescence`，且不会 teardown 后二次 Flush；用户主动 `ReloadCodeFromDisk()` 只有全部 dirty Store 安全保存后才触发原生 UI reload，否则明确取消。
- **Persistent Binding transaction**：设置控件在 Domain mutation 前 `PrepareWrite`，Store 冷态会先 Load+Apply；`MarkDirty` 失败时 best-effort 回滚 Domain value/revision，避免“页面看似成功、Reload 必回退”。
- **Direct-store call audit**：DPS boss list、Gear index/payload、DeathReview index/record 等立即保存路径补齐 load preflight；Gear Payload 与 DeathReview Record Slot 仅作为完整独立分片替换使用 `allowUnloadedWrite=true`。
- **Buff Display UI_IMPLEMENTING**：兼容四页签正式收敛为 `追踪管理 / HUD 布局 / 导入导出`；player+target 使用单一虚拟 Tracking Table；HUD 使用 `Element Tree + LayoutEditorWorkspace v2 + LayoutEditSession`。页面构造前读 Store，HUD Working Snapshot 与 Persistence getter 隔离；Preview/Undo/Redo/Reset/Revert 零持久化，只有 Apply 才 synchronous durable SaveStore。
- **Acceptance 修复**：最终 Foundation Audit 发现新增 BuffDisplay Acceptance 误用了未定义全局 `Fail()`；已改为标准 `return false, reason`，恢复 `globals=0`。
- **验证**：`PERSISTENCE_RELIABILITY_HARNESS PASS contract=1 unsafeReject=2 dirtyReload=1 retry=1 corrupt=1 autoLoads=1`；Foundation Audit PASS：`toc=210 activeLua=210 allLua=210 globals=0`；210/210 Lua `texluac -p` PASS。真实 SaveData 跨 Reload/重新登录仍需 RU Fresh Reload。
- **NEXT**：Persistence Reliability v2 / Mutation Transaction Audit，继续把剩余 public mutation 统一为 `PrepareWrite → mutate → MarkDirty/Save → rollback`；业务 UI 大规模迁移暂不抢占。
- **BuildTag**：`v3-m1.16.0.18.80-persistence-reliability-buff-display-ui-implementing`。

## M1.16.0.18.79 — Buff Display UI_APPROVED / Authority Cleanup（2026-09-03）

- **Gate**：用户确认“按照文档继续”，状态显示由 `UI_REVIEW → UI_APPROVED`。产品方向固定为 `追踪管理 / HUD 布局 / 导入导出` 三个任务；player/target 共用同一 HUD 几何模板；主手+副手在左、背部在右；远程 Fresh Default 为 OFF，启用时放左侧外层；Layout Reset 不清追踪。
- **装备布局 Authority**：`BuffHeadMarkersV3` 升 Contract 6，左侧顺序按“靠血条→外侧”为 `offHand → mainHand → ranged(optional)`，右侧只保留 `wings/back`；Acceptance 同步，不再与 Renderer 分叉。
- **默认值修复**：`COMPONENT_DEFAULTS.ranged.enabled=false`；`NormalizeComponent` 改为缺字段继承组件自己的 default，修复旧 `value.enabled ~= false` 会把所有缺失组件强制开启的问题。明确保存过的旧用户值继续保留。
- **字段 Authority 收口**：`headIconSize/headMaxIcons` 从 normalized live settings、页面控件、Projection/legacy accessor、导出策略中移除；旧 schema-4 存档和旧导入文本仍可兼容映射到 `components.buffs/debuffs.size/maxPerRow`。图标容量统一由 `maxPerRow × maxRows`（hard cap 64）决定。
- **Reset 语义**：新增 `ResetLayoutSettings`，只恢复 HUD components/head policy/plate/info 默认；tracked、classification、Tracking filters/rows、floating window 均保留。旧 `ResetAllSettings` 命令保留为同语义兼容 alias，禁止再执行破坏性清空。
- **导入导出兼容**：修复完整导入仍以 32/category 截断追踪 ID 的旧限制，统一为 Store 的 1024/category；完整导出/导入新增 Buff/Debuff `spacing/maxPerRow/maxRows` 与 CastBar `width/showText` round-trip，避免“导出后再导入”丢布局细节。
- **Store/Schema**：仍为 schema 4，无 schema bump；新增 `LayoutAuthorityContractVersion=1` 与默认设置 detached snapshot，供 Acceptance 和下一阶段 LayoutEditSession 使用。
- **验证**：Foundation Audit PASS：`toc=210 activeLua=210 allLua=210`，全部结构越界计数 0；BuffDisplay Acceptance 增加 40-ID import cap regression、component-specific export round-trip 与 fresh-default single-authority checks。
- **NEXT**：进入 `UI_IMPLEMENTING`，迁移三页签、单虚拟 Tracking Table，并把 HUD 布局接入 `Element Tree + LayoutEditorWorkspace v2 + LayoutEditSession`；本轮不抢跑大规模页面迁移。
- **BuildTag**：`v3-m1.16.0.18.79-buff-display-ui-approved-authority-cleanup`。

## UI REVIEW — Buff Display / 状态显示 v3（2026-09-03）

- **执行范围**：按 CURRENT §9.2 从 Foundation 进入第一个业务页面评审；只做真实代码审查 + 产品 UI_REVIEW，**不修改 Runtime / TOC / Store schema / 用户配置 / BuildTag**。Runtime 基线仍为 `.18.78`。
- **真实代码审查**：读取 Store schema 4、BuffDisplay Feature/Projection/Commands、当前四页签页面、BuffHeadMarkers Renderer、Aura/Metadata/Classification Services 与 `.18.75~.18.78` Layout Editor Foundation。
- **页面收敛**：当前 `状态追踪 / 头顶显示 / 布局外观 / 导入导出` 四页签评审为 `追踪管理 / HUD 布局 / 导入导出` 三个用户任务；头顶显示与布局外观合并，避免同一 HUD Template 的重复设置入口。
- **Tracking Review**：利用已有 `GetProjection("all") / GetTrackedList()`，设计为单一虚拟 Table + 来源筛选，不再在 1024×768 下并排“自己/目标”两张表；行点击仍是一键追踪/取消。
- **Layout Review**：指定 `Element Tree + LayoutEditorWorkspace v2`；player/target 共用一套 HUD 几何模板，只分别控制显示/Preview Scope；原生血条只作为不可见对齐基准，不虚构 Gameplay HealthBar Widget。
- **Persistence Review**：Tracking/Classification 仍可作为明确业务操作即时持久化；布局编辑必须 staged Working，Undo/Redo/Revert/Reset 不写 Store，只有 Apply 跨越 durable persistence boundary；Layout Reset 不得清 tracked/classification/window state。
- **运行时事实边界**：当前只批准 `player / target`；WatchTarget/Cooldown/Name 不因参考插件存在而进入当前 UI。目标装备图标因 RU scope API 证据不足继续 fail-closed，页面必须显示能力状态而非伪造可用。
- **发现的实现分叉**：Renderer 当前装备分组为左 `offHand/mainHand`、右 `wings/ranged`；Acceptance 却断言左 `ranged/offHand/mainHand`、右 `wings`；Store 注释“ranged 默认 OFF”与实际默认 `true` 冲突；Page 注释出现 schema 5 而真实 Store 仍为 schema 4；`headIconSize/headMaxIcons` 与 component 字段重复；现有 `ResetAllSettings` 作用域过大。
- **当前 Gate**：状态显示已从 `UI_DRAFT → UI_REVIEW`；下一步必须由用户确认 Review 中 4 个产品决策后进入 `UI_APPROVED`，再开始代码迁移。

## M1.16.0.18.78 — UI LayoutEditorWorkspace Integration（2026-09-03）

- **执行范围**：继续 Foundation First，零业务 Feature 页面迁移；完成 CURRENT §9.2 第 4/5 项，把 `.18.75~.18.77` 的 History / CommandBar / Session 正式接回共享 Workspace，并同步回写 Roadmap/Architecture。
- **RSUI v42 / API 12.6 / WorkspaceTemplates v4 / LayoutEditorWorkspace v2**：Workspace 创建唯一 bounded `LayoutEditHistoryModel` 并注入 PreviewAdapter；新增稳定 Command Host + `EditorCommandBar v2`，不再要求页面自己拼接 Undo/Redo/Reset/Revert/Apply。
- **Session Preflight**：`editSession=nil` 保留 history-only 兼容模式；一旦传入 Session 边界，必须同时提供 `getWorkingSnapshot / getPersistedSnapshot / getDefaultSnapshot / applyWorkingSnapshot / persistSnapshot`，partial contract 在构造 Native editor 前 fail-closed。
- **Authority Refresh Chain**：History `record/undo/redo` 只从 Adapter 刷新 Overlay/Inspector；Reset/Revert/Rebase 才从 Feature Working 显式 `RefreshFromSource`；caller 主动 Source Refresh 同步 `Session:RefreshWorking()`，不维护第二份 dirty/can* 状态。
- **Persistence Boundary**：Workspace 静态门禁禁止直接出现 `S.Persistence / SaveData / ClearData / SaveStore / MarkDirty`；durable Apply 仍只由 Feature callback 确认，Workspace 只负责绑定。
- **Lifecycle**：CommandBar/Session/History 全部事件订阅；root Release 先释放 UI 子组件，再解绑/释放 Session 与 History，避免关闭编辑器后残留监听或有界历史对象。
- **Compact UI**：CommandBar 默认 46px 紧凑按钮 + 84px 状态区，保持 1024 宽内容区可用；PreviewHost/Overlay/SAME TransformInspector 的 wide/drawer 单实例结构不变。
- **Gate / Acceptance / Sequence / Audit**：FoundationGate v78、UIV3Acceptance v53；新增 `LayoutEditorOverlayHistoryBindingContract v1`、`LayoutEditorWorkspaceContract v2`、`WorkspaceSessionBindingContract v1` 与 `v3_54_ui_layout_editor_workspace_integration_contract`；Audit 增加 no-sampling、no-direct-persistence、History injection、Session source refresh、lifecycle cleanup fence。
- **验证**：`LAYOUT_EDITOR_WORKSPACE_HARNESS PASS adapterRefresh=3 sourceRefresh=3 persist=1 historyOnly=true partialRejected=true`（非 Native 模拟，真实加载 History/Session/WorkspaceTemplates，覆盖 Record/Undo/Reset/Revert/外部刷新/Apply/Release）；210 个 Active Lua 额外使用 LuaTeX Lua 5.3 `texluac -p` 全量编译 PASS；Foundation Audit PASS（`toc=210 activeLua=210 allLua=210`，全部结构越界 0）；Sequence 的 pure Session preflight 已写入 Gate。Lua 5.3 编译仅为辅助语法证据，项目目标仍为 RU Lua 5.1；Workspace 实际按钮/输入/Z-order 仍以 RU Fresh Reload 为最终证据。
- **下一层**：CURRENT §9.2 进入**状态显示 UI_REVIEW**；先审 UI/交互/设置组织，再决定业务 Feature 重构，不跳过 UI_APPROVED Gate。
- **BuildTag**：`v3-m1.16.0.18.78-ui-layout-editor-workspace-integration`。

## M1.16.0.18.77 — UI Layout Edit Session / Reset-Revert-Apply Persistence Boundary（2026-09-03）

- **执行范围**：继续 Foundation First，零业务 Feature 页面迁移；完成 CURRENT §9.2 第 3 项 `Reset / Revert / Apply Session Semantics + Persistence Boundary`。
- **RSUI v41 / API 12.5 / LayoutEditSession Contract v1**：新增 `ui/framework/rs_ui_layout_edit_session.lua`，建立 `Persisted / SessionBaseline / Working / Defaults` 四态。SessionBaseline 是本次编辑起点/最近 Apply 基线，允许与 Persisted 不同。
- **命令语义**：`Revert` 只恢复 SessionBaseline；`Reset` 只把 Defaults staged 到 Working；二者都不调用 Store/ClearData。只有 `Apply` 调 caller `persistSnapshot`，且必须在 durable write 明确返回 true 后才推进 Persisted/Baseline。
- **Dirty 分离**：`dirty = Working != Persisted`；`sessionChanged = Working != SessionBaseline`。因此当前 Working 尚未持久化但本次 Session 未产生额外编辑时，Apply 可用而 Revert 仍禁用。
- **History Barrier / Integrity Fence**：Session 观察 History Record/Undo/Redo 事件刷新 Working；成功 Revert/Reset/Apply 清 History。Reset/Revert barrier 异常会 best-effort 回滚；durable Apply 后 barrier 异常不伪装回滚 Persistence，而进入 blocked，CommandBar v2 五命令 fail-closed。
- **Persistence Authority**：Session 文件静态门禁禁止直接出现 Runtime `S.Persistence / S.Api / SaveData / ClearData / SaveStore / MarkDirty` 调用；未来 Workspace/Feature Adapter 负责 durable callback。
- **Gate / Acceptance / Sequence**：FoundationGate v77、UIV3Acceptance v52；新增 `v3_ui_layout_edit_session_contract` 与 `v3_53_ui_layout_edit_session_contract`；EditorCommandBar Contract/Session Projection 升 v2 支持 blocked fence。
- **验证**：`LAYOUT_EDIT_SESSION_HARNESS PASS 2 30 1 2`；`LAYOUT_EDIT_SESSION_FOUR_STATE PASS 1 50`；`LAYOUT_EDIT_SESSION_FAILURE_HARNESS PASS 3 3 true`；Foundation Audit PASS（`toc=210 activeLua=210 allLua=210`，全部结构越界 0）。
- **下一层**：CURRENT §9.2 第 4 项 `LayoutEditorWorkspace Integration`，把 History/Session/CommandBar 接入同一 Workspace，不提前迁移业务 Feature。
- **BuildTag**：`v3-m1.16.0.18.77-ui-layout-edit-session-foundation`。

## M1.16.0.18.76 — UI Editor Command Bar Foundation（2026-09-03）

- **执行范围**：继续 Foundation First，零业务 Feature 页面迁移；完成 CURRENT §9.2 第 2 项 `Editor Command Bar`。
- **RSUI v40 / API 12.4 / Command Bar Contract v1**：新增 `ui/framework/rs_ui_editor_command_bar.lua`，固定 `Undo / Redo / Revert / Reset / Apply` 五命令入口。组件只做 Authority Projection，不拥有 Feature Store、Persistence 或 dirty/can* 第二份状态。
- **History Observable Extension v1**：`LayoutEditHistoryModel` 新增 `Subscribe/Unsubscribe`；成功 Record/Undo/Redo/Clear 才事件通知，Preview/Drag Pulse/Cancel 仍不产生 History/CommandBar 更新事件；无 Tick/OnUpdate。
- **Session Fail-Closed**：本轮刻意不定义 Reset/Revert/Apply 语义。Session Authority 未接入时三按钮全部 disabled；未来 Session 必须提供 `GetCommandSnapshot / ExecuteCommand / Subscribe / Unsubscribe`。
- **Busy Fence**：History 或 Session 任一 busy，五命令统一不可执行，避免 Undo 与 Apply/Reset 并发导致半事务。
- **Pure Projection**：新增 `ProjectEditorCommandState()`，允许 Gate/Sequence 不构造 Native Widget 就验证无 Session、Dirty Session 与 Busy 状态。
- **Gate / Acceptance / Audit**：FoundationGate v76、UIV3Acceptance v51；新增 `v3_ui_editor_command_bar_contract` 与 `v3_52_ui_editor_command_bar_contract`；Foundation Audit 增加 Active TOC、observable、no-sampling 与 session-command contract fence。
- **验证**：Foundation Audit PASS（`toc=209 activeLua=209 allLua=209`，全部结构越界 0）；当前容器无独立 Lua runtime，因此新 Sequence 已写入 Gate，最终运行结果继续以 RU/on-demand Gate 为准。
- **下一层**：CURRENT §9.2 第 3 项 `Reset / Revert / Apply Session Semantics + Persistence Boundary`，随后才接回 `LayoutEditorWorkspace`。
- **BuildTag**：`v3-m1.16.0.18.76-ui-editor-command-bar-foundation`。

## M1.16.0.18.75 — UI Layout Edit History / Undo-Redo Foundation（2026-09-03）

- **执行范围**：继续 Foundation First，零业务 Feature 页面迁移；完成 CURRENT §9.2 第 1 项共享 `LayoutEditHistoryModel / Undo-Redo`。
- **RSUI v39 / API 12.3 / History Contract v1**：新增 `ui/framework/rs_ui_layout_edit_history.lua`。History 只记录成功 Commit，Preview/Drag Pulse/Cancel 不入历史；before/after 以 stable key set 为身份边界，duplicate/missing/key-set drift 全部 fail-closed。
- **Bounded Session Memory**：默认 64 条命令、hard cap 256；每条 item 默认 128、hard cap 512；可选非 Rect state 使用 depth/node bound 深拷贝，避免 History 持有 live table 或无限增长。
- **Undo/Redo Transaction**：外部 `apply` 接受后才移动 cursor；异常/拒绝时 cursor 保持不变，并调用 rollback callback（未提供时复用 apply）恢复当前 side；rollback 失败单独计指标，不把半失败伪装成成功。
- **Anchor/Pivot 可逆性**：preserve-visual 锚点修改可能 before/after Rect 相同，因此 Adapter 只记录 `parentRect + rect + anchorX/Y + pivotX/Y` 的最小恢复快照；revision/lastSource 等瞬态字段不进入 History，避免伪 command。
- **PreviewAdapter 集成**：新增 `historyEnabled/historyModel`、`EnableHistory/GetHistoryModel/ApplyHistoryState`；Gesture Commit、Inspector Rect Commit、Single Anchor Commit 在外部 Commit 成功后才 Record；History replay 走受控 Commit 但不再次 Record。多选仍按 stable-key group projection 原子恢复。
- **Gate / Acceptance / Sequence**：FoundationGate v75、UIV3Acceptance v50；新增 `v3_ui_layout_edit_history_contract` 与 `v3_51_ui_layout_edit_history_contract`，Foundation Audit 增加 History Active TOC / bounded / rollback / no-sampling source fence。
- **验证**：`HISTORY_HARNESS PASS 1 1`；`ADAPTER_HISTORY_HARNESS PASS 2 1 10 0`；`MULTI_HISTORY_HARNESS PASS 1 10 210`；Foundation Audit PASS（`toc=208 activeLua=208 allLua=208`，全部结构越界 0）。
- **下一层**：CURRENT §9.2 第 2 项 `Editor Command Bar`，随后定义 `Reset / Revert / Apply` 的 Session/Persistence 语义并接回 `LayoutEditorWorkspace`。
- **BuildTag**：`v3-m1.16.0.18.75-ui-layout-edit-history-foundation`。

## Documentation Authority Consolidation — ToDo 单一入口（2026-09-03）

- 将 `CURRENT_REBUILD_STATUS.md` §9 明确为唯一活动 ToDo / 当前施工队列 Authority；Foundation、用户遗留事项、Product Matrix 后续入口与 RU Fresh Reload 验收统一在同一节管理。
- `PRODUCT_COMPLETION_MATRIX.md` 保留 125 项产品能力库存/完成度 Authority，但移除独立施工优先级，避免与 CURRENT 双 Authority；当前 Foundation Audit 证据同步为 `207/207`。
- `README.md` 新增 ToDo 权威导航和冲突优先级。
- `2026-09-03-pending-handoff.md` 的 #4–#7 已收拢进入 CURRENT §9；生成 `Archive/Handoff/WORKING_HANDOFF_20260903.md` 历史副本。旧 `Docs/Handoff/2026-09-03-pending-handoff.md` 路径应在覆盖后手动删除。
- 本轮仅文档治理，不修改 Runtime/TOC/Store/Schema/Feature 行为，不变更 BuildTag。

## M1.16.0.18.74 — UI Layout Editor Workspace Foundation（2026-09-03）

- **执行范围**：继续 Foundation First，零业务 Feature 页面迁移；把 `.18.71` 的独立 Transform 数学层组合成可复用 Editor Transaction / Overlay / Responsive Workspace。
- **RSUI v38 / API 12.2**：新增 `LayoutEditorPreviewAdapter v1` 与 `LayoutEditorOverlay v1`；`WorkspaceTemplates v3` 新增 `CreateLayoutEditorWorkspace()`。Canvas 统一为 `PreviewHost + EditorOverlay`，Feature Preview 不再负责 Handle/Guide。
- **Transaction v2**：`LayoutEditorGesture v2` 支持 Gesture Begin 动态尺寸约束、`onBegin/onAbort` 与 strict Preview/Commit rejection；`AnchorPivot v2` 增加完整 Snapshot Restore；`TransformInspector v2` 改为 `rectModel + optional anchorModel`，同一实例覆盖 single/multi。
- **Single/Multi Adapter**：Selection revision 是手势 fence；single 使用 AnchorPivot，multi 使用 MultiSelection ProjectionSession；Preview 只更新 working projection，Feature/Persistence Commit 拒绝会恢复 start items/anchor snapshot，不允许半事务。
- **Responsive Workspace**：Wide 右侧 inline Inspector；Compact 使用同一个 Inspector 作为 Drawer，只改变 Geometry/Visibility/Layer，不复制 Binding/Selection/Scroll，不使用未经验证 Native reparent。Toolbar 明示 `左上(0,0) · X→右 · Y→下`。
- **性能**：正常游戏态 0 editor sampling；candidate 只在 Gesture Begin 有界冻结，alignment 关闭时 candidate discovery=0；Pulse 只做 pointer/rect/snap math；Adapter/Multi projection O(selected) 且有 hard cap。
- **Gate / Acceptance / Sequence**：新增 PreviewAdapter / Overlay / Workspace Contract 门禁，并把 Gesture/Anchor/TransformInspector 最低契约提升到 v2；Sequence 新增 Adapter transaction/anchor rollback 与 composition contract。
- **下一层**：先补 `LayoutEditHistory / Undo-Redo + Editor Command Bar + Reset/Revert/Apply` 的共享可恢复编辑语义，再进入状态显示 `UI_REVIEW`。
- **BuildTag**：`v3-m1.16.0.18.74-ui-layout-editor-workspace-foundation`。


## M1.16.0.18.71 — UI Multi Selection Transform Foundation（2026-09-03）

- **执行范围**：继续 Foundation First，零业务 Feature 页面迁移；在 SelectionGeometry/Gesture 与 AnchorPivot 之间补齐 2+ selection 的 Group Bounds → per-child Rect 映射，解决完整 LayoutEditorOverlay 的最后一个核心数学/事务边界。
- **RSUI v35 / API 11.9 / MultiSelectionTransform Contract v1**：新增 `ui/framework/rs_ui_multi_selection_transform.lua`。模型只接受 2+ stable-key rect，默认 maxItems=256、hard cap=1024；single/duplicate/超上限全部 fail-closed，不静默截断 selection。
- **Authority 不重叠**：Group Bounds 的 move/resize/snap 仍由 `RectTransformTransaction + LayoutEditorGesture + GuideResolver` 负责；MultiSelectionTransform 不创建第二个 RectTransform，只把最终/snap-resolved Group Rect 投影回每个 Child。Feature/Store 仍只允许在外层 Commit 后持久化。
- **Projection Session**：`BeginProjectionSession → Project → Commit/Cancel`。Begin 冻结 start child rects/start bounds/base revision；Project 只生成 preview，不改 committed model；Commit 做 revision check 后一次性替换全部 child rect；Cancel 保持 committed model 完全不变。Session 活跃时 SetItems fail-closed，防止手势期间 selection 数据漂移。
- **比例 Resize**：按 Group `scaleX/scaleY` 映射每个 Child 的相对位置和尺寸；纯 Move 等价 scale=1。Session 根据所有 Child 的 minChildWidth/minChildHeight 反推出 `minGroupWidth/minGroupHeight`，未来 Gesture 从 Group 层限制 resize，而不是逐 child clamp 破坏比例。
- **Snap/Inspector 收紧**：`.18.70` SnapSettings 增加输入类型预检，非法值在 commit 前拒绝并保留旧 revision；TransformInspector 新增 TypeValidator，且自定义 SetEnabled 保留 Base Component enabled/alpha/revision 语义。
- **Gate / Acceptance / Audit**：FoundationGate v71、UIV3Acceptance v46；新增 `v3_ui_multi_selection_transform_contract` / `v3_48_ui_multi_selection_transform_contract`；Foundation Audit 门禁 `.18.69~.71` model/inspector/multi source 必须处于 Active TOC，并禁止纯 model 文件拥有 OnUpdate/InteractiveTask。
- **下一层**：允许开始 `LayoutEditorOverlay`，但只能作为 Coordinator：组合 SelectionOverlay/GuideOverlay/Gesture/Single-Multi Transform Adapter/Inspector，不得再造 Pointer Capture、Snap Resolver 或 Rect 数学。
- **BuildTag**：`v3-m1.16.0.18.71-ui-multi-selection-transform-foundation`。最终验证数字见本轮交付记录。

## M1.16.0.18.70 — UI Transform Inspector Foundation（2026-09-03）

- **执行范围**：继续 Foundation First，零业务 Feature 页面迁移；把 `.18.69` Anchor/Pivot + Snap Settings 模型接成可复用 Transform Inspector，但仍不组合完整 `LayoutEditorOverlay`，先避免把“单元素变换”误当成未来“多选整体变换”的最终 Authority。
- **RSUI v34 / API 11.8 / TransformInspector Contract v1**：新增 `ui/framework/rs_ui_transform_inspector.lua`，统一“变换 / 锚点与轴心 / 吸附与参考线”三段 Inspector；默认宽约 286px、两列字段、NumericField 精确输入，X/Y 标签明确 `左-/右+`、`上-/下+`，继续遵守 ArcheAge/CryEngine 左上原点坐标。
- **单一状态 Authority**：Inspector 不保存独立 Transform/Snap 副本；所有字段直接 Binding 到 `AnchorPivotModel` / `LayoutEditorSnapSettingsModel`。`onTransformChanged/onSnapChanged` 仅作为提交后的通知，不拥有 mutation Authority；通知异常只进 Diagnostics，不把已成功的模型提交伪装成半事务失败。
- **Preflight / Enabled 语义**：新增 `TransformInspector` TypeValidator，在创建 Native Root 前验证 Anchor/Snap Model 契约；自定义 `SetEnabled` 继续调用 Base Component `SetEnabled`，保持 Root enabledRevision、Native enabled 与 disabled alpha 一致，再递归驱动字段状态。
- **Snap Settings 输入完整性**：`SetPatch()` 在任何写入前验证布尔/数值字段类型；非法输入 fail-closed 并记录 `lastError`，不会把无效字符串悄悄 Clamp 成 1/0 等合法值。Snapshot 增加 `lastSource/lastError`，成功提交清除错误。
- **Gate / Acceptance / Sequence**：FoundationGate v70、UIV3Acceptance v45；新增 `v3_ui_transform_inspector_contract` / `v3_47_ui_transform_inspector_contract`，门禁 RSUI v34、TransformInspector v1 与 Anchor/Snap 共享模型依赖。
- **架构边界**：完整 `LayoutEditorOverlay` 仍刻意延后。下一层先定义 `MultiSelectionTransformModel`：单元素 Anchor/Pivot、Group Bounds、子元素相对变换、Commit/Rollback 必须先有明确 Authority，避免 Overlay 先落地后再返工多选语义。
- **BuildTag**：`v3-m1.16.0.18.70-ui-transform-inspector-foundation`。最终验证数字见本轮交付记录。

## M1.16.0.18.69 — UI Anchor / Pivot / Snap Settings Model Foundation（2026-09-03）

- **执行范围**：继续 Foundation First；新增纯 Lua editor state model，不创建 Native Widget、不注册 Tick、不修改业务 Store。
- **AnchorPivot Contract v1**：新增 `ui/framework/rs_ui_layout_editor_models.lua`。v1 只支持 9 个常用 Point Anchor + 自定义 normalized anchor `(0..1)` 与 Pivot `(0..1)`；明确暂不引入 UMG Stretch Min/Max Anchor，避免重新解释当前 top-left Rect 持久化。
- **视觉位置稳定**：切换 Anchor/Pivot 默认 preserve visual rect，只重新计算 anchor-relative `positionX/positionY`；Parent resize 则由 Caller 显式选择 `preserveVisual=true` 或 follow-anchor。公式统一为 `anchorAbs + position - size*pivot`，防止不同页面自己发明位置换算。
- **方向语义**：模型提供 `MoveUp/MoveDown/MoveLeft/MoveRight`；其中 `MoveUp(8)` 明确等价 `Y-8`，继续把 CryEngine `+Y=向下` 约束固化到语义 API。
- **Snap Settings Model v1**：统一 `enabled/gridEnabled/alignmentEnabled/canvasEnabled/showGuides/gridSize/threshold/maxCandidates`；`maxCandidates` hard cap=1024。`ToResolverOptions()` 是 GuideResolver 的唯一 Projection，不让页面散落吸附参数。
- **Gesture 性能收紧**：当对象对齐关闭时，Gesture Begin 不调用 `getSnapCandidates()`；只启用 Grid Snap 时 candidate discovery 次数为 0。GuideResolver 在 `enabled=false` 时直接返回 unchanged rect / scanned=0。
- **Gate / Acceptance / Sequence**：FoundationGate v69、UIV3Acceptance v44；新增 `v3_ui_layout_editor_model_contract` / `v3_46_ui_layout_editor_model_contract`，门禁 Anchor/Pivot、Snap Settings、方向语义与 grid-only bounded behavior。
- **BuildTag 过渡**：`.18.69` 为模型层里程碑；同轮继续收敛到 `.18.70` Transform Inspector 后统一交付。

## M1.16.0.18.68 — UI Layout Editor Gesture Transaction Foundation（2026-09-03）

- **执行范围**：继续 Foundation First，零业务 Feature 页面迁移；把 `.18.67` Selection/Guide Surface 接到项目已验证的 Native drag capture，而不是新建 generic pointer capture。
- **RSUI v32 / API 11.6 / Gesture Contract v1**：新增 `ui/framework/rs_ui_layout_editor_gesture.lua`。SelectionOverlay 的整框 `moveHit` 与 8 resize handle 统一走 `OnDragStart → StartMoving → gesture-only InteractiveTask/OnUpdate fallback → OnDragStop`；Controller 不拥有 Store/Persistence，只有 Caller `onCommit` 可以进入业务写入。
- **RectTransform Transaction v2**：增加 `OverridePreview()`；`PreviewDelta → GuideResolver → OverridePreview → Commit` 保证视觉 Snap 与最终提交坐标一致，并继续保持 left/top resize clamp 时 opposite edge 固定。
- **坐标空间 Fence**：Pointer 固定为 viewport-logical。只有 `coordinateSpace="viewport"` 可以 identity conversion；Canvas/Panel local editor 必须提供 `pointerToLocal`，否则创建 fail-closed。方向仍遵循 top-left：`+Y=下 / -Y=上`。
- **Bounded Gesture Performance**：Snap options/candidates 只在 Begin 调用一次并冻结，hard cap=1024；16ms pulse 只做 pointer delta + bounded pure math + 现有 overlay diff write；Scheduler 拒绝时才临时绑定 capture-surface `OnUpdate`，Commit/Cancel/Release 立即解除。Native Geometry Lease 防止 DiffRenderer 与 `StartMoving` 抢 capture surface。
- **Gate / Acceptance / Sequence**：FoundationGate v68、UIV3Acceptance v43；`v3_ui_layout_editor_gesture_contract` / `v3_45_ui_layout_editor_gesture_contract` 门禁 RSUI v32、Gesture v1、RectTransform v2、no-generic-capture；Foundation Audit 同步要求 gesture source 在 Active TOC、candidate freeze/lease/bounded contract 存在。
- **验证**：全量 `202/202 Lua Parse PASS`；Foundation Audit PASS（`toc=202 activeLua=202 allLua=202`，全部结构越界计数 0）；`RSUI_RECT_TRANSFORM_V2_HARNESS PASS upY=92 commit=92,87,88,73`；`RSUI_LAYOUT_EDITOR_GESTURE_HARNESS PASS x=100 y=95 candidates=1 preview=3 leases=1/1`；`RSUI_LAYOUT_EDITOR_FALLBACK_HARNESS PASS x=5 y=12 fallback=1`；`RSUI_LAYOUT_EDITOR_SAMPLING_FAIL_HARNESS PASS leases=0 begins=0`；`RSUI_SELECTION_OVERLAY_MOVE_HARNESS PASS moveIndex=3 handleIndex=4 upY=92`；`RSUI_SELECTION_GEOMETRY_BOUND_HARNESS PASS source=1100 bounded=1024 canvasBound=1024`。
- **BuildTag**：`v3-m1.16.0.18.68-ui-layout-editor-gesture-foundation`。

## M1.16.0.18.67 — UI Selection Geometry / Handle / Snap Foundation + Baseline Recovery（2026-09-03）

- **执行范围**：以用户重新上传的最新整包为唯一基线重新读 Docs/TOC/Foundation；继续零业务 Feature 迁移。
- **覆盖回流修复**：确认 `.18.63` 的历史 UI 文件组在多轮覆盖中局部回流：`UI.ComponentsV2`/旧 TOC、旧 Dropdown degraded behavior、旧 Popup/Z-layer 契约重新出现，而 `.18.64~.18.66` 新层仍存在。按真实调用链恢复 `ComponentsV2 retirement + ContainerSurface + Dropdown fail-closed + PopupCoordinator + UITokens v4`，不使用旧整包覆盖新工程。
- **更强防回流 Audit**：Foundation Audit 新增 Disk Lua ↔ Active TOC 双向门禁；任何磁盘 `.lua` 未列入 Active TOC 都直接 FAIL，使 retired source 不能以“暂时没加载”的方式残留等待未来复活。
- **RSUI v31 / API 11.5**：新增 `rs_ui_selection_geometry.lua`，`SelectionGeometryModel` 与 SelectionModel 分权；提供 multi-selection bounds、8-way handle geometry/hit test、`SelectionOverlay`、`LayoutGuideOverlay` 和有界 `LayoutGuideResolver`。
- **Snap/Guide**：支持 candidate/Grid/Canvas alignment；default candidate budget=256、hard cap=1024；最多 X/Y 各一条 guide；Resolver 不扫描 Widget Tree、不读取业务 metadata。
- **SelectionOverlay**：Root 使用 handleSize/hitSlop inset，确保 resize hit surface 不伸出物理 Parent；`.18.68` 增加整框 Move Hit Surface，创建顺序位于 resize handles 之前以保持边缘 Handle 命中优先。
- **Gate / Acceptance / Sequence**：FoundationGate v67、UIV3Acceptance v42；新增 `v3_ui_selection_geometry_contract` / `v3_44_ui_selection_geometry_contract`，静态 Audit 门禁 SelectionGeometry/GuideResolver/Overlay 与 1024 candidate hard cap。
- **验证**：Selection pure-math harness：`handles=8 alignX=200 grid=100,120 scan=1024`；SelectionOverlay mock：`root=113,83 xGuide=200 yGuide=150`；恢复后 Foundation Audit PASS，并作为 `.18.68` 202/202 全量回归基线继续验证。

## M1.16.0.18.66 — UI Coordinate / Pointer / RectTransform Foundation（2026-09-03）

- **执行范围**：继续 Foundation First，零业务 Feature 页面迁移；先把 ArcheAge/CryEngine 左上原点、Pointer delta 与 editor RectTransform 数学统一成共享 Authority，再进入 Selection/Handle/Snap。
- **RSUI v30 / API 11.4**：`S.Layout.CoordinateSystemContract v1` 明确 `(0,0)=左上`、`+X=右`、`+Y=下`，因此 `MoveUp(distance)` 语义等价于 `Y-distance`。新增 `OffsetPoint/MoveRect/GetCoordinateSystemSnapshot`，页面不得自行猜方向正负。
- **RectTransform Transaction v1**：纯数学 `Begin → PreviewDelta → Commit/Cancel`，支持 move + 8-way resize、min/max extent 与完整 rollback；delta 始终相对 Begin rect，避免逐帧累计漂移。它不捕获 Pointer、不直接写 Native Geometry，因此不会成为第二套 Windowing Authority。
- **Pointer Contract v1**：`RSUI.Pointer` 统一 `GetMouseLogicalPosition` 采样与 start→current delta；`captureSupported=false`，Native `StartMoving/StartSizing` 继续归 Windowing/已有控件。Tooltip 同样复用该 Pointer sampling path。
- **Overlay 审计**：确认 Application `ModalHost` 已拥有唯一 modal scrim。ResponsiveInspector drawer 默认保持非模态 Stable Host；当前不新增第二 Application Scrim Authority。
- **Gate / Acceptance / Sequence**：FoundationGate v66、UIV3Acceptance v41；新增 `v3_ui_geometry_pointer_contract` 与 `v3_43_ui_geometry_pointer_contract`，门禁 top-left coordinate、RectTransform transaction、Pointer v1 与 no-generic-capture policy；Foundation Audit 同步检查 source contract。
- **性能**：无 Tick/常驻 OnUpdate/业务扫描。坐标 helper 为 O(1)；RectTransform 只在显式 editor transaction 内做常数级数学；Pointer 只在事件/手势需要时采样。
- **兼容**：没有 Store Schema/Feature/页面迁移；只把过去隐含的 CryEngine 坐标方向变成显式共享契约。
- **验证**：全量 `200/200 Lua Parse PASS`；Foundation Audit PASS（全部结构越界计数 0）；Workspace/Container/Popup/Composite/Tree/Picker/Focus/Host-Slot/SearchablePicker/IconPicker 全部旧 Harness 回归 PASS；新增 `RSUI_GEOMETRY_POINTER_HARNESS PASS upY=92 resize=90,85,90,75`；Markdown 相对链接 `checked=52 bad=0`。
- **BuildTag**：`v3-m1.16.0.18.66-ui-geometry-pointer-foundation`。

## M1.16.0.18.65 — UI Host / Slot / Responsive Picker Foundation（2026-09-03）

- **执行范围**：继续 Foundation First，零业务 Feature 页面迁移；先审计 Host/Slot/Native Parent/Release 调用链，再补稳定响应式 Inspector 与 SearchablePicker Presentation。
- **RSUI v29 / API 11.3**：新增 `AttachmentContract v1`、`ReparentPolicyContract v1`，公开 `NativeReparentSupported=false`。Component 只有一个 logical parent；跨 Parent、self/ancestor cycle、Native creation parent mismatch 全部 fail-closed。`RemoveChild` 为 terminal release；Child 独立 Release 会先从 Parent `children/slots` 解除强引用。
- **Native Reparent Fence**：当前 RU 没有已验证通用 Reparent；`tools/rs_foundation_audit.py` 新增 Active Runtime 静态 fence，禁止未经证据的 `RemoveFromParent / Reparent / SetParent`。每次 attach 都核对 immutable Native Parent 与目标 `GetContentRoot()`，防止 logical/native Authority 分裂。
- **ResponsiveInspector v1 / WorkspaceTemplates v2**：Content + Inspector 在同一 Stable Host 下一次创建。wide 模式 inline 右栏；compact 模式右侧 drawer，只改 Geometry/Visibility/Raise，不重建、不复制 Binding/Selection/Scroll、不 reparent。新增 `CreateResponsiveInspectorWorkspace()`。
- **Composite Foundation v4 / SearchablePicker v1 / IconPicker v1**：SearchablePicker 复用 `.18.64` PickerModel，组合 TextInput + Search/Clear + StatusChip + virtual ListView；IconPicker 在同一 Model 上组合 virtual TileView + Image + selected preview。两者都只由 Enter/EditEnter 或显式按钮提交 Query，不绑定未验证 OnTextChanged/OnKeyDown/OnKeyUp，不注册 Tick；Icon bind 只消费 Caller 投影的 icon path，不调用业务 Metadata/Native 查询。
- **Gate / Acceptance / Sequence**：FoundationGate v65、UIV3Acceptance v40；新增 `v3_42_ui_host_slot_picker_contract`，门禁 RSUI v29、Attachment/Reparent、ResponsiveInspector/Workspace v2、SearchablePicker v1、IconPicker v1。Snapshot 增加 Attachment/Reparent/ResponsiveInspector/SearchablePicker contract 与相关 metrics。
- **性能**：无业务扫描、无常驻 OnUpdate。ResponsiveInspector 仅 layout/visibility 变化时工作；SearchablePicker/IconPicker 只有显式 Query/Selection 才更新，结果分别使用 ListView/TileView virtual pool；Icon tile bind 只写已投影纹理路径；Host/Slot 校验为有限祖先链（guard 64）+ O(1) Native-parent identity 比较。
- **验证**：`RSUI_HOST_SLOT_HARNESS PASS attachRejects=3 mode=drawer`；`RSUI_WORKSPACE_18_65_HARNESS PASS contract=2`；`RSUI_SEARCHABLE_PICKER_HARNESS PASS results=2 selected=fire`；`RSUI_ICON_PICKER_HARNESS PASS results=2 selected=fire binds=8`；最终全量 Gate/旧 Harness/Markdown 验证见本轮封包记录。BuildTag：`v3-m1.16.0.18.65-ui-host-slot-picker-foundation`。
- **RU 实机边界**：没有业务页面迁移，因此主要 Fresh Reload 风险集中于 Native Parent identity、compact drawer 的真实 Z-order/clip、TextInput Enter 事件与 Focus。未经验证 Native Reparent 仍明确禁止。

## M1.16.0.18.64 — UI Model Integrity Foundation：Transactional Tree / PickerModel / Focus Contract v2（2026-09-03）

- **执行范围**：继续 Foundation First，本轮仍不新增或重排业务 Feature。重点反向审计 `.18.63` Tree/Input/Focus 基础，先消除复杂编辑器未来最危险的稳定身份、半事务状态、默认展开语义和能力误报，再为 SearchablePicker/IconPicker 建共享数据模型。
- **RSUI v27 / API 11.1 / Composite Foundation v2**：`rs_ui_composite_foundation.lua` 升级，新增 `PickerModel v1`，TreeModel 内部升级 v2；`StatusChip v1 / TreeView v1 / PopupCoordinator v1` 保持单一现有 Authority。
- **Tree Stable Identity Contract v1**：节点必须提供 `key/id` 或 caller `getKey()`；彻底删除 path/index fallback。缺 Key → `tree_key_required:<path>`；`getKey/getChildren` 异常、children 非 table、duplicate key 全部显式 fail-closed，禁止排序/插入后 selection/expanded identity 漂移。
- **Tree Mutation Transaction Contract v2**：`SetNodes / SetExpanded / ToggleExpanded / ExpandAll / CollapseAll` 统一使用 staged candidate → build/validate → commit；失败完整保留旧 nodes/rows/maps/expansion/revision，只更新错误信息。专项验证覆盖“duplicate key 隐藏在折叠子树，展开后才暴露”场景，确认操作失败不产生半提交。
- **Tree expansion 三态与长期内存界限**：`true=显式展开 / false=显式折叠 / nil=defaultExpandedDepth`，修复默认展开节点被用户折叠后 Rebuild 又自动展开的问题。新增 `maxExpansionState`（默认 maxNodes×2、hard cap 32768）和 `treeExpansionStatePrunes`，动态树长期切换时旧 key 不无限积累。原 frame-cursor DFS / maxNodes bounded projection 保持。
- **PickerModel v1**：为 Buff/Skill/Item/Route/Icon 等大量选择场景建立 UI-agnostic shared model：稳定 key、transactional SetItems/SetQuery、显式 query、AND token plain match、caller `getSearchText`、stable selectedKey、duplicate/missing key fail-closed；`maxScan` 8192(default)/32768(hard)、`maxResults` 128(default)/512(hard)、token/query 长度均有界，并在 snapshot 暴露 truncation。SearchablePicker/IconPicker 后续只能消费该 Model，不得各造过滤/选择 Authority。
- **Focus Contract v2**：`CanSet / CanClear / GetTargetWidgetId / IsFocused` 改为 target-aware；`GetCapabilities(target)` 不再硬编码 `setFocus=true`，Set/Clear 只有目标 Native 真正支持方法时才宣告能力。逻辑 identity 不能冒充物理 focused widget id。
- **Input Event Fence**：由于 RU 当前仅验证 SetFocus/ClearFocus/GetFocusedWidgetId、Enter/EditEnter/LostFocus，Foundation Audit 新增 Active Runtime fence，禁止在证据不足时绑定 `OnKeyDown / OnKeyUp / OnTextChanged`。未来获得 RU/官方证据后必须升级 Input Contract 再移除 fence，而不是页面 Agent 自行猜事件名。
- **Gate / Acceptance / Sequence**：FoundationGate v64、UIV3Acceptance v39 要求 RSUI>=27、Composite v2、PickerModel v1、Tree Stable Identity v1、Tree Transaction v2、Tree Expansion Bound v1、Focus v2；新增 `v3_41_ui_model_integrity_contract` 覆盖 missing key、hidden duplicate rollback、default-expanded explicit collapse 与 Picker AND-token 投影。`tools/rs_foundation_audit.py` 同步增加 source contract 与回归 fence。
- **性能**：没有新增 Tick/OnUpdate/业务扫描。Tree projection 仍按 maxNodes 有界，frame-cursor traversal 临时内存按深度增长；长期 expansion override 有 cap。Picker 仅显式 SetItems/SetQuery 重建，scan/results/query/token 全有硬上限；Focus 为 O(1) capability/read 操作。
- **验证**：`RSUI_TREE_TRANSACTION_HARNESS PASS contract=2 stable=1`；`RSUI_TREE_DEFAULT_COLLAPSE_HARNESS PASS overrides=2 bounded=3`；`RSUI_PICKER_MODEL_HARNESS PASS contract=1 scan=10`；`RSUI_FOCUS_SERVICE_HARNESS PASS contract=2`；既有 Composite/Tree bounded/Popup/Container/Workspace harness 全部回归通过；全量 **200/200 Lua Parse PASS**；Foundation Audit PASS（`toc=200 activeLua=200 allLua=200 globals=0 presentation=0 rawNative=0 rawScope=0 detachedWidgetState=0 apiDependency=0 apiCapability=0 businessIds=0 auctionEventOwners=0`）；Markdown 相对链接 **0 断链**；Product Matrix 仍为 77/35/2/11，共 125。BuildTag：`v3-m1.16.0.18.64-ui-model-integrity-foundation`。
- **RU 实机边界**：本轮新 Model 尚未接入生产 Feature，所以无业务配置/页面迁移风险。通用 KeyDown/TextChanged 仍明确视为未验证；SearchablePicker 首版必须使用已证实 Edit/Enter/LostFocus 能力或显式提交模式。

## M1.16.0.18.63 — UI Composite Foundation：TreeView / StatusChip + ComponentsV2 退休 + Dropdown Fail-Closed（2026-09-03）

- **执行范围**：继续 Foundation First，本轮不新增、不重排任何业务 Feature 页面；目标是检查 RSUI 底层真实调用链，优先删除第二套 Presentation surface、补跨 Feature 高复用 Composite，并同步完善统一能力/UI 路线图。
- **RSUI v26 / API 11.0**：新增 `ui/framework/rs_ui_composite_foundation.lua`。`StatusChip v1` 统一 neutral/info/pending/success/warning/error/blocked/unavailable 状态语义；Feature 只提供 semantic status，不再各页自造红黄绿协议。
- **TreeModel / TreeView v1**：TreeModel 为 UI-agnostic 纯层级 projection，使用稳定 `key/id`、独立展开态、迭代式 bounded flatten（默认 4096 / hard cap 16384）、duplicate-key fail-fast；宽树审计进一步改为 frame-cursor DFS，不再 push-all-children，临时内存按遍历深度有界。TreeView 复用现有 `ListView` virtual pool、SelectionModel 与 stable key，只为可见行创建/绑定 indent + chevron + label，不注册 Tick/OnUpdate。
- **Dropdown degraded fail-closed**：Popup 构建失败时保留当前值并显示 `⚠`，Native control 禁用，`Open/ToggleOpen/Scroll/click` 均不改变值；删除旧“弹层失败后单按钮循环切换选项”的隐式交互变形。正常 Popup 路径不变。
- **PopupCoordinator v1 / UITokens v4**：Dropdown、ColorField、ContextMenu 统一到一个 weak registry；Open 前 `CloseAll(except)`，ColorField Disable/Release 自动关闭并 unregister，ContextMenu 统一 system layer / popup priority。`DropdownService` 仅为同一 coordinator 的兼容 alias。`UITokens.layer.popupPriority=10000` 成为唯一 Popup Z priority token，静态 Audit 禁止当前 popup surface 重新写 magic literal。
- **Input/Focus 结论**：当前 RU 证据支持 SetFocus/ClearFocus/GetFocusedWidgetId 与 Enter/EditEnter/LostFocus，但未验证 generic OnKeyDown/OnKeyUp 或实时 OnTextChanged；因此 SearchablePicker/IconPicker 暂不伪造桌面键盘交互，后续先做 evidence-safe 的显式搜索提交。
- **`UI.ComponentsV2` 退休**：调用链确认剩余真实 Consumer 仅为 RSUI 自身 Card/Section/FormSection。Card 改由 RSUI 直接创建，Section/FormSection 收敛到 `RSUI.ContainerSurface:CreateSection()`；同时保留旧 Native root 的 `_card` / `_section` identity 规则，避免清理底层顺带改变物理控件身份。`ui/framework/rs_ui_components_v2.lua` 从 Active TOC 与物理工程删除，`rs_ui_framework.lua` 同步删除 ComponentsV2 metrics/snapshot 钩子。历史文档保留旧接口作为演进证据，但明确标记 SUPERSEDED。
- **防回流 Gate**：`FoundationGate v63`、`UIV3Acceptance v38` 增加 Composite Foundation / StatusChip / TreeView / Dropdown fail-closed Contract；`tools/rs_foundation_audit.py` 新增 retired UI layer 静态 fence，禁止 `UI.ComponentsV2` / `Create*V2` component helper 或旧文件重新进入 Active Runtime，并要求 composite source 在 TOC。
- **Sequence / Harness**：新增 `v3_40_ui_composite_foundation_pure_contract`，覆盖 TreeModel 初始折叠、展开/折叠、duplicate key、bounded/truncated projection；开发 harness `RSUI_COMPOSITE_MODEL_HARNESS PASS rows=2 treeRebuilds=4`；`RSUI_TREE_BOUNDED_MEMORY_HARNESS PASS rows=64 siblings=20000 peakFrames=2 exactTruncated=true`；`RSUI_POPUP_COORDINATOR_HARNESS PASS closed=b`；`RSUI_CONTAINER_SURFACE_HARNESS PASS created=7` 验证 Section/Card 物理 ID 兼容、标题更新与 extent/layout 路径。
- **文档同步**：`CURRENT_ARCHITECTURE`、`CURRENT_REBUILD_STATUS`、`RSUI_ARCHITECTURE`、`CORE_ARCHITECTURE` 与 `REBUILD_REFERENCE_ADDON_CAPABILITY_ROADMAP` 同步更新；路线图将 TreeView/StatusChip 标记为 Foundation v1 已实现，并明确下一批先审计 Input/Focus/Popup 生命周期，再考虑 SearchablePicker/IconPicker、ResponsiveInspector/Drawer、LayoutEditorOverlay。
- **验证**：全量 **200** 个 Lua `texluac -p` PASS；Foundation Audit PASS（`toc=200 activeLua=200 allLua=200 globals=0 presentation=0 rawNative=0 rawScope=0 detachedWidgetState=0 apiDependency=0 apiCapability=0 businessIds=0 auctionEventOwners=0`）；Markdown 相对链接 **0 断链**。BuildTag：`v3-m1.16.0.18.63-ui-composite-foundation`。
- **RU 实机边界**：TreeView/StatusChip 尚未接入生产 Feature，业务行为风险低；但 Card/Section/FormSection 的 Native root 创建路径已收敛，Fresh Reload 应遍历现有页面确认几何/标题/Form section 无视觉回归。另需在开发环境故障注入 Dropdown Popup 创建失败，确认只读 `⚠` 路径不误改配置。

## M1.16.0.18.62 — UI Workspace Foundation：页面级组合模板 + 详细页面设计路线图（2026-09-03）

- **执行策略**：正式切换为 Foundation First。现有 RSUI Primitive/Panel/DataView/Form/Windowing 保留为唯一 UI Authority，不推倒重来；先补跨页面重复的 Workspace Composition，再逐页把 UI 从 `UI_DRAFT` 讨论到 `UI_APPROVED`，最后进入业务页面重排。
- **RSUI v25**：新增 `ui/framework/rs_ui_workspace_templates.lua`，只组合已有 `VerticalBox / HorizontalBox / UniformGrid / SplitView`，不读业务数据、不持久化 Feature 状态、不注册 Tick/OnUpdate。
- **四个首批 Workspace Template**：`CreateMasterDetailWorkspace`（主从/列表详情）、`CreateInspectorWorkbench`（左 Navigator + 中 Preview + 右 Inspector）、`CreateSettingsWorkbench`（分类设置工作台）、`CreateCommandCenterWorkspace`（Status Strip + Overview/Exception Queue + Evidence）。
- **统一页面策略**：`UITokens v3` 新增 Breakpoint（720/980/1180）与 Workspace Rail/Inspector/Preview 几何 token；新增 `WorkspaceTemplates.BreakpointPolicy` 与 `DensityPolicy`，页面不再各自发明 compact/wide 决策。
- **Foundation Gate**：`v3_advanced_ui_contract` 升级为 RSUI v25 + WorkspaceTemplates v1 必须存在，四个公共构建入口缺失即 blocker。
- **设计文档**：`REBUILD_REFERENCE_ADDON_CAPABILITY_ROADMAP.md` 扩充为能力 + 页面 UI 单一讨论总表；Gear、Buff Display、Unit Lines、Range Assist、Healer/Raid、Boss、DPS/Analytics/Death Review、Activities/Tasks、Bonds、Trade/Craft、Treasure/Fishing、Title/Profile、Diagnostics 均补充组件树、栏宽/行高、对齐、compact 降级和 Foundation 依赖。明确下一批候选 `TreeView/OutlineView / SearchablePicker / IconPicker / ResponsiveInspector/Drawer / StatusChip / LayoutEditorOverlay`，缺组件时优先下沉 Foundation，禁止页面临时复制。
- **验证**：全量 **200** 个 Lua `texluac -p` PASS；`RSUI_WORKSPACE_TEMPLATE_MOCK PASS`（四模板构造 + Breakpoint Policy）；Foundation Audit PASS（`toc=200 activeLua=200 allLua=200 globals=0 presentation=0 rawNative=0 rawScope=0 detachedWidgetState=0 apiDependency=0 apiCapability=0 businessIds=0 auctionEventOwners=0`）；Docs Markdown 相对链接 0 断链。BuildTag：`v3-m1.16.0.18.62-ui-workspace-foundation`。
- **RU 实机边界**：本轮没有把四个模板强行替换进现有生产页面，因此不改变 Gear/Healer/DPS 等业务行为；后续实际页面采用模板后仍需要 1024×768 / 1080p 拖动、缩放、Scroll、Split divider 与视觉密度 Fresh Reload 目测。

## M1.16.0.18.61 — Runtime Recovery：换装事务 / 单位连线布局 / 范围颜色 / 居民板识别（2026-09-03）

- **换装**：`GearV3` 升 v3。移除“bagId 0/1 视图不一致即整单取消”的错误安全门，按 RU 已验证 gearswap 行为固定以 `bagId=1` 作为物理槽候选 Authority，`X2Bag:Capacity()` 只决定有界扫描上限（150 fallback / 240 hard cap）。战斗中不再整单拒绝：只构建 16/17/18/19 武器优先队列并逐件重读验证；防具/饰品/称号显式延后，脱战再次执行补齐。
- **单位连线**：四个关系开关与公共参数改为 2 列 UniformGrid；四类每线外观改为独立卡片（标题 / 点数+大小 / ColorField），不再把标签、两个 NumericSetting 和颜色压进 28px 单行。
- **范围辅助**：`color` 正式加入 Permanent default/state contract，修复 SetColor 只改内存、Reload 后丢失；`ColorField` 触发器始终显示“标签 + #RRGGBB”，即便 RU Native 未提供 `CreateColorDrawable` 也能发现并操作颜色。`RangeAssist.VisualGuideContractVersion=3`，`UIV3Acceptance v37` 门禁 SetColor。
- **债券 / 居民板**：Board 1..7 每类只读取一次；归一化 `contents/content/rows/items` 与稀疏数字索引；位置识别恢复 RU 已验证规则（3+4 非空=大陆，5/6 非空=原大陆），只投影真实非空内容；`unavailable` 与“当前位置无内容”明确分离，并把 scope/faction/error 暴露给页面诊断。
- **验证**：`GEAR_SERVICE_V3_HARNESS PASS`（bagId1/bagId0 内容冲突不再误阻断；战斗仅切武器并留下 pending；脱战补齐防具）；全量 199 个 Active Lua `texluac -p` 通过；Foundation Audit PASS（`toc=199 activeLua=199 allLua=199 globals=0 presentation=0 rawNative=0 rawScope=0 detachedWidgetState=0 apiDependency=0 apiCapability=0 businessIds=0 auctionEventOwners=0`）；`BONDS_BOARD_SHAPE_HARNESS PASS`；`VISUAL_CONFIG_CONTRACT PASS`；Markdown 相对链接 0 断链。BuildTag：`v3-m1.16.0.18.61-runtime-recovery`。

> **⚠️ 架构变更声明（2026-09-01/02）**：旧版（Legacy/Professional）源码已全部物理删除（163 文件、−10.3 万行，commit 09010c0）。本文件是历史变更日志，早期条目（M1.16.0.18.x 及之前）可能引用已删文件（`rp_*`/`rh_*`/`rg_*`/`rdps_*`/`modules/professional/`/`S.State`/`S.Storage`/`rs_state`/`rs_storage`/`rs_module_manager`/`rs_module_sandbox`/`ReplicatedSuiteModuleSandbox`/`ReplicatedHealerModule`/`ReplicatedPlatesModule`/`ReplicatedDps` 等）。这些引用仅作历史记录，不代表当前代码。当前架构以 [`CURRENT_ARCHITECTURE.md`](CURRENT_ARCHITECTURE.md) 为准。

## M1.16.0.18.60 — 治疗辅助 团队名单识别 / 色块覆盖 / 校准 / 设置 重构：RaidTeam≠RaidPanel≠Calibration 解耦（2026-09-03）

- **背景（先查架构后动手）**：原实现把团队身份（`teamIndex`）与屏幕 `sections[4]` 四个固定区域强绑定——即"列表 A 永远等于团队 1"的反模式，且 50 个槽位用固定坐标写死，切换团队必须重新校准。这违背「谁拥有这个事实」原则：`RaidTeam`（数据身份）≠ `RaidPanel`（屏幕列表容器）≠ `Calibration`（面板几何）。
- **架构解耦（核心）**：引入 `panels{A,B}` 矩形模型。每个 Panel 拥有自己的 `{x,y,width,height}` 整面板包围盒，槽位由几何**派生**（非 50 个固定坐标）；`team` 绑定挂在 Panel 上、可运行时切换而**不触碰几何**。身份权威仍复用 `TeamRosterV3`（成员 `teamIndex` 0/1/2、`memberIndex` 1..50、`isSelf`）。overlay 按 `member.teamIndex` 映射到绑定该团队的 Panel；`team==0 && isOnly` 时归 Panel A（玩家自身）。
- **三模式**：`auto`（由 TeamRosterV3 实际在场团队派生）、`single`（Panel A 显示 singleTeamId 指定团队、唯一面板、切换不重校准）、`dual`（Panel A/B 显示任意团队组合）；`GetEffectivePanelBindings()` 解析出有序绑定列表 `{id,team,geometry,isOnly}`。
- **文件改动**：
  - `features/combat/healer/rs_healer_store.lua`：SCHEMA 3→4；弃用 `sections[4]`/`calibrationSection`/`calibrationScope`，改为 `panels{A,B}` + `mode`/`singleTeamId`/`testColors`/`slotNumbers`/`showMyself`；新增 `DefaultRaidPanel(s)`/`MigrateSectionsToPanels`/`NormalizeRaidPanel` 及 `SetRaidPanelRect/SetRaidPanelTeam/SetRaidMode/SetRaidSingleTeam/SetRaidTestSetting/ResetRaidLayout`。
  - `features/combat/healer/rs_healer_feature.lua`：`GetEffectivePanelBindings()`（auto/single/dual 解析）、`LocateSelf()`、`Commands` 面板门面。
  - `features/combat/healer/rs_healer_recommendation_v3.lua`：`GetRaidDisplayProjection` 行身份改为 `teamIndex`/`isSelf`/`memberIndex`（对齐 Healer.Roster 投影）。
  - `presentation/v3/widgets/rs_v3_healer_raid_overlay.lua`：全量重写——2 面板×50 槽位对象池、矩形 `LayoutPanel` 派生网格、按 team 绑定映射、`v3.healer.updated`/`v3.healer.locate_self` 事件驱动（非逐帧全扫）、测试色模式、`locate_self` 闪烁。
  - `presentation/v3/pages/rs_v3_healer_page.lua`：新增「团队/面板」组（模式下拉、单团队选择、A/B 团队绑定、测试色/槽位号开关、定位自身按钮），`ApplyRaidTeamVisibility` 按模式显隐对应控件。
  - `core/rs_foundation_gate.lua` + `features/combat/healer/rs_healer_aura_acceptance.lua`：契约由 `SetRaidSectionRect`→`SetRaidPanelRect`、SCHEMA 3→4、`visual_store_contract` 校验 `raid.panels.A/B`。
- **配置迁移**：旧 `sections[4]` 在 `NormalizePresentation` 中由 `MigrateSectionsToPanels` 折叠为 `panels{A,B}` 两个整面板包围盒，用户校准布局以矩形整体保留（非丢失）；全新存档走默认 `panels` 矩形。向后兼容、无人工迁移步骤。
- **验证（本轮回测实测数字）**：面板绑定 harness `.workbuddy/tmp/healer_raid_panel_harness.lua` **55/55 PASS**（默认面板模型 / 旧 sections→panels 迁移 / Set* 命令 / 钳制与非法输入守卫 / Commands 门面委派 / GetEffectivePanelBindings auto·single·dual 11 个子例）；全量 Lua 5.1 `luac -p` 语法门禁 8 文件全 PASS；Foundation Audit **PASS**（`toc=199 activeLua=199 allLua=199 globals=0 presentation=0 rawNative=0 rawScope=0 detachedWidgetState=0 apiDependency=0 apiCapability=0 businessIds=0 auctionEventOwners=0`）。
- **未验证项（RU 实机）**：覆盖色块实绘与坐标投影精确度、事件驱动 100 人刷新手感、双列布局目测、`locate_self` 闪烁、`testColors`/`slotNumbers` 实际呈现——需 Fresh Reload 目测；矩形校准几何已静态确认（派生网格、非 50 固定坐标）。
- BuildTag：`v3-m1.16.0.18.60-healer-raid-panel-model`。

## M1.16.0.18.59 — 截断文字悬浮提示跟随光标（issue #2，2026-09-02）

- **背景（先查架构后动手）**：用户反馈②文字显示不全时悬浮提示窗口不在鼠标位置出现。按「每个功能前先查底层架构是否支持」原则核查 `RSUI.Tooltip`（`ui/framework/rs_ui_interactions.lua`，v3）：其 `Show` 优先走原生 `SetTooltip(text, widget)`（由客户端导出、把提示锚定到所绑定的 widget 单元格、而非光标），命中即 `return`，而**真正读取 `PointerPosition()` 做光标跟随的逻辑只存在于 pooled fallback 分支**（lines 177–194 的 `AnchorRect`+`SetAnchor`）。所以"提示不出现在鼠标位置"的根因是：截断类提示走了原生 `SetTooltip`，被钉在单元格而非跟随光标。底层架构其实已具备光标跟随能力，只是对 hover/overflow 类提示未启用。
- **修复（`rs_ui_interactions.lua`）**：
  1. `Show` 在选路前先采样 `local mouseX, mouseY = PointerPosition()`；当 `options.cursorFollow == true` 时，跳过原生 `SetTooltip` 分支，直接进入带光标跟随的 fallback（与下方 fallback 分支一致读取 `PointerPosition` 并在 `mouseX~=nil` 时 `px,py = mouseX+gap, mouseY+gap` 并在越界时翻转）。默认（非 cursorFollow）行为不变，仍优先原生。
  2. `BindOverflowText`（截断文字路径）在落 binding 时显式 `binding.cursorFollow = true`，使所有 `GetOverflowTooltipText` 类提示强制走光标跟随 fallback，不再钉在单元格。
- **架构接口核对**：`PointerPosition()` 经 `S.Api:GetMouseLogicalPosition()` 取坐标；已核对真实 `rs_api.lua` 契约——该函数返回 `(x, y, nil)`（坐标取前两个返回值），与 fallback 分支的 `tonumber(x)` 用法对齐；`SetTooltip` 为原生全局导出，在 RU 客户端常态可用，故此前路径恒定命中原生、提示恒钉单元格，与用户观察一致。`RSUI:IsComponent(value)`（`rs_ui_component_core.lua:1155`）检查 `type(value.GetRoot)=="function" and value.kind~=nil`，已据此校正 harness fixture（原 stub 用 `__isComp` 且按位置取参，触发 colon-call 陷阱）。
- **验证（录制式 harness 实测）**：`tooltip_cursor_follow_harness.lua` 加载真实 `rs_ui_interactions.lua` + 桩 `S.UI/S.RSUI/S.Api`，三用例全 PASS：`TOOLTIP_CURSOR_FOLLOW_HARNESS_PASS cursorFollowSkipNative=true overflowBindsCursorFollow=true`——A) `cursorFollow=true` 跳过原生 `SetTooltip`、fallback 在光标 (110,110) 打开；B) 默认路径仍走原生（返回 `"native"`）；C) `BindOverflowText` 强制 `cursorFollow=true`，进入提示时跳过原生、在光标 (110,110) 打开 fallback。Foundation Audit 全 PASS（`toc=199 activeLua=199 allLua=199 globals=0 presentation=0 rawNative=0 rawScope=0 detachedWidgetState=0 apiDependency=0 apiCapability=0 businessIds=0 auctionEventOwners=0`）。BuildTag：`v3-m1.16.0.18.59-tooltip-cursor-follow-overflow`。
- **未验证项（RU 实机）**：fallback 提示在真实客户端下弹层位置/层级/鼠标坐标采样是否稳定、OnEnter 一次性采样 vs 拖动跟随手感——需 Fresh Reload 目测（fallback 仅 OnEnter 采样一次，不做 OnUpdate 跟随，符合原生 tooltip 行为）；`SetTooltip` 原生路径在无鼠标坐标的设备上仍作为兜底保留。

## M1.16.0.18.58 — ColorField 基础组件 + 单位连线/范围辅助线条颜色（issue #1+#3，2026-09-02）

- **背景（先查架构后动手）**：用户反馈①单位连线面板设置太杂乱（不像高端 UI 布局）、③范围辅助与单位连线都缺线条颜色设置。按「每个功能前先查底层架构是否支持」原则核查：RSUI 声明式组件库中没有颜色选择器，因此第一步是完善底层基础组件 `RSUI:ColorField`，再以新组件去落地两层线条颜色，而非在页面层硬塞一堆原生滑块。
- **新基础组件 `RSUI:ColorField`（`ui/framework/rs_ui_controls.lua`）**：点击色块（实时颜色预览）+ 弹层内 R/G/B 三个 Slider + hex 文本输入（提交走 `onSubmit`）。get/set 携带 `{r,g,b}`（0..1），复用 `RSUI:Binding` 的提交链，弹层用 `UIParent` 物理层 + `system` 层级避免被 ScrollBox/卡片裁剪。`c:ApplyColor` 经 `:Render()` 把通道 Slider 视图从 `c.color` 重新同步（不二次提交），hex 输入经 `ParseHex` 解析。
- **单位连线去杂乱（`presentation/v3/pages/rs_v3_business_pages.lua`）**：四种关系（target/targettarget/focus/focustarget）原来每行内联 3 个 `CompactNumericSetting` R/G/B 滑块（用户指的"杂乱"）→ 各替换为单个 `ColorField`；swatch 默认色取 presenter `UNIT_COLORS` 同款调色板（`UNIT_LINE_PALETTE`），未持久化前即与渲染线条一致。set → `feature.Commands:SetPairColor(pairKey, r, g, b)`。
- **范围辅助补颜色控件**：范围辅助原**完全没有**线条颜色控件 → 新增 `ColorField` 写入 `feature.Commands:SetColor`。配套在 `features/rs_business_bridge.lua` 补 `SetColor` Command（clamp 0..1，经 `PersistStateMutation` 持久化）并暴露 `color` 投影；presenter `presentation/v3/widgets/rs_v3_combat_visual_guides.lua` 的 `RenderRange` 读 `projection.color` 落点给 `PlaceDot`（缺省回退原 `(0.20, 0.82, 1.00)`）。
- **录制式 harness 验收发现并修复 1 个真实生产 Bug**：`business_page_color_harness.lua` 加载真实 `rs_ui_controls.lua` 构建真实 ColorField，模拟拖动 R 通道 → 触发 `rs_ui_controls.lua:908 attempt to call a nil value (global 'Clamp01')`。根因：内部每通道 Slider 的 `set` 闭包引用 `Clamp01`，而 `Clamp01` 在 Lua 中声明为 Slider 循环**之后**的 `local function`——Lua 闭包不会捕获晚声明的局部，该名被解析为全局，用户拖动任一颜色通道即崩溃。修复：将 `Clamp01` 声明上移到 Slider 循环之前（同作用域、循环前可见）。经小样本 Lua 复现确认该前向局部引用语义确为全局绑定（非本机工具链之误），即真实 RU 客户端同样会崩。
- **验证（本轮回测实测数字）**：录制 harness `BUSINESS_PAGE_COLOR_HARNESS_PASS unit=4 range=1 oldSlidersRemoved=true refreshOk=true`（4 个 per-pair ColorField 的 set 确调用 `SetPairColor`、1 个 range ColorField 的 set 确调用 `SetColor`、旧 3×R/G/B 滑块确认移除、两页 `Refresh()` 不崩）；Foundation Audit 全 PASS（`toc=199 activeLua=199 allLua=199 globals=0 presentation=0 rawNative=0 rawScope=0 detachedWidgetState=0 apiDependency=0 apiCapability=0 businessIds=0 auctionEventOwners=0`）。`rawNative=0 rawScope=0` 证明新组件零原生泄漏。BuildTag：`v3-m1.16.0.18.58-colorfield-foundation-unitlines-range-color`。
- **未验证项（RU 实机）**：ColorField 弹层在真实客户端的位置/层级/鼠标跟随、拖拽手感、hex 输入交互、范围辅助落点颜色实绘——需 Fresh Reload 目测；`Clamp01` 修复为纯作用域移动、已静态确认。

## M1.16.0.18.57 — V3 页面布局优化（gear/healer 迁 RSUI 模版）+ 底层预存在全局泄漏修复（2026-09-02）

- **背景**：用户要求用新增的底层 UI 框架/模版优化布局。本轮落地两块页面级迁移（WU1/WU2），并在验证门禁（Foundation Audit）中发现并修复两个预存在的全局泄漏（属未动过的旧文件，与布局改动无关，但阻塞门禁变绿）。
- **WU1 `rs_v3_gear_page.lua`（4 个像素钉死原生控件 → RSUI 声明式组件）**：`createEdit`/`createButton`/`nameEdit`/`saveName` 由手写 `Border`+`Text`+像素 `x/width` 钉位改为 `RSUI:TextInput`/`RSUI:Button`，统一进 `RSUI:HorizontalBox`（slot 宽度 54/55 为 RSUI 槽宽，非像素钉死）。新增 `SetNativeText`/`GetNativeText` helper 在 `widget:SetValue`/`widget:GetDraftValue` 之间路由（组件 API 优先、原生 `S.UI:SetText` 兜底）；`SafeNativeClick` 改为在 `widget.root` 上绑 `OnClick`。旧像素钉（x=4/137/138、width 130/129）经 grep 确认仅残留在注释中，源码已无。
- **WU2 `rs_v3_healer_page.lua`（4 个手写标题分组框 → RSUI:GroupBox）**：`settings_panel`/`visual_panel`/`advanced_panel`/`calibration_panel` 由 `variant="card"` 的 `RSUI:Border` + 独立标题 `Text` 改为 `RSUI:GroupBox`（title 移入 spec、原标题 `Text` 物理删除、内容 `VerticalBox` 作为首个 child 成为 content）。`visual_panel` 初始 `visible=false` 保留（tab 默认落在策略页）；`advancedHeader` + `advancedCloseButton` 保留并正确 parented（关闭按钮 onClick 链路不动）；现有 `SetVisibility` tab/显隐接线完整保留。判定用 GroupBox 而非 CollapsibleGroup——4 个均为 tab/按钮显隐的带标题框，无"点标题折叠"需求。
- **WU3 `rs_v3_business_pages.lua`（表视图状态覆盖）**：逐行盘点结论——本文件**不存在手写 label→value 展示行**，原 WU3 设想"把 `fill=1` 行换成 `RSUI:KeyValueRow`"对这份文件不成立：其 `fill=1` 槽位绝大多数是 `D:CompactNumericSetting` 滑块（控件）、动态状态 `RSUI:Text`（`SetText`+`SetLabelTone` 手搓的复合状态行）、`RSUI:TextInput`/`Dropdown`/`Toggle`（输入控件），数据展示走 `TableView`。真正的缺口是 **`tableView` 从不调用 `SetViewState`**（全文件 0 次），而所有兄弟 V3 表格页（activity/buff_display/death_review/task/life_economy…）都驱动空态/加载/不可用遮罩。在 `root:Refresh()` 末尾按既有的 `enabled`/`#rows` 信号补 `tableView:SetViewState`：`enabled~=true → "unavailable"`（带标题"功能已关闭"）、`#rows==0 → "empty"`（标题"暂无数据"）、否则 `"ready"`。桩 harness `business_pages_wu3_test.lua` **10/10 PASS**（disabled→unavailable / enabled+0rows→empty / enabled+rows→ready / boss_alerts 同路径 / unavailable 带 title，基线先 FAIL 证明缺口后 PASS）。`hint` 复合状态行保留不动（非 KV 对，StatusRow 不适用）。
- **验证门禁（Foundation Audit 前置修复）**：重跑审计 FAIL（`globals=2 presentation=1`）。根因均为预存在且非本轮引入：
  - `presentation/v3/widgets/rs_v3_buff_head_markers.lua:334` `function ComputePlateLayout(...)` 是非 local 全局函数定义（line 434 才 `P.ComputePlateLayout = ComputePlateLayout` 暴露）；改为 `local function`，table 赋值照常生效，全局泄漏消除。
  - `features/combat/buff_display/rs_buff_display_acceptance.lua:227` `if rows[1].name ~= "A"` 在第二个 `RegisterSequenceCase` 闭包里引用 `rows`，但该 `rows` 定义在第一个闭包（line 74）的 local 作用域——跨闭包孤儿引用，运行时 `rows[1]` 直接抛 "attempt to index a nil value"（plate_geometry 验收用例会崩溃）。改为在第二个闭包内自包含重投影（buff 条目 101 "A"），消除崩溃并保留 name 透传断言。
  - 重跑审计 **PASS**：`toc=199 activeLua=199 allLua=199 globals=0 presentation=0 rawNative=0 rawScope=0 detachedWidgetState=0 apiDependency=0 apiCapability=0 businessIds=0 auctionEventOwners=0`。
- **验证（本轮回测实测数字）**：WU1 桩 harness `.workbuddy/tmp/gear_page_wu1_test.lua` **20/20 PASS**（4 控件为 RSUI TextInput/Button、maxLength 32/36、OnClick 绑 `.root`、LoadDraft 经 SetValue 非原生、CreateSet/RenameOnly/Save 经 GetDraftValue+SetValue）；WU2 桩 harness `.workbuddy/tmp/healer_page_wu2_test.lua` **28/28 PASS**（4 面板为 GroupBox 且 title 正确、content child 已挂、visualPanel visible=false 保留、4 标题 Text 删除、advancedHeader/closeButton parented 完好、SetVisibility tab 接线驱动分组）；`luac -p` 布局+门禁 4 文件语法全 PASS；Foundation Audit 全 PASS（见上）。`rawNative=0 rawScope=0` 证明布局改动零原生泄漏、零新增 presentation 逃逸。
- **未验证项（RU 实机）**：GroupBox 原生 Border+标题条构建、`gear` TextInput/Button 交互行为、tab 切换显隐动画——需 Fresh Reload 目测；ComputePlateLayout 为纯几何函数无 native 副作用、已静态确认（audit 的 presentation-escape 仅因全局定义，改 local 后零残留）。

## M1.16.0.18.56 — tools_social 社交名单完善：保守归一化 + 诚实状态聚合 + IsFriend 点查（2026-09-02）

- **背景**：`tools_social`（社交名单，registry `migrated_m16_18`、能力门 8 API 全 OfficialEnabled、`RU_RUNTIME_ACCEPTANCE.md` Social 验收路线）此前 read 仅 11 行——`pairs` 直读名单表、无形态守卫、无行数上限、失败与空名单不可区分（三读全败仍报 `empty`，违反 §30 Unknown vs Empty / UI-STATE-001），且 `SetOnClick` 式猜形态渲染会把 table 地址当名字显示。本轮按「Better, not copied」在 V3 框架内补齐（参考工程仅作功能灵感；X2Friend 调用形态以 `api_functions.lua` Allowed functions 为签名权威）。
- **读侧重构（`rs_business_bridge.lua`）**：
  - 保守多形态归一化 `NormalizeSocialList`：数组-表（`name`/`characterName`/`memberName`/`charName`）、数组-名字串、名字键表三形态皆收；`count` 等标量哈希字段按元数据跳过；纯键表回退按 key 排序保证确定性；数组段优先（ipairs 语义）。
  - 无可用名字的条目渲染为显式「未识别条目」行（memberName=nil、muted），绝不伪造名字，并把状态降级 `partial`（RU 契约待实证的诚实信号）。
  - 每名单有界 `SOCIAL_LIST_MAX_ROWS=200` + 截断显式注记（`SOCIAL_LIST_SCAN_LIMIT=1000` 扫描护栏），超大名单不再冲爆投影。
  - 诚实状态聚合：单名单失败逐一名单进 error；三读全败 → `unavailable`（0 行不再伪装 empty），部分失败或存在未识别 → `partial`，全 ok 空 → `empty`，否则 `ready`。
  - 行身份字段：`memberName`/`listKind` + 保守可选事实（`online`/`isOnline`/`loggedIn` 布尔、`level`/`growLevel` 数值；未知显示「在线状态未知」，不猜）。
  - **native arity 纪律**：`GetFriendList(allMember=true)`（清单签名带布尔）显式传参；`GetBlockList()/GetMuteList()` 零参——旧代码路径存在给零参方法传 nil 改变 native arity 的隐患，已按清单签名修正。
- **新增 `IsFriend` 命令**：消费已登记但零使用的 `X2Friend:IsMyFriend(charName)` 点查；返回三态文案「是好友/非好友/好友状态未知（返回形态待 RU 实证）」，能力门拒绝/冷却原样透传。
- **页面（`rs_v3_business_pages.lua`）**：tools_social 列表行可选（行点击载入名字进操作框，未识别行惰性跳过，`SetValue` 签名与拍卖收藏行先例一致）；新增「查好友」按钮（info 命令只报事实、不 Refresh 不脏 Authority）；`socialInput/socialStatus` 提升作用域；提示文案更新（写操作遵守官方 1 秒冷却）。
- **验收**：`rs_v3_acceptance.lua` `social_action_contract` 增加对 `Commands.IsFriend` 的存在性要求。
- **验证**：新 harness `social_feature_harness.lua` **31/31 PASS**（加载**真实** bridge、脚本化 S.Api 驱动真实 read/commands 路径：三形态归一化/元数据跳过/确定性 key/未识别 partial/全败 unavailable/部分败 partial/空名单/200 截断/零参 arity 断言/写 false 透传/空名拒绝不入门/IsFriend 三态+门失败）；回归 RSUI **68/68**、price_quote **14/14 + 8/8**；`luac -p` 三改动文件通过；Foundation Audit **PASS**（`toc=199 activeLua=199 allLua=199 globals=0 presentation=0 rawNative=0 rawScope=0 detachedWidgetState=0 apiDependency=0 apiCapability=0 businessIds=0 auctionEventOwners=0`，toc 双向 0 差异）。
- **未验证项（RU 实机）**：X2Friend 名单真实返回字段（名字/在线/等级字段名）待 Fresh Reload 实证——归一化已把未知字段降级为「未知」展示，实证后仅需补字段名白名单；四写命令 native `false` 的细分语义（名字不存在 vs 已在名单）未区分，按「returned false」原样透传；行点击载入的 TextInput 行为沿用拍卖收藏先例，未单独实机构建。

## M1.16.0.18.55 — 底层框架可观测性审计：metrics 三件套补齐 + 游离开发目录清理（2026-09-02）

- **背景**：按维护技能流程对底层框架（`ui/framework/` 全部 25 文件 + core）做同型脆弱点扫描——逗号优先级陷阱多值赋值全库复查（**无残留**：现存 `local x, y = tonumber(x) or 0, tonumber(y) or 0` 均为每值独立完整表达式，仅 .53/.54 修过的 CollapsibleGroup/HeaderBodyFooter 属真实陷阱）；`toc.g` ↔ 磁盘双向 0 差异核验（**发现并清理** addon 树内游离 `.workbuddy/tmp/`）。扫描暴露 RSUI 全局 metrics 记账的 **init/snapshot/reset 三件套登记缺口**，本轮补齐。
- **metrics 三件套缺口（真实可观测性债务）**：机械对账（非目测）发现 4 个字段**有写入 + 有 init 默认但 GetSnapshot 从未读出**（诊断不可见）：`duplicateTypeRegistrations` / `externalLayoutInvalidations` / `typographyInvalidations` / `fontScaleApplications`；14 个字段 **ResetMetrics 未归零**（"重置后观察增量"工作流失真）：buildScope 全家（`buildScopesStarted/Committed/RolledBack`、`buildScopeComponentsReleased/WidgetsHidden/CleanupFailures/CloseOrderRecoveries`）、`buildTransactions/buildTransactionFailures`、`preflightFailures`、`strictBuildFailFast`、以及上述 `duplicateTypeRegistrations/externalLayoutInvalidations/fontScaleApplications`。`byType` 经子索引循环展开属正常豁免。均纯登记补齐，零行为变更。
- **清理**：删除 addon 树内遗留游离开发目录 `replicatedsuite/.workbuddy/tmp/`（19 个文件：9 个 09-01 历史 bugfix .zip + 10 个旧验证脚本；非 git 跟踪、不属于 toc 加载、违反红线 §12.4「测试/调试脚本一律放项目根 `.workbuddy/tmp/`，绝不放插件树内」）。删除后 toc 对账死文件归零。
- **验证**：`luac -p` 通过；Foundation Audit **PASS**（`toc=199 activeLua=199 allLua=208 globals=0 presentation=0 rawNative=0 rawScope=0 detachedWidgetState=0 apiDependency=0 apiCapability=0 businessIds=0 auctionEventOwners=0`）；RSUI layout templates harness **68/68 PASS**；toc 双向 0 差异。
- **未验证项**：无行为变更，无 RU 客户端新增依赖；诊断页展示新字段属下游展示，无需单独实机验证。

## M1.16.0.18.54 — RSUI 高级布局模版：外部独立审查（P2/P3）收口（2026-09-02）

- **背景**：.53 交付后交由另一 AI 做独立复审，结论「有条件通过」：2 个 bug 修复正确、其余 3 类无 bug、harness/audit 实跑通过；但提出 **3 项 P2 条件 + 5 项 P3 建议**。本轮全部落实（`LayoutTemplates.version` 2 → 3，行为契约有变）。
- **P2-1 SplitToolbar 窄窗 spacer 重叠零报告**：`SplitToolbarPolicy:Resolve` 命中 `spacerMinWidth` 钳制分支时 spacer 矩形会真实伸入右组（fail-closed 设计意图），但此前无任何记账。改为**返回第二值 `clamped`**（单返回值调用方不受影响，向后兼容），`Layout` 在 `clamped` 时计入 `RSUI.metrics.splitToolbarSpacerClamped`，注释明示「重叠可见是退化信号」。
- **P2-2 `SafeHandler` 返回值未检查**：`CollapsibleGroup` headerHit 绑定改为 `local bound = UI:SafeHandler(...)`，绑定失败（widget 不可用 / SetHandler 被拒 / 返回 false）计入 `RSUI.metrics.collapsibleHeaderBindFailed`。绑定丢失在运行时完全不可见（标题条照常渲染、只是点了没反应），不能假定成功。
- **P2-3 Steps 的 `state` 枚举无消费方**：文件头注释宣称「视觉层只需渲染三种色调」，但 `Layout` 只用 `step.width/x`。确立**可选消费契约**：子项暴露 `SetStepState(state, index)` 即由 `Layout` 调用（`"done"/"active"/"pending"`），按 `rsUiStepState` 做 **diff**（状态未变不重入，重复布局零开销；标记先于调用，抛错消费方不会被反复重试）；无该方法的子项是纯几何容器、零耦合不被触碰。注释同步改写。
- **P3 低风险项一并收口**：
  - `HeaderBodyFooter:Measure` 消除首批遗留的同型坑形（`local hw, hh = header and Measure(...) or 0, 0` + 纠正行），改 CollapsibleGroup 同款显式双值，三区高度一次算准（旧写法功能正确但依赖纠正行，脆弱）。
  - `SetExpanded` 内 `local next` 遮蔽全局 `next()` 迭代器 → 改名 `nextState`。
  - headerHit 按钮 `titleFontSize` 回退由 `font.small/10` 对齐为 `font.section/13`（与 title Label 同字段一致；按钮文本为空，零行为影响）。
  - 审查文档行号漂移（Steps 751 → 764 等）与 §2.3 措辞已修正。
- **metrics 登记补齐**：`rs_ui_component_core.lua` 新增 `collapsibleHeaderUnavailable`（此前被引用但漏登记）/ `collapsibleHeaderBindFailed` / `splitToolbarSpacerClamped` 三字段的**初始化、快照、ResetMetrics** 三处登记，沿用全库 `(tonumber(...) or 0) + 1` 记账惯例。
- **harness 50 → 68 断言，并修复一处会令断言空转的 mock 缺陷（重要）**：所有 `Create*/Set*` mock 此前是**点号声明但被冒号调用**，`self` 落进 `parent`，参数整体错位一位——widget id 取成了父对象，且所有 `SetExtent`/`SetAnchor` 写都落到 `UI` 表而非 widget 上。即 harness 看着全绿，实际**从未验证任何原生写入**。全部签名补显式 `self` 后（并对非 table 入参返回 false 以暴露错位），新增断言：headerHit 的真实 id/几何 `createArgs`、SafeHandler 标签、主题背景清零调用、绑定失败计数、无 Button 表面 fail-open 计数、Steps 状态交付/diff/变更重投、窄窗 clamp 计数、HeaderBodyFooter 三区高度求和、重展开后 `viewportVisible==true` 与 Measure 回到 106。
- **验证**：harness **68/68 PASS**；`luac -p` 三个文件语法通过；Foundation Audit **PASS**（`toc=199 activeLua=199 allLua=208 globals=0 presentation=0 rawNative=0 rawScope=0 detachedWidgetState=0 apiDependency=0 apiCapability=0 businessIds=0 auctionEventOwners=0`）。
- **未验证项**：`SetStepState` 契约尚无首个业务消费方（首个接入者需自带断言）；Button 覆盖层 z-order 与 0-alpha 背景仍需 RU 实机目测；harness 组件核仍是简化重实现，非 dofile 真实组件核。

## M1.16.0.18.53 — RSUI 高级布局模版（第二批：DetailRow / Steps / CollapsibleGroup / SplitToolbar）审查修复收口（2026-09-02）

- **背景**：第二批 4 类模版（CollapsibleGroup/DetailRow/Steps/SplitToolbar，随 Request J 已落盘 `rs_ui_layout_templates.lua` v2、toc.g 已注册）此前处于「未审查、含真实 bug、CHANGELOG/审查文档/memory 仍停留在第一批 .52」的半成品状态。本轮按审查文档 §8 候选清单完成逐行审查 + 修复 + harness 扩展 + 文档收口。
- **审查结论（其余 3 类）**：`DetailRow`（label 区 + 等宽右对齐 value 列，窄窗先让 label 收缩）几何一致；`Steps`（末格吸收余数，3×94+2×8 余量收敛到 96，末格到行尾零尾缝）正确，Measure 第 751 行 `math.max(0, N(spec.width,0)) or 0` 的 `or 0` 冗余无害；`SplitToolbar` 复用 `ToolbarPolicy:Partition` 三区，左右组距相消正确（`iw-leftUsed-rightUsed`），spacer 失败收敛到 `spacerMinWidth` 为 fail-closed 设计。无同类 bug。
- **修复 bug 1（CollapsibleGroup:Measure 展开高度恒缺内容）**：`local dw, dh = self.expanded and Measure(...) or 0, 0` 是 Lua 逗号优先级陷阱——`or` 优先级高于 `,`，实际解析为 `dw = (expanded and Measure(...) or 0); dh = 0`，**dh 恒为 0**，展开态测量永远不含内容高度（折叠/展开在同一父容器内切换时容器高度不会随内容伸缩）。改为显式 `if expanded and content ~= nil ... then dw, dh = Measure(...) end` 双值赋值。
- **修复 bug 2（headerHit 折叠点击在 RU 静默失效）**：旧实现用 `UI:CreateEmptyWidget(..., pickable=true)` + `SetOnClick/OnClick`，但全代码库该二方法零使用、EmptyWidget 面在 RU 客户端收不到 OnClick（权威注释见 `rs_ui_data_views.lua`），真实客户端折叠点击永远不触发。改为框架标准点击绑定：`UI:CreateButton`（空文本、置于 title/chevron Label 之下，Label 不抢点击）+ `UI:SafeHandler(headerHit, "OnClick", ..., "<id>:collapsible_header")`（generation/崩溃保护 + 随 owner 释放）；按钮主题背景经 `S.Theme:SetBackgroundOpacity(headerHit, 0)` 清零（pcall + 存在性守卫，视觉与 GroupBox 头部一致，chevron 承担可点暗示）。CreateButton 失败走 fail-open 降级（记录 `RSUI.metrics.collapsibleHeaderUnavailable`，组件照常渲染、`SetExpanded` API 仍可用）。
- **验证**：harness 扩展至 **50/50 PASS**（`.workbuddy/tmp/rsui_layout_templates_harness.lua`，不入包）——新增断言覆盖：展开态 Measure 含内容高度（10+28+8+50+10=106）、spec 固定宽保持、headerHit 为 native Button 表面、SafeHandler 绑定存在、header 点击→折叠（Measure 收缩到仅 header+padding=48、content viewport 隐藏）、再次点击→展开，配合 SafeHandler spy + `FireWidgetClick` 走真实绑定路径；`luac -p` 语法通过；Foundation Audit 全 PASS（`toc=199 activeLua=199 allLua=208 globals=0 presentation=0 rawNative=0 rawScope=0 ...`，toc 双向 0 差异）。mock UI 的 `SafeHandler` spy 修正为冒号调用兼容（补收隐式 self）。
- **未验证项**：Button 覆盖层 + 0-alpha 背景需 RU 实机构建目测（z-order：Button 在底、Label 在上不抢点击；点击热区高度 `headerHeight` 整条）；`CreateButton` 以 border Panel 为父的成功率依赖 Factory `CreateChild(type="button")`，与 data_views 行按钮同一路径（实机先行模式）。

## M1.16.0.18.52 — RSUI 高级布局模版（FormRow / KeyValueRow / Toolbar / HeaderBodyFooter / GroupBox）（2026-09-02）

- **背景**：RSUI 底层已有齐全的 UMG-like 基础积木（HorizontalBox/VerticalBox/Grid/UniformGrid/WrapBox/ScrollBox/SplitView/ScaleBox/SafeZone 等），但缺一层「组合式、跨分辨率稳定」的高级布局模版——每个 Feature 页面仍在手写 label/control 行、工具栏左/右分栏、页头/页体/页脚三区堆叠、带标题分组框等重复模式。
- **新增 `ui/framework/rs_ui_layout_templates.lua`（5 类注册类型 + 4 个纯策略函数）**：
  - `FormRow`：label | control | (hint) 单行；label 有 `labelShare` 占比，窄行先压 label 到 `labelMinWidth`、再压 control、最后丢 hint，绝不产生负宽。纯策略 `RSUI.FormRowPolicy:Resolve(...)`。
  - `KeyValueRow`：label ...... value（value 右对齐、受 `valueMaxShare` 上限）；纯策略 `RSUI.KeyValueRowPolicy:Resolve(...)`。
  - `Toolbar`：`slot.group = "left" | "right" | "spacer"` 三区；left 靠左、right 靠右、spacer 填中间；每项 auto 宽（不再被 fill 撑满整条）；纯策略 `RSUI.ToolbarPolicy:Partition(...)`。
  - `HeaderBodyFooter`：页头(auto)/页体(fill)/页脚(auto) 三区堆叠；纯策略 `RSUI.HeaderBodyFooterPolicy:Resolve(...)`。
  - `GroupBox`：带标题分组框（Border 面 + 标题条 + content + 可选 footer），由 Border 组合而成、继承完整 Measure/Arrange 路径。
- **设计约定**：全部由现有 primitives 组合，不建第二套布局 Authority；纯策略函数与类型并存（`SplitViewPolicy` 先例），tiny-window/序列测试可零 Native 副作用地跑纯数学；事件/布局驱动，无 Tick/OnUpdate/轮询；Measure 不写 Native 布局，Layout 只走既有 Diff/Anchor 权威。
- **修复 harness 暴露的 Toolbar 布局 bug**：初版 Toolbar 对每项 `Align(start, iw, dw, slot.hAlign)`，默认 `hAlign="fill"` 导致每个按钮被撑满整条工具栏宽度（left 项 width=400）。改为每项按自身测得宽度 auto 布局（`Align(start, dw, dw, "left")`）。
- **注册**：`toc.g` 在 `ui/framework/rs_ui_adaptive_panels.lua` 之后新增 `ui/framework/rs_ui_layout_templates.lua`（依赖 `RSUI.LayoutUtil` 与面板类型，需在其后加载）。
- **验证**：`luac -p` 语法通过（用内置 `luabin/luac.exe`）；Foundation Audit（`toc=199 activeLua=199 allLua=208 globals=0 presentation=0 rawNative=0 rawScope=0 ...`，toc 双向 0 差异；Audit 的 Lua parse FAIL 仅因审计工具未找到 texluac/luac 到 PATH，非代码问题）；自定义 harness `rsui_layout_templates_harness.lua` 20/20 PASS（`.workbuddy/tmp/`，不入包）——4 个纯策略 + 5 类模版的 measure/arrange/responsive/no-overlap/right-align/fill-remainder/Measure-purity 断言。
- **未验证项**：5 类模版尚未在 RU 客户端实机构建（Factory 注册与 Lua 静态覆盖无法替代真实构建序列）；`GroupBox` 的标题条 Drawable accentStrip 视觉需 RU 实测；纯策略函数依赖 `RSUI.LayoutUtil` 已加载（`rs_ui_panels.lua` 先行）。

## M1.16.0.18.51 — 共享限速报价队列 PriceQuoteQueueV3（共享前置 #1 落地）（2026-09-02）

- **背景**：REBUILD_ROADMAP 共享前置 #1——Trade/CraftAssist/AuctionFavorites 三个域都需要显式 `X2Auction:GetLowestPrice` 报价，但该 API 是 `Cooldown=500ms` 的 server_query，普通 Refresh 绝不能 fan-out。此前三域均已移除自动 fan-out（M1.16.0.18.39），但缺一个统一、限速、显式触发的报价服务。
- **新增 `services/rs_price_quote_queue_v3.lua`（`S.Services.PriceQuoteQueueV3`）**：
  - `RequestQuote(requester, itemType, itemGrade, callback)`：显式+异步报价入口。入队后由单一 Scheduler 串行 lane（`intervalMs=560ms ≥ 官方 500ms 冷却`）逐个 drain，一次只发一个原生调用，规避冷却冲突。
  - 异步回调：每请求完成通过内部事件总线 topic `v3.price_quote.completed` 广播 + 可选 `callback(snapshot)` 回传；requester 级快照（`GetSnapshot`）供投影只读回读，不重复发服务器请求。
  - fail-closed：能力门拒绝/返回不可读一律产出 `status`（`failed`/`unavailable`/`capability_unavailable`），绝不在 `GetLowestPrice` 返回形态未验证时伪造价格；`NormalizeQuote` 保守接受 number/string/若干常见字段，未验证字段不作为成交样本。
  - 上限 `maxQueue=64`、去重由 requester 快照覆盖、空队列自动停 lane（`_StopLane`）。
- **收敛直接调用**：`features/rs_business_bridge.lua` 中两处报价调用收敛到共享服务——`auctionCommands.Quote`（AuctionFavorites，原先直接 `Call GetLowestPrice`）与新增 `CraftCommands().QuoteMaterial`（CraftAssist 显式单材料报价命令）均改走 `PriceQuoteQueueV3:RequestQuote`；`CraftQuote` 桩保持「Refresh 不自动报价」诚实语义（注释指向共享服务）。
- **注册**：`toc.g` 在 `services/rs_auction_query_v3.lua` 之后新增 `services/rs_price_quote_queue_v3.lua`（双向 0 差异）。
- **报价快照接回投影 + itemType 索引 + 修复 `_FailPending` 丢弃失败快照 bug**：
  - 新增 `pricesByItemType[itemType]` 跨 Feature 读模型 + `GetPriceByItemType(itemType, itemGrade)`（grade 软过滤、omit-grade 返回最近价、未知返回 nil 而非 0）；`CompletePending` 仅在 `status=="ready"` 时写入索引（失败/不可读不覆盖好价，fail-closed）。
  - Trade `BuildTradeMaterialProjection` 材料循环改为读共享读模型：itemType 已有完成报价时填 `unitCostCopper`/`costCopper`（status=`quoted`），否则保持 `explicit_quote_required`；**只读不发服务器请求**。
  - CraftAssist `CraftQuote` 从「恒返回 explicit_quote_required 桩」改为读共享读模型：有价返回 `price, "quoted"`，无价保持桩语义。
  - **修复 bug**：`_FailPending` 原先先清 `Q.pending` 再调 `CompletePending`，导致 `CompletePending` 读到 nil 静默丢弃失败快照（第二次报价失败时 `GetSnapshot` 仍返回 `queued`）。改为交 `CompletePending` 单点清空。
- **验证**：`luac -p` 语法通过；Foundation Audit 全 PASS（`toc=198 activeLua=198 allLua=207 globals=0 ...`）；自定义 harness `price_quote_drain_harness.lua`（14/14）+ `price_quote_read_model_harness.lua`（8/8）全 PASS（`.workbuddy/tmp/`，不入包）。
- **未验证项**：`GetLowestPrice` 在 RU 客户端的真实返回形态需 RU 实机 Fresh Reload 验证；`pricesByItemType` 为会话级内存索引（重载清空，未做自动重建以避免重载 fan-out）；Trade Feature 尚无 `QuoteMaterial` 命令（成本依赖用户在 CraftAssist/Auction 先询价）。

## M1.16.0.18.50 — StatusDisplay 头顶全显（headShowAll）+ 勾选即见联动（参考 addon show-all 精华）（2026-08-31）

- **用户报告 Bug（延续）**：.49 修复渲染器 `HasTracked` 总开关后，勾选"头顶显示"且已追踪若干状态时图标仍不出现。深挖发现残留门禁：`ProjectPlates` 的 `BoundedTracked` 在投影层按 tracked 行过滤，tracked 列表为空（或玩家身上的 Buff 不在追踪列表）时 buffs/debuffs lane 产出 0 行——渲染器虽已启动但无行可画，表现为"任何图标都不出现"。对照 GitHub 同类 addon（belovres/ArcheRage-addons，RU 同客户端）精华：`targetdebufftracker/self.lua` 用 `target_buffs[strBuffId] ~= nil or showAllBuffs` 做**全显开关**，空 tracked 列表时用户开箱即可看到全部在场 Buff/Debuff；`buffcaptracker.lua` 单窗口容器 + OnUpdate；`distracker.lua`/`gstracker.lua` nil 时移屏 (5000,5000) + z>0 深度门禁。
- **修复 1（show-all 下沉投影层）**：`rs_buff_display_projection.lua` `BoundedTracked` 尊重新设置 `headShowAll`：`showAll == true or isTracked == true` 才收集行（仍受 `headMaxIcons` 有界限制）。tracked 语义从"行来源唯一门禁"降级为"可选过滤"——追踪列表为空或未命中时，在场 Buff/Debuff 照常投影显示，对齐参考 addon 开箱即见语义。
- **修复 2（设置默认开 + 归一化）**：`rs_buff_display_store.lua` `NormalizeSettings` 增加 `headShowAll = value.headShowAll ~= false`（默认开启，旧存档无损兼容）。
- **修复 3（导入导出链同步）**：`rs_buff_display_feature.lua` `ExportAll`/`SerializeExport` policy 白名单加入 `headShowAll`；`ImportAll` 布尔归一分支加入 `headShowAll`——导入导出往返不丢新设置。
- **修复 4（勾选即见联动）**：`rs_v3_buff_display_page.lua` Tab2 新增"全部显示：开/关"开关（`AddHeadToggle("headShowAll", ...)`，默认开）；`AddHeadToggle` 增加联动：`headEnabled` 从关→开时若 Feature 未启用则自动 `SetPreferredEnabled(true)` + `AcquireConsumer`（对齐参考 addon 开箱即用——用户无需先到总开关启用功能）；hint 文本同步"全部显示（不受追踪限制）/仅显示已追踪"。
- **验证**：自定义 Harness `17/17 PASS`（`.workbuddy/tmp/head_showall_harness.lua`：showAll=true 时空 tracked 列表仍全显 buffs/debuffs、showAll=false 时回到 tracked 过滤、maxIcons 有界截断、按 category 分 lane、feature 导入导出往返含 headShowAll、NormalizeSettings 默认值）；Foundation Audit 全 PASS（`toc=196 activeLua=196 allLua=353 globals=0 presentation=0 rawNative=0 rawScope=0 detachedWidgetState=0 apiDependency=0 apiCapability=0 businessIds=0 auctionEventOwners=0`）；全量 Lua `luac -p` 语法检查 352/352 通过。BuildTag：`v3-m1.16.0.18.50-statusdisplay-head-showall`（同步修正 `S.BuildTag` 版本一致性：此前停在 .48 而 CHANGELOG 已至 .49，本轮一并升到 .50）。
- **语义收口**：`headShowAll` 只影响 buffs/debuffs 头顶行的收集门限；distance/class/gearScore/装备/cast 等 6 个非 tracked 组件本就按组件 enabled 渲染不受影响；`headEnabled=false` 仍为主开关整体关闭。参考 addon 的"全显"与"z>0 深度门禁/移屏兜底"中，深度门禁本项目已由 `RenderScope` 的 `depth<=0` 检查覆盖，移屏 (5000,5000) 为 RU 特有 API 兜底不适用（本项目 anchor 缺失走 `metrics.anchorFailures` 诊断），不凭推断新增。

## M1.16.0.18.49 — StatusDisplay 头顶图标门禁修复（参考 addon 精华）（2026-08-31）

- **用户报告 Bug**：勾选"头顶显示"后玩家/目标身上不出现任何悬浮图标。GitHub 调研同类实现（belovres/ArcheRage-addons，RU 同客户端：disttracker/gearscoretracker/targetdebufftracker(self/enemy/tracktarget)/hiddendebufftracker 共 6 文件）吸取精华后定位根因。
- **根因（业务门禁不对称）**：`BuffHeadMarkersV3` 渲染器 `Start/VisualTick/Reconcile` 三处用 `HasTracked()`（tracked.buff/debuff 列表非空）作**总开关**，而 Feature 侧 `HeadScopeActive()` 只用 `headEnabled + AnyHeadComponent + headPlayer/headTarget`（无 HasTracked）。用户追踪列表为空时：position/distance/metadata/equipment/cast lane 全部在跑、投影与事件正常，但渲染器在 `EnsurePools` 之前就被 `not HasTracked` 拦死、永不启动——**distance/class/gearScore/装备/cast 等不依赖 tracked 的组件被连带隐藏**，表现为"任何图标都不出现"。属 10 组件重写（.46）时门禁未同步放宽的回归。
- **修复（对齐参考 addon show-all 语义）**：新增 `HasRenderableComponents()`（10 组件任一 enabled 即真），替换三处 `HasTracked` 总开关；`HasTracked` 保留但仅约束 buffs/debuffs 行数（`ProjectPlates` 的 `BoundedTracked` 天然按 tracked 过滤，tracked 为空渲染 0 行，其余组件照常显示）。`headEnabled=false`/无组件启用的空转防护保留。
- **诊断兜底**：`RenderScope` 在 anchor 缺失/depth<=0 时记录 `metrics.anchorFailures[scope]`（count/lastAt/lastErr）；新增 `BuffHeadMarkersV3:GetDiagnostics()`（running/consumerHeld/poolsAllocated/ticks/projections/anchorFailures/source/anchor/projectError）供 RU 实机排查；Feature `ProjectScope` 投影失败时 err 不再丢弃，写入 `lane.projectErr`（原静默清空 lane.x/y/depth）。
- **坐标空间裁决**：参考 addon 全部零 scale 直锚 `UIParent`，本项目 `ScreenProjectionV3` 归一化到 RSUI logical 坐标有 `rs_api.lua:133 GetUiMetrics` 权威注释背书（1024×768 除 scale 教训），**保留不改**；但 `NormalizeScreenPoint` 启发式（值落在 `(logicalW+2, screenW+2]` 区间才除 scale）在 4K/UI scale>1 下有误除风险，本轮不凭推断改共享投影服务（影响 Healer markers/range circles），通过 `GetDiagnostics().source/anchor` 暴露 + RU 手测 checklist 验证。
- **验证**：自定义 Harness `72 passed / 0 failed`（原 54 + 新增 18 条渲染器门禁/诊断断言：EMPTY tracked 时渲染器正常 Start、VisualTick 不短路、RenderScope 照常投影、anchor 丢失记录诊断且渲染器保持运行、headEnabled 主开关仍可启停）；Foundation Audit 全 PASS（`toc=196 activeLua=196 allLua=353 globals=0 presentation=0 rawNative=0 rawScope=0 detachedWidgetState=0 apiDependency=0 apiCapability=0 businessIds=0 auctionEventOwners=0`）；全量 Lua `luac -p` 语法检查 352/352 通过。BuildTag：`v3-m1.16.0.18.49-statusdisplay-head-gate-fix`。
- **契约收口**：`BuffHeadMarkerContractVersion` 2→3（门禁解耦 tracked + GetDiagnostics 诊断面 + anchorFailures 痕迹）；`rs_v3_acceptance.lua` 契约断言升 `buffHeadMarkers.version >= 2` + `GetDiagnostics`/`metrics.anchorFailures` 存在性；`rs_buff_display_acceptance.lua` `feature_contract` 升 `BuffHeadMarkerContractVersion >= 3` + 新增 `head_marker_gate_contract` 序列（Start/Stop/Reconcile/VisualTick/GetDiagnostics/anchorFailures 五面齐全）。全项目渲染器同源扫荡：combat_visual_guides（IsEnabled 门禁 + 渲染失败释放）、healer_head_marker（settings.enabled 门禁 + 已有 projectionFailures 诊断）、healer_raid_overlay（calibration/runtime 双模式）均为"功能开关"语义，数据空只隐藏不拦截启动，无 HasTracked 类总开关残留。

## M1.16.0.18.48 — StatusDisplay 全面重新审计（规范驱动）（2026-08-31）

- **审计性质**：本轮为纯审计轮，按 100 步规范对状态显示执行完整重新审计；**无代码改动**（审计确认 HY3 六项修复在位且正确，未发现新运行时 Bug，故不改代码）。BuildTag 提升至 `v3-m1.16.0.18.48-statusdisplay-full-reaudit` 以标记审计版本。
- **Phase 1 文档阅读**：`Docs/README`、`Docs/CURRENT_REBUILD_STATUS.md`、`Docs/Architecture/SERVICE_ARCHITECTURE.md`、`toc.g`（196 个 Active 条目）。
- **Phase 2 Authority 审计（逐文件读真实代码）**：`services/rs_aura_observation_v3.lua`（377 行）、`services/rs_status_classification_v3.lua`（212 行）、`services/rs_screen_projection_v3.lua`（198 行）、`services/rs_unit_identity_v3.lua`（331 行）、`features/rs_feature_runtime.lua`（367 行）、`core/rs_scheduler.lua`（389 行）、`core/rs_refresh_coordinator.lua`（169 行）、`features/combat/buff_display/rs_buff_display_feature.lua`（57.8KB）、`rs_buff_display_store.lua`（419 行）、`rs_buff_display_projection.lua`（165 行）、`rs_buff_display_acceptance.lua`（84 行）、`presentation/v3/pages/rs_v3_buff_display_page.lua`（550 行）、`presentation/v3/widgets/rs_v3_buff_display_widget.lua`（124 行）、`presentation/v3/widgets/rs_v3_buff_head_markers.lua`（370 行）。结论：AuraObservationV3=共享事实层（GetSnapshot 显式读取 + TTL 120ms + Demand reconcile）、StatusClassificationV3=全项目唯一"效果是什么" Authority、ScreenProjectionV3=共享只读投影（RSUI logical 空间）、UnitIdentityV3=保守身份事实但不在 StatusDisplay 链、Scheduler=单一 OnUpdate driver（highfrequency ≥1ms 不计 backlog）、RefreshCoordinator=仅 debounce/coalesce 且 StatusDisplay 未用（符合规范第 29 节"周期任务归 Scheduler"）、FeatureRuntime=三方法契约（.47 已补 Initialize）。
- **Phase 3 Prior-Agent 时间戳交叉核对收口**：基线 10:39 未动 = `rs_feature_runtime.lua` / `rs_refresh_coordinator.lua` / `rs_aura_observation_v3.lua` / `rs_unit_identity_v3.lua`；Prior-Agent 窗口 17:33–23:35 = `rs_screen_projection_v3.lua`(17:33) → `rs_status_classification_v3.lua`(18:26) / `rs_scheduler.lua`(18:25) / `rs_v3_buff_head_markers.lua`(18:32) / `rs_buff_display_acceptance.lua`(18:54) / `rs_v3_buff_display_page.lua`(18:55) / `rs_buff_display_projection.lua`(22:29) / `rs_v3_buff_display_widget.lua`(22:30) / `rs_buff_display_feature.lua`+`rs_buff_display_store.lua`(23:35)。全部文件已在本轮逐行读取，无未审新版本。
- **Phase 5 Native Capability 审计**：确认 `GetUnitsInSight` 不进入 StatusDisplay 链（状态显示使用 Tracked 集合，不做视野扫描），规范第 19 节 Visible Unit Observation 记录为"当前不适用"。
- **Phase 6 共享发现审计**：`UnitIdentityV3` 提供保守身份事实（ParseExplicitKind/GetById/ResolveCombatEndpoint/RefreshPlayerIdentity，bounded cache，只读 target-token 不扫描），但在 StatusDisplay 的 6 条 lane 中无任何消费，规范第 99 节记 N/A。
- **Foundation 使用情况（规范第 99 节）**：FeatureRuntime=使用（三方法契约 + lifecycle topic + DisableAll ForceQuiesce）；Demand=使用（`v3.aura_observation` lease，0→1/options-change/1→0 reconcile）；Scheduler=使用（aura 400ms / head 100ms / metadata 1000ms / equipment 2000ms / highfrequency 1ms 位置 lane）；FrameBudget=经 Scheduler 内置集成（Scheduler 每个 due task 调 `frameBudget:Request`，feature 不直用）；AuraObservationV3=使用（GetSnapshot/GetStatusMap）；UnitIdentityV3=N/A（不在链上）；Visible Unit Observation=N/A（Tracked 集合而非视野扫描）；Persistence=使用（RegisterV3Store schema 4 + MigrateState 1/2/3→4 + MarkStoreDirty write-fence）；RSUI=使用（Page/Widget 消费 detached Projection + `Feature.Commands`）；ViewState=经 RSUI 页面机制（四页签 Switcher 路由）；ActionRunner=经 Commands 可失败操作；RefreshCoordinator=N/A（周期位置 lane 归 Scheduler，仅事件路径一次性 `_QueueEventRefresh`）；Diagnostics=使用（feature health 快照 + FoundationGate 检查）；统一 candidate capture（规范 68-69 节）=尚未实现，文档层概念，无可用能力缺口。
- **验证**：Foundation Audit 全 PASS（`toc=196 activeLua=196 allLua=353 globals=0 presentation=0 rawNative=0 rawScope=0 detachedWidgetState=0 apiDependency=0 apiCapability=0 businessIds=0 auctionEventOwners=0`）；全量 Lua `luac -p` 语法检查通过；自定义 Harness `44 passed / 0 failed`（`.workbuddy/tmp/status_display_harness.lua`，开发工具不入包）。BuildTag：`v3-m1.16.0.18.48-statusdisplay-full-reaudit`。

## M1.16.0.18.47 — StatusDisplay HY3 收口修复（2026-08-31）

- **Feature 补上 Initialize() 完成 FeatureRuntime 三方法契约**：`combat_buff_display` 此前缺 `Initialize()` 导致 FeatureRuntime 注册失败（`IsImplemented=false`、AcquireConsumer 直接拒绝、Refresh 报 "buff display aura lease not held"），整个状态显示在 Fresh Reload 后报废。现补齐 `Initialize()`：EnsureStoreLoaded → 校验 AuraObservationV3（GetSnapshot/GetStatusMap）→ StatusClassificationV3（ClassifyEntry）→ ScreenProjectionV3（ProjectUnit）→ ProjectStatusMap/ProjectPlates → 构建 trackedIndex，一切下游 lane/demand/投影接通。
- **FoundationGate 陈旧契约修正**：`buff_display_v3_statusmap_contract` 仍要求 `schemaVersion==3`，而 Store 已是 schema 4，导致每次 Fresh Reload 门禁必 FAIL。已改 `== 4`。
- **Foundation Audit 白名单补登记 2 个真实 RU API**：`X2Locale`、`UnitDistance`（api_functions.lua 有签名），Audit globals 归零。
- **非官方 API 面改安全读取**：`UnitDistance`/`X2Locale`/`COMBINED_ABILITY_NAME_TEXT`/`ES_MAINHAND`/`ES_OFFHAND`/`ES_RANGED`/`ES_BACKPACK` 均改经 `Global()` 安全读取（load 时不存在则永久禁用对应调用路径，能力宿主由 `S.Api:ResolveCapabilityHost` 解析），不再裸全局访问。
- **ReadEquippedIcon 增加 scope 参数**：`targetEquippedItem` 在 target 上下文中传 `true`（对齐 rg_api/rg_core/rg_gear_service_v3 同源模式），修复目标装备信息显示成自身装备的 bug。
- **Store 迁移兜底 schema 3 扁平 tracked 数组**：原 MigrateState 只找 `settings.trackedIds`/`value.trackedIds`，丢失 `settings.tracked = { 101, 102, 103 }` 扁平形态；新增循环遍历该形态，无损迁移。
- **MarkStoreDirty 成为缓存失效唯一钩子**：所有设置写路径（SetSettingValue/SetComponentField/SetTrackedId/ClearTrackedIds/SetClassification/ClearClassification/import）统一经 MarkStoreDirty → `F:InvalidateSettingsCache()`，消除投影读到过期设置的窗口。
- **GetSettingsProjection 接入 detached 快照缓存**：settingsCache/settingsCacheRevision/SettingsRevision() 惰性深拷贝 + 失效计数，投影不再直接引用 live store 表。
- **ProjectPlates 修复投影边界违规**：`out.components` 此前直接引用 live store 表，现经 CopyComponents 深拷贝（Harness 断言 `plates.components ~= F.State.settings.components` 实证通过）。
- **Widget Refresh 去冗余**：原 3 次 GetProjection 调用（"all"+player+target）收敛为 1 次 `GetProjection("all", 24)`，遍历 rows 按 scope 统计 playerCount/targetCount。
- **验证**：自定义 Harness `44 passed / 0 failed`（`.workbuddy/tmp/status_display_harness.lua`，开发工具不入包）；Foundation Audit 全 PASS（`toc=196 activeLua=196 allLua=353 globals=0 presentation=0 rawNative=0 rawScope=0 detachedWidgetState=0 apiDependency=0 apiCapability=0 businessIds=0 auctionEventOwners=0`）；全量 Lua 语法检查通过（排除 toc.g）；真实 `S.Api:Call` 低级原语确认存在于 `core/rs_api.lua:105`（Aura/Unit/CombatEventBus V3 服务共用，热路径先 Gate 后走 Call，与架构文档一致）。BuildTag：`v3-m1.16.0.18.47-statusdisplay-hy3-fix`。

## M1.16.0.18.46 — Buff Display Schema 4 / Four-Tab Page（2026-08-31）

- **Scheduler 增加高频 Lane**：允许 1ms 下限的调度任务，为头顶标记的位置刷新与单位连线提供 1ms 档位，不再被旧的低频下限钳制（`refreshMs/headRefreshMs` 永不上钳）。
- **新建 StatusClassificationV3 共享分类服务**：全项目唯一"效果是什么"Authority，用户可见分类只有 buff/debuff，hidden/special_rule 收敛为 detection source；解析顺序 = 用户覆盖 → 种子库（Buff ID 库 + Plates 兼容集）→ 快照来源启发式 → 默认（未知 hidden 归 debuff）。`ClassifyEntry/ClassifyId/SetOverride/ApplyOverrides/GetRegistrySnapshot/GetHealth` 全部公开。
- **Store 升 schema 4**：tracked 按 `{ buff = {...}, debuff = {...} }` 分桶；hidden 不再作为用户分类；10 个头顶组件（buffs/debuffs/distance/class/gearScore/mainHand/offHand/ranged/wings/castBar）各带 enabled/x/y/size/fontSize/alpha；从 schema 1/2/3 无损迁移，历史追踪 ID 经分类服务落入正确分桶。
- **Projection/Plates 改造**：状态行携带 `category/detectionSource`，tracked 查找走预建 O(1) 索引；Plates 投影只返回启用组件 + 按 headMaxIcons 有界追踪行；`ProjectPlatesContractVersion=1`。
- **头顶显示重写为 10 组件渲染器**：`BuffHeadMarkersV3` 覆盖全部 10 个组件，按组件 enabled 启停渲染；Focus 目标行修复。
- **Feature 增加 Runtime Lane**：按组件启停消费运行时数据（buffRows/debuffRows/distance/class/gearScore/主副手/远程/翅膀/cast），Demand=0 释放；事件驱动 + 低频兜底。
- **单位连线 1ms 刷新**：视觉引导刷新频率下限降到 1ms，与高频 Scheduler Lane 对齐。
- **`combat.buff_display` 页面重构为四页签**：状态追踪（Buff/Debuff/只看隐藏筛选 + 关键词搜索 + 行点击 Toggle 追踪）/ 头顶显示（5 个开关 + 图标大小/数量/位置/刷新 4 个数值）/ 布局外观（10 个组件卡片，每卡启用开关 + x/y/size/fontSize/alpha 5 个数值，滚动承载）/ 导入导出（快速 ID 导入 合并/覆盖 + 完整导出/导入文本）。所有写入走 `Feature.Commands`：`SetTrackedId(id, category, enabled)` 显式传 category（修复旧 2 参调用误把布尔当 category 落入 debuff 桶的隐患）、`SetComponentField`、`ImportTrackedIds/ExportAll/SerializeExport/ParseImportText/ImportAll`。行点击 = 先选中后激活（`HandleRowClick` 契约），单击即切换追踪。
- **"隐藏"按钮语义修正（schema 4 对齐）**：hidden 不再是用户分类后旧"隐藏"开关对投影无效果；页面改为"只看隐藏"视图过滤器，仅显示 `detectionSource=="hidden"` 的行，与覆盖率 Hidden 计数一致。
- **toc.g 补登记 `services/rs_status_classification_v3.lua`**：该共享服务此前未被加载清单包含，游戏内为 nil 时自动分类会静默降级。
- **验收/门禁同步 schema 4**：`rs_buff_display_acceptance.lua` 升到 store schemaVersion==4，新增分类服务契约、schema 4 确定性投影断言（hidden 来源行归类 debuff）、10 组件投影与 Plates 投影契约、完整 Commands 面检查；`rs_v3_acceptance.lua` 的 buff 观察契约要求 `SchemaVersion==4` 与分类服务在场；`FoundationGate v62`。
- 本地验证：Foundation Audit 静态检查（toc/activeLua/globals/presentation/rawNative/businessIds）全 PASS；Lua 5.1 `luac` 语法门禁补齐（新增本机 luac 工具链）；`luaparser` 对四页签页面语法校验 OK。BuildTag：`v3-m1.16.0.18.46-buff-display-schema4-four-tab-page`。

## M1.16.0.18.45 — Product Usability Recovery（2026-08-31）

- **治疗校准重新接真实团队事实**：校准模式通过独立 Preview Consumer 读取 Team/Aura detached projection；治疗功能本体关闭时仍可显示真实团队成员颜色，退出校准立即释放 Preview Demand，不用推荐名单悬浮窗维持数据源。
- **状态显示恢复“追踪 Buff → 玩家/目标头顶标记”产品能力**：`v3.buff_display` Store schema 升到 3，保存最多 32 个精确 Buff ID 与玩家/目标、图标大小、数量、Y 偏移、刷新、层数/剩余时间设置；新增 `BuffHeadMarkersV3` bounded icon pool。收口时同步修正 `BuffDisplayAcceptance/FoundationGate` 仍要求 schema 2 的旧门禁，防止静态 Audit 绿灯而运行 Sequence 失败。
- **ScreenProjectionV3 v3 / Combat Visual Guides**：统一逻辑 UI 坐标与 Camera fallback，范围圆不再直接混用物理像素；Unit Lines 支持“自己↔目标、目标↔目标的目标、自己↔焦点、焦点↔焦点的目标”四条有界关系，并允许 50–1000ms 刷新频率。无 Tick，Feature Demand 归零后释放 Scheduler/视觉资源。
- **团队自动职责**：新增 86 个精确职业组合的静态职责目录，Ability Set / TeamRoster 变化时只对当前玩家调用已验证的 `X2Team:SetRole(role)`；不把读取任意成员职责错误扩张成任意成员写入。
- **生活 HUD 回收**：Trade FloatingSurface 可直接选择/循环起点终点，RU zone boolean-set/静态候选兼容继续由服务器 ratio 作为路线真实性 Authority；Treasure/Fishing 恢复独立悬浮窗，Treasure 主页面行选择真正调用 Feature Command。
- **制作规划/制作台去 raw ID**：普通用户改为选择已核制作物，由 Feature 内部解析 CraftID/ItemID；页面不再要求输入 `itemType/craftType/doodadId`。内部 ID 只留诊断/兼容入口，材料/持有/缺口状态使用中文产品语义。
- **背包旧版高价值交互迁回 V3**：新增跟随原生背包的 `取同类 / 放同类 / 停止` 快捷条；银行/箱子打开时按已验证的同类物品语义串行移动。类别批量整理保留为高级操作，快速任务与类别批量任务互斥；Scheduler 创建失败、仓储关闭、Feature Disable 都会回滚/停止，不留下僵尸移动任务。
- **AuctionQueryV3 v2 成为无 token 拍卖搜索唯一事件 Authority**：统一 9 参数 `SearchAuctionArticle`、串行 pending、超时清理、bounded current-listing rows。`tools.auction` 收藏与 `tools.market_analysis` 当前挂单行情共享该 Service；“当前挂单”不冒充历史成交价。Foundation Audit 新增 `AUCTION_ITEM_SEARCHED` 单一 Authority 静态门禁。
- `UIV3Acceptance v35 / FoundationGate v61`。最终 Foundation Audit 目标/结果：`195/195 Active TOC + 351/351 Lua`，`globals/presentation/rawNative/rawScope/detachedWidgetState/apiDependency/apiCapability/businessIds/auctionEventOwners=0`。专项回归：AuctionQuery、Bag task mutex、Healer calibration、ScreenProjection batch、Trade zone-shape、VisualGuide rollback、Alerts duration 全部 PASS。
- Product Capability Matrix 重新扩展被旧版/用户要求重新发现的能力后为 125 条：`77 IMPLEMENTED / 35 PARTIAL / 2 TODO / 11 SPECIFIC_RUNTIME_BLOCKED / 0 UNREVIEWED`。BuildTag：`v3-m1.16.0.18.45-product-usability-recovery`。


## M1.16.0.18.44 — DPS Skill Proxy Source Classification（2026-08-31）

- 修复 RU 老问题：`治愈之泉` 是玩家放置技能实体，不是玩家。旧 DPS shared-heal ledger 直接以 `sourceName` 建 Actor，导致该技能以独立治疗者进入排行榜，并可能把技能实体送入 CombatRelation。
- 新增 `CombatSourceProxyCatalog v1`，首个 family 精确覆盖治愈之泉 11948 / 41224 / 41225；DPS Domain 升 v7。代理 source 在关系学习与 Actor 创建之前 fail-closed：不进玩家榜、不写 CombatRelation，治疗量进入 `proxySourceHeals/proxySourceHealAmount` 显式诊断。
- 复核 bundled RU API 后确认没有可靠 generic proxy→caster owner link；因此最终实现**没有**使用本机施法时间、最近施法者、唯一已观察候选、距离或目标来猜主人。多人可同时放置治愈之泉，任何这类推断都可能把他人治疗算给自己。真实 `sourceName=玩家` 的同技能事件仍正常计入玩家。
- DPS 页面待确认诊断增加“技能代理未归属”，避免为了去掉假玩家而静默吞掉无法可靠归属的治疗量。`UIV3Acceptance v33 / FoundationGate v59` 新增 proxy source blocker。
- 本地验证目标：Foundation Audit `191/191 Active TOC + 347/347 Lua`；texlua Domain 故障注入验证 proxy source 不成 Actor、不触发 Relation 记录、真实玩家 source 的治愈之泉仍能统计。BuildTag：`v3-m1.16.0.18.44-dps-skill-proxy-source-classification`。

## M1.16.0.18.43 — Combat / Life Usability Recovery（2026-08-31）

- 根据 RU 实机负面证据收缩战斗页面信息密度：DPS 与 Death Review 默认折叠高级设置/诊断，把纵向空间优先让给排行、明细与死亡时间线；Healer 页面不再创建推荐名单/成员详情表，旧 `combat.healer` 推荐悬浮 Widget 从 Active TOC 移除，治疗辅助产品出口收敛为规则/颜色设置、Head Marker 与团队色块校准/覆盖。
- 修复 Healer 团队校准“打开无反应”：Raid Overlay 的 calibration 现在可以在 `combat_healer` Feature 关闭时独立运行，显示 4×25 校准色块且持有 **0 个 Healer Consumer**；退出校准或切回 live overlay 时按模式转移资源。旧 Healer sequence acceptance 同步改为禁止重新注册已删除的推荐 Widget，并验证 standalone calibration 生命周期。
- `combat.buff_display` 从低频快照补成 Demand-scoped `BUFF_UPDATE` / `TARGET_CHANGED` 观察；Buff burst 通过 120ms one-shot 合并后读取，Consumer=0 解除事件/任务；Presentation 明确区分“确实为空”和“状态事实不可读”。
- Boss 机制页按真实 `BossAlerts` 字段 `alert/kind/names/debuffId/style` 重建说明，接入共享 `AlertsService` + 新 `AlertHudV3`，增加 HUD 开关/锚点/字号/持续时间与“大字/倒计时”测试；修复不同 Alert 文本错误继承旧较长 expiry 的问题。自动机制匹配仍保持 Partial，禁止恢复 `CHAT_MESSAGE` 猜测。
- 新增共享 `ScreenProjectionV3 v2` 与受能力治理的 global-call primitive。`combat.unit_lines` 解除整项 Runtime Blocked，但只承诺“自己 ↔ 当前目标”的有界点状连线；`combat.range_assist` 只承诺用户自定义自身半径圆。两者均 Demand-scoped、无 Tick，范围圆用 `ProjectWorldBatch()` 一次捕获 Camera basis，避免每个点重复读取相机状态；新 `CombatVisualGuidesV3 v2` 只负责 bounded dot pool Diff 渲染并在分配失败时回滚刚取得的 Consumer。
- Trade 兼容 RU 生产/可售地区 `{[zoneId]=true}` 返回形态与 numeric-string/id-name map；可售列表为空时只以生产地区作为**候选 UI 列表**，真正路线货率仍由 `GetSpecialtyRatioBetween` 服务器结果作为 Authority。Trade/Bonds 新增独立 `life.trade` / `life.bonds` FloatingSurface，窗口自行持有/释放 Feature Consumer；普通 Trade/Craft Refresh 仍不会批量询价。
- `UIV3Acceptance v32` / `FoundationGate v58` 增加 ScreenProjection、Boss HUD、Visual Guides、Life Economy Widgets、Buff observation 与 removed-healer-widget usability contract。产品 Matrix 因用户明确移除 Healer 推荐悬浮能力缩减为 122 条，并根据最新 RU 负面证据重新降级为 `77 IMPLEMENTED / 31 PARTIAL / 3 TODO / 11 SPECIFIC_RUNTIME_BLOCKED / 0 UNREVIEWED`，不把本地修复提前宣称为 RU 完成。
- 本地验证：Foundation Audit `190/190 Active TOC + 346/346 Lua` PASS；Healer standalone calibration、Alert expiry/rearm、ScreenProjection batch、VisualGuide Consumer rollback、RU-style Trade zone shape 专项均 PASS。BuildTag：`v3-m1.16.0.18.43-combat-life-usability-recovery`。

## M1.16.0.18.42 — Business Page Logical ID / Strict Build Fail-Fast Recovery（2026-08-31）

- 修复 RU Fresh Reload 暴露的 `tools.social` 页面构建阻断：Business 通用工具条 `v3_business_<id>_actions` 在 `tools_social` 展开后与 Social 专用 `v3_business_tools_social_actions` 完全同名，导致第一个 Preflight 拒绝 Social Row，随后输入/按钮因 `parent=nil` 再产生两次 Preflight，最终 `button.onClick` 对 nil 的二次异常覆盖了真正根因。Social 专用 Row 已改为独立逻辑 ID `v3_business_tools_social_member_actions`。
- `RSUI ComponentCore` 新增 Strict Build Fail-Fast contract：严格 Page/Widget/Modal BuildScope 内，任何非 `buildOptional` 的 required 组件创建失败都会在第一次失败立即中止事务，保留原始 component/id/reason；显式 `buildOptional=true` 继续允许安全降级。BuildTransaction 在 callback 二次异常存在时优先保留 `scope.failure` 作为主因。
- Foundation Audit 新增 Business 共享页逻辑 ID 展开扫描：同时检查字面量重复与 `"..." .. id .. "..."` 对 Registry route id 展开后的固定 ID 冲突；故障注入恢复旧 Social ID 时门禁必定失败。`UIV3Acceptance v31` / `FoundationGate v57` 要求 Business component-id contract 与 Strict Build Fail-Fast contract。
- 本地验证：Foundation Audit `186/186 Active TOC + 342/342 Lua` PASS，`businessIds=0`；Business ID 故障注入 PASS；Strict BuildScope 行为测试 `required=1 / optional=1` PASS。BuildTag：`v3-m1.16.0.18.42-business-page-id-build-failfast-recovery`。

## M1.16.0.18.41 — Bag / Team / Persistence Integrity（2026-08-31）

- 修复 Bag 单槽存入方向的真实业务错误：`DepositBank/DepositCoffer` 现在始终读取背包源槽，再独立应用 bank/coffer 目标黑名单策略；不再把目标仓储同编号槽位误当源物品。四方向 source mapping 已通过专项契约测试；同时修复 Bag 投影 `tone` 运算优先级会返回布尔 `true` 的 Lua 表达式错误。
- 强化 Bag category batch 生命周期：Scheduler 创建失败立即回滚，Cancel/Feature Disable 都强制移除任务并清空 queue/runtime；页面只报告“任务已启动 + 队列数”，不再在异步任务刚入队时伪称“批量操作已完成”。
- 修正 Team Role 能力语义：bundled API 的写签名是单参数 `X2Team:SetRole(role)`，因此 Active V3 只承诺“当前玩家职责设置”，全队职责保持只读；TeamTools 在 Demand 存在时订阅 `v3.team_roster.updated`，解决 TeamRoster 延迟首刷/后续变化后职责投影长期停留旧快照的问题。
- Buff Cap 从一次快照升级为 Demand-scoped `BUFF_UPDATE` observation，高频事件以 150ms one-shot 合并后仅重读普通/隐藏数量；Consumer=0 解除事件并删除任务，不使用 Tick，也仍不猜测 RU 容量/顶替阈值。
- 修复 Activity/Tasks 专用持久化写入的 memory/store 分裂：任务追踪、scope、悬浮窗显隐，以及活动隐藏、HUD 行数/尺寸/最小化等 mutation 在 `MarkDirty` 失败时恢复原状态；复核确认公共 `Demand v2` 已自带失败反向 reconcile，因此没有重复增加一套 Demand 回滚实现。Craft 页面同时移除 Command 成功后重复执行第二次完整 Authority Refresh。
- `UIV3Acceptance v30` + `FoundationGate v56` 新增 Bag action/batch、Team role、Buff dynamic observation 与 specialized persistence mutation contract；Foundation Audit 保持 `186/186 Active TOC + 342/342 Lua`、所有静态越界计数为 0。BuildTag：`v3-m1.16.0.18.41-bag-team-persistence-integrity`。

## M1.16.0.18.40 — Demand Observation / Capability Cooldown Integrity（2026-08-31）

- 将 `ApiCapabilities.Cooldown` 从“仅元数据”提升为中央执行契约：`S.Api:CallCapability/ActionCapability` 在 Native 调用前统一消费 capability 级冷却，失败/异常调用同样不能立即重试打穿原生接口；新增可观测 cooldown state，普通无冷却能力不受影响。 Raid Applicant 的快速重复刷新在 1000ms 查询冷却内保留上一份已证明投影并显示 pacing 状态，不再因节流把列表瞬间清空。
- 修复页面生命周期遗漏：Housing / Butler / Random Shop / Instance Browser 不再在页面进入时直接 `FeatureRuntime:Enable()`，用户关闭状态保持关闭；启停只允许显式 `SetPreferredEnabled()`，页面只 Acquire/Release Consumer。开发静态门禁新增 Active V3 Presentation 直接 Enable/Disable 禁止规则。
- 修复动态功能“只有一次快照”的问题：Target Monitor 监听 `TARGET_CHANGED` 并在 Consumer 存在时以 500ms 低频刷新距离；Treasure 以 500ms Demand Scheduler 更新玩家位置/方向/距离；Fishing 对 `TARGET_CHANGED` 即时刷新，对高频 `BUFF_UPDATE` 以 100ms one-shot 合并后执行最多 128 Buff 的有界扫描。全部在 Consumer=0 时释放，无 Tick。
- Generic Business Demand 的自定义观察资源与通用事件订阅现在按同一获取事务处理；事件订阅失败会反向撤销刚创建的 Scheduler 资源，避免 Acquisition 失败留下后台任务。Business/Life Authority 更新统一发布 Feature update topic，页面订阅 detached read-model 更新；删除 AcquireConsumer 后再次 Commands.Refresh 的重复首刷路径。
- 修复真实业务闭环：Trade 异步货率结果会主动通知页面；Bonds 排序/过滤/重复优先级写入采用回滚安全持久化并触发真实 Authority 刷新；Treasure 选择、Bag batch 设置、Auction 关键词/收藏等设置在 `MarkDirty` 失败时恢复内存状态。Craft 的 Active implementation 补齐实际使用的 `X2Bag` API dependency。
- `UIV3Acceptance v29` + `FoundationGate v55` 新增 capability cooldown 与 Target/Treasure/Fishing dynamic observation contract；Foundation Audit 保持 `186/186 Active TOC + 342/342 Lua` 且所有静态越界计数为 0。BuildTag：`v3-m1.16.0.18.40-demand-observation-cooldown-integrity`。

## M1.16.0.18.39 — Feature Truth / Lifecycle Recovery（2026-08-31）

- 修正 `v3_live_ui` 对正常异步 Layout Queue 的误报：RSUI 记录 queued age / scheduler state，Foundation 只在 `hard>0`、stale root 或 unscheduled root 时告警；普通 50ms reflow 的 fresh `pending=1` 不再单独产生 Warning。
- 收紧 Business/Life 页面生命周期：打开一个用户明确关闭的 Feature 不再自动 Enable；显式开关统一走 `FeatureRuntime:SetPreferredEnabled()`，Demand 只在页面 Consumer 存在时建立，关闭后立即释放事件/共享资源。Generic Business event subscription 由 Enable 移到 Demand `0→1`，`1→0` 解除。
- 修复功能真实性与服务器查询边界：Trade/Craft 普通 Refresh 不再在材料循环中调用 cooldown-bound `GetLowestPrice`；Auction 删除错误的一参数 `SearchAuctionArticle` 调用；Team Move、Raid Create/Accept/Reject、Fishing Auto-R 等未验证写操作 fail-closed；Boss Alert 不再把 `CHAT_MESSAGE` 当机制事件；Buff Cap 不再猜测容量阈值。
- 修复 Social `GetFriendList/GetBlockList/GetMuteList` 参数差异，并修复 Lua 5.1 循环闭包捕获导致四个名单按钮可能落到最后一个动作的问题；Team Role 改为真实 `TMROLE_*` 枚举下拉。Generic Business Store 只持久化 default contract 声明字段，运行期 batch/query 状态不会污染永久配置。
- Registry/Completion Matrix 同步为真实能力状态；`UIV3Acceptance v28` + `FoundationGate v54` 新增 `v3_feature_truth_contract`，防止 Partial/Blocked 能力再次被登记为已完成。
- BuildTag：`v3-m1.16.0.18.39-feature-truth-lifecycle-recovery`。

## M1.16.0.18.38 — Life Projection Contract Recovery（2026-08-31）

- 修复 RU Fresh Reload 暴露的 `rs_v3_life_m16_pages.lua:122` 页面激活故障：`Trade` 已有公开 `GetProjection()`，但 `Bonds / Treasure / Fishing` 只实现了 Authority 级投影，导致共享生活页面调用不存在的 Feature facade。三者现在均通过 Feature 公共边界返回 detached Projection，Presentation 不直接读取 Authority。
- `rs_v3_life_m16_pages.lua` 在 `PageRoot` / Native allocation 前预检 exact Feature Projection + Commands 契约；故障注入时 4/4 生活页面均在 Native 分配前 fail-closed，避免再次形成“Factory 已注册但激活时才崩”的半构建页面。功能启停成功后同步刷新按钮/状态，并在 Disable 清空 Demand 后同步 page-local consumer 标记。
- `UIV3Acceptance v27` 新增 Trade/Bonds/Treasure/Fishing 的真实公共契约检查；`FoundationGate v53` 要求 Acceptance v27，因此这类漏导出不再能以“界面工厂存在”伪装成绿色 Foundation Gate。
- 本地专项 `life_m16_projection_contract_test`：`features=4 / detached=1 / preflight=4 / Native allocations=0` PASS；Foundation Audit `186/186 Active TOC + 342/342 Lua` PASS，所有静态越界计数为 0。RU Fresh Reload 仍需逐页打开 `life.trade / life.bonds / life.treasure / life.fishing` 关闭最终实机证据。
- BuildTag：`v3-m1.16.0.18.38-life-projection-contract-recovery`。

## M1.16.0.18.37 — Foundation Runtime Import / Authority Recovery（2026-08-31）

- 修复 RU Fresh Reload 暴露的系统性 API Import 边界错误：Feature 元数据继续使用 `X2Namespace:Method` 能力名，但 `NativeImports v3` 先映射到 namespace-scoped Native Contract 再执行 `ADDON:ImportAPI`；新增 FRIEND/AUCTION/STORE/CRAFT/RESIDENT/HOTKEY/BANK/COFFER 等当前 Active Feature 所需的 Suite-owned namespace 契约，并验证与 bundled `API_TYPE` 证据一致。
- `core/rs_api.lua` 增加调用时 Capability Host 解析；修复 Life/Business 文件在 API lazy import 前捕获 nil host 后永久失效的问题。Bag Registry 不再声明虚构 `DepositBank/WithdrawBank` 能力，改为真实 `MoveToEmpty*Slot` 方法。
- Native Import failure 现在区分 Foundation 与 Feature：单个业务 Feature Import 失败会 fault 该 Feature 并进入 warning/诊断，但不再污染整个 Native Foundation；Foundation Import 失败仍是 Blocker。
- 修复 `UIV3Acceptance` Gear Quick HUD spec ID 漂移（`combat.gear.quick`），并让 Foundation 的 `ui_foundation_matrix` 摘要输出首批失败标签；静态 Audit 新增 exact ApiCapabilities dependency 校验和 lazy-host/authority-scale 回归围栏。
- 修复 Strict Diff Authority cache-hit 的客户端缩放判断：Native extent/anchor getter 只允许额外应用 `uiScale`，不再二次乘 Suite `addonScale`。这是 RU 日志中数千次假 `AUTHORITY_VIOLATION` 的主要系统性来源；新增按 `text/visible/extent/anchor` 字段的违规计数，便于 Fresh Reload 继续定位真实外部写入。
- 本地最终门禁：Foundation Audit `186/186 Active TOC + 342/342 Lua` PASS；全 34 个 FeatureRuntime implementation 的 lazy API Initialize mock PASS，`23` 个 namespace import / `0` failure；Acceptance mock 除无法在纯 mock 复现的 UIParent root identity 外无其它 matrix failure。RU Fresh Reload 仍为最终 Native/Authority 验收 Authority。
- BuildTag：`v3-m1.16.0.18.37-foundation-runtime-recovery`。

## M1.16.0.18.36 — Craft Recursive Known-Record Graph（2026-08-31）

- Active Craft now exposes a bounded recursive graph over complete recipe records already returned by the verified X2Craft getters, with ceil output-batch quantities and visible cycle, ambiguity, missing-material, overflow, depth, and node-limit diagnostics.
- The graph does not enumerate the unverified full catalog or claim complete recursive market cost. Dedicated `craft_v3_recursive_graph_test.lua` and the full local set pass `42/42`; Foundation Audit remains `toc=186 activeLua=186 allLua=342` with all escape counters zero.
- BuildTag is `v3-m1.16.0.18.36-craft-recursive-graph-gate`.

## M1.16.0.18.35 — Bag Window Context / Embedded Quick Actions（2026-08-31）

- Active V3 `tools_bag` now projects four Command-driven embedded quick actions and a capability-gated `ADDON:GetContentMainScriptPosVis` bag-window diagnostic. Native follow remains `diagnostic_only` and unknown embedding remains `fail_closed` because no verified reparent/embed API is available.
- Dedicated `bag_v3_window_context_test.lua` and the full local set pass `41/41`; Foundation Audit remains `toc=186 activeLua=186 allLua=342` with all escape counters zero. RU native reparent/embed and multi-resolution visual follow remain pending.
- BuildTag is `v3-m1.16.0.18.35-bag-window-context-gate`.

## M1.16.0.18.34 — Team Actions / Party Movement（2026-08-31）

- Active V3 `combat_team_tools` now exposes bounded role assignment, numeric member exchange, and move-to-party actions through Feature Commands matching the verified RU Team signatures; Presentation and Command Authority both validate role `1–999` and member/party indices `1–50`.
- Command failure or projection refresh failure is surfaced without false success. Dedicated `team_tools_roster_roles_test.lua` and the full local set pass `40/40`; Foundation Audit remains `toc=186 activeLua=186 allLua=342` with all escape counters zero. RU permission/cooldown/result and visual round-trip remain pending.
- BuildTag is `v3-m1.16.0.18.34-team-actions-gate`.

## M1.16.0.18.33 — Auction Favorite / Context UX（2026-08-31）

- Active V3 `tools_auction` now normalizes and persists a bounded keyword/favorite context (maximum 20 favorites), exposes explicit add/remove/search commands, and provides stable-index 8-row paging with refresh-safe selection.
- Search state is reported as `pending`/`failed`; result fields remain explicitly `unknown` until the RU native result schema is verified. Dedicated `auction_v3_favorite_context_test.lua` and the full local set pass `40/40`; Foundation Audit remains `toc=186 activeLua=186 allLua=342` with all escape counters zero.
- BuildTag is `v3-m1.16.0.18.33-auction-favorite-context-gate`.

## M1.16.0.18.32 — Craft Product / Cost / Shortage Projection（2026-08-31）

- Active Craft now enriches bounded structured product/material rows with Bag held-count aggregation, shortage, grade-aware lowest-price quotes, and line costs through governed API calls; Bag read failures/unknown occupied slots, bad quotes, and opaque/truncated payloads remain `incomplete/unknown`.
- Dedicated `craft_v3_cost_shortage_test.lua` and the full local set pass `39/39`; Foundation Audit remains `toc=186 activeLua=186 allLua=342` with all escape counters zero. Recursive subrecipe expansion, total graph cost, full RU field parity, and Fresh Reload remain pending.
- BuildTag is `v3-m1.16.0.18.32-craft-cost-shortage-gate`.

## M1.16.0.18.31 — Bag Category Batch Deposit（2026-08-31）

- Active V3 `tools_bag` now supports explicit category-based batch deposit to bank or coffer with persisted category/target/limit settings, bounded 1–40 queue, target-window/capacity/empty-slot checks, blacklist fail-closed handling, shared Scheduler step execution, strict source-slot verification, cancel, failure-stop, and status projection/refresh.
- Dedicated `bag_v3_category_batch_test.lua`, the existing Bag action/blacklist harnesses, and the full local set pass `38/38`; Foundation Audit remains `toc=186 activeLua=186 allLua=342` with all escape counters zero. RU category field, storage window, and move timing/return verification remain pending.
- BuildTag is `v3-m1.16.0.18.31-bag-category-batch-gate`.

## M1.16.0.18.30 — Bonds Filter / Duplicate Priority（2026-08-31）

- Active V3 Bonds now persists q20/q60/q100/Auroria filters, quantity/continent sorting, and mainland duplicate priority through the existing Store/Commands path.
- Filtering is applied before projection; reliable west/east row identity selects the configured priority, while unresolved identity preserves duplicate rows and emits an explicit diagnostic. Page controls refresh the table and visibly report enabled/disabled state.
- Dedicated Bonds filter coverage passes; the current full harness set is `37/37`, Foundation Audit remains `toc=186 activeLua=186 allLua=342` with all escape counters zero. RU board-field and visual round-trip verification, plus remaining product capabilities, are still pending.
- BuildTag is `v3-m1.16.0.18.30-bonds-filter-priority-gate`.

## M1.16.0.18.29 — Bonds Completion / Resource Projection（2026-08-31）

- Active V3 Bonds now resolves governed mainland and Auroria bond mappings without loading Legacy Resident service code, and projects `QuestProgressV3` states as completed, turn-in-ready, in-progress, not accepted, or unknown.
- Bonds performs a demand-scoped bounded bag scan (`min(Capacity, 240)`), aggregates verified item/stack field fallbacks, and exposes required quantity, held quantity, shortage, and visible partial/unknown diagnostics. Auroria token quantities remain unknown unless a safe identity is proven.
- Mainland `materialKey:quantity` completion keys are dated and persisted in `S.State.life.bondCache`, so duplicate rows across mainland continents share the same daily completion authority. The page adds resource, shortage, resource-status, and task-status columns.
- Registry dependencies/evidence and the maintenance addendum were synchronized. Dedicated Bonds coverage and the complete local harness set pass: `36/36`; Foundation Audit passes `toc=186 activeLua=186 allLua=342` with all escape counters zero. RU Fresh Reload, real field parity, and remaining filter/priority UX remain pending.
- BuildTag is `v3-m1.16.0.18.29-bonds-completion-resource-gate`.

## M1.16.0.18.28 — Business Feature Migration Closure / Runtime Blocker Fence（2026-08-31）

- 依据当前源码重新审计 34 个 combat/life/tools 业务条目；Trade、Bonds、Treasure、Fishing 完成独立 V3 垂直切片，另外 17 个条目接入独立业务桥与通用 V3 页面，Legacy 只作为规格参考。
- Registry 业务停止统计收敛为 `26 implemented/migrated + 8 runtime_blocked + 0 planned`。Fishing 明确阻塞于完整 R 源槽位枚举、快照、写入/还原和异常恢复契约，不把 `autoArmed` 会话标记当作功能完成。
- 新增注册表完成度契约（34/8/0）与 21 条新增页面工厂闭包/路由契约；修复 Trade 页面循环工厂捕获、业务页面循环工厂捕获，并为 Trade 在材料静态数据与拍卖最低价均可证明时输出材料成本/毛利。
- 最终复跑结果：Foundation Regression Gate `toc=186 activeLua=186 allLua=342 globals=0 presentation=0 rawNative=0 rawScope=0 detachedWidgetState=0`，Active Lua Parse `186/186`，本地 Harness `28/28`；RU Fresh Reload、真实 Native 页面构建/关闭/重开及字段验收仍未被本地门禁替代。

## M1.16.0.18.27 — Foundation Gate / BuffDisplay Schema Parity（2026-08-31）

- 修复 `rs_foundation_gate.lua` 仍以 schema 1 检查 `v3.buff_display` 的门禁漂移，使 Foundation Gate v51 与 BuffDisplay Store schema 2、Feature Acceptance 保持一致。
- 修复后重新执行 Foundation Audit `182/182 + 338/338` 与 24 个本地 Harness，全部通过；RU Fresh Reload 仍待验收。

## M1.16.0.18.26 — Detached Floating State / BuffDisplay Persistence Fence（2026-08-31）

- FloatingSurface 与 CreateStateAdapter 支持 detached getState + setState 提交回调；Surface/适配器的持久化失败路径会恢复旧 snapshot，避免 UI 适配器直接原地修改 Feature Store。
- Activity、Task、DPS、DeathReview、BuffDisplay、Healer 六个 Active Floating Widget 的状态写回统一经 Feature.Commands:SetWidgetWindowState()；Foundation Audit 新增 detached widget state 静态 fence。
- BuffDisplay Store 从 schema 1 升至 schema 2，复用完整 FloatingSurface:NormalizeState()，修复原 NormalizeRect() 丢失 locked/minimized/opacity/fontScale 的持久化缺陷。
- 新增 floating_surface_detached_state_test.lua 7/7；BuffDisplay Feature Harness 扩展为 12/12；最终 Foundation Audit 182/182 + 338/338，24 个本地 Harness 全部通过。

## M1.16.0.18.25 — Active Presentation Command Fence Follow-up（2026-08-31）

- 修复 Foundation/Gear HUD/Gear Snap Modal 直接调用 Feature 写方法的问题；Activity/Gear/Instance/Buff 刷新、显隐、尺寸、外观与 Snap 设置统一经 `Feature.Commands`。
- Gear QuickHud 增加 detached `GetQuickHudProjection()`，Widget 不再保留可写内部状态表；边界 Harness `34/34`、Foundation Audit `182/182 + 338/338`、23 个本地 Harness 全部通过。

## M1.16.0.18.24 — Presentation Private-Field Fence Follow-up（2026-08-31）

- 修复 Foundation 页面对 `Activities.StoreId`、`Gear.IndexStoreId`、`Activities.WidgetWindowSizePolicy` 的直接读取；持久化绑定改用稳定本地 Store ID，窗口策略改走公开 `GetWidgetWindowPolicy()`。
- Foundation Audit 新增 `S.Features.<Feature>.<private>` 形态的静态拦截；当前 Foundation Audit `182/182 + 338/338`、Presentation boundary `34/34`、23 个本地 Harness 全部通过。

## M1.16.0.18.23 — Feature Demand Quiesce Coverage（2026-08-31）

- Activity/Task/Instance/Raid Readiness 的 Feature Demand 增加下游资源 `quiesce` 清理，覆盖 Scheduler、事件、QuestProgress、InstanceCatalog、Roster 与 Aura；Runtime 强制静默成功后同步 implementation/runtime 的 disabled projection，并把 stale demand 记为 shutdown failure。新增 `feature_demand_quiesce_contract_test.lua` `22/22`，shutdown harness 更新为 `14/14`。
- QuestProgress/InstanceCatalog Service Demand 补齐 `quiesce`：停止事件、RefreshCoordinator、Scheduler，并释放 QuestProgress 持有的二级 InstanceCatalog lease；新增 `demand_service_quiesce_contract_test.lua` `9/9`。
- `FeatureRuntime:DisableAll()` 现在同时检查 runtime row 与 implementation-local enabled flag；即使两者失配也会执行 teardown，防止状态投影异常掩盖运行时资源。

## M1.16.0.18.22 — WidgetHost Callback Failure Fence（2026-08-31）

- `WidgetHost` 对 `preference/enabled` 生命周期回调建立逐绑定 `xpcall` 隔离；单个坏绑定不再中断同一事件的其它 Widget，并记录 `V3_WIDGET_LIFECYCLE_CALLBACK_FAILED`。新增 `widget_host_callback_fence_test.lua` `13/13`。

## M1.16.0.18.21 — PageHost Navigation Rollback Fence（2026-08-31）

- `PageHost:Navigate()` 检查 `OnRoute/OnDeactivated` 的显式拒绝；Switcher 拒绝或目标激活失败时恢复旧页面路由、上下文、可见页与激活生命周期，并以旧 route 作为恢复激活来源。新增真实加载 PageHost 源码的 `page_host_navigation_rollback_test.lua` `16/16`。

- `FeatureRuntime:DisableAll()` 聚合失败并暴露 `lastDisableAllFailures`；残留 Feature Demand 会进入 `ForceQuiesce`，即使强制清理成功也会保留 stale-demand failure 诊断，避免隐藏泄漏被报告为绿状态。真实加载 Runtime 源码的 shutdown harness 为 `12/12`。

## M1.16.0.18.19 — Presentation Boundary / Housing Read-only（2026-08-31）

- Active V3 Presentation 的内部字段访问已收紧：页面/悬浮组件不再读取 `Feature.Id`、`enabled`、`revision`、`projections`、`consumerCount`、Store ID、窗口策略或 Quick Button 策略字段；设置读取统一使用 detached `*Projection`，刷新/生命周期写入统一使用 `Feature.Commands`。
- Foundation Audit 新增 Presentation 内部字段、旧 Settings getter 和直接 Refresh getter 静态围栏；强化后的 `v3_presentation_boundary_test.lua` 为 `34/34`，防止“能解析但页面运行时越过 Feature 边界”的回归。
- 新增 `life.housing` V3 只读 Page / Feature / Authority：仅按页面 Consumer、按需调用已登记的四个零参数 `X2House` getter，统一输出 ready/partial/unavailable 投影，不执行住宅写操作、不后台轮询、不猜测住宅上下文数据。
- 住宅、随机商店与管家页已加入已迁移 Presentation 矩阵；最终 Foundation Audit 为 `TOC 182/182`、Active Lua `182/182`、全 Lua `338/338`，Unexpected global / Presentation escape / Raw Native / Raw BuildScope 均为 `0`。
- `tools.reinforce_analysis` 暂不伪装完成：官方 getter 已登记，但槽位参数、返回结构和客户端上下文仍缺 RU 真机证据，因此继续保持 `planned_verified` / Runtime Pending，不创建猜测型页面或强化写操作。
- 新增 `tools.random_shop` 只读 Feature/Authority/Page：仅读取官方刷新次数 getter；商店开启状态、条目列表和刷新动作没有被当前 API 证明，全部不推断。
- 新增 `life.butler` 只读 Feature/Authority/Page：仅读取官方 `GetChargeInfo()`，不接入管家装备、交互或其它写动作。
- 已迁移 Presentation 矩阵现在显式关联 `v3_quest_detail_modal` 与 `v3_gear_quick_settings_modal`；新增 Foundation Sequence `v3_39_modal_build_matrix`，实际构建两个 Modal，换装设置 Modal 额外执行 Open/Close 栈回归，任务详情 Modal 不伪造 RU 任务 key。
- 本轮最终本地门禁目标更新为 Foundation Audit `TOC 182/182`、Active Lua `182/182`、全 Lua `338/338`；Modal 运行序列与全部页面/悬浮窗序列仍需 RU Fresh Reload 实际执行。

## M1.16.0.18.18 follow-up — Local Foundation Re-audit（2026-08-31）

- 重新执行当前本地项目的 Foundation Regression Gate：`FOUNDATION_AUDIT PASS`，Active TOC `170/170`、Active Lua `170/170`、全 Lua `326/326`，Unexpected global / Presentation escape / Raw Native / Raw BuildScope 均为 `0`。
- UIV3Acceptance 升至 v25：已迁移页面路由必须存在专用 PageHost factory；具备悬浮窗的已迁移路由必须存在对应 WidgetHost spec，防止路由静默落入 planned fallback placeholder。
- 新增 Foundation Sequence `v3_37_migrated_page_build_matrix`：在 RU 客户端按矩阵实际调用 10 个已迁移 PageHost factory，并继续遍历 FeatureRegistry 当前 39 个 Active Route（planned 路由走 fallback）；同时对 7 个已迁移悬浮窗执行 WidgetHost `EnsureInstance`。构建失败、Generation quarantine 或可见性恢复失败都会直接成为序列失败。
- 新增 Foundation Sequence `v3_38_floating_policy_zero_defaults`，在客户端运行时直接验证 FloatingSurface 的透明度策略默认值与兼容 alias 能保留显式 `0`。
- 复核 RU 客户端日志发现 `core/rs_theme.lua:219` 的真实类型错误：字符串对齐值会直接传入 Native `SetAlign`。现在由 Theme 统一将 `left/center/right/top-left` 归一化为 RU 数值常量；新增 Theme alignment contract `4/4`。既有日志错误来自本次修复前运行，修复后的 Fresh Reload 仍待执行。
- 修复开发工具 `rs_foundation_audit.py` 对当前运行环境的编译器探测：优先使用 `texluac`，不可用时使用等价的 `luac`，不降低任何审计规则。
- 现有 13 个基础 Lua harness 加上本轮 5 个专项 harness，共 18 个本地 Lua harness 全部复跑通过；其中框架生命周期回归 `112/112`。RU Fresh Reload、逐路由真实 Native 构建与真实 Aura/团队字段仍必须在客户端完成。
- 新增 Persistence migration harness：覆盖空存档、N-1 schema 迁移、future schema 写保护、metadata mismatch 写保护、显式空表和 cyclic payload 拒绝，共 `12/12`。
- 修复 AuraObservationV3 与 HealerAuraBridge 在 Tooltip=nil 时的 Lua 5.1 fallback 截断：不再用包含 nil 的 `{primary, secondary}` 配合 `ipairs`，现在能正确保留 Data Row 的 stack/timeLeft/name/icon；Aura 共享服务与 Healer fallback 回归 `18/18`。
- Foundation Audit 新增同类 Lua 5.1 nil-unsafe fallback list 静态拦截，避免该类回归再次等到页面运行时才暴露。
- 修复公共 `FloatingSurface` 策略默认值对显式 `0` 的误判：透明度策略现在按“非 nil”选择 primary/alias，`0` 不再被 Lua `or` 当作缺失；新增本地策略契约回归 `6/6`。

## M1.16.0.18.18 — Foundation Regression Gate Hardening（2026-08-30）

- 新增开发态 `tools/rs_foundation_audit.py`：Active TOC/全 Lua Parse、bytecode `_ENV` 未声明全局、Presentation 全局/Native/私有边界、Raw Native constructor、Raw BuildScope、已知 Lua5.1 stable capture 一次性封包门禁；负向注入测试可正确拒绝新未定义全局。
- 审计实际发现并修复 `features/combat/healer/rs_healer_feature.lua` 的 `Recommendation()` 未定义全局，改为读取 Feature 持有的 `self.Recommendation`。
- RSUI 升 v24/API 10.9：BuildScope v3、BuildTransaction v1、Preflight v1、LogicalIdGenerationFence v1；close-order 违规会 fail-closed 回滚泄漏 descendant scope 并恢复活动栈；新增 transaction/preflight/close-recovery 指标。
- `PageHost v4 / WidgetHost v13 / ModalHost v5` 统一使用 `WithBuildScope()`；Widget 的 `windowingRequired` 在 Commit 前验证，避免半有效 Surface 被提交后再 quarantine。
- `RSUI:ValidateSpec()` 在 factory/native allocation 前拒绝 logical ID 重复与基础 spec 错误；一旦通过 preflight，logical ID 即标记为本 Generation consumed，rollback/release 后也不允许用相同 Native identity 重建；首批为 Table/TableView、SegmentedSelector、NumericField 增加专属 validator。
- FoundationGate 升 v50 / UIV3Acceptance v24；Fresh Generation 将 close-order recovery、preflight failure、transaction failure、page/widget quarantine 作为 Blocker。BuildTag `v3-m1.16.0.18.18-foundation-regression-gate`。


## M1.16.0.18.17 — Floating Stability / Analytics Recovery（2026-08-30）

- 修复战斗分析页面 `pairs(nil)`：Presentation 错误引用 Feature 私有 `VALUE_OPTIONS`，现改为 Feature detached `GetValueSelectorModels()`。
- 移除 DPS Widget 自建外观编辑器；所有 Floating 外观统一由 WindowShell 标题栏“外”入口管理。
- NumericInline 升 v3：窄 HUD 外观行优先保证 Slider 轨道，标签/精确输入收窄；WindowShell 升 v19 / titleAppearanceContract v3。
- Tasks / DeathReview Widget 补齐 fontScale parity。
- Appearance lazy build 增加同 Generation 失败闩锁，避免失败后重复创建保留 Native id。
- FoundationGate v49 / UIV3Acceptance v23；BuildTag `v3-m1.16.0.18.17-floating-stability-analytics-recovery`。


# 2026-08-30 · M1.16.0.18.16 — Floating Appearance Slider Layout

- 修复公共 Floating 标题栏“外观”面板在极窄 HUD 中 Slider 过短：根因不是业务窗口宽度，而是 `NumericField inline` 固定 44px label floor + 54px input floor，导致两字标签仍占过多空间。
- `NumericInlineContractVersion` 升至 v2，新增 `labelMinWidth / labelMaxShare / inputMinWidth / sliderMinWidth`，默认值保持普通页面历史布局；只有明确的紧凑 Consumer 才能缩小标签/输入下限。
- WindowShell 外观 4 行改为 26–30px 标签、44–48px 精确输入、至少 44px Slider，gap/padding 同步收紧；整体/背景/文字/字号仍共用同一 Binding/持久化 Authority，无新增 Store 或后台任务。
- WindowShell v18、FoundationGate v48、UIV3Acceptance v22；BuildTag `v3-m1.16.0.18.16-floating-appearance-slider-layout`。RU Fresh Reload 仍需确认极窄活动/DPS/Healer 悬浮窗中的 Native Slider 实际拖动宽度与命中。

# 2026-08-30 · M1.16.0.18.15 — Floating Chrome / Activity Responsive / Analytics Value Switch

- WindowShell v17 / FloatingSurface v9 新增统一标题栏外观入口：所有 FloatingSurface 默认显示轻量“外”按钮，整体/背景/文字透明度与局部字号使用 Slider + 精确输入；外观面板按需 lazy 构建，不在每个隐藏 HUD 初始化时预创建 4 组 NumericField，也不新增 Tick/Scheduler。锁定与重置布局一并收敛到该面板。
- Activity HUD 进一步压缩 title/footer/padding，并让 TableView 使用 overlay scrollbar；滚动时不再永久扣除右侧轨道宽度，三列使用 fill + 较低 absoluteMinWidth 随实际 viewport 重新求解，关闭用户列宽拖动，避免缩窄窗口后出现大块无用黑边或旧宽度残留。Activity 同时补齐 WidgetHost fontScale capability。
- Combat Analytics 将“击杀/助攻/死亡”等指标值从二级 Dropdown 改为直接 `SegmentedSelector`；点击即经 `Feature.Commands:SetSelectedValue` 更新唯一 Store Authority。Store 增加 metric/value 白名单校验，拒绝无效 key；新增 `v3_m16_18_15_analytics_value_switch_contract` Sequence Case。
- FoundationGate 升 v47，门禁 WindowShell title appearance、FloatingSurface appearance 与 DataView overlay scrollbar；UIV3Acceptance 升 v21。Active TOC / 全 Lua 与专项 Harness 需以本轮最终封版重跑结果为准；RU 仍需 Fresh Reload 验证实际标题栏层级、透明度预览、Activity 极窄窗口和战斗分析点击。

# 2026-08-30 · M1.16.0.18.14 — UX Interaction Polish / Floating Detail

- FloatingSurface / WindowShell 新增 compact-minimize contract：HUD 标题栏进一步收紧，最小化改为约 32×32 的恢复方块，而不是保留整窗宽度的长条；业务 Widget 继续只使用公共 WindowShell Chrome。
- RSUI 新增 opt-in `NumericField inline` / `UIV3Design:CompactNumericSetting()`：有限范围数值统一复用同一 Binding，按“名称 + Slider + 精确输入框”单行排列；Healer 主设置/显示设置/高级数值、DPS 悬浮外观以及其它有限范围设置开始采用该交互。
- Healer 主页面设置区改为紧凑 UniformGrid，并加入“治疗策略 / 战斗显示”切换，避免两大设置面同时挤占实时推荐区域；Raid Calibration 底色恢复 `artwork` layer 并提高可见 Alpha，保持零额外 Health/Aura 扫描。
- DeathReview 新增单条删除 Command/Store transaction：先事务删除 authoritative history index，再 best-effort 清理 record shard；页面增加“删除选中”，不再只能整批清空。
- Task / Activity 悬浮窗点击行时改用独立 `QuestDetailFloatingV3`；详情只读 `QuestProgressV3` projection，不再调用 `ModalHost:EnsureApplicationVisible()` 唤起主菜单，且不建立第二 Feature/Store Authority。
- 本轮全项目 Lua `326/326`、Active TOC `170/170`；DeathReview 删除事务 Harness PASS，UX contract 静态 Harness `11/11`。真实窗口尺寸、校准底色和 Slider 拖动仍需 ArcheRage RU Fresh Reload 实机验收。

# 2026-08-30 · M1.16.0.18.13 — Active Presentation Mutation Authority

- Active V3 Page/Widget 不再直接调用 Feature 的 Binding setter 或 `MarkStoreDirty`；DPS、DeathReview、Gear、Raid Readiness、Activity、Task、BuffDisplay 的展示写入统一经对应 `Feature.Commands`，保留 Domain/Store 的 Normalize、rollback、dirty 与生命周期语义。
- `v3_presentation_boundary_test.lua` 新增 Active mutation scan、Feature command facade 合同与 Acceptance guard，扩展至 `25/25`；所有 13 个本地 Harness `244/244`，全项目 Lua 解析 `325/325`，Active TOC `169/169`，Active V3 direct State/Authority `0`。
- 本里程碑只收口源码可证明的 Presentation→Feature mutation Authority；RU Fresh Reload、真实规则/设置保存回读、视觉交互与多人性能仍待实机验收。

# 2026-08-30 · M1.16.0.18.12 — Healer Command Authority Boundary

- Healer Active V3 Page/Widget 不再直接调用规则、Tracked Buff、颜色、视觉布局、Roster 刷新或 Store dirty mutation；这些写入统一进入 `v3.healer` 的 `Feature.Commands`，保留 Store Normalize/MarkDirty rollback 与生命周期 lease 语义。
- `rs_healer_aura_acceptance.lua` 新增 Commands facade 合同；Presentation boundary Harness 扩展至 `21/21`，并增加 Healer Page/Widget/Raid Overlay direct mutation 扫描。
- 更新 Healer Architecture 中 schema 3 与 Commands API 文档；本轮全量回归为 13 个本地 Harness `240/240`，全项目 Lua 解析 `325/325`，Active TOC `169/169`，Healer direct writes `0`。
- 本里程碑只收口代码层 Presentation→Feature mutation Authority；RU Fresh Reload、规则保存回读、长文本/下拉降级、Head/Raid 视觉与多人性能仍待实机验收。

# 2026-08-30 · M1.16.0.18.11 — Factory Reset / Aura Store Contract

- `Storage:BuildFactoryResetKeys()` 现在清除 Aura Library manifest 与 `a/b/c × 32` 固定分片空间；Suite-owned Store 仍从 `Persistence:GetPersistentKeys()` 自动纳入，专业模块继续由各自 Authority 提供 bounded key 集合。
- Factory Reset 完成后会清除旧代内存 dirty 状态、设置 one-shot generation fence，并 quiesce ModuleManager/Events/Scheduler，避免 UI reload 前把旧配置写回刚清空的存档。
- P0-1 `GetEffectIds` 重复定义已收口为单一 Authority：Alerts 省略 `scanLimit` 时完整扫描，Manager discovery/capture 继续使用 bounded rolling slice；新增 `.workbuddy/tmp/factory_reset_contract_test.lua` 覆盖两条 P0 契约，共 `13/13`。
- 改动后 13 个本地 Harness 合计 `237/237`，全项目 Lua 解析 `325/325`，Active TOC `169/169`，Active V3 direct State/Authority 与 UI false-show bypass 均为 `0`；RU Fresh Reload 仍待验收。

# 2026-08-30 · M1.16.0.18.10 — Active Presentation Authority Boundary

- 将 Gear、Instance Browser、Raid Readiness 的 Active V3 Page/Widget 从直接持有 `Feature.Authority` 收口到 Feature Projection getter 与 Commands；Gear 的方案/快捷按钮操作、Raid Readiness 的取消扫描都保留原有事务语义。
- Gear Feature 新增公开 Projection/Command 面，Instance/Raid Readiness 新增 rows/row/summary getter；Raid Readiness 的 Aura 释放由 `CancelScan` 统一处理，避免页面自行拆生命周期。
- Presentation boundary Harness 扩展至 `18/18`；改动后 12 个本地 Harness 合计 `224/224`，全项目 Lua 解析 `325/325`，Active TOC `169/169`，Active V3 direct State/Authority 均为 `0`。
- 本里程碑只处理 Active Presentation 对 Feature Authority 的源码边界；更深的 planned Feature、Plates 内部 concern 拆分，以及 RU Fresh Reload/真实视觉/多人证据仍继续保留在待办图中。

# 2026-08-30 · M1.16.0.18.9 — Activity/Task Projection Boundary

- Activity/Task Active V3 Page/Widget 不再直接持有 `Feature.Authority`；读取统一经过 Feature Projection getter，刷新、隐藏活动、恢复隐藏与展开任务统一经过 Feature Commands/Presentation command boundary。
- 保留刷新语义：Activity 页面手动刷新仍执行区域扫描，脏事件刷新只更新已有投影，避免把边界收口变成额外轮询；Task Widget 的显示行数 getter 与任务 projection getter 分离。
- Presentation boundary Harness 扩展至 `14/14`；改动后 12 个本地 Harness 合计 `220/220`，全项目 Lua 解析 `325/325`，Active TOC `169/169`。
- 该里程碑只收口 Activity/Task 可由源码证明的 Authority 越界；其它页面仍有成熟 Authority projection 直连待按业务域继续拆分，RU Fresh Reload 与真实运行证据仍单独验收。

# 2026-08-30 · M1.16.0.18.8 — V3 Presentation Read Models

- 收紧 Active V3 Page/Widget 的 Store 边界：Activity、Task、DeathReview、DPS、BuffDisplay 的窗口几何统一经 `GetWidgetWindowState()`，Activity/Task 的行数与显隐偏好经窄 getter，Task 页面作用域与 Gear 页面方案计数经公开 read model 获取。
- Activity/Task Floating Widget 的显隐持久化统一走 Feature Commands；native close/自动显示失败继续使用 Domain 提供的 reset command，不再由 Presentation 直接改写 `Feature.State`。
- 新增 `.workbuddy/tmp/v3_presentation_boundary_test.lua`，覆盖 18 个 Active V3 Page/Widget 文件的 direct `Feature.State` 禁止、read-model getter 和 Commands 合同，共 `12/12`；改动后 12 个本地 Harness 合计 `218/218`，全项目 Lua 解析 `325/325`，Active TOC `169/169`。
- 本里程碑仅收口当前源码可证明的 Presentation read-model 越界；Page/Widget 仍有部分成熟 Authority projection 调用待更深拆分，RU Fresh Reload、真实 Authority/视觉/多人证据仍单独验收。

# 2026-08-30 · M1.16.0.18.7 — Plates Concern Facades

- 将 Legacy Plates Storage 的只读诊断细化为 Persistence、Tracking、Aura Library 三个 concern 快照；保留原有扁平字段兼容，且所有快照都只读取内存，不调用 `Get()/Load()/Save()`。
- 将 Legacy Plates Manager 的只读诊断细化为 Catalog、Discovery、Capture、Aura Import Staging 四个 concern 快照；Discovery cursor 返回 detached copy，避免诊断调用者反向修改 Manager 会话状态。
- Runtime Diagnostics 新增 `storageConcerns` / `managerConcerns` producer，继续通过已有 Suite Diagnostics 链输出；不改变双 Bank / Shard 协议、Runtime lane、扫描频率或 Legacy 是否进入 Active TOC 的裁定。
- 新增 `.workbuddy/tmp/plates_concern_facade_test.lua`，覆盖 concern composition、无 Load/Save/Scan、cursor 隔离和 Runtime producer，共 `14/14`；本轮 11 个本地 Harness 合计 `206/206`，全项目 Lua 解析 `325/325`，Active TOC `169/169`。
- 更深的 Manager Tracking/Classification/Transfer/Presenter 与 Storage Model/Transaction engine 仍需在不改变成熟协议的前提下继续拆分；RU API/服务器/玩家数据依赖仍不虚构为完成。

# 2026-08-30 · M1.16.0.18.6 — V3 Visibility Authority Cleanup

- 收紧 V3 可见性清理边界：`RSUI:EndBuildScope()` 回滚、`UI:ReleaseOwner()`、重复注册拒绝和 Primitive degraded 隔离统一经过 `UI:SetVisible()` / `SetEnabled()` / `SetPickable()` Authority，不再把 Diff cache 的 `false`（无变化或拒绝）误当作允许原生直写的信号。
- `MarkPrimitiveDegraded()` 先完成统一 Authority 的 fail-closed 隔离，再设置 degraded 标记，避免 degraded 后续调用被状态门禁短路；保留构造阶段的原生初始写入，不扩大改动范围。
- 新增 `.workbuddy/tmp/ui_visibility_authority_test.lua`，覆盖 Owner Release、BuildScope rollback、重复注册拒绝与 degraded 隔离，共 `8/8`；本轮十个本地 Harness 合计 `192/192`，全项目 Lua 解析 `325/325`，Active TOC `169/169`。
- 该里程碑仍只代表代码层收口；RU Fresh Reload、真实 `v3_authority_clean`、页面视觉与多人验收继续单独记录，不把静态契约测试当作实机 PASS。

# 2026-08-30 · M1.16.0.18.5 — Plates GameData Semantic Relations

- 新增 `data/ids/rs_plates_ids.lua`，把 Legacy Plates 已有的 31 个重要冷却探测项、3 个魔法阵候选 Buff、目标护甲/武器状态集合与 22969 计时修正登记到共享 `GameDataRegistry`；全部保留 `curated / verified=false` 元数据，不把兼容 ID 伪装成数据库事实。
- `rp_runtime.lua`、`rp_api.lua`、`rp_storage.lua` 改为读取共享语义集合；移除对应的重复内联 ID Authority。冷却显示仍只读取实时 RU cooldown getter，目标装备仍在白名单未命中时返回未知，魔法阵 ID 仍列为 RU 实机验证项。
- 新增只读 `rp_storage:GetHealth()`、`rp_manager:GetHealth()` 与 Runtime `storage/manager/dataRelations` 诊断 Facade；Suite 诊断摘要现在能显示 Plates Schema、Tracking/Aura 分片、Dirty、write fence、目录/发现/捕获 staging 状态，不触发 LoadData/SaveData 或新的 RU 扫描。
- 新增 `.workbuddy/tmp/plates_game_data_contract_test.lua`，覆盖集合注册、计数、未验证元数据、Registry 完整性、三个 Legacy 消费端无重复内联表与 Manager/Storage Diagnostics Facade；`21/21` 通过。Professional Plates 仍不回接 Active V3 TOC。

# 2026-08-30 · M1.16.0.18.4 — Buff/Plates StatusMap Consumer

- 新增 `combat.buff_display` Active V3 Feature：`AuraObservationV3:GetStatusMap()` 是唯一 Aura 事实入口，Feature Demand 只在 Page/Widget 有 consumer 时持有 Aura lease；player/target 的 Buff、Debuff、Hidden projection 有 bounded row 与 `available/complete/reliable` 覆盖元数据。
- 新增 `v3.buff_display` Store、V3 状态显示 Page 与 Floating Widget；页面只调用 Feature Projection/Commands，Legacy Professional Plates Runtime 未重新接回 Active TOC。
- 新增 `v3_m16_18_4_buff_display_statusmap_contract` acceptance，覆盖 Registry/Store/Aura/Page/Widget/Demand 冷态合同与纯 Lua projection 排序/过滤。
- Diagnostics 快照/摘要与 FoundationGate 新增 BuffDisplay 健康、demand scope 和资源生命周期检查；`.workbuddy/tmp/buff_display_diagnostics_test.lua` `4/4` 验证冷态/启用态诊断投影。该里程碑当时 Active TOC `168/168`、全项目 Lua `324/324`；projection `4/4`、Feature lifecycle `8/8`，证明过滤/排序和 Enable→Acquire→StatusMap→Release 生命周期链通过。RU Fresh Reload、真实 Aura 字段/图标/时间与目标切换仍待验收。
- FoundationGate 升至 v45，新增 BuffDisplay StatusMap contract blocker 与 demand/resource scope warning。
- WindowShell 构建失败的早期隐藏清理统一改走 `UI:SetVisible(window, false, owner)`，不再在 RSUI Authority 外直接调用原生 `window:Show(false)`；新增 `window_shell_authority_test.lua` `5/5` 验证回滚、owner 与原生直写隔离。
- Legacy Plates residual audit 补齐 `SetIconPath` 的 texture-path Diff cache，并新增 `plates_ui_diff_contract_test.lua`；Lines/Circle active-range、Effect Slot geometry/color/visibility 与 `plates:*` owner contract 均由本地门禁锁定，Professional Plates 仍不回接 Active TOC。

## 2026-08-30 · M1.16.0.18.3 — Strict V3 Build Failure Fence
- RSUI BuildScope 为 Page/Widget/Modal/Main Shell 标记严格构建作用域；非 `buildOptional=true` 的组件创建失败会记录原始错误、拒绝成功 Commit，并沿既有逆序 Release/Detach/Hide 回滚。
- PageHost 与 WidgetHost 现在检查严格作用域的 Commit 结果并进入当前 Generation quarantine；ModalHost/Main Shell 同样不再把严格构建失败误报为成功。
- Form Field 的 Label/Validation/Toggle/NumericInput/Dropdown 关键构造失败立即向上返回具体错误，避免页面保留半成品字段后在激活/布局阶段才空指针。Healer 高级编辑器的文本框显式标记为可选降级能力。
- FoundationGate 升至 v44，增加严格 BuildScope contract 门禁。
- 新增 `.workbuddy/tmp/strict_build_scope_test.lua`：required failure、optional degradation、healthy commit 共 `6/6`；在 M1.16.0.18.3 当时 Active TOC `162/162`、Active Lua `162/162`、全项目 Lua `318/318` 通过。

## 2026-08-30 · M1.16.0.18.2 — Healer Advanced Editors / Native Cache Fence
- `v3.healer` Store 新增统一的 `SetRule` / `AddRule` / `RemoveRule`、`SetTrackedBuff` / `AddTrackedBuff` / `RemoveTrackedBuff`、`SetHealerColor` Command；所有输入仍通过同一份 NormalizeSettings，MarkDirty 失败会恢复完整 settings snapshot。
- Healer V3 Page 新增高级编辑工作区：完整 Healing Rule 字段、Tracked Buff 增删改与颜色、范围/低血/紧急三组颜色通道；页面不直接修改 `Feature.State`，不创建第二套 persistence authority。
- NativeImports 的 optional ImportObject 失败（包括 ADDON/ImportObject 不可用）现在都会进入当前 Generation 的负缓存；required 请求仍忽略 optional cache；Generation 变化会清理 imported/cache/failure 状态并重新探测。
- FoundationGate 升至 v43，增加 Rule/Tracked Buff/Color Command Authority 门禁。
- 本地验证：Healer Advanced Command + Native Cache Harness `18/18`；Active TOC `162/162` 文件存在且解析通过；全项目 Lua `318/318` 解析通过。RU Fresh Reload 与新编辑器实机保存回读仍待验收。

## 2026-08-30 · M1.16.0.18.1 — V3 Page / Foundation Recovery
- RU 实机确认多个页面同时失败并非 Healer/DeathReview/Analytics/Tasks 各自 Domain 故障，而是公共 `RSUI:TableView()` 构造链的同一错误：`NormalizeColumn()` 把当前参数 `column` 误写成只在后续 Lua5.1 延迟回调循环存在的 `columnRef`。这会让 TableView 在返回前抛错，随后页面激活才以 `recommendationTable/history/tableView=nil` 形式二次暴露。修复为 `align=column.align`，延迟表头回调仍保留稳定 `columnRef`。当前 9 个 V3 页面 + 5 个 Floating Widget 共 14 个 TableView Consumer 同时受益。
- 修复 Generic WindowShell 构建事务泄漏：`BeginBuildScope("window_shell:...")` 成功路径此前从未 `EndBuildScope(..., true)`；主 Shell 提交因此会遇到 close-order 冲突并留下 `activeBuildScopes=2`。成功路径现在显式 Commit，Windowing Attach 失败改走统一 Rollback。
- 收紧 Strict Native Authority：TableView 列分隔 Handle 与 Shared Scrollbar 的运行期显隐统一改走 `UI:SetVisible()`，不再直接 `widget:Show()` 绕过 Diff cache；此前实机 `v3_authority_clean[viol=3]` 必须在新 Generation 完整 Reload 后重新确认，旧计数不作为新代码结论。
- Native Foundation 与 FoundationGate 契约重新对齐：NativeImports v2 增加 Optional Object negative-cache contract；NativeObjectFactory v3 对 `CreateChildByObject` 强制检查 ImportObject 结果并 fail-closed；NativeCapabilities 同步提升门禁。
- Windowing / WindowShell / FloatingSurface 补齐 same-value 幂等契约；WidgetHost v12 的 Feature lifecycle bind 改为事务式，订阅失败会回滚 binding；Events v4 显式暴露 RU 缺少 Native UnregisterEvent 时的 parked/skipped/owner-release 语义。
- RSUI v23 / API 10.8 补 WrappedText v2 sizing 公共契约、DataView callback-capture contract；V3 Shell 暴露导航 Lua5.1 capture contract。FoundationGate 升 v42，不通过降低门禁掩盖实现漂移。
- 本地封版验证：Active TOC 162/162 文件存在且 162/162 Lua 解析通过；全项目 Lua 318/318 解析通过；TableView Normalize、Native Optional negative cache、Factory Import Fence、Widget lifecycle bind rollback、Events release、WrappedText v2 专项 Harness 全 PASS；关键延迟 callback 捕获变量 `columnRef/routeRef/handleDefinition` 前置误用扫描 0。RU Fresh Reload 仍需重新验收 Foundation blocker、Authority violation 与所有 V3 路由。


## 2026-08-30 · M1.16.0.18 — Healer Head Marker / Raid Overlay Visual Consumers
- 新增 `features/combat/healer/rs_healer_screen_projection.lua`：Feature-side Native screen-position 窄桥，只负责 unitToken→screen x/y/z；Presentation 不直接访问 X2Unit，也不把屏幕位置提升成共享 Service/业务事实。
- 新增 `presentation/v3/widgets/rs_v3_healer_head_marker.lua`：独立 `presentation:healer_head_marker` Demand；Marker pool 在视觉任务外预分配，50ms P4 task 只做屏幕投影与 Diff。Recommendation 文本/设置缓存移出 hot path，visual tick 不创建 Widget、不深拷贝 Store。
- 新增 `presentation/v3/widgets/rs_v3_healer_raid_overlay.lua`：独立 `presentation:healer_raid_overlay` Demand；预分配 4×25 slot/rank/calibration。静态效果纯事件驱动无 Scheduler，动态效果只建一个 100ms P4 alpha task；通过 Recommendation committed Health/Status 生成全团 display projection，恢复范围底色/低血/追踪状态显示，但不复制旧 Native Health/Status scan。
- Head/Raid dormant controller 与 active realtime listener 分离 EventBus owner；Stop 先事务 Release Demand，失败时保持旧显示层完整运行。FeatureRuntime 已先 clear Demand 的 shutdown 路径按幂等收敛处理 token missing，避免假故障/资源泄漏。
- `v3.healer` 升 schema 3，新增 `presentation.head/raid` 与 4 个 Raid section rect；对 schema2 已完成 legacy settings import 的老用户增加一次只读 visual recovery，恢复旧 Marker/Overlay 参数并用 `visualImported` 防止后续重复覆盖。Feature enabled 仍不进入 Healer Store。
- V3 Healer Page 新增 Head/Raid 启停、Marker 数量/形状/文字、Raid rank/字号/校准/布局重置等核心入口，全部复用 Feature Commands/Persistent Binding 单写事务。
- FoundationGate v41 / Acceptance 增加严格 visual lifecycle：Head disabled 必须 0 consumer/task；Raid static effectMode=1 必须 0 animation task，动态模式才要求 task。Feature metadata=`migration_active_visuals_m16_18`；完整 Healing Rule/颜色/Tracked Buff 高级编辑器仍未迁，不标 fully migrated。
- 封版验证：Active TOC 162/162 路径存在且 162/162 Lua 解析通过；全项目 Lua 318/318 解析通过；`HEALER_RAID_PROJECTION_HARNESS`、`HEALER_RAID_SLOT_HARNESS`、`HEALER_VISUAL_LIFECYCLE_HARNESS`、`HEALER_HEAD_HOTPATH_HARNESS`、`HEALER_STORE_SCHEMA3_HARNESS` 全部 PASS；Professional Healer / old workspace Active 引用继续为 0。
- 本里程碑已合并 M1.16.0.17.1 Windowing Bootstrap Hotfix：`LayoutHandles()` 同步八向 Handle 布局使用当前 `definition.key`，不会在覆盖 0.18 文件后重新引入 `handleDefinition` 启动阻断。

## M1.16.0.17.1 — Windowing Bootstrap Hotfix (2026-08-30)

- 修复 `RSUI.Windowing:LayoutHandles()` 把当前循环变量 `definition` 误写为只在后续回调安装循环中存在的 `handleDefinition`，导致默认 V3 Presentation Host 在 `SetResizeEnabled()` 初始化阶段直接报 `attempt to index global 'handleDefinition'`。
- 该修复属于 RSUI Windowing 底层，不在 Shell/Healer 做绕过；所有使用统一八向 Resize Handle 的 V3 顶层窗口共同受益。
- 保留 Lua 5.1 延迟闭包保护：只有安装 Native 延迟拖拽回调的循环继续使用稳定局部 `handleDefinition = definition`；同步布局循环直接使用自己的 `definition`。
- 该 Hotfix 已并入 M1.16.0.18 最终工作树。

## 2026-08-30 · M1.16.0.17 — Healer V3 Presentation / Floating Recommendation
- 新增 `presentation/v3/pages/rs_v3_healer_page.lua`：正式接管 `combat.healer` 路由，只消费 Healer Feature Projection/Commands；提供实时推荐表、成员评分/状态明细、核心阈值/扫描周期/职责评分设置，以及 Feature/团队刷新/悬浮窗入口。状态详情读取已提交 Domain Cache，不因 UI 选中额外触发 Native Aura 扫描。
- 新增 `presentation/v3/widgets/rs_v3_healer_widget.lua`：统一接入 `WidgetHost + FloatingSurface` 的治疗推荐悬浮窗；显隐持有独立 `widget:combat_healer` Consumer，Feature 停用后按幂等语义收敛 Demand，窗口关闭不创建第二套 Runtime。
- `v3.healer` 升 schema 2，仅增加不透明 `widgetWindow` Presentation 持久化块；新增 `GetWidgetWindowState()` 窄接口，Widget 不再直接访问 `Feature.State`。Persistent Setting Binding 使用 Domain-only setter，避免一次用户设置产生重复 `MarkDirty`。
- 修复 schema 2 的 legacy 首次导入兼容：旧 `replicated_healer_recommender_v2` 导入现在重新经过 `NormalizeState()`，不会在重建 `F.State` 时丢掉 `widgetWindow`；专项验证同时确认旧 `trackedBuffs=nil` 仍保持空列表语义。
- Recommendation 新增 `GetMemberProjection()`：返回候选/不可用/Health/Status 的深拷贝明细，按 source/id 稳定排序；Presentation 不读取 Recommendation 私有缓存。
- 页面热路径收敛：推荐发布只刷新实时卡片/表格，不重复 Render 设置控件；设置控件仅在页面激活或 `v3.healer.settings` 变化时重绘。推荐表默认投影前 50 名，悬浮窗显示前 12 名，不改变 Domain 全量统计。
- Head Marker / Raid Overlay **仍未迁移**，继续作为下一阶段独立 Presentation Consumer，禁止恢复旧 `ui/rs_healer_workspace.lua` 或 `modules/professional/healer` Active TOC。Feature metadata=`migration_active_presentation_m16_17`。FoundationGate v40。
- 封版验证：Active TOC 159/159 路径存在、159/159 Lua 解析通过；全项目 315 个 Lua 解析通过；Presentation Store/Projection、Widget 生命周期、设置热路径、legacy schema2 迁移三组专项 harness 全通过；Active TOC 中 Professional Healer/旧 Workspace 为 0。
- BuildTag=`v3-m1.16.0.17-healer-presentation`。

## 2026-08-30 · M1.16.0.16 — Healer V3 Domain Runtime
- 新增 `rs_healer_store.lua / rs_healer_roster_v3.lua / rs_healer_recommendation_v3.lua / rs_healer_health_v3.lua / rs_healer_feature.lua`：`combat_healer` 进入 Active FeatureRuntime，但不恢复 `modules/professional/healer` TOC。
- Roster 只投影 TeamRosterV3；职责评分开启时才读 `X2Team:GetRole`，5 秒刷新、每片 8 人。Health Runtime 只注册一个 Suite Scheduler 50ms P1 任务，Health 每片最多 20、Status 每片最多 8；每个 roster generation 先完整 Status，再发布首次 Recommendation；定向紧急状态刷新保留 health snapshot 跨帧续作。
- Recommendation 原样迁移旧 health/distance/missing/unprotected 评分、rule effect、role score、enter/exit/minHold 滞回与稳定排序，Shared Aura Service 不拥有治疗结论。
- `HealerAuraBridge v2` 增加 `ReadAccurate()`：完整可靠共享 StatusMap 直接使用，否则有界 Native fallback；fallback 发现 Aura 行却无法解析 effect id 时 fail closed，避免“未知”变成“无 Buff”。
- 新 `v3.healer` schema 1 只保存永久治疗策略，不保存 Feature enabled；首次空 V3 Store 可只读导入旧 primary/backup。修复 legacy `trackedBuffs=nil` 被 Lua `and/or` 错误替换为新默认的问题：旧用户保持空列表，新 V3 默认才提供 25875/220。
- Feature Demand 资源按 TeamRoster→Aura→Events→Health 获取、逆序释放。故障注入验证 Aura 启动失败与 Aura 停止失败都能事务回滚，不留下半启动/半关闭状态。
- FoundationGate v39 与 Healer acceptance 增加 Domain/runtime/slice/dormant 契约。验证：Active TOC 157/157 路径存在、157/157 Lua 解析通过；Recommendation/Aura/Health/Feature/Store/Demand Rollback 六组 harness 全通过。
- Presentation 尚未迁移，Feature metadata 使用 `migration_active_domain_m16_16`，避免占位页误报“已完成”。BuildTag=`v3-m1.16.0.16-healer-domain-runtime`。

## 2026-08-30 · M1.16.0.15 — Healer Aura Phase 12B Bridge / Migration Preparation
- 新增 `features/combat/healer/rs_healer_aura_bridge.lua`：Feature-owned、零 Tick 的 Aura Consumer bridge，只负责 Healer Lease 与共享 StatusMap 读取；默认 dormant，不会因为 addon 启动就扫描 Buff。
- Legacy Healer `rh_status_cache.lua` 统一入口改为 `AuraObservationV3:GetSnapshot()+GetStatusMap()` 优先。只有共享覆盖不是 `available+complete+reliable` 才回退历史直接 X2Unit 扫描，准确率优先，不把未知缺口当作状态缺失。
- `ReplicatedHealerModule:EnableRuntime/DisableRuntime` 增加 Aura Lease 事务：启用后续失败会释放；禁用先释放 Aura，Release 失败不会继续伪装成功关闭。运行诊断增加 shared accepted/fallback/error 与 bridge health。
- `combat_healer` 元数据升级为 `migration_prepared_m16_15 / legacy_detached`。本轮明确**不**把 `modules/professional/healer` 重新加入 Active TOC，也不把未完成 Healer 标成 V3 implemented。
- 新增非破坏性 Healer Aura acceptance；FoundationGate v38 增加 bridge/dormant scope 门禁。验证：Active TOC 152/152 路径存在、152/152 Lua loadfile 编译通过；Bridge lifecycle/read Harness 与 StatusCache shared→direct fallback Harness 通过。
- BuildTag=`v3-m1.16.0.15-healer-aura-phase12b-bridge`。

## 2026-08-30 · M1.16.0.14 — Raid Readiness / Aura Phase 12B First Consumer

- `AuraObservationV3 v2` 新增无 Native 读取的 `GetStatusMap(snapshot, options)`：规范化 effect id、stack、timeLeft、name、iconPath 与 Buff/Debuff/Hidden source mask；多个 lane 的同一 effect 合并为单一事实。
- 新增保守 `EvaluateRequiredEffects()`：缺失 effect 只有在请求 lane 全部可用、完整、可靠时才判 `ok=false`；覆盖不完整时返回 `ok=nil`，团队检查显示“待确认”而非伪失败。
- 新增 `combat_raid_readiness` V3 Feature/Store/Authority/Page：页面 Demand 只持有 TeamRoster；手动检查按 50ms one-shot 分片读取职责/装分/距离，关键 Buff 规则存在时每片只处理 1 名成员并临时 Acquire Aura，在完成/取消/离页释放。无 Tick、无常驻 Aura 扫描。
- `TeamRosterV3 v4` 修复 canonical identity 一致性：同一玩家先以 `player/0/0` 种子出现、随后又从真实团队槽位命中时，不再让 lookup map 与 ordered snapshot 指向两张不同 row；改为保留稳定 `player` unit token 并在原 row 上补齐 team/member slot，供职责读取与后续团队 Consumer 复用。
- 新 Store `v3.raid_readiness` schema 1 只保存偏好；结果 Session-only。关键 Buff ID 完全由用户/后续核验数据提供，默认空，不猜 RU ID。
- NativeContract 加入 `TEAM={id=38,nativeName=X2Team}`，由 FeatureRuntime 通过 `ApiDependencies={"TEAM"}` 懒导入；新增非破坏性 Acceptance 与 FoundationGate v37 的 Aura/Raid Readiness 门禁。
- FeatureRegistry 将“团队战备检查”从 planned 升为 `migrated_m16_14 / on_demand_scan`。BuildTag=`v3-m1.16.0.14-raid-readiness-aura-phase12b`。

## 2026-08-30 · M1.16.0.13 — Foundation Lifecycle / Lua5.1 Callback Cleanup

- 扩大 Lua5.1 delayed-callback 审计：TableView 表头、Windowing 八向 Resize Handle、V3 主导航均显式捕获 per-iteration local，消除泛型 for 变量被 Native 延迟回调共享的隐患。
- Events v4 在 RU 缺少原生 Unregister API 时使用 parked registration；Lua listener/Feature consumer 仍正常释放，不再把“客户端没有注销能力”计为业务失败。
- FloatingSurface/WindowShell setter 统一 same-value 幂等成功语义，减少重复 Store dirty / layout / style write；Native/Logical content root 命名进一步分权；活动旧 `widgetRows` 运行时回灌清理。
- FoundationGate v36 新增 Lua5.1 deferred callback contract。BuildTag=`v3-m1.16.0.13-foundation-contract-lifecycle-cleanup`。

## 2026-08-29 · M1.16.0.12 — Floating Activity Interaction / Adaptive Viewport

- 修复 Activities/Tasks Floating Widget 的 Native X 关闭潜在死锁：局部 `ReleaseWidgetConsumer()` 误引用未定义 `self`，会在持久化 `widgetVisible=false` 前抛错并让生命周期桥重新拉起窗口；两处统一捕获具体 `instance`，Feature 已停用时按幂等释放处理。
- FloatingSurface v6 / WindowShell v14 引入 HUD compact chrome profile：悬浮窗默认标题栏 28px、标题字号 12、控制按钮 26px、body padding 6、footer 24px；普通 WindowShell 仍保留历史默认值，不创建第二 Window Authority。
- Activities Floating 不再调用 `GetWidgetRows(widgetRows)` 预截断 Projection，改把 Authority 的完整有界 `GetRows()` 交给 TableView。DataView Viewport Contract v1 明确由实际 Arrange 高度计算 `visibleCapacity`，所以竖向拖动窗口会自动增加/减少可见行并继续使用虚拟化池；旧 `widgetRows` 存档字段保留兼容，但设置 UI 不再把它当显示上限。
- 修复“从悬浮活动点击行没有详情”：ModalHost v4 新增 `EnsureApplicationVisible()`，Floating→Modal 路径会先唤醒/显示 V3 主 Shell，再 Push QuestDetail；即使活动没有核验 Quest/Instance detail，也会在可见宿主上明确 Toast，而不是在隐藏 Shell 中静默失败。GearQuickSettings 同步迁移同一 Modal wake contract。
- DataView 新增 `GetVisibleCapacity()` 公共查询；FoundationGate v35 新增 `v3_floating_interaction_contract` 并提升 WindowShell/FloatingSurface/ModalHost 版本门禁。BuildTag=`v3-m1.16.0.12-floating-activity-interaction-hardening`。

## 2026-08-29 · M1.16.0.11 — DPS Sort / Skill Detail / Combat Analytics UX Hardening

- 修复 Active V3 Dropdown 在 Lua 5.1 下的 option-loop closure bug：每个 option callback 显式捕获对应 Button/Index，避免所有选项最终引用循环末项；`DropdownContractVersion=2` 并纳入 FoundationGate。
- DPS 页面排序升级：主 metric 使用直接可见 `SegmentedSelector`；友/敌排行表头开启交互，伤害/承伤/治疗列切换唯一 Feature metric，名称/DPS 走当前有界 Projection 的本地排序；TableView 第三态 `none` 解释为前一列 ascending，形成 `desc ↔ asc` 两态；摘要显示真实 `显示 n/total`。
- DPS Domain v6 保留经过 CombatFact 语义验证的 skill id：`spell_damage/heal` 可记录 raw skill id；`melee_damage` 的 raw `abilityId` 在 RU 事件中是 damage amount，因此故意显示“—”，禁止制造假技能 ID。玩家技能明细新增 Icon、技能 ID、数值、占比、次数。
- 新增 `SkillMetadataV3 v1`：共享、懒解析、有界 512 缓存，仅在 UI Drilldown 路径调用 `X2Skill:Info/GetSkillTooltip`；正/负结果都缓存，Combat Domain/Bus 热路径零 Native skill lookup。
- `CombatAnalyticsV3 v3` 新增有界 `GetMetricActorDetail()` Projection API；Feature 增加同名 Commands/Projection 边界。Analytics 页面改为玩家可理解的战斗行为工作区：说明每个分析项用途、ActionRunner 明确反馈、中文采集覆盖、空态原因、玩家 A/B 对比及技能/击杀/控制/演奏/辅助/Aura/机制 Drilldown。Presentation 不读取 Metric private state。
- FoundationGate v34 门禁 SkillMetadata v1、Analytics v3 Actor Drilldown、DPS Domain v6、Dropdown v2；RSUI v22。BuildTag=`v3-m1.16.0.11-dps-detail-analytics-ux-hardening`。

## 2026-08-29 · M1.16.0.10 — Floating Shell Layout Ownership / Local Appearance

- 修复 DPS 悬浮窗“首次显示标题消失、内容顶到窗口最上方，拖动一次后标题才恢复”的底层根因：WindowShell 的 `root` 是特殊 Chrome compositor，但后创建的业务子组件会触发 RSUI 通用 invalidation queue；通用 Overlay reflow 随后把 `bodyFrame` stretch 到整个 root（y=0），覆盖 titleBar，而拖动恰好再次执行 WindowShell 专用 `Layout()` 才恢复。WindowShell v13 现在将 root 标记 `autoRelayout=false`，并通过 `layoutHost` 把后代 Measure/Layout invalidation 合并回 Shell 专用 title/body/footer compositor；50ms one-shot 只在内容变化时合并重排，无 Tick。
- FloatingSurface v5 新增标准 `fontScale` 状态通道与 StateAdapter；WindowShell/RSUI 增加局部字体倍率传播。局部倍率继承到后续虚拟化子组件，Theme/TextLayout/Native Render 共用同一物理字号计算，防止全局 Typography Refresh 把悬浮窗局部字号覆盖回去。
- DPS 悬浮窗快捷栏新增紧凑“外观”入口，默认折叠以保持 HUD 清爽；展开后提供精确数值输入：背景透明度 `0–100%`、字体 `80–125%`。两项复用现有 `v3.dps.widgetWindow` 持久化状态，不新增 Store Schema/第二 Authority。
- WidgetHost v11 将 `fontScale` 纳入标准 appearance capability；RSUI v21/api 10.7 新增 `FloatingFontScaleContract v1`；FoundationGate v33 新增 `v3_floating_shell_appearance_contract`，并把 Floating Text Layout 门禁提升到 WindowShell>=13 / FloatingSurface>=5。BuildTag=`v3-m1.16.0.10-floating-shell-layout-appearance`。

## 2026-08-29 · M1.16.0.9 — DPS Floating Quick Filters / SegmentedSelector

- 新增 `RSUI:SegmentedSelector()`（Contract v1）：有界 one-of-many 紧凑选择器，复用 HorizontalBox + Button active state + Persistent Setting Binding；重复点击当前项为幂等成功，不重复写 Store；无 Tick/OnUpdate。
- DPS 悬浮窗新增一行紧凑快捷筛选：`PVE/PVP`、`友方/敌方`、`伤害/承伤/治疗`。三组控件直接绑定 DPS Feature 的唯一 settings Authority，因此与完整 DPS 页面双向同步、持久化一致，不创建 widget-only shadow state，也不会影响后台对所有 PVE/PVP/关系桶的持续累计。
- 悬浮摘要去除与快捷筛选重复的模式文字，改为总伤/承伤/治疗/单位数；Replay/未决技术信息默认折叠，仅存在可能影响排行的待确认数据时显示警告，释放正常战斗 HUD 的垂直空间。
- RSUI 升 v20/api 10.6；FoundationGate 升 v32，新增 `v3_compact_selector_contract`；DPS acceptance 增加 quick-filter framework 契约。BuildTag=`v3-m1.16.0.9-dps-floating-quick-filters`。

## 2026-08-29 — M1.16.0.8 Floating Content / Wrapped Text Hardening

- 修复 DPS 悬浮窗摘要文字重叠的两个底层根因：`FloatingSurface:GetContentRoot()` 过去返回 `WindowShell.body.root` Native 对象，导致业务创建的 `VerticalBox` 虽然物理挂到窗口里，却没有进入 RSUI `parentComponent/children` 逻辑树，因而 Shell Measure/Arrange 无法给它正确内容宽度；`FloatingSurface v4` 现在优先返回 WindowShell v12 的逻辑 `GetContentComponent()`，原生访问保留为显式 `GetNativeContentRoot()`。
- 修复 `Text overflow=wrap` 把 `TextLayout:Wrap()` 产生的换行字符串直接写入 ArcheAge `LABEL` 的错误假设。当前 RU API 的 LABEL 没有可靠多行/行距契约；RSUI v19 的 WrappedText Contract v1 改用 `EMPTY_WIDGET + 有界单行 LABEL 池` 渲染，每个 Native LABEL 永远只收到一行文本，默认最多 6 行、硬上限 8 行，无 Tick/OnUpdate。
- `ApplyOpacityChannels` 增加组件级 `ApplyTextOpacity` hook，使复合 WrappedText 的每条子 Label 继承文本透明度；字体缩放仍由 Theme/TextLayout 的统一物理字号契约驱动。
- 继续审计所有 Active `TextLayout:Wrap` 消费点后发现 Tooltip fallback 也把换行结果写入单个 LABEL；TooltipService v3 已改为复用同一个 WrappedText Composite，Active UI 中只剩 WrappedText 自身调用 `TextLayout:Wrap`。
- DPS 悬浮窗摘要/详情与 DeathReview 悬浮摘要从固定高度改为 `auto + minHeight`，在字体/内容换行时允许真实 DesiredHeight 增长；Table 继续使用 Fill 吃剩余空间。
- FoundationGate 升 v31，WindowShell 门禁>=12、FloatingSurface>=4，并新增 `v3_floating_text_layout_contract`（WrappedText/Shell/Floating/Tooltip 四方契约）。BuildTag=`v3-m1.16.0.8-floating-content-wrapped-text-hardening`。
- 本地验证：Active TOC 144/144 `texluac -p`；WrappedText Harness 验证 120px 宽长摘要被拆成 4 个单行 LABEL，任一 Native `SetText` 都不含 `\n`；静态确认 4 个 V3 Floating Widget 继续只经 `surface:GetContentRoot()` 进入统一逻辑内容树。

## 2026-08-29 — M1.16.0.7 RSUI Public API / Navigation / Form Layout Hardening

- 修复 DPS 实机 `rs_v3_dps_page.lua:247: attempt to call method 'TextInput' (a nil value)`：`TextInput` 类型已在 `rs_ui_controls.lua` 注册，但 Component Core 的手写公共工厂列表遗漏了该类型。RSUI v18 改为 `RegisterType/ReplaceType` 注册时自动安装 `RSUI:<Type>()` 公共工厂，后续新增类型不再依赖人工同步第二份名单；FoundationGate v30 新增 `v3_rsui_public_factory_contract`，逐项检查已注册类型的公开创建入口。
- 修复重复点击当前已选导航项被误报 `widget switcher rejected target page`：`WidgetSwitcher:SetActiveWidget()` 将“目标已激活”定义为幂等成功，`PageHost:Navigate()` 对 same-route/same-page 提前成功返回，不再停用/重启 Feature consumer，也不再产生 `V3_PAGE_SWITCH_FAILED/PAGE_NAVIGATION_FAILED`。
- 修复 NumericField 共用布局在 UI/字体缩放后底部提示文字被裁切：Theme 增加统一物理字号解析；TextLayout v3 按真实 Native 字号测量宽度/行高；Text Primitive 不再在 Render 阶段把字体回写为未缩放 base size。Form Layout Contract v2 用真实 label/feedback/hint 行高计算 DesiredHeight，Numeric/Toggle/DropdownField 与 FieldGroup 统一 Measure→Arrange。
- `UIV3Design v5 NumericSetting` 将历史固定 62px slot 自动迁为 `auto + minHeight`（除非显式 `allowFixedHeight=true`）；系统设置、悬浮组件设置、DPS、死亡回顾与换装快捷设置的外层固定高度同步改为可增长。Border Measure 补齐 min/max 宽高约束。字体或界面缩放变化只触发一次弱引用 typography component Measure invalidation，无常驻 Tick。
- FoundationGate v30 新增 `v3_typography_form_layout_contract`，同时门禁 Theme font resolver、TextLayout v3、Form Contract v2、WidgetSwitcher Contract v2 与 Design v5。BuildTag=`v3-m1.16.0.7-rsui-api-nav-form-layout-hardening`。
- 本地验证：Active TOC 144/144 `loadfile`；Active RSUI `RegisterType/ReplaceType` 49 个、冒号调用 557 处，静态解析无未定义公共入口；Public Factory、WidgetSwitcher 幂等、NumericField Form Layout Harness 均通过。表单 Harness 在 106%/110% 下 DesiredHeight=74px、125%/150% 下=93px，均大于历史 62px 固定容器并完整容纳 hint。


## 2026-08-29 — M1.16.0.6 UI Adapter / Selection Contract Repair

- 修复 M1.16.0.5 实机仍无法打开 DPS/战斗分析的真实原因：Active `rs_ui_native_primitives.lua` 没有 Legacy `TrySetUILayer`，而新版 Dropdown 在 popup 创建成功后直接调用该缺失方法。`TrySetUILayer` 已正式进入 Active Native Primitive Adapter，并在 Dropdown 侧再做 capability guard；RU Widget 不支持 `SetUILayer` 时仅跳过层级调用，不允许页面事务失败。
- DataView Selection Contract 升 v2：ListView / TileView / TableView 统一回调参数；新增 `View:GetSelectedKey()`；TableView 对外返回自身 View 而不是内部 ListView。ListView 程序化选择在同步通知前发布本地 index，修复虚拟池未绑定时的旧 index 观察。
- 修复死亡回顾 `GetPrimaryKey` nil：页面曾把 SelectionChanged 第 3 参数 View 误当 SelectionModel。死亡回顾、换装、副本、活动、任务全部改为只消费 `View:GetSelectedKey()`，消除 Presentation 对 SelectionModel 参数位置的耦合。
- 诊断“运行完整自检”只要成功返回报告即视为动作成功；报告中的 blocker/warning 通过结果 Toast 表示，不再生成误导性的 `ACTION_FAILED`。FoundationGate v29 新增 `v3_ui_adapter_selection_contract`。
- 验证：Active TOC 144/144 `loadfile`；Active UI 调用面静态审计仅剩两个非 S.UI 别名误报，无缺失 S.UI method；TrySetUILayer harness、List/Tile Selection View Contract harness、TableView Public View harness 均通过。BuildTag=`v3-m1.16.0.6-ui-adapter-selection-contract-repair`。


## 2026-08-29 — M1.16.0.5 Root Parent / Diagnostics Recovery
- 修复 M1.16.0.4 RU 实机中 `combat.analytics` / `combat.stats` 仍因 Dropdown popup 创建失败而打不开：根因是 NativeObjectFactory 只把 `nil` 归一成 `"UIParent"`，却会把 `UIParent` userdata/object 原样再次传给 `UIParent:CreateWidget()`；该 RU Build 的 root constructor 可靠接受的是字面量 root token。现在 factory 统一归一 `nil / UIParent object / "UIParent"`。
- Panel / EmptyWidget / Label / Button 顶层 Primitive 统一 root-parent 路径与提交后 fail-open；配置阶段异常标记 `rsUiDegraded` 并进入结构化 Diagnostics，避免 Native 已提交后上层收到 nil、再次构建撞 Physical ID。
- Dropdown 增加功能降级：popup、滚动按钮或 option pool 无法创建时，保留 trigger 并降级成 `↻` 单按钮循环选择；仍可读写 Binding/触发 onChanged，无常驻 Tick。
- PageHost 增加 route/deactivate/switch/activate 四类结构化错误；`UIX:SafeHandler` 的 Native 回调异常也写入 Diagnostics。FoundationGate v28 的复制摘要新增页面失败/隔离/Native失败/事务回滚统计，并附最近 4 条 warning/error 的 code 与关键错误上下文。
- 修复诊断页“运行完整自检”看起来无反应：ActionRunner 改为显式 Toast 成功/失败；Refresh 可直接消费本次 gate report，避免一次点击执行两次 FoundationGate。
- 本地验证：Active TOC 144/144 `loadfile`；root-parent normalization、Dropdown fail-open、诊断摘要 3 个 harness 全通过。BuildTag=`v3-m1.16.0.5-root-parent-diagnostics-recovery`。


## 2026-08-29 — M1.16.0.4 Native Build Transaction Hardening
- RSUI v17 新增同步 BuildScope 事务；失败时逆序 Release/Detach Component 并隐藏本次已提交 Native Widget，不尝试未验证的 DestroyWidget。
- PageHost v3 / WidgetHost v10 / WindowShell v11 / ModalHost v3 / Main Shell / NativeAdapter v3 增加 Generation quarantine，保留第一次真实错误并阻止同 Generation 重建同一 Native identity。
- PageHost 改按 Component identity 切换；Activities/Tasks/Gear/Instance/System 页面补 PageRoot fail-fast。
- Native Primitive 初始化失败改为 degraded 隔离；UI Write Fence 拒绝 degraded widget 后续写入。FoundationGate v27 新增构建事务门禁。
- Active TOC 144/144 `loadfile` 语法通过。BuildTag=`v3-m1.16.0.4-native-build-transaction-hardening`。


> **Authority Level**: CURRENT / GENERATED
> 倒序记录。里程碑级结论以 [`CURRENT_REBUILD_STATUS.md`](CURRENT_REBUILD_STATUS.md) 为准；详细审计见 `Archive/`。

## 2026-08-29 — M1.16.0.3 Native Dropdown / Combat Page Recovery

- 修复 `combat.analytics` 实机 `metric=nil` 与 `combat.stats` 后续 `root=nil`：Active V3 TOC 从未加载 Legacy `ui/components/rs_dropdown.lua`，但 `RSUI:Dropdown()` 仍依赖 `S.Dropdown:Create()`。标准 Dropdown 已改为直接复用 `NativeObjectFactory + UI Diff Authority`，不再需要 `S.Dropdown/CreateEmptyWindow`。
- Dropdown popup 继续物理 parent 到 `UIParent` 防止 ScrollBox/Card 裁剪；`UI:CreatePanel()` 增加可选 logical owner，在 Register 前写入 V3 owner，使 popup 与 option buttons 进入严格 V3 ID/Lifecycle Authority。列表行固定池上限 16；刷新保留 top anchor；滚轮/上下按钮按事件驱动；关闭/切页不留常驻 Tick。
- 新增 `RSUI.DropdownService` 弱引用管理：打开一个 Dropdown 会关闭其他 popup；PageHost 成功路由准备、Shell 关闭或最小化时统一关闭 transient Dropdown，避免 UIParent popup 脱离旧页面或主窗口继续显示。
- 修复严格 V3 logical ID 冲突：DPS/DeathReview 页面动作按钮改为 `v3_dps_widget_toggle` / `v3_death_review_widget_toggle`，FloatingSurface 根继续保持 `v3_dps_widget` / `v3_death_review_widget`。Active TOC literal V3 ID 静态扫描未再发现页面/悬浮窗重复。
- DPS、Combat Analytics、DeathReview 的 PageRoot/关键 Dropdown 增加 fail-fast 错误，底层控件失败时直接报告具体组件，不再继续执行到 `attempt to index ... nil` 的二次错误。Analytics 同步改用标准 `SetSelectedValue()`，删除对旧 `.dropdown` adapter 的探测。
- FoundationGate 升 v26：`combat_relation_contract` 从不存在的 `ResolveName` 检查纠正为 `CombatRelationV3 v4` 实际公开契约 `GetRelationAt(name, at)`；idle `consumer=0/units=0/rosterHeld=false` 不再被错误标成 Blocker。
- 验证：Active TOC 144/144 Lua `loadfile` 通过；Active 文件 0 个 `S.Dropdown/CreateEmptyWindow` 引用；Dropdown 纯 Lua Harness 覆盖创建、选择、滚动、Render、禁用、Release 全通过。BuildTag=`v3-m1.16.0.3-native-dropdown-combat-page-recovery`。

## 2026-08-29 — M1.16.0.2 Combat Page Activation / Navigation Repair

- 修复“伤害统计 / 战斗分析导航按钮点击无可见反馈”的页面激活链。`UIV3Design v4` 的 `PageRoot/ScrollablePageRoot` 现在同时接受字符串 id 与 spec table，战斗分析页的 `{id,padding,gap}` 组合不再绕过共享 Design Root 契约。
- DPS 页对 RU 可选 `X2_EDITBOX/EDITBOX` 改为 fail-open：首领名称输入框创建失败只禁用手动首领名称输入并显示降级提示，不再让整个 `combat.stats` Page Factory 异常退出。
- Shell 导航失败新增 Diagnostics `PAGE_NAVIGATION_FAILED` + 用户点击 Toast/状态栏反馈；页面创建/OnActivated 回滚不再表现为“按钮完全没反应”。
- 修复 `rs_v3_acceptance` 仍要求 `combat_stats=migrated_m15_3 / authority=v3.dps` 的过期契约，更新为 M1.16 shared Analytics authority。FoundationGate 升 v25，并增加 `v3_combat_navigation_contract`；新增 `v3_36_combat_page_navigation_contract` Sequence 真正打开 DPS/Analytics 页面再恢复。
- BuildTag=`v3-m1.16.0.2-combat-page-activation-repair`。

## 2026-08-29 — M1.16.0.1 Combat Analytics Lifecycle Hardening

- `CombatAnalyticsV3` 升 v2：空 Metric Consumer 不再允许占用 Demand；`AcquireConsumer({metrics={}})` 明确拒绝，`UpdateConsumer({metrics={}})` 对已持有 token 执行事务式 Release。公开指标全部关闭后，Combat Analytics Feature 因此真正释放自身 all-scope Lease；若 DPS 的隐藏 `dps_core` 仍启用，只保留 DPS 自己的独立 token。
- 新增公共 `HasConsumer` / `ResetMetrics` / `NotifyMetricChanged` 契约；Feature `ClearAll` 不再调用 Service 私有 `_SchedulePublish`，也不会通过全量 Reset 误清隐藏 `dps_core`。
- Metric Reset 纳入失败传播：Disable/Quiesce/批量清空遇到 `Reset=false/异常` 不再假成功；Demand reconcile 可据此回滚。FoundationGate 升 v24，并把 `emptyConsumers==0` 纳入 Analytics runtime health。
- 回归：纯 Lua Runtime Harness 验证空 Acquire 拒绝、non-empty→empty 释放 Bus、公开批量清空不触碰隐藏 Metric、Reset 失败向上传播。BuildTag=`v3-m1.16.0.1-combat-analytics-lifecycle-hardening`。

## 2026-08-29 — M1.16.0 Combat Analytics Foundation

- 新增 `CombatAnalyticsV3 v1` + Metric Registry：高级分析只持有一个 `CombatEventBusV3 v6 scope=all` Consumer，并按预编译 fact/native plan 分发；DPS 通过隐藏 `dps_core` Adapter 复用该入口，DeathReview 仍独立 self-scope。
- 新增 9 个可独立启停、有界 Session Metric：Encounter/History/Timeline、Kills/Assists/Deaths、Casts/Opener、Performance、Control、Songcraft、Utility、Aura、Boss Mechanics；新增 `CombatAbilityCatalog` 与 `CombatMechanicCatalog` O(1) 热路径索引。
- `Core Events v3` 增加 Optional Native Event 事务；Optional 注册失败只记录 degraded health，Required 失败仍不提交 listener；Required/Optional topic 属性由当前 listener 集合重算。
- 正确性收口：8 秒 Encounter gap 由事件+one-shot 双保险；START 无 STOP 时不计算伪演奏时长；inferred/native 同一施法起手合并证据；控制/Aura open interval 实时 Projection；Boss 机制优先记受影响目标；Utility UI 明确为“技能活动”而非未经证实的成功打断/驱散。
- 性能：MetricCommon v2 使用显式 `head/tail/count` 有界队列；高频队列禁止 `table.remove(1)`；5 秒爆发采用 100ms 时间桶并在 200-hit 压力下完整保留伤害；History 仅 20 场紧凑摘要。
- 验证：Active TOC 144/144 文件存在、144/144 Lua `loadfile` 通过；MetricCommon、Catalog、Metrics、Analytics single-consumer runtime、Events Optional transaction 与 M1.16 final-edge Harness 全通过。BuildTag=`v3-m1.16.0-combat-analytics-foundation`。

## 2026-08-29 — M1.15.7 Foundation Event / Scheduler Contract Hardening
- 完成 M1.15.6 后的底层专项审计，不扩展 DPS 业务。`Scheduler v3` 新增 transient task-module ownership；`RefreshCoordinator` 的递增 one-shot 名称显式标记为 transient，RemoveTask/RemoveOwner/Stop 会回收动态 `taskModules`，修复长时间运行下无界字符串元数据增长。静态 Module→Task 映射继续保留，兼容旧模块停启。
- `Events v2` 把 Native `RegisterEvent` 纳入 Subscribe/Start 事务：运行中注册失败时不提交 listener；启动阶段任一预注册失败会回滚已注册事件和 Handler，不再返回“订阅成功但客户端从未投事件”的假状态。新增 register/unregister/start/subscribe failure 健康指标并进入 FoundationGate。
- `CombatEventBusV3 v5` 的 borrowed+immutable Fence 从“主要语义字段”扩展到全部公开标量字段（raw payload 与 death notice 同步保护），避免前序 Consumer 篡改 `rawAbilityId/rawMore*/subjectName/rawNotice*` 污染后序 Consumer。`GetHealth().scope` 同时识别 Demand projection 的 `consumerOptions`，诊断不再把真实 all-scope 错报成 self。`ENTERED_WORLD` 订阅失败时 CombatBus 启动事务回滚。
- `TeamRosterV3 v3`、`CombatRelationV3 v4`、DPS relation replay subscription、QuestProgress/Activities/Tasks/Instance Browser 等 Active V3 链路全部检查 Event/Internal subscription 返回值；启动失败即回滚已持有 Lease/事件/任务，不再留下 `subscribed=true` 假状态。Gear Quick Widget 的两个 Native 装备事件也改为事务订阅。
- Runtime Foundation 三个周期任务安装改为事务式：Layout/Persistence/Observation 任一注册失败都会移除本轮已安装任务并让 Runtime 启动失败，避免“只启动了一半 Foundation”仍进入 Ready。FoundationGate 升 v22，增加 Scheduler 动态元数据、Core EventBus、TeamRoster/CombatRelation 契约与运行健康检查。
- 本地 Foundation Harness：5000 次动态 Scheduler/RefreshCoordinator one-shot 后 transient/module mapping 不增长；模拟 Native RegisterEvent 失败可验证 Start/Subscribe 回滚；模拟恶意 Combat Consumer 修改 raw/death 字段后后序 Consumer 仍收到原始事实。Active TOC 135/135 文件存在且 Lua 语法通过。BuildTag=`v3-m1.15.7-foundation-event-contract-hardening`。

## 2026-08-29 — M1.15.6 DPS Evidence / Replay / Observability Hardening
- 收紧 damage 阵营反推：只有 SELF/TEAM 可信锚能推导另一端为 OPPONENT；FRIENDLY/OPPONENT 不再递归给第三方 UNKNOWN 贴阵营，修复“敌方攻击中立 NPC → 中立 NPC 被写成友方承伤”的污染。heal 仍按同阵营事实推导。
- `CombatRelationV3 v3` 在 `RecordCombatFact` 应用证据后返回 `relationChanged`；DPS 将其并入 160ms Scheduler Replay 请求。旧待确认事实因此可在后续首击/关系证据建立时重新归类，而不是一直卡在 UNKNOWN。Manual Apply/Clear 的实际变化继续发布 relation updated。
- DPS Domain 升 v5：provisional/side-unknown contribution 可先显示数值，但最终归类前不提交 actor active clock。修复 PVE provisional 后搬到 PVP 时旧 PVE 活动时间无法回滚、长期把 DPS 压低的问题。detail 回滚同时删除零值 row 并归还 skill/counterpart capacity，避免反复 Replay 后虚假触发 128/256 上限。
- `CombatEventBusV3 v4` 把 UI/UIParent 跨 Host 去重从单槽改为每 Host FIFO token 1:1 配对：同 Host 连续相同多段攻击全部保留，两个 Host 的镜像按 multiplicity 精确抵消。token 使用 50ms TTL、256 上限与 backing-order 压缩；新增 pending/evicted 健康指标。Global SELF 过滤/private SELF slice 契约不变。
- `TeamRosterV3 v2` 增加冷启动韧性：瞬时 `UnitName("player")` 失败不再把上一份有效团队快照清空；最多 3 次约 450ms one-shot 重试，成功后取消。仍无 Tick、无 CombatFact 热路径团队扫描。
- DPS 页面新增“查看待确认”：可检查模式未定/阵营未定 actor、当前指标值和事件数；页面/悬浮状态同时暴露 Replay 淘汰、Bus 跨 Host pending/evicted、Relation 与 TeamRoster 健康指标，区分“真正漏事实”和“事实已保留但证据未决”。
- 手动 Boss 名 ASCII 匹配改为大小写不敏感；Store schema 3 不变，不制造无必要迁移。
- 新增/扩展回归：第三方 OPPONENT→neutral 不得制造友方、relationChanged Replay、provisional activity clock、detail Replay capacity、UI/UIParent 1:1 multiplicity/5000 对压缩、TeamRoster 快照保留/恢复。BuildTag=`v3-m1.15.6-dps-evidence-replay-hardening`。

## 2026-08-29 — M1.15.5 DPS Correctness / Replay / Detail Hardening
- 修复 DPS Domain 持有 borrowed CombatFact 的所有权违规：待重放账本只复制分类/显示所需标量字段，不保存共享事实对象；Replay Ledger 改为 active-count 上限 + stale-prefix 压缩，520 条未决压力下 active/slots 均保持 512 上限，溢出只计 `pendingEvicted`。
- 修复首击分类的 Lua 语义 Bug：旧 `sourceFriendly and targetKind or sourceKind` 在 `targetKind=nil` 时会回退到 `sourceKind=PLAYER`，导致 SELF/TEAM 攻击未知 Kind NPC 首击误进 PVP。改为显式 endpoint 分支；首击 provisional PVE 可立即显示，并在 NPC/PLAYER 证据到达后 Replay。
- 治疗从 PVE/PVP backing bucket 解耦为单一 Shared Heal Ledger。每笔 heal 只累计一次，但 PVE/PVP Projection 都能合并查看；切到 PVP 不再“治疗消失”，也不会因为双桶写入而双算。
- 新增有界 actor 明细：技能最多 128、目标/来源最多 256；明细 refs 绑定同一 contribution，重分类时和总榜一起回滚/搬迁。DPS 页面新增伤害/承伤/治疗排序，双排行点击单位展示技能与目标/来源明细；1024×768 下主工作区改为左右双排行 + 下方弹性明细，避免三块纵向等分后每表只剩一两行；悬浮窗沿用同一 Projection。
- `v3.dps` Store 升 schema 3，持久化 `metric` 并继续保留 FloatingSurface `widgetWindow`。修复设置 setter 只改内存不 MarkDirty 的路径：RSUI Persistent Binding 使用 Domain-only `ApplySettingFromBinding`，Command/API 使用 `SetSettingValue` 自己排队持久化并在失败时回滚。
- RSUI 新增共享 `TextInput`（EditBox + committed Binding + Draft→Submit + Enter/Blur/按钮提交/校验），DPS 恢复 Boss 名称输入添加；显示行数继续使用修复后的 NumericField 独立行，不与 Slider 命中区重叠。
- 统计生命周期与 Enabled 解耦：Disable/Quiesce 释放 Consumer/Relation/TeamRoster 与 Replay/Segment 临时态，但保留当前 Session 统计；显式 Clear 才清零。
- `CombatRelationV3` 的 bounded order 增加 stale-prefix 压缩，长期大型战斗不再仅移动 head 而无限累积数组槽。DPS actor key 同步遵循 UnitIdentity 跨服契约：两个明确不同 `Name@World` 不合并，宁可暂时保留短名歧义也不错误合并跨服玩家。
- Acceptance 增加 borrowed fact、512 Replay、首击 NPC、shared heal、metric projection、detail、Disable 保留统计、跨服同名不碰撞等回归。RU 实机仍需确认 all-scope Coverage、真实 Kind 命中率、团队 token 与物理 UI 布局。
- BuildTag 更新为 `v3-m1.15.5-dps-correctness-hardening`，使诊断页/实机日志能明确区分本轮封包与 M1.15.3/1.15.4。

## 2026-08-29 — M1.15.4 DPS Data / UI / Lifecycle Repair
- 修复 M1.15.3 首轮实机暴露的结构性漏数：DPS Domain 不再用“来源是否等于 actor”推导承伤，而是对每条事实分别写入 `source.damage`、`target.taken`、`source.heal`；PVP/PVE、友方/敌方分桶均以事件两端独立贡献累计。
- 新增有界 `unclassified` 保留桶 + 512 条 Replay Ledger：关系/Kind 暂未决时数据先保留而不是静默丢弃；关系或显式 Unit Kind 更新后由 Scheduler 安全点 `ReplayPending` 重分类/搬桶。超出 Ledger 上限只失去最旧事实的“未来重分类能力”，已累计数值不删除，并计 `pendingEvicted`。
- `CombatRelationV3 v2` 修复“建立敌对证据的首击仍返回旧 UNKNOWN 快照”；Unit Kind 与 Relation Authority 分离，NPC/MATE/SLAVE Kind 不再自动制造 OPPONENT；新增按需 `TeamRosterV3` 共享事实服务，使用 `X2Unit:UnitName` 在团队变更后 Scheduler 安全点扫描团队 token，无 Tick、无战斗回调扫描。
- `CombatEventBusV3` 在已验证 raw id→端点绑定后通过 `UnitIdentityV3` 缓存附加 `sourceKind/targetKind`；borrowed+immutable 恢复边界同步覆盖这两个字段，DPS 不再重复做 `GetUnitInfoById`。
- 修复 DPS Feature 调度错误：原代码调用不存在的 `Scheduler:ScheduleOnce`，实际会退化为每条 CombatFact 直接发布 UI 更新；改为真实 `Scheduler:AddOneShot` 400ms 合并 Projection 发布，证据重放使用 160ms one-shot。功能停用/Quiesce 同时释放 CombatRelation/TeamRoster 下游租约与运行统计缓存。
- 修复 `rs_dps_store.lua`：schema 升 2 并保留 `widgetWindow`，解决 FloatingSurface 因 Store Normalize 丢字段而无法打开；新安装悬浮视图默认 `friendly`，旧配置中的合法 `enemy/friendly` 原样迁移；Boss 名去重，删除事务失败可正确恢复旧列表，并消除 `RemoveBossName` 同名覆盖导致的递归。
- DPS 主页面改为同时展示“友方/自己”和“敌方/目标”两张完整排行，列包含伤害/DPS/承伤/治疗；`side` 设置明确只控制悬浮窗，避免用户输出因默认看敌方而表现为“没有数据”。新增覆盖、未归类保留、待重放/重分类状态。启停/悬浮窗/清空/首领删除统一 ActionRunner 反馈。
- DPS 悬浮窗扩大默认/最小尺寸，补齐伤害/DPS/承伤/治疗列，Show/Hide 改为事务式状态同步，并接入共享 `WidgetHost:BindFeatureLifecycle`；修复“逻辑 visible=true 但原生 Show 失败”的漂移。
- RSUI `NumericField` 收紧窄宽布局并把 hint 放到 control 下方；DPS“显示行数”不再塞入 38px 高行，修复 Slider 覆盖字体。
- 验证：修改 Lua 文件使用 LuaTeX `loadfile` 语法校验通过；DPS Domain 独立 Harness 覆盖 PVE 输出、PVP 双向伤害、incoming taken、治疗同侧推导、UNKNOWN 保留，全部通过。仍需 RU 实机确认 all-scope Coverage、TEAM token 布局与真实 CombatFact Kind 命中率。

## 2026-08-29 — M1.15.3 DPS V3 Migration
- `combat_stats`（伤害统计）正式迁入 FeatureRuntime，成为首个 `CombatEventBus scope=all` 业务 Consumer；只订阅 `scope=all`，不注册 `COMBAT_MSG`，不拥有原生战斗 Handler。
- 新增独立 `CombatRelationV3`（Relation / Combat Classification Domain）：只回答「单元是 SELF/TEAM/FRIENDLY/OPPONENT/UNKNOWN」，支持 MANUAL 最高优先、KIND_NPC/KIND_PLAYER 显式类型、Chinese-name 低置信提示（默认关闭）；不拥有身份/Aura/战斗事实/DPS 业务结论。
- `rs_dps_domain.lua`（纯业务 Domain）：PVP/PVE 按「事件来源 × 目标」逐事件分类（同一玩家可同时进 PVE 与 PVP 两张表）；环境伤害恒为 PVE；治疗只按关系决定 PVE/PVP 存储桶，绝不因上下文未决而丢弃/拆分/延迟；手动 Boss 标记可把无名目标判 PVE，但确认 PLAYER 证据仍优先；排行榜人数上限只截断 Projection，累积永不受限；Clear 只清统计，不停 Consumer。
- `rs_dps_store.lua`：`S.Persistence:RegisterV3Store` 只持久化设置与手动 Boss 名集合（Account / Permanent），不持久化运行总量；业务侧一律走 `S.Persistence`，不得直接 `LoadData/SaveData/ClearData`。
- `rs_v3_dps_widget.lua` / `rs_v3_dps_page.lua`：复用 FloatingSurface + WidgetHost + PageHost + ViewState/ActionRunner/Persistent Binding，沿用 DeathReview 的「Feature 生命周期桥」模式；覆盖不全时 `surface:SetStatus("覆盖不完整", "warn")`。RSUI 无 TextInput，Boss 名列表为只读 + 移除按钮。
- 战斗热路径零 Tick/OnUpdate：事实回调只做轻量 `OnCombatFact` + 节流 Projection 发布（400ms `Scheduler:ScheduleOnce`），无 SaveData/UI 创建/整单位扫描。
- 修复 `RecordCombatFact` pcall 误捕获：`pcall` 把 `(true, {table})` 包成 `(ok, true, table)`，旧写法只取 `ok, resolved` 会把成功分类误判为 identity-cold 漏归类；改为取 `ok, r1, r2` 并消费第 3 个返回值。
- 新增验收序列 `v3_m15_3_dps_contract`（meta status=`migrated_m15_3`、store `v3.dps`、Demand、Domain、Commands、relation、bus、page `combat.stats`、widget `combat.dps` featureId `combat_stats`、运行时 scope=all）+ `v3_m15_3_dps_classification`（逐事件 PVP/PVE、显示上限 vs 累积、Clear 不停 Consumer、UNKNOWN、scope=all 订阅）；`rs_v3_acceptance` 升 v19 加入 `dps_feature_contract` / `dps_presentation_contract`。
- Runtime Harness 新增 33 条 DPS 用例（relation+store+domain+feature 经真实总线派发）：全绿；全工程 Lua 语法 290/290、TOC 134 条 0 缺失、静态扫描（Domain→Presentation 边界 / Persistence 逃逸 / 常驻 Tick）通过。
- BuildTag 升为 `v3-m1.15.3-dps-v3-migration`；FoundationGate 升 v21 加入 `dps_v3_contract`(blocker) / `dps_v3_runtime_scope`(warning)。

## 2026-08-29 — M1.15.2H2 Framework Verification / Runtime Lifecycle Hardening
- `CombatEventBusV3 v3`：`_OnCombatRaw/_OnDeathNotice` 增加第二道 `running` 闸门。此前只有 Native 闭包检查 running/Generation，`ForceQuiesce` 之后内部入口（Journal 重放、停放 Host）仍可能把战斗事实派发给已被丢弃租约的 Consumer。
- `CombatEventBusV3 v3` 新增 `quiesce` 强制失活 `_MarkInert()`：Demand 走 ForceQuiesce 时，无论 Native 释放是否成功，总线立即置 `running/globalActive=false` 并清空 Journal/去重表；真实释放错误照常上报（`quiesceFailures`），不静默吞错。
- `CombatEventBusV3 v3` 明确区分两类释放结果并分别计数：`releaseApiMissing`（RU Build 根本不暴露 Release API → 隐藏停放，不算业务失败）与 `releaseCallFailures`（API 存在但调用返回 false/异常 → 真实事务失败并回滚）。新增 `stopFailures/forcedInert` 指标。
- `CombatEventBusV3 v3` 引入 scope 分发契约（新增 `AcceptsTransport()`）：`scope=self` 的 Consumer 只收 private 传输事实，`scope=all` 收 private+global。DPS 未来启用全局桥后，DeathReview 等低成本 Consumer 不再为 all-scope 行付代价；过滤量计 `scopeFiltered`。
- 战斗热路径诊断改为 `RateLimited`：`COMBAT_CONSUMER_CALLBACK_FAILED` / `COMBAT_FACT_MUTATED` 不再每条战斗行直接写日志（原本每秒可达数百行），计数器仍逐条精确。
- `DeathReview Authority v2`：常规 Debuff 采样移出 Native COMBAT_MSG 回调。回调只记录“需要采样”，真正的 Native Aura 读取经共享 Scheduler one-shot 执行（`debuffSampleMinIntervalMs=150` 节流不变）。Finalize 的强制 Aura 读取本来就在 Scheduler 上。新增 `debuffDeferred/debuffDeferFailures` 指标。
- `FloatingSurface v3`：Native X 关闭后同步 `surface.visible=false`，消除“原生窗口已隐藏但 Surface 仍认为可见”的状态漂移；新增 `surface:Close(reason)` 作为与 X 同一契约的编程关闭入口（fail-open，仅 `allowCloseVeto` 可拦截）；新增 `closeRequests/closeVetoes/closedCallbacks` 指标。
- `WidgetHost v9`：新增共享 Feature 生命周期桥 `BindFeatureLifecycle()` + `NotifyProjectionChanged()` + 走同一关闭契约的 `RequestClose()`。
- **移除 Domain → Presentation 边**：`FeatureRuntime v3` 在 Enable/Disable 后统一广播 `v3.feature.lifecycle`；Activities / Tasks / Gear 三个 Feature 不再直接调用 `WidgetHost:SetVisible`，改由各自悬浮窗在 Presentation 侧响应。Activities 新增 `v3.activities.widget_visibility` / `widget_projection`，Tasks 新增 `v3.tasks.widget_visibility`，Gear 新增 `v3.gear.quick.visibility`。三个 Feature 同时补齐 `F.Commands`（含 `ResetWidgetVisibility` 用于自动显示失败时回滚持久化偏好）。
- 修复 Activities / Tasks 悬浮窗“关闭功能后窗口卡在屏幕上”：这两个 Feature 的 `Disable()` 会先 `Demand:Clear()` 清空整条租约（含 `widget:activities` / `widget:tasks` token），随后隐藏窗口时 `ReleaseConsumer` 必然返回 `consumer not held`，`instance:Hide` 直接失败返回，`Host:SetVisible(false)` 提前返回且 `visible` 仍为 true。改为：Feature 已停用时视为“无 consumer 可释放”，隐藏流程不再被阻断。`OnWindowClosed` 同路径修复。
- 修复 `v3_m15_2h_death_review_widget_close` 验收用例恒失败：DeathReview 悬浮窗实例此前没有 `instance.shell`（Activity/Task 有），用例必然返回 `widget_instance_missing`。同时为它补齐 `ApplyLayout/SetSize/ApplyProjection`，使其参与统一响应式重排。
- 新增验收序列 `v3_33_floating_close_contract`、`v3_34_combat_event_bus_lifecycle_contract`、`v3_35_feature_presentation_boundary_contract`；死亡回顾关闭用例增加“surface/instance/host 三态一致”与“一次关闭只触发一次 onClosed”断言。FoundationGate v20 / UIV3Acceptance v18。
- BuildTag 升为 `v3-m1.15.2h2-runtime-lifecycle-hardening`。

## 2026-08-29 — M1.15.2H1 Floating Close / RU Release Compatibility
- `WindowShell v10` 把用户关闭改为 fail-open 默认契约：普通 `onClose` 返回 false 或回调异常不再让 X 失效；只有显式 `allowCloseVeto=true` 的特殊窗口才允许阻止关闭，并增加 `onClosed` 后置清理阶段。
- `FloatingSurface v2` 透传 `onClosed/allowCloseVeto`；`WidgetHost v8` 新增 `NotifyWindowClosed/RequestClose`，Native X 关闭后统一同步逻辑 visible 状态与业务清理，避免 Shell/Host 双向递归隐藏。
- DeathReview / Activities / Tasks 悬浮窗迁到新的关闭链；DeathReview 无记录状态移除 TableView 空态覆盖层，避免摘要/空态文案在窄窗口重叠。
- `CombatEventBusV3` 对 RU 缺少 `UnregisterEvent/ReleaseEventHandler` 的客户端改用 generation-local 隐藏停放兼容模式；若 API 存在但真实 Release 返回失败，仍保持 Demand 事务失败/回滚语义。Diagnostics 增加 Private/Global Park 指标。
- 新增 DeathReview WindowShell 关闭序列验收；FoundationGate v19 / UIV3Acceptance v17 提升 WindowShell>=10、FloatingSurface>=2、WidgetHost>=8。

## 2026-08-29 — M1.15.2H Framework Hardening
- `CombatEventBusV3 v2` 增加 256 条/1500ms Pre-Identity Journal：all-scope 身份冷启动不再静默丢行；Identity Ready 后重放，过期/溢出与单 Host 覆盖通过 `FULL/DEGRADED/IDENTITY_COLD/UNAVAILABLE/INACTIVE` CoverageState 明示。
- CombatFact 改为 borrowed+immutable 契约并使用稳定订阅顺序；错误 Consumer 修改关键字段会恢复并计 `factMutationErrors`，避免污染后续 Consumer，同时不为每个 Subscriber 深拷贝热路径对象。
- DeathReview 的 UNIT_DEAD_NOTICE callback 改为 capture + Scheduler one-shot；强制 Aura、记录构建、Record/Index 持久化与自动弹窗离开 Native callback。auto-show 移到 V3 Presentation；Page/Widget 改读 Feature Projection/Commands。
- `Demand v2` 反向创建顺序 shutdown；Consumer 投影改为副本；Clear 失败可走 `ForceQuiesce` best-effort 静默下游 Native/Service 资源，并诊断 quiesce failure。Aura/Combat Demand 均提供 quiesce。
- Persistence 新增 `ReadLegacy/ClearStore/CanWrite/IsStoreLoaded` 公共机械边界；Gear/DeathReview Store 不再直接 LoadData/ClearData 或修改 Store 内部状态。Feature preference 增加 write-fence preflight 与 MarkDirty 失败 lifecycle+intent 回滚。
- FoundationGate 升级 v18、UIV3Acceptance v16；Diagnostics 增加 Combat Coverage/Journal/FactMutation、Demand Quiesce 与 DeathReview Deferred Finalize 指标。

## 2026-08-29 — M1.15.2 DeathReview V3 Migration
- `combat_death_review` 正式迁入 FeatureRuntime，成为首个 CombatEventBus 业务 Consumer；只申请 `scope=self`，关闭后释放 Combat/Aura Consumer，不依赖 DPS，也不启用 all-scope 全局桥。
- 删除旧死亡回顾的私有 COMBAT_MSG Listener / Suite OnUpdate / Legacy Presenter 依赖；自身受伤由 Combat Fact 事件驱动记录，Debuff 通过 AuraObservationV3 按 150ms 最小间隔采样并在死亡时强制刷新。
- 新增 V3 死亡历史 Page 与 FloatingSurface 最近记录窗口，复用 ViewState / Selection / ActionRunner / Persistent Setting Binding；清空历史要求 5 秒内二次确认。
- 死亡历史改为轻量 Account Index + 31 个固定 Record Slot，最多 30 条被索引引用并保留一个事务备用槽；单条 96 Event/10 Debuff 记录独立有界保存，避免 RU SaveData 大聚合表截断。
- Demand 反向回滚不再清空死亡前临时证据；重复 UNIT_DEAD_NOTICE 在 1.2s 窗口内抑制；`maxHistory` 缩减使用显式 SaveStore 事务，写失败恢复索引与设置。
- 修复 CombatEventBus 跨 Host 去重 `pairSerial` 被重复递增的问题；FoundationGate 升级 v17、UIV3Acceptance 升级 v15，并加入 DeathReview 独立 Acceptance。

## 2026-08-29 — M1.15.1 Combat Foundation
- 完成 M1.15.0 战斗调用链审计；旧 Professional DPS/Healer/Plates/DeathReview 保留为迁移参考，不重新接入 Active TOC，也不在 Foundation 阶段改业务算法。
- 新增 `UnitIdentityV3`：raw COMBAT_MSG unit id 只有在 Native name 与 source/target 唯一匹配时才绑定；显式 kind 冲突 fail-closed；有界 cache、无后台扫描。
- 新增 `CombatEventBusV3`：私有 hidden Host 提供 `scope=self` 低成本切片；只有 `scope=all` Consumer 存在时才注册全局 UI/UIParent COMBAT_MSG 桥；最后 all Consumer 离开立即释放。
- UI/UIParent 去重限定为跨 Host 短窗口成对重复；同一 Host 的连续相同行不去重。Combat Fact 只标准化 damage/heal/miss/death/raw payload，不拥有敌我、PVP/PVE、排名或治疗推荐。
- Demand 负责 Combat Native Handler 启停与失败回滚；同 Generation 私有 Host 隐藏复用，避免重复物理 ID；无 Tick/OnUpdate。Diagnostics、FoundationGate v16、UIV3Acceptance v14 纳入 Combat Foundation Contract。

## 2026-08-28 — M1.14.5 V3 Foundation Adoption / Cleanup
- 不新增第二套框架，完成 Active V3 第一轮 Foundation Adoption：系统悬浮组件/全局设置统一走 Domain-only apply + Persistent Setting Binding，消除 Host/Feature 自存 + Binding 再存的双 Save Authority。
- `WidgetHost v7` / FloatingSurface StateAdapter 增加显式 `persist` 传播；旧公共调用默认仍 `persist=true`，Settings Binding 以 `persist=false` 只应用状态后统一 MarkDirty，兼容旧调用同时保持单 Authority。
- Activities/Tasks 浮窗与 Quest Detail 扩展 ViewState；Instance 筛选改用标准 `SetSelected()` 视觉；Activities/Tasks/系统悬浮组件/全局设置/诊断的可失败操作扩大采用 ActionRunner。
- `ViewState v2`、`Binding v2.3` 增加弱注册表实时 Snapshot；ViewState Registry 按 Runtime Generation 隔离，Diagnostics 汇总 Demand/Refresh/View/Action/Binding/Floating/ScreenSnap 健康状态，不新增 Tick/全树轮询。
- Activities/Tasks 的页面 Feature 开关补齐 Consumer Acquire 失败回滚，并删除 Disable 后对已由 Demand Clear 清理 token 的重复 Release，避免 ActionRunner 把半启动状态误报为成功。
- 安全清理 Active V3 中语义完全一致的重复 helper（Demand DeepCopy、Gear Trim）；不强行合并带过滤/几何/热路径差异的本地 helper。

## 2026-08-28 — M1.14.4 View / Action / Settings Foundation
- 新增 `RSUI.ViewState`：List/Tile/Table 统一 loading/ready/empty/error/unavailable/stale；首批迁移 Activities/Tasks/Instance。
- 新增 `S.ActionRunner`：同步用户操作统一 Busy、同 ID 重入保护、异常隔离、Diagnostics 与可选 Toast；按钮临时状态用 revision 防止覆盖业务新最终状态。
- `UI Binding v2.2` 新增 Persistent Setting Binding：Store write-fence 前置检查、Domain mutation + MarkDirty 边界、Commit/失败回滚；Gear 吸附开关/距离/间距首批迁移。
- Gear 的获取当前/保存方案/检查方案/立即换装首批进入 ActionRunner；DataView 自动 Empty 只在非显式状态下生效，不覆盖 Error/Unavailable。

## 2026-08-28 — M1.14.3 FloatingSurface / HUD Foundation
- 新增 `RSUI.FloatingSurface`：严格位于 `WindowShellV3 + Windowing` 之上，统一悬浮 HUD 的位置/尺寸/最小化/锁定/三路透明度与 Feature Store 持久化映射，不建立第二套 Window Authority。
- `WindowShell v9` 新增 `collapse` 最小化模式并在状态快照中保留 normal width/height；修复最小化后标题栏高度可能污染正常窗口尺寸的问题。
- `WidgetHost v6` 增加公共 minimizable/minimized 状态与 `SetMinimized`；未创建 Widget 通过 FloatingSurface StateAdapter 直接、安全地更新持久化配置。
- Activities/Tasks 悬浮窗首批迁移：删除业务私有 RootWindow/Windowing/Opacity/Geometry 胶水；关闭事务改为 Consumer Release 成功后再隐藏/退订，避免视觉假关闭。
- ScreenSnap 公共层修复禁用目标仍参与候选的问题；FloatingSurface 可选吸附只在 Drag Stop Commit，不在 Resize Stop 触发。
- FloatingSurface 注册表按 Runtime Generation 隔离，避免 Reload 复用上一代 Surface 实例。

## 2026-08-28 — M1.14.2 Shared Runtime Foundation
- 新增 `Demand / Consumer Lease`：统一 Consumer 引用计数、Options 更新与失败反向回滚；Activities / Tasks / Instance Browser / QuestProgressV3 / InstanceCatalogV3 已迁移。
- 新增 `RefreshCoordinator`：基于唯一 Scheduler 合并短时间事件刷新，Identity 为 owner+stable key，不再让 Service 各自复制 debounce one-shot。
- 新增 `AuraObservationV3` Phase 12A：Buff/Debuff/Hidden Buff 共享事实层；无后台扫描、短 TTL/有界 coverage cache、Effect ID 缺失时才做 Tooltip fallback。
- Runtime/Bootstrap 增加 Refresh/Demand Generation 清理；Diagnostics 与 V3 Acceptance 纳入三项新 Foundation Contract。
- 修正文档现状：当前 Active TOC 已为 V3-only Host；Legacy/Professional 源码保留为迁移参考。

## 2026-08-28 — Table 列拖动文字抖动修复
- 修正上一轮实时 Column Preview 的 Fill 反馈回路：拖动开始冻结 resolved widths，Preview 改为稳定的相邻列宽对，不再每 16ms 重新求解全部 Fill Column。
- Preview 宽度量化为整数逻辑像素，并缓存 Row GridLine 位置；未变化 Cell/GridLine 不再重复 Native Anchor/Extent 写入，显著降低 RU Native Label 在拖列时的重排/ellipsis 抖动。
- DragStop 一次性提交 Preview 中的两列最终宽度，避免 Commit 后再次 Fill 求解产生二次跳变；Sequence Contract 新增“无关列不随拖动改变、总列宽保持稳定”验证。

## 2026-08-28 — RSUI 交互修复：透明度通道 / Table 实时列拖动 / 自由最小尺寸
- `WidgetHost` 与通用 `WindowShell v3` 增加整体/背景/文字三路透明度；活动悬浮窗旧单一 `opacity` 自动迁移到 `overallOpacity`，视觉兼容不丢配置。
- `TableView` Header Separator 改为手势期间实时 Preview：约 16ms interactive lane 只重排 Header + 可见池化 Row + Separator；松手只提交一次，修复列宽“松手瞬变”。
- 活动悬浮窗开启公共列拖动能力；主窗口、活动悬浮窗、未来 `WindowShell v3` 默认最小尺寸统一降为 Native 1px 技术下限，不再用 Framework/Store/Caller 三层业务 Clamp 浪费空间。
- 新增 Sequence Contract 覆盖三路透明度、精确数值设置、活动页/活动悬浮窗列拖动能力与无隐藏窗口上限。
- 全量审计当前 V3 TOC 中所有拖动型组件：Window Resize、Slider、ScrollBar、SplitView、Table Column Resize 均采用“手势期实时 Preview + 最终 Commit”；Scheduler 不可用或拒绝任务时，专用拖动 Surface/Handle 临时接管 `OnUpdate`，松手立即释放。
- 修正 Table 列宽语义：`minWidth` 只作为自动布局/推荐最小值，`absoluteMinWidth` 才是用户手动拖动的硬下限；固定列不再被布局系统强行膨胀回 `minWidth`。
- 去除 `SplitView` 默认 120px/120px 隐式最小值与 `SettingsPage` 默认 360×280 隐式窗口下限；显式 Feature 业务约束仍保持有效。
- ScrollBar 默认 Thumb 技术最小值从 28px 收敛为 12px（硬底线 6px），避免小视口下拖块填满轨道而失去可拖动行程。

## 2026-08-28 — M1.14.1 Native Identity / UI Crash Guard
- 逻辑 ID 与原生 ID 严格分离（`S.PhysicalId()` 投影，物理 ID 预算 23 ASCII、含完整 Generation Hash）。
- `NativeObjectFactory v2` 成为唯一原生构造边界；Parent Fence 在 C++ 构造前；`UI Framework v7` 统一原生写入安全检查。
- 回归门新增 `FoundationGate v11` / `NativeCapabilities v2` / `NativeObjectFactory v2` / `UI Framework v7` / `UIV3Acceptance v6` / `v3_28_native_identity_contract` / `v3_29_native_parent_fence_contract`。
- 验收：进入世界后日志不再出现 `the widget with the same name already exists` 与 `AddAnchor() expect parameter` 类异常。

## 2026-08-27 — 重建蓝图 + Native 独立 + 静态 ID R2/R3/R4 + UI 信息架构
- 发布 `Rebuild/REBUILD_BLUEPRINT.md`（V3 重建方向总纲，M1.12）。
- M1.5 Native Foundation Independence 完成（Native Contract / Object Authority / ESC / Feature API Import / Foundation Gate / Build-time 审计）。
- 静态 ID 审计 R2→R3→R4：Trade Product ItemID 84/98 → 98/98（无编号规律推测，逐项 wiki 核验）；Quest 214/214；Instance DB Zone 19/19；Runtime Instance verified=0。
- UI 信息架构重构基线：统一 `UICatalog` 为唯一 Presentation Catalog；收敛重复入口；明确 Global/Feature/HUD/Module 设置职责；V3 路由未完成前保留 Legacy。

## 2026-08-26 — Foundation Decisions v2 + 底层框架批
- `FOUNDATION_DECISIONS_v2`：Mechanism/Policy 分离、Diagnostics P0、Game Data Registry、Persistence Lifetime、UI Diff、Runtime/Authority 约束。
- RSUI Phase 3–8 全量落地 + Foundation Graduation（Foundation Freeze）+ M6-v10 审计修复（dirty layout flush / LinearBox Fill / Inspector sibling overlap / Dashboard root coverage）。
- Healer 四阶段迁移（Domain Runtime / Domain Split / Glue Persistence / Roster API Gateway）+ Settings Architecture。
- Plates 架构审计 + Runtime Foundation（P0-1 Effect ID Scan / P0-2 Factory Reset Aura Library）+ UI Diff。
- `PERSISTENCE_FRAMEWORK_v1`、`RUNTIME_FRAME_BUDGET_v1`、`UI_FRAMEWORK_v1/v2`、`Core v1` 规范集定稿。

## 2026-08-24 — Hotfix 红龙巢穴/卡杜姆
- 入场判定由任务判定改为团队副本入场次数判定；同日晚补受管对话框“一条线”渲染修复。详见 `Archive/Hotfixes/`。

## 2026-08-15 — Architecture v1.1 一次性重构完成
- 新增 `rs_module_manager` / `rs_hud_manager` / `rs_api_capabilities` / `rs_module_sandbox` / `rs_observation` / `rs_settings_registry` / `rs_profiles` / `rs_favorites` / `rs_diagnostics` / `rs_migration`。
- 四专业模块迁入 `modules/professional/`，默认关闭、统一生命周期；左侧导航主 UI 替代旧四页签。
- Audits 3–6 深审通过；Hotfix Audit 5.1–5.3；Validation 报告齐备。静态验收：Suite Lua 107、toc.g 111、直接官方 API 引用 163/51、SetEllipsis 0。
- 发布白名单仅 `globals / replicatedsuite / z_api_functions`。

## 约定
- 加新条目：在顶部插入 `## YYYY-MM-DD — 标题`，并同步更新 `CURRENT_REBUILD_STATUS.md` 的里程碑表/下一步。
- 不要在此文件复述已被 `Archive/` 收纳的审计细节。
