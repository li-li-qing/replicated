------------------------------------------------------------------------
-- Replicated Suite · 活动进行中颜色测试
-- 作者：Replicated
-- QQ群：1104129461
--
-- 离线回归：当前进行中的时间线活动显示红色，未来 10 分钟内的活动也显示红色；更晚的活动保持中性色，实时区域颜色仍由其自身规则决定。
------------------------------------------------------------------------
local pass, fail = 0, 0
local function Test(name, fn)
    local ok, why = xpcall(fn, debug.traceback)
    if ok then pass=pass+1; print('PASS '..name) else fail=fail+1; print('FAIL '..name..': '..tostring(why)) end
end
local function Boot(time)
    local h={ms=0,time=time or {year=2026,month=9,day=18,hour=11,minute=34,second=0}}
    ReplicatedSuite={Features={Activities={State={hiddenEvents={}}}},Data={},NowMs=function()return h.ms end}
    local S=ReplicatedSuite;S.SafeTraceback=debug.traceback
    UIParent={GetServerTimeTable=function()return h.time end}
    S.Api={CallCapability=function(_,_,obj,method,...)return pcall(obj[method],obj,...)end}
    X2Map={GetZoneStateInfoByZoneId=function(_,id)return h.zone end}
    dofile('core/rs_utils.lua');dofile('data/rs_event_data.lua');dofile('features/life/activities/rs_activity_authority.lua')
    h.A=S.Features.Activities.Authority;return h,h.A
end
local function Find(a,key)
    a:Refresh('test')
    for _,r in ipairs(a:GetRows()) do if r.key==key or r.questKey==key then return r end end
    return nil
end
Test('active scheduled timeline row is red',function()
    local _,a=Boot();local r=Find(a,'jmg');assert(r and r.active==true,'expected active JMG');assert(r.tone=='red','active tone='..tostring(r.tone))
end)
Test('upcoming scheduled timeline row inside ten minutes is red',function()
    local _,a=Boot({year=2026,month=9,day=18,hour=11,minute=19,second=0});local r=Find(a,'jmg');assert(r and r.active~=true,'expected upcoming JMG');assert(r.tone=='red','urgent upcoming tone='..tostring(r.tone))
end)
Test('upcoming scheduled timeline row above ten minutes remains neutral',function()
    local _,a=Boot({year=2026,month=9,day=18,hour=11,minute=9,second=0});local r=Find(a,'jmg');assert(r and r.active~=true,'expected upcoming JMG');assert((tonumber(r.secondsUntilStart) or 0)>600,'expected more than 10m');assert(r.tone=='default','far upcoming tone='..tostring(r.tone))
end)
Test('active live-derived timeline occurrence is red but live region keeps live tone',function()
    local h,a=Boot();h.zone={conflictState=6,remainTime=4590};assert(a:ScanZone(103));a:Refresh('whalesong')
    local dynamic=a:GetRow('dynamic:zone:103:whalesong_boss');assert(dynamic and dynamic.active==true,'expected active Whalesong occurrence');assert(dynamic.tone=='red','dynamic tone='..tostring(dynamic.tone))
    local live=a:GetRow('zone:103');assert(live and live.tone=='red','live WAR tone must remain live-authority red')
end)
print(string.format('RESULT %d passed, %d failed',pass,fail));if fail>0 then os.exit(1)end
