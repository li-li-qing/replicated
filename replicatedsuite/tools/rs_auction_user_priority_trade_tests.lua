-- 维护（2026-09-30）：复用真实 Trade/经济悬浮内容回归的 Native 边界主机；不得复制生产状态机。
-- 主机回归本身仍先运行，下面验证新增独立活动事件、只读投影和既有悬浮窗提示。
dofile("tools/rs_trade_tests.lua")
local S = ReplicatedSuite
local Trade, Queue = S.Features.Trade, S.Services.PriceQuoteQueueV3
local passed, total = 0, 0
local function Test(name, fn)
    total=total+1; local ok,err=xpcall(fn,debug.traceback)
    if ok then passed=passed+1;print("PASS "..name) else print("FAIL "..name..": "..tostring(err)) end
end
Test("Trade projection carries detached query pause without changing completion", function()
    Queue:_SetPaused(true,"native_auction_visible")
    local before=Trade:GetQuoteBatch()
    local p=Trade:GetProjection()
    assert(type(p.quoteActivity)=="table" and p.quoteActivity.paused==true,"Trade must project shared pause state")
    assert(p.quoteActivity.text:find("拍卖行使用中",1,true),"honest UI reason")
    p.quoteActivity.paused=false
    assert(Queue:GetActivitySnapshot().paused==true,"detached state")
    local after=Trade:GetQuoteBatch()
    assert(before.completed==after.completed and before.failed==after.failed,"pause not a material completion")
end)
Test("Trade activity event refreshes visible projection, not prices", function()
    assert(Trade:AcquireConsumer("auction_priority_ui_test"))
    Queue:_SetPaused(false)
    local before=Trade.Authority.revision
    local calls=0;local old=S.Api.CallCapability
    S.Api.CallCapability=function(self,...) calls=calls+1;return old(self,...) end
    Queue:_SetPaused(true,"native_auction_visible")
    S.Api.CallCapability=old
    assert(Trade.Authority.revision==before+1,"activity transition must notify Trade UI")
    assert(calls==0,"activity projection must not query Native")
end)
Test("unchanged pause does not repeatedly repaint Trade", function()
    local before=Trade.Authority.revision
    Queue:_SetPaused(true,"native_auction_visible")
    assert(Trade.Authority.revision==before,"transition-only publication")
end)
Test("Trade consumer release removes activity subscription", function()
    assert(Trade:ReleaseConsumer("auction_priority_ui_test"))
    local before=Trade.Authority.revision
    Queue:_SetPaused(false)
    assert(Trade.Authority.revision==before,"closed Trade UI must not handle activity")
end)
Test("floating Trade renders paused reason instead of still querying", function()
    local spec=S.UIV3.LifeEconomyContent.specs.Trade
    local message="拍卖行使用中，材料名称查询已暂停；关闭拍卖行后自动继续"
    local result=spec.status({status="ready",quoteActivity={paused=true,text=message},quoteBatch={active=true,total=3,completed=1}}, {})
    assert(result==message,"floating Trade must surface pause rather than claim ongoing search")
end)
Test("module diagnostics keep pause reason and query ownership", function()
    Queue:_SetPaused(true,"native_auction_visible")
    local diag=Trade:DescribeQuoteState()
    assert(type(diag.queue.activity)=="table" and diag.queue.activity.reason=="native_auction_visible","module report must retain pause")
end)
print(string.format("AUCTION_USER_PRIORITY_TRADE: %d/%d passed (%s)",passed,total,_VERSION))
assert(passed==total,"Trade auction pause integration failed")
