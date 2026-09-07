------------------------------------------------------------------------
-- Replicated Suite - Privacy-filtered Structured Diagnostics Authority
--
-- Diagnostics is infrastructure, not a business Domain.  It owns bounded
-- structured events, aggregation/rate limiting and health snapshots.  It must
-- never become an unbounded log sink or perform expensive work in hot loops.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite

local RECENT_MAX = 80
local RATE_KEY_MAX = 128
local COUNTER_MAX = 128
local CONTEXT_MAX_FIELDS = 12
local CONTEXT_STRING_MAX = 180

S.DiagnosticsManager = {
    recent = {},
    rate = {},
    rateOrder = {},
    counters = {},
    counterOrder = {},
    sequence = 0,
    suppressed = 0,
}
local D = S.DiagnosticsManager

local function NowMs()
    return type(S.NowMs) == "function" and math.max(0, tonumber(S.NowMs()) or 0) or 0
end

local function CountTable(value)
    local count = 0
    if type(value) == "table" then for _ in pairs(value) do count = count + 1 end end
    return count
end

local function NormalizeLevel(value)
    local level = tostring(value or "error"):lower()
    if level == "warn" then level = "warning" end
    if level ~= "debug" and level ~= "info" and level ~= "warning" and level ~= "error" then level = "info" end
    return level
end

local function NormalizeSource(value)
    local source = tostring(value or "suite")
    source = source:gsub("[\r\n]+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    if source == "" then source = "suite" end
    if #source > 80 then source = source:sub(1, 80) end
    return source
end

local function NormalizeCode(value)
    local code = tostring(value or "LEGACY")
    code = code:upper():gsub("[^A-Z0-9_%.:%-]", "_"):gsub("_+", "_")
    code = code:gsub("^_+", ""):gsub("_+$", "")
    if code == "" then code = "LEGACY" end
    if #code > 96 then code = code:sub(1, 96) end
    return code
end

local function SafePrimitive(value)
    local kind = type(value)
    if kind == "nil" or kind == "boolean" or kind == "number" then return value end
    if kind == "string" then
        local text = value:gsub("[\r\n]+", " ")
        if #text > CONTEXT_STRING_MAX then text = text:sub(1, CONTEXT_STRING_MAX) .. "…" end
        return text
    end
    return "<" .. kind .. ">"
end

local function SanitizeContext(value)
    if type(value) ~= "table" then return nil end
    local out, count = {}, 0
    for key, item in pairs(value) do
        if count >= CONTEXT_MAX_FIELDS then break end
        local safeKey = tostring(key or "")
        if safeKey ~= "" then
            out[safeKey] = SafePrimitive(item)
            count = count + 1
        end
    end
    return next(out) ~= nil and out or nil
end

local function ContextText(context)
    if type(context) ~= "table" then return "" end
    local keys = {}
    for key in pairs(context) do keys[#keys + 1] = tostring(key) end
    table.sort(keys)
    local parts = {}
    for _, key in ipairs(keys) do parts[#parts + 1] = key .. "=" .. tostring(context[key]) end
    return #parts > 0 and (" {" .. table.concat(parts, ", ") .. "}") or ""
end

local function CompactLogText(value)
    local text = tostring(value or "")
    text = text:gsub("\r\n", "\n"):gsub("\r", "\n")
    text = text:gsub("[\n]+", " ↳ ")
    text = text:gsub("^%s+", ""):gsub("%s+$", "")
    return text
end

local function TouchBoundedKey(container, order, key, limit)
    if container[key] ~= nil then return end
    order[#order + 1] = key
    if #order <= limit then return end
    local oldest = table.remove(order, 1)
    if oldest ~= nil then container[oldest] = nil end
end

function D:_Append(level, source, code, message, context, options)
    options = type(options) == "table" and options or {}
    level = NormalizeLevel(level)
    source = NormalizeSource(source)
    code = NormalizeCode(code)
    message = tostring(message or "")
    context = SanitizeContext(context)

    self.sequence = (tonumber(self.sequence) or 0) + 1
    local now = NowMs()
    local entry = {
        seq = self.sequence,
        level = level,
        source = source,
        code = code,
        message = message,
        context = context,
        at = now,
        count = math.max(1, math.floor(tonumber(options.count) or 1)),
        firstAt = tonumber(options.firstAt) or now,
        lastAt = tonumber(options.lastAt) or now,
    }
    self.recent[#self.recent + 1] = entry
    while #self.recent > RECENT_MAX do table.remove(self.recent, 1) end

    if options.writeLog ~= false and type(S.RecordLog) == "function" then
        local suffix = entry.count > 1 and (" · 重复 " .. tostring(entry.count - 1) .. " 次") or ""
        S.RecordLog(level, source, "[" .. code .. "] " .. message .. suffix .. ContextText(context))
    end
    return entry
end

-- New structured entry point.
function D:Emit(level, source, code, message, context)
    return self:_Append(level, source, code, message, context)
end

-- Backward-compatible entry used throughout the existing Suite. Optional code
-- and context allow callers to migrate incrementally without breaking old code.
function D:Record(level, source, message, code, context)
    return self:_Append(level, source, code or "LEGACY", message, context)
end

function D:Info(source, code, message, context)
    return self:Emit("info", source, code, message, context)
end
function D:Warn(source, code, message, context)
    return self:Emit("warning", source, code, message, context)
end
function D:Error(source, code, message, context)
    return self:Emit("error", source, code, message, context)
end

-- Repeated hot-loop problems are aggregated instead of writing hundreds of log
-- rows.  The next eligible emission reports how many repeats were suppressed.
function D:RateLimited(level, source, code, intervalMs, message, context)
    source = NormalizeSource(source)
    code = NormalizeCode(code)
    intervalMs = math.max(250, tonumber(intervalMs) or 5000)
    local key = source .. "|" .. code
    local now = NowMs()
    local state = self.rate[key]

    if state == nil then
        TouchBoundedKey(self.rate, self.rateOrder, key, RATE_KEY_MAX)
        state = { lastEmitAt = now, firstAt = now, lastAt = now, suppressed = 0 }
        self.rate[key] = state
        return self:_Append(level, source, code, message, context, { firstAt = now, lastAt = now })
    end

    state.lastAt = now
    if now - (tonumber(state.lastEmitAt) or 0) < intervalMs then
        state.suppressed = (tonumber(state.suppressed) or 0) + 1
        self.suppressed = (tonumber(self.suppressed) or 0) + 1
        return nil
    end

    local repeats = tonumber(state.suppressed) or 0
    state.lastEmitAt = now
    state.suppressed = 0
    local merged = SanitizeContext(context) or {}
    if repeats > 0 then merged.suppressedCount = repeats end
    return self:_Append(level, source, code, message, merged, {
        count = repeats + 1,
        firstAt = state.firstAt,
        lastAt = now,
    })
end

function D:WarnRateLimited(source, code, intervalMs, message, context)
    return self:RateLimited("warning", source, code, intervalMs, message, context)
end
function D:ErrorRateLimited(source, code, intervalMs, message, context)
    return self:RateLimited("error", source, code, intervalMs, message, context)
end

-- Bounded counters are useful for events that are important statistically but
-- should not create log rows (UI writes, retry counts, validation misses, etc.).
function D:Count(source, code, delta)
    source = NormalizeSource(source)
    code = NormalizeCode(code)
    local key = source .. "|" .. code
    local row = self.counters[key]
    if row == nil then
        TouchBoundedKey(self.counters, self.counterOrder, key, COUNTER_MAX)
        row = { source = source, code = code, count = 0, firstAt = NowMs(), lastAt = 0 }
        self.counters[key] = row
    end
    row.count = (tonumber(row.count) or 0) + (tonumber(delta) or 1)
    row.lastAt = NowMs()
    return row.count
end

function D:GetCounters(limit)
    local rows = {}
    for _, row in pairs(self.counters) do
        rows[#rows + 1] = {
            source = row.source,
            code = row.code,
            count = tonumber(row.count) or 0,
            firstAt = row.firstAt,
            lastAt = row.lastAt,
        }
    end
    table.sort(rows, function(a, b)
        if a.count ~= b.count then return a.count > b.count end
        return tostring(a.source) < tostring(b.source)
    end)
    limit = math.max(0, math.floor(tonumber(limit) or #rows))
    while #rows > limit do table.remove(rows) end
    return rows
end

-- User-copyable single-line diagnostics for the two P0 observability targets
-- (acceptance brief §19). Bounded, no per-frame chat output; both read only
-- Feature-owned runtime diagnostic tables.
function D.BuffGearLine(snap)
    local dia = snap.buffDisplay and snap.buffDisplay.equipmentDiagnostics or nil
    if dia == nil then return "BuffGear：装备诊断不可用（功能未加载）" end
    return "BuffGear：lane=" .. tostring(dia.laneTicks or 0) .. "次"
        .. " · reads=" .. tostring(dia.reads or 0)
        .. " · icons=" .. tostring(dia.validIcons or 0)
        .. " · empty=" .. tostring(dia.emptySlots or 0)
        .. " · errors=" .. tostring(dia.readErrors or 0)
        .. " · unresolvedSlots=" .. tostring(dia.unresolvedSlots or 0)
        .. " · source=" .. tostring(dia.lastReadSource or "none")
        .. " · iconField=" .. tostring(dia.iconField or "none")
        .. (dia.lastError and (" · lastError=" .. tostring(dia.lastError)) or "")
        .. (dia.sampleItemKeys and (" · itemKeys=" .. tostring(dia.sampleItemKeys)) or "")
end

function D.UnitLineLine(snap)
    local feature = S.Features and S.Features.combat_unit_lines or nil
    local dia = feature and feature.Diagnostics or nil
    if dia == nil then return "UnitLines：诊断不可用（功能未加载）" end
    local projection = snap.screenProjection or {}
    return "UnitLines：enabled=" .. tostring(dia.enabled == true)
        .. " · consumer=" .. tostring(dia.consumerCount or 0)
        .. " · pairs=" .. tostring(dia.attemptedPairs or 0)
        .. " · rows=" .. tostring(dia.drawnRows or 0)
        .. " · status=" .. tostring(dia.lastStatus or "idle")
        .. " · collapsed=" .. tostring(dia.endpointCollapsed or 0)
        .. " · projFail=" .. tostring(projection.failures or 0)
        .. " · aliasGuard=" .. tostring(projection.worldAliasGuards or 0)
        .. " · aliasKept=" .. tostring(projection.aliasNativeKept or 0)
        .. " · aliasReject=" .. tostring(projection.aliasNativeRejects or 0)
        .. (dia.lastFailureReason and (" · lastFailure=" .. tostring(dia.lastFailureReason)) or " · lastFailure=none")
end

function D.BossLine(snap)
    local dia = snap.bossAlerts
    if dia == nil then return "Boss：诊断不可用（功能未启用或未加载）" end
    local names = type(dia.castNames) == "table" and dia.castNames or {}
    local sample = {}
    for index = #names, math.max(1, #names - 2), -1 do sample[#sample + 1] = tostring(names[index]) end
    return "Boss：ticks=" .. tostring(dia.observeTicks or 0)
        .. " · source=" .. tostring(dia.lastFactSource or "none")
        .. " · casting=" .. tostring(dia.castingSkill or "-")
        .. " · debuff=" .. tostring(dia.playerDebuff or "-")
        .. " · rule=" .. tostring(dia.matchedRule or "-")
        .. ((tonumber(dia.lastMechanicAt) or 0) > 0 and (" · lastAt=" .. tostring(dia.lastMechanicAt)) or "")
        .. (#sample > 0 and (" · seenCast=" .. table.concat(sample, " | ")) or "")
end

------------------------------------------------------------------------
-- Per-feature status rows (2026-09-06 diagnostics overhaul).
--
-- The old summary only carried aggregate health counters, so a broken
-- feature surfaced as "everything green but it does not work" with no way
-- to tell WHICH layer failed. Each row answers three questions in order:
--   verdict   -- is this feature working right now (not "enabled")
--   evidence  -- the live numbers that prove the verdict
--   guidance  -- the next concrete action for the user when it is broken
-- The same rows feed the diagnostics page AND BuildCopyText, so what the
-- user sees on the page is exactly what they copy to chat.
------------------------------------------------------------------------

-- One feature row: { id, label, verdict="ok"|"degraded"|"down"|"off", text, hint }
local function FeatureRow(id, label, verdict, text, hint)
    return { id = id, label = label, verdict = verdict, text = text, hint = hint }
end

local function RuntimeEnabled(featureId)
    local runtime = S.FeatureRuntime
    if type(runtime) == "table" and type(runtime.IsEnabled) == "function" then
        return runtime:IsEnabled(featureId) == true
    end
    local feature = S.Features and S.Features[featureId] or nil
    return feature ~= nil and feature.enabled == true
end

local function ConsumerCount(feature)
    return tonumber(feature and feature.consumerCount) or 0
end

local function TaskActive(taskName)
    return S.Scheduler ~= nil and type(S.Scheduler.tasks) == "table"
        and S.Scheduler.tasks[taskName] ~= nil and S.Scheduler.tasks[taskName].enabled == true
end

local function TaskEvidence(taskName)
    if S.Scheduler == nil or type(S.Scheduler.GetTaskState) ~= "function" then return "任务=遥测不可用", nil end
    local state = S.Scheduler:GetTaskState(taskName)
    if type(state) ~= "table" or state.registered ~= true then return "任务=未登记", nil end
    local mode = state.enabled == true and "开" or (state.faultedAtMs ~= nil and "熔断" or "停")
    local text = "任务=" .. mode .. "/run" .. tostring(tonumber(state.runCount) or 0)
        .. "/失" .. tostring(tonumber(state.failureTotal) or 0)
        .. "/连续" .. tostring(tonumber(state.failureCount) or 0)
        .. "/恢复" .. tostring(tonumber(state.resumeCount) or 0)
    local err = state.lastError
    if err ~= nil and tostring(err) ~= "" then
        err = CompactLogText(err)
        if #err > 96 then err = err:sub(1, 96) .. "…" end
    else err = nil end
    return text, err
end

function D:BuildFeatureStatusRows()
    local rows = {}
    local features = S.Features or {}

    -- Presenter handshake evidence shared by the unit_lines/range_assist rows
    -- (v6 watchdog telemetry): without it a dead lease reported only "无消费
    -- 者" with no way to tell a missed lifecycle event from a failed acquire.
    local guides = S.UIV3 and S.UIV3.CombatVisualGuidesV3 or nil
    local lifecycleSeen = type(guides) == "table" and guides.lastLifecycle or nil
    local lifecycleText = lifecycleSeen ~= nil
        and ("已收:" .. tostring(lifecycleSeen.id) .. "/" .. tostring(lifecycleSeen.state))
        or "未收到"

    -- 单位连线: verdict needs consumer>0 AND rows drawn recently.
    do
        local feature = features.combat_unit_lines
        local dia = feature and feature.Diagnostics or nil
        local projection = S.Services and S.Services.ScreenProjectionV3 and S.Services.ScreenProjectionV3.GetHealth and S.Services.ScreenProjectionV3:GetHealth() or {}
        local enabled = RuntimeEnabled("combat_unit_lines")
        -- NOTE: `rows` here is the OUTPUT array declared above; the drawn-row
        -- count is `drawn`. Do not shadow the output array with a local of the
        -- same name (that bug crashed this very function on first use).
        local drawn = tonumber(dia and dia.drawnRows) or 0
        local lastFailure = dia and dia.lastFailureReason or nil
        -- Presenter-side render evidence. drawnRows only proves the PROJECTION
        -- produced rows; the .18.129d label-write failure kept this verdict
        -- green while zero dots reached the screen. lastUnitSampling is
        -- refreshed by every RenderUnit pass that ran with a held consumer.
        local sampling = type(guides) == "table" and type(guides.lastUnitSampling) == "table" and guides.lastUnitSampling or nil
        local visibleDots = tonumber(sampling and sampling.visibleDots) or 0
        local uniquePositions = tonumber(sampling and sampling.uniquePositions) or 0
        local renderedZero = sampling ~= nil and uniquePositions <= 0
        if not enabled then
            rows[#rows + 1] = FeatureRow("unit_lines", "单位连线", "off",
                "关闭 · 打开 设置→功能 或 连线设置页开关", "开启后选中目标即可看到连线")
        elseif ConsumerCount(feature) <= 0 then
            local attempts = type(guides) == "table" and tonumber(guides.acquireAttempts and guides.acquireAttempts.unit) or 0
            local acqErr = type(guides) == "table" and type(guides.lastAcquireError) == "table" and guides.lastAcquireError.unit or nil
            local heldDesync = type(guides) == "table" and guides.unitHeld == true
            local parts = { "已开启但无消费者", "生命周期=" .. lifecycleText, "接管尝试=" .. tostring(attempts) }
            if acqErr ~= nil then parts[#parts + 1] = "失败原因=" .. tostring(acqErr.error) end
            if heldDesync == true then parts[#parts + 1] = "失同步=presenter仍持有" end
            rows[#rows + 1] = FeatureRow("unit_lines", "单位连线", "down", table.concat(parts, " · "),
                acqErr ~= nil and ("重开连线开关；仍失败复制此行（" .. tostring(acqErr.error) .. "）")
                    or (heldDesync == true and "租约被外部清空，1 秒内自动重取；不恢复复制此行"
                    or (lifecycleSeen == nil and "重开连线开关；若生命周期仍=未收到 复制此行给维护者（事件未达渲染层）"
                    or "重开连线开关；仍为 0 复制此行给维护者")))
        elseif drawn > 0 and renderedZero then
            local sampling0 = sampling or {}
            local firstRow = tostring(sampling0.firstRow or "?")
            local projReasons = type(projection.failuresByReason) == "table" and projection.failuresByReason or {}
            local reasonText = nil
            local reasonKeys = {}
            for reason, count in pairs(projReasons) do reasonKeys[#reasonKeys + 1] = tostring(reason) .. "=" .. tostring(count) end
            table.sort(reasonKeys)
            if #reasonKeys > 0 then reasonText = table.concat(reasonKeys, ",", 1, math.min(3, #reasonKeys)) end
            rows[#rows + 1] = FeatureRow("unit_lines", "单位连线", "degraded",
                "投影有 " .. tostring(drawn) .. " 行但渲染层 0 个可见点 · 行=" .. firstRow
                .. " · UI=" .. tostring(math.floor(tonumber(sampling0.addonScale) or 1)) .. "x"
                .. " · proj失败=" .. tostring(projection.failures or 0)
                .. (reasonText ~= nil and (" · 原因:" .. reasonText) or ""),
                "渲染层没有产出任何点；若行=?? 为坐标缺失，否则为宿主/坐标空间问题——复制此行给维护者")
        elseif drawn > 0 then
            rows[#rows + 1] = FeatureRow("unit_lines", "单位连线", "ok",
                "工作中 · rows=" .. tostring(drawn) .. "/" .. tostring(dia.attemptedPairs or 0)
                .. " · 点=" .. tostring(visibleDots) .. "(唯一" .. tostring(uniquePositions) .. ")"
                .. " · 行=" .. tostring(sampling and sampling.firstRow or "?")
                .. " · 状态=" .. tostring(dia.lastStatus or "?")
                .. " · proj失败=" .. tostring(projection.failures or 0),
                lastFailure and ("部分未绘制：" .. tostring(lastFailure)) or nil)
        else
            rows[#rows + 1] = FeatureRow("unit_lines", "单位连线", "down",
                "已开启有消费者但没有产出任何行 · lastFailure=" .. tostring(lastFailure or "none")
                .. " · 投影失败=" .. tostring(projection.failures or 0),
                lastFailure == "ALL_PAIRS_DISABLED" and "在连线设置里至少开启一种连线"
                    or "选中一个目标后刷新诊断；仍有此行请复制给维护者")
        end
    end

    -- 范围辅助: needs circle points projected; renderer hides below 3.
    do
        local feature = features.combat_range_assist
        local enabled = RuntimeEnabled("combat_range_assist")
        local projection = feature and feature.GetProjection and feature:GetProjection() or {}
        local row = type(projection.rows) == "table" and projection.rows[1] or nil
        local points = type(row) == "table" and type(row.points) == "table" and #row.points or 0
        local visible = tonumber(row and row.visibleCount) or points
        local rangeTaskText, rangeTaskError = TaskEvidence("v3_business_range_assist_refresh")
        local refreshHealth = type(feature) == "table" and type(feature.RangeRefreshHealth) == "table" and feature.RangeRefreshHealth or {}
        local rangeRefreshText = "刷新=尝试" .. tostring(tonumber(refreshHealth.attempts) or 0)
            .. "/失" .. tostring(tonumber(refreshHealth.failures) or 0)
            .. "/连续" .. tostring(tonumber(refreshHealth.consecutiveFailures) or 0)
        local rangeRefreshError = refreshHealth.lastError
        if rangeRefreshError ~= nil and tostring(rangeRefreshError) ~= "" then
            rangeRefreshError = CompactLogText(rangeRefreshError)
            if #rangeRefreshError > 96 then rangeRefreshError = rangeRefreshError:sub(1, 96) .. "…" end
        else rangeRefreshError = nil end
        if not enabled then
            rows[#rows + 1] = FeatureRow("range_assist", "范围辅助", "off", "关闭 · 在范围辅助页开启", "开启后在角色脚下显示范围圆")
        elseif ConsumerCount(feature) <= 0 then
            local attempts = type(guides) == "table" and tonumber(guides.acquireAttempts and guides.acquireAttempts.range) or 0
            local acqErr = type(guides) == "table" and type(guides.lastAcquireError) == "table" and guides.lastAcquireError.range or nil
            local heldDesync = type(guides) == "table" and guides.rangeHeld == true
            local parts = { "已开启但无消费者", "生命周期=" .. lifecycleText, "接管尝试=" .. tostring(attempts) }
            if acqErr ~= nil then parts[#parts + 1] = "失败原因=" .. tostring(acqErr.error) end
            if heldDesync == true then parts[#parts + 1] = "失同步=presenter仍持有" end
            rows[#rows + 1] = FeatureRow("range_assist", "范围辅助", "down", table.concat(parts, " · "),
                acqErr ~= nil and ("重开范围辅助开关；仍失败复制此行（" .. tostring(acqErr.error) .. "）")
                    or (heldDesync == true and "租约被外部清空，1 秒内自动重取；不恢复复制此行"
                    or "重开范围辅助开关；仍为 0 复制此行"))
        elseif points >= 3 then
            local rangeSampling = type(guides) == "table" and guides.lastRangeSampling or nil
            local calibration = type(row) == "table" and tostring(row.calibration or "-") or "-"
            local projFacts = type(row) == "table" and tostring(row.projFacts or "") or ""
            local rangeEvidence = ""
            if type(rangeSampling) == "table" then
                rangeEvidence = " · 首点=" .. tostring(rangeSampling.first)
                    .. " · 宿主=" .. tostring(rangeSampling.hostVisible)
                    .. " · 缩放=" .. tostring(math.floor((tonumber(rangeSampling.addonScale) or 1) * 100) / 100) .. "x"
            end
            rows[#rows + 1] = FeatureRow("range_assist", "范围辅助", "ok",
                "工作中 · 圆周点 " .. tostring(points) .. " · 半径 " .. tostring(projection.radius or "?")
                .. " · 校准=" .. calibration
                .. (projFacts ~= "" and (" · " .. projFacts) or "")
                .. " · rev=" .. tostring(tonumber(projection.revision) or 0)
                .. " · " .. rangeTaskText .. " · " .. rangeRefreshText .. rangeEvidence
                .. (rangeTaskError ~= nil and (" · taskErr=" .. rangeTaskError) or "")
                .. (rangeRefreshError ~= nil and (" · refreshErr=" .. rangeRefreshError) or ""),
                (rangeTaskError ~= nil or rangeRefreshError ~= nil)
                    and "范围刷新曾出现异常；run/尝试继续增长且连续=0 表示已恢复，若连续失败增长请复制此行"
                    or (points < 8 and "点数偏少：检查投影失败计数" or nil))
        else
            local reasonText = nil
            local projHealth = S.Services and S.Services.ScreenProjectionV3 and S.Services.ScreenProjectionV3.GetHealth and S.Services.ScreenProjectionV3:GetHealth() or {}
            local projReasons = type(projHealth.failuresByReason) == "table" and projHealth.failuresByReason or {}
            local reasonKeys = {}
            for reason, count in pairs(projReasons) do reasonKeys[#reasonKeys + 1] = tostring(reason) .. "=" .. tostring(count) end
            table.sort(reasonKeys)
            if #reasonKeys > 0 then reasonText = table.concat(reasonKeys, ",", 1, math.min(3, #reasonKeys)) end
            local batch = S.Services and S.Services.ScreenProjectionV3 and S.Services.ScreenProjectionV3.lastWorldBatch or nil
            local batchText = ""
            if type(batch) == "table" then
                batchText = " · 批次=" .. tostring(batch.mode or "?")
                    .. "/原" .. tostring(tonumber(batch.native) or 0)
                    .. "/相" .. tostring(tonumber(batch.camera) or 0)
                    .. "/原拒" .. tostring(tonumber(batch.nativeRejected) or 0)
                    .. "/相拒" .. tostring(tonumber(batch.cameraRejected) or 0)
                if batch.frameErr ~= nil then batchText = batchText .. "/相机错=" .. CompactLogText(batch.frameErr) end
            end
            rows[#rows + 1] = FeatureRow("range_assist", "范围辅助", "down",
                "可见点不足(" .. tostring(points) .. "/3 以下不绘制) · 世界位置或投影失败"
                .. " · " .. rangeTaskText .. " · " .. rangeRefreshText .. batchText
                .. (reasonText ~= nil and (" · 原因:" .. reasonText) or "")
                .. (rangeTaskError ~= nil and (" · taskErr=" .. rangeTaskError) or "")
                .. (rangeRefreshError ~= nil and (" · refreshErr=" .. rangeRefreshError) or ""),
                "刷新一次；仍复现请复制此行与 UnitLines 行")
        end
    end

    -- Boss alerts
    do
        local feature = features.combat_boss_alerts
        local dia = feature and feature._bossDiag or nil
        local enabled = RuntimeEnabled("combat_boss_alerts")
        local hud = feature and feature.State and feature.State.hudEnabled
        if not enabled then
            rows[#rows + 1] = FeatureRow("boss_alerts", "首领机制", "off", "关闭 · 在首领机制页开启 HUD", "开启后点「仿真读条」即可验证弹窗")
        elseif not hud then
            rows[#rows + 1] = FeatureRow("boss_alerts", "首领机制", "down", "HUD 未开启 · 开关在首领机制页", "打开「机制 HUD」开关")
        elseif dia == nil or (tonumber(dia.observeTicks) or 0) <= 0 then
            rows[#rows + 1] = FeatureRow("boss_alerts", "首领机制", "down", "观察循环未运行", "点页面「仿真读条」验证 HUD；若仍无 ticks 复制此行")
        else
            rows[#rows + 1] = FeatureRow("boss_alerts", "首领机制", "ok",
                "工作中 · ticks=" .. tostring(dia.observeTicks or 0)
                .. " · 最近事实=" .. tostring(dia.lastFactSource or "none")
                .. " · 命中规则=" .. tostring(dia.matchedRule or "-"),
                "对读条怪应看到 casting=技能名；Boss 真名靠 seenCast 自动取证")
        end
    end

    -- Buff display
    do
        local feature = features.BuffDisplay
        local health = feature and feature.GetHealth and feature:GetHealth() or {}
        local dia = health.equipmentDiagnostics
        if health.ok ~= true then
            rows[#rows + 1] = FeatureRow("buff_display", "状态显示", "off", "关闭 · 在状态显示页开启", "开启后配置头部显示组件")
        elseif (tonumber(health.consumers) or 0) <= 0 then
            rows[#rows + 1] = FeatureRow("buff_display", "状态显示", "down", "已开启但无消费者", "打开状态显示窗口或悬浮组件")
        else
            rows[#rows + 1] = FeatureRow("buff_display", "状态显示", "ok",
                "工作中 · lanes=" .. tostring(#(health.activeLanes or {})) .. "/6"
                .. " · 装备读取=" .. tostring(dia and dia.validIcons or 0) .. "图标/" .. tostring(dia and dia.readErrors or 0) .. "错",
                (tonumber(dia and dia.readErrors or 0)) > 0 and ("装备读取报错：" .. tostring(dia.lastError)) or nil)
        end
    end

    -- 治疗辅助 (visual lifecycle is the gate-visible part)
    do
        local feature = features.Healer
        local health = feature and feature.GetHealth and feature:GetHealth() or {}
        local enabled = RuntimeEnabled("combat_healer")
        if not enabled then
            rows[#rows + 1] = FeatureRow("healer", "治疗辅助", "off", "关闭 · 在治疗辅助页开启", "开启后校准/实况由设置驱动")
        elseif health.enabled ~= true then
            rows[#rows + 1] = FeatureRow("healer", "治疗辅助", "down", "Runtime 开启但 Domain 未启用", "复制此行给维护者（生命周期分叉）")
        else
            local raid = S.UIV3 and S.UIV3.HealerRaidOverlay and S.UIV3.HealerRaidOverlay:Describe() or {}
            rows[#rows + 1] = FeatureRow("healer", "治疗辅助", (raid.running == true or raid.calibrationMode == true) and "ok" or "degraded",
                "Domain ON · overlay running=" .. tostring(raid.running == true)
                .. " · 校准=" .. tostring(raid.calibrationMode == true)
                .. " · 消费者=" .. tostring(raid.consumerHeld == true and 1 or 0) .. "(preview " .. tostring(raid.previewHeld == true and 1 or 0) .. ")",
                raid.running ~= true and "开启设置里的实况开关或校准；失败会有 RAID_RECONCILE_FAILED 告警" or nil)
        end
    end

    -- 一键换装: bank health is the load-time evidence.
    do
        local feature = features.Gear
        local enabled = RuntimeEnabled("combat_gear")
        local storeOk = S.Persistence and S.Persistence.IsStoreLoaded and S.Persistence:IsStoreLoaded("v3.gear.index") or false
        if not enabled then
            rows[#rows + 1] = FeatureRow("gear", "一键换装", "off", "关闭 · 在换装页开启", "开启后配置方案")
        elseif storeOk ~= true then
            local index = S.Persistence and S.Persistence.GetStore and S.Persistence:GetStore("v3.gear.index") or {}
            rows[#rows + 1] = FeatureRow("gear", "一键换装", "down",
                "方案索引未就绪 · " .. tostring(index.loadStatus or "?") .. (index.writeFenced and " · 写保护:" .. tostring(index.writeFenceReason) or ""),
                "按存档故障指引处理；不要清空方案")
        else
            rows[#rows + 1] = FeatureRow("gear", "一键换装", "ok", "工作中 · 方案索引已加载", nil)
        end
    end

    -- 跑商 (trade quote state machine)
    do
        local feature = features.Trade
        local enabled = RuntimeEnabled("life_trade")
        local describe = feature and feature.DescribeRequestState and feature:DescribeRequestState() or nil
        if not enabled then
            rows[#rows + 1] = FeatureRow("trade", "跑商", "off", "关闭 · 在跑商页开启", "开启后选择路线查询货率")
        elseif describe == nil then
            rows[#rows + 1] = FeatureRow("trade", "跑商", "down", "状态机诊断不可用", "复制此行给维护者")
        else
            local ok = describe.status == "ready" or describe.status == "loading"
            rows[#rows + 1] = FeatureRow("trade", "跑商", ok and "ok" or "degraded",
                "状态=" .. tostring(describe.status)
                .. " · 选择=" .. tostring(describe.selectedRoute)
                .. " · 在飞=" .. tostring(describe.activeRoute)
                .. " · 排队=" .. tostring(describe.pendingRoute)
                .. " · 丢弃回调=" .. tostring(describe.droppedCallbacks or 0),
                describe.status == "idle" and "选择起点与目的地后查询" or nil)
        end
    end

    -- 债券
    do
        local feature = features.Bonds
        local enabled = RuntimeEnabled("life_bonds")
        local cache = feature and feature.DescribeDailyCache and feature:DescribeDailyCache() or nil
        if not enabled then
            rows[#rows + 1] = FeatureRow("bonds", "债券", "off", "关闭 · 在债券页开启", "开启后当天首次读取居民板")
        elseif cache == nil then
            rows[#rows + 1] = FeatureRow("bonds", "债券", "down", "每日缓存诊断不可用", "复制此行给维护者")
        else
            local ok = (tonumber(cache.snapshotCount) or 0) > 0
            rows[#rows + 1] = FeatureRow("bonds", "债券", ok and "ok" or "degraded",
                "日期=" .. tostring(cache.dayKey)
                .. " · 已读大陆=" .. tostring(cache.snapshotCount) .. "/3"
                .. " · 板读取=" .. tostring(cache.boardReads or 0)
                .. " · 完成=" .. tostring(cache.completedCount or 0),
                ok == false and "进入西/东大陆可读居民板区域后点刷新；同一天不重复读" or nil)
        end
    end

    return rows
end

-- Render the rows as compact copy text (shared with BuildCopyText).
function D:FormatFeatureStatusRows(rows)
    rows = type(rows) == "table" and rows or self:BuildFeatureStatusRows()
    local marks = { ok = "✓", degraded = "△", down = "✗", off = "○" }
    local parts = {}
    for _, row in ipairs(rows) do
        parts[#parts + 1] = (marks[row.verdict] or "·") .. row.label .. " " .. row.text
    end
    return table.concat(parts, " ║ ")
end

-- Repair guidance lines: for every non-ok row, one actionable hint.
function D:BuildRepairGuidance(rows)
    rows = type(rows) == "table" and rows or self:BuildFeatureStatusRows()
    local hints = {}
    for _, row in ipairs(rows) do
        if row.verdict == "down" or row.verdict == "degraded" then
            hints[#hints + 1] = row.label .. "：" .. tostring(row.hint or "复制该行给维护者")
        end
    end
    if #hints == 0 then return "全部功能状态正常" end
    return table.concat(hints, "；")
end

function D:Snapshot()
    local registry = S.GameDataRegistry
    local gameData = registry and type(registry.Describe) == "function" and registry:Describe() or nil
    local persistence = S.Persistence and type(S.Persistence.Describe) == "function" and S.Persistence:Describe() or nil
    local staticDataV2 = S.StaticDataV2 and type(S.StaticDataV2.Describe) == "function" and S.StaticDataV2:Describe() or nil
    local uiHosts = S.UIHostManager and type(S.UIHostManager.Describe) == "function" and S.UIHostManager:Describe() or nil
    local snap = {
        version = tostring(S.Version or ""),
        buildTag = tostring(S.BuildTag or ""),
        generation = tonumber(S.Generation) or 0,
        saveSchema = S.Constants and S.Constants.SaveSchemaVersion or nil,
        moduleStates = {}, hudStates = {}, api = { total=0, allowed=0, unavailable=0, retired=0, conflicts=0 },
        schedulerTasks = S.Scheduler and CountTable(S.Scheduler.tasks) or 0,
        backlog = S.Scheduler and type(S.Scheduler.DescribeBacklog)=="function" and S.Scheduler:DescribeBacklog() or {health="Unknown",pending=0},
        performance = S.PerformanceMonitor and type(S.PerformanceMonitor.Snapshot)=="function" and S.PerformanceMonitor:Snapshot() or nil,
        frameBudget = S.FrameBudget and type(S.FrameBudget.Describe)=="function" and S.FrameBudget:Describe() or nil,
        demand = S.Demand and type(S.Demand.Describe)=="function" and S.Demand:Describe() or nil,
        refreshCoordinator = S.RefreshCoordinator and type(S.RefreshCoordinator.Describe)=="function" and S.RefreshCoordinator:Describe() or nil,
        auraObservation = S.Services and S.Services.AuraObservationV3 and type(S.Services.AuraObservationV3.GetHealth)=="function" and S.Services.AuraObservationV3:GetHealth() or nil,
        buffDisplay = S.Features and S.Features.BuffDisplay and type(S.Features.BuffDisplay.GetHealth)=="function" and S.Features.BuffDisplay:GetHealth() or nil,
        unitLines = S.Features and S.Features.combat_unit_lines and type(S.Features.combat_unit_lines.Diagnostics)=="table" and S.Features.combat_unit_lines.Diagnostics or nil,
        bossAlerts = S.Features and S.Features.combat_boss_alerts and type(S.Features.combat_boss_alerts._bossDiag)=="table" and S.Features.combat_boss_alerts._bossDiag or nil,
        unitIdentity = S.Services and S.Services.UnitIdentityV3 and type(S.Services.UnitIdentityV3.GetHealth)=="function" and S.Services.UnitIdentityV3:GetHealth() or nil,
        combatRelation = S.Services and S.Services.CombatRelationV3 and type(S.Services.CombatRelationV3.GetHealth)=="function" and S.Services.CombatRelationV3:GetHealth() or nil,
        teamRoster = S.Services and S.Services.TeamRosterV3 and type(S.Services.TeamRosterV3.GetHealth)=="function" and S.Services.TeamRosterV3:GetHealth() or nil,
        screenProjection = S.Services and S.Services.ScreenProjectionV3 and type(S.Services.ScreenProjectionV3.GetHealth)=="function" and S.Services.ScreenProjectionV3:GetHealth() or nil,
        combatEventBus = S.Services and S.Services.CombatEventBusV3 and type(S.Services.CombatEventBusV3.GetHealth)=="function" and S.Services.CombatEventBusV3:GetHealth() or nil,
        deathReview = S.Features and S.Features.DeathReview and type(S.Features.DeathReview.GetHealth)=="function" and S.Features.DeathReview:GetHealth() or nil,
        ui = S.UI and type(S.UI.GetFrameworkSnapshot)=="function" and S.UI:GetFrameworkSnapshot() or nil,
        uiFoundation = {
            viewState = S.RSUI and S.RSUI.ViewState and type(S.RSUI.ViewState.GetSnapshot) == "function" and S.RSUI.ViewState:GetSnapshot() or nil,
            actions = S.ActionRunner and type(S.ActionRunner.GetSnapshot) == "function" and S.ActionRunner:GetSnapshot() or nil,
            binding = S.UI and S.UI.Binding and type(S.UI.Binding.GetSnapshot) == "function" and S.UI.Binding:GetSnapshot() or nil,
            floating = S.RSUI and S.RSUI.FloatingSurface and type(S.RSUI.FloatingSurface.GetSnapshot) == "function" and S.RSUI.FloatingSurface:GetSnapshot() or nil,
            screenSnap = S.Layout and type(S.Layout.GetScreenSnapSnapshot) == "function" and S.Layout:GetScreenSnapSnapshot() or nil,
        },
        clientLanguage = "Unknown",
        moduleFaults = S.Diagnostics and CountTable(S.Diagnostics.moduleFaults) or 0,
        persistenceError = persistence ~= nil and (tonumber(persistence.fenced) or 0) > 0 or false,
        persistenceScope = {
            stores = persistence and tonumber(persistence.total) or 0,
            dirty = persistence and tonumber(persistence.dirty) or 0,
            fenced = persistence and tonumber(persistence.fenced) or 0,
            scopePending = persistence and tonumber(persistence.scopePending) or 0,
            budgetProtected = persistence and tonumber(persistence.budgetProtected) or 0,
        },
        structured = {
            recent = #self.recent,
            suppressed = tonumber(self.suppressed) or 0,
            rateKeys = CountTable(self.rate),
            counters = self:GetCounters(8),
        },
        gameData = gameData,
        staticDataV2 = staticDataV2,
        persistence = persistence,
        uiHosts = uiHosts,
        foundation = S.FoundationGate and S.FoundationGate.last or nil,
        recentErrors = {},
        migration = S.Migration and S.Migration:Describe() or nil,
    }
    if S.ModuleManager ~= nil then snap.moduleStates = S.ModuleManager:List(true) end
    if S.HudManager ~= nil then snap.hudStates = S.HudManager:List() end
    if S.ApiCapabilities ~= nil and type(S.ApiCapabilities.ProbeGetter) == "function" then
        local ok, locale = S.ApiCapabilities:ProbeGetter("X2Locale:GetLocale")
        if ok and locale ~= nil and tostring(locale) ~= "" then snap.clientLanguage = tostring(locale) end
    end
    if S.ApiCapabilities ~= nil and type(S.ApiCapabilities.records) == "table" then
        for name, info in pairs(S.ApiCapabilities.records) do
            snap.api.total = snap.api.total + 1
            local official = tostring(info.OfficialState or "Unknown")
            local retired = official == "Removed" or official == "OfficialDisabled"
            local allowed = S.ApiCapabilities:IsAllowed(name)
            if retired then snap.api.retired = snap.api.retired + 1
            elseif allowed then snap.api.allowed = snap.api.allowed + 1
            else snap.api.unavailable = snap.api.unavailable + 1 end
            local static = tostring(info.StaticState or "Unknown")
            if (official == "OfficialEnabled" and static == "Unavailable") or (retired and static == "Available") then
                snap.api.conflicts = snap.api.conflicts + 1
            end
        end
    end
    for _, item in ipairs(self.recent) do
        if item.level == "error" or item.level == "warning" then snap.recentErrors[#snap.recentErrors + 1] = item end
    end
    return snap
end

function D:BuildModuleSummary(moduleId)
    moduleId = tostring(moduleId or "")
    local snap = self:Snapshot()
    for _, item in ipairs(snap.moduleStates or {}) do
        if tostring(item.id or "") == moduleId then
            local hudVisible, hudTotal = 0, 0
            for _, hud in ipairs(snap.hudStates or {}) do
                if tostring(hud.moduleId or "") == moduleId then
                    hudTotal = hudTotal + 1
                    if hud.effectiveVisible then hudVisible = hudVisible + 1 end
                end
            end
            return table.concat({
                tostring(item.name or moduleId) .. " · " .. tostring(item.state or "Unknown"),
                "Enabled：" .. tostring(item.enabled == true) .. " · DataScope：" .. tostring(item.dataScope or "unknown"),
                "HUD：" .. tostring(hudVisible) .. "/" .. tostring(hudTotal),
                "Backlog：" .. tostring(snap.backlog and snap.backlog.health or "Unknown"),
                item.lastError and ("最近故障：" .. tostring(item.lastError)) or "最近故障：无",
            }, "\n")
        end
    end
    return "未找到模块：" .. moduleId
end

function D:BuildSummary()
    local snap = self:Snapshot()
    local enabled, faulted = 0, 0
    for _, item in ipairs(snap.moduleStates) do
        if item.enabled then enabled = enabled + 1 end
        if item.state == "Faulted" then faulted = faulted + 1 end
    end
    local visible = 0
    for _, item in ipairs(snap.hudStates) do if item.effectiveVisible then visible = visible + 1 end end
    local gd = snap.gameData or {}
    return table.concat({
        "Replicated Suite " .. snap.version .. (snap.buildTag ~= "" and (" · " .. snap.buildTag) or "") .. " · Schema " .. tostring(snap.saveSchema or "?") .. " · 语言 " .. tostring(snap.clientLanguage or "Unknown"),
        "模块：启用 " .. tostring(enabled) .. " / 故障 " .. tostring(faulted) .. " / 总计 " .. tostring(#snap.moduleStates),
        "HUD：有效显示 " .. tostring(visible) .. " / 已注册 " .. tostring(#snap.hudStates),
        "API：可用 " .. tostring(snap.api.allowed) .. " / 缺失 " .. tostring(snap.api.unavailable) .. " / 已移除 " .. tostring(snap.api.retired or 0) .. " / 冲突 " .. tostring(snap.api.conflicts),
        "Diagnostics：结构化 " .. tostring(snap.structured and snap.structured.recent or 0) .. " · 限频抑制 " .. tostring(snap.structured and snap.structured.suppressed or 0),
        "GameData：记录 " .. tostring(gd.totalRecords or 0) .. " · 集合 " .. tostring(gd.totalSets or 0) .. " · 无效 " .. tostring(gd.invalid or 0) .. " · 重复Key " .. tostring(gd.duplicateKeys or 0),
        "Persistence：Store " .. tostring(snap.persistence and snap.persistence.total or 0) .. " · Dirty " .. tostring(snap.persistence and snap.persistence.dirty or 0) .. " · 写保护 " .. tostring(snap.persistence and snap.persistence.fenced or 0),
        "UI：Diff尝试 " .. tostring(snap.ui and snap.ui.attempts or 0) .. " · Native写 " .. tostring(snap.ui and snap.ui.nativeCalls or 0) .. " · 跳过 " .. tostring(snap.ui and snap.ui.skips or 0) .. "（" .. string.format("%.1f%%", (tonumber(snap.ui and snap.ui.skipRatio) or 0) * 100) .. "）",
        "UI Foundation：Floating " .. tostring(snap.uiFoundation and snap.uiFoundation.floating and snap.uiFoundation.floating.active or 0)
            .. " · Snap " .. tostring(snap.uiFoundation and snap.uiFoundation.screenSnap and snap.uiFoundation.screenSnap.registered or 0)
            .. " · View R/E/Err " .. tostring(snap.uiFoundation and snap.uiFoundation.viewState and snap.uiFoundation.viewState.states and snap.uiFoundation.viewState.states.ready or 0)
            .. "/" .. tostring(snap.uiFoundation and snap.uiFoundation.viewState and snap.uiFoundation.viewState.states and snap.uiFoundation.viewState.states.empty or 0)
            .. "/" .. tostring(snap.uiFoundation and snap.uiFoundation.viewState and snap.uiFoundation.viewState.states and snap.uiFoundation.viewState.states.error or 0)
            .. " · Action Busy " .. tostring(snap.uiFoundation and snap.uiFoundation.actions and snap.uiFoundation.actions.busy or 0)
            .. " · Binding A/D/E " .. tostring(snap.uiFoundation and snap.uiFoundation.binding and snap.uiFoundation.binding.active or 0)
            .. "/" .. tostring(snap.uiFoundation and snap.uiFoundation.binding and snap.uiFoundation.binding.dirty or 0)
            .. "/" .. tostring(snap.uiFoundation and snap.uiFoundation.binding and snap.uiFoundation.binding.errored or 0),
        "Combat Foundation：Bus " .. tostring(snap.combatEventBus and snap.combatEventBus.running and "RUN" or "idle")
            .. " · Consumer " .. tostring(snap.combatEventBus and snap.combatEventBus.consumers or 0)
            .. " · Coverage " .. tostring(snap.combatEventBus and snap.combatEventBus.coverageState or "INACTIVE")
            .. " · Host " .. tostring(snap.combatEventBus and snap.combatEventBus.globalHosts or 0) .. "/2"
            .. " · Park P/G " .. tostring(snap.combatEventBus and snap.combatEventBus.privateParked == true and 1 or 0)
            .. "/" .. tostring(snap.combatEventBus and snap.combatEventBus.globalParkedHosts or 0)
            .. " · Journal P/R/D " .. tostring(snap.combatEventBus and snap.combatEventBus.journalPending or 0)
            .. "/" .. tostring(snap.combatEventBus and snap.combatEventBus.journalReplayed or 0)
            .. "/" .. tostring(snap.combatEventBus and snap.combatEventBus.journalDropped or 0)
            .. " · Facts " .. tostring(snap.combatEventBus and snap.combatEventBus.received or 0) .. "/" .. tostring(snap.combatEventBus and snap.combatEventBus.delivered or 0)
            .. " · Mut " .. tostring(snap.combatEventBus and snap.combatEventBus.factMutationErrors or 0)
            .. " · Identity " .. tostring(snap.unitIdentity and snap.unitIdentity.cache or 0) .. "/" .. tostring(snap.unitIdentity and snap.unitIdentity.cacheMax or 0)
            .. " · Bind " .. tostring(snap.unitIdentity and snap.unitIdentity.endpointBinds or 0)
            .. " · Player " .. tostring(snap.unitIdentity and snap.unitIdentity.playerReady == true and "ready" or "pending")
            .. " · DeathReview " .. tostring(snap.deathReview and snap.deathReview.ok == true and "ON" or "off")
            .. " H" .. tostring(snap.deathReview and snap.deathReview.history or 0)
            .. "/D" .. tostring(snap.deathReview and snap.deathReview.deaths or 0)
            .. "/Q" .. tostring(snap.deathReview and snap.deathReview.pendingDeath == true and 1 or 0)
            .. "/F" .. tostring(snap.deathReview and snap.deathReview.deferredFinalizeFailures or 0),
        "BuffDisplay：" .. tostring(snap.buffDisplay and snap.buffDisplay.ok == true and "ON" or "off")
            .. " · Consumer " .. tostring(snap.buffDisplay and snap.buffDisplay.consumers or 0)
            .. " · Aura " .. tostring(snap.buffDisplay and snap.buffDisplay.auraHeld == true and "held" or "idle")
            .. " · Task " .. tostring(snap.buffDisplay and snap.buffDisplay.taskActive == true and "active" or "idle")
            .. " · Revision " .. tostring(snap.buffDisplay and snap.buffDisplay.revision or 0),
        D.BuffGearLine(snap),
        D.UnitLineLine(snap),
        D.BossLine(snap),
        "调度任务：" .. tostring(snap.schedulerTasks) .. " · 积压状态：" .. tostring(snap.backlog and snap.backlog.health or "未知") .. "(" .. tostring(snap.backlog and snap.backlog.pending or 0) .. ") · 预算延期 " .. tostring(snap.backlog and snap.backlog.deferredByBudget or 0) .. " · 新版存档：" .. (snap.persistenceError and "写保护" or "正常"),
        snap.frameBudget and ("FrameBudget：" .. tostring(snap.frameBudget.pressure or "Normal") .. " · Credit " .. tostring(snap.frameBudget.creditsRemaining or 0) .. "/" .. tostring(snap.frameBudget.creditsTotal or 0) .. " · 执行 " .. tostring(snap.frameBudget.granted or 0) .. " · 延期 " .. tostring(snap.frameBudget.deferred or 0) .. " · 饥饿保底 " .. tostring(snap.frameBudget.starvationRuns or 0)) or "FrameBudget：未加载",
        snap.performance and ("性能：最近帧 " .. string.format("%.1f", tonumber(snap.performance.lastFrameMs) or 0) .. "ms · 最大 " .. string.format("%.1f", tonumber(snap.performance.maxFrameMs) or 0) .. "ms · 卡顿 " .. tostring(snap.performance.jankCount or 0) .. " · 未归因 " .. tostring(snap.performance.unattributedStalls or 0) .. " · 详细计时 " .. (snap.performance.timerAvailable and "可用" or "不可用")) or "性能：监控尚未加载",
        "存档作用域：仓库 " .. tostring(snap.persistenceScope and snap.persistenceScope.stores or 0)
            .. " · 待写 " .. tostring(snap.persistenceScope and snap.persistenceScope.dirty or 0)
            .. " · 写保护 " .. tostring(snap.persistenceScope and snap.persistenceScope.fenced or 0)
            .. " · 作用域待解析 " .. tostring(snap.persistenceScope and snap.persistenceScope.scopePending or 0),
        "迁移：" .. tostring(snap.migration and snap.migration.suiteStatus or "unknown") .. " · 旧运行时：不启用",
    }, "\n")
end

function D:BuildAllLogs()
    local snap = self:Snapshot()
    local sections = {}
    sections[#sections + 1] = "【诊断摘要】 " .. CompactLogText(self:BuildSummary()):gsub(" ↳ ", " ｜ ")
    if S.PerformanceMonitor ~= nil and type(S.PerformanceMonitor.BuildSummary) == "function" then
        sections[#sections + 1] = "【" .. CompactLogText(S.PerformanceMonitor:BuildSummary()) .. "】"
        for _, row in ipairs(S.PerformanceMonitor:GetTop(6) or {}) do
            local average = row.calls > 0 and row.totalMs / row.calls or 0
            sections[#sections + 1] = string.format("性能 %s：调用 %d · 总 %.3fms · 均 %.3fms · 最大 %.3fms · 卡顿关联 %d",
                tostring(row.label), tonumber(row.calls) or 0, tonumber(row.totalMs) or 0, average, tonumber(row.maxMs) or 0, tonumber(row.jankHits) or 0)
        end
        for _, row in ipairs(S.PerformanceMonitor:GetTopModules(6) or {}) do
            local average = row.calls > 0 and row.totalMs / row.calls or 0
            sections[#sections + 1] = string.format("模块性能 %s：调用 %d · 总 %.3fms · 均 %.3fms · 最大 %.3fms · 卡顿关联 %d",
                tostring(row.moduleId), tonumber(row.calls) or 0, tonumber(row.totalMs) or 0, average, tonumber(row.maxMs) or 0, tonumber(row.jankHits) or 0)
        end
        for _, row in ipairs(S.PerformanceMonitor:GetWorstJank(3) or {}) do
            sections[#sections + 1] = string.format("卡顿采样 %.1fms（原生 %.1fms%s）：%s · 模块 %s · 标签 %s · Backlog %d",
                tonumber(row.dtMs) or 0, tonumber(row.nativeDtMs) or tonumber(row.dtMs) or 0,
                row.clockGapMs ~= nil and (" · 脚本间隔 " .. string.format("%.1f", tonumber(row.clockGapMs) or 0) .. "ms") or "",
                tostring(row.kind or "关联上一帧 Suite 回调"), tostring(row.modules or "无 Suite 模块"), tostring(row.labels or "无 Suite 回调"), tonumber(row.pending) or 0)
        end
        local startup = S.PerformanceMonitor:GetStartup() or {}
        if #startup > 0 then
            local parts = {}
            for _, row in ipairs(startup) do parts[#parts + 1] = tostring(row.label) .. "=" .. string.format("%.1f", tonumber(row.elapsedMs) or 0) .. "ms" end
            sections[#sections + 1] = "启动阶段：" .. table.concat(parts, " · ")
        end
    end

    local frameBudget = snap.frameBudget
    if type(frameBudget) == "table" then
        sections[#sections + 1] = string.format("FrameBudget v%s：%s · 帧 %.1fms · Credit %d/%d · 执行 %d · 延期 %d · 关键通行 %d · 饥饿保底 %d · Pending %d→%d",
            tostring(frameBudget.version or "?"), tostring(frameBudget.pressure or "Normal"), tonumber(frameBudget.frameDtMs) or 0,
            tonumber(frameBudget.creditsRemaining) or 0, tonumber(frameBudget.creditsTotal) or 0, tonumber(frameBudget.granted) or 0,
            tonumber(frameBudget.deferred) or 0, tonumber(frameBudget.criticalGranted) or 0, tonumber(frameBudget.starvationRuns) or 0,
            tonumber(frameBudget.pendingBefore) or 0, tonumber(frameBudget.pendingAfter) or 0)
        local totals = frameBudget.totals or {}
        sections[#sections + 1] = string.format("FrameBudget累计：帧 %d · 请求 %d · 通行 %d · 延期 %d · 关键通行 %d · 饥饿保底 %d",
            tonumber(totals.frames) or 0, tonumber(totals.requests) or 0, tonumber(totals.granted) or 0,
            tonumber(totals.deferred) or 0, tonumber(totals.criticalGranted) or 0, tonumber(totals.starvationRuns) or 0)
        for _, row in ipairs(frameBudget.topDeferred or {}) do
            sections[#sections + 1] = string.format("Budget延期 %s：请求 %d · 通行 %d · 延期 %d · 保底 %d · 最大连续延期 %d",
                tostring(row.owner), tonumber(row.requests) or 0, tonumber(row.granted) or 0, tonumber(row.deferred) or 0,
                tonumber(row.starvationRuns) or 0, tonumber(row.maxConsecutiveDefers) or 0)
        end
    end

    local healerRuntime = snap.professionalRuntime and snap.professionalRuntime.healer or nil
    if type(healerRuntime) == "table" then
        local health = healerRuntime.health or {}
        local status = healerRuntime.status or {}
        local deferred = healerRuntime.deferred or {}
        local rosterInfo = healerRuntime.roster or {}
        local rosterCycle = rosterInfo.cycle or {}
        local rosterMetrics = rosterInfo.metrics or {}
        local apiInfo = healerRuntime.api or {}
        sections[#sections + 1] = string.format(
            "Healer Runtime v%s：%s · Roster %d / Gen %d ready=%s invalid=%s（phase=%s slot=%d/%d staged=%d role=%d nativeRole=%s, slotMax=%d, roleMax=%d, roleReads=%d, reused=%d） · API unit=%d fail=%d role=%d roleFail=%d invalidRole=%d · HealthGen %d（%d/%d active=%s, slice=%d, max=%d, targetedStatus=%d, targetedMax=%d） · StatusGen %d（%d/%d active=%s, slice=%d, max=%d） · 延期 roster=%d status=%d visual=%d settings=%d",
            tostring(healerRuntime.version or "?"), tostring(healerRuntime.rosterMode or "none"), tonumber(healerRuntime.rosterCount) or 0,
            tonumber(rosterInfo.generation) or 0, tostring(rosterInfo.ready == true), tostring(rosterInfo.invalidated == true), tostring(rosterCycle.phase or "idle"),
            tonumber(rosterCycle.slotCursor) or 0, tonumber(rosterCycle.maxSlots) or 0, tonumber(rosterCycle.staged) or 0, tonumber(rosterCycle.roleCursor) or 0,
            tostring(rosterCycle.needNativeRoles == true), tonumber(rosterMetrics.maxSlotSlice) or 0, tonumber(rosterMetrics.maxRoleSlice) or 0,
            tonumber(rosterMetrics.roleReads) or 0, tonumber(rosterMetrics.rolesReused) or 0,
            tonumber(apiInfo.unitCalls) or 0, tonumber(apiInfo.unitFailures) or 0, tonumber(apiInfo.roleCalls) or 0,
            tonumber(apiInfo.roleFailures) or 0, tonumber(apiInfo.invalidRoleRequests) or 0,
            tonumber(healerRuntime.healthGeneration) or 0, tonumber(health.cursor) or 0, tonumber(health.total) or 0, tostring(health.active == true),
            tonumber(health.slice) or 0, tonumber(health.maxSlice) or 0, tonumber(health.targetedStatusRefreshes) or 0,
            tonumber(health.maxTargetedStatusRefreshSlice) or 0, tonumber(healerRuntime.statusGeneration) or 0,
            tonumber(status.cursor) or 0, tonumber(status.total) or 0, tostring(status.active == true), tonumber(status.slice) or 0, tonumber(status.maxSlice) or 0,
            tonumber(deferred.roster) or 0, tonumber(deferred.status) or 0, tonumber(deferred.visual) or 0, tonumber(deferred.settings) or 0)

        local statusDomain = healerRuntime.statusDomain or {}
        local recommendationDomain = healerRuntime.recommendationDomain or {}
        local markerPresenter = healerRuntime.markerPresenter or {}
        local raidPresenter = healerRuntime.raidPresenter or {}
        sections[#sections + 1] = string.format(
            "Healer Domain：Status v%s members=%d reads=%d commits=%d · Recommendation v%s rows=%d eval=%d publish=%d · Marker v%s allocated=%d active=%d · Raid v%s overlays=%d visible=%d calibration=%s",
            tostring(statusDomain.version or "?"), tonumber(statusDomain.members) or 0, tonumber(statusDomain.reads) or 0, tonumber(statusDomain.commits) or 0,
            tostring(recommendationDomain.version or "?"), tonumber(recommendationDomain.recommendations) or 0, tonumber(recommendationDomain.evaluations) or 0, tonumber(recommendationDomain.publications) or 0,
            tostring(markerPresenter.version or "?"), tonumber(markerPresenter.allocated) or 0, tonumber(markerPresenter.active) or 0,
            tostring(raidPresenter.version or "?"), tonumber(raidPresenter.overlays) or 0, tonumber(raidPresenter.visible) or 0, tostring(raidPresenter.calibration == true))

        local settingsModel = healerRuntime.settingsModel or {}
        local settingsMigrations = healerRuntime.settingsMigrations or {}
        local settingsBootstrap = healerRuntime.settingsBootstrap or {}
        local settingsStore = healerRuntime.settingsStore or {}
        local settingsPresenter = healerRuntime.settingsPresenter or {}
        sections[#sections + 1] = string.format(
            "Healer Settings：Model v%s normalize=%d coerce=%d reject=%d · Migration v%s runs=%d applied=%d · Boot v%s loads=%d backup=%d future=%d · Store v%s dirty=%s fenced=%s flush=%d fail=%d · Presenter v%s read=%d write=%d reject=%d projection=%d",
            tostring(settingsModel.version or "?"), tonumber(settingsModel.normalizeState) or 0, tonumber(settingsModel.settingCoercions) or 0, tonumber(settingsModel.settingRejects) or 0,
            tostring(settingsMigrations.version or "?"), tonumber(settingsMigrations.runs) or 0, tonumber(settingsMigrations.applied) or 0,
            tostring(settingsBootstrap.version or "?"), tonumber(settingsBootstrap.loads) or 0, tonumber(settingsBootstrap.backup) or 0, tonumber(settingsBootstrap.futureSchema) or 0,
            tostring(settingsStore.version or "?"), tostring(settingsStore.dirty == true), tostring(settingsStore.writeFenced == true), tonumber(settingsStore.flushes) or 0, tonumber(settingsStore.flushFailures) or 0,
            tostring(settingsPresenter.version or "?"), tonumber(settingsPresenter.reads) or 0, tonumber(settingsPresenter.writes) or 0, tonumber(settingsPresenter.rejected) or 0, tonumber(settingsPresenter.projections) or 0)
    end

    local platesRuntime = snap.professionalRuntime and snap.professionalRuntime.plates or nil
    if type(platesRuntime) == "table" then
        local pb = platesRuntime.budget or {}
        local pw = platesRuntime.watchdog or {}
        sections[#sections + 1] = string.format(
            "Plates Runtime v%s：running=%s heartbeat=%d success=%d · Budget request=%d grant=%d defer=%d starvation=%d · Watchdog recoveries=%d attempts=%d success=%d budgetDefer=%d pending=%s · visibilityRepair=%d",
            tostring(platesRuntime.version or "?"), tostring(platesRuntime.running == true), tonumber(platesRuntime.heartbeat) or 0,
            tonumber(platesRuntime.successfulUpdates) or 0, tonumber(pb.requests) or 0, tonumber(pb.granted) or 0,
            tonumber(pb.deferred) or 0, tonumber(pb.starvation) or 0, tonumber(pw.recoveries) or 0,
            tonumber(pw.attempts) or 0, tonumber(pw.successes) or 0, tonumber(pw.budgetDeferrals) or 0,
            tostring(pw.pending == true), tonumber(pw.visibilityRepairs) or 0)
        for _, row in ipairs(pb.topDeferred or {}) do
            sections[#sections + 1] = string.format(
                "Plates Budget延期 %s：request=%d grant=%d defer=%d starvation=%d consecutive=%d max=%d reason=%s",
                tostring(row.label), tonumber(row.requests) or 0, tonumber(row.granted) or 0, tonumber(row.deferred) or 0,
                tonumber(row.starvation) or 0, tonumber(row.consecutiveDefers) or 0, tonumber(row.maxConsecutiveDefers) or 0,
                tostring(row.lastReason or ""))
        end
        local pui = platesRuntime.ui or {}
        local pe, pl, pc = pui.effects or {}, pui.lines or {}, pui.circle or {}
        sections[#sections + 1] = string.format(
            "Plates UI Diff：Effect update=%d visible=%d peak=%d hide=%d texture=%d · Lines frame=%d active=%d peak=%d staleHide=%d · Circle frame=%d active=%d peak=%d staleHide=%d",
            tonumber(pe.updates) or 0, tonumber(pe.visible) or 0, tonumber(pe.peakVisible) or 0, tonumber(pe.hidden) or 0, tonumber(pe.textureChanges) or 0,
            tonumber(pl.frames) or 0, tonumber(pl.active) or 0, tonumber(pl.peakActive) or 0, tonumber(pl.staleHides) or 0,
            tonumber(pc.frames) or 0, tonumber(pc.active) or 0, tonumber(pc.peakActive) or 0, tonumber(pc.staleHides) or 0)
        for _, row in ipairs(pui.frameworkOwners or {}) do
            sections[#sections + 1] = string.format("Plates UI Owner %s：attempt=%d write=%d skip=%d native=%d",
                tostring(row.owner or "?"), tonumber(row.attempts) or 0, tonumber(row.writes) or 0, tonumber(row.skips) or 0, tonumber(row.nativeCalls) or 0)
        end
    end

    local gameData = S.GameDataRegistry and type(S.GameDataRegistry.Validate) == "function" and S.GameDataRegistry:Validate() or nil
    if gameData ~= nil then
        sections[#sections + 1] = string.format("GameData校验：%s · 记录 %d · 集合 %d · 错误 %d · 别名/重复ID %d",
            gameData.ok and "OK" or "ISSUES", tonumber(gameData.totalRecords) or 0, tonumber(gameData.totalSets) or 0,
            tonumber(gameData.errors) or 0, tonumber(gameData.warnings) or 0)
    end
    local persistence = snap.persistence
    if type(persistence) == "table" then
        sections[#sections + 1] = string.format("Persistence：Store %d · Dirty %d · 写保护 %d · Load失败 %d · Save失败 %d · 迁移 %d · 周期重置 %d",
            tonumber(persistence.total) or 0, tonumber(persistence.dirty) or 0, tonumber(persistence.fenced) or 0,
            tonumber(persistence.stats and persistence.stats.loadFailures) or 0, tonumber(persistence.stats and persistence.stats.saveFailures) or 0,
            tonumber(persistence.stats and persistence.stats.migrations) or 0, tonumber(persistence.stats and persistence.stats.periodResets) or 0)
        for _, row in ipairs(persistence.rows or {}) do
            sections[#sections + 1] = string.format("Store %s｜%s/%s · Schema %s · %s%s%s%s",
                tostring(row.id), tostring(row.owner), tostring(row.lifetime), tostring(row.schema), tostring(row.loadStatus or "unknown"),
                row.periodId and (" · Period " .. tostring(row.periodId)) or "",
                row.writeFenced and (" · 写保护 " .. tostring(row.writeFenceReason or "unknown")) or (row.dirty and " · Dirty" or ""),
                row.lastIntegrityStatus ~= nil and (" · 完整性 " .. tostring(row.lastIntegrityStatus)
                    .. (row.lastIntegrityError and ("（" .. tostring(row.lastIntegrityError) .. "）") or "")) or "")
        end
    end
    local ui = snap.ui
    if type(ui) == "table" then
        sections[#sections + 1] = string.format("UI Framework v%s：缓存Widget %d · Owner %d · Diff尝试 %d · 实际写 %d · 跳过 %d（%.1f%%）· Native调用 %d",
            tostring(ui.version or "?"), tonumber(ui.cachedWidgets) or 0, tonumber(ui.owners) or 0, tonumber(ui.attempts) or 0,
            tonumber(ui.writes) or 0, tonumber(ui.skips) or 0, (tonumber(ui.skipRatio) or 0) * 100, tonumber(ui.nativeCalls) or 0)
        local inputLife = ui.lifecycle or {}
        sections[#sections + 1] = string.format("UI输入：激活 %d/%d · 失败 %d · PostArmFocus %d · FocusFast %d · ArmedNow %d · Keyboard %d/%d · ArmFail %d · FocusClearFail %d",
            tonumber(inputLife.inputActivationSuccesses) or 0, tonumber(inputLife.inputActivationAttempts) or 0,
            tonumber(inputLife.inputActivationFailures) or 0, tonumber(inputLife.postArmFocusPromotions) or 0,
            tonumber(inputLife.focusedFastPathHits) or 0, tonumber(inputLife.armedInputs) or 0,
            tonumber(inputLife.keyboardArms) or 0, tonumber(inputLife.keyboardDisarms) or 0,
            tonumber(inputLife.keyboardArmFailures) or 0, tonumber(inputLife.focusClearFailures) or 0)
        local design = ui.design or {}
        local lm, bm, sm, cm, rm = design.layout or {}, design.binding or {}, design.shell or {}, design.components or {}, design.rsui or {}
        sections[#sections + 1] = string.format("UI Design v%s：Layout %d次/%d放置/%d响应 · Binding %d写/%d拒绝/%d提交 · Field %d创建/%d渲染/%d校验错 · RSUI %d创建/%d类/%d错 · 压缩%d/越界%d/失效%d/滚动%d · Shell %d创建/%d布局",
            tostring(design.tokens or "?"), tonumber(lm.passes) or 0, tonumber(lm.placements) or 0, tonumber(lm.responsive) or 0,
            tonumber(bm.writes) or 0, tonumber(bm.rejected) or 0, tonumber(bm.commits) or 0,
            tonumber(cm.created) or 0, tonumber(cm.renders) or 0, tonumber(cm.validationErrors) or 0,
            tonumber(rm.created) or 0, tonumber(rm.registeredTypes) or 0, tonumber(rm.errors) or 0,
            tonumber(rm.layoutCompressionEvents) or 0, tonumber(rm.layoutOverflowEvents) or 0, tonumber(rm.invalidations) or 0, tonumber(rm.scrollChanges) or 0,
            tonumber(sm.created) or 0, tonumber(sm.layoutPasses) or 0)
        sections[#sections + 1] = string.format("RSUI布局安全：Measure %d/%d · Arrange %d/%d · Viewport刷新 %d · SafeZone夹紧 %d · 屏幕边界 %d · Visibility %d · DebugOverlay %d",
            tonumber(rm.measurePasses) or 0, tonumber(rm.measureSkips) or 0, tonumber(rm.layoutPasses) or 0, tonumber(rm.layoutSkips) or 0,
            tonumber(rm.viewportRefreshes) or 0, tonumber(rm.safeZoneClamps) or 0, tonumber(rm.screenBoundaryIssues) or 0,
            tonumber(rm.visibilityChanges) or 0, tonumber(rm.debugOverlayRefreshes) or 0)
        sections[#sections + 1] = string.format("RSUI重排/重叠：入队 %d · Flush %d · Reflow %d · 延期 %d · SiblingOverlap %d",
            tonumber(rm.layoutRootsQueued) or 0, tonumber(rm.layoutFlushes) or 0, tonumber(rm.layoutRootsReflowed) or 0,
            tonumber(rm.layoutFlushDeferrals) or 0, tonumber(rm.siblingOverlapIssues) or 0)
        sections[#sections + 1] = string.format("RSUI数据视图：Pool创建 %d · Row绑定 %d · Row复用 %d · Reconcile %d · 数据刷新 %d · 可见峰值 %d · 表格列解析 %d · 极限夹紧 %d",
            tonumber(rm.virtualPoolRowsCreated) or 0, tonumber(rm.virtualRowBinds) or 0, tonumber(rm.virtualRowReuses) or 0,
            tonumber(rm.virtualReconciles) or 0, tonumber(rm.virtualDataRefreshes) or 0, tonumber(rm.virtualVisibleRowsPeak) or 0,
            tonumber(rm.tableColumnResolves) or 0, tonumber(rm.tableEmergencyClamps) or 0)
        sections[#sections + 1] = string.format("RSUI选择/Tile：Selection %d模型/%d变化 · 高亮 %d池/%d应用 · Tile池 %d/绑定 %d/复用 %d/Reconcile %d · 列变化 %d · 可见峰值 %d · Header点击 %d/排序 %d/列宽 %d",
            tonumber(rm.selectionModelsCreated) or 0, tonumber(rm.selectionChanges) or 0,
            tonumber(rm.selectionVisualsCreated) or 0, tonumber(rm.selectionVisualApplications) or 0,
            tonumber(rm.tilePoolItemsCreated) or 0, tonumber(rm.tileItemBinds) or 0, tonumber(rm.tileItemReuses) or 0, tonumber(rm.tileReconciles) or 0,
            tonumber(rm.tileColumnChanges) or 0, tonumber(rm.tileVisibleItemsPeak) or 0, tonumber(rm.tableHeaderClicks) or 0,
            tonumber(rm.tableSortChanges) or 0, tonumber(rm.tableColumnWidthChanges) or 0)
        sections[#sections + 1] = string.format("RSUI交互/毕业：Event订阅 %d/派发 %d · Tooltip %d绑/%d显 · Menu %d开/%d动作/%d池行 · Focus %d · Playground %d/Stress %d",
            tonumber(rm.eventSubscriptions) or 0, tonumber(rm.eventDispatches) or 0,
            tonumber(rm.tooltipBindings) or 0, tonumber(rm.tooltipShows) or 0,
            tonumber(rm.contextMenuOpens) or 0, tonumber(rm.contextMenuActions) or 0, tonumber(rm.contextMenuRowsCreated) or 0,
            tonumber(rm.focusChanges) or 0, tonumber(rm.playgroundBuilds) or 0, tonumber(rm.playgroundStressRuns) or 0)
        for i = 1, math.min(6, #(ui.byOp or {})) do
            local row = ui.byOp[i]
            sections[#sections + 1] = string.format("UI操作 %s：尝试 %d · 写 %d · 跳过 %d · Native %d",
                tostring(row.op), tonumber(row.attempts) or 0, tonumber(row.writes) or 0, tonumber(row.skips) or 0, tonumber(row.nativeCalls) or 0)
        end
        for i = 1, math.min(4, #(ui.byOwner or {})) do
            local row = ui.byOwner[i]
            sections[#sections + 1] = string.format("UI Owner %s：尝试 %d · 写 %d · 跳过 %d · Native %d",
                tostring(row.owner), tonumber(row.attempts) or 0, tonumber(row.writes) or 0, tonumber(row.skips) or 0, tonumber(row.nativeCalls) or 0)
        end
    end
    for _, row in ipairs(self:GetCounters(8)) do
        sections[#sections + 1] = string.format("诊断计数 %s/%s：%d", tostring(row.source), tostring(row.code), tonumber(row.count) or 0)
    end

    local logs = type(S.LogBuffer) == "table" and S.LogBuffer or {}
    local dropped = tonumber(S.LogDropped) or 0
    sections[#sections + 1] = "【日志 " .. tostring(#logs) .. " 条"
        .. (dropped > 0 and ("，最早已丢弃 " .. tostring(dropped) .. " 条") or "") .. "】"

    for _, item in ipairs(logs) do
        local at = math.max(0, tonumber(item.at) or 0)
        local seconds = at / 1000
        sections[#sections + 1] = string.format("#%03d +%.3fs [%s/%s] %s",
            tonumber(item.seq) or 0,
            seconds,
            tostring(item.level or "info"),
            tostring(item.source or "suite"),
            CompactLogText(item.message))
    end

    if #logs == 0 then sections[#sections + 1] = "（本次加载尚无日志记录）" end
    return table.concat(sections, "  ║  ")
end

function D:PrintAllLogs()
    local payload = "[Replicated Suite 全部日志] " .. self:BuildAllLogs()
    if type(S.DispatchSystemChat) == "function" then return S.DispatchSystemChat(payload) end
    return false
end

function D:PrintSummary()
    return self:PrintAllLogs()
end
