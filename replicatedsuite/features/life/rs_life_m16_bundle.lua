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
    return S.Api:CallCapability(capability, object, method, ...)
end

local function Action(capability, object, method, ...)
    if S.Api == nil or type(S.Api.ActionCapability) ~= "function" then
        return false, "API boundary unavailable"
    end
    return S.Api:ActionCapability(capability, object, method, ...)
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
local function RegisterStore(id, owner, default, get, apply, migrate, budget)
    if P:GetStore(id) == nil then
        local store, err = P:RegisterV3Store({
            id = id, owner = owner, scope = P.Scope.Account, lifetime = P.Lifetime.Permanent,
            schemaVersion = 1, legacySchemaVersion = 0, key = P.V3KeyPrefix .. id:gsub("[^%w]", "_"),
            budget = budget or { maxDepth = 6, maxNodes = 320, maxStringBytes = 8192, maxEntriesPerTable = 160 },
            default = default, get = get, apply = apply, migrate = migrate or default,
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
InstallLifeWidgetContract(Trade, { defaultWidth = 470, defaultHeight = 374, minWidth = 320, minHeight = 254, defaultOverallOpacity = 0.94, defaultBackgroundOpacity = 1.0, defaultTextOpacity = 1.0 })
local TA = Trade.Authority
TA.RouteRefreshRetryContractVersion = 2
TA.SingleFlightLatestRouteContractVersion = 1
TA.RequestTimeoutContractVersion = 1
TA.requestTimeoutTask = "v3_trade_route_timeout"
TA.requestSerial = tonumber(TA.requestSerial) or 0
TA.pendingRoute = nil
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
function LocalizedTradeItemName(itemType, fallbackText)
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
            local quotedPrice, priceProvenance
            if type(quoteQueue) == "table" and type(quoteQueue.GetQuoteStateByItemType) == "function" then
                quoteState = quoteQueue:GetQuoteStateByItemType(itemType, itemGrade)
            end
            if quoteState ~= nil and quoteState.status == "ready" and quoteState.price ~= nil then
                quotedPrice, priceProvenance = quoteState.price, "live"
            elseif quoteState == nil and type(quoteQueue) == "table" and type(quoteQueue.GetPriceWithProvenance) == "function" then
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
    local changed = false
    for _, row in ipairs(self.rows or {}) do
        local affected = false
        for _, material in ipairs(type(row.materialRows) == "table" and row.materialRows or {}) do
            if material.materialKey == materialKey then affected = true; break end
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

function TA:ArmRequestTimeout(serial)
    if S.Scheduler == nil or type(S.Scheduler.AddOneShot) ~= "function" then return true end
    self:CancelRequestTimeout()
    return S.Scheduler:AddOneShot(self.requestTimeoutTask, 6500, function()
        local flight = TA.inFlight
        if type(flight) ~= "table" or tonumber(flight.serial) ~= tonumber(serial) then return true end
        TA.inFlight = nil
        local pending = TA.pendingRoute
        TA.pendingRoute = nil
        if type(pending) == "table" and Number(Trade.State.fromZone) == Number(pending.from) and Number(Trade.State.toZone) == Number(pending.to) then
            -- The timed-out request has released the single-flight lane. Start
            -- only the latest route the user still has selected.
            local started = TA:Request(false)
            if started == true then return true end
        end
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
    self.requestSerial = (tonumber(self.requestSerial) or 0) + 1
    local serial = self.requestSerial
    self.inFlight = { from = from, to = to, serial = serial, startedAt = S.NowMs and S.NowMs() or 0 }
    self.pendingRoute = nil
    self.status, self.error = "loading", nil
    self.revision = self.revision + 1
    PublishFeatureUpdate(Trade, self.revision, force == true and "route_request_retry" or "route_request")
    local ok, err = Action("X2Store:GetSpecialtyRatioBetween", StoreApi, "GetSpecialtyRatioBetween", from, to)
    if ok ~= true then
        self.inFlight, self.status, self.error = nil, "error", err or "服务器未接受路线查询"
        self:CancelRequestTimeout()
        self.revision = self.revision + 1; PublishFeatureUpdate(Trade, self.revision, "route_request_failed")
        -- The lane is free again; a queued latest route must not die with the
        -- failed dispatch. Relaunch it once (the recursive call re-reads the
        -- current selection, so the depth is bounded by route changes).
        if self.pendingRoute ~= nil then return self:Request(false) end
        return false, self.error
    end
    local timeoutOk = self:ArmRequestTimeout(serial)
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
    if type(flight) ~= "table" then
        -- Without a native request-id a callback that arrives after the
        -- timeout released the lane cannot be attributed safely. Dropping is
        -- the fail-closed choice (the timeout already re-armed the latest
        -- route), but it must be observable.
        self.diag = type(self.diag) == "table" and self.diag or {}
        self.diag.droppedCallbacks = (tonumber(self.diag.droppedCallbacks) or 0) + 1
        self.diag.lastCallbackAt = S.NowMs and S.NowMs() or 0
        return false
    end
    self.inFlight = nil
    self:CancelRequestTimeout()
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
        lastCallbackAt = type(self.diag) == "table" and tonumber(self.diag.lastCallbackAt) or 0,
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
    end, NormalizeTradeState)

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
        TraceInit("demand_init_done", "zones=" .. tostring(#(TA.zones or {})) .. "/" .. tostring(#(TA.sellableZones or {}))
            .. " fallback=" .. tostring(TA.zoneFallback == true) .. "/" .. tostring(TA.sellableFallback == true)
            .. " commerce=" .. tostring(TA.commerceStatus or "-"))
    elseif beforeCount > 0 and afterCount <= 0 and S.Events ~= nil then
        S.Events:UnsubscribeOwner(self)
        TA.inFlight = nil
        TA.pendingRoute = nil
        TA:CancelRequestTimeout()
        TA:CancelLiveIdentities()
    end
    return true
end
function Trade:Enable() self.enabled = true; TraceInit("enable", "feature enabled"); return true end
function Trade:Disable(reason) local ok, err = self.Demand:Clear(reason or "trade_disable"); if ok ~= true then return false, err end; if S.Events then S.Events:UnsubscribeOwner(self) end; self.enabled = false; TA.inFlight = nil; TA.pendingRoute = nil; TA:CancelRequestTimeout(); TA:CancelLiveIdentities(); TraceInit("disable", tostring(reason or "trade_disable")); return true end
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
function Trade:GetProjection() return TA:GetProjection() end
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
    for _, row in ipairs(TA.sellableZones or {}) do
        if row.id == Number(id) then
            local persisted, persistErr = PersistLifeMutation(self, "trade_to", function(state) state.toZone = row.id; return true end)
            if persisted ~= true then return false, persistErr end
            return TA:Request()
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
function Trade:QuoteMaterial(materialKey)
    local metaTable = S.Data and S.Data.TradeMaterialAuctionMeta or nil
    local item = type(metaTable) == "table" and metaTable[materialKey] or nil
    local itemType, itemGrade = item and tonumber(item.itemType) or nil, item and tonumber(item.itemGrade) or nil
    if itemType == nil then return false, "该材料没有已验证的拍卖行身份，无法询价" end
    local queue = S.Services ~= nil and S.Services.PriceQuoteQueueV3 or nil
    if type(queue) ~= "table" or type(queue.RequestQuote) ~= "function" then return false, "报价服务不可用" end
    -- Already queued/inflight for this itemType: report success without a
    -- duplicate native request; the existing entry's completion refreshes rows.
    if type(queue.GetQuoteStateByItemType) == "function" then
        local state = queue:GetQuoteStateByItemType(itemType, itemGrade)
        if state ~= nil and (state.status == "queued" or state.status == "inflight") then
            return true, "已在报价队列中"
        end
    end
    -- Grade ladder per the verified legacy protocol: the explicit hint first,
    -- then the 1..6 ladder and 0. The lowest listing grade often differs from
    -- the static hint; nil at one grade means "no listing at that grade".
    local gradeCandidates, seenGrades = {}, {}
    local function AddGrade(value)
        local n = tonumber(value)
        if n == nil or n ~= n or n < 0 or n > 20 or n ~= math.floor(n) or seenGrades[n] then return end
        seenGrades[n] = true
        gradeCandidates[#gradeCandidates + 1] = math.floor(n)
    end
    AddGrade(itemGrade)
    if itemGrade == nil and item ~= nil then
        AddGrade(tonumber(item.gradeOffset) ~= nil and math.floor(tonumber(item.gradeOffset)) + 1 or nil)
        AddGrade(item.gradeOffset)
    end
    for grade = 1, 6 do AddGrade(grade) end
    AddGrade(0)
    local quotedMaterialKey = materialKey
    -- Verified legacy fallback needs a localized display name: after the whole
    -- grade ladder proves there is no direct listing, one bounded auction search
    -- by name may still yield a reference bid price. Resolve through the shared
    -- Localization authority; never fabricate a keyword from the EN meta key.
    -- Keyword source is the same Localization Authority that renders the row. It
    -- can drift from live RU auction wording; _CheckFallback therefore cross-checks
    -- the returned row name and only rejects on a *positive* mismatch, so a stale
    -- entry degrades to "no match found" instead of silently discarding real hits.
    local searchName = LocalizedTradeItemName(itemType, nil)
    local ok, status = queue:RequestQuote("life_trade", itemType, itemGrade, function()
        return TA:RefreshQuotedMaterial(quotedMaterialKey)
    end, gradeCandidates, { searchName = searchName })
    if ok ~= true then return false, status or "报价请求失败" end
    return true, status or "queued"
end

function Trade:QuotePendingMaterials()
    local seen, requested, skipped = {}, 0, 0
    local queue = S.Services ~= nil and S.Services.PriceQuoteQueueV3 or nil
    local maxBatch = type(queue) == "table" and math.max(1, tonumber(queue.maxQueue) or 64) or 64
    for _, row in ipairs(TA.rows or {}) do
        for _, material in ipairs(type(row.materialRows) == "table" and row.materialRows or {}) do
            local key = material.materialKey
            if (material.costStatus == "explicit_quote_required" or material.costStatus == "quote_failed")
                and key ~= nil and seen[key] ~= true then
                seen[key] = true
                if requested >= maxBatch then
                    skipped = skipped + 1
                else
                    local ok = self:QuoteMaterial(key)
                    if ok == true then requested = requested + 1 else skipped = skipped + 1 end
                end
            end
        end
    end
    if requested == 0 and skipped == 0 then return false, "没有待询价材料（请先完成一次路线查询）", 0, 0 end
    return true, "已提交 " .. tostring(requested) .. " 项询价" .. (skipped > 0 and ("，" .. tostring(skipped) .. " 项暂未提交") or ""), requested, skipped
end
function Trade:QuoteRowMaterials(rowKey)
    local row = self:GetRow(rowKey)
    if row == nil then return false, "贸易品已不在当前路线结果中", 0, 0 end
    local seen, requested, skipped = {}, 0, 0
    local queue = S.Services ~= nil and S.Services.PriceQuoteQueueV3 or nil
    local maxBatch = type(queue) == "table" and math.max(1, tonumber(queue.maxQueue) or 64) or 64
    for _, material in ipairs(type(row.materialRows) == "table" and row.materialRows or {}) do
        local key = material.materialKey
        if (material.costStatus == "explicit_quote_required" or material.costStatus == "quote_failed")
            and key ~= nil and seen[key] ~= true then
            seen[key] = true
            if requested >= maxBatch then skipped = skipped + 1
            else
                local ok = self:QuoteMaterial(key)
                if ok == true then requested = requested + 1 else skipped = skipped + 1 end
            end
        end
    end
    if requested == 0 and skipped == 0 then return false, "该贸易品没有待询价材料", 0, 0 end
    return true, "已提交当前贸易品 " .. tostring(requested) .. " 项询价" .. (skipped > 0 and ("，" .. tostring(skipped) .. " 项暂未提交") or ""), requested, skipped
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
    QuotePendingMaterials = function() return Trade:QuotePendingMaterials() end, QuoteRowMaterials = function(_, rowKey) return Trade:QuoteRowMaterials(rowKey) end,
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
local Bonds = { Id = "life_bonds", storeId = "v3.life.bonds", enabled = false, storeLoaded = false }
S.Features.Bonds = Bonds
Bonds.UpdateTopic = "v3.life.bonds.updated"
Bonds.State = { sortMode = "continent", showCompleted = true, q20 = true, q60 = true, q100 = true, auroria = true, excludeSame = false, priority = "west", completionDateKey = nil, completedMainlandKeys = {}, dailyDateKey = nil, dailySnapshots = {}, widgetVisible = false, widgetWindow = nil }
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
    if S.Api == nil or S.Api:IsCapabilityAllowed("X2Bag:GetBagItemInfo") ~= true or S.Api:IsCapabilityAllowed("X2Bag:Capacity") ~= true then return totals, status end
    local capacityOk, capacity = Call("X2Bag:Capacity", BagApi, "Capacity")
    capacity = Number(capacity)
    if capacityOk ~= true or not capacity or capacity < 0 then return totals, status end
    local maxSlot = math.min(240, math.floor(capacity))
    local readCount, failed = 0, false
    for slot = 1, maxSlot do
        local ok, item = Call("X2Bag:GetBagItemInfo", BagApi, "GetBagItemInfo", 0, slot)
        if ok ~= true then failed = true
        else
            readCount = readCount + 1
            if type(item) == "table" then
                local itemType, count = BondItemType(item), BondItemCount(item)
                local key = BondMaterialKey(itemType)
                if key ~= nil then
                    -- Only a recognized bond material needs a stack count. An
                    -- unrelated unstacked bag item may legitimately omit a count
                    -- field and must not poison every bond row into `?`.
                    if count ~= nil then totals[key] = totals[key] + count else failed = true end
                elseif next(item) ~= nil and itemType == nil then
                    -- Occupied but identity-less rows could hide a bond material,
                    -- so keep the aggregate partial rather than under-counting.
                    failed = true
                end
            elseif item ~= nil then
                failed = true
            end
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
    return { sortMode = value.sortMode == "quantity" and "quantity" or "continent", showCompleted = value.showCompleted ~= false,
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
                        questStatus = tostring(progress:QuestState(questId) or "UNKNOWN")
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
                            resourceStatus = rowStatus, resourceText = haveCount and tostring(haveCount) or "?",
                            shortageText = requiredCount and haveCount and tostring(math.max(0, requiredCount - haveCount)) or "?",
                            questId = questId, questStatus = questStatus, completed = completed,
                            statusText = completed and "已完成" or (questStatus == "NOT_ACCEPTED" and "待确认" or (QUEST_STATUS_TEXT[questStatus] or "待确认")),
                            tone = completed and "green" or (questStatus == "NOT_ACCEPTED" and "muted" or (QUEST_STATUS_TONE[questStatus] or "muted")),
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

    if state.sortMode == "quantity" then
        local continentRank, materialRank = { west=1, east=2, auroria=3 }, { leather=1, fabric=2, lumber=3, iron=4 }
        table.sort(rows, function(a, b)
            local aq, bq = Number(a.quantity), Number(b.quantity)
            if aq ~= bq then
                if aq == nil then return false end
                if bq == nil then return true end
                return aq < bq
            end
            local ac, bc = continentRank[a.continentKey] or 9, continentRank[b.continentKey] or 9
            if ac ~= bc then return ac < bc end
            local am, bm = materialRank[a.materialKey] or 9, materialRank[b.materialKey] or 9
            if am ~= bm then return am < bm end
            return tostring(a.key) < tostring(b.key)
        end)
    end

    local capturedCount = 0
    for _, key in ipairs({ "west", "east", "auroria" }) do if state.dailySnapshots[key] ~= nil then capturedCount = capturedCount + 1 end end
    local status, errorText
    if capturedCount > 0 then
        status, errorText = "ready", nil
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
    return {
        revision = self.revision, rows = Copy(self.rows), status = self.status, resourceStatus = self.resourceStatus,
        error = self.error, duplicatePriorityUnresolved = self.duplicatePriorityUnresolved,
        boardScope = self.boardScope, faction = self.faction,
        snapshotDateKey = self.snapshotDateKey, snapshotCount = tonumber(self.snapshotCount) or 0,
    }
end
-- The daily snapshot domain nests 5 tables deep with up to 21 boards of CJK
-- text; the generic helper budget (depth 6 / 320 nodes) sat at the boundary
-- and silently starved the integrity upgrade's decode validation.
RegisterStore(Bonds.storeId, "v3.life.bonds", function() return NormalizeBondState(nil) end,
    function() return Copy(Bonds.State) end,
    function(value) Bonds.State = NormalizeBondState(value) end,
    NormalizeBondState,
    { maxDepth = 8, maxNodes = 960, maxStringBytes = 24576, maxEntriesPerTable = 192 })
Bonds.ApiDependencies = { "X2Resident:GetResidentBoardContent", "X2Bag:Capacity", "X2Bag:GetBagItemInfo", "X2Unit:GetCurrentZoneGroup" }
function Bonds:Initialize() return LoadStore(self) end
function Bonds:ReconcileDemand(_, before, after) if (tonumber(before and before.count) or 0) <= 0 and (tonumber(after and after.count) or 0) > 0 then BA:Refresh(); return true end return true end
function Bonds:Enable() self.enabled = true; return true end
function Bonds:Disable(reason) local ok, err = self.Demand:Clear(reason or "bonds_disable"); if ok ~= true then return false, err end; self.enabled = false; return true end
function Bonds:AcquireConsumer(token) if not self.enabled then return false, "居民板功能已关闭" end return self.Demand:Acquire(token, {}, "bonds_consumer") end
function Bonds:ReleaseConsumer(token) return self.Demand:Release(token, "bonds_consumer") end
function Bonds:Refresh() if not self.enabled or self.consumerCount <= 0 then return true end return BA:Refresh() end
-- Presentation must consume a detached Feature read model rather than reaching
-- through to Bonds.Authority. Keep this facade explicit so the public Feature
-- contract stays symmetric with Trade/Treasure/Fishing.
function Bonds:GetProjection() return BA:GetProjection() end

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
    local persisted, persistErr = PersistLifeMutation(self, "bonds_priority", function(state) state.priority = priority; state.excludeSame = true; return true end)
    if persisted ~= true then return false, persistErr end
    return self:Refresh()
end
Bonds.Commands = { Refresh = function(_, reason) return Bonds:Refresh(reason) end, SetSortMode = function(_, mode) return Bonds:SetSortMode(mode) end, SetBondFilterOption = function(_, key, enabled) return Bonds:SetBondFilterOption(key, enabled) end, SetDuplicatePriority = function(_, priority) return Bonds:SetDuplicatePriority(priority) end,
    GetWidgetVisible = function() return Bonds:GetWidgetVisible() end, SetWidgetVisible = function(_, value, reason) return Bonds:SetWidgetVisible(value, reason) end,
    SetWidgetWindowState = function(_, value, reason) return Bonds:SetWidgetWindowState(value, reason) end,
    MarkStoreDirty = function(_, delayMs, reason) return Bonds:MarkStoreDirty(delayMs, reason) end }
local bondsDemand, bondsErr = Demand:Create({ id = "feature:" .. Bonds.Id, owner = Bonds, projectionOwner = Bonds, projectionConsumersField = "consumers", projectionCountField = "consumerCount", reconcile = function(lease, before, after) return Bonds:ReconcileDemand(lease, before, after) end })
if bondsDemand == nil then error(bondsErr) end
Bonds.Demand = bondsDemand
ok, err = Runtime:RegisterImplementation(Bonds.Id, Bonds); if ok ~= true then error(err) end

------------------------------------------------------------------------
-- Treasure maps (direct bounded bag read; no Resource/Legacy dependency)
------------------------------------------------------------------------
local Treasure = { Id = "life_treasure", storeId = "v3.life.treasure", enabled = false, storeLoaded = false }
S.Features.Treasure = Treasure
Treasure.UpdateTopic = "v3.life.treasure.updated"
Treasure.ObservationContractVersion = 1
Treasure.State = { selectedKey = nil, widgetVisible = false, widgetWindow = nil }
InstallLifeWidgetContract(Treasure, { defaultWidth = 390, defaultHeight = 220, minWidth = 240, minHeight = 120, defaultOverallOpacity = 0.94, defaultBackgroundOpacity = 1.0, defaultTextOpacity = 1.0 })
Treasure.Authority = { version = 1, revision = 0, maps = {}, selected = nil, status = "idle", error = nil }
local XA = Treasure.Authority
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
function XA:Refresh()
    local maps, readable = {}, false
    if S.Api == nil or S.Api:IsCapabilityAllowed("X2Bag:GetBagItemInfo") ~= true then self.status, self.error = "unavailable", "X2Bag:GetBagItemInfo 被能力门阻止"; return false end
    local maxSlot = 150
    local okCapacity, capacity = Call("X2Bag:Capacity", BagApi, "Capacity")
    if okCapacity and Number(capacity) and Number(capacity) > 0 then maxSlot = math.min(240, math.floor(Number(capacity))) end
    for slot = 1, maxSlot do
        local ok, item = Call("X2Bag:GetBagItemInfo", BagApi, "GetBagItemInfo", 0, slot)
        if ok then
            readable = true
            if type(item) == "table" then
                local name = Text(item.name or item.itemName)
                local text = TreasureText(item)
                local wx, wy = Dms(item.longitudeDir, item.longitudeDeg, item.longitudeMin, item.longitudeSec, 21504), Dms(item.latitudeDir, item.latitudeDeg, item.latitudeMin, item.latitudeSec, 28672)
                if text and string.find(name, "藏宝图", 1, true) and wx and wy then maps[#maps + 1] = { key = text .. ":" .. tostring(slot), name = name, text = text, worldX = wx, worldY = wy, slot = slot, direction = "--", distance = nil } end
            end
        end
    end
    local selected = Treasure.State.selectedKey
    local found = false
    for _, map in ipairs(maps) do if map.key == selected then found = true; XA.selected = map end end
    if not found then XA.selected = maps[1]; selected = maps[1] and maps[1].key or nil; Treasure.State.selectedKey = selected end
    self.maps, self.selected, self.status, self.error = maps, self.selected, (#maps > 0 and "ready" or "empty"), nil
    self.revision = self.revision + 1
    PublishFeatureUpdate(Treasure, self.revision, "treasure_scan")
    return readable
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
function XA:GetProjection() return { revision = self.revision, maps = Copy(self.maps), selected = Copy(self.selected), status = self.status, error = self.error } end
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
Treasure.ApiDependencies = { "X2Bag:GetBagItemInfo", "X2Bag:Capacity", "X2Unit:GetUnitWorldPositionByTarget" }
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
Treasure.Commands = { Refresh = function(_, reason) return Treasure:Refresh(reason) end, Select = function(_, key) return Treasure:Select(key) end,
    GetWidgetVisible = function() return Treasure:GetWidgetVisible() end, SetWidgetVisible = function(_, value, reason) return Treasure:SetWidgetVisible(value, reason) end,
    SetWidgetWindowState = function(_, value, reason) return Treasure:SetWidgetWindowState(value, reason) end, MarkStoreDirty = function(_, delayMs, reason) return Treasure:MarkStoreDirty(delayMs, reason) end }
local treasureDemand, treasureErr = Demand:Create({ id = "feature:" .. Treasure.Id, owner = Treasure, projectionOwner = Treasure, projectionConsumersField = "consumers", projectionCountField = "consumerCount", reconcile = function(lease, before, after) return Treasure:ReconcileDemand(lease, before, after) end })
if treasureDemand == nil then error(treasureErr) end
Treasure.Demand = treasureDemand
ok, err = Runtime:RegisterImplementation(Treasure.Id, Treasure); if ok ~= true then error(err) end

------------------------------------------------------------------------
-- Fishing (bounded observation; Auto-R hotkey writes remain runtime-blocked)
------------------------------------------------------------------------
local Fishing = { Id = "life_fishing", storeId = "v3.life.fishing", enabled = false, storeLoaded = false, autoArmed = false }
S.Features.Fishing = Fishing
Fishing.UpdateTopic = "v3.life.fishing.updated"
Fishing.ObservationContractVersion = 1
Fishing.HotkeyContractVersion = 2
Fishing.HotkeyRuntimeBlocked = true
Fishing.State = { autoPreference = false, widgetVisible = false, widgetWindow = nil }
InstallLifeWidgetContract(Fishing, { defaultWidth = 360, defaultHeight = 190, minWidth = 230, minHeight = 110, defaultOverallOpacity = 0.94, defaultBackgroundOpacity = 1.0, defaultTextOpacity = 1.0 })
local FISHING_AUTO_BLOCKER = "自动 R 仍缺少 RU 实机完整 GetOptionBinding 源槽位/空绑定语义与故障注入回滚证据；当前版本仅提供鱼动作识别和技能栏推荐，不修改任何快捷键。"
Fishing.Authority = { version = 1, revision = 0, status = "idle", message = "尚未观察目标鱼动作", buffId = nil, slot = nil, autoArmed = false, autoAvailable = false, autoBlockedReason = FISHING_AUTO_BLOCKER }
local FA = Fishing.Authority
local FISH_MAP = { [5264] = { slot = 4, text = "向左拉" }, [5265] = { slot = 3, text = "向右拉" }, [5267] = { slot = 5, text = "放线" }, [5266] = { slot = 6, text = "收线" }, [5508] = { slot = 7, text = "提竿" } }

function FA:Refresh()
    self.buffId, self.slot = nil, nil
    if S.Api:IsCapabilityAllowed("X2Unit:UnitBuffCount") ~= true or S.Api:IsCapabilityAllowed("X2Unit:UnitBuff") ~= true then
        self.status, self.message = "unavailable", "当前 RU 能力面未证明目标 Buff 读取"
        self.revision = self.revision + 1
        PublishFeatureUpdate(Fishing, self.revision, "fishing_observation_unavailable")
        return false
    end
    local ok, count = Call("X2Unit:UnitBuffCount", UnitApi, "UnitBuffCount", "target")
    count = ok and Number(count) or 0
    for index = 1, math.min(128, math.floor(count)) do
        local readOk, buff = Call("X2Unit:UnitBuff", UnitApi, "UnitBuff", "target", index)
        local id = readOk and type(buff) == "table" and Number(buff.buff_id or buff.buffId or buff.type or buff.id) or nil
        if id and FISH_MAP[id] then self.buffId, self.slot = id, FISH_MAP[id].slot; break end
    end
    self.status = self.buffId and "ready" or "waiting"
    self.message = self.buffId and (FISH_MAP[self.buffId].text .. " · 推荐技能栏 " .. tostring(self.slot)) or "等待鱼的动作 Buff"
    self.autoArmed = false
    self.autoAvailable = false
    self.autoBlockedReason = FISHING_AUTO_BLOCKER
    self.revision = self.revision + 1
    PublishFeatureUpdate(Fishing, self.revision, "fishing_observation")
    return true
end

function FA:GetProjection()
    return {
        revision = self.revision, status = self.status, message = self.message, buffId = self.buffId, slot = self.slot,
        autoArmed = false, autoAvailable = false, autoBlockedReason = self.autoBlockedReason or FISHING_AUTO_BLOCKER,
    }
end

-- Hotkey writes are intentionally runtime-blocked. PRODUCT_COMPLETION_MATRIX
-- keeps both Fishing full-R snapshot and write/restore contracts locked until
-- RU Fresh Reload proves the complete source-slot set, explicit unbound
-- semantics, readback, reload recovery and failure rollback. Do not reintroduce
-- SetOptionBinding/RemoveOptionBinding/SaveHotKey here without that evidence.
function Fishing:ArmAuto()
    self.autoArmed = false
    FA.autoArmed = false
    FA.autoAvailable = false
    FA.autoBlockedReason = FISHING_AUTO_BLOCKER
    return false, FISHING_AUTO_BLOCKER
end

function Fishing:DisarmAuto()
    self.autoArmed = false
    FA.autoArmed = false
    FA.autoAvailable = false
    return true
end

function Fishing:IsAutoArmed() return false end

local function NormalizeFishingState(value)
    value = type(value) == "table" and value or {}
    return {
        autoPreference = value.autoPreference == true,
        widgetVisible = value.widgetVisible == true,
        widgetWindow = type(value.widgetWindow) == "table" and Copy(value.widgetWindow) or nil,
        recovery = type(value.recovery) == "table" and Copy(value.recovery) or nil,
    }
end
RegisterStore(Fishing.storeId, "v3.life.fishing", function() return NormalizeFishingState(nil) end, function() return Copy(Fishing.State) end, function(value)
    value = type(value) == "table" and value or {}
    Fishing.State.autoPreference = value.autoPreference == true
    Fishing.State.widgetVisible = value.widgetVisible == true
    Fishing.State.widgetWindow = type(value.widgetWindow) == "table" and Copy(value.widgetWindow) or nil
    Fishing.State.recovery = type(value.recovery) == "table" and Copy(value.recovery) or nil
end, NormalizeFishingState)
Fishing.ApiDependencies = { "X2Unit:UnitBuffCount", "X2Unit:UnitBuff" }
function Fishing:Initialize()
    local ok, err = LoadStore(self)
    if ok ~= true then return ok, err end
    -- `.18.115` and earlier may have persisted an experimental recovery marker
    -- inside the main Fishing store. Its unbound semantics were never RU-verified,
    -- so this version deliberately quarantines it instead of issuing any Native
    -- hotkey write. Preserve the marker for manual diagnosis/reset.
    if type(self.State.recovery) == "table" then
        FA.autoBlockedReason = "检测到旧版自动 R 恢复记录；为避免误删真实快捷键，本版本不会自动写回。请先在游戏按键设置中确认 R 键。"
        S.SafeChat(FA.autoBlockedReason)
    end
    return true
end
local FISHING_OBSERVE_TASK = "v3_life_fishing_observe"
function Fishing:ReconcileDemand(_, before, after)
    local beforeCount = tonumber(before and before.count) or 0
    local afterCount = tonumber(after and after.count) or 0
    if beforeCount <= 0 and afterCount > 0 then
        if S.Events == nil or S.Scheduler == nil or type(S.Scheduler.AddOneShot) ~= "function" then return false, "钓鱼观察事件/Scheduler 不可用" end
        S.Events:BindOwner(self, self.Id)
        local targetOk = S.Events:SubscribeOptional("TARGET_CHANGED", self, function()
            if Fishing.enabled and Fishing.consumerCount > 0 then return FA:Refresh() end
        end)
        local buffOk = S.Events:SubscribeOptional("BUFF_UPDATE", self, function()
            if Fishing.enabled and Fishing.consumerCount > 0 then
                -- BUFF_UPDATE can be noisy. Coalesce all native edges into one
                -- bounded target scan instead of scanning up to 128 buffs per event.
                S.Scheduler:AddOneShot(FISHING_OBSERVE_TASK, 100, function()
                    if Fishing.enabled and Fishing.consumerCount > 0 then return FA:Refresh() end
                    return true
                end, Fishing, "P2", 1)
            end
            return true
        end)
        if targetOk ~= true or buffOk ~= true then S.Events:UnsubscribeOwner(self); return false, "钓鱼目标/Buff 事件订阅失败" end
        return FA:Refresh()
    elseif beforeCount > 0 and afterCount <= 0 then
        if S.Events ~= nil then S.Events:UnsubscribeOwner(self) end
        if S.Scheduler ~= nil and type(S.Scheduler.RemoveTask) == "function" then
            S.Scheduler:RemoveTask(FISHING_OBSERVE_TASK)
        end
    end
    return true
end
function Fishing:Enable() self.enabled = true; return true end
function Fishing:Disable(reason)
    local ok, err = self.Demand:Clear(reason or "fishing_disable")
    if ok ~= true then return false, err end
    if S.Events then S.Events:UnsubscribeOwner(self) end
    if S.Scheduler and type(S.Scheduler.RemoveTask) == "function" then S.Scheduler:RemoveTask(FISHING_OBSERVE_TASK) end
    self:DisarmAuto()
    self.enabled = false
    return true
end
function Fishing:AcquireConsumer(token) if not self.enabled then return false, "钓鱼功能已关闭" end return self.Demand:Acquire(token, {}, "fishing_consumer") end
function Fishing:ReleaseConsumer(token) return self.Demand:Release(token, "fishing_consumer") end
function Fishing:Refresh() if not self.enabled or self.consumerCount <= 0 then return true end return FA:Refresh() end
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
