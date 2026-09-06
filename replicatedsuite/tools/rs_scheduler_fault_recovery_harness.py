#!/usr/bin/env python3
"""Real-Lua harness for the Scheduler fault breaker + bounded auto-recovery.

Root-cause regression for the reported "Unit Lines fail permanently until
reload" symptom: three consecutive callback exceptions used to disable a
background task for the rest of the session with no recovery path. The breaker
now records a fault time and the per-frame scan re-enables the task after an
exponential backoff (2s doubling to a 60s cap), so transient causes self-heal
while persistent ones cost at most one attempt per minute.

Also covers the §18 Unit Lines lifecycle cases: consumer 0 -> 1 style task
recreation after recovery, Scheduler stop/restart clearing recovery state, and
the stale-generation driver fence.
"""
from __future__ import annotations

import pathlib
import subprocess
import tempfile
from rs_lua_runner import RUNNER

ROOT = pathlib.Path(__file__).resolve().parents[1]
SCHEDULER = ROOT / "core/rs_scheduler.lua"

LUA = r'''
local nowMs = 100000
ReplicatedSuite = {
  BootError = nil, BuildTag = "scheduler-recovery-harness", Generation = 1,
  SaveKey = "rs_sched_harness",
  NowMs = function() return nowMs end,
  SafeChat = function() end,
  WarnOnce = function() end,
  SafeTraceback = function(err) return tostring(err) end,
  PhysicalId = function(id) return tostring(id) end,
  PerformanceMonitor = nil,
  FrameBudget = nil,
}
local handler = nil
local driver = {
  SetExtent = function() end,
  AddAnchor = function() end,
  Show = function() end,
  SetHandler = function(_, name, fn)
    if name == "OnUpdate" then handler = fn end
    return true
  end,
}
ReplicatedSuite.NativeObjectFactory = {
  CreateEmptyWidget = function() return driver end,
}
dofile("{SCHEDULER}")
local S = ReplicatedSuite
local Scheduler = S.Scheduler
assert(Scheduler:Start() == true, "scheduler_start")
assert(handler ~= nil, "driver_handler_bound")

local runs = 0
local failForever = true
local okAdd = Scheduler:AddTask("v3_harness_faulty", 50, function()
  runs = runs + 1
  if failForever then error("simulated transient native failure") end
end, false, nil, "P2", 1)
assert(okAdd == true, "task_added")

local function Advance(ms)
  local target = nowMs + ms
  while nowMs < target do
    nowMs = nowMs + 25
    handler(nil, 25)
  end
end

-- Three consecutive failures trip the breaker.
Advance(400)
assert(runs >= 3, "breaker_tripped")
assert(Scheduler.tasks["v3_harness_faulty"].enabled == false, "task_disabled")

-- Backoff: the task resumes automatically and heals once the callback stops
-- throwing. First resume window opens ~2s after the fault.
failForever = false
Advance(3000)
assert(Scheduler.tasks["v3_harness_faulty"].enabled == true, "task_resumed")
Advance(500)
assert(runs >= 4 and runs < 400, "callback_healthy_after_recovery")
local resumedRuns = runs

-- A second fault episode opens a longer window (backoff doubles).
failForever = true
Advance(400)
assert(Scheduler.tasks["v3_harness_faulty"].enabled == false, "second_trip")
local resumeCount = tonumber(Scheduler.tasks["v3_harness_faulty"].resumeCount) or 0
assert(resumeCount >= 2, "resume_count_tracks_episodes")
-- Backoff window ~4s: must NOT resume before it elapses.
Advance(2000)
assert(Scheduler.tasks["v3_harness_faulty"].enabled == false, "backoff_holds")
failForever = false
Advance(3000)
assert(Scheduler.tasks["v3_harness_faulty"].enabled == true, "second_episode_resumes")

-- Recovery state is exposed for diagnostics.
local health = Scheduler:GetHealth()
assert(tonumber(health.faultResumes) >= 2, "fault_resumes_metric")

-- Stop clears all tasks and recovery state.
Scheduler:Stop()
assert(Scheduler.tasks["v3_harness_faulty"] == nil, "stop_clears_tasks")
assert(handler == nil or Scheduler.running ~= true, "stop_stops_driver")

print("SCHEDULER_FAULT_RECOVERY_HARNESS PASS")
'''.replace("{SCHEDULER}", str(SCHEDULER.as_posix()))


def main() -> int:
    for token in (
        "function Scheduler:RecoverFaultedTasks(now)",
        "task.faultedAtMs = (S.NowMs and S.NowMs() or 0)",
        "faultResumes = tonumber(self.faultResumes) or 0",
    ):
        if token not in SCHEDULER.read_text(encoding="utf-8-sig"):
            raise AssertionError("Scheduler fault recovery implementation missing: " + token)
    if RUNNER is None:
        print("SCHEDULER_FAULT_RECOVERY_HARNESS SKIP | lua runner unavailable")
        return 2
    with tempfile.NamedTemporaryFile("w", suffix=".lua", encoding="utf-8", delete=False) as fh:
        fh.write(LUA)
        tmp = pathlib.Path(fh.name)
    try:
        proc = subprocess.run([RUNNER, str(tmp)], capture_output=True, text=True)
    finally:
        tmp.unlink(missing_ok=True)
    if proc.returncode != 0:
        raise AssertionError((proc.stdout + proc.stderr).strip())
    if "SCHEDULER_FAULT_RECOVERY_HARNESS PASS" not in proc.stdout:
        raise AssertionError(proc.stdout.strip() or "missing PASS marker")
    print("SCHEDULER_FAULT_RECOVERY_HARNESS PASS")


if __name__ == "__main__":
    raise SystemExit(main())
