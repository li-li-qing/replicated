------------------------------------------------------------------------
-- Replicated Suite V3 - tools_craft Feature Authority
--
-- Phase 1 Batch D（2026-09-28）：从 features/rs_business_bridge.lua 机械搬迁。
-- 只改变源码边界，不改业务行为：Feature ID、Store ID/Schema、UpdateTopic、Demand owner、
-- Commands、Projection shape、ApiDependencies、CraftUserSelectionContractVersion 与
-- 有界提取器上限（CRAFT_MAX_*/CRAFT_GRAPH_*）全部与被搬迁前逐字一致。
--
-- Authority 边界：制作配方与材料事实来自 X2Craft / X2Bag 只读接口，报价来自共享 PriceQuoteQueueV3；
-- 本文件只做有界解析与投影整形，普通 Refresh 绝不发起逐行询价。
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local FSF = S.FeatureSliceFactory
if type(FSF) ~= "table" then error("FeatureSliceFactory unavailable for tools_craft") end
local Call, Copy, Number, Scalar, Text, NewFeature = FSF.Call, FSF.Copy, FSF.Number, FSF.Scalar, FSF.Text, FSF.NewFeature
local P = S.Persistence
local BagApi = rawget(_G, "X2Bag")
local CraftApi = rawget(_G, "X2Craft")
-- 中文维护注释：背包扫描上界是平台级共享值（tools_bag 与 craft 共用），
-- 唯一 Authority 是 features/shared/rs_shared_bounds.lua，禁止在本文件另写数字。
local BAG_SCAN_LIMIT = S.SharedBounds and S.SharedBounds.BagScanLimit
if type(BAG_SCAN_LIMIT) ~= "number" then error("SharedBounds.BagScanLimit unavailable for tools_craft") end

-- Life/tools data reads with an explicit craft context.  The native craft
-- payloads are not a stable Lua schema, so this deliberately keeps a small
-- bounded extractor here instead of presenting an opaque "list returned"
-- string as a completed product capability.  The same read/command/projection
-- objects are registered for both craft features below.
local CRAFT_MAX_TYPES = 16
local CRAFT_MAX_ROWS = 64
local CRAFT_MAX_NODES = 256
local CRAFT_TEXT_LIMIT = 768
local CRAFT_ITEM_TYPE_KEYS = { "itemType", "itemTypeId", "item_type", "typeId" }
local CRAFT_NAME_KEYS = { "name", "itemName", "displayName", "title" }
local CRAFT_COUNT_KEYS = { "count", "amount", "requiredCount", "requireCount", "needCount", "itemCount", "stackCount", "quantity", "num" }
local CRAFT_GRADE_KEYS = { "itemGrade", "grade", "item_grade", "gradeId" }

local function CraftInteger(value, allowZero)
    local n = Number(Scalar(value))
    if n == nil or n ~= math.floor(n) or (allowZero and n < 0 or not allowZero and n < 1) then return nil end
    return math.floor(n)
end

local function CraftText(value, fallback)
    local text = value == nil and (fallback or "") or tostring(value)
    if #text <= CRAFT_TEXT_LIMIT then return text, false end
    return text:sub(1, CRAFT_TEXT_LIMIT) .. "…", true
end

local function CraftNumberField(value, keys)
    if type(value) ~= "table" then return nil end
    for _, key in ipairs(keys or {}) do
        local number = CraftInteger(value[key], false)
        if number ~= nil then return number end
    end
    return nil
end

local function CraftTextField(value, keys)
    if type(value) ~= "table" then return nil end
    for _, key in ipairs(keys or {}) do
        local text = value[key]
        if type(text) == "string" and text ~= "" then return text end
    end
    return nil
end

local function CraftRecord(value, inheritedCount)
    if type(value) ~= "table" then return nil end
    local itemType = CraftNumberField(value, CRAFT_ITEM_TYPE_KEYS)
    local name = CraftTextField(value, CRAFT_NAME_KEYS)
    local count = CraftNumberField(value, CRAFT_COUNT_KEYS) or inheritedCount
    local grade = CraftNumberField(value, CRAFT_GRADE_KEYS)
    for _, key in ipairs({ "itemInfo", "item", "info", "productInfo", "materialInfo" }) do
        local child = value[key]
        if type(child) == "table" then
            itemType = itemType or CraftNumberField(child, CRAFT_ITEM_TYPE_KEYS)
            name = name or CraftTextField(child, CRAFT_NAME_KEYS)
            count = count or CraftNumberField(child, CRAFT_COUNT_KEYS)
            grade = grade or CraftNumberField(child, CRAFT_GRADE_KEYS)
        end
    end
    -- A few native bindings expose { itemType, count } pairs instead of named
    -- fields.  Accept that shape only when the first scalar is a positive ID.
    if itemType == nil and type(value[1]) ~= "table" then itemType = CraftInteger(value[1], false) end
    if count == nil and type(value[2]) ~= "table" then count = CraftInteger(value[2], true) end
    if itemType == nil and name == nil and count == nil then return nil end
    return {
        itemType = itemType,
        name = name,
        count = count,
        grade = grade,
        status = itemType ~= nil and name ~= nil and count ~= nil and "ready" or "missing",
    }
end

local function CraftCollectRecords(payload)
    local rows, seen, diagnostics = {}, {}, { sourceCount = 0, truncated = false, nodes = 0 }
    local function visit(value, inheritedCount, depth)
        if type(value) ~= "table" then return end
        if depth > 8 or seen[value] then return end
        seen[value] = true
        diagnostics.nodes = diagnostics.nodes + 1
        if diagnostics.nodes > CRAFT_MAX_NODES then diagnostics.truncated = true; return end
        local record = CraftRecord(value, inheritedCount)
        if record ~= nil then
            diagnostics.sourceCount = diagnostics.sourceCount + 1
            if #rows < CRAFT_MAX_ROWS then rows[#rows + 1] = record else diagnostics.truncated = true end
        end
        -- Visit arrays first for deterministic native list order, then named
        -- children.  Identity wrappers are already folded into this record.
        for index, child in ipairs(value) do
            if type(child) == "table" then visit(child, CraftNumberField(value, CRAFT_COUNT_KEYS), depth + 1) end
        end
        for key, child in pairs(value) do
            if type(child) == "table" and type(key) ~= "number" and key ~= "itemInfo" and key ~= "item" and key ~= "info" and key ~= "productInfo" and key ~= "materialInfo" then
                visit(child, CraftNumberField(value, CRAFT_COUNT_KEYS), depth + 1)
            end
        end
    end
    visit(payload, nil, 0)
    return rows, diagnostics
end

local CRAFT_STATUS_ZH = {
    ready = "可用", incomplete = "部分可用", failed = "读取失败", empty = "暂无数据",
    opaque = "字段待核", partial = "部分可用", unavailable = "不可用", resolved = "已匹配",
    missing = "字段不完整", idle = "等待选择",
}
local CRAFT_ZONE_ZH = {
    [1]="格威尔森林", [2]="玛瑞诺普", [3]="碎石平原", [4]="黎明半岛", [5]="索兹里德半岛",
    [6]="黎利尔丘陵", [7]="彩虹荒野", [8]="双冠丘陵", [9]="摩哈特比", [10]="空气之原",
    [11]="猎鹰高原", [12]="咏唱之地", [13]="烈日峡谷", [14]="风刃废墟", [15]="棋盘石林",
    [16]="洛卡棋盘", [17]="伊尼斯泰尔", [18]="白雪森林", [19]="埋骨之地", [20]="十字星平原",
    [21]="珊瑚海岸北部", [22]="黄金平原", [23]="翡翠谷", [24]="虎脊山脉", [25]="古代森林",
    [26]="地狱沼泽", [27]="珊瑚海岸", [54]="墟境之口", [56]="煦日之野", [57]="黄金废墟",
    [93]="安息之地", [99]="洛卡山脉", [102]="海之烛台", [103]="鲸鱼歌湾",
}
local function CraftStatusText(value) return CRAFT_STATUS_ZH[tostring(value or "")] or tostring(value or "未知") end
local function CraftItemName(itemType, nativeName)
    local id = tonumber(itemType)
    if id ~= nil and S.Localization ~= nil and type(S.Localization.GetName) == "function" then
        local ok, value = pcall(S.Localization.GetName, S.Localization, "item", id, nil)
        if ok == true and type(value) == "string" and value ~= "" then return value end
    end
    if type(nativeName) == "string" and nativeName ~= "" and nativeName:find("[\128-\255]") ~= nil then return nativeName end
    return id ~= nil and "已识别物品" or "物品"
end
local function CraftFamilyLabel(record)
    local name = tostring(type(record)=="table" and record.legacyName or "")
    if name:find("Gilda Specialty",1,true) then return "特制特产" end
    if name:find("Local Specialty",1,true) then return "传统特产" end
    if name:find("Fertilizer Specialty",1,true) then return "肥料特产" end
    return "特产"
end
local CRAFT_RECIPE_OPTIONS
local function CraftRecipeOptions()
    if type(CRAFT_RECIPE_OPTIONS)=="table" then return CRAFT_RECIPE_OPTIONS end
    local rows = {}
    local static = S.StaticDataV2
    if type(static)=="table" and type(static.List)=="function" then
        for _, record in ipairs(static:List("trade_recipe")) do
            local craftId = tonumber(record and record.craftId)
            if craftId ~= nil and type(record.key)=="string" then
                local zone = CRAFT_ZONE_ZH[tonumber(record.originZoneId)] or "已核地区"
                rows[#rows+1] = { value=record.key, text=zone .. " · " .. CraftFamilyLabel(record), craftId=math.floor(craftId) }
            end
        end
    end
    table.sort(rows,function(a,b) if a.text==b.text then return tostring(a.value)<tostring(b.value) end return a.text<b.text end)
    CRAFT_RECIPE_OPTIONS = rows
    return CRAFT_RECIPE_OPTIONS
end
local function SelectedCraftRecipe(feature)
    local key = type(feature.State)=="table" and feature.State.selectedRecipeKey or nil
    if type(key)~="string" or key=="" or S.StaticDataV2==nil or type(S.StaticDataV2.Get)~="function" then return nil end
    return S.StaticDataV2:Get("trade_recipe",key)
end
local function CraftStaticItems(recipe)
    local rows = {}
    if type(recipe)~="table" or type(recipe.ingredients)~="table" then return rows end
    for _, ingredient in ipairs(recipe.ingredients) do
        local material = S.StaticDataV2 and type(S.StaticDataV2.Get)=="function" and S.StaticDataV2:Get("trade_material",ingredient.materialKey) or nil
        local itemType = tonumber(material and material.itemId)
        rows[#rows+1] = {
            itemType=itemType, count=tonumber(ingredient.count), name=CraftItemName(itemType,nil),
            status=itemType~=nil and "ready" or "missing", source="TradeStaticV2",
        }
    end
    return rows
end
local function CraftItemText(item)
    local name = CraftItemName(item and item.itemType, item and item.name)
    local count = item and item.count ~= nil and tostring(item.count) or "数量待核"
    local held = item and item.held ~= nil and (" · 持有 " .. tostring(item.held)) or ""
    local shortage = item and item.shortage ~= nil and (" · 缺口 " .. tostring(item.shortage)) or ""
    local quote = ""
    if item and item.unitCost ~= nil then
        local unitText = tostring(math.floor((tonumber(item.unitCost) or 0) + 0.5))
        local lineText = item.lineCost ~= nil and tostring(math.floor((tonumber(item.lineCost) or 0) + 0.5)) or nil
        if S.Utils ~= nil and type(S.Utils.FormatMoney) == "function" then
            local okUnit, formattedUnit = pcall(S.Utils.FormatMoney, tonumber(item.unitCost) or 0)
            if okUnit == true and type(formattedUnit) == "string" and formattedUnit ~= "" then unitText = formattedUnit end
            if item.lineCost ~= nil then
                local okLine, formattedLine = pcall(S.Utils.FormatMoney, tonumber(item.lineCost) or 0)
                if okLine == true and type(formattedLine) == "string" and formattedLine ~= "" then lineText = formattedLine end
            end
        end
        quote = " · 单价 " .. unitText
        if lineText ~= nil then quote = quote .. " · 小计 " .. lineText end
    elseif item and item.costStatus == "explicit_quote_required" and item.itemType ~= nil then
        quote = " · 未询价"
    end
    return name .. " × " .. count .. held .. shortage .. quote
end

local function CraftQuote(item)
    if item == nil or item.itemType == nil then return nil, "identity_unknown" end
    -- GetLowestPrice is a cooldown-bound server query. A craft graph can contain
    -- many materials, so ordinary Refresh must never fan out one request per row.
    -- Pricing belongs to the explicit, rate-limited PriceQuoteQueueV3 service:
    -- the user triggers QuoteMaterial per material, the queue serializes + paces
    -- + async-callbacks the result, and the completed price is exposed through
    -- the shared itemType read model. Here we only READ that read model — never
    -- issue a server request from a Refresh.
    local queue = S.Services ~= nil and S.Services.PriceQuoteQueueV3 or nil
    local price
    if type(queue) == "table" and type(queue.GetPriceByItemType) == "function" then
        price = queue:GetPriceByItemType(item.itemType, item.itemGrade)
    end
    if price ~= nil then return price, "quoted" end
    return nil, "explicit_quote_required", "最低价需显式询价"
end

local function CraftHeldCounts()
    local held, diagnostics = {}, { status = "unknown", scanned = 0, readErrors = 0, unknownOccupied = 0, capacity = nil }
    local bag = BagApi or rawget(_G, "X2Bag")
    if bag == nil then return held, diagnostics end
    local ok, capacity = Call("X2Bag:Capacity", bag, "Capacity")
    capacity = CraftInteger(capacity, true)
    if ok ~= true or capacity == nil then diagnostics.error = "背包容量未知"; return held, diagnostics end
    diagnostics.capacity = math.min(capacity, BAG_SCAN_LIMIT); diagnostics.status = "ready"
    for slot = 1, diagnostics.capacity do
        local itemOk, info = Call("X2Bag:GetBagItemInfo", bag, "GetBagItemInfo", 0, slot)
        diagnostics.scanned = diagnostics.scanned + 1
        if itemOk ~= true then
            diagnostics.readErrors = diagnostics.readErrors + 1
        elseif type(info) == "table" then
            local id = CraftNumberField(info, CRAFT_ITEM_TYPE_KEYS)
            local count = CraftNumberField(info, CRAFT_COUNT_KEYS)
            if id ~= nil and count ~= nil then held[id] = (held[id] or 0) + count
            elseif next(info) ~= nil then diagnostics.unknownOccupied = diagnostics.unknownOccupied + 1 end
        elseif info ~= nil then
            diagnostics.unknownOccupied = diagnostics.unknownOccupied + 1
        end
    end
    if diagnostics.readErrors > 0 or diagnostics.unknownOccupied > 0 or capacity > BAG_SCAN_LIMIT then
        diagnostics.status = "incomplete"
        diagnostics.error = diagnostics.readErrors > 0 and "背包槽位读取失败" or diagnostics.unknownOccupied > 0 and "背包存在身份未知的非空槽位" or "背包扫描达到上限"
    end
    return held, diagnostics
end

local function CraftEnrichItems(items, held, bagDiagnostics)
    local bagReady = bagDiagnostics and bagDiagnostics.status == "ready"
    local incomplete = not bagReady
    for _, item in ipairs(items or {}) do
        item.held = item.itemType ~= nil and (held[item.itemType] or (bagReady and 0 or nil)) or nil
        item.shortage = item.count ~= nil and item.held ~= nil and math.max(0, item.count - item.held) or nil
        item.unitCost, item.costStatus = CraftQuote(item)
        item.lineCost = item.unitCost ~= nil and item.count ~= nil and item.unitCost * item.count or nil
        item.status = (item.itemType ~= nil and item.count ~= nil and item.unitCost ~= nil and item.held ~= nil) and "ready" or "incomplete"
        if not bagReady then item.status = "incomplete" end
        if item.status ~= "ready" then incomplete = true end
    end
    return incomplete
end

local function CraftSection(kind, ok, payload, errorText, craftType, doodadId)
    local section = {
        kind = kind, source = "X2Craft:GetCraft" .. (kind == "base" and "BaseInfo" or kind == "product" and "ProductInfo" or "MaterialInfo"),
        craftType = craftType, doodadId = doodadId, failed = false, empty = false, opaque = false,
        truncated = false, sourceCount = 0, items = {}, status = "empty",
    }
    if ok ~= true then
        section.failed = true; section.status = "failed"; section.error = Text(errorText, "原生数据读取失败")
        section.text = (kind == "product" and "产物" or "材料") .. "读取失败：" .. section.error
        return section
    end
    if payload == nil then
        section.empty = true; section.text = (kind == "product" and "产物" or "材料") .. "暂无数据"
        return section
    end
    if type(payload) ~= "table" then
        section.opaque = true; section.status = "opaque"
        section.text, section.textTruncated = CraftText((kind == "product" and "产物" or "材料") .. "返回字段待核", nil)
        return section
    end
    if next(payload) == nil then
        section.empty = true; section.text = (kind == "product" and "产物" or "材料") .. "暂无数据"
        return section
    end
    local records, diagnostics = CraftCollectRecords(payload)
    section.items, section.sourceCount, section.truncated = records, diagnostics.sourceCount, diagnostics.truncated
    if #records == 0 then
        section.opaque = true; section.status = "opaque"
        section.text = (kind == "product" and "产物" or "材料") .. "返回结构待核"
        return section
    end
    section.status = "ready"
    local parts = {}
    for index, item in ipairs(records) do parts[index] = CraftItemText(item) end
    if section.truncated then
        local suffix = "已截断，原始记录 " .. tostring(section.sourceCount) .. " 条"
        local prefixLimit = math.max(32, CRAFT_TEXT_LIMIT - #suffix - #kind - 6)
        local prefix = ((kind == "product" and "产物：" or "材料：") .. table.concat(parts, "；")):sub(1, prefixLimit)
        section.text = prefix .. "… " .. suffix
        section.textTruncated = true
    else
        section.text, section.textTruncated = CraftText((kind == "product" and "产物：" or "材料：") .. table.concat(parts, "；"), nil)
    end
    return section
end

local function CraftBaseSection(ok, payload, errorText, craftType)
    local section = { kind = "base", source = "X2Craft:GetCraftBaseInfo", craftType = craftType, failed = false, empty = false, opaque = false, truncated = false, fields = {}, status = "empty" }
    if ok ~= true then section.failed = true; section.status = "failed"; section.error = Text(errorText, "读取失败"); section.text = "基础信息读取失败：" .. section.error; return section end
    if payload == nil then section.empty = true; section.text = "基础信息暂无数据"; return section end
    if type(payload) ~= "table" then section.opaque = true; section.status = "opaque"; section.text, section.textTruncated = CraftText("基础信息返回字段待核", nil); return section end
    if next(payload) == nil then section.empty = true; section.text = "基础信息暂无数据"; return section end
    for _, key in ipairs({ "craftType", "craftTypeId", "name", "title", "itemType", "itemTypeId", "level", "duration", "doodadId" }) do
        local value = payload[key]
        if type(value) == "number" or type(value) == "string" then section.fields[key] = value end
    end
    if next(section.fields) == nil then section.opaque = true; section.status = "opaque"; section.text = "基础信息返回结构待核"; return section end
    section.status = "ready"
    local parts = {}
    for _, key in ipairs({ "craftType", "craftTypeId", "name", "title", "itemType", "itemTypeId", "level", "duration", "doodadId" }) do
        if section.fields[key] ~= nil then parts[#parts + 1] = key .. "=" .. tostring(section.fields[key]) end
    end
    section.text, section.textTruncated = CraftText("基础信息已读取（详细字段仅用于诊断）", nil)
    return section
end

local function CraftCollectTypeIds(value, output, seen, depth)
    if #output >= CRAFT_MAX_TYPES or depth > 6 then return end
    local scalar = CraftInteger(value, false)
    if scalar ~= nil and type(value) ~= "table" then
        if not seen[scalar] then seen[scalar] = true; output[#output + 1] = scalar end
        return
    end
    if type(value) ~= "table" or seen[value] then return end
    seen[value] = true
    for _, key in ipairs({ "craftType", "craftTypeId", "craft_type" }) do
        local id = CraftInteger(value[key], false)
        if id ~= nil and not seen[id] then seen[id] = true; output[#output + 1] = id end
    end
    for key, child in pairs(value) do
        if type(key) == "number" or key == "craftTypes" or key == "types" or key == "list" then CraftCollectTypeIds(child, output, seen, depth + 1) end
    end
end

-- Bounded graph projection over records already returned by the verified
-- X2Craft getters. This deliberately does not enumerate the catalog or issue
-- recursive API calls: unknown children remain visible as unresolved leaves.
local CRAFT_GRAPH_MAX_DEPTH = 6
local CRAFT_GRAPH_MAX_NODES = 256
local CRAFT_GRAPH_MAX_QUANTITY = 1000000000

local function CraftGraphInteger(value)
    local n = tonumber(value)
    if n == nil or n ~= math.floor(n) or n < 1 then return nil end
    return math.floor(n)
end

local function CraftGraphRecordMap(records, diagnostics)
    local byProduct, ambiguous = {}, {}
    for _, recipe in ipairs(type(records) == "table" and records or {}) do
        local craftType = CraftGraphInteger(recipe and recipe.craftType)
        local products = recipe and recipe.product and recipe.product.items
        if craftType == nil or type(products) ~= "table" then
            diagnostics.missingRecords = diagnostics.missingRecords + 1
        else
            for _, product in ipairs(products) do
                local itemType = CraftGraphInteger(product and product.itemType)
                if itemType ~= nil then
                    if byProduct[itemType] ~= nil and byProduct[itemType] ~= craftType then
                        ambiguous[itemType] = true
                    else
                        byProduct[itemType] = craftType
                    end
                else
                    diagnostics.malformedProducts = diagnostics.malformedProducts + 1
                end
            end
        end
    end
    for itemType in pairs(ambiguous) do byProduct[itemType] = nil; diagnostics.ambiguous = diagnostics.ambiguous + 1 end
    return byProduct
end

function S.BuildCraftRecipeGraph(records, roots)
    local diagnostics = {
        status = "ready", nodes = 0, edges = 0, maxDepth = 0, unresolved = 0,
        cycles = 0, ambiguous = 0, missingRecords = 0, malformedProducts = 0,
        malformedMaterials = 0, quantityOverflow = 0, truncated = false,
    }
    local byCraft, byProduct = {}, CraftGraphRecordMap(records, diagnostics)
    for _, recipe in ipairs(type(records) == "table" and records or {}) do
        local craftType = CraftGraphInteger(recipe and recipe.craftType)
        if craftType ~= nil then byCraft[craftType] = recipe end
    end
    local graph = { roots = {}, nodes = {}, edges = {}, diagnostics = diagnostics, maxDepth = CRAFT_GRAPH_MAX_DEPTH, maxNodes = CRAFT_GRAPH_MAX_NODES }
    local function visit(itemType, quantity, depth, path)
        if diagnostics.nodes >= CRAFT_GRAPH_MAX_NODES then diagnostics.truncated = true; return nil end
        local item = CraftGraphInteger(itemType); local amount = CraftGraphInteger(quantity)
        if item == nil or amount == nil then diagnostics.malformedMaterials = diagnostics.malformedMaterials + 1; return nil end
        if amount > CRAFT_GRAPH_MAX_QUANTITY then diagnostics.quantityOverflow = diagnostics.quantityOverflow + 1; return nil end
        diagnostics.nodes = diagnostics.nodes + 1; diagnostics.maxDepth = math.max(diagnostics.maxDepth, depth)
        local node = { itemType = item, quantity = amount, depth = depth, status = "unresolved" }
        graph.nodes[#graph.nodes + 1] = node
        local craftType = byProduct[item]
        if depth >= CRAFT_GRAPH_MAX_DEPTH then diagnostics.truncated = true; node.status = "depth_limit"; diagnostics.unresolved = diagnostics.unresolved + 1; return node end
        if craftType == nil then diagnostics.unresolved = diagnostics.unresolved + 1; return node end
        if path[craftType] then diagnostics.cycles = diagnostics.cycles + 1; node.status = "cycle"; diagnostics.unresolved = diagnostics.unresolved + 1; return node end
        local recipe = byCraft[craftType]; local materials = recipe and recipe.materials and recipe.materials.items
        if type(materials) ~= "table" or recipe.materials.failed == true or recipe.materials.opaque == true then
            diagnostics.unresolved = diagnostics.unresolved + 1; node.status = "missing_materials"; return node
        end
        node.status = "expanded"; node.craftType = craftType
        local nextPath = {}; for key, value in pairs(path) do nextPath[key] = value end; nextPath[craftType] = true
        for _, material in ipairs(materials) do
            local materialType = CraftGraphInteger(material and material.itemType)
            local required = CraftGraphInteger(material and material.count)
            if materialType == nil or required == nil then
                diagnostics.malformedMaterials = diagnostics.malformedMaterials + 1
            else
                local productCount = 1
                local productItems = recipe.product and recipe.product.items or {}
                for _, product in ipairs(productItems) do if CraftGraphInteger(product.itemType) == item then productCount = CraftGraphInteger(product.count) or 1; break end end
                local craftCount = math.floor((amount + productCount - 1) / productCount)
                local total = required
                if craftCount > math.floor(CRAFT_GRAPH_MAX_QUANTITY / math.max(1, required)) then total = CRAFT_GRAPH_MAX_QUANTITY + 1 else total = required * craftCount end
                if total > CRAFT_GRAPH_MAX_QUANTITY then diagnostics.quantityOverflow = diagnostics.quantityOverflow + 1
                else graph.edges[#graph.edges + 1] = { from = item, to = materialType, quantity = total, craftType = craftType }; diagnostics.edges = diagnostics.edges + 1; visit(materialType, total, depth + 1, nextPath) end
            end
        end
        return node
    end
    for _, root in ipairs(type(roots) == "table" and roots or {}) do
        local itemType = CraftGraphInteger(root and root.itemType or root)
        local quantity = CraftGraphInteger(root and root.quantity or 1)
        if itemType ~= nil and quantity ~= nil then graph.roots[#graph.roots + 1] = visit(itemType, quantity, 0, {}) else diagnostics.malformedMaterials = diagnostics.malformedMaterials + 1 end
    end
    if diagnostics.truncated or diagnostics.quantityOverflow > 0 or diagnostics.cycles > 0 or diagnostics.ambiguous > 0 or diagnostics.unresolved > 0 then diagnostics.status = "partial" end
    return graph
end

local function CraftResolveTypes(feature)
    local state = feature.State or {}
    local itemType = state.itemType == nil and nil or CraftInteger(state.itemType, false)
    local craftType = state.craftType == nil and nil or CraftInteger(state.craftType, false)
    if (state.itemType ~= nil and itemType == nil) or (state.craftType ~= nil and craftType == nil) then return {}, { status = "failed", error = "制作物内部标识无效，请重新选择" } end
    if itemType ~= nil and craftType ~= nil then return {}, { status = "failed", error = "制作物上下文冲突，请重新选择" } end
    if craftType ~= nil then return { craftType }, { status = "ready", source = "已选制作物", itemType = nil, craftType = craftType } end
    if itemType == nil then return {}, { status = "empty", source = "未选择制作物", itemType = nil } end
    local craft = CraftApi or rawget(_G, "X2Craft")
    local ok, first, errorText, second, third, fourth = Call("X2Craft:GetCraftTypeByItemType", craft, "GetCraftTypeByItemType", itemType)
    if ok ~= true then return {}, { status = "failed", source = "X2Craft:GetCraftTypeByItemType", itemType = itemType, error = Text(errorText, "制作配方查询失败") } end
    local types, seen = {}, {}
    for _, value in ipairs({ first, second, third, fourth }) do CraftCollectTypeIds(value, types, seen, 0) end
    if #types == 0 then return {}, { status = "empty", source = "X2Craft:GetCraftTypeByItemType", itemType = itemType, error = "当前物品没有返回可用制作配方" } end
    return types, { status = "ready", source = "X2Craft:GetCraftTypeByItemType", itemType = itemType, craftTypes = Copy(types) }
end

local function CraftRead(feature)
    local rows, recipes = {}, {}
    local function RefreshSectionText(section)
        if type(section) ~= "table" or type(section.items) ~= "table" or #section.items == 0 or section.status ~= "ready" then return false end
        local parts = {}
        for index, item in ipairs(section.items) do parts[index] = CraftItemText(item) end
        local label = section.kind == "product" and "产物：" or "材料："
        if section.truncated then
            local suffix = "已截断，原始记录 " .. tostring(section.sourceCount or #section.items) .. " 条"
            local prefixLimit = math.max(32, CRAFT_TEXT_LIMIT - #suffix - #label - 6)
            section.text = (label .. table.concat(parts, "；")):sub(1, prefixLimit) .. "… " .. suffix
            section.textTruncated = true
        else
            section.text, section.textTruncated = CraftText(label .. table.concat(parts, "；"), nil)
        end
        return true
    end
    local selectedRecipe = SelectedCraftRecipe(feature)
    if selectedRecipe ~= nil and tonumber(selectedRecipe.craftId) ~= nil then
        feature.State.craftType = math.floor(tonumber(selectedRecipe.craftId))
        feature.State.itemType = nil
    end
    local craftTypes, resolution = CraftResolveTypes(feature)
    if #craftTypes == 0 then
        rows[#rows + 1] = { key = "craft:resolution", name = "制作上下文", text = resolution.status == "empty" and "请从上方制作物列表选择需要规划的配方" or Text(resolution.error, "制作上下文不可用"), statusText = CraftStatusText(resolution.status), tone = resolution.status == "failed" and "warn" or "default", source = resolution.source, failed = resolution.status == "failed", empty = resolution.status == "empty" }
        feature.CraftProjection = { context = resolution, recipes = {}, source = resolution.source, status = resolution.status, error = resolution.error }
        return rows, resolution.status == "empty" and "empty" or "unavailable", resolution.error
    end
    rows[#rows + 1] = { key = "craft:resolution", name = "当前制作物", text = selectedRecipe ~= nil and ((CRAFT_ZONE_ZH[tonumber(selectedRecipe.originZoneId)] or "已核地区") .. " · " .. CraftFamilyLabel(selectedRecipe)) or "已读取当前制作上下文", statusText = "已匹配", tone = "default", source = resolution.source, itemType = resolution.itemType, craftTypes = Copy(craftTypes) }
    local anyReadable, anyReady, errors = false, false, {}
    local held, bagDiagnostics = CraftHeldCounts()
    local doodadId = feature.State.doodadId == nil and 0 or CraftInteger(feature.State.doodadId, true)
    if doodadId == nil then doodadId = 0 end
    local craftApi = CraftApi or rawget(_G, "X2Craft")
    for _, craftType in ipairs(craftTypes) do
        local okBase, base, baseError = Call("X2Craft:GetCraftBaseInfo", craftApi, "GetCraftBaseInfo", craftType)
        local okProduct, product, productError = Call("X2Craft:GetCraftProductInfo", craftApi, "GetCraftProductInfo", craftType)
        local okMaterial, material, materialError = Call("X2Craft:GetCraftMaterialInfo", craftApi, "GetCraftMaterialInfo", craftType, doodadId)
        local recipe = { craftType = craftType, base = CraftBaseSection(okBase, base, baseError, craftType), product = CraftSection("product", okProduct, product, productError, craftType, doodadId), materials = CraftSection("materials", okMaterial, material, materialError, craftType, doodadId) }
        if selectedRecipe ~= nil and tonumber(selectedRecipe.craftId) == tonumber(craftType) then
            if (recipe.product.failed or recipe.product.opaque or #(recipe.product.items or {}) == 0) and tonumber(selectedRecipe.productItemId) ~= nil then
                recipe.product = { kind="product", source="TradeStaticV2", craftType=craftType, doodadId=doodadId, failed=false, empty=false, opaque=false, truncated=false, sourceCount=1, status="ready", items={{ itemType=tonumber(selectedRecipe.productItemId), count=1, name=CraftItemName(selectedRecipe.productItemId,nil), status="ready", source="TradeStaticV2" }}, text="产物：" .. CraftItemName(selectedRecipe.productItemId,nil) .. " × 1", staticFallback=true }
            end
            if recipe.materials.failed or recipe.materials.opaque or #(recipe.materials.items or {}) == 0 then
                local staticItems = CraftStaticItems(selectedRecipe)
                if #staticItems > 0 then
                    local parts={}; for _, item in ipairs(staticItems) do parts[#parts+1]=CraftItemText(item) end
                    recipe.materials = { kind="materials", source="TradeStaticV2", craftType=craftType, doodadId=doodadId, failed=false, empty=false, opaque=false, truncated=false, sourceCount=#staticItems, status="ready", items=staticItems, text="材料：" .. table.concat(parts,"；"), staticFallback=true }
                end
            end
        end
        recipe.product.incomplete = CraftEnrichItems(recipe.product.items, held, bagDiagnostics)
        recipe.materials.incomplete = CraftEnrichItems(recipe.materials.items, held, bagDiagnostics)
        RefreshSectionText(recipe.product)
        RefreshSectionText(recipe.materials)
        recipes[#recipes + 1] = recipe
        for _, section in ipairs({ recipe.base, recipe.product, recipe.materials }) do
            if section.failed then errors[#errors + 1] = section.kind .. "(" .. tostring(craftType) .. "): " .. tostring(section.error) else anyReadable = true end
            if section.status == "ready" then anyReady = true end
        end
        rows[#rows + 1] = { key = "craft:" .. tostring(craftType) .. ":base", name = "制作基础", text = recipe.base.text, statusText = CraftStatusText(recipe.base.status), tone = recipe.base.failed and "warn" or "default", source = recipe.base.source, fields = Copy(recipe.base.fields), failed = recipe.base.failed, empty = recipe.base.empty, opaque = recipe.base.opaque }
        rows[#rows + 1] = { key = "craft:" .. tostring(craftType) .. ":product", name = "制作产物", text = recipe.product.text, statusText = recipe.product.incomplete and "部分可用" or CraftStatusText(recipe.product.status), tone = recipe.product.failed and "warn" or "default", source = recipe.product.source, items = Copy(recipe.product.items), sourceCount = recipe.product.sourceCount, truncated = recipe.product.truncated, failed = recipe.product.failed, empty = recipe.product.empty, opaque = recipe.product.opaque, cost = recipe.product.items }
        rows[#rows + 1] = { key = "craft:" .. tostring(craftType) .. ":materials", name = "所需材料", text = recipe.materials.text, statusText = recipe.materials.incomplete and "部分可用" or CraftStatusText(recipe.materials.status), tone = recipe.materials.failed and "warn" or "default", source = recipe.materials.source, items = Copy(recipe.materials.items), sourceCount = recipe.materials.sourceCount, truncated = recipe.materials.truncated, failed = recipe.materials.failed, empty = recipe.materials.empty, opaque = recipe.materials.opaque, cost = recipe.materials.items }
    end
    local graphRoots = {}
    for _, recipe in ipairs(recipes) do
        for _, product in ipairs(recipe.product.items or {}) do
            if product.itemType ~= nil and product.count ~= nil then graphRoots[#graphRoots + 1] = { itemType = product.itemType, quantity = product.count } end
        end
    end
    local graph = S.BuildCraftRecipeGraph(recipes, graphRoots)
    local gd = graph.diagnostics
    rows[#rows + 1] = { key = "craft:graph", name = "成本图", text = "已知记录内展开 " .. tostring(gd.nodes) .. " 节点 / " .. tostring(gd.edges) .. " 边；未解析 " .. tostring(gd.unresolved) .. "，循环 " .. tostring(gd.cycles) .. "，歧义 " .. tostring(gd.ambiguous) .. (gd.truncated and "；已截断" or "；不代表完整目录"), statusText = CraftStatusText(gd.status), tone = gd.status == "ready" and "default" or "warn", source = "bounded_known_x2craft_records", graph = graph }
    local status = anyReady and "ready" or anyReadable and "empty" or "unavailable"
    local errorText = #errors > 0 and table.concat(errors, "; ") or nil
    feature.CraftProjection = { context = resolution, doodadId = doodadId, recipes = recipes, graph = graph, held = held, bag = bagDiagnostics, source = "X2Craft", status = status, error = errorText }
    return rows, status, errorText
end

local function CraftProjection(feature)
    local seen, pending, priced, quotedCost = {}, 0, 0, 0
    local craft = type(feature.CraftProjection) == "table" and feature.CraftProjection or nil
    for _, recipe in ipairs(craft and type(craft.recipes) == "table" and craft.recipes or {}) do
        local materials = type(recipe.materials) == "table" and recipe.materials.items or nil
        for _, item in ipairs(type(materials) == "table" and materials or {}) do
            local itemType = CraftInteger(item.itemType, false)
            local itemGrade = CraftInteger(item.itemGrade, false)
            local key = itemType and (tostring(itemType) .. ":" .. tostring(itemGrade or 0)) or nil
            if item.costStatus == "explicit_quote_required" and key ~= nil and seen[key] ~= true then
                seen[key], pending = true, pending + 1
            end
            if item.lineCost ~= nil then priced, quotedCost = priced + 1, quotedCost + math.max(0, tonumber(item.lineCost) or 0) end
        end
    end
    return {
        craft = Copy(feature.CraftProjection or { context = { status = "idle" }, recipes = {} }),
        recipeOptions = Copy(CraftRecipeOptions()),
        selectedRecipeKey = feature.State.selectedRecipeKey,
        pendingQuoteCount = pending, pricedMaterialCount = priced, quotedMaterialCostCopper = math.floor(quotedCost + 0.5),
    }
end
local function CraftPersist(feature, reason, mutator)
    if type(P.MutateStore) ~= "function" then return false, "制作上下文持久化事务不可用" end
    local marked, markErr = P:MutateStore(feature.storeId, function()
        mutator()
        return true
    end, { delayMs = 300, reason = tostring(reason or "craft_changed") })
    if marked ~= true then return false, "制作上下文未保存，已回滚：" .. tostring(markErr or "store write rejected") end
    return feature:Refresh(reason)
end

local function CraftCommands()
    return {
        SelectRecipe = function(feature, value)
            local key = tostring(value or "")
            local record = S.StaticDataV2 ~= nil and type(S.StaticDataV2.Get)=="function" and S.StaticDataV2:Get("trade_recipe", key) or nil
            local craftId = tonumber(record and record.craftId)
            if type(record)~="table" or craftId==nil then return false, "所选制作物没有已核配方" end
            return CraftPersist(feature, "craft_recipe_select", function()
                feature.State.selectedRecipeKey = record.key
                feature.State.craftType = math.floor(craftId)
                feature.State.itemType = nil
                feature.State.doodadId = 0
            end)
        end,
        SetCraftType = function(feature, value)
            local craftType = CraftInteger(value, false); if craftType == nil then return false, "制作配方编号必须是正整数" end
            return CraftPersist(feature, "craft_type", function() feature.State.craftType = craftType; feature.State.itemType = nil; feature.State.selectedRecipeKey = nil end)
        end,
        SetItemType = function(feature, value)
            local itemType = CraftInteger(value, false); if itemType == nil then return false, "物品编号必须是正整数" end
            return CraftPersist(feature, "craft_item_type", function() feature.State.itemType = itemType; feature.State.craftType = nil; feature.State.selectedRecipeKey = nil end)
        end,
        SetDoodadId = function(feature, value)
            local doodadId = CraftInteger(value, true); if doodadId == nil then return false, "制作台对象编号必须是非负整数" end
            return CraftPersist(feature, "craft_doodad", function() feature.State.doodadId = doodadId end)
        end,
        -- Explicit single-material lowest-price quote. Ordinary Refresh never
        -- fans out GetLowestPrice; the user triggers a quote here and the shared
        -- queue owns pacing. Completion rebuilds this Feature once so the visible
        -- material unit/subtotal values update without another user refresh.
        QuoteMaterial = function(feature, itemType, itemGrade)
            local queue = S.Services ~= nil and S.Services.PriceQuoteQueueV3 or nil
            if type(queue) ~= "table" or type(queue.RequestQuote) ~= "function" then return false, "报价服务不可用" end
            local ok, status = queue:RequestQuote(feature.Id .. ":craft", itemType, itemGrade, function()
                if feature.enabled == true and (tonumber(feature.consumerCount) or 0) > 0 then feature:Refresh("craft_quote_completed") end
            end)
            if ok ~= true then return false, status or "报价请求失败" end
            return true, status or "queued"
        end,
        -- Explicit batch quote for the currently projected recipe only. Targets
        -- are deduplicated and bounded by the shared queue capacity. To avoid a
        -- full Bag/Craft rescan every 560ms, callbacks coalesce to ONE refresh
        -- after the last successfully queued quote completes.
        QuotePendingMaterials = function(feature)
            local queue = S.Services ~= nil and S.Services.PriceQuoteQueueV3 or nil
            if type(queue) ~= "table" or type(queue.RequestQuote) ~= "function" then return false, "报价服务不可用" end
            local targets, seen = {}, {}
            local craft = type(feature.CraftProjection) == "table" and feature.CraftProjection or nil
            for _, recipe in ipairs(craft and type(craft.recipes) == "table" and craft.recipes or {}) do
                local materials = type(recipe.materials) == "table" and recipe.materials.items or nil
                for _, item in ipairs(type(materials) == "table" and materials or {}) do
                    local itemType = CraftInteger(item.itemType, false)
                    local itemGrade = CraftInteger(item.itemGrade, false)
                    local key = itemType and (tostring(itemType) .. ":" .. tostring(itemGrade or 0)) or nil
                    if item.costStatus == "explicit_quote_required" and key ~= nil and seen[key] ~= true then
                        seen[key] = true
                        targets[#targets + 1] = { itemType = itemType, itemGrade = itemGrade }
                    end
                end
            end
            if #targets == 0 then return false, "当前制作物没有待询价材料" end
            local limit = math.max(1, tonumber(queue.maxQueue) or 64)
            local requested, skipped, completed = 0, 0, 0
            local function OnComplete()
                completed = completed + 1
                if completed >= requested and requested > 0 and feature.enabled == true and (tonumber(feature.consumerCount) or 0) > 0 then
                    feature:Refresh("craft_quote_batch_completed")
                end
            end
            for index, target in ipairs(targets) do
                if index > limit then
                    skipped = skipped + 1
                else
                    local ok = queue:RequestQuote(feature.Id .. ":craft", target.itemType, target.itemGrade, OnComplete)
                    if ok == true then requested = requested + 1 else skipped = skipped + 1 end
                end
            end
            if requested == 0 then return false, "待询价材料未能进入报价队列", 0, skipped end
            return true, "已提交 " .. tostring(requested) .. " 项材料询价" .. (skipped > 0 and ("，" .. tostring(skipped) .. " 项暂未提交") or ""), requested, skipped
        end,
    }
end

local CRAFT_API_DEPENDENCIES = { "X2Craft:GetCraftBaseInfo", "X2Craft:GetCraftMaterialInfo", "X2Craft:GetCraftProductInfo", "X2Craft:GetCraftTypeByItemType", "X2Bag:Capacity", "X2Bag:GetBagItemInfo" }
-- 中文维护注释（2026-09-15，移除 life_craft_planner）：共享 CraftRead/CraftProjection 仍由制作台助手使用，
-- 但不再实例化 life_craft_planner，因此不会注册 v3.business.life_craft_planner Store、Demand 或 Runtime Implementation。
-- 旧磁盘键保持原样不主动清除，避免“删除功能”变成不可逆用户数据写操作；toc 同时停止加载 Planner extension。
local CraftAssistant = NewFeature("tools_craft", { apiDependencies = CRAFT_API_DEPENDENCIES, state = { selectedRecipeKey = nil, craftType = nil, itemType = nil, doodadId = 0, autoSidecar = true }, default = { selectedRecipeKey = nil, craftType = nil, itemType = nil, doodadId = 0, autoSidecar = true }, persistentKeys = { "selectedRecipeKey", "craftType", "itemType" }, read = CraftRead, projection = CraftProjection, commands = CraftCommands() })
CraftAssistant.CraftUserSelectionContractVersion = 1
