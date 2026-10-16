------------------------------------------------------------------------
-- Replicated Suite · HUD 布局预设与横纵排列回归
-- 作者：Replicated
-- QQ群：1104129461
------------------------------------------------------------------------
local passed,failed=0,0
local function Test(name,fn)
    local ok,err=xpcall(fn,debug.traceback)
    if ok then passed=passed+1;print('PASS hud-layouts '..name)
    else failed=failed+1;print('FAIL hud-layouts '..name..': '..tostring(err))end
end
local function Boot(disk)
    local h,S,F=dofile('tools/rs_pvp_hud_test_host.lua')({disk=disk})
    dofile('features/combat/buff_display/rs_buff_display_transfer_v2.lua')
    dofile('features/combat/buff_display/rs_buff_display_arrangement.lua')
    assert(F:EnsureStoreLoaded());return h,S,F
end
Test('directions persist independently without extending historical component schemas',function()
    local h,S,F=Boot();local snapshot=F:GetHudCalibrationSnapshot()
    snapshot.player.components.buffs.orientation='vertical'
    snapshot.player.components.cooldowns.orientation='vertical'
    assert(F:PersistHudCalibrationSnapshot(snapshot))
    assert(F:GetScopeLayoutSettings('player').components.buffs.orientation=='vertical')
    assert(F:GetScopeLayoutSettings('target').components.buffs.orientation==nil)
    assert(F.State.settings.components.buffs.orientation==nil,'direction polluted the old canonical')
    local _,_,reloaded=Boot(h.disk)
    assert(reloaded:GetScopeLayoutSettings('player').components.cooldowns.orientation=='vertical')
end)
local function Calibration(withColors)
    local files={}
    if withColors then files[#files+1]='features/combat/buff_display/rs_buff_display_colors.lua'end
    files[#files+1]='features/combat/buff_display/rs_buff_display_arrangement.lua'
    local h,S,F,P,C=dofile('tools/rs_hud_template_copy_test_host.lua')({featureFiles=files})
    S.Layout.ResolveSuiteOwnedViewportLogicalRect=function(_,n)local x,y=h:World(n);return x,y,n.width,n.height end
    dofile('ui/framework/rs_ui_popup_positioning.lua')
    if withColors then
        S.UI.SetColor=function(_,n,r,g,b,a)n.color={r,g,b,a};return true end
        S.UI.CreateSlider=function(_,p,id,x,y,w,ht)
            local n=h.Native(p,id,x,y,w,ht);function n:SetValue(v)self.value=v end;function n:GetValue()return self.value end;return n
        end
        S.UI.GetSliderValue=function(_,n)return n.value or 0 end
        S.UI.SetSliderValue=function(_,n,v)n.value=v;return true end
        dofile('presentation/v3/widgets/rs_v3_buff_color_settings.lua');assert(C:RefreshControls())
    end
    return h,S,F,P,C
end
Test('approved compact preset previews six Buffs four equipment slots and a paired identity',function()
    local h,S,F,P,C=Calibration(true);local writes=h.writes
    assert(C:ApplyColorPatch({player={classText={0.19,0.39,0.59}}}))
    assert(C.layoutPreset:Open());local button=C.layoutPreset.optionButtons[2]
    assert(button.events.OnClick(button,'LeftButton'))
    assert(C.draft.player.components.class.nameLinked==true,'compact identity is still split into distant slots')
    assert(C.preview.icons[6]and C.preview.icons[6].root.shown,'approved six-icon Buff row is truncated')
    assert(not C.preview.icons[7]or not C.preview.icons[7].root.shown)
    for _,key in ipairs({'mainHand','offHand','ranged','wings'})do
        assert(C.globalPreview.items[key].preview.icons[1].root.shown,'approved equipment preview omitted '..key)
    end
    assert(C.colorDraft.player.classText[1]==0.19 and h.writes==writes)
    local lines=table.concat(C:BuildTemplateSnapshotLines(),'\n')
    assert(lines:find('|PLAYER|IDENTITY|paired=1',1,true),'draft export omitted identity grouping')
    assert(C:Exit(false));assert(h.writes==writes)
end)
Test('compact identity persists independently and retains grouping through partial geometry updates',function()
    local h,S,F=Boot();local snapshot=F:GetHudCalibrationSnapshot()
    snapshot.player=assert(F:GetHudLayoutPreset('compact','player',snapshot.player))
    assert(F:PersistHudCalibrationSnapshot(snapshot))
    assert(F:GetScopeLayoutSettings('player').components.class.nameLinked==true)
    assert(F:GetScopeLayoutSettings('target').components.class.nameLinked==false)
    assert(F.State.settings.components.class.nameLinked==nil,'paired mode polluted the historical canonical')
    assert(F:PersistHudCalibrationSnapshot({player={components={class={x=3}}}}))
    local _,_,loaded=Boot(h.disk)
    assert(loaded:GetScopeLayoutSettings('player').components.class.nameLinked==true)
    assert(loaded:GetScopeLayoutSettings('player').components.class.x==3)
end)
Test('paired class icon follows short long and multibyte names at every HUD scale',function()
    local h,S,F,P,C=Calibration()
    for _,scale in ipairs({.5,.75,1,1.25,2})do
        local current=F:GetScopeLayoutSettings('player');current.plateScale=scale
        local p=F:GetHudLayoutPreset('compact','player',current)
        local L=P.ComputePlateLayout(0,0,p,12,8,{})
        for _,name in ipairs({'法师','血之猎人','Archer','Стрелок'})do
            local function Geometry()
                local layout=P.ComputePlateLayout(0,0,p,12,8,{})
                return P.ComputeInfoItemsLayout({class={value=name,icon='class.dds'},gearScore={value='123456'},distance={value='28.4m'}},p.info,p.components,layout.bar.centerX,layout.info.top,layout.info.font,scale,'player')
            end
            local g=Geometry();local gap=g.classText.x-g.iconX-g.iconSize
            assert(gap==math.max(2,math.floor(4*scale)),'class portrait is not adjacent to '..name)
            assert(math.abs((g.iconY+g.iconSize/2)-(g.classText.y+g.classText.height/2))<=1,'paired identity is not vertically aligned')
            if name=='血之猎人'then assert(g.classText.width<=4*L.info.font+4,'UTF-8 byte length left a false gap before the name')end
            p.info.showClass=false;local hidden=Geometry();p.info.showClass=true
            assert(hidden.iconX==g.iconX and hidden.iconY==g.iconY,'hiding the paired name moved its portrait')
            local beforeX,beforeY=g.iconX,g.iconY;p.info.x=p.info.x+17;p.info.y=p.info.y+12
            local moved=Geometry();assert(moved.iconX-beforeX==17 and math.abs(moved.iconY-beforeY-12*scale)<=1,'moving the name left its icon behind')
            p.info.x=p.info.x-17;p.info.y=p.info.y-12
        end
    end
end)
Test('approved compact equipment order and full rows survive save at both equipment generations',function()
    local h,S,F,P,C=Calibration()
    for _,version in ipairs({3,5})do for _,scale in ipairs({.5,1,1.25,2})do for _,width in ipairs({80,150,320})do
        F.State.settings.layoutPresetVersion=version
        local snapshot=F:GetHudCalibrationSnapshot();snapshot.player.plateScale=scale;snapshot.player.plate.width=width
        snapshot.player=assert(F:GetHudLayoutPreset('compact','player',snapshot.player))
        assert(F:PersistHudCalibrationSnapshot(snapshot));local p=F:GetScopeLayoutSettings('player')
        local L=P.ComputePlateLayout(0,0,p,12,8,{mainHand=true,offHand=true,ranged=true,wings=true})
        local slots={};for _,group in ipairs({L.leftGroup,L.rightGroup})do for _,s in ipairs(group.slots)do slots[s.key]=s end end
        assert(slots.mainHand.x+slots.mainHand.size<=slots.offHand.x and slots.offHand.x+slots.offHand.size<L.bar.left,'left equipment pair was lost')
        assert(L.bar.right<slots.ranged.x and slots.ranged.x+slots.ranged.size<=slots.wings.x,'right ranged/back pair was lost')
        local y=slots.mainHand.y;for _,s in pairs(slots)do assert(s.y==y,'equipment row has inconsistent baselines')end
        local a=p.components.debuffs;local grid=F.ComputeHudIconGrid(8,L.debuff.size,L.debuff.spacing,a.maxPerRow,a.maxRows,false,false)
        local castTop=math.floor(L.cast.top+p.components.castBar.y*scale)
        local textBottom=castTop+math.max(4,math.floor(p.components.castBar.size*scale))+16
        assert(castTop>L.debuff.firstTop+grid.height,'full Debuff rows overlap the cast bar')
        assert(L.bar.centerY+math.floor(p.components.cooldowns.y*scale)>textBottom,'cast text overlaps the cooldown row')
    end end end
end)
Test('real compact renderer receives grouping and draws all four equipment facts',function()
    local h,S,F,P=dofile('tools/rs_pvp_hud_test_host.lua')({runtimeHud=true})
    dofile('features/combat/buff_display/rs_buff_display_arrangement.lua')
    local snapshot=F:GetHudCalibrationSnapshot();snapshot.player=F:GetHudLayoutPreset('compact','player',snapshot.player)
    for _,cfg in pairs(snapshot.player.components)do cfg.enabled=true end
    assert(F:PersistHudCalibrationSnapshot(snapshot));F.State.settings.headShowAll=true;F:InvalidateSettingsCache()
    local lane=F.laneData.player;lane.buffRows={};lane.debuffRows={};lane.cooldownRows={}
    for _,def in ipairs({{'buffRows','buff',6},{'debuffRows','debuff',4},{'cooldownRows','cooldown',4}})do
        for i=1,def[3]do lane[def[1]][i]={id=i,category=def[2],iconPath=def[2]..'.dds',timeText='12'}end
    end
    lane.class={name='血之猎人',icon='class.dds'};lane.gearScore=16683;lane.distance=28.4
    lane.cast={casting=true,spellName='瞄准射击',currMs=500,totalMs=1000}
    for _,key in ipairs({'mainHand','offHand','ranged','wings'})do lane[key]={name=key,icon=key..'.dds'}end
    P:VisualTick(true);local pool=P.pools.player
    local icon,name=pool.info.iconRoot,pool.info.classTextRoot
    assert(icon.shown and name.shown and name.x-icon.x-icon.width==4,'runtime ignored paired identity projection')
    local found={}
    for _,entry in ipairs(pool.icons)do if entry.root.shown then found[entry.iconPath]=true end end
    for _,key in ipairs({'mainHand','offHand','ranged','wings'})do assert(found[key..'.dds'],'runtime omitted equipment '..key)end
    local writes,scans,reads=h.writes,h.scans,h.itemReads
    for i=1,10 do P:VisualTick(true)end
    assert(h.writes==writes and h.scans==scans and h.itemReads==reads,'compact rendering introduced observation or persistence work')
end)
Test('identity grouping shares completely while tracking and old packages preserve the local mode',function()
    local h,S,F=Boot();local p=F:GetHudCalibrationSnapshot();p.player=F:GetHudLayoutPreset('compact','player',p.player)
    assert(F:PersistHudCalibrationSnapshot(p));local text=F:SerializeExport(F:ExportAll())
    assert(text:find('HUDIDENTITY=player:paired',1,true),'complete share omitted paired identity')
    assert(not F:SerializeExport(F:ExportAll('tracking')):find('HUDIDENTITY=',1,true))
    local _,_,other=Boot();local parsed=other:ParseImportText(text)
    assert(#parsed.errors==0,table.concat(parsed.errors,';'));assert(other:ImportAll(parsed.data,'merge'))
    assert(other:GetScopeLayoutSettings('player').components.class.nameLinked==true)
    local old=text:gsub('\nHUDIDENTITY=[^\n]+','');assert(other:ImportAll(other:ParseImportText(old).data,'merge'))
    assert(other:GetScopeLayoutSettings('player').components.class.nameLinked==true,'old package reset identity grouping')
end)
Test('paired identity rolls back after geometry rejection and legacy direction-only saves still load',function()
    local h,S,F=Boot();assert(F:PersistHudArrangement({player={buffs='vertical'}}))
    local _,_,legacy=Boot(h.disk);assert(legacy:GetScopeLayoutSettings('player').components.buffs.orientation=='vertical')
    local p=F:GetHudCalibrationSnapshot();p.player=F:GetHudLayoutPreset('compact','player',p.player)
    local save=S.Api.SaveData
    S.Api.SaveData=function(self,key,value)if not key:find('buff_display_arrangement',1,true)then return false,'geometry_rejected'end;return save(self,key,value)end
    assert(F:PersistHudCalibrationSnapshot(p)==false)
    assert(F:GetScopeLayoutSettings('player').components.class.nameLinked==false)
    assert(F:GetScopeLayoutSettings('player').components.buffs.orientation=='vertical')
    local _,_,reloaded=Boot(h.disk);assert(reloaded:GetScopeLayoutSettings('player').components.class.nameLinked==false)
end)
Test('malformed and duplicate identity metadata is rejected before writes',function()
    local h,S,F=Boot();local text=F:SerializeExport(F:ExportAll());local writes=h.io.writes
    for _,row in ipairs({'HUDIDENTITY=player:wrong','HUDIDENTITY=other:paired','HUDIDENTITY=player:paired\nHUDIDENTITY=player:free'})do
        local parsed=F:ParseImportText(text..'\n'..row)
        assert(#parsed.errors>0 and F:ImportAll(parsed.data,'merge')==false,'bad identity metadata accepted')
    end
    assert(h.io.writes==writes)
end)
Test('HUD editor previews vertical icons at the original icon size and cancels the draft',function()
    local h,S,F,P,C=Calibration();local writes=h.writes
    assert(type(C.SetGroupOrientation)=='function','HUD adjustment has no orientation action')
    assert(C:SetGroupOrientation('vertical'))
    local icons=C.preview.icons
    assert(icons[1].root.x==icons[2].root.x and icons[2].root.y>icons[1].root.y)
    assert(icons[1].root.width==29 and C.preview.root.height>29,'vertical preview enlarged one icon to the group height')
    assert(C.fieldRows.perRow.label:GetText()=='每列' and C.fieldRows.rows.label:GetText()=='列数')
    assert(h.writes==writes and F:GetScopeLayoutSettings('player').components.buffs.orientation==nil)
    assert(C:Exit(false));assert(h.writes==writes)
end)
Test('orientation controls preserve pending coordinate input and keep inline colors visible',function()
    local h,S,F,P,C=Calibration(true);local colors=C.colorPanel
    C.inputs.x:SetText('137');assert(C:SetGroupOrientation('vertical'))
    assert(C.inputs.x:GetText()=='137'and colors.root.visible and C.colorPreset.visible,'direction toggle lost another editing control')
    assert(C:ApplyColorPatch({player={buffTime={0.2,0.4,0.6}}}))
    assert(C:ApplyLayoutPreset('balanced'))
    assert(C.colorDraft.player.buffTime[1]==0.2,'layout preset erased the custom palette')
    assert(C:Exit(false))
end)
Test('direction and geometry saves compensate each other on rejection',function()
    local h,S,F=Boot();local snapshot=F:GetHudCalibrationSnapshot()
    snapshot.player.components.debuffs.orientation='vertical'
    local save=S.Api.SaveData
    S.Api.SaveData=function(self,key,value)
        if not key:find('buff_display_arrangement',1,true)then return false,'layout_rejected'end
        return save(self,key,value)
    end
    local ok,err=F:PersistHudCalibrationSnapshot(snapshot)
    assert(ok==false and err and F:GetScopeLayoutSettings('player').components.debuffs.orientation==nil)
    S.Api.SaveData=function()return false,'arrangement_rejected'end
    local before=h.io.writes;assert(F:PersistHudCalibrationSnapshot(snapshot)==false)
    assert(h.io.writes==before and F:GetScopeLayoutSettings('player').components.debuffs.orientation==nil)
end)
Test('partial geometry updates retain a previously saved vertical direction',function()
    local h,S,F=Boot();assert(F:PersistHudArrangement({player={buffs='vertical'}}))
    assert(F:PersistHudCalibrationSnapshot({player={components={buffs={x=77}}}}))
    assert(F:GetScopeLayoutSettings('player').components.buffs.orientation=='vertical','partial X update cleared direction')
end)
Test('cold save rollback restores the loaded disk directions rather than factory defaults',function()
    local h,S,F=Boot();assert(F:PersistHudArrangement({player={buffs='vertical'},target={debuffs='vertical'}}))
    local cold,S2,F2=dofile('tools/rs_pvp_hud_test_host.lua')({disk=h.disk})
    dofile('features/combat/buff_display/rs_buff_display_arrangement.lua')
    local save=S2.Api.SaveData
    S2.Api.SaveData=function(self,key,value)
        if not key:find('buff_display_arrangement',1,true)then return false,'cold_geometry_rejected'end
        return save(self,key,value)
    end
    assert(F2:PersistHudCalibrationSnapshot({player={components={buffs={orientation='horizontal'}}}})==false)
    local _,_,reloaded=Boot(cold.disk)
    assert(reloaded:GetScopeLayoutSettings('player').components.buffs.orientation=='vertical','cold rollback overwrote saved player direction')
    assert(reloaded:GetScopeLayoutSettings('target').components.debuffs.orientation=='vertical','cold rollback overwrote another scope')
end)
Test('full sharing round trips direction and old or tracking packages preserve local direction',function()
    local h,S,F=Boot();assert(F:PersistHudArrangement({player={buffs='vertical'}}))
    local text=F:SerializeExport(F:ExportAll())
    assert(text:find('HUDARRANGE=player:buffs:vertical',1,true))
    local parsed=F:ParseImportText(text);assert(#parsed.errors==0,table.concat(parsed.errors,';'))
    assert(parsed.data.arrangement.player.buffs=='vertical')
    assert(not F:SerializeExport(F:ExportAll('tracking')):find('HUDARRANGE=',1,true))
    local old=text:gsub('\nHUDARRANGE=[^\n]+','')
    local legacy=F:ParseImportText(old);assert(F:ImportAll(legacy.data,'merge'))
    assert(F:GetScopeLayoutSettings('player').components.buffs.orientation=='vertical','old package reset direction')
end)
Test('bad direction or duplicate sharing rows fail before any writes',function()
    local h,S,F=Boot();local writes=h.io.writes
    local snapshot=F:GetHudCalibrationSnapshot();snapshot.target.components.cooldowns.orientation=false
    assert(F:PersistHudCalibrationSnapshot(snapshot)==false and h.io.writes==writes)
    local parsed=F:ParseImportText('VERSION=8\nFORMAT=replicatedsuite.buff_display.v3\nPLAYER_BUFF=1\nHUDARRANGE=player:buffs:vertical\nHUDARRANGE=player:buffs:horizontal')
    assert(#parsed.errors>0 and F:ImportAll(parsed.data,'merge')==false and h.io.writes==writes)
end)
Test('layout preset selection previews the whole HUD while keeping colors and the other scope',function()
    local h,S,F,P,C=Calibration();local writes=h.writes
    assert(C.layoutPreset,'HUD editor has no layout preset selector')
    local oldTarget=C.draft.target.components.buffs.x
    local menu=C.layoutPreset;assert(menu:Open())
    local button=menu.optionButtons[4];assert(button.events.OnClick(button,'LeftButton'))
    assert(C.allPreviewEnabled and C.draft.player.components.buffs.orientation=='vertical')
    assert(C.draft.target.components.buffs.x==oldTarget and h.writes==writes)
    assert(C:ApplyLayoutPreset('original'));assert(C.draft.player.components.buffs.orientation==nil)
    assert(C:Exit(false));assert(h.writes==writes)
end)
Test('grid wraps vertically with a real bounding box and preserves icon size',function()
    local _,_,F=Boot()
    local g=F.ComputeHudIconGrid(6,24,3,4,2,true,true)
    assert(g.count==6 and g.width==51 and g.height==105 and g.size==24)
    assert(g.slots[1].x==g.slots[2].x and g.slots[2].y-g.slots[1].y==27)
    assert(g.slots[5].x-g.slots[1].x==27 and g.slots[5].y==g.slots[1].y)
    assert(g.top==-81 and g.slots[4].y==81)
end)
Test('horizontal grids keep fixed columns and a shared left edge as content changes',function()
    local _,_,F=Boot()
    for _,count in ipairs({1,4,8,9,16})do
        local g=F.ComputeHudIconGrid(count,25,4,8,2,false,false)
        assert(g.width==228 and g.left==-114,'horizontal grid moved its left edge with icon count')
        assert(g.slots[1].x==0,'first column was centered inside the row')
        if count>8 then assert(g.slots[9].x==0 and g.slots[9].y==29,'partial last row left the matrix columns')end
    end
end)
Test('scoped calibration geometry carries the runtime equipment generation',function()
    local h,S,F=Boot()
    for _,version in ipairs({3,4})do
        F.State.settings.layoutPresetVersion=version
        assert(F:GetScopeLayoutSettings('player').layoutPresetVersion==version,'player preview lost equipment generation')
        assert(F:GetScopeLayoutSettings('target').layoutPresetVersion==version,'target preview lost equipment generation')
    end
end)
Test('matrix preset is selectable and keeps colors anchor and scope independent',function()
    local h,S,F,P,C=Calibration(true);local writes=h.writes
    C.draft.player.plate.x=37;C.draft.player.plate.width=161
    local otherX=C.draft.target.components.buffs.x
    assert(C:ApplyColorPatch({player={buffTime={0.21,0.41,0.61}}}))
    assert(C:ApplyLayoutPreset('matrix'))
    assert(C.draft.player.plate.x==37 and C.draft.player.plate.width==161)
    assert(C.draft.target.components.buffs.x==otherX and C.colorDraft.player.buffTime[1]==0.21)
    assert(C.allPreviewEnabled and C.layoutPresetSelections.player=='matrix')
    assert(C:Exit(true));assert(C:Open());assert(C.draft.player.components.castBar.width>161)
    assert(C.draft.player.components.buffs.orientation=='horizontal')
end)
Test('matrix slots align equipment columns and leave full status and cast regions clear',function()
    local h,S,F,P,C=Calibration()
    local plates={class={value='职业名称',icon='class.dds'},gearScore={value='123456'},distance={value='28.4m'}}
    for _,version in ipairs({3,4})do for _,scope in ipairs({'player','target'})do
        F.State.settings.layoutPresetVersion=version
        for _,scale in ipairs({0.5,1,1.25,2})do for _,width in ipairs({80,150,320})do
            local current=F:GetScopeLayoutSettings(scope);current.plateScale=scale;current.plate.width=width
            local profile=assert(F:GetHudLayoutPreset('matrix',scope,current))
            local a=profile.components.buffs;local n=a.maxPerRow*a.maxRows
            local L=P.ComputePlateLayout(0,0,profile,n,n,{mainHand=true,offHand=true,ranged=true,wings=true})
            local g=F.ComputeHudIconGrid(n,L.buff.size,L.buff.spacing,a.maxPerRow,a.maxRows,false,true)
            local left=math.floor(L.bar.centerX+g.left);local right=left+g.width
            local slots={};for _,group in ipairs({L.leftGroup,L.rightGroup})do for _,slot in ipairs(group.slots)do slots[slot.key]=slot end end
            assert(math.abs(slots.mainHand.x-left)<=1 and math.abs(slots.offHand.x-left)<=1,'left equipment column drifted')
            assert(math.abs(slots.ranged.x+slots.ranged.size-right)<=1 and math.abs(slots.wings.x+slots.wings.size-right)<=1,'right equipment column drifted')
            assert(slots.mainHand.y+slots.mainHand.size<=slots.offHand.y and slots.ranged.y+slots.ranged.size<=slots.wings.y,'equipment rows overlap')
            local debuffGrid=F.ComputeHudIconGrid(n,L.debuff.size,L.debuff.spacing,a.maxPerRow,a.maxRows,false,false)
            local debuffBottom=L.debuff.firstTop+debuffGrid.height
            local castTop=math.floor(L.cast.top+profile.components.castBar.y*scale)
            local castBottom=castTop+math.max(4,math.floor(profile.components.castBar.size*scale))+16
            assert(castTop>debuffBottom and L.bar.centerY+math.floor(profile.components.cooldowns.y*scale)>castBottom,'matrix status/cast/CD regions overlap')
            local info=P.ComputeInfoItemsLayout(plates,profile.info,profile.components,L.bar.centerX,L.info.top,L.info.font,scale,scope)
            local buffTop=L.buff.firstTop+g.top
            assert(info.iconY+info.iconSize<=math.min(info.gearScore.y,info.distance.y),'identity and numeric rows overlap')
            assert(info.gearScore.y+info.gearScore.height<buffTop and info.distance.y+info.distance.height<buffTop,'header overlaps full Buff rows')
        end end
    end end
end)
Test('matrix target name stays above identity at minimum and intermediate scales',function()
    local h,S,F,P,C=Calibration()
    for _,width in ipairs({80,150,320})do for step=50,200 do
        local current=F:GetScopeLayoutSettings('target');current.plateScale=step/100;current.plate.width=width
        local profile,alias=F:GetHudLayoutPreset('matrix','target',current)
        local L=P.ComputePlateLayout(0,0,profile,16,16,{})
        local info=P.ComputeInfoItemsLayout({class={value='职业名称',icon='class.dds'}},profile.info,profile.components,L.bar.centerX,L.info.top,L.info.font,step/100,'target')
        local name=P.ComputeTargetAliasLayout('目标名字',alias,L.bar.centerX,L.bar.centerY,step/100)
        assert(name.y+name.height<math.min(info.iconY,info.classText.y),'target name overlaps matrix identity at scale '..step/100)
    end end
end)
Test('matrix full sharing preserves equipment columns across layout generations',function()
    local function Positions(P,F,scope)
        local p=F:GetScopeSettingsProjection(scope);local L=P.ComputePlateLayout(0,0,p,16,16,{mainHand=true,offHand=true,ranged=true,wings=true})
        local out={};for _,g in ipairs({L.leftGroup,L.rightGroup})do for _,v in ipairs(g.slots)do out[v.key]=v.x end end
        return out
    end
    for _,versions in ipairs({{3,5},{5,3}})do
        local h,S,F,P=dofile('tools/rs_pvp_hud_test_host.lua')({runtimeHud=true})
        dofile('features/combat/buff_display/rs_buff_display_transfer_v2.lua');dofile('features/combat/buff_display/rs_buff_display_arrangement.lua')
        F.State.settings.layoutPresetVersion=versions[1];F:InvalidateSettingsCache()
        local snapshot=F:GetHudCalibrationSnapshot()
        for _,scope in ipairs({'player','target'})do snapshot[scope]=assert(F:GetHudLayoutPreset('matrix',scope,snapshot[scope]))end
        assert(F:PersistHudCalibrationSnapshot(snapshot));local expected={player=Positions(P,F,'player'),target=Positions(P,F,'target')}
        local text=F:SerializeExport(F:ExportAll())
        local h2,S2,F2,P2=dofile('tools/rs_pvp_hud_test_host.lua')({runtimeHud=true})
        dofile('features/combat/buff_display/rs_buff_display_transfer_v2.lua');dofile('features/combat/buff_display/rs_buff_display_arrangement.lua')
        F2.State.settings.layoutPresetVersion=versions[2];F2:InvalidateSettingsCache()
        local parsed=F2:ParseImportText(text);assert(#parsed.errors==0,table.concat(parsed.errors,';'));assert(F2:ImportAll(parsed.data,'merge'))
        for _,scope in ipairs({'player','target'})do for key,x in pairs(Positions(P2,F2,scope))do assert(x==expected[scope][key],'cross-generation matrix column moved: '..key)end end
        assert(F2.State.settings.layoutPresetVersion==versions[2],'import changed local equipment generation')
    end
end)
Test('wide matrix survives durable normalization within the component offset budget',function()
    local h,S,F,P,C=Calibration()
    F.State.settings.layoutPresetVersion=3
    for _,scale in ipairs({0.5,1,1.25,2})do
        local snapshot=F:GetHudCalibrationSnapshot();snapshot.player.plate.width=320;snapshot.player.plateScale=scale
        snapshot.player=assert(F:GetHudLayoutPreset('matrix','player',snapshot.player))
        local requested=snapshot.player.components.ranged.x
        assert(F:PersistHudCalibrationSnapshot(snapshot))
        assert(F:GetScopeLayoutSettings('player').components.ranged.x==requested,'wide matrix was clamped during save')
    end
end)
Test('bad or duplicate equipment generation metadata is rejected without writes',function()
    local h,S,F=Boot();local text=F:SerializeExport(F:ExportAll());local writes=h.io.writes
    for _,suffix in ipairs({'\nHUDORDER=99','\nHUDORDER=bad','\nHUDORDER=3\nHUDORDER=5'})do
        local parsed=F:ParseImportText(text..suffix)
        assert(#parsed.errors>0 and F:ImportAll(parsed.data,'merge')==false,'invalid equipment generation was accepted')
    end
    assert(h.io.writes==writes)
end)
Test('presets are detached geometry drafts and preserve anchor visibility and user colors',function()
    local h,S,F=Boot();local current=F:GetScopeLayoutSettings('player');local writes=h.io.writes
    current.plate.x=57;current.components.buffs.enabled=false;current.info.gearScoreFormat='compact'
    for _,name in ipairs({'classic','compact','balanced','vertical'})do
        local profile=assert(F:GetHudLayoutPreset(name,'player',current))
        assert(profile.plate.x==57 and profile.components.buffs.enabled==false and profile.info.gearScoreFormat=='compact')
        assert(profile~=current and profile.components~=current.components)
    end
    assert(F:GetHudLayoutPreset('vertical','player',current).components.debuffs.orientation=='vertical')
    assert(h.io.writes==writes,'browsing presets saved the draft')
end)
Test('classic preview separates Debuffs cast text and cooldowns throughout the HUD scale range',function()
    local h,S,F,P,C=Calibration();local writes=h.writes
    for _,scope in ipairs({'player','target'})do
        assert(C:SetScope(scope));assert(C:SetComponent('castBar'))
        for _,scale in ipairs({1,0.5,0.75,1.25,2})do
            C.draft[scope].plateScale=scale;assert(C:ApplyLayoutPreset('classic'))
            local cast=C.preview;local debuff=C.globalPreview.items.debuffs.preview
            local _,castY=h:World(cast.root);local _,debuffY=h:World(debuff.root)
            assert(castY>=debuffY+debuff.root.height+1,'classic preview cast overlaps Debuffs at '..scope..' scale '..scale)
            local cd=C.globalPreview.items.cooldowns.preview;local _,cdY=h:World(cd.root)
            local _,textY=h:World(cast.castText)
            assert(cdY>=textY+cast.castText.height+1,'classic preview cast text overlaps cooldowns at scale '..scale)
        end
    end
    assert(C:Exit(false));assert(h.writes==writes,'previewing the repaired preset wrote settings')
end)
Test('classic renderer reserves full Debuff capacity and cast text before cooldowns',function()
    local h,S,F,P=dofile('tools/rs_pvp_hud_test_host.lua')({runtimeHud=true})
    dofile('features/combat/buff_display/rs_buff_display_arrangement.lua');assert(F:EnsureStoreLoaded())
    for _,scope in ipairs({'player','target'})do for _,scale in ipairs({1,0.5,0.75,1.25,2})do
        local snapshot=F:GetHudCalibrationSnapshot();snapshot[scope].plateScale=scale
        local profile=assert(F:GetHudLayoutPreset('classic',scope,snapshot[scope]));snapshot[scope]=profile
        profile.components.buffs.enabled=false;profile.components.debuffs.enabled=true
        profile.components.castBar.enabled=true;profile.components.cooldowns.enabled=true
        assert(F:PersistHudCalibrationSnapshot(snapshot));F.State.settings.headShowAll=true;F:InvalidateSettingsCache()
        local lane=F.laneData[scope];local count=profile.components.debuffs.maxPerRow*profile.components.debuffs.maxRows
        lane.buffRows={};lane.debuffRows={};lane.cooldownRows={{id=9001,category='cooldown',iconPath='skill.dds',timeText='12'}}
        for i=1,count do lane.debuffRows[i]={id=i,category='debuff',iconPath='debuff.dds',timeText='12'}end
        lane.cast={casting=true,spellName='cast',currMs=400,totalMs=1000};P:VisualTick(true)
        local pool=P.pools[scope];local cast=pool.cast
        local debuffBottom=0
        for i=1,count do local icon=pool.icons[i].root;debuffBottom=math.max(debuffBottom,icon.y+icon.height)end
        assert(cast.root.y>=debuffBottom+1,'classic runtime cast overlaps full Debuff rows at '..scope..' scale '..scale)
        if scope=='player'then
            local cd=pool.icons[count+1].root
            assert(cd.y>=cast.root.y+cast.text.y+cast.text.height+1,'classic runtime cast text overlaps cooldowns at scale '..scale)
        end
    end end
end)
Test('runtime vertically stacks real Buff icons without moving fixed text slots',function()
    local h,S,F,P=dofile('tools/rs_pvp_hud_test_host.lua')({runtimeHud=true})
    dofile('features/combat/buff_display/rs_buff_display_arrangement.lua');assert(F:EnsureStoreLoaded())
    local snapshot=F:GetHudCalibrationSnapshot();local cfg=snapshot.player.components.buffs
    local before=P.ComputePlateLayout(0,0,snapshot.player,0,0,{})
    cfg.orientation='vertical';cfg.size=24;cfg.spacing=3;cfg.maxPerRow=4;cfg.maxRows=2
    assert(F:PersistHudCalibrationSnapshot(snapshot))
    F.State.settings.headShowAll=true;F:InvalidateSettingsCache()
    F.laneData.player.buffRows={}
    for i=1,6 do F.laneData.player.buffRows[i]={id=i,category='buff',iconPath='buff'..i..'.dds',stack=3,timeText='12'}end
    P:VisualTick(true)
    local icons=P.pools.player.icons
    assert(icons[1].root.x==icons[2].root.x,'runtime still draws horizontal icons; direction='..tostring(F:GetScopeSettingsProjection('player').components.buffs.orientation)..'; rows='..#F:GetPlatesProjection('player').buffs..'; positions='..icons[1].root.x..','..icons[2].root.x)
    assert(icons[2].root.y-icons[1].root.y==27)
    assert(icons[5].root.x-icons[1].root.x==27)
    local after=P.ComputePlateLayout(0,0,F:GetScopeLayoutSettings('player'),6,0,{})
    assert(after.info.top==before.info.top and after.cast.top==before.cast.top,'status direction moved fixed metadata slots')
end)
Test('Buff Debuff and cooldown runtime directions are independent and render without disk writes',function()
    local h,S,F,P=dofile('tools/rs_pvp_hud_test_host.lua')({runtimeHud=true})
    dofile('features/combat/buff_display/rs_buff_display_arrangement.lua');assert(F:EnsureStoreLoaded())
    local snapshot=F:GetHudCalibrationSnapshot()
    for _,key in ipairs({'buffs','debuffs','cooldowns'})do
        local cfg=snapshot.player.components[key]
        cfg.enabled=true;cfg.orientation=key=='debuffs'and 'horizontal'or 'vertical'
        cfg.size=24;cfg.spacing=3;cfg.maxPerRow=4;cfg.maxRows=2
    end
    assert(F:PersistHudCalibrationSnapshot(snapshot));F.State.settings.headShowAll=true;F:InvalidateSettingsCache()
    for _,kind in ipairs({'buff','debuff','cooldown'})do
        local rows={};for i=1,6 do rows[i]={id=i,category=kind,iconPath='test.dds',timeText='12'}end
        F.laneData.player[kind..'Rows']=rows
    end
    local writes=h.writes;P:VisualTick(true);local icons=P.pools.player.icons
    assert(icons[1].root.x==icons[2].root.x and icons[2].root.y-icons[1].root.y==27)
    assert(icons[7].root.y==icons[8].root.y and icons[8].root.x-icons[7].root.x==27)
    assert(icons[13].root.x==icons[14].root.x and icons[14].root.y-icons[13].root.y==27)
    for i=1,10 do P:VisualTick(true)end
    assert(h.writes==writes and F:GetScopeLayoutSettings('target').components.buffs.orientation==nil)
end)
Test('editor saves each group direction and exports the draft without premature writes',function()
    local h,S,F,P,C=Calibration();local writes=h.writes
    for _,key in ipairs({'buffs','debuffs','cooldowns'})do assert(C:SetComponent(key));assert(C:SetGroupOrientation('vertical'))end
    local text=table.concat(C:BuildTemplateSnapshotLines(),'\n')
    assert(text:find('|PLAYER|ARRANGE|buffs=vertical,debuffs=vertical,cooldowns=vertical',1,true)and h.writes==writes)
    assert(C:Exit(true));assert(C:Open())
    for _,key in ipairs({'buffs','debuffs','cooldowns'})do assert(C.draft.player.components[key].orientation=='vertical')end
    assert(C:Exit(false))
end)
Test('copying the original horizontal self HUD clears the target vertical direction explicitly',function()
    local h,S,F,P,C=Calibration();assert(C:Exit(false))
    assert(F:PersistHudArrangement({target={buffs='vertical'}}));assert(C:Open({scope='target'}))
    assert(C:SyncPlayerToTarget());assert(C:Exit(true))
    assert(F:GetScopeLayoutSettings('target').components.buffs.orientation==nil)
end)
Test('explicit reset and classic preset restore default horizontal without clearing other scopes',function()
    local h,S,F,P,C=Calibration();assert(C:SetGroupOrientation('vertical'));assert(C:Exit(true));assert(C:Open())
    assert(C:ResetCurrentComponent());assert(C:Exit(true))
    assert(F:GetScopeLayoutSettings('player').components.buffs.orientation==nil)
    assert(C:Open());assert(C:SetGroupOrientation('vertical'));assert(C:ApplyLayoutPreset('classic'));assert(C:Exit(true))
    assert(F:GetScopeLayoutSettings('player').components.buffs.orientation==nil)
end)
Test('save cancel and scope changes close the detached layout menu',function()
    local h,S,F,P,C=Calibration();local menu=C.layoutPreset
    assert(menu:Open());assert(C:Exit(false))
    assert(not menu.open and not menu.popup.shown and not menu.popup.pickable,'cancel left a detached layout menu')
    assert(C:Open());assert(menu:Open());assert(C:SetScope('target'))
    assert(not menu.open and not menu.popup.shown)
    assert(menu:Open());assert(C:Exit(true))
    assert(not menu.open and not menu.popup.shown and not menu.popup.pickable,'save left a detached layout menu')
end)
print(string.format('HUD LAYOUTS RESULT %d passed / %d failed',passed,failed))
assert(failed==0,'HUD layout regressions failed')
