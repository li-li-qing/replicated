------------------------------------------------------------------------
-- Replicated Suite V3 - Random Shop lifecycle and settings
-- 维护（2026-09-12）：页面只拥有Consumer和输入草稿；Feature拥有用户偏好，Authority拥有读数。
-- 默认手动；可选自动读取只在已有Consumer时运行，不监听未经验证的商店事件、不刷新游戏商店。
-- 新增小型Account/Permanent设置Store；旧版本无此Store，空档按默认值加载，不改其它旧配置。
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local Runtime, P = S.FeatureRuntime, S.Persistence
S.Features = S.Features or {}
S.Features.RandomShop = S.Features.RandomShop or {}
local F = S.Features.RandomShop
if type(Runtime) ~= "table" or type(F.Authority) ~= "table" or type(P) ~= "table" then return end
F.Id, F.storeId = "tools_random_shop", "v3.random_shop"
F.ApiDependencies = { "X2Store:GetRandomShopStoreRefreshCount" }
F.UpdateTopic, F.ObservationContractVersion = "v3.random_shop.updated", 2
F.Patch = "random-shop-observer-1"
F.enabled, F.pollActive, F.pollEpoch = false, false, 0
F.settings = { autoRead = false, threshold = 0 }
local TASK = "v3_random_shop_observe"

local function Threshold(value)
    local n = (type(value) == "number" or type(value) == "string") and tonumber(value) or nil
    -- 维护：0关闭页面提示，1000000仅为本地表单预算上限，不声称游戏有这个额度。
    if n == nil or n ~= n or n < 0 or n > 1000000 or n ~= math.floor(n) then return nil end
    return n
end
local function Settings(value)
    value = type(value) == "table" and value or {}
    return { autoRead = value.autoRead == true, threshold = Threshold(value.threshold) or 0 }
end
local function Publish(reason)
    if S.Events and type(S.Events.Publish) == "function" then S.Events:Publish(F.UpdateTopic, F.Id, reason) end
end

if P:GetStore(F.storeId) == nil then
    local store, err = P:RegisterV3Store({ id = F.storeId, owner = "v3.random_shop", scope = P.Scope.Account,
        lifetime = P.Lifetime.Permanent, schemaVersion = 1, legacySchemaVersion = 0,
        key = P.V3KeyPrefix .. "v3_random_shop",
        budget = { maxDepth = 3, maxNodes = 32, maxStringBytes = 128, maxEntriesPerTable = 8 },
        default = function() return Settings(nil) end,
        get = function() return Settings(F.settings) end,
        apply = function(value) F.settings = Settings(value); return true end,
        migrate = function(value) return value end })
    if store == nil then error(err or "random shop store registration failed") end
end

function F:EnsureStoreLoaded()
    local store = P:GetStore(self.storeId)
    if store == nil or store.writeFenced == true then
        self.settingsError = store and store.writeFenceReason or "设置Store不可用"
        return false, self.settingsError
    end
    if self.storeLoaded == true and store.loaded == true then return true end
    local ok, _, err = P:LoadStore(self.storeId)
    if ok ~= true and ok ~= "empty" then self.settingsError = err or tostring(ok); return false, self.settingsError end
    self.storeLoaded, self.settingsError = true, nil
    return true
end
function F:Initialize() return self:EnsureStoreLoaded() end

function F:StopSampling()
    -- 维护：epoch同时防停用/重新启用和自动→手动→自动后的旧闭包；Generation再防插件重载。
    self.pollEpoch, self.pollActive = self.pollEpoch + 1, false
    if S.Scheduler and type(S.Scheduler.RemoveTask) == "function" then S.Scheduler:RemoveTask(TASK) end
end
function F:SyncSampling()
    local wanted = self.enabled == true and (self.consumerCount or 0) > 0 and self.settings.autoRead == true
    if not wanted then self:StopSampling(); self.lifecycleError = nil; return true end
    if self.pollActive then return true end
    if not S.Scheduler or type(S.Scheduler.AddTask) ~= "function" then
        self.lifecycleError = "观察调度器不可用"; return false, self.lifecycleError
    end
    local epoch, generation = self.pollEpoch, S.Generation
    local added = S.Scheduler:AddTask(TASK, 1000, function()
        if self.pollEpoch ~= epoch or S.Generation ~= generation or not self.pollActive then return end
        if not self.enabled or (self.consumerCount or 0) <= 0 or not self.settings.autoRead then return end
        return self:Refresh("random_shop_poll")
    end, false, self, "P3", 1)
    if added ~= true then self.lifecycleError = "计数观察任务创建失败"; return false, self.lifecycleError end
    self.pollActive, self.lifecycleError = true, nil
    if type(S.Scheduler.SetTaskModule) == "function" then S.Scheduler:SetTaskModule(TASK, self.Id, true) end
    return true
end
function F:StopObservation(reason)
    self:StopSampling(); self.Authority:Clear(reason); Publish(reason or "stopped")
    return true
end
function F:ReconcileDemand(_, before, after)
    if (after.count or 0) <= 0 then return self:StopObservation("random_shop_no_consumers") end
    local synced, err = self:SyncSampling(); if synced ~= true then return false, err end
    if (before.count or 0) <= 0 then
        self.Authority:Clear("random_shop_new_observation")
        return self:Refresh("random_shop_consumer_acquire")
    end
    return true
end
if S.Demand == nil or type(S.Demand.Create) ~= "function" then error("Demand unavailable for RandomShop") end
local demand, demandErr = S.Demand:Create({
    id = "feature:" .. F.Id, owner = F, projectionOwner = F,
    projectionConsumersField = "consumers", projectionCountField = "consumerCount",
    reconcile = function(lease, before, after) return F:ReconcileDemand(lease, before, after) end,
    quiesce = function() return F:StopObservation("random_shop_force_quiesce") end,
})
if demand == nil then error(demandErr) end
F.Demand = demand

function F:AcquireConsumer(token)
    if self.enabled ~= true then return false, "请先启用随机商店计数" end
    return self.Demand:Acquire(token, {}, "random_shop_consumer")
end
function F:ReleaseConsumer(token) return self.Demand:Release(token, "random_shop_consumer") end
function F:Enable()
    local ok, err = self:EnsureStoreLoaded(); if ok ~= true then return false, err end
    self.enabled = true; Publish("enabled"); return true
end
function F:Disable(reason)
    local ok, err = self.Demand:Clear(reason or "random_shop_feature_disable")
    if ok ~= true then return false, err end
    self.enabled = false
    return self:StopObservation(reason or "disabled")
end
function F:Refresh(reason)
    if self.enabled ~= true or (self.consumerCount or 0) <= 0 then return false, "请启用功能并打开计数页面后读取" end
    -- 维护：完成一次采样与取得有效值是两件事；getter失败是可展示的未知状态，不抛异常让轮询卡死。
    local ok, err = self.Authority:Refresh(reason); Publish(reason or "sample"); return ok, err
end
function F:GetProjection()
    local p = self.Authority:GetProjection()
    p.enabled, p.observing, p.polling = self.enabled, (self.consumerCount or 0) > 0, self.pollActive
    p.autoRead, p.threshold = self.settings.autoRead, self.settings.threshold
    p.reminderState = p.threshold == 0 and "off" or (not p.available and "unknown" or (p.refreshCount >= p.threshold and "reached" or "below"))
    p.lifecycleError, p.settingsError, p.patch = self.lifecycleError, self.settingsError, self.Patch
    return p
end
function F:GetHealth()
    local h = self.Authority:GetHealth()
    h.enabled, h.consumers, h.polling, h.patch = self.enabled, self.consumerCount, self.pollActive, self.Patch
    h.lifecycleError, h.settingsError = self.lifecycleError, self.settingsError
    return h
end
local function Commit(key, value)
    local loaded, loadErr = F:EnsureStoreLoaded(); if loaded ~= true then return false, loadErr end
    if F.settings[key] ~= value then
        -- 维护：沿用真实耐久事务/回读校验。失败先还原内存设置，不提前启停任务；物理写入是否恢复
        -- 由现有Persistence barrier负责，不能在页面假称磁盘已回滚。采样、历史、起点绝不写入Store。
        local ok, err = P:MutateStore(F.storeId, function() F.settings[key] = value; return true end,
            { durable = true, reason = "random_shop_settings" })
        if ok ~= true then return false, err end
    end
    local synced, err = F:SyncSampling(); Publish("settings")
    if synced ~= true then return false, "设置已保存，但观察未启动：" .. tostring(err) end
    return true
end
F.Commands = F.Commands or {}
function F.Commands:Refresh(reason) return F:Refresh(reason or "random_shop_command") end
function F.Commands:SetAutoRead(value)
    if type(value) ~= "boolean" then return false, "自动读取开关必须是布尔值" end
    return Commit("autoRead", value)
end
function F.Commands:SetThreshold(value)
    local n = Threshold(value)
    if n == nil then return false, "个人阈值需为0-1000000的整数；0关闭提示" end
    return Commit("threshold", n)
end
function F.Commands:ResetBaseline()
    if not F.enabled or (F.consumerCount or 0) <= 0 then return false, "请先启用并打开计数页面" end
    local ok, err = F.Authority:ResetBaseline(); if ok then Publish("baseline_reset") end; return ok, err
end
local ok, err = Runtime:RegisterImplementation(F.Id, F)
if ok ~= true then error(err) end
