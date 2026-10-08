-- Compact tracking grid: real Store/Feature/Projection, RAM Native disk; not RU live acceptance.
local passed,failed=0,0
local function T(name,fn)local ok,e=xpcall(fn,debug.traceback);if ok then passed=passed+1;print('PASS tracking-grid '..name)else failed=failed+1;print('FAIL tracking-grid '..name..': '..tostring(e))end end
local Boot=dofile('tools/rs_pvp_hud_test_host.lua')
local function Build()
    local h,S,F=Boot();assert(F:EnsureStoreLoaded());dofile('features/combat/buff_display/rs_buff_display_transfer_v2.lua')
    F.projections={player={{id=21,key='player:21',name='自己状态',category='buff',timeText='10'}},target={{id=82,key='target:82',name='目标状态',category='debuff',timeText='5'}}}
    F.coverage={player={available=true},target={available=true}};F.revision=F.revision+1
    S.FeatureRuntime.IsEnabled=function()return false end
    local ui=dofile('tools/rs_status_ui_test_host.lua')(S);local page=assert(ui:Build());assert(page:Refresh())
    return h,S,F,ui,page
end
local function Col(ui,tableId,id)
    for _,c in ipairs(assert(ui.widgets[tableId]).spec.columns)do if c.id==id then return c end end
    error('missing column '..id)
end
T('first entry shows current own and target only despite 400 saved states',function()
    local h,S,F,ui,page=Build()
    for id=1000,1399 do F.State.settings.tracked.player.auto[#F.State.settings.tracked.player.auto+1]=id end
    F:InvalidateSettingsCache();page:Refresh()
    assert(page.managementView=='live','default opens the full saved catalog')
    local rows=ui.widgets.v3_buff_display_tracking_table.items
    assert(#rows==2 and rows[1].id==21 and rows[2].id==82,'unrelated saved states appear in current list')
    local tabs=ui.widgets.v3_buff_display_tabs.spec.items
    assert(#tabs==4 and tabs[1].text=='状态追踪' and tabs[4].value=='library','duplicate adding/tracked tab entry remains')
    assert(ui.widgets.v3_buff_manage_view.spec.set('tracked'));assert(#ui.widgets.v3_buff_display_tracking_table.items==400)
end)
T('four red green row toggles are independent persist and use bound row identity',function()
    local h,S,F,ui,page=Build();local tableId='v3_buff_display_tracking_table';local row=ui.widgets[tableId].items[1]
    local ownBuff=Col(ui,tableId,'player_buff');local ownDebuff=Col(ui,tableId,'player_debuff')
    local targetBuff=Col(ui,tableId,'target_buff');local targetDebuff=Col(ui,tableId,'target_debuff')
    assert(ownBuff.getTone(row)=='red');assert(ownBuff.onClick(row));assert(ownBuff.getTone(row)=='green')
    assert(ownDebuff.onClick(row) and targetBuff.onClick(row) and targetDebuff.onClick(row))
    page.selectedManagementRow={id=82,kind='effect'};assert(ownBuff.onClick(row))
    assert(not F:IsTrackedPlacement(21,'player','buff') and F:IsTrackedPlacement(21,'player','debuff')
        and F:IsTrackedPlacement(21,'target','buff') and F:IsTrackedPlacement(21,'target','debuff'),'other columns were changed')
    local _,_,cold=Boot({disk=h.disk});assert(cold:EnsureStoreLoaded())
    assert(not cold:IsTrackedPlacement(21,'player','buff') and cold:IsTrackedPlacement(21,'player','debuff'),'reload loses column selection')
end)
T('legacy auto cancellation preserves the other three visible selections and classification',function()
    local h,S,F=Boot();assert(F:EnsureStoreLoaded());assert(F:SetTrackedScope(21,'player',true));assert(F:SetTrackedScope(21,'target',true))
    assert(F:SetClassification(21,'debuff'));assert(F:IsTrackedPlacement(21,'player','buff'))
    assert(F.Commands:SetTrackedPlacement(21,'player','buff',false))
    assert(not F:IsTrackedPlacement(21,'player','buff') and F:IsTrackedPlacement(21,'player','debuff'))
    assert(F:IsTrackedPlacement(21,'target','buff') and F:IsTrackedPlacement(21,'target','debuff'))
    assert(F:GetClassification()[21]=='debuff','placement changes metadata')
    local writes=h.io.writes;assert(F.Commands:SetTrackedPlacement(21,'player','buff',false));assert(h.io.writes==writes,'idempotent state writes again')
end)
T('failed save retains green committed state and cancellation can be retried',function()
    local h,S,F,ui,page=Build();local col=Col(ui,'v3_buff_display_tracking_table','player_buff');local row=ui.widgets.v3_buff_display_tracking_table.items[1]
    assert(col.onClick(row));local old=S.Api.SaveData;S.Api.SaveData=function()return false,'test_failed_save'end
    assert(col.onClick(row)==false and col.getTone(row)=='green','failed write appeared red')
    S.Api.SaveData=old;assert(col.onClick(row) and col.getTone(row)=='red')
end)
T('same effect is one row with separate current remaining times and live never becomes retained',function()
    local h,S,F,ui,page=Build()
    F.projections.target={{id=21,key='target:21',name='自己状态',category='debuff',timeText='5'}};F.revision=F.revision+1
    F.managementFreeze.active=true;F.managementFreeze.rows={player={{id=123,key='player:123',name='消失状态',category='buff'}},target={}}
    page:Refresh();local rows=ui.widgets.v3_buff_display_tracking_table.items
    assert(#rows==1 and rows[1].id==21 and rows[1].timeText:find('10',1,true) and rows[1].timeText:find('5',1,true),'source facts lost or duplicated')
    F.projections.target={};F.revision=F.revision+1;page:Refresh();assert(not ui.widgets.v3_buff_display_tracking_table.items[1].timeText:find('目',1,true),'previous target time leaked')
    assert(ui.widgets.v3_buff_manage_view.spec.set('frozen'));assert(ui.widgets.v3_buff_display_tracking_table.items[1].id==123,'recorded source lost')
end)
T('library is a separate tab with the same four columns and refresh never writes',function()
    local h,S,F,ui,page=Build();assert(ui.widgets.v3_buff_manage_view.spec.set('library'))
    local tab=ui.widgets.v3_buff_library_table;assert(#tab.items>100)
    assert(Col(ui,tab.id,'target_debuff').cellType=='button');local writes=h.io.writes
    assert(page:Refresh());assert(h.io.writes==writes,'source viewing writes tracking')
    assert(ui.widgets.v3_buff_library_search.spec.onSubmit(tostring(tab.items[1].id)));assert(#tab.items>=1,'ID search lost')
end)
T('one CD toggle clears both old routes and target never mirrors local timer',function()
    local h,S,F,ui,page=Build();assert(F:SetTrackedCooldownId(37172,'mate',true))
    S.Services.CooldownObservationV3={GetHealth=function()return {revision=1}end,GetTrackedRows=function()return {
        {id=37172,kind='skill',source='skill',name='技能',remainingMs=13000,timeText='13',active=true},
        {id=37172,kind='mate',source='mate',name='技能',nativeStatus='unknown',timeText='Native 未读取'},
    }end}
    assert(ui.widgets.v3_buff_manage_view.spec.set('cooldowns'));local rows=ui.widgets.v3_buff_cooldown_table.items
    assert(#rows==1 and rows[1].timeText=='13','CD source split or lost positive Native fact')
    local own=Col(ui,'v3_buff_cooldown_table','player_cd');local target=Col(ui,'v3_buff_cooldown_table','target_cd')
    assert(own.getTone(rows[1])=='green' and own.onClick(rows[1]))
    assert(not F:IsTrackedCooldownId(37172,'skill') and not F:IsTrackedCooldownId(37172,'mate'),'cancel left one hidden route')
    assert(own.getTone(rows[1])=='red' and own.onClick(rows[1]))
    assert(F:IsUnifiedCooldownTracked(37172),'unified CD did not save')
    local writes=h.io.writes;assert(target.onClick(rows[1])==false and h.io.writes==writes,'unsupported target CD writes or mirrors local')
end)
local function RealPage()
    local h,S,F=Boot({runtimeHud=true,noRenderer=true})
    for _,file in ipairs({'data/rs_skill_effects.lua','data/rs_combat_ability_catalog.lua','data/ids/rs_buff_ids.lua','data/rs_status_tracking_catalog.lua','features/combat/buff_display/rs_buff_display_management.lua','features/combat/buff_display/rs_buff_display_transfer_v2.lua','ui/framework/rs_ui_forms.lua'})do dofile(file)end
    S.UIV3.WidgetHost={IsVisible=function()return false end,SetVisible=function()return true end};S.UI.CreateMultiEditBox=function()return nil end
    S.UI.SetButtonStatusTone=function(_,widget,tone)widget.testStatusTone=tone;return true end -- Native 着色提交模型。
    dofile('presentation/v3/pages/rs_v3_buff_display_page.lua')
    local parent=h.Native(nil,'tracking-grid-parent',0,0,640,560)
    local page=assert(S.UIV3.PageHost.factories['combat.buff_display'](parent,'combat.buff_display'))
    F.projections={player={{id=21,key='player:21',name='测试长名称和俄语：Очень длинное имя эффекта',category='buff',timeText='123.4'}},target={{id=82,key='target:82',name='目标状态',category='debuff',timeText='5'}}};F.revision=F.revision+1;assert(page:Refresh())
    local widgets={};local function Index(n)widgets[n.id]=n;for _,child in ipairs(n.children or {})do Index(child)end end;Index(page)
    local function Layout(w,ht)
        parent:SetExtent(w,ht);page:SetBounds(0,0,w,ht);page:InvalidateMeasure('test_viewport');S.RSUI:FlushLayoutQueue(32)
        assert(S.RSUI:GetLayoutQueueSnapshot().pending==0,'layout queue did not converge')
    end
    return h,S,F,page,widgets,Layout
end
T('real compact grid retains table and all columns at 560 and 800 widths through source switches',function()
    local h,S,F,page,widgets,Layout=RealPage()
    for _,size in ipairs({{560,460},{800,650}})do
        for _,source in ipairs({'live','library','tracked','frozen','cooldowns','live'})do
            assert(widgets.v3_buff_manage_view.spec.set(source));Layout(size[1],size[2])
            local tableView=source=='library' and widgets.v3_buff_library_table or source=='cooldowns' and widgets.v3_buff_cooldown_table or widgets.v3_buff_display_tracking_table
            assert(tableView.height>=120,'compact toolbar still crowds the table: '..source..' '..tableView.height)
            local total=0;for _,c in ipairs(tableView:GetResolvedColumns())do total=total+c.width;if c.id:find('_buff') or c.id:find('_debuff')then assert(c.width>=56,'channel column clipped '..source..' table='..tableView.width..' column='..c.width)end end
            assert(total<=tableView.width,'columns escape narrow viewport')
            if source=='library' then
                assert(h:VisibleRect(widgets.v3_buff_library_pack));assert(h:VisibleRect(widgets.v3_buff_library_import));assert(h:VisibleRect(widgets.v3_buff_library_search_clear))
            else assert(h:VisibleRect(widgets.v3_buff_manage_view));assert(h:VisibleRect(widgets.v3_buff_display_track_search_clear))end
            if source=='cooldowns' then assert(h:VisibleRect(widgets.v3_buff_cooldown_add))end
        end
    end
end)
T('real pooled toggle commits once and follows the reused ID and current colour',function()
    local h,S,F,page,widgets,Layout=RealPage()
    assert(F:SetTrackedPlacement(21,'player','buff',true));assert(F:SetTrackedPlacement(82,'player','buff',true))
    assert(widgets.v3_buff_manage_view.spec.set('tracked'));Layout(640,560)
    local view=widgets.v3_buff_display_tracking_table;local slot=assert(view.list.pool[1]);local button=slot.row.cells[5]
    local originalId=slot.row.item.id
    assert(F:IsTrackedPlacement(originalId,'player','buff') and button.root.testStatusTone=='green','row colour was not submitted');local writes=h.writes
    assert(button.root.events.OnClick(button.root,'LeftButton'));assert(h.writes==writes+4,'one click has duplicate commits')
    assert(not F:IsTrackedPlacement(originalId,'player','buff'));assert(F:SetTrackedPlacement(123,'player','buff',true));assert(page:Refresh())
    Layout(640,560);assert(slot.row.item and slot.row.item.id~=originalId and button.root.testStatusTone=='green','row binding or colour stale')
    local nextId=slot.row.item.id;assert(button.root.events.OnClick(button.root,'LeftButton'));assert(not F:IsTrackedPlacement(nextId,'player','buff'))
    Layout(640,560);assert(button.root.events.OnClick(button.root,'LeftButton')==false,'retired row can act')
end)
T('real current-row button changes Native status colour red green red',function()
    local h,S,F,page,widgets,Layout=RealPage();Layout(640,560)
    local slot=assert(widgets.v3_buff_display_tracking_table.list.pool[1]);local button=slot.row.cells[5]
    assert(button.root.testStatusTone=='red');assert(button.root.events.OnClick(button.root,'LeftButton'))
    assert(button.root.testStatusTone=='green','tracked colour stayed red')
    assert(button.root.events.OnClick(button.root,'LeftButton'));assert(button.root.testStatusTone=='red','cancelled colour stayed green')
end)
T('compact merge preserves target and category filtering without cache contamination',function()
    local h,S,F=Build()
    F.projections.target={{id=21,key='target:21',name='目标同状态',category='debuff',timeText='5'}};F.revision=F.revision+1
    local rows=F:GetManagementProjection({view='live',compact=true,scope='target',filter='debuff'})
    assert(#rows==1 and rows[1].id==21 and rows[1].timeText=='目标 5','merged player representative concealed target debuff')
    rows=F:GetManagementProjection({view='live',compact=true,scope='player',filter='buff'})
    assert(#rows==1 and rows[1].timeText=='自身 10','target-filtered cache leaked into own filter')
end)
T('unchanged library revisions and unrelated cooldown ticks do not rebind the catalog',function()
    local h,S,F,ui,page=Build();assert(ui.widgets.v3_buff_manage_view.spec.set('library'))
    local view=ui.widgets.v3_buff_library_table;local sets,revision=0,1;local base=view.SetItems
    S.Services.CooldownObservationV3={GetHealth=function()return {revision=revision}end}
    page:Refresh();view.SetItems=function(self,...)sets=sets+1;return base(self,...)end
    for i=1,100 do revision=revision+1;assert(page:Refresh())end
    assert(sets==0,'unchanged library is rebound on CD ticks')
end)
T('row command exceptions are visible and committed writes survive UI refresh errors',function()
    local h,S,F,ui,page=Build();local view=ui.widgets.v3_buff_display_tracking_table;local col=Col(ui,view.id,'player_buff');local row=view.items[1]
    local command=F.Commands.SetTrackedPlacement;F.Commands.SetTrackedPlacement=function()error('row_command_failure')end
    local accepted,result=pcall(col.onClick,row);assert(accepted and result==false,'row command escaped its feedback boundary')
    assert(ui.widgets.v3_buff_tracking_status.text:find('row_command_failure',1,true))
    F.Commands.SetTrackedPlacement=command;local set=view.SetItems;view.SetItems=function()error('rebind_after_commit')end
    assert(col.onClick(row)==true and F:IsTrackedPlacement(row.id,'player','buff'),'UI failure mislabels committed tracking')
    assert(ui.widgets.v3_buff_tracking_status.text:find('已保存',1,true) and ui.widgets.v3_buff_tracking_status.text:find('刷新失败',1,true))
    view.SetItems=set;assert(page:Refresh());assert(col.getTone(row)=='green','UI did not retry its unaccepted revision')
end)
T('all tracking labels are readable words including saved automatic placements and CDs',function()
    local h,S,F,ui,page=Build();local row=ui.widgets.v3_buff_display_tracking_table.items[1]
    local own=Col(ui,'v3_buff_display_tracking_table','player_buff');assert(own.getText(row)=='未追踪','untracked row relies on an unsupported symbol')
    assert(F:SetTrackedScope(row.id,'player',true));page:Refresh()
    assert(own.getText(row)=='追踪' and Col(ui,'v3_buff_display_tracking_table','player_debuff').getText(row)=='追踪','legacy auto is exposed as confusing UI mode')
    assert(own.onClick(row));assert(own.getText(row)=='未追踪' and own.getTone(row)=='red')
    assert(F:SetUnifiedCooldownTracked(37172,true));assert(ui.widgets.v3_buff_manage_view.spec.set('cooldowns'))
    local cd=ui.widgets.v3_buff_cooldown_table.items[1];local toggle=Col(ui,'v3_buff_cooldown_table','player_cd')
    assert(toggle.getText(cd)=='追踪' and toggle.onClick(cd) and toggle.getText(cd)=='未追踪')
end)
T('library is a distinct last tab and whole-group selection commits once despite a search filter',function()
    local h,S,F,ui,page=Build();local tabs=ui.widgets.v3_buff_display_tabs.spec.items
    assert(#tabs==4 and tabs[3].value=='transfer' and tabs[4].value=='library','library is hidden in source menu')
    for _,item in ipairs(ui.widgets.v3_buff_manage_view.spec.items)do assert(item.value~='library','duplicate library entrance')end
    local writes=h.io.writes;assert(page:SwitchTab('library'));assert(page.activeTab=='library' and h.io.writes==writes)
    local lib=ui.widgets.v3_buff_library_table;assert(lib and #lib.items>400 and page.libraryPack=='recommended','beginner preset is not obvious')
    assert(ui.widgets.v3_buff_library_search.spec.onSubmit('21'))
    assert(ui.widgets.v3_buff_library_import.onClick());assert(h.io.writes==writes+4,'one group did not use one manifest transaction')
    for _,entry in ipairs(S.Data.StatusTrackingCatalogV3.Packs.recommended.entries)do assert(F:IsTrackedId(entry.id),'search caused partial group import')end
    assert(page.activeTab=='library' and ui.widgets.v3_buff_library_status.text:find('已保存',1,true))
    local row=lib.items[1];assert(Col(ui,lib.id,'target_buff').getText(row)=='追踪','committed state not visible in library')
end)
T('library whole-group failure rolls back and post-commit display errors preserve saved feedback',function()
    local h,S,F,ui,page=Build();assert(page:SwitchTab('library'));local button=ui.widgets.v3_buff_library_import
    assert(button and button.onClick,'whole-group action unavailable');local save=S.Api.SaveData
    S.Api.SaveData=function()return false,'library_save_rejected'end;assert(button.onClick()==false);S.Api.SaveData=save
    assert(not F:IsTrackedId(21) and ui.widgets.v3_buff_library_status.text:find('失败',1,true),'failed group looked committed')
    ui.widgets.v3_buff_library_table.SetItems=function()error('library_rebind_after_commit')end
    assert(button.onClick()==true and F:IsTrackedId(21),'presentation failure undid a durable group commit')
    assert(ui.widgets.v3_buff_library_status.text:find('已保存',1,true) and ui.widgets.v3_buff_library_status.text:find('刷新失败',1,true))
end)
T('real library tab exposes readable controls and one Native click commits exactly one group',function()
    local h,S,F,page,widgets,Layout=RealPage();assert(page:SwitchTab('library'));Layout(560,460)
    local button=widgets.v3_buff_library_import;local writes=h.writes
    assert(button.root.events.OnClick(button.root,'LeftButton'));assert(h.writes==writes+4,'group click executed twice')
    Layout(560,460);local slot
    for _,candidate in pairs(widgets.v3_buff_library_table.list.pool)do
        if candidate.row.visible==true and candidate.row.viewportVisible~=false and h:VisibleRect(candidate.row)then slot=candidate;break end
    end
    assert(slot,'library contains no visible clickable rows');local toggle=slot.row.cells[5]
    assert(toggle.root.testStatusTone=='green' and toggle.text=='追踪','actual pooled button has no readable tracking label')
    local id=slot.row.item.id;local changed,why=toggle.root.events.OnClick(toggle.root,'LeftButton');assert(changed,tostring(why)..' id='..tostring(id)..' enabled='..tostring(toggle.enabled)..' row='..tostring(slot.row.item.key))
    assert(not F:IsTrackedPlacement(id,'player','buff') and F:IsTrackedPlacement(id,'player','debuff'))
    Layout(560,460);assert(toggle.text=='未追踪' and toggle.root.testStatusTone=='red')
    assert(button.root.events.OnClick(button.root,'LeftButton'))
    assert(not F:IsTrackedPlacement(id,'player','buff') and F:IsTrackedPlacement(id,'player','debuff'),'batch action overwrote the configured single-column choice')
    local _,_,cold=Boot({disk=h.disk});assert(cold:EnsureStoreLoaded());assert(not cold:IsTrackedPlacement(id,'player','buff'),'library cancellation lost on reload')
end)
local function PrimePopup(S,picker)
    -- 只替代“已打开”的Native现场，关闭/点击/生命周期由真实RSUI执行；不测试坐标求解。
    assert(picker.popup and not picker.rsUiDegraded,'popup host unavailable')
    assert(S.UI:EnsureVisible(picker.popup,true,picker.owner));assert(S.UI:EnsurePickable(picker.popup,true,picker.owner))
    picker.open=true
end
T('ordinary Native button closes an open source popup before its action runs',function()
    local h,S,F,page,widgets,Layout=RealPage();Layout(640,560);local picker=widgets.v3_buff_manage_view
    PrimePopup(S,picker);local button=widgets.v3_buff_display_track_search_clear;local clicked=0;local callback=button.onClick
    button.onClick=function(...)assert(picker.open==false,'ordinary action ran with a live popup');clicked=clicked+1;return callback(...)end
    assert(button.root.events.OnClick(button.root,'LeftButton'));assert(clicked==1 and picker.open==false and picker.popup.shown==false)
end)
T('page tab switch and deactivation close detached popup surfaces',function()
    local h,S,F,page,widgets,Layout=RealPage();Layout(640,560);local picker=widgets.v3_buff_manage_view
    PrimePopup(S,picker);assert(page:SwitchTab('library'));assert(not picker.open and not picker.popup.shown,'hidden tab left top-level popup open')
    -- 旧几何宿主只保留factory/绑定stub；本用例补入真实PageHost释放方法，而不是跳过生命周期。
    local pageHost=S.UIV3.PageHost;dofile('presentation/v3/shell/rs_v3_page_host.lua')
    pageHost.ReleaseFeatureConsumer=S.UIV3.PageHost.ReleaseFeatureConsumer;pageHost.stats=S.UIV3.PageHost.stats;S.UIV3.PageHost=pageHost
    Layout(640,560);local pack=widgets.v3_buff_library_pack;PrimePopup(S,pack);assert(page:OnDeactivated())
    assert(not pack.open and not pack.popup.shown,'hidden page left popup open')
end)
T('dropdown option and popup-owned child interactions keep their own popup until explicit closure',function()
    local h,S,F,page,widgets,Layout=RealPage();Layout(640,560);local picker=widgets.v3_buff_manage_view
    PrimePopup(S,picker);local option=picker.optionButtons[2];assert(option.rsDropdownSelectable)
    assert(option.events.OnClick(option,'LeftButton'));assert(not picker.open and page.managementView=='tracked','option was dismissed before committing')
    local body=assert(S.RSUI:VerticalBox({id='test_popup_body',parent=UIParent}))
    local popup={open=true,popupBody=body,Close=function(self)self.open=false;return true end};S.RSUI.PopupCoordinator:Register(popup)
    local hits=0;local child=assert(S.RSUI:Button({id='test_popup_child',parent=body,text='内部操作',onClick=function()hits=hits+1;return true end}))
    assert(child.root.events.OnClick(child.root,'LeftButton') and hits==1 and popup.open,'popup child click dismissed its owner')
    S.RSUI.PopupCoordinator:Unregister(popup)
end)
T('remaining time spells out self target and unavailable without implying expiration',function()
    local h,S,F,ui,page=Build()
    F.projections.player[1].timeText='--';F.projections.target={{id=21,key='target:21',name='目标状态',category='buff',timeText='5'}}
    F.revision=F.revision+1;assert(page:Refresh());local row=ui.widgets.v3_buff_display_tracking_table.items[1]
    assert(row.timeText=='自身 未知 / 目标 5','remaining time uses ambiguous shorthand: '..tostring(row.timeText))
end)
T('real narrow time cell uses two bounded native lines without squeezing tracking buttons',function()
    local h,S,F,page,widgets,Layout=RealPage()
    F.projections.player[1].timeText='12.34.56'
    F.projections.target={{id=21,key='target:21',name='目标状态',category='buff',timeText='12.34.56'}}
    F.revision=F.revision+1;assert(page:Refresh());Layout(560,460)
    local view=widgets.v3_buff_display_tracking_table;local cell=assert(view.list.pool[1].row.cells[4])
    assert(cell.overflow=='wrap' and cell.maxLines==2 and #cell.lineLabels==2,'time values share one cramped Native label')
    assert(cell.lineLabels[1].text=='自身 12.34.56' and cell.lineLabels[2].text=='目标 12.34.56','one scope or its numeric time was clipped')
    for _,column in ipairs(view:GetResolvedColumns())do if column.cellType=='button' then assert(column.width>=56,'tracking action squeezed by time')end end
end)
T('display content includes calibration and scrollable settings under four visible tabs',function()
    local h,S,F,page,widgets,Layout=RealPage();local tabs=widgets.v3_buff_display_tabs.spec.items
    assert(#tabs==4 and tabs[2].text=='显示内容' and tabs[3].value=='transfer' and tabs[4].value=='library','content and geometry remain separate tabs')
    assert(page:SwitchTab('layout') and page.activeTab=='visibility','old layout navigation does not enter combined content')
    local scroll=assert(widgets.v3_buff_display_content_scroll,'display content lacks a bounded scrolling viewport')
    for _,size in ipairs({{560,460},{800,650}}) do
      for _,scope in ipairs({'player','target'}) do
        assert(widgets.v3_buff_visibility_scope.spec.set(scope))
        Layout(size[1],size[2]);assert(h:VisibleRect(widgets.v3_buff_display_layout_open_calibration),'calibration action is not accessible')
        assert(h:VisibleRect(widgets.v3_buff_visibility_scope),'scope chooser is not accessible')
        assert(scroll.lastOverflow<=0.01,'a settings group is too tall to scroll safely')
        for _,id in ipairs({'v3_buff_visibility_grid','v3_buff_display_layout_policy_card','v3_buff_display_layout_refresh_card'}) do
            local component=assert(widgets[id]);local entry=component
            while entry.parentComponent and entry.parentComponent~=scroll do entry=entry.parentComponent end
            assert(entry.parentComponent==scroll,'display setting escaped the combined content tree')
            scroll:EnsureChildVisible(entry);Layout(size[1],size[2]);assert(h:VisibleRect(component),'cannot reach display setting '..id)
            if id=='v3_buff_visibility_grid' then
                for _,definition in ipairs(F.HudVisibilityDefinitions) do
                    local control=widgets['v3_buff_visibility_'..definition.key]
                    if control and control.visible~=false then assert(h:VisibleRect(control),'display toggle is clipped '..definition.key)end
                end
            end
        end
        scroll:ScrollToTop();Layout(size[1],size[2])
      end
    end
    local writes=h.writes;local request
    S.UIV3.BuffHudCalibrationV3={Open=function(_,options)request=options;return true end}
    assert(widgets.v3_buff_display_layout_open_calibration.root.events.OnClick(widgets.v3_buff_display_layout_open_calibration.root,'LeftButton'))
    assert(request and request.scope=='target' and h.writes==writes,'calibration ignored selected HUD or wrote a draft early')
end)
T('two share buttons export the full setup and one import persists it for another user',function()
    local h,S,F,ui,page=Build();assert(page:SwitchTab('transfer'))
    local actions=ui.widgets.v3_buff_display_transfer_buttons.children
    assert(#actions==2 and actions[1].text=='导出' and actions[2].text=='导入','sharing requires extra modes or steps')
    assert(F:SetTrackedPlacement(21,'player','debuff',true));assert(F:SetTrackedPlacement(82,'target','buff',true))
    assert(F:SetUnifiedCooldownTracked(37172,true));assert(F.Commands:SetSetting('headShowStacks',false))
    local hud=F:GetHudCalibrationSnapshot();hud.player.components.buffs.x=37;hud.target.components.buffs.x=73
    assert(F:PersistHudCalibrationSnapshot(hud,'test_share'));local writes=h.io.writes
    assert(actions[1].onClick());local text=ui.edit.text
    assert(h.io.writes==writes and text:find('EXPORT_MODE=full',1,true),'export writes settings or omits layout')
    local other,otherS,otherF,otherUi,otherPage=Build();assert(otherF:SetTrackedPlacement(99,'target','debuff',true))
    assert(otherPage:SwitchTab('transfer'));otherUi.edit.text=text
    assert(otherUi.widgets.v3_buff_display_transfer_import.onClick())
    assert(otherF:IsTrackedPlacement(21,'player','debuff') and otherF:IsTrackedPlacement(82,'target','buff'),'first import only previews')
    assert(otherF:IsTrackedPlacement(99,'target','debuff'),'simple import erased an unrelated existing selection')
    assert(otherF:IsUnifiedCooldownTracked(37172) and otherF:GetSettingsProjection().headShowStacks==false,'shared CD or display policy lost')
    local copied=otherF:GetHudCalibrationSnapshot();assert(copied.player.components.buffs.x==37 and copied.target.components.buffs.x==73,'dual HUD layout lost')
    local _,_,cold=Boot({disk=other.disk});assert(cold:EnsureStoreLoaded())
    assert(cold:IsTrackedPlacement(21,'player','debuff') and cold:GetHudCalibrationSnapshot().target.components.buffs.x==73,'import was not durable')
end)
T('simple import rejects invalid text and reports failed persistence without changing selections',function()
    local h,S,F,ui,page=Build();assert(F:SetTrackedPlacement(99,'target','debuff',true));assert(page:SwitchTab('transfer'))
    local button=ui.widgets.v3_buff_display_transfer_import;local before=F:SerializeExport(F:ExportAll());local writes=h.io.writes
    ui.edit.text='AUTO=21,bad';assert(button.onClick()==false)
    assert(h.io.writes==writes and F:SerializeExport(F:ExportAll())==before,'invalid import mutated settings')
    ui.edit.text='AUTO=21';local original=S.Api.SaveData;S.Api.SaveData=function()return false,'test_share_write_failed'end
    assert(button.onClick()==false);S.Api.SaveData=original
    assert(F:SerializeExport(F:ExportAll())==before and not F:IsTrackedId(21),'failed import changed committed state')
    assert(ui.widgets.v3_buff_display_transfer_status.text:find('导入失败',1,true),'failed save reported success')
end)
T('export refuses a rewritten or truncated editor instead of reporting a usable share',function()
    local h,S,F,ui,page=Build();assert(page:SwitchTab('transfer'));local writes=h.io.writes
    ui.edit.SetText=function(self,value)self.text=tostring(value):sub(1,12);return true end
    assert(ui.widgets.v3_buff_display_transfer_export.onClick()==false,'truncated text was advertised as a share')
    assert(not ui.widgets.v3_buff_display_transfer_status.text:find('已导出',1,true) and h.io.writes==writes,'export mutates configuration or reports false success')
end)
print(string.format('TRACKING_GRID_RESULT passed=%d failed=%d',passed,failed));if failed>0 then os.exit(1)end
