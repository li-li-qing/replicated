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

# 悬浮窗必须只有一个常驻 Dropdown；主页面仍保留三项完整配置。
check(bonds.count("RSUI:Dropdown({") == 1, "floating Bonds must allocate exactly one Dropdown")
check("bondSettingsDropdown" in bonds and 'placeholder = "设置"' in bonds, "single Settings trigger missing")
check("bondOrderDropdown" not in bonds and "bondScopeDropdown" not in bonds and "bondDuplicateDropdown" not in bonds,
      "legacy three floating Dropdown instances remain")
check(page.count('id = "v3_bonds_order"') == 1 and page.count('id = "v3_bonds_scope"') == 1
      and page.count('id = "v3_bonds_duplicate_mode"') == 1, "main page must retain the three full controls")

# 单菜单使用不可选 header 分组，并只调用既有原子 Feature Command。
for marker in ('text = "排序"', 'text = "显示范围"', 'text = "重复材料"', 'kind = "header"', 'selectable = false'):
    check(marker in widget, f"group marker missing: {marker}")
for marker in ("SetDisplayOrder", "SetFilterMask", "SetDuplicateMode"):
    check(marker in bonds, f"atomic command missing: {marker}")
check('get = function() return "__bond_settings__" end' in bonds, "settings trigger sentinel missing")
check('onChanged = function(_, _, control)' in bonds and 'control:Render()' in bonds,
      "settings trigger must reset to placeholder after an action")

# 布局预算：常驻高度 26px，并恢复更多表格行池。
check('height = 26' in bonds, "floating settings row is not compact")
check("slot = instance.headerMode and {size='fill',fill=1,hAlign='fill'} or { size = \"fixed\", width = 112, minWidth = 100 }" in bonds,
      "floating settings must retain 112px while only the home header uses its parent width")
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
