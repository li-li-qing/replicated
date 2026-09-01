------------------------------------------------------------------------
-- Replicated Suite V3 - Native ESC Bridge
--
-- Suite-owned proxy for the documented ADDON content/ESC menu contract. It
-- owns no feature visibility state; V3 UIHostManager remains the Authority.
------------------------------------------------------------------------
if ReplicatedSuite == nil then return end
local S = ReplicatedSuite

S.NativeEscBridge = { version = 1, registrations = 0, failures = 0 }
local E = S.NativeEscBridge

local function Call(owner, methodName, ...)
    if owner == nil or type(owner[methodName]) ~= "function" then return false, tostring(methodName) .. " unavailable" end
    local method, args, count = owner[methodName], { ... }, select("#", ...)
    local ok, value = pcall(function() return method(owner, unpack(args, 1, count)) end)
    if ok ~= true then return false, tostring(value) end
    if value == false then return false, tostring(methodName) .. " returned false" end
    return true, value
end

function E:ResolveVisibility(requested, currentVisible)
    local kind = type(requested)
    if kind == "boolean" then return requested end
    if kind == "number" then return requested ~= 0 end
    if kind == "string" then
        local value = string.lower(requested)
        if value == "1" or value == "true" or value == "on" or value == "show" then return true end
        if value == "0" or value == "false" or value == "off" or value == "hide" then return false end
    end
    return currentVisible ~= true
end

function E:RegisterContent(contentId, widget, trigger)
    contentId = tonumber(contentId)
    if contentId == nil or widget == nil or type(trigger) ~= "function" then return false, "invalid content registration" end
    local ok, err = Call(ADDON, "RegisterContentWidget", contentId, widget)
    if ok ~= true then self.failures = self.failures + 1; return false, err end
    ok, err = Call(ADDON, "RegisterContentTriggerFunc", contentId, trigger)
    if ok ~= true then self.failures = self.failures + 1; return false, err end
    self.registrations = self.registrations + 1
    return true
end

function E:RegisterButton(categoryId, contentId, iconKey, name)
    categoryId = tonumber(categoryId) or 3
    contentId = tonumber(contentId)
    if contentId == nil then return false, "invalid content id" end
    iconKey, name = tostring(iconKey or "info"), tostring(name or "Replicated Suite")
    local ok, err = Call(ADDON, "AddEscMenuButton", categoryId, contentId, iconKey, name)
    if ok ~= true then
        local config = { buttonType = 1, buttonValue = 1, colorKey = "situation_01" }
        ok, err = Call(ADDON, "AddEscMenuButton", categoryId, contentId, iconKey, name, config)
    end
    if ok ~= true then self.failures = self.failures + 1; return false, err end
    self.registrations = self.registrations + 1
    return true
end

function E:Describe()
    return { version = self.version, registrations = self.registrations, failures = self.failures }
end
