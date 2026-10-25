-- Replicated Suite · 原生击杀通知双入口测试
-- 真实 Core Events / Demand / Bus / Analytics / 指标 / 个人历史；仅 Native
-- Host、时钟、Scheduler 和磁盘为替身，不读取玩家存档，不证明 RU 全局投递覆盖。
local passed,failed=0,0
local function Test(name,fn)
    local ok,err=xpcall(fn,debug.traceback)
    if ok then passed=passed+1;print('PASS kill ingress '..name)
    else failed=failed+1;print('FAIL kill ingress '..name..': '..tostring(err)) end
end
local function Copy(v)if type(v)~='table' then return v end local r={} for k,x in pairs(v)do r[k]=Copy(x)end return r end
local function Size(t)local n=0 for _ in pairs(t)do n=n+1 end return n end
local function SettleExistingPublication(h)
    -- Analytics 原有350ms投影发布可在最后一条事实后尚未执行；入口不能另建任何任务。
    for id in pairs(h.tasks)do assert(id==h.A.publishTask,'kill ingress added a scheduler task: '..id)end
    h:Advance(1000);assert(Size(h.tasks)==0,'stopped ingress retained scheduler work')
end
local names={'INSTANT_GAME_KILL','UNIT_KILL_STREAK'}
local function Boot(start,options)
    options=options or {}
    local h={now=1000,writes=0,tasks={},hosts={},setAttempts={},registrations={},releases={},options=options}
    local S={Generation=42,SafeTraceback=debug.traceback,Services={},Features={},Data={},Utils={DeepCopy=Copy}}
    ReplicatedSuite=S;h.S=S;S.PhysicalId=function(id)return id end;S.NowMs=function()return h.now end
    S.Utils.GetServerTime=function()return {year=2026,month=10,day=24,hour=18,minute=0}end
    local function Host(id)
        local host={id=id,handlers={},registered={}}
        function host:SetHandler(key,fn)self.handlers[key]=fn;return true end
        function host:ReleaseHandler(key)self.handlers[key]=nil;return true end
        function host:RegisterEvent(name)self.registered[name]=true;return true end
        function host:UnregisterEvent(name)self.registered[name]=nil;return true end
        function host:Show()return true end
        function host:SetExtent()return true end
        function host:EnablePick()return true end
        h.hosts[id]=host;return host
    end
    S.NativeObjectFactory={CreateWindow=function(_,id)return Host(id)end}
    UIParent={callbacks={}}
    function UIParent:SetEventHandler(name,fn)
        assert(name~='COMBAT_MSG','kill ingress expanded global COMBAT_MSG')
        h.setAttempts[name]=(h.setAttempts[name]or 0)+1
        if options.registrationDenied then return false end
        self.callbacks[name]=self.callbacks[name]or {};table.insert(self.callbacks[name],fn)
        h.registrations[name]=(h.registrations[name]or 0)+1;return true
    end
    function UIParent:ReleaseEventHandler(name,fn)
        h.releases[name]=(h.releases[name]or 0)+1
        if options.releaseDenied then return false end
        local kept={} for _,entry in ipairs(self.callbacks[name]or {})do if entry~=fn then kept[#kept+1]=entry end end
        self.callbacks[name]=kept;return true
    end
    h.globalHost=UIParent
    S.Api={IsCapabilityAllowed=function(_,cap)return options.deniedCapability~=cap end}
    function S.Api:ActionCapability(cap,host,method,...)
        if not self:IsCapabilityAllowed(cap)then return false end
        local ok,result=pcall(host[method],host,...);return ok and result~=false
    end
    S.Scheduler={AddOneShot=function(_,id,ms,fn,owner)h.tasks[id]={due=h.now+ms,fn=fn,owner=owner};return true end,
        RemoveTask=function(_,id)h.tasks[id]=nil;return true end,SetTaskModule=function()end,
        AddTask=function()error('kill ingress introduced polling task')end}
    function h:Advance(ms)
        self.now=self.now+ms;local pending=self.tasks;self.tasks={}
        for id,row in pairs(pending)do if row.due<=self.now then row.fn()else self.tasks[id]=row end end
    end
    S.Services.UnitIdentityV3={player={id='self-id',name='Self'},IsPlayerName=function(_,name)return name=='Self'end,
        IsPlayerIdentityReady=function()return true end,RefreshPlayerIdentity=function(self)return self.player end,
        ResolveCombatEndpoint=function(_,id,source)if id=='self-id'and source=='Self'then return {id=id,role='source',confidence='exact'}end end,
        GetById=function()return {kind='PLAYER',kindReliable=true}end}
    S.Services.CombatRelationV3={GetUnit=function()return {kind='PLAYER'}end}
    S.FeatureRuntime={implementations={},state={}}
    function S.FeatureRuntime:RegisterImplementation(id,f)self.implementations[id]=f;self.state[id]={initialized=true,enabled=true};return true end
    function S.FeatureRuntime:GetSnapshot(id)local f=self.implementations[id];return {enabled=f and f.enabled==true}end
    S.Persistence={Scope={Account='account',Character='character'},Lifetime={Permanent='permanent'},V3KeyPrefix='rs.v3.',stores={},loaded={}}
    local P=S.Persistence
    function P:GetStore(id)return self.stores[id]end
    function P:RegisterV3Store(spec)self.stores[spec.id]=spec;return spec end
    function P:IsStoreLoaded(id)return self.loaded[id]==true end
    function P:LoadStore(id)local s=self.stores[id];s.apply(s.default());self.loaded[id]=true;return 'empty'end
    function P:MarkDirty()h.writes=h.writes+1;return true end
    function P:MutateStore(_,fn)local ok,err=fn();if ok==false then return false,err end return self:MarkDirty()end
    dofile('features/rs_feature_registry.lua');dofile('core/rs_demand.lua');dofile('core/rs_events.lua')
    assert(S.Events:Start())
    dofile('services/rs_combat_event_bus_v3.lua');dofile('services/rs_combat_analytics_v3.lua')
    dofile('features/combat/analytics/rs_combat_metric_common.lua');dofile('features/combat/analytics/rs_combat_analytics_metrics.lua')
    dofile('features/combat/analytics/rs_combat_analytics_store.lua');dofile('features/combat/analytics/rs_combat_personal_history.lua')
    dofile('features/combat/analytics/rs_combat_analytics_feature.lua')
    h.bus=S.Services.CombatEventBusV3;h.A=S.Services.CombatAnalyticsV3;h.F=S.Features.CombatAnalytics
    h.bus._StartGlobalBridge=function()error('kill ingress requested all-scope bridge')end
    assert(h.F:Initialize());if start~=false then assert(h.F:Enable('test'))end
    function h:Global(event,payload)
        local callbacks={}for _,fn in ipairs(self.globalHost.callbacks[event]or {})do callbacks[#callbacks+1]=fn end
        for _,fn in ipairs(callbacks)do fn(payload)end
    end
    function h:Private(event,payload)
        local host=self.bus.privateHost;assert(host and host.registered[event]and host.handlers.OnEvent,'private native handler missing')
        host.handlers.OnEvent(host,event,payload)
    end
    function h:Count()return self.F:GetPersonalHistoryProjection().totals.kills end
    function h:Payload(victim,count,event,killer)
        if event=='INSTANT_GAME_KILL'then return {killer=killer or 'Self',victim=victim,killerKillstreak=count,ruleMode=5}end
        return {killerName=killer or 'Self',victimName=victim,killerKillStreak=count,gameType=5}
    end
    return h
end

Test('three global-only explicit victims in one burst count three',function()
    local h=Boot()
    for index,name in ipairs({'Eliou','Xiaobaiyang','Hunao'})do h:Global('UNIT_KILL_STREAK',h:Payload(name,index))end
    assert(h:Count()==3,'global-only confirmed kills were lost')
    local d=h.bus:GetDiagnosticDetail().killNotifications
    assert(d.sources.global.received==3 and d.sources.private.received==0 and d.sources.global.running==true)
    assert(d.events[1].transport=='private:kill_global','native source provenance missing')
    assert(h.bus.globalActive==false and h.bus.globalRows==0,'global damage bridge activated')
    for id in pairs(h.tasks)do assert(id==h.A.publishTask,'kill ingress added a scheduler task: '..id)end
end)
for _,event in ipairs(names)do
    for _,globalFirst in ipairs({false,true})do
        Test(event..' private/global mirror credits once '..tostring(globalFirst),function()
            local h=Boot();local payload=h:Payload('Victim',1,event)
            if globalFirst then h:Global(event,payload);h:Private(event,payload)
            else h:Private(event,payload);h:Global(event,payload)end
            assert(h:Count()==1,'mirrored explicit notification was missed or counted twice')
            local d=h.bus:GetDiagnosticDetail().killNotifications
            assert(d.received==2 and d.sources.global.received==1 and d.sources.private.received==1,'one native route was absent')
            assert(h.F:DescribeDiagnosticDetail().kills.counters.duplicate_death==1)
        end)
    end
end
Test('damage and name-only deaths still never fabricate attribution',function()
    local h=Boot()
    for _,name in ipairs({'Eliou','Xiaobaiyang','Hunao'})do
        h.bus:_OnCombatRaw('private','self-id','SPELL_DAMAGE','Self',name,11,'Hit',0,100,true)
        h.bus:_OnDeathNotice(name)
    end
    h:Advance(1800);assert(h:Count()==0,'death or damage inferred a kill')
end)
Test('global other-killer notification remains outside self scope',function()
    local h=Boot();h:Global('UNIT_KILL_STREAK',h:Payload('Victim',1,nil,'Other'))
    assert(h.bus:GetDiagnosticDetail().killNotifications.received==1,'global notification never arrived')
    assert(h:Count()==0 and h.A:GetDeathIngressDiagnostics().counters.self_scope_filtered==1)
end)
Test('registration belongs to first and last Bus demand with zero tasks',function()
    local h=Boot(false);assert(Size(h.registrations)==0,'inactive Bus registered global ingress')
    local first,second={},{};assert(h.bus:Subscribe(first,function()end,{scope='self'}))
    assert(h.bus:Subscribe(second,function()end,{scope='self'}));assert(h.bus:_Start())
    for _,name in ipairs(names)do assert(h.registrations[name]==1,'duplicate or missing native registration')end
    assert(Size(h.tasks)==0,'Bus ingress owns scheduler work')
    assert(h.bus:Unsubscribe(first));for _,name in ipairs(names)do assert(not h.releases[name])end
    assert(h.bus:Unsubscribe(second));for _,name in ipairs(names)do assert(h.releases[name]==1)end
    assert(Size(h.tasks)==0 and h.bus:GetDiagnosticDetail().killNotifications.sources.global.running==false)
end)
Test('Stop and same-generation restart fence native and saved business closures',function()
    local h=Boot();local E=h.S.Events;local event='UNIT_KILL_STREAK'
    local native=assert(h.globalHost.callbacks[event]and h.globalHost.callbacks[event][1],'global handler absent')
    local listener=assert(E.internalListeners['native.global.'..event][1]);local oldOwner=listener.owner
    assert(h.F:Disable());local before=h.bus.killNoticeRows
    native(h:Payload('AfterStop',1));listener.callback(oldOwner,h:Payload('SavedAfterStop',1))
    assert(h.bus.killNoticeRows==before and Size(h.tasks)==0,'stopped ingress executed')
    assert(h.F:Enable('resume'));native(h:Payload('OldNative',1));listener.callback(oldOwner,h:Payload('OldBusiness',1))
    assert(h.bus.killNoticeRows==before,'same-generation restart revived old closure')
    h:Global(event,h:Payload('Fresh',1));assert(h:Count()==1,'fresh restarted ingress unavailable')
    assert(h.registrations[event]==2)
end)
Test('MarkInert revokes global owners without touching another owner',function()
    local h=Boot();local E=h.S.Events;local other,called={},0
    assert(E:SubscribeGlobalOptional('UNIT_KILL_STREAK',other,function()called=called+1 end))
    h.bus:_MarkInert();local before=h.bus.killNoticeRows
    h:Global('UNIT_KILL_STREAK',h:Payload('Inert',1));assert(h.bus.killNoticeRows==before and called==1)
    assert(h.registrations.UNIT_KILL_STREAK==1 and not h.releases.UNIT_KILL_STREAK,'another owner lost native handler')
    assert(Size(h.tasks)==0,'MarkInert introduced scheduler work')
end)
for _,cap in ipairs({'UIParent:SetEventHandler','UIParent:ReleaseEventHandler'})do
    Test(cap..' denial preserves private ingress',function()
        local h=Boot(true,{deniedCapability=cap});assert(Size(h.registrations)==0)
        h:Private('UNIT_KILL_STREAK',h:Payload('Private',1));assert(h:Count()==1)
        local d=h.bus:GetDiagnosticDetail().killNotifications
        assert(d.sources.global.running==false and d.sources.global.registrations.UNIT_KILL_STREAK=='unavailable')
        assert(h.F:Disable());SettleExistingPublication(h)
    end)
end
Test('registration rejection preserves private ingress without scheduler retries',function()
    local h=Boot(true,{registrationDenied=true});assert(Size(h.registrations)==0)
    h:Private('INSTANT_GAME_KILL',h:Payload('Private',1,'INSTANT_GAME_KILL'));assert(h:Count()==1)
    assert(h.bus:_Start());for _,name in ipairs(names)do assert(h.setAttempts[name]==1,'optional failure caused implicit retry')end
    assert(h.F:Disable());SettleExistingPublication(h)
end)
Test('release rejection parks old native callback and prevents duplicate registration',function()
    local h=Boot(true,{releaseDenied=true});local E=h.S.Events
    local native=assert(h.globalHost.callbacks.UNIT_KILL_STREAK and h.globalHost.callbacks.UNIT_KILL_STREAK[1],'global handler absent')
    assert(h.F:Disable());assert(E.globalReleaseFailures==2)
    assert(h.F:Enable('resume'))
    for _,name in ipairs(names)do assert(h.registrations[name]==1 and h.setAttempts[name]==1,'parked handler registered twice')end
    native(h:Payload('Parked',1));assert(h:Count()==0,'failed release revived parked callback')
    h:Private('UNIT_KILL_STREAK',h:Payload('PrivateAfterFailure',1));assert(h:Count()==1)
    assert(h.F:Disable());for _,name in ipairs(names)do assert(h.releases[name]==1,'failed release retried or leaked')end
    SettleExistingPublication(h)
end)
Test('malformed global payload is bounded and diagnosis snapshots are detached',function()
    local h=Boot();local payload=h:Payload('Victim',1);payload.extra={nested='not retained'}
    h:Global('UNIT_KILL_STREAK',payload);h:Global('UNIT_KILL_STREAK',{killerName={},victimName='Broken'})
    local d=h.bus:GetDiagnosticDetail().killNotifications
    assert(d.sources.global.received==2 and d.sources.global.rejected==1 and h:Count()==1)
    assert(d.events[1].transport=='private:kill_global' and d.events[1].extra==nil)
    d.sources.global.received=-1;d.sources.global.registrations.UNIT_KILL_STREAK='mutated';d.events[1].transport='mutated'
    local fresh=h.bus:GetDiagnosticDetail().killNotifications
    assert(fresh.sources.global.received==2 and fresh.sources.global.registrations.UNIT_KILL_STREAK=='registered')
    assert(fresh.events[1].transport=='private:kill_global')
end)
Test('unsupported transport cannot bypass self-only bus delivery',function()
    local h=Boot();h.bus:_OnKillNotice('UNIT_KILL_STREAK',h:Payload('Victim',1),'global:arbitrary')
    local d=h.bus:GetDiagnosticDetail().killNotifications
    assert(h:Count()==1 and d.sources.private.received==1 and d.sources.global.received==0)
    assert(d.events[1].transport=='private')
end)
Test('generation change fences native and saved business closures',function()
    local h=Boot();local event='UNIT_KILL_STREAK';local E=h.S.Events
    local listener=assert(E.internalListeners['native.global.'..event]and E.internalListeners['native.global.'..event][1],'global listener absent')
    h.S.Generation=h.S.Generation+1;h:Global(event,h:Payload('Stale',1));listener.callback(listener.owner,h:Payload('StaleBusiness',1))
    assert(h.bus.killNoticeRows==0 and h:Count()==0,'old generation global callback executed')
end)
print(string.format('KILL INGRESS RESULT %d passed / %d failed (%s)',passed,failed,_VERSION))
assert(failed==0,'kill ingress regression failures: '..failed)
