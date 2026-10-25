# Replicated Suite · 债券浮窗设置菜单测试
# 作者：Replicated
# QQ群：1104129461
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
widget = (ROOT / "presentation/v3/widgets/rs_v3_life_economy_widgets.lua").read_text(encoding="utf-8")
page = (ROOT / "presentation/v3/pages/rs_v3_life_m16_pages.lua").read_text(encoding="utf-8")
gate = (ROOT / "core/rs_foundation_gate.lua").read_text(encoding="utf-8")
acceptance = (ROOT / "presentation/v3/rs_v3_acceptance.lua").read_text(encoding="utf-8")

start = widget.index('featureName = "Bonds"')
end = widget.index('featureName = "Treasure"', start)
bonds = widget[start:end]

failures = []
def check(condition, message):
    if not condition:
        failures.append(message)

# 用户要求三项直接呈现于同一行；主页面仍保留三项完整配置。
check(bonds.count("RSUI:Dropdown({") == 3, "floating Bonds must expose three Dropdowns")
for name in ("bondScopeDropdown", "bondOrderDropdown", "bondDuplicateDropdown"):
    check(name in bonds, f"floating setting missing: {name}")
check("bondSettingsDropdown" not in bonds, "obsolete combined Settings menu remains")
check(page.count('id = "v3_bonds_order"') == 1 and page.count('id = "v3_bonds_scope"') == 1
      and page.count('id = "v3_bonds_duplicate_mode"') == 1, "main page must retain the three full controls")

# 三项只调用既有原子 Feature Command。
for marker in ("SetDisplayOrder", "SetFilterMask", "SetDuplicateMode"):
    check(marker in bonds, f"atomic command missing: {marker}")
check('__bond_settings__' not in bonds, "current selections must not use a placeholder sentinel")

# 布局预算：常驻高度 26px，并恢复更多表格行池。
check('height = 26' in bonds, "floating settings row is not compact")
check(bonds.count('compact = true') == 3, "three choices must fit narrow windows")
check('spec.featureName == "Bonds" then desiredRows = 9' in widget, "Bonds table row budget was not restored")
check('"toolbar_primary"' not in bonds and '"toolbar_scope"' not in bonds, "old two-row toolbar remains")

# 混载门禁必须识别新的 Presentation 契约。
check('version = 9' in widget and 'bondsDropdownControlsContractVersion = 3' in widget
      and 'bondsFloatingSettingsMenuContractVersion = 1' in widget, "widget v9 contract missing")
check('bondsFloatingSettingsMenuContractVersion' in gate and '(tonumber(lifeWidgets.version) or 0) < 9' in gate,
      "Foundation mixed-version gate missing")
check('bondsFloatingSettingsMenuContractVersion' in acceptance and '(tonumber(lifeWidgets.version) or 0) < 9' in acceptance,
      "V3 acceptance mixed-version gate missing")

if failures:
    for failure in failures:
        print("FAIL:", failure)
    raise SystemExit(1)
print("BONDS FLOATING SETTINGS MENU: PASS")
