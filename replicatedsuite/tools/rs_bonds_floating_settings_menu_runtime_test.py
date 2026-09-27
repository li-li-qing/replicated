from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
source = (ROOT / "presentation/v3/widgets/rs_v3_life_economy_widgets.lua").read_text(encoding="utf-8")
start = source.index("local BOND_ORDER_ITEMS = {")
end = source.index("-- 维护（overview-content-1）", start)
production_chunk = source[start:end]

harness = production_chunk + r'''
local Feature = {
    GetDisplayOrderKey = function(self) return "quantity:east_first" end,
    GetFilterMask = function(self) return 8 end,
    GetDuplicateMode = function(self) return "west" end,
}
local items = BuildBondFloatingSettingsItems(Feature)
assert(#items == 28, "expected 28 grouped menu entries, got " .. tostring(#items))
local headers, checked = 0, 0
local sawOrder, sawScope, sawDuplicate = false, false, false
for _, item in ipairs(items) do
    if item.kind == "header" then
        headers = headers + 1
        assert(item.selectable == false, "headers must be non-selectable")
    end
    local text = tostring(item.text or "")
    if string.sub(text, 1, 3) == "✓" then checked = checked + 1 end
    if item.value == "order|quantity:east_first" and string.find(text, "✓", 1, true) then sawOrder = true end
    if item.value == "scope|8" and string.find(text, "✓", 1, true) then sawScope = true end
    if item.value == "duplicate|west" and string.find(text, "✓", 1, true) then sawDuplicate = true end
end
assert(headers == 3, "expected three group headers")
assert(checked == 3, "expected exactly three current-setting checks, got " .. tostring(checked))
assert(sawOrder and sawScope and sawDuplicate, "current Feature values were not marked in all three groups")
print("BONDS_FLOATING_SETTINGS_MENU_RUNTIME: PASS")
'''

with tempfile.NamedTemporaryFile("w", suffix=".lua", encoding="utf-8", delete=False) as f:
    f.write(harness)
    temp = Path(f.name)
try:
    result = subprocess.run(["texlua", str(temp)], check=False, text=True, capture_output=True)
    if result.stdout:
        print(result.stdout, end="")
    if result.stderr:
        print(result.stderr, end="")
    raise SystemExit(result.returncode)
finally:
    temp.unlink(missing_ok=True)
