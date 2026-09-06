#!/usr/bin/env python3
"""Static safety/ownership harness for .18.122 Team Sac + marker snapshot."""
from pathlib import Path
import sys

ROOT=Path(__file__).resolve().parents[1]
EXT=(ROOT/'features/combat/team_tools/rs_team_tools_visuals.lua').read_text(encoding='utf-8-sig')
WIDGET=(ROOT/'presentation/v3/widgets/rs_v3_team_sac_overlay.lua').read_text(encoding='utf-8-sig')
PAGE=(ROOT/'presentation/v3/pages/rs_v3_business_pages.lua').read_text(encoding='utf-8-sig')
REG=(ROOT/'features/rs_feature_registry.lua').read_text(encoding='utf-8-sig')
CAP=(ROOT/'core/rs_api_capabilities.lua').read_text(encoding='utf-8-sig')
TOC=(ROOT/'toc.g').read_text(encoding='utf-8-sig')
GATE=(ROOT/'core/rs_foundation_gate.lua').read_text(encoding='utf-8-sig')
ACCEPT=(ROOT/'presentation/v3/rs_v3_acceptance.lua').read_text(encoding='utf-8-sig')

checks=[]
def check(name, cond): checks.append((name, bool(cond)))

check('extension_after_business', TOC.index('features/rs_business_bridge.lua') < TOC.index('features/combat/team_tools/rs_team_tools_visuals.lua'))
check('widget_before_page', TOC.index('presentation/v3/widgets/rs_v3_team_sac_overlay.lua') < TOC.index('presentation/v3/pages/rs_v3_business_pages.lua'))
check('single_feature_authority', 'S.Features.combat_team_tools' in EXT and 'RegisterImplementation' not in EXT and 'Feature.TeamVisuals = V' in EXT)
check('separate_persistent_substore', 'v3.combat.team_tools.visuals' in EXT and 'sacEnabled' in EXT and 'savedMarks' in EXT)
check('bounded_saved_marks', 'MAX_SAVED_MARKS = 16' in EXT and 'NormalizeSavedMarks' in EXT)
check('reference_sac_ids', all(x in EXT for x in ['30098','30137','30141','30142','SPELLEDANCE_ABILITY_INDEX = 14']))
check('shared_roster', 'TeamRosterV3' in EXT and 'AcquireConsumer(ROSTER_TOKEN' in EXT)
check('shared_aura', 'AuraObservationV3' in EXT and 'GetStatusMap' in EXT and 'AcquireConsumer(AURA_TOKEN' in EXT)
check('candidate_cadence', 'CANDIDATE_TASK' in EXT and '10000' in EXT)
check('aura_safety_cadence', 'AURA_TASK' in EXT and '1200' in EXT and 'AURA_EDGE_TASK' in EXT and '120' in EXT)
check('no_domain_tick', 'OnUpdate' not in EXT and 'OnTick' not in EXT)
check('no_domain_screen_projection', 'GetUnitScreenPosition' not in EXT and 'ProjectUnitBatch' not in EXT)
check('presentation_projection_only', 'ScreenProjectionV3' in WIDGET and 'ProjectUnitBatch' in WIDGET)
check('presentation_50ms_only_active', 'AddTask(self.taskName, 50' in WIDGET and '#active == 0' in WIDGET)
check('no_widget_native_aura_reads', 'UnitBuff' not in WIDGET and 'GetTargetAbilityTemplates' not in WIDGET)
check('marker_get_capability', 'X2Unit:GetOverHeadMarker"] = { OfficialState="OfficialEnabled"' in CAP)
check('marker_write_capability', 'X2Unit:SetOverHeadMarker"] = { OfficialState="OfficialEnabled"' in CAP)
check('marker_snapshot_reads_existing_only', 'ReadRosterMarks' in EXT and 'GetOverHeadMarker' in EXT)
check('marker_restore_serial_1100', 'MARK_RESTORE_TASK' in EXT and '1100' in EXT)
check('marker_restore_uses_governed_action', 'ActionCapability("X2Unit:SetOverHeadMarker"' in EXT)
check('marker_restore_readback_before_advance', 'V.restorePending ~= nil' in EXT and 'CallCapability("X2Unit:GetOverHeadMarker"' in EXT and 'V.markerApplied = V.markerApplied + 1' in EXT)
check('marker_restore_native_verify', 'tonumber(current) ~= tonumber(pending.markerIndex)' in EXT)
check('marker_restore_prewrite_read', '标记写入前读取失败' in EXT and 'marker_already_correct' in EXT)
check('marker_snapshot_durable', 'team_marker_save' in EXT and '{ durable = true }' in EXT)
check('sac_release_failure_propagates', 'local stopped, stopErr = self:StopSacObservation("feature_disable")' in EXT and 'if stopped ~= true then return false, stopErr end' in EXT)
check('sac_release_rollback', 'reason = "stop_rollback"' in EXT and 'Aura rollback failed' in EXT)
check('sac_acquire_rollback_verified', 'roster rollback failed' in EXT and 'local released, releaseErr = roster:ReleaseConsumer(ROSTER_TOKEN)' in EXT)
check('marker_no_implicit_clear', 'RemoveAllOverHeadMarker' not in EXT)
check('page_sac_control', 'v3_business_combat_team_tools_sac_toggle' in PAGE and 'SetSacHighlightEnabled' in PAGE)
check('page_marker_controls', all(x in PAGE for x in ['SaveRaidMarkers','RestoreRaidMarkers','ClearSavedRaidMarkers']))
check('registry_truth', 'v3.team_tools + v3.team_visuals' in REG and 'X2Unit:GetOverHeadMarker' in REG and '牺牲之舞' in REG)
check('foundation_gate', 'v3_team_visual_marker_contract' in GATE)
check('acceptance_gate', 'team_visual_marker_contract_v1' in ACCEPT)
check('contract_versions', all(x in EXT for x in ['TeamVisualContractVersion = 1','TeamMarkerSnapshotContractVersion = 1','TeamSacContractVersion = 1']) and 'TeamSacPresentationContractVersion = 1' in WIDGET)

failed=[name for name,ok in checks if not ok]
if failed:
    print(f'TEAM_VISUAL_MARKER_HARNESS FAIL | {len(checks)-len(failed)}/{len(checks)}')
    for name in failed: print(' -',name)
    sys.exit(1)
print(f'TEAM_VISUAL_MARKER_HARNESS PASS | {len(checks)}/{len(checks)}')
