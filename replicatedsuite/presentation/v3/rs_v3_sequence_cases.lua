------------------------------------------------------------------------
-- Replicated Suite V3 - Foundation Sequence Cases
--
-- Synchronous, bounded probes only. They never register Tick/OnUpdate and must
-- preserve the current V3 shell visibility because Diagnostics itself is a V3
-- page in rebuild mode.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local G, H = S.FoundationGate, S.UIHostManager
local V3 = S.UIV3Host
if type(G) ~= "table" or type(G.RegisterSequenceCase) ~= "function" or type(H) ~= "table" or type(V3) ~= "table" then return end

local function Fail(message) return false, tostring(message or "failed") end
local function Visible(widget)
    local adapter = S.UIV3NativeAdapter
    return type(adapter) == "table" and type(adapter.IsVisible) == "function" and adapter:IsVisible(widget) or false
end
local function Approx(a, b, epsilon)
    a, b = tonumber(a), tonumber(b)
    if a == nil or b == nil then return false end
    return math.abs(a - b) <= (tonumber(epsilon) or 1.0)
end
local function RestoreVisibility(wasVisible)
    if wasVisible then return V3:Open() end
    return V3:Close()
end

G:RegisterSequenceCase("v3_01_contract", function()
    local host = H:Get("v3")
    if host == nil or tonumber(host.contractVersion) < 2 then return Fail("host_contract") end
    if H.defaultId ~= "v3" then return Fail("v3_not_default") end
    local store = S.Persistence and S.Persistence:GetStore("v3.shell") or nil
    if store == nil or tonumber(store.contractVersion) < 3 then return Fail("store_contract") end
    if tostring(store.owner or ""):match("^v3%.") == nil then return Fail("store_owner") end
    if S.FeatureRegistry == nil or S.UIV3 == nil or S.UIV3.Router == nil or S.UIV3.PageHost == nil then return Fail("application_foundation") end
    return true
end)

G:RegisterSequenceCase("v3_02_create_authority", function()
    local host, err = H:Ensure("v3")
    if host == nil then return Fail(err or "ensure") end
    local shell = V3.shell
    local snapshot = shell:GetSnapshot()
    if snapshot.window == nil or snapshot.created ~= true then return Fail("window_missing") end
    if snapshot.owner ~= "v3:shell" or snapshot.authorityMode ~= "strict" then return Fail("strict_authority_missing") end
    if snapshot.rootDirty or snapshot.stackDirty then return Fail("layout_dirty") end
    if snapshot.pageHost == nil or tonumber(snapshot.pageHost.created) < 1 then return Fail("page_host_empty") end
    return true
end)

G:RegisterSequenceCase("v3_03_open_close_restore", function()
    local host, err = H:Ensure("v3")
    if host == nil then return Fail(err or "ensure") end
    local window = V3:GetWindow()
    local wasVisible = Visible(window)
    if V3:Open() ~= true or not Visible(window) then RestoreVisibility(wasVisible); return Fail("open_visibility") end
    if V3:Close() ~= true or Visible(window) then RestoreVisibility(wasVisible); return Fail("close_visibility") end
    if RestoreVisibility(wasVisible) ~= true then return Fail("visibility_restore") end
    return true
end)

G:RegisterSequenceCase("v3_04_resize_reflow", function()
    local host, err = H:Ensure("v3")
    if host == nil then return Fail(err or "ensure") end
    local shell = V3.shell
    local window = V3:GetWindow()
    local wasVisible = Visible(window)
    local state = S.UIV3 and S.UIV3.ShellState or {}
    local restoreW, restoreH = tonumber(state.width) or 1040, tonumber(state.height) or 700
    local beforeAuthority = S.UI:GetAuthoritySnapshot()
    local beforeFramework = S.UI:GetFrameworkSnapshot()

    local ok, rect = shell:ApplyLayout(false, 720, 520)
    if ok ~= true or type(rect) ~= "table" then shell:ApplyLayout(false, restoreW, restoreH); RestoreVisibility(wasVisible); return Fail("resize_apply") end
    local snapshot = shell:GetSnapshot()
    local good = Approx(snapshot.width, rect.width, 1.0) and Approx(snapshot.height, rect.height, 1.0)
        and snapshot.rootDirty ~= true and snapshot.stackDirty ~= true
    shell:ApplyLayout(false, restoreW, restoreH)
    RestoreVisibility(wasVisible)
    if not good then return Fail("resize_geometry") end

    local afterAuthority = S.UI:GetAuthoritySnapshot()
    local afterFramework = S.UI:GetFrameworkSnapshot()
    if (tonumber(afterAuthority.violations) or 0) ~= (tonumber(beforeAuthority.violations) or 0) then return Fail("authority_violation") end
    if (tonumber(afterAuthority.conflicts) or 0) ~= (tonumber(beforeAuthority.conflicts) or 0) then return Fail("authority_conflict") end
    if (tonumber(afterFramework.cacheRepairs) or 0) ~= (tonumber(beforeFramework.cacheRepairs) or 0) then return Fail("cache_repair") end
    return true
end)

G:RegisterSequenceCase("v3_05_reopen_id_stability", function()
    local host, err = H:Ensure("v3")
    if host == nil then return Fail(err or "ensure") end
    local originalWindow = V3:GetWindow()
    local wasVisible = Visible(originalWindow)
    local before = S.UI:GetRegistrySnapshot()
    if V3:Open() ~= true then RestoreVisibility(wasVisible); return Fail("open_1") end
    V3:Close()
    if V3:Open() ~= true then RestoreVisibility(wasVisible); return Fail("open_2") end
    RestoreVisibility(wasVisible)
    local after = S.UI:GetRegistrySnapshot()
    if V3:GetWindow() ~= originalWindow then return Fail("window_recreated") end
    if (tonumber(after.v3Duplicates) or 0) ~= (tonumber(before.v3Duplicates) or 0) then return Fail("duplicate_id") end
    return true
end)

G:RegisterSequenceCase("v3_06_navigation", function()
    local previousRoute = V3.shell and V3.shell.lastRoute or "home"
    local window = V3:GetWindow()
    local wasVisible = Visible(window)
    local ok, err = H:Navigate("foundation:probe", {}, { hostId = "v3", closePrevious = false, openHost = false })
    if ok ~= true then return Fail(err or "navigate_probe") end
    if H.activeId ~= "v3" then return Fail("v3_not_active") end
    local routeOk, routeErr = V3:Navigate(previousRoute == "foundation:probe" and "home" or previousRoute, { keepHidden = not wasVisible, source = "sequence_restore" })
    if routeOk ~= true then RestoreVisibility(wasVisible); return Fail(routeErr or "route_restore") end
    RestoreVisibility(wasVisible)
    return true
end)

G:RegisterSequenceCase("v3_07_window_interaction_foundation", function()
    local host, err = H:Ensure("v3")
    if host == nil then return Fail(err or "ensure") end
    local shell = V3.shell
    local controller = shell and shell.windowController or nil
    if type(controller) ~= "table" or controller.dragHandle == nil then return Fail("window_controller_missing") end
    local handleCount = 0
    for _ in pairs(controller.handles or {}) do handleCount = handleCount + 1 end
    if handleCount ~= 8 then return Fail("resize_handles:" .. tostring(handleCount)) end

    local state = S.UIV3 and S.UIV3.ShellState or nil
    if type(state) ~= "table" then return Fail("shell_state_missing") end
    local window = V3:GetWindow()
    local wasVisible = Visible(window)
    local originalMinimized = state.minimized == true
    state.minimized = true
    shell:ApplyMinimizedState(false)
    local minOk = shell.body ~= nil and shell.body:IsCollapsed() ~= true and controller.resizeEnabled == true
    state.minimized = false
    shell:ApplyMinimizedState(false)
    local restoreOk = shell.body ~= nil and shell.body:IsCollapsed() ~= true and controller.resizeEnabled == true
    state.minimized = originalMinimized
    shell:ApplyMinimizedState(false)
    shell:ApplyLayout(false)
    RestoreVisibility(wasVisible)
    if not minOk then return Fail("minimize_to_launcher_contract") end
    if not restoreOk then return Fail("restore_contract") end
    return true
end)

G:RegisterSequenceCase("v3_08_navigation_critical_access", function()
    local host, err = H:Ensure("v3")
    if host == nil then return Fail(err or "ensure") end
    local shell = V3.shell
    if shell == nil or shell.navScroll == nil then return Fail("navigation_scroll_missing") end
    local entries = shell.navScroll:GetScrollableEntries()
    if #entries < 12 then return Fail("navigation_entries:" .. tostring(#entries)) end
    if shell.navButtons["system.settings"] == nil then return Fail("settings_entry_missing") end
    if shell.navButtons["system.diagnostics"] == nil then return Fail("diagnostics_entry_missing") end
    if shell.reloadButton == nil or type(S.ReloadCodeFromDisk) ~= "function" then return Fail("reload_entry_missing") end

    local previousOffset = tonumber(shell.navScroll.scrollOffset) or 0
    shell.navScroll:ScrollToBottom()
    local bottomOffset = tonumber(shell.navScroll.scrollOffset) or 0
    shell.navScroll:SetScrollOffset(previousOffset)
    shell:RefreshNavScrollHint()
    if shell.navScroll:GetMaxOffset() > 0 and bottomOffset <= previousOffset then return Fail("navigation_scroll_inactive") end
    return true
end)

G:RegisterSequenceCase("v3_09_text_containment", function()
    local host, err = H:Ensure("v3")
    if host == nil then return Fail(err or "ensure") end
    local shell = V3.shell
    local pageHost = S.UIV3 and S.UIV3.PageHost or nil
    if shell == nil or pageHost == nil or type(S.RSUI.InspectLayout) ~= "function" then return Fail("layout_inspector_missing") end

    local previousRoute = shell.lastRoute or pageHost.activeRoute or "home"
    local state = S.UIV3 and S.UIV3.ShellState or {}
    local restoreW, restoreH = tonumber(state.width) or 1040, tonumber(state.height) or 700
    local routed, routeErr = shell:Navigate("home", { source = "text_containment_sequence", keepHidden = true })
    if routed ~= true then return Fail(routeErr or "home_route") end
    local layoutOk = shell:ApplyLayout(false, 829, 555)
    if layoutOk ~= true then return Fail("stress_layout") end

    local hard = 0
    local function CountHard(component)
        local audit = S.RSUI:InspectLayout(component, { maxNodes = 512, maxDepth = 32 })
        if audit.ok ~= true then hard = hard + 1; return end
        for _, issue in ipairs(audit.issues or {}) do
            for _, flag in ipairs(issue.flags or {}) do
                if flag == "text_overflow" or flag == "x_out_of_bounds" or flag == "y_out_of_bounds" or flag == "sibling_overlap" or flag == "overflow" then
                    hard = hard + 1
                    break
                end
            end
        end
    end
    CountHard(shell.topBar)
    CountHard(pageHost.pages["home"])

    shell:ApplyLayout(false, restoreW, restoreH)
    if previousRoute ~= "home" then shell:Navigate(previousRoute, { source = "text_containment_restore", keepHidden = true }) end
    if hard > 0 then return Fail("layout_hard_issues:" .. tostring(hard)) end
    return true
end)

G:RegisterSequenceCase("v3_10_scale_font_scroll_stress", function()
    local host, err = H:Ensure("v3")
    if host == nil then return Fail(err or "ensure") end
    local shell = V3.shell
    local pageHost = S.UIV3 and S.UIV3.PageHost or nil
    local app = S.AppState
    if shell == nil or pageHost == nil or app == nil or S.Layout == nil then return Fail("settings_stress_foundation") end

    local previousRoute = shell.lastRoute or pageHost.activeRoute or "home"
    local state = S.UIV3 and S.UIV3.ShellState or {}
    local restoreW, restoreH = tonumber(state.width) or 1040, tonumber(state.height) or 700
    local restoreScale = tonumber(app.settings and app.settings.addonScale) or 1
    local restoreFont = tonumber(app.settings and app.settings.fontScale) or 1
    local wasVisible = Visible(V3:GetWindow())
    local hard = 0

    local ok, detail = xpcall(function()
        app:Set("addonScale", 1.25, false)
        app:Set("fontScale", 1.50, false)
        S.Layout:Invalidate()
        local refreshed, refreshErr = S.Layout:RefreshNow(true)
        if refreshed == false then error(refreshErr or "responsive_refresh") end
        local routed, routeErr = shell:Navigate("system.settings", { source = "scale_font_stress", keepHidden = true })
        if routed ~= true then error(routeErr or "settings_route") end
        local layoutOk = shell:ApplyLayout(false, 720, 520)
        if layoutOk ~= true then error("settings_layout") end
        local root = pageHost.pages["system.settings"]
        if root == nil or tostring(root.kind or "") ~= "ScrollBox" or type(root.GetMaxOffset) ~= "function" then error("settings_scroll_contract") end
        local audit = S.RSUI:InspectLayout(root, { maxNodes = 768, maxDepth = 36 })
        if audit.ok ~= true then hard = hard + 1 else
            for _, issue in ipairs(audit.issues or {}) do
                for _, flag in ipairs(issue.flags or {}) do
                    if flag == "text_overflow" or flag == "x_out_of_bounds" or flag == "y_out_of_bounds" or flag == "sibling_overlap" or flag == "overflow" then
                        hard = hard + 1
                        break
                    end
                end
            end
        end
    end, S.SafeTraceback)

    app:Set("addonScale", restoreScale, false)
    app:Set("fontScale", restoreFont, false)
    S.Layout:Invalidate()
    pcall(function() S.Layout:RefreshNow(true) end)
    pcall(function() shell:ApplyLayout(false, restoreW, restoreH) end)
    if previousRoute ~= "system.settings" then pcall(function() shell:Navigate(previousRoute, { source = "scale_font_stress_restore", keepHidden = true }) end) end
    RestoreVisibility(wasVisible)

    if ok ~= true then return Fail(detail or "settings_stress") end
    if hard > 0 then return Fail("settings_layout_hard_issues:" .. tostring(hard)) end
    return true
end)

G:RegisterSequenceCase("v3_11_management_contracts", function()
    local host, err = H:Ensure("v3")
    if host == nil then return Fail(err or "ensure") end
    local shell = V3.shell
    local controller = shell and shell.windowController or nil
    local widgetHost = S.UIV3 and S.UIV3.WidgetHost or nil
    local modalHost = S.UIV3 and S.UIV3.ModalHost or nil
    if controller == nil or widgetHost == nil or modalHost == nil then return Fail("management_foundation") end

    local originalLocked = type(controller.IsLocked) == "function" and controller:IsLocked() or false
    if type(controller.SetLocked) ~= "function" then return Fail("window_lock_contract") end
    controller:SetLocked(not originalLocked)
    local changed = controller:IsLocked() == (not originalLocked)
    controller:SetLocked(originalLocked)
    if not changed or controller:IsLocked() ~= originalLocked then return Fail("window_lock_transaction") end

    local widgetState = widgetHost:GetState("life.activities")
    if widgetState == nil or widgetState.lockable ~= true or widgetState.resettable ~= true then return Fail("widget_management_contract") end

    if modalHost:Describe().attached ~= true or modalHost:GetContentRoot() == nil then return Fail("modal_attach_contract") end
    if modalHost.sequenceProbe == nil then
        modalHost.sequenceProbe = S.RSUI:Border({
            id = "v3_modal_sequence_probe", parent = modalHost:GetContentRoot(), variant = "card", padding = 4,
            slot = { size = "fixed", width = 220, height = 90, hAlign = "center", vAlign = "center" },
        })
        if modalHost.sequenceProbe == nil then return Fail("modal_probe_create") end
        modalHost.sequenceProbe:SetVisibility("collapsed")
    end
    if modalHost:Push("sequence_probe", modalHost.sequenceProbe, { dismissOnBackdrop = false }) ~= true then return Fail("modal_push") end
    local top = modalHost:GetTop()
    local pushed = top ~= nil and top.id == "sequence_probe" and modalHost:Describe().count == 1
    local popped = modalHost:Pop("sequence_probe", "sequence") ~= nil and modalHost:Describe().count == 0
    if not pushed or not popped then modalHost:Clear("sequence_repair"); return Fail("modal_stack_transaction") end
    return true
end)

G:RegisterSequenceCase("v3_12_bounded_notifications", function()
    local host, err = H:Ensure("v3")
    if host == nil then return Fail(err or "ensure") end
    local scheduler = S.Scheduler
    local toastHost = S.UIV3 and S.UIV3.ToastHost or nil
    if scheduler == nil or type(scheduler.AddOneShot) ~= "function" then return Fail("one_shot_scheduler_missing") end
    if toastHost == nil or type(toastHost.Notify) ~= "function" then return Fail("toast_host_missing") end

    local fired = 0
    local taskName = "v3_sequence_one_shot"
    scheduler:RemoveTask(taskName)
    if scheduler:AddOneShot(taskName, 50, function() fired = fired + 1 end, G, "P4", 1) ~= true then return Fail("one_shot_register") end
    if scheduler.tasks[taskName] == nil then return Fail("one_shot_not_registered") end
    if scheduler:RunTask(taskName) ~= true then return Fail("one_shot_run") end
    if fired ~= 1 or scheduler.tasks[taskName] ~= nil then return Fail("one_shot_cleanup") end

    local before = toastHost:Describe().active or 0
    local toastId, toastErr = toastHost:Notify({ id = "sequence_toast", title = "自检通知", detail = "通知宿主事务检查", tone = "green", durationMs = 12000 })
    if toastId == nil then return Fail(toastErr or "toast_notify") end
    if (toastHost:Describe().active or 0) ~= before + 1 then toastHost:Dismiss(toastId, "sequence_repair"); return Fail("toast_active") end
    if toastHost:Dismiss(toastId, "sequence") ~= true then return Fail("toast_dismiss") end
    if (toastHost:Describe().active or 0) ~= before then return Fail("toast_cleanup") end
    return true
end)

G:RegisterSequenceCase("v3_13_widget_appearance", function()
    local widgetHost = S.UIV3 and S.UIV3.WidgetHost or nil
    if widgetHost == nil or type(widgetHost.SetAppearance) ~= "function" or type(widgetHost.SetOpacity) ~= "function" then return Fail("widget_appearance_contract") end
    local state = widgetHost:GetState("life.activities")
    if state == nil or state.overallOpacityAdjustable ~= true or state.backgroundOpacityAdjustable ~= true or state.textOpacityAdjustable ~= true then
        return Fail("activity_appearance_capability")
    end
    local original = {
        overall = tonumber(state.overallOpacity) or 0.94,
        background = tonumber(state.backgroundOpacity) or 1.0,
        text = tonumber(state.textOpacity) or 1.0,
    }
    local targets = { overall = 0.81, background = 0.63, text = 0.87 }
    for _, channel in ipairs({ "overall", "background", "text" }) do
        local ok, err = widgetHost:SetAppearance("life.activities", channel, targets[channel])
        if ok ~= true then
            for restoreChannel, value in pairs(original) do widgetHost:SetAppearance("life.activities", restoreChannel, value) end
            return Fail(err or (channel .. "_opacity_set"))
        end
    end
    local changed = widgetHost:GetState("life.activities")
    local projected = changed ~= nil
        and Approx(changed.overallOpacity, targets.overall, 0.01)
        and Approx(changed.backgroundOpacity, targets.background, 0.01)
        and Approx(changed.textOpacity, targets.text, 0.01)
        and Approx(changed.opacity, targets.overall, 0.01)
    for channel, value in pairs(original) do widgetHost:SetAppearance("life.activities", channel, value) end
    if projected ~= true then return Fail("appearance_projection") end
    return true
end)

G:RegisterSequenceCase("v3_14_widget_responsive_reflow", function()
    local widgetHost = S.UIV3 and S.UIV3.WidgetHost or nil
    if widgetHost == nil or type(widgetHost.ApplyResponsiveLayout) ~= "function" then return Fail("widget_responsive_contract") end
    local state = widgetHost:GetState("life.activities")
    if state == nil then return Fail("activity_widget_missing") end

    -- Diagnostics must remain valid when the user has explicitly disabled the
    -- Activity Feature. In that state there is intentionally no live widget to
    -- reflow, so only the host contract is asserted.
    if S.FeatureRuntime ~= nil and S.FeatureRuntime:IsEnabled("life_activities") ~= true then return true end

    local wasVisible = state.visible == true
    if not wasVisible then
        local shown, showErr = widgetHost:SetVisible("life.activities", true, { persist = false, reason = "sequence_responsive" })
        if shown ~= true then return Fail(showErr or "widget_show") end
    end

    local before = widgetHost:Describe()
    local beforeReflows = tonumber(before.stats and before.stats.responsiveReflows) or 0
    local beforeFailures = tonumber(before.stats and before.stats.responsiveFailures) or 0
    local ok, detail = widgetHost:ApplyResponsiveLayout(true)
    local after = widgetHost:Describe()
    local afterReflows = tonumber(after.stats and after.stats.responsiveReflows) or 0
    local afterFailures = tonumber(after.stats and after.stats.responsiveFailures) or 0

    if not wasVisible then widgetHost:SetVisible("life.activities", false, { persist = false, reason = "sequence_responsive_restore" }) end
    if ok ~= true then return Fail(detail or "responsive_reflow") end
    if afterReflows <= beforeReflows then return Fail("responsive_reflow_not_counted") end
    if afterFailures ~= beforeFailures then return Fail("responsive_reflow_failure") end
    return true
end)


G:RegisterSequenceCase("v3_15_native_geometry_lease", function()
    local host, err = H:Ensure("v3")
    if host == nil then return Fail(err or "ensure") end
    local shell = S.UIV3 and S.UIV3.Shell or nil
    local controller = shell and shell.windowController or nil
    local ui = S.UI
    if controller == nil or ui == nil then return Fail("geometry_lease_foundation") end
    if type(ui.BeginNativeGeometryLease) ~= "function" or type(ui.EndNativeGeometryLease) ~= "function" then return Fail("geometry_lease_contract") end
    if type(controller.IsInteracting) ~= "function" or type(controller.PulseLiveGeometry) ~= "function" then return Fail("window_interaction_contract") end

    local window = shell.window
    local before = ui.NativeStateCache and ui.NativeStateCache[window] or nil
    local beforeX = before and before.anchorX or nil
    local began = ui:BeginNativeGeometryLease(window, shell.owner, "sequence")
    if began ~= true then return Fail("geometry_lease_begin") end
    local deferred = ui:SetAnchor(window, UIParent, (tonumber(beforeX) or 0) + 37, 21, shell.owner)
    local lease = ui:GetNativeGeometryLease(window)
    local ended = ui:EndNativeGeometryLease(window, shell.owner)
    if deferred ~= false or lease == nil or ended ~= true then return Fail("geometry_lease_transaction") end
    shell:ApplyLayout(false)
    return true
end)

G:RegisterSequenceCase("v3_16_live_resize_projection", function()
    local host, err = H:Ensure("v3")
    if host == nil then return Fail(err or "ensure") end
    local shell = S.UIV3 and S.UIV3.Shell or nil
    local controller = shell and shell.windowController or nil
    if shell == nil or controller == nil or shell.window == nil or shell.root == nil then return Fail("live_resize_foundation") end
    if controller:IsInteracting() == true then return Fail("interaction_already_active") end

    local window = shell.window
    local restoreX, restoreY, restoreW, restoreH = S.Layout:GetLogicalRect(window)
    if controller:BeginInteraction("resize", "BOTTOMRIGHT") ~= true then return Fail("live_resize_begin") end

    -- The mock/native host may not emulate mouse sizing, so emulate only the
    -- Native rect mutation that StartSizing owns during a real RU drag.
    local sizePolicy = S.UIV3 and S.UIV3.ShellSizePolicy or { minWidth = 1, minHeight = 1 }
    if type(window.SetExtent) == "function" then
        window:SetExtent(math.max(tonumber(sizePolicy.minWidth) or 1, restoreW - 64), math.max(tonumber(sizePolicy.minHeight) or 1, restoreH - 48))
    end
    local nativeW, nativeH = window:GetWidth(), window:GetHeight()
    if controller:PulseLiveGeometry(true) ~= true then controller:EndInteraction(); return Fail("live_resize_pulse") end
    local rootW, rootH = tonumber(shell.root.width) or 0, tonumber(shell.root.height) or 0
    if math.abs(rootW - nativeW) > 1 or math.abs(rootH - nativeH) > 1 then controller:EndInteraction(); return Fail("live_resize_content_reflow") end

    -- A normal shell layout request during the gesture must not overwrite the
    -- Native dimensions being driven by the mouse.
    shell:ApplyLayout(false)
    local afterW, afterH = window:GetWidth(), window:GetHeight()
    if math.abs(afterW - nativeW) > 1 or math.abs(afterH - nativeH) > 1 then controller:EndInteraction(); return Fail("live_resize_geometry_fight") end

    controller:EndInteraction()
    S.UI:InvalidateNativeState(window)
    S.UI:SetAnchor(window, UIParent, restoreX, restoreY, shell.owner)
    S.UI:SetExtent(window, restoreW, restoreH, shell.owner)
    shell:ApplyLayout(false, restoreW, restoreH)
    return true
end)


G:RegisterSequenceCase("v3_17_unbounded_window_placement", function()
    local layout = S.Layout
    local shell = S.UIV3 and S.UIV3.Shell or nil
    local controller = shell and shell.windowController or nil
    if layout == nil or controller == nil or type(layout.ResolvePlacement) ~= "function" then return Fail("free_placement_contract") end
    if tostring(controller.boundaryMode or "") ~= "free" then return Fail("main_window_not_free") end

    local context = layout:GetContext()
    local window = shell.window
    local restoreX, restoreY, restoreW, restoreH = layout:GetLogicalRect(window)
    local state = S.UIV3 and S.UIV3.ShellState or {}
    local stateBackup = {}
    for k,v in pairs(state) do stateBackup[k] = v end

    -- Deliberately place the window fully outside the viewport. Free mode must
    -- preserve the exact coordinate; recovery is an explicit user action, not
    -- an invisible clamp during drag/commit/restore.
    local candidateX = (tonumber(context.logicalWidth) or 1024) + 360
    local candidateY = (tonumber(context.logicalHeight) or 768) + 220
    if controller:BeginInteraction("drag") ~= true then return Fail("free_drag_begin") end
    if type(window.RemoveAllAnchors) == "function" then window:RemoveAllAnchors() end
    if type(window.AddAnchor) == "function" then window:AddAnchor("TOPLEFT", "UIParent", candidateX, candidateY) end
    controller:EndInteraction()
    local committed, committedX, committedY = controller:CommitGeometry("drag")
    local actualX, actualY = layout:GetLogicalRect(window)
    local freeStored = tostring(state.coordinateSpace or "") == "logical-free-v2" and Approx(state.x, candidateX, 0.5) and Approx(state.y, candidateY, 0.5)
    local good = committed == true and Approx(committedX, candidateX, 0.5) and Approx(committedY, candidateY, 0.5)
        and Approx(actualX, candidateX, 0.5) and Approx(actualY, candidateY, 0.5) and freeStored

    local scale = math.max(0.01, tonumber(context.addonScale) or 1)
    local oversizedW = math.max(restoreW, (tonumber(context.usableWidth) or 1000) + 240)
    local oversizedH = math.max(restoreH, (tonumber(context.usableHeight) or 744) + 180)
    local resolvedX, resolvedY, resolvedW, resolvedH = layout:ResolvePlacement({
        userMoved = true, coordinateSpace = "logical-free-v2", x = candidateX, y = candidateY,
    }, oversizedW, oversizedH, 0, 0, { mode = "free" })
    good = good and Approx(resolvedX, candidateX, 0.5) and Approx(resolvedY, candidateY, 0.5)
        and Approx(resolvedW, oversizedW, 0.5) and Approx(resolvedH, oversizedH, 0.5)

    -- Main shell and Windowing must not re-introduce the retired 1180x900 or
    -- current-viewport caps. Explicit semantic max values remain supported for
    -- truly fixed windows, but the application shell intentionally has none.
    local designW, designH = oversizedW / scale, oversizedH / scale
    local _, _, shellW, shellH = shell:ResolveRect(designW, designH)
    good = good and controller.maxWidth == nil and controller.maxHeight == nil
        and Approx(shellW, oversizedW, 1.0) and Approx(shellH, oversizedH, 1.0)

    for k in pairs(state) do state[k] = nil end
    for k,v in pairs(stateBackup) do state[k] = v end
    S.UI:InvalidateNativeState(window)
    S.UI:SetAnchor(window, UIParent, restoreX, restoreY, shell.owner)
    S.UI:SetExtent(window, restoreW, restoreH, shell.owner)
    shell:ApplyLayout(false, tonumber(state.width) or restoreW, tonumber(state.height) or restoreH)
    if not good then return Fail("unbounded_window_commit") end
    return true
end)

G:RegisterSequenceCase("v3_18_exact_numeric_settings", function()
    local shell = S.UIV3 and S.UIV3.Shell or nil
    local pageHost = S.UIV3 and S.UIV3.PageHost or nil
    local design = S.UIV3Design
    if shell == nil or pageHost == nil or type(design) ~= "table" or type(design.NumericSetting) ~= "function" then
        return Fail("numeric_setting_contract")
    end
    local restoreRoute = pageHost.activeRoute or "home"
    if shell:Navigate("system.settings", { source = "sequence_numeric" }) ~= true then return Fail("numeric_settings_route") end
    local settings = pageHost.pages["system.settings"]
    local fields = settings and settings.numericFields or nil
    local required = { "width", "height", "scale", "font" }
    for _, key in ipairs(required) do
        local field = fields and fields[key] or nil
        if field == nil or field.input == nil then
            shell:Navigate(restoreRoute, { source = "sequence_numeric_restore" })
            return Fail("numeric_input_missing:" .. key)
        end
        if field.minus ~= nil or field.plus ~= nil then
            shell:Navigate(restoreRoute, { source = "sequence_numeric_restore" })
            return Fail("numeric_cycle_button_present:" .. key)
        end
        if type(field.Measure) ~= "function" or type(field.ResolveFieldMetrics) ~= "function" then
            shell:Navigate(restoreRoute, { source = "sequence_numeric_restore" })
            return Fail("numeric_measure_contract_missing:" .. key)
        end
        local _, desiredH = field:Measure(900, nil)
        local metrics = field:ResolveFieldMetrics(field.controlPreferredHeight)
        if tonumber(desiredH) == nil or tonumber(metrics and metrics.requiredHeight) == nil
            or tonumber(desiredH) + 0.01 < tonumber(metrics.requiredHeight) then
            shell:Navigate(restoreRoute, { source = "sequence_numeric_restore" })
            return Fail("numeric_hint_height_clipped:" .. key)
        end
    end
    if fields.width.maximum ~= nil or fields.height.maximum ~= nil then
        shell:Navigate(restoreRoute, { source = "sequence_numeric_restore" })
        return Fail("window_numeric_max_cap")
    end
    if shell:Navigate("system.widgets", { source = "sequence_numeric_widget" }) ~= true then
        shell:Navigate(restoreRoute, { source = "sequence_numeric_restore" })
        return Fail("numeric_widget_route")
    end
    local widgets = pageHost.pages["system.widgets"]
    local widgetFields = widgets and widgets.numericFields or nil
    for _, key in ipairs({ "overallOpacity", "backgroundOpacity", "textOpacity", "rows", "width", "height" }) do
        local field = widgetFields and widgetFields[key] or nil
        if field == nil or field.input == nil or field.minus ~= nil or field.plus ~= nil then
            shell:Navigate(restoreRoute, { source = "sequence_numeric_restore" })
            return Fail("widget_numeric_contract:" .. key)
        end
    end
    if widgetFields.width.maximum ~= nil or widgetFields.height.maximum ~= nil then
        shell:Navigate(restoreRoute, { source = "sequence_numeric_restore" })
        return Fail("widget_window_numeric_max_cap")
    end
    shell:Navigate(restoreRoute, { source = "sequence_numeric_restore" })
    return true
end)

G:RegisterSequenceCase("v3_19_slider_geometry_sync", function()
    local shell = S.UIV3 and S.UIV3.Shell or nil
    local pageHost = S.UIV3 and S.UIV3.PageHost or nil
    local ui = S.UI
    if shell == nil or pageHost == nil or ui == nil then return Fail("slider_sync_foundation") end
    local restoreRoute = pageHost.activeRoute or "home"
    if shell:Navigate("system.widgets", { source = "sequence_slider_sync" }) ~= true then return Fail("slider_sync_route") end
    local widgets = pageHost.pages["system.widgets"]
    local fields = widgets and widgets.numericFields or nil

    local function ReadWidth(widget)
        if widget == nil then return nil end
        if type(widget.GetWidth) == "function" then
            local ok, value = pcall(function() return widget:GetWidth() end)
            if ok then return tonumber(value) end
        end
        if type(widget.GetExtent) == "function" then
            local ok, value = pcall(function() local w = widget:GetExtent(); return w end)
            if ok then return tonumber(value) end
        end
        return nil
    end

    for _, key in ipairs({ "overallOpacity", "backgroundOpacity", "textOpacity", "rows" }) do
        local field = fields and fields[key] or nil
        local slider = field and field.slider or nil
        local root = slider and slider.root or nil
        local track = root and root.rsTrack or nil
        local drag = root and root.rsDragSurface or nil
        if root == nil or track == nil or drag == nil or root.rsCustomHorizontal ~= true then
            shell:Navigate(restoreRoute, { source = "sequence_slider_sync_restore" })
            return Fail("slider_composite_missing:" .. key)
        end
        local beforeW = ReadWidth(root) or tonumber(root.rsWidth) or 160
        local beforeH = (type(root.GetHeight) == "function" and tonumber(root:GetHeight())) or tonumber(root.rsHeight) or 20
        local targetW = beforeW + 73
        ui:SetExtent(root, targetW, beforeH, slider.owner)
        local trackW = ReadWidth(track)
        local dragW = ReadWidth(drag)
        local synced = Approx(root.rsVisualWidth, targetW, 0.5)
            and (trackW == nil or Approx(trackW, math.max(1, targetW - 12), 1.0))
            and (dragW == nil or Approx(dragW, targetW, 1.0))
        ui:SetExtent(root, beforeW, beforeH, slider.owner)
        if synced ~= true then
            shell:Navigate(restoreRoute, { source = "sequence_slider_sync_restore" })
            return Fail("slider_extent_desync:" .. key)
        end
    end
    shell:Navigate(restoreRoute, { source = "sequence_slider_sync_restore" })
    return true
end)


G:RegisterSequenceCase("v3_20_interactive_scheduler_contract", function()
    local scheduler = S.Scheduler
    if type(scheduler) ~= "table" or type(scheduler.AddTask) ~= "function" or type(scheduler.AddInteractiveTask) ~= "function" then
        return Fail("interactive_scheduler_missing")
    end
    local bg, interactive = "rs_sequence_m114_bg", "rs_sequence_m114_interactive"
    scheduler:RemoveTask(bg); scheduler:RemoveTask(interactive)
    scheduler:AddTask(bg, 1, function() return true end, false, G, "P5", 1)
    scheduler:AddInteractiveTask(interactive, 1, function() return true end, false, G, "P0", 1)
    local b, i = scheduler.tasks[bg], scheduler.tasks[interactive]
    local good = b ~= nil and i ~= nil and b.lane == "background" and i.lane == "interactive"
        and (tonumber(b.intervalMs) or 0) >= 50 and (tonumber(i.intervalMs) or 0) >= 16 and (tonumber(i.intervalMs) or 99) < 50
    scheduler:RemoveTask(bg); scheduler:RemoveTask(interactive)
    if not good then return Fail("scheduler_lane_bounds") end
    return true
end)

G:RegisterSequenceCase("v3_21_scrollbox_scrollbar_contract", function()
    local shell = S.UIV3 and S.UIV3.Shell or nil
    local nav = shell and shell.navScroll or nil
    local behavior = nav and nav.scrollbar or nil
    if behavior == nil or (tonumber(behavior.version) or 0) < 2 then return Fail("nav_scrollbar_missing") end
    if behavior.thumb == nil or behavior.dragProxy == nil or behavior.thumb == behavior.dragProxy then return Fail("scrollbar_authority_split") end
    if type(behavior.Release) ~= "function" or type(behavior.Layout) ~= "function" then return Fail("scrollbar_lifecycle") end
    return true
end)

G:RegisterSequenceCase("v3_22_split_view_contract", function()
    local rsui = S.RSUI
    local policy = rsui and rsui.SplitViewPolicy or nil
    if rsui == nil or type(rsui.SplitView) ~= "function" or rsui.types == nil or rsui.types["SplitView"] == nil or type(policy) ~= "table" then
        return Fail("split_view_registration")
    end
    local a, b, divider = policy:Resolve(140, 6, 120, 120, 100, nil, nil)
    if a < 0 or b < 0 or divider < 0 or not Approx(a + b + divider, 140, 0.01) then return Fail("split_tiny_geometry") end
    local wideA, wideB = policy:Resolve(1600, 6, 120, 120, 1100, nil, nil)
    if wideA < 1099 or wideB <= 0 then return Fail("split_hidden_max_cap") end
    return true
end)

G:RegisterSequenceCase("v3_23_responsive_outer_surface_contract", function()
    local layout = S.Layout
    if layout == nil or type(layout.BuildMainSpec) ~= "function" then return Fail("main_spec_solver") end
    local context = { addonScale=1, columns=2, breakpoint="WIDE", usableWidth=1000, usableHeight=744 }
    local spec = layout:BuildMainSpec(context, { width=1540, height=1080 }, 1.2)
    if type(spec) ~= "table" or not Approx(spec.width,1540,0.01) or not Approx(spec.height,1080,0.01) then return Fail("outer_surface_clamped") end
    if spec.width <= context.usableWidth or spec.height <= context.usableHeight then return Fail("outer_surface_not_free") end
    return true
end)

G:RegisterSequenceCase("v3_24_invalidation_reactivation_contract", function()
    local rsui = S.RSUI
    if rsui == nil or type(rsui.ShouldCoalesceInvalidation) ~= "function" then return Fail("invalidation_predicate") end
    local sticky = { measureDirty=true, layoutDirty=true }
    -- Critical regression: a dirty child/parent after the prior layout transaction
    -- has ended must propagate again instead of being suppressed by stale bits.
    if rsui:ShouldCoalesceInvalidation(false, sticky, true) ~= false then return Fail("sticky_dirty_suppressed") end
    if rsui:ShouldCoalesceInvalidation(true, sticky, true) ~= true then return Fail("active_transaction_not_coalesced") end
    if rsui:ShouldCoalesceInvalidation(true, {measureDirty=false,layoutDirty=false}, true) ~= false then return Fail("clean_parent_coalesced") end
    return true
end)

G:RegisterSequenceCase("v3_25_virtual_scrollbar_contract", function()
    local rsui = S.RSUI
    if rsui == nil or rsui.types == nil or rsui.types["ListView"] == nil or rsui.types["TileView"] == nil then return Fail("virtual_view_types") end
    local behavior = rsui.ScrollbarBehavior
    if behavior == nil or type(behavior.Attach) ~= "function" or type(behavior.ComputeGeometry) ~= "function" then return Fail("shared_scroll_behavior") end
    return true
end)

G:RegisterSequenceCase("v3_26_table_resize_contract", function()
    local util = S.RSUI and S.RSUI.DataViewUtil or nil
    if util == nil or type(util.ColumnResizeBounds) ~= "function" or type(util.ClampColumnResizeWidth) ~= "function" or type(util.ResolveColumnWidths) ~= "function" then return Fail("table_resize_util") end
    local minBound, maxBound = util.ColumnResizeBounds({ minWidth=80, maxWidth=120, absoluteMinWidth=1 })
    if minBound ~= 1 or maxBound ~= nil then return Fail("table_native_drag_reused_layout_max") end
    local hardMin, hardMax = util.ColumnResizeBounds({ minWidth=80, maxWidth=120, absoluteMinWidth=2, absoluteMaxWidth=333 })
    if hardMin ~= 2 or hardMax ~= 333 then return Fail("table_absolute_drag_bounds") end
    local free = { minWidth=48, absoluteMinWidth=8, maxWidth=nil }
    if not Approx(util.ClampColumnResizeWidth(free, 1400), 1400, 0.01) then return Fail("table_hidden_max_cap") end
    if not Approx(util.ClampColumnResizeWidth(free, 9), 9, 0.01) then return Fail("table_preferred_min_blocks_user_resize") end
    if not Approx(util.ClampColumnResizeWidth(free, 1), 8, 0.01) then return Fail("table_hard_min_ignored") end
    local normalized = util.NormalizeColumns({ { id="manual", size="fixed", width=10, minWidth=48, absoluteMinWidth=8 } })
    local widths = util.ResolveColumnWidths(normalized, 200, 0)
    if not Approx(widths[1], 10, 0.01) then return Fail("table_fixed_width_reinflated_to_preferred_min") end
    local layoutBounded = { minWidth=48, absoluteMinWidth=1, maxWidth=300 }
    if not Approx(util.ClampColumnResizeWidth(layoutBounded, 1400), 1400, 0.01) then return Fail("table_layout_max_blocks_manual_resize") end
    local hardBounded = { minWidth=48, absoluteMinWidth=1, maxWidth=300, absoluteMaxWidth=420 }
    if not Approx(util.ClampColumnResizeWidth(hardBounded, 1400), 420, 0.01) then return Fail("table_absolute_max_ignored") end
    if type(util.ResolveAdjacentResizePreview) ~= "function" then return Fail("table_stable_preview_missing") end
    if type(util.CommitColumnResizeWidth) ~= "function" then return Fail("table_responsive_commit_missing") end
    local previewColumns = util.NormalizeColumns({
        { id="a", size="fill", minWidth=80, absoluteMinWidth=8, fill=1 },
        { id="b", size="fill", minWidth=100, absoluteMinWidth=8, fill=1 },
        { id="c", size="fixed", width=60, minWidth=44, absoluteMinWidth=8 },
    })
    local baseline = { 120, 160, 60 }
    local preview, leftWidth, compensationIndex, compensationWidth = util.ResolveAdjacentResizePreview(previewColumns, baseline, 1, 140)
    if type(preview) ~= "table" or leftWidth ~= 140 or compensationIndex ~= 2 or compensationWidth ~= 140 then return Fail("table_preview_pair_geometry") end
    if preview[3] ~= 60 or (preview[1] + preview[2] + preview[3]) ~= 340 then return Fail("table_preview_unrelated_columns_moved") end
    util.CommitColumnResizeWidth(previewColumns[1], 140)
    util.CommitColumnResizeWidth(previewColumns[2], 140)
    if previewColumns[1].size ~= "fill" or previewColumns[2].size ~= "fill" then return Fail("table_drag_destroyed_fill_mode") end
    local committed = util.ResolveColumnWidths(previewColumns, 340, 0)
    if committed[1] ~= 140 or committed[2] ~= 140 or committed[3] ~= 60 then return Fail("table_committed_preview_changed") end
    local expanded = util.ResolveColumnWidths(previewColumns, 440, 0)
    if (expanded[1] + expanded[2] + expanded[3]) ~= 440 or expanded[1] <= committed[1] or expanded[2] <= committed[2] then
        return Fail("table_manual_fill_stopped_responding")
    end

    local pageHost = S.UIV3 and S.UIV3.PageHost or nil
    local activityPage = pageHost and pageHost.pages and pageHost.pages["life.activities"] or nil
    if activityPage ~= nil and activityPage.tableView ~= nil and activityPage.tableView.columnResizeEnabled ~= true then return Fail("activity_page_column_resize_disabled") end
    local widgetHost = S.UIV3 and S.UIV3.WidgetHost or nil
    local widget = widgetHost and widgetHost:GetInstance("life.activities") or nil
    if widget ~= nil and widget.table ~= nil then
        if widget.table.columnResizeEnabled ~= true then return Fail("activity_widget_column_resize_disabled") end
        if type(widget.table.ApplyColumnResizePreview) ~= "function" or type(widget.table.LayoutColumnResizeHandles) ~= "function" then return Fail("table_live_preview_contract") end
    end
    return true
end)

G:RegisterSequenceCase("v3_27_scrollbar_zero_travel_contract", function()
    local behavior = S.RSUI and S.RSUI.ScrollbarBehavior or nil
    if behavior == nil or type(behavior.ComputeGeometry) ~= "function" then return Fail("scrollbar_geometry_policy") end
    local geometry = behavior:ComputeGeometry(20, 28, 1, 100, 40, 99)
    if geometry.thumbPrimary ~= 20 or geometry.travel ~= 0 or geometry.draggable ~= false or geometry.thumbAxis ~= 0 then
        return Fail("scrollbar_zero_travel")
    end
    local compact = behavior:ComputeGeometry(20, 12, 1, 100, 40, 99)
    if compact.thumbPrimary ~= 12 or compact.travel ~= 8 or compact.draggable ~= true then
        return Fail("scrollbar_compact_viewport_not_draggable")
    end
    return true
end)

G:RegisterSequenceCase("v3_27b_interactive_feedback_contract", function()
    local rsui = S.RSUI
    if rsui == nil then return Fail("rsui_missing") end
    local scrollbar = rsui.ScrollbarBehavior
    if scrollbar == nil or (tonumber(scrollbar.version) or 0) < 3 then return Fail("scrollbar_live_fallback_contract") end
    local splitFactory = rsui.types and rsui.types["SplitView"] or nil
    if splitFactory == nil then return Fail("splitview_missing") end
    local windowing = rsui.Windowing
    if windowing == nil or (tonumber(windowing.version) or 0) < 11 then return Fail("windowing_missing") end
    return true
end)

G:RegisterSequenceCase("v3_27c_splitview_unrestricted_default_contract", function()
    local policy = S.RSUI and S.RSUI.SplitViewPolicy or nil
    if policy == nil or type(policy.Resolve) ~= "function" then return Fail("split_policy_missing") end
    local a,b = policy:Resolve(100, 6, 0, 0, 1, nil, nil)
    if a < 0 or b < 0 then return Fail("split_negative") end
    local collapsedA, collapsedB = policy:Resolve(100, 6, 0, 0, 0, nil, nil)
    if not Approx(collapsedA, 0, 0.01) or collapsedB <= 0 then return Fail("split_default_cannot_collapse") end
    return true
end)

G:RegisterSequenceCase("v3_28_native_identity_contract", function()
    local identity = S.NativeIdentity
    local factory = S.NativeObjectFactory
    if type(identity) ~= "table" or (tonumber(identity.version) or 0) < 2 or type(identity.Build) ~= "function" then return Fail("native_identity_missing") end
    if type(factory) ~= "table" or (tonumber(factory.version) or 0) < 2 or type(factory.ValidatePhysicalId) ~= "function" then return Fail("native_factory_guard_missing") end
    local logical = {
        "v3_shell_nav_scroll_scrollbar_track",
        "v3_shell_nav_scroll_scrollbar_thumb",
        "v3_shell_nav_scroll_scrollbar_drag_proxy",
        "v3_home_card_activity_stack",
        "v3_home_card_activity_header",
        "v3_home_card_activity_detail",
    }
    local seen = {}
    for _, id in ipairs(logical) do
        local physical = identity:Build(id, 1, 0)
        if #physical > (tonumber(identity.maxPhysicalLength) or 23) then return Fail("physical_id_length:" .. tostring(#physical)) end
        if seen[physical] ~= nil then return Fail("physical_id_collision:" .. id .. ":" .. seen[physical]) end
        seen[physical] = id
        local valid = factory:ValidatePhysicalId(physical)
        if valid ~= true then return Fail("factory_rejected_compact_id:" .. id) end
    end
    local g1 = identity:Build("v3_shell_nav_scroll_scrollbar_track", 1, 0)
    local g2 = identity:Build("v3_shell_nav_scroll_scrollbar_track", 2, 0)
    if g1 == g2 then return Fail("generation_alias") end
    return true
end)


G:RegisterSequenceCase("v3_29_native_parent_fence_contract", function()
    local factory = S.NativeObjectFactory
    if type(factory) ~= "table" or type(factory.ValidateParent) ~= "function" then return Fail("native_parent_fence_missing") end
    local current = { rsNativeGeneration = S.Generation }
    local stale = { rsNativeGeneration = (tonumber(S.Generation) or 1) - 1 }
    local rejected = { rsNativeGeneration = S.Generation, rsUiRegistrationRejected = true }
    local currentOk = factory:ValidateParent(current)
    local staleOk = factory:ValidateParent(stale)
    local rejectedOk = factory:ValidateParent(rejected)
    if currentOk ~= true then return Fail("current_parent_rejected") end
    if staleOk == true then return Fail("stale_parent_accepted") end
    if rejectedOk == true then return Fail("registration_rejected_parent_accepted") end
    return true
end)

G:RegisterSequenceCase("v3_30_menu_information_architecture_contract", function()
    local features = S.FeatureRegistry
    local router = S.UIV3 and S.UIV3.Router or nil
    if type(features) ~= "table" or type(router) ~= "table" then return Fail("menu_registry_missing") end

    -- Titles are already part of Replicated Gear's real save/capture/runtime
    -- contract. A second top-level title feature would duplicate both the UX
    -- entry and the eventual persistence Authority.
    if features:Get("tools_title_profiles") ~= nil or router:Get("tools.title_profiles") ~= nil then
        return Fail("duplicate_title_feature")
    end
    local gear = features:Get("combat_gear")
    if gear == nil or tostring(gear.name or ""):find("称号", 1, true) == nil then return Fail("gear_title_affinity_missing") end
    if tostring(gear.group or "") ~= "combat_loadout" then return Fail("gear_group_missing") end

    -- A group may appear only once in a category's sorted navigation. This
    -- guarantees related entries remain contiguous instead of being scattered.
    for _, category in ipairs({ "combat", "life", "tools" }) do
        local seen, previous = {}, nil
        for _, route in ipairs(router:List(category)) do
            local group = tostring(route.group or category)
            if group ~= previous then
                if seen[group] == true then return Fail("menu_group_split:" .. category .. ":" .. group) end
                seen[group] = true
                previous = group
            end
        end
    end

    -- Schema v6 intentionally drops retired edge-v1 shell placement so an old
    -- LEFT/TOP default cannot keep reopening the rebuilt menu in the corner.
    local store = S.Persistence and S.Persistence:GetStore("v3.shell") or nil
    if store == nil or type(store.migrate) ~= "function" or (tonumber(store.schemaVersion) or 0) < 6 then return Fail("shell_center_migration_missing") end
    local legacy = store.migrate({
        width = 1040, height = 700, userMoved = true,
        coordinateSpace = "logical-edge-v1", anchorH = "LEFT", anchorV = "TOP", offsetX = 0, offsetY = 0,
    })
    if type(legacy) ~= "table" or legacy.userMoved == true or legacy.x ~= nil or legacy.y ~= nil or legacy.coordinateSpace ~= nil then
        return Fail("legacy_corner_not_recentred")
    end
    local free = store.migrate({
        width = 900, height = 620, userMoved = true,
        coordinateSpace = "logical-free-v2", x = 321, y = 147,
    })
    if type(free) ~= "table" or free.userMoved ~= true or not Approx(free.x, 321, 0.01) or not Approx(free.y, 147, 0.01) then
        return Fail("explicit_v3_position_not_preserved")
    end
    return true
end)

G:RegisterSequenceCase("v3_31_floating_surface_contract", function()
    local floating = S.RSUI and S.RSUI.FloatingSurface or nil
    local host = S.UIV3 and S.UIV3.WidgetHost or nil
    if type(floating) ~= "table" or (tonumber(floating.version) or 0) < 1
        or tonumber(floating.generation) ~= tonumber(S.Generation) then return Fail("floating_surface_missing") end
    if type(host) ~= "table" or (tonumber(host.version) or 0) < 6 or type(host.SetMinimized) ~= "function" then
        return Fail("floating_widget_host_missing")
    end
    for _, id in ipairs({ "life.activities", "life.tasks" }) do
        local state = host:GetState(id)
        if state == nil or state.minimizable ~= true or state.lockable ~= true or state.appearanceAdjustable ~= true then
            return Fail("floating_widget_projection:" .. id)
        end
    end

    -- Native collapse semantics are exercised only when the Activity Feature is
    -- already enabled. Diagnostics must never start a disabled feature merely
    -- to validate Presentation infrastructure.
    if S.FeatureRuntime == nil or S.FeatureRuntime:IsEnabled("life_activities") ~= true then return true end
    local id = "life.activities"
    local initial = host:GetState(id)
    local wasVisible = initial and initial.visible == true
    local wasMinimized = initial and initial.minimized == true
    if not wasVisible then
        local shown, showErr = host:SetVisible(id, true, { persist = false, reason = "sequence_floating_surface" })
        if shown ~= true then return Fail(showErr or "floating_widget_show") end
    end
    local instance = host:GetInstance(id)
    local shell = instance and instance.surface and instance.surface.shell or nil
    if shell == nil or tostring(shell.minimizeMode or "") ~= "collapse" then
        if not wasVisible then host:SetVisible(id, false, { persist = false, reason = "sequence_floating_restore" }) end
        return Fail("floating_collapse_mode")
    end
    if shell.minimized == true then host:SetMinimized(id, false) end
    local normalHeight = tonumber(shell.normalHeight) or 0
    local minimizedOk, minimizedErr = host:SetMinimized(id, true)
    if minimizedOk ~= true then
        if not wasVisible then host:SetVisible(id, false, { persist = false, reason = "sequence_floating_restore" }) end
        return Fail(minimizedErr or "floating_minimize")
    end
    local stateAfter = host:GetState(id)
    local preserved = math.abs((tonumber(shell.normalHeight) or 0) - normalHeight) <= 0.01
        and stateAfter ~= nil and stateAfter.minimized == true
    host:SetMinimized(id, wasMinimized == true)
    if not wasVisible then host:SetVisible(id, false, { persist = false, reason = "sequence_floating_restore" }) end
    if preserved ~= true then return Fail("floating_normal_extent_not_preserved") end
    return true
end)

G:RegisterSequenceCase("v3_32_view_action_settings_contract", function()
    local rsui = S.RSUI
    local viewState = rsui and rsui.ViewState or nil
    if viewState == nil or (tonumber(viewState.version) or 0) < 1 or type(rsui.CreateViewState) ~= "function" then return Fail("view_state_missing") end
    local runner = S.ActionRunner
    if runner == nil or (tonumber(runner.version) or 0) < 1 or type(runner.Run) ~= "function" then return Fail("action_runner_missing") end
    local binding = S.UI and S.UI.Binding or nil
    if binding == nil or (tonumber(binding.version) or 0) < 2.2 or type(S.UI.CreatePersistentSettingBinding) ~= "function" then return Fail("persistent_binding_missing") end

    -- Re-entrant same-id invocation must be rejected while the outer command is
    -- active. This is synchronous and leaves no Scheduler task or UI mutation.
    local duplicateRejected = false
    local ok, err = runner:Run({
        id = "sequence.action_runner.reentry",
        notify = false,
        execute = function()
            local nestedOk, nestedErr = runner:Run({ id = "sequence.action_runner.reentry", notify = false, execute = function() return true end })
            duplicateRejected = nestedOk == false and tostring(nestedErr) == "busy"
            return duplicateRejected
        end,
    })
    if ok ~= true or duplicateRejected ~= true then return Fail(err or "action_duplicate_guard") end
    if runner:IsBusy("sequence.action_runner.reentry") then return Fail("action_runner_leak") end
    return true
end)

G:RegisterSequenceCase("v3_33_floating_close_contract", function()
    -- The close chain is a Foundation contract, not a per-feature behaviour:
    --   user X -> WindowShell:Close -> onClose (veto only when opted in)
    --           -> native hide -> onClosed -> FloatingSurface sync -> Host sync
    local shellAuthority = S.UI and S.UI.WindowShell or nil
    if shellAuthority == nil or (tonumber(shellAuthority.version) or 0) < 10 then return Fail("window_shell_missing") end
    local floating = S.RSUI and S.RSUI.FloatingSurface or nil
    if floating == nil or (tonumber(floating.version) or 0) < 3 or tonumber(floating.generation) ~= tonumber(S.Generation) then
        return Fail("floating_surface_missing")
    end
    local host = S.UIV3 and S.UIV3.WidgetHost or nil
    if host == nil or (tonumber(host.version) or 0) < 9 or type(host.RequestClose) ~= "function" then return Fail("widget_host_missing") end

    local metrics = type(shellAuthority.Describe) == "function" and shellAuthority:Describe() or nil
    if type(metrics) ~= "table" then return Fail("window_shell_metrics_missing") end
    for _, key in ipairs({ "closeRequests", "closeVetoes", "closeCallbackFailures", "closedCallbacks" }) do
        if metrics[key] == nil then return Fail("window_shell_metric:" .. key) end
    end
    -- A veto must be an explicit opt-in. Fail-open is the default so a business
    -- callback can never make a normal window undismissable.
    if metrics.closeVetoes ~= nil and tonumber(metrics.closeVetoes) ~= tonumber(metrics.closeVetoes) then return Fail("close_veto_metric") end
    local floatingSnapshot = type(floating.GetSnapshot) == "function" and floating:GetSnapshot() or nil
    if type(floatingSnapshot) ~= "table" or floatingSnapshot.closeRequests == nil or floatingSnapshot.closedCallbacks == nil then
        return Fail("floating_surface_metrics_missing")
    end
    return true
end)

G:RegisterSequenceCase("v3_34_combat_event_bus_lifecycle_contract", function()
    local bus = S.Services and S.Services.CombatEventBusV3 or nil
    if bus == nil or (tonumber(bus.version) or 0) < 3 then return Fail("combat_event_bus_missing") end
    if type(bus._MarkInert) ~= "function" then return Fail("combat_forced_inert_missing") end
    if type(bus.AcceptsTransport) ~= "function" then return Fail("combat_scope_filter_missing") end

    -- Scope is a dispatch contract: self-scope consumers must never receive
    -- all-scope traffic once DPS-like consumers enable the global bridge.
    if bus:AcceptsTransport({ scope = "self" }, "private") ~= true then return Fail("scope_self_private") end
    if bus:AcceptsTransport({ scope = "self" }, "global:UI") ~= false then return Fail("scope_self_global") end
    if bus:AcceptsTransport({ scope = "all" }, "global:UIParent") ~= true then return Fail("scope_all_global") end
    if bus:AcceptsTransport({ scope = "all" }, "private") ~= true then return Fail("scope_all_private") end

    -- Generation guard must be absolute: a handler owned by a previous addon
    -- load can never dispatch combat facts.
    if type(bus._IsCurrentGeneration) == "function" then
        if bus:_IsCurrentGeneration(S.Generation) ~= true then return Fail("generation_current") end
        if bus:_IsCurrentGeneration((tonumber(S.Generation) or 0) + 1) ~= false then return Fail("generation_stale") end
    end

    local health = type(bus.GetHealth) == "function" and bus:GetHealth() or nil
    if type(health) ~= "table" then return Fail("combat_health_missing") end
    for _, key in ipairs({ "releaseApiMissing", "releaseCallFailures", "stopFailures", "forcedInert", "scopeFiltered", "coverageState" }) do
        if health[key] == nil then return Fail("combat_health_metric:" .. key) end
    end
    local allowed = { FULL = true, DEGRADED = true, IDENTITY_COLD = true, UNAVAILABLE = true, INACTIVE = true }
    if allowed[tostring(health.coverageState)] ~= true then return Fail("coverage_state:" .. tostring(health.coverageState)) end
    return true
end)

G:RegisterSequenceCase("v3_35_feature_presentation_boundary_contract", function()
    -- Domain code must not reach WidgetHost. Feature lifecycle travels through
    -- the shared `v3.feature.lifecycle` topic; Presentation reacts.
    local runtime = S.FeatureRuntime
    local host = S.UIV3 and S.UIV3.WidgetHost or nil
    if type(runtime) ~= "table" or (tonumber(runtime.version) or 0) < 3 or type(runtime.LifecycleTopic) ~= "string" then
        return Fail("feature_runtime_lifecycle_missing")
    end
    if host == nil or (tonumber(host.version) or 0) < 9 or type(host.BindFeatureLifecycle) ~= "function" then return Fail("widget_host_missing") end
    if type(host.featureBindings) ~= "table" then return Fail("feature_bindings_missing") end
    local bound = 0
    for _ in pairs(host.featureBindings) do bound = bound + 1 end
    if bound <= 0 then return Fail("no_feature_lifecycle_binding") end
    local describe = type(host.Describe) == "function" and host:Describe() or nil
    if type(describe) ~= "table" or (tonumber(describe.stats.lifecycleReactionFailures) or 0) ~= 0 then
        return Fail("lifecycle_reaction_failures")
    end
    return true
end)

G:RegisterSequenceCase("v3_36_combat_page_navigation_contract", function()
    local shell = S.UIV3 and S.UIV3.Shell or nil
    local pageHost = S.UIV3 and S.UIV3.PageHost or nil
    if type(shell) ~= "table" or type(shell.Navigate) ~= "function" then return Fail("shell_navigation_missing") end
    if type(pageHost) ~= "table" or type(pageHost.factories) ~= "table" then return Fail("page_host_missing") end
    if type(pageHost.factories["combat.stats"]) ~= "function" then return Fail("dps_page_factory_missing") end
    if type(pageHost.factories["combat.analytics"]) ~= "function" then return Fail("analytics_page_factory_missing") end

    local restoreRoute = tostring(pageHost.activeRoute or shell.lastRoute or "home")
    if S.RSUI == nil or type(S.RSUI.TextInput) ~= "function" then return Fail("dps_text_input_public_factory_missing") end
    local ok, err = shell:Navigate("combat.stats", { source = "sequence_combat_page", keepHidden = true })
    if ok ~= true then
        if restoreRoute ~= "combat.stats" then pcall(function() shell:Navigate(restoreRoute, { source = "sequence_combat_restore", keepHidden = true }) end) end
        return Fail("dps_page_navigation:" .. tostring(err or "failed"))
    end
    ok, err = shell:Navigate("combat.stats", { source = "sequence_combat_page_repeat", keepHidden = true })
    if ok ~= true then
        if restoreRoute ~= "combat.stats" then pcall(function() shell:Navigate(restoreRoute, { source = "sequence_combat_restore", keepHidden = true }) end) end
        return Fail("dps_same_route_navigation:" .. tostring(err or "failed"))
    end
    ok, err = shell:Navigate("combat.analytics", { source = "sequence_combat_page", keepHidden = true })
    if ok ~= true then
        if restoreRoute ~= "combat.analytics" then pcall(function() shell:Navigate(restoreRoute, { source = "sequence_combat_restore", keepHidden = true }) end) end
        return Fail("analytics_page_navigation:" .. tostring(err or "failed"))
    end
    if restoreRoute ~= "combat.analytics" then
        local restored, restoreErr = shell:Navigate(restoreRoute, { source = "sequence_combat_restore", keepHidden = true })
        if restored ~= true then return Fail("combat_page_restore:" .. tostring(restoreErr or "failed")) end
    end
    return true
end)

G:RegisterSequenceCase("v3_37_migrated_page_build_matrix", function()
    local shell = S.UIV3 and S.UIV3.Shell or nil
    local pageHost = S.UIV3 and S.UIV3.PageHost or nil
    local acceptance = S.UIV3Acceptance
    local matrix = type(acceptance) == "table" and acceptance.migratedPresentation or nil
    if type(shell) ~= "table" or type(shell.Navigate) ~= "function" then return Fail("shell_navigation_missing") end
    if type(pageHost) ~= "table" or type(pageHost.Navigate) ~= "function" or type(pageHost.pages) ~= "table"
        or type(pageHost.factories) ~= "table" then return Fail("page_host_missing") end
    if type(matrix) ~= "table" or #matrix == 0 then return Fail("migrated_route_matrix_missing") end

    local restoreRoute = tostring(pageHost.activeRoute or shell.lastRoute or "home")
    local builtRoutes = {}
    for _, item in ipairs(matrix) do
        local route = tostring(item.route or "")
        if route == "" or type(pageHost.factories[route]) ~= "function" then
            if restoreRoute ~= "" and restoreRoute ~= route then pcall(function() shell:Navigate(restoreRoute, { source = "sequence_restore", keepHidden = true }) end) end
            return Fail("factory_missing:" .. route)
        end
        local ok, err = shell:Navigate(route, { source = "sequence_migrated_page_build", keepHidden = true })
        if ok ~= true or pageHost.pages[route] == nil then
            if restoreRoute ~= "" and restoreRoute ~= route then pcall(function() shell:Navigate(restoreRoute, { source = "sequence_restore", keepHidden = true }) end) end
            return Fail("page_build:" .. route .. ":" .. tostring(err or "missing page"))
        end
        local failed = pageHost.failedPages and pageHost.failedPages[route] or nil
        if type(failed) == "table" and tonumber(failed.generation) == tonumber(S.Generation) then
            if restoreRoute ~= "" and restoreRoute ~= route then pcall(function() shell:Navigate(restoreRoute, { source = "sequence_restore", keepHidden = true }) end) end
            return Fail("page_quarantined:" .. route .. ":" .. tostring(failed.error or "failed"))
        end
        builtRoutes[route] = true
    end

    -- The specialized matrix above covers migrated features. The registry
    -- loop also exercises every current Active Route, including planned routes
    -- that intentionally resolve through the bounded fallback placeholder.
    local registry = S.FeatureRegistry
    if type(registry) ~= "table" or type(registry.List) ~= "function" or type(pageHost.fallbackFactory) ~= "function" then
        if restoreRoute ~= "" then pcall(function() shell:Navigate(restoreRoute, { source = "sequence_restore", keepHidden = true }) end) end
        return Fail("active_route_registry_or_fallback_missing")
    end
    for _, feature in ipairs(registry:List()) do
        local route = tostring(feature.route or "")
        if route ~= "" and not builtRoutes[route] then
            local ok, err = shell:Navigate(route, { source = "sequence_active_route_build", keepHidden = true })
            if ok ~= true or pageHost.pages[route] == nil then
                if restoreRoute ~= "" and restoreRoute ~= route then pcall(function() shell:Navigate(restoreRoute, { source = "sequence_restore", keepHidden = true }) end) end
                return Fail("active_route_build:" .. route .. ":" .. tostring(err or "missing page"))
            end
            local failed = pageHost.failedPages and pageHost.failedPages[route] or nil
            if type(failed) == "table" and tonumber(failed.generation) == tonumber(S.Generation) then
                if restoreRoute ~= "" and restoreRoute ~= route then pcall(function() shell:Navigate(restoreRoute, { source = "sequence_restore", keepHidden = true }) end) end
                return Fail("active_route_quarantined:" .. route .. ":" .. tostring(failed.error or "failed"))
            end
            builtRoutes[route] = true
        end
    end

    if restoreRoute ~= "" and restoreRoute ~= tostring(pageHost.activeRoute or "") then
        local restored, restoreErr = shell:Navigate(restoreRoute, { source = "sequence_restore", keepHidden = true })
        if restored ~= true then return Fail("page_restore:" .. tostring(restoreErr or "failed")) end
    end

    local widgetHost = S.UIV3 and S.UIV3.WidgetHost or nil
    if type(widgetHost) ~= "table" or type(widgetHost.EnsureInstance) ~= "function"
        or type(widgetHost.GetSpec) ~= "function" or type(widgetHost.IsVisible) ~= "function" then
        return Fail("widget_host_missing")
    end
    for _, item in ipairs(matrix) do
        local widgetId = item.widget
        if widgetId ~= nil then
            widgetId = tostring(widgetId)
            if widgetHost:GetSpec(widgetId) == nil then return Fail("widget_spec_missing:" .. widgetId) end
            local wasVisible = widgetHost:IsVisible(widgetId) == true
            local instance, err = widgetHost:EnsureInstance(widgetId, { source = "sequence_migrated_widget_build" })
            if instance == nil then return Fail("widget_build:" .. widgetId .. ":" .. tostring(err or "missing instance")) end
            local failed = widgetHost.failedInstances and widgetHost.failedInstances[widgetId] or nil
            if type(failed) == "table" and tonumber(failed.generation) == tonumber(S.Generation) then
                return Fail("widget_quarantined:" .. widgetId .. ":" .. tostring(failed.error or "failed"))
            end
            if widgetHost:SetVisible(widgetId, wasVisible, { persist = false, source = "sequence_restore" }) ~= true then
                return Fail("widget_visibility_restore:" .. widgetId)
            end
        end
    end
    return true
end)

G:RegisterSequenceCase("v3_39_modal_build_matrix", function()
    local acceptance = S.UIV3Acceptance
    local matrix = type(acceptance) == "table" and acceptance.migratedPresentation or nil
    local modalHost = S.UIV3 and S.UIV3.ModalHost or nil
    if type(matrix) ~= "table" or type(modalHost) ~= "table"
        or type(modalHost.GetContentRoot) ~= "function" or modalHost:GetContentRoot() == nil
        or type(modalHost.Describe) ~= "function" then
        return Fail("modal_build_matrix_missing")
    end

    local modalModules = {
        ["v3_quest_detail_modal"] = "QuestDetailModalV3",
        ["v3_gear_quick_settings_modal"] = "GearQuickSettingsModalV3",
    }
    local checked = {}
    for _, item in ipairs(matrix) do
        local modalId = item.modal ~= nil and tostring(item.modal) or ""
        if modalId ~= "" and checked[modalId] ~= true then
            checked[modalId] = true
            local moduleName = modalModules[modalId]
            local modal = moduleName ~= nil and S.UIV3 and S.UIV3[moduleName] or nil
            if type(modal) ~= "table" or tostring(modal.id or "") ~= modalId
                or type(modal.EnsureCreated) ~= "function" then
                return Fail("modal_module_missing:" .. modalId)
            end
            local built, buildErr = modal:EnsureCreated()
            if built ~= true or modal.card == nil then
                return Fail("modal_build:" .. modalId .. ":" .. tostring(buildErr or "missing card"))
            end

            -- The gear settings modal has no runtime-data dependency, so it is
            -- safe to exercise the complete visible transaction locally. The
            -- quest modal is only built here; opening it needs a real RU task
            -- group key and must not be faked by this foundation sequence.
            if modalId == "v3_gear_quick_settings_modal" then
                local before = modalHost:Describe().count or 0
                local opened, openErr = modal:Open()
                if opened ~= true then return Fail("modal_open:" .. modalId .. ":" .. tostring(openErr or "failed")) end
                local shown = modalHost:Describe()
                if tonumber(shown.count) ~= tonumber(before) + 1 or tostring(shown.topId or "") ~= modalId then
                    modal:Close("sequence_modal_repair")
                    return Fail("modal_open_stack:" .. modalId)
                end
                if modal:Close("sequence_modal") ~= true then return Fail("modal_close:" .. modalId) end
                if tonumber(modalHost:Describe().count) ~= tonumber(before) then return Fail("modal_close_stack:" .. modalId) end
            end
        end
    end
    return true
end)

G:RegisterSequenceCase("v3_38_floating_policy_zero_defaults", function()
    local floating = S.RSUI and S.RSUI.FloatingSurface or nil
    if type(floating) ~= "table" or type(floating.NormalizeState) ~= "function" then return Fail("floating_surface_missing") end
    local zero = floating:NormalizeState(nil, {
        defaultOverallOpacity = 0,
        defaultBackgroundOpacity = 0,
        defaultTextOpacity = 0,
    })
    if zero.overallOpacity ~= 0 or zero.backgroundOpacity ~= 0 or zero.textOpacity ~= 0 then
        return Fail("explicit_zero_defaults_lost")
    end
    local aliases = floating:NormalizeState(nil, { overallOpacity = 0, backgroundOpacity = 0, textOpacity = 0 })
    if aliases.overallOpacity ~= 0 or aliases.backgroundOpacity ~= 0 or aliases.textOpacity ~= 0 then
        return Fail("zero_alias_defaults_lost")
    end
    return true
end)
