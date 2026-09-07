#!/usr/bin/env python3
"""Real-Lua regression harness for .18.143 hover-leave/draft/adaptive numeric-range contracts."""
from __future__ import annotations
import pathlib
import subprocess
import tempfile
from rs_lua_runner import RUNNER

ROOT = pathlib.Path(__file__).resolve().parents[1]
FORMS = ROOT / "ui/framework/rs_ui_forms.lua"
RANGE_STORE = ROOT / "ui/framework/rs_ui_numeric_range_store.lua"
THEME = ROOT / "core/rs_theme.lua"
PRIMITIVES = ROOT / "ui/framework/rs_ui_primitives.lua"
BUSINESS_PAGE = ROOT / "presentation/v3/pages/rs_v3_business_pages.lua"


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


def forms_harness() -> None:
    forms = str(FORMS).replace("\\", "/")
    lua = r'''
ALIGN_LEFT=1; ALIGN_RIGHT=2
local factories = {}
local domain = { main=5, clamp=5, restored=5, apply=4 }
local applyWrites = 0
local saved = {}
local saves = 0
local RSUI = {
  metrics={numericRangeExpansions=0}, types={}, State={Normal="normal",Disabled="disabled",Error="error"}
}
function RSUI:RegisterType(name, fn)
  factories[name]=fn; self.types[name]=fn
  self[name]=function(selfOrSpec, maybeSpec)
    local spec = maybeSpec or selfOrSpec
    return fn(spec)
  end
  return true
end
function RSUI:RegisterTypeValidator() return true end
function RSUI:Callback(_, fn, ...) if type(fn)~="function" then return true end return true, fn(...) end
function RSUI:_Count() end
function RSUI:Binding(spec)
  local b={spec=spec, value=spec.value}
  function b:Get() if type(self.spec.get)=="function" then return self.spec.get() end return self.value end
  function b:Set(v, final, source)
    if type(self.spec.set)=="function" then
      local ok, err=self.spec.set(v, final, source)
      if ok==false then return false,err end
    else self.value=v end
    return true
  end
  function b:Commit() return true end
  function b:IsDirty() return false end
  function b:GetError() return nil end
  return b
end
function RSUI:NewComponent(kind,spec,root)
  local c={kind=kind,spec=spec,id=spec.id,root=root,owner="harness",enabled=true,released=false,children={},width=spec.width or 300,height=spec.height or 52}
  function c:AddChild(child) if child then self.children[#self.children+1]=child end return child end
  function c:SetEnabled(v) self.enabled=v~=false; return self.enabled,true,nil end
  function c:EnsureChildEnabled(child,v) if child and child.SetEnabled then child:SetEnabled(v) end return true,nil end
  function c:SetBounds(x,y,w,h) self.x=x;self.y=y;self.width=w;self.height=h;return true end
  function c:Layout(x,y,w,h) self.layout={x=x,y=y,w=w,h=h}; self:SetBounds(x,y,w,h); return h end
  function c:Measure() return self.width,self.height end
  function c:Release() self.released=true; return 1 end
  return c
end
local function textStub(spec)
  local c={root={},spec=spec,text=tostring(spec.text or "")}
  function c:SetText(v) self.text=tostring(v or "");return true end
  function c:SetTone() return true end
  function c:SetVisibility() return true end
  function c:Layout() return true end
  function c:Measure() return spec.width or 80,spec.height or 18 end
  return c
end
function RSUI:Text(spec) return textStub(spec) end
RSUI.NumericRangeStore={}
function RSUI.NumericRangeStore:Get(key) local r=saved[key]; if r then return r.min,r.max end return nil,nil end
function RSUI.NumericRangeStore:Set(key,minv,maxv)
  saved[key]={min=minv,max=maxv}; saves=saves+1; return true
end
local UI={}
function UI:CreatePanel() return {} end
function UI:CreateLabel() local n={text="",style={}}; function n.style:SetFontSize() end; function n.style:SetColor() end; return n end
function UI:SetText(n,v) n.text=tostring(v or ""); return true end
function UI:SetLabelTone() return true end
ReplicatedSuite={UI=UI,RSUI=RSUI,UITokens={}}

-- Stub child controls but preserve the actual NumericField orchestration.
function RSUI:Slider(spec)
  local c={spec=spec,min=spec.min,max=spec.max,step=spec.step,value=spec.binding:Get(),enabled=true}
  function c:SetRange(a,b,step) self.min=a;self.max=b;self.step=step;return true,true end
  function c:Render(v) self.value=v; return v end
  function c:SetEnabled(v) self.enabled=v~=false;return self.enabled,true,nil end
  function c:Layout(x,y,w,h) self.layout={x=x,y=y,w=w,h=h}; return true end
  return c
end
function RSUI:NumericInput(spec)
  local c={spec=spec,value=spec.binding:Get(),draft=spec.binding:Get(),enabled=true,editing=false}
  function c:Render(v) self.value=v; if self.editing~=true then self.draft=v end; return v end
  function c:SetEnabled(v) self.enabled=v~=false;return self.enabled,true,nil end
  function c:Layout(x,y,w,h) self.layout={x=x,y=y,w=w,h=h}; return true end
  function c:GetDraftNumber() return self.draft end
  function c:IsEditing() return self.editing==true end
  function c:SetDraft(v) self.draft=v; self.editing=true end
  function c:EndEditing() self.editing=false; return true end
  function c:CommitAndEndEditing(source)
    local v=self.draft
    local ok=spec.binding:Set(v,true,source or "apply_button")
    self.editing=false
    if ok and type(spec.onChanged)=="function" then spec.onChanged(v,c) end
    return ok
  end
  function c:Commit(v)
    self.draft=v
    local ok=spec.binding:Set(v,true,"edit")
    self.editing=false
    if ok and type(spec.onChanged)=="function" then spec.onChanged(v,c) end
    return ok
  end
  return c
end
function RSUI:Button(spec)
  local c={spec=spec,enabled=true}
  function c:SetEnabled(v) self.enabled=v~=false;return self.enabled,true,nil end
  function c:Layout(x,y,w,h) self.layout={x=x,y=y,w=w,h=h}; return true end
  function c:Release() return 1 end
  function c:Click() if self.enabled==false or type(spec.onClick)~="function" then return false end return spec.onClick(c) end
  return c
end

assert(loadfile([[@@FORMS@@]]))()

-- Base 1..10: accepted exact edit 20 expands only max and persists it.
local f=assert(factories.NumericField({id="field.main",parent={},min=1,max=10,step=1,integer=true,slider=true,stepButtons=false,
  get=function() return domain.main end,set=function(v) domain.main=v; return true end}))
local a,b=f:GetRange(); assert(a==1 and b==10,"initial range mismatch")
assert(f.input:Commit(20)==true,"20 commit failed")
a,b=f:GetRange(); assert(domain.main==20 and a==1 and b==20,"accepted high edit did not expand max")
assert(saved["field.main"].min==1 and saved["field.main"].max==20,"expanded max not persisted")

-- Accepted edit below base min expands min too; expansion is outward-only.
assert(f.input:Commit(-4)==true,"negative commit failed")
a,b=f:GetRange(); assert(domain.main==-4 and a==-4 and b==20,"accepted low edit did not expand min")
assert(saved["field.main"].min==-4 and saved["field.main"].max==20,"expanded min not persisted")

-- Fresh field construction restores persisted presentation endpoints even when
-- the business value itself is back inside the original range.
domain.main=5
local f2=assert(factories.NumericField({id="field.main",parent={},min=1,max=10,step=1,integer=true,slider=true,stepButtons=false,
  get=function() return domain.main end,set=function(v) domain.main=v; return true end}))
a,b=f2:GetRange(); assert(a==-4 and b==20,"persisted adaptive range not restored")

-- A Domain clamp is authoritative: raw request 20 becomes 10, so presentation
-- must not pretend 20 was accepted and must not persist a fake expansion.
local fc=assert(factories.NumericField({id="field.clamp",parent={},min=1,max=10,step=1,integer=true,slider=true,stepButtons=false,
  get=function() return domain.clamp end,set=function(v) domain.clamp=math.max(1,math.min(10,v)); return true end}))
assert(fc.input:Commit(20)==true,"clamped write should be an accepted domain transaction")
a,b=fc:GetRange(); assert(domain.clamp==10 and a==1 and b==10,"domain clamp was bypassed by adaptive UI range")
assert(saved["field.clamp"]==nil,"rejected/clamped presentation range was persisted")

-- A stale/narrow saved range can never shrink a newer code-defined base range.
saved["field.restored"]={min=2,max=8}
local fr=assert(factories.NumericField({id="field.restored",parent={},min=1,max=10,step=1,integer=true,slider=true,stepButtons=false,
  get=function() return domain.restored end,set=function(v) domain.restored=v; return true end}))
a,b=fr:GetRange(); assert(a==1 and b==10,"saved range shrank newer base contract")

-- Explicit Apply: base slider stays 2..10 until exact draft 15 is accepted.
-- Successful commit expands only the presentation max to 15 and persists it.
local fa=assert(factories.NumericField({id="field.apply",parent={},min=2,max=10,hardMin=2,hardMax=24,step=1,integer=true,slider=true,stepButtons=false,applyButton=true,
  get=function() return domain.apply end,set=function(v) applyWrites=applyWrites+1; domain.apply=v; return true end}))
assert(fa.apply~=nil and type(fa.ApplyDraft)=="function","explicit Apply action missing")
fa.input:SetDraft(15)
assert(fa.apply:Click()==true,"Apply click failed")
a,b=fa:GetRange(); assert(domain.apply==15 and a==2 and b==15,"Apply did not commit 15 and expand max")
assert(saved["field.apply"].min==2 and saved["field.apply"].max==15,"Apply expansion not persisted")
assert(applyWrites==1,"Apply wrote domain more than once")
-- Simulate RU LostFocus-before-OnClick ordering: the value is already committed
-- and the later button action must not perform a duplicate Domain write.
fa.input.draft=15; fa.input.editing=false
assert(fa.apply:Click()==true and applyWrites==1,"LostFocus-before-click caused duplicate write")
fa:Layout(0,0,147,30)
assert(fa.apply.layout and (fa.apply.layout.x+fa.apply.layout.w)<=147,"narrow Apply layout overflow")
assert(fa.slider.layout and fa.slider.layout.w>=1 and fa.input.layout and fa.input.layout.w>=1,"narrow controls collapsed invalidly")
assert((RSUI.metrics.numericRangeExpansions or 0)>=3,"range expansion metric missing")
assert(saves>=3,"range persistence was not exercised")
print("UI_ADAPTIVE_RANGE_LUA PASS 26/26")
'''.replace("@@FORMS@@", forms)
    run_lua(lua, "UI_ADAPTIVE_RANGE_LUA PASS 26/26")


def store_harness() -> None:
    store = str(RANGE_STORE).replace("\\", "/")
    lua = r'''
local defs={}
local P={Scope={Account="account"},Lifetime={Permanent="permanent"},V3KeyPrefix="rs:v3:"}
function P:GetStore(id) return defs[id] end
function P:RegisterV3Store(def) defs[def.id]=def; return def end
function P:LoadStore(id) local d=defs[id]; d.apply(d.default(),"empty"); return "empty",nil,nil end
function P:MutateStore(id,fn,options) local ok,err=fn(defs[id]); if ok==false then return false,err end; self.lastDelay=options.delayMs; return true end
local RSUI={}
ReplicatedSuite={Persistence=P,RSUI=RSUI,DiagnosticsManager={Warn=function() end,Error=function() end}}
assert(loadfile([[@@STORE@@]]))()
assert(RSUI.NumericRangePersistenceContractVersion==1,"range store contract missing")
local S=assert(RSUI.NumericRangeStore)
local a,b=S:Get("field.x"); assert(a==nil and b==nil,"fresh range store not empty")
assert(S:Set("field.x",1,20,"harness")==true,"range set failed")
a,b=S:Get("field.x"); assert(a==1 and b==20,"range set/get mismatch")
assert(P.lastDelay==400,"range persistence debounce mismatch")
local snapshot=defs["v3.rsui.numeric_ranges"].get()
assert(snapshot.ranges["field.x"].max==20,"registered V3 store did not expose state")
print("UI_RANGE_STORE_LUA PASS 7/7")
'''.replace("@@STORE@@", store)
    run_lua(lua, "UI_RANGE_STORE_LUA PASS 7/7")


def hover_harness() -> None:
    theme = str(THEME).replace("\\", "/")
    lua = r'''
ALIGN_LEFT=1; ALIGN_RIGHT=2; ALIGN_CENTER=3; ALIGN_TOP_LEFT=4
local function gradient() return {{{0.1,0.1,0.1},{0.1,0.1,0.1},{0.1,0.1,0.1}}} end
ReplicatedSuite={Constants={Color={
  text={1,1,1,1},green={0,1,0,1},yellow={1,1,0,1},orange={1,0.5,0,1},red={1,0,0,1},accent={0,1,1,1},muted={0.5,0.5,0.5,1},
  Gradient={button=gradient()[1],buttonHover={{0.2,0.2,0.2},{0.2,0.2,0.2},{0.2,0.2,0.2}},buttonPushed=gradient()[1],buttonDisabled=gradient()[1]}
}},UITokens={button={normal={0.1,0.1,0.1,1},hover={0.3,0.3,0.3,1},active={0.2,0.2,0.2,1},activeHover={0.4,0.4,0.4,1}}}}
assert(loadfile([[@@THEME@@]]))()
local function drawable()
 local d={}; function d:SetColor(r,g,b,a) self.last={r,g,b,a} end; return d
end
local b={rsButtonBgs={drawable(),drawable(),drawable(),drawable()},rsButtonBgColors={{},{},{},{}},rsButtonActive=false,rsButtonHovered=false}
assert(ReplicatedSuite.Theme:SetButtonHovered(b,true)==true,"hover repaint rejected")
for i=1,4 do assert(b.rsButtonBgs[1].last[i]==b.rsButtonBgs[2].last[i],"normal/highlight differ while hovered") end
assert(ReplicatedSuite.Theme:SetButtonActive(b,true)==true,"active repaint rejected")
for i=1,4 do assert(b.rsButtonBgs[1].last[i]==b.rsButtonBgs[2].last[i],"active refresh reintroduced hover flicker") end
assert(ReplicatedSuite.Theme:SetButtonHovered(b,false)==true,"hover leave repaint rejected")
assert(b.rsButtonBgs[1].last[1]~=b.rsButtonBgs[2].last[1],"leave did not restore distinct native states")
print("UI_STABLE_HOVER_LUA PASS 11/11")
'''.replace("@@THEME@@", theme)
    run_lua(lua, "UI_STABLE_HOVER_LUA PASS 11/11")



def hover_leave_fence_static() -> None:
    primitives = PRIMITIVES.read_text(encoding="utf-8")
    business = BUSINESS_PAGE.read_text(encoding="utf-8")
    checks = {
        "hover_contract_v2": "RSUI.StableButtonHoverContractVersion = 2" in primitives,
        "leave_grace": "STABLE_HOVER_LEAVE_GRACE_MS = 120" in primitives,
        "deferred_leave": "AddHighFrequencyOneShot" in primitives and "CommitLeave" in primitives,
        "physical_recheck": "native:IsMouseOver()" in primitives,
        "enter_cancels_leave": "CancelStableHoverLeave(component, native)" in primitives,
        "visual_page_scope": 'id == "combat_unit_lines" or id == "combat_range_assist"' in business,
        "visual_tick_coalesce": 'reason ~= "visual_tick" and reason ~= "visual_tick_error"' in business,
        "presentation_delay": "visualPageRefreshMs = 160" in business,
        "deactivation_cancel": "S.Scheduler:RemoveTask(visualPageRefreshTask)" in business,
        "transient_module": 'SetTaskModule(visualPageRefreshTask, "presentation", true)' in business,
    }
    failed = [name for name, ok in checks.items() if not ok]
    if failed:
        raise AssertionError("hover leave fence static failures: " + ", ".join(failed))
    print("UI_HOVER_LEAVE_FENCE_STATIC PASS 10/10")

def point_size_apply_static() -> None:
    forms = FORMS.read_text(encoding="utf-8")
    controls = (ROOT / "ui/framework/rs_ui_controls.lua").read_text(encoding="utf-8")
    design = (ROOT / "ui/design_system/rs_ui_design_system_v3.lua").read_text(encoding="utf-8")
    bridge = (ROOT / "features/rs_business_bridge.lua").read_text(encoding="utf-8")
    visual = (ROOT / "presentation/v3/widgets/rs_v3_combat_visual_guides.lua").read_text(encoding="utf-8")
    checks = {
        "explicit_apply_contract": "RSUI.NumericExplicitApplyContractVersion = 1" in forms,
        "compact_apply_default": 'nextSpec.applyButton = spec.applyButton ~= false' in design,
        "apply_reads_draft": "function c:ApplyDraft(source)" in forms and "function c:GetDraftNumber()" in controls,
        "point_size_hard_max": "pointSizeHardMax = 24" in bridge,
        "range_size_domain_uses_hard_max": 'PersistStateMutation(feature,"range_size"' in bridge and "math.min(S.VisualGuideLimits.pointSizeHardMax" in bridge,
        "range_page_base_and_hard_range": 'label = "点大小", min = 2, max = 10, hardMin = 2, hardMax = 24' in BUSINESS_PAGE.read_text(encoding="utf-8"),
        "renderer_extends_above_10": "ResolveVisualPointFontSize" in visual and "math.min(40" not in visual,
    }
    failed = [name for name, ok in checks.items() if not ok]
    if failed:
        raise AssertionError("point-size/apply static failures: " + ", ".join(failed))
    print("UI_POINT_SIZE_APPLY_STATIC PASS 7/7")

def main() -> int:
    forms_harness()
    store_harness()
    hover_harness()
    hover_leave_fence_static()
    point_size_apply_static()
    print("UI_INTERACTION_RANGE_HARNESS PASS 61/61")
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
