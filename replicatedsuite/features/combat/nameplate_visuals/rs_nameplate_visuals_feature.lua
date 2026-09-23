------------------------------------------------------------------------
-- Replicated Suite V3 - Native nameplate / HP bar visual feature
--
-- 维护（2026-09-20，nameplate-mark-ratio-3）：
-- Feature 只拥有生命周期、设置事务与 ENTERED_WORLD 重新应用；Native 读写属于 Authority，
-- 持久化属于 Store，Presentation 只能走 Commands。该功能没有 Scheduler/Tick，关闭后仅保留
-- Durable 设置，不保留事件监听、Native baseline 或其它运行时资源。
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local Runtime, P = S.FeatureRuntime, S.Persistence
S.Features = S.Features or {}
S.Features.NameplateVisuals = S.Features.NameplateVisuals or {}
local F = S.Features.NameplateVisuals
if type(Runtime) ~= "table" or type(P) ~= "table" or type(F.Authority) ~= "table" then return end

F.Id = "combat_nameplate_visuals"
F.ApiDependencies = { "X2Option:GetConsoleVariable", "X2Option:SetConsoleVariable" }
F.UpdateTopic = "v3.nameplate_visuals.updated"
F.Patch = "nameplate-mark-ratio-3"
F.enabled = false
F.lastLifecycleError = nil
F.lastLifecycleStage = "loaded_disabled"
F.reapplyCount = 0
F.lifecycleMetrics = F.lifecycleMetrics or { enableAttempts = 0, enableSuccess = 0, disableAttempts = 0, disableSuccess = 0 }

local function FailLifecycle(stage, err)
    F.lastLifecycleStage = tostring(stage or "unknown")
    F.lastLifecycleError = tostring(err or "unknown")
    return false, F.lastLifecycleError
end

local function Publish(reason)
    if S.Events and type(S.Events.Publish) == "function" then
        S.Events:Publish(F.UpdateTopic, F.Id, tostring(reason or "updated"))
    end
end

local function Copy(value)
    local out = {}
    for key, item in pairs(type(value) == "table" and value or {}) do out[key] = item end
    return out
end

function F:Initialize()
    return self:EnsureStoreLoaded()
end

function F:Enable(reason)
    if self.enabled == true then return true end
    self.lifecycleMetrics.enableAttempts = (tonumber(self.lifecycleMetrics.enableAttempts) or 0) + 1
    self.lastLifecycleStage = "enable_store"
    local loaded, loadErr = self:EnsureStoreLoaded()
    if loaded ~= true then return FailLifecycle("enable_store_failed", loadErr) end
    self.lastLifecycleStage = "enable_events"
    if S.Events == nil or type(S.Events.Subscribe) ~= "function" then return FailLifecycle("enable_events_unavailable", "事件总线不可用") end

    self.lastLifecycleStage = "enable_capture_baseline"
    local captured, captureErr = self.Authority:CaptureBaseline()
    if captured ~= true then return FailLifecycle("enable_capture_failed", captureErr) end
    self.lastLifecycleStage = "enable_apply_native"
    local applied, applyErr = self.Authority:ApplySettings(self:GetSettings(), reason or "feature_enable")
    if applied ~= true then
        self.Authority:ReleaseBaseline()
        return FailLifecycle("enable_apply_failed", applyErr)
    end

    -- 维护：GitHub 上 RU 社区 reloadcfg 明确选择 ENTERED_WORLD 重读 system.cfg；本功能按同一
    -- 生命周期边沿重新声明自己的 CVar，而不是用轮询对抗其它设置。事件订阅失败时先恢复启用前值
    -- 再拒绝 Enable，保持事务性；是否在所有 RU 场景都需要重写仍留给实机验收。
    S.Events:BindOwner(self, self.Id)
    local subscribed = S.Events:Subscribe("ENTERED_WORLD", self, function()
        if F.enabled ~= true then return end
        local ok, err = F.Authority:ApplySettings(F:GetSettings(), "entered_world")
        F.reapplyCount = (tonumber(F.reapplyCount) or 0) + 1
        F.lastLifecycleError = ok == true and nil or tostring(err)
        Publish(ok == true and "entered_world_reapplied" or "entered_world_reapply_failed")
    end)
    if subscribed ~= true then
        local restored, restoreErr = self.Authority:RestoreBaseline("enable_subscribe_rollback")
        self.Authority:ReleaseBaseline()
        if restored ~= true then return FailLifecycle("enable_subscribe_rollback_failed", "ENTERED_WORLD 订阅失败；Native 回滚同时失败：" .. tostring(restoreErr)) end
        return FailLifecycle("enable_subscribe_failed", "ENTERED_WORLD 订阅失败")
    end

    self.enabled, self.lastLifecycleError, self.lastLifecycleStage = true, nil, "enabled"
    self.lifecycleMetrics.enableSuccess = (tonumber(self.lifecycleMetrics.enableSuccess) or 0) + 1
    Publish("enabled")
    return true
end

function F:Disable(reason)
    self.lifecycleMetrics.disableAttempts = (tonumber(self.lifecycleMetrics.disableAttempts) or 0) + 1
    if self.enabled ~= true then
        if self.Authority.baseline ~= nil then self.Authority:ReleaseBaseline() end
        self.lastLifecycleStage = "disabled"
        return true
    end
    self.lastLifecycleStage = "disable_restore_baseline"
    -- 维护：先恢复再撤事件。若恢复失败，FeatureRuntime 必须看到 Disable=false 并保持 enabled，
    -- ENTERED_WORLD listener 也继续存在；不能出现“Native 仍是插件值但 Runtime 声称已关闭”。
    local restored, restoreErr = self.Authority:RestoreBaseline(reason or "feature_disable")
    if restored ~= true then
        self.lastLifecycleError = tostring(restoreErr)
        self.lastLifecycleStage = "disable_restore_failed"
        Publish("disable_restore_failed")
        return false, restoreErr
    end
    if S.Events and type(S.Events.UnsubscribeOwner) == "function" then S.Events:UnsubscribeOwner(self) end
    self.Authority:ReleaseBaseline()
    self.enabled, self.lastLifecycleError, self.lastLifecycleStage = false, nil, "disabled"
    self.lifecycleMetrics.disableSuccess = (tonumber(self.lifecycleMetrics.disableSuccess) or 0) + 1
    Publish("disabled")
    return true
end

function F:GetProjection()
    local settings = self:GetSettings()
    local native = self.Authority:GetProjection()
    return {
        enabled = self.enabled == true,
        settings = settings,
        baseline = native.baseline,
        baselineSources = native.baselineSources,
        baselineSourceSummary = native.baselineSourceSummary,
        observed = native.observed,
        effective = native.effective,
        readbackMode = native.readbackMode,
        unreadableCvars = native.unreadableCvars,
        systemCfgPath = native.systemCfgPath,
        revision = native.revision,
        lastApplyReason = native.lastApplyReason,
        lastError = native.lastError or self.lastLifecycleError,
        metrics = native.metrics,
        reapplyCount = tonumber(self.reapplyCount) or 0,
        settingsError = self.settingsError,
        lifecycleStage = self.lastLifecycleStage,
        lifecycleMetrics = Copy(self.lifecycleMetrics),
        patch = self.Patch,
    }
end

-- 中文维护注释（nameplate-mark-ratio-3）：Store schema1 不新增 markerScale 字段；页面与诊断
-- 统一从历史 markerWidth 推导百分比，避免 schema/canonical 变化。46 是 console_vars dump 中旧基准宽度，
-- 只作为持久兼容编码，不再写 over_head_marker_width。
function F:GetMarkerPercent()
    local settings = self:GetSettings()
    local width = tonumber(settings and settings.markerWidth) or tonumber(self.Defaults and self.Defaults.markerWidth) or 46
    local base = tonumber(self.Defaults and self.Defaults.markerWidth) or 46
    if base <= 0 then base = 46 end
    return math.floor((width * 100 / base) + 0.5)
end

function F:GetHealth()
    local p = self:GetProjection()
    return {
        enabled = p.enabled,
        revision = p.revision,
        reapplyCount = p.reapplyCount,
        reads = tonumber(p.metrics and p.metrics.reads) or 0,
        writes = tonumber(p.metrics and p.metrics.writes) or 0,
        failures = tonumber(p.metrics and p.metrics.failures) or 0,
        enableAttempts = tonumber(p.lifecycleMetrics and p.lifecycleMetrics.enableAttempts) or 0,
        enableSuccess = tonumber(p.lifecycleMetrics and p.lifecycleMetrics.enableSuccess) or 0,
        lifecycleStage = p.lifecycleStage,
        readbackMode = p.readbackMode,
        unreadableCount = type(p.unreadableCvars) == "table" and #p.unreadableCvars or 0,
        baselineSources = p.baselineSourceSummary,
        lastError = p.lastError,
        patch = p.patch,
    }
end

-- Durable 设置 + Native 应用的跨边界补偿事务：先保存候选，再写客户端；如果客户端拒绝，
-- 立即把 Store 恢复到旧设置。这样 UI 不会留下“下次重载又突然应用一个本次失败值”的隐患。
function F:CommitAndApply(mutator, reason)
    local before = self:GetSettings()
    local saved, saveErr = self:CommitSettings(mutator, reason)
    if saved ~= true then return false, saveErr end
    if self.enabled ~= true then
        Publish("settings_saved_disabled")
        return true
    end

    local applied, applyErr = self.Authority:ApplySettings(self:GetSettings(), reason or "settings_apply")
    if applied == true then Publish("settings_applied"); return true end

    local rollbackSaved, rollbackErr = self:CommitSettings(function(working)
        for key in pairs(working) do working[key] = nil end
        for key, value in pairs(before) do working[key] = value end
        return true
    end, tostring(reason or "settings") .. "_native_rollback")
    Publish("settings_native_failed")
    if rollbackSaved ~= true then
        return false, tostring(applyErr) .. "；设置回滚保存失败：" .. tostring(rollbackErr)
    end
    return false, tostring(applyErr)
end

F.Commands = F.Commands or {}
function F.Commands:SetValue(key, value)
    local ranges = F.Limits or {}
    if ranges[key] == nil then return false, "未知数值设置：" .. tostring(key) end
    local n = tonumber(value)
    if n == nil or n ~= n then return false, "请输入有效数值" end
    local min, max = ranges[key][1], ranges[key][2]
    if n < min or n > max then return false, tostring(key) .. " 允许范围 " .. tostring(min) .. "-" .. tostring(max) end
    n = n >= 0 and math.floor(n + 0.5) or math.ceil(n - 0.5)
    return F:CommitAndApply(function(working) working[key] = n; return true end, "nameplate_value:" .. key)
end

function F.Commands:SetFixedSize(value)
    if type(value) ~= "boolean" then return false, "固定尺寸开关必须是布尔值" end
    return F:CommitAndApply(function(working) working.markerFixedSize = value; return true end, "nameplate_fixed_size")
end

function F.Commands:SetMarkerPreset(percent)
    percent = tonumber(percent)
    if percent == nil or percent < 50 or percent > 300 then return false, "标记比例需为50%-300%" end
    -- 维护：继续写 schema1 的 width/height 作为百分比编码，Authority 只消费 width/46 -> ratio。
    -- height 同步保留是为了让 18.270-18.272 旧 UI/存档仍保持一致，offset 不再参与 Native。
    local width = math.floor((F.Defaults.markerWidth * percent / 100) + 0.5)
    local height = math.floor((F.Defaults.markerHeight * percent / 100) + 0.5)
    return F:CommitAndApply(function(working)
        working.markerWidth, working.markerHeight = width, height
        return true
    end, "nameplate_marker_ratio:" .. tostring(percent))
end

function F.Commands:SetMarkerScalePercent(percent)
    return self:SetMarkerPreset(percent)
end

function F.Commands:ResetDefaults()
    local defaults = Copy(F.Defaults)
    return F:CommitAndApply(function(working)
        for key in pairs(working) do working[key] = nil end
        for key, value in pairs(defaults) do working[key] = value end
        return true
    end, "nameplate_reset_defaults")
end

function F.Commands:Reapply()
    if F.enabled ~= true then return false, "请先启用头顶显示增强" end
    local ok, err = F.Authority:ApplySettings(F:GetSettings(), "manual_reapply")
    if ok == true then Publish("manual_reapply") end
    return ok, err
end

-- 中文维护注释（2026-09-20，nameplate-startup-evidence-1）：Provider 只读取现有 Lua/Store/API
-- 对象状态，不触发 Initialize、LoadStore 或 Native CVar。即使启动按钮在 FeatureRuntime 前置检查阶段
-- 被拒绝，模块诊断也能区分“按钮没进 Feature”与“Feature 已开始但 Native 阶段失败”。
if type(S.ModuleDiagnosticsHub) == "table" and type(S.ModuleDiagnosticsHub.RegisterProvider) == "function" then
    S.ModuleDiagnosticsHub:RegisterProvider(F.Id, "nameplate_startup", function()
        local preferenceStore = type(P.GetStore) == "function" and P:GetStore(Runtime.preferenceStoreId) or nil
        local option = rawget(_G, "X2Option")
        return {
            lifecycleStage = F.lastLifecycleStage,
            enableAttempts = tonumber(F.lifecycleMetrics.enableAttempts) or 0,
            enableSuccess = tonumber(F.lifecycleMetrics.enableSuccess) or 0,
            disableAttempts = tonumber(F.lifecycleMetrics.disableAttempts) or 0,
            disabled = F.enabled ~= true,
            optionHost = type(option) == "table",
            optionGet = type(option) == "table" and type(option.GetConsoleVariable) == "function" or false,
            optionSet = type(option) == "table" and type(option.SetConsoleVariable) == "function" or false,
            preferenceLoaded = type(preferenceStore) == "table" and preferenceStore.loaded == true or false,
            preferenceStatus = type(preferenceStore) == "table" and tostring(preferenceStore.loadStatus or "not_loaded") or "unavailable",
            preferenceFenced = type(preferenceStore) == "table" and preferenceStore.writeFenced == true or false,
            readbackMode = type(F.Authority) == "table" and tostring(F.Authority.readbackMode or "unknown") or "unavailable",
            unreadableCvars = type(F.Authority) == "table" and table.concat(F.Authority.unreadableCvars or {}, ",") or "",
            baselineSources = type(F.Authority) == "table" and F.Authority:GetBaselineSourceSummary() or "unavailable",
            systemCfgPath = type(F.Authority) == "table" and tostring(F.Authority.systemCfgPath or "not_found") or "unavailable",
            markerCvar = "name_tag_mark_size_ratio",
            legacyMarkerCvarsIgnored = true,
            markerPercent = type(F.GetMarkerPercent) == "function" and F:GetMarkerPercent() or nil,
            lastError = F.lastLifecycleError,
        }
    end, 35)
end

local ok, err = Runtime:RegisterImplementation(F.Id, F)
if ok ~= true then error(err) end
