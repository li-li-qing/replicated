#!/usr/bin/env python3
"""Runtime-ish contract harness for RSUI Interactive Draft + LayoutEditor drawer affordance."""
from __future__ import annotations
import pathlib
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
CONTROLS = ROOT / "ui/framework/rs_ui_controls.lua"
FORMS = ROOT / "ui/framework/rs_ui_forms.lua"
WORKSPACE = ROOT / "ui/framework/rs_ui_workspace_templates.lua"
BUFF = ROOT / "presentation/v3/pages/rs_v3_buff_display_page.lua"
PRIMITIVES = ROOT / "ui/rs_ui_native_primitives.lua"
UI_FRAMEWORK = ROOT / "ui/rs_ui_framework.lua"
NATIVE_ADAPTER = ROOT / "presentation/v3/rs_v3_native_adapter.lua"
APP_SHELL = ROOT / "presentation/v3/rs_v3_shell.lua"
COMPONENT_CORE = ROOT / "ui/framework/rs_ui_component_core.lua"
PRIMITIVE_COMPONENTS = ROOT / "ui/framework/rs_ui_primitives.lua"
WIDGET_HOST = ROOT / "presentation/v3/widgets/rs_v3_widget_host.lua"
INTERACTIONS = ROOT / "ui/framework/rs_ui_interactions.lua"
WINDOWING = ROOT / "ui/framework/rs_ui_windowing.lua"
WINDOW_SHELL = ROOT / "ui/framework/rs_ui_window_shell_v3.lua"
FLOATING_SURFACE = ROOT / "ui/framework/rs_ui_floating_surface.lua"
MODAL_HOST = ROOT / "presentation/v3/shell/rs_v3_modal_host.lua"
LAYOUT_TEMPLATES = ROOT / "ui/framework/rs_ui_layout_templates.lua"


def require_source(path: pathlib.Path, tokens: tuple[str, ...]) -> None:
    source = path.read_text(encoding="utf-8-sig", errors="replace")
    for token in tokens:
        if token not in source:
            raise AssertionError(f"missing source contract {path.name}: {token}")


def forbid_source(path: pathlib.Path, tokens: tuple[str, ...]) -> None:
    source = path.read_text(encoding="utf-8-sig", errors="replace")
    for token in tokens:
        if token in source:
            raise AssertionError(f"forbidden source regression {path.name}: {token}")


def run_lua() -> None:
    controls = str(CONTROLS).replace("\\", "/")
    lua = f'''
local factories = {{}}
local metrics = {{ interactiveDraftRenderSuppressions = 0 }}
local function binding(spec)
    local b = {{ value = spec.value, spec = spec }}
    function b:Get() if type(self.spec.get) == "function" then return self.spec.get() end return self.value end
    function b:Set(v, final, source)
        if type(self.spec.set) == "function" then
            local ok, err = self.spec.set(v, final, source)
            if ok == false then return false, err end
        else self.value = v end
        return true
    end
    function b:Commit() return true end
    return b
end
local RSUI = {{ metrics = metrics, types = {{}} }}
function RSUI:RegisterType(name, fn) factories[name] = fn; self.types[name] = fn end
function RSUI:RegisterTypeValidator() end
function RSUI:Binding(spec) return binding(spec) end
function RSUI:_Count() end
function RSUI:Callback(_, fn, ...) if type(fn) ~= "function" then return true end return true, fn(...) end
function RSUI:NewComponent(kind, spec, root)
    local c = {{ kind=kind, spec=spec, id=spec.id, root=root, owner="harness", enabled=true, released=false }}
    function c:On(native, event, fn) native.handlers = native.handlers or {{}}; native.handlers[event] = fn; return true end
    function c:RequireOn(native, event, fn) return self:On(native, event, fn) end
    function c:SetEnabled(v) self.enabled = v ~= false; return self.enabled end
    function c:Release() self.released=true; return 1 end
    return c
end
RSUI.Focus = {{}}
function RSUI.Focus:IsFocused(native) return native and native.focused == true end
local UI = {{}}
local function editbox()
    local n={{text="", focused=false, handlers={{}}}}
    function n:GetText() return self.text end
    function n:SetText(v) self.text=tostring(v or "") end
    return n
end
function UI:CreateEditBox() return editbox() end
function UI:SetText(native, text) native:SetText(text); return true end
function UI:CreateSlider(_, id, x, y, w, h, minv, maxv, step, initial)
    local n={{ value=initial, rsDragging=false, handlers={{}} }}
    function n:GetValue() return self.value end
    function n:SetValue(v, notify) self.value=v; return v end
    function n:SetValueChangedHandler(fn) self.handler=fn end
    return n
end
function UI:CreateButton()
    local n={{text="", handlers={{}}}}
    function n:SetText(v) self.text=tostring(v or "") end
    return n
end
function UI:SetButtonActive(native, value) native.active=value == true; return true end
ReplicatedSuite = {{ UI=UI, RSUI=RSUI, Scheduler=nil }}
assert(loadfile([[{controls}]]))()

local committedText = "abcdef"
local t = assert(factories.TextInput({{id="t", parent={{}}, value=committedText, get=function() return committedText end, set=function(v) committedText=v; return true end}}))
t.root.focused=true; t.root.text="abcde"; t:Render(nil, "binding_refresh")
assert(t.root.text=="abcde", "TextInput ambient refresh clobbered focused draft")
t.root.focused=false; t:Render(nil, "binding_refresh")
assert(t.root.text=="abcdef", "TextInput did not resync after focus ended")

local committedNumber = 100
local n = assert(factories.NumericInput({{id="n", parent={{}}, min=0, max=2000, step=1, integer=true, unit="ms", value=100, get=function() return committedNumber end, set=function(v) committedNumber=v; return true end}}))
n.root.focused=true; n.root.text="10"; n:Render(100, "binding_refresh")
assert(n.root.text=="10", "NumericInput ambient refresh clobbered focused draft")
n:Submit("edit")
assert(committedNumber==10 and n.root.text=="10ms", "NumericInput commit did not own final render")

local committedSlider = 100
local s = assert(factories.Slider({{id="s", parent={{}}, min=0, max=2000, step=25, value=100, get=function() return committedSlider end, set=function(v) committedSlider=v; return true end}}))
s.root.rsDragging=true; s:Preview(500, "slider"); s:Render(100, "binding_refresh")
assert(s.root.value==500, "Slider ambient refresh clobbered active preview")
s:Render(100, "commit")
assert(s.root.value==100, "Slider explicit commit did not override preview")
assert((metrics.interactiveDraftRenderSuppressions or 0) >= 3, "draft suppression metric not recorded")

-- Rejected writes are transactions too: the control must roll its visual state
-- back to the authoritative binding and must not publish onChanged.
local toggleValue, toggleChanged = false, 0
local tg = assert(factories.Toggle({{id="tg", parent={{}}, value=false, get=function() return toggleValue end,
    set=function() return false, "reject" end, onChanged=function() toggleChanged=toggleChanged+1 end}}))
assert(tg:SetValue(true, "harness") == false, "Toggle rejected write reported success")
assert(tg.root.active == false and toggleValue == false and toggleChanged == 0, "Toggle rejection leaked visual/callback state")

local rejectText, textChanged = "keep", 0
local rt = assert(factories.TextInput({{id="rt", parent={{}}, value=rejectText, get=function() return rejectText end,
    set=function() return false, "reject" end, onChanged=function() textChanged=textChanged+1 end}}))
rt.root.focused=true; rt.root.text="draft"
assert(rt:SetValue("bad", true, "harness") == false, "TextInput rejected write reported success")
assert(rt.root.text=="keep" and rejectText=="keep" and textChanged==0, "TextInput rejection did not restore authoritative state")

local rejectNumber, numberChanged = 42, 0
local rn = assert(factories.NumericInput({{id="rn", parent={{}}, min=0,max=100,step=1,integer=true,unit="ms", value=42,
    get=function() return rejectNumber end, set=function() return false, "reject" end, onChanged=function() numberChanged=numberChanged+1 end}}))
rn.root.focused=true; rn.root.text="99"
assert(rn:Submit("harness") == false, "NumericInput rejected write reported success")
assert(rn.root.text=="42ms" and rejectNumber==42 and numberChanged==0, "NumericInput rejection did not restore authoritative state")

local rejectSlider, sliderChanged = 100, 0
local rs = assert(factories.Slider({{id="rs", parent={{}}, min=0,max=1000,step=25,value=100, get=function() return rejectSlider end,
    set=function() return false, "reject" end, onChanged=function() sliderChanged=sliderChanged+1 end}}))
rs.root.rsDragging=true; assert(rs:Preview(500, "harness") == true)
assert(rs:CommitValue(500, "harness") == false, "Slider rejected write reported success")
assert(rs.root.value==100 and rejectSlider==100 and sliderChanged==0, "Slider rejection did not restore authoritative state")
print("INTERACTIVE_DRAFT_LUA PASS 12/12")
'''
    with tempfile.NamedTemporaryFile("w", suffix=".lua", encoding="utf-8", delete=False) as fh:
        fh.write(lua)
        script = fh.name
    proc = subprocess.run(["texlua", script], capture_output=True, text=True)
    pathlib.Path(script).unlink(missing_ok=True)
    if proc.returncode != 0:
        raise AssertionError((proc.stdout + proc.stderr).strip())
    if "INTERACTIVE_DRAFT_LUA PASS 12/12" not in proc.stdout:
        raise AssertionError(proc.stdout.strip() or "lua harness produced no PASS marker")


def run_foundation_interaction_lua() -> None:
    framework = str(UI_FRAMEWORK).replace("\\", "/")
    native_adapter = str(NATIVE_ADAPTER).replace("\\", "/")
    component_core = str(COMPONENT_CORE).replace("\\", "/")
    lua = f'''
local UI = {{ controls = {{}} }}
ReplicatedSuite = {{
    UI = UI,
    Generation = 1,
    SafeTraceback = function(err) return tostring(err) end,
}}
assert(loadfile([[{framework}]]))()

local rootNativeCalls, adapterCalls = 0, 0
local composite = {{}}
function composite:Enable(value) rootNativeCalls = rootNativeCalls + 1 end
composite.rsUiSetEnabledAdapter = function(self, value)
    adapterCalls = adapterCalls + 1
    self.childEnabled = value
    return true, value
end
assert(UI:SetEnabled(composite, false, "harness") == true, "composite disable did not write")
assert(adapterCalls == 1 and rootNativeCalls == 0 and composite.childEnabled == false,
    "UI:SetEnabled bypassed composite adapter")
assert(UI:SetEnabled(composite, false, "harness") == false and adapterCalls == 1,
    "composite enabled cache did not suppress duplicate write")

local noPick = {{}}
assert(UI:SetPickable(noPick, true, "harness") == false, "unsupported pickable widget reported success")
assert(UI.NativeStateCache[noPick].pickable == nil, "unsupported pickable state poisoned diff cache")

local picked = {{ calls = 0 }}
function picked:EnablePick(value) self.calls = self.calls + 1; self.last = value end
assert(UI:SetPickable(picked, true, "harness") == true, "supported pickable widget did not write")
assert(picked.calls == 1 and picked.last == true, "pickable native write mismatch")

-- RU Native boolean setters may return the applied state rather than a
-- success flag. A false return while applying false must not be classified as
-- a rejected call; this exact ambiguity blocked the V3 root during .18.103.
local falseState = {{ visible = true, enabled = true, pickable = true }}
function falseState:Show(value) self.visible = value; return value end
function falseState:IsVisible() return self.visible end
function falseState:Enable(value) self.enabled = value; return value end
function falseState:EnablePick(value) self.pickable = value; return value end
function falseState:Clickable(value) self.clickable = value; return value end
assert(UI:SetVisible(falseState, false, "harness") == true and falseState.visible == false,
    "false-return visibility setter was misclassified as rejection")
assert(UI:SetEnabled(falseState, false, "harness") == true and falseState.enabled == false,
    "false-return enabled setter was misclassified as rejection")
assert(UI:SetPickable(falseState, false, "harness") == true and falseState.pickable == false,
    "false-return pickable setter was misclassified as rejection")
local vetoAdapter = {{}}
vetoAdapter.rsUiSetEnabledAdapter = function(self, value) return false end
assert(UI:SetEnabled(vetoAdapter, false, "harness") == false
        and UI.NativeStateCache[vetoAdapter].enabled == nil,
    "explicit Lua composite enabled veto was confused with Native false-state return")

-- Reproduce the real startup shape: the recovery R uses true-state setters,
-- while the main V3 root is initialized hidden/non-pickable and disables
-- Native escape/modal policy with false. All of those calls may return their
-- resulting false state on RU and must still permit root construction.
UI.Register = function(self, logicalId, widget) self.controls[logicalId] = widget; return widget end
ReplicatedSuite.PhysicalId = function(id) return tostring(id) end
ReplicatedSuite.NativeObjectFactory = {{}}
function ReplicatedSuite.NativeObjectFactory:CreateWindow(id, parent, template)
    local root = {{ visible = true }}
    function root:Enable(value) self.enabled = value; return value end
    function root:EnablePick(value) self.pickable = value; return value end
    function root:Clickable(value) self.clickable = value; return value end
    function root:Show(value) self.visible = value; return value end
    function root:IsVisible() return self.visible end
    function root:SetUILayer(value) self.layer = value; return value end
    function root:SetCloseOnEscape(value) self.closeOnEscape = value; return value end
    function root:SetWindowModal(value) self.modal = value; return value end
    return root
end
assert(loadfile([[{native_adapter}]]))()
local root, rootErr = ReplicatedSuite.UIV3NativeAdapter:CreateRootWindow("harness_root", "v3:harness")
assert(root ~= nil, "V3 root rejected valid false-return Native setters: " .. tostring(rootErr))
assert(root.pickable == false and root.visible == false and root.closeOnEscape == false and root.modal == false,
    "V3 root false-state policy was not established")

-- Component-core behavior is tested with a deterministic native binding stub;
-- rs_ui_native_primitives owns the production SafeHandler implementation.
function UI:SafeHandler(widget, eventName, fn)
    local result = widget:SetHandler(eventName, fn)
    return result ~= false
end

assert(loadfile([[{component_core}]]))()
local RSUI = ReplicatedSuite.RSUI
local degradedRoot = {{ rsUiDegraded = true }}
assert(RSUI:RegisterType("HarnessDegraded", function(spec)
    return RSUI:NewComponent("HarnessDegraded", spec, degradedRoot)
end) == true)
local component, err = RSUI:Create("HarnessDegraded", {{ id = "degraded_root", parent = {{}} }})
assert(component == nil, "degraded native root escaped RSUI:Create")
assert(string.find(tostring(err), "component_root_unusable:primitive_degraded", 1, true) ~= nil,
    "degraded root failure reason lost")
assert((RSUI.metrics.componentRootRejects or 0) == 1, "degraded root reject metric missing")

local eventRoot = {{}}
local eventComponent = RSUI:NewComponent("HarnessEvent", {{ id = "event_retry", parent = {{}} }}, eventRoot)
local eventWidget = {{ attempts = 0 }}
function eventWidget:SetHandler(name, handler)
    self.attempts = self.attempts + 1
    if self.attempts == 1 then return false end
    self.handler = handler
    return true
end
local firstCalls, secondCalls = 0, 0
assert(eventComponent:On(eventWidget, "OnClick", function() firstCalls = firstCalls + 1 end, "first") == false,
    "first rejected native handler unexpectedly succeeded")
assert(eventComponent:On(eventWidget, "OnClick", function() secondCalls = secondCalls + 1 end, "second") == true,
    "handler retry did not recover")
eventWidget.handler()
assert(firstCalls == 0 and secondCalls == 1, "failed subscription leaked into successful retry")
print("FOUNDATION_INTERACTION_LUA PASS 14/14")
'''
    with tempfile.NamedTemporaryFile("w", suffix=".lua", encoding="utf-8", delete=False) as fh:
        fh.write(lua)
        script = fh.name
    proc = subprocess.run(["texlua", script], capture_output=True, text=True)
    pathlib.Path(script).unlink(missing_ok=True)
    if proc.returncode != 0:
        raise AssertionError((proc.stdout + proc.stderr).strip())
    if "FOUNDATION_INTERACTION_LUA PASS 14/14" not in proc.stdout:
        raise AssertionError(proc.stdout.strip() or "foundation interaction lua harness produced no PASS marker")


def run_widget_host_lua() -> None:
    widget_host = str(WIDGET_HOST).replace("\\", "/")
    lua = r'''
local eventBus = {}
function eventBus:SubscribeInternal(topic, owner, fn) self.callback=fn; return true end
local rsui = {}
function rsui:WithBuildScope(label, fn)
    local value, detail = fn()
    if value == nil or value == false then return false, nil, detail end
    return true, value, detail
end
ReplicatedSuite = {
    Generation=77,
    SafeTraceback=function(err) return tostring(err) end,
    Events=eventBus,
    FeatureRuntime={LifecycleTopic="v3.feature.lifecycle"},
    RSUI=rsui,
}
assert(loadfile([[@@WIDGET_HOST@@]]))()
local W=ReplicatedSuite.UIV3.WidgetHost
assert(W.version >= 14 and W.preferenceInitializationContractVersion >= 1, "WidgetHost preference contract version missing")

local loaded, preferenceCalls, createCalls, showCalls = false, 0, 0, 0
assert(W:Register("ok", {featureId="feature_ok",
    ensurePreferences=function() loaded=true; return true end,
    create=function() createCalls=createCalls+1; return {windowController={}, Show=function(self) showCalls=showCalls+1; return true end, Hide=function() return true end} end,
}) == true)
assert(W:BindFeatureLifecycle("ok", {featureId="feature_ok", enabled=function() return true end, preference=function()
    preferenceCalls=preferenceCalls+1; assert(loaded==true, "preference read before persisted state load"); return true
end}) == true)
W:_OnFeatureLifecycle("feature_ok", "enabled", "harness")
assert(loaded==true and preferenceCalls==1, "Widget lifecycle did not load preferences before preference callback")
assert(createCalls==1 and showCalls==1 and W:IsVisible("ok")==true, "Widget lifecycle did not show preferred widget")

local failedPreferenceCalls=0
assert(W:Register("reject", {featureId="feature_reject", ensurePreferences=function() return false, "load_rejected" end, create=function() error("must not create") end}) == true)
assert(W:BindFeatureLifecycle("reject", {featureId="feature_reject", enabled=function() return true end, preference=function() failedPreferenceCalls=failedPreferenceCalls+1; return true end}) == true)
local beforeFailures=W.stats.lifecycleReactionFailures or 0
W:_OnFeatureLifecycle("feature_reject", "enabled", "harness")
assert(failedPreferenceCalls==0 and W:IsVisible("reject")==false, "failed preference load leaked into lifecycle visibility")
assert((W.stats.lifecycleReactionFailures or 0)==beforeFailures+1, "preference-load failure was not diagnosed")

local manualCreates=0
assert(W:Register("manual", {ensurePreferences=function() return false, "manual_reject" end, create=function() manualCreates=manualCreates+1; return {windowController={}} end}) == true)
local ok=select(1,W:SetVisible("manual", true, {source="harness"}))
assert(ok==false and manualCreates==0 and W:IsVisible("manual")==false, "manual show bypassed preference initialization")
print("WIDGET_HOST_PREFERENCE_LUA PASS 8/8")
'''.replace("@@WIDGET_HOST@@", widget_host)
    with tempfile.NamedTemporaryFile("w", suffix=".lua", encoding="utf-8", delete=False) as fh:
        fh.write(lua)
        script = fh.name
    proc = subprocess.run(["texlua", script], capture_output=True, text=True)
    pathlib.Path(script).unlink(missing_ok=True)
    if proc.returncode != 0:
        raise AssertionError((proc.stdout + proc.stderr).strip())
    if "WIDGET_HOST_PREFERENCE_LUA PASS 8/8" not in proc.stdout:
        raise AssertionError(proc.stdout.strip() or "widget host lua harness produced no PASS marker")


def main() -> int:
    run_lua()
    run_foundation_interaction_lua()
    run_widget_host_lua()
    require_source(FORMS, (
        "RSUI.NumericInlineContractVersion = 4",
        "RSUI.NumericStepPairFallbackContractVersion = 1",
        "buildOptional = true",
        "c.minus, c.plus = nil, nil",
        'SyncControls(Current(), "binding_refresh")',
        'c.input:Render(value, "interaction")',
        'SyncControls(actual, "commit")',
    ))
    require_source(WORKSPACE, (
        "contractVersion = 6",
        "RSUI.LayoutEditorWorkspaceContractVersion = 4",
        'id = id .. "_inspector_toggle"',
        'root:ToggleDrawer(true)',
        'inspectorToggle:SetVisible(drawer)',
    ))
    require_source(BUFF, (
        "autoOpenInspectorOnSelection = true",
        'if layoutWorkspace:GetMode() == "drawer" then layoutWorkspace:SetDrawerOpen(true, true) end',
        'if root.activeTab == "track" then root:Refresh() end',
    ))
    require_source(PRIMITIVES, (
        "NativeInteractionContractVersion = 4",
        "CriticalInteractionDeliveryContractVersion = 1",
        "local NATIVE_BOOLEAN_STATE_SETTERS = {",
        "if not falseStateSetter then return false",
        "function UIX:TryInteractionCall(widget, methodName, ...)",
        "function UIX:RequireHandler(widget, eventName, fn, label)",
        "if ConfigureNativePickable(edit, true) ~= true then error",
        'CallNativeAccepted(edit, "EnableKeyboard", true)',
        "EDITBOX_MULTILINE inherits WidgetBase interaction flags",
        'CallNativeAccepted(edit, "SetReadOnly", false)',
        "slider.rsUiSetEnabledAdapter = ApplySliderEnabled",
        "local dragStartBound = UIX:SafeHandler",
        "local dragStopBound = UIX:SafeHandler",
        "PrimitiveFailureDetail",
        'S.WarnOnce("rsui_bind_failed_"',
        "return FailPrimitive(",
        "visible = true, enabled = true, pickable = true",
    ))
    require_source(UI_FRAMEWORK, (
        "NativeBooleanSetterReturnContractVersion = 1",
        "CompositeEnabledAdapterContractVersion = 2",
        "local enabledAdapter = widget.rsUiSetEnabledAdapter",
        "if calls == 0 then",
    ))
    forbid_source(PRIMITIVES, (
        'if result == false then return false, tostring(methodName) .. "_rejected" end',
    ))
    require_source(NATIVE_ADAPTER, (
        "RootInteractionPolicyContractVersion = 2",
        "SetCloseOnEscape(false) / SetWindowModal(false) may return the applied",
    ))
    require_source(COMPONENT_CORE, (
        "DegradedRootFailClosedContractVersion = 1",
        "EventBindingContractVersion = 1",
        "PostFactoryRejectReleaseContractVersion = 1",
        "local function RejectComponent(reason)",
        "component_root_unusable:",
        "if channel.handlers[index] == subscription then table.remove(channel.handlers, index); break end",
    ))
    require_source(CONTROLS, (
        "RSUI.ControlTransactionContractVersion = 1",
        "RSUI.PopupVisibilityTransactionContractVersion = 1",
        "local function EnsureRawVisible(widget, visible, owner)",
        'self:Render(nil, "rejected")',
        'self:Render(authoritative, "rejected")',
        'if ok and type(spec.onChanged) == "function"',
        'Write(self.binding, nextColor, true, "colorfield_api", spec)',
    ))
    require_source(INTERACTIONS, (
        "RSUI.InteractionServiceContractVersion = 3",
        "RSUI.InteractionPopupVisibilityContractVersion = 1",
        "local function EnsureVisible(widget, visible, owner)",
        "if okA == true and okB == true then",
        "tooltip_handler_pair_required",
        "UI:EnsureEnabled(row.button",
        "local function ApplyFocusInteraction(native, methodName)",
    ))
    require_source(LAYOUT_TEMPLATES, (
        "RSUI.CollapsibleGroupInteractionContractVersion = 2",
        'c:RequireOn(headerHit, "OnClick"',
        'c.rsUiDegradedReason = "collapsible_header_create_failed"',
    ))
    require_source(CONTROLS, (
        "RSUI.DropdownRuntimeInteractionContractVersion = 1",
        "function c:FailDropdownInteraction(reason)",
        "function c:EnsureChildEnabled(widget, desired, role)",
    ))
    require_source(PRIMITIVE_COMPONENTS, (
        "RSUI.ButtonActionContractVersion = 2",
        "function c:SetOnClick(fn)",
        "function c:GetOnClick()",
        "function c:Click(...)",
        'c:RequireOn(button, "OnClick", function(...) return c:Click(...) end',
    ))
    require_source(WIDGET_HOST, (
        "version = 14",
        "preferenceInitializationContractVersion = 2",
        "self.stats.preferenceLoadFailures",
        "local prepared, prepareErr = EnsurePreferences(spec)",
        "V3_WIDGET_PREFERENCE_LOAD_FAILED",
    ))
    require_source(UI_FRAMEWORK, (
        "GeometryStateTransactionContractVersion = 1",
        "function UI:EnsureAnchor",
        "function UI:EnsureExtent",
    ))
    require_source(WINDOWING, (
        "StateMutationTransactionContractVersion = 1",
        "GeometryCallbackTransactionContractVersion = 1",
        "local function EnsureNativeResizing",
        "geometryCallbackRejects",
    ))
    require_source(WINDOW_SHELL, (
        "version = 22",
        "visibilityTransactionContract = 1",
        "stateMutationTransactionContract = 1",
        "stateCallbackTransactionContract = 1",
        "stateCallbackRejects",
    ))
    require_source(APP_SHELL, (
        "Shell.StateMutationTransactionContractVersion = 1",
        "EnsureComponentVisibility",
        "主窗口几何提交失败",
    ))
    require_source(FLOATING_SURFACE, (
        "StateMutationTransactionContractVersion = 1",
        "local function CommitState",
    ))
    require_source(MODAL_HOST, (
        "version = 6",
        "visibilityTransactionContractVersion = 1",
    ))
    print("INTERACTIVE_DRAFT_HARNESS PASS 110/110")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
