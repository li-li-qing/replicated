#!/usr/bin/env python3
"""Exercise bootstrap recovery command input without relying on V3 Host/ESC/chat slash APIs."""
from __future__ import annotations

import shutil
import subprocess
import tempfile
from pathlib import Path
from rs_lua_runner import RUNNER


def run_lua(source: str) -> subprocess.CompletedProcess[str]:
    texlua = RUNNER
    if texlua is None:
        return subprocess.CompletedProcess([], 0, "RECOVERY_COMMAND_HARNESS SKIP | texlua unavailable\n", "")
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
    runtime = (root / "core/rs_runtime.lua").resolve()
    source = bootstrap.read_text(encoding="utf-8-sig", errors="replace")
    runtime_source = runtime.read_text(encoding="utf-8-sig", errors="replace")

    static_checks = {
        "no_slashcmdlist": "SlashCmdList" not in source,
        "no_get_chat_commands": "GetChatCommands" not in source,
        "no_recovery_polling": 'SetHandler("OnUpdate"' not in source[source.find("function S.InstallRecoveryCommandBar()"):source.find("local function ReadRecoveryPosition")],
        "verified_enter_event_only": 'edit.SetHandler, edit, "OnEnterPressed", SubmitRecoveryCommand' in source and "OnEditEnter" not in source[source.find("function S.InstallRecoveryCommandBar()\n"):source.find("local function ReadRecoveryPosition")],
        "runtime_shows_on_failure": "S.SetRecoveryCommandBarVisible(true)" in runtime_source,
        "runtime_hides_on_ready": "S.SetRecoveryCommandBarVisible(false)" in runtime_source,
    }
    for name, passed in static_checks.items():
        if not passed:
            print(f"RECOVERY_COMMAND_HARNESS FAIL static:{name}")
            return 1

    lua = f'''
UIParent = {{}}
assert(loadfile([[{bootstrap}]]))()
local S = assert(ReplicatedSuite)
local checks, passed = 0, 0
local function Check(name, condition)
    checks = checks + 1
    if condition then passed = passed + 1 else error("FAIL:" .. name) end
end

local bar = {{ handlers = {{}}, visible = false }}
function bar:SetCloseOnEscape(_) return true end
function bar:SetWindowModal(_) return true end
function bar:SetUILayer(_) return true end
function bar:SetExtent(w, h) self.w, self.h = w, h; return true end
function bar:RemoveAllAnchors() return true end
function bar:AddAnchor(_, _, x, y) self.x, self.y = x, y; return true end
function bar:Enable(value) return value end
function bar:EnablePick(value) return value end
function bar:Show(value) self.visible = value == true; return self.visible end
function bar:CreateColorDrawable() return {{ AddAnchor = function() return true end }} end

local label = {{}}
function label:SetExtent(w, h) self.w, self.h = w, h; return true end
function label:SetText(value) self.text = value; return true end
function label:AddAnchor(...) return true end
function label:Show(value) self.visible = value; return value end

local edit = {{ handlers = {{}}, text = "" }}
function edit:SetExtent(w, h) self.w, self.h = w, h; return true end
function edit:SetInset(...) return true end
function edit:Enable(value) return value end
function edit:EnableFocus(value) self.focusEnabled = value == true; return value end
function edit:ClearFocus() self.focusCleared = true; return true end
function edit:EnableKeyboard(value) self.keyboardEnabled = value == true; return value end
function edit:EnablePick(value) return value end
function edit:Clickable(value) return value end
function edit:SetReClickable(value) return value end
function edit:SetReadOnly(value) self.readOnly = value; return not value end
function edit:UseSelectAllWhenFocused(value) return value end
function edit:SetMaxTextLength(value) self.maxLength = value; return true end
function edit:SetText(value) self.text = tostring(value or ""); return true end
function edit:GetText() return self.text end
function edit:AddAnchor(...) return true end
function edit:Show(value) self.visible = value; return value end
function edit:SetHandler(name, fn) self.handlers[name] = fn; return true end

S.NativeObjectFactory = {{
    CreateWindow = function(_, _, _, _) return bar end,
    CreateChildByObject = function(_, _, objectName, _, _, _)
        if objectName == "LABEL" then return label end
        if objectName == "X2_EDITBOX" then return edit end
        return nil
    end,
}}

local setCalls, lastConsoleValue = 0, nil
X2Option = {{
    GetConsoleVariable = function(_, key) Check("reload_reads_vsync", key == "r_VSync"); return "1" end,
    SetConsoleVariable = function(_, key, value)
        Check("reload_writes_vsync", key == "r_VSync")
        setCalls = setCalls + 1
        lastConsoleValue = value
        return true
    end,
}}
S.Persistence = {{ Flush = function() return true end }}

S.Ready = false
local installed, installErr = S.InstallRecoveryCommandBar()
Check("command_contract_version", tonumber(S.RecoveryCommandContractVersion) >= 2)
Check("command_bar_install", installed == true and installErr == nil)
Check("command_bar_bootstrap_hidden", bar.visible == false)
Check("command_edit_bootstrap_keyboard_inert", edit.keyboardEnabled == false and edit.focusEnabled == false)
Check("input_isolation_contract", tonumber(S.RecoveryInputIsolationContractVersion) >= 1)
Check("command_bar_compact_size", bar.w == 174 and bar.h == 30)
Check("command_edit_exists", bar.edit == edit and edit.visible == true)
Check("enter_handler_bound", type(edit.handlers.OnEnterPressed) == "function")
Check("unverified_enter_handler_absent", edit.handlers.OnEditEnter == nil)
Check("explicit_show_arms_keyboard", S.SetRecoveryCommandBarVisible(true) == true and bar.visible == true and edit.keyboardEnabled == true and edit.focusEnabled == true)

edit:SetText(" /RSRELOAD ")
local submitResult = edit.handlers.OnEnterPressed()
Check("enter_executes_reload", submitResult == true and setCalls == 1 and lastConsoleValue == "0")
Check("input_cleared_before_reload", edit:GetText() == "")

-- A broken persistence Store must not deadlock the recovery path that loads the
-- file containing its fix. Recovery reload still attempts Flush once, records
-- the failure, warns, and continues. Explicit strict durability remains gated.
S.Persistence = {{ Flush = function() return false, {{ "v3.test:injected_save_failure" }} end }}
local recoveryAfterSaveFailure = S.ReloadCodeFromDisk("harness_recovery")
Check("flush_failure_does_not_block_recovery_reload", recoveryAfterSaveFailure == true and setCalls == 2)
Check("flush_failure_evidence_retained", type(S.LastReloadFlushFailure) == "table"
    and string.find(tostring(S.LastReloadFlushFailure.detail), "v3.test:injected_save_failure", 1, true) ~= nil)
local strictAfterSaveFailure = S.ReloadCodeFromDisk("harness_strict", {{ requireDurable = true }})
Check("strict_durability_still_blocks", strictAfterSaveFailure == false and setCalls == 2)

local toggles = 0
S.Ready = true
S.Runtime = {{ started = true, escRegistered = true }}
S.UIHostManager = {{ Toggle = function() toggles = toggles + 1; return true end }}
Check("open_command", S.ExecuteRecoveryCommand("open") == true and toggles == 1)
Check("diag_command", S.ExecuteRecoveryCommand("diag") == true)
Check("help_command", S.ExecuteRecoveryCommand("help") == true)
local unknown, unknownErr = S.ExecuteRecoveryCommand("does-not-exist")
Check("unknown_fails_closed", unknown == false and unknownErr == "unknown_command")

-- Show(false) may legitimately return false because it is the resulting native
-- state. Visibility transport must still be considered successful.
Check("hide_false_state_is_success", S.SetRecoveryCommandBarVisible(false) == true and bar.visible == false)
Check("hide_disarms_keyboard", edit.keyboardEnabled == false and edit.focusEnabled == false)
Check("show_again", S.SetRecoveryCommandBarVisible(true) == true and bar.visible == true)

print("RECOVERY_COMMAND_HARNESS PASS " .. tostring(passed) .. "/" .. tostring(checks)
    .. " reloads=" .. tostring(setCalls) .. " toggles=" .. tostring(toggles))
'''
    result = run_lua(lua)
    if result.stdout:
        print(result.stdout.strip())
    if result.stderr:
        print(result.stderr.strip())
    return result.returncode


if __name__ == "__main__":
    raise SystemExit(main())
