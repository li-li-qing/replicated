#!/usr/bin/env python3
from pathlib import Path
import subprocess, tempfile
from rs_lua_runner import RUNNER

ROOT = Path(__file__).resolve().parents[1]
LAYOUT = (ROOT / 'core/rs_layout.lua').as_posix()

LUA = r'''
ReplicatedSuite = {
  BootError = nil,
  Constants = {
    Breakpoint = { COMPACT = 1150, STANDARD = 1700, WIDE = 2300, NARROW_ONE_COLUMN = 760 },
    SafeArea = 12, SnapDistance = 16,
    ResolutionSafety = { edge=12, spawnX=300, spawnY=100, spawnGapX=8, spawnGapY=8, maxColumns=4 },
    MinAddonScale = 0.80, MaxAddonScale = 1.20,
    Layout = { margin=10, titleHeight=40, tabHeight=28, cardGap=8, rowHeight=30, compactRowHeight=24 },
    MainWindow = { threeColumnWidth=1180, threeColumnHeight=900, twoColumnWidth=900, twoColumnHeight=760, oneColumnWidth=620, oneColumnHeight=700, minWidth=560, minHeight=600 },
  },
  AppState = { settings = { addonScale = 1 } },
  Api = {},
}
UIParent = {}
local metricW, metricH, metricScale = 2560, 1440, 1
local uiParentX, uiParentY = 0, 0
function UIParent:GetEffectiveOffset() return uiParentX * metricScale, uiParentY * metricScale end
function ReplicatedSuite.Api:GetUiMetrics() return metricW, metricH, metricScale, metricW / metricScale, metricH / metricScale end
assert(loadfile([[__LAYOUT__]]))()
local L = ReplicatedSuite.Layout
local pass, fail = 0, 0
local function Check(name, ok, detail)
  if ok then pass = pass + 1 else fail = fail + 1; print('FAIL | '..name..' | '..tostring(detail or '')) end
end
local function SetMetrics(w,h,s) metricW,metricH,metricScale=w,h,s or 1; L:Invalidate() end
local function Widget(x,y,w,h)
  return {
    GetEffectiveOffset=function() return x*metricScale,y*metricScale end,
    GetEffectiveExtent=function() return w*metricScale,h*metricScale end,
    GetOffset=function() return x,y end, GetWidth=function() return w end, GetHeight=function() return h end,
  }
end

-- Save a real free-floating surface at 2560x1440.
SetMetrics(2560,1440,1)
local state = { userMoved=true }
local sw, sh = 420, 280
L:StorePlacement(state, Widget(1800,980,sw,sh), { mode='free' })
Check('responsive_metadata_written', state.savedLogicalWidth==2560 and state.savedLogicalHeight==1440 and state.normalizedCenterX~=nil and state.normalizedCenterY~=nil,
  tostring(state.savedLogicalWidth)..'x'..tostring(state.savedLogicalHeight))
local rx, ry = state.normalizedCenterX, state.normalizedCenterY

local resolutions = {
  {1024,768},{1152,864},{1176,664},{1280,720},{1280,768},{1280,800},{1280,960},{1280,1024},{1280,1440},
  {1360,768},{1366,768},{1440,1080},{1600,900},{1600,1024},{1600,1200},{1680,1050},{1920,1080},{1920,1200},{1920,1440},{2560,1440}
}
for i,r in ipairs(resolutions) do
  SetMetrics(r[1],r[2],1)
  local x,y = L:ResolvePlacement(state, sw, sh, 300,100,{mode='free'})
  local c=L:GetContext()
  local minX = c.safeLeft - sw + math.max(8,math.min(sw,72)); local maxX = c.logicalWidth-c.safeRight-math.max(8,math.min(sw,72))
  local minY = c.safeTop - sh + math.max(18,math.min(sh,sh)); local maxY = c.logicalHeight-c.safeBottom-18
  Check('free_recoverable_'..i, x>=minX-0.01 and x<=maxX+0.01 and y>=minY-0.01 and y<=maxY+0.01, tostring(x)..','..tostring(y)..' @ '..r[1]..'x'..r[2])
  if r[1]==2560 and r[2]==1440 then
    Check('same_viewport_exact_restore', math.abs(x-1800)<0.01 and math.abs(y-980)<0.01, tostring(x)..','..tostring(y))
  end
end

-- Edge-anchored screen buttons retain their user-selected corner/margins on every resolution.
SetMetrics(1920,1080,1)
local storedButton = { userMoved=true }
L:StorePlacement(storedButton, Widget(1738,1000,104,26), { mode='strict' })
Check('strict_store_writes_edge_intent', storedButton.coordinateSpace=='logical-edge-v1' and storedButton.x==nil and storedButton.y==nil
  and (storedButton.anchorH=='LEFT' or storedButton.anchorH=='RIGHT') and (storedButton.anchorV=='TOP' or storedButton.anchorV=='BOTTOM'),
  tostring(storedButton.coordinateSpace)..'/'..tostring(storedButton.anchorH)..'/'..tostring(storedButton.anchorV))
local edge = { coordinateSpace='logical-edge-v1', anchorH='RIGHT', anchorV='BOTTOM', offsetX=24, offsetY=36 }
for i,r in ipairs(resolutions) do
  SetMetrics(r[1],r[2],1)
  local x,y=L:ResolvePlacement(edge,104,26,300,100,{mode='strict'})
  local c=L:GetContext()
  local ex=c.logicalWidth-c.safeRight-24-104; local ey=c.logicalHeight-c.safeBottom-36-26
  Check('edge_button_'..i, math.abs(x-ex)<0.01 and math.abs(y-ey)<0.01, tostring(x)..','..tostring(y))
end

-- Overlay host local conversion: projected UIParent point must subtract the live host origin.
SetMetrics(1280,768,1)
local host = Widget(7,13,200,200)
local lx,ly,meta=L:ScreenPointToWidgetLocal(host,640,384)
Check('screen_to_host_local', lx==633 and ly==371 and meta.originX==7 and meta.originY==13, tostring(lx)..','..tostring(ly))

-- UI scale must not corrupt logical host origin conversion.
SetMetrics(2560,1440,1.25)
local hostScaled = Widget(11,19,200,200)
local sx,sy,smeta=L:ScreenPointToWidgetLocal(hostScaled,1000,700)
Check('scaled_host_origin_logical', math.abs(sx-989)<0.01 and math.abs(sy-681)<0.01 and math.abs(smeta.originX-11)<0.01 and math.abs(smeta.originY-19)<0.01, tostring(sx)..','..tostring(sy))

-- UIParent itself may have an effective screen origin after Native correction.
-- Projection points are UIParent-local, so only host-origin MINUS UIParent-origin
-- may be subtracted. This prevents a second offset on non-default resolutions.
SetMetrics(1280,768,1)
uiParentX, uiParentY = 23, 17
local correctedHost = Widget(30,30,200,200) -- effective screen origin; UIParent-local = 7,13
local cx,cy,cmeta=L:ScreenPointToWidgetLocal(correctedHost,640,384)
Check('ui_parent_origin_removed_once', cx==633 and cy==371 and cmeta.originX==7 and cmeta.originY==13
  and cmeta.uiParentOriginX==23 and cmeta.uiParentOriginY==17, tostring(cx)..','..tostring(cy)..' parent='..tostring(cmeta.uiParentOriginX)..','..tostring(cmeta.uiParentOriginY))
uiParentX, uiParentY = 0, 0

print('RESOLUTION_COORDINATE_HARNESS PASS '..pass..'/'..(pass+fail))
os.exit(fail==0 and 0 or 1)
'''.replace('__LAYOUT__', LAYOUT)

def main():
    with tempfile.NamedTemporaryFile('w', suffix='.lua', delete=False, encoding='utf-8') as f:
        f.write(LUA); name=f.name
    p=subprocess.run([RUNNER, name], text=True, capture_output=True)
    print(p.stdout, end='')
    if p.returncode != 0:
        print(p.stderr, end='')
        raise SystemExit(p.returncode)

if __name__=='__main__': main()
