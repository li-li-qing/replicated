------------------------------------------------------------------------
-- 工作台配色预设（2026-09-18）。Theme owns 色彩；Workspace 仅保存预设名。
-- 不修改 AppState 老存档/Canonical，不覆盖用户字号/透明度/几何。色表原位更新，
-- 保持 UITokens 引用。只在初始化/显式切换遍历当前 UI.controls，先查代内可用性，
-- 不追 Native 父子节点、不创建/销毁 Drawable，渐变仅用现有 ChangeColor1/2/3。
------------------------------------------------------------------------
if ReplicatedSuite==nil or ReplicatedSuite.BootError~=nil then return end
local S=ReplicatedSuite;local T=S.Theme;local C=S.Constants and S.Constants.Color
if not T or not C then return end
local function Copy(v)if type(v)~='table'then return v end;local r={};for k,x in pairs(v)do r[k]=Copy(x)end;return r end
local defaults=Copy(C);local buttonDefaults=Copy(S.UITokens and S.UITokens.button or {})
local function Assign(target,values)
 for k,v in pairs(values)do if type(v)=='table'then target[k]=type(target[k])=='table' and target[k] or {};Assign(target[k],v)else target[k]=v end end
end
local palettes={
 gold={panel={0.030,0.026,0.022,0.98},panelAlt={0.047,0.040,0.030,0.98},card={0.043,0.036,0.027,0.97},cardHeader={0.075,0.058,0.035,0.98},
  border={0.67,0.49,0.23,0.65},borderSoft={0.34,0.27,0.16,0.65},text={0.96,0.92,0.83,1},textMuted={0.72,0.68,0.59,1},accent={0.97,0.76,0.38,1},accentLine={0.97,0.75,0.36,0.75}},
 contrast={panel={0.009,0.012,0.017,1},panelAlt={0.030,0.036,0.044,1},card={0.020,0.026,0.034,1},cardHeader={0.060,0.073,0.085,1},
  border={0.64,0.70,0.77,0.90},borderSoft={0.42,0.48,0.55,0.86},text={1,1,1,1},textMuted={0.83,0.86,0.90,1},accent={1,0.84,0.39,1},accentLine={1,0.84,0.39,0.94}},
}
local function Band(base,up)
 return {{math.min(1,base[1]+up),math.min(1,base[2]+up),math.min(1,base[3]+up)},
  {base[1],base[2],base[3]},{base[1]*0.65,base[2]*0.65,base[3]*0.65}}
end
local function ApplyBands(drawable,bands)
 if not drawable or not bands or not drawable.ChangeColor1 or not drawable.ChangeColor2 or not drawable.ChangeColor3 then return end
 drawable:ChangeColor1(unpack(bands[1]));drawable:ChangeColor2(unpack(bands[2]));drawable:ChangeColor3(unpack(bands[3]))
end
function T:ApplyWorkspacePalette(name)
 name=tostring(name or 'dark');if name~='dark' and not palettes[name]then return false,'未知主题'end
 if self.workspacePalette==name then return true end
 Assign(C,defaults);if S.UITokens then Assign(S.UITokens.button,buttonDefaults)end
 local palette=palettes[name]
 if palette then
  Assign(C,palette)
  for _,kind in ipairs({'panel','card','header','titlebar','button','buttonHover','buttonPushed','buttonDisabled'})do
   local base=(kind=='header' or kind=='titlebar' or kind=='buttonHover') and C.cardHeader or kind=='card' and C.card or C.panelAlt
   C.Gradient[kind]=C.Gradient[kind] or {};Assign(C.Gradient[kind],Band(base,kind=='buttonHover' and 0.10 or 0.025))
  end
  if S.UITokens then
   Assign(S.UITokens.button,{normal=Copy(C.panelAlt),active=Copy(C.cardHeader),hover=Copy(C.cardHeader),activeHover=Copy(C.cardHeader),pushed=Copy(C.panel),disabled=Copy(C.card)})
  end
 end
 self.workspacePalette=name;local changed,failed=0,0
 local UI=S.UI
 for _,widget in pairs(UI and UI.controls or {})do
  if type(UI.IsWidgetUsable)=='function' and UI:IsWidgetUsable(widget)==true then
   local ok=pcall(function()
    local kind=widget.rsThemeBackgroundKind
    if widget.rsBackground and kind then
     local color=kind=='header' and C.cardHeader or kind=='card' and C.card or C.panel
     if widget.rsThemeGradient then
      ApplyBands(widget.rsBackground,C.Gradient[kind] or C.Gradient.panel);widget.rsBackgroundColor={1,1,1,color[4]}
     else widget.rsBackgroundColor=Copy(color)end
    end
    if widget.rsBorder then widget.rsBorderColor=Copy(widget.rsThemeSoftBorder and C.borderSoft or C.border)end
    if widget.rsAccentStrip and widget.rsThemeDefaultAccent then widget.rsAccentStripColor=Copy(C.accentLine)end
    if widget.rsButtonBgs then
     -- 强制重新应用交互状态，但不改启停语义；四个背景复用，不重复 StyleButton 分配。
     local tone=widget.rsButtonStatusTone;widget.rsButtonStatusTone='workspace_repaint'
     self:SetButtonStatusTone(widget,tone)
     if widget.rsGradientBands then ApplyBands(widget.rsButtonBgs[4],C.Gradient.buttonDisabled)
     elseif widget.rsButtonBgColors then widget.rsButtonBgColors[4]=Copy(S.UITokens.button.disabled)end
    end
    if widget.rsLabelTone and widget.style then
     local tone=widget.rsLabelTone;widget.rsLabelTone=nil;self:SetLabelTone(widget,tone)
    end
    self:SetBackgroundOpacity(widget,widget.rsBackgroundOpacity or 1)
   end)
   if ok then changed=changed+1 else failed=failed+1 end
  end
 end
 self.workspacePaletteUpdated=changed;self.workspacePaletteFailures=failed
 if failed>0 and S.DiagnosticsManager then S.DiagnosticsManager:Warn('ui_v3','WORKSPACE_PALETTE_PARTIAL','部分已创建控件未接受主题更新',{failed=failed,palette=name})end
 return true,changed
end
