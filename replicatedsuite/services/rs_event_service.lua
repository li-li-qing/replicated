------------------------------------------------------------------------
-- Replicated Suite - RU Event Timer Authority
-- Author: Replicated
--
-- Static schedule time is anchored once to the server clock and then advanced
-- by the Suite monotonic clock.  This avoids a RU-client quirk where repeated
-- GetServerTimeTable() reads can remain unchanged inside addon execution.
-- Live zone-state display covers Cinderstone/Ynystere/Whalesong/Aegis, while
-- Garden of the Gods uses the same server Authority for its dedicated Boss row.
-- The client conflict cycle is translated as Danger 1-5 / Conflict / War / Peace.
-- The user's working timeUntil addon confirms GetZoneStateInfoByZoneId()
-- returns remainTime (seconds) for Conflict / War / Peace. Use that live value
-- directly instead of manufacturing timers from observation time.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S=ReplicatedSuite; S.Services=S.Services or {}; S.Services.Event={dynamic={},zoneStates={},zoneRemainSeconds={},zoneRemainObservedAt={},clockAnchor=nil,fallbackNowMs=0,lastVisibleSuiteNowMs=nil,reminderSeen={},reminderDateKey=nil,warReminderOccurrence={}}
local E=S.Services.Event
E.presentationBoundary = "service_only"
E.presentationDebt = nil

local WEEK_SECONDS=7*24*60*60
local function HasDay(days,day) for _,v in ipairs(days or {}) do if tonumber(v)==day then return true end end return false end

-- X2Dominion exposes these state constants in the client, but Replicated Suite
-- does not require the Dominion API just to read X2Map zone state.  Resolve the
-- global constants when present and fall back to the stable client enum order.
local ZONE_STATE = {
    TROUBLE_0 = tonumber(rawget(_G,"HPWS_TROUBLE_0")) or 0,
    TROUBLE_1 = tonumber(rawget(_G,"HPWS_TROUBLE_1")) or 1,
    TROUBLE_2 = tonumber(rawget(_G,"HPWS_TROUBLE_2")) or 2,
    TROUBLE_3 = tonumber(rawget(_G,"HPWS_TROUBLE_3")) or 3,
    TROUBLE_4 = tonumber(rawget(_G,"HPWS_TROUBLE_4")) or 4,
    BATTLE    = tonumber(rawget(_G,"HPWS_BATTLE")) or 5,
    WAR       = tonumber(rawget(_G,"HPWS_WAR")) or 6,
    PEACE     = tonumber(rawget(_G,"HPWS_PEACE")) or 7,
}

local ZONE_STATE_VIEW = {
    -- Danger 1~5 has no authoritative remainTime on this client. These rows
    -- deliberately sort behind every activity/phase that has a real timer.
    [ZONE_STATE.TROUBLE_0] = { text="危险1阶段", tone="blue", danger=true },
    [ZONE_STATE.TROUBLE_1] = { text="危险2阶段", tone="blue", danger=true },
    [ZONE_STATE.TROUBLE_2] = { text="危险3阶段", tone="yellow", danger=true },
    [ZONE_STATE.TROUBLE_3] = { text="危险4阶段", tone="orange", danger=true },
    [ZONE_STATE.TROUBLE_4] = { text="危险5阶段", tone="orange", danger=true },
    [ZONE_STATE.BATTLE]    = { text="纷争", tone="orange", timed=true },
    [ZONE_STATE.WAR]       = { text="战争", tone="red", timed=true },
    [ZONE_STATE.PEACE]     = { text="和平", tone="green", timed=true },
}

local function IsConflictStage(state)
    return tonumber(state)==ZONE_STATE.BATTLE
end

local function NormalizeElapsedMs(dt)
    local elapsed=tonumber(dt) or 0
    if elapsed~=elapsed or elapsed==math.huge or elapsed==-math.huge or elapsed<0 then return 0 end
    if elapsed>0 and elapsed<1 then elapsed=elapsed*1000 end
    return math.min(elapsed,1000)
end

function E:NowMs()
    return math.max(tonumber(self.fallbackNowMs) or 0,S.NowMs())
end

-- Visible event-window OnUpdate is a narrow fallback for client builds where
-- the shared scheduler temporarily stops while this floating window is open.
-- It advances only this service's local clock and never mutates Suite Clock, so
-- the normal scheduler and this fallback cannot double-advance global time.
function E:AdvanceVisibleClock(dt)
    local elapsed=NormalizeElapsedMs(dt)
    if elapsed<=0 then return 0,false end

    local suiteNow=tonumber(S.NowMs()) or 0
    local previousSuiteNow=tonumber(self.lastVisibleSuiteNowMs)
    local schedulerProgressed=previousSuiteNow~=nil and suiteNow>previousSuiteNow
    self.lastVisibleSuiteNowMs=suiteNow

    if schedulerProgressed then
        -- The shared scheduler is healthy. Follow its monotonic Authority instead
        -- of independently adding dt, otherwise the visible-window fallback can
        -- drift ahead and effectively become a second clock.
        self.fallbackNowMs=math.max(tonumber(self.fallbackNowMs) or 0,suiteNow)
    else
        -- Shared OnUpdate did not advance between two visible-window frames. Only
        -- then may this local fallback advance the Event service clock.
        self.fallbackNowMs=math.max(tonumber(self.fallbackNowMs) or 0,suiteNow)+elapsed
    end
    return elapsed,schedulerProgressed
end

local function NormalizeWeekSeconds(value)
    local n=tonumber(value) or 0
    n=n%WEEK_SECONDS
    if n<0 then n=n+WEEK_SECONDS end
    return n
end

local function WeekSecondsFromServerTime(now)
    if type(now)~="table" then return nil end
    local day=S.Utils.DayOfWeek(now.year,now.month,now.day)
    if tonumber(day)==nil then return nil end
    return NormalizeWeekSeconds(((day-1)*24*60*60)+((tonumber(now.hour) or 0)*60*60)+((tonumber(now.minute) or 0)*60)+(tonumber(now.second) or 0))
end

-- Monotonic Gregorian day number used only for seasonal event visibility.
-- It intentionally avoids os.time(), which is not a reliable game-addon
-- Authority and may use the player's local timezone instead of server date.
local function DateSerial(year,month,day)
    local y,m,d=tonumber(year),tonumber(month),tonumber(day)
    if y==nil or m==nil or d==nil then return nil end
    y=math.floor(y); m=math.floor(m); d=math.floor(d)
    if m<=2 then y=y-1; m=m+12 end
    return (365*y)+math.floor(y/4)-math.floor(y/100)+math.floor(y/400)+math.floor((153*(m-3)+2)/5)+d
end

local function IsoDateSerial(text)
    local y,m,d=string.match(tostring(text or ""),"^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
    return DateSerial(y,m,d)
end

local function DaySecondsFromServerTime(now)
    if type(now)~="table" then return nil end
    return ((tonumber(now.hour) or 0)*60*60)+((tonumber(now.minute) or 0)*60)+(tonumber(now.second) or 0)
end

local function EventDateEnabled(event,currentDateSerial)
    if type(event)~="table" or currentDateSerial==nil then return true end
    local from=IsoDateSerial(event.activeFrom)
    local untilDate=IsoDateSerial(event.activeUntil)
    if from~=nil and currentDateSerial<from then return false end
    if untilDate~=nil and currentDateSerial>untilDate then return false end
    return true
end

local function ForwardWeekDelta(fromValue,toValue)
    return NormalizeWeekSeconds((tonumber(toValue) or 0)-(tonumber(fromValue) or 0))
end

local function FormatLiveCountdown(seconds)
    -- Dense HUD presentation: Chinese units and no redundant countdown prefix.
    -- For >= 1 minute we intentionally hide seconds; this stops every row from
    -- visually jittering each second and matches the compact schedule-table use.
    local value=math.max(0,math.floor(tonumber(seconds) or 0))
    if value<60 then return tostring(value).."秒" end
    local minutes=math.floor(value/60)
    if minutes<60 then return tostring(minutes).."分" end
    local hours=math.floor(minutes/60)
    minutes=minutes%60
    if hours<24 then
        if minutes>0 then return tostring(hours).."时"..tostring(minutes).."分" end
        return tostring(hours).."时"
    end
    local days=math.floor(hours/24)
    hours=hours%24
    if hours>0 then return tostring(days).."天"..tostring(hours).."时" end
    return tostring(days).."天"
end


function E:GetZoneRemainSeconds(zoneId)
    zoneId=tonumber(zoneId)
    if zoneId==nil then return nil end
    local sampled=tonumber(self.zoneRemainSeconds and self.zoneRemainSeconds[zoneId])
    if sampled==nil then return nil end
    local observedAt=tonumber(self.zoneRemainObservedAt and self.zoneRemainObservedAt[zoneId]) or self:NowMs()
    local elapsed=math.max(0,math.floor((self:NowMs()-observedAt)/1000))
    return math.max(0,math.floor(sampled)-elapsed)
end

-- Event rows read quest progress from QuestService's cached snapshot.  Event
-- timers refresh every second, but they never poll X2Quest here; quest API work
-- remains owned by QuestService and is event/debounce/safety driven.
function E:GetQuestProgress(key)
    key=tostring(key or "")
    if key=="" then return nil end

    -- Event progress has ONE Authority: QuestService's canonical
    -- ActivityQuestGroups snapshot.  Never fall back to the Daily presentation
    -- list; that old fallback is exactly how the floating HUD could show a
    -- different denominator/task set from the detail/daily page.
    local cached=S.State.data.eventQuestProgress and S.State.data.eventQuestProgress[key]
    if type(cached)~="table" then return nil end
    local total=math.max(0,tonumber(cached.total) or 0)
    if total<=0 then return nil end
    local completed=math.max(0,math.min(tonumber(cached.completed) or 0,total))
    local ready=math.max(0,math.min(tonumber(cached.readyCount) or 0,completed))
    return completed,total,tostring(completed).."/"..tostring(total),ready
end

function E:AttachQuestProgress(rows)
    for _,row in ipairs(rows or {}) do
        local completed,total,text,ready=self:GetQuestProgress(row.questKey)
        if text~=nil then
            row.progressText=text
            row.progressCompleted=completed
            row.progressTotal=total
            row.progressReady=ready or 0
            if completed>=total and total>0 then
                row.progressTone=(ready or 0)>0 and "orange" or "green"
            elseif completed>0 then
                row.progressTone="yellow"
            else
                row.progressTone="muted"
            end
        else
            row.progressText="--"
            row.progressTone="muted"
        end
    end
end

function E:SyncClock(force)
    local sampled=S.Utils.GetServerTime()
    local sampledWeek=WeekSecondsFromServerTime(sampled)
    if sampledWeek==nil then return self.clockAnchor~=nil end
    local sampledDate=DateSerial(sampled.year,sampled.month,sampled.day)
    local sampledDaySeconds=DaySecondsFromServerTime(sampled)
    local nowMs=self:NowMs()
    if self.clockAnchor==nil or force==true then
        self.clockAnchor={
            weekSeconds=sampledWeek,atMs=nowMs,lastSample=sampledWeek,
            dateSerial=sampledDate,daySeconds=sampledDaySeconds,
        }
        return true
    end

    -- A frozen sample must never pull the running countdown back to the same
    -- second every refresh.  Re-anchor only when the authoritative sample has
    -- actually advanced.  Modular delta also handles the Sunday->Monday wrap.
    local lastSample=tonumber(self.clockAnchor.lastSample)
    local advanced=lastSample~=nil and ForwardWeekDelta(lastSample,sampledWeek) or 0
    if lastSample==nil or (advanced>0 and advanced<(12*60*60)) then
        self.clockAnchor.weekSeconds=sampledWeek
        self.clockAnchor.atMs=nowMs
        self.clockAnchor.lastSample=sampledWeek
        self.clockAnchor.dateSerial=sampledDate or self.clockAnchor.dateSerial
        self.clockAnchor.daySeconds=sampledDaySeconds or self.clockAnchor.daySeconds
    elseif sampledWeek~=lastSample then
        -- A large discontinuity can happen after loading screens / reconnects.
        -- Trust the new server sample rather than accumulating stale local time.
        self.clockAnchor.weekSeconds=sampledWeek
        self.clockAnchor.atMs=nowMs
        self.clockAnchor.lastSample=sampledWeek
        self.clockAnchor.dateSerial=sampledDate or self.clockAnchor.dateSerial
        self.clockAnchor.daySeconds=sampledDaySeconds or self.clockAnchor.daySeconds
    end
    return true
end

function E:GetDateSerial()
    self:SyncClock(false)
    if self.clockAnchor==nil then return nil end
    local baseDate=tonumber(self.clockAnchor.dateSerial)
    local baseDaySeconds=tonumber(self.clockAnchor.daySeconds)
    if baseDate==nil or baseDaySeconds==nil then return nil end
    local elapsed=math.max(0,(self:NowMs()-(tonumber(self.clockAnchor.atMs) or 0))/1000)
    return baseDate+math.floor((baseDaySeconds+elapsed)/86400)
end

function E:GetWeekSeconds()
    self:SyncClock(false)
    if self.clockAnchor==nil then return nil end
    local elapsed=math.max(0,(self:NowMs()-(tonumber(self.clockAnchor.atMs) or 0))/1000)
    return NormalizeWeekSeconds((tonumber(self.clockAnchor.weekSeconds) or 0)+elapsed)
end


local function HasQuestDrivenTail(questKey)
    questKey=tostring(questKey or "")
    if questKey=="" then return false end
    local cached=S.State.data.eventQuestProgress and S.State.data.eventQuestProgress[questKey]
    return type(cached)=="table" and (tonumber(cached.tailInFlightCount) or 0)>0
end

function E:BuildStatic(now)
    local nowSecond=type(now)=="number" and NormalizeWeekSeconds(now) or WeekSecondsFromServerTime(now)
    if nowSecond==nil then return {} end
    local result={}
    local currentDateSerial=self:GetDateSerial()
    for _,event in ipairs(S.Data.RuEvents or {}) do
        if EventDateEnabled(event,currentDateSerial) then
            for d=1,7 do
                if HasDay(event.days,d) then
                    local start=((d-1)*24*60*60)+((tonumber(event.hour) or 0)*60*60)+((tonumber(event.minute) or 0)*60)
                    local durationSeconds=(tonumber(event.duration) or 0)*60
                    for _,offset in ipairs({-WEEK_SECONDS,0,WEEK_SECONDS}) do
                        local s=start+offset; local delta=s-nowSecond
                        if delta<=0 and nowSecond<s+durationSeconds then
                            local remain=math.max(0,math.floor((s+durationSeconds)-nowSecond))
                            result[#result+1]={name=event.name,fullName=event.fullName or event.name,shortName=event.shortName or event.name,microName=event.microName or event.shortName or event.name,questScope=event.questScope,questKey=event.questKey,active=true,seconds=remain,sortSeconds=-1,tone="red",status="进行中 "..FormatLiveCountdown(remain),reminderOccurrence=tostring(event.fullName or event.name)..":"..tostring(d)..":"..tostring(start)}
                        elseif delta<=0 and tonumber(event.taskTailMinutes)~=nil then
                            -- The schedule window can finish before a verified boss/follow-up
                            -- quest does. Do not guess another timer: QuestService owns quest
                            -- state and exposes only explicitly marked tail objectives here.
                            local endedAgo=math.max(0,nowSecond-(s+durationSeconds))
                            local tailSeconds=math.max(0,tonumber(event.taskTailMinutes) or 0)*60
                            if endedAgo<=tailSeconds and HasQuestDrivenTail(event.questKey) then
                                result[#result+1]={name=event.name,fullName=event.fullName or event.name,shortName=event.shortName or event.name,microName=event.microName or event.shortName or event.name,questScope=event.questScope,questKey=event.questKey,active=true,taskTail=true,sortSeconds=-1,tone="red",status="Boss / 后续任务进行中",reminderOccurrence=tostring(event.fullName or event.name)..":"..tostring(d)..":"..tostring(start)..":tail"}
                            end
                        elseif delta>0 and delta<=WEEK_SECONDS then
                            local remain=math.max(0,math.floor(delta))
                            result[#result+1]={name=event.name,fullName=event.fullName or event.name,shortName=event.shortName or event.name,microName=event.microName or event.shortName or event.name,questScope=event.questScope,questKey=event.questKey,active=false,seconds=remain,sortSeconds=remain,tone=(remain<=900 and "yellow" or "blue"),status=FormatLiveCountdown(remain),reminderOccurrence=tostring(event.fullName or event.name)..":"..tostring(d)..":"..tostring(start)}
                        end
                    end
                end
            end
        end
    end
    return result
end

local function DynamicDefinition(zoneId)
    return S.Data.DynamicEventZones and S.Data.DynamicEventZones[tonumber(zoneId)] or nil
end

local function DynamicItem(self, zoneId)
    return self.dynamic and self.dynamic[tonumber(zoneId)] or nil
end

local function DynamicBase(zoneId, definition)
    local name=type(definition)=="table" and definition.name or tostring(definition or zoneId)
    return {
        zoneId=tonumber(zoneId),
        name=name,
        fullName=type(definition)=="table" and (definition.fullName or definition.name) or name,
        shortName=type(definition)=="table" and (definition.shortName or definition.name) or name,
        microName=type(definition)=="table" and (definition.microName or definition.shortName or definition.name) or name,
        questScope=type(definition)=="table" and definition.questScope or nil,
        questKey=type(definition)=="table" and definition.questKey or nil,
        inlineOnly=type(definition)=="table" and definition.inlineOnly==true or false,
    }
end

function E:BeginDynamic(zoneId)
    zoneId=tonumber(zoneId)
    local definition=DynamicDefinition(zoneId)
    if zoneId==nil or definition==nil then return false end
    local now=self:NowMs()
    local leadMs=math.max(0,tonumber(definition.conflictLeadMinutes) or 15)*60*1000
    local activeMs=math.max(0,tonumber(definition.activeDurationMinutes) or 0)*60*1000
    local item=DynamicBase(zoneId,definition)
    item.conflictAt=now
    item.warAt=now+leadMs
    item.startAt=item.warAt
    item.endAt=item.warAt+activeMs
    item.timingKnown=true
    local bossOffset=tonumber(definition.bossAfterWarMinutes)
    if bossOffset~=nil then item.bossAt=item.warAt+math.max(0,bossOffset)*60*1000 end
    self.dynamic[zoneId]=item
    return true
end

function E:MarkWarEntered(zoneId, previousState)
    zoneId=tonumber(zoneId)
    local definition=DynamicDefinition(zoneId)
    if zoneId==nil or definition==nil then return false end
    local now=self:NowMs()
    local item=DynamicItem(self,zoneId)
    if item==nil then item=DynamicBase(zoneId,definition); self.dynamic[zoneId]=item end
    if tonumber(previousState)==ZONE_STATE.BATTLE then
        -- HPW_ZONE_STATE_CHANGE / the 5s fallback gives us the real transition,
        -- which is more accurate than the 15-minute prediction made at Conflict.
        item.warAt=now
        item.startAt=now
        item.endAt=now+math.max(0,tonumber(definition.activeDurationMinutes) or 0)*60*1000
        item.timingKnown=true
        local bossOffset=tonumber(definition.bossAfterWarMinutes)
        item.bossAt=bossOffset~=nil and (now+math.max(0,bossOffset)*60*1000) or nil
    elseif item.warAt==nil then
        -- Reloading while the zone is already at War does not expose elapsed War
        -- time through the public addon API. Do not invent a false Boss timer.
        item.observedWarAt=now
        item.timingKnown=false
    end
    return true
end

function E:BuildZoneStateRows()
    local rows={}
    for index,definition in ipairs(S.Data.ZoneStateWatch or {}) do
        local zoneId=tonumber(definition.zoneId)
        local state=tonumber(self.zoneStates[zoneId])
        local remain=self:GetZoneRemainSeconds(zoneId)
        local dynamicDefinition=DynamicDefinition(zoneId)
        local view=state~=nil and ZONE_STATE_VIEW[state] or nil
        local stateText=view and view.text or "状态未知"
        local status=stateText
        local tone=view and view.tone or "muted"
        local sortPriority=0
        local sortSeconds=nil
        local deferredZone=false
        local activePhase=(state==ZONE_STATE.BATTLE or state==ZONE_STATE.WAR)
        local rowActive=activePhase
        local reminderName,reminderSeconds,reminderActive,reminderOccurrence=nil,nil,false,nil

        -- Display contract shared by the main page and floating HUD:
        --   active Conflict / War -> "进行中 纷争/战争 <server remain>"
        --   Peace               -> "和平 <server remain>"
        --   Danger 1~5          -> "危险N阶段" (no invented countdown)
        -- Only phases with authoritative remainTime enter chronological sorting.
        if remain~=nil and view~=nil and view.timed==true then
            if activePhase then
                status="进行中 "..stateText.." "..FormatLiveCountdown(remain)
            else
                status=stateText.." "..FormatLiveCountdown(remain)
            end
            sortSeconds=remain
        elseif view~=nil and view.danger==true then
            sortPriority=1000+index
            sortSeconds=math.huge
        else
            sortPriority=900+index
            sortSeconds=math.huge
        end

        -- Peace remains informational and is kept behind currently useful rows.
        if state==ZONE_STATE.PEACE then
            deferredZone=true
            sortPriority=800+index
        end

        -- Aegis / Whalesong have event semantics that are narrower than the map's
        -- generic Conflict/War state.  Keep X2Map remainTime as timing Authority,
        -- but do not call either event "进行中" merely because the zone is Conflict.
        if (zoneId==102 or zoneId==103) and state==ZONE_STATE.BATTLE and remain~=nil then
            status="纷争 "..FormatLiveCountdown(remain)
            rowActive=false
        end

        if zoneId==102 and state==ZONE_STATE.WAR and remain~=nil then
            -- Aegis is considered actively running only for the first 20 minutes
            -- of the 90-minute War window. This can be derived from the live War
            -- remainder, so reloads do not need a locally remembered transition.
            local totalMinutes=math.max(0,tonumber(dynamicDefinition and dynamicDefinition.warTotalMinutes) or 90)
            local activeMinutes=math.max(0,tonumber(dynamicDefinition and dynamicDefinition.activeWarMinutes) or 20)
            local activeFloor=math.max(0,totalMinutes-activeMinutes)*60
            if remain>activeFloor then
                status="进行中 战争 "..FormatLiveCountdown(remain)
                rowActive=true
            else
                status="战争 "..FormatLiveCountdown(remain)
                rowActive=false
            end
        elseif zoneId==103 and state==ZONE_STATE.WAR and remain~=nil then
            -- Whalesong Boss appears when the authoritative War remainder reaches
            -- 1h16m. Before that point, replace the generic War text with a direct
            -- Boss countdown. Keep a one-minute Boss-active band, then return to
            -- ordinary War time without claiming the event is still in progress.
            local thresholdMinutes=math.max(0,tonumber(dynamicDefinition and dynamicDefinition.bossWarRemainMinutes) or 76)
            local activeUntilMinutes=math.max(0,tonumber(dynamicDefinition and dynamicDefinition.bossActiveUntilWarRemainMinutes) or 75)
            local thresholdSeconds=thresholdMinutes*60
            local activeUntilSeconds=activeUntilMinutes*60
            local bossLabel=tostring((dynamicDefinition and dynamicDefinition.bossLabel) or "Boss")
            if remain>thresholdSeconds then
                local bossRemain=math.max(0,math.floor(remain-thresholdSeconds))
                status=bossLabel.." "..FormatLiveCountdown(bossRemain)
                tone="yellow"
                sortSeconds=bossRemain
                rowActive=false
                reminderName="鲸鱼Boss"
                reminderSeconds=bossRemain
                reminderOccurrence="zone103:boss:"..tostring(math.floor((self:NowMs()+bossRemain*1000)/60000))
            elseif remain>activeUntilSeconds then
                local thresholdAt=self:NowMs()-math.max(0,thresholdSeconds-remain)*1000
                status=bossLabel.."进行中"
                tone="red"
                sortSeconds=0
                rowActive=true
                reminderName="鲸鱼Boss"
                reminderActive=true
                reminderOccurrence="zone103:boss:"..tostring(math.floor(thresholdAt/60000))
            else
                status="战争 "..FormatLiveCountdown(remain)
                tone="red"
                sortSeconds=remain
                rowActive=false
            end
        end

        -- Quest tracking is independent from the live zone phase. The previous
        -- implementation removed Whalesong/Aegis questKey during Danger/Peace,
        -- which made their real accepted tasks disappear from the activity UI.
        -- Keep phase text as presentation only; QuestService remains Authority for
        -- whether the linked tasks are unaccepted, active, ready or completed.
        local rowQuestScope=(dynamicDefinition and dynamicDefinition.questScope) or definition.questScope or nil
        local rowQuestKey=(dynamicDefinition and dynamicDefinition.questKey) or definition.questKey or nil

        local shortName=tostring(definition.stripName or definition.name or definition.sourceName or zoneId)
        rows[#rows+1]={
            name=tostring(definition.name or definition.sourceName or ("区域 "..tostring(zoneId))),
            fullName=tostring(definition.fullName or definition.name or definition.sourceName or ("区域 "..tostring(zoneId))),
            shortName=shortName,
            microName=shortName,
            status=status,
            tone=tone,
            zoneState=true,
            zoneId=zoneId,
            questScope=rowQuestScope,
            questKey=rowQuestKey,
            sortPriority=sortPriority,
            sortSeconds=sortSeconds,
            seconds=(sortSeconds~=nil and sortSeconds~=math.huge) and sortSeconds or nil,
            untimedZone=(sortSeconds==math.huge),
            deferredZone=deferredZone,
            active=rowActive,
            reminderName=reminderName, reminderSeconds=reminderSeconds, reminderActive=reminderActive, reminderOccurrence=reminderOccurrence,
        }
    end
    return rows
end

function E:ScanZoneState(zoneId)
    zoneId=tonumber(zoneId)
    if zoneId==nil then return false end
    local watched=S.Data.ZoneStateWatchById and S.Data.ZoneStateWatchById[zoneId]
    local dynamicDefinition=DynamicDefinition(zoneId)
    if watched==nil and dynamicDefinition==nil then return false end

    local ok,info=S.Api:CallCapability("X2Map:GetZoneStateInfoByZoneId", X2Map, "GetZoneStateInfoByZoneId",zoneId)
    if not ok or type(info)~="table" then return false end
    local state=tonumber(info.conflictState)
    if state==nil then return false end

    local previous=self.zoneStates[zoneId]
    local previousRemain=tonumber(self.zoneRemainSeconds and self.zoneRemainSeconds[zoneId])
    self.zoneStates[zoneId]=state
    self.zoneRemainSeconds=self.zoneRemainSeconds or {}
    self.zoneRemainObservedAt=self.zoneRemainObservedAt or {}
    local remain=tonumber(info.remainTime)
    self.zoneRemainSeconds[zoneId]=remain~=nil and math.max(0,math.floor(remain)) or nil
    self.zoneRemainObservedAt[zoneId]=remain~=nil and self:NowMs() or nil

    -- A live War occurrence is an edge-triggered identity, not a value derived
    -- from the repeatedly sampled remainTime.  Garden Boss reminders use this
    -- stable token so one War can never become a "new" reminder merely because
    -- the server countdown was refreshed.  The token is released only after the
    -- zone leaves War; the next War transition receives a fresh identity.
    self.warReminderOccurrence=type(self.warReminderOccurrence)=="table" and self.warReminderOccurrence or {}
    if state==ZONE_STATE.WAR then
        if tonumber(previous)~=ZONE_STATE.WAR or self.warReminderOccurrence[zoneId]==nil then
            self.warReminderOccurrence[zoneId]=tostring(math.floor(self:NowMs()))
        end
    else
        self.warReminderOccurrence[zoneId]=nil
    end

    -- Live-region rows render the server remainTime directly. Generic dynamic
    -- definitions may still track real phase edges for their own schedules;
    -- Whalesong Boss timing itself is derived from authoritative War remainTime.
    if dynamicDefinition~=nil then
        if previous~=nil and state==ZONE_STATE.WAR and tonumber(previous)~=ZONE_STATE.WAR then
            self:MarkWarEntered(zoneId,previous)
        elseif dynamicDefinition.inlineOnly~=true and dynamicDefinition.liveRowOnly~=true and previous~=nil and IsConflictStage(state) and not IsConflictStage(previous) then
            self:BeginDynamic(zoneId)
        elseif state~=ZONE_STATE.BATTLE and state~=ZONE_STATE.WAR and previous~=nil and previous~=state then
            self.dynamic[zoneId]=nil
        end
    end
    return previous~=state or previousRemain~=self.zoneRemainSeconds[zoneId]
end

function E:ScanDynamicZone(zoneId)
    zoneId=tonumber(zoneId)
    if zoneId==nil or (S.Data.DynamicEventZones and S.Data.DynamicEventZones[zoneId])==nil then return false end
    return self:ScanZoneState(zoneId)
end
-- Compatibility entry used by older callers.
function E:AddDynamic(zoneId)
    return self:ScanDynamicZone(zoneId)
end

function E:GetReminderThresholds()
    local mode=tostring(S.State.settings.eventReminderMode or "off")
    if mode=="15_5" then return {15,5},true end
    if mode=="5" then return {5},true end
    return {},false
end

function E:ProcessReminders(rows)
    local thresholds,enabled=self:GetReminderThresholds(); if enabled~=true then return end
    local dateKey=tostring(S.Utils.ServerDateKey())
    if self.reminderDateKey~=dateKey then self.reminderDateKey=dateKey; self.reminderSeen={} end
    self.reminderSeen=type(self.reminderSeen)=="table" and self.reminderSeen or {}
    -- Do not flood chat with "已开始" for every event that was already active
    -- when reminders are first enabled or the addon reloads. Upcoming windows
    -- still notify immediately; future active transitions use a fresh key.
    if self.reminderBootstrapped~=true then
        for _,row in ipairs(rows or {}) do
            if row.reminderActive==true or (row.zoneState~=true and row.active==true) then
                local occurrence=tostring(row.reminderOccurrence or row.fullName or row.name or "event")
                self.reminderSeen[dateKey..":"..occurrence..":start"]=true
            end
        end
        self.reminderBootstrapped=true
    end
    local function Send(row,kind,text)
        if row.zoneState~=true and self:IsHidden(row) then return end
        local occurrence=tostring(row.reminderOccurrence or row.fullName or row.name or "event")
        local key=dateKey..":"..occurrence..":"..kind
        if self.reminderSeen[key] then return end
        self.reminderSeen[key]=true
        S.SafeChat("[活动提醒] "..tostring(row.reminderName or row.fullName or row.name or "活动").." "..text)
    end
    for _,row in ipairs(rows or {}) do
        local seconds=tonumber(row.reminderSeconds)
        if seconds==nil and row.zoneState~=true and row.active~=true then seconds=tonumber(row.seconds) end
        if seconds~=nil and seconds>0 then
            for _,minute in ipairs(thresholds) do
                local upper=minute*60; local lower=(minute==15) and 300 or 0
                if seconds<=upper and seconds>lower then Send(row,"before"..tostring(minute),"将在 "..tostring(minute).." 分钟内开始") end
            end
        end
        if row.reminderActive==true or (row.zoneState~=true and row.active==true) then Send(row,"start","已开始") end
    end
end

function E:BuildGardenBossRow()
    local zoneId=133
    local definition=DynamicDefinition(zoneId)
    if definition==nil then return nil end

    local state=tonumber(self.zoneStates[zoneId])
    local remain=self:GetZoneRemainSeconds(zoneId)
    if state==nil or remain==nil then return nil end

    local name=tostring(definition.name or "庭院Boss")
    local fullName=tostring(definition.fullName or name)
    local nowMs=self:NowMs()
    local row={
        name=name,
        fullName=fullName,
        shortName=tostring(definition.shortName or name),
        microName=tostring(definition.microName or definition.shortName or name),
        active=false,
        zoneId=zoneId,
        liveEvent=true,
    }

    if state==ZONE_STATE.WAR then
        -- Garden raid bosses belong to the War window. The server's live
        -- remainTime is the Authority, so reloads in the middle of War do not
        -- require reconstructing elapsed time from a local observation.
        row.active=true
        row.sortSeconds=-1
        row.seconds=remain
        row.tone="red"
        -- Garden bosses remain available for the authoritative War window.
        -- Show that same server-derived War remainder instead of a static
        -- "已刷新" marker, so the activity row tells the user exactly how long
        -- the current boss/War window remains open.
        row.status="进行中 战争 "..FormatLiveCountdown(remain)
        row.reminderName=name
        row.reminderActive=true
        -- Garden Boss is edge-triggered: notify once when this War begins.
        -- Never derive the reminder identity from remainTime; repeated server
        -- samples can drift and previously made one War look like several
        -- separate occurrences.
        self.warReminderOccurrence=type(self.warReminderOccurrence)=="table" and self.warReminderOccurrence or {}
        local occurrence=self.warReminderOccurrence[zoneId]
        if occurrence==nil then
            occurrence=tostring(math.floor(nowMs))
            self.warReminderOccurrence[zoneId]=occurrence
        end
        row.reminderOccurrence="zone133:war:"..occurrence
        return row
    end

    local bossRemain=nil
    if state==ZONE_STATE.BATTLE then
        -- War follows Conflict immediately, so the boss window begins when the
        -- authoritative Conflict countdown reaches zero.
        bossRemain=remain
    elseif state==ZONE_STATE.PEACE then
        -- RU Garden cycle has a 10-minute Conflict between Peace and War. Add
        -- only that known lead to the live Peace remainder; no wall-clock
        -- schedule is manufactured here.
        local conflictLead=math.max(0,tonumber(definition.conflictLeadMinutes) or 10)*60
        bossRemain=remain+conflictLead
    else
        -- Garden normally cycles Peace -> Conflict -> War. If a client build
        -- reports a different phase, omit the row rather than publish a false
        -- countdown that cannot be derived from authoritative data.
        return nil
    end

    bossRemain=math.max(0,math.floor(bossRemain or 0))
    row.seconds=bossRemain
    row.sortSeconds=bossRemain
    row.tone=(bossRemain<=900 and "yellow" or "blue")
    row.status=FormatLiveCountdown(bossRemain)
    -- This countdown is display-only. Garden bosses begin with the live War
    -- phase, but the addon has no authoritative boss-death signal. Therefore
    -- do not feed the row into the generic 15/5-minute reminder pipeline.
    -- The only Garden Boss notification is the War-entry edge above.
    return row
end

function E:Refresh()
    local rows=self:BuildZoneStateRows()
    local gardenBoss=self:BuildGardenBossRow()
    if gardenBoss~=nil then rows[#rows+1]=gardenBoss end
    local weekSeconds=self:GetWeekSeconds()
    local staticRows=self:BuildStatic(weekSeconds)
    for _,row in ipairs(staticRows) do rows[#rows+1]=row end
    local nowMs=self:NowMs()
    for key,item in pairs(self.dynamic) do
        -- Aegis/Whalesong already have authoritative live rows in BuildZoneStateRows.
        -- Keep dynamic timing authority here without emitting duplicate rows.
        if item.inlineOnly~=true then
            if tonumber(item.endAt)~=nil and nowMs>=item.endAt then self.dynamic[key]=nil
            elseif tonumber(item.startAt)~=nil and nowMs>=item.startAt then
                local remain=math.max(0,math.floor((item.endAt-nowMs)/1000))
                rows[#rows+1]={name=item.name or tostring(key),fullName=item.fullName or item.name or tostring(key),shortName=item.shortName or item.name or tostring(key),microName=item.microName or item.shortName or item.name or tostring(key),questScope=item.questScope,questKey=item.questKey,active=true,sortSeconds=-1,seconds=remain,tone="red",status="进行中 "..FormatLiveCountdown(remain)}
            elseif tonumber(item.startAt)~=nil then
                local remain=math.max(0,math.floor((item.startAt-nowMs)/1000))
                rows[#rows+1]={name=item.name or tostring(key),fullName=item.fullName or item.name or tostring(key),shortName=item.shortName or item.name or tostring(key),microName=item.microName or item.shortName or item.name or tostring(key),questScope=item.questScope,questKey=item.questKey,active=false,sortSeconds=remain,seconds=remain,tone="yellow",status=FormatLiveCountdown(remain)}
            end
        end
    end
    self:AttachQuestProgress(rows)
    self:ProcessReminders(rows)
    table.sort(rows,function(a,b)
        local pa,pb=tonumber(a.sortPriority) or 0,tonumber(b.sortPriority) or 0
        if pa~=pb then return pa<pb end
        if a.active~=b.active then return a.active==true end
        local sa,sb=tonumber(a.sortSeconds) or math.huge,tonumber(b.sortSeconds) or math.huge
        if sa~=sb then return sa<sb end
        return tostring(a.name)<tostring(b.name)
    end)
    -- Deduplicate the same event occurrence produced by week-wrap candidates.
    -- IMPORTANT: the 64-row guard applies only to ordinary scheduled rows.
    -- Untimed live-zone rows sort after the schedule (priority ~= 1000); the old
    -- early `break` could therefore stop before Whalesong/Aegis/Cinderstone were
    -- ever copied into `filtered`.  A timed zone such as Ynystere Peace survived,
    -- which made this bug look phase-specific.  Always preserve every zoneState
    -- row, then let the visible-cap reorder below reserve its final slots.
    local seen,filtered={},{}
    local ordinaryKept=0
    for _,row in ipairs(rows) do
        local hidden = row.zoneState ~= true and self:IsHidden(row)
        local key=tostring(row.name)..":"..tostring(row.active)..":"..tostring(math.floor((row.seconds or 0)/60))
        local isLiveZone=row.zoneState==true
        local underOrdinaryGuard=isLiveZone or ordinaryKept<64
        if hidden ~= true and underOrdinaryGuard and not seen[key] then
            seen[key]=true
            filtered[#filtered+1]=row
            if not isLiveZone then ordinaryKept=ordinaryKept+1 end
        end
    end

    -- Live-zone ordering contract:
    --   * Conflict / War rows have authoritative remainTime and are useful now,
    --     so they stay in the normal chronological stream.
    --   * Peace and Danger/unknown rows are informational. Reserve visible slots
    --     for them after near-term useful activities so live map context never
    --     disappears behind many hours of static schedule rows.
    -- This is intentionally done after de-duplication so the four watched zones
    -- (Cinderstone / Ynystere / Whalesong / Aegis) remain first-class rows and
    -- their quest progress is never lost merely because the schedule is busy.
    local cap=math.max(5,math.min(20,tonumber(S.State.settings.eventMaxRows) or 20))
    local timed,reserved={},{}
    for _,row in ipairs(filtered) do
        -- Untimed Danger/unknown stages and informational Peace phases are
        -- guaranteed a visible slot, but only AFTER currently useful timed
        -- activities. Whalesong/Aegis Conflict and War are never deferred.
        if row.zoneState==true and (row.untimedZone==true or row.deferredZone==true) then
            reserved[#reserved+1]=row
        else
            timed[#timed+1]=row
        end
    end
    if #reserved>0 then
        local near,far={},{}
        local nearLimit=math.max(0,cap-#reserved)
        local NEAR_SECONDS=2*60*60
        for _,row in ipairs(timed) do
            local seconds=tonumber(row.seconds)
            local isNear=row.active==true or (seconds~=nil and seconds<=NEAR_SECONDS)
            if isNear and #near<nearLimit then
                near[#near+1]=row
            else
                far[#far+1]=row
            end
        end

        local reordered={}
        for _,row in ipairs(near) do reordered[#reordered+1]=row end
        for _,row in ipairs(reserved) do reordered[#reordered+1]=row end
        for _,row in ipairs(far) do reordered[#reordered+1]=row end
        filtered=reordered
    end
    S.State.data.events=filtered
    local nextEvent=nil
    for _,row in ipairs(filtered) do
        -- Timed live-zone phases are now first-class schedule rows. Danger-only
        -- rows have no seconds and should not become the global "next event".
        if row.zoneState~=true or tonumber(row.seconds)~=nil then nextEvent=row; break end
    end
    S.State.data.summary.nextEvent=(nextEvent and (tostring(nextEvent.name).." "..tostring(nextEvent.status))) or "--"
    S.State:MarkDirty("events")
end

local function HiddenKey(rowOrName)
    if type(rowOrName) == "table" then
        return tostring(rowOrName.fullName or rowOrName.name or "")
    end
    return tostring(rowOrName or "")
end

function E:IsHidden(rowOrName)
    local key = HiddenKey(rowOrName)
    return key ~= "" and type(S.State.life.hiddenEvents) == "table" and S.State.life.hiddenEvents[key] == true
end

function E:GetHiddenCount()
    local count = 0
    for _, hidden in pairs(type(S.State.life.hiddenEvents) == "table" and S.State.life.hiddenEvents or {}) do
        if hidden == true then count = count + 1 end
    end
    return count
end

function E:HideEvent(row)
    if type(row) ~= "table" or row.zoneState == true then return false end
    local key = HiddenKey(row)
    if key == "" then return false end
    S.State.life.hiddenEvents = type(S.State.life.hiddenEvents) == "table" and S.State.life.hiddenEvents or {}
    S.State.life.hiddenEvents[key] = true
    S.Storage:RequestSave()
    self:Refresh()
    S.SafeChat("已隐藏活动：" .. key .. "。可在“生活 → 活动”中恢复。")
    return true
end

function E:RestoreHiddenEvents()
    S.State.life.hiddenEvents = {}
    S.Storage:RequestSave()
    self:Refresh()
    return true
end

function E:OpenTask(row)
    if type(row) ~= "table" or row.questKey == nil then return false end
    local quest = S.Services and S.Services.Quest
    if quest == nil or type(quest.OpenGroupDetail) ~= "function" then
        -- Diagnostic: the detail click path depends on the Quest service.  A
        -- hot reload that left S.Services.Quest incomplete would make every
        -- activity row click fail silently; surface it so the user can report.
        S.SafeChat("任务详情入口不可用：Quest 服务未就绪。")
        return false
    end
    quest:OpenGroupDetail(row.questScope or "event", row.questKey)
    return true
end

function E:ScanDynamicZones()
    self:ScanDynamicZone(102)
    self:ScanDynamicZone(103)
end

function E:ScanTrackedZones()
    local changed=false
    local scanned={}
    for _,definition in ipairs(S.Data.ZoneStateWatch or {}) do
        local zoneId=tonumber(definition.zoneId)
        if zoneId~=nil then
            scanned[zoneId]=true
            if self:ScanZoneState(zoneId) then changed=true end
        end
    end
    -- Some live events (currently Garden Boss) have their own dedicated row.
    -- Scan those definitions here as well while avoiding duplicate X2Map calls
    -- for Aegis/Whalesong, which are already part of the unified live-zone list.
    for dynamicZoneId,_ in pairs(S.Data.DynamicEventZones or {}) do
        local zoneId=tonumber(dynamicZoneId)
        if zoneId~=nil and scanned[zoneId]~=true then
            if self:ScanZoneState(zoneId) then changed=true end
        end
    end
    return changed
end

function E:Start()
    self.fallbackNowMs=S.NowMs()
    self.lastVisibleSuiteNowMs=S.NowMs()
    self:SyncClock(true)
    S.Events:Subscribe("HPW_ZONE_STATE_CHANGE",self,function(_,zoneId)
        local id=tonumber(zoneId)
        if id~=nil and ((S.Data.ZoneStateWatchById and S.Data.ZoneStateWatchById[id]) or (S.Data.DynamicEventZones and S.Data.DynamicEventZones[id])) then
            E:ScanZoneState(id)
            E:Refresh()
        end
    end)
    S.Events:Subscribe("ENTERED_WORLD",self,function()
        E.zoneStates={}
        E.zoneRemainSeconds={}
        E.zoneRemainObservedAt={}
        E.dynamic={}
        E:SyncClock(true)
        E:ScanTrackedZones()
        E:Refresh()
    end)
    S.Scheduler:AddTask("event_timer",S.Constants.Refresh.eventTimerMs,function() E:Refresh() end,false,self,"P4")
    -- Low-frequency fallback keeps live-region rows plus dedicated live
    -- event zones (for example Garden) current even if a client build drops
    -- HPW_ZONE_STATE_CHANGE while the addon is reloading. These lightweight
    -- X2Map reads run every five seconds, never on Tick/OnUpdate.
    S.Scheduler:AddTask("event_dynamic_zone_scan",5000,function()
        if E:ScanTrackedZones() then E:Refresh() end
    end,false,self,"P2")
    self:ScanTrackedZones()
    self:Refresh()
end
