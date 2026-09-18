------------------------------------------------------------------------
-- Replicated Suite V3 - Casting Observation Domain
--
-- Shared read-only casting facts for player/target/targettarget/watchtarget.
-- The four-unit scope set is the proven wbdebuff fact model
-- (jumpblackdragon.lua:115-129 checks target -> targettarget -> player ->
-- watchtarget in that order); Boss mechanic rules depend on all of them
-- because losing the target mid-mechanic must not kill the cast fact.
-- Consumers declare which scopes they need; the service owns the only
-- UnitCastingInfo polling task and stops it when the last lease is released.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
S.Services = S.Services or {}

local C = {
    Id = "v3.casting_observation",
    version = 3, -- 中文维护：新增可用性与会话施法序号；不是服务器施法/实体 ID，不用于归属推断。
    taskName = "v3_casting_observation_refresh",
    snapshots = { player = nil, target = nil, targettarget = nil, watchtarget = nil },
    revision = 0,
    nativeReads = 0,
    readFailures = 0,
    intervalMs = nil,
    scopes = { player = false, target = false, targettarget = false, watchtarget = false },
    -- 中文维护：读失败不同于施法结束。Service 独占覆盖状态；旧快照仅用于下一次成功读取的边沿比较，
    -- Consumer 经 Get/GetCoverage 消费，不得把失败期间的缓存当作仍在施法的事实。
    coverage = {}, castSequence = 0, taskGeneration = 0,
}
C.presentationBoundary = "service_only"
C.DemandScopedPollingContractVersion = 1
S.Services.CastingObservationV3 = C

local CAST_SCOPES = { "player", "target", "targettarget", "watchtarget" }
local CAST_SCOPE_SET = { player = true, target = true, targettarget = true, watchtarget = true }

local function Clamp(value, minimum, maximum)
    value = math.floor(tonumber(value) or minimum)
    if value < minimum then return minimum end
    if value > maximum then return maximum end
    return value
end

local function CopyCast(value)
    if type(value) ~= "table" then return nil end
    return {
        casting = value.casting == true,
        spellName = tostring(value.spellName or ""),
        currMs = math.max(0, math.floor(tonumber(value.currMs) or 0)),
        totalMs = math.max(1, math.floor(tonumber(value.totalMs) or 1)),
        remainingMs = math.max(0, math.floor(tonumber(value.remainingMs) or 0)),
        at = math.max(0, tonumber(value.at) or 0),
        revision = math.max(0, math.floor(tonumber(value.revision) or 0)),
        serial = tonumber(value.serial) or 0, -- 中文维护：进度回退/新读条时递增，补足连续同名读条无空帧的通知边沿。
    }
end

local function SameCast(a, b)
    if a == nil and b == nil then return true end
    if type(a) ~= "table" or type(b) ~= "table" then return false end
    return a.serial == b.serial and a.spellName == b.spellName and a.totalMs == b.totalMs
        and math.abs((tonumber(a.currMs) or 0) - (tonumber(b.currMs) or 0)) < 40
end

local function NowMs() return math.max(0, tonumber(S.NowMs and S.NowMs()) or 0) end

-- 中文维护：Native 返回只在本边界解析；未知/非法计时不能按 0/1ms 补齐，
-- 否则下游会把坏数据当真实首领机制。已有无读条 nil/空名称语义保留，不增加 API 调用。
function C:_Read(scope)
    local function Failed(reason)
        self.readFailures = self.readFailures + 1
        return nil, false, tostring(reason or "casting_unavailable")
    end
    if S.Api == nil or type(S.Api.CallCapability) ~= "function" then return Failed("api_unavailable") end
    local unitApi = rawget(_G, "X2Unit")
    if unitApi == nil then return Failed("unit_api_unavailable") end
    self.nativeReads = self.nativeReads + 1
    local ok, info, err = S.Api:CallCapability("X2Unit:UnitCastingInfo", unitApi, "UnitCastingInfo", scope)
    if ok ~= true then return Failed(err) end
    if info == nil then return nil, true end
    if type(info) ~= "table" then return Failed("invalid_cast_shape") end
    if info.spellName == nil or tostring(info.spellName) == "" then return nil, true end
    local currMs, totalMs = tonumber(info.currCastingTime), tonumber(info.castingTime)
    if currMs == nil or totalMs == nil or currMs ~= currMs or totalMs ~= totalMs
        or currMs == math.huge or totalMs == math.huge or currMs < 0 or totalMs <= 0 then
        return Failed("invalid_cast_timing")
    end
    if currMs >= totalMs then return nil, true end
    return { casting = true, spellName = tostring(info.spellName), currMs = currMs, totalMs = totalMs,
        remainingMs = totalMs - currMs, at = NowMs() }, true
end

function C:Refresh(reason)
    if self.Demand == nil or (tonumber(self.Demand.count) or 0) <= 0 then return true end
    local changed = false
    for _, scope in ipairs(CAST_SCOPES) do
        if self.scopes[scope] == true then
            local nextCast, available, err = self:_Read(scope)
            local oldCast, oldCoverage = self.snapshots[scope], self.coverage[scope]
            local scopeChanged = oldCoverage == nil or oldCoverage.available ~= available or oldCoverage.error ~= err
            self.coverage[scope] = { available = available == true, error = err, at = NowMs() }
            if available == true then
                -- 中文维护：序号只描述本 scope 的本地观察段；读失败不清空旧比较基线，
                -- 真正空读条、名称/总时长变化或进度回退才产生新段。绝不能把序号保存成服务器身份。
                if nextCast ~= nil then
                    if oldCast == nil or oldCast.spellName ~= nextCast.spellName
                        or oldCast.totalMs ~= nextCast.totalMs or nextCast.currMs < oldCast.currMs then
                        self.castSequence = self.castSequence + 1
                        nextCast.serial = self.castSequence
                    else nextCast.serial = oldCast.serial end
                end
                scopeChanged = scopeChanged or SameCast(oldCast, nextCast) ~= true
                self.snapshots[scope] = nextCast
            end
            if scopeChanged then
                self.revision = self.revision + 1
                changed = true
            end
            if available == true and nextCast ~= nil then
                nextCast.revision = scopeChanged and self.revision or (oldCast and oldCast.revision or self.revision)
            end
            if scopeChanged and S.Events ~= nil and type(S.Events.Publish) == "function" then
                S.Events:Publish("v3.casting.updated", scope, self.revision, tostring(reason or "refresh"))
            end
        else
            if self.snapshots[scope] ~= nil then changed = true end
            self.snapshots[scope], self.coverage[scope] = nil, nil
        end
    end
    return true, changed
end

function C:Get(scope)
    scope = tostring(scope or "")
    if CAST_SCOPE_SET[scope] ~= true or not self.coverage[scope] or self.coverage[scope].available ~= true then return nil end
    return CopyCast(self.snapshots[scope])
end

-- 中文维护：detached 覆盖投影供通知边沿判断“已结束/未知”；调用不读 Native，也不暴露可变快照。
function C:GetCoverage(scope)
    local value = self.coverage[tostring(scope or "")]
    return { available = value ~= nil and value.available == true, error = value and value.error or nil,
        at = value and value.at or nil }
end

function C:AcquireConsumer(token, options)
    if self.Demand == nil then return false, "casting demand unavailable" end
    return self.Demand:Acquire(token, options, "casting_consumer")
end

function C:ReleaseConsumer(token)
    if self.Demand == nil then return false, "casting demand unavailable" end
    if self.Demand:Has(token) ~= true then return true end
    return self.Demand:Release(token, "casting_consumer")
end

function C:_Desired(after)
    local scopes = { player = false, target = false, targettarget = false, watchtarget = false }
    local interval = 1000
    for _, options in pairs(type(after) == "table" and type(after.consumers) == "table" and after.consumers or {}) do
        if type(options) == "table" then
            if options.player == true then scopes.player = true end
            if options.target ~= false then scopes.target = true end
            if options.targettarget == true then scopes.targettarget = true end
            if options.watchtarget == true then scopes.watchtarget = true end
            interval = math.min(interval, Clamp(options.intervalMs, 50, 1000))
        end
    end
    return scopes, interval
end

function C:_StopTask()
    -- 中文维护：移除索引不保证已捕获闭包失效；每次停止推进代次，旧任务不得借新 Consumer 再次读取。
    self.taskGeneration = self.taskGeneration + 1
    if S.Scheduler ~= nil and type(S.Scheduler.RemoveTask) == "function" then S.Scheduler:RemoveTask(self.taskName) end
    self.intervalMs = nil
    return true
end

function C:_StartTask(scopes, interval)
    if S.Scheduler == nil or type(S.Scheduler.AddTask) ~= "function" then return false, "Casting Scheduler 不可用" end
    self:_StopTask()
    self.scopes = {
        player = scopes.player == true, target = scopes.target == true,
        targettarget = scopes.targettarget == true, watchtarget = scopes.watchtarget == true,
    }
    self.intervalMs = Clamp(interval, 50, 1000)
    local generation = self.taskGeneration
    local added = S.Scheduler:AddTask(self.taskName, self.intervalMs, function()
        if C.taskGeneration ~= generation or S.Services.CastingObservationV3 ~= C then return true end
        return C:Refresh("scheduled")
    end, false, self, "P2", 1)
    if added ~= true then self.intervalMs = nil; return false, "Casting 观察任务创建失败" end
    if type(S.Scheduler.SetTaskModule) == "function" then S.Scheduler:SetTaskModule(self.taskName, self.Id, false) end
    self:Refresh("lease_reconcile")
    return true
end

function C:GetHealth()
    return {
        ok = self.Demand ~= nil,
        consumers = self.Demand and self.Demand.count or 0,
        intervalMs = self.intervalMs,
        player = self.scopes.player == true,
        target = self.scopes.target == true,
        targettarget = self.scopes.targettarget == true,
        watchtarget = self.scopes.watchtarget == true,
        revision = self.revision,
        nativeReads = self.nativeReads,
        readFailures = self.readFailures,
    }
end

if S.Demand == nil or type(S.Demand.Create) ~= "function" then error("Demand unavailable for CastingObservationV3") end
local demand, demandErr = S.Demand:Create({
    id = C.Id,
    owner = C,
    projectionOwner = C,
    projectionConsumersField = "consumers",
    projectionCountField = "consumerCount",
    normalize = function(options)
        options = type(options) == "table" and options or {}
        local player = options.player == true
        local target = options.target ~= false
        -- 中文维护：焦点/目标的目标也是独立合法消费者；只在四个 scope 均未请求时沿用旧 target 默认值。
        if player ~= true and target ~= true and options.targettarget ~= true and options.watchtarget ~= true then target = true end
        return { player = player, target = target,
            targettarget = options.targettarget == true, watchtarget = options.watchtarget == true,
            intervalMs = Clamp(options.intervalMs, 50, 1000), purpose = tostring(options.purpose or "generic") }
    end,
    reconcile = function(_, before, after)
        local beforeCount = tonumber(before and before.count) or 0
        local afterCount = tonumber(after and after.count) or 0
        if afterCount <= 0 then
            C:_StopTask()
            C.scopes = { player = false, target = false, targettarget = false, watchtarget = false }
            C.snapshots = { player = nil, target = nil, targettarget = nil, watchtarget = nil }
            C.coverage = {} -- 中文维护：最后一个租约释放即丢弃覆盖事实，不向下一代消费者泄漏旧可用性。
            return true
        end
        local scopes, interval = C:_Desired(after)
        local needsRestart = beforeCount <= 0 or C.intervalMs ~= interval
            or C.scopes.player ~= scopes.player or C.scopes.target ~= scopes.target
            -- 中文维护：原实现漏比两个附加 scope，新增/释放它们不会更新 Native 轮询集合。
            or C.scopes.targettarget ~= scopes.targettarget or C.scopes.watchtarget ~= scopes.watchtarget
        if needsRestart then return C:_StartTask(scopes, interval) end
        return true
    end,
    quiesce = function()
        C:_StopTask()
        C.scopes = { player = false, target = false, targettarget = false, watchtarget = false }
        C.snapshots = { player = nil, target = nil, targettarget = nil, watchtarget = nil }
            C.coverage = {} -- 中文维护：最后一个租约释放即丢弃覆盖事实，不向下一代消费者泄漏旧可用性。
        return true
    end,
})
if demand == nil then error(demandErr) end
C.Demand = demand
