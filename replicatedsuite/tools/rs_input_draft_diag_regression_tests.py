#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

def read(rel):
    return (ROOT / rel).read_text(encoding="utf-8")

def require(cond, msg):
    if not cond:
        raise AssertionError(msg)

controls = read("ui/framework/rs_ui_controls.lua")
profiles = read("presentation/v3/pages/rs_v3_feature_profiles_page.lua")
business = read("presentation/v3/pages/rs_v3_business_pages.lua")
diag = read("presentation/v3/widgets/rs_v3_module_diagnostics_window.lua")
copybox = read("ui/framework/rs_ui_diagnostic_copy_box.lua")
foundation = read("core/rs_foundation_gate.lua")
acceptance = read("presentation/v3/rs_v3_acceptance.lua")

require("InputActionDraftReadContractVersion = 1" in controls, "TextInput action draft contract missing")
require("function c:GetActionValue() return self:GetDraftValue() end" in controls, "TextInput action read does not use current draft")
require("local name = ReadActionText(createInput)" in profiles, "feature profile create still reads committed binding")
require("local name = ReadActionText(renameInput)" in profiles, "feature profile rename still reads committed binding")
# 2026-10-07: user removed hotkey profiles; preserve active profile draft checks
# above and assert the retired input/native feature cannot silently return.
require("hotkeyNameInput" not in business, "retired hotkey profile input remains")
require('Add("tools_hotkey_profiles"' not in read("features/rs_feature_registry.lua"), "retired hotkey feature returned")
require("features/tools/rs_hotkey_profiles_feature.lua" not in read("toc.g"), "retired hotkey feature still loads")
require("local NORMAL_PAGE_CAPACITY = 2048" in diag, "diagnostic safe default capacity missing")
require("function W:_AutoRepageReadback" in diag, "diagnostic automatic readback repage missing")
require("Hub.Repage" in diag and "actualBytes" in diag, "diagnostic auto fit is not based on immutable repage/native readback")
require("preferredPageCapacity" in diag, "diagnostic measured capacity is not retained for the load")
require("DiagnosticCopyBoxContractVersion = 3" in copybox, "diagnostic copybox contract not bumped")
require("DiagnosticCopyBoxContractVersion) or 0) >= 3" in foundation, "foundation does not reject old copybox overlay")
require("AutoReadbackRepageContractVersion" in foundation, "foundation does not require auto-repage window contract")
require("InputActionDraftReadContractVersion" in acceptance, "acceptance does not reject old TextInput action contract")
print("PASS input-draft/diagnostic-autofit regression contracts")
