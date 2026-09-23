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
--   * 1s projection; clock re-sampling is throttled to 15s (including failures).
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
local CLOCK_STALE_MS = 120000
local ZONE_STALE_MS = 20000
local TIMELINE_URGENT_SECONDS = 10 * 60

-- 中文维护注释（2026-09-19，活动临近开始红色提醒）：
-- 用户需要在活动密集列表中优先看到“10 分钟内即将开始”的项目，因此 timeline 颜色由 Authority 统一投影。
-- active 始终 red；upcoming 仅在 0 < secondsUntilStart <= 600 时 red，超过 10 分钟保持 default。
-- Presentation 不重复判断阈值，首页/活动页/悬浮窗消费同一个 row.tone；实时区域 ZONE_VIEW 的战争/纷争/和平配色完全独立。
-- 这里只做标量比较，不新增 Tick、Native 查询、缓存或 Store 字段。
local function TimelineTone(active, secondsUntilStart)
    if active == true then return "red" end
    local seconds = tonumber(secondsUntilStart)
    if seconds ~= nil and seconds > 0 and seconds <= TIMELINE_URGENT_SECONDS then return "red" end
    return "default"
end
-- 维护（activity-time-audit）：Native 样本有精度/有效期，不是无条件的事实。
-- 本 Authority 独占瞬态时钟与区域样本；所有界面只消费投影，不写业务存档。
-- 分钟精度的值代表一个 60 秒区间，不能每 15 秒重新当作 :00，否则 JMG 等所有活动倒计时回跳。
-- 只读诊断不采样；失败同样限流。保留现有采样频率，不增加 Tick/高频 API/持久化字段。
local function Integer(value, lo, hi)
    local n = tonumber(value)
    if n == nil or n ~= n or n == math.huge or n == -math.huge or n ~= math.floor(n) or n < lo or n > hi then return nil end
    return n
end
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
            -- 后续任务 provider 与普通进度同样隔离；一个任务读取失败不得中断 JMG/其他活动的整个投影。
            local progressSnapshot = nil
            if taskTailMinutes ~= nil and event.questKey ~= nil and type(self.questProgressProvider) == "function" then
                local ok, value = pcall(self.questProgressProvider,event.questScope or "event",event.questKey)
                if ok then progressSnapshot=value end
            end
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
                        seconds = math.max(0, math.ceil(NormalizeWeekSeconds(start - now)))
                    end

                    -- 每个 occurrence 都要校验日期；仅检查 today 会让限时活动在最后一天指向已结束的下一周。
                    local daySeconds = now % DAY_SECONDS
                    local occurrenceDate = currentDateSerial and (currentDateSerial+math.floor((daySeconds+(active and -elapsed or seconds))/DAY_SECONDS)) or nil
                    local confidence = event.scheduleConfidence or "curated"
                    local minutePrecision = self.clockAnchor and self.clockAnchor.precision == "minute"
                    -- 中文维护注释（2026-09-18，活动时间文案可读性）：
                    -- Authority 仍然只投影“静态日程 + 当前服务器钟”得到的计划窗口，不能把计划结束误写成首领实际存活时间。
                    -- 旧“计划余1分”属于内部术语，玩家无法判断是开始还是结束；因此 Presentation 字段改为方向明确的自然语言：
                    -- 秒级服务器钟使用“预计X后结束”，分钟级服务器钟使用“约X后结束”；尚未开始统一写“X后开始”。
                    -- 兼容边界：active/seconds/sortSeconds/taskTailActive/scheduleConfidence 均保持原语义，排序、Store、任务尾部逻辑不变。
                    local stateText
                    if tailActive then
                        stateText = "后续≤" .. FormatCountdown(seconds)
                    elseif active then
                        stateText = (minutePrecision and "约" or "预计") .. FormatCountdown(seconds) .. "后结束"
                    else
                        stateText = (minutePrecision and "约" or "") .. FormatCountdown(seconds) .. "后开始"
                    end
                    local endMinute = ((tonumber(event.hour) or 0)*60+(tonumber(event.minute) or 0)+duration/60)
                    local endText = string.format("%02d:%02d",math.floor(endMinute/60)%24,math.floor(endMinute)%60)
                    if endMinute >= 1440 then endText="次日 "..endText end
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
                        -- 中文维护注释（2026-09-18，活动进行中视觉状态）：
                        -- 用户需要在密集时间线里一眼识别“当前正在进行”的计划活动，因此 timeline active 统一使用 red。
                        -- Authority：颜色只由本 Activity Authority 根据现有 active 事实投影；Presentation 仅消费 row.tone，
                        -- 不重复判断时间窗口。数据流仍为日程/服务器钟 -> active -> tone，不新增 Tick、Native 查询或持久化字段。
                        -- 兼容边界：upcoming 仅在 10 分钟内切 red，超过 10 分钟仍为 default；实时区域仍由 ZONE_VIEW 自己决定红/橙/蓝，不复用 timeline 规则；
                        -- active/seconds/sortSeconds/occurrenceKey、排序、Store 与任务尾部语义全部保持不变。
                        tone = TimelineTone(active, active and 0 or seconds),
                        -- 中文维护注释（2026-09-19，隐藏内部可信度标签）：
                        -- scheduleConfidence / scheduleEvidence 是维护与诊断 Authority，不是玩家活动状态。旧版把 reference
                        -- 直接拼成“参考·X后开始 / ·参考”，普通用户无法理解，还会误把来源可信度当成活动阶段。
                        -- 因此 Presentation 字段只保留“何时开始/结束”及计划窗口；可信度元数据继续独立保存，供诊断和核对使用。
                        -- 兼容边界：不改变日程、排序、active/seconds、任务尾部、Store 或诊断证据；主页面/首页/悬浮窗共用此投影。
                        status = stateText,
                        scheduleText = FormatSchedule(day, event.hour, event.minute).." →计划 "..endText,
                        scheduleConfidence = confidence,
                        scheduleEvidence = event.scheduleEvidence or "existing RU curated table",
                        plannedDurationSeconds = duration,
                        taskTailActive = tailActive,
                        occurrenceKey = tostring(event.fullName or event.name) .. ":" .. tostring(day) .. ":" .. tostring(start),
                    }
                    if EventDateEnabled(event,occurrenceDate) and BetterOccurrence(candidate, best) then best = candidate end
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

    -- 中文维护注释（2026-09-19，Garden phase migration）：庭院是“同一事实、两个互斥投影”。
    -- WAR 之前，BuildDynamicTimelineRows 用 Native 区域 remainTime 投影“距离战争开始”的倒计时，方便玩家提前去庭院准备四个 Boss；
    -- 一旦 Native 明确进入 WAR，这条倒计时必须从 timeline 消失，并且这里只生成 live row。禁止同时保留两条“庭院”，否则小窗口会重复占位。
    -- Authority 仍然只有 zone 133 的 5s transient snapshot；这里不新增扫描、不本地制造 1h50m 计时，也不持久化区域阶段。
    -- 兼容边界：保留历史 key `zone:133:garden_boss`，避免关注/诊断引用失效；短暂 stale 时仍保留 WAR 行并由 GetZoneView 显示等待更新。
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
            -- 中文维护注释（2026-09-22，Garden score quest projection）：live 庭院行过去硬编码 progress=--，
            -- 导致即使 EventData 提供 Quest 映射，战争阶段也无法显示/点击“精灵的委托”。这里与其他活动
            -- 统一走 AttachProgress，只消费 QuestProgress detached snapshot；区域阶段和 Quest 状态仍是两个 Authority。
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
        -- 中文维护注释（2026-09-18，动态时间线进行中颜色）：
        -- live-derived occurrence 虽由区域事实推导，但进入 timeline 后仍遵循统一的“进行中=红色”视觉规则。
        -- 这里只消费已经计算出的 active/seconds，不把 live 区域的原始 tone 传播进来；upcoming 在 10 分钟内由统一 TimelineTone 标红，
        -- live 区域本身继续由 ZONE_VIEW 独立着色；不改变区域 Authority、扫描频率、排序或存档。
        tone = TimelineTone(active, active and 0 or seconds),
        -- 区域推导倒计时仍需明确方向；不将 Boss/战争计划窗口声称为存活事实。
        status = active and ("预计余"..FormatCountdown(seconds)) or (FormatCountdown(seconds).."后"),
        scheduleText = "实时推导",
        occurrenceKey = tostring(options.key or "dynamic:unknown") .. ":" .. tostring(options.phase or "derived"),
    }
end

function A:BuildDynamicTimelineRows()
    -- 中文维护注释（Activity Timeline v2，动态 occurrence）：只使用已经由 X2Map Authority 采样并缓存的 zoneStates/remainTime，
    -- 本函数禁止再调用 Native API。只有“能由当前已知规则得到唯一秒数”的状态才进入 timeline；危险阶段等无确定时间的信息留在 live section。
    -- 未来新增规则必须把时间来源/阈值写进 data/rs_event_data.lua，禁止从 UI 文案或名称猜测。
    local rows = {}
    -- 计时归零只代表旧阶段计时耗尽，不代表新阶段已经生效。必须等下一份区域事实。
    -- 这项约束作用于所有实时推导；不能将 0 秒伪装成即将开场并置顶。
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
        if remain ~= nil and remain > 0 and state == ZONE_STATE.BATTLE then
            append(MakeDynamicOccurrence({
                key = "dynamic:zone:102:aegis", name = aegis.name or "海之烛台", fullName = aegis.fullName or aegis.name,
                shortName = aegis.shortName or "烛台", microName = aegis.microName or "烛台", zoneId = 102,
                questScope = aegis.questScope, questKey = aegis.questKey, seconds = remain, active = false, phase = "battle_to_war",
            }))
        elseif remain ~= nil and remain > 0 and state == ZONE_STATE.WAR then
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
        -- 中文维护注释（2026-09-19）：鲸鱼 Boss 的刷新点必须只来自 data Authority 中的战争剩余阈值。
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
        -- 中文维护注释（2026-09-19，Garden phase migration）：WAR 已经是实时事实，不能再生成 active timeline occurrence。
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

    -- 中文维护注释（Activity Timeline v2 projection transaction）：一次 Refresh 内分别构建 timeline/live，
    -- 各自完成排序后再拼接，最后一次性替换 rows/rowByKey/revision。Presentation 因此永远看到同一 revision 的完整快照，
    -- 不会在 1s timer 中先看到新 timeline、后看到旧 live。动态 occurrence 只复用前一次 5s zone scan 的 transient facts，
    -- 区域 Native 读取只在 5s 采样；SyncClock 每 15s 最多读取一次时钟，失败也受同一限流。
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
    self.zoneStates, self.zoneRemainSeconds, self.zoneObservedAtMs = {}, {}, {}
    self.clockAnchor = nil
    self.lastClockSampleAtMs = -1
    self.lastClockValidAtMs,self.lastClockSample,self.clockError=nil,nil,nil
    self.clockSampleFailures=0
    self.lastZoneScanAtMs = -1
end

-- 静态关注目录：不依赖正在发生的 occurrence，因此隐藏/尚未发生项也可恢复。
-- Identity 与上方 BuildStaticRows/BuildDynamicTimelineRows/BuildZoneRows 同属本 Authority。
-- 老存档的 fullName 键保持不变；仅实时区域新增已有稳定 row.key，不改变 Store canonical。
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
