#!/usr/bin/env python3
"""Real-Lua harness for the per-feature diagnostics status rows.

The 2026-09-06 diagnostics overhaul adds BuildFeatureStatusRows /
FormatFeatureStatusRows / BuildRepairGuidance to DiagnosticsManager, and the
copy banner (BuildCopyText) now carries per-feature verdicts + repair hints.

Behavioral assertions (not "function exists"):
  1. unit_lines reads OFF when disabled, DOWN with a layer-specific hint when
     enabled with no consumers, OK with evidence when rows were drawn,
  2. range_assist mirrors the <3-visible-points renderer cut-off,
  3. boss_alerts distinguishes HUD-off from observe-loop-not-running,
  4. bonds degrades with dayKey/snapshot evidence when nothing was read today,
  5. repair guidance lists one actionable hint per non-ok row and the ok-only
     case reports 全部正常,
  6. verdict marks round-trip through FormatFeatureStatusRows.
"""
from __future__ import annotations

import pathlib
import subprocess
import tempfile
from rs_lua_runner import RUNNER

ROOT = pathlib.Path(__file__).resolve().parents[1]
DIAGNOSTICS = ROOT / "core/rs_diagnostics.lua"

LUA = r'''
local function copy(value, seen)
  if type(value) ~= "table" then return value end
  seen = seen or {}
  if seen[value] ~= nil then return seen[value] end
  local out = {}; seen[value] = out
  for k, v in pairs(value) do out[copy(k, seen)] = copy(v, seen) end
  return out
end
ReplicatedSuite = {
  BootError = nil, BuildTag = "diag-status-harness", Version = "1.2",
  NowMs = function() return 1000 end,
  Utils = { DeepCopy = copy },
  Features = {}, Services = {}, Scheduler = { tasks = {} },
  FeatureRuntime = { enabled = {},
    IsEnabled = function(self, id) return self.enabled[tostring(id or "")] == true end },
  DiagnosticsManager = nil,
}
local S = ReplicatedSuite
dofile("{DIAGNOSTICS}")
local D = S.DiagnosticsManager
local passed, total = 0, 0
local function Check(name, ok, detail)
  total = total + 1
  if ok then passed = passed + 1 else print("FAIL | " .. tostring(name) .. " | " .. tostring(detail or "")) end
end

-- Case 1: unit_lines OFF -> verdict off with an enabling hint.
S.FeatureRuntime.enabled.combat_unit_lines = nil
local rows = D:BuildFeatureStatusRows()
local byId = {}
for _, row in ipairs(rows) do byId[row.id] = row end
Check("unit_off_verdict", byId.unit_lines and byId.unit_lines.verdict == "off", byId.unit_lines and byId.unit_lines.verdict)

-- Case 2: enabled, no consumers -> DOWN with consumer hint.
S.FeatureRuntime.enabled.combat_unit_lines = true
S.Features.combat_unit_lines = { consumerCount = 0 }
rows = D:BuildFeatureStatusRows()
byId = {}
for _, row in ipairs(rows) do byId[row.id] = row end
Check("unit_no_consumer_down", byId.unit_lines and byId.unit_lines.verdict == "down", byId.unit_lines and byId.unit_lines.verdict)
Check("unit_no_consumer_hint", byId.unit_lines ~= nil and tostring(byId.unit_lines.text):find("无消费者", 1, true) ~= nil)

-- Case 3: enabled + consumer + drawn rows -> OK with evidence.
S.Features.combat_unit_lines.consumerCount = 1
S.Features.combat_unit_lines.Diagnostics = { drawnRows = 2, attemptedPairs = 2, lastStatus = "ready" }
S.Services.ScreenProjectionV3 = { GetHealth = function() return { failures = 0 } end }
rows = D:BuildFeatureStatusRows()
byId = {}
for _, row in ipairs(rows) do byId[row.id] = row end
Check("unit_ok_verdict", byId.unit_lines and byId.unit_lines.verdict == "ok", byId.unit_lines and byId.unit_lines.verdict)
Check("unit_ok_evidence", byId.unit_lines ~= nil and tostring(byId.unit_lines.text):find("rows=2", 1, true) ~= nil)

-- Case 4: enabled + consumer + zero rows -> DOWN with lastFailure.
S.Features.combat_unit_lines.Diagnostics = { drawnRows = 0, attemptedPairs = 2, lastStatus = "empty", lastFailureReason = "ALL_PAIRS_DISABLED" }
rows = D:BuildFeatureStatusRows()
byId = {}
for _, row in ipairs(rows) do byId[row.id] = row end
Check("unit_zero_rows_down", byId.unit_lines and byId.unit_lines.verdict == "down")
Check("unit_zero_rows_hint", byId.unit_lines ~= nil and tostring(byId.unit_lines.hint or ""):find("连线设置", 1, true) ~= nil)

-- Case 5: range assist <3 points -> DOWN; >=3 -> OK.
S.FeatureRuntime.enabled.combat_range_assist = true
S.Features.combat_range_assist = { consumerCount = 1, GetProjection = function(self)
  return { rows = { { points = { {x=1,y=1}, {x=2,y=2} } } }, radius = 10 }
end }
rows = D:BuildFeatureStatusRows()
byId = {}
for _, row in ipairs(rows) do byId[row.id] = row end
Check("range_low_points_down", byId.range_assist and byId.range_assist.verdict == "down", byId.range_assist and byId.range_assist.verdict)
S.Features.combat_range_assist.GetProjection = function(self)
  local pts = {}
  for i = 1, 24 do pts[i] = { x = i, y = i } end
  return { rows = { { points = pts } }, radius = 10 }
end
rows = D:BuildFeatureStatusRows()
byId = {}
for _, row in ipairs(rows) do byId[row.id] = row end
Check("range_full_points_ok", byId.range_assist and byId.range_assist.verdict == "ok", byId.range_assist and byId.range_assist.verdict)

-- Case 6: boss HUD off vs observe loop running.
S.FeatureRuntime.enabled.combat_boss_alerts = true
S.Features.combat_boss_alerts = { State = { hudEnabled = false }, _bossDiag = nil }
rows = D:BuildFeatureStatusRows()
byId = {}
for _, row in ipairs(rows) do byId[row.id] = row end
Check("boss_hud_off_down", byId.boss_alerts and byId.boss_alerts.verdict == "down")
S.Features.combat_boss_alerts.State.hudEnabled = true
S.Features.combat_boss_alerts._bossDiag = { observeTicks = 5, lastFactSource = "target", matchedRule = "-" }
rows = D:BuildFeatureStatusRows()
byId = {}
for _, row in ipairs(rows) do byId[row.id] = row end
Check("boss_running_ok", byId.boss_alerts and byId.boss_alerts.verdict == "ok", byId.boss_alerts and byId.boss_alerts.verdict)

-- Case 7: bonds with no snapshots today -> degraded with day evidence.
S.FeatureRuntime.enabled.life_bonds = true
S.Features.Bonds = { DescribeDailyCache = function()
  return { dayKey = "2026-09-06", snapshotCount = 0, boardReads = 0, completedCount = 0 }
end }
rows = D:BuildFeatureStatusRows()
byId = {}
for _, row in ipairs(rows) do byId[row.id] = row end
Check("bonds_degraded", byId.bonds and byId.bonds.verdict == "degraded", byId.bonds and byId.bonds.verdict)
Check("bonds_evidence", byId.bonds ~= nil and tostring(byId.bonds.text):find("2026-09-06", 1, true) ~= nil)

-- Case 8: repair guidance aggregates only non-ok rows.
local hints = D:BuildRepairGuidance(rows)
Check("guidance_lists_broken", tostring(hints):find("债券", 1, true) ~= nil, hints)
for _, row in ipairs(rows) do row.verdict = "ok" end
Check("guidance_all_ok", D:BuildRepairGuidance(rows) == "全部功能状态正常")

-- Case 9: formatted output carries verdict marks.
rows = D:BuildFeatureStatusRows()
rows[1].verdict = "ok"; rows[1].label = "单位连线"; rows[1].text = "工作中"
local text = D:FormatFeatureStatusRows(rows)
Check("format_marks", tostring(text):find("✓单位连线", 1, true) ~= nil, text)

if passed ~= total then os.exit(1) end
print("DIAGNOSTICS_FEATURE_STATUS_HARNESS PASS " .. tostring(passed) .. "/" .. tostring(total))
'''.replace("{DIAGNOSTICS}", str(DIAGNOSTICS.as_posix())) \
   .replace("{{", "{").replace("}}", "}")


def main() -> int:
    source = DIAGNOSTICS.read_text(encoding="utf-8-sig")
    for token in (
        "function D:BuildFeatureStatusRows()",
        "function D:FormatFeatureStatusRows(rows)",
        "function D:BuildRepairGuidance(rows)",
        'FeatureRow("unit_lines", "单位连线"',
    ):
        if token not in source:
            raise AssertionError("diagnostics status rows contract missing: " + token)
    if RUNNER is None:
        print("DIAGNOSTICS_FEATURE_STATUS_HARNESS SKIP | lua runner unavailable")
        return 2
    with tempfile.NamedTemporaryFile("w", suffix=".lua", encoding="utf-8", delete=False) as fh:
        fh.write(LUA)
        tmp = pathlib.Path(fh.name)
    try:
        proc = subprocess.run([RUNNER, str(tmp)], capture_output=True, text=True)
    finally:
        tmp.unlink(missing_ok=True)
    if proc.returncode != 0 or "DIAGNOSTICS_FEATURE_STATUS_HARNESS PASS" not in proc.stdout:
        raise AssertionError((proc.stdout + proc.stderr).strip()[-3000:])
    print("DIAGNOSTICS_FEATURE_STATUS_HARNESS PASS")


if __name__ == "__main__":
    raise SystemExit(main())
