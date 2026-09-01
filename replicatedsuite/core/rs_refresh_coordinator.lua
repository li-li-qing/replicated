------------------------------------------------------------------------
-- Replicated Suite - Refresh Coordinator
--
-- Event-driven sliding debounce/coalescing on top of the Suite's single
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
}
local R = S.RefreshCoordinator
local NIL_OWNER = {}

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
    if state == nil then return end
    local bucket, ownerKey = Bucket(self, state.owner, false)
    if bucket ~= nil and bucket[state.key] == state then
        bucket[state.key] = nil
        if next(bucket) == nil then self.byOwner[ownerKey] = nil end
    end
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
            cost = math.max(1, math.floor(tonumber(spec.cost) or 1)),
            generation = S.Generation,
        }
        bucket[key] = state
    else
        self.coalesced = self.coalesced + 1
        state.callback = spec.callback
        if spec.moduleId ~= nil then state.moduleId = tostring(spec.moduleId) end
        if spec.priority ~= nil then state.priority = tostring(spec.priority) end
        if spec.cost ~= nil then state.cost = math.max(1, math.floor(tonumber(spec.cost) or 1)) end
    end

    local reason = tostring(spec.reason or "request")
    state.reasons[reason] = true
    local delayMs = math.max(50, tonumber(spec.delayMs) or 200)

    local scheduler = S.Scheduler
    if scheduler == nil or type(scheduler.AddOneShot) ~= "function" then
        RemoveState(self, state)
        return Execute(self, state, reason)
    end

    scheduler:RemoveTask(state.taskName)
    local added = scheduler:AddOneShot(state.taskName, delayMs, function()
        if tonumber(state.generation) ~= tonumber(S.Generation) then return false end
        RemoveState(R, state)
        local executed = Execute(R, state, reason)
        return executed
    end, owner, state.priority, state.cost)
    if added ~= true then
        RemoveState(self, state)
        return Execute(self, state, reason)
    end
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
    }
end
