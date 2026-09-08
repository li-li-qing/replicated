#!/usr/bin/env python3
"""Real-Lua regression harness for RSUI Settings Page Foundation v3 (.18.161)."""
from __future__ import annotations
import pathlib
import subprocess
import tempfile
from rs_lua_runner import RUNNER

ROOT = pathlib.Path(__file__).resolve().parents[1]
LAYOUT = ROOT / "ui/framework/rs_ui_layout_templates.lua"
SETTINGS = ROOT / "ui/framework/rs_ui_settings_foundation.lua"


def run_lua(source: str, marker: str) -> None:
    with tempfile.NamedTemporaryFile("w", suffix=".lua", encoding="utf-8", delete=False) as fh:
        fh.write(source)
        script = pathlib.Path(fh.name)
    try:
        proc = subprocess.run([RUNNER, str(script)], capture_output=True, text=True)
    finally:
        script.unlink(missing_ok=True)
    if proc.returncode != 0:
        raise AssertionError((proc.stdout + proc.stderr).strip())
    if marker not in proc.stdout:
        raise AssertionError(proc.stdout.strip() or f"missing marker {marker}")


def form_row_policy_harness() -> None:
    layout = str(LAYOUT).replace("\\", "/")
    lua = r'''
ALIGN_LEFT=1; ALIGN_CENTER=2
local factories={}
local RSUI={metrics={settingsResponsiveModeChanges=0}, BaseComponent={}}
function RSUI:RegisterType(name,fn) factories[name]=fn; return true end
local function N(v,f) return tonumber(v) or tonumber(f) or 0 end
local function Clamp(v,a,b) v=tonumber(v) or 0; if a and v<a then v=a end; if b and v>b then v=b end; return v end
local function Pad(v) local n=tonumber(v) or 0; return {left=n,right=n,top=n,bottom=n} end
local function Slot(v) return v or {} end
local function Measure(c) return c.dw or 1,c.dh or 1 end
local function Align(origin,available,desired,mode) if mode=="fill" then return origin,available end; return origin,math.min(available,desired) end
local function Arrange(c,x,y,w,h) c.layout={x=x,y=y,w=w,h=h}; return true end
local function Host(kind,spec)
  local c={kind=kind,spec=spec,slots={},width=spec.width,height=spec.height}
  function c:SetBounds(x,y,w,h) self.x=x;self.y=y;self.width=w;self.height=h end
  function c:InvalidateMeasure() end
  function c:InvalidateLayout() end
  return c
end
RSUI.LayoutUtil={N=N,Clamp=Clamp,Pad=Pad,Slot=Slot,Measure=Measure,Align=Align,Arrange=Arrange,Host=Host}
local UI={}
ReplicatedSuite={UI=UI,RSUI=RSUI,UITokens={Number=function(_,_,fallback) return fallback end},SafeTraceback=function(e)return e end}
assert(loadfile([[@@LAYOUT@@]]))()
assert(RSUI.FormRowResponsiveContractVersion==1,"responsive contract missing")
assert(RSUI.FormRowPolicy.version>=2,"policy version missing")
assert(RSUI.FormRowPolicy:ResolveMode(700,"auto",360)=="horizontal","wide auto mode")
assert(RSUI.FormRowPolicy:ResolveMode(220,"auto",360)=="vertical","narrow auto mode")
assert(RSUI.FormRowPolicy:ResolveMode(220,"horizontal",360)=="horizontal","explicit horizontal changed")
local row=assert(factories.FormRow({id="row",parent={},layout="auto",collapseWidth=360,gap=8,padding=0}))
local label={dw=100,dh=16,visible=true}; local control={dw=180,dh=24,visible=true}; local hint={dw=200,dh=12,visible=true}
row.slots={{child=label,slot={hAlign="fill",vAlign="center"}},{child=control,slot={hAlign="fill",vAlign="center"}},{child=hint,slot={hAlign="fill",vAlign="center"}}}
local w,h=row:Measure(220,nil)
assert(row:GetResolvedLayoutMode()=="vertical","row did not collapse")
assert(h==68,"vertical measure used widths as heights: "..tostring(h))
row:Layout(0,0,220,68)
assert(label.layout.y==0 and control.layout.y==24 and hint.layout.y==56,"vertical child stacking mismatch")
row:Layout(0,0,700,32)
assert(row:GetResolvedLayoutMode()=="horizontal","row did not expand")
assert((RSUI.metrics.settingsResponsiveModeChanges or 0)>=1,"mode change metric missing")
print("SETTINGS_FORM_ROW_LUA PASS 10/10")
'''.replace("@@LAYOUT@@", layout)
    run_lua(lua, "SETTINGS_FORM_ROW_LUA PASS 10/10")


def settings_composition_harness() -> None:
    settings = str(SETTINGS).replace("\\", "/")
    lua = r'''
local specs={}
local function component(kind,spec)
  specs[spec.id]={kind=kind,spec=spec}
  local c={kind=kind,id=spec.id,spec=spec,expanded=spec.expanded,children={}}
  function c:SetText(v) self.text=v; return true end
  function c:SetStatus(a,b,d) self.status={a,b,d}; return true end
  function c:SetExpanded(v) self.expanded=v; return true end
  return c
end
local RSUI={LayoutUtil={},metrics={settingsDiagnosticsDisclosuresCreated=0}}
for _,name in ipairs({"VerticalBox","HorizontalBox","Text","StatusChip","UniformGrid","Toggle","GroupBox","CollapsibleGroup","FormRow","NumericField","Divider"}) do
  RSUI[name]=function(selfOrSpec,maybeSpec) return component(name,maybeSpec or selfOrSpec) end
end
function RSUI:Create(name,spec) return component(name,spec) end
local Tokens={
  version=8, settings={settingRowCollapseWidth=360,numericStackBelow=250,styleCardMinWidth=300,styleCardMinHeight=116}, breakpoint={compact=720,regular=980}
}
function Tokens:Number(path,fallback)
  local node=self
  for part in tostring(path):gmatch("[^%.]+") do node=type(node)=="table" and node[part] or nil end
  return tonumber(node) or tonumber(fallback) or 0
end
ReplicatedSuite={RSUI=RSUI,UITokens=Tokens,SafeTraceback=function(e)return e end}
assert(loadfile([[@@SETTINGS@@]]))()
local F=assert(RSUI.SettingsFoundation)
assert(F.contractVersion==3 and RSUI.SettingsFoundationContractVersion==3,"foundation contract missing")
assert(RSUI.SettingsResponsiveContractVersion==2 and RSUI.SettingsStyleCardContractVersion==3,"settings v3 responsive/style contract missing")
assert(RSUI.SettingsScrollSafeCardContractVersion==2 and RSUI.SettingsSectionHierarchyContractVersion==1,"settings hierarchy contract missing")
assert(RSUI.SettingsNumericSliderContractVersion==1,"numeric slider contract missing")
assert(F:ResolveColumns(699,300,8,2)==2,"699 should fit two style cards")
assert(F:ResolveColumns(520,300,8,2)==1,"520 should collapse style cards")
assert(F:ResolveDensity(600)=="compact" and F:ResolveDensity(800)=="regular" and F:ResolveDensity(1200)=="wide","density policy mismatch")
local header=assert(F:CreateHeader({id="u",parent={},title="单位连线",description="说明",status={status="ready"}}))
assert(header.root and header.actions and header.status,"header composition incomplete")
local toggles=assert(F:CreateToggleGrid({id="u",parent={},compact=true,toggleWidth=142})); local t=assert(toggles:AddToggle({onText="开",offText="关"})); assert(t~=nil and toggles.settingsToggleCount==1,"toggle grid add failed"); assert(t.spec.width==142 and t.spec.slot.hAlign=="left","compact toggle width/alignment missing")
local section=assert(F:CreateSection({id="u",parent={},title="全局显示"})); assert(section.root and section.content and section.title and section.divider,"flat section composition incomplete")
assert(specs["u_section"].kind=="VerticalBox","settings section must not be nested card surface")
local cards=assert(F:CreateStyleCardGrid({id="u",parent={}})); assert(specs["u_style_grid"].spec.minCellWidth==300,"style grid token mismatch")
local card=assert(F:CreateStyleCard({id="u",parent={},title="自己 与 当前目标"})); assert(card.root and card.content,"style card incomplete")
assert(specs["u_style_card"].spec.variant=="soft" and specs["u_style_card"].spec.accentStrip==false,"style card hierarchy should be soft/subtle")
local diag=assert(F:CreateDiagnosticsDisclosure({id="u",parent={}})); assert(diag:IsExpanded()==false,"diagnostics must default collapsed")
local row=assert(F:CreateSettingRow({id="u",parent={},label="颜色",createControl=function(parent) return component("ColorField",{id="u_color",parent=parent}) end})); assert(row.root and row.label and row.control,"setting row incomplete")
local numeric=assert(F:CreateNumericSetting({id="u_num",parent={},label="点大小",min=2,max=10,get=function()return 4 end,set=function()return true end})); assert(numeric.spec.responsiveStack==true and numeric.spec.stackBelow==250,"numeric responsive stack not enabled")
local slider=assert(F:CreateNumericSliderSetting({id="u_slider",parent={},label="点大小",min=2,max=10,hardMax=24,get=function()return 4 end,set=function()return true end})); assert(slider.spec.slider==true and slider.spec.applyButton==true and slider.spec.adaptiveRange==true,"standard numeric slider policy missing")
assert((RSUI.metrics.settingsDiagnosticsDisclosuresCreated or 0)==1,"diagnostics metric missing")
local snap=F:GetSnapshot(); assert(snap.contractVersion==3 and snap.compactToggleContractVersion==1 and snap.scrollSafeCardContractVersion==2 and snap.sectionHierarchyContractVersion==1 and snap.numericSliderContractVersion==1 and #snap.factories>=9,"snapshot incomplete")
print("SETTINGS_FOUNDATION_LUA PASS 24/24")
'''.replace("@@SETTINGS@@", settings)
    run_lua(lua, "SETTINGS_FOUNDATION_LUA PASS 24/24")


def static_fences() -> None:
    raw = SETTINGS.read_text(encoding="utf-8")
    source = "\n".join(line for line in raw.splitlines() if not line.lstrip().startswith("--"))
    forbidden = ("OnUpdate", "Tick", "SetDrawPriority(10000", "GetUnitScreenPosition")
    for token in forbidden:
        if token in source:
            raise AssertionError(f"settings foundation contains forbidden hot/native token: {token}")


if __name__ == "__main__":
    form_row_policy_harness()
    settings_composition_harness()
    static_fences()
    print("SETTINGS_PAGE_FOUNDATION_HARNESS PASS 35/35")
