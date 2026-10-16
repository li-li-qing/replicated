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
print(string.format('HUD COLORS RESULT %d passed / %d failed',passed,failed))
assert(failed==0,'HUD color regressions failed')
