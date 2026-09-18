------------------------------------------------------------------------
-- Replicated Suite V3 - Activity Authority
--
-- First migrated gameplay Authority in the V3 rebuild.
--
-- Authority boundaries:
--   * Curated schedule: data/rs_event_data.lua
--   * Server wall clock: UIParent:GetServerTimeTable() sampled at low frequency
--   * Live region phase: X2Map:GetZoneStateInfoByZoneId() every 5s while there
--     is an active Activity consumer (page/widget)
--   * Quest/instance progress: explicit future provider contracts; this file
--     never revives Legacy QuestService or Legacy State.
--
-- Performance:
--   * No independent OnUpdate.
--   * No API calls in the 1s countdown projection pass.
--   * Static schedule is grouped to one visible row per semantic activity.
------------------------------------------------------------------------
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
A.ActivityTimelineSortContractVersion = 2
A.PriorityStageSortContractVersion = 1 -- 兼容只读标记：旧 v1 分带已经退役，保留字段仅防止历史诊断/脚本因 nil 误判。
-- 中文维护注释（2026-09-18，Activity Timeline v2）：
-- 原 v1 把“计划活动时间”和“实时区域阶段”塞进同一 comparator，再用 <=3h / 鲸鱼烛台 / >3h 的业务分带补偿，
-- 结果虽然可控，却不是玩家理解的时间线：一个“危险3阶段”没有可比较的开始时间，却会插进 2h40m 与 3h10m 之间。
-- v2 的 Authority 边界改为两类投影：
--   1) timeline：只有能得到明确开始/结束时间的计划活动或 live-derived occurrence；active 按剩余结束时间，upcoming 按距离开始时间。
--   2) live：只描述战争/纷争/和平/危险阶段，按 curated ZoneStateWatch 顺序稳定展示，绝不与 timeline 比较。
-- 数据流仍是 CuratedSchedule + X2Map transient facts -> Activity Authority；不增加 Tick、不改变 QuestProgress/Store Authority。
-- 后续维护禁止重新引入“阶段权重/3小时阈值”把 live row 插回 timeline；若某实时状态可以确定地推导出时间点，应新建 dynamic occurrence，
-- 并同时保留原 live state row。不能根据名称或阶段猜测时间，也不能把实时区域颜色传播到 timeline 倒计时。

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
    if y == nil or m == nil or d == nil then return nil end
    y, m, d = math.floor(y), math.floor(m), math.floor(d)
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

local function WeekSecondsFromServerTime(now)
    if type(now) ~= "table" then return nil end
    local day = S.Utils and type(S.Utils.DayOfWeek) == "function" and S.Utils.DayOfWeek(now.year, now.month, now.day) or nil
    if tonumber(day) == nil then return nil end
    local hour = tonumber(now.hour) or 0
    local minute = tonumber(now.minute or now.min) or 0
    local second = tonumber(now.second or now.sec) or 0
    return NormalizeWeekSeconds(((day - 1) * DAY_SECONDS) + hour * 3600 + minute * 60 + second)
end

local function DaySecondsFromServerTime(now)
    if type(now) ~= "table" then return nil end
    local hour = tonumber(now.hour) or 0
    local minute = tonumber(now.minute or now.min) or 0
    local second = tonumber(now.second or now.sec) or 0
    return hour * 3600 + minute * 60 + second
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
    return tostring(row.fullName or row.name or "")
end

local function IsHidden(row)
    if type(row) ~= "table" or row.zoneState == true then return false end
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

function A:SyncClock(force)
    local nowMs = self:NowMs()
    if force ~= true and self.clockAnchor ~= nil and self.lastClockSampleAtMs >= 0 and nowMs - self.lastClockSampleAtMs < CLOCK_SAMPLE_MS then
        return true
    end
    local sampled = S.Utils and type(S.Utils.GetServerTime) == "function" and S.Utils.GetServerTime() or nil
    local weekSeconds = WeekSecondsFromServerTime(sampled)
    if weekSeconds == nil then return self.clockAnchor ~= nil end
    self.lastClockSampleAtMs = nowMs
    self.clockAnchor = {
        weekSeconds = weekSeconds,
        atMs = nowMs,
        dateSerial = DateSerial(sampled.year, sampled.month, sampled.day),
        daySeconds = DaySecondsFromServerTime(sampled),
    }
    return true
end

function A:GetWeekSeconds()
    if self:SyncClock(false) ~= true or self.clockAnchor == nil then return nil end
    local elapsed = math.max(0, (self:NowMs() - (tonumber(self.clockAnchor.atMs) or 0)) / 1000)
    return NormalizeWeekSeconds((tonumber(self.clockAnchor.weekSeconds) or 0) + elapsed)
end

function A:GetDateSerial()
    if self:SyncClock(false) ~= true or self.clockAnchor == nil then return nil end
    local baseDate = tonumber(self.clockAnchor.dateSerial)
    local baseSeconds = tonumber(self.clockAnchor.daySeconds)
    if baseDate == nil or baseSeconds == nil then return nil end
    local elapsed = math.max(0, (self:NowMs() - (tonumber(self.clockAnchor.atMs) or 0)) / 1000)
    return baseDate + math.floor((baseSeconds + elapsed) / DAY_SECONDS)
end

local function TimelineSortParts(row)
    -- 中文维护注释（Activity Timeline v2）：timelineState 是时间排序的唯一语义 Authority。
    -- active 使用 secondsUntilEnd，upcoming 使用 secondsUntilStart；兼容旧/测试行时才回退 active/seconds/sortSeconds。
    -- 不读取 zoneState/tone/name 来推导时间状态，避免 Presentation 语义反向污染 Domain 排序。
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

function A:BuildStaticRows()
    local now = self:GetWeekSeconds()
    if now == nil then return {} end
    local currentDateSerial = self:GetDateSerial()
    local grouped = {}

    for _, event in ipairs(S.Data and S.Data.RuEvents or {}) do
        if EventDateEnabled(event, currentDateSerial) then
            local best = nil
            local duration = math.max(0, tonumber(event.duration) or 0) * 60
            -- 中文维护注释：支持活动 taskTailMinutes 后续任务保持期（如征兆之痕90分钟、煦日120分钟）。
            -- 当玩家身上已接受或待交后续 Boss/恶魔阶段任务（tailInFlightCount > 0）时，
            -- 即使首个计划时长（如10分钟）已过，仍将当期活动保持为“进行中”，防止在击杀过程中倒计时过早跳到 4 小时后的下一次。
            local taskTailMinutes = tonumber(event.taskTailMinutes)
            local tailDuration = taskTailMinutes and math.max(duration, taskTailMinutes * 60) or duration
            local progressSnapshot = (taskTailMinutes ~= nil and event.questKey ~= nil and type(self.questProgressProvider) == "function")
                and self.questProgressProvider(event.questScope or "event", event.questKey) or nil
            local tailInFlight = type(progressSnapshot) == "table" and (tonumber(progressSnapshot.tailInFlightCount) or 0) > 0

            for day = 1, 7 do
                if HasDay(event.days, day) then
                    local start = ((day - 1) * DAY_SECONDS) + (tonumber(event.hour) or 0) * 3600 + (tonumber(event.minute) or 0) * 60
                    local elapsed = NormalizeWeekSeconds(now - start)
                    local baseActive = duration > 0 and elapsed < duration
                    local tailActive = tailInFlight and (elapsed >= duration and elapsed < tailDuration)
                    local active = baseActive or tailActive
                    local seconds
                    if baseActive then
                        seconds = math.max(0, math.floor(duration - elapsed))
                    elseif tailActive then
                        seconds = math.max(0, math.floor(tailDuration - elapsed))
                    else
                        seconds = math.max(0, math.floor(NormalizeWeekSeconds(start - now)))
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
                        -- 中文维护注释（2026-09-15，活动显示规范）：计划活动的 active 只负责排序/任务尾部保持，
                        -- 不再承担视觉颜色或“进行中”文案。普通时间统一用 default（白色）；战争/纷争/和平颜色
                        -- 只由实时区域状态 Authority 决定，避免同一个红色同时代表“活动正在发生”和“战争区域”。
                        -- 兼容边界：active/seconds/sortSeconds/occurrenceKey 均保持原语义，Store 与任务尾部逻辑不变。
                        tone = "default",
                        status = FormatCountdown(seconds),
                        scheduleText = FormatSchedule(day, event.hour, event.minute),
                        occurrenceKey = tostring(event.fullName or event.name) .. ":" .. tostring(day) .. ":" .. tostring(start),
                    }
                    if BetterOccurrence(candidate, best) then best = candidate end
                end
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

function A:GetZoneRemainSeconds(zoneId)
    zoneId = tonumber(zoneId)
    local sampled = zoneId and tonumber(self.zoneRemainSeconds[zoneId]) or nil
    if sampled == nil then return nil end
    local observed = tonumber(self.zoneObservedAtMs[zoneId]) or self:NowMs()
    local elapsed = math.max(0, math.floor((self:NowMs() - observed) / 1000))
    return math.max(0, math.floor(sampled) - elapsed)
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
    self.zoneStates[zoneId] = tonumber(info.conflictState)
    local remain = tonumber(info.remainTime)
    self.zoneRemainSeconds[zoneId] = remain ~= nil and math.max(0, math.floor(remain)) or nil
    self.zoneObservedAtMs[zoneId] = remain ~= nil and self:NowMs() or nil
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
    -- 中文维护注释（2026-09-18，Activity Timeline v2 / Live Authority）：
    -- 这里的 row 只描述“区域现在是什么状态”，不再承载 Boss/活动开始时间。旧实现会把 102/103 的 Boss 文案写回 zone row，
    -- 然后再拿 remainTime 与计划活动排序，造成 live state 与 timeline 语义混用。现在战争/纷争/和平/危险阶段永远留在 live section；
    -- 能从这些状态确定性推导出来的活动时间由 BuildDynamicTimelineRows 另建 occurrence。这样同一 Native 事实可以有两个只读投影，
    -- 但 Authority 仍然只有本 Activity Authority，不增加第二套扫描/缓存/持久化。
    local rows = {}
    local liveOrder = 0
    for _, definition in ipairs(S.Data and S.Data.ZoneStateWatch or {}) do
        liveOrder = liveOrder + 1
        local zoneId = tonumber(definition.zoneId)
        local state = zoneId and tonumber(self.zoneStates[zoneId]) or nil
        local remain = zoneId and self:GetZoneRemainSeconds(zoneId) or nil
        local view = state ~= nil and ZONE_VIEW[state] or nil
        local status = view and view.text or "状态未知"
        local tone = view and view.tone or "muted"
        local active = state == ZONE_STATE.BATTLE or state == ZONE_STATE.WAR
        local untimed = true
        if remain ~= nil and view ~= nil and view.timed == true then
            status = view.text .. " " .. FormatCountdown(remain)
            untimed = false
        end

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
            phaseKnown = view ~= nil,
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

    -- Garden 不是 ZoneStateWatch 的常驻四区之一，但 DynamicEventZones 已有独立 live Authority。
    -- 保留历史 key `zone:133:garden_boss` 兼容选择/诊断；语义改为 live state，真正的 Boss 时间线另由 dynamic occurrence 投影。
    local garden = S.Data and S.Data.DynamicEventZones and S.Data.DynamicEventZones[133] or nil
    if garden ~= nil then
        local state, remain = tonumber(self.zoneStates[133]), self:GetZoneRemainSeconds(133)
        if state ~= nil then
            local view = ZONE_VIEW[state]
            local status = view and view.text or "状态未知"
            local tone = view and view.tone or "muted"
            local untimed = true
            if remain ~= nil and view ~= nil and view.timed == true then
                status = view.text .. " " .. FormatCountdown(remain)
                untimed = false
            end
            rows[#rows + 1] = {
                key = "zone:133:garden_boss",
                name = tostring(garden.name or "庭院Boss"),
                fullName = tostring(garden.fullName or garden.name or "庭院Boss"),
                shortName = tostring(garden.shortName or "庭院"),
                microName = tostring(garden.microName or "庭院"),
                kind = "zone", source = "live", presentationSection = "live", liveOrder = liveOrder + 1,
                zoneState = true, zoneId = 133, phaseKnown = view ~= nil,
                active = state == ZONE_STATE.BATTLE or state == ZONE_STATE.WAR,
                seconds = untimed and nil or remain, sortSeconds = untimed and math.huge or remain,
                tone = tone, status = status, scheduleText = "实时区域", untimed = untimed,
                progressText = "--", progressTone = "muted", progressAvailable = false,
            }
        end
    end
    return rows
end

local function MakeDynamicOccurrence(options)
    options = type(options) == "table" and options or {}
    local active = options.active == true
    local seconds = math.max(0, math.floor(tonumber(options.seconds) or 0))
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
        -- Timeline 时间统一使用中性颜色。区域红/橙/蓝属于 live-state 语义，不能传播到时间点。
        tone = "default",
        status = FormatCountdown(seconds),
        scheduleText = "实时推导",
        occurrenceKey = tostring(options.key or "dynamic:unknown") .. ":" .. tostring(options.phase or "derived"),
    }
end

function A:BuildDynamicTimelineRows()
    -- 中文维护注释（Activity Timeline v2，动态 occurrence）：只使用已经由 X2Map Authority 采样并缓存的 zoneStates/remainTime，
    -- 本函数禁止再调用 Native API。只有“能由当前已知规则得到唯一秒数”的状态才进入 timeline；危险阶段等无确定时间的信息留在 live section。
    -- 未来新增规则必须把时间来源/阈值写进 data/rs_event_data.lua，禁止从 UI 文案或名称猜测。
    local rows = {}
    local function append(row)
        if type(row) ~= "table" or IsHidden(row) == true then return end
        self:AttachProgress(row)
        rows[#rows + 1] = row
    end

    -- 中文维护注释（十字星/伊尼斯净化）：RU 客户端在 BATTLE 阶段提供 remainTime，参考 timeUntil 也把该冲突窗口结束
    -- 视为净化开始；本项目只借鉴这个“可确定开始时间”的事实，用现有 5s Zone snapshot 构造 upcoming occurrence。
    -- 一旦进入 WAR，本 Authority 不凭观察时刻再制造“15分钟进行中”计时，因为那会把插件启动/事件到达时间错误提升为服务器 Authority。
    -- 若未来拿到官方/Native 的活动结束时间，再把 active 时长写入 data Authority；在此之前必须 fail-closed。
    for _, zoneId in ipairs({ 20, 17 }) do
        local definition = S.Data and S.Data.ZoneStateWatchById and S.Data.ZoneStateWatchById[zoneId] or nil
        local state, remain = tonumber(self.zoneStates[zoneId]), self:GetZoneRemainSeconds(zoneId)
        if type(definition) == "table" and state == ZONE_STATE.BATTLE and remain ~= nil then
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
        if remain ~= nil and state == ZONE_STATE.BATTLE then
            append(MakeDynamicOccurrence({
                key = "dynamic:zone:102:aegis", name = aegis.name or "海之烛台", fullName = aegis.fullName or aegis.name,
                shortName = aegis.shortName or "烛台", microName = aegis.microName or "烛台", zoneId = 102,
                questScope = aegis.questScope, questKey = aegis.questKey, seconds = remain, active = false, phase = "battle_to_war",
            }))
        elseif remain ~= nil and state == ZONE_STATE.WAR then
            local total = math.max(0, tonumber(aegis.warTotalMinutes) or 90)
            local activeMinutes = math.max(0, tonumber(aegis.activeWarMinutes) or 20)
            local endThreshold = math.max(0, total - activeMinutes) * 60
            if remain > endThreshold then
                append(MakeDynamicOccurrence({
                    key = "dynamic:zone:102:aegis", name = aegis.name or "海之烛台", fullName = aegis.fullName or aegis.name,
                    shortName = aegis.shortName or "烛台", microName = aegis.microName or "烛台", zoneId = 102,
                    questScope = aegis.questScope, questKey = aegis.questKey, seconds = remain - endThreshold, active = true, phase = "war_opening",
                }))
            end
        end
    end

    local whalesong = S.Data and S.Data.DynamicEventZones and S.Data.DynamicEventZones[103] or nil
    if whalesong ~= nil then
        local state, remain = tonumber(self.zoneStates[103]), self:GetZoneRemainSeconds(103)
        if remain ~= nil and state == ZONE_STATE.WAR then
            local threshold = math.max(0, tonumber(whalesong.bossWarRemainMinutes) or 76) * 60
            local activeUntil = math.max(0, tonumber(whalesong.bossActiveUntilWarRemainMinutes) or 75) * 60
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
        if remain ~= nil and state == ZONE_STATE.PEACE then
            seconds = remain + math.max(0, tonumber(garden.conflictLeadMinutes) or 10) * 60
            phase = "peace_to_war"
        elseif remain ~= nil and state == ZONE_STATE.BATTLE then
            seconds, phase = remain, "battle_to_war"
        elseif remain ~= nil and state == ZONE_STATE.WAR then
            seconds, active, phase = remain, true, "war_active"
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

    -- 中文维护注释（Activity Timeline v2 projection transaction）：一次 Refresh 内分别构建 timeline/live，
    -- 各自完成排序后再拼接，最后一次性替换 rows/rowByKey/revision。Presentation 因此永远看到同一 revision 的完整快照，
    -- 不会在 1s timer 中先看到新 timeline、后看到旧 live。动态 occurrence 只复用前一次 5s zone scan 的 transient facts，
    -- 所以本路径仍然没有 Native API 调用；性能模型保持“1s 纯投影 + 5s 区域采样”。
    local timeline = self:BuildStaticRows()
    local dynamic = self:BuildDynamicTimelineRows()
    for _, row in ipairs(dynamic) do timeline[#timeline + 1] = row end
    table.sort(timeline, SortTimelineRows)

    local live = self:BuildZoneRows()
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
    if row == nil or row.zoneState == true then return false, "live zone rows cannot be hidden" end
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
    self.zoneStates, self.zoneRemainSeconds, self.zoneObservedAtMs = {}, {}, {}
    self.clockAnchor = nil
    self.lastClockSampleAtMs = -1
    self.lastZoneScanAtMs = -1
end
