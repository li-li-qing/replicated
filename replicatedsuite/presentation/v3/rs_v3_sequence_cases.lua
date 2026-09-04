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

G:RegisterSequenceCase("v3_40_ui_composite_foundation_pure_contract", function()
    local rsui = S.RSUI
    if type(rsui) ~= "table" or (tonumber(rsui.version) or 0) < 27 then return Fail("rsui_v27_missing") end
    if (tonumber(rsui.StatusChipContractVersion) or 0) < 1 or type(rsui.StatusChip) ~= "function" then return Fail("status_chip_contract") end
    if (tonumber(rsui.TreeViewContractVersion) or 0) < 1 or type(rsui.TreeModel) ~= "table" or type(rsui.TreeView) ~= "function" then return Fail("tree_view_contract") end
    if (tonumber(rsui.DropdownDegradedFailClosedContractVersion) or 0) < 1 then return Fail("dropdown_fail_closed_contract") end
    if (tonumber(rsui.PopupCoordinatorContractVersion) or 0) < 1 or type(rsui.PopupCoordinator) ~= "table"
        or type(rsui.PopupCoordinator.CloseAll) ~= "function" or rsui.DropdownService ~= rsui.PopupCoordinator then return Fail("popup_coordinator_contract") end

    local model = rsui.TreeModel:New({
        nodes = {
            { key = "a", text = "A", children = { { key = "a1", text = "A1" } } },
            { key = "b", text = "B" },
        },
        maxNodes = 16,
    })
    if type(model) ~= "table" or model.lastError ~= nil or #model:GetRows() ~= 2 then return Fail("tree_initial_flatten") end
    local expanded, expandErr = model:SetExpanded("a", true)
    if expanded ~= true or expandErr ~= nil or #model:GetRows() ~= 3 or model:GetRowIndex("a1") ~= 2 then return Fail("tree_expand") end
    local collapsed, collapseErr = model:SetExpanded("a", false)
    if collapsed ~= true or collapseErr ~= nil or #model:GetRows() ~= 2 or model:GetRowIndex("a1") ~= nil then return Fail("tree_collapse") end

    local duplicate = rsui.TreeModel:New({ nodes = { { key = "x" }, { key = "x" } }, maxNodes = 8 })
    if type(duplicate) ~= "table" or tostring(duplicate.lastError or ""):find("tree_duplicate_key", 1, true) == nil then return Fail("tree_duplicate_key_fence") end

    local bounded = rsui.TreeModel:New({
        nodes = { { key = "root", children = { { key = "c1" }, { key = "c2" }, { key = "c3" } } } },
        defaultExpandedDepth = 1,
        maxNodes = 2,
    })
    local snap = bounded:GetSnapshot()
    if #bounded:GetRows() ~= 2 or snap.truncated ~= true or snap.maxNodes ~= 2 then return Fail("tree_bounded_projection") end
    return true
end)


G:RegisterSequenceCase("v3_41_ui_model_integrity_contract", function()
    local rsui = S.RSUI
    if type(rsui) ~= "table" then return Fail("rsui_missing") end
    if (tonumber(rsui.PickerModelContractVersion) or 0) < 1 or type(rsui.PickerModel) ~= "table" then return Fail("picker_model_contract") end
    if (tonumber(rsui.TreeStableIdentityContractVersion) or 0) < 1 then return Fail("tree_identity_contract") end
    if (tonumber(rsui.TreeMutationTransactionContractVersion) or 0) < 2 then return Fail("tree_transaction_contract") end
    if (tonumber(rsui.TreeExpansionStateBoundContractVersion) or 0) < 1 then return Fail("tree_expansion_bound_contract") end
    if (tonumber(rsui.FocusContractVersion) or 0) < 2 or type(rsui.Focus) ~= "table"
        or type(rsui.Focus.CanSet) ~= "function" or type(rsui.Focus.CanClear) ~= "function" then return Fail("focus_target_capability_contract") end

    local missingKey = rsui.TreeModel:New({ nodes = { { text = "missing" } }, maxNodes = 8 })
    if tostring(missingKey.lastError or "") ~= "tree_key_required:1" then return Fail("tree_path_identity_fallback") end

    local tx = rsui.TreeModel:New({
        nodes = { { key = "root", children = { { key = "dup" }, { key = "dup" } } }, { key = "tail" } },
        maxNodes = 16,
    })
    if tx.lastError ~= nil or #tx:GetRows() ~= 2 then return Fail("tree_tx_initial") end
    local beforeRevision = tonumber(tx.revision) or 0
    local expanded, expandErr = tx:SetExpanded("root", true)
    if expanded ~= false or tostring(expandErr or "") ~= "tree_duplicate_key:dup" then return Fail("tree_tx_duplicate_not_rejected") end
    if tx:IsExpanded("root") == true or #tx:GetRows() ~= 2 or (tonumber(tx.revision) or 0) ~= beforeRevision then return Fail("tree_tx_partial_commit") end

    local defaultTree = rsui.TreeModel:New({
        nodes = { { key = "r", children = { { key = "c" } } } },
        defaultExpandedDepth = 1,
        maxNodes = 8,
    })
    if defaultTree:IsExpanded("r") ~= true then return Fail("tree_default_expand") end
    local collapsed = defaultTree:SetExpanded("r", false)
    if collapsed ~= true or defaultTree:IsExpanded("r") == true or #defaultTree:GetRows() ~= 1 then return Fail("tree_explicit_collapse") end
    if defaultTree:Rebuild() ~= true or defaultTree:IsExpanded("r") == true or #defaultTree:GetRows() ~= 1 then return Fail("tree_collapse_not_persistent") end

    local picker = rsui.PickerModel:New({
        items = {
            { key = "heal", text = "Healing Light", keywords = { "support", "spell" } },
            { key = "fire", text = "Fireball", keywords = { "damage", "spell" } },
            { key = "ice", text = "Ice Lance", keywords = { "damage", "spell" } },
        },
        maxScan = 32,
        maxResults = 16,
    })
    if picker.lastError ~= nil then return Fail("picker_initial") end
    local queryChanged, queryErr = picker:SetQuery("damage spell")
    if queryChanged ~= true or queryErr ~= nil or #picker:GetResults() ~= 2 then return Fail("picker_query") end
    if picker:GetResults()[1].key ~= "fire" or picker:GetResults()[2].key ~= "ice" then return Fail("picker_result_order") end
    return true
end)
G:RegisterSequenceCase("v3_42_ui_host_slot_picker_contract", function()
    local rsui = S.RSUI
    if type(rsui) ~= "table" or (tonumber(rsui.version) or 0) < 29 then return Fail("rsui_v29_missing") end
    if (tonumber(rsui.AttachmentContractVersion) or 0) < 1
        or (tonumber(rsui.ReparentPolicyContractVersion) or 0) < 1
        or rsui.NativeReparentSupported ~= false then return Fail("attachment_reparent_contract") end
    if (tonumber(rsui.ResponsiveInspectorContractVersion) or 0) < 1 or type(rsui.ResponsiveInspector) ~= "function" then
        return Fail("responsive_inspector_contract")
    end
    local workspaces = rsui.WorkspaceTemplates
    if type(workspaces) ~= "table" or (tonumber(workspaces.contractVersion) or 0) < 2
        or type(rsui.CreateResponsiveInspectorWorkspace) ~= "function" then return Fail("responsive_workspace_contract") end
    if (tonumber(rsui.SearchablePickerContractVersion) or 0) < 1 or type(rsui.SearchablePicker) ~= "function" then
        return Fail("searchable_picker_contract")
    end
    if (tonumber(rsui.IconPickerContractVersion) or 0) < 1 or type(rsui.IconPicker) ~= "function" then
        return Fail("icon_picker_contract")
    end
    local picker = rsui.PickerModel:New({
        items = {
            { key = "a", text = "Alpha", keywords = { "one", "spell" } },
            { key = "b", text = "Beta", keywords = { "two", "spell" } },
        },
        maxScan = 8,
        maxResults = 8,
    })
    local changed, err = picker:SetQuery("two spell")
    if changed ~= true or err ~= nil or #picker:GetResults() ~= 1 or picker:GetResults()[1].key ~= "b" then
        return Fail("searchable_picker_model_dependency")
    end
    return true
end)
G:RegisterSequenceCase("v3_43_ui_geometry_pointer_contract", function()
    local rsui, layout = S.RSUI, S.Layout
    if type(rsui) ~= "table" or (tonumber(rsui.version) or 0) < 30 then return Fail("rsui_v30_missing") end
    if type(layout) ~= "table" or (tonumber(layout.CoordinateSystemContractVersion) or 0) < 1
        or (tonumber(layout.RectTransformTransactionContractVersion) or 0) < 2 then return Fail("geometry_contract") end
    local coord = layout:GetCoordinateSystemSnapshot()
    if type(coord) ~= "table" or coord.origin ~= "top_left" or coord.xPositive ~= "right" or coord.yPositive ~= "down" then
        return Fail("coordinate_semantics")
    end
    local x, y, err = layout:OffsetPoint(100, 100, "up", 12)
    if err ~= nil or x ~= 100 or y ~= 88 then return Fail("move_up_sign") end
    x, y, err = layout:OffsetPoint(100, 100, "down", 12)
    if err ~= nil or x ~= 100 or y ~= 112 then return Fail("move_down_sign") end

    local tx = layout:CreateRectTransformTransaction({ minWidth = 20, minHeight = 20 })
    local begun = tx:Begin({ x = 100, y = 100, width = 80, height = 60 }, "resize", "top_left")
    if begun ~= true then return Fail("rect_tx_begin") end
    local preview, previewErr = tx:PreviewDelta(-10, -15)
    if previewErr ~= nil or preview.x ~= 90 or preview.y ~= 85 or preview.width ~= 90 or preview.height ~= 75 then
        return Fail("rect_tx_top_left_semantics")
    end
    local overridden, overrideErr = tx:OverridePreview({ x = 92, y = 87, width = 88, height = 73 })
    if overrideErr ~= nil or overridden.x ~= 92 or overridden.y ~= 87 then return Fail("rect_tx_override") end
    local committed, commitErr = tx:Commit()
    if commitErr ~= nil or committed.x ~= 92 or committed.y ~= 87 then return Fail("rect_tx_commit") end

    if (tonumber(rsui.PointerContractVersion) or 0) < 1 or type(rsui.Pointer) ~= "table"
        or rsui.Pointer.captureSupported ~= false then return Fail("pointer_contract") end
    local dx, dy, deltaErr = rsui.Pointer:Delta(100, 100, 90, 85)
    if deltaErr ~= nil or dx ~= -10 or dy ~= -15 then return Fail("pointer_delta_semantics") end
    return true
end)


G:RegisterSequenceCase("v3_44_ui_selection_geometry_contract", function()
    local rsui = S.RSUI
    if type(rsui) ~= "table" or (tonumber(rsui.version) or 0) < 31 then return Fail("rsui_v31_missing") end
    if (tonumber(rsui.SelectionGeometryContractVersion) or 0) < 1
        or type(rsui.SelectionGeometry) ~= "table" or type(rsui.CreateSelectionGeometryModel) ~= "function" then
        return Fail("selection_geometry_contract")
    end
    if (tonumber(rsui.LayoutGuideResolverContractVersion) or 0) < 1
        or type(rsui.LayoutGuideResolver) ~= "table" or type(rsui.LayoutGuideResolver.Resolve) ~= "function" then
        return Fail("layout_guide_contract")
    end
    if (tonumber(rsui.SelectionOverlayContractVersion) or 0) < 1 or type(rsui.SelectionOverlay) ~= "function"
        or (tonumber(rsui.LayoutGuideOverlayContractVersion) or 0) < 1 or type(rsui.LayoutGuideOverlay) ~= "function" then
        return Fail("selection_overlay_contract")
    end

    local selection = rsui:CreateSelectionModel({ id = "__geometry_accept", mode = "multi", selectedKeys = { "a", "b" } })
    local rects = {
        a = { x = 100, y = 100, width = 40, height = 20 },
        b = { x = 160, y = 130, width = 60, height = 30 },
    }
    local geometry = rsui:CreateSelectionGeometryModel({
        id = "__geometry_accept_model", selectionModel = selection,
        getRect = function(key) return rects[key] end,
        maxSelected = 8,
    })
    local ok, err = geometry:Resolve()
    if ok ~= true or err ~= nil then return Fail("selection_geometry_resolve") end
    local bounds = geometry:GetBounds()
    if bounds == nil or bounds.x ~= 100 or bounds.y ~= 100 or bounds.right ~= 220 or bounds.bottom ~= 160 then
        return Fail("selection_geometry_bounds")
    end
    local handles = geometry:GetHandleRects({ size = 8, hitSlop = 2 })
    if type(handles) ~= "table" or #handles ~= 8 then return Fail("selection_handle_count") end
    local hit = rsui.SelectionGeometry:HitTestHandle(100, 100, bounds, { size = 8, hitSlop = 2 })
    if hit ~= "top_left" then return Fail("selection_handle_hit") end

    local snapped, guides, snapErr = rsui.LayoutGuideResolver:Resolve(
        { x = 196, y = 100, width = 40, height = 20 }, "move",
        {
            threshold = 6,
            candidates = { { key = "target", rect = { x = 240, y = 100, width = 40, height = 20 } } },
            gridEnabled = false,
        })
    if snapErr ~= nil or snapped == nil or snapped.x ~= 200 then return Fail("alignment_snap_x") end
    if type(guides) ~= "table" or #guides < 1 or guides[1].axis ~= "x" then return Fail("alignment_guide_x") end

    local gridRect, gridGuides, gridErr = rsui.LayoutGuideResolver:Resolve(
        { x = 103, y = 117, width = 40, height = 20 }, "move",
        { threshold = 4, gridEnabled = true, gridSize = 10, candidates = {} })
    if gridErr ~= nil or gridRect == nil or gridRect.x ~= 100 or gridRect.y ~= 120 then return Fail("grid_snap") end
    if type(gridGuides) ~= "table" or #gridGuides ~= 2 then return Fail("grid_guides") end
    return true
end)

G:RegisterSequenceCase("v3_45_ui_layout_editor_gesture_contract", function()
    local rsui, layout = S.RSUI, S.Layout
    if type(rsui) ~= "table" or (tonumber(rsui.version) or 0) < 32 then return Fail("rsui_v32_missing") end
    if (tonumber(rsui.LayoutEditorGestureContractVersion) or 0) < 1
        or type(rsui.CreateLayoutEditorGestureController) ~= "function"
        or type(rsui.LayoutEditorGestureController) ~= "table" then
        return Fail("layout_editor_gesture_contract")
    end
    if type(layout) ~= "table" or (tonumber(layout.RectTransformTransactionContractVersion) or 0) < 2 then
        return Fail("rect_transform_v2_missing")
    end
    if type(rsui.SelectionOverlay) ~= "function" or type(rsui.LayoutGuideOverlay) ~= "function" then
        return Fail("gesture_overlay_dependencies")
    end
    -- Runtime-native gesture capture is RU-widget dependent and is covered by
    -- the dedicated offline harness; sequence acceptance fences the shared
    -- contract and the no-generic-capture policy without synthesizing input.
    if type(rsui.Pointer) ~= "table" or rsui.Pointer.captureSupported ~= false then
        return Fail("generic_capture_policy")
    end
    return true
end)


G:RegisterSequenceCase("v3_46_ui_layout_editor_model_contract", function()
    local rsui = S.RSUI
    if type(rsui) ~= "table" or (tonumber(rsui.version) or 0) < 33 then return Fail("rsui_v33_missing") end
    if (tonumber(rsui.AnchorPivotContractVersion) or 0) < 1 or type(rsui.CreateAnchorPivotModel) ~= "function" then
        return Fail("anchor_pivot_contract")
    end
    if (tonumber(rsui.LayoutEditorSnapSettingsContractVersion) or 0) < 1
        or type(rsui.CreateLayoutEditorSnapSettingsModel) ~= "function" then return Fail("snap_settings_contract") end

    local model, err = rsui:CreateAnchorPivotModel({
        id = "__anchor_accept",
        parentRect = { x = 0, y = 0, width = 1000, height = 800 },
        rect = { x = 100, y = 100, width = 100, height = 50 },
        anchorX = 0, anchorY = 0, pivotX = 0, pivotY = 0,
    })
    if model == nil or err ~= nil then return Fail("anchor_create") end
    if model:SetAnchorPreset("center", true, "accept") ~= true then return Fail("anchor_preset") end
    local rect = model:GetRect()
    if rect.x ~= 100 or rect.y ~= 100 then return Fail("anchor_preserve_visual") end
    if model:SetParentRect({ x = 0, y = 0, width = 1200, height = 900 }, false, "accept_resize") ~= true then return Fail("anchor_parent_reflow") end
    rect = model:GetRect()
    if rect.x ~= 200 or rect.y ~= 150 then return Fail("anchor_reflow_geometry") end
    model:MoveUp(8)
    rect = model:GetRect()
    if rect.y ~= 142 then return Fail("anchor_move_up_sign") end
    if model:SetPivot(0.5, 0.5, true, "accept_pivot") ~= true then return Fail("pivot_set") end
    rect = model:GetRect()
    if rect.x ~= 200 or rect.y ~= 142 then return Fail("pivot_preserve_visual") end

    local snap = rsui:CreateLayoutEditorSnapSettingsModel({ alignmentEnabled = false, gridEnabled = true, gridSize = 10, threshold = 4 })
    if snap == nil then return Fail("snap_model_create") end
    local options = snap:ToResolverOptions({ candidates = { { key = "near", rect = { x = 239, y = 142, width = 40, height = 20 } } } })
    if options.alignmentEnabled ~= false or options.gridEnabled ~= true or options.gridSize ~= 10 then return Fail("snap_projection") end
    local resolved, guides, snapErr = rsui.LayoutGuideResolver:Resolve({ x = 203, y = 142, width = 40, height = 20 }, "move", options)
    if snapErr ~= nil or resolved == nil or resolved.x ~= 200 then return Fail("snap_grid_only") end
    if type(guides) ~= "table" or #guides < 1 then return Fail("snap_grid_guide") end
    return true
end)

G:RegisterSequenceCase("v3_47_ui_transform_inspector_contract", function()
    local rsui = S.RSUI
    if type(rsui) ~= "table" or (tonumber(rsui.version) or 0) < 36 then return Fail("rsui_v36_missing") end
    if (tonumber(rsui.TransformInspectorContractVersion) or 0) < 2
        or type(rsui.TransformInspector) ~= "function" or type(rsui.types) ~= "table"
        or rsui.types["TransformInspector"] == nil then return Fail("transform_inspector_contract") end
    if type(rsui.types["NumericField"]) ~= "function" or type(rsui.types["DropdownField"]) ~= "function"
        or type(rsui.types["ToggleField"]) ~= "function" or type(rsui.types["FormSection"]) ~= "function" then
        return Fail("transform_inspector_form_dependencies")
    end
    return true
end)

G:RegisterSequenceCase("v3_48_ui_multi_selection_transform_contract", function()
    local rsui = S.RSUI
    if type(rsui) ~= "table" or (tonumber(rsui.version) or 0) < 35 then return Fail("rsui_v35_missing") end
    if (tonumber(rsui.MultiSelectionTransformContractVersion) or 0) < 1
        or type(rsui.CreateMultiSelectionTransformModel) ~= "function"
        or type(rsui.MultiSelectionTransformModel) ~= "table"
        or type(rsui.MultiSelectionTransformSession) ~= "table" then
        return Fail("multi_selection_transform_contract")
    end

    local model, err = rsui:CreateMultiSelectionTransformModel({
        id = "__multi_transform_accept", minChildWidth = 10, minChildHeight = 10,
        items = {
            { key = "a", rect = { x = 100, y = 100, width = 100, height = 50 } },
            { key = "b", rect = { x = 300, y = 200, width = 200, height = 100 } },
        },
    })
    if model == nil or err ~= nil then return Fail("multi_transform_create") end
    local bounds = model:GetBounds()
    if bounds == nil or bounds.x ~= 100 or bounds.y ~= 100 or bounds.width ~= 400 or bounds.height ~= 200 then
        return Fail("multi_transform_bounds")
    end
    local session, sessionErr = model:BeginProjectionSession()
    if session == nil or sessionErr ~= nil then return Fail("multi_transform_session") end
    local projected, projectionErr = session:Project({ x = 200, y = 150, width = 800, height = 400 })
    if projected == nil or projectionErr ~= nil or #projected ~= 2 then return Fail("multi_transform_projection") end
    if projected[1].rect.x ~= 200 or projected[1].rect.y ~= 150
        or projected[1].rect.width ~= 200 or projected[1].rect.height ~= 100 then
        return Fail("multi_transform_child_a")
    end
    if projected[2].rect.x ~= 600 or projected[2].rect.y ~= 350
        or projected[2].rect.width ~= 400 or projected[2].rect.height ~= 200 then
        return Fail("multi_transform_child_b")
    end
    local committed, commitErr = session:Commit(nil, "accept")
    if committed == nil or commitErr ~= nil then return Fail("multi_transform_commit") end
    bounds = model:GetBounds()
    if bounds.x ~= 200 or bounds.y ~= 150 or bounds.width ~= 800 or bounds.height ~= 400 then
        return Fail("multi_transform_commit_bounds")
    end
    local single = rsui:CreateMultiSelectionTransformModel({ items = { { key = "only", rect = { x = 0, y = 0, width = 10, height = 10 } } } })
    if single ~= nil then return Fail("multi_transform_single_must_reject") end
    return true
end)

G:RegisterSequenceCase("v3_49_ui_layout_editor_preview_adapter_contract", function()
    local rsui = S.RSUI
    if type(rsui) ~= "table" or (tonumber(rsui.version) or 0) < 36 then return Fail("rsui_v36_missing") end
    if (tonumber(rsui.LayoutEditorPreviewAdapterContractVersion) or 0) < 1
        or type(rsui.CreateLayoutEditorPreviewAdapter) ~= "function"
        or type(rsui.LayoutEditorPreviewAdapter) ~= "table" then
        return Fail("layout_editor_preview_adapter_contract")
    end
    if (tonumber(rsui.LayoutEditorGestureContractVersion) or 0) < 2
        or (tonumber(rsui.AnchorPivotContractVersion) or 0) < 2
        or (tonumber(rsui.TransformInspectorContractVersion) or 0) < 2 then
        return Fail("layout_editor_transaction_dependencies")
    end

    local selection = rsui:CreateSelectionModel({ id = "__layout_editor_adapter_selection", mode = "multi" })
    selection:SetSelected("a", true, "accept")
    selection:SetSelected("b", true, "accept")
    local source = {
        a = { x = 0, y = 0, width = 100, height = 50 },
        b = { x = 200, y = 100, width = 100, height = 50 },
    }
    local reject = false
    local commits = 0
    local adapter, err = rsui:CreateLayoutEditorPreviewAdapter({
        id = "__layout_editor_adapter_accept",
        selectionModel = selection,
        canvasRect = { x = 0, y = 0, width = 1000, height = 800 },
        getRect = function(key) return source[key] end,
        onCommit = function(items)
            if reject then return false, "accept_reject" end
            for _, item in ipairs(items or {}) do
                source[item.key] = { x=item.rect.x, y=item.rect.y, width=item.rect.width, height=item.rect.height }
            end
            commits = commits + 1
            return true
        end,
    })
    if adapter == nil or err ~= nil or adapter:GetMode() ~= "multi" then return Fail("layout_editor_adapter_multi_create") end
    local bounds = adapter:GetRect()
    if bounds == nil or bounds.x ~= 0 or bounds.y ~= 0 or bounds.width ~= 300 or bounds.height ~= 150 then
        return Fail("layout_editor_adapter_multi_bounds")
    end
    if adapter:BeginGesture("move", "move") ~= true then return Fail("layout_editor_adapter_begin") end
    if adapter:PreviewGesture({ x = 10, y = 20, width = 300, height = 150 }, {}) ~= true then return Fail("layout_editor_adapter_preview") end
    if adapter:CommitGesture({ x = 10, y = 20, width = 300, height = 150 }) ~= true then return Fail("layout_editor_adapter_commit") end
    if commits ~= 1 or source.a.x ~= 10 or source.a.y ~= 20 or source.b.x ~= 210 or source.b.y ~= 120 then
        return Fail("layout_editor_adapter_projection_commit")
    end

    selection:SelectOnly("a", "accept_single")
    if adapter:SyncSelection("accept_single") ~= true or adapter:GetMode() ~= "single" then return Fail("layout_editor_adapter_single_sync") end
    local anchor = adapter:GetAnchorModel()
    if anchor == nil or type(anchor.GetSnapshot) ~= "function" then return Fail("layout_editor_adapter_anchor_model") end
    local before = anchor:GetSnapshot()
    reject = true
    if anchor:SetAnchorPreset("center", true, "accept_anchor") ~= true then return Fail("layout_editor_adapter_anchor_mutate") end
    local accepted = adapter:CommitSingleAnchorEdit("accept_anchor", before)
    local after = anchor:GetSnapshot()
    if accepted ~= false or after.anchorX ~= before.anchorX or after.anchorY ~= before.anchorY
        or after.pivotX ~= before.pivotX or after.pivotY ~= before.pivotY then
        return Fail("layout_editor_adapter_anchor_rollback")
    end
    return true
end)

G:RegisterSequenceCase("v3_50_ui_layout_editor_composition_contract", function()
    local rsui = S.RSUI
    local templates = rsui and rsui.WorkspaceTemplates or nil
    if type(rsui) ~= "table" or (tonumber(rsui.version) or 0) < 38 then return Fail("rsui_v38_missing") end
    if (tonumber(rsui.LayoutEditorOverlayContractVersion) or 0) < 1
        or type(rsui.LayoutEditorOverlay) ~= "function"
        or type(rsui.types) ~= "table" or rsui.types["LayoutEditorOverlay"] == nil then
        return Fail("layout_editor_overlay_contract")
    end
    if type(templates) ~= "table" or (tonumber(templates.contractVersion) or 0) < 6
        or (tonumber(rsui.LayoutEditorWorkspaceContractVersion) or 0) < 4
        or (tonumber(rsui.ComponentApiContractVersion) or 0) < 1
        or type(rsui.RequireComponentMethods) ~= "function"
        or (tonumber(rsui.LayoutEditorWorkspaceSessionBindingContractVersion) or 0) < 1
        or type(templates.ValidateLayoutEditorEditSessionSpec) ~= "function"
        or type(rsui.CreateLayoutEditorWorkspace) ~= "function" then
        return Fail("layout_editor_workspace_contract")
    end
    if (tonumber(rsui.LayoutEditorGestureContractVersion) or 0) < 2
        or (tonumber(rsui.TransformInspectorContractVersion) or 0) < 2
        or (tonumber(rsui.LayoutEditorPreviewAdapterContractVersion) or 0) < 1 then
        return Fail("layout_editor_workspace_dependencies")
    end
    return true
end)

G:RegisterSequenceCase("v3_51_ui_layout_edit_history_contract", function()
    local rsui = S.RSUI
    if type(rsui) ~= "table" or (tonumber(rsui.version) or 0) < 39 then return Fail("rsui_v39_missing") end
    if (tonumber(rsui.LayoutEditHistoryContractVersion) or 0) < 1
        or type(rsui.CreateLayoutEditHistoryModel) ~= "function"
        or type(rsui.LayoutEditHistoryModel) ~= "table" then
        return Fail("layout_edit_history_contract")
    end

    -- Standalone transaction semantics: cursor changes only after accepted
    -- apply; a partially-mutating rejected apply is restored by rollback.
    local external = { a = { x = 0, y = 0, width = 100, height = 50 } }
    local rejectApply = false
    local history, historyErr = rsui:CreateLayoutEditHistoryModel({
        id = "__layout_history_accept", maxCommands = 4,
        apply = function(items, context)
            for _, item in ipairs(items or {}) do
                external[item.key] = { x=item.rect.x, y=item.rect.y, width=item.rect.width, height=item.rect.height }
            end
            if rejectApply == true and not (context and context.rollback == true) then return false, "accept_reject" end
            return true
        end,
    })
    if history == nil or historyErr ~= nil then return Fail("layout_history_create") end
    if history:Record({
        source = "accept_move_1", beforeItems = { { key="a", rect={ x=0,y=0,width=100,height=50 } } },
        afterItems = { { key="a", rect={ x=10,y=0,width=100,height=50 } } },
    }) ~= true then return Fail("layout_history_record_1") end
    external.a.x = 10
    if history:Record({
        source = "accept_move_2", beforeItems = { { key="a", rect={ x=10,y=0,width=100,height=50 } } },
        afterItems = { { key="a", rect={ x=20,y=0,width=100,height=50 } } },
    }) ~= true then return Fail("layout_history_record_2") end
    external.a.x = 20
    if history:Undo() ~= true or external.a.x ~= 10 then return Fail("layout_history_undo") end
    rejectApply = true
    local rejected = history:Undo()
    local rejectedSnapshot = history:GetSnapshot()
    if rejected ~= false or external.a.x ~= 10 or rejectedSnapshot.cursor ~= 1 then
        return Fail("layout_history_reject_rollback")
    end
    rejectApply = false
    if history:Undo() ~= true or external.a.x ~= 0 then return Fail("layout_history_undo_to_origin") end
    if history:Redo() ~= true or external.a.x ~= 10 then return Fail("layout_history_redo") end

    local bounded = rsui:CreateLayoutEditHistoryModel({ id = "__layout_history_bounded", maxCommands = 2 })
    if bounded == nil then return Fail("layout_history_bounded_create") end
    for index = 1, 3 do
        local beforeX, afterX = index - 1, index
        if bounded:Record({
            source = "bounded_" .. tostring(index),
            beforeItems = { { key="a", rect={ x=beforeX,y=0,width=100,height=50 } } },
            afterItems = { { key="a", rect={ x=afterX,y=0,width=100,height=50 } } },
        }) ~= true then return Fail("layout_history_bounded_record") end
    end
    local boundedSnapshot = bounded:GetSnapshot()
    if boundedSnapshot.count ~= 2 or boundedSnapshot.cursor ~= 2 or boundedSnapshot.trims ~= 1 then
        return Fail("layout_history_bounded_trim")
    end

    -- Adapter integration: preview/cancel creates no command; successful commit
    -- does. Anchor/Pivot state is reversible even when visual rect is unchanged.
    local selection = rsui:CreateSelectionModel({ id = "__layout_history_adapter_selection", mode = "single", selectedKeys = { "a" } })
    local source = { a = { x = 0, y = 0, width = 100, height = 50 } }
    local anchorState = { anchorX = 0, anchorY = 0, pivotX = 0, pivotY = 0 }
    local adapter, adapterErr = rsui:CreateLayoutEditorPreviewAdapter({
        id = "__layout_history_adapter", selectionModel = selection,
        canvasRect = { x=0, y=0, width=1000, height=800 }, historyEnabled = true,
        getRect = function(key) return source[key] end,
        getAnchorSpec = function()
            return { parentRect={ x=0,y=0,width=1000,height=800 }, anchorX=anchorState.anchorX, anchorY=anchorState.anchorY,
                pivotX=anchorState.pivotX, pivotY=anchorState.pivotY }
        end,
        onCommit = function(items, context)
            for _, item in ipairs(items or {}) do
                source[item.key] = { x=item.rect.x, y=item.rect.y, width=item.rect.width, height=item.rect.height }
            end
            local anchor = context and context.metadata and context.metadata.anchor or nil
            if type(anchor) == "table" then
                anchorState.anchorX, anchorState.anchorY = anchor.anchorX, anchor.anchorY
                anchorState.pivotX, anchorState.pivotY = anchor.pivotX, anchor.pivotY
            end
            return true
        end,
    })
    if adapter == nil or adapterErr ~= nil then return Fail("layout_history_adapter_create") end
    local adapterHistory = adapter:GetHistoryModel()
    if adapterHistory == nil then return Fail("layout_history_adapter_history_missing") end
    if adapter:BeginGesture("move", "move") ~= true then return Fail("layout_history_adapter_preview_begin") end
    if adapter:PreviewGesture({ x=5,y=0,width=100,height=50 }, {}) ~= true then return Fail("layout_history_adapter_preview") end
    if adapter:CancelGesture("accept_cancel") ~= true then return Fail("layout_history_adapter_cancel") end
    if adapterHistory:GetSnapshot().count ~= 0 then return Fail("layout_history_preview_must_not_record") end

    if adapter:BeginGesture("move", "move") ~= true then return Fail("layout_history_adapter_commit_begin") end
    if adapter:PreviewGesture({ x=10,y=0,width=100,height=50 }, {}) ~= true then return Fail("layout_history_adapter_commit_preview") end
    if adapter:CommitGesture({ x=10,y=0,width=100,height=50 }) ~= true then return Fail("layout_history_adapter_commit") end
    if adapterHistory:GetSnapshot().count ~= 1 or source.a.x ~= 10 then return Fail("layout_history_adapter_commit_record") end

    local anchorModel = adapter:GetAnchorModel()
    local beforeAnchor = anchorModel and anchorModel:GetSnapshot() or nil
    if beforeAnchor == nil or anchorModel:SetAnchorPreset("center", true, "accept_anchor") ~= true then
        return Fail("layout_history_anchor_change")
    end
    if adapter:CommitSingleAnchorEdit("accept_anchor", beforeAnchor) ~= true then return Fail("layout_history_anchor_commit") end
    if adapterHistory:GetSnapshot().count ~= 2 or anchorState.anchorX ~= 0.5 or source.a.x ~= 10 then
        return Fail("layout_history_anchor_record")
    end
    if adapterHistory:Undo() ~= true or anchorState.anchorX ~= 0 or adapter:GetAnchorModel():GetSnapshot().anchorX ~= 0 then
        return Fail("layout_history_anchor_undo")
    end
    if adapterHistory:Undo() ~= true or source.a.x ~= 0 then return Fail("layout_history_adapter_move_undo") end
    if adapterHistory:Redo() ~= true or source.a.x ~= 10 then return Fail("layout_history_adapter_move_redo") end
    return true
end)

G:RegisterSequenceCase("v3_52_ui_editor_command_bar_contract", function()
    local rsui = S.RSUI
    if type(rsui) ~= "table" or (tonumber(rsui.version) or 0) < 41 then return Fail("rsui_v41_missing") end
    if (tonumber(rsui.LayoutEditHistoryObservableContractVersion) or 0) < 1
        or (tonumber(rsui.EditorCommandBarContractVersion) or 0) < 2
        or (tonumber(rsui.EditorCommandSessionProjectionContractVersion) or 0) < 2
        or type(rsui.ProjectEditorCommandState) ~= "function" then
        return Fail("editor_command_bar_contract")
    end

    local history = rsui:CreateLayoutEditHistoryModel({ id = "__command_bar_history", maxCommands = 4 })
    if history == nil or type(history.Subscribe) ~= "function" or type(history.Unsubscribe) ~= "function" then
        return Fail("editor_command_history_observable")
    end
    local notifications = 0
    if history:Subscribe("__command_bar_case", function() notifications = notifications + 1 end) ~= true then
        return Fail("editor_command_history_subscribe")
    end
    if history:Record({
        source = "command_bar_case",
        beforeItems = { { key="a", rect={ x=0,y=0,width=10,height=10 } } },
        afterItems = { { key="a", rect={ x=1,y=0,width=10,height=10 } } },
    }) ~= true or notifications ~= 1 then
        return Fail("editor_command_history_notification")
    end

    local noSession = rsui.ProjectEditorCommandState(history:GetSnapshot(), nil)
    if type(noSession) ~= "table" or noSession.canUndo ~= true or noSession.canRedo ~= false
        or noSession.canRevert ~= false or noSession.canReset ~= false or noSession.canApply ~= false then
        return Fail("editor_command_projection_no_session")
    end
    local session = { revision=3, dirty=true, busy=false, canRevert=true, canReset=true, canApply=true, statusText="dirty" }
    local withSession = rsui.ProjectEditorCommandState(history:GetSnapshot(), session)
    if type(withSession) ~= "table" or withSession.canUndo ~= true or withSession.canRevert ~= true
        or withSession.canReset ~= true or withSession.canApply ~= true or withSession.dirty ~= true then
        return Fail("editor_command_projection_session")
    end
    session.busy = true
    local busy = rsui.ProjectEditorCommandState(history:GetSnapshot(), session)
    if busy.canUndo ~= false or busy.canRedo ~= false or busy.canRevert ~= false
        or busy.canReset ~= false or busy.canApply ~= false or busy.busy ~= true then
        return Fail("editor_command_projection_busy_fence")
    end
    if history:Unsubscribe("__command_bar_case") ~= true then return Fail("editor_command_history_unsubscribe") end
    if history:Clear("command_bar_case_clear") ~= true or notifications ~= 1 then
        return Fail("editor_command_history_unsubscribe_fence")
    end
    return true
end)


G:RegisterSequenceCase("v3_53_ui_layout_edit_session_contract", function()
    local rsui = S.RSUI
    if type(rsui) ~= "table" or (tonumber(rsui.version) or 0) < 41 then return Fail("rsui_v41_missing") end
    if (tonumber(rsui.LayoutEditSessionContractVersion) or 0) < 1
        or (tonumber(rsui.LayoutEditSessionPersistenceBoundaryContractVersion) or 0) < 1
        or type(rsui.CreateLayoutEditSessionModel) ~= "function" then
        return Fail("layout_edit_session_contract")
    end

    local working = { layout = { x = 10, y = 20, width = 100, height = 50 } }
    local persisted = { layout = { x = 10, y = 20, width = 100, height = 50 } }
    local defaults = { layout = { x = 0, y = 0, width = 100, height = 50 } }
    local persistCalls = 0
    local rejectPersist = false
    local allowPersist = true

    local history = rsui:CreateLayoutEditHistoryModel({ id = "__layout_session_history", maxCommands = 8 })
    if history == nil then return Fail("layout_edit_session_history_create") end

    local session, sessionErr = rsui:CreateLayoutEditSessionModel({
        id = "__layout_session",
        historyModel = history,
        getWorkingSnapshot = function() return working end,
        getPersistedSnapshot = function() return persisted end,
        getDefaultSnapshot = function() return defaults end,
        applyWorkingSnapshot = function(snapshot, context)
            if type(snapshot) ~= "table" or type(snapshot.layout) ~= "table" then return false, "snapshot_invalid" end
            if type(context) ~= "table" or context.persist == true then return false, "working_boundary_invalid" end
            working = { layout = {
                x = snapshot.layout.x, y = snapshot.layout.y,
                width = snapshot.layout.width, height = snapshot.layout.height,
            } }
            return true
        end,
        persistSnapshot = function(snapshot, context)
            persistCalls = persistCalls + 1
            if type(context) ~= "table" or context.persist ~= true or context.durable ~= true then
                return false, "persist_boundary_invalid"
            end
            if rejectPersist == true then return false, "persist_rejected" end
            persisted = { layout = {
                x = snapshot.layout.x, y = snapshot.layout.y,
                width = snapshot.layout.width, height = snapshot.layout.height,
            } }
            return true
        end,
        canPersist = function()
            if allowPersist ~= true then return false, "write_fenced" end
            return true
        end,
    })
    if session == nil or sessionErr ~= nil then return Fail("layout_edit_session_create") end

    local initial = session:GetCommandSnapshot()
    if initial.dirty ~= false or initial.canRevert ~= false or initial.canApply ~= false
        or initial.canReset ~= true or initial.workingAtDefaults ~= false then
        return Fail("layout_edit_session_initial_projection")
    end

    -- Simulate a successful editor commit: Domain changes first, History Record
    -- then notifies Session. No polling/explicit page dirty flag is needed.
    working.layout.x = 25
    if history:Record({
        source = "session_edit_1",
        beforeItems = { { key="a", rect={ x=10,y=20,width=100,height=50 } } },
        afterItems = { { key="a", rect={ x=25,y=20,width=100,height=50 } } },
    }) ~= true then return Fail("layout_edit_session_history_record") end
    local edited = session:GetCommandSnapshot()
    if edited.dirty ~= true or edited.canRevert ~= true or edited.canApply ~= true then
        return Fail("layout_edit_session_history_refresh")
    end

    -- Reset is staging only: Working <- Defaults, no persistence, history barrier.
    if session:ExecuteCommand("reset", { source = "sequence" }) ~= true then return Fail("layout_edit_session_reset") end
    if working.layout.x ~= 0 or persistCalls ~= 0 or history:GetSnapshot().count ~= 0 then
        return Fail("layout_edit_session_reset_boundary")
    end
    local resetState = session:GetCommandSnapshot()
    if resetState.dirty ~= true or resetState.canReset ~= false or resetState.canRevert ~= true or resetState.canApply ~= true then
        return Fail("layout_edit_session_reset_projection")
    end

    -- Revert returns to SessionBaseline and still never persists.
    if session:ExecuteCommand("revert", { source = "sequence" }) ~= true then return Fail("layout_edit_session_revert") end
    if working.layout.x ~= 10 or persistCalls ~= 0 then return Fail("layout_edit_session_revert_boundary") end
    if session:GetCommandSnapshot().dirty ~= false then return Fail("layout_edit_session_revert_dirty") end

    working.layout.x = 30
    if history:Record({
        source = "session_edit_2",
        beforeItems = { { key="a", rect={ x=10,y=20,width=100,height=50 } } },
        afterItems = { { key="a", rect={ x=30,y=20,width=100,height=50 } } },
    }) ~= true then return Fail("layout_edit_session_history_record_2") end

    allowPersist = false
    local fenced = session:GetCommandSnapshot()
    if fenced.dirty ~= true or fenced.canApply ~= false or fenced.canRevert ~= true then
        return Fail("layout_edit_session_persistence_fence")
    end
    allowPersist = true
    rejectPersist = true
    if session:ExecuteCommand("apply", { source = "sequence" }) ~= false then return Fail("layout_edit_session_apply_reject") end
    local afterReject = session:GetStateSnapshot()
    if persistCalls ~= 1 or working.layout.x ~= 30 or afterReject.command.dirty ~= true
        or afterReject.baseline.layout.x ~= 10 or history:GetSnapshot().count ~= 1 then
        return Fail("layout_edit_session_apply_reject_boundary")
    end

    rejectPersist = false
    if session:ExecuteCommand("apply", { source = "sequence" }) ~= true then return Fail("layout_edit_session_apply") end
    local applied = session:GetStateSnapshot()
    if persistCalls ~= 2 or persisted.layout.x ~= 30 or applied.persisted.layout.x ~= 30
        or applied.baseline.layout.x ~= 30 or applied.working.layout.x ~= 30
        or applied.command.dirty ~= false or applied.command.canRevert ~= false
        or history:GetSnapshot().count ~= 0 then
        return Fail("layout_edit_session_apply_boundary")
    end

    -- SessionBaseline and Persisted are intentionally distinct states. An
    -- editor may open on a valid runtime Working snapshot that differs from the
    -- last durable snapshot; Apply must be available without inventing Revert.
    local working2 = { layout = { x=50,y=0,width=10,height=10 } }
    local persisted2 = { layout = { x=40,y=0,width=10,height=10 } }
    local session2 = rsui:CreateLayoutEditSessionModel({
        id = "__layout_session_four_state",
        getWorkingSnapshot = function() return working2 end,
        getPersistedSnapshot = function() return persisted2 end,
        getDefaultSnapshot = function() return { layout={ x=0,y=0,width=10,height=10 } } end,
        applyWorkingSnapshot = function(snapshot) working2 = snapshot; return true end,
        persistSnapshot = function(snapshot) persisted2 = snapshot; return true end,
    })
    if session2 == nil then return Fail("layout_edit_session_four_state_create") end
    local fourState = session2:GetCommandSnapshot()
    if fourState.dirty ~= true or fourState.sessionChanged ~= false
        or fourState.canApply ~= true or fourState.canRevert ~= false then
        return Fail("layout_edit_session_four_state_projection")
    end
    if session2:ExecuteCommand("apply", { source="sequence" }) ~= true
        or session2:GetCommandSnapshot().dirty ~= false then
        return Fail("layout_edit_session_four_state_apply")
    end
    session2:Release()

    local projectedBlocked = rsui.ProjectEditorCommandState(
        { revision=1, busy=false, canUndo=true, canRedo=true, count=2, cursor=1 },
        { revision=1, busy=false, blocked=true, dirty=true, canRevert=true, canReset=true, canApply=true, statusText="blocked" })
    if type(projectedBlocked) ~= "table" or projectedBlocked.blocked ~= true
        or projectedBlocked.canUndo ~= false or projectedBlocked.canRedo ~= false
        or projectedBlocked.canRevert ~= false or projectedBlocked.canReset ~= false or projectedBlocked.canApply ~= false then
        return Fail("layout_edit_session_blocked_projection")
    end

    session:Release()
    history:Release()
    return true
end)

G:RegisterSequenceCase("v3_54_ui_layout_editor_workspace_integration_contract", function()
    local rsui = S.RSUI
    local templates = rsui and rsui.WorkspaceTemplates or nil
    if type(rsui) ~= "table" or (tonumber(rsui.version) or 0) < 44 then return Fail("rsui_v44_missing") end
    if type(templates) ~= "table" or (tonumber(templates.contractVersion) or 0) < 6
        or (tonumber(rsui.LayoutEditorWorkspaceContractVersion) or 0) < 4
        or (tonumber(rsui.ComponentApiContractVersion) or 0) < 1
        or type(rsui.RequireComponentMethods) ~= "function"
        or (tonumber(rsui.LayoutEditorWorkspaceSessionBindingContractVersion) or 0) < 1
        or type(templates.ValidateLayoutEditorEditSessionSpec) ~= "function" then
        return Fail("layout_editor_workspace_integration_contract")
    end
    local valid, validErr = templates:ValidateLayoutEditorEditSessionSpec({
        getWorkingSnapshot = function() return { layout = {} } end,
        getPersistedSnapshot = function() return { layout = {} } end,
        getDefaultSnapshot = function() return { layout = {} } end,
        applyWorkingSnapshot = function() return true end,
        persistSnapshot = function() return true end,
        canPersist = function() return true end,
    })
    if valid ~= true or validErr ~= nil then return Fail("layout_editor_workspace_session_preflight") end
    local transientOk = templates:ValidateLayoutEditorEditSessionSpec(nil)
    if transientOk ~= true then return Fail("layout_editor_workspace_transient_preflight") end
    local partialOk, partialErr = templates:ValidateLayoutEditorEditSessionSpec({
        getWorkingSnapshot = function() return {} end,
    })
    if partialOk ~= false or tostring(partialErr) ~= "layout_editor_workspace_edit_session_callback_required:getPersistedSnapshot" then
        return Fail("layout_editor_workspace_partial_session_must_reject")
    end
    if (tonumber(rsui.LayoutEditorOverlayHistoryBindingContractVersion) or 0) < 1
        or (tonumber(rsui.LayoutEditHistoryContractVersion) or 0) < 1
        or (tonumber(rsui.LayoutEditSessionContractVersion) or 0) < 1
        or (tonumber(rsui.EditorCommandBarContractVersion) or 0) < 2 then
        return Fail("layout_editor_workspace_authority_dependencies")
    end
    return true
end)

G:RegisterSequenceCase("v3_55_unit_line_adaptive_sampling_contract", function()
    local guides = S.UIV3 and S.UIV3.CombatVisualGuidesV3 or nil
    if type(guides) ~= "table" or (tonumber(guides.version) or 0) < 5
        or (tonumber(guides.AdaptiveUnitLineSamplingContractVersion) or 0) < 2
        or (tonumber(guides.UnitLineVisibleSegmentClippingContractVersion) or 0) < 1
        or (tonumber(guides.UnitLinePressureBudgetContractVersion) or 0) < 1
        or (tonumber(guides.UnitLineDiffRenderContractVersion) or 0) < 1
        or (tonumber(guides.UnitLineProgressivePoolContractVersion) or 0) < 1
        or type(guides.BuildUnitLineSamplePlan) ~= "function" then
        return Fail("unit_line_adaptive_contract")
    end
    local projection = { pointCount=24, pairPoints={ target=24 }, refreshMs=100 }
    local near = guides:BuildUnitLineSamplePlan({ { pairKey="target",x1=100,y1=100,x2=200,y2=100 } }, projection, 1024, 768)
    if type(near) ~= "table" or #near ~= 1 or near[1].count ~= 24 or near[1].clipped ~= false then
        return Fail("unit_line_near_density_floor")
    end
    local long = guides:BuildUnitLineSamplePlan({ { pairKey="target",x1=50,y1=100,x2=950,y2=100 } }, projection, 1024, 768)
    if type(long) ~= "table" or #long ~= 1 or tonumber(long[1].count) == nil or long[1].count <= 48 then
        return Fail("unit_line_long_distance_must_add_samples")
    end
    local clipped = guides:BuildUnitLineSamplePlan({ { pairKey="target",x1=-10000,y1=384,x2=512,y2=384 } }, projection, 1024, 768)
    if type(clipped) ~= "table" or #clipped ~= 1 or clipped[1].clipped ~= true
        or math.abs((tonumber(clipped[1].x1) or -1)-0) > 0.01 or math.abs((tonumber(clipped[1].x2) or -1)-512) > 0.01 then
        return Fail("unit_line_visible_segment_clipping")
    end
    local hidden = guides:BuildUnitLineSamplePlan({ { pairKey="target",x1=-100,y1=-100,x2=-50,y2=-50 } }, projection, 1024, 768)
    if type(hidden) ~= "table" or #hidden ~= 0 then return Fail("unit_line_offscreen_segment_cull") end
    local rows = {}
    for index=1,4 do rows[index]={ pairKey=(index==1 and "target" or ("edge"..index)),x1=0,y1=index*100,x2=1024,y2=index*100 } end
    local fastProjection = { pointCount=48, pairPoints={ target=48,edge2=48,edge3=48,edge4=48 }, refreshMs=1 }
    local fast,budget = guides:BuildUnitLineSamplePlan(rows, fastProjection, 1024, 768, "Normal")
    local total=0; for _,plan in ipairs(fast or {}) do total=total+(tonumber(plan.count) or 0) end
    if tonumber(budget) ~= 256 or total > 256 then return Fail("unit_line_fast_refresh_budget") end
    local pressured,criticalBudget = guides:BuildUnitLineSamplePlan(rows, fastProjection, 1024, 768, "Critical")
    local pressuredTotal=0; for _,plan in ipairs(pressured or {}) do pressuredTotal=pressuredTotal+(tonumber(plan.count) or 0) end
    -- With four explicit base=48 edges, the configured base floor (192) wins
    -- over the nominal Critical factor. Pressure may shed only adaptive EXTRA
    -- density, never the user's persisted base density.
    if tonumber(criticalBudget) ~= 192 or pressuredTotal ~= 192 then return Fail("unit_line_pressure_budget_base_floor") end
    return true
end)



G:RegisterSequenceCase("v3_56_ui_component_api_contract", function()
    local rsui = S.RSUI
    if type(rsui) ~= "table" or (tonumber(rsui.version) or 0) < 44
        or (tonumber(rsui.ComponentApiContractVersion) or 0) < 1
        or type(rsui.RequireComponentMethods) ~= "function"
        or type(rsui.BaseComponent) ~= "table"
        or type(rsui.BaseComponent.Show) ~= "function"
        or type(rsui.BaseComponent.Hide) ~= "function" then
        return Fail("rsui_component_api_contract")
    end
    local probe = {
        SetVisible = function() return true end,
        SetText = function() return true end,
    }
    local ok, err = rsui:RequireComponentMethods(probe, { "SetVisible", "SetText" }, "sequence_probe")
    if ok ~= true or err ~= nil then return Fail("component_api_positive_probe") end
    local missingOk, missingErr = rsui:RequireComponentMethods(probe, { "SetVisible", "Show" }, "sequence_probe")
    if missingOk ~= false or tostring(missingErr) ~= "component_method_required:sequence_probe:Show" then
        return Fail("component_api_missing_method_probe")
    end
    return true
end)
