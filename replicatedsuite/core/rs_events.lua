------------------------------------------------------------------------
-- Replicated Suite - Isolated event bus
-- Uses a private hidden Window so this addon never replaces another addon's
-- UIParent:SetEventHandler callback.
------------------------------------------------------------------------

if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite

S.Events = {
    version = 4,
    host = nil,
    listeners = {},
    internalListeners = {},
    registered = {},
    ownerModules = {},
    running = false,
    registerFailures = 0,
    unregisterFailures = 0,
    startFailures = 0,
    subscribeFailures = 0,
    optionalTopics = {},
    optionalRegisterFailures = 0,
    optionalUnavailable = {},
    parkedRegistrations = {},
    unregisterCapability = nil,
    unregisterSkipped = 0,
    ownerReleaseContractVersion = 1,
    -- 维护（foundation-lifecycle-1）：Owner 释放立即撤销在途回调，Epoch 隔离同代 Stop/Start。
    -- 仅治理事件执行权限，不拥有 Feature/UI 状态；不改变 owner-first 参数或 Native 注册策略。
    dispatchEpoch = 0,
    lifecycleContractVersion = 1,
}
local E = S.Events


local function ListenerListIsOptional(list)
    if type(list) ~= "table" or #list <= 0 then return nil end
    for _, listener in ipairs(list) do
        if listener.optional ~= true then return false end
    end
    return true
end

local function Emit(level, code, message, context)
    local diag = S.DiagnosticsManager
    if type(diag) == "table" and type(diag.RateLimited) == "function" then
        diag:RateLimited(level, "events", code, 3000, message, context)
    elseif type(diag) == "table" and type(diag.Emit) == "function" then
        diag:Emit(level, "events", code, message, context)
    end
end

function E:BindOwner(owner, moduleId)
    if owner == nil or moduleId == nil or tostring(moduleId) == "" then return false end
    self.ownerModules[owner] = tostring(moduleId)
    return true
end

function E:RegisterOptional(eventName)
    eventName = tostring(eventName or "")
    if eventName == "" then return false end
    if self.registered[eventName] == true then
        self.optionalUnavailable[eventName] = nil
        self.parkedRegistrations[eventName] = nil
        return true
    end
    if self.host == nil or type(self.host.RegisterEvent) ~= "function" then
        self.optionalRegisterFailures = self.optionalRegisterFailures + 1
        self.optionalUnavailable[eventName] = (tonumber(self.optionalUnavailable[eventName]) or 0) + 1
        Emit("warning", "OPTIONAL_EVENT_REGISTER_UNAVAILABLE", "可选原生事件不可用，功能将降级", { event = eventName })
        return false
    end
    local ok, result = pcall(function() return self.host:RegisterEvent(eventName) end)
    if ok and result ~= false then
        self.registered[eventName] = true
        self.optionalUnavailable[eventName] = nil
        return true
    end
    self.optionalRegisterFailures = self.optionalRegisterFailures + 1
    self.optionalUnavailable[eventName] = (tonumber(self.optionalUnavailable[eventName]) or 0) + 1
    Emit("warning", "OPTIONAL_EVENT_REGISTER_FAILED", "可选原生事件注册失败，功能将降级", { event = eventName })
    return false
end

function E:SubscribeOptional(eventName, owner, callback)
    if type(eventName) ~= "string" or eventName == "" or type(callback) ~= "function" then return false end
    if self.running == true and self.registered[eventName] ~= true then
        if self:RegisterOptional(eventName) ~= true then return false end
    end
    self.optionalTopics[eventName] = self.optionalTopics[eventName] ~= false
    self.parkedRegistrations[eventName] = nil
    self.listeners[eventName] = self.listeners[eventName] or {}
    local ownerLabel = type(owner) == "table" and (owner.Id or owner.id or owner.Name or owner.name) or nil
    local moduleId = self.ownerModules[owner] or tostring(ownerLabel or "suite")
    table.insert(self.listeners[eventName], { owner = owner, callback = callback, label = tostring(ownerLabel or "listener"), moduleId = moduleId, optional = true })
    return true
end

function E:Subscribe(eventName, owner, callback)
    if type(eventName) ~= "string" or eventName == "" or type(callback) ~= "function" then return false end
    -- Native registration is part of the subscription transaction. Never tell
    -- a Service that its listener is live when RegisterEvent actually failed.
    -- Do not promote an existing optional topic to required until registration
    -- has succeeded and this required listener is actually committed.
    if self.running == true and self.registered[eventName] ~= true then
        if self:Register(eventName) ~= true then
            self.subscribeFailures = self.subscribeFailures + 1
            Emit("error", "EVENT_SUBSCRIBE_REGISTER_FAILED", "原生事件注册失败，订阅未提交", { event = eventName })
            return false
        end
    end
    self.parkedRegistrations[eventName] = nil
    self.listeners[eventName] = self.listeners[eventName] or {}
    local ownerLabel = type(owner) == "table" and (owner.Id or owner.id or owner.Name or owner.name) or nil
    local moduleId = self.ownerModules[owner] or tostring(ownerLabel or "suite")
    table.insert(self.listeners[eventName], { owner = owner, callback = callback, label = tostring(ownerLabel or "listener"), moduleId = moduleId })
    self.optionalTopics[eventName] = false
    return true
end

function E:Unsubscribe(eventName, owner)
    local list = self.listeners[eventName]
    if type(list) ~= "table" then return 0 end
    local kept, removed = {}, 0
    for _, listener in ipairs(list) do
        -- 维护：只换 list 会让旧分发快照继续调用已释放的 Owner；撤销标记由所有快照共享。
        -- 不清 callback/owner 字段，避免破坏正在执行的回调；当前栈退回后旧记录自然释放。
        if listener.owner == owner then
            listener.cancelled = true
            removed = removed + 1
        else kept[#kept + 1] = listener end
    end
    if #kept > 0 then
        self.listeners[eventName] = kept
        self.optionalTopics[eventName] = ListenerListIsOptional(kept) == true
    else
        self.listeners[eventName] = nil
        self.optionalTopics[eventName] = nil
        self.optionalUnavailable[eventName] = nil
        self:Unregister(eventName)
    end
    return removed
end

function E:UnsubscribeOwner(owner)
    if owner == nil then return 0 end
    local removed = 0
    for eventName, list in pairs(self.listeners) do
        if type(list) == "table" then
            local kept = {}
            for _, listener in ipairs(list) do
                -- 维护：只换 list 会让旧分发快照继续调用已释放的 Owner；撤销标记由所有快照共享。
                -- 不清 callback/owner 字段，避免破坏正在执行的回调；当前栈退回后旧记录自然释放。
                if listener.owner == owner then
                    listener.cancelled = true
                    removed = removed + 1
                else kept[#kept + 1] = listener end
            end
            if #kept > 0 then
                self.listeners[eventName] = kept
                self.optionalTopics[eventName] = ListenerListIsOptional(kept) == true
            else
                self.listeners[eventName] = nil
                self.optionalTopics[eventName] = nil
                self.optionalUnavailable[eventName] = nil
                self:Unregister(eventName)
            end
        end
    end
    self.ownerModules[owner] = nil
    return removed
end

------------------------------------------------------------------------
-- Internal event bus
--
-- V3 Features publish projection changes here. Internal topics never call
-- Native RegisterEvent(), so a Presentation subscriber cannot accidentally
-- expand the game's event surface merely by observing a Feature.
------------------------------------------------------------------------
function E:SubscribeInternal(topic, owner, callback)
    topic = tostring(topic or "")
    if topic == "" or type(callback) ~= "function" then return false end
    self.internalListeners[topic] = self.internalListeners[topic] or {}
    local list = self.internalListeners[topic]
    list[#list + 1] = { owner = owner, callback = callback }
    return true
end

function E:UnsubscribeInternal(topic, owner)
    topic = tostring(topic or "")
    local list = self.internalListeners[topic]
    if type(list) ~= "table" then return 0 end
    local kept, removed = {}, 0
    for _, listener in ipairs(list) do
        -- 维护：只换 list 会让旧分发快照继续调用已释放的 Owner；撤销标记由所有快照共享。
        -- 不清 callback/owner 字段，避免破坏正在执行的回调；当前栈退回后旧记录自然释放。
        if listener.owner == owner then
            listener.cancelled = true
            removed = removed + 1
        else kept[#kept + 1] = listener end
    end
    if #kept > 0 then self.internalListeners[topic] = kept else self.internalListeners[topic] = nil end
    return removed
end

function E:UnsubscribeInternalOwner(owner)
    if owner == nil then return 0 end
    local removed = 0
    for topic, list in pairs(self.internalListeners) do
        if type(list) == "table" then
            local kept = {}
            for _, listener in ipairs(list) do
                -- 维护：只换 list 会让旧分发快照继续调用已释放的 Owner；撤销标记由所有快照共享。
                -- 不清 callback/owner 字段，避免破坏正在执行的回调；当前栈退回后旧记录自然释放。
                if listener.owner == owner then
                    listener.cancelled = true
                    removed = removed + 1
                else kept[#kept + 1] = listener end
            end
            if #kept > 0 then self.internalListeners[topic] = kept else self.internalListeners[topic] = nil end
        end
    end
    return removed
end

function E:Publish(topic, ...)
    topic = tostring(topic or "")
    local list = self.internalListeners[topic]
    if type(list) ~= "table" then return 0 end
    local args, argCount = { ... }, select("#", ...)
    -- 维护：新增订阅延至下一次 Publish；Stop/Generation 变化中断快照，即使同代立即重启。
    local epoch, generation = self.dispatchEpoch, S.Generation
    local count = #list
    local delivered = 0
    for index = 1, count do
        if self.dispatchEpoch ~= epoch or S.Generation ~= generation then break end
        local listener = list[index]
        if listener ~= nil and listener.cancelled ~= true and type(listener.callback) == "function" then
            local ok, err = xpcall(function()
                listener.callback(listener.owner, unpack(args, 1, argCount))
            end, S.SafeTraceback)
            if ok then
                delivered = delivered + 1
            else
                S.LastInternalEventError = { topic = topic, error = tostring(err or "unknown") }
            end
        end
    end
    return delivered
end

function E:Unregister(eventName)
    eventName = tostring(eventName or "")
    if eventName == "" or self.registered[eventName] ~= true then return true end

    -- Some ArcheRage RU builds expose RegisterEvent without a matching
    -- UnregisterEvent. That is a capability limitation, not a runtime failure:
    -- listener ownership has already been removed above, so the native event can
    -- be safely parked on the hidden host and ignored until host shutdown.
    if self.host == nil or type(self.host.UnregisterEvent) ~= "function" then
        self.unregisterCapability = false
        if self.parkedRegistrations[eventName] ~= true then
            self.unregisterSkipped = (tonumber(self.unregisterSkipped) or 0) + 1
        end
        self.parkedRegistrations[eventName] = true
        return true, "parked"
    end
    self.unregisterCapability = true
    local ok, result = pcall(function() return self.host:UnregisterEvent(eventName) end)
    if ok and result ~= false then
        self.registered[eventName] = nil
        self.parkedRegistrations[eventName] = nil
        return true
    end
    self.unregisterFailures = self.unregisterFailures + 1
    Emit("warning", "EVENT_UNREGISTER_FAILED", "原生事件注销失败", { event = eventName })
    return false
end

function E:Register(eventName)
    eventName = tostring(eventName or "")
    if eventName == "" then return false end
    if self.registered[eventName] == true then return true end
    if self.host == nil or type(self.host.RegisterEvent) ~= "function" then
        self.registerFailures = self.registerFailures + 1
        Emit("error", "EVENT_REGISTER_UNAVAILABLE", "原生事件注册接口不可用", { event = eventName })
        return false
    end
    local ok, result = pcall(function() return self.host:RegisterEvent(eventName) end)
    if ok and result ~= false then self.registered[eventName] = true; return true end
    self.registerFailures = self.registerFailures + 1
    Emit("error", "EVENT_REGISTER_FAILED", "原生事件注册失败", { event = eventName })
    return false
end

function E:Dispatch(eventName, ...)
    local list = self.listeners[eventName]
    if type(list) ~= "table" then return end
    local args = { ... }
    local argCount = select("#", ...)
    -- 维护：只冻结本次订阅数量，不冻结生命周期权限；取消立即生效，新增下次分发。
    -- 复用原 list + 撤销标记，无每事件 listener 副本；重载/Stop/Start 均不能复活旧快照。
    local epoch, generation = self.dispatchEpoch, S.Generation
    local listenerCount = #list
    for index = 1, listenerCount do
        if self.dispatchEpoch ~= epoch or S.Generation ~= generation then break end
        local listener = list[index]
        if listener ~= nil and listener.cancelled ~= true and type(listener.callback) == "function" then
            local moduleId = tostring(listener.moduleId or listener.label or "suite")
            local label = "event:" .. tostring(eventName) .. ":" .. moduleId
            local token = S.PerformanceMonitor and S.PerformanceMonitor:Begin(label, moduleId) or nil
            local ok, err = xpcall(function()
                listener.callback(listener.owner, unpack(args, 1, argCount))
            end, S.SafeTraceback)
            if S.PerformanceMonitor ~= nil then S.PerformanceMonitor:End(token) end
            if not ok then S.LastEventError = { event = tostring(eventName), error = tostring(err or "unknown") } end
        end
    end
end

function E:Start()
    if self.running == true then return true end
    local factory = S.NativeObjectFactory
    if type(factory) ~= "table" or type(factory.CreateWindow) ~= "function" then self.startFailures = self.startFailures + 1; return false end
    local host = factory:CreateWindow(S.PhysicalId("event_host"), "UIParent", "")
    if host == nil then self.startFailures = self.startFailures + 1; return false end
    if type(host.Show)=="function" then host:Show(false) end
    if type(host.SetHandler)~="function" then self.startFailures = self.startFailures + 1; return false end
    -- 维护：Generation 只区分重载，不区分同代重启；Native 可能无法解绑旧 Handler。
    -- Host 身份 + Epoch 是 transport 执行门，不复制模块启停/可见性 Authority。
    self.dispatchEpoch = self.dispatchEpoch + 1
    local epoch = self.dispatchEpoch
    local generation = S.Generation
    local handlerOk, handlerResult = pcall(function()
        return host:SetHandler("OnEvent", function(_, eventName, ...)
            if S.Generation ~= generation or E.running ~= true or E.host ~= host or E.dispatchEpoch ~= epoch then return end
            E:Dispatch(eventName, ...)
        end)
    end)
    if handlerOk ~= true or handlerResult == false then
        if type(host.Show)=="function" then pcall(function() host:Show(false) end) end
        self.startFailures = self.startFailures + 1
        return false
    end
    self.host = host
    self.running = true
    local names = {}
    for eventName in pairs(self.listeners) do names[#names + 1] = eventName end
    table.sort(names)
    for _, eventName in ipairs(names) do
        local optional = self.optionalTopics[eventName] == true
        local registeredOk
        if optional == true then registeredOk = self:RegisterOptional(eventName)
        else registeredOk = self:Register(eventName) end
        if registeredOk ~= true and optional ~= true then
            local registeredNames = {}
            for registeredName in pairs(self.registered) do registeredNames[#registeredNames + 1] = registeredName end
            for _, registeredName in ipairs(registeredNames) do self:Unregister(registeredName) end
            self.registered = {}
            self.running = false
            if type(host.ReleaseHandler) == "function" then pcall(function() host:ReleaseHandler("OnEvent") end) end
            if type(host.Show)=="function" then pcall(function() host:Show(false) end) end
            self.host = nil
            self.startFailures = self.startFailures + 1
            Emit("error", "EVENT_BUS_START_ROLLBACK", "事件总线启动事务回滚：存在无法注册的必需原生事件", { event = eventName })
            return false
        end
    end
    return true
end

function E:GetHealth()
    local nativeTopics, nativeListeners, internalTopics, internalListeners, registered = 0, 0, 0, 0, 0
    for _, list in pairs(self.listeners or {}) do nativeTopics = nativeTopics + 1; nativeListeners = nativeListeners + (type(list) == "table" and #list or 0) end
    for _, list in pairs(self.internalListeners or {}) do internalTopics = internalTopics + 1; internalListeners = internalListeners + (type(list) == "table" and #list or 0) end
    local parked = 0
    for eventName in pairs(self.registered or {}) do
        registered = registered + 1
        if self.parkedRegistrations[eventName] == true then parked = parked + 1 end
    end
    return {
        version = self.version, running = self.running == true, nativeTopics = nativeTopics, nativeListeners = nativeListeners,
        internalTopics = internalTopics, internalListeners = internalListeners, registered = registered,
        registerFailures = self.registerFailures, unregisterFailures = self.unregisterFailures,
        startFailures = self.startFailures, subscribeFailures = self.subscribeFailures,
        optionalRegisterFailures = self.optionalRegisterFailures, optionalUnavailable = self.optionalUnavailable,
        parkedRegistrations = parked, unregisterCapability = self.unregisterCapability,
        unregisterSkipped = tonumber(self.unregisterSkipped) or 0,
        nativeUnregisterSupported = self.unregisterCapability,
        ownerReleaseContractVersion = tonumber(self.ownerReleaseContractVersion) or 0,
        -- 维护：仅只读契约标识，诊断不触发事件注册、订阅或业务状态变更。
        lifecycleContractVersion = self.lifecycleContractVersion,
    }
end

function E:Stop()
    -- 维护：先撤销在途分发和旧 Native 闭包，再释放订阅；禁止先清表却留下快照可调用。
    self.dispatchEpoch = self.dispatchEpoch + 1
    self.running = false
    local registeredNames = {}
    for eventName in pairs(self.registered or {}) do registeredNames[#registeredNames + 1] = eventName end
    for _, eventName in ipairs(registeredNames) do self:Unregister(eventName) end
    self.listeners = {}
    self.internalListeners = {}
    self.registered = {}
    self.ownerModules = {}
    self.optionalTopics = {}
    self.optionalUnavailable = {}
    self.parkedRegistrations = {}
    self.unregisterCapability = nil
    self.unregisterSkipped = 0
    local host = self.host
    if host ~= nil then
        if type(host.ReleaseHandler) == "function" then
            pcall(function() host:ReleaseHandler("OnEvent") end)
        end
        pcall(function() host:Show(false) end)
    end
    self.host = nil
end
