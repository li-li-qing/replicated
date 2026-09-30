#!/usr/bin/env python3
"""Static regression guard for Bonds/Auroria ResidentBoard slice.

This intentionally complements rs_bonds_tests.lua: it can run in a plain build
workspace where the historical Lua UI test host is not packaged. It validates
source-level architecture/contract invariants only; it does not pretend to
replace RU-client Native integration testing.
"""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

def read(rel):
    return (ROOT / rel).read_text(encoding="utf-8")

def require(cond, name):
    if not cond:
        raise AssertionError(name)
    print("PASS", name)

boot = read("replicatedsuite.lua")
# 中文维护注释（2026-09-28，Phase 2 Step 3/4）：life_bonds 已搬到独立源码单元，
# rs_life_m16_bundle.lua 已退役；探针改读真正拥有这些契约的文件。
bonds = read("features/life/bonds/rs_bonds_feature.lua")
items = read("data/ids/rs_item_ids.lua")
quests = read("data/ids/rs_quest_ids.lua")
page = read("presentation/v3/pages/rs_v3_life_m16_pages.lua")
widget = read("presentation/v3/widgets/rs_v3_life_economy_widgets.lua")
acceptance = read("features/life/bonds/rs_bonds_acceptance.lua")
v3_acceptance = read("presentation/v3/rs_v3_acceptance.lua")
gate = read("core/rs_foundation_gate.lua")
diagnostics = read("core/rs_diagnostics.lua")

# 中文维护注释（2026-09-28，Phase 2 Step 4）：本条按 §30 分类 B（旧硬编码 version）更新。
# Authority：BuildTag 已按 Phase 0 闭合（.330）、Phase 1 闭合（.331）、Phase 2 首轮闭合（.332）
# 连续合法推进，三份 Phase 报告都有门禁证据；继续 pin 已被取代的 .329 只会产生误报。
require("v3-m1.16.0.18.332-phase2-life-bundle-slice-complete" in boot, "build tag must carry the current cumulative baseline")
for key, value in {
    "prince_purse": 35461, "prince_crate": 42076, "queen_purse": 40928,
    "queen_crate": 42077, "ancestor_purse": 43176, "ancestor_crate": 43177,
}.items():
    require(f"{key} = {value}" in items, f"Auroria item identity {key}")
for quest_id in range(10504, 10516):
    require(str(quest_id) in quests, f"Auroria resident quest {quest_id}")
require('Registry:RegisterAlias("quest", alias[1], alias[2])' in quests and "AURORIA_BOND_GOLDEN_BAG_30" in quests
        and "AURORIA_BOND_HEIR_BOX_20" in quests, "legacy Auroria quest registry keys retained as aliases")

require("Bonds.MultiContinentSnapshotContractVersion = 3" in bonds, "multi-continent v3 contract")
require("Bonds.ResidentBoardFamilyContractVersion = 1" in bonds, "ResidentBoard family contract")
require("Bonds.AuroriaMaterialContractVersion = 1" in bonds, "Auroria material contract")
require("BOND_MATERIAL_KEY_BY_ITEM_TYPE" in bonds and "return BOND_MATERIAL_KEY_BY_ITEM_TYPE[tonumber(itemType)]" in bonds,
        "Bonds inventory aggregation uses prebuilt itemType reverse index")
require('reason == "presentation" and type(self.resourceTotals) == "table"' in bonds
        and 'self.resourceReads = (tonumber(self.resourceReads) or 0) + 1' in bonds
        and 'resourceReads = tonumber(BA.resourceReads) or 0' in bonds,
        "presentation-only dropdown refresh reuses cached resource totals")
# 2026-09-30: 3/4 and 5/6 were sufficient examples, not exclusive requirements.
# Behavior (partial input, mixed families, stale faction, retries) runs in the default Lua suite.
require('for index = 1, 4 do mainlandReady' in bonds and 'for index = 5, 7 do auroriaReady' in bonds
        and 'mixed_board_families' in bonds and 'location_faction_conflict' in bonds,
        "partial board families require unambiguous continent evidence")
require('forceRead = reason == "page_manual"' in bonds and 'demandProbe = reason == "demand_start" or reason == "initial"' in bonds
        and 'boundaryProbe = reason == "zone_changed" or reason == "entered_world"' in bonds
        and 'local shouldRead = not projectionOnly and dateReady' in bonds,
        "board probing excludes pure projection events and undated observations")
require('SubscribeOptional("ENTER_ANOTHER_ZONEGROUP"' in bonds and 'SubscribeOptional("ENTERED_WORLD"' in bonds
        and 'SubscribeOptional("LEFT_LOADING"' in bonds and 'BONDS_LOCATION_DELAYS = { 750, 1500, 3000 }' in bonds
        and 'AddOneShot(BONDS_ZONE_REFRESH_TASK, delay' in bonds and 'RemoveTask(BONDS_ZONE_REFRESH_TASK)' in bonds
        and 'S.Generation ~= generation' in bonds and 'Bonds.locationEpoch ~= epoch' in bonds,
        "resident-board recovery is bounded, cancellable and generation guarded")
require("BondSnapshotLineCount(out) > 0 and out or nil" in bonds, "empty snapshots rejected")
require("local function MergeBondSnapshot(previous, captured, continentKey)" in bonds
        and 'probe.captureAction = "merged_new_board_lines"' in bonds
        and 'probe.addedLines = tonumber(addedLines) or 0' in bonds,
        "daily snapshots merge per-board evidence instead of replacing whole continent")
require('return "auroria:" .. suffix' in bonds, "Auroria completion latch has isolated daily key")
require('for number in string.gmatch(tostring(text or ""), "(%d+)") do' in bonds
        and 'for amount in pairs(observed) do' in bonds,
        "Auroria fallback identity scans all numeric evidence before inferring purse/crate")
require('"котом", "Котом"' in bonds,
        "Auroria RU Ancestor coinpurse wording is recognized before ambiguous quantity fallback")
require('materialKey = auroriaToken' in bonds and 'auroria_token' not in bonds.replace('-- auroria_token', ''),
        "Auroria rows use real material identities")
require("SetDisplayOrder" in bonds and "SetFilterMask" in bonds and "SetDuplicateMode" in bonds,
        "atomic dropdown commands")
require('value.sortMode == "material"' in bonds and 'state.sortMode == "material"' in bonds,
        "Bonds domain accepts persisted material sort mode")
require('按数量 · 少→多' in page and '按数量 · 多→少' in page and '按材料 · 正序' in page and '按材料 · 倒序' in page,
        "main Bonds sort dropdown exposes quantity directions and material ordering")
require('按数量 · 少→多' in widget and '按材料 · 正序' in widget,
        "floating Bonds sort dropdown matches main page semantics")

require('id = "v3_bonds_order"' in page and 'id = "v3_bonds_scope"' in page and 'id = "v3_bonds_duplicate_mode"' in page,
        "main Bonds page uses three dropdowns")
require('v3_bonds_q20' not in page and 'v3_bonds_priority' not in page,
        "legacy Bonds option buttons removed from main page")
require("bondSettingsDropdown" in widget and 'placeholder = "设置"' in widget,
        "floating Bonds widget uses the single compact settings dropdown")
require("bondOrderDropdown" not in widget and "bondScopeDropdown" not in widget and "bondDuplicateDropdown" not in widget,
        "floating Bonds widget no longer keeps three persistent dropdowns")
require('text = "排序"' in widget and 'text = "显示范围"' in widget and 'text = "重复材料"' in widget and 'kind = "header"' in widget,
        "floating Bonds settings menu groups sort/scope/duplicate actions")
require('"settings_row"' in widget and 'height = 26' in widget and 'spec.featureName == "Bonds" then desiredRows = 9' in widget,
        "floating Bonds single-row controls restore vertical table budget")
require("bondsDropdownControlsContractVersion = 3" in widget and "bondsFloatingSettingsMenuContractVersion = 1" in widget
        and "bondsMultiContinentContractVersion = 3" in widget,
        "floating Bonds v9 compact settings-menu contracts")
require("ResidentBoardFamilyContractVersion" in acceptance and "SetFilterMask" in acceptance,
        "Bonds acceptance requires material-sort contracts")
require("bondsDropdownControlsContractVersion" in v3_acceptance and "bondsResidentBoardFamilyContractVersion" in v3_acceptance,
        "V3 acceptance requires Bonds dropdown/family contracts")
# 维护（2026-09-30）：Phase 3 的 Feature 判定归 acceptance；Core 仍验 UIV3，且必须执行只读通道。
require("F.ResidentBoardFamilyContractVersion" in acceptance and "runtime = true" in acceptance
        and "bondsDropdownControlsContractVersion" in gate and "self:RunRuntimeContracts(report)" in gate,
        "feature-owned live gate and Core presentation gate reject mixed old/new Bonds files")
require("进入西/东/原大陆可读居民板区域后点刷新" in diagnostics and "cache.lastBoardProbe" in diagnostics,
        "Bonds diagnostics exposes Auroria probe evidence")

print("BONDS AURORIA REGRESSION: PASS")
