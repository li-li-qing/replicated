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
    version = 1,
    rows = {},
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
local PRIORITY_STAGE_THRESHOLD_SECONDS = 3 * 60 * 60
A.PriorityStageSortContractVersion = 1 -- 中文维护注释（2026-09-16，活动排序 Authority）：v1 固化“普通进行中 → 普通<=3h → 鲸鱼/烛台已知阶段 → 普通>3h → 其它无时限”的产品规则。这里只声明排序契约，不改变活动时间/阶段读取或 Store。

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

local function BetterOccurrence(candidate, existing)
    if existing == nil then return true end
    if candidate.active ~= existing.active then return candidate.active == true end
    local a = tonumber(candidate.sortSeconds) or math.huge
    local b = tonumber(existing.sortSeconds) or math.huge
    if a ~= b then return a < b end
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
                        questScope = event.questScope,
                        questKey = event.questKey,
                        active = active,
                        seconds = seconds,
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
    local rows = {}
    for _, definition in ipairs(S.Data and S.Data.ZoneStateWatch or {}) do
        local zoneId = tonumber(definition.zoneId)
        local state = zoneId and tonumber(self.zoneStates[zoneId]) or nil
        local remain = zoneId and self:GetZoneRemainSeconds(zoneId) or nil
        local view = state ~= nil and ZONE_VIEW[state] or nil
        local status = view and view.text or "状态未知"
        local tone = view and view.tone or "muted"
        local active = state == ZONE_STATE.BATTLE or state == ZONE_STATE.WAR
        local sortSeconds = math.huge
        local untimed = true

        if remain ~= nil and view ~= nil and view.timed == true then
            -- 中文维护注释（2026-09-15）：实时区域状态直接显示“战争/纷争/和平 + 时间”，
            -- active 继续作为内部排序/摘要事实，Presentation 不再把它拼成“进行中”。
            status = view.text .. " " .. FormatCountdown(remain)
            sortSeconds = remain
            untimed = false
        end

        local dynamic = S.Data and S.Data.DynamicEventZones and S.Data.DynamicEventZones[zoneId] or nil
        if zoneId == 102 and state == ZONE_STATE.BATTLE and remain ~= nil then
            status, active, sortSeconds, untimed = "纷争 " .. FormatCountdown(remain), false, remain, false
        elseif zoneId == 102 and state == ZONE_STATE.WAR and remain ~= nil then
            local total = math.max(0, tonumber(dynamic and dynamic.warTotalMinutes) or 90)
            local activeMinutes = math.max(0, tonumber(dynamic and dynamic.activeWarMinutes) or 20)
            active = remain > math.max(0, total - activeMinutes) * 60
            status = "战争 " .. FormatCountdown(remain)
        elseif zoneId == 103 and state == ZONE_STATE.BATTLE and remain ~= nil then
            status, active, sortSeconds, untimed = "纷争 " .. FormatCountdown(remain), false, remain, false
        elseif zoneId == 103 and state == ZONE_STATE.WAR and remain ~= nil then
            local threshold = math.max(0, tonumber(dynamic and dynamic.bossWarRemainMinutes) or 76) * 60
            local activeUntil = math.max(0, tonumber(dynamic and dynamic.bossActiveUntilWarRemainMinutes) or 75) * 60
            local boss = tostring(dynamic and dynamic.bossLabel or "首领")
            if remain > threshold then
                local bossRemain = remain - threshold
                -- 中文维护注释（2026-09-15，区域颜色 Authority）：此 Boss 倒计时仍处于 WAR conflictState，
                -- 因此颜色必须继续使用战争红色；Boss 文案只改变状态文字，不能覆盖区域语义颜色。
                -- 兼容边界：阈值、active、sortSeconds 与任务进度均保持原逻辑，仅修正 Presentation tone。
                status, tone, active, sortSeconds = boss .. " " .. FormatCountdown(bossRemain), "red", false, bossRemain
            elseif remain > activeUntil then
                status, tone, active, sortSeconds = boss, "red", true, 0
            else
                status, tone, active, sortSeconds = "战争 " .. FormatCountdown(remain), "red", false, remain
            end
            untimed = false
        end

        local row = {
            key = "zone:" .. tostring(zoneId),
            name = tostring(definition.name or definition.sourceName or ("区域 " .. tostring(zoneId))),
            fullName = tostring(definition.fullName or definition.name or definition.sourceName or ("区域 " .. tostring(zoneId))),
            shortName = tostring(definition.stripName or definition.name or zoneId),
            microName = tostring(definition.stripName or definition.name or zoneId),
            kind = "zone",
            source = "live",
            zoneState = true,
            zoneId = zoneId,
            -- 中文维护注释（2026-09-16，阶段排序事实）：phaseKnown 只表示本次 X2Map conflictState 能映射到已知区域阶段，
            -- 它属于 Activity Authority 的瞬时只读事实，用来区分“危险1~5/纷争/战争/和平”与真正的“状态未知”。
            -- 数据流只从 ScanZone -> ZONE_VIEW -> row 投影；不持久化、不影响任务进度。这样鲸鱼/烛台即使危险阶段没有 remainTime，
            -- 也能进入专用排序带；未知状态仍 fail-closed 留在末尾，避免把 API 失败误当成有效阶段。
            phaseKnown = view ~= nil,
            -- 中文维护注释：实时区域行优先从 definition 获取任务关联，同时回退到 DynamicEventZones 中的定义，
            -- 确保如鲸鱼歌湾（103）与海之烛台（102）能正确关联 whalesong 与 aegis 任务组并挂接阶段进度。
            questScope = definition.questScope or (dynamic and dynamic.questScope),
            questKey = definition.questKey or (dynamic and dynamic.questKey),
            active = active,
            seconds = untimed and nil or sortSeconds,
            sortSeconds = sortSeconds,
            tone = tone,
            status = status,
            scheduleText = "实时区域",
            untimed = untimed,
        }
        self:AttachProgress(row)
        rows[#rows + 1] = row
    end

    local garden = S.Data and S.Data.DynamicEventZones and S.Data.DynamicEventZones[133] or nil
    if garden ~= nil then
        local state, remain = tonumber(self.zoneStates[133]), self:GetZoneRemainSeconds(133)
        if state ~= nil and remain ~= nil then
            local status, tone, active, seconds = "状态未知", "muted", false, remain
            if state == ZONE_STATE.WAR then
                status, tone, active = "战争 " .. FormatCountdown(remain), "red", true
            elseif state == ZONE_STATE.BATTLE then
                status, tone = "纷争 " .. FormatCountdown(remain), "orange"
            elseif state == ZONE_STATE.PEACE then
                local lead = math.max(0, tonumber(garden.conflictLeadMinutes) or 10) * 60
                seconds = remain + lead
                status, tone = "距下次战争约 " .. FormatCountdown(seconds), "blue"
            else
                local view = ZONE_VIEW[state]
                status, tone = view and view.text or "状态未知", view and view.tone or "muted"
            end
            rows[#rows + 1] = {
                key = "zone:133:garden_boss", name = tostring(garden.name or "庭院首领"), fullName = tostring(garden.fullName or garden.name or "庭院首领"),
                shortName = tostring(garden.shortName or "庭院"), microName = tostring(garden.microName or "庭院"),
                kind = "zone", source = "live", zoneState = true, zoneId = 133,
                active = active, seconds = seconds, sortSeconds = active and 0 or seconds, tone = tone, status = status,
                scheduleText = "实时区域", progressText = "--", progressTone = "muted", progressAvailable = false,
            }
        end
    end
    return rows
end

local function IsPriorityLiveStage(row)
    local zoneId = tonumber(type(row) == "table" and row.zoneId or nil)
    return (zoneId == 102 or zoneId == 103) and row.phaseKnown == true
end

local function ActivitySortBand(row)
    local specialStage = IsPriorityLiveStage(row)
    local seconds = tonumber(type(row) == "table" and row.sortSeconds or nil)
    local timed = seconds ~= nil and seconds ~= math.huge
    -- 中文维护注释（2026-09-16，活动排序根因修复）：旧 SortRows 只比较 active/sortSeconds，导致鲸鱼/烛台
    -- 在战争阶段按 1h 倒计时插进普通 1~2h 活动前面，而危险阶段因为无倒计时又掉到所有长时活动之后。
    -- Authority 现在使用显式业务分带：普通进行中(0) → 普通<=3h(1) → 鲸鱼/烛台已知阶段(2) → 普通>3h(3) → 其它无时限/未知(4)。
    -- 特殊阶段必须在 active 判断之前归入 band=2，避免“活动阶段 active=true”再次抢到最前；恰好3小时仍属于用户定义的“3小时以内”。
    -- 兼容边界：不改 sortSeconds/active 的原始语义，也不影响十字星/伊尼斯/庭院等其它区域；同一 band 内仍沿用秒数、zoneState、名称稳定排序。
    if specialStage then return 2 end
    if type(row) == "table" and row.active == true then return 0 end
    if timed and seconds <= PRIORITY_STAGE_THRESHOLD_SECONDS then return 1 end
    if timed then return 3 end
    return 4
end

local function SortRows(a, b)
    local aBand, bBand = ActivitySortBand(a), ActivitySortBand(b)
    if aBand ~= bBand then return aBand < bBand end
    local sa, sb = tonumber(a.sortSeconds) or math.huge, tonumber(b.sortSeconds) or math.huge
    if sa ~= sb then return sa < sb end
    if a.zoneState ~= b.zoneState then return a.zoneState == true end
    return tostring(a.name) < tostring(b.name)
end

function A:Refresh(reason)
    self:SyncClock(false)
    local rows = self:BuildZoneRows()
    local static = self:BuildStaticRows()
    for _, row in ipairs(static) do rows[#rows + 1] = row end
    table.sort(rows, SortRows)

    local byKey = {}
    for _, row in ipairs(rows) do byKey[row.key] = row end
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
    local active, soon, live = 0, 0, 0
    for _, row in ipairs(self.rows) do
        if row.active == true then active = active + 1 end
        if row.zoneState == true then live = live + 1 end
        local seconds = tonumber(row.seconds)
        if row.active ~= true and seconds ~= nil and seconds <= 2 * 60 * 60 then soon = soon + 1 end
    end
    local hidden = 0
    for _, value in pairs(Feature.State and Feature.State.hiddenEvents or {}) do if value == true then hidden = hidden + 1 end end
    return {
        revision = self.revision,
        total = #self.rows,
        active = active,
        withinTwoHours = soon,
        liveZones = live,
        hidden = hidden,
        updatedAtMs = self.updatedAtMs,
        zoneScanFailures = self.zoneScanFailures,
        progressAuthority = self.questProgressProvider ~= nil or self.instanceProgressProvider ~= nil,
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
