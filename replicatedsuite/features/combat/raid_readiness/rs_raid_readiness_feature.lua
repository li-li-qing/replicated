------------------------------------------------------------------------
-- Replicated Suite V3 - Raid Readiness Feature Lifecycle
--
-- Page visibility holds only the lightweight TeamRoster consumer. Expensive
-- Aura observation is acquired exclusively for an explicit scan and released
-- immediately when the scan completes/cancels. Closing the page therefore
-- leaves no high-frequency observation running.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local Runtime = S.FeatureRuntime
local F = S.Features and S.Features.RaidReadiness or nil
if type(Runtime) ~= "table" or type(F) ~= "table" or type(F.Authority) ~= "table" then return end

F.Id = "combat_raid_readiness"
F.ApiDependencies = { "TEAM" }
F.enabled = false
F.consumers = F.consumers or {}
F.consumerCount = 0
F.rosterToken = "raid_readiness:roster"
F.rosterHeld = false
F.auraToken = "raid_readiness:aura"
F.auraHeld = false

function F:Initialize()
    return self:EnsureStoreLoaded()
end

function F:AcquireAuraLease(reason)
    if self.auraHeld == true then return true end
    local aura = S.Services and S.Services.AuraObservationV3 or nil
    if type(aura) ~= "table" or type(aura.AcquireConsumer) ~= "function" then return false, "共享增益观察服务不可用" end
    local ok, err = aura:AcquireConsumer(self.auraToken, { purpose = tostring(reason or "raid_readiness") })
    if ok ~= true then return false, err end
    self.auraHeld = true
    return true
end

function F:ReleaseAuraLease(reason)
    if self.auraHeld ~= true then return true end
    local aura = S.Services and S.Services.AuraObservationV3 or nil
    if type(aura) ~= "table" or type(aura.ReleaseConsumer) ~= "function" then return false, "共享增益观察释放不可用" end
    local ok, err = aura:ReleaseConsumer(self.auraToken)
    if ok ~= true then return false, err end
    self.auraHeld = false
    return true
end

function F:ReconcileDemand(before, after)
    local beforeCount = tonumber(before and before.count) or 0
    local afterCount = tonumber(after and after.count) or 0
    if beforeCount == 0 and afterCount > 0 then
        local roster = S.Services and S.Services.TeamRosterV3 or nil
        if type(roster) ~= "table" or type(roster.AcquireConsumer) ~= "function" then return false, "团队名单服务不可用" end
        local ok, err = roster:AcquireConsumer(self.rosterToken, { purpose = "raid_readiness" })
        if ok ~= true then return false, err end
        self.rosterHeld = true
    elseif beforeCount > 0 and afterCount == 0 then
        self.Authority:CancelScan("consumer_release")
        local auraOk, auraErr = self:ReleaseAuraLease("consumer_release")
        if auraOk ~= true then return false, auraErr end
        if self.rosterHeld == true then
            local roster = S.Services and S.Services.TeamRosterV3 or nil
            if type(roster) ~= "table" or type(roster.ReleaseConsumer) ~= "function" then return false, "团队名单释放不可用" end
            local ok, err = roster:ReleaseConsumer(self.rosterToken)
            if ok ~= true then return false, err end
            self.rosterHeld = false
        end
    end
    return true
end

if S.Demand == nil or type(S.Demand.Create) ~= "function" then error("Demand unavailable for RaidReadiness") end
local demand, demandErr = S.Demand:Create({
    id = "feature:" .. F.Id,
    owner = F,
    projectionOwner = F,
    projectionConsumersField = "consumers",
    projectionCountField = "consumerCount",
    reconcile = function(_, before, after) return F:ReconcileDemand(before, after) end,
    quiesce = function(_, reason, cause) return F:QuiesceDemand(reason, cause) end,
})
if demand == nil then error(demandErr) end
F.Demand = demand

function F:AcquireConsumer(token)
    if self.enabled ~= true then return false, "团队战备检查未启用" end
    return self.Demand:Acquire(token, {}, "raid_readiness_consumer")
end
function F:ReleaseConsumer(token) return self.Demand:Release(token, "raid_readiness_consumer") end

function F:QuiesceDemand(reason, cause)
    local ok = self.Authority:CancelScan(reason or "runtime_quiesce") == true
    if self.auraHeld == true then
        local released = self:ReleaseAuraLease(reason or "runtime_quiesce")
        if released ~= true then ok = false end
    end
    if self.rosterHeld == true then
        local roster = S.Services and S.Services.TeamRosterV3 or nil
        if type(roster) ~= "table" or type(roster.ReleaseConsumer) ~= "function" then
            ok = false
        else
            local released = roster:ReleaseConsumer(self.rosterToken)
            if released ~= true then ok = false else self.rosterHeld = false end
        end
    end
    self.Authority:ResetTransient(reason or "runtime_quiesce")
    return ok
end

function F:Enable(reason)
    if self.enabled == true then return true end
    self.enabled = true
    return true
end

function F:Disable(reason)
    if self.enabled ~= true then return true end
    local cleared, clearErr = self.Demand:Clear(reason or "feature_disable")
    if cleared ~= true then return false, clearErr end
    self.Authority:CancelScan("feature_disable")
    self:ReleaseAuraLease("feature_disable")
    self.enabled = false
    return true
end

function F:RunScan(reason)
    if self.enabled ~= true then return false, "团队战备检查未启用" end
    if self.consumerCount <= 0 then return false, "团队战备检查当前没有活动页面" end
    return self.Authority:StartScan(reason or "manual")
end

-- Public Projection/Commands boundary for Active V3. The Page never keeps a
-- reference to the readiness Authority or releases its temporary Aura lease
-- independently of this command.
function F:GetRows(showOnlyIssues)
    return self.Authority:GetRows(showOnlyIssues == true)
end

function F:GetRow(key)
    return self.Authority:GetRow(key)
end

function F:GetSummary()
    return self.Authority:GetSummary()
end

function F:GetSettingsProjection()
    local settings = S.Utils.DeepCopy(self:GetSettings() or {})
    settings.maxRequiredAuras = tonumber(self.MaxRequiredAuras) or 24
    return settings
end

function F:CancelScan(reason)
    local ok, err = self.Authority:CancelScan(reason or "presentation_cancel")
    local releaseOk, releaseErr = self:ReleaseAuraLease(reason or "presentation_cancel")
    if releaseOk ~= true then return false, releaseErr end
    return ok, err
end

function F:GetHealth()
    local roster = S.Services and S.Services.TeamRosterV3 or nil
    local aura = S.Services and S.Services.AuraObservationV3 or nil
    local r = type(roster) == "table" and type(roster.GetHealth) == "function" and roster:GetHealth() or nil
    local a = type(aura) == "table" and type(aura.GetHealth) == "function" and aura:GetHealth() or nil
    local h = self.Authority:GetHealth()
    h.ok = self.enabled == true
    h.consumers = self.consumerCount
    h.rosterHeld = self.rosterHeld == true
    h.auraHeld = self.auraHeld == true
    h.rosterMembers = type(r) == "table" and tonumber(r.members) or 0
    h.auraConsumers = type(a) == "table" and tonumber(a.consumers) or 0
    return h
end

F.Commands = F.Commands or {}
function F.Commands:ApplySettingFromBinding(key, value) return F:ApplySettingFromBinding(key, value) end
function F.Commands:MarkStoreDirty(delayMs, reason) return F:MarkStoreDirty(delayMs, reason) end
function F.Commands:RunScan(reason) return F:RunScan(reason or "raid_readiness_command") end
function F.Commands:CancelScan(reason) return F:CancelScan(reason or "raid_readiness_command") end

local ok, err = Runtime:RegisterImplementation(F.Id, F)
if ok ~= true then error(err) end
