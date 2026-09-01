------------------------------------------------------------------------
-- Replicated Suite V3 - Task Tracker Feature
--
-- Independent lifecycle. The feature never reads X2Quest itself; it acquires
-- QuestProgressService V3 only while the page or floating tracker is visible.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local Runtime = S.FeatureRuntime
if type(Runtime) ~= "table" then return end

S.Features = S.Features or {}
S.Features.Tasks = S.Features.Tasks or {}
local F = S.Features.Tasks
F.Id = "life_tasks"
F.ApiDependencies = { "QUEST" }
F.enabled = F.enabled == true
F.consumers = {}
F.consumerCount = 0
F.progressConsumerToken = "feature:life_tasks"
F.progressConsumerHeld = false
F.progressSubscribed = false
F.PersistenceMutationContractVersion = 2

local VALID_SCOPE = { daily = true, weekly = true }

function F:Initialize()
    local ok, err = self:EnsureStoreLoaded()
    if ok ~= true then return false, err end
    if type(self.Authority) ~= "table" then return false, "task authority unavailable" end
    return true
end

function F:GetTracking(scope)
    scope = VALID_SCOPE[tostring(scope or "")] and tostring(scope) or "daily"
    self.State.tracking = type(self.State.tracking) == "table" and self.State.tracking or {}
    local bucket = self.State.tracking[scope]
    if type(bucket) ~= "table" then bucket = { configured = false, keys = {} }; self.State.tracking[scope] = bucket end
    if type(bucket.keys) ~= "table" then bucket.keys = {} end
    return bucket
end

function F:IsTracked(scope, key)
    key = tostring(key or "")
    if key == "" then return false end
    local bucket = self:GetTracking(scope)
    if bucket.configured ~= true then return true end
    return bucket.keys[key] == true
end

function F:EnsureTrackingConfigured(scope)
    scope = VALID_SCOPE[tostring(scope or "")] and tostring(scope) or "daily"
    local bucket = self:GetTracking(scope)
    if bucket.configured == true then return bucket end
    bucket.configured, bucket.keys = true, {}
    for _, key in ipairs(self.Authority:GetGroupKeys(scope)) do bucket.keys[key] = true end
    return bucket
end

function F:SetTracked(scope, key, enabled, source)
    scope, key = tostring(scope or ""), tostring(key or "")
    if VALID_SCOPE[scope] ~= true or key == "" then return false end
    local known = false
    for _, candidate in ipairs(self.Authority:GetGroupKeys(scope)) do if candidate == key then known = true break end end
    if known ~= true then return false end
    local before = S.Utils.DeepCopy(self:GetTracking(scope))
    local bucket = self:EnsureTrackingConfigured(scope)
    if enabled == true then bucket.keys[key] = true else bucket.keys[key] = nil end
    local marked, markErr = self:MarkStoreDirty(300, source or "task_tracking")
    if marked ~= true then self.State.tracking[scope] = before; return false, markErr or "任务追踪设置未保存，已回滚" end
    local refreshed, refreshErr = self.Authority:Refresh("tracking_changed")
    if refreshed == false then return false, "任务追踪已保存，但投影刷新失败：" .. tostring(refreshErr or "unknown") end
    return true
end

function F:ToggleTracked(scope, key, source)
    return self:SetTracked(scope, key, not self:IsTracked(scope, key), source or "task_tracking_toggle")
end

function F:SetAllTracked(scope, enabled, source)
    scope = tostring(scope or "")
    if VALID_SCOPE[scope] ~= true then return false end
    local before = S.Utils.DeepCopy(self:GetTracking(scope))
    local bucket = self:GetTracking(scope)
    bucket.configured, bucket.keys = true, {}
    if enabled == true then
        for _, key in ipairs(self.Authority:GetGroupKeys(scope)) do bucket.keys[key] = true end
    end
    local marked, markErr = self:MarkStoreDirty(300, source or "task_tracking_all")
    if marked ~= true then self.State.tracking[scope] = before; return false, markErr or "任务批量追踪设置未保存，已回滚" end
    local refreshed, refreshErr = self.Authority:Refresh("tracking_all_changed")
    if refreshed == false then return false, "任务追踪已保存，但投影刷新失败：" .. tostring(refreshErr or "unknown") end
    return true
end

function F:SetLastScope(scope)
    scope = tostring(scope or "")
    if VALID_SCOPE[scope] ~= true or self.State.lastScope == scope then return false end
    local previous = self.State.lastScope
    self.State.lastScope = scope
    local marked, markErr = self:MarkStoreDirty(400, "task_scope")
    if marked ~= true then self.State.lastScope = previous; return false, markErr or "任务页签设置未保存，已回滚" end
    return true
end

-- Narrow Presentation read model. Pages and Widgets must not reach into the
-- persisted State table directly.
function F:GetLastScope()
    return VALID_SCOPE[self.State and tostring(self.State.lastScope or "")] and tostring(self.State.lastScope) or "daily"
end

function F:GetWidgetWindowState()
    local value = self.State and self.State.widgetWindow or nil
    local floating = S.RSUI and S.RSUI.FloatingSurface or nil
    if type(floating) == "table" and type(floating.NormalizeState) == "function" then
        return S.Utils.DeepCopy(floating:NormalizeState(value, self:GetWidgetWindowPolicy()))
    end
    return S.Utils.DeepCopy(value)
end

function F:SetWidgetWindowState(value, reason)
    if type(value) ~= "table" or type(self.State) ~= "table" then return false, "task widget window state unavailable" end
    local floating = S.RSUI and S.RSUI.FloatingSurface or nil
    local normalized = type(floating) == "table" and type(floating.NormalizeState) == "function"
        and floating:NormalizeState(value, self:GetWidgetWindowPolicy()) or S.Utils.DeepCopy(value)
    self.State.widgetWindow = normalized
    return true
end

function F:GetWidgetWindowPolicy()
    return S.Utils.DeepCopy(self.WidgetWindowSizePolicy or { defaultWidth = 420, defaultHeight = 286, minWidth = 1, minHeight = 1 })
end

function F:GetWidgetRowCount()
    return tonumber(self.State and self.State.widgetRows) or 9
end

function F:GetWidgetVisiblePreference()
    return self.State and self.State.widgetVisible == true or false
end

-- Public Projection/Commands boundary for Active V3. Presentation does not
-- retain or call the Task Authority object directly.
function F:GetRows(scope)
    return self.Authority:GetRows(scope)
end

function F:GetRow(id)
    return self.Authority:GetRow(id)
end

function F:GetSummary(scope)
    return self.Authority:GetSummary(scope)
end

function F:GetWidgetProjection()
    return self.Authority:GetWidgetRows()
end

function F:RefreshProjection(reason)
    if self.enabled ~= true then return false, "task feature disabled" end
    return self.Authority:Refresh(reason or "presentation_refresh")
end

function F:ToggleExpanded(scope, key)
    return self.Authority:ToggleExpanded(scope, key)
end

function F:SubscribeProgress()
    if self.progressSubscribed == true then return true end
    if S.Events == nil or type(S.Events.SubscribeInternal) ~= "function" then return false, "internal event bus unavailable" end
    local subscribed = S.Events:SubscribeInternal("v3.quest_progress.updated", self, function()
        if F.enabled == true and F.consumerCount > 0 then F.Authority:Refresh("quest_progress") end
    end)
    if subscribed ~= true then return false, "quest progress internal subscribe failed" end
    self.progressSubscribed = true
    return true
end

function F:UnsubscribeProgress()
    if self.progressSubscribed ~= true then return true end
    if S.Events ~= nil and type(S.Events.UnsubscribeInternalOwner) == "function" then S.Events:UnsubscribeInternalOwner(self) end
    self.progressSubscribed = false
    return true
end

function F:ReconcileDemand(before, after)
    local beforeCount = tonumber(before and before.count) or 0
    local afterCount = tonumber(after and after.count) or 0
    if beforeCount == 0 and afterCount > 0 then
        local progress = S.Services and S.Services.QuestProgressV3 or nil
        if type(progress) ~= "table" or type(progress.AcquireConsumer) ~= "function" then
            return false, "quest progress service unavailable"
        end
        local ok, err = progress:AcquireConsumer(self.progressConsumerToken)
        if ok ~= true then return false, err end
        self.progressConsumerHeld = true
        local subscribed, subErr = self:SubscribeProgress()
        if subscribed ~= true then return false, subErr end
        local refreshed, refreshErr = self.Authority:Refresh("consumer_acquired")
        if refreshed == false then return false, refreshErr or "task refresh failed" end
    elseif beforeCount > 0 and afterCount == 0 then
        self:UnsubscribeProgress()
        if self.progressConsumerHeld == true then
            local progress = S.Services and S.Services.QuestProgressV3 or nil
            if type(progress) ~= "table" or type(progress.ReleaseConsumer) ~= "function" then
                return false, "quest progress release unavailable"
            end
            local released, releaseErr = progress:ReleaseConsumer(self.progressConsumerToken)
            if released ~= true then return false, releaseErr or "quest progress release failed" end
            self.progressConsumerHeld = false
        end
        self.Authority:ResetTransient()
    end
    return true
end

if S.Demand == nil or type(S.Demand.Create) ~= "function" then error("Demand unavailable for Tasks") end
local taskDemand, taskDemandErr = S.Demand:Create({
    id = "feature:" .. F.Id,
    owner = F,
    projectionOwner = F,
    projectionConsumersField = "consumers",
    projectionCountField = "consumerCount",
    reconcile = function(_, before, after) return F:ReconcileDemand(before, after) end,
    quiesce = function(_, reason, cause) return F:QuiesceDemand(reason, cause) end,
})
if taskDemand == nil then error(taskDemandErr) end
F.Demand = taskDemand

function F:AcquireConsumer(token)
    if self.enabled ~= true then return false, "task feature disabled" end
    return self.Demand:Acquire(token, {}, "task_consumer")
end

function F:ReleaseConsumer(token)
    return self.Demand:Release(token, "task_consumer")
end

function F:QuiesceDemand(reason, cause)
    local ok = self:UnsubscribeProgress() == true
    if self.progressConsumerHeld == true then
        local progress = S.Services and S.Services.QuestProgressV3 or nil
        if type(progress) ~= "table" or type(progress.ReleaseConsumer) ~= "function" then
            ok = false
        else
            local released = progress:ReleaseConsumer(self.progressConsumerToken)
            if released ~= true then ok = false else self.progressConsumerHeld = false end
        end
    end
    self.Authority:ResetTransient()
    return ok
end

function F:Enable(reason)
    if self.enabled == true then return true end
    self.enabled = true
    -- Floating widget restore is a Presentation reaction bound to
    -- `v3.feature.lifecycle`; Domain only owns the persisted preference.
    return true
end

function F:Disable(reason)
    if self.enabled ~= true then return true end
    local cleared, clearErr = self.Demand:Clear(reason or "feature_disable")
    if cleared ~= true then return false, clearErr end
    self.enabled = false
    return true
end

function F:Refresh(reason)
    if self.enabled == true and self.consumerCount > 0 then return self.Authority:Refresh(reason or "feature_refresh") end
    return true
end

function F:SetWidgetVisible(visible, source)
    if self.enabled ~= true then return false, "task feature disabled" end
    -- Persist the Domain preference before publishing the Presentation fact so
    -- a rejected store write can never leave the window and saved state split.
    local nextValue = visible == true
    local previous = self.State.widgetVisible == true
    if previous ~= nextValue then
        self.State.widgetVisible = nextValue
        local marked, markErr = self:MarkStoreDirty(250, "task_widget_visibility")
        if marked ~= true then self.State.widgetVisible = previous; return false, markErr or "任务悬浮窗可见性未保存，已回滚" end
    end
    if S.Events ~= nil and type(S.Events.Publish) == "function" then
        S.Events:Publish("v3.tasks.widget_visibility", nextValue, tostring(source or "task_page"))
    end
    return true
end

function F:GetHealth()
    local summary = self.Authority:GetSummary()
    local progress = S.Services and S.Services.QuestProgressV3 or nil
    local progressHealth = type(progress) == "table" and type(progress.GetHealth) == "function" and progress:GetHealth("all") or nil
    return {
        ok = self.enabled == true,
        consumers = self.consumerCount,
        tracked = summary.tracked,
        unfinished = summary.unfinished,
        ready = summary.ready,
        progressRunning = type(progressHealth) == "table" and progressHealth.running == true or false,
        progressRevision = type(progressHealth) == "table" and progressHealth.revision or 0,
    }
end

F.Commands = F.Commands or {}
function F.Commands:MarkStoreDirty(delayMs, reason) return F:MarkStoreDirty(delayMs, reason) end
function F.Commands:SetWidgetVisible(visible, source) return F:SetWidgetVisible(visible == true, source or "task_command") end
function F.Commands:SetLastScope(scope) return F:SetLastScope(scope) end
function F.Commands:ToggleTracked(scope, key, source) return F:ToggleTracked(scope, key, source or "task_command") end
function F.Commands:SetAllTracked(scope, enabled, source) return F:SetAllTracked(scope, enabled == true, source or "task_command") end
function F.Commands:RefreshProjection(reason) return F:RefreshProjection(reason or "task_command") end
function F.Commands:ToggleExpanded(scope, key) return F:ToggleExpanded(scope, key) end
function F.Commands:ResetWidgetVisibility(source)
    if F.State.widgetVisible ~= false then
        local previous = F.State.widgetVisible
        F.State.widgetVisible = false
        local marked, markErr = F:MarkStoreDirty(250, tostring(source or "widget_visibility_reset"))
        if marked ~= true then F.State.widgetVisible = previous; return false, markErr or "任务悬浮窗复位未保存，已回滚" end
    end
    return true
end

local ok, err = Runtime:RegisterImplementation(F.Id, F)
if ok ~= true then error(err) end
