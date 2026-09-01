------------------------------------------------------------------------
-- Replicated Suite - Low-overhead performance telemetry
--
-- This module never persists data and never uses the Suite's simulated
-- OnUpdate clock as an execution timer.  Frame samples are always available;
-- callback timing is opt-in and only enabled when a monotonic local timer is
-- actually available in the client Lua environment.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite

local FRAME_RING_SIZE = 180
local JANK_RING_SIZE = 40
local MAX_FRAME_LABELS = 12
local MAX_LABELS = 128
local JANK_MS = 50
local CLOCK_GAP_TOLERANCE_MS = 25

local function Finite(value)
    value = tonumber(value)
    if value == nil or value ~= value or value == math.huge or value == -math.huge then return nil end
    return value
end

local function ResolveTimer()
    local osTable = rawget(_G, "os")
    if type(osTable) ~= "table" or type(osTable.clock) ~= "function" then return nil, "os.clock unavailable" end
    local okA, a = pcall(osTable.clock)
    local okB, b = pcall(osTable.clock)
    a, b = okA and Finite(a) or nil, okB and Finite(b) or nil
    if a == nil or b == nil or b < a then return nil, "os.clock is not monotonic" end
    return function()
        local ok, value = pcall(osTable.clock)
        value = ok and Finite(value) or nil
        return value and value * 1000 or nil
    end, "os.clock"
end

S.PerformanceMonitor = {
    frameRing = {}, frameCursor = 0, frameCount = 0,
    jankRing = {}, jankCursor = 0, jankCount = 0, jankTotal = 0, worstJank = nil,
    labels = {}, current = { labels = {}, seen = {}, modules = {}, moduleSeen = {}, executed = 0, pending = 0, measuredMs = 0, completed = false },
    previous = { labels = {}, modules = {}, executed = 0, pending = 0, measuredMs = 0, valid = false },
    outside = { labels = {}, seen = {}, modules = {}, moduleSeen = {}, executed = 0, measuredMs = 0 }, frameActive = false,
    -- lastFrameMs remains the client-provided OnUpdate delta for compatibility.
    -- os.clock is deliberately reported as a *script-clock gap*, not wall time:
    -- different RU clients may account suspended/render time differently.
    lastFrameMs = 0, maxFrameMs = 0, lastClockGapMs = nil, maxClockGapMs = 0,
    lastUnattributedMs = 0, maxUnattributedMs = 0, unattributedStalls = 0,
    lastFrameClockMs = nil, jankThresholdMs = JANK_MS,
    capture = nil, timer = nil, timerName = "unavailable", timerReason = "not initialized",
    startup = { startedAt = tonumber(S.BootLoadStartedAt), checkpoints = {} },
}
local P = S.PerformanceMonitor

function P:Initialize()
    self.timer, self.timerName = ResolveTimer()
    self.timerReason = self.timer ~= nil and nil or self.timerName
    return self.timer ~= nil
end

function P:MarkStartup(label)
    local startup = self.startup
    if startup == nil or self.timer == nil or startup.startedAt == nil then return false end
    local now = self.timer()
    if now == nil then return false end
    local elapsed = math.max(0, now - startup.startedAt)
    local checkpoints = startup.checkpoints
    local name = tostring(label or "startup")
    if name == "" then name = "startup" end
    if #name > 96 then name = name:sub(1, 96) end
    checkpoints[#checkpoints + 1] = { label = name, elapsedMs = elapsed }
    while #checkpoints > 12 do table.remove(checkpoints, 1) end
    return true
end

function P:GetStartup()
    local startup = self.startup or {}
    local rows = {}
    for _, row in ipairs(startup.checkpoints or {}) do
        rows[#rows + 1] = { label = row.label, elapsedMs = row.elapsedMs }
    end
    return rows
end

local function NormalizeLabel(value)
    local label = tostring(value or "unknown")
    if label == "" then label = "unknown" end
    if #label > 96 then label = label:sub(1, 96) end
    return label
end

local function AppendUnique(list, value)
    for _, existing in ipairs(list) do if existing == value then return end end
    if #list < MAX_FRAME_LABELS then list[#list + 1] = value end
end

function P:_Stats(label, detailed)
    label = NormalizeLabel(label)
    local container = detailed and self.capture and self.capture.labels or self.labels
    if container == nil then return nil, label end
    -- Do not use `a and b or fallback` here: an absent detailed entry is nil
    -- on its first call and would incorrectly select the always-on aggregate
    -- table, leaving the finished capture empty despite valid timing samples.
    local stats = container[label]
    if stats ~= nil then return stats, label end
    local count = 0
    for _ in pairs(container) do count = count + 1 end
    if count >= MAX_LABELS then label = "other"; stats = container[label]; if stats ~= nil then return stats, label end end
    stats = { calls = 0, totalMs = 0, maxMs = 0, jankHits = 0 }
    container[label] = stats
    return stats, label
end

function P:_MarkFrame(label)
    local current = self.current
    if current.seen[label] == true then return end
    current.seen[label] = true
    if #current.labels < MAX_FRAME_LABELS then current.labels[#current.labels + 1] = label end
end

function P:_MarkModule(moduleId)
    local current = self.current
    moduleId = tostring(moduleId or "suite")
    if current.moduleSeen[moduleId] == true then return end
    current.moduleSeen[moduleId] = true
    if #current.modules < MAX_FRAME_LABELS then current.modules[#current.modules + 1] = moduleId end
end

function P:_MarkOutside(label, moduleId)
    local outside = self.outside
    if outside.seen[label] ~= true then
        outside.seen[label] = true
        if #outside.labels < MAX_FRAME_LABELS then outside.labels[#outside.labels + 1] = label end
    end
    moduleId = tostring(moduleId or "suite")
    if outside.moduleSeen[moduleId] ~= true then
        outside.moduleSeen[moduleId] = true
        if #outside.modules < MAX_FRAME_LABELS then outside.modules[#outside.modules + 1] = moduleId end
    end
end

function P:_ModuleStats(moduleId)
    local capture = self.capture
    if capture == nil or capture.finished == true then return nil end
    moduleId = tostring(moduleId or "suite")
    local stats = capture.modules[moduleId]
    if stats == nil then
        local count = 0; for _ in pairs(capture.modules) do count = count + 1 end
        if count >= MAX_LABELS then moduleId = "other"; stats = capture.modules[moduleId] end
        if stats == nil then stats = { calls = 0, totalMs = 0, maxMs = 0, jankHits = 0 }; capture.modules[moduleId] = stats end
    end
    return stats, moduleId
end

function P:_CopyCompletedFrame()
    local previous, current = self.previous, self.current
    local outside = self.outside
    previous.valid = current.completed == true or #outside.labels > 0
    previous.executed = (current.executed or 0) + (outside.executed or 0)
    previous.pending = current.pending or 0
    previous.measuredMs = (current.measuredMs or 0) + (outside.measuredMs or 0)
    for index = #previous.labels, 1, -1 do previous.labels[index] = nil end
    for index = #previous.modules, 1, -1 do previous.modules[index] = nil end
    if previous.valid ~= true then return end
    for index, label in ipairs(current.labels) do previous.labels[index] = label end
    for index, moduleId in ipairs(current.modules) do previous.modules[index] = moduleId end
    -- Native hosts that ran after the scheduler's previous EndFrame belong to
    -- the interval that ends now. Merge them before evaluating this OnUpdate
    -- delta; deferring them one more scheduler frame would create a false
    -- causal offset in the diagnostic output.
    for _, label in ipairs(outside.labels) do AppendUnique(previous.labels, label) end
    for _, moduleId in ipairs(outside.modules) do AppendUnique(previous.modules, moduleId) end
    for key in pairs(outside.seen) do outside.seen[key] = nil end
    for key in pairs(outside.moduleSeen) do outside.moduleSeen[key] = nil end
    for index = #outside.labels, 1, -1 do outside.labels[index] = nil end
    for index = #outside.modules, 1, -1 do outside.modules[index] = nil end
    outside.executed, outside.measuredMs = 0, 0
end

function P:BeginFrame(dtMs, pending)
    -- A native OnUpdate delta describes the interval that ended just before
    -- this callback.  Preserve the completed previous-frame labels so a long
    -- interval is never attributed to callbacks that have not run yet.
    self:_CopyCompletedFrame()
    local current = self.current
    for key in pairs(current.seen) do current.seen[key] = nil end
    for key in pairs(current.moduleSeen) do current.moduleSeen[key] = nil end
    for index = #current.labels, 1, -1 do current.labels[index] = nil end
    for index = #current.modules, 1, -1 do current.modules[index] = nil end
    current.executed = 0
    current.pending = math.max(0, tonumber(pending) or 0)
    current.measuredMs = 0
    current.completed = false
    local nativeElapsed = math.max(0, Finite(dtMs) or 0)
    self.lastFrameMs = nativeElapsed
    local now = self.timer and self.timer() or nil
    local clockGap = nil
    if now ~= nil and self.lastFrameClockMs ~= nil and now >= self.lastFrameClockMs then
        clockGap = math.max(0, now - self.lastFrameClockMs)
    end
    self.lastFrameClockMs = now
    current.nativeDtMs = nativeElapsed
    current.clockGapMs = clockGap
    current.unattributedMs = clockGap ~= nil and math.max(0, clockGap - nativeElapsed) or 0
    self.lastClockGapMs = clockGap
    if clockGap ~= nil and clockGap > self.maxClockGapMs then self.maxClockGapMs = clockGap end
    self.lastUnattributedMs = current.unattributedMs
    if current.unattributedMs > self.maxUnattributedMs then self.maxUnattributedMs = current.unattributedMs end
    self.frameActive = true
end

function P:Begin(label, moduleId)
    label = NormalizeLabel(label)
    local stats, normalized = self:_Stats(label, false)
    if stats ~= nil then stats.calls = stats.calls + 1 end
    if self.frameActive == true then
        self:_MarkFrame(normalized)
        self:_MarkModule(moduleId)
        self.current.executed = self.current.executed + 1
    else
        self:_MarkOutside(normalized, moduleId)
        self.outside.executed = (self.outside.executed or 0) + 1
    end
    local capture = self.capture
    if capture == nil or capture.finished == true then return nil end
    local detail = self:_Stats(normalized, true)
    if detail ~= nil then detail.calls = detail.calls + 1 end
    local moduleStats, normalizedModule = self:_ModuleStats(moduleId)
    if moduleStats ~= nil then moduleStats.calls = moduleStats.calls + 1 end
    local started = self.timer and self.timer() or nil
    return { label = normalized, moduleId = normalizedModule, started = started }
end

function P:End(token)
    if token == nil or self.capture == nil then return end
    local detail = self:_Stats(token.label, true)
    if detail == nil or token.started == nil or self.timer == nil then return end
    local finished = self.timer()
    if finished == nil or finished < token.started then return end
    local elapsed = math.max(0, finished - token.started)
    detail.totalMs = detail.totalMs + elapsed
    if elapsed > detail.maxMs then detail.maxMs = elapsed end
    local moduleStats = self:_ModuleStats(token.moduleId)
    if moduleStats ~= nil then
        moduleStats.totalMs = moduleStats.totalMs + elapsed
        if elapsed > moduleStats.maxMs then moduleStats.maxMs = elapsed end
    end
    if self.frameActive == true then
        self.current.measuredMs = (self.current.measuredMs or 0) + elapsed
    else
        self.outside.measuredMs = (self.outside.measuredMs or 0) + elapsed
    end
end

function P:EndFrame(dtMs, backlog)
    local elapsed = math.max(0, Finite(dtMs) or self.lastFrameMs or 0)
    self.lastFrameMs = elapsed
    if elapsed > self.maxFrameMs then self.maxFrameMs = elapsed end
    self.frameCursor = (self.frameCursor % FRAME_RING_SIZE) + 1
    self.frameCount = math.min(FRAME_RING_SIZE, self.frameCount + 1)
    local frame = self.frameRing[self.frameCursor] or {}; self.frameRing[self.frameCursor] = frame
    frame.dtMs, frame.executed, frame.pending = elapsed, self.current.executed, math.max(0, tonumber(backlog) or self.current.pending)
    frame.clockGapMs = self.current.clockGapMs
    frame.unattributedMs = self.current.unattributedMs or 0
    frame.measuredMs = self.previous.measuredMs or 0

    local observed = math.max(elapsed, tonumber(self.current.clockGapMs) or 0)
    -- A clock gap larger than the native delta is useful evidence of a stall,
    -- but not proof of a particular external source.  Do not accuse the Suite
    -- callbacks that happen to run after that gap.
    local clockDominant = self.current.clockGapMs ~= nil
        and (self.current.unattributedMs or 0) >= CLOCK_GAP_TOLERANCE_MS
        and observed >= self.jankThresholdMs
    local source = self.previous.valid == true and self.previous or self.current
    local measured = tonumber(source.measuredMs) or 0
    local intervalUnmeasured = self.timer ~= nil and elapsed >= self.jankThresholdMs
        and math.max(0, elapsed - measured) or 0
    local suppressAssociation = clockDominant or intervalUnmeasured >= self.jankThresholdMs
    local kind = clockDominant and "脚本时钟间隔异常（未归因）"
        or (suppressAssociation and "原生帧间隔异常（Suite 回调未覆盖）" or "关联上一帧 Suite 回调")
    if observed >= self.jankThresholdMs then
        self.jankTotal = self.jankTotal + 1
        if suppressAssociation then self.unattributedStalls = self.unattributedStalls + 1 end
        self.jankCursor = (self.jankCursor % JANK_RING_SIZE) + 1
        self.jankCount = math.min(JANK_RING_SIZE, self.jankCount + 1)
        local jank = self.jankRing[self.jankCursor] or {}; self.jankRing[self.jankCursor] = jank
        jank.dtMs, jank.nativeDtMs, jank.clockGapMs = observed, elapsed, self.current.clockGapMs
        jank.executed, jank.pending, jank.measuredMs, jank.kind = source.executed or 0, frame.pending, measured, kind
        if suppressAssociation then
            jank.labels = "未归因：本帧 Suite 回调不作为根因"
            jank.modules = "无（需排查客户端/渲染/其他插件）"
        else
            jank.labels = table.concat(source.labels, ", ")
            jank.modules = table.concat(source.modules, ", ")
        end
        if self.worstJank == nil or observed > (tonumber(self.worstJank.dtMs) or 0) then
            -- Keep the all-session maximum separately: the 40-entry recent
            -- ring can be overwritten by ordinary stutters after a rare long
            -- freeze, precisely the incident this monitor must preserve.
            self.worstJank = { dtMs = observed, nativeDtMs = elapsed, clockGapMs = self.current.clockGapMs,
                measuredMs = measured, kind = kind, labels = jank.labels, modules = jank.modules, pending = frame.pending }
        end
        -- A finished capture is immutable. Continuing to associate later
        -- frames with its old labels made jankHits exceed calls, producing an
        -- impossible and misleading hotspot signal in exported diagnostics.
        if suppressAssociation ~= true and self.capture ~= nil and self.capture.finished ~= true then
            for _, label in ipairs(source.labels) do
                local detail = self:_Stats(label, true)
                if detail ~= nil then detail.jankHits = detail.jankHits + 1 end
            end
            for _, moduleId in ipairs(source.modules) do
                local moduleStats = self:_ModuleStats(moduleId)
                if moduleStats ~= nil then moduleStats.jankHits = moduleStats.jankHits + 1 end
            end
        end
    end
    local capture = self.capture
    if capture ~= nil and (S.NowMs and S.NowMs() or 0) >= capture.endsAt then capture.finished = true end
    self.current.completed = true
    self.frameActive = false
end

function P:StartCapture(seconds)
    if self.capture ~= nil and self.capture.finished ~= true then return false, "详细捕获已在进行" end
    local duration = math.max(5, math.min(120, math.floor(tonumber(seconds) or 30)))
    self.capture = { startedAt = S.NowMs and S.NowMs() or 0, endsAt = (S.NowMs and S.NowMs() or 0) + duration * 1000,
        durationSeconds = duration, labels = {}, modules = {}, finished = false }
    return true, self.timer ~= nil and ("已开始 " .. tostring(duration) .. " 秒详细捕获") or "已开始计数捕获；客户端不支持回调耗时计时"
end

function P:StopCapture()
    if self.capture == nil then return false, "当前没有详细捕获" end
    self.capture.finished = true
    self.capture.endsAt = S.NowMs and S.NowMs() or 0
    return true, "详细捕获已停止"
end

function P:ClearCapture()
    self.capture = nil
    return true
end

function P:GetTop(limit)
    local capture = self.capture
    if capture == nil then return {} end
    local rows = {}
    for label, stat in pairs(capture.labels) do
        rows[#rows + 1] = { label = label, calls = stat.calls, totalMs = stat.totalMs, maxMs = stat.maxMs, jankHits = stat.jankHits }
    end
    table.sort(rows, function(a, b)
        if a.totalMs ~= b.totalMs then return a.totalMs > b.totalMs end
        if a.jankHits ~= b.jankHits then return a.jankHits > b.jankHits end
        return a.calls > b.calls
    end)
    local count = math.max(1, math.floor(tonumber(limit) or 6))
    while #rows > count do table.remove(rows) end
    return rows
end

function P:GetTopModules(limit)
    local capture = self.capture
    if capture == nil then return {} end
    local rows = {}
    for moduleId, stat in pairs(capture.modules or {}) do
        rows[#rows + 1] = { moduleId = moduleId, calls = stat.calls, totalMs = stat.totalMs, maxMs = stat.maxMs, jankHits = stat.jankHits }
    end
    table.sort(rows, function(a, b)
        if a.totalMs ~= b.totalMs then return a.totalMs > b.totalMs end
        if a.jankHits ~= b.jankHits then return a.jankHits > b.jankHits end
        return a.calls > b.calls
    end)
    local count = math.max(1, math.floor(tonumber(limit) or 6))
    while #rows > count do table.remove(rows) end
    return rows
end

function P:GetWorstJank(limit)
    if self.worstJank == nil then return {} end
    return { self.worstJank }
end

function P:Snapshot()
    local capture = self.capture
    local jank = self.jankRing[self.jankCursor]
    return {
        lastFrameMs = self.lastFrameMs, maxFrameMs = self.maxFrameMs, frameSamples = self.frameCount,
        lastClockGapMs = self.lastClockGapMs, maxClockGapMs = self.maxClockGapMs,
        lastUnattributedMs = self.lastUnattributedMs, maxUnattributedMs = self.maxUnattributedMs,
        unattributedStalls = self.unattributedStalls,
        -- jankCount is the all-session count; the bounded ring only retains
        -- the latest samples for association, never silently caps the number
        -- shown to the user at 40.
        jankCount = self.jankTotal, jankSamples = self.jankCount, jankThresholdMs = self.jankThresholdMs,
        latestJank = jank and { dtMs = jank.dtMs, nativeDtMs = jank.nativeDtMs, clockGapMs = jank.clockGapMs,
            kind = jank.kind, labels = jank.labels, pending = jank.pending } or nil,
        timerAvailable = self.timer ~= nil, timerName = self.timerName, timerReason = self.timerReason,
        capture = capture and { active = capture.finished ~= true, finished = capture.finished == true,
            secondsRemaining = math.max(0, math.ceil(((capture.endsAt or 0) - (S.NowMs and S.NowMs() or 0)) / 1000)),
            durationSeconds = capture.durationSeconds } or nil,
        top = self:GetTop(6), topModules = self:GetTopModules(6), worstJank = self:GetWorstJank(3), startup = self:GetStartup(),
    }
end

function P:BuildSummary()
    local snap = self:Snapshot()
    local text = "性能：最近帧 " .. string.format("%.1f", snap.lastFrameMs) .. "ms · 最大 " .. string.format("%.1f", snap.maxFrameMs)
        .. "ms · 卡顿≥" .. tostring(snap.jankThresholdMs) .. "ms：" .. tostring(snap.jankCount)
        .. " · 计时：" .. (snap.timerAvailable and tostring(snap.timerName) or "不可用")
    if snap.lastClockGapMs ~= nil then
        text = text .. " · 脚本间隔 " .. string.format("%.1f", snap.lastClockGapMs) .. "ms"
    end
    if (tonumber(snap.unattributedStalls) or 0) > 0 then
        text = text .. " · 未归因卡顿 " .. tostring(snap.unattributedStalls)
    end
    if snap.capture ~= nil then text = text .. " · 捕获：" .. (snap.capture.active and ("进行中 " .. tostring(snap.capture.secondsRemaining) .. "s") or "已完成") end
    local latestStartup = snap.startup and snap.startup[#snap.startup] or nil
    if latestStartup ~= nil then text = text .. " · 启动 " .. string.format("%.1f", tonumber(latestStartup.elapsedMs) or 0) .. "ms" end
    return text
end

P:Initialize()
