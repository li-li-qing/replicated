ReplicatedSuiteModuleSandbox:Enter('plates', {'ReplicatedPlates'})
------------------------------------------------------------------------
-- Replicated Plates - Suite Workspace Presenter (M5 v5)
--
-- Authority / Proxy boundary:
--   * Storage stays the only persistent settings + tracking Authority.
--   * Manager stays the only discovery/capture/import-export Authority.
--   * Runtime stays the only live scan / combat rendering Authority.
--   * UI stays the only native Plates HUD layout/calibration Authority.
--   * This presenter exposes bounded snapshots and explicit user actions only.
--
-- Hot-path contract:
--   * no X2* call from periodic workspace refresh;
--   * tracked rows are rebuilt only when Storage.trackingRevision changes;
--   * capture/discovery rows are rebuilt only when their session serial changes;
--   * API metadata resolution is allowed only for an explicit "add by ID" click;
--   * diagnostics that probe native APIs are generated only on explicit request.
------------------------------------------------------------------------
if ReplicatedPlates == nil or ReplicatedPlates.BootError ~= nil
    or ReplicatedPlates.Storage == nil or ReplicatedPlates.Manager == nil then return end

local P = ReplicatedPlates
local S = P.Storage
local M = P.Manager
local R = P.Runtime
local U = P.UI
local A = P.Api

P.WorkspacePresenter = {}
local W = P.WorkspacePresenter
W.generation = P.Generation
W.trackedCache = {}
W.captureCache = {}
W.discoveryCache = {}

local function DeepCopy(value, seen)
    if type(value) ~= "table" then return value end
    seen = seen or {}
    if seen[value] ~= nil then return seen[value] end
    local copy = {}
    seen[value] = copy
    for key, child in pairs(value) do copy[DeepCopy(key, seen)] = DeepCopy(child, seen) end
    return copy
end

local function Restore(dst, src)
    if type(dst) ~= "table" or type(src) ~= "table" then return false end
    for key in pairs(dst) do dst[key] = nil end
    for key, value in pairs(src) do dst[key] = DeepCopy(value) end
    return true
end

local function Clamp(value, minimum, maximum, fallback)
    value = tonumber(value)
    if value == nil then value = tonumber(fallback) or 0 end
    if minimum ~= nil and value < minimum then value = minimum end
    if maximum ~= nil and value > maximum then value = maximum end
    return value
end

local function Scope(scope)
    return scope == "player" and "player" or "target"
end

local function Effect(effectType)
    if effectType == "debuff" or effectType == "hidden" then return effectType end
    return "buff"
end

local function LaneKey(scope, effectType)
    return Scope(scope) .. ":" .. Effect(effectType)
end

local function RefreshScope(scope)
    scope = Scope(scope)
    if U ~= nil and type(U.ApplyPlateLayout) == "function" then pcall(function() U:ApplyPlateLayout(scope) end) end
    local rt = R and R.scopes and R.scopes[scope] or nil
    local cfg = S:GetPlate(scope)
    if U ~= nil and type(U.MovePlate) == "function" and type(rt) == "table" and rt.positionValid == true and type(cfg) == "table" then
        pcall(function()
            U:MovePlate(scope, (tonumber(rt.lastScreenX) or 0) + (tonumber(cfg.offsetX) or 0),
                (tonumber(rt.lastScreenY) or 0) + (tonumber(cfg.offsetY) or 0))
        end)
    end
    local mock = U ~= nil and type(U.GetPreviewMode) == "function" and U:GetPreviewMode(scope) == "mock"
    if mock and type(U.RefreshMockPreview) == "function" then
        pcall(function() U:RefreshMockPreview(scope) end)
    elseif R ~= nil and type(R.ForceScope) == "function" then
        local suite = rawget(_G, "ReplicatedSuite")
        local enabled = suite == nil or suite.ModuleManager == nil or suite.ModuleManager:IsEnabled("plates") == true
        if enabled then pcall(function() R:ForceScope(scope) end) end
    end
end

local function RuntimeRefresh(methodName)
    if R ~= nil and type(R[methodName]) == "function" then pcall(function() R[methodName](R) end) end
end

local function SavePlate(scope, mutate, tracking)
    scope = Scope(scope)
    local cfg = S:GetPlate(scope)
    if type(cfg) ~= "table" then return false, "HUD 配置不可用" end
    local snapshot = DeepCopy(cfg)
    local dirty, trackingDirty, auraDirty = S.dirty, S.trackingDirty, S.auraDirty
    local rev, trackRev = S.revision, S.trackingRevision
    local ok, err = xpcall(function() mutate(cfg) end, P.SafeTraceback)
    if not ok then return false, tostring(err) end
    if tracking == true then S:MarkTrackingDirty() else S:MarkDirty() end
    local saved, saveErr = S:Save(true)
    if saved ~= true then
        Restore(cfg, snapshot)
        S.dirty, S.trackingDirty, S.auraDirty = dirty, trackingDirty, auraDirty
        S.revision, S.trackingRevision = rev, trackRev
        return false, tostring(saveErr or "保存失败")
    end
    RefreshScope(scope)
    return true
end

local function SaveTop(blockKey, mutate, runtimeMethod)
    local settings = S:Get()
    local cfg = settings and settings[blockKey] or nil
    if type(cfg) ~= "table" then return false, tostring(blockKey) .. " 配置不可用" end
    local snapshot = DeepCopy(cfg)
    local dirty, rev = S.dirty, S.revision
    local ok, err = xpcall(function() mutate(cfg) end, P.SafeTraceback)
    if not ok then return false, tostring(err) end
    S:MarkDirty()
    local saved, saveErr = S:Save(true)
    if saved ~= true then
        Restore(cfg, snapshot)
        S.dirty, S.revision = dirty, rev
        return false, tostring(saveErr or "保存失败")
    end
    if runtimeMethod ~= nil then RuntimeRefresh(runtimeMethod) end
    return true
end

local function SetPath(root, path, value)
    if type(root) ~= "table" or type(path) ~= "table" or #path == 0 then return false end
    local node = root
    for index = 1, #path - 1 do
        local key = path[index]
        if type(node[key]) ~= "table" then node[key] = {} end
        node = node[key]
    end
    node[path[#path]] = value
    return true
end

local function GetPath(root, path, fallback)
    local node = root
    for _, key in ipairs(type(path) == "table" and path or {}) do
        if type(node) ~= "table" then return fallback end
        node = node[key]
    end
    if node == nil then return fallback end
    return node
end

local function InvalidateTrackingProjection(self)
    self.trackedCache = {}
    self.captureCache = {}
    self.discoveryCache = {}
end

local function CopyEntry(id, entry)
    entry = type(entry) == "table" and entry or {}
    return {
        id = tostring(id or ""),
        name = tostring(entry.customName ~= nil and entry.customName ~= "" and entry.customName or entry.name or ""),
        baseName = tostring(entry.name or ""),
        customName = tostring(entry.customName or ""),
        iconPath = tostring(entry.iconPath or ""),
        category = tostring(entry.category or ""),
        enabled = entry.enabled ~= false,
        priority = math.floor(tonumber(entry.priority) or 0),
        showDuration = entry.showDuration,
        showStack = entry.showStack,
        showBorder = entry.showBorder,
        showTooltip = entry.showTooltip,
        iconSize = tonumber(entry.iconSize),
        expireEnabled = entry.expireEnabled,
        expireThreshold = tonumber(entry.expireThreshold),
        borderColor = type(entry.borderColor) == "table" and DeepCopy(entry.borderColor) or nil,
        expireColor = type(entry.expireColor) == "table" and DeepCopy(entry.expireColor) or nil,
    }
end

local function SortedTrackedRows(scope, effectType)
    local rows = {}
    for id, entry in pairs(S:GetTracked(scope, effectType)) do rows[#rows + 1] = CopyEntry(id, entry) end
    table.sort(rows, function(left, right)
        if left.priority ~= right.priority then return left.priority > right.priority end
        if left.enabled ~= right.enabled then return left.enabled end
        local ln, rn = tostring(left.name or ""), tostring(right.name or "")
        if ln ~= rn then return ln < rn end
        local li, ri = tonumber(left.id), tonumber(right.id)
        if li ~= nil and ri ~= nil and li ~= ri then return li < ri end
        return tostring(left.id) < tostring(right.id)
    end)
    return rows
end

function W:GetTrackingRevision()
    return tonumber(S.trackingRevision) or 0
end

function W:GetTrackedRows(scope, effectType)
    scope, effectType = Scope(scope), Effect(effectType)
    local key = LaneKey(scope, effectType)
    local revision = self:GetTrackingRevision()
    local cache = self.trackedCache[key]
    if cache ~= nil and cache.revision == revision then return cache.rows, revision end
    local rows = SortedTrackedRows(scope, effectType)
    self.trackedCache[key] = { revision = revision, rows = rows }
    return rows, revision
end

function W:GetCaptureRows(scope, effectType)
    scope, effectType = Scope(scope), Effect(effectType)
    local serial = tonumber(M.capture and M.capture.serial) or 0
    local key = LaneKey(scope, effectType)
    local cache = self.captureCache[key]
    if cache ~= nil and cache.serial == serial then return cache.rows, serial end
    local source = type(M.GetCaptureList) == "function" and M:GetCaptureList(scope, effectType) or {}
    local rows = {}
    for _, entry in ipairs(source or {}) do
        local row = CopyEntry(entry.id, entry)
        row.stack = tonumber(entry.stack) or 1
        row.timeLeftMs = tonumber(entry.timeLeftMs) or 0
        row.tracked = S:IsTracked(scope, effectType, row.id)
        rows[#rows + 1] = row
    end
    self.captureCache[key] = { serial = serial, rows = rows }
    return rows, serial
end

function W:GetDiscoveredRows(scope, effectType)
    scope, effectType = Scope(scope), Effect(effectType)
    local serial = tonumber(M.discoverySerial) or 0
    local key = LaneKey(scope, effectType)
    local cache = self.discoveryCache[key]
    if cache ~= nil and cache.serial == serial then return cache.rows, serial end
    local source = type(M.GetDiscoveryList) == "function" and M:GetDiscoveryList(scope, effectType) or {}
    local rows = {}
    for _, entry in ipairs(source or {}) do
        local row = CopyEntry(entry.id, entry)
        row.firstSeen = tonumber(entry.firstSeen) or 0
        row.tracked = S:IsTracked(scope, effectType, row.id)
        rows[#rows + 1] = row
    end
    self.discoveryCache[key] = { serial = serial, rows = rows }
    return rows, serial
end

function W:SearchKnown(query, effectType, limit)
    local rows = type(M.SearchKnown) == "function" and M:SearchKnown(tostring(query or ""), Effect(effectType), limit or 50) or {}
    for _, row in ipairs(rows or {}) do row.tracked = S:IsTracked("target", Effect(effectType), row.id) or S:IsTracked("player", Effect(effectType), row.id) end
    return rows or {}
end

function W:GetLaneRows()
    local rows = {}
    for _, scope in ipairs({ "target", "player" }) do
        local cfg = S:GetPlate(scope) or {}
        for _, effectType in ipairs({ "buff", "debuff", "hidden" }) do
            local enabled = effectType == "buff" and cfg.showBuffs ~= false
                or effectType == "debuff" and cfg.showDebuffs ~= false
                or effectType == "hidden" and cfg.showHidden == true
            local trackedOnly = effectType == "hidden" or cfg.trackedOnly == true
            rows[#rows + 1] = {
                key = LaneKey(scope, effectType), scope = scope, effectType = effectType,
                tracked = S:TrackedCount(scope, effectType), activeTracked = S:ActiveTrackedCount(scope, effectType),
                discovered = type(M.GetDiscoveredCount) == "function" and M:GetDiscoveredCount(scope, effectType) or 0,
                enabled = enabled, trackedOnly = trackedOnly,
            }
        end
    end
    return rows
end

function W:GetOverview()
    local settings = S:Get() or {}
    local runtime = R ~= nil and type(R.GetRuntimeDiagnostics) == "function" and R:GetRuntimeDiagnostics() or {}
    local function Plate(scope)
        local cfg = S:GetPlate(scope) or {}
        return {
            enabled = cfg.enabled ~= false,
            showBuffs = cfg.showBuffs ~= false, showDebuffs = cfg.showDebuffs ~= false, showHidden = cfg.showHidden == true,
            trackedOnly = cfg.trackedOnly == true, autoPvPRelevant = cfg.autoPvPRelevant == true,
            showCast = cfg.showCast == true, showDistance = cfg.showDistance == true,
            showClass = cfg.showClass == true, showGear = cfg.showGear == true, showLoadout = cfg.showLoadout == true,
            showEquipment = cfg.showEquipment == true, showImportantCooldowns = cfg.showImportantCooldowns == true,
            width = tonumber(cfg.width) or 286, offsetX = tonumber(cfg.offsetX) or 0, offsetY = tonumber(cfg.offsetY) or 0,
            anchorMode = tostring(cfg.anchorMode or "TOP"), sectionGap = tonumber(cfg.sectionGap) or 4,
        }
    end
    local suite = rawget(_G, "ReplicatedSuite")
    local function HudVisible(id, fallback)
        if suite ~= nil and suite.HudManager ~= nil and suite.HudManager:Get(id) ~= nil then return suite.HudManager:IsVisible(id) == true end
        return fallback == true
    end
    return {
        ready = P.BootError == nil and S ~= nil,
        generation = tonumber(P.Generation) or 0,
        runtime = runtime,
        target = Plate("target"), player = Plate("player"),
        targetHudVisible = HudVisible("plates_target", S:GetPlate("target") and S:GetPlate("target").enabled),
        playerHudVisible = HudVisible("plates_player", S:GetPlate("player") and S:GetPlate("player").enabled),
        capture = {
            enabled = type(M.IsCaptureEnabled) == "function" and M:IsCaptureEnabled() == true,
            sticky = type(M.IsCaptureSticky) ~= "function" or M:IsCaptureSticky() == true,
            serial = tonumber(M.capture and M.capture.serial) or 0,
        },
        watchtarget = DeepCopy(settings.watchtarget or {}),
        alerts = DeepCopy(settings.alerts or {}),
        buffcap = DeepCopy(settings.buffcap or {}),
        magiccircle = DeepCopy(settings.magiccircle or {}),
        lines = DeepCopy(settings.lines or {}),
        auraSync = DeepCopy(settings.auraSync or {}),
        auraCount = type(S.AuraCount) == "function" and S:AuraCount() or 0,
        trackingRevision = self:GetTrackingRevision(),
    }
end

function W:SetHudVisible(scope, visible)
    scope = Scope(scope)
    local suite = rawget(_G, "ReplicatedSuite")
    local id = scope == "target" and "plates_target" or "plates_player"
    if suite ~= nil and suite.HudManager ~= nil and suite.HudManager:Get(id) ~= nil then
        return suite.HudManager:SetVisible(id, visible == true)
    end
    return SavePlate(scope, function(cfg) cfg.enabled = visible == true end)
end

function W:TogglePlate(scope, key)
    scope = Scope(scope)
    return SavePlate(scope, function(cfg) cfg[key] = not (cfg[key] == true) end)
end

function W:SetPlateValue(scope, path, value)
    return SavePlate(scope, function(cfg) SetPath(cfg, path, value) end)
end

function W:GetPlateValue(scope, path, fallback)
    return GetPath(S:GetPlate(Scope(scope)), path, fallback)
end

function W:SetEffectValue(scope, effectType, key, value)
    scope, effectType = Scope(scope), Effect(effectType)
    return SavePlate(scope, function(cfg)
        cfg.effects = type(cfg.effects) == "table" and cfg.effects or {}
        cfg.effects[effectType] = type(cfg.effects[effectType]) == "table" and cfg.effects[effectType] or {}
        cfg.effects[effectType][key] = value
    end)
end

function W:CycleEffectDirection(scope, effectType)
    local order = { RIGHT = "DOWN", DOWN = "LEFT", LEFT = "UP", UP = "RIGHT" }
    local current = tostring(self:GetPlateValue(scope, { "effects", Effect(effectType), "direction" }, "RIGHT"))
    return self:SetEffectValue(scope, effectType, "direction", order[current] or "RIGHT")
end

function W:ResetEffectLayout(scope, effectType)
    scope, effectType = Scope(scope), Effect(effectType)
    local ok, err = S:ResetEffectLayout(scope, effectType)
    if ok == true then RefreshScope(scope) end
    return ok, err
end

function W:ResetHudOffset(scope)
    scope = Scope(scope)
    local ok, err = S:ResetPlateOffset(scope)
    if ok == true then RefreshScope(scope) end
    return ok, err
end

function W:SetPreviewMode(scope, mode)
    scope = Scope(scope)
    if U == nil or type(U.SetPreviewMode) ~= "function" then return false, "预览接口不可用" end
    local ok, err = pcall(function() U:SetPreviewMode(scope, mode == "mock" and "mock" or "real") end)
    return ok, err
end

function W:StartCalibration(scope, component)
    scope = Scope(scope)
    if U == nil then return false, "HUD UI 未初始化" end
    if component == nil or component == "overall" then
        if type(U.SetLayoutEdit) == "function" then U:SetLayoutEdit(nil, nil) end
        if type(U.SetCalibration) == "function" then U:SetCalibration(scope); return true end
    end
    if type(U.SetCalibration) == "function" then U:SetCalibration(nil) end
    if type(U.SetLayoutEdit) == "function" then U:SetLayoutEdit(scope, tostring(component)); return true end
    return false, "布局校准接口不可用"
end

function W:StopCalibration()
    if U == nil then return false end
    if type(U.SetCalibration) == "function" then U:SetCalibration(nil) end
    if type(U.SetLayoutEdit) == "function" then U:SetLayoutEdit(nil, nil) end
    return true
end

function W:AddTracked(scope, effectType, id, source)
    scope, effectType = Scope(scope), Effect(effectType)
    id = tostring(id or ""):gsub("%s+", "")
    if not id:match("^%d+$") then return false, "ID 必须是数字" end
    local entry = type(source) == "table" and {
        name = tostring(source.baseName or source.name or ""), iconPath = tostring(source.iconPath or ""),
        category = tostring(source.category or ""), enabled = true, priority = tonumber(source.priority) or 0,
    } or nil
    if entry == nil and A ~= nil and type(A.ResolveTrackedEntry) == "function" then
        local resolved, info = A:ResolveTrackedEntry(id, "ID " .. id, "")
        entry = resolved or { name = "ID " .. id, iconPath = "" }
        if type(info) == "table" and tostring(info.category or "") ~= "" then entry.category = tostring(info.category) end
    end
    entry = entry or { name = "ID " .. id, iconPath = "" }
    local ok, err = S:AddTracked(scope, effectType, id, entry)
    if ok == true then InvalidateTrackingProjection(self); RefreshScope(scope) end
    return ok, err
end

function W:UpdateTracked(scope, effectType, id, changes, clearFields)
    scope, effectType = Scope(scope), Effect(effectType)
    local ok, err = S:UpdateTracked(scope, effectType, tostring(id or ""), changes, clearFields)
    if ok == true then InvalidateTrackingProjection(self); RefreshScope(scope) end
    return ok, err
end

function W:RemoveTracked(scope, effectType, id)
    scope, effectType = Scope(scope), Effect(effectType)
    local ok, err = S:RemoveTracked(scope, effectType, tostring(id or ""))
    if ok == true then InvalidateTrackingProjection(self); RefreshScope(scope) end
    return ok, err
end

function W:ClearAllTracked()
    local count, err = S:ClearAllTracked()
    if count ~= nil then
        InvalidateTrackingProjection(self)
        RefreshScope("target"); RefreshScope("player")
        return true, count
    end
    return false, err
end

function W:SetCaptureEnabled(enabled, scope, effectType)
    if type(M.SetCaptureEnabled) ~= "function" then return false, "持续检测不可用" end
    local state = M:SetCaptureEnabled(enabled == true, Scope(scope), Effect(effectType))
    self.captureCache = {}
    return true, state
end

function W:SetCaptureSticky(enabled)
    if type(M.SetCaptureSticky) ~= "function" then return false, "捕获保持不可用" end
    local state = M:SetCaptureSticky(enabled == true)
    -- Sticky changes which aged rows are projected even when capture.serial did
    -- not advance, so invalidate the presentation cache explicitly.
    self.captureCache = {}
    return true, state
end

function W:ClearCapture(scope, effectType, all)
    if type(M.ClearCaptureQueue) ~= "function" then return false, "捕获队列不可用" end
    local ok = all == true and M:ClearCaptureQueue(nil, nil) or M:ClearCaptureQueue(Scope(scope), Effect(effectType))
    if ok == true then self.captureCache = {} end
    return ok == true
end

function W:ForgetDiscovered(scope, effectType, id)
    if type(M.ForgetDiscovered) ~= "function" then return false end
    M:ForgetDiscovered(Scope(scope), Effect(effectType), tostring(id or ""))
    self.discoveryCache = {}
    return true
end

function W:ClearDiscovered(scope, effectType)
    if type(M.ClearDiscovered) ~= "function" then return false end
    M:ClearDiscovered(Scope(scope), Effect(effectType))
    self.discoveryCache = {}
    return true
end

function W:SetTopValue(blockKey, path, value, runtimeMethod)
    return SaveTop(blockKey, function(cfg) SetPath(cfg, path, value) end, runtimeMethod)
end

function W:ToggleTop(blockKey, path, runtimeMethod)
    return SaveTop(blockKey, function(cfg)
        local current = GetPath(cfg, path, false)
        SetPath(cfg, path, not (current == true))
    end, runtimeMethod)
end

function W:CycleAlertScope()
    return SaveTop("alerts", function(cfg)
        cfg.scope = cfg.scope == "target" and "player" or cfg.scope == "player" and "target+player" or "target"
    end, "UpdateAlerts")
end

function W:CycleAlertStyle()
    return SaveTop("alerts", function(cfg) cfg.style = cfg.style == "countdown" and "bigtext" or "countdown" end, "UpdateAlerts")
end

function W:CycleAlertAnchor()
    return SaveTop("alerts", function(cfg) cfg.anchorMode = cfg.anchorMode == "center" and "top" or "center" end, "UpdateAlerts")
end

function W:SetAlertItem(key, enabled)
    return SaveTop("alerts", function(cfg)
        cfg.items = type(cfg.items) == "table" and cfg.items or {}
        cfg.items[tostring(key or "")] = enabled == true
    end, "UpdateAlerts")
end

function W:GetAlertRows()
    local cfg = S:Get().alerts or {}
    local rows = {}
    local data = rawget(_G, "ReplicatedSuite")
    data = data and data.Data and data.Data.BossAlerts or {}
    for _, entry in ipairs(type(data) == "table" and data or {}) do
        local key = tostring(entry.key or "")
        if key ~= "" then
            rows[#rows + 1] = {
                key = key, kind = tostring(entry.kind or ""), alert = tostring(entry.alert or key),
                detail = entry.kind == "debuff" and ("Debuff ID " .. tostring(entry.debuffId or "--"))
                    or table.concat(type(entry.names) == "table" and entry.names or {}, " / "),
                enabled = type(cfg.items) ~= "table" or cfg.items[key] ~= false,
                style = tostring(entry.style or "bigtext"),
            }
        end
    end
    return rows
end

function W:PreviewAlert()
    local suite = rawget(_G, "ReplicatedSuite")
    local alerts = suite and suite.Services and suite.Services.Alerts or nil
    if alerts == nil or type(alerts.Push) ~= "function" then return false, "警报通道尚未就绪" end
    alerts:Push({ text = "BUFF显示 · 警报预览", style = "countdown", durationMs = 2200, remainingMs = 2200 })
    return true
end

function W:SimulateAlert()
    if R == nil or type(R.SimulateAlert) ~= "function" then return false, "完整链路模拟不可用" end
    local ok, result = xpcall(function() return R:SimulateAlert(nil) end, P.SafeTraceback)
    return ok == true, ok and result or tostring(result)
end

function W:ImportCorePreset()
    if type(M.ImportCorePreset) ~= "function" then return false, "内置实战库不可用" end
    local ok, err = M:ImportCorePreset()
    if ok == true then InvalidateTrackingProjection(self); RefreshScope("target"); RefreshScope("player") end
    return ok, err
end

function W:Export(mode, scope, effectType, id)
    mode = tostring(mode or "all")
    if mode == "library" then
        if type(M.ExportAuraLibraryChunks) ~= "function" then return nil, "状态库分片导出不可用" end
        local chunks, err, info = M:ExportAuraLibraryChunks()
        return chunks, err, info
    elseif mode == "tracking" and type(M.ExportTracking) == "function" then
        return M:ExportTracking()
    elseif mode == "layout" and type(M.ExportLayout) == "function" then
        return M:ExportLayout()
    elseif mode == "rule" and type(M.ExportRule) == "function" then
        return M:ExportRule(Scope(scope), Effect(effectType), tostring(id or ""))
    elseif type(M.ExportConfig) == "function" then
        return M:ExportConfig()
    end
    return nil, "导出接口不可用"
end

function W:PreviewImport(text)
    text = tostring(text or "")
    if text:find("RPPLATESAURA3|", 1, true) then
        local stage, err
        if type(M.StageAuraImportText) == "function" then
            stage, err = M:StageAuraImportText(text)
        elseif type(M.StageAuraImportChunk) == "function" then
            stage, err = M:StageAuraImportChunk(text)
        else
            return false, "状态库分片导入不可用"
        end
        return stage ~= nil, err, stage
    end
    if type(M.PreviewImportPackage) ~= "function" then return false, "导入解析不可用" end
    local preview, err = M:PreviewImportPackage(text)
    return preview ~= nil, err, preview
end

function W:CommitImport(text)
    text = tostring(text or "")
    if text:find("RPPLATESAURA3|", 1, true) then return false, "状态库分片请先解析暂存，再点击提交状态库" end
    if type(M.ImportPackage) ~= "function" then return false, "配置导入不可用" end
    local ok, err, info = M:ImportPackage(text)
    if ok == true then InvalidateTrackingProjection(self); RefreshScope("target"); RefreshScope("player") end
    return ok, err, info
end

function W:GetAuraImportStageInfo()
    return type(M.GetAuraImportStageInfo) == "function" and M:GetAuraImportStageInfo() or nil
end

function W:CommitAuraImport(policy)
    if type(M.CommitAuraImport) ~= "function" then return false, "状态库提交不可用" end
    local ok, err, info = M:CommitAuraImport(policy == "replace" and "replace" or "merge")
    if ok == true then InvalidateTrackingProjection(self); RefreshScope("target"); RefreshScope("player") end
    return ok, err, info
end

function W:ResetAuraImportStage()
    if type(M.ResetAuraImportStage) == "function" then M:ResetAuraImportStage(); return true end
    return false
end

function W:BuildDiagnostics()
    if P.Diagnostics == nil or type(P.Diagnostics.BuildReport) ~= "function" then return nil, "诊断模块不可用" end
    local ok, result = xpcall(function() return P.Diagnostics:BuildReport() end, P.SafeTraceback)
    if not ok then return nil, tostring(result) end
    return tostring(result or "")
end

function W:GetDiagnosticsSnapshot()
    local runtime = R ~= nil and type(R.GetRuntimeDiagnostics) == "function" and R:GetRuntimeDiagnostics() or {}
    local budget = type(runtime.budget) == "table" and runtime.budget or {}
    local ui = type(runtime.ui) == "table" and runtime.ui or {}
    local effects = type(ui.effects) == "table" and ui.effects or {}
    return {
        running = runtime.running == true,
        heartbeat = tonumber(runtime.heartbeat) or 0,
        successfulUpdates = tonumber(runtime.successfulUpdates) or 0,
        budgetRequests = tonumber(budget.requests) or 0,
        budgetGranted = tonumber(budget.granted) or 0,
        budgetDeferred = tonumber(budget.deferred) or 0,
        budgetStarvation = tonumber(budget.starvation) or 0,
        effectUpdates = tonumber(effects.updates) or 0,
        effectVisible = tonumber(effects.visible) or 0,
        effectPeak = tonumber(effects.peakVisible) or 0,
        effectTextureChanges = tonumber(effects.textureChanges) or 0,
    }
end

function W:GetColorPresets()
    return type(S.GetColorPresets) == "function" and S:GetColorPresets() or {}
end

function W:SetEffectColor(scope, effectType, field, color)
    if field ~= "expireColor" then field = "borderColor" end
    return self:SetEffectValue(scope, effectType, field, DeepCopy(color))
end

function W:SetTrackedColor(scope, effectType, id, field, color)
    if field ~= "expireColor" then field = "borderColor" end
    return self:UpdateTracked(scope, effectType, id, { [field] = DeepCopy(color) })
end

function W:Describe()
    return {
        generation = tonumber(self.generation) or 0,
        revision = tonumber(S.revision) or 0,
        trackingRevision = tonumber(S.trackingRevision) or 0,
        captureSerial = tonumber(M.capture and M.capture.serial) or 0,
        discoverySerial = tonumber(M.discoverySerial) or 0,
    }
end
