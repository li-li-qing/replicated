#!/usr/bin/env python3
"""End-to-end Unit Line evidence harness: REAL bridge + REAL projection + REAL
presenter, only the engine Native surface is mocked.

This is the "能使用的证据" demanded after the regression round: it proves the
exact production chain  target change -> TargetService fact -> world/screen
reads -> ProjectUnitBatch -> UnitLines.read rows -> BuildUnitLineSamplePlan ->
EnsureUnitPairPool -> PlaceUnitDot (unique positions)  on the REAL code, not a
re-implementation. If this passes but the overlay is still invisible on the RU
client, the remaining unknown is a Native/runtime fact (UI host creation,
generation state, actual screen metrics) and the UnitLines: diagnostics line
must be captured on the client.

Engine mocks (evidence for each, from z_api_functions / reference plugins):
  X2Unit:GetUnitWorldPositionByTarget(unit, isLocal) -> global-space world pos
      (reference: rs_business_bridge "isLocal=true 历史bug" note, wbdebuff-era
      usage)
  X2Unit:GetUnitScreenPosition(unit) -> x, _, y, depth
  UIParent:GetViewCameraPos/Dir/Fov -> camera basis looking down +X at origin
  S.Api:GetUiMetrics -> 1280x960 @1.25 scale, logical 1024x768
"""
from __future__ import annotations

import pathlib
import subprocess
import tempfile
from rs_lua_runner import RUNNER

ROOT = pathlib.Path(__file__).resolve().parents[1]
PERSISTENCE = ROOT / "core/rs_persistence.lua"
PROJECTION = ROOT / "services/rs_screen_projection_v3.lua"
BRIDGE = ROOT / "features/rs_business_bridge.lua"
GUIDES = ROOT / "presentation/v3/widgets/rs_v3_combat_visual_guides.lua"

LUA = r'''
-- Deterministic deep copy (mock for S.Utils.DeepCopy).
local function copy(value, seen)
  if type(value) ~= "table" then return value end
  seen = seen or {{}}
  if seen[value] ~= nil then return seen[value] end
  local out = {{}}; seen[value] = out
  for k, v in pairs(value) do out[copy(k, seen)] = copy(v, seen) end
  return out
end
local function Trim(v) return tostring(v or ""):match("^%s*(.-)%s*$") or "" end
local function Lower(v) return string.lower(tostring(v or "")) end

local storage = {{}}
local nowMs = 500000
ReplicatedSuite = {
  BootError = nil, BuildTag = "unit-line-e2e", Generation = 1,
  SaveKey = "rs_e2e_harness", Version = "1.2",
  NowMs = function() return nowMs end,
  PhysicalId = function(id) return tostring(id) end,
  SafeChat = function() end,
  WarnOnce = function() end,
  SafeTraceback = function(err) return tostring(err) end,
  Utils = {{ DeepCopy = copy, Trim = Trim, Lower = Lower }},
  -- Production provides S.UI via ui/rs_ui_native_primitives.lua (toc.g:36);
  -- the presenter load guard (combat_visual_guides.lua:10) silently returns
  -- without a table at S.UI, so this mock MUST exist or the render layer
  -- never loads. The presenter creates hosts/dots through S.UI:CreateEmptyWidget
  -- (combat_visual_guides.lua:43/:216), so those calls must land in the same
  -- widget records the assertions read.
  -- UI mock is attached AFTER the chunk-level widget records are declared
  -- (see "Native widget surface" below); the load guard only needs the TABLE
  -- to exist at guides-dofile time, and dofile happens later.
  UI = nil,
  Api = {{}},
  Data = {{}},
  Services = {{}},
  Features = {{}},
  Events = nil, -- bridge tolerates nil S.Events in several paths; set below
  Scheduler = nil,
  Demand = nil,
  FrameBudget = nil,
  -- Mirrors the real FeatureRuntime contract (rs_feature_runtime.lua:230):
  -- Enable -> feature:Enable() -> PublishLifecycle. The presenter acquires its
  -- consumer from the LIFECYCLE event, so enable MUST go through here or
  -- unitHeld stays false and the overlay never renders.
  FeatureRuntime = {{ enabled = {{}}, LifecycleTopic = "v3.feature.lifecycle",
    RegisterImplementation = function() return true end,
    IsEnabled = function(self, id) return self.enabled[tostring(id or "")] == true end,
    Enable = function(self, id, reason)
      local feature = ReplicatedSuite.Features and ReplicatedSuite.Features[tostring(id or "")]
      if feature == nil or feature.Enable == nil then return false, "feature not found: " .. tostring(id) end
      local ok, err = feature:Enable()
      if ok ~= true then return false, err end
      self.enabled[tostring(id)] = true
      ReplicatedSuite.Events:Publish(self.LifecycleTopic, tostring(id), "enabled", tostring(reason or "harness"))
      return true
    end,
    Disable = function(self, id, reason)
      local feature = ReplicatedSuite.Features and ReplicatedSuite.Features[tostring(id or "")]
      if feature ~= nil and feature.Disable ~= nil then feature:Disable(reason or "harness") end
      self.enabled[tostring(id)] = nil
      ReplicatedSuite.Events:Publish(self.LifecycleTopic, tostring(id), "disabled", tostring(reason or "harness"))
      return true
    end,
    EnableDefaults = function() return true end }},
  DiagnosticsManager = {{ Record = function() end, Error = function() end, Warning = function() end,
    WarnRateLimited = function() end, WarningRateLimited = function() end }},
}
local S = ReplicatedSuite

-- ---- Scheduler mock: records tasks, allows manual pump --------------------
local tasks = {{}}
S.Scheduler = {
  AddTask = function(self, name, interval, callback) tasks[name] = {{ interval = interval, callback = callback, failures = 0 }}; return true end,
  AddHighFrequencyTask = function(self, name, interval, callback) tasks[name] = {{ interval = interval, callback = callback, failures = 0 }}; return true end,
  RemoveTask = function(self, name) tasks[name] = nil end,
  RemoveOwner = function() return 0 end,
  SetTaskModule = function() end,
  tasks = tasks,
}
local function Pump(name, times)
  for _ = 1, (times or 1) do
    local task = tasks[name]
    if task ~= nil then
      nowMs = nowMs + task.interval
      local ok, err = pcall(task.callback)
      if not ok then task.failures = task.failures + 1; S.LastSchedulerError = tostring(err) end
    end
  end
end

-- ---- Events mock: synchronous publish/subscribe registry ------------------
local handlers = {{}}
S.Events = {
  -- Dispatch convention matches core/rs_events.lua:207-213: the recorded
  -- OWNER is passed as the first argument, then the publish args. Getting
  -- this wrong silently drops every handler whose callback pattern is
  -- `function(_, payload)` -- which is most of them.
  Publish = function(self, event, ...)
    local owner = nil
    for _, entry in ipairs(handlers[event] or {{}}) do
      pcall(entry.fn, entry.owner, ...)
      owner = entry.owner
    end
    return true
  end,
  SubscribeInternal = function(self, event, owner, fn) handlers[event] = handlers[event] or {{}}; handlers[event][#handlers[event] + 1] = {{ owner = owner, fn = fn }}; return true end,
  SubscribeOptional = function(self, event, owner, fn) handlers[event] = handlers[event] or {{}}; handlers[event][#handlers[event] + 1] = {{ owner = owner, fn = fn }}; return true end,
  UnsubscribeOwner = function() return true end,
  UnsubscribeInternalOwner = function() return true end,
  BindOwner = function() return true end,
}

-- ---- Demand mock: lease counting with reconcile callback ------------------
S.Demand = {
  Create = function(self, spec)
    -- The real Demand maintains projectionOwner[consumersField]/[countField]
    -- (core/rs_demand.lua); the mock must do the same or consumer-gated code
    -- (visual refresh tasks, lane ticks) never runs -- which would fake a
    -- "feature has no effect" result.
    local owner = spec.projectionOwner
    local consumersField = spec.projectionConsumersField or "consumers"
    local countField = spec.projectionCountField or "consumerCount"
    owner[consumersField] = {{}}
    owner[countField] = 0
    local d = {{ count = 0, consumers = {{}}, spec = spec }}
    function d:Acquire(token, options, purpose)
      local before = {{ count = self.count }}
      if self.consumers[token] ~= true then
        self.consumers[token] = true
        self.count = self.count + 1
        owner[consumersField][token] = true
        owner[countField] = self.count
      end
      local after = {{ count = self.count }}
      if spec.reconcile ~= nil then spec.reconcile(self, before, after) end
      return true
    end
    function d:Release(token, purpose)
      if self.consumers[token] ~= true then return true end
      self.consumers[token] = nil
      self.count = self.count - 1
      owner[consumersField][token] = nil
      owner[countField] = self.count
      if spec.reconcile ~= nil then spec.reconcile(self, {{ count = self.count + 1 }}, {{ count = self.count }}) end
      return true
    end
    function d:Has(token) return self.consumers[token] == true end
    function d:Clear()
      local before = {{ count = self.count }}
      self.consumers = {{}}; self.count = 0
      owner[consumersField] = {{}}; owner[countField] = 0
      if spec.reconcile ~= nil then spec.reconcile(self, before, {{ count = 0 }}) end
      return true
    end
    return d
  end,
}

-- ---- FrameBudget / PerformanceMonitor mocks (absent is fine too) ---------
S.FrameBudget = {{ current = {{ pressure = "Normal" }} }}
S.PerformanceMonitor = nil

-- ---- Native API surface ---------------------------------------------------
-- Target stands 20 world units in front of the player (+X), camera looks +X.
-- Target is OFF the camera view axis (a real target stands to the side); a
-- target ON the axis projects both endpoints to the exact screen center --
-- the degenerate geometry this harness must not mistake for a code failure.
local world = {{ player = {{ 10, 0, 0 }}, target = {{ 30, 4, 0 }} }}
local screen = {{ player = {{ 512, 384, 1 }}, target = {{ 300, 350, 1 }} }}
X2Unit = {{}}
X2Player = {{ GetEffectAppellation = function() return nil end }}
X2Store, X2Bag, X2Resident, X2Ability = {{}}, {{}}, {{}}, {{}}
UIParent = {{}}
function S.Api:GetUiMetrics() return 1280, 960, 1.25, 1024, 768 end
function S.Api:IsCapabilityAllowed() return true, "mock" end
function S.Api:CallCapability(capability, host, method, ...)
  local arg = (...)
  if capability == "UIParent:GetViewCameraPos" then return true, {{ x = 0, y = 0, z = 0 }} end
  if capability == "UIParent:GetViewCameraDir" then return true, {{ x = 1, y = 0, z = 0 }} end
  if capability == "UIParent:GetViewCameraFov" then return true, 1.57 end
  if capability == "X2Unit:GetUnitWorldPositionByTarget" then
    local p = world[tostring(arg or "")]
    if p == nil then return false, nil, "missing_world" end
    return true, p[1], nil, p[2], p[3]
  end
  if capability == "X2Unit:GetUnitScreenPosition" then
    local p = screen[tostring(arg or "")]
    if p == nil then return false, nil, "missing_screen" end
    return true, p[1], nil, p[2], p[3]
  end
  if capability == "X2Unit:UnitCastingInfo" then return false, nil, "no_cast" end
  if capability == "X2Unit:UnitGearScore" then return true, 0 end
  if capability == "X2Unit:UnitDistance" then return true, 20 end
  if capability == "X2Unit:GetTargetUnitId" then return true, "0x0001" end
  if capability == "X2Unit:UnitNameWithWorld" then return true, "CharA@world1" end
  if capability == "X2Unit:UnitName" then return true, "TargetName" end
  return false, nil, "unsupported:" .. tostring(capability)
end
function S.Api:CallGlobalCapability() return false, nil, "disabled" end
function S.Api:SaveData(key, raw) storage[key] = copy(raw); return true, nil end
function S.Api:LoadData(key) return copy(storage[key]), nil end
function S.Api:ClearData(key) storage[key] = nil; return true, nil end

-- ---- Native UI surface: real widget records so the presenter can place dots
local widgetCounter = 0
local widgets = {{}}
local function NewWidget(parent)
  widgetCounter = widgetCounter + 1
  local w = {{ __widget = true, name = "w" .. widgetCounter, parent = parent, visible = false, x = -1, y = -1, width = 0, height = 0 }}
  widgets[w.name] = w
  function w:SetExtent(a, b) self.width, self.height = a, b; return true end
  function w:AddAnchor(point, target, x, y) self.anchorPoint, self.anchorTarget, self.ax, self.ay = point, target, x, y; if x ~= nil then self.x, self.y = x, y end; return true end
  function w:RemoveAllAnchors() return true end
  function w:Show(v) self.visible = v == true; return true end
  function w:SetVisible(v) self.visible = v == true; return true end
  function w:Raise() return true end
  function w:SetColor() return true end
  function w:SetHandler() return true end
  function w:ReleaseHandler() return true end
  function w:CreateDrawable() return true end
  function w:CreateColorDrawable()
    return {{ SetColor = function() return true end, SetExtent = function() return true end,
      AddAnchor = function() return true end }}
  end
  function w:GetWidth() return self.width end
  function w:GetHeight() return self.height end
  return w
end
S.NativeObjectFactory = {{ CreateEmptyWidget = function(self, id, parent) return NewWidget(parent) end }}
-- Presenter surface: hosts and dots are created through S.UI:CreateEmptyWidget
-- (combat_visual_guides.lua:43/:216), so S.UI must route into the SAME widget
-- records the assertions inspect.
S.UI = {{ controls = {{}} }}
function S.UI:CreateEmptyWidget(parent, name, x, y, w, h)
  local widget = NewWidget(parent)
  widget.x, widget.y, widget.width, widget.height = x or 0, y or 0, w or 0, h or 0
  return widget
end
function S.UI:SetVisible(widget, value) if widget ~= nil then widget:SetVisible(value) end; return true end
function S.UI:SetAnchor(widget, parent, x, y) if widget ~= nil then widget:AddAnchor("TOPLEFT", parent, x, y) end; return true end
function S.UI:SetExtent(widget, w, h) if widget ~= nil then widget:SetExtent(w, h) end; return true end
function S.UI:SetColor(drawable, r, g, b, a) if drawable ~= nil and drawable.SetColor ~= nil then return drawable:SetColor(r, g, b, a) end; return true end
function S.UI:SetAlpha() return true end
function S.UI:SetFontSize() return true end
function S.UI:TrySetUILayer(widget) if widget ~= nil and widget.Raise ~= nil then widget:Raise() end; return true end
UIParent = {{}}

-- Load order mirrors toc.g (:107 projection -> :152 bridge -> :166 guides);
-- the presenter file returns early unless the feature objects already exist.
dofile("{PERSISTENCE}")
dofile("{PROJECTION}")
dofile("{BRIDGE}")
dofile("{GUIDES}")

local P = ReplicatedSuite.Persistence
local UnitFeature = ReplicatedSuite.Features.combat_unit_lines
local RangeFeature = ReplicatedSuite.Features.combat_range_assist
local Presenter = ReplicatedSuite.Features.combat_unit_lines and _G.__presenter or nil
local passed, total = 0, 0
local function Check(name, ok, detail)
  total = total + 1
  if ok then passed = passed + 1 else print("FAIL | " .. tostring(name) .. " | " .. tostring(detail or "")) end
end

-- Presenter: the guides file wires itself to the feature objects; find it.
local presenter = nil
for _, candidate in ipairs({ ReplicatedSuite.UIV3 and ReplicatedSuite.UIV3.CombatVisualGuides, _G.CombatVisualGuidesPresenter }) do
  if type(candidate) == "table" and candidate.RenderUnit ~= nil then presenter = candidate break end
end
-- Fallback: the guides module registers itself under S.UIV3 or a local; probe
-- known mount points, else drive the render path through UpdateTopic handlers.
local function DriveUnitRender()
  S.Events:Publish(UnitFeature.UpdateTopic)
end
local function DriveRangeRender()
  S.Events:Publish(RangeFeature.UpdateTopic)
end

-- 1. Feature enable + consumer acquire (lifecycle path).
Check("unit_feature_exists", UnitFeature ~= nil and UnitFeature.AcquireConsumer ~= nil)
Check("range_feature_exists", RangeFeature ~= nil)
-- Production path: page/defaults call FeatureRuntime:Enable, which publishes
-- the lifecycle event the presenter listens on. Calling feature:Enable()
-- directly would bypass the presenter wiring (unitHeld stays false).
local lifecycleSeen = nil
S.Events:SubscribeInternal("v3.feature.lifecycle", "e2e:probe", function(_, featureId, state) lifecycleSeen = tostring(featureId) .. ":" .. tostring(state) end)
local unitEnabled = S.FeatureRuntime:Enable("combat_unit_lines", "e2e")
Check("unit_enable_ok", unitEnabled == true)
local acquired = UnitFeature:AcquireConsumer("e2e:harness")
Check("unit_consumer_acquired", acquired == true)
Check("unit_task_registered", tasks["v3_business_unit_lines_refresh"] ~= nil)

-- 2. One scheduler tick produces rows for a target 20 world units away.
Pump("v3_business_unit_lines_refresh", 3)
local projection = UnitFeature:GetProjection()
Check("rows_emitted", type(projection.rows) == "table" and #projection.rows >= 1,
  projection.rows and #projection.rows or "nil")
if type(projection.rows) == "table" and projection.rows[1] ~= nil then
  local row = projection.rows[1]
  Check("row_span_far", math.abs((row.x2 or 0) - (row.x1 or 0)) > 8, tostring(row.x1) .. "->" .. tostring(row.x2))
end

-- 3. Render publishes dots through the real presenter pool.
-- The lifecycle event during Enable already ran Reconcile; rows only exist
-- after the first task tick, so publish an UpdateTopic render now.
DriveUnitRender()
nowMs = nowMs + 50
DriveUnitRender()
nowMs = nowMs + 50
DriveUnitRender()
local dia = UnitFeature.Diagnostics
Check("diag_exists", dia ~= nil)
Check("diag_rows_drawn", dia ~= nil and (tonumber(dia.drawnRows) or 0) >= 1, dia and dia.drawnRows)
Check("diag_consumer", dia ~= nil and (tonumber(dia.consumerCount) or 0) >= 1)

-- 3b. REAL placement evidence: the presenter created real dot widgets through
-- the mocked native surface and anchored them along the line. Count visible
-- dots and DISTINCT positions on the widget records themselves.
-- Dot widgets are 4x4 children of the unit host (PlaceUnitDot SetExtent 4,4).
local visibleDots, seenPositions = 0, {}
for _, w in pairs(widgets) do
  if w.visible == true and w.__widget == true and w.width == 4 and w.height == 4 then
    visibleDots = visibleDots + 1
    seenPositions[tostring(w.x) .. "," .. tostring(w.y)] = true
  end
end
local uniquePositions = 0
for _ in pairs(seenPositions) do uniquePositions = uniquePositions + 1 end
Check("dots_visible_on_widgets", visibleDots >= 8, visibleDots)
Check("dot_positions_unique", uniquePositions >= 8, uniquePositions)

-- 4. Range assist: circle around the player yields multiple visible points.
local rangeEnabled = S.FeatureRuntime:Enable("combat_range_assist", "e2e")
Check("range_enable_ok", rangeEnabled == true)
local rangeAcquired = RangeFeature:AcquireConsumer("e2e:harness_range")
Check("range_consumer_acquired", rangeAcquired == true)
Pump("v3_business_range_assist_refresh", 3)
local rangeProjection = RangeFeature:GetProjection()
local rangeRow = type(rangeProjection.rows) == "table" and rangeProjection.rows[1] or nil
local rangePoints = type(rangeRow) == "table" and type(rangeRow.points) == "table" and #rangeRow.points or 0
Check("range_points_generated", rangePoints >= 8, rangePoints)

if passed ~= total then os.exit(1) end
print("UNIT_LINE_END_TO_END_HARNESS PASS " .. tostring(passed) .. "/" .. tostring(total))
'''.replace("{PERSISTENCE}", str(PERSISTENCE.as_posix())) \
   .replace("{PROJECTION}", str(PROJECTION.as_posix())) \
   .replace("{BRIDGE}", str(BRIDGE.as_posix())) \
   .replace("{GUIDES}", str(GUIDES.as_posix())) \
   .replace("{{", "{").replace("}}", "}")


def main() -> int:
    if RUNNER is None:
        print("UNIT_LINE_END_TO_END_HARNESS SKIP | lua runner unavailable")
        return 2
    # BuildUnitLineSamplePlan / EnsureUnitPairPool live in the PRESENTER file
    # (presentation layer owns rendering); the bridge owns the fact rows.
    bridge_source = BRIDGE.read_text(encoding="utf-8-sig")
    for token in ("local function NormalizeCastKey(value)", "UNIT_LINE_PAIRS"):
        if token not in bridge_source:
            raise AssertionError("bridge contract missing: " + token)
    if "BuildUnitLineSamplePlan" not in GUIDES.read_text(encoding="utf-8-sig"):
        raise AssertionError("presenter contract missing: BuildUnitLineSamplePlan")
    with tempfile.NamedTemporaryFile("w", suffix=".lua", encoding="utf-8", delete=False) as fh:
        fh.write(LUA)
        tmp = pathlib.Path(fh.name)
    try:
        proc = subprocess.run([RUNNER, str(tmp)], capture_output=True, text=True)
    finally:
        tmp.unlink(missing_ok=True)
    out = (proc.stdout + proc.stderr).strip()
    if proc.returncode != 0 or "UNIT_LINE_END_TO_END_HARNESS PASS" not in proc.stdout:
        raise AssertionError(out[-3000:])
    print(out[-500:] if out else "UNIT_LINE_END_TO_END_HARNESS PASS")


if __name__ == "__main__":
    raise SystemExit(main())
