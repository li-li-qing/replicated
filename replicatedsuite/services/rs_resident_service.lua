------------------------------------------------------------------------
-- Replicated Suite - Resident Board / Blue Salt Bond Authority
-- Author: Replicated
--
-- Board contents are fixed for the day. Each continent is captured at most
-- once per server date; quest completion and bag material counts remain live.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S=ReplicatedSuite; S.Services=S.Services or {}; S.Services.Resident={}
local R=S.Services.Resident
R.presentationBoundary = "service_only"
R.presentationDebt = nil

local BOARD_NAMES={"布料","皮革","木材","铁锭","王子物资","女王物资","祖先物资"}
local BOARD_MATERIAL_KEY={ [1]="fabric", [2]="leather", [3]="lumber", [4]="iron" }
-- Bond display ordering is quantity-first.  For rows with the same requested
-- quantity, keep the user-facing material order stable as:
-- leather -> fabric -> lumber -> iron.  Unknown/Auroria material types keep
-- their captured order after the four mainland materials.
local BOND_MATERIAL_SORT_RANK={ leather=1, fabric=2, lumber=3, iron=4 }
local CONTINENT_LABEL={ west="西大陆", east="东大陆", auroria="原大陆" }
local BOND_FILTER_KEYS={ q20=true, q60=true, q100=true, auroria=true, excludeSame=true }
local BOND_CATEGORY_FILTER_KEYS={ "q20", "q60", "q100", "auroria" }

local function NormalizeBondFilter(value)
    local result={q20=true,q60=true,q100=true,auroria=true,excludeSame=false,priority="west"}
    if type(value)=="table" then
        for key in pairs(BOND_FILTER_KEYS) do
            if value[key]~=nil then result[key]=value[key]==true end
        end
        local priority=tostring(value.priority or "")
        if priority=="west" or priority=="east" then result.priority=priority end
    end
    return result
end

local function BondEntryFilterKey(entry)
    if type(entry)~="table" then return nil end
    -- Auroria is an independent category even when its parsed line also
    -- contains a number such as 20/60/100.
    if tostring(entry.continentKey or "")=="auroria" then return "auroria" end
    local quantity=tonumber(entry.quantity)
    if quantity==20 then return "q20" end
    if quantity==60 then return "q60" end
    if quantity==100 then return "q100" end
    -- Unknown/new mainland rows stay visible so a parser miss never silently
    -- hides captured resident-board data from the player.
    return nil
end

local CONTINENT_SORT_RANK={ west=1, east=2, auroria=3 }

local function NormalizeSortMode(mode)
    mode=tostring(mode or "continent")
    -- Migrate the previous 3-state quantity sorter:
    -- none = captured continent order, asc/desc = quantity sorting.
    if mode=="asc" or mode=="desc" or mode=="quantity" then return "quantity" end
    return "continent"
end

function R:GetBondSortMode()
    S.State.life.bondSortMode=NormalizeSortMode(S.State.life.bondSortMode)
    return S.State.life.bondSortMode
end

function R:GetBondSortButtonText()
    return "排序"
end

function R:SetBondSortMode(mode)
    local normalized=NormalizeSortMode(mode)
    S.State.life.bondSortMode=normalized
    S.Storage:RequestSave(0)
    S.State:MarkDirty("resident")
    return normalized
end

-- Compatibility for older callers. The title-bar button no longer uses this;
-- it opens a dedicated two-choice sort panel instead.
function R:CycleBondSortMode()
    local current=self:GetBondSortMode()
    return self:SetBondSortMode(current=="continent" and "quantity" or "continent")
end

function R:GetBondFilter()
    local normalized=NormalizeBondFilter(S.State.life.bondFilter)
    S.State.life.bondFilter=normalized
    return normalized
end

function R:SetBondFilterOption(key,enabled)
    key=tostring(key or "")
    if BOND_FILTER_KEYS[key]~=true then return false end
    local filter=self:GetBondFilter()
    filter[key]=enabled==true
    S.State.life.bondFilter=filter
    S.Storage:RequestSave(0)
    S.State:MarkDirty("resident")
    return true
end

function R:ToggleBondFilterOption(key)
    key=tostring(key or "")
    if BOND_FILTER_KEYS[key]~=true then return false end
    local filter=self:GetBondFilter()
    return self:SetBondFilterOption(key,not (filter[key]==true))
end

function R:SetBondDuplicatePriority(priority)
    priority=tostring(priority or "")
    if priority~="west" and priority~="east" then return false end
    local filter=self:GetBondFilter()
    filter.priority=priority
    -- Selecting a preferred continent is an explicit request to use duplicate
    -- suppression, so enable it in the same action. The user can still turn
    -- "相同则排除" off afterwards without losing the remembered preference.
    filter.excludeSame=true
    S.State.life.bondFilter=filter
    S.Storage:RequestSave(0)
    S.State:MarkDirty("resident")
    return true
end

function R:GetBondFilterButtonText()
    local filter=self:GetBondFilter()
    local count=0
    for _,key in ipairs(BOND_CATEGORY_FILTER_KEYS) do
        if filter[key]==true then count=count+1 end
    end
    local base=count==#BOND_CATEGORY_FILTER_KEYS and "筛选" or ("筛选"..tostring(count).."/"..tostring(#BOND_CATEGORY_FILTER_KEYS))
    if filter.excludeSame==true then return base.."·去重" end
    return base
end

local function MainlandDuplicateKey(entry)
    if type(entry)~="table" then return nil end
    local continent=tostring(entry.continentKey or "")
    if continent~="west" and continent~="east" then return nil end
    local materialKey=tostring(entry.materialKey or "")
    local quantity=tonumber(entry.quantity)
    if materialKey=="" or quantity==nil then return nil end
    return materialKey..":"..tostring(quantity)
end

local function RemoveDuplicateMainlandBonds(result,priority)
    priority=(priority=="east") and "east" or "west"
    local other=priority=="west" and "east" or "west"
    local groups={}

    for _,wrapped in ipairs(result) do
        local key=MainlandDuplicateKey(wrapped.entry)
        if key~=nil then
            local continent=tostring(wrapped.entry.continentKey or "")
            local group=groups[key]
            if group==nil then
                group={west={},east={}}
                groups[key]=group
            end
            if continent=="west" or continent=="east" then
                group[continent][#group[continent]+1]=wrapped
            end
        end
    end

    local suppressed={}
    for _,group in pairs(groups) do
        local total=#group.west+#group.east
        if total>1 then
            -- The resident-board rule is global for mainland bond quests: the
            -- same material + quantity can only be turned in once. Therefore
            -- duplicates must also collapse when they occur twice on the SAME
            -- continent (for example two west-side Lumber:20 rows).
            --
            -- Continent priority only decides the winner when the duplicate is
            -- present on both Nuia and Haranya. Within the winning continent we
            -- preserve the first captured board row so the display stays stable.
            local winner=nil
            if #group[priority]>0 then
                winner=group[priority][1]
            elseif #group[other]>0 then
                winner=group[other][1]
            end

            for _,wrapped in ipairs(group.west) do
                if wrapped~=winner then suppressed[wrapped]=true end
            end
            for _,wrapped in ipairs(group.east) do
                if wrapped~=winner then suppressed[wrapped]=true end
            end
        end
    end

    if next(suppressed)==nil then return result end
    local filtered={}
    for _,wrapped in ipairs(result) do
        if suppressed[wrapped]~=true then filtered[#filtered+1]=wrapped end
    end
    return filtered
end

function R:GetDisplayBondEntries(entries)
    local source=type(entries)=="table" and entries or {}
    local filter=self:GetBondFilter()
    local result={}
    for index,entry in ipairs(source) do
        local filterKey=BondEntryFilterKey(entry)
        if filterKey==nil or filter[filterKey]==true then
            result[#result+1]={entry=entry,index=index}
        end
    end

    if filter.excludeSame==true then
        result=RemoveDuplicateMainlandBonds(result,filter.priority)
    end

    local mode=self:GetBondSortMode()
    if mode=="quantity" then
        table.sort(result,function(a,b)
            local ae=a.entry or {}
            local be=b.entry or {}
            local aq=tonumber(ae.quantity)
            local bq=tonumber(be.quantity)
            -- Natural quantity order: 20 -> 60 -> 100. Unknown/new quantities
            -- remain visible and are placed after known rows rather than hidden.
            if aq==nil and bq==nil then return a.index<b.index end
            if aq==nil then return false end
            if bq==nil then return true end
            if aq~=bq then return aq<bq end

            -- Equal quantities stay deterministic: continent first, then the
            -- familiar mainland material order, finally original capture order.
            local ac=CONTINENT_SORT_RANK[tostring(ae.continentKey or "")] or 1000
            local bc=CONTINENT_SORT_RANK[tostring(be.continentKey or "")] or 1000
            if ac~=bc then return ac<bc end
            local ar=BOND_MATERIAL_SORT_RANK[tostring(ae.materialKey or "")] or 1000
            local br=BOND_MATERIAL_SORT_RANK[tostring(be.materialKey or "")] or 1000
            if ar~=br then return ar<br end
            return a.index<b.index
        end)
    else
        -- BuildBondEntries already captures west -> east -> auroria. Keeping the
        -- original index therefore gives a stable continent-grouped view and
        -- preserves each board's native row order inside that continent.
        table.sort(result,function(a,b) return a.index<b.index end)
    end

    local flat={}
    for _,wrapped in ipairs(result) do flat[#flat+1]=wrapped.entry end
    return flat
end

-- ArcheRage resident development stage groups observed in the working activity
-- addon. These are queried only on relevant events plus a low-frequency safety
-- refresh; never from Tick/OnUpdate.
local RESIDENT_STAGE_WATCH = {
    { name="微弱繁荣", zoneIds={54,56,57,102,103} },
    { name="高级灿烂台", zoneIds={2,22,26,27,78,11,14,16} },
    { name="限时船商", zoneIds={3,4,5,6,9,13} },
    { name="限时车商", zoneIds={7,10,21,24} },
    { name="特殊货物", zoneIds={8,15,18,23} },
}

function R:ReadBoard(index)
    local ok,value=S.Api:CallCapability("X2Resident:GetResidentBoardContent", X2Resident, "GetResidentBoardContent",index)
    if not ok or type(value)~="table" then return {contents={},faction=nil} end
    if type(value.contents)~="table" then value.contents={} end
    return value
end

function R:EnsureDailyCache()
    local key=S.Utils.ServerDateKey()
    local cache=S.State.life.bondCache
    -- Cold-window guard (2026-08-24): while the server date is unknown (right
    -- after login/reload) keep the restored cache instead of treating the
    -- unknown key as a new day and discarding the captured boards.
    if key ~= "unknown" and (type(cache)~="table" or tostring(cache.dateKey)~=tostring(key)) then
        -- Mainland bond completion is shared by material + quantity for the
        -- whole server day.  Example: once any Lumber:20 resident quest is
        -- turned in, every other mainland Lumber:20 row is no longer
        -- turn-in eligible and must render as completed as well.
        S.State.life.bondCache={dateKey=key,west=nil,east=nil,auroria=nil,completedMainlandBondKeys={}}
        S.Storage:RequestSave(0)
    elseif type(cache)~="table" then
        cache={dateKey="unknown",west=nil,east=nil,auroria=nil,completedMainlandBondKeys={}}
        S.State.life.bondCache=cache
    elseif type(cache.completedMainlandBondKeys)~="table" then
        -- Schema-compatible upgrade for an already captured cache from an
        -- older addon build.  Keep the captured boards; only add the new
        -- per-day completion authority table.
        cache.completedMainlandBondKeys={}
        S.Storage:RequestSave(0)
    end
    if key ~= "unknown" then S.State.data.bondBoard.dateKey=key end
    return S.State.life.bondCache
end

function R:CurrentContinentKey(boards)
    local auroria=(#(boards[5].contents or {})>0 or #(boards[6].contents or {})>0)
    if auroria then return "auroria" end
    local mainland=(#(boards[3].contents or {})>0 and #(boards[4].contents or {})>0)
    if not mainland then return nil end
    local ok,zoneId=S.Api:CallCapability("X2Unit:GetCurrentZoneGroup", X2Unit, "GetCurrentZoneGroup")
    zoneId=ok and tonumber(zoneId) or nil
    local trade=S.Services and S.Services.Trade
    local key=trade and type(trade.GetContinentKeyByZoneId)=="function" and trade:GetContinentKeyByZoneId(zoneId) or nil
    if key=="west" or key=="east" then return key end
    return nil
end

local function CopyArray(source)
    local out={}; for _,v in ipairs(source or {}) do out[#out+1]=tostring(v) end; return out
end

function R:CaptureContinent(continentKey,boards)
    local cache=self:EnsureDailyCache()
    if continentKey==nil or cache[continentKey]~=nil then return false end
    local startIndex,endIndex=1,4
    if continentKey=="auroria" then startIndex,endIndex=5,7 end
    local rows={}
    for i=startIndex,endIndex do
        rows[#rows+1]={
            boardIndex=i, name=BOARD_NAMES[i] or ("分类"..tostring(i)),
            materialKey=BOARD_MATERIAL_KEY[i], raw=CopyArray(boards[i].contents),
        }
    end
    cache[continentKey]={
        continentKey=continentKey, label=CONTINENT_LABEL[continentKey] or continentKey,
        faction=tostring(boards[1].faction or "--"), capturedDate=cache.dateKey,
        rows=rows,
    }
    S.Storage:RequestSave(150)
    return true
end

local function ResolveQuantityFromMap(text,map)
    if type(map)~="table" then return nil end
    text=tostring(text or "")
    for number in string.gmatch(text,"(%d+)") do
        local n=tonumber(number)
        if n~=nil and map[n]~=nil then return n end
    end
    return nil
end

local function AuroriaToken(text)
    text=tostring(text or "")
    if string.find(text,"金闪闪",1,true)~=nil and string.find(text,"袋",1,true)~=nil then return "golden_bag" end
    if string.find(text,"王子",1,true)~=nil and (string.find(text,"杂货箱",1,true)~=nil or string.find(text,"杂物箱",1,true)~=nil) then return "prince_box" end
    if string.find(text,"女王",1,true)~=nil and string.find(text,"袋",1,true)~=nil then return "queen_bag" end
    if string.find(text,"女王",1,true)~=nil and (string.find(text,"杂货箱",1,true)~=nil or string.find(text,"杂物箱",1,true)~=nil) then return "queen_box" end
    if string.find(text,"继承者",1,true)~=nil and string.find(text,"袋",1,true)~=nil then return "heir_bag" end
    if string.find(text,"继承者",1,true)~=nil and (string.find(text,"杂货箱",1,true)~=nil or string.find(text,"杂物箱",1,true)~=nil) then return "heir_box" end
    return nil
end

function R:IsQuestCompletedById(qid)
    if qid==nil then return nil end
    local quest=S.Services and S.Services.Quest
    return quest and type(quest.IsQuestCompleted)=="function" and quest:IsQuestCompleted(qid)==true or false
end

function R:ResolveBondQuest(row,line)
    -- Nuia/Haranya mainland boards are keyed by material type and quantity.
    local materialMap=S.Constants.BondQuestByMaterialQuantity
        and row and row.materialKey
        and S.Constants.BondQuestByMaterialQuantity[row.materialKey]
    if type(materialMap)=="table" then
        local quantity=ResolveQuantityFromMap(line,materialMap)
        local qid=quantity and materialMap[quantity] or nil
        return qid,quantity,nil
    end

    -- Auroria boards use region-supply item names rather than the four base materials.
    local token=AuroriaToken(line)
    local auroriaMap=token and S.Constants.AuroriaBondQuestByTokenQuantity
        and S.Constants.AuroriaBondQuestByTokenQuantity[token] or nil
    local quantity=ResolveQuantityFromMap(line,auroriaMap)
    local qid=quantity and auroriaMap and auroriaMap[quantity] or nil
    return qid,quantity,token
end

function R:BuildBondEntries()
    local cache=self:EnsureDailyCache()
    local entries={}
    local completedKeys=cache.completedMainlandBondKeys
    local completionChanged=false

    -- Pass 1: read the live quest completion state.  A positive completion is
    -- latched by the logical mainland bond key (material + quantity), not by
    -- zone/board/quest row.  This matches the in-game turn-in rule: the same
    -- material and amount can only be submitted once per day across regions.
    for _,continentKey in ipairs({"west","east","auroria"}) do
        local continent=cache[continentKey]
        if type(continent)=="table" then
            for _,row in ipairs(continent.rows or {}) do
                if #(row.raw or {})==0 then
                    entries[#entries+1]={continentKey=continentKey,continentLabel=continent.label,material=row.name,text="暂无内容",status="--",tone="muted"}
                else
                    for _,line in ipairs(row.raw or {}) do
                        local qid,quantity,auroriaToken=self:ResolveBondQuest(row,line)
                        local done=qid~=nil and self:IsQuestCompletedById(qid) or nil
                        local entry={
                            continentKey=continentKey,continentLabel=continent.label,material=row.name,
                            materialKey=row.materialKey,auroriaToken=auroriaToken,quantity=quantity,text=tostring(line),
                            questId=qid,completed=done,status="?",tone="muted",
                        }

                        local sharedKey=MainlandDuplicateKey(entry)
                        if sharedKey~=nil and done==true and completedKeys[sharedKey]~=true then
                            completedKeys[sharedKey]=true
                            completionChanged=true
                        end
                        entries[#entries+1]=entry
                    end
                end
            end
        end
    end

    -- Pass 2: project the daily shared completion authority back onto every
    -- matching mainland row.  This is deliberately independent from the
    -- display de-duplication option: even when the user chooses to show all
    -- duplicate rows, every Lumber:20 row must show completed after any one
    -- Lumber:20 turn-in succeeds.
    for _,entry in ipairs(entries) do
        local sharedKey=MainlandDuplicateKey(entry)
        if sharedKey~=nil and completedKeys[sharedKey]==true then
            entry.completed=true
        end
        if entry.questId~=nil then
            entry.status=entry.completed==true and "已" or "未"
            entry.tone=entry.completed==true and "green" or "red"
        end
    end

    if completionChanged then S.Storage:RequestSave(150) end
    return entries
end

function R:PublishState(currentKey,boards,errorText)
    local cache=self:EnsureDailyCache()
    local continents={west=cache.west,east=cache.east,auroria=cache.auroria}
    S.State.data.bondBoard={
        dateKey=cache.dateKey,currentContinent=currentKey,continents=continents,
        materials=(S.State.data.bondBoard and S.State.data.bondBoard.materials) or {},
        entries=self:BuildBondEntries(),error=errorText,
    }
    local rows={}; local current=currentKey and cache[currentKey] or nil
    if current~=nil then
        for _,row in ipairs(current.rows or {}) do
            local preview="--"; if #(row.raw or {})>0 then preview=tostring(row.raw[1]); if #row.raw>1 then preview=preview.."  +"..tostring(#row.raw-1) end end
            rows[#rows+1]={name=row.name,status=preview,tone=#(row.raw or {})>0 and "blue" or "muted",raw=row.raw}
        end
    end
    S.State.data.resident={
        status=current~=nil and "ready" or "unavailable",
        faction=tostring((current and current.faction) or (boards and boards[1] and boards[1].faction) or "--"),
        location=currentKey or "unknown",continentKey=currentKey,rows=rows,error=errorText,
    }
    S.State:MarkDirty("resident")
end

function R:RefreshCompletion()
    self:PublishState((S.State.data.bondBoard or {}).currentContinent,nil,nil)
end

function R:RefreshStages()
    local rows = {}
    if S.Api == nil or type(S.Api.IsCapabilityAllowed) ~= "function"
        or S.Api:IsCapabilityAllowed("X2Map:GetZoneStateInfoByZoneId") ~= true then
        S.State.data.residentStages = rows
        S.State:MarkDirty("resident")
        return false
    end
    for _, definition in ipairs(RESIDENT_STAGE_WATCH) do
        local foundName, foundId = nil, nil
        for _, zoneId in ipairs(definition.zoneIds or {}) do
            local ok, info = S.Api:CallCapability("X2Map:GetZoneStateInfoByZoneId", X2Map, "GetZoneStateInfoByZoneId", zoneId)
            if ok and type(info) == "table" and tonumber(info.localDevelopmentStep) == 3 then
                foundName = tostring(info.zoneName or info.name or ("区域 " .. tostring(zoneId)))
                foundId = tonumber(zoneId)
                break
            end
        end
        rows[#rows + 1] = {
            name = tostring(definition.name),
            status = foundName or "暂无3阶段",
            tone = foundName ~= nil and "green" or "muted",
            zoneId = foundId,
        }
    end
    S.State.data.residentStages = rows
    S.State:MarkDirty("resident")
    return true
end

function R:Refresh()
    if X2Resident==nil then self:PublishState(nil,nil,"X2Resident unavailable"); return end
    local boards={}; for i=1,7 do boards[i]=self:ReadBoard(i) end
    local currentKey=self:CurrentContinentKey(boards)
    if currentKey~=nil then self:CaptureContinent(currentKey,boards) end
    self:PublishState(currentKey,boards,currentKey==nil and "当前位置暂时无法判定债券大陆；进入西/东大陆居民区或原大陆后会自动记录一次。" or nil)
end

function R:PrintFull()
    local board=S.State.data.bondBoard or {}; local entries=board.entries or {}
    if #entries==0 then S.SafeChat("今天尚未记录任何大陆的债券信息。进入对应大陆可读取居民板的区域后会自动加入。") end
    S.SafeChat("----- 今日居民 / 债券信息 -----")
    for _,entry in ipairs(entries) do
        S.SafeChat("["..tostring(entry.continentLabel).."] "..tostring(entry.material).." · "..tostring(entry.text).."  "..tostring(entry.status or ""))
    end
    for _, stage in ipairs(S.State.data.residentStages or {}) do
        S.SafeChat("[三阶段] " .. tostring(stage.name) .. " · " .. tostring(stage.status))
    end
    S.SafeChat("-------------------------------")
end

function R:Start()
    S.Events:Subscribe("ENTERED_WORLD",self,function() R:Refresh(); R:RefreshStages() end)
    S.Events:Subscribe("RESIDENT_ZONE_STATE_CHANGE",self,function() R:Refresh(); R:RefreshStages() end)
    S.Events:Subscribe("ENTER_ANOTHER_ZONEGROUP",self,function() R:Refresh(); R:RefreshStages() end)
    S.Scheduler:AddTask("resident_safety",S.Constants.Refresh.residentSafetyMs,function() R:Refresh() end,false,self,"P3")
    S.Scheduler:AddTask("resident_stage_safety",S.Constants.Refresh.residentStageSafetyMs or 60000,function() R:RefreshStages() end,false,self,"P3")
    self:Refresh()
    self:RefreshStages()
end
