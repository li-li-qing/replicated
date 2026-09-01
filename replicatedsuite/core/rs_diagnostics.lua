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
        unitIdentity = S.Services and S.Services.UnitIdentityV3 and type(S.Services.UnitIdentityV3.GetHealth)=="function" and S.Services.UnitIdentityV3:GetHealth() or nil,
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
        professionalRuntime = {},
        recentErrors = {},
        migration = S.Migration and S.Migration:Describe() or nil,
    }
    -- Professional modules keep Domain Authority in isolated sandboxes. Read
    -- only their narrow diagnostic facades; Diagnostics never reaches into
    -- module-local mutable tables directly.
    local sandbox = rawget(_G, "ReplicatedSuiteModuleSandbox")
    if sandbox ~= nil and type(sandbox.GetExport) == "function" then
        local healerModule = sandbox:GetExport("healer", "ReplicatedHealerModule")
        if healerModule ~= nil and type(healerModule.GetRuntimeDiagnostics) == "function" then
            local ok, value = pcall(healerModule.GetRuntimeDiagnostics, healerModule)
            if ok and type(value) == "table" then snap.professionalRuntime.healer = value end
        end
        local platesModule = sandbox:GetExport("plates", "ReplicatedPlatesModule")
        if platesModule ~= nil and type(platesModule.GetRuntimeDiagnostics) == "function" then
            local ok, value = pcall(platesModule.GetRuntimeDiagnostics, platesModule)
            if ok and type(value) == "table" then snap.professionalRuntime.plates = value end
        end
    end
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
        snap.professionalRuntime and snap.professionalRuntime.healer and ("Healer Runtime v" .. tostring(snap.professionalRuntime.healer.version or "?")
            .. "：Roster " .. tostring(snap.professionalRuntime.healer.rosterCount or 0)
            .. " / Gen " .. tostring(snap.professionalRuntime.healer.roster and snap.professionalRuntime.healer.roster.generation or 0)
            .. " " .. tostring(snap.professionalRuntime.healer.roster and snap.professionalRuntime.healer.roster.cycle and snap.professionalRuntime.healer.roster.cycle.phase or "idle")
            .. " · Role读取 " .. tostring(snap.professionalRuntime.healer.api and snap.professionalRuntime.healer.api.roleCalls or 0)
            .. " · HealthGen " .. tostring(snap.professionalRuntime.healer.healthGeneration or 0)
            .. " · StatusGen " .. tostring(snap.professionalRuntime.healer.statusGeneration or 0)
            .. " · 紧急状态刷新 " .. tostring(snap.professionalRuntime.healer.health and snap.professionalRuntime.healer.health.targetedStatusRefreshes or 0)
            .. " · Roster延期 " .. tostring(snap.professionalRuntime.healer.deferred and snap.professionalRuntime.healer.deferred.roster or 0)
            .. " · Status延期 " .. tostring(snap.professionalRuntime.healer.deferred and snap.professionalRuntime.healer.deferred.status or 0)
            .. " · Visual延期 " .. tostring(snap.professionalRuntime.healer.deferred and snap.professionalRuntime.healer.deferred.visual or 0)) or "Healer Runtime：未加载",
        snap.professionalRuntime and snap.professionalRuntime.plates and ("Plates Runtime v" .. tostring(snap.professionalRuntime.plates.version or "?")
            .. "：Budget请求 " .. tostring(snap.professionalRuntime.plates.budget and snap.professionalRuntime.plates.budget.requests or 0)
            .. " · 延期 " .. tostring(snap.professionalRuntime.plates.budget and snap.professionalRuntime.plates.budget.deferred or 0)
            .. " · 保底 " .. tostring(snap.professionalRuntime.plates.budget and snap.professionalRuntime.plates.budget.starvation or 0)
            .. " · UI点 " .. tostring(snap.professionalRuntime.plates.ui and snap.professionalRuntime.plates.ui.lines and snap.professionalRuntime.plates.ui.lines.active or 0)
            .. "/" .. tostring(snap.professionalRuntime.plates.ui and snap.professionalRuntime.plates.ui.circle and snap.professionalRuntime.plates.ui.circle.active or 0)
            .. " · Watchdog尝试 " .. tostring(snap.professionalRuntime.plates.watchdog and snap.professionalRuntime.plates.watchdog.attempts or 0)
            .. " · 恢复成功 " .. tostring(snap.professionalRuntime.plates.watchdog and snap.professionalRuntime.plates.watchdog.successes or 0)
            .. " · Watchdog延期 " .. tostring(snap.professionalRuntime.plates.watchdog and snap.professionalRuntime.plates.watchdog.budgetDeferrals or 0)) or "Plates Runtime：未加载",
        snap.professionalRuntime and snap.professionalRuntime.plates and snap.professionalRuntime.plates.storage and ("Plates Storage：Schema " .. tostring(snap.professionalRuntime.plates.storage.schemaVersion or "?")
            .. " · Tracking " .. tostring(snap.professionalRuntime.plates.storage.trackingSharded == true and "sharded" or "legacy")
            .. " · Aura " .. tostring(snap.professionalRuntime.plates.storage.auraSharded == true and "sharded" or "legacy")
            .. " · Dirty " .. tostring(snap.professionalRuntime.plates.storage.dirty == true)
            .. " · Fence " .. tostring(snap.professionalRuntime.plates.storage.writeFence or "none")) or "Plates Storage：未加载",
        snap.professionalRuntime and snap.professionalRuntime.plates and snap.professionalRuntime.plates.manager and ("Plates Manager：" .. tostring(snap.professionalRuntime.plates.manager.catalogMode or "live")
            .. " · Catalog " .. tostring(snap.professionalRuntime.plates.manager.catalogEntries or 0)
            .. " · Discovery " .. tostring(snap.professionalRuntime.plates.manager.discoveryEntries or 0)
            .. " · Capture " .. tostring(snap.professionalRuntime.plates.manager.captureEntries or 0)
            .. " · Staged " .. tostring(snap.professionalRuntime.plates.manager.auraImportStaged == true)) or "Plates Manager：未加载",
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
            sections[#sections + 1] = string.format("Store %s｜%s/%s · Schema %s · %s%s%s",
                tostring(row.id), tostring(row.owner), tostring(row.lifetime), tostring(row.schema), tostring(row.loadStatus or "unknown"),
                row.periodId and (" · Period " .. tostring(row.periodId)) or "",
                row.writeFenced and (" · 写保护 " .. tostring(row.writeFenceReason or "unknown")) or (row.dirty and " · Dirty" or ""))
        end
    end
    local ui = snap.ui
    if type(ui) == "table" then
        sections[#sections + 1] = string.format("UI Framework v%s：缓存Widget %d · Owner %d · Diff尝试 %d · 实际写 %d · 跳过 %d（%.1f%%）· Native调用 %d",
            tostring(ui.version or "?"), tonumber(ui.cachedWidgets) or 0, tonumber(ui.owners) or 0, tonumber(ui.attempts) or 0,
            tonumber(ui.writes) or 0, tonumber(ui.skips) or 0, (tonumber(ui.skipRatio) or 0) * 100, tonumber(ui.nativeCalls) or 0)
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
