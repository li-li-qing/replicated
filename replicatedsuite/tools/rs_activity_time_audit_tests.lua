-- Offline only; exercise real Activity Authority and curated data, not a copied timer.
-- No native mutation or persistence. The sampled server clock/map are controllable boundaries.
local pass, fail = 0, 0
local function Test(name, fn)
    local ok, why = xpcall(fn, debug.traceback)
    if ok then pass = pass + 1; print('PASS '..name) else fail = fail + 1; print('FAIL '..name..': '..tostring(why)) end
end
local function Boot(time)
    local h = { ms=0, samples=0, time=time or {year=2026,month=9,day=18,hour=11,minute=34,second=0}, mapCalls=0 }
    ReplicatedSuite={Features={Activities={State={hiddenEvents={}}}}, Data={}, NowMs=function()return h.ms end}
    local S=ReplicatedSuite
    S.SafeTraceback=debug.traceback
    UIParent={GetServerTimeTable=function()h.samples=h.samples+1;return h.time end}
    S.Api={CallCapability=function(_,_,obj,method,...)return pcall(obj[method],obj,...)end}
    X2Map={GetZoneStateInfoByZoneId=function(_,id)h.mapCalls=h.mapCalls+1;return h.zone end}
    dofile('core/rs_utils.lua');dofile('data/rs_event_data.lua');dofile('features/life/activities/rs_activity_authority.lua')
    h.S,h.A=S,S.Features.Activities.Authority
    return h,h.A
end
local function Jmg(a)
    a:Refresh('test');for _,r in ipairs(a:GetRows())do if r.questKey=='jmg'then return r end end
    error('missing JMG')
end
Test('JMG active window uses player-facing end wording',function()
    local h,a=Boot();local r=Jmg(a)
    assert(r.active and r.seconds==60)
    assert(r.status:find('后结束',1,true),'active status must say when it ends: '..r.status)
    assert(not r.status:find('计划余',1,true),'internal wording leaked into player UI: '..r.status)
    assert(r.scheduleText:find('11:20',1,true) and r.scheduleText:find('11:35',1,true),'start and planned end must both be visible')
end)
Test('JMG future start carries direction and does not shift all times',function()
    local h,a=Boot({year=2026,month=9,day=18,hour=11,minute=19,second=0});local r=Jmg(a)
    assert(not r.active and r.seconds==60 and r.status:find('后开始',1,true),r.status)
    assert(r.scheduleConfidence=='reference','TimeUntil agreement is not current server verification')
    assert(not r.status:find('参考',1,true),'internal confidence label leaked into player status: '..r.status)
    assert(not r.scheduleText:find('参考',1,true),'internal confidence label leaked into player schedule: '..r.scheduleText)
end)
Test('minute-only samples retain elapsed seconds between calibrations',function()
    local h,a=Boot({year=2026,month=9,day=18,hour=11,minute=34});a:SyncClock(true)
    local first=a:GetWeekSeconds()
    for _,ms in ipairs({15000,30000,45000})do h.ms=ms;a:SyncClock(false);assert(math.abs(a:GetWeekSeconds()-first-ms/1000)<0.01,'clock jumped back at '..ms)end
    assert(a.clockAnchor.precision=='minute')
end)
Test('next sampled minute narrows uncertainty without rewinding',function()
    local h,a=Boot({year=2026,month=9,day=18,hour=11,minute=34});a:SyncClock(true)
    h.ms=15000;h.time.minute=35;a:SyncClock(false)
    assert(a:GetWeekSeconds()%86400==11*3600+35*60)
    h.ms=30000;a:SyncClock(false);assert(a:GetWeekSeconds()%86400==11*3600+35*60+15)
end)
Test('invalid date or partial hour minute cannot fabricate a clock',function()
    for _,t in ipairs({{}, {year=2026,month=9,day=18}, {year=2026,month=2,day=30,hour=10,minute=0},
        {year=2026,month=9,day=18,hour=24,minute=0},{year=2026,month=9,day=18,hour=10,minute=60},
        {year=2026,month=9,day=18,hour=10,minute=0,second=99}})do
        local h,a=Boot(t);assert(a:SyncClock(true)==false,'accepted invalid clock');assert(a:GetWeekSeconds()==nil)
    end
end)
Test('unavailable clock reads are throttled even before first valid sample',function()
    local h,a=Boot({});for n=1,100 do a:SyncClock(false);a:GetWeekSeconds();a:GetDateSerial()end
    assert(h.samples==1,'failed clock repeatedly polled: '..h.samples)
end)
Test('failed clock expires rather than predicting forever',function()
    local h,a=Boot();a:SyncClock(true);h.time=nil;h.ms=121000
    assert(a:GetWeekSeconds()==nil,'stale anchor still authoritative')
end)
Test('clock diagnostics are read-only and contain JMG start and end evidence',function()
    local h,a=Boot();Jmg(a);local calls=h.samples
    assert(type(a.GetTimingDiagnostics)=='function','timing diagnostics missing')
    local d=a:GetTimingDiagnostics();assert(h.samples==calls and h.mapCalls==0)
    assert(d.serverSample and d.jmg and d.jmg:find('11:20',1,true))
end)
Test('broken quest tail provider cannot stop all activity projections',function()
    local h,a=Boot();a:SetQuestProgressProvider(function()error('provider-failure')end)
    assert(a:Refresh('broken-provider'));assert(#a:GetTimelineRows()>0)
end)
Test('invalid zone remain cannot become a trustworthy zero',function()
    local h,a=Boot();h.zone={conflictState=6,remainTime=-10};a:ScanZone(103)
    assert(a:GetZoneRemainSeconds(103)==nil,'negative native time clamped to authoritative zero')
end)
Test('stale zone samples expire and suppress derived countdowns',function()
    local h,a=Boot();h.zone={conflictState=6,remainTime=4800};a:ScanZone(103)
    h.ms=21000;assert(a:GetZoneRemainSeconds(103)==nil)
    a:Refresh('stale');local r=a:GetRow('zone:103');assert(r and r.status:find('过期',1,true))
    assert(a:GetRow('dynamic:zone:103:whalesong_boss')==nil)
end)
Test('fresh timed phase reaching zero requests a refresh not a guessed transition',function()
    local h,a=Boot();h.zone={conflictState=6,remainTime=2};a:ScanZone(103);h.ms=3000;a:Refresh('zero')
    local r=a:GetRow('zone:103');assert(r.status:find('更新',1,true),r.status)
end)
Test('date gated final occurrence cannot leak into the following week',function()
    local h,a=Boot();h.S.Data.RuEvents={{name='season',fullName='season',hour=10,minute=0,days={6},duration=1,activeFrom='2026-09-18',activeUntil='2026-09-18'}}
    a:Refresh('season');assert(a:GetRow('event:season')==nil,'expired next-week occurrence is still listed')
end)
Test('Hasla daily 21h is not incorrectly restricted to Sunday through Wednesday',function()
    local h,a=Boot();a:Refresh('hasla');for _,r in ipairs(a:GetRows())do if r.questKey=='hasla_shadow'then
        assert(r.seconds<86400,'Hasla pushed to next week');return end end;error('missing Hasla')
end)
Test('weekly boss days and confirmed existing slot distinctions stay intact',function()
    local h,a=Boot();a:Refresh('weekly');local by={};for _,r in ipairs(a:GetRows())do by[r.questKey or r.key]=r end
    assert(by.black_dragon.scheduleText:find('周六 18:30',1,true))
    assert(by.lusca.seconds==56*60,'existing 12:30 user-observed Lusca slot changed')
end)
Test('clock repeated frozen minute expires without periodic rewinds',function()
    local h,a=Boot({year=2026,month=9,day=18,hour=11,minute=34});a:SyncClock(true)
    local old=a:GetWeekSeconds()
    for ms=15000,210000,15000 do h.ms=ms;local n=a:GetWeekSeconds();if n then assert(n>=old,'frozen clock rewound');old=n end end
    assert(a:GetWeekSeconds()==nil and a.clockError=='server_time_not_advancing')
end)
Test('subsecond upcoming boundary never displays zero before it starts',function()
    local h,a=Boot({year=2026,month=9,day=18,hour=11,minute=19,second=59});a:SyncClock(true);h.ms=500
    local r=Jmg(a);assert(not r.active and r.seconds==1,'rounded a future occurrence down to zero')
end)
Test('expired conflict countdown cannot fabricate a zero-second start',function()
    local h,a=Boot();h.zone={conflictState=5,remainTime=1};a:ScanZone(20);a:ScanZone(102);h.ms=2000;a:Refresh('expired-phase')
    assert(a:GetRow('dynamic:zone:20:cinderstone_purify')==nil)
    assert(a:GetRow('dynamic:zone:102:aegis')==nil)
end)
Test('second aliases and weekly midnight rollover preserve server semantics',function()
    local h,a=Boot({year=2026,month=9,day=19,hour=23,min=59,sec=59});a:SyncClock(true)
    h.ms=2000;assert(a:GetWeekSeconds()==1)
    assert(a:GetDateSerial()==a.clockAnchor.dateSerial+1)
end)
Test('untimed danger phases without a duration remain valid observations',function()
    local h,a=Boot();h.zone={conflictState=2};a:ScanZone(103);a:Refresh('untimed')
    local r=a:GetRow('zone:103');assert(r.phaseKnown and r.status=='危险3阶段',r.status)
end)
Test('timed phase with invalid remaining value says waiting timer not stale phase',function()
    local h,a=Boot();h.zone={conflictState=6,remainTime=-1};a:ScanZone(103);a:Refresh('invalid')
    local r=a:GetRow('zone:103');assert(r.phaseKnown and r.status:find('等待计时',1,true),r.status)
end)
Test('minute precision uses approximate wording while second precision uses estimated wording',function()
    local h,a=Boot({year=2026,month=9,day=18,hour=11,minute=34});local r=Jmg(a)
    assert(r.status:find('约',1,true) and r.status:find('后结束',1,true),r.status)
    local h2,a2=Boot({year=2026,month=9,day=18,hour=11,minute=34,second=0});local r2=Jmg(a2)
    assert(r2.status:find('预计',1,true) and r2.status:find('后结束',1,true),r2.status)
end)
print(string.format('RESULT %d passed, %d failed',pass,fail));if fail>0 then os.exit(1)end
