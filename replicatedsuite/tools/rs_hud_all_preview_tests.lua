-- Real BuffDisplay stores, calibration, marker geometry and commands. Native drawing uses the existing test host.
local passed,failed=0,0
local function Eq(a,b)
    if type(a)~=type(b) then return false end
    if type(a)~='table' then return a==b end
    for key,value in pairs(a)do if not Eq(value,b[key])then return false end end
    for key in pairs(b)do if a[key]==nil then return false end end
    return true
end
local function Test(name,fn)
    local ok,err=xpcall(fn,debug.traceback)
    if ok then passed=passed+1;print('PASS hud-all-preview '..name)
    else failed=failed+1;print('FAIL hud-all-preview '..name..': '..tostring(err))end
end
local function Boot(scale,failSelectedDetails)
    local h=dofile('tools/rs_gear_page_test_host.lua')();local S=h.S
    UIParent=h.Native(nil,'screen',0,0,2560,1440)
    S.Api.GetUiMetrics=function()return 2560,1440,1,2560,1440 end
    S.UI.CreateWindowShell=function()return nil,'test_no_window'end
    S.UI.SetAlpha=function(_,n,a)n.alpha=a;return true end
    S.UI.SetColor=function(_,n,r,g,b,a)n.color={r,g,b,a};return true end
    S.UI.SetFontSize=function(_,n,a)n.fontSize=a;return true end
    S.UI.SetButtonActive=function(_,n,v)n.active=v;return true end
    S.UI.CreateIconDrawable=function(_,n,path)local d=h.Native(n,n.id..'_icon',0,0,1,1);d.texture=path;return d end
    S.UI.SetIconTexture=function(_,n,path)n.texture=path;return true end
    S.UI.EnsureIconTexture=function(_,n,path)
        if h.rejectTexture==path then n.texture=nil;return false,false,'test_rejected' end
        n.texture=path;return true,true
    end
    local anchor=S.UI.SetAnchor
    S.UI.SetAnchor=function(self,n,...)n.anchored=true;return anchor(self,n,...)end
    S.UI.BeginNativeGeometryLease=function(_,n)n.leased=true;return true end
    S.UI.EndNativeGeometryLease=function(_,n)n.leased=false;return true end
    h.natives={}
    for _,method in ipairs({'CreateLabel','CreateButton','CreateEditBox'})do
        local original=S.UI[method]
        S.UI[method]=function(self,...)
            local n=original(self,...);if n then h.natives[#h.natives+1]=n end;return n
        end
    end
    S.Layout={GetWindowLogicalRect=function(_,n)return n.x,n.y,n.width,n.height,{effectiveScale=1}end,
        GetContext=function()return {}end,MakeSignature=function()return 'test-viewport'end}
    local create=S.UI.CreateEmptyWidget
    S.UI.CreateEmptyWidget=function(self,...)
        local n=create(self,...)
        h.natives[#h.natives+1]=n
        function n:EnableDrag(v)self.dragEnabled=v end
        function n:StartMoving()self.moving=true end
        function n:StopMovingOrSizing()self.moving=false end
        function n:Raise()self.raised=true end
        function n:CreateIconDrawable()
            local d=h.Native(self,self.id..'_icon',0,0,1,1);d.anchored=false
            function d:AddAnchor(_,p,x,y)self.parent=p;self.x=x;self.y=y;self.anchored=true end
            function d:RemoveAllAnchors()self.anchored=false end
            return d
        end
        function n:CreateColorDrawable(r,g,b,a)
            local d=h.Native(self,self.id..'_fill',0,0,1,1);d.color={r,g,b,a};return d
        end
        return n
    end
    for _,path in ipairs({'data/rs_data_registry.lua','data/rs_skill_effects.lua','data/rs_combat_ability_catalog.lua',
        'data/ids/rs_buff_ids.lua','data/ids/rs_plates_ids.lua','services/rs_status_classification_v3.lua',
        'data/rs_status_tracking_catalog.lua','core/rs_demand.lua','ui/framework/rs_ui_floating_surface.lua',
        'features/combat/buff_display/rs_buff_display_store.lua','features/combat/buff_display/rs_buff_display_projection.lua',
        'features/combat/buff_display/rs_buff_display_feature.lua','features/combat/buff_display/rs_buff_display_management.lua',
        'features/combat/buff_display/rs_buff_display_alias_store.lua',
        'presentation/v3/widgets/rs_v3_buff_head_markers.lua','presentation/v3/widgets/rs_v3_buff_hud_calibration.lua'})do dofile(path)end
    local F=S.Features.BuffDisplay;assert(F:EnsureStoreLoaded())
    F.GetPlatesAnchor=function(_,scope)return scope=='target' and 1740 or 1280,680 end
    -- Calibration must never start an observation lane or ask Native for simulated cooldowns.
    h.F=F;h.C=S.UIV3.BuffHudCalibrationV3
    if failSelectedDetails then
        local createLabel=S.UI.CreateLabel
        S.UI.CreateLabel=function(self,parent,id,...)
            if id=='v3_buff_hud_calibration_preview_2_fallback' then return nil,'test_rejected' end
            return createLabel(self,parent,id,...)
        end
        assert(h.C:Open({scope='player'})==false,'selected detail rejection was ignored')
        S.UI.CreateLabel=createLabel
    else assert(h.C:Open({scope='player'})) end
    if scale then h.C.draft.player.plateScale=scale;h.C.draft.target.plateScale=scale end
    function h:All()local b=assert(self.C.allPreviewButton,'show-all button missing');return b.events.OnClick(b,'LeftButton')end
    function h:AssertAll(scope)
        for _,key in ipairs({'plate','buffs','debuffs','cooldowns','info','gearScore','distance','class','mainHand','offHand','ranged','wings','castBar','alias'})do
            local item=assert(self.C.globalPreview.items[key])
            if key=='alias' and scope~='target' then assert(item.root.shown==false,'target alias leaked into own HUD')
            elseif key==self.C.component then assert(item.root.shown==false and self.C.preview.root.shown,'selected preview duplicated')
            else
                assert(item.root.shown,'component hidden in all mode: '..key)
                local p=assert(item.preview,'full sample missing: '..key)
                if key=='buffs' or key=='debuffs' or key=='cooldowns' then
                    assert(p.icons[1].root.shown and p.icons[1].texture.texture,'icon simulation missing: '..key)
                elseif key=='info' or key=='gearScore' or key=='distance' or key=='alias' then
                    assert(p.infoLabel.shown and p.infoLabel.text~='','text simulation missing: '..key)
                elseif key=='castBar' then assert(p.castFill.shown and p.castFill.width>0,'cast simulation missing')
                elseif key~='plate' then assert(p.icons[1].root.shown and (p.icons[1].texture.texture or p.icons[1].fallback.shown),'single icon simulation missing: '..key)end
            end
        end
    end
    return h
end
local function TaskIds(h)
    local out={};for id in pairs(h.S.Scheduler.tasks)do out[id]=true end;return out
end
Test('button displays every own HUD simulation without changing draft or persistence',function()
    local h=Boot();local c=h.C;local before=c:GetDraftSnapshot();local writes,reads=h.writes,h.reads
    assert(h:All());assert(c.allPreviewEnabled==true and c.allPreviewButton.text=='单项模拟')
    h:AssertAll('player')
    assert(Eq(before,c:GetDraftSnapshot()) and not c.dirty,'show-all changed HUD configuration')
    assert(h.writes==writes and h.reads==reads,'show-all performed persistence IO')
end)
Test('selection and scope retain all simulations and target-only alias stays isolated',function()
    local h=Boot();assert(h:All());assert(h.C:SetComponent('plate'));h:AssertAll('player')
    assert(h.C:SetComponent('distance'));h:AssertAll('player')
    assert(h.C:SetScope('target'));h:AssertAll('target')
    assert(h.C:SetComponent('alias'));h:AssertAll('target')
    assert(h.C:SetScope('player') and h.C.component=='buffs');h:AssertAll('player')
end)
Test('disabled components still simulate without enabling saved configuration',function()
    local h=Boot();local c=h.C;local p=c.draft.player
    p.info.enabled=false;p.info.showClass=false;p.info.showGear=false;p.info.showDistance=false
    p.components.class.enabled=false;p.components.cooldowns.enabled=false;p.components.castBar.enabled=false
    local before=c:GetDraftSnapshot()
    assert(h:All());assert(c:SetComponent('plate'));h:AssertAll('player')
    assert(Eq(before,c:GetDraftSnapshot()) and not c.dirty,'simulation enabled real HUD items')
end)
Test('selected drag changes only its draft while other simulations remain visible',function()
    local h=Boot();assert(h:All());local c=h.C;assert(c:SetComponent('buffs'))
    local before=c:GetDraftSnapshot();local root=c.preview.root
    assert(root.events.OnDragStart());root.x=root.x+20;root.y=root.y+10
    assert(root.events.OnDragStop());h:AssertAll('player')
    assert(c.draft.player.components.buffs.x==before.player.components.buffs.x+20)
    assert(c.draft.player.components.buffs.y==before.player.components.buffs.y-10,'buff Y adapter lost')
    before.player.components.buffs.x=c.draft.player.components.buffs.x;before.player.components.buffs.y=c.draft.player.components.buffs.y
    assert(Eq(before,c:GetDraftSnapshot()),'drag moved sibling or target HUD')
    assert(not root.leased and not root.moving)
end)
Test('all preview respects scale and aura capacity',function()
    local h=Boot(1.5);local c=h.C;c.draft.player.components.debuffs.maxPerRow=2
    assert(h:All());local p=c.globalPreview.items.debuffs.preview
    assert(p.icons[1].root.width==math.floor(c.draft.player.components.debuffs.size*1.5),'icon scale differs from preview rectangle')
    assert(p.icons[2].root.shown and not p.icons[3].root.shown,'icons exceed simulated row capacity')
    local last=p.icons[2].root
    assert(last.x+last.width<=p.root.width,'simulated icons exceed component rectangle')
end)
Test('all simulation preserves independent full and compact gear formats',function()
    local h=Boot();local c=h.C
    c.draft.player.info.gearScoreFormat='compact';c.draft.target.info.gearScoreFormat='full'
    local before=c:GetDraftSnapshot()
    assert(h:All());assert(c:SetComponent('plate'))
    assert(c.globalPreview.items.gearScore.preview.infoLabel.text=='12.3K','compact gear simulation lost')
    assert(c:SetComponent('gearScore') and c.preview.infoLabel.text=='12.3K','selected compact sample differs from all sample')
    assert(c:SetScope('target') and c.preview.infoLabel.text=='12345','target full gear format changed')
    assert(Eq(before,c:GetDraftSnapshot()),'gear simulation changed scope format preferences')
end)
Test('toggle off and cancel hide simulations and preserve current settings',function()
    local h=Boot();local saved=h.F:GetHudCalibrationSnapshot();assert(h:All())
    assert(h:All() and not h.C.allPreviewEnabled)
    local p=h.C.globalPreview.items.cooldowns.preview;assert(not p.icons[1].root.shown,'full simulation remained after toggle off')
    assert(h:All());assert(h.C:SetComponent('distance'));assert(h.C:Nudge(10,0));local writes=h.writes
    assert(h.C:Exit(false));assert(h.writes==writes and Eq(saved,h.F:GetHudCalibrationSnapshot()),'cancel saved layout')
    for _,item in pairs(h.C.globalPreview.items)do assert(not item.root.shown,'preview leaked after exit')end
    assert(h.C:Open({scope='target'}) and not h.C.allPreviewEnabled,'show-all mode leaked into reopened calibration')
end)
Test('all simulations reuse widgets and start no observation or scheduler work',function()
    local h=Boot();local tasks=TaskIds(h);local consumers=h.F.consumerCount
    local get=h.F.GetPlatesProjection;local projectionReads=0
    h.F.GetPlatesProjection=function(self,scope)projectionReads=projectionReads+1;return get(self,scope)end
    h.F.GetProjection=function()error('calibration rescanned aura list separately')end
    assert(h:All());assert(h.C:SetComponent('plate'));assert(h.C:SetScope('target'))
    local created=#h.natives
    for i=1,20 do assert(h.C:SetComponent(i%2==0 and 'distance' or 'plate'))end
    assert(#h.natives==created,'refresh rebuilt simulation widgets')
    assert(Eq(tasks,TaskIds(h)) and h.F.consumerCount==consumers,'simulation started runtime work')
    assert(projectionReads==23,'cached projection should be read once per user refresh')
    assert(h.C:GetDiagnostics().simulatedComponents==14)
end)
Test('new button remains inside the panel and avoids existing controls in both scopes',function()
    local h=Boot();local c=h.C
    for _,scope in ipairs({'player','target'})do
        assert(c:SetScope(scope));local b=c.allPreviewButton
        assert(b.x>=0 and b.y>=0 and b.x+b.width<=c.panel.width and b.y+b.height<=c.panel.height)
        for _,n in ipairs(h.natives)do
            if n~=b and n.parent==c.panel and n.shown~=false and n.id~='v3_buff_hud_calibration_panel_drag_handle' then
                local overlaps=b.x<n.x+n.width and b.x+b.width>n.x and b.y<n.y+n.height and b.y+b.height>n.y
                assert(not overlaps,'new button overlaps '..n.id)
            end
        end
    end
end)
Test('saving all-preview layout keeps component edits and original enable settings',function()
    local h=Boot();local c=h.C;local old=h.F:GetHudCalibrationSnapshot()
    assert(h:All());assert(c:SetComponent('distance'));assert(c:Nudge(11,0));local writes=h.writes
    assert(c:Exit(true));assert(h.writes>writes,'layout was not durably saved')
    local saved=h.F:GetHudCalibrationSnapshot()
    assert(saved.player.components.distance.x==old.player.components.distance.x+11)
    old.player.components.distance.x=saved.player.components.distance.x
    assert(Eq(old,saved),'saving simulations changed unrelated layout or component enables')
    assert(not c:GetDiagnostics().allPreviewEnabled and c:GetDiagnostics().simulatedComponents==0)
end)
Test('partial sample creation failure returns to single mode and retries safely',function()
    local h=Boot();local create=h.S.UI.CreateEmptyWidget
    h.S.UI.CreateEmptyWidget=function(self,parent,id,...)
        if id=='v3_buff_hud_calibration_all_debuffs_icon_2' then return nil,'test_rejected'end
        return create(self,parent,id,...)
    end
    local before=h.C:GetDraftSnapshot();assert(h:All()==false and not h.C.allPreviewEnabled)
    assert(h.C:GetDiagnostics().lastAction=='all_preview_failed' and Eq(before,h.C:GetDraftSnapshot()))
    h.S.UI.CreateEmptyWidget=create;assert(h:All());h:AssertAll('player')
    assert(h.C:ToggleGlobalPreview() and not h.C.allPreviewEnabled,'global off left full simulation enabled')
    for _,item in pairs(h.C.globalPreview.items)do assert(not item.root.shown)end
end)
Test('equipment sample textures have explicit native anchors and no empty timer labels',function()
    local h=Boot();assert(h:All());assert(h.C:SetComponent('plate'))
    for _,key in ipairs({'mainHand','offHand','ranged','wings','class'})do
        local icon=h.C.globalPreview.items[key].preview.icons[1]
        assert(icon.texture.anchored==true and icon.texture.x==0 and icon.texture.y==0,'unanchored equipment texture: '..key)
        assert(icon.time.shown==false,'empty timer label visible: '..key)
    end
    assert(h.C:SetComponent('mainHand'))
    assert(h.C.preview.icons[1].texture.anchored and not h.C.preview.icons[1].time.shown,'selected equipment differs from all simulation')
end)
Test('all mode has no filled helper boxes or floating editor captions',function()
    local h=Boot();assert(h:All())
    assert(h.C.preview.caption.shown==false,'floating caption covers adjacent HUD content')
    assert(h.C.preview.bg.shown==false,'selected sample has an opaque helper rectangle')
    for key,item in pairs(h.C.globalPreview.items)do
        if item.root.shown then
            assert(item.bg.shown==false,'filled helper background remains: '..key)
            assert(item.label.shown==false,'global reference text remains: '..key)
        end
    end
end)
Test('full simulation retains cached scope content with stacks grades and skill cooldowns',function()
    local h=Boot();local F=h.F
    F.State.settings.headShowAll=true;F:InvalidateSettingsCache()
    F.laneData.player={class={name='我的职业',icon='cached-class.dds'},gearScore=18765,distance=8.5,
        mainHand={icon='cached-sword.dds',gradeIconPath='cached-grade.dds'},offHand={icon='cached-shield.dds'},
        ranged={icon='cached-bow.dds'},wings={icon='cached-wings.dds'},
        buffRows={{id=11,iconPath='cached-buff.dds',timeText='9.3',stack=3}},
        debuffRows={{id=12,iconPath='cached-debuff.dds',timeText='4.2',stack=2}},
        cooldownRows={{id=13,iconPath='cached-skill.dds',timeText='8.1'}},cast={casting=true,spellName='我的技能',currMs=400,totalMs=1000}}
    F.laneData.target={mainHand={icon='target-type.dds'},class={name='目标职业',icon='target-class.dds'}}
    local facts=h.Copy(F.laneData);local reads,writes=h.reads,h.writes
    assert(h:All());assert(h.C:SetComponent('plate'))
    local p=h.C.globalPreview.items
    assert(p.mainHand.preview.icons[1].texture.texture=='cached-sword.dds','existing equipment icon discarded')
    assert(p.mainHand.preview.icons[1].grade.texture=='cached-grade.dds','existing quality overlay omitted')
    assert(p.buffs.preview.icons[1].texture.texture=='cached-buff.dds' and p.buffs.preview.icons[1].time.text=='9.3')
    assert(p.buffs.preview.icons[1].stack.shown and p.buffs.preview.icons[1].stack.text=='3','stack sample omitted')
    assert(p.cooldowns.preview.icons[1].texture.texture=='cached-skill.dds','cached cooldown icon discarded')
    assert(p.info.preview.infoLabel.text=='我的职业' and p.castBar.preview.castText.text=='我的技能')
    assert(Eq(facts,F.laneData) and reads==h.reads and writes==h.writes,'snapshot render queried or changed facts/persistence')
    assert(h.C:SetScope('target'));assert(p.mainHand.preview.icons[1].texture.texture=='target-type.dds','target borrowed own equipment')
end)
Test('missing facts use distinct samples and compact equipment glyphs without native observation',function()
    local h=Boot()
    h.F.AcquireConsumer=function()error('preview acquired consumer')end
    h.F.RefreshScope=function()error('preview requested lane facts')end
    X2Equipment.GetEquippedItemTooltipInfo=function()error('preview sampled equipment')end
    X2Ability={GetBuffTooltip=function()error('preview sampled tooltip')end}
    assert(h:All());assert(h.C:SetComponent('plate'))
    local p=h.C.globalPreview.items;local paths={}
    for _,key in ipairs({'buffs','debuffs','cooldowns'})do
        local icon=p[key].preview.icons[1]
        assert(icon.texture.shown and icon.texture.texture~='ui/icon/icon_unknown_item.dds','unknown sample remains')
        assert(not paths[icon.texture.texture],'categories share identical sample image');paths[icon.texture.texture]=true
    end
    for key,glyph in pairs({mainHand='主',offHand='副',ranged='远',wings='背'})do
        local icon=p[key].preview.icons[1]
        assert(not icon.texture.shown and icon.fallback.shown and icon.fallback.text==glyph,'missing slot cannot be distinguished: '..key)
    end
end)
Test('native texture rejection uses a glyph and a repeated accepted texture stays visible',function()
    local h=Boot();h.F.laneData.player.mainHand={icon='rejected.dds'};h.rejectTexture='rejected.dds'
    assert(h:All());assert(h.C:SetComponent('mainHand'));local icon=h.C.preview.icons[1]
    assert(not icon.texture.shown and icon.fallback.shown and icon.fallback.text=='主','rejected icon left a stray drawable')
    h.rejectTexture=nil;assert(h.C:RefreshControls())
    assert(icon.texture.shown and not icon.fallback.shown,'valid icon did not recover')
    h.S.UI.EnsureIconTexture=function(_,n,path)assert(n.texture==path);return true,false end
    assert(h.C:LayoutPreview() and icon.texture.shown,'successful texture no-op was treated as failure')
end)
Test('shared selected preview clears grades and respects hidden time stacks and cast text',function()
    local h=Boot();local F=h.F;F.State.settings.headShowAll=true;F.State.settings.headShowTime=false;F.State.settings.headShowStacks=false;F:InvalidateSettingsCache()
    F.laneData.player={mainHand={icon='sword.dds',gradeIconPath='grade.dds'},buffRows={{id=11,iconPath='buff.dds',timeText='9.3',stack=3}}}
    h.C.draft.player.components.castBar.showText=false
    assert(h:All());assert(h.C:SetComponent('mainHand'));local icon=h.C.preview.icons[1]
    assert(icon.grade.shown and icon.grade.anchored,'quality drawable omitted or unanchored')
    assert(h.C:SetComponent('buffs'))
    assert(not icon.grade.shown and not icon.time.shown and not icon.stack.shown,'shared children leaked or ignored policy')
    assert(h.C:SetComponent('castBar') and not h.C.preview.castText.shown,'full simulation forces hidden cast text')
    assert(h:All());assert(h.C.preview.caption.shown,'single preview caption did not recover')
    assert(h.C.globalPreview.items.mainHand.bg.shown and h.C.globalPreview.items.mainHand.label.shown,'reference mode did not recover')
end)
Test('calibration outlines stay inside the actual rectangles and clean up on exit',function()
    local h=Boot(1.5);assert(h:All());assert(h.C:SetComponent('buffs'))
    for _,preview in ipairs({h.C.preview,h.C.globalPreview.items.plate.preview})do
        assert(#preview.outline==4,'outline missing')
        for _,edge in ipairs(preview.outline)do
            assert(edge.shown and (edge.width==1 or edge.height==1),'outline covers HUD interior')
            assert(edge.x>=0 and edge.y>=0 and edge.x+edge.width<=preview.root.width and edge.y+edge.height<=preview.root.height,'outline exceeds component')
        end
    end
    assert(h.C:Exit(false) and h.C.previewContent==nil,'preview snapshot retained after exit')
end)
Test('selected sample creation failure hides partial roots and retries without duplicate controls',function()
    local h=Boot(nil,true);local c=h.C
    assert(not c.visible and not c.panel.shown and not c.preview.root.shown,'failed editor left visible roots')
    local panel,root=c.panel,c.preview.root
    local firstFallback=c.preview.icons[1].fallback
    assert(c:Open({scope='player'}) and c.panel==panel and c.preview.root==root,'failed creation rebuilt owned roots')
    assert(c.preview.icons[1].fallback==firstFallback and c.preview.icons[2].fallback,'retry discarded completed controls')
    assert(h:All());h:AssertAll('player')
    assert(c.preview.root.events.OnDragStart and c.preview.root.events.OnDragStop,'retry lost drag handlers')
end)
print('RESULT hud-all-preview passed='..passed..' failed='..failed..' ('.._VERSION..')')
if failed>0 then os.exit(1)end
