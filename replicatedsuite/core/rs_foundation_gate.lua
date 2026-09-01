------------------------------------------------------------------------
-- Replicated Suite - V3 Foundation Readiness Gate
--
-- One on-demand, copy-friendly verdict for infrastructure readiness. This gate
-- never polls and never starts feature modules. Legacy presentation debt is
-- reported explicitly instead of being hidden behind a green UI screenshot.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite

S.FoundationGate = {
    version = 62,
    last = nil,
    sequenceCases = {},
    sequenceOrder = {},
}
local G = S.FoundationGate

local function AddCheck(report, id, ok, severity, detail)
    local row = { id=tostring(id), ok=ok == true, severity=tostring(severity or "blocker"), detail=tostring(detail or "") }
    report.checks[#report.checks + 1] = row
    if not row.ok then
        if row.severity == "blocker" then report.blockers = report.blockers + 1 else report.warnings = report.warnings + 1 end
    end
    return row
end

local function Join(values, maxItems)
    local out = {}
    for i=1,math.min(#values, math.max(1, tonumber(maxItems) or #values)) do out[#out+1] = tostring(values[i]) end
    if #values > #out then out[#out+1] = "+" .. tostring(#values - #out) end
    return table.concat(out, ",")
end

function G:RegisterSequenceCase(id, fn)
    id = tostring(id or "")
    if id == "" or type(fn) ~= "function" then return false end
    if self.sequenceCases[id] == nil then self.sequenceOrder[#self.sequenceOrder+1] = id; table.sort(self.sequenceOrder) end
    self.sequenceCases[id] = fn
    return true
end

function G:RunSequences()
    local result = { total=0, passed=0, failed=0, failures={} }
    for _, id in ipairs(self.sequenceOrder) do
        result.total = result.total + 1
        local ok, value, detail = xpcall(self.sequenceCases[id], S.SafeTraceback)
        local passed = ok and value ~= false
        if passed then
            result.passed = result.passed + 1
        else
            result.failed = result.failed + 1
            local reason = ok and tostring(detail or "returned_false") or tostring(value)
            result.failures[#result.failures+1] = id .. ":" .. reason
        end
    end
    return result
end

function G:Run(options)
    options = type(options) == "table" and options or {}
    local report = { version=self.version, checks={}, blockers=0, warnings=0, status="BLOCKED" }

    local host = S.UIHostManager and S.UIHostManager:Describe() or nil
    local v3HostRegistered = S.UIHostManager ~= nil
        and type(S.UIHostManager.IsRegistered) == "function"
        and S.UIHostManager:IsRegistered("v3")
    AddCheck(report, "presentation_host", host ~= nil and tonumber(host.total) and host.total >= 1 and host.activeId ~= nil,
        "blocker", host and ("active=" .. tostring(host.activeId) .. "/hosts=" .. tostring(host.total) .. "/fail=" .. tostring(host.stats and host.stats.failures or 0)) or "missing")
    if host ~= nil then
        AddCheck(report, "presentation_navigation_authority",
            (tonumber(host.contractV2) or 0) == (tonumber(host.total) or 0)
                and (tonumber(host.navigationReady) or 0) == (tonumber(host.total) or 0),
            "blocker", "v2=" .. tostring(host.contractV2 or 0) .. "/" .. tostring(host.total or 0)
                .. "/nav=" .. tostring(host.navigationReady or 0)
                .. "/routeFail=" .. tostring(host.stats and host.stats.routeFailures or 0))
    end

    if tostring(S.ArchitectureMode or "") == "v3_rebuild" then
        local legacyRegistered = S.UIHostManager ~= nil and type(S.UIHostManager.IsRegistered) == "function" and S.UIHostManager:IsRegistered("legacy")
        local staleLegacyEntry = S.MainWindow ~= nil or S.MainButton ~= nil or S.TaskWidget ~= nil or S.EventWidget ~= nil
        AddCheck(report, "legacy_presentation_detached", legacyRegistered ~= true and staleLegacyEntry ~= true, "blocker",
            "host=" .. tostring(legacyRegistered == true) .. "/stale=" .. tostring(staleLegacyEntry == true))
    end

    local nativeInfo = S.NativeCapabilities and type(S.NativeCapabilities.Describe) == "function" and S.NativeCapabilities:Describe() or nil
    local nativeOk, nativeErr = false, "native capabilities missing"
    if S.NativeCapabilities ~= nil and type(S.NativeCapabilities.Validate) == "function" then
        nativeOk, nativeErr = S.NativeCapabilities:Validate()
    end
    AddCheck(report, "native_foundation", nativeOk == true, "blocker",
        nativeOk == true and ("owner=" .. tostring(nativeInfo and nativeInfo.owner or "?") .. "/contract=" .. tostring(nativeInfo and nativeInfo.contract and nativeInfo.contract.version or "?"))
            or tostring(nativeErr or "invalid"))
    AddCheck(report, "native_independence", nativeInfo ~= nil
            and tonumber(nativeInfo.externalGlobalsConsumed) == 0
            and tonumber(nativeInfo.legacyUiHelpersConsumed) == 0
            and nativeInfo.contract ~= nil
            and tonumber(nativeInfo.contract.externalGlobalsConsumed) == 0
            and tonumber(nativeInfo.contract.legacyUiHelpersConsumed) == 0,
        "blocker", "external=" .. tostring(nativeInfo and nativeInfo.externalGlobalsConsumed or "?")
            .. "/legacyHelpers=" .. tostring(nativeInfo and nativeInfo.legacyUiHelpersConsumed or "?"))
    local nativeImports = nativeInfo and nativeInfo.imports or nil
    AddCheck(report, "native_import_authority", nativeImports ~= nil
            and (tonumber(nativeImports.version) or 0) >= 3
            and (tonumber(nativeImports.optionalNegativeCacheContractVersion) or 0) >= 1
            and (tonumber(nativeImports.methodDependencyResolutionContractVersion) or 0) >= 1
            and tostring(nativeImports.source or "") == "replicated_native"
            and (tonumber(nativeImports.foundationFailures) or 0) == 0
            and (tonumber(nativeImports.requiredObjects) or 0) >= 7,
        "blocker", nativeImports and ("v=" .. tostring(nativeImports.version or 0)
            .. "/negCache=" .. tostring(nativeImports.optionalNegativeCacheContractVersion or 0)
            .. "/methodMap=" .. tostring(nativeImports.methodDependencyResolutionContractVersion or 0)
            .. "/cacheHit=" .. tostring(nativeImports.optionalFailureCacheHits or 0)
            .. "/api=" .. tostring(nativeImports.total or 0)
            .. "/core=" .. tostring(nativeImports.core or 0)
            .. "/feature=" .. tostring(nativeImports.feature or 0)
            .. "/objects=" .. tostring(nativeImports.objects or 0)
            .. "/required=" .. tostring(nativeImports.requiredObjects or 0)
            .. "/fail=" .. tostring(nativeImports.failures or 0)
            .. "/foundationFail=" .. tostring(nativeImports.foundationFailures or 0)
            .. "/featureFail=" .. tostring(nativeImports.featureFailures or 0)) or "missing")
    AddCheck(report, "feature_native_import_health", nativeImports ~= nil and (tonumber(nativeImports.featureFailures) or 0) == 0,
        "warning", nativeImports and ("featureFail=" .. tostring(nativeImports.featureFailures or 0)) or "missing")

    local identityInfo = type(S.DescribeNativeIdentity) == "function" and S.DescribeNativeIdentity() or nil
    local factoryInfo = S.NativeObjectFactory and type(S.NativeObjectFactory.Describe) == "function" and S.NativeObjectFactory:Describe() or nil
    AddCheck(report, "native_widget_identity", identityInfo ~= nil and (tonumber(identityInfo.version) or 0) >= 2
            and (tonumber(identityInfo.maxPhysicalLength) or 99) <= 23
            and (tonumber(identityInfo.maxObservedLength) or 0) <= (tonumber(identityInfo.maxPhysicalLength) or 23)
            and (tonumber(identityInfo.collisions) or 0) == 0
            and factoryInfo ~= nil and (tonumber(factoryInfo.version) or 0) >= 3
            and (tonumber(factoryInfo.objectImportFenceContractVersion) or 0) >= 1
            and (tonumber(factoryInfo.duplicateRejects) or 0) == 0
            and (tonumber(factoryInfo.invalidIdentityRejects) or 0) == 0
            and (tonumber(factoryInfo.staleParentRejects) or 0) == 0,
        "blocker", "identity=" .. tostring(identityInfo and identityInfo.version or "?")
            .. "/max=" .. tostring(identityInfo and identityInfo.maxObservedLength or "?") .. "/" .. tostring(identityInfo and identityInfo.maxPhysicalLength or "?")
            .. "/collision=" .. tostring(identityInfo and identityInfo.collisions or "?")
            .. "/factory=" .. tostring(factoryInfo and factoryInfo.version or "?")
            .. "/importFence=" .. tostring(factoryInfo and factoryInfo.objectImportFenceContractVersion or 0)
            .. "/dupReject=" .. tostring(factoryInfo and factoryInfo.duplicateRejects or "?")
            .. "/invalidReject=" .. tostring(factoryInfo and factoryInfo.invalidIdentityRejects or "?")
            .. "/staleParent=" .. tostring(factoryInfo and factoryInfo.staleParentRejects or "?"))

    local ui = S.UI
    local authority = ui and type(ui.GetAuthoritySnapshot) == "function" and ui:GetAuthoritySnapshot() or nil
    AddCheck(report, "v3_strict_authority", authority ~= nil and type(ui.AdoptV3Widget) == "function" and type(ui.ClaimNativeAuthority) == "function",
        "blocker", authority and ("claims=" .. tostring(authority.claims or 0) .. "/viol=" .. tostring(authority.violations or 0) .. "/conflict=" .. tostring(authority.conflicts or 0)) or "missing")
    if authority ~= nil then
        local byField = type(authority.byField) == "table" and authority.byField or {}
        AddCheck(report, "v3_authority_clean", (tonumber(authority.violations) or 0) == 0 and (tonumber(authority.conflicts) or 0) == 0,
            "blocker", "viol=" .. tostring(authority.violations or 0)
                .. "/conflict=" .. tostring(authority.conflicts or 0)
                .. "/field[t=" .. tostring(byField.text or 0)
                .. ",v=" .. tostring(byField.visible or 0)
                .. ",e=" .. tostring(byField.extent or 0)
                .. ",a=" .. tostring(byField.anchor or 0) .. "]")
    end
    local registrySnapshot = ui and type(ui.GetRegistrySnapshot) == "function" and ui:GetRegistrySnapshot() or nil
    AddCheck(report, "v3_component_ids", registrySnapshot ~= nil and (tonumber(registrySnapshot.v3Duplicates) or 0) == 0,
        "blocker", registrySnapshot and ("dup=" .. tostring(registrySnapshot.duplicates or 0) .. "/v3=" .. tostring(registrySnapshot.v3Duplicates or 0)
            .. "/degraded=" .. tostring(registrySnapshot.degraded or 0)) or "missing")
    local frameworkSnapshot = ui and type(ui.GetFrameworkSnapshot) == "function" and ui:GetFrameworkSnapshot() or nil
    local nativeSafety = frameworkSnapshot and frameworkSnapshot.nativeSafety or nil
    AddCheck(report, "v3_native_write_safety", frameworkSnapshot ~= nil and (tonumber(frameworkSnapshot.version) or 0) >= 7
            and nativeSafety ~= nil and (tonumber(nativeSafety.callFailures) or 0) == 0
            and (tonumber(nativeSafety.staleRejects) or 0) == 0
            and (tonumber(nativeSafety.registrationRejects) or 0) == 0,
        "blocker", nativeSafety and ("framework=" .. tostring(frameworkSnapshot.version)
            .. "/callFail=" .. tostring(nativeSafety.callFailures or 0)
            .. "/stale=" .. tostring(nativeSafety.staleRejects or 0)
            .. "/registration=" .. tostring(nativeSafety.registrationRejects or 0)
            .. "/parentRepair=" .. tostring(nativeSafety.anchorParentRepairs or 0)) or "missing")
    AddCheck(report, "v3_native_primitive_health", nativeSafety ~= nil and (tonumber(nativeSafety.degradedRejects) or 0) == 0
            and registrySnapshot ~= nil and (tonumber(registrySnapshot.degraded) or 0) == 0,
        "warning", nativeSafety and ("degradedRejects=" .. tostring(nativeSafety.degradedRejects or 0)
            .. "/degradedPrimitives=" .. tostring(registrySnapshot and registrySnapshot.degraded or 0)) or "missing")

    if v3HostRegistered then
        local shell = S.UIV3 and S.UIV3.Shell or nil
        local windowing = S.RSUI and S.RSUI.Windowing or nil
        local controller = shell and shell.windowController or nil
        local resizeHandles = 0
        for _ in pairs(controller and controller.handles or {}) do resizeHandles = resizeHandles + 1 end
        AddCheck(report, "v3_outer_window_foundation", type(windowing) == "table" and (tonumber(windowing.version) or 0) >= 13 and type(controller) == "table"
                and controller.dragHandle ~= nil and resizeHandles == 8
                and (tonumber(windowing.IdempotentStateContractVersion) or 0) >= 1
                and (tonumber(windowing.CallbackCaptureContractVersion) or 0) >= 1
                and type(controller.SetLocked) == "function" and type(controller.SetResizeEnabled) == "function" and type(controller.IsInteracting) == "function"
                and type(controller.PulseLiveGeometry) == "function" and type(windowing.Detach) == "function"
                and S.Layout ~= nil and type(S.Layout.ResolvePlacement) == "function" and tostring(S.Layout.defaultFloatingBoundary or "") == "free" and tostring(controller.boundaryMode or "") == "free"
                and type(ui.BeginNativeGeometryLease) == "function" and type(ui.EndNativeGeometryLease) == "function",
            "blocker", "version=" .. tostring(windowing and windowing.version or "?")
                .. "/drag=" .. tostring(controller ~= nil and controller.dragHandle ~= nil)
                .. "/resizeHandles=" .. tostring(resizeHandles)
                .. "/idem=" .. tostring(windowing and windowing.IdempotentStateContractVersion or 0)
                .. "/capture=" .. tostring(windowing and windowing.CallbackCaptureContractVersion or 0)
                .. "/lock=" .. tostring(controller ~= nil and type(controller.SetLocked) == "function"))

        local design = S.UIV3Design
        AddCheck(report, "v3_exact_numeric_settings", type(design) == "table" and type(design.NumericSetting) == "function",
            "blocker", "numeric values require direct NumericInput; preset cycling buttons are forbidden")

        local genericShell = S.UI and S.UI.WindowShell or nil
        local genericShellInfo = genericShell and type(genericShell.Describe) == "function" and genericShell:Describe() or nil
        AddCheck(report, "v3_generic_window_shell", genericShellInfo ~= nil and (tonumber(genericShellInfo.version) or 0) >= 17
                and (tonumber(genericShellInfo.idempotentMutationContract) or 0) >= 1
                and (tonumber(genericShellInfo.compactMinimizeContract) or 0) >= 1
                and (tonumber(genericShellInfo.titleAppearanceContract) or 0) >= 3
                and type(S.UI.CreateWindowShell) == "function",
            "blocker", genericShellInfo and ("version=" .. tostring(genericShellInfo.version)
                .. "/idem=" .. tostring(genericShellInfo.idempotentMutationContract or 0)
                .. "/compact=" .. tostring(genericShellInfo.compactMinimizeContract or 0)
                .. "/appearance=" .. tostring(genericShellInfo.titleAppearanceContract or 0)
                .. "/fail=" .. tostring(genericShellInfo.failures or 0)) or "missing")

        local floatingSurface = S.RSUI and S.RSUI.FloatingSurface or nil
        local floatingInfo = floatingSurface and type(floatingSurface.GetSnapshot) == "function" and floatingSurface:GetSnapshot() or nil
        AddCheck(report, "v3_floating_surface_contract", floatingInfo ~= nil and (tonumber(floatingInfo.version) or 0) >= 9
                and tonumber(floatingSurface.generation) == tonumber(S.Generation)
                and (tonumber(floatingSurface.IdempotentMutationContractVersion) or 0) >= 1
                and (tonumber(floatingSurface.CompactMinimizeContractVersion) or 0) >= 1
                and (tonumber(floatingSurface.TitleAppearanceContractVersion) or 0) >= 1
                and (tonumber(floatingSurface.DetachedStateContractVersion) or 0) >= 1
                and type(floatingSurface.Create) == "function" and type(floatingSurface.NormalizeState) == "function"
                and type(floatingSurface.CreateStateAdapter) == "function",
            "blocker", floatingInfo and ("version=" .. tostring(floatingInfo.version) .. "/active=" .. tostring(floatingInfo.active or 0)
                .. "/idem=" .. tostring(floatingSurface and floatingSurface.IdempotentMutationContractVersion or 0)
                .. "/compact=" .. tostring(floatingSurface and floatingSurface.CompactMinimizeContractVersion or 0)
                .. "/appearance=" .. tostring(floatingSurface and floatingSurface.TitleAppearanceContractVersion or 0)
                .. "/detached=" .. tostring(floatingSurface and floatingSurface.DetachedStateContractVersion or 0)
                .. "/close=" .. tostring(floatingInfo.closeRequests or 0)
                .. "/veto=" .. tostring(floatingInfo.closeVetoes or 0)
                .. "/fail=" .. tostring(floatingInfo.failures or 0)) or "missing")

        local viewState = S.RSUI and S.RSUI.ViewState or nil
        local viewStateInfo = viewState and type(viewState.GetSnapshot) == "function" and viewState:GetSnapshot() or nil
        AddCheck(report, "v3_view_state_contract", viewStateInfo ~= nil and (tonumber(viewStateInfo.version) or 0) >= 2
                and tonumber(viewStateInfo.generation) == tonumber(S.Generation) and type(S.RSUI.CreateViewState) == "function",
            "blocker", viewStateInfo and ("version=" .. tostring(viewStateInfo.version) .. "/active=" .. tostring(viewStateInfo.active or 0)
                .. "/ready=" .. tostring(viewStateInfo.states and viewStateInfo.states.ready or 0)
                .. "/empty=" .. tostring(viewStateInfo.states and viewStateInfo.states.empty or 0)
                .. "/error=" .. tostring(viewStateInfo.states and viewStateInfo.states.error or 0)) or "missing")

        local actionRunner = S.ActionRunner
        local actionInfo = actionRunner and type(actionRunner.GetSnapshot) == "function" and actionRunner:GetSnapshot() or nil
        AddCheck(report, "v3_action_runner_contract", actionInfo ~= nil and (tonumber(actionInfo.version) or 0) >= 1
                and type(actionRunner.Run) == "function" and type(actionRunner.IsBusy) == "function",
            "blocker", actionInfo and ("version=" .. tostring(actionInfo.version) .. "/runs=" .. tostring(actionInfo.runs or 0)
                .. "/failed=" .. tostring(actionInfo.failed or 0) .. "/duplicate=" .. tostring(actionInfo.duplicates or 0)) or "missing")

        local binding = S.UI and S.UI.Binding or nil
        local bindingInfo = binding and type(binding.GetSnapshot) == "function" and binding:GetSnapshot() or nil
        AddCheck(report, "v3_persistent_setting_binding", bindingInfo ~= nil and (tonumber(bindingInfo.version) or 0) >= 2.3
                and type(S.UI.CreatePersistentSettingBinding) == "function",
            "blocker", bindingInfo and ("version=" .. tostring(bindingInfo.version) .. "/active=" .. tostring(bindingInfo.active or 0)
                .. "/persistent=" .. tostring(bindingInfo.persistentActive or 0) .. "/dirty=" .. tostring(bindingInfo.dirty or 0)
                .. "/error=" .. tostring(bindingInfo.errored or 0) .. "/markFail=" .. tostring(bindingInfo.persistenceFailures or 0)) or "missing")

        AddCheck(report, "legacy_window_runtime_detached", S.State == nil and S.Storage == nil
                and S.UI ~= nil and S.UI.CreateManagedWindow == nil and S.UI.AttachManagedWindow == nil and S.UI.WindowManager == nil,
            "blocker", "state=" .. tostring(S.State ~= nil) .. "/storage=" .. tostring(S.Storage ~= nil)
                .. "/managed=" .. tostring(S.UI and S.UI.CreateManagedWindow ~= nil) .. "/manager=" .. tostring(S.UI and S.UI.WindowManager ~= nil))

        local widgetHost = S.UIV3 and S.UIV3.WidgetHost or nil
        local widgetInfo = widgetHost and type(widgetHost.Describe) == "function" and widgetHost:Describe() or nil
        AddCheck(report, "v3_widget_management_contract", widgetInfo ~= nil and (tonumber(widgetInfo.version) or 0) >= 13
                and (tonumber(widgetInfo.buildTransactionContractVersion) or 0) >= 1
                and type(widgetHost.NotifyWindowClosed) == "function" and type(widgetHost.SetLocked) == "function" and type(widgetHost.SetMinimized) == "function"
                and type(widgetHost.ResetLayout) == "function" and type(widgetHost.ApplyResponsiveLayout) == "function"
                and type(widgetHost.ResetAllLayouts) == "function"
                -- Feature lifecycle bridge: Domain publishes, Presentation reacts.
                and type(widgetHost.BindFeatureLifecycle) == "function"
                and type(widgetHost.RequestClose) == "function"
                and type(widgetHost.NotifyProjectionChanged) == "function"
                and ((tonumber(widgetInfo.featureBindings) or 0) == 0 or widgetInfo.lifecycleBound == true)
                and (tonumber(widgetInfo.stats and widgetInfo.stats.lifecycleBindFailures) or 0) == 0,
            "blocker", widgetInfo and ("version=" .. tostring(widgetInfo.version) .. "/registered=" .. tostring(widgetInfo.registered or 0)
                .. "/bindings=" .. tostring(widgetInfo.featureBindings or 0)
                .. "/reactions=" .. tostring(widgetInfo.stats and widgetInfo.stats.lifecycleReactions or 0)
                .. "/bound=" .. tostring(widgetInfo.lifecycleBound == true)
                .. "/bindFail=" .. tostring(widgetInfo.stats and widgetInfo.stats.lifecycleBindFailures or 0)
                .. "/reactionFail=" .. tostring(widgetInfo.stats and widgetInfo.stats.lifecycleReactionFailures or 0)
                .. "/lockable=" .. tostring(widgetInfo.lockable or 0) .. "/resettable=" .. tostring(widgetInfo.resettable or 0)) or "missing")

        local modalHost = S.UIV3 and S.UIV3.ModalHost or nil
        local modalInfo = modalHost and type(modalHost.Describe) == "function" and modalHost:Describe() or nil
        AddCheck(report, "v3_modal_host_contract", modalInfo ~= nil and (tonumber(modalInfo.version) or 0) >= 5
                and (tonumber(modalInfo.buildTransactionContractVersion) or 0) >= 1
                and modalInfo.attached == true and type(modalHost.GetContentRoot) == "function"
                and type(modalHost.DismissTop) == "function" and type(modalHost.EnsureApplicationVisible) == "function",
            "blocker", modalInfo and ("version=" .. tostring(modalInfo.version) .. "/attached=" .. tostring(modalInfo.attached)
                .. "/count=" .. tostring(modalInfo.count or 0) .. "/wakeFail=" .. tostring(modalInfo.hostWakeFailures or 0)) or "missing")

        local toastHost = S.UIV3 and S.UIV3.ToastHost or nil
        local toastInfo = toastHost and type(toastHost.Describe) == "function" and toastHost:Describe() or nil
        AddCheck(report, "v3_toast_host_contract", toastInfo ~= nil and (tonumber(toastInfo.version) or 0) >= 1
                and toastInfo.attached == true and tonumber(toastInfo.maxVisible) == 3
                and type(toastHost.Notify) == "function" and type(toastHost.Dismiss) == "function",
            "blocker", toastInfo and ("version=" .. tostring(toastInfo.version) .. "/attached=" .. tostring(toastInfo.attached)
                .. "/visible=" .. tostring(toastInfo.visible or 0) .. "/pending=" .. tostring(toastInfo.active or 0)) or "missing")

        local scheduler = S.Scheduler
        local schedulerHealth = scheduler and type(scheduler.GetHealth) == "function" and scheduler:GetHealth() or nil
        AddCheck(report, "v3_bounded_delayed_work", type(scheduler) == "table" and type(scheduler.AddOneShot) == "function",
            "blocker", "shared one-shot scheduler required")
        AddCheck(report, "v3_interactive_scheduler_contract", type(scheduler) == "table" and (tonumber(scheduler.version) or 0) >= 3
                and type(scheduler.AddInteractiveTask) == "function" and type(scheduler.RemoveTask) == "function"
                and type(scheduler.SetTaskModule) == "function" and schedulerHealth ~= nil,
            "blocker", schedulerHealth and ("version=" .. tostring(schedulerHealth.version or 0)
                .. "/tasks=" .. tostring(schedulerHealth.activeTasks or 0)
                .. "/modules=" .. tostring(schedulerHealth.moduleMappings or 0)
                .. "/transient=" .. tostring(schedulerHealth.transientMappings or 0))
                or "background >=50ms; finite interactive gestures may borrow >=16ms")
        AddCheck(report, "v3_scheduler_metadata_health", schedulerHealth ~= nil
                and (tonumber(schedulerHealth.transientOrphans) or 0) == 0,
            "warning", schedulerHealth and ("transient=" .. tostring(schedulerHealth.transientMappings or 0)
                .. "/orphan=" .. tostring(schedulerHealth.transientOrphans or 0)) or "missing")

        local eventBus = S.Events
        local eventHealth = eventBus and type(eventBus.GetHealth) == "function" and eventBus:GetHealth() or nil
        AddCheck(report, "v3_event_bus_contract", type(eventBus) == "table" and (tonumber(eventBus.version) or 0) >= 4
                and type(eventBus.Subscribe) == "function" and type(eventBus.SubscribeOptional) == "function" and type(eventBus.SubscribeInternal) == "function"
                and type(eventBus.GetHealth) == "function" and eventHealth ~= nil,
            "blocker", eventHealth and ("version=" .. tostring(eventHealth.version or 0)
                .. "/native=" .. tostring(eventHealth.nativeListeners or 0)
                .. "/registered=" .. tostring(eventHealth.registered or 0)
                .. "/parked=" .. tostring(eventHealth.parkedRegistrations or 0)
                .. "/internal=" .. tostring(eventHealth.internalListeners or 0)) or "missing")
        AddCheck(report, "v3_event_bus_runtime_health", eventHealth ~= nil
                and (tonumber(eventHealth.startFailures) or 0) == 0
                and (tonumber(eventHealth.subscribeFailures) or 0) == 0
                and (tonumber(eventHealth.registerFailures) or 0) == 0
                and (tonumber(eventHealth.unregisterFailures) or 0) == 0,
            "warning", eventHealth and ("startFail=" .. tostring(eventHealth.startFailures or 0)
                .. "/subFail=" .. tostring(eventHealth.subscribeFailures or 0)
                .. "/registerFail=" .. tostring(eventHealth.registerFailures or 0)
                .. "/unregisterFail=" .. tostring(eventHealth.unregisterFailures or 0)
                .. "/parked=" .. tostring(eventHealth.parkedRegistrations or 0)
                .. "/nativeUnreg=" .. tostring(eventHealth.nativeUnregisterSupported)) or "missing")
        AddCheck(report, "v3_event_release_contract", eventHealth ~= nil
                and (tonumber(eventHealth.version) or 0) >= 4
                and eventHealth.parkedRegistrations ~= nil and eventHealth.unregisterSkipped ~= nil
                and (tonumber(eventHealth.ownerReleaseContractVersion) or 0) >= 1
                and (tonumber(eventHealth.unregisterFailures) or 0) == 0,
            "blocker", eventHealth and ("parked=" .. tostring(eventHealth.parkedRegistrations or 0)
                .. "/skipped=" .. tostring(eventHealth.unregisterSkipped or 0)
                .. "/nativeUnreg=" .. tostring(eventHealth.nativeUnregisterSupported)
                .. "/ownerRelease=" .. tostring(eventHealth.ownerReleaseContractVersion or 0)
                .. "/realFail=" .. tostring(eventHealth.unregisterFailures or 0)) or "missing")

        local rsui = S.RSUI
        local scrollbar = rsui and rsui.ScrollbarBehavior or nil
        AddCheck(report, "v3_advanced_ui_contract", type(rsui) == "table" and (tonumber(rsui.version) or 0) >= 24
                and type(rsui.SplitView) == "function" and type(rsui.types) == "table" and rsui.types["SplitView"] ~= nil
                and type(rsui.SplitViewPolicy) == "table" and type(rsui.SplitViewPolicy.Resolve) == "function"
                and type(scrollbar) == "table" and (tonumber(scrollbar.version) or 0) >= 2 and type(scrollbar.ComputeGeometry) == "function",
            "blocker", "RSUI v24 + BuildTransaction/Preflight + wrapped text + public factory API + SplitView + shared ScrollbarBehavior required")
        local uiAdapter = S.UI
        local selectionType = rsui and rsui.SelectionModel or nil
        AddCheck(report, "v3_ui_adapter_selection_contract", type(uiAdapter) == "table"
                and type(uiAdapter.TrySetUILayer) == "function"
                and type(selectionType) == "table" and type(selectionType.GetPrimaryKey) == "function"
                and (tonumber(rsui.DataViewSelectionContractVersion) or 0) >= 2
                and (tonumber(rsui.DropdownContractVersion) or 0) >= 2,
            "blocker", "adapterLayer=" .. tostring(type(uiAdapter) == "table" and type(uiAdapter.TrySetUILayer) == "function")
                .. "/selection=" .. tostring(type(selectionType) == "table" and type(selectionType.GetPrimaryKey) == "function")
                .. "/viewContract=" .. tostring(rsui and rsui.DataViewSelectionContractVersion or 0)
                .. "/dropdown=" .. tostring(rsui and rsui.DropdownContractVersion or 0))
        local navigationShell = S.UIV3 and S.UIV3.Shell or nil
        AddCheck(report, "v3_lua51_callback_capture_contract", type(windowing) == "table"
                and (tonumber(windowing.CallbackCaptureContractVersion) or 0) >= 1
                and type(rsui) == "table" and (tonumber(rsui.DataViewCallbackCaptureContractVersion) or 0) >= 1
                and type(navigationShell) == "table" and (tonumber(navigationShell.NavigationCallbackCaptureContractVersion) or 0) >= 1
                and (tonumber(rsui.DropdownContractVersion) or 0) >= 2,
            "blocker", "window=" .. tostring(windowing and windowing.CallbackCaptureContractVersion or 0)
                .. "/data=" .. tostring(rsui and rsui.DataViewCallbackCaptureContractVersion or 0)
                .. "/nav=" .. tostring(navigationShell and navigationShell.NavigationCallbackCaptureContractVersion or 0)
                .. "/dropdown=" .. tostring(rsui and rsui.DropdownContractVersion or 0))
        local missingPublicFactories = {}
        if type(rsui) == "table" and type(rsui.types) == "table" then
            for typeName, factory in pairs(rsui.types) do
                if type(factory) == "function" and type(rsui[typeName]) ~= "function" then missingPublicFactories[#missingPublicFactories + 1] = tostring(typeName) end
            end
            table.sort(missingPublicFactories)
        end
        AddCheck(report, "v3_rsui_public_factory_contract", type(rsui) == "table"
                and type(rsui.TextInput) == "function" and #missingPublicFactories == 0,
            "blocker", "textInput=" .. tostring(type(rsui) == "table" and type(rsui.TextInput) == "function")
                .. "/missing=" .. tostring(#missingPublicFactories)
                .. (#missingPublicFactories > 0 and ("[" .. Join(missingPublicFactories, 6) .. "]") or ""))
        AddCheck(report, "v3_rsui_strict_build_scope_contract", type(rsui) == "table"
                and (tonumber(rsui.BuildScopeContractVersion) or 0) >= 3
                and (tonumber(rsui.BuildTransactionContractVersion) or 0) >= 1
                and (tonumber(rsui.PreflightContractVersion) or 0) >= 1
                and (tonumber(rsui.LogicalIdGenerationFenceVersion) or 0) >= 1
                and type(rsui.BeginBuildScope) == "function" and type(rsui.EndBuildScope) == "function"
                and type(rsui.WithBuildScope) == "function" and type(rsui.ValidateSpec) == "function"
                and type(rsui.RegisterTypeValidator) == "function",
            "blocker", "buildScope=" .. tostring(rsui and rsui.BuildScopeContractVersion or 0)
                .. "/tx=" .. tostring(rsui and rsui.BuildTransactionContractVersion or 0)
                .. "/preflight=" .. tostring(rsui and rsui.PreflightContractVersion or 0)
                .. "/logicalFence=" .. tostring(rsui and rsui.LogicalIdGenerationFenceVersion or 0)
                .. "/begin=" .. tostring(type(rsui) == "table" and type(rsui.BeginBuildScope) == "function")
                .. "/wrapper=" .. tostring(type(rsui) == "table" and type(rsui.WithBuildScope) == "function"))
        local preflightValidators = rsui and rsui.typeValidators or nil
        AddCheck(report, "v3_rsui_preflight_contract", type(preflightValidators) == "table"
                and type(preflightValidators.TableView) == "function"
                and type(preflightValidators.Table) == "function"
                and type(preflightValidators.SegmentedSelector) == "function"
                and type(preflightValidators.NumericField) == "function",
            "blocker", "table=" .. tostring(type(preflightValidators) == "table" and type(preflightValidators.TableView) == "function")
                .. "/tableAlias=" .. tostring(type(preflightValidators) == "table" and type(preflightValidators.Table) == "function")
                .. "/segment=" .. tostring(type(preflightValidators) == "table" and type(preflightValidators.SegmentedSelector) == "function")
                .. "/numeric=" .. tostring(type(preflightValidators) == "table" and type(preflightValidators.NumericField) == "function"))
        local textLayout = rsui and rsui.TextLayout or nil
        local designContract = S.UIV3Design
        AddCheck(report, "v3_typography_form_layout_contract", type(S.Theme) == "table" and type(S.Theme.ResolveFontSize) == "function"
                and type(textLayout) == "table" and (tonumber(textLayout.version) or 0) >= 3
                and (tonumber(rsui.FormLayoutContractVersion) or 0) >= 2
                and (tonumber(rsui.NumericInlineContractVersion) or 0) >= 3
                and (tonumber(rsui.WidgetSwitcherContractVersion) or 0) >= 2
                and type(designContract) == "table" and (tonumber(designContract.version) or 0) >= 6
                and type(designContract.CompactNumericSetting) == "function",
            "blocker", "text=" .. tostring(textLayout and textLayout.version or 0)
                .. "/form=" .. tostring(rsui and rsui.FormLayoutContractVersion or 0)
                .. "/numericInline=" .. tostring(rsui and rsui.NumericInlineContractVersion or 0)
                .. "/switch=" .. tostring(rsui and rsui.WidgetSwitcherContractVersion or 0)
                .. "/design=" .. tostring(designContract and designContract.version or 0))
        local tooltipService = rsui and rsui.Tooltip or nil
        AddCheck(report, "v3_floating_text_layout_contract", type(rsui) == "table"
                and (tonumber(rsui.WrappedTextContractVersion) or 0) >= 2
                and type(rsui.NormalizeWrappedTextSizing) == "function"
                and genericShellInfo ~= nil and (tonumber(genericShellInfo.version) or 0) >= 15
                and floatingInfo ~= nil and (tonumber(floatingInfo.version) or 0) >= 7
                and type(floatingSurface.GetSnapshot) == "function"
                and type(tooltipService) == "table" and (tonumber(tooltipService.version) or 0) >= 3,
            "blocker", "wrapped=" .. tostring(rsui and rsui.WrappedTextContractVersion or 0)
                .. "/shell=" .. tostring(genericShellInfo and genericShellInfo.version or 0)
                .. "/floating=" .. tostring(floatingInfo and floatingInfo.version or 0)
                .. "/tooltip=" .. tostring(tooltipService and tooltipService.version or 0))
        AddCheck(report, "v3_floating_shell_appearance_contract", type(rsui) == "table"
                and (tonumber(rsui.version) or 0) >= 23
                and (tonumber(rsui.FloatingFontScaleContractVersion) or 0) >= 1
                and type(rsui.ApplyFontScale) == "function"
                and genericShellInfo ~= nil and (tonumber(genericShellInfo.version) or 0) >= 15
                and floatingInfo ~= nil and (tonumber(floatingInfo.version) or 0) >= 7
                and widgetInfo ~= nil and (tonumber(widgetInfo.version) or 0) >= 12
                and type(widgetHost.SetFontScale) == "function",
            "blocker", "rsui=" .. tostring(rsui and rsui.version or 0)
                .. "/font=" .. tostring(rsui and rsui.FloatingFontScaleContractVersion or 0)
                .. "/shell=" .. tostring(genericShellInfo and genericShellInfo.version or 0)
                .. "/floating=" .. tostring(floatingInfo and floatingInfo.version or 0)
                .. "/widget=" .. tostring(widgetInfo and widgetInfo.version or 0))
        local floatingAppearanceIds = { "life.activities", "life.tasks", "combat.death_review", "combat.dps" }
        local floatingAppearanceMissing = {}
        if type(widgetHost) == "table" and type(widgetHost.GetSpec) == "function" then
            for _, widgetId in ipairs(floatingAppearanceIds) do
                local spec = widgetHost:GetSpec(widgetId)
                if type(spec) ~= "table" or spec.fontScaleAdjustable ~= true
                        or type(spec.getFontScale) ~= "function" or type(spec.setFontScale) ~= "function" then
                    floatingAppearanceMissing[#floatingAppearanceMissing + 1] = widgetId
                end
            end
        else
            floatingAppearanceMissing = floatingAppearanceIds
        end
        AddCheck(report, "v3_floating_appearance_parity", #floatingAppearanceMissing == 0,
            "blocker", "missing=" .. tostring(#floatingAppearanceMissing)
                .. (#floatingAppearanceMissing > 0 and ("[" .. Join(floatingAppearanceMissing, 4) .. "]") or ""))

        AddCheck(report, "v3_compact_selector_contract", type(rsui) == "table"
                and (tonumber(rsui.version) or 0) >= 20
                and (tonumber(rsui.SegmentedSelectorContractVersion) or 0) >= 1
                and type(rsui.SegmentedSelector) == "function",
            "blocker", "rsui=" .. tostring(rsui and rsui.version or 0)
                .. "/segmented=" .. tostring(rsui and rsui.SegmentedSelectorContractVersion or 0)
                .. "/factory=" .. tostring(type(rsui) == "table" and type(rsui.SegmentedSelector) == "function"))
        AddCheck(report, "v3_floating_interaction_contract", type(rsui) == "table"
                and (tonumber(rsui.DataViewViewportContractVersion) or 0) >= 2
                and (tonumber(rsui.DataViewOverlayScrollbarContractVersion) or 0) >= 1
                and genericShellInfo ~= nil and (tonumber(genericShellInfo.version) or 0) >= 17
                and floatingInfo ~= nil and (tonumber(floatingInfo.version) or 0) >= 7
                and modalInfo ~= nil and (tonumber(modalInfo.version) or 0) >= 4
                and type(modalHost.EnsureApplicationVisible) == "function",
            "blocker", "viewport=" .. tostring(rsui and rsui.DataViewViewportContractVersion or 0)
                .. "/overlayScroll=" .. tostring(rsui and rsui.DataViewOverlayScrollbarContractVersion or 0)
                .. "/shell=" .. tostring(genericShellInfo and genericShellInfo.version or 0)
                .. "/floating=" .. tostring(floatingInfo and floatingInfo.version or 0)
                .. "/modal=" .. tostring(modalInfo and modalInfo.version or 0))
        local rsuiInfo = type(rsui.GetSnapshot) == "function" and rsui:GetSnapshot() or nil
        local pageInfo = S.UIV3 and S.UIV3.PageHost and type(S.UIV3.PageHost.Describe) == "function" and S.UIV3.PageHost:Describe() or nil
        local businessPagesContract = S.UIV3 and S.UIV3.BusinessPagesContract or nil
        AddCheck(report, "v3_build_transaction_contract", rsuiInfo ~= nil and type(rsui.WithBuildScope) == "function"
                and type(rsui.TrackBuildWidget) == "function"
                and (tonumber(rsui.StrictBuildFailFastContractVersion) or 0) >= 1
                and type(businessPagesContract) == "table" and (tonumber(businessPagesContract.componentIdContractVersion) or 0) >= 1
                and (tonumber(rsuiInfo.activeBuildScopes) or 0) == 0
                and (tonumber(rsuiInfo.buildScopeCloseOrderRecoveries) or 0) == 0
                and (tonumber(rsuiInfo.buildScopeCleanupFailures) or 0) == 0
                and (tonumber(rsuiInfo.buildTransactionFailures) or 0) == 0
                and (tonumber(rsuiInfo.preflightFailures) or 0) == 0
                and pageInfo ~= nil and (tonumber(pageInfo.version) or 0) >= 4
                and (tonumber(pageInfo.buildTransactionContractVersion) or 0) >= 1 and (tonumber(pageInfo.quarantined) or 0) == 0
                and widgetInfo ~= nil and (tonumber(widgetInfo.version) or 0) >= 13
                and (tonumber(widgetInfo.buildTransactionContractVersion) or 0) >= 1 and (tonumber(widgetInfo.quarantined) or 0) == 0,
            "blocker", rsuiInfo and ("scope=" .. tostring(rsuiInfo.activeBuildScopes or 0)
                .. "/rollback=" .. tostring(rsuiInfo.buildScopesRolledBack or 0)
                .. "/closeRecover=" .. tostring(rsuiInfo.buildScopeCloseOrderRecoveries or 0)
                .. "/cleanupFail=" .. tostring(rsuiInfo.buildScopeCleanupFailures or 0)
                .. "/txFail=" .. tostring(rsuiInfo.buildTransactionFailures or 0)
                .. "/preflightFail=" .. tostring(rsuiInfo.preflightFailures or 0)
                .. "/failFastCount=" .. tostring(rsuiInfo.strictBuildFailFast or 0)
                .. "/pageQ=" .. tostring(pageInfo and pageInfo.quarantined or 0)
                .. "/widgetQ=" .. tostring(widgetInfo and widgetInfo.quarantined or 0)
                .. "/failFast=" .. tostring(rsui and rsui.StrictBuildFailFastContractVersion or 0)
                .. "/businessIds=" .. tostring(businessPagesContract and businessPagesContract.componentIdContractVersion or 0)) or "missing")

        local nativeAdapter = S.UIV3NativeAdapter
        local adapterInfo = nativeAdapter and type(nativeAdapter.Describe) == "function" and nativeAdapter:Describe() or nil
        AddCheck(report, "v3_native_root_policy", adapterInfo ~= nil and (tonumber(adapterInfo.version) or 0) >= 3
                and (tonumber(adapterInfo.rootsCreated) or 0) >= 1
                and (tonumber(adapterInfo.nativeEscapeCloseDisabled) or 0) >= 1,
            "blocker", adapterInfo and ("version=" .. tostring(adapterInfo.version) .. "/roots=" .. tostring(adapterInfo.rootsCreated)
                .. "/escapeFence=" .. tostring(adapterInfo.nativeEscapeCloseDisabled)) or "missing")

        local design = S.UIV3Design
        AddCheck(report, "v3_scrollable_page_contract", type(design) == "table" and (tonumber(design.version) or 0) >= 4 and type(design.ScrollablePageRoot) == "function",
            "blocker", "Design v4: page roots accept id/spec and settings/forms can scroll at minimum viewport")

        local navEntries = shell and shell.navScroll and shell.navScroll.GetScrollableEntries and shell.navScroll:GetScrollableEntries() or {}
        AddCheck(report, "v3_navigation_critical_access", shell ~= nil and shell.navScroll ~= nil and #navEntries >= 12
                and (tonumber(shell.NavigationCallbackCaptureContractVersion) or 0) >= 1
                and shell.navButtons ~= nil and shell.navButtons["system.settings"] ~= nil
                and shell.navButtons["system.diagnostics"] ~= nil and shell.reloadButton ~= nil,
            "blocker", "entries=" .. tostring(#navEntries) .. "/capture=" .. tostring(shell and shell.NavigationCallbackCaptureContractVersion or 0)
                .. "/settings=" .. tostring(shell and shell.navButtons and shell.navButtons["system.settings"] ~= nil)
                .. "/diagnostics=" .. tostring(shell and shell.navButtons and shell.navButtons["system.diagnostics"] ~= nil)
                .. "/reload=" .. tostring(shell and shell.reloadButton ~= nil))

        local pageHost = S.UIV3 and S.UIV3.PageHost or nil
        AddCheck(report, "v3_combat_navigation_contract", shell ~= nil and shell.navButtons ~= nil
                and shell.navButtons["combat.stats"] ~= nil and shell.navButtons["combat.analytics"] ~= nil
                and pageHost ~= nil and type(pageHost.factories) == "table"
                and type(pageHost.factories["combat.stats"]) == "function"
                and type(pageHost.factories["combat.analytics"]) == "function"
                and S.UIV3Acceptance ~= nil and (tonumber(S.UIV3Acceptance.version) or 0) >= 34,
            "blocker", "dpsButton=" .. tostring(shell and shell.navButtons and shell.navButtons["combat.stats"] ~= nil)
                .. "/analyticsButton=" .. tostring(shell and shell.navButtons and shell.navButtons["combat.analytics"] ~= nil)
                .. "/dpsFactory=" .. tostring(pageHost and pageHost.factories and type(pageHost.factories["combat.stats"]) == "function")
                .. "/analyticsFactory=" .. tostring(pageHost and pageHost.factories and type(pageHost.factories["combat.analytics"]) == "function"))
        AddCheck(report, "v3_reload_authority", type(S.ReloadCodeFromDisk) == "function"
                and S.Persistence ~= nil and type(S.Persistence.Flush) == "function",
            "blocker", "reload=" .. tostring(type(S.ReloadCodeFromDisk) == "function")
                .. "/flush=" .. tostring(S.Persistence ~= nil and type(S.Persistence.Flush) == "function"))

        local appState = S.AppState and type(S.AppState.Describe) == "function" and S.AppState:Describe() or nil
        AddCheck(report, "v3_app_ui_settings", appState ~= nil and appState.loaded == true
                and tonumber(appState.addonScale) ~= nil and tonumber(appState.fontScale) ~= nil
                and S.Layout ~= nil and type(S.Layout.RefreshNow) == "function",
            "blocker", appState and ("scale=" .. tostring(appState.addonScale) .. "/font=" .. tostring(appState.fontScale) .. "/appearance=" .. tostring(appState.appearance)) or "missing")

        local featureRuntime = S.FeatureRuntime and type(S.FeatureRuntime.Describe) == "function" and S.FeatureRuntime:Describe() or nil
        local featureStore = S.Persistence and type(S.Persistence.GetStore) == "function" and S.Persistence:GetStore("v3.features") or nil
        AddCheck(report, "v3_feature_preferences", featureRuntime ~= nil and featureRuntime.preferencesLoaded == true and featureStore ~= nil,
            "blocker", featureRuntime and ("loaded=" .. tostring(featureRuntime.preferencesLoaded) .. "/explicit=" .. tostring(featureRuntime.explicitPreferences or 0)) or "missing")

        local demand = S.Demand and type(S.Demand.Describe) == "function" and S.Demand:Describe() or nil
        AddCheck(report, "v3_demand_hardening_contract", S.Demand ~= nil and (tonumber(S.Demand.version) or 0) >= 2
                and type(S.Demand.Create) == "function" and type(S.Demand.ClearAll) == "function"
                and demand ~= nil and demand.quiesceFailures ~= nil,
            "blocker", demand and ("version=" .. tostring(demand.version) .. "/leases=" .. tostring(demand.leases or 0)
                .. "/quiesceFail=" .. tostring(demand.quiesceFailures or 0)) or "missing")
    end

    local unitIdentity = S.Services and S.Services.UnitIdentityV3 or nil
    local unitIdentityHealth = unitIdentity and type(unitIdentity.GetHealth) == "function" and unitIdentity:GetHealth() or nil
    AddCheck(report, "combat_unit_identity_contract", unitIdentity ~= nil and (tonumber(unitIdentity.version) or 0) >= 1
            and type(unitIdentity.ResolveCombatEndpoint) == "function" and type(unitIdentity.GetById) == "function"
            and type(unitIdentity.ParseExplicitKind) == "function" and unitIdentityHealth ~= nil,
        "blocker", unitIdentityHealth and ("cache=" .. tostring(unitIdentityHealth.cache or 0)
            .. "/bind=" .. tostring(unitIdentityHealth.endpointBinds or 0)
            .. "/ambiguous=" .. tostring(unitIdentityHealth.endpointAmbiguous or 0)) or "missing")

    local combatBus = S.Services and S.Services.CombatEventBusV3 or nil
    local combatHealth = combatBus and type(combatBus.GetHealth) == "function" and combatBus:GetHealth() or nil
    local combatCapsRegistered = true
    for _, capability in ipairs({ "X2Unit:GetUnitNameById", "X2Unit:GetUnitInfoById", "UI:SetEventHandler", "UI:ReleaseEventHandler", "UIParent:SetEventHandler", "UIParent:ReleaseEventHandler" }) do
        if S.ApiCapabilities == nil or S.ApiCapabilities:Get(capability) == nil then combatCapsRegistered = false; break end
    end
    AddCheck(report, "combat_event_bus_contract", combatBus ~= nil and (tonumber(combatBus.version) or 0) >= 6
            and type(combatBus.Subscribe) == "function" and type(combatBus.Unsubscribe) == "function"
            and type(combatBus.DescribeEventType) == "function" and type(combatBus.ParseAmount) == "function"
            and type(combatBus.GetCoverageState) == "function" and type(combatBus.GetHealth) == "function"
            and combatBus.demand ~= nil and combatCapsRegistered == true,
        "blocker", combatHealth and ("version=" .. tostring(combatHealth.version or 0)
            .. "/consumer=" .. tostring(combatHealth.consumers or 0)
            .. "/scope=" .. tostring(combatHealth.scope or "none")
            .. "/coverage=" .. tostring(combatHealth.coverageState or "?")
            .. "/global=" .. tostring(combatHealth.globalHosts or 0)
            .. "/caps=" .. tostring(combatCapsRegistered)) or "missing")
    -- Release compatibility must be observable, never silent: "API missing"
    -- (parked host) and "API exists but call failed" are different outcomes and
    -- only the second one is allowed to report a real transaction failure.
    AddCheck(report, "combat_event_bus_release_contract", combatBus ~= nil
            and type(combatBus._MarkInert) == "function"
            and combatHealth ~= nil and combatHealth.releaseApiMissing ~= nil
            and combatHealth.releaseCallFailures ~= nil and combatHealth.forcedInert ~= nil,
        "blocker", combatHealth and ("apiMissing=" .. tostring(combatHealth.releaseApiMissing or 0)
            .. "/callFail=" .. tostring(combatHealth.releaseCallFailures or 0)
            .. "/stopFail=" .. tostring(combatHealth.stopFailures or 0)
            .. "/forcedInert=" .. tostring(combatHealth.forcedInert or 0)
            .. "/parkedPrivate=" .. tostring(combatHealth.privateParked == true)
            .. "/parkedGlobal=" .. tostring(combatHealth.globalParkedHosts or 0)) or "missing")
    AddCheck(report, "combat_event_bus_runtime_health", combatHealth ~= nil
            and (tonumber(combatHealth.callbackErrors) or 0) == 0
            and (tonumber(combatHealth.factMutationErrors) or 0) == 0
            and (tonumber(combatHealth.startFailures) or 0) == 0,
        "warning", combatHealth and ("callbackErr=" .. tostring(combatHealth.callbackErrors or 0)
            .. "/mutationErr=" .. tostring(combatHealth.factMutationErrors or 0)
            .. "/startFail=" .. tostring(combatHealth.startFailures or 0)
            .. "/scopeFiltered=" .. tostring(combatHealth.scopeFiltered or 0)
            .. "/unknown=" .. tostring(combatHealth.unknownKinds or 0)) or "missing")
    AddCheck(report, "combat_event_bus_coverage_health", combatHealth ~= nil
            and (combatHealth.globalActive ~= true or tostring(combatHealth.coverageState or "") ~= "UNAVAILABLE"),
        "warning", combatHealth and ("coverage=" .. tostring(combatHealth.coverageState or "?")
            .. "/hosts=" .. tostring(combatHealth.globalHosts or 0)
            .. "/journal=" .. tostring(combatHealth.journalPending or 0)
            .. "/replay=" .. tostring(combatHealth.journalReplayed or 0)
            .. "/drop=" .. tostring(combatHealth.journalDropped or 0)) or "missing")

    local analytics = S.Services and S.Services.CombatAnalyticsV3 or nil
    local analyticsHealth = analytics and type(analytics.GetHealth) == "function" and analytics:GetHealth() or nil
    local abilityCatalog = S.Data and S.Data.CombatAbilityCatalog or nil
    local abilityHealth = abilityCatalog and type(abilityCatalog.GetHealth) == "function" and abilityCatalog:GetHealth() or nil
    local mechanicCatalog = S.Data and S.Data.CombatMechanicCatalog or nil
    local analyticsStore = S.Persistence and type(S.Persistence.GetStore) == "function" and S.Persistence:GetStore("v3.combat_analytics") or nil
    local analyticsMeta = S.FeatureRegistry and S.FeatureRegistry:Get("combat_analytics") or nil
    local analyticsPage = S.UIV3 and S.UIV3.PageHost and S.UIV3.PageHost.factories and S.UIV3.PageHost.factories["combat.analytics"] or nil
    AddCheck(report, "combat_analytics_contract", analytics ~= nil and (tonumber(analytics.version) or 0) >= 3
            and type(analytics.RegisterMetric) == "function" and type(analytics.AcquireConsumer) == "function"
            and type(analytics.ResetMetrics) == "function" and type(analytics.HasConsumer) == "function"
            and type(analytics.NotifyMetricChanged) == "function"
            and type(analytics.ReleaseConsumer) == "function" and type(analytics.GetMetricProjection) == "function"
            and type(analytics.GetMetricActorDetail) == "function"
            and analytics.Demand ~= nil and analyticsHealth ~= nil and (tonumber(analyticsHealth.registeredMetrics) or 0) >= 9
            and analyticsStore ~= nil and analyticsMeta ~= nil and analyticsPage ~= nil,
        "blocker", analyticsHealth and ("version=" .. tostring(analyticsHealth.version or 0)
            .. "/registered=" .. tostring(analyticsHealth.registeredMetrics or 0)
            .. "/active=" .. tostring(analyticsHealth.activeMetrics or 0)
            .. "/consumer=" .. tostring(analyticsHealth.consumers or 0)) or "missing")
    AddCheck(report, "combat_analytics_catalogs", abilityHealth ~= nil and (tonumber(abilityHealth.skills) or 0) >= 100
            and (tonumber(abilityHealth.songs) or 0) >= 4 and mechanicCatalog ~= nil
            and type(mechanicCatalog.FindCast) == "function" and type(mechanicCatalog.FindDebuff) == "function",
        "blocker", abilityHealth and ("skills=" .. tostring(abilityHealth.skills or 0)
            .. "/control=" .. tostring(abilityHealth.control or 0)
            .. "/utility=" .. tostring(abilityHealth.utility or 0)
            .. "/songs=" .. tostring(abilityHealth.songs or 0)) or "missing")
    local skillMetadata = S.Services and S.Services.SkillMetadataV3 or nil
    local skillMetadataHealth = type(skillMetadata) == "table" and type(skillMetadata.GetHealth) == "function" and skillMetadata:GetHealth() or nil
    AddCheck(report, "skill_metadata_v3_contract", type(skillMetadata) == "table" and (tonumber(skillMetadata.version) or 0) >= 1
            and type(skillMetadata.GetSkillInfo) == "function" and skillMetadataHealth ~= nil
            and (tonumber(skillMetadataHealth.cacheMax) or 0) >= 128 and (tonumber(skillMetadataHealth.cacheMax) or 0) <= 1024,
        "blocker", skillMetadataHealth and ("version=" .. tostring(skillMetadataHealth.version or 0)
            .. "/cache=" .. tostring(skillMetadataHealth.cacheCount or 0) .. "/" .. tostring(skillMetadataHealth.cacheMax or 0)
            .. "/lookups=" .. tostring(skillMetadataHealth.nativeLookups or 0)) or "missing")
    AddCheck(report, "combat_analytics_runtime_health", analyticsHealth ~= nil
            and (tonumber(analyticsHealth.metricErrors) or 0) == 0
            and (tonumber(analyticsHealth.metricMutations) or 0) == 0
            and (tonumber(analyticsHealth.emptyConsumers) or 0) == 0,
        "warning", analyticsHealth and ("errors=" .. tostring(analyticsHealth.metricErrors or 0)
            .. "/mutations=" .. tostring(analyticsHealth.metricMutations or 0)
            .. "/emptyConsumers=" .. tostring(analyticsHealth.emptyConsumers or 0)
            .. "/facts=" .. tostring(analyticsHealth.factsReceived or 0)
            .. "/damagePlan=" .. tostring(analyticsHealth.damageDispatchMetrics or 0)
            .. "/auraPlan=" .. tostring(analyticsHealth.auraDispatchMetrics or 0)) or "missing")

    local teamRoster = S.Services and S.Services.TeamRosterV3 or nil
    local teamHealth = teamRoster and type(teamRoster.GetHealth) == "function" and teamRoster:GetHealth() or nil
    AddCheck(report, "combat_team_roster_contract", teamRoster ~= nil and (tonumber(teamRoster.version) or 0) >= 4
            and type(teamRoster.AcquireConsumer) == "function" and type(teamRoster.ReleaseConsumer) == "function"
            and type(teamRoster.GetSnapshot) == "function" and teamRoster.demand ~= nil and teamHealth ~= nil,
        "blocker", teamHealth and ("version=" .. tostring(teamHealth.version or 0)
            .. "/consumer=" .. tostring(teamHealth.consumers or 0)
            .. "/members=" .. tostring(teamHealth.members or 0)
            .. "/subscribed=" .. tostring(teamHealth.subscribed == true)) or "missing")

    local auraObservation = S.Services and S.Services.AuraObservationV3 or nil
    local auraHealth = auraObservation and type(auraObservation.GetHealth) == "function" and auraObservation:GetHealth() or nil
    AddCheck(report, "aura_observation_phase12b_contract", auraObservation ~= nil and (tonumber(auraObservation.version) or 0) >= 2
            and type(auraObservation.AcquireConsumer) == "function" and type(auraObservation.ReleaseConsumer) == "function"
            and type(auraObservation.GetSnapshot) == "function" and type(auraObservation.GetStatusMap) == "function"
            and type(auraObservation.EvaluateRequiredEffects) == "function" and auraObservation.Demand ~= nil and auraHealth ~= nil,
        "blocker", auraHealth and ("version=" .. tostring(auraObservation.version or 0)
            .. "/consumer=" .. tostring(auraHealth.consumers or 0)
            .. "/cache=" .. tostring(auraHealth.cache or 0)
            .. "/native=" .. tostring(auraHealth.nativeReads or 0)) or "missing")

    local buffDisplay = S.Features and S.Features.BuffDisplay or nil
    local buffDisplayHealth = type(buffDisplay) == "table" and type(buffDisplay.GetHealth) == "function" and buffDisplay:GetHealth() or nil
    local buffDisplayMeta = S.FeatureRegistry and S.FeatureRegistry:Get("combat_buff_display") or nil
    local buffDisplayStore = S.Persistence and type(S.Persistence.GetStore) == "function" and S.Persistence:GetStore("v3.buff_display") or nil
    local buffDisplayPageHost = S.UIV3 and S.UIV3.PageHost or nil
    local buffDisplayWidgetHost = S.UIV3 and S.UIV3.WidgetHost or nil
    local buffDisplayPage = type(buffDisplayPageHost) == "table" and type(buffDisplayPageHost.factories) == "table"
        and buffDisplayPageHost.factories["combat.buff_display"] or nil
    local buffDisplayWidget = type(buffDisplayWidgetHost) == "table" and type(buffDisplayWidgetHost.GetSpec) == "function"
        and buffDisplayWidgetHost:GetSpec("combat.buff_display") or nil
    AddCheck(report, "buff_display_v3_statusmap_contract", buffDisplay ~= nil and S.FeatureRuntime ~= nil
            and S.FeatureRuntime:IsImplemented("combat_buff_display") == true
            and type(buffDisplay.ProjectStatusMap) == "function" and type(buffDisplay.GetProjection) == "function"
            and type(buffDisplay.RefreshScope) == "function" and type(buffDisplay.Commands) == "table"
            and type(buffDisplay.Commands.SetSetting) == "function" and type(buffDisplay.Commands.SetWidgetVisible) == "function"
            and type(buffDisplay.Commands.ApplySettingFromBinding) == "function" and type(buffDisplay.Commands.MarkStoreDirty) == "function"
            and buffDisplay.Demand ~= nil and buffDisplayStore ~= nil and tonumber(buffDisplayStore.schemaVersion) == 4
            and (tonumber(buffDisplay.BuffHeadMarkerContractVersion) or 0) >= 1
            and buffDisplayPage ~= nil and type(buffDisplayWidget) == "table"
            and buffDisplayMeta ~= nil and tostring(buffDisplayMeta.status) == "migrated_m16_18"
            and tostring(buffDisplayMeta.lifecycle) == "demand_scoped"
            and tostring(buffDisplayMeta.authority):find("v3.buff_display", 1, true) ~= nil,
        "blocker", buffDisplayHealth and ("enabled=" .. tostring(buffDisplay.enabled == true)
            .. "/consumer=" .. tostring(buffDisplayHealth.consumers or 0)
            .. "/aura=" .. tostring(buffDisplayHealth.auraHeld == true)
            .. "/task=" .. tostring(buffDisplayHealth.taskActive == true)) or "missing")
    AddCheck(report, "buff_display_v3_runtime_scope", buffDisplayHealth ~= nil
            and (((tonumber(buffDisplayHealth.consumers) or 0) > 0
                    and buffDisplayHealth.auraHeld == true and buffDisplayHealth.taskActive == true)
                or ((tonumber(buffDisplayHealth.consumers) or 0) <= 0
                    and buffDisplayHealth.auraHeld ~= true and buffDisplayHealth.taskActive ~= true)),
        "warning", buffDisplayHealth and ("enabled=" .. tostring(buffDisplay.enabled == true)
            .. "/consumer=" .. tostring(buffDisplayHealth.consumers or 0)
            .. "/aura=" .. tostring(buffDisplayHealth.auraHeld == true)
            .. "/task=" .. tostring(buffDisplayHealth.taskActive == true)) or "missing")

    local readiness = S.Features and S.Features.RaidReadiness or nil
    local readinessHealth = readiness and type(readiness.GetHealth) == "function" and readiness:GetHealth() or nil
    local readinessMeta = S.FeatureRegistry and S.FeatureRegistry:Get("combat_raid_readiness") or nil
    local readinessStore = S.Persistence and type(S.Persistence.GetStore) == "function" and S.Persistence:GetStore("v3.raid_readiness") or nil
    local readinessPage = S.UIV3 and S.UIV3.PageHost and S.UIV3.PageHost.factories and S.UIV3.PageHost.factories["combat.raid_readiness"] or nil
    local teamNative = S.NativeContract and type(S.NativeContract.GetApi) == "function" and S.NativeContract:GetApi("TEAM") or nil
    AddCheck(report, "raid_readiness_v3_contract", readiness ~= nil and type(readiness.Authority) == "table"
            and (tonumber(readiness.Authority.version) or 0) >= 1 and type(readiness.RunScan) == "function"
            and type(readiness.Authority.StartScan) == "function" and type(readiness.Authority.CancelScan) == "function"
            and type(readiness.Commands) == "table" and type(readiness.Commands.ApplySettingFromBinding) == "function"
            and type(readiness.Commands.MarkStoreDirty) == "function"
            and readiness.Demand ~= nil and readinessStore ~= nil and readinessPage ~= nil
            and readinessMeta ~= nil and tostring(readinessMeta.status) == "migrated_m16_14"
            and tostring(readinessMeta.lifecycle) == "on_demand_scan"
            and type(teamNative) == "table" and tonumber(teamNative.id) == 38,
        "blocker", readinessHealth and ("enabled=" .. tostring(readiness.enabled == true)
            .. "/consumer=" .. tostring(readinessHealth.consumers or 0)
            .. "/scan=" .. tostring(readinessHealth.scanning == true)
            .. "/roster=" .. tostring(readinessHealth.rosterHeld == true)
            .. "/aura=" .. tostring(readinessHealth.auraHeld == true)) or "missing")
    AddCheck(report, "raid_readiness_runtime_scope", readinessHealth ~= nil
            and ((tonumber(readinessHealth.consumers) or 0) > 0 or (readinessHealth.rosterHeld ~= true and readinessHealth.auraHeld ~= true and readinessHealth.scanning ~= true))
            and (readinessHealth.scanning ~= true or readinessHealth.rosterHeld == true)
            and (readinessHealth.auraHeld ~= true or readinessHealth.scanning == true),
        "warning", readinessHealth and ("consumer=" .. tostring(readinessHealth.consumers or 0)
            .. "/scan=" .. tostring(readinessHealth.scanning == true)
            .. "/roster=" .. tostring(readinessHealth.rosterHeld == true)
            .. "/aura=" .. tostring(readinessHealth.auraHeld == true)
            .. "/members=" .. tostring(readinessHealth.rosterMembers or 0)) or "missing")

    local healer = S.Features and S.Features.Healer or nil
    local healerAuraBridge = S.Features and S.Features.HealerAuraBridge or nil
    local healerAuraHealth = type(healerAuraBridge) == "table" and type(healerAuraBridge.GetHealth) == "function"
        and healerAuraBridge:GetHealth() or nil
    local healerHealth = type(healer) == "table" and type(healer.GetHealth) == "function" and healer:GetHealth() or nil
    local healerMeta = S.FeatureRegistry and S.FeatureRegistry:Get("combat_healer") or nil
    local healerStore = S.Persistence and type(S.Persistence.GetStore) == "function" and S.Persistence:GetStore("v3.healer") or nil
    local healerRuntimeHealth = healerHealth and healerHealth.runtime or nil
    AddCheck(report, "healer_v3_domain_runtime", healer ~= nil and S.FeatureRuntime ~= nil
            and S.FeatureRuntime:IsImplemented("combat_healer") == true
            and healerStore ~= nil and type(healer.Roster) == "table" and type(healer.Recommendation) == "table"
            and type(healer.HealthRuntime) == "table" and type(healer.GetProjection) == "function"
            and healerAuraBridge ~= nil and (tonumber(healerAuraBridge.version) or 0) >= 2
            and type(healerAuraBridge.ReadAccurate) == "function"
            and type(healer.Commands) == "table" and type(healer.Commands.ApplySettingFromBinding) == "function"
            and type(healer.Commands.MarkStoreDirty) == "function"
            and healerMeta ~= nil and tostring(healerMeta.status) == "migrated_m16_18"
            and tostring(healerMeta.lifecycle) == "independent"
            and tostring(healerMeta.authority):find("v3.healer", 1, true) ~= nil,
        "blocker", healerHealth and ("enabled=" .. tostring(healerHealth.enabled == true)
            .. "/consumer=" .. tostring(healerHealth.consumers or 0)
            .. "/roster=" .. tostring(healerHealth.rosterHeld == true)
            .. "/aura=" .. tostring(healerHealth.auraHeld == true)
            .. "/task=" .. tostring(healerRuntimeHealth and healerRuntimeHealth.taskActive == true or false)) or "missing")
    AddCheck(report, "healer_v3_runtime_scope", healerHealth ~= nil and healerAuraHealth ~= nil
            and ((healerHealth.enabled == true and healerHealth.rosterHeld == true and healerHealth.auraHeld == true
                    and healerHealth.eventsSubscribed == true and healerRuntimeHealth ~= nil and healerRuntimeHealth.running == true)
                or (healerHealth.enabled ~= true and (tonumber(healerHealth.consumers) or 0) <= 0
                    and healerHealth.rosterHeld ~= true and healerHealth.auraHeld ~= true
                    and healerHealth.eventsSubscribed ~= true and (healerRuntimeHealth == nil or healerRuntimeHealth.running ~= true)
                    and healerAuraHealth.held ~= true))
            and (healerRuntimeHealth == nil or ((tonumber(healerRuntimeHealth.maxHealthSlice) or 0) <= 20
                and (tonumber(healerRuntimeHealth.maxStatusSlice) or 0) <= 8
                and (tonumber(healerRuntimeHealth.maxHealthStatusRefreshSlice) or 0) <= 8)),
        "warning", healerRuntimeHealth and ("health=" .. tostring(healerRuntimeHealth.healthGeneration or 0)
            .. "/status=" .. tostring(healerRuntimeHealth.statusGeneration or 0)
            .. "/shared=" .. tostring(healerRuntimeHealth.sharedStatusAccepted or 0)
            .. "/nativeFallback=" .. tostring(healerRuntimeHealth.nativeStatusFallbacks or 0)
            .. "/unknown=" .. tostring(healerRuntimeHealth.unknownStatusMembers or 0)) or "dormant")
    local healerPageHost = S.UIV3 and S.UIV3.PageHost or nil
    local healerWidgetHost = S.UIV3 and S.UIV3.WidgetHost or nil
    local healerPageRegistered = type(healerPageHost) == "table" and type(healerPageHost.factories) == "table"
        and type(healerPageHost.factories["combat.healer"]) == "function"
    local healerWidgetSpec = type(healerWidgetHost) == "table" and type(healerWidgetHost.specs) == "table"
        and healerWidgetHost.specs["combat.healer"] or nil
    AddCheck(report, "healer_v3_presentation", healerPageRegistered == true and healerWidgetSpec == nil
            and type(healer.GetMemberDetail) == "function" and type(healer.ApplySettingFromBinding) == "function"
            and healerStore ~= nil and tonumber(healerStore.schemaVersion) == 3,
        "blocker", "page=" .. tostring(healerPageRegistered == true)
            .. "/recommendationWidgetRemoved=" .. tostring(healerWidgetSpec == nil)
            .. "/store=" .. tostring(healerStore and healerStore.schemaVersion or "missing"))
    AddCheck(report, "healer_v3_advanced_editor_commands", type(healer.GetRules) == "function"
            and type(healer.SetRule) == "function" and type(healer.AddRule) == "function"
            and type(healer.RemoveRule) == "function" and type(healer.GetTrackedBuffs) == "function"
            and type(healer.SetTrackedBuff) == "function" and type(healer.AddTrackedBuff) == "function"
            and type(healer.RemoveTrackedBuff) == "function" and type(healer.SetHealerColor) == "function"
            and type(healer.Commands) == "table" and type(healer.Commands.SetRule) == "function"
            and type(healer.Commands.AddRule) == "function" and type(healer.Commands.RemoveRule) == "function"
            and type(healer.Commands.SetTrackedBuff) == "function" and type(healer.Commands.AddTrackedBuff) == "function"
            and type(healer.Commands.RemoveTrackedBuff) == "function" and type(healer.Commands.SetHealerColor) == "function"
            and type(healer.Commands.SetRaidSectionRect) == "function" and type(healer.Commands.ResetRaidLayout) == "function",
        "blocker", "v3.healer rule/tracked/color command authority required")
    local healerHead = S.UIV3 and S.UIV3.HealerHeadMarker or nil
    local healerRaid = S.UIV3 and S.UIV3.HealerRaidOverlay or nil
    local healerScreen = S.Features and S.Features.HealerScreenProjection or nil
    local healerPresentation = type(healer.GetPresentationSettings) == "function" and healer:GetPresentationSettings() or nil
    AddCheck(report, "healer_v3_visual_consumers", type(healerHead) == "table" and type(healerHead.Describe) == "function"
            and type(healerRaid) == "table" and type(healerRaid.Describe) == "function"
            and type(healerScreen) == "table" and type(healerScreen.ProjectUnit) == "function"
            and type(healer.ProjectUnitToScreen) == "function" and type(healer.GetRosterProjection) == "function"
            and type(healer.GetRaidOverlayProjection) == "function" and type(healerPresentation) == "table" and type(healerPresentation.head) == "table"
            and type(healerPresentation.raid) == "table",
        "blocker", "head=" .. tostring(type(healerHead) == "table")
            .. "/raid=" .. tostring(type(healerRaid) == "table")
            .. "/screen=" .. tostring(type(healerScreen) == "table"))
    local headHealth = type(healerHead) == "table" and healerHead:Describe() or nil
    local raidHealth = type(healerRaid) == "table" and healerRaid:Describe() or nil
    local headSettings = type(healerPresentation) == "table" and healerPresentation.head or nil
    local raidSettings = type(healerPresentation) == "table" and healerPresentation.raid or nil
    local healerRuntimeEnabled = healerHealth and healerHealth.enabled == true
    local headExpected = healerRuntimeEnabled and headSettings and headSettings.enabled == true
    local raidCalibrationExpected = raidSettings and raidSettings.calibration == true
    local raidLiveExpected = raidCalibrationExpected ~= true and healerRuntimeEnabled and raidSettings and raidSettings.enabled == true
    local raidExpected = raidCalibrationExpected == true or raidLiveExpected == true
    local headLifecycleOk = type(headHealth) ~= "table"
        or (headExpected and headHealth.running == true and headHealth.consumerHeld == true and headHealth.taskActive == true)
        or (not headExpected and headHealth.running ~= true and headHealth.consumerHeld ~= true and headHealth.taskActive ~= true)
    local raidTaskExpected = raidLiveExpected and tonumber(raidSettings.effectMode) ~= 1
    local raidLifecycleOk = type(raidHealth) ~= "table"
        or (raidCalibrationExpected and raidHealth.running == true and raidHealth.calibrationMode == true
            and raidHealth.consumerHeld ~= true and raidHealth.taskActive ~= true)
        or (raidLiveExpected and raidHealth.running == true and raidHealth.calibrationMode ~= true and raidHealth.consumerHeld == true
            and ((raidTaskExpected and raidHealth.taskActive == true) or (not raidTaskExpected and raidHealth.taskActive ~= true)))
        or (not raidExpected and raidHealth.running ~= true and raidHealth.consumerHeld ~= true and raidHealth.taskActive ~= true)
    AddCheck(report, "healer_v3_visual_lifecycle", headLifecycleOk and raidLifecycleOk,
        "warning", "head=" .. tostring(headHealth and headHealth.running == true or false)
            .. "/raid=" .. tostring(raidHealth and raidHealth.running == true or false)
            .. "/raid_task=" .. tostring(raidHealth and raidHealth.taskActive == true or false))

    local combatRelation = S.Services and S.Services.CombatRelationV3 or nil
    local relationHealth = combatRelation and type(combatRelation.GetHealth) == "function" and combatRelation:GetHealth() or nil
    AddCheck(report, "combat_relation_contract", combatRelation ~= nil and (tonumber(combatRelation.version) or 0) >= 4
            and type(combatRelation.AcquireConsumer) == "function" and type(combatRelation.ReleaseConsumer) == "function"
            -- v4 relation queries are timestamp-aware. ResolveName belonged to
            -- an abandoned intermediate contract and is not part of the active
            -- CombatRelationV3 service.
            and type(combatRelation.GetRelationAt) == "function" and combatRelation.demand ~= nil and relationHealth ~= nil,
        "blocker", relationHealth and ("version=" .. tostring(relationHealth.version or 0)
            .. "/consumer=" .. tostring(relationHealth.consumers or 0)
            .. "/units=" .. tostring(relationHealth.units or 0)
            .. "/rosterHeld=" .. tostring(relationHealth.rosterHeld == true)) or "missing")

    local deathReview = S.Features and S.Features.DeathReview or nil
    local deathHealth = deathReview and type(deathReview.GetHealth) == "function" and deathReview:GetHealth() or nil
    local deathStore = S.Persistence and type(S.Persistence.GetStore) == "function" and S.Persistence:GetStore("v3.death_review") or nil
    local deathMeta = S.FeatureRegistry and S.FeatureRegistry:Get("combat_death_review") or nil
    local deathPage = S.UIV3 and S.UIV3.PageHost and S.UIV3.PageHost.factories and S.UIV3.PageHost.factories["combat.death_review"] or nil
    local deathWidget = S.UIV3 and S.UIV3.WidgetHost and type(S.UIV3.WidgetHost.GetSpec) == "function" and S.UIV3.WidgetHost:GetSpec("combat.death_review") or nil
    AddCheck(report, "death_review_v3_contract", deathReview ~= nil and type(deathReview.Authority) == "table"
            and type(deathReview.Authority.RequestFinalizeDeath) == "function"
            and type(deathReview.GetProjection) == "function" and type(deathReview.Commands) == "table"
            and type(deathReview.Commands.ApplyAutoShow) == "function" and type(deathReview.Commands.ApplyShowDebuffs) == "function"
            and type(deathReview.Commands.ApplyWindowMs) == "function" and type(deathReview.Commands.ApplyMinDamage) == "function"
            and type(deathReview.Commands.SetMaxHistory) == "function" and type(deathReview.Commands.MarkStoreDirty) == "function"
            and type(deathReview.Commands.SetEnabled) == "function" and type(deathReview.Commands.ClearHistory) == "function"
            and deathReview.Demand ~= nil and deathStore ~= nil and deathPage ~= nil and deathWidget ~= nil
            and deathMeta ~= nil and tostring(deathMeta.status) == "migrated_m15_2" and tostring(deathMeta.authority) == "v3.death_review",
        "blocker", deathHealth and ("enabled=" .. tostring(deathReview.enabled == true)
            .. "/consumer=" .. tostring(deathHealth.consumers or 0)
            .. "/scope=" .. tostring(deathHealth.busScope or "none")
            .. "/deferred=" .. tostring(deathHealth.debuffDeferred or 0)
            .. "/ferFail=" .. tostring(deathHealth.debuffDeferFailures or 0)
            .. "/history=" .. tostring(deathHealth.history or 0)) or "missing")
    AddCheck(report, "death_review_runtime_scope", deathHealth ~= nil
            and (deathReview.enabled ~= true or (deathHealth.busSubscribed == true and tostring(deathHealth.busScope) == "self"))
            and (deathReview.enabled == true or (tonumber(deathHealth.consumers) or 0) == 0)
            and (tonumber(deathHealth.deferredFinalizeFailures) or 0) == 0,
        "warning", deathHealth and ("enabled=" .. tostring(deathReview.enabled == true)
            .. "/bus=" .. tostring(deathHealth.busSubscribed == true)
            .. "/scope=" .. tostring(deathHealth.busScope or "none")
            .. "/aura=" .. tostring(deathHealth.auraConsumer == true)
            .. "/pending=" .. tostring(deathHealth.pendingDeath == true)
            .. "/deferredFail=" .. tostring(deathHealth.deferredFinalizeFailures or 0)) or "missing")
    local dpsFeature = S.Features and S.Features.DPS or nil
    local dpsMeta = S.FeatureRegistry and S.FeatureRegistry:Get("combat_stats") or nil
    local dpsPage = S.UIV3 and S.UIV3.PageHost and S.UIV3.PageHost.factories and S.UIV3.PageHost.factories["combat.stats"] or nil
    local dpsWidget = S.UIV3 and S.UIV3.WidgetHost and type(S.UIV3.WidgetHost.GetSpec) == "function" and S.UIV3.WidgetHost:GetSpec("combat.dps") or nil
    local dpsStore = S.Persistence and type(S.Persistence.GetStore) == "function" and S.Persistence:GetStore("v3.dps") or nil
    local dpsHealth = type(dpsFeature) == "table" and type(dpsFeature.GetHealth) == "function" and dpsFeature:GetHealth() or nil
    AddCheck(report, "dps_v3_contract", dpsFeature ~= nil and type(dpsFeature.Domain) == "table" and (tonumber(dpsFeature.Domain.version) or 0) >= 7
            and type(dpsFeature.Domain.OnCombatFact) == "function" and type(dpsFeature.Domain.GetActorDetail) == "function" and type(dpsFeature.ClearStats) == "function"
            and type(dpsFeature.GetProjection) == "function" and type(dpsFeature.Commands) == "table"
            and type(dpsFeature.Commands.ApplySettingFromBinding) == "function" and type(dpsFeature.Commands.MarkStoreDirty) == "function"
            and type(dpsFeature.Commands.SetEnabled) == "function" and type(dpsFeature.Commands.Clear) == "function"
            and dpsFeature.Demand ~= nil and dpsStore ~= nil and dpsPage ~= nil and dpsWidget ~= nil
            and dpsMeta ~= nil and tostring(dpsMeta.status) == "migrated_m16"
            and tostring(dpsMeta.authority):find("v3.dps", 1, true) ~= nil
            and S.Services ~= nil and type(S.Services.CombatRelationV3) == "table"
            and type(S.Services.CombatAnalyticsV3) == "table",
        "blocker", dpsHealth and ("enabled=" .. tostring(dpsFeature.enabled == true)
            .. "/consumer=" .. tostring(dpsHealth.consumers or 0)
            .. "/scope=" .. tostring(dpsHealth.busScope or "none")
            .. "/pvp=" .. tostring(dpsHealth.classificationPVP or 0)
            .. "/pve=" .. tostring(dpsHealth.classificationPVE or 0)
            .. "/pending=" .. tostring(dpsHealth.pendingRows or 0)) or "missing")
    local proxyCatalog = S.Data and S.Data.CombatSourceProxyCatalog or nil
    local fountainProxy = type(proxyCatalog) == "table" and type(proxyCatalog.Get) == "function" and proxyCatalog:Get("healing_fountain") or nil
    AddCheck(report, "dps_skill_proxy_source_contract", type(proxyCatalog) == "table" and (tonumber(proxyCatalog.version) or 0) >= 1
            and type(proxyCatalog.ResolveSource) == "function" and type(proxyCatalog.ResolveAbility) == "function"
            and type(fountainProxy) == "table" and tostring(fountainProxy.kind) == "PLAYER_PLACED_SKILL_PROXY"
            and tostring(fountainProxy.ownerAttribution) == "UNAVAILABLE_NO_RELIABLE_OWNER_LINK"
            and tonumber(fountainProxy.durationMs) == 60000 and dpsHealth ~= nil
            and dpsHealth.proxySourceHeals ~= nil and dpsHealth.proxySourceHealAmount ~= nil,
        "blocker", "catalog=" .. tostring(proxyCatalog and proxyCatalog.version or 0)
            .. "/domain=" .. tostring(dpsFeature and dpsFeature.Domain and dpsFeature.Domain.version or 0)
            .. "/proxyEvents=" .. tostring(dpsHealth and dpsHealth.proxySourceHeals or 0)
            .. "/proxyHeal=" .. tostring(dpsHealth and dpsHealth.proxySourceHealAmount or 0))

    AddCheck(report, "dps_v3_runtime_scope", dpsHealth ~= nil
            and (dpsFeature.enabled ~= true or (dpsHealth.analyticsHeld == true and tostring(dpsHealth.busScope) == "all(shared_analytics)"))
            and dpsFeature.busSubscribed ~= true
            and (dpsFeature.enabled == true or (tonumber(dpsHealth.consumers) or 0) == 0),
        "warning", dpsHealth and ("enabled=" .. tostring(dpsFeature.enabled == true)
            .. "/analytics=" .. tostring(dpsHealth.analyticsHeld == true)
            .. "/directBus=" .. tostring(dpsFeature.busSubscribed == true)
            .. "/scope=" .. tostring(dpsHealth.busScope or "none")
            .. "/pvp=" .. tostring(dpsHealth.classificationPVP or 0)
            .. "/pve=" .. tostring(dpsHealth.classificationPVE or 0)
            .. "/unknown=" .. tostring(dpsHealth.classificationUnknown or 0)
            .. "/pending=" .. tostring(dpsHealth.pendingRows or 0)) or "missing")

    local gameValidation = S.GameDataRegistry and type(S.GameDataRegistry.Validate) == "function" and S.GameDataRegistry:Validate() or nil
    AddCheck(report, "game_identity_registry", gameValidation ~= nil and gameValidation.ok == true
            and gameValidation.sealed == true and (tonumber(gameValidation.sealViolations) or 0) == 0
            and gameValidation.mutationDetected ~= true,
        "blocker", gameValidation and ("records=" .. tostring(gameValidation.totalRecords or 0)
            .. "/sets=" .. tostring(gameValidation.totalSets or 0)
            .. "/sealed=" .. tostring(gameValidation.sealed == true)
            .. "/sealViol=" .. tostring(gameValidation.sealViolations or 0)
            .. "/mut=" .. tostring(gameValidation.mutationDetected == true)
            .. "/warn=" .. tostring(gameValidation.warnings or 0)) or "missing")

    local zoneCatalog = S.StaticDataV2 and S.StaticDataV2:GetCatalog("zone") or nil
    local zoneIds = S.GameIds and S.GameIds.Zone or nil
    local zoneCount = zoneCatalog and #(zoneCatalog.order or {}) or 0
    AddCheck(report, "zone_identity_catalog", zoneCount >= 34 and type(zoneIds) == "table" and type(zoneIds.ById) == "table",
        "blocker", "zones=" .. tostring(zoneCount) .. "/shared=" .. tostring(type(zoneIds) == "table"))

    AddCheck(report, "static_data_api", S.StaticDataV2 ~= nil
            and type(S.StaticDataV2.Get) == "function" and type(S.StaticDataV2.FindById) == "function"
            and type(S.StaticDataV2.List) == "function" and type(S.StaticDataV2.GetCount) == "function",
        "blocker", "indexed read API")

    local staticValidation = S.StaticDataV2 and S.StaticDataV2:Validate() or nil
    AddCheck(report, "static_data_v2", staticValidation ~= nil and staticValidation.ok == true
            and staticValidation.sealed == true and (tonumber(staticValidation.sealViolations) or 0) == 0
            and staticValidation.mutationDetected ~= true
            and (tonumber(staticValidation.records) or 0) > 0,
        "blocker", staticValidation and ("catalogs=" .. tostring(staticValidation.catalogs or 0)
            .. "/records=" .. tostring(staticValidation.records or 0)
            .. "/refs=" .. tostring(staticValidation.references or 0)
            .. "/missing=" .. tostring(staticValidation.missingRefs or 0)
            .. "/missingId=" .. tostring(staticValidation.missingRequiredIds or 0)
            .. "/sealed=" .. tostring(staticValidation.sealed == true)
            .. "/sealViol=" .. tostring(staticValidation.sealViolations or 0)
            .. "/mut=" .. tostring(staticValidation.mutationDetected == true)) or "missing")

    local tradeStatic = S.Data and S.Data.TradeStaticV2 and type(S.Data.TradeStaticV2.Describe) == "function" and S.Data.TradeStaticV2:Describe() or nil
    local tradeReady = tradeStatic ~= nil
        and (tonumber(tradeStatic.materials) or 0) > 0
        and (tonumber(tradeStatic.goods) or 0) > 0
        and (tonumber(tradeStatic.recipes) or 0) > 0
    AddCheck(report, "trade_static_catalog", tradeReady, "blocker", tradeStatic and
        ("materials=" .. tostring(tradeStatic.materials or 0) .. "/goods=" .. tostring(tradeStatic.goods or 0) .. "/recipes=" .. tostring(tradeStatic.recipes or 0)) or "missing")
    if tradeReady then
        AddCheck(report, "trade_origin_zone_links", (tonumber(tradeStatic.pendingOriginZones) or 0) == 0, "blocker",
            "pending=" .. tostring(tradeStatic.pendingOriginZones or 0))
        AddCheck(report, "trade_craft_ids",
            (tonumber(tradeStatic.recipes) or 0) >= 98
                and (tonumber(tradeStatic.primaryCraftIds) or 0) == (tonumber(tradeStatic.recipes) or 0)
                and (tonumber(tradeStatic.missingCraftIds) or 0) == 0,
            "blocker", "primary=" .. tostring(tradeStatic.primaryCraftIds or 0) .. "/" .. tostring(tradeStatic.recipes or 0)
                .. "/refs=" .. tostring(tradeStatic.totalRecipeCraftIds or 0)
                .. "/alt=" .. tostring(tradeStatic.alternateRecipeCraftIds or 0))
        AddCheck(report, "trade_recipe_signatures",
            (tonumber(tradeStatic.verifiedIngredientSignatures) or 0) == (tonumber(tradeStatic.recipes) or 0)
                and (tonumber(tradeStatic.recipes) or 0) >= 98
                and (tonumber(tradeStatic.ingredientSignatureFailures) or 0) == 0,
            "blocker", "verified=" .. tostring(tradeStatic.verifiedIngredientSignatures or 0)
                .. "/fail=" .. tostring(tradeStatic.ingredientSignatureFailures or 0))
        -- R4 has authoritative Product ItemIDs for the current 98-recipe set.
        -- Treat coverage or duplicate regressions as blockers so runtime code
        -- never falls back to an ambiguous name for an already-audited product.
        AddCheck(report, "trade_product_ids",
            (tonumber(tradeStatic.pendingProductIds) or 0) == 0
                and (tonumber(tradeStatic.productIdDuplicates) or 0) == 0,
            "blocker", "verified=" .. tostring(tradeStatic.verifiedProductIds or 0)
                .. "/pending=" .. tostring(tradeStatic.pendingProductIds or 0)
                .. "/duplicates=" .. tostring(tradeStatic.productIdDuplicates or 0))
    end
    report.tradeStatic = tradeStatic

    local questIds = S.GameIds and S.GameIds.Quest and type(S.GameIds.Quest.Describe) == "function" and S.GameIds.Quest:Describe() or nil
    AddCheck(report, "quest_id_verification",
        questIds ~= nil
            and (tonumber(questIds.total) or 0) >= 214
            and (tonumber(questIds.verified) or 0) == (tonumber(questIds.total) or 0)
            and (tonumber(questIds.pending) or 0) == 0,
        "warning",
        questIds and ("verified=" .. tostring(questIds.verified or 0) .. "/pending=" .. tostring(questIds.pending or 0) .. "/total=" .. tostring(questIds.total or 0)) or "missing")
    report.questIds = questIds

    local instanceIds = S.GameIds and S.GameIds.Instance and type(S.GameIds.Instance.Describe) == "function" and S.GameIds.Instance:Describe() or nil
    AddCheck(report, "instance_database_zone_ids", instanceIds ~= nil and (tonumber(instanceIds.databaseVerified) or 0) >= 19, "blocker",
        instanceIds and ("db=" .. tostring(instanceIds.databaseVerified or 0) .. "/runtime=" .. tostring(instanceIds.runtimeVerified or 0)
            .. "/pending=" .. tostring(instanceIds.runtimePending or 0)) or "missing")
    AddCheck(report, "instance_runtime_observation_conflicts",
        instanceIds ~= nil and (tonumber(instanceIds.runtimeObservedConflicts) or 0) == 0,
        "warning", instanceIds and ("observed=" .. tostring(instanceIds.runtimeObserved or 0)
            .. "/conflicts=" .. tostring(instanceIds.runtimeObservedConflicts or 0)) or "missing")
    report.instanceIds = instanceIds

    local persistence = S.Persistence and S.Persistence:Describe() or nil
    local persistenceStats = persistence and persistence.stats or {}
    AddCheck(report, "persistence_v3_contract_api",
        S.Persistence ~= nil and type(S.Persistence.RegisterV3Store) == "function"
            and type(S.Persistence.InspectPayload) == "function"
            and type(S.Persistence.ClearStore) == "function"
            and type(S.Persistence.CanWrite) == "function" and type(S.Persistence.IsStoreLoaded) == "function"
            and type(S.Persistence.V3KeyPrefix) == "string",
        "blocker", "explicit v3 owner/scope/key/budget contract")
    local payloadSafe, payloadCycleRejected = false, false
    if S.Persistence ~= nil and type(S.Persistence.InspectPayload) == "function" then
        local safe = S.Persistence:InspectPayload({ probe = true, nested = { value = 1 } })
        local cycle = {}; cycle.self = cycle
        local rejected = S.Persistence:InspectPayload(cycle)
        payloadSafe = type(safe) == "table" and safe.ok == true
        payloadCycleRejected = type(rejected) == "table" and rejected.ok == false and rejected.reason == "cyclic_table"
    end
    AddCheck(report, "persistence_preflight", payloadSafe and payloadCycleRejected, "blocker",
        "safe=" .. tostring(payloadSafe) .. "/cycleReject=" .. tostring(payloadCycleRejected))

    AddCheck(report, "persistence_v2", persistence ~= nil
            and (tonumber(persistence.fenced) or 0) == 0
            and (tonumber(persistence.legacyContracts) or 0) == 0
            and (tonumber(persistence.budgetProtected) or 0) == (tonumber(persistence.total) or 0)
            and (tonumber(persistenceStats.payloadRejected) or 0) == 0
            and (tonumber(persistenceStats.encodedPayloadRejected) or 0) == 0
            and (tonumber(persistenceStats.metadataMismatches) or 0) == 0
            and (tonumber(persistenceStats.keyCollisions) or 0) == 0,
        "blocker", persistence and ("stores=" .. tostring(persistence.total or 0)
            .. "/v2=" .. tostring(persistence.contractV2 or 0)
            .. "/budget=" .. tostring(persistence.budgetProtected or 0)
            .. "/legacy=" .. tostring(persistence.legacyContracts or 0)
            .. "/fenced=" .. tostring(persistence.fenced or 0)
            .. "/reject=" .. tostring(persistenceStats.payloadRejected or 0)
            .. "/encoded=" .. tostring(persistenceStats.encodedPayloadRejected or 0)
            .. "/keyCollision=" .. tostring(persistenceStats.keyCollisions or 0)
            .. "/meta=" .. tostring(persistenceStats.metadataMismatches or 0)) or "missing")

    if v3HostRegistered then
        AddCheck(report, "persistence_v3_store",
            persistence ~= nil and (tonumber(persistence.contractV3) or 0) >= 1,
            "blocker", "registered=" .. tostring(persistence and persistence.contractV3 or 0))
    end

    local invalidBoundaries = {}
    local allowedBoundary = { service_only = true, event_host_only = true }
    for name, service in pairs(S.Services or {}) do
        if type(service) == "table" then
            local boundary = tostring(service.presentationBoundary or "missing")
            if allowedBoundary[boundary] ~= true then invalidBoundaries[#invalidBoundaries+1] = tostring(name) .. ":" .. boundary end
        end
    end
    if type(S.TargetService) == "table" then
        local boundary = tostring(S.TargetService.presentationBoundary or "missing")
        if allowedBoundary[boundary] ~= true then invalidBoundaries[#invalidBoundaries+1] = "TargetService:" .. boundary end
    end
    table.sort(invalidBoundaries)
    AddCheck(report, "service_presentation_boundary", #invalidBoundaries == 0, "blocker",
        #invalidBoundaries == 0 and "all services explicitly presentation-free" or ("invalid=" .. Join(invalidBoundaries, 8)))
    report.legacyPresentationDebt = invalidBoundaries

    local acceptance = S.UIV3Acceptance or S.UIAcceptance
    if acceptance ~= nil then
        local matrix = type(acceptance.RunMatrix) == "function" and acceptance:RunMatrix() or nil
        local text = type(acceptance.RunTextStress) == "function" and acceptance:RunTextStress() or nil
        local live = type(acceptance.InspectLive) == "function" and acceptance:InspectLive() or nil
        local coreOk = matrix ~= nil and matrix.ok == true and text ~= nil and text.ok == true
        local matrixDetail = matrix and type(matrix.details) == "table" and Join(matrix.details, 5) or ""
        AddCheck(report, "ui_foundation_matrix", coreOk, "blocker",
            "matrix=" .. tostring(matrix and matrix.failures or "?") .. "/text=" .. tostring(text and text.failures or "?")
                .. (matrixDetail ~= "" and ("/first=" .. matrixDetail) or ""))
        if live ~= nil then
            local liveOk = (tonumber(live.hardIssues) or 0) == 0
                and (tonumber(live.staleLayoutRoots) or 0) == 0
                and (tonumber(live.unscheduledLayoutRoots) or 0) == 0
            AddCheck(report, "v3_live_ui", liveOk, "warning",
                "hard=" .. tostring(live.hardIssues or 0)
                    .. "/pending=" .. tostring(live.pendingLayoutRoots or 0)
                    .. "/fresh=" .. tostring(live.freshLayoutRoots or 0)
                    .. "/stale=" .. tostring(live.staleLayoutRoots or 0)
                    .. "/unscheduled=" .. tostring(live.unscheduledLayoutRoots or 0)
                    .. "/oldestMs=" .. tostring(live.oldestLayoutAgeMs or 0)
                    .. "/repairs=" .. tostring(live.cacheRepairs or 0))
        end
    else
        AddCheck(report, "ui_foundation_matrix", false, "blocker", "acceptance unavailable")
    end

    local truthExpected = {
        combat_boss_alerts = "migrated_partial", combat_buff_cap = "migrated_partial", combat_team_tools = "migrated_partial",
        combat_unit_lines = "migrated_partial", combat_range_assist = "migrated_partial",
        combat_raid_recruitment = "migrated_partial", life_trade = "migrated_partial", life_fishing = "migrated_partial",
        life_craft_planner = "migrated_partial", tools_bag = "migrated_partial", tools_auction = "migrated_partial", tools_market_analysis = "migrated_partial", tools_craft = "migrated_partial",
    }
    local truthFailures = {}
    for id, expected in pairs(truthExpected) do
        local row = S.FeatureRegistry and S.FeatureRegistry:Get(id) or nil
        if row == nil or tostring(row.status or "") ~= expected then truthFailures[#truthFailures + 1] = id .. ":" .. tostring(row and row.status or "missing") end
    end
    table.sort(truthFailures)
    AddCheck(report, "v3_feature_truth_contract", #truthFailures == 0, "blocker", #truthFailures == 0 and "partial/blocked capabilities labeled honestly" or ("invalid=" .. Join(truthFailures, 8)))

    local apiCooldownOk = type(S.Api) == "table" and (tonumber(S.Api.CapabilityCooldownContractVersion) or 0) >= 1
        and type(S.Api.ConsumeCapabilityCooldown) == "function" and type(S.Api.GetCapabilityCooldownState) == "function"
    AddCheck(report, "api_capability_cooldown_contract", apiCooldownOk, "blocker",
        apiCooldownOk and "registered capability cooldowns enforced centrally" or "central capability cooldown fence unavailable")

    local targetMonitor = S.Features and S.Features.combat_target_monitor or nil
    local buffCap = S.Features and S.Features.combat_buff_cap or nil
    local treasure = S.Features and S.Features.Treasure or nil
    local fishing = S.Features and S.Features.Fishing or nil
    local observationFailures = {}
    if type(targetMonitor) ~= "table" or (tonumber(targetMonitor.ObservationContractVersion) or 0) < 1 or type(targetMonitor.UpdateTopic) ~= "string" then observationFailures[#observationFailures + 1] = "target" end
    if type(buffCap) ~= "table" or (tonumber(buffCap.ObservationContractVersion) or 0) < 1 or type(buffCap.UpdateTopic) ~= "string" then observationFailures[#observationFailures + 1] = "buff_cap" end
    if type(treasure) ~= "table" or (tonumber(treasure.ObservationContractVersion) or 0) < 1 or type(treasure.UpdateTopic) ~= "string" then observationFailures[#observationFailures + 1] = "treasure" end
    if type(fishing) ~= "table" or (tonumber(fishing.ObservationContractVersion) or 0) < 1 or type(fishing.UpdateTopic) ~= "string" then observationFailures[#observationFailures + 1] = "fishing" end
    AddCheck(report, "v3_dynamic_observation_contract", #observationFailures == 0, "blocker",
        #observationFailures == 0 and "target/buff-cap/treasure/fishing demand observation contracts present" or ("missing=" .. Join(observationFailures, 8)))

    local usabilityFailures = {}
    local screenProjection = S.Services and S.Services.ScreenProjectionV3 or nil
    local alerts = S.Services and S.Services.Alerts or nil
    local alertHud = S.UIV3 and S.UIV3.AlertHudV3 or nil
    local visualGuides = S.UIV3 and S.UIV3.CombatVisualGuidesV3 or nil
    local lifeWidgets = S.UIV3 and S.UIV3.LifeEconomyWidgetsV3 or nil
    local widgetHost = S.UIV3 and S.UIV3.WidgetHost or nil
    local bossAlerts = S.Features and S.Features.combat_boss_alerts or nil
    local unitLines = S.Features and S.Features.combat_unit_lines or nil
    local rangeAssist = S.Features and S.Features.combat_range_assist or nil
    local buffDisplay2 = S.Features and S.Features.BuffDisplay or nil
    local buffHealth2 = type(buffDisplay2) == "table" and type(buffDisplay2.GetHealth) == "function" and buffDisplay2:GetHealth() or nil
    if type(screenProjection) ~= "table" or (tonumber(screenProjection.version) or 0) < 3 or tostring(screenProjection.presentationBoundary or "") ~= "service_only"
        or type(screenProjection.ProjectUnitFlexible) ~= "function" or type(screenProjection.ProjectWorld) ~= "function"
        or type(screenProjection.ProjectWorldBatch) ~= "function" then usabilityFailures[#usabilityFailures + 1] = "screen_projection" end
    if type(alerts) ~= "table" or type(alerts.Push) ~= "function" or type(alertHud) ~= "table" or (tonumber(alertHud.version) or 0) < 1
        or type(bossAlerts) ~= "table" or (tonumber(bossAlerts.HudContractVersion) or 0) < 1 then usabilityFailures[#usabilityFailures + 1] = "boss_hud" end
    if type(visualGuides) ~= "table" or (tonumber(visualGuides.version) or 0) < 2
        or type(unitLines) ~= "table" or (tonumber(unitLines.VisualGuideContractVersion) or 0) < 1
        or type(rangeAssist) ~= "table" or (tonumber(rangeAssist.VisualGuideContractVersion) or 0) < 1 then usabilityFailures[#usabilityFailures + 1] = "visual_guides" end
    local tradeWidget = type(widgetHost) == "table" and type(widgetHost.GetSpec) == "function" and widgetHost:GetSpec("life.trade") or nil
    local bondsWidget = type(widgetHost) == "table" and type(widgetHost.GetSpec) == "function" and widgetHost:GetSpec("life.bonds") or nil
    if type(lifeWidgets) ~= "table" or (tonumber(lifeWidgets.version) or 0) < 1 or type(tradeWidget) ~= "table" or type(bondsWidget) ~= "table" then usabilityFailures[#usabilityFailures + 1] = "life_widgets" end
    if type(buffHealth2) ~= "table" or (tonumber(buffHealth2.observationContractVersion) or 0) < 2 then usabilityFailures[#usabilityFailures + 1] = "buff_observation" end
    local healerFloatingSpec = type(widgetHost) == "table" and type(widgetHost.GetSpec) == "function" and widgetHost:GetSpec("combat.healer") or nil
    if healerFloatingSpec ~= nil then usabilityFailures[#usabilityFailures + 1] = "healer_recommendation_widget" end
    AddCheck(report, "v3_combat_life_usability_contract", #usabilityFailures == 0, "blocker",
        #usabilityFailures == 0 and "screen HUD/visual guides/life widgets/status observation contracts present" or ("missing=" .. Join(usabilityFailures, 8)))

    local bagTools = S.Features and S.Features.tools_bag or nil
    local bagQuickPresenter = S.UIV3 and S.UIV3.BagQuickOverlay or nil
    local bagContractOk = type(bagTools) == "table" and (tonumber(bagTools.BagMoveContractVersion) or 0) >= 4
        and (tonumber(bagTools.BatchLifecycleContractVersion) or 0) >= 4 and (tonumber(bagTools.NativeWindowQuickContractVersion) or 0) >= 2
        and (tonumber(bagTools.BagTaskMutexContractVersion) or 0) >= 1
        and type(bagTools.Commands) == "table" and type(bagTools.Commands.QuickWithdraw) == "function"
        and type(bagTools.Commands.QuickDeposit) == "function" and type(bagTools.Commands.QuickCancel) == "function"
        and type(bagTools.Commands.SetBatchCategory) == "function" and type(bagTools.Commands.SetBatchTarget) == "function"
        and type(bagTools.Commands.SetBatchLimit) == "function"
        and type(bagQuickPresenter) == "table" and (tonumber(bagQuickPresenter.version) or 0) >= 1
    AddCheck(report, "v3_bag_action_contract", bagContractOk, "blocker",
        bagContractOk and "native-window follow quick take/put + category UX + mutually-exclusive serial move tasks present" or "bag action contract v4 unavailable")

    local auctionQuery = S.Services and S.Services.AuctionQueryV3 or nil
    local auction = S.Features and S.Features.tools_auction or nil
    local market = S.Features and S.Features.tools_market_analysis or nil
    local auctionQueryOk = type(auctionQuery) == "table" and (tonumber(auctionQuery.version) or 0) >= 2
        and (tonumber(auctionQuery.EventAuthorityContractVersion) or 0) >= 1
        and tostring(auctionQuery.presentationBoundary or "") == "service_only" and type(auctionQuery.Search) == "function" and type(auctionQuery.GetSnapshot) == "function"
        and type(auction) == "table" and (tonumber(auction.AuctionQueryContractVersion) or 0) >= 1 and type(auction.Commands.Search) == "function"
        and type(market) == "table" and (tonumber(market.AuctionQueryContractVersion) or 0) >= 1 and type(market.Commands.Search) == "function"
    AddCheck(report, "v3_auction_query_contract", auctionQueryOk, "blocker",
        auctionQueryOk and "single event Authority + timeout-fenced explicit current-listing query" or "auction query contract v2 unavailable")

    local craftSelectionOk = true
    for _, craftId in ipairs({ "life_craft_planner", "tools_craft" }) do
        local craftFeature = S.Features and S.Features[craftId] or nil
        if type(craftFeature) ~= "table" or (tonumber(craftFeature.CraftUserSelectionContractVersion) or 0) < 1
            or type(craftFeature.Commands) ~= "table" or type(craftFeature.Commands.SelectRecipe) ~= "function" then craftSelectionOk = false end
    end
    AddCheck(report, "v3_craft_user_selection_contract", craftSelectionOk, "blocker",
        craftSelectionOk and "user selects verified craft entry; raw ids are internal" or "craft user-selection contract unavailable")

    local teamTools = S.Features and S.Features.combat_team_tools or nil
    local teamRoleOk = type(teamTools) == "table" and (tonumber(teamTools.TeamRoleContractVersion) or 0) >= 2
        and type(teamTools.Commands) == "table" and type(teamTools.Commands.SetRole) == "function"
    AddCheck(report, "v3_team_role_contract", teamRoleOk, "blocker",
        teamRoleOk and "roster observation + self-role write semantics present" or "team role contract v2 unavailable")

    local activities = S.Features and S.Features.Activities or nil
    local tasks = S.Features and S.Features.Tasks or nil
    local persistenceMutationOk = type(activities) == "table" and (tonumber(activities.PersistenceMutationContractVersion) or 0) >= 2
        and type(tasks) == "table" and (tonumber(tasks.PersistenceMutationContractVersion) or 0) >= 2
    AddCheck(report, "v3_feature_persistence_mutation_contract", persistenceMutationOk, "blocker",
        persistenceMutationOk and "activity/task specialized mutations roll back on store rejection" or "specialized persistence mutation contract v2 unavailable")

    AddCheck(report, "diagnostics", S.DiagnosticsManager ~= nil and type(S.DiagnosticsManager.Snapshot) == "function", "blocker", "structured diagnostics")

    local sequenceAuthorityBefore = ui and type(ui.GetAuthoritySnapshot) == "function" and ui:GetAuthoritySnapshot() or nil
    local sequenceRegistryBefore = ui and type(ui.GetRegistrySnapshot) == "function" and ui:GetRegistrySnapshot() or nil
    local sequences
    local registeredSequenceCount = #(self.sequenceOrder or {})
    if options.skipSequences == true then
        sequences = { total = registeredSequenceCount, passed = 0, failed = 0, failures = {}, skipped = true, registered = registeredSequenceCount }
    else
        sequences = self:RunSequences()
        sequences.registered = registeredSequenceCount
        self.lastSequences = sequences
    end
    report.sequences = sequences
    local sequenceAuthorityAfter = ui and type(ui.GetAuthoritySnapshot) == "function" and ui:GetAuthoritySnapshot() or nil
    local sequenceRegistryAfter = ui and type(ui.GetRegistrySnapshot) == "function" and ui:GetRegistrySnapshot() or nil
    if v3HostRegistered then
        AddCheck(report, "sequence_authority_clean",
            sequenceAuthorityBefore ~= nil and sequenceAuthorityAfter ~= nil
                and (tonumber(sequenceAuthorityAfter.violations) or 0) == (tonumber(sequenceAuthorityBefore.violations) or 0)
                and (tonumber(sequenceAuthorityAfter.conflicts) or 0) == (tonumber(sequenceAuthorityBefore.conflicts) or 0)
                and sequenceRegistryBefore ~= nil and sequenceRegistryAfter ~= nil
                and (tonumber(sequenceRegistryAfter.v3Duplicates) or 0) == (tonumber(sequenceRegistryBefore.v3Duplicates) or 0),
            "blocker", "viol+=" .. tostring((tonumber(sequenceAuthorityAfter and sequenceAuthorityAfter.violations) or 0) - (tonumber(sequenceAuthorityBefore and sequenceAuthorityBefore.violations) or 0))
                .. "/conflict+=" .. tostring((tonumber(sequenceAuthorityAfter and sequenceAuthorityAfter.conflicts) or 0) - (tonumber(sequenceAuthorityBefore and sequenceAuthorityBefore.conflicts) or 0))
                .. "/iddup+=" .. tostring((tonumber(sequenceRegistryAfter and sequenceRegistryAfter.v3Duplicates) or 0) - (tonumber(sequenceRegistryBefore and sequenceRegistryBefore.v3Duplicates) or 0)))
    end
    if sequences.failed > 0 then
        AddCheck(report, "sequence_harness", false, "blocker",
            "cases=" .. tostring(sequences.total) .. "/pass=" .. tostring(sequences.passed) .. "/fail=" .. tostring(sequences.failed))
    elseif v3HostRegistered and registeredSequenceCount == 0 then
        AddCheck(report, "sequence_harness", false, "blocker", "v3 host registered but no sequence cases")
    elseif registeredSequenceCount == 0 then
        AddCheck(report, "sequence_harness", false, "warning", "waiting_for_v3_host")
    elseif sequences.skipped == true then
        AddCheck(report, "sequence_harness", true, "blocker",
            "registered=" .. tostring(registeredSequenceCount) .. "/live_run=disabled")
    else
        AddCheck(report, "sequence_harness", true, "blocker",
            "cases=" .. tostring(sequences.total) .. "/pass=" .. tostring(sequences.passed) .. "/fail=0")
    end

    report.status = report.blockers == 0 and "READY" or "BLOCKED"
    self.last = report
    return report
end

function G:GetLastSummary()
    local r = self.last
    if type(r) ~= "table" then return "未运行" end
    return (tostring(r.status) == "READY" and "正常" or "阻断") .. " · 阻断 " .. tostring(r.blockers or 0) .. " · 警告 " .. tostring(r.warnings or 0)
end

function G:BuildCopyText(runNow)
    local r = runNow ~= false and self:Run({ skipSequences = true }) or self.last
    if type(r) ~= "table" then return "新版基础框架｜未运行" end
    local statusText = tostring(r.status) == "READY" and "正常" or "阻断"
    local parts = { "新版基础框架｜" .. statusText .. " · 阻断 " .. tostring(r.blockers) .. " · 警告 " .. tostring(r.warnings) }
    local failed = {}
    for _, row in ipairs(r.checks or {}) do
        if not row.ok then failed[#failed+1] = row.id .. "[" .. row.detail .. "]" end
    end
    if #failed > 0 then parts[#parts+1] = "未通过：" .. Join(failed, 8) end
    local static = S.StaticDataV2 and S.StaticDataV2:Describe() or nil
    local persistence = S.Persistence and S.Persistence:Describe() or nil
    local authority = S.UI and type(S.UI.GetAuthoritySnapshot)=="function" and S.UI:GetAuthoritySnapshot() or nil
    local uiRegistry = S.UI and type(S.UI.GetRegistrySnapshot)=="function" and S.UI:GetRegistrySnapshot() or nil
    local trade = r.tradeStatic or (S.Data and S.Data.TradeStaticV2 and type(S.Data.TradeStaticV2.Describe)=="function" and S.Data.TradeStaticV2:Describe() or nil)
    local gameData = S.GameDataRegistry and type(S.GameDataRegistry.Validate)=="function" and S.GameDataRegistry:Validate() or nil
    local host = S.UIHostManager and type(S.UIHostManager.Describe)=="function" and S.UIHostManager:Describe() or nil
    parts[#parts+1] = "界面宿主 " .. tostring(host and host.activeId == "v3" and "新版" or host and host.activeId or "?") .. "/契约 " .. tostring(host and host.contractV2 or 0) .. "/导航 " .. tostring(host and host.navigationReady or 0)
    local native = S.NativeCapabilities and type(S.NativeCapabilities.Describe)=="function" and S.NativeCapabilities:Describe() or nil
    local nativeImports = native and native.imports or nil
    parts[#parts+1] = "原生层 " .. tostring(native and native.owner or "?")
        .. "/外部 " .. tostring(native and native.externalGlobalsConsumed or "?")
        .. "/旧助手 " .. tostring(native and native.legacyUiHelpersConsumed or "?")
        .. "/接口 " .. tostring(nativeImports and nativeImports.total or 0)
        .. "/对象 " .. tostring(nativeImports and nativeImports.objects or 0)
    local zones = S.StaticDataV2 and S.StaticDataV2:GetCatalog("zone") or nil
    parts[#parts+1] = "IDs " .. tostring(gameData and gameData.totalRecords or 0) .. "/Zone " .. tostring(zones and #(zones.order or {}) or 0) .. "/封存" .. tostring(gameData and gameData.sealed == true) .. "/违规" .. tostring(gameData and gameData.sealViolations or 0)
    parts[#parts+1] = "Data " .. tostring(static and static.records or 0) .. "条/缺引用" .. tostring(static and static.missingRefs or 0) .. "/缺ID" .. tostring(static and static.missingRequiredIds or 0) .. "/封存" .. tostring(static and static.sealed == true)
    parts[#parts+1] = "跑商 材" .. tostring(trade and trade.materials or 0)
        .. "/货" .. tostring(trade and trade.goods or 0)
        .. "/配" .. tostring(trade and trade.recipes or 0)
        .. "/Craft " .. tostring(trade and trade.primaryCraftIds or 0) .. "/" .. tostring(trade and trade.recipes or 0)
        .. "/引用" .. tostring(trade and trade.totalRecipeCraftIds or 0)
        .. "/配方核验" .. tostring(trade and trade.verifiedIngredientSignatures or 0)
        .. "/失败" .. tostring(trade and trade.ingredientSignatureFailures or 0)
        .. "/地区待核" .. tostring(trade and trade.pendingOriginZones or 0)
        .. "/货物ID" .. tostring(trade and trade.verifiedProductIds or 0) .. "/" .. tostring(trade and trade.goods or 0)
        .. "/待核" .. tostring(trade and trade.pendingProductIds or 0)
        .. "/货物重复" .. tostring(trade and trade.productIdDuplicates or 0)
    local quest = r.questIds or (S.GameIds and S.GameIds.Quest and type(S.GameIds.Quest.Describe)=="function" and S.GameIds.Quest:Describe() or nil)
    parts[#parts+1] = "任务 总" .. tostring(quest and quest.total or 0) .. "/已核" .. tostring(quest and quest.verified or 0) .. "/待核" .. tostring(quest and quest.pending or 0)
    local instance = r.instanceIds or (S.GameIds and S.GameIds.Instance and type(S.GameIds.Instance.Describe)=="function" and S.GameIds.Instance:Describe() or nil)
    parts[#parts+1] = "副本 数据库核验 " .. tostring(instance and instance.databaseVerified or 0)
        .. "/Runtime已核" .. tostring(instance and instance.runtimeVerified or 0)
        .. "/观察" .. tostring(instance and instance.runtimeObserved or 0)
        .. "/冲突" .. tostring(instance and instance.runtimeObservedConflicts or 0)
        .. "/待核" .. tostring(instance and instance.runtimePending or 0)
    parts[#parts+1] = "存档 " .. tostring(persistence and persistence.total or 0) .. "/V2 " .. tostring(persistence and persistence.contractV2 or 0) .. "/V3 " .. tostring(persistence and persistence.contractV3 or 0) .. "/Budget " .. tostring(persistence and persistence.budgetProtected or 0) .. "/Fence " .. tostring(persistence and persistence.fenced or 0)
    parts[#parts+1] = "界面所有权 违规 " .. tostring(authority and authority.violations or 0) .. "/冲突 " .. tostring(authority and authority.conflicts or 0) .. "/编号重复 " .. tostring(uiRegistry and uiRegistry.v3Duplicates or 0)
    local pageInfo = S.UIV3 and S.UIV3.PageHost and type(S.UIV3.PageHost.Describe) == "function" and S.UIV3.PageHost:Describe() or nil
    local factoryInfo = S.NativeObjectFactory and type(S.NativeObjectFactory.Describe) == "function" and S.NativeObjectFactory:Describe() or nil
    local rsuiInfo = S.RSUI and type(S.RSUI.GetSnapshot) == "function" and S.RSUI:GetSnapshot() or nil
    parts[#parts+1] = "界面构建 页面失败 " .. tostring(pageInfo and pageInfo.buildFailures or 0)
        .. "/隔离 " .. tostring(pageInfo and pageInfo.quarantined or 0)
        .. "/Native失败 " .. tostring(factoryInfo and factoryInfo.failures or 0)
        .. "/重复拒绝 " .. tostring(factoryInfo and factoryInfo.duplicateRejects or 0)
        .. "/事务回滚 " .. tostring(rsuiInfo and rsuiInfo.buildScopesRolledBack or 0)
        .. "/闭合恢复 " .. tostring(rsuiInfo and rsuiInfo.buildScopeCloseOrderRecoveries or 0)
        .. "/前检拒绝 " .. tostring(rsuiInfo and rsuiInfo.preflightFailures or 0)
        .. "/事务失败 " .. tostring(rsuiInfo and rsuiInfo.buildTransactionFailures or 0)
        .. "/活动事务 " .. tostring(rsuiInfo and rsuiInfo.activeBuildScopes or 0)

    -- The copy-friendly summary must carry the actual runtime fault, not only an
    -- aggregate "pageQ=2" counter.  This is intentionally bounded to the latest
    -- four warning/error rows so one chat line remains practical to copy from the
    -- ArcheAge client log.
    local diagnostics = S.DiagnosticsManager
    local recentFaults = {}
    if type(diagnostics) == "table" and type(diagnostics.recent) == "table" then
        for index = #diagnostics.recent, 1, -1 do
            local row = diagnostics.recent[index]
            if type(row) == "table" and (row.level == "error" or row.level == "warning") then
                local context = type(row.context) == "table" and row.context or {}
                local detail = tostring(context.error or context.reason or context.detail or context.route or context.id or "")
                detail = detail:gsub("[\r\n]+", " ↳ ")
                if #detail > 130 then detail = detail:sub(1, 127) .. "..." end
                local item = tostring(row.code or "FAULT") .. ":" .. tostring(row.message or "")
                if detail ~= "" then item = item .. "[" .. detail .. "]" end
                recentFaults[#recentFaults + 1] = item
                if #recentFaults >= 4 then break end
            end
        end
    end
    if #recentFaults > 0 then parts[#parts+1] = "最近故障 " .. table.concat(recentFaults, " | ") end
    if r.sequences ~= nil and r.sequences.skipped == true then
        parts[#parts+1] = "序列测试 已登记 " .. tostring(r.sequences.registered or r.sequences.total or 0) .. " · 实机诊断不执行破坏性序列"
    else
        parts[#parts+1] = "序列测试 " .. tostring(r.sequences and r.sequences.passed or 0) .. "/" .. tostring(r.sequences and r.sequences.total or 0)
    end
    if r.sequences ~= nil and tonumber(r.sequences.failed) and r.sequences.failed > 0 then
        parts[#parts+1] = "序列失败 " .. Join(r.sequences.failures or {}, 4)
    end
    return table.concat(parts, " ║ ")
end

function G:PrintReport()
    local text = self:BuildCopyText(true)
    if type(S.SafeChat) == "function" then S.SafeChat(text, self.last and self.last.status == "READY" and "info" or "warning", "foundation") end
    return text
end
