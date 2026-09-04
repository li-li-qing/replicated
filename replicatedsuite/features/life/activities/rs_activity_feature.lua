------------------------------------------------------------------------
-- Replicated Suite V3 - Activity Feature Lifecycle
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local Runtime = S.FeatureRuntime
local F = S.Features and S.Features.Activities or nil
if type(Runtime) ~= "table" or type(F) ~= "table" or type(F.Authority) ~= "table" then return end

F.Id = "life_activities"
F.ApiDependencies = { "MAP", "QUEST", "BATTLE_FIELD" }
F.enabled = false
F.consumers = F.consumers or {}
F.consumerCount = 0
F.timerTask = "v3_activity_timer"
F.zoneTask = "v3_activity_zone_scan"
F.progressConsumerToken = "activity:progress"
F.progressConsumerHeld = false
F.PersistenceMutationContractVersion = 2

local function SetTaskState(enabled)
    if S.Scheduler == nil or type(S.Scheduler.SetEnabled) ~= "function" then return end
    S.Scheduler:SetEnabled(F.timerTask, enabled == true)
    S.Scheduler:SetEnabled(F.zoneTask, enabled == true)
end

function F:Initialize()
    local ok, err = self:EnsureStoreLoaded()
    if ok ~= true then return false, err end
    local progress = S.Services and S.Services.QuestProgressV3 or nil
    if type(progress) == "table" then
        self.Authority:SetQuestProgressProvider(function(scope, key) return progress:GetQuestProgress(scope, key) end)
        self.Authority:SetInstanceProgressProvider(function(scope, key) return progress:GetInstanceProgress(scope, key) end)
    end
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
        local progressOk, progressErr = progress:AcquireConsumer(self.progressConsumerToken, { instances = true })
        if progressOk ~= true then return false, progressErr end
        self.progressConsumerHeld = true
        SetTaskState(true)
        self.Authority:SyncClock(true)
        self.Authority:ScanTrackedZones()
        local refreshed, refreshErr = self.Authority:Refresh("consumer_acquired")
        if refreshed == false then return false, refreshErr or "activity refresh failed" end
    elseif beforeCount > 0 and afterCount == 0 then
        SetTaskState(false)
        if self.progressConsumerHeld == true then
            local progress = S.Services and S.Services.QuestProgressV3 or nil
            if type(progress) ~= "table" or type(progress.ReleaseConsumer) ~= "function" then
                return false, "quest progress release unavailable"
            end
            local released, releaseErr = progress:ReleaseConsumer(self.progressConsumerToken)
            if released ~= true then return false, releaseErr or "quest progress release failed" end
            self.progressConsumerHeld = false
        end
    end
    return true
end

if S.Demand == nil or type(S.Demand.Create) ~= "function" then error("Demand unavailable for Activities") end
local activityDemand, activityDemandErr = S.Demand:Create({
    id = "feature:" .. F.Id,
    owner = F,
    projectionOwner = F,
    projectionConsumersField = "consumers",
    projectionCountField = "consumerCount",
    reconcile = function(_, before, after) return F:ReconcileDemand(before, after) end,
    quiesce = function(_, reason, cause) return F:QuiesceDemand(reason, cause) end,
})
if activityDemand == nil then error(activityDemandErr) end
F.Demand = activityDemand

function F:AcquireConsumer(token)
    if self.enabled ~= true then return false, "activity feature disabled" end
    return self.Demand:Acquire(token, {}, "activity_consumer")
end

function F:ReleaseConsumer(token)
    return self.Demand:Release(token, "activity_consumer")
end

function F:QuiesceDemand(reason, cause)
    local ok = true
    SetTaskState(false)
    if S.Scheduler ~= nil then
        if type(S.Scheduler.RemoveTask) == "function" then
            S.Scheduler:RemoveTask(self.timerTask)
            S.Scheduler:RemoveTask(self.zoneTask)
        end
        if type(S.Scheduler.RemoveOwner) == "function" then S.Scheduler:RemoveOwner(self) end
    end
    if S.Events ~= nil then
        if type(S.Events.UnsubscribeOwner) == "function" then S.Events:UnsubscribeOwner(self) end
        if type(S.Events.UnsubscribeInternalOwner) == "function" then S.Events:UnsubscribeInternalOwner(self) end
    end
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
    if S.Scheduler == nil or type(S.Scheduler.AddTask) ~= "function" then return false, "scheduler unavailable" end
    if S.Events == nil or type(S.Events.Subscribe) ~= "function" then return false, "event bus unavailable" end

    if self.Demand.count > 0 then return false, "activity demand not idle before enable" end
    self.Authority:ResetTransient()

    local timerAdded = S.Scheduler:AddTask(self.timerTask, 1000, function()
        if F.enabled == true and F.consumerCount > 0 then F.Authority:Refresh("timer") end
    end, false, self, "P4", 1)
    if timerAdded ~= true then return false, "activity timer task registration failed" end
    S.Scheduler:SetTaskModule(self.timerTask, self.Id)

    local zoneAdded = S.Scheduler:AddTask(self.zoneTask, 5000, function()
        if F.enabled == true and F.consumerCount > 0 then
            -- The one-second timer is the presentation publish cadence. Zone
            -- polling only updates transient zone state here; publishing again
            -- in the same five-second window needlessly rebuilds/binds all rows.
            F.Authority:ScanTrackedZones()
        end
    end, false, self, "P2", 2)
    if zoneAdded ~= true then
        S.Scheduler:RemoveTask(self.timerTask)
        return false, "activity zone task registration failed"
    end
    S.Scheduler:SetTaskModule(self.zoneTask, self.Id)
    SetTaskState(false)

    S.Events:BindOwner(self, self.Id)
    local zoneSubscribed = S.Events:Subscribe("HPW_ZONE_STATE_CHANGE", self, function(_, zoneId)
        if F.consumerCount <= 0 then return end
        zoneId = tonumber(zoneId)
        local watched = S.Data and S.Data.ZoneStateWatchById and S.Data.ZoneStateWatchById[zoneId] or nil
        local dynamic = S.Data and S.Data.DynamicEventZones and S.Data.DynamicEventZones[zoneId] or nil
        if watched ~= nil or dynamic ~= nil then
            F.Authority:ScanZone(zoneId)
            F.Authority:Refresh("zone_event")
        end
    end)
    local worldSubscribed = S.Events:Subscribe("ENTERED_WORLD", self, function()
        F.Authority:ResetTransient()
        if F.consumerCount > 0 then
            F.Authority:SyncClock(true)
            F.Authority:ScanTrackedZones()
            F.Authority:Refresh("entered_world")
        end
    end)
    if zoneSubscribed ~= true or worldSubscribed ~= true then
        S.Events:UnsubscribeOwner(self)
        S.Scheduler:RemoveTask(self.timerTask)
        S.Scheduler:RemoveTask(self.zoneTask)
        return false, "activity native event subscription failed"
    end
    if type(S.Events.SubscribeInternal) ~= "function" or S.Events:SubscribeInternal("v3.quest_progress.updated", self, function()
        if F.enabled == true and F.consumerCount > 0 then F.Authority:Refresh("quest_progress") end
    end) ~= true then
        S.Events:UnsubscribeOwner(self)
        if type(S.Events.UnsubscribeInternalOwner) == "function" then S.Events:UnsubscribeInternalOwner(self) end
        S.Scheduler:RemoveOwner(self)
        return false, "quest progress internal subscribe failed"
    end

    self.enabled = true
    -- Floating widget visibility is a Presentation reaction bound to
    -- `v3.feature.lifecycle`; Domain only owns the persisted preference.
    return true
end

function F:Disable(reason)
    if self.enabled ~= true then return true end
    local cleared, clearErr = self.Demand:Clear(reason or "feature_disable")
    if cleared ~= true then return false, clearErr end
    self.enabled = false
    SetTaskState(false)
    if S.Scheduler ~= nil then
        S.Scheduler:RemoveTask(self.timerTask)
        S.Scheduler:RemoveTask(self.zoneTask)
    end
    if S.Events ~= nil then
        S.Events:UnsubscribeOwner(self)
        if type(S.Events.UnsubscribeInternalOwner) == "function" then S.Events:UnsubscribeInternalOwner(self) end
    end
    return true
end

function F:Refresh(reason)
    if self.enabled ~= true then return true end
    if self.consumerCount > 0 then
        self.Authority:SyncClock(reason == "main_open")
        self.Authority:Refresh(reason or "feature_refresh")
    end
    return true
end

function F:PublishWidgetProjection(kind)
    -- Domain publishes a fact; Presentation decides whether a live widget
    -- re-reads the projection. This keeps the Feature → Presentation edge out
    -- of the Domain entirely.
    if S.Events ~= nil and type(S.Events.Publish) == "function" then
        S.Events:Publish("v3.activities.widget_projection", tostring(kind or "projection"))
    end
    return true
end

-- Narrow Presentation read model. Geometry/row-count/visibility remain
-- persisted by this Feature, while Pages and Widgets consume only these
-- getters instead of reaching into the backing State table.
function F:GetWidgetWindowState()
    local value = self.State and self.State.widgetWindow or nil
    local floating = S.RSUI and S.RSUI.FloatingSurface or nil
    if type(floating) == "table" and type(floating.NormalizeState) == "function" then
        return S.Utils.DeepCopy(floating:NormalizeState(value, self:GetWidgetWindowPolicy()))
    end
    return S.Utils.DeepCopy(value)
end

function F:SetWidgetWindowState(value, reason)
    if type(value) ~= "table" or type(self.State) ~= "table" then return false, "activity widget window state unavailable" end
    local floating = S.RSUI and S.RSUI.FloatingSurface or nil
    local persistence = S.Persistence
    if type(persistence) ~= "table" or type(persistence.PrepareWrite) ~= "function" then return false, "activity persistence unavailable" end
    local ready, readyErr = persistence:PrepareWrite(self.StoreId)
    if ready ~= true then return false, readyErr or "活动窗口状态写入前读取失败" end
    local normalized = type(floating) == "table" and type(floating.NormalizeState) == "function"
        and floating:NormalizeState(value, self:GetWidgetWindowPolicy()) or S.Utils.DeepCopy(value)
    self.State.widgetWindow = normalized
    return true
end

function F:GetWidgetWindowPolicy()
    return S.Utils.DeepCopy(self.WidgetWindowSizePolicy or { defaultWidth = 430, defaultHeight = 276, minWidth = 1, minHeight = 1 })
end

function F:GetWidgetRows()
    return tonumber(self.State and self.State.widgetRows) or 8
end

function F:GetWidgetVisiblePreference()
    return self.State and self.State.widgetVisible == true or false
end

-- Public Projection/Commands boundary for Active V3. Presentation does not
-- retain or call the Activity Authority object directly.
function F:GetRows()
    return self.Authority:GetRows()
end

function F:GetRow(key)
    return self.Authority:GetRow(key)
end

function F:GetSummary()
    return self.Authority:GetSummary()
end

function F:RefreshProjection(reason, scanZones)
    if self.enabled ~= true then return false, "activity feature disabled" end
    self.Authority:SyncClock(true)
    if scanZones ~= false then self.Authority:ScanTrackedZones() end
    return self.Authority:Refresh(reason or "presentation_refresh")
end

function F:HideEvent(key)
    return self.Authority:HideEvent(key)
end

function F:RestoreHiddenEvents()
    return self.Authority:RestoreHiddenEvents()
end

function F:ApplyWidgetRows(rows, source)
    rows = math.max(3, math.min(16, math.floor(tonumber(rows) or self.State.widgetRows or 8)))
    if self.State.widgetRows == rows then return true end
    self.State.widgetRows = rows
    self:PublishWidgetProjection("rows")
    return true
end

function F:SetWidgetRows(rows, source)
    rows = math.max(3, math.min(16, math.floor(tonumber(rows) or self.State.widgetRows or 8)))
    if self.State.widgetRows == rows then return true end
    local marked, markErr = self:MutateStore(function() self.State.widgetRows = rows; return true end, 250, source or "widget_rows")
    if marked ~= true then return false, markErr or "活动行数未保存，已回滚" end
    self:PublishWidgetProjection("rows")
    return true
end

function F:ApplyWidgetSize(width, height, source)
    local state = type(self.State.widgetWindow) == "table" and self.State.widgetWindow or nil
    if state == nil then return false, "activity widget window state unavailable" end
    local size = self.WidgetWindowSizePolicy or { defaultWidth = 430, defaultHeight = 276, minWidth = 1, minHeight = 1 }
    local nextWidth = math.max(size.minWidth, tonumber(width) or tonumber(state.width) or size.defaultWidth)
    local nextHeight = math.max(size.minHeight, tonumber(height) or tonumber(state.height) or size.defaultHeight)
    if tonumber(state.width) == nextWidth and tonumber(state.height) == nextHeight then return true end
    local previousWidth, previousHeight, previousMinimized = state.width, state.height, state.minimized
    state.width, state.height = nextWidth, nextHeight
    state.minimized = false
    self:PublishWidgetProjection("size")
    return true
end

function F:SetWidgetSize(width, height, source)
    local size = self.WidgetWindowSizePolicy or { defaultWidth = 430, defaultHeight = 276, minWidth = 1, minHeight = 1 }
    local current = type(self.State.widgetWindow) == "table" and self.State.widgetWindow or nil
    if current == nil then return false, "activity widget window state unavailable" end
    local nextWidth = math.max(size.minWidth, tonumber(width) or tonumber(current.width) or size.defaultWidth)
    local nextHeight = math.max(size.minHeight, tonumber(height) or tonumber(current.height) or size.defaultHeight)
    if tonumber(current.width) == nextWidth and tonumber(current.height) == nextHeight and current.minimized ~= true then return true end
    local marked, markErr = self:MutateStore(function()
        local state = self.State.widgetWindow
        state.width, state.height, state.minimized = nextWidth, nextHeight, false
        return true
    end, 250, source or "widget_size")
    if marked ~= true then return false, markErr or "活动悬浮窗尺寸未保存，已回滚" end
    self:PublishWidgetProjection("size")
    return true
end

function F:SetWidgetVisible(visible, source)
    if self.enabled ~= true then return false, "activity feature disabled" end
    local nextValue = visible == true
    if (self.State.widgetVisible == true) ~= nextValue then
        local marked, markErr = self:MutateStore(function() self.State.widgetVisible = nextValue; return true end, 250, "widget_visibility")
        if marked ~= true then return false, markErr or "活动悬浮窗可见性未保存，已回滚" end
    end
    if S.Events ~= nil and type(S.Events.Publish) == "function" then
        S.Events:Publish("v3.activities.widget_visibility", nextValue, tostring(source or "activity_page"))
    end
    return true
end

function F:GetHealth()
    local summary = self.Authority:GetSummary()
    local progress = S.Services and S.Services.QuestProgressV3 or nil
    local progressHealth = type(progress) == "table" and type(progress.GetHealth) == "function" and progress:GetHealth() or nil
    return {
        ok = self.enabled == true,
        consumers = self.consumerCount,
        rows = summary.total,
        active = summary.active,
        liveZones = summary.liveZones,
        zoneScanFailures = summary.zoneScanFailures,
        questProgressMigrated = summary.progressAuthority == true,
        progressRevision = type(progressHealth) == "table" and progressHealth.revision or 0,
        progressAvailable = type(progressHealth) == "table" and progressHealth.available or 0,
        progressFailures = type(progressHealth) == "table" and progressHealth.refreshFailures or 0,
    }
end

F.Commands = F.Commands or {}
function F.Commands:MarkStoreDirty(delayMs, reason) return F:MarkStoreDirty(delayMs, reason) end
function F.Commands:SetWidgetVisible(visible, source) return F:SetWidgetVisible(visible == true, source or "activity_command") end
function F.Commands:SetWidgetWindowState(value, reason) return F:SetWidgetWindowState(value, reason or "activity_widget_window_state") end
function F.Commands:SetWidgetRows(rows, source) return F:SetWidgetRows(rows, source or "activity_command") end
function F.Commands:SetWidgetSize(width, height, source) return F:SetWidgetSize(width, height, source or "activity_command") end
function F.Commands:RefreshProjection(reason, scanZones) return F:RefreshProjection(reason or "activity_command", scanZones) end
function F.Commands:HideEvent(key) return F:HideEvent(key) end
function F.Commands:RestoreHiddenEvents() return F:RestoreHiddenEvents() end
function F.Commands:ResetWidgetVisibility(source)
    -- Presentation calls this when a lifecycle auto-show fails so the persisted
    -- preference cannot claim a window that is not on screen.
    if F.State.widgetVisible ~= false then
        local marked, markErr = F:MutateStore(function() F.State.widgetVisible = false; return true end, 250, tostring(source or "widget_visibility_reset"))
        if marked ~= true then return false, markErr or "活动悬浮窗复位未保存，已回滚" end
    end
    return true
end

local ok, err = Runtime:RegisterImplementation(F.Id, F)
if ok ~= true then error(err) end
