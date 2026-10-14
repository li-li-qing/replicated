------------------------------------------------------------------------
-- Replicated Suite · 贸易材料身份
-- 作者：Replicated
-- QQ群：1104129461
--
-- 依据本地化货率行解析特产材料；服务拥有身份事实及唯一 X2Craft 访问，Presentation/Feature 不调用 X2Craft。
-- 优先层次：①按产品 itemType 读取 GetCraftTypeByItemType/GetCraftProductInfo/GetCraftMaterialInfo，产品侧证
-- 明查询 itemType 后才信任；按需 250ms 串行，会话按 itemType 缓存。②已验证 Product ItemID，再精确旧名选完整
-- 静态配方；地区或数据库签名冲突则拒绝。③按本地化关键词共享全区相同配方，如发酵/陈化蜂蜜、奶酪、药材、肥料
-- 、时空碎片、蓝盐运输。④originZoneId 从共享目录 nameEn+tradeQuality 决定地区，文本只选 family 尾部：特制特
-- 产=Gilda、传统特产=Local、保存/标准/新鲜/特供特产=Specialty。不能用本地化文本选地区，避免 [十字星] 错映
-- Hasla。无配方且无实况则无身份，显示配方未匹配/解析中；不造材料、不后台扫描，Feature 显式请求期间读取，队
-- 列耗尽或取消即停止。
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
S.Services = S.Services or {}
local M = {
    version = 1,
    IdentityContractVersion = 1,
    presentationBoundary = "service_only",
    -- craft getter 虽 SideEffectFree，每 tick 只做一条链，使路线批次有界且不占快速通道。
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
    recentFailed = {}, -- 失败实时尝试采用最新优先有界环。
    recentFailedMax = 8,
}
S.Services.TradeMaterialIdentityV3 = M

-- S.StaticDataV2 是 GetCatalog/Register 登记表；S.Data.TradeStaticV2 才是包含
-- GetRecipeByLegacyName/GetMaterialByLegacyName/GetMaterialByCompactId 的访问门面。不能误通过登记表查询，否
-- 则每次均静默 nil。
local StaticRegistry = S.StaticDataV2
local StaticFacade = S.Data and S.Data.TradeStaticV2 or nil
local function NowMs()
    if type(S.NowMs) == "function" then return math.max(0, tonumber(S.NowMs()) or 0) end
    return 0
end
local function Contains(text, token)
    return type(text) == "string" and string.find(text, token, 1, true) ~= nil
end

-- 标准英文材料键映射物品身份；静态 trade_material 目录是精选权威。Gilda Star 是配方货币、无自有目录项，须显
-- 式补入。
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

-- 共享 family 配方沿用已提供可工作旧实现的数量×紧凑资源 ID，编号与 S.Data.TradeMaterialResources 一致。
local FAMILY_TABLES = {
    { token = "肥料特产", fallback = "Fertilizer Specialty", template = "template.fertilizer", label = "肥料特产" },
    -- （2026-10-02）蜂蜜/奶酪/药材是材料名称，不是任意货物属于发酵货的证据。
    -- 保留已存在的“基本/加工/无添加发酵”和陈化文案，避免未知特产借到整个发酵配方。
    { counts = { 2, 4, 20, 1 }, ids = { 62, 63, 64, 65 }, token = "发酵蜂蜜", alternate = "陈化蜂蜜", fallback = "Aged Honey", label = "陈化蜂蜜" },
    { counts = { 2, 50, 30, 1 }, ids = { 62, 12, 48, 65 }, token = "发酵奶酪", alternate = "陈化奶酪", fallback = "Aged Cheese", label = "陈化奶酪" },
    { counts = { 2, 20, 30, 1 }, ids = { 62, 66, 13, 65 }, token = "发酵药材", alternate = "陈化药材", fallback = "Aged Salve", label = "陈化药材" },
    { token = "时空碎片", fallback = "Space-Time Fragment", template = "template.fragment", label = "时空碎片运输品" },
    { token = "蓝盐商会运输品", fallback = "Bluesalt Transport", template = "template.transport", label = "蓝盐商会运输品" },
}

-- 本地化尾部映射旧配方 family 词，顺序重要：特制特产先于特产。只选择 family，地区始终来自 originZoneId。
local TAIL_RULES = {
    { token = "特制特产", tail = "Gilda Specialty" },
    { token = "传统特产", tail = "Local Specialty" },
    { token = "肥料特产", tail = "Fertilizer Specialty" },
    { token = "特产", tail = "Specialty" },
}

-- 玩家材料命名统一在此把身份转为官方中文或诚实通用标签。Chopped Produce 等标准英文键、紧凑 ID、craftType、
-- Halcyona Preserved Specialty 等 legacyName 都是数据层事实，不得进入页面或 HUD。优先顺序：按 itemType 的精
-- 选 Localization 权威（用于核验原生名的同表）->本地化静态记录名->调用者 fallback->中性材料/贸易品，绝不输
-- 出原始键。
local function LocalizedItemName(itemType)
    local id = tonumber(itemType)
    if id == nil or S.Localization == nil or type(S.Localization.GetName) ~= "function" then return nil end
    local name = S.Localization:GetName("item", math.floor(id), nil)
    if type(name) ~= "string" or name == "" then return nil end
    -- GetName 无名称时合成 ID <n>，该值不能视为名称。
    if name:match("^ID%s+%d+$") then return nil end
    return name
end

-- 把单材料行解析为玩家可读中文。
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

-- 把路线行或配方产品解析为中文贸易品名；craftType 数字或英文旧配方名不接受。
function M:ResolveProductDisplayName(itemType, fallbackLabel)
    local name = LocalizedItemName(itemType)
    if name ~= nil then return name end
    local label = tostring(fallbackLabel or "")
    if label ~= "" and not label:match("^[A-Za-z0-9_ .%-%+]+$") and not label:match("^%d+$") then return label end
    return "贸易品"
end

function M:ResolveRecipeDisplayName(legacyName)
    local recipe = StaticFacade and type(StaticFacade.GetRecipeByLegacyName) == "function"
        and StaticFacade:GetRecipeByLegacyName(legacyName) or nil
    if type(recipe) ~= "table" then return nil, "recipe_unknown" end
    local productName = LocalizedItemName(recipe.productItemId)
    if productName ~= nil then return productName, "native_item_name" end
    -- （2026-10-03）没有产品 ItemID/客户端名称不等于地区未知。今日任务
    -- 沿用 1.2 的地区显示思路，只读已核配方的 originZoneId；不输出英文键、不猜物品 ID。
    local zones = S.GameIds and S.GameIds.Zone and S.GameIds.Zone.ById or {}
    local zone = zones[tonumber(recipe.originZoneId)]
    local name = type(zone) == "table" and tostring(zone.nameZh or "") or ""
    if name ~= "" then return "[" .. name .. "]特产", "static_origin_zone" end
    return nil, "origin_unknown"
end

local function GetMaterialRecord(ingredient)
    if type(StaticFacade) ~= "table" then return nil end
    local byEn = type(StaticFacade.GetMaterialByLegacyName) == "function" and StaticFacade:GetMaterialByLegacyName(ingredient.materialKey) or nil
    if byEn ~= nil then return byEn end
    local compactId = tonumber(ingredient.compactId)
    if compactId ~= nil and type(StaticFacade.GetMaterialByCompactId) == "function" then
        local byCompact = StaticFacade:GetMaterialByCompactId(compactId)
        if byCompact ~= nil then return byCompact end
    end
    -- 实时 craft 行可能只有 itemType，须解析同一精选材料记录，使绑定/非市场/可拍卖成本策略在静态配方和
    -- X2Craft 兜底间一致。
    local itemType = tonumber(ingredient.itemType)
    if itemType ~= nil and type(StaticFacade.GetMaterialByItemId) == "function" then
        return StaticFacade:GetMaterialByItemId(itemType)
    end
    return nil
end

-- 把旧配方、共享 family 或实时读取的材料归一化为投影行：标准英文 materialKey 用于拍卖元数据查询，记录提供时
-- 使用显式 itemType。
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
    -- （2026-10-02）缺一个材料也不能把剩余材料标成完整配方。
    -- 静态配方只接受真实 ItemID 与正整数需求；绑定资源仍保留，只禁止询价。
    if type(ingredients) ~= "table" then return {} end
    local rows = {}
    for _, ingredient in ipairs(ingredients) do
        local row = BuildIngredientRow(ingredient)
        if row == nil or row.itemType == nil or row.itemType <= 0 or row.itemType ~= math.floor(row.itemType)
            or row.count <= 0 or row.count ~= math.floor(row.count) or row.count == math.huge then return {} end
        rows[#rows + 1] = row
    end
    return rows
end

local function RowsFromFamilyTable(family)
    local counts, ids = family.counts or {}, family.ids or {}
    -- 共享发酵配方同样必须全部材料可证明，不能用 min 静默吃掉未登记尾项。
    if #counts ~= #ids then return {} end
    local ingredients = {}
    for index = 1, #counts do
        ingredients[#ingredients + 1] = { compactId = ids[index], count = counts[index] }
    end
    return RowsFromIngredients(ingredients)
end

local function GetTemplateRecord(key)
    if type(StaticRegistry) ~= "table" or type(StaticRegistry.GetCatalog) ~= "function" then return nil end
    local catalog = StaticRegistry:GetCatalog("trade_recipe_template")
    return type(catalog) == "table" and type(catalog.records) == "table" and catalog.records[tostring(key)] or nil
end

-- 第 2/3 层为纯数据，无原生调用，可安全用于投影构造。
function M:ResolveStatic(sourceName, originZoneId, productItemType)
    local raw = tostring(sourceName or "")
    if type(StaticFacade) ~= "table" or type(StaticFacade.GetRecipeByLegacyName) ~= "function" then return nil end

    local function RecipeResult(recipe, label)
        -- 登记时已发现的数据库签名冲突不得在消费端升级成可信材料。
        -- 货物与路由地区相矛盾时也不借用另一区域；让既有 Live/待匹配路径继续取证。
        if type(recipe) ~= "table" or recipe.ingredientStatus == "database_mismatch" then return nil end
        if tonumber(originZoneId) ~= nil and tonumber(recipe.originZoneId) ~= nil
            and tonumber(originZoneId) ~= tonumber(recipe.originZoneId) then return nil end
        local rows = RowsFromIngredients(recipe and recipe.ingredients or nil)
        if #rows == 0 then return nil end
        return { rows = rows, label = label, source = "static_recipe" }
    end

    -- （2026-10-02）货率回执已提供真实商品 ItemID 时，先查已核 TradeProduct
    -- 的精确配方身份，不因汉化变更/货物名中的“特产”猜品类。纯任务标题没有 ItemID，仍走地区链。
    local products = S.GameIds and S.GameIds.TradeProduct
    local product = type(products) == "table" and type(products.GetByItemId) == "function"
        and tonumber(productItemType) ~= nil and products:GetByItemId(productItemType) or nil
    if type(product) == "table" then
        local recipe = StaticFacade:GetRecipeByLegacyName(product.legacyName)
        if type(recipe) ~= "table" or tonumber(recipe.productItemId) ~= tonumber(productItemType) then return nil end
        return RecipeResult(recipe, tostring(recipe.legacyName))
    end
    if raw == "" then return nil end

    -- 精确旧名直接命中；服务器身份可能直接匹配。
    local direct = StaticFacade:GetRecipeByLegacyName(raw)
    if direct ~= nil then
        return RecipeResult(direct, tostring(direct.legacyName or raw))
    end

    -- 共享 family 仅按关键词匹配，各地区配方相同。
    for _, family in ipairs(FAMILY_TABLES) do
        if Contains(raw, family.token) or (family.alternate ~= nil and Contains(raw, family.alternate)) or Contains(raw, family.fallback or "") then
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

    -- 地区权威配合本地化 family 尾部。
    local zoneId = tonumber(originZoneId)
    local zones = S.GameIds and S.GameIds.Zone and S.GameIds.Zone.ById or nil
    local zone = type(zones) == "table" and zones[zoneId] or nil
    local zoneEn = type(zone) == "table" and tostring(zone.nameEn or "") or ""
    local quality = type(zone) == "table" and tostring(zone.tradeQuality or "") or ""
    if zoneEn == "" or quality == "" then return nil end
    local tail = nil
    local suffix = raw:match("^%s*(.-)%s*$") or raw
    for _, rule in ipairs(TAIL_RULES) do
        -- （2026-10-02）日常标题开头的“[特产]”与自定义“皮毯特产”不是标准货物品类。
        -- 中文普通特产需证明保存/标准/新鲜/特供后缀；更具体的传统/特制仍优先，英文保持完整词尾匹配。
        local localized = suffix:sub(-#rule.token) == rule.token
        if rule.tail == "Specialty" and localized then
            localized = false
            for _, qualityZh in ipairs({ "保存", "标准", "新鲜", "特供" }) do
                local ending = qualityZh .. rule.token
                if suffix:sub(-#ending) == ending then localized = true; break end
            end
            if quality == "Coastal" and Contains(raw, zoneEn .. " Coastal") then localized = true end
        end
        local english = suffix:sub(-#rule.tail) == rule.tail
        if localized or english then tail = rule.tail; break end
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

-- 实时 craft 身份采用有界显式队列，每 tick 一条 X2Craft 链。
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
    -- object=nil 使 ResolveCapabilityHost 在调用时解析 X2Craft 全局；某 RU 加载时捕获会错过整个命名空间，不
    -- 能在此缓存 host。
    return S.Api:CallCapability("X2Craft:" .. name, nil, name, ...)
end

-- 能力拒绝须结合宿主事实解释：登记表可区分命名空间从未构造与已有命名空间缺方法，但 IsAllowed 仅返
-- Unavailable。StaticState 加实时 host 探测提供区别，避免报告只有“能力未放行”而让维护靠猜测。
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

-- 返回产品 itemType 的 V3 材料行，或 nil+reason；产品侧可证明不对应查询 itemType 的 craft 必须拒绝，防
-- stale 或碰撞 craftType。
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
            productTrusted = true -- 产品探测不可读时保留当前允许继续的兼容行为。
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

-- 检查 itemType 实时尝试是否已终止（ready/failed）；失败后投影显示配方未匹配，不把已经失败误作仍排队/在途而
-- 永久解析中。
function M:HasLiveAttempt(itemType)
    itemType = tonumber(itemType)
    if itemType == nil then return false end
    local entry = M.liveCache[math.floor(itemType)]
    return type(entry) == "table"
end

function M:_StartLane()
    if M.running == true then return end
    if S.Scheduler == nil or type(S.Scheduler.AddTask) ~= "function" then return end
    -- P2 用于小型显式需求，与报价 drain 同类；RU .18.168 证据显示 P3 在负载下会长期队列=1、读=0 饥饿。
    local added = S.Scheduler:AddTask(M.taskName, M.intervalMs, function() M:_Drain() end, false, M.owner, "P2", 1)
    if added == true then M.running = true end
end

function M:_StopLane()
    if M.running ~= true then return end
    if S.Scheduler ~= nil and type(S.Scheduler.RemoveTask) == "function" then S.Scheduler:RemoveTask(M.taskName) end
    M.running = false
end

-- liveCache 按 itemType 使用稀疏键，Lua 5.1 # 不表示哈希表项数，不能用其检查 128 项上限。预算统一在写入点执
-- 行：先淘汰最旧失败项，再淘汰最旧 ready，不在查询循环反复遍历，不驱逐尚未进入缓存的 pending。
local function TrimLiveCacheForInsert()
    local maxEntries = math.max(1, math.floor(tonumber(M.maxCacheEntries) or 128))
    local count = 0
    local oldestFailedKey, oldestFailedAt = nil, nil
    local oldestAnyKey, oldestAnyAt = nil, nil
    for key, entry in pairs(M.liveCache) do
        count = count + 1
        local at = type(entry) == "table" and (tonumber(entry.at) or 0) or 0
        if oldestAnyAt == nil or at < oldestAnyAt then oldestAnyKey, oldestAnyAt = key, at end
        if type(entry) ~= "table" or entry.status ~= "ready" then
            if oldestFailedAt == nil or at < oldestFailedAt then oldestFailedKey, oldestFailedAt = key, at end
        end
    end
    if count < maxEntries then return false end
    local evictKey = oldestFailedKey or oldestAnyKey
    if evictKey ~= nil then M.liveCache[evictKey] = nil; return true end
    return false
end

function M:_Drain()
    if M.pending ~= nil then return end
    local request = table.remove(M.queue, 1)
    if request == nil then M:_StopLane(); return end
    M.pending = request
    local rows, err, craftType = ReadLiveMaterials(request.itemType)
    M.liveReads = M.liveReads + 1
    M.pending = nil
    TrimLiveCacheForInsert()
    if rows ~= nil and #rows > 0 then
        M.liveCache[request.itemType] = { status = "ready", rows = rows, craftType = craftType, at = NowMs() }
    else
        -- 空 ready payload 也属终态失败；缓存为 ready 会让投影永久无行。
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

-- 显式 requester token 支持功能禁用或新路线请求时生命周期取消；itemType 缓存命中立即同步回调。
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
