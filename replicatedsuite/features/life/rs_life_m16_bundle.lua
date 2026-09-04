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
local PlayerApi = rawget(_G, "X2Player")
local HotkeyApi = rawget(_G, "X2Hotkey")

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

local function RegisterStore(id, owner, default, get, apply)
    if P:GetStore(id) == nil then
        local store, err = P:RegisterV3Store({
            id = id, owner = owner, scope = P.Scope.Account, lifetime = P.Lifetime.Permanent,
            schemaVersion = 1, legacySchemaVersion = 0, key = P.V3KeyPrefix .. id:gsub("[^%w]", "_"),
            budget = { maxDepth = 6, maxNodes = 320, maxStringBytes = 8192, maxEntriesPerTable = 160 },
            default = default, get = get, apply = apply, migrate = default,
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
Trade.State = { fromZone = nil, toZone = nil, favorites = {}, sortMode = "ratio", widgetVisible = false, widgetWindow = nil }
Trade.Authority = { version = 2, revision = 0, zones = {}, sellableZones = {}, rows = {}, status = "idle", error = nil, inFlight = nil, zoneFallback = false, sellableFallback = false, sellableError = nil }
InstallLifeWidgetContract(Trade, { defaultWidth = 470, defaultHeight = 310, minWidth = 260, minHeight = 140, defaultOverallOpacity = 0.94, defaultBackgroundOpacity = 1.0, defaultTextOpacity = 1.0 })
local TA = Trade.Authority
TA.sellableCache = {}
local TRADE_CONTINENT_ORDER = { west = 1, east = 2, auroria = 3, other = 4 }
local TRADE_ANCHORS_W = { [1] = true, [5] = true, [8] = true, [20] = true }
local TRADE_ANCHORS_E = { [4] = true, [12] = true, [17] = true }

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
    return id and tostring(id) or "--"
end

local function TradePrice(destination, name, ratio)
    local tableForZone = S.Data and S.Data.TradePrices and S.Data.TradePrices[Number(destination)]
    local raw = type(tableForZone) == "table" and tableForZone[Text(name)] or nil
    local base = type(raw) == "table" and Number(raw[1]) or Number(raw)
    if base == nil then return nil end
    return math.floor(base * (Number(ratio) or 0) + 0.5)
end

-- Trade material projection is deliberately bounded because the route event is
-- user-triggered but can contain static/custom recipes of arbitrary size.  The
-- same bounded rows are used for the visible summary, per-material quote data,
-- and total cost; a truncated recipe never reports its subtotal as a complete
-- cost.
local TRADE_MATERIAL_MAX_ROWS = 32
local TRADE_MATERIAL_KEY_MAX_CHARS = 48
local TRADE_MATERIAL_SUMMARY_ROW_MAX_CHARS = 120
local TRADE_MATERIAL_SUMMARY_MAX_CHARS = 4096

local function BoundedTradeText(value, fallback, maxChars)
    local text = Text(value, fallback)
    local limit = tonumber(maxChars) or TRADE_MATERIAL_KEY_MAX_CHARS
    if #text > limit then return string.sub(text, 1, limit) end
    return text
end

local function BuildTradeMaterialProjection(name)
    local static = S.Data and S.Data.TradeStaticV2
    local recipe = static and type(static.GetRecipeByLegacyName) == "function" and static:GetRecipeByLegacyName(name) or nil
    local ingredients = type(recipe) == "table" and recipe.ingredients or nil
    local result = {
        rows = {}, materialRows = {}, summary = "材料待确认", sourceCount = 0,
        truncated = false, costCopper = nil, subtotalCopper = 0,
        costComplete = false, costStatus = "unavailable",
    }
    if type(ingredients) ~= "table" then return result end

    local meta = S.Data and S.Data.TradeMaterialAuctionMeta
    local sourceCount = #ingredients
    local limit = sourceCount
    if limit > TRADE_MATERIAL_MAX_ROWS then
        limit = TRADE_MATERIAL_MAX_ROWS
        result.truncated = true
    end
    result.sourceCount = sourceCount

    local total, complete = 0, false
    for index = 1, limit do
        local ingredient = type(ingredients[index]) == "table" and ingredients[index] or {}
        local materialKey = ingredient.materialKey or ingredient.compactId or "?"
        local count = math.max(0, tonumber(ingredient.count) or 0)
        local item = type(meta) == "table" and meta[ingredient.materialKey] or nil
        local itemType = item and tonumber(item.itemType) or nil
        local itemGrade = item and tonumber(item.itemGrade) or nil
        local unitCost, totalCost, status = nil, nil, "price_pending"
        local includeInCost = not (item and item.includeInCost == false)

        if not includeInCost then
            totalCost, status = 0, "excluded"
        elseif itemType == nil then
            complete, status = false, "identity_pending"
        else
            -- Material identity is a local fact. Price is not: GetLowestPrice is
            -- cooldown-bound and must never fan out from an ordinary route refresh.
            -- Instead read the shared PriceQuoteQueueV3 read model: if a quote has
            -- already completed for this itemType (via an explicit user quote in
            -- CraftAssist/AuctionFavorites), resolve the unit cost here; otherwise
            -- stay "explicit_quote_required" without issuing a server request.
            local quoteQueue = S.Services ~= nil and S.Services.PriceQuoteQueueV3 or nil
            local quotedPrice
            if type(quoteQueue) == "table" and type(quoteQueue.GetPriceByItemType) == "function" then
                quotedPrice = quoteQueue:GetPriceByItemType(itemType, itemGrade)
            end
            if quotedPrice ~= nil then
                unitCost, totalCost, status = quotedPrice, quotedPrice * count, "quoted"
            else
                complete, status = false, "explicit_quote_required"
            end
        end

        local row = {
            index = index,
            materialKey = materialKey,
            compactId = tonumber(ingredient.compactId),
            name = BoundedTradeText(materialKey, "?", TRADE_MATERIAL_KEY_MAX_CHARS),
            count = count,
            itemType = itemType,
            itemGrade = itemGrade,
            includeInCost = includeInCost,
            unitCostCopper = unitCost,
            totalCostCopper = totalCost,
            costCopper = totalCost,
            costStatus = status,
        }
        local detail = row.name .. "×" .. tostring(row.count)
        if status == "excluded" then
            detail = detail .. "（不计成本）"
        elseif unitCost ~= nil and totalCost ~= nil then
            detail = detail .. "（单价 " .. Money(unitCost) .. " / 小计 " .. Money(totalCost) .. "）"
        else
            detail = detail .. (status == "explicit_quote_required" and "（价格需显式询价）" or "（单价待确认）")
        end
        row.summaryText = BoundedTradeText(detail, row.name .. "×" .. tostring(row.count), TRADE_MATERIAL_SUMMARY_ROW_MAX_CHARS)
        result.rows[#result.rows + 1] = row
        result.materialRows[#result.materialRows + 1] = row
    end

    local summaryParts, summaryChars = {}, 0
    for _, row in ipairs(result.materialRows) do
        local part = row.summaryText
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

local function TradeMaterialSummary(name)
    return BuildTradeMaterialProjection(name).summary
end

local function TradeMaterialCost(name)
    return BuildTradeMaterialProjection(name).costCopper
end

function TA:RefreshZones()
    self.sellableCache = {}
    local ok, value, err = Call("X2Store:GetProductionZoneGroups", StoreApi, "GetProductionZoneGroups")
    if ok ~= true then self.status, self.error = "unavailable", err or "production zones unavailable"; return false, self.error end
    self.zones = NormalizeTradeZones(value)
    self.zoneFallback = false
    if #self.zones == 0 then
        self.zones = NormalizeTradeZones(StaticTradeZones())
        self.zoneFallback = #self.zones > 0
    end
    self.sellableZones = {}
    self.sellableFallback, self.sellableError = false, nil
    self.status, self.error = #self.zones > 0 and "ready" or "empty", (#self.zones > 0 and nil or "生产地区列表为空")
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

function TA:Request()
    local from, to = Number(Trade.State.fromZone), Number(Trade.State.toZone)
    if from == nil or to == nil then self.status, self.rows = "idle", {}; return false, "请先选择完整路线" end
    if self.inFlight ~= nil then return false, "路线查询仍在进行" end
    self.inFlight = { from = from, to = to }
    self.status, self.error = "loading", nil
    self.revision = self.revision + 1
    PublishFeatureUpdate(Trade, self.revision, "route_request")
    local ok, err = Action("X2Store:GetSpecialtyRatioBetween", StoreApi, "GetSpecialtyRatioBetween", from, to)
    if ok ~= true then
        self.inFlight, self.status, self.error = nil, "error", err or "服务器未接受路线查询"
        self.revision = self.revision + 1; PublishFeatureUpdate(Trade, self.revision, "route_request_failed")
        return false, self.error
    end
    return true
end

function TA:OnRatio(info)
    local flight = self.inFlight; self.inFlight = nil
    if type(flight) ~= "table" or type(info) ~= "table" then self.status, self.error = "error", "货率返回为空"; return false end
    local rows = {}
    for _, value in pairs(info) do
        if type(value) == "table" then
            local item = type(value.itemInfo) == "table" and value.itemInfo or value
            local name = item.name or item.itemName or value.name
            local ratio = Number(value.ratio or value.rate or value.percentage)
            if name ~= nil and ratio ~= nil then
                local price = TradePrice(flight.to, name, ratio)
                local materialProjection = BuildTradeMaterialProjection(name)
                local cost = materialProjection.costCopper
                local profit = price and cost and (price - cost) or nil
                rows[#rows + 1] = {
                    key = tostring(flight.from) .. ":" .. tostring(flight.to) .. ":" .. tostring(name),
                    name = Text(name), sourceName = Text(name), ratio = ratio,
                    rate = tostring(math.floor(ratio + 0.5)) .. "%", priceCopper = price,
                    price = price and Money(price) or "--",
                    materials = materialProjection.summary,
                    -- Generic V3 business pages expose row.text as their fact
                    -- column; keep it wired to the exact same bounded summary
                    -- used by the dedicated Trade material column.
                    text = materialProjection.summary,
                    materialRows = materialProjection.materialRows,
                    materialCount = materialProjection.count,
                    materialSourceCount = materialProjection.sourceCount,
                    materialLimit = TRADE_MATERIAL_MAX_ROWS,
                    materialsTruncated = materialProjection.truncated,
                    materialSummaryTruncated = materialProjection.summaryDisplayTruncated,
                    materialCostCopper = cost,
                    materialCostStatus = materialProjection.costStatus,
                    materialCostComplete = materialProjection.costComplete,
                    materialSubtotalCopper = materialProjection.subtotalCopper,
                    profit = profit and Money(profit) or (price and "待材料价格" or "--"),
                    tone = ratio >= 125 and "green" or (ratio >= 115 and "yellow" or "red"),
                }
            end
        end
    end
    table.sort(rows, function(a, b)
        local av = Trade.State.sortMode == "price" and (a.priceCopper or -1) or a.ratio
        local bv = Trade.State.sortMode == "price" and (b.priceCopper or -1) or b.ratio
        if av ~= bv then return av > bv end
        return a.key < b.key
    end)
    self.rows, self.status, self.error = rows, (#rows > 0 and "ready" or "error"), (#rows > 0 and nil or "服务器返回的货率列表为空")
    self.revision = self.revision + 1
    PublishFeatureUpdate(Trade, self.revision, "ratio_result")
    return #rows > 0
end
function TA:GetProjection() return { revision = self.revision, zones = Copy(self.zones), sellableZones = Copy(self.sellableZones), rows = Copy(self.rows), status = self.status, error = self.error, fromZone = Trade.State.fromZone, toZone = Trade.State.toZone, zoneFallback = self.zoneFallback == true, sellableFallback = self.sellableFallback == true, sellableError = self.sellableError } end

RegisterStore(Trade.storeId, "v3.life.trade", function() return { fromZone = nil, toZone = nil, favorites = {}, sortMode = "ratio", widgetVisible = false } end,
    function() return Copy(Trade.State) end,
    function(value)
        value = type(value) == "table" and value or {}
        Trade.State.fromZone, Trade.State.toZone = Number(value.fromZone), Number(value.toZone)
        Trade.State.favorites = type(value.favorites) == "table" and value.favorites or {}
        Trade.State.sortMode = value.sortMode == "price" and "price" or "ratio"
        Trade.State.widgetVisible = value.widgetVisible == true
        Trade.State.widgetWindow = type(value.widgetWindow) == "table" and Copy(value.widgetWindow) or nil
    end)

Trade.ApiDependencies = { "X2Store:GetProductionZoneGroups", "X2Store:GetSellableZoneGroups", "X2Store:GetSpecialtyRatioBetween", "X2Ability:GetAllMyActabilityInfos" }
function Trade:Initialize() return LoadStore(self) end
function Trade:ReconcileDemand(_, before, after)
    local beforeCount = tonumber(before and before.count) or 0
    local afterCount = tonumber(after and after.count) or 0
    if beforeCount <= 0 and afterCount > 0 then
        if S.Events ~= nil then
            S.Events:BindOwner(self, self.Id)
            if S.Events:SubscribeOptional("SPECIALTY_RATIO_BETWEEN_INFO", self, function(_, info) return TA:OnRatio(info) end) ~= true then
                self.eventUnavailable = true
                return false, "SPECIALTY_RATIO_BETWEEN_INFO 订阅失败"
            end
            self.eventUnavailable = false
        end
        self.Authority:RefreshZones()
    elseif beforeCount > 0 and afterCount <= 0 and S.Events ~= nil then
        S.Events:UnsubscribeOwner(self)
        TA.inFlight = nil
    end
    return true
end
function Trade:Enable() self.enabled = true; return true end
function Trade:Disable(reason) local ok, err = self.Demand:Clear(reason or "trade_disable"); if ok ~= true then return false, err end; if S.Events then S.Events:UnsubscribeOwner(self) end; self.enabled = false; TA.inFlight = nil; return true end
function Trade:AcquireConsumer(token) if not self.enabled then return false, "跑商功能已关闭" end return self.Demand:Acquire(token, {}, "trade_consumer") end
function Trade:ReleaseConsumer(token) return self.Demand:Release(token, "trade_consumer") end
function Trade:Refresh() if not self.enabled or self.consumerCount <= 0 then return true end; return TA:RefreshZones() end
function Trade:GetProjection() return TA:GetProjection() end
function Trade:GetRouteSettings() return { fromZone = Trade.State.fromZone, toZone = Trade.State.toZone, sortMode = Trade.State.sortMode } end
function Trade:SetFrom(id)
    local persisted, persistErr = PersistLifeMutation(self, "trade_from", function(state)
        state.fromZone = Number(id)
        return true
    end)
    if persisted ~= true then return false, persistErr or "起点保存失败" end
    TA:RefreshSellable()
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
    local ok, status = queue:RequestQuote("life_trade", itemType, itemGrade, function()
        TA.revision = TA.revision + 1
        PublishFeatureUpdate(Trade, TA.revision, "trade_quote_completed")
    end)
    if ok ~= true then return false, status or "报价请求失败" end
    return true, status or "queued"
end

Trade.Commands = { Refresh = function(_, reason) return Trade:Refresh(reason) end, SetFrom = function(_, id) return Trade:SetFrom(id) end, SetTo = function(_, id) return Trade:SetTo(id) end,
    QuoteMaterial = function(_, materialKey) return Trade:QuoteMaterial(materialKey) end,
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
Bonds.State = { sortMode = "continent", showCompleted = true, q20 = true, q60 = true, q100 = true, auroria = true, excludeSame = false, priority = "west", widgetVisible = false, widgetWindow = nil }
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
                local key, count = BondMaterialKey(BondItemType(item)), BondItemCount(item)
                local occupied = count ~= nil or next(item) ~= nil
                if key and count then totals[key] = totals[key] + count
                elseif occupied then failed = true end
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
local function NormalizeBondState(value)
    value = type(value) == "table" and value or {}
    return { sortMode = value.sortMode == "quantity" and "quantity" or "continent", showCompleted = value.showCompleted ~= false,
        q20 = value.q20 ~= false, q60 = value.q60 ~= false, q100 = value.q100 ~= false, auroria = value.auroria ~= false,
        excludeSame = value.excludeSame == true, priority = value.priority == "east" and "east" or "west",
        widgetVisible = value.widgetVisible == true, widgetWindow = type(value.widgetWindow) == "table" and Copy(value.widgetWindow) or nil }
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
    local rows, apiReadable, contentCount = {}, 0, 0
    local state = NormalizeBondState(Bonds.State)
    BA.duplicatePriorityUnresolved = nil
    BA.boardScope, BA.faction = "unknown", nil
    local resources, resourceStatus = ReadBondResources()

    -- Read every board type exactly once. The original RU residentboard addon
    -- identifies mainland by non-empty 3+4 and Auroria by non-empty 5/6; keep
    -- that proven shape while normalizing the return defensively.
    local boards = {}
    local firstError = nil
    for index = 1, 7 do
        local ok, value, err = Call("X2Resident:GetResidentBoardContent", ResidentApi, "GetResidentBoardContent", index)
        if ok == true and value ~= nil then
            apiReadable = apiReadable + 1
            local contents = NormalizeResidentBoardContents(value)
            boards[index] = { raw = value, contents = contents }
            contentCount = contentCount + #contents
            if type(value) == "table" and BA.faction == nil and value.faction ~= nil then BA.faction = Text(value.faction) end
        else
            boards[index] = { raw = value, contents = {} }
            if err ~= nil then firstError = firstError or tostring(err) end
        end
    end

    local function Has(index)
        return type(boards[index]) == "table" and #(boards[index].contents or {}) > 0
    end

    local selected = {}
    if Has(3) and Has(4) then
        BA.boardScope = "mainland"
        for index = 1, 4 do selected[#selected + 1] = index end
    elseif Has(5) or Has(6) then
        BA.boardScope = "auroria"
        for index = 5, 7 do selected[#selected + 1] = index end
    else
        -- If the current RU client returns only a subset, do not discard valid
        -- rows just because the historical location heuristic cannot classify
        -- the zone. Keep those rows and report scope=unknown.
        for index = 1, 7 do if Has(index) then selected[#selected + 1] = index end end
    end

    for _, index in ipairs(selected) do
        local contents = boards[index] and boards[index].contents or {}
        for lineIndex, line in ipairs(contents) do
            local textValue = BondRowText(line)
            local materialKey = type(line) == "table" and (line.materialKey or line.material_key) or BOND_TEXT_MATERIAL[index]
            if not materialKey and index >= 5 then materialKey = "auroria_token" end
            local quantity = type(line) == "table" and Number(line.quantity or line.requiredCount or line.required_count)
                or Number(string.match(textValue, "(%d+)"))
            local requiredCount, haveCount = quantity, materialKey and resources[materialKey] or nil
            local rowStatus = materialKey and resourceStatus or "unknown"
            if resourceStatus == "unknown" or resourceStatus == "partial" then haveCount = nil end
            if materialKey == "auroria_token" then haveCount, rowStatus = nil, "unknown" end
            local questId, mappedQuantity, auroriaToken = BondQuestEvidence(materialKey, textValue)
            quantity = mappedQuantity or quantity
            requiredCount = mappedQuantity or requiredCount
            local questStatus = "UNKNOWN"
            local progress = S.Services and S.Services.QuestProgressV3
            if questId ~= nil and progress and type(progress.QuestState) == "function" then
                questStatus = tostring(progress:QuestState(questId) or "UNKNOWN")
            end
            local completed = questStatus == "COMPLETED"
            local continentKey = BondContinentKey(line)
            if continentKey == nil and index >= 5 then continentKey = "auroria" end
            local category = continentKey == "auroria" and "auroria"
                or (quantity == 20 and "q20" or quantity == 60 and "q60" or quantity == 100 and "q100" or nil)
            if category == nil or state[category] then
                rows[#rows + 1] = {
                    key = "board:" .. index .. ":" .. lineIndex,
                    board = index, name = BOND_BOARD_NAMES[index] or ("分类" .. tostring(index)),
                    continent = BondContinent(index), continentKey = continentKey,
                    text = textValue, quantity = quantity, materialKey = materialKey, auroriaToken = auroriaToken,
                    requiredCount = requiredCount, haveCount = haveCount,
                    shortage = requiredCount and haveCount and math.max(0, requiredCount - haveCount) or nil,
                    resourceStatus = rowStatus, resourceText = haveCount and tostring(haveCount) or "?",
                    shortageText = requiredCount and haveCount and tostring(math.max(0, requiredCount - haveCount)) or "?",
                    questId = questId, questStatus = questStatus, completed = completed,
                    statusText = completed and "已完成" or (QUEST_STATUS_TEXT[questStatus] or "待确认"),
                    tone = completed and "green" or (QUEST_STATUS_TONE[questStatus] or "muted"),
                }
            end
        end
    end

    if state.excludeSame then
        local groups, unresolved = {}, {}
        for _, row in ipairs(rows) do
            local key = row.materialKey and row.quantity and (tostring(row.materialKey) .. ":" .. tostring(row.quantity)) or nil
            if key then
                groups[key] = groups[key] or { west = {}, east = {}, other = {} }
                local side = row.continentKey == "west" and "west" or row.continentKey == "east" and "east" or "other"
                groups[key][side][#groups[key][side] + 1] = row
            end
        end
        local winners = {}
        for key, group in pairs(groups) do
            local total = #group.west + #group.east + #group.other
            if total > 1 then
                if #group.other > 0 then unresolved[key] = true
                else winners[key] = (#group[state.priority] > 0 and group[state.priority][1])
                    or group[state.priority == "west" and "east" or "west"][1] end
            end
        end
        local filtered, emitted = {}, {}
        for _, row in ipairs(rows) do
            local key = row.materialKey and row.quantity and (tostring(row.materialKey) .. ":" .. tostring(row.quantity)) or nil
            if unresolved[key] then
                BA.duplicatePriorityUnresolved = "重复债券优先级无法解析：缺少可靠大陆身份，已保留重复行"
                filtered[#filtered + 1] = row
            elseif winners[key] then
                if emitted[key] ~= true then emitted[key] = true; filtered[#filtered + 1] = winners[key] end
            else
                filtered[#filtered + 1] = row
            end
        end
        rows = filtered
    end

    if state.sortMode == "quantity" then
        table.sort(rows, function(a, b) return (a.quantity or 999) < (b.quantity or 999) end)
    end

    local status, errorText
    if apiReadable <= 0 then
        status, errorText = "unavailable", firstError or "居民板 API 当前不可用"
    elseif contentCount <= 0 then
        status, errorText = "empty", "当前位置没有可读取的居民债券内容"
    else
        status, errorText = "ready", nil
    end
    self.rows, self.status, self.resourceStatus, self.error = rows, status, resourceStatus, errorText
    self.revision = self.revision + 1
    PublishFeatureUpdate(Bonds, self.revision, "bonds_refresh")
    return apiReadable > 0
end
function BA:GetProjection()
    return {
        revision = self.revision, rows = Copy(self.rows), status = self.status, resourceStatus = self.resourceStatus,
        error = self.error, duplicatePriorityUnresolved = self.duplicatePriorityUnresolved,
        boardScope = self.boardScope, faction = self.faction,
    }
end
RegisterStore(Bonds.storeId, "v3.life.bonds", function() return NormalizeBondState(nil) end,
    function() return Copy(Bonds.State) end,
    function(value) Bonds.State = NormalizeBondState(value) end)
Bonds.ApiDependencies = { "X2Resident:GetResidentBoardContent", "X2Bag:Capacity", "X2Bag:GetBagItemInfo" }
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
RegisterStore(Treasure.storeId, "v3.life.treasure", function() return { selectedKey = nil, widgetVisible = false } end, function() return Copy(Treasure.State) end, function(value)
    value = type(value) == "table" and value or {}
    Treasure.State.selectedKey = value.selectedKey
    Treasure.State.widgetVisible = value.widgetVisible == true
    Treasure.State.widgetWindow = type(value.widgetWindow) == "table" and Copy(value.widgetWindow) or nil
end)
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
-- Fishing (bounded observation plus reversible explicit hotkey action)
------------------------------------------------------------------------
local Fishing = { Id = "life_fishing", storeId = "v3.life.fishing", recoveryStoreId = "v3.life.fishing.recovery", enabled = false, storeLoaded = false, autoArmed = false }
S.Features.Fishing = Fishing
Fishing.UpdateTopic = "v3.life.fishing.updated"
Fishing.ObservationContractVersion = 1
Fishing.HotkeyContractVersion = 1
Fishing.State = { autoPreference = false, widgetVisible = false, widgetWindow = nil }
InstallLifeWidgetContract(Fishing, { defaultWidth = 360, defaultHeight = 190, minWidth = 230, minHeight = 110, defaultOverallOpacity = 0.94, defaultBackgroundOpacity = 1.0, defaultTextOpacity = 1.0 })
Fishing.Authority = { version = 1, revision = 0, status = "idle", message = "尚未观察目标鱼动作", buffId = nil, slot = nil, autoArmed = false, autoAvailable = false, autoBlockedReason = "自动 R 尚未启用" }
local FA = Fishing.Authority
local FISH_SLOTS = { 2, 3, 4, 5, 6, 7 }
local FISH_MAP = { [5264] = { slot = 4, text = "向左拉" }, [5265] = { slot = 3, text = "向右拉" }, [5267] = { slot = 5, text = "放线" }, [5266] = { slot = 6, text = "收线" }, [5508] = { slot = 7, text = "提竿" } }

-- Auto-R hotkey transaction state (reversible; see Fishing:ArmAuto/DisarmAuto).
-- sessionSnapshot holds the pre-fishing binding Authority for the current armed
-- session; pendingCombatRestore flags that keys must be repaired once out of
-- combat. The recovery store mirrors this across reloads so an unexpected
-- addon reload can still restore the original bindings.
Fishing.hotkey = {
    sourceSlot = nil,        -- slot that currently holds R (the source)
    currentSlot = nil,       -- slot R currently occupies during fishing
    sessionSnapshot = nil,   -- { sourceSlot, sourceBinding, slots = { [slot] = {slot, binding, wasUnbound} }, touched = {} }
    pendingCombatRestore = false,
    recoveryLoaded = false,
}
local ACTION_BAR = "mode_action_bar_button"
local ACTION_SCAN_MAX = 12
local READ_OPTIONS = { false, true, 0, 1 }
function FA:Refresh()
    -- Combat guard: fishing itself never puts the player in combat, but if the
    -- player is attacked (mob aggros / another player attacks) mid-fishing, the
    -- hotkey writes are combat-restricted. Disarm immediately — DisarmAuto will
    -- restore the original bindings (or defer to out-of-combat if still in
    -- combat, where writes are forbidden).
    if Fishing.autoArmed == true and Fishing:InCombat() then
        Fishing:DisarmAuto(true)
    end
    self.buffId, self.slot = nil, nil
    if S.Api:IsCapabilityAllowed("X2Unit:UnitBuffCount") ~= true or S.Api:IsCapabilityAllowed("X2Unit:UnitBuff") ~= true then self.status, self.message = "unavailable", "当前 RU 能力面未证明目标 Buff 读取"; return false end
    local ok, count = Call("X2Unit:UnitBuffCount", UnitApi, "UnitBuffCount", "target")
    count = ok and Number(count) or 0
    for index = 1, math.min(128, math.floor(count)) do
        local readOk, buff = Call("X2Unit:UnitBuff", UnitApi, "UnitBuff", "target", index)
        local id = readOk and type(buff) == "table" and Number(buff.buff_id or buff.buffId or buff.type or buff.id) or nil
        if id and FISH_MAP[id] then self.buffId, self.slot = id, FISH_MAP[id].slot; break end
    end
    self.status = self.buffId and "ready" or "waiting"
    self.message = self.buffId and (FISH_MAP[self.buffId].text .. " · 技能栏 " .. tostring(self.slot)) or "等待鱼的动作 Buff"
    -- A pending combat restore must progress even when only the observation
    -- path is ticking (widget hidden); resolve it here once out of combat.
    if Fishing.hotkey and Fishing.hotkey.pendingCombatRestore == true then Fishing:ResolvePendingCombatRestore() end
    self.revision = self.revision + 1
    PublishFeatureUpdate(Fishing, self.revision, "fishing_observation")
    return true
end
function FA:GetProjection() return { revision = self.revision, status = self.status, message = self.message, buffId = self.buffId, slot = self.slot, autoArmed = self.autoArmed == true, autoAvailable = self.autoAvailable == true, autoBlockedReason = self.autoArmed ~= true and self.autoBlockedReason or nil } end
function Fishing:InCombat()
    if S.Api:IsCapabilityAllowed("X2Player:PlayerInCombat") ~= true then return true end
    local ok, value = Call("X2Player:PlayerInCombat", PlayerApi, "PlayerInCombat"); return ok ~= true or value == nil or value == true
end

------------------------------------------------------------------------
-- Auto-R reversible hotkey transaction (V3 HotkeyContract v1)
-- 1) snapshot the R source slot + every fishing target slot
-- 2) moving R restores the previously-occupied target first, then re-seats R
-- 3) disable/reload/combat restores every touched slot + the R source exactly
-- 4) a persisted recovery snapshot (v3.life.fishing.recovery) repairs keys
--    after an unexpected addon reload
-- All reads cross CallCapability; all writes cross ActionCapability (RU 2026-08-19
-- combat-restricted). Combat read failure fails closed (treat as in-combat).
------------------------------------------------------------------------
local function HotkeyText(value)
    if type(value) == "string" or type(value) == "number" then return tostring(value) end
    if type(value) == "table" then
        for _, key in ipairs({ "key", "binding", "text", "value", "name" }) do
            if type(value[key]) == "string" or type(value[key]) == "number" then return tostring(value[key]) end
        end
    end
    return nil
end
local function NormalizeBinding(value)
    local text = HotkeyText(value)
    if text == nil then return nil end
    text = tostring(text):gsub("^%s+", ""):gsub("%s+$", "")
    if text == "" then return nil end
    return text
end
local function IsR(value)
    local text = NormalizeBinding(value)
    if text == nil then return false end
    text = string.upper((text:gsub("%s+", "")))
    return text == "R" or text == "KEY_R"
end

function Fishing:ReadSlotBinding(slot)
    slot = tonumber(slot)
    if slot == nil or S.Api:IsCapabilityAllowed("X2Hotkey:GetOptionBinding") ~= true then return nil end
    for _, option in ipairs(READ_OPTIONS) do
        local ok, value = Call("X2Hotkey:GetOptionBinding", HotkeyApi, "GetOptionBinding", ACTION_BAR, 1, option, slot)
        if ok and value ~= nil then
            local text = NormalizeBinding(value)
            if text ~= nil then return text end
        end
    end
    return nil
end

function Fishing:FindSourceSlot()
    for slot = 1, ACTION_SCAN_MAX do
        if IsR(self:ReadSlotBinding(slot)) then return slot end
    end
    return nil
end

function Fishing:BeginHotkeyEdit()
    if self:InCombat() then return false, "战斗中不能修改按键" end
    if S.Api:IsCapabilityAllowed("X2Hotkey:SetOptionBindingWithIndex") ~= true then return false, "X2Hotkey 写入不可用" end
    if S.Api:IsCapabilityAllowed("X2Hotkey:BindingToOption") == true then
        local ok, err = Action("X2Hotkey:BindingToOption", HotkeyApi, "BindingToOption")
        if not ok then return false, err end
    end
    return true
end

function Fishing:CanRemoveSlotBinding()
    return S.Api:IsCapabilityAllowed("X2Hotkey:RemoveOptionBinding") == true
end

function Fishing:SetSlotBindingNoSave(slot, key)
    slot = tonumber(slot); key = NormalizeBinding(key)
    if slot == nil then return false, "技能栏位置无效" end
    if key == nil then return false, "缺少原按键，无法安全恢复" end
    return Action("X2Hotkey:SetOptionBindingWithIndex", HotkeyApi, "SetOptionBindingWithIndex", ACTION_BAR, key, 1, math.floor(slot))
end

function Fishing:RemoveSlotBindingNoSave(slot)
    slot = tonumber(slot)
    if slot == nil then return false, "技能栏位置无效" end
    if not self:CanRemoveSlotBinding() then return false, "RemoveOptionBinding 不可用" end
    return Action("X2Hotkey:RemoveOptionBinding", HotkeyApi, "RemoveOptionBinding", ACTION_BAR, 1, math.floor(slot))
end

function Fishing:RestoreSlot(item)
    if type(item) ~= "table" then return true end
    if item.wasUnbound == true or NormalizeBinding(item.binding) == nil then
        return self:RemoveSlotBindingNoSave(item.slot)
    end
    return self:SetSlotBindingNoSave(item.slot, item.binding)
end

function Fishing:SaveHotkeys()
    if S.Api:IsCapabilityAllowed("X2Hotkey:SaveHotKey") == true then
        local ok, err = Action("X2Hotkey:SaveHotKey", HotkeyApi, "SaveHotKey")
        if not ok then return false, err end
    end
    return true
end

function Fishing:BuildSessionSnapshot(sourceSlot)
    sourceSlot = tonumber(sourceSlot)
    if sourceSlot == nil then return nil, "原 R 槽位无效" end
    local snapshot = { sourceSlot = math.floor(sourceSlot), sourceBinding = "R", slots = {}, touched = {} }
    for _, slot in ipairs(FISH_SLOTS) do
        local binding = self:ReadSlotBinding(slot)
        snapshot.slots[slot] = { slot = slot, binding = binding, wasUnbound = binding == nil }
    end
    if snapshot.slots[snapshot.sourceSlot] == nil then
        local binding = self:ReadSlotBinding(snapshot.sourceSlot)
        snapshot.slots[snapshot.sourceSlot] = { slot = snapshot.sourceSlot, binding = binding, wasUnbound = binding == nil }
    end
    snapshot.slots[snapshot.sourceSlot].binding = snapshot.slots[snapshot.sourceSlot].binding or "R"
    return snapshot
end

-- Recovery snapshot persistence: a dedicated V3 store so an unexpected reload
-- can restore the pre-fishing bindings. Never writes hotkeys in combat.
function Fishing:WriteRecovery(snapshot)
    if type(snapshot) ~= "table" then return false end
    local ok, err = PersistLifeMutation(self, "fishing_recovery_write", function(state)
        state.recovery = { pending = true, snapshot = Copy(snapshot) }
        return true
    end)
    return ok == true, err
end
function Fishing:ClearRecovery()
    return PersistLifeMutation(self, "fishing_recovery_clear", function(state)
        state.recovery = nil
        return true
    end)
end
function Fishing:LoadRecoverySnapshot()
    local rec = self.State and self.State.recovery or nil
    if type(rec) == "table" and rec.pending == true and type(rec.snapshot) == "table" then return rec.snapshot end
    return nil
end

function Fishing:RestoreSnapshot(snapshot)
    if type(snapshot) ~= "table" then return true end
    local sourceSlot = tonumber(snapshot.sourceSlot)
    if sourceSlot == nil then return false, "恢复记录缺少原 R 槽位" end
    local ok, err = self:BeginHotkeyEdit()
    if not ok then return false, err end
    local touched = type(snapshot.touched) == "table" and snapshot.touched or {}
    local slots = type(snapshot.slots) == "table" and snapshot.slots or {}
    for slotKey, wasTouched in pairs(touched) do
        local slot = tonumber(slotKey)
        if wasTouched == true and slot ~= nil and slot ~= sourceSlot then
            local item = slots[slot] or slots[slotKey]
            if type(item) ~= "table" then return false, "槽位 " .. tostring(slot) .. " 缺少恢复记录" end
            item.slot = tonumber(item.slot) or slot
            ok, err = self:RestoreSlot(item)
            if not ok then return false, err end
        end
    end
    ok, err = self:SetSlotBindingNoSave(sourceSlot, snapshot.sourceBinding or "R")
    if not ok then return false, err end
    ok, err = self:SaveHotkeys()
    if not ok then return false, err end
    return true
end

function Fishing:RecoverPendingOnLoad()
    local snapshot = self:LoadRecoverySnapshot()
    if snapshot == nil then return true end
    if self:InCombat() then
        self.hotkey.sessionSnapshot = snapshot
        self.hotkey.pendingCombatRestore = true
        S.SafeChat("检测到未完成的钓鱼改键，但当前在战斗中，脱战后自动恢复。")
        return false
    end
    local ok, err = self:RestoreSnapshot(snapshot)
    if ok then
        self:ClearRecovery()
        S.SafeChat("检测到上次未完成的钓鱼改键，已恢复原按键。")
        return true
    end
    S.SafeChat("检测到未完成的钓鱼改键，但自动恢复失败：" .. tostring(err))
    return false
end

function Fishing:SetRSlot(slot)
    slot = tonumber(slot)
    if slot == nil then return false, "技能栏位置无效" end
    slot = math.floor(slot)
    local snapshot = self.hotkey.sessionSnapshot
    if type(snapshot) ~= "table" then return false, "缺少钓鱼改键快照" end
    if tonumber(self.hotkey.currentSlot) == slot then return true end
    local sourceSlot = tonumber(snapshot.sourceSlot)
    local targetItem = snapshot.slots and snapshot.slots[slot] or nil
    if slot ~= sourceSlot then
        if targetItem == nil then return false, "槽位 " .. tostring(slot) .. " 没有备份记录" end
        if NormalizeBinding(targetItem.binding) == nil and not self:CanRemoveSlotBinding() then
            return false, "槽位 " .. tostring(slot) .. " 原本未绑定按键，且 RemoveOptionBinding 不可用"
        end
        if snapshot.touched[slot] ~= true then
            snapshot.touched[slot] = true
            local okW, errW = self:WriteRecovery(snapshot)
            if not okW then snapshot.touched[slot] = nil; return false, errW or "无法保存改键恢复快照，因此拒绝修改按键" end
        end
    end
    local ok, err = self:BeginHotkeyEdit()
    if not ok then return false, err end
    local previousSlot = tonumber(self.hotkey.currentSlot)
    if previousSlot ~= nil and previousSlot ~= sourceSlot then
        local previousItem = snapshot.slots and snapshot.slots[previousSlot] or nil
        if type(previousItem) ~= "table" then return false, "上一个槽位缺少恢复记录" end
        ok, err = self:RestoreSlot(previousItem)
        if not ok then return false, err end
    end
    ok, err = self:SetSlotBindingNoSave(sourceSlot, snapshot.sourceBinding or "R")
    if not ok then return false, err end
    if slot ~= sourceSlot then
        ok, err = self:SetSlotBindingNoSave(slot, "R")
        if not ok then return false, err end
    end
    ok, err = self:SaveHotkeys()
    if not ok then return false, err end
    self.hotkey.currentSlot = slot
    return true
end

function Fishing:ArmAuto()
    if self.autoArmed then return true end
    if self:InCombat() then
        FA.autoBlockedReason = "战斗中不能修改按键"
        S.SafeChat("战斗中不能修改按键，自动 R 未启用。")
        return false, "战斗中不能修改按键"
    end
    if type(self.hotkey.sessionSnapshot) == "table" then
        if not self:DisarmAuto(false) then return false, "上一次改键尚未恢复" end
    end
    local source = self:FindSourceSlot()
    if source == nil then
        FA.autoBlockedReason = "无法可靠读取当前 R 键所在动作栏位置"
        S.SafeChat("钓鱼自动R未启用：无法可靠读取当前 R 键所在动作栏位置，因此不会修改键位。")
        return false, "无法可靠读取 R 键位置"
    end
    local snapshot, err = self:BuildSessionSnapshot(source)
    if snapshot == nil then
        FA.autoBlockedReason = tostring(err)
        S.SafeChat("钓鱼自动R未启用：" .. tostring(err))
        return false, err
    end
    self.hotkey.sourceSlot = source
    self.hotkey.sessionSnapshot = snapshot
    self.hotkey.currentSlot = nil
    self.autoArmed = true
    local okW, errW = self:WriteRecovery(snapshot)
    if not okW then
        self.hotkey.sourceSlot = nil
        self.hotkey.sessionSnapshot = nil
        self.autoArmed = false
        FA.autoBlockedReason = "无法保存恢复快照"
        S.SafeChat("钓鱼自动R未启用：" .. tostring(errW or "无法保存恢复快照"))
        return false, errW or "无法保存恢复快照"
    end
    FA.autoArmed = true
    FA.autoAvailable = true
    FA.autoBlockedReason = nil
    FA.message = "自动R已启用 · 原R槽位 " .. tostring(source)
    PublishFeatureUpdate(Fishing, FA.revision, "fishing_auto_armed")
    return true
end

function Fishing:DisarmAuto(silent)
    local snapshot = self.hotkey.sessionSnapshot
    if self.autoArmed ~= true and type(snapshot) ~= "table" then
        FA.autoArmed = false; FA.autoAvailable = false
        return true
    end
    if self:InCombat() and type(snapshot) == "table" then
        self.autoArmed = false
        self.hotkey.pendingCombatRestore = true
        FA.autoArmed = false
        FA.message = "战斗中不能改键 · 等待脱战恢复"
        PublishFeatureUpdate(Fishing, FA.revision, "fishing_auto_combat")
        if silent ~= true then S.SafeChat("战斗中不能修改按键，原按键将在脱战后自动恢复。") end
        return false, "战斗中不能改键，等待脱战恢复"
    end
    local restored, err = true, nil
    if type(snapshot) == "table" then restored, err = self:RestoreSnapshot(snapshot) end
    self.autoArmed = false
    self.hotkey.pendingCombatRestore = false
    FA.autoArmed = false
    FA.autoAvailable = false
    if restored then
        self.hotkey.sourceSlot = nil
        self.hotkey.currentSlot = nil
        self.hotkey.sessionSnapshot = nil
        self:ClearRecovery()
        FA.message = "自动R已关闭 · 已恢复原按键"
    else
        FA.message = "自动R已关闭 · 恢复按键失败"
    end
    PublishFeatureUpdate(Fishing, FA.revision, "fishing_auto_disarmed")
    if silent ~= true and not restored then S.SafeChat("钓鱼助手关闭时未能恢复原按键：" .. tostring(err)) end
    return restored
end

function Fishing:IsAutoArmed() return self.autoArmed == true end
RegisterStore(Fishing.storeId, "v3.life.fishing", function() return { autoPreference = false, widgetVisible = false } end, function() return Copy(Fishing.State) end, function(value)
    value = type(value) == "table" and value or {}
    Fishing.State.autoPreference = value.autoPreference == true
    Fishing.State.widgetVisible = value.widgetVisible == true
    Fishing.State.widgetWindow = type(value.widgetWindow) == "table" and Copy(value.widgetWindow) or nil
    Fishing.State.recovery = type(value.recovery) == "table" and Copy(value.recovery) or nil
end)
Fishing.ApiDependencies = { "X2Unit:UnitBuffCount", "X2Unit:UnitBuff", "X2Player:PlayerInCombat", "X2Hotkey:GetOptionBinding", "X2Hotkey:SetOptionBindingWithIndex", "X2Hotkey:RemoveOptionBinding", "X2Hotkey:SaveHotKey", "X2Hotkey:BindingToOption" }
function Fishing:Initialize()
    local ok, err = LoadStore(self)
    if ok ~= true then return ok, err end
    -- Repair any orphaned hotkey transaction from a previous session (unless
    -- in combat, where a pending restore is scheduled instead).
    self:RecoverPendingOnLoad()
    return true
end
local FISHING_OBSERVE_TASK = "v3_life_fishing_observe"
local FISHING_RESTORE_TASK = "v3_life_fishing_restore"
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
        -- Persistent low-frequency combat/restore watch: (a) detect entry into
        -- combat while armed and disarm immediately (attacked mid-fishing), and
        -- (b) resolve a pending restore once out of combat. AddOneShot self-arms
        -- so it keeps ticking regardless of buff/target event activity.
        local function armRestorePoll()
            if not (Fishing.enabled and Fishing.consumerCount > 0) then return false end
            if Fishing.autoArmed == true and Fishing:InCombat() then
                Fishing:DisarmAuto(true)
            end
            if Fishing.hotkey.pendingCombatRestore == true then Fishing:ResolvePendingCombatRestore() end
            S.Scheduler:AddOneShot(FISHING_RESTORE_TASK, 500, function() return armRestorePoll() end, Fishing, "P2", 1)
            return true
        end
        S.Scheduler:AddOneShot(FISHING_RESTORE_TASK, 500, function() return armRestorePoll() end, Fishing, "P2", 1)
        return FA:Refresh()
    elseif beforeCount > 0 and afterCount <= 0 then
        if S.Events ~= nil then S.Events:UnsubscribeOwner(self) end
        if S.Scheduler ~= nil and type(S.Scheduler.RemoveTask) == "function" then
            S.Scheduler:RemoveTask(FISHING_OBSERVE_TASK)
            S.Scheduler:RemoveTask(FISHING_RESTORE_TASK)
        end
    end
    return true
end
function Fishing:ResolvePendingCombatRestore()
    if self.hotkey.pendingCombatRestore ~= true then return true end
    if self:InCombat() then return true end
    local snapshot = self.hotkey.sessionSnapshot
    if type(snapshot) == "table" then
        local restored, err = self:RestoreSnapshot(snapshot)
        if restored then
            self.hotkey.pendingCombatRestore = false
            self.autoArmed = false
            self.hotkey.sourceSlot = nil
            self.hotkey.currentSlot = nil
            self.hotkey.sessionSnapshot = nil
            self:ClearRecovery()
            FA.autoArmed = false
            FA.autoAvailable = false
            FA.message = "自动R已关闭 · 脱战后已恢复原按键"
            PublishFeatureUpdate(Fishing, FA.revision, "fishing_auto_restored")
            S.SafeChat("脱战后已恢复原按键。")
        else
            FA.message = "自动R已关闭 · 脱战恢复失败：" .. tostring(err)
            PublishFeatureUpdate(Fishing, FA.revision, "fishing_auto_restore_failed")
        end
    else
        self.hotkey.pendingCombatRestore = false
    end
    return true
end

function Fishing:Enable() self.enabled = true; return true end
function Fishing:Disable(reason) local ok, err = self.Demand:Clear(reason or "fishing_disable"); if ok ~= true then return false, err end; if S.Events then S.Events:UnsubscribeOwner(self) end; if S.Scheduler and type(S.Scheduler.RemoveTask) == "function" then S.Scheduler:RemoveTask(FISHING_OBSERVE_TASK); S.Scheduler:RemoveTask(FISHING_RESTORE_TASK) end; self:DisarmAuto(); self.enabled = false; return true end
function Fishing:AcquireConsumer(token) if not self.enabled then return false, "钓鱼功能已关闭" end return self.Demand:Acquire(token, {}, "fishing_consumer") end
function Fishing:ReleaseConsumer(token) return self.Demand:Release(token, "fishing_consumer") end
function Fishing:Refresh() if not self.enabled or self.consumerCount <= 0 then if self.hotkey.pendingCombatRestore == true then self:ResolvePendingCombatRestore() end; return true end return FA:Refresh() end
function Fishing:GetProjection() return FA:GetProjection() end
Fishing.Commands = { Refresh = function(_, reason) return Fishing:Refresh(reason) end, ArmAuto = function()
        local ok, err = Fishing:ArmAuto()
        if not ok then return ok, err end
        -- Fail-closed: the main-store save must succeed through the unified
        -- transaction; on failure roll back the armed hotkey session so the
        -- visible state never reports armed without a persisted intent.
        local persisted, persistErr = PersistLifeMutation(Fishing, "fishing_auto", function() return true end)
        if persisted ~= true then
            Fishing:DisarmAuto(true)
            return false, persistErr or "自动R保存失败"
        end
        return true, nil
    end, DisarmAuto = function() return Fishing:DisarmAuto() end,
    GetWidgetVisible = function() return Fishing:GetWidgetVisible() end, SetWidgetVisible = function(_, value, reason) return Fishing:SetWidgetVisible(value, reason) end,
    SetWidgetWindowState = function(_, value, reason) return Fishing:SetWidgetWindowState(value, reason) end, MarkStoreDirty = function(_, delayMs, reason) return Fishing:MarkStoreDirty(delayMs, reason) end }
local fishingDemand, fishingErr = Demand:Create({ id = "feature:" .. Fishing.Id, owner = Fishing, projectionOwner = Fishing, projectionConsumersField = "consumers", projectionCountField = "consumerCount", reconcile = function(lease, before, after) return Fishing:ReconcileDemand(lease, before, after) end })
if fishingDemand == nil then error(fishingErr) end
Fishing.Demand = fishingDemand
ok, err = Runtime:RegisterImplementation(Fishing.Id, Fishing); if ok ~= true then error(err) end
