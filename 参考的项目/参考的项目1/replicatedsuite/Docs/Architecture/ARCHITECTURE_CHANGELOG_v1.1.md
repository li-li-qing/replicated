# Replicated Suite Architecture v1.1 Amendment

日期：2026-08-15

## DPS 数据范围模式

- 新增“团队模式 / 范围模式”。
- 团队模式正式统计 `SELF + TEAM`，非团队 Actor 仅作为必要 Context。
- 范围模式继续识别团队外友军、敌军、NPC、召唤物和 Unknown，TEAM 仍是强 Authority。
- 团队模式必须停止或显著收缩 100m 全范围扫描。
- 范围模式才启用完整 World Observation / Unknown Resolver。
- 两种模式共享 Event Fact、PVP/PVE、Stats Domain、Boss、Detail、人工纠错等同一业务管线。
- 切换模式不清空历史统计，不伪造切换前未采集的数据。
- 默认范围模式，以保持当前 Replicated DPS 的产品目标。
