------------------------------------------------------------------------
-- Replicated Suite - Trade Payout Calculator V3
--
-- Pure/data-driven payout calculator for life_trade. X2Store remains the sole
-- Authority for route validity and live specialty ratio; X2Ability remains the
-- Authority for the player's current Commerce proficiency. This service only
-- combines already-observed facts with the static payout table and pack-category
-- multipliers retained from the supplied working Trade implementation.
--
-- No Tick / Scheduler / Native API calls live here. Price-key resolution and
-- larder indexes are built lazily on user-triggered route results.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
S.Services = S.Services or {}

local P = {
    version = 1,
    PriceFormulaContractVersion = 3,
    StaticPriceKeyResolverContractVersion = 2,
    CommerceMultiplierContractVersion = 1,
    PackCategoryMultiplierContractVersion = 3,
    presentationBoundary = "service_only",
    FormulaSource = "ru_live_payout_v3_full_freshness_matrix",
    indexes = {},
}
S.Services.TradePayoutV3 = P

-- Raw server/API names are business identity. These aliases are compatibility
-- candidates only and never replace the sourceName stored on a Trade row.
local PRICE_KEY_ALIASES = {
    ["埋骨之地角笛"] = { "埋骨之地角笛", "埋骨之地狩猎战利品", "埋骨之地狩猎战利品货物" },
    ["埋骨之地狩猎战利品"] = { "埋骨之地角笛", "埋骨之地狩猎战利品", "埋骨之地狩猎战利品货物" },
    ["埋骨之地狩猎战利品货物"] = { "埋骨之地角笛", "埋骨之地狩猎战利品", "埋骨之地狩猎战利品货物" },
    ["Silent Forest Aged Garlic"] = { "Silent Forest Aged Garlic", "[古代森林]糖醋泡蒜" },
}

local DISPLAY_ALIASES = {
    ["埋骨之地角笛"] = "埋骨之地狩猎战利品",
    ["埋骨之地狩猎战利品货物"] = "埋骨之地狩猎战利品",
    ["Silent Forest Aged Garlic"] = "[古代森林]糖醋泡蒜",
}

local LARDER_PREFIXES = { "基本发酵", "保存发酵", "加工发酵", "天然发酵", "无添加发酵", "无添加", "发酵" }
local LARDER_COMMODITIES = {
    { canonical = "奶酪", tokens = { "奶酪", "cheese" } },
    { canonical = "药材", tokens = { "药材", "salve", "herb" } },
    { canonical = "蜂蜜", tokens = { "蜂蜜", "honey" } },
}

local function Text(value)
    return tostring(value or "")
end

local function Number(value)
    local n = tonumber(value)
    if n == nil or n ~= n or n == math.huge or n == -math.huge then return nil end
    return n
end

local function EndsWith(value, suffix)
    value, suffix = Text(value), Text(suffix)
    if suffix == "" or #value < #suffix then return false end
    return string.sub(value, #value - #suffix + 1) == suffix
end

local function DetectCommodity(name)
    local raw = Text(name)
    local low = string.lower(raw)
    for _, commodity in ipairs(LARDER_COMMODITIES) do
        for _, token in ipairs(commodity.tokens) do
            if string.find(raw, token, 1, true) ~= nil or string.find(low, string.lower(token), 1, true) ~= nil then
                return commodity.canonical
            end
        end
    end
    return nil
end

local function DetectPrefix(name)
    local raw = Text(name)
    for _, prefix in ipairs(LARDER_PREFIXES) do
        if string.find(raw, prefix, 1, true) ~= nil then return prefix end
    end
    return nil
end

local function PushUnique(list, seen, value)
    value = Text(value)
    if value == "" or seen[value] then return end
    seen[value] = true
    list[#list + 1] = value
end

function P:ResolveDisplayName(sourceName)
    local raw = Text(sourceName)
    return DISPLAY_ALIASES[raw] or raw
end

function P:BuildPriceIndex(destination)
    destination = Number(destination)
    if destination == nil then return nil end
    destination = math.floor(destination)
    local tableForZone = S.Data and S.Data.TradePrices and S.Data.TradePrices[destination] or nil
    if type(tableForZone) ~= "table" then return nil end
    local cached = self.indexes[destination]
    if type(cached) == "table" and cached.source == tableForZone then return cached end

    local index = { source = tableForZone, origins = {}, larder = {} }
    for key, _ in pairs(tableForZone) do
        local priceKey = Text(key)
        for _, commodity in ipairs(LARDER_COMMODITIES) do
            for _, prefix in ipairs(LARDER_PREFIXES) do
                local suffix = prefix .. commodity.canonical
                if EndsWith(priceKey, suffix) then
                    local origin = string.sub(priceKey, 1, #priceKey - #suffix)
                    if origin ~= "" then
                        index.origins[origin] = true
                        index.larder[origin] = index.larder[origin] or {}
                        index.larder[origin][commodity.canonical] = index.larder[origin][commodity.canonical] or {}
                        index.larder[origin][commodity.canonical][prefix] = priceKey
                    end
                end
            end
        end
    end
    self.indexes[destination] = index
    return index
end

local function OriginCandidates(index, exact, originZoneName)
    local list, seen = {}, {}
    local selected = Text(originZoneName)
    -- Static fallback labels such as "地区 5" are not a localized zone name and
    -- must not be allowed to cross-match a payout origin.
    if selected ~= "" and string.find(selected, "地区 ", 1, true) ~= 1 then
        if index.origins[selected] then PushUnique(list, seen, selected) end
        for origin, _ in pairs(index.origins) do
            if string.find(origin, selected, 1, true) ~= nil or string.find(selected, origin, 1, true) ~= nil then
                PushUnique(list, seen, origin)
            end
        end
    end

    local bracket = string.match(exact, "^%[(.-)%]")
    if bracket ~= nil and bracket ~= "" then
        if index.origins[bracket] then PushUnique(list, seen, bracket) end
        for origin, _ in pairs(index.origins) do
            if string.find(origin, bracket, 1, true) ~= nil or string.find(bracket, origin, 1, true) ~= nil then
                PushUnique(list, seen, origin)
            end
        end
    end
    for origin, _ in pairs(index.origins) do
        if string.find(exact, origin, 1, true) ~= nil then PushUnique(list, seen, origin) end
    end
    return list
end

function P:ResolvePriceKey(destination, itemName, originZoneName)
    local destinationId = Number(destination)
    if destinationId == nil then return nil, "destination_invalid" end
    destinationId = math.floor(destinationId)
    local index = self:BuildPriceIndex(destinationId)
    if type(index) ~= "table" then return nil, "destination_price_table_missing" end
    local tableForZone = index.source
    local exact = Text(itemName)
    if exact ~= "" and tableForZone[exact] ~= nil then return exact, "exact" end

    local aliases = PRICE_KEY_ALIASES[exact]
    if type(aliases) == "table" then
        for _, candidate in ipairs(aliases) do
            if tableForZone[candidate] ~= nil then return candidate, "alias" end
        end
    end

    local commodity = DetectCommodity(exact)
    if commodity == nil then return nil, "price_key_missing" end
    local preferredPrefix = DetectPrefix(exact)
    local candidates = OriginCandidates(index, exact, originZoneName)
    for _, origin in ipairs(candidates) do
        local byPrefix = index.larder[origin] and index.larder[origin][commodity] or nil
        if type(byPrefix) == "table" then
            if preferredPrefix ~= nil and byPrefix[preferredPrefix] ~= nil then
                return byPrefix[preferredPrefix], "larder_origin_prefix"
            end
            for _, prefix in ipairs(LARDER_PREFIXES) do
                if byPrefix[prefix] ~= nil then return byPrefix[prefix], "larder_origin" end
            end
        end
    end
    return nil, "price_key_missing"
end

function P:GetPackMultiplier(itemName, priceKey)
    -- 中文维护（2026-09-27，trade-freshness-matrix-v3）：这里解析的是“最高新鲜度/品类奖励”，
    -- 与 X2Store 返回的实时供需货率严格分离。Authority 只来自维护过的精确 token 表；禁止模糊匹配。
    -- sourceName 优先，是为了尊重 Native 当前商品身份；静态 priceKey 仅作为本地化/别名兜底。
    local sources = { { value = Text(itemName), source = "source_name" }, { value = Text(priceKey), source = "price_key" } }
    for _, source in ipairs(sources) do
        if source.value ~= "" then
            for _, multiplier in ipairs(S.Data and S.Data.TradeNameMultipliers or {}) do
                local token = Text(multiplier.token)
                local value = Number(multiplier.value)
                if token ~= "" and value ~= nil and value > 0 and string.find(source.value, token, 1, true) ~= nil then
                    return value, token, source.source, Text(multiplier.category), Text(multiplier.label)
                end
            end
        end
    end
    local neutral = S.Data and S.Data.TradeNeutralPayoutNames or nil
    for _, source in ipairs(sources) do
        if type(neutral) == "table" and neutral[source.value] == true then
            return 1, nil, source.source, "neutral", "无新鲜度奖励"
        end
    end
    -- 未分类不是“默认 1.00”的同义词。未来新增贸易品若没有补类别规则，继续给数字会再次静默产出错误售价；
    -- 因此明确标记 unclassified，让 Estimate fail-closed，并在模块诊断的覆盖审计中暴露名称。
    return nil, nil, "none", "unclassified", "新鲜度类别未登记"
end

function P:AuditFreshnessCoverage()
    -- 冷路径诊断：只在 Describe/测试调用时遍历静态售价表，不参与刷新/排序循环。它保证每次新增贸易品
    -- 都能看见是否命中类别倍率，避免未来再次出现“某一类名称忘记补倍率却静默按 1.00 计算”。
    local result = { total = 0, categorized = 0, neutral = 0, byCategory = {}, neutralSamples = {} }
    for destination, rows in pairs(S.Data and S.Data.TradePrices or {}) do
        if type(destination) == "number" and type(rows) == "table" then
            for name, _ in pairs(rows) do
                result.total = result.total + 1
                local value, token, _, category = self:GetPackMultiplier(name, name)
                if token ~= nil and Number(value) ~= nil and Number(value) ~= 1 then
                    result.categorized = result.categorized + 1
                    category = category ~= "" and category or token
                    result.byCategory[category] = (tonumber(result.byCategory[category]) or 0) + 1
                elseif category == "neutral" then
                    result.neutral = result.neutral + 1
                    if #result.neutralSamples < 12 then
                        result.neutralSamples[#result.neutralSamples + 1] = tostring(name)
                    end
                else
                    result.unclassified = (tonumber(result.unclassified) or 0) + 1
                    result.unclassifiedSamples = result.unclassifiedSamples or {}
                    if #result.unclassifiedSamples < 12 then
                        result.unclassifiedSamples[#result.unclassifiedSamples + 1] = tostring(name)
                    end
                end
            end
        end
    end
    return result
end

function P:GetCommerceMultiplier(commerceSkill, enabled)
    if enabled ~= true then return 1, false end
    local skill = Number(commerceSkill)
    if skill == nil then return nil, false end
    skill = math.max(0, skill)
    -- Supplied working formula: +5% payout for each 10,000 Commerce points.
    return 1 + (skill / 10000 * 0.05), true
end

function P:Estimate(spec)
    spec = type(spec) == "table" and spec or {}
    local destination = Number(spec.destination)
    local ratio = Number(spec.ratio)
    if destination == nil or ratio == nil then return nil, { status = "route_or_ratio_invalid" } end
    destination = math.floor(destination)
    local priceKey, keyMode = self:ResolvePriceKey(destination, spec.itemName, spec.originZoneName)
    if priceKey == nil then
        return nil, { status = "price_key_missing", keyMode = keyMode, sourceName = Text(spec.itemName) }
    end
    local tableForZone = S.Data and S.Data.TradePrices and S.Data.TradePrices[destination] or nil
    local raw = type(tableForZone) == "table" and tableForZone[priceKey] or nil
    local base = type(raw) == "table" and Number(raw[1]) or Number(raw)
    if base == nil then return nil, { status = "base_price_missing", priceKey = priceKey, keyMode = keyMode } end

    local commerceMultiplier, commerceApplied = self:GetCommerceMultiplier(spec.commerceSkill, spec.includeCommerce == true)
    if commerceMultiplier == nil then
        return nil, {
            status = "commerce_skill_unavailable", priceKey = priceKey, keyMode = keyMode,
            baseCopperPerPercent = base, ratio = ratio,
        }
    end
    local packMultiplier, packToken, packSource, packCategory, packLabel = self:GetPackMultiplier(spec.itemName, priceKey)
    if packMultiplier == nil then
        return nil, {
            status = "freshness_unclassified", priceKey = priceKey, keyMode = keyMode, ratio = ratio,
            packCategory = packCategory, packLabel = packLabel, sourceName = Text(spec.itemName),
        }
    end
    local baseAtRatio = base * ratio
    local price = baseAtRatio * commerceMultiplier * packMultiplier
    return math.floor(price + 0.5), {
        status = "ready", complete = true,
        formulaSource = self.FormulaSource,
        priceKey = priceKey, keyMode = keyMode,
        baseCopperPerPercent = base,
        baseAtRatioCopper = math.floor(baseAtRatio + 0.5),
        ratio = ratio,
        commerceSkill = Number(spec.commerceSkill),
        commerceMultiplier = commerceMultiplier,
        commerceApplied = commerceApplied == true,
        packMultiplier = packMultiplier,
        packToken = packToken,
        packCategory = packCategory,
        packLabel = packLabel,
        packMultiplierSource = packSource,
    }
end

function P:Describe()
    return {
        version = self.version,
        priceFormulaContractVersion = self.PriceFormulaContractVersion,
        priceKeyResolverContractVersion = self.StaticPriceKeyResolverContractVersion,
        commerceMultiplierContractVersion = self.CommerceMultiplierContractVersion,
        packCategoryMultiplierContractVersion = self.PackCategoryMultiplierContractVersion,
        formulaSource = self.FormulaSource,
        freshnessCoverage = self:AuditFreshnessCoverage(),
    }
end
