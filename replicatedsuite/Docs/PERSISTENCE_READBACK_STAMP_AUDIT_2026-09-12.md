# 存档公共回读校验复查与修复

日期：2026-09-12。基线：`Addon(20260911-164009).zip`，依次覆盖状态追踪补丁、存档恢复热修复、只读取证补丁和单条诊断补丁。

## 本轮结论

已修复 **回读确认与下一次加载判定不一致** 的公共验证漏洞。尚未恢复用户当前受保护的三个存档，也未确认它们的原始生成原因。不能把本轮测试解释为用户存档恢复成功。

本轮没有实际用户 SaveData 载荷。现有输入是源代码、此前的补丁和用户粘贴的 RS-DIAG-3；上传的状态显示重构计划不是存档导出文件。

用户原始摘要：

```text
RS-DIAG-3 b=v3-m1.16.0.18.208 B2/W2 F3
v3.buff_display s5>6 1E7F5813>6307A930 r6623AE99 m3/2/- qU hC
v3.death_review s2>2 695423CD>3B54171E r3B54171E m3/2/1 qU hN
v3.life.trade s1>1 6BE9E557>48B0E072 r48B0E072 m3/2/- q- hR
END
```

这些摘要证明已发生校验拒绝，但不能证明哪个字段变化、变化发生于哪次保存，也不能反推原始内容。没有为上述任何指纹添加白名单。

## 1. 实际检查的链路

- `features/life/rs_life_m16_bundle.lua`：Trade Store 注册、NormalizeTradeState、get/apply 与收藏结构。
- `features/combat/death_review/rs_death_review_store.lua`：schema2 Index、codec1、settings/history/widgetWindow 与恢复入口。
- `features/combat/buff_display/rs_buff_display_store.lua`：schema6、旧 schema5 canonical、双 HUD、追踪桶与迁移。
- `ui/framework/rs_ui_floating_surface.lua`：窗口状态规范化的纯函数边界。
- `core/rs_reuse.lua`、`core/rs_utils.lua`：真实深拷贝与工具实现。
- `core/rs_api.lua`、`core/rs_api_capabilities.lua`：真实 SaveData/LoadData 包装与能力门。
- `core/rs_persistence.lua`：SaveStore/SaveValue、两次 canonical 使用、transport、metadata seal、VerifyPersistedValue、Flush、LoadStore。
- `z_api_functions/README.md` 与 `api_functions.lua`：仅提供 `LoadData(key)`、`SaveData(key, table)` 的参考边界；没有提供用户当前读取结果。

## 2. 已复现的漏洞

定义：

- E：当前准备验证的 Domain 按 Store canonical 算出的指纹。
- A：本次 LoadData 回读内容按同一 canonical 算出的指纹。
- S：磁盘 metadata 中保存的 `encodedFingerprint`。

旧的 integrity-v4 回读路径检查了 metadata seal，也检查了 E == A，但漏掉 S 与 E/A 的绑定。

metadata seal 证明的是元数据自洽；它包含 S，不等于证明业务内容算出的指纹就是 S。于是，一份 **E == A，但 S != A** 且元数据封印有效的表，可以通过回读和 Flush，随后又被 LoadStore 正确拒绝。

测试直接复用了三个真实 Store、生产 API 包装、能力门和 Persistence。仅 ADDON 的 Native 层是内存盘。合成样本有意保留业务内容、改变 S 并重新封印 metadata，以检验验证器是否遵守完整契约；**这不是对 RU Native 会重写封印的假设，也不是用户原始存档样本**。

修复前：40 项新回归中 28 项通过、12 项失败。三个 Store 都出现四类相同问题：

1. 验证器接受旧业务章；
2. durable SaveStore 错误报告成功；
3. Flush 错误清除耐久回读义务；
4. 内容与期望一致时仍能绕过业务章绑定。

同一份合成表在新注册的 Addon 环境中运行 LoadStore，则拒绝读取并保持写保护。因此此处不是仅根据代码怀疑，而是旧验证器和加载器之间可重复验证的判定矛盾。

## 3. 实际修复

在 `VerifyPersistedValue` 计算 E/A 成功后、进入精确表示恢复之前，增加：

```text
当前 canonical 回读：先要求 S == E；随后原逻辑要求 A == E。
最终成功条件为 S == E == A。
```

失败原因：

```text
readback_stamped_fingerprint_mismatch:<磁盘章>><期望章>
```

失败沿用原 Fail、SaveStore 和 Flush 路径，不盖新章、不 Apply、不在证明过程中写盘、不解除任何现有写保护。Flush 既有重试行为仍只针对已安全加载的 Domain；启动时加载失败的三个 Store 不因此变为可写。

**检查发生在回读阶段，SaveData 可能已经触碰物理键；因此检测到失败不等于旧磁盘内容未改变，也不等于能自动还原。** 本轮没有新增备份/回滚文件或自动恢复承诺。

只增加常数时间的短字符串比较，没有新增读取、保存、全表扫描、事件监听、Tick、轮询或 Native API。

## 4. 兼容边界

- 不修改当前 Hash 算法、Store schema、codec、transport、canonical、历史迁移与已知恢复规则。
- integrity-v2 的章是 encoded payload 章，不能拿它与 Domain 章直接比较；新检查只作用于现有 canonicalReadback 分支。三个 Store 的 v2 回读正例保持通过。
- 已有精确序列表形恢复仍要求正确的期望章；原有全部回归通过。
- 单条 RS-DIAG-3 和完整取证文本框保持原样；不再添加聊天输出。
- 全局 `.18.208` BuildTag 未改；修复文件的 SHA256 见补丁 manifest。
- **这是验证漏洞修复，不是三个故障存档的恢复补丁。覆盖后 F3 仍可能原样存在。**

## 5. 新回归覆盖

三个 Store 分别覆盖：默认/自定义配置保存后重注册加载、真实 API 能力门、纯函数/深拷贝/编码幂等性、回读不 Apply、不写盘、旧业务章拒绝、耐久 SaveStore 拒绝、Flush 屏障保留义务、错误章不进入候选恢复、业务数据改变拒绝、错误期望值拒绝、元数据封印/owner 拒绝、旧 v2 readback 正例。

另覆盖 transport2 的 false、0、空表、空字符串、保留前缀转义、数字/字符串同名键及带 NUL 的字节字符串往返。

默认验证命令同时执行原状态显示回归与新公共链路回归：

```sh
python tools/rs_status_refactor_test_runner.py
python tools/rs_status_refactor_test_runner.py --pipeline
python tools/rs_status_refactor_test_runner.py --syntax
python -m unittest discover -s tools -p 'test_*.py' -v
```

新测试不进入 toc.g。默认配置和选定自定义配置通过，不能推导所有用户输入、所有 Native 序列化形态都已验证。

## 6. 环境与未完成事项

本轮执行环境为 Linux `liblua5.4` 加现有兼容垫片。没有 Lua 5.1 / LuaJIT 可执行文件；尝试下载官方 Lua 5.1.5 源码时容器 DNS 失败，因此没有宣称跑过 Lua 5.1。测试未连接 RU 客户端，也未做实机性能和 UI 验收。

所谓“重注册加载”是在同一个 Lua VM 中创建新 ReplicatedSuite、API、能力门、Store 和内存盘宿主，不是新 OS 进程，也不是 RU 重启。

**尚缺的关键材料：`v3.life.trade` 的完整只读取证导出。** 先取这一份即可，不需要重新上传整个项目或重复发送同一条 Hash 摘要。入口保持：PVP → 状态显示 → 配置已保护 → 选择 v3.life.trade → 读取故障存档 → 文本框复制到 .txt。多段时保留全部首尾标记。

拿到真实样本后，才能逐项比较物理表、transport 解码结果、当前 canonical 与对应历史规则，并判断是否能在不丢设置的前提下精确恢复。当前不把模拟测试中的错误章更换用作用户存档修复手段。
