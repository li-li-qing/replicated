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
Add("combat_target_monitor", "combat.target_monitor", "目标监控", "combat", 60, "按需追踪当前目标身份、名称与距离；不伪造仇恨目标。", { status = "migrated_m16_18", lifecycle = "demand_scoped", authority = "v3.target_monitor", widgetCapable = true, apiDependencies = { "X2Unit:GetTargetUnitId", "X2Unit:UnitName", "X2Unit:UnitDistance" }, apiReadiness = "partial", apiPolicy = "on_demand_read_only", currentImplementation = "TARGET_CHANGED 即时刷新 + 500ms Demand-scoped 距离采样；Consumer=0 时任务和事件全部释放", remainingCapability = "仇恨目标需要独立、已验证的 RU 事实来源后再接入", evidence = "V3 target observation contract v1; event edge + bounded Scheduler distance refresh" })
Add("combat_unit_lines", "combat.unit_lines", "单位连线", "combat", 70, "当前实现为自己 ↔ 当前目标的独立屏幕连线；不恢复官方禁用的附近单位枚举。", { status = "migrated_partial", lifecycle = "demand_scoped", authority = "v3.unit_lines + screen_projection_v3", currentImplementation = "100ms Demand-scoped 当前目标投影 + 有界点线 Presenter；支持点数/大小/透明度", remainingCapability = "全单位关系网络仍需要官方允许的单位集合来源；GetUnitsInSight 保持禁用", widgetCapable = false, settingsCapable = true, apiDependencies = { "X2Unit:GetUnitScreenPosition", "X2Unit:GetUnitWorldPositionByTarget" }, apiReadiness = "partial", apiPolicy = "bounded_current_target_only" })
Add("combat_range_assist", "combat.range_assist", "范围辅助", "combat", 80, "以玩家为圆心绘制用户指定半径的范围圆；不猜技能/魔法阵真实范围。", { status = "migrated_partial", lifecycle = "demand_scoped", authority = "v3.range_assist + screen_projection_v3", currentImplementation = "200ms Demand-scoped 玩家世界坐标 + 12-48 个有界投影点；支持半径/点数/点大小/透明度", remainingCapability = "技能/魔法阵自动半径需要独立已验证的技能范围事实；当前只承诺用户自定义半径", widgetCapable = false, settingsCapable = true, apiDependencies = { "X2Unit:GetUnitWorldPositionByTarget" }, apiReadiness = "partial", apiPolicy = "bounded_user_radius" })
Add("combat_buff_cap", "combat.buff_cap", "增益容量监控", "combat", 85, "读取自身普通/隐藏增益数量；RU 容量与顶替阈值未验证前不生成风险告警。", {
    status = "migrated_partial", lifecycle = "demand_scoped", authority = "v3.buff_cap", widgetCapable = true, settingsCapable = true,
    apiDependencies = { "X2Unit:UnitBuffCount", "X2Unit:UnitHiddenBuffCount" }, apiReadiness = "partial", apiPolicy = "read_only",
    currentImplementation = "Demand-scoped BUFF_UPDATE/TARGET_CHANGED 事件边 + 120ms one-shot 合并刷新，并保留低频兜底；Consumer=0 时不保留事件或任务；不推断容量阈值", remainingCapability = "需要 RU Buff 容量、顶替顺序与预警阈值的实机证据后才能恢复风险提示",
    evidence = "Bundled X2Unit buff-count getters; no verified RU eviction threshold",
})
Add("combat_team_tools", "combat.team_tools", "团队管理", "combat", 90, "全队职责只读与当前玩家职责设置；成员移动在无法合法证明队长权限时安全停用。", { status = "migrated_partial", lifecycle = "explicit_action", authority = "v3.team_tools", settingsCapable = true, apiDependencies = { "X2Team:GetRole", "X2Team:SetRole" }, apiReadiness = "partial", verification = "static_signature_verified_pending_ru_runtime", apiPolicy = "explicit_action_fail_closed", currentImplementation = "TeamRoster 更新驱动的全队职责只读；X2Team:SetRole(role) 仅作为当前玩家职责写入；成员移动按钮不可执行", remainingCapability = "MoveTeamMember/MoveTeamMemberToParty 需要允许使用的队长/权限 getter；当前 IsTeamOwner 明确 NotAllowed", evidence = "Bundled TMROLE_* globals + X2Team signatures + capability registry permission fence" })
Add("combat_raid_readiness", "combat.raid_readiness", "团队战备检查", "combat", 92, "按需检查团队职责、关键增益、装分与职业准备状态，不依赖 DPS 常驻运行。", {
    status = "migrated_m16_14", lifecycle = "on_demand_scan", authority = "v3.raid_readiness + v3.team_roster + v3.aura_observation",
    widgetCapable = false, settingsCapable = true, defaultEnabled = false,
    apiDependencies = { "X2Team:GetRole", "X2Unit:UnitGearScore", "X2Unit:UnitDistance", "X2Unit:UnitBuffCount", "X2Unit:UnitBuff", "X2Unit:UnitHiddenBuffCount", "X2Unit:UnitHiddenBuff" },
    apiReadiness = "partial", apiPolicy = "read_only_on_demand",
    evidence = "V3 TeamRoster + AuraObservation Phase 12B; TEAM interface id 38 from bundled apitypes and GetRole capability registry",
})
Add("combat_raid_recruitment", "combat.raid_recruitment", "团队招募助手", "combat", 94, "按需读取招募申请并允许关闭招募；创建、接受、拒绝在参数形态未验证前安全停用。", {
    status = "migrated_partial", lifecycle = "explicit_action", authority = "v3.raid_recruitment", settingsCapable = true,
    apiDependencies = { "X2Team:RaidRecruitDel", "X2Team:RaidApplicantList" }, apiReadiness = "partial", apiPolicy = "verified_subset_only",
    currentImplementation = "读取 RaidApplicantList；Close 走 RaidRecruitDel；Create/Accept/Reject fail-closed",
    remainingCapability = "RaidRecruitAdd 9 字段语义与 RaidApplicantAccept/Reject(charIds) 的 charIds 形态需 RU 实机验证",
    evidence = "Bundled X2Team signatures; only verified subset is exposed as executable",
})
Add("combat_siege_readiness", "combat.siege_readiness", "攻城战备检查", "combat", 96, "攻城场景专用的装备与团队准备检查，关闭后不保留高频观察。", {
    status = "runtime_blocked", runtimeBlocked = true, runtimeBlocker = "GetEquippedItemTooltipInfo 的装备字段结构与攻城场景判定 API 未在当前 RU 客户端验证", currentImplementation = "V3 页面显示精确阻塞，不对装备文本做猜测解析", remainingCapability = "需要稳定的 itemType/slot/装分返回字段和 siege context", lifecycle = "independent", authority = "v3.siege_readiness", widgetCapable = true,
    apiDependencies = { "X2Equipment:GetEquippedItemTooltipInfo", "X2Team:GetRole" }, apiReadiness = "research", apiPolicy = "read_only",
    evidence = "ArcheRage community Raidcheckersiege; exact remote equipment coverage requires RU runtime verification",
})
Add("combat_gear", "combat.gear", "换装 / 称号", "combat", 100,
    "装备、武器、防具、饰品与效果称号使用同一套方案保存和一键切换；每套常用方案可生成一个独立可拖动的屏幕按钮。", {
    status = "migrated_m4", lifecycle = "independent", authority = "v3.gear",
    widgetCapable = true, settingsCapable = true, defaultEnabled = true,
    apiDependencies = {
        "X2Equipment:GetEquippedItemTooltipInfo", "X2Bag:GetBagItemInfo", "X2Bag:EquipBagItem",
        "X2Player:GetShowingAppellation", "X2Player:GetEffectAppellation",
        "X2Player:PlayerInCombat", "X2Player:ChangeAppellation",
    },
    apiReadiness = "official_mixed", apiPolicy = "explicit_user_read_write",
    evidence = "V3 GearService + legacy Replicated Gear live-tested bag/title contracts; RU write restrictions are enforced fail-closed",
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
    apiDependencies = { "X2Store:GetProductionZoneGroups", "X2Store:GetSellableZoneGroups", "X2Store:GetSpecialtyRatioBetween" },
    apiReadiness = "official_mixed", apiPolicy = "on_demand_server_query", currentImplementation = "路线/区域/服务器货率 + bounded 材料 itemType/数量投影；普通 Refresh 不调用拍卖报价", remainingCapability = "建立独立、限速、显式 GetLowestPrice 报价队列后才能恢复材料成本/利润", evidence = "V3 Trade Authority + SPECIALTY_RATIO_BETWEEN_INFO; quote fan-out removed in M1.16.0.18.39",
})
Add("life_bonds", "life.bonds", "债券 / 居民板", "life", 30, "每日居民板材料、完成状态与背包资源。", {
    status = "migrated_m16_18", lifecycle = "demand_scoped", authority = "v3.life.bonds", widgetCapable = true, settingsCapable = true,
    apiDependencies = { "X2Resident:GetResidentBoardContent", "X2Bag:Capacity", "X2Bag:GetBagItemInfo", "X2Quest:IsCompleted", "X2Quest:IsReadyForCompleteQuest" }, apiReadiness = "official_mixed", apiPolicy = "on_demand_read_only",
    evidence = "V3 Bonds resolves curated/verified constant mappings and projects QuestProgressV3 states plus bounded resource diagnostics; unknown runtime fields remain fail-closed",
})
Add("life_tasks", "life.tasks", "任务追踪", "life", 40, "用户选择的日常与周常任务追踪；支持子任务展开和独立悬浮追踪。", {
    status = "migrated_m1", lifecycle = "independent", authority = "v3.tasks",
    widgetCapable = true, settingsCapable = true, defaultEnabled = true,
    apiDependencies = {
        "X2Quest:GetActiveQuestListCount", "X2Quest:GetActiveQuestType",
        "X2Quest:IsCompleted", "X2Quest:IsReadyForCompleteQuest", "X2Quest:GetQuestContextMainTitle",
    },
    apiReadiness = "read_only", apiPolicy = "on_demand_read_only",
    evidence = "V3 QuestProgressService shared projection; no legacy QuestService runtime dependency",
})
Add("life_treasure", "life.treasure", "寻宝", "life", 50, "藏宝图坐标、方向与距离。", {
    status = "migrated_m16_18", lifecycle = "demand_scoped", authority = "v3.life.treasure", widgetCapable = true, settingsCapable = true,
    apiDependencies = { "X2Bag:GetBagItemInfo", "X2Bag:Capacity", "X2Unit:GetUnitWorldPositionByTarget" }, apiReadiness = "official_mixed", apiPolicy = "on_demand_read_only",
    currentImplementation = "有界背包藏宝图扫描 + 500ms Demand-scoped 玩家位置/方向/距离刷新；Consumer=0 立即停任务",
    evidence = "V3 Treasure observation contract v1; bounded bag scan + Scheduler position projection; Legacy Resource/Treasure is not loaded",
})
Add("life_fishing", "life.fishing", "钓鱼", "life", 60, "目标鱼动作 Buff 识别与技能推荐；自动 R 在完整可回滚热键事务迁入前不可用。", {
  status = "migrated_partial", lifecycle = "demand_scoped", authority = "v3.life.fishing", widgetCapable = true, settingsCapable = true,
  currentImplementation = "V3 页面、Demand、TARGET_CHANGED/BUFF_UPDATE 驱动的 bounded 目标 Buff observation 与技能栏推荐可用；Auto-R 按钮明确禁用",
  remainingCapability = "需要迁移并验证原 R/目标槽位快照、写入回读、异常恢复、Reload 恢复与原键还原事务",
  apiDependencies = { "X2Unit:UnitBuffCount", "X2Unit:UnitBuff", "X2Player:PlayerInCombat" }, apiReadiness = "partial", apiPolicy = "read_only_until_hotkey_transaction_verified",
  evidence = "Active V3 Fishing observation contract v1; target/buff events refresh detached projection; fake autoArmed completion removed in M1.16.0.18.39",
})
Add("life_craft_planner", "life.craft_planner", "制作规划", "life", 70, "多配方材料、持有量/缺口与已知记录制作链规划；市场成本必须走后续显式限速报价。", {
    status = "migrated_partial", lifecycle = "explicit_query", authority = "v3.craft_planner", widgetCapable = true, settingsCapable = true,
    apiDependencies = { "X2Craft:GetCraftBaseInfo", "X2Craft:GetCraftMaterialInfo", "X2Craft:GetCraftProductInfo", "X2Craft:GetCraftTypeByItemType", "X2Bag:Capacity", "X2Bag:GetBagItemInfo" },
    apiReadiness = "official_mixed_pending_runtime", verification = "local_contract_verified_pending_ru_runtime", apiPolicy = "on_demand_read_only",
    currentImplementation = "用户从 98 条已核制作物目录选择配方，内部解析 CraftID；bounded product/material rows、持有量/缺口与 known-record recursive graph；普通 Refresh 不发 Auction 查询",
    remainingCapability = "非跑商制作目录的用户级检索、RU 原生制作字段一致性，以及独立限速市场报价/完整递归成本仍待完成",
    evidence = "Known-record graph and shortage contracts; auction quote fan-out removed in M1.16.0.18.39",
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
    status = "migrated_partial", lifecycle = "explicit_action", authority = "v3.bag", settingsCapable = true,
    capabilities = { "category_batch", "scheduler_queue", "window_commands", "native_window_quick_take_put", "blacklist_filter", "read_verify_stop" },
    scheduler = "Shared Scheduler serializes bounded category moves and native-window quick take/put; quick/category tasks are mutually exclusive; one move per scheduled step; no per-frame polling",
    window = "打开银行/箱子时 V3 Presenter 跟随背包显示“取/放/停”；显式点击才建立同类物品移动计划，页面保留高级整理入口",
    blacklist = "Per-bank/coffer itemType/category rules are applied before every move; blacklist or source-read failure fails closed",
    apiDependencies = {
        "X2Bag:Capacity", "X2Bag:GetBagItemInfo", "X2Bank:GetBagItemInfo", "X2Coffer:GetBagItemInfo",
        "X2Bag:MoveToEmptyBankSlot", "X2Bag:MoveToEmptyCofferSlot",
        "X2Bank:MoveToEmptyBagSlot", "X2Coffer:MoveToEmptyBagSlot",
    },
    apiReadiness = "local_contract_verified_pending_native_runtime", verification = "v3_native_window_follow_contract_pending_ru_visual_runtime",
    apiPolicy = "read_plus_explicit_move", evidence = "Active V3 uses ADDON:GetContentMainScriptPosVis only for bounded geometry observation; overlay is an independent RSUI Presenter, not Native reparenting. Quick take/put and category batch are mutually exclusive, serialize at 250ms, re-read the source slot before every move, and stop on storage close/change or feature disable. RU visual anchoring and move timing still require Fresh Reload proof.",
})
Add("tools_auction", "tools.auction_favorites", "拍卖收藏", "tools", 20, "拍卖关键词/收藏、当前挂单查询、稳定分页与单物品显式报价；服务器搜索统一走共享查询服务。", {
    status = "migrated_partial", lifecycle = "explicit_query", authority = "v3.auction", settingsCapable = true,
    apiDependencies = { "X2Auction:SearchAuctionArticle", "X2Auction:GetSearchedItemCount", "X2Auction:GetSearchedItemInfo", "X2Auction:GetLowestPrice" },
    apiReadiness = "official_mixed", verification = "local_contract_verified_pending_ru_runtime", apiPolicy = "explicit_server_query",
    currentImplementation = "收藏增删/持久化/分页可用；AuctionQueryV3 串行拥有无 token 的 AUCTION_ITEM_SEARCHED，使用已验证 9 参数搜索并归一化 bounded 当前挂单；Quote 是单次显式 GetLowestPrice",
    remainingCapability = "RU 搜索结果的全部字段/排序语义与更丰富筛选仍待实机验证；当前结果不能被当成历史成交样本",
    evidence = "Bundled 9-parameter API signature + retained AuctionService proven call shape; AuctionQueryV3 serializes AUCTION_ITEM_SEARCHED and bounds result reads"
})
Add("tools_market_analysis", "tools.market_analysis", "拍卖行情", "tools", 25, "显式查询当前拍卖挂单并分页查看价格、数量与卖家；不把当前挂单伪装成历史成交行情，也不后台持续扫拍卖行。", {
    status = "migrated_partial", currentImplementation = "AuctionQueryV3 提供按需当前挂单查询与 bounded 结果投影；页面明确标记“非历史成交价”，不后台扫拍卖行", remainingCapability = "真正历史行情仍需要稳定的成交/时间样本来源；当前 Search result 只能表示当前挂单", lifecycle = "explicit_query", authority = "v3.market_analysis", widgetCapable = false, settingsCapable = true,
    apiDependencies = { "X2Auction:SearchAuctionArticle", "X2Auction:GetSearchedItemCount", "X2Auction:GetSearchedItemInfo", "X2Auction:GetLowestPrice", "X2Auction:AskMarketPrice" },
    apiReadiness = "official", apiPolicy = "explicit_server_query", evidence = "Retained rs_auction_service.lua 9-parameter SearchInteractive + AuctionQueryV3 serialized completion ownership; history remains explicitly unclaimed",
})
Add("tools_craft", "tools.craft_assist", "制作台助手", "tools", 30, "制作台上下文的材料、持有量与缺口辅助；生命周期与跑商解耦，批量市场报价不在普通刷新执行。", {
    status = "migrated_partial", lifecycle = "page_scoped", authority = "v3.craft", settingsCapable = true,
    apiDependencies = { "X2Craft:GetCraftTypeByItemType", "X2Craft:GetCraftMaterialInfo", "X2Craft:GetCraftProductInfo", "X2Bag:Capacity", "X2Bag:GetBagItemInfo" },
    apiReadiness = "official_mixed_pending_runtime", verification = "local_contract_verified_pending_ru_runtime", apiPolicy = "on_demand_read_only",
    currentImplementation = "用户从已核制作物目录选择，不输入 doodadId/craftType；bounded product/material、held/shortage 与 known-record graph；Native 材料不可读时可回退已核静态贸易配方",
    remainingCapability = "非贸易制作目录、制作台上下文事件以及独立限速市场报价仍待验证/实现",
    evidence = "Craft shared read model; auction quote fan-out removed in M1.16.0.18.39",
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
Add("tools_reinforce_analysis", "tools.reinforce_analysis", "装备强化分析", "tools", 80, "读取槽位强化等级、材料需求、套装/组合效果，做升级差距与材料规划，不执行强化动作。", {
    status = "runtime_blocked", runtimeBlocked = true, runtimeBlocker = "强化 getter 的 equipSlotIndex 合法范围、返回字段和当前装备上下文仍未在 RU 实机确认", currentImplementation = "V3 页面显示阻塞原因，不猜槽位或强化等级", remainingCapability = "需要稳定槽位枚举与 GetReinforceInfo/GetMaterialInfo 字段契约", lifecycle = "independent", authority = "v3.reinforce_analysis", settingsCapable = true,
    apiDependencies = { "X2EquipSlotReinforce:GetMaterialInfo", "X2EquipSlotReinforce:GetReinforceInfo", "X2EquipSlotReinforce:GetAppliedAllSetEffect", "X2EquipSlotReinforce:GetTotalReinforceLevel" },
    apiReadiness = "official", apiPolicy = "read_only", evidence = "ArcheRage RU official 20 reinforcement getters; crash-prone getters fixed 2026-05-12",
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
