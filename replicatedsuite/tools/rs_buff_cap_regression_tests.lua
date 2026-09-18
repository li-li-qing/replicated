-- 中文维护：开发期真实 Feature/Api/Store/Demand/Events/Scheduler/Alerts 回归，不进入 TOC。
-- Native 两类读数、磁盘和 Presenter 可控替换；不把模拟的值/阈值当作 RU 容量证明。
local H = dofile('tools/rs_udf_numeric_test_host.lua')
local passed, failed = 0, 0
local function Test(name, fn)
    local ok, err = pcall(fn)
    if ok then passed = passed + 1; print('PASS buff-cap ' .. name)
    else failed = failed + 1; print('FAIL buff-cap ' .. name .. ': ' .. tostring(err)) end
end
local POLL, EDGE = 'v3_business_buff_cap_poll', 'v3_business_buff_cap_refresh'
local function Boot(disk, disabled, realRuntime)
    local S, P, io = H.Boot(disk)
    S.SafeTraceback = debug.traceback
    local c = {now=1000,normal=4,hidden=2,reads=0,shows={},hides=0}
    S.NowMs = function() return c.now end
    dofile('core/rs_events.lua'); dofile('core/rs_scheduler.lua')
    X2Unit = {
        UnitBuffCount = function(_, unit) assert(unit=='player'); c.reads=c.reads+1; if c.failNormal then error('normal_unavailable') end; return c.normal end,
        UnitHiddenBuffCount = function(_, unit) assert(unit=='player'); c.reads=c.reads+1; if c.failHidden then error('hidden_unavailable') end; return c.hidden end,
    }
    dofile('services/rs_alerts_service.lua')
    local A = S.Services.Alerts
    A:SetPresenter({Show=function(_,text) if c.rejectShow then return false end; c.shows[#c.shows+1]=text; return true end,
        Hide=function() c.hides=c.hides+1; return true end, UpdateText=function() return true end})
    assert(A:Start())
    if realRuntime then
        -- 中文维护：生命周期、ImportRegistry、元数据均用真实实现，仅底层 ImportAPI/Object 是 Native 替身。
        S.Generation=1;ADDON.ImportAPI=function()return true end;ADDON.ImportObject=function()return true end
        dofile('native/rs_native_contract.lua');dofile('native/rs_native_imports.lua');assert(S.BootError==nil,S.BootError)
        dofile('features/rs_feature_registry.lua');dofile('features/rs_feature_runtime.lua')
    end
    dofile('features/rs_business_bridge.lua')
    local F = assert(S.Features.combat_buff_cap)
    assert(F:Initialize()); if not disabled then assert(F:Enable()) end
    function c:Refresh() return F.Commands:Refresh('test') end
    function c:Step(name, ms) self.now=self.now+(ms or 1000); return S.Scheduler:RunTask(name or POLL) end
    function c:Event() S.Events:Dispatch('BUFF_UPDATE', 'player') end
    return S,F,c,P,io,A
end
local function Set(F, scope, value)
    assert(type(F.Commands.SetThreshold)=='function', 'missing SetThreshold')
    return F.Commands:SetThreshold(scope,value)
end
local function Arm(F, scope, n)
    assert(Set(F,scope or 'normal',n or 4))
    assert(type(F.Commands.SetReminderEnabled)=='function', 'missing SetReminderEnabled')
    return F.Commands:SetReminderEnabled(true)
end
local function Row(F,key)
    for _,r in ipairs(F:GetProjection().rows) do if r.key=='buff_cap:'..key then return r end end
    error('missing separate '..key..' row')
end
Test('quiet enable has no observer or writes until a consumer exists',function()
    local S,F,c,P,io=Boot(); assert(c.reads==0 and F.consumerCount==0 and S.Scheduler.tasks[POLL]==nil and io.writes==0)
end)
Test('two independent rows expose counts and no alleged shared capacity',function()
    local S,F,c=Boot(); assert(F:AcquireConsumer('page'))
    assert(Row(F,'normal').count==4 and Row(F,'hidden').count==2 and #F:GetProjection().rows==2)
    assert(F:GetProjection().capacity==nil and c.reads==2)
end)
Test('one failed read stays unknown instead of contributing zero to a total',function()
    local S,F,c=Boot(); c.failHidden=true; assert(F:AcquireConsumer('page'))
    assert(Row(F,'normal').count==4 and Row(F,'hidden').count==nil and Row(F,'hidden').available==false)
    assert(F:GetProjection().status=='partial' and F:GetProjection().total==nil)
end)
Test('legal zero is available and can initialize a zero peak',function()
    local S,F,c=Boot(); c.normal=0; c.hidden=0; assert(F:AcquireConsumer('page'))
    assert(Row(F,'normal').count==0 and Row(F,'normal').peak==0 and F:GetProjection().status=='ready')
end)
Test('nil false negative fractional NaN infinite and table counts are unknown',function()
    for _,v in ipairs({false,-1,2.5,0/0,math.huge,{},'bad'}) do
        local S,F,c=Boot(); c.normal=v; assert(F:AcquireConsumer('page')); assert(Row(F,'normal').count==nil)
    end
    local S,F,c=Boot(); c.normal=nil;c.hidden=nil;assert(F:AcquireConsumer('page'));assert(F:GetProjection().status=='unavailable')
end)
Test('numeric string getter results retain exact integer meaning',function()
    local S,F,c=Boot();c.normal='7';assert(F:AcquireConsumer('page'));assert(Row(F,'normal').count==7)
end)
Test('peaks update independently and unknown never overwrites a peak',function()
    local S,F,c=Boot();assert(F:AcquireConsumer('page'));c.normal=12;c.hidden=1;c:Refresh()
    c.normal=nil;c.hidden=6;c:Refresh();assert(Row(F,'normal').peak==12 and Row(F,'hidden').peak==6)
end)
Test('reset peaks starts from current valid counts without writing a save',function()
    local S,F,c,P,io=Boot();assert(F:AcquireConsumer('page'));c.normal=10;c:Refresh();c.normal=3;c:Refresh()
    assert(type(F.Commands.ResetPeaks)=='function','missing ResetPeaks');assert(F.Commands:ResetPeaks())
    assert(Row(F,'normal').peak==3 and io.writes==0)
end)
Test('settings are durable across reload but counts and peaks are session only',function()
    local S,F,c,P,io=Boot();assert(Arm(F,'normal',3));c.normal=99;c:Refresh()
    local _,F2,c2=Boot(io.disk,true);local p=F2:GetProjection()
    assert(p.reminderEnabled==true and p.normalThreshold==3 and Row(F2,'normal').peak==nil and c2.reads==0)
end)
Test('explicit false and zero survive reload',function()
    local S,F,c,P,io=Boot();assert(Arm(F,'normal',3));assert(F.Commands:SetReminderEnabled(false));assert(Set(F,'normal',0))
    local _,F2=Boot(io.disk,true);assert(F2:GetProjection().normalThreshold==0 and F2:GetProjection().reminderEnabled==false)
end)
Test('old empty schema-one store upgrades in memory without rewriting it on load',function()
    local S,F,c,P,io=Boot();assert(P:SaveValue(F.storeId,{}, {durable=true,verifyAfterSave=true}))
    local _,F2,c2,P2,io2=Boot(io.disk,true);local p=F2:GetProjection()
    assert(p.reminderEnabled==false and p.normalThreshold==0 and p.hiddenThreshold==0 and io2.writes==0)
end)
Test('unchanged settings do not write repeatedly',function()
    local S,F,c,P,io=Boot();assert(Set(F,'normal',5));local n=io.writes
    assert(Set(F,'normal',5));assert(F.Commands:SetReminderEnabled(false));assert(io.writes==n)
end)
Test('invalid scope and non-integer thresholds refuse without mutation',function()
    local S,F,c,P,io=Boot()
    for _,v in ipairs({-1,1.5,1001,'bad',false,math.huge}) do assert(Set(F,'normal',v)==false) end
    assert(Set(F,'arbitrary',8)==false);assert(F.Commands:SetReminderEnabled('false')==false);assert(io.writes==0)
end)
Test('failed save rolls back setting and does not acquire observation',function()
    local S,F,c,P,io=Boot();assert(Set(F,'normal',4));local disk=H.Copy(io.disk);ADDON.SaveData=function() return false end
    assert(F.Commands:SetReminderEnabled(true)==false);assert(F:GetProjection().reminderEnabled==false)
    assert(F.consumerCount==0 and c.reads==0 and H.Eq(disk,io.disk))
end)
Test('editing disabled module is supported without starting tasks',function()
    local S,F,c,P,io=Boot(nil,true);assert(Arm(F,'hidden',8));assert(F.enabled==false and c.reads==0 and F.consumerCount==0)
end)
Test('enabled reminder with both thresholds zero stays idle',function()
    local S,F,c=Boot();assert(type(F.Commands.SetReminderEnabled)=='function','missing reminder command')
    assert(F.Commands:SetReminderEnabled(true));assert(c.reads==0 and F.consumerCount==0)
end)
Test('closing page keeps only explicit reminder demand and never starts DPS',function()
    local S,F,c=Boot();assert(F:AcquireConsumer('page'));assert(Arm(F,'normal',10));assert(F.consumerCount==2)
    assert(F:ReleaseConsumer('page'));assert(F.consumerCount==1 and S.Scheduler.tasks[POLL]~=nil)
    assert(S.Features.DPS==nil or S.Features.DPS.enabled~=true)
end)
Test('setting last threshold to zero releases reminder-only demand',function()
    local S,F,c=Boot();assert(Arm(F,'normal',10));assert(Set(F,'normal',0));assert(F.consumerCount==0 and S.Scheduler.tasks[POLL]==nil)
end)
Test('disabling reminder leaves page observation intact',function()
    local S,F,c=Boot();assert(Arm(F));assert(F:AcquireConsumer('page'));assert(F.Commands:SetReminderEnabled(false))
    assert(F.consumerCount==1 and S.Scheduler.tasks[POLL]~=nil)
end)
Test('first-edge coalescing is not postponed by continuous events',function()
    local S,F,c=Boot();assert(F:AcquireConsumer('page'));c:Event();local first=S.Scheduler.tasks[EDGE];assert(first)
    first.elapsedMs=100;for i=1,100 do c:Event() end
    assert(S.Scheduler.tasks[EDGE]==first and first.elapsedMs==100,'continuous events replaced the pending refresh')
    c:Step(EDGE,150);assert(c.reads==4)
end)
Test('low frequency fallback refreshes without BUFF_UPDATE',function()
    local S,F,c=Boot();assert(F:AcquireConsumer('page'));assert(S.Scheduler.tasks[POLL].intervalMs==1000)
    c.normal=9;c:Step();assert(Row(F,'normal').count==9)
end)
Test('all demand gone removes both tasks and stale values',function()
    local S,F,c=Boot();assert(F:AcquireConsumer('page'));c:Event();assert(F:ReleaseConsumer('page'))
    local n=c.reads;c:Event();assert(S.Scheduler.tasks[POLL]==nil and S.Scheduler.tasks[EDGE]==nil and c.reads==n)
    assert(Row(F,'normal').count==nil and F:GetProjection().observing==false)
end)
Test('retired periodic closure cannot run after reenable',function()
    local S,F,c=Boot();assert(F:AcquireConsumer('page'));local old=S.Scheduler.tasks[POLL].callback
    assert(F:Disable());assert(F:Enable());assert(F:AcquireConsumer('page'));local n=c.reads;old();assert(c.reads==n)
end)
Test('retired one-shot closure does not read after a new observation session',function()
    local S,F,c=Boot();assert(F:AcquireConsumer('page'));c:Event();local old=S.Scheduler.tasks[EDGE].callback
    assert(F:ReleaseConsumer('page'));assert(F:AcquireConsumer('page'));local n=c.reads;old();assert(c.reads==n)
end)
Test('failure to start scheduler rolls consumer acquisition back',function()
    local S,F,c=Boot();S.Scheduler.AddTask=function() return false end
    assert(F:AcquireConsumer('page')==false and F.consumerCount==0 and F:GetProjection().observing~=true)
end)
Test('enabling reminder reports persisted settings separately from failed observation',function()
    local S,F,c,P,io=Boot();assert(Set(F,'normal',10));S.Scheduler.AddTask=function() return false end
    local ok,err=F.Commands:SetReminderEnabled(true);assert(ok==false and tostring(err):find('已保存',1,true))
    assert(F:GetProjection().reminderEnabled==true and F.consumerCount==0 and io.writes==2)
end)
Test('repeating a saved enable retries failed observation without another save',function()
    local S,F,c,P,io=Boot();assert(Set(F,'normal',10));local add=S.Scheduler.AddTask;S.Scheduler.AddTask=function() return false end
    assert(F.Commands:SetReminderEnabled(true)==false);S.Scheduler.AddTask=add;local n=io.writes
    assert(F.Commands:SetReminderEnabled(true));assert(F.consumerCount==1 and io.writes==n)
end)
Test('high level emits once until a reliable below-threshold observation',function()
    local S,F,c,P,io,A=Boot();assert(Arm(F));assert(#c.shows==1)
    for i=1,12 do c:Step() end;assert(#c.shows==1)
    c.normal=3;c:Step();c.normal=4;c:Step();assert(#c.shows==2)
end)
Test('unavailable samples do not rearm an already delivered threshold',function()
    local S,F,c=Boot();assert(Arm(F));c.normal=nil;c:Step();c.normal=4;c:Step();assert(#c.shows==1)
end)
Test('fast threshold oscillation is rate limited without dropping a sustained new crossing',function()
    local S,F,c=Boot();assert(Arm(F));c.normal=3;c:Step(nil,150);c.normal=4;c:Step(nil,150);assert(#c.shows==1)
    c:Step(nil,5000);assert(#c.shows==2)
end)
Test('two threshold crossings are combined into a single notification',function()
    local S,F,c=Boot();assert(Set(F,'normal',4));assert(Set(F,'hidden',2));assert(F.Commands:SetReminderEnabled(true))
    assert(#c.shows==1 and c.shows[1]:find('普通',1,true) and c.shows[1]:find('隐藏',1,true))
end)
Test('another source owns the shared alert until it finishes',function()
    local S,F,c,P,io,A=Boot();assert(A:Push({text='Boss active',ownerKey='combat_boss_alerts',durationMs=3000}))
    assert(Arm(F));assert(#c.shows==1 and A.currentOwnerKey=='combat_boss_alerts')
    c.now=c.now+3001;A:Tick();c:Step();assert(#c.shows==2 and A.currentOwnerKey==F.Id)
end)
Test('an abandoned deferred crossing cannot alert after the count falls',function()
    local S,F,c,P,io,A=Boot();assert(A:Push({text='Boss',ownerKey='boss',durationMs=3000}));assert(Arm(F))
    c.normal=1;c:Step();A:Hide();c:Step();assert(#c.shows==1)
end)
Test('disabling this feature never hides another module alert',function()
    local S,F,c,P,io,A=Boot();assert(Arm(F));assert(A:Push({text='Boss',ownerKey='boss',durationMs=3000}));local hides=c.hides
    assert(F:Disable());assert(c.hides==hides and A.currentOwnerKey=='boss')
end)
Test('disabling reminders retracts only their own alert',function()
    local S,F,c,P,io,A=Boot();assert(Arm(F));assert(A.currentOwnerKey==F.Id)
    assert(F.Commands:SetReminderEnabled(false));assert(A.currentOwnerKey==nil)
end)
Test('presenter refusal is visible and not retried each observation',function()
    local S,F,c=Boot();c.rejectShow=true;assert(Arm(F));local p=F:GetProjection();assert(p.reminderError~=nil)
    c.rejectShow=false;for i=1,8 do c:Step() end;assert(#c.shows==0)
end)
Test('test notification never fabricates counts peaks or saves',function()
    local S,F,c,P,io=Boot();assert(type(F.Commands.TestReminder)=='function','missing TestReminder')
    local before=F:GetProjection();assert(F.Commands:TestReminder());local after=F:GetProjection()
    assert(after.samples==before.samples and c.reads==0 and io.writes==0 and #c.shows==1)
end)
Test('test notification refuses while the feature is disabled',function()
    local S,F,c=Boot(nil,true);assert(type(F.Commands.TestReminder)=='function','missing TestReminder')
    assert(F.Commands:TestReminder()==false and #c.shows==0)
end)
Test('projection is detached and has no Native or save side effects',function()
    local S,F,c,P,io=Boot();assert(F:AcquireConsumer('page'));local n,w,r=c.reads,io.writes,io.reads
    for i=1,10 do local p=F:GetProjection();p.rows[1].count=999 end
    assert(Row(F,'normal').count==4 and c.reads==n and io.writes==w and io.reads==r)
end)
-- 中文维护：补充串行配置与迟到回调/故障事务边界，针对真实实现，不以成功日志替代行为断言。
Test('editing hidden threshold never rearms an unchanged normal threshold',function()
    local S,F,c=Boot();assert(Arm(F));assert(#c.shows==1)
    c:Step(nil,5000);assert(Set(F,'hidden',1));assert(#c.shows==2)
    assert(c.shows[2]:find('隐藏',1,true) and not c.shows[2]:find('普通',1,true),'unrelated threshold edit reannounced normal')
end)
Test('retired edge cannot remove a newly scheduled edge with the same name',function()
    local S,F,c=Boot();assert(F:AcquireConsumer('page'));c:Event();local old=S.Scheduler.tasks[EDGE].callback
    assert(F:ReleaseConsumer('page'));assert(F:AcquireConsumer('page'));c:Event()
    local current,n=S.Scheduler.tasks[EDGE],c.reads;old()
    assert(S.Scheduler.tasks[EDGE]==current and c.reads==n)
    c.normal=11;c:Step(EDGE,150);assert(c.reads==n+2 and Row(F,'normal').count==11)
end)
Test('readback failure rolls in-memory state back without starting background observation',function()
    local S,F,c,P,io=Boot();assert(Set(F,'normal',4));local load=ADDON.LoadData
    ADDON.LoadData=function() return nil end
    local ok,err=F.Commands:SetReminderEnabled(true);ADDON.LoadData=load
    assert(ok==false and err~=nil and F:GetProjection().reminderEnabled==false)
    assert(F.consumerCount==0 and c.reads==0,'readback failure started reminder')
    -- SaveData may already have written; do not claim disk rollback from a failed verification.
end)
Test('event subscription failure rolls back periodic task and demand',function()
    local S,F,c=Boot();S.Events.SubscribeOptional=function()return false end
    assert(F:AcquireConsumer('page')==false)
    assert(F.consumerCount==0 and S.Scheduler.tasks[POLL]==nil and not F:GetProjection().observing and c.reads==0)
end)
Test('failed event scheduling reports error but keeps fallback usable',function()
    local S,F,c=Boot();assert(F:AcquireConsumer('page'));local add=S.Scheduler.AddTask
    S.Scheduler.AddTask=function(self,name,...)if name==EDGE then return false end;return add(self,name,...)end
    c:Event();assert(F:GetProjection().error~=nil and S.Scheduler.tasks[POLL]~=nil)
    c.normal=18;c:Step();assert(Row(F,'normal').count==18)
    S.Scheduler.AddTask=add;c:Event();c:Step(EDGE,150);assert(F:GetProjection().error==nil)
end)
Test('unavailable hidden count does not block a reliable normal reminder',function()
    local S,F,c=Boot();c.hidden=nil;assert(Arm(F));assert(#c.shows==1 and F:GetProjection().status=='partial')
    assert(c.shows[1]:find('普通',1,true) and not c.shows[1]:find('隐藏',1,true))
end)
Test('both unavailable counts never produce a threshold alert',function()
    local S,F,c=Boot();c.normal=nil;c.hidden=nil;assert(Set(F,'hidden',1));assert(Arm(F,'normal',1))
    assert(#c.shows==0 and F:GetProjection().status=='unavailable')
end)


Test('real FeatureRuntime and NativeImports start and retire reminder demand',function()
    local S,F,c,P,io=Boot(nil,true,true);local R=S.FeatureRuntime
    assert(R:IsImplemented(F.Id) and not R:IsEnabled(F.Id));assert(Arm(F,'normal',10));assert(c.reads==0)
    assert(R:SetPreferredEnabled(F.Id,true,'test_enable'));assert(R:IsEnabled(F.Id) and F.consumerCount==1 and c.reads==2)
    assert(#S.ApiImports:GetOwnerApis('feature:'..F.Id)==1)
    assert(R:SetPreferredEnabled(F.Id,false,'test_disable'));assert(not R:IsEnabled(F.Id) and not F.enabled)
    assert(F.consumerCount==0 and S.Scheduler.tasks[POLL]==nil and F:GetProjection().rows[1].count==nil)
    assert(F:GetProjection().normalThreshold==10 and F:GetProjection().reminderEnabled==true)
end)
Test('real runtime initialization failure cannot activate tasks or a second session',function()
    local S,F,c=Boot(nil,true,true);local R=S.FeatureRuntime
    assert(Arm(F,'hidden',9));S.ApiImports.Acquire=function()return false,'synthetic import refusal'end
    local ok,err=R:Enable(F.Id,'test');assert(ok==false and err=='synthetic import refusal')
    assert(not R:IsEnabled(F.Id) and not F.enabled and F.consumerCount==0 and c.reads==0)
end)


Test('below-threshold sample must not withdraw a manual presentation test',function()
    local S,F,c,P,io,A=Boot();assert(Arm(F,'normal',10));assert(F.Commands:TestReminder())
    assert(A.currentAlertKey=='manual_test');c:Step(nil,1000)
    assert(A.currentAlertKey=='manual_test','normal sampling cancelled manual presentation test')
    c.now=c.now+2001;A:Tick();assert(A.currentText==nil)
end)

print('BUFF CAP RESULTS: '..passed..' passed / '..failed..' failed (runtime='.._VERSION..')')
assert(failed==0,tostring(failed)..' buff capacity regressions')
