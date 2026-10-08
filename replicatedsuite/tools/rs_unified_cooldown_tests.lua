-- Unified local CD source: real Demand / Events / Scheduler / Feature; Native return model only.
local passed,failed=0,0
local function T(name,fn)local ok,e=xpcall(fn,debug.traceback);if ok then passed=passed+1;print('PASS unified-CD '..name)else failed=failed+1;print('FAIL unified-CD '..name..': '..tostring(e))end end
local function Boot()
    local h,S,F=dofile('tools/rs_pvp_hud_test_host.lua')({runtimeHud=true,noRenderer=true})
    h.own,h.mates,h.readsCd={},{},0
    S.ApiImports={AcquireApi=function()return true end}
    S.Services.SkillMetadataV3={GetSkillInfo=function(_,id)return {name='Skill '..id,iconPath='cached/skill-'..id..'.dds',resolved=true}end}
    local call=S.Api.CallCapability
    S.Api.CallCapability=function(self,cap,host,method,id,ignore,mateType,...)
        if cap=='X2Skill:GetCooldown' then h.readsCd=h.readsCd+1;if h.fail then return true,nil,nil end;return true,h.own[id] or 0,nil,60000 end
        if cap=='X2Skill:GetMateCooldown' then h.readsCd=h.readsCd+1;if h.fail then return true,nil,nil end;return true,(h.mates[id] or {})[mateType] or 0,nil,60000 end
        return call(self,cap,host,method,id,ignore,mateType,...)
    end
    for _,path in ipairs({'services/rs_cooldown_observation_v3.lua','data/rs_skill_effects.lua','data/rs_combat_ability_catalog.lua','data/ids/rs_buff_ids.lua','data/rs_status_tracking_catalog.lua','features/combat/buff_display/rs_buff_display_management.lua'})do dofile(path)end
    h.C,h.F=S.Services.CooldownObservationV3,F
    function h:Advance()for i=1,100 do self:Step(16)end end
    return h
end
T('old mate-only selection uses proven own cooldown without rewriting saved source',function()
    local h=Boot();h.own[37172]=13071;assert(h.F:SetTrackedCooldownId(37172,'mate',true));local writes=h.writes
    h:Advance();local rows=h.F:GetPlatesProjection('player').cooldowns
    assert(#rows==1 and rows[1].remainingMs==13071 and rows[1].source=='skill','local positive cannot cross old saved source')
    assert(h.F:IsTrackedCooldownId(37172,'mate') and not h.F:IsTrackedCooldownId(37172,'skill'),'runtime migrates Store')
    assert(h.writes==writes,'source resolution writes every frame')
end)
T('single toggle resolves ride and battle pet with real timers and cancels the full ID',function()
    local h=Boot();h.mates[99031]={[1]=17000};h.mates[99032]={[2]=18000}
    assert(h.F:SetUnifiedCooldownTracked(99031,true));assert(h.F:SetUnifiedCooldownTracked(99032,true));h:Advance()
    local rows=h.F:GetPlatesProjection('player').cooldowns;assert(#rows==2 and rows[1].source=='mate' and rows[2].source=='mate','mate positive not selected')
    assert(rows[1].mateType==1 and rows[2].mateType==2,'Native mate type lost')
    assert(h.F:SetUnifiedCooldownTracked(99031,false));h:Advance();assert(#h.F:GetPlatesProjection('player').cooldowns==1)
    assert(not h.F:IsUnifiedCooldownTracked(99031),'hidden route remains tracked')
end)
T('unknown and all-ready routes never create theoretical cooldowns',function()
    local h=Boot();h.fail=true;assert(h.F:SetUnifiedCooldownTracked(99033,true));h:Advance()
    assert(#h.C:GetActiveRows()==0,'unknown started a timer')
    h.fail=false;h:Advance();assert(#h.C:GetActiveRows()==0,'Ready started a timer')
    h.mates[99033]={[1]=16000};h:Advance();assert(#h.C:GetActiveRows()==1,'zero/unknown was permanently cached')
end)
T('unified cold probes and urgent candidates stay inside the original eight Native calls',function()
    local h=Boot();local ids={};for id=99040,99059 do ids[#ids+1]=id end
    assert(h.C:AcquireConsumer('test:local',{localIds=ids,automatic=false}))
    for _,id in ipairs(ids)do h.C.autoProbePending[id]=id end
    for i=1,20 do local reads=h.readsCd;assert(h.C:ProbeReady());assert(h.readsCd-reads<=8,'source fallback escaped shared Native budget')end
    assert(h.C.nativeReads>0 and h.C:GetHealth().tracked==20,'local union did not converge')
    assert(h.C:ReleaseConsumer('test:local'));assert(not h.C.probeTaskActive and not h.C.taskActive)
end)
T('positive source uses one read in active lane and close releases all local state',function()
    local h=Boot();h.mates[99034]={[2]=17000};assert(h.F:SetUnifiedCooldownTracked(99034,true));h:Advance()
    local reads=h.readsCd;assert(h.S.Scheduler:RunTask(h.C.taskName));assert(h.readsCd-reads==1,'proven source re-probes all routes')
    assert(h.F:ReleaseConsumer('test:observer'));assert(not h.C.probeTaskActive and not h.C.taskActive and h.C:GetHealth().localTracked==0)
end)
T('budget exhaustion does not permanently skip the third unresolved ID',function()
    local h=Boot();local ids={99101,99102,99103};h.mates[99103]={[2]=15000}
    assert(h.C:AcquireConsumer('fairness',{localIds=ids}))
    for i=1,4 do local reads=h.readsCd;h.C:ProbeReady();assert(h.readsCd-reads<=8)end
    local rows=h.C:GetActiveRows();assert(#rows==1 and rows[1].id==99103,'third local ID starved forever at shared budget edge')
    for _,id in ipairs(ids)do assert(h.C.nativeEvidence['skill:'..id] and h.C.nativeEvidence['skill:'..id].queries>0,'round robin never observes '..id)end
end)
T('one ready route cannot hide unread alternatives before source is confirmed',function()
    local h=Boot();local call=h.S.Api.CallCapability
    h.S.Api.CallCapability=function(self,cap,host,method,id,ignore,mateType,...)
        if cap=='X2Skill:GetMateCooldown' then h.readsCd=h.readsCd+1;return true,nil,nil end
        return call(self,cap,host,method,id,ignore,mateType,...)
    end
    assert(h.F:SetUnifiedCooldownTracked(99201,true));h:Advance()
    local row=h.C:GetTrackedRows()[1];assert(row and row.nativeStatus=='unknown' and not row.ready,'own zero concealed unread mate sources')
    local evidence=h.C.nativeEvidence['skill:99201'];assert(evidence.unknown>0 and evidence.error,'partial coverage lost in diagnostics')
    h.S.Api.CallCapability=call;h:Advance();row=h.C:GetTrackedRows()[1]
    assert(row.ready and #h.C:GetActiveRows()==0,'all confirmed ready routes must stay timer free')
end)
print(string.format('UNIFIED_CD_RESULT passed=%d failed=%d',passed,failed));if failed>0 then os.exit(1)end
