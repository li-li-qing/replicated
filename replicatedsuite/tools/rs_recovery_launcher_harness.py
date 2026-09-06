#!/usr/bin/env python3
"""Execute Recovery R click-vs-drag and fixed logical sizing contracts."""
from __future__ import annotations

import shutil
import subprocess
import tempfile
from pathlib import Path
from rs_lua_runner import RUNNER


def run_lua(source: str) -> subprocess.CompletedProcess[str]:
    texlua = RUNNER
    if texlua is None:
        return subprocess.CompletedProcess([], 0, "RECOVERY_LAUNCHER_HARNESS SKIP | texlua unavailable\n", "")
    with tempfile.NamedTemporaryFile("w", encoding="utf-8", suffix=".lua", delete=False) as handle:
        handle.write(source)
        path = Path(handle.name)
    try:
        return subprocess.run([texlua, str(path)], text=True, capture_output=True)
    finally:
        path.unlink(missing_ok=True)


def main() -> int:
    root = Path(__file__).resolve().parents[1]
    bootstrap = (root / "replicatedsuite.lua").resolve()
    launcher = (root / "presentation/v3/rs_v3_launcher_store.lua").resolve()
    lua = f'''
UIParent = {{}}
assert(loadfile([[{bootstrap}]]))()
local S = assert(ReplicatedSuite)
local checks, passed = 0, 0
local function Check(name, condition)
    checks = checks + 1
    if condition then passed = passed + 1 else error("FAIL:" .. name) end
end

local button = {{ x = 0, y = 0, w = 0, h = 0, handlers = {{}} }}
function button:SetText(value) self.text = value; return true end
function button:SetStyle(_) return true end
function button:SetAutoResize(value) self.autoResize = value; return value end
function button:SetExtent(w, h) self.w, self.h = w, h; return true end
function button:SetWidth(w) self.w = w; return true end
function button:SetHeight(h) self.h = h; return true end
function button:RemoveAllAnchors() return true end
function button:AddAnchor(_, _, x, y) self.x, self.y = x, y; return true end
function button:Enable(value) return value end
function button:EnablePick(value) return value end
function button:Clickable(value) return value end
function button:Show(value) self.visible = value; return value end
function button:SetHandler(name, fn) self.handlers[name] = fn; return true end
function button:EnableDrag(value) return value end
function button:StartMoving() return true end
function button:StopMovingOrSizing() return true end
function button:GetEffectiveOffset() return self.x, self.y end

S.NativeObjectFactory = {{ CreateButton = function() return button end }}
local installed, installErr = S.InstallBootstrapRecoveryEntry()
Check("bootstrap_install", installed == true and installErr == nil)
Check("compact_bootstrap_extent", button.w == 30 and button.h == 30)
Check("bootstrap_auto_resize_disabled", button.autoResize == false)
Check("input_contract_version", tonumber(S.RecoveryLauncherContractVersion) >= 2)

local toggles, placementWrites, dirtyWrites = 0, 0, 0
S.Ready = true
S.Runtime = {{ started = true, escRegistered = true }}
S.UIHostManager = {{ Toggle = function() toggles = toggles + 1; return true end }}
S.UIV3 = {{ LauncherState = {{}}, MarkLauncherStoreDirty = function() dirtyWrites = dirtyWrites + 1; return true end }}
S.Layout = {{
    GetLogicalRect = function(self, _) return button.x, button.y, button.w, button.h end,
    StorePlacement = function(self, target, _) placementWrites = placementWrites + 1; target.x, target.y = button.x, button.y; return button.x, button.y, button.w, button.h end,
    ResolveScreenSnap = function(self, _, x, y) return x, y, false end,
}}

-- RU may emit DragStart/DragStop for a normal click. With no geometry delta the
-- following OnClick must still open the main host exactly once.
button.handlers.OnDragStart()
button.handlers.OnDragStop()
button.handlers.OnClick()
Check("click_survives_zero_delta_drag_callbacks", toggles == 1)
Check("zero_delta_not_marked_ignore", button.rsIgnoreClick ~= true)
Check("zero_delta_does_not_persist_drag", placementWrites == 0 and dirtyWrites == 0)

-- A real drag must suppress only the synthetic click immediately following the
-- drag; the next intentional click opens the host normally.
button.handlers.OnDragStart()
button.x = button.x + 12
button.y = button.y + 4
button.handlers.OnDragStop()
button.handlers.OnClick()
Check("real_drag_suppresses_followup_click", toggles == 1)
Check("real_drag_persists_once", placementWrites == 1 and dirtyWrites == 1)
Check("suppression_consumed_once", button.rsIgnoreClick ~= true)
button.handlers.OnClick()
Check("next_click_after_drag_opens", toggles == 2)

-- Launcher placement is a screen affordance. Suite addonScale must not multiply
-- its extent a second time; client uiScale remains the native scale authority.
local store
S.UIV3 = {{}}
S.RecoveryEntry = button
S.Persistence = {{
    Scope = {{ Account = "account" }}, Lifetime = {{ Permanent = "permanent" }}, V3KeyPrefix = "v3:",
    RegisterV3Store = function(self, value) store = value end,
    GetStore = function(self, _) return store end,
    LoadStore = function() return "empty" end,
    MarkDirty = function() return true end,
}}
local placementCalls, floatingSpec = {{}}, nil
S.Layout = {{
    GetContext = function() return {{ addonScale = 4, uiScale = 1 }} end,
    ApplyPlacement = function(self, _, _, w, h) placementCalls[#placementCalls + 1] = {{ w, h }}; return 0, 0, w, h end,
    RegisterFloating = function(self, _, _, spec) floatingSpec = spec end,
    RegisterScreenSnap = function() return true end,
}}
assert(loadfile([[{launcher}]]))()
Check("launcher_store_load", S.UIV3:EnsureLauncherStoreLoaded() == true)
Check("launcher_apply", S.UIV3:ApplyLauncherPlacement() == true)
Check("addon_scale_not_applied_to_launcher", placementCalls[1][1] == 30 and placementCalls[1][2] == 30)
floatingSpec.onMetricsChanged()
Check("metrics_change_keeps_fixed_logical_size", placementCalls[2][1] == 30 and placementCalls[2][2] == 30)

print("RECOVERY_LAUNCHER_HARNESS PASS " .. tostring(passed) .. "/" .. tostring(checks)
    .. " toggles=" .. tostring(toggles) .. " size=" .. tostring(button.w) .. "x" .. tostring(button.h))
'''
    result = run_lua(lua)
    if result.stdout:
        print(result.stdout.strip())
    if result.stderr:
        print(result.stderr.strip())
    return result.returncode


if __name__ == "__main__":
    raise SystemExit(main())
