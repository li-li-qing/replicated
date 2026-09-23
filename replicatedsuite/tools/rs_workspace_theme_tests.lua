-- 真实 Theme 及 Color/Tokens；绘制替身断言不创建新背景，不用 SetColor 擦掉渐变。
local p,f=0,0
local function T(n,fn)local ok,e=xpcall(fn,debug.traceback);if ok then p=p+1;print('PASS '..n)else f=f+1;print('FAIL '..n..' '..e)end end
local function Boot()
 ReplicatedSuite={GameIds={Item={BLUE_SALT_BOND=1,BOND_MATERIAL={}},Quest={ResidentBond={MaterialByQuantity={},AuroriaByTokenQuantity={}}}},UI={controls={}},Generation=1}
 local S=ReplicatedSuite;function S.UI:IsWidgetUsable(w)return not w.stale end
 dofile('core/rs_constants.lua');dofile('ui/framework/rs_ui_tokens.lua');dofile('core/rs_theme.lua')
 assert(io.open('core/rs_workspace_theme.lua','r'),'missing theme palette');dofile('core/rs_workspace_theme.lua')
 local h={drawables=0}
 function h:Widget(id,gradient)
  local w={style={SetColor=function(self,...)self.rgba={...}end}}
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
print('THEME RESULT '..p..' passed / '..f..' failed');if f>0 then error('theme failures')end
