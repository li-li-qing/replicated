# F2：窗口精度兼容与有界数值诊断

## 输入与结论边界

输入是用户本轮 `RS-FOCUS-1 ID=1.1`，BODY_BYTES=1256，CHECK=9C2BCBD6。开发期解码器验证整条复制完整；它不含原档，`raw=0/2 rawStatus=copy_budget` 是生成端预算决定，不是用户复制丢失。

本次加载只列出 v3.buff_display、v3.death_review；v3.life.trade 已不在写保护清单。不能据此把跑商未来的每次保存也视为已验收。

两个剩余原档没有附带，因此本轮没有取得这两份真实数据，也没有证明它们各自的实际差异字段。不得把合成样本中的坐标或Hash写成用户实档。

## 真实代码与复现

状态显示的 schema5 历史 normalizer 和 schema6 当前 normalizer，都在 widgetWindow 使用共享 FloatingSurface.NormalizeState。死亡回顾 schema2 将同一窗口语义投影到其冻结字段列表；codec1 的指纹对象是 `{codec=1,payload=...}`，不是直接对 Domain 算Hash。

此前真实跑商取证证明了一个字段差异可由“保留六位小数→binary32”模型复现，并唯一还原原指纹。该模型不代表已取得客户端serializer源码。本轮把这个模型注入两套实际Store代码的合成旧档：状态显示 schema5、schema6，以及死亡回顾 schema2 均复现了旧版无法恢复单轴比例差异的问题。

schema5 使用原项目生成、已冻结的历史golden settings；不随新 normalizer 重生成以掩盖回归。其他字段的合法数值也会经历Native模型的表示变化，因此非修改字段应与“Native读出的值”比较，不声称找回其全部已丢失精度。

## 运行时变更

### 公共受限算法

`P:RebuildFixed6WindowCanonical` 收敛原跑商的算法：由Store传入已声明schema/codec与对应历史canonical；限定 Framework3、Transport2、Integrity4、Store/owner身份；两个现有中心比例字段必须在raw/decoded/canonical中一致、属于logical-free-v2且userMoved=true。

每次只改变一个已经存在的 `normalizedCenterX` 或 `normalizedCenterY` 数字。绝对值限[0.01,1)，排除跨数量级等边界，每个轴的候选格受限，最多32次全表指纹计算。只有唯一候选的整份旧指纹相同，才返回候选及只改变该叶子的Domain副本。Core继续负责元数据、预算、迁移、Apply和持久化。

这不是密码学真实性证明；延用项目原本的一致性Hash，也不新增Hash白名单。不得扩大为任意字段搜索或多字段组合来凑Hash。

### 接入边界

- 跑商：改为委托公共算法，原真实fixture及负面测试保持通过。
- 状态显示：先严格验证追踪列表表形未改变，再用旧schema5或当前schema6 canonical尝试数值恢复；验证旧章在迁移之前。
- 死亡回顾：先检查原始history.entries是完整连续序列且未发生转换，再尝试窗口桥。序列有效性通过显式第三返回值传递，不依赖诊断字符串。不会读取或重写死亡record分片，也不启动DPS。
- 复合序列变形与数值变化、两轴同时丢精度、范围外的值、未知schema/codec/transport、其他内容变化、无命中和多命中均继续写保护。
- Transport3的新保存路径、业务schema、指纹算法、budget与保存key均未改变。

### 有界诊断

恢复冷路径缓存两轴原始17位数值字符串、旧6位token、范围/结构检查结果、候选数和匹配数。不保留完整raw/canonical，不从当前默认Domain捏造旧数据。新物理读取时清理旧证据；失败缓存命中继续保留同一加载事实。回读不能覆盖Load证据。

聚焦报告增加原子 `N:<Store>` 行，即使原档因copy_budget省略，也可得到两轴真实数值与检查结果。`numeric=2/2` 表示两个故障Store带有该类有限诊断，不代表两份原档齐全。`raw=0/2` 仍如实保留，完整报告仍最多3500字节、一次复制、两个按钮不变。

所有额外工作在存档失败冷路径或显式打印时执行，无Tick、轮询、订阅或新的Native读取；打印仍至多读取一份原档。若恢复失败仍需进一步分析，下一份报告提供数值而不是再次只提供相同Hash。

## 测试与限制

新增25项窗口精度回归：三种schema/codec旧档的单轴恢复、保存Transport3与全新加载；源值/历史/非窗口偏好保留；另一轴、负数、极小值、错误身份与新传输拒绝；双轴损失、其他内容改变、稀疏历史、歧义Hash拒绝；30条历史索引保留；新读取清理证据；回读不污染证据；诊断文本不是恢复Authority。

新增2项聚焦报告回归：原档超容量时仍一次复制两套数值证据，且没有第二次Native读取；更多故障时整行省略并计数。原测试继续覆盖真实跑商fixture、新旧传输、状态显示、存档管线、报告UI与解码工具。

环境是本地liblua5.4与已有兼容垫片，Native存储/控件为模拟；Lua5.1解释器不可用，下载尝试失败。没有RU客户端、Lua5.1执行或两个F2真实原档恢复成功的声明。

命令：

```text
python tools/rs_status_refactor_test_runner.py
python tools/rs_status_refactor_test_runner.py --window-numeric
python tools/rs_status_refactor_test_runner.py --syntax
python -m unittest discover -s tools -p 'test_*.py'
```

## 覆盖与验收

基线为 Addon(20260912-025223).zip + 两按钮自检 + 报告交付 + 容量回退 + 回读适配 + 聚焦报告 + 跑商精度恢复。覆盖增量包全部文件，先备份代码和配置，不清档，不重置默认值。TOC和API参考目录不变。

使用“重新加载文件”而不是只切页。检查状态显示旧追踪清单、自己/目标HUD、死亡历史与跑商是否保留；成功加载后改一项普通设置，再重载验证保存。无法恢复的旧档继续Fenced，由下一条聚焦报告的N行提供证据。

上一轮已引入Transport3：降级仍必须恢复匹配代码和配置备份，不能单独换旧Core。本轮没有再次升级传输或schema。
