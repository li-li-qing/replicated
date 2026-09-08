------------------------------------------------------------------------
-- Replicated Suite - Trade Material Identity V3
--
-- Resolves which materials a specialty pack needs, from the localized ratio
-- row. Semantics recovered from the legacy TradeMaterials service; ownership
-- follows the current V3 boundaries: this service owns the identity fact and
-- the only X2Craft access, Presentation/Feature never call X2Craft.
--
-- Resolution layers, in priority order:
--   1. Live craft facts: X2Craft:GetCraftTypeByItemType + GetCraftProductInfo
--      + GetCraftMaterialInfo keyed by the ratio row's product itemType. The
--      craft is trusted only after its product side names the queried itemType.
--      On-demand, serialized at 250ms, cached per itemType for the session.
--   2. Shared static families by localized keyword (larder 蜂蜜/奶酪/药材,
--      肥料/时空碎片/蓝盐运输) — recipes identical in every zone.
--   3. Region Authority + localized family tail: originZoneId picks the zone
--      (nameEn + tradeQuality from the shared zone catalog); localized text
--      only selects the family tail (特制特产=Gilda / 传统特产=Local /
--      特产=Specialty). Localized text must NEVER choose the region — the
--      legacy "[十字星]→Hasla" hard-map once made Cinderstone packs display
--      Hasla's recipe.
--
-- Everything fails closed: no recipe and no live data yields no identity, and
-- the projection keeps an honest "配方未匹配/解析中" state. No fabricated
-- materials, no background scanning; live reads run only while a Feature
-- explicitly requests identities and stop when its queue is drained/cancelled.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
S.Services = S.Services or {}
local M = {
    version = 1,
    IdentityContractVersion = 1,
    presentationBoundary = "service_only",
    -- Native spacing: craft getters are SideEffectFree, but one chain per tick
    -- keeps a route batch bounded and off the fast lanes.
    intervalMs = 250,
    maxQueue = 64,
    maxCacheEntries = 128,
    taskName = "v3_trade_material_identity_drain",
    liveCache = {},
    queue = {},
    pending = nil,
    running = false,
    owner = {},
    lastError = nil,
    liveReads = 0,
    recentFailed = {}, -- newest-first bounded ring of failed live attempts
    recentFailedMax = 8,
}
S.Services.TradeMaterialIdentityV3 = M

-- Two different tables live here: S.StaticDataV2 is the REGISTRY (GetCatalog/
-- Register), while S.Data.TradeStaticV2 is the ACCESSOR FACADE carrying
-- GetRecipeByLegacyName / GetMaterialByLegacyName / GetMaterialByCompactId.
-- Resolving through the registry silently yields nil for every lookup.
local StaticRegistry = S.StaticDataV2
local StaticFacade = S.Data and S.Data.TradeStaticV2 or nil
local function NowMs()
    if type(S.NowMs) == "function" then return math.max(0, tonumber(S.NowMs()) or 0) end
    return 0
end
local function Contains(text, token)
    return type(text) == "string" and string.find(text, token, 1, true) ~= nil
end

-- Canonical English material key -> item identity. The static trade_material
-- catalog is the curated Authority; Gilda Star is recipe currency without a
-- catalog entry of its own and is added explicitly.
local RESOURCE_BY_EN, GILDA_STAR_ITEM_TYPE = {}, 23633
do
    local meta = S.Data and S.Data.TradeMaterialAuctionMeta or nil
    if type(meta) == "table" then
        for en, entry in pairs(meta) do
            local itemType = type(entry) == "table" and tonumber(entry.itemType) or nil
            if itemType ~= nil then RESOURCE_BY_EN[en] = { itemType = math.floor(itemType), itemGrade = tonumber(entry.itemGrade) } end
        end
    end
    RESOURCE_BY_EN["Gilda Star"] = { itemType = GILDA_STAR_ITEM_TYPE, includeInCost = false }
end

-- Shared-family recipes recovered verbatim from the supplied working legacy
-- implementation (counts × compact resource ids; compact numbering matches the
-- current S.Data.TradeMaterialResources table).
local FAMILY_TABLES = {
    { token = "肥料特产", fallback = "Fertilizer Specialty", template = "template.fertilizer", label = "肥料特产" },
    { counts = { 2, 4, 20, 1 }, ids = { 62, 63, 64, 65 }, token = "蜂蜜", fallback = "Aged Honey", label = "陈化蜂蜜" },
    { counts = { 2, 50, 30, 1 }, ids = { 62, 12, 48, 65 }, token = "奶酪", fallback = "Aged Cheese", label = "陈化奶酪" },
    { counts = { 2, 20, 30, 1 }, ids = { 62, 66, 13, 65 }, token = "药材", fallback = "Aged Salve", label = "陈化药材" },
    { token = "时空碎片", fallback = "Space-Time Fragment", template = "template.fragment", label = "时空碎片运输品" },
    { token = "蓝盐商会运输品", fallback = "Bluesalt Transport", template = "template.transport", label = "蓝盐商会运输品" },
}

-- Localized tail -> legacy recipe family word. Order matters: 特制特产 must be
-- tested before 特产. These words only pick the FAMILY; the region always comes
-- from originZoneId.
local TAIL_RULES = {
    { token = "特制特产", tail = "Gilda Specialty" },
    { token = "传统特产", tail = "Local Specialty" },
    { token = "肥料特产", tail = "Fertilizer Specialty" },
    { token = "特产", tail = "Specialty" },
}

-- ---------------------------------------------------------------------
-- Player-facing material naming.
--
-- The Suite runs on a Chinese RU client and its users are players, not
-- developers. Every internal identifier (canonical EN key such as
-- "Chopped Produce", a compact id, a craftType number, a static-table
-- legacyName like "Halcyona Preserved Specialty") is a data-layer fact and
-- must never reach a page or HUD row. This resolver is the single place that
-- turns an identity into display text; callers pass what they have and get
-- back official Chinese wording, or an honest generic label -- never a raw key.
--
-- Priority: curated Localization Authority by itemType (the same table the
-- native client name is verified against) -> localized static record name ->
-- supplied fallback label -> neutral "材料"/"贸易品" wording.
-- ---------------------------------------------------------------------
local function LocalizedItemName(itemType)
    local id = tonumber(itemType)
    if id == nil or S.Localization == nil or type(S.Localization.GetName) ~= "function" then return nil end
    local name = S.Localization:GetName("item", math.floor(id), nil)
    if type(name) ~= "string" or name == "" then return nil end
    -- GetName synthesizes "ID <n>" when it has nothing; that is not a name.
    if name:match("^ID%s+%d+$") then return nil end
    return name
end

-- Resolve one material row to player-readable Chinese text.
function M:ResolveMaterialDisplayName(row)
    if type(row) ~= "table" then return "材料" end
    local name = LocalizedItemName(row.itemType)
    if name ~= nil then return name end
    if StaticFacade ~= nil and type(StaticFacade.GetMaterialByLegacyName) == "function" then
        local record = StaticFacade:GetMaterialByLegacyName(tostring(row.materialKey or ""))
        local localized = type(record) == "table" and tostring(record.name or "") or ""
        if localized ~= "" and not localized:match("^[A-Za-z ]+$") then return localized end
    end
    local label = tostring(row.displayName or "")
    if label ~= "" and not label:match("^[A-Za-z0-9_ .%-%+]+$") then return label end
    return "材料"
end

-- Resolve a produced trade good (route row / recipe product) to Chinese text.
-- A craftType number or an English legacy recipe name is never acceptable here.
function M:ResolveProductDisplayName(itemType, fallbackLabel)
    local name = LocalizedItemName(itemType)
    if name ~= nil then return name end
    local label = tostring(fallbackLabel or "")
    if label ~= "" and not label:match("^[A-Za-z0-9_ .%-%+]+$") and not label:match("^%d+$") then return label end
    return "贸易品"
end

local function GetMaterialRecord(ingredient)
    if type(StaticFacade) ~= "table" then return nil end
    local byEn = type(StaticFacade.GetMaterialByLegacyName) == "function" and StaticFacade:GetMaterialByLegacyName(ingredient.materialKey) or nil
    if byEn ~= nil then return byEn end
    local compactId = tonumber(ingredient.compactId)
    if compactId ~= nil and type(StaticFacade.GetMaterialByCompactId) == "function" then
        return StaticFacade:GetMaterialByCompactId(compactId)
    end
    return nil
end

-- Normalize one ingredient (from a legacy recipe, a shared family table, or a
-- live craft read) into the projection row shape: canonical EN materialKey for
-- the auction-meta lookup, explicit itemType when the record supplies one.
local function BuildIngredientRow(ingredient)
    if type(ingredient) ~= "table" then return nil end
    local count = math.max(0, tonumber(ingredient.count) or 0)
    local record = GetMaterialRecord(ingredient)
    local enKey = tostring(ingredient.materialKey or "")
    local itemType = tonumber(ingredient.itemType)
    local itemGrade = tonumber(ingredient.itemGrade)
    local includeInCost = ingredient.includeInCost ~= false
    if record ~= nil then
        enKey = tostring(record.nameEn or enKey)
        itemType = tonumber(record.itemId) or itemType
        itemGrade = tonumber(record.itemGrade) or itemGrade
        includeInCost = record.includeInCost ~= false and includeInCost
    elseif RESOURCE_BY_EN[enKey] ~= nil then
        itemType = RESOURCE_BY_EN[enKey].itemType or itemType
        itemGrade = RESOURCE_BY_EN[enKey].itemGrade or itemGrade
        if RESOURCE_BY_EN[enKey].includeInCost == false then includeInCost = false end
    end
    if enKey == "" then
        if itemType ~= nil then enKey = "item:" .. tostring(math.floor(itemType))
        else return nil end
    end
    return {
        materialKey = enKey, compactId = tonumber(ingredient.compactId), count = count,
        itemType = itemType, itemGrade = itemGrade, includeInCost = includeInCost,
    }
end

local function RowsFromIngredients(ingredients)
    local rows = {}
    for _, ingredient in ipairs(type(ingredients) == "table" and ingredients or {}) do
        local row = BuildIngredientRow(ingredient)
        if row ~= nil then rows[#rows + 1] = row end
    end
    return rows
end

local function RowsFromFamilyTable(family)
    local rows = {}
    local counts, ids = family.counts or {}, family.ids or {}
    for index = 1, math.min(#counts, #ids) do
        local row = BuildIngredientRow({ materialKey = nil, compactId = ids[index], count = counts[index] })
        if row ~= nil then rows[#rows + 1] = row end
    end
    return rows
end

local function GetTemplateRecord(key)
    if type(StaticRegistry) ~= "table" or type(StaticRegistry.GetCatalog) ~= "function" then return nil end
    local catalog = StaticRegistry:GetCatalog("trade_recipe_template")
    return type(catalog) == "table" and type(catalog.records) == "table" and catalog.records[tostring(key)] or nil
end

-- Layer 2 + 3. Pure data: no native calls, safe inside projection builders.
function M:ResolveStatic(sourceName, originZoneId)
    local raw = tostring(sourceName or "")
    if raw == "" or type(StaticFacade) ~= "table" or type(StaticFacade.GetRecipeByLegacyName) ~= "function" then return nil end

    local function RecipeResult(recipe, label)
        local rows = RowsFromIngredients(recipe and recipe.ingredients or nil)
        if #rows == 0 then return nil end
        return { rows = rows, label = label, source = "static_recipe" }
    end

    -- Direct legacy-name hit (server identity may some day match directly).
    local direct = StaticFacade:GetRecipeByLegacyName(raw)
    if direct ~= nil then
        local result = RecipeResult(direct, tostring(direct.legacyName or raw))
        if result ~= nil then return result end
    end

    -- Shared families: keyword only, identical recipe in every zone.
    for _, family in ipairs(FAMILY_TABLES) do
        if Contains(raw, family.token) or Contains(raw, family.fallback or "") then
            local rows
            if family.template ~= nil then
                local record = GetTemplateRecord(family.template)
                rows = RowsFromIngredients(record and record.ingredients or nil)
            else
                rows = RowsFromFamilyTable(family)
            end
            if #rows > 0 then return { rows = rows, label = family.label, source = "static_family" } end
        end
    end

    -- Region Authority + localized family tail.
    local zoneId = tonumber(originZoneId)
    local zones = S.GameIds and S.GameIds.Zone and S.GameIds.Zone.ById or nil
    local zone = type(zones) == "table" and zones[zoneId] or nil
    local zoneEn = type(zone) == "table" and tostring(zone.nameEn or "") or ""
    local quality = type(zone) == "table" and tostring(zone.tradeQuality or "") or ""
    if zoneEn == "" or quality == "" then return nil end
    local tail = nil
    for _, rule in ipairs(TAIL_RULES) do
        if Contains(raw, rule.token) or Contains(raw, rule.tail) then tail = rule.tail; break end
    end
    if tail == nil then return nil end
    local candidates = { zoneEn .. " " .. quality .. " " .. tail }
    if quality == "Coastal" then
        candidates[#candidates + 1] = zoneEn .. " Coastal " .. tail
        if tail == "Specialty" then candidates[#candidates + 1] = zoneEn .. " Coastal Local Specialty" end
    end
    for _, candidate in ipairs(candidates) do
        local recipe = StaticFacade:GetRecipeByLegacyName(candidate)
        if recipe ~= nil then
            local result = RecipeResult(recipe, candidate)
            if result ~= nil then return result end
        end
    end
    return nil
end

-- ---------------------------------------------------------------------
-- Live craft identity: bounded explicit queue, one X2Craft chain per tick.
-- ---------------------------------------------------------------------
local function CollectNumbers(value, out, seen, depth)
    depth = tonumber(depth) or 0
    if depth > 3 or out == nil or #out >= 16 then return end
    local number = tonumber(value)
    if number ~= nil and type(value) ~= "table" then
        number = math.floor(number)
        if number > 0 and not seen[number] then seen[number] = true; out[#out + 1] = number end
        return
    end
    if type(value) ~= "table" then return end
    if seen[value] then return end
    seen[value] = true
    for _, key in ipairs({ "craftType", "craftTypeId", "craft_type" }) do
        local id = tonumber(value[key])
        if id ~= nil and id > 0 and not seen[math.floor(id)] then
            seen[math.floor(id)] = true; out[#out + 1] = math.floor(id)
        end
    end
    for _, child in pairs(value) do
        if type(child) == "table" or type(child) == "number" then CollectNumbers(child, out, seen, depth + 1) end
    end
end

local ITEM_TYPE_KEYS = { "itemType", "itemTypeId", "item_type", "typeId" }
local COUNT_KEYS = { "count", "amount", "requiredCount", "requireCount", "needCount", "itemCount", "stackCount", "quantity", "num" }
local function FirstNumber(tbl, keys)
    if type(tbl) ~= "table" then return nil end
    for _, key in ipairs(keys or {}) do
        local value = tonumber(tbl[key])
        if value ~= nil and value == value and value > 0 then return value end
    end
    return nil
end
local function ExtractItemRecord(tbl)
    if type(tbl) ~= "table" then return nil end
    local itemType = FirstNumber(tbl, ITEM_TYPE_KEYS)
    if itemType == nil then
        for _, key in ipairs({ "itemInfo", "item", "info", "tooltip", "productInfo", "materialInfo" }) do
            local child = tbl[key]
            if type(child) == "table" then itemType = FirstNumber(child, ITEM_TYPE_KEYS); if itemType ~= nil then break end end
        end
    end
    if itemType == nil then return nil end
    return math.floor(itemType)
end

local function CollectMaterialCandidates(node, inheritedCount, out, seenTables, depth)
    depth = tonumber(depth) or 0
    if type(node) ~= "table" or depth > 6 or seenTables[node] then return end
    seenTables[node] = true
    local count = FirstNumber(node, COUNT_KEYS) or tonumber(inheritedCount)
    if count == nil and type(node[1]) == "table" and tonumber(node[2]) ~= nil then count = tonumber(node[2]) end
    local itemType = ExtractItemRecord(node)
    if itemType ~= nil and count ~= nil and count > 0 then
        local existing = out[itemType]
        if existing == nil or (tonumber(existing.count) or 0) < count then
            out[itemType] = { itemType = itemType, count = count }
        end
    end
    local infos = node.materials or node.materialInfos or node.items
    local counts = node.counts or node.amounts or node.requiredCounts or node.needCounts
    if type(infos) == "table" and type(counts) == "table" then
        for index, child in ipairs(infos) do
            CollectMaterialCandidates(child, tonumber(counts[index]), out, seenTables, depth + 1)
        end
    end
    for key, child in pairs(node) do
        if type(child) == "table" then
            local childCount = count
            if type(key) == "number" and type(node[key + 1]) == "number" then childCount = tonumber(node[key + 1]) or childCount end
            CollectMaterialCandidates(child, childCount, out, seenTables, depth + 1)
        end
    end
end

local function CollectProductItemTypes(node, out, seen, depth)
    depth = tonumber(depth) or 0
    if type(node) ~= "table" or depth > 6 or seen[node] then return end
    seen[node] = true
    local itemType = ExtractItemRecord(node)
    if itemType ~= nil then out[#out + 1] = itemType end
    for _, child in pairs(node) do
        if type(child) == "table" then CollectProductItemTypes(child, out, seen, depth + 1) end
    end
end

local function CallCraft(name, ...)
    if S.Api == nil or type(S.Api.CallCapability) ~= "function" then return false end
    -- object=nil: ResolveCapabilityHost resolves the X2Craft global at CALL
    -- time. A load-time capture missed the namespace entirely on one RU client
    -- ("X2Craft 不可用"), so never cache the host here.
    return S.Api:CallCapability("X2Craft:" .. name, nil, name, ...)
end

-- Explain WHY a capability gate refused, with the underlying host fact. The
-- registry distinguishes "namespace global never built" from "method missing on
-- an existing namespace", but IsAllowed only returns a bare "Unavailable"; the
-- observed StaticState plus a live host probe carries the difference. Without
-- this the report can only say "能力未放行" and the next fix is guesswork
-- (same class of blindness as .18.169's "X2Craft 不可用").
local function CapabilityBlockReason(capabilityName)
    local allowed, reason = S.Api:IsCapabilityAllowed(capabilityName)
    if allowed == true then return nil end
    local detail = tostring(reason or "unknown")
    if S.ApiCapabilities ~= nil and type(S.ApiCapabilities.Describe) == "function" then
        local info = S.ApiCapabilities:Describe(capabilityName)
        if type(info) == "table" then
            detail = detail .. "(static=" .. tostring(info.StaticState or "?")
                .. ", official=" .. tostring(info.OfficialState or "?")
                .. ", runtime=" .. tostring(info.RuntimeState or "?") .. ")"
            local host = rawget(_G, tostring(info.Namespace or "X2Craft"))
            if host == nil then
                detail = detail .. " host_global_missing"
            elseif type(host[tostring(info.Method or "")]) ~= "function" then
                detail = detail .. " method_missing_on_host"
            end
        end
    end
    return capabilityName .. " 未放行: " .. detail
end

-- Returns V3 ingredient rows for a produced itemType, or nil + reason.
-- Fail-closed: a craft whose product side provably does not name the queried
-- itemType is rejected (stale/colliding craftType guard from the legacy code).
local function ReadLiveMaterials(itemType)
    if S.Api == nil or type(S.Api.IsCapabilityAllowed) ~= "function" then return nil, "能力边界不可用" end
    for _, required in ipairs({
        "X2Craft:GetCraftTypeByItemType",
        "X2Craft:GetCraftMaterialInfo",
        "X2Craft:GetCraftProductInfo",
    }) do
        local blockReason = CapabilityBlockReason(required)
        if blockReason ~= nil then return nil, blockReason end
    end
    local ok, a, err, b, c, d = CallCraft("GetCraftTypeByItemType", itemType)
    if ok ~= true then return nil, tostring(err or "craft type 查询失败") end
    local craftTypes, seen = {}, {}
    CollectNumbers(a, craftTypes, seen, 0); CollectNumbers(b, craftTypes, seen, 0)
    CollectNumbers(c, craftTypes, seen, 0); CollectNumbers(d, craftTypes, seen, 0)
    if #craftTypes == 0 then return nil, "craft type 未找到" end
    for index, craftType in ipairs(craftTypes) do
        if index > 4 then break end
        local pok, pa, perr, pb, pc, pd = CallCraft("GetCraftProductInfo", craftType)
        local productTrusted = true
        if pok == true then
            local found, seenProducts = {}, {}
            CollectProductItemTypes(pa, found, seenProducts, 0); CollectProductItemTypes(pb, found, seenProducts, 0)
            CollectProductItemTypes(pc, found, seenProducts, 0); CollectProductItemTypes(pd, found, seenProducts, 0)
            if #found > 0 then
                productTrusted = false
                for _, produced in ipairs(found) do
                    if tonumber(produced) == tonumber(itemType) then productTrusted = true; break end
                end
            end
        elseif perr ~= nil then
            productTrusted = true -- probe unreadable: keep legacy fail-open acceptance
        end
        if productTrusted then
            local mok, ma, merr, mb, mc, md = CallCraft("GetCraftMaterialInfo", craftType, 0)
            if mok == true then
                local candidates, visited = {}, {}
                CollectMaterialCandidates(ma, nil, candidates, visited, 0)
                CollectMaterialCandidates(mb, nil, candidates, visited, 0)
                CollectMaterialCandidates(mc, nil, candidates, visited, 0)
                CollectMaterialCandidates(md, nil, candidates, visited, 0)
                local rows = {}
                for _, candidate in pairs(candidates) do
                    local row = BuildIngredientRow({ materialKey = nil, itemType = candidate.itemType, count = candidate.count })
                    if row ~= nil then rows[#rows + 1] = row end
                end
                table.sort(rows, function(x, y) return (x.itemType or 0) < (y.itemType or 0) end)
                if #rows > 0 then return rows, nil, craftType end
            elseif merr ~= nil then
                M.lastError = "GetCraftMaterialInfo:" .. tostring(merr)
            end
        end
    end
    return nil, "live material info 为空"
end

function M:GetCachedLive(itemType)
    itemType = tonumber(itemType)
    if itemType == nil then return nil end
    local entry = M.liveCache[math.floor(itemType)]
    if type(entry) ~= "table" or entry.status ~= "ready" or type(entry.rows) ~= "table" or #entry.rows == 0 then return nil end
    return entry
end

-- Has a live attempt already TERMINATED for this itemType (ready or failed)?
-- The projection uses this to render 配方未匹配 after a failed attempt instead
-- of an endless 配方解析中 while the request is merely queued/in flight.
function M:HasLiveAttempt(itemType)
    itemType = tonumber(itemType)
    if itemType == nil then return false end
    local entry = M.liveCache[math.floor(itemType)]
    return type(entry) == "table"
end

function M:_StartLane()
    if M.running == true then return end
    if S.Scheduler == nil or type(S.Scheduler.AddTask) ~= "function" then return end
    -- P2: the P3 maintenance lane starves under load (RU evidence .18.168:
    -- 队列=1 读=0 forever). This is a small explicit-demand lane, same class as
    -- the price quote drain.
    local added = S.Scheduler:AddTask(M.taskName, M.intervalMs, function() M:_Drain() end, false, M.owner, "P2", 1)
    if added == true then M.running = true end
end

function M:_StopLane()
    if M.running ~= true then return end
    if S.Scheduler ~= nil and type(S.Scheduler.RemoveTask) == "function" then S.Scheduler:RemoveTask(M.taskName) end
    M.running = false
end

function M:_Drain()
    if M.pending ~= nil then return end
    local request = table.remove(M.queue, 1)
    if request == nil then M:_StopLane(); return end
    M.pending = request
    local rows, err, craftType = ReadLiveMaterials(request.itemType)
    M.liveReads = M.liveReads + 1
    M.pending = nil
    if rows ~= nil and #rows > 0 then
        M.liveCache[request.itemType] = { status = "ready", rows = rows, craftType = craftType, at = NowMs() }
    else
        -- An empty ready payload is a terminal failure too: caching it as
        -- ready would leave the row's projection without rows forever.
        M.liveCache[request.itemType] = { status = "failed", error = tostring(err or (rows ~= nil and "live material info 为空") or "unknown"), at = NowMs() }
        M.lastError = tostring(err or (rows ~= nil and "live material info 为空") or "unknown")
        table.insert(M.recentFailed, 1, { itemType = request.itemType, error = M.lastError, at = NowMs() })
        if #M.recentFailed > M.recentFailedMax then table.remove(M.recentFailed) end
    end
    if type(request.callback) == "function" then
        local ok, cbErr = pcall(function() request.callback(request.itemType) end)
        if not ok and S.DiagnosticsManager ~= nil and type(S.DiagnosticsManager.Warn) == "function" then
            S.DiagnosticsManager:Warn("trade_material_identity", "LIVE_CALLBACK_FAILED", tostring(cbErr or "unknown"), {})
        end
    end
end

-- Explicit entry: requester token enables lifecycle cancellation (feature
-- disable / new route request). Cached itemTypes fire the callback inline.
function M:RequestLive(requester, itemType, callback)
    requester = tostring(requester or "")
    itemType = tonumber(itemType)
    if requester == "" or itemType == nil or itemType ~= math.floor(itemType) then return false, "参数无效" end
    itemType = math.floor(itemType)
    local cached = M.liveCache[itemType]
    if type(cached) == "table" then
        if type(callback) == "function" then pcall(function() callback(itemType) end) end
        return true, "cached"
    end
    for _, request in ipairs(M.queue) do
        if request.itemType == itemType then return true, "queued" end
    end
    if #M.queue >= M.maxQueue then return false, "身份解析队列已满" end
    M.queue[#M.queue + 1] = { requester = requester, itemType = itemType, callback = callback, requestedAt = NowMs() }
    if #M.liveCache >= M.maxCacheEntries then
        -- Bounded session cache: drop the oldest failed entry first.
        local oldestKey, oldestAt = nil, nil
        for key, entry in pairs(M.liveCache) do
            if entry.status ~= "ready" and (oldestAt == nil or (tonumber(entry.at) or 0) < oldestAt) then
                oldestKey, oldestAt = key, (tonumber(entry.at) or 0)
            end
        end
        if oldestKey ~= nil then M.liveCache[oldestKey] = nil end
    end
    M:_StartLane()
    return true, "queued"
end

function M:CancelRequester(requester)
    requester = tostring(requester or "")
    local kept, dropped = {}, 0
    for _, request in ipairs(M.queue) do
        if request.requester == requester then dropped = dropped + 1
        else kept[#kept + 1] = request end
    end
    M.queue = kept
    if #M.queue == 0 and M.pending == nil then M:_StopLane() end
    return dropped
end

function M:Describe()
    local ready, failed = 0, 0
    for _, entry in pairs(M.liveCache) do
        if entry.status == "ready" then ready = ready + 1 else failed = failed + 1 end
    end
    return {
        version = self.version, running = self.running == true, pending = self.pending ~= nil,
        queueLength = #self.queue, maxQueue = self.maxQueue, liveReads = self.liveReads,
        cachedReady = ready, cachedFailed = failed, lastError = self.lastError,
    }
end

function M:GetHealth()
    return self:Describe()
end
