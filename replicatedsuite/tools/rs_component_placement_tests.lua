-- Replicated Suite · 组件独立固定位置回归，真实存档/校准，Native 为模型。
local passed,failed=0,0
local function Test(name,fn)local ok,err=xpcall(fn,debug.traceback);if ok then passed=passed+1;print('PASS component-placement '..name)else failed=failed+1;print('FAIL component-placement '..name..': '..tostring(err))end end
local FILE='features/combat/buff_display/rs_buff_display_placement.lua'
local function Boot(disk)
    local h,S,F=dofile('tools/rs_pvp_hud_test_host.lua')({disk=disk})
    for _,path in ipairs({'features/combat/buff_display/rs_buff_display_transfer_v2.lua','features/combat/buff_display/rs_buff_display_arrangement.lua',FILE})do dofile(path)end
    assert(F:EnsureStoreLoaded());return h,S,F
end
local function Calibration()
    return dofile('tools/rs_hud_template_copy_test_host.lua')({featureFiles={
        'features/combat/buff_display/rs_buff_display_transfer_v2.lua','features/combat/buff_display/rs_buff_display_arrangement.lua',FILE}})
end
Test('fixing only distance leaves every other component on head and survives reload and sharing',function()
    local h,S,F=Boot();assert(F.Commands:SetHudComponentDisplayMode('target','distance','fixed'))
    assert(F:GetHudComponentDisplayModeProjection('target','distance').mode=='fixed')
    for _,key in ipairs({'info','class','gearScore','buffs','debuffs','castBar','alias'})do assert(F:GetHudComponentDisplayModeProjection('target',key).mode=='head',key..' moved with distance')end
    local head,fixed=F:GetHudLayerSettingsProjection('target','head'),F:GetHudLayerSettingsProjection('target','fixed')
    assert(head.components.distance.enabled==false and head.components.buffs.enabled~=false)
    assert(fixed.components.distance.enabled~=false and fixed.components.buffs.enabled==false)
    assert(F:GetScopeSettingsProjection('target').placement.needsHead==true)
    local _,_,reloaded=Boot(h.disk);assert(reloaded:GetHudComponentDisplayModeProjection('target','distance').mode=='fixed')
    local text=F:SerializeExport(F:ExportAll());assert(text:find('HUDSLOT=target:distance:fixed:',1,true))
    local data=F:ParseImportText(text);assert(#data.errors==0,table.concat(data.errors,','))
    assert(reloaded:ImportAll(data.data,'merge'));assert(reloaded:GetHudComponentDisplayModeProjection('target','buffs').mode=='head')
    assert(not F:SerializeExport(F:ExportAll('tracking')):find('HUDSLOT',1,true))
end)
Test('visibility updates affect only the selected component layout bank',function()
    local h,S,F=Boot();local before=F:GetHudModeLayoutsProjection().target.head
    assert(F.Commands:SetHudComponentDisplayMode('target','distance','fixed'))
    local banks=F:GetHudModeLayoutsProjection();banks.target.fixed.components.distance.fontSize=22
    assert(F:PersistHudCalibrationSnapshot({modeLayouts=banks}))
    assert(F.Commands:SetHudVisibility('target','distance',false))
    local after=F:GetHudModeLayoutsProjection()
    assert(after.target.fixed.components.distance.enabled==false,'visibility wrote to head bank')
    assert(after.target.head.components.distance.fontSize==before.components.distance.fontSize,'fixed appearance leaked into head')
    assert(after.target.head.components.distance.enabled==before.components.distance.enabled,'fixed visibility changed head preference')
end)
Test('calibration mode button applies only to current component and uses independent screen XY',function()
    local h,S,F,R,C=Calibration();local writes=h.writes
    assert(C:SetScope('target'));assert(C:SetComponent('distance'));assert(h:Click('v3_buff_hud_calibration_mode'))
    assert(C.component=='distance','mode button changed selection to an entire HUD editor')
    assert(C.draft.target.placement.slots and C.draft.target.placement.slots.distance.mode=='fixed','component draft missing')
    C.inputs.x:SetText('1080');C.inputs.y:SetText('640');assert(C:ApplyInputFields())
    local distanceX=C.draft.target.placement.slots.distance.x
    assert(C:SetComponent('buffs'));assert((C.draft.target.placement or {}).mode=='head','unrelated component switched to fixed')
    assert(C:SetComponent('distance'));assert(C.draft.target.placement.slots.distance.x==distanceX)
    assert(h.writes==writes,'component preview persisted early')
    assert(C:Exit(true));assert(F:GetHudComponentDisplayModeProjection('target','distance').mode=='fixed')
    assert(F:GetHudComponentDisplayModeProjection('target','buffs').mode=='head')
end)
Test('calibration snapshot roundtrip preserves separate head and fixed appearance',function()
    local h,S,F=Boot();assert(F.Commands:SetHudComponentDisplayMode('target','distance','fixed'))
    local banks=F:GetHudModeLayoutsProjection();local headFont=banks.target.head.components.distance.fontSize
    banks.target.fixed.components.distance.fontSize=25
    assert(F:PersistHudCalibrationSnapshot({modeLayouts=banks}))
    assert(F:PersistHudCalibrationSnapshot(F:GetHudCalibrationSnapshot()))
    local after=F:GetHudModeLayoutsProjection()
    assert(after.target.head.components.distance.fontSize==headFont,'snapshot copied fixed font into head')
    assert(after.target.fixed.components.distance.fontSize==25)
end)
Test('two fixed components have independent position and reset only the selected anchor',function()
    local h,S,F,R,C=Calibration();assert(C:SetScope('target'));assert(C:SetComponent('distance'));assert(C:SetDisplayMode('fixed'))
    C.inputs.x:SetText('1000');C.inputs.y:SetText('600');C.inputs.font:SetText('24');assert(C:ApplyInputFields())
    assert(C:SetComponent('gearScore'));assert(C:SetDisplayMode('fixed'))
    C.inputs.x:SetText('800');C.inputs.y:SetText('500');assert(C:ApplyInputFields())
    local gearX=C.draft.target.placement.slots.gearScore.x
    assert(C:SetComponent('distance'));assert(C:ResetCurrentComponent())
    local position=C.draft.target.placement.slots.distance
    local default=F:GetDefaultHudComponentPlacement('target','distance')
    assert(position.x==default.x and position.y==default.y,'reset retained the edited fixed anchor')
    assert(C.draft.target.placement.slots.gearScore.x==gearX,'reset moved another component')
    local lines=assert(C:BuildTemplateSnapshotLines())
    assert(table.concat(lines,'\n'):find('|SLOT|component=distance,mode=fixed,',1,true),'template omitted per-component mode')
    assert(C:Exit(true));assert(F:GetHudComponentDisplayModeProjection('target','gearScore').x==gearX)
end)
Test('mixed preview reads each components own appearance and cancel makes no writes',function()
    local h,S,F,R,C=Calibration();local writes=h.writes
    S.UI.SetFontSize=function(_,widget,value)widget.fontSize=value;return true end
    assert(C:SetScope('target'));assert(C:SetComponent('distance'));assert(C:SetDisplayMode('fixed'))
    C.inputs.font:SetText('24');C.inputs.alpha:SetText('0.4');assert(C:ApplyInputFields())
    assert(C:SetComponent('buffs'));C.allPreviewEnabled=true;assert(C:LayoutGlobalPreview())
    local preview=C.globalPreview.items.distance.preview
    assert(preview.infoLabel.fontSize==24,'head selection changed fixed distance preview font')
    assert(preview.root.alpha==.4,'head selection changed fixed distance alpha')
    assert(C:Exit(false));assert(h.writes==writes,'cancel wrote component routing')
    assert(F:GetHudComponentDisplayModeProjection('target','distance').mode=='head')
end)
Test('malformed component shares reject before any persistence writes',function()
    local h,S,F=Boot();local text=F:SerializeExport(F:ExportAll());local writes=h.io.writes
    for _,line in ipairs({'HUDSLOT=target:distance:fixed:10001:5000','HUDSLOT=player:alias:fixed:5000:5000',
        'HUDSLOT=target:distance:fixed:5000:5000\nHUDSLOT=target:distance:head:4000:4000'})do
        local parsed=F:ParseImportText(text..'\n'..line)
        assert(#parsed.errors>0,'malformed slot accepted')
        assert(not F:ImportAll(parsed.data,'merge'),'invalid component share persisted')
    end
    assert(h.io.writes==writes)
end)
Test('fixing distance keeps other components preview anchored to the character',function()
    local h,S,F,R,C=Calibration();assert(C:SetScope('target'));assert(C:SetComponent('distance'))
    local class=C.globalPreview.items.class.root;local x,y=class.x,class.y
    assert(C:SetDisplayMode('fixed'))
    assert(class.x==x and class.y==y,'fixing distance moved a head component preview')
    assert(C:SetComponent('class'));assert(C.preview.root.x==x and C.preview.root.y==y)
end)
Test('restoring entry appearance cannot turn a component bank label into whole HUD fixed mode',function()
    local h,S,F,R,C=Calibration();assert(C:SetScope('target'));assert(C:SetComponent('distance'));assert(C:SetDisplayMode('fixed'))
    assert(C:ApplyLayoutPreset('original'));assert(C:Exit(true))
    assert(F:GetHudComponentDisplayModeProjection('target','distance').mode=='fixed')
    for _,key in ipairs({'class','gearScore','buffs','castBar'})do
        assert(F:GetHudComponentDisplayModeProjection('target',key).mode=='head','restoring appearance moved '..key)
    end
end)
Test('restoring current HUD resets fixed anchors without changing component modes',function()
    local h,S,F,R,C=Calibration();assert(C:SetScope('target'));assert(C:SetComponent('distance'));assert(C:SetDisplayMode('fixed'))
    C.inputs.x:SetText('1000');C.inputs.y:SetText('600');assert(C:ApplyInputFields());assert(C:ResetCurrentScope())
    local position=C.draft.target.placement.slots.distance;local default=F:GetDefaultHudComponentPlacement('target','distance')
    assert(position.x==default.x and position.y==default.y,'scope reset kept edited component anchor')
    assert(C:Exit(true));assert(F:GetHudComponentDisplayModeProjection('target','distance').mode=='fixed')
    assert(F:GetHudComponentDisplayModeProjection('target','buffs').mode=='head')
end)
Test('multi-row fixed Buff preview anchors its first icon exactly like the renderer',function()
    local h,S,F,R,C=Calibration();assert(C:SetComponent('buffs'));assert(C:SetDisplayMode('fixed'));assert(C:SetGroupOrientation('horizontal'))
    C.inputs.x:SetText('600');C.inputs.y:SetText('400');C.inputs.perRow:SetText('2');C.inputs.rows:SetText('2');assert(C:ApplyInputFields())
    local x,y=h:World(C.preview.icons[1].root)
    assert(x==600 and y==400,'fixed preview anchor used the bounding box instead of the first icon')
    local thirdX,thirdY=h:World(C.preview.icons[3].root)
    assert(thirdX==x and thirdY<y,'fixed multi-row Buffs lost upward growth')
    assert(C:Exit(true));F.State.settings.headShowAll=true
    F.laneData.player.buffRows={}
    for i=1,4 do F.laneData.player.buffRows[i]={id=i,iconPath='fixed-multi-'..i..'.dds'}end
    F:InvalidateSettingsCache();assert(R:Reconcile('component_preview_alignment'));R:VisualTick()
    local roots={}
    for _,marker in ipairs(R.pools.player_fixed.icons)do roots[marker.icon.texture]=marker.root end
    local liveX,liveY=h:World(assert(roots['fixed-multi-1.dds']))
    local liveThirdX,liveThirdY=h:World(assert(roots['fixed-multi-3.dds']))
    assert(liveX==x and liveY==y and liveThirdX==thirdX and liveThirdY==thirdY,'saving moved the fixed Buff rows')
end)
if failed>0 then error('COMPONENT_PLACEMENT '..failed..' failure(s), '..passed..' passed')end
print('COMPONENT_PLACEMENT PASS: '..passed..' cases')
