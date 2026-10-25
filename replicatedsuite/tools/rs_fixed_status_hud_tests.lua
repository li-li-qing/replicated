-- Replicated Suite · 屏幕固定 HUD 回归（Native/磁盘为受控模型）
-- 作者：Replicated
-- QQ群：1104129461
local passed,failed=0,0
local function Test(name,fn)
    local ok,err=xpcall(fn,debug.traceback)
    if ok then passed=passed+1;print('PASS fixed-hud '..name)
    else failed=failed+1;print('FAIL fixed-hud '..name..': '..tostring(err))end
end
local FILE='features/combat/buff_display/rs_buff_display_placement.lua'
local function LoadPlacement()
    local f=io.open(FILE,'r');if f then f:close();dofile(FILE)end
    assert(type(ReplicatedSuite.Features.BuffDisplay.GetHudDisplayModeProjection)=='function','screen fixed display mode is missing')
end
local function Boot(disk,withAliases)
    local h,S,F=dofile('tools/rs_pvp_hud_test_host.lua')({disk=disk})
    dofile('features/combat/buff_display/rs_buff_display_transfer_v2.lua')
    if withAliases then dofile('features/combat/buff_display/rs_buff_display_alias_store.lua')end
    dofile('features/combat/buff_display/rs_buff_display_arrangement.lua')
    LoadPlacement();assert(F:EnsureStoreLoaded());return h,S,F
end
Test('old users keep head mode and first fixed layout inherits their current appearance',function()
    local h,S,F=Boot();local old=F:GetHudCalibrationSnapshot()
    old.target.components.distance.fontSize=21
    assert(F:PersistHudCalibrationSnapshot(old))
    assert(F:GetHudDisplayModeProjection('target').mode=='head')
    assert(F.Commands:SetHudDisplayMode('target','fixed'))
    local fixed=F:GetScopeLayoutSettings('target')
    assert(fixed.components.distance.fontSize==21 and fixed.placement.mode=='fixed')
    assert(F:GetHudDisplayModeProjection('player').mode=='head')
    fixed.components.distance.fontSize=13
    assert(F:PersistHudCalibrationSnapshot({target=fixed}))
    assert(F.Commands:SetHudDisplayMode('target','head'))
    assert(F:GetScopeLayoutSettings('target').components.distance.fontSize==21,'fixed edits overwrote the head layout')
    assert(F.Commands:SetHudDisplayMode('target','fixed'))
    assert(F:GetScopeLayoutSettings('target').components.distance.fontSize==13)
    local _,_,loaded=Boot(h.disk)
    assert(loaded:GetScopeLayoutSettings('target').components.distance.fontSize==13)
    assert(loaded:GetHudDisplayModeProjection('target').mode=='fixed')
end)
Test('fixed calibration is independent, rejects invalid modes and rolls back rejected writes',function()
    local h,S,F=Boot();assert(F.Commands:SetHudDisplayMode('player','fixed'))
    local before=F:GetHudCalibrationSnapshot();local draft=F:GetHudCalibrationSnapshot()
    draft.player.components.buffs.orientation='vertical';draft.player.components.class.nameLinked=true
    draft.player.placement.x=2700;draft.player.placement.y=7400
    assert(F:PersistHudCalibrationSnapshot(draft))
    assert(F:GetScopeLayoutSettings('player').components.buffs.orientation=='vertical')
    assert(F:GetScopeLayoutSettings('target').placement.mode=='head')
    assert(not F.Commands:SetHudDisplayMode('target','oops'))
    local mutate=S.Persistence.MutateStore
    S.Persistence.MutateStore=function(self,id,...)if id==F.HudPlacementStoreId then return false,'injected_placement_failure'end;return mutate(self,id,...)end
    assert(not F:PersistHudCalibrationSnapshot(before))
    assert(F:GetScopeLayoutSettings('player').placement.x==2700)
end)
Test('fixed target remains on screen without head projection and clears when identity is lost',function()
    local h,S,F,R=dofile('tools/rs_pvp_hud_test_host.lua')({runtimeHud=true})
    dofile('features/combat/buff_display/rs_buff_display_arrangement.lua');LoadPlacement()
    local call=S.Api.CallCapability;local present=true
    S.Api.CallCapability=function(self,key,object,method,unit,...)
        if key=='X2Unit:UnitName'then return true,present and 'Enemy' or nil end
        if key=='X2Unit:GetUnitId'then return true,unit=='target'and (present and 'enemy-1'or nil)or 'self-1'end
        return call(self,key,object,method,unit,...)
    end
    F:RefreshTargetAliasIdentity('test');assert(F.Commands:SetHudDisplayMode('target','fixed'))
    F.laneData.target.distance=25.1;h.points.target=nil
    R:VisualTick();F:PositionTick();assert(R.pools.target.root.shown,'fixed HUD still depends on native head position')
    local x,y=h:World(R.pools.target.root);local reads=h.projectionReads
    h.points.player={400,400,1};F:PositionTick();local nx,ny=h:World(R.pools.target.root)
    assert(nx==x and ny==y,'camera moved fixed HUD')
    assert(h.projectionReads==reads+1,'fixed target still reads native projection every frame')
    assert(R.pools.target.info.distanceRoot.text=='25.1m')
    present=false;h:Event('TARGET_CHANGED');F:PositionTick()
    assert(not R.pools.target.root.shown,'cleared target resurrected in fixed HUD')
end)
Test('calibration mode switching keeps both drafts, whole HUD movement, cancel and save',function()
    local h,S,F,R,C=dofile('tools/rs_hud_template_copy_test_host.lua')({featureFiles={
        'features/combat/buff_display/rs_buff_display_arrangement.lua',FILE}})
    local writes=h.writes;local old=C.draft.player.components.distance.fontSize
    assert(type(C.SetDisplayMode)=='function','calibration has no display mode selector')
    assert(C:SetLegacyDisplayMode('fixed'));assert(C:SetComponent('screen'));assert(C:Nudge(10,5))
    local moved=C.draft.player.placement.x;assert(moved>3500)
    assert(C:SetComponent('distance'));assert(C:Adjust('font',2));local font=C.draft.player.components.distance.fontSize
    assert(C:SetLegacyDisplayMode('head'));assert(C.draft.player.components.distance.fontSize==old)
    assert(C:SetLegacyDisplayMode('fixed'));assert(C.draft.player.placement.x==moved and C.draft.player.components.distance.fontSize==font)
    assert(h.writes==writes,'mode preview persisted a draft')
    assert(C:Exit(false));assert(h.writes==writes and F:GetHudDisplayModeProjection('player').mode=='head')
    assert(C:Open());assert(C:SetLegacyDisplayMode('fixed'));assert(C:SetComponent('screen'));assert(C:Nudge(10,5))
    assert(C:Exit(true));assert(F:GetHudDisplayModeProjection('player').mode=='fixed')
    assert(F:GetScopeLayoutSettings('player').placement.x>3500)
end)
Test('full share round trips modes fixed layouts and old head layout without changing tracking shares',function()
    local _,S,F=Boot();local old=F:GetScopeLayoutSettings('target').components.distance.fontSize
    assert(F.Commands:SetHudDisplayMode('target','fixed'))
    local snapshot=F:GetHudCalibrationSnapshot();snapshot.target.components.distance.fontSize=22;snapshot.target.placement.x=8100
    assert(F:PersistHudCalibrationSnapshot(snapshot))
    local text=F:SerializeExport(F:ExportAll())
    assert(text:find('HUDPLACEMENT=target:fixed:8100:',1,true),'full share omitted fixed display mode')
    local parsed=F:ParseImportText(text);assert(#parsed.errors==0,table.concat(parsed.errors,','))
    local _,_,dest=Boot();assert(dest:ImportAll(parsed.data,'merge'))
    assert(dest:GetScopeLayoutSettings('target').components.distance.fontSize==22)
    assert(dest:GetHudDisplayModeProjection('target').x==8100)
    assert(dest.Commands:SetHudDisplayMode('target','head'))
    assert(dest:GetScopeLayoutSettings('target').components.distance.fontSize==old,'fixed share overwrote the separate head bank')
    assert(not F:SerializeExport(F:ExportAll('tracking')):find('HUDPLACEMENT',1,true))
    local invalid=F:ParseImportText(text..'\nHUDPLACEMENT=target:head:5000:5000')
    assert(#invalid.errors>0,'duplicate mode row accepted')
    assert(not F:ImportAll(invalid.data,'merge'))
end)
local function Calibration(options)
    options=options or {};options.featureFiles={'features/combat/buff_display/rs_buff_display_transfer_v2.lua','features/combat/buff_display/rs_buff_display_arrangement.lua',FILE}
    return dofile('tools/rs_hud_template_copy_test_host.lua')(options)
end
Test('whole position numeric inputs show full viewport coordinates and apply real edits',function()
    local h,S,F,R,C=Calibration();assert(C:SetLegacyDisplayMode('fixed'))
    assert(C.component=='screen'and C.draft.player.placement.mode=='fixed')
    local input=C.inputControls.x
    assert(tonumber(input:GetDraftValue())==448,'screen X still clipped by component offset limits')
    input.root:SetText('1000');assert(C:ApplyInputFields('x'))
    local actual=F.ComputeFixedHudAnchor(C.draft.player.placement,1280,768)
    assert(math.abs(actual-1000)<=1)
    assert(C:SetComponent('buffs'));assert(C:Adjust('x',10000));assert(C.draft.player.components.buffs.x==400)
    assert(C:Exit(false))
end)
Test('first fixed preview inherits in-session head edits without initializing unused fixed layouts',function()
    local h,S,F,R,C=Calibration();assert(C:SetComponent('distance'));assert(C:Adjust('font',3))
    local font=C.draft.player.components.distance.fontSize
    assert(C:SetLegacyDisplayMode('fixed'));assert(C.draft.player.components.distance.fontSize==font)
    assert(C:Exit(false));assert(C:Open());assert(C:SetComponent('distance'));assert(C:Adjust('font',1));assert(C:Exit(true))
    assert(F:GetHudModeLayoutsProjection().player.fixedInitialized==false,'editing head HUD silently created a stale fixed bank')
end)
Test('mode switch cancels an active gesture and rejects its late drag stop',function()
    local h,S,F,R,C=Calibration();assert(C:SetLegacyDisplayMode('fixed'));local root=C.preview.root
    assert(root.events.OnDragStart(root));assert(C.dragging)
    assert(C:SetLegacyDisplayMode('head'));local x=C.draft.player.components.buffs.x
    root.x=root.x+180;assert(root.events.OnDragStop(root)==false)
    assert(not C.dragging and C.draft.player.components.buffs.x==x)
    assert(C:Exit(false))
end)
Test('both edited modes save together, with mode-aware reset preset and copy',function()
    local h,S,F,R,C=Calibration();assert(C:SetComponent('distance'));assert(C:Adjust('font',2));local head=C.draft.player.components.distance.fontSize
    assert(C:SetLegacyDisplayMode('fixed'));assert(C:SetComponent('distance'));assert(C:Adjust('font',3));local fixed=C.draft.player.components.distance.fontSize
    assert(C:ApplyLayoutPreset('compact'));assert(C.draft.player.placement.mode=='fixed')
    assert(C:SetComponent('distance'));assert(C:Adjust('font',fixed-C.draft.player.components.distance.fontSize))
    assert(C:Exit(true));assert(F:GetScopeLayoutSettings('player').components.distance.fontSize==fixed)
    assert(F.Commands:SetHudDisplayMode('player','head'));assert(F:GetScopeLayoutSettings('player').components.distance.fontSize==head)
    assert(C:Open());assert(C:SetLegacyDisplayMode('fixed'));assert(C:ResetCurrentScope());assert(C.draft.player.placement.mode=='fixed')
    assert(C:SetScope('target'));assert(C:SetLegacyDisplayMode('fixed'));local targetX=C.draft.target.placement.x
    assert(C:SyncPlayerToTarget());assert(C.draft.target.placement.x==targetX,'copy placed target on top of self')
    local lines=table.concat(C:BuildTemplateSnapshotLines(),'\n')
    assert(lines:find('|TARGET|PLACEMENT|mode=fixed',1,true),'draft template lost mode/anchor')
    assert(C:Exit(false))
end)
Test('screen anchors use logical viewport consistently at several resolutions and scales',function()
    for _,size in ipairs({{1280,768,1},{1920,1080,1},{2560,1440,.75},{3840,2160,1.5}})do
        local h,S,F,R,C=Calibration({width=size[1],height=size[2],scale=size[3]})
        assert(C:SetLegacyDisplayMode('fixed'));local p=C.draft.player;local w,hgt=size[1]/size[3],size[2]/size[3]
        local x,y=F.ComputeFixedHudAnchor(p.placement,w,hgt)
        local rect=C.preview.expectedRect;local layout=R.ComputePlateLayout(x,y,p,4,4,{})
        assert(rect.x==layout.bar.left and rect.y==layout.bar.top,'preview uses a different fixed coordinate space')
        assert(C:Exit(true));h.ms=h.ms+300;F:PositionTick();R:VisualTick()
        local worldX,worldY=h:World(R.pools.player.root)
        assert(worldX==math.floor(x+R.pools.player.offsetX+.5)and worldY==math.floor(y+R.pools.player.offsetY+.5),'renderer double-scaled the fixed anchor')
    end
end)
Test('fixed partial updates preserve orientation paired identity and unknown distance',function()
    local h,S,F,R=dofile('tools/rs_pvp_hud_test_host.lua')({runtimeHud=true})
    dofile('features/combat/buff_display/rs_buff_display_arrangement.lua');LoadPlacement()
    assert(F.Commands:SetHudDisplayMode('player','fixed'));local snapshot=F:GetHudCalibrationSnapshot()
    snapshot.player.components.buffs.orientation='vertical';snapshot.player.components.class.nameLinked=true
    assert(F:PersistHudCalibrationSnapshot(snapshot));assert(F:PersistHudCalibrationSnapshot({player={components={distance={x=17}}}}))
    local p=F:GetScopeLayoutSettings('player');assert(p.components.buffs.orientation=='vertical'and p.components.class.nameLinked)
    R:VisualTick();assert(R.pools.player.info.distanceRoot.text=='--m','unknown distance masqueraded as zero or vanished')
    local anchors,reads,writes=h.anchors,h.projectionReads,h.writes
    for i=1,12 do F:PositionTick()end
    assert(h.anchors==anchors and h.writes==writes,'stationary fixed HUD rewrites geometry or saves')
    assert(h.projectionReads==reads+12,'mixed mode projected the fixed self HUD')
end)
Test('mode page follows self target selection and preserves other display controls',function()
    local h,S,F=Boot();S.FeatureRuntime.IsEnabled=function()return false end
    local ui=dofile('tools/rs_status_ui_test_host.lua')(S);local page=assert(ui:Build());assert(page:Refresh())
    local selector=assert(ui.widgets.v3_buff_display_mode,'settings mode selector missing')
    assert(selector:SetValue('fixed'));assert(F:GetHudComponentDisplayModeProjection('player','distance').mode=='fixed')
    assert(ui.widgets.v3_buff_visibility_scope:SetValue('target'));assert(selector.value=='head')
    assert(selector:SetValue('fixed'));assert(F.Commands:SetHudVisibility('target','distance',false))
    assert(not F:GetScopeLayoutSettings('target').components.distance.enabled)
    assert(F:GetScopeLayoutSettings('player').components.distance.enabled~=false)
    assert(not S.FeatureRuntime:IsEnabled(),'opening settings enabled a feature')
end)
Test('invalid placement fields reject before writes and later import failures restore mode',function()
    local h,S,F=Boot();local writes=h.io.writes
    for _,bad in ipairs({{target={mode='other'}},{target={x=10001}},{target={fixed={components={distance={fontSize=999}}}}},{other={mode='fixed'}}})do
        assert(not F:ImportAll({placement=bad},'merge'))
    end
    assert(h.io.writes==writes,'invalid mode import wrote a partial store')
    local save=S.Api.SaveData
    S.Api.SaveData=function(self,key,value)
        if key:find('buff_display_settings',1,true)then return false,'injected_settings_failure'end
        return save(self,key,value)
    end
    local ok=F:ImportAll({settings={refreshMs=777},placement={target={mode='fixed',x=8000,y=7000}}},'merge')
    assert(not ok and F:GetHudDisplayModeProjection('target').mode=='head','failed import committed only its display mode')
end)
Test('target alias geometry and visibility are independent between head and fixed modes',function()
    local h,S,F,R,C=Calibration();local original=F:GetTargetAliasHudConfigProjection()
    assert(C:SetScope('target'));assert(C:SetLegacyDisplayMode('fixed'));assert(C:SetComponent('alias'));assert(C:Nudge(37,29))
    assert(C:Exit(true));local fixed=F:GetTargetAliasHudConfigProjection();assert(fixed.x==original.x+37)
    assert(F.Commands:SetHudDisplayMode('target','head'))
    local head=F:GetTargetAliasHudConfigProjection();assert(head.x==original.x and head.y==original.y,'fixed alias edit overwrote head geometry')
    assert(F.Commands:SetHudDisplayMode('target','fixed'));assert(F:GetTargetAliasHudConfigProjection().x==fixed.x)
    assert(F:SetTargetAliasDisplayEnabled(false));assert(not F:GetTargetAliasHudConfigProjection().enabled)
    assert(F.Commands:SetHudDisplayMode('target','head'));assert(F:GetTargetAliasHudConfigProjection().enabled)
end)
Test('fixed alias saves and both mode aliases survive full sharing and rollback',function()
    local h,S,F,R,C=Calibration();assert(C:SetScope('target'));assert(C:SetComponent('alias'));assert(C:Nudge(-17,8))
    assert(C:SetLegacyDisplayMode('fixed'));assert(C:SetComponent('alias'));assert(C:Nudge(43,21));assert(C:Exit(true))
    local fixed=F:GetTargetAliasHudConfigProjection();local text=F:SerializeExport(F:ExportAll())
    local parsed=F:ParseImportText(text);assert(#parsed.errors==0,table.concat(parsed.errors,','))
    local h2,S2,F2,R2,C2=Calibration();assert(C2:Exit(false));assert(F2:ImportAll(parsed.data,'merge'))
    assert(F2:GetTargetAliasHudConfigProjection().x==fixed.x)
    assert(F2.Commands:SetHudDisplayMode('target','head'));assert(F2:GetTargetAliasHudConfigProjection().x==-17)
    assert(C2:Open());assert(C2:SetScope('target'));assert(C2:SetComponent('alias'));assert(C2:Nudge(13,0))
    assert(C2:SetLegacyDisplayMode('fixed'));assert(C2:SetComponent('alias'));assert(C2:Nudge(19,0))
    local save=S2.Api.SaveData
    S2.Api.SaveData=function(self,key,value)
        if key:find('buff_display_layout',1,true)then return false,'injected_layout_failure'end
        return save(self,key,value)
    end
    assert(not C2:Exit(true));assert(C2.visible and F2:GetHudDisplayModeProjection('target').mode=='head')
    assert(F2:GetTargetAliasHudConfigProjection().x==-17,'failed save retained the head alias half of a transaction')
    S2.Api.SaveData=save;assert(C2:Exit(false))
end)
Test('copying fixed self to head target exits the fixed-only position editor',function()
    local h,S,F,R,C=Calibration();assert(C:SetLegacyDisplayMode('fixed'));assert(C.component=='screen')
    assert(C:SyncPlayerToTarget());assert(C.component~='screen'and C.draft.target.placement.mode=='head')
    local x=C.draft.target.placement.x;assert(C:Nudge(10,0));assert(C.draft.target.placement.x==x)
    assert(C:Exit(false))
end)
Test('fixed screen edge anchor matches preview and stays stable as content bounds change',function()
    local h,S,F,R,C=Calibration();assert(C:SetLegacyDisplayMode('fixed'));C.inputs.x:SetText('1270');C.inputs.y:SetText('730')
    assert(C:ApplyInputFields());local p=C.draft.player;local x,y=F.ComputeFixedHudAnchor(p.placement,1280,768)
    assert(C:Exit(true));F:PositionTick();R:VisualTick()
    local pool=R.pools.player;local wx,wy=h:World(pool.root)
    assert(wx==math.floor(x+pool.offsetX+.5)and wy==math.floor(y+pool.offsetY+.5),'saved fixed anchor jumped due to pool clipping')
    F.laneData.player.gearScore=123456789;S.Events:Publish('v3.buff_display.plates.updated','equipment');R:MotionTick()
    wx,wy=h:World(pool.root);assert(wx-pool.offsetX==x and wy-pool.offsetY==y,'new content bounds drifted fixed anchor')
end)
Test('restoring entry layout uses the current modes own alias rather than the opening active mode',function()
    local h,S,F,R,C=Calibration();assert(C:Exit(false))
    assert(F:PersistTargetAliasHudConfig({enabled=true,x=11,y=-90,fontSize=13,alpha=.8}))
    assert(F.Commands:SetHudDisplayMode('target','fixed'));assert(F:PersistTargetAliasHudConfig({enabled=false,x=99,y=-70,fontSize=21,alpha=.4}))
    assert(F.Commands:SetHudDisplayMode('target','head'));assert(C:Open());assert(C:SetScope('target'));assert(C:SetLegacyDisplayMode('fixed'))
    assert(C:ApplyLayoutPreset('original'))
    assert(C.draft.target.aliasHud.x==99 and C.draft.target.aliasHud.fontSize==21 and C.draft.target.aliasHud.alpha==.4)
    assert(C.aliasDraft.enabled==false,'original preset restored the other modes visibility')
    assert(C:Exit(false))
end)
Test('cold mode switches inherit durable head alias settings and keep saved fixed aliases',function()
    local h,S,F=Boot(nil,true)
    assert(F:PersistTargetAliasHudConfig({enabled=true,x=37,y=-65,fontSize=17,alpha=.6}))
    local h2,S2,F2=Boot(h.disk,true)
    assert(F2.Commands:SetHudDisplayMode('target','fixed'))
    assert(F2:GetTargetAliasHudConfigProjection().x==37,'cold fixed initialization copied unloaded defaults')
    assert(F2:PersistTargetAliasHudConfig({enabled=false,x=88,y=-44,fontSize=20,alpha=.5}))
    local _,_,F3=Boot(h2.disk,true)
    assert(F3:GetTargetAliasHudConfigProjection().x==88 and not F3:GetTargetAliasHudConfigProjection().enabled)
    assert(F3.Commands:SetHudDisplayMode('target','head'))
    assert(F3:GetTargetAliasHudConfigProjection().x==37 and F3:GetTargetAliasHudConfigProjection().enabled)
end)
if failed>0 then error('FIXED_HUD '..failed..' failure(s), '..passed..' passed')end
print('FIXED_HUD PASS: '..passed..' cases')
