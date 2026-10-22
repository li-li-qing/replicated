------------------------------------------------------------------------
-- Replicated Suite · 工作区主题配置
-- 作者：Replicated
-- QQ群：1104129461
--
-- 工作台配色预设（2026-09-18）。Theme owns 色彩；Workspace 仅保存预设名。
-- 不修改 AppState 老存档/Canonical，不覆盖用户字号/透明度/几何。色表原位更新，
-- 保持 UITokens 引用。只在初始化/显式切换遍历当前 UI.controls，先查代内可用性，
-- 不追 Native 父子节点、不创建/销毁 Drawable，渐变仅用现有 ChangeColor1/2/3。
------------------------------------------------------------------------
if ReplicatedSuite==nil or ReplicatedSuite.BootError~=nil then return end
local S=ReplicatedSuite;local T=S.Theme;local C=S.Constants and S.Constants.Color
if not T or not C then return end
local function Copy(v)if type(v)~='table'then return v end;local r={};for k,x in pairs(v)do r[k]=Copy(x)end;return r end
local defaults=Copy(C);local tokenDefaults={}
for _,key in ipairs({'button','scrollbar','input','slider','resize','decorations'})do tokenDefaults[key]=Copy(S.UITokens and S.UITokens[key] or {})end
local function Assign(target,values)
 for k,v in pairs(values)do if type(v)=='table'then target[k]=type(target[k])=='table' and target[k] or {};Assign(target[k],v)else target[k]=v end end
end
local function Hex(value,alpha)
 return {tonumber(value:sub(1,2),16)/255,tonumber(value:sub(3,4),16)/255,tonumber(value:sub(5,6),16)/255,alpha or 1}
end
local palettes={
 -- Addon1.2.zip 的共享 Color 原值；包含背景 alpha 和三段渐变，不按新主题算法近似生成。
 legacy={
  panel={.025,.035,.050,.94},panelAlt={.040,.052,.068,.94},card={.035,.046,.060,.92},cardHeader={.060,.072,.088,.96},
  border={.34,.29,.20,.90},borderSoft={.20,.24,.28,.82},text={.94,.91,.84,1},textMuted={.66,.68,.70,1},
  accent={.84,.67,.33,1},blue={.30,.75,1,1},green={.52,.88,.30,1},yellow={1,.78,.18,1},
  orange={1,.42,.12,1},red={.95,.22,.16,1},purple={.77,.45,.98,1},
  accentSoft={.84,.67,.33,.30},accentLine={.90,.75,.40,.85},divider={.30,.36,.44,.55},dividerSoft={.20,.24,.30,.40},
  headerText={.98,.94,.85,1},rowHover={.16,.21,.27,.55},rowSelected={.22,.26,.18,.60},
  Gradient={
   panel={{.055,.085,.125},{.032,.048,.072},{.016,.024,.040}},
   card={{.060,.085,.115},{.038,.054,.075},{.022,.032,.048}},
   header={{.115,.150,.195},{.075,.098,.130},{.050,.066,.092}},
   titlebar={{.135,.170,.215},{.090,.115,.150},{.060,.078,.105}},
   button={{.120,.155,.200},{.080,.105,.140},{.048,.066,.092}},
   buttonHover={{.175,.215,.265},{.115,.148,.190},{.070,.095,.128}},
   buttonPushed={{.060,.085,.118},{.090,.118,.155},{.135,.170,.215}},
   buttonDisabled={{.060,.066,.075},{.048,.052,.060},{.036,.040,.048}},
  },
 },
 gold={panel={0.030,0.026,0.022,0.98},panelAlt={0.047,0.040,0.030,0.98},card={0.043,0.036,0.027,0.97},cardHeader={0.075,0.058,0.035,0.98},
  border={0.67,0.49,0.23,0.65},borderSoft={0.34,0.27,0.16,0.65},text={0.96,0.92,0.83,1},textMuted={0.72,0.68,0.59,1},accent={0.97,0.76,0.38,1},accentLine={0.97,0.75,0.36,0.75}},
 contrast={panel={0.009,0.012,0.017,1},panelAlt={0.030,0.036,0.044,1},card={0.020,0.026,0.034,1},cardHeader={0.060,0.073,0.085,1},
  border={0.64,0.70,0.77,0.90},borderSoft={0.42,0.48,0.55,0.86},text={1,1,1,1},textMuted={0.83,0.86,0.90,1},accent={1,0.84,0.39,1},accentLine={1,0.84,0.39,0.94}},
 -- （2026-10-05）中性灰白 + 低饱和蓝灰。状态文字采用深色，浅底不沿用荧光黄/绿。
 light={panel=Hex('EEF0F2',.98),panelAlt=Hex('E9EDF0',.98),card=Hex('F7F8F9',.97),cardHeader=Hex('E1E6EA',.98),
  border=Hex('B5C1CB',.85),borderSoft=Hex('C6CFD6',.78),text=Hex('28333D'),textMuted=Hex('56636F'),
  accent=Hex('41657E'),blue=Hex('41657E'),green=Hex('356846'),yellow=Hex('7A6024'),orange=Hex('87502B'),red=Hex('9A403C'),purple=Hex('705280'),
  accentSoft=Hex('41657E',.16),accentLine=Hex('809BAB',.65),divider=Hex('ADBEC9',.65),dividerSoft=Hex('BCC9D2',.45),
  headerText=Hex('28333D'),rowHover=Hex('E6EDF2',.9),rowSelected=Hex('DCE6ED',.92)},
}
local lightTokens={
 button={normal=Hex('E7ECF0',.97),active=Hex('D5E1EA',.99),hover=Hex('DBE5ED',.99),activeHover=Hex('CFDDE7',.99),pushed=Hex('C8D7E2',.99),disabled=Hex('E3E7EA',.70)},
 scrollbar={track=Hex('E0E5E9'),thumb=Hex('CBD2D8')},
 input={background=Hex('F9FAFB',.995),text=Hex('28333D'),placeholder=Hex('56636F'),border=Hex('B5C1CB',.98),focus=Hex('62869F'),caret=Hex('41657E')},
 slider={track=Hex('BFCBD4',.95),disabled=Hex('CFD6DC',.55),thumbBorder=Hex('718FA4'),thumb=Hex('DFE7ED',.98)},
 resize={accent=Hex('62869F')},
 decorations={separator=Hex('ADBEC9',.58),split=Hex('ADBEC9',.72),hover=Hex('41657E')},
}
local function Band(base,up)
 return {{math.min(1,base[1]+up),math.min(1,base[2]+up),math.min(1,base[3]+up)},
  {base[1],base[2],base[3]},{base[1]*0.65,base[2]*0.65,base[3]*0.65}}
end
local function ApplyBands(drawable,bands)
 if not drawable or not bands or not drawable.ChangeColor1 or not drawable.ChangeColor2 or not drawable.ChangeColor3 then return end
 drawable:ChangeColor1(unpack(bands[1]));drawable:ChangeColor2(unpack(bands[2]));drawable:ChangeColor3(unpack(bands[3]))
end
local function LightBand(base)
 local function Shift(delta)local v={};for i=1,3 do v[i]=math.max(0,math.min(1,base[i]+delta))end;return v end
 return {Shift(.008),Shift(0),Shift(-.012)}
end
-- （2026-10-05）参考 Nord / Catppuccin / Rosé Pine 的表面层次，按游戏小字号加深浅色文字、调亮深色状态字。
-- 仅扩充既有 Theme 的常量色表；旧四种主题原样保留。所有新主题为轻渐变，交互/滚动/输入仍由原组件所有。
local paletteModes={light='light',nord='dark',dusk='dark',dawn='light',sage='light'}
local legacyTokens=Copy(tokenDefaults)
-- 纯色按钮取自旧版 Theme:StyleButton；输入框及滑杆原色与现有深色 token 一致。
legacyTokens.button={normal={.075,.095,.120,.97},active={.17,.14,.09,.98},hover={.14,.19,.24,.99},
 activeHover={.26,.21,.12,.99},pushed={.045,.060,.078,.99},disabled={.050,.052,.058,.70}}
legacyTokens.input.placeholder=Copy(palettes.legacy.textMuted)
-- 新框架的滚动条和布局装饰在旧包没有同一组件；采用旧色表的表面、按钮中段及分隔线角色。
legacyTokens.scrollbar={track={.025,.035,.050,1},thumb={.080,.105,.140,1}}
legacyTokens.decorations={separator=Copy(palettes.legacy.dividerSoft),split=Copy(palettes.legacy.divider),hover=Copy(palettes.legacy.blue)}
local tokenPalettes={light=lightTokens,legacy=legacyTokens};local statusPalettes={}
local function Mix(a,b,amount,alpha)
 return {a[1]+(b[1]-a[1])*amount,a[2]+(b[2]-a[2])*amount,a[3]+(b[3]-a[3])*amount,alpha or 1}
end
local function AddPreset(id,d)
 local light=paletteModes[id]=='light'
 local p={panel=Hex(d.panel,.98),panelAlt=Hex(d.panelAlt,.98),card=Hex(d.card,.97),cardHeader=Hex(d.header,.98),
  text=Hex(d.text),textMuted=Hex(d.muted),border=Hex(d.border,light and .85 or .72),borderSoft=Hex(d.borderSoft,.65),
  accent=Hex(d.accent),accentSoft=Hex(d.accent,.16),accentLine=Hex(d.accent,light and .48 or .60),
  divider=Hex(d.border,.65),dividerSoft=Hex(d.borderSoft,.45),headerText=Hex(d.text)}
 for _,role in ipairs({'blue','green','yellow','orange','red','purple'})do p[role]=Hex(d[role])end
 p.rowHover=Mix(p.panelAlt,p.accent,.09,.9);p.rowSelected=Mix(p.panelAlt,p.accent,.15,.92)
 local normal=Mix(p.panelAlt,p.panelAlt,0,.97)
 local track=Mix(p.panel,p.cardHeader,.4)
 tokenPalettes[id]={
  button={normal=normal,active=Mix(normal,p.accent,.16,.99),hover=Mix(normal,p.accent,.10,.99),
   activeHover=Mix(normal,p.accent,.20,.99),pushed=Mix(normal,p.accent,.22,.99),disabled=Mix(p.panelAlt,p.panel,.35,.70)},
  scrollbar={track=track,thumb=Mix(track,p.text,.10)},
  input={background=Mix(light and p.card or p.panel,p.panel,0,.995),text=Copy(p.text),placeholder=Copy(p.textMuted),
   border=Hex(d.border,.98),focus=Copy(p.accent),caret=Copy(p.accent)},
  slider={track=Mix(p.cardHeader,p.text,.16,.95),disabled=Mix(p.panel,p.cardHeader,.5,.55),
   thumbBorder=Copy(p.accent),thumb=Mix(p.panelAlt,p.accent,.12,.98)},
  resize={accent=Copy(p.accent)},decorations={separator=Hex(d.border,.58),split=Hex(d.border,.72),hover=Copy(p.accent)},
 }
 local status={}
 for _,tone in ipairs({'green','red'})do
  status[tone]={normal=LightBand(Mix(p.panelAlt,p[tone],light and .04 or .05)),
   bright=LightBand(Mix(p.panelAlt,p[tone],light and .08 or .10))}
 end
 palettes[id],statusPalettes[id]=p,status
end
AddPreset('nord',{panel='2E3440',panelAlt='303746',card='353D4B',header='394251',text='ECEFF4',muted='BFC9D8',
 border='59687C',borderSoft='485363',accent='88C0D0',blue='93BADB',green='A3BE8C',yellow='EBCB8B',orange='EAB18F',red='E9A0AA',purple='C8ABD7'})
AddPreset('dusk',{panel='1E1E2E',panelAlt='262636',card='2A2A3C',header='303046',text='CDD6F4',muted='BAC2DE',
 border='585B75',borderSoft='45475F',accent='CBA6F7',blue='89B4FA',green='A6E3A1',yellow='F9E2AF',orange='FAB387',red='F38BA8',purple='CBA6F7'})
AddPreset('dawn',{panel='FAF4ED',panelAlt='F5EFE6',card='FFFAF3',header='EEE7DD',text='514C64',muted='615A70',
 border='BFB3B7',borderSoft='D3C8C5',accent='715A81',blue='386478',green='47684C',yellow='7C5F25',orange='8D542E',red='9C4652',purple='715A81'})
AddPreset('sage',{panel='EDF2EE',panelAlt='E7EEE9',card='F6F8F4',header='DCE7E0',text='2E3C35',muted='4F6156',
 border='A9BDB0',borderSoft='BECEC3',accent='3D6B58',blue='426779',green='3B6447',yellow='705F2B',orange='83532D',red='934D49',purple='6B577D'})
function T:ApplyWorkspacePalette(name)
 name=tostring(name or 'dark');if name~='dark' and not palettes[name]then return false,'未知主题'end
 if self.workspacePalette==name and (self.workspacePaletteFailures or 0)==0 then return true end
 Assign(C,defaults);if S.UITokens then for key,value in pairs(tokenDefaults)do Assign(S.UITokens[key],value)end end
 local palette=palettes[name]
 local themeTokens=tokenPalettes[name]
 if palette then
  Assign(C,palette)
  if not palette.Gradient then
  for _,kind in ipairs({'panel','card','header','titlebar','button','buttonHover','buttonPushed','buttonDisabled'})do
   local base=(kind=='header' or kind=='titlebar' or kind=='buttonHover') and C.cardHeader or kind=='card' and C.card or C.panelAlt
   if themeTokens then
    local buttonKind=({button='normal',buttonHover='hover',buttonPushed='pushed',buttonDisabled='disabled'})[kind]
    if buttonKind then base=themeTokens.button[buttonKind]end
   end
   C.Gradient[kind]=C.Gradient[kind] or {};Assign(C.Gradient[kind],themeTokens and LightBand(base) or Band(base,kind=='buttonHover' and 0.10 or 0.025))
  end
  end
  if S.UITokens then
   if themeTokens then for key,value in pairs(themeTokens)do Assign(S.UITokens[key],value)end
   else Assign(S.UITokens.button,{normal=Copy(C.panelAlt),active=Copy(C.cardHeader),hover=Copy(C.cardHeader),activeHover=Copy(C.cardHeader),pushed=Copy(C.panel),disabled=Copy(C.card)})end
  end
 end
 self.workspacePalette=name;self.workspacePaletteMode=paletteModes[name] or 'dark';self.workspaceStatusBands=statusPalettes[name]
 local changed,failed,skipped=0,0,0;local failures={}
 local UI=S.UI
 for logicalId,widget in pairs(UI and UI.controls or {})do
  if type(UI.IsWidgetUsable)=='function' and UI:IsWidgetUsable(widget)==true then
   local ok,paintError=pcall(function()
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
    if (widget.rsLabelTone or widget.rsThemeTextRole) and widget.style then self:RefreshTextColor(widget)end
    self:RefreshColorDrawables(widget)
    self:SetBackgroundOpacity(widget,widget.rsBackgroundOpacity or 1)
   end)
   if ok then changed=changed+1 else
    failed=failed+1;if #failures<32 then failures[#failures+1]={id=tostring(logicalId),error=tostring(paintError)}end
   end
  else skipped=skipped+1
  end
 end
 self.workspacePaletteUpdated=changed;self.workspacePaletteFailures=failed
 self.workspacePaletteSkipped=skipped;self.workspacePaletteFailureDetails=failures
 if failed>0 and S.DiagnosticsManager then S.DiagnosticsManager:Warn('ui_v3','WORKSPACE_PALETTE_PARTIAL','部分已创建控件未接受主题更新',{failed=failed,palette=name})end
 if failed>0 then return false,'部分控件配色更新失败：'..failed end
 return true,changed
end
function T:GetPaletteDiagnostics()
 return {contractVersion=self.PaletteContractVersion,palette=self.workspacePalette or 'dark',mode=self.workspacePaletteMode or 'dark',
  updated=self.workspacePaletteUpdated or 0,failures=self.workspacePaletteFailures or 0,skipped=self.workspacePaletteSkipped or 0,
  failureDetails=Copy(self.workspacePaletteFailureDetails or {}),patch='palette-collection-1'}
end
