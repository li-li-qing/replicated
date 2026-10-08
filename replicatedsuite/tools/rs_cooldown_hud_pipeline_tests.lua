-- 开发期真实 Service -> Feature -> Scheduler -> Renderer 回归；仅 Native/磁盘使用模型，不代表 RU 实测。
local passed,failed=0,0
local function Test(name,fn)
    local ok,err=xpcall(fn,debug.traceback)
    if ok then passed=passed+1;print('PASS cooldown HUD '..name)
    else failed=failed+1;print('FAIL cooldown HUD '..name..': '..tostring(err))end
end
local function Boot()
    local h,S,F=dofile('tools/rs_pvp_hud_test_host.lua')({runtimeHud=true,noRenderer=true})
    h.remaining,h.mateRemaining,h.metadataReads,h.cdReads={},{},0,0
    S.ApiImports={AcquireApi=function()return true end}
    S.Services.SkillMetadataV3={GetSkillInfo=function(_,id)
        h.metadataReads=h.metadataReads+1
        return {name='Skill '..id,iconPath='cached/skill-'..id..'.dds',resolved=true}
    end}
    local call=S.Api.CallCapability
    S.Api.CallCapability=function(self,cap,host,method,id,ignore,mateType,...)
        if cap=='X2Skill:GetCooldown' then h.cdReads=h.cdReads+1;return true,h.remaining[id] or 0,nil,60000 end
        if cap=='X2Skill:GetMateCooldown' then
            h.cdReads=h.cdReads+1
            if h.mateUnknown then return true,nil,nil end
            return true,(h.mateRemaining[id] or {})[mateType] or 0,nil,60000
        end
        return call(self,cap,host,method,id,ignore,mateType,...)
    end
    for _,path in ipairs({'services/rs_cooldown_observation_v3.lua','data/rs_skill_effects.lua',
        'data/rs_combat_ability_catalog.lua','data/ids/rs_buff_ids.lua','data/rs_status_tracking_catalog.lua',
        'features/combat/buff_display/rs_buff_display_management.lua'})do dofile(path)end
    h.providers={}
    S.ModuleDiagnosticsHub={RegisterProvider=function(_,module,id,provider)
        assert(module=='combat_buff_display');h.providers[id]=provider;return true
    end}
    assert(F:SetComponentField('cooldowns','enabled',true))
    dofile('presentation/v3/widgets/rs_v3_buff_head_markers.lua')
    h.F,h.C,h.P=F,S.Services.CooldownObservationV3,S.UIV3.BuffHeadMarkersV3
    function h:Advance()for i=1,80 do self:Step(16)end end
    function h:VisibleCooldowns()
        local pool=self.P.pools.player;local result={}
        if not pool.root.shown or not pool.ready then return result end
        for _,m in ipairs(pool.icons)do
            if m.root.shown and tostring(m.iconPath):find('cached/skill-',1,true)then result[#result+1]=m end
        end
        return result
    end
    return h
end
Test('all eight saved own and mate skills reach visible parent and viewport',function()
    local h=Boot();local own={24326,37493,38130,39036,50867,9002021};local mate={32211,37172}
    for _,id in ipairs(own)do h.remaining[id]=13000;assert(h.F:SetTrackedCooldownId(id,'skill',true))end
    for _,id in ipairs(mate)do h.mateRemaining[id]={[1]=17000};assert(h.F:SetTrackedCooldownId(id,'mate',true))end
    h:Advance();local rows=h:VisibleCooldowns();assert(#rows==8,'full pipeline lost a saved active cooldown')
    for _,m in ipairs(rows)do
        local x,y=h:World(m.root)
        assert(x>=0 and y>=0 and x+m.root.width<=1280 and y+m.root.height<=768,'cooldown outside viewport')
        assert(m.time.text~='' and m.time.text~='--','countdown text missing')
    end
    local d=h.F:GetCooldownHudDiagnostics()
    assert(d.serviceActive==8 and d.selectedActive==8 and d.projected==8)
    local r=h.P:GetDiagnostics().cooldowns
    assert(r.inputRows==8 and r.drawn==8 and r.rootVisible==true and r.rootReady==true)
end)
Test('read-only diagnostic provider keeps every saved sample before automatic candidates',function()
    local h=Boot();assert(h.F:SetTrackedCooldownId(9002021,'skill',true));h.remaining[9002021]=16000
    for id=1000,1039 do h.C:_RecordNativeEvidence('skill',id,0,0,'skill',nil,nil)end
    h:Advance();local reads,meta,writes=h.cdReads,h.metadataReads,h.writes
    local provider=assert(h.providers.cooldown_hud_pipeline,'module export lacks renderer pipeline evidence')
    local d=provider();assert(d.feature.nativeSampleCount==32 and d.feature.nativeSampleTruncated==true)
    assert(d.feature.nativeEvidence[1].id==9002021 and d.feature.nativeEvidence[1].tracked==true,'saved high ID hidden by automatic samples')
    d.feature.activeRows[1].id=0
    assert(h.C:GetActiveRows()[1].id==9002021,'diagnostic mutates service facts')
    assert(h.cdReads==reads and h.metadataReads==meta and h.writes==writes,'diagnostic invokes Native or persistence')
end)
Test('legacy mate choice displays proven own CD through one local row without Store migration',function()
    local h=Boot();h.mateUnknown=true;h.remaining[37172]=13071;assert(h.F:SetTrackedCooldownId(37172,'mate',true))
    h.C.discoveredSkills[37172]={id=37172,name='Skill 37172'};local skills,mates=h.C:_MergedTracked();h.C:_ApplyTracked(skills,mates)
    assert(h.F:_AcquireCooldowns());local writes=h.writes;h:Advance();assert(#h:VisibleCooldowns()==1,'unified choice lost proven own Native timer')
    assert(h.F:IsTrackedCooldownId(37172,'mate') and not h.F:IsTrackedCooldownId(37172,'skill') and h.writes==writes,'runtime rewrote legacy choice')
    local host=dofile('tools/rs_status_ui_test_host.lua')(h.S);local page=assert(host:Build());page.managementView='cooldowns';page:Refresh()
    local view=host.widgets.v3_buff_cooldown_table;assert(#view.items==1 and view.items[1].id==37172 and view.items[1].active)
    local toggle;for _,c in ipairs(view.spec.columns)do if c.id=='player_cd'then toggle=c end end
    local row=view.items[1];assert(toggle.getTone(row)=='green' and toggle.onClick(row));h:Advance();assert(#h:VisibleCooldowns()==0)
    assert(toggle.onClick(row));h:Advance();assert(#h:VisibleCooldowns()==1,'unified re-add did not reach renderer')
end)
Test('texture rejection is distinguished from positive service and parent anchor loss',function()
    local h=Boot();h.remaining[37493]=12000;h.rejectTexture='cached/skill-37493.dds'
    assert(h.F:SetTrackedCooldownId(37493,'skill',true));h:Advance()
    local d=h.F:GetCooldownHudDiagnostics();local r=h.P:GetDiagnostics().cooldowns
    assert(d.selectedActive==1 and d.projected==1 and r.inputRows==1 and r.drawn==0 and r.rejected==1,'texture rejection looks like no cooldown')
    h.rejectTexture=nil;h:Advance();assert(#h:VisibleCooldowns()==1,'texture retry failed')
    h.points.player=nil;h:Step(16);r=h.P:GetDiagnostics().cooldowns
    assert(r.rootVisible==false and r.rootVisibilityReason=='native_anchor_unavailable','missing parent projection is not exposed')
    h.points.player={350,350,1};h:Advance();assert(#h:VisibleCooldowns()==1,'anchor recovery failed')
end)
Test('calibration suppression and ready completion leave useful last-active evidence',function()
    local h=Boot();h.remaining[37493]=15000;assert(h.F:SetTrackedCooldownId(37493,'skill',true));h:Advance()
    assert(h.P:SetCalibrationSuppressed(true,'test'));assert(#h:VisibleCooldowns()==0)
    local r=h.P:GetDiagnostics();assert(r.calibrationSuppressed and not r.cooldowns.rootVisible)
    assert(h.P:SetCalibrationSuppressed(false,'test'));h:Advance();assert(#h:VisibleCooldowns()==1)
    h.remaining[37493]=0;h:Advance();assert(#h:VisibleCooldowns()==0)
    local d=h.F:GetCooldownHudDiagnostics();assert(d.selectedActive==0 and d.lastActive.id==37493 and d.nonemptyTicks>0)
    r=h.P:GetDiagnostics().cooldowns;assert(r.inputRows==0 and r.drawn==0 and r.lastNonemptyDrawn==1)
    assert(h.F:SetTrackedCooldownId(37493,'skill',false));h.remaining[37493]=18000;h:Advance()
    assert(#h:VisibleCooldowns()==0,'cancelled ID returns to HUD')
end)
Test('root visibility no-op is accepted and rejected hide remains unknown',function()
    local h=Boot();h.remaining[37493]=15000;assert(h.F:SetTrackedCooldownId(37493,'skill',true));h:Advance()
    h:Step(16);local r=h.P:GetDiagnostics().cooldowns
    assert(r.rootVisible==true and r.rootVisibilityAccepted==true,'visibility no-op classified as rejected')
    local root=h.P.pools.player.root;local ensure=h.S.UI.EnsureVisible
    -- 宿主的 Native 提交边界返回明确拒写，保持原 root 事实；不是用 false 冒充 SetVisible 的 noop。
    h.S.UI.EnsureVisible=function(self,widget,value,owner)
        if widget==root and value==false then return false,false,'test_visibility_rejected' end
        return ensure(self,widget,value,owner)
    end
    h.points.player=nil;h:Step(16);r=h.P:GetDiagnostics().cooldowns
    assert(root.shown==true,'model did not reject the hide')
    assert(r.rootVisible==nil and r.rootVisibilityAccepted==false and r.rootVisibilityRequested==false
        and r.rootVisibilityReason=='visibility_write_rejected','rejected hide reported as actually hidden')
    assert(h.P:SetCalibrationSuppressed(true,'test'));r=h.P:GetDiagnostics().cooldowns
    assert(r.rootVisible==nil and r.rootVisibilityAccepted==false and r.rootVisibilityRequested==false,'HideScope lies about rejection')
    h.S.UI.EnsureVisible=ensure;h.points.player={350,350,1};assert(h.P:SetCalibrationSuppressed(false,'test'));h:Advance()
    assert(#h:VisibleCooldowns()==1 and h.P:GetDiagnostics().cooldowns.rootVisibilityAccepted==true,'accepted visibility recovery failed')
end)
Test('CD alone starts its real projection lane and stopping releases its own demand',function()
    local h=Boot()
    for key in pairs(h.F.State.settings.components)do if key~='cooldowns' then assert(h.F:SetComponentField(key,'enabled',false))end end
    assert(h.F:ApplySettingFromBinding('info.enabled',false))
    assert(h.F:ApplySettingFromBinding('headTarget',false))
    h.remaining[37493]=15000;assert(h.F:SetTrackedCooldownId(37493,'skill',true));h:Advance()
    assert(h.P.running and #h:VisibleCooldowns()==1,'CD-only HUD is not a valid render demand')
    assert(h.F:SetComponentField('cooldowns','enabled',false));h:Advance()
    assert(not h.P.running and not h.F.lanes.position.active,'CD-only close retains another hidden render gate')
    assert(h.F:SetComponentField('cooldowns','enabled',true));h:Advance()
    assert(h.P.running and #h:VisibleCooldowns()==1,'CD-only reopen did not resume HUD')
    assert(h.P:Stop());assert(h.F:ReleaseConsumer('test:observer'))
    assert(not h.C.taskActive and not h.C.probeTaskActive and not h.F.cooldownHeld,'last observer retained CD tasks')
end)
print(string.format('cooldown HUD pipeline tests: %d passed, %d failed',passed,failed))
if failed>0 then os.exit(1)end
