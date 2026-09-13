-- 开发期回归：实际 Api/Persistence/Demand/Scheduler/EventBus；原生读数与磁盘为可控替身。
-- 只验证读数观察和设置事务，不证明RU返回值语义/刷新额度/每日重置；禁止加入TOC。
local H = dofile('tools/rs_udf_numeric_test_host.lua')
local passed, failed = 0, 0
local function Test(name, fn)
    local ok, err = pcall(fn)
    if ok then passed=passed+1;print('PASS random-shop '..name)
    else failed=failed+1;print('FAIL random-shop '..name..': '..tostring(err)) end
end
local TASK='v3_random_shop_observe'
local function Boot(disk, disabled, realRuntime)
    local S,P,io=H.Boot(disk);S.Generation=1;S.SafeTraceback=debug.traceback
    local c={now=1000,value=4,reads=0};S.NowMs=function()return c.now end
    dofile('core/rs_events.lua');dofile('core/rs_scheduler.lua')
    X2Store={GetRandomShopStoreRefreshCount=function(...)
        assert(select('#',...)==1,'getter arguments invented');c.reads=c.reads+1
        if c.fail then error('synthetic native failure')end;return c.value
    end}
    if realRuntime then
        ADDON.ImportAPI=function()return true end;ADDON.ImportObject=function()return true end
        dofile('native/rs_native_contract.lua');dofile('native/rs_native_imports.lua')
        dofile('features/rs_feature_registry.lua');dofile('features/rs_feature_runtime.lua')
    end
    dofile('features/tools/random_shop/rs_random_shop_authority.lua')
    dofile('features/tools/random_shop/rs_random_shop_feature.lua')
    local F=S.Features.RandomShop;assert(F:Initialize());if not disabled then assert(F:Enable())end
    function c:Read(v)self.value=v;return F.Commands:Refresh('manual_test')end
    function c:Step()self.now=self.now+1000;return S.Scheduler:RunTask(TASK)end
    return S,F,c,P,io
end
local function Auto(F,value)assert(type(F.Commands.SetAutoRead)=='function','missing SetAutoRead');return F.Commands:SetAutoRead(value)end
local function Threshold(F,v)assert(type(F.Commands.SetThreshold)=='function','missing SetThreshold');return F.Commands:SetThreshold(v)end
Test('empty defaults are inert and do not write',function()
    local S,F,c,P,io=Boot();local p=F:GetProjection();assert(p.autoRead==false and p.threshold==0 and c.reads==0 and io.writes==0)
end)
Test('acquire reads once and stays manual by default',function()
    local S,F,c=Boot();assert(F:AcquireConsumer('page'));assert(c.reads==1 and F:GetProjection().refreshCount==4 and S.Scheduler.tasks[TASK]==nil)
end)
Test('zero and numeric strings are valid integers',function()
    local S,F,c=Boot();assert(F:AcquireConsumer('page'));assert(c:Read(0));assert(F:GetProjection().available and F:GetProjection().refreshCount==0)
    assert(c:Read('7'));assert(F:GetProjection().refreshCount==7)
end)
Test('fractional negative NaN infinity boolean and objects are unknown',function()
    for _,v in ipairs({-1,2.5,0/0,math.huge,false,{},'bad',9007199254740992})do
        local S,F,c=Boot();assert(F:AcquireConsumer('page'));c:Read(v);local p=F:GetProjection();assert(not p.available and p.refreshCount==nil,tostring(v))
    end
end)
Test('nil and getter exceptions never manufacture zero',function()
    local S,F,c=Boot();assert(F:AcquireConsumer('page'));c:Read(nil);assert(not F:GetProjection().available)
    c.fail=true;c:Read(7);assert(not F:GetProjection().available and F:GetHealth().failures==2)
end)
Test('observation yields delta from an explicit local baseline',function()
    local S,F,c=Boot();assert(F:AcquireConsumer('page'));c:Read(9);local p=F:GetProjection();assert(p.baseline==4 and p.sinceBaseline==5 and p.history[1].delta==5)
    assert(p.remaining==nil and p.dailyLimit==nil and p.spent==nil)
end)
Test('a drop starts a new segment without claiming daily reset',function()
    local S,F,c=Boot();assert(F:AcquireConsumer('page'));c:Read(9);c:Read(2);local p=F:GetProjection()
    assert(p.baseline==2 and p.sinceBaseline==0 and p.history[1].delta==-7 and p.history[1].kind=='decrease')
end)
Test('unavailable interval breaks continuity before recovery',function()
    local S,F,c=Boot();assert(F:AcquireConsumer('page'));c:Read(12);c:Read(nil);c:Read(30)
    local p=F:GetProjection();assert(p.baseline==30 and p.sinceBaseline==0 and p.history[1].delta==nil)
end)
Test('history contains changed samples only and is bounded to twelve',function()
    local S,F,c=Boot();assert(F:AcquireConsumer('page'));for i=1,100 do c:Read(i+4)end
    local p=F:GetProjection();assert(#p.history==12 and p.history[1].count==104)
    local key=p.history[1].key;for i=1,40 do c:Read(104)end;assert(F:GetProjection().history[1].key==key)
end)
Test('reset baseline is local and never saves or reads',function()
    local S,F,c,P,io=Boot();assert(F:AcquireConsumer('page'));c:Read(11);local r,w=c.reads,io.writes
    assert(type(F.Commands.ResetBaseline)=='function','missing ResetBaseline');assert(F.Commands:ResetBaseline());local p=F:GetProjection()
    assert(p.baseline==11 and p.sinceBaseline==0 and c.reads==r and io.writes==w)
end)
Test('threshold highlight is based only on a valid raw count',function()
    local S,F,c=Boot();assert(Threshold(F,4));assert(F:AcquireConsumer('page'));assert(F:GetProjection().reminderState=='reached')
    c:Read(3);assert(F:GetProjection().reminderState=='below');c:Read(nil);assert(F:GetProjection().reminderState=='unknown')
    assert(Threshold(F,0));assert(F:GetProjection().reminderState=='off')
end)
Test('settings survive reload while observations do not',function()
    local S,F,c,P,io=Boot();assert(Auto(F,true));assert(Threshold(F,18));assert(F:AcquireConsumer('page'));c:Read(30)
    local _,F2,c2=Boot(io.disk,true);local p=F2:GetProjection();assert(p.autoRead and p.threshold==18 and #p.history==0 and not p.available and c2.reads==0)
end)
Test('false and zero persist and unchanged settings do not rewrite',function()
    local S,F,c,P,io=Boot();assert(Auto(F,true));assert(Threshold(F,18));assert(Auto(F,false));assert(Threshold(F,0));local w=io.writes
    assert(Auto(F,false));assert(Threshold(F,0));assert(io.writes==w)
    local _,F2=Boot(io.disk,true);assert(F2:GetProjection().threshold==0 and not F2:GetProjection().autoRead)
end)
Test('invalid settings refuse mutation',function()
    local S,F,c,P,io=Boot();for _,v in ipairs({-1,1.2,1000001,math.huge,{},false,'bad'})do assert(Threshold(F,v)==false)end
    assert(Auto(F,'true')==false and io.writes==0)
end)
Test('failed durable save rolls back before starting observer',function()
    local S,F,c,P,io=Boot();assert(F:AcquireConsumer('page'));ADDON.SaveData=function()return false end
    assert(Auto(F,true)==false and F:GetProjection().autoRead==false and S.Scheduler.tasks[TASK]==nil)
end)
Test('readback mismatch is not a committed setting',function()
    local S,F,c,P,io=Boot();local load=ADDON.LoadData;ADDON.SaveData=function()io.writes=io.writes+1;return true end
    assert(Threshold(F,37)==false and F:GetProjection().threshold==0 and P.stats.readbackVerifyFailures>0)
end)
Test('disabled settings can be edited without acquiring a consumer',function()
    local S,F,c,P,io=Boot(nil,true);assert(Auto(F,true));assert(Threshold(F,12));assert(c.reads==0 and F.consumerCount==0 and S.Scheduler.tasks[TASK]==nil)
end)
Test('auto sampling uses one shared low-frequency task per feature',function()
    local S,F,c=Boot();assert(Auto(F,true));assert(F:AcquireConsumer('page'));assert(F:AcquireConsumer('page'));assert(F:AcquireConsumer('other'))
    assert(c.reads==1 and S.Scheduler.tasks[TASK].intervalMs==1000);c.value=8;c:Step();assert(c.reads==2 and F:GetProjection().refreshCount==8)
end)
Test('closing last consumer stops sampling and clears ephemeral state',function()
    local S,F,c=Boot();assert(Auto(F,true));assert(F:AcquireConsumer('page'));assert(F:ReleaseConsumer('page'))
    local p=F:GetProjection();assert(not p.observing and not p.available and #p.history==0 and S.Scheduler.tasks[TASK]==nil)
end)
Test('removing one consumer preserves the other',function()
    local S,F,c=Boot();assert(Auto(F,true));assert(F:AcquireConsumer('a'));assert(F:AcquireConsumer('b'));assert(F:ReleaseConsumer('a'))
    assert(F.consumerCount==1 and S.Scheduler.tasks[TASK]);assert(F:Disable());assert(F.consumerCount==0 and S.Scheduler.tasks[TASK]==nil)
end)
Test('turning auto off retains manual page reads but removes timer',function()
    local S,F,c=Boot();assert(Auto(F,true));assert(F:AcquireConsumer('page'));assert(Auto(F,false));assert(S.Scheduler.tasks[TASK]==nil and F.consumerCount==1)
    assert(c:Read(9));assert(F:GetProjection().refreshCount==9)
end)
Test('retired callbacks cannot read in a new demand session',function()
    local S,F,c=Boot();assert(Auto(F,true));assert(F:AcquireConsumer('page'));local old=S.Scheduler.tasks[TASK].callback
    assert(F:Disable());assert(F:Enable());assert(F:AcquireConsumer('page'));local r=c.reads;old();assert(c.reads==r)
end)
Test('generation guard rejects an old callback after reload',function()
    local S,F,c=Boot();assert(Auto(F,true));assert(F:AcquireConsumer('page'));local old=S.Scheduler.tasks[TASK].callback;S.Generation=2
    local r=c.reads;old();assert(c.reads==r)
end)
Test('manual refresh refuses disabled and consumer-free states',function()
    local S,F,c=Boot(nil,true);assert(F.Commands:Refresh()==false);assert(F:Enable());assert(F.Commands:Refresh()==false and c.reads==0)
end)
Test('projection is detached and render paths never perform a read',function()
    local S,F,c,P,io=Boot();assert(F:AcquireConsumer('page'));local p=F:GetProjection();p.history[1].count=999;p.threshold=10
    local r,w=c.reads,io.writes;for i=1,50 do F:GetProjection();F:GetHealth()end
    assert(F:GetProjection().history[1].count==4 and F:GetProjection().threshold==0 and c.reads==r and io.writes==w)
end)
Test('failed scheduler activation rolls back Demand without orphan work',function()
    local S,F,c=Boot();assert(Auto(F,true));S.Scheduler.AddTask=function()return false end;assert(F:AcquireConsumer('page')==false)
    assert(F.consumerCount==0 and not F:GetProjection().observing and S.Scheduler.tasks[TASK]==nil)
end)
Test('saved settings and observer failure have distinct receipts and can retry',function()
    local S,F,c=Boot();assert(F:AcquireConsumer('page'));local add=S.Scheduler.AddTask;S.Scheduler.AddTask=function()return false end
    local ok,err=Auto(F,true);assert(ok==false and tostring(err):find('已保存',1,true) and F:GetProjection().autoRead)
    S.Scheduler.AddTask=add;assert(Auto(F,true));assert(S.Scheduler.tasks[TASK])
end)
Test('update events use the real owner-first internal bus',function()
    local S,F,c=Boot();local owner={};local n=0
    assert(type(F.UpdateTopic)=='string','missing update topic');S.Events:SubscribeInternal(F.UpdateTopic,owner,function(o)assert(o==owner);n=n+1 end)
    assert(F:AcquireConsumer('page'));c:Read(8);assert(n>=2 and next(S.Events.listeners)==nil)
end)
Test('fenced settings never fall back to writable defaults',function()
    local S,F,c,P=Boot(nil,true);local store=assert(P:GetStore(F.storeId));store.writeFenced=true;store.writeFenceReason='synthetic protected'
    assert(Threshold(F,8)==false and c.reads==0)
end)
Test('real runtime can enable disable and preserve explicit preference',function()
    local S,F,c,P,io=Boot(nil,true,true);assert(S.FeatureRuntime:SetPreferredEnabled(F.Id,true,'test'))
    assert(F:AcquireConsumer('page'));assert(Threshold(F,8));assert(Auto(F,true));assert(S.FeatureRuntime:SetPreferredEnabled(F.Id,false,'test'))
    assert(not F.enabled and F.consumerCount==0 and S.Scheduler.tasks[TASK]==nil and F:GetProjection().threshold==8)
end)
-- 维护：验收序列只检查结构；执行诊断不得为这页启动观察、读Native或写入新Store。
Test('acceptance checks real registration without native reads or durable writes',function()
    local S,F,c,P,io=Boot(nil,true,true);local callback
    S.FoundationGate={RegisterSequenceCase=function(_,id,fn)assert(id=='v3_random_shop_read_only_contract');callback=fn end}
    dofile('features/tools/random_shop/rs_random_shop_acceptance.lua')
    local reads,writes=c.reads,io.writes;assert(type(callback)=='function');local ok,err=callback();assert(ok,err)
    assert(c.reads==reads and io.writes==writes and F.consumerCount==0 and not F.enabled)
    local saved=F.ObservationContractVersion;F.ObservationContractVersion=1;assert(callback()==false);F.ObservationContractVersion=saved
end)
print('RANDOM SHOP RESULTS: '..passed..' passed / '..failed..' failed (runtime='.._VERSION..')')
assert(failed==0,tostring(failed)..' random shop regressions')
