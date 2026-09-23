------------------------------------------------------------------------
-- Replicated Suite - Refresh Coordinator
--
-- Event-driven bounded sliding debounce/coalescing on top of the Suite's single
-- Scheduler.  There is no additional Tick/OnUpdate authority.  Identity is
-- owner + stable key; callback closure identity is deliberately NOT part of
-- the conflict contract because callers commonly create a fresh closure for
-- each event request.
------------------------------------------------------------------------
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
    -- 维护（foundation-lifecycle-1）：最大合并窗口防止持续事件饿死刷新；仍只使用共享 Scheduler。
    -- 此处只拥有 owner+key 的刷新调度权，不拥有 Quest/Instance 事实或窗口可见性。
    boundedDebounceContractVersion = 1,
    reusedSchedules = 0,
}
local R = S.RefreshCoordinator
local NIL_OWNER = {}
local MIN_DELAY_MS = 50
local DEFAULT_MAX_WAIT_MS = 1000

-- 维护：非法 delay/maxWait 不得形成 NaN/无限截止时间；正常有限延迟保持原契约。
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
    -- 维护：返回是否仍拥有该注册实例；运输层迟到回调不能只凭 owner+key 重用执行权。
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
            -- 维护：首次请求固定 deadline，后续事件只能合并，不能无限向后推。
            -- maxWait 至少容纳首次明确 delay；默认 1s 是防饥饿合并窗口，不是真机响应 SLA。
            -- 仍受 Scheduler 帧间隔/预算/客户端暂停影响，不在事件热路径直接刷新业务。
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
    -- 维护：保留定时任务时仍必须读取最新 reason/callback，禁止闭包冻结最初请求。
    state.latestReason = reason

    local scheduler = S.Scheduler
    if scheduler == nil or type(scheduler.AddOneShot) ~= "function" then
        RemoveState(self, state)
        return Execute(self, state, reason)
    end

    local targetAtMs = math.min(now + delayMs, state.deadlineAtMs)
    -- 维护：达到同一 deadline 后保留已有任务，而不是反复重设 50ms 最小延迟。
    -- 否则 16ms 事件流仍会饿死已到期任务，并反复抹掉预算 deferCount；也会无谓分配闭包。
    -- 只读查询确认任务未被外部 RemoveOwner 移除，缺查询能力时保留旧的重排兼容路径。
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
        -- 维护：只读性能/契约证据；Describe 不刷新业务、不启动 Consumer、不修改 deadline。
        boundedDebounceContractVersion = self.boundedDebounceContractVersion,
        reusedSchedules = self.reusedSchedules,
    }
end
