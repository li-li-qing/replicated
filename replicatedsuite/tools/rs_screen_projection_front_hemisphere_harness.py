#!/usr/bin/env python3
"""Execute ScreenProjectionV3 v5 front/coordinate-consistency batching with texlua."""
from __future__ import annotations

import argparse
import shutil
import subprocess
import tempfile
from pathlib import Path

DEFAULT_ROOT = Path(__file__).resolve().parents[1]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", default=None)
    args = parser.parse_args()
    root = Path(args.root).resolve() if args.root else DEFAULT_ROOT
    module = root / "services/rs_screen_projection_v3.lua"
    texlua = shutil.which("texlua")
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
  player={{10,0,0}}, front={{20,5,0}}, behind={{-20,0,0}}, edge={{20,100,0}}, drift={{20,-2,0}},
}}
-- Simulate a RU/UI-scale path where otherwise-valid native points arrive in
-- physical pixels.  Because most of those values are still < logicalW/H, the
-- old threshold-only normalizer could not tell which coordinate space they used.
local screen={{
  player={{640,480,1}}, front={{520,456,1}},
  -- Deliberately wrong mirrored result: positive depth at a corner.
  behind={{1272,955,1}}, edge={{5000,480,1}},
  -- Deliberately stale but still on-screen native point.
  drift={{900,700,1}},
}}
UIParent={{}}
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
Check('contract_version',P.version==5 and P.FrontHemisphereBatchContractVersion==1 and P.UnitProjectionConsistencyContractVersion==1 and type(P.ProjectUnitBatch)=='function')
local result,status=P:ProjectUnitBatch({{'player','front','behind','behind','edge','drift'}},{{requireFrontHemisphere=true,worldZOffset=1,validateNativeAgainstCamera=true,reconcileNativeScale=true}})
Check('batch_ready',status=='ready' and type(result)=='table')
Check('camera_frame_once',calls.camPos==1 and calls.camDir==1 and calls.camFov==1)
Check('deduplicated_world_reads',calls.world==5)
Check('all_world_reads_global',calls.worldLocalTrue==0)
Check('behind_rejected_before_native_screen',type(result.behind)=='table' and result.behind.visible==false and result.behind.reason=='behind_camera' and calls.screen==4)
Check('front_scale_reconciled',result.front.visible==true and result.front.source=='native_scale_reconciled' and math.abs(result.front.x-416)<3)
Check('player_scale_reconciled',result.player.visible==true and result.player.source=='native_scale_reconciled' and result.player.forward>0)
Check('stale_inbounds_native_falls_back',result.drift.visible==true and result.drift.source=='camera_consistency_fallback' and result.drift.x<700)
Check('front_offscreen_preserved_for_presenter_clip',result.edge.visible==true and result.edge.source=='camera_world' and (result.edge.x<0 or result.edge.x>1024 or result.edge.y<0 or result.edge.y>768))
local health=P:GetHealth()
Check('behind_diagnostic',health.behindCameraRejects==1 and health.unitBatches==1)
Check('coordinate_consistency_diagnostics',health.nativeScaleReconciles>=2 and health.nativeConsistencyFallbacks==1)
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
