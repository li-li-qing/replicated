-- Replicated Suite · 活动追踪业务权威
-- 作者：Replicated
-- QQ群：1104129461
-- 活动权威边界：日程归 data/rs_event_data.lua；服务器墙钟低频采样 UIParent:GetServerTimeTable()；有活动页面/Widget 消费端时每5s读 X2Map:GetZoneStateInfoByZoneId()。
-- 任务/副本进度通过明确 Provider 契约接入，禁止复活旧 QuestService 或旧 State。
-- 不使用独立 OnUpdate，投影节奏1s；时钟重采（包括失败）节流15s；静态日程按语义活动合并为一个可见行。
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
S.Features = S.Features or {}
S.Features.Activities = S.Features.Activities or {}
local Feature = S.Features.Activities

local A = {
    version = 2,
    rows = {},
    timelineRows = {},
    liveRows = {},
    rowByKey = {},
    revision = 0,
    updatedAtMs = 0,
    clockAnchor = nil,
    lastClockSampleAtMs = -1,
    zoneStates = {},
    zoneRemainSeconds = {},
    zoneObservedAtMs = {},
    lastZoneScanAtMs = -1,
    zoneScanFailures = 0,
    questProgressProvider = nil,
    instanceProgressProvider = nil,
}
Feature.Authority = A

local WEEK_SECONDS = 7 * 24 * 60 * 60
local DAY_SECONDS = 24 * 60 * 60
local CLOCK_SAMPLE_MS = 15000
local CLOCK_STALE_MS = 120000
local ZONE_STALE_MS = 20000
local TIMELINE_URGENT_SECONDS = 10 * 60

-- timeline 进行中为 red，即将开始仅在 0<secondsUntilStart<=600 时标红；各界面直接消费 row.tone。实时区域配色独立。
local function TimelineTone(active, secondsUntilStart)
    if active == true then return "red" end
    local seconds = tonumber(secondsUntilStart)
    if seconds ~= nil and seconds > 0 and seconds <= TIMELINE_URGENT_SECONDS then return "red" end
    return "default"
end
-- 分钟精度服务器钟表示 60 秒区间，不能每 15 秒当作 :00 重新起算，否则倒计时回跳。
-- 只读诊断不采样；成功/失败均按既有频率限流，时钟与区域样本只驻会话。
local function Integer(value, lo, hi)
    local n = tonumber(value)
    if n == nil or n ~= n or n == math.huge or n == -math.huge or n ~= math.floor(n) or n < lo or n > hi then return nil end
    return n
end
A.ActivityTimelineSortContractVersion = 2
A.PriorityStageSortContractVersion = 1 -- 兼容只读标记：旧 v1 分带已经退役，保留字段仅防止历史诊断/脚本因 nil 误判。
-- timeline 只放有明确时间的计划或区域派生活动，进行中按结束倒计时、将开始按开始倒计时排序。
-- live 仅按目录顺序显示战争/纷争/和平/危险阶段，不能用阶段权重或 3 小时阈值混入时间线。
-- 有确定时间规则才新建 dynamic occurrence；不能按名称猜时间或沿用区域颜色。

local ZONE_STATE = {
    TROUBLE_0 = tonumber(rawget(_G, "HPWS_TROUBLE_0")) or 0,
    TROUBLE_1 = tonumber(rawget(_G, "HPWS_TROUBLE_1")) or 1,
    TROUBLE_2 = tonumber(rawget(_G, "HPWS_TROUBLE_2")) or 2,
    TROUBLE_3 = tonumber(rawget(_G, "HPWS_TROUBLE_3")) or 3,
    TROUBLE_4 = tonumber(rawget(_G, "HPWS_TROUBLE_4")) or 4,
    BATTLE = tonumber(rawget(_G, "HPWS_BATTLE")) or 5,
    WAR = tonumber(rawget(_G, "HPWS_WAR")) or 6,
    PEACE = tonumber(rawget(_G, "HPWS_PEACE")) or 7,
}

local ZONE_VIEW = {
    [ZONE_STATE.TROUBLE_0] = { text = "危险1阶段", tone = "blue", untimed = true },
    [ZONE_STATE.TROUBLE_1] = { text = "危险2阶段", tone = "blue", untimed = true },
    [ZONE_STATE.TROUBLE_2] = { text = "危险3阶段", tone = "yellow", untimed = true },
    [ZONE_STATE.TROUBLE_3] = { text = "危险4阶段", tone = "orange", untimed = true },
    [ZONE_STATE.TROUBLE_4] = { text = "危险5阶段", tone = "orange", untimed = true },
    [ZONE_STATE.BATTLE] = { text = "纷争", tone = "orange", timed = true },
    [ZONE_STATE.WAR] = { text = "战争", tone = "red", timed = true },
    [ZONE_STATE.PEACE] = { text = "和平", tone = "blue", timed = true },
}

local DAY_NAME = { "周日", "周一", "周二", "周三", "周四", "周五", "周六" }

local function NormalizeWeekSeconds(value)
    local n = tonumber(value) or 0
    n = n % WEEK_SECONDS
    if n < 0 then n = n + WEEK_SECONDS end
    return n
end

local function HasDay(days, day)
    for _, value in ipairs(type(days) == "table" and days or {}) do
        if tonumber(value) == tonumber(day) then return true end
    end
    return false
end

local function DateSerial(year, month, day)
    local y, m, d = tonumber(year), tonumber(month), tonumber(day)
    y, m, d = Integer(y, 2000, 2100), Integer(m, 1, 12), Integer(d, 1, 31)
    if y == nil or m == nil or d == nil then return nil end
    local leap = y % 4 == 0 and (y % 100 ~= 0 or y % 400 == 0)
    local monthDays = {31, leap and 29 or 28, 31,30,31,30,31,31,30,31,30,31}
    if d > monthDays[m] then return nil end
    if m <= 2 then y, m = y - 1, m + 12 end
    return (365 * y) + math.floor(y / 4) - math.floor(y / 100) + math.floor(y / 400) + math.floor((153 * (m - 3) + 2) / 5) + d
end

local function IsoDateSerial(text)
    local y, m, d = string.match(tostring(text or ""), "^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
    return DateSerial(y, m, d)
end

local function EventDateEnabled(event, dateSerial)
    if type(event) ~= "table" or dateSerial == nil then return true end
    local from = IsoDateSerial(event.activeFrom)
    local untilDate = IsoDateSerial(event.activeUntil)
    if from ~= nil and dateSerial < from then return false end
    if untilDate ~= nil and dateSerial > untilDate then return false end
    return true
end

local function ParseServerTime(now)
    if type(now) ~= "table" then return nil end
    local date = DateSerial(now.year, now.month, now.day)
    local hour, minute = Integer(now.hour, 0, 23), Integer(now.minute or now.min, 0, 59)
    local rawSecond = now.second
    if rawSecond == nil then rawSecond = now.sec end
    local second = rawSecond == nil and 0 or Integer(rawSecond, 0, 59)
    if date == nil or hour == nil or minute == nil or second == nil then return nil end
    local day = S.Utils and type(S.Utils.DayOfWeek) == "function" and S.Utils.DayOfWeek(now.year, now.month, now.day) or nil
    if Integer(day,1,7) == nil then return nil end
    local seconds = hour*3600 + minute*60 + second
    return {dateSerial=date, daySeconds=seconds, weekSeconds=(day-1)*DAY_SECONDS+seconds,
        absolute=date*DAY_SECONDS+seconds, precision=rawSecond == nil and "minute" or "second",
        text=string.format("%04d-%02d-%02d %02d:%02d:%s",now.year,now.month,now.day,hour,minute,
            rawSecond == nil and "??" or string.format("%02d",second))}
end

local function FormatCountdown(seconds)
    local value = math.max(0, math.floor(tonumber(seconds) or 0))
    if value < 60 then return tostring(value) .. "秒" end
    local minutes = math.floor(value / 60)
    if minutes < 60 then return tostring(minutes) .. "分" end
    local hours = math.floor(minutes / 60)
    minutes = minutes % 60
    if hours < 24 then
        if minutes > 0 then return tostring(hours) .. "时" .. tostring(minutes) .. "分" end
        return tostring(hours) .. "时"
    end
    local days = math.floor(hours / 24)
    hours = hours % 24
    if hours > 0 then return tostring(days) .. "天" .. tostring(hours) .. "时" end
    return tostring(days) .. "天"
end

local function FormatSchedule(day, hour, minute)
    return tostring(DAY_NAME[tonumber(day) or 1] or "") .. " " .. string.format("%02d:%02d", tonumber(hour) or 0, tonumber(minute) or 0)
end

local function HiddenKey(row)
    if type(row) ~= "table" then return tostring(row or "") end
    return row.zoneState == true and tostring(row.key or "") or tostring(row.fullName or row.name or "")
end

local function IsHidden(row)
    if type(row) ~= "table" then return false end
    local hidden = Feature.State and Feature.State.hiddenEvents or nil
    local key = HiddenKey(row)
    return key ~= "" and type(hidden) == "table" and hidden[key] == true
end

function A:SetQuestProgressProvider(provider)
    self.questProgressProvider = type(provider) == "function" and provider or nil
end

function A:SetInstanceProgressProvider(provider)
    self.instanceProgressProvider = type(provider) == "function" and provider or nil
end

function A:NowMs()
    return math.max(0, tonumber(S.NowMs and S.NowMs()) or 0)
end

function A:IsClockFresh()
    local a, nowMs = self.clockAnchor, self:NowMs()
    local stamp = a and (self.lastClockValidAtMs or a.atMs)
    return a ~= nil and stamp ~= nil and nowMs >= stamp and nowMs-stamp <= CLOCK_STALE_MS
end

function A:SyncClock(force)
    local nowMs = self:NowMs()
    if force ~= true and self.lastClockSampleAtMs >= 0 and nowMs >= self.lastClockSampleAtMs
        and nowMs-self.lastClockSampleAtMs < CLOCK_SAMPLE_MS then return self:IsClockFresh() end
    self.lastClockSampleAtMs = nowMs -- 失败也消耗采样周期；禁止每行/每帧重试。
    local raw = S.Utils and type(S.Utils.GetServerTime) == "function" and S.Utils.GetServerTime() or nil
    local sample = ParseServerTime(raw)
    if sample == nil then
        self.clockSampleFailures = (self.clockSampleFailures or 0)+1
        self.clockError = "server_time_unavailable_or_invalid"
        return self:IsClockFresh()
    end
    local previous = self.lastClockSample
    local quantum = sample.precision == "minute" and 60 or 1
    -- 未变化的读值超出自身精度，不能通过反复读取把过期事实延长成“新样本”。
    if previous and previous.absolute == sample.absolute and nowMs-(previous.changedAtMs or previous.atMs) > (quantum+1)*1000 then
        self.clockError = "server_time_not_advancing"
        self.clockSampleFailures = (self.clockSampleFailures or 0)+1
        return self:IsClockFresh()
    end
    local anchor = self.clockAnchor
    local absolute = sample.absolute
    if anchor and anchor.absolute and nowMs >= anchor.atMs and sample.precision == "minute" then
        local predicted = anchor.absolute+(nowMs-anchor.atMs)/1000
        -- 相同分钟样本落后于本地连续投影时，保留旧锚点而不是重置到 :00。
        -- 只在新分钟真正到达时校准；这里不延长样本有效期，冻结接口最终进入过期状态。
        if predicted >= sample.absolute+60 and previous and previous.absolute == sample.absolute then
            self.clockError = "server_time_not_advancing"
            return self:IsClockFresh()
        end
        if predicted >= sample.absolute and predicted < sample.absolute+60 then absolute=predicted end
    end
    local shift = absolute-sample.absolute
    self.clockAnchor = {weekSeconds=NormalizeWeekSeconds(sample.weekSeconds+shift), atMs=nowMs,
        dateSerial=sample.dateSerial, daySeconds=sample.daySeconds+shift, absolute=absolute, precision=sample.precision}
    sample.atMs = nowMs
    sample.changedAtMs = previous and previous.absolute == sample.absolute and previous.changedAtMs or nowMs
    self.lastClockSample, self.lastClockValidAtMs, self.clockError = sample, nowMs, nil
    return true
end

function A:GetWeekSeconds()
    if self:SyncClock(false) ~= true or not self:IsClockFresh() then return nil end
    return NormalizeWeekSeconds(self.clockAnchor.weekSeconds+(self:NowMs()-self.clockAnchor.atMs)/1000)
end

function A:GetDateSerial()
    if self:SyncClock(false) ~= true or not self:IsClockFresh() then return nil end
    local a = self.clockAnchor
    return a.dateSerial+math.floor((a.daySeconds+(self:NowMs()-a.atMs)/1000)/DAY_SECONDS)
end

-- 诊断只复制有界标量，不调用 Utils/Native/Refresh/QuestProgress，也不重新读取存档。
-- JMG 的计划开始与结束同时保留，避免“1分”被误判为 1 分钟后开场。
function A:GetTimingDiagnostics()
    local sample, anchor, jmg = self.lastClockSample, self.clockAnchor, nil
    for _, row in ipairs(self.timelineRows or {}) do if row.questKey == "jmg" then jmg=row;break end end
    return {source="UIParent:GetServerTimeTable / server wall clock", serverSample=sample and sample.text or "unavailable",
        precision=anchor and anchor.precision or "unknown", fresh=self:IsClockFresh(), error=self.clockError,
        sampleAgeMs=sample and math.max(0,self:NowMs()-(self.lastClockValidAtMs or sample.atMs)) or nil,
        sampleFailures=self.clockSampleFailures or 0, lastSampleAtMs=self.lastClockSampleAtMs,
        jmg=jmg and (tostring(jmg.status).." | "..tostring(jmg.scheduleText)) or "no JMG projection",
        scheduleAuthority="curated RU slots; durations are planned windows, not boss liveness",
        scheduleVersion="activity-time-audit-1", zoneTtlMs=ZONE_STALE_MS}
end

local function TimelineSortParts(row)
    -- 排序以 timelineState 为准：active 取 secondsUntilEnd，upcoming 取 secondsUntilStart；旧/测试行才回退兼容字段，不按颜色或名称猜状态。
    local active = type(row) == "table" and (row.timelineState == "active" or row.active == true) or false
    if active then
        return 0, tonumber(row.secondsUntilEnd) or tonumber(row.seconds) or math.huge
    end
    return 1, tonumber(type(row) == "table" and row.secondsUntilStart or nil)
        or tonumber(type(row) == "table" and row.seconds or nil)
        or tonumber(type(row) == "table" and row.sortSeconds or nil)
        or math.huge
end

local function BetterOccurrence(candidate, existing)
    if existing == nil then return true end
    local aState, aSeconds = TimelineSortParts(candidate)
    local bState, bSeconds = TimelineSortParts(existing)
    if aState ~= bState then return aState < bState end
    if aSeconds ~= bSeconds then return aSeconds < bSeconds end
    return tostring(candidate.scheduleText or "") < tostring(existing.scheduleText or "")
end

function A:AttachProgress(row)
    if type(row) ~= "table" then return row end
    local provider = nil
    if row.questKey == "red_dragon" or row.questKey == "kadum" then provider = self.instanceProgressProvider else provider = self.questProgressProvider end
    if type(provider) == "function" then
        local ok, value = xpcall(function() return provider(row.questScope or "event", row.questKey, row) end, S.SafeTraceback)
        if ok and type(value) == "table" then
            row.progressText = tostring(value.text or value.progressText or "--")
            row.progressTone = tostring(value.tone or value.progressTone or "muted")
            row.progressAvailable = true
            return row
        end
    end
    row.progressText = "--"
    row.progressTone = "muted"
    row.progressAvailable = false
    return row
end

-- 静态发生时间/计划文案只随目录或 Generation 改变。
-- 缓存归 Activity Authority 的会话生命周期，ResetTransient 同时释放；日期有效期、
-- 当前活动/倒计时/颜色与进度仍每轮从真实钟和 provider 求值，绝不缓存这些动态结论。
local function CompiledSchedules(self)
    local source = S.Data and S.Data.RuEvents
    local cached = self.compiledSchedules
    if cached ~= nil and cached.source == source and cached.generation == S.Generation then return cached.rows end
    local rows = {}
    for _, event in ipairs(source or {}) do
        local duration = math.max(0, tonumber(event.duration) or 0) * 60
        local endMinute = (tonumber(event.hour) or 0)*60 + (tonumber(event.minute) or 0) + duration/60
        local endText = string.format("%02d:%02d", math.floor(endMinute/60)%24, math.floor(endMinute)%60)
        if endMinute >= 1440 then endText = "次日 " .. endText end
        local occurrences = {}
        for day = 1, 7 do
            if HasDay(event.days, day) then
                occurrences[#occurrences+1] = { day=day,
                    start=(day-1)*DAY_SECONDS+(tonumber(event.hour) or 0)*3600+(tonumber(event.minute) or 0)*60,
                    scheduleText=FormatSchedule(day,event.hour,event.minute).." →计划 "..endText }
            end
        end
        rows[#rows+1] = { event=event, duration=duration, occurrences=occurrences }
    end
    self.compiledSchedules = { source=source, generation=S.Generation, rows=rows }
    return rows
end

function A:BuildStaticRows()
    local now = self:GetWeekSeconds()
    if now == nil then return {} end
    local currentDateSerial = self:GetDateSerial()
    local grouped = {}

    for _, schedule in ipairs(CompiledSchedules(self)) do
        local event = schedule.event -- 日期约束仍来自当前静态目录，不复制一份业务 Authority。
        if EventDateEnabled(event, currentDateSerial) then
            local best = nil
            local duration = schedule.duration
            -- 时间列只由日程和服务器钟决定。未交任务不能延长计划窗口，
            -- 也不能覆盖下一场开场倒计时；任务进度由 AttachProgress 独立投影。
            for _, occurrence in ipairs(schedule.occurrences) do
                local day, start = occurrence.day, occurrence.start -- 复用预编译周时间，动态窗口算法保持不变。
                local elapsed = NormalizeWeekSeconds(now - start)
                local active = duration > 0 and elapsed < duration
                local seconds
                if active then
                    seconds = math.max(0, math.floor(duration - elapsed))
                else
                    seconds = math.max(0, math.ceil(NormalizeWeekSeconds(start - now)))
                end

                -- 每个 occurrence 都要校验日期；仅检查 today 会让限时活动在最后一天指向已结束的下一周。
                local daySeconds = now % DAY_SECONDS
                local occurrenceDate = currentDateSerial and (currentDateSerial+math.floor((daySeconds+(active and -elapsed or seconds))/DAY_SECONDS)) or nil
                local confidence = event.scheduleConfidence or "curated"
                local minutePrecision = self.clockAnchor and self.clockAnchor.precision == "minute"
                -- 这里只给计划窗口，不能当首领实际存活时间。秒级钟写预计结束，分钟级钟写约结束；任务状态不参与场次选择。
                local stateText
                if active then
                    stateText = (minutePrecision and "约" or "预计") .. FormatCountdown(seconds) .. "后结束"
                else
                    stateText = (minutePrecision and "约" or "") .. FormatCountdown(seconds) .. "后开始"
                end
                local candidate = {
                    key = "event:" .. tostring(event.fullName or event.name or "unknown"),
                    name = tostring(event.name or event.fullName or "活动"),
                    fullName = tostring(event.fullName or event.name or "活动"),
                    shortName = tostring(event.shortName or event.name or "活动"),
                    microName = tostring(event.microName or event.shortName or event.name or "活动"),
                    kind = "schedule",
                    source = "curated",
                    presentationSection = "timeline",
                    timelineState = active and "active" or "upcoming",
                    questScope = event.questScope,
                    questKey = event.questKey,
                    active = active,
                    seconds = seconds,
                    secondsUntilStart = active and 0 or seconds,
                    secondsUntilEnd = active and seconds or nil,
                    -- sortSeconds 仅作为旧 Presentation/诊断兼容字段；v2 comparator 不再把 live 状态和它比较。
                    sortSeconds = active and 0 or seconds,
                    -- timeline 按统一 TimelineTone：进行中标红，将开始仅 10 分钟内标红；live 的战争/纷争/和平配色独立。
                    tone = TimelineTone(active, active and 0 or seconds),
                    -- scheduleConfidence/scheduleEvidence 只供诊断，展示只说开始/结束时间，避免把来源可信度当活动阶段。
                    status = stateText,
                    scheduleText = occurrence.scheduleText, -- 固定文本不再每秒为每个周发生点重新格式化。
                    scheduleConfidence = confidence,
                    scheduleEvidence = event.scheduleEvidence or "existing RU curated table",
                    plannedDurationSeconds = duration,
                    occurrenceKey = tostring(event.fullName or event.name) .. ":" .. tostring(day) .. ":" .. tostring(start),
                }
                if EventDateEnabled(event,occurrenceDate) and BetterOccurrence(candidate, best) then best = candidate end
            end
            if best ~= nil then
                local key = best.key
                if BetterOccurrence(best, grouped[key]) then grouped[key] = best end
            end
        end
    end

    local rows = {}
    for _, row in pairs(grouped) do
        if IsHidden(row) ~= true then
            self:AttachProgress(row)
            rows[#rows + 1] = row
        end
    end
    return rows
end

function A:IsZoneFresh(zoneId)
    local atMs=self.zoneObservedAtMs[tonumber(zoneId)]
    return atMs ~= nil and self:NowMs() >= atMs and self:NowMs()-atMs <= ZONE_STALE_MS
end

function A:GetZoneRemainSeconds(zoneId)
    zoneId=tonumber(zoneId)
    if zoneId == nil or not self:IsZoneFresh(zoneId) then return nil end
    local sampled=tonumber(self.zoneRemainSeconds[zoneId])
    if sampled == nil then return nil end
    return math.max(0,math.floor(sampled-(self:NowMs()-self.zoneObservedAtMs[zoneId])/1000))
end

-- 区域状态与定时值分别校验；未计时的危险阶段是有效状态，不制造倒计时。
-- 到零、读错或样本过期不推测下个阶段。五秒采样恢复后由同一 Authority 重新投影。
function A:GetZoneView(zoneId)
    local state=tonumber(self.zoneStates[zoneId])
    local view=state and ZONE_VIEW[state] or nil
    if not view then return "状态未知","muted",true,false end
    if not self:IsZoneFresh(zoneId) then return view.text.." ·已过期","muted",true,false end
    local remain=self:GetZoneRemainSeconds(zoneId)
    if view.timed then
        if remain == nil then return view.text.." ·等待计时",view.tone,true,false end
        if remain <= 0 then return view.text.." ·等待更新",view.tone,true,false end
        return view.text.." "..FormatCountdown(remain),view.tone,false,true
    end
    return view.text,view.tone,true,true
end

function A:ScanZone(zoneId)
    zoneId = tonumber(zoneId)
    if zoneId == nil then return false end
    if X2Map == nil or S.Api == nil or type(S.Api.CallCapability) ~= "function" then return false end
    local ok, info = S.Api:CallCapability("X2Map:GetZoneStateInfoByZoneId", X2Map, "GetZoneStateInfoByZoneId", zoneId)
    if not ok or type(info) ~= "table" or tonumber(info.conflictState) == nil then
        self.zoneScanFailures = (tonumber(self.zoneScanFailures) or 0) + 1
        return false
    end
    local state=Integer(info.conflictState,0,7)
    if state == nil then self.zoneScanFailures=(self.zoneScanFailures or 0)+1;return false end
    self.zoneStates[zoneId] = state
    local remain = tonumber(info.remainTime)
    if remain == nil or remain ~= remain or remain < 0 or remain == math.huge then remain=nil end
    self.zoneRemainSeconds[zoneId] = remain ~= nil and math.floor(remain) or nil
    -- 阶段有效性不依赖剩余秒数：危险阶段本来没有计时；战争返回无效计时也仍是已观察的阶段。
    -- 有效 conflictState 更新观察时间，remain 独立保留 nil，投影明确显示“等待计时”。
    self.zoneObservedAtMs[zoneId] = self:NowMs()
    return true
end

function A:ScanTrackedZones()
    local scanned, changed = {}, false
    for _, definition in ipairs(S.Data and S.Data.ZoneStateWatch or {}) do
        local zoneId = tonumber(definition.zoneId)
        if zoneId ~= nil then
            scanned[zoneId] = true
            if self:ScanZone(zoneId) then changed = true end
        end
    end
    for zoneId in pairs(S.Data and S.Data.DynamicEventZones or {}) do
        zoneId = tonumber(zoneId)
        if zoneId ~= nil and scanned[zoneId] ~= true then
            if self:ScanZone(zoneId) then changed = true end
        end
    end
    self.lastZoneScanAtMs = self:NowMs()
    return changed
end

function A:BuildZoneRows()
    -- 区域行只描述当前阶段；可确定的活动时间由 BuildDynamicTimelineRows 另建 occurrence，共用同一采样事实。
    local rows = {}
    local liveOrder = 0
    for _, definition in ipairs(S.Data and S.Data.ZoneStateWatch or {}) do
        liveOrder = liveOrder + 1
        local zoneId = tonumber(definition.zoneId)
        local state = zoneId and tonumber(self.zoneStates[zoneId]) or nil
        local remain = zoneId and self:GetZoneRemainSeconds(zoneId) or nil
        local view = state ~= nil and ZONE_VIEW[state] or nil
        local status,tone,untimed,fresh=self:GetZoneView(zoneId)
        local active = fresh and (state == ZONE_STATE.BATTLE or state == ZONE_STATE.WAR)

        local dynamic = S.Data and S.Data.DynamicEventZones and S.Data.DynamicEventZones[zoneId] or nil
        local row = {
            key = "zone:" .. tostring(zoneId),
            name = tostring(definition.name or definition.sourceName or ("区域 " .. tostring(zoneId))),
            fullName = tostring(definition.fullName or definition.name or definition.sourceName or ("区域 " .. tostring(zoneId))),
            shortName = tostring(definition.stripName or definition.name or zoneId),
            microName = tostring(definition.stripName or definition.name or zoneId),
            kind = "zone",
            source = "live",
            presentationSection = "live",
            liveOrder = liveOrder,
            zoneState = true,
            zoneId = zoneId,
            phaseKnown = view ~= nil and self:IsZoneFresh(zoneId),
            questScope = definition.questScope or (dynamic and dynamic.questScope),
            questKey = definition.questKey or (dynamic and dynamic.questKey),
            active = active,
            seconds = untimed and nil or remain,
            sortSeconds = untimed and math.huge or remain, -- 兼容诊断字段；v2 不用它与 timeline 比较。
            tone = tone,
            status = status,
            scheduleText = "实时区域",
            untimed = untimed,
        }
        self:AttachProgress(row)
        rows[#rows + 1] = row
    end

    -- 庭院 WAR 前用 zone 133 remainTime 显示战争开始倒计时，进入 WAR 后只保留 live 行，避免重复。
    -- 不自行制造 1h50m 时长；保留历史 key zone:133:garden_boss，短暂 stale 时保留 WAR 行等待更新。
    local garden = S.Data and S.Data.DynamicEventZones and S.Data.DynamicEventZones[133] or nil
    if garden ~= nil then
        local state, remain = tonumber(self.zoneStates[133]), self:GetZoneRemainSeconds(133)
        if state == ZONE_STATE.WAR then
            local view = ZONE_VIEW[state]
            local status,tone,untimed,fresh=self:GetZoneView(133)
            local row = {
                key = "zone:133:garden_boss",
                name = tostring(garden.name or "庭院Boss"),
                fullName = tostring(garden.fullName or garden.name or "庭院Boss"),
                shortName = tostring(garden.shortName or "庭院"),
                microName = tostring(garden.microName or "庭院"),
                kind = "zone", source = "live", presentationSection = "live", liveOrder = liveOrder + 1,
                zoneState = true, zoneId = 133, phaseKnown = view ~= nil and self:IsZoneFresh(133),
                questScope = garden.questScope, questKey = garden.questKey,
                active = fresh,
                seconds = untimed and nil or remain, sortSeconds = untimed and math.huge or remain,
                tone = tone, status = status, scheduleText = "实时区域", untimed = untimed,
            }
            -- live 庭院也调用 AttachProgress，才能显示/点击精灵委托；只用 QuestProgress 副本，任务进度不决定区域阶段。
            self:AttachProgress(row)
            rows[#rows + 1] = row
        end
    end
    return rows
end

local function MakeDynamicOccurrence(options)
    options = type(options) == "table" and options or {}
    local active = options.active == true
    local seconds = math.max(0, math.floor(tonumber(options.seconds) or 0))
    local status = active and ("预计"..FormatCountdown(seconds).."后结束") or (FormatCountdown(seconds).."后开始")
    -- 鲸鱼 Boss 行回答“何时出现”；到点后的短提示窗口不是 Boss 存活时间，不能写成“后结束”。
    if options.phase == "spawn_countdown" then
        status = tostring(math.ceil(seconds / 60)) .. "分钟后出怪"
    elseif options.phase == "spawn_active" then
        local elapsedMinutes = math.floor(math.max(0, tonumber(options.elapsedSeconds) or 0) / 60)
        status = elapsedMinutes > 0 and ("已出怪" .. tostring(elapsedMinutes) .. "分钟") or "已经出怪"
    elseif options.phase == "boss_countdown" then
        status = tostring(math.ceil(seconds / 60)) .. "分钟后出现" -- 不足一分钟仍显示 1 分钟，避免尚未到点就显示 0。
    elseif options.phase == "boss_active" then
        status = "已到预计出现时间"
    end
    return {
        key = tostring(options.key or "dynamic:unknown"),
        name = tostring(options.name or "活动"),
        fullName = tostring(options.fullName or options.name or "活动"),
        shortName = tostring(options.shortName or options.name or "活动"),
        microName = tostring(options.microName or options.shortName or options.name or "活动"),
        kind = "dynamic_occurrence",
        source = "live-derived",
        presentationSection = "timeline",
        timelineState = active and "active" or "upcoming",
        derivedFromZoneId = tonumber(options.zoneId),
        zoneId = tonumber(options.zoneId),
        questScope = options.questScope,
        questKey = options.questKey,
        active = active,
        seconds = seconds,
        secondsUntilStart = active and 0 or seconds,
        secondsUntilEnd = active and seconds or nil,
        sortSeconds = active and 0 or seconds,
        -- 区域派生活动进入 timeline 后也遵循 TimelineTone，不沿用 live 的原始 tone。
        tone = TimelineTone(active, active and 0 or seconds),
        -- 普通活动继续表达开始/计划结束方向；首领出现提示使用上方显式 phase 文案。
        status = status,
        scheduleText = "实时推导",
        occurrenceKey = tostring(options.key or "dynamic:unknown") .. ":" .. tostring(options.phase or "derived"),
    }
end

function A:BuildDynamicTimelineRows()
    -- 只用已采样 zoneStates/remainTime，不额外读 Native；能唯一推导秒数才进入 timeline。
    -- 新时间规则须写入 data/rs_event_data.lua，不能从 UI 名称猜。
    local rows = {}
    -- 计时归零只代表旧阶段计时耗尽，不代表新阶段已经生效。必须等下一份区域事实。
    -- 这项约束作用于所有实时推导；不能将 0 秒伪装成即将开场并置顶。
    local function append(row)
        if type(row) ~= "table" or IsHidden(row) == true then return end
        self:AttachProgress(row)
        rows[#rows + 1] = row
    end

    -- BATTLE remainTime 可确定净化开始，复用 5s snapshot 构造 upcoming。进入 WAR 后不能凭观察时刻造 15 分钟计时；须等服务器结束时间证据。
    for _, zoneId in ipairs({ 20, 17 }) do
        local definition = S.Data and S.Data.ZoneStateWatchById and S.Data.ZoneStateWatchById[zoneId] or nil
        local state, remain = tonumber(self.zoneStates[zoneId]), self:GetZoneRemainSeconds(zoneId)
        if type(definition) == "table" and state == ZONE_STATE.BATTLE and remain ~= nil and remain > 0 then
            local short = tostring(definition.stripName or definition.name or zoneId)
            append(MakeDynamicOccurrence({
                key = zoneId == 20 and "dynamic:zone:20:cinderstone_purify" or "dynamic:zone:17:ynystere_purify",
                name = short .. "净化",
                fullName = tostring(definition.fullName or definition.name or short) .. "净化",
                shortName = short .. "净化", microName = short .. "净化", zoneId = zoneId,
                questScope = definition.questScope, questKey = definition.questKey,
                seconds = remain, active = false, phase = "battle_to_purification",
            }))
        end
    end

    local aegis = S.Data and S.Data.DynamicEventZones and S.Data.DynamicEventZones[102] or nil
    if aegis ~= nil then
        local state, remain = tonumber(self.zoneStates[102]), self:GetZoneRemainSeconds(102)
        local spawnThreshold = math.max(0, tonumber(aegis.spawnWarRemainMinutes) or 84) * 60
        local displaySeconds = math.max(0, tonumber(aegis.spawnDisplayMinutes) or 10) * 60
        local seconds, active, phase, elapsed = nil, false, nil, nil
        -- 出怪时刻与已过时间都从当前战争剩余秒数推导；中途进入/重载不能重新起算十分钟。
        if remain ~= nil and remain > 0 and state == ZONE_STATE.BATTLE then
            local total = math.max(0, tonumber(aegis.warTotalMinutes) or 90) * 60
            seconds, phase = remain + math.max(0, total - spawnThreshold), "spawn_countdown"
        elseif remain ~= nil and remain > 0 and state == ZONE_STATE.WAR then
            local endThreshold = math.max(0, spawnThreshold - displaySeconds)
            if remain > spawnThreshold then
                seconds, phase = remain - spawnThreshold, "spawn_countdown"
            elseif remain > endThreshold then
                seconds, active, phase = remain - endThreshold, true, "spawn_active"
                elapsed = spawnThreshold - remain
            end
        end
        if seconds ~= nil then
            append(MakeDynamicOccurrence({
                key = "dynamic:zone:102:aegis", name = aegis.name or "海之烛台", fullName = aegis.fullName or aegis.name,
                shortName = aegis.shortName or "烛台", microName = aegis.microName or "烛台", zoneId = 102,
                questScope = aegis.questScope, questKey = aegis.questKey,
                seconds = seconds, active = active, phase = phase, elapsedSeconds = elapsed,
            }))
        end
    end

    local whalesong = S.Data and S.Data.DynamicEventZones and S.Data.DynamicEventZones[103] or nil
    if whalesong ~= nil then
        -- 鲸鱼 Boss 的刷新点必须只来自 data Authority 中的战争剩余阈值。
        -- 旧 76m 在 RU 实机晚约 1 分钟，现校正为 77m；本层不再叠加额外“经验补偿”，
        -- 避免以后数据阈值与 Presentation 各自补偿造成双重偏移。
        local state, remain = tonumber(self.zoneStates[103]), self:GetZoneRemainSeconds(103)
        if remain ~= nil and state == ZONE_STATE.WAR then
            local threshold = math.max(0, tonumber(whalesong.bossWarRemainMinutes) or 77) * 60
            local activeUntil = math.max(0, tonumber(whalesong.bossActiveUntilWarRemainMinutes) or 76) * 60
            local bossName = tostring(whalesong.bossLabel or "Boss")
            if remain > threshold then
                append(MakeDynamicOccurrence({
                    key = "dynamic:zone:103:whalesong_boss", name = tostring(whalesong.shortName or "鲸鱼") .. " " .. bossName,
                    fullName = tostring(whalesong.fullName or whalesong.name or "鲸鱼歌湾") .. " " .. bossName,
                    shortName = tostring(whalesong.shortName or "鲸鱼") .. " " .. bossName, microName = "鲸鱼Boss", zoneId = 103,
                    questScope = whalesong.questScope, questKey = whalesong.questKey, seconds = remain - threshold, active = false, phase = "boss_countdown",
                }))
            elseif remain > activeUntil then
                append(MakeDynamicOccurrence({
                    key = "dynamic:zone:103:whalesong_boss", name = tostring(whalesong.shortName or "鲸鱼") .. " " .. bossName,
                    fullName = tostring(whalesong.fullName or whalesong.name or "鲸鱼歌湾") .. " " .. bossName,
                    shortName = tostring(whalesong.shortName or "鲸鱼") .. " " .. bossName, microName = "鲸鱼Boss", zoneId = 103,
                    questScope = whalesong.questScope, questKey = whalesong.questKey, seconds = remain - activeUntil, active = true, phase = "boss_active",
                }))
            end
        end
    end

    local garden = S.Data and S.Data.DynamicEventZones and S.Data.DynamicEventZones[133] or nil
    if garden ~= nil then
        local state, remain = tonumber(self.zoneStates[133]), self:GetZoneRemainSeconds(133)
        local seconds, active, phase = nil, false, nil
        if remain ~= nil and remain > 0 and state == ZONE_STATE.PEACE then
            seconds = remain + math.max(0, tonumber(garden.conflictLeadMinutes) or 10) * 60
            phase = "peace_to_war"
        elseif remain ~= nil and remain > 0 and state == ZONE_STATE.BATTLE then
            seconds, phase = remain, "battle_to_war"
        -- WAR 已经是实时事实，不能再生成 active timeline occurrence。
        -- 进入 WAR 后由 BuildZoneRows 独占显示；只有 PEACE/BATTLE 才保留“多久后进入战争”的活动时间倒计时。
        end
        if seconds ~= nil then
            append(MakeDynamicOccurrence({
                key = "dynamic:zone:133:garden_boss", name = garden.name or "庭院Boss", fullName = garden.fullName or garden.name,
                shortName = garden.shortName or "庭院", microName = garden.microName or "庭院", zoneId = 133,
                questScope = garden.questScope, questKey = garden.questKey, seconds = seconds, active = active, phase = phase,
            }))
        end
    end
    return rows
end

local function SortTimelineRows(a, b)
    local aState, aSeconds = TimelineSortParts(a)
    local bState, bSeconds = TimelineSortParts(b)
    if aState ~= bState then return aState < bState end
    if aSeconds ~= bSeconds then return aSeconds < bSeconds end
    local aSource = tostring(a.source or "") == "live-derived" and 0 or 1
    local bSource = tostring(b.source or "") == "live-derived" and 0 or 1
    if aSource ~= bSource then return aSource < bSource end
    local aName, bName = tostring(a.name or ""), tostring(b.name or "")
    if aName ~= bName then return aName < bName end
    return tostring(a.scheduleText or "") < tostring(b.scheduleText or "")
end

local function SortLiveRows(a, b)
    -- Live section 是状态面板，不是时间线。使用 data/rs_event_data.lua 的 curated 顺序作为稳定 Authority；
    -- remainTime 只显示，不参与行位置，避免“战争剩 59m”每秒在区域列表里和别的阶段互换。
    local ao, bo = tonumber(a.liveOrder) or math.huge, tonumber(b.liveOrder) or math.huge
    if ao ~= bo then return ao < bo end
    local az, bz = tonumber(a.zoneId) or math.huge, tonumber(b.zoneId) or math.huge
    if az ~= bz then return az < bz end
    return tostring(a.name or "") < tostring(b.name or "")
end

function A:Refresh(reason)
    self:SyncClock(false)

    -- timeline/live 分别构建排序后同 revision 原子替换，避免界面混看两代。区域每 5s 采样，时钟每 15s 最多读取一次，失败也限流。
    local timeline = self:BuildStaticRows()
    local dynamic = self:BuildDynamicTimelineRows()
    for _, row in ipairs(dynamic) do timeline[#timeline + 1] = row end
    table.sort(timeline, SortTimelineRows)

    -- 显示偏好按稳定区域 key 过滤，保留原有时间线/区域独立排序与共享 5s 采样。
    -- 不删 Zone Authority facts；取消关注只影响投影，恢复时仍能由完整静态目录找到。
    local live = {}
    for _, row in ipairs(self:BuildZoneRows()) do if not IsHidden(row) then live[#live+1]=row end end
    table.sort(live, SortLiveRows)

    local rows = {}
    for _, row in ipairs(timeline) do rows[#rows + 1] = row end
    for _, row in ipairs(live) do rows[#rows + 1] = row end

    local byKey = {}
    for _, row in ipairs(rows) do byKey[row.key] = row end
    self.timelineRows, self.liveRows = timeline, live
    self.rows, self.rowByKey = rows, byKey
    self.revision = (tonumber(self.revision) or 0) + 1
    self.updatedAtMs = self:NowMs()
    self.lastReason = tostring(reason or "refresh")
    if S.Events ~= nil and type(S.Events.Publish) == "function" then
        S.Events:Publish("v3.activities.updated", self.revision, self.lastReason)
    end
    return true
end

function A:GetRows()
    return self.rows, self.revision
end

function A:GetTimelineRows()
    return self.timelineRows, self.revision
end

function A:GetLiveRows()
    return self.liveRows, self.revision
end

function A:GetRow(key)
    return self.rowByKey[tostring(key or "")]
end

function A:GetWidgetRows(limit)
    limit = math.max(1, math.floor(tonumber(limit) or 8))
    local rows = {}
    for _, row in ipairs(self.rows) do
        rows[#rows + 1] = row
        if #rows >= limit then break end
    end
    return rows, self.revision
end

function A:GetSummary()
    local timelineActive, liveActive, soon = 0, 0, 0
    for _, row in ipairs(self.timelineRows or {}) do
        if row.timelineState == "active" or row.active == true then
            timelineActive = timelineActive + 1
        else
            local seconds = tonumber(row.secondsUntilStart) or tonumber(row.seconds)
            if seconds ~= nil and seconds <= 2 * 60 * 60 then soon = soon + 1 end
        end
    end
    for _, row in ipairs(self.liveRows or {}) do
        if row.active == true then liveActive = liveActive + 1 end
    end
    local hidden = 0
    for _, value in pairs(Feature.State and Feature.State.hiddenEvents or {}) do if value == true then hidden = hidden + 1 end end
    return {
        revision = self.revision,
        total = #(self.rows or {}),
        active = timelineActive + liveActive, -- 历史兼容字段；新 UI 使用 timelineActive/liveActive 分离语义。
        timelineActive = timelineActive,
        liveActive = liveActive,
        timelineTotal = #(self.timelineRows or {}),
        withinTwoHours = soon,
        liveZones = #(self.liveRows or {}),
        hidden = hidden,
        updatedAtMs = self.updatedAtMs,
        zoneScanFailures = self.zoneScanFailures,
        progressAuthority = self.questProgressProvider ~= nil or self.instanceProgressProvider ~= nil,
        timelineContractVersion = self.ActivityTimelineSortContractVersion,
    }
end

function A:HideEvent(key)
    local row = self:GetRow(key)
    if row == nil then return false, "event unavailable" end
    local hiddenKey = HiddenKey(row)
    if hiddenKey == "" then return false, "event key unavailable" end
    if type(Feature.MutateStore) ~= "function" then return false, "activity persistence transaction unavailable" end
    local marked, markErr = Feature:MutateStore(function()
        Feature.State.hiddenEvents = type(Feature.State.hiddenEvents) == "table" and Feature.State.hiddenEvents or {}
        Feature.State.hiddenEvents[hiddenKey] = true
        return true
    end, 200, "hide_event")
    if marked ~= true then return false, markErr or "隐藏活动未保存，已回滚" end
    return self:Refresh("hide_event")
end

function A:RestoreHiddenEvents()
    if type(Feature.MutateStore) ~= "function" then return false, "activity persistence transaction unavailable" end
    local marked, markErr = Feature:MutateStore(function() Feature.State.hiddenEvents = {}; return true end, 200, "restore_events")
    if marked ~= true then return false, markErr or "恢复活动未保存，已回滚" end
    return self:Refresh("restore_hidden")
end

function A:ResetTransient()
    self.compiledSchedules = nil -- 进入世界/重置释放静态编译缓存，允许同代目录原地调整后显式重建。
    self.zoneStates, self.zoneRemainSeconds, self.zoneObservedAtMs = {}, {}, {}
    self.clockAnchor = nil
    self.lastClockSampleAtMs = -1
    self.lastClockValidAtMs,self.lastClockSample,self.clockError=nil,nil,nil
    self.clockSampleFailures=0
    self.lastZoneScanAtMs = -1
end

-- 静态关注目录不依赖 occurrence，未发生/隐藏项也能恢复；旧 fullName 键不改，实时区域用稳定 row.key。
function A:GetAttentionCatalog()
    local rows, seen = {}, {}
    local function Add(id, name, category)
        id=tostring(id or ""); if id=="" or seen[id] then return end
        seen[id]=true; rows[#rows+1]={id=id,key=id,name=tostring(name or id),category=category,
            tracked=not (Feature.State and Feature.State.hiddenEvents and Feature.State.hiddenEvents[id]),
            fullName=id,zoneState=category=="区域状态"}
    end
    for _, event in ipairs(S.Data and S.Data.RuEvents or {}) do
        local name=event.fullName or event.name; Add(name,name,"计划活动")
    end
    for _, definition in ipairs(S.Data and S.Data.ZoneStateWatch or {}) do
        local id=tonumber(definition.zoneId)
        Add("zone:"..tostring(id),definition.fullName or definition.name,"区域状态")
        if id==20 or id==17 then local name=tostring(definition.fullName or definition.name or id).."净化"; Add(name,name,"动态活动") end
    end
    for _, id in ipairs({102,103,133}) do
        local definition=S.Data and S.Data.DynamicEventZones and S.Data.DynamicEventZones[id]
        if definition then
            local name=tostring(definition.fullName or definition.name or id)
            if id==103 then name=name.." "..tostring(definition.bossLabel or "Boss") end
            Add(name,name,"动态活动")
            if id==133 then Add("zone:133:garden_boss",definition.fullName or definition.name,"区域状态") end
        end
    end
    return rows
end
