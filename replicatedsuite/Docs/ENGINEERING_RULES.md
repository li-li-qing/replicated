# Replicated Suite 工程与文档规则

> **Authority Level**: CURRENT
> 本文定义两条硬规则：(A) 文档体系纪律；(B) 工程实现硬规则。新文档/新代码都必须遵守。

---

## A. 文档体系纪律（Documentation Policy）

### A.1 禁止继续制造散落文档

- **禁止**在 `Docs/`、`Docs/Architecture/`、`Docs/Rebuild/` 根层再新建 `M1_xx_*.md`、`REPLICATED_*.md`、`*_2026xxxx.md` 这类按日期/里程碑命名的孤立文档。
- 新的架构知识 **必须** 归并到对应的权威文档：
  - 通用底层 → `Architecture/CORE_ARCHITECTURE.md`
  - Native → `Architecture/NATIVE_ARCHITECTURE.md`
  - 服务 → `Architecture/SERVICE_ARCHITECTURE.md`
  - 持久化 → `Architecture/PERSISTENCE_ARCHITECTURE.md`
  - RSUI → `Architecture/RSUI_ARCHITECTURE.md`
  - Healer → `Architecture/HEALER_ARCHITECTURE.md`
  - Feature/专业模块 → `Architecture/FEATURE_ARCHITECTURE.md`
  - 静态 ID → `STATIC_DATA.md`
- 进度/决策更新 → **更新 [`CURRENT_REBUILD_STATUS.md`](CURRENT_REBUILD_STATUS.md) 与 [`CHANGELOG.md`](CHANGELOG.md)**，而不是新建一份里程碑文档。

### A.2 禁止重复副本

- 同一份内容 **不得** 同时存在于：项目根目录、`Docs/` 根层、`Docs/Architecture/` 根层 与 其子目录（`Core/`、`RSUI/`、`Healer/`、`Historical/`）。
- 100% 内容一致的文件只保留一个权威副本，其余 `SAFE_DELETE`。
- 如需历史快照，移入 `Archive/<日期>/` 或 `Archive/<类型>/`，并标注日期与来源。

### A.3 历史/审计/验证归档

- 一次性审计、Hotfix 复盘、Validation JSON、阶段性迁移记录：**完成即归档到 `Archive/`**，不作为当前架构入口。
- 历史文档若声明了已被推翻的架构规则，必须标记 `SUPERSEDED` 或删除，避免误导。

### A.4 不修改业务代码

- 本文档收口动作 **不触碰** 运行时 Lua（Core / Native / Services / Feature / UI runtime / Static ID runtime / Config / Persistence runtime / Addon 入口）。
- 仅允许修正文档之间的相对路径引用。

---

## B. 工程实现硬规则（Engineering Hard Rules）

> 提炼自 `CORE_ARCHITECTURE.md`（Engineering Skill / Foundation Decisions v2）。

1. **Authority 与 Presentation 永远分离**：业务结论不提升到公共 Core；UI 不自己决定功能归属（`ui/rs_ui_catalog.lua` 是唯一导航/Presentation Catalog）。
2. **Module Enabled ≠ HUD Visible ≠ Collapsed**：三者严格分离；禁用模块不清空业务配置与统计；关闭模块后仍可进设置。
3. **Quiet by Default**：新安装默认关闭专业模块；不偷偷出现旧 HUD/快捷按钮；默认不弹提示。
4. **200 玩家是正常容量**：共享 Observation + Domain Authority 分离；订阅驱动数据；Unknown Actor 不污染排行；非团队事件只作 Context Fact。
5. **Diagnostics 是 P0 基础设施**：高频问题必须限频；结构化事件；热路径只统计不日志。
6. **Native Identity 严格分离**：逻辑 ID → `S.PhysicalId()` 投影 → NativeObjectFactory 构造；物理 ID 不透明、不解析、不持久化；Parent Fence 必须在 C++ 构造前；`pcall` 只处理可恢复参数异常，不是架构补丁。
7. **静态 ID 命名空间分离**：`trade_craft.craftId` / `trade_good.productItemId` / `trade_material.compactId|itemId` / `instance.databaseZoneId|runtimeInstanceId` / `quest.id` 互不可替；**禁止用编号规律推测未核 ID**；新增未核 ID 触发 Foundation Gate 告警。
8. **Persistence 先定义生命周期再保存**：Permanent/Daily/Weekly/Session/Checkpoint 五类 Lifetime；Dirty+Debounce；Store 级 Write Fence；Daily/Weekly 不能只判断本地日期。
9. **UI Diff Rendering 是默认规则**；不再直接用 Native Geometry 堆业务页面；大量数据必须虚拟化（Row/Tile Pool）。
10. **禁止伪重构**：只拆文件、超级 Core、全局可写 State 都不允许。
11. **API 治理**：以 `core/rs_api_capabilities.lua` 为静态基线；Official/Static/Runtime 状态分离；不因旧版本曾开放而假设当前可用。
12. **故障隔离**：单个模块异常不拖垮 Suite；危险操作二次确认；一键诊断摘要可用。
13. **Foundation Regression Gate 是封包必跑项**：在交付任何 Active V3 Lua 变更前执行 `python3 replicatedsuite/tools/rs_foundation_audit.py`；Unexpected global、Presentation→Native/私有状态越界、Raw Native constructor、非法 raw BuildScope、Active/All Lua Parse 任一失败都不得封包。Page/Widget/Modal 新代码必须优先使用 `RSUI:WithBuildScope()`，不得复制裸 Begin/End 事务模板。

