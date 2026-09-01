------------------------------------------------------------------------
-- Replicated Suite - shared reuse primitives
--
-- This file intentionally has no State/Storage dependency.  Professional
-- addons can use the globally published primitives when embedded, while the
-- helpers themselves stay valid for their standalone runtime as well.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite

local Shared = rawget(_G, "ReplicatedSuiteShared") or {}
_G.ReplicatedSuiteShared = Shared
S.Reuse = Shared

Shared.Value = Shared.Value or {}
local Value = Shared.Value

function Value.IsFinite(value)
    local n = tonumber(value)
    return n ~= nil and n == n and n ~= math.huge and n ~= -math.huge
end

function Value.Clamp(value, minimum, maximum, fallback)
    local n = Value.IsFinite(value) and tonumber(value) or tonumber(fallback) or tonumber(minimum) or 0
    if minimum ~= nil and n < minimum then n = minimum end
    if maximum ~= nil and n > maximum then n = maximum end
    return n
end

function Value.Normalize(value, options)
    options = type(options) == "table" and options or {}
    local n = Value.Clamp(value, options.min, options.max, options.default)
    local step = tonumber(options.step)
    if step ~= nil and step > 0 then
        local base = tonumber(options.min) or 0
        n = base + math.floor(((n - base) / step) + 0.5) * step
        n = Value.Clamp(n, options.min, options.max, options.default)
    end
    local precision = tonumber(options.precision)
    if options.integer == true then precision = 0 end
    if precision ~= nil and precision >= 0 then
        local factor = 10 ^ math.min(6, math.floor(precision))
        n = math.floor(n * factor + 0.5) / factor
    end
    return n
end

function Value.Format(value, options)
    options = type(options) == "table" and options or {}
    local n = Value.Normalize(value, options)
    local precision = tonumber(options.precision)
    if options.integer == true then precision = 0 end
    local text
    if precision ~= nil and precision > 0 then text = string.format("%." .. tostring(math.min(6, math.floor(precision))) .. "f", n)
    else text = tostring(math.floor(n + 0.5)) end
    return text .. tostring(options.unit or "")
end

Shared.Text = Shared.Text or {}
local Text = Shared.Text

function Text.TruncateUtf8(value, byteLimit, suffix)
    local text = tostring(value or "")
    local limit = math.max(0, math.floor(tonumber(byteLimit) or #text))
    if #text <= limit then return text end
    local cut = text:sub(1, limit)
    while #cut > 0 do
        local last = cut:byte(#cut)
        if last < 0x80 or last >= 0xC0 then break end
        cut = cut:sub(1, #cut - 1)
    end
    return cut .. tostring(suffix or "")
end

function Text.Trim(value)
    local text = tostring(value or "")
    return text:match("^%s*(.-)%s*$") or ""
end

function Text.SingleLine(value)
    return Text.Trim(tostring(value or ""):gsub("[\r\n]", " "))
end

Shared.Table = Shared.Table or {}
local Table = Shared.Table

function Table.DeepCopy(value, seen)
    if type(value) ~= "table" then return value end
    seen = seen or {}
    if seen[value] ~= nil then return seen[value] end
    local result = {}
    seen[value] = result
    for key, child in pairs(value) do
        result[Table.DeepCopy(key, seen)] = Table.DeepCopy(child, seen)
    end
    return result
end

function Table.Count(value)
    local count = 0
    if type(value) == "table" then
        for _ in pairs(value) do count = count + 1 end
    end
    return count
end

Shared.Id = Shared.Id or {}
local Id = Shared.Id

function Id.Normalize(value)
    return tostring(value or ""):lower():gsub("[^%w_%-]", "")
end

Shared.Time = Shared.Time or {}
local Time = Shared.Time

function Time.NowMs()
    return type(S.NowMs) == "function" and (tonumber(S.NowMs()) or 0) or 0
end

Shared.NativeSafe = Shared.NativeSafe or {}
local NativeSafe = Shared.NativeSafe

function NativeSafe.Call(widget, method, ...)
    if widget == nil or type(widget[method]) ~= "function" then return false, "unsupported" end
    local args = { ... }
    local count = select("#", ...)
    local ok, result = pcall(function() return widget[method](widget, unpack(args, 1, count)) end)
    return ok == true and result ~= false, result
end

function NativeSafe.ReleaseHandler(widget, handlerName)
    if widget == nil or type(widget.ReleaseHandler) ~= "function" then return false end
    if type(widget.HasHandler) == "function" then
        local ok, has = pcall(widget.HasHandler, widget, handlerName)
        if ok and has ~= true then return true end
    end
    local ok, result = pcall(widget.ReleaseHandler, widget, handlerName)
    return ok == true and result ~= false
end

function NativeSafe.BindHandler(widget, handlerName, callback)
    if widget == nil or type(widget.SetHandler) ~= "function" or type(callback) ~= "function" then return false, "unsupported" end
    NativeSafe.ReleaseHandler(widget, handlerName)
    local ok, result = pcall(widget.SetHandler, widget, handlerName, callback)
    if ok ~= true or result == false then return false, tostring(result or "SetHandler failed") end
    return true
end

function NativeSafe.CreateDriver(id, parent, visible)
    local factory = S.NativeObjectFactory
    if type(factory) ~= "table" or type(factory.CreateWindow) ~= "function" then return nil, "NativeObjectFactory unavailable" end
    -- Logical runtime-host IDs must cross the same compact identity boundary as
    -- RSUI widgets. Passing a semantic ID directly into the native factory would
    -- bypass the collision/length registry introduced in M1.14.1.
    local physicalId = type(S.PhysicalId) == "function" and S.PhysicalId("runtime_driver_" .. tostring(id or "host")) or nil
    if physicalId == nil then return nil, "native runtime driver identity unavailable" end
    local window, createErr = factory:CreateWindow(physicalId, parent or "UIParent", "")
    if window == nil then return nil, createErr or "native driver creation failed" end
    NativeSafe.Call(window, "SetExtent", 1, 1)
    NativeSafe.Call(window, "AddAnchor", "TOPLEFT", parent or "UIParent", 0, 0)
    NativeSafe.Call(window, "EnablePick", false, true)
    NativeSafe.Call(window, "Clickable", false, true)
    NativeSafe.Call(window, "Show", visible == true)
    return window
end

Shared.NativeRuntimeHost = Shared.NativeRuntimeHost or {}
local RuntimeHost = Shared.NativeRuntimeHost

function RuntimeHost.Acquire(options)
    options = type(options) == "table" and options or {}
    local host = { id = tostring(options.id or "runtime_host"), parent = options.parent or "UIParent", window = options.window,
        handlers = {}, events = {}, visible = options.visible == true, generation = S.Generation }
    function host:Ensure()
        if tonumber(self.generation) ~= tonumber(S.Generation) then return false, "stale runtime host generation" end
        if self.window ~= nil then
            local nativeGeneration = tonumber(self.window.rsNativeGeneration)
            if nativeGeneration ~= nil and nativeGeneration ~= tonumber(S.Generation) then return false, "stale runtime host window" end
            return true, self.window
        end
        local window, err = NativeSafe.CreateDriver(self.id, self.parent, self.visible)
        if window == nil then return false, err end
        self.window = window
        return true, window
    end
    function host:Bind(handlerName, callback)
        local ok, windowOrErr = self:Ensure()
        if not ok then return false, windowOrErr end
        if type(callback) ~= "function" then return false, "callback required" end
        local generation = self.generation
        local guarded = function(...)
            if tonumber(S.Generation) ~= tonumber(generation) then return nil end
            return callback(...)
        end
        local bound, err = NativeSafe.BindHandler(windowOrErr, handlerName, guarded)
        if bound then self.handlers[handlerName] = true end
        return bound, err
    end
    function host:Register(eventName)
        local ok, windowOrErr = self:Ensure()
        if not ok then return false, windowOrErr end
        local registered, result = NativeSafe.Call(windowOrErr, "RegisterEvent", eventName)
        if registered then self.events[tostring(eventName)] = true end
        return registered, result
    end
    function host:Show(visible)
        local ok, windowOrErr = self:Ensure()
        if not ok then return false, windowOrErr end
        self.visible = visible == true
        return NativeSafe.Call(windowOrErr, "Show", self.visible)
    end
    function host:Release()
        local window = self.window
        if window == nil then return true end
        for handlerName in pairs(self.handlers) do NativeSafe.ReleaseHandler(window, handlerName) end
        for eventName in pairs(self.events) do NativeSafe.Call(window, "UnregisterEvent", eventName) end
        self.handlers, self.events = {}, {}
        NativeSafe.Call(window, "Show", false)
        return true
    end
    return host
end

Shared.OwnerScope = Shared.OwnerScope or {}
local OwnerScope = Shared.OwnerScope

function OwnerScope.Release(scope, owner, moduleId)
    scope = type(scope) == "table" and scope or {}
    if owner == nil then return 0 end
    local released = 0
    if scope.events ~= nil and type(scope.events.UnsubscribeOwner) == "function" then released = released + (tonumber(scope.events:UnsubscribeOwner(owner)) or 0) end
    if scope.scheduler ~= nil and type(scope.scheduler.RemoveOwner) == "function" then released = released + (tonumber(scope.scheduler:RemoveOwner(owner)) or 0) end
    if scope.refresh ~= nil and type(scope.refresh.CancelOwner) == "function" then released = released + (tonumber(scope.refresh:CancelOwner(owner)) or 0) end
    if scope.observation ~= nil and type(scope.observation.Unsubscribe) == "function" and moduleId ~= nil then
        scope.observation:Unsubscribe(tostring(moduleId))
    end
    return released
end

-- Keep the Suite utility surface as the canonical convenience API for normal
-- modules. Old call sites remain compatible while new code has no reason to
-- introduce private Clamp/UTF-8 helpers.
S.Utils.Clamp = Value.Clamp
S.Utils.NormalizeValue = Value.Normalize
S.Utils.FormatValue = Value.Format
S.Utils.TruncateUtf8 = Text.TruncateUtf8
S.Utils.Trim = Text.Trim
S.Utils.SingleLine = Text.SingleLine
S.Utils.DeepCopy = Table.DeepCopy
S.Utils.TableCount = Table.Count
S.Utils.NormalizeId = Id.Normalize
S.Utils.NowMs = Time.NowMs
