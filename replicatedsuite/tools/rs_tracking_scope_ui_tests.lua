-- Scoped tracking interaction regression: real BuffDisplay model + synthetic presentation controls.
local pass,fail=0,0
local function Test(name,fn)local ok,err=pcall(fn);if ok then pass=pass+1;print('PASS scope-ui '..name)else fail=fail+1;print('FAIL scope-ui '..name..': '..tostring(err))end end
local Boot=dofile('tools/rs_pvp_hud_test_host.lua')
local function Build()
    local h,S,F=Boot({noRenderer=true})
    for _,file in ipairs({'data/rs_skill_effects.lua','data/rs_combat_ability_catalog.lua','data/ids/rs_buff_ids.lua','data/rs_status_tracking_catalog.lua'}) do dofile(file) end
    if type(F.GetManagementProjection)~='function' then dofile('features/combat/buff_display/rs_buff_display_management.lua') end
    dofile('features/combat/buff_display/rs_buff_display_transfer_v2.lua')
    F.projections={player={{id=21,key='player:21',name='测试状态',category='buff',timeText='10',stack=1,detectionSource='normal'}},target={}}
    F.coverage={player={available=true,complete=true,reliable=true},target={available=true,complete=true,reliable=true}}
    F.revision=(F.revision or 0)+1
    S.FeatureRuntime.IsEnabled=function() return false end
    local ui=dofile('tools/rs_status_ui_test_host.lua')(S)
    local page=assert(ui:Build());assert(page:Refresh())
    page.managementView='live';assert(page:Refresh())
    return S,F,ui,page
end
Test('list activation only selects and four inline buttons independently toggle',function()
    local S,F,ui,page=Build();local view=ui.widgets.v3_buff_display_tracking_table;local row=view.items[1];assert(view.spec.onItemActivated(row))
    assert(page.selectedManagementRow.id==21 and not F:IsTrackedId(21),'selection mutated tracking')
    local columns={};for _,c in ipairs(view.spec.columns)do columns[c.id]=c end
    for _,id in ipairs({'player_buff','player_debuff','target_buff','target_debuff'})do assert(columns[id].cellType=='button')end
    local target=columns.target_buff;assert(target.onClick(row));assert(F:IsTrackedPlacement(21,'target','buff') and not F:IsTrackedPlacement(21,'player','buff'))
    assert(target.getTone(row)=='green');assert(target.onClick(row));assert(not F:IsTrackedPlacement(21,'target','buff') and target.getTone(row)=='red')
end)
Test('library row activation selects without importing or toggling tracking',function()
    local S,F,ui,page=Build();page:SwitchTab('library');assert(page:RefreshLibrary())
    local t=assert(ui.widgets.v3_buff_library_table);local row=assert(t.items[1]);local id=row.id
    assert(t.spec.onItemActivated(row));assert(page.selectedManagementRow and page.selectedManagementRow.id==id)
    assert(not F:IsTrackedId(id),'library row activation changed persistent tracking')
end)
Test('four tracking placements have dedicated readable columns',function()
    local S,F,ui=Build();local columns={};for _,c in ipairs(ui.widgets.v3_buff_display_tracking_table.spec.columns)do columns[c.id]=c end
    for _,id in ipairs({'player_buff','player_debuff','target_buff','target_debuff'})do assert(columns[id] and columns[id].width>=56 and columns[id].cellType=='button')end
    assert(not columns.cancel,'redundant global cancellation remains')
end)
Test('simple share import preserves encoded target-only scope without extra selectors',function()
    local S,F,ui,page=Build();page:SwitchTab('transfer')
    assert(ui.widgets.v3_buff_display_transfer_scope==nil and ui.widgets.v3_buff_display_transfer_category==nil,'extra sharing selectors remain')
    ui.edit.text='TARGET_AUTO=21';assert(ui.widgets.v3_buff_display_transfer_import.onClick())
    assert(F:IsTrackedChannel(21,'target','auto') and not F:IsTrackedChannel(21,'player','auto'),'share import scope ignored')
    page:RefreshTransferStatus();assert(ui.widgets.v3_buff_display_transfer_status.text:find('导入成功',1,true),'saved feedback lost on refresh')
end)

Test('four column labels distinguish self target without category correction mutation',function()
    local S,F,ui=Build();local labels={player_buff='自身 Buff',player_debuff='自身 Debuff',target_buff='目标 Buff',target_debuff='目标 Debuff'}
    for _,c in ipairs(ui.widgets.v3_buff_display_tracking_table.spec.columns)do if labels[c.id]then assert(c.title==labels[c.id])end end
    assert(ui.widgets.v3_buff_classify_buff==nil,'manual selected-row controls crowd the grid')
    assert(F:SetClassification(21,'debuff'));assert(F:SetTrackedPlacement(21,'player','buff',true));assert(F:GetClassification()[21]=='debuff','placement rewrote metadata')
end)
Test('compact tracker source uses selection-first four-channel contract',function()
    local f=assert(io.open('presentation/v3/widgets/rs_v3_buff_display_widget.lua','rb'));local source=f:read('*a');f:close()
    for _,id in ipairs({'v3_buff_widget_player_buff','v3_buff_widget_player_debuff','v3_buff_widget_target_buff','v3_buff_widget_target_debuff'}) do assert(source:find(id,1,true),id..' missing') end
    assert(source:find('unsetLabel="取消目标 Buff"',1,true),'compact target buff cancel action label missing')
    assert(source:find('active and def.unsetLabel or def.setLabel',1,true),'compact channel label is not driven by authoritative tracking state')
    assert(source:find('selectedRow',1,true),'compact selection state missing')
    assert(not source:find('SetTrackedId(tonumber(item.id)',1,true),'compact row activation still toggles global tracking')
end)
print(('SCOPE UI RESULT %d passed / %d failed'):format(pass,fail));if fail>0 then error('scope UI tests failed') end
