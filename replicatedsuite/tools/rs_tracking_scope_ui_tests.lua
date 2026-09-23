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
    return S,F,ui,page
end
Test('main list activation only selects and four buttons toggle independent channels',function()
    local S,F,ui,page=Build()
    local tableView=assert(ui.widgets.v3_buff_display_tracking_table);local row=assert(tableView.items[1])
    assert(tableView.spec.onItemActivated(row))
    assert(page.selectedManagementRow and page.selectedManagementRow.id==21,'row not selected')
    assert(not F:IsTrackedChannel(21,'player','buff') and not F:IsTrackedChannel(21,'target','buff'),'selection mutated tracking')
    for _,id in ipairs({'v3_buff_track_player_buff','v3_buff_track_player_debuff','v3_buff_track_target_buff','v3_buff_track_target_debuff'}) do assert(ui.widgets[id],id..' missing') end
    local targetButton=ui.widgets.v3_buff_track_target_buff
    assert(targetButton.onClick())
    assert(F:IsTrackedChannel(21,'target','buff') and not F:IsTrackedChannel(21,'player','buff'),'target-only toggle leaked to self')
    assert(targetButton.text=='所选取消目标 Buff' or (type(targetButton.GetText)=='function' and targetButton:GetText()=='所选取消目标 Buff'),'tracked target buff did not expose cancel action')
    assert(targetButton.onClick())
    assert(not F:IsTrackedChannel(21,'target','buff'),'second click did not remove target channel')
    assert(targetButton.text=='所选设为目标 Buff' or (type(targetButton.GetText)=='function' and targetButton:GetText()=='所选设为目标 Buff'),'removed target buff did not restore set action')
end)
Test('library row activation selects without importing or toggling tracking',function()
    local S,F,ui,page=Build();page:SwitchTab('library');assert(page:RefreshLibrary())
    local t=assert(ui.widgets.v3_buff_library_table);local row=assert(t.items[1]);local id=row.id
    assert(t.spec.onItemActivated(row));assert(page.selectedManagementRow and page.selectedManagementRow.id==id)
    assert(not F:IsTrackedId(id),'library row activation changed persistent tracking')
end)
Test('tracking column is wide enough for multi-channel labels',function()
    local S,F,ui=Build();local cols=ui.widgets.v3_buff_display_tracking_table.spec.columns;local width
    for _,c in ipairs(cols) do if c.id=='tracked' then width=c.width end end
    assert((width or 0)>=150,'tracked column still sized for yes/no text')
end)
Test('quick import exposes self target both scope selector and respects target-only choice',function()
    local S,F,ui,page=Build();page:SwitchTab('transfer')
    local scope=assert(ui.widgets.v3_buff_display_transfer_scope,'scope selector missing')
    assert(scope.spec.set('target'));page.quickText='21';ui.widgets.v3_buff_display_transfer_quick_input.value='21'
    assert(ui.widgets.v3_buff_display_transfer_quick_import.onClick())
    assert(F:IsTrackedChannel(21,'target','auto') and not F:IsTrackedChannel(21,'player','auto'),'quick import scope ignored')
    page:RefreshTransferStatus();local text=ui.widgets.v3_buff_display_transfer_status.text
    assert(text:find('自身',1,true) and text:find('目标',1,true),'scoped counts missing')
end)

Test('four channel labels use explicit self target wording and classification controls remain separate',function()
    local S,F,ui=Build()
    local expected={
        v3_buff_track_player_buff='所选设为自身 Buff',
        v3_buff_track_player_debuff='所选设为自身 Debuff',
        v3_buff_track_target_buff='所选设为目标 Buff',
        v3_buff_track_target_debuff='所选设为目标 Debuff',
    }
    for id,label in pairs(expected) do local w=assert(ui.widgets[id],id..' missing');assert(w.text==label or (type(w.GetText)=='function' and w:GetText()==label),id..' label') end
    assert(ui.widgets.v3_buff_classify_buff and ui.widgets.v3_buff_classify_debuff and ui.widgets.v3_buff_classify_auto,'classification correction controls lost')
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
