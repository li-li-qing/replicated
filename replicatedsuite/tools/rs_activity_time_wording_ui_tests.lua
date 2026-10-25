-- Replicated Suite · 活动时间文案界面测试
-- 作者：Replicated
-- QQ群：1104129461
-- 离线表现契约：玩家看到的活动文案不能泄露内部调度术语。
local pass, fail = 0, 0
local function Test(name, fn)
    local ok, why = xpcall(fn, debug.traceback)
    if ok then pass=pass+1; print('PASS '..name) else fail=fail+1; print('FAIL '..name..': '..tostring(why)) end
end
local function Read(path)
    local f=assert(io.open(path,'rb')); local s=f:read('*a'); f:close(); return s
end
Test('activity page summary explains schedule uncertainty in player language',function()
    local src=Read('presentation/v3/pages/rs_v3_activity_page.lua')
    assert(not src:find('计划余≠首领存活',1,true),'developer shorthand leaked into normal activity page')
    assert(src:find('时间按活动日程估算，实际结束时间可能有偏差',1,true),'plain-language schedule uncertainty hint missing')
    assert(not src:find('参考场次待核对',1,true),'internal confidence wording leaked into normal activity page')
    assert(not src:find('任务未完成',1,true),'task state must not replace the activity time column')
    assert(src:find('任务进度单独显示',1,true),'independent time and progress explanation missing')
end)
print(string.format('RESULT %d passed, %d failed',pass,fail));if fail>0 then os.exit(1)end
