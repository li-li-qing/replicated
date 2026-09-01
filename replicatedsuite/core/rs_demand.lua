------------------------------------------------------------------------
-- Replicated Suite - Demand / Consumer Lease Foundation
--
-- Shared reference-counted lifecycle primitive.  A Demand owns only consumer
-- intent.  Business/service side effects remain in the owner's reconcile
-- callback.  Transitions are transactional: if reconcile fails, the consumer
-- state is restored and the reconcile callback is invoked in reverse so any
-- downstream lease/start/subscribe side effects can be unwound.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite

S.Demand = {
    version = 2,
    registry = {},
    order = {},
    created = 0,
    transitions = 0,
    rollbacks = 0,
    rollbackFailures = 0,
    quiesceFailures = 0,
}
local D = S.Demand

local DeepCopy = S.Utils.DeepCopy

local function DeepEqual(a, b, seen)
    if a == b then return true end
    if type(a) ~= type(b) or type(a) ~= "table" then return false end
    seen = seen or {}
    if seen[a] == b then return true end
    seen[a] = b
    for key, value in pairs(a) do if DeepEqual(value, b[key], seen) ~= true then return false end end
    for key in pairs(b) do if a[key] == nil then return false end end
    return true
end

local function ReplaceTable(target, source)
    for key in pairs(target) do target[key] = nil end
    for key, value in pairs(type(source) == "table" and source or {}) do target[key] = DeepCopy(value) end
end

local function Count(tbl)
    local count = 0
    for _ in pairs(type(tbl) == "table" and tbl or {}) do count = count + 1 end
    return count
end

local function Emit(level, code, message, context)
    local diag = S.DiagnosticsManager
    if type(diag) == "table" and type(diag.Emit) == "function" then
        diag:Emit(level, "demand", code, message, context)
    end
end

function D:Create(spec)
    spec = type(spec) == "table" and spec or {}
    local id = tostring(spec.id or "")
    if id == "" then return nil, "demand id required" end
    if self.registry[id] ~= nil then return nil, "demand id already registered: " .. id end
    if spec.reconcile ~= nil and type(spec.reconcile) ~= "function" then return nil, "demand reconcile must be function" end

    local lease = {
        id = id,
        owner = spec.owner,
        consumers = {},
        count = 0,
        normalize = type(spec.normalize) == "function" and spec.normalize or nil,
        reconcile = spec.reconcile,
        quiesce = type(spec.quiesce) == "function" and spec.quiesce or nil,
        projectionOwner = spec.projectionOwner or spec.owner,
        projectionConsumersField = tostring(spec.projectionConsumersField or "consumers"),
        projectionCountField = tostring(spec.projectionCountField or "consumerCount"),
        generation = S.Generation,
        transitions = 0,
        rollbacks = 0,
    }

    function lease:_Normalize(options)
        local value = type(options) == "table" and options or {}
        if self.normalize ~= nil then
            local ok, normalized = xpcall(function() return self.normalize(value) end, S.SafeTraceback)
            if ok ~= true then return nil, normalized end
            value = type(normalized) == "table" and normalized or {}
        end
        return DeepCopy(value)
    end

    function lease:_Project()
        local owner = self.projectionOwner
        if type(owner) ~= "table" then return end
        owner[self.projectionConsumersField] = DeepCopy(self.consumers)
        owner[self.projectionCountField] = self.count
    end

    function lease:Snapshot()
        return { count = self.count, consumers = DeepCopy(self.consumers) }
    end

    function lease:Get(token)
        token = tostring(token or "")
        local value = token ~= "" and self.consumers[token] or nil
        return value ~= nil and DeepCopy(value) or nil
    end

    function lease:Has(token)
        token = tostring(token or "")
        return token ~= "" and self.consumers[token] ~= nil
    end

    function lease:AnyOption(key, expected)
        key = tostring(key or "")
        if key == "" then return false end
        for _, options in pairs(self.consumers) do
            if type(options) == "table" and options[key] == expected then return true end
        end
        return false
    end

    function lease:_Invoke(before, after, context)
        if self.reconcile == nil then return true end
        local ok, result, err = xpcall(function()
            return self.reconcile(self, before, after, context)
        end, S.SafeTraceback)
        if ok ~= true then return false, result end
        if result == false then return false, err or "demand reconcile failed" end
        return true, result
    end

    function lease:_Restore(snapshot)
        ReplaceTable(self.consumers, snapshot and snapshot.consumers or {})
        self.count = Count(self.consumers)
        self:_Project()
    end

    function lease:_Commit(before, context)
        self.count = Count(self.consumers)
        self:_Project()
        local after = self:Snapshot()
        if DeepEqual(before, after) then return true, false end

        self.transitions = self.transitions + 1
        D.transitions = D.transitions + 1
        local ok, err = self:_Invoke(before, after, context)
        if ok == true then return true, true end

        self.rollbacks = self.rollbacks + 1
        D.rollbacks = D.rollbacks + 1
        self:_Restore(before)
        local rollbackContext = {
            action = context and context.action or "transition",
            token = context and context.token or nil,
            reason = context and context.reason or nil,
            rollback = true,
            cause = tostring(err or "reconcile failed"),
        }
        local rollbackOk, rollbackErr = self:_Invoke(after, before, rollbackContext)
        if rollbackOk ~= true then
            D.rollbackFailures = D.rollbackFailures + 1
            Emit("error", "DEMAND_ROLLBACK_FAILED", "Demand 回滚副作用失败", {
                id = self.id, error = tostring(rollbackErr or "unknown"), cause = tostring(err or "unknown"),
            })
        end
        return false, tostring(err or "demand reconcile failed")
    end

    function lease:Acquire(token, options, reason)
        token = tostring(token or "")
        if token == "" then return false, "consumer token required" end
        if tonumber(self.generation) ~= tonumber(S.Generation) then return false, "stale demand generation" end
        local normalized, normalizeErr = self:_Normalize(options)
        if normalized == nil then return false, normalizeErr end
        local before = self:Snapshot()
        self.consumers[token] = normalized
        return self:_Commit(before, { action = before.consumers[token] ~= nil and "update" or "acquire", token = token, reason = reason })
    end

    function lease:Release(token, reason)
        token = tostring(token or "")
        if token == "" or self.consumers[token] == nil then return false, "consumer not held" end
        local before = self:Snapshot()
        self.consumers[token] = nil
        return self:_Commit(before, { action = "release", token = token, reason = reason })
    end

    function lease:Clear(reason)
        if self.count <= 0 then return true, false end
        local before = self:Snapshot()
        for token in pairs(self.consumers) do self.consumers[token] = nil end
        return self:_Commit(before, { action = "clear", reason = reason or "clear" })
    end

    function lease:ForceClear()
        for token in pairs(self.consumers) do self.consumers[token] = nil end
        self.count = 0
        self:_Project()
        return true
    end

    function lease:ForceQuiesce(reason, cause)
        local quiesced, quiesceErr = true, nil
        if self.quiesce ~= nil then
            local ok, result, err = xpcall(function() return self.quiesce(self, reason or "runtime_quiesce", cause) end, S.SafeTraceback)
            quiesced = ok == true and result ~= false
            quiesceErr = ok == true and err or result
            if quiesced ~= true then
                D.quiesceFailures = D.quiesceFailures + 1
                Emit("error", "DEMAND_FORCE_QUIESCE_FAILED", "Demand 强制静默下游资源失败", {
                    id = self.id, reason = tostring(reason or "runtime_quiesce"), error = tostring(quiesceErr or "unknown"), cause = tostring(cause or "")
                })
            end
        end
        self:ForceClear()
        return quiesced, quiesceErr
    end

    function lease:Describe()
        return { id = self.id, consumers = self.count, transitions = self.transitions, rollbacks = self.rollbacks, generation = self.generation }
    end

    lease:_Project()
    self.registry[id] = lease
    self.order[#self.order + 1] = id
    self.created = self.created + 1
    return lease
end

function D:Get(id) return self.registry[tostring(id or "")] end

function D:ClearAll(reason)
    local ok = true
    -- Demand dependencies are normally created foundation->service->feature.
    -- Shutdown therefore walks the registry in reverse creation order so
    -- Feature consumers release before their downstream Services/Foundation.
    for index = #self.order, 1, -1 do
        local lease = self.registry[self.order[index]]
        if lease ~= nil then
            local cleared, clearErr = lease:Clear(reason or "runtime_clear")
            if cleared ~= true then
                ok = false
                Emit("warning", "DEMAND_FORCE_QUIESCE", "Demand 正常释放失败，进入强制静默", {
                    id = lease.id, reason = tostring(reason or "runtime_clear"), error = tostring(clearErr or "unknown"),
                })
                lease:ForceQuiesce(reason or "runtime_clear", clearErr)
            end
        end
    end
    return ok
end

function D:Describe()
    local active = 0
    for _, lease in pairs(self.registry) do if lease.count > 0 then active = active + 1 end end
    return {
        version = self.version, leases = Count(self.registry), active = active,
        transitions = self.transitions, rollbacks = self.rollbacks, rollbackFailures = self.rollbackFailures, quiesceFailures = self.quiesceFailures,
    }
end
