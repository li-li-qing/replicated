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

-- 维护（module-controls-diag-2）：这是源码工作负载预估，不是CPU/内存/FPS采样。
-- 显式登记避免按模块名称猜等级；只在注册时取值，关闭模块也能查看开启成本。
-- 高密度PVP/圈点数量/团队人数可改变真实开销，后续实测调整元数据而不能改动生命周期。
local PERFORMANCE_LABELS = { "低", "中", "高", "非常高" }
local PERFORMANCE_PROFILES = {
    life_daily_stats = { 1, "低频事件累计今日变化，无全场扫描。" },
    combat_stats = { 3, "战斗事件量与参与单位、技能明细增加时开销上升。" },
    combat_analytics = { 4, "击杀、死亡和个人历史与伤害统计共享采集；所有人模式随战斗事件量增加开销。" },
    combat_healer = { 4, "多人团队生命值、距离、状态与推荐排序持续更新，人数越多开销越高。" },
    combat_death_review = { 1, "有界死亡前事件历史；战斗密集时事件处理量增加。" },
    combat_buff_display = { 3, "自身/目标状态观察、图标与HUD更新；追踪数量会影响开销。" },
    combat_nameplate_visuals = { 1, "仅启停、设置变更和进入世界时写入少量原生显示参数；无持续轮询。" },
    combat_boss_alerts = { 2, "按需观察首领技能与状态事件，机制与可见提示数量影响开销。" },
    combat_target_monitor = { 1, "按需观察少量指定目标。" },
    combat_unit_lines = { 3, "持续投影与连线点绘制；刷新间隔、线条数和密度影响开销。" },
    combat_range_assist = { 3, "多圆多点投影；圆数、点密度与刷新频率越高开销越大。" },
    -- 中文维护（2026-10-09）：工作负载只含当前目标的两个弧，开关关闭/无显示租约不采样。
    combat_facing_indicator = { 2, "当前目标朝向与36个有界点/文字按帧投影；关闭时停止观测。" },
    combat_buff_cap = { 1, "自身状态数量低频观察。" },
    combat_team_tools = { 2, "团队列表投影和可选高亮；多人团队/高亮刷新增加开销。" },
    combat_raid_readiness = { 2, "显式战备检查时扫描团队，非持续全场扫描。" },
    combat_raid_recruitment = { 1, "以用户操作和事件处理为主。" },
    combat_siege_readiness = { 1, "当前运行入口受保护；此等级不表示功能可用。" },
    combat_gear = { 1, "按用户操作切换装备，不持续扫描所有单位。" },
    life_activities = { 1, "时间表与低频阶段、倒计时更新。" },
    life_trade = { 2, "可见页面和显式查询使用报价队列；查询量影响开销。" },
    life_bonds = { 2, "任务状态及材料列表按需更新。" },
    life_tasks = { 1, "任务事件与低频进度投影。" },
    life_treasure = { 2, "开启指引时进行坐标计算与方向更新。" },
    life_fishing = { 2, "有使用者时才采样；目标数量与刷新频率影响开销。" },
    life_housing = { 1, "页面打开时读取住宅投影。" },
    tools_bag = { 1, "显式整理计划及容器事件；执行计划时有短时增量。" },
    tools_auction = { 2, "用户搜索与材料列表查询；非持续全量市场扫描。" },
    tools_market_analysis = { 2, "显式查询和结果分析，数据量越大成本越高。" },
    tools_craft = { 2, "配方与材料计划计算；复杂计划会增加开销。" },
    tools_instance_browser = { 1, "按需查询和列表展示。" },
    tools_social = { 1, "以显式操作和事件为主。" },
    tools_feature_profiles = { 1, "仅在创建/编辑/应用方案与功能生命周期边沿比较开关状态；无 Tick/无持续扫描。" },
}

local function NormalizeId(value)
    local id = tostring(value or ""):lower():gsub("[^%w_%.%-]", "_"):gsub("_+", "_")
    return id:gsub("^_+", ""):gsub("_+$", "")
end

local function ResolveNavigationDevelopmentState(spec) -- 中文维护注释：左侧导航的“完成/未完成”只属于 Presentation 开发视图，不得反向成为 Feature 生命周期、Store、Authority 或 API 可用性的第二事实源。
    spec = type(spec) == "table" and spec or {} -- 中文维护注释：Registry 注册边界统一归一输入，避免 nil spec 让开发排序在启动期抛错并阻断整个导航。
    local forced = tostring(spec.navigationDevelopmentState or ""):lower() -- 中文维护注释：仅允许少量当前 RU 实机回归用显式覆盖；完成后删除/改为 complete 即可恢复自动判定，route/id/config key 均不变化。
    if forced == "complete" or forced == "incomplete" or forced == "implemented_pending_ru" then return forced end -- 中文维护注释：显式覆盖优先于启发式，仅用于 Registry 已知状态落后于 CURRENT 实机 ToDo 的窗口期。
    local status = tostring(spec.status or "planned"):lower() -- 中文维护注释：status 是现有 Feature 元数据；planned/partial/blocked 都表示产品能力尚未闭环，适合作为导航开发排序证据。
    local readiness = tostring(spec.apiReadiness or ""):lower() -- 中文维护注释：API readiness 只参与展示分桶；partial/pending/research 不会因此解锁或禁用任何运行时 API。
    local verification = tostring(spec.verification or ""):lower() -- 中文维护注释：仍明确 pending 的运行时验证保持在“未完成”区，防止本地 Harness 通过后过早上移。
    local remaining = tostring(spec.remainingCapability or "") -- 中文维护注释：Feature 自己声明仍有剩余产品能力时，左侧导航应继续把它视为开发中而不是“已完成”。
    if spec.runtimeBlocked == true then return "incomplete" end -- 中文维护注释：Runtime Blocked 是最强未完成证据；这里只改变左侧排序/标签，原 fail-closed blocker 逻辑完全不动。
    if status:find("partial", 1, true) ~= nil or status:find("planned", 1, true) ~= nil or status:find("blocked", 1, true) ~= nil then return "incomplete" end -- 中文维护注释：复用现有状态命名约定，避免每新增一个 PARTIAL Feature 都要手工维护第二张导航名单。
    if readiness:find("partial", 1, true) ~= nil or readiness:find("pending", 1, true) ~= nil or readiness:find("research", 1, true) ~= nil then return "incomplete" end -- 中文维护注释：API 仍部分可用、等待 RU 或处于研究态时继续下沉，避免把“页面存在”误标成产品完成。
    if verification:find("pending", 1, true) ~= nil then return "incomplete" end -- 中文维护注释：需要 RU Fresh Reload/实机证明的显式 verification 同样属于开发中状态。
    if remaining ~= "" then return "incomplete" end -- 中文维护注释：remainingCapability 非空就是 Registry 自证尚未闭环；该判断不解析自然语言内容，只看是否存在剩余项。
    return "complete" -- 中文维护注释：只有没有任何未完成证据的 Feature 才进入左侧上方“完成”区域；未来元数据补充会自动重新分桶。
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
    local navigationDevelopmentState = ResolveNavigationDevelopmentState(spec) -- 中文维护注释：在注册时冻结本次 Feature 的导航开发态，Router 只消费结果，禁止再复制一套判定规则造成排序漂移。
    -- 中文维护（manual-feature-access-1）：启动时冻结手工配置，Registry 是唯一开放判断来源。
    -- 配置表中出现的功能也成为受限功能；仅 true 开放，缺失/字符串/数字不得意外解锁。
    -- 与 navigationVisible 分离，避免把原有隐藏语义子页误禁用；修改文件后重载，不做热轮询。
    local access = type(ReplicatedSuiteFeatureAccess) == "table" and ReplicatedSuiteFeatureAccess[id] or nil
    local accessConfigured = type(ReplicatedSuiteFeatureAccess) == "table" and ReplicatedSuiteFeatureAccess[id] ~= nil
    local manualAccessRequired = spec.manualAccessRequired == true or accessConfigured
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
        manualAccessAllowed = not manualAccessRequired or access == true, -- 中文维护：Runtime、路由、功能目录共享此冻结结果，不允许存档或 UI 改写它。
        navigationParentRoute = tostring(spec.navigationParentRoute or ""), -- 中文维护注释：隐藏语义子页可声明主导航父路由；这里只存展示元数据，绝不能改变 Feature 生命周期或 Authority。
        preferenceGroup = type(spec.preferenceGroup)=="table" and spec.preferenceGroup or nil,
        navigationDevelopmentState = navigationDevelopmentState, -- 中文维护注释：唯一导航开发态结果只用于 Router/Shell 展示；FeatureRuntime、Persistence 与页面业务不得读取它做功能决策。
        -- 中文维护注释（pending-ru-navigation-1）：Authority 仍是 Registry 的三态开发状态；
        -- implemented_pending_ru 代表“代码已实现但尚无 RU 实机验收”，因此 Presentation 必须继续放在未完成区，
        -- 不能因为离线单测通过就冒充产品完成。这里只改变导航标签/排序，不参与 Feature 生命周期或 API 门禁。
        navigationIncomplete = navigationDevelopmentState ~= "complete",
        description = tostring(spec.description or ""),
        status = tostring(spec.status or "planned"),
        lifecycle = tostring(spec.lifecycle or "independent"),
        authority = tostring(spec.authority or "pending"),
        -- 中文维护注释（2026-09-18，module-diagnostics-source-authority-1）：
        -- Feature 自己声明“确定属于本模块”的 Diagnostics source 别名。ModuleDiagnosticsHub 只做
        -- 精确匹配，禁止根据字符串相似度猜模块；这样 buff_display_v3/dps_v3 等历史 source 能进入
        -- 正确模块报告，同时 FeatureRegistry 仍是唯一模块身份 Authority，不再维护第二张别名表。
        diagnosticSources = (function()
            local out, seen = {}, {}
            for _, value in ipairs(type(spec.diagnosticSources) == "table" and spec.diagnosticSources or {}) do
                local source = tostring(value or "")
                if source ~= "" and not seen[source] then seen[source] = true; out[#out + 1] = source end
            end
            return out
        end)(),
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
    -- 首页控制今日统计；系统管理页无独立工作负载，不能伪造绿色“已开启”。
    row.controlFeatureId = spec.controlFeatureId or (id == "home" and "life_daily_stats" or (row.lifecycle == "shell" and "" or id))
    -- 系统管理页面不是独立工作负载，报告也不应凭空标一个“中”等级。
    if row.controlFeatureId ~= "" then
        local cost = PERFORMANCE_PROFILES[row.controlFeatureId] or { 2, "尚未专项评估，暂按中等开销预估。" }
        row.performanceLevel, row.performanceLabel, row.performanceReason = cost[1], PERFORMANCE_LABELS[cost[1]], cost[2]
        row.performanceEstimated = true
    end
    self.registrationRevision = (tonumber(self.registrationRevision) or 0) + 1
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

-- 中文维护：List 保留完整元数据用于内部诊断/实现注册；用户可选目录必须使用此过滤接口。
-- 被限制的原有偏好与参数仍可安全加载，禁止通过删除注册项导致存档归一丢失旧配置。
function R:IsAccessible(id)
    local meta = self:Get(id)
    return meta ~= nil and meta.manualAccessAllowed == true
end
function R:ListAccessible(category)
    local rows = {}
    for _, meta in ipairs(self:List(category)) do
        if self:IsAccessible(meta.id) then rows[#rows + 1] = meta end
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

-- 维护（overview-income-source-9）：客户端 UI 源码与 RU 实机参数形状共同确认：
-- PLAYER_MONEY(change, changeStr, itemTaskType, info)、PLAYER_HONOR_POINT(amount, amountStr, ...)
-- 与 PLAYER_LIVING_POINT(amount, amountStr) 的首参数是本次变化量，不是余额。官方 exp_bar_set / combat_text
-- 进一步确认 EXP_CHANGED(stringId, expNum, expStr)，其中仅 player unitId 的 expStr 被直接显示为本次经验增长。
-- 金币优先使用 changeStr；经验优先使用 expStr；禁止 GetExpInfo/GetHeirExpInfo 等 Getter 仍不调用。
Add("life_daily_stats", "home.daily_stats", "今日收支", "home", 15, "独立角色日账本：服务器自然日；金币/荣誉/经验/生活点采用 Native 直接变化量，未知来源不伪造。", {
    navigationVisible=false, navigationParentRoute="home", status="migrated_partial", lifecycle="independent",
    authority="v3.daily_ledger + daily_income_chat_source", defaultEnabled=true, settingsCapable=true, apiDependencies={}, apiReadiness="partial",
    apiPolicy="native_direct_delta_events_only", currentImplementation="服务器日界线、耐久账本、PLAYER_MONEY/HONOR/LIVING + EXP_CHANGED 直接变化事件；金币 changeStr / 经验 expStr 精确字符串优先；CHAT_MESSAGE 精确 CMF 显式 delta 回退；会话级暂停",
    remainingCapability="PLAYER_LIVING_POINT 与荣誉仍需更多 RU 实机样本确认极端负值/战场语义；EXP_CHANGED 已有客户端源码契约，仍需 RU 10.0 实机确认事件注册与参数形态。",
    evidence="Client UI dump chat_msg_event.lua defines PLAYER_MONEY/HONOR/LIVING direct deltas; exp_bar_set.lua defines EXP_CHANGED(stringId, expNum, expStr); combat_text.lua consumes player expStr directly as gained EXP; RU diagnostics already match resource-event payload shapes",
})

Add("combat_stats", "combat.stats", "战斗统计与分析", "combat", 10, "统计伤害、治疗、承伤、玩家击杀与死亡。每人一行，共用一次采集。默认只统计自己，可选所有人，个人历史长期保存在本地。", {
    preferenceGroup = { "combat_stats", "combat_analytics" },
    status = "migrated_m16", lifecycle = "independent", authority = "v3.dps + v3.combat_analytics", diagnosticSources = { "dps_v3" },
    widgetCapable = true, settingsCapable = true,
    currentImplementation = "每人一行显示伤害、治疗、承伤、玩家击杀、死亡，自身/全员均只计明确归属；永久个人历史与旧指纹验证迁移，旧推断保留但不计入明确击杀合计；玩家明确击杀已实机通过（游戏需开启显示战斗信息）；技能击杀次数与玩家名单仅保留当前统计期，技能未确认单列，不猜最后一击；死亡/归属通知合并去重；首屏与短面板明细自适应，可滚动；只读布局/击杀来源诊断",
    evidence = "RU 20261007-090816: 7 confirmed player kills live/history; 20261007 user retired NPC kill statistics and probes; genuine schema1/schema2 history and retired preference integrity regressions; skill-victim bounded drill-down + first-entry layout regressions",
})
Add("combat_analytics", "combat.analytics", "战斗分析", "combat", 15, "玩家击杀、死亡与个人历史，和伤害统计共享单一 CombatEventBus；助攻及高级分析暂时停止计算。", {
    navigationVisible = false, navigationParentRoute = "combat.stats", controlFeatureId = "combat_stats",
    preferenceGroup = { "combat_stats", "combat_analytics" },
    status = "migrated_m16_foundation", lifecycle = "independent_metrics", authority = "v3.combat_analytics",
    widgetCapable = false, settingsCapable = true, defaultEnabled = false,
})
Add("combat_healer", "combat.healer", "治疗辅助", "combat", 20, "治疗推荐核心与团队校准/屏幕色块：共享团队名单与 Aura 事实；不再提供无意义的推荐列表悬浮窗，校准可在治疗计算关闭时独立显示。", {
    navigationDevelopmentState = "complete", -- 中文维护注释：2026-09-10 用户已完成实机验收，左侧开发导航将治疗辅助列入“已完成”区域。这里只覆盖 Presentation 完成度；apiReadiness/remainingCapability 仍保留真实工程风险，不会因此放宽 Healer Consumer、Aura/TeamRoster Authority 或 Native API 门。
    status = "migrated_m16_18", lifecycle = "independent", authority = "v3.healer + v3.team_roster + v3.aura_observation", diagnosticSources = { "healer_v3" },
    widgetCapable = false, settingsCapable = true, defaultEnabled = false,
    apiDependencies = { "X2Team:GetRole", "X2Unit:UnitHealth", "X2Unit:UnitMaxHealth", "X2Unit:UnitDistance", "X2Unit:UnitBuffCount", "X2Unit:UnitBuff", "X2Unit:UnitDeBuffCount", "X2Unit:UnitDeBuff", "X2Unit:UnitHiddenBuffCount", "X2Unit:UnitHiddenBuff", "X2Unit:GetUnitScreenPosition" },
    apiReadiness = "partial", apiPolicy = "read_only_sliced", currentImplementation = "页面策略配置 + 头顶标记 + 团队覆盖层；Raid calibration 是独立 Presentation 模式，不获取治疗 Consumer", remainingCapability = "继续按实机校准团队框位置/颜色，不恢复推荐列表悬浮窗", evidence = "V3 Healer Domain + HeadMarker/RaidOverlay; TeamRosterV3 + AuraObservationV3 shared facts",
})
Add("combat_death_review", "combat.death_review", "死亡回顾", "combat", 30, "独立低开销死亡前时间线与历史。", {
    status = "migrated_m15_2", lifecycle = "independent", authority = "v3.death_review", diagnosticSources = { "death_review_v3" },
    widgetCapable = true, settingsCapable = true,
})
Add("combat_buff_display", "combat.buff_display", "状态显示", "combat", 40, "首个 Plates/BUFF V3 消费端：player/target 的增益、减益与隐藏状态 bounded display；事实只来自共享 StatusMap。", {
    navigationDevelopmentState = "complete", -- 中文维护（2026-09-13 用户实机验收）：状态显示按当前产品范围标记完成。这里只改变导航开发态；共享 Aura/StatusMap 的 API 能力说明、按需生命周期与个人配置均保持不变，后续新增能力仍需单独验收。
    -- 中文维护注释（.18.243）：旧 v3.buff_display 已降级为 migration-only 证据源；当前配置
    -- Authority 是 settings/layout/aliases/manifest 指向的 tracking slot。这里必须写清，避免维护者依据 Registry
    -- 又把 HUD/Tracking 保存接回旧单体 Store。AuraObservation 仍只负责运行时事实，不持有用户配置。
    status = "migrated_m16_18", lifecycle = "demand_scoped", authority = "v3.buff_display.settings + v3.buff_display.layout + v3.buff_display.aliases + v3.buff_display.tracking.manifest + v3.aura_observation (legacy v3.buff_display migration-only)", diagnosticSources = { "buff_display_v3" },
    widgetCapable = true, settingsCapable = true, defaultEnabled = false,
    apiDependencies = { "X2Unit:UnitBuffCount", "X2Unit:UnitBuff", "X2Unit:UnitBuffTooltip", "X2Unit:UnitDeBuffCount", "X2Unit:UnitDeBuff", "X2Unit:UnitDeBuffTooltip", "X2Unit:UnitHiddenBuffCount", "X2Unit:UnitHiddenBuff", "X2Unit:UnitHiddenBuffTooltip", "X2Unit:UnitName", "X2Ability:GetBuffTooltip", "X2Equipment:GetEquippedItemType", "X2Equipment:GetEquippedItemTooltipInfo" },
    apiReadiness = "shared_service_partial", apiPolicy = "read_only_bounded",
    currentImplementation = "状态追踪默认只列当前自己/目标实际出现的状态；来源入口切换当前、已追踪、记录与技能CD，不再分散为已追踪/添加状态页。内置库独立位于导入导出旁，默认全部内置状态推荐组，可选职业/类型分组后一键追踪本组；搜索只筛选展示，批量操作针对所选整组，保存失败整体回滚。四个选项卡为状态追踪、显示内容、导入导出、内置库；显示内容统一自身/目标显隐与HUD校准入口，短窗口可滚动访问全部设置。分享只提供导出和导入：完整配置包含追踪、显示策略及双HUD布局，粘贴后一次严格校验并通过原耐久事务导入，默认加入分享追踪并保留用户其它追踪；导出读回验证文本完整。状态行显示ID、名字、剩余时间与自身Buff/自身Debuff/目标Buff/目标Debuff四个独立开关；时间写明自身/目标并分两行，未取得时间显示未知，绿色写追踪、红色写未追踪，不依赖勾/圈字形；旧Auto保留内部语义，界面统一文字，取消某列保留其它列的意图。普通控件点击、切页和关闭页面先收起下拉弹层，弹层内部操作保留自身交互。已确认Buff/Debuff保持实际分类，不被相反追踪通道翻转；未分类状态仍可指定展示列。同ID合并一行，自己/目标剩余时间分别展示；未出现的保存状态仍可在已追踪来源取消。紧凑虚拟列表复用原元数据队列与A/B耐久事务。技能CD按ID统一自身/坐骑/宠物收藏，界面无需选择来源；未确认来源在原8次Native探测预算内查询已允许Getter，正读数确认后仅查询对应来源，不以静态秒数推算；取消同时移除旧两桶，旧选择加载不自动迁移。目标真实CD未有已验证入口，目标列明确不可用，不借本机读数；显示链诊断仅取缓存。HUD校准保留单项/全部预览、真实游戏画面拖动、现有图标/层数/品质/施法样本与原保存/取消事务。",
    evidence = "AuraObservationV3:GetStatusMap(); V3 Page/Widget projection and lifecycle contract",
})
-- 中文维护（2026-09-20，nameplate-mark-ratio-3）：18.272 RU 实机确认 name_tag_hp_* 血条有效，
-- 同时确认 over_head_marker_width/height/offset Set 后无视觉变化。头顶队伍标记改用
-- name_tag_mark_size_ratio（客户端 help: name tag mark scale）；旧三项不再写入。
-- 中文维护（2026-10-02 用户验收）：当前头顶标记/血条范围已接受，导航进入完成区；
-- 此标签仅属于 Presentation，不改变原生 CVar 事务、能力门、关闭恢复或存档契约。
Add("combat_nameplate_visuals", "combat.nameplate_visuals", "头顶标记 / 血条", "combat", 45,
    "调整原生头顶队伍标记倍率与名称血条尺寸；无持续扫描，关闭恢复启用前客户端值。", {
    navigationDevelopmentState = "complete", status = "migrated_partial", lifecycle = "event_edge", -- 中文维护：用户验收只覆盖导航开发态，工程能力描述仍保留真实限制。
    authority = "v3.nameplate_visuals + X2Option capability boundary", diagnosticSources = { "nameplate_visuals_v3" },
    widgetCapable = false, settingsCapable = true, defaultEnabled = false,
    apiDependencies = { "X2Option:GetConsoleVariable", "X2Option:SetConsoleVariable" },
    apiReadiness = "official_enabled_pending_ru_cvar_runtime", apiPolicy = "bounded_verified_cvar_write",
    currentImplementation = "6项原生 CVar 事务写入/回读/失败回滚；头标使用 name_tag_mark_size_ratio + overhead_marker_fixed_size，血条使用四项 name_tag_hp_*；ENTERED_WORLD 边沿重应用；Store schema1 不变；原生飘字入口诊断已在RU实机运行，当前已知控件/字号配置在addon全局不可见，未加入飘字大小设置",
    remainingCapability = "需 RU 实机确认 name_tag_mark_size_ratio 对 X2Unit:SetOverHeadMarker 1-12 标记的实时缩放、远近距离固定尺寸行为及极端 UI 缩放；原生飘字独立字号当前被控件访问入口阻断，需新的合法入口证据后再实现，用户指定落点为头顶标记/血条",
    verification = "hp_ru_verified_marker_ratio_pending",
    evidence = "18.272 RU: name_tag_hp_* visual confirmed / over_head_marker_width-height-offset no visual effect; bundled console_vars help says name_tag_mark_size_ratio = name tag mark scale; 2026-03-24 ArcheRage enabled X2Unit:SetOverHeadMarker APIs; 2026-10-07 RU 100122: native-combat-text-access-1 / frame_not_exposed / frameType=nil / localeType=nil / widgetsPresent=0 / no module or store faults",
})
-- 中文维护（2026-10-07）：用户同意缺少原GitHub链接时自行研究，以源码审查/本地回归验收当前范围。
-- 五条规则、15个读条别名、两个状态ID、仿真寿命与耐久回读通过；导航标完成，现场覆盖如实保留。
Add("combat_boss_alerts", "combat.boss_alerts", "首领机制 / 战斗警报", "combat", 50, "五条内置机制规则：逐条启停、实时施法/自身 Debuff 观察与屏幕提示。", { navigationDevelopmentState = "complete", status = "migrated_partial", lifecycle = "demand_scoped", authority = "v3.boss_alerts + alerts_service", widgetCapable = false, settingsCapable = true, apiReadiness = "shared_service_partial", apiPolicy = "read_only_push_hud", currentImplementation = "稳定 key 规则开关与批量耐久保存、选中规则测试、仿真提示独立寿命且关闭对应规则/HUD时撤回、四种 token 施法观察/自身 Debuff、同机制连续观察去重、真实剩余倒计时、HUD 字号/位置/时长", remainingCapability = "RU现场语言/时序及具体Boss仍需后续核对；当前完成范围为现有五条规则，不是全部首领机制库，不推测聊天或实体归属", verification = "source_review_local_contract_verified_pending_ru", evidence = "Boss RuleManagement v1 + CastingObservationV3 + AuraObservationV3 + Alerts owner-scoped presenter; 18 real-layer offline regressions, no RU live acceptance claim" })
Add("combat_target_monitor", "combat.target_monitor", "目标监控", "combat", 60, "按需追踪当前目标身份、名称与距离；不伪造仇恨目标。", { navigationVisible = false, status = "migrated_m16_18", lifecycle = "demand_scoped", authority = "v3.target_monitor", widgetCapable = true, apiDependencies = { "X2Unit:GetTargetUnitId", "X2Unit:UnitName", "X2Unit:UnitDistance" }, apiReadiness = "partial", apiPolicy = "on_demand_read_only", currentImplementation = "TARGET_CHANGED 即时刷新 + 500ms Demand-scoped 距离采样；Consumer=0 时任务和事件全部释放", remainingCapability = "仇恨目标需要独立、已验证的 RU 事实来源后再接入", evidence = "V3 target observation contract v1; event edge + bounded Scheduler distance refresh" })
-- 维护（用户实机确认2026-09-12）：当前约定范围标为完成并上移导航；技术能力限制仍如实保留，
-- 该展示覆盖不影响启停/调度/存档/允许API，不把附近单位枚举或自动技能半径视为已实现。
Add("combat_unit_lines", "combat.unit_lines", "单位连线", "combat", 70, "当前实现为自己 ↔ 当前目标的独立屏幕连线；不恢复官方禁用的附近单位枚举。", { navigationDevelopmentState = "complete", status = "migrated_partial", lifecycle = "demand_scoped", authority = "v3.unit_lines + screen_projection_v3", currentImplementation = "1-1000ms Demand-scoped 四类 token 连线 + 屏幕空间自适应密度/可见段裁剪/帧压力额外点预算 + P1 连续视觉刷新 + Presenter 本地 Diff/渐进点池；旧 pointCount 作为基础密度兼容保留；每线大小/颜色独立设置", remainingCapability = "全单位关系网络仍需要官方允许的单位集合来源；GetUnitsInSight 保持禁用", widgetCapable = false, settingsCapable = true, apiDependencies = { "X2Unit:GetUnitScreenPosition", "X2Unit:GetUnitWorldPositionByTarget" }, apiReadiness = "partial", apiPolicy = "bounded_current_target_only" })
-- 维护（用户实机确认2026-09-12）：当前约定范围标为完成并上移导航；技术能力限制仍如实保留，
-- 该展示覆盖不影响启停/调度/存档/允许API，不把附近单位枚举或自动技能半径视为已实现。
Add("combat_range_assist", "combat.range_assist", "范围辅助", "combat", 80, "以玩家为圆心绘制用户自建的多个范围圆；默认空配置，不猜技能/魔法阵真实范围。", { navigationDevelopmentState = "complete", status = "migrated_partial", lifecycle = "demand_scoped", authority = "v3.range_assist + screen_projection_v3", currentImplementation = "16/32/48ms 自适应 Demand-scoped 范围绘制；所有启用圆每次共享一个刚性投影批次，Native 不完整时整批切换到同一 Camera frame；RangeAssist 专用 Camera basis 正交单位化并要求有效 FOV，读数缺失时暂不绘制，恢复后继续；镜头 FOV 变化只参与当前透视，不重置已校准坐标比例；对玩家锚点偏移做会话有界稳定化。Presenter 按 raw UIParent 视口隐藏屏外点，保留可见范围弧段，未知视口保持有限坐标；只提交坐标/样式/可见性差异。半径配置始终保存游戏米，按需以 UnitDistance(target) 校准 worldUnitsPerMeter，高差或距离被拒绝的样本不更新屏幕比例；保留最多12条镜头位置/方向/圆心/比例诊断，分别记录镜头后方与投影平面附近的点；支持多圆列表、空默认配置、旧单圆存档迁移，以及每圆独立半径/点数/点大小/透明度/颜色并持久化", remainingCapability = "技能/魔法阵自动半径需要独立已验证的技能范围事实；当前只承诺用户自定义范围圆；无可靠目标样本时保留会话已核验值，从未校准时使用1:1；正常镜头远近/高度导致的透视变化仍保留，副本与高低差待RU实机复测", widgetCapable = false, settingsCapable = true, apiDependencies = { "X2Unit:GetUnitWorldPositionByTarget", "X2Unit:GetUnitScreenPosition", "X2Unit:UnitDistance" }, apiReadiness = "partial", apiPolicy = "bounded_user_radius" })
-- 中文维护（2026-09-12）：已接入的是计数/采样峰值与个人阈值提醒，不是经过实机证明的容量预警。
-- 元数据只说明产品/验收范围，不改变原route/Feature/Store身份，不用本地测试自动上移“已完成”。
-- 中文维护（2026-10-09）：Registry 统一提供导航/模块开关/方案/诊断身份。代码已落地但朝向轴与
-- 目标脚底投影尚待 RU 实机验收，继续标为未完成；不能以离线数学/Native 模型通过冒充实机。
Add("combat_facing_indicator", "combat.facing_indicator", "正面／背面指示器", "combat", 82,
    "当前目标脚下的红色正面弧与绿色背面弧，随目标移动和转身更新。", {
    navigationDevelopmentState="implemented_pending_ru", status="implemented_pending_ru", lifecycle="demand_scoped",
    authority="v3.facing_indicator + screen_projection_v3", widgetCapable=false, settingsCapable=true,
    manualAccessRequired=true, -- 中文维护：此功能默认隐藏；只有 rs_feature_access.lua 明确 true 才开放，存档已开启也不能绕过。
    diagnosticSources={"facing_indicator"}, -- 中文维护：采样/显示的限速错误源必须精确归属模块，不能在模块报告中静默漏掉。
    apiDependencies={"X2Unit:GetTargetUnitId","X2Unit:GetUnitWorldPositionByTarget","X2Unit:GetUnitScreenPosition","X2Unit:UnitDistance"},
    apiReadiness="official_enabled", apiPolicy="bounded_current_target_only", verification="pending_ru_facing_projection",
    currentImplementation="16ms Demand-scoped 当前目标两侧弧线和文字；单帧投影、目标身份校验、空朝向隐藏；半径/弧长/点大小/透明度/朝向校准永久设置",
    remainingCapability="目标模型与角度轴、玩家/NPC/首领脚底投影及镜头缩放待 RU 实机验收；弧长不是技能背击判定范围",
})
Add("combat_buff_cap", "combat.buff_cap", "增益容量监控", "combat", 85, "分别查看自身普通/隐藏增益数量、本次启用峰值；可保存个人数量提醒。个人阈值不代表 RU 容量或顶替规则。", {
    navigationDevelopmentState = "complete", -- 2026-10-06 用户要求标记完成；只影响导航展示。
    status = "migrated_partial", lifecycle = "demand_scoped", authority = "v3.buff_cap", widgetCapable = true, settingsCapable = true,
    apiDependencies = { "X2Unit:UnitBuffCount", "X2Unit:UnitHiddenBuffCount" }, apiReadiness = "partial", apiPolicy = "read_only",
    verification = "local_contract_verified_pending_ru_runtime",
    currentImplementation = "两类计数/未知值独立；本次启用峰值；个人整数阈值0关闭，默认提醒关闭；设置耐久保存回读。BUFF_UPDATE首次事件150ms合并+1秒兜底，每次仅两次自身计数读取；页面/其它消费者按需，明确启用的非零阈值提醒独立持有后台需求。关闭功能清任务/事件/提示；低优先级提醒让位其它来源，不依赖DPS或全Buff扫描",
    remainingCapability = "计数返回值、阈值提醒、输入/滚动、重载保存需集中RU实机验收；真实Buff容量、普通/隐藏槽位关系、顶替顺序未经验证，继续不推断容量风险",
    evidence = "Bundled X2Unit count getters and local Feature/Store/RSUI regression; no verified RU capacity or eviction threshold",
})
-- 中文维护（2026-10-02 用户重组）：职责保留历史 Feature ID/Store/route，页面名称改为职责设置；
-- 团队中心聚合页删除，牺牲之舞使用独立 Runtime 身份，开关/方案不再彼此连带。
Add("combat_team_tools", "combat.team_tools", "职责设置", "combat", 90, "设置当前玩家职责；按已验证职业组合自动匹配，全队名单仅供只读。", {
    status="migrated_partial", navigationDevelopmentState="complete", lifecycle="explicit_action", -- 中文维护（2026-10-03）：用户明确要求标记完成；统一导航/功能方案消费此开发态，历史身份、持久配置及能力限制继续沿用。
    authority="v3.team_tools", settingsCapable=true,
    apiDependencies={"X2Team:GetRole", "X2Team:SetRole", "X2Unit:GetTargetAbilityTemplates", "X2Unit:UnitName"},
    apiReadiness="official_mixed", verification="static_signature_verified_pending_ru_runtime",
    apiPolicy="explicit_write_plus_bounded_roster", evidence="Existing self-role write + independent auto-role roster lease; old Store identity preserved",
})
Add("combat_sac_highlight", "combat.sac_highlight", "牺牲之舞", "combat", 91, "高亮正在释放牺牲之舞的团队成员；保存、串行恢复团队头标。", {
    status="migrated_partial", navigationDevelopmentState="complete", lifecycle="explicit_action", -- 中文维护（2026-10-03）：按用户确认移入已完成导航；完成标记只影响展示，不扩大原生权限或改变独立开关/观察租约。
    authority="v3.team_visuals", settingsCapable=true,
    apiDependencies={"X2Unit:GetTargetAbilityTemplates", "X2Unit:UnitBuffCount", "X2Unit:UnitBuff", "X2Unit:GetOverHeadMarker", "X2Unit:SetOverHeadMarker"},
    apiReadiness="official_mixed", apiPolicy="bounded_shared_aura_plus_verified_marker_write",
    verification="static_signature_verified_pending_ru_runtime", evidence="Existing shared Aura/roster reads + 1100ms marker write/readback; visual Store schema2 preserved",
})
Add("combat_raid_readiness", "combat.raid_readiness", "团队战备检查", "combat", 92, "按需检查团队职责、关键增益、装分与职业准备状态，不依赖 DPS 常驻运行。", {
    -- 中文维护注释（B11团队战备检查闭环）：按需分片异步扫描团队装分（含RU千分位防御性解析）、职责/职业降级、关键增益（AuraObservationV3共享按需租约，仅扫描期持有）、距离与多状态收敛（ready/failed/unknown/info）、列表过滤（只看问题）、设置防抖持久化已全部闭环；标记为 implemented_pending_ru 待RU实机联调。
    navigationDevelopmentState = "implemented_pending_ru",
    navigationVisible = false, navigationParentRoute = "", -- 中文维护注释：战备检查仍是独立路由/按需扫描 Feature，但主导航视觉归属团队中心。
    status = "migrated_m16_14", lifecycle = "on_demand_scan", authority = "v3.raid_readiness + v3.team_roster + v3.aura_observation", diagnosticSources = { "raid_readiness_v3" },
    widgetCapable = false, settingsCapable = true, defaultEnabled = false,
    apiDependencies = { "X2Team:GetRole", "X2Unit:UnitGearScore", "X2Unit:UnitDistance", "X2Unit:UnitBuffCount", "X2Unit:UnitBuff", "X2Unit:UnitHiddenBuffCount", "X2Unit:UnitHiddenBuff" },
    apiReadiness = "partial", apiPolicy = "read_only_on_demand",
    evidence = "V3 TeamRoster + AuraObservation Phase 12B; TEAM interface id 38 from bundled apitypes and GetRole capability registry",
})
Add("combat_raid_recruitment", "combat.raid_recruitment", "团队招募助手", "combat", 94, "按需读取招募申请并允许关闭招募；创建、接受、拒绝在参数形态未验证前安全停用。", {
    navigationVisible = false, navigationParentRoute = "", -- 中文维护注释：招募助手保持独立显式动作生命周期，仅把侧栏选中态归到团队中心。
    status = "migrated_partial", lifecycle = "explicit_action", authority = "v3.raid_recruitment", settingsCapable = true,
    apiDependencies = { "X2Team:RaidRecruitDel", "X2Team:RaidApplicantList" }, apiReadiness = "partial", apiPolicy = "verified_subset_only",
    currentImplementation = "读取 RaidApplicantList；Close 走 RaidRecruitDel；Create/Accept/Reject fail-closed",
    remainingCapability = "RaidRecruitAdd 9 字段语义与 RaidApplicantAccept/Reject(charIds) 的 charIds 形态需 RU 实机验证",
    evidence = "Bundled X2Team signatures; only verified subset is exposed as executable",
})
Add("combat_siege_readiness", "combat.siege_readiness", "攻城战备检查", "combat", 96, "攻城场景专用的装备与团队准备检查，关闭后不保留高频观察。", {
    navigationVisible = false, navigationParentRoute = "", -- 中文维护注释：攻城战备即使处于 runtime-blocked，也属于团队中心子导航；不得因此绕过运行时阻塞。
    status = "runtime_blocked", runtimeBlocked = true, runtimeBlocker = "GetEquippedItemTooltipInfo 的装备字段结构与攻城场景判定 API 未在当前 RU 客户端验证", currentImplementation = "V3 页面显示精确阻塞，不对装备文本做猜测解析", remainingCapability = "需要稳定的 itemType/slot/装分返回字段和 siege context", lifecycle = "independent", authority = "v3.siege_readiness", widgetCapable = true,
    apiDependencies = { "X2Equipment:GetEquippedItemTooltipInfo", "X2Team:GetRole" }, apiReadiness = "research", apiPolicy = "read_only",
    evidence = "ArcheRage community Raidcheckersiege; exact remote equipment coverage requires RU runtime verification",
})
Add("combat_gear", "combat.gear", "换装 / 称号", "combat", 100,
    "装备、武器、防具、饰品与效果称号使用同一套方案保存和一键切换；每套常用方案可生成一个独立可拖动的屏幕按钮。", {
    status = "migrated_m4", lifecycle = "independent", authority = "v3.gear", diagnosticSources = { "gear_v3" },
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
    -- 中文维护注释（2026-09-15，用户验收）：活动按当前产品范围正式进入完成区。
    -- Authority 仍是 v3.activity，区域状态/服务器时钟/任务进度数据流不变；这里只改变导航开发态，
    -- 不把“完成”标签用于放宽 X2Map/X2Quest 能力门，也不改既有 Store/隐藏活动/悬浮窗配置兼容。
    navigationDevelopmentState = "complete",
    -- 中文维护注释（2026-09-18）：FeatureRegistry 只记录实现契约，不复制排序逻辑。Activity Timeline v2 的 Authority
    -- 仍在 rs_activity_authority.lua；这里明确性能边界，防止以后为了“更实时”把 timeUntil 的 OnUpdate/Quest 扫描重新接入模块元数据驱动。
    currentImplementation = "Activity Timeline v2：固定计划与可确定的实时派生活动进入时间线（当前活动按剩余结束时间、未来活动按距离开始时间）；战争/纷争/和平/危险阶段独立放在实时区域段，保持 curated 区域顺序；继续复用 QuestProgressV3、5s 区域采样与1s纯投影，不增加 Native 扫描",
    status = "migrated_m1", lifecycle = "independent", authority = "v3.activity", diagnosticSources = { "activities_v3" },
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
Add("life_trade", "life.trade", "跑商", "life", 20, "路线、多货物与实时货率；本地材料价立即计算毛利，过期价格后台静默重验，显式多货物询价只补缺价，每种材料最多读取当前页三条挂单，显示样本参考价。", {
    -- 中文维护注释（2026-09-23，trade-live-cargo-focus）：跑商继续使用 v3.life.trade 作为业务 Authority；
    -- 历史路线/收藏/HUD 仍保留在 v3.life.trade schema1，避免用户升级触发旧指纹迁移。新增的关注/自动刷新/随身扫描偏好
    -- 单独进入 v3.trade_preferences；查询调度仍维持 SingleFlight，不能因为新增随身扫描而并发 Native 请求。
    navigationDevelopmentState = "complete",
    status = "migrated_partial", lifecycle = "demand_scoped_with_background_refresh", authority = "v3.life.trade", diagnosticSources = { "trade_material_identity" }, widgetCapable = true, settingsCapable = true,
    -- 维护（2026-09-23，trade-runtime-metadata-1）：Feature 实现已把背包槽读取纳入 Authority，Registry 也必须
    -- 公开相同依赖，避免 Runtime/诊断在实现可用时却把元数据描述成旧能力集合。页面事件由 Demand 生命周期负责；普通路线自动刷新只额外持有独立轻量 Runtime owner。
    apiDependencies = {
        -- 维护（2026-09-28，trade-native-dependency-ownership-1）：Registry 必须与 Trade 实现层保持同一完整依赖。
        -- 材料身份读取属于 X2Craft；材料价格的 Ask/Read 与名称 fallback 属于 X2Auction。禁止再依赖其它 Feature
        -- 偶然先导入这些 namespace，否则“只开启跑商”会出现 host_global_missing/报价全失败。
        "X2Store:GetProductionZoneGroups", "X2Store:GetSellableZoneGroups", "X2Store:GetSpecialtyRatioBetween",
        "X2Ability:GetAllMyActabilityInfos",
        "X2Equipment:GetEquippedItemType", "X2Equipment:GetEquippedItemTooltipInfo",
        "X2Craft:GetCraftTypeByItemType", "X2Craft:GetCraftMaterialInfo", "X2Craft:GetCraftProductInfo",
        "X2Auction:AskMarketPrice", "X2Auction:GetLowestPrice", "X2Auction:SearchAuctionArticle",
        "X2Auction:GetSearchedItemCount", "X2Auction:GetSearchedItemInfo",
    },
    apiReadiness = "official_mixed", apiPolicy = "on_demand_server_query", currentImplementation = "路线/区域/服务器货率 + 满货率 130% 本地对比 + 经商熟练度售价估算；路线请求统一进入 SingleFlight 调度器；“自动刷新”由独立轻量 Runtime owner 保活，不再伪装成页面 Demand Consumer；该 Runtime 只持有 SPECIALTY_RATIO_BETWEEN_INFO 回执、可选跨区事件与 1 秒低频 Scheduler watchdog，默认约 10 秒（且不短于 2×Native cooldown）才真正请求一次。主页面关闭后仍可持续保持当前路线新鲜，同时 QuoteQueue/装备观察/LiveIdentity 等页面资源会真实释放。材料单位价由独立 MaterialPriceServiceV3 持久化到 v3.market.material_prices：打开/刷新路线先使用最后可信本地单价立即重算材料成本、毛利与毛利率，再仅对 Warm/Stale 已有缓存低优先级后台刷新；用户双击/批量多 RowJob 通过 TradeMaterialQuoteServiceV3 优先查询缺价，每个身份最多一次搜索、最多读取三条挂单，5秒内终态，但所有拍卖 Native 调用仍共用单一 PriceQuoteQueueV3 串行 lane 并按 itemType+grade 去重。货率/熟练度变化推进 payout revision，材料价变化推进 material revision，两者都重新派生利润，禁止保存独立旧毛利。全部/关注/随身三种投影视图继续保留；随身模式通过 ES_BACKPACK（缺失时使用已验证槽位27）识别当前贸易包。UNIT_EQUIPMENT_CHANGED 220ms 合并刷新，不使用 Tick。绑定/非市场制作资源保留配方数量但不伪造金币成本。路线/收藏/窗口继续使用历史 v3.life.trade schema1，新偏好独立保存于 v3.trade_preferences。", remainingCapability = "GetLowestPrice 返回形态、RU 生产/可售地区 payload、GetSpecialtyRatioBetween 数值返回的真实节流语义与静态底价长期一致性仍需实机验证；售价拆解需用多路线/多熟练度实售样本继续校准；自动制作台刷新/叛乱记录仍缺安全事件证据", evidence = "V3 Trade Authority + SPECIALTY_RATIO_BETWEEN_INFO + official X2Ability actability list + official X2Equipment:GetEquippedItemType/GetEquippedItemTooltipInfo + ES_BACKPACK slot authority + verified Trade Product ItemID registry; SingleFlight route/cargo scheduler + bounded favorites/tracked projection + shared TradeDetailFloatingV3 + explicit selected-row material quote",
})
Add("life_bonds", "life.bonds", "债券 / 居民板", "life", 30, "每日居民板材料、完成状态与背包资源。", {
    -- 中文维护注释（2026-09-15，用户验收完成）：债券当前产品范围已接受，导航不再标“未完成”。
    -- 这里只更新 Presentation 开发态；多大陆 dailySnapshots、任务状态、背包资源与 Store Authority 不受影响。
    -- 存档 historical canonical 修复在 Feature Store 自己声明，不能把“完成”当成绕过完整性检查的理由。
    navigationDevelopmentState = "complete",
    status = "migrated_m16_18", lifecycle = "demand_scoped", authority = "v3.life.bonds", widgetCapable = true, settingsCapable = true,
    apiDependencies = {
        "X2Resident:GetResidentBoardContent", "X2Bag:Capacity", "X2Bag:GetBagItemInfo",
        "X2Quest:GetActiveQuestListCount", "X2Quest:GetActiveQuestType",
        "X2Quest:IsCompleted", "X2Quest:IsReadyForCompleteQuest",
    }, apiReadiness = "official_mixed", apiPolicy = "on_demand_read_only",
    currentImplementation = "按服务器日期分别缓存 west/east/auroria 居民板快照；玩家在各大陆首次刷新后统一合并显示，表格显式标记大陆来源。排序方式（按大陆/按数量）、大陆顺序（西→东/东→西）与重复任务策略（全部/合并）相互独立；合并优先侧不会隐式开启去重。继续兼容 contents/content/rows/items 与稀疏数字行，并通过 activeIndex 联动任务状态。",
    evidence = "V3 Bonds + RU residentboard GetResidentBoardContent(index).contents 行为；未知字段继续 fail-closed；tools/rs_bonds_tests 与 v3_m1_bonds 门禁全绿",
})
Add("life_tasks", "life.tasks", "任务追踪", "life", 40, "用户选择的日常与周常任务追踪；支持子任务展开和独立悬浮追踪。", {
    navigationDevelopmentState = "complete", -- 2026-10-06 用户要求任务追踪标记完成；保留原有生命周期与存档契约。
    status = "migrated_m1", lifecycle = "independent", authority = "v3.tasks", diagnosticSources = { "tasks_v3" },
    widgetCapable = true, settingsCapable = true, defaultEnabled = true,
    apiDependencies = {
        "X2Quest:GetActiveQuestListCount", "X2Quest:GetActiveQuestType",
        "X2Quest:IsCompleted", "X2Quest:IsReadyForCompleteQuest", "X2Quest:GetQuestContextMainTitle",
    },
    apiReadiness = "read_only", apiPolicy = "on_demand_read_only",
    currentImplementation = "日常/周常独立选择、父任务逐项加入/取消追踪、仅追踪筛选与悬浮窗复用同一持久追踪集合；.18.119 将逐项操作直接显示为‘✓ 已追踪 / ＋ 可添加’，不再隐藏在选中后的按钮语义里",
    evidence = "V3 QuestProgressService shared projection; no legacy QuestService runtime dependency",
})
Add("life_treasure", "life.treasure", "寻宝", "life", 50, "藏宝图坐标、方向、距离与原生世界地图定位。", {
    status = "migrated_m16_18", lifecycle = "demand_scoped", authority = "v3.life.treasure", widgetCapable = true, settingsCapable = true,
    -- 中文维护注释（2026-09-16，寻宝地图定位）：InventorySnapshotV3 仍只提供共享背包事实；ShowWorldmapLocation 仅由用户点击触发。
    -- 中文维护（2026-10-09）：声明与实现保持一致；UnitScreen 只用于罗盘锚定，位置任务核对单槽，地图写仍须显式点击。
    apiDependencies = { "X2Bag:GetBagItemInfo", "X2Bag:Capacity", "X2Unit:GetUnitWorldPositionByTarget", "X2Unit:GetUnitScreenPosition", "X2Unit:GetCurrentZoneGroup", "X2Map:ShowWorldmapLocation" }, apiReadiness = "official_mixed", apiPolicy = "on_demand_read_plus_explicit_ui_action",
    currentImplementation = "InventorySnapshotV3 有限扫描 + 坐标字段识别 + 500ms 单槽核对/方向/距离 + 3 秒补采 + 33ms 共享刚性投影圆环/箭头；地图定位仅显式点击，Consumer=0 立即停两条任务并隐藏标记",
    evidence = "V3 Treasure map-location contract v2 + RU API ShowWorldmapLocation(zoneGroupId,globalX,globalY,z) + reference TreasureMapHunter targetZone,targetX,targetY call; fixed context-id 2 removed",
})
Add("life_fishing", "life.fishing", "钓鱼", "life", 60, "目标鱼动作识别、技能栏推荐与可逆自动 R；完整写键链已恢复。", {
  -- 中文维护注释（2026-09-15，用户验收完成）：钓鱼按当前产品范围进入完成区。
  -- Demand-scoped Buff 观察、FishingHotkeyV3 可逆事务、战斗中延迟恢复和持久恢复快照全部保持原 Authority；
  -- 这里只改变导航开发态，不把完成标签用于放宽 Native 写键能力门或热键 readback 安全检查。
  navigationDevelopmentState = "complete",
  status = "migrated_partial", lifecycle = "demand_scoped", authority = "v3.life.fishing", widgetCapable = true, settingsCapable = true,
  -- 中文维护：Fishing Authority 只在有页面/悬浮窗 Consumer 时观察目标；HotkeyV3 只拥有可逆写键事务，Persistence 仍由 Feature Store 持有，禁止回退成旧版强耦合服务。
  currentImplementation = "TARGET_CHANGED/BUFF_UPDATE + 100ms Demand-scoped 兜底扫描当前目标 Buff；支持多条鱼来回选中，推荐槽位相同也复核原生 R，丢失时才重映射；普通区域/ZoneGroup 49 独立动作映射；HotkeyContract v3 在首次写键前 durable 保存恢复快照，并逐次 Native readback 后才提交状态",
  -- 中文维护：当前 remainingCapability 只保留 RU 10.0 实机验收，不再把已具备事务/回滚证据的 Auto-R 错标为全局硬禁用；若实机暴露新 API 形态必须重新 fail-closed。
  remainingCapability = "待 RU 10.0 Fresh Reload 验证实际 R 源槽读取、多鱼来回切换（含相同动作 Buff 和延迟到达）、五种鱼动作连续切换、战斗中延迟恢复、ZoneGroup 49 与异常重载自动恢复；离线通过不等于实机完成",
  apiDependencies = { "X2Unit:UnitBuffCount", "X2Unit:UnitBuff", "X2Unit:GetCurrentZoneGroup", "X2Player:PlayerInCombat", "X2Hotkey:GetOptionBinding", "X2Hotkey:BindingToOption", "X2Hotkey:SetOptionBindingWithIndex", "X2Hotkey:RemoveOptionBinding", "X2Hotkey:SaveHotKey" },
  apiReadiness = "official_mixed_pending_ru", apiPolicy = "demand_scoped_reversible_hotkey_transaction",
  evidence = "Addon1.2 可用旧版的可逆 R 事务语义 + FishBuddy/Nuzi Fishing 一致动作 Buff IDs + V3 FishingHotkeyV3 transaction/readback/durable-recovery offline regressions; RU final acceptance pending",
})
-- 中文维护注释（2026-09-15，用户删除制作规划）：life.craft_planner 已从产品导航/Feature Registry 移除。
-- 旧 v3.business.life_craft_planner 存档不会主动清除；升级覆盖时即使磁盘残留旧扩展文件，toc.g 也不再加载它。
-- “制作台助手（tools_craft）”仍是独立功能，继续复用共享 CraftRead/CraftProjection，不受本删除影响。
Add("life_housing", "life.housing", "住宅 / 税务", "life", 80, "住宅名称、类型、所有者与当前税务信息；仅在住宅上下文按需读取。", {
    -- 中文维护注释（2026-09-15，用户删除选项卡）：只从主导航移除住宅/税务入口，不删除 Feature/Authority/Store。
    -- 这样旧路由、历史配置与后续内部调用仍兼容；用户主菜单不再暴露未完成入口，且不会因“删选项卡”误清用户数据。
    navigationVisible = false,
    navigationDevelopmentState = "incomplete", -- 中文维护（2026-09-13 用户实测）：住宅/税务当前功能覆盖仍不全面，继续留在“未完成”区。只调整 Presentation 开发态；既有只读 Authority、Demand 生命周期、存档与 API 门禁不变。
    status = "migrated_v3_read_only", lifecycle = "page_scoped", authority = "v3.housing", widgetCapable = false, settingsCapable = false,
    apiDependencies = { "X2House:GetCurrentHousingTaxInfo", "X2House:GetHouseOwnerName", "X2House:GetHouseName", "X2House:GetHouseType" },
    apiReadiness = "official", apiPolicy = "read_only", evidence = "ArcheRage RU official addon API update 2026-08-19; tools/rs_housing_tests.lua & v3_housing_read_only_contract pass",
})
-- 中文维护（2026-10-02 用户删除）：管家助手退出 Registry 与 toc，不参与启动、导航或方案。
-- 历史存档不清除；删除菜单功能不等于授权清空账号数据。

Add("tools_bag", "tools.bag_organizer", "整理背包", "tools", 10, "快速在背包与当前银行/保管箱之间整理同类物品；黑名单物品不会参与取放。", {
    navigationDevelopmentState = "complete", -- 中文维护注释：2026-09-10 用户已将整理背包列为完成；只改变左侧开发状态，现有 InventorySnapshotV3/显式 Move Authority、100ms 低成本窗口观察、250ms 串行写入与 fail-closed 边界全部保持。
    status = "migrated_partial", lifecycle = "independent_low_cost", authority = "v3.bag", settingsCapable = true, defaultEnabled = true,
    capabilities = { "category_batch", "scheduler_queue", "window_commands", "native_window_quick_take_put", "blacklist_filter", "read_verify_stop", "dynamic_source_resolution", "ru_identity_fallback", "shared_inventory_snapshot", "physical_bag_authority", "grouped_intent_queue", "quick_two_button_stop_switch", "quick_stale_run_self_heal", "batch_target_open_storage", "surface_action_visibility_split", "storage_session_bag_surface_fallback", "bag_action_physical_read_authority", "quick_released_host_recovery", "product_blacklist_ux", "blacklist_name_metadata", "blacklist_explicit_lookup" },
    scheduler = "InventorySnapshotV3 builds one bounded read/index snapshot per explicit plan (bagId=1 physical Authority with bounded bagId=0 fallback); Shared Scheduler serializes grouped same-item/category intent at 250ms; slotHint is revalidated before every write and quick/category tasks remain mutually exclusive; no per-frame polling",
    window = "默认启用的低成本窗口观察只读取背包/银行/箱子的几何与可见性；兼容 RU GetContentMainScriptPosVis 的 boolean/0-1/string/四值形态。动作 Authority 与显示 Surface 分离：仓储写入继续由当前打开仓储的严格事实 + 显式点击后的有界物理容器读取共同证明并 fail-closed；UIC_BAG 仅承担 Presentation 定位，不再作为取放动作 Authority。RU 打开银行/保管箱时若 UIC_BAG 仍是 hidden proxy，但 MainScript 已给出合法背包矩形，则可在“仓储 Surface 已可见”这一会话事实下仅用于显示/定位取放条，不放宽仓储写入门。悬浮快捷条提供「取 / 放 / 全放 / 设置」；取/放：空闲=开始，运行中点同一个=停止，点另一个=切换方向；使用真实 transient WINDOW 宿主，并在仓储可见期间以 100ms 低成本 heartbeat 有界重试 Presenter。同一个 100ms 观察任务兼任取放看门狗；物品扫描/移动仍只在显式点击后执行；用户显式关闭整理背包后观察任务立即释放。",
    blacklist = "主菜单与背包悬浮设置采用背包物品/黑名单列表、名称或ID筛选和行内加入/移出；可直接移除已不在背包的名单物品，也保留输入ID或当前背包/仓储名称添加。筛选只使用现有投影；来源变化独立刷新复用按钮身份，几何心跳不重绑物品表。保存仍以itemType为Authority，名称只作显示元数据。新增规则镜像到 bank/coffer 以保持现有运行时检查；旧 scope/category 规则继续兼容但不再占据主页面。",
    apiDependencies = {
        "X2Bag:Capacity", "X2Bag:GetBagItemInfo", "X2Bank:GetBagItemInfo", "X2Coffer:GetBagItemInfo",
        "X2Bag:MoveToEmptyBankSlot", "X2Bag:MoveToEmptyCofferSlot",
        "X2Bank:MoveToEmptyBagSlot", "X2Coffer:MoveToEmptyBagSlot",
        "ADDON:GetContent", "ADDON:GetContentMainScriptPosVis",
    },
    apiReadiness = "local_contract_verified_pending_native_runtime", verification = "v3_native_window_follow_contract_pending_ru_visual_runtime",
    apiPolicy = "read_plus_explicit_move", evidence = ".18.123 keeps the reference project as behavior evidence only and replaces its scan/queue mechanics with shared InventorySnapshotV3. The service normalizes native rows into detached primitives, prefers verified physical bagId=1 with bounded bagId=0 fallback, and builds identity/category indexes in the same pass. Quick take/put and category batch queue grouped stable intent rather than one record per transient slot, use live slot hints + wraparound revalidation before every write, and only run a bounded population count when the post-write source slot is ambiguous. The old production name+grade+category tuple remains a conservative fallback only when RU omits itemType. All writes stay explicit, 250ms serialized, mutually exclusive and fail-closed on read/verify/window changes. RU visual anchoring and long move timing still require Fresh Reload proof.",
})
-- 中文维护注释（2026-09-15，拍卖收藏玩家可见说明）：
-- 问题原因：Registry.description 会直接进入主页面标题说明，旧文案暴露“稳定分页/共享查询服务”等
-- 实现细节，却没有告诉玩家真正可见的 AuctionSidecar 工作区。Authority/数据流不在 Registry，
-- 这里只描述产品行为；查询仍由 AuctionQueryV3/AuctionSearchBridgeV3，Sidecar 生命周期仍由
-- AuctionSurfaceV3 + Presentation Controller 管理。兼容边界：不改 id/route/order/status/default/store/schema。
-- 实现理由：让主页面首屏先说明“收藏/今日任务/临时清单”与拍卖行助手关系。风险仅为展示文本变更，
-- 后续若 Sidecar 页签能力调整，应同步此说明，禁止在描述里重新暴露内部 API 契约。
Add("tools_auction", "tools.auction_favorites", "拍卖收藏", "tools", 20, "拍卖关键词收藏、当前挂单查询与拍卖助手管理；打开拍卖行后可使用收藏、今日任务和临时清单工作区。", {
    -- 中文维护注释（2026-09-15，用户验收后标记完成）：拍卖收藏的主页面入口、收藏 CRUD、
    -- Sidecar 三页签、独立悬浮开关与直接 AuctionQuery 降级路径已经形成完整用户闭环，用户明确要求
    -- 从“未完成”区移出。这里仅更新 Registry 产品/导航元数据，不改变 AuctionQueryV3 Authority、
    -- Store schema、Sidecar 生命周期或 API 能力门。原生搜索 EditBox 同步仍是可降级增强：失败时直接
    -- 查询路径保持可用，因此不再作为产品完成态 blocker。未来若核心 CRUD/查询/Sidecar 退化，应重新
    -- 标记 incomplete，而不是用可选增强的 RU 验证状态反向污染完成态。
    navigationDevelopmentState = "complete",
    status = "migrated_m1", lifecycle = "explicit_query", authority = "v3.auction", diagnosticSources = { "auction" }, widgetCapable = true, settingsCapable = true,
    apiDependencies = { "X2Auction:SearchAuctionArticle", "X2Auction:GetSearchedItemCount", "X2Auction:GetSearchedItemInfo", "X2Auction:GetLowestPrice", "ADDON:GetContent", "ADDON:GetContentMainScriptPosVis" },
    apiReadiness = "official_mixed", verification = "user_runtime_accepted_2026_09_15", apiPolicy = "explicit_server_query_plus_readonly_native_surface_observation",
    currentImplementation = ".18.213+：AuctionSidecar 为收藏/今日任务/临时三页签工作区；主页面可独立启停悬浮助手。DailyAuctionMaterialsV3 结合 QuestProgressV3 detached 活动任务目录与 TradeMaterialIdentityV3 已核配方识别明确区域做货任务；收藏、Session 临时清单和 AuctionSearchBridgeV3 搜索降级语义保持独立。原生搜索框同步属于可选增强，失败时仍直接走 AuctionQueryV3。",
    remainingCapability = "",
    evidence = "用户已于 2026-09-15 接受拍卖收藏产品闭环；UIC_AUCTION + ADDON:GetContent/GetContentMainScriptPosVis provide the native-surface fact; AuctionQueryV3 keeps sole un-tokened AUCTION_ITEM_SEARCHED ownership; local tests cover direct/fallback search, persistent Sidecar toggle, CRUD, tab demand release and trade-detail handoff."
})
Add("tools_market_analysis", "tools.market_analysis", "拍卖行情", "tools", 25, "显式查询当前拍卖挂单并分页查看价格、数量与卖家；不把当前挂单伪装成历史成交行情，也不后台持续扫拍卖行。", {
    -- 中文维护注释（2026-09-15，用户删除选项卡）：仅隐藏主导航；AuctionQueryV3 与旧路由保持存在，
    -- 避免拍卖收藏/诊断或历史配置因 UI 清理而失去共享查询 Authority。
    navigationVisible = false,
    status = "migrated_partial", currentImplementation = "AuctionQueryV3 提供按需当前挂单查询与 bounded 结果投影；页面明确标记“非历史成交价”，不后台扫拍卖行", remainingCapability = "真正历史行情仍需要稳定的成交/时间样本来源；当前 Search result 只能表示当前挂单", lifecycle = "explicit_query", authority = "v3.market_analysis", widgetCapable = false, settingsCapable = true,
    apiDependencies = { "X2Auction:SearchAuctionArticle", "X2Auction:GetSearchedItemCount", "X2Auction:GetSearchedItemInfo", "X2Auction:GetLowestPrice", "X2Auction:AskMarketPrice" },
    apiReadiness = "official", apiPolicy = "explicit_server_query", evidence = "Retained rs_auction_service.lua 9-parameter SearchInteractive + AuctionQueryV3 serialized completion ownership; history remains explicitly unclaimed",
})
Add("tools_craft", "tools.craft_assist", "制作台助手", "tools", 30, "制作台上下文的材料、持有量与缺口辅助；生命周期与跑商解耦，批量市场报价不在普通刷新执行。", {
    -- 中文维护注释（2026-09-15，用户删除选项卡）：制作台 Sidecar/CraftSurface 仍可能被原生制作窗口使用，
    -- 因此只删除主导航可见性，不物理删除 Feature/Service/Store；兼容现有设置且避免回退成强耦合。
    navigationVisible = false,
    navigationDevelopmentState = "incomplete", -- 中文维护（2026-09-13 用户实测）：制作台助手当前功能覆盖仍不全面，继续标记“未完成”。现有原生窗口观察、Sidecar 生命周期和无后台询价边界保持不变。
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
    -- 中文维护注释（2026-09-15，用户删除选项卡）：隐藏主导航但保留原 Feature 与 1 秒写冷却 Authority。
    -- 不删除旧配置、不改变好友/屏蔽/静音 API 写入边界；未来若重新启用入口无需迁移数据。
    navigationVisible = false,
    navigationDevelopmentState = "incomplete", -- 中文维护（2026-09-13 用户实测）：社交名单仍有产品能力缺口，显式固定为“未完成”，避免官方 API 完整度被启发式误判为产品已完成。现有 1 秒写冷却与 Authority 边界不变。
    status = "migrated_m16_18", lifecycle = "explicit_action", authority = "v3.social", settingsCapable = true,
    apiDependencies = { "X2Friend:IsMyFriend", "X2Friend:GetFriendList", "X2Friend:GetBlockList", "X2Friend:BlockUser", "X2Friend:UnblockUser", "X2Friend:GetMuteList", "X2Friend:MuteUser", "X2Friend:UnmuteUser" },
    apiReadiness = "official", apiPolicy = "cooldown_writes", evidence = "ArcheRage RU official addon API updates 2026-04-28 / 2026-08-05; central Api CapabilityCooldown contract enforces 1000ms writes",
})
Add("tools_feature_profiles", "tools.feature_profiles", "功能方案", "tools", 65,
    "自定义一组功能开关并生成屏幕快捷按钮；应用时开启已选功能、关闭其它可控业务功能，但保留各模块自己的配置。", {
    -- 中文维护注释（2026-09-25，feature-profile-v1）：方案不内置“生活/战斗”等语义；用户名称与选择是唯一配置。
    -- 应用事务只调用 FeatureRuntime 批量偏好接口，不直接碰其它 Feature Store/Consumer/Native UI。
    navigationDevelopmentState = "complete", -- 2026-10-05 用户明确要求“功能方案”标记完成，仅变更导航展示状态。
    status = "migrated_m1", lifecycle = "independent",
    authority = "v3.feature_profiles + FeatureRuntime preference transaction", diagnosticSources = { "feature_profiles_v3" },
    widgetCapable = true, settingsCapable = true, defaultEnabled = true, apiDependencies = {},
    apiReadiness = "none", apiPolicy = "feature_lifecycle_only",
    currentImplementation = "账号级最多16个自定义方案；方案保存开启集合，其余可控业务 Feature 在应用时关闭；FeatureRuntime 单次 durable 偏好事务 + 生命周期失败回滚；可捕获当前状态、重命名/删除/排序、按方案显示独立可拖动屏幕按钮；手动改变模块后显示方案已偏离。",
    remainingCapability = "需 RU 实机集中验收：多模块混合启停、正在显示页面/悬浮窗的关闭回收、快捷按钮拖动与不同分辨率恢复。",
    verification = "local_contract_verified_pending_ru_runtime",
    evidence = "FeatureRuntime is the existing lifecycle/preference Authority; feature-profile-v1 adds no gameplay/native API and local regression covers batch rollback + profile semantics.",
})
-- 2026-10-07 用户删除快捷键方案：不再登记目录、运行入口及原生目录探测；旧独立存档保留。

-- 个人工作台是应用设置页，无独立 Enabled / API / 性能负载，不注册业务实现。
Add("system_workspace", "system.workspace", "个性化工作台", "system", 5, "导航、首页与关注列表自定义。", { status="foundation", lifecycle="shell", authority="v3.workspace", verification="presentation_only" })
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
AssignGroup("combat_assist", 20, { "combat_healer", "combat_buff_display", "combat_buff_cap", "combat_boss_alerts", "combat_target_monitor", "combat_unit_lines", "combat_range_assist", "combat_facing_indicator" }) -- 中文维护：新功能归入现有战斗辅助组，不增加顶层导航分类。
AssignGroup("combat_team", 30, { "combat_team_tools", "combat_sac_highlight", "combat_raid_readiness", "combat_raid_recruitment", "combat_siege_readiness" })
AssignGroup("combat_loadout", 40, { "combat_gear" })

AssignGroup("life_schedule", 10, { "life_activities", "life_tasks" })
AssignGroup("life_economy", 20, { "life_trade", "life_bonds" })
AssignGroup("life_property", 30, { "life_housing" })
AssignGroup("life_leisure", 40, { "life_treasure", "life_fishing" })

AssignGroup("tools_inventory", 10, { "tools_bag", "tools_craft" })
AssignGroup("tools_market", 20, { "tools_auction", "tools_market_analysis" })
AssignGroup("tools_reference", 30, { "tools_instance_browser" })
AssignGroup("tools_social", 40, { "tools_social" })
AssignGroup("tools_profiles", 50, { "tools_feature_profiles" })

AssignGroup("system", 10, { "system_widgets", "system_features", "system_settings", "system_diagnostics" })
R:Resort()
