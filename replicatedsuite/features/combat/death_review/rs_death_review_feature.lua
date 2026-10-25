-- Replicated Suite · 死亡复盘功能入口
-- 作者：Replicated
-- QQ群：1104129461
-- 独立低成本 CombatEventBus 消费端。Feature Enabled 控制后台记录生命周期；HUD/页面可见性不能启动 DPS 或 scope=all 战斗传输。
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local Runtime = S.FeatureRuntime
local F = S.Features and S.Features.DeathReview or nil
if type(Runtime) ~= "table" or type(F) ~= "table" then return end

F.Id = "combat_death_review"
F.enabled = F.enabled == true
F.consumers = {}
F.consumerCount = 0
F.busSubscribed = false
F.auraConsumerHeld = false
F.auraToken = "feature:combat_death_review:aura"

local function Bus() return S.Services and S.Services.CombatEventBusV3 or nil end
local function Aura() return S.Services and S.Services.AuraObservationV3 or nil end

function F:Initialize()
    local ok, err = self:EnsureStoreLoaded()
    if ok ~= true then return false, err end
    if type(self.Authority) ~= "table" then return false, "death review authority unavailable" end
    if type(Bus()) ~= "table" then return false, "combat event bus unavailable" end
    return true
end

function F:_AcquireAuraIfNeeded()
    if self:GetSettings().showDebuffs ~= true then return true end
    if self.auraConsumerHeld == true then return true end
    local aura = Aura()
    if type(aura) ~= "table" or type(aura.AcquireConsumer) ~= "function" then return false, "aura observation unavailable" end
    local ok, err = aura:AcquireConsumer(self.auraToken, { purpose = "death_review" })
    if ok ~= true then return false, err end
    self.auraConsumerHeld = true
    -- 只在功能启用且状态采集开关打开时持有事件；扫描仍交统一调度合并。
    if S.Events and type(S.Events.SubscribeOptional) == "function" then
        for _, event in ipairs({ "BUFF_UPDATE", "DEBUFF_UPDATE" }) do
            S.Events:SubscribeOptional(event, self, function()
                if F.enabled and F.auraConsumerHeld then return F.Authority:RequestDebuffSample(nil, true) end
                return true
            end)
        end
    end
    return true
end

function F:_ReleaseAura()
    if self.auraConsumerHeld ~= true then return true end
    local aura = Aura()
    if type(aura) ~= "table" or type(aura.ReleaseConsumer) ~= "function" then return false, "aura release unavailable" end
    local ok, err = aura:ReleaseConsumer(self.auraToken)
    if ok ~= true then return false, err end
    self.auraConsumerHeld = false
    if S.Events and type(S.Events.UnsubscribeOwner) == "function" then S.Events:UnsubscribeOwner(self) end
    self.Authority.debuffSampleScheduled = false
    if S.Scheduler and type(S.Scheduler.RemoveTask) == "function" then S.Scheduler:RemoveTask(self.Authority.debuffSampleTask) end
    return true
end

function F:_SubscribeCombat()
    if self.busSubscribed == true then return true end
    local bus = Bus()
    if type(bus) ~= "table" or type(bus.Subscribe) ~= "function" then return false, "combat event bus unavailable" end
    local ok, err = bus:Subscribe(self, function(_, fact) F.Authority:OnCombatFact(fact) end, { scope = "self" })
    if ok ~= true then return false, err end
    self.busSubscribed = true
    return true
end

function F:_UnsubscribeCombat()
    if self.busSubscribed ~= true then return true end
    local bus = Bus()
    if type(bus) ~= "table" or type(bus.Unsubscribe) ~= "function" then return false, "combat event bus release unavailable" end
    local ok, err = bus:Unsubscribe(self)
    if ok ~= true then return false, err end
    self.busSubscribed = false
    return true
end

function F:ReconcileDemand(before, after, context)
    local beforeCount = tonumber(before and before.count) or 0
    local afterCount = tonumber(after and after.count) or 0
    if beforeCount <= 0 and afterCount > 0 then
        local busOk, busErr = self:_SubscribeCombat()
        if busOk ~= true then return false, busErr end
        local auraOk, auraErr = self:_AcquireAuraIfNeeded()
        if auraOk ~= true then return false, auraErr end
        if not (type(context) == "table" and context.rollback == true) then self.Authority:ResetTransient() end
        if self.auraConsumerHeld then self.Authority:RequestDebuffSample() end
    elseif beforeCount > 0 and afterCount <= 0 then
        local busOk, busErr = self:_UnsubscribeCombat()
        if busOk ~= true then return false, busErr end
        local auraOk, auraErr = self:_ReleaseAura()
        if auraOk ~= true then return false, auraErr end
        if not (type(context) == "table" and context.rollback == true) then self.Authority:ResetTransient() end
    end
    return true
end

if S.Demand == nil or type(S.Demand.Create) ~= "function" then error("Demand unavailable for DeathReview") end
local lease, leaseErr = S.Demand:Create({
    id = "feature:" .. F.Id,
    owner = F,
    projectionOwner = F,
    projectionConsumersField = "consumers",
    projectionCountField = "consumerCount",
    reconcile = function(_, before, after, context) return F:ReconcileDemand(before, after, context) end,
    quiesce = function()
        local ok = true
        if F.busSubscribed == true then local released = F:_UnsubscribeCombat(); if released ~= true then ok = false end end
        if F.auraConsumerHeld == true then local released = F:_ReleaseAura(); if released ~= true then ok = false end end
        F.busSubscribed, F.auraConsumerHeld = false, false
        if type(F.Authority) == "table" then F.Authority:ResetTransient() end
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
    if S.Events ~= nil and type(S.Events.Publish) == "function" then S.Events:Publish("v3.death_review.lifecycle", "disabled", tostring(reason or "feature_disable")) end
    return true
end

function F:SetSettingValue(key, value)
    local settings = self:GetSettings()
    local previous = settings[key]
    local oldShowDebuffs = settings.showDebuffs == true
    local ok, err = self:ApplySettingRaw(key, value)
    if ok ~= true then return false, err end
    if key == "showDebuffs" and self.enabled == true then
        local target = self:GetSettings().showDebuffs == true
        local resourceOk, resourceErr
        if target then resourceOk, resourceErr = self:_AcquireAuraIfNeeded() else resourceOk, resourceErr = self:_ReleaseAura() end
        if resourceOk ~= true then
            self:ApplySettingRaw(key, previous)
            if oldShowDebuffs then self:_AcquireAuraIfNeeded() else self:_ReleaseAura() end
            return false, resourceErr
        end
        if target ~= true then self.Authority.debuffSamples = {} else self.Authority:RequestDebuffSample() end
    end
    if S.Events ~= nil and type(S.Events.Publish) == "function" then S.Events:Publish("v3.death_review.settings", tostring(key)) end
    return true
end

-- 持久化 Binding 使用这些仅 Domain 设置器；dirty/save 归 Binding。
function F:ApplyAutoShow(value) return self:SetSettingValue("autoShow", value) end
function F:ApplyWindowMs(value) return self:SetSettingValue("windowMs", value) end
function F:SetMaxHistory(value)
    local ok, err = self:SetMaxHistoryPersistent(value)
    if ok == true and S.Events ~= nil and type(S.Events.Publish) == "function" then S.Events:Publish("v3.death_review.settings", "maxHistory") end
    return ok, err
end
function F:ApplyMinDamage(value) return self:SetSettingValue("minDamage", value) end
function F:ApplyShowDebuffs(value) return self:SetSettingValue("showDebuffs", value) end

function F:DeleteRecord(serial) return self.Authority:DeleteRecord(serial) end
function F:ClearHistory() return self.Authority:ClearHistory() end
function F:Refresh(reason) return true end

-- 共享 RSUI 窗口壳使用的窄 Presentation 读模型。
function F:GetWidgetWindowState()
    local value = self.State and self.State.widgetWindow or nil
    local floating = S.RSUI and S.RSUI.FloatingSurface or nil
    local policy = self.WidgetWindowSizePolicy or { defaultWidth = 470, defaultHeight = 330, minWidth = 1, minHeight = 1,
        defaultOverallOpacity = 0.96, defaultBackgroundOpacity = 1.0, defaultTextOpacity = 1.0 }
    if type(floating) == "table" and type(floating.NormalizeState) == "function" then
        return S.Utils.DeepCopy(floating:NormalizeState(value, policy))
    end
    return S.Utils.DeepCopy(value)
end

function F:SetWidgetWindowState(value, reason)
    if type(value) ~= "table" or type(self.State) ~= "table" then return false, "death review widget window state unavailable" end
    local floating = S.RSUI and S.RSUI.FloatingSurface or nil
    local policy = self.WidgetWindowSizePolicy or { defaultWidth = 470, defaultHeight = 330, minWidth = 1, minHeight = 1,
        defaultOverallOpacity = 0.96, defaultBackgroundOpacity = 1.0, defaultTextOpacity = 1.0 }
    self.State.widgetWindow = type(floating) == "table" and type(floating.NormalizeState) == "function"
        and floating:NormalizeState(value, policy) or S.Utils.DeepCopy(value)
    return true
end

F.Commands = F.Commands or {}
function F.Commands:SetEnabled(enabled, reason)
    return S.FeatureRuntime:SetPreferredEnabled(F.Id, enabled == true, reason or "death_review_command")
end
function F.Commands:ApplyAutoShow(value) return F:ApplyAutoShow(value) end
function F.Commands:ApplyShowDebuffs(value) return F:ApplyShowDebuffs(value) end
function F.Commands:ApplyWindowMs(value) return F:ApplyWindowMs(value) end
function F.Commands:ApplyMinDamage(value) return F:ApplyMinDamage(value) end
function F.Commands:SetMaxHistory(value) return F:SetMaxHistory(value) end
function F.Commands:MarkStoreDirty(delayMs, reason) return F:MarkStoreDirty(delayMs, reason) end
function F.Commands:DeleteRecord(serial) return F:DeleteRecord(serial) end
function F.Commands:ClearHistory() return F:ClearHistory() end
function F.Commands:SetWidgetWindowState(value, reason) return F:SetWidgetWindowState(value, reason) end

function F:GetProjection(request)
    request = type(request) == "table" and request or {}
    local runtime = S.FeatureRuntime and S.FeatureRuntime:GetSnapshot(self.Id) or nil
    local historyLimit = math.max(1, math.min(30, math.floor(tonumber(request.historyLimit) or 30)))
    local timelineLimit = math.max(1, math.min(96, math.floor(tonumber(request.timelineLimit) or 96)))
    local historyRows = self.Authority:GetHistoryRows(historyLimit)
    local timelineRows, record = self.Authority:GetTimelineRows(request.serial, timelineLimit)
    return {
        enabled = runtime ~= nil and runtime.enabled == true or false,
        settings = S.Utils.DeepCopy(self:GetSettings()),
        health = S.Utils.DeepCopy(self:GetHealth()),
        -- Authority每次创建列表，record由LoadRecord/volatile分支隔离；只转交本次独立投影，避免三遍复制记录。
        historyRows = historyRows,
        timelineRows = timelineRows,
        record = record,
    }
end

function F:GetSettingsProjection()
    return S.Utils.DeepCopy(self:GetSettings() or {})
end

function F:GetHealth()
    local bus = Bus()
    local busHealth = type(bus) == "table" and type(bus.GetHealth) == "function" and bus:GetHealth() or nil
    local domain = self.Authority:GetHealth()
    return {
        ok = self.enabled == true,
        consumers = self.consumerCount,
        busSubscribed = self.busSubscribed == true,
        busScope = self.busSubscribed == true and "self" or "none",
        busGlobalActive = type(busHealth) == "table" and busHealth.globalActive == true or false,
        auraConsumer = self.auraConsumerHeld == true,
        history = domain.history,
        incoming = domain.incoming,
        debuffSamples = domain.debuffSamples,
        deaths = domain.deaths,
        pendingDeath = domain.pendingDeath == true,
        deferredFinalizes = tonumber(domain.deferredFinalizes) or 0,
        deferredFinalizeFailures = tonumber(domain.deferredFinalizeFailures) or 0,
        debuffDeferred = tonumber(domain.debuffDeferred) or 0,
        debuffDeferFailures = tonumber(domain.debuffDeferFailures) or 0,
        duplicateDeathNotices = tonumber(domain.duplicateDeathNotices) or 0,
        persistenceFailures = tonumber(domain.persistenceFailures) or 0,
        revision = domain.revision,
    }
end

local ok, err = Runtime:RegisterImplementation(F.Id, F)
if ok ~= true then error(err) end

-- 向 Core 注册实时诊断 provider，每次现读，不缓存 Feature 状态。
local providers = S.FeatureHealthProviders
if type(providers) == "table" then
    providers:Register("death_review_health", function()
        local feature = S.Features and S.Features.DeathReview or nil
        return type(feature) == "table" and type(feature.GetHealth) == "function" and feature:GetHealth() or nil
    end)
end
