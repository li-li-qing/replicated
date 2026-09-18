-- Testing the real ledger with explicitly synthetic verified sources only.
local p,f=0,0
local function Test(n,fn)local ok,e=pcall(fn);if ok then p=p+1;print('PASS ledger-v2 '..n)else f=f+1;print('FAIL ledger-v2 '..n..': '..tostring(e))end end
local function Boot(disk)
 local H=dofile('tools/rs_udf_numeric_test_host.lua');local S,P,io=H.Boot(disk);S.SafeTraceback=tostring
 X2Unit={UnitNameWithWorld=function()return 'LedgerV2@Synthetic' end}
 local clock={year=2026,month=9,day=12};local calls=0
 S.Utils.GetServerTime=function()calls=calls+1;return clock.value or (not clock.failed and {year=clock.year,month=clock.month,day=clock.day} or nil)end
 S.FeatureRuntime={RegisterImplementation=function()return true end};dofile('core/rs_events.lua');dofile('core/rs_scheduler.lua')
 dofile('features/life/rs_daily_ledger.lua');local L=S.Features.DailyLedger;assert(L:Enable())
 return S,P,L,clock,io,function()return calls end
end
local function Source(L)assert(L:RegisterSource('honor',{id='test:honor',verified=true,evidence='unit test only',unit='points',mode='delta'}))end
Test('clock errors never become the displayed server date',function()
 local _,P,L,c=Boot();c.failed=true;assert(not L:CheckDay());local v=L:GetProjection()
 assert(v.day=='2026-09-12' and v.clockAvailable==false and v.error~=nil)
end)
Test('read model never performs a native time read or store mutation',function()
 local _,P,L,c,io,reads=Boot();local before=reads();local rev=L.revision
 for i=1,50 do L:GetProjection()end;assert(reads()==before and L.revision==rev)
end)
Test('same day saved totals remain visible before the next verified receipt',function()
 local _,P,L,c,io=Boot();Source(L);assert(L:Observe('honor',20,'test:honor',1));assert(P:Flush(L.StoreId))
 local _,P2,L2=Boot(io.disk);Source(L2);local r=L2:GetProjection().rows[2]
 assert(r.status=='retained' and r.value==20 and r.coverageGap)
end)
Test('pause retains previously earned total and labels it paused',function()
 local _,_,L=Boot();Source(L);L:Observe('honor',20,'test:honor',1);L:Disable();local r=L:GetProjection().rows[2]
 assert(r.status=='off' and r.value==20)
end)
Test('day roll does not expose yesterdays total under a new date while paused',function()
 local _,_,L,c=Boot();Source(L);L:Observe('honor',20,'test:honor',1);L:Disable();c.day=13
 local v=L:GetProjection();assert(v.day=='2026-09-12' and v.rows[2].value==20,'paused page must use saved date not fresh date')
 L:Enable();assert(L:GetProjection().day=='2026-09-13' and L:GetProjection().rows[2].value==nil)
end)
Test('registered source count controls source note and cannot fabricate others',function()
 local _,_,L=Boot();Source(L);local v=L:GetProjection();assert(v.verifiedSources==1 and v.missingSources==3)
 assert(v.rows[1].value==nil and v.rows[1].status=='unconnected')
end)
print('LEDGER V2 RESULT '..p..' passed / '..f..' failed');if f>0 then error('ledger v2 failed')end
