#!/usr/bin/env python3
"""Execute startup degradation/fatal-boundary contracts for Replicated Suite V3."""
from __future__ import annotations

import shutil
import subprocess
import tempfile
from pathlib import Path
from rs_lua_runner import RUNNER


def run_lua(source: str) -> subprocess.CompletedProcess[str]:
    texlua = RUNNER
    if texlua is None:
        return subprocess.CompletedProcess([], 0, "STARTUP_FAULT_ISOLATION_HARNESS SKIP | texlua unavailable\n", "")
    with tempfile.NamedTemporaryFile("w", encoding="utf-8", suffix=".lua", delete=False) as handle:
        handle.write(source)
        temp = Path(handle.name)
    try:
        return subprocess.run([texlua, str(temp)], text=True, capture_output=True)
    finally:
        temp.unlink(missing_ok=True)


def main() -> int:
    root = Path(__file__).resolve().parents[1]
    app = (root / "core/rs_app_state_v3.lua").resolve()
    launcher = (root / "presentation/v3/rs_v3_launcher_store.lua").resolve()
    shell = (root / "presentation/v3/rs_v3_shell_store.lua").resolve()
    runtime = (root / "core/rs_runtime.lua").resolve()

    lua = f'''
local checks, passed = 0, 0
local function Check(name, condition)
    checks = checks + 1
    if condition then passed = passed + 1 else error("FAIL:" .. name) end
end

-- Persistence-backed Foundation/session state must fall back to safe defaults
-- rather than removing the entire application shell from the user.
local stores, warnings = {{}}, {{}}
local markDirtyCalls, mutateCalls = 0, 0
ReplicatedSuite = {{
    Persistence = {{
        Scope = {{ Account = "account" }}, Lifetime = {{ Permanent = "permanent" }}, V3KeyPrefix = "v3:",
        GetStore = function(self, id) return stores[id] end,
        RegisterV3Store = function(self, spec) stores[spec.id] = spec; return spec end,
        LoadStore = function(self, id) return false, nil, "simulated_corrupt:" .. tostring(id) end,
        MarkDirty = function() markDirtyCalls = markDirtyCalls + 1; return false, "write_fenced" end,
        MutateStore = function() mutateCalls = mutateCalls + 1; return false, "write_fenced" end,
    }},
    DiagnosticsManager = {{ Warn = function(self, source, code, message, context) warnings[#warnings + 1] = code end }},
}}
assert(loadfile([[{app}]]))()
local A = assert(ReplicatedSuite.AppState)
Check("app_fallback_loads", A:EnsureLoaded() == true)
Check("app_fallback_flag", A.sessionFallback == true and A.loaded == true)
Check("app_fallback_defaults", A.settings.addonScale == 1 and A.settings.fontScale == 1 and A.settings.appearance == "dark")
Check("app_fallback_session_mutation", A:Set("addonScale", 1.1, true) == true and A.settings.addonScale == 1.1 and mutateCalls == 0)

ReplicatedSuite.UIV3 = {{}}
assert(loadfile([[{launcher}]]))()
local V3 = ReplicatedSuite.UIV3
Check("launcher_fallback_loads", V3:EnsureLauncherStoreLoaded() == true)
Check("launcher_fallback_flag", V3.LauncherStoreSessionFallback == true and V3.LauncherStoreLoaded == true)
Check("launcher_fallback_default_position", V3.LauncherState.userMoved ~= true and V3.LauncherState.x == nil and V3.LauncherState.y == nil)
Check("launcher_fallback_no_persist", V3:MarkLauncherStoreDirty(0, "drag") == true and markDirtyCalls == 0)

assert(loadfile([[{shell}]]))()
Check("shell_fallback_loads", V3:EnsureShellStoreLoaded() == true)
Check("shell_fallback_flag", V3.ShellStoreSessionFallback == true and V3.ShellStoreLoaded == true)
Check("shell_fallback_default_state", V3.ShellState.width == 1040 and V3.ShellState.height == 700 and V3.ShellState.userMoved ~= true)
Check("shell_fallback_no_persist", V3:MarkShellStoreDirty(0, "route_changed") == true and markDirtyCalls == 0)
Check("fallback_diagnostics_visible", #warnings >= 3)

-- Runtime optional Feature failures are degradations, not Core startup blockers.
local diagnosticRows = {{}}
local window = {{ IsVisible = function() return false end, Raise = function() return true end }}
ReplicatedSuite = {{
    SafeTraceback = function(err) return tostring(err) end,
    SafeChat = function() end,
    WarnOnce = function() end,
    Generation = 1,
    Constants = {{ Refresh = {{ layoutMs = 250, storageMs = 500 }} }},
    Api = {{ Validate = function() return true end }},
    AppState = {{ EnsureLoaded = function() return true end }},
    Layout = {{ Invalidate = function() end, PrimeCurrentSignature = function() end, PollChanges = function() end }},
    UIV3 = {{ EnsureLauncherStoreLoaded = function() return true end, ApplyLauncherPlacement = function() return true end }},
    UIHostManager = {{
        IsRegistered = function(self, id) return id == "v3" end,
        Ensure = function(self, id) return id == "v3" and {{ id = "v3" }} or nil end,
        GetWindow = function() return window end,
        RefreshData = function() return true end,
        ApplyResponsiveLayout = function() return true end,
        HideAll = function() return true end,
    }},
    Events = {{ Start = function() return true end, Stop = function() return true end }},
    Scheduler = {{
        AddTask = function() return true end,
        RemoveTask = function() return true end,
        Start = function() return true end,
        Stop = function() return true end,
        AddOneShot = function() return true end,
    }},
    FeatureRuntime = {{
        EnableDefaults = function() return false, "combat_gear:simulated_feature_failure" end,
        DisableAll = function() return true end,
        RefreshEnabled = function() return true end,
    }},
    NativeEscBridge = {{
        IsReady = function() return true end,
        Describe = function() return {{ version = 2, requestedReady = true }} end,
    }},
    DiagnosticsManager = {{ Emit = function(self, level, source, code, message, context) diagnosticRows[#diagnosticRows + 1] = {{ level=level, code=code, context=context }} end }},
}}
assert(loadfile([[{runtime}]]))()
Check("feature_failure_does_not_block_ready", ReplicatedSuite.Ready == true and ReplicatedSuite.Runtime.started == true)
Check("feature_failure_marks_degraded", ReplicatedSuite.Runtime.startupDegraded == true and #ReplicatedSuite.Runtime.startupWarnings == 1)
Check("feature_failure_keeps_booterror_clear", ReplicatedSuite.BootError == nil and ReplicatedSuite.BootStage == "ready")
local sawDegraded = false
for _, row in ipairs(diagnosticRows) do if row.code == "RUNTIME_STARTUP_DEGRADED" then sawDegraded = true end end
Check("feature_failure_diagnostic", sawDegraded == true)

print("STARTUP_FAULT_ISOLATION_HARNESS PASS " .. tostring(passed) .. "/" .. tostring(checks))
'''
    result = run_lua(lua)
    if result.stdout:
        print(result.stdout.strip())
    if result.stderr:
        print(result.stderr.strip())
    return result.returncode


if __name__ == "__main__":
    raise SystemExit(main())
