-- Replicated Suite · 刷新合并与防抖
-- 作者：Replicated
-- QQ群：1104129461
-- 用共享 Scheduler 合并事件刷新；以 owner+稳定 key 识别请求，不以每次新建的闭包识别。
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite

S.RefreshCoordinator = {
    version = 1,
    byOwner = {},
    sequence = 0,
    requested = 0,
    coalesced = 0,
    executed = 0,
    cancelled = 0,
    failed = 0,
    -- 最大合并窗口防止持续事件饿死刷新；仍只使用共享 Scheduler。
    -- 此处只拥有 owner+key 的刷新调度权，不拥有 Quest/Instance 事实或窗口可见性。
    boundedDebounceContractVersion = 1,
    reusedSchedules = 0,
}
local R = S.RefreshCoordinator
local NIL_OWNER = {}
local MIN_DELAY_MS = 50
local DEFAULT_MAX_WAIT_MS = 1000

-- 非法 delay/maxWait 不得形成 NaN/无限截止时间；正常有限延迟保持原契约。
local function Finite(value, fallback)
    value = tonumber(value)
    if value == nil or value ~= value or value == math.huge or value == -math.huge then return fallback end
    return value
end

local function OwnerKey(owner) return owner ~= nil and owner or NIL_OWNER end

local function Bucket(self, owner, create)
    local key = OwnerKey(owner)
    local bucket = self.byOwner[key]
    if bucket == nil and create == true then bucket = {}; self.byOwner[key] = bucket end
    return bucket, key
end

local function Count(tbl)
    local count = 0
    for _, bucket in pairs(type(tbl) == "table" and tbl or {}) do
        for _ in pairs(bucket) do count = count + 1 end
    end
    return count
end

local function RemoveState(self, state)
    -- 返回是否仍拥有该注册实例；运输层迟到回调不能只凭 owner+key 重用执行权。
    -- 先消费本次状态再回调，允许回调创建同 key 后继状态且不被旧清理删除。
    if state == nil then return false end
    local bucket, ownerKey = Bucket(self, state.owner, false)
    if bucket ~= nil and bucket[state.key] == state then
        bucket[state.key] = nil
        if next(bucket) == nil then self.byOwner[ownerKey] = nil end
        return true
    end
    return false
end

local function Execute(self, state, latestReason)
    self.executed = self.executed + 1
    local ok, result, err = xpcall(function()
        return state.callback(state.reasons, latestReason)
    end, S.SafeTraceback)
    if ok ~= true or result == false then
        self.failed = (tonumber(self.failed) or 0) + 1
        local message = ok == true and tostring(err or "refresh callback returned false") or tostring(result or "refresh callback failed")
        if S.DiagnosticsManager ~= nil and type(S.DiagnosticsManager.Record) == "function" then
            S.DiagnosticsManager:Record("warning", "refresh_coordinator", tostring(state.key) .. " 刷新回调失败: " .. message)
        end
        return false, message
    end
    return true, result
end

function R:Request(spec)
    spec = type(spec) == "table" and spec or {}
    local key = tostring(spec.key or "")
    if key == "" or type(spec.callback) ~= "function" then return false, "refresh key/callback required" end
    local owner = spec.owner
    local delayMs = math.max(MIN_DELAY_MS, Finite(spec.delayMs, 200))
    local now = Finite(S.NowMs and S.NowMs() or 0, 0)
    local bucket = Bucket(self, owner, true)
    local state = bucket[key]
    self.requested = self.requested + 1

    if state == nil then
        self.sequence = self.sequence + 1
        state = {
            key = key,
            owner = owner,
            taskName = "refresh_coordinator_" .. tostring(self.sequence),
            reasons = {},
            callback = spec.callback,
            moduleId = tostring(spec.moduleId or key),
            priority = tostring(spec.priority or "P2"),
            cost = math.max(1, math.floor(Finite(spec.cost, 1))),
            generation = S.Generation,
            -- 首次请求固定 deadline；maxWait 至少容纳首次 delay，默认 1s 防止持续事件无限推迟。
            -- 实际执行仍受帧间隔、预算和客户端暂停影响。
            deadlineAtMs = now + math.max(delayMs, Finite(spec.maxWaitMs, DEFAULT_MAX_WAIT_MS)),
            scheduledAtMs = nil,
        }
        bucket[key] = state
    else
        self.coalesced = self.coalesced + 1
        state.callback = spec.callback
        if spec.moduleId ~= nil then state.moduleId = tostring(spec.moduleId) end
        if spec.priority ~= nil then state.priority = tostring(spec.priority) end
        if spec.cost ~= nil then state.cost = math.max(1, math.floor(Finite(spec.cost, 1))) end
    end

    local reason = tostring(spec.reason or "request")
    state.reasons[reason] = true
    -- 保留定时任务时仍必须读取最新 reason/callback，禁止闭包冻结最初请求。
    state.latestReason = reason

    local scheduler = S.Scheduler
    if scheduler == nil or type(scheduler.AddOneShot) ~= "function" then
        RemoveState(self, state)
        return Execute(self, state, reason)
    end

    local targetAtMs = math.min(now + delayMs, state.deadlineAtMs)
    -- deadline 到期后保留已有任务；反复重设 50ms 会让 16ms 事件流饿死刷新并清掉 deferCount。
    -- 先确认任务未被 RemoveOwner 移除；旧 Scheduler 无查询能力时仍重排。
    if state.scheduledAtMs == targetAtMs and type(scheduler.GetTaskState) == "function"
        and scheduler:GetTaskState(state.taskName).registered == true then
        if spec.priority ~= nil and type(scheduler.SetPriority) == "function" then scheduler:SetPriority(state.taskName, state.priority) end
        if spec.cost ~= nil and type(scheduler.SetCost) == "function" then scheduler:SetCost(state.taskName, state.cost) end
        if spec.moduleId ~= nil and type(scheduler.SetTaskModule) == "function" then scheduler:SetTaskModule(state.taskName, state.moduleId, true) end
        self.reusedSchedules = self.reusedSchedules + 1
        return true
    end
    scheduler:RemoveTask(state.taskName)
    local added = scheduler:AddOneShot(state.taskName, math.max(MIN_DELAY_MS, targetAtMs - now), function()
        if tonumber(state.generation) ~= tonumber(S.Generation) then RemoveState(R, state); return false end
        if RemoveState(R, state) ~= true then return false end
        local executed = Execute(R, state, state.latestReason)
        return executed
    end, owner, state.priority, state.cost)
    if added ~= true then
        RemoveState(self, state)
        return Execute(self, state, reason)
    end
    state.scheduledAtMs = targetAtMs
    if type(scheduler.SetTaskModule) == "function" then scheduler:SetTaskModule(state.taskName, state.moduleId, true) end
    return true
end

function R:Cancel(owner, key)
    key = tostring(key or "")
    local bucket = Bucket(self, owner, false)
    local state = bucket and bucket[key] or nil
    if state == nil then return false end
    if S.Scheduler ~= nil then S.Scheduler:RemoveTask(state.taskName) end
    RemoveState(self, state)
    self.cancelled = self.cancelled + 1
    return true
end

function R:CancelOwner(owner)
    local bucket = Bucket(self, owner, false)
    if bucket == nil then return 0 end
    local states = {}
    for _, state in pairs(bucket) do states[#states + 1] = state end
    for _, state in ipairs(states) do
        if S.Scheduler ~= nil then S.Scheduler:RemoveTask(state.taskName) end
        RemoveState(self, state)
    end
    self.cancelled = self.cancelled + #states
    return #states
end

function R:ClearAll()
    local states = {}
    for _, bucket in pairs(self.byOwner) do for _, state in pairs(bucket) do states[#states + 1] = state end end
    for _, state in ipairs(states) do
        if S.Scheduler ~= nil then S.Scheduler:RemoveTask(state.taskName) end
        RemoveState(self, state)
    end
    self.cancelled = self.cancelled + #states
    return #states
end

function R:Describe()
    return {
        version = self.version,
        pending = Count(self.byOwner),
        requested = self.requested,
        coalesced = self.coalesced,
        executed = self.executed,
        cancelled = self.cancelled,
        failed = self.failed,
        boundedDebounceContractVersion = self.boundedDebounceContractVersion,
        reusedSchedules = self.reusedSchedules,
    }
end
