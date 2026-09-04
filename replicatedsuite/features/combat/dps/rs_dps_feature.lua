------------------------------------------------------------------------
-- Replicated Suite V3 - DPS Feature
--
-- V3 combat statistics feature. It is a CombatEventBus scope=all consumer only;
-- it owns NO native COMBAT_MSG handler (the bus owns that) and no persistence of
-- running totals. Per-event PVP/PVE classification and accumulation live in the
-- Domain (rs_dps_domain.lua); relation facts live in CombatRelationV3; this file
-- only owns lifecycle, settings, commands and the Projection boundary.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local Runtime = S.FeatureRuntime
S.Features = S.Features or {}
S.Features.DPS = S.Features.DPS or {}
local F = S.Features.DPS
if type(Runtime) ~= "table" then return end

F.Id = "combat_stats"
F.enabled = F.enabled == true
F.consumers = {}
F.consumerCount = 0
F.busSubscribed = false -- direct bus ownership removed in M1.16; retained for compatibility health only
F.analyticsHeld = F.analyticsHeld == true
F.analyticsMetricRegistered = F.analyticsMetricRegistered == true
F.relationHeld = false
F.relationEventsSubscribed = false
F.projectionPublishScheduled = false
F.projectionPublishToken = "v3.dps.projection_publish"
F.pendingReplayScheduled = false
F.pendingReplayToken = "v3.dps.pending_replay"

local function Bus() return S.Services and S.Services.CombatEventBusV3 or nil end
local function Analytics() return S.Services and S.Services.CombatAnalyticsV3 or nil end
local function Relation() return S.Services and S.Services.CombatRelationV3 or nil end
local function Domain() return F.Domain end

function F:_EnsureAnalyticsMetric()
    if self.analyticsMetricRegistered == true then return true end
    local analytics = Analytics()
    if type(analytics) ~= "table" or type(analytics.RegisterMetric) ~= "function" then return false, "combat analytics unavailable" end
    if analytics:GetMetric("dps_core") ~= nil then self.analyticsMetricRegistered = true; return true end
    local ok, err = analytics:RegisterMetric({
        id = "dps_core", title = "DPS Core", category = "core", order = 5, hidden = true,
        factCategories = { "damage", "heal" }, owner = self,
        OnFact = function(_, fact)
            local d = Domain()
            local consumed, meta = false, nil
            if type(d) == "table" and type(d.OnCombatFact) == "function" then consumed, meta = d:OnCombatFact(fact) end
            if consumed == true then
                if type(meta) == "table" and meta.replaySuggested == true then F:SchedulePendingReplay("fact_evidence") end
                F:ScheduleProjectionPublish()
            end
            return consumed == true
        end,
        Reset = function()
            local d = Domain()
            if type(d) == "table" and type(d.ResetTransient) == "function" then d:ResetTransient("dps_metric_inactive") end
            return true
        end,
        GetHealth = function()
            local d = Domain()
            return type(d) == "table" and type(d.GetHealth) == "function" and d:GetHealth() or { ok = false }
        end,
    })
    if ok ~= true then return false, err end
    self.analyticsMetricRegistered = true
    return true
end

function F:Initialize()
    local ok, err = self:EnsureStoreLoaded()
    if ok ~= true then return false, err end
    if type(Domain()) ~= "table" then return false, "dps domain unavailable" end
    if type(Analytics()) ~= "table" then return false, "combat analytics unavailable" end
    if type(Relation()) ~= "table" then return false, "combat relation unavailable" end
    return self:_EnsureAnalyticsMetric()
end

function F:_AcquireAnalytics()
    if self.analyticsHeld == true then return true end
    local ok, err = self:_EnsureAnalyticsMetric()
    if ok ~= true then return false, err end
    local analytics = Analytics()
    ok, err = analytics:AcquireConsumer("dps_core", { metrics = { "dps_core" } }, "dps_enable")
    if ok ~= true then return false, err end
    self.analyticsHeld = true
    return true
end

function F:_ReleaseAnalytics()
    if self.analyticsHeld ~= true then return true end
    local analytics = Analytics()
    if type(analytics) ~= "table" or type(analytics.ReleaseConsumer) ~= "function" then return false, "combat analytics release unavailable" end
    local ok, err = analytics:ReleaseConsumer("dps_core", "dps_disable")
    if ok ~= true then return false, err end
    self.analyticsHeld = false
    return true
end

function F:_AcquireRelation()
    if self.relationHeld == true then return true end
    local relation = Relation()
    if type(relation) ~= "table" or type(relation.AcquireConsumer) ~= "function" then return false, "combat relation unavailable" end
    local ok, err = relation:AcquireConsumer("dps", { purpose = "dps" })
    if ok ~= true then return false, err end
    self.relationHeld = true
    return true
end

function F:_ReleaseRelation()
    if self.relationHeld ~= true then return true end
    local relation = Relation()
    if type(relation) ~= "table" or type(relation.ReleaseConsumer) ~= "function" then return false, "combat relation release unavailable" end
    local ok, err = relation:ReleaseConsumer("dps")
    if ok ~= true then return false, err end
    self.relationHeld = false
    return true
end

function F:_SubscribeRelationEvents()
    if self.relationEventsSubscribed == true then return true end
    if S.Events == nil or type(S.Events.SubscribeInternal) ~= "function" then return false, "internal event bus unavailable" end
    local subscribed = S.Events:SubscribeInternal("v3.combat_relation.updated", self, function(_, reason)
        if F.enabled == true then F:SchedulePendingReplay("relation:" .. tostring(reason or "updated")) end
    end)
    if subscribed ~= true then return false, "combat relation update subscribe failed" end
    self.relationEventsSubscribed = true
    return true
end

function F:_UnsubscribeRelationEvents()
    if self.relationEventsSubscribed ~= true then return true end
    if S.Events ~= nil and type(S.Events.UnsubscribeInternal) == "function" then S.Events:UnsubscribeInternal("v3.combat_relation.updated", self) end
    self.relationEventsSubscribed = false
    return true
end

function F:ReconcileDemand(before, after, context)
    local beforeCount = tonumber(before and before.count) or 0
    local afterCount = tonumber(after and after.count) or 0
    local rollback = type(context) == "table" and context.rollback == true
    if beforeCount <= 0 and afterCount > 0 then
        if rollback ~= true then
            local d = Domain()
            if type(d) == "table" and type(d.ResetTransient) == "function" then d:ResetTransient("dps_enable") end
        end
        local relationOk, relationErr = self:_AcquireRelation()
        if relationOk ~= true then return false, relationErr end
        local relationSubOk, relationSubErr = self:_SubscribeRelationEvents()
        if relationSubOk ~= true then return false, relationSubErr end
        local analyticsOk, analyticsErr = self:_AcquireAnalytics()
        if analyticsOk ~= true then return false, analyticsErr end
    elseif beforeCount > 0 and afterCount <= 0 then
        local analyticsOk, analyticsErr = self:_ReleaseAnalytics()
        if analyticsOk ~= true then return false, analyticsErr end
        self:_UnsubscribeRelationEvents()
        local relationOk, relationErr = self:_ReleaseRelation()
        if relationOk ~= true then return false, relationErr end
        self:CancelPendingReplay()
    end
    return true
end

if S.Demand == nil or type(S.Demand.Create) ~= "function" then error("Demand unavailable for DPS") end
local lease, leaseErr = S.Demand:Create({
    id = "feature:" .. F.Id,
    owner = F,
    projectionOwner = F,
    projectionConsumersField = "consumers",
    projectionCountField = "consumerCount",
    reconcile = function(_, before, after, context) return F:ReconcileDemand(before, after, context) end,
    quiesce = function()
        local ok = true
        if F:_ReleaseAnalytics() ~= true then ok = false end
        F:_UnsubscribeRelationEvents()
        if F:_ReleaseRelation() ~= true then ok = false end
        F.analyticsHeld, F.busSubscribed, F.relationHeld = false, false, false
        F:CancelProjectionPublish()
        F:CancelPendingReplay()
        return ok
    end,
})
if lease == nil then error(leaseErr) end
F.Demand = lease

function F:Enable(reason)
    if self.enabled == true then return true end
    self.enabled = true
    local ok, err = self.Demand:Acquire("runtime", {}, reason or "feature_enable")
    if ok ~= true then self.enabled = false; return false, err end
    return true
end

function F:Disable(reason)
    if self.enabled ~= true then return true end
    local ok, err = self.Demand:Clear(reason or "feature_disable")
    if ok ~= true then return false, err end
    self.enabled = false
    self:CancelProjectionPublish()
    return true
end

------------------------------------------------------------------------
-- Settings
------------------------------------------------------------------------
local function PublishSettingChanged(key)
    if S.Events ~= nil and type(S.Events.Publish) == "function" then S.Events:Publish("v3.dps.settings", tostring(key or "")) end
end

-- Persistent RSUI bindings own the write-fence + MarkDirty transaction. This
-- path mutates only the Domain setting and publishes the projection change.
function F:ApplySettingFromBinding(key, value)
    key = tostring(key or "")
    local ok, err = self:ApplySettingRaw(key, value)
    if ok ~= true then return false, err end
    PublishSettingChanged(key)
    return true
end

-- Command/non-RSUI callers do not have a PersistentSettingBinding around them,
-- so the Feature must queue persistence itself and roll the scalar back on a
-- write fence/failure. This keeps both entry paths transactional without
-- double-marking the Store from normal UI controls.
function F:SetSettingValue(key, value)
    key = tostring(key or "")
    local dirtyOk, dirtyErr = self:MutateStore(function() return self:ApplySettingRaw(key, value) end, 300, "setting_" .. key)
    if dirtyOk ~= true then return false, dirtyErr or "DPS 设置保存排队失败" end
    PublishSettingChanged(key)
    return true
end

function F:SetMode(value) return self:SetSettingValue("mode", value) end
function F:SetSide(value) return self:SetSettingValue("side", value) end
function F:SetMetric(value) return self:SetSettingValue("metric", value) end
function F:SetDisplayRows(value) return self:SetSettingValue("displayRows", value) end
function F:SetAlwaysShowSelf(value) return self:SetSettingValue("alwaysShowSelf", value == true) end

function F:AddBossName(name)
    local ok, err = self:SetBossName(name)
    if ok == true and S.Events ~= nil and type(S.Events.Publish) == "function" then S.Events:Publish("v3.dps.settings", "bossNames") end
    return ok, err
end

function F:RemoveBossName(name)
    local ok, err = self:DeleteBossName(name)
    if ok == true and S.Events ~= nil and type(S.Events.Publish) == "function" then S.Events:Publish("v3.dps.settings", "bossNames") end
    return ok, err
end

------------------------------------------------------------------------
-- Clear: statistics only. The combat consumer is owned by the Demand lease and
-- must survive this call.
------------------------------------------------------------------------
function F:ClearStats(reason)
    local d = Domain()
    if type(d) ~= "table" or type(d.ClearStats) ~= "function" then return false, "dps domain unavailable" end
    local ok = d:ClearStats(reason or "user_clear")
    if ok == true and S.Events ~= nil and type(S.Events.Publish) == "function" then
        S.Events:Publish("v3.dps.updated", "clear")
    end
    return ok
end

------------------------------------------------------------------------
-- Throttled projection publish (keeps the live meter off the native combat
-- callback hot path).
------------------------------------------------------------------------
function F:ScheduleProjectionPublish()
    if self.projectionPublishScheduled == true then return true end
    if S.Scheduler == nil or type(S.Scheduler.AddOneShot) ~= "function" then
        if S.Events ~= nil and type(S.Events.Publish) == "function" then S.Events:Publish("v3.dps.updated", "fact") end
        return true
    end
    self.projectionPublishScheduled = true
    local ok = S.Scheduler:AddOneShot(self.projectionPublishToken, 400, function()
        F.projectionPublishScheduled = false
        if S.Events ~= nil and type(S.Events.Publish) == "function" then S.Events:Publish("v3.dps.updated", "fact") end
        return true
    end, self, "P2", 1)
    if ok ~= true then self.projectionPublishScheduled = false end
    return ok
end

function F:CancelProjectionPublish()
    self.projectionPublishScheduled = false
    if S.Scheduler ~= nil and type(S.Scheduler.RemoveTask) == "function" then S.Scheduler:RemoveTask(self.projectionPublishToken) end
    return true
end

function F:SchedulePendingReplay(reason)
    if self.pendingReplayScheduled == true then return true end
    local d = Domain()
    if type(d) ~= "table" or type(d.ReplayPending) ~= "function" then return false end
    if S.Scheduler == nil or type(S.Scheduler.AddOneShot) ~= "function" then return false, "scheduler unavailable" end
    self.pendingReplayScheduled = true
    local ok = S.Scheduler:AddOneShot(self.pendingReplayToken, 160, function()
        F.pendingReplayScheduled = false
        local replayOk = d:ReplayPending(reason or "evidence")
        if replayOk == true then F:ScheduleProjectionPublish() end
        return replayOk
    end, self, "P1", 2)
    if ok ~= true then self.pendingReplayScheduled = false end
    return ok
end

function F:CancelPendingReplay()
    self.pendingReplayScheduled = false
    if S.Scheduler ~= nil and type(S.Scheduler.RemoveTask) == "function" then S.Scheduler:RemoveTask(self.pendingReplayToken) end
    return true
end

-- Narrow Presentation read model for the shared RSUI window shell.
function F:GetWidgetWindowState()
    local value = self.State and self.State.widgetWindow or nil
    local floating = S.RSUI and S.RSUI.FloatingSurface or nil
    local policy = { defaultWidth = 470, defaultHeight = 330, minWidth = 1, minHeight = 1,
        defaultOverallOpacity = 0.96, defaultBackgroundOpacity = 1.0, defaultTextOpacity = 1.0 }
    if type(floating) == "table" and type(floating.NormalizeState) == "function" then
        return S.Utils.DeepCopy(floating:NormalizeState(value, policy))
    end
    return S.Utils.DeepCopy(value)
end

function F:SetWidgetWindowState(value, reason)
    if type(value) ~= "table" or type(self.State) ~= "table" then return false, "dps widget window state unavailable" end
    local floating = S.RSUI and S.RSUI.FloatingSurface or nil
    local policy = { defaultWidth = 470, defaultHeight = 330, minWidth = 1, minHeight = 1,
        defaultOverallOpacity = 0.96, defaultBackgroundOpacity = 1.0, defaultTextOpacity = 1.0 }
    self.State.widgetWindow = type(floating) == "table" and type(floating.NormalizeState) == "function"
        and floating:NormalizeState(value, policy) or S.Utils.DeepCopy(value)
    return true
end

function F:Refresh(reason) return true end

------------------------------------------------------------------------
-- Projection / Commands
------------------------------------------------------------------------
F.Commands = F.Commands or {}
function F.Commands:SetEnabled(enabled, reason)
    return S.FeatureRuntime:SetPreferredEnabled(F.Id, enabled == true, reason or "dps_command")
end
function F.Commands:ApplySettingFromBinding(key, value) return F:ApplySettingFromBinding(key, value) end
function F.Commands:MarkStoreDirty(delayMs, reason) return F:MarkStoreDirty(delayMs, reason) end
function F.Commands:Clear(reason) return F:ClearStats(reason) end
function F.Commands:SetMode(mode) return F:SetMode(mode) end
function F.Commands:SetSide(side) return F:SetSide(side) end
function F.Commands:SetMetric(metric) return F:SetMetric(metric) end
function F.Commands:SetDisplayRows(rows) return F:SetDisplayRows(rows) end
function F.Commands:SetAlwaysShowSelf(value) return F:SetAlwaysShowSelf(value) end
function F.Commands:AddBossName(name) return F:AddBossName(name) end
function F.Commands:RemoveBossName(name) return F:RemoveBossName(name) end
function F.Commands:GetActorDetail(request) return F:GetActorDetail(request) end
function F.Commands:SetWidgetWindowState(value, reason) return F:SetWidgetWindowState(value, reason) end


function F:GetActorDetail(request)
    local d = Domain()
    if type(d) ~= "table" or type(d.GetActorDetail) ~= "function" then
        return { actor = nil, abilities = {}, counterparts = {}, revision = 0 }
    end
    local detail = S.Utils.DeepCopy(d:GetActorDetail(request))
    -- Skill metadata is presentation drill-down enrichment, never combat hot-path
    -- work. The shared service performs bounded lazy X2Skill resolution and
    -- caches positive/negative results so repeated detail refreshes stay cheap.
    local metadata = S.Services and S.Services.SkillMetadataV3 or nil
    for _, row in ipairs(type(detail.abilities) == "table" and detail.abilities or {}) do
        if type(metadata) == "table" and type(metadata.GetSkillInfo) == "function" then
            local info = metadata:GetSkillInfo(row.abilityId, row.name)
            if type(info) == "table" then
                row.skillId = info.skillId
                row.iconPath = tostring(info.iconPath or "ui/icon/icon_unknown_item.dds")
                if tostring(info.name or "") ~= "" then row.name = tostring(info.name) end
                row.metadataSource = info.source
            end
        else
            row.skillId = tonumber(row.abilityId)
            row.iconPath = "ui/icon/icon_unknown_item.dds"
        end
    end
    return detail
end

function F:GetProjection(request)
    request = type(request) == "table" and request or {}
    local runtime = S.FeatureRuntime and S.FeatureRuntime:GetSnapshot(self.Id) or nil
    local d = Domain()
    local bus = Bus()
    local busHealth = type(bus) == "table" and type(bus.GetHealth) == "function" and bus:GetHealth() or nil
    local projection = type(d) == "table" and type(d.GetProjection) == "function" and d:GetProjection(request) or nil
    return {
        enabled = runtime ~= nil and runtime.enabled == true or false,
        settings = S.Utils.DeepCopy(self:GetSettings()),
        bossNames = self:GetBossNames(),
        coverageState = type(busHealth) == "table" and tostring(busHealth.coverageState or "INACTIVE") or "INACTIVE",
        busScope = self.analyticsHeld == true and "all(shared_analytics)" or "none",
        projection = projection,
        health = S.Utils.DeepCopy(self:GetHealth()),
    }
end

function F:GetSettingsProjection()
    return S.Utils.DeepCopy(self:GetSettings() or {})
end

function F:GetHealth()
    local d = Domain()
    local domain = type(d) == "table" and type(d.GetHealth) == "function" and d:GetHealth() or nil
    local bus = Bus()
    local busHealth = type(bus) == "table" and type(bus.GetHealth) == "function" and bus:GetHealth() or nil
    local relation = Relation()
    local relationHealth = type(relation) == "table" and type(relation.GetHealth) == "function" and relation:GetHealth() or nil
    local roster = S.Services and S.Services.TeamRosterV3 or nil
    local rosterHealth = type(roster) == "table" and type(roster.GetHealth) == "function" and roster:GetHealth() or nil
    return {
        ok = self.enabled == true,
        consumers = self.consumerCount,
        busSubscribed = false,
        analyticsHeld = self.analyticsHeld == true,
        busScope = self.analyticsHeld == true and "all(shared_analytics)" or "none",
        relationHeld = self.relationHeld == true,
        classificationPVP = domain and domain.classifiedPVP or 0,
        classificationPVE = domain and domain.classifiedPVE or 0,
        classificationUnknown = domain and domain.classifiedUnknown or 0,
        classificationHeal = domain and domain.classifiedHeal or 0,
        provisional = domain and domain.provisional or 0,
        pendingRows = domain and domain.pendingRows or 0,
        pendingLedgerSlots = domain and domain.pendingLedgerSlots or 0,
        replays = domain and domain.replays or 0,
        replayUpgrades = domain and domain.replayUpgrades or 0,
        replayReclassifications = domain and domain.replayReclassifications or 0,
        pendingEvicted = domain and domain.pendingEvicted or 0,
        unresolvedDamage = domain and domain.unresolvedDamage or 0,
        unresolvedHeal = domain and domain.unresolvedHeal or 0,
        sideUnknownHeal = domain and domain.sideUnknownHeal or 0,
        proxySourceHeals = domain and domain.proxySourceHeals or 0,
        proxySourceHealAmount = domain and domain.proxySourceHealAmount or 0,
        unresolvedTaken = domain and domain.unresolvedTaken or 0,
        droppedNoIdentity = domain and domain.droppedNoIdentity or 0,
        unknownRelations = domain and domain.unknownRelations or 0,
        events = domain and domain.events or 0,
        actors = domain and domain.actors or 0,
        busPrivateRows = busHealth and busHealth.privateRows or 0,
        busGlobalRows = busHealth and busHealth.globalRows or 0,
        busGlobalSelfFiltered = busHealth and busHealth.globalSelfFiltered or 0,
        busCrossHostDuplicates = busHealth and busHealth.globalCrossHostDuplicates or 0,
        busCrossHostPending = busHealth and busHealth.globalCrossHostPending or 0,
        busCrossHostEvicted = busHealth and busHealth.globalCrossHostEvicted or 0,
        busJournalDropped = busHealth and busHealth.journalDropped or 0,
        busFactMutationErrors = busHealth and busHealth.factMutationErrors or 0,
        relationUnits = relationHealth and relationHealth.units or 0,
        relationUnknown = relationHealth and relationHealth.unknown or 0,
        relationEvidenceApplied = relationHealth and relationHealth.evidenceApplied or 0,
        relationConflicts = relationHealth and relationHealth.conflicts or 0,
        teamMembers = rosterHealth and rosterHealth.members or 0,
        teamScans = rosterHealth and rosterHealth.scans or 0,
        teamScanFailures = rosterHealth and rosterHealth.scanFailures or 0,
        teamRetries = rosterHealth and rosterHealth.retries or 0,
        teamRetryStreak = rosterHealth and rosterHealth.retryStreak or 0,
    }
end

local ok, err = Runtime:RegisterImplementation(F.Id, F)
if ok ~= true then error(err) end
