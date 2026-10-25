-- Replicated Suite · Buff追踪交互测试
-- 作者：Replicated
-- QQ群：1104129461
-- Buff 追踪交互测试使用真实 Store、Commands 和投影，仅原生磁盘以内存替代。
local passed,failed=0,0
local function T(name,fn) local ok,err=pcall(fn);if ok then passed=passed+1;print('PASS buff-ux '..name) else failed=failed+1;print('FAIL buff-ux '..name..': '..tostring(err)) end end
local Boot=dofile('tools/rs_pvp_hud_test_host.lua')
local function Build()
    local h,S,F=Boot();assert(F:EnsureStoreLoaded())
    dofile('features/combat/buff_display/rs_buff_display_transfer_v2.lua')
    F.projections={player={{id=21,key='player:21',name='自己的状态',category='buff',stack=1,timeText='10'}},target={{id=82,key='target:82',name='目标的状态',category='debuff',timeText='5'}}}
    F.coverage={player={available=true},target={available=true}};F.revision=(F.revision or 0)+1
    S.FeatureRuntime.IsEnabled=function() return false end
    local ui=dofile('tools/rs_status_ui_test_host.lua')(S);local page=assert(ui:Build());assert(page:Refresh())
    return h,S,F,ui,page
end
local function Column(ui,tableId,id)
    for _,c in ipairs(assert(ui.widgets[tableId]).spec.columns) do if c.id==id then return c end end
    error('missing row action '..id)
end
T('scope switch retires all same-scope categories and preserves other scope / classification',function()
    local h,S,F=Boot();assert(F:EnsureStoreLoaded())
    assert(F:SetTrackedChannel(21,'player','buff',true));assert(F:SetTrackedChannel(21,'player','debuff',true));assert(F:SetTrackedChannel(21,'target','auto',true))
    assert(F:SetTrackedChannel(82,'player','buff',true));assert(F:SetClassification(21,'debuff'))
    assert(F.Commands:SetTrackedScope(21,'player',false))
    for _,cat in ipairs({'buff','debuff','auto'}) do assert(not F:IsTrackedChannel(21,'player',cat),'same-scope bucket survived '..cat) end
    assert(F:IsTrackedChannel(21,'target','auto') and F:IsTrackedId(82),'other selection lost')
    assert(F:GetClassification()[21]=='debuff','manual correction lost')
end)
T('independent scope adds preserve auto and explicit placement, no Native scan or repeat write',function()
    local h,S,F=Boot();assert(F:EnsureStoreLoaded());local scans=0
    S.Services.AuraObservationV3.GetSnapshot=function() scans=scans+1;return nil end
    assert(F.Commands:SetTrackedScope(21,'player',true));assert(F.Commands:SetTrackedScope(21,'target',true))
    assert(F:IsTrackedChannel(21,'player','auto') and F:IsTrackedChannel(21,'target','auto'))
    assert(F:SetTrackedChannel(82,'player','debuff',true));local writes=h.io.writes
    assert(F.Commands:SetTrackedScope(82,'player',true));assert(h.io.writes==writes,'idempotent add saved again')
    assert(F:IsTrackedChannel(82,'player','debuff') and not F:IsTrackedChannel(82,'player','auto'))
    assert(scans==0,'tracking action queried Native Aura')
end)
T('scope removal failure rolls back and reload reads last committed selection',function()
    local h,S,F=Boot();assert(F:EnsureStoreLoaded());assert(F.Commands:SetTrackedScope(21,'player',true));assert(F.Commands:SetTrackedScope(21,'target',true))
    local oldSave=S.Api.SaveData;S.Api.SaveData=function() return false,'forced failure' end
    local ok=F.Commands:SetTrackedScope(21,'player',false);assert(ok==false and F:IsTrackedId(21,nil,'player'),'failed save changed authority')
    S.Api.SaveData=oldSave;local _,_,fresh=Boot({disk=h.disk});assert(fresh:EnsureStoreLoaded());assert(fresh:IsTrackedId(21,nil,'player') and fresh:IsTrackedId(21,nil,'target'),'reload lost committed choice')
end)
T('default current list hides absent saved effects and tracked source cancels every placement',function()
    local h,S,F,ui,page=Build();assert(F:SetTrackedId(123,'auto',true));page:Refresh()
    assert(page.managementView=='live' and #ui.widgets.v3_buff_display_tracking_table.items==2,'saved catalog crowds first entry')
    assert(ui.widgets.v3_buff_manage_view.spec.set('tracked'))
    local rows=ui.widgets.v3_buff_display_tracking_table.items;assert(#rows==1 and rows[1].id==123,'inactive saved effect missing')
    for _,id in ipairs({'player_buff','player_debuff','target_buff','target_debuff'})do assert(Column(ui,'v3_buff_display_tracking_table',id).onClick(rows[1]))end
    assert(not F:IsTrackedId(123) and #ui.widgets.v3_buff_display_tracking_table.items==0)
    local _,_,fresh=Boot({disk=h.disk});assert(fresh:EnsureStoreLoaded());assert(not fresh:IsTrackedId(123),'cancel resurrected after reload')
end)
T('single source list has independent four-column actions and name ID search',function()
    local h,S,F,ui,page=Build();local src=ui.widgets.v3_buff_manage_view;local query=ui.widgets.v3_buff_display_track_search
    local tab=ui.widgets.v3_buff_display_tracking_table;assert(#tab.items==2 and tab.items[1].id==21)
    local own=Column(ui,tab.id,'player_buff');local target=Column(ui,tab.id,'target_buff')
    assert(own.onClick(tab.items[1]));assert(F:IsTrackedPlacement(21,'player','buff') and not F:IsTrackedPlacement(21,'target','buff'))
    assert(target.onClick(tab.items[1]));assert(own.onClick(tab.items[1]));assert(not F:IsTrackedPlacement(21,'player','buff') and F:IsTrackedPlacement(21,'target','buff'))
    assert(query.spec.onSubmit('目标'));assert(#tab.items==1 and tab.items[1].id==82)
    assert(query.spec.onSubmit('不存在'));assert(#tab.items==0 and tab.viewState=='empty')
    assert(query.spec.onSubmit(''));assert(src.spec.set('library'));tab=ui.widgets.v3_buff_library_table;query=ui.widgets.v3_buff_library_search;assert(#tab.items>100,'catalog missing')
    assert(query.spec.onSubmit(tostring(tab.items[1].id)));assert(#tab.items>=1,'ID search lost match')
end)
T('tracking surface has one entry with four columns and no selected-row advanced controls',function()
    local h,S,F,ui,page=Build();local tabs=ui.widgets.v3_buff_display_tabs.spec.items
    assert(#tabs==4 and tabs[1].text=='状态追踪')
    assert(ui.widgets.v3_buff_tracking_advanced==nil and ui.widgets.v3_buff_add_source==nil,'duplicate controls remain')
    for _,id in ipairs({'player_buff','player_debuff','target_buff','target_debuff'})do assert(Column(ui,'v3_buff_display_tracking_table',id).cellType=='button')end
    assert(F:SetClassification(21,'debuff') and F:GetClassification()[21]=='debuff','classification authority lost')
end)
T('row toggle uses supplied identity without selected-row dependency',function()
    local h,S,F,ui,page=Build();assert(F:SetTrackedPlacement(21,'player','buff',true));assert(F:SetTrackedPlacement(82,'player','buff',true));page:Refresh()
    local action=Column(ui,'v3_buff_display_tracking_table','player_buff');page.selectedManagementRow={id=82,kind='effect'}
    assert(action.onClick({id=21,kind='effect'}));assert(not F:IsTrackedPlacement(21,'player','buff') and F:IsTrackedPlacement(82,'player','buff'))
    assert(action.onClick({id=99003,kind='skill'})==false,'Buff action accepted CD namespace')
end)
T('empty unavailable current and record sources are explained without writes',function()
    local h,S,F,ui,page=Build();F.projections={player={},target={}};F.coverage={};F.revision=F.revision+1
    local writes=h.io.writes;page:Refresh();assert(ui.widgets.v3_buff_display_tracking_table.viewState=='unavailable')
    page:Refresh();assert(h.io.writes==writes,'refresh saved config')
    assert(ui.widgets.v3_buff_manage_view.spec.set('frozen'));assert(ui.widgets.v3_buff_display_tracking_table.viewDetail.message:find('记录',1,true))
end)
T('recorded vanished states remain addable and search preserves capture',function()
    local h,S,F,ui,page=Build();F.managementFreeze.active=true;F.managementFreeze.revision=F.managementFreeze.revision+1
    F.managementFreeze.rows={player={{id=123,key='player:123',name='已消失的短状态',category='debuff',timeText='已消失',frozen=true}},target={}}
    assert(ui.widgets.v3_buff_manage_view.spec.set('frozen'));local tab=ui.widgets.v3_buff_display_tracking_table;assert(#tab.items==1 and tab.items[1].id==123)
    local writes=h.io.writes;assert(ui.widgets.v3_buff_display_track_search.spec.onSubmit('短状态'));assert(h.io.writes==writes)
    assert(Column(ui,tab.id,'player_debuff').onClick(tab.items[1]));assert(F:IsTrackedPlacement(123,'player','debuff'))
    assert(F.managementFreeze.active and #F.managementFreeze.rows.player==1,'adding changed captured facts')
    F.managementFreeze.overflow=true;F.managementFreeze.revision=F.managementFreeze.revision+1;page:Refresh()
    assert(ui.widgets.v3_buff_record_hint.text:find('上限',1,true) and ui.widgets.v3_buff_record_hint.text:find('未记录',1,true))
end)
T('scope validation capacity rejection and all-scope cancel failure preserve data',function()
    local h,S,F=Boot();assert(F:EnsureStoreLoaded())
    for _,id in ipairs({0,-1,1.5,2147483648}) do assert(F.Commands:SetTrackedScope(id,'player',true)==false) end
    assert(F.Commands:SetTrackedScope(21,'team',true)==false)
    assert(F.Commands:SetTrackedScope(21,'target',true));assert(F.Commands:SetTrackedScope(21,'player',true))
    local before=h.io.writes;local save=S.Api.SaveData;S.Api.SaveData=function()return false,'blocked disk' end
    assert(F.Commands:RemoveTrackedEffect(21)==false);assert(F:IsTrackedId(21,nil,'player') and F:IsTrackedId(21,nil,'target'))
    S.Api.SaveData=save
    for i=1,1024 do F.State.settings.tracked.player.auto[i]=i+1000 end -- 输入控件测试替身保留容量上限。
    assert(F.Commands:SetTrackedScope(99999,'player',true)==false,'capacity was silently truncated')
    assert(not F:IsTrackedId(99999) and F:IsTrackedId(21,nil,'target'))
end)
T('CD mode has one local toggle with real time and visible ID without Buff actions',function()
    local h,S,F,ui,page=Build()
    S.Services.CooldownObservationV3={GetHealth=function()return {revision=1}end,GetTrackedRows=function()return {{id=99001,kind='skill',name='冷却技能',timeText='12.3s',timeLeft=12.3,tracked=true}}end}
    assert(F:SetTrackedCooldownId(99001,'skill',true));page.managementView='cooldowns';page:Refresh()
    local view=ui.widgets.v3_buff_cooldown_table;assert(view.visible and not ui.widgets.v3_buff_display_tracking_table.visible)
    assert(Column(ui,view.id,'time').getText(view.items[1])=='12.3s' and view.items[1].timeText=='12.3s')
    assert(Column(ui,view.id,'id').field=='id' and view.items[1].id==99001)
    assert(Column(ui,view.id,'player_cd').getTone(view.items[1])=='green');assert(Column(ui,view.id,'target_cd').onClick(view.items[1])==false)
    assert(view.spec.onItemActivated(view.items[1]) and page.selectedManagementRow.id==99001)
end)
T('metadata completion does not reorder default visible library rows into a scan cascade',function()
    local h,S,F,ui,page=Build();local cached,revision={},0
    S.Services.BuffMetadataV3={GetCached=function(_,id)return cached[id]end,GetRevision=function()return revision end}
    page.librarySource='library';page:SwitchTab('library');local view=ui.widgets.v3_buff_library_table
    local firstId=view.items[1].id;cached[firstId]={name='zzzz last localized name',iconPath='resolved.dds'};revision=revision+1
    page:RefreshLibrary();assert(view.items[1].id==firstId,'metadata resolution reordered visible catalog / admitted fresh IDs')
    assert(view.items[1].name=='zzzz last localized name' and view.items[1].iconPath=='resolved.dds','stable order skipped resolved metadata')
end)
local function BuildReal()
    local h,S,F=Boot({runtimeHud=true,noRenderer=true})
    for _,file in ipairs({'data/rs_skill_effects.lua','data/rs_combat_ability_catalog.lua','data/ids/rs_buff_ids.lua','data/rs_status_tracking_catalog.lua','features/combat/buff_display/rs_buff_display_management.lua','features/combat/buff_display/rs_buff_display_transfer_v2.lua','ui/framework/rs_ui_forms.lua'}) do dofile(file) end
    S.UIV3.WidgetHost={IsVisible=function()return false end,SetVisible=function()return true end}
    S.UI.CreateMultiEditBox=function()return nil end -- 可选原生导出编辑器不属于本次测试界面。
    dofile('presentation/v3/pages/rs_v3_buff_display_page.lua')
    local parent=h.Native(nil,'buff-ux-parent',0,0,640,560)
    local page=assert(S.UIV3.PageHost.factories['combat.buff_display'](parent,'combat.buff_display'))
    local widgets={};local function Index(n)widgets[n.id]=n;for _,child in ipairs(n.children or {})do Index(child)end end;Index(page)
    assert(F.Commands:SetTrackedScope(21,'player',true));assert(F.Commands:SetTrackedScope(82,'target',true));assert(page:Refresh())
    -- 使用真实布局事务；反复直接 Layout 而不排空队列，会把测试中的未清理失效标记合并到已布局根节点，偏离生产刷新生命周期。
    local function Layout(w,ht)
        parent:SetExtent(w,ht);page:SetBounds(0,0,w,ht);page:InvalidateMeasure('test_viewport');S.RSUI:FlushLayoutQueue(32)
        assert(S.RSUI:GetLayoutQueueSnapshot().pending==0,'layout queue did not stabilize')
    end
    return h,S,F,page,widgets,Layout
end
T('real RSUI compact sources retain columns and controls at 560 and 800 widths',function()
    local h,S,F,page,widgets,Layout=BuildReal()
    for _,size in ipairs({{560,460},{800,650}})do
        for _,source in ipairs({'tracked','library','cooldowns','live'})do
            assert(widgets.v3_buff_manage_view.spec.set(source));Layout(size[1],size[2])
            local view=source=='library' and widgets.v3_buff_library_table or source=='cooldowns' and widgets.v3_buff_cooldown_table or widgets.v3_buff_display_tracking_table
            assert(view.height>=120,'table crowded by controls')
            for _,c in ipairs(view:GetResolvedColumns())do if c.cellType=='button' then assert(c.width>=56,'toggle column clipped')end end
            local controlIds=source=='library' and {'v3_buff_library_pack','v3_buff_library_import','v3_buff_library_search_clear'} or {'v3_buff_manage_view','v3_buff_display_track_search_clear'}
            for _,id in ipairs(controlIds)do local ok,why=h:VisibleRect(widgets[id]);assert(ok,why)end
            if source=='library' then assert(h:VisibleRect(widgets.v3_buff_library_pack))elseif source=='cooldowns' then assert(h:VisibleRect(widgets.v3_buff_cooldown_add))end
        end
    end
end)
T('real pooled row toggles once for current binding after another row is removed',function()
    local h,S,F,page,widgets,Layout=BuildReal()
    assert(F.Commands:RemoveTrackedEffect(21));assert(F.Commands:RemoveTrackedEffect(82))
    assert(F:SetTrackedPlacement(21,'player','buff',true));assert(F:SetTrackedPlacement(82,'player','buff',true))
    assert(widgets.v3_buff_manage_view.spec.set('tracked'));Layout(640,560)
    local view=widgets.v3_buff_display_tracking_table;local slot=assert(view.list.pool[1]);local originalId=slot.row.item.id
    local button=slot.row.cells[5];local writes=h.writes;assert(button.root.events.OnClick(button.root,'LeftButton'));assert(h.writes==writes+4,'duplicate Native click transaction')
    assert(not F:IsTrackedId(originalId));assert(F:SetTrackedPlacement(123,'player','buff',true));assert(page:Refresh());Layout(640,560)
    local nextId=slot.row.item.id;assert(nextId~=originalId and F:IsTrackedId(nextId))
    assert(button.root.events.OnClick(button.root,'LeftButton'));assert(not F:IsTrackedId(nextId),'reused cell changed old ID')
    Layout(640,560);assert(button.root.events.OnClick(button.root,'LeftButton')==false,'retired row accepted click')
end)
T('freezing current rows survives aura churn while tracking remains live and performs no scan or save',function()
    local h,S,F,ui,page=Build();F.enabled=true;S.FeatureRuntime.IsEnabled=function()return true end;page:Refresh()
    local freeze=assert(ui.widgets.v3_buff_display_track_freeze,'current-list freeze entry missing')
    local reads,writes=0,h.io.writes;S.Services.AuraObservationV3.GetSnapshot=function()reads=reads+1;return nil end
    assert(freeze.onClick());assert(F:GetManagementListFreezeState().active)
    local tableView=ui.widgets.v3_buff_display_tracking_table
    F.projections={player={{id=9001,key='player:9001',name='随后状态',category='buff',timeText='1'}},target={}};F.revision=F.revision+1
    F:ObserveManagementRows('player',F.projections.player,{available=true,complete=true,reliable=true},120)
    F:ObserveManagementRows('target',{}, {available=true,complete=true,reliable=true},120)
    assert(page:Refresh());assert(#tableView.items==3 and tableView.items[1].id==21 and tableView.items[3].id==9001,'freeze stopped admitting new Buffs or removed old rows')
    local live=F:GetProjection('player');assert(live[1].id==9001,'HUD facts were frozen with management list')
    assert(reads==0 and h.io.writes==writes,'presentation freeze crossed Native or permanent Store')
    assert(Column(ui,tableView.id,'player_buff').onClick(tableView.items[1]));assert(F:IsTrackedPlacement(21,'player','buff'))
    assert(#tableView.items==3 and Column(ui,tableView.id,'player_buff').getText(tableView.items[1])=='追踪')
    assert(freeze.onClick());assert(not F:GetManagementListFreezeState().active)
    assert(#tableView.items==1 and tableView.items[1].id==9001,'unfreeze did not return to current facts')
end)
T('current freeze is shared by compact and floating projections and clears on feature lifecycle cleanup',function()
    local h,S,F,ui,page=Build();F.enabled=true
    assert(F.Commands:SetManagementListFrozen(true))
    F.projections={player={},target={}};F.revision=F.revision+1
    local rows=F:GetManagementProjection({view='live',cacheOwner='widget',preserveLive=true,sort='id'})
    assert(#rows==2 and rows[1].id==21,'floating view did not use same frozen snapshot')
    assert(F:ClearFrozenRows());assert(F:GetManagementListFreezeState().active,'stopping retention cleared independent list freeze')
    assert(F:Disable());assert(not F:GetManagementListFreezeState().active)
    rows=F:GetManagementProjection({view='live',compact=true,preserveLive=true,sort='id'});assert(#rows==0)
end)
T('floating freeze action uses real shared projection and keeps narrow actions visible',function()
    local h,S,F,page,widgets,Layout=BuildReal()
    F.projections={player={{id=21,key='player:21',name='自己的状态',category='buff',timeText='10'},{id=82,key='player:82',name='第二状态',category='buff',timeText='4'}},target={}}
    F.coverage={player={available=true},target={available=true}};F.revision=F.revision+1
    local R=S.RSUI;local spec
    S.UIV3.WidgetHost.Register=function(_,_,value)spec=value;return true end
    S.UIV3.WidgetHost.BindFeatureLifecycle=function()return true end
    local parent=h.Native(nil,'buff-freeze-widget-parent',0,0,330,270)
    local body=assert(R:VerticalBox({id='buff-freeze-widget-root',parent=parent}))
    R.FloatingSurface.Create=function()
        return {shell={root=body},GetContentRoot=function()return body end,SetStatus=function(self,text)self.status=text;return true end}
    end
    dofile('presentation/v3/widgets/rs_v3_buff_display_widget.lua');local instance=assert(spec.create())
    assert(instance:Refresh());assert(instance.listFreezeButton,'floating current freeze missing')
    assert(instance.listFreezeButton.onClick());assert(F:GetManagementListFreezeState().active)
    F.projections.player={};F.revision=F.revision+1;assert(instance:Refresh());assert(#instance.rows==2)
    assert(instance.table.spec.onItemActivated(instance.rows[2]));assert(instance.channelButtons.v3_buff_widget_player_buff.onClick())
    assert(instance.rows[1].id==21 and instance.rows[2].id==82,'tracking reordered frozen list')
    body:SetBounds(0,0,330,270);body:InvalidateMeasure('test_widget');R:FlushLayoutQueue(64)
    assert(h:VisibleRect(instance.listFreezeButton));assert(h:VisibleRect(instance.captureButton))
    assert(instance.listFreezeButton.onClick());assert(not F:GetManagementListFreezeState().active and #instance.rows==0)
end)
T('frozen list admits later short Buffs through real aura refresh and keeps expired rows in place',function()
    local h,S,F=Boot({runtimeHud=true,noRenderer=true})
    for _,file in ipairs({'data/rs_skill_effects.lua','data/rs_combat_ability_catalog.lua','data/ids/rs_buff_ids.lua','data/rs_status_tracking_catalog.lua','features/combat/buff_display/rs_buff_display_management.lua'})do dofile(file)end
    h.facts.player[82]=h:Fact(82);assert(F:RefreshScope('player'));assert(F.Commands:SetManagementListFrozen(true))
    h.facts.player={};h.facts.player[21]=h:Fact(21);assert(F:RefreshScope('player',true))
    local rows=F:GetManagementProjection({view='live',preserveLive=true,sort='tracked'})
    assert(#rows==2 and rows[1].id==82 and rows[2].id==21,'new lower ID was dropped or moved the existing selection')
    assert(#F.laneData.player.buffRows==1 and F.laneData.player.buffRows[1].id==21,'expired Buff leaked into live HUD')
    h.facts.player={};assert(F:RefreshScope('player',true))
    local retained=F:GetManagementProjection({view='live',preserveLive=true,query='21'})
    assert(#retained==1 and retained[1].id==21,'new Buff was removed after expiring')
    assert(F.Commands:SetTrackedPlacement(21,'player','buff',true));assert(F:IsTrackedPlacement(21,'player','buff'))
    assert(F.Commands:SetTrackedPlacement(21,'player','buff',false))
    rows=F:GetManagementProjection({view='live',preserveLive=true})
    assert(#rows==2 and rows[1].id==82 and rows[2].id==21,'tracking clicks reordered or removed frozen observations')
    assert(F.Commands:SetManagementListFrozen(false));assert(#F:GetManagementProjection({view='live',preserveLive=true})==0)
end)
T('frozen compact rows keep first observation order when the same ID appears in another scope',function()
    local h,S,F,ui,page=Build();F.enabled=true
    F.projections={player={{id=100,key='player:100',name='100',category='buff'}},target={{id=21,key='target:21',name='21',category='buff'}}}
    assert(F.Commands:SetManagementListFrozen(true))
    F:ObserveManagementRows('player',{{id=21,key='player:21',name='21',category='buff'}},{available=true,complete=true,reliable=true},120)
    local rows=F:GetManagementProjection({view='live',preserveLive=true,compact=true})
    assert(#rows==2 and rows[1].id==21 and rows[2].id==100,'compact merge reordered earlier target observation')
    local both=F:GetManagementProjection({view='live',preserveLive=true,scope='player'})
    assert(#both==2 and both[1].id==100 and both[2].id==21,'new scope evidence was dropped or inserted before an existing row')
end)
T('list freeze alone catches event-edge short Buffs with HUD categories hidden and stops on disable',function()
    local h,S,F=Boot({runtimeHud=true,noRenderer=true})
    for _,file in ipairs({'data/rs_skill_effects.lua','data/rs_combat_ability_catalog.lua','data/ids/rs_buff_ids.lua','data/rs_status_tracking_catalog.lua','features/combat/buff_display/rs_buff_display_management.lua'})do dofile(file)end
    F.State.settings.showBuffs=false;F.State.settings.showDebuffs=false;F.State.settings.headEnabled=false;F:InvalidateSettingsCache()
    assert(F.Commands:SetManagementListFrozen(true));assert(not F:GetManagementFreezeState().active)
    h.facts.player[77]=h:Fact(77);h:Event('BUFF_UPDATE');h.facts.player={};h:Event('BUFF_UPDATE')
    local rows=F:GetManagementProjection({view='live',preserveLive=true})
    assert(#rows==1 and rows[1].id==77,'short Buff was gone before list freeze observed it')
    assert(h.lastAuraForce==true and #F.laneData.player.buffRows==0)
    assert(F:Disable());local scans=h.scans;h:Event('BUFF_UPDATE')
    assert(h.scans==scans and not F:GetManagementListFreezeState().active,'disabled feature kept collecting frozen rows')
end)
T('list freeze deduplicates repeated Buffs and reports bounded overflow without discarding earlier choices',function()
    local h,S,F,ui,page=Build();F.enabled=true;assert(F.Commands:SetManagementListFrozen(true));local writes=h.io.writes
    local input={};for id=1000,2100 do input[#input+1]={id=id,key='player:'..id,name=tostring(id),category='buff'}end
    F:ObserveManagementRows('player',input,{available=true,complete=true,reliable=true},120)
    local rows=F:GetManagementProjection({view='live',scope='player',preserveLive=true})
    assert(#rows==1024 and rows[1].id==21 and rows[2].id==1000,'overflow replaced earlier rows')
    local state=F:GetManagementListFreezeState();assert(state.overflow and state.capacityPerScope==1024)
    F:ObserveManagementRows('player',input,{available=true,complete=true,reliable=true},240)
    rows=F:GetManagementProjection({view='live',scope='player',preserveLive=true});assert(#rows==1024,'duplicate observations grew the list')
    F:ObserveManagementRows('player',nil,{available=false,complete=false,reliable=false},nil)
    assert(#F:GetManagementProjection({view='live',scope='player',preserveLive=true})==1024,'read failure removed frozen rows')
    assert(h.io.writes==writes,'observations were persisted')
    assert(F.Commands:SetManagementListFrozen(false));assert(F:GetManagementListFreezeState().count==0)
end)
print(('BUFF_TRACKING_UX_RESULT passed=%d failed=%d'):format(passed,failed));if failed>0 then error('Buff tracking UX tests failed') end
