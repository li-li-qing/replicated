------------------------------------------------------------------------
-- Replicated Suite V3 - Death Review Acceptance
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local G = S.FoundationGate
local F = S.Features and S.Features.DeathReview or nil
if type(G) ~= "table" or type(G.RegisterSequenceCase) ~= "function" or type(F) ~= "table" then return end

local function Fail(message) return false, tostring(message or "death_review_acceptance_failed") end

G:RegisterSequenceCase("v3_m15_2h_death_review_contract", function()
    local meta = S.FeatureRegistry and S.FeatureRegistry:Get("combat_death_review") or nil
    if meta == nil or tostring(meta.status) ~= "migrated_m15_2" or tostring(meta.lifecycle) ~= "independent"
        or tostring(meta.authority) ~= "v3.death_review" or meta.widgetCapable ~= true or meta.settingsCapable ~= true then
        return Fail("metadata_contract")
    end
    if meta.defaultEnabled == true then return Fail("quiet_default_contract") end
    if S.FeatureRuntime == nil or S.FeatureRuntime:IsImplemented("combat_death_review") ~= true then return Fail("implementation_missing") end

    local store = S.Persistence and S.Persistence:GetStore(F.StoreId or "v3.death_review") or nil
    if store == nil or tostring(store.owner or "") ~= "v3.death_review"
        or tostring(store.scope or "") ~= tostring(S.Persistence.Scope.Account)
        or tostring(store.lifetime or "") ~= tostring(S.Persistence.Lifetime.Permanent)
        or tonumber(store.schemaVersion) ~= 1 then
        return Fail("store_contract")
    end

    if F.Demand == nil or type(F.Demand.Acquire) ~= "function" or type(F.Demand.Release) ~= "function"
        or type(F.ReconcileDemand) ~= "function" or type(F.GetSettings) ~= "function" or type(F.SetMaxHistory) ~= "function"
        or tonumber(F.RecordSlots) ~= 31 or type(F.CommitDeathRecord) ~= "function" or type(F.LoadRecord) ~= "function"
        or type(F.DeleteHistoryRecord) ~= "function" then
        return Fail("lifecycle_contract")
    end
    if type(F.Authority) ~= "table" or type(F.Authority.OnCombatFact) ~= "function"
        or type(F.Authority.GetHistoryRows) ~= "function" or type(F.Authority.GetTimelineRows) ~= "function"
        or type(F.Authority.RequestFinalizeDeath) ~= "function" or type(F.Authority.FinalizeDeath) ~= "function"
        or type(F.GetProjection) ~= "function" or type(F.Commands) ~= "table"
        or type(F.Commands.ApplyAutoShow) ~= "function" or type(F.Commands.ApplyShowDebuffs) ~= "function"
        or type(F.Commands.ApplyWindowMs) ~= "function" or type(F.Commands.ApplyMinDamage) ~= "function"
        or type(F.Commands.SetMaxHistory) ~= "function" or type(F.Commands.MarkStoreDirty) ~= "function"
        or type(F.Commands.SetEnabled) ~= "function" or type(F.Commands.DeleteRecord) ~= "function" or type(F.Commands.ClearHistory) ~= "function" then
        return Fail("authority_contract")
    end

    local settings = F:GetSettings()
    if type(settings) ~= "table" or tonumber(settings.windowMs) == nil or tonumber(settings.maxHistory) == nil
        or tonumber(settings.minDamage) == nil or type(settings.autoShow) ~= "boolean" or type(settings.showDebuffs) ~= "boolean" then
        return Fail("settings_contract")
    end
    if tonumber(settings.windowMs) < 3000 or tonumber(settings.windowMs) > 20000
        or tonumber(settings.maxHistory) < 1 or tonumber(settings.maxHistory) > 30
        or tonumber(settings.minDamage) < 0 or tonumber(settings.minDamage) > 5000 then
        return Fail("settings_range")
    end

    local syntheticEvents = {}
    for index = 1, 96 do
        syntheticEvents[index] = { time = index, source = "预算测试来源", ability = "预算测试技能", amount = 9999, environmental = false }
    end
    local syntheticDebuffs = {}
    for index = 1, 10 do syntheticDebuffs[index] = { effectId = index, name = "预算测试减益", stack = 1, path = "ui/test" } end
    local syntheticRecord = {
        schemaVersion = 1, serial = 30, time = 1000, noticeTime = 1000, clock = "12:34:56", windowMs = 10000, totalDamage = 999999,
        lethal = syntheticEvents[#syntheticEvents], events = syntheticEvents, debuffs = syntheticDebuffs,
    }
    local recordProbe = S.Persistence:InspectPayload({ payload = syntheticRecord, __rsmeta = { framework = S.Persistence.FrameworkVersion, store = "v3.death_review.record.1", owner = "v3.death_review", contractVersion = 3, lifetime = "Permanent", scope = "Account", schema = 1 } }, F.RecordBudget)
    if type(recordProbe) ~= "table" or recordProbe.ok ~= true then return Fail("record_budget:" .. tostring(recordProbe and recordProbe.reason)) end

    local summaries = {}
    for index = 1, 30 do
        summaries[index] = { serial = index, storageId = index, time = index, clock = "12:34:56", windowMs = 10000, totalDamage = 999999, lethalSource = "预算测试来源", lethalAbility = "预算测试技能", lethalAmount = 9999, eventCount = 96, debuffCount = 10 }
    end
    local syntheticIndex = { settings = settings, history = { serial = 30, entries = summaries }, legacyImported = true, widgetWindow = { x = 100, y = 100, width = 470, height = 330 } }
    local indexProbe = S.Persistence:InspectPayload({ payload = syntheticIndex, __rsmeta = { framework = S.Persistence.FrameworkVersion, store = "v3.death_review", owner = "v3.death_review", contractVersion = 3, lifetime = "Permanent", scope = "Account", schema = 1 } }, F.IndexBudget)
    if type(indexProbe) ~= "table" or indexProbe.ok ~= true then return Fail("index_budget:" .. tostring(indexProbe and indexProbe.reason)) end

    local bus = S.Services and S.Services.CombatEventBusV3 or nil
    local aura = S.Services and S.Services.AuraObservationV3 or nil
    if type(bus) ~= "table" or type(bus.Subscribe) ~= "function" or type(aura) ~= "table" or type(aura.GetSnapshot) ~= "function" then
        return Fail("shared_service_contract")
    end

    if S.UIV3 == nil or S.UIV3.PageHost == nil or S.UIV3.PageHost.factories["combat.death_review"] == nil then
        return Fail("page_contract")
    end
    local widget = S.UIV3.WidgetHost and S.UIV3.WidgetHost:GetSpec("combat.death_review") or nil
    if widget == nil or widget.featureId ~= "combat_death_review" or widget.minimizable ~= true
        or widget.lockable ~= true or widget.opacityAdjustable ~= true then
        return Fail("widget_contract")
    end

    local health = F:GetHealth()
    if type(health) ~= "table" or (F.enabled == true and health.busScope ~= "self")
        or (F.enabled ~= true and (tonumber(health.consumers) or 0) ~= 0)
        or (tonumber(health.deferredFinalizeFailures) or 0) ~= 0 then
        return Fail("runtime_scope_contract")
    end
    return true
end)


G:RegisterSequenceCase("v3_m15_2h_death_review_widget_close", function()
    local host = S.UIV3 and S.UIV3.WidgetHost or nil
    if type(host) ~= "table" or type(host.SetVisible) ~= "function" then return Fail("widget_host_missing") end

    local wasEnabled = F.enabled == true
    local wasVisible = host.visible ~= nil and host.visible["combat.death_review"] == true

    local function Restore()
        if wasVisible ~= true then host:SetVisible("combat.death_review", false, { persist = false, source = "sequence_restore" }) end
        if wasEnabled ~= true then F.Commands:SetEnabled(false, "sequence_restore") end
        if wasVisible == true then host:SetVisible("combat.death_review", true, { persist = false, source = "sequence_restore" }) end
        return true
    end

    if wasEnabled ~= true then
        local ok, err = F.Commands:SetEnabled(true, "sequence_probe")
        if ok ~= true then Restore(); return Fail("enable:" .. tostring(err)) end
    end
    local opened, openErr = host:SetVisible("combat.death_review", true, { persist = false, source = "sequence_probe" })
    if opened ~= true then Restore(); return Fail("open:" .. tostring(openErr)) end

    local instance = host.instances ~= nil and host.instances["combat.death_review"] or nil
    if type(instance) ~= "table" or type(instance.shell) ~= "table" or type(instance.shell.Close) ~= "function" then
        Restore()
        return Fail("widget_instance_missing")
    end
    -- The Surface and the Host must agree with the native window after a close;
    -- a stale `visible=true` would make ResetLayout/responsive reflow drive a
    -- window that is no longer on screen.
    if type(instance.surface) ~= "table" or type(instance.surface.Close) ~= "function" then
        Restore()
        return Fail("floating_surface_close_missing")
    end
    if instance.surface.visible ~= true then
        Restore()
        return Fail("floating_surface_not_visible_before_close")
    end

    -- One close must produce exactly one onClosed trip: no Shell→Feature→Host
    -- →Widget→Shell recursion.
    local beforeNotifications = tonumber(host.stats and host.stats.nativeCloseNotifications) or 0

    local closed = instance.shell:Close("sequence_probe")
    local hidden = host.visible == nil or host.visible["combat.death_review"] ~= true
    local surfaceSynced = instance.surface.visible == false
    local instanceSynced = instance.visible == false
    local notificationTrips = (tonumber(host.stats and host.stats.nativeCloseNotifications) or 0) - beforeNotifications
    Restore()
    if closed ~= true or hidden ~= true then return Fail("close_contract") end
    if surfaceSynced ~= true then return Fail("floating_surface_visible_desync") end
    if instanceSynced ~= true then return Fail("widget_instance_visible_desync") end
    if notificationTrips ~= 1 then return Fail("close_notification_trips:" .. tostring(notificationTrips)) end
    return true
end)
