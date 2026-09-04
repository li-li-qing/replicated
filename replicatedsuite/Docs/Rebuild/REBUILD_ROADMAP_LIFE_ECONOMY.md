# 重建路线表：生活/经济/工具域剩余能力 Backlog

**日期**：2026-09-02  
**性质**：框架缺口 backlog 文档，**只写文档不实现**。实现要等用户逐项批准。  
**数据来源**：`features/rs_feature_registry.lua` 的 `currentImplementation` / `remainingCapability` 字段 + `Docs/Rebuild/REBUILD_BLUEPRINT.md` 旧服务清单。

---

## V3 Feature ↔ 旧服务对应关系

本次 WU4 已从 `rs_feature_registry.lua` 物理删除 `legacyReference` 字段（19 处使用 + 1 处定义），对应关系迁移至此文档保留迁移历史。

| V3 Feature ID | 旧服务名 | 当前状态 |
|---|---|---|
| combat_stats | Replicated DPS | migrated_m16 |
| combat_healer | Replicated Healer | migrated_m16_18 |
| combat_death_review | DamageReviewService | migrated_m15_2 |
| combat_buff_display | Replicated Plates | migrated_m16_18 |
| combat_boss_alerts | AlertsService | migrated_partial |
| combat_target_monitor | TargetService | migrated_m16_18 |
| combat_unit_lines | Replicated Plates lines | migrated_partial |
| combat_range_assist | Replicated Plates circle/magiccircle | migrated_partial |
| combat_team_tools | TeamUtilityService | migrated_partial |
| combat_gear | Replicated Gear | migrated_m4 |
| life_activities | EventService | migrated_m1 |
| life_trade | TradeService | migrated_partial |
| life_bonds | ResidentService | migrated_m16_18 |
| life_tasks | QuestService | migrated_m1 |
| life_treasure | TreasureService | migrated_m16_18 |
| life_fishing | FishingService | migrated_partial |
| tools_bag | BagOrganizerService | migrated_partial |
| tools_auction | AuctionFavoritesService | migrated_partial |
| tools_craft | CraftAssistService | migrated_partial |

---

## 12 域重建路线表

### 1. Trade（跑商）

| 维度 | 内容 |
|---|---|
| 旧实现要点 | TradeService：路线、多货物、实时货率、材料报价与利润计算 |
| V3 对应物 | `life_trade`（v3.life.trade），状态 `migrated_partial` |
| V3 已实现 | 路线/区域/服务器货率 + bounded 材料 itemType/数量投影；普通 Refresh 不调用拍卖报价；Trade 已提供 QuoteMaterial/QuotePendingMaterials 显式入口并通过共享 PriceQuoteQueueV3 异步限速报价；报价完成只重建受影响路线行的材料成本/利润（`.18.93`） |
| 剩余能力 | RU 实机核验报价返回/材料成本/利润一致性；current/full ratio 与 commerce skill mode；更完整详情/收藏体验 |
| 重建前置条件 | ① PriceQuoteQueueV3 限速队列 ✅ ② 报价失败 fail-closed ✅ ③ 用户显式触发（不自动 fan-out）✅ ④ Trade 报价快照→成本/利润重建 ✅ ⑤ RU 价格/地区 payload 验收待完成 |

### 2. Event（活动）

| 维度 | 内容 |
|---|---|
| 旧实现要点 | EventService：世界活动、区域阶段、任务/实例参与进度 |
| V3 对应物 | `life_activities`（v3.activity），状态 `migrated_m1` |
| V3 已实现 | X2Map:GetZoneStateInfoByZoneId + X2Quest active quest + X2BattleField instance getters；RU X2BattleField getters 2026-05-19 官方开放 |
| 剩余能力 | 无明确剩余（状态 migrated_m1，已完整迁移） |
| 重建前置条件 | 无。如需扩展，确认 RU 区域阶段 API 字段一致性 |

### 3. Resident（居民/债券）

| 维度 | 内容 |
|---|---|
| 旧实现要点 | ResidentService：每日居民板材料、完成状态与背包资源 |
| V3 对应物 | `life_bonds`（v3.life.bonds），状态 `migrated_m16_18` |
| V3 已实现 | V3 Bonds 解析 curated/verified 常量映射 + QuestProgressV3 状态投影 + bounded 资源诊断；unknown runtime fields fail-closed |
| 剩余能力 | 无明确剩余（状态 migrated_m16_18） |
| 重建前置条件 | 无。WU4 已清理 BondDateCache 死代码（S.State 已删除导致的不可达分支） |

### 4. Quest（任务追踪）

| 维度 | 内容 |
|---|---|
| 旧实现要点 | QuestService：用户选择的日常与周常任务追踪；子任务展开和独立悬浮追踪 |
| V3 对应物 | `life_tasks`（v3.tasks），状态 `migrated_m1` |
| V3 已实现 | V3 QuestProgressService 共享投影；X2Quest:GetActiveQuestListCount/Type + IsCompleted + IsReadyForCompleteQuest + GetQuestContextMainTitle |
| 剩余能力 | 无明确剩余（状态 migrated_m1，已完整迁移） |
| 重建前置条件 | 无 |

### 5. TeamUtility（团队管理）

| 维度 | 内容 |
|---|---|
| 旧实现要点 | TeamUtilityService：全队职责管理、成员移动 |
| V3 对应物 | `combat_team_tools`（v3.team_tools），状态 `migrated_partial` |
| V3 已实现 | TeamRoster 更新驱动的全队职责只读；X2Team:SetRole(role) 仅作为当前玩家职责写入 |
| 剩余能力 | MoveTeamMember/MoveTeamMemberToParty 需要允许使用的队长/权限 getter；当前 IsTeamOwner 明确 NotAllowed |
| 重建前置条件 | ① RU 实机验证 IsTeamOwner 返回值 ② 确认 MoveTeamMember 的 charId/partyIndex 参数形态 ③ 队长权限 fail-closed 策略 |

### 6. Treasure（寻宝）

| 维度 | 内容 |
|---|---|
| 旧实现要点 | TreasureService：藏宝图坐标、方向与距离 |
| V3 对应物 | `life_treasure`（v3.life.treasure），状态 `migrated_m16_18` |
| V3 已实现 | 有界背包藏宝图扫描 + 500ms Demand-scoped 玩家位置/方向/距离刷新；Consumer=0 立即停任务 |
| 剩余能力 | 无明确剩余（状态 migrated_m16_18） |
| 重建前置条件 | 无 |

### 7. BagOrganizer（整理背包）

| 维度 | 内容 |
|---|---|
| 旧实现要点 | BagOrganizerService：背包/仓库整理、黑名单与按类别批量移动 |
| V3 对应物 | `tools_bag`（v3.bag），状态 `migrated_partial` |
| V3 已实现 | category_batch + scheduler_queue + native_window_quick_take_put + blacklist_filter + read_verify_stop；Shared Scheduler 串行 bounded 移动；V3 Presenter 跟随背包显示"取/放/停" |
| 剩余能力 | RU visual anchoring 和 move timing 仍需 Fresh Reload 验证 |
| 重建前置条件 | ① RU 实机 Fresh Reload 验证窗口跟随锚定 ② 验证 250ms 串行移动时序 ③ 验证 storage close/change 停止逻辑 |

### 8. AuctionFavorites（拍卖收藏）

| 维度 | 内容 |
|---|---|
| 旧实现要点 | AuctionFavoritesService：拍卖关键词/收藏、当前挂单查询、分页 |
| V3 对应物 | `tools_auction`（v3.auction），状态 `migrated_partial` |
| V3 已实现 | 收藏增删/持久化/分页；AuctionQueryV3 串行拥有 AUCTION_ITEM_SEARCHED；使用已验证 9 参数搜索；Quote 走共享 PriceQuoteQueueV3 显式+异步限速报价（2026-09-02） |
| 剩余能力 | RU 搜索结果的全部字段/排序语义与更丰富筛选仍待实机验证；当前结果不能当成历史成交样本 |
| 重建前置条件 | ① RU 实机验证搜索结果字段 ② 验证排序语义 ③ 确认筛选参数扩展点 |

### 9. Fishing（钓鱼）

| 维度 | 内容 |
|---|---|
| 旧实现要点 | FishingService：目标鱼动作 Buff 识别与技能推荐；自动 R |
| V3 对应物 | `life_fishing`（v3.life.fishing），状态 `migrated_partial` |
| V3 已实现 | V3 页面 + Demand + TARGET_CHANGED/BUFF_UPDATE 驱动的 bounded 目标 Buff observation 与技能栏推荐；Auto-R 可回滚热键事务已迁入（2026-09-02） |
| 剩余能力 | RU 实机 Fresh Reload 验证写入回读 / Reload 恢复 / 原键还原；确认 GetOptionBinding 返回结构在 RU 一致（钓鱼不进入战斗，战斗保护为旁路兜底） |
| 重建前置条件 | ① 完整可回滚热键事务设计 ② R 键槽位快照/写入回读契约 ③ 异常恢复 + Reload 恢复 + 原键还原 ④ Fresh Reload 验证 |

### 10. DamageReview（死亡回顾）

| 维度 | 内容 |
|---|---|
| 旧实现要点 | DamageReviewService：死亡前时间线与历史 |
| V3 对应物 | `combat_death_review`（v3.death_review），状态 `migrated_m15_2` |
| V3 已实现 | 独立低开销死亡前时间线与历史 |
| 剩余能力 | 无明确剩余（状态 migrated_m15_2） |
| 重建前置条件 | 无 |

### 11. Character（角色信息）

| 维度 | 内容 |
|---|---|
| 旧实现要点 | CharacterService：角色身份、属性、装备摘要等信息聚合（REBUILD_BLUEPRINT.md:1015 列出） |
| V3 对应物 | **无独立 Feature**。feature_registry 中无 character 域条目。角色身份已由 `core/rs_api.lua` 的 Character Scope 持久化 + `UnitIdentityV3` 服务承载；角色属性/装备摘要分散在 combat_gear / combat_raid_readiness 等功能中 |
| V3 已实现 | Character Scope 持久化（Account + Character Override）已由 V3 Persistence 承载；UnitIdentityV3 提供 world-qualified 身份 |
| 剩余能力 | 如需独立"角色信息"页面（属性面板/装备摘要/身份诊断），需新建 Feature |
| 重建前置条件 | ① 确认是否需要独立角色信息页面（当前已被其他功能吸收） ② 如需新建，定义 Feature ID/route/category ③ 确认属性/装备 getter 的 RU 字段一致性 |

### 12. CraftAssist（制作台助手）

| 维度 | 内容 |
|---|---|
| 旧实现要点 | CraftAssistService：制作台上下文的材料、持有量与缺口辅助 |
| V3 对应物 | `tools_craft`（v3.craft），状态 `migrated_partial` |
| V3 已实现 | 用户从已核制作物目录选择，不输入 doodadId/craftType；bounded product/material、held/shortage 与 known-record graph；Native 材料不可读时可回退已核静态贸易配方 |
| 剩余能力 | 非贸易制作目录、制作台上下文事件以及报价快照接回材料成本投影仍待验证/实现 |
| 重建前置条件 | ① RU 实机验证制作台 doodadId/craftType 上下文 ② 非贸易制作目录扩展 ③ 独立限速市场报价队列（与 Trade 共享）✅ 已建 PriceQuoteQueueV3 |

---

## 优先级建议

基于"剩余能力"的阻塞程度和用户影响：

| 优先级 | 域 | 原因 |
|---|---|---|
| P1 | Fishing | Auto-R 已迁入可回滚热键事务（2026-09-02），剩余仅 RU 实机 Fresh Reload 验证 |
| P2 | BagOrganizer | RU Fresh Reload 验证是唯一阻塞，验证后可全量启用 |
| P2 | AuctionFavorites | RU 搜索结果字段验证是唯一阻塞 |
| P3 | Trade | 报价队列需要与 AuctionFavorites 共享设计，可一起做 |
| P3 | CraftAssist | 非贸易目录 + 报价队列，依赖 Trade 的报价设计 |
| P3 | TeamUtility | 需要 RU 实机验证 IsTeamOwner，低频需求 |
| P4 | Character | 需确认是否需要独立页面，当前已被其他功能吸收 |
| — | Event/Resident/Quest/Treasure/DamageReview | 已完整迁移，无剩余能力 |

---

## 共享前置条件

以下能力被多个域依赖，建议优先完成：

1. **AuctionQueryV3 限速报价队列**：~~Trade + CraftAssist + AuctionFavorites 都需要显式 `GetLowestPrice` 报价，当前都已移除自动 fan-out。~~ **已落地（2026-09-02）**：新建共享 `PriceQuoteQueueV3`（`services/rs_price_quote_queue_v3.lua`），提供显式+异步限速报价（`RequestQuote` 串行 + 560ms 间隔 + 异步回调 + requester 快照）。CraftAssist 新增 `QuoteMaterial` 命令、AuctionFavorites 的 `Quote` 命令改走共享服务，均不再直接调 `GetLowestPrice`。剩余：各 Feature 将异步报价快照接回材料成本/利润投影。
2. **RU Fresh Reload 验证基线**：BagOrganizer / Fishing / AuctionFavorites 都需要 RU 实机验证，建议建立统一的 Fresh Reload 验证 checklist。
3. **热键事务框架**：Fishing 的 Auto-R 需要完整可回滚热键事务。如果未来 hotkey_profiles 从 runtime_blocked 解除，也会复用这个框架。
