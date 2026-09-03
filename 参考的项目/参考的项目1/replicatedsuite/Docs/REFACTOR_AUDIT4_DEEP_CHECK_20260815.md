# Replicated Suite Architecture v1.1 — Audit 4 深度检查报告

版本：`1.0.3-architecture-v1.1-audit4`  
保存结构：`Schema 19`  
日期：2026-08-15  
作者：Replicated

## 结论

本轮继续以最终冻结的 `Replicated Suite Architecture Final v1.1` 为裁决，不重复 Audit3 已完成的模块拆分，而是继续检查生命周期、DataScope、隐藏 Runtime、旧 HUD 残留和迁移安全性。

Audit4 已直接修入工作树。当前代码静态层面可以进入下一轮 ArcheRage 实机验证；仍需实机证明的项目在文末单独列出，没有伪造“已验证”。

## 本轮确认并修复

### 1. Suite DataScope 从“模块元数据”变成真实存储基础设施

`Schema 18 -> 19`，Suite 存储增加：

- Account 基础状态；
- `characterOverrides[UnitNameWithWorld]`；
- 角色域模块启用状态；
- 团队辅助角色设置；
- 日常追踪 / 当日完成状态；
- 资源日计数。

这次只接管 **Suite 自己明确拥有、作用域无歧义的数据**。DPS / Healer / Gear / Plates 的历史 Domain SaveKey 不被 Core 擅自改写。

### 2. Character Override 迁移不会反写 Runtime State

旧 `BuildSavePayload()` 返回的是 State 表引用。首版实现如果直接在 payload 上恢复 Account 基线，会连当前 Runtime State 一起改掉。

现已改为：

1. 先快照当前角色有效状态；
2. DeepCopy 序列化 payload；
3. 只在 detached payload 内恢复 Account 基线；
4. 再把角色有效状态写入 Character Override。

已通过迁移仿真。

### 3. 角色身份冷启动不再造成配置丢失

`UnitNameWithWorld("player")` 在登录 / UI reload 的极早阶段可能暂时不可用。

现在的策略：

- 身份已识别：正规保存为 Account + Character Override；
- 身份暂不可用：保持旧版“当前有效快照”语义，优先保证用户刚修改的数据不丢；
- 后续身份可用后：下一次保存自动正规化回 Account + Character Override。

诊断页会显示 Character 是否已识别，以及是否处于“待正规化”状态。

### 4. `UnitNameWithWorld` 纳入 API Capability Registry

Character Scope 不再由 Storage 私自假定 API 可用。

新增：

- `X2Unit:UnitNameWithWorld`
- `OfficialEnabled`
- `SideEffectFree=true`

Storage 在调用前经过 Capability 静态 Gate；Getter 暂时返回空值时不把 Capability 永久判死。

### 5. Suite Stop / 热重载 Ready Gate 收口

`Runtime:Stop()` 现在无论是否已经进入 started 状态都会先清除 `S.Ready`。

ESC 内容回调同时要求：

- `S.Ready == true`
- `Runtime.started == true`

避免旧 Generation 的原生回调在 Suite 已停止 / 热重载后重新打开 UI。

### 6. Plates Disabled 真正释放高频 Handler

Audit3 已让 Plates 关闭时隐藏 HUD，但原生 Driver / Watchdog 仍保留 Lua Handler，只靠逻辑早退。

Audit4 改为：

- Disable 释放 Driver `OnEvent`；
- Disable 释放 Driver `OnUpdate`；
- Disable 释放 Watchdog `OnUpdate`；
- Enable 时重新安装 Handler；
- 保留 Domain / 配置，不重新创建业务状态。

这更符合架构定义的 `Disabled = 尽可能停止业务 Runtime`。

### 7. Healer Disabled 释放团队事件 Handler

`TEAM_MEMBERS_CHANGED` 私有 Event Host 仍保留事件注册作为宿主，但 Suite 模式下：

- Module Enable 才绑定 `OnEvent` Handler；
- Module Disable 立即释放 Handler；
- 独立模式继续保持原生命周期兼容。

关闭 Healer 后不再为团队事件进入 Lua 回调再早退。

### 8. Suite 模式不再创建废弃的 Healer 独立推荐排行 HUD

最终架构要求删除独立“哪些玩家需要治疗”排行榜 HUD。

Audit3 已把它隐藏，但窗口、行、Resize、滚轮和按钮仍在加载阶段完整创建。

Audit4 改为：

- `ReplicatedSuiteEmbedded == true` 时不创建该 HUD 对象；
- 不创建对应行 / Resize / Close / Scroll Handler；
- `LayoutRecommendPanel()` / `RefreshRecommendationPanel()` 在无对象时安全返回。

**没有删除推荐候选 / 排名 Domain。** 头顶标记与团队格高亮仍消费该结果，所以保留算法是有明确消费者的，不是重复 Authority。

### 9. 移除最后一个用户可见 `...` 状态文本

Gear 快捷换装按钮的 `名称...` 改为 `名称 切换`。

本轮重新扫描：

- `SetEllipsis(true)`：0；
- 独立 `"..."` 用户状态字符串：0。

## DataScope 当前边界

### 已真实分层

- Suite 角色域 Module Enabled；
- Team Utility 角色设置；
- Daily Tracking；
- Event Daily Done；
- Daily Resource Counters。

### 继续保留原 Domain 持久化

- Gear：已有自己的角色隔离逻辑；
- DPS：保留已验证统计 / 分片 / replay 持久化结构；
- Healer：保留历史规则 / 配置结构；
- Plates：保留历史配置结构。

原因：当前官方 `ADDON:LoadData(key)` 签名没有跨旧 Addon namespace 参数。未经 ArcheRage 实机确认前，强制改专业 Domain 键会有“旧配置 / 旧统计无法恢复”的实际风险。

## 静态与行为验收

- Suite Lua：107 个，语法失败 0；
- TOC：111 项，缺失 0；
- Professional Lua Sandbox Enter：41 / 41；
- 架构文档：与用户提供的 Final v1.1 原文件逐文件一致；
- `SetEllipsis(true)`：0；
- 用户状态字面量 `"..."`：0；
- `rs_combat_bridge`：0；
- 旧 `sightProcessJob`：0；
- Addon 顶级目录：`globals / replicatedsuite / z_api_functions`；
- Schema 18 -> 19 多角色迁移仿真：PASS；
- Character identity cold -> resolved 正规化仿真：PASS；
- 全 Suite Lua 解析：PASS。

## 实机必须重点验证

1. **角色 A / B 切换**：角色域模块开关、团队辅助、日常追踪和资源日计数不能串号；跑商、债券、活动等 Account 项应继续共享。
2. **冷启动身份**：登录后诊断的 Character 应最终从“未识别 / 待正规化”恢复为“已识别”。
3. **Plates 连续开关**：关闭后目标变化 / 施法 / OnUpdate 不应继续产生 Plates Runtime 活动；再次开启应完整恢复。
4. **Healer 连续开关**：关闭后团队变化不应触发 Healer 业务；再次开启后团队刷新、Buff、高亮、头标恢复。
5. **Healer UI**：Suite 中不应出现独立 Top3 / 推荐排行榜 HUD；团队高亮和头顶标记仍正常。
6. **DPS Team / Range**：继续确认不清空历史、Team 不广域扫描、非团队 Context 不进入正式排行。
7. **100 / 200 人长战斗**：记录 FPS、Backlog Health、事件追平时间和长期内存增长。
8. **1024x768 / 窄 HUD**：确认真实客户端字体度量下没有裁切、重叠、无意义省略。
9. **旧独立 Addon 数据**：确认合并后 `ADDON:LoadData(key)` 对旧 namespace 的真实行为，再决定是否进入专业 Domain 的下一阶段存储迁移。

## 本轮明确没有做的危险修改

- 没有重写 DPS 统计语义；
- 没有删除 Healer 候选 / 排名算法，因为仍有头标与团队高亮消费者；
- 没有把所有数据粗暴改成 Character Scope；
- 没有改专业 Domain 历史 SaveKey；
- 没有恢复任何旧独立 Addon Runtime；
- 没有为了“架构更漂亮”清空用户配置或统计。

---

下一步测试时，只安装本 Audit4 Suite 包；旧 `replicatedgear / replicatedplates / replicatedhealer / replicateddps` 目录必须不存在，否则会人为制造双 Runtime。
