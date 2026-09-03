------------------------------------------------------------------------
-- Replicated Suite - Character Information Authority
-- Author: Replicated
--
-- Uses only RU-whitelisted Equipment / Achievement / Unit reads. This absorbs
-- the proven checks from the user's previous InfoTracker without inheriting
-- its independent window/timer architecture.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
S.Services = S.Services or {}
S.Services.Character = {}
local C = S.Services.Character

local STATUE_BUFF_IDS = {
    [30766]=true,[30767]=true,[30768]=true,[30771]=true,[30773]=true,
    [9002338]=true,[9002340]=true,[9002342]=true,[9002337]=true,[9002339]=true,
    [902341]=true,[30760]=true,[30764]=true,[30765]=true,[30770]=true,[30772]=true,
}

local function Slot(primary, fallback)
    -- The original InfoTracker used ES_COSPLAY / ES_UNDERPANTS /
    -- ES_RACE_COSPLAY directly in the real RU client.  Prefer those proven
    -- constants; EST_* is only a compatibility fallback for alternate dumps.
    return rawget(_G, primary) or rawget(_G, fallback)
end

local function Remaining(info)
    if type(info) ~= "table" or next(info) == nil then return "未装备", "muted" end
    local evolving = info.evolvingInfo
    local remain = type(evolving) == "table" and evolving.remainTime or nil
    if type(remain) ~= "table" then return "有效 / 永久", "green" end
    local year = tonumber(remain.year) or 0; local month = tonumber(remain.month) or 0
    local day = tonumber(remain.day) or 0; local hour = tonumber(remain.hour) or 0
    local minute = tonumber(remain.minute) or 0; local second = tonumber(remain.second) or 0
    if year == 0 and month == 0 and day == 0 and hour == 0 and minute == 0 and second == 0 then return "已过期", "red" end
    local parts = {}
    if year > 0 then parts[#parts+1] = tostring(year).."年" end
    if month > 0 then parts[#parts+1] = tostring(month).."月" end
    if day > 0 then parts[#parts+1] = tostring(day).."天" end
    if #parts < 2 and hour > 0 then parts[#parts+1] = tostring(hour).."小时" end
    if #parts < 2 and minute > 0 then parts[#parts+1] = tostring(minute).."分" end
    return "剩余 " .. (#parts > 0 and table.concat(parts, " ") or "有效"), "green"
end

function C:EquipmentStatus(slotName, legacy)
    local slot = Slot(slotName, legacy)
    if slot == nil or S.Api == nil or type(S.Api.IsCapabilityAllowed) ~= "function"
        or S.Api:IsCapabilityAllowed("X2Equipment:GetEquippedItemTooltipInfo") ~= true then return "--", "muted" end
    local ok, info = S.Api:CallCapability("X2Equipment:GetEquippedItemTooltipInfo", X2Equipment, "GetEquippedItemTooltipInfo", slot, false)
    if not ok then return "--", "muted" end
    return Remaining(info)
end

function C:AssignmentStatus(kind)
    if kind == nil or S.Api == nil or type(S.Api.IsCapabilityAllowed) ~= "function"
        or S.Api:IsCapabilityAllowed("X2Achievement:GetTodayAssignmentInfo") ~= true then return "--", "muted" end
    local locked, active, completed, total = 0, 0, 0, 0
    for i=1,7 do
        local ok, info = S.Api:CallCapability("X2Achievement:GetTodayAssignmentInfo", X2Achievement, "GetTodayAssignmentInfo", kind, i)
        if ok and type(info)=="table" then
            local st = tonumber(info.status)
            if st ~= nil then
                total = total + 1
                if st == 1 then locked = locked + 1 elseif st == 2 then active = active + 1 elseif st == 3 then completed = completed + 1 end
            end
        end
    end
    if total == 0 then return "--", "muted" end
    if completed == total then return "已完成 "..completed.."/"..total, "green" end
    if active > 0 or completed > 0 then return "已接 "..tostring(active+completed).."/"..total, "yellow" end
    return "未接", "orange"
end

function C:StatueBuffStatus()
    if S.Api == nil or type(S.Api.IsCapabilityAllowed) ~= "function"
        or S.Api:IsCapabilityAllowed("X2Unit:UnitBuffCount") ~= true
        or S.Api:IsCapabilityAllowed("X2Unit:UnitBuff") ~= true then return "--", "muted" end
    local ok, count = S.Api:CallCapability("X2Unit:UnitBuffCount", X2Unit, "UnitBuffCount", "player")
    if not ok then return "--", "muted" end
    for i=1,(tonumber(count) or 0) do
        local okBuff, info = S.Api:CallCapability("X2Unit:UnitBuff", X2Unit, "UnitBuff", "player", i)
        if okBuff and type(info)=="table" and STATUE_BUFF_IDS[tonumber(info.buff_id)] then return "已获得", "green" end
    end
    return "未获得", "orange"
end

function C:Refresh()
    local underwear, underwearTone = self:EquipmentStatus("ES_UNDERPANTS", "EST_UNDERPANTS")
    local costume, costumeTone = self:EquipmentStatus("ES_COSPLAY", "EST_COSPLAY")
    local daru, daruTone = self:EquipmentStatus("ES_RACE_COSPLAY", "EST_RACE_COSPLAY")
    local daily, dailyTone = self:AssignmentStatus(rawget(_G, "TADT_TODAY"))
    local guild, guildTone = self:AssignmentStatus(rawget(_G, "TADT_EXPEDITION"))
    local statue, statueTone = self:StatueBuffStatus()
    S.State.data.character = {
        { name="内衣", status=underwear, tone=underwearTone },
        { name="时装", status=costume, tone=costumeTone },
        { name="每日任务", status=daily, tone=dailyTone },
        { name="公会任务", status=guild, tone=guildTone },
        { name="多鲁时装", status=daru, tone=daruTone },
        { name="国王雕像 Buff", status=statue, tone=statueTone },
    }
    S.State:MarkDirty("character")
end

function C:RequestRefresh(delayMs)
    S.Scheduler:AddTask("character_debounce", math.max(100, tonumber(delayMs) or 300), function()
        S.Scheduler:RemoveTask("character_debounce"); C:Refresh()
    end, true, self, "P2")
end

function C:Start()
    for _,eventName in ipairs({"UNIT_EQUIPMENT_CHANGED","BUFF_UPDATE","ACHIEVEMENT_UPDATE","COMPLETE_ACHIEVEMENT","ENTERED_WORLD"}) do
        S.Events:Subscribe(eventName, self, function() C:RequestRefresh(300) end)
    end
    S.Scheduler:AddTask("character_safety", math.max(10000, tonumber(S.State.settings.dataRefreshMs) or 15000), function() C:Refresh() end, false, self, "P3")
    self:Refresh()
end
