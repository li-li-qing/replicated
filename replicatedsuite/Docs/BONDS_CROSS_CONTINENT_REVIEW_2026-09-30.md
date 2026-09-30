# Replicated Suite：债券跨大陆采集与保存恢复检查

日期：2026-09-30  
识别标记：`bonds-cross-continent-1`  
交付：增量修改文件，不是完整工程。

## 1. 检查结论与完成内容

用户反馈：部分客户端只显示当前大陆的债券，跨大陆后先前内容没有保留；维护者本地测试正常。

本轮没有取得受影响玩家的原始存档或完整模块诊断，不能断言所有反馈由同一个原因导致。已使用当前真实 Authority、Demand、Events、Scheduler、Persistence 和 Transport 代码复现并修复若干条件性缺陷。Native API、日期、存储介质由开发测试输入模拟；这不等于 RU 实机验收。

正常情况下，原本的同日 west/east 快照合并、实际 SaveStore 与新实例 LoadStore 就能保留两大陆。因此，维护者的正常本地结果与其他客户端触发边界问题并不矛盾。没有发现“每次去另一大陆，都无条件删掉上一大陆”的正常合并行为。

### 1.1 原生行表的键表示和稀疏排列导致采集丢行

文件：`features/life/bonds/rs_bonds_feature.lua`，`NormalizeResidentBoardContents`。

原先先用 ipairs 遍历；若前半段已有内容，遇到空洞后不进入备用分支，后半段直接遗漏。备用分支把字符串数字键转成数字后，再用数字索引原表，读取不到 `contents["1"]`；只含字符串索引的裸表也没有进入有效 source 分支。

现在按实际键值建立有界索引再排序，支持规范字符串数字索引和稀疏 Native 行。元数据不当成任务行，数字/字符串别名碰撞整体拒绝，单板最多检查 192 项；保留原来的每板 4 行、每行 160 字节持久化预算。Native 读取允许稀疏，与持久化序列必须完整的边界分开处理。

### 1.2 局部加载被误判成没有可保存的居民板

原来主大陆只有第 3、4 板同时有内容才被识别，原大陆只检查第 5、6 板。在可明确归属的前提下，第 1/2 板先加载，或者原大陆只有第 7 板有内容，均可能没有进入保存链。

现在主大陆检查 1..4，原大陆检查 5..7；可归属的局部板先合并，同日后续实际读取到的板再补齐，空读不删除已有快照。西/东必须有已知区域或明确 faction 证据，不猜未知主大陆归属。

兼容性复核发现，旧 B3 测试支持“1..4 和第 5 板同时非空”。不能一律把混合板族当成坏数据：已知所在地时仅采集对应板区间，未知所在地的混合板族才等待重新确认。旧 B3 断言完整保留。

有内容板的 faction 与已知西/东位置相冲突时，不把上一大陆的旧板写成目的大陆数据，等待有限恢复探测。未知主大陆区域仍保留原版 board1.faction 等 locator 兜底，即使该板的文本为空；空板元数据不会覆盖已知位置或有内容板的明确证据。未扩张静态区域表，也没有编造远程查询接口。

这些时序/表示输入能在离线测试触发缺陷，但受影响玩家实际是否遇到这种 Native 返回形状，仍需模块诊断核实。

### 1.3 单次 750ms 跨区探测没有覆盖加载较慢的情况

原来区域事件只安排一次 750ms one-shot。第一次读空、局部返回或服务器日期未就绪，后续没有可靠的有限补读；首开无数据也没有完整恢复序列。

现在在需求首开、显式刷新及位置生命周期边界上，使用共享 Scheduler 的同一个任务名，最多做 3 次延迟探测，逐次等待 750 / 1500 / 3000ms；成功即停止。补充可选 `LEFT_LOADING` 事件；客户端不支持该事件不构成启动硬依赖。

新事件替换旧序列；取消需求、禁用模块、热重载 generation 变化或 S 实例变化后，旧回调不能继续读取。最后一个消费者退出时移除任务，不因隐藏与关闭混淆而后台永久轮询。

超过有限预算仍未就绪时，记录 exhausted，不无限重试；后续加载事件、重新打开功能页面/悬浮窗或手动刷新可以开启新序列。纯排序/筛选和 quest_progress 重算不触发居民板补读，避免把频繁任务事件变成隐式轮询。

### 1.4 日期未知时，新数据被混入旧日期

原代码在服务器日期未知时保留旧缓存，但仍继续采集新的居民板和记录新的完成锁存。这可能把新地点信息写在旧日期下，或者形成无日期快照，随后合法日期恢复又将其清掉。

现在日期未就绪只投影已经恢复的快照，不采集新板、不把当前新完成状态写入旧日锁存。实时完成状态仍可用于展示。日期明确后再按已有服务器日规则采集；真正跨日仍使昨日债券失效，不把昨日任务永久保留为今日任务。

### 1.5 SaveData 数组键表示变化引发恢复失败

`NormalizeBondSnapshot` 原先只按数字数组恢复 boards / lines。离线把 Native 保存后的数字键转换为规范字符串数字键，可以复现真实 SaveStore 读回/新 LoadStore 失败：内容还在，但被当前归一化当作空序列丢掉，导致与原盖章指纹不符。

现在只对 Bonds 已声明的 boards / lines 序列使用 Core 现有的完整 1..N 重建函数。普通数字数组的 canonical 不变；字符串数字序列重建仍必须通过原 envelope 和 domain stamped fingerprint。

这不是放宽全部存档校验。缺口、重复别名、非规范索引、篡改文本、缺失大陆仍拒绝，真实损坏仍写保护。没有修改 Persistence / Transport 通用实现、Store ID、Schema、scope、存档预算或历史 pre-continentOrder 精确恢复钩子。

### 1.6 诊断分清未采集、被筛选隐藏和没有成功落盘

新增 Bonds:GetHealth，直接接入现有模块诊断提供器；扩充 DescribeDailyCache，普通诊断也继续使用原入口。两者不读取居民板，不 Load/Save，不清 fence。

| 字段 | 用途 |
|---|---|
| `patch` | 是否运行 `bonds-cross-continent-1` |
| `dayKey` / `serverDateKey` | 当前快照日期 / 最近一次刷新取得的服务器日期 |
| `coverage.west/east/auroria.lines` | 各大陆内存缓存的真实行数 |
| `coverage.*.visibleRows` | 筛选和去重后实际显示行数 |
| `filters` | 数量筛选、原大陆、已完成、合并与优先大陆偏好 |
| `lastBoardProbe` | 最近一次 Native 探测：板数、归属、空读/冲突/等待日期、合并结果 |
| `recovery` | 有限恢复是否 pending / complete / exhausted / cancelled，以及次数 |
| `persistence` | 已加载、脏数据、写保护、存储失败、读回验证和 revision 元数据 |
| `lastSaveIntent` | 最近的 MarkDirty 请求是否被接受，不代表已安全落盘 |

例如 east.lines 大于 0，但 visibleRows 为 0，说明数据仍在，需要检查合并/筛选，而不是删除用户存档。显示行数不等于完整存储量，内存有缓存也不等于保存已经成功。

## 2. 修改文件

以当前对话累计工程为基线：
`Addon(20260929-172837).zip` → RefactorReview → LiveContract → UI_Position → Auction_UserPriority，依次覆盖。本次没有收到新的完整工程。

修改 4 个、新增 2 个，无删除；只有 1 个运行时文件。

| 类型 | 相对 replicatedsuite 的路径 |
|---|---|
| 修改 / 运行时 | `features/life/bonds/rs_bonds_feature.lua` |
| 修改 / 测试 | `tools/rs_bonds_tests.lua` |
| 修改 / 静态契约测试 | `tools/rs_bonds_auroria_regression_tests.py` |
| 修改 / 默认门禁 | `tools/rs_status_refactor_test_runner.py` |
| 新增 / 回归 | `tools/rs_bonds_cross_continent_tests.lua` |
| 新增 / 报告 | `Docs/BONDS_CROSS_CONTINENT_REVIEW_2026-09-30.md` |

原有 Bonds 测试补充了固定的有效 Native 服务器日期：原来宿主完全没有提供日期，依赖未知日期仍允许采集的漏洞。原有 23 项断言保留，包括旧格式精确恢复和混合板族的兼容测试。静态脚本更新旧的 3/4、5/6、单次 750ms 条件，改为检查新边界与有限恢复契约；没有删除行为测试来制造通过。

原有 CRLF 文件保持 CRLF。测试与报告不加入 toc.g。此前的窗口位置和拍卖用户优先修复保留。

## 3. 性能影响

不新增永久 Tick、OnUpdate 或常驻独立观察器。每次恢复序列最多 3 个延迟探测，每个最多读取 7 块居民板；首开另有原来的立即刷新。每次延迟探测沿用 BA:Refresh 的既有材料/任务投影逻辑，包含其资源读取成本，不宣称完全零开销。

与只试一次相比，慢加载时增加有限重试；成功即止，禁用/无消费者时取消。另一方面，纯排序/筛选及任务进度投影不再因当前大陆缓存缺失而重新读取居民板。

只新增少量恢复状态和最近一次摘要；不保存完整历史日志。现有同日快照预算保持不变。没有 RU 客户端 CPU、内存或帧时间实测，不给出虚构的性能收益百分比。

## 4. 验证与兼容风险

### 离线结果

| 验证 | 结果 |
|---|---|
| 最终新增同一套回归放回未修复运行时 | 13/39 通过，26 组失败 |
| 新增跨大陆/日期/键表示/真实持久化/生命周期/诊断回归 | 39/39 通过 |
| 原有 Bonds 功能测试 | 23/23 通过 |
| 默认全量 Runner | 通过，退出码 0 |
| 10 个独立 Python 回归脚本 | 全部通过 |
| 窗口视口 / 重载位置 / 方案按钮 | 66/66、26/26、14/14 通过 |
| 拍卖用户优先 / 跑商集成 | 27/27、6/6 通过 |
| Feature 拆分 / Core 解耦 / Live Gate / Live Contract | 66/66、128/128、17/17、18/18 通过 |
| TOC 安装完整性 | 298/298，无缺失、空文件或冲突标记 |
| 架构 / Native 依赖审计 | 0 已知问题 / 0 错误、阻断、警告 |
| 测试依赖审计 | 通过 |
| Lua 语法 | 425 个文件在 Lua 5.4 下通过 |
| 第二份干净累计基线覆盖本次代码后 | 默认全量、全部独立脚本、语法、安装和审计通过 |
| 真正 Lua 5.1 编译门禁 | BLOCKED，退出码 2：未安装 luac5.1/luac-5.1 |
| RU 客户端实机 | 尚未执行 |

26 组失败包含同一缺陷的边界和新增诊断契约，不是 26 个互相独立的业务故障。新增保存测试使用 `verifyAfterSave=true`，没有用无效选项代替真实读回验证。完整日志、diff、文件哈希与交付检查收录于独立证据包。

### 覆盖与升级

退出游戏、备份当前插件和用户存档，再把补丁的 replicatedsuite 合并覆盖到原 Addon 下同名目录。不要先删除旧目录，不需要清配置、清缓存或重新安装其他补丁。首次完整重启客户端。

BuildTag 仍可能为 `.18.332`，以模块诊断的 `bonds-cross-continent-1` 判断本逻辑是否加载。优先请此前能复现的用户验证，再扩大发布范围。

真正已丢失的历史快照不能凭空重建；未去过/未采集、功能关闭期间未观察到的大陆，也不会远程伪造数据。已经真实损坏或缺失字段的存档仍受保护，本补丁不解除写保护。日期变化后旧日快照失效属于原设计。

## 5. 实机必测和后续定位

先在原有布局下开启债券主页面或悬浮窗，为观察差异临时选择“全部显示”，保留各数量类型与原大陆。西大陆采集后转东大陆，再去原大陆，确认同一服务器日此前已采集大陆仍在。主页面和悬浮窗共用同一 projection，不应各自少一份数据。

重复一次热重载和完整重登，再验证“合并重复材料、优先西/东”只改变显示，不改变 coverage 内存行数。用加载较慢的客户端或跨大陆传送复现，观察局部数据是否补齐。等待期间禁用模块、关闭最后一个消费者后，不应继续读板；重新打开可恢复。

日期边界需要验证服务器日期未知→就绪、真实跨日。真实跨日后不要把昨日行消失当成本次缓存丢失。

仍有失败时，不清存档，保留债券模块完整分页诊断，并说明跨大陆前后、重登前后、当时的筛选模式。重点比较 dailyCache.coverage、lastBoardProbe、recovery、persistence；需要核实被反馈用户的实际 Native 返回和保存保护原因，而不是根据维护者本地通过直接关闭问题。

### 本地验证命令（在 replicatedsuite 目录）

```text
python tools/rs_status_refactor_test_runner.py --bonds-cross-continent
python tools/rs_status_refactor_test_runner.py
python tools/rs_status_refactor_test_runner.py --syntax
python tools/rs_check_installation.py .
python tools/rs_architecture_audit.py
python tools/rs_native_dependency_audit.py
python tools/rs_test_dependency_audit.py
python tools/rs_lua51_compile_gate.py
```

`--syntax` 若实际使用 Lua 5.4，不能当作 Lua 5.1 编译通过。5.1 门禁失败/缺工具必须如实报告，不删除门禁。

### 外部参考的有限用途

复核了 Strawberry-devs / ArcheRage-addons 的 residentboard.lua：其界面从第 1 板读取 faction locator，并根据 3/4 或 5/6 内容选择板族。这个示例没有覆盖本项目的跨大陆持久化，也不能证明受影响玩家的确切返回形状；本次结论仍以本工程真实调用链和可复现实验为依据。参考地址：

```text
https://raw.githubusercontent.com/Strawberry-devs/ArcheRage-addons/master/residentboard/residentboard.lua
```
