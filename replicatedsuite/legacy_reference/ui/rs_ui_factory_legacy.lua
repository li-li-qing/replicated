------------------------------------------------------------------------
-- Replicated Suite - UI Factory
------------------------------------------------------------------------

if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite

S.UI = {
    controls = {},
    windows = {},
    pages = {},
    widgets = {},
    managedWindows = {},
    currentPage = "life",
    registryMetrics = { duplicates = 0, v3Duplicates = 0 },
}
local UIX = S.UI

function UIX:Register(id, widget)
    if id ~= nil and widget ~= nil then
        local key = tostring(id)
        local previous = self.controls[key]
        local owner = tostring(widget.rsUiOwner or "")
        if previous ~= nil and previous ~= widget then
            self.registryMetrics.duplicates = (tonumber(self.registryMetrics.duplicates) or 0) + 1
            local previousOwner = tostring(previous.rsUiOwner or "")
            local strictV3 = owner:sub(1, 3) == "v3:" or previousOwner:sub(1, 3) == "v3:"
            if strictV3 then
                -- V3 IDs are address/ownership identities, not labels. Never
                -- keep legacy's last-writer-wins behavior for a strict tree.
                self.registryMetrics.v3Duplicates = (tonumber(self.registryMetrics.v3Duplicates) or 0) + 1
                widget.rsUiRegistrationRejected = true
                if type(widget.Show) == "function" then pcall(function() widget:Show(false) end) end
                local d = S.DiagnosticsManager
                if type(d) == "table" and type(d.Emit) == "function" then
                    d:Emit("error", "ui_v3", "DUPLICATE_COMPONENT_ID", "V3 UI 控件 ID 重复，拒绝后注册控件", {
                        id = key, owner = owner, previousOwner = previousOwner,
                    })
                end
                return previous
            end
            -- Legacy remains compatible during migration, but every duplicate
            -- is still counted so cleanup can proceed without silent aliases.
            S.WarnOnce("ui_control_duplicate:" .. key, "界面控件编号重复：" .. key)
        end
        self.controls[key] = widget
        if owner:sub(1, 3) == "v3:" and type(self.AdoptV3Widget) == "function" then
            self:AdoptV3Widget(widget, owner, key)
        elseif type(self.AdoptWidget) == "function" then
            self:AdoptWidget(widget, widget.rsUiOwner, key)
        end
    end
    return widget
end

function UIX:GetRegistrySnapshot()
    return {
        duplicates = tonumber(self.registryMetrics and self.registryMetrics.duplicates) or 0,
        v3Duplicates = tonumber(self.registryMetrics and self.registryMetrics.v3Duplicates) or 0,
    }
end

function UIX:SafeHandler(widget, eventName, fn, label)
    if widget == nil or type(widget.SetHandler) ~= "function" or type(fn) ~= "function" then return false end
    local generation = S.Generation
    -- Create this packer once per binding rather than once per event dispatch;
    -- sliders can emit many callbacks while being dragged.
    local function Pack(...)
        local packed = { ... }
        packed.n = select("#", ...)
        return packed
    end
    local function handler(...)
        if S.Generation ~= generation then return nil end
        local args = { ... }
        local argCount = select("#", ...)
        local result = nil
        local token = S.PerformanceMonitor and S.PerformanceMonitor:Begin("ui:" .. tostring(label or eventName)) or nil
        local ok, err = xpcall(function()
            -- Preserve the exact result arity. A `{ fn(...) }` wrapper loses
            -- trailing/intermediate nil values and can subtly change handler
            -- contracts such as drag-start returning `false, nil`.
            result = Pack(fn(unpack(args, 1, argCount)))
        end, S.SafeTraceback)
        if S.PerformanceMonitor ~= nil then S.PerformanceMonitor:End(token) end
        if not ok then
            S.SafeChat("界面错误 " .. tostring(label or eventName) .. "：" .. tostring(err))
            return nil
        end
        if result ~= nil then return unpack(result, 1, tonumber(result.n) or #result) end
        return nil
    end
    -- Some RU widget builds expose only one of several historical event names.
    -- Probe SetHandler itself safely and return whether the binding succeeded so
    -- callers can stop at the first supported alias instead of double-binding.
    local ok, bindResult = pcall(function() return widget:SetHandler(eventName, handler) end)
    -- Some widget builds reject an unknown handler name by returning false
    -- rather than throwing. Treat that as a failed probe so alias callers can
    -- continue to the next supported event name.
    local bound = ok == true and bindResult ~= false
    if bound and type(self.RegisterHandlerBinding) == "function" then self:RegisterHandlerBinding(widget, eventName) end
    return bound
end

-- Standard lifecycle for ordinary dialogs. HUD widgets keep using WidgetBase
-- and HudManager; dialogs get a smaller API with the same logical placement,
-- safe drag, sizing bounds, opacity and font ownership rules.
function UIX:CreateManagedWindow(spec)
    spec = type(spec) == "table" and spec or {}
    local id = tostring(spec.id or "")
    if id == "" or S.NativeObjectFactory == nil or S.State == nil then return nil end
    S.State.ui.dialogs = type(S.State.ui.dialogs) == "table" and S.State.ui.dialogs or {}
    local placement = S.State.ui.dialogs[id]
    if type(placement) ~= "table" then
        placement = { width = tonumber(spec.width) or 420, height = tonumber(spec.height) or 280,
            fontScale = 1.0, backgroundAlpha = 0.90, locked = false, userMoved = false }
        S.State.ui.dialogs[id] = placement
    end
    local window = S.NativeObjectFactory:CreateWindow(S.PhysicalId("dialog_" .. id), "UIParent", "")
    if window == nil then return nil end
    window.rsHudOwner = "dialog:" .. id
    window.rsUiOwner = "dialog:" .. id
    if type(self.AdoptWidget) == "function" then self:AdoptWidget(window, window.rsUiOwner, "dialog_" .. id) end
    if window.Enable ~= nil then pcall(function() window:Enable(true) end) end
    if window.Clickable ~= nil then pcall(function() window:Clickable(true) end) end
    if S.UI.TrySetUILayer ~= nil then S.UI:TrySetUILayer(window, "system") end
    local managed = { id = id, window = window, placement = placement, spec = spec, destroyed = false }
    self.managedWindows[id] = managed

    local function Clamp(value, minimum, maximum)
        value = tonumber(value) or minimum
        return math.max(minimum, math.min(maximum, value))
    end
    function managed:GetSize()
        local context = S.Layout:GetContext()
        local scale = context.addonScale
        local minW, minH = tonumber(spec.minWidth) or tonumber(spec.width) or 160, tonumber(spec.minHeight) or tonumber(spec.height) or 100
        local maxW, maxH = tonumber(spec.maxWidth) or 1200, tonumber(spec.maxHeight) or 900
        local designW = Clamp(tonumber(placement.width) or tonumber(spec.width) or 420, minW, maxW)
        local designH = Clamp(tonumber(placement.height) or tonumber(spec.height) or 280, minH, maxH)
        return math.min(designW * scale, context.usableWidth), math.min(designH * scale, context.usableHeight)
    end
    function managed:ApplyPlacement(width, height)
        -- NOTE: `width, height = width or self:GetSize()` is a Lua trap — an
        -- `or` expression yields only ONE value, so `height` became nil and the
        -- window was SetExtent(width, nil) => 0-height sliver ("一条线" bug from
        -- the managed-window refactor). Resolve both dimensions explicitly.
        if width == nil or height == nil then
            local sizeW, sizeH = self:GetSize()
            width = width or sizeW
            height = height or sizeH
        end
        if placement.userMoved == true then
            S.Layout:ApplyPlacement(window, placement, width, height)
        elseif type(spec.defaultPlacement) == "function" then
            spec.defaultPlacement(window, width, height, S.Layout:GetContext())
        else
            if window.RemoveAllAnchors ~= nil then window:RemoveAllAnchors() end
            window:AddAnchor("CENTER", "UIParent", 0, 0)
            window:SetExtent(width, height)
        end
        if spec.resizable == true then
            if window.UseResizing ~= nil then pcall(function() window:UseResizing(true) end) end
            if window.SetMinResizingExtent ~= nil then pcall(function() window:SetMinResizingExtent((tonumber(spec.minWidth) or 160) * S.Layout:GetContext().addonScale, (tonumber(spec.minHeight) or 100) * S.Layout:GetContext().addonScale) end) end
            if window.SetMaxResizingExtent ~= nil then pcall(function() window:SetMaxResizingExtent((tonumber(spec.maxWidth) or 1200) * S.Layout:GetContext().addonScale, (tonumber(spec.maxHeight) or 900) * S.Layout:GetContext().addonScale) end) end
        end
    end
    function managed:StorePlacement()
        S.Layout:StorePlacement(placement, window)
        local _, _, width, height = S.Layout:GetLogicalRect(window)
        local scale = math.max(0.01, S.Layout:GetContext().addonScale)
        placement.width, placement.height = width / scale, height / scale
        placement.userMoved = true
        if S.Storage ~= nil and type(S.Storage.RequestSave) == "function" then S.Storage:RequestSave() end
    end
    function managed:SetLocked(locked, persist)
        placement.locked = locked == true
        if persist ~= false and S.Storage ~= nil and type(S.Storage.RequestSave) == "function" then S.Storage:RequestSave() end
        return placement.locked
    end
    function managed:IsLocked()
        return placement.locked == true
    end
    function managed:BindTitleBar(titleBar)
        if titleBar == nil then return false end
        if titleBar.EnableDrag ~= nil then pcall(function() titleBar:EnableDrag(true) end) end
        if titleBar.Clickable ~= nil then pcall(function() titleBar:Clickable(true) end) end
        S.UI:SafeHandler(titleBar, "OnDragStart", function()
            if self:IsLocked() then return false end
            titleBar.rsManagedMoving = S.Layout ~= nil and type(S.Layout.BeginSafeMove) == "function"
                and S.Layout:BeginSafeMove("dialog:" .. id, window, { clamp = true }) == true
            titleBar.rsManagedNative = false
            if titleBar.rsManagedMoving == true then return true end
            if type(window.StartMoving) ~= "function" then return false end
            local ok = pcall(function() window:StartMoving() end)
            titleBar.rsManagedNative = ok == true
            return titleBar.rsManagedNative
        end, "dialog:" .. id .. ":drag_start")
        S.UI:SafeHandler(titleBar, "OnDragStop", function()
            if titleBar.rsManagedMoving == true then
                if S.Layout ~= nil and type(S.Layout.EndSafeMove) == "function" then S.Layout:EndSafeMove("dialog:" .. id, false) end
            elseif titleBar.rsManagedNative == true and type(window.StopMovingOrSizing) == "function" then
                pcall(function() window:StopMovingOrSizing() end)
            end
            if S.Layout ~= nil and type(S.Layout.EnsureWidgetVisible) == "function" then
                S.Layout:EnsureWidgetVisible(window, { onlyWhenVisible = false })
            end
            titleBar.rsManagedMoving = false; titleBar.rsManagedNative = false; self:StorePlacement(); return true
        end, "dialog:" .. id .. ":drag_stop")
        return true
    end
    function managed:BindResizeHandle(handle)
        if handle == nil or spec.resizable ~= true then return false end
        if handle.EnableDrag ~= nil then pcall(function() handle:EnableDrag(true) end) end
        S.UI:SafeHandler(handle, "OnDragStart", function()
            if self:IsLocked() or type(window.StartSizing) ~= "function" then return false end
            local ok = pcall(function() window:StartSizing("BOTTOMRIGHT") end)
            handle.rsManagedSizing = ok == true
            return handle.rsManagedSizing
        end, "dialog:" .. id .. ":resize_start")
        S.UI:SafeHandler(handle, "OnDragStop", function()
            if handle.rsManagedSizing == true and type(window.StopMovingOrSizing) == "function" then pcall(function() window:StopMovingOrSizing() end) end
            handle.rsManagedSizing = false
            self:StorePlacement()
            if S.Layout ~= nil and type(S.Layout.EnsureWidgetVisible) == "function" then S.Layout:EnsureWidgetVisible(window, { onlyWhenVisible = false }) end
            return true
        end, "dialog:" .. id .. ":resize_stop")
        return true
    end
    function managed:SetBackgroundAlpha(value, persist)
        placement.backgroundAlpha = Clamp(value, 0, 1); S.Theme:SetBackgroundOpacity(window, placement.backgroundAlpha)
        for _, control in pairs(S.UI.controls or {}) do
            if control ~= nil and control.rsHudOwner == window.rsHudOwner then S.Theme:SetBackgroundOpacity(control, placement.backgroundAlpha) end
        end
        if persist ~= false and S.Storage ~= nil and type(S.Storage.RequestSave) == "function" then S.Storage:RequestSave() end
    end
    function managed:SetFontScale(value, persist)
        placement.fontScale = Clamp(value, 0.5, 2.0)
        for _, control in pairs(S.UI.controls or {}) do
            if control ~= nil and control.rsHudOwner == window.rsHudOwner and tonumber(control.rsBaseFontSize) ~= nil and control.style ~= nil and type(control.style.SetFontSize) == "function" then
                pcall(function() control.style:SetFontSize(math.max(6, control.rsBaseFontSize * placement.fontScale)) end)
            end
        end
        if persist ~= false and S.Storage ~= nil and type(S.Storage.RequestSave) == "function" then S.Storage:RequestSave() end
    end
    function managed:ResetPlacement()
        placement.userMoved = false
        placement.width = tonumber(spec.width) or placement.width
        placement.height = tonumber(spec.height) or placement.height
        placement.fontScale = 1.0
        placement.backgroundAlpha = 0.90
        placement.locked = false
        self:ApplyPlacement()
        self:SetFontScale(placement.fontScale, false)
        self:SetBackgroundAlpha(placement.backgroundAlpha, false)
        if S.Storage ~= nil and type(S.Storage.RequestSave) == "function" then S.Storage:RequestSave() end
    end
    -- A compact shared settings popover. It intentionally lives inside the
    -- dialog so no extra floating-window persistence or Esc ownership is
    -- created. `CreateNumericSettingControl` is loaded after this factory;
    -- callers invoke this only while constructing regular UI windows.
    function managed:AttachSettingsControls(titleBar, options)
        options = type(options) == "table" and options or {}
        if titleBar == nil or type(S.UI.CreateNumericSettingControl) ~= "function" then return nil end
        local baseId = "dialog_" .. id .. "_settings"
        local button = S.UI:CreateButton(titleBar, baseId .. "_button", "⚙", 0, 3, 28, 24, 10, false)
        local panel = S.UI:CreatePanel(window, baseId .. "_panel", 0, 33, 300, 86, "card")
        panel:Show(false)
        local lock = S.UI:CreateButton(panel, baseId .. "_lock", "锁定：关", 10, 6, 72, 22, 8, false)
        local reset = S.UI:CreateButton(panel, baseId .. "_reset", "恢复默认", 214, 6, 76, 22, 8, false)
        local alphaBinding = S.UI:CreateSettingBinding({
            get=function() return placement.backgroundAlpha or 0.90 end,
            set=function(value, final) self:SetBackgroundAlpha(value, final == true); return true end,
        })
        local alpha = S.UI:CreateNumericSettingControl(panel, baseId .. "_alpha", {
            label="透明度", x=10, y=31, labelWidth=56, sliderWidth=88, editWidth=44, height=22,
            min=0.40, max=1.00, step=0.05, precision=2, binding=alphaBinding,
        })
        local fontBinding = S.UI:CreateSettingBinding({
            get=function() return placement.fontScale or 1.0 end,
            set=function(value, final) self:SetFontScale(value, final == true); return true end,
        })
        local font = S.UI:CreateNumericSettingControl(panel, baseId .. "_font", {
            label="字体", x=10, y=58, labelWidth=56, sliderWidth=88, editWidth=44, height=22,
            min=0.70, max=1.60, step=0.05, precision=2, binding=fontBinding,
        })
        local function refresh()
            lock:SetText(self:IsLocked() and "锁定：开" or "锁定：关")
            alpha:Refresh(); font:Refresh()
        end
        S.UI:SafeHandler(button, "OnClick", function() panel:Show(not panel:IsVisible()); if panel:IsVisible() then refresh() end end, baseId .. ":toggle")
        S.UI:SafeHandler(lock, "OnClick", function() self:SetLocked(not self:IsLocked()); refresh() end, baseId .. ":lock")
        S.UI:SafeHandler(reset, "OnClick", function() self:ResetPlacement(); refresh() end, baseId .. ":reset")
        return { button=button, panel=panel, lock=lock, reset=reset, alpha=alpha, font=font,
            ApplyLayout=function(_, width) button:SetExtent(28,24); S.UI:SetAnchor(button,titleBar,math.max(4,width-66),3) end }
    end
    function managed:Show(visible)
        if self.destroyed == true then return false end
        self:ApplyPlacement()
        if visible == true then self:SetFontScale(placement.fontScale or 1.0, false); self:SetBackgroundAlpha(placement.backgroundAlpha or 0.90, false) end
        window:Show(visible == true)
        if visible == true and window.Raise ~= nil then pcall(function() window:Raise() end) end
        return true
    end
    function managed:Destroy()
        self.destroyed = true
        if S.UI ~= nil and type(S.UI.ReleaseOwner) == "function" and window.rsUiOwner ~= nil then
            S.UI:ReleaseOwner(window.rsUiOwner)
        else
            pcall(function() window:Show(false) end)
        end
        if S.UI ~= nil and S.UI.managedWindows ~= nil and S.UI.managedWindows[id] == self then S.UI.managedWindows[id] = nil end
    end
    return managed
end

-- Professional modules own independent SaveData trees and, in standalone
-- mode, cannot be forced into `S.State.ui.dialogs`.  This adapter gives an
-- existing window the same interaction contract without taking ownership of
-- that storage. `placement`, `persist` and presentation callbacks are injected
-- by the module, so no Suite-state coupling is introduced.
function UIX:AttachManagedWindow(window, spec)
    spec = type(spec) == "table" and spec or {}
    if window == nil then return nil end
    local id = tostring(spec.id or "attached_window")
    local placement = type(spec.placement) == "table" and spec.placement or {}
    window.rsUiOwner = window.rsUiOwner or ("attached:" .. id)
    if type(self.AdoptWidget) == "function" then self:AdoptWidget(window, window.rsUiOwner, "attached_" .. id) end
    local managed = { id=id, window=window, placement=placement, spec=spec, destroyed=false }
    function managed:Persist()
        if type(spec.persist) == "function" then spec.persist(placement) end
    end
    function managed:IsLocked() return placement.locked == true end
    function managed:SetLocked(value)
        placement.locked = value == true; self:Persist(); return placement.locked
    end
    function managed:ApplyPlacement()
        if type(spec.applyPlacement) == "function" then return spec.applyPlacement(window, placement) end
        if S.Layout ~= nil and type(S.Layout.EnsureWidgetVisible) == "function" then return S.Layout:EnsureWidgetVisible(window, { onlyWhenVisible=false }) end
        return true
    end
    function managed:SetBackgroundAlpha(value, persist)
        placement.backgroundAlpha = math.max(0, math.min(1, tonumber(value) or 1))
        if type(spec.applyOpacity) == "function" then spec.applyOpacity(placement.backgroundAlpha) end
        if persist ~= false then self:Persist() end
    end
    function managed:SetFontScale(value, persist)
        placement.fontScale = math.max(0.5, math.min(2.0, tonumber(value) or 1))
        if type(spec.applyFontScale) == "function" then spec.applyFontScale(placement.fontScale) end
        if persist ~= false then self:Persist() end
    end
    function managed:BindTitleBar(titleBar)
        if titleBar == nil then return false end
        if titleBar.EnableDrag ~= nil then pcall(function() titleBar:EnableDrag(true) end) end
        if titleBar.Clickable ~= nil then pcall(function() titleBar:Clickable(true) end) end
        S.UI:SafeHandler(titleBar, "OnDragStart", function()
            if self:IsLocked() or type(window.StartMoving) ~= "function" then return false end
            titleBar.rsAttachedMoving = pcall(function() window:StartMoving() end)
            return titleBar.rsAttachedMoving == true
        end, "attached:" .. id .. ":drag_start")
        S.UI:SafeHandler(titleBar, "OnDragStop", function()
            if titleBar.rsAttachedMoving == true and type(window.StopMovingOrSizing) == "function" then pcall(function() window:StopMovingOrSizing() end) end
            titleBar.rsAttachedMoving = false; self:ApplyPlacement(); self:Persist(); return true
        end, "attached:" .. id .. ":drag_stop")
        return true
    end
    function managed:Show(visible)
        if self.destroyed == true then return false end
        self:ApplyPlacement(); if type(window.Show) == "function" then window:Show(visible == true) end
        if visible == true and window.Raise ~= nil then pcall(function() window:Raise() end) end
        return true
    end
    function managed:Destroy()
        self.destroyed = true
        if S.UI ~= nil and type(S.UI.ReleaseOwner) == "function" and window.rsUiOwner ~= nil then
            S.UI:ReleaseOwner(window.rsUiOwner)
            return
        end
        local native = S.Reuse and S.Reuse.NativeSafe
        if native ~= nil and type(native.ReleaseHandler) == "function" then
            native.ReleaseHandler(window, "OnUpdate"); native.ReleaseHandler(window, "OnEvent")
        end
        if type(window.Show) == "function" then pcall(function() window:Show(false) end) end
    end
    return managed
end

-- Unstyled native host used by RSUI primitives.  This remains in the Factory
-- layer so Component code does not need to repeat CreateChildWidget ownership,
-- pickability, registration or Diff priming rules.
function UIX:CreateEmptyWidget(parent, id, x, y, width, height, pickable)
    if parent == nil or type(parent.CreateChildWidget) ~= "function" then return nil end
    local widget = S.NativeObjectFactory and S.NativeObjectFactory:CreateChild(parent, "emptywidget", S.PhysicalId(id), 0, true) or nil
    if widget == nil then return nil end
    local configured = pcall(function()
        widget:SetExtent(math.max(1, tonumber(width) or 1), math.max(1, tonumber(height) or 1))
        widget:AddAnchor("TOPLEFT", parent, tonumber(x) or 0, tonumber(y) or 0)
        if widget.Enable ~= nil then widget:Enable(true) end
        if widget.EnablePick ~= nil then widget:EnablePick(pickable == true) end
        if widget.Clickable ~= nil then widget:Clickable(pickable == true) end
        widget:Show(true)
    end)
    if not configured then return nil end
    widget.rsHudOwner = parent and parent.rsHudOwner or nil
    widget.rsUiOwner = parent and (parent.rsUiOwner or (parent.rsHudOwner and ("hud:" .. tostring(parent.rsHudOwner)))) or nil
    widget.rsUiParent = parent
    if type(self.PrimeNativeState) == "function" then
        self:PrimeNativeState(widget, {
            width = math.max(1, tonumber(width) or 1), height = math.max(1, tonumber(height) or 1),
            visible = true, enabled = true, pickable = pickable == true,
            anchorTopLeft = { parent = parent, x = tonumber(x) or 0, y = tonumber(y) or 0 },
        })
    end
    return self:Register(id, widget)
end

function UIX:CreatePanel(parent, id, x, y, width, height, kind, opts)
    local panel = S.NativeObjectFactory and S.NativeObjectFactory:CreateEmptyWidget(S.PhysicalId(id), parent) or nil
    if panel == nil then return nil end
    panel:AddAnchor("TOPLEFT", parent, x or 0, y or 0)
    panel:SetExtent(math.max(1, width or 1), math.max(1, height or 1))
    panel.rsHudOwner = parent and parent.rsHudOwner or nil
    panel.rsUiOwner = parent and (parent.rsUiOwner or (parent.rsHudOwner and ("hud:" .. tostring(parent.rsHudOwner)))) or nil
    panel.rsUiParent = parent
    S.Theme:AddBorder(panel, kind == "soft")
    opts = type(opts) == "table" and opts or {}
    local theme = S.Constants and S.Constants.Theme or {}
    -- Master-switch behaviour: by default card/header/soft panels are skinned
    -- with the modern gradient unless Theme.modern is off or the caller opts
    -- out explicitly with { gradient = false }.  Panels that must keep a flat
    -- look (e.g. tiny overlay strips) pass gradient = false.
    local useGradient = opts.gradient
    if useGradient == nil then
        useGradient = theme.modern ~= false
            and ((kind == "card" and theme.gradientPanels ~= false)
                or (kind == "soft" and theme.gradientPanels ~= false)
                or (kind == "header" and theme.gradientHeaders ~= false))
    end
    if useGradient == true then
        -- kind string also selects the gradient band set (titlebar/header/card).
        local gradientKind = opts.gradientKind
            or (kind == "header" and "header" or (kind == "card" and "card" or (kind == "titlebar" and "titlebar" or nil)))
        S.Theme:AddGradientBackground(panel, gradientKind or kind, nil)
        -- Headers carry the golden accent strip by default (still overridable).
        if kind == "header" and opts.accentStrip ~= false and theme.gradientHeaders ~= false then
            S.Theme:AddAccentStrip(panel, nil, nil)
        end
    else
        S.Theme:AddPanelBackground(panel, kind == "header" and "header" or (kind == "card" and "card" or nil))
    end
    if opts.accentStrip == true then
        S.Theme:AddAccentStrip(panel, nil, nil)
    elseif type(opts.accentStrip) == "number" then
        S.Theme:AddAccentStrip(panel, opts.accentStrip, nil)
    end
    if opts.divider ~= nil then
        S.Theme:AddDivider(panel, opts.divider, opts.dividerSoft == true)
    end
    panel:Show(true)
    if type(self.PrimeNativeState) == "function" then
        self:PrimeNativeState(panel, {
            width = math.max(1, width or 1), height = math.max(1, height or 1), visible = true,
            anchorTopLeft = { parent = parent, x = x or 0, y = y or 0 },
        })
    end
    return self:Register(id, panel)
end

function UIX:CreateLabel(parent, id, text, x, y, width, height, fontSize, tone, align, shadow)
    local label = S.NativeObjectFactory and S.NativeObjectFactory:CreateChild(parent, "label", S.PhysicalId(id), 0, true) or nil
    if label == nil then return nil end
    label:AddAnchor("TOPLEFT", parent, x or 0, y or 0)
    if label.SetAutoResize ~= nil then label:SetAutoResize(false) end
    label:SetExtent(math.max(1, width or 1), math.max(1, height or 1))
    if label.EnablePick ~= nil then label:EnablePick(false) end
    if label.Clickable ~= nil then label:Clickable(false) end
    label.rsHudOwner = parent and parent.rsHudOwner or nil
    label.rsUiOwner = parent and (parent.rsUiOwner or (parent.rsHudOwner and ("hud:" .. tostring(parent.rsHudOwner)))) or nil
    label.rsUiParent = parent
    label.rsBaseFontSize = tonumber(fontSize)
    -- Automatic title shadow: fontSize >= 13 labels get a subtle shadow unless
    -- the master switch is off or the caller passes an explicit false.
    local theme = S.Constants and S.Constants.Theme or {}
    local useShadow = shadow
    if useShadow == nil then
        useShadow = theme.modern ~= false and theme.labelShadow ~= false and tonumber(fontSize) ~= nil and tonumber(fontSize) >= 13
    end
    S.Theme:StyleLabel(label, fontSize or (S.UITokens and S.UITokens:Number("font.body", 11)) or 11, tone, align, useShadow)
    label:SetText(tostring(text or ""))
    label:Show(true)
    if type(self.PrimeNativeState) == "function" then
        self:PrimeNativeState(label, {
            text = tostring(text or ""), width = math.max(1, width or 1), height = math.max(1, height or 1),
            visible = true, pickable = false, anchorTopLeft = { parent = parent, x = x or 0, y = y or 0 },
            fontSize = label.rsAppliedFontSize,
        })
    end
    return self:Register(id, label)
end

function UIX:CreateEditBox(parent, id, x, y, width, height, maxLength)
    if parent == nil or type(parent.CreateChildWidgetByType) ~= "function" then return nil end
    -- RU clients are inconsistent about which single-line editbox token is
    -- exported. Prefer X2_EDITBOX, then fall back to the regular EDITBOX.
    -- A missing text field must never break the entire Suite layout.
    local factory = S.NativeObjectFactory
    if type(factory) ~= "table" or type(factory.CreateChildByObject) ~= "function" then return nil end
    local edit = factory:CreateChildByObject(parent, "X2_EDITBOX", S.PhysicalId(id), 0, true)
    if edit == nil then edit = factory:CreateChildByObject(parent, "EDITBOX", S.PhysicalId(id), 0, true) end
    if edit == nil then return nil end
    local configured = pcall(function()
        edit:SetExtent(math.max(1, width or 120), math.max(1, height or 26))
        if edit.SetInset ~= nil then edit:SetInset(5,5,5,5) end
        if edit.EnableFocus ~= nil then edit:EnableFocus(true) end
        if edit.UseSelectAllWhenFocused ~= nil then edit:UseSelectAllWhenFocused(true) end
        if edit.SetMaxTextLength ~= nil then edit:SetMaxTextLength(math.max(1, tonumber(maxLength) or 64)) end
        if edit.style ~= nil then
            if edit.style.SetAlign ~= nil then edit.style:SetAlign(ALIGN_LEFT) end
            if edit.style.SetColor ~= nil then edit.style:SetColor(1.00,0.96,0.84,1.00) end
        end
        if edit.CreateColorDrawable ~= nil then
            local border=edit:CreateColorDrawable(0.34,0.43,0.52,0.98,"background")
            if border and border.AddAnchor then border:AddAnchor("TOPLEFT",edit,0,0); border:AddAnchor("BOTTOMRIGHT",edit,0,0) end
            local bg=edit:CreateColorDrawable(0.015,0.022,0.032,0.995,"background")
            if bg and bg.AddAnchor then bg:AddAnchor("TOPLEFT",edit,1,1); bg:AddAnchor("BOTTOMRIGHT",edit,-1,-1) end
        end
        edit:AddAnchor("TOPLEFT", parent, x or 0, y or 0)
        edit:Show(true)
    end)
    if not configured then return nil end
    edit.rsUiOwner = parent and (parent.rsUiOwner or (parent.rsHudOwner and ("hud:" .. tostring(parent.rsHudOwner)))) or nil
    if type(self.PrimeNativeState) == "function" then
        self:PrimeNativeState(edit, { width = math.max(1, width or 120), height = math.max(1, height or 26), visible = true, anchorTopLeft = { parent = parent, x = x or 0, y = y or 0 } })
    end
    return self:Register(id, edit)
end

function UIX:CreateMultiEditBox(parent, id, x, y, width, height, maxLength)
    if parent == nil or type(parent.CreateChildWidgetByType) ~= "function" then return nil end
    local factory = S.NativeObjectFactory
    if type(factory) ~= "table" or type(factory.CreateChildByObject) ~= "function" then return nil end
    local edit = factory:CreateChildByObject(parent, "EDITBOX_MULTILINE", S.PhysicalId(id), 0, true)
    if edit == nil then return nil end
    local configured = pcall(function()
        edit:SetExtent(math.max(1, width or 220), math.max(1, height or 96))
        if edit.SetInset ~= nil then edit:SetInset(8,8,10,8) end
        if edit.EnableFocus ~= nil then edit:EnableFocus(true) end
        if edit.UseSelectAllWhenFocused ~= nil then edit:UseSelectAllWhenFocused(true) end
        if edit.SetMaxTextLength ~= nil then edit:SetMaxTextLength(math.max(1, tonumber(maxLength) or 65535)) end
        if edit.style ~= nil then
            if edit.style.SetAlign ~= nil then edit.style:SetAlign(ALIGN_TOP_LEFT or ALIGN_LEFT) end
            if edit.style.SetColor ~= nil then edit.style:SetColor(1.00,0.96,0.84,1.00) end
        end
        if edit.guideTextStyle ~= nil and edit.guideTextStyle.SetAlign ~= nil then
            edit.guideTextStyle:SetAlign(ALIGN_TOP_LEFT or ALIGN_LEFT)
        end
        if edit.CreateColorDrawable ~= nil then
            local border=edit:CreateColorDrawable(0.34,0.43,0.52,0.98,"background")
            if border and border.AddAnchor then border:AddAnchor("TOPLEFT",edit,0,0); border:AddAnchor("BOTTOMRIGHT",edit,0,0) end
            local bg=edit:CreateColorDrawable(0.015,0.022,0.032,0.995,"background")
            if bg and bg.AddAnchor then bg:AddAnchor("TOPLEFT",edit,1,1); bg:AddAnchor("BOTTOMRIGHT",edit,-1,-1) end
        end
        edit:AddAnchor("TOPLEFT", parent, x or 0, y or 0)
        edit:Show(true)
    end)
    if not configured then return nil end
    edit.rsUiOwner = parent and (parent.rsUiOwner or (parent.rsHudOwner and ("hud:" .. tostring(parent.rsHudOwner)))) or nil
    if type(self.PrimeNativeState) == "function" then
        self:PrimeNativeState(edit, { width = math.max(1, width or 220), height = math.max(1, height or 96), visible = true, anchorTopLeft = { parent = parent, x = x or 0, y = y or 0 } })
    end
    return self:Register(id, edit)
end

function UIX:EnsureHorizontalSlider(slider)
    -- Kept as a compatibility shim for callers created before UI2.  Since
    -- 1.0.22 Suite sliders are no longer native Slider widgets at all.  Their
    -- drag surface is an ordinary movable EmptyWidget and only its X delta is
    -- consumed, so native RU Slider orientation cannot affect the drag axis.
    return slider ~= nil and slider.rsCustomHorizontal == true
end

local function ClampSliderValue(slider, value)
    local minimum = tonumber(slider and slider.rsMinimum) or 0
    local maximum = tonumber(slider and slider.rsMaximum) or 100
    if maximum < minimum then minimum, maximum = maximum, minimum end
    local step = math.abs(tonumber(slider and slider.rsStep) or 1)
    local v = tonumber(value) or minimum
    if step > 0 then
        v = minimum + math.floor(((v - minimum) / step) + 0.5) * step
    end
    if v < minimum then v = minimum end
    if v > maximum then v = maximum end
    return v
end

function UIX:UpdateSliderVisual(slider, explicitValue)
    if slider == nil then return end
    local thumb = slider.rsThumbButton
    if thumb == nil then return end
    local minimum = tonumber(slider.rsMinimum) or 0
    local maximum = tonumber(slider.rsMaximum) or 100
    local value = ClampSliderValue(slider, explicitValue ~= nil and explicitValue or slider.rsValue)
    slider.rsValue = value
    local width = slider.GetWidth and slider:GetWidth() or tonumber(slider.rsWidth) or 140
    local height = slider.GetHeight and slider:GetHeight() or tonumber(slider.rsHeight) or 20
    slider.rsWidth, slider.rsHeight = width, height
    local track = slider.rsTrack
    if track ~= nil then
        if track.RemoveAllAnchors ~= nil then track:RemoveAllAnchors() end
        if track.SetExtent ~= nil then track:SetExtent(math.max(1, width - 12), 4) end
        if track.AddAnchor ~= nil then track:AddAnchor("TOPLEFT", slider, 6, math.max(0, math.floor((height - 4) / 2))) end
    end
    local thumbW = math.max(10, tonumber(slider.rsThumbWidth) or 18)
    local thumbH = math.max(10, math.min(height, tonumber(slider.rsThumbHeight) or 14))
    local travel = math.max(1, width - thumbW)
    local ratio = maximum > minimum and ((value - minimum) / (maximum - minimum)) or 0
    local tx = math.floor(travel * ratio + 0.5)
    local ty = math.max(0, math.floor((height - thumbH) / 2))
    if thumb.RemoveAllAnchors ~= nil then thumb:RemoveAllAnchors() end
    if thumb.AddAnchor ~= nil then thumb:AddAnchor("TOPLEFT", slider, tx, ty) end
    if thumb.SetExtent ~= nil then thumb:SetExtent(thumbW, thumbH) end
    if thumb.Raise ~= nil then pcall(function() thumb:Raise() end) end

    -- The drag surface is deliberately invisible and may move vertically while
    -- the mouse is held.  Re-anchor it only when the drag transaction ends;
    -- during dragging its effective X position is our cursor substitute.
    local drag = slider.rsDragSurface
    if drag ~= nil and slider.rsDragging ~= true then
        if drag.RemoveAllAnchors ~= nil then drag:RemoveAllAnchors() end
        if drag.SetExtent ~= nil then drag:SetExtent(width, height) end
        if drag.AddAnchor ~= nil then drag:AddAnchor("TOPLEFT", slider, 0, 0) end
        if drag.Raise ~= nil then pcall(function() drag:Raise() end) end
    end
end

function UIX:CreateSlider(parent, id, x, y, width, height, minimum, maximum, step, value)
    if parent == nil or type(parent.CreateChildWidget) ~= "function" then return nil end

    -- Do NOT use UOT_SLIDER here.  ArcheRage RU has been observed to keep the
    -- native drag axis vertical even after SetOrientation("HORIZONTAL").  This
    -- widget implements horizontal dragging from first principles with an
    -- invisible movable surface.  StartMoving() supplies mouse movement, while
    -- only its X delta contributes to the slider value; Y is ignored entirely.
    local slider = S.NativeObjectFactory and S.NativeObjectFactory:CreateChild(parent, "emptywidget", S.PhysicalId(id), 0, true) or nil
    if slider == nil then return nil end

    local configured = pcall(function()
        local sliderW = math.max(30, tonumber(width) or 140)
        local sliderH = math.max(14, tonumber(height) or 20)
        slider:SetExtent(sliderW, sliderH)
        slider:AddAnchor("TOPLEFT", parent, x or 0, y or 0)
        slider.rsCustomHorizontal = true
        slider.rsMinimum = tonumber(minimum) or 0
        slider.rsMaximum = tonumber(maximum) or 100
        slider.rsStep = math.abs(tonumber(step) or 1)
        slider.rsWidth = sliderW
        slider.rsHeight = sliderH
        slider.rsThumbWidth = 18
        slider.rsThumbHeight = math.max(12, math.min(16, sliderH - 2))
        slider.rsValue = ClampSliderValue(slider, value)
        slider.rsDragging = false
        slider.rsEnabled = true
        slider.rsValueChanged = nil
        slider.rsNotifyElapsed = 0

        if slider.CreateColorDrawable ~= nil then
            local track = slider:CreateColorDrawable(0.26, 0.31, 0.37, 0.95, "background")
            slider.rsTrack = track
        end

        local thumb = S.NativeObjectFactory:CreateChild(slider, "emptywidget", S.PhysicalId(id .. "_thumb"), 0, true)
        if thumb == nil then error("slider thumb creation failed") end
        thumb:SetExtent(slider.rsThumbWidth, slider.rsThumbHeight)
        if thumb.EnablePick ~= nil then pcall(function() thumb:EnablePick(false, true) end) end
        if thumb.Clickable ~= nil then pcall(function() thumb:Clickable(false, true) end) end
        if thumb.CreateColorDrawable ~= nil then
            local outer = thumb:CreateColorDrawable(0.82, 0.68, 0.34, 1.00, "artwork")
            if outer and outer.AddAnchor then outer:AddAnchor("TOPLEFT", thumb, 0, 0); outer:AddAnchor("BOTTOMRIGHT", thumb, 0, 0) end
            local inner = thumb:CreateColorDrawable(0.18, 0.21, 0.25, 0.98, "artwork")
            if inner and inner.AddAnchor then inner:AddAnchor("TOPLEFT", thumb, 2, 2); inner:AddAnchor("BOTTOMRIGHT", thumb, -2, -2) end
        end
        slider.rsThumbButton = thumb
        thumb:Show(true)

        -- Full-width transparent drag surface.  It is allowed to move in both
        -- native axes, but remains invisible; only its effective X delta is
        -- sampled.  The visible thumb is always re-positioned on the horizontal
        -- rail, so dragging vertically can never change the value or visual Y.
        local drag = S.NativeObjectFactory:CreateChild(slider, "emptywidget", S.PhysicalId(id .. "_drag"), 0, true)
        if drag == nil then error("slider drag surface creation failed") end
        drag:SetExtent(sliderW, sliderH)
        drag:AddAnchor("TOPLEFT", slider, 0, 0)
        if drag.Enable ~= nil then pcall(function() drag:Enable(true) end) end
        if drag.EnablePick ~= nil then pcall(function() drag:EnablePick(true, true) end) end
        if drag.Clickable ~= nil then pcall(function() drag:Clickable(true, true) end) end
        if drag.EnableDrag ~= nil then pcall(function() drag:EnableDrag(true) end) end
        if drag.SetDragCondition ~= nil and DC_ALWAYS ~= nil then pcall(function() drag:SetDragCondition(DC_ALWAYS) end) end
        if drag.CreateColorDrawable ~= nil then
            local hit = drag:CreateColorDrawable(0, 0, 0, 0.001, "overlay")
            if hit and hit.AddAnchor then hit:AddAnchor("TOPLEFT", drag, 0, 0); hit:AddAnchor("BOTTOMRIGHT", drag, 0, 0) end
        end
        slider.rsDragSurface = drag

        function slider:GetValue()
            return tonumber(self.rsValue) or tonumber(self.rsMinimum) or 0
        end
        function slider:SetValue(v, notify)
            local nv = ClampSliderValue(self, v)
            local changed = nv ~= self.rsValue
            self.rsValue = nv
            UIX:UpdateSliderVisual(self, nv)
            if changed and notify == true and type(self.rsValueChanged) == "function" then
                self.rsValueChanged(nv, false)
            end
            return nv
        end
        function slider:SetValueChangedHandler(fn)
            self.rsValueChanged = type(fn) == "function" and fn or nil
        end
        function slider:SetEnabled(enabled)
            self.rsEnabled = enabled ~= false
            if drag.Enable ~= nil then pcall(function() drag:Enable(self.rsEnabled) end) end
            if drag.EnablePick ~= nil then pcall(function() drag:EnablePick(self.rsEnabled, true) end) end
            if drag.Clickable ~= nil then pcall(function() drag:Clickable(self.rsEnabled, true) end) end
            if self.rsTrack ~= nil and type(self.rsTrack.SetColor) == "function" then
                if self.rsEnabled then self.rsTrack:SetColor(0.26, 0.31, 0.37, 0.95)
                else self.rsTrack:SetColor(0.16, 0.18, 0.21, 0.55) end
            end
            if self.rsThumbButton ~= nil and self.rsThumbButton.Show ~= nil then self.rsThumbButton:Show(true) end
            UIX:UpdateSliderVisual(self, self.rsValue)
        end

        local function EffectiveX(widget)
            if widget == nil then return nil end
            if type(widget.GetEffectiveOffset) == "function" then
                local okOffset, ox = pcall(function() local xx = widget:GetEffectiveOffset(); return xx end)
                if okOffset and tonumber(ox) ~= nil then return tonumber(ox) end
            end
            if type(widget.GetOffset) == "function" then
                local okOffset, ox = pcall(function() local xx = widget:GetOffset(); return xx end)
                if okOffset and tonumber(ox) ~= nil then return tonumber(ox) end
            end
            return nil
        end

        local function SyncFromDrag(final)
            if slider.rsDragging ~= true and final ~= true then return end
            local currentX = EffectiveX(drag)
            local startX = tonumber(slider.rsDragStartX)
            if currentX == nil or startX == nil then return end
            local range = (tonumber(slider.rsMaximum) or 100) - (tonumber(slider.rsMinimum) or 0)
            local thumbW = math.max(10, tonumber(slider.rsThumbWidth) or 18)
            local currentW = slider.GetWidth and slider:GetWidth() or slider.rsWidth
            local travel = math.max(1, (tonumber(currentW) or sliderW) - thumbW)
            local startValue = tonumber(slider.rsDragStartValue) or tonumber(slider.rsValue) or 0
            local nv = ClampSliderValue(slider, startValue + ((currentX - startX) / travel) * range)
            local changed = nv ~= slider.rsValue
            slider.rsValue = nv
            UIX:UpdateSliderVisual(slider, nv)
            if changed and type(slider.rsValueChanged) == "function" then
                slider.rsValueChanged(nv, final == true)
            elseif final == true and type(slider.rsValueChanged) == "function" then
                -- Commit even when quantisation returns to the same value so a
                -- staged preview always receives its final persistence fence.
                slider.rsValueChanged(nv, true)
            end
        end

        local dragTaskName = "ui_custom_slider:" .. tostring(id)
        UIX:SafeHandler(drag, "OnDragStart", function()
            if slider.rsEnabled == false then return false end
            slider.rsDragging = true
            slider.rsDragStartX = EffectiveX(drag)
            slider.rsDragStartValue = slider.rsValue
            if type(drag.StartMoving) == "function" then drag:StartMoving() end
            -- Do not depend on the widget exposing an OnUpdate event.  The Suite
            -- scheduler is already a validated frame driver; a temporary 50 ms
            -- task exists only while the user is dragging and samples X delta.
            if S.Scheduler ~= nil and type(S.Scheduler.AddTask) == "function" then
                S.Scheduler:RemoveTask(dragTaskName)
                S.Scheduler:AddTask(dragTaskName, 50, function()
                    if slider.rsDragging == true then SyncFromDrag(false) end
                end, true, slider, "P1")
            end
            return true
        end, "slider:" .. tostring(id) .. ":drag_start")

        -- Fallback for clients where the scheduler has not started yet (for
        -- example during very early UI construction).  If supported, OnUpdate
        -- provides the same X-only sampling; duplicate samples are harmless.
        UIX:SafeHandler(drag, "OnUpdate", function()
            if slider.rsDragging == true and (S.Scheduler == nil or S.Scheduler.tasks == nil or S.Scheduler.tasks[dragTaskName] == nil) then
                SyncFromDrag(false)
            end
        end, "slider:" .. tostring(id) .. ":drag_update_fallback")

        UIX:SafeHandler(drag, "OnDragStop", function()
            SyncFromDrag(true)
            if S.Scheduler ~= nil and type(S.Scheduler.RemoveTask) == "function" then S.Scheduler:RemoveTask(dragTaskName) end
            if type(drag.StopMovingOrSizing) == "function" then drag:StopMovingOrSizing() end
            slider.rsDragging = false
            slider.rsDragStartX = nil
            slider.rsDragStartValue = nil
            UIX:UpdateSliderVisual(slider, slider.rsValue)
            return true
        end, "slider:" .. tostring(id) .. ":drag_stop")

        UIX:UpdateSliderVisual(slider, slider.rsValue)
        drag:Show(true)
        slider:Show(true)
    end)
    if not configured then return nil end
    slider.rsUiOwner = parent and (parent.rsUiOwner or (parent.rsHudOwner and ("hud:" .. tostring(parent.rsHudOwner)))) or nil
    if type(self.PrimeNativeState) == "function" then
        self:PrimeNativeState(slider, { width = math.max(20, tonumber(width) or 140), height = math.max(14, tonumber(height) or 20), visible = true, anchorTopLeft = { parent = parent, x = x or 0, y = y or 0 } })
    end
    return self:Register(id, slider)
end

function UIX:CreateButton(parent, id, text, x, y, width, height, fontSize, active, useGradient)
    local button = S.NativeObjectFactory and S.NativeObjectFactory:CreateChild(parent, "button", S.PhysicalId(id), 0, true) or nil
    if button == nil then return nil end
    button:SetText(tostring(text or ""))
    button.rsHudOwner = parent and parent.rsHudOwner or nil
    button.rsUiOwner = parent and (parent.rsUiOwner or (parent.rsHudOwner and ("hud:" .. tostring(parent.rsHudOwner)))) or nil
    button.rsUiParent = parent
    button.rsBaseFontSize = tonumber(fontSize)
    S.Theme:StyleButton(button, width, height or (S.UITokens and S.UITokens:Number("size.buttonH", 26)) or 26, fontSize or (S.UITokens and S.UITokens:Number("font.body", 11)) or 11, active, useGradient)
    button:AddAnchor("TOPLEFT", parent, x or 0, y or 0)
    if button.Enable ~= nil then button:Enable(true) end
    if button.EnablePick ~= nil then button:EnablePick(true) end
    if button.Clickable ~= nil then button:Clickable(true) end
    button:Show(true)
    if type(self.PrimeNativeState) == "function" then
        self:PrimeNativeState(button, {
            text = tostring(text or ""), width = math.max(1, width or 80), height = math.max(1, height or 26),
            visible = true, enabled = true, pickable = true, anchorTopLeft = { parent = parent, x = x or 0, y = y or 0 },
            fontSize = button.rsAppliedFontSize,
        })
    end
    return self:Register(id, button)
end

function UIX:SetAnchor(widget, parent, x, y)
    if widget == nil then return end
    if widget.RemoveAllAnchors ~= nil then widget:RemoveAllAnchors() end
    widget:AddAnchor("TOPLEFT", parent, x or 0, y or 0)
end

function UIX:SetVisible(widget, visible)
    if widget ~= nil and widget.Show ~= nil then widget:Show(visible == true) end
end

-- ui_functions.lua exposes SetUILayer on Window, not on every WidgetBase.
-- Some ArcheRage builds may additionally expose it on selected widgets, so all
-- layer changes must be capability-checked and protected by pcall.
function UIX:TrySetUILayer(widget, layerName)
    if widget == nil or type(widget.SetUILayer) ~= "function" then return false end
    local ok = pcall(function() widget:SetUILayer(layerName or "system") end)
    return ok == true
end

function UIX:NotifyPagesHidden(exceptName)
    for pageName, page in pairs(self.pages or {}) do
        if pageName ~= exceptName and type(page) == "table" and type(page.OnPageHidden) == "function" then
            local ok, err = xpcall(function() page:OnPageHidden() end, S.SafeTraceback)
            if not ok then S.WarnOnce("page_hide:" .. tostring(pageName), "页面隐藏清理异常 [" .. tostring(pageName) .. "]：" .. tostring(err)) end
        end
    end
end

function UIX:HideAll(preserveEntry)
    self:NotifyPagesHidden(nil)
    if S.Dropdown ~= nil and type(S.Dropdown.CloseAll) == "function" then S.Dropdown:CloseAll() end
    if S.RSUI ~= nil and S.RSUI.ContextMenu ~= nil and type(S.RSUI.ContextMenu.Close) == "function" then S.RSUI.ContextMenu:Close() end
    if S.RSUI ~= nil and S.RSUI.Tooltip ~= nil and type(S.RSUI.Tooltip.Hide) == "function" then S.RSUI.Tooltip:Hide() end
    for _, window in pairs(self.windows or {}) do pcall(function() window:Show(false) end) end
    for _, widget in pairs(self.widgets or {}) do
        if type(widget) == "table" and widget.window ~= nil then pcall(function() widget.window:Show(false) end) end
    end
    if self.controls.entry ~= nil then
        pcall(function() self.controls.entry:Show(preserveEntry == true) end)
    elseif preserveEntry == true and S.RecoveryEntry ~= nil then
        pcall(function() S.RecoveryEntry:Show(true) end)
    end
    if self.controls.entryTooltip ~= nil then pcall(function() self.controls.entryTooltip:Show(false) end) end
    if S.MainWindow ~= nil and S.MainWindow.chromeTooltip ~= nil then
        pcall(function() S.MainWindow.chromeTooltip:Show(false) end)
    end
    if self.controls.widget_chrome_tooltip ~= nil then
        pcall(function() self.controls.widget_chrome_tooltip:Show(false) end)
    end
end

function UIX:ToggleMain()
    local window = self.windows.main
    if window == nil then return end
    local nextVisible = not window:IsVisible()
    if not nextVisible then self:NotifyPagesHidden(nil) end
    if not nextVisible and S.Dropdown ~= nil and type(S.Dropdown.CloseAll) == "function" then S.Dropdown:CloseAll() end
    if not nextVisible and S.RSUI ~= nil and S.RSUI.ContextMenu ~= nil and type(S.RSUI.ContextMenu.Close) == "function" then S.RSUI.ContextMenu:Close() end
    if not nextVisible and S.RSUI ~= nil and S.RSUI.Tooltip ~= nil and type(S.RSUI.Tooltip.Hide) == "function" then S.RSUI.Tooltip:Hide() end
    if not nextVisible and S.MainWindow ~= nil and S.MainWindow.chromeTooltip ~= nil then
        pcall(function() S.MainWindow.chromeTooltip:Show(false) end)
    end
    window:Show(nextVisible)
    if nextVisible then
        -- Gentle fade-in for the modern look. pcall-guarded: window alpha
        -- animation is part of the client's windowcommon helper set and is safe
        -- on RU; if it ever fails the window simply stays fully opaque.
        if window.SetAlphaAnimation ~= nil then
            pcall(function() window:SetAlphaAnimation(0.0, 1.0, 0.12, 0.12) end)
        end
        if self.currentPage == "life" and S.State ~= nil and type(S.State.runtime) == "table" then S.State.runtime.homeSeen = true end
        -- Opening a window must stay cheap.  World-backed reads and a full
        -- child-window layout can each be tens of milliseconds, so schedule
        -- them after this native click has returned instead of extending input
        -- dispatch.  Existing data remains visible until the refresh publishes.
        if S.Scheduler ~= nil and type(S.Scheduler.AddTask) == "function" then
            local refreshTask = "main_open_refresh"
            S.Scheduler:RemoveTask(refreshTask)
            S.Scheduler:AddTask(refreshTask, 50, function()
                S.Scheduler:RemoveTask(refreshTask)
                if window:IsVisible() and S.Runtime ~= nil and type(S.Runtime.RefreshForMainOpen) == "function" then
                    local ok, err = xpcall(function() S.Runtime:RefreshForMainOpen() end, S.SafeTraceback)
                    if not ok then S.WarnOnce("main_open_refresh", "首次打开数据刷新异常：" .. tostring(err)) end
                end
            end, true, nil, "P2")
            local taskName = "main_show_reflow"
            S.Scheduler:RemoveTask(taskName)
            S.Scheduler:AddTask(taskName, 120, function()
                S.Scheduler:RemoveTask(taskName)
                if window:IsVisible() and S.Layout ~= nil then
                    -- ArcheRage can defer effective child geometry while the
                    -- parent was hidden.  Solve once on the next scheduler
                    -- frame, after the input dispatch and data-read task.
                    S.Layout:Invalidate()
                    S.Layout:GetContext(true)
                    UIX:ApplyResponsiveLayout(true)
                end
            end, false, nil, "P3")
        end
    end
    if window:IsVisible() and window.Raise ~= nil then pcall(function() window:Raise() end) end
end

-- UI Foundation v3 page-layout authority bridge. RSUI roots can invalidate
-- their owning legacy page without directly calling that page's ApplyLayout.
-- The bridge only clears the page signature immediately; visible-page reflow is
-- coalesced through the Suite Scheduler, so a burst of child invalidations
-- becomes one outer layout transaction rather than N nested ApplyLayout calls.
function UIX:InvalidatePageLayout(name, reason)
    local page = self.pages and self.pages[name] or nil
    if page == nil then return false end
    page._rsLayoutSignature = nil
    page._rsLayoutInvalidationReason = tostring(reason or "rsui")
    if tostring(self.currentPage or "") ~= tostring(name or "") then return true end
    local collapsed = S.State and S.State.ui and S.State.ui.main and S.State.ui.main.collapsed == true
    if collapsed then return true end
    if page._rsOuterLayoutScheduled == true then return true end
    local scheduler = S.Scheduler
    if scheduler == nil or type(scheduler.AddTask) ~= "function" then return true end
    local taskName = "ui_page_layout:" .. tostring(name)
    page._rsOuterLayoutScheduled = true
    scheduler:RemoveTask(taskName)
    scheduler:AddTask(taskName, 50, function()
        if S.Scheduler ~= nil and type(S.Scheduler.RemoveTask) == "function" then S.Scheduler:RemoveTask(taskName) end
        page._rsOuterLayoutScheduled = false
        if tostring(UIX.currentPage or "") == tostring(name or "") then
            UIX:EnsurePageLayout(name, true)
        end
    end, true, page, "P2", 1)
    return true
end

function UIX:BindPageLayoutAuthority(name, page)
    if type(page) ~= "table" or page._rsLayoutAuthorityBound == true then return false end
    local component = page.component
    if component == nil or type(component.SetLayoutHost) ~= "function" then return false end
    local host = {}
    function host:InvalidateMeasure(reason) return UIX:InvalidatePageLayout(name, reason or "measure") end
    function host:InvalidateLayout(reason) return UIX:InvalidatePageLayout(name, reason or "layout") end
    component:SetLayoutHost(host)
    page._rsLayoutHost = host
    page._rsLayoutAuthorityBound = true
    return true
end

-- M6 lazy page-layout fence. Outer shell/resolution changes lay out only the
-- currently visible page. Hidden pages keep a compact signature and are solved
-- once, immediately before they become visible. This preserves responsive
-- correctness while avoiding a full M1-M5 page-tree layout pass on every
-- monitor/UI-scale/main-window resize event.
function UIX:EnsurePageLayout(name, force, spec)
    local page = self.pages and self.pages[name] or nil
    if page == nil or type(page.ApplyLayout) ~= "function" then return false, "no_layout" end
    self:BindPageLayoutAuthority(name, page)
    spec = type(spec) == "table" and spec or (S.Layout and S.Layout:GetMainSpec() or nil)
    if type(spec) ~= "table" then return false, "spec_unavailable" end
    local context = S.Layout and S.Layout:GetContext() or {}
    local signature = table.concat({
        string.format("%.2f", tonumber(spec.contentWidth) or 0),
        string.format("%.2f", tonumber(spec.contentHeight) or 0),
        string.format("%.2f", tonumber(spec.width) or 0),
        string.format("%.2f", tonumber(spec.height) or 0),
        string.format("%.3f", tonumber(context.addonScale) or 1),
        string.format("%.3f", tonumber(S.State and S.State.settings and S.State.settings.fontScale) or 1),
    }, ":")
    if force ~= true and page._rsLayoutSignature == signature then return false, "unchanged" end
    page.lastLayoutSpec = spec
    local ok, err = xpcall(function() page:ApplyLayout(spec) end, S.SafeTraceback)
    if not ok then
        S.WarnOnce("page_layout:" .. tostring(name), "页面布局异常 [" .. tostring(name) .. "]：" .. tostring(err))
        if S.DiagnosticsManager ~= nil and type(S.DiagnosticsManager.Record) == "function" then
            S.DiagnosticsManager:Record("error", "layout:" .. tostring(name), tostring(err))
        end
        return false, err
    end
    page._rsLayoutSignature = signature
    return true
end

function UIX:ShowPage(name)
    if name == "activity" then name = "life" end
    if name == "combat" then name = "dps" end
    -- Target Inspector UI was removed because BUFF显示/状态追踪 is the single
    -- user-facing effect inspection Authority. Preserve old favorites/hotlinks.
    if name == "target" then name = "plates" end
    if S.Dropdown ~= nil and type(S.Dropdown.CloseAll) == "function" then S.Dropdown:CloseAll() end
    local target = self.pages[name]
    if target == nil then return false end
    self:NotifyPagesHidden(name)
    self.currentPage = name
    S.State.runtime.activePage = name
    if S.State ~= nil and type(S.State.product) == "table" then
        -- lastPage is a persisted navigation preference used by
        -- defaultStartPage="last".  It used to update only the live table, so
        -- simply switching pages and relogging could restore an older page.
        -- Debounce through Suite Storage because page navigation can be bursty.
        if tostring(S.State.product.lastPage or "") ~= tostring(name) then
            S.State.product.lastPage = name
            if S.Storage ~= nil and type(S.Storage.RequestSave) == "function" then
                S.Storage:RequestSave()
            end
        end
    end
    local collapsed = S.State.ui and S.State.ui.main and S.State.ui.main.collapsed == true
    for pageName, page in pairs(self.pages) do
        if page.root ~= nil then page.root:Show(not collapsed and pageName == name) end
    end
    if not collapsed then self:EnsurePageLayout(name, false) end
    if not collapsed and type(target.Refresh) == "function" then
        local ok, err = xpcall(function() target:Refresh() end, S.SafeTraceback)
        if not ok then S.WarnOnce("page_refresh:" .. tostring(name), "页面刷新异常 [" .. tostring(name) .. "]：" .. tostring(err)) end
    end
    if S.MainWindow ~= nil and S.MainWindow.RefreshTabs ~= nil then S.MainWindow:RefreshTabs() end
    return true
end

function UIX:ToggleWidget(name)
    if S.HudManager ~= nil and S.HudManager:Get(name) ~= nil then
        S.HudManager:ToggleVisible(name)
        return
    end
    local widget = self.widgets[name]
    local placement = S.State.ui.widgets[name]
    if widget == nil or placement == nil then return end
    placement.visible = not (widget.window ~= nil and widget.window:IsVisible())
    if widget.SetVisible ~= nil then widget:SetVisible(placement.visible) elseif widget.window ~= nil then widget.window:Show(placement.visible) end
    S.Storage:RequestSave()
end

function UIX:ApplyResponsiveLayout(fromMetricsChange)
    -- V3 owns responsive presentation through UIHostManager. This compatibility
    -- method remains because low-level UI code may still call it, but it must not
    -- execute the legacy S.State/MainWindow path in rebuild mode.
    if tostring(S.ArchitectureMode or "") == "v3_rebuild" then
        if S.Theme ~= nil and type(S.Theme.RefreshTypography) == "function" then S.Theme:RefreshTypography() end
        if S.RSUI ~= nil and type(S.RSUI.RefreshResolutionRoots) == "function" then pcall(function() S.RSUI:RefreshResolutionRoots(true) end) end
        if S.UIHostManager ~= nil and type(S.UIHostManager.ApplyResponsiveLayout) == "function" and S.UIHostManager:GetActive() ~= nil then
            return S.UIHostManager:ApplyResponsiveLayout(fromMetricsChange == true)
        end
        return false
    end
    if S.Theme ~= nil and type(S.Theme.RefreshTypography) == "function" then S.Theme:RefreshTypography() end
    if S.MainWindow ~= nil and S.MainWindow.ApplyLayout ~= nil then S.MainWindow:ApplyLayout(fromMetricsChange == true) end
    if S.MainButton ~= nil and S.MainButton.ApplyLayout ~= nil then S.MainButton:ApplyLayout(fromMetricsChange == true) end
    for _, widget in pairs(self.widgets or {}) do
        if type(widget) == "table" and widget.ApplyLayout ~= nil then widget:ApplyLayout(fromMetricsChange == true) end
    end
    if S.QuestDetailWindow ~= nil and S.QuestDetailWindow.window ~= nil and type(S.QuestDetailWindow.ApplyLayout) == "function" then
        S.QuestDetailWindow:ApplyLayout(fromMetricsChange == true)
    end
    if S.DailyCustomWindow ~= nil and S.DailyCustomWindow.window ~= nil and type(S.DailyCustomWindow.ApplyLayout) == "function" then
        S.DailyCustomWindow:ApplyLayout(fromMetricsChange == true)
    end
    if S.TradeDetailWindow ~= nil and S.TradeDetailWindow.window ~= nil and type(S.TradeDetailWindow.ApplyLayout) == "function" then
        S.TradeDetailWindow:ApplyLayout(fromMetricsChange == true)
    end
    -- Professional modules keep their own persistence Authority, but resolution
    -- changes still need one shared presentation-safety pass. This pass never
    -- writes module saves; it only reapplies/clamps the live viewport.
    if S.HudManager ~= nil and type(S.HudManager.OnMetricsChanged) == "function" then
        S.HudManager:OnMetricsChanged(fromMetricsChange == true)
    end
    if S.Layout ~= nil and type(S.Layout.RefreshFloatingSafety) == "function" then
        S.Layout:RefreshFloatingSafety(fromMetricsChange == true)
    end
    if S.State ~= nil and type(S.State.runtime) == "table" then
        S.State.runtime.layoutRevision = (tonumber(S.State.runtime.layoutRevision) or 0) + 1
    end
    return true
end


function UIX:RefreshData(dirty)
    dirty = type(dirty) == "table" and dirty or { all = true }
    local refreshAll = dirty.all == true
    if S.MainButton ~= nil and type(S.MainButton.RefreshData) == "function" and (refreshAll or dirty.quests or dirty.resources or dirty.events) then S.MainButton:RefreshData() end
    local life = self.pages and self.pages.life
    if life ~= nil and type(life.Refresh) == "function" and (refreshAll or dirty.quests or dirty.resources or dirty.events or dirty.trade or dirty.resident or dirty.character or dirty.treasure or dirty.fishing) then
        -- Data refresh owns text/rows only.  MainWindow/Layout is the sole
        -- Authority for outer geometry, preventing asynchronous service updates
        -- from resizing cards underneath the player.
        -- Pass the consumed dirty mask through as optional presentation context.
        -- Legacy pages ignore extra arguments; M2 dashboard uses it to avoid
        -- rebuilding unrelated card projections on frequent event updates.
        life:Refresh(dirty)
    end
    -- M3 Life workspaces are refreshed only while selected. Hidden pages do
    -- not need presentation rebinds because ShowPage() performs one Refresh()
    -- when the player opens them. This keeps frequent event updates away from
    -- Trade/Bond/Task tables and avoids unnecessary RSUI reconcile work.
    local lifeWorkspaceDirty = {
        life_activity = refreshAll or dirty.events or dirty.quests,
        life_trade = refreshAll or dirty.trade,
        life_bond = refreshAll or dirty.resident or dirty.resources,
        life_tasks = refreshAll or dirty.quests or dirty.events,
        life_treasure = refreshAll or dirty.treasure or dirty.resources,
        life_fishing = refreshAll or dirty.fishing,
    }
    local activeLifePage = self.currentPage
    if lifeWorkspaceDirty[activeLifePage] == true then
        local workspace = self.pages and self.pages[activeLifePage]
        if workspace ~= nil and type(workspace.Refresh) == "function" then workspace:Refresh(dirty) end
    end
    -- `pages.combat` was removed when DPS/Healer/Gear/Plates became first-class
    -- Suite pages, but profile/module actions still mark the shared `combat`
    -- dirty section. Refresh the visible professional page instead of silently
    -- dropping that invalidation.
    if refreshAll or dirty.combat or dirty.modules then
        for _, pageName in ipairs({ "dps", "healer", "gear", "plates" }) do
            local professional = self.pages and self.pages[pageName]
            if professional ~= nil and type(professional.Refresh) == "function"
                and (refreshAll or self.currentPage == pageName) then
                professional:Refresh()
            end
        end
    end
    local quick = self.pages and self.pages.quick
    if quick ~= nil and type(quick.Refresh) == "function" and (refreshAll or dirty.treasure or dirty.fishing or dirty.hud or dirty.favorites) then quick:Refresh() end
    local team = self.pages and self.pages.team
    if team ~= nil and type(team.Refresh) == "function" and (refreshAll or dirty.teamUtility or dirty.modules) then team:Refresh() end
    local modules = self.pages and self.pages.modules
    if modules ~= nil and type(modules.Refresh) == "function" and (refreshAll or dirty.modules or dirty.combat) then modules:Refresh() end
    local hud = self.pages and self.pages.hud
    if hud ~= nil and type(hud.Refresh) == "function" and (refreshAll or dirty.hud or dirty.modules) then hud:Refresh() end
    local diagnostics = self.pages and self.pages.diagnostics
    if diagnostics ~= nil and type(diagnostics.Refresh) == "function"
        and (refreshAll or (self.currentPage=="diagnostics" and (dirty.modules or dirty.combat or dirty.hud))) then
        diagnostics:Refresh()
    end
    if (refreshAll or dirty.quests) and S.QuestDetailWindow ~= nil and S.QuestDetailWindow.window ~= nil and S.QuestDetailWindow.window:IsVisible() and type(S.QuestDetailWindow.Reload) == "function" then
        S.QuestDetailWindow:Reload()
    end
    if (refreshAll or dirty.quests) and S.DailyCustomWindow ~= nil and S.DailyCustomWindow.window ~= nil and S.DailyCustomWindow.window:IsVisible() and type(S.DailyCustomWindow.Refresh) == "function" then
        S.DailyCustomWindow:Refresh()
    end
    if (refreshAll or dirty.trade) and S.TradeDetailWindow ~= nil and S.TradeDetailWindow.window ~= nil and S.TradeDetailWindow.window:IsVisible() and type(S.TradeDetailWindow.Refresh)=="function" then S.TradeDetailWindow:Refresh() end
    for _, name in ipairs({ "task", "trade", "bond", "event", "treasure", "fishing" }) do
        local widget = self.widgets and self.widgets[name]
        if widget ~= nil and type(widget.Refresh) == "function" then
            -- Map widget name -> State dirty section key.  Note the plural
            -- mismatches: task->quests, bond->resident, event->events (the
            -- Event service marks "events", never the singular "event").
            local section = name == "task" and "quests" or name == "bond" and "resident" or name == "event" and "events" or name
            if refreshAll or dirty[section] or (name == "bond" and dirty.resources) then widget:Refresh() end
        end
    end
end
