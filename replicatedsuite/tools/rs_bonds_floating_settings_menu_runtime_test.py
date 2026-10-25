# Replicated Suite · 债券浮窗设置菜单运行时测试
# 作者：Replicated
# QQ群：1104129461
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
harness = r'''
-- 使用真实内容构建器、Dropdown、Binding 和布局；仅原生绘制与 Feature 为受控边界。
local Host = dofile('tools/rs_workspace_home_test_host.lua')
local S, _, _, counts, _, h = Host({deferBuild=true})
S.RSUI.PopupPositioning={
    ResolveDropdown=function(_,control,opts)
        return {width=opts.popupWidth,height=opts.rowHeight*math.min(#control.items,opts.maxVisible)},nil,{visibleRows=opts.maxVisible}
    end,
    ApplyNativeRelativePopup=function(_,popup,control,owner,opts) popup:SetExtent(opts.width,opts.height);return true end,
    CorrectNativePopupToScreen=function() return true end,
}
local Feature = S.Features.Bonds
local state = {order='quantity:east_first', mask=8, duplicate='west'}
function Feature:GetDisplayOrderKey() return state.order end
function Feature:GetFilterMask() return state.mask end
function Feature:GetDuplicateMode() return state.duplicate end
function Feature.Commands:SetDisplayOrder(mode, order) state.order=mode..':'..order;return true end
function Feature.Commands:SetFilterMask(mask)
    if mask==99 then return false,'invalid scope' end
    state.mask=mask;return true
end
function Feature.Commands:SetDuplicateMode(mode) state.duplicate=mode;return true end
local parent=h.Native(nil,'bond_toolbar_parent',0,0,500,300)
local content=assert(S.UIV3.LifeEconomyContent:Create(parent,'Bonds','bond_toolbar_',{}))
local scope,order,duplicate=content.bondScopeDropdown,content.bondOrderDropdown,content.bondDuplicateDropdown
assert(scope and order and duplicate, 'three independent choices missing')
assert(content:Refresh())
assert(scope.value==8 and order.value==state.order and duplicate.value=='west', 'initial values not authoritative')
assert(#scope.items==16 and #order.items==6 and #duplicate.items==3, 'setting choices lost')
for _,width in ipairs({220,300,440}) do
    content.content:Layout(0,0,width,260)
    local previousRight=0
    for _,control in ipairs({scope,order,duplicate}) do
        local rect=control.lastLayout
        assert(rect.x>=previousRight and rect.x+rect.w<=width, 'toolbar overlaps or exceeds content width')
        assert(rect.y==scope.lastLayout.y and rect.h==26, 'toolbar gained a second row')
        previousRight=rect.x+rect.w
    end
end
for _,item in ipairs(scope.items) do assert(scope:SetSelectedValue(item.value));assert(state.mask==item.value) end
for _,item in ipairs(order.items) do assert(order:SetSelectedValue(item.value));assert(state.order==item.value) end
for _,item in ipairs(duplicate.items) do assert(duplicate:SetSelectedValue(item.value));assert(state.duplicate==item.value) end
local oldMask=state.mask
assert(not scope:SetSelectedValue(99) and state.mask==oldMask and scope.value==oldMask, 'failed selection changed saved scope')
state.mask=7;state.order='material:west_first';state.duplicate='all';assert(content:Refresh())
assert(scope.value==7 and order.value==state.order and duplicate.value=='all', 'external changes not synchronized')
assert(scope:Open());assert(order:Open());assert(not scope.open and order.open, 'popups are not exclusive')
assert(content:SetAvailable(false,'disabled'));assert(not order.open, 'popup remains after hiding content')
assert(counts.quotes==0 and counts.acquired==0 and counts.enabledWrites==0, 'settings started unrelated work')
print("BONDS_FLOATING_TOOLBAR_RUNTIME: PASS (layout, all choices, rejection, synchronization, popup lifecycle)")
'''

with tempfile.NamedTemporaryFile("w", suffix=".lua", encoding="utf-8", delete=False) as f:
    f.write(harness)
    temp = Path(f.name)
# 本机没有 texlua，旧实现硬编码它导致 WinError 2，
# 与 README §6.3「不要硬编码 texlua」直接冲突（该约定要求回落到本机真实 Lua 运行时）。
# 这里按优先级挑选，并且优先真实 Lua 5.1；找不到任何运行时按 BLOCKED 退出，不用“跳过=通过”掩盖。
CANDIDATES = ("texlua", "lua5.1", "lua51", "luajit", "lua")
runtime = next((shutil.which(name) for name in CANDIDATES if shutil.which(name)), None)
if runtime is None:
    print("BLOCKED: no Lua runtime found (tried: " + ", ".join(CANDIDATES) + ")")
    raise SystemExit(2)
try:
    result = subprocess.run([runtime, str(temp)], cwd=ROOT, check=False, text=True, capture_output=True)
    if result.stdout:
        print(result.stdout, end="")
    if result.stderr:
        print(result.stderr, end="")
    raise SystemExit(result.returncode)
finally:
    temp.unlink(missing_ok=True)
