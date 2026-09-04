#!/usr/bin/env python3
"""Execute the real Unit Lines sampling + smooth render contracts with texlua."""
from __future__ import annotations

import argparse
import shutil
import subprocess
import tempfile
from pathlib import Path

DEFAULT_ROOT = Path(__file__).resolve().parents[1]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", default=None)
    args = parser.parse_args()
    root = Path(args.root).resolve() if args.root else DEFAULT_ROOT
    module = root / "presentation/v3/widgets/rs_v3_combat_visual_guides.lua"
    texlua = shutil.which("texlua")
    if texlua is None:
        print("UNIT_LINE_SAMPLING_HARNESS SKIP | texlua unavailable")
        return 2
    if not module.is_file():
        print(f"UNIT_LINE_SAMPLING_HARNESS FAIL | missing {module}")
        return 1

    module_path = str(module).replace("\\", "/").replace("'", "\\'")
    script = f"""
local projectionState={{pointCount=24,pointSize=4,opacity=0.78,pairPoints={{target=24}},pairSizes={{target=4}},refreshMs=16,
    rows={{{{pairKey='target',x1=100,y1=100,x2=200,y2=100}}}}}}
local uiCalls={{create=0,anchor=0,extent=0,color=0,visible=0}}
local function NewWidget()
  local w={{}}
  function w:CreateColorDrawable() return {{}} end
  return w
end
local UnitFeature={{}}
function UnitFeature:GetProjection() return projectionState end
function UnitFeature:AcquireConsumer() return true end
function UnitFeature:ReleaseConsumer() return true end
local RangeFeature={{GetProjection=function() return {{rows={{}}}} end,AcquireConsumer=function() return true end,ReleaseConsumer=function() return true end}}
ReplicatedSuite = {{
  UI = {{
    CreateEmptyWidget=function(_,parent,id,x,y,w,h,visible,owner) uiCalls.create=uiCalls.create+1; return NewWidget() end,
    SetAnchor=function(...) uiCalls.anchor=uiCalls.anchor+1; return true end,
    SetExtent=function(...) uiCalls.extent=uiCalls.extent+1; return true end,
    SetColor=function(...) uiCalls.color=uiCalls.color+1; return true end,
    SetVisible=function(...) uiCalls.visible=uiCalls.visible+1; return true end,
    TrySetUILayer=function() return true end,
  }},
  Api = {{ GetUiMetrics=function() return 0,0,1,1024,768 end }},
  UIV3 = {{}},
  FeatureRuntime = {{ IsEnabled = function() return false end }},
  Features = {{ combat_unit_lines = UnitFeature, combat_range_assist = RangeFeature }},
  FrameBudget = {{ current={{pressure='Normal'}} }},
}}
dofile('{module_path}')
local P = ReplicatedSuite.UIV3.CombatVisualGuidesV3
local passed,total = 0,0
local function Check(name, ok)
  total=total+1
  if ok then passed=passed+1 else print('FAIL | '..name) end
end
local projection={{pointCount=24,pairPoints={{target=24}},refreshMs=100}}
local near=P:BuildUnitLineSamplePlan({{{{pairKey='target',x1=100,y1=100,x2=200,y2=100}}}},projection,1024,768,'Normal')
Check('near_density_floor', type(near)=='table' and #near==1 and near[1].count==24 and near[1].clipped==false)
local long=P:BuildUnitLineSamplePlan({{{{pairKey='target',x1=50,y1=100,x2=950,y2=100}}}},projection,1024,768,'Normal')
Check('long_adds_samples', type(long)=='table' and #long==1 and long[1].count>48)
local clipped=P:BuildUnitLineSamplePlan({{{{pairKey='target',x1=-10000,y1=384,x2=512,y2=384}}}},projection,1024,768,'Normal')
Check('visible_segment_clip', type(clipped)=='table' and #clipped==1 and clipped[1].clipped==true and math.abs(clipped[1].x1)<0.01 and math.abs(clipped[1].x2-512)<0.01)
local hidden=P:BuildUnitLineSamplePlan({{{{pairKey='target',x1=-100,y1=-100,x2=-50,y2=-50}}}},projection,1024,768,'Normal')
Check('fully_offscreen_cull', type(hidden)=='table' and #hidden==0)
local rows={{{{pairKey='target',x1=0,y1=100,x2=1024,y2=100}},{{pairKey='edge2',x1=0,y1=200,x2=1024,y2=200}},{{pairKey='edge3',x1=0,y1=300,x2=1024,y2=300}},{{pairKey='edge4',x1=0,y1=400,x2=1024,y2=400}}}}
local fast,budget=P:BuildUnitLineSamplePlan(rows,{{pointCount=48,pairPoints={{target=48,edge2=48,edge3=48,edge4=48}},refreshMs=1}},1024,768,'Normal')
local totalDots=0; for _,plan in ipairs(fast or {{}}) do totalDots=totalDots+(plan.count or 0) end
Check('fast_total_budget', budget==256 and totalDots<=256 and totalDots>=192)
local slow,slowBudget=P:BuildUnitLineSamplePlan(rows,{{pointCount=48,pairPoints={{target=48,edge2=48,edge3=48,edge4=48}},refreshMs=100}},1024,768,'Normal')
local slowDots=0; for _,plan in ipairs(slow or {{}}) do slowDots=slowDots+(plan.count or 0) end
Check('slow_budget_more_density', slowBudget==480 and slowDots>totalDots and slowDots<=480)
local pressured,criticalBudget=P:BuildUnitLineSamplePlan(rows,{{pointCount=24,pairPoints={{target=24,edge2=24,edge3=24,edge4=24}},refreshMs=1}},1024,768,'Critical')
local pressuredDots=0; for _,plan in ipairs(pressured or {{}}) do pressuredDots=pressuredDots+(plan.count or 0) end
Check('pressure_sheds_only_extra', criticalBudget==140 and pressuredDots<=140 and pressuredDots>=96 and pressuredDots<totalDots)

P.unitHeld=true
P.unitPools={{}}; P.unitHost=nil; P.hostMetrics={{}}
projectionState.rows={{{{pairKey='target',x1=50,y1=100,x2=950,y2=100}}}}
projectionState.refreshMs=16
ReplicatedSuite.FrameBudget.current.pressure='Critical'
P:RenderUnit()
local first=P:Describe()
Check('progressive_pool_growth', first.unitPoolGrowth<=16 and first.unitPoolGrowth>0 and first.unitVisibleDots<=16 and first.unitRequestedDots>first.unitVisibleDots)
ReplicatedSuite.FrameBudget.current.pressure='Normal'
-- Grow the same pair to its requested count over bounded passes.
for i=1,4 do P:RenderUnit() end
local grown=P:Describe()
Check('pool_reaches_requested_bounded', grown.unitVisibleDots==grown.unitRequestedDots and grown.unitPoolGrowth<=48)
-- Once geometry/style is stable, the Presenter-local cache must prevent all
-- redundant per-dot Native compatibility reads/writes on the next pass.
P:RenderUnit()
local stable=P:Describe()
Check('stable_render_zero_redundant_writes', stable.unitAnchorWrites==0 and stable.unitStyleWrites==0 and stable.unitVisibilityWrites==0 and stable.unitPoolGrowth==0)
-- Moving the segment should touch anchors only; size/color/visibility remain hot-cache hits.
projectionState.rows={{{{pairKey='target',x1=52,y1=100,x2=952,y2=100}}}}
P:RenderUnit()
local moved=P:Describe()
Check('moving_render_anchor_only', moved.unitAnchorWrites>0 and moved.unitStyleWrites==0 and moved.unitVisibilityWrites==0 and moved.unitPoolGrowth==0)
if passed~=total then os.exit(1) end
print('UNIT_LINE_SAMPLING_HARNESS PASS '..tostring(passed)..'/'..tostring(total))
"""
    with tempfile.NamedTemporaryFile("w", suffix=".lua", encoding="utf-8", delete=False) as handle:
        handle.write(script)
        temp = Path(handle.name)
    try:
        result = subprocess.run([texlua, str(temp)], text=True, capture_output=True)
        if result.stdout:
            print(result.stdout.rstrip())
        if result.stderr:
            print(result.stderr.rstrip())
        return result.returncode
    finally:
        temp.unlink(missing_ok=True)


if __name__ == "__main__":
    raise SystemExit(main())
