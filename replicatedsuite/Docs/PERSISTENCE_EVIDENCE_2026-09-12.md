# 存档校验失败：单条诊断与只读取证

日期：2026-09-12  
默认聊天诊断标识：`RS-DIAG-3`；原始取证格式仍为 `RS-PERSIST-EVIDENCE-1`  
类型：单条复制交互修正 + 保留用户主动导出，不是存档恢复补丁。

## 1. 基线与当前证据

覆盖基线按顺序为：

1. `Addon(20260911-164009).zip`
2. `ReplicatedSuite_StatusTracking_Freeze_Library_Patch_2026-09-12.zip`
3. `ReplicatedSuite_Persistence_Status_Recovery_Hotfix_2026-09-12.zip`
4. `ReplicatedSuite_Persistence_ReadOnly_Evidence_Patch_2026-09-12.zip`

本轮基于以上四者完整叠加后的文件进行修改。仅增量覆盖，不包含上述旧包。全局版本号未改，仍可能显示 `.18.208`。

用户最新实机日志显示：

- `v3.buff_display` 原 stamp 为 `1E7F5813`，当前 canonical 为 `6307A930`；schema5 historical candidate 为 `6623AE99`，仍不匹配。
- BuffDisplay 和 DeathReview 的恢复探针均为 `sequence=unchanged`。
- `fenced=3`、`integrityFail=3`，没有成功恢复的证据。
- 构建事务阻断已不在未通过列表内，但这不等于存档恢复。
- 后续用户日志确认第三项为 `v3.life.trade`，当前指纹仅见前缀 `48B0E`；完整指纹仍不能补猜。

这些信息只能排除“上一轮已成功恢复”的判断，不能反推具体变动字段、原始布局、追踪列表或历史记录。尚无用户实际 `LoadData` 返回表，无法确认是历史规范化差异、传输改变还是数据损坏。本轮不新增候选恢复分支，不放行未知 Hash，不把默认值盖到旧档。

## 2. 用户操作

先备份现有插件及配置，在上述基线上覆盖本轮 `replicatedsuite/`，使用“重新加载文件”。无需清空配置，不要重置默认值。

### 单条报告（当前默认）

点击“输出诊断摘要”或“输出存档故障”，每次均只提交**一条**聊天消息：以 `RS-DIAG-3` 开头、以 `| END` 结束。只需复制这一条，不再自动追加 `RS-SUMMARY 1/30` 等分段，也不逐个发送 Store 说明。

报告优先保留当前所有写保护 Store 的名称、schema、完整原/现指纹、raw 指纹和恢复状态。三个当前故障 Store 的标准元数据可放在同一条内；更多/更长的条目超出预算时只省略**整条记录**，显式标记 `more=N`，禁止截半个指纹或悄悄丢掉尾部。没有写保护时展示失败的框架检查 ID，超额标记 `checksMore=N`。

字段：`b` 是版本数字段（不重复冗长描述后缀）；`B/W` 是最近一次 Gate 验收的阻断/警告数（不会重跑验收）；`F` 是当前注册 Store 的写保护数；`s旧>当前` 是 schema；随后的 `旧指纹>当前指纹` 均完整保留；`r` 为缓存的 raw 指纹，**不保证等同 historical candidate**；`m框架/传输/codec` 为存档元数据。

`q` 表示序列恢复探针：`U`=unchanged、`A`=unavailable、`C`=存在数字变化计数、`?`=其它结果、`-`=未记录。`h` 表示恢复函数状态：`C`=candidate、`N`=no_candidate、`E`=exception、`R`=not_registered、`S`=not_called、`I`=called、`-`=未记录。**candidate 或序列发生变化均不表示存档通过校验**，最终写保护仍由 Core 决定。

缺失元数据显示 `-`，格式未知显示 `?`；Gate 未运行时 `B?/W?`，Persistence 未就绪时 `F?`，不能伪装成零故障。`END` 只是传输尾标，不是完整性认证。只读当前缓存，不执行 BuildCopyText/Run/LoadData/SaveData，不打印 SaveKey、原始 lastError 或玩家业务字段。完整原始取证仍由下方文本框显式读取，不塞入聊天摘要。

### 读取真实字段

打开 `PVP → 状态显示` 的“配置已保护”页面。选择一个故障 Store，点击“读取故障存档”。点击复制框，使用 Ctrl+A、Ctrl+C，粘贴到本地 `.txt`。

出现多段时，用“下一段”逐段复制到**同一个 Store 的同一个文本文件**；保留每段首尾标记。不同 Store 分开文件。界面列出全部当前写保护项，本次日志为三个；不必猜测第三个名称或查找整份账号数据库。

隐藏页面会清空取证文本缓存，未复制前不要离开。切换 Store 也会清空旧文本；“清空取证文本”只清空显示，不删除存档。页面打开、翻页、普通诊断不会额外读取所选存档；每次主动“读取”调用一次 Native LoadData。

原始返回字段可能包含角色/玩家名称、状态 ID、历史记录和布局，只提交给负责定位的维护者，不要公开分享。程序不会自动上传。导出内容是 API 本次返回的表，不是磁盘原始字节，也不证明与首次失败读到的表完全相同。

若提示“文本回读不一致”或超限，导出整体失败；不要把局部内容当作完整样本。真实 RU 的剪贴板、编辑框和滚动布局仍需实机确认。

## 3. 所有权和数据流

```text
用户显式点击
  → Presentation / Diagnostics 转发
  → Core 校验 registered / fenced / resolvedKey / character scope
  → S.Api:LoadData(resolvedKey) 一次
  → InspectPayload（原表，不规范化）
  → ASCII 带类型序列化 + 复制校验
  → 页面分段复制框
  → 用户手动保存文本
```

Core 独占 SaveKey、scope 和预算；界面没有持久化 Authority。导出路径不调用 Store.default/decode/migrate/apply，不调用 SaveData/ClearData，不改变 Store 的 dirty/fence/loadStatus 或失败信息。恢复/迁移/哈希/旧 Hash 白名单/Store schema 全部维持前一基线。

Native 编辑框使用共享输入生命周期。失败时禁用取证按钮；隐藏时释放键盘所有权，不退休仍可重开的编辑框。较长故障页复用 Foundation ScrollablePageRoot，不新增坐标、滚轮或 Tick 系统。正常四页签不变。

## 4. 输出格式与边界

完整 envelope：

```text
RS-PERSIST-EVIDENCE-1
BYTES=<ASCII body bytes>
CHECK=<8 uppercase hex>
<typed body>
RS-PERSIST-EVIDENCE-END
```

复制框 page：

```text
RS-PERSIST-PART-1 i=<index> n=<total> check=<same check> bytes=<chunk length>
<fragment of complete envelope>
RS-PERSIST-PART-END
```

Typed body：`N;`、`B0;`/`B1;`、`D<number>;`、`S<byte length>:<HEX>;`、`T<count>{<key><value>...}`。数字采用 `%.17g`，字符串保存完整原始字节；数字键 `1` 和字符串键 `"1"` 不合并，false/0/空字符串/空表保留。仅支持 Native SaveData 契约中的字符串/数字键。复制校验采用项目既有多项式 hash，仅用于发现缺段/改字，不是密码学认证，不参与接受存档。

只读预算不超过 Store 原有 encodedBudget，另设硬上限：深度15、节点64000、字符串累计131072字节、单表4096项、编码 body 262144字节。超限、环、非法类型、非有限数、Native 异常或角色 scope 变化整体拒绝，不截断数据伪造完整输出。每段最多30000字节，编辑框写入后立即 GetText 比较；分页始终来自一次快照。

单条摘要正文最多 288 字节，采用 ASCII 诊断字段；加当前 SafeChat 的 27 字节中文前缀最多 315 字节。此数值是保守预算，不是声称 Native 上限已实测。任意带控制字节或超长的成品会拒绝发送，调用失败/抛错不追加第二条。只在 SafeChat 不存在时选择 DispatchSystemChat，不改变全局聊天分发逻辑。

详细 `BuildPersistenceFailureReport()`、`BuildCopyText()` 和开发期 `PrintBoundedText()` 接口保留兼容，但默认两个诊断动作不再调用它们自动刷屏；专用 HUD/Popup 报告等其它诊断动作不在本轮修改范围。

## 5. 开发者解码与测试

运行离线 Lua 回归会生成两个仅供测试的 `tools/.evidence_test_*.txt`，不要加入发行 ZIP 或运行时 TOC。随后执行 Python 解码器测试：

```sh
python tools/rs_status_refactor_test_runner.py
python -m unittest discover -s tools -p test_rs_persistence_evidence_decode.py -v
python tools/rs_status_refactor_test_runner.py --syntax
```

单份用户样本解码：

```sh
python tools/rs_persistence_evidence_decode.py input.txt -o evidence.json
```

解码器纯标准库、严格语法，不执行 Lua/eval，不接触游戏配置。输出为带类型 JSON，字符串保留 hex 和可用的 UTF-8 文本。拒绝缺段/重复段/混合导出、长度/校验不符、非法结构和超限；不覆盖已存在的输出文件。解码成功不等于存档校验通过。

本轮离线：88项 Lua 回归（上一轮72项，本轮补充16项并调整旧的多条输出预期），13项 Python 解码回归，237个 Lua 文件语法检查。环境为 Lua5.4 + Lua5.1 兼容垫片；未执行 Lua5.1/RU客户端验收，也未使用用户真实 SaveData 证明恢复。

## 6. 后续定位约束

收到真实样本后先验证复制完整性，保留原文件及校验值，再离线对照 Native raw、transport decode、schema5 historical canonical 和 schema6 canonical。不得把本轮样本的复制校验当作可信原始 stamp。找到可复现字段变化后，先添加失败用例，再按精确旧指纹匹配制定恢复；未知数据保持写保护。不要继续仅凭三组 Hash 叠加猜测分支。
