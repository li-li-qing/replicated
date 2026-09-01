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
M.presentationBoundary = "service_only"
M.presentationDebt = nil
local SharedItemIds=(S.GameIds and S.GameIds.Item) or {}
local SharedBondMaterials=SharedItemIds.BOND_MATERIAL or {}

local SharedZones=(S.GameIds and S.GameIds.Zone) or {}
local ZONE_BY_ID=SharedZones.ById or {}


-- Auction House identity metadata.
--
-- IMPORTANT: TradeMaterialResources uses compact recipe-resource ids (1..68).
-- Those ids are NOT X2Auction itemType values. itemType below is the actual
-- server item database id and is the ONLY auction identity Authority.
-- itemGrade/itemGradeOffset is merely a preferred grade hint; the auction
-- service can probe the small trade-material grade range by the SAME itemType
-- when a hint is stale. Localized names are fallback discovery text only and
-- can never replace itemType as the accepted auction identity.
local RESOURCE_AUCTION_META = (S.Data and S.Data.TradeMaterialAuctionMeta) or {}


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
    local tradeStatic=S.Data and S.Data.TradeStaticV2 or nil
    if tradeStatic~=nil and type(tradeStatic.GetMaterialByCompactId)=="function" then
        local row=tradeStatic:GetMaterialByCompactId(resourceId)
        if type(row)=="table" then return row.nameEn end
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
    for zoneId,zone in pairs(ZONE_BY_ID) do
        local zoneEn=type(zone)=="table" and tostring(zone.nameEn or "") or ""
        local prefix=zoneEn.." "
        if zoneEn~="" and string.find(raw,prefix,1,true)==1 and #zoneEn>bestLength then
            bestId,bestLength=tonumber(zoneId),#zoneEn
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
    local zone=ZONE_BY_ID[zoneId]
    return type(zone)=="table" and tostring(zone.nameEn or recipeName or "货物") or tostring(recipeName or "货物")
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
    local zone=ZONE_BY_ID[zoneId]
    local zoneEn=type(zone)=="table" and zone.nameEn or nil
    local quality=type(zone)=="table" and zone.tradeQuality or nil
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
