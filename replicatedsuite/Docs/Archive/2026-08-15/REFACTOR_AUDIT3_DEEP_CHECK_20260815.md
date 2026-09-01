# Replicated Suite Architecture v1.1 — Audit 3 深度检查报告

版本：`1.0.2-architecture-v1.1-audit3`  
日期：2026-08-15  
作者：Replicated

## 结论

本轮不是重复语法检查，而是对一次性合并后的 Authority、生命周期、HUD 持久化、故障补偿、DPS Scope、API Capability、热重载和高频 Runtime 做第二轮行为级审计。确认的问题已直接修入最终工作树。

## 本轮确认并修复

1. **Healer 嵌入预启动**：历史 `state.enabled=true` 不再在 ModuleManager 裁决前触发团队/Buff/推荐扫描；私有 `TEAM_MEMBERS_CHANGED` 在模块关闭时硬返回。
2. **Module 生命周期补偿**：Enable/Disable 中途失败会撤销事件、Scheduler Owner、Observation 订阅，并保持中央 Authority 与真实 Runtime 一致。
3. **设置窗口非生命周期故障**：打开设置失败只记录 UI 警告，不再把正在运行的模块误标为 Faulted。
4. **内置 Service 假状态**：`Start()` 返回 false、`Stop()` 异常/false 都不再被吞掉；清理先执行，再向 ModuleManager 上报。
5. **DPS 半启动幽灵 Runtime**：`Stop()` 现在无条件执行 `AbortStart()`，Start 在最终 `started=true` 前异常也能释放已注册 Event/OnUpdate。
6. **Runtime Fault 隔离**：新增 `ModuleManager:ReportRuntimeFault()`；Healer/Plates 连续 OnUpdate 真异常达到阈值后停止本模块 Runtime、保留用户持久化 ON 意图并允许模块页显式重试。
7. **HUD 专业模块 Authority**：DPS/Gear/Plates 的可见、锁定、方案捕获/应用纳入 Suite HUD Manager；Plates 目标/自己 HUD 进入中央 HUD 管理。
8. **HUD 重登恢复**：State 会物化并恢复晚注册的专业 HUD placement，不再只恢复内置默认 HUD。
9. **首次合并 DPS HUD 偏好**：没有 Suite HUD 存档时，从旧 DPS Domain 接收友/敌排行显示与锁定初值；已有 Suite 存档仍由 Suite 覆盖。
10. **HUD Profile 引用破坏**：应用方案改为原表就地覆盖，不替换已被窗口持有的 placement 对象。
11. **HUD Profile 默认值恢复**：Profile v2 增加显式 clear 元数据，可恢复 `nil` 表示的默认尺寸、继承字体、继承背景、compact/customTitle 等；旧 Profile 保持兼容。
12. **Profile 管理**：功能方案、HUD 方案、组合方案均补齐选择/保存/应用/删除；组合应用在功能方案失败时不会继续套 HUD。
13. **更新提示死链**：首页“查看变化”现在可点击；只有明确点击后才标记已读，切页面不再偷偷消失。
14. **设置搜索粒度**：专业模块注册具体设置关键词并跳到对应设置页/窗口。
15. **禁用模块设置语义**：四专业设置页明确显示“当前模块未启用”；Runtime-only 操作被禁用/拒绝，静态设置仍可编辑。
16. **DPS Enable 双 Authority**：专业设置中的启用按钮委托 Suite ModuleManager，不再直接自启动 Runtime。
17. **DPS Nearby API 过期 Gate**：`X2Unit:GetUnitsInSight` 按当前 20260815 API 基线统一为官方开放；Nearby 不再错误依赖 `diagnosticsEnabled`。
18. **DPS Team Scope 残留任务**：实际任务字段为 `sightTask`；范围→团队会立即取消正在分帧处理的广域视野快照，并在 `StepSightTask` 内二次硬门。
19. **DPS Scope 语义**：Team 只提升 SELF/TEAM 为正式排行 Actor；非团队 Event Fact/目标/承伤关系保留 Context，不复制第二套 DPS Pipeline，也不切换时清空历史。
20. **Scheduler 优先级/积压**：公共 Scheduler 支持 P0-P5、同帧预算、Backlog Health、3 次失败隔离；不会一帧补跑多次低优先级任务。
21. **Sandbox 热重载代际**：Suite Generation 变化时撤销上一代显式 Export、创建新专业环境，避免删除过的全局符号或旧 Export 残留。
22. **Observation 基础读取共享**：短 TTL 共享 Name/ID/HP/Distance 等基础 Fact；业务分类、治疗优先级、Buff 决策仍由各 Domain Authority 持有。
23. **公共发布白名单**：最终 Addon 仅允许 `globals / replicatedsuite / z_api_functions`，代码中无私人模块路径。

## 行为级测试

- Module Enable 故障补偿：PASS
- Module Disable 故障保持 OFF Authority：PASS
- 设置 UI 故障不改变 Runtime Authority：PASS
- Runtime Fault 保留用户 ON 意图并可 Retry：PASS
- Built-in Service Start/Stop 故障传播：PASS
- Scheduler P0 优先 / backlog / RemoveOwner / 3 次故障隔离：PASS
- HUD Profile 原对象引用保持 + 默认值显式恢复：PASS
- 专业 HUD 晚注册后重登恢复：PASS
- HUD 注册 DefaultVisible / DefaultLocked 迁移：PASS

## 最终静态验收

- Suite Lua：107 个，语法失败 0
- TOC：111 项，缺失 0
- Professional Lua Sandbox Enter：41 / 41
- 官方 API 索引：348 个方法
- 直接官方调用：124 处 / 26 个唯一方法 / 未登记 0
- Professional API Facade：24 个唯一方法 / 未登记 0
- 代码 `SetEllipsis(true)`：0
- 代码 `rs_combat_bridge`：0
- 代码旧 `sightProcessJob`：0
- 代码私人路径 token：0
- Addon 顶级目录：`globals / replicatedsuite / z_api_functions`

## 必须留到 ArcheRage 实机验证的边界

这些不是静态代码可以证明的项目，因此没有伪造“已验证”：

1. 旧四独立 Addon 的 `ADDON:LoadData(key)` 是否能在合并后的 Suite 命名空间直接读到历史数据；当前官方签名没有跨 Addon namespace 参数。
2. `GetUnitsInSight` 在 RU 当前客户端的实际返回表形状；代码继续保守解析，未知字段不作为玩家/NPC硬 Authority。
3. 真实 100/200 人战斗下 FPS、事件追平时间、Backlog Health 与长期内存增长。
4. 游戏 UI 字体真实度量下 1024x768 / 极窄 HUD 是否还有客户端特有裁切。
5. Account 默认 + Character Override 的通用存储层仍不对历史专业 Domain 强制改键；各 Module 已声明 DataScope，Gear 已使用 `UnitNameWithWorld` 做角色隔离。对 Healer/DPS 等历史键的通用 Character Override 应在确认客户端持久化作用域后迁移，避免一次性改键造成旧配置/统计不可恢复。

## 测试原则

最终开始实机时，只安装这个 Suite 包；旧 `replicatedgear / replicatedplates / replicatedhealer / replicateddps` 目录必须不存在，否则会人为制造双 Runtime。
