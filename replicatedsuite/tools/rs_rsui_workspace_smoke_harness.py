#!/usr/bin/env python3
"""Real-Lua smoke test for LayoutEditorWorkspace construction.

The mock Button intentionally exposes SetVisible/SetText but NOT Show(). This
catches the exact class of regression that previously compiled cleanly and only
failed in the RU client when a workspace called a method outside the common
component contract.
"""
from __future__ import annotations

import pathlib
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
WORKSPACE = ROOT / "ui/framework/rs_ui_workspace_templates.lua"


def run_lua() -> None:
    script = r'''
ReplicatedSuite = {
  BootError = nil,
  SafeTraceback = debug.traceback,
  UITokens = { Number = function(_, _, fallback) return fallback end },
}
local R = {
  ComponentApiContractVersion = 1,
  ResponsiveInspectorContractVersion = 1,
  LayoutEditorOverlayContractVersion = 1,
  TransformInspectorContractVersion = 2,
  LayoutEditHistoryContractVersion = 1,
  LayoutEditSessionContractVersion = 1,
  EditorCommandBarContractVersion = 2,
  metrics = {
    layoutEditorWorkspacesCreated = 0,
    layoutEditorWorkspaceHistoryBindings = 0,
    layoutEditorWorkspaceSessionBindings = 0,
  },
}
ReplicatedSuite.RSUI = R

function R:Callback(_, fn, ...)
  if type(fn) ~= "function" then return true, nil end
  return true, fn(...)
end
function R:RequireComponentMethods(component, methods, context)
  if type(component) ~= "table" then return false, "component_required:" .. tostring(context) end
  for _, name in ipairs(methods or {}) do
    if type(component[name]) ~= "function" then
      return false, "component_method_required:" .. tostring(context) .. ":" .. tostring(name)
    end
  end
  return true, nil
end

local function Generic(id)
  local c = { id = id, released = false, visible = true, enabled = true }
  function c:SetVisible(value) self.visible = value == true; return true end
  function c:SetText(value) self.text = tostring(value or ""); return true end
  function c:SetEnabled(value) self.enabled = value ~= false; return true end
  function c:Release() self.released = true; return 1 end
  function c:GetSnapshot() return { id = self.id } end
  return c
end

function R:ResponsiveInspector(spec)
  local c = Generic(spec.id)
  c.mode = "drawer"; c.drawerOpen = false
  function c:GetMode() return self.mode end
  function c:IsDrawerOpen() return self.drawerOpen == true end
  function c:SetDrawerOpen(open, notify)
    self.drawerOpen = open == true
    if notify ~= false and type(spec.onDrawerChanged) == "function" then spec.onDrawerChanged(self.drawerOpen, self) end
    return true
  end
  function c:ToggleDrawer(notify) return self:SetDrawerOpen(not self.drawerOpen, notify) end
  function c:GetResponsiveSnapshot() return { mode = self.mode, drawerOpen = self.drawerOpen } end
  return c
end
function R:VerticalBox(spec) return Generic(spec.id) end
function R:SplitView(spec) return Generic(spec.id) end
function R:UniformGrid(spec) return Generic(spec.id) end
function R:HorizontalBox(spec) return Generic(spec.id) end
function R:Overlay(spec) return Generic(spec.id) end
function R:ScrollBox(spec) return Generic(spec.id) end
function R:Text(spec) return Generic(spec.id) end
function R:StatusChip(spec)
  local c = Generic(spec.id)
  function c:SetStatus(status, text) self.status, self.text = status, text; return true end
  return c
end
function R:Button(spec)
  -- Intentionally NO Show(). LayoutEditorWorkspace must only rely on the common
  -- SetVisible contract for this mock primitive.
  local c = Generic(spec.id)
  c.onClick = spec.onClick
  function c:Click() return self.onClick and self.onClick() or true end
  return c
end

function R:CreateLayoutEditHistoryModel(spec)
  local h = { id = spec.id, listeners = {} }
  function h:Subscribe(token, fn) self.listeners[token] = fn; return true end
  function h:Unsubscribe(token) self.listeners[token] = nil; return true end
  function h:Release() self.listeners = {}; return true end
  function h:GetSnapshot() return { id = self.id } end
  return h
end

function R:LayoutEditorOverlay(spec)
  local c = Generic(spec.id)
  local anchor = { GetSnapshot = function() return {} end }
  local adapter = {}
  function adapter:GetHistoryModel() return spec.historyModel end
  function adapter:GetAnchorModel() return anchor end
  function adapter:GetMode() return "none" end
  c.adapter = adapter
  function c:GetAdapter() return self.adapter end
  function c:GetSnapModel() return {} end
  function c:RefreshFromAdapter() return true end
  function c:RefreshFromSource() return true end
  return c
end

function R:TransformInspector(spec)
  local c = Generic(spec.id)
  function c:SetModels(rect, anchor) self.rectModel, self.anchorModel = rect, anchor; return true end
  return c
end
function R:EditorCommandBar(spec)
  local c = Generic(spec.id)
  function c:Execute(command) return false, "session_not_attached" end
  return c
end

-- Loaded by the harness after the mock is complete.
'''
    script += f'dofile([[{WORKSPACE.as_posix()}]])\n'
    script += r'''
local master, err = R:CreateMasterDetailWorkspace({ id = "master", parent = {} })
assert(master ~= nil, tostring(err))
assert(master.kind == "MasterDetailWorkspace" and master.root ~= nil and master.master ~= nil and master.detail ~= nil, "master_detail_invalid")

local inspectorWorkbench, iwErr = R:CreateInspectorWorkbench({ id = "iw", parent = {} })
assert(inspectorWorkbench ~= nil, tostring(iwErr))
assert(inspectorWorkbench.kind == "InspectorWorkbench" and inspectorWorkbench.navigator ~= nil and inspectorWorkbench.canvas ~= nil and inspectorWorkbench.inspector ~= nil, "inspector_workbench_invalid")

local responsive, responsiveErr = R:CreateResponsiveInspectorWorkspace({ id = "responsive", parent = {} })
assert(responsive ~= nil, tostring(responsiveErr))
assert(responsive.kind == "ResponsiveInspectorWorkspace" and responsive.content ~= nil and responsive.inspector ~= nil, "responsive_invalid")
responsive:SetDrawerOpen(true, true)
assert(responsive:GetMode() == "drawer" and responsive.root:IsDrawerOpen() == true, "responsive_drawer_invalid")

local settings, settingsErr = R:CreateSettingsWorkbench({ id = "settings", parent = {} })
assert(settings ~= nil, tostring(settingsErr))
assert(settings.kind == "SettingsWorkbench" and settings.navigation == settings.master and settings.content == settings.detail, "settings_invalid")

local command, commandErr = R:CreateCommandCenterWorkspace({ id = "command", parent = {} })
assert(command ~= nil, tostring(commandErr))
assert(command.kind == "CommandCenterWorkspace" and command.header ~= nil and command.status ~= nil and command.body ~= nil and command.evidence ~= nil, "command_center_invalid")
local commandNoEvidence, commandNoEvidenceErr = R:CreateCommandCenterWorkspace({ id = "command_no_evidence", parent = {}, evidence = false })
assert(commandNoEvidence ~= nil, tostring(commandNoEvidenceErr))
assert(commandNoEvidence.evidence == nil, "command_center_evidence_flag_invalid")

local workspace, layoutErr = R:CreateLayoutEditorWorkspace({
  id = "workspace_smoke",
  parent = {},
  selectionModel = {},
  getRect = function() return { x = 0, y = 0, width = 100, height = 50 } end,
})
assert(workspace ~= nil, tostring(layoutErr))
assert(R.LayoutEditorWorkspaceContractVersion >= 4, "workspace_contract_version")
assert(workspace.inspectorToggle ~= nil, "toggle_missing")
assert(workspace.inspectorToggle.visible == true, "drawer_toggle_should_be_visible")
assert(type(workspace.inspectorToggle.Show) ~= "function", "mock_button_must_not_have_show")
workspace:SetDrawerOpen(true, true)
assert(workspace.inspectorToggle.text == "收起属性", "toggle_text_not_synced")
local snapshot = workspace:GetSnapshot()
assert(snapshot ~= nil and snapshot.responsive.mode == "drawer", "snapshot_invalid")
workspace:Release()
print("RSUI_WORKSPACE_SMOKE_LUA PASS 22/22")
'''
    with tempfile.NamedTemporaryFile("w", suffix=".lua", encoding="utf-8", delete=False) as fh:
        fh.write(script)
        tmp = pathlib.Path(fh.name)
    try:
        proc = subprocess.run(["texlua", str(tmp)], capture_output=True, text=True)
    finally:
        tmp.unlink(missing_ok=True)
    if proc.returncode != 0:
        raise AssertionError((proc.stdout + proc.stderr).strip())
    if "RSUI_WORKSPACE_SMOKE_LUA PASS 22/22" not in proc.stdout:
        raise AssertionError(proc.stdout.strip() or "missing PASS marker")


def main() -> int:
    source = WORKSPACE.read_text(encoding="utf-8-sig")
    required = (
        "contractVersion = 6",
        "RSUI.LayoutEditorWorkspaceContractVersion = 4",
        "RSUI:RequireComponentMethods(inspectorToggle",
        "inspectorToggle:SetVisible(drawer)",
    )
    for token in required:
        if token not in source:
            raise AssertionError("missing source contract: " + token)
    if "inspectorToggle:Show(" in source:
        raise AssertionError("forbidden inspectorToggle:Show call")
    run_lua()
    print("RSUI_WORKSPACE_SMOKE_HARNESS PASS 27/27")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
