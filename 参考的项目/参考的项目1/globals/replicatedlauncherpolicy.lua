------------------------------------------------------------------------
-- Replicated shared combat launcher visibility policy
-- Author: Replicated
--
-- This object owns only visibility of the independent combat HUD launchers.
-- DPS / Healer / Gear / Plates remain the Authority for their own runtime,
-- windows and settings. Replicated Suite is only the policy UI / persistence
-- Proxy that toggles this shared visibility flag.
------------------------------------------------------------------------

ReplicatedCombatLauncherPolicy = ReplicatedCombatLauncherPolicy or {}
local P = ReplicatedCombatLauncherPolicy

P.entries = type(P.entries) == "table" and P.entries or {}
-- Replicated Suite is the canonical launcher entry in the bundled package.
-- Keep independent combat launchers hidden until Suite explicitly enables them.
-- Cross-addon control uses native ADDON content triggers; this shared table is
-- only a same-environment fast path and must never default the launchers on.
if P.visible == nil then P.visible = false end
P.claimed = P.claimed == true

local function ApplyWidget(widget, visible)
    if widget == nil or type(widget.Show) ~= "function" then return false end
    local ok = pcall(function() widget:Show(visible == true) end)
    return ok == true
end

function P:Register(key, widget)
    key = tostring(key or "")
    if key == "" or widget == nil then return false end
    self.entries[key] = widget
    -- Until Suite explicitly claims this policy, the bundled default is hidden.
    -- This also fixes addon-isolated Lua environments where each addon gets its
    -- own copy of this helper and therefore cannot inherit Suite state directly.
    return ApplyWidget(widget, self.claimed == true and self.visible == true)
end

function P:Unregister(key, widget)
    key = tostring(key or "")
    if key == "" then return end
    if widget == nil or self.entries[key] == widget then self.entries[key] = nil end
end

function P:SetVisible(visible)
    self.claimed = true
    self.visible = visible == true
    for key, widget in pairs(self.entries) do
        if not ApplyWidget(widget, self.visible) then
            -- A stale widget from a prior reload must not keep producing work.
            self.entries[key] = nil
        end
    end
    return self.visible
end

function P:IsVisible()
    return self.visible == true
end


------------------------------------------------------------------------
-- Replicated ESC menu compatibility policy
--
-- Each addon remains Authority for its own window visibility and refresh.
-- The native ESC content entry is only an open/close Proxy. The bundled RU
-- z_api_functions contract exposes ADDON:AddEscMenuButton.
-- Newer server builds may also accept an additional button-config table, but
-- the user's current client already accepts the documented four-argument form.
-- We therefore keep that proven path first and only try the optional config
-- form as a fallback. No non-whitelisted X2 UI API is called.
------------------------------------------------------------------------
ReplicatedEscMenuPolicy = ReplicatedEscMenuPolicy or {}
local E = ReplicatedEscMenuPolicy

local function EscAction(owner, methodName, ...)
    if owner == nil or type(owner[methodName]) ~= "function" then
        return false, tostring(methodName) .. " unavailable"
    end
    local method = owner[methodName]
    local args = { ... }
    local argCount = select("#", ...)
    local ok, value = pcall(function() return method(owner, unpack(args, 1, argCount)) end)
    if not ok then return false, tostring(value) end
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
    -- Normal ESC buttons on some client builds invoke the content trigger
    -- without a visibility argument.  In that case the only deterministic
    -- behaviour is to toggle the addon's authoritative current state.
    return currentVisible ~= true
end

function E:RegisterContent(contentId, widget, trigger)
    contentId = tonumber(contentId)
    if contentId == nil or widget == nil or type(trigger) ~= "function" then
        return false, "invalid content registration"
    end
    local widgetOk, widgetErr = EscAction(ADDON, "RegisterContentWidget", contentId, widget)
    if not widgetOk then return false, widgetErr end
    local triggerOk, triggerErr = EscAction(ADDON, "RegisterContentTriggerFunc", contentId, trigger)
    if not triggerOk then return false, triggerErr end
    return true
end

function E:RegisterButton(categoryId, contentId, iconKey, name)
    categoryId = tonumber(categoryId) or 3
    contentId = tonumber(contentId)
    if contentId == nil then return false, "invalid content id" end
    iconKey = tostring(iconKey or "info")
    name = tostring(name or "Replicated")

    local config = {
        buttonType = 1,
        buttonValue = 1,
        colorKey = "situation_01",
    }
    if ADDON == nil or type(ADDON.AddEscMenuButton) ~= "function" then
        return false, "AddEscMenuButton unavailable"
    end

    -- Use the proven four-argument contract first.  Only if the client rejects
    -- it do we retry with the newer optional config table. Both calls remain on
    -- the explicitly allowed ADDON:AddEscMenuButton boundary.
    local ok, err = EscAction(ADDON, "AddEscMenuButton", categoryId, contentId, iconKey, name)
    if not ok then
        ok, err = EscAction(ADDON, "AddEscMenuButton", categoryId, contentId, iconKey, name, config)
    end
    if ok then return true end
    return false, err or "AddEscMenuButton failed"
end
