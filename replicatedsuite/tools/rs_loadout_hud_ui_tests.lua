-- 中文维护：真实头顶投影/Renderer + 原生绘制替身；不把控件坐标模拟当客户端验收。
local passed,failed=0,0
local function Test(name,fn)local ok,e=pcall(fn);if ok then passed=passed+1;print('PASS loadout-ui '..name)else failed=failed+1;print('FAIL loadout-ui '..name..': '..tostring(e))end end
local function Head()
    local h=dofile('tools/rs_gear_page_test_host.lua')({width=1280,height=768});h.page:OnDeactivated();local S=h.S
    UIParent=h.Native(nil,'UIParent',0,0,1280,768)
    local function New(parent,id,x,y,w,ht,pick,owner)
        local n=h.Native(parent,id,x,y,w,ht)
        function n:CreateIconDrawable()return h.Native(self,self.id..'_icon',0,0,1,1)end
        return n
    end
    S.UI.CreateEmptyWidget=function(_,...)return New(...)end
    S.UI.SetAlpha=function(_,n,v)n.alpha=v;return true end
    S.UI.SetIconTexture=function(_,icon,path)icon.texture=path;h.textureWrites=(h.textureWrites or 0)+1;return true end
    S.Api.GetUiMetrics=function()return 1280,768,1,1280,768 end
    S.Features.BuffDisplay={enabled=true};dofile('features/combat/buff_display/rs_buff_display_projection.lua')
    local F=S.Features.BuffDisplay
    local cfg={headEnabled=true,headPlayer=true,headTarget=true,headShowAll=true,components={},info={enabled=true,showClass=true,showGear=true,showDistance=true}}
    local lanes={player={class={name='Class P',icon='role-p.dds'},mainHand={name='real weapon',icon='actual-item.dds'}},
        target={class={name='Class T',icon='role-t.dds'},targetLoadout={weapon={name='双持',icon='dual-buff.dds',source='observed_buff',buffId=4899},armor={name='皮甲',icon='leather-buff.dds',source='observed_buff',buffId=716}}}}
    F.GetHeadPolicyProjection=function()return cfg end;F.GetScopeSettingsProjection=function()return cfg end
    F.GetPlatesProjection=function(_,scope)return F.ProjectPlates(lanes[scope],cfg)end
    F.GetPlatesAnchor=function(_,scope)return scope=='player' and 350 or 850,350,1 end
    F.AcquireConsumer=function()return true end;F.ReleaseConsumer=function()return true end
    dofile('presentation/v3/widgets/rs_v3_buff_head_markers.lua')
    return h,S.UIV3.BuffHeadMarkersV3,lanes,cfg
end
Test('profession icon is drawn before localized class text on both units',function()
    local h,P=Head();assert(P.running)
    for _,scope in ipairs({'player','target'})do
        local info=P.pools[scope].info
        assert(info.iconRoot and info.iconRoot.shown and info.icon.texture,'profession icon absent')
        assert(info.iconRoot.x+info.iconRoot.width<=info.root.x,'icon is not before class')
    end
end)
Test('target buff type textures and self actual item stay distinct',function()
    local h,P=Head();local found={}
    for _,m in ipairs(P.pools.target.icons)do if m.root.shown then found[m.icon.texture]=true end end
    assert(found['dual-buff.dds'] and found['leather-buff.dds'] and not found['actual-item.dds'])
    local actual=false;for _,m in ipairs(P.pools.player.icons)do if m.root.shown and m.icon.texture=='actual-item.dds'then actual=true end end
    assert(actual)
end)
Test('unknown class and hidden info clear previous profession icon',function()
    local h,P,lanes,cfg=Head();lanes.target.class.icon=nil;P:VisualTick();assert(not P.pools.target.info.iconRoot.shown)
    cfg.info.enabled=false;P:VisualTick();assert(not P.pools.player.info.iconRoot.shown)
end)
Test('head renderer reuses icon pools and unchanged textures across frames',function()
    local h,P=Head();local allocated=P.metrics.allocated;local writes=h.textureWrites
    for _=1,20 do P:VisualTick()end
    assert(P.metrics.allocated==allocated and h.textureWrites==writes)
end)
Test('missing texture does not fabricate an equipment item icon',function()
    local h,P,lanes=Head();lanes.target.targetLoadout.weapon.icon='';P:VisualTick()
    for _,m in ipairs(P.pools.target.icons)do
        assert(not(m.root.shown and m.icon.texture=='ui/icon/icon_unknown_item.dds'),'placeholder disguises missing metadata as item')
    end
end)
Test('stop hides profession icons as well as all item markers',function()
    local h,P=Head();assert(P:Stop())
    for _,scope in ipairs({'player','target'})do
        assert(not P.pools[scope].info.iconRoot.shown)
        for _,m in ipairs(P.pools[scope].icons)do assert(not m.root.shown)end
    end
end)
print(string.format('LOADOUT_UI_RESULT passed=%d failed=%d',passed,failed));assert(failed==0,'loadout UI failed')
