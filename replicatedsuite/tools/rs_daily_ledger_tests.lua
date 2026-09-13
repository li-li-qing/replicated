-- Contract tests use synthetic verified sources, NOT available RU balance APIs.
local pass,fail=0,0
local function Test(n,f)local ok,e=pcall(f);if ok then pass=pass+1;print('PASS daily '..n)else fail=fail+1;print('FAIL daily '..n..': '..tostring(e))end end
local function Boot(disk)
 local H=dofile('tools/rs_udf_numeric_test_host.lua');local S,P,io=H.Boot(disk)
 local c={date={year=2026,month=9,day=12,hour=10,minute=0},tasks={}}
 X2Unit={UnitNameWithWorld=function()return 'LedgerSynthetic@TestWorld' end}
 S.Utils.GetServerTime=function()return c.date end
 S.Scheduler={AddTask=function(_,key,ms,fn)c.tasks[key]=fn;return true end,RemoveTask=function(_,key)c.tasks[key]=nil;return true end}
 dofile('features/life/rs_daily_ledger.lua');local L=assert(S.Features.DailyLedger);assert(L:Enable());return S,P,L,c,io
end
local function Source(L,key,mode)
 return L:RegisterSource(key,{id='test:'..key,verified=true,evidence='synthetic test only',mode=mode or 'balance',unit=key=='gold' and 'copper' or key=='experience' and 'experience' or 'points'})
end
Test('unconnected channels report unavailable not invented zero',function()
 local _,_,L=Boot();local p=L:GetProjection();assert(#p.rows==4)
 for _,r in ipairs(p.rows)do assert(r.value==nil and r.status=='unconnected')end
 assert(not L:Observe('gold',1010,'unknown',1))
end)
Test('balance establishes baseline and tracks positive and negative net copper',function()
 local _,_,L=Boot();assert(Source(L,'gold'));assert(L:Observe('gold',10000000,'test:gold',1))
 assert(L.State.channels.gold.net==0);assert(L:Observe('gold',10100000,'test:gold',2));assert(L.State.channels.gold.net==100000)
 assert(L:Observe('gold',10000000,'test:gold',3));assert(L.State.channels.gold.net==0)
end)
Test('duplicates stale receipts and nonintegral amounts are rejected without changing totals',function()
 local _,_,L=Boot();Source(L,'gold');L:Observe('gold',100,'test:gold',1);L:Observe('gold',110,'test:gold',2)
 assert(not L:Observe('gold',999,'test:gold',2));assert(not L:Observe('gold',1.5,'test:gold',3));assert(L.State.channels.gold.net==10)
end)
Test('daily roll resets only ledger and never attributes unobserved gap to new day',function()
 local _,_,L,c=Boot();Source(L,'gold');L:Observe('gold',100,'test:gold',1);L:Observe('gold',110,'test:gold',2)
 c.date.day=13;assert(L:Observe('gold',140,'test:gold',3));assert(L.State.day=='2026-09-13' and L.State.channels.gold.net==0)
 L:Observe('gold',145,'test:gold',4);assert(L.State.channels.gold.net==5)
end)
Test('missing clock and backward clock preserve totals and flag gaps',function()
 local _,_,L,c=Boot();Source(L,'gold');L:Observe('gold',100,'test:gold',1);L:Observe('gold',110,'test:gold',2)
 c.date=nil;assert(not L:Observe('gold',150,'test:gold',3));assert(L.State.channels.gold.net==10)
 c.date={year=2026,month=9,day=11};assert(not L:CheckDay());assert(L.State.channels.gold.net==10)
end)
Test('same day reload retains net but rebaselines unobserved interval',function()
 local _,P,L,c,io=Boot();Source(L,'gold');L:Observe('gold',100,'test:gold',1);L:Observe('gold',110,'test:gold',2);assert(P:Flush(L.StoreId))
 local _,_,L2=Boot(io.disk);Source(L2,'gold');L2:Observe('gold',999,'test:gold',1)
 assert(L2.State.channels.gold.net==10 and L2.State.channels.gold.coverageGap)
 L2:Observe('gold',1000,'test:gold',2);assert(L2.State.channels.gold.net==11)
end)
Test('XP bar balance is refused while verified delta handles level rollover safely',function()
 local _,_,L=Boot();assert(not Source(L,'experience','balance'));assert(Source(L,'experience','delta'))
 assert(L:Observe('experience',40,'test:experience',1));assert(L.State.channels.experience.net==40)
end)
Test('disable stops task observations and reenabling does not count gap',function()
 local _,_,L,c=Boot();Source(L,'gold');L:Observe('gold',100,'test:gold',1);L:Observe('gold',105,'test:gold',2)
 assert(L:Disable());assert(not next(c.tasks));assert(not L:Observe('gold',120,'test:gold',3))
 L:Enable();L:Observe('gold',120,'test:gold',3);assert(L.State.channels.gold.net==5)
end)
Test('failed persistence prepare keeps previously committed data intact',function()
 local _,P,L=Boot();Source(L,'gold');L:Observe('gold',100,'test:gold',1)
 local st=P:GetStore(L.StoreId);st.writeFenced=true;assert(not L:Observe('gold',150,'test:gold',2));assert(L.State.channels.gold.net==0)
end)
Test('cross-day rebaseline explicitly marks unobserved interval instead of a complete zero',function()
 local _,_,L,c=Boot();Source(L,'gold');L:Observe('gold',100,'test:gold',1);c.date.day=14
 L:Observe('gold',150,'test:gold',2);assert(L.State.channels.gold.net==0 and L.State.channels.gold.coverageGap)
end)
Test('independent channels persist without mixing their units',function()
 local _,P,L,c,io=Boot();for _,k in ipairs({'gold','honor','living','experience'})do Source(L,k,'delta');assert(L:Observe(k,19,'test:'..k,1))end
 assert(P:Flush(L.StoreId));local _,_,L2=Boot(io.disk)
 for _,k in ipairs({'gold','honor','living','experience'})do assert(L2.State.channels[k].net==19)end
 assert(io.clears==0)
end)
Test('real FeatureRuntime honors persisted disable independently of homepage',function()
 local H=dofile('tools/rs_udf_numeric_test_host.lua');local S,P=H.Boot();S.SafeTraceback=tostring
 S.Utils.GetServerTime=function()return {year=2026,month=9,day=12}end
 X2Unit={UnitNameWithWorld=function()return 'DailyRegistry@Test' end}
 dofile('core/rs_events.lua');dofile('core/rs_scheduler.lua');dofile('features/rs_feature_registry.lua');dofile('features/rs_feature_runtime.lua')
 dofile('features/life/rs_daily_ledger.lua');local R=S.FeatureRuntime
 assert(S.FeatureRegistry:Get('life_daily_stats').navigationVisible==false)
 assert(R:GetPreferredEnabled('life_daily_stats')==true)
 assert(R:SetPreferredEnabled('life_daily_stats',true,'test'));assert(R:IsEnabled('life_daily_stats'))
 assert(R:SetPreferredEnabled('life_daily_stats',false,'test'));assert(not R:IsEnabled('life_daily_stats'))
 assert(not S.Scheduler.tasks.v3_daily_ledger_clock)
end)
Test('delta receipts after reload retain totals but flag observation gap',function()
 local _,P,L,c,io=Boot();Source(L,'honor','delta');L:Observe('honor',10,'test:honor',1);assert(P:Flush(L.StoreId))
 local _,_,L2=Boot(io.disk);Source(L2,'honor','delta');assert(L2:Observe('honor',3,'test:honor',1))
 assert(L2.State.channels.honor.net==13 and L2.State.channels.honor.coverageGap)
end)
Test('source registration copies only bounded verified descriptors',function()
 local _,_,L=Boot();local spec={id='test:honor',unit='points',mode='delta',verified=true,evidence='test-only fixture'};spec.loop=spec
 assert(L:RegisterSource('honor',spec));assert(L.sources.honor.loop==nil)
 assert(not L:RegisterSource('living',{id='bad',unit='points',mode='delta',verified=true,evidence=string.rep('a',513)}))
end)
Test('cumulative XP never counts a reset bar as negative earnings',function()
 local _,_,L=Boot();Source(L,'experience','cumulative');assert(L:Observe('experience',100,'test:experience',1))
 assert(L:Observe('experience',120,'test:experience',2));assert(not L:Observe('experience',1,'test:experience',3))
 assert(L.State.channels.experience.net==20 and L.sessions.experience.sequence==2)
end)
Test('collection pause stops adapters and clock without disabling the feature',function()
 local _,_,L,c=Boot();Source(L,'gold','delta');assert(L:Observe('gold',25,'test:gold',1))
 assert(L:SetPaused(true,'home'));assert(L.enabled and L.paused and not next(c.tasks))
 local p=L:GetProjection();assert(p.enabled and p.paused and p.rows[1].status=='paused' and p.rows[1].value==25)
 assert(not L:Observe('gold',9,'test:gold',2))
 assert(L:SetPaused(false,'home'));assert(L.enabled and not L.paused and c.tasks.v3_daily_ledger_clock)
end)


Test('continuous balance source persists current balance across same-day reload',function()
 local _,P,L,c,io=Boot();assert(L:RegisterSource('gold',{id='native:gold',verified=true,evidence='native absolute balance test',mode='balance',unit='copper',continuousBalance=true}))
 assert(L:Observe('gold',20348,'native:gold',1))
 assert(L.State.channels.gold.net==0 and L.State.channels.gold.balance==20348)
 assert(P:Flush(L.StoreId))
 local _,_,L2=Boot(io.disk);assert(L2:RegisterSource('gold',{id='native:gold',verified=true,evidence='native absolute balance test',mode='balance',unit='copper',continuousBalance=true}))
 assert(L2:Observe('gold',20448,'native:gold',1))
 assert(L2.State.channels.gold.net==100 and L2.State.channels.gold.balance==20448)
end)

Test('pause invalidates continuous balance so paused gap is not counted',function()
 local _,_,L=Boot();assert(L:RegisterSource('gold',{id='native:gold',verified=true,evidence='native absolute balance test',mode='balance',unit='copper',continuousBalance=true}))
 assert(L:Observe('gold',1000,'native:gold',1));assert(L:Observe('gold',1100,'native:gold',2));assert(L.State.channels.gold.net==100)
 assert(L:SetPaused(true,'home'));assert(L.State.channels.gold.balance==nil)
 assert(L:SetPaused(false,'home'));assert(L:Observe('gold',2000,'native:gold',1));assert(L.State.channels.gold.net==100)
 assert(L:Observe('gold',2050,'native:gold',2));assert(L.State.channels.gold.net==150)
end)
Test('next-day cold start never backfills offline continuous balance gap',function()
 local _,P,L,c,io=Boot();assert(L:RegisterSource('gold',{id='native:gold',verified=true,evidence='native absolute balance test',mode='balance',unit='copper',continuousBalance=true}))
 assert(L:Observe('gold',1000,'native:gold',1));assert(L:Observe('gold',1100,'native:gold',2));assert(P:Flush(L.StoreId))
 -- Simulate closing the client on Sep 12 and starting again on Sep 13 with 500 copper
 -- of unobserved changes while offline. The first event must establish today's baseline only.
 local H=dofile('tools/rs_udf_numeric_test_host.lua');local S2,P2=H.Boot(io.disk)
 local c2={date={year=2026,month=9,day=13,hour=10,minute=0},tasks={}}
 X2Unit={UnitNameWithWorld=function()return 'LedgerSynthetic@TestWorld' end}
 S2.Utils.GetServerTime=function()return c2.date end
 S2.Scheduler={AddTask=function(_,key,ms,fn)c2.tasks[key]=fn;return true end,RemoveTask=function(_,key)c2.tasks[key]=nil;return true end}
 dofile('features/life/rs_daily_ledger.lua');local L2=assert(S2.Features.DailyLedger);assert(L2:Enable())
 assert(L2:RegisterSource('gold',{id='native:gold',verified=true,evidence='native absolute balance test',mode='balance',unit='copper',continuousBalance=true}))
 assert(L2:Observe('gold',1600,'native:gold',1));assert(L2.State.channels.gold.net==0 and L2.State.channels.gold.balance==1600)
 assert(L2:Observe('gold',1650,'native:gold',2));assert(L2.State.channels.gold.net==50)
end)

print('DAILY RESULT '..pass..' passed / '..fail..' failed');if fail>0 then error('daily tests failed')end
