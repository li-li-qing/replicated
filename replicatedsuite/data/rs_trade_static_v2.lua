------------------------------------------------------------------------
-- Replicated Suite - Trade Static Data V2
--
-- Canonical trade-material identity lives here, not inside TradeService.
-- compactId is legacy recipe compatibility only; itemId is the real server
-- item identity used by Auction/Inventory/V3. Runtime prices never live here.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
S.Data = S.Data or {}
local SharedItemIds=(S.GameIds and S.GameIds.Item) or {}
local SharedBondMaterials=SharedItemIds.BOND_MATERIAL or {}

local RESOURCE_AUCTION_META = {
    ["Chopped Produce"]={itemType=30898,itemGrade=1,gradeOffset=0},
    ["Ground Grain"]={itemType=30902,itemGrade=1,gradeOffset=0},
    ["Trimmed Meat"]={itemType=30905,itemGrade=1,gradeOffset=0},
    ["Dried Flowers"]={itemType=30900,itemGrade=1,gradeOffset=0},
    ["Orchard Puree"]={itemType=30899,itemGrade=1,gradeOffset=0},
    ["Ground Spices"]={itemType=30901,itemGrade=1,gradeOffset=0},
    ["Egg"]={itemType=3603,gradeOffset=0},
    ["Grape"]={itemType=8065,gradeOffset=0},
    ["Goose Down"]={itemType=19947,gradeOffset=0},
    ["Apple"]={itemType=773,gradeOffset=0},
    ["Milk"]={itemType=8055,gradeOffset=1},
    ["Olive"]={itemType=8054,gradeOffset=0},
    ["Wool"]={itemType=8053,gradeOffset=0},
    ["Narcissus"]={itemType=3667,gradeOffset=0},
    ["Medicinal Powder"]={itemType=30903,itemGrade=1,gradeOffset=0},
    ["Duck Down"]={itemType=19946,gradeOffset=0},
    ["Cherry"]={itemType=14627,gradeOffset=0},
    ["Pomegranate"]={itemType=3588,gradeOffset=0},
    ["Bay Leaf"]={itemType=3675,gradeOffset=0},
    ["Yam"]={itemType=7994,gradeOffset=0},
    ["Banana"]={itemType=14620,gradeOffset=0},
    ["Mushroom"]={itemType=14630,gradeOffset=0},
    ["Avocado"]={itemType=3592,gradeOffset=0},
    ["Rosemary"]={itemType=3628,gradeOffset=1},
    ["Barley"]={itemType=8005,gradeOffset=0},
    ["Rice"]={itemType=784,gradeOffset=0},
    ["Corn"]={itemType=8013,gradeOffset=0},
    ["Cornflower"]={itemType=2178,gradeOffset=0},
    ["Rye"]={itemType=14971,gradeOffset=1},
    ["Sunflower"]={itemType=3622,gradeOffset=0},
    ["Turmeric"]={itemType=16268,gradeOffset=0},
    ["Carrot"]={itemType=7998,gradeOffset=0},
    ["Azalea"]={itemType=3684,gradeOffset=0},
    ["Lily"]={itemType=3564,gradeOffset=0},
    ["Ginkgo Leaf"]={itemType=15767,gradeOffset=0},
    ["Cucumber"]={itemType=8012,gradeOffset=0},
    ["Fig"]={itemType=8038,gradeOffset=0},
    ["Peanut"]={itemType=8000,gradeOffset=1},
    ["Onion"]={itemType=8010,gradeOffset=0},
    ["Potato"]={itemType=7992,gradeOffset=0},
    ["Oats"]={itemType=3545,gradeOffset=1},
    ["Millet"]={itemType=3546,gradeOffset=0},
    ["Garlic"]={itemType=8001,gradeOffset=0},
    ["Yata Fur"]={itemType=26674,gradeOffset=2},
    ["Saffron"]={itemType=16273,gradeOffset=0},
    ["Jujube"]={itemType=8034,gradeOffset=2},
    ["Lemon"]={itemType=8036,gradeOffset=0},
    ["Mint"]={itemType=14629,gradeOffset=0},
    ["Lavender"]={itemType=3627,gradeOffset=0},
    ["Tomato"]={itemType=8016,gradeOffset=0},
    ["Moringa Fruit"]={itemType=15770,gradeOffset=0},
    ["Iris"]={itemType=3713,gradeOffset=0},
    ["Aloe"]={itemType=16290,gradeOffset=1},
    ["Orange"]={itemType=14621,gradeOffset=1},
    ["Rose"]={itemType=3711,gradeOffset=0},
    ["Strawberry"]={itemType=8006,gradeOffset=0},
    ["Flaming Log"]={itemType=18749,gradeOffset=0},
    ["Archeum Log"]={itemType=18442,gradeOffset=0},
    ["Silver Lily"]={itemType=49243,gradeOffset=4},
    ["Crimson Petunia"]={itemType=49244,gradeOffset=4},
    ["Lumber"]={itemType=SharedBondMaterials.lumber,gradeOffset=0},
    ["Honey"]={itemType=28481,gradeOffset=0},
    ["Hay Bale"]={itemType=3712,gradeOffset=0},
    ["Royal Seed"]={itemType=42343,gradeOffset=3},
    ["Cultivated Ginseng"]={itemType=3680,gradeOffset=0},
    ["Quality Certificate"]={itemType=4747,gradeOffset=0},
    ["Cedar Hardwood"]={itemType=3426,gradeOffset=0},
    -- itemType values verified against the official ArcheRage wiki item DB.
    ["Time-Space Rift Shard"]={itemType=45045,gradeOffset=0},
    ["Iron Ingot"]={itemType=SharedBondMaterials.iron,gradeOffset=0},
    ["Blue Salt Bond"]={itemType=SharedItemIds.BLUE_SALT_BOND,gradeOffset=0},
    ["Small Root Pigment"]={itemType=19448,gradeOffset=0},
    ["Small Seed Oil"]={itemType=19449,gradeOffset=0},
    ["Opaque Polish"]={itemType=19450,gradeOffset=0},
}


S.Data.TradeMaterialAuctionMeta = RESOURCE_AUCTION_META

local Static = S.StaticDataV2
if type(Static) ~= "table" then return end
if Static:GetCatalog("trade_material") == nil then Static:DefineCatalog("trade_material", { idField = "itemId", requireId = true }) end
if Static:GetCatalog("trade_recipe") == nil then Static:DefineCatalog("trade_recipe", { idField = "craftId", requireId = true }) end
if Static:GetCatalog("trade_good") == nil then Static:DefineCatalog("trade_good", { idField = "itemId" }) end
if Static:GetCatalog("trade_recipe_template") == nil then Static:DefineCatalog("trade_recipe_template") end

local function Key(value)
    return tostring(value or ""):lower():gsub("[^%w_%.%-]", "_"):gsub("_+", "_"):gsub("^_+", ""):gsub("_+$", "")
end

local compactByName = {}
for name, row in pairs(S.Data.TradeMaterialResources or {}) do
    if type(row) == "table" and tonumber(row[1]) ~= nil then compactByName[name] = math.floor(tonumber(row[1])) end
end

local COST_POLICY = {
    ["Gilda Star"] = { includeInCost=false, auctionable=false, note="特殊货币，不计成本", itemType=23633, gradeOffset=0 },
    ["Quality Certificate"] = { includeInCost=false, auctionable=false, note="当前不可购买，不计拍卖成本" },
}

local materialKeyByLegacyName, materialKeyByCompactId = {}, {}
S.GameIds = S.GameIds or {}
S.GameIds.TradeMaterial = S.GameIds.TradeMaterial or { ByLegacyName = {}, ByCompactId = {} }
local TradeMaterialIds = S.GameIds.TradeMaterial
local allNames = {}
for name in pairs(compactByName) do allNames[name] = true end
for name in pairs(RESOURCE_AUCTION_META) do allNames[name] = true end
for name in pairs(COST_POLICY) do allNames[name] = true end
for name in pairs(allNames) do
    local meta = RESOURCE_AUCTION_META[name] or {}
    local policy = COST_POLICY[name] or {}
    local itemId = tonumber(meta.itemType or policy.itemType)
    local compactId = compactByName[name]
    local key = "material." .. Key(name)
    local record, err = Static:Register("trade_material", key, {
        itemId = itemId,
        compactId = compactId,
        nameEn = name,
        itemGrade = tonumber(meta.itemGrade),
        gradeOffset = tonumber(meta.gradeOffset or policy.gradeOffset) or 0,
        includeInCost = policy.includeInCost ~= false,
        auctionable = policy.auctionable ~= false and itemId ~= nil,
        note = policy.note,
        source = "ArcheRage RU curated trade material data",
        confidence = "curated",
        identityStatus = itemId ~= nil and "known_item_id" or "missing_item_id",
        verified = false,
    })
    if record ~= nil then
        materialKeyByLegacyName[name] = record.key
        if compactId ~= nil then materialKeyByCompactId[compactId] = record.key end

        -- Shared item identity follows the same Registry path as Skills/Buffs.
        -- Compact trade IDs are compatibility-only and never become server IDs.
        local registry = S.GameDataRegistry
        if registry ~= nil and itemId ~= nil then
            local itemKey = "TRADE_MATERIAL_" .. Key(name):upper():gsub("[%.-]", "_")
            local identity = registry:FindById("item", itemId)
            if identity ~= nil and type(registry.RegisterAlias) == "function" then
                identity = registry:RegisterAlias("item", itemKey, itemId) or identity
            elseif identity == nil then
                identity = registry:Register("item", itemKey, itemId, {
                    name = name,
                    tags = { "TRADE_MATERIAL" },
                    source = "ArcheRage RU curated trade material data",
                    confidence = "curated",
                    verified = false,
                    notes = "Static identity migrated from TradeMaterialService; verify metadata independently from runtime price state",
                })
            end
            TradeMaterialIds.ByLegacyName[name] = identity or { id=itemId, key=itemKey }
            if compactId ~= nil then TradeMaterialIds.ByCompactId[compactId] = TradeMaterialIds.ByLegacyName[name] end
        end
    elseif S.DiagnosticsManager ~= nil and type(S.DiagnosticsManager.Warn) == "function" then
        S.DiagnosticsManager:Warn("static_data_v2", "TRADE_MATERIAL_REGISTER_FAILED", tostring(err), { material = name })
    end
end

local recipeKeyByLegacyName, recipeKeyByCraftId = {}, {}
local TradeCraftIds = (S.GameIds and S.GameIds.TradeCraft) or {}
local TradeProductIds = (S.GameIds and S.GameIds.TradeProduct) or {}
local tradeCraftStats = {
    primaryCraftIds = 0,
    missingCraftIds = 0,
    totalRecipeCraftIds = 0,
    alternateRecipeCraftIds = 0,
    verifiedIngredientSignatures = 0,
    ingredientSignatureFailures = 0,
}

-- Deterministic audit signature over legacy compact material IDs. This runs only
-- during StaticDataV2 construction; runtime trade refresh paths use O(1) indexes.
local function BuildIngredientSignature(ingredients)
    local parts = {}
    for _, ingredient in ipairs(type(ingredients) == "table" and ingredients or {}) do
        local compactId = tonumber(ingredient.compactId)
        local count = tonumber(ingredient.count)
        if compactId ~= nil and count ~= nil then
            parts[#parts + 1] = { compactId=math.floor(compactId), count=count }
        end
    end
    table.sort(parts, function(a, b) return a.compactId < b.compactId end)
    local out = {}
    for _, row in ipairs(parts) do
        out[#out + 1] = tostring(row.compactId) .. ":" .. tostring(row.count)
    end
    return table.concat(out, "|")
end

local ZoneIds = (S.GameIds and S.GameIds.Zone) or {}
local ZoneById = ZoneIds.ById or {}

local function ResolveOriginZone(legacyName)
    local raw = tostring(legacyName or "")
    local best, bestLength = nil, 0
    for _, zone in pairs(ZoneById) do
        local nameEn = type(zone) == "table" and tostring(zone.nameEn or "") or ""
        local prefix = nameEn .. " "
        if nameEn ~= "" and string.find(raw, prefix, 1, true) == 1 and #nameEn > bestLength then
            best, bestLength = zone, #nameEn
        end
    end
    return best
end

local function RegisterRecipeTable(tbl, family)
    for legacyName, raw in pairs(type(tbl) == "table" and tbl or {}) do
        local counts = type(raw) == "table" and raw[1] or nil
        local compactIds = type(raw) == "table" and raw[2] or nil
        if type(counts) == "table" and type(compactIds) == "table" then
            local ingredients = {}
            local recipeKey = "trade." .. Key(legacyName)
            for i = 1, math.min(#counts, #compactIds) do
                local compactId = tonumber(compactIds[i]) and math.floor(tonumber(compactIds[i])) or nil
                local materialKey = compactId and materialKeyByCompactId[compactId] or nil
                ingredients[#ingredients + 1] = {
                    materialKey = materialKey,
                    compactId = compactId,
                    count = tonumber(counts[i]) or 0,
                }
            end
            local originZone = ResolveOriginZone(legacyName)
            local originZoneId = type(originZone) == "table" and tonumber(originZone.zoneId) or nil
            local originZoneKey = type(originZone) == "table" and originZone.key or nil

            -- Craft IDs and product item IDs are deliberately different namespaces.
            -- A Local Specialty may have both Plaza and Community Center craft IDs.
            local craftRows = type(TradeCraftIds.GetByLegacyName) == "function" and TradeCraftIds:GetByLegacyName(legacyName) or {}
            local primaryCraft = type(TradeCraftIds.GetPrimaryByLegacyName) == "function" and TradeCraftIds:GetPrimaryByLegacyName(legacyName) or nil
            local craftId = type(primaryCraft) == "table" and tonumber(primaryCraft.craftId) or nil
            local craftIds = {}
            for _, craftRow in ipairs(type(craftRows) == "table" and craftRows or {}) do
                if type(craftRow) == "table" and craftRow.kind ~= "FERTILIZER" and tonumber(craftRow.craftId) ~= nil then
                    craftIds[#craftIds + 1] = math.floor(tonumber(craftRow.craftId))
                end
            end
            table.sort(craftIds)
            if craftId ~= nil then
                tradeCraftStats.primaryCraftIds = tradeCraftStats.primaryCraftIds + 1
            else
                tradeCraftStats.missingCraftIds = tradeCraftStats.missingCraftIds + 1
            end
            tradeCraftStats.totalRecipeCraftIds = tradeCraftStats.totalRecipeCraftIds + #craftIds
            if #craftIds > 1 then tradeCraftStats.alternateRecipeCraftIds = tradeCraftStats.alternateRecipeCraftIds + (#craftIds - 1) end

            local ingredientSignature = BuildIngredientSignature(ingredients)
            local verifiedSignature = craftId ~= nil and type(TradeCraftIds.GetVerifiedIngredientSignature) == "function" and TradeCraftIds:GetVerifiedIngredientSignature(craftId) or nil
            local ingredientVerified = verifiedSignature ~= nil and ingredientSignature == verifiedSignature
            local ingredientStatus = "curated_pending"
            if verifiedSignature ~= nil then
                tradeCraftStats.verifiedIngredientSignatures = tradeCraftStats.verifiedIngredientSignatures + 1
                if ingredientVerified then
                    ingredientStatus = "database_verified"
                else
                    ingredientStatus = "database_mismatch"
                    tradeCraftStats.ingredientSignatureFailures = tradeCraftStats.ingredientSignatureFailures + 1
                    if S.DiagnosticsManager ~= nil and type(S.DiagnosticsManager.Error) == "function" then
                        S.DiagnosticsManager:Error("static_data_v2", "TRADE_RECIPE_SIGNATURE_MISMATCH", "RU 数据库已验证配方与本地材料签名不一致", {
                            legacyName=legacyName, craftId=craftId, expected=verifiedSignature, actual=ingredientSignature,
                        })
                    end
                end
            end

            local productRow = type(TradeProductIds.GetByLegacyName) == "function" and TradeProductIds:GetByLegacyName(legacyName) or nil
            local productItemId = type(productRow) == "table" and tonumber(productRow.itemId) or nil
            local productSource = type(productRow) == "table" and tostring(productRow.source or "") or ""

            local record = Static:Register("trade_recipe", recipeKey, {
                craftId = craftId,
                craftIds = craftIds,
                productItemId = productItemId,
                productIdentityStatus = productItemId ~= nil and "database_verified" or "product_item_id_pending",
                productIdentitySource = productSource ~= "" and productSource or nil,
                legacyName = legacyName,
                family = family,
                originZoneId = originZoneId,
                originZoneKey = originZoneKey,
                ingredients = ingredients,
                ingredientSignature = ingredientSignature,
                ingredientStatus = ingredientStatus,
                ingredientVerified = ingredientVerified,
                craftIdStatus = craftId ~= nil and "database_verified" or "missing_craft_id",
                source = "ArcheRage RU Commerce craft IDs + legacy ingredient table",
            })
            if record ~= nil then
                recipeKeyByLegacyName[legacyName] = record.key
                for _, indexedCraftId in ipairs(craftIds) do recipeKeyByCraftId[indexedCraftId] = record.key end
                local goodKey = "good." .. Key(legacyName)
                local good = Static:Register("trade_good", goodKey, {
                    serverName = legacyName,
                    family = family,
                    recipeKey = record.key,
                    originZoneId = originZoneId,
                    originZoneKey = originZoneKey,
                    itemId = productItemId,
                    identityStatus = productItemId ~= nil and "database_verified" or "product_item_id_pending",
                    source = productItemId ~= nil and (productSource ~= "" and productSource or "ArcheRage item database") or "legacy trade recipe table normalized for V3",
                })
                if good ~= nil then
                    Static:AddReference("trade_good", good.key, "recipeKey", "trade_recipe", record.key, true)
                    if originZoneKey ~= nil then Static:AddReference("trade_good", good.key, "originZoneKey", "zone", originZoneKey, true) end
                end
                if originZoneKey ~= nil then Static:AddReference("trade_recipe", record.key, "originZoneKey", "zone", originZoneKey, true) end
                for index, ingredient in ipairs(ingredients) do
                    if ingredient.materialKey ~= nil then
                        Static:AddReference("trade_recipe", record.key, "ingredients[" .. tostring(index) .. "]", "trade_material", ingredient.materialKey, true)
                    end
                end
            end
        end
    end
end

RegisterRecipeTable(S.Data.TradeMaterialNuia, "nuia")
RegisterRecipeTable(S.Data.TradeMaterialHaranya, "haranya")
RegisterRecipeTable(S.Data.TradeMaterialAuroria, "auroria")
RegisterRecipeTable(S.Data.TradeMaterialCustom, "custom")

local function RegisterTemplate(key, raw, family)
    local counts = type(raw) == "table" and raw[1] or nil
    local compactIds = type(raw) == "table" and raw[2] or nil
    if type(counts) ~= "table" or type(compactIds) ~= "table" then return end
    local ingredients = {}
    for i = 1, math.min(#counts, #compactIds) do
        local compactId = tonumber(compactIds[i]) and math.floor(tonumber(compactIds[i])) or nil
        local materialKey = compactId and materialKeyByCompactId[compactId] or nil
        ingredients[#ingredients + 1] = { materialKey=materialKey, compactId=compactId, count=tonumber(counts[i]) or 0 }
    end
    local record = Static:Register("trade_recipe_template", key, { family=family, ingredients=ingredients, source="legacy trade recipe template normalized for V3" })
    if record ~= nil then
        for index, ingredient in ipairs(ingredients) do
            if ingredient.materialKey ~= nil then Static:AddReference("trade_recipe_template", record.key, "ingredients[" .. tostring(index) .. "]", "trade_material", ingredient.materialKey, true) end
        end
    end
end
RegisterTemplate("template.fertilizer", S.Data.TradeMaterialFertilizer, "fertilizer")
RegisterTemplate("template.fragment", S.Data.TradeMaterialFragment, "fragment")
RegisterTemplate("template.transport", S.Data.TradeMaterialTransport, "transport")

S.Data.TradeStaticV2 = {
    materialKeyByLegacyName = materialKeyByLegacyName,
    materialKeyByCompactId = materialKeyByCompactId,
    recipeKeyByLegacyName = recipeKeyByLegacyName,
    recipeKeyByCraftId = recipeKeyByCraftId,
    tradeCraftStats = tradeCraftStats,
}

function S.Data.TradeStaticV2:GetMaterialByLegacyName(name)
    local key = self.materialKeyByLegacyName[tostring(name or "")]
    return key and Static:Get("trade_material", key) or nil
end
function S.Data.TradeStaticV2:GetMaterialByCompactId(id)
    local key = self.materialKeyByCompactId[tonumber(id)]
    return key and Static:Get("trade_material", key) or nil
end
function S.Data.TradeStaticV2:GetRecipeByLegacyName(name)
    local key = self.recipeKeyByLegacyName[tostring(name or "")]
    return key and Static:Get("trade_recipe", key) or nil
end
function S.Data.TradeStaticV2:GetRecipeByCraftId(craftId)
    local key = self.recipeKeyByCraftId[tonumber(craftId)]
    return key and Static:Get("trade_recipe", key) or nil
end

function S.Data.TradeStaticV2:Describe()
    local materials = Static:GetCatalog("trade_material")
    local goods = Static:GetCatalog("trade_good")
    local recipes = Static:GetCatalog("trade_recipe")
    local pendingProductIds, pendingOriginZones = 0, 0
    if goods ~= nil then
        for _, key in ipairs(goods.order or {}) do
            local row = goods.records[key]
            if row ~= nil and tonumber(row.itemId) == nil then pendingProductIds = pendingProductIds + 1 end
            if row ~= nil and tonumber(row.originZoneId) == nil then pendingOriginZones = pendingOriginZones + 1 end
        end
    end
    local productStats = type(TradeProductIds.Describe) == "function" and TradeProductIds:Describe(goods and #goods.order or 98) or {}
    return {
        materials = materials and #materials.order or 0,
        goods = goods and #goods.order or 0,
        recipes = recipes and #recipes.order or 0,
        primaryCraftIds = tonumber(self.tradeCraftStats.primaryCraftIds) or 0,
        missingCraftIds = tonumber(self.tradeCraftStats.missingCraftIds) or 0,
        totalRecipeCraftIds = tonumber(self.tradeCraftStats.totalRecipeCraftIds) or 0,
        alternateRecipeCraftIds = tonumber(self.tradeCraftStats.alternateRecipeCraftIds) or 0,
        verifiedIngredientSignatures = tonumber(self.tradeCraftStats.verifiedIngredientSignatures) or 0,
        ingredientSignatureFailures = tonumber(self.tradeCraftStats.ingredientSignatureFailures) or 0,
        verifiedProductIds = math.max(0, (goods and #goods.order or 0) - pendingProductIds),
        pendingProductIds = pendingProductIds,
        productIdDuplicates = tonumber(productStats.duplicates) or 0,
        pendingOriginZones = pendingOriginZones,
    }
end
