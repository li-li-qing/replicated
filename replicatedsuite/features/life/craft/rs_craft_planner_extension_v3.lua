------------------------------------------------------------------------
-- Replicated Suite V3 - Craft Planner Multi-Recipe Extension
--
-- Extends the existing life_craft_planner Authority after rs_business_bridge
-- without adding more top-level locals to that Lua-5.1-budget-critical file.
-- The plan uses only governed StaticDataV2 recipe/material identities plus the
-- already-built Craft projection and shared PriceQuoteQueueV3 read model.
--
-- Serialization contract:
--   State.planItems = array(max 12) of { recipeKey=string, quantity=int[1,999] }
-- Only stable StaticDataV2 recipe keys are persisted. Native CraftIDs, bag slot
-- indices, transient prices, held counts and derived material totals are never
-- serialized into the plan. This keeps upgrade/migration semantics stable.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local Feature = S.Features and S.Features.life_craft_planner or nil
local P = S.Persistence
if type(Feature) ~= "table" or type(P) ~= "table" then return end

local MAX_PLAN_ITEMS = 12
local MAX_QUANTITY = 999

local function Copy(value)
    if S.Utils ~= nil and type(S.Utils.DeepCopy) == "function" then return S.Utils.DeepCopy(value) end
    if type(value) ~= "table" then return value end
    local out = {}; for key, child in pairs(value) do out[key] = Copy(child) end; return out
end

local function Recipe(recipeKey)
    if S.StaticDataV2 == nil or type(S.StaticDataV2.Get) ~= "function" then return nil end
    return S.StaticDataV2:Get("trade_recipe", tostring(recipeKey or ""))
end

local function Material(materialKey)
    if S.StaticDataV2 == nil or type(S.StaticDataV2.Get) ~= "function" then return nil end
    return S.StaticDataV2:Get("trade_material", tostring(materialKey or ""))
end

local function Quantity(value)
    local n = tonumber(value)
    if n == nil or n ~= math.floor(n) then return nil end
    n = math.floor(n)
    if n < 1 or n > MAX_QUANTITY then return nil end
    return n
end

local function NormalizePlan(source)
    local output, byKey = {}, {}
    for _, raw in ipairs(type(source) == "table" and source or {}) do
        local key = tostring(type(raw) == "table" and raw.recipeKey or "")
        local quantity = Quantity(type(raw) == "table" and raw.quantity or nil)
        if key ~= "" and quantity ~= nil and Recipe(key) ~= nil then
            if byKey[key] ~= nil then
                local index = byKey[key]
                output[index].quantity = math.min(MAX_QUANTITY, output[index].quantity + quantity)
            elseif #output < MAX_PLAN_ITEMS then
                output[#output + 1] = { recipeKey = key, quantity = quantity }
                byKey[key] = #output
            end
        end
    end
    return output
end

local function ProductName(record)
    if type(record) ~= "table" then return "未知制作物" end
    local itemType = tonumber(record.productItemId)
    if itemType ~= nil and S.Localization ~= nil and type(S.Localization.GetName) == "function" then
        local ok, name = pcall(S.Localization.GetName, S.Localization, "item", itemType, nil)
        if ok == true and type(name) == "string" and name ~= "" then return name end
    end
    local legacy = tostring(record.legacyName or "")
    return legacy ~= "" and legacy or "已核制作物"
end

local function MaterialName(record)
    if type(record) ~= "table" then return "未知材料" end
    local itemType = tonumber(record.itemId)
    if itemType ~= nil and S.Localization ~= nil and type(S.Localization.GetName) == "function" then
        local ok, name = pcall(S.Localization.GetName, S.Localization, "item", itemType, nil)
        if ok == true and type(name) == "string" and name ~= "" then return name end
    end
    local legacy = tostring(record.nameEn or "")
    return legacy ~= "" and legacy or "已核材料"
end

local function FormatMoney(value)
    value = math.max(0, tonumber(value) or 0)
    if S.Utils ~= nil and type(S.Utils.FormatMoney) == "function" then
        local ok, text = pcall(S.Utils.FormatMoney, value)
        if ok == true and type(text) == "string" and text ~= "" then return text end
    end
    return tostring(math.floor(value + 0.5))
end

local function BuildPlanProjection(base)
    local plan = NormalizePlan(Feature.State and Feature.State.planItems)
    local held = type(base) == "table" and type(base.craft) == "table" and type(base.craft.held) == "table" and base.craft.held or {}
    local heldKnown = type(base) == "table" and type(base.craft) == "table" and type(base.craft.bag) == "table" and base.craft.bag.status == "ready"
    local recipeRows, materialMap, materialOrder = {}, {}, {}

    for _, entry in ipairs(plan) do
        local record = Recipe(entry.recipeKey)
        if type(record) == "table" then
            local uniqueMaterials, recipeMaterialSeen = 0, {}
            for _, ingredient in ipairs(type(record.ingredients) == "table" and record.ingredients or {}) do
                local count = tonumber(ingredient.count)
                count = count ~= nil and count == math.floor(count) and count >= 1 and count <= 1000000 and math.floor(count) or nil
                local material = Material(ingredient.materialKey)
                if count ~= nil and type(material) == "table" then
                    local mapKey = tostring(material.key or ingredient.materialKey or "")
                    if mapKey ~= "" then
                        if recipeMaterialSeen[mapKey] ~= true then recipeMaterialSeen[mapKey] = true; uniqueMaterials = uniqueMaterials + 1 end
                        local row = materialMap[mapKey]
                        if row == nil then
                            row = {
                                key = "plan-material:" .. mapKey, materialKey = mapKey,
                                itemType = tonumber(material.itemId), itemGrade = tonumber(material.itemGrade),
                                name = MaterialName(material), required = 0,
                                includeInCost = material.includeInCost ~= false,
                                auctionable = material.auctionable == true and tonumber(material.itemId) ~= nil,
                            }
                            materialMap[mapKey] = row; materialOrder[#materialOrder + 1] = mapKey
                        end
                        row.required = math.min(1000000000, row.required + count * entry.quantity)
                    end
                end
            end
            recipeRows[#recipeRows + 1] = {
                key = "plan-recipe:" .. tostring(entry.recipeKey), recipeKey = entry.recipeKey,
                name = ProductName(record), quantity = entry.quantity, materialCount = uniqueMaterials,
                craftId = tonumber(record.craftId),
            }
        end
    end

    local queue = S.Services and S.Services.PriceQuoteQueueV3 or nil
    local materialRows, pending, priced, quotedRequired, quotedShortage = {}, 0, 0, 0, 0
    for _, mapKey in ipairs(materialOrder) do
        local row = materialMap[mapKey]
        row.held = row.itemType ~= nil and heldKnown and tonumber(held[row.itemType]) or nil
        row.shortage = row.held ~= nil and math.max(0, row.required - row.held) or nil
        if row.includeInCost == true and row.itemType ~= nil and type(queue) == "table" and type(queue.GetPriceByItemType) == "function" then
            row.unitCost = queue:GetPriceByItemType(row.itemType, row.itemGrade)
        end
        if row.unitCost ~= nil then
            row.requiredCost = math.max(0, tonumber(row.unitCost) or 0) * row.required
            row.shortageCost = row.shortage ~= nil and math.max(0, tonumber(row.unitCost) or 0) * row.shortage or nil
            priced = priced + 1
            quotedRequired = quotedRequired + row.requiredCost
            if row.shortageCost ~= nil then quotedShortage = quotedShortage + row.shortageCost end
            row.costStatus = "quoted"
        elseif row.includeInCost ~= true then
            row.costStatus = "excluded"
        elseif row.auctionable == true then
            row.costStatus = "explicit_quote_required"; pending = pending + 1
        else
            row.costStatus = "identity_unavailable"
        end
        row.requiredText = tostring(row.required)
        row.heldText = row.held ~= nil and tostring(row.held) or "?"
        row.shortageText = row.shortage ~= nil and tostring(row.shortage) or "?"
        row.priceText = row.unitCost ~= nil and FormatMoney(row.unitCost) or (row.costStatus == "excluded" and "排除" or "未询价")
        materialRows[#materialRows + 1] = row
    end
    table.sort(materialRows, function(a, b) return tostring(a.name) < tostring(b.name) end)

    return {
        planItems = Copy(plan), planRecipeRows = recipeRows, planMaterialRows = materialRows,
        planRecipeCount = #recipeRows, planMaterialCount = #materialRows,
        planPendingQuoteCount = pending, planPricedMaterialCount = priced,
        planQuotedRequiredCostCopper = math.floor(quotedRequired + 0.5),
        planQuotedShortageCostCopper = math.floor(quotedShortage + 0.5),
        planHeldStatus = heldKnown and "ready" or "unknown",
        planMaxItems = MAX_PLAN_ITEMS,
    }
end

local function Persist(reason, mutator)
    if type(P.MutateStore) ~= "function" then return false, "制作计划持久化事务不可用" end
    local ok, err = P:MutateStore(Feature.storeId, function()
        Feature.State.planItems = NormalizePlan(Feature.State.planItems)
        local changed, changeErr = mutator(Feature.State.planItems)
        if changed ~= true then return false, changeErr or "制作计划没有变化" end
        Feature.State.planItems = NormalizePlan(Feature.State.planItems)
        return true
    end, { delayMs = 300, reason = tostring(reason or "craft_plan_changed") })
    if ok ~= true then return false, tostring(err or "制作计划保存失败") end
    Feature:Refresh(reason)
    return true
end

local baseInitialize = Feature.Initialize
function Feature:Initialize()
    local ok, err = baseInitialize(self)
    if ok ~= true then return ok, err end
    self.State.planItems = NormalizePlan(self.State.planItems)
    return true
end

local baseProjection = Feature.GetProjection
function Feature:GetProjection()
    local projection = baseProjection(self) or {}
    local plan = BuildPlanProjection(projection)
    for key, value in pairs(plan) do projection[key] = Copy(value) end
    projection.rows = type(projection.rows) == "table" and projection.rows or {}
    if plan.planRecipeCount > 0 then
        projection.rows[#projection.rows + 1] = {
            key = "craft:plan:summary", name = "制作计划",
            text = tostring(plan.planRecipeCount) .. " 个制作物 · " .. tostring(plan.planMaterialCount) .. " 种聚合材料"
                .. (plan.planPendingQuoteCount > 0 and (" · 待询价 " .. tostring(plan.planPendingQuoteCount)) or "")
                .. (plan.planPricedMaterialCount > 0 and (" · 已报价总需求 " .. FormatMoney(plan.planQuotedRequiredCostCopper)) or ""),
            statusText = plan.planPendingQuoteCount > 0 and "部分可用" or "已聚合", tone = plan.planPendingQuoteCount > 0 and "warn" or "default", source = "CraftPlanV3",
        }
        for _, row in ipairs(plan.planMaterialRows) do
            projection.rows[#projection.rows + 1] = {
                key = row.key, name = row.name,
                text = "计划需 " .. row.requiredText .. " · 持有 " .. row.heldText .. " · 缺口 " .. row.shortageText .. " · " .. row.priceText,
                statusText = row.costStatus == "quoted" and "已报价" or row.costStatus == "excluded" and "不计成本" or "待询价",
                tone = (row.costStatus == "quoted" or row.costStatus == "excluded") and "default" or "warn", source = "CraftPlanV3",
            }
        end
    end
    return projection
end

function Feature.Commands:AddPlanRecipe(recipeKey, quantity)
    local key, amount = tostring(recipeKey or ""), Quantity(quantity)
    if Recipe(key) == nil then return false, "所选制作物没有已核配方" end
    if amount == nil then return false, "计划数量必须是 1-" .. tostring(MAX_QUANTITY) .. " 的整数" end
    return Persist("craft_plan_add", function(plan)
        for _, entry in ipairs(plan) do
            if entry.recipeKey == key then entry.quantity = math.min(MAX_QUANTITY, entry.quantity + amount); return true end
        end
        if #plan >= MAX_PLAN_ITEMS then return false, "制作计划最多 " .. tostring(MAX_PLAN_ITEMS) .. " 项" end
        plan[#plan + 1] = { recipeKey = key, quantity = amount }
        return true
    end)
end

function Feature.Commands:SetPlanRecipeQuantity(recipeKey, quantity)
    local key, amount = tostring(recipeKey or ""), Quantity(quantity)
    if amount == nil then return false, "计划数量必须是 1-" .. tostring(MAX_QUANTITY) .. " 的整数" end
    return Persist("craft_plan_quantity", function(plan)
        for _, entry in ipairs(plan) do if entry.recipeKey == key then entry.quantity = amount; return true end end
        return false, "制作计划中没有该制作物"
    end)
end

function Feature.Commands:RemovePlanRecipe(recipeKey)
    local key = tostring(recipeKey or "")
    return Persist("craft_plan_remove", function(plan)
        for index, entry in ipairs(plan) do if entry.recipeKey == key then table.remove(plan, index); return true end end
        return false, "制作计划中没有该制作物"
    end)
end

function Feature.Commands:ClearPlan()
    if #(NormalizePlan(Feature.State.planItems)) == 0 then return false, "制作计划已经为空" end
    return Persist("craft_plan_clear", function(plan) for index = #plan, 1, -1 do table.remove(plan, index) end; return true end)
end

function Feature.Commands:QuotePlanMaterials()
    local queue = S.Services and S.Services.PriceQuoteQueueV3 or nil
    if type(queue) ~= "table" or type(queue.RequestQuote) ~= "function" then return false, "报价服务不可用" end
    local projection = BuildPlanProjection(baseProjection(Feature) or {})
    local targets, seen = {}, {}
    for _, row in ipairs(projection.planMaterialRows or {}) do
        if row.costStatus == "explicit_quote_required" and row.itemType ~= nil then
            local key = tostring(row.itemType) .. ":" .. tostring(row.itemGrade or 0)
            if seen[key] ~= true then seen[key] = true; targets[#targets + 1] = { itemType = row.itemType, itemGrade = row.itemGrade } end
        end
    end
    if #targets == 0 then return false, "制作计划没有待询价材料" end
    local limit = math.max(1, tonumber(queue.maxQueue) or 64)
    local requested, completed, skipped, sealed = 0, 0, 0, false
    local function FinishIfReady()
        if sealed == true and requested > 0 and completed >= requested and Feature.enabled == true and (tonumber(Feature.consumerCount) or 0) > 0 then
            Feature:Refresh("craft_plan_quote_batch_completed")
        end
    end
    local function OnComplete() completed = completed + 1; FinishIfReady() end
    for index, target in ipairs(targets) do
        if index > limit then skipped = skipped + 1
        else
            local ok = queue:RequestQuote(Feature.Id .. ":plan", target.itemType, target.itemGrade, OnComplete)
            if ok == true then requested = requested + 1 else skipped = skipped + 1 end
        end
    end
    sealed = true; FinishIfReady()
    if requested == 0 then return false, "计划材料未能进入报价队列", 0, skipped end
    return true, "已提交 " .. tostring(requested) .. " 项计划材料询价" .. (skipped > 0 and ("，" .. tostring(skipped) .. " 项暂未提交") or ""), requested, skipped
end

Feature.CraftPlanContractVersion = 1
Feature.CraftPlanMaxItems = MAX_PLAN_ITEMS
