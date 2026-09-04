------------------------------------------------------------------------
-- Replicated Suite - V3 Native Primitive Factory
--
-- Active V3 Foundation only.  Legacy ManagedWindow/Page navigation helpers
-- were moved to legacy_reference/ui and are deliberately not loaded.  This
-- file owns primitive native control construction/registration only; geometry
-- and presentation mutations are subsequently owned by rs_ui_framework.lua.
------------------------------------------------------------------------

if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite

S.UI = {
    controls = {},
    registryMetrics = { duplicates = 0, v3Duplicates = 0, degraded = 0 },
}
local UIX = S.UI

local function TrackNativeBuildWidget(widget)
    local rsui = S.RSUI
    if widget ~= nil and type(rsui) == "table" and type(rsui.TrackBuildWidget) == "function" then rsui:TrackBuildWidget(widget) end
    return widget
end

local function MarkPrimitiveDegraded(widget, id, detail)
    if widget == nil then return nil end
    UIX.registryMetrics.degraded = (tonumber(UIX.registryMetrics.degraded) or 0) + 1
    pcall(function()
        local owner = widget.rsUiOwner
        -- Apply the final defensive state before marking the widget degraded;
        -- the Diff Authority intentionally rejects already-degraded widgets.
        if type(UIX.SetEnabled) == "function" then UIX:SetEnabled(widget, false, owner) end
        if type(UIX.SetPickable) == "function" then UIX:SetPickable(widget, false, owner) end
        if type(UIX.SetVisible) == "function" then UIX:SetVisible(widget, false, owner) end
        widget.rsUiDegraded = true
        widget.rsUiDegradedReason = tostring(detail or "native primitive configuration failed")
    end)
    local diagnostics = S.DiagnosticsManager
    if type(diagnostics) == "table" and type(diagnostics.Emit) == "function" then
        diagnostics:Emit("error", "ui", "NATIVE_PRIMITIVE_DEGRADED", "原生控件已创建但初始化失败，已隐藏并隔离", {
            id = tostring(id or ""), error = tostring(detail or "configuration_failed"),
        })
    end
    return widget
end

local function IsRootParent(parent)
    return parent == "UIParent" or parent == UIParent
end

local function RootNativeParent(parent)
    if IsRootParent(parent) then return "UIParent" end
    return parent
end

local function RootAnchorParent(parent)
    if IsRootParent(parent) then return "UIParent" end
    return parent
end

local function RootStateParent(parent)
    if IsRootParent(parent) then return UIParent end
    return parent
end

function UIX:Register(id, widget)
    TrackNativeBuildWidget(widget)
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
                -- SetVisible(false) may legitimately return false on a cache-hit;
                -- it is still the only visibility Authority for rejected V3 UI.
                if type(UIX.SetVisible) == "function" then pcall(function() UIX:SetVisible(widget, false, owner) end) end
                if type(S.RecordLog) == "function" then
                    S.RecordLog("error", "ui_v3", "DUPLICATE_COMPONENT_ID:" .. key .. ":owner=" .. owner .. ":previous=" .. previousOwner)
                end
                local d = S.DiagnosticsManager
                if type(d) == "table" and type(d.Emit) == "function" then
                    d:Emit("error", "ui_v3", "DUPLICATE_COMPONENT_ID", "V3 UI 控件 ID 重复，已安全拒绝新控件", {
                        id = key, owner = owner, previousOwner = previousOwner,
                    })
                end
                -- Never alias the rejected native object to the previously
                -- registered widget. Returning the old object lets the caller
                -- continue layout with the wrong parent/type and can cross the
                -- Lua/native ownership boundary with stale geometry.
                return nil
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
        degraded = tonumber(self.registryMetrics and self.registryMetrics.degraded) or 0,
    }
end

function UIX:SafeHandler(widget, eventName, fn, label)
    if widget == nil or type(widget.SetHandler) ~= "function" or type(fn) ~= "function" then return false end
    -- Handler binding is also a native write.  A rejected/stale widget must not
    -- receive callbacks that can outlive its RSUI owner or reach a previous hot-
    -- reload generation.  rs_ui_framework.lua installs IsWidgetUsable after this
    -- primitive module loads; honor it whenever available.
    if type(self.IsWidgetUsable) == "function" and self:IsWidgetUsable(widget) ~= true then return false end
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
        if type(UIX.IsWidgetUsable) == "function" and UIX:IsWidgetUsable(widget) ~= true then return nil end
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
            local diagnostics = S.DiagnosticsManager
            if type(diagnostics) == "table" and type(diagnostics.Error) == "function" then
                diagnostics:Error("ui_event", "UI_HANDLER_EXCEPTION", "原生界面事件回调执行失败", {
                    event = tostring(eventName or ""), label = tostring(label or eventName or ""),
                    logicalId = tostring(widget and (widget.rsUiLogicalId or widget.rsNativeLogicalId) or ""),
                    owner = tostring(widget and widget.rsUiOwner or ""), error = tostring(err),
                })
            end
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
    if not bound then
        -- A silently unbound OnClick reads to the user as a dead button (§9.3
        -- bag regression candidate). Surface it once per label instead of
        -- returning a flag every caller ignores.
        local diagnostics = S.DiagnosticsManager
        if type(diagnostics) == "table" and type(diagnostics.Warn) == "function" then
            diagnostics:Warn("ui_event", "UI_HANDLER_BIND_FAILED", "原生界面事件绑定失败，该控件点击将无响应", {
                event = tostring(eventName or ""), label = tostring(label or eventName or ""),
                logicalId = tostring(widget and (widget.rsUiLogicalId or widget.rsNativeLogicalId) or ""),
            })
        end
        if type(S.WarnOnce) == "function" then
            S:WarnOnce("rsui_bind_failed_" .. tostring(label or eventName),
                "界面事件绑定失败：" .. tostring(label or eventName) .. "（" .. tostring(eventName) .. "），该按钮可能无响应，请在诊断页查看详情")
        end
    end
    return bound
end

-- SetUILayer is optional in ArcheAge/RU: ui_functions exposes it on Window,
-- while several WidgetBase variants do not implement it at all. Active V3
-- code must therefore never call SetUILayer directly or assume the legacy
-- UI factory is loaded. This adapter is intentionally fail-open; callers can
-- fall back to draw priority without making a whole Page/Dropdown transaction
-- fail.
function UIX:TrySetUILayer(widget, layerName)
    if widget == nil or type(widget.SetUILayer) ~= "function" then return false end
    local ok, result = pcall(function() return widget:SetUILayer(layerName or "system") end)
    return ok == true and result ~= false
end

-- Standard lifecycle for ordinary dialogs. HUD widgets keep using WidgetBase
-- and HudManager; dialogs get a smaller API with the same logical placement,
-- safe drag, sizing bounds, opacity and font ownership rules.
function UIX:CreateEmptyWidget(parent, id, x, y, width, height, pickable, explicitOwner)
    local factory = S.NativeObjectFactory
    if type(factory) ~= "table" or parent == nil then return nil, "native_factory_or_parent_unavailable" end
    local rootParent = IsRootParent(parent)
    if rootParent ~= true and type(parent.CreateChildWidget) ~= "function" then return nil, "CreateChildWidget unavailable" end
    local widget, nativeErr
    if rootParent then
        widget, nativeErr = factory:CreateEmptyWidget(S.PhysicalId(id), "UIParent")
    else
        widget, nativeErr = factory:CreateChild(parent, "emptywidget", S.PhysicalId(id), 0, true)
    end
    if widget == nil then return nil, nativeErr or "emptywidget_create_failed" end
    TrackNativeBuildWidget(widget)
    local anchorParent = RootAnchorParent(parent)
    local stateParent = RootStateParent(parent)
    local ownerParent = rootParent and nil or parent
    widget.rsHudOwner = ownerParent and ownerParent.rsHudOwner or nil
    widget.rsUiOwner = explicitOwner or (ownerParent and (ownerParent.rsUiOwner or (ownerParent.rsHudOwner and ("hud:" .. tostring(ownerParent.rsHudOwner)))) or nil)
    widget.rsUiParent = stateParent
    local configured = pcall(function()
        widget:SetExtent(math.max(1, tonumber(width) or 1), math.max(1, tonumber(height) or 1))
        widget:AddAnchor("TOPLEFT", anchorParent, tonumber(x) or 0, tonumber(y) or 0)
        if widget.Enable ~= nil then widget:Enable(true) end
        if widget.EnablePick ~= nil then widget:EnablePick(pickable == true) end
        if widget.Clickable ~= nil then widget:Clickable(pickable == true) end
        widget:Show(true)
    end)
    if not configured then
        MarkPrimitiveDegraded(widget, id, "emptywidget_configuration_failed")
        return self:Register(id, widget)
    end
    if type(self.PrimeNativeState) == "function" then
        self:PrimeNativeState(widget, {
            width = math.max(1, tonumber(width) or 1), height = math.max(1, tonumber(height) or 1),
            visible = true, enabled = true, pickable = pickable == true,
            anchorTopLeft = { parent = stateParent, x = tonumber(x) or 0, y = tonumber(y) or 0 },
        })
    end
    return self:Register(id, widget)
end

function UIX:CreatePanel(parent, id, x, y, width, height, kind, opts)
    opts = type(opts) == "table" and opts or {}
    local factory = S.NativeObjectFactory
    if type(factory) ~= "table" or parent == nil then return nil, "native_factory_or_parent_unavailable" end
    local rootParent = IsRootParent(parent)
    local nativeParent = RootNativeParent(parent)
    local anchorParent = RootAnchorParent(parent)
    local stateParent = RootStateParent(parent)
    local panel, nativeErr = factory:CreateEmptyWidget(S.PhysicalId(id), nativeParent)
    if panel == nil then return nil, nativeErr or "panel_create_failed" end
    TrackNativeBuildWidget(panel)
    local ownerParent = rootParent and nil or parent
    panel.rsHudOwner = ownerParent and ownerParent.rsHudOwner or nil
    -- Top-level transient presentation surfaces (dropdowns/tooltips/menus) are
    -- physically parented to UIParent for z-order safety.  They still belong to
    -- the page/widget that created them, so callers may provide an explicit
    -- logical owner before Register() runs.  This keeps V3 duplicate-ID and
    -- lifecycle checks strict instead of briefly registering the surface as an
    -- unowned legacy widget.
    panel.rsUiOwner = opts.owner or (ownerParent and (ownerParent.rsUiOwner or (ownerParent.rsHudOwner and ("hud:" .. tostring(ownerParent.rsHudOwner)))) or nil)
    panel.rsUiParent = stateParent
    local configured = pcall(function()
        panel:AddAnchor("TOPLEFT", anchorParent, x or 0, y or 0)
        panel:SetExtent(math.max(1, width or 1), math.max(1, height or 1))
        S.Theme:AddBorder(panel, kind == "soft")
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
    end)
    if not configured then
        MarkPrimitiveDegraded(panel, id, "panel_configuration_failed")
        return self:Register(id, panel), "panel_configuration_failed"
    end
    if type(self.PrimeNativeState) == "function" then
        self:PrimeNativeState(panel, {
            width = math.max(1, width or 1), height = math.max(1, height or 1), visible = true,
            anchorTopLeft = { parent = stateParent, x = x or 0, y = y or 0 },
        })
    end
    return self:Register(id, panel)
end

function UIX:CreateLabel(parent, id, text, x, y, width, height, fontSize, tone, align, shadow)
    local factory = S.NativeObjectFactory
    if type(factory) ~= "table" or parent == nil then return nil, "native_factory_or_parent_unavailable" end
    local rootParent = IsRootParent(parent)
    if rootParent ~= true and type(parent.CreateChildWidget) ~= "function" then return nil, "CreateChildWidget unavailable" end
    local label, nativeErr
    if rootParent then
        label, nativeErr = factory:Create("label", S.PhysicalId(id), "UIParent")
    else
        label, nativeErr = factory:CreateChild(parent, "label", S.PhysicalId(id), 0, true)
    end
    if label == nil then return nil, nativeErr or "label_create_failed" end
    TrackNativeBuildWidget(label)
    local anchorParent = RootAnchorParent(parent)
    local stateParent = RootStateParent(parent)
    local ownerParent = rootParent and nil or parent
    label.rsHudOwner = ownerParent and ownerParent.rsHudOwner or nil
    label.rsUiOwner = ownerParent and (ownerParent.rsUiOwner or (ownerParent.rsHudOwner and ("hud:" .. tostring(ownerParent.rsHudOwner)))) or nil
    label.rsUiParent = stateParent
    label.rsBaseFontSize = tonumber(fontSize)
    local configured = pcall(function()
        label:AddAnchor("TOPLEFT", anchorParent, x or 0, y or 0)
        if label.SetAutoResize ~= nil then label:SetAutoResize(false) end
        label:SetExtent(math.max(1, width or 1), math.max(1, height or 1))
        if label.EnablePick ~= nil then label:EnablePick(false) end
        if label.Clickable ~= nil then label:Clickable(false) end
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
    end)
    if not configured then
        MarkPrimitiveDegraded(label, id, "label_configuration_failed")
        return self:Register(id, label), "label_configuration_failed"
    end
    if type(self.PrimeNativeState) == "function" then
        self:PrimeNativeState(label, {
            text = tostring(text or ""), width = math.max(1, width or 1), height = math.max(1, height or 1),
            visible = true, pickable = false, anchorTopLeft = { parent = stateParent, x = x or 0, y = y or 0 },
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
    TrackNativeBuildWidget(edit)
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
    if not configured then
        MarkPrimitiveDegraded(edit, id, "editbox_configuration_failed")
        return self:Register(id, edit)
    end
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
    TrackNativeBuildWidget(edit)
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
    if not configured then
        MarkPrimitiveDegraded(edit, id, "multieditbox_configuration_failed")
        return self:Register(id, edit)
    end
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
    if slider == nil then return false end
    local thumb = slider.rsThumbButton
    if thumb == nil then return false end
    local minimum = tonumber(slider.rsMinimum) or 0
    local maximum = tonumber(slider.rsMaximum) or 100
    local value = ClampSliderValue(slider, explicitValue ~= nil and explicitValue or slider.rsValue)
    slider.rsValue = value
    local width = slider.GetWidth and slider:GetWidth() or tonumber(slider.rsWidth) or 140
    local height = slider.GetHeight and slider:GetHeight() or tonumber(slider.rsHeight) or 20
    local dragging = slider.rsDragging == true

    -- A custom slider is a composite widget: resizing its root does not resize
    -- the rail/drag surface automatically. Cache the visual geometry separately
    -- so framework SetExtent() can cheaply resynchronise stale children without
    -- introducing permanent OnUpdate/Tick work.
    if tonumber(slider.rsVisualWidth) == tonumber(width)
        and tonumber(slider.rsVisualHeight) == tonumber(height)
        and tonumber(slider.rsVisualValue) == tonumber(value)
        and slider.rsVisualDragging == dragging then
        slider.rsWidth, slider.rsHeight = width, height
        return false
    end

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
    slider.rsVisualWidth = width
    slider.rsVisualHeight = height
    slider.rsVisualValue = value
    slider.rsVisualDragging = dragging
    return true
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
    TrackNativeBuildWidget(slider)

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
            -- Interactive sampling borrows the single Suite frame driver only
            -- for the lifetime of this gesture.  Ordinary service tasks retain
            -- their 50 ms floor; sliders can preview at ~16 ms without adding a
            -- permanent widget Tick.
            local scheduled = false
            if S.Scheduler ~= nil and type(S.Scheduler.AddInteractiveTask) == "function" then
                S.Scheduler:RemoveTask(dragTaskName)
                scheduled = S.Scheduler:AddInteractiveTask(dragTaskName, 16, function()
                    if slider.rsUiReleased == true then
                        slider.rsDragging = false
                        if S.Scheduler ~= nil then S.Scheduler:RemoveTask(dragTaskName) end
                        return true
                    end
                    if slider.rsDragging == true then SyncFromDrag(false) end
                    return true
                end, true, slider, "P0", 1) == true
            end
            if scheduled ~= true then
                -- Early boot *and scheduler rejection* fallback. It exists only
                -- for this active gesture and is released on drag stop, so idle
                -- sliders still own no permanent OnUpdate/Tick.
                UIX:SafeHandler(drag, "OnUpdate", function()
                    if slider.rsDragging == true then SyncFromDrag(false) end
                    return true
                end, "slider:" .. tostring(id) .. ":drag_update_fallback")
            end
            SyncFromDrag(false)
            return true
        end, "slider:" .. tostring(id) .. ":drag_start")

        UIX:SafeHandler(drag, "OnDragStop", function()
            SyncFromDrag(true)
            if S.Scheduler ~= nil and type(S.Scheduler.RemoveTask) == "function" then S.Scheduler:RemoveTask(dragTaskName) end
            if type(drag.ReleaseHandler) == "function" then pcall(function() drag:ReleaseHandler("OnUpdate") end) end
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
    if not configured then
        MarkPrimitiveDegraded(slider, id, "slider_configuration_failed")
        return self:Register(id, slider)
    end
    slider.rsUiOwner = parent and (parent.rsUiOwner or (parent.rsHudOwner and ("hud:" .. tostring(parent.rsHudOwner)))) or nil
    if type(self.PrimeNativeState) == "function" then
        self:PrimeNativeState(slider, { width = math.max(20, tonumber(width) or 140), height = math.max(14, tonumber(height) or 20), visible = true, anchorTopLeft = { parent = parent, x = x or 0, y = y or 0 } })
    end
    return self:Register(id, slider)
end

function UIX:CreateButton(parent, id, text, x, y, width, height, fontSize, active, useGradient, explicitOwner)
    local factory = S.NativeObjectFactory
    if type(factory) ~= "table" then return nil, "native_factory_unavailable" end

    -- UIParent is not a normal child-widget host on every RU build.  Top-level
    -- screen controls must go through UIParent:CreateWidget (factory CreateButton),
    -- while panel/page children continue through CreateChildWidget.  Treating a
    -- root button as a child silently returned nil on affected clients, which is
    -- exactly why Gear quick-plan buttons had valid state but no native control.
    local rootParent = IsRootParent(parent)
    local anchorTarget = RootAnchorParent(parent)
    local anchorStateParent = RootStateParent(parent)
    local button, nativeErr
    if rootParent then
        button, nativeErr = factory:CreateButton(S.PhysicalId(id), "UIParent", "")
    else
        button, nativeErr = factory:CreateChild(parent, "button", S.PhysicalId(id), 0, true)
    end
    if button == nil then return nil, nativeErr or "button_create_failed" end
    TrackNativeBuildWidget(button)

    local ownerParent = rootParent and nil or parent
    button.rsHudOwner = ownerParent and ownerParent.rsHudOwner or nil
    button.rsUiOwner = explicitOwner or (ownerParent and (ownerParent.rsUiOwner or (ownerParent.rsHudOwner and ("hud:" .. tostring(ownerParent.rsHudOwner)))) or nil)
    button.rsUiParent = anchorStateParent
    button.rsBaseFontSize = tonumber(fontSize)
    local configured = pcall(function()
        button:SetText(tostring(text or ""))
        S.Theme:StyleButton(button, width, height or (S.UITokens and S.UITokens:Number("size.buttonH", 26)) or 26, fontSize or (S.UITokens and S.UITokens:Number("font.body", 11)) or 11, active, useGradient)
        button:AddAnchor("TOPLEFT", anchorTarget, x or 0, y or 0)
        if button.Enable ~= nil then button:Enable(true) end
        if button.EnablePick ~= nil then button:EnablePick(true) end
        if button.Clickable ~= nil then button:Clickable(true) end
        button:Show(true)
    end)
    if not configured then
        MarkPrimitiveDegraded(button, id, "button_configuration_failed")
        return self:Register(id, button), "button_configuration_failed"
    end
    if type(self.PrimeNativeState) == "function" then
        self:PrimeNativeState(button, {
            text = tostring(text or ""), width = math.max(1, width or 80), height = math.max(1, height or 26),
            visible = true, enabled = true, pickable = true, anchorTopLeft = { parent = anchorStateParent, x = x or 0, y = y or 0 },
            fontSize = button.rsAppliedFontSize,
        })
    end
    return self:Register(id, button)
end
