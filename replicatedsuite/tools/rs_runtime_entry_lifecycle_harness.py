#!/usr/bin/env python3
"""Execute the generation-local Native ESC registration recovery contract."""
from __future__ import annotations

import shutil
import subprocess
import tempfile
from pathlib import Path
from rs_lua_runner import RUNNER


def main() -> int:
    root = Path(__file__).resolve().parents[1]
    bridge = (root / "native/rs_native_esc_bridge.lua").resolve()
    recovery = (root / "native/rs_native_recovery.lua").resolve()
    texlua = RUNNER
    if texlua is None:
        print("RUNTIME_ENTRY_LIFECYCLE_HARNESS SKIP | texlua unavailable")
        return 0

    lua = f'''
ReplicatedSuite = {{}}
local widgetCalls, triggerCalls, buttonCalls = 0, 0, 0
local failTriggerOnce = true
local failButtonCalls = 2
ADDON = {{}}
function ADDON:RegisterContentWidget(contentId, widget)
    widgetCalls = widgetCalls + 1
    return contentId == 91730 and widget ~= nil
end
function ADDON:RegisterContentTriggerFunc(contentId, trigger)
    triggerCalls = triggerCalls + 1
    if failTriggerOnce then failTriggerOnce = false; return false end
    return contentId == 91730 and type(trigger) == "function"
end
function ADDON:AddEscMenuButton(...)
    buttonCalls = buttonCalls + 1
    if buttonCalls <= failButtonCalls then return false end
    return true
end

assert(loadfile([[{bridge}]]))()
local E = assert(ReplicatedSuite.NativeEscBridge)
local checks, passed = 0, 0
local function Check(name, condition)
    checks = checks + 1
    if condition then passed = passed + 1 else error("FAIL:" .. name) end
end

local widget = {{ id = "suite" }}
local triggerA = function() end
local triggerB = function() end

local ok = E:RegisterContent(91730, widget, triggerA)
Check("partial_content_failure_visible", ok == false)
Check("partial_content_widget_once", widgetCalls == 1 and triggerCalls == 1)

ok = E:RegisterContent(91730, widget, triggerB)
Check("partial_content_retry_success", ok == true and E:IsContentRegistered(91730) == true)
Check("partial_content_retry_skips_widget", widgetCalls == 1 and triggerCalls == 2)

ok = E:RegisterButton(3, 91730, "info", "上古世纪综合辅助")
Check("button_first_attempt_fails", ok == false and buttonCalls == 2)
ok = E:RegisterButton(3, 91730, "info", "上古世纪综合辅助")
Check("button_retry_success", ok == true and buttonCalls == 3)
Check("bridge_ready_after_bounded_retry", E:IsReady(91730) == true)

local beforeWidget, beforeTrigger, beforeButton = widgetCalls, triggerCalls, buttonCalls
Check("complete_content_reuse", E:RegisterContent(91730, widget, function() end) == true)
Check("complete_button_reuse", E:RegisterButton(3, 91730, "info", "上古世纪综合辅助") == true)
Check("complete_reuse_has_no_native_calls", widgetCalls == beforeWidget and triggerCalls == beforeTrigger and buttonCalls == beforeButton)

local otherWidget = {{ id = "other" }}
Check("same_generation_identity_collision_rejected", E:RegisterContent(91730, otherWidget, function() end) == false)
Check("boolean_visibility_true", E:ResolveVisibility(true, false) == true)
Check("string_visibility_false", E:ResolveVisibility("off", true) == false)
Check("unknown_visibility_toggles", E:ResolveVisibility(nil, true) == false)

local info = E:Describe(91730)
Check("describe_contract", info.version >= 2 and info.idempotentRegistrationContractVersion >= 1)
Check("describe_retry_evidence", info.partialRetries >= 2 and info.reuses >= 2)
Check("describe_ready", info.requestedReady == true)

local recoveryChats = {{}}
ReplicatedSuite = {{
    InstallBootstrapRecoveryEntry = function() return false, "left-click binding unavailable" end,
    SafeChat = function(message) recoveryChats[#recoveryChats + 1] = tostring(message) end,
}}
assert(loadfile([[{recovery}]]))()
Check("recovery_logical_false_is_observed", #recoveryChats == 1 and string.find(recoveryChats[1], "left%-click binding unavailable") ~= nil)
Check("recovery_failure_does_not_poison_runtime_boot", ReplicatedSuite.BootError == nil)
Check("recovery_failure_is_diagnostic", ReplicatedSuite.RecoveryEntryHealthy == false and ReplicatedSuite.RecoveryEntryError == "left-click binding unavailable")

print("RUNTIME_ENTRY_LIFECYCLE_HARNESS PASS " .. tostring(passed) .. "/" .. tostring(checks)
    .. " widget=" .. tostring(widgetCalls) .. " trigger=" .. tostring(triggerCalls) .. " button=" .. tostring(buttonCalls)
    .. " partialRetry=" .. tostring(info.partialRetries) .. " reuse=" .. tostring(info.reuses))
'''
    with tempfile.NamedTemporaryFile("w", encoding="utf-8", suffix=".lua", delete=False) as handle:
        handle.write(lua)
        temp = Path(handle.name)
    try:
        result = subprocess.run([texlua, str(temp)], text=True, capture_output=True)
    finally:
        temp.unlink(missing_ok=True)
    if result.stdout:
        print(result.stdout.strip())
    if result.stderr:
        print(result.stderr.strip())
    return result.returncode


if __name__ == "__main__":
    raise SystemExit(main())
