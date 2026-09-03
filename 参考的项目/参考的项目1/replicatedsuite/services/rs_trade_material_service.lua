------------------------------------------------------------------------
-- Replicated Suite - Trade material recipe resolver
-- Author: Replicated
--
-- Recipe data is static reference data supplied by the user. Route and payout
-- remain server-authoritative through X2Store; auction prices remain live data.
--
-- Localization policy:
--   * displayName is UI-only and never participates in auction identity.
--   * auction identity is itemType (+ itemGrade hint) only.
--   * includeInCost=false marks non-auction special currency/materials that
--     must be shown in the recipe but must not block material-cost/profit math.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S=ReplicatedSuite; S.Services=S.Services or {}; S.Services.TradeMaterials={}
local M=S.Services.TradeMaterials

local ZONE_EN_BY_ID = {
    [1]="Gweonid", [2]="Marianople", [3]="Dewstone", [4]="Solis", [5]="Solzreed",
    [6]="Lilyut", [7]="Arcum Iris", [8]="Two Crowns", [9]="Mahadevi", [10]="Airain",
    [11]="Falcorth", [12]="Villanelle", [13]="Sunbite", [14]="Windscour", [15]="Perinoor",
    [16]="Rookborne", [17]="Ynystere", [18]="White Arden", [19]="Karkasse", [20]="Cinderstone",
    [21]="Aubre", [22]="Halcyona", [23]="Hasla", [24]="Tigerspine", [25]="Silent Forest",
    [26]="Hellswamp", [27]="Sanddeep", [54]="Exeloch", [56]="Sungold", [57]="Golden Ruins",
    [93]="Ahnimar", [99]="Rokhala", [102]="Aegis", [103]="Whalesong",
}
local ZONE_QUALITY_BY_ID = {
    [1]="Commercial", [2]="Fine", [3]="Fine", [4]="Luxury", [5]="Luxury", [6]="Fine",
    [7]="Commercial", [8]="Luxury", [9]="Fine", [10]="Commercial", [11]="Fine", [12]="Luxury",
    [13]="Commercial", [14]="Preserved", [15]="Preserved", [16]="Preserved", [17]="Commercial",
    [18]="Commercial", [19]="Commercial", [20]="Luxury", [21]="Commercial", [22]="Preserved",
    [23]="Preserved", [24]="Fine", [25]="Commercial", [26]="Preserved", [27]="Preserved",
    [54]="Coastal", [56]="Coastal", [57]="Coastal", [93]="Preserved", [99]="Preserved",
    [102]="Coastal", [103]="Coastal",
}

-- Auction House identity metadata.
--
-- IMPORTANT: TradeMaterialResources uses compact recipe-resource ids (1..68).
-- Those ids are NOT X2Auction itemType values. itemType below is the actual
-- server item database id and is the ONLY auction identity Authority.
-- itemGrade/itemGradeOffset is merely a preferred grade hint; the auction
-- service can probe the small trade-material grade range by the SAME itemType
-- when a hint is stale. Localized names are fallback discovery text only and
-- can never replace itemType as the accepted auction identity.
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
    ["Lumber"]={itemType=8337,gradeOffset=0},
    ["Honey"]={itemType=28481,gradeOffset=0},
    ["Hay Bale"]={itemType=3712,gradeOffset=0},
    ["Royal Seed"]={itemType=42343,gradeOffset=3},
    ["Cultivated Ginseng"]={itemType=3680,gradeOffset=0},
    ["Quality Certificate"]={itemType=4747,gradeOffset=0},
    ["Cedar Hardwood"]={itemType=3426,gradeOffset=0},
    -- itemType values verified against the official ArcheRage wiki item DB.
    ["Time-Space Rift Shard"]={itemType=45045,gradeOffset=0},
    ["Iron Ingot"]={itemType=8318,gradeOffset=0},
    ["Blue Salt Bond"]={itemType=41488,gradeOffset=0},
    ["Small Root Pigment"]={itemType=19448,gradeOffset=0},
    ["Small Seed Oil"]={itemType=19449,gradeOffset=0},
    ["Opaque Polish"]={itemType=19450,gradeOffset=0},
}


-- Reverse lookup used by the live X2Craft resolver.  The compact static recipe
-- resource ids above are historical Suite data; live craft material itemType is
-- the runtime identity Authority whenever the current client exposes it.
local RESOURCE_EN_BY_ITEM_TYPE = {}
local RESOURCE_ITEM_TYPE_BY_NAME = {}
for resourceName, meta in pairs(RESOURCE_AUCTION_META) do
    local itemType = meta and tonumber(meta.itemType) or nil
    if itemType ~= nil and itemType > 0 then
        itemType = math.floor(itemType)
        RESOURCE_EN_BY_ITEM_TYPE[itemType] = resourceName
        RESOURCE_ITEM_TYPE_BY_NAME[resourceName] = itemType
    end
end
-- Gilda Star intentionally has no auction metadata because it is excluded from
-- cost math, but live craft data still needs to resolve its canonical policy.
RESOURCE_EN_BY_ITEM_TYPE[23633] = "Gilda Star"
RESOURCE_ITEM_TYPE_BY_NAME["Gilda Star"] = 23633



-- Gilda Stars are recipe currency, not an auction material. They remain visible
-- so the recipe is complete, but are intentionally excluded from auction cost
-- and therefore can never make a profit quote incomplete.
local RESOURCE_COST_POLICY = {
    ["Gilda Star"]={includeInCost=false, auctionable=false, note="特殊货币，不计成本"},
    -- Current ArcheRage database marks this legacy certificate as no longer
    -- purchasable/usable. Keep it visible so the recipe is complete, but do not
    -- let an unavailable auction quote block the tradable-material cost.
    ["Quality Certificate"]={includeInCost=false, auctionable=false, note="当前不可购买，不计拍卖成本"},
}

local function Contains(text, token)
    return type(text)=="string" and string.find(text, token, 1, true)~=nil
end

local function RecipeTables()
    return {S.Data.TradeMaterialNuia, S.Data.TradeMaterialHaranya, S.Data.TradeMaterialAuroria, S.Data.TradeMaterialCustom}
end

local function FindRecipe(name)
    if type(name)~="string" then return nil end
    for _,tbl in ipairs(RecipeTables()) do
        if type(tbl)=="table" and tbl[name]~=nil then return tbl[name],name end
    end
    return nil
end

local function ResourceNameById(resourceId)
    resourceId=tonumber(resourceId)
    for name,value in pairs(S.Data.TradeMaterialResources or {}) do
        if type(value)=="table" and tonumber(value[1])==resourceId then return name end
    end
    return nil
end

function M:DisplayResourceName(name, itemType)
    local numeric = tonumber(itemType) or RESOURCE_ITEM_TYPE_BY_NAME[tostring(name or "")]
    if S.Localization ~= nil and type(S.Localization.GetName) == "function" and numeric ~= nil then
        local text, verified = S.Localization:GetName("item", numeric, nil)
        if verified == true then return text end
    end
    return numeric ~= nil and ("物品ID " .. tostring(numeric)) or tostring(name or "未知材料")
end

function M:BuildMaterials(required)
    if type(required)~="table" or type(required[1])~="table" or type(required[2])~="table" then return {} end
    local counts,ids=required[1],required[2]; local rows={}
    for i=1,math.min(#counts,#ids) do
        local en=ResourceNameById(ids[i])
        if en~=nil then
            local policy=RESOURCE_COST_POLICY[en] or {}
            local auctionMeta=RESOURCE_AUCTION_META[en]
            -- itemType fallback (2026-08-24): RESOURCE_AUCTION_META only covers
            -- auctionable materials. Recipe-only currencies like Gilda Star
            -- (23633) have no auction metadata, yet the craft window must still
            -- match them against the bag. Reverse-look up the EN name in
            -- RESOURCE_EN_BY_ITEM_TYPE to recover the server item id.
            local itemType = auctionMeta and tonumber(auctionMeta.itemType) or nil
            if itemType == nil then itemType = RESOURCE_ITEM_TYPE_BY_NAME[en] end
            local display=self:DisplayResourceName(en,itemType)
            rows[#rows+1]={
                id=tonumber(ids[i]), name=en, displayName=display,
                itemType=itemType,
                itemGrade=auctionMeta and tonumber(auctionMeta.itemGrade) or nil,
                itemGradeOffset=auctionMeta and tonumber(auctionMeta.gradeOffset) or 0,
                count=math.max(0,tonumber(counts[i]) or 0), priceCopper=nil, costCopper=nil,
                includeInCost=policy.includeInCost~=false,
                auctionable=policy.auctionable~=false,
                costNote=policy.note,
            }
        end
    end
    return rows
end

-- Returns the production-zone id encoded by a canonical recipe key.
-- This is presentation metadata only; recipe/material identity still comes from
-- FindRecipe + RESOURCE_AUCTION_META and never from localized zone text.
function M:GetRecipeZoneId(recipeName)
    local raw=tostring(recipeName or "")
    if raw=="" then return nil end
    local bestId,bestLength=nil,0
    for zoneId,zoneEn in pairs(ZONE_EN_BY_ID) do
        local prefix=tostring(zoneEn).." "
        if string.find(raw,prefix,1,true)==1 and #tostring(zoneEn)>bestLength then
            bestId,bestLength=tonumber(zoneId),#tostring(zoneEn)
        end
    end
    return bestId
end

function M:GetRecipeZoneLabel(recipeName)
    local zoneId=self:GetRecipeZoneId(recipeName)
    if zoneId==nil then return tostring(recipeName or "货物") end
    local trade=S.Services and S.Services.Trade or nil
    if trade~=nil and type(trade.ZoneName)=="function" then
        local ok,label=pcall(function() return trade:ZoneName(zoneId) end)
        label=ok and tostring(label or "") or ""
        -- Trade:ZoneName falls back to the numeric id while server production
        -- zones are still loading. Do not expose that transient value in UI.
        if label~="" and label~="--" and label~=tostring(zoneId) then return label end
    end
    return ZONE_EN_BY_ID[zoneId] or tostring(recipeName or "货物")
end

function M:ResolveRecipeName(packName,originZone)
    local raw=tostring(packName or "")
    if raw=="" then return nil end
    local direct, directName=FindRecipe(raw); if direct~=nil then return directName end

    -- Localized pack labels must NEVER choose a different production region.
    -- The old table hard-mapped [十字星] to Hasla, which made Cinderstone packs
    -- display Hasla's Duck Down + Medicinal Powder recipe.  originZone is the
    -- region Authority; localized text is used only to identify the pack family.

    local zoneId=tonumber(originZone)
    local zoneEn=ZONE_EN_BY_ID[zoneId]
    local quality=ZONE_QUALITY_BY_ID[zoneId]
    if zoneEn==nil or quality==nil then return nil end

    local tail=nil
    if Contains(raw,"特制特产") then tail="Gilda Specialty"
    elseif Contains(raw,"传统特产") then tail="Local Specialty"
    elseif Contains(raw,"肥料特产") then tail="Fertilizer Specialty"
    elseif Contains(raw,"特产") then tail="Specialty" end
    if tail==nil then return nil end

    local candidates={}
    if quality=="Coastal" then
        candidates[#candidates+1]=zoneEn.." Coastal "..tail
        if tail=="Specialty" then candidates[#candidates+1]=zoneEn.." Coastal Local Specialty" end
    else
        candidates[#candidates+1]=zoneEn.." "..quality.." "..tail
    end
    for _,candidate in ipairs(candidates) do
        if FindRecipe(candidate)~=nil then return candidate end
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- Live recipe resolver
--
-- ArcheRage RU officially exposes GetCraftTypeByItemType + GetCraftMaterialInfo.
-- These calls are made only when the user opens a trade-pack detail row, never
-- from Tick/loops.  Static tables remain a compatibility fallback for clients
-- that do not expose the live craft data or for unusual custom packs.
-- ---------------------------------------------------------------------------
M.liveRecipeCache=M.liveRecipeCache or {}

local ITEM_TYPE_KEYS={"itemType","itemTypeId","item_type","typeId"}
local COUNT_KEYS={"count","amount","requiredCount","requireCount","needCount","itemCount","stackCount","quantity","num"}
local NAME_KEYS={"name","itemName","displayName"}
local GRADE_KEYS={"itemGrade","grade","gradeId","grade_id"}

local function FirstNumber(tbl,keys)
    if type(tbl)~="table" then return nil end
    for _,key in ipairs(keys or {}) do
        local value=tonumber(tbl[key])
        if value~=nil and value==value then return value end
    end
    return nil
end

local function FirstText(tbl,keys)
    if type(tbl)~="table" then return nil end
    for _,key in ipairs(keys or {}) do
        local value=tbl[key]
        if type(value)=="string" and value~="" then return value end
    end
    return nil
end

local function ExtractItemRecord(tbl)
    if type(tbl)~="table" then return nil,nil,nil end
    local itemType=FirstNumber(tbl,ITEM_TYPE_KEYS)
    local name=FirstText(tbl,NAME_KEYS)
    local grade=FirstNumber(tbl,GRADE_KEYS)
    for _,key in ipairs({"itemInfo","item","info","tooltip","productInfo","materialInfo"}) do
        local child=tbl[key]
        if type(child)=="table" then
            itemType=itemType or FirstNumber(child,ITEM_TYPE_KEYS)
            name=name or FirstText(child,NAME_KEYS)
            grade=grade or FirstNumber(child,GRADE_KEYS)
        end
    end
    itemType=tonumber(itemType)
    if itemType~=nil and itemType>0 then itemType=math.floor(itemType) else itemType=nil end
    return itemType,name,grade
end

local function CollectMaterialCandidates(node,inheritedCount,out,seenTables,depth)
    if type(node)~="table" then return end
    depth=tonumber(depth) or 0
    if depth>8 or seenTables[node] then return end
    seenTables[node]=true

    local count=FirstNumber(node,COUNT_KEYS) or tonumber(inheritedCount)
    if count==nil and type(node[1])=="table" and tonumber(node[2])~=nil then count=tonumber(node[2]) end
    local itemType,name,grade=ExtractItemRecord(node)
    if itemType~=nil and count~=nil and count>0 then
        local existing=out[itemType]
        if existing==nil or (tonumber(existing.count) or 0)<count then
            out[itemType]={itemType=itemType,count=count,name=name,itemGrade=grade}
        elseif existing.name==nil and name~=nil then
            existing.name=name
        end
    end

    -- Common parallel-array shapes used by native UI bindings.
    local infos=node.materials or node.materialInfos or node.items
    local counts=node.counts or node.amounts or node.requiredCounts or node.needCounts
    if type(infos)=="table" and type(counts)=="table" then
        for index,child in ipairs(infos) do
            CollectMaterialCandidates(child,tonumber(counts[index]),out,seenTables,depth+1)
        end
    end

    for key,child in pairs(node) do
        if type(child)=="table" then
            local childCount=count
            if type(key)=="number" and type(node[key+1])=="number" and type(child)=="table" then childCount=tonumber(node[key+1]) or childCount end
            CollectMaterialCandidates(child,childCount,out,seenTables,depth+1)
        end
    end
end

local function CollectCraftTypes(value,list,seen,depth)
    depth=tonumber(depth) or 0
    if depth>5 then return end
    local number=tonumber(value)
    if number~=nil and type(value)~="table" then
        number=math.floor(number)
        if number>0 and not seen[number] then seen[number]=true; list[#list+1]=number end
        return
    end
    if type(value)~="table" then return end
    for _,key in ipairs({"craftType","craftTypeId","craft_type"}) do
        local id=tonumber(value[key])
        if id~=nil then id=math.floor(id); if id>0 and not seen[id] then seen[id]=true; list[#list+1]=id end end
    end
    for key,child in pairs(value) do
        if type(key)=="number" or key=="craftTypes" or key=="types" or key=="list" then CollectCraftTypes(child,list,seen,depth+1) end
    end
end

local function BuildLiveRows(candidates)
    local rows={}
    for itemType,candidate in pairs(candidates or {}) do
        local canonical=RESOURCE_EN_BY_ITEM_TYPE[tonumber(itemType)]
        local staticMeta=canonical and RESOURCE_AUCTION_META[canonical] or nil
        local policy=canonical and (RESOURCE_COST_POLICY[canonical] or {}) or {}
        local liveName=tostring(candidate.name or "")
        local display=liveName~="" and liveName or M:DisplayResourceName(canonical,itemType)
        local keyName=canonical or liveName
        if keyName=="" then keyName="item:"..tostring(itemType) end
        rows[#rows+1]={
            id=nil,
            name=keyName,
            displayName=display,
            itemType=tonumber(itemType),
            itemGrade=tonumber(candidate.itemGrade) or (staticMeta and tonumber(staticMeta.itemGrade)) or nil,
            itemGradeOffset=(staticMeta and tonumber(staticMeta.gradeOffset)) or 0,
            count=math.max(0,tonumber(candidate.count) or 0),
            priceCopper=nil,
            costCopper=nil,
            includeInCost=policy.includeInCost~=false,
            auctionable=policy.auctionable~=false,
            costNote=policy.note,
            liveRecipe=true,
        }
    end
    table.sort(rows,function(a,b)
        local ai,bi=tonumber(a.itemType) or 0,tonumber(b.itemType) or 0
        return ai<bi
    end)
    return rows
end

local function CollectProductItemTypes(node,out,seen,depth)
    if type(node)~="table" then return end
    depth=tonumber(depth) or 0
    if depth>6 or seen[node] then return end
    seen[node]=true
    local itemType=ExtractItemRecord(node)
    if itemType~=nil then out[#out+1]=itemType end
    for _,child in pairs(node) do
        if type(child)=="table" then CollectProductItemTypes(child,out,seen,depth+1) end
    end
end

function M:GetLiveMaterialsForItem(itemType)
    itemType=tonumber(itemType)
    if itemType==nil or itemType<=0 then return nil,nil,"missing itemType" end
    itemType=math.floor(itemType)
    local cached=self.liveRecipeCache[itemType]
    if type(cached)=="table" and type(cached.rows)=="table" and #cached.rows>0 then
        local copy={}
        for index,row in ipairs(cached.rows) do local cloned={}; for key,value in pairs(row) do cloned[key]=value end; copy[index]=cloned end
        return copy,cached.craftType,nil
    end
    if S.Api==nil or type(S.Api.IsCapabilityAllowed)~="function" then return nil,nil,"api unavailable" end
    if S.Api:IsCapabilityAllowed("X2Craft:GetCraftTypeByItemType")~=true
        or S.Api:IsCapabilityAllowed("X2Craft:GetCraftMaterialInfo")~=true then
        return nil,nil,"craft capability unavailable"
    end

    local ok,a,err,b,c,d=S.Api:CallCapability("X2Craft:GetCraftTypeByItemType",X2Craft,"GetCraftTypeByItemType",itemType)
    if not ok then return nil,nil,tostring(err or "craft type lookup failed") end
    local craftTypes,seen={},{}
    CollectCraftTypes(a,craftTypes,seen,0); CollectCraftTypes(b,craftTypes,seen,0); CollectCraftTypes(c,craftTypes,seen,0); CollectCraftTypes(d,craftTypes,seen,0)
    if #craftTypes==0 then return nil,nil,"craft type not found" end

    -- GetCraftTypeByItemType returns are heuristically collected, so a stale or
    -- colliding id can resolve to a valid-but-unrelated craft.  Trust a craft's
    -- material list only after its PRODUCT side names the queried itemType; a
    -- mismatch (or an opaque product payload) falls through to the next
    -- candidate and finally to the verified static tables.
    local productProbeAllowed=S.Api:IsCapabilityAllowed("X2Craft:GetCraftProductInfo")==true
    local function CraftProducesQueriedItem(craftType)
        if not productProbeAllowed then return true end
        local pok,pa,perr,pb,pc,pd=S.Api:CallCapability("X2Craft:GetCraftProductInfo",X2Craft,"GetCraftProductInfo",craftType)
        if pok~=true then return false end
        local found={}; local seenProducts={}
        CollectProductItemTypes(pa,found,seenProducts,0)
        CollectProductItemTypes(pb,found,seenProducts,0)
        CollectProductItemTypes(pc,found,seenProducts,0)
        CollectProductItemTypes(pd,found,seenProducts,0)
        if #found==0 then return true end
        for _,produced in ipairs(found) do
            if produced==itemType then return true end
        end
        return false
    end

    for _,craftType in ipairs(craftTypes) do
        if CraftProducesQueriedItem(craftType) then
            local mok,ma,merr,mb,mc,md=S.Api:CallCapability("X2Craft:GetCraftMaterialInfo",X2Craft,"GetCraftMaterialInfo",craftType,0)
            if mok==true then
                local candidates={}; local visited={}
                CollectMaterialCandidates(ma,nil,candidates,visited,0)
                CollectMaterialCandidates(mb,nil,candidates,visited,0)
                CollectMaterialCandidates(mc,nil,candidates,visited,0)
                CollectMaterialCandidates(md,nil,candidates,visited,0)
                local rows=BuildLiveRows(candidates)
                if #rows>0 then
                    self.liveRecipeCache[itemType]={craftType=craftType,rows=rows}
                    local copy={}; for index,row in ipairs(rows) do local cloned={}; for key,value in pairs(row) do cloned[key]=value end; copy[index]=cloned end
                    return copy,craftType,nil
                end
            elseif merr~=nil then
                -- Keep trying alternative craft types if the item has more than one.
            end
        end
    end
    return nil,nil,"live material info empty"
end

function M:GetMaterialsForPack(packName,originZone,itemType)
    local raw=tostring(packName or "")
    if raw=="" then return {},nil,"none" end

    -- Current client craft data is authoritative when the trade-ratio row
    -- exposes the produced item's stable itemType.  This automatically follows
    -- ArcheRage recipe changes without requiring another static table update.
    local liveRows,craftType=self:GetLiveMaterialsForItem(itemType)
    if type(liveRows)=="table" and #liveRows>0 then
        return liveRows,"craft:"..tostring(craftType or "?"),"live"
    end

    -- Fertilizer and aged-larder recipes are shared families and do not need a
    -- localized pack-name lookup.
    if Contains(raw,"肥料特产") or Contains(raw,"Fertilizer Specialty") then
        return self:BuildMaterials(S.Data.TradeMaterialFertilizer),"Fertilizer Specialty","static"
    end
    if Contains(raw,"蜂蜜") or Contains(raw,"Aged Honey") then
        return self:BuildMaterials({{2,4,20,1},{62,63,64,65}}),"Aged Honey","static"
    end
    if Contains(raw,"奶酪") or Contains(raw,"Aged Cheese") then
        return self:BuildMaterials({{2,50,30,1},{62,12,48,65}}),"Aged Cheese","static"
    end
    if Contains(raw,"药材") or Contains(raw,"Aged Salve") then
        return self:BuildMaterials({{2,20,30,1},{62,66,13,65}}),"Aged Salve","static"
    end
    -- Zone Space-Time Fragment / Blue Salt transport packs are shared families
    -- verified against the official ArcheRage wiki craft DB; the recipe is
    -- identical in every zone.
    if Contains(raw,"时空碎片") or Contains(raw,"Space-Time Fragment") then
        return self:BuildMaterials(S.Data.TradeMaterialFragment),"Space-Time Fragment","static"
    end
    if Contains(raw,"蓝盐商会运输品") then
        return self:BuildMaterials(S.Data.TradeMaterialTransport),"Bluesalt Transport","static"
    end

    local resolved=self:ResolveRecipeName(raw,originZone)
    local required=resolved and FindRecipe(resolved) or nil
    if required==nil then return {},resolved,"none" end
    return self:BuildMaterials(required),resolved,"static"
end
