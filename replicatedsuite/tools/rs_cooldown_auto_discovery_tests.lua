-- Real Demand, Scheduler, CombatEventBus, Cooldown service and BuffDisplay projections.
-- Native transport/cooldown values use a controlled model; not RU live evidence. Never in TOC.
local passed,failed=0,0
local function Test(name,fn)
    local ok,err=xpcall(fn,debug.traceback)
    if ok then passed=passed+1;print('PASS cooldown auto '..name)
    else failed=failed+1;print('FAIL cooldown auto '..name..': '..tostring(err))end
end
local function Boot(withFeature,options)
    local h=dofile('tools/rs_gear_page_test_host.lua')(options);local S=h.S
    h.remaining={};h.mateRemaining={};h.cdReads=0;h.mateReads=0;h.failCooldown=false
    S.PhysicalId=function(id)return id end
    S.UI.CreateWindowShell=function()return nil,'test_no_window' end
    S.NativeObjectFactory={CreateWindow=function(_,id)
        if h.failHost then return nil,'test_host_unavailable' end
        local n=h.Native(nil,id,0,0,1,1)
        function n:RegisterEvent()return true end
        function n:ReleaseEvent()return true end
        return n
    end}
    S.Services.UnitIdentityV3={
        IsPlayerIdentityReady=function()return h.identityUnknown~=true end,
        IsPlayerName=function(_,name)return name=='Self' end,
        RefreshPlayerIdentity=function()return {id='self-id',name='Self',reliable=true} end,
        ResolveCombatEndpoint=function()return nil end,
    }
    S.ApiImports={AcquireApi=function()return true end}
    local call=S.Api.CallCapability
    S.Api.CallCapability=function(self,cap,host,method,id,ignore,...)
        if cap=='X2Skill:GetMateCooldown' then
            local mateType=select(1,...)
            assert(method=='GetMateCooldown' and ignore==true and (mateType==1 or mateType==2),'invalid mate Native route')
            h.mateReads=h.mateReads+1
            return true,(h.mateRemaining[id] or {})[mateType] or 0,nil,30000
        end
        if cap~='X2Skill:GetCooldown' then return call(self,cap,host,method,id,ignore,...) end
        assert(cap=='X2Skill:GetCooldown' and method=='GetCooldown' and ignore==true,'auto used unverified skill API')
        h.cdReads=h.cdReads+1
        if h.failCooldown then return false,nil,'test_native_failure' end
        return true,h.remaining[id] or 0,nil,30000
    end
    S.Services.SkillMetadataV3={GetSkillInfo=function(_,id,name)
        return {name=name or ('Skill '..id),iconPath='cached/skill-'..id..'.dds',resolved=true,source='test_native_metadata'}
    end}
    dofile('core/rs_demand.lua')
    dofile('services/rs_combat_event_bus_v3.lua')
    h.bus=S.Services.CombatEventBusV3
    h.bus._StartGlobalBridge=function()error('automatic discovery opened all-player bridge')end
    dofile('services/rs_cooldown_observation_v3.lua')
    h.C=S.Services.CooldownObservationV3
    function h:Cast(id,source,event,transport)
        self.bus:_OnCombatRaw(transport or 'private','self-id',event or 'CastSuccess',source or 'Self','Target',id,'Skill '..tostring(id),0,0,true)
    end
    function h:Probe()
        self.ms=self.ms+250
        assert(self.S.Scheduler:RunTask(self.C.probeTaskName),'probe not scheduled')
    end
    if withFeature then
        for _,path in ipairs({'data/rs_data_registry.lua','data/rs_skill_effects.lua','data/rs_combat_ability_catalog.lua',
            'data/ids/rs_buff_ids.lua','data/ids/rs_plates_ids.lua','data/rs_status_tracking_catalog.lua',
            'services/rs_status_classification_v3.lua','ui/framework/rs_ui_floating_surface.lua','features/combat/buff_display/rs_buff_display_store.lua',
            'features/combat/buff_display/rs_buff_display_projection.lua','features/combat/buff_display/rs_buff_display_feature.lua',
            'features/combat/buff_display/rs_buff_display_management.lua'})do dofile(path)end
        h.F=S.Features.BuffDisplay;assert(h.F:EnsureStoreLoaded())
        h.F.enabled=true;h.F.consumerCount=1;assert(h.F:_StartEvents())
    end
    return h
end
local function CDPage(h)
    local host=dofile('tools/rs_status_ui_test_host.lua')(h.S);local page=assert(host:Build())
    page.managementView='cooldowns';assert(page:Refresh())
    return host,page
end
local function OwnToggle(host)
    for _,c in ipairs(host.widgets.v3_buff_cooldown_table.spec.columns)do if c.id=='player_cd'then return c end end
    error('unified local CD toggle missing')
end
Test('empty configuration automatically discovers own used skill and shows Native cooldown',function()
    local h=Boot();local C=h.C;local reads,writes=h.reads,h.writes
    assert(C:AcquireConsumer('hud',{automatic=true,skillIds={},mateIds={}}))
    assert(C:GetHealth().subscribed and h.bus:GetHealth().scope=='self','empty automatic config did not acquire self discovery')
    assert(not C.probeTaskActive and not C.taskActive and h.cdReads==0,'empty discovery polls Native')
    h.remaining[777]=18000;h:Cast(777)
    assert(h.cdReads==0,'cast callback synchronously queried cooldown')
    h:Probe();local rows=C:GetActiveRows()
    assert(#rows==1 and rows[1].id==777 and rows[1].remainingMs==18000 and rows[1].authority=='LocalNative','automatic skill did not become a real countdown')
    assert(rows[1].automatic==true and rows[1].tracked==false,'automatic discovery became a saved manual selection')
    assert(h.reads==reads and h.writes==writes,'discovery performed persistence IO')
end)
Test('automatic candidate becomes one local choice and resolves real mount source',function()
    local h=Boot(true);local F=h.F;F.State.settings.components.cooldowns.enabled=true;F:InvalidateSettingsCache();assert(F:_AcquireCooldowns())
    h.mateRemaining[99006]={[1]=15000};h:Cast(99006);h:Probe()
    local host,page=CDPage(h);local view=host.widgets.v3_buff_cooldown_table;local row=view.items[1];local toggle=OwnToggle(host)
    assert(toggle.getTone(row)=='red' and toggle.onClick(row));assert(F:IsUnifiedCooldownTracked(99006))
    h:Probe();local rows=F:GetPlatesProjection('player').cooldowns
    assert(#rows==1 and rows[1].kind=='mate' and rows[1].mateType==1 and rows[1].remainingMs==15000,'mount positive not delivered')
    page:Refresh();assert(#view.items==1,'source split into duplicate rows')
    assert(toggle.onClick(row));assert(not F:IsUnifiedCooldownTracked(99006) and #F:GetPlatesProjection('player').cooldowns==0)
end)
Test('manual local ID add resolves battle pet without a source picker',function()
    local h=Boot(true);local host,page=CDPage(h);h.mateRemaining[99007]={[2]=17000}
    host.widgets.v3_buff_cooldown_skill_id:SetValue('99007',false);assert(host.widgets.v3_buff_cooldown_add.onClick())
    assert(h.F:IsUnifiedCooldownTracked(99007));h:Probe();local rows=h.F:GetPlatesProjection('player').cooldowns
    assert(#rows==1 and rows[1].kind=='mate' and rows[1].mateType==2 and h.mateReads>0,'battle pet used wrong Native source')
    page:Refresh();local row=host.widgets.v3_buff_cooldown_table.items[1];assert(OwnToggle(host).onClick(row));assert(not h.F:IsUnifiedCooldownTracked(99007))
end)
Test('legacy wrong-source choice cancels as one ID and re-add survives reload',function()
    local h=Boot(true);local F=h.F;assert(F.Commands:SetTrackedCooldownId(99008,'mate',true))
    local host,page=CDPage(h);local row=host.widgets.v3_buff_cooldown_table.items[1];local toggle=OwnToggle(host)
    assert(toggle.onClick(row));assert(not F:IsUnifiedCooldownTracked(99008));assert(toggle.onClick(row));assert(F:IsUnifiedCooldownTracked(99008))
    local cold=Boot(true,{disk=h.disk});assert(cold.F:IsUnifiedCooldownTracked(99008) and not cold.F:IsTrackedCooldownId(99008,'mate'),'unified choice lost on cold reload')
    cold.mateRemaining[99008]={[1]=16000};assert(cold.F:_AcquireCooldowns());cold:Probe()
    assert(cold.F:GetPlatesProjection('player').cooldowns[1].source=='mate','saved local choice failed Native source resolution')
end)
Test('failed unified cancellation preserves legacy mate choice and permits retry',function()
    local h=Boot(true);assert(h.F.Commands:SetTrackedCooldownId(99009,'mate',true));local host,page=CDPage(h)
    local row=host.widgets.v3_buff_cooldown_table.items[1];local toggle=OwnToggle(host)
    h.failSave=true;local ok=toggle.onClick(row);h.failSave=false;assert(ok==false)
    assert(h.F:IsTrackedCooldownId(99009,'mate') and not h.F:IsTrackedCooldownId(99009,'skill'),'failure changed committed route')
    assert(toggle.getTone(row)=='green' and host.widgets.v3_buff_tracking_status.text:find('失败',1,true))
    assert(toggle.onClick(row) and not h.F:IsUnifiedCooldownTracked(99009))
end)
Test('foreign source incoming casts aura IDs and global traffic are ignored',function()
    local h=Boot();assert(h.C:AcquireConsumer('hud',{automatic=true}))
    h:Cast(701,'Other');h:Cast(702,'Self','AuraApplied');h:Cast(703,'Self','SPELL_AURA_APPLIED')
    h:Cast(704,'Self','SPELL_DAMAGE');h:Cast(705,'Self','CastStart');h:Cast(706,'Self','CastSuccess','global:UI')
    h.identityUnknown=true;h:Cast(707);h.identityUnknown=false
    assert(h.C:GetHealth().autoDiscovered==0 and h.cdReads==0,'non-self/ambiguous fact became a skill')
    h:Cast(708,'Self','SPELL_CAST_SUCCESS');assert(h.C:GetHealth().autoDiscovered==1,'verified cast spelling not recognized')
    assert(h.bus.factMutationErrors==0,'auto changed shared CombatFact')
end)
Test('Native Ready or unknown never starts a theoretical timer and recovery works',function()
    local h=Boot();assert(h.C:AcquireConsumer('hud',{automatic=true}));h:Cast(801)
    h:Probe();assert(#h.C:GetActiveRows()==0,'Ready started a timer')
    h.failCooldown=true;h:Probe();assert(#h.C:GetActiveRows()==0,'unknown fabricated a timer')
    h.failCooldown=false;h.remaining[801]=12000;h:Probe()
    assert(#h.C:GetActiveRows()==1,'Native recovery was cached as no cooldown')
    h.remaining[801]=0;assert(h.S.Scheduler:RunTask(h.C.taskName))
    assert(#h.C:GetActiveRows()==0 and not h.C.taskActive,'completed auto timer stayed active')
end)
Test('automatic discovery is bounded and all Native probes share the existing budget',function()
    local h=Boot();assert(h.C:AcquireConsumer('hud',{automatic=true}))
    for id=1001,2000 do h:Cast(id)end
    assert(h.C:GetHealth().autoDiscovered<=64 and h.C:GetHealth().autoDiscovered>0,'automatic pool is unbounded or empty')
    assert(h.cdReads==0,'discovery scans Native in the event callback')
    h:Probe();assert(h.cdReads<=8,'automatic Native calls exceed original per-probe budget')
end)
Test('auto release preserves manual selection and final release fences old callbacks',function()
    local h=Boot();local C=h.C
    assert(C:AcquireConsumer('manual',{skillIds={901}}));assert(not C:GetHealth().subscribed,'manual flow acquired CombatBus')
    assert(C:AcquireConsumer('hud',{automatic=true}));h:Cast(901);h:Cast(902);h.remaining[901]=9000;h.remaining[902]=8000;h:Probe()
    local oldProbe=h.S.Scheduler.tasks[C.probeTaskName].callback
    assert(C:ReleaseConsumer('hud'));assert(not C:GetHealth().subscribed and C:GetHealth().autoDiscovered==0)
    local rows=C:GetActiveRows();assert(#rows==1 and rows[1].id==901 and rows[1].tracked==true,'auto release removed a manual timer')
    assert(C:ReleaseConsumer('manual'));local before=h.cdReads
    oldProbe();h:Cast(903)
    assert(h.cdReads==before and C:GetHealth().autoDiscovered==0 and h.bus.subscriberCount==0,'late callback revived released work')
    assert(not h.S.Scheduler.tasks[C.taskName] and not h.S.Scheduler.tasks[C.probeTaskName],'last release leaked tasks')
end)
Test('unavailable discovery transport remains diagnosable without failing manual cooldowns',function()
    local h=Boot();h.failHost=true
    assert(h.C:AcquireConsumer('hud',{automatic=true,skillIds={911}}),'discovery failure blocked feature')
    assert(h.C:GetHealth().autoError and not h.C:GetHealth().subscribed,'discovery failure hidden')
    h.remaining[911]=5000;h:Probe();assert(#h.C:GetActiveRows()==1,'manual Native timer stopped with discovery failure')
    assert(h.C:ReleaseConsumer('hud'))
end)
Test('BuffDisplay auto discovers candidates without implicitly tracking them on HUD',function()
    local h=Boot(true);local F=h.F
    assert(F:GetSettingsProjection().components.cooldowns.enabled==false)
    F.State.settings.components.cooldowns.enabled=true;F:InvalidateSettingsCache()
    local reads,writes=h.reads,h.writes;assert(F:_AcquireCooldowns())
    assert(h.C:GetHealth().subscribed,'CD display toggle did not enable automatic discovery')
    h.remaining[921]=21000;h:Cast(921);h:Probe()
    local own,target=F:GetPlatesProjection('player'),F:GetPlatesProjection('target')
    assert(#own.cooldowns==0,'unselected automatic candidate reached HUD')
    assert(#target.cooldowns==0,'target inherited local cooldown')
    local rows=F:GetManagementProjection({view='cooldowns'})
    assert(#rows==1 and rows[1].tracked==false and rows[1].trackedText=='未追踪（自动识别）','management misreports automatic as saved tracking')
    assert(h.reads==reads and h.writes==writes,'HUD auto mutated store')
    assert(F:_ReleaseCooldowns())
end)
Test('selected cooldown cancellation removes HUD even when automatic discovery keeps the skill',function()
    local h=Boot(true);local F=h.F
    F.State.settings.components.cooldowns.enabled=true;F:InvalidateSettingsCache();assert(F:_AcquireCooldowns())
    h.remaining[99001]=18000;h.remaining[99002]=14000;h:Cast(99001);h:Cast(99002);h:Probe()
    assert(F.Commands:SetTrackedCooldownId(99001,'skill',true))
    assert(F:IsTrackedCooldownId(99001,'skill') and not F:IsTrackedCooldownId(99002,'skill'))
    local rows=F:GetPlatesProjection('player').cooldowns
    assert(#rows==1 and rows[1].id==99001,'HUD did not honor selected-only CD tracking')
    assert(F.Commands:SetTrackedCooldownId(99001,'skill',false))
    assert(not F:IsTrackedCooldownId(99001,'skill') and #F:GetPlatesProjection('player').cooldowns==0,'cancelled discovered CD still visible')
    h:Cast(99001);h:Probe()
    assert(#F:GetPlatesProjection('player').cooldowns==0,'using cancelled skill silently retracked it')
    rows=F:GetManagementProjection({view='cooldowns'})
    assert(#rows==2 and not rows[1].tracked and not rows[2].tracked,'candidates disappeared or tracking was guessed')
end)
Test('cooldown choices survive a cold store reload and remain namespace independent',function()
    local h=Boot(true);local F=h.F
    assert(F.Commands:SetTrackedCooldownId(99001,'skill',true))
    assert(F.Commands:SetTrackedCooldownId(99002,'skill',true))
    assert(F.Commands:SetTrackedCooldownId(99001,'skill',false))
    local cold=Boot(true,{disk=h.disk});local G=cold.F
    assert(not G:IsTrackedCooldownId(99001,'skill') and G:IsTrackedCooldownId(99002,'skill'),'cold reload lost selected/cancelled choices')
    assert(not G:IsTrackedCooldownId(99002,'mate') and not G:IsTrackedChannel(99002,'player','buff'),'skill choice leaked into mate or Effect namespace')
    G.State.settings.components.cooldowns.enabled=true;G:InvalidateSettingsCache();assert(G:_AcquireCooldowns())
    cold.remaining[99001]=18000;cold.remaining[99002]=14000;cold:Cast(99001);cold:Cast(99002);cold:Probe()
    local rows=G:GetPlatesProjection('player').cooldowns
    assert(#rows==1 and rows[1].id==99002,'cold discovery ignored saved choices')
end)
Test('CD row toggles without selected-row dependency and keeps Native reads cold',function()
    local h=Boot(true);local F=h.F;F.State.settings.components.cooldowns.enabled=true;F:InvalidateSettingsCache();assert(F:_AcquireCooldowns())
    h.remaining[99001]=16000;h:Cast(99001);h:Probe();local host,page=CDPage(h);local row=host.widgets.v3_buff_cooldown_table.items[1];local toggle=OwnToggle(host)
    page.selectedManagementRow={id=99999,kind='skill'};assert(toggle.onClick(row));assert(toggle.getTone(row)=='green' and F:IsUnifiedCooldownTracked(99001))
    assert(toggle.onClick(row));assert(toggle.getTone(row)=='red' and #F:GetPlatesProjection('player').cooldowns==0)
    assert(toggle.onClick(row));local reads,writes=h.cdReads+h.mateReads,h.writes;page:Refresh();page:Refresh()
    assert(h.cdReads+h.mateReads==reads and h.writes==writes,'presentation performed Native or Store IO')
end)
Test('manual CD add exposes a green row that can immediately be cancelled',function()
    local h=Boot(true);local host,page=CDPage(h);host.widgets.v3_buff_cooldown_skill_id:SetValue('99003',false);assert(host.widgets.v3_buff_cooldown_add.onClick())
    local row=host.widgets.v3_buff_cooldown_table.items[1];local toggle=OwnToggle(host)
    assert(row.id==99003 and toggle.getTone(row)=='green','manual selection not visible')
    assert(toggle.onClick(row));assert(not h.F:IsUnifiedCooldownTracked(99003) and toggle.getTone(row)=='red')
    assert(toggle.onClick(row));assert(h.F:IsUnifiedCooldownTracked(99003))
end)
Test('failed inline cooldown cancellation preserves green tracking and reports failure',function()
    local h=Boot(true);assert(h.F.Commands:SetTrackedCooldownId(99004,'skill',true));local host,page=CDPage(h)
    local row=host.widgets.v3_buff_cooldown_table.items[1];local toggle=OwnToggle(host);h.failSave=true;local ok=toggle.onClick(row);h.failSave=false
    assert(ok==false and h.F:IsUnifiedCooldownTracked(99004) and toggle.getTone(row)=='green')
    assert(host.widgets.v3_buff_tracking_status.text:find('失败',1,true));assert(toggle.onClick(row));assert(not h.F:IsUnifiedCooldownTracked(99004))
end)
Test('CD source cannot inherit obsolete effect category filters',function()
    local h=Boot(true);local host,page=CDPage(h);page.managementView='live';page.managementFilter='tracked_buff'
    assert(host.widgets.v3_buff_manage_view:SetValue('cooldowns'));assert(host.widgets.v3_buff_manage_filter==nil,'redundant category picker retained')
    h:Cast(99001);h:Cast(99002);h:Probe();assert(h.F:SetUnifiedCooldownTracked(99001,true));page:Refresh()
    local rows=host.widgets.v3_buff_cooldown_table.items;assert(#rows==2 and rows[1].id==99001 and rows[2].id==99002,'obsolete filter concealed CD')
    assert(OwnToggle(host).getTone(rows[1])=='green' and OwnToggle(host).getTone(rows[2])=='red')
    assert(host.widgets.v3_buff_manage_view:SetValue('live'));assert(host.widgets.v3_buff_display_tracking_table.visible and not host.widgets.v3_buff_cooldown_table.visible)
end)
Test('CD toggle follows the union of committed choices and cancellation clears both old routes',function()
    local h=Boot(true);assert(h.F.Commands:SetTrackedCooldownId(99005,'skill',true));local host,page=CDPage(h)
    local row=host.widgets.v3_buff_cooldown_table.items[1];local toggle=OwnToggle(host)
    assert(h.F.Commands:SetTrackedCooldownId(99005,'mate',true));assert(toggle.getTone(row)=='green')
    assert(h.F.Commands:SetTrackedCooldownId(99005,'skill',false));page:Refresh();assert(toggle.getTone(row)=='green','legacy mate choice concealed')
    assert(toggle.onClick(row));assert(not h.F:IsTrackedCooldownId(99005,'mate') and not h.F:IsTrackedCooldownId(99005,'skill'))
    assert(toggle.getTone(row)=='red' and toggle.onClick(row));assert(h.F:IsUnifiedCooldownTracked(99005))
end)
Test('closed own HUD does not discover unless CD management view requests it',function()
    local h=Boot(true);local F=h.F
    F.State.settings.components.cooldowns.enabled=true;F.State.settings.headEnabled=false;F:InvalidateSettingsCache()
    assert(F:_AcquireCooldowns());assert(not h.C:GetHealth().subscribed,'hidden HUD acquired discovery')
    F.cooldownManagementActive=true;assert(F:_AcquireCooldowns());assert(h.C:GetHealth().subscribed,'management view did not request discovery')
    F.cooldownManagementActive=false;assert(F:_AcquireCooldowns());assert(not h.C:GetHealth().subscribed,'leaving management retained automatic discovery')
    assert(F:_ReleaseCooldowns())
end)
Test('transport recovery and reopening fence the old discovery closure',function()
    local h=Boot();local C=h.C;h.failHost=true
    assert(C:AcquireConsumer('hud',{automatic=true}));assert(not C:GetHealth().subscribed)
    h.failHost=false;assert(C:AcquireConsumer('hud',{automatic=true}));assert(C:GetHealth().subscribed,'same-options retry did not recover transport')
    local old=h.bus.subscribers[C].callback
    assert(C:ReleaseConsumer('hud'));assert(C:AcquireConsumer('hud',{automatic=true}))
    old(C,{rawEventType='CastSuccess',sourceName='Self',rawAbilityId=955})
    assert(C:GetHealth().autoDiscovered==0,'old subscription populated a reopened session')
    h:Cast(956);assert(C:GetHealth().autoDiscovered==1)
    assert(C:ReleaseConsumer('hud'))
end)
Test('automatic capacity evicts idle entries while protecting proven active cooldowns',function()
    local h=Boot();local C=h.C;assert(C:AcquireConsumer('hud',{automatic=true}))
    h.remaining[1000]=9000;h:Cast(1000);h:Probe()
    for id=1001,1063 do h:Cast(id)end
    h:Cast(1064)
    assert(C:GetHealth().autoDiscovered==64 and C:GetHealth().autoEvicted==1,'idle capacity did not rotate')
    local rows=C:GetActiveRows();assert(#rows==1 and rows[1].id==1000,'capacity evicted a confirmed active skill')
    assert(C:ReleaseConsumer('hud'))
end)
Test('failed unsubscribe rolls Demand back and can be released on retry',function()
    local h=Boot();local C=h.C;assert(C:AcquireConsumer('hud',{automatic=true}));h:Cast(971)
    local unsub=h.bus.Unsubscribe;h.bus.Unsubscribe=function()return false,'test_release_rejected'end
    local ok=C:ReleaseConsumer('hud')
    assert(ok==false and C.Demand:Has('hud') and C:GetHealth().subscribed,'failed release falsely cleared its lease')
    h.bus.Unsubscribe=unsub
    assert(C:ReleaseConsumer('hud'));assert(h.bus.subscriberCount==0 and C:GetHealth().autoDiscovered==0,'release retry leaked discovery')
end)
Test('fresh and repeated casts with short cooldowns precede a full Ready pool within the same budget',function()
    local h=Boot();local C=h.C;assert(C:AcquireConsumer('hud',{automatic=true}))
    for id=1001,1064 do h:Cast(id)end
    for i=1,20 do h:Probe()end
    h.remaining[9999]=1000;h:Cast(9999)
    local before=h.cdReads;h:Probe()
    local rows=C:GetActiveRows()
    assert(#rows==1 and rows[1].id==9999,'fresh short CD missed behind Ready scan')
    assert(h.cdReads-before<=8,'fresh cast bypassed the shared Native budget')
    h.remaining[9999]=0;assert(h.S.Scheduler:RunTask(C.taskName))
    for i=1,8 do h:Probe()end
    h.remaining[9999]=900;h:Cast(9999)
    before=h.cdReads;h:Probe();rows=C:GetActiveRows()
    assert(#rows==1 and rows[1].id==9999 and h.cdReads-before<=8,'repeated short CD has no priority')
    assert(C:ReleaseConsumer('hud'))
end)
print('RESULT cooldown-auto passed='..passed..' failed='..failed..' ('.._VERSION..')')
if failed>0 then os.exit(1)end
