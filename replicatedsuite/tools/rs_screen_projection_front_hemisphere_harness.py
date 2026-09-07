#!/usr/bin/env python3
"""Execute ScreenProjectionV3 v8 front/coordinate-consistency/index-stable batching with texlua."""
from __future__ import annotations

import argparse
import shutil
import subprocess
import tempfile
from pathlib import Path
from rs_lua_runner import RUNNER

DEFAULT_ROOT = Path(__file__).resolve().parents[1]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", default=None)
    args = parser.parse_args()
    root = Path(args.root).resolve() if args.root else DEFAULT_ROOT
    module = root / "services/rs_screen_projection_v3.lua"
    texlua = RUNNER
    if texlua is None:
        print("SCREEN_PROJECTION_FRONT_HEMISPHERE_HARNESS SKIP | texlua unavailable")
        return 2
    if not module.is_file():
        print(f"SCREEN_PROJECTION_FRONT_HEMISPHERE_HARNESS FAIL | missing {module}")
        return 1

    module_path = str(module).replace("\\", "/").replace("'", "\\'")
    script = f"""
local calls={{camPos=0,camDir=0,camFov=0,screen=0,world=0,worldLocalTrue=0}}
local world={{
  player={{10,0,0}}, front={{20,5,0}}, behind={{-20,0,0}}, edge={{20,100,0}}, drift={{20,-2,0}}, alias_target={{10,0,0}},
  alias_kept={{10,0,0}}, alias_rej={{10,0,0}},
}}
-- Simulate a RU/UI-scale path where otherwise-valid native points arrive in
-- physical pixels.  Because most of those values are still < logicalW/H, the
-- old threshold-only normalizer could not tell which coordinate space they used.
local screen={{
  player={{640,480,1}}, front={{520,456,1}},
  -- Deliberately wrong mirrored result: positive depth at a corner.
  behind={{1272,955,1}}, edge={{5000,480,1}},
  -- Deliberately stale but still on-screen native point.
  drift={{900,700,1}}, alias_target={{900,480,1}}, alias_kept={{642,481,1}},
}}
UIParent={{}}
function UIParent:GetScreenWidth() return 1280 end
function UIParent:GetScreenHeight() return 960 end
X2Unit={{}}
ReplicatedSuite={{
  Services={{}},
  Api={{
    GetUiMetrics=function() return 1280,960,1.25,1024,768 end,
    CallCapability=function(self,capability,host,method,...)
      local arg,isLocal=(...)
      if capability=='UIParent:GetViewCameraPos' then calls.camPos=calls.camPos+1; return true,{{x=0,y=0,z=0}} end
      if capability=='UIParent:GetViewCameraDir' then calls.camDir=calls.camDir+1; return true,{{x=1,y=0,z=0}} end
      if capability=='UIParent:GetViewCameraFov' then calls.camFov=calls.camFov+1; return true,1.57 end
      if capability=='X2Unit:GetUnitWorldPositionByTarget' then
        calls.world=calls.world+1
        if isLocal==true then calls.worldLocalTrue=calls.worldLocalTrue+1 end
        local p=world[tostring(arg or '')]
        if p==nil then return false,nil,'missing_world' end
        return true,p[1],nil,p[2],p[3]
      end
      if capability=='X2Unit:GetUnitScreenPosition' then
        calls.screen=calls.screen+1
        local p=screen[tostring(arg or '')]
        if p==nil then return false,nil,'missing_screen' end
        return true,p[1],nil,p[2],p[3]
      end
      return false,nil,'unsupported:'..tostring(capability)
    end,
    CallGlobalCapability=function() return false,nil,'disabled' end,
  }},
}}
dofile('{module_path}')
local P=ReplicatedSuite.Services.ScreenProjectionV3
local passed,total=0,0
local function Check(name,ok)
  total=total+1
  if ok then passed=passed+1 else print('FAIL | '..name) end
end
Check('contract_version',P.version==12 and P.FrontHemisphereBatchContractVersion==1 and P.CameraUnavailableNativeFallbackContractVersion==1 and P.UnitProjectionConsistencyContractVersion==1 and P.UnitWorldAliasGuardContractVersion==1 and P.WorldBatchIndexContractVersion==1 and P.WorldBatchFactsContractVersion==2 and P.WorldBatchAnchorCalibrationContractVersion==1 and type(P.ProjectUnitBatch)=='function' and type(P.ProjectWorldBatch)=='function')
local result,status=P:ProjectUnitBatch({{'player','front','behind','behind','edge','drift'}},{{requireFrontHemisphere=true,worldZOffset=1,validateNativeAgainstCamera=true,reconcileNativeScale=true}})
Check('batch_ready',status=='ready' and type(result)=='table')
Check('camera_frame_once',calls.camPos==1 and calls.camDir==1 and calls.camFov==1)
Check('deduplicated_world_reads',calls.world==5)
Check('all_world_reads_global',calls.worldLocalTrue==0)
Check('behind_rejected_before_native_screen',type(result.behind)=='table' and result.behind.visible==false and result.behind.reason=='behind_camera' and calls.screen==4)
Check('front_keeps_native_raw',result.front.visible==true and result.front.source=='native_unit' and math.abs(result.front.x-520)<0.01)
Check('player_keeps_native_raw',result.player.visible==true and result.player.source=='native_unit' and result.player.forward>0 and math.abs(result.player.x-640)<0.01)
Check('drift_keeps_native_raw',result.drift.visible==true and result.drift.source=='native_unit' and math.abs(result.drift.x-900)<0.01)
Check('edge_keeps_native_raw',result.edge.visible==true and result.edge.source=='native_unit' and math.abs(result.edge.x-5000)<0.01)
local health=P:GetHealth()
Check('behind_diagnostic',health.behindCameraRejects==1 and health.unitBatches==1)
Check('native_raw_diagnostics',health.nativeScaleReconciles==0 and health.nativeConsistencyFallbacks==0 and type(health.failuresByReason)=='table' and health.unitReads>=4)
-- Real RU failure: target world fact transiently aliases the player's world
-- position while the native screen getter already points at the actual target.
-- Camera consistency must NOT collapse both endpoints back onto the player.
local aliasResult=P:ProjectUnitBatch({{'player','alias_target'}},{{requireFrontHemisphere=true,worldZOffset=1,validateNativeAgainstCamera=true,reconcileNativeScale=true}})
Check('world_alias_player_keeps_native',aliasResult.player.visible==true and aliasResult.player.source=='native_world_alias_guard')
Check('world_alias_target_keeps_native',aliasResult.alias_target.visible==true and aliasResult.alias_target.source=='native_world_alias_guard')
Check('world_alias_endpoints_remain_separate',math.abs((aliasResult.alias_target.x or 0)-(aliasResult.player.x or 0))>=48)
local aliasHealth=P:GetHealth()
Check('world_alias_diagnostic',aliasHealth.worldAliasGuards>=2)
-- Residual collapse paths closed in v6.1: an alias CANDIDATE whose alias could
-- NOT be confirmed (paired native read failed or native points coincide) must
-- never fall back to the camera projection derived from the suspect world fact
-- -- that fallback was the remaining route to the "line anchored on my own
-- character" failure. Native evidence is kept as-is; without it, fail closed.
local unconfirmed=P:ProjectUnitBatch({{'player','alias_kept','alias_rej'}},{{requireFrontHemisphere=true,worldZOffset=1,validateNativeAgainstCamera=true,reconcileNativeScale=true}})
Check('alias_candidate_keeps_native',unconfirmed.alias_kept.visible==true and unconfirmed.alias_kept.source=='native_alias_candidate' and math.abs((unconfirmed.alias_kept.x or 0)-642)<0.01)
Check('alias_candidate_native_missing_fails_closed',unconfirmed.alias_rej.visible==false and unconfirmed.alias_rej.reason~=nil)
local unconfirmedHealth=P:GetHealth()
Check('alias_candidate_diagnostics',unconfirmedHealth.aliasNativeKept>=1 and unconfirmedHealth.aliasNativeRejects>=1)
-- v7 contract: ProjectWorldBatch must preserve every source index. Sparse Lua
-- arrays are unsafe because ipairs/# stop at the first nil; Range Assist circles
-- naturally include behind-camera samples, so a hole used to truncate the arc.
local worldBatch,worldBatchStatus,worldBatchFacts=P:ProjectWorldBatch({{
  {{x=20,y=0,z=0}},
  {{x=-20,y=0,z=0}},
  {{x='bad',y=0,z=0}},
  {{x=20,y=2,z=0}},
}},{{preferLogicalCamera=true}})
Check('world_batch_camera_ready',worldBatchStatus=='camera')
Check('world_batch_facts_match_call',type(worldBatchFacts)=='table' and worldBatchFacts.total==4 and worldBatchFacts.native==0 and worldBatchFacts.camera==2)
Check('world_batch_dense_index_contract',#worldBatch==4 and type(worldBatch[1])=='table' and type(worldBatch[2])=='table' and type(worldBatch[3])=='table' and type(worldBatch[4])=='table')
Check('world_batch_visible_sentinel',worldBatch[1].visible==true and worldBatch[2].visible==false and worldBatch[3].visible==false and worldBatch[4].visible==true)
local denseCount=0
for _ in ipairs(worldBatch) do denseCount=denseCount+1 end
Check('world_batch_ipairs_crosses_hidden_samples',denseCount==4)
-- Resolution/UI-scale anchor calibration: with a 1280x960 camera frame and
-- a native player anchor at 640,480 this first case is already aligned. Replace
-- the native player anchor with 512,384 (logical 1024x768 centre) and require
-- the EasyPull camera batch to translate rigidly to that native truth.
screen.player={{512,384,1}}
local anchored,anchoredStatus,anchoredFacts=P:ProjectWorldBatch({{
  {{x=20,y=0,z=0.25}}, {{x=20,y=2,z=0.25}}, {{x=20,y=-2,z=0.25}},
}},{{easyPullCompat=true,anchorUnit='player',anchorWorld={{x=10,y=0,z=0.25}}}})
Check('world_batch_anchor_calibration_ready',anchoredStatus=='easypull_camera' and type(anchoredFacts)=='table')
Check('world_batch_anchor_calibration_applied',anchoredFacts.calibrationStatus=='applied' and anchoredFacts.calibrationDx~=nil and anchoredFacts.calibrationDy~=nil)
Check('world_batch_anchor_calibration_translates_points',type(anchored[1])=='table' and anchored[1].visible==true and anchored[1].source=='easypull_camera')
-- Flip the camera so the former "behind" target is now in front. It must be
-- eligible again; this proves the cull follows the camera, not character token.
ReplicatedSuite.Api.CallCapability=function(self,capability,host,method,...)
  local arg,isLocal=(...)
  if capability=='UIParent:GetViewCameraPos' then return true,{{x=0,y=0,z=0}} end
  if capability=='UIParent:GetViewCameraDir' then return true,{{x=-1,y=0,z=0}} end
  if capability=='UIParent:GetViewCameraFov' then return true,1.57 end
  if capability=='X2Unit:GetUnitWorldPositionByTarget' then local p=world[tostring(arg or '')]; return true,p[1],nil,p[2],p[3] end
  if capability=='X2Unit:GetUnitScreenPosition' then local p=screen[tostring(arg or '')]; return true,p[1],nil,p[2],p[3] end
  return false,nil,'unsupported'
end
local flipped=P:ProjectUnitBatch({{'behind'}},{{requireFrontHemisphere=true,worldZOffset=1,validateNativeAgainstCamera=true,reconcileNativeScale=true}})
Check('camera_relative_not_character_relative',flipped.behind.visible==true)
Check('flipped_uses_consistency_guard',flipped.behind.source=='camera_consistency_fallback' or flipped.behind.source=='native_scale_reconciled' or flipped.behind.source=='native_unit')
if passed~=total then os.exit(1) end
print('SCREEN_PROJECTION_FRONT_HEMISPHERE_HARNESS PASS '..tostring(passed)..'/'..tostring(total))
"""
    with tempfile.NamedTemporaryFile("w", suffix=".lua", encoding="utf-8", delete=False) as handle:
        handle.write(script)
        temp = Path(handle.name)
    try:
        result = subprocess.run([texlua, str(temp)], text=True, capture_output=True)
        if result.stdout:
            print(result.stdout.rstrip())
        if result.stderr:
            print(result.stderr.rstrip())
        return result.returncode
    finally:
        temp.unlink(missing_ok=True)


if __name__ == "__main__":
    raise SystemExit(main())
