------------------------------------------------------------------------
-- Replicated Suite V3 - Native ESC Bridge
--
-- Suite-owned generation-local Proxy for the documented ADDON content/ESC
-- integration. It owns registration transport/idempotency only; V3
-- UIHostManager remains the visibility Authority.
------------------------------------------------------------------------
if ReplicatedSuite == nil then return end
local S = ReplicatedSuite

S.NativeEscBridge = {
    version = 2,
    IdempotentRegistrationContractVersion = 1,
    registrations = 0,
    failures = 0,
    reuses = 0,
    partialRetries = 0,
    contentById = {},
    buttonById = {},
}
local E = S.NativeEscBridge

local function Call(owner, methodName, ...)
    if owner == nil or type(owner[methodName]) ~= "function" then return false, tostring(methodName) .. " unavailable" end
    local method, args, count = owner[methodName], { ... }, select("#", ...)
    local ok, value = pcall(function() return method(owner, unpack(args, 1, count)) end)
    if ok ~= true then return false, tostring(value) end
    if value == false then return false, tostring(methodName) .. " returned false" end
    return true, value
end

local function CountComplete(rows)
    local count = 0
    for _, row in pairs(rows or {}) do
        if type(row) == "table" and row.complete == true then count = count + 1 end
    end
    return count
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

    local row = self.contentById[contentId]
    if row ~= nil and row.widget ~= widget then
        self.failures = self.failures + 1
        return false, "content id already bound to another widget this generation"
    end
    if row ~= nil and row.complete == true then
        self.reuses = self.reuses + 1
        return true
    end
    if row == nil then
        row = { widget = widget, widgetRegistered = false, triggerRegistered = false, complete = false }
        self.contentById[contentId] = row
    elseif row.widgetRegistered == true or row.triggerRegistered == true then
        self.partialRetries = self.partialRetries + 1
    end

    local ok, err
    if row.widgetRegistered ~= true then
        ok, err = Call(ADDON, "RegisterContentWidget", contentId, widget)
        if ok ~= true then self.failures = self.failures + 1; return false, err end
        row.widgetRegistered = true
    end
    if row.triggerRegistered ~= true then
        ok, err = Call(ADDON, "RegisterContentTriggerFunc", contentId, trigger)
        if ok ~= true then self.failures = self.failures + 1; return false, err end
        row.triggerRegistered = true
    end

    row.trigger = trigger
    row.complete = true
    self.registrations = self.registrations + 1
    return true
end

function E:RegisterButton(categoryId, contentId, iconKey, name)
    categoryId = tonumber(categoryId) or 3
    contentId = tonumber(contentId)
    if contentId == nil then return false, "invalid content id" end
    iconKey, name = tostring(iconKey or "info"), tostring(name or "Replicated Suite")

    local row = self.buttonById[contentId]
    if row ~= nil then
        if row.categoryId ~= categoryId or row.iconKey ~= iconKey or row.name ~= name then
            self.failures = self.failures + 1
            return false, "content id already bound to another ESC button identity this generation"
        end
        if row.complete == true then
            self.reuses = self.reuses + 1
            return true
        end
        self.partialRetries = self.partialRetries + 1
    else
        row = { categoryId = categoryId, iconKey = iconKey, name = name, complete = false }
        self.buttonById[contentId] = row
    end

    local ok, err = Call(ADDON, "AddEscMenuButton", categoryId, contentId, iconKey, name)
    if ok ~= true then
        local config = { buttonType = 1, buttonValue = 1, colorKey = "situation_01" }
        ok, err = Call(ADDON, "AddEscMenuButton", categoryId, contentId, iconKey, name, config)
    end
    if ok ~= true then self.failures = self.failures + 1; return false, err end

    row.complete = true
    self.registrations = self.registrations + 1
    return true
end

function E:IsContentRegistered(contentId)
    local row = self.contentById[tonumber(contentId)]
    return type(row) == "table" and row.complete == true
end

function E:IsButtonRegistered(contentId)
    local row = self.buttonById[tonumber(contentId)]
    return type(row) == "table" and row.complete == true
end

function E:IsReady(contentId)
    return self:IsContentRegistered(contentId) and self:IsButtonRegistered(contentId)
end

function E:Describe(contentId)
    local id = tonumber(contentId)
    return {
        version = self.version,
        idempotentRegistrationContractVersion = self.IdempotentRegistrationContractVersion,
        registrations = self.registrations,
        failures = self.failures,
        reuses = self.reuses,
        partialRetries = self.partialRetries,
        contentRegistrations = CountComplete(self.contentById),
        buttonRegistrations = CountComplete(self.buttonById),
        requestedContentId = id,
        requestedReady = id ~= nil and self:IsReady(id) or nil,
    }
end
