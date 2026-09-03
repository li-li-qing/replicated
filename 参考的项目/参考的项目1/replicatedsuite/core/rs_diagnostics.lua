------------------------------------------------------------------------
-- Replicated Suite - Privacy-filtered Diagnostics Authority
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
S.DiagnosticsManager = { recent = {} }
local D = S.DiagnosticsManager

function D:Record(level, source, message)
    level = tostring(level or "error")
    source = tostring(source or "suite")
    message = tostring(message or "")
    self.recent[#self.recent + 1] = { level=level, source=source, message=message, at=S.NowMs and S.NowMs() or 0 }
    while #self.recent > 20 do table.remove(self.recent, 1) end
    -- Diagnostics that are not user-facing chat messages still belong in the
    -- same copyable log stream (module stack traces are the important case).
    if type(S.RecordLog) == "function" then S.RecordLog(level, source, message) end
end

local function CountTable(value)
    local count = 0
    if type(value) == "table" then for _ in pairs(value) do count = count + 1 end end
    return count
end

function D:Snapshot()
    local snap = {
        version = tostring(S.Version or ""),
        generation = tonumber(S.Generation) or 0,
        saveSchema = S.Constants and S.Constants.SaveSchemaVersion or nil,
        moduleStates = {}, hudStates = {}, api = { total=0, allowed=0, unavailable=0, retired=0, conflicts=0 },
        schedulerTasks = S.Scheduler and CountTable(S.Scheduler.tasks) or 0,
        backlog = S.Scheduler and type(S.Scheduler.DescribeBacklog)=="function" and S.Scheduler:DescribeBacklog() or {health="Unknown",pending=0},
        performance = S.PerformanceMonitor and type(S.PerformanceMonitor.Snapshot)=="function" and S.PerformanceMonitor:Snapshot() or nil,
        clientLanguage = "Unknown",
        moduleFaults = S.Diagnostics and CountTable(S.Diagnostics.moduleFaults) or 0,
        storageError = S.Storage and S.Storage.lastError or nil,
        storageScope = {
            characterResolved = S.Storage and S.Storage.characterKey ~= nil or false,
            characterDeferred = S.Storage and S.Storage.characterScopeDeferred == true or false,
            characterOverrides = S.Storage and CountTable(S.Storage.characterOverrides) or 0,
            writeFenced = S.Storage and (S.Storage.loadFailed == true or S.Storage.futureSchema == true) or false,
            writeFenceReason = S.Storage and S.Storage.writeFenceReason or nil,
            futureSchema = S.Storage and S.Storage.futureSchema == true or false,
        },
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
            if retired then
                -- Removed/officially-disabled entries are deliberate tombstones in
                -- the registry, not missing APIs. Reporting them as "unavailable"
                -- made a healthy client look broken in the one-click summary.
                snap.api.retired = snap.api.retired + 1
            elseif allowed then
                snap.api.allowed = snap.api.allowed + 1
            else
                snap.api.unavailable = snap.api.unavailable + 1
            end
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
    return table.concat({
        "Replicated Suite " .. snap.version .. " · Schema " .. tostring(snap.saveSchema or "?") .. " · 语言 " .. tostring(snap.clientLanguage or "Unknown"),
        "模块：启用 " .. tostring(enabled) .. " / 故障 " .. tostring(faulted) .. " / 总计 " .. tostring(#snap.moduleStates),
        "HUD：有效显示 " .. tostring(visible) .. " / 已注册 " .. tostring(#snap.hudStates),
        "API：可用 " .. tostring(snap.api.allowed) .. " / 缺失 " .. tostring(snap.api.unavailable) .. " / 已移除 " .. tostring(snap.api.retired or 0) .. " / 冲突 " .. tostring(snap.api.conflicts),
        "Scheduler任务：" .. tostring(snap.schedulerTasks) .. " · Backlog：" .. tostring(snap.backlog and snap.backlog.health or "Unknown") .. "(" .. tostring(snap.backlog and snap.backlog.pending or 0) .. ") · Storage：" .. (snap.storageScope and snap.storageScope.writeFenced and "写保护" or (snap.storageError and "异常" or "正常")),
        snap.performance and ("性能：最近帧 " .. string.format("%.1f", tonumber(snap.performance.lastFrameMs) or 0) .. "ms · 最大 " .. string.format("%.1f", tonumber(snap.performance.maxFrameMs) or 0) .. "ms · 卡顿 " .. tostring(snap.performance.jankCount or 0) .. " · 未归因 " .. tostring(snap.performance.unattributedStalls or 0) .. " · 详细计时 " .. (snap.performance.timerAvailable and "可用" or "不可用")) or "性能：监控尚未加载",
        "Scope：Character " .. (snap.storageScope and snap.storageScope.characterResolved and "已识别" or "未识别")
            .. (snap.storageScope and snap.storageScope.characterDeferred and "（待正规化）" or "")
            .. " · 角色覆盖 " .. tostring(snap.storageScope and snap.storageScope.characterOverrides or 0),
        "迁移：" .. tostring(snap.migration and snap.migration.suiteStatus or "unknown") .. " · 旧运行时：不启用",
    }, "\n")
end
local function CompactLogText(value)
    local text = tostring(value or "")
    text = text:gsub("\r\n", "\n"):gsub("\r", "\n")
    text = text:gsub("[\n]+", " ↳ ")
    text = text:gsub("^%s+", ""):gsub("%s+$", "")
    return text
end

function D:BuildAllLogs()
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
    -- ArcheRage flattens embedded newlines. Use a visible delimiter so the whole
    -- result remains one system-chat message and can be copied in one selection.
    return table.concat(sections, "  ║  ")
end

function D:PrintAllLogs()
    local payload = "[Replicated Suite 全部日志] " .. self:BuildAllLogs()
    -- Do not call S.SafeChat here: that would append the dump itself back into
    -- the log buffer and make every subsequent print recursively larger.
    if type(S.DispatchSystemChat) == "function" then
        return S.DispatchSystemChat(payload)
    end
    return false
end

-- Compatibility entry used by older buttons/search actions. It now prints the
-- complete buffered log instead of scattering one summary row per chat line.
function D:PrintSummary()
    return self:PrintAllLogs()
end
