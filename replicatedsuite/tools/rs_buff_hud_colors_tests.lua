------------------------------------------------------------------------
-- Replicated Suite · 状态显示自定义颜色回归
-- 作者：Replicated
-- QQ群：1104129461
------------------------------------------------------------------------
local passed,failed=0,0
local function Test(name,fn)
    local ok,err=xpcall(fn,debug.traceback)
    if ok then passed=passed+1;print('PASS hud-colors '..name)
    else failed=failed+1;print('FAIL hud-colors '..name..': '..tostring(err))end
end
local function Boot(disk)
    local h,S,F=dofile('tools/rs_pvp_hud_test_host.lua')({disk=disk})
    dofile('features/combat/buff_display/rs_buff_display_transfer_v2.lua')
    local file=io.open('features/combat/buff_display/rs_buff_display_colors.lua','rb')
    assert(file,'custom HUD color domain is missing');file:close()
    dofile('features/combat/buff_display/rs_buff_display_colors.lua')
    assert(F:EnsureHudColorsLoaded())
    return h,S,F
end
local function Same(a,b)return math.abs(a-b)<0.000001 end
Test('arbitrary RGB survives durable reload and target stays independent',function()
    local h,S,F=Boot();local color={37/255,143/255,219/255}
    assert(F.Commands:SetHudColor('player','classText',color))
    local r,g,b=F:GetHudColor('player','classText')
    assert(Same(r,color[1]) and Same(g,color[2]) and Same(b,color[3]))
    assert(F:GetHudColor('target','classText')==1)
    local h2,S2,F2=Boot(h.disk)
    assert(Same(F2:GetHudColor('player','classText'),color[1]))
    assert(F2:GetHudColor('target','classText')==1)
end)
Test('bad RGB is rejected and save failure restores the committed color',function()
    local h,S,F=Boot();local writes=h.io.writes
    for _,color in ipairs({{-1,0,0},{0/0,1,1},{1,math.huge,0},{1,0},{2,0,0}})do
        assert(F.Commands:SetHudColor('target','gearScore',color)==false)
    end
    assert(h.io.writes==writes)
    local sparse={1,1,1};sparse[2]=nil
    assert(F.Commands:SetHudColor('target','gearScore',sparse)==false,'sparse RGB must fail gracefully')
    S.Api.SaveData=function()return false,'color_disk_rejected'end
    local ok,err=F.Commands:SetHudColor('target','gearScore',{0.2,0.4,0.6})
    assert(ok==false and err and F:GetHudColor('target','gearScore')==1)
end)
local function Panel()
    local h=dofile('tools/rs_gear_page_test_host.lua')();local S=h.S
    UIParent=h.Native(nil,'screen',0,0,480,680)
    S.UI.CreatePanel=S.UI.CreateEmptyWidget
    S.UI.CreateWindowShell=function()return nil,'test_no_window'end
    S.UI.EnsurePickable=function(_,n,v)n.pickable=v;return true,true end
    S.UI.EnsureEnabled=function(_,n,v)n.enabled=v;return true,true end
    S.UI.EnsureVisible=function(_,n,v)n.shown=v;return true,true end
    S.UI.SetColor=function(_,n,r,g,b,a)n.color={r,g,b,a};return true end
    S.UI.CreateSlider=function(_,p,id,x,y,w,ht)
        local n=h.Native(p,id,x,y,w,ht)
        function n:SetValue(value)self.value=value end;function n:GetValue()return self.value end
        return n
    end
    S.UI.GetSliderValue=function(_,n)return n.value or 0 end
    S.UI.SetSliderValue=function(_,n,v)n.value=v;return true end
    S.UI.BindDeferredInputActivation=function()return true end
    for _,path in ipairs({'core/rs_demand.lua','ui/framework/rs_ui_floating_surface.lua','features/combat/buff_display/rs_buff_display_store.lua',
        'features/combat/buff_display/rs_buff_display_projection.lua','features/combat/buff_display/rs_buff_display_feature.lua',
        'features/combat/buff_display/rs_buff_display_management.lua','features/combat/buff_display/rs_buff_display_transfer_v2.lua',
        'features/combat/buff_display/rs_buff_display_colors.lua','presentation/v3/widgets/rs_v3_buff_color_settings.lua'})do dofile(path)end
    local F=S.Features.BuffDisplay;assert(F:EnsureHudColorsLoaded())
    local scope='player'
    local panel=S.UIV3.BuffColorSettings:Build(UIParent,{id='test_colors',getScope=function()return scope end,
        getColors=function()return F:GetHudColorsProjection()end,apply=function(patch)return F:PersistHudColors(patch)end})
    function h:SetScope(value)panel:CancelPickers();scope=value;panel:Refresh()end
    function h:LayoutColors(width)panel.root:Layout(0,0,width,600)end
    function h:ColorAction(id)
        local function Find(n)if n.id==id then return n end;for _,child in ipairs(n.children or {})do local result=Find(child);if result then return result end end end
        local button=assert(Find(panel.root));return button.spec.onClick()
    end
    return h,S,F,panel
end
Test('real ColorField applies arbitrary RGB and cancels edits without saving',function()
    local h,S,F,panel=Panel();local field=panel.fields.classText;local writes=h.writes
    assert(not field.rsUiDegraded,'actual ColorField was replaced or unavailable')
    field:BeginDraft();field:SetDraftColor(37/255,143/255,219/255,true)
    assert(h.writes==writes and F:GetHudColor('player','classText')==1,'dragging saved a color')
    field:CancelDraft();assert(h.writes==writes)
    field:SetDraftColor(37/255,143/255,219/255,true);assert(field:ApplyDraft())
    assert(Same(F:GetHudColor('player','classText'),37/255))
    assert(Same(F:GetRecentHudColors()[1][3],219/255))
    assert(panel.rows.alias.row.visible==false);h:SetScope('target');assert(panel.rows.alias.row.visible==true)
end)
Test('real HEX input accepts unsubmitted text and rejects invalid drafts without writing',function()
    local h,S,F,panel=Panel();local field=panel.fields.classText;local writes=h.writes
    local input=assert(field.hexInput,'HUD ColorField has no editable HEX input')
    field:BeginDraft();input.root:SetText('#258FDB')
    assert(field:ApplyDraft(),'clicking Apply lost the unsubmitted HEX text')
    assert(Same(F:GetHudColor('player','classText'),37/255))
    writes=h.writes;field:BeginDraft();input.root:SetText('#NOTHEX')
    assert(field:ApplyDraft()==false and h.writes==writes,'invalid HEX was saved')
    field:CancelDraft();assert(input.root:GetText()=='#258FDB' and h.writes==writes)
    field:BeginDraft();input.root:SetText('#654321');assert(input:Submit('enter'))
    assert(h.writes==writes,'pressing Enter committed a color instead of the picker draft')
    assert(Same(field.draftColor[1],101/255));assert(field:ApplyDraft())
    assert(Same(F:GetHudColor('player','classText'),101/255))
    field:BeginDraft();input.root:SetText('#258FDB');field:SetDraftColor(0.2,0.4,0.6,true)
    assert(input.root:GetText()=='#336699','RGB selection left a stale HEX override')
    assert(field:ApplyDraft());assert(Same(F:GetHudColor('player','classText'),0.2))
end)
Test('HEX input retains suspended drafts and closing releases its keyboard ownership',function()
    local h,S,F,panel=Panel();local field=panel.fields.classText;local input=assert(field.hexInput)
    field:BeginDraft();assert(input:BeginEditing('test_hex'))
    input.root:SetText('#258FDB');assert(input:SuspendEditing('test_blur'))
    input.root:SetText('#FFFFFF') -- RU 失焦重绘不能覆盖 Lua 持有的草稿。
    assert(field:ApplyDraft());assert(Same(F:GetHudColor('player','classText'),37/255))
    field:BeginDraft();assert(input:BeginEditing('test_close'));input.root:SetText('#654321')
    local writes=h.writes;field:Close()
    assert(input.root.rsUiKeyboardArmed==false and not input:HasDraftSession())
    assert(h.writes==writes and input.root:GetText()=='#258FDB')
end)
Test('color rows stay within narrow layouts and scope copying preserves target-only alias',function()
    local h,S,F,panel=Panel()
    for _,width in ipairs({320,400,600})do
        h:LayoutColors(width)
        for key,row in pairs(panel.rows)do
            if row.row.visible then
                local field=panel.fields[key];assert(field.width>=80)
                assert(field.x+field.width<=width,'color field overflows at '..width)
            end
        end
    end
    assert(F:SetHudColor('target','alias',{0.2,0.4,0.6}))
    assert(h:ColorAction('test_colors_copy'))
    assert(Same(F:GetHudColor('target','alias'),0.2),'copying hidden self alias erased the target-only name color')
end)
Test('color projections are detached and never read or write Native',function()
    local h,S,F=Boot();local reads,writes=h.io.reads,h.io.writes
    local colors=F:GetHudColorsProjection();colors.player.classText[1]=0
    for i=1,25 do F:GetHudColor('target','distance');F:GetHudColorsProjection()end
    assert(F:GetHudColor('player','classText')==1 and h.io.reads==reads and h.io.writes==writes)
end)
Test('full sharing retains custom RGB while tracking-only sharing omits it',function()
    local h,S,F=Boot();assert(F:EnsureStoreLoaded())
    assert(F.Commands:SetHudColor('target','gearScore',{17/255,33/255,201/255}))
    local text=F:SerializeExport(F:ExportAll())
    assert(text:find('HUDCOLOR=target:gearScore:1121C9',1,true),'color missing from full export')
    local parsed=F:ParseImportText(text);assert(#parsed.errors==0,table.concat(parsed.errors,';'))
    assert(parsed.data.colors.target.gearScore[3]==201/255)
    assert(not F:SerializeExport(F:ExportAll('tracking')):find('HUDCOLOR=',1,true))
end)
Test('real HUD renderer applies independent colors and preserves widget alpha',function()
    local h,S,F,P=dofile('tools/rs_pvp_hud_test_host.lua')({runtimeHud=true})
    dofile('features/combat/buff_display/rs_buff_display_colors.lua');assert(F:EnsureHudColorsLoaded())
    S.UI.SetColor=function(_,widget,r,g,b,a)widget.customColor={r,g,b,a};return true end
    assert(F.Commands:SetHudColor('target','classText',{0.2,0.4,0.6}))
    assert(F.Commands:SetHudColor('player','gearScore',{0.6,0.4,0.2}))
    F.laneData.player.gearScore=12345
    F.State.settings.components.gearScore.alpha=0.37;F:InvalidateSettingsCache()
    P:VisualTick(true)
    assert(P.pools.target.info.classTextRoot.customColor,'renderer ignores custom text colors')
    assert(Same(P.pools.target.info.classTextRoot.customColor[1],0.2))
    assert(Same(P.pools.player.info.gearRoot.customColor[1],0.6))
    assert(P.pools.player.info.classTextRoot.customColor[1]==1)
    assert(P.pools.target.info.classTextRoot.rsManualTextColor==true,'workspace theme can overwrite custom RGB')
    assert(Same(P.pools.player.info.gearRoot.alpha,0.37),'RGB replaced the component opacity')
    assert(Same(P.pools.player.info.gearRoot.customColor[4],1),'text color applied opacity twice')
end)
local function Calibration(withControls)
    local h,S,F,P,C=dofile('tools/rs_hud_template_copy_test_host.lua')()
    assert(C:Exit(false)) -- 旧测试宿主提前打开了校准；按生产TOC顺序先加载扩展，再建立新的草稿。
    dofile('features/combat/buff_display/rs_buff_display_colors.lua')
    if withControls then
        S.UI.SetColor=function(_,n,r,g,b,a)n.color={r,g,b,a};return true end
        -- 真实 PopupPositioning 保留；图形宿主仅提供其已知逻辑父链，独立定位用例覆盖真实求解边界。
        S.Layout.ResolveSuiteOwnedViewportLogicalRect=function(_,n)local x,y=h:World(n);return x,y,n.width,n.height end
        dofile('ui/framework/rs_ui_popup_positioning.lua')
        S.UI.EnsureVisible=function(_,n,v)n.shown=v;return true,true end
        S.UI.CreateSlider=function(_,p,id,x,y,w,ht)
            local n=h.Native(p,id,x,y,w,ht)
            function n:SetValue(value)self.value=value end;function n:GetValue()return self.value end
            return n
        end
        S.UI.GetSliderValue=function(_,n)return n.value or 0 end
        S.UI.SetSliderValue=function(_,n,v)n.value=v;return true end
        dofile('presentation/v3/widgets/rs_v3_buff_color_settings.lua')
    end
    assert(F:EnsureHudColorsLoaded());assert(C:Open())
    return h,S,F,C
end
Test('HUD adjustment directly embeds the selected component colors without another settings window',function()
    local h,S,F,C=Calibration(true);local panel=assert(C.colorPanel,'HUD adjustment does not directly expose color fields')
    assert(panel.root.root.parent==C.panel,'colors belong to a separate surface')
    assert(panel.rows.buffTime.row.visible and panel.rows.buffStacks.row.visible)
    assert(not panel.rows.classText.row.visible and panel.visibleRowCount==2)
    assert(not h.buttons.v3_buff_hud_calibration_colors,'legacy extra color window entry remains')
    local bottom=panel.root.y+panel.root.height
    assert(panel.root.x>=126 and panel.root.x+panel.root.width<=420)
    assert(bottom<=C.enabledButton.y and C.enabledButton.y+C.enabledButton.height<=C.statusLabel.y,'Buff colors overlap apply or status controls')
    assert(C.anchorHint.shown==false or C.anchorHint.y>=C.enabledButton.y+C.enabledButton.height,'anchor hint overlaps inline color actions')
    assert(C:SetComponent('gearScore'));assert(panel.visibleRowCount==1 and panel.rows.gearScore.row.visible)
    assert(not panel.rows.buffTime.row.visible)
    local writes=h.writes;local field=panel.fields.gearScore
    C.inputs.x:SetText('987')
    field:BeginDraft();field.hexInput.root:SetText('#258FDB');assert(field:ApplyDraft())
    assert(h.writes==writes and F:GetHudColor('player','gearScore')==1 and Same(C.colorDraft.player.gearScore[1],37/255))
    assert(C.inputs.x:GetText()=='987','applying a color erased unsubmitted geometry input')
    assert(C:SetComponent('mainHand'));assert(panel.visibleRowCount==0 and panel.root.visible==false)
    assert(C:Exit(false));assert(F:GetHudColor('player','gearScore')==1 and h.writes==writes)
end)
Test('inline colors fit every HUD component and switching scope cancels the open picker',function()
    local h,S,F,C=Calibration(true);local panel=C.colorPanel;local created=h.createdButtons
    for _,scope in ipairs({'player','target'})do
        assert(C:SetScope(scope))
        for _,key in ipairs({'buffs','debuffs','cooldowns','info','gearScore','distance','castBar','class','mainHand'})do
            assert(C:SetComponent(key))
            if panel.visibleRowCount>0 then
                assert(panel.root.y+panel.root.height<=C.enabledButton.y,'colors overlap actions for '..key)
                assert(C.enabledButton.y+C.enabledButton.height<=C.statusLabel.y)
            end
        end
    end
    assert(C:SetScope('player'));assert(C:SetComponent('gearScore'))
    local field=panel.fields.gearScore;local opened,openErr=field:Open();assert(opened,'inline color button cannot open its picker: '..tostring(openErr))
    assert(field.hexInput:BeginEditing('inline_test'));field.hexInput.root:SetText('#258FDB')
    assert(C:SetScope('target'));assert(not field.open and not field.hexInput:HasDraftSession())
    assert(F:GetHudColor('player','gearScore')==1 and C.colorDraft.player.gearScore[1]==1)
    assert(C:SetComponent('alias'));assert(panel.rows.alias.row.visible and panel.visibleRowCount==1)
    assert(C:SetComponent('info'));local writes=h.writes
    assert(C.colorPreset:SetValue('contrast'))
    assert(C.colorDraft.target.classText[1]==0 and C.colorDraft.target.classText[2]==1)
    assert(C.colorDraft.player.classText[1]==1 and C.colorDraft.target.gearScore[1]==1 and h.writes==writes)
    assert(h.createdButtons==created,'switching components recreated color widgets')
    assert(C:Exit(false));assert(C:Open());assert(C.colorPanel==panel)
    assert(C:Exit(false))
end)
Test('Native preset clicks immediately recolor each supported HUD preview without saving',function()
    local h,S,F,C=Calibration(true);local writes=h.writes
    local function Signature(color)return string.format('%.6f,%.6f,%.6f',color[1],color[2],color[3])end
    for _,scope in ipairs({'player','target'})do
        assert(C:SetScope(scope))
        for _,component in ipairs({'buffs','debuffs','cooldowns','info','gearScore','distance','castBar','alias'})do
            if component~='alias'or scope=='target'then
                assert(C:SetComponent(component));local seen={}
                for index,name in ipairs({'recommended','white','contrast'})do
                    local dropdown=C.colorPreset;assert(dropdown:Open())
                    local option=dropdown.optionButtons[index]
                    assert(option.events.OnClick(option,'LeftButton'),'native preset click failed')
                    assert(not dropdown.open and C.component==component and C.scope==scope)
                    local palette=F:GetHudColorPreset(name)
                    for key,row in pairs(C.colorPanel.rows)do
                        if row.row.visible then
                            local actual
                            if component=='buffs'or component=='debuffs'or component=='cooldowns'then
                                actual=key:find('Stacks',1,true)and C.preview.icons[1].stack or C.preview.icons[1].time
                            else actual=component=='castBar'and C.preview.castText or C.preview.infoLabel end
                            assert(actual and actual.color,'no rendered color for '..component)
                            assert(actual.shown and actual:GetText()~='','the colored preview text is not visible: '..component)
                            assert(Signature(actual.color)==Signature(palette[key]),'preview did not update immediately: '..component..' '..name)
                            seen[key]=seen[key]or {}
                            assert(not seen[key][Signature(actual.color)],'preset makes no visible change: '..component..' '..key..' '..name)
                            seen[key][Signature(actual.color)]=true
                        end
                    end
                    assert(h.writes==writes,'preset selection wrote the persistent store')
                    assert(F:GetHudColor(scope,'buffTime')==1)
                end
            end
        end
    end
    assert(C:Exit(false));assert(h.writes==writes)
end)
Test('calibration colors stay in the draft and cancellation performs no writes',function()
    local h,S,F,C=Calibration();local writes=h.writes
    assert(C:ApplyColorPatch({target={gearScore={0.2,0.4,0.6}}}))
    assert(F:GetHudColor('target','gearScore')==1 and C.colorDraft.target.gearScore[1]==0.2)
    assert(C:Exit(false));assert(h.writes==writes and F:GetHudColor('target','gearScore')==1)
    assert(C:Open());assert(C.colorDraft.target.gearScore[1]==1);assert(C:Exit(false))
end)
Test('calibration saves arbitrary colors without requiring a geometry change',function()
    local h,S,F,C=Calibration(true);assert(C:SetComponent('distance'))
    local field=C.colorPanel.fields.distance
    field:BeginDraft();field.hexInput.root:SetText('#336699');assert(field:ApplyDraft())
    local writes=h.writes;local text=table.concat(C:BuildTemplateSnapshotLines(),'\n')
    assert(text:find('|PLAYER|COLORS|',1,true)and text:find('distance=336699',1,true),'layout template omitted the color draft')
    assert(h.writes==writes,'exporting the draft saved its colors')
    assert(C:Exit(true));assert(Same(F:GetHudColor('player','distance'),0.2))
end)
Test('geometry failure rolls colors back and retains the editable draft',function()
    local h,S,F,C=Calibration();assert(C:ApplyColorPatch({player={distance={0.2,0.4,0.6}}}))
    C.layoutDirty=true
    F.Commands.PersistHudCalibrationSnapshot=function()return false,'geometry_rejected'end
    local ok,err=C:Exit(true)
    assert(ok==false and err=='geometry_rejected' and C.visible==true and C.colorDraft)
    assert(F:GetHudColor('player','distance')==1,'failed geometry left half the draft committed')
    assert(C:Exit(false))
end)
Test('malformed sharing colors are rejected at preview and do not modify any store',function()
    local h,S,F=Boot();assert(F:EnsureStoreLoaded());local writes=h.io.writes
    local bad=F:ParseImportText('VERSION=8\nFORMAT=replicatedsuite.buff_display.v3\nPLAYER_BUFF=123\nHUDCOLOR=target:gearScore:NOTHEX')
    assert(#bad.errors>0 and F:ImportAll(bad.data,'merge')==false and h.io.writes==writes)
    local ok=F:PreviewImport({colors={target={gearScore={0/0,0,1}}}},'merge');assert(ok==false)
end)
Test('import failure compensates the independent color store',function()
    local h,S,F=Boot();assert(F:EnsureStoreLoaded())
    local save=S.Api.SaveData
    S.Api.SaveData=function(self,key,value)
        if not key:find('buff_display_colors',1,true)then return false,'other_store_rejected'end
        return save(self,key,value)
    end
    local ok,err=F:ImportAll({tracked={player={buff={123},debuff={},auto={}},target={buff={},debuff={},auto={}}},
        colors={target={gearScore={0.2,0.4,0.6}}}},'merge')
    assert(ok==false and err and F:GetHudColor('target','gearScore')==1,'failed import retained half the new colors')
end)
local function DistanceRules()
    return {{meters=22,color={1,1,1}},{meters=5,color={1,0,0}},{meters=15,color={1,1,0}}}
end
Test('distance upper thresholds use raw meters at boundaries and survive reload',function()
    local h,S,F=Boot()
    assert(F:PersistHudColors({target={distanceRules=DistanceRules()}}))
    for _,case in ipairs({{0,1,0,0},{4.99,1,0,0},{5,1,0,0},{5.01,1,1,0},{14.99,1,1,0},
        {15,1,1,0},{15.01,1,1,1},{21.99,1,1,1},{22,1,1,1},{22.01,1,1,1},{9999,1,1,1}})do
        local r,g,b=F:GetHudColor('target','distance',case[1])
        assert(r==case[2]and g==case[3]and b==case[4],'wrong range at '..case[1])
    end
    assert(F:GetHudColor('player','distance',15)==1)
    local _,_,F2=Boot(h.disk)
    local _,g,b=F2:GetHudColor('target','distance',15);assert(g==1 and b==0)
    local copy=F2:GetHudColorsProjection();copy.target.distanceRules[1].color[1]=0
    assert(F2:GetHudColor('target','distance',5)==1)
end)
Test('invalid distance rules never save and empty arrays restore fixed color',function()
    local h,S,F=Boot();local writes=h.io.writes
    for _,rules in ipairs({{{meters=-1,color={1,0,0}}},{{meters=0/0,color={1,0,0}}},
        {{meters=math.huge,color={1,0,0}}},{{meters=5,color={1,0,0}},{meters=5,color={1,1,0}}},
        {{meters=5,color={2,0,0}}},{[2]={meters=5,color={1,0,0}}}})do
        assert(F:PersistHudColors({target={distanceRules=rules}})==false)
    end
    assert(h.io.writes==writes)
    assert(F:PersistHudColors({target={distance={0.2,0.4,0.6},distanceRules=DistanceRules()}}))
    S.Api.SaveData=function()return false,'range_disk_rejected'end
    assert(F:PersistHudColors({target={distanceRules={}}})==false)
    local _,_,b=F:GetHudColor('target','distance',15);assert(b==0,'failed save retained the new range array')
end)
Test('distance rules round trip with full sharing and can be explicitly cleared',function()
    local _,_,F=Boot();assert(F:EnsureStoreLoaded())
    assert(F:PersistHudColors({target={distanceRules=DistanceRules()}}))
    local text=F:SerializeExport(F:ExportAll());local parsed=F:ParseImportText(text)
    assert(#parsed.errors==0,table.concat(parsed.errors,';'))
    assert(#parsed.data.colors.target.distanceRules==3)
    assert(F:PersistHudColors({target={distanceRules={}}}))
    assert(F:ImportAll(parsed.data,'merge'))
    local _,_,b=F:GetHudColor('target','distance',15);assert(b==0)
    assert(not F:SerializeExport(F:ExportAll('tracking')):find('HUDDISTANCE=',1,true))
    local bad=F:ParseImportText(text..'\nHUDDISTANCE=target:15:00FF00')
    assert(#bad.errors>0 and F:ImportAll(bad.data,'merge')==false)
end)
Test('same-width distance changes recolor the real partial HUD renderer',function()
    local h,S,F,P=dofile('tools/rs_pvp_hud_test_host.lua')({runtimeHud=true})
    dofile('features/combat/buff_display/rs_buff_display_colors.lua');assert(F:EnsureHudColorsLoaded())
    S.UI.SetColor=function(_,widget,r,g,b,a)widget.customColor={r,g,b,a};return true end
    assert(F:PersistHudColors({target={distanceRules=DistanceRules()}}))
    F.laneData.target.distance=4.9;P:VisualTick(true)
    local root=P.pools.target.info.distanceRoot;assert(root.customColor[2]==0)
    local builds=P.motionMetrics.contentBuilds
    F.laneData.target.distance=5.1;S.Events:Publish('v3.buff_display.plates.updated','distance');P:MotionTick()
    assert(root.customColor[2]==1 and root.customColor[3]==0,'partial update did not change range color')
    assert(P.motionMetrics.contentBuilds==builds,'range crossing rebuilt all HUD components')
end)
Test('self-target hides the entire target HUD and motion does not reshow it',function()
    local h,S,F,P=dofile('tools/rs_pvp_hud_test_host.lua')({runtimeHud=true})
    local old=X2Unit;X2Unit={};local selfTarget=true
    S.Api.CallCapability=function(_,key,object,method,scope)
        if method=='GetUnitId'then return true,(scope=='player'or selfTarget)and '101'or '202'end
        if method=='UnitName'then return true,selfTarget and 'Self'or 'Other'end
        return false
    end
    F.laneData.target.distance=10;F.laneData.player.gearScore=12345
    assert(F:RefreshTargetAliasIdentity('self_test'));P:VisualTick(true);P:MotionTick()
    assert(P.pools.target.root.shown==false,'self target HUD remains visible')
    assert(P.pools.player.root.shown==true,'self HUD was hidden together with target')
    P:MotionTick();assert(P.pools.target.root.shown==false)
    selfTarget=false;assert(F:RefreshTargetAliasIdentity('other_test'));P:VisualTick(true);P:MotionTick()
    assert(P.pools.target.root.shown==true,'other target HUD did not recover')
    X2Unit=old
end)
Test('inline distance array editing previews without saving and fits the calibration panel',function()
    local h,S,F,C=Calibration(true);assert(C:SetScope('target'));assert(C:SetComponent('distance'))
    local ranges=assert(C.distanceColorPanel,'no distance array editor in the selected component')
    local writes=h.writes;assert(ranges:UseExamples())
    assert(#C.colorDraft.target.distanceRules==3 and h.writes==writes)
    assert(ranges.root.y+ranges.root.height<=C.enabledButton.y)
    assert(C.enabledButton.y+C.enabledButton.height<=C.statusLabel.y,'range editor overlaps status')
    assert(ranges:Select(2));assert(ranges:Update(16,{0.2,0.4,0.6}))
    assert(C.colorDraft.target.distanceRules[2].meters==16)
    assert(ranges:Add());assert(#C.colorDraft.target.distanceRules==4)
    assert(ranges:Delete());assert(#C.colorDraft.target.distanceRules==3)
    assert(C:Exit(false));assert(h.writes==writes and #F:GetHudColorsProjection().target.distanceRules==0)
    assert(C:Open());assert(C:SetScope('target'));assert(C:SetComponent('distance'))
    assert(C.distanceColorPanel:UseExamples());assert(C:Exit(true))
    local _,_,b=F:GetHudColor('target','distance',15);assert(b==0)
end)
Test('schema1 colors migrate without changing old RGB or recent choices',function()
    local h,S,F=Boot();local legacy={player={},target={},recent={'123456'}}
    for _,scope in ipairs({'player','target'})do
        for _,definition in ipairs(F:GetHudColorDefinitions())do legacy[scope][definition.key]='FFFFFF'end
    end
    legacy.target.distance='336699';legacy.player.buffTime='123456'
    local store=S.Persistence:GetStore(F.HudColorsStoreId)
    -- 真实 schema1 没有 migrate，不能用当前 normalizer 给“旧档”盖上新结构指纹。
    store.schemaVersion=1;store.migrate=nil;store.rebuildCanonicalForIntegrity=nil;store.get=function()return legacy end
    assert(S.Persistence:SaveStore(F.HudColorsStoreId))
    local _,S2,F2=Boot(h.disk)
    assert(S2.Persistence:GetStore(F2.HudColorsStoreId).schemaVersion==2)
    local r,g,b=F2:GetHudColor('target','distance',15)
    assert(Same(r,0.2)and Same(g,0.4)and Same(b,0.6))
    assert(#F2:GetHudColorsProjection().target.distanceRules==0)
    assert(Same(F2:GetRecentHudColors()[1][1],18/255))
    local disk=S.Utils.DeepCopy(h.disk);local tampered=false
    for _,raw in pairs(disk)do
        if type(raw)=='table'and type(raw.__rsmeta)=='table'and raw.__rsmeta.store==F.HudColorsStoreId then
            raw.payload.target.distance='000000';tampered=true
        end
    end
    assert(tampered,'legacy fixture did not contain the saved color envelope')
    local _,S3,F3=dofile('tools/rs_pvp_hud_test_host.lua')({disk=disk})
    dofile('features/combat/buff_display/rs_buff_display_colors.lua')
    assert(F3:EnsureHudColorsLoaded()==false,'legacy recovery accepted a changed old RGB without its old fingerprint')
    assert(S3.Persistence:GetStore(F3.HudColorsStoreId).writeFenced)
end)
Test('real distance inputs reorder rules, reject duplicates and cancel across scopes',function()
    local h,S,F,C=Calibration(true);assert(C:SetScope('target'));assert(C:SetComponent('distance'))
    local panel=C.distanceColorPanel;local writes=h.writes
    assert(panel:UseExamples())
    assert(C.preview.infoLabel:GetText()=='15m'and C.preview.infoLabel.color[2]==1 and C.preview.infoLabel.color[3]==0,'example selection preview is stale')
    assert(panel.selector:Open());local option=panel.selector.optionButtons[1]
    assert(option.events.OnClick(option,'LeftButton'));assert(panel.index==1 and C.preview.infoLabel:GetText()=='5m')
    panel.input.root:SetText('18');assert(panel.input:Submit('enter'))
    assert(panel.index==2 and C.colorDraft.target.distanceRules[2].meters==18)
    panel.color:BeginDraft();panel.color.hexInput.root:SetText('#336699');assert(panel.color:ApplyDraft())
    local row=C.colorDraft.target.distanceRules[2]
    assert(Same(row.color[1],0.2)and Same(row.color[2],0.4)and Same(row.color[3],0.6))
    assert(C.preview.infoLabel:GetText()=='18m'and Same(C.preview.infoLabel.color[3],0.6))
    panel.input.root:SetText('22');assert(panel.input:Submit('enter')==false)
    assert(C.colorDraft.target.distanceRules[2].meters==18)
    assert(panel.color:Open());assert(panel.color.hexInput:BeginEditing('range_scope'));panel.color.hexInput.root:SetText('#ABCDEF')
    assert(C:SetScope('player'));assert(not panel.color.open and not panel.color.hexInput:HasDraftSession())
    assert(#C.colorDraft.player.distanceRules==0 and h.writes==writes)
    assert(C:SetScope('target'));assert(C:SetComponent('distance'));assert(C:ResetCurrentComponent())
    assert(#C.colorDraft.target.distanceRules==0,'reset distance retained dynamic rules')
    assert(C:Exit(false))
end)
Test('native Apply button commits pending distance before refresh with either focus order',function()
    for _,blurFirst in ipairs({false,true})do
        local h,S,F,C=Calibration(true);assert(C:SetScope('target'));assert(C:SetComponent('distance'))
        local panel=C.distanceColorPanel;assert(panel:UseExamples());assert(panel:Select(3));assert(panel:Delete());assert(panel:Select(2))
        local writes=h.writes;assert(panel.input:BeginEditing('distance_apply'))
        panel.input.root:SetText('22')
        if blurFirst then
            assert(panel.input:SuspendEditing('distance_apply_blur'))
            panel.input.root:SetText('15') -- Native失焦重绘不能覆盖Lua持有的新阈值。
        end
        assert(h:Click('v3_buff_hud_calibration_apply_inputs'))
        assert(C.colorDraft.target.distanceRules[2].meters==22,'Apply ignored the pending distance input')
        assert(panel.input.root:GetText()=='22'and h.writes==writes)
        assert(C:Exit(true));assert(F:GetHudColorsProjection().target.distanceRules[2].meters==22)
    end
end)
Test('duplicate distance Apply reports the conflict and preserves the typed input',function()
    local h,S,F,C=Calibration(true);assert(C:SetScope('target'));assert(C:SetComponent('distance'))
    local panel=C.distanceColorPanel;assert(panel:UseExamples());local writes=h.writes
    assert(panel.input:BeginEditing('distance_duplicate'));panel.input.root:SetText('22')
    local ok,err=h:Click('v3_buff_hud_calibration_apply_inputs')
    assert(ok==false and tostring(err):find('22',1,true),'duplicate Apply was treated as success')
    assert(panel.input:GetDraftNumber()==22,'rejected Apply silently restored 15m')
    assert(C.colorDraft.target.distanceRules[2].meters==15 and h.writes==writes)
    assert(C.statusLabel:GetText():find('22',1,true),'duplicate threshold has no visible feedback')
    assert(C:Exit(false))
end)
Test('color picker Apply consumes the pending distance together with the selected RGB',function()
    local h,S,F,C=Calibration(true);assert(C:SetScope('target'));assert(C:SetComponent('distance'))
    local panel=C.distanceColorPanel;assert(panel:UseExamples());assert(panel:Select(3));assert(panel:Delete());assert(panel:Select(2))
    local writes=h.writes;assert(panel.input:BeginEditing('distance_color_apply'));panel.input.root:SetText('22')
    assert(panel.input:SuspendEditing('distance_color_blur'));panel.input.root:SetText('15')
    panel.color:BeginDraft();panel.color.hexInput.root:SetText('#336699');assert(panel.color:ApplyDraft())
    local row=C.colorDraft.target.distanceRules[2]
    assert(row.meters==22 and Same(row.color[1],0.2)and Same(row.color[3],0.6),'color Apply lost the pending threshold')
    assert(h.writes==writes);assert(C:Exit(false))
end)
Test('save and exit consumes an unsubmitted distance without depending on blur',function()
    local h,S,F,C=Calibration(true);assert(C:SetScope('target'));assert(C:SetComponent('distance'))
    local panel=C.distanceColorPanel;assert(panel:UseExamples());assert(panel:Select(3));assert(panel:Delete());assert(panel:Select(2))
    assert(panel.input:BeginEditing('distance_save'));panel.input.root:SetText('22')
    assert(C:Exit(true));assert(F:GetHudColorsProjection().target.distanceRules[2].meters==22)
end)
Test('distance editor displays plain digits and places the unit beside the input',function()
    local h,S,F,C=Calibration(true);assert(C:SetScope('target'));assert(C:SetComponent('distance'))
    local panel=C.distanceColorPanel;assert(panel:UseExamples())
    assert(panel.input.root:GetText()=='15','distance unit remains inside the editable text')
    assert(panel.unit and panel.unit.root:GetText()=='米','distance unit is not visible beside the input')
    assert(panel.unit.x>=panel.input.x+panel.input.width,'unit overlaps the numeric input')
    assert(panel.color.x+panel.color.width<=282,'separate unit pushed color picker outside the editor')
    assert(C:Exit(false))
end)
Test('every visible HUD calibration numeric row has its own reachable Apply button',function()
    local h,S,F,C=Calibration(true)
    for _,scope in ipairs({'player','target'})do
        assert(C:SetScope(scope))
        for _,key in ipairs({'plate','buffs','debuffs','cooldowns','info','gearScore','distance','class','mainHand','offHand','ranged','wings','castBar'})do
            assert(C:SetComponent(key))
            for name,row in pairs(C.fieldRows)do
                assert(row.apply,'numeric row has no Apply: '..name)
                assert(row.apply.shown==row.edit.shown,'Apply visibility differs from its input')
                if row.edit.shown then
                    assert(row.apply.x>=row.plus.x+row.plus.width and row.apply.x+row.apply.width<=420)
                    assert(row.apply.y==row.edit.y and row.apply.y+row.apply.height<=C.enabledButton.y)
                end
            end
        end
    end
    assert(C:Exit(false))
end)
Test('HUD row Apply consumes latest Native text before blur and only previews until Save',function()
    for _,key in ipairs({'buffs','debuffs','cooldowns','castBar','gearScore'})do
        local h,S,F,C=Calibration(true);assert(C:SetComponent(key))
        local name=key=='gearScore'and 'font'or 'size';local value=key=='gearScore'and 19 or 33
        local writes=h.writes;C.inputs[name]:SetText(tostring(value))
        assert(h:Click('v3_buff_hud_calibration_apply_'..name))
        local draft=C.draft.player.components[key]
        assert((name=='font'and draft.fontSize or draft.size)==value,'row Apply ignored its input')
        assert(h.writes==writes,'row Apply wrote persistent settings')
        assert(C:Exit(false));assert(h.writes==writes,'cancel persisted the preview')
    end
end)
Test('HUD Save consumes unsubmitted geometry and invalid text keeps the editor open',function()
    for _,key in ipairs({'buffs','debuffs','cooldowns'})do
        local h,S,F,C=Calibration(true);assert(C:SetScope('target'));assert(C:SetComponent(key))
        C.inputs.size:SetText('35');C.inputs.perRow:SetText('11');C.inputs.alpha:SetText('0.65')
        assert(C:Exit(true))
        local saved=F.Commands:GetHudCalibrationSnapshot().target.components[key]
        assert(saved.size==35 and saved.maxPerRow==11 and Same(saved.alpha,0.65),'Save discarded pending numeric inputs')
    end
    local h,S,F,C=Calibration(true);local writes=h.writes;local old=C.draft.player.components.buffs.size
    C.inputs.size:SetText('35');C.inputs.font:SetText('')
    local ok,err=C:Exit(true)
    assert(ok==false and C.visible and err,'invalid pending geometry silently closed the editor')
    assert(h.writes==writes and C.draft.player.components.buffs.size==old,'invalid form partially committed')
    assert(C.inputs.size:GetText()=='35'and C.inputs.font:GetText()=='','rejected Save erased pending text')
    assert(C:Exit(false))
end)
local function CalibrationInputDiff()
    local h,S,F,C=Calibration(true)
    dofile('ui/rs_ui_framework.lua');GetFocusedWidgetId=nil
    for _,input in pairs(C.inputControls or {})do
        local n=input.root;n.rsUiKeyboardInput=true
        function n:EnableKeyboard(value)self.keyboard=value end
        function n:SetFocus()error('numeric buffer observation must not request focus')end
        function n:ClearFocus()error('unknown focus must not be cleared')end
        assert(S.UI:AdoptV3Widget(n,input.owner,input.id))
        S.UI:PrimeNativeState(n,{text=n.text,visible=n.shown,enabled=true})
    end
    return h,S,F,C
end
Test('real calibration input drafts survive refresh and applying another row without focus APIs',function()
    local h,S,F,C=CalibrationInputDiff();local writes=h.writes;local oldX=C.draft.player.components.buffs.x
    C.inputs.x:SetText('123');C.inputs.size:SetText('33');assert(C:RefreshControls())
    assert(C.inputs.x:GetText()=='123'and C.inputs.size:GetText()=='33','refresh erased Native numeric drafts')
    assert(h:Click('v3_buff_hud_calibration_apply_size'))
    assert(C.draft.player.components.buffs.size==33 and C.draft.player.components.buffs.x==oldX)
    assert(C.inputs.x:GetText()=='123','single-row Apply erased another pending field')
    C.inputs.x.events.OnLostFocus()
    assert(h:Click('v3_buff_hud_calibration_apply_x')and C.draft.player.components.buffs.x==123)
    assert(S.UI:GetAuthoritySnapshot().violations==0 and h.writes==writes)
    assert(C:Exit(false));assert(h.writes==writes)
end)
Test('switching HUD contexts and restoring layouts cancel old numeric drafts',function()
    local h,S,F,C=CalibrationInputDiff();local writes=h.writes
    C.inputs.size:SetText('41');assert(C:RefreshControls());assert(C.inputControls.size:HasDraftSession())
    assert(C:SetComponent('debuffs'))
    assert(not C.inputControls.size:HasDraftSession()and tonumber(C.inputs.size:GetText())==C.draft.player.components.debuffs.size)
    C.inputs.size:SetText('42');assert(C:RefreshControls());assert(C:ResetCurrentComponent())
    assert(not C.inputControls.size:HasDraftSession()and tonumber(C.inputs.size:GetText())==C.draft.player.components.debuffs.size)
    C.inputs.size:SetText('43');assert(C:RefreshControls());assert(C:SetScope('target'))
    assert(not C.inputControls.size:HasDraftSession()and tonumber(C.inputs.size:GetText())==C.draft.target.components.debuffs.size)
    C.inputs.size:SetText('44');assert(C:RefreshControls());assert(C:ApplyLayoutPreset('original'))
    assert(not C.inputControls.size:HasDraftSession()and tonumber(C.inputs.size:GetText())==C.draft.target.components.debuffs.size)
    assert(C:Exit(false));assert(C:Open());assert(not C.inputControls.size:HasDraftSession())
    assert(C:Exit(false));assert(h.writes==writes)
end)
Test('numeric step buttons start from pending text and unchanged display precision does not rewrite the draft',function()
    local h,S,F,C=CalibrationInputDiff();local writes=h.writes
    C.inputs.size:SetText('22');assert(h:Click('v3_buff_hud_calibration_plus_size'))
    assert(C.draft.player.components.buffs.size==23 and C.inputs.size:GetText()=='23')
    C.draft.player.plateScale=1.337;assert(C:RefreshControls(true))
    C.inputs.size:SetText('34');assert(C:ApplyInputFields())
    assert(C.draft.player.plateScale==1.337,'unchanged rounded scale was rewritten during Apply')
    assert(C.draft.player.components.buffs.size==34 and S.UI:GetAuthoritySnapshot().violations==0)
    assert(C:Exit(false));assert(h.writes==writes)
end)
Test('failed coordinate nudge validates both fields before changing a calibration draft',function()
    local h,S,F,C=CalibrationInputDiff();local old=C.draft.player.components.buffs.x
    C.inputs.x:SetText('12');C.inputs.y:SetText('')
    local ok,err=C:Nudge(1,0)
    assert(ok==false and err and C.draft.player.components.buffs.x==old,'failed nudge partially applied X')
    assert(C.inputs.x:GetText()=='12'and C.inputs.y:GetText()=='','failed nudge erased the input')
    assert(C:SetComponent('debuffs'));assert(C:Exit(true))
    assert(F.Commands:GetHudCalibrationSnapshot().player.components.buffs.x==old,'failed nudge leaked into saved geometry')
end)
print(string.format('HUD COLORS RESULT %d passed / %d failed',passed,failed))
assert(failed==0,'HUD color regressions failed')
