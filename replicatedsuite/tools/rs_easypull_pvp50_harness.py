from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BRIDGE = (ROOT / "features/rs_business_bridge.lua").read_text(encoding="utf-8-sig")
PROJ = (ROOT / "services/rs_screen_projection_v3.lua").read_text(encoding="utf-8-sig")
DPS = (ROOT / "features/combat/dps/rs_dps_feature.lua").read_text(encoding="utf-8-sig")
BOOT = (ROOT / "replicatedsuite.lua").read_text(encoding="utf-8-sig")

checks = []
def require(name, cond):
    if not cond:
        raise AssertionError(name)
    checks.append(name)

require("build_tag_family", 'BuildTag = "v3-m1.16.0.18.' in BOOT)
require("range_local_world", 'projection:GetUnitWorldPosition("player", true)' in BRIDGE)
require("range_no_global_world", 'projection:GetUnitWorldPosition("player", false)' not in BRIDGE[BRIDGE.index('local RANGE_ASSIST_TASK'):BRIDGE.index('NewFeature("combat_siege_readiness"')])
require("range_easypull_fallback", 'easyPullCompat=true' in BRIDGE and 'anchorUnit="player"' in BRIDGE and 'anchorWorld={x=px,y=py,z=pz+0.25}' in BRIDGE)
require("range_service_anchor_calibration", 'P.WorldBatchAnchorCalibrationContractVersion = 1' in PROJ and 'calibrationStatus="applied"' in PROJ and 'anchorX-projectedX' in PROJ)
require("range_50ms", 'local RANGE_ASSIST_REFRESH_MS = 50' in BRIDGE)
require("range_high_frequency", 'AddHighFrequencyTask(RANGE_ASSIST_TASK, RANGE_ASSIST_REFRESH_MS' in BRIDGE)
require("range_p1", 'end, false, feature, "P1", 1)' in BRIDGE[BRIDGE.index('local RANGE_ASSIST_TASK'):BRIDGE.index('NewFeature("combat_siege_readiness"')])
require("range_exception_isolation", 'xpcall(function()' in BRIDGE and 'visual_tick_error' in BRIDGE)
require("projection_easypull_option", 'local easyPullCompat = options.easyPullCompat == true' in PROJ)
require("projection_easypull_contract", 'P.EasyPullWorldToScreenContractVersion = 2' in PROJ)
require("projection_easypull_frame", 'function P:_BuildEasyPullCameraFrame()' in PROJ and 'function P:_ProjectWithEasyPullCameraFrame(frame, wx, wy, wz)' in PROJ)
require("projection_easypull_no_camdir_normalize", 'fx,fy,fz=fx/fLen,fy/fLen,fz/fLen' not in PROJ[PROJ.index('function P:_BuildEasyPullCameraFrame()'):PROJ.index('function P:_ProjectWithEasyPullCameraFrame')])
require("projection_strict_depth", 'depth>0 then' in PROJ)
require("projection_call_local_facts", 'cameraRejected=cameraRejected' in PROJ and 'easypull_camera' in PROJ)
require("pvp_50ms_constant", 'local PVP_REFRESH_MS = 50' in DPS)
require("pvp_projection_50ms", 'ProjectionPublishDelayMs()' in DPS and 'PVE_PROJECTION_REFRESH_MS = 400' in DPS)
require("pvp_pending_50ms", 'PendingReplayDelayMs()' in DPS and 'PVE_PENDING_REPLAY_MS = 160' in DPS)
require("pvp_high_frequency_oneshot", 'S.Scheduler.AddHighFrequencyOneShot' in DPS)

print(f"EASYPULL_PVP50_HARNESS PASS | {len(checks)}/{len(checks)}")
