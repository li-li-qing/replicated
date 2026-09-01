------------------------------------------------------------------------
-- Replicated Suite - Trade Authority
-- Author: Replicated
--
-- X2Store is the only Authority for route/ratio data.  Requests are
-- serialized because SPECIALTY_RATIO_BETWEEN_INFO does not include route
-- identity in the supplied RU API surface.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
S.Services = S.Services or {}
S.Services.Trade = { inFlight = nil, pending = false }
local T = S.Services.Trade
T.presentationBoundary = "service_only"
T.presentationDebt = nil

local CONTINENT_ORDER = { west = 1, east = 2, auroria = 3, other = 4 }
local CONTINENT_LABEL = { west = "西大陆", east = "东大陆", auroria = "原大陆", other = "其他" }
local WEST_ANCHORS = { [1]=true, [5]=true, [8]=true, [20]=true }
local EAST_ANCHORS = { [4]=true, [12]=true, [17]=true }

-- Server/API names are the lookup Authority.  Display aliases must never replace
-- those raw names because the static payout table and recipe mappings use the
-- server-provided key.
local TRADE_PACK_DISPLAY_ALIASES = {
    ["埋骨之地角笛"] = "埋骨之地狩猎战利品",
    ["埋骨之地狩猎战利品货物"] = "埋骨之地狩猎战利品",
    ["Silent Forest Aged Garlic"] = "[古代森林]糖醋泡蒜",
}

local TRADE_PACK_PRICE_KEY_ALIASES = {
    ["埋骨之地角笛"] = { "埋骨之地角笛", "埋骨之地狩猎战利品", "埋骨之地狩猎战利品货物" },
    ["埋骨之地狩猎战利品"] = { "埋骨之地角笛", "埋骨之地狩猎战利品", "埋骨之地狩猎战利品货物" },
    ["埋骨之地狩猎战利品货物"] = { "埋骨之地角笛", "埋骨之地狩猎战利品", "埋骨之地狩猎战利品货物" },
    ["Silent Forest Aged Garlic"] = { "Silent Forest Aged Garlic", "[古代森林]糖醋泡蒜" },
}

local function ResolveTradePackDisplayName(sourceName)
    local raw = tostring(sourceName or "")
    return TRADE_PACK_DISPLAY_ALIASES[raw] or raw
end

local function ExtractStableItemType(itemInfo)
    if type(itemInfo)~="table" then return nil end
    local value=tonumber(itemInfo.itemType or itemInfo.itemTypeId or itemInfo.item_type or itemInfo.typeId)
    if value==nil and type(itemInfo.itemInfo)=="table" then
        local nested=itemInfo.itemInfo
        value=tonumber(nested.itemType or nested.itemTypeId or nested.item_type or nested.typeId)
    end
    if value==nil or value<=0 then return nil end
    return math.floor(value)
end

local function ZoneById(list, id)
    id = tonumber(id)
    for _, zone in ipairs(list or {}) do if tonumber(zone.id) == id then return zone end end
    return nil
end

function T:RebuildContinentIndex(zones)
    self.zoneContinent = {}
    local westName, eastName
    for _, zone in ipairs(zones or {}) do
        if WEST_ANCHORS[tonumber(zone.id)] and zone.continent ~= "" then westName = westName or zone.continent end
        if EAST_ANCHORS[tonumber(zone.id)] and zone.continent ~= "" then eastName = eastName or zone.continent end
    end
    for _, zone in ipairs(zones or {}) do
        local key = "other"
        if WEST_ANCHORS[tonumber(zone.id)] or (westName ~= nil and zone.continent == westName) then key = "west"
        elseif EAST_ANCHORS[tonumber(zone.id)] or (eastName ~= nil and zone.continent == eastName) then key = "east"
        elseif zone.continent ~= "" then key = "auroria" end
        zone.continentKey = key
        zone.continentLabel = CONTINENT_LABEL[key]
        zone.displayName = "[" .. CONTINENT_LABEL[key] .. "] " .. tostring(zone.name)
        self.zoneContinent[tonumber(zone.id)] = key
    end
end

function T:GetContinentKeyByZoneId(zoneId)
    return self.zoneContinent and self.zoneContinent[tonumber(zoneId)] or nil
end

function T:DecorateZone(zone)
    if type(zone) ~= "table" then return zone end
    local master = ZoneById(S.State.data.trade.zones or {}, zone.id)
    if master ~= nil then
        zone.continent = master.continent
        zone.continentKey = master.continentKey
        zone.continentLabel = master.continentLabel
    else
        zone.continentKey = self:GetContinentKeyByZoneId(zone.id) or "other"
        zone.continentLabel = CONTINENT_LABEL[zone.continentKey] or CONTINENT_LABEL.other
    end
    zone.displayName = "[" .. tostring(zone.continentLabel or "其他") .. "] " .. tostring(zone.name)
    return zone
end

function T:SortZones(list)
    table.sort(list, function(a, b)
        local ap = CONTINENT_ORDER[a.continentKey or "other"] or 9
        local bp = CONTINENT_ORDER[b.continentKey or "other"] or 9
        if ap ~= bp then return ap < bp end
        return tostring(a.name) < tostring(b.name)
    end)
end

local function AddUnique(list, seen, id, name, continent)
    id = tonumber(id)
    if id == nil or seen[id] then return end
    seen[id] = true
    list[#list + 1] = {
        id = id,
        name = tostring(name or id),
        continent = tostring(continent or ""),
    }
end

function T:NormalizeProductionZones(zones)
    local normalized, seen = {}, {}
    if type(zones) ~= "table" then return normalized end
    for key, value in pairs(zones) do
        if type(value) == "table" then
            AddUnique(
                normalized,
                seen,
                value.id or value.zoneGroupId or value.zoneGroup or value.zoneGroupType or value[1],
                value.zoneGroupName or value.name or value[2],
                value.continentName or value.continent
            )
        elseif type(value) == "number" then
            AddUnique(normalized, seen, value, nil, nil)
        elseif type(value) == "string" then
            -- Some Lua bindings expose an id->name map instead of an array.
            AddUnique(normalized, seen, tonumber(key), value, nil)
        elseif value == true then
            AddUnique(normalized, seen, tonumber(key), nil, nil)
        end
    end
    self:RebuildContinentIndex(normalized)
    self:SortZones(normalized)
    return normalized
end

function T:ZoneName(id)
    id = tonumber(id)
    for _, zone in ipairs(S.State.data.trade.zones or {}) do
        if zone.id == id then return zone.name end
    end
    return id and tostring(id) or "--"
end


function T:FindZoneByText(text)
    local wanted=S.Utils.Trim(text)
    if wanted=="" then return nil end
    local wantedLower=string.lower(wanted)
    local partial=nil
    for _,zone in ipairs(S.State.data.trade.zones or {}) do
        local name=tostring(zone.name or "")
        local display=tostring(zone.displayName or name)
        if name==wanted or display==wanted or string.lower(name)==wantedLower then return tonumber(zone.id) end
        if string.find(string.lower(name),wantedLower,1,true)~=nil or string.find(string.lower(display),wantedLower,1,true)~=nil then
            if partial~=nil and partial~=tonumber(zone.id) then return nil end
            partial=tonumber(zone.id)
        end
    end
    return partial
end

function T:SelectPack(row,showWindow)
    if type(row)~="table" then return false end
    local sourceName=tostring(row.sourceName or row.name or "")
    local materialsService=S.Services and S.Services.TradeMaterials
    local materials,resolved,recipeSource={},nil,nil
    if materialsService and type(materialsService.GetMaterialsForPack)=="function" then
        materials,resolved,recipeSource=materialsService:GetMaterialsForPack(sourceName,S.State.life.trade.fromZone,row.itemType)
    end
    local hasMaterials=#(materials or {})>0
    local hasPayout=tonumber(row.priceCopper)~=nil
    local quoteText
    if not hasMaterials then
        quoteText="该贸易品暂未匹配到制作材料表"
    elseif not hasPayout then
        quoteText="材料已匹配；缺少可靠售价基准，可查材料成本，预计售价/毛利暂不估算"
    else
        quoteText="点击“查价格”获取当前拍卖参考价"
    end
    S.State.data.trade.selectedPack={
        name=tostring(row.name or ""), sourceName=sourceName, itemType=tonumber(row.itemType), ratio=tonumber(row.ratio) or 0, rate=row.rate,
        priceCopper=tonumber(row.priceCopper), price=row.price,
        materials=materials or {}, resolvedRecipe=resolved, recipeSource=recipeSource or "none",
        materialCostCopper=nil, materialCost="--", profitCopper=nil, profit="--",
        quoteStatus=hasMaterials and "ready" or "unavailable",
        quoteText=quoteText,
    }
    S.State:MarkDirty("trade")
    if showWindow~=false and S.TradeDetailWindow and type(S.TradeDetailWindow.ShowPack)=="function" then S.TradeDetailWindow:ShowPack() end
    return true
end

function T:QuoteSelectedPack()
    local selected=S.State.data.trade.selectedPack
    if type(selected)~="table" or #(selected.materials or {})==0 then return false end
    local auction=S.Services and S.Services.Auction
    if auction==nil or type(auction.QuotePack)~="function" then return false end
    selected.quoteStatus="loading"; selected.quoteText="正在按可交易材料逐项搜索拍卖参考价…"
    for _,material in ipairs(selected.materials) do
        material.priceCopper=nil
        material.costCopper=(material.includeInCost==false) and 0 or nil
    end
    S.State:MarkDirty("trade")
    return auction:QuotePack(selected.name,selected.materials,{priceCopper=selected.priceCopper,packName=selected.name})
end

function T:OnMaterialQuote(quote)
    local selected=S.State.data.trade.selectedPack
    if type(selected)~="table" or type(quote)~="table" or tostring(selected.name)~=tostring(quote.packName) then return end
    local total=0; local complete=true; local excluded=0
    for _,material in ipairs(selected.materials or {}) do
        if material.includeInCost==false then
            material.priceCopper=nil
            material.costCopper=0
            excluded=excluded+1
        else
            local price=tonumber(quote.prices and quote.prices[material.name])
            material.priceCopper=price
            if price~=nil then
                material.costCopper=math.floor(price*(tonumber(material.count) or 0)+0.5)
                total=total+material.costCopper
            else
                material.costCopper=nil; complete=false
            end
        end
    end
    selected.excludedCostCount=excluded
    selected.materialCostCopper=complete and total or nil
    selected.materialCost=complete and S.Utils.FormatMoney(total,false) or "部分材料无价格"
    if complete and tonumber(selected.priceCopper)~=nil then
        selected.profitCopper=math.floor(selected.priceCopper-total)
        selected.profit=S.Utils.FormatMoney(selected.profitCopper,true)
    else
        selected.profitCopper=nil; selected.profit="--"
    end
    selected.quoteStatus=complete and "ready" or "partial"
    if complete then
        local quoteBase=(excluded>0)
            and "拍卖参考价已更新；特殊货币/不可购买材料不计拍卖成本"
            or "拍卖参考价已更新（缓存约2分钟）"
        if tonumber(selected.priceCopper)==nil then
            selected.quoteText=quoteBase.."；缺少可靠售价基准，毛利暂不计算"
        else
            selected.quoteText=quoteBase
        end
    else
        local failedNames={}
        local firstReason=nil
        for _,failure in ipairs(quote.failures or {}) do
            local name=tostring(failure.name or "")
            if name~="" then failedNames[#failedNames+1]=name end
            if firstReason==nil and tostring(failure.error or "")~="" then firstReason=tostring(failure.error) end
            if name~="" or tostring(failure.error or "")~="" then
                S.SafeChat("材料报价失败："..(name~="" and name or "?").." ["..tostring(failure.error or "未知原因").."]")
            end
        end
        local failedText=(#failedNames>0) and table.concat(failedNames,"、") or "部分材料"
        selected.quoteText="未报价："..failedText
        if firstReason~=nil then selected.quoteText=selected.quoteText.."（"..firstReason.."）" end
    end
    -- Mirror the selected result onto the matching route row for future UI use.
    for _,row in ipairs(S.State.data.trade.rows or {}) do
        if tostring(row.name)==tostring(selected.name) then
            row.materialCostCopper=selected.materialCostCopper
            row.profitCopper=selected.profitCopper
            row.profit=selected.profit
        end
    end
    S.State:MarkDirty("trade")
end

function T:PrintCurrentRatios(limit)
    local rows=S.State.data.trade.rows or {}
    if #rows==0 then S.SafeChat("当前没有可输出的货率，请先选择路线查询。") return end
    S.SafeChat("----- "..tostring(S.State.data.trade.route or "跑商货率").." -----")
    for i=1,math.min(math.max(1,tonumber(limit) or 10),#rows) do
        local row=rows[i]
        S.SafeChat(string.format("%d. %s · %s · %s",i,tostring(row.name or ""),tostring(row.rate or "--"),tostring(row.price or "--")))
    end
end

function T:HandleChatMessage(channel,relation,name,message)
    local okPlayer,playerName=S.Api:CallCapability("X2Unit:UnitName", X2Unit, "UnitName","player")
    if not okPlayer or tostring(name or "")~=tostring(playerName or "") then return end
    local text=tostring(message or "")
    if text=="/输出" or text=="/输出货率" or text=="/Output" then self:PrintCurrentRatios(10); return end
    local fromText,toText=text:match("^/货率%s+(%S+)%s+(%S+)%s*$")
    if not fromText then fromText,toText=text:match("^/地区%s+(%S+)%s+(%S+)%s*$") end
    if not fromText then return end
    local from=self:FindZoneByText(fromText); local to=self:FindZoneByText(toText)
    if from==nil or to==nil then S.SafeChat("地区名称未找到或匹配不唯一，请输入游戏内地区名称。") return end
    if from==to then S.SafeChat("出发地和目的地不能相同。") return end
    if not self:SelectFrom(from) then return end
    local valid=false
    for _,zone in ipairs(S.State.data.trade.sellableZones or {}) do if tonumber(zone.id)==to then valid=true; break end end
    if not valid then S.SafeChat("该目的地当前不在服务器返回的可交货列表中。") return end
    self:SelectTo(to)
    S.SafeChat("正在查询 "..self:ZoneName(from).." → "..self:ZoneName(to).." 的实时货率。")
end

local function FavoriteKey(fromZone, toZone)
    local from = tonumber(fromZone)
    local to = tonumber(toZone)
    if from == nil or to == nil then return nil end
    return tostring(math.floor(from)) .. ":" .. tostring(math.floor(to))
end

function T:GetFavorites()
    local source = S.State.life.trade.favorites
    if type(source) ~= "table" then source = {} end
    local result, seen = {}, {}

    local function Add(fromZone, toZone)
        local from = tonumber(fromZone)
        local to = tonumber(toZone)
        local key = FavoriteKey(from, to)
        if key == nil or from == to or seen[key] then return end
        seen[key] = true
        result[#result + 1] = { fromZone = from, toZone = to, key = key }
    end

    -- Arrays preserve the user's explicit favorite order. A second pass accepts
    -- the keyed "from:to" shape from any earlier experimental save without
    -- letting pairs() randomly reorder the normal array representation.
    for _, value in ipairs(source) do
        if type(value) == "table" then
            Add(value.fromZone or value.from or value[1], value.toZone or value.to or value[2])
        end
    end
    for key, value in pairs(source) do
        if type(key) ~= "number" and value == true and type(key) == "string" then
            local from, to = string.match(key, "^(%-?%d+):(%-?%d+)$")
            Add(from, to)
        end
    end
    return result
end

function T:StoreFavorites(favorites)
    local stored = {}
    for _, favorite in ipairs(favorites or {}) do
        if #stored >= 12 then break end
        local from = tonumber(favorite.fromZone)
        local to = tonumber(favorite.toZone)
        if FavoriteKey(from, to) ~= nil and from ~= to then
            stored[#stored + 1] = { fromZone = from, toZone = to }
        end
    end
    S.State.life.trade.favorites = stored
    if S.Storage ~= nil and type(S.Storage.PersistFavorites) == "function" then
        S.Storage:PersistFavorites(stored, S.State.life.auctionFavorites)
    end
    S.Storage:RequestSave()
    S.State:MarkDirty("trade")
end

function T:IsFavorite(fromZone, toZone)
    local wanted = FavoriteKey(fromZone, toZone)
    if wanted == nil then return false end
    for _, favorite in ipairs(self:GetFavorites()) do
        if favorite.key == wanted then return true end
    end
    return false
end

function T:ToggleCurrentFavorite()
    local from = tonumber(S.State.life.trade.fromZone)
    local to = tonumber(S.State.life.trade.toZone)
    local wanted = FavoriteKey(from, to)
    if wanted == nil then return false end

    local nextFavorites = {}
    local removed = false
    for _, favorite in ipairs(self:GetFavorites()) do
        if favorite.key == wanted then
            removed = true
        else
            nextFavorites[#nextFavorites + 1] = favorite
        end
    end
    if not removed then
        if #nextFavorites >= 12 then
            S.SafeChat("收藏路线最多保存 12 条，请先取消一条旧收藏。")
            return false
        end
        nextFavorites[#nextFavorites + 1] = { fromZone = from, toZone = to }
    end
    self:StoreFavorites(nextFavorites)
    return true
end

function T:GetFavoriteItems()
    local items = {}
    local currentKey = FavoriteKey(S.State.life.trade.fromZone, S.State.life.trade.toZone)
    for _, favorite in ipairs(self:GetFavorites()) do
        items[#items + 1] = {
            value = favorite.key,
            text = "[收藏] " .. self:ZoneName(favorite.fromZone) .. " > " .. self:ZoneName(favorite.toZone),
            selected = favorite.key == currentKey,
        }
    end
    return items
end

function T:SelectFavorite(key)
    key = tostring(key or "")
    local selected
    for _, favorite in ipairs(self:GetFavorites()) do
        if favorite.key == key then selected = favorite; break end
    end
    if selected == nil then return false end

    if not self:SelectFrom(selected.fromZone) then return false end
    local valid = false
    for _, zone in ipairs(S.State.data.trade.sellableZones or {}) do
        if tonumber(zone.id) == tonumber(selected.toZone) then valid = true; break end
    end
    if not valid then
        S.SafeChat("收藏路线当前不可用：" .. self:ZoneName(selected.fromZone) .. " → " .. self:ZoneName(selected.toZone))
        return false
    end
    return self:SelectTo(selected.toZone)
end

function T:NormalizeSellableZones(zones)
    local normalized, seen = {}, {}
    if type(zones) ~= "table" then return normalized end
    for key, value in pairs(zones) do
        local id, name
        if type(value) == "table" then
            id = tonumber(value.id or value.zoneGroupId or value.zoneGroup or value.zoneGroupType or value[1])
            name = value.zoneGroupName or value.name or value[2]
        elseif type(value) == "number" then
            id = tonumber(value)
        elseif type(value) == "string" then
            -- Covers { [zoneId] = "localized name" } and string numeric IDs.
            id = tonumber(value) or tonumber(key)
            if tonumber(value) == nil then name = value end
        elseif value == true then
            id = tonumber(key)
        end
        if id ~= nil then AddUnique(normalized, seen, id, name or self:ZoneName(id), nil) end
    end
    for _, zone in ipairs(normalized) do self:DecorateZone(zone) end
    self:SortZones(normalized)
    return normalized
end

function T:RefreshZones()
    local ok, zones = S.Api:CallCapability("X2Store:GetProductionZoneGroups", X2Store, "GetProductionZoneGroups")
    local normalized = ok and self:NormalizeProductionZones(zones) or {}
    S.State.data.trade.zones = normalized

    local selected = tonumber(S.State.life.trade.fromZone)
    local found = false
    for _, zone in ipairs(normalized) do
        if zone.id == selected then found = true; break end
    end
    if not found then
        S.State.life.trade.fromZone = nil
        S.State.life.trade.toZone = nil
        S.State.life.trade.routeConfirmed = false
    end
    self:RefreshSellable()
    S.State:MarkDirty("trade")
end

function T:RefreshSellable()
    local from = tonumber(S.State.life.trade.fromZone)
    if from == nil then
        S.State.data.trade.sellableZones = {}
        S.State.data.trade.sellableFallback = false
        S.State.data.trade.status = "idle"
        S.State.data.trade.error = nil
        S.State.data.trade.route = "请选择出发地和目的地"
        S.State.data.trade.rows = {}
        S.State.life.trade.toZone = nil
        S.State.life.trade.routeConfirmed = false
        S.State:MarkDirty("trade")
        return
    end

    local ok, zones = S.Api:CallCapability("X2Store:GetSellableZoneGroups", X2Store, "GetSellableZoneGroups", from)
    local normalized = ok and self:NormalizeSellableZones(zones) or {}
    local fallback = false

    -- A few RU addon implementations have observed different Lua shapes for
    -- GetSellableZoneGroups.  If the official call yields no usable entries,
    -- keep the UI operable by presenting the official production-zone list.
    -- IDs are therefore still game-provided; the server's ratio request remains
    -- the final Authority for whether a selected pair is actually sellable.
    if #normalized == 0 then
        fallback = true
        local seen = {}
        for _, zone in ipairs(S.State.data.trade.zones or {}) do
            if zone.id ~= from then AddUnique(normalized, seen, zone.id, zone.name, zone.continent) end
        end
        for _, zone in ipairs(normalized) do self:DecorateZone(zone) end
        self:SortZones(normalized)
    end

    S.State.data.trade.sellableZones = normalized
    S.State.data.trade.sellableFallback = fallback

    local current = tonumber(S.State.life.trade.toZone)
    local found = false
    for _, zone in ipairs(normalized) do
        if zone.id == current then found = true; break end
    end
    if not found then
        S.State.life.trade.toZone = nil
        S.State.life.trade.routeConfirmed = false
        S.State.data.trade.rows = {}
        S.State.data.trade.status = "idle"
        S.State.data.trade.error = nil
        S.State.data.trade.route = self:ZoneName(from) .. " → 请选择目的地"
    end
    S.State:MarkDirty("trade")
end

function T:SelectFrom(zoneId)
    zoneId = tonumber(zoneId)
    if zoneId == nil then return false end
    S.State.life.trade.fromZone = zoneId
    -- Selecting a new origin invalidates the old destination by design.  This
    -- prevents an implicit query and makes both dropdown choices explicit.
    S.State.life.trade.toZone = nil
    S.State.life.trade.routeConfirmed = false
    self.pending = false
    self:RefreshSellable()
    S.Storage:RequestSave()
    return true
end

function T:SelectTo(zoneId)
    zoneId = tonumber(zoneId)
    if zoneId == nil or tonumber(S.State.life.trade.fromZone) == nil then return false end
    local valid = false
    for _, zone in ipairs(S.State.data.trade.sellableZones or {}) do
        if zone.id == zoneId then valid = true; break end
    end
    if not valid then return false end
    S.State.life.trade.toZone = zoneId
    S.State.life.trade.routeConfirmed = true
    S.State.data.trade.route = self:ZoneName(S.State.life.trade.fromZone) .. " → " .. self:ZoneName(zoneId)
    S.Storage:RequestSave()
    return self:Request(true)
end

function T:GetCommerceSkill()
    local ok, infos = S.Api:CallCapability("X2Ability:GetAllMyActabilityInfos", X2Ability, "GetAllMyActabilityInfos")
    if not ok or type(infos) ~= "table" then return 0 end
    for _, info in pairs(infos) do
        if type(info) == "table" and (info.name == "Commerce" or info.name == "经商" or info.name == "Торговля") then
            return (tonumber(info.point) or 0) + (tonumber(info.modifyPoint) or 0)
        end
    end
    return 0
end

-- Fermented larder packs (奶酪 / 药材 / 蜂蜜) are reported by the server under
-- several naming schemes — a [zone] bracket prefix, and 保存发酵 / 基本发酵 /
-- 加工发酵 / 天然发酵 fermentation prefixes — but the static payout table stores
-- exactly one canonical key per origin zone + commodity.  Detect the commodity
-- and the origin zone from the item name, then probe every known fermentation
-- prefix.  The probe only "wins" when a real price key exists, so it can never
-- cross zones or match a non-larder pack.
local LARDER_FERMENT_PREFIXES = { "基本发酵", "保存发酵", "加工发酵", "天然发酵", "无添加发酵", "无添加", "发酵" }
local LARDER_COMMODITY_TOKENS = {
    { cn = "奶酪", en = "cheese" },
    { cn = "药材", en = "salve" },
    { cn = "蜂蜜", en = "honey" },
}

local function DetectLarderCommodity(exact)
    local low = string.lower(exact)
    for _, tok in ipairs(LARDER_COMMODITY_TOKENS) do
        if string.find(exact, tok.cn, 1, true) ~= nil or string.find(low, tok.en, 1, true) ~= nil then
            return tok.cn
        end
    end
    return nil
end

-- Known larder origin zones.  Used as a substring fallback when the item name
-- carries the origin zone somewhere other than the [zone] bracket or the slot
-- immediately before the fermentation prefix (e.g. "地狱沼泽的保存发酵奶酪" or
-- "保存发酵奶酪(地狱沼泽)").  This generalizes the old Hellswamp-only
-- string.find(exact,"地狱沼泽") match to every zone.  The list is also re-derived
-- from the live payout table below, so it stays correct if zones are added.
local LARDER_FALLBACK_ZONES = {
    "珊瑚海岸", "地狱沼泽", "黄金平原", "棋盘石林", "洛卡山脉",
    "草原之脉", "哈里洛废墟", "翡翠谷", "西风脊", "古代森林",
    "双冠丘陵", "中央大陆", "黎利尔丘陵", "碎石平原", "玛瑞诺普",
}
local LARDER_ORIGIN_ZONES = nil
local function GetLarderOriginZones()
    if LARDER_ORIGIN_ZONES ~= nil then return LARDER_ORIGIN_ZONES end
    local zones = {}
    for _, z in ipairs(LARDER_FALLBACK_ZONES) do zones[z] = true end
    local prices = S.Data and S.Data.TradePrices
    if type(prices) == "table" then
        local pat = "^(.-)(" .. table.concat(LARDER_FERMENT_PREFIXES, "|") .. ")(奶酪|药材|蜂蜜)$"
        for _, zoneTable in pairs(prices) do
            if type(zoneTable) == "table" then
                for key, _ in pairs(zoneTable) do
                    local origin = string.match(tostring(key), pat)
                    if origin and origin ~= "" then zones[origin] = true end
                end
            end
        end
    end
    LARDER_ORIGIN_ZONES = zones
    return zones
end

local function ResolveLarderPriceKey(tableForZone, exact, originZoneName)
    if type(tableForZone) ~= "table" or type(exact) ~= "string" or exact == "" then return nil end
    local commodity = DetectLarderCommodity(exact)
    if commodity == nil then return nil end

    -- Authoritative path: every trade row's pack originates from the selected
    -- departure zone (request.from).  When that zone name is known, probe every
    -- fermentation prefix directly.  This is immune to how the server formats the
    -- item name — missing zone, a bracketed shorthand like [黎利尔], an odd
    -- fermentation word (无添加 / 无添加发酵), etc. — because we already know
    -- the correct origin.
    if type(originZoneName) == "string" and originZoneName ~= "" then
        for _, prefix in ipairs(LARDER_FERMENT_PREFIXES) do
            local key = originZoneName .. prefix .. commodity
            if tableForZone[key] ~= nil then return key end
        end
    end

    -- Fallback: derive the origin zone from the item name itself.
    local zones, seen = {}, {}
    local function push(z)
        if z and z ~= "" and not seen[z] then seen[z] = true; zones[#zones + 1] = z end
    end

    local bracket = string.match(exact, "^%[(.-)%]")
    push(bracket)
    local hints = {}
    if bracket and bracket ~= "" then hints[bracket] = true end
    for _, prefix in ipairs(LARDER_FERMENT_PREFIXES) do
        local z = string.match(exact, "^(.-)(" .. prefix .. ")" .. commodity .. "$")
        if z and z ~= "" then push(z); hints[z] = true end
    end
    -- Bidirectional substring: a known origin zone that equals, contains, or is
    -- contained in a zone hint pulled from the name.  Lets "[黎利尔]无添加奶酪"
    -- resolve to the 黎利尔丘陵 key even though the bracket says just 黎利尔.
    for origin, _ in pairs(GetLarderOriginZones()) do
        if string.find(exact, origin, 1, true) then
            push(origin)
        else
            for h, _ in pairs(hints) do
                if string.find(origin, h, 1, true) then push(origin); break end
            end
        end
    end

    for _, zone in ipairs(zones) do
        for _, prefix in ipairs(LARDER_FERMENT_PREFIXES) do
            local key = zone .. prefix .. commodity
            if tableForZone[key] ~= nil then return key end
        end
    end
    return nil
end

local function ResolveStaticTradePriceKey(tableForZone, itemName, originZoneName)
    if type(tableForZone)~="table" then return nil end
    local exact=tostring(itemName or "")
    if tableForZone[exact]~=nil then return exact end

    -- Keep raw server names and UI aliases separate.  This also repairs installs
    -- that briefly received the v1 data-only rename: all known aliases resolve
    -- back to whichever compatible key exists in the local payout table.
    local candidates=TRADE_PACK_PRICE_KEY_ALIASES[exact]
    if type(candidates)=="table" then
        for _,candidate in ipairs(candidates) do
            if tableForZone[candidate]~=nil then return candidate end
        end
    end

    -- Generic aged-larder resolution.  Replaces the old Hellswamp-only special
    -- case: any zone's 奶酪/药材/蜂蜜 pack (e.g. "[西风脊]保存发酵奶酪",
    -- "地狱沼泽加工发酵蜂蜜") now resolves to its canonical payout key.
    -- originZoneName (the selected departure zone) makes the match authoritative.
    return ResolveLarderPriceKey(tableForZone, exact, originZoneName)
end

function T:EstimatePrice(destination, itemName, ratio, commerceSkill, originZoneName)
    local tableForZone = S.Data.TradePrices and S.Data.TradePrices[tonumber(destination)]
    if type(tableForZone) ~= "table" then return nil end
    local priceKey=ResolveStaticTradePriceKey(tableForZone,itemName,originZoneName)
    local raw = priceKey and tableForZone[priceKey] or nil
    local base = type(raw) == "table" and tonumber(raw[1]) or tonumber(raw)
    if base == nil then return nil end
    local skill = tonumber(commerceSkill)
    if skill == nil then skill = self:GetCommerceSkill() end
    local price = base * (tonumber(ratio) or 0) * (1 + (skill / 10000 * 0.05))
    for _, multiplier in ipairs(S.Data.TradeNameMultipliers or {}) do
        if string.find(itemName, tostring(multiplier.token), 1, true) then
            price = price * (tonumber(multiplier.value) or 1)
            break
        end
    end
    return math.floor(price + 0.5)
end

function T:Request(force)
    if S.Api == nil or type(S.Api.IsCapabilityAllowed) ~= "function"
        or S.Api:IsCapabilityAllowed("X2Store:GetSpecialtyRatioBetween") ~= true then return false end
    local from = tonumber(S.State.life.trade.fromZone)
    local to = tonumber(S.State.life.trade.toZone)
    if from == nil or to == nil then
        S.State.data.trade.status = "idle"
        S.State.data.trade.error = nil
        S.State.data.trade.rows = {}
        S.State.data.trade.route = from and (self:ZoneName(from) .. " → 请选择目的地") or "请选择出发地和目的地"
        S.State:MarkDirty("trade")
        return false
    end
    S.State.life.trade.routeConfirmed = true
    if self.inFlight ~= nil then self.pending = true; return false end

    self.inFlight = { from = from, to = to, requestedAt = S.NowMs() }
    self.pending = false
    S.State.data.trade.status = "loading"
    S.State.data.trade.error = nil
    S.State.data.trade.route = self:ZoneName(from) .. " → " .. self:ZoneName(to)
    S.State:MarkDirty("trade")

    local ok, err = S.Api:ActionCapability("X2Store:GetSpecialtyRatioBetween", X2Store, "GetSpecialtyRatioBetween", from, to)
    if not ok then
        self.inFlight = nil
        S.State.data.trade.status = "error"
        S.State.data.trade.error = "服务器未接受该路线查询"
        if err ~= nil then S.State.data.trade.debugError = tostring(err) end
        S.State:MarkDirty("trade")
        return false
    end
    return true
end

function T:OnRatio(info)
    local request = self.inFlight
    self.inFlight = nil
    if request == nil then return end

    local desiredFrom = tonumber(S.State.life.trade.fromZone)
    local desiredTo = tonumber(S.State.life.trade.toZone)
    if request.from ~= desiredFrom or request.to ~= desiredTo then
        self.pending = true
    else
        local rows = {}
        local commerceSkill = self:GetCommerceSkill()
        if type(info) == "table" then
            for _, value in pairs(info) do
                if type(value) == "table" and type(value.itemInfo) == "table" then
                    local sourceName = tostring(value.itemInfo.name or "未知特产")
                    local name = ResolveTradePackDisplayName(sourceName)
                    local itemType = ExtractStableItemType(value.itemInfo) or ExtractStableItemType(value)
                    local ratio = tonumber(value.ratio) or 0
                    local price = self:EstimatePrice(request.to, sourceName, ratio, commerceSkill, self:ZoneName(request.from))
                    rows[#rows + 1] = {
                        name = name,
                        sourceName = sourceName,
                        itemType = itemType,
                        packKey = tostring(request.from) .. ":" .. tostring(request.to) .. ":" .. sourceName,
                        ratio = ratio,
                        rate = tostring(math.floor(ratio + 0.5)) .. "%",
                        priceCopper = price,
                        price = price and S.Utils.FormatCompactMoney(price, false) or "--",
                        profit = "--",
                        tone = ratio >= 125 and "green" or (ratio >= 115 and "yellow" or "red"),
                    }
                end
            end
        end
        -- Deterministic, stable sort.  The server returns the pack list via an
        -- unordered pairs() walk and the rounded % rate collapses many rows onto
        -- the same value, so a plain table.sort (which is NOT stable in Lua)
        -- reshuffles equal-rate rows on every refresh.  Tie-break on the unique
        -- packKey (from:to:sourceName) so the row order is fixed for a given
        -- route and never visually jumps between auto-refreshes.
        local function HasBracketPrefix(name)
            return string.sub(tostring(name or ""), 1, 1) == "["
        end
        local sortMode = S.State.settings.tradeSortMode
        local function Primary(row)
            local v = (sortMode == "price") and row.priceCopper or row.ratio
            -- Missing payouts (nil) must sort consistently to the bottom instead
            -- of flipping position between refreshes; NaN guards are cheap.
            if v == nil or v ~= v then return -1 end
            return v
        end
        -- Items whose display name carries a [..] origin/type prefix (e.g.
        -- "[西风脊]保存特制特产", "[古代森林]糖醋泡蒜") bubble to the top first,
        -- so special/aged packs stay grouped up top regardless of the chosen
        -- ratio/price sort.  This is the "bring the [..] prefixed rows to the
        -- front" ordering requested by users.
        table.sort(rows, function(a, b)
            local ab, bb = HasBracketPrefix(a.name), HasBracketPrefix(b.name)
            if ab ~= bb then return ab end
            local pa, pb = Primary(a), Primary(b)
            if pa ~= pb then return pa > pb end
            local ka, kb = tostring(a.packKey or a.name or ""), tostring(b.packKey or b.name or "")
            if ka ~= kb then return ka < kb end
            return tostring(a.sourceName or "") < tostring(b.sourceName or "")
        end)
        S.State.data.trade.rows = rows
        local previousSelected=S.State.data.trade.selectedPack
        if type(previousSelected)=="table" then
            local matched=nil
            for _,row in ipairs(rows) do if tostring(row.name)==tostring(previousSelected.name) then matched=row; break end end
            if matched~=nil then
                -- Re-resolve materials against the current origin and discard old
                -- payout/cost math so stale route data never survives a refresh.
                self:SelectPack(matched,false)
            else
                S.State.data.trade.selectedPack=nil
            end
        end
        S.State.data.trade.updatedAt = S.NowMs()
        S.State.data.trade.route = self:ZoneName(request.from) .. " → " .. self:ZoneName(request.to)
        if #rows > 0 then
            S.State.data.trade.status = "ready"
            S.State.data.trade.error = nil
        else
            S.State.data.trade.status = "error"
            S.State.data.trade.error = "服务器返回的货率列表为空"
        end
        S.State:MarkDirty("trade")
    end

    if self.pending then self.pending = false; self:Request(true) end
end

-- Compatibility helpers retained for any older quick-page button references.
function T:CycleFrom(delta)
    local zones = S.State.data.trade.zones or {}
    if #zones == 0 then return end
    local index = 0
    for i, zone in ipairs(zones) do if zone.id == tonumber(S.State.life.trade.fromZone) then index = i; break end end
    index = ((index + (tonumber(delta) or 1) - 1) % #zones) + 1
    self:SelectFrom(zones[index].id)
end

function T:CycleTo(delta)
    local zones = S.State.data.trade.sellableZones or {}
    if #zones == 0 then return end
    local index = 0
    for i, zone in ipairs(zones) do if zone.id == tonumber(S.State.life.trade.toZone) then index = i; break end end
    index = ((index + (tonumber(delta) or 1) - 1) % #zones) + 1
    self:SelectTo(zones[index].id)
end

function T:Tick()
    if self.inFlight ~= nil and S.NowMs() - (self.inFlight.requestedAt or 0) >= S.Constants.Refresh.tradeTimeoutMs then
        self.inFlight = nil
        S.State.data.trade.status = "error"
        S.State.data.trade.error = "货率查询超时，请手动刷新重试"
        S.State:MarkDirty("trade")
        if self.pending then self.pending = false; self:Request(true) end
    end
end

function T:Start()
    self:RefreshZones()
    S.Events:Subscribe("SPECIALTY_RATIO_BETWEEN_INFO", self, function(_, info) T:OnRatio(info) end)
    S.Events:Subscribe("CHAT_MESSAGE", self, function(_, channel, relation, name, message) T:HandleChatMessage(channel, relation, name, message) end)
    S.Events:Subscribe("ENTERED_WORLD", self, function()
        T:RefreshZones()
        if S.State.life.trade.routeConfirmed == true then T:Request(false) end
    end)
    S.Scheduler:AddTask("trade_timeout", 500, function() T:Tick() end, false, self, "P2")
    S.Scheduler:AddTask("trade_auto", S.Constants.Refresh.tradeAutoMs, function()
        if S.State.settings.tradeAutoRefresh and S.State.life.trade.routeConfirmed == true then T:Request(false) end
    end, false, self, "P5")
    if S.State.life.trade.routeConfirmed == true then self:Request(false) end
    -- P1-3: the craft-station material assist rides the trade module lifecycle
    -- (no new top-level module switch). Its own Start/Stop manage the watcher
    -- task, event subscription and window; disabling trade stops it too.
    local craft = S.Services and S.Services.CraftAssist
    if craft ~= nil then
        if S.Events ~= nil and type(S.Events.BindOwner) == "function" then S.Events:BindOwner(craft, "trade") end
        if type(craft.Start) == "function" then craft:Start() end
    end
end

function T:Stop()
    local craft = S.Services and S.Services.CraftAssist
    if craft ~= nil and type(craft.Stop) == "function" then craft:Stop() end
end
