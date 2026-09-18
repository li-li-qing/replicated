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
local Trade = { Id = "life_trade", storeId = "v3.life.trade", enabled = false, storeLoaded = false }
S.Features.Trade = Trade
Trade.UpdateTopic = "v3.life.trade.updated"
Trade.State = { fromZone = nil, toZone = nil, favorites = {}, sortMode = "ratio", ratioMode = "current", commerceMode = "observe", widgetVisible = false, widgetWindow = nil }
Trade.Authority = { version = 6, revision = 0, zones = {}, sellableZones = {}, rows = {}, selectedKey = nil, status = "idle", error = nil, inFlight = nil, zoneFallback = false, sellableFallback = false, sellableError = nil, commerceSkill = nil, commerceStatus = "idle", commerceName = nil, commerceError = nil }
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
TA.RouteRefreshRetryContractVersion = 3
TA.SingleFlightLatestRouteContractVersion = 1
TA.RequestTimeoutContractVersion = 3
TA.NativeCooldownContractVersion = 2
TA.requestTimeoutTask = "v3_trade_route_timeout"
TA.requestDeferredTask = "v3_trade_route_deferred"
TA.requestSerial = tonumber(TA.requestSerial) or 0
TA.pendingRoute = nil
TA.pendingRetryCount = nil
TA.timedOutFlight = nil
TA.responseSlaMs = 6500
TA.lastNativeCooldownMs = tonumber(TA.lastNativeCooldownMs) or 0
TA.nextNativeRequestAt = tonumber(TA.nextNativeRequestAt) or 0
TA.lastResponseTimeoutMs = tonumber(TA.lastResponseTimeoutMs) or 6500
TA.sellableCache = {}
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

local TRADE_MATERIAL_KEY_MAX_CHARS = 48
-- Table cells hold "name×count" only; keep the bound tight so four materials fit.
local TRADE_MATERIAL_CELL_MAX_CHARS = 26
local TRADE_MATERIAL_SUMMARY_ROW_MAX_CHARS = 120
local TRADE_MATERIAL_SUMMARY_MAX_CHARS = 4096

local function BoundedTradeText(value, fallback, maxChars)
    local text = Text(value, fallback)
    local limit = tonumber(maxChars) or TRADE_MATERIAL_KEY_MAX_CHARS
    if #text > limit then return string.sub(text, 1, limit) end
    return text
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
    end
    local item = (record == nil and type(meta) == "table") and meta[ingredient.materialKey] or nil
    local itemType = (record and tonumber(record.itemId)) or (item and tonumber(item.itemType)) or tonumber(ingredient.itemType)
    local itemGrade = (record and tonumber(record.itemGrade)) or (item and tonumber(item.itemGrade)) or tonumber(ingredient.itemGrade)
    local includeInCost = not (record and record.includeInCost == false) and not (item and item.includeInCost == false)
    if ingredient.includeInCost == false then includeInCost = false end
    local materialKey = tostring((record and record.nameEn) or ingredient.materialKey or ingredient.compactId or "?")
    return materialKey, itemType, itemGrade, includeInCost
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
        local materialKey, itemType, itemGrade, includeInCost = ResolveTradeIngredient(static, meta, ingredient)
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
            totalCost, status = 0, "excluded"
        elseif itemType == nil then
            complete, status = false, "identity_pending"
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
            internalKey = BoundedTradeText(materialKey, "?", TRADE_MATERIAL_KEY_MAX_CHARS),
            name = BoundedTradeText(displayName or "材料", "材料", TRADE_MATERIAL_KEY_MAX_CHARS),
            count = count,
            itemType = itemType,
            itemGrade = itemGrade,
            includeInCost = includeInCost,
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
        if status == "excluded" then
            row.detailText = row.detailText .. "（不计成本）"
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
        row.summaryText = BoundedTradeText(row.detailText, row.name .. "×" .. tostring(row.count), TRADE_MATERIAL_SUMMARY_ROW_MAX_CHARS)
        row.cellText = BoundedTradeText(row.name .. "×" .. tostring(row.count), row.name, TRADE_MATERIAL_CELL_MAX_CHARS)
        result.rows[#result.rows + 1] = row
        result.materialRows[#result.materialRows + 1] = row
    end

    local summaryParts, summaryChars = {}, 0
    for _, row in ipairs(result.materialRows) do
        local part = row.cellText or row.summaryText
        local nextChars = summaryChars + #part + (#summaryParts > 0 and 3 or 0)
        if nextChars > TRADE_MATERIAL_SUMMARY_MAX_CHARS then
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
    result.costStatus = result.truncated and "truncated" or (result.costComplete and "ready" or "partial")
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
    row.identityStatus = materialProjection.identityStatus
    row.recipeLabel = materialProjection.recipeLabel
    row.identitySource = materialProjection.identitySource
    row.materialIdentityPending = materialProjection.identityStatus == "live_pending"
    -- .18.176 RU evidence: GetLowestPrice returns nil for every grade on every
    -- control itemType (oats/hay/egg included), so a material cost is currently
    -- unobtainable on this client. "待材料价格" used to imply the number was merely
    -- pending; say what is actually missing and where the player can still get a
    -- usable estimate (the sell price and 货率 columns remain real facts).
    row.profit = profit and Money(profit) or (price and "缺材料价（拍卖行无返回）" or "--")
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

function TA:RebuildDisplayRows(reason)
    for _, row in ipairs(self.rows or {}) do ApplyTradeDisplayModeToRow(row) end
    SortTradeRows(self.rows or {})
    self.revision = self.revision + 1
    PublishFeatureUpdate(Trade, self.revision, reason or "trade_display_mode")
    return true
end

function TA:RefreshCommerceSkill()
    if Trade.State.commerceMode ~= "observe" then
        self.commerceSkill, self.commerceName, self.commerceError = nil, nil, nil
        self.commerceStatus = "off"
        return true
    end
    local ok, infos, err = Call("X2Ability:GetAllMyActabilityInfos", AbilityApi, "GetAllMyActabilityInfos")
    if ok ~= true or type(infos) ~= "table" then
        self.commerceSkill, self.commerceName = nil, nil
        self.commerceStatus, self.commerceError = "unavailable", err or "经商熟练度列表不可读"
        return true
    end
    for _, info in pairs(infos) do
        if type(info) == "table" then
            local name = Text(info.name, "")
            if TRADE_COMMERCE_NAMES[name] == true then
                local point, modify = Number(info.point), Number(info.modifyPoint)
                if point ~= nil or modify ~= nil then
                    self.commerceSkill = math.max(0, (point or 0) + (modify or 0))
                    self.commerceName, self.commerceStatus, self.commerceError = name, "ready", nil
                    return true
                end
                self.commerceSkill, self.commerceName = nil, name
                self.commerceStatus, self.commerceError = "unavailable", "经商熟练度字段不可读"
                return true
            end
        end
    end
    self.commerceSkill, self.commerceName = nil, nil
    self.commerceStatus, self.commerceError = "not_found", "未在当前本地化熟练度列表中识别到经商项目"
    return true
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
local function RequestPendingLiveIdentities()
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
local function TraceInit(event, detail)
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
    if not found then Trade.State.toZone = nil; self.rows = {}; self.status = "idle" end
    self.revision = self.revision + 1
    PublishFeatureUpdate(Trade, self.revision, "sellable")
    return true
end

function TA:CancelRequestTimeout()
    if S.Scheduler ~= nil and type(S.Scheduler.RemoveTask) == "function" then S.Scheduler:RemoveTask(self.requestTimeoutTask) end
end

-- 中文维护注释（trade-native-cooldown-1）：官方客户端会使用 GetSpecialtyRatioBetween 的返回值
-- 作为查询按钮冷却时间。旧实现忽略该值并固定 6.5 秒超时，可能在服务器仍处于查询冷却时
-- 先释放 SingleFlight，导致稍后到达的 SPECIALTY_RATIO_BETWEEN_INFO 被当成“无在飞请求”丢弃。
-- Authority 在这里统一维护冷却；Presentation 不猜时序，也不自行重复发请求。
function TA:GetNativeCooldownRemaining()
    local now = S.NowMs and tonumber(S.NowMs()) or 0
    return math.max(0, (tonumber(self.nextNativeRequestAt) or 0) - now)
end

function TA:CancelDeferredRequest()
    if S.Scheduler ~= nil and type(S.Scheduler.RemoveTask) == "function" then S.Scheduler:RemoveTask(self.requestDeferredTask) end
end

function TA:ArmDeferredRequest(delayMs)
    if S.Scheduler == nil or type(S.Scheduler.AddOneShot) ~= "function" then return false end
    self:CancelDeferredRequest()
    local delay = math.max(50, tonumber(delayMs) or 50)
    self.diag = type(self.diag) == "table" and self.diag or {}
    self.diag.deferredRequests = (tonumber(self.diag.deferredRequests) or 0) + 1
    return S.Scheduler:AddOneShot(self.requestDeferredTask, delay, function()
        local from, to = Number(Trade.State.fromZone), Number(Trade.State.toZone)
        if from == nil or to == nil then
            TA.pendingRoute = nil
            TA.status, TA.error = "idle", "请先选择完整路线"
            TA.revision = TA.revision + 1
            PublishFeatureUpdate(Trade, TA.revision, "route_deferred_cancelled")
            return true
        end
        return TA:Request(true)
    end, Trade, "P2", 1)
end

function TA:ArmRequestTimeout(serial, delayMs)
    if S.Scheduler == nil or type(S.Scheduler.AddOneShot) ~= "function" then return true end
    self:CancelRequestTimeout()
    -- 中文维护注释（trade-native-query-clock-2）：Native 返回值是“下一次允许查询”的按钮冷却，
    -- 不是当前 SPECIALTY_RATIO_BETWEEN_INFO 的网络响应 SLA。把二者绑定会在 RU 服务端只返回
    -- 冷却、不立即回调时把 UI 锁在 loading 数十秒。响应通道固定使用短 watchdog；冷却只节流重试。
    local delay = math.max(1000, tonumber(delayMs) or tonumber(self.responseSlaMs) or 6500)
    self.lastResponseTimeoutMs = delay
    return S.Scheduler:AddOneShot(self.requestTimeoutTask, delay, function()
        local flight = TA.inFlight
        if type(flight) ~= "table" or tonumber(flight.serial) ~= tonumber(serial) then return true end
        TA.inFlight = nil
        TA.diag = type(TA.diag) == "table" and TA.diag or {}
        TA.diag.responseTimeouts = (tonumber(TA.diag.responseTimeouts) or 0) + 1

        local pending = TA.pendingRoute
        TA.pendingRoute = nil
        if type(pending) == "table" and Number(Trade.State.fromZone) == Number(pending.from) and Number(Trade.State.toZone) == Number(pending.to) then
            -- 当前选择已经变成排队的新路线：旧请求不再允许晚到接管，直接追最新选择。
            TA.timedOutFlight = nil
            TA.pendingRetryCount = 0
            local started = TA:Request(false)
            if started == true then return true end
        end

        local currentFrom, currentTo = Number(Trade.State.fromZone), Number(Trade.State.toZone)
        local retryCount = tonumber(flight.retryCount) or 0
        if currentFrom == Number(flight.from) and currentTo == Number(flight.to) and retryCount < 1 then
            -- 同一路线允许一次有界重试。watchdog 到期后先释放 SingleFlight；若 Native 查询冷却仍在，
            -- 进入显式 cooldown 状态并等待冷却结束，而不是继续伪装成“正在查询”。在真正发出下一次
            -- 请求前保留 timedOutFlight，使没有新请求竞争时的迟到回调仍可安全归属于当前路线。
            TA.timedOutFlight = flight
            TA.pendingRetryCount = retryCount + 1
            local remaining = TA:GetNativeCooldownRemaining()
            if remaining > 0 then
                TA.pendingRoute = { from = currentFrom, to = currentTo }
                TA.status, TA.error = "cooldown", nil
                TA.revision = TA.revision + 1
                PublishFeatureUpdate(Trade, TA.revision, "route_request_waiting_native_cooldown")
                return TA:ArmDeferredRequest(remaining + 50)
            end
            TA.status, TA.error = "loading", nil
            TA.revision = TA.revision + 1
            PublishFeatureUpdate(Trade, TA.revision, "route_request_retry_after_timeout")
            return TA:Request(true)
        end

        TA.timedOutFlight = nil
        TA.pendingRetryCount = nil
        TA.status, TA.error = "error", "服务器货率查询超时，请点刷新重试"
        TA.revision = TA.revision + 1
        PublishFeatureUpdate(Trade, TA.revision, "route_request_timeout")
        return true
    end, Trade, "P2", 1)
end

function TA:Request(force)
    local from, to = Number(Trade.State.fromZone), Number(Trade.State.toZone)
    if from == nil or to == nil then self.status, self.rows = "idle", {}; return false, "请先选择完整路线" end
    if self.inFlight ~= nil then
        local same = tonumber(self.inFlight.from) == from and tonumber(self.inFlight.to) == to
        if same and force ~= true then return false, "路线查询仍在进行" end
        if same and force == true then
            -- Without a native request-id, issuing a second identical request
            -- would make the two callbacks indistinguishable. Keep the current
            -- request alive; Refresh becomes a visible no-op retry request.
            self.status, self.error = "loading", nil
            self.revision = self.revision + 1
            PublishFeatureUpdate(Trade, self.revision, "route_request_still_inflight")
            return true
        end
        -- Different route while one request is active: never overlap Native
        -- requests. Remember only the latest desired route and launch it after
        -- the current callback/timeout releases the lane.
        self.pendingRoute = { from = from, to = to }
        self.rows, self.status, self.error = {}, "loading", nil
        self.revision = self.revision + 1
        PublishFeatureUpdate(Trade, self.revision, "route_request_queued_latest")
        return true
    end
    local cooldownRemaining = self:GetNativeCooldownRemaining()
    if cooldownRemaining > 0 then
        -- 中文维护注释（trade-native-cooldown-1）：与官方 Specialty 窗口一致，服务器冷却期内不重复调用
        -- GetSpecialtyRatioBetween。当前路线已有 rows 时保留旧结果，直到真正发出刷新；切新路线则保持空表 loading。
        self.pendingRoute = { from = from, to = to }
        local sameRows = #self.rows > 0 and Number(self.rows[1] and self.rows[1].originZone) == from
            and Number(self.rows[1] and self.rows[1].destinationZone) == to
        if not sameRows then self.rows = {}; self.selectedKey = nil end
        self.status, self.error = "cooldown", nil
        self.revision = self.revision + 1
        PublishFeatureUpdate(Trade, self.revision, "route_request_deferred_cooldown")
        local deferredOk = self:ArmDeferredRequest(cooldownRemaining + 50)
        if deferredOk ~= true then
            self.status, self.error = "error", "货率冷却重试任务创建失败"
            self.revision = self.revision + 1
            PublishFeatureUpdate(Trade, self.revision, "route_deferred_guard_failed")
            return false, self.error
        end
        return true
    end

    -- 中文维护注释（trade-route-invalidate-1）：只有 Native 请求真正取得 SingleFlight lane 时才撤下旧 rows。
    -- 冷却等待期间同路线继续显示上一份可信结果；一旦真正发出查询，再进入 loading 防止旧路线被误认成新结果。
    self:CancelDeferredRequest()
    -- 真正发出新 Native 请求后，上一轮超时请求的迟到回调已经无法与新请求区分；撤销其归属资格。
    self.timedOutFlight = nil
    self.rows = {}
    self.selectedKey = nil
    self.requestSerial = (tonumber(self.requestSerial) or 0) + 1
    local serial = self.requestSerial
    local retryCount = tonumber(self.pendingRetryCount) or 0
    self.pendingRetryCount = nil
    self.inFlight = { from = from, to = to, serial = serial, retryCount = retryCount, startedAt = S.NowMs and S.NowMs() or 0 }
    self.pendingRoute = nil
    self.status, self.error = "loading", nil
    self.revision = self.revision + 1
    PublishFeatureUpdate(Trade, self.revision, force == true and "route_request_retry" or "route_request")
    local ok, nativeCooldownOrErr = Action("X2Store:GetSpecialtyRatioBetween", StoreApi, "GetSpecialtyRatioBetween", from, to)
    if ok ~= true then
        self.inFlight, self.status, self.error = nil, "error", nativeCooldownOrErr or "服务器未接受路线查询"
        self:CancelRequestTimeout()
        self.revision = self.revision + 1; PublishFeatureUpdate(Trade, self.revision, "route_request_failed")
        if self.pendingRoute ~= nil then return self:Request(false) end
        return false, self.error
    end
    local nativeCooldown = tonumber(nativeCooldownOrErr) or 0
    if nativeCooldown < 0 then nativeCooldown = 0 elseif nativeCooldown > 60000 then nativeCooldown = 60000 end
    self.lastNativeCooldownMs = nativeCooldown
    local now = S.NowMs and tonumber(S.NowMs()) or 0
    self.nextNativeRequestAt = now + nativeCooldown
    self.diag = type(self.diag) == "table" and self.diag or {}
    self.diag.nativeRequests = (tonumber(self.diag.nativeRequests) or 0) + 1
    self.diag.lastRequestAt = now
    self.diag.lastNativeCooldownMs = nativeCooldown
    -- Native cooldown 只控制下一次请求；本次响应使用独立短 watchdog，避免无回调时长期卡 loading。
    local responseTimeoutMs = tonumber(self.responseSlaMs) or 6500
    local timeoutOk = self:ArmRequestTimeout(serial, responseTimeoutMs)
    if timeoutOk ~= true then
        self.inFlight, self.status, self.error = nil, "error", "货率超时保护任务创建失败"
        self.revision = self.revision + 1
        PublishFeatureUpdate(Trade, self.revision, "route_timeout_guard_failed")
        return false, self.error
    end
    return true
end

function TA:OnRatio(info)
    local flight = self.inFlight
    local acceptedLate = false
    if type(flight) ~= "table" and type(self.timedOutFlight) == "table" then
        local late = self.timedOutFlight
        local currentFrom, currentTo = Number(Trade.State.fromZone), Number(Trade.State.toZone)
        -- 只在“没有更新的 Native 请求已经发出”且当前路线仍等于超时请求时接受迟到回调。
        -- 一旦实际发出新请求 Request() 会先清 timedOutFlight，因此不会把旧路线结果写进新请求。
        if currentFrom == Number(late.from) and currentTo == Number(late.to) then
            flight = late
            acceptedLate = true
        end
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
    if acceptedLate then self:CancelDeferredRequest() end
    self.pendingRetryCount = nil
    self.diag = type(self.diag) == "table" and self.diag or {}
    self.diag.callbackCount = (tonumber(self.diag.callbackCount) or 0) + 1
    if acceptedLate then self.diag.lateCallbacksAccepted = (tonumber(self.diag.lateCallbacksAccepted) or 0) + 1 end
    self.diag.lastCallbackAt = S.NowMs and S.NowMs() or 0
    local currentFrom, currentTo = Number(Trade.State.fromZone), Number(Trade.State.toZone)
    local staleForCurrentSelection = currentFrom ~= Number(flight.from) or currentTo ~= Number(flight.to)
    if staleForCurrentSelection then
        local pending = self.pendingRoute
        self.pendingRoute = nil
        if currentFrom ~= nil and currentTo ~= nil then
            self.rows, self.status, self.error = {}, "loading", nil
            self.revision = self.revision + 1
            PublishFeatureUpdate(Trade, self.revision, "route_result_superseded")
            return self:Request(false)
        end
        -- Changing the origin intentionally clears toZone. The superseded
        -- callback must NOT leave the panel in "loading" with empty rows and
        -- no re-arm path (the SetFrom dead corner) -- drop to an explicit
        -- idle prompt instead.
        self.rows, self.status, self.error = {}, "idle", "请先选择完整路线"
        self.revision = self.revision + 1
        PublishFeatureUpdate(Trade, self.revision, "route_result_superseded_idle")
        return true
    end
    self.pendingRoute = nil
    if type(info) ~= "table" then
        self.status, self.error = "error", "货率返回为空"
        self.revision = self.revision + 1
        PublishFeatureUpdate(Trade, self.revision, "ratio_result_invalid")
        return false
    end
    local rows = {}
    for _, value in pairs(info) do
        if type(value) == "table" then
            local item = type(value.itemInfo) == "table" and value.itemInfo or value
            local name = item.name or item.itemName or value.name
            local ratio = Number(value.ratio or value.rate or value.percentage)
            if name ~= nil and ratio ~= nil then
                local payout = S.Services and S.Services.TradePayoutV3 or nil
                local displayName = type(payout) == "table" and type(payout.ResolveDisplayName) == "function"
                    and payout:ResolveDisplayName(name) or Text(name)
                -- The ratio row's product itemType is the live craft-identity
                -- Authority for packs the static tables cannot name. RU shape
                -- unproven: extract bounded, fail to nil and stay static-only.
                local rowItemType = Number(item.itemType or item.itemTypeId or item.item_type or item.typeId
                    or value.itemType or value.itemTypeId or value.typeId)
                local row = {
                    key = tostring(flight.from) .. ":" .. tostring(flight.to) .. ":" .. tostring(name),
                    name = displayName, sourceName = Text(name), currentRatio = ratio, ratio = ratio,
                    originZone = flight.from, destinationZone = flight.to, itemType = rowItemType,
                }
                ApplyTradeDisplayModeToRow(row)
                rows[#rows + 1] = row
            end
        end
    end
    SortTradeRows(rows)
    if self.selectedKey ~= nil then
        local found = false
        for _, row in ipairs(rows) do if tostring(row.key or "") == tostring(self.selectedKey) then found = true; break end end
        if not found then self.selectedKey = nil end
    end
    self.rows, self.status, self.error = rows, (#rows > 0 and "ready" or "error"), (#rows > 0 and nil or "服务器返回的货率列表为空")
    self.revision = self.revision + 1
    PublishFeatureUpdate(Trade, self.revision, "ratio_result")
    RequestPendingLiveIdentities()
    TraceInit("ratio_result", "rows=" .. tostring(#rows) .. " from=" .. tostring(flight.from) .. "->" .. tostring(flight.to))
    return #rows > 0
end
function TA:DescribeRequestState()
    local flight = type(self.inFlight) == "table" and self.inFlight or nil
    local pending = type(self.pendingRoute) == "table" and self.pendingRoute or nil
    local now = S.NowMs and S.NowMs() or 0
    return {
        selectedRoute = tostring(Number(Trade.State.fromZone) or "-") .. "->" .. tostring(Number(Trade.State.toZone) or "-"),
        activeRoute = flight ~= nil and (tostring(flight.from) .. "->" .. tostring(flight.to)) or "none",
        requestAge = flight ~= nil and math.max(0, math.floor((tonumber(now) or 0) - (tonumber(flight.startedAt) or 0))) or 0,
        pendingRoute = pending ~= nil and (tostring(pending.from) .. "->" .. tostring(pending.to)) or "none",
        droppedCallbacks = type(self.diag) == "table" and tonumber(self.diag.droppedCallbacks) or 0,
        callbackCount = type(self.diag) == "table" and tonumber(self.diag.callbackCount) or 0,
        nativeRequests = type(self.diag) == "table" and tonumber(self.diag.nativeRequests) or 0,
        deferredRequests = type(self.diag) == "table" and tonumber(self.diag.deferredRequests) or 0,
        lastCallbackAt = type(self.diag) == "table" and tonumber(self.diag.lastCallbackAt) or 0,
        nativeCooldownMs = tonumber(self.lastNativeCooldownMs) or 0,
        cooldownRemainingMs = self:GetNativeCooldownRemaining(),
        responseTimeoutMs = tonumber(self.lastResponseTimeoutMs) or 0,
        responseSlaMs = tonumber(self.responseSlaMs) or 6500,
        responseTimeouts = type(self.diag) == "table" and tonumber(self.diag.responseTimeouts) or 0,
        lateCallbacksAccepted = type(self.diag) == "table" and tonumber(self.diag.lateCallbacksAccepted) or 0,
        timedOutRoute = type(self.timedOutFlight) == "table" and (tostring(self.timedOutFlight.from) .. "->" .. tostring(self.timedOutFlight.to)) or "none",
        status = tostring(self.status or "idle"),
    }
end

function TA:GetProjection()
    return {
        revision = self.revision, zones = Copy(self.zones), sellableZones = Copy(self.sellableZones), rows = Copy(self.rows),
        status = self.status, error = self.error, fromZone = Trade.State.fromZone, toZone = Trade.State.toZone,
        zoneFallback = self.zoneFallback == true, sellableFallback = self.sellableFallback == true, sellableError = self.sellableError,
        pendingQuoteCount = PendingTradeQuoteCount(self.rows),
        quoteInFlightCount = InFlightTradeQuoteCount(self.rows),
        nativeCooldownMs = tonumber(self.lastNativeCooldownMs) or 0,
        cooldownRemainingMs = self:GetNativeCooldownRemaining(),
        responseTimeoutMs = tonumber(self.lastResponseTimeoutMs) or 0,
        unresolvedIdentityCount = UnresolvedTradeIdentityCount(self.rows),
        favorites = Trade:GetFavorites(), favoriteItems = Trade:GetFavoriteItems(),
        currentFavoriteKey = Trade:FavoriteKey(Trade.State.fromZone, Trade.State.toZone),
        currentRouteFavorite = Trade:IsFavorite(Trade.State.fromZone, Trade.State.toZone),
        selectedKey = self.selectedKey, sortMode = Trade.State.sortMode,
        ratioMode = Trade.State.ratioMode, fullRatio = TRADE_FULL_RATIO,
        commerceMode = Trade.State.commerceMode, commerceSkill = self.commerceSkill, commerceStatus = self.commerceStatus,
        commerceName = self.commerceName, commerceError = self.commerceError,
        priceIncludesCommerce = Trade.State.commerceMode ~= "off" and self.commerceStatus == "ready",
        commercePriceFormulaStatus = "supplied_working_v1",
        packPriceMultiplierStatus = "supplied_working_v1",
        payoutCalculator = type(S.Services and S.Services.TradePayoutV3) == "table"
            and S.Services.TradePayoutV3:Describe() or nil,
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

Trade.ApiDependencies = { "X2Store:GetProductionZoneGroups", "X2Store:GetSellableZoneGroups", "X2Store:GetSpecialtyRatioBetween", "X2Ability:GetAllMyActabilityInfos" }
function Trade:Initialize()
    if type(S.Services and S.Services.TradePayoutV3) ~= "table" then return false, "跑商售价计算服务不可用" end
    return LoadStore(self)
end
function Trade:ReconcileDemand(_, before, after)
    local beforeCount = tonumber(before and before.count) or 0
    local afterCount = tonumber(after and after.count) or 0
    if beforeCount <= 0 and afterCount > 0 then
        TraceInit("demand_start", "consumer=" .. tostring(afterCount) .. " enabled=" .. tostring(self.enabled == true)
            .. " storeLoaded=" .. tostring(self.storeLoaded == true)
            .. " route=" .. tostring(Number(Trade.State.fromZone) or "-") .. "->" .. tostring(Number(Trade.State.toZone) or "-"))
        if S.Events ~= nil then
            S.Events:BindOwner(self, self.Id)
            if S.Events:SubscribeOptional("SPECIALTY_RATIO_BETWEEN_INFO", self, function(_, info) return TA:OnRatio(info) end) ~= true then
                self.eventUnavailable = true
                TraceInit("event_subscribe_failed", "SPECIALTY_RATIO_BETWEEN_INFO")
                return false, "SPECIALTY_RATIO_BETWEEN_INFO 订阅失败"
            end
            self.eventUnavailable = false
        end
        self.Authority:RefreshCommerceSkill()
        self.Authority:RefreshZones()
        -- 中文维护注释（trade-home-first-consumer-1）：Trade 路线配置是持久化的，但 Demand 0->1 过去只恢复
        -- 地区/目的地下拉列表，不会为已经完整保存的路线发货率查询。首页因此会显示“已选路线 + 暂无货率”，
        -- 直到用户再切一次目的地或进入完整跑商页。首次可见 Consumer 取得 Authority 后，若当前路线完整、没有
        -- 可信 rows 且没有请求在飞，则只发一次标准 Request；SingleFlight/Native 冷却仍由 TA 统一管理。
        if Number(Trade.State.fromZone) ~= nil and Number(Trade.State.toZone) ~= nil
            and #(TA.rows or {}) == 0 and TA.inFlight == nil then
            local requested, requestErr = TA:Request(false)
            if requested ~= true then
                TraceInit("demand_route_query_deferred", tostring(requestErr or "request_not_started"))
            end
        end
        TraceInit("demand_init_done", "zones=" .. tostring(#(TA.zones or {})) .. "/" .. tostring(#(TA.sellableZones or {}))
            .. " fallback=" .. tostring(TA.zoneFallback == true) .. "/" .. tostring(TA.sellableFallback == true)
            .. " commerce=" .. tostring(TA.commerceStatus or "-"))
    elseif beforeCount > 0 and afterCount <= 0 and S.Events ~= nil then
        S.Events:UnsubscribeOwner(self)
        TA.inFlight = nil
        TA.pendingRoute = nil
        TA.pendingRetryCount = nil
        TA.timedOutFlight = nil
        TA:CancelRequestTimeout()
        TA:CancelDeferredRequest()
        TA:CancelLiveIdentities()
        self:CancelQuoteBatch("no_consumers")
    end
    return true
end
function Trade:Enable() self.enabled = true; TraceInit("enable", "feature enabled"); return true end
function Trade:Disable(reason) local ok, err = self.Demand:Clear(reason or "trade_disable"); if ok ~= true then return false, err end; if S.Events then S.Events:UnsubscribeOwner(self) end; self:CancelQuoteBatch(reason or "disabled"); self.enabled = false; TA.inFlight = nil; TA.pendingRoute = nil; TA.pendingRetryCount = nil; TA.timedOutFlight = nil; TA:CancelRequestTimeout(); TA:CancelDeferredRequest(); TA:CancelLiveIdentities(); TraceInit("disable", tostring(reason or "trade_disable")); return true end
function Trade:AcquireConsumer(token) if not self.enabled then return false, "跑商功能已关闭" end return self.Demand:Acquire(token, {}, "trade_consumer") end
function Trade:ReleaseConsumer(token) return self.Demand:Release(token, "trade_consumer") end
function Trade:Refresh(reason)
    if not self.enabled or self.consumerCount <= 0 then return true end
    TA:RefreshCommerceSkill()
    local zonesOk, zonesErr = TA:RefreshZones()
    if zonesOk ~= true then return false, zonesErr end
    if Number(Trade.State.fromZone) ~= nil and Number(Trade.State.toZone) ~= nil then
        return TA:Request(true)
    end
    return true
end
function Trade:GetProjection()
    local projection=TA:GetProjection()
    projection.quoteBatch=self:GetQuoteBatch()
    return projection
end
function Trade:GetRouteSettings() return { fromZone = Trade.State.fromZone, toZone = Trade.State.toZone, sortMode = Trade.State.sortMode, ratioMode = Trade.State.ratioMode, commerceMode = Trade.State.commerceMode } end
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
    local ok, err = self:SetFrom(selected.fromZone)
    if ok ~= true then return false, err end
    return self:SetTo(selected.toZone)
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
        TA.pendingRoute = currentTo ~= nil and { from = nextFrom, to = currentTo } or nil
        TA.rows = {}
        if TA.inFlight ~= nil then
            TA.status, TA.error = "loading", nil
        elseif TA.pendingRoute ~= nil then
            TA.status, TA.error = "loading", nil
            TA:Request(false)
        end
    else
        TA.pendingRoute = nil
        TA.rows, TA.status, TA.error = {}, "idle", nil
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
            return TA:Request(true) -- 中文维护注释：目的地选择与收藏重选允许作为明确的用户重试/确认请求，避免同路线查询期间报“路线查询仍在进行”错误。
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
function Trade:QuoteMaterial(materialKey,mode,batch)
    -- 维护：详情/旧Command也必须经过功能生命周期门，不允许关闭后重新入队。
    if not self.enabled then return false,"跑商功能已关闭" end
    local metaTable=S.Data and S.Data.TradeMaterialAuctionMeta
    local item=type(metaTable)=="table" and metaTable[materialKey] or nil
    local itemType,itemGrade=item and tonumber(item.itemType),item and tonumber(item.itemGrade)
    if not itemType then return false,"该材料没有已验证的拍卖行身份，无法询价" end
    local queue=S.Services and S.Services.PriceQuoteQueueV3
    if not queue or type(queue.RequestQuote)~="function" then return false,"报价服务不可用" end
    itemGrade=itemGrade or (item and tonumber(item.gradeOffset) and tonumber(item.gradeOffset)+1) or 1
    local grades={itemGrade};local seen={[itemGrade]=true}
    if mode=="full" then
        for grade=0,6 do if not seen[grade] then grades[#grades+1]=grade;seen[grade]=true end end
    end
    local generation=self.quoteGeneration
    local searchName=mode=="full" and LocalizedTradeItemName(itemType,nil) or nil
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
function Trade:_StartMaterialBatch(rows,mode)
    if not self.enabled then return false,"跑商功能已关闭" end
    if self.quoteBatch.active then return true,"询价中 "..self.quoteBatch.completed.."/"..self.quoteBatch.total,0,0 end
    local queue=S.Services and S.Services.PriceQuoteQueueV3
    if not queue then return false,"报价服务不可用" end
    local now=type(S.NowMs)=="function" and S.NowMs() or 0
    local selected,seen,deferred={}, {}, 0
    for _,row in ipairs(rows or {}) do
        for _,m in ipairs(row.materialRows or {}) do
            local meta=S.Data and S.Data.TradeMaterialAuctionMeta and S.Data.TradeMaterialAuctionMeta[m.materialKey]
            local id=meta and tonumber(meta.itemType)
            local grade=meta and (tonumber(meta.itemGrade) or (tonumber(meta.gradeOffset) and tonumber(meta.gradeOffset)+1)) or 1
            local key=id and (tostring(id)..":"..tostring(grade))
            local state=id and queue:GetQuoteStateByItemType(id,grade)
            local cooling=state and state.status=="failed" and now-(state.at or 0)>=0 and now-(state.at or 0)<queue.negativeTtlMs
            local missing=m.costStatus=="explicit_quote_required" or m.costStatus=="quote_failed" or m.costStatus=="quoted_reference"
            if key and not seen[key] and (missing or mode=="full") then
                seen[key]=true
                if (cooling and mode~="full") or #selected>=4 then deferred=deferred+1
                else selected[#selected+1]=m.materialKey end
            end
        end
    end
    if #selected==0 then return false,"没有可询价材料；已有缓存/失败冷却期内，或尚未选择路线",0,deferred end
    self.quoteGeneration=self.quoteGeneration+1
    local batch={id=self.quoteGeneration,active=true,total=#selected,completed=0,ready=0,failed=0,mode=mode or "basic",deferred=deferred}
    self.quoteBatch=batch
    for _,key in ipairs(selected) do
        local ok,err=self:QuoteMaterial(key,mode,batch)
        if not ok then batch.completed=batch.completed+1;batch.failed=batch.failed+1;batch.error=tostring(err) end
    end
    batch.active=batch.completed<batch.total
    TA.revision=TA.revision+1;PublishFeatureUpdate(self,TA.revision,"quote_batch")
    return true,"本批 "..batch.total.." 项（最多4项）；剩余/冷却 "..deferred,batch.total,deferred
end
function Trade:QuotePendingMaterials(mode) return self:_StartMaterialBatch(TA.rows,mode) end
function Trade:QuoteRowMaterials(rowKey,mode)
    local row=self:GetRow(rowKey);if not row then return false,"贸易品已不在当前路线结果中" end
    return self:_StartMaterialBatch({row},mode)
end

-- Diagnostics reads describe helpers off the Feature table (S.Features.Trade),
-- but the request/identity state lives on the Authority. Bonds defines its
-- describe helpers directly on the feature table, which is why its row always
-- rendered; expose the same reachability here or the 跑商 row degrades to
-- "状态机诊断不可用" forever.
function Trade:DescribeRequestState() return TA:DescribeRequestState() end
function Trade:DescribeIdentityState() return TA:DescribeIdentityState() end
Trade.Commands = { Refresh = function(_, reason) return Trade:Refresh(reason) end, SetFrom = function(_, id) return Trade:SetFrom(id) end, SetTo = function(_, id) return Trade:SetTo(id) end,
    SetSortMode = function(_, mode) return Trade:SetSortMode(mode) end,
    SetRatioMode = function(_, mode) return Trade:SetRatioMode(mode) end, SetCommerceMode = function(_, mode) return Trade:SetCommerceMode(mode) end,
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
    progressConsumerToken = "feature:life_bonds:quest_progress", progressConsumerHeld = false, progressSubscribed = false }
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
Bonds.MultiContinentSnapshotContractVersion = 1
InstallLifeWidgetContract(Bonds, { defaultWidth = 500, defaultHeight = 330, minWidth = 280, minHeight = 150, defaultOverallOpacity = 0.94, defaultBackgroundOpacity = 1.0, defaultTextOpacity = 1.0 })
Bonds.Authority = { version = 2, revision = 0, rows = {}, status = "idle", error = nil, boardScope = "unknown", faction = nil }
local BA = Bonds.Authority
local function BondMaterialKey(itemType)
    for key, value in pairs(S.Constants and S.Constants.BondMaterialItemTypes or {}) do
        if tonumber(value) == tonumber(itemType) then return key end
    end
    return nil
end
local function BondItemType(item) return item.itemType or item.itemTypeId or item.typeId or item.item_type end
local function BondItemCount(item) return Number(item.stackCount or item.stack or item.count or item.itemCount or item.amount or item.stackSize or item.quantity) end
local QUEST_STATUS_TEXT = { COMPLETED = "已完成", READY_TO_TURN_IN = "可交付", IN_PROGRESS = "进行中", NOT_ACCEPTED = "未接", UNKNOWN = "待确认" }
local QUEST_STATUS_TONE = { COMPLETED = "green", READY_TO_TURN_IN = "orange", IN_PROGRESS = "yellow", NOT_ACCEPTED = "muted", UNKNOWN = "muted" }
local function BondQuestEvidence(materialKey, text)
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
    local line, token = tostring(text or ""), nil
    if string.find(line, "金闪闪", 1, true) and string.find(line, "袋", 1, true) then token = "golden_bag"
    elseif string.find(line, "王子", 1, true) and (string.find(line, "杂货箱", 1, true) or string.find(line, "杂物箱", 1, true)) then token = "prince_box"
    elseif string.find(line, "女王", 1, true) and string.find(line, "袋", 1, true) then token = "queen_bag"
    elseif string.find(line, "女王", 1, true) and (string.find(line, "杂货箱", 1, true) or string.find(line, "杂物箱", 1, true)) then token = "queen_box"
    elseif string.find(line, "继承者", 1, true) and string.find(line, "袋", 1, true) then token = "heir_bag"
    elseif string.find(line, "继承者", 1, true) and (string.find(line, "杂货箱", 1, true) or string.find(line, "杂物箱", 1, true)) then token = "heir_box" end
    local map = token and S.Constants and S.Constants.AuroriaBondQuestByTokenQuantity and S.Constants.AuroriaBondQuestByTokenQuantity[token]
    local quantity = quantityFromMap(map)
    if quantity ~= nil then return map[quantity], quantity, token end
    return nil, nil, token
end
-- BondDateCache removed 2026-09-02: S.State 永远 nil (replicatedsuite.lua 显式置 nil
-- + foundation_gate 断言), 整个函数返回 nil, 调用方 cache 逻辑不可达.
-- 大陆债券完成状态由 questStatus 直接决定, 无缓存层.
local function ReadBondResources()
    local totals, expected = {}, {}
    for key in pairs(S.Constants and S.Constants.BondMaterialItemTypes or {}) do totals[key] = 0; expected[key] = true end
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
    return #out.boards > 0 and out or nil
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
    return { sortMode = value.sortMode == "quantity" and "quantity" or "continent",
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
    if continentKey == "auroria" or materialKey == nil or tonumber(quantity) == nil then return nil end
    return tostring(materialKey) .. ":" .. tostring(math.floor(tonumber(quantity)))
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
function BA:Refresh()
    local rows = {}
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

    local resources, resourceStatus = ReadBondResources()
    local currentKey = CurrentBondContinentKey()
    local currentSnapshot = currentKey and state.dailySnapshots[currentKey] or nil
    local firstError = nil

    local lastReadable, lastContentCount = 0, 0
    -- Capture at most once per continent/server day. Reloading, sorting and
    -- filtering reuse the persisted snapshot and do not touch ResidentBoard.
    if currentSnapshot == nil and (currentKey ~= nil or next(state.dailySnapshots) == nil) then
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
        end
        lastReadable, lastContentCount = readable, contentCount
        -- Auroria is identifiable from its distinct 5/6 board families even if
        -- the zone-id map does not know the current zone yet.
        if currentKey == nil then
            local hasAuroria = #(boards[5].contents or {}) > 0 or #(boards[6].contents or {}) > 0
            if hasAuroria then currentKey = "auroria" end
        end
        if currentKey ~= nil and readable > 0 and contentCount > 0 then
            local captured = CaptureBondSnapshot(currentKey, boards)
            if captured ~= nil then
                state.dailySnapshots[currentKey] = captured
                Bonds.State.dailySnapshots[currentKey] = Copy(captured)
                currentSnapshot = captured
                snapshotDirty = true
            end
        end
    end

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
                    if not materialKey and index >= 5 then materialKey = "auroria_token" end
                    local quantity = Number(string.match(textValue, "(%d+)"))
                    local requiredCount, haveCount = quantity, materialKey and resources[materialKey] or nil
                    local rowStatus = materialKey and resourceStatus or "unknown"
                    if resourceStatus == "unknown" or resourceStatus == "partial" then haveCount = nil end
                    if materialKey == "auroria_token" then haveCount, rowStatus = nil, "unknown" end

                    local questId, mappedQuantity, auroriaToken = BondQuestEvidence(materialKey, textValue)
                    quantity = mappedQuantity or quantity
                    requiredCount = mappedQuantity or requiredCount
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
                            board = index, name = BOND_BOARD_NAMES[index] or ("分类" .. tostring(index)),
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

    -- 中文维护注释（2026-09-15，排序只排序不删数据）：continentOrder 与 duplicate priority 完全分离。
    -- 按大陆模式先比较大陆，按数量模式先比较数量；两种模式都使用同一个确定性 tie-breaker。这样切换
    -- “西→东/东→西”只改变行顺序，不会触发去重，也不会修改快照。原大陆始终排在两主大陆之后。
    local continentRank = state.continentOrder == "east_first"
        and { east = 1, west = 2, auroria = 3 } or { west = 1, east = 2, auroria = 3 }
    local materialRank = { leather = 1, fabric = 2, lumber = 3, iron = 4 }
    table.sort(rows, function(a, b)
        local ac, bc = continentRank[a.continentKey] or 9, continentRank[b.continentKey] or 9
        local aq, bq = Number(a.quantity), Number(b.quantity)
        if state.sortMode == "quantity" then
            if aq ~= bq then
                if aq == nil then return false end
                if bq == nil then return true end
                return aq < bq
            end
            if ac ~= bc then return ac < bc end
        else
            if ac ~= bc then return ac < bc end
            -- 中文维护注释：按大陆模式只负责把同一大陆聚在一起，组内继续保持居民板 1→7 的
            -- 自然顺序；不能再按数量二次重排，否则“按大陆”仍会改变板位阅读顺序并让语义模糊。
            local ab, bb = Number(a.board) or 99, Number(b.board) or 99
            if ab ~= bb then return ab < bb end
        end
        local am, bm = materialRank[a.materialKey] or 9, materialRank[b.materialKey] or 9
        if am ~= bm then return am < bm end
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
        if Bonds.enabled == true and Bonds.consumerCount > 0 then BA:Refresh() end
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
        -- Demand 0->1 在 QuestProgress 已完成一次同步刷新后再重算 Bonds，确保首次打开也使用最新 activeIndex。
        BA:Refresh()
    elseif beforeCount > 0 and afterCount <= 0 then
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
function Bonds:Refresh() if not self.enabled or self.consumerCount <= 0 then return true end return BA:Refresh() end
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
    }
end
function Bonds:GetSortMode() return Bonds.State.sortMode end
function Bonds:SetSortMode(mode)
    local persisted, persistErr = PersistLifeMutation(self, "bonds_sort", function(state) state.sortMode = mode == "quantity" and "quantity" or "continent"; return true end)
    if persisted ~= true then return false, persistErr end
    return self:Refresh()
end
function Bonds:GetContinentOrder() return NormalizeBondState(Bonds.State).continentOrder end
function Bonds:SetContinentOrder(order)
    if order ~= "west_first" and order ~= "east_first" then return false, "大陆排序方向无效" end
    -- 中文维护注释：大陆顺序是纯 Presentation 偏好，但由 Bonds Store 持久化并由 Authority 排序，
    -- 这样主页面/悬浮窗共享同一顺序。该命令不读 ResidentBoard、不修改 dailySnapshots，也不触发去重。
    local persisted, persistErr = PersistLifeMutation(self, "bonds_continent_order", function(state) state.continentOrder = order; return true end)
    if persisted ~= true then return false, persistErr end
    return self:Refresh()
end
function Bonds:GetBondFilter() return NormalizeBondState(Bonds.State) end
function Bonds:GetBondFilterOption(key) return Bonds:GetBondFilter()[key] == true end
function Bonds:GetDuplicatePriority() return Bonds:GetBondFilter().priority end
function Bonds:SetBondFilterOption(key, enabled)
    if key ~= "q20" and key ~= "q60" and key ~= "q100" and key ~= "auroria" and key ~= "excludeSame" then return false, "债券筛选键无效" end
    local persisted, persistErr = PersistLifeMutation(self, "bonds_filter", function(state) state[key] = enabled == true; return true end)
    if persisted ~= true then return false, persistErr end
    return self:Refresh()
end
function Bonds:SetDuplicatePriority(priority)
    if priority ~= "west" and priority ~= "east" then return false, "重复材料优先大陆无效" end
    -- 中文维护注释（2026-09-15，合并优先级无副作用）：旧实现会在选择“优先西/东”时顺手把
    -- excludeSame=true，导致用户只是想改顺序/偏好却突然少一整个大陆的重复行。priority 现在只保存
    -- “合并模式下保留哪一侧”，是否合并只能由 SetBondFilterOption(excludeSame) 显式决定。
    local persisted, persistErr = PersistLifeMutation(self, "bonds_priority", function(state) state.priority = priority; return true end)
    if persisted ~= true then return false, persistErr end
    return self:Refresh()
end
Bonds.Commands = { Refresh = function(_, reason) return Bonds:Refresh(reason) end, SetSortMode = function(_, mode) return Bonds:SetSortMode(mode) end, SetContinentOrder = function(_, order) return Bonds:SetContinentOrder(order) end, SetBondFilterOption = function(_, key, enabled) return Bonds:SetBondFilterOption(key, enabled) end, SetDuplicatePriority = function(_, priority) return Bonds:SetDuplicatePriority(priority) end,
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
Treasure.MapLocationContractVersion = 1 -- 中文维护注释（2026-09-16，原生地图定位）：v1 表示选中藏宝图可经 Feature Command 显式调用 X2Map:ShowWorldmapLocation；Presentation 不直接执行 Native 写动作。
Treasure.State = { selectedKey = nil, widgetVisible = false, widgetWindow = nil }
InstallLifeWidgetContract(Treasure, { defaultWidth = 390, defaultHeight = 220, minWidth = 240, minHeight = 120, defaultOverallOpacity = 0.94, defaultBackgroundOpacity = 1.0, defaultTextOpacity = 1.0 })
Treasure.Authority = { version = 2, revision = 0, maps = {}, selected = nil, status = "idle", error = nil, lastMapActionError = nil, mapOpenAttempts = 0 }
local XA = Treasure.Authority
local TREASURE_MAP_CONTEXT_ID = 2 -- 中文维护注释：用户提供的 RU 实机可用 TreasureMapHunter 对 ShowWorldmapLocation 的首参固定传 2。bundled manifest 只给出参数名而没有语义保证，因此这里把它定义为“参考插件已验证的地图上下文值”，不擅自解释成当前 ZoneGroup/World，也不从别的 API 猜值。
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
        name = name, text = text, worldX = worldX, worldY = worldY, mapContextId = TREASURE_MAP_CONTEXT_ID,
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
Treasure.ApiDependencies = { "X2Bag:GetBagItemInfo", "X2Bag:Capacity", "X2Unit:GetUnitWorldPositionByTarget", "X2Map:ShowWorldmapLocation" } -- 中文维护注释：地图 API 只在显式 Command 点击时执行；加入依赖仅确保 FeatureRuntime 惰性导入 X2Map namespace，不启动任何地图观察。
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
function Treasure:ShowSelectedOnMap()
    -- 中文维护注释（2026-09-16，Native 写边界）：地图打开属于显式用户动作，只能从 Command 进入并经 Capability Gate；
    -- Scheduler/UpdatePosition 永远不能调用它。失败只记录诊断并保留当前选择/距离追踪，不清 Store、不切换藏宝图，避免 UI 能力故障污染 Domain Authority。
    local map = XA.selected
    if type(map) ~= "table" then return false, "请先选择一张藏宝图" end
    local worldX, worldY = Number(map.worldX), Number(map.worldY)
    if worldX == nil or worldY == nil then return false, "藏宝图坐标不可用" end
    XA.mapOpenAttempts = (tonumber(XA.mapOpenAttempts) or 0) + 1
    local ok, mapErr = Action("X2Map:ShowWorldmapLocation", nil, "ShowWorldmapLocation", Number(map.mapContextId) or TREASURE_MAP_CONTEXT_ID, worldX, worldY, 0)
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
