-- Replicated Suite · DPS 投影缓存回归
-- 真实 Domain/复用拷贝；仅替代关系和设置输入，不读玩家 UDF，不进入 TOC。
local passed,failed=0,0
local function Test(name,fn)
    local ok,err=xpcall(fn,debug.traceback)
    if ok then passed=passed+1;print('PASS dps-projection '..name)
    else failed=failed+1;print('FAIL dps-projection '..name..': '..tostring(err))end
end
local function Same(a,b,seen)
    assert(type(a)==type(b),'type differs')
    if type(a)~='table' then assert(a==b,'value differs '..tostring(a)..' / '..tostring(b));return end
    seen=seen or {};if seen[a]==b then return end;seen[a]=b
    for key,value in pairs(a)do assert(b[key]~=nil,'missing '..tostring(key));Same(value,b[key],seen)end
    for key in pairs(b)do assert(a[key]~=nil,'extra '..tostring(key))end
end
local function Boot(path)
    local h={ms=10000,settings={mode='PVE',side='friendly',metric='damage',displayRows=12,alwaysShowSelf=true}}
    local S={Generation=1,Services={},Features={},Utils={},NowMs=function()return h.ms end}
    ReplicatedSuite=S;dofile('core/rs_reuse.lua')
    h.S=S
    local F={enabled=true,GetSettings=function()return h.settings end,IsBossName=function()return false end}
    S.Features.DPS=F
    local R={kinds={},relations={Me='SELF',Friend='FRIENDLY',Enemy='OPPONENT',Npc='OPPONENT'}}
    function R:GetRelationAt(name)return self.relations[name] or 'UNKNOWN'end
    function R:GetUnit(name)return {kind=self.kinds[name]}end
    function R:ApplyKind(name,kind)local changed=self.kinds[name]~=kind;self.kinds[name]=kind;return true,nil,changed end
    function R:RecordCombatFact(fact)return true,{sourceRelation=self:GetRelationAt(fact.sourceName),targetRelation=self:GetRelationAt(fact.targetName)}end
    S.Services.CombatRelationV3=R;h.R=R
    dofile(path or arg[1] or 'features/combat/dps/rs_dps_domain.lua');h.D=F.Domain
    function h:Fact(source,target,amount,ability,sourceKind,targetKind,category)
        self.ms=self.ms+1000
        return self.D:OnCombatFact({sourceName=source,targetName=target,amount=amount,
            rawAbilityId=ability or 10,abilityName='Skill'..tostring(ability or 10),
            sourceKind=sourceKind,targetKind=targetKind,category=category or 'damage',
            kind=category=='heal' and 'heal' or 'spell_damage',receivedAt=self.ms,sequence=self.ms})
    end
    function h:Seed()
        assert(self:Fact('Me','Npc',100,11,'PLAYER','NPC'))
        assert(self:Fact('Friend','Npc',80,12,'PLAYER','NPC'))
        assert(self:Fact('Me','Enemy',50,13,'PLAYER','PLAYER'))
        assert(self:Fact('Friend','Me',25,14,'PLAYER','PLAYER','heal'))
    end
    return h
end
local function Counts(h,fn)
    local tracked={}
    local function TrackBucket(bucket)
        tracked[bucket.actors]=true
        for _,actor in pairs(bucket.actors)do tracked[actor.abilityDetails]=true;tracked[actor.counterpartDetails]=true end
    end
    for _,mode in pairs(h.D.modes)do for _,side in ipairs({'friendly','enemy','unknown'})do TrackBucket(mode[side])end end
    for _,bucket in pairs(h.D.healing)do TrackBucket(bucket)end;TrackBucket(h.D.unclassified)
    local originalSort,originalPairs=table.sort,pairs
    local sorts,scans=0,0
    table.sort=function(...)sorts=sorts+1;return originalSort(...)end
    pairs=function(map)
        if tracked[map] then scans=scans+1 end
        return originalPairs(map)
    end
    local ok,result=pcall(fn)
    table.sort,pairs=originalSort,originalPairs
    assert(ok,result)
    return sorts,scans,result
end

Test('revision zero snapshots are detached and reusable',function()
    local h=Boot();local first=h.D:GetProjection({})
    local sorts,scans,second=Counts(h,function()return h.D:GetProjection({})end)
    assert(sorts==0 and scans==0,'revision-zero cache miss repeats sort/scan')
    assert(first~=second and first.totals~=second.totals);Same(first,second)
end)
Test('repeat projection avoids sorting and actor-map scans',function()
    local h=Boot();h:Seed();h.D:GetProjection({})
    local sorts,scans=Counts(h,function()return h.D:GetProjection({})end)
    assert(sorts==0 and scans==0,'unchanged projection repeats sort/scan')
end)
Test('repeat detail avoids sorting and detail-map scans',function()
    local h=Boot();h:Seed();local request={actorKey='name:me',mode='PVE',metric='damage',limit=100}
    h.D:GetActorDetail(request)
    local sorts,scans=Counts(h,function()return h.D:GetActorDetail(request)end)
    assert(sorts==0 and scans==0,'unchanged detail repeats sort/scan')
end)
Test('four mixed requests coexist and fifth evicts oldest',function()
    local h=Boot();h:Seed()
    local requests={{mode='PVE',metric='damage'},{mode='PVP',metric='damage'},
        {mode='PVE',metric='heal'},{mode='PVE',metric='damage',includeZero=true}}
    for _,request in ipairs(requests)do h.D:GetProjection(request)end
    for _,request in ipairs(requests)do
        local sorts=Counts(h,function()return h.D:GetProjection(request)end);assert(sorts==0,'alternating request thrashes below capacity')
    end
    h.D:GetActorDetail({actorKey='name:me',mode='PVE'})
    local sorts=Counts(h,function()return h.D:GetProjection(requests[1])end)
    assert(sorts>0,'cache retained more than four distinct requests')
end)
Test('different side, limit, and self preference reuse sorted candidates',function()
    local h=Boot();h:Seed();assert(h:Fact('Friend','Npc',1000,15,'PLAYER','NPC'))
    local first=h.D:GetProjection({displayRows=1})
    assert(#first.rows==1 and first.rows[1].key=='name:me' and first.rows[1].rank==2,'self insertion must replace last top row')
    local sorts,scans=Counts(h,function()return h.D:GetProjection({side='enemy',displayRows=100})end)
    assert(sorts==0 and scans==0,'other surface rebuilt shared candidates')
    h.settings.alwaysShowSelf=false
    local a,b,result=Counts(h,function()return h.D:GetProjection({displayRows=1})end)
    assert(a==0 and b==0,'self preference changed candidate ownership')
    assert(#result.rows==1 and result.rows[1].key=='name:friend' and result.rows[1].rank==1,'self preference reused wrong public slice')
end)
Test('caller mutation cannot poison ranking, totals, or detail',function()
    local h=Boot();h:Seed();local original=h.D:GetProjection({});local clean=h.S.Utils.DeepCopy(original)
    original.rows[1].damage=-900;original.rows[1].name='poison';original.totals.damage=-900
    original.sides.friendly.rows={};original.unresolved.totals.damage=-900
    Same(clean,h.D:GetProjection({}))
    local request={actorKey='name:me',mode='PVE'}
    local detail=h.D:GetActorDetail(request);local expected=h.S.Utils.DeepCopy(detail)
    detail.actor.damage=-900;detail.abilities[1].name='poison';detail.counterparts[1].amount=-900;detail.abilities={}
    Same(expected,h.D:GetActorDetail(request))
end)
Test('forced zero-amount self keeps rank zero and private fields stay private',function()
    local h=Boot();assert(h:Fact('Me','Friend',25,14,'PLAYER','PLAYER','heal'))
    for i=1,2 do
        local projection=h.D:GetProjection({metric='damage'})
        local row=assert(projection.rows[1]);assert(#projection.rows==1 and row.self)
        assert(row.rank==0 and row.damage==0 and row.metricValue==0 and row.dps==0 and row.hps==25)
        assert(row.damageActiveMs==nil and row.healActiveMs==nil,'private merged clock fields leaked')
        row.damageActiveMs=-100;row.healActiveMs=-100;row.rank=-100
    end
end)
Test('all effective request flags and defaults remain independent',function()
    local h=Boot();h:Seed()
    local requests={{},{mode='PVP'},{side='enemy'},{side='unknown'},{metric='heal'},{metric='taken'},
        {displayRows=1},{includeZero=true},{summaryOnly=true},{overview=true,displayRows=512,includeZero=true},
        {mode='bad',side='bad',metric='bad',displayRows=-1},{summaryOnly=false,includeZero=false}}
    for _,request in ipairs(requests)do
        local result=h.D:GetProjection(request)
        -- A reset of the transient state invalidates caches while preserving cumulative data.
        h.D:ResetTransient('test_invalidate');local fresh=h.D:GetProjection(request)
        result.revision=fresh.revision;Same(result,fresh)
    end
    for _,field in ipairs({'mode','side','metric','displayRows','alwaysShowSelf'})do
        h.D:GetProjection({})
        h.settings[field]=({mode='PVP',side='enemy',metric='taken',displayRows=1,alwaysShowSelf=false})[field]
        local changed=h.D:GetProjection({})
        h.D:ResetTransient('settings_reference')
        local fresh=h.D:GetProjection({});changed.revision=fresh.revision;Same(changed,fresh)
    end
end)
Test('candidate cap preserves total count and self beyond 512 ranks',function()
    local h=Boot();assert(h:Fact('Me','Npc',1,10,'PLAYER','NPC'))
    for index=1,600 do
        local name='Other'..index;h.R.relations[name]='FRIENDLY'
        assert(h:Fact(name,'Npc',index+10,10,'PLAYER','NPC'))
    end
    local value=h.D:GetProjection({displayRows=512,overview=true})
    assert(#value.rows==512 and value.totalRows==601 and value.truncated and value.totals.actorCount==601)
    assert(value.rows[1].key=='name:me' and value.rows[1].rank==601,'self candidate beyond retained prefix was lost')
    h.settings.alwaysShowSelf=false
    local sorts,scans,other=Counts(h,function()return h.D:GetProjection({displayRows=2})end)
    assert(sorts==0 and scans==0 and #other.rows==2 and other.rows[1].rank==1 and other.rows[2].rank==2)
end)
Test('detail dimensions and empty identities do not alias',function()
    local h=Boot();h:Seed()
    for _,request in ipairs({{actorKey='name:me'},{actorKey='name:friend'},{actorKey='name:me',mode='PVP'},
        {actorKey='name:me',side='enemy'},{actorKey='name:friend',metric='heal'},
        {actorKey='name:me',metric='taken'},{actorKey='name:me',limit=1},{actorKey=''}})do
        local value=h.D:GetActorDetail(request);h.D:ResetTransient('test_invalidate')
        local fresh=h.D:GetActorDetail(request);value.revision=fresh.revision;Same(value,fresh)
    end
end)
Test('advancing time without facts preserves existing rate and duration rules',function()
    local h=Boot();h:Seed();local before=h.D:GetProjection({});local detail=h.D:GetActorDetail({actorKey='name:me'})
    h.ms=h.ms+60000
    Same(before,h.D:GetProjection({}));Same(detail,h.D:GetActorDetail({actorKey='name:me'}))
    -- This Domain derives active time from accepted events, not elapsed wall-clock.
    assert(before.rows[1].dps==h.D:GetProjection({}).rows[1].dps)
end)
Test('generation and self identity invalidate without revision changes',function()
    local h=Boot();h:Seed();h.D:GetProjection({})
    h.S.Generation=h.S.Generation+1
    local sorts=Counts(h,function()return h.D:GetProjection({})end);assert(sorts>0,'generation reused old cache')
    h.D.selfKey='name:friend'
    local value=h.D:GetProjection({});local found=false
    for _,row in ipairs(value.rows)do if row.key=='name:friend' then assert(row.self);found=true end end
    assert(found,'self identity stale')
end)
Test('new fact, replay, clear, and transient reset invalidate immediately',function()
    local h=Boot();h:Seed();local before=h.D:GetProjection({});h.D:GetActorDetail({actorKey='name:me'})
    assert(h:Fact('Me','Npc',77,15,'PLAYER','NPC'))
    local after=h.D:GetProjection({});assert(after.totals.damage==before.totals.damage+77)
    assert(h.D:GetActorDetail({actorKey='name:me'}).actor.damage==177)
    h.D:ResetTransient('disable');local sorts=Counts(h,function()return h.D:GetProjection({})end)
    assert(sorts>0,'disable/reset did not invalidate');assert(h.D:GetProjection({}).totals.damage==after.totals.damage)
    h.D:ClearStats('clear');assert(h.D:GetProjection({}).totals.damage==0)
    assert(h.D:GetActorDetail({actorKey='name:me'}).actor==nil)
    -- Unknown target: first hit is provisionally PVE, then exact player evidence upgrades it to PVP.
    assert(h:Fact('Me','NewEnemy',42,16,'PLAYER',nil))
    assert(h.D:GetProjection({mode='PVE'}).totals.damage==42)
    h.R.kinds.NewEnemy='PLAYER';h.R.relations.NewEnemy='OPPONENT';assert(h.D:ReplayPending('kind'))
    assert(h.D:GetProjection({mode='PVE'}).totals.damage==0)
    assert(h.D:GetProjection({mode='PVP'}).totals.damage==42)
end)
Test('projection reads do not change cumulative facts or details',function()
    local h=Boot();h:Seed();local health=h.S.Utils.DeepCopy(h.D:GetHealth())
    local modes=h.S.Utils.DeepCopy(h.D.modes);local healing=h.S.Utils.DeepCopy(h.D.healing)
    for i=1,30 do h.D:GetProjection({mode=i%2==0 and 'PVE' or 'PVP',displayRows=i});h.D:GetActorDetail({actorKey='name:me',limit=i})end
    Same(health,h.D:GetHealth());Same(modes,h.D.modes);Same(healing,h.D.healing)
end)
Test('Feature enriches detached Domain rows without a second deep copy',function()
    local h=Boot();h:Seed();local S=h.S
    S.FeatureRuntime={RegisterImplementation=function()return true end}
    dofile('core/rs_demand.lua');dofile('features/combat/dps/rs_dps_feature.lua')
    local metadataName,metadataReads='Resolved skill',0
    S.Services.SkillMetadataV3={GetSkillInfo=function(_,id)
        metadataReads=metadataReads+1;return {skillId=id,name=metadataName,iconPath='icon',source='test'}
    end}
    S.Services.CombatAnalyticsV3={GetMetricProjection=function()
        return {statsAvailable=true,dataRevision=1,skills={{abilityId=11,key='id:11',name='Kill skill',kills=2,targets={{name='Victim'}}}}}
    end}
    local deepCopies,originalCopy=0,S.Utils.DeepCopy
    S.Utils.DeepCopy=function(...)deepCopies=deepCopies+1;return originalCopy(...)end
    local request={actorKey='name:me',mode='PVE',limit=100}
    local F=S.Features.DPS
    local first=F:GetActorDetail(request)
    assert(first.abilities[1].name=='Resolved skill' and first.abilities[1].kills==2)
    assert(deepCopies==0,'Feature repeats Domain-owned detached snapshot copy')
    local domain=h.D:GetActorDetail(request)
    assert(domain.abilities[1].name=='Skill11' and domain.abilities[1].kills==nil,'Feature metadata/kills poisoned Domain cache')
    first.actor.damage=-100;first.abilities[1].name='caller poison';first.counterparts[1].amount=-100
    metadataName='Refreshed metadata'
    local second=F:GetActorDetail(request)
    assert(second.actor.damage==100 and second.abilities[1].name=='Refreshed metadata' and second.counterparts[1].amount==100)
    assert(metadataReads==2,'metadata TTL lookup was frozen by Domain cache')
    domain.abilities[1].name='Domain caller poison';domain.actor.damage=-10
    assert(F:GetActorDetail(request).actor.damage==100,'Domain caller poisoned Feature')
    assert(h.D:GetActorDetail(request).abilities[1].name=='Skill11','Domain scalar snapshot lost native name')
end)
print('DPS_PROJECTION_PERFORMANCE_TESTS '..(failed==0 and 'PASS' or 'FAIL')..' passed='..passed..' failed='..failed)
if failed>0 then os.exit(1)end
