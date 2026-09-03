------------------------------------------------------------------------
-- Replicated Suite V3 - Healer Feature Lifecycle
--
-- Feature Enabled owns one independent Healer runtime lease. Resource order:
--   TeamRosterV3 -> HealerAuraBridge -> internal events -> HealthRuntime.
-- Shutdown is the exact reverse so no observer can outlive the feature.
-- Presentation consumes only public projection/commands and never owns these facts.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local Runtime = S.FeatureRuntime
local F = S.Features and S.Features.Healer or nil
if type(Runtime) ~= "table" or type(F) ~= "table" then return end

F.Id = "combat_healer"
F.ApiDependencies = { "TEAM" }
F.enabled = F.enabled == true
F.consumers = {}
F.consumerCount = 0
F.rosterToken = "feature:combat_healer:roster"
F.rosterHeld = false
F.auraHeld = false
F.eventsSubscribed = false

local function TeamRoster() return S.Services and S.Services.TeamRosterV3 or nil end
local function AuraBridge() return S.Features and S.Features.HealerAuraBridge or nil end
local function HealthRuntime() return F.HealthRuntime end
local function ScreenProjection() return S.Features and S.Features.HealerScreenProjection or nil end
local function ClampTeamId(value, fallback)
    local v = math.floor(tonumber(value) or 0)
    if v ~= 1 and v ~= 2 then v = (fallback == 2) and 2 or 1 end
    return v
end

function F:Initialize()
    local ok, err = self:EnsureStoreLoaded()
    if ok ~= true then return false, err end
    if type(self.Roster) ~= "table" or type(self.Recommendation) ~= "table" or type(self.HealthRuntime) ~= "table" then
        return false, "治疗辅助 V3 Domain 未完整加载"
    end
    if type(TeamRoster()) ~= "table" then return false, "TeamRosterV3 unavailable" end
    if type(AuraBridge()) ~= "table" or type(AuraBridge().ReadAccurate) ~= "function" then return false, "HealerAuraBridge unavailable" end
    return true
end

function F:_AcquireRoster()
    if self.rosterHeld == true then return true end
    local roster = TeamRoster()
    if type(roster) ~= "table" or type(roster.AcquireConsumer) ~= "function" then return false, "团队名单服务不可用" end
    local ok, err = roster:AcquireConsumer(self.rosterToken, { purpose = "healer_runtime" })
    if ok ~= true then return false, err end
    self.rosterHeld = true
    return true
end

function F:_ReleaseRoster()
    if self.rosterHeld ~= true then return true end
    local roster = TeamRoster()
    if type(roster) ~= "table" or type(roster.ReleaseConsumer) ~= "function" then return false, "团队名单释放不可用" end
    local ok, err = roster:ReleaseConsumer(self.rosterToken)
    if ok ~= true then return false, err end
    self.rosterHeld = false
    return true
end

function F:_AcquireAura(reason)
    if self.auraHeld == true then return true end
    local bridge = AuraBridge()
    if type(bridge) ~= "table" or type(bridge.Start) ~= "function" then return false, "治疗状态共享桥不可用" end
    local ok, err = bridge:Start(reason or "healer_enable")
    if ok ~= true then return false, err end
    self.auraHeld = true
    return true
end

function F:_ReleaseAura(reason)
    if self.auraHeld ~= true then return true end
    local bridge = AuraBridge()
    if type(bridge) ~= "table" or type(bridge.Stop) ~= "function" then return false, "治疗状态共享桥释放不可用" end
    local ok, err = bridge:Stop(reason or "healer_disable")
    if ok ~= true then return false, err end
    self.auraHeld = false
    return true
end

function F:_SubscribeDomainEvents()
    if self.eventsSubscribed == true then return true end
    if S.Events == nil or type(S.Events.SubscribeInternal) ~= "function" then return false, "V3 internal event bus unavailable" end
    local rosterOk = S.Events:SubscribeInternal("v3.team_roster.updated", self, function(_, _, reason)
        local health = HealthRuntime()
        if type(health) == "table" and type(health.OnRosterUpdated) == "function" then health:OnRosterUpdated(reason) end
    end)
    if rosterOk ~= true then return false, "healer roster event subscribe failed" end
    local settingsOk = S.Events:SubscribeInternal("v3.healer.settings", self, function(_, key)
        local health = HealthRuntime()
        if type(health) == "table" and type(health.OnScoringPolicyChanged) == "function" then health:OnScoringPolicyChanged(key) end
    end)
    if settingsOk ~= true then
        S.Events:UnsubscribeInternal("v3.team_roster.updated", self)
        return false, "healer settings event subscribe failed"
    end
    self.eventsSubscribed = true
    return true
end

function F:_UnsubscribeDomainEvents()
    if self.eventsSubscribed ~= true then return true end
    if S.Events == nil or type(S.Events.UnsubscribeInternal) ~= "function" then return false, "V3 internal event bus release unavailable" end
    S.Events:UnsubscribeInternal("v3.team_roster.updated", self)
    S.Events:UnsubscribeInternal("v3.healer.settings", self)
    self.eventsSubscribed = false
    return true
end

function F:_StartRuntime(reason)
    local ok, err = self:_AcquireRoster()
    if ok ~= true then return false, err end
    ok, err = self:_AcquireAura(reason)
    if ok ~= true then return false, err end
    ok, err = self:_SubscribeDomainEvents()
    if ok ~= true then return false, err end
    local health = HealthRuntime()
    if type(health) ~= "table" or type(health.Start) ~= "function" then return false, "治疗 Health Runtime 不可用" end
    ok, err = health:Start(reason or "healer_enable")
    if ok ~= true then return false, err end
    return true
end

function F:_StopRuntime(reason)
    local health = HealthRuntime()
    if type(health) == "table" and type(health.Stop) == "function" then
        local ok, err = health:Stop(reason or "healer_disable")
        if ok ~= true then return false, err end
    end
    local eventsOk, eventsErr = self:_UnsubscribeDomainEvents()
    if eventsOk ~= true then return false, eventsErr end
    local auraOk, auraErr = self:_ReleaseAura(reason)
    if auraOk ~= true then return false, auraErr end
    local rosterOk, rosterErr = self:_ReleaseRoster()
    if rosterOk ~= true then return false, rosterErr end
    return true
end

function F:ReconcileDemand(before, after)
    local beforeCount = tonumber(before and before.count) or 0
    local afterCount = tonumber(after and after.count) or 0
    if beforeCount <= 0 and afterCount > 0 then return self:_StartRuntime("demand_start") end
    if beforeCount > 0 and afterCount <= 0 then return self:_StopRuntime("demand_stop") end
    return true
end

if S.Demand == nil or type(S.Demand.Create) ~= "function" then error("Demand unavailable for Healer") end
local demand, demandErr = S.Demand:Create({
    id = "feature:" .. F.Id,
    owner = F,
    projectionOwner = F,
    projectionConsumersField = "consumers",
    projectionCountField = "consumerCount",
    reconcile = function(_, before, after) return F:ReconcileDemand(before, after) end,
    quiesce = function()
        local ok = true
        local health = HealthRuntime()
        if type(health) == "table" and health.running == true and health:Stop("runtime_quiesce") ~= true then ok = false end
        if F:_UnsubscribeDomainEvents() ~= true then ok = false end
        if F:_ReleaseAura("runtime_quiesce") ~= true then ok = false end
        if F:_ReleaseRoster() ~= true then ok = false end
        return ok
    end,
})
if demand == nil then error(demandErr) end
F.Demand = demand

function F:AcquireConsumer(token)
    if self.enabled ~= true then return false, "治疗辅助未启用" end
    return self.Demand:Acquire(token, {}, "healer_consumer")
end

-- Calibration is an explicit Presentation preview.  It is allowed to acquire
-- the same read-only Healer facts without changing the user's persistent
-- Feature enabled preference.  This keeps the calibration grid useful (real
-- roster colors) while still releasing all Team/Aura/Health resources when the
-- calibration panel closes.
function F:AcquirePreviewConsumer(token)
    return self.Demand:Acquire(token, { preview = true }, "healer_calibration_preview")
end
function F:HasConsumer(token)
    return self.Demand ~= nil and type(self.Demand.Has) == "function" and self.Demand:Has(token) == true
end

function F:ReleaseConsumer(token)
    return self.Demand:Release(token, "healer_consumer")
end

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
    return true
end

function F:GetProjection(limit)
    if type(self.Recommendation) ~= "table" or type(self.Recommendation.GetProjection) ~= "function" then
        return { revision = 0, recommendationCount = 0, unavailableCount = 0, recommendations = {}, unavailable = {} }
    end
    return self.Recommendation:GetProjection(limit)
end

function F:GetSettingsProjection()
    return S.Utils.DeepCopy(self:GetSettings() or {})
end

function F:GetPresentationProjection(scope)
    return S.Utils.DeepCopy(self:GetPresentationSettings(scope) or {})
end

function F:GetMemberDetail(key)
    if type(self.Recommendation) ~= "table" or type(self.Recommendation.GetMemberProjection) ~= "function" then return nil end
    return self.Recommendation:GetMemberProjection(key)
end

function F:GetRosterProjection()
    if type(self.Roster) ~= "table" or type(self.Roster.GetSnapshot) ~= "function" then return { revision=0, count=0, members={} } end
    return self.Roster:GetSnapshot()
end

function F:GetRaidOverlayProjection()
    local roster = self:GetRosterProjection()
    local recommendation = self.Recommendation
    if type(recommendation) ~= "table" or type(recommendation.GetRaidDisplayProjection) ~= "function" then
        return { revision=0, rosterCount=tonumber(roster and roster.count) or 0, candidateCount=0, rows={} }
    end
    local presentation = type(self.GetPresentationSettings) == "function" and self:GetPresentationSettings("raid") or nil
    return recommendation:GetRaidDisplayProjection(type(roster) == "table" and roster.members or {}, {
        proximityMode = type(presentation) ~= "table" or presentation.proximityMode ~= false,
    })
end

-- Resolve which team identity each visible overlay panel currently displays.
-- RaidTeam (TeamRosterV3 identity) is decoupled from RaidPanel (screen container):
-- the binding can change (native team switch, manual override) without touching any
-- geometry. Returns an ordered list of { id="A"|"B", team=1|2, geometry, isOnly }.
function F:GetEffectivePanelBindings()
    local raid = type(self.GetPresentationSettings) == "function" and self:GetPresentationSettings("raid") or nil
    if type(raid) ~= "table" then return {} end
    local panels = type(raid.panels) == "table" and raid.panels or {}
    local presentTeams = {}
    local roster = self:GetRosterProjection()
    if type(roster) == "table" and type(roster.members) == "table" then
        for _, member in ipairs(roster.members) do
            local t = tonumber(member.teamIndex) or 0
            if t > 0 then presentTeams[t] = true end
        end
    end
    local mode = raid.mode or "auto"
    local out = {}
    if mode == "dual" then
        local A = panels.A or { team = 1 }
        local B = panels.B or { team = 2 }
        out[1] = { id = "A", team = ClampTeamId(A.team), geometry = A.geometry, isOnly = false }
        out[2] = { id = "B", team = ClampTeamId(B.team, 2), geometry = B.geometry, isOnly = false }
    elseif mode == "single" then
        local team = tonumber(raid.singleTeamId) or 0
        if team < 1 then team = next(presentTeams) or 1 end
        out[1] = { id = "A", team = team, geometry = (panels.A or {}).geometry, isOnly = true }
    else -- auto: derive from the actual team composition reported by TeamRosterV3
        local teamList = {}
        for t in pairs(presentTeams) do teamList[#teamList + 1] = t end
        table.sort(teamList)
        if #teamList >= 2 then
            local A = panels.A or { team = teamList[1] }
            local B = panels.B or { team = teamList[2] }
            out[1] = { id = "A", team = teamList[1], geometry = A.geometry, isOnly = false }
            out[2] = { id = "B", team = teamList[2], geometry = B.geometry, isOnly = false }
        else
            local team = teamList[1] or 1
            out[1] = { id = "A", team = team, geometry = (panels.A or {}).geometry, isOnly = true }
        end
    end
    return out
end

-- Diagnostic: briefly flash the player's own slot in every active overlay panel.
-- Presentation owns the transient highlight; this only publishes an internal signal.
function F:LocateSelf()
    if S.Events == nil or type(S.Events.Publish) ~= "function" then return false, "internal event bus unavailable" end
    S.Events:Publish("v3.healer.locate_self")
    return true
end

-- Narrow Presentation command. World->screen is a Native observation and must
-- remain behind Feature/Domain ownership; Head Marker never touches X2Unit.
function F:ProjectUnitToScreen(unitToken)
    local bridge = ScreenProjection()
    if type(bridge) ~= "table" or type(bridge.ProjectUnit) ~= "function" then return nil, "screen projection bridge unavailable" end
    return bridge:ProjectUnit(unitToken)
end

function F:RequestRosterRefresh(reason)
    local roster = TeamRoster()
    if type(roster) ~= "table" or type(roster.ScheduleRefresh) ~= "function" then return false, "团队名单服务不可用" end
    local ok, err = roster:ScheduleRefresh(80, tostring(reason or "healer_manual"))
    if ok == false then return false, err end
    return true, err
end

-- Presentation writes enter through one Feature command surface. The Store
-- remains responsible for normalization and dirty rollback; Presentation does
-- not reach the mutation Authority directly.
F.Commands = F.Commands or {}
function F.Commands:ApplySettingFromBinding(key, value) return F:ApplySettingFromBinding(key, value) end
function F.Commands:ApplyPresentationSettingFromBinding(scope, key, value)
    return F:ApplyPresentationSettingFromBinding(scope, key, value)
end
function F.Commands:SetScalarSetting(key, value) return F:SetScalarSetting(key, value) end
function F.Commands:SetRule(index, key, value) return F:SetRule(index, key, value) end
function F.Commands:AddRule(template) return F:AddRule(template) end
function F.Commands:RemoveRule(index) return F:RemoveRule(index) end
function F.Commands:SetTrackedBuff(index, key, value) return F:SetTrackedBuff(index, key, value) end
function F.Commands:AddTrackedBuff(id, name, iconPath) return F:AddTrackedBuff(id, name, iconPath) end
function F.Commands:RemoveTrackedBuff(index) return F:RemoveTrackedBuff(index) end
function F.Commands:SetHealerColor(key, color) return F:SetHealerColor(key, color) end
function F.Commands:SetPresentationSetting(scope, key, value) return F:SetPresentationSetting(scope, key, value) end
function F.Commands:SetRaidPanelRect(panelId, rect) return F:SetRaidPanelRect(panelId, rect) end
function F.Commands:SetRaidPanelTeam(panelId, team) return F:SetRaidPanelTeam(panelId, team) end
function F.Commands:SetRaidMode(mode) return F:SetRaidMode(mode) end
function F.Commands:SetRaidSingleTeam(teamId) return F:SetRaidSingleTeam(teamId) end
function F.Commands:SetRaidTestSetting(key, value) return F:SetRaidTestSetting(key, value) end
function F.Commands:ResetRaidLayout() return F:ResetRaidLayout() end
function F.Commands:LocateSelf() return F:LocateSelf() end
function F.Commands:RequestRosterRefresh(reason) return F:RequestRosterRefresh(reason) end
function F.Commands:MarkStoreDirty(delayMs, reason) return F:MarkStoreDirty(delayMs, reason) end
function F.Commands:SetWidgetWindowState(value, reason) return F:SetWidgetWindowState(value, reason) end

function F:GetHealth()
    local rosterHealth = type(self.Roster) == "table" and self.Roster:GetHealth() or nil
    local auraHealth = type(AuraBridge()) == "table" and AuraBridge():GetHealth() or nil
    local runtimeHealth = type(self.HealthRuntime) == "table" and self.HealthRuntime:GetHealth() or nil
    local recommendationHealth = type(self.Recommendation) == "table" and self.Recommendation:GetHealth() or nil
    local storeHealth = type(self.GetStoreHealth) == "function" and self:GetStoreHealth() or nil
    return {
        version = 1,
        enabled = self.enabled == true,
        consumers = tonumber(self.consumerCount) or 0,
        rosterHeld = self.rosterHeld == true,
        auraHeld = self.auraHeld == true,
        eventsSubscribed = self.eventsSubscribed == true,
        store = storeHealth,
        roster = rosterHealth,
        aura = auraHealth,
        runtime = runtimeHealth,
        recommendation = recommendationHealth,
    }
end

local ok, err = Runtime:RegisterImplementation(F.Id, F)
if ok ~= true then error(err) end
