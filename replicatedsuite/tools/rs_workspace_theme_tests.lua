-- 真实 Theme 及 Color/Tokens；绘制替身断言不创建新背景，不用 SetColor 擦掉渐变。
local p,f=0,0
local function T(n,fn)local ok,e=xpcall(fn,debug.traceback);if ok then p=p+1;print('PASS '..n)else f=f+1;print('FAIL '..n..' '..e)end end
local function Boot()
 -- Theme 不消费债券 ID；补齐 Constants 当前要求的只读目录形状，避免启动保护提前退出。
 ReplicatedSuite={GameIds={Item={BLUE_SALT_BOND=1,BOND_MATERIAL={},AURORIA_BOND_MATERIAL={}},Quest={ResidentBond={MaterialByQuantity={},AuroriaByTokenQuantity={}}}},UI={controls={}},Generation=1}
 local S=ReplicatedSuite;function S.UI:IsWidgetUsable(w)return not w.stale end
 dofile('core/rs_constants.lua');dofile('ui/framework/rs_ui_tokens.lua');dofile('core/rs_theme.lua')
 assert(io.open('core/rs_workspace_theme.lua','r'),'missing theme palette');dofile('core/rs_workspace_theme.lua')
 local h={drawables=0}
 function h:Widget(id,gradient)
  local w={style={SetColor=function(self,...)self.rgba={...}end,SetShadow=function(self,v)self.shadow=v end}}
  function w:CreateColorDrawable(r,g,b,a)h.drawables=h.drawables+1;return {rgba={r,g,b,a},AddAnchor=function()end,SetColor=function(d,...)d.rgba={...}end}end
  if gradient then function w:CreateThreeColorDrawable()
   h.drawables=h.drawables+1
   return {bands={},ChangeColor1=function(d,...)d.bands[1]={...}end,ChangeColor2=function(d,...)d.bands[2]={...}end,ChangeColor3=function(d,...)d.bands[3]={...}end,
    SetAlpha=function(d,a)d.alpha=a end,SetColor=function()error('gradient SetColor forbidden')end,AddAnchor=function()end}
  end end
  S.UI.controls[id]=w;return w
 end
 return S,h
end
T('palette updates owned gradients preserves opacity and token references',function()
 local S,h=Boot();local w=h:Widget('panel',true);S.Theme:AddGradientBackground(w,'card');S.Theme:AddBorder(w,true);S.Theme:SetBackgroundOpacity(w,0.35)
 local token=S.UITokens.tone.muted;local original=S.Constants.Color.card[1];local count=h.drawables
 assert(S.Theme:ApplyWorkspacePalette('gold'));assert(S.Constants.Color.card[1]~=original);assert(S.UITokens.tone.muted==token)
 assert(h.drawables==count and w.rsBackgroundOpacity==0.35);assert(math.abs(w.rsBackground.alpha-S.Constants.Color.card[4]*0.35)<0.00001)
 assert(S.Theme:ApplyWorkspacePalette('dark'));assert(S.Constants.Color.card[1]==original)
end)
T('status buttons remain semantic and stale wrappers not touched',function()
 local S,h=Boot();local w=h:Widget('button',true);S.Theme:StyleButton(w,100,30,12,false,true);S.Theme:SetButtonStatusTone(w,'green')
 local before=w.rsButtonBgs[1].bands[1][2];assert(S.Theme:ApplyWorkspacePalette('contrast'));assert(w.rsButtonStatusTone=='green' and w.rsButtonBgs[1].bands[1][2]==before)
 w.stale=true;w.rsButtonBgs[1].ChangeColor1=function()error('stale native use')end;assert(S.Theme:ApplyWorkspacePalette('gold'));assert(h.drawables==4)
end)
local function Equal(a,b)
 if type(a)~=type(b)then return false end;if type(a)~='table'then return a==b end
 for k,v in pairs(a)do if not Equal(v,b[k])then return false end end
 for k in pairs(b)do if a[k]==nil then return false end end;return true
end
T('old and newly created buttons share palette foreground after switching',function()
 local S,h=Boot();local old=h:Widget('old');S.Theme:StyleButton(old,80,24,11,false,false)
 assert(S.Theme:ApplyWorkspacePalette('gold'));local fresh=h:Widget('fresh');S.Theme:StyleButton(fresh,80,24,11,false,false)
 assert(Equal(old.style.rgba,fresh.style.rgba),'old button text stayed on previous palette')
end)
T('neutral light palette restores every color and token in place',function()
 local S,h=Boot();local C=S.Constants.Color;local dark=h:Widget('snapshot');local old={}
 for k,v in pairs(C)do if type(v)=='table'then old[k]={};for i,x in ipairs(v)do old[k][i]=type(x)=='table' and {unpack(x)} or x end end end
 local text,scroll=S.UITokens.tone.default,S.UITokens.scrollbar.thumb
 local originalText={unpack(C.text)};local originalThumb={unpack(scroll)}
 assert(S.Theme:ApplyWorkspacePalette('light'),'light palette unavailable')
 assert(C.panel[1]>.85 and C.panel[3]>=C.panel[1] and C.text[1]<.25)
 assert(S.UITokens.tone.default==text and S.UITokens.scrollbar.thumb==scroll)
 assert(C.Gradient.panel[1][1]-C.Gradient.panel[3][1]<.06,'dark gradient reused on light panel')
 assert(S.UITokens.scrollbar.track[1]>scroll[1] and S.UITokens.scrollbar.track[1]-scroll[1]<.1)
 assert(S.Theme:ApplyWorkspacePalette('dark'));assert(Equal(originalText,text) and Equal(originalThumb,scroll))
 assert(Equal(old.red,C.red) and Equal(old.divider,C.divider) and Equal(old.rowSelected,C.rowSelected))
end)
T('light semantic buttons preserve active hover and opacity without allocations',function()
 local S,h=Boot();local w=h:Widget('green',true);S.Theme:StyleButton(w,80,24,11,true,true);S.Theme:SetButtonStatusTone(w,'green');S.Theme:SetButtonHovered(w,true);S.Theme:SetBackgroundOpacity(w,.4)
 local before=w.rsButtonBgs[1].bands[2][2];local count=h.drawables
 assert(S.Theme:ApplyWorkspacePalette('light'));assert(w.rsButtonStatusTone=='green' and w.rsButtonActive and w.rsButtonHovered)
 assert(w.rsButtonBgs[1].bands[2][2]>.7 and w.style.rgba[1]<.3 and h.drawables==count and w.rsBackgroundOpacity==.4)
 assert(S.Theme:ApplyWorkspacePalette('dark'));assert(w.rsButtonBgs[1].bands[2][2]==before)
end)
T('theme owned decorations repaint but custom and world colors remain intact',function()
 local S,h=Boot();local w=h:Widget('decorated');local line=S.Theme:AddDivider(w,0,true)
 local custom=w:CreateColorDrawable(.9,.2,.1,.7)
 local world=h:Widget('world');S.Theme:StyleLabel(world,12,'default','LEFT',true);S.Theme:SetWorldTextPalette(world)
 local worldColor={unpack(world.style.rgba)}
 local label=h:Widget('label');S.Theme:StyleLabel(label,13,'default','LEFT',true)
 assert(S.Theme:ApplyWorkspacePalette('light'))
 assert(Equal(line.rgba,S.Constants.Color.dividerSoft) and Equal(custom.rgba,{.9,.2,.1,.7}))
 assert(Equal(world.style.rgba,worldColor) and world.style.shadow==true and label.style.shadow==false)
 assert(S.Theme:ApplyWorkspacePalette('dark') and label.style.shadow==true)
end)
T('failed repaint is reported and same palette can retry',function()
 local S,h=Boot();local w=h:Widget('retry');S.Theme:StyleLabel(w,12,'default');local setter=w.style.SetColor
 w.style.SetColor=function()error('native paint rejected')end
 local ok=S.Theme:ApplyWorkspacePalette('light');assert(ok==false and S.Theme.workspacePaletteFailures==1)
 w.style.SetColor=setter;assert(S.Theme:ApplyWorkspacePalette('light'));assert(Equal(w.style.rgba,S.Constants.Color.text))
end)
T('default untyped solid panels switch their background together with text',function()
 local S,h=Boot();local w=h:Widget('default_panel');S.Theme:AddPanelBackground(w)
 assert(S.Theme:ApplyWorkspacePalette('light'));assert(Equal(w.rsBackground.rgba,S.Constants.Color.panel),'untyped solid panel kept dark background')
end)
T('light body and semantic button text have readable contrast across all gradient bands',function()
 local S,h=Boot();assert(S.Theme:ApplyWorkspacePalette('light'))
 local function Lum(c)local l=0;for i,w in ipairs({.2126,.7152,.0722})do local v=c[i];l=l+w*(v<=.04045 and v/12.92 or ((v+.055)/1.055)^2.4)end;return l end
 local function Check(a,b)local x,y=Lum(a),Lum(b);local ratio=(math.max(x,y)+.05)/(math.min(x,y)+.05)
  assert(ratio>=4.5,string.format('low light text contrast %.3f foreground %.3f %.3f %.3f background %.3f %.3f %.3f',ratio,a[1],a[2],a[3],b[1],b[2],b[3]))end
 for _,role in ipairs({'text','textMuted','accent','green','yellow','orange','red','purple'})do
  for _,kind in ipairs({'panel','card','header','titlebar'})do for _,bg in ipairs(S.Constants.Color.Gradient[kind])do Check(S.Constants.Color[role],bg)end end
 end
 for _,tone in ipairs({'red','green'})do
  local b=h:Widget('contrast_'..tone,true);S.Theme:StyleButton(b,80,24,11,false,true);S.Theme:SetButtonStatusTone(b,tone)
  for _,hover in ipairs({false,true})do S.Theme:SetButtonHovered(b,hover);for i=1,3 do for _,bg in ipairs(b.rsButtonBgs[i].bands)do Check(b.style.rgba,bg)end end end
 end
end)
T('new palettes switch all color roles in place and restore legacy dark exactly',function()
 local S,h=Boot()
 local function Clone(v)if type(v)~='table'then return v end;local r={};for k,x in pairs(v)do r[k]=Clone(x)end;return r end
 local initial=Clone(S.Constants.Color);local initialTokens={}
 for _,key in ipairs({'button','scrollbar','input','slider','resize','decorations'})do initialTokens[key]=Clone(S.UITokens[key])end
 local w=h:Widget('palette_panel',true);S.Theme:AddGradientBackground(w,'card');S.Theme:SetBackgroundOpacity(w,.4)
 local b=h:Widget('palette_button',true);S.Theme:StyleButton(b,80,24,11,true,true);S.Theme:SetButtonHovered(b,true)
 local world=h:Widget('palette_world');S.Theme:StyleLabel(world,12,'default','LEFT',true);S.Theme:SetWorldTextPalette(world)
 local originalWorld={unpack(world.style.rgba)};local originalThumb={unpack(S.UITokens.scrollbar.thumb)}
 local textRef,thumbRef=S.UITokens.tone.default,S.UITokens.scrollbar.thumb;local count=h.drawables
 local seen={}
 for _,name in ipairs({'nord','dusk','dawn','sage'})do
  assert(S.Theme:ApplyWorkspacePalette(name),'new palette missing: '..name)
  assert(S.Theme:IsLightWorkspacePalette()==(name=='dawn' or name=='sage'),'incorrect light/dark treatment')
  local C=S.Constants.Color
  assert(S.UITokens.tone.default==textRef and S.UITokens.scrollbar.thumb==thumbRef and h.drawables==count)
  assert(Equal(world.style.rgba,originalWorld) and world.style.shadow and b.rsButtonActive and b.rsButtonHovered and w.rsBackgroundOpacity==.4)
  assert(S.UITokens.scrollbar.track[4]==1 and S.UITokens.scrollbar.thumb[4]==1)
  for i=1,3 do assert(math.abs(S.UITokens.scrollbar.track[i]-S.UITokens.scrollbar.thumb[i])<.10,'prominent scrollbar in '..name)end
  assert(C.Gradient.panel[1][1]-C.Gradient.panel[3][1]<.04,'heavy panel gradient in '..name)
  local key=table.concat(C.panel,':');assert(not seen[key],'duplicate palette appearance');seen[key]=true
 end
 assert(S.Theme:ApplyWorkspacePalette('dark'));assert(Equal(originalThumb,S.UITokens.scrollbar.thumb) and Equal(initial,S.Constants.Color))
 for key,v in pairs(initialTokens)do assert(Equal(v,S.UITokens[key]),'legacy token drift: '..key)end
end)
T('new palettes keep body inputs and semantic buttons readable on every native band',function()
 local S,h=Boot()
 local function Lum(c)local l=0;for i,w in ipairs({.2126,.7152,.0722})do local v=c[i];l=l+w*(v<=.04045 and v/12.92 or ((v+.055)/1.055)^2.4)end;return l end
 local function Check(a,b,label)local x,y=Lum(a),Lum(b);local ratio=(math.max(x,y)+.05)/(math.min(x,y)+.05);assert(ratio>=4.5,label..' contrast '..ratio)end
 for _,name in ipairs({'nord','dusk','dawn','sage'})do
  assert(S.Theme:ApplyWorkspacePalette(name))
  for _,role in ipairs({'text','textMuted','accent','blue','green','yellow','orange','red','purple'})do
   for _,kind in ipairs({'panel','card','header','titlebar'})do for _,bg in ipairs(S.Constants.Color.Gradient[kind])do Check(S.Constants.Color[role],bg,name..'/'..role..'/'..kind)end end
  end
  Check(S.UITokens.input.text,S.UITokens.input.background,name..'/input')
  Check(S.UITokens.input.placeholder,S.UITokens.input.background,name..'/placeholder')
  for _,tone in ipairs({'plain','red','green'})do
   local b=h:Widget(name..'_contrast_'..tone,true);S.Theme:StyleButton(b,80,24,11,false,true);S.Theme:SetButtonStatusTone(b,tone)
   for _,hover in ipairs({false,true})do S.Theme:SetButtonHovered(b,hover);for i=1,3 do for _,bg in ipairs(b.rsButtonBgs[i].bands)do Check(b.style.rgba,bg,name..'/button/'..tone)end end end
  end
 end
end)
print('THEME RESULT '..p..' passed / '..f..' failed');if f>0 then error('theme failures')end
