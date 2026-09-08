#!/usr/bin/env python3
"""Runtime-shape + static regression harness for Unit Lines settings consumer (.18.161)."""
from __future__ import annotations
import pathlib
import subprocess
import tempfile
from rs_lua_runner import RUNNER

ROOT = pathlib.Path(__file__).resolve().parents[1]
PAGE = ROOT / "presentation/v3/pages/rs_v3_business_pages.lua"


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


def runtime_composition_harness() -> None:
    page = str(PAGE).replace("\\", "/")
    lua = r'''
local components, factories = {}, {}
local function add(kind, spec)
  spec = spec or {}
  local c={kind=kind,id=spec.id,spec=spec,parent=spec.parent,text=spec.text or "",enabled=true,visible=true}
  components[spec.id or (kind.."#"..tostring(#components+1))]=c
  function c:SetText(v) self.text=tostring(v or ""); return true end
  function c:SetEnabled(v) self.enabled=v==true; return true end
  function c:SetStatus(a,b,d) self.status={a,b,d}; return true end
  function c:Render() self.renders=(self.renders or 0)+1; return true end
  return c
end
local RSUI={}
function RSUI:Button(spec) return add("Button",spec) end
function RSUI:Text(spec) return add("Text",spec) end
function RSUI:UniformGrid(spec) return add("UniformGrid",spec) end
function RSUI:HorizontalBox(spec) return add("HorizontalBox",spec) end
function RSUI:ColorField(spec) local c=add("ColorField",spec); c.get=spec.get; c.set=spec.set; return c end
function RSUI:TableView(spec)
  local c=add("TableView",spec); c.items={}; c.viewState=nil
  function c:SetItems(items,revision) self.items=items or {}; self.revision=revision; return true end
  function c:SetViewState(state,opts) self.viewState=state; self.viewOpts=opts; return true end
  function c:GetItem(i) return self.items[i] end
  return c
end
local D={}
function D:ScrollablePageRoot(parent,idOrSpec)
  local spec=type(idOrSpec)=="table" and idOrSpec or {id=idOrSpec}
  spec.parent=parent
  local c=add("ScrollablePageRoot",spec); return c
end
function D:FeatureSettingsHeader(parent,spec)
  local root=add("SettingsHeader",{id=spec.id.."_header",parent=parent})
  local actions=add("HeaderActions",{id=spec.id.."_actions",parent=root})
  local out={root=root,actions=actions,status={}}
  function out:SetStatus(a,b,c) self.status={a,b,c}; return true end
  return out
end
function D:SettingsSection(parent,spec)
  local root=add("SettingsSection",{id=spec.id.."_section",parent=parent,headerHeight=spec.headerHeight,padding=spec.padding,gap=spec.gap,itemGap=spec.itemGap})
  local content=add("SectionContent",{id=spec.id.."_content",parent=root})
  return {root=root,content=content}
end
function D:SettingsToggleGrid(parent,spec)
  local grid=add("SettingsToggleGrid",{id=spec.id.."_toggle_grid",parent=parent,minCellWidth=spec.minCellWidth,maxColumns=spec.maxColumns,compact=spec.compact,toggleWidth=spec.toggleWidth})
  grid.toggles={}
  function grid:AddToggle(ts)
    ts.parent=self
    local t=add("Toggle",ts); t.get=ts.get; t.set=ts.set
    self.toggles[#self.toggles+1]=t
    return t
  end
  return grid
end
function D:SettingsNumericSlider(parent,spec)
  spec.parent=parent; spec.slider=true
  local c=add("SettingsNumericSlider",spec); c.get=spec.get; c.set=spec.set; return c
end
function D:ResponsiveNumericSetting() error("unit lines must use the full SettingsNumericSlider policy") end
function D:SettingsStyleCardGrid(parent,spec)
  return add("SettingsStyleCardGrid",{id=spec.id.."_style_grid",parent=parent,minCellWidth=spec.minCellWidth,minCellHeight=spec.minCellHeight,maxColumns=spec.maxColumns,gap=spec.gap})
end
function D:SettingsStyleCard(parent,spec)
  local root=add("SettingsStyleCard",{id=spec.id.."_style_card",parent=parent,title=spec.title,minHeight=spec.slot and spec.slot.minHeight,headerHeight=spec.headerHeight})
  local content=add("StyleCardContent",{id=spec.id.."_style_card_content",parent=root})
  return {root=root,content=content}
end
function D:SettingsDiagnostics(parent,spec)
  local root=add("SettingsDiagnostics",{id=spec.id.."_diagnostics",parent=parent,expanded=spec.expanded==true})
  root.expanded=spec.expanded==true
  local content=add("DiagnosticsContent",{id=spec.id.."_diagnostics_content",parent=root})
  return {root=root,content=content,IsExpanded=function(self) return self.root.expanded end}
end
function D:PageHeader() error("legacy PageHeader must not be used by unit lines") end
function D:CompactNumericSetting() error("legacy CompactNumericSetting must not be used by unit lines") end

local feature={
  UpdateTopic="test.unit_lines",
  Diagnostics={consumerCount=1,attemptedPairs=4,drawnRows=1,endpointCollapsed=0,lastStatus="partial",lastFailureReason="unit_projection_unavailable",projection={failures=7}},
}
local projection={
  status="partial", error="unit_projection_unavailable", revision=3,
  rows={{name="自己 ↔ 当前目标",text="自己 ↔ 当前目标",cost={},statusText="可绘制",tone="green"}},
  pointCount=24,pointSize=4,opacity=.8,refreshMs=100,
  showTarget=true,showTargetTarget=true,showFocusTarget=true,showFocusTargetTarget=true,
  pairPoints={target=24,targettarget=24,focus=24,focustarget=24},
  pairSizes={target=4,targettarget=4,focus=4,focustarget=4},
  colors={target={1,.72,.12},targettarget={.94,.42,.2},focus={.35,.82,1},focustarget={.67,.52,1}},
}
function feature:GetProjection() return projection end
function feature:AcquireConsumer() return true end
function feature:ReleaseConsumer() return true end
feature.Commands={
  Refresh=function() return true end,
  SetPairEnabled=function() return true end,
  SetPointCount=function() return true end, SetPointSize=function() return true end,
  SetOpacity=function() return true end, SetRefreshMs=function() return true end,
  SetPairPoints=function() return true end, SetPairSize=function() return true end,
  SetPairColor=function() return true end,
}
local Host={}
function Host:RegisterFactory(route,fn) factories[route]=fn; return true end
local Runtime={enabled=true}
function Runtime:IsEnabled() return self.enabled end
function Runtime:SetPreferredEnabled(_,v) self.enabled=v==true; return true end
ReplicatedSuite={
  RSUI=RSUI, UIV3Design=D, UIV3={PageHost=Host}, Features={combat_unit_lines=feature},
  FeatureRegistry={Get=function() return {name="单位连线",description="desc",status="migrated_partial"} end},
  FeatureRuntime=Runtime, Events=nil, Scheduler=nil,
}
assert(loadfile([[@@PAGE@@]]))()
assert(type(ReplicatedSuite.UIV3.BusinessPagesContract)=="table","business contract missing")
assert(ReplicatedSuite.UIV3.BusinessPagesContract.unitLineSettingsFoundationConsumerContractVersion==3,"consumer contract missing")
local factory=assert(factories["combat.unit_lines"],"unit line route missing")
local root=assert(factory({},"combat.unit_lines"))
assert(components["v3_business_combat_unit_lines_settings_header"],"foundation header missing")
assert(components["v3_business_combat_unit_lines_visibility_section"],"visibility section missing")
local tg=assert(components["v3_business_combat_unit_lines_visibility_grid_toggle_grid"],"toggle grid missing")
assert(#tg.toggles==4,"toggle count mismatch:"..tostring(#tg.toggles))
assert(tg.spec.compact==true and tg.spec.maxColumns==4 and tg.spec.toggleWidth==142,"toggle grid is not compact")
assert(components["v3_business_combat_unit_lines_global_section"],"global section missing")
assert(components["v3_business_combat_unit_lines_styles_section"],"style section missing")
local sg=assert(components["v3_business_combat_unit_lines_style_grid_style_grid"],"style grid missing")
assert(sg.spec.minCellWidth==300 and sg.spec.maxColumns==2 and sg.spec.minCellHeight==116,"style grid responsive policy mismatch")
local styleSection=assert(components["v3_business_combat_unit_lines_styles_section"],"style section missing")
local estimatedStyleHeight=(styleSection.spec.headerHeight or 20)+2*sg.spec.minCellHeight+(sg.spec.gap or 6)+8
assert(estimatedStyleHeight<=270,"style section exceeds 768p dense budget:"..tostring(estimatedStyleHeight))
local numerics=0; local cards=0; local colors=0; local pairSliders=0; local adaptiveSizes=0
for _,c in pairs(components) do
  if c.kind=="SettingsNumericSlider" then
    numerics=numerics+1
    assert(c.spec.slider==true,"standard numeric slider lost slider")
    assert(c.spec.applyButton~=false,"standard numeric slider lost Apply")
    if tostring(c.id):find("_pair_",1,true) then
      pairSliders=pairSliders+1
      if tostring(c.id):find("_size",1,true) then
        assert(c.spec.hardMax==24 and c.spec.fixedRange~=true,"pair point-size must keep adaptive 10->24 range")
        adaptiveSizes=adaptiveSizes+1
      end
    end
  end
  if c.kind=="SettingsStyleCard" then cards=cards+1; assert(c.spec.minHeight==116,"style card height mismatch") end
  if c.kind=="ColorField" then colors=colors+1 end
end
assert(numerics==12,"numeric slider count mismatch:"..tostring(numerics))
assert(pairSliders==8,"pair slider count mismatch:"..tostring(pairSliders))
assert(adaptiveSizes==4,"adaptive pair-size count mismatch:"..tostring(adaptiveSizes))
for _,c in pairs(components) do
  assert(not (c.kind=="HorizontalBox" and tostring(c.id):find("_numeric_row",1,true)),"legacy cramped numeric row remains")
end
assert(cards==4,"style card count mismatch:"..tostring(cards))
assert(colors==4,"color count mismatch:"..tostring(colors))
local diag=assert(components["v3_business_combat_unit_lines_runtime_diagnostics"],"diagnostics disclosure missing")
assert(diag.expanded==false,"diagnostics must default collapsed")
local tableView=assert(components["v3_business_combat_unit_lines_table"],"table missing")
assert(tableView.parent==components["v3_business_combat_unit_lines_runtime_diagnostics_content"],"diagnostic table escaped disclosure")
assert(tableView.spec.desiredRows==5,"diagnostic table rows should be bounded")
assert(root:Refresh()==true,"refresh failed")
local summary=assert(components["v3_business_combat_unit_lines_summary"],"summary missing")
assert(summary.text:find("详细原因见",1,true),"raw diagnostic leaked into primary summary:"..summary.text)
assert(not summary.text:find("unit_projection_unavailable",1,true),"raw failure leaked into summary")
local diagText=assert(components["v3_business_combat_unit_lines_runtime_text"],"diagnostic text missing")
assert(diagText.text:find("unit_projection_unavailable",1,true),"raw failure missing from diagnostics")
assert(tableView.viewState=="ready","table view state mismatch:"..tostring(tableView.viewState))
print("UNIT_LINE_SETTINGS_PAGE_LUA PASS 32/32")
'''.replace("@@PAGE@@", page)
    run_lua(lua, "UNIT_LINE_SETTINGS_PAGE_LUA PASS 32/32")


def static_contract_harness() -> None:
    raw = PAGE.read_text(encoding="utf-8")
    start = raw.index('elseif id == "combat_unit_lines" then')
    end = raw.index('elseif id == "combat_range_assist" then', start)
    branch = raw[start:end]
    required = (
        'D:SettingsSection(root', 'D:SettingsToggleGrid(', 'D:SettingsNumericSlider(',
        'D:SettingsStyleCardGrid(', 'D:SettingsStyleCard(', 'D:SettingsDiagnostics(root',
        'expanded = false', 'unitLineSettingsFoundationConsumerContractVersion = 3',
        'compact = true, toggleWidth = 142', 'minHeight = 116', 'hardMax = 24',
    )
    for token in required:
        if token not in (branch if token != 'unitLineSettingsFoundationConsumerContractVersion = 3' else raw):
            raise AssertionError(f"missing unit-line settings consumer token: {token}")
    forbidden = (
        'D:CompactNumericSetting(', 'D:ResponsiveNumericSetting(', 'slider = false',
        'v3_business_combat_unit_lines_pair_appearance',
        'v3_business_combat_unit_lines_pairs", parent = root',
        '1280', '1920', '2560',
    )
    for token in forbidden:
        if token in branch:
            raise AssertionError(f"unit-line settings branch contains legacy/resolution-specific token: {token}")


if __name__ == "__main__":
    runtime_composition_harness()
    static_contract_harness()
    print("UNIT_LINE_SETTINGS_PAGE_HARNESS PASS 43/43")
