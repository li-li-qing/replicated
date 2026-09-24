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
TA.AutoRefreshContractVersion = 2
TA.NativeCallbackLeaseContractVersion = 1
TA.CargoObservationContractVersion = 1
TA.PreferenceProjectionContractVersion = 1
TA.requestTimeoutTask = "v3_trade_route_timeout"
TA.timeoutDrainTask = "v3_trade_timeout_drain"
TA.requestDeferredTask = "v3_trade_route_deferred"
TA.requestAutoTask = "v3_trade_route_auto_refresh"
TA.equipmentRefreshTask = "v3_trade_equipment_refresh"
TA.cargoPumpTask = "v3_trade_cargo_pump"
TA.cargoRescanTask = "v3_trade_cargo_rescan"
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
TA.cargoRescanIntervalMs = 15000
-- 维护（2026-09-23，trade-cargo-native-budget-1）：随身扫描是低优先级后台消费者。即使某个 RU 客户端
-- 对 GetSpecialtyRatioBetween 的数值返回语义发生变化，也至少保持 1 秒 Native 间隔；正常情况下更大的
-- 服务器返回节流仍优先生效。这样不会因错误把 0/小数值解释成 cooldown 而对几十个目的地形成短时请求风暴。
TA.cargoMinIntervalMs = 1000
TA.cargo = { status = "empty", itemType = nil, legacyName = nil, name = nil, originZone = nil, results = {}, queue = {}, generation = 0, scanning = false, lastScanAt = 0, scanStartedAt = 0, error = nil }
TA.requestTrace = {}
TA.TradePayoutProjectionContractVersion = 1
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
-- 维护（2026-09-23，trade-row-quote-intent-1）：全列表批量询价仍保持 4 项预算，避免误操作导致拍卖行请求洪泛；
-- 但“用户双击某一货物”是明确的单行意图，必须覆盖该行已解析出的全部材料，否则会出现点了询价却仍算不出毛利。
-- 单行预算受 TRADE_MATERIAL_MAX_ROWS 的硬上限保护，底层 PriceQuoteQueueV3 继续串行执行，不增加 Native 并发。
local TRADE_DEFAULT_QUOTE_BATCH_MAX = 4
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
            local quotedPrice
            if type(quoteQueue) == "table" and type(quoteQueue.GetQuoteStateByItemType) == "function" then
                quoteState = quoteQueue:GetQuoteStateByItemType(itemType, itemGrade)
            end
            -- 维护：缓存新鲜度由QuoteService决定，不能把旧ready状态永久当实时价。
            if type(quoteQueue) == "table" and type(quoteQueue.GetPriceWithProvenance) == "function" then
                quotedPrice, priceProvenance = quoteQueue:GetPriceWithProvenance(itemType, itemGrade)
            end
            if quotedPrice ~= nil and priceProvenance ~= "reference" then
                unitCost, totalCost, status = quotedPrice, quotedPrice * count, "quoted"
            elseif quotedPrice ~= nil then
                unitCost, totalCost, priceProvenance, status = quotedPrice, quotedPrice * count, "reference", "quoted_reference"
            elseif quoteState ~= nil and (quoteState.status == "queued" or quoteState.status == "inflight") then
                -- An explicit re-quote is in flight: keep showing any reference cost
                -- rather than regressing to "pending" while it runs.
                local referenceOnly
                if type(quoteQueue) == "table" and type(quoteQueue.GetReferencePrice) == "function" then
                    referenceOnly = quoteQueue:GetReferencePrice(itemType, itemGrade)
                end
                if referenceOnly ~= nil then
                    unitCost, totalCost, priceProvenance, status = referenceOnly, referenceOnly * count, "reference", "quoted_reference"
                else
                    complete, status = false, "quote_pending"
                end
            elseif quoteState ~= nil and quoteState.status == "failed" then
                local referenceOnly
                if type(quoteQueue) == "table" and type(quoteQueue.GetReferencePrice) == "function" then
                    referenceOnly = quoteQueue:GetReferencePrice(itemType, itemGrade)
                end
                quoteError = type(quoteState.error) == "string" and quoteState.error or tostring(quoteState.code or "报价失败")
                if referenceOnly ~= nil then
                    unitCost, totalCost, priceProvenance, status = referenceOnly, referenceOnly * count, "reference", "quoted_reference"
                else
                    complete, status = false, "quote_failed"
                end
            else
                local referenceOnly, referenceMeta
                if type(quoteQueue) == "table" and type(quoteQueue.GetReferencePrice) == "function" then
                    referenceOnly, referenceMeta = quoteQueue:GetReferencePrice(itemType, itemGrade)
                end
                if referenceOnly ~= nil then
                    unitCost, totalCost, priceProvenance, status = referenceOnly, referenceOnly * count, "reference", "quoted_reference"
                else
                    complete, status = false, "explicit_quote_required"
                end
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
            row.detailText = row.detailText .. "（单价 " .. Money(unitCost) .. " / 小计 " .. Money(totalCost)
                .. (priceProvenance == "reference" and "，参考" or "") .. "）"
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
    row.materials = materialProjection.summary
    row.text = materialProjection.summary
    row.materialRows = materialProjection.materialRows
    row.materialCount = materialProjection.count
    row.materialSourceCount = materialProjection.sourceCount
    row.materialLimit = TRADE_MATERIAL_MAX_ROWS
    row.materialsTruncated = materialProjection.truncated
    row.materialSummaryTruncated = materialProjection.summaryDisplayTruncated
    row.materialCostCopper = cost
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
    -- .18.176 RU evidence: GetLowestPrice returns nil for every grade on every
    -- control itemType (oats/hay/egg included), so a material cost is currently
    -- unobtainable on this client. "待材料价格" used to imply the number was merely
    -- pending; say what is actually missing and where the player can still get a
    -- usable estimate (the sell price and 货率 columns remain real facts).
    if profit then
        row.profitStatus = "ready"
        row.profit = Money(profit) .. ((row.boundResourceCount > 0 or row.nonMarketResourceCount > 0) and "*" or "")
    else
        -- 维护（2026-09-23，trade-row-actionable-profit-1）：紧凑列表中的毛利列必须告诉玩家“下一步做什么”。
        -- 旧文案“缺材料价（拍卖行无返回）”既过长又像永久故障，且无法解释显式询价模型。这里仅消费已经
        -- 解析好的材料状态，不发 Native 请求；双击行为仍由 Presentation -> QuoteRowMaterials 明确触发。
        local hasQuotePending, hasQuoteFailed, hasQuoteRequired = false, false, false
        for _, material in ipairs(type(materialProjection.materialRows) == "table" and materialProjection.materialRows or {}) do
            if material.costStatus == "quote_pending" then hasQuotePending = true
            elseif material.costStatus == "quote_failed" then hasQuoteFailed = true
            elseif material.costStatus == "explicit_quote_required" then hasQuoteRequired = true end
        end
        -- 维护（2026-09-24，trade-row-quote-visual-scope-1）：PriceQuoteQueueV3 的 itemType 状态是共享事实；
        -- 两个贸易品共用同一材料时，用户双击 A 行后 B 行也会看到该材料的 queued/inflight。共享价格事实必须
        -- 保留，但“询价中…”是用户意图提示，单行批次只能标在被双击的 rowKey 上。完成后的 ready/failed
        -- 仍会按共享材料事实传播到其它行，避免为了 UI 外观复制第二套报价 Authority。
        local rowBatch = type(Trade.quoteBatch) == "table" and Trade.quoteBatch or nil
        local rowScopedPending = rowBatch ~= nil and rowBatch.active == true and rowBatch.scope == "row"
        local isIntentRow = not rowScopedPending or tostring(rowBatch.rowKey or "") == tostring(row.key or "")
        if hasQuotePending and not isIntentRow then
            hasQuotePending = false
            hasQuoteRequired = true
        end
        if price == nil then
            row.profitStatus, row.profit = "price_unavailable", "--"
        elseif hasQuotePending then
            row.profitStatus, row.profit = "quote_pending", "询价中…"
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

local function ApplyTradeDisplayModeToRow(row)
    if type(row) ~= "table" then return false end
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
    row.packMultiplierSource = estimate.packMultiplierSource
    if row.priceComplete then
        row.priceBreakdown = "货率基价 " .. Money(estimate.baseAtRatioCopper)
            .. " × 熟练 " .. string.format("%.3f", tonumber(estimate.commerceMultiplier) or 1)
            .. " × 品类 " .. string.format("%.2f", tonumber(estimate.packMultiplier) or 1)
    elseif row.priceEstimateStatus == "commerce_skill_unavailable" then
        row.priceBreakdown = "经商熟练度不可读，已停止输出不完整售价"
    elseif row.priceEstimateStatus == "price_key_missing" then
        row.priceBreakdown = "静态售价 Key 未匹配：" .. tostring(row.sourceName or row.name or "?")
    else
        row.priceBreakdown = "售价估算不可用：" .. row.priceEstimateStatus
    end
    row.tone = ratio >= 125 and "green" or (ratio >= 115 and "yellow" or "red")
    ApplyTradeMaterialProjectionToRow(row)
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

function TA:BuildCargoDisplayRows()
    local cargo = type(self.cargo) == "table" and self.cargo or {}
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
            ApplyTradeDisplayModeToRow(row)
            row.tracked = Trade:IsTrackedProduct(row.itemType)
            rows[#rows + 1] = row
        end
    end
    return rows
end

function TA:RebuildDisplayRows(reason)
    local mode = Trade:GetViewMode()
    local rows = {}
    if mode == "cargo" then
        rows = self:BuildCargoDisplayRows()
    else
        for _, raw in ipairs(type(self.rawRows) == "table" and self.rawRows or {}) do
            if mode == "all" or Trade:IsTrackedProduct(raw.itemType) then
                local row = CopyTradeRouteRow(raw)
                ApplyTradeDisplayModeToRow(row)
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
    self.revision = self.revision + 1
    PublishFeatureUpdate(Trade, self.revision, reason or "trade_display_mode")
    if type(self.RequestPendingLiveIdentities) == "function" then self:RequestPendingLiveIdentities() end
    return true
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
    return true, changed
end

local function TradeBackpackSlot()
    local slot = rawget(_G, "EST_BACKPACK")
    return Number(slot)
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
    local slot = TradeBackpackSlot()
    if slot == nil then
        cargo.status, cargo.error = "unavailable", "EST_BACKPACK 不可用"
        cargo.itemType, cargo.legacyName, cargo.name, cargo.originZone = nil, nil, nil, nil
        local changed = ObservationChanged()
        if oldItemType ~= nil then
            cargo.results, cargo.queue, cargo.scanning = {}, {}, false
            cargo.generation = (tonumber(cargo.generation) or 0) + 1
        end
        return true, changed
    end
    local ok, itemType, err = Call("X2Equipment:GetEquippedItemType", EquipmentApi, "GetEquippedItemType", slot)
    itemType = ok == true and Number(itemType) or nil
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
    TraceInit("cargo_observed", tostring(reason or "refresh") .. " item=" .. tostring(itemType) .. " origin=" .. tostring(originZone or "-"))
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

-- Live identity fill-in: after a route result, rows the static chain could not
-- name submit ONE bounded service request per distinct product itemType; the
-- identity service serializes the X2Craft reads and calls back here.
function TA:RequestPendingLiveIdentities()
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
    self:RebuildDisplayRows(reason or "route_cache_restore")
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

function TA:ArmAutoRefresh(delayMs)
    if S.Scheduler == nil or type(S.Scheduler.AddOneShot) ~= "function" then return false end
    self:CancelAutoRefresh()
    if Trade.enabled ~= true or (tonumber(Trade.consumerCount) or 0) <= 0 or Trade.Preferences.autoRefresh ~= true then return false end
    if Trade:GetViewMode() == "cargo" then return false end
    if Number(Trade.State.fromZone) == nil or Number(Trade.State.toZone) == nil then return false end
    local delay = math.max(250, tonumber(delayMs) or tonumber(self.autoRefreshTargetMs) or 10000)
    return S.Scheduler:AddOneShot(self.requestAutoTask, delay, function()
        if Trade.enabled ~= true or (tonumber(Trade.consumerCount) or 0) <= 0 or Trade.Preferences.autoRefresh ~= true or Trade:GetViewMode() == "cargo" then return true end
        local ok = TA:Request(false, "auto_refresh")
        if ok ~= true then TA:ArmAutoRefresh(1000) end
        return true
    end, Trade, "P3", 1)
end

function TA:ScheduleNextAutoRefresh()
    if Trade.Preferences.autoRefresh ~= true or Trade:GetViewMode() == "cargo" then self:CancelAutoRefresh(); return false end
    -- 后台刷新不能把 Native 单通道持续占满。最近一次 Native cooldown 若为 5 秒，则下一次自动刷新至少 10 秒后；
    -- 这给收藏路线/手动目的地留下一个完整合法查询窗口，同时跨区与用户显式刷新仍可立即进入 Scheduler。
    local baseTarget = math.max(1000, tonumber(self.autoRefreshTargetMs) or 10000)
    local cooldownTarget = math.max(0, tonumber(self.lastNativeCooldownMs) or 0) * math.max(1, tonumber(self.autoRefreshCooldownFactor) or 2)
    local target = math.max(baseTarget, cooldownTarget)
    local remaining = self:GetNativeCooldownRemaining()
    return self:ArmAutoRefresh(math.max(target, remaining + 50))
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
    self:CancelAutoRefresh()
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
        self:RebuildDisplayRows("cargo_ratio_result")
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
        -- Consumer 已释放时只结算旧 Native lane，绝不因为迟到回调在后台追逐后来保存的路线。下一次真正的
        -- Consumer 会按当前 State 发起 initial 查询；这保持“关闭功能即释放资源”，同时避免回调串线。
        if Trade.enabled ~= true or (tonumber(Trade.consumerCount) or 0) <= 0 then
            self.status, self.error = "idle", nil
            self:TraceRequest("stale_callback_consumed_no_consumers", flight, "selected=" .. tostring(currentFrom) .. "->" .. tostring(currentTo))
            self.revision = self.revision + 1
            PublishFeatureUpdate(Trade, self.revision, "route_result_stale_no_consumers")
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
        return false
    end

    local rows = {}
    local now = callbackAt
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
    self.rawRows = rows
    self.lastCompletedRoute = { from = Number(flight.from), to = Number(flight.to) }
    self.lastRatioAt = now
    if #rows > 0 then self:StoreRouteCache(flight.from, flight.to, rows, now) end
    self.status, self.error = (#rows > 0 and "ready" or "error"), (#rows > 0 and nil or "服务器返回的货率列表为空")
    self:RebuildDisplayRows("ratio_result")
    TraceInit("ratio_result", "rows=" .. tostring(#rows) .. " from=" .. tostring(flight.from) .. "->" .. tostring(flight.to) .. " reason=" .. tostring(flight.reason or ""))
    if #rows > 0 then self:ScheduleNextAutoRefresh() end
    if Trade:GetViewMode() == "cargo" and self.cargo.scanning == true then self:ArmCargoPump(math.max(50, self:GetNativeCooldownRemaining() + 50)) end
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
        lastCallbackAt = type(self.diag) == "table" and tonumber(self.diag.lastCallbackAt) or 0,
        lastCallbackLatencyMs = type(self.diag) == "table" and tonumber(self.diag.lastCallbackLatencyMs) or 0,
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
        rawRowCount = #(self.rawRows or {}), displayRowCount = #(self.rows or {}), lastRatioAt = tonumber(self.lastRatioAt) or 0,
        ratioAgeMs = ratioAgeMs, isRefreshing = displayStatus == "refreshing" or displayStatus == "loading" or displayStatus == "cooldown",
        cargo = cargoProjection,
        payoutCalculator = type(payoutService) == "table" and payoutService:Describe() or nil,
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

Trade.ApiDependencies = { "X2Store:GetProductionZoneGroups", "X2Store:GetSellableZoneGroups", "X2Store:GetSpecialtyRatioBetween", "X2Ability:GetAllMyActabilityInfos", "X2Equipment:GetEquippedItemType" }
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
            -- Native 回执使用独立 lease owner；Demand 结束时不能撤销一个已经被服务器接受的请求的回调归属。
            local nativeSubscribed, nativeSubscribeErr = self:EnsureNativeRatioSubscription()
            if nativeSubscribed ~= true then
                self.eventUnavailable = true
                TraceInit("event_subscribe_failed", "SPECIALTY_RATIO_BETWEEN_INFO")
                return false, nativeSubscribeErr or "SPECIALTY_RATIO_BETWEEN_INFO 订阅失败"
            end
            -- 维护（2026-09-23，trade-event-refresh-1）：换装/跨区都由事件驱动，禁止 Tick 轮询。
            -- UNIT_EQUIPMENT_CHANGED 可能一次换装连续触发，Authority 内 220ms debounce 后只读取一次熟练度/背包槽；
            -- ENTER_ANOTHER_ZONEGROUP 只提高一次刷新优先级，不绕开 SingleFlight。
            S.Events:SubscribeOptional("UNIT_EQUIPMENT_CHANGED", self, function() return TA:ScheduleEquipmentRefresh("UNIT_EQUIPMENT_CHANGED") end)
            S.Events:SubscribeOptional("ENTER_ANOTHER_ZONEGROUP", self, function() return TA:HandleWorldBoundary("zone_change") end)
            self.eventUnavailable = false
        end
        self.Authority:RefreshCommerceSkill()
        self.Authority:RefreshCargoObservation("demand_start")
        self.Authority:RefreshZones()
        if self:GetViewMode() == "cargo" then
            self.Authority:StartCargoScan("demand_start")
        elseif Number(Trade.State.fromZone) ~= nil and Number(Trade.State.toZone) ~= nil then
            if #(TA.rawRows or {}) == 0 and TA.inFlight == nil then
                local requested, requestErr = TA:Request(false, "initial")
                if requested ~= true then TraceInit("demand_route_query_deferred", tostring(requestErr or "request_not_started")) end
            else
                TA:ScheduleNextAutoRefresh()
            end
        end
        TraceInit("demand_init_done", "zones=" .. tostring(#(TA.zones or {})) .. "/" .. tostring(#(TA.sellableZones or {}))
            .. " fallback=" .. tostring(TA.zoneFallback == true) .. "/" .. tostring(TA.sellableFallback == true)
            .. " commerce=" .. tostring(TA.commerceStatus or "-") .. " cargo=" .. tostring(TA.cargo.status or "-"))
    elseif beforeCount > 0 and afterCount <= 0 then
        -- 维护（2026-09-24，trade-native-callback-lease-1）：释放高频/业务观察资源，但已接受的 Native 请求必须
        -- 保留 inFlight + timeout + 独立回执订阅直到 callback/timeout 自然结算。诊断 18.294 已证明旧版在 native_accepted
        -- 后立刻 no_consumers，造成 1 次请求永久丢失。pendingRoute 属于 UI 意图，Consumer 归零时清掉，避免后台追新路线。
        if S.Events ~= nil then S.Events:UnsubscribeOwner(self) end
        local preserveNativeFlight = type(TA.inFlight) == "table" or type(TA.timedOutFlight) == "table"
        TA.pendingRoute = nil
        TA.pendingRetryCount = nil
        TA:CancelDeferredRequest()
        TA:CancelAutoRefresh()
        TA:CancelEquipmentRefresh()
        TA:StopCargoScan("no_consumers")
        TA:CancelLiveIdentities()
        self:CancelQuoteBatch("no_consumers")
        if preserveNativeFlight then
            TA.diag = type(TA.diag) == "table" and TA.diag or {}
            TA.diag.consumerReleaseFlightsPreserved = (tonumber(TA.diag.consumerReleaseFlightsPreserved) or 0) + 1
            TA:TraceRequest("consumer_release_preserve_flight", TA.inFlight or TA.timedOutFlight, "consumer=0")
        else
            TA.timedOutFlight = nil
            TA:CancelRequestTimeout()
            TA:CancelTimeoutDrain()
        end
    end
    return true
end

function Trade:Enable()
    self.enabled = true
    TraceInit("enable", "feature enabled")
    return true
end

function Trade:Disable(reason)
    local ok, err = self.Demand:Clear(reason or "trade_disable")
    if ok ~= true then return false, err end
    if S.Events then S.Events:UnsubscribeOwner(self) end
    self:ReleaseNativeRatioSubscription(reason or "trade_disable")
    self:CancelQuoteBatch(reason or "disabled")
    self.enabled = false
    TA.inFlight, TA.pendingRoute, TA.pendingRetryCount, TA.timedOutFlight = nil, nil, nil, nil
    TA:CancelRequestTimeout(); TA:CancelTimeoutDrain(); TA:CancelDeferredRequest(); TA:CancelAutoRefresh(); TA:CancelEquipmentRefresh(); TA:StopCargoScan("feature_disabled"); TA:CancelLiveIdentities()
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
    projection.quoteBatch=self:GetQuoteBatch()
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
    self:CancelQuoteBatch("view_mode_changed")
    if mode == "cargo" then
        TA:CancelAutoRefresh()
        TA:RebuildDisplayRows("trade_view_cargo")
        if self.enabled and (tonumber(self.consumerCount) or 0) > 0 then return TA:StartCargoScan("view_mode") end
        return true
    end
    TA:StopCargoScan("view_changed")
    TA:RebuildDisplayRows("trade_view_" .. mode)
    if self.enabled and (tonumber(self.consumerCount) or 0) > 0 and Number(self.State.fromZone) ~= nil and Number(self.State.toZone) ~= nil then
        if not TA:HasRawRowsForRoute(self.State.fromZone, self.State.toZone) then return TA:Request(true, "route_change") end
        TA:ScheduleNextAutoRefresh()
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
    if value then TA:ScheduleNextAutoRefresh() else TA:CancelAutoRefresh() end
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
-- 维护（trade-budget-1）：报价批次由Trade独立持有，UI共享投影而不各建队列。
-- 默认每次最多4种材料/每种仅查提示品质；完整品质+名称搜索只能由explicit full命令触发。
-- 取消/路线变化递增generation，迟到回调不能重建另一条路线。原配置schema不变，批次仅会话状态。
local QUOTE_REFRESH_TASK="v3_trade_quote_refresh"
Trade.quoteGeneration=0
Trade.quoteBatch={active=false,total=0,completed=0,ready=0,failed=0,mode="basic"}
function Trade:GetQuoteBatch() return Copy(self.quoteBatch) end
function Trade:CancelQuoteBatch(reason)
    self.quoteGeneration=self.quoteGeneration+1
    local queue=S.Services and S.Services.PriceQuoteQueueV3
    if queue and type(queue.CancelRequester)=="function" then queue:CancelRequester("life_trade") end
    if S.Scheduler then S.Scheduler:RemoveTask(QUOTE_REFRESH_TASK) end
    self.quoteRefreshPending=false;self.quoteMaterialKeys={}
    self.quoteBatch.active=false;self.quoteBatch.reason=tostring(reason or "cancelled")
    TA.revision=TA.revision+1;PublishFeatureUpdate(self,TA.revision,"quote_cancelled")
    return true
end
function Trade:_QueueQuoteRefresh(materialKey,generation)
    self.quoteMaterialKeys=self.quoteMaterialKeys or {};self.quoteMaterialKeys[materialKey]=true
    if self.quoteRefreshPending then return true end
    self.quoteRefreshPending=true
    local function Apply()
        if generation~=Trade.quoteGeneration then return true end
        Trade.quoteRefreshPending=false;local keys=Trade.quoteMaterialKeys;Trade.quoteMaterialKeys={}
        if not Trade.enabled or Trade.consumerCount<=0 then return true end
        -- 多完成事件合并为一次现有成本投影刷新，不再次发出询价/货率请求。
        local begin=type(S.NowMs)=="function" and S.NowMs() or 0
        TA:RefreshQuotedMaterial(keys)
        Trade.quoteBatch.refreshMs=math.max(0,(type(S.NowMs)=="function" and S.NowMs() or begin)-begin)
        return true
    end
    if S.Scheduler and type(S.Scheduler.AddOneShot)=="function" then
        local ok=S.Scheduler:AddOneShot(QUOTE_REFRESH_TASK,100,Apply,self,"P3",1)
        if ok==true then return true end
    end
    return Apply()
end
local function ResolveTradeQuoteIdentity(material)
    local materialKey, itemType, itemGrade, gradeOffset
    if type(material) == "table" then
        materialKey = tostring(material.materialKey or material.internalKey or "")
        itemType, itemGrade = tonumber(material.itemType), tonumber(material.itemGrade)
    else
        materialKey = tostring(material or "")
    end
    local metaTable = S.Data and S.Data.TradeMaterialAuctionMeta
    local meta = type(metaTable) == "table" and metaTable[materialKey] or nil
    if type(meta) == "table" then
        itemType = itemType or tonumber(meta.itemType)
        itemGrade = itemGrade or tonumber(meta.itemGrade)
        gradeOffset = tonumber(meta.gradeOffset)
    end
    if itemType == nil or itemType <= 0 then return materialKey, nil, nil end
    itemType = math.floor(itemType)
    itemGrade = itemGrade or (gradeOffset ~= nil and gradeOffset + 1) or 1
    itemGrade = math.max(0, math.min(20, math.floor(tonumber(itemGrade) or 1)))
    if materialKey == "" then materialKey = "item:" .. tostring(itemType) end
    return materialKey, itemType, itemGrade
end

function Trade:QuoteMaterial(material,mode,batch)
    -- 维护（2026-09-23，trade-live-material-quote-1）：显式询价的 Authority 是投影材料的 itemType/itemGrade，
    -- 不是静态 English materialKey。旧实现只查 TradeMaterialAuctionMeta，导致 X2Craft 实时解析出来但尚未进入
    -- 静态材料表的新材料永远显示“可拍卖”却无法点击询价。这里保留 string key 旧 Command 兼容，同时允许
    -- 传入 detached material row；Native 询价仍全部由 PriceQuoteQueueV3 串行/冷却管理，不新增并发。
    if not self.enabled then return false,"跑商功能已关闭" end
    local materialKey,itemType,itemGrade=ResolveTradeQuoteIdentity(material)
    if not itemType then return false,"该材料没有已验证的拍卖行身份，无法询价" end
    local queue=S.Services and S.Services.PriceQuoteQueueV3
    if not queue or type(queue.RequestQuote)~="function" then return false,"报价服务不可用" end
    local grades={itemGrade};local seen={[itemGrade]=true}
    if mode=="full" then
        for grade=0,6 do if not seen[grade] then grades[#grades+1]=grade;seen[grade]=true end end
    end
    local generation=self.quoteGeneration
    -- 维护（2026-09-24，trade-basic-quote-fallback-1）：RU 实机已经证明 GetLowestPrice 在大量常用材料上会
    -- “调用成功但全部返回 nil”，真正可工作的兼容链路是随后按本地化物品名走一次 AuctionQueryV3 名称搜索。
    -- 2026-09-23 UI 收敛后，主面板/悬浮窗都只调用 QuoteRowMaterials(row.key) 的 basic 模式；旧代码却仅在
    -- mode=="full" 时传 searchName，等于把当前唯一用户入口的名称兜底永久关闭，最终表现为“询价根本查不到”。
    -- searchName 只是给 PriceQuoteQueueV3 的失败兜底使用：稳定 itemType + itemGrade 仍是第一 Authority，普通询价
    -- 仍只探测一个品质档，不恢复旧版 0..6 批量探针；因此不会增加正常成功路径的 Native 调用，也不会绕过共享
    -- 串行/冷却队列。detached material row 优先携带当前投影已解析出的玩家可见名称，Localization 作为同源兜底。
    local projectedName=type(material)=="table" and (material.searchName or material.name) or nil
    local searchName=LocalizedTradeItemName(itemType,projectedName)
    return queue:RequestQuote("life_trade",itemType,itemGrade,function(result)
        if generation~=Trade.quoteGeneration or not Trade.enabled then return end
        if batch and Trade.quoteBatch==batch then
            batch.completed=batch.completed+1
            if result.status=="ready" then batch.ready=batch.ready+1 else batch.failed=batch.failed+1 end
            batch.active=batch.completed<batch.total
        end
        Trade:_QueueQuoteRefresh(materialKey,generation)
    end,grades,{searchName=searchName})
end
function Trade:_StartMaterialBatch(rows,mode,options)
    if not self.enabled then return false,"跑商功能已关闭" end
    options=type(options)=="table" and options or {}
    if self.quoteBatch.active then
        return true,"询价中 "..self.quoteBatch.completed.."/"..self.quoteBatch.total,0,0
    end
    local queue=S.Services and S.Services.PriceQuoteQueueV3
    if not queue then return false,"报价服务不可用" end
    -- 维护（2026-09-23，trade-row-quote-intent-1）：批量入口默认最多4项；明确的单行双击可以把预算提高到
    -- 当前行材料投影硬上限。两者共用同一 PriceQuoteQueueV3 requester，因此仍严格串行，不能从这里直接调用拍卖 API。
    local maxItems=math.max(1,math.min(TRADE_MATERIAL_MAX_ROWS,math.floor(tonumber(options.maxItems) or TRADE_DEFAULT_QUOTE_BATCH_MAX)))
    local now=type(S.NowMs)=="function" and S.NowMs() or 0
    local selected,seen,deferred={}, {}, 0
    for _,row in ipairs(rows or {}) do
        for _,m in ipairs(row.materialRows or {}) do
            local materialKey,id,grade=ResolveTradeQuoteIdentity(m)
            local key=id and (tostring(id)..":"..tostring(grade))
            local state=id and queue:GetQuoteStateByItemType(id,grade)
            local cooling=state and state.status=="failed" and now-(state.at or 0)>=0 and now-(state.at or 0)<queue.negativeTtlMs
            local missing=m.costStatus=="explicit_quote_required" or m.costStatus=="quote_failed" or m.costStatus=="quoted_reference"
            if key and not seen[key] and m.auctionable~=false and m.includeInCost~=false and (missing or mode=="full") then
                seen[key]=true
                if (cooling and mode~="full") or #selected>=maxItems then deferred=deferred+1
                else
                    -- 维护（trade-basic-quote-fallback-1）：批次队列必须携带 detached 的本地化显示名；否则
                    -- QuoteMaterial 只能依赖静态 Localization，实时 Craft 解析出来的新材料会再次失去名称搜索兜底。
                    -- 这里只复制短字符串事实，不保留 UI row/table 引用，避免跨 Feature 生命周期持有可变对象。
                    selected[#selected+1]={materialKey=materialKey,itemType=id,itemGrade=grade,searchName=m.name}
                end
            end
        end
    end
    if #selected==0 then return false,"没有可询价材料；已有有效报价、失败冷却中，或材料本身不可拍卖",0,deferred end
    self.quoteGeneration=self.quoteGeneration+1
    local batch={
        id=self.quoteGeneration,active=true,total=#selected,completed=0,ready=0,failed=0,mode=mode or "basic",deferred=deferred,
        scope=tostring(options.scope or "batch"),rowKey=options.rowKey,label=options.label,maxItems=maxItems,
    }
    self.quoteBatch=batch
    local affectedKeys={}
    for _,material in ipairs(selected) do
        if material.materialKey~=nil then affectedKeys[material.materialKey]=true end
        local ok,err=self:QuoteMaterial(material,mode,batch)
        if not ok then batch.completed=batch.completed+1;batch.failed=batch.failed+1;batch.error=tostring(err) end
    end
    batch.active=batch.completed<batch.total
    -- RequestQuote 会立刻把共享 read-model 标成 queued/inflight；马上重投影受影响行，让毛利列从“查询材料”
    -- 变成“询价中…”。只重建命中的材料行，不刷新货率，也不遍历/请求未选中的路线数据。
    if next(affectedKeys)~=nil then TA:RefreshQuotedMaterial(affectedKeys) end
    TA.revision=TA.revision+1;PublishFeatureUpdate(self,TA.revision,"quote_batch")
    return true,"本次查询 "..batch.total.." 项材料"..(deferred>0 and ("；另有 "..deferred.." 项处于冷却/预算外") or ""),batch.total,deferred
end
function Trade:QuotePendingMaterials(mode)
    return self:_StartMaterialBatch(TA.rows,mode,{maxItems=TRADE_DEFAULT_QUOTE_BATCH_MAX,scope="batch"})
end
function Trade:QuoteRowMaterials(rowKey,mode)
    local row=self:GetRow(rowKey);if not row then return false,"贸易品已不在当前路线结果中" end
    -- 双击另一行代表新的明确用户意图；旧的单行批次若仍在排队，直接取消而不是让用户等待一个已经不关心的货物。
    -- 同一行重复双击则只返回当前进度，避免取消后又重建同一 requester。
    if self.quoteBatch.active then
        if self.quoteBatch.scope=="row" and tostring(self.quoteBatch.rowKey or "")==tostring(rowKey or "") then
            return true,"正在查询该货物材料 "..tostring(self.quoteBatch.completed or 0).."/"..tostring(self.quoteBatch.total or 0)
        end
        self:CancelQuoteBatch("row_quote_superseded")
    end
    local ok,msg,total,deferred=self:_StartMaterialBatch({row},mode,{
        maxItems=TRADE_ROW_QUOTE_BATCH_MAX,scope="row",rowKey=rowKey,label=row.name,
    })
    if ok~=true and row.materialCostComplete==true and row.materialCostCopper~=nil then
        return true,"该货物材料价格已可用，毛利已更新",0,0
    end
    return ok,msg,total,deferred
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
                name = row.name, bidPrice = row.bidPrice, directPrice = row.directPrice,
            }
        end
        searchSummary = {
            status = search.status, keyword = search.keyword, count = search.count, error = search.error,
            requestedAt = search.requestedAt, completedAt = search.completedAt, candidates = candidates,
        }
    end
    return { batch = Copy(self.quoteBatch or {}), queue = queueSummary, fallbackSearch = searchSummary }
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
    CancelQuoteBatch = function(_,reason) return Trade:CancelQuoteBatch(reason) end,
    CycleFrom = function(_, delta) return Trade:CycleFrom(delta) end, CycleTo = function(_, delta) return Trade:CycleTo(delta) end,
    GetWidgetVisible = function() return Trade:GetWidgetVisible() end, SetWidgetVisible = function(_, value, reason) return Trade:SetWidgetVisible(value, reason) end,
    SetWidgetWindowState = function(_, value, reason) return Trade:SetWidgetWindowState(value, reason) end,
    MarkStoreDirty = function(_, delayMs, reason) return Trade:MarkStoreDirty(delayMs, reason) end }
local tradeDemand, tradeErr = Demand:Create({ id = "feature:" .. Trade.Id, owner = Trade, projectionOwner = Trade, projectionConsumersField = "consumers", projectionCountField = "consumerCount", reconcile = function(lease, before, after) return Trade:ReconcileDemand(lease, before, after) end })
if tradeDemand == nil then error(tradeErr) end
Trade.Demand = tradeDemand
local ok, err = Runtime:RegisterImplementation(Trade.Id, Trade); if ok ~= true then error(err) end

------------------------------------------------------------------------
-- Bonds / Resident board
------------------------------------------------------------------------
local Bonds = { Id = "life_bonds", storeId = "v3.life.bonds", enabled = false, storeLoaded = false,
    progressConsumerToken = "feature:life_bonds:quest_progress", progressConsumerHeld = false, progressSubscribed = false,
    locationSubscribed = false }
local BONDS_ZONE_REFRESH_TASK = "life_bonds_zone_refresh"
S.Features.Bonds = Bonds
Bonds.UpdateTopic = "v3.life.bonds.updated"
Bonds.State = { sortMode = "continent", continentOrder = "west_first", showCompleted = true, q20 = true, q60 = true, q100 = true, auroria = true, excludeSame = false, priority = "west", completionDateKey = nil, completedMainlandKeys = {}, dailyDateKey = nil, dailySnapshots = {}, widgetVisible = false, widgetWindow = nil }
-- 中文维护注释（2026-09-15，西/东大陆同日快照与排序语义）：
-- 问题原因：旧页面把“按大陆排序”“优先西/东”和“去重”挤在同一排，priority 还会隐式开启去重，
-- 用户切换排序时会看到另一大陆行被隐藏，从而误以为 Authority 只能读取一个大陆。Authority 实际已经
-- 按 server day 保存 west/east/auroria 三份快照，因此本次不新增第二数据源，只把“大陆展示顺序”提升为
-- 独立持久化偏好 continentOrder，并明确 duplicate priority 只有在合并模式开启时才参与。
-- Authority/数据流：ResidentBoard -> Bonds.Authority -> dailySnapshots[continent] -> detached Projection；
-- Presentation 只能调用 Commands，禁止直接读取 State。兼容边界：新增字段缺失时默认 west_first，旧 Store
-- schema/fingerprint 仍由 NormalizeBondState 兼容；不增加轮询，不跨大陆伪造远程读取。
-- 风险：未来若增加第四大陆/新阵营，必须同时扩展排序 rank、dailySnapshotStatus 和 UI 标签，不能复用 priority。
-- 中文维护注释（2026-09-24，债券 18.302 契约）：v3 表示多大陆缓存已具备 Native 板族识别、
-- 空快照拒绝、区域重探测以及按 board index 的同日增量合并；ResidentBoardFamily/AuroriaMaterial/DropdownPresentation 分开打契约，
-- 让 Foundation/Acceptance 能在用户只覆盖部分文件时 fail-fast，而不是运行到一半才出现“原大陆没数据/按钮旧版”。
Bonds.MultiContinentSnapshotContractVersion = 3
Bonds.ResidentBoardFamilyContractVersion = 1
Bonds.AuroriaMaterialContractVersion = 1
Bonds.DropdownPresentationContractVersion = 2
InstallLifeWidgetContract(Bonds, { defaultWidth = 500, defaultHeight = 330, minWidth = 280, minHeight = 150, defaultOverallOpacity = 0.94, defaultBackgroundOpacity = 1.0, defaultTextOpacity = 1.0 })
Bonds.Authority = { version = 3, revision = 0, rows = {}, status = "idle", error = nil, boardScope = "unknown", faction = nil }
local BA = Bonds.Authority
-- 中文维护注释（2026-09-24，债券 ItemType 反向索引）：大陆 4 种 + 原大陆 6 种材料在脚本加载时
-- 建一次只读反向表。InventorySnapshotV3 刷新会遍历背包物品，如果每个 item 再 pairs 扫 10 个常量键，
-- 会把一个 O(n) 背包聚合放大成 O(n*10)。反向索引保持同一 GameIds Authority，只消除热路径重复匹配。
local BOND_MATERIAL_KEY_BY_ITEM_TYPE = {}
for key, value in pairs(S.Constants and S.Constants.BondMaterialItemTypes or {}) do
    if tonumber(value) ~= nil then BOND_MATERIAL_KEY_BY_ITEM_TYPE[tonumber(value)] = key end
end
for key, value in pairs(S.Constants and S.Constants.AuroriaBondMaterialItemTypes or {}) do
    if tonumber(value) ~= nil then BOND_MATERIAL_KEY_BY_ITEM_TYPE[tonumber(value)] = key end
end
local function BondMaterialKey(itemType)
    return BOND_MATERIAL_KEY_BY_ITEM_TYPE[tonumber(itemType)]
end
local function BondItemType(item) return item.itemType or item.itemTypeId or item.typeId or item.item_type end
local function BondItemCount(item) return Number(item.stackCount or item.stack or item.count or item.itemCount or item.amount or item.stackSize or item.quantity) end
local QUEST_STATUS_TEXT = { COMPLETED = "已完成", READY_TO_TURN_IN = "可交付", IN_PROGRESS = "进行中", NOT_ACCEPTED = "未接", UNKNOWN = "待确认" }
local QUEST_STATUS_TONE = { COMPLETED = "green", READY_TO_TURN_IN = "orange", IN_PROGRESS = "yellow", NOT_ACCEPTED = "muted", UNKNOWN = "muted" }
local AURORIA_BOND_LABEL = {
    prince_purse = "王子的钱袋", prince_crate = "王子的箱子",
    queen_purse = "女王的钱袋", queen_crate = "女王的箱子",
    ancestor_purse = "祖先的钱袋", ancestor_crate = "祖先的箱子",
}
local function BondTextContainsAny(text, patterns)
    text = tostring(text or "")
    local lower = string.lower(text)
    for _, pattern in ipairs(patterns or {}) do
        if string.find(text, pattern, 1, true) or string.find(lower, string.lower(pattern), 1, true) then return true end
    end
    return false
end
local function ResolveAuroriaBondToken(boardIndex, text, quantity)
    -- 中文维护注释（2026-09-24，原大陆任务解析 / 18.302 复核）：公开 ArcheRage residentboard
    -- 插件确认板位 5/6/7 分别代表 Prince/Queen/Ancestor。板位只决定家族，文本优先判断钱袋/箱子；
    -- 若本地化关键词缺失，不能只拿“文本第一个数字”推断，因为区域名/阶段文本可能在需求量之前出现其它数字。
    -- 这里扫描整行所有数字，并且只有所有命中证据唯一指向 purse 或 crate 时才降级推断；30/25/20 等
    -- 两类都合法的歧义数量仍保持 UNKNOWN。Authority 不猜任务身份，避免把完成状态锁到错误 QuestId。
    local family = ({ [5] = "prince", [6] = "queen", [7] = "ancestor" })[tonumber(boardIndex)]
    if family == nil then return nil end
    local purse = BondTextContainsAny(text, { "钱袋", "袋", "coinpurse", "purse", "кош", "Кош", "меш", "Меш", "котом", "Котом", "金闪闪" })
    local crate = BondTextContainsAny(text, { "箱", "盒", "匣", "杂货箱", "杂物箱", "crate", "box", "сунд", "Сунд", "ящ", "Ящ" })
    if purse and not crate then return family .. "_purse" end
    if crate and not purse then return family .. "_crate" end

    local maps = S.Constants and S.Constants.AuroriaBondQuestByTokenQuantity or {}
    local purseMap, crateMap = maps[family .. "_purse"], maps[family .. "_crate"]
    local observed = {}
    local q = tonumber(quantity)
    if q ~= nil then observed[q] = true end
    for number in string.gmatch(tostring(text or ""), "(%d+)") do
        q = tonumber(number)
        if q ~= nil then observed[q] = true end
    end
    local purseMatch, crateMatch = false, false
    for amount in pairs(observed) do
        purseMatch = purseMatch or (type(purseMap) == "table" and purseMap[amount] ~= nil)
        crateMatch = crateMatch or (type(crateMap) == "table" and crateMap[amount] ~= nil)
    end
    if purseMatch ~= crateMatch then return purseMatch and (family .. "_purse") or (family .. "_crate") end
    return nil
end
local function BondQuestEvidence(materialKey, text, boardIndex)
    local function quantityFromMap(map)
        if type(map) ~= "table" then return nil end
        for number in string.gmatch(tostring(text or ""), "(%d+)") do
            local quantity = tonumber(number)
            if quantity ~= nil and map[quantity] ~= nil then return quantity end
        end
        return nil
    end
    local materialMap = S.Constants and S.Constants.BondQuestByMaterialQuantity
        and S.Constants.BondQuestByMaterialQuantity[materialKey]
    if type(materialMap) == "table" then
        local quantity = quantityFromMap(materialMap)
        return quantity and materialMap[quantity] or nil, quantity, nil
    end

    local rawQuantity = Number(string.match(tostring(text or ""), "(%d+)"))
    local token = ResolveAuroriaBondToken(boardIndex, text, rawQuantity)
    local map = token and S.Constants and S.Constants.AuroriaBondQuestByTokenQuantity and S.Constants.AuroriaBondQuestByTokenQuantity[token]
    local quantity = quantityFromMap(map)
    if quantity ~= nil then return map[quantity], quantity, token end
    return nil, rawQuantity, token
end
-- BondDateCache removed 2026-09-02: S.State 永远 nil (replicatedsuite.lua 显式置 nil
-- + foundation_gate 断言), 整个函数返回 nil, 调用方 cache 逻辑不可达.
-- 大陆债券完成状态由 questStatus 直接决定, 无缓存层.
local function ReadBondResources()
    local totals = {}
    for key in pairs(S.Constants and S.Constants.BondMaterialItemTypes or {}) do totals[key] = 0 end
    for key in pairs(S.Constants and S.Constants.AuroriaBondMaterialItemTypes or {}) do totals[key] = 0 end
    local status = "unknown"
    -- 中文维护注释：优先复用 InventorySnapshotV3 统一背包只读快照（含 bagId 1/0 自动试探与数量提取），
    -- 避免各生活模块对物理背包槽位产生第二 Authority 或猜测不同 bagId。
    local snapshotService = S.Services and S.Services.InventorySnapshotV3
    if type(snapshotService) == "table" and type(snapshotService.BuildSnapshot) == "function" then
        local snapshot, snapErr = snapshotService:BuildSnapshot("bag")
        if snapshot ~= nil and type(snapshot.rows) == "table" then
            for _, row in ipairs(snapshot.rows) do
                local key = BondMaterialKey(row.itemType)
                if key ~= nil then
                    totals[key] = totals[key] + (tonumber(row.stack) or 1)
                end
            end
            local failed = (tonumber(snapshot.readErrors) or 0) > 0 or (snapshot.unknown and snapshot.unknown > 0)
            if #snapshot.rows == 0 then status = "unknown" elseif failed then status = "partial" else status = "ready" end
            return totals, status
        end
    end

    if S.Api == nil or S.Api:IsCapabilityAllowed("X2Bag:GetBagItemInfo") ~= true or S.Api:IsCapabilityAllowed("X2Bag:Capacity") ~= true then return totals, status end
    local capacityOk, capacity = Call("X2Bag:Capacity", BagApi, "Capacity")
    capacity = Number(capacity)
    if capacityOk ~= true or not capacity or capacity < 0 then return totals, status end
    local maxSlot = math.min(240, math.floor(capacity))
    local readCount, failed = 0, false
    -- 中文维护注释：物理槽位降级读取依循 GearV3 规范：bagId=1 优先，无有效物品时降级 bagId=0。
    local bagIds = { 1, 0 }
    for _, bagId in ipairs(bagIds) do
        local currentReadCount, currentObservedItems = 0, 0
        local currentTotals = {}
        for key in pairs(totals) do currentTotals[key] = 0 end
        local currentFailed = false
        for slot = 1, maxSlot do
            local ok, item = Call("X2Bag:GetBagItemInfo", BagApi, "GetBagItemInfo", bagId, slot)
            if ok ~= true then
                currentFailed = true
            else
                currentReadCount = currentReadCount + 1
                if type(item) == "table" then
                    -- 中文维护注释（bond-bag-fallback-1）：API 调用成功只证明槽位可读，nil/空表不能证明
                    -- bagId=1 是当前物理背包。只有看到至少一个真实物品后才锁定该 bagId；否则继续试 bagId=0。
                    -- 这样不会把“100 个空槽位成功返回 nil”误判为有效背包而把真实材料统计成 0。
                    if next(item) ~= nil then currentObservedItems = currentObservedItems + 1 end
                    local itemType, count = BondItemType(item), BondItemCount(item)
                    local key = BondMaterialKey(itemType)
                    if key ~= nil then
                        if count ~= nil then currentTotals[key] = currentTotals[key] + count else currentFailed = true end
                    elseif next(item) ~= nil and itemType == nil then
                        currentFailed = true
                    end
                elseif item ~= nil then
                    currentObservedItems = currentObservedItems + 1
                    currentFailed = true
                end
            end
        end
        if currentObservedItems > 0 then
            totals = currentTotals
            readCount = currentReadCount
            failed = currentFailed
            break
        end
    end
    if readCount == 0 then status = "unknown" elseif failed then status = "partial" else status = "ready" end
    return totals, status
end
local function BondRowText(value)
    if type(value) == "table" then return Text(value.text or value.name or value.title or value[1]) end
    return Text(value)
end
local BOND_BOARD_NAMES = {
    [1] = "布料", [2] = "皮革", [3] = "木材", [4] = "铁锭",
    [5] = "王子的物品", [6] = "女王的物品", [7] = "祖先的物品",
}
local function NormalizeResidentBoardContents(value)
    if type(value) == "string" or type(value) == "number" then
        local text = Text(value)
        return text ~= "" and { value } or {}
    end
    if type(value) ~= "table" then return {} end

    local source = value.contents
    if source == nil then source = value.content or value.rows or value.items end
    if source == nil and value[1] ~= nil then source = value end
    if type(source) == "string" or type(source) == "number" then
        local text = Text(source)
        return text ~= "" and { source } or {}
    end
    if type(source) ~= "table" then return {} end

    local result = {}
    for index, entry in ipairs(source) do
        if BondRowText(entry) ~= "" then result[#result + 1] = entry end
    end
    -- Some RU builds may expose sparse numeric indices. Preserve deterministic
    -- numeric order without treating metadata keys as resident-board rows.
    if #result == 0 then
        local numericKeys = {}
        for key in pairs(source) do
            local n = tonumber(key)
            if n ~= nil and n >= 1 and math.floor(n) == n then numericKeys[#numericKeys + 1] = n end
        end
        table.sort(numericKeys)
        for _, key in ipairs(numericKeys) do
            local entry = source[key]
            if BondRowText(entry) ~= "" then result[#result + 1] = entry end
        end
    end
    return result
end
local function BondContinent(index) if index >= 5 then return "原大陆" else return "西/东大陆" end end
local BOND_CONTINENT_LABEL = { west = "西大陆", east = "东大陆", auroria = "原大陆" }
local BOND_WEST_ZONE = { [1]=true,[2]=true,[3]=true,[5]=true,[6]=true,[8]=true,[18]=true,[19]=true,[20]=true,[22]=true,[26]=true,[27]=true,[93]=true }
local BOND_EAST_ZONE = { [4]=true,[7]=true,[9]=true,[10]=true,[11]=true,[12]=true,[13]=true,[14]=true,[15]=true,[16]=true,[17]=true,[21]=true,[23]=true,[24]=true,[25]=true,[99]=true }
local BOND_AURORIA_ZONE = { [54]=true,[56]=true,[57]=true,[102]=true,[103]=true }
local BOND_SNAPSHOT_MAX_LINES = 4
local BOND_SNAPSHOT_MAX_TEXT = 160

local function BoundedBondSnapshotText(value)
    local text = Text(value, "")
    if #text <= BOND_SNAPSHOT_MAX_TEXT then return text end
    local cut = BOND_SNAPSHOT_MAX_TEXT
    -- Persist only a valid UTF-8 prefix. Russian/Chinese board text is
    -- multi-byte; raw string.sub at the byte budget can split a codepoint and
    -- corrupt the restored daily snapshot.
    while cut > 0 do
        local byte = string.byte(text, cut)
        if byte ~= nil and byte >= 0x80 and byte < 0xC0 then cut = cut - 1 else break end
    end
    if cut <= 0 then return "" end
    local lead = string.byte(text, cut) or 0
    local width = lead >= 0xF0 and 4 or (lead >= 0xE0 and 3 or (lead >= 0xC0 and 2 or 1))
    if cut + width - 1 > BOND_SNAPSHOT_MAX_TEXT then cut = cut - 1 else cut = BOND_SNAPSHOT_MAX_TEXT end
    return string.sub(text, 1, math.max(0, cut))
end

local function CurrentBondContinentKey()
    local ok, zoneId = Call("X2Unit:GetCurrentZoneGroup", UnitApi, "GetCurrentZoneGroup")
    zoneId = ok == true and math.floor(Number(zoneId) or 0) or 0
    if BOND_WEST_ZONE[zoneId] then return "west" end
    if BOND_EAST_ZONE[zoneId] then return "east" end
    if BOND_AURORIA_ZONE[zoneId] then return "auroria" end
    return nil
end

local function BondBoardLineCount(boards, index)
    local board = type(boards) == "table" and boards[index] or nil
    return #(type(board) == "table" and type(board.contents) == "table" and board.contents or {})
end

local function DetectResidentBoardFamily(boards)
    -- 中文维护注释（2026-09-24，ResidentBoard 家族识别）：Strawberry-devs 的公开 ArcheRage
    -- residentboard 插件使用“3/4 板同时非空 => 主大陆；5/6 任一非空 => 原大陆”的真实客户端行为。
    -- 旧 Bonds 反过来先相信静态 zoneGroup 表，导致未收录的原大陆区域在已经缓存西/东后完全不再调用
    -- GetResidentBoardContent，甚至可能把 5/6 的原大陆内容误作为西/东的一张空快照保存。这里把 Native
    -- ResidentBoard 内容提升为“当前板族”的 Authority，zoneGroup 只负责主大陆西/东分边，不再决定原大陆。
    local mainlandReady = BondBoardLineCount(boards, 3) > 0 and BondBoardLineCount(boards, 4) > 0
    if mainlandReady then return "mainland", "boards_3_4" end
    local auroriaReady = BondBoardLineCount(boards, 5) > 0 or BondBoardLineCount(boards, 6) > 0
    if auroriaReady then return "auroria", "boards_5_6" end
    return nil, "insufficient_board_evidence"
end

local function BondFactionContinentHint(boards)
    -- zoneGroup 缺失时仅把 faction 当成主大陆的最后辅助提示；未知/新本地化必须返回 nil，禁止猜测。
    local faction = ""
    for index = 1, 7 do
        local raw = type(boards[index]) == "table" and boards[index].raw or nil
        local value = type(raw) == "table" and Text(raw.faction, "") or ""
        if value ~= "" then faction = value; break end
    end
    local lower = string.lower(faction)
    if string.find(lower, "nuia", 1, true) or string.find(lower, "nui", 1, true)
        or string.find(faction, "нуи", 1, true) or string.find(faction, "Нуи", 1, true)
        or string.find(faction, "西", 1, true) then return "west", faction end
    if string.find(lower, "haranya", 1, true) or string.find(lower, "harani", 1, true)
        or string.find(faction, "хар", 1, true) or string.find(faction, "Хар", 1, true)
        or string.find(faction, "东", 1, true) then return "east", faction end
    return nil, faction
end

local function ResolveLiveBondScope(boards, zoneHint)
    local family, evidence = DetectResidentBoardFamily(boards)
    if family == "auroria" then return "auroria", family, evidence end
    if family == "mainland" then
        if zoneHint == "west" or zoneHint == "east" then return zoneHint, family, evidence .. "+zone" end
        local factionHint = BondFactionContinentHint(boards)
        if factionHint ~= nil then return factionHint, family, evidence .. "+faction" end
        return nil, family, evidence .. "+mainland_side_unknown"
    end
    return nil, nil, evidence
end

local function BondSnapshotLineCount(snapshot)
    local count = 0
    for _, board in ipairs(type(snapshot) == "table" and type(snapshot.boards) == "table" and snapshot.boards or {}) do
        count = count + #(type(board.lines) == "table" and board.lines or {})
    end
    return count
end

local function NormalizeBondSnapshot(value, continentKey)
    if type(value) ~= "table" then return nil end
    if continentKey ~= "west" and continentKey ~= "east" and continentKey ~= "auroria" then return nil end
    local out = { continentKey = continentKey, faction = Text(value.faction, ""), boards = {} }
    local count = 0
    for _, rawBoard in ipairs(type(value.boards) == "table" and value.boards or {}) do
        if count >= 7 then break end
        local board = type(rawBoard) == "table" and rawBoard or {}
        local index = math.floor(Number(board.index or board.board) or 0)
        if index >= 1 and index <= 7 then
            local lines = {}
            for _, rawLine in ipairs(type(board.lines) == "table" and board.lines or {}) do
                if #lines >= BOND_SNAPSHOT_MAX_LINES then break end
                local line = BoundedBondSnapshotText(rawLine)
                if line ~= "" then
                    lines[#lines + 1] = line
                end
            end
            out.boards[#out.boards + 1] = { index = index, lines = lines }
            count = count + 1
        end
    end
    -- 中文维护注释（2026-09-24，空快照污染修复）：旧 Normalize 只要存在 1..7 的 board 外壳就
    -- 接受快照，即使所有 lines 都为空。若一次 ResidentBoard 临时读空却被错误大陆提示命中，Store 会把
    -- “空西大陆/空东大陆”保存整天，后续 Refresh 因 snapshot 已存在不再读取，表现就是“偶尔整天没数据”。
    -- 现在至少要求 1 条真实居民板文本；旧存档中的空壳会在 Normalize 时自然丢弃，无需清配置或迁移 schema。
    return BondSnapshotLineCount(out) > 0 and out or nil
end

local function CaptureBondSnapshot(continentKey, boards)
    if continentKey == nil or type(boards) ~= "table" then return nil end
    local firstIndex, lastIndex = 1, 4
    if continentKey == "auroria" then firstIndex, lastIndex = 5, 7 end
    local snapshot = { continentKey = continentKey, faction = "", boards = {} }
    for index = firstIndex, lastIndex do
        local board = type(boards[index]) == "table" and boards[index] or {}
        if snapshot.faction == "" and type(board.raw) == "table" and board.raw.faction ~= nil then snapshot.faction = Text(board.raw.faction, "") end
        local lines = {}
        for _, entry in ipairs(type(board.contents) == "table" and board.contents or {}) do
            if #lines >= BOND_SNAPSHOT_MAX_LINES then break end
            local line = BoundedBondSnapshotText(BondRowText(entry))
            if line ~= "" then
                lines[#lines + 1] = line
            end
        end
        snapshot.boards[#snapshot.boards + 1] = { index = index, lines = lines }
    end
    return NormalizeBondSnapshot(snapshot, continentKey)
end


-- 中文维护注释（2026-09-24，18.302 每板增量合并）：dailySnapshots 的 Authority 粒度是“服务器日 + 大陆”，
-- 但一次 Native ResidentBoard 读取只代表玩家当前可见板内容。18.301 把整个 auroria 当成单个原子快照，
-- 导致已经缓存 Prince 后进入 Queen/Ancestor 区域时，zone-boundary 探测虽然成功却因 previous 已存在而拒绝
-- 新内容；手动刷新又只按总行数比较，可能同样丢失另一组合法板数据。这里改为按 board index 合并，并对
-- 每个板的文本做稳定去重。旧行先保留，新探测只追加尚未记录的真实行；空读绝不删除已有行。主大陆也
-- 复用同一规则，从而抵抗局部 Native 空读。每天日期 rollover 仍由上层清空，因此不会跨天积累陈旧事实。
local function MergeBondSnapshot(previous, captured, continentKey)
    previous = NormalizeBondSnapshot(previous, continentKey)
    captured = NormalizeBondSnapshot(captured, continentKey)
    if previous == nil then
        return captured, captured ~= nil, BondSnapshotLineCount(captured)
    end
    if captured == nil then
        return previous, false, 0
    end

    local firstIndex, lastIndex = 1, 4
    if continentKey == "auroria" then firstIndex, lastIndex = 5, 7 end
    local previousByIndex, capturedByIndex = {}, {}
    for _, board in ipairs(previous.boards or {}) do previousByIndex[tonumber(board.index)] = board end
    for _, board in ipairs(captured.boards or {}) do capturedByIndex[tonumber(board.index)] = board end

    local merged = {
        continentKey = continentKey,
        faction = Text(captured.faction, "") ~= "" and Text(captured.faction, "") or Text(previous.faction, ""),
        boards = {},
    }
    local changed, addedLines = false, 0
    if merged.faction ~= Text(previous.faction, "") then changed = true end
    for index = firstIndex, lastIndex do
        local lines, seen = {}, {}
        local function append(source, isNewProbe)
            for _, rawLine in ipairs(type(source) == "table" and type(source.lines) == "table" and source.lines or {}) do
                if #lines >= BOND_SNAPSHOT_MAX_LINES then break end
                local line = BoundedBondSnapshotText(rawLine)
                if line ~= "" and seen[line] ~= true then
                    seen[line] = true
                    lines[#lines + 1] = line
                    if isNewProbe then changed, addedLines = true, addedLines + 1 end
                end
            end
        end
        append(previousByIndex[index], false)
        append(capturedByIndex[index], true)
        merged.boards[#merged.boards + 1] = { index = index, lines = lines }
    end
    return NormalizeBondSnapshot(merged, continentKey) or previous, changed, addedLines
end

local function NormalizeBondWidgetWindow(value)
    if type(value) ~= "table" then return nil end
    local floating = S.RSUI and S.RSUI.FloatingSurface or nil
    if type(floating) == "table" and type(floating.NormalizeState) == "function" then
        return floating:NormalizeState(value, {
            defaultWidth = 430, defaultHeight = 300, minWidth = 180, minHeight = 100,
            defaultOverallOpacity = 0.94, defaultBackgroundOpacity = 1.0, defaultTextOpacity = 1.0,
        })
    end
    return Copy(value)
end

local function NormalizeBondState(value)
    value = type(value) == "table" and value or {}
    local completed = {}
    local completedCount = 0
    for key, enabled in pairs(type(value.completedMainlandKeys) == "table" and value.completedMainlandKeys or {}) do
        key = tostring(key or "")
        if enabled == true and key ~= "" and #key <= 64 and completedCount < 64 then
            completed[key] = true
            completedCount = completedCount + 1
        end
    end
    local dateKey = tostring(value.completionDateKey or "")
    if not string.match(dateKey, "^%d%d%d%d%-%d%d%-%d%d$") then dateKey = nil end
    local dailyDateKey = tostring(value.dailyDateKey or "")
    if not string.match(dailyDateKey, "^%d%d%d%d%-%d%d%-%d%d$") then dailyDateKey = nil end
    local snapshots = {}
    for _, continentKey in ipairs({ "west", "east", "auroria" }) do
        local snap = NormalizeBondSnapshot(type(value.dailySnapshots) == "table" and value.dailySnapshots[continentKey] or nil, continentKey)
        if snap ~= nil then snapshots[continentKey] = snap end
    end
    -- 中文维护注释（2026-09-24，排序兼容）：18.303 新增 material 排序，但不新增 Store 字段，避免
    -- schema=1 的历史 envelope 再次发生 canonical 漂移。已有 continent/quantity 值保持原样；只有用户
    -- 新选择“按材料”后才会持久化 material。旧版本回退时 material 会安全归一为 continent，不破坏快照。
    local sortMode = value.sortMode == "quantity" and "quantity" or (value.sortMode == "material" and "material" or "continent")
    return { sortMode = sortMode,
        continentOrder = value.continentOrder == "east_first" and "east_first" or "west_first",
        showCompleted = value.showCompleted ~= false,
        q20 = value.q20 ~= false, q60 = value.q60 ~= false, q100 = value.q100 ~= false, auroria = value.auroria ~= false,
        excludeSame = value.excludeSame == true, priority = value.priority == "east" and "east" or "west",
        completionDateKey = dateKey, completedMainlandKeys = completed,
        dailyDateKey = dailyDateKey, dailySnapshots = snapshots,
        widgetVisible = value.widgetVisible == true,
        -- widgetWindow is the only passthrough field left in this Domain and it
        -- was the top fingerprint-drift candidate (arbitrary keys survive the
        -- Copy; RU serialization then reorders/drops them). Routing it through
        -- the shared FloatingSurface normalizer gives it a fixed shape like
        -- every other field, which both stabilizes the canonical fingerprint
        -- and repairs legacy windows saved with missing keys.
        widgetWindow = NormalizeBondWidgetWindow(value.widgetWindow) }
end
-- 中文维护注释（2026-09-15，债券 historical canonical 修复）：上一版在 schema=1 的
-- NormalizeBondState 中新增 continentOrder，导致已经合法盖章的旧存档（字段尚不存在）在下一次
-- Fresh Reload 被当前 canonical 自动补成 west_first，从而出现 fingerprint_mismatch。这里由 Bonds Store
-- 自己声明唯一可证明的历史形状：CURRENT canonical 去掉新增字段。候选没有信任权，仍必须重新计算并
-- 精确命中磁盘已经保存的 stampedFingerprint；未知 Hash、已有 continentOrder 的 payload、非 schema1
-- 都继续 fail-closed。恢复成功后第二返回值使用当前 NormalizeBondState，Core 会按当前 canonical 立即重盖章。
-- 该函数只走 Persistence mismatch 冷路径，不进入 Refresh/Tick，也不读取居民板或背包。
local function RebuildBondCanonicalForIntegrity(decoded, stampedFingerprint, currentCanonical, rawEnvelope)
    if type(decoded) ~= "table" or type(currentCanonical) ~= "table" then return nil, nil end
    if decoded.continentOrder ~= nil then return nil, nil end
    local meta = type(rawEnvelope) == "table" and rawEnvelope.__rsmeta or nil
    if type(meta) == "table" and tonumber(meta.schema) ~= 1 then return nil, nil end
    if currentCanonical.continentOrder ~= "west_first" then return nil, nil end

    local historical = Copy(currentCanonical)
    historical.continentOrder = nil
    local store = type(P.GetStore) == "function" and P:GetStore(Bonds.storeId) or nil
    if type(store) ~= "table" or type(P.FingerprintCanonicalValue) ~= "function" then return nil, nil end
    local candidateFingerprint = P:FingerprintCanonicalValue(store, historical)
    local matched = candidateFingerprint ~= nil and tostring(candidateFingerprint) == tostring(stampedFingerprint)
    store.lastHistoricalRecoveryProbe = "bonds_pre_continent_order/candidate=" .. tostring(candidateFingerprint or "nil")
        .. "/matched=" .. tostring(matched == true)
    if matched ~= true then return nil, nil end
    return historical, NormalizeBondState(decoded)
end

local function BondCompletionKey(materialKey, quantity, continentKey)
    if materialKey == nil or tonumber(quantity) == nil then return nil end
    -- 中文维护注释（2026-09-24，原大陆完成锁存）：QuestProgress 在任务交付后可能从 activeIndex 中移除，
    -- 如果只依赖当前 questStatus，原大陆已完成行会从“已完成”退回“待确认”。沿用现有每日完成 Store，
    -- 但给原大陆 key 加 auroria 前缀，避免和主大陆 material:quantity 的跨大陆共享语义碰撞；不改 schema。
    local suffix = tostring(materialKey) .. ":" .. tostring(math.floor(tonumber(quantity)))
    if continentKey == "auroria" then return "auroria:" .. suffix end
    return suffix
end
local function BondContinentKey(line)
    if type(line) ~= "table" then return nil end
    local value = line.continentKey or line.continent_key or line.continentId or line.continent_id or line.continent
    value = string.lower(tostring(value or ""))
    if value == "west" or value == "nuia" or value == "nuia_continent" or value == "西大陆" then return "west" end
    if value == "east" or value == "haranya" or value == "haranya_continent" or value == "东大陆" then return "east" end
    if value == "auroria" or value == "原大陆" then return "auroria" end
    return nil
end
local BOND_TEXT_MATERIAL = { [1] = "fabric", [2] = "leather", [3] = "lumber", [4] = "iron" }
function BA:Refresh(reason)
    local rows = {}
    reason = tostring(reason or "feature_refresh")
    local state = NormalizeBondState(Bonds.State)
    local completionDirty, snapshotDirty = false, false
    local serverDateKey = S.Utils and type(S.Utils.ServerDateKey) == "function" and tostring(S.Utils.ServerDateKey()) or "unknown"

    -- Daily resident-board contents are stable for the server day. Keep the
    -- restored cache during the cold unknown-date window; only a proven date
    -- rollover is allowed to invalidate snapshots/completion latches.
    if serverDateKey ~= "unknown" then
        if state.completionDateKey ~= serverDateKey then
            state.completionDateKey = serverDateKey
            state.completedMainlandKeys = {}
            completionDirty = true
        end
        if state.dailyDateKey ~= serverDateKey then
            state.dailyDateKey = serverDateKey
            state.dailySnapshots = {}
            snapshotDirty = true
        end
    end
    Bonds.State.completionDateKey = state.completionDateKey
    Bonds.State.completedMainlandKeys = Copy(state.completedMainlandKeys)
    Bonds.State.dailyDateKey = state.dailyDateKey
    Bonds.State.dailySnapshots = Copy(state.dailySnapshots)
    BA.duplicatePriorityUnresolved = nil

    -- 中文维护注释（2026-09-24，筛选/排序不重复扫包）：Dropdown 只改变 Presentation 过滤与排序，
    -- 不改变背包事实。旧实现每次 SetDisplayOrder/SetFilterMask/SetDuplicateMode 都会重新 BuildSnapshot("bag")，
    -- 大背包下属于不必要的 O(slots) 读取。Authority 现在只在 presentation 重建时复用最近一次 detached 资源
    -- 汇总；Demand 首开、手动刷新、QuestProgress/其他业务刷新仍重新读取背包，因此交任务/消耗材料后的数量不会
    -- 被长期缓存。缓存只含 10 个 materialKey->count 与状态，不持有 Native item/slot 引用，也不进入 Store。
    local resources, resourceStatus
    if reason == "presentation" and type(self.resourceTotals) == "table" then
        resources = Copy(self.resourceTotals)
        resourceStatus = self.resourceReadStatus or "unknown"
    else
        resources, resourceStatus = ReadBondResources()
        self.resourceTotals = Copy(resources)
        self.resourceReadStatus = resourceStatus
        self.resourceReads = (tonumber(self.resourceReads) or 0) + 1
    end
    local zoneHint = CurrentBondContinentKey()
    local currentKey = zoneHint
    local currentSnapshot = currentKey and state.dailySnapshots[currentKey] or nil
    local firstError = nil

    local lastReadable, lastContentCount = 0, 0
    local forceRead = reason == "page_manual" or reason == "widget_manual" or reason == "overview_manual" or reason == "manual"
    -- 中文维护注释（2026-09-24，首次 Consumer 探测）：Demand 0->1 是低频显式生命周期边界。即使静态
    -- zoneHint 命中且当天已有缓存，也做一次 bounded 1..7 Native 探测，以校正旧/新增 zoneGroup 映射、
    -- 识别当前位置实际是 mainland 还是 Auroria，并恢复“有缓存却当前位置新数据不显示”的场景。排序、
    -- 筛选、QuestProgress 等后续刷新仍不读 Native，所以不会形成轮询或 UI 操作放大。
    local demandProbe = reason == "demand_start" or reason == "initial"
    -- 中文维护注释（2026-09-24，区域切换一次性重探测）：页面保持打开跨区时 Demand 不会回到 0，
    -- 仅靠 demand_start 会漏掉“西/东缓存已存在 -> 进入未收录/误映射原大陆”的场景。区域事件经过
    -- 750ms 同名 one-shot 去抖后只触发一次 bounded 1..7 探测，让 ResidentBoard Native 内容重新裁决板族。
    -- 这是事件驱动的生命周期边界，不是 Tick/轮询；延迟也避免 ENTER_ANOTHER_ZONEGROUP 刚发出时板数据尚未就绪。
    local boundaryProbe = reason == "zone_changed" or reason == "entered_world"
    local shouldRead = forceRead or demandProbe or boundaryProbe
        or (zoneHint ~= nil and state.dailySnapshots[zoneHint] == nil)
        or (zoneHint == nil and state.dailySnapshots.west == nil and state.dailySnapshots.east == nil and state.dailySnapshots.auroria == nil)
    local probe = {
        reason = reason, zoneHint = zoneHint or "unknown", attempted = shouldRead == true,
        readable = 0, contentCount = 0, detectedFamily = "none", detectedScope = "none",
        evidence = "not_probed", captureAction = "cache_reuse", capturedLines = 0, boardCounts = {},
    }

    -- 中文维护注释（2026-09-24，ResidentBoard Authority/偶发空数据修复）：旧实现只有“当前静态 zoneGroup
    -- 已识别且该大陆未缓存”或“三大陆缓存完全为空”时才读 1..7。于是用户已缓存西/东后进入未收录的
    -- 原大陆 zoneGroup，会永远复用旧缓存而不探测 5/6；一次 Native 临时空返回还可能把空壳快照锁到
    -- 当天。现在页面/悬浮窗显式刷新可强制做一次 bounded 1..7 探测，首次 Demand 0->1 也固定探测一次；
    -- 排序/筛选/QuestProgress 只重建 Projection，不重复读 Native。板族由 Native 3/4 或 5/6 内容决定，
    -- 静态 zone 只负责 mainland 的西/东分边。强制刷新若拿到比已有快照更少的行不会覆盖好缓存。
    if shouldRead then
        local boards, readable, contentCount = {}, 0, 0
        for index = 1, 7 do
            local ok, value, err = Call("X2Resident:GetResidentBoardContent", ResidentApi, "GetResidentBoardContent", index)
            Bonds.boardReads = (tonumber(Bonds.boardReads) or 0) + 1
            if ok == true and value ~= nil then
                readable = readable + 1
                local contents = NormalizeResidentBoardContents(value)
                boards[index] = { raw = value, contents = contents }
                contentCount = contentCount + #contents
            else
                boards[index] = { raw = value, contents = {} }
                if err ~= nil then firstError = firstError or tostring(err) end
            end
            probe.boardCounts[index] = BondBoardLineCount(boards, index)
        end
        lastReadable, lastContentCount = readable, contentCount
        probe.readable, probe.contentCount = readable, contentCount

        local liveScope, family, evidence = ResolveLiveBondScope(boards, zoneHint)
        probe.detectedFamily = family or "none"
        probe.detectedScope = liveScope or "none"
        probe.evidence = evidence or "none"
        if liveScope ~= nil then
            currentKey = liveScope
            local captured = CaptureBondSnapshot(liveScope, boards)
            local capturedLines = BondSnapshotLineCount(captured)
            probe.capturedLines = capturedLines
            local previous = state.dailySnapshots[liveScope]
            local merged, changed, addedLines = MergeBondSnapshot(previous, captured, liveScope)
            probe.addedLines = tonumber(addedLines) or 0
            probe.mergedLines = BondSnapshotLineCount(merged)
            if merged ~= nil then
                currentSnapshot = merged
                if previous == nil or changed == true then
                    state.dailySnapshots[liveScope] = merged
                    Bonds.State.dailySnapshots[liveScope] = Copy(merged)
                    snapshotDirty = true
                end
                if previous == nil then
                    probe.captureAction = "captured_new"
                elseif captured == nil then
                    probe.captureAction = "kept_cache_empty_probe"
                elseif changed == true then
                    probe.captureAction = "merged_new_board_lines"
                else
                    probe.captureAction = "cache_unchanged"
                end
            else
                currentSnapshot = nil
                probe.captureAction = captured == nil and "no_snapshot_from_probe" or "capture_rejected"
            end
        else
            currentSnapshot = currentKey and state.dailySnapshots[currentKey] or nil
            probe.captureAction = contentCount > 0 and "scope_unresolved" or "empty_probe"
        end
    end

    -- 只有真实 Native 探测才覆盖 lastBoardProbe；排序/筛选等纯 Presentation 重算保留最近一次
    -- 可诊断证据，避免用户操作下拉框后再导出报告时只看到 not_probed。
    if shouldRead then BA.lastBoardProbe = probe end
    BA.lastRefreshReason = reason
    BA.boardScope = currentKey or "cached"
    BA.faction = currentSnapshot and currentSnapshot.faction or nil

    local progress = S.Services and S.Services.QuestProgressV3
    local activeIndex = progress and (progress.activeIndex or (type(progress.BuildActiveIndex) == "function" and select(1, progress:BuildActiveIndex()))) or nil
    local function AppendSnapshot(continentKey, snapshot)
        if type(snapshot) ~= "table" then return end
        for _, board in ipairs(snapshot.boards or {}) do
            local index = math.floor(Number(board.index) or 0)
            if index >= 1 and index <= 7 then
                for lineIndex, textValue in ipairs(type(board.lines) == "table" and board.lines or {}) do
                    textValue = Text(textValue, "")
                    local materialKey = BOND_TEXT_MATERIAL[index]
                    local quantity = Number(string.match(textValue, "(%d+)"))
                    -- 中文维护注释（2026-09-24，原大陆行身份闭环）：板 5/6/7 不再使用一个虚拟
                    -- auroria_token。ResidentBoard 文本 + 板位先解析成 prince/queen/ancestor purse/crate，
                    -- 再与共享 ItemType/QuestId 映射汇合。这样原大陆也能显示真实“持有/缺口/完成状态”；
                    -- 文本不足以区分钱袋与箱子时保持 unknown，绝不为了显示数量而猜错材料/任务。
                    local questId, mappedQuantity, auroriaToken = BondQuestEvidence(materialKey, textValue, index)
                    if index >= 5 then materialKey = auroriaToken end
                    quantity = mappedQuantity or quantity
                    local requiredCount = quantity
                    local haveCount = materialKey and resources[materialKey] or nil
                    local rowStatus = materialKey and resourceStatus or "unknown"
                    if resourceStatus == "unknown" or resourceStatus == "partial" then haveCount = nil end
                    local questStatus = "UNKNOWN"
                    if questId ~= nil and progress and type(progress.QuestState) == "function" then
                        questStatus = tostring(progress:QuestState(questId, activeIndex) or "UNKNOWN")
                    end
                    local completionKey = BondCompletionKey(materialKey, quantity, continentKey)
                    if questStatus == "COMPLETED" and completionKey ~= nil and state.completedMainlandKeys[completionKey] ~= true then
                        state.completedMainlandKeys[completionKey] = true
                        Bonds.State.completedMainlandKeys[completionKey] = true
                        completionDirty = true
                    end
                    local completed = questStatus == "COMPLETED" or (completionKey ~= nil and state.completedMainlandKeys[completionKey] == true)
                    local category = continentKey == "auroria" and "auroria"
                        or (quantity == 20 and "q20" or quantity == 60 and "q60" or quantity == 100 and "q100" or nil)
                    if (category == nil or state[category]) and (state.showCompleted or completed ~= true) then
                        rows[#rows + 1] = {
                            key = "daily:" .. tostring(continentKey) .. ":" .. tostring(index) .. ":" .. tostring(lineIndex),
                            board = index, name = AURORIA_BOND_LABEL[materialKey] or BOND_BOARD_NAMES[index] or ("分类" .. tostring(index)),
                            continent = BOND_CONTINENT_LABEL[continentKey] or tostring(continentKey), continentKey = continentKey,
                            text = textValue, quantity = quantity, materialKey = materialKey, auroriaToken = auroriaToken,
                            requiredCount = requiredCount, haveCount = haveCount,
                            shortage = requiredCount and haveCount and math.max(0, requiredCount - haveCount) or nil,
                            resourceStatus = rowStatus,
                            -- 中文维护注释：resourceStatus 保留机器态供诊断/兼容，玩家表格使用本地化文本，
                            -- 避免直接暴露 ready/partial/unknown 造成语义不清；这里仍由同一 Authority 生成。
                            resourceStatusText = rowStatus == "ready" and "可读取" or (rowStatus == "partial" and "部分" or "未知"),
                            resourceText = haveCount and tostring(haveCount) or "?",
                            shortageText = requiredCount and haveCount and tostring(math.max(0, requiredCount - haveCount)) or "?",
                            questId = questId, questStatus = questStatus, completed = completed,
                            statusText = completed and "已完成" or (QUEST_STATUS_TEXT[questStatus] or "待确认"),
                            tone = completed and "green" or (QUEST_STATUS_TONE[questStatus] or "muted"),
                        }
                    end
                end
            end
        end
    end

    for _, continentKey in ipairs({ "west", "east", "auroria" }) do
        AppendSnapshot(continentKey, state.dailySnapshots[continentKey])
    end

    -- Mainland daily identity is material + quantity. A Leather:20 completion
    -- is global across west/east, while Leather:20/60/100 remain three distinct
    -- tasks. De-duplication therefore uses that exact key and may also collapse
    -- accidental duplicates within one continent.
    if state.excludeSame then
        local groups = {}
        for _, row in ipairs(rows) do
            if row.continentKey == "west" or row.continentKey == "east" then
                local key = row.materialKey and row.quantity and (tostring(row.materialKey) .. ":" .. tostring(row.quantity)) or nil
                if key ~= nil then
                    groups[key] = groups[key] or { west = {}, east = {} }
                    groups[key][row.continentKey][#groups[key][row.continentKey] + 1] = row
                end
            end
        end
        local suppressed = {}
        local priority = state.priority == "east" and "east" or "west"
        local other = priority == "west" and "east" or "west"
        for _, group in pairs(groups) do
            local total = #group.west + #group.east
            if total > 1 then
                local winner = group[priority][1] or group[other][1]
                for _, row in ipairs(group.west) do if row ~= winner then suppressed[row] = true end end
                for _, row in ipairs(group.east) do if row ~= winner then suppressed[row] = true end end
            end
        end
        if next(suppressed) ~= nil then
            local filtered = {}
            for _, row in ipairs(rows) do if suppressed[row] ~= true then filtered[#filtered + 1] = row end end
            rows = filtered
        end
    end

    -- 中文维护注释（2026-09-24，债券三维排序）：18.302 的“按数量 · 西→东/东→西”只改变
    -- 数量主键、却仍用大陆方向作为第二语义，用户无法表达“数量少→多/多→少”，也没有按材料聚合，
    -- 因而实际体验会像“少了排序”。18.303 不增加新的 Store 字段：继续复用 sortMode + continentOrder
    -- 这两个稳定字段，其中 continent 模式解释 order 为大陆方向；quantity/material 模式解释同一二值为
    -- 正向/反向。Authority 只重排 detached rows，不删行、不改 dailySnapshots、不重扫背包。
    local forward = state.continentOrder ~= "east_first"
    local continentRank = state.sortMode == "continent" and (forward
        and { west = 1, east = 2, auroria = 3 } or { east = 1, west = 2, auroria = 3 })
        or { west = 1, east = 2, auroria = 3 }
    -- 材料正序按 ResidentBoard 的稳定业务语义排列，不依赖本地化名称排序，避免中/俄文环境下顺序漂移。
    local materialRank = {
        fabric = 1, leather = 2, lumber = 3, iron = 4,
        prince_purse = 5, prince_crate = 6,
        queen_purse = 7, queen_crate = 8,
        ancestor_purse = 9, ancestor_crate = 10,
    }
    table.sort(rows, function(a, b)
        local ac, bc = continentRank[a.continentKey] or 9, continentRank[b.continentKey] or 9
        local aq, bq = Number(a.quantity), Number(b.quantity)
        local am, bm = materialRank[a.materialKey] or 99, materialRank[b.materialKey] or 99
        if state.sortMode == "quantity" then
            if aq ~= bq then
                if aq == nil then return false end
                if bq == nil then return true end
                if forward then return aq < bq end
                return aq > bq
            end
            if ac ~= bc then return ac < bc end
            if am ~= bm then return am < bm end
        elseif state.sortMode == "material" then
            if am ~= bm then
                if forward then return am < bm end
                return am > bm
            end
            if aq ~= bq then
                if aq == nil then return false end
                if bq == nil then return true end
                if forward then return aq < bq end
                return aq > bq
            end
            if ac ~= bc then return ac < bc end
        else
            if ac ~= bc then return ac < bc end
            -- 按大陆模式只负责把同一大陆聚在一起，组内继续保持居民板 1→7 的自然顺序。
            local ab, bb = Number(a.board) or 99, Number(b.board) or 99
            if ab ~= bb then return ab < bb end
            if am ~= bm then return am < bm end
        end
        return tostring(a.key) < tostring(b.key)
    end)

    local capturedCount = 0
    for _, key in ipairs({ "west", "east", "auroria" }) do if state.dailySnapshots[key] ~= nil then capturedCount = capturedCount + 1 end end
    local status, errorText
    if capturedCount > 0 then
        status, errorText = "ready", nil
    elseif lastReadable > 0 and lastContentCount == 0 then
        status, errorText = "empty", "居民板暂无委托内容"
    else
        status, errorText = "unavailable", firstError or "今天尚未记录居民债券；进入可读取居民板的地区后刷新一次"
    end
    self.rows, self.status, self.resourceStatus, self.error = rows, status, resourceStatus, errorText
    self.snapshotDateKey, self.snapshotCount = state.dailyDateKey, capturedCount
    self.revision = self.revision + 1
    if (completionDirty or snapshotDirty) and type(Bonds.MarkStoreDirty) == "function" then
        Bonds:MarkStoreDirty(150, completionDirty and "bond_daily_completion_or_snapshot" or "bond_daily_snapshot")
    end
    PublishFeatureUpdate(Bonds, self.revision, "bonds_refresh")
    return capturedCount > 0
end

function BA:GetProjection()
    local snapshots = type(Bonds.State.dailySnapshots) == "table" and Bonds.State.dailySnapshots or {}
    -- 中文维护注释（2026-09-15，Projection 覆盖状态）：Presentation 需要告诉玩家“今天西/东大陆
    -- 哪些已读取”，但禁止直接读 State/Store。因此 Authority 只投影三个布尔值和当前大陆标签，不暴露
    -- snapshot 原文/嵌套表，也不复制第二份业务数据。该 detached 状态不会触发任何 Native 读取。
    local coverage = { west = snapshots.west ~= nil, east = snapshots.east ~= nil, auroria = snapshots.auroria ~= nil }
    return {
        revision = self.revision, rows = Copy(self.rows), status = self.status, resourceStatus = self.resourceStatus,
        error = self.error, duplicatePriorityUnresolved = self.duplicatePriorityUnresolved,
        boardScope = self.boardScope, currentContinentLabel = BOND_CONTINENT_LABEL[self.boardScope], faction = self.faction,
        snapshotDateKey = self.snapshotDateKey, snapshotCount = tonumber(self.snapshotCount) or 0,
        dailySnapshotStatus = coverage,
        lastBoardProbe = Copy(self.lastBoardProbe),
        selectedKey = Bonds.selectedKey,
    }
end
-- The daily snapshot domain nests 5 tables deep with up to 21 boards of CJK
-- text; the generic helper budget (depth 6 / 320 nodes) sat at the boundary
-- and silently starved the integrity upgrade's decode validation.
RegisterStore(Bonds.storeId, "v3.life.bonds", function() return NormalizeBondState(nil) end,
    function() return Copy(Bonds.State) end,
    function(value) Bonds.State = NormalizeBondState(value) end,
    NormalizeBondState,
    { maxDepth = 8, maxNodes = 960, maxStringBytes = 24576, maxEntriesPerTable = 192 },
    RebuildBondCanonicalForIntegrity) -- 中文维护注释：仅 Bonds 注册 pre-continentOrder exact historical bridge；Core 规则不放宽。
Bonds.ApiDependencies = { "X2Resident:GetResidentBoardContent", "X2Bag:Capacity", "X2Bag:GetBagItemInfo", "X2Unit:GetCurrentZoneGroup" }
function Bonds:Initialize() return LoadStore(self) end
function Bonds:SubscribeProgress()
    if self.progressSubscribed == true then return true end
    if S.Events == nil or type(S.Events.SubscribeInternal) ~= "function" then return false, "quest progress internal event unavailable" end
    local subscribed = S.Events:SubscribeInternal("v3.quest_progress.updated", self, function()
        -- 中文维护注释（bond-quest-reactive-1）：居民板 Store/材料快照仍由 Bonds Authority 持有；这里只在已有
        -- Bonds Consumer 时重算 questStatus，不新增 ResidentBoard 轮询。QuestProgress 的事件由 Native Quest 事件
        -- 合并后发布，因此交任务/变为可交付可以在事件后立即刷新主页面与悬浮窗。
        if Bonds.enabled == true and Bonds.consumerCount > 0 then BA:Refresh("quest_progress") end
    end)
    if subscribed ~= true then return false, "quest progress internal subscribe failed" end
    self.progressSubscribed = true
    return true
end
function Bonds:UnsubscribeProgress()
    if self.progressSubscribed ~= true then return true end
    if S.Events ~= nil and type(S.Events.UnsubscribeInternalOwner) == "function" then S.Events:UnsubscribeInternalOwner(self) end
    self.progressSubscribed = false
    return true
end
function Bonds:ScheduleLocationRefresh(reason)
    if self.enabled ~= true or (tonumber(self.consumerCount) or 0) <= 0 then return true end
    reason = reason == "entered_world" and "entered_world" or "zone_changed"
    -- 中文维护注释（2026-09-24，区域事件去抖/生命周期）：跨区过程中 Native resident board 可能先发
    -- 区域事件、后完成板数据装载。使用共享 Scheduler 的单个同名 one-shot，连续事件只保留最后一次；
    -- Consumer 释放时移除任务。绝不创建独立 OnUpdate/Tick，也不会在窗口隐藏/功能关闭后继续读取。
    if S.Scheduler ~= nil and type(S.Scheduler.AddOneShot) == "function" then
        local added = S.Scheduler:AddOneShot(BONDS_ZONE_REFRESH_TASK, 750, function()
            if Bonds.enabled == true and (tonumber(Bonds.consumerCount) or 0) > 0 then return BA:Refresh(reason) end
            return true
        end, self, "P2", 1)
        if added == true and type(S.Scheduler.SetTaskModule) == "function" then
            S.Scheduler:SetTaskModule(BONDS_ZONE_REFRESH_TASK, self.Id, false)
        end
        return added == true
    end
    return BA:Refresh(reason)
end
function Bonds:SubscribeLocationEvents()
    if self.locationSubscribed == true then return true end
    if S.Events == nil or type(S.Events.SubscribeOptional) ~= "function" then return true end
    local zoneOk = S.Events:SubscribeOptional("ENTER_ANOTHER_ZONEGROUP", self, function()
        return Bonds:ScheduleLocationRefresh("zone_changed")
    end)
    local worldOk = S.Events:SubscribeOptional("ENTERED_WORLD", self, function()
        return Bonds:ScheduleLocationRefresh("entered_world")
    end)
    -- Optional Native events are an enhancement, not a hard startup dependency. Manual refresh and Demand probe
    -- remain valid fallback paths if an older RU client cannot register one of them. Track whether any listener landed
    -- so release can deterministically clean the owner without introducing a second event Authority.
    self.locationSubscribed = zoneOk == true or worldOk == true
    return true
end
function Bonds:UnsubscribeLocationEvents()
    if S.Scheduler ~= nil and type(S.Scheduler.RemoveTask) == "function" then S.Scheduler:RemoveTask(BONDS_ZONE_REFRESH_TASK) end
    if self.locationSubscribed == true and S.Events ~= nil and type(S.Events.UnsubscribeOwner) == "function" then
        S.Events:UnsubscribeOwner(self)
    end
    self.locationSubscribed = false
    return true
end
function Bonds:ReconcileDemand(_, before, after)
    local beforeCount = tonumber(before and before.count) or 0
    local afterCount = tonumber(after and after.count) or 0
    if beforeCount <= 0 and afterCount > 0 then
        local progress = S.Services and S.Services.QuestProgressV3 or nil
        if type(progress) ~= "table" or type(progress.AcquireConsumer) ~= "function" then return false, "quest progress service unavailable" end
        local acquired, acquireErr = progress:AcquireConsumer(self.progressConsumerToken)
        if acquired ~= true then return false, acquireErr end
        self.progressConsumerHeld = true
        local subscribed, subErr = self:SubscribeProgress()
        if subscribed ~= true then
            progress:ReleaseConsumer(self.progressConsumerToken)
            self.progressConsumerHeld = false
            return false, subErr
        end
        self:SubscribeLocationEvents()
        -- Demand 0->1 在 QuestProgress 已完成一次同步刷新后再重算 Bonds，确保首次打开也使用最新 activeIndex。
        BA:Refresh("demand_start")
    elseif beforeCount > 0 and afterCount <= 0 then
        self:UnsubscribeLocationEvents()
        self:UnsubscribeProgress()
        if self.progressConsumerHeld == true then
            local progress = S.Services and S.Services.QuestProgressV3 or nil
            if type(progress) ~= "table" or type(progress.ReleaseConsumer) ~= "function" then return false, "quest progress release unavailable" end
            local released, releaseErr = progress:ReleaseConsumer(self.progressConsumerToken)
            if released ~= true then return false, releaseErr or "quest progress release failed" end
            self.progressConsumerHeld = false
        end
    end
    return true
end
function Bonds:Enable() self.enabled = true; return true end
function Bonds:Disable(reason) local ok, err = self.Demand:Clear(reason or "bonds_disable"); if ok ~= true then return false, err end; self.enabled = false; return true end
function Bonds:AcquireConsumer(token) if not self.enabled then return false, "居民板功能已关闭" end return self.Demand:Acquire(token, {}, "bonds_consumer") end
function Bonds:ReleaseConsumer(token) return self.Demand:Release(token, "bonds_consumer") end
function Bonds:Refresh(reason) if not self.enabled or self.consumerCount <= 0 then return true end return BA:Refresh(reason or "feature_refresh") end
-- Presentation must consume a detached Feature read model rather than reaching
-- through to Bonds.Authority. Keep this facade explicit so the public Feature
-- contract stays symmetric with Trade/Treasure/Fishing.
function Bonds:GetProjection() return BA:GetProjection() end
function Bonds:GetRow(key)
    key = tostring(key or "")
    if key == "" then return nil end
    for _, row in ipairs(BA.rows or {}) do
        if tostring(row.key or "") == key or tostring(row.questId or "") == key then return Copy(row) end
    end
    return nil
end
function Bonds:SelectRow(key)
    self.selectedKey = key ~= nil and tostring(key) or nil
    return true
end
function Bonds:GetSelectedRow()
    if self.selectedKey == nil then return nil end
    return self:GetRow(self.selectedKey)
end

-- §Bonds diagnostics (dayKey / per-continent load state / snapshot volume /
-- board read counter) for the acceptance snapshot. Reads only live state.
function Bonds:DescribeDailyCache()
    local snapshots = type(self.State.dailySnapshots) == "table" and self.State.dailySnapshots or {}
    return {
        dayKey = tostring(self.State.dailyDateKey or "-"),
        westLoaded = snapshots.west ~= nil,
        eastLoaded = snapshots.east ~= nil,
        auroriaLoaded = snapshots.auroria ~= nil,
        snapshotCount = (snapshots.west ~= nil and 1 or 0) + (snapshots.east ~= nil and 1 or 0) + (snapshots.auroria ~= nil and 1 or 0),
        completedCount = (function() local n = 0 for _ in pairs(type(self.State.completedMainlandKeys) == "table" and self.State.completedMainlandKeys or {}) do n = n + 1 end return n end)(),
        boardReads = tonumber(self.boardReads) or 0,
        resourceReads = tonumber(BA.resourceReads) or 0,
        -- 中文维护注释（2026-09-24，诊断证据）：只暴露上一次 bounded 1..7 探测摘要，不复制
        -- ResidentBoard 原始文本，既能判断“没读/读空/板族未识别/保留旧缓存”，又控制诊断体积。
        lastBoardProbe = Copy(BA.lastBoardProbe),
    }
end
function Bonds:GetSortMode() return Bonds.State.sortMode end
function Bonds:SetSortMode(mode)
    if mode ~= "continent" and mode ~= "quantity" and mode ~= "material" then return false, "债券排序模式无效" end
    local persisted, persistErr = PersistLifeMutation(self, "bonds_sort", function(state) state.sortMode = mode; return true end)
    if persisted ~= true then return false, persistErr end
    return self:Refresh("presentation")
end
function Bonds:GetContinentOrder() return NormalizeBondState(Bonds.State).continentOrder end
function Bonds:SetContinentOrder(order)
    if order ~= "west_first" and order ~= "east_first" then return false, "大陆排序方向无效" end
    -- 中文维护注释：大陆顺序是纯 Presentation 偏好，但由 Bonds Store 持久化并由 Authority 排序，
    -- 这样主页面/悬浮窗共享同一顺序。该命令不读 ResidentBoard、不修改 dailySnapshots，也不触发去重。
    local persisted, persistErr = PersistLifeMutation(self, "bonds_continent_order", function(state) state.continentOrder = order; return true end)
    if persisted ~= true then return false, persistErr end
    return self:Refresh("presentation")
end
function Bonds:GetBondFilter() return NormalizeBondState(Bonds.State) end
function Bonds:GetBondFilterOption(key) return Bonds:GetBondFilter()[key] == true end
function Bonds:GetDuplicatePriority() return Bonds:GetBondFilter().priority end
function Bonds:SetBondFilterOption(key, enabled)
    if key ~= "q20" and key ~= "q60" and key ~= "q100" and key ~= "auroria" and key ~= "excludeSame" then return false, "债券筛选键无效" end
    local persisted, persistErr = PersistLifeMutation(self, "bonds_filter", function(state) state[key] = enabled == true; return true end)
    if persisted ~= true then return false, persistErr end
    return self:Refresh("presentation")
end
function Bonds:SetDuplicatePriority(priority)
    if priority ~= "west" and priority ~= "east" then return false, "重复材料优先大陆无效" end
    -- 中文维护注释（2026-09-15，合并优先级无副作用）：旧实现会在选择“优先西/东”时顺手把
    -- excludeSame=true，导致用户只是想改顺序/偏好却突然少一整个大陆的重复行。priority 现在只保存
    -- “合并模式下保留哪一侧”，是否合并只能由 SetBondFilterOption(excludeSame) 显式决定。
    local persisted, persistErr = PersistLifeMutation(self, "bonds_priority", function(state) state.priority = priority; return true end)
    if persisted ~= true then return false, persistErr end
    return self:Refresh("presentation")
end
-- 中文维护注释（2026-09-24，债券下拉框原子命令）：主页面与悬浮窗都改为 3 个 Dropdown。
-- Presentation 不能连续模拟点击多个旧按钮来表达一个选项，否则会产生多次 Store 写入/Projection 发布，
-- 还可能在 Dropdown popup 未关闭时重入刷新。这里提供组合命令，一次 PersistLifeMutation 原子提交。
-- 旧 SetSortMode/SetContinentOrder/SetBondFilterOption/SetDuplicatePriority 继续保留，保证升级/扩展兼容。
function Bonds:GetDisplayOrderKey()
    local state = NormalizeBondState(Bonds.State)
    return tostring(state.sortMode) .. ":" .. tostring(state.continentOrder)
end
function Bonds:SetDisplayOrder(mode, order)
    if mode ~= "continent" and mode ~= "quantity" and mode ~= "material" then return false, "债券排序模式无效" end
    if order ~= "west_first" and order ~= "east_first" then return false, "大陆排序方向无效" end
    local persisted, persistErr = PersistLifeMutation(self, "bonds_display_order", function(state)
        state.sortMode, state.continentOrder = mode, order
        return true
    end)
    if persisted ~= true then return false, persistErr end
    return self:Refresh("presentation")
end
function Bonds:GetFilterMask()
    local state = NormalizeBondState(Bonds.State)
    local mask = 0
    if state.q20 then mask = mask + 1 end
    if state.q60 then mask = mask + 2 end
    if state.q100 then mask = mask + 4 end
    if state.auroria then mask = mask + 8 end
    return mask
end
function Bonds:SetFilterMask(mask)
    mask = tonumber(mask)
    if mask == nil or mask < 0 or mask > 15 or math.floor(mask) ~= mask then return false, "债券筛选组合无效" end
    local q20 = (mask % 2) >= 1
    local q60 = (math.floor(mask / 2) % 2) >= 1
    local q100 = (math.floor(mask / 4) % 2) >= 1
    local auroria = (math.floor(mask / 8) % 2) >= 1
    local persisted, persistErr = PersistLifeMutation(self, "bonds_filter_mask", function(state)
        state.q20, state.q60, state.q100, state.auroria = q20, q60, q100, auroria
        return true
    end)
    if persisted ~= true then return false, persistErr end
    return self:Refresh("presentation")
end
function Bonds:GetDuplicateMode()
    local state = NormalizeBondState(Bonds.State)
    if state.excludeSame ~= true then return "all" end
    return state.priority == "east" and "east" or "west"
end
function Bonds:SetDuplicateMode(mode)
    if mode ~= "all" and mode ~= "west" and mode ~= "east" then return false, "重复材料显示模式无效" end
    local persisted, persistErr = PersistLifeMutation(self, "bonds_duplicate_mode", function(state)
        state.excludeSame = mode ~= "all"
        -- “全部显示”不改历史 priority；用户以后再次选择合并时仍保留上次偏好。
        if mode == "west" or mode == "east" then state.priority = mode end
        return true
    end)
    if persisted ~= true then return false, persistErr end
    return self:Refresh("presentation")
end

Bonds.Commands = { SetDisplayOrder = function(_, mode, order) return Bonds:SetDisplayOrder(mode, order) end, SetFilterMask = function(_, mask) return Bonds:SetFilterMask(mask) end, SetDuplicateMode = function(_, mode) return Bonds:SetDuplicateMode(mode) end, Refresh = function(_, reason) return Bonds:Refresh(reason) end, SetSortMode = function(_, mode) return Bonds:SetSortMode(mode) end, SetContinentOrder = function(_, order) return Bonds:SetContinentOrder(order) end, SetBondFilterOption = function(_, key, enabled) return Bonds:SetBondFilterOption(key, enabled) end, SetDuplicatePriority = function(_, priority) return Bonds:SetDuplicatePriority(priority) end,
    SelectRow = function(_, key) return Bonds:SelectRow(key) end, GetSelectedRow = function() return Bonds:GetSelectedRow() end, GetRow = function(_, key) return Bonds:GetRow(key) end,
    GetWidgetVisible = function() return Bonds:GetWidgetVisible() end, SetWidgetVisible = function(_, value, reason) return Bonds:SetWidgetVisible(value, reason) end,
    SetWidgetWindowState = function(_, value, reason) return Bonds:SetWidgetWindowState(value, reason) end,
    MarkStoreDirty = function(_, delayMs, reason) return Bonds:MarkStoreDirty(delayMs, reason) end }
local bondsDemand, bondsErr = Demand:Create({ id = "feature:" .. Bonds.Id, owner = Bonds, projectionOwner = Bonds, projectionConsumersField = "consumers", projectionCountField = "consumerCount", reconcile = function(lease, before, after) return Bonds:ReconcileDemand(lease, before, after) end })
if bondsDemand == nil then error(bondsErr) end
Bonds.Demand = bondsDemand
ok, err = Runtime:RegisterImplementation(Bonds.Id, Bonds); if ok ~= true then error(err) end

------------------------------------------------------------------------
-- Treasure maps (shared InventorySnapshotV3 + DMS coordinates + native world-map location)
------------------------------------------------------------------------
local Treasure = { Id = "life_treasure", storeId = "v3.life.treasure", enabled = false, storeLoaded = false }
S.Features.Treasure = Treasure
Treasure.UpdateTopic = "v3.life.treasure.updated"
Treasure.ObservationContractVersion = 2 -- 中文维护注释（2026-09-16，背包 Authority 收敛）：v2 表示藏宝图枚举不再固定 bagId=0 直扫，改由 InventorySnapshotV3 选择 RU 当前可读物理背包视图；位置 500ms 刷新仍只读取玩家坐标，不重复扫描背包。
Treasure.MapLocationContractVersion = 2 -- 中文维护注释（2026-09-19，原生地图定位区域 Authority）：v2 修复旧版把 ShowWorldmapLocation 首参固定为 2 的错误假设。RU 2025-11 后签名明确要求 zoneGroupId + 全局坐标；优先使用藏宝图原生条目显式区域组，缺失时只退化到玩家当前区域组，绝不再用魔数伪造地图上下文。
Treasure.State = { selectedKey = nil, widgetVisible = false, widgetWindow = nil }
InstallLifeWidgetContract(Treasure, { defaultWidth = 390, defaultHeight = 220, minWidth = 240, minHeight = 120, defaultOverallOpacity = 0.94, defaultBackgroundOpacity = 1.0, defaultTextOpacity = 1.0 })
Treasure.Authority = { version = 2, revision = 0, maps = {}, selected = nil, status = "idle", error = nil, lastMapActionError = nil, mapOpenAttempts = 0, lastMapZoneGroup = nil, lastMapZoneSource = nil }
local XA = Treasure.Authority
local function NormalizeTreasureZoneGroup(value)
    -- 中文维护注释（2026-09-19，区域事实边界）：ShowWorldmapLocation 的首参是 zoneGroupId，不是 WorldId/MapContext。
    -- 这里只接受客户端已经给出的正整数事实；禁止从坐标范围、名称、当前大陆等软线索猜区域，否则地图会打开却把标记投到错误图层。
    local n = Number(value)
    if n == nil then return nil end
    n = math.floor(n)
    if n <= 0 then return nil end
    return n
end
local function Dms(dir, deg, min, sec, offset)
    deg, min, sec = Number(deg), Number(min), Number(sec); if not deg or not min or not sec then return nil end
    local value = deg + min / 60 + sec / 3600; if dir == "W" or dir == "S" then value = -value end
    return value * 1024 + offset
end
local function TreasureText(item)
    local lon, lat = Text(item.longitudeDir), Text(item.latitudeDir)
    local a, b, c = Number(item.longitudeDeg), Number(item.longitudeMin), Number(item.longitudeSec)
    local d, e, f = Number(item.latitudeDeg), Number(item.latitudeMin), Number(item.latitudeSec)
    if (lon ~= "E" and lon ~= "W") or (lat ~= "N" and lat ~= "S") or not a or not b or not c or not d or not e or not f then return nil end
    return string.format("%s %d°%d' %d\" · %s %d°%d' %d\"", lon, a, b, c, lat, d, e, f)
end
local function TreasureMapFromNativeItem(item, row, bagId)
    -- 中文维护注释（2026-09-16，跨语言藏宝图识别）：RU 客户端物品名不是中文，旧 string.find(name,"藏宝图") 会把真实藏宝图全部过滤掉。
    -- 藏宝图原生物品事实自身携带完整经纬 DMS 字段，这是本功能真正需要且与语言无关的业务证据；只有八个坐标字段均合法时才接纳，
    -- 不根据名字、Tooltip 文案或未知 category 猜测。InventorySnapshotV3 只负责“哪个物理背包槽真实存在”，业务坐标判断仍由 Treasure Authority 所有。
    if type(item) ~= "table" then return nil end
    local text = TreasureText(item)
    local worldX = Dms(item.longitudeDir, item.longitudeDeg, item.longitudeMin, item.longitudeSec, 21504)
    local worldY = Dms(item.latitudeDir, item.latitudeDeg, item.latitudeMin, item.latitudeSec, 28672)
    if text == nil or worldX == nil or worldY == nil then return nil end
    local slot = math.max(1, math.floor(Number(row and row.slot) or 1))
    local name = Text(item.name or item.itemName)
    if name == "" then name = "藏宝图 " .. tostring(slot) end -- 中文维护注释：这里只是缺名时的 Presentation fallback，不参与识别，因此不会重新引入本地化依赖。
    return {
        -- 中文维护注释（2026-09-16，旧配置兼容）：selectedKey 在旧版一直使用“坐标文本:槽位”。
        -- 虽然新版 Snapshot 能读到 itemType，也绝不能把它塞进 key，否则用户升级后已保存的当前藏宝图会失配并被静默切回第一张。
        -- itemType 仍作为事实字段保留供诊断/未来迁移使用；只有显式 schema migration 才允许改变持久身份格式。
        key = text .. ":" .. tostring(slot),
        name = name, text = text, worldX = worldX, worldY = worldY,
        -- 中文维护注释（2026-09-19，原生区域优先）：部分 RU 物品结构会直接附带 zoneGroupId/zoneGroupType。
        -- 若字段不存在则保持 nil，后续显式地图定位时再读取“当前区域组”作为有证据的 fallback；不要在背包扫描阶段调用位置 API。
        zoneGroupId = NormalizeTreasureZoneGroup(item.zoneGroupId) or NormalizeTreasureZoneGroup(item.zoneGroupType) or NormalizeTreasureZoneGroup(item.zoneGroup),
        slot = slot, bagId = Number(bagId), itemType = Number(row and row.itemType), direction = "--", distance = nil,
    }
end
function XA:Refresh()
    -- 中文维护注释（2026-09-16，共享背包事实）：Treasure 不再直接循环 X2Bag。显式刷新/Consumer 首次进入时只构建一次 bounded Snapshot，
    -- 由 InventorySnapshotV3 统一处理 bagId=1/0 RU 差异；随后只对 Snapshot 已确认占用的槽做一次原生详情读取以取得坐标字段。
    -- 该二阶段读取不在 500ms 位置任务内执行，因此不会把背包扫描带入高频路径，也不会复制第二份 Inventory Authority。
    local snapshotService = S.Services and S.Services.InventorySnapshotV3 or nil
    if type(snapshotService) ~= "table" or type(snapshotService.BuildSnapshot) ~= "function" or type(snapshotService.ReadPhysicalBagSlot) ~= "function" then
        self.status, self.error = "unavailable", "InventorySnapshotV3 不可用"
        self.revision = self.revision + 1
        PublishFeatureUpdate(Treasure, self.revision, "treasure_inventory_unavailable")
        return false
    end
    local snapshot, snapshotErr = snapshotService:BuildSnapshot("bag", { maxSlots = 240 })
    if type(snapshot) ~= "table" then
        self.status, self.error = "unavailable", "背包快照不可用：" .. tostring(snapshotErr or "unknown")
        self.revision = self.revision + 1
        PublishFeatureUpdate(Treasure, self.revision, "treasure_inventory_failed")
        return false
    end

    local maps = {}
    for _, row in ipairs(type(snapshot.rows) == "table" and snapshot.rows or {}) do
        local readOk, item, _, physicalBagId = snapshotService:ReadPhysicalBagSlot(row.slot, snapshot.bagId)
        if readOk == true and type(item) == "table" and next(item) ~= nil then
            local map = TreasureMapFromNativeItem(item, row, physicalBagId or snapshot.bagId)
            if map ~= nil then maps[#maps + 1] = map end
        end
    end

    local selected = Treasure.State.selectedKey
    local selectedMap = nil
    for _, map in ipairs(maps) do
        if map.key == selected then selectedMap = map; break end
    end
    if selectedMap == nil then
        selectedMap = maps[1]
        selected = selectedMap and selectedMap.key or nil
        Treasure.State.selectedKey = selected
    end
    self.maps, self.selected = maps, selectedMap
    self.inventoryBagId = snapshot.bagId
    self.inventoryFallbackUsed = snapshot.fallbackUsed == true
    self.status, self.error = (#maps > 0 and "ready" or "empty"), nil
    self.revision = self.revision + 1
    PublishFeatureUpdate(Treasure, self.revision, "treasure_scan")
    return true
end
function XA:UpdatePosition()
    local map = self.selected; if not map then return false end
    if S.Api:IsCapabilityAllowed("X2Unit:GetUnitWorldPositionByTarget") ~= true then self.error = "X2Unit:GetUnitWorldPositionByTarget 未在当前 RU 能力面证明"; return false end
    local ok, x, _, y = Call("X2Unit:GetUnitWorldPositionByTarget", UnitApi, "GetUnitWorldPositionByTarget", "player", false)
    x, y = ok and Number(x) or nil, ok and Number(y) or nil; if not x or not y then return false end
    local dx, dy = map.worldX - x, map.worldY - y
    map.distance = math.sqrt(dx * dx + dy * dy)
    map.direction = math.abs(dx) >= math.abs(dy) and (dx >= 0 and "东" or "西") or (dy >= 0 and "北" or "南")
    self.revision = self.revision + 1
    PublishFeatureUpdate(Treasure, self.revision, "treasure_position")
    return true
end
function XA:GetProjection()
    return {
        revision = self.revision, maps = Copy(self.maps), selected = Copy(self.selected), status = self.status, error = self.error,
        observationContractVersion = Treasure.ObservationContractVersion, mapLocationContractVersion = Treasure.MapLocationContractVersion,
        inventoryBagId = self.inventoryBagId, inventoryFallbackUsed = self.inventoryFallbackUsed == true,
        lastMapActionError = self.lastMapActionError, mapOpenAttempts = self.mapOpenAttempts,
        lastMapZoneGroup = self.lastMapZoneGroup, lastMapZoneSource = self.lastMapZoneSource,
    }
end
local function NormalizeTreasureState(value)
    value = type(value) == "table" and value or {}
    return {
        selectedKey = value.selectedKey ~= nil and tostring(value.selectedKey) or nil,
        widgetVisible = value.widgetVisible == true,
        widgetWindow = type(value.widgetWindow) == "table" and Copy(value.widgetWindow) or nil,
    }
end
RegisterStore(Treasure.storeId, "v3.life.treasure", function() return NormalizeTreasureState(nil) end, function() return Copy(Treasure.State) end, function(value)
    value = type(value) == "table" and value or {}
    Treasure.State.selectedKey = value.selectedKey
    Treasure.State.widgetVisible = value.widgetVisible == true
    Treasure.State.widgetWindow = type(value.widgetWindow) == "table" and Copy(value.widgetWindow) or nil
end, NormalizeTreasureState)
Treasure.ApiDependencies = { "X2Bag:GetBagItemInfo", "X2Bag:Capacity", "X2Unit:GetUnitWorldPositionByTarget", "X2Unit:GetCurrentZoneGroup", "X2Map:ShowWorldmapLocation" } -- 中文维护注释：地图 API 与当前区域读取都只在显式 Command 点击时执行；加入依赖仅确保 FeatureRuntime 惰性导入对应 namespace，不启动任何地图观察。
function Treasure:Initialize() return LoadStore(self) end
local TREASURE_POSITION_TASK = "v3_life_treasure_position"
function Treasure:ReconcileDemand(_, before, after)
    local beforeCount = tonumber(before and before.count) or 0
    local afterCount = tonumber(after and after.count) or 0
    if beforeCount <= 0 and afterCount > 0 then
        XA:Refresh(); XA:UpdatePosition()
        if S.Scheduler == nil or type(S.Scheduler.AddTask) ~= "function" then return false, "寻宝位置刷新 Scheduler 不可用" end
        local added = S.Scheduler:AddTask(TREASURE_POSITION_TASK, 500, function()
            if Treasure.enabled == true and (tonumber(Treasure.consumerCount) or 0) > 0 then XA:UpdatePosition() end
        end, false, Treasure, "P3", 1)
        if added ~= true then return false, "寻宝位置刷新任务创建失败" end
        if type(S.Scheduler.SetTaskModule) == "function" then S.Scheduler:SetTaskModule(TREASURE_POSITION_TASK, Treasure.Id, false) end
    elseif beforeCount > 0 and afterCount <= 0 and S.Scheduler ~= nil and type(S.Scheduler.RemoveTask) == "function" then
        S.Scheduler:RemoveTask(TREASURE_POSITION_TASK)
    end
    return true
end
function Treasure:Enable() self.enabled = true; return true end
function Treasure:Disable(reason) local ok, err = self.Demand:Clear(reason or "treasure_disable"); if ok ~= true then return false, err end; if S.Scheduler and type(S.Scheduler.RemoveTask) == "function" then S.Scheduler:RemoveTask(TREASURE_POSITION_TASK) end; self.enabled = false; return true end
function Treasure:AcquireConsumer(token) if not self.enabled then return false, "寻宝功能已关闭" end return self.Demand:Acquire(token, {}, "treasure_consumer") end
function Treasure:ReleaseConsumer(token) return self.Demand:Release(token, "treasure_consumer") end
function Treasure:Refresh() if not self.enabled or self.consumerCount <= 0 then return true end; XA:Refresh(); XA:UpdatePosition(); return true end
function Treasure:GetProjection() return XA:GetProjection() end
function Treasure:Select(key)
    for _, map in ipairs(XA.maps or {}) do
        if map.key == key then
            local persisted, persistErr = PersistLifeMutation(self, "treasure_select", function(state) state.selectedKey = key; return true end)
            if persisted ~= true then return false, persistErr end
            XA.selected = map; XA:UpdatePosition(); return true
        end
    end
    return false, "藏宝图选择无效"
end
local function ResolveTreasureMapZoneGroup(map)
    -- 中文维护注释（2026-09-19，地图定位证据链）：参考 TreasureMapHunter 的真实调用是 targetZone + global x/y，
    -- 因此先信藏宝图条目自己的 zoneGroup；没有时只允许用玩家当前 zoneGroup。后者只能保证“玩家已进入藏宝图所在区域”时精确定位，
    -- 但至少不会像旧魔数 2 那样打开地图却静默落到错误区域。跨区域一键定位若要完全可靠，后续必须补结构化 Treasure Location DB，不能猜。
    local explicit = type(map) == "table" and NormalizeTreasureZoneGroup(map.zoneGroupId) or nil
    if explicit ~= nil then return explicit, "item" end
    local ok, currentZone, err = Call("X2Unit:GetCurrentZoneGroup", UnitApi, "GetCurrentZoneGroup")
    local zone = ok == true and NormalizeTreasureZoneGroup(currentZone) or nil
    if zone ~= nil then return zone, "current_zone" end
    return nil, tostring(err or "藏宝图未提供区域组，且当前区域组不可用")
end
function Treasure:ShowSelectedOnMap()
    -- 中文维护注释（2026-09-16，Native 写边界）：地图打开属于显式用户动作，只能从 Command 进入并经 Capability Gate；
    -- Scheduler/UpdatePosition 永远不能调用它。失败只记录诊断并保留当前选择/距离追踪，不清 Store、不切换藏宝图，避免 UI 能力故障污染 Domain Authority。
    local map = XA.selected
    if type(map) ~= "table" then return false, "请先选择一张藏宝图" end
    local worldX, worldY = Number(map.worldX), Number(map.worldY)
    if worldX == nil or worldY == nil then return false, "藏宝图坐标不可用" end
    local zoneGroupId, zoneSourceOrErr = ResolveTreasureMapZoneGroup(map)
    if zoneGroupId == nil then
        XA.lastMapActionError = "地图定位缺少区域组：" .. tostring(zoneSourceOrErr or "unknown")
        XA.lastMapZoneGroup, XA.lastMapZoneSource = nil, "unresolved"
        XA.revision = XA.revision + 1
        PublishFeatureUpdate(self, XA.revision, "treasure_map_zone_unresolved")
        return false, XA.lastMapActionError
    end
    XA.mapOpenAttempts = (tonumber(XA.mapOpenAttempts) or 0) + 1
    XA.lastMapZoneGroup, XA.lastMapZoneSource = zoneGroupId, tostring(zoneSourceOrErr or "unknown")
    local ok, mapErr = Action("X2Map:ShowWorldmapLocation", nil, "ShowWorldmapLocation", zoneGroupId, worldX, worldY, 0)
    if ok ~= true then
        XA.lastMapActionError = tostring(mapErr or "地图定位失败")
        XA.revision = XA.revision + 1
        PublishFeatureUpdate(self, XA.revision, "treasure_map_failed")
        return false, XA.lastMapActionError
    end
    XA.lastMapActionError = nil
    XA.revision = XA.revision + 1
    PublishFeatureUpdate(self, XA.revision, "treasure_map_opened")
    return true
end
Treasure.Commands = {
    Refresh = function(_, reason) return Treasure:Refresh(reason) end,
    Select = function(_, key) return Treasure:Select(key) end,
    ShowSelectedOnMap = function() return Treasure:ShowSelectedOnMap() end, -- 中文维护注释：Presentation 只调用 Feature Command，不直接触碰 X2Map；主页面与悬浮窗因此共享同一选择和失败诊断。
    GetWidgetVisible = function() return Treasure:GetWidgetVisible() end, SetWidgetVisible = function(_, value, reason) return Treasure:SetWidgetVisible(value, reason) end,
    SetWidgetWindowState = function(_, value, reason) return Treasure:SetWidgetWindowState(value, reason) end, MarkStoreDirty = function(_, delayMs, reason) return Treasure:MarkStoreDirty(delayMs, reason) end,
}
local treasureDemand, treasureErr = Demand:Create({ id = "feature:" .. Treasure.Id, owner = Treasure, projectionOwner = Treasure, projectionConsumersField = "consumers", projectionCountField = "consumerCount", reconcile = function(lease, before, after) return Treasure:ReconcileDemand(lease, before, after) end })
if treasureDemand == nil then error(treasureErr) end
Treasure.Demand = treasureDemand
ok, err = Runtime:RegisterImplementation(Treasure.Id, Treasure); if ok ~= true then error(err) end

------------------------------------------------------------------------
-- Fishing (Demand-scoped observation + reversible Auto-R hotkey transaction)
------------------------------------------------------------------------
local Fishing = { Id = "life_fishing", storeId = "v3.life.fishing", enabled = false, storeLoaded = false, autoArmed = false, autoLeaseHeld = false, recoveryNativeRestored = false } -- 中文维护：Fishing Feature 继续拥有业务生命周期；Auto-R 会话状态只在本模块存活，持久恢复证据进入 v3.life.fishing Store。
S.Features.Fishing = Fishing -- 中文维护：保持现有 FeatureRuntime/Presentation Authority 名称，用户升级无需迁移导航或 Consumer token。
Fishing.Patch = "fishing-auto-r-transaction-1" -- 中文维护：实机诊断必须能区分本轮完整 Auto-R 事务与旧 Runtime-Blocked 版本，避免覆盖错误时继续猜根因。
Fishing.UpdateTopic = "v3.life.fishing.updated" -- 中文维护：页面与悬浮窗继续消费同一更新主题；识别/改键不能创建第二套 UI 状态源。
Fishing.ObservationContractVersion = 2 -- 中文维护：v2 表示 TARGET/BUFF 事件 + 100ms Demand-scoped 兜底扫描；避免 RU 漏 BUFF_UPDATE 时长期不刷新。
Fishing.HotkeyContractVersion = 3 -- 中文维护：v3 表示恢复旧版已验证的完整 R 快照/恢复事务，并要求持久化 durability barrier + Native readback。
Fishing.HotkeyRuntimeBlocked = false -- 中文维护：旧版实机实现和当前 Capability 面已补足缺失证据；若运行时能力/存档不可用仍由事务 fail-closed，不再全局硬禁用。
Fishing.State = { autoPreference = false, widgetVisible = false, widgetWindow = nil, recovery = nil } -- 中文维护：recovery 是唯一持久恢复 Authority；模块关闭仍保留直到原按键已确认恢复。
InstallLifeWidgetContract(Fishing, { defaultWidth = 360, defaultHeight = 190, minWidth = 230, minHeight = 110, defaultOverallOpacity = 0.94, defaultBackgroundOpacity = 1.0, defaultTextOpacity = 1.0 })

local FishingHotkey = S.Services and S.Services.FishingHotkeyV3 or nil -- 中文维护：Feature 只编排事务，不直接复制 Native Hotkey 细节；服务缺失时观察仍可用、Auto-R fail-closed。
local FISH_NORMAL_MAP = { [5264] = { slot = 4, text = "向左拉" }, [5265] = { slot = 3, text = "向右拉" }, [5267] = { slot = 5, text = "放线" }, [5266] = { slot = 6, text = "收线" }, [5508] = { slot = 7, text = "提竿" } } -- 中文维护：来源为用户提供的可用旧版 + GitHub FishBuddy/Nuzi 同组 Buff；只迁移行为语义，不搬旧生命周期。
local FISH_MIRAGE_MAP = { [5264] = { slot = 3, text = "向左拉" }, [5265] = { slot = 2, text = "向右拉" }, [5267] = { slot = 4, text = "放线" }, [5266] = { slot = 5, text = "收线" }, [5508] = { slot = 6, text = "提竿" } } -- 中文维护：ZoneGroup 49 使用旧版已验证的幻想岛槽位偏移；不能把普通区域映射硬套过去。
local FISHING_POLL_TASK = "v3_life_fishing_poll" -- 中文维护：100ms 兜底仅在 Consumer>0 运行；隐藏/关闭后必须释放，避免生活模块常驻扫描 Buff。
local FISHING_EVENT_TASK = "v3_life_fishing_event_refresh" -- 中文维护：BUFF_UPDATE 可爆发，事件边沿合并为单次 50ms 扫描，和周期兜底共享同一 Authority。
local FISHING_AUTO_CONSUMER = "auto:r" -- 中文维护：Auto-R 自身就是独立 Demand consumer；关闭主菜单不能终止已明确启用的自动钓鱼，Disarm 后必须释放。
local FISHING_RECOVERY_TASK = "v3_life_fishing_recovery" -- 中文维护：仅“战斗中等待恢复/恢复记录清理失败”时存在；不扫描 Buff，只保障用户键位最终恢复。
local FISHING_POLL_MS = 100 -- 中文维护：自动 R 需要比旧 500ms 更及时；任务严格 Demand-scoped，成本边界是最多每秒 10 次目标 Buff 扫描。
local FISHING_RECOVERY_MS = 250 -- 中文维护：恢复任务只检查战斗状态/重试事务，无需高频；250ms 兼顾脱战恢复体验与开销。

Fishing.Authority = {
    version = 2, revision = 0, status = "idle", message = "尚未观察目标鱼动作",
    buffId = nil, slot = nil, zoneGroup = nil, autoArmed = false, autoAvailable = false, autoBlockedReason = nil,
    lastScanCount = 0, lastObservedIds = {}, lastRefreshAt = 0, lastRefreshReason = "init",
    polls = 0, nativeEventRefreshes = 0, writeFailures = 0, lastWriteError = nil,
} -- 中文维护：诊断保留“事件/兜底/动作/写失败”边界，后续 RU 报告可以直接区分没事件、ID 不对还是 Hotkey 事务失败。
local FA = Fishing.Authority

local function NormalizeFishingSnapshot(snapshot) -- 中文维护：恢复快照经过持久化后不信任表形；只接受 v3 所需标量/槽位，防止旧实验记录触发 Native 写入。
    if type(snapshot) ~= "table" or (tonumber(snapshot.contractVersion) or 0) < 3 then return nil end
    local sourceSlot = Number(snapshot.sourceSlot)
    if sourceSlot == nil then return nil end
    sourceSlot = math.floor(sourceSlot)
    if sourceSlot < 1 or sourceSlot > 12 then return nil end
    local out = { contractVersion = 3, sourceSlot = sourceSlot, sourceBinding = Text(snapshot.sourceBinding, "R"), slots = {}, touched = {} }
    for key, item in pairs(type(snapshot.slots) == "table" and snapshot.slots or {}) do
        if type(item) == "table" then
            local slot = Number(item.slot or key)
            if slot ~= nil then
                slot = math.floor(slot)
                if slot >= 1 and slot <= 12 then out.slots[slot] = { slot = slot, binding = item.binding ~= nil and tostring(item.binding) or nil, wasUnbound = item.wasUnbound == true } end
            end
        end
    end
    for key, touched in pairs(type(snapshot.touched) == "table" and snapshot.touched or {}) do
        local slot = Number(key)
        if touched == true and slot ~= nil then out.touched[math.floor(slot)] = true end
    end
    if type(out.slots[sourceSlot]) ~= "table" then out.slots[sourceSlot] = { slot = sourceSlot, binding = out.sourceBinding, wasUnbound = false } end
    return out
end

local function NormalizeFishingRecovery(recovery) -- 中文维护：只把 pending=true + contractVersion>=3 视为可执行恢复权威；旧版/损坏形状保留给诊断但绝不自动写键。
    if type(recovery) ~= "table" then return nil end
    local snapshot = NormalizeFishingSnapshot(recovery.snapshot)
    if recovery.pending ~= true or snapshot == nil then return Copy(recovery) end
    return { pending = true, snapshot = snapshot }
end

local function HasValidFishingRecovery(value) -- 中文维护：所有自动恢复入口共用一个验证条件，避免 UI/Initialize/Disable 对同一存档形状做不同判断。
    return type(value) == "table" and value.pending == true and NormalizeFishingSnapshot(value.snapshot) ~= nil
end

local function CurrentFishingMap() -- 中文维护：ZoneGroup 读取是业务事实；失败时回退普通映射而不阻断动作提示，Zone 49 只有明确读到时才启用特殊偏移。
    local zoneId = nil
    if S.Api ~= nil and S.Api:IsCapabilityAllowed("X2Unit:GetCurrentZoneGroup") == true then
        local okZone, value = Call("X2Unit:GetCurrentZoneGroup", UnitApi, "GetCurrentZoneGroup")
        if okZone == true then zoneId = Number(value) end
    end
    zoneId = zoneId ~= nil and math.floor(zoneId) or nil
    FA.zoneGroup = zoneId
    return zoneId == 49 and FISH_MIRAGE_MAP or FISH_NORMAL_MAP
end

function Fishing:PersistRecoverySnapshot(snapshot, reason) -- 中文维护：每次首次触碰新槽位前走 durable=true；SaveData+readback 未通过就拒绝 Native 改键，不允许“稍后再存”。
    local normalized = NormalizeFishingSnapshot(snapshot)
    if normalized == nil then return false, "钓鱼恢复快照无效" end
    return P:MutateStore(self.storeId, function()
        self.State.recovery = { pending = true, snapshot = Copy(normalized) }
        self.State.autoPreference = true
        return true
    end, { durable = true, reason = reason or "fishing_hotkey_recovery" })
end

function Fishing:ClearRecoveryRecord(reason) -- 中文维护：必须在 Native 完整恢复成功之后才清；清理也要求持久读回，防止 Reload 又看到伪清理状态。
    return P:MutateStore(self.storeId, function()
        self.State.recovery = nil
        self.State.autoPreference = false
        return true
    end, { durable = true, reason = reason or "fishing_hotkey_recovery_clear" })
end

function Fishing:RefreshAutoAvailability() -- 中文维护：按钮可用性来自当前 Capability/战斗/恢复状态，不把失败藏在 onClick；观察功能即使 Auto-R 不可用仍保持工作。
    local supported, supportErr = false, "FishingHotkeyV3 服务不可用"
    if type(FishingHotkey) == "table" and type(FishingHotkey.IsSupported) == "function" then supported, supportErr = FishingHotkey:IsSupported() end
    local invalidRecovery = type(self.State.recovery) == "table" and not HasValidFishingRecovery(self.State.recovery)
    -- 中文维护：Lua 的 `a and b or true` 会在 b=false 时重新落到 true；此前因此把“未战斗”也判成战斗中，Auto-R UI 永远不可用。
    -- Authority：战斗状态只由 FishingHotkeyV3 的 capability-gated PlayerInCombat 读取；服务缺失时才 fail-closed 为 true。
    local inCombat = true
    if type(FishingHotkey) == "table" and type(FishingHotkey.InCombat) == "function" then
        inCombat = FishingHotkey:InCombat() == true
    end
    FA.autoArmed = self.autoArmed == true
    FA.autoAvailable = supported == true and invalidRecovery ~= true and inCombat ~= true and (self:IsRecoveryPending() ~= true or self.autoArmed == true)
    if invalidRecovery then FA.autoBlockedReason = "检测到无法验证的旧版自动 R 恢复记录；为避免误删按键，本次拒绝改键。请先确认游戏按键并重置钓鱼配置。"
    elseif supported ~= true then FA.autoBlockedReason = tostring(supportErr or "自动 R API 不可用")
    elseif inCombat then FA.autoBlockedReason = "战斗中不能修改按键"
    elseif self:IsRecoveryPending() and self.autoArmed ~= true then FA.autoBlockedReason = "正在恢复原 R 键，请稍候"
    else FA.autoBlockedReason = nil end
    return FA.autoAvailable
end

function Fishing:IsRecoveryPending() -- 中文维护：持久 Store 和服务内存任一仍有恢复义务，都视为 pending；UI 关闭不能抹掉这个安全状态。
    if self.recoveryNativeRestored == true then return true end
    if HasValidFishingRecovery(self.State.recovery) then return true end
    return type(FishingHotkey) == "table" and type(FishingHotkey.IsRecoveryPending) == "function" and FishingHotkey:IsRecoveryPending() == true or false
end

function Fishing:CancelRecoveryTask() -- 中文维护：恢复完成后主动释放低频安全任务；不会让生活功能关闭后留下永久 Scheduler 消费者。
    if S.Scheduler ~= nil and type(S.Scheduler.RemoveTask) == "function" then S.Scheduler:RemoveTask(FISHING_RECOVERY_TASK) end
end

function Fishing:EnsureRecoveryTask() -- 中文维护：仅在确有恢复义务时创建；即使 Feature 被关闭也允许此安全任务继续，直到用户原键位恢复。
    if self:IsRecoveryPending() ~= true then self:CancelRecoveryTask(); return true end
    if S.Scheduler == nil or type(S.Scheduler.AddTask) ~= "function" then return false, "钓鱼按键恢复 Scheduler 不可用" end
    if S.Scheduler.tasks and S.Scheduler.tasks[FISHING_RECOVERY_TASK] ~= nil then return true end
    local added = S.Scheduler:AddTask(FISHING_RECOVERY_TASK, FISHING_RECOVERY_MS, function()
        if Fishing:IsRecoveryPending() ~= true then Fishing:CancelRecoveryTask(); return true end
        if type(FishingHotkey) == "table" and FishingHotkey:InCombat() == true then return true end
        Fishing:ProcessPendingRecovery(true, "recovery_task")
        return true
    end, false, self, "P1", 1)
    if added == true and type(S.Scheduler.SetTaskModule) == "function" then S.Scheduler:SetTaskModule(FISHING_RECOVERY_TASK, self.Id, false) end
    return added == true, added == true and nil or "钓鱼按键恢复任务创建失败"
end

function Fishing:ProcessPendingRecovery(silent, reason) -- 中文维护：Native 恢复与持久 recovery 清理分两段；任一失败都保留 Authority，下一 tick 可重试，不会宣称已恢复。
    local recovery = HasValidFishingRecovery(self.State.recovery) and self.State.recovery or nil
    local snapshot = recovery and NormalizeFishingSnapshot(recovery.snapshot) or nil
    if snapshot == nil and type(FishingHotkey) == "table" and type(FishingHotkey.sessionSnapshot) == "table" then snapshot = NormalizeFishingSnapshot(FishingHotkey.sessionSnapshot) end
    if snapshot == nil then
        self.recoveryNativeRestored = false
        if type(FishingHotkey) == "table" and type(FishingHotkey.ResetSession) == "function" then FishingHotkey:ResetSession() end
        self:CancelRecoveryTask()
        self:RefreshAutoAvailability()
        return true
    end
    if type(FishingHotkey) ~= "table" then self:EnsureRecoveryTask(); return false, "FishingHotkeyV3 服务不可用" end
    if FishingHotkey:InCombat() == true then
        FishingHotkey:AdoptRecovery(snapshot)
        FishingHotkey.pendingRecovery = true
        self.autoArmed = false
        FA.autoArmed = false
        FA.status, FA.message = "recovering", "战斗中不能改键 · 等待脱战恢复原 R"
        self:EnsureRecoveryTask()
        self:RefreshAutoAvailability()
        return false, "战斗中等待恢复"
    end
    if FishingHotkey.sessionSnapshot == nil then FishingHotkey:AdoptRecovery(snapshot) end
    if self.recoveryNativeRestored ~= true then
        local restored, restoreErr = FishingHotkey:RestoreSnapshot(snapshot)
        if restored ~= true then
            FA.status, FA.message = "error", "恢复原按键失败：" .. tostring(restoreErr or "unknown")
            FA.lastWriteError = tostring(restoreErr or "restore failed")
            self:EnsureRecoveryTask()
            self:RefreshAutoAvailability()
            if silent ~= true then S.SafeChat(FA.message) end
            return false, restoreErr
        end
        self.recoveryNativeRestored = true
    end
    local cleared, clearErr = self:ClearRecoveryRecord("fishing_recovery_clear:" .. tostring(reason or "manual"))
    if cleared ~= true then
        FA.status, FA.message = "recovering", "原按键已恢复，但恢复记录保存失败；将继续重试"
        FA.lastWriteError = tostring(clearErr or "recovery clear failed")
        self:EnsureRecoveryTask()
        self:RefreshAutoAvailability()
        return false, clearErr
    end
    self.recoveryNativeRestored = false
    self.autoArmed = false
    FishingHotkey:ResetSession()
    self:CancelRecoveryTask()
    FA.autoArmed = false
    FA.status, FA.message = "waiting", "自动 R 已关闭 · 已恢复原按键"
    FA.lastWriteError = nil
    self:RefreshAutoAvailability()
    FA.revision = FA.revision + 1
    PublishFeatureUpdate(self, FA.revision, "fishing_hotkey_restored")
    if silent ~= true then S.SafeChat("钓鱼自动 R 已关闭，原按键已恢复。") end
    return true
end

function FA:Refresh(reason) -- 中文维护：鱼动作识别是唯一 projection Authority；事件刷新和 100ms 兜底都走这里，防止 UI 与 Auto-R 读取不同 Buff 快照。
    reason = tostring(reason or "manual")
    self.buffId, self.slot = nil, nil
    self.lastScanCount, self.lastObservedIds = 0, {}
    self.lastRefreshAt = S.NowMs and S.NowMs() or 0
    self.lastRefreshReason = reason
    if reason == "poll" then self.polls = (tonumber(self.polls) or 0) + 1 else self.nativeEventRefreshes = (tonumber(self.nativeEventRefreshes) or 0) + 1 end
    if S.Api:IsCapabilityAllowed("X2Unit:UnitBuffCount") ~= true or S.Api:IsCapabilityAllowed("X2Unit:UnitBuff") ~= true then
        self.status, self.message = "unavailable", "当前 RU 能力面未证明目标 Buff 读取"
        Fishing:RefreshAutoAvailability()
        self.revision = self.revision + 1
        PublishFeatureUpdate(Fishing, self.revision, "fishing_observation_unavailable")
        return false
    end
    local map = CurrentFishingMap()
    local ok, count = Call("X2Unit:UnitBuffCount", UnitApi, "UnitBuffCount", "target")
    count = ok and Number(count) or 0
    count = math.max(0, math.min(128, math.floor(count or 0)))
    self.lastScanCount = count
    for index = 1, count do
        local readOk, buff = Call("X2Unit:UnitBuff", UnitApi, "UnitBuff", "target", index)
        local id = readOk and type(buff) == "table" and Number(buff.buff_id or buff.buffId or buff.type or buff.id) or nil
        if id ~= nil and #self.lastObservedIds < 16 then self.lastObservedIds[#self.lastObservedIds + 1] = math.floor(id) end
        if id and map[id] then self.buffId, self.slot = math.floor(id), map[id].slot; break end
    end
    self.status = self.buffId and "ready" or "waiting"
    if self.buffId then
        self.message = map[self.buffId].text .. " · 技能栏 " .. tostring(self.slot) .. (Fishing.autoArmed and " · R 已自动映射" or "")
    else
        self.message = Fishing.autoArmed and "等待鱼的动作 Buff · R 保持当前映射" or "选中正在挣扎的鱼后显示推荐技能"
    end

    if Fishing.autoArmed == true and self.slot ~= nil then
        if type(FishingHotkey) ~= "table" then
            self.writeFailures = (tonumber(self.writeFailures) or 0) + 1
            self.lastWriteError = "FishingHotkeyV3 服务不可用"
            Fishing.autoArmed = false
            Fishing:ReleaseAutoLease("fishing_auto_missing_service")
            self.status, self.message = "error", "自动 R 不可用：FishingHotkeyV3 服务缺失"
            Fishing:RefreshAutoAvailability()
            self.revision = self.revision + 1
            PublishFeatureUpdate(Fishing, self.revision, "fishing_auto_missing_service")
            return false
        end
        local moved, moveErr = FishingHotkey:MoveR(self.slot, function(snapshot)
            return Fishing:PersistRecoverySnapshot(snapshot, "fishing_hotkey_touch_slot")
        end)
        if moved ~= true then
            self.writeFailures = (tonumber(self.writeFailures) or 0) + 1
            self.lastWriteError = tostring(moveErr or "hotkey move failed")
            Fishing.autoArmed = false
            self.autoArmed = false
            Fishing:ReleaseAutoLease("fishing_auto_write_failure")
            self.status, self.message = "error", "自动 R 设置失败：" .. self.lastWriteError
            Fishing:EnsureRecoveryTask()
            -- 中文维护：写入失败后不丢恢复快照；非战斗状态立即尝试回滚，战斗状态交给独立恢复任务，绝不继续切换新槽位。
            if FishingHotkey:InCombat() ~= true then Fishing:ProcessPendingRecovery(true, "auto_move_failure") end
            Fishing:RefreshAutoAvailability()
            self.revision = self.revision + 1
            PublishFeatureUpdate(Fishing, self.revision, "fishing_auto_write_failed")
            return false
        end
    end

    Fishing:RefreshAutoAvailability()
    self.revision = self.revision + 1
    PublishFeatureUpdate(Fishing, self.revision, "fishing_observation:" .. reason)
    return true
end

function FA:GetProjection() -- 中文维护：Presentation 只读 detached projection；Hotkey 服务内部快照/真实按键内容永不暴露给 UI。
    local hotkeyDiag = type(FishingHotkey) == "table" and type(FishingHotkey.GetDiagnostics) == "function" and FishingHotkey:GetDiagnostics() or nil
    return {
        patch = Fishing.Patch, revision = self.revision, status = self.status, message = self.message, buffId = self.buffId, slot = self.slot, zoneGroup = self.zoneGroup,
        autoArmed = Fishing.autoArmed == true, autoAvailable = self.autoAvailable == true, autoBlockedReason = self.autoBlockedReason,
        lastScanCount = self.lastScanCount, lastObservedIds = Copy(self.lastObservedIds), lastRefreshAt = self.lastRefreshAt, lastRefreshReason = self.lastRefreshReason,
        polls = self.polls, nativeEventRefreshes = self.nativeEventRefreshes, writeFailures = self.writeFailures, lastWriteError = self.lastWriteError,
        recoveryPending = Fishing:IsRecoveryPending(), hotkey = hotkeyDiag,
    }
end

function Fishing:AcquireAutoLease() -- 中文维护：Auto-R 持有自己的 Demand lease，避免用户关闭主页面后 consumer=0 导致刚启用的 R 映射立即被恢复。
    if self.autoLeaseHeld == true and self.Demand:Has(FISHING_AUTO_CONSUMER) then return true end
    local ok, err = self.Demand:Acquire(FISHING_AUTO_CONSUMER, { autoR = true }, "fishing_auto_r")
    if ok == true then self.autoLeaseHeld = true end
    return ok, err
end

function Fishing:ReleaseAutoLease(reason) -- 中文维护：先清本地 held 标志再 Release，防止 1→0 reconcile 回调再次进入 Disarm 形成递归；失败时恢复标志供后续清理。
    if self.autoLeaseHeld ~= true and self.Demand:Has(FISHING_AUTO_CONSUMER) ~= true then return true end
    self.autoLeaseHeld = false
    local ok, err = self.Demand:Release(FISHING_AUTO_CONSUMER, reason or "fishing_auto_r_release")
    if ok ~= true and self.Demand:Has(FISHING_AUTO_CONSUMER) then self.autoLeaseHeld = true end
    return ok, err
end

function Fishing:ArmAuto() -- 中文维护：启用流程固定为“能力/战斗检查→找到原 R→全槽快照→durable recovery→进入会话→按当前 Buff 映射”；顺序不可反转。
    if self.autoArmed == true then return true end
    if self.enabled ~= true or (tonumber(self.consumerCount) or 0) <= 0 then return false, "请先打开钓鱼页面或悬浮窗，再启用自动 R" end
    if type(FishingHotkey) ~= "table" then return false, "FishingHotkeyV3 服务不可用" end
    if type(self.State.recovery) == "table" and HasValidFishingRecovery(self.State.recovery) ~= true then
        self:RefreshAutoAvailability()
        return false, FA.autoBlockedReason or "旧版恢复记录无法验证"
    end
    if self:IsRecoveryPending() == true then
        local recovered, recoverErr = self:ProcessPendingRecovery(true, "before_arm")
        if recovered ~= true then return false, recoverErr or "仍有未完成的按键恢复" end
    end
    local supported, supportErr = FishingHotkey:IsSupported()
    if supported ~= true then self:RefreshAutoAvailability(); return false, supportErr end
    if FishingHotkey:InCombat() == true then self:RefreshAutoAvailability(); return false, "战斗中不能修改按键" end
    local original = FishingHotkey:FindOriginalRSlot()
    if original == nil then return false, "无法可靠读取当前 R 键所在动作栏位置，因此不会修改键位" end
    local snapshot, snapshotErr = FishingHotkey:BuildSessionSnapshot(original)
    if snapshot == nil then return false, snapshotErr end
    local persisted, persistErr = self:PersistRecoverySnapshot(snapshot, "fishing_hotkey_arm")
    if persisted ~= true then return false, "无法持久保存改键恢复快照，因此拒绝修改按键：" .. tostring(persistErr or "unknown") end
    local adopted, adoptErr = FishingHotkey:AdoptRecovery(snapshot)
    if adopted ~= true then return false, adoptErr end
    local leased, leaseErr = self:AcquireAutoLease()
    if leased ~= true then
        -- 中文维护：此时尚未执行 Native 写键；若独立 Auto-R Demand 无法建立，撤销内存会话并 durable 清除恢复记录，不能留下“其实没改键”的幽灵 recovery。
        FishingHotkey:ResetSession()
        self:ClearRecoveryRecord("fishing_auto_lease_rollback")
        return false, leaseErr or "自动 R 生命周期启动失败"
    end
    self.autoArmed = true
    self.recoveryNativeRestored = false
    FA.autoArmed = true
    FA.status, FA.message = "waiting", "自动 R 已启用 · 等待鱼动作"
    FA.lastWriteError = nil
    self:RefreshAutoAvailability()
    local refreshed, refreshErr = FA:Refresh("arm_auto")
    if refreshed ~= true then return false, refreshErr or FA.lastWriteError or "自动 R 初次映射失败" end
    S.SafeChat("钓鱼自动 R 已启用；关闭功能/悬浮窗或切换区域时会恢复原按键。")
    return true
end

function Fishing:DisarmAuto(silent) -- 中文维护：关闭时先停止新映射并释放 Auto-R 自有 Demand，再恢复；战斗中只标记 pending，不触碰受限 Hotkey API，脱战由恢复任务处理。
    self.autoArmed = false
    FA.autoArmed = false
    self:ReleaseAutoLease("fishing_auto_disarm")
    if self:IsRecoveryPending() ~= true then
        self:RefreshAutoAvailability()
        return true
    end
    if type(FishingHotkey) ~= "table" then return false, "FishingHotkeyV3 服务不可用" end
    if FishingHotkey:InCombat() == true then
        FishingHotkey.pendingRecovery = true
        FA.status, FA.message = "recovering", "战斗中不能改键 · 等待脱战恢复原 R"
        self:EnsureRecoveryTask()
        self:RefreshAutoAvailability()
        if silent ~= true then S.SafeChat("战斗中不能修改按键，脱战后自动恢复原 R。") end
        return false, "战斗中等待恢复"
    end
    return self:ProcessPendingRecovery(silent, "disarm")
end

function Fishing:IsAutoArmed() return self.autoArmed == true end -- 中文维护：Presentation 只查询 Feature 会话状态，不直接读 Hotkey 服务内部字段。

local function NormalizeFishingState(value) -- 中文维护：旧 Store schema 继续兼容；新增 recovery 仍在同一 schema 的可选字段，不删除窗口/用户偏好。
    value = type(value) == "table" and value or {}
    return {
        autoPreference = value.autoPreference == true,
        widgetVisible = value.widgetVisible == true,
        widgetWindow = type(value.widgetWindow) == "table" and Copy(value.widgetWindow) or nil,
        recovery = NormalizeFishingRecovery(value.recovery),
    }
end
RegisterStore(Fishing.storeId, "v3.life.fishing", function() return NormalizeFishingState(nil) end, function() return Copy(Fishing.State) end, function(value)
    value = NormalizeFishingState(value)
    Fishing.State.autoPreference = value.autoPreference == true
    Fishing.State.widgetVisible = value.widgetVisible == true
    Fishing.State.widgetWindow = type(value.widgetWindow) == "table" and Copy(value.widgetWindow) or nil
    Fishing.State.recovery = type(value.recovery) == "table" and Copy(value.recovery) or nil
end, NormalizeFishingState)
Fishing.ApiDependencies = { "X2Unit:UnitBuffCount", "X2Unit:UnitBuff", "X2Unit:GetCurrentZoneGroup", "X2Hotkey:GetOptionBinding", "X2Hotkey:BindingToOption", "X2Hotkey:SetOptionBindingWithIndex", "X2Hotkey:RemoveOptionBinding", "X2Hotkey:SaveHotKey", "X2Player:PlayerInCombat" } -- 中文维护：Registry/诊断必须公开真实依赖，不能再次把 Auto-R 写能力隐藏成“只读功能”。

function Fishing:Initialize() -- 中文维护：Reload 时先加载 Store，再优先修复未完成 Hotkey 事务；不会因为 autoPreference=true 自动重新改键。
    local ok, err = LoadStore(self)
    if ok ~= true then return ok, err end
    self.autoArmed = false
    if HasValidFishingRecovery(self.State.recovery) then
        if type(FishingHotkey) ~= "table" then return false, "检测到钓鱼按键恢复记录，但 FishingHotkeyV3 服务不可用" end
        local adopted, adoptErr = FishingHotkey:AdoptRecovery(NormalizeFishingSnapshot(self.State.recovery.snapshot))
        if adopted ~= true then return false, adoptErr end
        local recovered = self:ProcessPendingRecovery(true, "initialize_reload")
        if recovered ~= true then self:EnsureRecoveryTask() end
    elseif type(self.State.recovery) == "table" then
        -- 中文维护：历史实验记录不满足 v3 SnapshotContract，绝不自动解释/删除；这是最后一道防止误删真实用户按键的兼容边界。
        FA.status = "blocked"
        FA.message = "检测到无法验证的旧版自动 R 恢复记录"
        self:RefreshAutoAvailability()
        S.SafeChat(FA.autoBlockedReason or FA.message)
    else
        self:RefreshAutoAvailability()
    end
    return true
end

function Fishing:HandleWorldBoundary(reason) -- 中文维护：切地图/进入世界会改变动作栏上下文；先终止 Auto-R 并恢复，再重新观察，禁止携带旧槽位映射跨区域。
    if self.autoArmed == true or self:IsRecoveryPending() == true then self:DisarmAuto(true) end
    if self.enabled == true and (tonumber(self.consumerCount) or 0) > 0 then return FA:Refresh(reason or "world_boundary") end
    return true
end

function Fishing:ReconcileDemand(_, before, after) -- 中文维护：观察扫描严格由 Consumer 生命周期驱动；Auto-R 关闭/页面关闭时释放高频读，只有安全恢复任务可短暂独立存在。
    local beforeCount = tonumber(before and before.count) or 0
    local afterCount = tonumber(after and after.count) or 0
    if beforeCount <= 0 and afterCount > 0 then
        if S.Events == nil or S.Scheduler == nil or type(S.Scheduler.AddTask) ~= "function" or type(S.Scheduler.AddOneShot) ~= "function" then return false, "钓鱼观察事件/Scheduler 不可用" end
        S.Events:BindOwner(self, self.Id)
        local targetOk = S.Events:SubscribeOptional("TARGET_CHANGED", self, function(_)
            if Fishing.enabled and Fishing.consumerCount > 0 then return FA:Refresh("target_changed") end
            return true
        end)
        local buffOk = S.Events:SubscribeOptional("BUFF_UPDATE", self, function(_)
            if Fishing.enabled and Fishing.consumerCount > 0 then
                S.Scheduler:AddOneShot(FISHING_EVENT_TASK, 50, function()
                    if Fishing.enabled and Fishing.consumerCount > 0 then return FA:Refresh("buff_update") end
                    return true
                end, Fishing, "P1", 1)
            end
            return true
        end)
        local worldOk = S.Events:SubscribeOptional("ENTERED_WORLD", self, function(_) return Fishing:HandleWorldBoundary("entered_world") end)
        local zoneOk = S.Events:SubscribeOptional("ENTER_ANOTHER_ZONEGROUP", self, function(_) return Fishing:HandleWorldBoundary("zone_changed") end)
        if targetOk ~= true or buffOk ~= true or worldOk ~= true or zoneOk ~= true then S.Events:UnsubscribeOwner(self); return false, "钓鱼目标/Buff/区域事件订阅失败" end
        local added = S.Scheduler:AddTask(FISHING_POLL_TASK, FISHING_POLL_MS, function()
            if Fishing.enabled == true and (tonumber(Fishing.consumerCount) or 0) > 0 then return FA:Refresh("poll") end
            return true
        end, false, self, "P2", 1)
        if added ~= true then S.Events:UnsubscribeOwner(self); return false, "钓鱼 100ms 兜底扫描任务创建失败" end
        if type(S.Scheduler.SetTaskModule) == "function" then S.Scheduler:SetTaskModule(FISHING_POLL_TASK, self.Id, false); S.Scheduler:SetTaskModule(FISHING_EVENT_TASK, self.Id, false) end
        return FA:Refresh("consumer_start")
    elseif beforeCount > 0 and afterCount <= 0 then
        -- 中文维护：Auto-R 有自己的 lease；正常页面关闭不会走到 0。真正 0-consumer 时仅在仍 armed 的异常路径执行 Disarm，避免 ReleaseAutoLease 的 1→0 转换递归。
        if self.autoArmed == true then self:DisarmAuto(true) end
        if S.Events ~= nil then S.Events:UnsubscribeOwner(self) end
        if S.Scheduler ~= nil and type(S.Scheduler.RemoveTask) == "function" then S.Scheduler:RemoveTask(FISHING_POLL_TASK); S.Scheduler:RemoveTask(FISHING_EVENT_TASK) end
        if self:IsRecoveryPending() then self:EnsureRecoveryTask() end
    end
    return true
end

function Fishing:Enable() self.enabled = true; self:RefreshAutoAvailability(); return true end
function Fishing:Disable(reason) -- 中文维护：Disable 先清 Demand/停止扫描，再恢复 R；若战斗阻止恢复，低频 recovery task 继续到成功，不能因 Feature off 丢失恢复义务。
    self.autoLeaseHeld = false -- 中文维护：Demand:Clear 会原子删除 Auto-R token；先清本地标志，避免 reconcile 中 Disarm 再尝试 Release 已被 Clear 的 token。
    local ok, err = self.Demand:Clear(reason or "fishing_disable")
    if ok ~= true then return false, err end
    if S.Events then S.Events:UnsubscribeOwner(self) end
    if S.Scheduler and type(S.Scheduler.RemoveTask) == "function" then S.Scheduler:RemoveTask(FISHING_POLL_TASK); S.Scheduler:RemoveTask(FISHING_EVENT_TASK) end
    local restored, restoreErr = self:DisarmAuto(true)
    self.enabled = false
    if restored ~= true and self:IsRecoveryPending() then self:EnsureRecoveryTask() end
    return restored ~= false or self:IsRecoveryPending(), restoreErr
end
function Fishing:AcquireConsumer(token) if not self.enabled then return false, "钓鱼功能已关闭" end return self.Demand:Acquire(token, {}, "fishing_consumer") end
function Fishing:ReleaseConsumer(token) return self.Demand:Release(token, "fishing_consumer") end
function Fishing:Refresh(reason) if not self.enabled or self.consumerCount <= 0 then return true end return FA:Refresh(reason or "manual") end
function Fishing:GetProjection() return FA:GetProjection() end
Fishing.Commands = {
    Refresh = function(_, reason) return Fishing:Refresh(reason) end,
    ArmAuto = function() return Fishing:ArmAuto() end,
    DisarmAuto = function() return Fishing:DisarmAuto() end,
    GetWidgetVisible = function() return Fishing:GetWidgetVisible() end,
    SetWidgetVisible = function(_, value, reason) return Fishing:SetWidgetVisible(value, reason) end,
    SetWidgetWindowState = function(_, value, reason) return Fishing:SetWidgetWindowState(value, reason) end,
    MarkStoreDirty = function(_, delayMs, reason) return Fishing:MarkStoreDirty(delayMs, reason) end,
}
local fishingDemand, fishingErr = Demand:Create({ id = "feature:" .. Fishing.Id, owner = Fishing, projectionOwner = Fishing, projectionConsumersField = "consumers", projectionCountField = "consumerCount", reconcile = function(lease, before, after) return Fishing:ReconcileDemand(lease, before, after) end })
if fishingDemand == nil then error(fishingErr) end
Fishing.Demand = fishingDemand
ok, err = Runtime:RegisterImplementation(Fishing.Id, Fishing); if ok ~= true then error(err) end
