-- Replicated Suite · 分组件屏幕固定 Renderer 回归
-- 作者：Replicated
-- QQ群：1104129461
-- 真实 Runtime/Feature/Renderer；Native 图形与游戏事实使用现有受控宿主。
local passed,failed=0,0
local function Test(name,fn)
    local ok,err=xpcall(fn,debug.traceback)
    if ok then passed=passed+1;print('PASS component-renderer '..name)
    else failed=failed+1;print('FAIL component-renderer '..name..': '..tostring(err))end
end
local function Boot(slots,configure)
    local h,S,F,R=dofile('tools/rs_pvp_hud_test_host.lua')({runtimeHud=true})
    dofile('features/combat/buff_display/rs_buff_display_arrangement.lua')
    dofile('features/combat/buff_display/rs_buff_display_placement.lua')
    F.laneData.target.class={name='Example',value='Example',icon='class.dds'}
    F.laneData.target.distance=25.1;F:InvalidateSettingsCache();R:VisualTick()
    h.initialHeadClassX,h.initialHeadClassY=h:World(R.pools.target.info.iconRoot)
    for key,slot in pairs(slots)do assert(F.Commands:SetHudComponentDisplayMode('target',key,slot.mode))end
    local draft=F:GetHudCalibrationSnapshot()
    for key,slot in pairs(slots)do
        draft.target.placement.slots[key].x=slot.x;draft.target.placement.slots[key].y=slot.y
    end
    if configure then draft.target.placement.mode='fixed';configure(draft)end
    assert(F:PersistHudCalibrationSnapshot(draft))
    F.laneData.target.targetPresent=true;F.laneData.target.isSelf=false
    F.laneData.target.distance=25.1
    F.laneData.target.class={name='Example',value='Example',icon='class.dds'}
    F:InvalidateSettingsCache();assert(R:Reconcile('component_renderer_test'))
    return h,S,F,R
end
Test('only distance is fixed while head class still follows its unit',function()
    local h,S,F,R=Boot({distance={mode='fixed',x=2000,y=7000}})
    local fixed=R.pools.target_fixed
    assert(fixed and fixed.info and fixed.info.distanceRoot,'fixed distance has no independent renderer layer')
    assert(fixed.root.shown and fixed.info.distanceRoot.shown)
    assert(not R.pools.target.info.distanceRoot.shown,'distance is duplicated above the head')
    assert(R.pools.target.info.iconRoot.shown,'head class disappeared with fixed distance')
    local classX,classY=h:World(R.pools.target.info.iconRoot)
    assert(classX==h.initialHeadClassX and classY==h.initialHeadClassY,'fixing distance moved the remaining head class')
    local x,y=h:World(fixed.info.distanceRoot)
    assert(x==256 and y==538,'fixed distance did not use its own normalized screen anchor')
    local hx,hy=h:World(R.pools.target.info.iconRoot)
    h.points.target={950,400,1};F:PositionTick()
    local nx,ny=h:World(fixed.info.distanceRoot)
    local nhx,nhy=h:World(R.pools.target.info.iconRoot)
    assert(nx==x and ny==y,'fixed distance followed camera movement')
    assert(nhx-hx==100 and nhy-hy==50,'head class stopped following the unit')
    assert(#fixed.icons==0 and fixed.cast==nil,'distance-only fixed layer allocated unused icon rows or cast bar')
end)
Test('several fixed components keep separate screen positions and resize once',function()
    local h,S,F,R=Boot({distance={mode='fixed',x=1000,y=2000},gearScore={mode='fixed',x=8000,y=8000}})
    F.laneData.target.gearScore=12345;R:VisualTick()
    local pool=R.pools.target_fixed
    local dx,dy=h:World(pool.info.distanceRoot);local gx,gy=h:World(pool.info.gearRoot)
    assert(dx==128 and dy==154 and gx==1024 and gy==614,'fixed components shared one screen anchor')
    local content=R.motionMetrics.contentBuilds
    h.width,h.height=1600,900;h.ms=h.ms+250;F:PositionTick()
    dx,dy=h:World(pool.info.distanceRoot);gx,gy=h:World(pool.info.gearRoot)
    assert(dx==160 and dy==180 and gx==1280 and gy==720,'viewport resize lost independent normalized slots: '..tostring(dx)..','..tostring(dy)..' / '..tostring(gx)..','..tostring(gy))
    assert(R.motionMetrics.contentBuilds==content,'viewport resize rebuilt content')
    local anchors=h.anchors
    for i=1,8 do R:MotionTick()end
    assert(h.anchors==anchors,'stationary fixed components rewrote anchors')
    h.scale=1.5;h.ms=h.ms+250;F:PositionTick()
    local width,height=F:GetFixedHudViewport()
    local sx,sy=F.ComputeFixedHudAnchor({x=1000,y=2000},width,height)
    dx,dy=h:World(pool.info.distanceRoot)
    assert(dx==sx and dy==sy,'fixed logical viewport was scaled twice')
end)
Test('head projection loss leaves fixed distance dynamic and both layers clear immediately',function()
    local h,S,F,R=Boot({distance={mode='fixed',x=2000,y=7000}})
    local pool=R.pools.target_fixed
    h.points.target=nil;F:PositionTick()
    assert(not R.pools.target.root.shown and pool.root.shown,'fixed layer depends on head projection')
    local builds=R.motionMetrics.contentBuilds
    F.laneData.target.distance=25.2;S.Events:Publish('v3.buff_display.plates.updated','distance');R:MotionTick()
    assert(pool.info.distanceRoot.text=='25.2m' and pool.root.shown,'fixed distance stopped updating without head projection')
    assert(R.motionMetrics.contentBuilds==builds,'same-width fixed distance rebuilt all content')
    S.Events:Publish('v3.buff_display.plates.updated','target_identity_invalidated')
    assert(not pool.root.shown and not R.pools.target.root.shown,'target identity invalidation did not clear both layers immediately')
    F.laneData.target.targetPresent=false;R:MotionTick()
    assert(not pool.root.shown,'invalid target resurrected in fixed layer')
end)
Test('calibration suppression and feature stop hide both pools',function()
    local h,S,F,R=Boot({distance={mode='fixed',x=2000,y=7000}})
    assert(R.pools.target.root.shown and R.pools.target_fixed.root.shown)
    assert(R:SetCalibrationSuppressed(true,'test'))
    assert(not R.pools.target.root.shown and not R.pools.target_fixed.root.shown)
    assert(R:SetCalibrationSuppressed(false,'test'))
    assert(R.pools.target.root.shown and R.pools.target_fixed.root.shown)
    assert(R:Stop('test'))
    assert(not R.pools.target.root.shown and not R.pools.target_fixed.root.shown)
end)
Test('text class icon equipment rows cast and alias use their own component anchors',function()
    local slots={}
    for index,key in ipairs({'info','class','buffs','debuffs','mainHand','offHand','ranged','wings','castBar','alias'})do
        slots[key]={mode='fixed',x=index*800,y=index*700}
    end
    local h,S,F,R=Boot(slots,function(draft)
        for key in pairs(slots)do
            if draft.target.components[key]then draft.target.components[key].enabled=true end
        end
        draft.target.info.enabled=true;draft.target.info.showClass=true
    end)
    F.State.settings.headShowAll=true
    local lane=F.laneData.target
    lane.buffRows={{id=11,iconPath='buff-first.dds'},{id=12,iconPath='buff-second.dds'}}
    lane.debuffRows={{id=21,iconPath='debuff-first.dds'}}
    lane.targetLoadout=nil
    for _,key in ipairs({'mainHand','offHand','ranged','wings'})do lane[key]={icon=key..'.dds'}end
    lane.cast={casting=true,spellName='cast',currMs=100,totalMs=1000}
    lane.targetAlias='Nickname';F:InvalidateSettingsCache();R:VisualTick()
    local pool=R.pools.target_fixed
    local widgets={info=pool.info.classTextRoot,class=pool.info.iconRoot,castBar=pool.cast.root,alias=pool.info.aliasRoot}
    for _,marker in ipairs(pool.icons)do
        if marker.root.shown then
            local path=marker.icon.texture
            if path=='buff-first.dds'then widgets.buffs=marker.root
            elseif path=='debuff-first.dds'then widgets.debuffs=marker.root
            else
                for _,key in ipairs({'mainHand','offHand','ranged','wings'})do if path==key..'.dds'then widgets[key]=marker.root end end
            end
        end
    end
    for key,slot in pairs(slots)do
        local widget=assert(widgets[key],'component did not draw: '..key)
        assert(widget.shown,'component is hidden: '..key)
        local x,y=h:World(widget);local expectedX,expectedY=F.ComputeFixedHudAnchor(slot,F:GetFixedHudViewport())
        assert(x==expectedX and y==expectedY,'wrong screen anchor for '..key..': '..x..','..y)
    end
    assert(not R.pools.target.info.classTextRoot.shown and not R.pools.target.info.iconRoot.shown,'fixed class content duplicated on head layer')
    local second
    for _,marker in ipairs(pool.icons)do if marker.icon.texture=='buff-second.dds'then second=marker.root end end
    local firstX,firstY=h:World(widgets.buffs);local nextX,nextY=h:World(assert(second))
    assert(nextX>firstX and nextY==firstY,'fixed buff row lost its relative icon layout')
end)
Test('fixed distance custom and dynamic colors use target scope and preserve alpha',function()
    local h,S,F,R=Boot({distance={mode='fixed',x=2000,y=7000}})
    dofile('features/combat/buff_display/rs_buff_display_colors.lua');assert(F:EnsureHudColorsLoaded())
    S.UI.SetColor=function(_,widget,r,g,b,a)widget.customColor={r,g,b,a};return true end
    assert(F.Commands:SetHudColor('target','distance',{0.2,0.4,0.6}))
    assert(F.Commands:SetHudColor('player','distance',{0.8,0.6,0.4}))
    local draft=F:GetHudCalibrationSnapshot()
    draft.target.placement.mode='fixed';draft.target.components.distance.alpha=0.37
    assert(F:PersistHudCalibrationSnapshot(draft))
    F.laneData.target.targetPresent=true;R:VisualTick()
    local root=R.pools.target_fixed.info.distanceRoot
    assert(root.customColor[1]==0.2 and root.alpha==0.37,'fixed target text inherited player color or lost alpha')
    assert(F.Commands:SetHudColor('target','distance',{0.3,0.5,0.7}))
    F.laneData.target.distance=25.2;S.Events:Publish('v3.buff_display.plates.updated','distance');R:MotionTick()
    assert(root.customColor[1]==F:GetHudColor('target','distance',25.2) and root.text=='25.2m' and root.alpha==0.37,'dynamic fixed distance lost target colors')
end)
Test('player cooldown fixed row uses player facts and does not duplicate on head',function()
    local h,S,F,R=Boot({distance={mode='fixed',x=2000,y=7000}})
    assert(F.Commands:SetHudComponentDisplayMode('player','cooldowns','fixed'))
    local draft=F:GetHudCalibrationSnapshot()
    draft.player.placement.mode='fixed';draft.player.placement.slots.cooldowns.x=9000;draft.player.placement.slots.cooldowns.y=1000
    draft.player.components.cooldowns.enabled=true;assert(F:PersistHudCalibrationSnapshot(draft))
    F.laneData.player.cooldownRows={{id=101,iconPath='player-cooldown.dds',timeText='4'}}
    R:VisualTick()
    local pool=assert(R.pools.player_fixed)
    local marker
    for _,item in ipairs(pool.icons)do if item.icon.texture=='player-cooldown.dds'then marker=item end end
    assert(marker and marker.root.shown,'fixed player cooldown did not use player facts')
    local x,y=h:World(marker.root)
    assert(x==1152 and y==77,'fixed player cooldown ignored its own anchor')
    for _,item in ipairs(R.pools.player.icons)do assert(item.icon.texture~='player-cooldown.dds' or not item.root.shown,'cooldown duplicated on head')end
    assert(R.cooldownEvidence.drawn==1,'fixed cooldown lost accepted-submission evidence')
end)
print(string.format('COMPONENT RENDERER RESULT %d passed / %d failed',passed,failed))
if failed>0 then os.exit(1)end
