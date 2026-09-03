ReplicatedSuiteModuleSandbox:Enter('gear', {'ReplicatedGear', 'ReplicatedGearConfig'})
------------------------------------------------------------------------
-- Replicated Gear - Stable visual UI
------------------------------------------------------------------------

if ReplicatedGear == nil or ReplicatedGear.BootError ~= nil or ReplicatedGear.Core == nil then return end
local G = ReplicatedGear
local C = G.Core

-- Hide widgets from an older hot-reload generation. ArcheRage keeps the old
-- physical widget IDs alive, so every new generation receives a unique suffix.
if type(G.UI) == "table" and type(G.UI.HideAll) == "function" then
    pcall(function() G.UI:HideAll() end)
end

G.UI = {
    windows = {},
    controls = {},
    quickButtons = {}, -- keyed by set id; each is an independent UIParent button
    setRows = {},
    itemRows = {},
    setPage = 1,
    selectedSetId = nil,
    draft = nil,
    draftDirty = false,
    activeSetId = nil,
    switchingSetId = nil,
    quickStatusText = "",
    deleteArmedId = nil,
    deleteArmedAt = 0,
}
local U = G.UI
local suffix = "_g" .. tostring(G.Generation)
local uiGeneration = G.Generation

local function Physical(id) return tostring(id) .. suffix end

local function RuntimeBusy()
    local runtime = G.Runtime
    return type(runtime) == "table"
        and runtime.generation == G.Generation
        and type(runtime.IsBusy) == "function"
        and runtime:IsBusy() == true
end

local function SuiteModuleEnabled()
    if ReplicatedSuiteEmbedded == true and ReplicatedSuite ~= nil and ReplicatedSuite.ModuleManager ~= nil then
        return ReplicatedSuite.ModuleManager:IsEnabled("gear")
    end
    return true
end


local function SafeHandler(widget, eventName, fn, label)
    widget:SetHandler(eventName, function(...)
        if G.Generation ~= uiGeneration then return nil end
        local args = { ... }
        local argCount = select("#", ...)
        local ok, result = xpcall(function() return fn(unpack(args, 1, argCount)) end, G.SafeTraceback)
        if not ok then
            G.SafeChat("UI错误 " .. tostring(label or eventName) .. "：" .. tostring(result))
            return nil
        end
        return result
    end)
end

local function SetPick(widget, enabled)
    if widget == nil then return end
    if widget.Enable ~= nil then widget:Enable(enabled ~= false) end
    if widget.EnablePick ~= nil then widget:EnablePick(enabled ~= false, true) end
    if widget.Clickable ~= nil then widget:Clickable(enabled ~= false, true) end
end

local function CreateBackground(parent, r, g, b, a)
    local bg = parent:CreateColorDrawable(r, g, b, a, "background")
    bg:AddAnchor("TOPLEFT", parent, 0, 0)
    bg:AddAnchor("BOTTOMRIGHT", parent, 0, 0)
    parent.rgRefs = parent.rgRefs or {}
    parent.rgRefs[#parent.rgRefs + 1] = bg
    return bg
end

local function StyleButton(button, width, height, fontSize)
    width, height = math.max(1, width or 90), math.max(1, height or 25)
    button.rgRefs = button.rgRefs or {}
    if button.rgRefs.states == nil then
        local colors = {
            { 0.14, 0.21, 0.29, 0.97 },
            { 0.23, 0.35, 0.47, 0.99 },
            { 0.08, 0.13, 0.19, 0.99 },
            { 0.08, 0.09, 0.11, 0.72 },
        }
        button.rgRefs.states = {}
        for index = 1, 4 do
            local c = colors[index]
            local bg = button:CreateColorDrawable(c[1], c[2], c[3], c[4], "background")
            bg:AddAnchor("TOPLEFT", button, 0, 0)
            bg:AddAnchor("BOTTOMRIGHT", button, 0, 0)
            button.rgRefs.states[index] = bg
        end
        button:SetNormalBackground(button.rgRefs.states[1])
        button:SetHighlightBackground(button.rgRefs.states[2])
        button:SetPushedBackground(button.rgRefs.states[3])
        button:SetDisabledBackground(button.rgRefs.states[4])
    end
    if button.SetAutoResize ~= nil then button:SetAutoResize(false) end
    button:SetExtent(width, height)
    if button.SetWidth ~= nil then button:SetWidth(width) end
    if button.SetHeight ~= nil then button:SetHeight(height) end
    if button.style ~= nil then
        button.style:SetFontSize(fontSize or 10)
        button.style:SetColor(0.96, 0.92, 0.82, 1)
        if button.style.SetEllipsis ~= nil then pcall(function() button.style:SetEllipsis(false) end) end
    end
end

local function CreateButton(parent, id, text, x, y, width, height, fontSize)
    local button = parent:CreateChildWidget("button", Physical(id), 0, true)
    button:SetText(text or "")
    StyleButton(button, width, height, fontSize)
    button:AddAnchor("TOPLEFT", parent, x, y)
    SetPick(button, true)
    button:Show(true)
    return button
end

local function CreateLabel(parent, id, text, x, y, width, height, fontSize, align)
    local label = parent:CreateChildWidget("label", Physical(id), 0, true)
    label:AddAnchor("TOPLEFT", parent, x, y)
    if label.SetAutoResize ~= nil then label:SetAutoResize(false) end
    label:SetExtent(width, height)
    if label.SetWidth ~= nil then label:SetWidth(width) end
    if label.SetHeight ~= nil then label:SetHeight(height) end
    label:EnablePick(false)
    if label.Clickable ~= nil then label:Clickable(false) end
    label.style:SetFontSize(fontSize or 10)
    label.style:SetAlign(align or ALIGN_LEFT)
    label.style:SetColor(1, 1, 1, 1)
    if label.style.SetEllipsis ~= nil then pcall(function() label.style:SetEllipsis(false) end) end
    label:SetText(text or "")
    label:Show(true)
    return label
end

local function CreateEditBox(parent, id, x, y, width, height, maxLength)
    if UOT_X2_EDITBOX == nil then error("UOT_X2_EDITBOX unavailable") end
    if parent == nil or type(parent.CreateChildWidgetByType) ~= "function" then error("CreateChildWidgetByType unavailable") end
    local edit = parent:CreateChildWidgetByType(UOT_X2_EDITBOX, Physical(id), 0, true)
    if edit == nil or type(edit.AddAnchor) ~= "function" or type(edit.SetExtent) ~= "function" then
        error("X2_EDITBOX creation returned an incompatible widget")
    end
    if edit.style == nil then error("X2_EDITBOX text style unavailable") end
    edit:SetExtent(width, height or 24)
    edit:SetInset(5, 5, 5, 5)
    edit:EnableFocus(true)
    if edit.UseSelectAllWhenFocused ~= nil then edit:UseSelectAllWhenFocused(true) end
    edit.style:SetAlign(ALIGN_LEFT)
    -- Do not inherit the client theme's "title" color here.  On some RU
    -- ArcheRage UI themes that key resolves to a very pale/low-contrast tint,
    -- making loadout names difficult to read.  Use an explicit high-contrast
    -- text color so both the new-set and editor name fields stay legible.
    edit.style:SetColor(1.00, 0.96, 0.84, 1.00)
    if maxLength ~= nil and edit.SetMaxTextLength ~= nil then edit:SetMaxTextLength(maxLength) end
    -- Do not use CreateDrawable("editbox_df") here.  In the RU ArcheRage
    -- client the generic Drawable returned by CreateDrawable does not expose
    -- Uibounds:AddAnchor, even though ColorDrawable does.  The older helper
    -- copied from a reference addon therefore crashes during UI creation.
    -- Use the same anchored ColorDrawable path as the rest of this UI.
    -- Give edit boxes a visible frame plus a near-black inner field.  This is
    -- intentionally stronger than the surrounding panel so the user can
    -- immediately identify where text is entered even on bright game scenes.
    local border = edit:CreateColorDrawable(0.34, 0.43, 0.52, 0.98, "background")
    if border ~= nil and border.AddAnchor ~= nil then
        border:AddAnchor("TOPLEFT", edit, 0, 0)
        border:AddAnchor("BOTTOMRIGHT", edit, 0, 0)
        edit.rgBorder = border
    end
    local bg = edit:CreateColorDrawable(0.015, 0.022, 0.032, 0.995, "background")
    if bg ~= nil and bg.AddAnchor ~= nil then
        bg:AddAnchor("TOPLEFT", edit, 1, 1)
        bg:AddAnchor("BOTTOMRIGHT", edit, -1, -1)
        edit.rgBg = bg
    end
    edit:AddAnchor("TOPLEFT", parent, x, y)
    edit:Show(true)
    return edit
end

local function CreateWindow(id, width, height, x, y)
    if type(CreateEmptyWindow) ~= "function" then error("CreateEmptyWindow unavailable; globals/window.lua not loaded") end
    local window = CreateEmptyWindow(Physical(id), "UIParent")
    if window == nil or type(window.AddAnchor) ~= "function" then error("CreateEmptyWindow returned an incompatible window") end
    window:SetExtent(width, height)
    if window.SetUILayer ~= nil then pcall(function() window:SetUILayer("system") end) end
    SetPick(window, true)
    window:AddAnchor("TOPLEFT", "UIParent", x or 0, y or 0)
    if window.CorrectOffsetByScreen ~= nil then pcall(function() window:CorrectOffsetByScreen() end) end
    CreateBackground(window, 0.025, 0.035, 0.052, 0.95)
    window:Show(false)
    return window
end

local function GetScale()
    if UIParent ~= nil and UIParent.GetUIScale ~= nil then
        local ok, value = pcall(function() return UIParent:GetUIScale() end)
        if ok and tonumber(value) and tonumber(value) > 0 then return tonumber(value) end
    end
    if UI ~= nil and UI.GetUIScale ~= nil then
        local ok, value = pcall(function() return UI:GetUIScale() end)
        if ok and tonumber(value) and tonumber(value) > 0 then return tonumber(value) end
    end
    return 1
end

local function GetLogicalWidgetRect(widget)
    if widget == nil then return 0, 0, 1, 1 end
    if ReplicatedSuiteEmbedded == true and ReplicatedSuite ~= nil and ReplicatedSuite.Layout ~= nil
        and type(ReplicatedSuite.Layout.GetLogicalRect) == "function" then
        local ok, x, y, width, height = pcall(function() return ReplicatedSuite.Layout:GetLogicalRect(widget) end)
        if ok and tonumber(x) ~= nil and tonumber(y) ~= nil then
            return tonumber(x) or 0, tonumber(y) or 0, tonumber(width) or 1, tonumber(height) or 1
        end
    end
    local scale = GetScale()
    if type(widget.GetEffectiveOffset) == "function" then
        local ok, x, y = pcall(function() return widget:GetEffectiveOffset() end)
        if ok and tonumber(x) ~= nil and tonumber(y) ~= nil then
            local width, height = 1, 1
            if type(widget.GetEffectiveExtent) == "function" then
                local okExtent, w, h = pcall(function() return widget:GetEffectiveExtent() end)
                if okExtent then width, height = (tonumber(w) or scale) / scale, (tonumber(h) or scale) / scale end
            end
            return (tonumber(x) or 0) / scale, (tonumber(y) or 0) / scale, width, height
        end
    end
    local x, y = 0, 0
    if type(widget.GetOffset) == "function" then
        local ok, a, b = pcall(function() return widget:GetOffset() end)
        if ok then x, y = tonumber(a) or 0, tonumber(b) or 0 end
    end
    local width = type(widget.GetWidth) == "function" and tonumber(widget:GetWidth()) or 1
    local height = type(widget.GetHeight) == "function" and tonumber(widget:GetHeight()) or 1
    return x, y, width or 1, height or 1
end

local function StorePosition(name, widget)
    local state = C:GetUiState(name)
    if type(state) ~= "table" or widget == nil then return end
    local x, y = GetLogicalWidgetRect(widget)
    state.x = math.floor((tonumber(x) or 0) + 0.5)
    state.y = math.floor((tonumber(y) or 0) + 0.5)
    C:Persist()
end

local function AttachDrag(window, handle, stateName)
    handle:EnableDrag(true)
    local dragKey = "gear_" .. tostring(stateName or "window")
    SafeHandler(handle, "OnDragStart", function(self)
        self.rgMoving = true
        self.rgSafeMoving = false
        if ReplicatedSuiteEmbedded == true and ReplicatedSuite ~= nil and ReplicatedSuite.Layout ~= nil
            and type(ReplicatedSuite.Layout.BeginSafeMove) == "function" then
            local ok, moved = pcall(function()
                return ReplicatedSuite.Layout:BeginSafeMove(dragKey, window, { clamp = true })
            end)
            self.rgSafeMoving = ok and moved == true
        end
        if self.rgSafeMoving ~= true then window:StartMoving() end
        return true
    end, stateName .. ":drag_start")
    SafeHandler(handle, "OnDragStop", function(self)
        if self.rgSafeMoving == true and ReplicatedSuite ~= nil and ReplicatedSuite.Layout ~= nil
            and type(ReplicatedSuite.Layout.EndSafeMove) == "function" then
            pcall(function() ReplicatedSuite.Layout:EndSafeMove(dragKey, false) end)
        else
            window:StopMovingOrSizing()
        end
        self.rgMoving = false
        self.rgSafeMoving = false
        if ReplicatedSuiteEmbedded == true and ReplicatedSuite ~= nil and ReplicatedSuite.Layout ~= nil
            and type(ReplicatedSuite.Layout.EnsureWidgetVisible) == "function" then
            pcall(function() ReplicatedSuite.Layout:EnsureWidgetVisible(window, { onlyWhenVisible = true }) end)
        elseif window.CorrectOffsetByScreen ~= nil then
            pcall(function() window:CorrectOffsetByScreen() end)
        end
        StorePosition(stateName, window)
    end, stateName .. ":drag_stop")
end

function U:SetStatus(line1, line2)
    if self.controls.status1 then self.controls.status1:SetText(tostring(line1 or "")) end
    if self.controls.status2 then self.controls.status2:SetText(tostring(line2 or "")) end
end

function U:SetQuickStatus(text)
    self.quickStatusText = tostring(text or "")
    -- There is no shared quick panel anymore. Refresh only changes the text/state
    -- of independent floating loadout buttons and never moves them.
    if self._floatingReady == true and type(self.RefreshQuick) == "function" then
        pcall(function() self:RefreshQuick() end)
    end
end

function U:HideAll()
    for _, window in pairs(self.windows or {}) do pcall(function() window:Show(false) end) end
    for _, button in pairs(self.quickButtons or {}) do pcall(function() button:Show(false) end) end
    if self.controls and self.controls.launcher then pcall(function() self.controls.launcher:Show(false) end) end
end

local function CreateLauncher()
    local state = C:GetUiState("launcher") or { x = 300, y = 100 }
    local launcher = UIParent:CreateWidget("button", Physical("rg_launcher"), "UIParent", "")
    launcher:SetText("换装")
    StyleButton(launcher, 88, 26, 11)
    launcher:AddAnchor("TOPLEFT", "UIParent", tonumber(state.x) or 300, tonumber(state.y) or 100)
    if launcher.CorrectOffsetByScreen ~= nil then pcall(function() launcher:CorrectOffsetByScreen() end) end
    -- Persistent launcher must not cover native Backpack/Character windows.
    launcher:EnableDrag(true)
    SetPick(launcher, true)
    launcher:Show(false)
    U.controls.launcher = launcher
    if ReplicatedSuiteEmbedded ~= true and ReplicatedCombatLauncherPolicy ~= nil and type(ReplicatedCombatLauncherPolicy.Register) == "function" then
        ReplicatedCombatLauncherPolicy:Register("gear", launcher)
    else
        pcall(function() launcher:Show(false) end)
    end

    U.launcherVisible = U.launcherVisible == true
    local GEAR_LAUNCHER_CONTENT_ID = 91833
    if ReplicatedSuiteEmbedded ~= true and ADDON ~= nil then
        if type(ADDON.RegisterContentWidget) == "function" then
            pcall(function() ADDON:RegisterContentWidget(GEAR_LAUNCHER_CONTENT_ID, launcher) end)
        end
        if type(ADDON.RegisterContentTriggerFunc) == "function" then
            pcall(function()
                ADDON:RegisterContentTriggerFunc(GEAR_LAUNCHER_CONTENT_ID, function(show)
                    U.launcherVisible = show == true
                    launcher:Show(U.launcherVisible)
                end)
            end)
        end
    end
    if ReplicatedSuiteEmbedded == true then U.launcherVisible = false end
    launcher:Show(U.launcherVisible == true)

    SafeHandler(launcher, "OnDragStart", function(self)
        self.rgMoving = true
        self.rgSafeMoving = false
        if ReplicatedSuiteEmbedded == true and ReplicatedSuite ~= nil and ReplicatedSuite.Layout ~= nil
            and type(ReplicatedSuite.Layout.BeginSafeMove) == "function" then
            local ok, moved = pcall(function()
                return ReplicatedSuite.Layout:BeginSafeMove("gear_launcher", self, { clamp = true })
            end)
            self.rgSafeMoving = ok and moved == true
        end
        if self.rgSafeMoving ~= true then self:StartMoving() end
        return true
    end, "launcher_drag_start")
    SafeHandler(launcher, "OnDragStop", function(self)
        if self.rgSafeMoving == true and ReplicatedSuite ~= nil and ReplicatedSuite.Layout ~= nil
            and type(ReplicatedSuite.Layout.EndSafeMove) == "function" then
            pcall(function() ReplicatedSuite.Layout:EndSafeMove("gear_launcher", false) end)
        else
            self:StopMovingOrSizing()
        end
        self.rgSafeMoving = false
        self.rgMoving = false
        self.rgIgnoreNextClick = true
        if ReplicatedSuiteEmbedded == true and ReplicatedSuite ~= nil and ReplicatedSuite.Layout ~= nil
            and type(ReplicatedSuite.Layout.EnsureWidgetVisible) == "function" then
            pcall(function() ReplicatedSuite.Layout:EnsureWidgetVisible(self, { onlyWhenVisible = true }) end)
        elseif self.CorrectOffsetByScreen ~= nil then
            pcall(function() self:CorrectOffsetByScreen() end)
        end
        StorePosition("launcher", self)
    end, "launcher_drag_stop")
    SafeHandler(launcher, "OnClick", function(self)
        if self.rgMoving then return end
        if self.rgIgnoreNextClick == true then
            self.rgIgnoreNextClick = false
            return
        end
        U:OpenConfig()
    end, "launcher_click")
end

local function StoreQuickButtonPosition(setId, widget)
    if widget == nil then return end
    local x, y = GetLogicalWidgetRect(widget)
    local logicalX = math.floor((tonumber(x) or 0) + 0.5)
    local logicalY = math.floor((tonumber(y) or 0) + 0.5)
    local ok, err = C:SetQuickButtonPosition(setId, logicalX, logicalY)
    if not ok then
        G.SafeChat("保存“" .. tostring(setId) .. "”按钮位置失败：" .. tostring(err or "unknown"))
    end
end

local function SnapQuickButtonToPeers(widget)
    if widget == nil then return false end
    if type(C.IsQuickButtonSnapEnabled) == "function" and C:IsQuickButtonSnapEnabled() ~= true then return false end
    local x, y, width, height = GetLogicalWidgetRect(widget)
    -- Gear quick buttons are fixed logical-size controls, so the snap radius uses
    -- the same logical coordinate basis rather than the Suite addon scale.
    local threshold = 18
    local bestX, bestY, bestDX, bestDY = x, y, threshold + 0.001, threshold + 0.001
    local function visible(button)
        if button == nil or button == widget then return false end
        if type(button.IsVisible) ~= "function" then return true end
        local ok, value = pcall(function() return button:IsVisible() end)
        return not ok or value == true
    end
    for _, other in pairs(U.quickButtons or {}) do
        if visible(other) then
            local ox, oy, ow, oh = GetLogicalWidgetRect(other)
            local verticalNear = (y < oy + oh + threshold) and (y + height > oy - threshold)
            local horizontalNear = (x < ox + ow + threshold) and (x + width > ox - threshold)
            if verticalNear then
                for _, candidate in ipairs({ox, ox + ow - width, ox + ow, ox - width}) do
                    local distance = math.abs(x - candidate)
                    if distance <= threshold and distance < bestDX then bestX, bestDX = candidate, distance end
                end
            end
            if horizontalNear then
                for _, candidate in ipairs({oy, oy + oh - height, oy + oh, oy - height}) do
                    local distance = math.abs(y - candidate)
                    if distance <= threshold and distance < bestDY then bestY, bestDY = candidate, distance end
                end
            end
        end
    end
    if bestDX > threshold and bestDY > threshold then return false end
    if type(widget.RemoveAllAnchors) == "function" then widget:RemoveAllAnchors() end
    widget:AddAnchor("TOPLEFT", "UIParent", math.floor(bestX + 0.5), math.floor(bestY + 0.5))
    if widget.CorrectOffsetByScreen ~= nil then pcall(function() widget:CorrectOffsetByScreen() end) end
    return true
end

local function FloatingButtonText(set)
    local name = tostring(set and set.name or "换装")
    if tostring(U.switchingSetId or "") == tostring(set and set.id or "") then
        local status = tostring(U.quickStatusText or "")
        if status ~= "" and status ~= "切换中" then
            return name .. " " .. status
        end
        return name .. " 切换"
    end
    if tostring(U.activeSetId or "") == tostring(set and set.id or "") then
        return "[" .. name .. "]"
    end
    return name
end

local FLOAT_BUTTON_WIDTH = 104
local FLOAT_BUTTON_HEIGHT = 26
local FLOAT_BUTTON_GAP_X = 4
local FLOAT_BUTTON_GAP_Y = 4
local FLOAT_SAFE_BASE_X = 300
local FLOAT_SAFE_BASE_Y = 100
local FLOAT_SAFE_MAX_COLUMNS = 4

local function GetLogicalScreenExtent()
    local width, height = nil, nil
    if UIParent ~= nil and type(UIParent.GetExtent) == "function" then
        local ok, w, h = pcall(function() return UIParent:GetExtent() end)
        if ok then width, height = tonumber(w), tonumber(h) end
    end
    if (width == nil or width <= 0) and UIParent ~= nil and type(UIParent.GetWidth) == "function" then
        local ok, value = pcall(function() return UIParent:GetWidth() end)
        if ok then width = tonumber(value) end
    end
    if (height == nil or height <= 0) and UIParent ~= nil and type(UIParent.GetHeight) == "function" then
        local ok, value = pcall(function() return UIParent:GetHeight() end)
        if ok then height = tonumber(value) end
    end
    local scale = GetScale()
    if (width == nil or width <= 0) and UI ~= nil and type(UI.GetScreenWidth) == "function" then
        local ok, value = pcall(function() return UI:GetScreenWidth() end)
        if ok and tonumber(value) then width = tonumber(value) / scale end
    end
    if (height == nil or height <= 0) and UI ~= nil and type(UI.GetScreenHeight) == "function" then
        local ok, value = pcall(function() return UI:GetScreenHeight() end)
        if ok and tonumber(value) then height = tonumber(value) / scale end
    end
    return math.max(320, tonumber(width) or 1024), math.max(240, tonumber(height) or 768)
end

local function IsFloatingPositionFullyVisible(x, y)
    local screenW, screenH = GetLogicalScreenExtent()
    local edge = 8
    x, y = tonumber(x), tonumber(y)
    if x == nil or y == nil then return false end
    return x >= edge and y >= edge
        and x + FLOAT_BUTTON_WIDTH <= screenW - edge
        and y + FLOAT_BUTTON_HEIGHT <= screenH - edge
end

local function SafeFloatingDefaultPosition(index)
    -- Embedded Suite mode delegates the safe discovery zone to the global
    -- Resolution Safety Authority. Standalone Gear keeps the same fallback
    -- algorithm so it remains usable outside the Suite.
    if ReplicatedSuiteEmbedded == true and ReplicatedSuite ~= nil and ReplicatedSuite.Layout ~= nil
        and type(ReplicatedSuite.Layout.GetSafeSpawn) == "function" then
        local ok, x, y = pcall(function()
            return ReplicatedSuite.Layout:GetSafeSpawn(index, FLOAT_BUTTON_WIDTH, FLOAT_BUTTON_HEIGHT, {
                baseX = FLOAT_SAFE_BASE_X, baseY = FLOAT_SAFE_BASE_Y,
                gapX = FLOAT_BUTTON_GAP_X, gapY = FLOAT_BUTTON_GAP_Y,
                maxColumns = FLOAT_SAFE_MAX_COLUMNS, edge = 8,
            })
        end)
        if ok and tonumber(x) ~= nil and tonumber(y) ~= nil then
            return math.floor(tonumber(x) + 0.5), math.floor(tonumber(y) + 0.5)
        end
    end
    local screenW, screenH = GetLogicalScreenExtent()
    local edge = 8
    local stepX = FLOAT_BUTTON_WIDTH + FLOAT_BUTTON_GAP_X
    local stepY = FLOAT_BUTTON_HEIGHT + FLOAT_BUTTON_GAP_Y
    local n = math.max(1, math.floor(tonumber(index) or 1)) - 1

    -- CryEngine resolution changes crop from the top-left coordinate origin.
    -- Therefore all untouched/new Gear buttons are born in a stable discovery
    -- zone around (300,100), instead of following a launcher or a previous
    -- large-resolution edge.  A compact grid keeps multiple new buttons visible
    -- and ready for the user's drag/snap layout.
    local maxBaseX = math.max(edge, screenW - FLOAT_BUTTON_WIDTH - edge)
    local maxBaseY = math.max(edge, screenH - FLOAT_BUTTON_HEIGHT - edge)
    local baseX = math.max(edge, math.min(FLOAT_SAFE_BASE_X, maxBaseX))
    local baseY = math.max(edge, math.min(FLOAT_SAFE_BASE_Y, maxBaseY))

    local columnsThatFit = math.floor((screenW - edge - baseX + FLOAT_BUTTON_GAP_X) / stepX)
    local cols = math.max(1, math.min(FLOAT_SAFE_MAX_COLUMNS, columnsThatFit))
    local col = n % cols
    local row = math.floor(n / cols)
    local x = baseX + col * stepX
    local y = baseY + row * stepY

    -- Extremely small resolutions or a very large number of sets can exhaust the
    -- preferred grid.  Keep the control fully visible rather than allowing a
    -- newly-created button to disappear outside the current crop.
    if x + FLOAT_BUTTON_WIDTH > screenW - edge then
        x = math.max(edge, screenW - FLOAT_BUTTON_WIDTH - edge)
    end
    if y + FLOAT_BUTTON_HEIGHT > screenH - edge then
        y = math.max(edge, screenH - FLOAT_BUTTON_HEIGHT - edge)
    end
    return math.floor(x + 0.5), math.floor(y + 0.5)
end

local function ResolveFloatingButtonPosition(set, index)
    local x, y, customized = C:GetQuickButtonPosition(set, index)
    if customized == true and tonumber(x) ~= nil and tonumber(y) ~= nil
        and IsFloatingPositionFullyVisible(x, y) then
        return tonumber(x), tonumber(y), true, false
    end
    -- Preserve an off-screen customized position in storage.  On this smaller
    -- resolution we only use the safe fallback for display; if the player later
    -- returns to the larger resolution the original layout can reappear.  A drag
    -- in the current resolution will explicitly save the new position.
    local safeX, safeY = SafeFloatingDefaultPosition(index)
    return safeX, safeY, false, customized == true
end

local function ApplyResolvedFloatingPosition(button, set, index, force)
    if button == nil then return end
    local x, y, _, fromOffscreenSaved = ResolveFloatingButtonPosition(set, index)
    local currentX, currentY = GetLogicalWidgetRect(button)
    local currentVisible = IsFloatingPositionFullyVisible(currentX, currentY)
    local differs = math.abs((tonumber(currentX) or 0) - (tonumber(x) or 0)) > 1
        or math.abs((tonumber(currentY) or 0) - (tonumber(y) or 0)) > 1
    local restoreAfterResolution = button.rgResolutionFallback == true and fromOffscreenSaved ~= true
    if force == true or currentVisible ~= true or fromOffscreenSaved == true or restoreAfterResolution then
        if differs or force == true then
            if type(button.RemoveAllAnchors) == "function" then button:RemoveAllAnchors() end
            button:AddAnchor("TOPLEFT", "UIParent", tonumber(x) or FLOAT_SAFE_BASE_X, tonumber(y) or FLOAT_SAFE_BASE_Y)
            if button.CorrectOffsetByScreen ~= nil then pcall(function() button:CorrectOffsetByScreen() end) end
        end
    end
    button.rgResolutionFallback = fromOffscreenSaved == true
end

local function EnsureFloatingButton(set, index)
    if type(set) ~= "table" then return nil end
    local key = tostring(set.id)
    local existing = U.quickButtons[key]
    if existing ~= nil then
        -- Resolution changes in CryEngine crop the existing UI from TOPLEFT.
        -- Revalidate already-created controls too; otherwise only buttons created
        -- after the resolution change would benefit from the safe spawn zone.
        ApplyResolvedFloatingPosition(existing, set, index, false)
        return existing
    end

    local physicalKey = tostring(set.storageId or set.id or index)
    local button = UIParent:CreateWidget("button", Physical("rg_float_" .. physicalKey), "UIParent", "")
    button.rgSetId = set.id
    if ReplicatedSuiteEmbedded == true then button.rsHudOwner = "gear_quick" end
    button:SetText(tostring(set.name or "换装"))
    StyleButton(button, 104, 26, 10)

    ApplyResolvedFloatingPosition(button, set, index, true)
    -- Floating loadout buttons are interactive HUD controls. In Suite mode
    -- persistent lock state belongs to HudManager; clicking remains available
    -- while drag movement is disabled.
    button:EnableDrag(not (ReplicatedSuiteEmbedded == true and U.suiteHudLocked == true))
    SetPick(button, true)
    button:Show(true)

    SafeHandler(button, "OnDragStart", function(self)
        if ReplicatedSuiteEmbedded == true and U.suiteHudLocked == true then return false end
        self.rgMoving = true
        self.rgSafeMoving = false
        if ReplicatedSuiteEmbedded == true and ReplicatedSuite ~= nil and ReplicatedSuite.Layout ~= nil
            and type(ReplicatedSuite.Layout.BeginSafeMove) == "function" then
            local ok, moved = pcall(function()
                return ReplicatedSuite.Layout:BeginSafeMove("gear_quick_" .. tostring(self.rgSetId or key), self, { clamp = true })
            end)
            self.rgSafeMoving = ok and moved == true
        end
        if self.rgSafeMoving ~= true then self:StartMoving() end
        return true
    end, "float_drag_start_" .. key)

    SafeHandler(button, "OnDragStop", function(self)
        if self.rgSafeMoving == true and ReplicatedSuite ~= nil and ReplicatedSuite.Layout ~= nil
            and type(ReplicatedSuite.Layout.EndSafeMove) == "function" then
            pcall(function()
                ReplicatedSuite.Layout:EndSafeMove("gear_quick_" .. tostring(self.rgSetId or key), false)
            end)
        else
            self:StopMovingOrSizing()
        end
        self.rgSafeMoving = false
        self.rgMoving = false
        self.rgIgnoreNextClick = true
        if ReplicatedSuiteEmbedded == true and ReplicatedSuite ~= nil and ReplicatedSuite.Layout ~= nil then
            pcall(function() ReplicatedSuite.Layout:SnapAndStore({}, self) end)
        end
        -- Gear buttons also snap to one another even when the global HUD editor
        -- is not the active page. This runs only on drag stop (never in Tick),
        -- so up to 40 loadout buttons remain negligible during combat.
        SnapQuickButtonToPeers(self)
        if self.CorrectOffsetByScreen ~= nil then pcall(function() self:CorrectOffsetByScreen() end) end
        StoreQuickButtonPosition(self.rgSetId, self)
        self.rgResolutionFallback = false
    end, "float_drag_stop_" .. key)

    SafeHandler(button, "OnClick", function(self)
        if self.rgMoving then return end
        -- Some ArcheRage UI builds emit a click immediately after a drag stop.
        -- Consume that one click so moving a loadout button never changes gear.
        if self.rgIgnoreNextClick == true then
            self.rgIgnoreNextClick = false
            return
        end
        if self.rgSetId ~= nil and G.Runtime ~= nil then
            G.Runtime:Start(self.rgSetId)
        end
    end, "float_click_" .. key)

    U.quickButtons[key] = button
    return button
end

local function CreateConfigWindow()
    local state = C:GetUiState("config") or { x = 190, y = 105 }
    local window = CreateWindow("rg_config", 720, 560, tonumber(state.x) or 190, tonumber(state.y) or 105)
    U.windows.config = window
    if window.SetCloseOnEscape ~= nil then window:SetCloseOnEscape(true) end

    local headerBg = window:CreateColorDrawable(0.08, 0.15, 0.23, 0.98, "background")
    headerBg:AddAnchor("TOPLEFT", window, 0, 0)
    headerBg:SetExtent(720, 36)
    U.controls.configHeaderBg = headerBg

    U.controls.configTitle = CreateLabel(window, "rg_config_title", "Replicated Gear 配置", 10, 7, 620, 22, 13, ALIGN_LEFT)
    U.controls.configClose = CreateButton(window, "rg_config_close", "X", 686, 5, 27, 24, 10)
    local drag = UIParent:CreateWidget("emptywidget", Physical("rg_config_drag"), window)
    drag:AddAnchor("TOPLEFT", window, 0, 0)
    drag:SetExtent(670, 36)
    drag:Show(true)
    SetPick(drag, true)
    AttachDrag(window, drag, "config")
    U.controls.configDrag = drag

    local divider = window:CreateColorDrawable(0.20, 0.28, 0.36, 0.65, "artwork")
    divider:AddAnchor("TOPLEFT", window, 202, 42)
    divider:SetExtent(1, 507)
    U.controls.divider = divider

    CreateLabel(window, "rg_list_title", "换装方案", 10, 45, 180, 20, 11, ALIGN_LEFT)
    CreateLabel(window, "rg_new_name_label", "名称", 10, 73, 34, 20, 10, ALIGN_LEFT)
    U.controls.newName = CreateEditBox(window, "rg_new_name", 45, 70, 91, 25, 24)
    U.controls.newButton = CreateButton(window, "rg_new_button", "新建", 141, 70, 52, 25, 10)

    for index = 1, 10 do
        local row = CreateButton(window, "rg_set_row_" .. tostring(index), "", 10, 104 + (index - 1) * 31, 183, 27, 10)
        row.rgSetId = nil
        U.setRows[index] = row
        SafeHandler(row, "OnClick", function(self)
            if self.rgSetId ~= nil then U:SelectSet(self.rgSetId) end
        end, "set_row_" .. tostring(index))
    end

    U.controls.setPrev = CreateButton(window, "rg_set_prev", "<", 10, 420, 34, 24, 10)
    U.controls.setPage = CreateLabel(window, "rg_set_page", "1/1", 50, 422, 80, 20, 9, ALIGN_CENTER)
    U.controls.setNext = CreateButton(window, "rg_set_next", ">", 136, 420, 34, 24, 10)

    CreateLabel(window, "rg_hint_1", "每套方案会生成一个可自由拖动的独立按钮", 10, 461, 184, 18, 9, ALIGN_LEFT)
    CreateLabel(window, "rg_hint_2", "新建 > 获取当前配置 > 保存 > 拖动按钮到合适位置", 10, 481, 184, 18, 9, ALIGN_LEFT)

    local rx = 216
    CreateLabel(window, "rg_editor_name_label", "名称", rx, 48, 40, 20, 10, ALIGN_LEFT)
    U.controls.editorName = CreateEditBox(window, "rg_editor_name", rx + 43, 44, 190, 26, 24)
    U.controls.quickToggle = CreateButton(window, "rg_quick_toggle", "显示按钮：开", rx + 241, 44, 100, 26, 9)
    U.controls.moveUp = CreateButton(window, "rg_move_up", "上移", rx + 347, 44, 54, 26, 9)
    U.controls.moveDown = CreateButton(window, "rg_move_down", "下移", rx + 407, 44, 54, 26, 9)

    -- Keep the editor header compact. Title participation is presented as one
    -- more managed row beside the equipment list instead of a separate banner.
    U.controls.captureState = CreateLabel(window, "rg_capture_state", "请选择一个换装方案", rx, 80, 460, 20, 9, ALIGN_LEFT)

    CreateLabel(window, "rg_items_heading", "已保存装备（√=参与 X=忽略）", rx, 106, 210, 20, 11, ALIGN_LEFT)
    -- Five managed presets on one row. Heading width 210 keeps the row inside
    -- the 720px window: buttons span rx+218..rx+484 (=700 <= 720-16 edge).
    U.controls.manageAll = CreateButton(window, "rg_manage_all", "全选", rx + 218, 104, 44, 24, 9)
    U.controls.manageWeapons = CreateButton(window, "rg_manage_weapons", "仅武器", rx + 265, 104, 52, 24, 9)
    U.controls.manageArmor = CreateButton(window, "rg_manage_armor", "防具饰品", rx + 320, 104, 62, 24, 9)
    U.controls.manageTitle = CreateButton(window, "rg_manage_title", "仅称号", rx + 385, 104, 52, 24, 9)
    U.controls.manageNone = CreateButton(window, "rg_manage_none", "清空", rx + 440, 104, 44, 24, 9)

    local equipmentStartY = 132
    for index, slotDef in ipairs(C.EquipmentSlots) do
        local col = index <= 10 and 0 or 1
        local rowIndex = col == 0 and index - 1 or index - 11
        local x = rx + col * 238
        local y = equipmentStartY + rowIndex * 28
        local panel = UIParent:CreateWidget("emptywidget", Physical("rg_item_panel_" .. tostring(index)), window)
        panel:AddAnchor("TOPLEFT", window, x, y)
        panel:SetExtent(226, 24)
        panel:Show(true)
        panel:EnablePick(false)
        local bg = panel:CreateColorDrawable(0.055, 0.075, 0.10, 0.86, "background")
        bg:AddAnchor("TOPLEFT", panel, 0, 0)
        bg:AddAnchor("BOTTOMRIGHT", panel, 0, 0)
        local label = CreateLabel(panel, "rg_item_label_" .. tostring(index), slotDef.name .. "：未读取", 5, 2, 181, 19, 9, ALIGN_LEFT)
        local toggle = CreateButton(panel, "rg_item_toggle_" .. tostring(index), "-", 190, 1, 31, 22, 9)
        toggle.rgSlot = slotDef.slot
        SafeHandler(toggle, "OnClick", function(self) U:ToggleManagedSlot(self.rgSlot) end, "item_toggle_" .. tostring(index))
        U.itemRows[index] = { panel = panel, label = label, toggle = toggle, slot = slotDef }
    end

    -- Title uses the exact same visual language as an equipment slot and sits
    -- directly below the right-column outfit/battle-costume row. This makes the
    -- managed-state meaning consistent: √ participates, — is ignored.
    local titlePanel = UIParent:CreateWidget("emptywidget", Physical("rg_title_panel"), window)
    titlePanel:AddAnchor("TOPLEFT", window, rx + 238, equipmentStartY + 9 * 28)
    titlePanel:SetExtent(226, 24)
    titlePanel:Show(true)
    titlePanel:EnablePick(false)
    local titleBg = titlePanel:CreateColorDrawable(0.055, 0.075, 0.10, 0.86, "background")
    titleBg:AddAnchor("TOPLEFT", titlePanel, 0, 0)
    titleBg:AddAnchor("BOTTOMRIGHT", titlePanel, 0, 0)
    U.controls.titlePanel = titlePanel
    U.controls.titleLabel = CreateLabel(titlePanel, "rg_title_label", "称号：未读取", 5, 2, 181, 19, 9, ALIGN_LEFT)
    U.controls.titleToggle = CreateButton(titlePanel, "rg_title_toggle", "-", 190, 1, 31, 22, 9)

    U.controls.status1 = CreateLabel(window, "rg_status_1", "", rx, 416, 460, 20, 9, ALIGN_LEFT)
    U.controls.status2 = CreateLabel(window, "rg_status_2", "", rx, 437, 460, 20, 9, ALIGN_LEFT)

    U.controls.captureButton = CreateButton(window, "rg_capture", "获取当前配置", rx, 468, 118, 30, 10)
    U.controls.saveButton = CreateButton(window, "rg_save", "保存", rx + 126, 468, 78, 30, 10)
    U.controls.swapButton = CreateButton(window, "rg_swap", "立即换装", rx + 212, 468, 92, 30, 10)
    U.controls.deleteButton = CreateButton(window, "rg_delete", "删除", rx + 312, 468, 72, 30, 10)
    U.controls.discardButton = CreateButton(window, "rg_discard", "放弃修改", rx + 392, 468, 92, 30, 9)

    SafeHandler(U.controls.configClose, "OnClick", function() window:Show(false) end, "config_close")
    SafeHandler(U.controls.newButton, "OnClick", function() U:CreateNewSet() end, "new_set")
    SafeHandler(U.controls.manageAll, "OnClick", function() U:SetManagedPreset("ALL") end, "manage_all")
    SafeHandler(U.controls.manageWeapons, "OnClick", function() U:SetManagedPreset("WEAPON") end, "manage_weapons")
    SafeHandler(U.controls.manageArmor, "OnClick", function() U:SetManagedPreset("ARMOR") end, "manage_armor")
    SafeHandler(U.controls.manageTitle, "OnClick", function() U:SetManagedPreset("TITLE") end, "manage_title")
    SafeHandler(U.controls.manageNone, "OnClick", function() U:SetManagedPreset("NONE") end, "manage_none")
    SafeHandler(U.controls.setPrev, "OnClick", function()
        U.setPage = math.max(1, U.setPage - 1)
        U:RefreshSetList()
    end, "set_prev")
    SafeHandler(U.controls.setNext, "OnClick", function()
        U.setPage = U.setPage + 1
        U:RefreshSetList()
    end, "set_next")
    SafeHandler(U.controls.quickToggle, "OnClick", function()
        if U.draft == nil then return end
        U.draft.quick = U.draft.quick == false
        U.draftDirty = true
        U:RefreshEditor()
        U:SetStatus("快捷显示已修改", "点击保存后生效")
    end, "quick_toggle")
    SafeHandler(U.controls.titleToggle, "OnClick", function()
        if U.draft == nil or type(U.draft.title) ~= "table" then return end
        local canApply = U.draft.title.effect and U.draft.title.effect.id ~= nil
        if not canApply then
            U:SetStatus("当前配置没有可切换的称号信息", "请先在游戏中选择称号后重新获取当前配置")
            return
        end
        U.draft.title.apply = U.draft.title.apply ~= true
        U.draftDirty = true
        U:RefreshEditor()
        U:SetStatus("称号跟随已修改", "点击保存后生效")
    end, "title_toggle")
    SafeHandler(U.controls.moveUp, "OnClick", function()
        if RuntimeBusy() then U:SetStatus("换装正在执行", "请等待完成后再调整方案顺序") return end
        if U.selectedSetId then
            local ok, err = C:MoveSet(U.selectedSetId, -1)
            if not ok then
                U:SetStatus("上移失败：" .. tostring(err or "unknown"), "")
            else
                U:EnsureSelectedSetPage()
            end
            U:RefreshAll()
        end
    end, "move_up")
    SafeHandler(U.controls.moveDown, "OnClick", function()
        if RuntimeBusy() then U:SetStatus("换装正在执行", "请等待完成后再调整方案顺序") return end
        if U.selectedSetId then
            local ok, err = C:MoveSet(U.selectedSetId, 1)
            if not ok then
                U:SetStatus("下移失败：" .. tostring(err or "unknown"), "")
            else
                U:EnsureSelectedSetPage()
            end
            U:RefreshAll()
        end
    end, "move_down")
    SafeHandler(U.controls.captureButton, "OnClick", function() U:CaptureCurrent() end, "capture")
    SafeHandler(U.controls.saveButton, "OnClick", function() U:SaveDraft() end, "save")
    SafeHandler(U.controls.swapButton, "OnClick", function()
        if U.selectedSetId == nil then return end
        if U:HasUnsavedChanges() then
            U:SetStatus("当前编辑内容还没有保存", "请先点击“保存”再立即换装")
            return
        end
        if G.Runtime then G.Runtime:Start(U.selectedSetId) end
    end, "swap")
    SafeHandler(U.controls.deleteButton, "OnClick", function() U:DeleteSelected() end, "delete")
    SafeHandler(U.controls.discardButton, "OnClick", function() U:DiscardDraft() end, "discard")

    window:Show(false)
end

function U:HasUnsavedChanges()
    if self.draft == nil then return false end
    if self.draftDirty == true then return true end
    if self.controls.editorName ~= nil then
        local edited = tostring(self.controls.editorName:GetText() or "")
        local saved = tostring(self.draft.name or "")
        if edited ~= saved then return true end
    end
    return false
end

function U:DiscardDraft()
    if RuntimeBusy() then
        self:SetStatus("换装正在执行", "请等待完成后再修改编辑状态")
        return
    end
    if self.selectedSetId == nil then return end
    local draft = C:GetSetCopy(self.selectedSetId)
    if draft == nil then return end
    self.draft = draft
    self.draftDirty = false
    self.controls.editorName:SetText(draft.name or "")
    self:RefreshEditor()
    self:SetStatus("已放弃未保存修改", "当前显示的是上一次已保存配置")
end

function U:CreateNewSet()
    if RuntimeBusy() then
        self:SetStatus("换装正在执行", "请等待完成后再新建换装")
        return
    end
    if self:HasUnsavedChanges() then
        self:SetStatus("当前换装还有未保存修改", "请先保存或点击“放弃修改”，再新建换装")
        return
    end
    local name = self.controls.newName:GetText()
    local set, err = C:CreateSet(name)
    if set == nil then
        self:SetStatus("新建失败：" .. tostring(err or "未知错误"), "")
        return
    end
    self.controls.newName:SetText("")
    self.setPage = math.max(1, math.ceil(#C:GetSets(true) / 10))
    self:RefreshSetList()
    self:SelectSet(set.id)
    self:SetStatus("已新建“" .. tostring(set.name) .. "”", "请穿好装备和称号，然后点击“获取当前配置”")
end

function U:EnsureSelectedSetPage()
    if self.selectedSetId == nil then return end
    local sets = C:GetSets(true)
    for index, set in ipairs(sets) do
        if tostring(set.id) == tostring(self.selectedSetId) then
            self.setPage = math.max(1, math.ceil(index / 10))
            return
        end
    end
end

function U:SelectSet(id)
    if RuntimeBusy() and self.selectedSetId ~= nil and tostring(id) ~= tostring(self.selectedSetId) then
        self:SetStatus("换装正在执行", "请等待完成后再切换编辑中的方案")
        return
    end
    if self.selectedSetId ~= nil and tostring(id) ~= tostring(self.selectedSetId) and self:HasUnsavedChanges() then
        self:SetStatus("当前换装还有未保存修改", "请先保存或点击“放弃修改”，再切换到其他方案")
        return
    end
    local draft = C:GetSetCopy(id)
    if draft == nil then return end
    self.selectedSetId = draft.id
    self:EnsureSelectedSetPage()
    self.draft = draft
    self.draftDirty = false
    self.deleteArmedId = nil
    self.controls.editorName:SetText(draft.name or "")
    self:RefreshSetList()
    self:RefreshEditor()
    if draft.configured then
        self:SetStatus("已加载“" .. tostring(draft.name) .. "”", "需要更新时：穿好装备/称号 > 获取当前配置 > 保存")
    else
        self:SetStatus("“" .. tostring(draft.name) .. "”尚未配置", "穿好装备和称号后点击“获取当前配置”并保存；未配置方案不会生成悬浮换装按钮")
    end
end

function U:CaptureCurrent()
    if RuntimeBusy() then
        self:SetStatus("换装正在执行，不能读取当前配置", "避免把切换到一半的装备保存成套装")
        return
    end
    if self.selectedSetId == nil then
        self:SetStatus("请先新建或选择一个换装方案", "")
        return
    end
    local draft, err = C:CaptureDraft(self.selectedSetId)
    if draft == nil then
        self:SetStatus("读取当前配置失败：" .. tostring(err or "未知错误"), "")
        return
    end
    draft.name = self.controls.editorName:GetText()
    if self.draft and self.draft.quick == false then draft.quick = false end
    if self.draft and type(self.draft.title) == "table" and self.draft.title.apply == false and type(draft.title) == "table" then
        draft.title.apply = false
    end
    self.draft = draft
    self.draftDirty = true
    self:RefreshEditor()
    self:SetStatus("已读取当前装备和当前称号", "可用“全选 / 仅武器 / 清空”或逐个部位选择参与换装，再点击“保存”")
end

function U:SaveDraft()
    if RuntimeBusy() then
        self:SetStatus("换装正在执行", "请等待完成后再保存配置")
        return
    end
    if self.draft == nil then
        self:SetStatus("没有可保存的换装方案", "")
        return
    end
    self.draft.name = self.controls.editorName:GetText()
    local ok, err = C:CommitPayloadDraft(self.draft, "standalone_save")
    if not ok then
        self:SetStatus("保存失败：" .. tostring(err or "未知错误"), "")
        return
    end
    self.draft = C:GetSetCopy(self.draft.id)
    self.selectedSetId = self.draft.id
    self.draftDirty = false
    self:RefreshAll()
    self:SetStatus("已保存“" .. tostring(self.draft.name) .. "” · 管理 " .. tostring(C:CountManagedItems(self.draft)) .. " 个部位", "独立按钮只会改变这些参与部位，可与任意皮甲/板甲组合使用")
end

function U:DeleteSelected()
    if RuntimeBusy() then
        self:SetStatus("换装正在执行", "请等待完成后再删除方案")
        return
    end
    if self.selectedSetId == nil then return end
    local now = G.NowMs()
    if self.deleteArmedId ~= self.selectedSetId or now - (self.deleteArmedAt or 0) > 3000 then
        self.deleteArmedId = self.selectedSetId
        self.deleteArmedAt = now
        self:SetStatus("再次点击“删除”确认删除当前换装", "3秒内有效")
        return
    end
    local oldId = self.selectedSetId
    local oldIndex = 1
    for index, set in ipairs(C:GetSets(true)) do
        if tostring(set.id) == tostring(oldId) then oldIndex = index break end
    end
    local deleted, deleteErr = C:DeleteSet(oldId)
    if not deleted then
        self:SetStatus("删除失败：" .. tostring(deleteErr or "unknown"), "")
        return
    end
    self.selectedSetId = nil
    self.draft = nil
    self.draftDirty = false
    self.deleteArmedId = nil
    local sets = C:GetSets(true)
    if #sets > 0 then
        local nextIndex = math.max(1, math.min(#sets, oldIndex))
        self:SelectSet(sets[nextIndex].id)
    else
        self:RefreshAll()
    end
    self:SetStatus("换装方案已删除", "")
end

function U:RefreshSetList()
    -- Suite-embedded mode does not create the legacy standalone config window.
    if self.controls.setPage == nil then return end
    local busy = RuntimeBusy()
    if self.controls.newName and self.controls.newName.Enable then self.controls.newName:Enable(not busy) end
    if self.controls.newButton and self.controls.newButton.Enable then self.controls.newButton:Enable(not busy) end
    local sets = C:GetSets(true)
    local totalPages = math.max(1, math.ceil(#sets / 10))
    self.setPage = math.max(1, math.min(self.setPage, totalPages))
    local offset = (self.setPage - 1) * 10
    for index, row in ipairs(self.setRows) do
        local set = sets[offset + index]
        if set ~= nil then
            row.rgSetId = set.id
            local prefix = tostring(set.id) == tostring(self.selectedSetId) and "> " or "  "
            local suffixText = set.configured == true and "" or " [未配置]"
            row:SetText(prefix .. tostring(set.name) .. suffixText)
            row:Show(true)
            row:Enable(not busy)
        else
            row.rgSetId = nil
            row:SetText("")
            row:Show(false)
        end
    end
    self.controls.setPage:SetText(tostring(self.setPage) .. "/" .. tostring(totalPages))
    self.controls.setPrev:Enable(self.setPage > 1)
    self.controls.setNext:Enable(self.setPage < totalPages)
end

function U:SetManagedPreset(mode)
    if self.draft == nil or RuntimeBusy() then return end
    local changed, titleMissing = C:ApplyManagedPreset(self.draft, mode)
    if changed then self.draftDirty = true end
    self:RefreshEditor()
    local count = C:CountManagedItems(self.draft)
    if mode == "WEAPON" then
        self:SetStatus("已选择武器部位：" .. tostring(count) .. " 个", "可继续点击单个部位右侧按钮进行增减")
    elseif mode == "ALL" then
        self:SetStatus("已选择全部非空装备：" .. tostring(count) .. " 个", "点击保存后该方案会管理这些部位")
    elseif mode == "ARMOR" then
        self:SetStatus("已选择防具/饰品：" .. tostring(count) .. " 个", "武器部位未选中，可再单独增减")
    elseif mode == "TITLE" then
        if titleMissing then
            self:SetStatus("当前配置没有可切换的称号信息", "请先在游戏中选择称号后重新获取当前配置")
        else
            self:SetStatus("已只保留称号参与", "换装时只切称号，不换装备")
        end
    else
        self:SetStatus("已清空参与部位", "现在只勾选这个按钮真正需要切换的 1～3 件装备即可")
    end
end

function U:ToggleManagedSlot(slot)
    if self.draft == nil or RuntimeBusy() then return end
    for _, item in ipairs(self.draft.items or {}) do
        if tonumber(item.slot) == tonumber(slot) then
            if item.empty == true then
                self:SetStatus(tostring(item.slotName or "该部位") .. "当前为空", "公开 API 无法可靠主动卸下该槽，因此空槽不能设为参与换装")
                return
            end
            item.managed = item.managed == false
            self.draftDirty = true
            self:RefreshEditor()
            self:SetStatus((item.managed == true and "已参与：" or "已忽略：") .. tostring(item.slotName or "装备"),
                "当前方案共管理 " .. tostring(C:CountManagedItems(self.draft)) .. " 个装备部位")
            return
        end
    end
    self:SetStatus("这个部位还没有读取", "请先点击“获取当前配置”")
end

function U:RefreshEditor()
    -- Suite owns the settings surface while embedded; legacy editor controls are
    -- intentionally absent. Domain state and floating quick buttons remain live.
    if self.controls.editorName == nil then return end
    local enabled = self.draft ~= nil
    local busy = RuntimeBusy()
    local editable = enabled and not busy
    for _, control in ipairs({
        self.controls.editorName, self.controls.quickToggle, self.controls.moveUp, self.controls.moveDown,
        self.controls.captureButton, self.controls.saveButton, self.controls.deleteButton, self.controls.discardButton,
        self.controls.manageAll, self.controls.manageWeapons, self.controls.manageNone,
    }) do
        if control and control.Enable then control:Enable(editable) end
    end
    if self.controls.swapButton ~= nil and self.controls.swapButton.Enable ~= nil then
        self.controls.swapButton:Enable(editable and SuiteModuleEnabled())
    end

    if not enabled then
        self.controls.editorName:SetText("")
        self.controls.quickToggle:SetText("显示按钮：-")
        self.controls.titleToggle:SetText("-")
        self.controls.titleToggle:Enable(false)
        self.controls.titleLabel:SetText("称号：未读取")
        self.controls.captureState:SetText("请选择一个换装方案")
        for index, row in ipairs(self.itemRows) do
            row.label:SetText(row.slot.name .. "：未读取")
            if row.toggle then row.toggle:SetText("-"); row.toggle:Enable(false) end
        end
        return
    end

    self.controls.quickToggle:SetText(self.draft.quick == false and "显示按钮：关" or "显示按钮：开")
    local title = self.draft.title
    self.controls.titleLabel:SetText("称号：" .. C:TitleText(title))
    local canApply = type(title) == "table" and title.effect and title.effect.id ~= nil
    self.controls.titleToggle:Enable(canApply == true and not busy)
    self.controls.titleToggle:SetText(canApply and (title.apply == true and "开" or "关") or "-")
    local managedCount = C:CountManagedItems(self.draft)
    self.controls.captureState:SetText(self.draft.configured == true and ("配置状态：已读取 · 参与 " .. tostring(managedCount) .. " 个部位") or "配置状态：尚未读取当前装备")

    local bySlot = {}
    for _, item in ipairs(self.draft.items or {}) do bySlot[tonumber(item.slot)] = item end
    for _, row in ipairs(self.itemRows) do
        local item = bySlot[tonumber(row.slot.slot)]
        if item == nil then
            row.label:SetText(row.slot.name .. "：未读取")
            if row.toggle then row.toggle:SetText("-"); row.toggle:Enable(false) end
        elseif item.empty == true then
            row.label:SetText(row.slot.name .. "：空（保持当前）")
            if row.toggle then row.toggle:SetText("-"); row.toggle:Enable(false) end
        else
            local grade = item.grade ~= nil and (" [G" .. tostring(item.grade) .. "]") or ""
            row.label:SetText(row.slot.name .. "：" .. tostring(item.name or "未知装备") .. grade)
            if row.toggle then
                row.toggle:SetText(item.managed == false and "X" or "√")
                row.toggle:Enable(not busy)
            end
        end
    end
end

function U:SetSuiteHudLocked(locked)
    self.suiteHudLocked = locked == true
    for _, button in pairs(self.quickButtons or {}) do
        if button ~= nil and type(button.EnableDrag) == "function" then
            pcall(function() button:EnableDrag(not self.suiteHudLocked) end)
        end
    end
    return true
end

function U:ApplySuiteQuickButtonPositions()
    local sets = C:GetSets(false)
    for index, set in ipairs(sets) do
        if set.quick ~= false then
            local button = self.quickButtons and self.quickButtons[tostring(set.id)] or nil
            if button ~= nil then
                ApplyResolvedFloatingPosition(button, set, index, true)
            end
        end
    end
    self:RefreshQuick()
    return true
end

function U:CaptureSuiteHudProfile(placement)
    if type(placement) ~= "table" then return false end
    local positions = {}
    for _, set in ipairs(C:GetSets(true)) do
        positions[tostring(set.id)] = {
            x = tonumber(set.quickX), y = tonumber(set.quickY),
            customized = set.quickPositionCustomized == true,
        }
    end
    placement.profileExtra = type(placement.profileExtra) == "table" and placement.profileExtra or {}
    placement.profileExtra.quickPositions = positions
    return true
end

function U:ApplySuiteHudProfile(placement)
    local extra = type(placement) == "table" and placement.profileExtra or nil
    local positions = type(extra) == "table" and extra.quickPositions or nil
    if type(positions) ~= "table" then return true end
    local changed = false
    for _, set in ipairs(C:GetSets(true)) do
        local saved = positions[tostring(set.id)]
        if type(saved) == "table" then
            local customized = saved.customized == true and tonumber(saved.x) ~= nil and tonumber(saved.y) ~= nil
            local nextX = customized and math.floor(tonumber(saved.x) + 0.5) or nil
            local nextY = customized and math.floor(tonumber(saved.y) + 0.5) or nil
            if set.quickPositionCustomized ~= customized or set.quickX ~= nextX or set.quickY ~= nextY then
                set.quickPositionCustomized = customized; set.quickX = nextX; set.quickY = nextY; changed = true
            end
        end
    end
    if changed then
        local ok, err = C:Persist()
        if not ok then return false, err end
    end
    return self:ApplySuiteQuickButtonPositions()
end

function U:ResetSuiteHudPosition()
    local changed = false
    for _, set in ipairs(C:GetSets(true)) do
        if set.quickPositionCustomized == true or set.quickX ~= nil or set.quickY ~= nil then
            set.quickPositionCustomized = false; set.quickX = nil; set.quickY = nil; changed = true
        end
    end
    if changed then
        local ok, err = C:Persist()
        if not ok then return false, err end
    end
    return self:ApplySuiteQuickButtonPositions()
end

function U:SetSuiteHudVisible(visible)
    self.suiteHudVisible = visible == true
    if self.suiteHudVisible ~= true then
        for _, button in pairs(self.quickButtons or {}) do
            if button ~= nil and type(button.Show) == "function" then button:Show(false) end
        end
        return true
    end
    if self._floatingReady == true then self:RefreshQuick() end
    return true
end

function U:RefreshQuick()
    if ReplicatedSuiteEmbedded == true and self.suiteHudVisible ~= true then
        for _, button in pairs(self.quickButtons or {}) do
            if button ~= nil and type(button.Show) == "function" then button:Show(false) end
        end
        self._floatingReady = true
        return
    end
    local allSets = C:GetSets(false)
    local seen = {}
    for index, set in ipairs(allSets) do
        local key = tostring(set.id)
        if set.quick ~= false then
            local button = EnsureFloatingButton(set, index)
            if button ~= nil then
                seen[key] = true
                button.rgSetId = set.id
                button:SetText(FloatingButtonText(set))
                button:Show(true)
                button:Enable(not RuntimeBusy())
            end
        end
    end
    for key, button in pairs(self.quickButtons or {}) do
        if seen[tostring(key)] ~= true then
            button:Show(false)
        end
    end
    self._floatingReady = true
end

function U:RefreshAll()
    if self.controls.configTitle ~= nil then
        self.controls.configTitle:SetText(SuiteModuleEnabled()
            and "Replicated Gear 配置"
            or "Replicated Gear · 当前模块未启用（方案仍可编辑）")
    end
    self:RefreshSetList()
    self:RefreshEditor()
    self:RefreshQuick()
end

function U:ShowConfig(show)
    local window = self.windows.config
    if window == nil then return end
    window:Show(show ~= false)
    if show ~= false then
        window:Raise()
        local sets = C:GetSets(true)
        if self.selectedSetId == nil and #sets > 0 then
            self:SelectSet(sets[1].id)
        else
            self:RefreshAll()
        end
    end
end

-- The old shared quick-panel no longer exists. The launcher is deliberately
-- open-only: clicking it can never hide/toggle the configuration window.
function U:OpenConfig()
    if ReplicatedSuiteEmbedded == true and ReplicatedSuite ~= nil and ReplicatedSuite.UI ~= nil then
        ReplicatedSuite.UI:ShowPage("gear")
        return true
    end
    self:ShowConfig(true)
    return true
end

function U:OnRuntimeStarted(session)
    self.switchingSetId = session and session.setId or nil
    self:SetQuickStatus("切换中")
    local same = tonumber(session.preflightSame) or tonumber(session.skipped) or 0
    local need = tonumber(session.preflightNeedChange) or #(session.queue or {})
    local pending = #(session.pendingFailures or {})
    local detail = "预检完成：相同 " .. tostring(same) .. " 件跳过，需要更换 " .. tostring(need) .. " 件"
    if pending > 0 then
        detail = detail .. "；其中 " .. tostring(pending) .. " 件当前先记为 Pending，最终以实际装备状态重新对账"
    end
    self:SetStatus("正在切换“" .. tostring(session.setName) .. "”", detail)
    self:RefreshSetList()
    self:RefreshEditor()
    self:RefreshQuick()
end

function U:OnRuntimeProgress(session, index, total, phase)
    local totalCount = math.max(0, tonumber(total) or 0)
    local current = math.max(1, tonumber(index) or 1)
    local phaseText = tostring(phase or "")
    if phaseText == "VERIFY" then
        phaseText = "验证装备"
    elseif phaseText == "ACTION" then
        phaseText = "更换装备"
    elseif phaseText == "FINAL_VERIFY" then
        phaseText = "整套验证"
    elseif phaseText == "TITLE_VERIFY" then
        phaseText = "切换称号"
    elseif phaseText == "START" then
        phaseText = "预检完成"
    elseif phaseText == "SKIP" then
        phaseText = "跳过已相同装备"
    elseif phaseText == "PARTIAL_SKIP" or phaseText == "PENDING" then
        phaseText = "记录未完成并继续其它槽位"
    end
    if totalCount > 0 then
        local shown = math.min(current, totalCount)
        self:SetQuickStatus(tostring(shown) .. "/" .. tostring(totalCount))
        self:SetStatus("正在切换“" .. tostring(session.setName) .. "”", phaseText .. "（" .. tostring(shown) .. "/" .. tostring(totalCount) .. "）")
    else
        self:SetQuickStatus("切换中")
        self:SetStatus("正在切换“" .. tostring(session.setName) .. "”", phaseText)
    end
end

function U:OnRuntimeBlocked(session)
    local missingCount = #(session.missing or {})
    local ambiguousCount = #(session.ambiguous or {})
    local readErrorCount = #(session.readErrors or {})
    local repositionCount = #(session.reposition or {})
    local count = missingCount + ambiguousCount + readErrorCount + repositionCount
    self:SetQuickStatus("阻止" .. tostring(count))
    local first = (session.missing and session.missing[1])
        or (session.ambiguous and session.ambiguous[1])
        or (session.readErrors and session.readErrors[1])
        or (session.reposition and session.reposition[1])
    local detail = first and (tostring(first.slotName or "装备") .. "：" .. tostring(first.name or "未知")) or ""
    if readErrorCount > 0 then
        self:SetStatus("背包读取不完整，已阻止换装", "请稍后重试；" .. detail)
        G.SafeChat("读取背包时部分 API 调用失败，为避免误判缺失或穿错装备，本次换装已阻止。")
    elseif repositionCount > 0 and missingCount == 0 and ambiguousCount == 0 then
        self:SetStatus("无法直接完成槽位互换：目标装备都还穿在身上", "请先手动把其中一件放回背包，再点击换装；" .. detail)
        G.SafeChat("目标装备当前互相占用装备槽，公开 API 无法直接交换两个已装备槽；请先手动放一件进背包。")
    else
        self:SetStatus("无法完整切换“" .. tostring(session.setName) .. "”：缺少或无法唯一识别 " .. tostring(count) .. " 件", detail)
        G.SafeChat("无法完整切换“" .. tostring(session.setName) .. "”，阻止项 " .. tostring(count) .. " 件。")
    end
end

function U:OnRuntimeFinished(session, ok, message)
    self.switchingSetId = nil
    if ok and session.partial == true then
        self:SetQuickStatus("部分")
        self.activeSetId = nil
        local matched = tonumber(session.actualMatched) or 0
        local managed = tonumber(session.actualManaged) or tonumber(session.managedCount) or 0
        self:SetStatus("“" .. tostring(session.setName) .. "”部分完成 " .. tostring(matched) .. "/" .. tostring(managed),
            tostring(message or "仍有参与槽位未达到目标状态；再次点击同一方案只会补齐未完成部分"))
    elseif ok then
        self:SetQuickStatus("完成")
        self.activeSetId = session.setId
        local managed = tonumber(session.actualManaged) or tonumber(session.managedCount) or 0
        self:SetStatus("“" .. tostring(session.setName) .. "”切换完成", "最终对账 " .. tostring(managed) .. "/" .. tostring(managed)
            .. "；本次实际更换 " .. tostring(session.success or 0) .. " 件，跳过相同 " .. tostring(session.skipped or 0) .. " 件")
    else
        self:SetQuickStatus("失败")
        self.activeSetId = nil
        self:SetStatus("“" .. tostring(session.setName) .. "”切换未完成", tostring(message or "请检查背包、装备限制或战斗状态"))
    end
    self:RefreshSetList()
    self:RefreshEditor()
    self:RefreshQuick()
end

local ok, err = xpcall(function()
    if UIParent == nil or type(UIParent.CreateWidget) ~= "function" then error("UIParent:CreateWidget unavailable") end
    if type(CreateEmptyWindow) ~= "function" then error("CreateEmptyWindow unavailable") end
    if ReplicatedSuiteEmbedded == true then
        -- The Suite right panel is the only settings Authority. Do not allocate
        -- the historical launcher/config window just to keep domain logic alive.
        U.suiteHudVisible = false
        U:RefreshQuick()
    else
        CreateLauncher()
        CreateConfigWindow()
        U.suiteHudVisible = true
        U:RefreshAll()
    end
end, G.SafeTraceback)

if not ok then
    G.BootError = "ui: " .. tostring(err)
    G.SafeChat("UI初始化失败：" .. tostring(err))
    U:HideAll()
    return
end
