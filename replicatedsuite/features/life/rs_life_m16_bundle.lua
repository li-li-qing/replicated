-- 维护（2026-09-18，startup-source-recovery）：本文件在故障包中有 2 处未解决的 Git 合并冲突。
-- 已对照用户此前完整 V3 工程恢复有效实现；Authority、调用数据流和存档协议仍由下方原实现负责，
-- 不通过清配置、跳过加载或恢复 Legacy 绕过错误。兼容边界：须与完整 toc.g 及 .18.247 UI 配套；
-- 后续合并必须先检查冲突标记、清单完整性与 Lua 语法，再做运行时验收；注释不增加运行期开销。
------------------------------------------------------------------------
-- Replicated Suite V3 - Life vertical slice (Trade / Bonds / Treasure / Fishing)
--
-- This file is deliberately self-contained: the four domains own their
-- projections, commands, persistence and lifecycle.  Legacy services are not
-- imported or started.  Every game read/write crosses S.Api and every API
-- shape is normalized before it reaches Presentation.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local P, Runtime, Demand = S.Persistence, S.FeatureRuntime, S.Demand
if type(P) ~= "table" or type(Runtime) ~= "table" or type(Demand) ~= "table" then return end
-- Active V3 code never resolves game namespaces as bare globals.  Capture the
-- host objects once through the guarded global table; every later call still
-- crosses S.Api and therefore remains capability-gated.
local StoreApi = rawget(_G, "X2Store")
local AuctionApi = rawget(_G, "X2Auction")
local ResidentApi = rawget(_G, "X2Resident")
local BagApi = rawget(_G, "X2Bag")
local UnitApi = rawget(_G, "X2Unit")
local AbilityApi = rawget(_G, "X2Ability")
local EquipmentApi = rawget(_G, "X2Equipment")

S.Features = S.Features or {}

local function Copy(value)
    if S.Utils and type(S.Utils.DeepCopy) == "function" then return S.Utils.DeepCopy(value) end
    return value
end

local function Call(capability, object, method, ...)
    if S.Api == nil or type(S.Api.CallCapability) ~= "function" then
        return false, nil, "API boundary unavailable"
    end
    -- API namespaces are imported lazily by FeatureRuntime after this file is
    -- loaded. A load-time rawget may therefore be nil even though the namespace
    -- becomes valid before the first feature read. Let the central API boundary
    -- resolve a nil host from the registered capability at call time.
    local host = object
    if host == nil or (method and host[method] == nil) then
        local ns = capability:match("^([^:]+)")
        if ns then host = rawget(_G, ns) or host end
    end
    return S.Api:CallCapability(capability, host, method, ...)
end

local function Action(capability, object, method, ...)
    if S.Api == nil or type(S.Api.ActionCapability) ~= "function" then
        return false, "API boundary unavailable"
    end
    local host = object
    if host == nil or (method and host[method] == nil) then
        local ns = capability:match("^([^:]+)")
        if ns then host = rawget(_G, ns) or host end
    end
    return S.Api:ActionCapability(capability, host, method, ...)
end

local function PersistLifeMutation(feature, reason, mutator)
    if type(P.MutateStore) ~= "function" then return false, "Persistence mutation transaction unavailable" end
    return P:MutateStore(feature.storeId, function()
        return mutator(feature.State)
    end, { delayMs = 300, reason = reason or "life_feature_changed" })
end

local function InstallLifeWidgetContract(feature, policy)
    feature.WidgetWindowPolicy = policy
    function feature:GetWidgetWindowPolicy() return Copy(self.WidgetWindowPolicy) end
    function feature:GetWidgetVisible() return self.State and self.State.widgetVisible == true or false end
    function feature:GetWidgetWindowState()
        local value = self.State and self.State.widgetWindow or nil
        local floating = S.RSUI and S.RSUI.FloatingSurface or nil
        if type(floating) == "table" and type(floating.NormalizeState) == "function" then
            return Copy(floating:NormalizeState(value, self:GetWidgetWindowPolicy()))
        end
        return Copy(value)
    end
    function feature:SetWidgetWindowState(value, reason)
        if type(value) ~= "table" or type(self.State) ~= "table" then return false, "生活悬浮窗状态不可用" end
        if type(P.PrepareWrite) == "function" then
            local prepared, prepareErr = P:PrepareWrite(self.storeId)
            if prepared ~= true then return false, prepareErr or "生活悬浮窗配置尚未安全读取" end
        end
        local floating = S.RSUI and S.RSUI.FloatingSurface or nil
        self.State.widgetWindow = type(floating) == "table" and type(floating.NormalizeState) == "function"
            and floating:NormalizeState(value, self:GetWidgetWindowPolicy()) or Copy(value)
        return true
    end
    function feature:SetWidgetVisible(value, reason)
        return PersistLifeMutation(self, "widget_" .. tostring(reason or "visibility"), function(state)
            state.widgetVisible = value == true
            return true
        end)
    end
    function feature:MarkStoreDirty(delayMs, reason)
        if P and type(P.MarkDirty) == "function" then return P:MarkDirty(self.storeId, tonumber(delayMs) or 250, reason or "life_widget_state") end
        return false, "persistence unavailable"
    end
end

local function PublishFeatureUpdate(feature, revision, reason)
    if type(feature) ~= "table" or type(feature.UpdateTopic) ~= "string" then return false end
    if S.Events ~= nil and type(S.Events.Publish) == "function" then
        return S.Events:Publish(feature.UpdateTopic, tonumber(revision) or 0, tostring(reason or "refresh"))
    end
    return false
end

-- migrate MUST be a pure per-value normalizer: it doubles as the Integrity v3
-- canonical function. The old `migrate = default` passed a function that
-- IGNORES its input and always builds a fresh default table, which made the
-- canonical fingerprint CONTENT-BLIND (every value hashed to the default
-- shape, so real corruption verified as healthy).
-- 维护：历史桥作为 Store 声明注册，不在运行中偷偷修改 Core/其他模块。旧调用参数仍兼容。
local function RegisterStore(id, owner, default, get, apply, migrate, budget, rebuildCanonicalForIntegrity)
    if P:GetStore(id) == nil then
        local store, err = P:RegisterV3Store({
            id = id, owner = owner, scope = P.Scope.Account, lifetime = P.Lifetime.Permanent,
            schemaVersion = 1, legacySchemaVersion = 0, key = P.V3KeyPrefix .. id:gsub("[^%w]", "_"),
            budget = budget or { maxDepth = 6, maxNodes = 320, maxStringBytes = 8192, maxEntriesPerTable = 160 },
            default = default, get = get, apply = apply, migrate = migrate or default,
            rebuildCanonicalForIntegrity = rebuildCanonicalForIntegrity, -- 维护：仅显式声明的 Store 启用；其他生活模块不受影响。
        })
        if store == nil then error(err or ("store register failed: " .. id)) end
    end
end

local function LoadStore(feature)
    if feature.storeLoaded == true then return true end
    if P:GetStore(feature.storeId) == nil then return false, "store unavailable: " .. feature.storeId end
    local status, _, err = P:LoadStore(feature.storeId)
    if status ~= true and status ~= "empty" then return false, err or tostring(status or "store load failed") end
    feature.storeLoaded = true
    return true
end

local function Number(v) return tonumber(v) end
local function Text(v, fallback)
    if v == nil then return fallback or "" end
    return tostring(v)
end

local function Money(v, fallback)
    if v == nil then return fallback or "--" end
    local utils = S.Utils
    if type(utils) == "table" and type(utils.FormatMoney) == "function" then
        local n = tonumber(v)
        if n ~= nil then
            local ok, text = pcall(utils.FormatMoney, n)
            if ok and type(text) == "string" and text ~= "" then return text end
        end
    end
    return tostring(v)
end

------------------------------------------------------------------------
-- Trade
------------------------------------------------------------------------
local Trade = { Id = "life_trade", storeId = "v3.life.trade", preferenceStoreId = "v3.trade_preferences", enabled = false, storeLoaded = false, preferenceStoreLoaded = false }
S.Features.Trade = Trade
Trade.UpdateTopic = "v3.life.trade.updated"
Trade.State = { fromZone = nil, toZone = nil, favorites = {}, sortMode = "ratio", ratioMode = "current", commerceMode = "observe", widgetVisible = false, widgetWindow = nil }
-- 维护（2026-09-23，trade-preferences-split-1）：关注货物/显示模式/自动刷新是新能力，禁止直接扩展
-- 历史 v3.life.trade schema1。旧 Store 曾有实档指纹恢复桥；把新字段塞进去会让升级用户重新走完整性迁移。
-- 因此使用独立 schema1 Store，业务路线/收藏/悬浮窗继续由旧 Store Authority 管理。
Trade.Preferences = { viewMode = "all", trackedProducts = {}, autoRefresh = true, cargoScan = true }
Trade.Authority = { version = 9, revision = 0, zones = {}, sellableZones = {}, rows = {}, rawRows = {}, selectedKey = nil, status = "idle", error = nil, inFlight = nil, zoneFallback = false, sellableFallback = false, sellableError = nil, commerceSkill = nil, commerceStatus = "idle", commerceName = nil, commerceError = nil }
InstallLifeWidgetContract(Trade, { defaultWidth = 410, defaultHeight = 306, minWidth = 320, minHeight = 228, defaultOverallOpacity = 0.94, defaultBackgroundOpacity = 1.0, defaultTextOpacity = 1.0 }) -- 中文维护注释：跑商悬浮窗默认尺寸收敛到紧凑 HUD；只改变 Window policy，货率 Authority/请求生命周期不受影响。
local TradeWidgetWindowStateBase = Trade.GetWidgetWindowState -- 中文维护注释：保留统一 FloatingSurface 状态读取入口，只在展示边界兼容旧默认尺寸，不改写持久化权威。
function Trade:GetWidgetWindowState() -- 中文维护注释：跑商悬浮窗使用只读兼容投影，避免为纯 UI 紧凑化引入 Store schema/fingerprint 迁移风险。
    local state = TradeWidgetWindowStateBase(self) -- 中文维护注释：先交给统一 FloatingSurface policy 归一化位置、透明度、锁定与当前尺寸。
    if type(state) == "table" and Number(state.width) == 470 and Number(state.height) == 374 then -- 中文维护注释：仅识别历史版本精确默认 470x374，绝不压缩玩家主动保存的其他自定义尺寸。
        state.width, state.height = 410, 306 -- 中文维护注释：把旧默认展示为新版紧凑尺寸；这里不修改 Trade.State，因此旧存档完整性指纹保持原样。
    end -- 中文维护注释：结束历史默认尺寸兼容分支。
    return state -- 中文维护注释：Presentation 只消费兼容后的副本；后续用户真实拖拽/缩放仍由统一 SetWidgetWindowState 持久化。
end -- 中文维护注释：结束跑商悬浮窗兼容状态读取。
local TA = Trade.Authority
-- 维护（2026-09-24，trade-native-callback-lease-1）：SPECIALTY_RATIO_BETWEEN_INFO 是已发 Native 请求的回执，
-- 生命周期不能跟瞬时 UI Consumer 完全绑定。页面切换时 Demand 可能短暂 1->0；旧版此时立即 Unsubscribe + 清 inFlight，
-- 已被 X2Store 接受的请求随后回调无人接收，下一次打开只能再等一个 Native 窗口。单独的轻量 owner 只持有这一条回执事件；
-- 装备/跨区等观察事件仍严格随 Consumer 释放。它不主动发请求，不形成后台扫描。
Trade.nativeRatioEventOwner = { Id = "life_trade.native_ratio_callback" }
Trade.nativeRatioSubscribed = false
local TraceInit -- forward declaration: diagnostics ring is used by cargo/equipment helpers defined before its implementation.
TA.RouteRefreshRetryContractVersion = 3
TA.SingleFlightLatestRouteContractVersion = 1
TA.RequestTimeoutContractVersion = 3
TA.NativeCooldownContractVersion = 4
TA.QuerySchedulerContractVersion = 2
TA.AutoRefreshContractVersion = 3
TA.AutoRefreshWatchdogContractVersion = 3
TA.RatioFastPublishContractVersion = 2
-- 中文维护注释（2026-09-26，trade-auto-refresh-runtime-split-1）：自动货率刷新不再伪装成普通页面 Consumer。
-- 旧版 auto:trade_ratio 塞进 Trade.Demand 后，会让页面关闭时 consumerCount 永远不归零，连带保活报价订阅、装备观察、
-- LiveIdentity 等本应属于可见页面的资源；同时 no_consumers 清理边沿也失去真实语义。现在拆成独立轻量 Runtime Owner：
-- 只持有 1 个低频 Scheduler watchdog、SPECIALTY_RATIO_BETWEEN_INFO 回执和可选跨区事件。Native 查询仍只有 TA:Request
-- SingleFlight Authority；关闭跑商/自动刷新/进入随身模式后立即释放后台 Runtime，不影响真实页面 Consumer 生命周期。
Trade.AutoRefreshBackgroundLeaseContractVersion = 2 -- 兼容旧门禁字段；v2 语义已从 Demand lease 升级为独立 Runtime owner。
Trade.AutoRefreshRuntimeContractVersion = 1
Trade.autoRefreshRuntimeOwner = { Id = "life_trade.auto_refresh" }
Trade.autoRefreshWorldSubscribed = false
TA.NativeCallbackLeaseContractVersion = 1
TA.CargoObservationContractVersion = 2
TA.PreferenceProjectionContractVersion = 1
TA.requestTimeoutTask = "v3_trade_route_timeout"
TA.timeoutDrainTask = "v3_trade_timeout_drain"
TA.requestDeferredTask = "v3_trade_route_deferred"
TA.requestAutoTask = "v3_trade_route_auto_refresh_watchdog"
TA.equipmentRefreshTask = "v3_trade_equipment_refresh"
TA.cargoPumpTask = "v3_trade_cargo_pump"
TA.cargoRescanTask = "v3_trade_cargo_rescan"
TA.materialProjectionTask = "v3_trade_material_projection_deferred"
TA.requestSerial = tonumber(TA.requestSerial) or 0
TA.pendingRoute = nil
TA.pendingRetryCount = nil
TA.timedOutFlight = nil
TA.responseSlaMs = 6500
-- A callback carries no request-id. After a timeout, keep the lane empty briefly so a late callback
-- can be consumed as the timed-out flight instead of being misattributed to the next request.
TA.timeoutDrainMs = 2000
TA.timeoutDrainUntil = tonumber(TA.timeoutDrainUntil) or 0
TA.lastNativeCooldownMs = tonumber(TA.lastNativeCooldownMs) or 0
TA.nextNativeRequestAt = tonumber(TA.nextNativeRequestAt) or 0
TA.lastResponseTimeoutMs = tonumber(TA.lastResponseTimeoutMs) or 6500
TA.sellableCache = {}
TA.lastCompletedRoute = nil
TA.lastRatioAt = tonumber(TA.lastRatioAt) or 0
-- 维护（2026-09-23，trade-route-session-cache-1）：路线切换受 RU Native 查询冷却限制，且回调没有 request-id，
-- 因此不能靠并发“抢跑”来消除等待。这里增加仅本次插件加载有效的路线快照缓存：已经成功查过的路线再次
-- 选中时立即恢复上一份真实货率，并在后台等合法 Native 窗口刷新。缓存不是服务器 Authority、不写存档，
-- UI 会继续按 lastRatioAt 显示数据年龄；最多保留 12 条路线，避免长期会话无界增长。
TA.routeCache = {}
TA.routeCacheOrder = {}
TA.routeCacheMax = 12
-- 维护（2026-09-24，trade-auto-refresh-headroom-1）：RU Native 当前实机返回 5000ms 查询窗口。旧版自动刷新也按 5 秒
-- 紧贴窗口执行，等价于几乎永久占满下一次合法请求机会；用户切收藏/目的地时自然总撞 cooldown。自动刷新仍保持
-- 足够实时，但至少预留一个完整 Native cooldown 的交互空窗：默认 10 秒，且不低于最近 Native cooldown 的 2 倍。
-- 用户手动路线/跨区刷新仍是高优先级；这里只调整低优先级后台刷新，不改变服务器 Authority。
TA.autoRefreshTargetMs = 10000
TA.autoRefreshCooldownFactor = 2
TA.autoRefreshWatchIntervalMs = 1000
TA.autoRefreshDiagnostics = { watchStarts = 0, watchRestarts = 0, staleRestarts = 0, checks = 0, triggered = 0, skippedBusy = 0, skippedFresh = 0, lastCheckAt = 0, lastCheckGapMs = 0, maxCheckGapMs = 0, lastTriggerAt = 0, lastDecision = "idle", lastReason = "" }
-- 维护（2026-09-27，trade-profit-swr-carry-forward-1）：货率 fast-publish 与材料派生 one-shot 分离后，
-- 必须单独观察“是否排上/是否真正执行”。旧诊断只有 fastPublishes/deferredRebuilds，无法区分 no_consumer、
-- Scheduler 拒绝、任务被替换或预算延迟；本结构只记录 O(1) 调度事实，不扫描任务表、不触发业务读取。
TA.materialProjectionDiagnostics = { scheduleAttempts = 0, scheduleAccepted = 0, scheduleFailures = 0, runs = 0, lastScheduledAt = 0, lastRunAt = 0, lastReason = "", lastError = nil }
TA.cargoRescanIntervalMs = 15000
-- 维护（2026-09-23，trade-cargo-native-budget-1）：随身扫描是低优先级后台消费者。即使某个 RU 客户端
-- 对 GetSpecialtyRatioBetween 的数值返回语义发生变化，也至少保持 1 秒 Native 间隔；正常情况下更大的
-- 服务器返回节流仍优先生效。这样不会因错误把 0/小数值解释成 cooldown 而对几十个目的地形成短时请求风暴。
TA.cargoMinIntervalMs = 1000
TA.cargo = { status = "empty", itemType = nil, legacyName = nil, name = nil, originZone = nil, results = {}, queue = {}, generation = 0, scanning = false, lastScanAt = 0, scanStartedAt = 0, error = nil, slot = nil, slotSource = nil, identityReadSource = nil, rawItemType = nil, tooltipName = nil, legacyEstBackpack = nil }
TA.requestTrace = {}
TA.TradePayoutProjectionContractVersion = 1
Trade.MaterialPriceCacheContractVersion = 1
Trade.BackgroundMaterialRevalidateContractVersion = 1
Trade.EconomicsRevisionContractVersion = 1
TA.economics = { payoutRevision = 0, materialRevision = 0, rebuilds = 0, lastReason = "init", lastAt = 0 }
function TA:MarkEconomicsPayoutInput(reason)
    local state = type(self.economics) == "table" and self.economics or {}
    self.economics = state
    state.payoutRevision = (tonumber(state.payoutRevision) or 0) + 1
    state.lastReason = tostring(reason or "payout_input")
    state.lastAt = type(S.NowMs) == "function" and tonumber(S.NowMs()) or 0
    return state.payoutRevision
end
function TA:SyncEconomicsMaterialRevision(reason)
    local state = type(self.economics) == "table" and self.economics or {}
    self.economics = state
    local service = S.Services and S.Services.MaterialPriceServiceV3 or nil
    local revision = type(service) == "table" and type(service.GetRevision) == "function" and tonumber(service:GetRevision()) or 0
    state.materialRevision = revision or 0
    if reason ~= nil then state.lastReason = tostring(reason) end
    state.lastAt = type(S.NowMs) == "function" and tonumber(S.NowMs()) or state.lastAt
    return state.materialRevision
end
local TRADE_CONTINENT_ORDER = { west = 1, east = 2, auroria = 3, other = 4 }
local TRADE_ANCHORS_W = { [1] = true, [5] = true, [8] = true, [20] = true }
local TRADE_ANCHORS_E = { [4] = true, [12] = true, [17] = true }
-- Official ArcheAge trade-pack demand caps at 130%. Current/full ratio remains
-- a local comparison mode. Commerce proficiency and pack-category multipliers
-- are now restored through TradePayoutV3 from the supplied working implementation;
-- X2Store/X2Ability remain the live fact Authorities.
local TRADE_FULL_RATIO = 130
local TRADE_RATIO_MODES = { current = true, full = true }
local TRADE_COMMERCE_MODES = { observe = true, off = true }
-- Sort modes are a closed set shared by Authority normalization and the
-- page/widget selectors: ratio (default), price, name ([]-prefixed first).
local TRADE_SORT_MODES = { ratio = true, price = true, name = true }
local TRADE_VIEW_MODES = { all = true, tracked = true, cargo = true }
local TRADE_COMMERCE_NAMES = { ["Commerce"] = true, ["经商"] = true, ["贸易"] = true, ["Торговля"] = true }

local function StaticTradeZones()
    local result = {}
    local byId = S.GameIds and S.GameIds.Zone and S.GameIds.Zone.ById or nil
    if type(byId) ~= "table" then return result end
    for id, row in pairs(byId) do
        id = Number(id)
        if id ~= nil and type(row) == "table" then
            result[#result + 1] = { id = math.floor(id), name = "地区 " .. tostring(math.floor(id)) .. (row.nameEn and (" · " .. tostring(row.nameEn)) or ""), continent = "" }
        end
    end
    return result
end

local function NormalizeTradeZones(value)
    local result, seen = {}, {}
    for key, row in pairs(type(value) == "table" and value or {}) do
        local id, name, continent
        if type(row) == "table" then
            id = Number(row.id or row.zoneGroupId or row.zoneGroup or row.zoneGroupType or row[1])
            name = row.zoneGroupName or row.name or row[2]
            continent = row.continentName or row.continent
        elseif row == true then
            -- ArcheRage RU can expose zone groups as a set: { [zoneGroupId] = true }.
            -- Treat the numeric key as the identity; `true` is membership, never a name.
            id = Number(key)
        elseif type(row) == "number" then id = row
        elseif type(row) == "string" then
            local numericValue = Number(row)
            if numericValue ~= nil then id = numericValue else id, name = Number(key), row end
        end
        if id ~= nil and not seen[id] then
            seen[id] = true
            local displayName = Text(name, "")
            if displayName == "" or displayName == tostring(math.floor(id)) then displayName = "地区 " .. tostring(math.floor(id)) end
            result[#result + 1] = { id = math.floor(id), name = displayName, continent = Text(continent, "") }
        end
    end
    local westName, eastName
    for _, row in ipairs(result) do
        if TRADE_ANCHORS_W[row.id] and row.continent ~= "" then westName = westName or row.continent end
        if TRADE_ANCHORS_E[row.id] and row.continent ~= "" then eastName = eastName or row.continent end
    end
    for _, row in ipairs(result) do
        if TRADE_ANCHORS_W[row.id] or (westName and row.continent == westName) then row.continentKey = "west"
        elseif TRADE_ANCHORS_E[row.id] or (eastName and row.continent == eastName) then row.continentKey = "east"
        elseif row.continent ~= "" then row.continentKey = "auroria" else row.continentKey = "other" end
        row.continentLabel = ({ west = "西大陆", east = "东大陆", auroria = "原大陆", other = "其它" })[row.continentKey]
        row.displayName = "[" .. row.continentLabel .. "] " .. row.name
    end
    table.sort(result, function(a, b)
        local ap, bp = TRADE_CONTINENT_ORDER[a.continentKey] or 9, TRADE_CONTINENT_ORDER[b.continentKey] or 9
        if ap ~= bp then return ap < bp end
        return tostring(a.name) < tostring(b.name)
    end)
    return result
end

local function TradeZoneName(id)
    for _, row in ipairs(TA.zones or {}) do if row.id == Number(id) then return row.name end end
    for _, row in ipairs(TA.sellableZones or {}) do if row.id == Number(id) then return row.name end end
    return id and tostring(id) or "--"
end

-- Route favorites are a local/persisted user preference only.  X2Store remains
-- the sole Authority for whether a route is actually valid and for its live
-- specialty ratio.  Keep the list bounded and store only numeric route ids so
-- localized display names can change without corrupting identity.
function Trade:NormalizeFavorites(value)
    local result, seen = {}, {}
    for _, favorite in ipairs(type(value) == "table" and value or {}) do
        local from, to = Number(type(favorite) == "table" and favorite.fromZone or nil), Number(type(favorite) == "table" and favorite.toZone or nil)
        if from ~= nil and to ~= nil and from ~= to then
            from, to = math.floor(from), math.floor(to)
            local key = tostring(from) .. ":" .. tostring(to)
            if seen[key] ~= true then
                seen[key] = true
                result[#result + 1] = { fromZone = from, toZone = to }
                if #result >= 12 then break end
            end
        end
    end
    return result
end

function Trade:FavoriteKey(fromZone, toZone)
    local from, to = Number(fromZone), Number(toZone)
    if from == nil or to == nil or from == to then return nil end
    return tostring(math.floor(from)) .. ":" .. tostring(math.floor(to))
end

function Trade:GetFavorites()
    return Copy(self:NormalizeFavorites(self.State.favorites))
end

function Trade:IsFavorite(fromZone, toZone)
    local wanted = self:FavoriteKey(fromZone, toZone)
    if wanted == nil then return false end
    for _, favorite in ipairs(self:NormalizeFavorites(self.State.favorites)) do
        if self:FavoriteKey(favorite.fromZone, favorite.toZone) == wanted then return true end
    end
    return false
end

function Trade:GetFavoriteItems()
    local result = {}
    local currentKey = self:FavoriteKey(self.State.fromZone, self.State.toZone)
    for _, favorite in ipairs(self:NormalizeFavorites(self.State.favorites)) do
        local key = self:FavoriteKey(favorite.fromZone, favorite.toZone)
        result[#result + 1] = {
            value = key, key = key, fromZone = favorite.fromZone, toZone = favorite.toZone,
            text = "[收藏] " .. TradeZoneName(favorite.fromZone) .. " → " .. TradeZoneName(favorite.toZone),
            selected = key == currentKey,
        }
    end
    return result
end

-- 维护（2026-09-23，trade-focus-mode-1）：服务器 GetSpecialtyRatioBetween 只能按路线整包返回，
-- “关注货物”不能伪装成服务端单品查询。这里仅持久化经过核验的 product itemType，随后在本地 Projection
-- 过滤并只对可见/关注行执行材料身份与成本重投影，从而减少 Live Craft/报价相关工作。最大 128 项，禁止
-- 把 localized name 当稳定身份；itemType 缺失的行仍可在“全部”查看，但不能写入关注 Store。
function Trade:NormalizeTrackedProducts(value)
    local out, seen = {}, {}
    for _, raw in ipairs(type(value) == "table" and value or {}) do
        local id = Number(raw)
        if id ~= nil then
            id = math.floor(id)
            if id > 0 and seen[id] ~= true then
                seen[id] = true
                out[#out + 1] = id
                if #out >= 128 then break end
            end
        end
    end
    table.sort(out)
    return out
end

function Trade:RefreshTrackedProductSet()
    self.Preferences.trackedProducts = self:NormalizeTrackedProducts(self.Preferences.trackedProducts)
    local set = {}
    for _, id in ipairs(self.Preferences.trackedProducts) do set[id] = true end
    self._trackedProductSet = set
    return set
end

function Trade:IsTrackedProduct(itemType)
    itemType = Number(itemType)
    if itemType == nil then return false end
    itemType = math.floor(itemType)
    local set = type(self._trackedProductSet) == "table" and self._trackedProductSet or self:RefreshTrackedProductSet()
    return set[itemType] == true
end

local function PersistTradePreference(reason, mutator)
    if type(P.MutateStore) ~= "function" then return false, "Persistence mutation transaction unavailable" end
    return P:MutateStore(Trade.preferenceStoreId, function()
        return mutator(Trade.Preferences)
    end, { delayMs = 300, reason = reason or "trade_preferences_changed" })
end

function Trade:GetViewMode()
    return TRADE_VIEW_MODES[self.Preferences.viewMode] and self.Preferences.viewMode or "all"
end

local function TradePrice(destination, name, ratio, commerceSkill, originZoneName, includeCommerce)
    local payout = S.Services and S.Services.TradePayoutV3 or nil
    if type(payout) ~= "table" or type(payout.Estimate) ~= "function" then
        return nil, { status = "trade_payout_service_unavailable" }
    end
    return payout:Estimate({
        destination = destination, itemName = name, ratio = ratio,
        commerceSkill = commerceSkill, originZoneName = originZoneName,
        includeCommerce = includeCommerce == true,
    })
end

-- Trade material projection is deliberately bounded because the route event is
-- user-triggered but can contain static/custom recipes of arbitrary size.  The
-- same bounded rows are used for the visible summary, per-material quote data,
-- and total cost; a truncated recipe never reports its subtotal as a complete
-- cost.
local TRADE_MATERIAL_MAX_ROWS = 32
-- 维护（2026-09-25，trade-multi-row-quote-budget-1）：每个 RowJob 可以覆盖该货物全部已解析材料，
-- 但材料数仍受 32 项硬上限保护；“多个货物同时询价”只增加业务任务/watcher，不增加 Native 并发。
-- 总同时 RowJob 与批量列表行数在后面的 QuoteJob Orchestrator 继续有界，PriceQuoteQueueV3 还保留 64 项共享队列上限。
local TRADE_ROW_QUOTE_BATCH_MAX = TRADE_MATERIAL_MAX_ROWS
-- Player-facing Chinese name for an itemType, via the shared Localization
-- Authority. Internal identifiers (English data keys, compact ids, craftType
-- numbers, English legacy recipe names) must never be rendered as a row label:
-- the Suite's users are players on a Chinese RU client. Returns nil only when
-- no localized fact exists, so callers can choose an honest generic wording.
--
-- MAINTENANCE: this helper is file-local by design. `.18.180` accidentally
-- declared it as a global function, which polluted the addon namespace and made
-- Foundation Audit fail even though every caller lives in this bundle. Keep it
-- local; cross-module name resolution belongs to Localization/Identity services.
local function LocalizedTradeItemName(itemType, fallbackText)
    local id = tonumber(itemType)
    if id ~= nil and S.Localization ~= nil and type(S.Localization.GetName) == "function" then
        local name = S.Localization:GetName("item", math.floor(id), nil)
        if type(name) == "string" and name ~= "" and not name:match("^ID%s+%d+$") then return name end
    end
    local text = tostring(fallbackText or "")
    -- Reject ASCII-only leftovers ("Ground Grain", "Halcyona Preserved Specialty",
    -- "3") which are internal identifiers rather than player-readable names.
    if text ~= "" and not text:match("^[A-Za-z0-9_ .%-%+%%:/]+$") then return text end
    return nil
end

local TRADE_MATERIAL_KEY_MAX_BYTES = 48
-- Table cells hold "name×count" only. These limits are byte budgets because Lua 5.1
-- strings are byte arrays; never cut a localized UTF-8 code point in the middle.
local TRADE_MATERIAL_CELL_MAX_BYTES = 26
local TRADE_MATERIAL_SUMMARY_ROW_MAX_BYTES = 120
local TRADE_MATERIAL_SUMMARY_MAX_BYTES = 4096

-- 维护（2026-09-23，trade-utf8-boundary-1）：旧 BoundedTradeText 直接 string.sub(text, 1, limit)，
-- 中文 3-byte UTF-8 在边界处会被切出无效字节，轻则显示乱码，重则污染原生编辑框/列表文本。Authority 仍只
-- 负责有界 Projection，不扩大缓存预算；这里按“字节上限”扫描完整 code point，非法/不完整序列直接停在其前。
-- 该逻辑只在构建材料显示文本时执行，最多扫描 120 bytes，不进入 Tick/高频 Native 查询。
local function TradeUtf8Prefix(value, maxBytes)
    local text = tostring(value or "")
    local limit = math.max(0, math.floor(tonumber(maxBytes) or #text))
    if #text <= limit then return text end
    local index, lastComplete = 1, 0
    while index <= #text and index <= limit do
        local first = string.byte(text, index)
        if first == nil then break end
        local width
        if first <= 0x7F then width = 1
        elseif first >= 0xC2 and first <= 0xDF then width = 2
        elseif first >= 0xE0 and first <= 0xEF then width = 3
        elseif first >= 0xF0 and first <= 0xF4 then width = 4
        else break end
        if index + width - 1 > limit then break end
        local valid = true
        for offset = 1, width - 1 do
            local continuation = string.byte(text, index + offset)
            if continuation == nil or continuation < 0x80 or continuation > 0xBF then valid = false; break end
        end
        if not valid then break end
        lastComplete = index + width - 1
        index = lastComplete + 1
    end
    return lastComplete > 0 and string.sub(text, 1, lastComplete) or ""
end

local function BoundedTradeText(value, fallback, maxBytes)
    local text = Text(value, fallback)
    local limit = tonumber(maxBytes) or TRADE_MATERIAL_KEY_MAX_BYTES
    return #text > limit and TradeUtf8Prefix(text, limit) or text
end

-- Ingredient identity comes from the curated trade_material record (resolved by
-- EN key or compactId), falling back to what the ingredient row itself carries
-- (live craft rows). The legacy recipe tables store "material.xxx" registry
-- keys while the auction meta table is EN-name keyed — resolve through the
-- record instead of trusting the raw key.
local function ResolveTradeIngredient(static, meta, ingredient)
    local record = nil
    if type(static) == "table" then
        if type(static.GetMaterialByLegacyName) == "function" and ingredient.materialKey ~= nil then
            record = static:GetMaterialByLegacyName(ingredient.materialKey)
        end
        if record == nil and type(static.GetMaterialByCompactId) == "function" and tonumber(ingredient.compactId) ~= nil then
            record = static:GetMaterialByCompactId(ingredient.compactId)
        end
        -- X2Craft fallback material rows can be detached from English/compact keys. ItemID remains the stable
        -- Authority for curated cost policy, especially bound resources such as Gilda Star (23633).
        if record == nil and type(static.GetMaterialByItemId) == "function" and tonumber(ingredient.itemType) ~= nil then
            record = static:GetMaterialByItemId(ingredient.itemType)
        end
    end
    local item = (record == nil and type(meta) == "table") and meta[ingredient.materialKey] or nil
    local itemType = (record and tonumber(record.itemId)) or (item and tonumber(item.itemType)) or tonumber(ingredient.itemType)
    local itemGrade = (record and tonumber(record.itemGrade)) or (item and tonumber(item.itemGrade)) or tonumber(ingredient.itemGrade)
    local includeInCost = not (record and record.includeInCost == false) and not (item and item.includeInCost == false)
    if ingredient.includeInCost == false then includeInCost = false end
    local auctionable = not (record and record.auctionable == false) and itemType ~= nil
    if ingredient.auctionable == false then auctionable = false end
    local costKind = record and tostring(record.costKind or "") or ""
    if costKind == "" then costKind = auctionable and "market" or (includeInCost and "unknown_non_market" or "non_market") end
    local note = record and record.note or nil
    local materialKey = tostring((record and record.nameEn) or ingredient.materialKey or ingredient.compactId or "?")
    return materialKey, itemType, itemGrade, includeInCost, auctionable, costKind, note
end

local function BuildTradeMaterialProjection(row)
    row = type(row) == "table" and row or {}
    local name = tostring(row.sourceName or row.name or "")
    local static = S.Data and S.Data.TradeStaticV2
    local identity = S.Services and S.Services.TradeMaterialIdentityV3 or nil
    local recipe = static and type(static.GetRecipeByLegacyName) == "function" and static:GetRecipeByLegacyName(name) or nil
    local ingredients = type(recipe) == "table" and recipe.ingredients or nil
    local recipeLabel = type(recipe) == "table" and tostring(recipe.legacyName or name) or nil
    -- Diagnostics-only trace (source ids / craftType). Kept off every rendered
    -- row so pages show Chinese product wording and nothing else.
    local identityDetail = nil
    local identitySource = type(recipe) == "table" and "static_recipe" or nil
    local result = {
        rows = {}, materialRows = {}, summary = "材料待确认", sourceCount = 0,
        truncated = false, costCopper = nil, subtotalCopper = 0,
        costComplete = false, costStatus = "unavailable",
        boundResourceCount = 0, nonMarketResourceCount = 0, hasUnpricedNonMarket = false,
        identityStatus = "unresolved", recipeLabel = nil, identitySource = nil,
    }
    -- Layer 2/3 of the identity chain: shared static families and the
    -- originZone Authority + localized family tail (pure data, no native calls),
    -- then the live craft cache (read-only peek; native reads run only in the
    -- identity service's bounded queue).
    if type(ingredients) ~= "table" and type(identity) == "table" and type(identity.ResolveStatic) == "function" then
        local resolved = identity:ResolveStatic(name, row.originZone)
        if type(resolved) == "table" and type(resolved.rows) == "table" and #resolved.rows > 0 then
            ingredients = resolved.rows
            recipeLabel, identitySource = tostring(resolved.label or "?"), tostring(resolved.source or "static")
            identityDetail = tostring(resolved.source or "static") .. ":" .. tostring(resolved.label or "?")
            -- The static table is keyed by English legacy recipe names ("Halcyona
            -- Preserved Specialty"). Prefer the localized product name for display.
            recipeLabel = LocalizedTradeItemName(row.itemType, recipeLabel) or recipeLabel
        end
    end
    if type(ingredients) ~= "table" and row.itemType ~= nil and type(identity) == "table" and type(identity.GetCachedLive) == "function" then
        local live = identity:GetCachedLive(row.itemType)
        if type(live) == "table" and type(live.rows) == "table" and #live.rows > 0 then
            ingredients = live.rows
            -- A craftType number is an internal identifier, never a label. The
            -- product's own localized name is the only honest player-facing text;
            -- craftType stays on the diagnostics-only identityDetail field.
            recipeLabel = LocalizedTradeItemName(row.itemType, nil) or "配方已识别"
            identitySource = "live"
            identityDetail = "live craftType=" .. tostring(live.craftType or "?")
        end
    end
    if type(ingredients) ~= "table" then
        -- "解析中" only while the live attempt is still queued/in flight; once
        -- the attempt terminated (ready-but-empty or failed), say 未匹配.
        local liveAttempted = row.itemType ~= nil and type(identity) == "table"
            and type(identity.HasLiveAttempt) == "function" and identity:HasLiveAttempt(row.itemType) or false
        result.identityStatus = (row.itemType ~= nil and not liveAttempted) and "live_pending" or "unresolved"
        result.summary = result.identityStatus == "live_pending" and "配方解析中…" or "配方未匹配"
        return result
    end
    result.identityStatus, result.recipeLabel, result.identitySource = "resolved", recipeLabel, identitySource
    result.identityDetail = identityDetail

    local meta = S.Data and S.Data.TradeMaterialAuctionMeta
    local sourceCount = #ingredients
    local limit = sourceCount
    if limit > TRADE_MATERIAL_MAX_ROWS then
        limit = TRADE_MATERIAL_MAX_ROWS
        result.truncated = true
    end
    result.sourceCount = sourceCount

    local total, complete = 0, sourceCount > 0
    for index = 1, limit do
        local ingredient = type(ingredients[index]) == "table" and ingredients[index] or {}
        local count = math.max(0, tonumber(ingredient.count) or 0)
        local materialKey, itemType, itemGrade, includeInCost, auctionable, costKind, materialNote = ResolveTradeIngredient(static, meta, ingredient)
        local unitCost, totalCost, status = nil, nil, "price_pending"
        local quoteState, quoteError = nil, nil
        -- Provenance is rendered after the pricing branch below, so its lifetime
        -- must cover the whole ingredient iteration. Do NOT redeclare it inside
        -- the `itemType ~= nil` branch: Lua block scope would end at `end`, and
        -- the later detailText read would silently resolve a global named
        -- `priceProvenance` instead. That exact leak was caught by the full
        -- Foundation Audit while sealing `.18.188`.
        local priceProvenance = nil

        if not includeInCost then
            -- 维护（2026-09-23，trade-bound-resource-cost-1）：绑定资源/非市场凭证仍是配方真实需求，
            -- 不能因为“不进入金币成本”就被表现成“识别不到材料”。金币小计为 0，但保留 itemType/count/资源类型，
            -- 并禁止进入拍卖询价队列。利润仍可给出“金币口径”，详情明确提示存在未折价资源。
            totalCost = 0
            status = costKind == "bound_resource" and "bound_resource" or "non_market_resource"
        elseif itemType == nil then
            complete, status = false, "identity_pending"
        elseif auctionable ~= true then
            complete, status = false, "non_market_unpriced"
        else
            -- Material identity is a local fact. Price is not: GetLowestPrice is
            -- cooldown-bound and must never fan out from an ordinary route refresh.
            -- Instead read the shared PriceQuoteQueueV3 read model: a completed
            -- quote resolves the unit cost here; an in-flight request renders
            -- quote_pending; a failed one renders quote_failed with its real
            -- error instead of an endless 待询价. No server request is issued.
            -- Three-tier price resolution (user-requested design):
            --   1. a live quote completed this session        -> "quoted"
            --   2. otherwise the persisted reference table    -> "quoted_reference"
            --   3. otherwise pending / failed / never queried -> honest states
            -- A reference value still costs into the margin (the player asked for a
            -- usable number immediately), but it is labelled separately everywhere:
            -- auction listings are manipulable, so an old sample must never be
            -- presented as current market data.
            local quoteQueue = S.Services ~= nil and S.Services.PriceQuoteQueueV3 or nil
            local materialPrices = S.Services ~= nil and S.Services.MaterialPriceServiceV3 or nil
            local quotedPrice, priceMeta = nil, nil
            if type(quoteQueue) == "table" and type(quoteQueue.GetQuoteStateByItemType) == "function" then
                quoteState = quoteQueue:GetQuoteStateByItemType(itemType, itemGrade)
            end
            -- 维护（2026-09-25，material-price-swr-1）：材料成本首先读取持久化 MaterialPriceServiceV3。
            -- 本地值无论 fresh/warm/stale/old 都可立即参与毛利；年龄只决定后台是否重验，绝不能因为过期把
            -- 已知成本清成 nil。PriceQuoteQueueV3 仍只负责 Native 串行和当前请求状态，禁止 Presentation/Trade
            -- 自己保存第二份材料单价。混装旧包时才回退 Queue 旧接口。
            if type(materialPrices) == "table" and type(materialPrices.GetPrice) == "function" then
                quotedPrice, priceMeta = materialPrices:GetPrice(itemType, itemGrade)
                if quotedPrice ~= nil then
                    priceProvenance = tostring(priceMeta and priceMeta.freshness or "unknown") == "fresh" and "local_fresh" or "local_cached"
                end
            end
            -- 维护（2026-09-27，trade-material-store-degraded-fallback-1）：MaterialPriceServiceV3 存在并不代表
            -- 它的 Store 一定可读。实机诊断已经出现 storeLoaded=false / 0 writes；旧版因为上面是 if/elseif，
            -- 服务表只要存在就会吞掉 PriceQuoteQueueV3 已完成的会话报价，导致材料长期“待询价”。持久 Authority
            -- 不可用/未命中时只读回退共享 QuoteQueue read-model；不复制价格、不发 Native 请求，Store 恢复后仍优先它。
            if quotedPrice == nil and type(quoteQueue) == "table" and type(quoteQueue.GetPriceWithProvenance) == "function" then
                local legacyProvenance, legacyMeta
                quotedPrice, legacyProvenance, legacyMeta = quoteQueue:GetPriceWithProvenance(itemType, itemGrade)
                if quotedPrice ~= nil then
                    priceMeta = legacyMeta
                    priceProvenance = legacyProvenance == "live" and "local_fresh" or "local_cached"
                end
            end
            if quotedPrice ~= nil then
                unitCost, totalCost = quotedPrice, quotedPrice * count
                status = priceProvenance == "local_fresh" and "quoted" or "quoted_reference"
            elseif quoteState ~= nil and (quoteState.status == "queued" or quoteState.status == "inflight") then
                complete, status = false, "quote_pending"
            elseif quoteState ~= nil and quoteState.status == "failed" then
                quoteError = type(quoteState.error) == "string" and quoteState.error or tostring(quoteState.code or "报价失败")
                complete, status = false, "quote_failed"
            else
                complete, status = false, "explicit_quote_required"
            end
        end
        if totalCost ~= nil then total = total + totalCost end

        -- Player-facing text only. `materialKey` is the canonical English data
        -- key ("Chopped Produce"); showing it to a player on a Chinese client is
        -- unreadable noise. Resolve through the identity service's display
        -- resolver (Localization Authority first) and keep the internal key on a
        -- diagnostics-only field instead of the rendered name.
        local identityService = S.Services and S.Services.TradeMaterialIdentityV3 or nil
        local displayName = (type(identityService) == "table" and type(identityService.ResolveMaterialDisplayName) == "function"
            and identityService:ResolveMaterialDisplayName({
                itemType = itemType, materialKey = materialKey,
            })) or nil
        if displayName == nil or displayName == "" then
            displayName = LocalizedTradeItemName(itemType, materialKey)
        end
        local row = {
            index = index,
            materialKey = materialKey,
            compactId = tonumber(ingredient.compactId),
            -- Diagnostics-only: never rendered on a page/HUD row.
            internalKey = BoundedTradeText(materialKey, "?", TRADE_MATERIAL_KEY_MAX_BYTES),
            name = BoundedTradeText(displayName or "材料", "材料", TRADE_MATERIAL_KEY_MAX_BYTES),
            count = count,
            itemType = itemType,
            itemGrade = itemGrade,
            includeInCost = includeInCost,
            auctionable = auctionable == true,
            costKind = costKind,
            materialNote = materialNote ~= nil and BoundedTradeText(materialNote, "", 96) or nil,
            unitCostCopper = unitCost,
            totalCostCopper = totalCost,
            costCopper = totalCost,
            costStatus = status,
            quoteState = status == "quote_pending" and tostring(quoteState.status) or nil,
            quoteError = quoteError ~= nil and BoundedTradeText(quoteError, "报价失败", 96) or nil,
            priceFreshness = type(priceMeta) == "table" and tostring(priceMeta.freshness or "unknown") or nil,
            priceAgeMinutes = type(priceMeta) == "table" and tonumber(priceMeta.ageMinutes) or nil,
            priceSource = type(priceMeta) == "table" and tostring(priceMeta.source or "") or nil,
            priceRefreshing = type(priceMeta) == "table" and priceMeta.refreshing == true or false,
        }
        -- Compact cell text: name × count only. Per-material price/status detail
        -- lives on the row fields below (consumed by the detail window and the
        -- diagnostics panel), not in the scanned table cell.
        row.detailText = row.name .. "×" .. tostring(row.count)
        if status == "bound_resource" then
            row.detailText = row.detailText .. "（绑定资源，不计金币成本）"
        elseif status == "non_market_resource" then
            row.detailText = row.detailText .. "（非市场资源，不计金币成本）"
        elseif status == "non_market_unpriced" then
            row.detailText = row.detailText .. "（不可拍卖，价格未折算）"
        elseif unitCost ~= nil and totalCost ~= nil then
            local ageText = ""
            if row.priceAgeMinutes ~= nil then
                if row.priceAgeMinutes < 60 then ageText = "，本地" .. tostring(math.floor(row.priceAgeMinutes)) .. "分钟前"
                elseif row.priceAgeMinutes < 1440 then ageText = "，本地" .. tostring(math.floor(row.priceAgeMinutes / 60)) .. "小时前"
                else ageText = "，本地" .. tostring(math.floor(row.priceAgeMinutes / 1440)) .. "天前" end
            elseif priceProvenance == "local_cached" then ageText = "，本地历史价" end
            if row.priceRefreshing == true then ageText = ageText .. "，后台更新中" end
            row.detailText = row.detailText .. "（单价 " .. Money(unitCost) .. " / 小计 " .. Money(totalCost) .. ageText .. "）"
        elseif status == "quote_pending" then
            row.detailText = row.detailText .. "（询价" .. (row.quoteState == "inflight" and "中" or "排队中") .. "）"
        elseif status == "quote_failed" then
            row.detailText = row.detailText .. "（询价失败）"
        else
            row.detailText = row.detailText .. (status == "explicit_quote_required" and "（价格需显式询价）" or "（单价待确认）")
        end
        row.summaryText = BoundedTradeText(row.detailText, row.name .. "×" .. tostring(row.count), TRADE_MATERIAL_SUMMARY_ROW_MAX_BYTES)
        row.cellText = BoundedTradeText(row.name .. "×" .. tostring(row.count), row.name, TRADE_MATERIAL_CELL_MAX_BYTES)
        if status == "bound_resource" then result.boundResourceCount = result.boundResourceCount + 1 end
        if status == "non_market_resource" then result.nonMarketResourceCount = result.nonMarketResourceCount + 1 end
        if status == "non_market_unpriced" then result.hasUnpricedNonMarket = true end
        result.rows[#result.rows + 1] = row
        result.materialRows[#result.materialRows + 1] = row
    end

    local summaryParts, summaryChars = {}, 0
    for _, row in ipairs(result.materialRows) do
        local part = row.cellText or row.summaryText
        local nextChars = summaryChars + #part + (#summaryParts > 0 and 3 or 0)
        if nextChars > TRADE_MATERIAL_SUMMARY_MAX_BYTES then
            -- Keep the collection/cost contract explicit even if a future
            -- localized material name makes the bounded display too long.
            result.summaryDisplayTruncated = true
            break
        end
        summaryParts[#summaryParts + 1], summaryChars = part, nextChars
    end
    result.summary = #summaryParts > 0 and table.concat(summaryParts, " + ") or "材料待确认"
    if result.truncated then
        result.summary = result.summary .. "；材料明细已截断（显示 " .. tostring(limit) .. "/" .. tostring(sourceCount) .. " 项）"
    elseif result.summaryDisplayTruncated then
        result.summary = result.summary .. "；材料摘要已截断（详情数据仍受 " .. tostring(TRADE_MATERIAL_MAX_ROWS) .. " 项上限保护）"
    end
    result.subtotalCopper = math.floor(total + 0.5)
    result.costComplete = complete and not result.truncated and not result.summaryDisplayTruncated
    if result.truncated then
        result.costStatus = "truncated"
    elseif result.costComplete and (result.boundResourceCount > 0 or result.nonMarketResourceCount > 0) then
        result.costStatus = "ready_with_resources"
    else
        result.costStatus = result.costComplete and "ready" or "partial"
    end
    result.costCopper = result.costComplete and result.subtotalCopper or nil
    result.count = #result.materialRows
    return result
end

local function ApplyTradeMaterialProjectionToRow(row)
    if type(row) ~= "table" then return false end
    local materialProjection = BuildTradeMaterialProjection(row)
    local cost = materialProjection.costCopper
    local price = tonumber(row.priceCopper)
    local profit = price and cost and (price - cost) or nil
    local economics = type(TA.economics) == "table" and TA.economics or {}
    local materialPriceService = S.Services and S.Services.MaterialPriceServiceV3 or nil
    local materialRevision = type(materialPriceService) == "table" and type(materialPriceService.GetRevision) == "function" and tonumber(materialPriceService:GetRevision()) or (tonumber(economics.materialRevision) or 0)
    row.materials = materialProjection.summary
    row.text = materialProjection.summary
    row.materialRows = materialProjection.materialRows
    row.materialCount = materialProjection.count
    row.materialSourceCount = materialProjection.sourceCount
    row.materialLimit = TRADE_MATERIAL_MAX_ROWS
    row.materialsTruncated = materialProjection.truncated
    row.materialSummaryTruncated = materialProjection.summaryDisplayTruncated
    row.materialCostCopper = cost
    row.profitCopper = profit
    row.profitRate = profit ~= nil and cost ~= nil and cost > 0 and (profit / cost * 100) or nil
    row.economicsPayoutRevision = tonumber(economics.payoutRevision) or 0
    row.economicsMaterialRevision = materialRevision or 0
    row.materialCostStatus = materialProjection.costStatus
    row.materialCostComplete = materialProjection.costComplete
    row.materialSubtotalCopper = materialProjection.subtotalCopper
    row.boundResourceCount = tonumber(materialProjection.boundResourceCount) or 0
    row.nonMarketResourceCount = tonumber(materialProjection.nonMarketResourceCount) or 0
    row.hasUnpricedNonMarket = materialProjection.hasUnpricedNonMarket == true
    row.materialCostBasis = (row.boundResourceCount > 0 or row.nonMarketResourceCount > 0) and "gold_only_with_resources" or "gold_only"
    row.identityStatus = materialProjection.identityStatus
    row.recipeLabel = materialProjection.recipeLabel
    row.identitySource = materialProjection.identitySource
    row.materialIdentityPending = materialProjection.identityStatus == "live_pending"
    -- 每次投影先清掉上一轮的展示附注，避免 ready -> pending/failed 时复用同一个 row table 留下旧“仅金币成本”提示。
    row.profitNote = nil
    -- .18.176 RU evidence: GetLowestPrice returns nil for every grade on every
    -- control itemType (oats/hay/egg included), so a material cost is currently
    -- unobtainable on this client. "待材料价格" used to imply the number was merely
    -- pending; say what is actually missing and where the player can still get a
    -- usable estimate (the sell price and 货率 columns remain real facts).
    if profit then
        row.profitStatus = "ready"
        -- 维护（2026-09-25，trade-profit-resource-label-1）：旧版在毛利后追加“*”表示仍有绑定/非市场
        -- 制作资源未折算金币，但列表没有脚注，用户会误以为是货币/公式异常。紧凑列只显示真实金币口径数字；
        -- 是否“仅金币成本”由结构化 materialCostBasis/profitNote 投影，并在选中提示/详情明确说明。
        row.profit = Money(profit)
        local extraResources = row.boundResourceCount + row.nonMarketResourceCount
        row.profitNote = extraResources > 0 and ("仅扣已折算金币材料；另有 " .. tostring(extraResources) .. " 项绑定/非市场资源未折价") or nil
    else
        -- 维护（2026-09-23，trade-row-actionable-profit-1）：紧凑列表中的毛利列必须告诉玩家“下一步做什么”。
        -- 旧文案“缺材料价（拍卖行无返回）”既过长又像永久故障，且无法解释显式询价模型。这里仅消费已经
        -- 解析好的材料状态，不发 Native 请求；双击行为仍由 Presentation -> QuoteRowMaterials 明确触发。
        local hasQuotePending, hasQuoteFailed, hasQuoteRequired, hasBackgroundPending = false, false, false, false
        for _, material in ipairs(type(materialProjection.materialRows) == "table" and materialProjection.materialRows or {}) do
            if material.costStatus == "quote_pending" then hasQuotePending = true
            elseif material.costStatus == "quote_failed" then hasQuoteFailed = true
            elseif material.costStatus == "explicit_quote_required" then hasQuoteRequired = true end
            if material.priceRefreshing == true then hasBackgroundPending = true end
        end
        -- 维护（2026-09-25，trade-multi-row-quote-visual-1）：共享 QuoteQueue 的 queued/inflight 是材料事实，
        -- 但“询价中”属于 RowJob 用户意图。多货物并行后不能再用一个全局 quoteBatch.rowKey 判断；只有当前行
        -- 自己存在 active RowJob 时才显示询价中。其它行即使共享同一个正在查询的红薯/鸡蛋，也只显示“可询价”，
        -- 直到用户把该行加入任务；底层请求仍会自动合并，不会重复访问服务器。
        local rowJob = type(Trade.quoteJobsByRowKey) == "table" and Trade.quoteJobsByRowKey[tostring(row.key or "")] or nil
        local isIntentRow = type(rowJob) == "table" and rowJob.active == true
        if hasQuotePending and not isIntentRow and not hasBackgroundPending then
            hasQuotePending = false
            hasQuoteRequired = true
        end
        if price == nil then
            row.profitStatus, row.profit = "price_unavailable", "--"
        elseif hasQuotePending then
            if hasBackgroundPending and not isIntentRow then
                row.profitStatus, row.profit = "background_quote_pending", "后台询价…"
            else
                row.profitStatus, row.profit = "quote_pending", "询价中…"
            end
        elseif hasQuoteFailed then
            row.profitStatus, row.profit = "quote_failed", "询价失败"
        elseif hasQuoteRequired then
            row.profitStatus, row.profit = "quote_required", "双击询价"
        elseif materialProjection.identityStatus == "live_pending" then
            row.profitStatus, row.profit = "identity_pending", "材料解析中"
        elseif materialProjection.identityStatus ~= "resolved" then
            row.profitStatus, row.profit = "identity_unresolved", "材料未识别"
        elseif materialProjection.hasUnpricedNonMarket == true then
            row.profitStatus, row.profit = "non_market_unpriced", "材料不可估"
        else
            row.profitStatus, row.profit = "partial", "材料价不全"
        end
    end
    -- RowJob 元数据只用于 Presentation 展示进度/按钮状态；材料价格本身由 MaterialPriceServiceV3 Authority 提供。
    local displayJob = type(Trade.quoteJobsByRowKey) == "table" and Trade.quoteJobsByRowKey[tostring(row.key or "")] or nil
    row.quoteJobActive = type(displayJob) == "table" and displayJob.active == true
    row.quoteJobState = type(displayJob) == "table" and tostring(displayJob.state or (displayJob.active and "quoting" or "idle")) or "idle"
    row.quoteJobCompleted = type(displayJob) == "table" and (tonumber(displayJob.completed) or 0) or 0
    row.quoteJobTotal = type(displayJob) == "table" and (tonumber(displayJob.total) or 0) or 0
    row.quoteJobReady = type(displayJob) == "table" and (tonumber(displayJob.ready) or 0) or 0
    row.quoteJobFailed = type(displayJob) == "table" and (tonumber(displayJob.failed) or 0) or 0
    return true
end

-- 维护（2026-09-27，trade-profit-swr-carry-forward-1）：ratio fast-publish 只更新服务器货率/售价事实，
-- 不得把已经可用的材料成本和毛利清成 nil。材料价格是独立 Authority，上一帧同一路线/同一货物的
-- 已投影材料快照在新货率到达时仍然有效；这里仅复用当前 Display ReadModel 中的稳定派生字段，并用
-- 新 priceCopper 重新计算毛利。整个快路径不读取 MaterialPriceService、不发 Auction Native，也不保留
-- 跨路线数据：key/来源/目的地/itemType 任一身份不一致即拒绝继承。后续 deferred projection 仍会用
-- MaterialPriceService Authority 重新校准，因此这是 stale-while-revalidate 的显示连续性，不是第二价格缓存。
local TRADE_FAST_CARRY_FIELDS = {
    "materials", "text", "materialRows", "materialCount", "materialSourceCount", "materialLimit",
    "materialsTruncated", "materialSummaryTruncated", "materialCostCopper", "materialCostStatus",
    "materialCostComplete", "materialSubtotalCopper", "boundResourceCount", "nonMarketResourceCount",
    "hasUnpricedNonMarket", "materialCostBasis", "identityStatus", "recipeLabel", "identitySource",
    "materialIdentityPending", "economicsMaterialRevision",
}

local function IsCompatibleTradeMaterialSnapshot(row, previous)
    if type(row) ~= "table" or type(previous) ~= "table" then return false end
    if tostring(row.key or "") == "" or tostring(row.key or "") ~= tostring(previous.key or "") then return false end
    local rowFrom, previousFrom = Number(row.originZone), Number(previous.originZone)
    local rowTo, previousTo = Number(row.destinationZone), Number(previous.destinationZone)
    if rowFrom ~= nil and previousFrom ~= nil and rowFrom ~= previousFrom then return false end
    if rowTo ~= nil and previousTo ~= nil and rowTo ~= previousTo then return false end
    local rowItem, previousItem = Number(row.itemType), Number(previous.itemType)
    if rowItem ~= nil and previousItem ~= nil and rowItem ~= previousItem then return false end
    local materialRows = type(previous.materialRows) == "table" and previous.materialRows or nil
    local useful = (materialRows ~= nil and #materialRows > 0) or previous.materialCostCopper ~= nil
        or (previous.materialCostStatus ~= nil and tostring(previous.materialCostStatus) ~= "deferred")
    return useful == true
end

local function ApplyTradeFastMaterialCarryForward(row, previous)
    if not IsCompatibleTradeMaterialSnapshot(row, previous) then return false end
    for _, field in ipairs(TRADE_FAST_CARRY_FIELDS) do row[field] = previous[field] end

    local economics = type(TA.economics) == "table" and TA.economics or {}
    row.economicsPayoutRevision = tonumber(economics.payoutRevision) or 0
    local price = Number(row.priceCopper)
    local cost = Number(row.materialCostCopper)
    if price ~= nil and row.materialCostComplete == true and cost ~= nil then
        local profit = price - cost
        row.profitCopper = profit
        row.profitRate = cost > 0 and (profit / cost * 100) or nil
        row.profitStatus = "ready"
        row.profit = Money(profit)
        local extraResources = (tonumber(row.boundResourceCount) or 0) + (tonumber(row.nonMarketResourceCount) or 0)
        row.profitNote = extraResources > 0 and ("仅扣已折算金币材料；另有 " .. tostring(extraResources) .. " 项绑定/非市场资源未折价") or nil
    else
        -- 成本尚未完整时保留可操作状态（后台询价/双击询价/材料未识别），但绝不能复制与旧售价绑定的 profitCopper。
        row.profitCopper, row.profitRate = nil, nil
        row.profitStatus = price == nil and "price_unavailable" or tostring(previous.profitStatus or "partial")
        row.profit = price == nil and "--" or tostring(previous.profit or "材料价不全")
        row.profitNote = nil
        if row.profitStatus == "ready" then row.profitStatus, row.profit = "partial", "材料价不全" end
    end

    -- RowJob 是当前会话用户意图，不从旧 row 快照继承；按稳定 rowKey 重新读取现行任务状态。
    local displayJob = type(Trade.quoteJobsByRowKey) == "table" and Trade.quoteJobsByRowKey[tostring(row.key or "")] or nil
    row.quoteJobActive = type(displayJob) == "table" and displayJob.active == true
    row.quoteJobState = type(displayJob) == "table" and tostring(displayJob.state or (displayJob.active and "quoting" or "idle")) or "idle"
    row.quoteJobCompleted = type(displayJob) == "table" and (tonumber(displayJob.completed) or 0) or 0
    row.quoteJobTotal = type(displayJob) == "table" and (tonumber(displayJob.total) or 0) or 0
    row.quoteJobReady = type(displayJob) == "table" and (tonumber(displayJob.ready) or 0) or 0
    row.quoteJobFailed = type(displayJob) == "table" and (tonumber(displayJob.failed) or 0) or 0
    row.fastMaterialCarryForward = true
    return true
end

-- Actionable quote backlog: never-quoted materials plus failed ones the user can
-- retry. In-flight (queued/inflight) materials are NOT counted here; they have
-- their own counter so the button reflects only what a click would submit.
local function PendingTradeQuoteCount(rows)
    local seen, count = {}, 0
    for _, row in ipairs(type(rows) == "table" and rows or {}) do
        for _, material in ipairs(type(row.materialRows) == "table" and row.materialRows or {}) do
            local key = material.materialKey
            if (material.costStatus == "explicit_quote_required" or material.costStatus == "quote_failed")
                and key ~= nil and seen[key] ~= true then
                seen[key], count = true, count + 1
            end
        end
    end
    return count
end

local function InFlightTradeQuoteCount(rows)
    local seen, count = {}, 0
    for _, row in ipairs(type(rows) == "table" and rows or {}) do
        for _, material in ipairs(type(row.materialRows) == "table" and row.materialRows or {}) do
            local key = material.materialKey
            if material.costStatus == "quote_pending" and key ~= nil and seen[key] ~= true then
                seen[key], count = true, count + 1
            end
        end
    end
    return count
end

local function UnresolvedTradeIdentityCount(rows)
    local count = 0
    for _, row in ipairs(type(rows) == "table" and rows or {}) do
        if row.materialIdentityPending == true or (row.identityStatus ~= nil and row.identityStatus ~= "resolved") then
            count = count + 1
        end
    end
    return count
end

-- Name sort puts bracket-prefixed goods ("[xxx]…") first, then orders by the
-- localized display name.  The byte order of "[" (0x5B) is above digits and
-- ASCII letters but below CJK UTF-8 lead bytes, so a plain byte compare would
-- sink [黄金] rows behind Chinese names on this client; the prefix flag is
-- therefore compared explicitly.  Tie-break falls back to ratio so two rows
-- with an identical name never swap between rebuilds.
local function TradeNameSortKey(row)
    local name = tostring(row.name or row.sourceName or "")
    return (name:find("^%[") ~= nil) and 1 or 0, name
end

local function SortTradeRows(rows)
    local mode = Trade.State.sortMode
    table.sort(rows, function(a, b)
        if mode == "name" then
            local ap, an = TradeNameSortKey(a)
            local bp, bn = TradeNameSortKey(b)
            if ap ~= bp then return ap > bp end
            if an ~= bn then return an < bn end
            local ar, br = a.ratio or -1, b.ratio or -1
            if ar ~= br then return ar > br end
            return tostring(a.key or "") < tostring(b.key or "")
        end
        local av = mode == "price" and (a.priceCopper or -1) or (a.ratio or -1)
        local bv = mode == "price" and (b.priceCopper or -1) or (b.ratio or -1)
        if av ~= bv then return av > bv end
        return tostring(a.key or "") < tostring(b.key or "")
    end)
end

local function ApplyTradeDisplayModeToRow(row, options)
    if type(row) ~= "table" then return false end
    options = type(options) == "table" and options or {}
    local current = Number(row.currentRatio or row.ratio)
    if current == nil then return false end
    local ratio = Trade.State.ratioMode == "full" and TRADE_FULL_RATIO or current
    row.currentRatio = current
    row.ratio = ratio
    row.rate = tostring(math.floor(ratio + 0.5)) .. "%"
    local includeCommerce = Trade.State.commerceMode ~= "off"
    local price, estimate = TradePrice(
        row.destinationZone or Trade.State.toZone, row.sourceName or row.name, ratio,
        TA.commerceSkill, TradeZoneName(row.originZone or Trade.State.fromZone), includeCommerce)
    estimate = type(estimate) == "table" and estimate or {}
    row.priceCopper = price
    row.price = price and Money(price) or "--"
    row.priceEstimateStatus = tostring(estimate.status or "unavailable")
    row.priceComplete = estimate.complete == true
    row.priceKey = estimate.priceKey
    row.priceKeyMode = estimate.keyMode
    row.priceFormulaSource = estimate.formulaSource
    row.priceBaseAtRatioCopper = estimate.baseAtRatioCopper
    row.commerceMultiplier = tonumber(estimate.commerceMultiplier)
    row.commerceApplied = estimate.commerceApplied == true
    row.packMultiplier = tonumber(estimate.packMultiplier)
    row.packMultiplierToken = estimate.packToken
    row.packCategory = estimate.packCategory
    row.packLabel = estimate.packLabel
    row.packMultiplierSource = estimate.packMultiplierSource
    if row.priceComplete then
        row.priceBreakdown = "货率基价 " .. Money(estimate.baseAtRatioCopper)
            .. " × 熟练 " .. string.format("%.3f", tonumber(estimate.commerceMultiplier) or 1)
            .. " × 品类 " .. string.format("%.2f", tonumber(estimate.packMultiplier) or 1)
    elseif row.priceEstimateStatus == "commerce_skill_unavailable" then
        row.priceBreakdown = "经商熟练度不可读，已停止输出不完整售价"
    elseif row.priceEstimateStatus == "price_key_missing" then
        row.priceBreakdown = "静态售价 Key 未匹配：" .. tostring(row.sourceName or row.name or "?")
    elseif row.priceEstimateStatus == "freshness_unclassified" then
        row.priceBreakdown = "新鲜度类别未登记，已停止输出可能错误的售价：" .. tostring(row.sourceName or row.name or "?")
    else
        row.priceBreakdown = "售价估算不可用：" .. row.priceEstimateStatus
    end
    row.tone = ratio >= 125 and "green" or (ratio >= 115 and "yellow" or "red")
    if options.includeMaterials ~= false then
        ApplyTradeMaterialProjectionToRow(row)
    else
        -- 维护（2026-09-27，trade-profit-swr-carry-forward-1）：fast-publish 仍禁止同步读取材料价格服务，
        -- 但同一货物上一帧已经确认的材料快照不能被清空。优先用旧材料成本配合新售价重算毛利；只有
        -- 首次出现/路线身份改变且没有可继承快照时才进入 deferred 占位。这样自动刷新不会把金币毛利
        -- 瞬间或永久改回“--”，QuoteQueue 后续完成事件也仍能按 materialRows 命中当前行。
        if ApplyTradeFastMaterialCarryForward(row, options.previousRow) ~= true then
            row.materials, row.text, row.materialRows, row.materialCount = "材料加载中…", "材料加载中…", {}, 0
            row.materialCostCopper, row.profitCopper, row.profitRate = nil, nil, nil
            row.materialCostStatus, row.materialCostComplete = "deferred", false
            row.profitStatus, row.profit = "deferred", "--"
            row.fastMaterialCarryForward = false
        end
    end
    return true
end

local function CopyTradeRouteRow(raw)
    -- 维护（2026-09-23，trade-raw-projection-split-1）：RawRatioSnapshot 只保存服务器货率事实，
    -- Display Projection 才挂售价/材料/利润。浅拷贝足够，因为 raw 行全部是标量；避免对几十行反复 DeepCopy。
    return {
        key = raw.key, name = raw.name, sourceName = raw.sourceName, currentRatio = raw.currentRatio, ratio = raw.ratio,
        originZone = raw.originZone, destinationZone = raw.destinationZone, itemType = raw.itemType, ratioUpdatedAt = raw.ratioUpdatedAt,
    }
end

function TA:BuildCargoDisplayRows(options)
    options = type(options) == "table" and options or {}
    local cargo = type(self.cargo) == "table" and self.cargo or {}
    local previousRowsByKey = type(options.previousRowsByKey) == "table" and options.previousRowsByKey or {}
    local rows = {}
    if cargo.status ~= "ready" and cargo.status ~= "scanning" and cargo.status ~= "complete" then return rows end
    for destination, result in pairs(type(cargo.results) == "table" and cargo.results or {}) do
        if type(result) == "table" and Number(result.ratio) ~= nil then
            local to = Number(destination) or Number(result.destinationZone)
            local row = {
                key = "cargo:" .. tostring(cargo.itemType or "?") .. ":" .. tostring(to or "?"),
                name = "→ " .. TradeZoneName(to), sourceName = tostring(cargo.legacyName or cargo.name or ""),
                currentRatio = Number(result.ratio), ratio = Number(result.ratio), originZone = Number(cargo.originZone),
                destinationZone = to, itemType = Number(cargo.itemType), ratioUpdatedAt = tonumber(result.updatedAt) or 0,
                cargoMode = true, cargoProductName = tostring(cargo.name or cargo.legacyName or "随身货物"),
            }
            ApplyTradeDisplayModeToRow(row, {
                includeMaterials = options.includeMaterials ~= false,
                previousRow = previousRowsByKey[tostring(row.key or "")],
            })
            row.tracked = Trade:IsTrackedProduct(row.itemType)
            rows[#rows + 1] = row
        end
    end
    return rows
end

function TA:QueueBackgroundMaterialRevalidation(reason)
    -- 维护（2026-09-25，material-price-swr-1）：普通路线刷新先用本地价完成毛利，再把当前可见行中
    -- Missing/Warm/Stale/Old 材料交给 MaterialPriceServiceV3。这里只提交“刷新意图”，Native 仍由
    -- PriceQuoteQueueV3 单通道串行；fresh 材料不会重复查，服务还会按 itemType+grade 去重/节流。
    if Trade.enabled ~= true or (tonumber(Trade.consumerCount) or 0) <= 0 then return false, "no_consumers" end
    local service = S.Services and S.Services.MaterialPriceServiceV3 or nil
    if type(service) ~= "table" or type(service.QueueRevalidate) ~= "function" then return false, "material_price_service_unavailable" end
    local materials = {}
    for _, row in ipairs(type(self.rows) == "table" and self.rows or {}) do
        for _, material in ipairs(type(row.materialRows) == "table" and row.materialRows or {}) do
            if material.itemType ~= nil and material.auctionable ~= false and material.includeInCost ~= false then
                materials[#materials + 1] = {
                    itemType = material.itemType, itemGrade = material.itemGrade, name = material.name, searchName = material.name,
                    auctionable = true, includeInCost = true,
                }
            end
        end
    end
    local ok, result = service:QueueRevalidate(materials, { reason = tostring(reason or "trade_visible_rows"), maxItems = 12 })
    self.materialRevalidateDiagnostics = type(result) == "table" and Copy(result) or { error = tostring(result or "unknown") }
    self.materialRevalidateDiagnostics.reason = tostring(reason or "trade_visible_rows")
    self.materialRevalidateDiagnostics.at = type(S.NowMs) == "function" and tonumber(S.NowMs()) or 0
    if ok == true and type(result) == "table" and (tonumber(result.submitted) or 0) > 0 then
        -- Missing rows should immediately reflect queued/inflight state. Cached rows keep their existing cost/profit while
        -- background refresh runs, which is the core stale-while-revalidate guarantee.
        for _, row in ipairs(self.rows or {}) do ApplyTradeMaterialProjectionToRow(row) end
    end
    return ok, result
end

function TA:RebuildDisplayRows(reason, options)
    options = type(options) == "table" and options or {}
    local includeMaterials = options.includeMaterials ~= false
    local mode = Trade:GetViewMode()
    local previousRowsByKey = {}
    if includeMaterials ~= true then
        -- Fast path only: index the currently visible read-model once. This is O(visible rows), normally eight,
        -- and prevents a 10s auto-refresh from destroying already-known material/profit state. Full rebuilds always
        -- go back to the real MaterialPrice/Identity Authorities and never consume this carry-forward map.
        for _, previous in ipairs(type(self.rows) == "table" and self.rows or {}) do
            if type(previous) == "table" and previous.key ~= nil then previousRowsByKey[tostring(previous.key)] = previous end
        end
    end
    local rows = {}
    if mode == "cargo" then
        rows = self:BuildCargoDisplayRows({ includeMaterials = includeMaterials, previousRowsByKey = previousRowsByKey })
    else
        for _, raw in ipairs(type(self.rawRows) == "table" and self.rawRows or {}) do
            if mode == "all" or Trade:IsTrackedProduct(raw.itemType) then
                local row = CopyTradeRouteRow(raw)
                ApplyTradeDisplayModeToRow(row, {
                    includeMaterials = includeMaterials,
                    previousRow = previousRowsByKey[tostring(row.key or "")],
                })
                row.tracked = Trade:IsTrackedProduct(row.itemType)
                rows[#rows + 1] = row
            end
        end
    end
    self.rows = rows
    SortTradeRows(self.rows)
    if self.selectedKey ~= nil then
        local found = false
        for _, row in ipairs(self.rows) do if tostring(row.key or "") == tostring(self.selectedKey) then found = true; break end end
        if not found then self.selectedKey = nil end
    end
    if includeMaterials then
        self:SyncEconomicsMaterialRevision(reason or "trade_display_mode")
        self:QueueBackgroundMaterialRevalidation(reason or "trade_display_mode")
    end
    local economics = type(self.economics) == "table" and self.economics or {}
    economics.rebuilds = (tonumber(economics.rebuilds) or 0) + 1
    economics.lastReason = tostring(reason or "trade_display_mode")
    economics.lastAt = type(S.NowMs) == "function" and tonumber(S.NowMs()) or economics.lastAt
    if includeMaterials then
        economics.deferredRebuilds = options.deferredMaterial == true and ((tonumber(economics.deferredRebuilds) or 0) + 1) or (tonumber(economics.deferredRebuilds) or 0)
        if options.deferredMaterial == true then economics.lastDeferredAt = economics.lastAt end
    else
        economics.fastPublishes = (tonumber(economics.fastPublishes) or 0) + 1
        economics.lastFastPublishAt = economics.lastAt
        local carried = 0
        for _, row in ipairs(self.rows or {}) do if row.fastMaterialCarryForward == true then carried = carried + 1 end end
        economics.lastFastCarryForwardRows = carried
        economics.lastFastDeferredRows = math.max(0, #(self.rows or {}) - carried)
        economics.fastCarryForwardTotal = (tonumber(economics.fastCarryForwardTotal) or 0) + carried
    end
    self.economics = economics
    self.revision = self.revision + 1
    PublishFeatureUpdate(Trade, self.revision, reason or "trade_display_mode")
    if type(self.RequestPendingLiveIdentities) == "function" and includeMaterials then self:RequestPendingLiveIdentities() end
    return true
end

function TA:CancelDeferredMaterialProjection()
    if S.Scheduler ~= nil and type(S.Scheduler.RemoveTask) == "function" then
        S.Scheduler:RemoveTask(self.materialProjectionTask)
    end
    return true
end

function TA:ScheduleDeferredMaterialProjection(reason, delayMs)
    local diagnostics = type(self.materialProjectionDiagnostics) == "table" and self.materialProjectionDiagnostics or {}
    self.materialProjectionDiagnostics = diagnostics
    diagnostics.scheduleAttempts = (tonumber(diagnostics.scheduleAttempts) or 0) + 1
    diagnostics.lastScheduledAt = type(S.NowMs) == "function" and tonumber(S.NowMs()) or 0
    diagnostics.lastReason = tostring(reason or "ratio_result")
    if Trade.enabled ~= true or (tonumber(Trade.consumerCount) or 0) <= 0 then
        diagnostics.scheduleFailures = (tonumber(diagnostics.scheduleFailures) or 0) + 1
        diagnostics.lastError = "no_consumers"
        return false, "no_consumers"
    end
    local scheduler = S.Scheduler
    if type(scheduler) ~= "table" or type(scheduler.AddOneShot) ~= "function" then
        diagnostics.scheduleFailures = (tonumber(diagnostics.scheduleFailures) or 0) + 1
        diagnostics.lastError = "scheduler_unavailable"
        return false, "scheduler_unavailable"
    end
    self:CancelDeferredMaterialProjection()
    local delay = math.max(30, tonumber(delayMs) or 60)
    local sourceReason = tostring(reason or "ratio_result")
    -- 维护（2026-09-27，trade-profit-swr-carry-forward-1）：货率 callback 先发布 server facts；材料重投影
    -- 仍走共享 Scheduler，但提升到 P2 的有界 one-shot，避免在后台拍卖任务繁忙时长期压住可见页面的毛利收敛。
    -- 即使该 one-shot 被延迟，fast-publish 已 carry-forward 上一份稳定材料成本，UI 也不会退回“--”。
    local added = scheduler:AddOneShot(self.materialProjectionTask, delay, function()
        diagnostics.runs = (tonumber(diagnostics.runs) or 0) + 1
        diagnostics.lastRunAt = type(S.NowMs) == "function" and tonumber(S.NowMs()) or diagnostics.lastRunAt
        if Trade.enabled ~= true or (tonumber(Trade.consumerCount) or 0) <= 0 then return true end
        return TA:RebuildDisplayRows("material_deferred:" .. sourceReason, { includeMaterials = true, deferredMaterial = true })
    end, Trade, "P2", 1)
    if added == true then
        diagnostics.scheduleAccepted = (tonumber(diagnostics.scheduleAccepted) or 0) + 1
        diagnostics.lastError = nil
        return true
    end
    diagnostics.scheduleFailures = (tonumber(diagnostics.scheduleFailures) or 0) + 1
    diagnostics.lastError = "scheduler_rejected"
    return false, diagnostics.lastError
end

function TA:RefreshCommerceSkill()
    local oldSkill, oldStatus, oldName, oldError = self.commerceSkill, self.commerceStatus, self.commerceName, self.commerceError
    if Trade.State.commerceMode ~= "observe" then
        self.commerceSkill, self.commerceName, self.commerceError = nil, nil, nil
        self.commerceStatus = "off"
    else
        local ok, infos, err = Call("X2Ability:GetAllMyActabilityInfos", AbilityApi, "GetAllMyActabilityInfos")
        if ok ~= true or type(infos) ~= "table" then
            self.commerceSkill, self.commerceName = nil, nil
            self.commerceStatus, self.commerceError = "unavailable", err or "经商熟练度列表不可读"
        else
            local matched = false
            for _, info in pairs(infos) do
                if type(info) == "table" then
                    local name = Text(info.name, "")
                    if TRADE_COMMERCE_NAMES[name] == true then
                        matched = true
                        local point, modify = Number(info.point), Number(info.modifyPoint)
                        if point ~= nil or modify ~= nil then
                            self.commerceSkill = math.max(0, (point or 0) + (modify or 0))
                            self.commerceName, self.commerceStatus, self.commerceError = name, "ready", nil
                        else
                            self.commerceSkill, self.commerceName = nil, name
                            self.commerceStatus, self.commerceError = "unavailable", "经商熟练度字段不可读"
                        end
                        break
                    end
                end
            end
            if not matched then
                self.commerceSkill, self.commerceName = nil, nil
                self.commerceStatus, self.commerceError = "not_found", "未在当前本地化熟练度列表中识别到经商项目"
            end
        end
    end
    local changed = oldSkill ~= self.commerceSkill or oldStatus ~= self.commerceStatus or oldName ~= self.commerceName or oldError ~= self.commerceError
    if changed and type(self.MarkEconomicsPayoutInput) == "function" then self:MarkEconomicsPayoutInput("commerce_skill_changed") end
    return true, changed
end

-- 维护（2026-09-25，trade-cargo-slot-authority-1）：X2Equipment:GetEquippedItemType 接收的是实际装备槽
-- （ES_*），不是装备槽类型（EST_*）。18.307 把 EST_BACKPACK 直接传入后，RU 客户端调用本身成功但返回 nil，
-- 因而随身模式长期落到 cargo.status=empty。现有 Gear/HUD 同样以 ES 槽位 16/17/18/27 读取装备；历史客户端
-- 常量表也明确 ES_BACKPACK=27。Authority 优先读取运行时 ES_BACKPACK；若该全局未导出，使用已验证槽位 27。
-- EST_BACKPACK 只保留到诊断字段，绝不再作为 GetEquippedItemType/GetEquippedItemTooltipInfo 的 locator。
local function TradeBackpackSlot()
    local slot = Number(rawget(_G, "ES_BACKPACK"))
    if slot ~= nil and slot > 0 then return math.floor(slot), "ES_BACKPACK" end
    return 27, "verified_slot_27"
end

local function TradeEquipmentItemType(value)
    if type(value) ~= "table" then return nil end
    for _, key in ipairs({ "itemType", "itemTypeId", "typeId", "item_type" }) do
        local itemType = Number(value[key])
        if itemType ~= nil and itemType > 0 then return math.floor(itemType) end
    end
    return nil
end

local function TradeEquipmentName(value)
    if type(value) ~= "table" then return nil end
    local name = Text(value.name or value.itemName, "")
    return name ~= "" and name or nil
end

-- Read order is deliberately bounded and event-driven: one GetEquippedItemType attempt first, then at most two
-- local tooltip reads only when the direct ItemType is empty. No Tick/loop polling is introduced. Some RU builds have
-- historically differed on targetEquippedItem semantics, so false is the normal self path and true is a read-only
-- compatibility fallback. Stable numeric ItemType remains the only business identity; tooltip name is diagnostics only.
local function ReadTradeBackpackIdentity(slot)
    local errors = {}
    local okType, directType, typeErr = Call("X2Equipment:GetEquippedItemType", EquipmentApi, "GetEquippedItemType", slot)
    local itemType = okType == true and Number(directType) or nil
    if itemType ~= nil and itemType > 0 then
        return true, math.floor(itemType), "GetEquippedItemType", nil, nil
    end
    if okType ~= true and typeErr ~= nil then errors[#errors + 1] = tostring(typeErr) end

    local okFalse, falseTooltip, falseErr = Call("X2Equipment:GetEquippedItemTooltipInfo", EquipmentApi, "GetEquippedItemTooltipInfo", slot, false)
    itemType = okFalse == true and TradeEquipmentItemType(falseTooltip) or nil
    if itemType ~= nil then
        return true, itemType, "Tooltip(false)", nil, TradeEquipmentName(falseTooltip)
    end
    if okFalse ~= true and falseErr ~= nil then errors[#errors + 1] = tostring(falseErr) end

    local okTrue, trueTooltip, trueErr = Call("X2Equipment:GetEquippedItemTooltipInfo", EquipmentApi, "GetEquippedItemTooltipInfo", slot, true)
    itemType = okTrue == true and TradeEquipmentItemType(trueTooltip) or nil
    if itemType ~= nil then
        return true, itemType, "Tooltip(true)", nil, TradeEquipmentName(trueTooltip)
    end
    if okTrue ~= true and trueErr ~= nil then errors[#errors + 1] = tostring(trueErr) end

    -- At least one API call succeeded: an empty/nil identity is truthful "nothing equipped" evidence, not API failure.
    if okType == true or okFalse == true or okTrue == true then
        return true, nil, okType == true and "GetEquippedItemType(empty)" or (okFalse == true and "Tooltip(false,empty)" or "Tooltip(true,empty)"), nil,
            TradeEquipmentName(falseTooltip) or TradeEquipmentName(trueTooltip)
    end
    return false, nil, "unavailable", table.concat(errors, " | "), nil
end

function TA:RefreshCargoObservation(reason)
    local cargo = type(self.cargo) == "table" and self.cargo or {}
    self.cargo = cargo
    local oldItemType, oldOrigin = Number(cargo.itemType), Number(cargo.originZone)
    local oldStatus, oldError, oldName = cargo.status, cargo.error, cargo.name
    local function ObservationChanged()
        return oldItemType ~= Number(cargo.itemType) or oldOrigin ~= Number(cargo.originZone)
            or oldStatus ~= cargo.status or oldError ~= cargo.error or oldName ~= cargo.name
    end
    local slot, slotSource = TradeBackpackSlot()
    cargo.slot, cargo.slotSource = slot, slotSource
    cargo.legacyEstBackpack = Number(rawget(_G, "EST_BACKPACK"))
    if slot == nil then
        cargo.status, cargo.error = "unavailable", "ES_BACKPACK/槽位27不可用"
        cargo.itemType, cargo.legacyName, cargo.name, cargo.originZone = nil, nil, nil, nil
        cargo.identityReadSource, cargo.rawItemType, cargo.tooltipName = "unavailable", nil, nil
        local changed = ObservationChanged()
        if oldItemType ~= nil then
            cargo.results, cargo.queue, cargo.scanning = {}, {}, false
            cargo.generation = (tonumber(cargo.generation) or 0) + 1
        end
        return true, changed
    end
    local ok, itemType, readSource, err, tooltipName = ReadTradeBackpackIdentity(slot)
    cargo.identityReadSource, cargo.rawItemType, cargo.tooltipName = readSource, itemType, tooltipName
    if ok ~= true then
        -- 维护（2026-09-23，trade-cargo-observation-state-1）：API 短暂不可读时保留上一次 ItemID/结果，
        -- 但必须把 unavailable/error 作为一次可观察状态变化发布；否则 UI 会继续显示“随身扫描正常”。
        cargo.status, cargo.error = "unavailable", err or "背部装备读取失败"
        return true, ObservationChanged()
    end
    if itemType == nil or itemType <= 0 then
        local identityChanged = oldItemType ~= nil
        cargo.status, cargo.error = "empty", nil
        cargo.itemType, cargo.legacyName, cargo.name, cargo.originZone = nil, nil, nil, nil
        if identityChanged then
            cargo.results, cargo.queue, cargo.scanning = {}, {}, false
            cargo.generation = (tonumber(cargo.generation) or 0) + 1
        end
        return true, ObservationChanged()
    end
    itemType = math.floor(itemType)
    local products = S.GameIds and S.GameIds.TradeProduct or nil
    local product = type(products) == "table" and type(products.GetByItemId) == "function" and products:GetByItemId(itemType) or nil
    if type(product) ~= "table" then
        local identityChanged = oldItemType ~= itemType or oldOrigin ~= nil
        cargo.status, cargo.error = "not_trade", nil
        cargo.itemType, cargo.legacyName, cargo.name, cargo.originZone = itemType, nil, LocalizedTradeItemName(itemType, nil), nil
        if identityChanged then cargo.results, cargo.queue, cargo.scanning = {}, {}, false; cargo.generation = (tonumber(cargo.generation) or 0) + 1 end
        return true, ObservationChanged()
    end
    local legacyName = tostring(product.legacyName or "")
    local static = S.Data and S.Data.TradeStaticV2 or nil
    local recipe = type(static) == "table" and type(static.GetRecipeByLegacyName) == "function" and static:GetRecipeByLegacyName(legacyName) or nil
    local originZone = type(recipe) == "table" and Number(recipe.originZoneId) or nil
    local identityChanged = oldItemType ~= itemType or oldOrigin ~= originZone
    cargo.itemType, cargo.legacyName = itemType, legacyName
    cargo.name = LocalizedTradeItemName(itemType, legacyName) or legacyName
    cargo.originZone = originZone
    -- 维护（trade-cargo-observation-state-1）：仅观察背包不能把同一货物正在进行的扫描状态从 scanning/complete
    -- 强行降回 ready。只有身份变化才重建扫描世代；普通武器/经商装变化不应重启整条目的地队列。
    if originZone == nil then
        cargo.status, cargo.error = "unknown_origin", "贸易品来源地区尚未映射"
    elseif not identityChanged and (oldStatus == "scanning" or oldStatus == "complete") then
        cargo.status, cargo.error = oldStatus, nil
    else
        cargo.status, cargo.error = "ready", nil
    end
    if identityChanged then
        cargo.results, cargo.queue, cargo.scanning = {}, {}, false
        cargo.generation = (tonumber(cargo.generation) or 0) + 1
    end
    local changed = ObservationChanged()
    TraceInit("cargo_observed", tostring(reason or "refresh") .. " slot=" .. tostring(slot) .. "/" .. tostring(slotSource) .. " read=" .. tostring(readSource) .. " item=" .. tostring(itemType) .. " origin=" .. tostring(originZone or "-"))
    return true, changed
end

function TA:ScheduleEquipmentRefresh(reason)
    if S.Scheduler == nil or type(S.Scheduler.AddOneShot) ~= "function" then
        local _, commerceChanged = self:RefreshCommerceSkill()
        local _, cargoChanged = self:RefreshCargoObservation(reason or "equipment_changed")
        if commerceChanged or cargoChanged then self:RebuildDisplayRows("trade_equipment_changed") end
        return true
    end
    S.Scheduler:RemoveTask(self.equipmentRefreshTask)
    return S.Scheduler:AddOneShot(self.equipmentRefreshTask, 220, function()
        local _, commerceChanged = TA:RefreshCommerceSkill()
        local _, cargoChanged = TA:RefreshCargoObservation(reason or "equipment_changed")
        if commerceChanged or cargoChanged then TA:RebuildDisplayRows("trade_equipment_changed") end
        if cargoChanged and Trade:GetViewMode() == "cargo" and Trade.Preferences.cargoScan == true and type(TA.StartCargoScan) == "function" then
            TA:StartCargoScan("equipment_changed")
        end
        return true
    end, Trade, "P2", 1)
end

function TA:RefreshQuotedMaterial(materialKey)
    -- 维护：100ms合并器传入受影响key集合；一条货物最多重建一次，不能只刷新首个材料。
    local keys=type(materialKey)=="table" and materialKey or {[materialKey]=true}
    local changed = false
    for _, row in ipairs(self.rows or {}) do
        local affected = false
        for _, material in ipairs(type(row.materialRows) == "table" and row.materialRows or {}) do
            if keys[material.materialKey] then affected = true; break end
        end
        if affected then ApplyTradeMaterialProjectionToRow(row); changed = true end
    end
    self.revision = self.revision + 1
    PublishFeatureUpdate(Trade, self.revision, changed and "trade_quote_completed" or "trade_quote_completed_unmatched")
    return changed
end

-- 维护（2026-09-25，trade-quote-readmodel-sync-1）：PriceQuoteQueueV3 是跨 Feature 共享报价 Authority。
-- Trade 自己的 batch callback 只能覆盖“当前 generation 且仍持有 watcher”的请求；当用户切换货物、取消上一批，
-- 或另一个模块共享同 itemType 时，报价可能在 Trade callback 之外进入 ready/failed。旧版没有消费 Queue Topic，
-- self.rows 会继续保存旧 quote_pending，导致 batch 已 1/1 ready 但 UI 永久“询价中”。这里按稳定 itemType/itemGrade
-- 只重投影命中的当前行；不发任何拍卖/货率 Native 请求、不扫描历史缓存、不创建 Tick。额外事件参数由 QuoteQueue
-- Authority 提供，禁止用本地化材料名反查，避免 Proxy 重新发明身份。
Trade.QuoteReadModelSyncContractVersion=1
TA.quoteReadModelSync={events=0,matchedRows=0,changedRows=0,lastAt=0,lastItemType=nil,lastItemGrade=nil,lastStatus=nil,lastReason=nil,lastDelivered=0}
function TA:RefreshQuotedItemType(itemType,itemGrade,status,reason)
    local id=Number(itemType)
    if id==nil or id<=0 then return false,0,0 end
    id=math.floor(id)
    local grade=Number(itemGrade)
    if grade~=nil then grade=math.floor(grade) end
    local matched,changed=0,0
    self:SyncEconomicsMaterialRevision("material_price_changed")
    for _,row in ipairs(self.rows or {}) do
        local affected=false
        for _,material in ipairs(type(row.materialRows)=="table" and row.materialRows or {}) do
            local materialId=Number(material.itemType)
            local materialGrade=Number(material.itemGrade)
            if materialId~=nil and math.floor(materialId)==id
                and (grade==nil or materialGrade==nil or math.floor(materialGrade)==grade) then
                affected=true;break
            end
        end
        if affected then
            matched=matched+1
            local before=tostring(row.profitStatus or "").."|"..tostring(row.profit or "").."|"
                ..tostring(row.materialCostStatus or "").."|"..tostring(row.materialCostCopper or "")
            ApplyTradeMaterialProjectionToRow(row)
            local after=tostring(row.profitStatus or "").."|"..tostring(row.profit or "").."|"
                ..tostring(row.materialCostStatus or "").."|"..tostring(row.materialCostCopper or "")
            if before~=after then changed=changed+1 end
        end
    end
    local sync=self.quoteReadModelSync or {}
    self.quoteReadModelSync=sync
    sync.events=(tonumber(sync.events) or 0)+1;sync.matchedRows=matched;sync.changedRows=changed
    sync.lastAt=type(S.NowMs)=="function" and S.NowMs() or 0;sync.lastItemType=id;sync.lastItemGrade=grade
    sync.lastStatus=tostring(status or "unknown");sync.lastReason=tostring(reason or "price_quote_completed")
    if matched>0 then
        self.revision=self.revision+1
        sync.lastDelivered=tonumber(PublishFeatureUpdate(Trade,self.revision,"trade_quote_readmodel_sync")) or 0
        return true,matched,changed
    end
    sync.lastDelivered=0
    return false,0,0
end

-- Live identity fill-in: after a route result, rows the static chain could not
-- name submit ONE bounded service request per distinct product itemType; the
-- identity service serializes the X2Craft reads and calls back here.
function TA:RequestPendingLiveIdentities()
    -- 页面关闭但货率后台 Runtime 仍运行时，不得因此保活制作/材料身份扫描；重新打开页面会通过
    -- demand_start_projection 再次调用本函数并按当前可见行补齐。
    if (tonumber(Trade.consumerCount) or 0) <= 0 then return end
    local identity = S.Services and S.Services.TradeMaterialIdentityV3 or nil
    if type(identity) ~= "table" or type(identity.RequestLive) ~= "function" then return end
    local requested = {}
    for _, row in ipairs(TA.rows or {}) do
        local itemType = tonumber(row.itemType)
        if row.materialIdentityPending == true and itemType ~= nil and requested[itemType] ~= true then
            requested[itemType] = true
            identity:RequestLive("life_trade", itemType, function(requestItemType)
                return TA:ApplyLiveIdentity(requestItemType)
            end)
        end
    end
end

function TA:ApplyLiveIdentity(itemType)
    local changed = false
    for _, row in ipairs(self.rows or {}) do
        if tonumber(row.itemType) ~= nil and tonumber(row.itemType) == tonumber(itemType) then
            ApplyTradeMaterialProjectionToRow(row)
            changed = true
        end
    end
    if changed then
        self.revision = self.revision + 1
        PublishFeatureUpdate(Trade, self.revision, "trade_identity_live")
    end
    return changed
end

function TA:CancelLiveIdentities()
    local identity = S.Services and S.Services.TradeMaterialIdentityV3 or nil
    if type(identity) == "table" and type(identity.CancelRequester) == "function" then
        return identity:CancelRequester("life_trade")
    end
    return 0
end

function TA:DescribeIdentityState()
    local total, unresolved, livePending, firstUnresolved = #(self.rows or {}), 0, 0, nil
    for _, row in ipairs(self.rows or {}) do
        if row.identityStatus == "live_pending" then livePending = livePending + 1 end
        if row.identityStatus ~= nil and row.identityStatus ~= "resolved" then
            unresolved = unresolved + 1
            if firstUnresolved == nil then firstUnresolved = tostring(row.sourceName or row.name or "?") end
        end
    end
    local identity = S.Services and S.Services.TradeMaterialIdentityV3 or nil
    return {
        rows = total, unresolved = unresolved, livePending = livePending,
        firstUnresolved = firstUnresolved,
        live = type(identity) == "table" and type(identity.Describe) == "function" and identity:Describe() or nil,
    }
end

-- Bounded init/refresh milestone ring. The user-facing reload symptom "很多东
-- 西没有初始化成功" cannot be reproduced statically; this trace records what
-- actually happened during demand 0->1 (store restore, zones, commerce, route)
-- so the diagnostics panel answers it with facts on the next repro.
TraceInit = function(event, detail)
    TA.initTrace = type(TA.initTrace) == "table" and TA.initTrace or {}
    TA.initTrace[#TA.initTrace + 1] = {
        at = S.NowMs and S.NowMs() or 0,
        event = tostring(event),
        detail = tostring(detail or ""),
    }
    if #TA.initTrace > 12 then table.remove(TA.initTrace, 1) end
end

function TA:DescribeInitTrace()
    local out = {}
    for _, record in ipairs(type(TA.initTrace) == "table" and TA.initTrace or {}) do
        out[#out + 1] = { at = tonumber(record.at) or 0, event = tostring(record.event), detail = tostring(record.detail or "") }
    end
    return {
        enabled = Trade.enabled == true,
        runtimeEnabled = S.FeatureRuntime ~= nil and S.FeatureRuntime:IsEnabled(Trade.Id) == true,
        storeLoaded = Trade.storeLoaded == true,
        consumerCount = tonumber(Trade.consumerCount) or 0,
        milestones = out,
    }
end

function TA:RefreshZones()
    self.sellableCache = {}
    local ok, value, err = Call("X2Store:GetProductionZoneGroups", StoreApi, "GetProductionZoneGroups")
    self.zones = ok == true and NormalizeTradeZones(value) or {}
    self.zoneFallback = false
    if #self.zones == 0 then
        -- RU builds can transiently reject or shape-shift the production-zone
        -- getter.  The curated Zone table is already an accepted candidate
        -- fallback; use it on API failure as well as empty responses so the
        -- dropdown remains selectable. GetSpecialtyRatioBetween is still the
        -- server Authority that accepts/rejects the final route.
        self.zones = NormalizeTradeZones(StaticTradeZones())
        self.zoneFallback = #self.zones > 0
    end
    self.sellableZones = {}
    self.sellableFallback, self.sellableError = false, nil
    if #self.zones > 0 then
        self.status = "ready"
        self.error = ok == true and nil or (err or "生产地区 API 不可用，已使用静态候选")
    else
        self.status = ok == true and "empty" or "unavailable"
        self.error = err or "生产地区列表为空"
    end
    local valid = false
    for _, row in ipairs(self.zones) do if row.id == Number(Trade.State.fromZone) then valid = true end end
    if not valid then Trade.State.fromZone, Trade.State.toZone = nil, nil end
    if Trade.State.fromZone ~= nil then self:RefreshSellable() end
    self.revision = self.revision + 1
    PublishFeatureUpdate(Trade, self.revision, "zones")
    return true
end

function TA:RefreshSellable(force)
    local from = Number(Trade.State.fromZone)
    if from == nil then self.sellableZones, Trade.State.toZone = {}, nil; return true end
    -- Session cache: cycling routes re-reads the same small zone list many
    -- times; skip the per-click GetSellableZoneGroups round trip unless the
    -- caller explicitly forces a refresh.
    local cached = force ~= true and self.sellableCache[from] or nil
    if cached ~= nil then
        self.sellableZones, self.sellableFallback, self.sellableError = cached.list, cached.fallback, cached.error
        local found = false
        for _, row in ipairs(self.sellableZones or {}) do if row.id == Number(Trade.State.toZone) then found = true end end
        if not found then Trade.State.toZone = nil end
        self.revision = self.revision + 1
        PublishFeatureUpdate(Trade, self.revision, "sellable_cached")
        return true
    end
    local ok, value, sellableErr = Call("X2Store:GetSellableZoneGroups", StoreApi, "GetSellableZoneGroups", from)
    local list = ok and NormalizeTradeZones(value) or {}
    self.sellableFallback, self.sellableError = false, nil
    if #list == 0 then
        -- Some RU builds expose production groups but return an empty/shape-variant
        -- sellable list. Offer the bounded production-group set as candidate UI
        -- choices; the server's GetSpecialtyRatioBetween remains the authority
        -- that accepts/rejects the selected route.
        for _, row in ipairs(self.zones or {}) do if row.id ~= from then list[#list + 1] = Copy(row) end end
        self.sellableFallback = #list > 0
        self.sellableError = sellableErr or (ok and "可售地区列表为空，已使用生产地区候选" or "可售地区 API 不可用，已使用生产地区候选")
    end
    self.sellableZones = list
    self.sellableCache[from] = { list = list, fallback = self.sellableFallback, error = self.sellableError }
    local found = false
    for _, row in ipairs(list) do if row.id == Number(Trade.State.toZone) then found = true end end
    if not found then Trade.State.toZone = nil; self.rawRows, self.rows = {}, {}; self.status = "idle" end
    self.revision = self.revision + 1
    PublishFeatureUpdate(Trade, self.revision, "sellable")
    return true
end

function TA:TraceRequest(event, spec, detail)
    self.requestTrace = type(self.requestTrace) == "table" and self.requestTrace or {}
    local row = {
        at = S.NowMs and tonumber(S.NowMs()) or 0,
        event = tostring(event or "?"),
        kind = type(spec) == "table" and tostring(spec.kind or "route") or "route",
        from = type(spec) == "table" and Number(spec.from) or nil,
        to = type(spec) == "table" and Number(spec.to) or nil,
        reason = type(spec) == "table" and tostring(spec.reason or "") or "",
        detail = tostring(detail or ""),
    }
    self.requestTrace[#self.requestTrace + 1] = row
    if #self.requestTrace > 20 then table.remove(self.requestTrace, 1) end
end

function TA:CancelRequestTimeout()
    if S.Scheduler ~= nil and type(S.Scheduler.RemoveTask) == "function" then S.Scheduler:RemoveTask(self.requestTimeoutTask) end
end

function TA:CancelTimeoutDrain()
    if S.Scheduler ~= nil and type(S.Scheduler.RemoveTask) == "function" then S.Scheduler:RemoveTask(self.timeoutDrainTask) end
    self.timeoutDrainUntil = 0
end

function TA:GetTimeoutDrainRemaining()
    local now = S.NowMs and tonumber(S.NowMs()) or 0
    return math.max(0, (tonumber(self.timeoutDrainUntil) or 0) - now)
end

-- 维护（2026-09-23，trade-timeout-drain-1）：SPECIALTY_RATIO_BETWEEN_INFO 没有 request-id。旧代码在
-- 6.5s 超时后立刻释放 SingleFlight 并发起下一条路线/目的地；若旧回调随后迟到，它会被误认成“当前 inFlight”，
-- 把 A→B 的 payload 写进 C→D。这里仅在“已超时”冷路径保留 2s drain 窗口：正常路线切换零额外延迟；
-- 迟到回调先按 timedOutFlight 消费，若窗口内始终无回调，再恢复最新 pendingRoute/cargo 队列。
function TA:ArmTimeoutDrain(flight)
    if S.Scheduler == nil or type(S.Scheduler.AddOneShot) ~= "function" then
        self.timedOutFlight, self.timeoutDrainUntil = nil, 0
        return false
    end
    self:CancelTimeoutDrain()
    self.timedOutFlight = type(flight) == "table" and flight or nil
    local delay = math.max(500, tonumber(self.timeoutDrainMs) or 2000)
    local now = S.NowMs and tonumber(S.NowMs()) or 0
    self.timeoutDrainUntil = now + delay
    self:TraceRequest("timeout_drain_start", flight, "delay=" .. tostring(delay))
    local added = S.Scheduler:AddOneShot(self.timeoutDrainTask, delay, function()
        local timedOut = TA.timedOutFlight
        TA.timeoutDrainUntil = 0
        if TA.inFlight ~= nil then return true end
        TA.timedOutFlight = nil
        if type(timedOut) == "table" then TA:TraceRequest("timeout_drain_expired", timedOut, "") end
        -- A cargo timeout is only committed after the drain window expires. If a late callback arrived, OnRatio
        -- cancelled this task and OnCargoRatio advanced queueIndex exactly once. Advancing at the original timeout
        -- would make a late callback advance it a second time and silently skip the next destination.
        if type(timedOut) == "table" and tostring(timedOut.kind or "route") == "cargo" then
            local cargo = TA.cargo
            if cargo.scanning == true and tonumber(cargo.generation) == tonumber(timedOut.cargoGeneration)
                and Number(cargo.itemType) == Number(timedOut.itemType) then
                cargo.results[Number(timedOut.to)] = { destinationZone = Number(timedOut.to), error = "查询超时", updatedAt = S.NowMs and tonumber(S.NowMs()) or 0 }
                cargo.queueIndex = (tonumber(cargo.queueIndex) or 1) + 1
                cargo.error = "部分目的地查询超时，已继续扫描"
                TA:RebuildDisplayRows("cargo_request_timeout_committed")
            end
        end
        local pending = type(TA.pendingRoute) == "table" and TA.pendingRoute or nil
        if pending ~= nil then return TA:Request(pending.force ~= false, pending.reason or "route_change") end
        if type(timedOut) == "table" and tostring(timedOut.kind or "route") == "cargo" and TA.cargo.scanning == true then
            return TA:ArmCargoPump(50)
        end
        Trade:MaybeReleaseNativeRatioSubscription("timeout_drain_expired")
        return true
    end, Trade, "P2", 1)
    if added ~= true then self.timedOutFlight, self.timeoutDrainUntil = nil, 0 end
    return added == true
end

function TA:CancelDeferredRequest()
    if S.Scheduler ~= nil and type(S.Scheduler.RemoveTask) == "function" then S.Scheduler:RemoveTask(self.requestDeferredTask) end
    self.deferredReason = nil
end

function TA:CancelAutoRefresh()
    if S.Scheduler ~= nil and type(S.Scheduler.RemoveTask) == "function" then S.Scheduler:RemoveTask(self.requestAutoTask) end
end

function TA:CancelEquipmentRefresh()
    if S.Scheduler ~= nil and type(S.Scheduler.RemoveTask) == "function" then S.Scheduler:RemoveTask(self.equipmentRefreshTask) end
end

function TA:CancelCargoTasks()
    if S.Scheduler ~= nil and type(S.Scheduler.RemoveTask) == "function" then
        S.Scheduler:RemoveTask(self.cargoPumpTask)
        S.Scheduler:RemoveTask(self.cargoRescanTask)
    end
end

-- 维护（2026-09-23，trade-cargo-generation-stop-1）：停止随身扫描不能只把 scanning=false。Native 回调没有
-- request-id，已经发出的 cargo 请求仍可能迟到；若不推进 generation，旧回调会重新写 results/lastScanAt，甚至把
-- “已关闭/已卸货”的状态重新推进为 complete。这里保留 inFlight 直到真实回调释放 SingleFlight，但使其结果世代失效。
-- Presentation 只读取 cargo Projection，不拥有取消语义；重新启用扫描会创建新 generation 并在旧 lane 释放后继续。
function TA:StopCargoScan(reason, preserveStatus)
    self:CancelCargoTasks()
    local cargo = type(self.cargo) == "table" and self.cargo or {}
    self.cargo = cargo
    local wasScanning = cargo.scanning == true
    cargo.scanning = false
    cargo.generation = (tonumber(cargo.generation) or 0) + 1

    local itemType, originZone = Number(cargo.itemType), Number(cargo.originZone)
    -- Observation failures (API unavailable / unknown origin / non-trade item) already carry the truthful status/error.
    -- Stopping the scan must invalidate its generation without rewriting that evidence back to ready/complete.
    if preserveStatus ~= true then
        if itemType ~= nil and originZone ~= nil then
            local hasResults = false
            for _ in pairs(type(cargo.results) == "table" and cargo.results or {}) do hasResults = true; break end
            cargo.status = hasResults and "complete" or "ready"
            if tostring(reason or "") == "scan_disabled" then cargo.error = nil end
        elseif cargo.status == "scanning" or cargo.status == "complete" or cargo.status == "ready" then
            cargo.status = itemType ~= nil and "unknown_origin" or "empty"
        end
    end
    self:TraceRequest("cargo_scan_stop", { kind = "cargo", from = originZone, reason = reason }, wasScanning and "active=1" or "active=0")
    return true
end

-- 维护（2026-09-23，trade-native-cooldown-4）：实机已经证明该数值必须作为 Native 查询窗口处理。
-- SPECIALTY_RATIO_BETWEEN_INFO 又没有 request-id，因此路线切换不能在冷却内并发/抢跑；否则可能得到
-- “函数调用成功但没有本路线回调”，最后进入超时恢复。现在统一由 Scheduler 等窗口到期，已查过路线则
-- 先恢复会话缓存，保证交互有即时反馈；所有 Native 调用仍只有一条 SingleFlight lane。
function TA:GetNativeCooldownRemaining()
    local now = S.NowMs and tonumber(S.NowMs()) or 0
    return math.max(0, (tonumber(self.nextNativeRequestAt) or 0) - now)
end

function TA:HasRawRowsForRoute(from, to)
    from, to = Number(from), Number(to)
    if from == nil or to == nil or #(self.rawRows or {}) == 0 then return false end
    local first = self.rawRows[1]
    return type(first) == "table" and Number(first.originZone) == from and Number(first.destinationZone) == to
end

local function TradeRouteCacheKey(from, to)
    from, to = Number(from), Number(to)
    if from == nil or to == nil then return nil end
    return tostring(math.floor(from)) .. ":" .. tostring(math.floor(to))
end

function TA:StoreRouteCache(from, to, rows, updatedAt)
    local key = TradeRouteCacheKey(from, to)
    if key == nil or type(rows) ~= "table" or #rows == 0 then return false end
    self.routeCache = type(self.routeCache) == "table" and self.routeCache or {}
    self.routeCacheOrder = type(self.routeCacheOrder) == "table" and self.routeCacheOrder or {}
    self.routeCache[key] = { from = Number(from), to = Number(to), rows = Copy(rows), updatedAt = tonumber(updatedAt) or 0 }
    for index = #self.routeCacheOrder, 1, -1 do
        if self.routeCacheOrder[index] == key then table.remove(self.routeCacheOrder, index) end
    end
    self.routeCacheOrder[#self.routeCacheOrder + 1] = key
    local limit = math.max(1, math.floor(tonumber(self.routeCacheMax) or 12))
    while #self.routeCacheOrder > limit do
        local evicted = table.remove(self.routeCacheOrder, 1)
        self.routeCache[evicted] = nil
    end
    return true
end

function TA:RestoreRouteCache(from, to, reason)
    local key = TradeRouteCacheKey(from, to)
    local entry = key ~= nil and type(self.routeCache) == "table" and self.routeCache[key] or nil
    if type(entry) ~= "table" or type(entry.rows) ~= "table" or #entry.rows == 0 then return false end
    self.rawRows = Copy(entry.rows)
    self.lastCompletedRoute = { from = Number(from), to = Number(to) }
    self.lastRatioAt = tonumber(entry.updatedAt) or 0
    self.selectedKey = nil
    self.status, self.error = "ready", nil
    self:MarkEconomicsPayoutInput(reason or "route_cache_restore")
    self:RebuildDisplayRows(reason or "route_cache_restore", { includeMaterials = false })
    self:ScheduleDeferredMaterialProjection(reason or "route_cache_restore", 60)
    self:TraceRequest("route_cache_restore", { kind = "route", from = from, to = to, reason = reason or "route_change" }, "rows=" .. tostring(#self.rawRows))
    return true
end

function TA:GetSellableForOrigin(origin, force)
    origin = Number(origin)
    if origin == nil then return {}, false, "贸易品来源地区不可用" end
    local cached = force ~= true and self.sellableCache[origin] or nil
    if type(cached) == "table" and type(cached.list) == "table" then
        return cached.list, cached.fallback == true, cached.error
    end
    local ok, value, sellableErr = Call("X2Store:GetSellableZoneGroups", StoreApi, "GetSellableZoneGroups", origin)
    local list = ok == true and NormalizeTradeZones(value) or {}
    local fallback, errorText = false, nil
    if #list == 0 then
        for _, row in ipairs(self.zones or {}) do
            if Number(row.id) ~= origin then list[#list + 1] = Copy(row) end
        end
        fallback = #list > 0
        errorText = sellableErr or (ok == true and "可售地区列表为空，已使用生产地区候选" or "可售地区 API 不可用，已使用生产地区候选")
    end
    self.sellableCache[origin] = { list = list, fallback = fallback, error = errorText }
    return list, fallback, errorText
end

function TA:ArmDeferredRequest(delayMs, reason)
    if S.Scheduler == nil or type(S.Scheduler.AddOneShot) ~= "function" then return false end
    self:CancelDeferredRequest()
    local delay = math.max(50, tonumber(delayMs) or 50)
    self.deferredReason = tostring(reason or "deferred")
    self.diag = type(self.diag) == "table" and self.diag or {}
    self.diag.deferredRequests = (tonumber(self.diag.deferredRequests) or 0) + 1
    return S.Scheduler:AddOneShot(self.requestDeferredTask, delay, function()
        local pending = type(TA.pendingRoute) == "table" and TA.pendingRoute or nil
        local from, to = Number(Trade.State.fromZone), Number(Trade.State.toZone)
        if from == nil or to == nil then
            TA.pendingRoute = nil
            TA.status, TA.error = "idle", "请先选择完整路线"
            TA.revision = TA.revision + 1
            PublishFeatureUpdate(Trade, TA.revision, "route_deferred_cancelled")
            return true
        end
        local requestReason = pending and pending.reason or TA.deferredReason or "deferred"
        TA.deferredReason = nil
        return TA:Request(pending == nil or pending.force ~= false, requestReason)
    end, Trade, "P2", 1)
end

-- 中文维护注释（2026-09-26，trade-auto-refresh-runtime-split-1）：货率自动刷新继续使用一个低频 watchdog，
-- 但后台运行资格不再由 Trade.consumerCount 决定。页面/悬浮窗 Consumer 只拥有可见业务资源；自动刷新由
-- Trade.AutoRefreshRuntime 独立拥有 Scheduler + Native ratio callback + 可选跨区事件。这样主页面关闭后仍能维护当前路线，
-- 同时不会把拍卖报价、装备观察、LiveIdentity 等页面资源一起保活。真正 Native 查询仍全部经过 TA:Request 的
-- SingleFlight/cooldown/timeout quarantine；watchdog 每秒只做 O(1) 年龄检查，绝不在 Tick/循环里直接调用 X2Store。
function TA:GetAutoRefreshTargetMs()
    local baseTarget = math.max(1000, tonumber(self.autoRefreshTargetMs) or 10000)
    local cooldownTarget = math.max(0, tonumber(self.lastNativeCooldownMs) or 0) * math.max(1, tonumber(self.autoRefreshCooldownFactor) or 2)
    return math.max(baseTarget, cooldownTarget)
end

function TA:GetAutoRefreshWatchTaskState()
    local scheduler = S.Scheduler
    if type(scheduler) == "table" and type(scheduler.GetTaskState) == "function" then
        return scheduler:GetTaskState(self.requestAutoTask)
    end
    local task = type(scheduler) == "table" and type(scheduler.tasks) == "table" and scheduler.tasks[self.requestAutoTask] or nil
    return { registered = type(task) == "table", enabled = type(task) == "table" and task.enabled == true or false, pending = type(task) == "table" and task.pending == true or false }
end

function TA:IsAutoRefreshWatchActive()
    local state = self:GetAutoRefreshWatchTaskState()
    return type(state) == "table" and state.registered == true and state.enabled == true
end

function TA:GetAutoRefreshState()
    local now = S.NowMs and tonumber(S.NowMs()) or 0
    local target = self:GetAutoRefreshTargetMs()
    local dataAt = tonumber(self.lastRatioAt) or 0
    local lastNativeAt = type(self.diag) == "table" and tonumber(self.diag.lastRequestAt) or 0
    local lastTriggerAt = type(self.autoRefreshDiagnostics) == "table" and tonumber(self.autoRefreshDiagnostics.lastTriggerAt) or 0
    local anchor = math.max(dataAt, lastNativeAt or 0, lastTriggerAt or 0)
    local age = dataAt > 0 and math.max(0, now - dataAt) or nil
    local nextIn = math.max(0, target - math.max(0, now - anchor))
    local watchTask = self:GetAutoRefreshWatchTaskState()
    return {
        enabled = Trade.Preferences.autoRefresh == true,
        runtimeActive = type(Trade.ShouldRunAutoRefreshBackground) == "function" and Trade:ShouldRunAutoRefreshBackground() == true or false,
        worldEventSubscribed = Trade.autoRefreshWorldSubscribed == true,
        uiConsumers = tonumber(Trade.consumerCount) or 0,
        watchActive = type(watchTask) == "table" and watchTask.registered == true and watchTask.enabled == true,
        watchRegistered = type(watchTask) == "table" and watchTask.registered == true,
        watchEnabled = type(watchTask) == "table" and watchTask.enabled == true,
        watchPending = type(watchTask) == "table" and watchTask.pending == true,
        watchRunCount = type(watchTask) == "table" and tonumber(watchTask.runCount) or 0,
        watchFailureTotal = type(watchTask) == "table" and tonumber(watchTask.failureTotal) or 0,
        watchLastError = type(watchTask) == "table" and watchTask.lastError or nil,
        targetMs = target, watchIntervalMs = math.max(250, tonumber(self.autoRefreshWatchIntervalMs) or 1000),
        dataAgeMs = age, nextInMs = nextIn,
    }
end

function TA:ArmAutoRefresh(delayMs, reason)
    if type(self.autoRefreshDiagnostics) ~= "table" then self.autoRefreshDiagnostics = {} end
    local now = S.NowMs and tonumber(S.NowMs()) or 0
    local delay = math.max(0, tonumber(delayMs) or 0)
    self.autoRefreshDiagnostics.notBeforeAt = math.max(tonumber(self.autoRefreshDiagnostics.notBeforeAt) or 0, now + delay)
    if reason ~= nil then self.autoRefreshDiagnostics.lastReason = tostring(reason) end
    return self:ScheduleNextAutoRefresh(reason or "arm")
end

function TA:ScheduleNextAutoRefresh(reason)
    if type(Trade.ShouldRunAutoRefreshBackground) ~= "function" or Trade:ShouldRunAutoRefreshBackground() ~= true then
        self:CancelAutoRefresh()
        return false
    end
    if S.Scheduler == nil or type(S.Scheduler.AddTask) ~= "function" then return false end

    self.autoRefreshDiagnostics = type(self.autoRefreshDiagnostics) == "table" and self.autoRefreshDiagnostics or {}
    local diagnostics = self.autoRefreshDiagnostics
    local interval = math.max(250, tonumber(self.autoRefreshWatchIntervalMs) or 1000)
    local now = S.NowMs and tonumber(S.NowMs()) or 0
    local taskState = self:GetAutoRefreshWatchTaskState()
    local lastCheckAt = tonumber(diagnostics.lastCheckAt) or 0
    local lastWatchStartAt = tonumber(diagnostics.lastWatchStartAt) or 0
    local watchLivenessAt = math.max(lastCheckAt, lastWatchStartAt)
    local staleRegisteredTask = type(taskState) == "table" and taskState.registered == true and watchLivenessAt > 0
        and (now - watchLivenessAt) > math.max(5000, interval * 5)
    if type(taskState) == "table" and taskState.registered == true and taskState.enabled == true and staleRegisteredTask ~= true then return true end

    -- 维护（2026-09-27，trade-auto-watchdog-self-heal-1）：18.324 实机出现 watchActive=true 但 135s 内
    -- checks 不再增长。旧 IsAutoRefreshWatchActive 只看“任务表里有没有名字”，即使任务已禁用/僵住也阻止重建。
    -- 每次成功货率 callback/Runtime reconcile 都会经过这里，因此把 disabled 或超过 5 个周期未检查的旧实例撤销并
    -- 重建；正常 pending/运行中的实例不动。Native 请求仍全部经过 TA:Request SingleFlight，不会因此并发。
    if type(taskState) == "table" and taskState.registered == true then
        if type(S.Scheduler.RemoveTask) == "function" then S.Scheduler:RemoveTask(self.requestAutoTask) end
        diagnostics.watchRestarts = (tonumber(diagnostics.watchRestarts) or 0) + 1
        if staleRegisteredTask then diagnostics.staleRestarts = (tonumber(diagnostics.staleRestarts) or 0) + 1 end
        diagnostics.lastRestartAt = now
        diagnostics.lastRestartReason = staleRegisteredTask and "stale_registered_task" or "disabled_registered_task"
    end

    diagnostics.watchStarts = (tonumber(diagnostics.watchStarts) or 0) + 1
    diagnostics.lastWatchStartAt = now
    diagnostics.lastReason = tostring(reason or "schedule_next")
    return S.Scheduler:AddTask(self.requestAutoTask, interval, function()
        local d = TA.autoRefreshDiagnostics
        local now = S.NowMs and tonumber(S.NowMs()) or 0
        local previousCheckAt = tonumber(d.lastCheckAt) or 0
        local gap = previousCheckAt > 0 and math.max(0, now - previousCheckAt) or 0
        d.checks = (tonumber(d.checks) or 0) + 1
        d.lastCheckGapMs = gap
        d.maxCheckGapMs = math.max(tonumber(d.maxCheckGapMs) or 0, gap)
        d.lastCheckAt = now

        if type(Trade.ShouldRunAutoRefreshBackground) ~= "function" or Trade:ShouldRunAutoRefreshBackground() ~= true then
            d.lastDecision = "inactive"
            return true
        end

        local target = TA:GetAutoRefreshTargetMs()
        local notBeforeAt = tonumber(d.notBeforeAt) or 0
        if now < notBeforeAt then
            d.lastDecision = "not_before"
            return true
        end
        local lastRatioAt = tonumber(TA.lastRatioAt) or 0
        local lastNativeAt = type(TA.diag) == "table" and tonumber(TA.diag.lastRequestAt) or 0
        local lastTriggerAt = tonumber(d.lastTriggerAt) or 0
        local anchor = math.max(lastRatioAt, lastNativeAt or 0, lastTriggerAt)
        if anchor > 0 and (now - anchor) < target then
            d.skippedFresh = (tonumber(d.skippedFresh) or 0) + 1
            d.lastDecision = "fresh"
            return true
        end
        if TA.inFlight ~= nil or TA.pendingRoute ~= nil or TA.timedOutFlight ~= nil then
            d.skippedBusy = (tonumber(d.skippedBusy) or 0) + 1
            d.lastDecision = "singleflight_busy"
            return true
        end

        d.lastTriggerAt = now
        d.triggered = (tonumber(d.triggered) or 0) + 1
        d.lastDecision = "trigger"
        local ok, requestErr = TA:Request(false, "auto_refresh")
        if ok ~= true then
            -- Native/调度失败不能让 watchdog 消失；target 时间窗同时充当失败退避，避免 1 秒循环轰炸。
            d.lastDecision = "request_failed"
            d.lastError = tostring(requestErr or "request_not_started")
        else
            d.lastError = nil
        end
        return true
    end, true, Trade.autoRefreshRuntimeOwner or Trade, "P2", 1)
end

function TA:ArmCargoPump(delayMs)
    if S.Scheduler == nil or type(S.Scheduler.AddOneShot) ~= "function" then return false end
    if S.Scheduler.RemoveTask ~= nil then S.Scheduler:RemoveTask(self.cargoPumpTask) end
    local delay = math.max(50, tonumber(delayMs) or 50)
    return S.Scheduler:AddOneShot(self.cargoPumpTask, delay, function() return TA:PumpCargoQueue() end, Trade, "P3", 1)
end

function TA:ScheduleCargoRescan(delayMs)
    if S.Scheduler == nil or type(S.Scheduler.AddOneShot) ~= "function" then return false end
    if S.Scheduler.RemoveTask ~= nil then S.Scheduler:RemoveTask(self.cargoRescanTask) end
    if Trade.enabled ~= true or (tonumber(Trade.consumerCount) or 0) <= 0 or Trade:GetViewMode() ~= "cargo" or Trade.Preferences.cargoScan ~= true then return false end
    local delay = math.max(1000, tonumber(delayMs) or tonumber(self.cargoRescanIntervalMs) or 15000)
    return S.Scheduler:AddOneShot(self.cargoRescanTask, delay, function()
        if Trade.enabled == true and (tonumber(Trade.consumerCount) or 0) > 0 and Trade:GetViewMode() == "cargo" and Trade.Preferences.cargoScan == true then
            TA:StartCargoScan("periodic")
        end
        return true
    end, Trade, "P3", 1)
end

function TA:StartCargoScan(reason)
    self:CancelAutoRefresh()
    if Trade.enabled ~= true or (tonumber(Trade.consumerCount) or 0) <= 0 then return false, "跑商功能未运行" end
    if Trade:GetViewMode() ~= "cargo" or Trade.Preferences.cargoScan ~= true then
        self:StopCargoScan("scan_disabled")
        return true
    end
    -- 维护（2026-09-23，trade-cargo-restart-lifecycle-1）：开始一轮新扫描先撤销上一轮 pump/rescan one-shot。
    -- 否则“上一轮 complete 后已排的 rescan”可能在新货物扫描中途触发 StartCargoScan，再次推进 generation/重置队列。
    -- Native inFlight 不在这里强行清除；它仍由 generation + SingleFlight 正确归属/淘汰。
    self:CancelCargoTasks()
    local _, cargoChanged = self:RefreshCargoObservation(reason or "cargo_scan")
    local cargo = self.cargo
    if cargo.status ~= "ready" and cargo.status ~= "scanning" and cargo.status ~= "complete" then
        self:StopCargoScan("cargo_not_ready", true)
        self:RebuildDisplayRows("cargo_not_ready")
        return false, cargo.error or "当前背部没有可识别贸易品"
    end
    if Number(cargo.originZone) == nil or Number(cargo.itemType) == nil then
        self:StopCargoScan("cargo_origin_missing", true)
        self:RebuildDisplayRows("cargo_origin_missing")
        return false, cargo.error or "贸易品来源地区尚未映射"
    end
    local destinations, fallback, sellableErr = self:GetSellableForOrigin(cargo.originZone, false)
    cargo.generation = (tonumber(cargo.generation) or 0) + 1
    cargo.queue, cargo.queueIndex = {}, 1
    for _, row in ipairs(destinations or {}) do
        local to = Number(row.id)
        if to ~= nil and to ~= Number(cargo.originZone) then cargo.queue[#cargo.queue + 1] = to end
        if #cargo.queue >= 48 then break end
    end
    cargo.scanning = #cargo.queue > 0
    cargo.status = cargo.scanning and "scanning" or "complete"
    cargo.error = #cargo.queue == 0 and (sellableErr or "没有可扫描的目的地") or nil
    cargo.sellableFallback = fallback == true
    cargo.scanStartedAt = S.NowMs and tonumber(S.NowMs()) or 0
    -- 维护（trade-cargo-stale-while-refresh-1）：周期刷新期间继续显示上一轮结果，但只保留仍在当前可售集合中的目的地；
    -- lastScanAt 代表“最后一份真实结果/完整扫描”的时间，不能在仅开始新扫描时伪装成刚更新。
    local keepResults, validDestination = {}, {}
    for _, to in ipairs(cargo.queue or {}) do validDestination[Number(to)] = true end
    for to, result in pairs(type(cargo.results) == "table" and cargo.results or {}) do
        local key = Number(to)
        if key ~= nil and validDestination[key] == true then keepResults[key] = result end
    end
    cargo.results = keepResults
    self:TraceRequest("cargo_scan_start", { kind = "cargo", from = cargo.originZone, reason = reason }, "destinations=" .. tostring(#cargo.queue) .. " changed=" .. tostring(cargoChanged == true))
    self:RebuildDisplayRows("cargo_scan_start")
    if cargo.scanning then return self:PumpCargoQueue() end
    self:ScheduleCargoRescan()
    return true
end

function TA:PumpCargoQueue()
    local cargo = self.cargo
    if Trade.enabled ~= true or (tonumber(Trade.consumerCount) or 0) <= 0 or Trade:GetViewMode() ~= "cargo" or Trade.Preferences.cargoScan ~= true then
        self:StopCargoScan("pump_inactive")
        return true
    end
    -- A stale callback/task from an invalidated generation must never resurrect an empty/disabled cargo state.
    if cargo.scanning ~= true then return true end
    -- Gate on the ownership token, not wall-clock remaining. The scheduler may run late under backlog; once a timed-out
    -- callback owns quarantine, no newer Native request may start until the drain callback explicitly releases it.
    if type(self.timedOutFlight) == "table" then return true end
    if type(self.pendingRoute) == "table" then
        if self.inFlight == nil then return self:Request(true, self.pendingRoute.reason or "route_change") end
        return true
    end
    if self.inFlight ~= nil then return true end
    local nextIndex = math.max(1, tonumber(cargo.queueIndex) or 1)
    local destination = cargo.queue and cargo.queue[nextIndex] or nil
    if destination == nil then
        cargo.scanning = false
        cargo.status = "complete"
        cargo.lastScanAt = S.NowMs and tonumber(S.NowMs()) or cargo.lastScanAt
        self:RebuildDisplayRows("cargo_scan_complete")
        self:TraceRequest("cargo_scan_complete", { kind = "cargo", from = cargo.originZone }, "results=" .. tostring((function() local n=0; for _ in pairs(cargo.results or {}) do n=n+1 end; return n end)()))
        self:ScheduleCargoRescan()
        return true
    end
    local remaining = self:GetNativeCooldownRemaining()
    if remaining > 0 then return self:ArmCargoPump(remaining + 50) end
    return self:StartCargoNativeRequest(destination)
end

function TA:RecordNativeAccepted(nativeCooldownOrErr, flight)
    local nativeCooldown = tonumber(nativeCooldownOrErr) or 0
    if nativeCooldown < 0 then nativeCooldown = 0 elseif nativeCooldown > 60000 then nativeCooldown = 60000 end
    self.lastNativeCooldownMs = nativeCooldown
    local now = S.NowMs and tonumber(S.NowMs()) or 0
    self.nextNativeRequestAt = now + nativeCooldown
    self.diag = type(self.diag) == "table" and self.diag or {}
    self.diag.nativeRequests = (tonumber(self.diag.nativeRequests) or 0) + 1
    self.diag.lastRequestAt = now
    self.diag.lastNativeCooldownMs = nativeCooldown
    self.diag.lastRequestReason = type(flight) == "table" and tostring(flight.reason or "") or ""
    self:TraceRequest("native_accepted", flight, "cooldown=" .. tostring(nativeCooldown))
    return nativeCooldown
end

function TA:StartCargoNativeRequest(destination)
    local cargo = self.cargo
    destination = Number(destination)
    if cargo.scanning ~= true then return false, "随身货物扫描已停止" end
    if destination == nil or Number(cargo.originZone) == nil or Number(cargo.itemType) == nil then return false, "随身货物扫描参数不完整" end
    if self.inFlight ~= nil then return false, "Native 查询通道占用中" end
    local generation = tonumber(cargo.generation) or 0
    self.requestSerial = (tonumber(self.requestSerial) or 0) + 1
    local serial = self.requestSerial
    local flight = {
        kind = "cargo", from = Number(cargo.originZone), to = destination, serial = serial,
        startedAt = S.NowMs and tonumber(S.NowMs()) or 0, reason = "cargo_scan",
        cargoGeneration = generation, itemType = Number(cargo.itemType), legacyName = cargo.legacyName,
    }
    self.inFlight = flight
    self:TraceRequest("native_attempt", flight, "")
    local ok, nativeCooldownOrErr = Action("X2Store:GetSpecialtyRatioBetween", StoreApi, "GetSpecialtyRatioBetween", flight.from, flight.to)
    if ok ~= true then
        self.inFlight = nil
        cargo.results[destination] = { destinationZone = destination, error = tostring(nativeCooldownOrErr or "服务器未接受查询"), updatedAt = S.NowMs and tonumber(S.NowMs()) or 0 }
        cargo.queueIndex = (tonumber(cargo.queueIndex) or 1) + 1
        self:TraceRequest("native_rejected", flight, tostring(nativeCooldownOrErr or "rejected"))
        self:RebuildDisplayRows("cargo_request_failed")
        return self:ArmCargoPump(math.max(1000, self:GetNativeCooldownRemaining() + 50))
    end
    self:RecordNativeAccepted(nativeCooldownOrErr, flight)
    local timeoutOk = self:ArmRequestTimeout(serial, tonumber(self.responseSlaMs) or 6500)
    if timeoutOk ~= true then
        self.inFlight = nil
        cargo.results[destination] = { destinationZone = destination, error = "货率超时保护任务创建失败", updatedAt = S.NowMs and tonumber(S.NowMs()) or 0 }
        cargo.queueIndex = (tonumber(cargo.queueIndex) or 1) + 1
        self:RebuildDisplayRows("cargo_timeout_guard_failed")
        return false, "货率超时保护任务创建失败"
    end
    return true
end

function TA:ArmRequestTimeout(serial, delayMs)
    if S.Scheduler == nil or type(S.Scheduler.AddOneShot) ~= "function" then return true end
    self:CancelRequestTimeout()
    local delay = math.max(1000, tonumber(delayMs) or tonumber(self.responseSlaMs) or 6500)
    self.lastResponseTimeoutMs = delay
    return S.Scheduler:AddOneShot(self.requestTimeoutTask, delay, function()
        local flight = TA.inFlight
        if type(flight) ~= "table" or tonumber(flight.serial) ~= tonumber(serial) then return true end
        TA.inFlight = nil
        TA.diag = type(TA.diag) == "table" and TA.diag or {}
        TA.diag.responseTimeouts = (tonumber(TA.diag.responseTimeouts) or 0) + 1
        TA:TraceRequest("response_timeout", flight, "age=" .. tostring(delay))

        if tostring(flight.kind or "route") == "cargo" then
            local cargo = TA.cargo
            if tonumber(cargo.generation) == tonumber(flight.cargoGeneration) and Number(cargo.itemType) == Number(flight.itemType) then
                cargo.error = "目的地查询超时，等待迟到回调保护"
                TA:RebuildDisplayRows("cargo_request_timeout_waiting_drain")
            end
            return TA:ArmTimeoutDrain(flight)
        end

        local currentFrom, currentTo = Number(Trade.State.fromZone), Number(Trade.State.toZone)
        local pending = type(TA.pendingRoute) == "table" and TA.pendingRoute or nil
        if type(pending) == "table" and currentFrom == Number(pending.from) and currentTo == Number(pending.to) then
            TA.pendingRoute = pending
            TA.pendingRetryCount = 0
            TA.status, TA.error = TA:HasRawRowsForRoute(currentFrom, currentTo) and "refreshing" or "loading", nil
            TA.revision = TA.revision + 1
            PublishFeatureUpdate(Trade, TA.revision, "route_request_waiting_timeout_drain")
            return TA:ArmTimeoutDrain(flight)
        end

        -- If the selection changed while the timed-out request was in flight, keep the latest user route even when
        -- pendingRoute was lost/replaced by another maintenance action. It will start after the drain window.
        if currentFrom ~= nil and currentTo ~= nil and (currentFrom ~= Number(flight.from) or currentTo ~= Number(flight.to)) then
            TA.pendingRoute = { from = currentFrom, to = currentTo, reason = "route_change", force = true }
            TA.pendingRetryCount = 0
            TA.status, TA.error = TA:HasRawRowsForRoute(currentFrom, currentTo) and "refreshing" or "loading", nil
            TA.revision = TA.revision + 1
            PublishFeatureUpdate(Trade, TA.revision, "route_request_latest_after_timeout")
            return TA:ArmTimeoutDrain(flight)
        end

        local retryCount = tonumber(flight.retryCount) or 0
        if currentFrom == Number(flight.from) and currentTo == Number(flight.to) and retryCount < 1 then
            TA.pendingRetryCount = retryCount + 1
            TA.pendingRoute = { from = currentFrom, to = currentTo, reason = "timeout_retry", force = true }
            TA.status, TA.error = TA:HasRawRowsForRoute(currentFrom, currentTo) and "refreshing" or "loading", nil
            TA.revision = TA.revision + 1
            PublishFeatureUpdate(Trade, TA.revision, "route_request_waiting_timeout_drain")
            return TA:ArmTimeoutDrain(flight)
        end

        TA.pendingRetryCount = nil
        if TA:HasRawRowsForRoute(currentFrom, currentTo) then
            TA.status, TA.error = "ready", "本次货率刷新超时，继续显示上一份数据"
            TA:ScheduleNextAutoRefresh()
        else
            TA.status, TA.error = "error", "服务器货率查询超时，请点刷新重试"
        end
        TA.revision = TA.revision + 1
        PublishFeatureUpdate(Trade, TA.revision, "route_request_timeout")
        return TA:ArmTimeoutDrain(flight)
    end, Trade, "P2", 1)
end

function TA:Request(force, reason)
    reason = tostring(reason or (force == true and "manual_refresh" or "initial"))
    local from, to = Number(Trade.State.fromZone), Number(Trade.State.toZone)
    if from == nil or to == nil then
        self.status, self.rawRows, self.rows = "idle", {}, {}
        return false, "请先选择完整路线"
    end

    local timeoutDrainRemaining = self:GetTimeoutDrainRemaining()
    -- timedOutFlight is the quarantine ownership token. Do not rely on remaining>0: a scheduler backlog can make
    -- the deadline pass before the drain task executes, and reopening the lane in that gap would reintroduce
    -- late-callback misattribution. The drain callback clears timedOutFlight before resuming the latest request.
    if self.inFlight == nil and type(self.timedOutFlight) == "table" then
        self.pendingRoute = { from = from, to = to, reason = reason, force = force == true }
        if not self:HasRawRowsForRoute(from, to) and Trade:GetViewMode() ~= "cargo" then self:RestoreRouteCache(from, to, "route_cache_timeout_drain") end
        self.status, self.error = self:HasRawRowsForRoute(from, to) and "refreshing" or "loading", nil
        self.revision = self.revision + 1
        PublishFeatureUpdate(Trade, self.revision, "route_request_deferred_timeout_drain")
        self:TraceRequest("timeout_drain_deferred", self.pendingRoute, "remaining=" .. tostring(math.floor(timeoutDrainRemaining)))
        return true
    end

    if self.inFlight ~= nil then
        local same = tostring(self.inFlight.kind or "route") == "route" and Number(self.inFlight.from) == from and Number(self.inFlight.to) == to
        if same and force ~= true then return false, "路线查询仍在进行" end
        if same and force == true then
            self.status, self.error = self:HasRawRowsForRoute(from, to) and "refreshing" or "loading", nil
            self.revision = self.revision + 1
            PublishFeatureUpdate(Trade, self.revision, "route_request_still_inflight")
            return true
        end
        -- 维护（trade-singleflight-latest-2）：无 native request-id 时绝不并发；任何用户路线都只保留最后一次选择。
        -- cargo 扫描属于低优先级后台消费者，当前 Native 回调结束后必须先让 pendingRoute 取得通道。
        self.pendingRoute = { from = from, to = to, reason = reason, force = force == true }
        if Trade:GetViewMode() ~= "cargo" and not self:HasRawRowsForRoute(from, to) then
            if self:RestoreRouteCache(from, to, "route_cache_queued_latest") ~= true then self.rawRows, self.rows, self.selectedKey = {}, {}, nil end
        end
        self.status, self.error = self:HasRawRowsForRoute(from, to) and "refreshing" or "loading", nil
        self.revision = self.revision + 1
        PublishFeatureUpdate(Trade, self.revision, "route_request_queued_latest")
        self:TraceRequest("queued_latest", { kind = "route", from = from, to = to, reason = reason }, "active=" .. tostring(self.inFlight.kind or "route"))
        return true
    end

    local cooldownRemaining = self:GetNativeCooldownRemaining()
    -- 维护（2026-09-23，trade-native-cooldown-4）：实机确认路线切换在 Native 冷却窗口内“先调用再说”并不会
    -- 更快得到新路线；调用可能只返回剩余时间而不产生对应回调，随后反而要等响应超时/迟到回调隔离，形成
    -- “第一次失败，再等很久”的体验。回调又没有 request-id，因此不能并发第二条路线。正确做法是：路线选择
    -- 立即生效，若有会话缓存就先显示缓存；Native 查询统一在 nextNativeRequestAt 到期后单通道执行。
    if cooldownRemaining > 0 then
        self.pendingRoute = { from = from, to = to, reason = reason, force = force == true }
        if not self:HasRawRowsForRoute(from, to) and Trade:GetViewMode() ~= "cargo" then
            if self:RestoreRouteCache(from, to, "route_cache_before_cooldown") ~= true then self.rawRows, self.rows, self.selectedKey = {}, {}, nil end
        end
        self.status, self.error = self:HasRawRowsForRoute(from, to) and "refreshing" or "cooldown", nil
        self.revision = self.revision + 1
        PublishFeatureUpdate(Trade, self.revision, "route_request_deferred_cooldown")
        self:TraceRequest("cooldown_deferred", { kind = "route", from = from, to = to, reason = reason }, "remaining=" .. tostring(math.floor(cooldownRemaining)))
        local deferredOk = self:ArmDeferredRequest(cooldownRemaining + 50, reason)
        if deferredOk ~= true then
            self.status, self.error = "error", "货率冷却重试任务创建失败"
            self.revision = self.revision + 1
            PublishFeatureUpdate(Trade, self.revision, "route_deferred_guard_failed")
            return false, self.error
        end
        return true
    end

    self:CancelDeferredRequest()
    -- 中文维护注释（2026-09-25，trade-auto-refresh-watchdog-1）：请求开始不能再取消自动刷新 watchdog。
    -- Watchdog 自身会在 inFlight/pending/timedOut 时 O(1) 跳过；若这里移除它，就重新回到“必须依赖 callback 重挂”的脆弱链。
    self:CancelTimeoutDrain()
    self.timedOutFlight = nil
    local keepRows = self:HasRawRowsForRoute(from, to)
    if not keepRows then
        self.rawRows, self.rows, self.selectedKey = {}, {}, nil
    end
    self.requestSerial = (tonumber(self.requestSerial) or 0) + 1
    local serial = self.requestSerial
    local retryCount = tonumber(self.pendingRetryCount) or 0
    self.pendingRetryCount = nil
    local flight = {
        kind = "route", from = from, to = to, serial = serial, retryCount = retryCount,
        startedAt = S.NowMs and tonumber(S.NowMs()) or 0, reason = reason,
        cooldownBypassed = false,
    }
    self.inFlight = flight
    self.pendingRoute = nil
    self.status, self.error = keepRows and "refreshing" or "loading", nil
    self.revision = self.revision + 1
    PublishFeatureUpdate(Trade, self.revision, "route_request_" .. reason)
    self:TraceRequest("native_attempt", flight, "local_remaining=" .. tostring(math.floor(cooldownRemaining)))
    local ok, nativeCooldownOrErr = Action("X2Store:GetSpecialtyRatioBetween", StoreApi, "GetSpecialtyRatioBetween", from, to)
    if ok ~= true then
        self.inFlight = nil
        self:CancelRequestTimeout()
        self:TraceRequest("native_rejected", flight, tostring(nativeCooldownOrErr or "rejected"))
        -- 非冷却窗口内的真实 Native 调用失败才落到这里；冷却中的路线变更已在上方直接延迟，
        -- 不再制造一个无回调的“假 inFlight”后再走 6.5 秒超时恢复。
        self.status, self.error = keepRows and "ready" or "error", nativeCooldownOrErr or "服务器未接受路线查询"
        self.revision = self.revision + 1
        PublishFeatureUpdate(Trade, self.revision, "route_request_failed")
        if keepRows then self:ScheduleNextAutoRefresh() end
        return false, self.error
    end
    self:RecordNativeAccepted(nativeCooldownOrErr, flight)
    local timeoutOk = self:ArmRequestTimeout(serial, tonumber(self.responseSlaMs) or 6500)
    if timeoutOk ~= true then
        self.inFlight, self.status, self.error = nil, keepRows and "ready" or "error", "货率超时保护任务创建失败"
        self.revision = self.revision + 1
        PublishFeatureUpdate(Trade, self.revision, "route_timeout_guard_failed")
        return false, self.error
    end
    return true
end

function TA:OnCargoRatio(info, flight)
    local cargo = self.cargo
    if tonumber(cargo.generation) ~= tonumber(flight.cargoGeneration) or Number(cargo.itemType) ~= Number(flight.itemType) then
        self:TraceRequest("cargo_result_stale", flight, "generation/item changed")
    else
        local foundRatio = nil
        if type(info) == "table" then
            for _, value in pairs(info) do
                if type(value) == "table" then
                    local item = type(value.itemInfo) == "table" and value.itemInfo or value
                    local name = item.name or item.itemName or value.name
                    local itemType = Number(item.itemType or item.itemTypeId or item.item_type or item.typeId or value.itemType or value.itemTypeId or value.typeId)
                    local nameMatches = tostring(name or "") == tostring(flight.legacyName or "")
                    if Number(itemType) == Number(flight.itemType) or (itemType == nil and nameMatches) then
                        foundRatio = Number(value.ratio or value.rate or value.percentage)
                        if foundRatio ~= nil then break end
                    end
                end
            end
        end
        local now = S.NowMs and tonumber(S.NowMs()) or 0
        cargo.results[Number(flight.to)] = {
            destinationZone = Number(flight.to), ratio = foundRatio, updatedAt = now,
            error = foundRatio == nil and "当前目的地未返回该贸易品" or nil,
        }
        cargo.queueIndex = (tonumber(cargo.queueIndex) or 1) + 1
        cargo.lastScanAt = now
        cargo.error = nil
        self:MarkEconomicsPayoutInput("cargo_ratio_result")
        self:RebuildDisplayRows("cargo_ratio_result", { includeMaterials = false })
        self:ScheduleDeferredMaterialProjection("cargo_ratio_result", 60)
        self:TraceRequest("cargo_result", flight, foundRatio ~= nil and ("ratio=" .. tostring(foundRatio)) or "missing")
    end
    local pending = self.pendingRoute
    if type(pending) == "table" then return self:Request(true, pending.reason or "route_change") end
    if cargo.scanning ~= true then return true end
    return self:ArmCargoPump(math.max(tonumber(self.cargoMinIntervalMs) or 1000, self:GetNativeCooldownRemaining() + 50))
end

function TA:OnRatio(info)
    local flight = self.inFlight
    local acceptedLate = false
    if type(flight) ~= "table" and type(self.timedOutFlight) == "table" then
        -- During the drain window the only callback that can legally arrive belongs to the timed-out lane, regardless
        -- of whether the user already selected a new route. Route staleness is handled below after the callback is consumed.
        flight = self.timedOutFlight
        acceptedLate = true
    end
    if type(flight) ~= "table" then
        self.diag = type(self.diag) == "table" and self.diag or {}
        self.diag.droppedCallbacks = (tonumber(self.diag.droppedCallbacks) or 0) + 1
        self.diag.lastCallbackAt = S.NowMs and S.NowMs() or 0
        return false
    end

    self.inFlight = nil
    self.timedOutFlight = nil
    self:CancelRequestTimeout()
    if acceptedLate then self:CancelTimeoutDrain(); self:CancelDeferredRequest() end
    self.pendingRetryCount = nil
    self.diag = type(self.diag) == "table" and self.diag or {}
    self.diag.callbackCount = (tonumber(self.diag.callbackCount) or 0) + 1
    if acceptedLate then self.diag.lateCallbacksAccepted = (tonumber(self.diag.lateCallbacksAccepted) or 0) + 1 end
    local callbackAt = S.NowMs and tonumber(S.NowMs()) or 0
    self.diag.lastCallbackAt = callbackAt
    self.diag.lastCallbackLatencyMs = math.max(0, callbackAt - (tonumber(flight.startedAt) or callbackAt))
    self:TraceRequest("callback", flight, "latency=" .. tostring(math.floor(self.diag.lastCallbackLatencyMs)) .. (acceptedLate and " late=1" or ""))

    if tostring(flight.kind or "route") == "cargo" then return self:OnCargoRatio(info, flight) end

    local currentFrom, currentTo = Number(Trade.State.fromZone), Number(Trade.State.toZone)
    local staleForCurrentSelection = currentFrom ~= Number(flight.from) or currentTo ~= Number(flight.to)
    if staleForCurrentSelection then
        local pending = self.pendingRoute
        self.pendingRoute = nil
        -- 页面 Consumer 已释放时，只有独立 auto-refresh Runtime 仍拥有当前路线才允许继续追最新选择。
        -- 关闭 Feature/自动刷新后只结算旧 Native lane，绝不因迟到回调重新启动后台请求。
        local hasRouteRuntime = Trade.enabled == true and ((tonumber(Trade.consumerCount) or 0) > 0 or Trade:ShouldRunAutoRefreshBackground() == true)
        if hasRouteRuntime ~= true then
            self.status, self.error = "idle", nil
            self:TraceRequest("stale_callback_consumed_no_runtime", flight, "selected=" .. tostring(currentFrom) .. "->" .. tostring(currentTo))
            self.revision = self.revision + 1
            PublishFeatureUpdate(Trade, self.revision, "route_result_stale_no_runtime")
            Trade:MaybeReleaseNativeRatioSubscription("stale_callback_no_runtime")
            return true
        end
        if currentFrom ~= nil and currentTo ~= nil then
            if Trade:GetViewMode() ~= "cargo" then self.rawRows, self.rows, self.selectedKey = {}, {}, nil end
            self.status, self.error = "loading", nil
            self.revision = self.revision + 1
            PublishFeatureUpdate(Trade, self.revision, "route_result_superseded")
            -- 维护（trade-route-switch-priority-2）：旧路线回调释放 SingleFlight 后立即追最新用户选择；
            -- 若 Native 冷却尚未结束，Request 会直接按剩余时间延迟，不再先制造一次无回调的抢跑请求。
            return self:Request(true, type(pending) == "table" and pending.reason or "route_change")
        end
        if Trade:GetViewMode() ~= "cargo" then self.rawRows, self.rows, self.selectedKey = {}, {}, nil end
        self.status, self.error = "idle", "请先选择完整路线"
        self.revision = self.revision + 1
        PublishFeatureUpdate(Trade, self.revision, "route_result_superseded_idle")
        return true
    end

    self.pendingRoute = nil
    if type(info) ~= "table" then
        if self:HasRawRowsForRoute(flight.from, flight.to) then
            self.status, self.error = "ready", "货率返回为空，继续显示上一份数据"
            self:ScheduleNextAutoRefresh()
        else
            self.status, self.error = "error", "货率返回为空"
        end
        self.revision = self.revision + 1
        PublishFeatureUpdate(Trade, self.revision, "ratio_result_invalid")
        Trade:MaybeReleaseNativeRatioSubscription("ratio_result_invalid")
        return false
    end

    local rows = {}
    local now = callbackAt
    local payloadTopLevelCount = 0
    for _ in pairs(info) do payloadTopLevelCount = payloadTopLevelCount + 1 end
    for _, value in pairs(info) do
        if type(value) == "table" then
            local item = type(value.itemInfo) == "table" and value.itemInfo or value
            local name = item.name or item.itemName or value.name
            local ratio = Number(value.ratio or value.rate or value.percentage)
            if name ~= nil and ratio ~= nil then
                local payout = S.Services and S.Services.TradePayoutV3 or nil
                local sourceName = Text(name)
                local displayName = type(payout) == "table" and type(payout.ResolveDisplayName) == "function" and payout:ResolveDisplayName(name) or sourceName
                local rowItemType = Number(item.itemType or item.itemTypeId or item.item_type or item.typeId or value.itemType or value.itemTypeId or value.typeId)
                if rowItemType == nil then
                    local products = S.GameIds and S.GameIds.TradeProduct or nil
                    local known = type(products) == "table" and type(products.GetByLegacyName) == "function" and products:GetByLegacyName(sourceName) or nil
                    rowItemType = type(known) == "table" and Number(known.itemId) or nil
                end
                rows[#rows + 1] = {
                    key = tostring(flight.from) .. ":" .. tostring(flight.to) .. ":" .. sourceName,
                    name = displayName, sourceName = sourceName, currentRatio = ratio, ratio = ratio,
                    originZone = flight.from, destinationZone = flight.to, itemType = rowItemType, ratioUpdatedAt = now,
                }
            end
        end
    end
    self:MarkEconomicsPayoutInput("ratio_result")
    self.rawRows = rows
    self.lastCompletedRoute = { from = Number(flight.from), to = Number(flight.to) }
    self.lastRatioAt = now
    if #rows > 0 then self:StoreRouteCache(flight.from, flight.to, rows, now) end
    self.status, self.error = (#rows > 0 and "ready" or "error"), (#rows > 0 and nil or "服务器返回的货率列表为空")
    -- 维护（trade-ratio-fast-publish-1）：先提交服务器货率事实，再异步补材料/毛利。Native 回调不再同步穿过
    -- MaterialPriceService/PriceQuoteQueue；诊断同时记录 payload/解析行数/首批货率样本，下一次无需再猜服务器到底返回了什么。
    self:RebuildDisplayRows("ratio_result", { includeMaterials = false })
    self.diag.lastRatioPayloadTopLevelCount = payloadTopLevelCount
    self.diag.lastRatioParsedRows = #rows
    self.diag.lastRatioSample = {}
    for index = 1, math.min(8, #rows) do
        self.diag.lastRatioSample[#self.diag.lastRatioSample + 1] = { name = tostring(rows[index].sourceName or rows[index].name or "?"), ratio = Number(rows[index].currentRatio or rows[index].ratio) }
    end
    local publishedAt = S.NowMs and tonumber(S.NowMs()) or callbackAt
    self.diag.lastRatioPublishDelayMs = math.max(0, publishedAt - callbackAt)
    if #rows > 0 then self:ScheduleDeferredMaterialProjection("ratio_result", 60) end
    TraceInit("ratio_result", "rows=" .. tostring(#rows) .. " from=" .. tostring(flight.from) .. "->" .. tostring(flight.to) .. " reason=" .. tostring(flight.reason or ""))
    if #rows > 0 then self:ScheduleNextAutoRefresh() end
    if Trade:GetViewMode() == "cargo" and self.cargo.scanning == true then self:ArmCargoPump(math.max(50, self:GetNativeCooldownRemaining() + 50)) end
    Trade:MaybeReleaseNativeRatioSubscription("route_callback_complete")
    return #rows > 0
end

function TA:DescribeRequestState()
    local flight = type(self.inFlight) == "table" and self.inFlight or nil
    local pending = type(self.pendingRoute) == "table" and self.pendingRoute or nil
    local now = S.NowMs and tonumber(S.NowMs()) or 0
    local trace = {}
    for _, row in ipairs(type(self.requestTrace) == "table" and self.requestTrace or {}) do trace[#trace + 1] = Copy(row) end
    return {
        selectedRoute = tostring(Number(Trade.State.fromZone) or "-") .. "->" .. tostring(Number(Trade.State.toZone) or "-"),
        activeKind = flight ~= nil and tostring(flight.kind or "route") or "none",
        activeRoute = flight ~= nil and (tostring(flight.from) .. "->" .. tostring(flight.to)) or "none",
        activeReason = flight ~= nil and tostring(flight.reason or "") or "",
        requestAge = flight ~= nil and math.max(0, math.floor(now - (tonumber(flight.startedAt) or now))) or 0,
        pendingRoute = pending ~= nil and (tostring(pending.from) .. "->" .. tostring(pending.to)) or "none",
        pendingReason = pending ~= nil and tostring(pending.reason or "") or "",
        droppedCallbacks = type(self.diag) == "table" and tonumber(self.diag.droppedCallbacks) or 0,
        callbackCount = type(self.diag) == "table" and tonumber(self.diag.callbackCount) or 0,
        nativeRequests = type(self.diag) == "table" and tonumber(self.diag.nativeRequests) or 0,
        deferredRequests = type(self.diag) == "table" and tonumber(self.diag.deferredRequests) or 0,
        consumerCount = tonumber(Trade.consumerCount) or 0, nativeCallbackSubscribed = Trade.nativeRatioSubscribed == true,
        consumerReleaseFlightsPreserved = type(self.diag) == "table" and tonumber(self.diag.consumerReleaseFlightsPreserved) or 0,
        autoRefreshTargetMs = math.max(1000, tonumber(self.autoRefreshTargetMs) or 10000),
        autoRefreshCooldownFactor = math.max(1, tonumber(self.autoRefreshCooldownFactor) or 2),
        autoRefresh = self:GetAutoRefreshState(),
        autoRefreshDiagnostics = Copy(self.autoRefreshDiagnostics),
        materialProjectionSchedule = Copy(self.materialProjectionDiagnostics),
        lastCallbackAt = type(self.diag) == "table" and tonumber(self.diag.lastCallbackAt) or 0,
        lastCallbackLatencyMs = type(self.diag) == "table" and tonumber(self.diag.lastCallbackLatencyMs) or 0,
        lastRatioPublishDelayMs = type(self.diag) == "table" and tonumber(self.diag.lastRatioPublishDelayMs) or 0,
        lastRatioPayloadTopLevelCount = type(self.diag) == "table" and tonumber(self.diag.lastRatioPayloadTopLevelCount) or 0,
        lastRatioParsedRows = type(self.diag) == "table" and tonumber(self.diag.lastRatioParsedRows) or 0,
        lastRatioSample = type(self.diag) == "table" and Copy(self.diag.lastRatioSample or {}) or {},
        lastRequestReason = type(self.diag) == "table" and tostring(self.diag.lastRequestReason or "") or "",
        nativeCooldownMs = tonumber(self.lastNativeCooldownMs) or 0,
        cooldownRemainingMs = self:GetNativeCooldownRemaining(),
        cooldownBypassAttempts = type(self.diag) == "table" and tonumber(self.diag.cooldownBypassAttempts) or 0,
        cooldownBypassAccepted = type(self.diag) == "table" and tonumber(self.diag.cooldownBypassAccepted) or 0,
        cooldownBypassFallbacks = type(self.diag) == "table" and tonumber(self.diag.cooldownBypassFallbacks) or 0,
        responseTimeoutMs = tonumber(self.lastResponseTimeoutMs) or 0,
        responseSlaMs = tonumber(self.responseSlaMs) or 6500,
        responseTimeouts = type(self.diag) == "table" and tonumber(self.diag.responseTimeouts) or 0,
        lateCallbacksAccepted = type(self.diag) == "table" and tonumber(self.diag.lateCallbacksAccepted) or 0,
        timeoutDrainMs = tonumber(self.timeoutDrainMs) or 0, timeoutDrainRemainingMs = self:GetTimeoutDrainRemaining(),
        timedOutRoute = type(self.timedOutFlight) == "table" and (tostring(self.timedOutFlight.from) .. "->" .. tostring(self.timedOutFlight.to)) or "none",
        status = tostring(self.status or "idle"),
        rawRows = #(self.rawRows or {}), displayRows = #(self.rows or {}), lastRatioAt = tonumber(self.lastRatioAt) or 0,
        viewMode = Trade:GetViewMode(), requestTrace = trace,
        cargo = {
            status = tostring(self.cargo and self.cargo.status or "empty"), itemType = self.cargo and Number(self.cargo.itemType) or nil,
            originZone = self.cargo and Number(self.cargo.originZone) or nil, scanning = self.cargo and self.cargo.scanning == true or false,
            queueIndex = self.cargo and tonumber(self.cargo.queueIndex) or 0, queueCount = self.cargo and #(self.cargo.queue or {}) or 0,
            lastScanAt = self.cargo and tonumber(self.cargo.lastScanAt) or 0, error = self.cargo and self.cargo.error or nil,
            slot = self.cargo and Number(self.cargo.slot) or nil, slotSource = self.cargo and self.cargo.slotSource or nil,
            identityReadSource = self.cargo and self.cargo.identityReadSource or nil, rawItemType = self.cargo and Number(self.cargo.rawItemType) or nil,
            tooltipName = self.cargo and self.cargo.tooltipName or nil, legacyEstBackpack = self.cargo and Number(self.cargo.legacyEstBackpack) or nil,
        },
    }
end

function TA:GetProjection()
    local mode = Trade:GetViewMode()
    local now = S.NowMs and tonumber(S.NowMs()) or 0
    local dataAt = tonumber(self.lastRatioAt) or 0
    local displayStatus, displayError = self.status, self.error
    local cargoProjection = Copy(self.cargo)
    cargoProjection.results = nil
    cargoProjection.queue = nil
    cargoProjection.resultCount = 0
    for _ in pairs(type(self.cargo.results) == "table" and self.cargo.results or {}) do cargoProjection.resultCount = cargoProjection.resultCount + 1 end
    cargoProjection.queueCount = #(self.cargo.queue or {})
    cargoProjection.queueIndex = tonumber(self.cargo.queueIndex) or 0
    cargoProjection.completedCount = math.max(0, math.min(cargoProjection.queueCount, cargoProjection.queueIndex - 1))
    if mode == "cargo" then
        dataAt = tonumber(self.cargo.lastScanAt) or 0
        local cargoStatus = tostring(self.cargo.status or "empty")
        if cargoStatus == "scanning" then displayStatus, displayError = "refreshing", self.cargo.error
        elseif cargoStatus == "complete" or cargoStatus == "ready" then displayStatus, displayError = (#(self.rows or {}) > 0 and "ready" or "empty"), self.cargo.error
        elseif cargoStatus == "unavailable" or cargoStatus == "unknown_origin" then displayStatus, displayError = "unavailable", self.cargo.error
        else displayStatus, displayError = "empty", self.cargo.error end
    end
    local ratioAgeMs = dataAt > 0 and math.max(0, now - dataAt) or nil
    local trackedCount = #(Trade.Preferences.trackedProducts or {})
    -- 维护（2026-09-23，trade-commerce-projection-authority-1）：Presentation 不得复制经商倍率公式。
    -- 售价与状态栏必须共享 TradePayoutV3 Authority，否则服务公式/校准一旦变化，列表售价与“熟练度×倍率”会分叉。
    -- 这里只投影已计算倍率；换装仍由 UNIT_EQUIPMENT_CHANGED -> RefreshCommerceSkill -> RebuildDisplayRows 驱动。
    local payoutService = S.Services and S.Services.TradePayoutV3 or nil
    local commerceMultiplier = nil
    if type(payoutService) == "table" and type(payoutService.GetCommerceMultiplier) == "function" then
        commerceMultiplier = payoutService:GetCommerceMultiplier(self.commerceSkill, Trade.State.commerceMode ~= "off")
    end
    return {
        revision = self.revision, zones = Copy(self.zones), sellableZones = Copy(self.sellableZones), rows = Copy(self.rows),
        status = displayStatus, routeStatus = self.status, error = displayError, fromZone = Trade.State.fromZone, toZone = Trade.State.toZone,
        zoneFallback = self.zoneFallback == true, sellableFallback = self.sellableFallback == true, sellableError = self.sellableError,
        pendingQuoteCount = PendingTradeQuoteCount(self.rows), quoteInFlightCount = InFlightTradeQuoteCount(self.rows),
        nativeCooldownMs = tonumber(self.lastNativeCooldownMs) or 0, cooldownRemainingMs = self:GetNativeCooldownRemaining(),
        responseTimeoutMs = tonumber(self.lastResponseTimeoutMs) or 0, unresolvedIdentityCount = UnresolvedTradeIdentityCount(self.rows),
        favorites = Trade:GetFavorites(), favoriteItems = Trade:GetFavoriteItems(), currentFavoriteKey = Trade:FavoriteKey(Trade.State.fromZone, Trade.State.toZone),
        currentRouteFavorite = Trade:IsFavorite(Trade.State.fromZone, Trade.State.toZone), selectedKey = self.selectedKey, sortMode = Trade.State.sortMode,
        ratioMode = Trade.State.ratioMode, fullRatio = TRADE_FULL_RATIO, commerceMode = Trade.State.commerceMode, commerceSkill = self.commerceSkill,
        commerceStatus = self.commerceStatus, commerceName = self.commerceName, commerceError = self.commerceError, commerceMultiplier = commerceMultiplier,
        priceIncludesCommerce = Trade.State.commerceMode ~= "off" and self.commerceStatus == "ready",
        commercePriceFormulaStatus = "supplied_working_v1", packPriceMultiplierStatus = "supplied_working_v1",
        viewMode = mode, trackedCount = trackedCount, autoRefresh = Trade.Preferences.autoRefresh == true, cargoScan = Trade.Preferences.cargoScan == true,
        autoRefreshState = self:GetAutoRefreshState(),
        rawRowCount = #(self.rawRows or {}), displayRowCount = #(self.rows or {}), lastRatioAt = tonumber(self.lastRatioAt) or 0,
        ratioAgeMs = ratioAgeMs, isRefreshing = displayStatus == "refreshing" or displayStatus == "loading" or displayStatus == "cooldown",
        cargo = cargoProjection,
        payoutCalculator = type(payoutService) == "table" and payoutService:Describe() or nil,
        materialPriceCache = (function() local service=S.Services and S.Services.MaterialPriceServiceV3 or nil; return type(service)=="table" and type(service.Describe)=="function" and service:Describe() or nil end)(),
        economics = Copy(self.economics),
        materialRevalidate = Copy(self.materialRevalidateDiagnostics),
    }
end

local function NormalizeTradeState(value)
    value = type(value) == "table" and value or {}
    local favorites = {}
    for _, raw in ipairs(type(value.favorites) == "table" and value.favorites or {}) do
        if #favorites >= 64 then break end
        if type(raw) == "table" then favorites[#favorites + 1] = Copy(raw) end
    end
    return {
        fromZone = Number(value.fromZone), toZone = Number(value.toZone),
        favorites = favorites,
        sortMode = TRADE_SORT_MODES[value.sortMode] and value.sortMode or "ratio",
        ratioMode = TRADE_RATIO_MODES[value.ratioMode] and value.ratioMode or "current",
        commerceMode = TRADE_COMMERCE_MODES[value.commerceMode] and value.commerceMode or "observe",
        widgetVisible = value.widgetVisible == true,
        widgetWindow = type(value.widgetWindow) == "table" and Copy(value.widgetWindow) or nil,
    }
end
local function NormalizeTradePreferences(value)
    value = type(value) == "table" and value or {}
    return {
        viewMode = TRADE_VIEW_MODES[value.viewMode] and value.viewMode or "all",
        trackedProducts = Trade:NormalizeTrackedProducts(value.trackedProducts),
        autoRefresh = value.autoRefresh ~= false,
        cargoScan = value.cargoScan ~= false,
    }
end

-- 中文维护注释（2026-09-12 实档）：只还原 widgetWindow.normalizedCenterX 的旧 six-significant
-- token 0.0903896 就把整张跑商 canonical 从 48B0E072 精确还原为存档自带的 6BE9E557。
-- 该样本可由“固定6位小数 + binary32 回读”逐字段复现，但我们没有客户端 serializer 源码。
-- 不硬编码上述 Hash/坐标：只允许旧 schema1/Framework3/Transport2 的两个既有中心比例字段，
-- 每次只改变一个叶子，枚举与同一固定6位小数表示相容的有限6位有效数字 token（总计<=32）。
-- Authority：Trade 选择可恢复字段，Core 再验完整旧指纹/metadata/预算并 Apply；不改路线、收藏、
-- 开关/宽高，不清档。唯一整表命中才返回；零/极小值、跨数量级、多字段变化和不匹配继续保护。
-- 这只能恢复旧指纹所表达的有效数字，无法声称找回已经丢失的全部17位原值。新写由 Transport3 防损。
-- 此桥只在加载失败冷路径执行；不要扩成任意字段搜索，也不要扩大枚举预算以“凑 Hash”。
local function RebuildTradeWindowDecimalCanonical(decoded, stampedFingerprint, canonical, raw)
    -- 维护：三个Store使用同一32候选算法，防止复制出三套不同安全边界；既有实档回归不变。
    local st = P:GetStore(Trade.storeId)
    if type(st) ~= "table" or type(P.RebuildFixed6WindowCanonical) ~= "function" then return nil end
    local candidate, domain = P:RebuildFixed6WindowCanonical(st, decoded, stampedFingerprint, canonical, raw, 1, nil)
    local proof = st.lastWindowNumericEvidence
    if type(proof) == "table" then
        st.lastHistoricalRecoveryProbe = "trade_fixed6/tries=" .. tostring(proof.attempts)
            .. "/matches=" .. tostring(proof.matches) .. (proof.field and ("/field=" .. proof.field) or "")
    end
    return candidate, domain
end

RegisterStore(Trade.storeId, "v3.life.trade", function() return NormalizeTradeState(nil) end,
    function() return Copy(Trade.State) end,
    function(value)
        value = type(value) == "table" and value or {}
        Trade.State.fromZone, Trade.State.toZone = Number(value.fromZone), Number(value.toZone)
        Trade.State.favorites = Trade:NormalizeFavorites(value.favorites)
        Trade.State.sortMode = TRADE_SORT_MODES[value.sortMode] and value.sortMode or "ratio"
        Trade.State.ratioMode = TRADE_RATIO_MODES[value.ratioMode] and value.ratioMode or "current"
        Trade.State.commerceMode = TRADE_COMMERCE_MODES[value.commerceMode] and value.commerceMode or "observe"
        Trade.State.widgetVisible = value.widgetVisible == true
        Trade.State.widgetWindow = type(value.widgetWindow) == "table" and Copy(value.widgetWindow) or nil
    end, NormalizeTradeState, nil, RebuildTradeWindowDecimalCanonical) -- 维护：schema1 不变，先精确验旧章才应用恢复。

-- 维护（2026-09-23，trade-preferences-store-1）：新显示/刷新策略使用独立 Store，避免改变历史
-- v3.life.trade 的 schema1 canonical。trackedProducts 只保存 itemType，禁止保存本地化货物名。
RegisterStore(Trade.preferenceStoreId, "v3.life.trade.preferences", function() return NormalizeTradePreferences(nil) end,
    function() return Copy(Trade.Preferences) end,
    function(value)
        Trade.Preferences = NormalizeTradePreferences(value)
        Trade:RefreshTrackedProductSet()
    end, NormalizeTradePreferences, { maxDepth = 4, maxNodes = 192, maxStringBytes = 1024, maxEntriesPerTable = 144 })

Trade.ApiDependencies = {
    -- 维护（2026-09-28，trade-native-dependency-ownership-1）：Trade 的材料身份与材料报价不能借用
    -- tools_craft/tools_auction 是否恰好启用来获得 X2Craft/X2Auction namespace。FeatureRuntime 以实现层
    -- ApiDependencies 为导入 Authority，所以这里必须声明 Trade 实际调用链的完整 Native 依赖。只导入 namespace，
    -- 不新增轮询/事件；QuoteQueue 仍是拍卖服务器查询的唯一串行 Authority。
    "X2Store:GetProductionZoneGroups", "X2Store:GetSellableZoneGroups", "X2Store:GetSpecialtyRatioBetween",
    "X2Ability:GetAllMyActabilityInfos",
    "X2Equipment:GetEquippedItemType", "X2Equipment:GetEquippedItemTooltipInfo",
    "X2Craft:GetCraftTypeByItemType", "X2Craft:GetCraftMaterialInfo", "X2Craft:GetCraftProductInfo",
    "X2Auction:AskMarketPrice", "X2Auction:GetLowestPrice", "X2Auction:SearchAuctionArticle",
    "X2Auction:GetSearchedItemCount", "X2Auction:GetSearchedItemInfo",
}
function Trade:Initialize()
    if type(S.Services and S.Services.TradePayoutV3) ~= "table" then return false, "跑商售价计算服务不可用" end
    local ok, err = LoadStore(self)
    if ok ~= true then return false, err end
    if self.preferenceStoreLoaded ~= true then
        if P:GetStore(self.preferenceStoreId) == nil then return false, "store unavailable: " .. tostring(self.preferenceStoreId) end
        local status, _, preferenceErr = P:LoadStore(self.preferenceStoreId)
        if status ~= true and status ~= "empty" then return false, preferenceErr or tostring(status or "trade preference store load failed") end
        self.preferenceStoreLoaded = true
    end
    self:RefreshTrackedProductSet()
    return true
end
function Trade:EnsureNativeRatioSubscription()
    if self.nativeRatioSubscribed == true then return true end
    if S.Events == nil or type(S.Events.SubscribeOptional) ~= "function" then return false, "事件系统不可用" end
    if type(S.Events.BindOwner) == "function" then S.Events:BindOwner(self.nativeRatioEventOwner, self.Id) end
    local ok = S.Events:SubscribeOptional("SPECIALTY_RATIO_BETWEEN_INFO", self.nativeRatioEventOwner, function(_, info) return TA:OnRatio(info) end)
    if ok ~= true then
        self.nativeRatioSubscribed = false
        return false, "SPECIALTY_RATIO_BETWEEN_INFO 订阅失败"
    end
    self.nativeRatioSubscribed = true
    TA:TraceRequest("native_callback_subscribed", { kind = "lifecycle", reason = "ensure" }, "consumer=" .. tostring(tonumber(self.consumerCount) or 0))
    return true
end

function Trade:ReleaseNativeRatioSubscription(reason)
    if self.nativeRatioSubscribed ~= true then return true end
    if S.Events ~= nil and type(S.Events.UnsubscribeOwner) == "function" then S.Events:UnsubscribeOwner(self.nativeRatioEventOwner) end
    self.nativeRatioSubscribed = false
    TA:TraceRequest("native_callback_unsubscribed", { kind = "lifecycle", reason = tostring(reason or "release") }, "")
    return true
end

function TA:HandleWorldBoundary(reason)
    local _, cargoChanged = self:RefreshCargoObservation(reason or "zone_change")
    if Trade:GetViewMode() == "cargo" then
        if cargoChanged then self:RebuildDisplayRows("cargo_zone_observed") end
        return self:StartCargoScan(reason or "zone_change")
    end
    local from, to = Number(Trade.State.fromZone), Number(Trade.State.toZone)
    if from ~= nil and to ~= nil then return self:Request(true, "zone_change") end
    return true
end


-- 中文维护注释（2026-09-26，trade-auto-refresh-runtime-split-1）：后台跨区刷新不能复用完整页面 HandleWorldBoundary。
-- 后者会读取背包/随身货物并可能启动 cargo 扫描，这些都不属于普通路线后台刷新权限。独立 Runtime 只提高当前路线
-- 货率请求优先级；若 Native lane 正在忙，TA:Request 仍只记录 latest pending，不产生并发。
function TA:HandleAutoRefreshBoundary(reason)
    if type(Trade.ShouldRunAutoRefreshBackground) ~= "function" or Trade:ShouldRunAutoRefreshBackground() ~= true then return true end
    self.autoRefreshDiagnostics = type(self.autoRefreshDiagnostics) == "table" and self.autoRefreshDiagnostics or {}
    local d = self.autoRefreshDiagnostics
    d.worldEvents = (tonumber(d.worldEvents) or 0) + 1
    d.lastWorldEventAt = S.NowMs and tonumber(S.NowMs()) or 0
    d.lastReason = tostring(reason or "zone_change_auto")
    return self:Request(true, reason or "zone_change_auto")
end

function Trade:EnsurePriceQuoteSubscription()
    if self.PriceQuoteSubscribed==true then return true end
    local queue=S.Services and S.Services.PriceQuoteQueueV3 or nil
    if type(queue)~="table" or type(queue.Topic)~="string" or queue.Topic=="" then return false,"报价完成事件不可用" end
    if S.Events==nil or type(S.Events.SubscribeInternal)~="function" then return false,"内部报价事件总线不可用" end
    local ok=S.Events:SubscribeInternal(queue.Topic,self,function(_,itemType,itemGrade,status,reason)
        if Trade.enabled~=true or (tonumber(Trade.consumerCount) or 0)<=0 then return true end
        -- 维护（2026-09-25，trade-multi-row-quote-event-reconcile-1）：先用共享 QuoteQueue 的稳定身份
        -- 收敛所有命中的 RowJob，再刷新可见行 read-model。正常 requester callback 会先完成并把 item.done=true，
        -- 因此这里是幂等 backstop；生命周期边沿若丢失单个 callback，也不会留下永远 active 的货物任务。
        if type(Trade._ReconcileQuoteJobsByIdentity)=="function" then Trade:_ReconcileQuoteJobsByIdentity(itemType,itemGrade,status,reason) end
        return TA:RefreshQuotedItemType(itemType,itemGrade,status,reason)
    end)
    if ok~=true then return false,"报价完成事件订阅失败" end
    self.PriceQuoteSubscribed=true
    return true
end
function Trade:ReleasePriceQuoteSubscription()
    if self.PriceQuoteSubscribed~=true then return true end
    local queue=S.Services and S.Services.PriceQuoteQueueV3 or nil
    if S.Events~=nil and type(S.Events.UnsubscribeInternal)=="function" and type(queue)=="table" and type(queue.Topic)=="string" then
        S.Events:UnsubscribeInternal(queue.Topic,self)
    end
    self.PriceQuoteSubscribed=false
    return true
end

-- 中文维护注释（2026-09-26，trade-auto-refresh-runtime-split-1）：自动货率刷新与页面 Consumer 生命周期严格分离。
-- Authority：Trade.enabled + 已保存 autoRefresh 偏好 + 当前完整路线 + 非 cargo 模式共同决定后台 Runtime 是否存在；
-- Runtime 只持有 watchdog、SPECIALTY_RATIO_BETWEEN_INFO 回执、ENTER_ANOTHER_ZONEGROUP 三种轻量资源。
-- 页面 Demand 归零后必须释放 QuoteQueue 订阅、装备观察、LiveIdentity/询价任务等页面资源，但不能因此停止当前路线货率更新。
-- 反过来，关闭自动刷新/Feature 或进入 cargo 时，后台 Runtime 必须立即静默；若已有 Native flight 被服务器接受，
-- 只保留 callback owner 到该 flight 自然 callback/timeout 结算，禁止强行丢弃无 request-id 的回执。
function Trade:ShouldRunAutoRefreshBackground()
    return self.enabled == true and self.Preferences.autoRefresh == true and self:GetViewMode() ~= "cargo"
        and Number(self.State.fromZone) ~= nil and Number(self.State.toZone) ~= nil
end

function Trade:EnsureAutoRefreshWorldSubscription()
    if self.autoRefreshWorldSubscribed == true then return true end
    if S.Events == nil or type(S.Events.SubscribeOptional) ~= "function" then return false, "事件系统不可用" end
    local owner = self.autoRefreshRuntimeOwner
    if type(S.Events.BindOwner) == "function" then S.Events:BindOwner(owner, self.Id) end
    local ok = S.Events:SubscribeOptional("ENTER_ANOTHER_ZONEGROUP", owner, function()
        if Trade:ShouldRunAutoRefreshBackground() ~= true then return true end
        return TA:HandleAutoRefreshBoundary("zone_change_auto")
    end)
    if ok ~= true then
        self.autoRefreshWorldSubscribed = false
        return false, "ENTER_ANOTHER_ZONEGROUP 自动刷新订阅不可用"
    end
    self.autoRefreshWorldSubscribed = true
    return true
end

function Trade:ReleaseAutoRefreshWorldSubscription()
    if self.autoRefreshWorldSubscribed ~= true then return true end
    if S.Events ~= nil and type(S.Events.UnsubscribeOwner) == "function" then S.Events:UnsubscribeOwner(self.autoRefreshRuntimeOwner) end
    self.autoRefreshWorldSubscribed = false
    return true
end

function Trade:MaybeReleaseNativeRatioSubscription(reason)
    if (tonumber(self.consumerCount) or 0) > 0 then return true end
    if self:ShouldRunAutoRefreshBackground() == true then return true end
    if type(TA.inFlight) == "table" or type(TA.timedOutFlight) == "table" then return true end
    return self:ReleaseNativeRatioSubscription(reason or "trade_runtime_idle")
end

function Trade:StopAutoRefreshRuntime(reason)
    TA:CancelAutoRefresh()
    self:ReleaseAutoRefreshWorldSubscription()
    TA.autoRefreshDiagnostics = type(TA.autoRefreshDiagnostics) == "table" and TA.autoRefreshDiagnostics or {}
    TA.autoRefreshDiagnostics.lastDecision = "stopped"
    TA.autoRefreshDiagnostics.lastReason = tostring(reason or "auto_refresh_stop")
    self:MaybeReleaseNativeRatioSubscription(reason or "auto_refresh_stop")
    return true
end

function Trade:ReconcileAutoRefreshRuntime(reason)
    if self:ShouldRunAutoRefreshBackground() ~= true then
        self:StopAutoRefreshRuntime(reason or "auto_refresh_inactive")
        return true
    end

    local nativeOk, nativeErr = self:EnsureNativeRatioSubscription()
    if nativeOk ~= true then
        self:StopAutoRefreshRuntime("native_callback_unavailable")
        return false, nativeErr or "货率回执事件不可用"
    end

    -- 跨区事件是“到达新区域后尽快刷新”的加速器；若某个 RU 构建不提供该可选事件，1 秒 watchdog 仍会
    -- 在合法年龄窗口自动刷新，因此这里降级而不是把整个功能判失败。
    local worldOk, worldErr = self:EnsureAutoRefreshWorldSubscription()
    TA.autoRefreshDiagnostics = type(TA.autoRefreshDiagnostics) == "table" and TA.autoRefreshDiagnostics or {}
    TA.autoRefreshDiagnostics.worldEventAvailable = worldOk == true
    TA.autoRefreshDiagnostics.worldEventError = worldOk == true and nil or tostring(worldErr or "optional_event_unavailable")

    local scheduled = TA:ScheduleNextAutoRefresh(reason or "auto_refresh_reconcile")
    if scheduled ~= true then return false, "自动刷新 watchdog 创建失败" end
    return true
end

function Trade:ReconcileDemand(_, before, after)
    local beforeCount = tonumber(before and before.count) or 0
    local afterCount = tonumber(after and after.count) or 0
    if beforeCount <= 0 and afterCount > 0 then
        TraceInit("demand_start", "consumer=" .. tostring(afterCount) .. " enabled=" .. tostring(self.enabled == true)
            .. " storeLoaded=" .. tostring(self.storeLoaded == true)
            .. " route=" .. tostring(Number(Trade.State.fromZone) or "-") .. "->" .. tostring(Number(Trade.State.toZone) or "-")
            .. " view=" .. tostring(self:GetViewMode()))
        if S.Events ~= nil then
            S.Events:BindOwner(self, self.Id)
            -- 共享报价结果与当前 batch callback 是两条不同生命周期：先订阅 QuoteQueue 终态，再建立 Native 比率回执。
            local quoteSubscribed, quoteSubscribeErr = self:EnsurePriceQuoteSubscription()
            if quoteSubscribed ~= true then
                TraceInit("quote_event_subscribe_failed", tostring(quoteSubscribeErr or "unknown"))
                return false, quoteSubscribeErr or "报价完成事件订阅失败"
            end
            -- Native 回执使用独立 lease owner；Demand 结束时不能撤销一个已经被服务器接受的请求的回调归属。
            local nativeSubscribed, nativeSubscribeErr = self:EnsureNativeRatioSubscription()
            if nativeSubscribed ~= true then
                self.eventUnavailable = true
                self:ReleasePriceQuoteSubscription()
                TraceInit("event_subscribe_failed", "SPECIALTY_RATIO_BETWEEN_INFO")
                return false, nativeSubscribeErr or "SPECIALTY_RATIO_BETWEEN_INFO 订阅失败"
            end
            -- 维护（2026-09-23，trade-event-refresh-1）：换装/跨区都由事件驱动，禁止 Tick 轮询。
            -- UNIT_EQUIPMENT_CHANGED 可能一次换装连续触发，Authority 内 220ms debounce 后只读取一次熟练度/背包槽；
            -- ENTER_ANOTHER_ZONEGROUP 只提高一次刷新优先级，不绕开 SingleFlight。
            S.Events:SubscribeOptional("UNIT_EQUIPMENT_CHANGED", self, function() return TA:ScheduleEquipmentRefresh("UNIT_EQUIPMENT_CHANGED") end)
            S.Events:SubscribeOptional("ENTER_ANOTHER_ZONEGROUP", self, function()
                -- 自动刷新后台 Runtime 已独立拥有普通路线的跨区加速器；页面侧只在 auto-refresh 关闭或 cargo 模式
                -- 执行完整 WorldBoundary，避免同一个原生事件重复提交两次当前路线请求。
                if Trade:GetViewMode() == "cargo" or Trade:ShouldRunAutoRefreshBackground() ~= true then
                    return TA:HandleWorldBoundary("zone_change")
                end
                return true
            end)
            self.eventUnavailable = false
        end
        local materialPrices = S.Services and S.Services.MaterialPriceServiceV3 or nil
        if type(materialPrices) == "table" and type(materialPrices.EnsureStoreLoaded) == "function" then
            local loaded, loadErr = materialPrices:EnsureStoreLoaded()
            if loaded ~= true then TraceInit("material_price_store_load_failed", tostring(loadErr or "unknown")) end
        end
        self.Authority:SyncEconomicsMaterialRevision("demand_start")
        self.Authority:RefreshCommerceSkill()
        self.Authority:RefreshCargoObservation("demand_start")
        self.Authority:RefreshZones()
        if self:GetViewMode() == "cargo" then
            self:StopAutoRefreshRuntime("demand_start_cargo")
            self.Authority:StartCargoScan("demand_start")
        else
            if Number(Trade.State.fromZone) ~= nil and Number(Trade.State.toZone) ~= nil then
                if #(TA.rawRows or {}) == 0 and TA.inFlight == nil then
                    local requested, requestErr = TA:Request(false, "initial")
                    if requested ~= true then TraceInit("demand_route_query_deferred", tostring(requestErr or "request_not_started")) end
                elseif #(TA.rawRows or {}) > 0 then
                    -- 后台 Runtime 可能在页面关闭期间已经拿到新货率；页面 Consumer 重新出现时只重建一次
                    -- 可见 read-model，让材料 SWR/LiveIdentity 从当前页面 Demand 正式接管，不要求再打一次货率请求。
                    TA:RebuildDisplayRows("demand_start_projection")
                end
            end
            local autoOk, autoErr = self:ReconcileAutoRefreshRuntime("demand_start")
            if autoOk ~= true then TraceInit("auto_refresh_runtime_failed", tostring(autoErr or "unknown")) end
        end
        TraceInit("demand_init_done", "zones=" .. tostring(#(TA.zones or {})) .. "/" .. tostring(#(TA.sellableZones or {}))
            .. " fallback=" .. tostring(TA.zoneFallback == true) .. "/" .. tostring(TA.sellableFallback == true)
            .. " commerce=" .. tostring(TA.commerceStatus or "-") .. " cargo=" .. tostring(TA.cargo.status or "-"))
    elseif beforeCount > 0 and afterCount <= 0 then
        -- 维护（2026-09-26，trade-auto-refresh-runtime-split-1）：页面 Demand 归零必须真实释放页面资源。
        -- 自动货率刷新若仍开启，只保留独立 Runtime owner；不能再借一个伪 Consumer 让 QuoteQueue/装备观察/LiveIdentity
        -- 永久存活。已被服务器接受的无 request-id Native flight 仍保留 callback ownership 到自然结算。
        if S.Events ~= nil then S.Events:UnsubscribeOwner(self) end
        self:ReleasePriceQuoteSubscription()
        TA:CancelEquipmentRefresh()
        TA:CancelDeferredMaterialProjection()
        TA:StopCargoScan("no_consumers")
        TA:CancelLiveIdentities()
        self:CancelQuoteBatch("no_consumers")

        local backgroundActive = self:ShouldRunAutoRefreshBackground() == true
        local preserveNativeFlight = type(TA.inFlight) == "table" or type(TA.timedOutFlight) == "table"
        if backgroundActive then
            -- 当前保存路线仍由后台 Runtime 维护；pending/deferred 可能正是 auto_refresh 或刚切换的新路线，不能清掉。
            local autoOk, autoErr = self:ReconcileAutoRefreshRuntime("ui_consumers_released")
            if autoOk ~= true then TraceInit("auto_refresh_runtime_failed", tostring(autoErr or "unknown")) end
        else
            TA.pendingRoute = nil
            TA.pendingRetryCount = nil
            TA:CancelDeferredRequest()
            TA:CancelAutoRefresh()
        end

        if preserveNativeFlight then
            TA.diag = type(TA.diag) == "table" and TA.diag or {}
            TA.diag.consumerReleaseFlightsPreserved = (tonumber(TA.diag.consumerReleaseFlightsPreserved) or 0) + 1
            TA:TraceRequest("consumer_release_preserve_flight", TA.inFlight or TA.timedOutFlight, backgroundActive and "consumer=0/background=1" or "consumer=0")
        elseif backgroundActive ~= true then
            TA.timedOutFlight = nil
            TA:CancelRequestTimeout()
            TA:CancelTimeoutDrain()
            self:MaybeReleaseNativeRatioSubscription("ui_consumers_released")
        end
    end
    return true
end

function Trade:Enable()
    self.enabled = true
    -- 维护（trade-auto-refresh-runtime-split-1）：Feature 启用后按已保存偏好恢复独立后台 Runtime。
    -- 路线未完整时 Reconcile 只保持静默，不创建伪 Consumer；一旦用户/旧配置提供完整路线，SetTo/收藏切换会重新接通。
    local autoOk, autoErr = self:ReconcileAutoRefreshRuntime("feature_enable")
    if autoOk ~= true then self.enabled = false; self:StopAutoRefreshRuntime("feature_enable_failed"); return false, autoErr or "自动刷新后台 Runtime 启动失败" end
    TraceInit("enable", "feature enabled")
    return true
end

function Trade:Disable(reason)
    local ok, err = self.Demand:Clear(reason or "trade_disable")
    if ok ~= true then return false, err end
    if S.Events then S.Events:UnsubscribeOwner(self) end
    self:ReleasePriceQuoteSubscription()
    self:CancelQuoteBatch(reason or "disabled")
    self.enabled = false
    self:StopAutoRefreshRuntime(reason or "trade_disable")
    self:ReleaseNativeRatioSubscription(reason or "trade_disable")
    TA.inFlight, TA.pendingRoute, TA.pendingRetryCount, TA.timedOutFlight = nil, nil, nil, nil
    TA:CancelRequestTimeout(); TA:CancelTimeoutDrain(); TA:CancelDeferredRequest(); TA:CancelAutoRefresh(); TA:CancelEquipmentRefresh(); TA:CancelDeferredMaterialProjection(); TA:StopCargoScan("feature_disabled"); TA:CancelLiveIdentities()
    TraceInit("disable", tostring(reason or "trade_disable"))
    return true
end

function Trade:AcquireConsumer(token) if not self.enabled then return false, "跑商功能已关闭" end return self.Demand:Acquire(token, {}, "trade_consumer") end
function Trade:ReleaseConsumer(token) return self.Demand:Release(token, "trade_consumer") end

function Trade:Refresh(reason)
    if not self.enabled or self.consumerCount <= 0 then return true end
    local _, commerceChanged = TA:RefreshCommerceSkill()
    local _, cargoChanged = TA:RefreshCargoObservation(reason or "manual_refresh")
    local zonesOk, zonesErr = TA:RefreshZones()
    if zonesOk ~= true then return false, zonesErr end
    if commerceChanged or cargoChanged then TA:RebuildDisplayRows("trade_manual_observation_refresh") end
    if self:GetViewMode() == "cargo" then return TA:StartCargoScan(reason or "manual_refresh") end
    if Number(Trade.State.fromZone) ~= nil and Number(Trade.State.toZone) ~= nil then return TA:Request(true, "manual_refresh") end
    return true
end

function Trade:GetProjection()
    local projection=TA:GetProjection()
    projection.quoteBatch=self:GetQuoteBatch() -- 兼容旧 UI/诊断的聚合只读快照。
    projection.quoteJobs=self:GetQuoteJobs()
    return projection
end
function Trade:GetRouteSettings() return { fromZone = Trade.State.fromZone, toZone = Trade.State.toZone, sortMode = Trade.State.sortMode, ratioMode = Trade.State.ratioMode, commerceMode = Trade.State.commerceMode, viewMode = self:GetViewMode() } end

function Trade:SetViewMode(mode)
    mode = TRADE_VIEW_MODES[mode] and mode or nil
    if mode == nil then return false, "显示模式必须是 all、tracked 或 cargo" end
    if self:GetViewMode() == mode then return true end
    local persisted, persistErr = PersistTradePreference("trade_view_mode", function(state) state.viewMode = mode; return true end)
    if persisted ~= true then return false, persistErr or "显示模式保存失败" end
    self:RefreshTrackedProductSet()
    -- 维护（2026-09-25，trade-view-quote-lifetime-1）：all/tracked/cargo 是 Display Projection 选择，
    -- 不是材料报价 Authority，也不会改变已经双击选中的货物身份。18.307 在这里无条件 CancelQuoteBatch，
    -- 会把刚进入 PriceQuoteQueueV3 的第一项 pending 与后续 queued 材料一起撤销；更严重的是旧 Queue
    -- 对 pending 取消没有收敛 itemType 生命周期，列表随后会永久显示“询价中…”。显示模式切换现在只重建
    -- 当前可见行/随身扫描，显式材料询价继续由原 generation 完成并写入共享报价缓存；真正改变业务身份的
    -- 路线切换、Consumer 归零和 Feature Disable 仍保留 CancelQuoteBatch，因此不会把旧路线结果串到新路线。
    if mode == "cargo" then
        -- 普通路线自动刷新与随身多目的地扫描是两套 Native 调度语义；进入 cargo 时立即释放独立后台 Runtime。
        self:StopAutoRefreshRuntime("trade_view_cargo")
        TA:RebuildDisplayRows("trade_view_cargo")
        if self.enabled and (tonumber(self.consumerCount) or 0) > 0 then return TA:StartCargoScan("view_mode") end
        return true
    end
    TA:StopCargoScan("view_changed")
    local autoOk, autoErr = self:ReconcileAutoRefreshRuntime("trade_view_route")
    if autoOk ~= true then return false, autoErr or "自动刷新后台 Runtime 启动失败" end
    TA:RebuildDisplayRows("trade_view_" .. mode)
    if self.enabled and (tonumber(self.consumerCount) or 0) > 0 and Number(self.State.fromZone) ~= nil and Number(self.State.toZone) ~= nil then
        if not TA:HasRawRowsForRoute(self.State.fromZone, self.State.toZone) then return TA:Request(true, "route_change") end
    end
    return true
end

function Trade:ToggleTrackedProduct(value)
    local itemType = Number(value)
    if itemType == nil then
        local key = tostring(value or "")
        local row = self:GetRow(key)
        if row == nil then
            for _, raw in ipairs(TA.rawRows or {}) do if tostring(raw.key or "") == key then row = raw; break end end
        end
        itemType = row and Number(row.itemType) or nil
    end
    if itemType == nil or itemType <= 0 then return false, "该贸易品缺少已验证 ItemID，暂不能加入关注" end
    itemType = math.floor(itemType)
    local wasTracked = self:IsTrackedProduct(itemType)
    local nextValues = {}
    for _, id in ipairs(self:NormalizeTrackedProducts(self.Preferences.trackedProducts)) do if id ~= itemType then nextValues[#nextValues + 1] = id end end
    if not wasTracked then
        if #nextValues >= 128 then return false, "关注货物最多 128 项" end
        nextValues[#nextValues + 1] = itemType
    end
    table.sort(nextValues)
    local persisted, persistErr = PersistTradePreference("trade_tracked_product", function(state) state.trackedProducts = nextValues; return true end)
    if persisted ~= true then return false, persistErr or "关注货物保存失败" end
    self:RefreshTrackedProductSet()
    TA:RebuildDisplayRows("trade_tracked_product")
    return true, wasTracked and "已取消关注" or "已关注货物"
end

function Trade:SetAutoRefresh(value)
    value = value == true
    local persisted, persistErr = PersistTradePreference("trade_auto_refresh", function(state) state.autoRefresh = value; return true end)
    if persisted ~= true then return false, persistErr or "自动刷新设置保存失败" end
    if value then
        local runtimeOk, runtimeErr = self:ReconcileAutoRefreshRuntime("trade_auto_refresh_enabled")
        if runtimeOk ~= true then
            -- 偏好已经进入事务内存；Native callback/watchdog 若建立失败必须回滚偏好，不能留下“开但不工作”的假状态。
            PersistTradePreference("trade_auto_refresh_rollback", function(state) state.autoRefresh = false; return true end)
            self:StopAutoRefreshRuntime("trade_auto_refresh_rollback")
            return false, runtimeErr or "自动刷新后台 Runtime 启动失败"
        end
    else
        self:StopAutoRefreshRuntime("trade_auto_refresh_disabled")
    end
    TA.revision = TA.revision + 1; PublishFeatureUpdate(self, TA.revision, "trade_auto_refresh")
    return true
end

function Trade:SetCargoScan(value)
    value = value == true
    local persisted, persistErr = PersistTradePreference("trade_cargo_scan", function(state) state.cargoScan = value; return true end)
    if persisted ~= true then return false, persistErr or "随身货物扫描设置保存失败" end
    if value and self:GetViewMode() == "cargo" and self.enabled and (tonumber(self.consumerCount) or 0) > 0 then return TA:StartCargoScan("cargo_scan_enabled") end
    if not value then TA:StopCargoScan("scan_disabled"); TA:RebuildDisplayRows("cargo_scan_disabled") end
    return true
end
function Trade:SetSortMode(mode)
    mode = TRADE_SORT_MODES[mode] and mode or nil
    if mode == nil then return false, "排序模式必须是 ratio、price 或 name" end
    local persisted, persistErr = PersistLifeMutation(self, "trade_sort_mode", function(state) state.sortMode = mode; return true end)
    if persisted ~= true then return false, persistErr or "排序模式保存失败" end
    return TA:RebuildDisplayRows("trade_sort_mode")
end
function Trade:ToggleCurrentFavorite()
    local wanted = self:FavoriteKey(self.State.fromZone, self.State.toZone)
    if wanted == nil then return false, "请先选择完整路线" end
    local nextFavorites, removed = {}, false
    for _, favorite in ipairs(self:NormalizeFavorites(self.State.favorites)) do
        if self:FavoriteKey(favorite.fromZone, favorite.toZone) == wanted then
            removed = true
        else
            nextFavorites[#nextFavorites + 1] = favorite
        end
    end
    if not removed then
        if #nextFavorites >= 12 then return false, "收藏路线最多保存 12 条，请先取消一条旧收藏" end
        nextFavorites[#nextFavorites + 1] = { fromZone = math.floor(Number(self.State.fromZone)), toZone = math.floor(Number(self.State.toZone)) }
    end
    local persisted, persistErr = PersistLifeMutation(self, "trade_favorite_toggle", function(state) state.favorites = self:NormalizeFavorites(nextFavorites); return true end)
    if persisted ~= true then return false, persistErr or "收藏路线保存失败" end
    TA.revision = TA.revision + 1
    PublishFeatureUpdate(self, TA.revision, removed and "trade_favorite_removed" or "trade_favorite_added")
    return true, removed and "已取消收藏" or "已收藏路线"
end
function Trade:SelectFavorite(key)
    key = tostring(key or "")
    local selected
    for _, favorite in ipairs(self:NormalizeFavorites(self.State.favorites)) do
        if self:FavoriteKey(favorite.fromZone, favorite.toZone) == key then selected = favorite; break end
    end
    if selected == nil then return false, "收藏路线不存在" end

    -- 维护（2026-09-23，trade-favorite-route-atomic-1）：收藏路线是一次“from+to”用户意图，不能继续拆成
    -- SetFrom -> SetTo 两次持久化/两次 UI 发布。旧流程会先把 to 清空，再刷新可售地区，再提交第二次请求；
    -- 如果此时正处 Native 冷却或旧请求回调，用户会看到一次中间失败/空表。这里一次事务写入完整路线，
    -- 再刷新 sellable 候选、恢复会话缓存并交给同一 SingleFlight Scheduler；不新增第二 Authority。
    self:CancelQuoteBatch("favorite_route_changed")
    local from, to = Number(selected.fromZone), Number(selected.toZone)
    if from == nil or to == nil then return false, "收藏路线数据不完整" end
    -- 先读取候选并验证，再提交一次完整状态事务；验证失败不能把旧路线改成半成品。
    local sellable, sellableFallback, sellableErr = TA:GetSellableForOrigin(from)
    local targetAvailable = false
    for _, row in ipairs(sellable or {}) do if Number(row.id) == to then targetAvailable = true; break end end
    if targetAvailable ~= true then return false, sellableErr or "收藏路线目的地当前不可用" end

    local persisted, persistErr = PersistLifeMutation(self, "trade_select_favorite", function(state)
        state.fromZone, state.toZone = from, to
        return true
    end)
    if persisted ~= true then return false, persistErr or "收藏路线切换保存失败" end

    TA.sellableZones = Copy(sellable)
    TA.sellableFallback, TA.sellableError = sellableFallback == true, sellableErr
    local autoOk, autoErr = self:ReconcileAutoRefreshRuntime("favorite_route_changed")
    if autoOk ~= true then return false, autoErr or "自动刷新后台 Runtime 启动失败" end
    TA:RestoreRouteCache(from, to, "favorite_route_cache")
    return TA:Request(true, "route_change")
end
function Trade:GetRow(key)
    key = tostring(key or "")
    for _, row in ipairs(TA.rows or {}) do if tostring(row.key or "") == key then return Copy(row) end end
    return nil
end
function Trade:SelectRow(key)
    local row = self:GetRow(key)
    if row == nil then return false, "贸易品已不在当前路线结果中" end
    TA.selectedKey = tostring(row.key)
    return true
end
function Trade:GetSelectedRow() return TA.selectedKey and self:GetRow(TA.selectedKey) or nil end
function Trade:SetRatioMode(mode)
    mode = TRADE_RATIO_MODES[mode] and mode or nil
    if mode == nil then return false, "货率模式必须是 current 或 full" end
    local persisted, persistErr = PersistLifeMutation(self, "trade_ratio_mode", function(state) state.ratioMode = mode; return true end)
    if persisted ~= true then return false, persistErr or "货率模式保存失败" end
    TA:MarkEconomicsPayoutInput("trade_ratio_mode")
    return TA:RebuildDisplayRows("trade_ratio_mode")
end
function Trade:SetCommerceMode(mode)
    mode = TRADE_COMMERCE_MODES[mode] and mode or nil
    if mode == nil then return false, "熟练度模式必须是 observe 或 off" end
    local persisted, persistErr = PersistLifeMutation(self, "trade_commerce_mode", function(state) state.commerceMode = mode; return true end)
    if persisted ~= true then return false, persistErr or "熟练度模式保存失败" end
    TA:RefreshCommerceSkill()
    return TA:RebuildDisplayRows("trade_commerce_mode")
end
function Trade:SetFrom(id)
    -- 维护：路线变更先取消旧批次，旧结果只能进入共享缓存，不能更新新路线。
    self:CancelQuoteBatch("route_changed")
    local nextFrom = Number(id)
    local persisted, persistErr = PersistLifeMutation(self, "trade_from", function(state)
        if Number(state.fromZone) ~= nextFrom then state.toZone = nil end
        state.fromZone = nextFrom
        return true
    end)
    if persisted ~= true then return false, persistErr or "起点保存失败" end
    -- 起点变化会清空目的地；此时后台 Runtime 必须立即静默，避免旧完整路线 watchdog 继续提交请求。
    self:ReconcileAutoRefreshRuntime("trade_from_changed")
    -- Keep the latest desired route alive across a mid-flight origin switch.
    -- The old form cleared pendingRoute AND reset to idle, so the sequence
    -- A->B in flight, SetTo(C), SetFrom(D) left the UI empty with no queued
    -- request: the in-flight callback then found no pending route and nothing
    -- re-armed -- exactly the reported "快速切起点后没有数据" dead corner.
    TA:RefreshSellable()
    local currentTo = Number(Trade.State.toZone)
    if TA.inFlight ~= nil or currentTo ~= nil then
        TA.pendingRoute = currentTo ~= nil and { from = nextFrom, to = currentTo, reason = "route_change", force = true } or nil
        TA.rawRows, TA.rows = {}, {}
        if TA.inFlight ~= nil then
            TA.status, TA.error = "loading", nil
        elseif TA.pendingRoute ~= nil then
            TA.status, TA.error = "loading", nil
            TA:Request(true, "route_change")
        end
    else
        TA.pendingRoute = nil
        TA.rawRows, TA.rows, TA.status, TA.error = {}, {}, "idle", nil
    end
    TA.revision = (tonumber(TA.revision) or 0) + 1
    PublishFeatureUpdate(self, TA.revision, "trade_from")
    return true
end
function Trade:SetTo(id)
    self:CancelQuoteBatch("route_changed")
    for _, row in ipairs(TA.sellableZones or {}) do
        if row.id == Number(id) then
            local persisted, persistErr = PersistLifeMutation(self, "trade_to", function(state) state.toZone = row.id; return true end)
            if persisted ~= true then return false, persistErr end
            local autoOk, autoErr = self:ReconcileAutoRefreshRuntime("trade_to_changed")
            if autoOk ~= true then return false, autoErr or "自动刷新后台 Runtime 启动失败" end
            -- 维护（trade-route-session-cache-1）：已查过的路线先恢复会话快照，让列表立即可见；Native 刷新仍由
            -- SingleFlight/cooldown Scheduler 串行执行。未命中缓存时保持原来的 loading/cooldown 空态提示。
            TA:RestoreRouteCache(Trade.State.fromZone, row.id, "route_cache_manual_select")
            return TA:Request(true, "route_change")
        end
    end
    return false, "目的地不可用"
end
local function CycleTradeList(list, currentId, delta)
    list = type(list) == "table" and list or {}
    if #list == 0 then return nil end
    local currentIndex = 0
    for index, row in ipairs(list) do if tonumber(row.id) == tonumber(currentId) then currentIndex = index break end end
    delta = tonumber(delta) or 1
    local nextIndex = ((currentIndex + delta - 1) % #list) + 1
    return list[nextIndex] and list[nextIndex].id or nil
end
function Trade:CycleFrom(delta)
    local id = CycleTradeList(TA.zones, Trade.State.fromZone, delta)
    if id == nil then return false, "没有可用起点" end
    return self:SetFrom(id)
end
function Trade:CycleTo(delta)
    local id = CycleTradeList(TA.sellableZones, Trade.State.toZone, delta)
    if id == nil then return false, "没有可用目的地" end
    return self:SetTo(id)
end
-- 维护（2026-09-25，trade-multi-row-quote-jobs-1）：用户层“同时询价多个货物”与 Native 层并发必须严格分离。
-- 业务层允许多个 RowJob 同时存在；每个 RowJob 只描述一个货物需要哪些材料、各自进度和取消身份。
-- 真正的拍卖 Native 请求仍全部进入 PriceQuoteQueueV3 单通道，由其 requestKey 去重并把同一材料的完成结果
-- fan-out 给多个 requester。也就是说 8 个货物可以同时处于“询价中”，但服务器侧仍严格一次只处理一个材料；
-- 多个货物共享红薯/鸡蛋等材料时只查询一次。禁止在这里直接调用 X2Auction，也禁止为每个 RowJob 新建 Scheduler lane。
-- 路线/Feature 生命周期变化使用 quoteEpoch 统一失效旧任务；新增另一个 RowJob 不得递增 epoch，否则会把仍合法的并行任务作废。
local QUOTE_REFRESH_TASK="v3_trade_quote_refresh"
local TRADE_MAX_ACTIVE_QUOTE_JOBS=16
local TRADE_BULK_QUOTE_MAX_ROWS=16
local TRADE_QUOTE_DIAG_JOB_LIMIT=12
Trade.QuoteTerminalRefreshContractVersion=2
Trade.MultiRowQuoteJobsContractVersion=1
Trade.quoteEpoch=0
Trade.quoteJobSequence=0
Trade.quoteJobsByRowKey={}
Trade.quoteJobOrder={}
Trade.quoteMaterialKeys={}
Trade.quoteRefreshPending=false
Trade.quoteRefreshDiagnostics={lastRefreshAt=0,lastRefreshReason="idle",lastRefreshChanged=false,refreshMs=0}
-- 兼容旧页面/诊断的聚合只读快照。它不再是任务 Authority；真实任务在 quoteJobsByRowKey。
Trade.quoteBatch={active=false,total=0,completed=0,ready=0,failed=0,mode="basic",scope="multi",activeJobs=0,totalJobs=0}
Trade.lastQuoteJob=nil

local function QuoteJobSummary(job)
    if type(job)~="table" then return nil end
    return {
        id=job.id,rowKey=job.rowKey,label=job.label,requester=job.requester,mode=job.mode,state=job.state,
        active=job.active==true,total=tonumber(job.total) or 0,completed=tonumber(job.completed) or 0,
        pending=math.max(0,(tonumber(job.total) or 0)-(tonumber(job.completed) or 0)),
        ready=tonumber(job.ready) or 0,failed=tonumber(job.failed) or 0,deferred=tonumber(job.deferred) or 0,
        joinedPending=tonumber(job.joinedPending) or 0,createdAt=job.createdAt,completedAt=job.completedAt,
        reason=job.reason,maxItems=job.maxItems,
    }
end

function Trade:_CountActiveQuoteJobs()
    local count=0
    for _,job in pairs(type(self.quoteJobsByRowKey)=="table" and self.quoteJobsByRowKey or {}) do
        if type(job)=="table" and job.active==true then count=count+1 end
    end
    return count
end

function Trade:_RefreshQuoteAggregate(reason)
    local activeJobs,totalJobs,total,completed,ready,failed=0,0,0,0,0,0
    local onlyJob=nil
    for _,rowKey in ipairs(type(self.quoteJobOrder)=="table" and self.quoteJobOrder or {}) do
        local job=self.quoteJobsByRowKey and self.quoteJobsByRowKey[rowKey] or nil
        if type(job)=="table" then
            totalJobs=totalJobs+1
            if job.active==true then
                activeJobs=activeJobs+1;onlyJob=job
                total=total+(tonumber(job.total) or 0);completed=completed+(tonumber(job.completed) or 0)
                ready=ready+(tonumber(job.ready) or 0);failed=failed+(tonumber(job.failed) or 0)
            end
        end
    end
    local refresh=self.quoteRefreshDiagnostics or {}
    local summary={
        active=activeJobs>0,total=total,completed=completed,ready=ready,failed=failed,
        mode="basic",scope=activeJobs>1 and "multi" or (onlyJob and "row" or "multi"),
        activeJobs=activeJobs,totalJobs=totalJobs,
        rowKey=activeJobs==1 and onlyJob and onlyJob.rowKey or nil,
        label=activeJobs==1 and onlyJob and onlyJob.label or (activeJobs>1 and (tostring(activeJobs).."个货物") or nil),
        reason=tostring(reason or "snapshot"),
        lastRefreshAt=refresh.lastRefreshAt,lastRefreshReason=refresh.lastRefreshReason,
        lastRefreshChanged=refresh.lastRefreshChanged,refreshMs=refresh.refreshMs,
    }
    if activeJobs==0 and type(self.lastQuoteJob)=="table" then
        summary.completed=tonumber(self.lastQuoteJob.completed) or 0
        summary.total=tonumber(self.lastQuoteJob.total) or 0
        summary.ready=tonumber(self.lastQuoteJob.ready) or 0
        summary.failed=tonumber(self.lastQuoteJob.failed) or 0
        summary.rowKey=self.lastQuoteJob.rowKey;summary.label=self.lastQuoteJob.label
        summary.scope="row";summary.lastJobState=self.lastQuoteJob.state
    end
    self.quoteBatch=summary
    return summary
end

function Trade:GetQuoteBatch()
    return Copy(self:_RefreshQuoteAggregate("snapshot"))
end

function Trade:GetQuoteJobs()
    local jobs,activeCount,totalCount={},0,0
    local active,history={},{}
    for _,rowKey in ipairs(type(self.quoteJobOrder)=="table" and self.quoteJobOrder or {}) do
        local job=self.quoteJobsByRowKey and self.quoteJobsByRowKey[rowKey] or nil
        if type(job)=="table" then
            totalCount=totalCount+1
            if job.active==true then active[#active+1]=job;activeCount=activeCount+1 else history[#history+1]=job end
        end
    end
    for _,job in ipairs(active) do
        if #jobs>=TRADE_QUOTE_DIAG_JOB_LIMIT then break end
        jobs[#jobs+1]=QuoteJobSummary(job)
    end
    for index=#history,1,-1 do
        if #jobs>=TRADE_QUOTE_DIAG_JOB_LIMIT then break end
        jobs[#jobs+1]=QuoteJobSummary(history[index])
    end
    return {activeCount=activeCount,totalCount=totalCount,maxActive=TRADE_MAX_ACTIVE_QUOTE_JOBS,jobs=jobs}
end

function Trade:GetQuoteJob(rowKey)
    local job=type(self.quoteJobsByRowKey)=="table" and self.quoteJobsByRowKey[tostring(rowKey or "")] or nil
    return QuoteJobSummary(job)
end

function Trade:IsRowQuoteActive(rowKey)
    local job=type(self.quoteJobsByRowKey)=="table" and self.quoteJobsByRowKey[tostring(rowKey or "")] or nil
    return type(job)=="table" and job.active==true
end

function Trade:_PruneQuoteJobHistory()
    -- 当前路线通常只有少量行，但历史任务不能无界增长。只淘汰最老的非 active 记录；active 永远不删。
    if #(self.quoteJobOrder or {})<=32 then return end
    local compact={}
    for _,rowKey in ipairs(self.quoteJobOrder or {}) do
        local job=self.quoteJobsByRowKey[rowKey]
        if type(job)=="table" and job.active==true then compact[#compact+1]=rowKey end
    end
    for index=#(self.quoteJobOrder or {}),1,-1 do
        local rowKey=self.quoteJobOrder[index];local job=self.quoteJobsByRowKey[rowKey]
        if type(job)=="table" and job.active~=true then
            local exists=false;for _,key in ipairs(compact) do if key==rowKey then exists=true break end end
            if not exists then table.insert(compact,1,rowKey) end
            if #compact>=32 then break end
        end
    end
    self.quoteJobOrder=compact
    local keep={};for _,key in ipairs(compact) do keep[key]=true end
    for key,job in pairs(self.quoteJobsByRowKey) do if keep[key]~=true and type(job)=="table" and job.active~=true then self.quoteJobsByRowKey[key]=nil end end
end

function Trade:CancelQuoteRowMaterials(rowKey,reason)
    rowKey=tostring(rowKey or "")
    local job=self.quoteJobsByRowKey and self.quoteJobsByRowKey[rowKey] or nil
    if type(job)~="table" or job.active~=true then return false,"该货物当前没有询价任务" end
    job.active=false;job.state="cancelled";job.reason=tostring(reason or "user_cancelled")
    job.completedAt=type(S.NowMs)=="function" and S.NowMs() or 0
    local queue=S.Services and S.Services.PriceQuoteQueueV3
    if queue and type(queue.CancelRequester)=="function" then queue:CancelRequester(job.requester) end
    self.lastQuoteJob=QuoteJobSummary(job)
    self:_RefreshQuoteAggregate("row_cancelled")
    for _,row in ipairs(TA.rows or {}) do ApplyTradeMaterialProjectionToRow(row) end
    TA.revision=TA.revision+1;PublishFeatureUpdate(self,TA.revision,"quote_row_cancelled")
    return true
end

function Trade:CancelQuoteBatch(reason)
    -- 兼容旧命令名：现在表示取消本 Feature 的全部 RowJob。每个 requester 精确解绑；共享材料若仍有别的
    -- RowJob/Feature watcher，PriceQuoteQueueV3 会继续处理，不会因为某个货物取消而杀掉其它任务。
    self.quoteEpoch=(tonumber(self.quoteEpoch) or 0)+1
    local queue=S.Services and S.Services.PriceQuoteQueueV3
    for _,job in pairs(type(self.quoteJobsByRowKey)=="table" and self.quoteJobsByRowKey or {}) do
        if type(job)=="table" and job.active==true then
            job.active=false;job.state="cancelled";job.reason=tostring(reason or "cancelled")
            job.completedAt=type(S.NowMs)=="function" and S.NowMs() or 0
            if queue and type(queue.CancelRequester)=="function" then queue:CancelRequester(job.requester) end
            self.lastQuoteJob=QuoteJobSummary(job)
        end
    end
    -- 热重载兼容：18.315 以前可能仍存在旧 requester 名称。
    if queue and type(queue.CancelRequester)=="function" then queue:CancelRequester("life_trade") end
    if S.Scheduler then S.Scheduler:RemoveTask(QUOTE_REFRESH_TASK) end
    self.quoteRefreshPending=false;self.quoteMaterialKeys={}
    self.quoteJobsByRowKey={};self.quoteJobOrder={};self.lastQuoteJob=nil
    self.quoteBatch={active=false,total=0,completed=0,ready=0,failed=0,mode="basic",scope="multi",activeJobs=0,totalJobs=0,reason=tostring(reason or "cancelled")}
    for _,row in ipairs(TA.rows or {}) do ApplyTradeMaterialProjectionToRow(row) end
    TA.revision=TA.revision+1;PublishFeatureUpdate(self,TA.revision,"quote_cancelled")
    return true
end

function Trade:_FlushQuoteRefresh(epoch,reason)
    if epoch~=Trade.quoteEpoch then return true end
    if S.Scheduler and type(S.Scheduler.RemoveTask)=="function" then S.Scheduler:RemoveTask(QUOTE_REFRESH_TASK) end
    Trade.quoteRefreshPending=false
    local keys=Trade.quoteMaterialKeys or {};Trade.quoteMaterialKeys={}
    if not Trade.enabled or Trade.consumerCount<=0 then return true end
    local begin=type(S.NowMs)=="function" and S.NowMs() or 0
    local changed=TA:RefreshQuotedMaterial(keys)
    local now=type(S.NowMs)=="function" and S.NowMs() or begin
    Trade.quoteRefreshDiagnostics={
        refreshMs=math.max(0,now-begin),lastRefreshAt=now,lastRefreshReason=tostring(reason or "coalesced"),lastRefreshChanged=changed==true,
    }
    Trade:_RefreshQuoteAggregate(reason or "coalesced")
    return true
end

function Trade:_QueueQuoteRefresh(materialKey,epoch,terminal)
    self.quoteMaterialKeys=self.quoteMaterialKeys or {}
    if materialKey~=nil and materialKey~="" then self.quoteMaterialKeys[materialKey]=true end
    -- 任意 RowJob 到达终态都立即 flush 当前已完成材料；这只读共享 QuoteQueue read-model，不会增加 Native 请求。
    if terminal==true then return self:_FlushQuoteRefresh(epoch,"row_job_terminal") end
    if self.quoteRefreshPending then return true end
    self.quoteRefreshPending=true
    local function Apply() return Trade:_FlushQuoteRefresh(epoch,"coalesced") end
    if S.Scheduler and type(S.Scheduler.AddOneShot)=="function" then
        local ok=S.Scheduler:AddOneShot(QUOTE_REFRESH_TASK,100,Apply,self,"P3",1)
        if ok==true then return true end
    end
    return Apply()
end

local function ResolveTradeQuoteIdentity(material)
    local materialKey,itemType,itemGrade,gradeOffset
    if type(material)=="table" then
        materialKey=tostring(material.materialKey or material.internalKey or "")
        itemType,itemGrade=tonumber(material.itemType),tonumber(material.itemGrade)
    else materialKey=tostring(material or "") end
    local metaTable=S.Data and S.Data.TradeMaterialAuctionMeta
    local meta=type(metaTable)=="table" and metaTable[materialKey] or nil
    if type(meta)=="table" then
        itemType=itemType or tonumber(meta.itemType);itemGrade=itemGrade or tonumber(meta.itemGrade);gradeOffset=tonumber(meta.gradeOffset)
    end
    if itemType==nil or itemType<=0 then return materialKey,nil,nil end
    itemType=math.floor(itemType);itemGrade=itemGrade or (gradeOffset~=nil and gradeOffset+1) or 1
    itemGrade=math.max(0,math.min(20,math.floor(tonumber(itemGrade) or 1)))
    if materialKey=="" then materialKey="item:"..tostring(itemType) end
    return materialKey,itemType,itemGrade
end

function Trade:_CompleteQuoteJobMaterial(job,quoteKey,status,reason)
    if type(job)~="table" or job.active~=true or job.epoch~=self.quoteEpoch then return false,false,nil end
    if self.quoteJobsByRowKey[tostring(job.rowKey or "")]~=job then return false,false,nil end
    local item=type(job.items)=="table" and job.items[quoteKey] or nil
    if type(item)~="table" or item.done==true then return false,false,nil end
    item.done=true;item.status=tostring(status or "failed");item.reason=tostring(reason or "completed")
    job.completed=(tonumber(job.completed) or 0)+1
    if item.status=="ready" then job.ready=(tonumber(job.ready) or 0)+1 else job.failed=(tonumber(job.failed) or 0)+1 end
    local terminal=job.completed>=job.total
    if terminal then
        job.active=false;job.completedAt=type(S.NowMs)=="function" and S.NowMs() or 0
        if (tonumber(job.failed) or 0)<=0 then job.state="ready"
        elseif (tonumber(job.ready) or 0)>0 then job.state="partial" else job.state="failed" end
        self.lastQuoteJob=QuoteJobSummary(job)
    else job.state="quoting" end
    self:_RefreshQuoteAggregate(terminal and "row_terminal" or "row_progress")
    return true,terminal,item.materialKey
end

function Trade:_ReconcileQuoteJobsByIdentity(itemType,itemGrade,status,reason)
    -- Queue completion event is the shared Authority backstop. Normal callbacks arrive first, so done=true makes this idempotent;
    -- if a requester callback is lost during a lifecycle edge, the stable item identity still converges every affected RowJob.
    local id=tonumber(itemType);if id==nil or id<=0 then return false end
    id=math.floor(id);local grade=tonumber(itemGrade);if grade~=nil then grade=math.floor(grade) end
    local changed=false;local terminal=false;local materialKeys={}
    for _,job in pairs(type(self.quoteJobsByRowKey)=="table" and self.quoteJobsByRowKey or {}) do
        if type(job)=="table" and job.active==true and type(job.items)=="table" then
            for quoteKey,item in pairs(job.items) do
                if item.done~=true and tonumber(item.itemType)==id
                    and (grade==nil or tonumber(item.itemGrade)==nil or math.floor(tonumber(item.itemGrade))==grade) then
                    local did,ended,key=self:_CompleteQuoteJobMaterial(job,quoteKey,status,reason or "queue_event")
                    if did then changed=true;terminal=terminal or ended;if key then materialKeys[key]=true end end
                end
            end
        end
    end
    if changed then
        for key in pairs(materialKeys) do self.quoteMaterialKeys[key]=true end
        if terminal then self:_FlushQuoteRefresh(self.quoteEpoch,"queue_event_terminal") end
    end
    return changed
end

function Trade:QuoteMaterial(material,mode,job)
    if not self.enabled then return false,"跑商功能已关闭" end
    if type(job)~="table" or job.active~=true then return false,"货物询价任务已失效" end
    local materialKey,itemType,itemGrade=ResolveTradeQuoteIdentity(material)
    if not itemType then return false,"该材料没有已验证的拍卖行身份，无法询价" end
    local queue=S.Services and S.Services.PriceQuoteQueueV3
    if not queue or type(queue.RequestQuote)~="function" then return false,"报价服务不可用" end
    local grades={itemGrade};local seen={[itemGrade]=true}
    if mode=="full" then for grade=0,6 do if not seen[grade] then grades[#grades+1]=grade;seen[grade]=true end end end
    local projectedName=type(material)=="table" and (material.searchName or material.name) or nil
    local searchName=LocalizedTradeItemName(itemType,projectedName)
    local quoteKey=tostring(itemType)..":"..tostring(itemGrade)
    return queue:RequestQuote(job.requester,itemType,itemGrade,function(result)
        if job.epoch~=Trade.quoteEpoch or not Trade.enabled then return end
        if Trade.quoteJobsByRowKey[tostring(job.rowKey or "")]~=job then return end
        local did,terminal,key=Trade:_CompleteQuoteJobMaterial(job,quoteKey,tostring(result and result.status or "failed"),result and (result.error or result.priceSource) or "callback")
        if did then Trade:_QueueQuoteRefresh(key or materialKey,job.epoch,terminal) end
    end,grades,{searchName=searchName,force=true,priority="user"})
end

function Trade:_StartRowQuoteJob(row,mode,options)
    if not self.enabled then return false,"跑商功能已关闭" end
    if type(row)~="table" or row.key==nil then return false,"贸易品已不在当前路线结果中" end
    options=type(options)=="table" and options or {}
    local rowKey=tostring(row.key)
    local existing=self.quoteJobsByRowKey[rowKey]
    if type(existing)=="table" and existing.active==true then
        return true,"正在查询该货物材料 "..tostring(existing.completed or 0).."/"..tostring(existing.total or 0),0,tonumber(existing.deferred) or 0
    end
    if self:_CountActiveQuoteJobs()>=TRADE_MAX_ACTIVE_QUOTE_JOBS then return false,"同时询价货物已达到 "..tostring(TRADE_MAX_ACTIVE_QUOTE_JOBS).." 个，请等待部分完成" end
    local queue=S.Services and S.Services.PriceQuoteQueueV3
    if not queue then return false,"报价服务不可用" end
    local maxItems=math.max(1,math.min(TRADE_MATERIAL_MAX_ROWS,math.floor(tonumber(options.maxItems) or TRADE_ROW_QUOTE_BATCH_MAX)))
    local now=type(S.NowMs)=="function" and S.NowMs() or 0
    ApplyTradeMaterialProjectionToRow(row)
    local selected,seen,deferred,joinedPending={}, {},0,0
    for _,m in ipairs(row.materialRows or {}) do
        local materialKey,id,grade=ResolveTradeQuoteIdentity(m);local key=id and (tostring(id)..":"..tostring(grade))
        local state=id and queue:GetQuoteStateByItemType(id,grade)
        local cooling=state and state.status=="failed" and now-(state.at or 0)>=0 and now-(state.at or 0)<queue.negativeTtlMs
        local pending=state and (state.status=="queued" or state.status=="inflight")
        local missing=m.costStatus=="explicit_quote_required" or m.costStatus=="quote_failed" or m.costStatus=="quoted_reference" or m.costStatus=="quote_pending"
        -- 双击/显式 RowJob 的语义是“强制校准这个货物”，即使本地价格仍 fresh 也允许重验；
        -- PriceQuoteQueueV3 会按 itemType+grade 去重并把 user 请求排在 background 前，不会并发打 Native。
        local explicitlyRequested = options.force ~= false
        if key and not seen[key] and m.auctionable~=false and m.includeInCost~=false and (explicitlyRequested or missing or mode=="full") then
            seen[key]=true
            if (cooling and mode~="full") or #selected>=maxItems then deferred=deferred+1
            else
                if pending then joinedPending=joinedPending+1 end
                selected[#selected+1]={materialKey=materialKey,itemType=id,itemGrade=grade,searchName=m.name,quoteKey=key}
            end
        end
    end
    if #selected==0 then
        if row.materialCostComplete==true and row.materialCostCopper~=nil then return true,"该货物材料价格已可用，毛利已更新",0,deferred end
        return false,"没有可询价材料；已有有效报价、失败冷却中，或材料本身不可拍卖",0,deferred
    end
    self.quoteJobSequence=(tonumber(self.quoteJobSequence) or 0)+1
    local job={
        id=self.quoteJobSequence,epoch=self.quoteEpoch,rowKey=rowKey,label=tostring(row.name or "货物"),
        requester="life_trade:rowjob:"..tostring(self.quoteJobSequence),mode=mode or "basic",state="queued",active=true,
        total=#selected,completed=0,ready=0,failed=0,deferred=deferred,joinedPending=joinedPending,maxItems=maxItems,
        createdAt=now,items={},
    }
    for _,material in ipairs(selected) do
        job.items[material.quoteKey]={materialKey=material.materialKey,itemType=material.itemType,itemGrade=material.itemGrade,done=false,status="queued"}
    end
    self.quoteJobsByRowKey[rowKey]=job
    local nextOrder={}
    for _,key in ipairs(self.quoteJobOrder or {}) do if key~=rowKey then nextOrder[#nextOrder+1]=key end end
    nextOrder[#nextOrder+1]=rowKey;self.quoteJobOrder=nextOrder
    self:_PruneQuoteJobHistory();self:_RefreshQuoteAggregate("row_started")
    for _,material in ipairs(selected) do
        local ok,err=self:QuoteMaterial(material,mode,job)
        if ok~=true then
            local did,terminal,key=self:_CompleteQuoteJobMaterial(job,material.quoteKey,"failed",err)
            if did then self:_QueueQuoteRefresh(key or material.materialKey,job.epoch,terminal) end
        end
    end
    -- 单行入口立即重投影；批量列表入口延迟到所有 RowJob 建好后只做一次全表重投影，避免 O(rows²) UI 重建。
    if options.deferPublish~=true then
        for _,displayRow in ipairs(TA.rows or {}) do ApplyTradeMaterialProjectionToRow(displayRow) end
        TA.revision=TA.revision+1;PublishFeatureUpdate(self,TA.revision,"quote_row_job_started")
    end
    return true,"已加入询价："..job.label.." · "..tostring(job.total).." 项材料"..(joinedPending>0 and (" · 共享等待 "..tostring(joinedPending)) or "")..(deferred>0 and (" · 延后 "..tostring(deferred)) or ""),job.total,deferred
end

function Trade:QuotePendingMaterials(mode)
    -- “询价当前列表”创建多个独立 RowJob；不会取消已经运行的任务。真正 Native 请求仍由共享 Queue 单通道串行。
    local started,already,readyRows,skipped=0,0,0,0
    local limit=math.min(TRADE_BULK_QUOTE_MAX_ROWS,#(TA.rows or {}))
    for index=1,limit do
        local row=TA.rows[index]
        if row and row.key~=nil then
            local existing=self.quoteJobsByRowKey[tostring(row.key)]
            if type(existing)=="table" and existing.active==true then already=already+1
            elseif self:_CountActiveQuoteJobs()>=TRADE_MAX_ACTIVE_QUOTE_JOBS then skipped=skipped+1
            else
                local ok,_,total=self:_StartRowQuoteJob(row,mode,{maxItems=TRADE_ROW_QUOTE_BATCH_MAX,scope="row",bulk=true,deferPublish=true})
                if ok==true and (tonumber(total) or 0)>0 then started=started+1
                elseif ok==true then readyRows=readyRows+1 else skipped=skipped+1 end
            end
        end
    end
    self:_RefreshQuoteAggregate("bulk_submit")
    if started>0 then
        -- 维护（2026-09-25，trade-multi-row-bulk-projection-1）：批量按钮是显式低频动作，但仍只在所有
        -- RowJob 注册完成后做一次 bounded 全表重投影；禁止每创建一个任务就重复重建整张列表。
        for _,displayRow in ipairs(TA.rows or {}) do ApplyTradeMaterialProjectionToRow(displayRow) end
        TA.revision=TA.revision+1;PublishFeatureUpdate(self,TA.revision,"quote_bulk_jobs_started")
    end
    if started==0 and already==0 then
        if readyRows>0 then return true,"当前列表已有可用材料价格，无需再次询价",0,skipped end
        return false,"当前列表没有可提交的材料询价",0,skipped
    end
    local parts={}
    if started>0 then parts[#parts+1]="新加入 "..tostring(started).." 个货物" end
    if already>0 then parts[#parts+1]="已有 "..tostring(already).." 个货物询价中" end
    if skipped>0 then parts[#parts+1]="另有 "..tostring(skipped).." 个暂未提交" end
    return true,table.concat(parts," · "),started,skipped
end

function Trade:QuoteRowMaterials(rowKey,mode)
    local row=self:GetRow(rowKey);if not row then return false,"贸易品已不在当前路线结果中" end
    -- 与旧版不同：双击另一行不再 supersede 之前的 RowJob。多个业务任务并存，底层材料请求仍由 Queue 去重/串行。
    return self:_StartRowQuoteJob(row,mode,{maxItems=TRADE_ROW_QUOTE_BATCH_MAX,scope="row",force=true})
end


-- Diagnostics reads describe helpers off the Feature table (S.Features.Trade),
-- but the request/identity state lives on the Authority. Bonds defines its
-- describe helpers directly on the feature table, which is why its row always
-- rendered; expose the same reachability here or the 跑商 row degrades to
-- "状态机诊断不可用" forever.
function Trade:DescribeRequestState() return TA:DescribeRequestState() end
function Trade:DescribeIdentityState() return TA:DescribeIdentityState() end
function Trade:DescribeQuoteState()
    -- 维护（2026-09-24，trade-quote-diagnostics-2）：模块诊断必须能直接回答“询价为什么失败”，但不能把
    -- AuctionQueryV3 最多 20 条搜索结果和 QuoteQueue 全部历史原样塞进报告。这里仅读取两个共享 Authority 的
    -- detached Describe/Snapshot，并压缩成“最近完成/原生返回/fallback 匹配/最多3条候选”证据；不获取 Consumer、
    -- 不触发 Native API、不改变缓存/存档。完整搜索结果仍由 AuctionQueryV3 自己持有，不复制成第二 Authority。
    local queue = S.Services and S.Services.PriceQuoteQueueV3 or nil
    local query = S.Services and S.Services.AuctionQueryV3 or nil
    local materialPrices = S.Services and S.Services.MaterialPriceServiceV3 or nil
    local health = type(queue) == "table" and type(queue.Describe) == "function" and queue:Describe() or nil
    local queueSummary = nil
    if type(health) == "table" then
        local recent = {}
        for index = 1, math.min(4, #(type(health.recent) == "table" and health.recent or {})) do
            recent[index] = Copy(health.recent[index])
        end
        queueSummary = {
            version = health.version, running = health.running, pending = health.pending,
            queueLength = health.queueLength, maxQueue = health.maxQueue, intervalMs = health.intervalMs,
            stats = Copy(health.stats), lastRawReturn = health.lastRawReturn,
            lastFallbackMatch = Copy(health.lastFallbackMatch), pendingDetail = Copy(health.pendingDetail),
            lastCompleted = Copy(health.lastCompleted), recent = recent,
        }
    end
    local search = type(query) == "table" and type(query.GetSnapshot) == "function" and query:GetSnapshot("price_quote_fallback") or nil
    local searchSummary = nil
    if type(search) == "table" then
        local candidates = {}
        local rows = type(search.rows) == "table" and search.rows or {}
        for index = 1, math.min(3, #rows) do
            local row = type(rows[index]) == "table" and rows[index] or {}
            candidates[index] = {
                resultIndex = row.resultIndex or index, itemType = row.itemType, itemGrade = row.itemGrade,
                name = row.name, quantity = row.quantity, bidPrice = row.bidPrice, directPrice = row.directPrice,
                unitBidPrice = row.unitBidPrice, unitDirectPrice = row.unitDirectPrice,
            }
        end
        searchSummary = {
            status = search.status, keyword = search.keyword, count = search.count, error = search.error,
            requestedAt = search.requestedAt, completedAt = search.completedAt, candidates = candidates,
        }
    end
    return {
        batch = self:GetQuoteBatch(), jobs = self:GetQuoteJobs(), queue = queueSummary,
        fallbackSearch = searchSummary, readModelSync = Copy(TA.quoteReadModelSync or {}),
        materialPriceCache = type(materialPrices) == "table" and type(materialPrices.Describe) == "function" and materialPrices:Describe() or nil,
        economics = Copy(TA.economics or {}), materialRevalidate = Copy(TA.materialRevalidateDiagnostics or {}),
        payout = (S.Services and S.Services.TradePayoutV3 and type(S.Services.TradePayoutV3.Describe) == "function") and S.Services.TradePayoutV3:Describe() or nil,
    }
end
Trade.Commands = { Refresh = function(_, reason) return Trade:Refresh(reason) end, SetFrom = function(_, id) return Trade:SetFrom(id) end, SetTo = function(_, id) return Trade:SetTo(id) end,
    SetSortMode = function(_, mode) return Trade:SetSortMode(mode) end,
    SetRatioMode = function(_, mode) return Trade:SetRatioMode(mode) end, SetCommerceMode = function(_, mode) return Trade:SetCommerceMode(mode) end,
    SetViewMode = function(_, mode) return Trade:SetViewMode(mode) end, ToggleTrackedProduct = function(_, value) return Trade:ToggleTrackedProduct(value) end,
    SetAutoRefresh = function(_, value) return Trade:SetAutoRefresh(value) end, SetCargoScan = function(_, value) return Trade:SetCargoScan(value) end,
    ToggleCurrentFavorite = function() return Trade:ToggleCurrentFavorite() end, SelectFavorite = function(_, key) return Trade:SelectFavorite(key) end,
    SelectRow = function(_, key) return Trade:SelectRow(key) end,
    QuoteMaterial = function(_, materialKey) return Trade:QuoteMaterial(materialKey) end,
    QuotePendingMaterials = function(_, mode) return Trade:QuotePendingMaterials(mode) end, QuoteRowMaterials = function(_, rowKey, mode) return Trade:QuoteRowMaterials(rowKey, mode) end,
    CancelQuoteRowMaterials = function(_, rowKey, reason) return Trade:CancelQuoteRowMaterials(rowKey, reason) end,
    CancelQuoteBatch = function(_,reason) return Trade:CancelQuoteBatch(reason) end,
    CycleFrom = function(_, delta) return Trade:CycleFrom(delta) end, CycleTo = function(_, delta) return Trade:CycleTo(delta) end,
    GetWidgetVisible = function() return Trade:GetWidgetVisible() end, SetWidgetVisible = function(_, value, reason) return Trade:SetWidgetVisible(value, reason) end,
    SetWidgetWindowState = function(_, value, reason) return Trade:SetWidgetWindowState(value, reason) end,
    MarkStoreDirty = function(_, delayMs, reason) return Trade:MarkStoreDirty(delayMs, reason) end }
local tradeDemand, tradeErr = Demand:Create({ id = "feature:" .. Trade.Id, owner = Trade, projectionOwner = Trade, projectionConsumersField = "consumers", projectionCountField = "consumerCount", reconcile = function(lease, before, after) return Trade:ReconcileDemand(lease, before, after) end })
if tradeDemand == nil then error(tradeErr) end
Trade.Demand = tradeDemand
local ok, err = Runtime:RegisterImplementation(Trade.Id, Trade); if ok ~= true then error(err) end

-- 中文维护注释（2026-09-28，Phase 2 Step 3）：life_bonds 已机械搬迁到
-- features/life/bonds/rs_bonds_feature.lua（toc.g 只登记一次；X2Quest ownership 仍在 Registry 的 .328 声明）。

-- 中文维护注释（2026-09-28，Phase 2 Step 1）：life_treasure 已机械搬迁到
-- features/life/treasure/rs_treasure_feature.lua（toc.g 只登记一次；§24.3 的地图权限红线随文件搬走）。
-- 共享装配 helper 已收敛到 features/life/shared/rs_life_slice_factory.lua。

-- 中文维护注释（2026-09-28，Phase 2 Step 2）：life_fishing 已机械搬迁到
-- features/life/fishing/rs_fishing_feature.lua（toc.g 只登记一次；§24.3 的 Auto-R 事务契约随文件搬走）。
