-- Replicated Suite · 消费者需求与租约
-- 作者：Replicated
-- QQ群：1104129461
-- Demand 保存消费者意图和引用计数，实际启停由拥有者的 reconcile 执行。
-- reconcile 失败时恢复消费者快照，再反向调用以撤销租约、任务和订阅。
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
        -- 消费者计数只描述意图；回滚/强制静默失败必须另存故障，不能被空快照掩盖。
        needsQuiesce = false,
        -- 单租约只允许一个副作用事务；同步投影回调不能在旧快照尚未提交时再改消费者。
        transitioning = false,
        quiescing = false,
    }
    -- 只在执行栈内持有已提交前快照；忙中幂等确认必须证明目标早已存在，不能把临时投影当提交成功。
    local transitionBefore = nil

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
        -- 正向及逆向 reconcile 共用同一事务栅栏；其它租约仍可正常获取/释放。
        transitionBefore = before
        self.transitioning = true
        local ok, err = self:_Invoke(before, after, context)
        if ok == true then self.transitioning = false; transitionBefore = nil; return true, true end

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
        self.transitioning = false -- 失败也必须释放执行栅栏，让独立 quiesce 能在关闭时重试。
        transitionBefore = nil -- 外层结算后释放快照，禁止后续事务沿用上一轮的“已提交”证据。
        if rollbackOk ~= true then
            self.needsQuiesce = true -- RAM 已回到 before，不代表下游资源已恢复；直到成功静默前禁止丢失此证据。
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
        -- 故障租约不能对新消费者声称就绪；成功 quiesce 后才恢复正常业务获取。
        if self.needsQuiesce == true or self.quiescing == true then return false, "demand requires quiesce" end
        -- 无变化获取没有副作用，但忙中还必须命中事务前已提交的同值 token；外层新建/更新随后可能失败，不能提前承诺成功。
        if self.consumers[token] ~= nil and DeepEqual(self.consumers[token], normalized) then
            local committed = transitionBefore and transitionBefore.consumers[token] -- 忙事务只认可 before 快照，不能使用本轮临时投影。
            if self.transitioning ~= true or (committed ~= nil and DeepEqual(committed, normalized)) then return true, false end
        end
        if self.transitioning == true then return false, "demand transition in progress" end
        local before = self:Snapshot()
        self.consumers[token] = normalized
        return self:_Commit(before, { action = before.consumers[token] ~= nil and "update" or "acquire", token = token, reason = reason })
    end

    function lease:Release(token, reason)
        token = tostring(token or "")
        if token == "" or self.consumers[token] == nil then return false, "consumer not held" end
        -- 正常 Release 不能覆盖进行中的快照或不可信资源态；关闭恢复由 Clear/ForceQuiesce 承担。
        if self.transitioning == true or self.quiescing == true then return false, "demand transition in progress" end
        if self.needsQuiesce == true then return false, "demand requires quiesce" end
        local before = self:Snapshot()
        self.consumers[token] = nil
        return self:_Commit(before, { action = "release", token = token, reason = reason })
    end

    function lease:Clear(reason)
        -- 零消费者也可能有失败回滚留下的资源；只有正常空租约才能直接按幂等成功返回。
        if self.needsQuiesce == true then return self:ForceQuiesce(reason or "clear_retry", "pending demand cleanup") end
        if self.count <= 0 then return true, false end
        if self.transitioning == true or self.quiescing == true then return false, "demand transition in progress" end
        local before = self:Snapshot()
        for token in pairs(self.consumers) do self.consumers[token] = nil end
        return self:_Commit(before, { action = "clear", reason = reason or "clear" })
    end

    function lease:ForceClear()
        -- 强制逻辑清空也不能从 reconcile 内截断正在提交的事务，且不会自行洗掉 needsQuiesce。
        if self.transitioning == true or self.quiescing == true then return false, "demand transition in progress" end
        for token in pairs(self.consumers) do self.consumers[token] = nil end
        self.count = 0
        self:_Project()
        return true
    end

    function lease:ForceQuiesce(reason, cause)
        -- quiesce 是独立恢复事务，不能重入正向/逆向 reconcile，也不能在自己的回调中重开消费者。
        if self.transitioning == true or self.quiescing == true then return false, "demand transition in progress" end
        local hadCleanupFailure = self.needsQuiesce == true
        self.quiescing = true
        local quiesced, quiesceErr = true, nil
        if self.quiesce ~= nil then
            local ok, result, err = xpcall(function() return self.quiesce(self, reason or "runtime_quiesce", cause) end, S.SafeTraceback)
            quiesced = ok == true and result ~= false
            quiesceErr = ok == true and err or result
        elseif hadCleanupFailure then
            -- 已知清理失败不能被“没有恢复回调”伪装为成功；保留故障交给 Runtime 诊断。
            quiesced, quiesceErr = false, "demand quiesce unavailable"
        end
        self.quiescing = false -- 回调异常/返回失败也必须解锁，否则后续关闭无法重试恢复。
        self.needsQuiesce = quiesced ~= true -- 只有实际成功静默才清除失败证据，ForceClear 只撤销消费者意图。
        if quiesced ~= true then
            D.quiesceFailures = D.quiesceFailures + 1
            Emit("error", "DEMAND_FORCE_QUIESCE_FAILED", "Demand 强制静默下游资源失败", {
                id = self.id, reason = tostring(reason or "runtime_quiesce"), error = tostring(quiesceErr or "unknown"), cause = tostring(cause or "")
            })
        end
        self:ForceClear()
        return quiesced, quiesceErr
    end

    function lease:Describe()
        -- 诊断必须能区分“健康零需求”和“逻辑已清空但下游未确认停止”。
        return { id = self.id, consumers = self.count, transitions = self.transitions, rollbacks = self.rollbacks, generation = self.generation,
            needsQuiesce = self.needsQuiesce == true }
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
    -- 通常按基础层、服务、Feature 的顺序创建；关闭时反向遍历，让 Feature 先释放下游。
    for index = #self.order, 1, -1 do
        local lease = self.registry[self.order[index]]
        if lease ~= nil then
            -- 故障租约的 Clear 已执行一次恢复；每轮关闭只尝试一次 quiesce，失败留给下一次显式重试。
            local retryingQuiesce = lease.needsQuiesce == true
            local cleared, clearErr = lease:Clear(reason or "runtime_clear")
            if cleared ~= true then
                ok = false
                Emit("warning", "DEMAND_FORCE_QUIESCE", "Demand 正常释放失败，进入强制静默", {
                    id = lease.id, reason = tostring(reason or "runtime_clear"), error = tostring(clearErr or "unknown"),
                })
                if retryingQuiesce ~= true then lease:ForceQuiesce(reason or "runtime_clear", clearErr) end
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
