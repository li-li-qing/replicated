------------------------------------------------------------------------
-- Replicated Suite V3 - Feature Registry
--
-- This is presentation/domain metadata only. It does not start legacy modules,
-- touch Native UI, or read game APIs. New V3 Features register here first so
-- navigation, diagnostics and lifecycle status share one semantic catalog.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite

S.FeatureRegistry = {
    version = 3,
    features = {},
    order = {},
    categories = {
        home = { id = "home", name = "首页", order = 10 },
        combat = { id = "combat", name = "战斗", order = 20 },
        life = { id = "life", name = "生活", order = 30 },
        tools = { id = "tools", name = "工具", order = 40 },
        system = { id = "system", name = "系统", order = 50 },
    },
}
local R = S.FeatureRegistry

local function NormalizeId(value)
    local id = tostring(value or ""):lower():gsub("[^%w_%.%-]", "_"):gsub("_+", "_")
    return id:gsub("^_+", ""):gsub("_+$", "")
end


function R:Resort()
    table.sort(self.order, function(a, b)
        local left, right = self.features[a], self.features[b]
        local lc, rc = self.categories[left.category], self.categories[right.category]
        if lc.order ~= rc.order then return lc.order < rc.order end
        if left.groupOrder ~= right.groupOrder then return left.groupOrder < right.groupOrder end
        if left.groupItemOrder ~= right.groupItemOrder then return left.groupItemOrder < right.groupItemOrder end
        if left.order ~= right.order then return left.order < right.order end
        return left.id < right.id
    end)
    return true
end

function R:Register(spec)
    spec = type(spec) == "table" and spec or {}
    local id = NormalizeId(spec.id)
    if id == "" then return nil, "feature id required" end
    if self.features[id] ~= nil then return nil, "duplicate feature: " .. id end
    local category = NormalizeId(spec.category)
    if self.categories[category] == nil then return nil, "unknown feature category: " .. category end
    local route = tostring(spec.route or id)
    local row = {
        id = id,
        route = route,
        name = tostring(spec.name or id),
        shortName = tostring(spec.shortName or spec.name or id),
        category = category,
        order = tonumber(spec.order) or 100,
        group = tostring(spec.group or category),
        groupOrder = tonumber(spec.groupOrder) or 100,
        groupItemOrder = tonumber(spec.groupItemOrder) or tonumber(spec.order) or 100,
        navigationVisible = spec.navigationVisible ~= false,
        description = tostring(spec.description or ""),
        status = tostring(spec.status or "planned"),
        lifecycle = tostring(spec.lifecycle or "independent"),
        authority = tostring(spec.authority or "pending"),
        widgetCapable = spec.widgetCapable == true,
        settingsCapable = spec.settingsCapable == true,
        apiDependencies = type(spec.apiDependencies) == "table" and spec.apiDependencies or {},
        apiReadiness = tostring(spec.apiReadiness or "unknown"),
        verification = tostring(spec.verification or "pending_runtime_verification"),
        apiPolicy = tostring(spec.apiPolicy or "none"),
        evidence = tostring(spec.evidence or ""),
        scheduler = tostring(spec.scheduler or ""),
        window = tostring(spec.window or ""),
        blacklist = tostring(spec.blacklist or ""),
        capabilities = type(spec.capabilities) == "table" and spec.capabilities or {},
        defaultEnabled = spec.defaultEnabled == true,
        runtimeBlocked = spec.runtimeBlocked == true,
        runtimeBlocker = tostring(spec.runtimeBlocker or ""),
        currentImplementation = tostring(spec.currentImplementation or ""),
        remainingCapability = tostring(spec.remainingCapability or ""),
    }
    self.features[id] = row
    self.order[#self.order + 1] = id
    self:Resort()
    return row
end

function R:Get(id)
    return self.features[NormalizeId(id)]
end

function R:GetByRoute(route)
    route = tostring(route or "")
    for _, id in ipairs(self.order) do
        local row = self.features[id]
        if row.route == route then return row end
    end
    return nil
end

function R:List(category)
    category = category ~= nil and NormalizeId(category) or nil
    local rows = {}
    for _, id in ipairs(self.order) do
        local row = self.features[id]
        if category == nil or row.category == category then rows[#rows + 1] = row end
    end
    return rows
end

function R:Describe()
    local status = {}
    for _, id in ipairs(self.order) do
        local key = tostring(self.features[id].status or "unknown")
        status[key] = (tonumber(status[key]) or 0) + 1
    end
    return { version = self.version, total = #self.order, status = status }
end

local function Add(id, route, name, category, order, description, options)
    options = type(options) == "table" and options or {}
    options.id, options.route, options.name, options.category, options.order = id, route, name, category, order
    options.description = description
    local row, err = R:Register(options)
    if row == nil then error(err) end
end

Add("home", "home", "今日总览", "home", 10,
    "新的综合辅助工作台。这里只读取各功能已经整理好的显示数据，不重复进行业务计算。",
    { status = "foundation", lifecycle = "shell", authority = "projection" })

Add("combat_stats", "combat.stats", "伤害统计", "combat", 10, "逐事件 PVP/PVE 分类的伤害、承伤与治疗统计；M1.16 起通过 CombatAnalytics 共享唯一 scope=all 战斗事实流。", {
    status = "migrated_m16", lifecycle = "independent", authority = "v3.dps + v3.combat_analytics",
    widgetCapable = true, settingsCapable = true,
})
Add("combat_analytics", "combat.analytics", "战斗分析", "combat", 15, "模块化战斗贡献分析：战斗历史、击杀/助攻、技能、爆发、控制、乐器、辅助、Aura 与 Boss 机制；每个指标独立启停并共享单一 CombatEventBus 消费者。", {
    status = "migrated_m16_foundation", lifecycle = "independent_metrics", authority = "v3.combat_analytics",
    widgetCapable = false, settingsCapable = true, defaultEnabled = false,
})
Add("combat_healer", "combat.healer", "治疗辅助", "combat", 20, "治疗推荐核心与团队校准/屏幕色块：共享团队名单与 Aura 事实；不再提供无意义的推荐列表悬浮窗，校准可在治疗计算关闭时独立显示。", {
    status = "migrated_m16_18", lifecycle = "independent", authority = "v3.healer + v3.team_roster + v3.aura_observation",
    widgetCapable = false, settingsCapable = true, defaultEnabled = false,
    apiDependencies = { "X2Team:GetRole", "X2Unit:UnitHealth", "X2Unit:UnitMaxHealth", "X2Unit:UnitDistance", "X2Unit:UnitBuffCount", "X2Unit:UnitBuff", "X2Unit:UnitDeBuffCount", "X2Unit:UnitDeBuff", "X2Unit:UnitHiddenBuffCount", "X2Unit:UnitHiddenBuff", "X2Unit:GetUnitScreenPosition" },
    apiReadiness = "partial", apiPolicy = "read_only_sliced", currentImplementation = "页面策略配置 + 头顶标记 + 团队覆盖层；Raid calibration 是独立 Presentation 模式，不获取治疗 Consumer", remainingCapability = "继续按实机校准团队框位置/颜色，不恢复推荐列表悬浮窗", evidence = "V3 Healer Domain + HeadMarker/RaidOverlay; TeamRosterV3 + AuraObservationV3 shared facts",
})
Add("combat_death_review", "combat.death_review", "死亡回顾", "combat", 30, "独立低开销死亡前时间线与历史。", {
    status = "migrated_m15_2", lifecycle = "independent", authority = "v3.death_review",
    widgetCapable = true, settingsCapable = true,
})
Add("combat_buff_display", "combat.buff_display", "状态显示", "combat", 40, "首个 Plates/BUFF V3 消费端：player/target 的增益、减益与隐藏状态 bounded display；事实只来自共享 StatusMap。", {
    status = "migrated_m16_18", lifecycle = "demand_scoped", authority = "v3.buff_display + v3.aura_observation",
    widgetCapable = true, settingsCapable = true, defaultEnabled = false,
    apiDependencies = { "X2Unit:UnitBuffCount", "X2Unit:UnitBuff", "X2Unit:UnitBuffTooltip", "X2Unit:UnitDeBuffCount", "X2Unit:UnitDeBuff", "X2Unit:UnitDeBuffTooltip", "X2Unit:UnitHiddenBuffCount", "X2Unit:UnitHiddenBuff", "X2Unit:UnitHiddenBuffTooltip" },
    apiReadiness = "shared_service_partial", apiPolicy = "read_only_bounded",
    evidence = "AuraObservationV3:GetStatusMap(); V3 Page/Widget projection and lifecycle contract",
})
Add("combat_boss_alerts", "combat.boss_alerts", "首领机制 / 战斗警报", "combat", 50, "首领机制静态规则目录 + 可配置/可测试屏幕 HUD；实时施法/Aura 触发仍待验证事实桥。", { status = "migrated_partial", lifecycle = "demand_scoped", authority = "v3.boss_alerts + alerts_service", widgetCapable = false, settingsCapable = true, apiReadiness = "static_plus_presenter", apiPolicy = "read_only_push_hud", currentImplementation = "按真实 alert/kind/names/debuffId/style 字段投影机制；HUD 支持中央/顶部、字号、时长以及大字/倒计时测试", remainingCapability = "需要已验证的施法/Aura 事件事实把静态规则接到实时触发；不使用 CHAT_MESSAGE 猜机制", evidence = "V3 static BossAlerts + AlertsService push presenter; CHAT_MESSAGE false-positive matcher removed" })
Add("combat_target_monitor", "combat.target_monitor", "目标监控", "combat", 60, "按需追踪当前目标身份、名称与距离；不伪造仇恨目标。", { navigationVisible = false, status = "migrated_m16_18", lifecycle = "demand_scoped", authority = "v3.target_monitor", widgetCapable = true, apiDependencies = { "X2Unit:GetTargetUnitId", "X2Unit:UnitName", "X2Unit:UnitDistance" }, apiReadiness = "partial", apiPolicy = "on_demand_read_only", currentImplementation = "TARGET_CHANGED 即时刷新 + 500ms Demand-scoped 距离采样；Consumer=0 时任务和事件全部释放", remainingCapability = "仇恨目标需要独立、已验证的 RU 事实来源后再接入", evidence = "V3 target observation contract v1; event edge + bounded Scheduler distance refresh" })
Add("combat_unit_lines", "combat.unit_lines", "单位连线", "combat", 70, "当前实现为自己 ↔ 当前目标的独立屏幕连线；不恢复官方禁用的附近单位枚举。", { status = "migrated_partial", lifecycle = "demand_scoped", authority = "v3.unit_lines + screen_projection_v3", currentImplementation = "1-1000ms Demand-scoped 四类 token 连线 + 屏幕空间自适应密度/可见段裁剪/帧压力额外点预算 + P1 连续视觉刷新 + Presenter 本地 Diff/渐进点池；旧 pointCount 作为基础密度兼容保留；每线大小/颜色独立设置", remainingCapability = "全单位关系网络仍需要官方允许的单位集合来源；GetUnitsInSight 保持禁用", widgetCapable = false, settingsCapable = true, apiDependencies = { "X2Unit:GetUnitScreenPosition", "X2Unit:GetUnitWorldPositionByTarget" }, apiReadiness = "partial", apiPolicy = "bounded_current_target_only" })
Add("combat_range_assist", "combat.range_assist", "范围辅助", "combat", 80, "以玩家为圆心绘制用户指定半径的范围圆；不猜技能/魔法阵真实范围。", { status = "migrated_partial", lifecycle = "demand_scoped", authority = "v3.range_assist + screen_projection_v3", currentImplementation = "50ms Demand-scoped EasyPull 本地世界坐标 + Native→WorldToScreen Camera fallback + 玩家屏幕锚点整批刚性校准 + 12-48 个有界投影点；支持半径/点数/点大小/透明度/颜色并持久化", remainingCapability = "技能/魔法阵自动半径需要独立已验证的技能范围事实；当前只承诺用户自定义半径", widgetCapable = false, settingsCapable = true, apiDependencies = { "X2Unit:GetUnitWorldPositionByTarget", "X2Unit:GetUnitScreenPosition" }, apiReadiness = "partial", apiPolicy = "bounded_user_radius" })
Add("combat_buff_cap", "combat.buff_cap", "增益容量监控", "combat", 85, "读取自身普通/隐藏增益数量；RU 容量与顶替阈值未验证前不生成风险告警。", {
    status = "migrated_partial", lifecycle = "demand_scoped", authority = "v3.buff_cap", widgetCapable = true, settingsCapable = true,
    apiDependencies = { "X2Unit:UnitBuffCount", "X2Unit:UnitHiddenBuffCount" }, apiReadiness = "partial", apiPolicy = "read_only",
    currentImplementation = "Demand-scoped BUFF_UPDATE/TARGET_CHANGED 事件边 + 120ms one-shot 合并刷新，并保留低频兜底；Consumer=0 时不保留事件或任务；不推断容量阈值", remainingCapability = "需要 RU Buff 容量、顶替顺序与预警阈值的实机证据后才能恢复风险提示",
    evidence = "Bundled X2Unit buff-count getters; no verified RU eviction threshold",
})
Add("combat_team_tools", "combat.team_tools", "团队中心", "combat", 90, "全队职责只读与当前玩家职责设置；可选牺牲之舞头顶高亮与团队头标方案保存/串行恢复；成员移动在无法合法证明队长权限时安全停用。", { status = "migrated_partial", lifecycle = "explicit_action", authority = "v3.team_tools + v3.team_visuals", settingsCapable = true, apiDependencies = { "X2Team:GetRole", "X2Team:SetRole", "X2Unit:GetTargetAbilityTemplates", "X2Unit:UnitBuffCount", "X2Unit:UnitBuff", "X2Unit:GetOverHeadMarker", "X2Unit:SetOverHeadMarker" }, apiReadiness = "official_mixed", verification = "static_signature_verified_pending_ru_runtime", apiPolicy = "explicit_write_plus_bounded_shared_aura", currentImplementation = "TeamRoster 更新驱动的全队职责只读；X2Team:SetRole(role) 仅作为当前玩家职责写入；.18.122 增加按需牺牲之舞高亮（候选职业 10s/名单边发现、AuraObservationV3 共享 Buff 事实、仅激活时 50ms Presentation 投影）以及当前头标快照保存/按 1100ms 队列恢复并逐项 GetOverHeadMarker 读回验证；不会自动清除或覆盖未保存头标。成员移动按钮仍不可执行", remainingCapability = "MoveTeamMember/MoveTeamMemberToParty 仍需要允许使用的队长/权限 getter；当前 IsTeamOwner 明确 NotAllowed。牺牲之舞 Buff/屏幕位置与头标写入仍需 RU Fresh Reload 视觉/权限验证", evidence = "Bundled TMROLE_* + X2Team signatures; current RU capability list enables X2Unit Get/SetOverHeadMarker; user-provided legacy TeamUtility/ShinySac supplies Spelldance index 14 and Sac Buff IDs 30098/30137/30141/30142; shared TeamRosterV3/AuraObservationV3/ScreenProjectionV3 own reads" })
Add("combat_raid_readiness", "combat.raid_readiness", "团队战备检查", "combat", 92, "按需检查团队职责、关键增益、装分与职业准备状态，不依赖 DPS 常驻运行。", {
    navigationVisible = false,
    status = "migrated_m16_14", lifecycle = "on_demand_scan", authority = "v3.raid_readiness + v3.team_roster + v3.aura_observation",
    widgetCapable = false, settingsCapable = true, defaultEnabled = false,
    apiDependencies = { "X2Team:GetRole", "X2Unit:UnitGearScore", "X2Unit:UnitDistance", "X2Unit:UnitBuffCount", "X2Unit:UnitBuff", "X2Unit:UnitHiddenBuffCount", "X2Unit:UnitHiddenBuff" },
    apiReadiness = "partial", apiPolicy = "read_only_on_demand",
    evidence = "V3 TeamRoster + AuraObservation Phase 12B; TEAM interface id 38 from bundled apitypes and GetRole capability registry",
})
Add("combat_raid_recruitment", "combat.raid_recruitment", "团队招募助手", "combat", 94, "按需读取招募申请并允许关闭招募；创建、接受、拒绝在参数形态未验证前安全停用。", {
    navigationVisible = false,
    status = "migrated_partial", lifecycle = "explicit_action", authority = "v3.raid_recruitment", settingsCapable = true,
    apiDependencies = { "X2Team:RaidRecruitDel", "X2Team:RaidApplicantList" }, apiReadiness = "partial", apiPolicy = "verified_subset_only",
    currentImplementation = "读取 RaidApplicantList；Close 走 RaidRecruitDel；Create/Accept/Reject fail-closed",
    remainingCapability = "RaidRecruitAdd 9 字段语义与 RaidApplicantAccept/Reject(charIds) 的 charIds 形态需 RU 实机验证",
    evidence = "Bundled X2Team signatures; only verified subset is exposed as executable",
})
Add("combat_siege_readiness", "combat.siege_readiness", "攻城战备检查", "combat", 96, "攻城场景专用的装备与团队准备检查，关闭后不保留高频观察。", {
    navigationVisible = false,
    status = "runtime_blocked", runtimeBlocked = true, runtimeBlocker = "GetEquippedItemTooltipInfo 的装备字段结构与攻城场景判定 API 未在当前 RU 客户端验证", currentImplementation = "V3 页面显示精确阻塞，不对装备文本做猜测解析", remainingCapability = "需要稳定的 itemType/slot/装分返回字段和 siege context", lifecycle = "independent", authority = "v3.siege_readiness", widgetCapable = true,
    apiDependencies = { "X2Equipment:GetEquippedItemTooltipInfo", "X2Team:GetRole" }, apiReadiness = "research", apiPolicy = "read_only",
    evidence = "ArcheRage community Raidcheckersiege; exact remote equipment coverage requires RU runtime verification",
})
Add("combat_gear", "combat.gear", "换装 / 称号", "combat", 100,
    "装备、武器、防具、饰品与效果称号使用同一套方案保存和一键切换；每套常用方案可生成一个独立可拖动的屏幕按钮。", {
    status = "migrated_m4", lifecycle = "independent", authority = "v3.gear",
    widgetCapable = true, settingsCapable = true, defaultEnabled = true,
    apiDependencies = {
        "X2Equipment:GetEquippedItemTooltipInfo", "X2Bag:GetBagItemInfo", "X2Bag:Capacity", "X2Bag:EquipBagItem",
        "X2Player:GetShowingAppellation", "X2Player:GetEffectAppellation",
        "X2Player:PlayerInCombat", "X2Player:ChangeAppellation",
    },
    apiReadiness = "official_mixed", apiPolicy = "explicit_user_read_write",
    currentImplementation = "GearV3 v3 使用 bagId=1 作为换装物理槽权威并以 Capacity 有界扫描；战斗中仅执行 16/17/18/19 武器优先事务，防具/饰品/称号延后；脱战再次执行补齐",
    evidence = "V3 GearService + RU gearswap/Replicated Gear 已验证的 bagId=1 / EquipBagItem / title 行为；写入继续 fail-closed",
})

Add("life_activities", "life.activities", "活动", "life", 10, "世界活动、区域阶段、任务/实例参与进度。", {
    status = "migrated_m1", lifecycle = "independent", authority = "v3.activity",
    widgetCapable = true, settingsCapable = true,
    apiDependencies = {
        "X2Map:GetZoneStateInfoByZoneId",
        "X2Quest:GetActiveQuestListCount", "X2Quest:GetActiveQuestType", "X2Quest:IsCompleted", "X2Quest:IsReadyForCompleteQuest",
        "X2BattleField:GetInstanceUiKindList", "X2BattleField:GetInstanceListByKind", "X2BattleField:GetDetailInstanceInfo", "X2BattleField:GetInstanceName",
    },
    apiReadiness = "read_only_mixed", apiPolicy = "on_demand_read_only",
    evidence = "V3 Activity Authority + shared QuestProgressV3; RU X2BattleField getters officially enabled 2026-05-19",
    defaultEnabled = true,
})
Add("life_trade", "life.trade", "跑商", "life", 20, "路线、多货物与实时货率；材料身份/数量可读，材料报价与利润改为独立显式询价后再接回。", {
    status = "migrated_partial", lifecycle = "demand_scoped", authority = "v3.life.trade", widgetCapable = true, settingsCapable = true,
    apiDependencies = { "X2Store:GetProductionZoneGroups", "X2Store:GetSellableZoneGroups", "X2Store:GetSpecialtyRatioBetween", "X2Ability:GetAllMyActabilityInfos" },
    apiReadiness = "official_mixed", apiPolicy = "on_demand_server_query", currentImplementation = "路线/区域/服务器实时货率 + 满货率 130% 本地对比模式（持久化）+ 经商熟练度读取并按已提供旧版工作公式计入预计售价；TradePayoutV3 统一组合静态底价、实时/130% 货率、经商倍率与 TradeNameMultipliers 品类倍率，并恢复 larder/别名价格 Key 解析。路线收藏最多 12 条并由 life.trade 单 Store 持久化，主页面与 life.trade HUD 共用收藏/排序命令；选中贸易品复用 TradeDetailFloatingV3，详情仅在可见期持有独立 Consumer，并通过 QuoteRowMaterials 显式询价当前材料。普通 Refresh 不产生 Auction fan-out。", remainingCapability = "GetLowestPrice 返回形态、RU 生产/可售地区 payload 与静态底价长期一致性仍需实机验证；新增售价拆解需用多路线/多熟练度实售样本继续校准；自动制作台刷新/叛乱记录仍缺安全事件证据", evidence = "V3 Trade Authority + SPECIALTY_RATIO_BETWEEN_INFO + official X2Ability actability list + supplied working Trade payout formula; TradePayoutV3 price-key/larder/category multiplier contracts; bounded favorites + shared TradeDetailFloatingV3 + explicit selected-row material quote",
})
Add("life_bonds", "life.bonds", "债券 / 居民板", "life", 30, "每日居民板材料、完成状态与背包资源。", {
    status = "migrated_m16_18", lifecycle = "demand_scoped", authority = "v3.life.bonds", widgetCapable = true, settingsCapable = true,
    apiDependencies = { "X2Resident:GetResidentBoardContent", "X2Bag:Capacity", "X2Bag:GetBagItemInfo", "X2Quest:IsCompleted", "X2Quest:IsReadyForCompleteQuest" }, apiReadiness = "official_mixed", apiPolicy = "on_demand_read_only",
    currentImplementation = "单次读取 1-7 居民板，兼容 contents/content/rows/items 与稀疏数字行；按 RU 已验证的 3+4=大陆、5/6=原大陆规则选择分类，并显式区分 unavailable/empty/ready",
    evidence = "V3 Bonds + RU residentboard GetResidentBoardContent(index).contents 行为；未知字段继续 fail-closed",
})
Add("life_tasks", "life.tasks", "任务追踪", "life", 40, "用户选择的日常与周常任务追踪；支持子任务展开和独立悬浮追踪。", {
    status = "migrated_m1", lifecycle = "independent", authority = "v3.tasks",
    widgetCapable = true, settingsCapable = true, defaultEnabled = true,
    apiDependencies = {
        "X2Quest:GetActiveQuestListCount", "X2Quest:GetActiveQuestType",
        "X2Quest:IsCompleted", "X2Quest:IsReadyForCompleteQuest", "X2Quest:GetQuestContextMainTitle",
    },
    apiReadiness = "read_only", apiPolicy = "on_demand_read_only",
    currentImplementation = "日常/周常独立选择、父任务逐项加入/取消追踪、仅追踪筛选与悬浮窗复用同一持久追踪集合；.18.119 将逐项操作直接显示为‘✓ 已追踪 / ＋ 可添加’，不再隐藏在选中后的按钮语义里",
    evidence = "V3 QuestProgressService shared projection; no legacy QuestService runtime dependency",
})
Add("life_treasure", "life.treasure", "寻宝", "life", 50, "藏宝图坐标、方向与距离。", {
    status = "migrated_m16_18", lifecycle = "demand_scoped", authority = "v3.life.treasure", widgetCapable = true, settingsCapable = true,
    apiDependencies = { "X2Bag:GetBagItemInfo", "X2Bag:Capacity", "X2Unit:GetUnitWorldPositionByTarget" }, apiReadiness = "official_mixed", apiPolicy = "on_demand_read_only",
    currentImplementation = "有界背包藏宝图扫描 + 500ms Demand-scoped 玩家位置/方向/距离刷新；Consumer=0 立即停任务",
    evidence = "V3 Treasure observation contract v1; bounded bag scan + Scheduler position projection; Legacy Resource/Treasure is not loaded",
})
Add("life_fishing", "life.fishing", "钓鱼", "life", 60, "目标鱼动作 Buff 识别与技能栏推荐；自动 R 热键写入保持 Runtime Blocked，直到 RU 实机完成完整回滚证据。", {
  status = "migrated_partial", lifecycle = "demand_scoped", authority = "v3.life.fishing", widgetCapable = true, settingsCapable = true,
  currentImplementation = "V3 页面、Demand、TARGET_CHANGED/BUFF_UPDATE 驱动的 bounded 目标 Buff observation 与技能栏推荐；不会读取、覆盖、删除或保存任何游戏快捷键",
  remainingCapability = "自动 R 仍缺少 verified GetOptionBinding 源槽位集合、明确空绑定语义、写入回读、Reload 恢复及逐写入点故障注入回滚证据；获得 RU Fresh Reload 证据前保持 Runtime Blocked",
  apiDependencies = { "X2Unit:UnitBuffCount", "X2Unit:UnitBuff" }, apiReadiness = "official_read_only", apiPolicy = "observation_only_hotkey_runtime_blocked",
  evidence = "Active V3 Fishing observation contract v1 + HotkeyContract v2 runtime-block fence; PRODUCT_COMPLETION_MATRIX locked rows remain SPECIFIC_RUNTIME_BLOCKED",
})
Add("life_craft_planner", "life.craft_planner", "制作规划", "life", 70, "多配方材料、持有量/缺口与已知记录制作链规划；市场成本必须走后续显式限速报价。", {
    status = "migrated_partial", lifecycle = "explicit_query", authority = "v3.craft_planner", widgetCapable = true, settingsCapable = true,
    apiDependencies = { "X2Craft:GetCraftBaseInfo", "X2Craft:GetCraftMaterialInfo", "X2Craft:GetCraftProductInfo", "X2Craft:GetCraftTypeByItemType", "X2Bag:Capacity", "X2Bag:GetBagItemInfo" },
    apiReadiness = "official_mixed_pending_runtime", verification = "local_contract_verified_pending_ru_runtime", apiPolicy = "on_demand_read_only",
    currentImplementation = "用户从 98 条已核制作物目录选择配方，内部解析 CraftID；bounded product/material rows、持有量/缺口与 known-record recursive graph；普通 Refresh 不发 Auction 查询；.18.121 新增 CraftPlanV3：最多 12 个稳定 recipeKey 的持久多配方计划，同配方合并数量，按 StaticDataV2 聚合材料/持有量/缺口；计划报价仍只通过用户显式 QuotePlanMaterials -> PriceQuoteQueueV3 批量限速，并分别给出总需求/当前缺口报价小计。",
    remainingCapability = "非跑商制作目录的用户级检索、RU 原生制作字段一致性，以及未知/歧义 recursive graph 节点的完整递归成本仍待完成",
    evidence = "CraftPlanContract v1 + governed StaticDataV2 recipe/material identities + shared PriceQuoteQueueV3; no Native recipe enumeration or implicit auction fan-out",
})
Add("life_housing", "life.housing", "住宅 / 税务", "life", 80, "住宅名称、类型、所有者与当前税务信息；仅在住宅上下文按需读取。", {
    status = "migrated_v3_read_only", lifecycle = "page_scoped", authority = "v3.housing", widgetCapable = false, settingsCapable = false,
    apiDependencies = { "X2House:GetCurrentHousingTaxInfo", "X2House:GetHouseOwnerName", "X2House:GetHouseName", "X2House:GetHouseType" },
    apiReadiness = "official", apiPolicy = "read_only", evidence = "ArcheRage RU official addon API update 2026-08-19",
})
Add("life_butler", "life.butler", "管家助手", "life", 90, "预留管家充能/服务状态入口；当前只接纳已开放的充能信息 getter，不提前接未授权动作。", {
    status = "migrated_v3_read_only", lifecycle = "page_scoped", authority = "v3.butler", widgetCapable = false, settingsCapable = false,
    apiDependencies = { "X2Butler:GetChargeInfo" }, apiReadiness = "official_narrow", apiPolicy = "read_only",
    evidence = "ArcheRage RU official addon API update 2026-08-26; capability surface is currently narrow",
})

Add("tools_bag", "tools.bag_organizer", "整理背包", "tools", 10, "背包/仓库整理、黑名单与按类别有界批量移动。", {
    status = "migrated_partial", lifecycle = "independent_low_cost", authority = "v3.bag", settingsCapable = true, defaultEnabled = true,
    capabilities = { "category_batch", "scheduler_queue", "window_commands", "native_window_quick_take_put", "blacklist_filter", "read_verify_stop", "dynamic_source_resolution", "ru_identity_fallback", "shared_inventory_snapshot", "physical_bag_authority", "grouped_intent_queue" },
    scheduler = "InventorySnapshotV3 builds one bounded read/index snapshot per explicit plan (bagId=1 physical Authority with bounded bagId=0 fallback); Shared Scheduler serializes grouped same-item/category intent at 250ms; slotHint is revalidated before every write and quick/category tasks remain mutually exclusive; no per-frame polling",
    window = "默认启用的低成本窗口观察只读取背包/银行/箱子的几何与可见性；兼容 RU GetContentMainScriptPosVis 的 boolean/0-1/string/四值形态。显式 Native 可见性最高优先级；ADDON:GetContent 仅提供正向可见证据，隐藏代理不得否决仍有合法 MainScript 几何的实际窗口。取/放/停使用真实 transient WINDOW 宿主，并在仓储可见期间以 350ms heartbeat 有界重试 Presenter；物品扫描/移动仍只在显式点击后执行；用户显式关闭整理背包后观察任务立即释放。",
    blacklist = "Per-bank/coffer itemType/category rules are applied before every move; blacklist or source-read failure fails closed",
    apiDependencies = {
        "X2Bag:Capacity", "X2Bag:GetBagItemInfo", "X2Bank:GetBagItemInfo", "X2Coffer:GetBagItemInfo",
        "X2Bag:MoveToEmptyBankSlot", "X2Bag:MoveToEmptyCofferSlot",
        "X2Bank:MoveToEmptyBagSlot", "X2Coffer:MoveToEmptyBagSlot",
        "ADDON:GetContent", "ADDON:GetContentMainScriptPosVis",
    },
    apiReadiness = "local_contract_verified_pending_native_runtime", verification = "v3_native_window_follow_contract_pending_ru_visual_runtime",
    apiPolicy = "read_plus_explicit_move", evidence = ".18.123 keeps the reference project as behavior evidence only and replaces its scan/queue mechanics with shared InventorySnapshotV3. The service normalizes native rows into detached primitives, prefers verified physical bagId=1 with bounded bagId=0 fallback, and builds identity/category indexes in the same pass. Quick take/put and category batch queue grouped stable intent rather than one record per transient slot, use live slot hints + wraparound revalidation before every write, and only run a bounded population count when the post-write source slot is ambiguous. The old production name+grade+category tuple remains a conservative fallback only when RU omits itemType. All writes stay explicit, 250ms serialized, mutually exclusive and fail-closed on read/verify/window changes. RU visual anchoring and long move timing still require Fresh Reload proof.",
})
Add("tools_auction", "tools.auction_favorites", "拍卖收藏", "tools", 20, "拍卖关键词/收藏、当前挂单查询、稳定分页与单物品显式报价；服务器搜索统一走共享查询服务。", {
    status = "migrated_partial", lifecycle = "explicit_query", authority = "v3.auction", settingsCapable = true,
    apiDependencies = { "X2Auction:SearchAuctionArticle", "X2Auction:GetSearchedItemCount", "X2Auction:GetSearchedItemInfo", "X2Auction:GetLowestPrice", "ADDON:GetContent", "ADDON:GetContentMainScriptPosVis" },
    apiReadiness = "official_mixed", verification = "local_contract_verified_pending_ru_runtime", apiPolicy = "explicit_server_query_plus_readonly_native_surface_observation",
    currentImplementation = "收藏增删/持久化/分页可用；AuctionQueryV3 串行拥有无 token 的 AUCTION_ITEM_SEARCHED；Quote 走共享 PriceQuoteQueueV3；.18.118 新增 AuctionSurfaceV3 v2 + 独立 Sidecar Consumer，打开原生拍卖行时只读跟随其位置/可见性并复用同一收藏/搜索 Authority；兼容 RU MainScript 只返回四个几何值而省略 visible 的构建，并用 ADDON:GetContent 父链可见性/几何作为更强事实，不后台发起搜索。",
    remainingCapability = "Sidecar 的 RU 视觉跟随/原生拍卖行几何返回仍需 Fresh Reload；RU 搜索结果的全部字段/排序语义与更丰富筛选仍待实机验证；当前结果不能被当成历史成交样本",
    evidence = "z_api_functions exports UIC_AUCTION + ADDON:GetContent/GetContentMainScriptPosVis; retained old Auction Favorites service proves the RU four-value geometry compatibility and parent-chain behavior; Active V3 uses the existing Favorite Store/AuctionQuery and a read-only 250ms surface observer with no server-query fan-out"
})
Add("tools_market_analysis", "tools.market_analysis", "拍卖行情", "tools", 25, "显式查询当前拍卖挂单并分页查看价格、数量与卖家；不把当前挂单伪装成历史成交行情，也不后台持续扫拍卖行。", {
    status = "migrated_partial", currentImplementation = "AuctionQueryV3 提供按需当前挂单查询与 bounded 结果投影；页面明确标记“非历史成交价”，不后台扫拍卖行", remainingCapability = "真正历史行情仍需要稳定的成交/时间样本来源；当前 Search result 只能表示当前挂单", lifecycle = "explicit_query", authority = "v3.market_analysis", widgetCapable = false, settingsCapable = true,
    apiDependencies = { "X2Auction:SearchAuctionArticle", "X2Auction:GetSearchedItemCount", "X2Auction:GetSearchedItemInfo", "X2Auction:GetLowestPrice", "X2Auction:AskMarketPrice" },
    apiReadiness = "official", apiPolicy = "explicit_server_query", evidence = "Retained rs_auction_service.lua 9-parameter SearchInteractive + AuctionQueryV3 serialized completion ownership; history remains explicitly unclaimed",
})
Add("tools_craft", "tools.craft_assist", "制作台助手", "tools", 30, "制作台上下文的材料、持有量与缺口辅助；生命周期与跑商解耦，批量市场报价不在普通刷新执行。", {
    status = "migrated_partial", lifecycle = "independent", authority = "v3.craft", widgetCapable = true, settingsCapable = true,
    apiDependencies = { "X2Craft:GetCraftTypeByItemType", "X2Craft:GetCraftMaterialInfo", "X2Craft:GetCraftProductInfo", "X2Bag:Capacity", "X2Bag:GetBagItemInfo", "ADDON:GetContent", "ADDON:GetContentMainScriptPosVis" },
    apiReadiness = "official_mixed_pending_runtime", verification = "local_contract_verified_pending_ru_runtime", apiPolicy = "on_demand_read_only_plus_native_surface_observation",
    currentImplementation = "用户从已核制作物目录选择，不输入 doodadId/craftType；bounded product/material、held/shortage 与 known-record graph；Native 材料不可读时可回退已核静态贸易配方；.18.121 新增 CraftSurfaceV3 + 独立 tools.craft_sidecar：仅在功能启用且自动侧窗打开时以 400ms bounded watcher 观察 UIC_MAKE_CRAFT_ORDER/UIC_CRAFT_ORDER/UIC_CRAFT_BOOK，原生制作窗可见时复用同一 Craft Authority 显示材料侧窗；不订阅未验证 Craft Event，不后台询价。",
    remainingCapability = "非贸易制作目录、原生制作窗口几何/可见性的 RU Fresh Reload 证明，以及更精确的制作台/区域业务上下文仍待验证；未验证 Craft Event 继续不接入",
    evidence = "z_api_functions exports three craft UIC constants + governed ADDON read-only calls; retained production CraftAssist behavior used only as visibility/sidecar UX evidence; Active V3 CraftSurfaceContract v1 is event-free and fail-closed on geometry-only visibility",
})
Add("tools_instance_browser", "tools.instance_browser", "副本目录", "tools", 40, "浏览客户端当前副本分类、入场次数与运行时副本ID；静态数据库区域ID与运行时副本ID严格分离。", {
    status = "migrated_m1", lifecycle = "page_scoped", authority = "v3.instances", settingsCapable = false,
    apiDependencies = { "X2BattleField:GetInstanceUiKindList", "X2BattleField:GetInstanceListByKind", "X2BattleField:GetDetailInstanceInfo", "X2BattleField:GetInstanceName" },
    apiReadiness = "official", apiPolicy = "on_demand_read_only", evidence = "ArcheRage RU official addon API update 2026-05-19 + InstanceCatalogV3",
})
Add("tools_social", "tools.social", "社交名单", "tools", 50, "好友列表、屏蔽与静音名单的统一查看和管理；写操作遵守 1 秒冷却。", {
    status = "migrated_m16_18", lifecycle = "explicit_action", authority = "v3.social", settingsCapable = true,
    apiDependencies = { "X2Friend:IsMyFriend", "X2Friend:GetFriendList", "X2Friend:GetBlockList", "X2Friend:BlockUser", "X2Friend:UnblockUser", "X2Friend:GetMuteList", "X2Friend:MuteUser", "X2Friend:UnmuteUser" },
    apiReadiness = "official", apiPolicy = "cooldown_writes", evidence = "ArcheRage RU official addon API updates 2026-04-28 / 2026-08-05; central Api CapabilityCooldown contract enforces 1000ms writes",
})
Add("tools_hotkey_profiles", "tools.hotkey_profiles", "快捷键方案", "tools", 70, "保存/恢复一组游戏快捷键绑定；所有写操作只允许在非战斗状态执行。", {
    status = "runtime_blocked", runtimeBlocked = true, runtimeBlocker = "当前 RU API 没有动作名称枚举接口；GetOptionBinding 只能读取已知 action/index，无法安全构造完整快捷键方案", currentImplementation = "V3 页面只显示阻塞原因，不写入未知按键", remainingCapability = "需要官方 action registry 或完整 profile 导出契约", lifecycle = "explicit_action", authority = "v3.hotkey_profiles", settingsCapable = true,
    apiDependencies = { "X2Hotkey:GetOptionBinding", "X2Hotkey:BindingToOption", "X2Hotkey:OptionToBinding", "X2Hotkey:SetOptionBindingWithIndex", "X2Hotkey:RemoveOptionBinding", "X2Hotkey:SaveHotKey" },
    apiReadiness = "official_restricted", apiPolicy = "combat_restricted_write", evidence = "ArcheRage RU official hotkey API + 2026-08-19 combat restrictions",
})
Add("tools_reinforce_analysis", "tools.reinforce_analysis", "装备强化分析", "tools", 80, "读取已验证的强化聚合/套装信息；逐槽位等级与材料详情在合法 equipSlotIndex 契约确认前保持 Runtime Blocked。", {
    status = "migrated_partial", currentImplementation = "V3 只读聚合投影：总强化等级、属性系合计、下一套装档位、套装状态与组合效果上限；不枚举、不探测未知 equipSlotIndex", remainingCapability = "逐槽位强化等级/材料仍为 SPECIFIC_RUNTIME_BLOCKED：需要 RU 实机证明合法 equipSlotIndex 枚举来源及 GetReinforceInfo/GetMaterialInfo 返回结构；写入类强化接口始终不可达", lifecycle = "independent", authority = "v3.reinforce_analysis", settingsCapable = true,
    apiDependencies = { "X2EquipSlotReinforce:GetTotalReinforceLevel", "X2EquipSlotReinforce:GetAttributeTotalLevel", "X2EquipSlotReinforce:GetNextSetApplyLevel", "X2EquipSlotReinforce:HasNextSetEffect", "X2EquipSlotReinforce:SuitableLevelForEquipSlotReinforce", "X2EquipSlotReinforce:GetBundleEffectTopLevel" },
    apiReadiness = "official_aggregate_only", apiPolicy = "read_only_no_slot_probe", evidence = "ArcheRage RU aggregate reinforcement getters + PRODUCT_COMPLETION_MATRIX locked per-slot contract; guessed 0..31 probe removed",
})
Add("tools_portal_profiles", "tools.portal_profiles", "传送配置", "tools", 90, "预留个人传送偏好/收藏配置；只在 RU 实机验证当前 Option API 后接业务，不使用未授权 X2Warp 写接口。", {
    status = "runtime_blocked", runtimeBlocked = true, runtimeBlocker = "X2Option optionType/返回值语义和个人传送候选集合未在当前 RU 客户端验证", currentImplementation = "V3 页面显示阻塞原因，不执行 Option 写入", remainingCapability = "需要候选枚举、稳定 optionType 和写入回读契约", lifecycle = "independent", authority = "v3.portal_profiles", settingsCapable = true,
    apiDependencies = { "X2Option:GetOptionItemValue", "X2Option:SetItemFloatValue" }, apiReadiness = "research", apiPolicy = "candidate_write",
    evidence = "ArcheRage community Personal Portals setter; Suite candidate Option APIs remain runtime-unverified",
})
Add("tools_random_shop", "tools.random_shop", "随机商店计数", "tools", 100, "预留随机商店刷新次数显示与提醒；当前官方只开放刷新计数 getter，不假设其它商店数据可读。", {
    status = "migrated_v3_read_only", lifecycle = "page_scoped", authority = "v3.random_shop", widgetCapable = false, settingsCapable = false,
    apiDependencies = { "X2Store:GetRandomShopStoreRefreshCount" }, apiReadiness = "official_narrow", apiPolicy = "read_only",
    evidence = "ArcheRage RU official addon API update 2026-08-26",
})

Add("system_widgets", "system.widgets", "悬浮组件", "system", 10, "统一管理已经迁入新版框架的独立悬浮组件。", { status = "foundation", lifecycle = "shell", authority = "widget_host" })
Add("system_features", "system.features", "功能模块", "system", 20, "统一查看新版功能目录与各功能的独立运行状态。", { status = "foundation", lifecycle = "shell", authority = "feature_registry" })
Add("system_settings", "system.settings", "全局设置", "system", 30, "只管理应用级设置；各功能设置由对应功能自己管理。", { status = "foundation", lifecycle = "shell", authority = "v3.shell" })
Add("system_diagnostics", "system.diagnostics", "诊断与维护", "system", 40, "检查基础框架、界面宿主、数据所有权与功能迁移状态。", { status = "foundation", lifecycle = "shell", authority = "diagnostics" })

-- Navigation affinity groups. These are presentation metadata only: they do not
-- couple Feature lifecycles. The shell uses them to keep related entries next
-- to each other with a small visual separator between groups.
local function AssignGroup(groupId, groupOrder, ids)
    for index, id in ipairs(ids) do
        local row = R.features[id]
        if row ~= nil then
            row.group = tostring(groupId)
            row.groupOrder = tonumber(groupOrder) or 100
            row.groupItemOrder = index
        end
    end
end

AssignGroup("home", 10, { "home" })
AssignGroup("combat_analysis", 10, { "combat_stats", "combat_analytics", "combat_death_review" })
AssignGroup("combat_assist", 20, { "combat_healer", "combat_buff_display", "combat_buff_cap", "combat_boss_alerts", "combat_target_monitor", "combat_unit_lines", "combat_range_assist" })
AssignGroup("combat_team", 30, { "combat_team_tools", "combat_raid_readiness", "combat_raid_recruitment", "combat_siege_readiness" })
AssignGroup("combat_loadout", 40, { "combat_gear" })

AssignGroup("life_schedule", 10, { "life_activities", "life_tasks" })
AssignGroup("life_economy", 20, { "life_trade", "life_bonds", "life_craft_planner" })
AssignGroup("life_property", 30, { "life_housing", "life_butler" })
AssignGroup("life_leisure", 40, { "life_treasure", "life_fishing" })

AssignGroup("tools_inventory", 10, { "tools_bag", "tools_craft" })
AssignGroup("tools_market", 20, { "tools_auction", "tools_market_analysis" })
AssignGroup("tools_reference", 30, { "tools_instance_browser" })
AssignGroup("tools_social", 40, { "tools_social" })
AssignGroup("tools_profiles", 50, { "tools_hotkey_profiles", "tools_portal_profiles" })
AssignGroup("tools_equipment", 60, { "tools_reinforce_analysis" })
AssignGroup("tools_shop", 70, { "tools_random_shop" })

AssignGroup("system", 10, { "system_widgets", "system_features", "system_settings", "system_diagnostics" })
R:Resort()
