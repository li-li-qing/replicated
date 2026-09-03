# Replicated Suite Architecture Final v1

本资料包是 2026-08-15 经过多轮需求确认后的正式产品/架构基线。

包含：

1. `Replicated_Suite_Product_Architecture_v1.md`
   - 单一 Suite 产品形态
   - Module Manager
   - Authority
   - 首页/导航
   - 功能方案
   - 多角色
   - 诊断、更新、危险操作、迁移等

2. `Replicated_Suite_UI_HUD_Spec_v1.md`
   - HUD 关闭/缩小
   - 自由 Resize
   - 字体/透明度
   - 标题栏
   - 编辑模式
   - 吸附
   - 布局方案
   - 文字 `...` / 长文本硬性验收规则

3. `Replicated_Suite_Runtime_Data_API_v1.md`
   - 200 人正常负载
   - Observation Service
   - Event Fact / Unknown Actor
   - DPS Accuracy
   - Backlog / TTL / Event 分层方向
   - API Capability Registry
   - 技术侧待验证问题

4. `replicated-suite-engineering/`
   - 可跨新页面复用的 Skill
   - `SKILL.md`
   - `references/` 内包含上述三份规范的副本

后续新页面推荐携带：
- 最新完整 Addon ZIP
- 最新 z_api_functions / 官方 API 包（API相关工作时）
- `replicated-suite-engineering` Skill

注意：
- 产品/UI 规则已作为正式基线。
- Unknown 身份证据、具体 API 可用状态、TTL、Dedup 阈值等仍属于“必须验证后落地”的技术项。

## v1.1 补充：DPS 数据范围模式（2026-08-15）

新增正式规则：

- DPS 提供 `团队模式 / 范围模式`
- 团队模式正式统计 `SELF + TEAM`
- 非团队单位在团队模式下仍可作为 Context 用于 PVP/PVE、Boss、承伤来源和目标明细
- 范围模式继续尝试识别团队外友军、敌军、NPC、召唤物和 Unknown
- 范围模式仍把 TEAM 作为强 Authority
- 两种模式共享同一 Event / Domain Pipeline
- 团队模式关闭或显著收缩完整范围扫描
- 模式切换不自动清空统计
- 默认保持范围模式，以兼容当前“统计所有可见单位”的产品目标
