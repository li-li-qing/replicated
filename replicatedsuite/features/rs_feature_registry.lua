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
        navigationParentRoute = tostring(spec.navigationParentRoute or ""), -- 中文维护注释：隐藏语义子页可声明主导航父路由；这里只存展示元数据，绝不能改变 Feature 生命周期或 Authority。
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

Add("combat_stats", "combat.stats", "伤害统计", "combat", 10, "逐事件 PVP/PVE 分类的伤害、承伤与治疗统计；M1.16 起通过 CombatAnalytics 共享唯一 scope=all 战斗事实流。", {
    status = "migrated_m16", lifecycle = "independent", authority = "v3.dps + v3.combat_analytics", diagnosticSources = { "dps_v3" },
    widgetCapable = true, settingsCapable = true,
})
Add("combat_analytics", "combat.analytics", "战斗分析", "combat", 15, "模块化战斗贡献分析：战斗历史、击杀/助攻、技能、爆发、控制、乐器、辅助、Aura 与 Boss 机制；每个指标独立启停并共享单一 CombatEventBus 消费者。", {
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
    -- Authority 是 settings/layout/manifest 指向的 tracking slot。这里必须写清，避免维护者依据 Registry
    -- 又把 HUD/Tracking 保存接回旧单体 Store。AuraObservation 仍只负责运行时事实，不持有用户配置。
    status = "migrated_m16_18", lifecycle = "demand_scoped", authority = "v3.buff_display.settings + v3.buff_display.layout + v3.buff_display.tracking.manifest + v3.aura_observation (legacy v3.buff_display migration-only)", diagnosticSources = { "buff_display_v3" },
    widgetCapable = true, settingsCapable = true, defaultEnabled = false,
    apiDependencies = { "X2Unit:UnitBuffCount", "X2Unit:UnitBuff", "X2Unit:UnitBuffTooltip", "X2Unit:UnitDeBuffCount", "X2Unit:UnitDeBuff", "X2Unit:UnitDeBuffTooltip", "X2Unit:UnitHiddenBuffCount", "X2Unit:UnitHiddenBuff", "X2Unit:UnitHiddenBuffTooltip" },
    apiReadiness = "shared_service_partial", apiPolicy = "read_only_bounded",
    evidence = "AuraObservationV3:GetStatusMap(); V3 Page/Widget projection and lifecycle contract",
})
-- 中文维护（2026-09-12）：登记当前真实实现，不再声称事实桥尚未接入；仅本地回归通过，
-- 故保留 migrated_partial/未完成分桶。五条现有规则不代表全部首领技能，禁止据此自动宣告实机验收。
Add("combat_boss_alerts", "combat.boss_alerts", "首领机制 / 战斗警报", "combat", 50, "五条内置机制规则：逐条启停、实时施法/自身 Debuff 观察与屏幕提示。", { status = "migrated_partial", lifecycle = "demand_scoped", authority = "v3.boss_alerts + alerts_service", widgetCapable = false, settingsCapable = true, apiReadiness = "shared_service_partial", apiPolicy = "read_only_push_hud", currentImplementation = "稳定 key 规则开关与批量耐久保存、选中规则测试、四种 token 施法观察/自身 Debuff、同机制连续观察去重、真实剩余倒计时、HUD 字号/位置/时长", remainingCapability = "现有五条规则待 RU 实机核对语言/时序、重载保存、窄屏及缩放；不是全部首领机制库，不推测聊天或实体归属", verification = "ru_client_pending", evidence = "Boss RuleManagement v1 + CastingObservationV3 + AuraObservationV3 + Alerts owner-scoped presenter; local regression, no RU acceptance claim" })
Add("combat_target_monitor", "combat.target_monitor", "目标监控", "combat", 60, "按需追踪当前目标身份、名称与距离；不伪造仇恨目标。", { navigationVisible = false, status = "migrated_m16_18", lifecycle = "demand_scoped", authority = "v3.target_monitor", widgetCapable = true, apiDependencies = { "X2Unit:GetTargetUnitId", "X2Unit:UnitName", "X2Unit:UnitDistance" }, apiReadiness = "partial", apiPolicy = "on_demand_read_only", currentImplementation = "TARGET_CHANGED 即时刷新 + 500ms Demand-scoped 距离采样；Consumer=0 时任务和事件全部释放", remainingCapability = "仇恨目标需要独立、已验证的 RU 事实来源后再接入", evidence = "V3 target observation contract v1; event edge + bounded Scheduler distance refresh" })
-- 维护（用户实机确认2026-09-12）：当前约定范围标为完成并上移导航；技术能力限制仍如实保留，
-- 该展示覆盖不影响启停/调度/存档/允许API，不把附近单位枚举或自动技能半径视为已实现。
Add("combat_unit_lines", "combat.unit_lines", "单位连线", "combat", 70, "当前实现为自己 ↔ 当前目标的独立屏幕连线；不恢复官方禁用的附近单位枚举。", { navigationDevelopmentState = "complete", status = "migrated_partial", lifecycle = "demand_scoped", authority = "v3.unit_lines + screen_projection_v3", currentImplementation = "1-1000ms Demand-scoped 四类 token 连线 + 屏幕空间自适应密度/可见段裁剪/帧压力额外点预算 + P1 连续视觉刷新 + Presenter 本地 Diff/渐进点池；旧 pointCount 作为基础密度兼容保留；每线大小/颜色独立设置", remainingCapability = "全单位关系网络仍需要官方允许的单位集合来源；GetUnitsInSight 保持禁用", widgetCapable = false, settingsCapable = true, apiDependencies = { "X2Unit:GetUnitScreenPosition", "X2Unit:GetUnitWorldPositionByTarget" }, apiReadiness = "partial", apiPolicy = "bounded_current_target_only" })
-- 维护（用户实机确认2026-09-12）：当前约定范围标为完成并上移导航；技术能力限制仍如实保留，
-- 该展示覆盖不影响启停/调度/存档/允许API，不把附近单位枚举或自动技能半径视为已实现。
Add("combat_range_assist", "combat.range_assist", "范围辅助", "combat", 80, "以玩家为圆心绘制用户自建的多个范围圆；默认空配置，不猜技能/魔法阵真实范围。", { navigationDevelopmentState = "complete", status = "migrated_partial", lifecycle = "demand_scoped", authority = "v3.range_assist + screen_projection_v3", currentImplementation = "50ms Demand-scoped 范围绘制；半径配置始终保存游戏米，按需以 UnitDistance(target) 校准 worldUnitsPerMeter；EasyPull Camera fallback 再用 Native player/target 屏幕向量做 bounded 焦距比例校准并围绕玩家锚点整批等比缩放；支持多圆列表、空默认配置、旧单圆存档迁移，以及每圆独立半径/点数/点大小/透明度/颜色并持久化", remainingCapability = "技能/魔法阵自动半径需要独立已验证的技能范围事实；当前只承诺用户自定义范围圆；无可靠目标校准样本时 fail-closed 使用 1:1 世界单位/投影比例", widgetCapable = false, settingsCapable = true, apiDependencies = { "X2Unit:GetUnitWorldPositionByTarget", "X2Unit:GetUnitScreenPosition", "X2Unit:UnitDistance" }, apiReadiness = "partial", apiPolicy = "bounded_user_radius" })
-- 中文维护（2026-09-12）：已接入的是计数/采样峰值与个人阈值提醒，不是经过实机证明的容量预警。
-- 元数据只说明产品/验收范围，不改变原route/Feature/Store身份，不用本地测试自动上移“已完成”。
Add("combat_buff_cap", "combat.buff_cap", "增益容量监控", "combat", 85, "分别查看自身普通/隐藏增益数量、本次启用峰值；可保存个人数量提醒。个人阈值不代表 RU 容量或顶替规则。", {
    status = "migrated_partial", lifecycle = "demand_scoped", authority = "v3.buff_cap", widgetCapable = true, settingsCapable = true,
    apiDependencies = { "X2Unit:UnitBuffCount", "X2Unit:UnitHiddenBuffCount" }, apiReadiness = "partial", apiPolicy = "read_only",
    verification = "local_contract_verified_pending_ru_runtime",
    currentImplementation = "两类计数/未知值独立；本次启用峰值；个人整数阈值0关闭，默认提醒关闭；设置耐久保存回读。BUFF_UPDATE首次事件150ms合并+1秒兜底，每次仅两次自身计数读取；页面/其它消费者按需，明确启用的非零阈值提醒独立持有后台需求。关闭功能清任务/事件/提示；低优先级提醒让位其它来源，不依赖DPS或全Buff扫描",
    remainingCapability = "计数返回值、阈值提醒、输入/滚动、重载保存需集中RU实机验收；真实Buff容量、普通/隐藏槽位关系、顶替顺序未经验证，继续不推断容量风险",
    evidence = "Bundled X2Unit count getters and local Feature/Store/RSUI regression; no verified RU capacity or eviction threshold",
})
Add("combat_team_tools", "combat.team_tools", "团队中心", "combat", 90, "全队职责只读与当前玩家职责设置；可选牺牲之舞头顶高亮与团队头标方案保存/串行恢复；成员移动在无法合法证明队长权限时安全停用。", {
    -- 中文维护注释（B10团队中心闭环）：全队职责只读、当前玩家自身职责写入（含500ms冷却防抖）、职业模版自动职责匹配、头标快照保存（上限16）与1100ms串行恢复及回读校验、牺牲之舞候选发现及共享Aura投影全部通过单测与契约闭环；队长移动成员严格Fail-Closed停用；标记为 implemented_pending_ru 待RU实机联调。
    status = "migrated_partial", navigationDevelopmentState = "implemented_pending_ru", lifecycle = "explicit_action", authority = "v3.team_tools + v3.team_visuals", settingsCapable = true, apiDependencies = { "X2Team:GetRole", "X2Team:SetRole", "X2Unit:GetTargetAbilityTemplates", "X2Unit:UnitBuffCount", "X2Unit:UnitBuff", "X2Unit:GetOverHeadMarker", "X2Unit:SetOverHeadMarker" }, apiReadiness = "official_mixed", verification = "static_signature_verified_pending_ru_runtime", apiPolicy = "explicit_write_plus_bounded_shared_aura", currentImplementation = "TeamRoster 更新驱动的全队职责只读；X2Team:SetRole(role) 仅作为当前玩家职责写入；.18.122 增加按需牺牲之舞高亮（候选职业 10s/名单边发现、AuraObservationV3 共享 Buff 事实、仅激活时 50ms Presentation 投影）以及当前头标快照保存/按 1100ms 队列恢复并逐项 GetOverHeadMarker 读回验证；不会自动清除或覆盖未保存头标。成员移动按钮仍不可执行", remainingCapability = "MoveTeamMember/MoveTeamMemberToParty 仍需要允许使用的队长/权限 getter；当前 IsTeamOwner 明确 NotAllowed。牺牲之舞 Buff/屏幕位置与头标写入仍需 RU Fresh Reload 视觉/权限验证", evidence = "Bundled TMROLE_* + X2Team signatures; current RU capability list enables X2Unit Get/SetOverHeadMarker; user-provided legacy TeamUtility/ShinySac supplies Spelldance index 14 and Sac Buff IDs 30098/30137/30141/30142; shared TeamRosterV3/AuraObservationV3/ScreenProjectionV3 own reads"
})
Add("combat_raid_readiness", "combat.raid_readiness", "团队战备检查", "combat", 92, "按需检查团队职责、关键增益、装分与职业准备状态，不依赖 DPS 常驻运行。", {
    -- 中文维护注释（B11团队战备检查闭环）：按需分片异步扫描团队装分（含RU千分位防御性解析）、职责/职业降级、关键增益（AuraObservationV3共享按需租约，仅扫描期持有）、距离与多状态收敛（ready/failed/unknown/info）、列表过滤（只看问题）、设置防抖持久化已全部闭环；标记为 implemented_pending_ru 待RU实机联调。
    navigationDevelopmentState = "implemented_pending_ru",
    navigationVisible = false, navigationParentRoute = "combat.team_tools", -- 中文维护注释：战备检查仍是独立路由/按需扫描 Feature，但主导航视觉归属团队中心。
    status = "migrated_m16_14", lifecycle = "on_demand_scan", authority = "v3.raid_readiness + v3.team_roster + v3.aura_observation", diagnosticSources = { "raid_readiness_v3" },
    widgetCapable = false, settingsCapable = true, defaultEnabled = false,
    apiDependencies = { "X2Team:GetRole", "X2Unit:UnitGearScore", "X2Unit:UnitDistance", "X2Unit:UnitBuffCount", "X2Unit:UnitBuff", "X2Unit:UnitHiddenBuffCount", "X2Unit:UnitHiddenBuff" },
    apiReadiness = "partial", apiPolicy = "read_only_on_demand",
    evidence = "V3 TeamRoster + AuraObservation Phase 12B; TEAM interface id 38 from bundled apitypes and GetRole capability registry",
})
Add("combat_raid_recruitment", "combat.raid_recruitment", "团队招募助手", "combat", 94, "按需读取招募申请并允许关闭招募；创建、接受、拒绝在参数形态未验证前安全停用。", {
    navigationVisible = false, navigationParentRoute = "combat.team_tools", -- 中文维护注释：招募助手保持独立显式动作生命周期，仅把侧栏选中态归到团队中心。
    status = "migrated_partial", lifecycle = "explicit_action", authority = "v3.raid_recruitment", settingsCapable = true,
    apiDependencies = { "X2Team:RaidRecruitDel", "X2Team:RaidApplicantList" }, apiReadiness = "partial", apiPolicy = "verified_subset_only",
    currentImplementation = "读取 RaidApplicantList；Close 走 RaidRecruitDel；Create/Accept/Reject fail-closed",
    remainingCapability = "RaidRecruitAdd 9 字段语义与 RaidApplicantAccept/Reject(charIds) 的 charIds 形态需 RU 实机验证",
    evidence = "Bundled X2Team signatures; only verified subset is exposed as executable",
})
Add("combat_siege_readiness", "combat.siege_readiness", "攻城战备检查", "combat", 96, "攻城场景专用的装备与团队准备检查，关闭后不保留高频观察。", {
    navigationVisible = false, navigationParentRoute = "combat.team_tools", -- 中文维护注释：攻城战备即使处于 runtime-blocked，也属于团队中心子导航；不得因此绕过运行时阻塞。
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
    currentImplementation = "世界活动与实时区域状态监测；已修复海之烛台/鲸鱼歌湾任务组关联与阶段进度展示；已修复征兆/煦日等活动在任务进行中的尾部持续期保持；通过 rs_activity_tests 与 v3_m1_activities 验收",
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
Add("life_trade", "life.trade", "跑商", "life", 20, "路线、多货物与实时货率；材料身份/数量可读，材料报价与利润改为独立显式询价后再接回。", {
    -- 中文维护注释（2026-09-15，用户验收完成）：这里只把“跑商”从开发中分桶上移到完成区。
    -- Authority 仍是 v3.life.trade，SingleFlight/报价队列/收藏/HUD 生命周期和 Store 均不变化；
    -- remainingCapability 中的长期校准项继续作为维护备注，不能反向把用户已经接受的当前产品范围标成未完成。
    navigationDevelopmentState = "complete",
    status = "migrated_partial", lifecycle = "demand_scoped", authority = "v3.life.trade", diagnosticSources = { "trade_material_identity" }, widgetCapable = true, settingsCapable = true,
    apiDependencies = { "X2Store:GetProductionZoneGroups", "X2Store:GetSellableZoneGroups", "X2Store:GetSpecialtyRatioBetween", "X2Ability:GetAllMyActabilityInfos" },
    apiReadiness = "official_mixed", apiPolicy = "on_demand_server_query", currentImplementation = "路线/区域/服务器实时货率 + 满货率 130% 本地对比模式（持久化）+ 经商熟练度读取并按已提供旧版工作公式计入预计售价；TradePayoutV3 统一组合静态底价、实时/130% 货率、经商倍率与 TradeNameMultipliers 品类倍率，并恢复 larder/别名价格 Key 解析。路线收藏最多 12 条并由 life.trade 单 Store 持久化，主页面与 life.trade HUD 共用收藏/排序命令（排序为货率/售价/名字三态单选，名字模式 [xx] 前缀货物置顶）；选中贸易品复用 TradeDetailFloatingV3，详情仅在可见期持有独立 Consumer，并通过 QuoteRowMaterials 显式询价当前材料。普通 Refresh 不产生 Auction fan-out。", remainingCapability = "GetLowestPrice 返回形态、RU 生产/可售地区 payload 与静态底价长期一致性仍需实机验证；新增售价拆解需用多路线/多熟练度实售样本继续校准；自动制作台刷新/叛乱记录仍缺安全事件证据", evidence = "V3 Trade Authority + SPECIALTY_RATIO_BETWEEN_INFO + official X2Ability actability list + supplied working Trade payout formula; TradePayoutV3 price-key/larder/category multiplier contracts; bounded favorites + shared TradeDetailFloatingV3 + explicit selected-row material quote",
})
Add("life_bonds", "life.bonds", "债券 / 居民板", "life", 30, "每日居民板材料、完成状态与背包资源。", {
    -- 中文维护注释（2026-09-15，用户验收完成）：债券当前产品范围已接受，导航不再标“未完成”。
    -- 这里只更新 Presentation 开发态；多大陆 dailySnapshots、任务状态、背包资源与 Store Authority 不受影响。
    -- 存档 historical canonical 修复在 Feature Store 自己声明，不能把“完成”当成绕过完整性检查的理由。
    navigationDevelopmentState = "complete",
    status = "migrated_m16_18", lifecycle = "demand_scoped", authority = "v3.life.bonds", widgetCapable = true, settingsCapable = true,
    apiDependencies = { "X2Resident:GetResidentBoardContent", "X2Bag:Capacity", "X2Bag:GetBagItemInfo", "X2Quest:IsCompleted", "X2Quest:IsReadyForCompleteQuest" }, apiReadiness = "official_mixed", apiPolicy = "on_demand_read_only",
    currentImplementation = "按服务器日期分别缓存 west/east/auroria 居民板快照；玩家在各大陆首次刷新后统一合并显示，表格显式标记大陆来源。排序方式（按大陆/按数量）、大陆顺序（西→东/东→西）与重复任务策略（全部/合并）相互独立；合并优先侧不会隐式开启去重。继续兼容 contents/content/rows/items 与稀疏数字行，并通过 activeIndex 联动任务状态。",
    evidence = "V3 Bonds + RU residentboard GetResidentBoardContent(index).contents 行为；未知字段继续 fail-closed；tools/rs_bonds_tests 与 v3_m1_bonds 门禁全绿",
})
Add("life_tasks", "life.tasks", "任务追踪", "life", 40, "用户选择的日常与周常任务追踪；支持子任务展开和独立悬浮追踪。", {
    navigationDevelopmentState = "implemented_pending_ru", -- 中文维护注释：2026-09-13 完成子任务选中向父组定位（修复选中子行时无法追踪/无法查看详情）、补全“查看详情”按钮、增加统一服务器日期回退并经 10 套单测（tools/rs_task_tests.lua）与 v3_m1_tasks 门禁验证全绿；保留 implemented_pending_ru 待 RU 实测证据。
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
    -- 依赖声明用于 FeatureRuntime 惰性导入 BAG/MAP namespace，不代表后台会周期调用 X2Map；500ms Scheduler 仍只读取玩家位置。
    apiDependencies = { "X2Bag:GetBagItemInfo", "X2Bag:Capacity", "X2Unit:GetUnitWorldPositionByTarget", "X2Map:ShowWorldmapLocation" }, apiReadiness = "official_mixed", apiPolicy = "on_demand_read_plus_explicit_ui_action",
    currentImplementation = "InventorySnapshotV3 bounded 背包扫描 + 坐标字段跨语言藏宝图识别 + 500ms Demand-scoped 玩家位置/方向/距离刷新；选中藏宝图可显式打开原生世界地图定位；Consumer=0 立即停位置任务",
    evidence = "V3 Treasure observation contract v2 + user-supplied RU TreasureMapHunter ShowWorldmapLocation(2,x,y,0) behavior evidence; no external web map/runtime Legacy dependency",
})
Add("life_fishing", "life.fishing", "钓鱼", "life", 60, "目标鱼动作识别、技能栏推荐与可逆自动 R；完整写键链已恢复。", {
  -- 中文维护注释（2026-09-15，用户验收完成）：钓鱼按当前产品范围进入完成区。
  -- Demand-scoped Buff 观察、FishingHotkeyV3 可逆事务、战斗中延迟恢复和持久恢复快照全部保持原 Authority；
  -- 这里只改变导航开发态，不把完成标签用于放宽 Native 写键能力门或热键 readback 安全检查。
  navigationDevelopmentState = "complete",
  status = "migrated_partial", lifecycle = "demand_scoped", authority = "v3.life.fishing", widgetCapable = true, settingsCapable = true,
  -- 中文维护：Fishing Authority 只在有页面/悬浮窗 Consumer 时观察目标；HotkeyV3 只拥有可逆写键事务，Persistence 仍由 Feature Store 持有，禁止回退成旧版强耦合服务。
  currentImplementation = "TARGET_CHANGED/BUFF_UPDATE + 100ms Demand-scoped 兜底扫描全部目标 Buff；普通区域/ZoneGroup 49 独立动作映射；HotkeyContract v3 在首次写键前 durable 保存恢复快照，并逐次 Native readback 后才提交状态",
  -- 中文维护：当前 remainingCapability 只保留 RU 10.0 实机验收，不再把已具备事务/回滚证据的 Auto-R 错标为全局硬禁用；若实机暴露新 API 形态必须重新 fail-closed。
  remainingCapability = "待 RU 10.0 Fresh Reload 验证实际 R 源槽读取、五种鱼动作连续切换、战斗中延迟恢复、ZoneGroup 49 与异常重载自动恢复；离线通过不等于实机完成",
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
Add("life_butler", "life.butler", "管家助手", "life", 90, "预留管家充能/服务状态入口；当前只接纳已开放的充能信息 getter，不提前接未授权动作。", {
    navigationDevelopmentState = "incomplete", -- 中文维护（2026-09-13 用户实测）：管家助手现有充能/只读投影不足以覆盖完整产品需求，继续标记“未完成”。不回退已实现的动态宿主、事件发布与页面按需刷新。
    status = "migrated_v3_read_only", lifecycle = "page_scoped", authority = "v3.butler", widgetCapable = false, settingsCapable = false,
    apiDependencies = { "X2Butler:GetChargeInfo" }, apiReadiness = "official_narrow", apiPolicy = "read_only",
    evidence = "ArcheRage RU official addon API update 2026-08-26; capability surface is currently narrow",
})

Add("tools_bag", "tools.bag_organizer", "整理背包", "tools", 10, "快速在背包与当前银行/保管箱之间整理同类物品；黑名单物品不会参与取放。", {
    navigationDevelopmentState = "complete", -- 中文维护注释：2026-09-10 用户已将整理背包列为完成；只改变左侧开发状态，现有 InventorySnapshotV3/显式 Move Authority、100ms 低成本窗口观察、250ms 串行写入与 fail-closed 边界全部保持。
    status = "migrated_partial", lifecycle = "independent_low_cost", authority = "v3.bag", settingsCapable = true, defaultEnabled = true,
    capabilities = { "category_batch", "scheduler_queue", "window_commands", "native_window_quick_take_put", "blacklist_filter", "read_verify_stop", "dynamic_source_resolution", "ru_identity_fallback", "shared_inventory_snapshot", "physical_bag_authority", "grouped_intent_queue", "quick_two_button_stop_switch", "quick_stale_run_self_heal", "batch_target_open_storage", "surface_action_visibility_split", "storage_session_bag_surface_fallback", "bag_action_physical_read_authority", "quick_released_host_recovery", "product_blacklist_ux", "blacklist_name_metadata", "blacklist_explicit_lookup" },
    scheduler = "InventorySnapshotV3 builds one bounded read/index snapshot per explicit plan (bagId=1 physical Authority with bounded bagId=0 fallback); Shared Scheduler serializes grouped same-item/category intent at 250ms; slotHint is revalidated before every write and quick/category tasks remain mutually exclusive; no per-frame polling",
    window = "默认启用的低成本窗口观察只读取背包/银行/箱子的几何与可见性；兼容 RU GetContentMainScriptPosVis 的 boolean/0-1/string/四值形态。动作 Authority 与显示 Surface 分离：仓储写入继续由当前打开仓储的严格事实 + 显式点击后的有界物理容器读取共同证明并 fail-closed；UIC_BAG 仅承担 Presentation 定位，不再作为取放动作 Authority。RU 打开银行/保管箱时若 UIC_BAG 仍是 hidden proxy，但 MainScript 已给出合法背包矩形，则可在“仓储 Surface 已可见”这一会话事实下仅用于显示/定位取放条，不放宽仓储写入门。悬浮快捷条只有「取 / 放」两个按钮：空闲=开始，运行中点同一个=停止，点另一个=切换方向；使用真实 transient WINDOW 宿主，并在仓储可见期间以 100ms 低成本 heartbeat 有界重试 Presenter。同一个 100ms 观察任务兼任取放看门狗；物品扫描/移动仍只在显式点击后执行；用户显式关闭整理背包后观察任务立即释放。",
    blacklist = "普通玩家页面只暴露全局物品黑名单：可输入 ItemID、输入当前背包/仓储中的物品名称，或直接点击当前背包物品行；保存仍以 itemType 为 Authority，名称只作显示元数据。新增规则镜像到 bank/coffer 以保持现有运行时检查；旧 scope/category 规则继续兼容但不再占据主页面。",
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
-- 维护（2026-09-12）：新增观察闭环只消费已有只读getter，不扩大API门禁。设置永久保存，
-- 采样/起点/12条历史仅在Consumer存续期保留；本地测试不代替RU验收，导航继续未完成。
Add("tools_random_shop", "tools.random_shop", "随机商店计数", "tools", 100, "只读原始计数、观察差值及最近12条变化；可保存可见页自动读取与个人阈值提示。", {
    navigationDevelopmentState = "incomplete",
    status = "migrated_v3_read_only", lifecycle = "page_scoped", authority = "v3.random_shop", widgetCapable = false, settingsCapable = true,
    apiDependencies = { "X2Store:GetRandomShopStoreRefreshCount" }, apiReadiness = "official_narrow", apiPolicy = "read_only",
    verification = "local_contract_verified_pending_ru_runtime",
    currentImplementation = "默认手动读取；可选可见页1秒采样，需求归零/停用立即清任务与临时历史。严格整数/未知判定、下降及断档另起一段、手动重设起点。个人阈值0关闭，仅页内提示；偏好经独立Store耐久保存回读，失败不冒充成功。",
    remainingCapability = "原始计数含义、商店上下文覆盖、输入/滚动与重载待集中RU验收；无商店身份/周期证据，不推算每日额度/剩余/花费，不调用商店刷新或购买。",
    evidence = "Bundled allowed GetRandomShopStoreRefreshCount() and existing capability entry (2026-08-26); random-shop-observer-1 local regression, no RU acceptance claim",
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
AssignGroup("life_economy", 20, { "life_trade", "life_bonds" })
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
