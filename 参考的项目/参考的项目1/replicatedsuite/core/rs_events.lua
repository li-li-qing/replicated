------------------------------------------------------------------------
-- Replicated Suite - Isolated event bus
-- Uses a private hidden Window so this addon never replaces another addon's
-- UIParent:SetEventHandler callback.
------------------------------------------------------------------------

if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite

S.Events = { host = nil, listeners = {}, registered = {}, ownerModules = {}, running = false }
local E = S.Events

function E:BindOwner(owner, moduleId)
    if owner == nil or moduleId == nil or tostring(moduleId) == "" then return false end
    self.ownerModules[owner] = tostring(moduleId)
    return true
end

function E:Subscribe(eventName, owner, callback)
    if type(eventName) ~= "string" or type(callback) ~= "function" then return false end
    self.listeners[eventName] = self.listeners[eventName] or {}
    local ownerLabel = type(owner) == "table" and (owner.Id or owner.id or owner.Name or owner.name) or nil
    local moduleId = self.ownerModules[owner] or tostring(ownerLabel or "suite")
    table.insert(self.listeners[eventName], { owner = owner, callback = callback, label = tostring(ownerLabel or "listener"), moduleId = moduleId })
    if self.running == true then self:Register(eventName) end
    return true
end

function E:Unsubscribe(eventName, owner)
    local list = self.listeners[eventName]
    if type(list) ~= "table" then return 0 end
    local kept, removed = {}, 0
    for _, listener in ipairs(list) do
        if listener.owner == owner then removed = removed + 1 else kept[#kept + 1] = listener end
    end
    if #kept > 0 then self.listeners[eventName] = kept else self.listeners[eventName] = nil end
    return removed
end

function E:UnsubscribeOwner(owner)
    if owner == nil then return 0 end
    local removed = 0
    for eventName, list in pairs(self.listeners) do
        if type(list) == "table" then
            local kept = {}
            for _, listener in ipairs(list) do
                if listener.owner == owner then removed = removed + 1 else kept[#kept + 1] = listener end
            end
            if #kept > 0 then self.listeners[eventName] = kept else self.listeners[eventName] = nil end
        end
    end
    return removed
end

function E:Register(eventName)
    if self.host == nil or self.registered[eventName] == true then return self.registered[eventName] == true end
    if type(self.host.RegisterEvent) ~= "function" then return false end
    local ok, result = pcall(function() return self.host:RegisterEvent(eventName) end)
    if ok and result ~= false then self.registered[eventName] = true; return true end
    return false
end

function E:Dispatch(eventName, ...)
    local list = self.listeners[eventName]
    if type(list) ~= "table" then return end
    local args = { ... }
    local argCount = select("#", ...)
    -- Dispatch has snapshot semantics without allocating a second listener table:
    -- a callback may subscribe another listener, but that new listener must not
    -- receive the event that is already in flight. UnsubscribeOwner replaces the
    -- authoritative list, so the current snapshot remains deterministic as well.
    local listenerCount = #list
    for index = 1, listenerCount do
        local listener = list[index]
        if listener ~= nil and type(listener.callback) == "function" then
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
    local host = CreateEmptyWindow(S.PhysicalId("event_host"), "UIParent")
    if host == nil then return false end
    if type(host.Show)=="function" then host:Show(false) end
    if type(host.SetHandler)~="function" then return false end
    local generation = S.Generation
    local handlerOk, handlerResult = pcall(function()
        return host:SetHandler("OnEvent", function(_, eventName, ...)
            if S.Generation ~= generation or E.running ~= true then return end
            E:Dispatch(eventName, ...)
        end)
    end)
    if handlerOk ~= true or handlerResult == false then
        if type(host.Show)=="function" then pcall(function() host:Show(false) end) end
        return false
    end
    self.host = host
    self.running = true
    for eventName in pairs(self.listeners) do self:Register(eventName) end
    return true
end

function E:Stop()
    self.running = false
    self.listeners = {}
    self.registered = {}
    self.ownerModules = {}
    local host = self.host
    if host ~= nil then
        if type(host.ReleaseHandler) == "function" then
            pcall(function() host:ReleaseHandler("OnEvent") end)
        end
        pcall(function() host:Show(false) end)
    end
    self.host = nil
end
