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
bundle = read("features/life/rs_life_m16_bundle.lua")
items = read("data/ids/rs_item_ids.lua")
quests = read("data/ids/rs_quest_ids.lua")
page = read("presentation/v3/pages/rs_v3_life_m16_pages.lua")
widget = read("presentation/v3/widgets/rs_v3_life_economy_widgets.lua")
acceptance = read("features/life/bonds/rs_bonds_acceptance.lua")
v3_acceptance = read("presentation/v3/rs_v3_acceptance.lua")
gate = read("core/rs_foundation_gate.lua")
diagnostics = read("core/rs_diagnostics.lua")

require("v3-m1.16.0.18.303-bonds-material-quantity-sort" in boot, "build tag advanced")
for key, value in {
    "prince_purse": 35461, "prince_crate": 42076, "queen_purse": 40928,
    "queen_crate": 42077, "ancestor_purse": 43176, "ancestor_crate": 43177,
}.items():
    require(f"{key} = {value}" in items, f"Auroria item identity {key}")
for quest_id in range(10504, 10516):
    require(str(quest_id) in quests, f"Auroria resident quest {quest_id}")
require('Registry:RegisterAlias("quest", alias[1], alias[2])' in quests and "AURORIA_BOND_GOLDEN_BAG_30" in quests
        and "AURORIA_BOND_HEIR_BOX_20" in quests, "legacy Auroria quest registry keys retained as aliases")

require("Bonds.MultiContinentSnapshotContractVersion = 3" in bundle, "multi-continent v3 contract")
require("Bonds.ResidentBoardFamilyContractVersion = 1" in bundle, "ResidentBoard family contract")
require("Bonds.AuroriaMaterialContractVersion = 1" in bundle, "Auroria material contract")
require("BOND_MATERIAL_KEY_BY_ITEM_TYPE" in bundle and "return BOND_MATERIAL_KEY_BY_ITEM_TYPE[tonumber(itemType)]" in bundle,
        "Bonds inventory aggregation uses prebuilt itemType reverse index")
require('reason == "presentation" and type(self.resourceTotals) == "table"' in bundle
        and 'self.resourceReads = (tonumber(self.resourceReads) or 0) + 1' in bundle
        and 'resourceReads = tonumber(BA.resourceReads) or 0' in bundle,
        "presentation-only dropdown refresh reuses cached resource totals")
require('BondBoardLineCount(boards, 3) > 0 and BondBoardLineCount(boards, 4) > 0' in bundle,
        "mainland family uses boards 3/4 evidence")
require('BondBoardLineCount(boards, 5) > 0 or BondBoardLineCount(boards, 6) > 0' in bundle,
        "Auroria family uses boards 5/6 evidence")
require('forceRead = reason == "page_manual"' in bundle and 'demandProbe = reason == "demand_start" or reason == "initial"' in bundle
        and 'boundaryProbe = reason == "zone_changed" or reason == "entered_world"' in bundle
        and 'local shouldRead = forceRead or demandProbe or boundaryProbe' in bundle,
        "manual, Demand 0->1 and zone-boundary board probing")
require('SubscribeOptional("ENTER_ANOTHER_ZONEGROUP"' in bundle and 'SubscribeOptional("ENTERED_WORLD"' in bundle
        and 'AddOneShot(BONDS_ZONE_REFRESH_TASK, 750' in bundle and 'RemoveTask(BONDS_ZONE_REFRESH_TASK)' in bundle,
        "resident-board zone transitions use one debounced scheduler one-shot")
require("BondSnapshotLineCount(out) > 0 and out or nil" in bundle, "empty snapshots rejected")
require("local function MergeBondSnapshot(previous, captured, continentKey)" in bundle
        and 'probe.captureAction = "merged_new_board_lines"' in bundle
        and 'probe.addedLines = tonumber(addedLines) or 0' in bundle,
        "daily snapshots merge per-board evidence instead of replacing whole continent")
require('return "auroria:" .. suffix' in bundle, "Auroria completion latch has isolated daily key")
require('for number in string.gmatch(tostring(text or ""), "(%d+)") do' in bundle
        and 'for amount in pairs(observed) do' in bundle,
        "Auroria fallback identity scans all numeric evidence before inferring purse/crate")
require('"котом", "Котом"' in bundle,
        "Auroria RU Ancestor coinpurse wording is recognized before ambiguous quantity fallback")
require('materialKey = auroriaToken' in bundle and 'auroria_token' not in bundle.replace('-- auroria_token', ''),
        "Auroria rows use real material identities")
require("SetDisplayOrder" in bundle and "SetFilterMask" in bundle and "SetDuplicateMode" in bundle,
        "atomic dropdown commands")
require('value.sortMode == "material"' in bundle and 'state.sortMode == "material"' in bundle,
        "Bonds domain accepts persisted material sort mode")
require('按数量 · 少→多' in page and '按数量 · 多→少' in page and '按材料 · 正序' in page and '按材料 · 倒序' in page,
        "main Bonds sort dropdown exposes quantity directions and material ordering")
require('按数量 · 少→多' in widget and '按材料 · 正序' in widget,
        "floating Bonds sort dropdown matches main page semantics")

require('id = "v3_bonds_order"' in page and 'id = "v3_bonds_scope"' in page and 'id = "v3_bonds_duplicate_mode"' in page,
        "main Bonds page uses three dropdowns")
require('v3_bonds_q20' not in page and 'v3_bonds_priority' not in page,
        "legacy Bonds option buttons removed from main page")
require("bondOrderDropdown" in widget and "bondScopeDropdown" in widget and "bondDuplicateDropdown" in widget,
        "floating Bonds widget uses three dropdowns")
require('"toolbar_primary"' in widget and '"toolbar_scope"' in widget and 'spec.featureName == "Bonds" then desiredRows = 7' in widget,
        "floating Bonds dropdowns remain usable at minimum width")
require("bondsDropdownControlsContractVersion = 2" in widget and "bondsMultiContinentContractVersion = 3" in widget,
        "floating Bonds v8 sort/dropdown contracts")
require("ResidentBoardFamilyContractVersion" in acceptance and "SetFilterMask" in acceptance,
        "Bonds acceptance requires 18.303 contracts")
require("bondsDropdownControlsContractVersion" in v3_acceptance and "bondsResidentBoardFamilyContractVersion" in v3_acceptance,
        "V3 acceptance requires Bonds dropdown/family contracts")
require("Bonds.ResidentBoardFamilyContractVersion" in gate and "bondsDropdownControlsContractVersion" in gate,
        "Foundation gate rejects mixed old/new Bonds files")
require("进入西/东/原大陆可读居民板区域后点刷新" in diagnostics and "cache.lastBoardProbe" in diagnostics,
        "Bonds diagnostics exposes Auroria probe evidence")

print("BONDS AURORIA REGRESSION: PASS")
