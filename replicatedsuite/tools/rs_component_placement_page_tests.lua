-- Replicated Suite · 组件显示位置设置页回归
-- 作者：Replicated
-- QQ群：1104129461
-- 运行真实页面、Feature Commands 与持久化；仅使用现有离线 UI/磁盘宿主。
local passed,failed=0,0
local function Test(name,fn)
    local ok,err=xpcall(fn,debug.traceback)
    if ok then passed=passed+1;print('PASS component-placement-page '..name)
    else failed=failed+1;print('FAIL component-placement-page '..name..': '..tostring(err))end
end
local function Build(disk)
    local h,S,F=dofile('tools/rs_pvp_hud_test_host.lua')({disk=disk,noRenderer=true})
    dofile('features/combat/buff_display/rs_buff_display_transfer_v2.lua')
    dofile('features/combat/buff_display/rs_buff_display_alias_store.lua')
    dofile('features/combat/buff_display/rs_buff_display_arrangement.lua')
    dofile('features/combat/buff_display/rs_buff_display_placement.lua')
    assert(F:EnsureStoreLoaded())
    S.FeatureRuntime.IsEnabled=function()return false end
    local ui=dofile('tools/rs_status_ui_test_host.lua')(S)
    local page=assert(ui:Build());assert(page:OnActivated());assert(page:SwitchTab('visibility'))
    return h,S,F,ui,page
end
local function Controls(ui)
    return assert(ui.widgets.v3_buff_display_component,'current component picker missing'),
        assert(ui.widgets.v3_buff_display_mode,'current component mode selector missing'),
        assert(ui.widgets.v3_buff_visibility_scope,'scope selector missing')
end
local function Mode(F,scope,key)
    return assert(F.Commands:GetHudComponentDisplayModeProjection(scope,key)).mode
end
local function HasItem(picker,key)
    for _,item in ipairs(picker.items)do if item.value==key then return true end end
    return false
end

Test('distance defaults to one click fixed while every other component and scope stays head',function()
    local h,S,F,ui,page=Build();local picker,mode=Controls(ui)
    assert(picker.spec.get()=='distance','distance is not selected by default')
    assert(mode:SetValue('fixed'))
    assert(Mode(F,'player','distance')=='fixed','selected distance did not become fixed')
    for _,key in ipairs({'info','class','gearScore','buffs','debuffs','cooldowns','mainHand','offHand','ranged','wings','castBar'})do
        assert(Mode(F,'player',key)=='head','distance change moved '..key)
    end
    assert(Mode(F,'target','distance')=='head','distance change leaked to target')
    assert(not S.FeatureRuntime:IsEnabled() and not page.consumerHeld,'settings enabled the feature')
    local _,_,cold=Build(h.disk)
    assert(Mode(cold,'player','distance')=='fixed' and Mode(cold,'player','buffs')=='head','reload lost component isolation')
end)

Test('scope and component switches reread independent committed modes',function()
    local _,_,F,ui=Build();local picker,mode,scope=Controls(ui)
    assert(mode:SetValue('fixed'));assert(picker:SetValue('buffs'));assert(mode.value=='head')
    assert(scope:SetValue('target'));assert(picker.spec.get()=='buffs' and mode.value=='head')
    assert(mode:SetValue('fixed'));assert(picker:SetValue('distance'));assert(mode.value=='head')
    assert(scope:SetValue('player'));assert(mode.value=='fixed')
    assert(picker:SetValue('buffs'));assert(mode.value=='head')
    assert(Mode(F,'target','buffs')=='fixed' and Mode(F,'player','buffs')=='head')
    assert(picker:SetValue('info'));assert(mode:SetValue('fixed'))
    assert(Mode(F,'player','info')=='fixed' and Mode(F,'player','class')=='head','profession text and icon were confused')
end)

Test('target alias selection cannot leak into the player component picker or calibration',function()
    local _,S,F,ui=Build();local picker,mode,scope=Controls(ui)
    assert(not HasItem(picker,'alias'));assert(not picker:SetValue('alias'))
    assert(not picker:SetValue('images') and not picker:SetValue('unknown'),'picker accepted a visibility group or unknown component')
    assert(scope:SetValue('target'));assert(HasItem(picker,'alias'));assert(picker:SetValue('alias'));assert(mode:SetValue('fixed'))
    local opened
    S.UIV3.BuffHudCalibrationV3={Open=function(_,context)opened=context;return true end}
    assert(ui.widgets.v3_buff_display_layout_open_calibration.onClick())
    assert(opened.scope=='target' and opened.component=='alias','calibration did not preselect the current target component')
    assert(scope:SetValue('player'));assert(not HasItem(picker,'alias') and picker.spec.get()=='distance')
    assert(ui.widgets.v3_buff_display_layout_open_calibration.onClick())
    assert(opened.scope=='player' and opened.component=='distance','target alias leaked into player calibration')
    assert(Mode(F,'target','alias')=='fixed' and Mode(F,'player','distance')=='head')
end)

Test('failed component save restores the selector from committed projection',function()
    local _,S,F,ui=Build();local _,mode=Controls(ui)
    local save=S.Api.SaveData
    S.Api.SaveData=function(_,key,value)
        if key:find('buff_display_placement',1,true)then return false,'injected_component_save_failure'end
        return save(S.Api,key,value)
    end
    local ok,err=mode:SetValue('fixed')
    assert(ok==false and tostring(err):find('injected_component_save_failure',1,true),'save failure was swallowed')
    assert(mode.value=='head' and Mode(F,'player','distance')=='head','failed save left a UI-only fixed selection')
    assert(ui.widgets.v3_buff_visibility_status.text:find('保存失败',1,true),'save failure feedback missing')
end)

Test('visibility toggles keep their scope and do not overwrite component placement',function()
    local _,S,F,ui,page=Build();local picker,mode,scope=Controls(ui)
    assert(mode:SetValue('fixed'));assert(ui.widgets.v3_buff_visibility_distance:SetValue(false))
    assert(not F:GetScopeLayoutSettings('player').components.distance.enabled)
    assert(Mode(F,'player','distance')=='fixed')
    assert(scope:SetValue('target'));assert(ui.widgets.v3_buff_visibility_distance.spec.get()==true)
    assert(ui.widgets.v3_buff_visibility_classIcon:SetValue(false))
    assert(F:GetScopeLayoutSettings('player').components.class.enabled~=false)
    assert(picker:SetValue('class'));assert(mode:SetValue('fixed'))
    assert(not F:GetScopeLayoutSettings('target').components.class.enabled,'mode change turned a hidden component on')
    assert(Mode(F,'target','distance')=='head' and Mode(F,'target','class')=='fixed')
    assert(not S.FeatureRuntime:IsEnabled() and not page.consumerHeld,'display edits acquired the feature consumer')
end)

print(('COMPONENT PLACEMENT PAGE RESULTS: %d passed / %d failed'):format(passed,failed))
assert(failed==0,tostring(failed)..' component placement page regressions')
