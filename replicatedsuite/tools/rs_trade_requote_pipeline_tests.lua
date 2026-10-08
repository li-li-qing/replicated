
-- Tests assert actual Native call/result/state behavior, not a made-up quote implementation.
-- 594/8800 copper are USER-SUPPLIED prices. Old 1500/8950 are a constructed counterexample,
-- deliberately yielding the earlier screenshot -3g40s; not recovered player cache evidence.
local Boot=dofile('tools/rs_trade_requote_test_host.lua')
local passed,total=0,0
local function Eq(a,b,m) assert(a==b,(m or 'value')..': expected='..tostring(b)..' actual='..tostring(a)) end
local function Test(name,fn) total=total+1;local ok,err=xpcall(fn,debug.traceback)
 if ok then passed=passed+1;print('PASS '..name) else print('FAIL '..name..': '..tostring(err)) end end
local function Unknown(h)
 h.content=nil;ADDON.GetContentMainScriptPosVis=function()h.visibilityReads=h.visibilityReads+1;return nil,nil,nil,nil end
 -- 中文维护注释（2026-10-02）：真实调用失败才是 unknown；两个 getter 正常为空已证明窗口关闭。
 ADDON.GetContent=function()error('native_content_unreadable')end
end
local function Strict(h,token,id,name)
 return h:quote(token,id,name,{force=true,priority='user',searchName=name or ('材料'..id),requireListing=true})
end
local function Listing(id,unit,n) return {itemType=id,itemGrade=1,itemStack=n or 100,name='材料'..id,directPrice=unit*(n or 100)} end
Test('manual current listing quote bypasses positive old GetLowestPrice and TTL cache',function()
 local h=Boot();local m=h:loadMaterialPrices();assert(m:ObserveConfirmedPrice(30901,1,1500,'market_price:1'))
 h.lowest[30901]=1500;h.queue.cache['30901:1']={price=1500,at=h.now};h.syncComplete=true
 h.onSearch=function()return {Listing(30901,594)}end
 assert(Strict(h,'user',30901,'香料'));h:advance(15000)
 Eq(h.deliveries[1].price,594);Eq(m:GetPrice(30901,1),594)
 Eq(h:count('GetLowestPrice'),0,'manual quote must not silently reuse native market snapshot')
 Eq(h:count('SearchAuctionArticle'),2,'large correction needs two independent listing observations in one action')
 Eq(#h.deliveries,1,'single terminal per watcher');Eq(h.deliveries[1].priceAccepted,true)
end)
Test('first held observation is not terminal successful refresh',function()
 local h=Boot();local m=h:loadMaterialPrices();assert(m:ObserveConfirmedPrice(30901,1,1500,'market_price:1'))
 assert(Strict(h,'user',30901,'香料'));h:untilSearch();h:searched({Listing(30901,594)})
 h:advance(1000);Eq(#h.deliveries,0,'not ready with retained wrong old value')
 Eq(m:GetPrice(30901,1),1500,'guard retained until second independent sample')
 Eq(h.queue:GetQuoteStateByItemType(30901,1).status,'verifying')
end)
Test('disagreeing large candidates stop at two observations without blessing old price',function()
 local h=Boot();local m=h:loadMaterialPrices();assert(m:ObserveConfirmedPrice(30901,1,1500,'market_price:1'))
 h.syncComplete=true;h.onSearch=function(_,n)return {Listing(30901,n==1 and 594 or 4000)}end
 assert(Strict(h,'user',30901));h:advance(30000)
 Eq(h:count('SearchAuctionArticle'),2);Eq(#h.deliveries,1);Eq(h.deliveries[1].status,'review_required')
 Eq(m:GetPrice(30901,1),1500);Eq(h.queue.running,false)
 Eq(next(h.queue.negativeCache),nil,'review is not proof of no listings')
end)
Test('normal price change takes one listing observation',function()
 local h=Boot();local m=h:loadMaterialPrices();assert(m:ObserveConfirmedPrice(14627,1,8950,'market_price:1'))
 h.syncComplete=true;h.onSearch=function()return {Listing(14627,8800,2)}end
 assert(Strict(h,'user',14627));h:advance(10000)
 Eq(h.deliveries[1].price,8800);Eq(h:count('SearchAuctionArticle'),1)
end)
Test('strict re-quote cannot accept bid-only row as current buyout cost',function()
 local h=Boot();h.syncComplete=true;h.onSearch=function()local r=Listing(101,100);r.directPrice=nil;r.bidPrice=10;return {r}end
 assert(Strict(h,'user',101));h:advance(10000)
 assert(h.deliveries[1].status~='ready','bid is not immediately purchasable');Eq(h.queue:GetPriceByItemType(101,1),nil)
end)
Test('strict request cannot accept a conflicting grade',function()
 local h=Boot();h.syncComplete=true;h.onSearch=function()local r=Listing(101,594);r.itemGrade=3;return {r}end
 assert(Strict(h,'user',101));h:advance(10000);assert(h.deliveries[1].status~='ready')
end)
Test('strict request joins and upgrades queued background identity',function()
 local h=Boot();h.lowest[30901]=1500;h.syncComplete=true;h.onSearch=function()return {Listing(30901,594)}end
 assert(h:quote('bg',30901,'香料',{priority='background',searchName='香料'}));assert(Strict(h,'user',30901,'香料'))
 h:advance(12000);Eq(h:count('SearchAuctionArticle'),1);Eq(#h.deliveries,2)
 for _,r in ipairs(h.deliveries)do Eq(r.price,594)end
end)
Test('strict request upgrades in-progress unsent market read without duplicate native search',function()
 local h=Boot();h.lowest[30901]=1500;h.syncComplete=true;h.onSearch=function()return {Listing(30901,594)}end
 assert(h:quote('bg',30901,'香料',{priority='background',searchName='香料'}));h:advance(2000)
 assert(Strict(h,'user',30901,'香料'));h:advance(12000)
 Eq(h:count('SearchAuctionArticle'),1);for _,r in ipairs(h.deliveries)do Eq(r.price,594)end
end)
-- 维护（auction-full-lane-safety-1）：unknown 时所有价格请求均停本地，不再把 ID 通道当作安全旁路。
Test('unknown admission parks both requests and user-priority ID quote resumes first after close',function()
 local h=Boot();Unknown(h)
 assert(h:quote('bg',3545,'燕麦',{priority='background',searchName='燕麦'}));h:advance(6000)
 h.lowest[30901]=594;assert(h:quote('user',30901,'香料',{priority='user',searchName='香料'}));h:advance(6000)
 Eq(h:count('AskMarketPrice'),0);Eq(h:count('GetLowestPrice'),0);Eq(h:count('SearchAuctionArticle'),0)
 Eq(#h.deliveries,0);Eq(h.queue.pending,nil,'parked requests do not own Native slot')
 ADDON.GetContentMainScriptPosVis=function()return nil,nil,nil,nil,false end
 h:advance(5000)
 Eq(#h.deliveries,1);Eq(h.deliveries[1].requester,'user');Eq(h.deliveries[1].price,594)
 Eq(h:count('SearchAuctionArticle'),0,'background did not get ahead of user request')
 h.queue:CancelRequester('bg')
end)
Test('13 unknown materials reach explicit blocked terminal and release lane with no negative cache',function()
 local h=Boot();Unknown(h)
 for id=3545,3557 do assert(h:quote('bg:'..id,id,'材料'..id,{priority='background',searchName='材料'..id}))end
 h:advance(180000);Eq(#h.deliveries,13)
 for _,r in ipairs(h.deliveries)do Eq(r.status,'blocked')end
 Eq(h:count('SearchAuctionArticle'),0);Eq(h.queue.running,false);Eq(next(h.queue.negativeCache),nil)
 Eq(h.queue.pending,nil);Eq(h.queue:Describe().admissionWaiting,0)
end)
Test('unknown is waiting during the grace period and resumes with real closed evidence',function()
 local h=Boot();Unknown(h);assert(Strict(h,'user',101));h:advance(30000)
 Eq(#h.deliveries,0);Eq(h:count('SearchAuctionArticle'),0)
 ADDON.GetContentMainScriptPosVis=function()return nil,nil,nil,nil,false end
 h.syncComplete=true;h.onSearch=function()return {Listing(101,594)}end;h:advance(12000)
 Eq(h.deliveries[1].price,594);Eq(h.queue.running,false)
end)
Test('known visible user auction is never stolen and remains resumable after minutes',function()
 local h=Boot();h.visible=true;assert(Strict(h,'user',101));h:advance(120000)
 Eq(h:count('SearchAuctionArticle'),0);Eq(#h.deliveries,0)
 h.visible=false;h.syncComplete=true;h.onSearch=function()return {Listing(101,594)}end;h:advance(10000)
 Eq(h.deliveries[1].price,594)
end)
Test('cancelling final local waiter releases its lane and never revives on window close',function()
 local h=Boot();Unknown(h);assert(Strict(h,'user',101));h:advance(6000);h.queue:CancelRequester('user')
 Eq(h.queue.running,false);Eq(h.queue:Describe().admissionWaiting,0)
 ADDON.GetContentMainScriptPosVis=function()return nil,nil,nil,nil,false end;h:advance(60000)
 Eq(h:count('SearchAuctionArticle'),0);Eq(#h.deliveries,0)
end)
Test('cancelling one waiter preserves other watcher on same identity',function()
 local h=Boot();Unknown(h);assert(Strict(h,'a',101));h:advance(6000);assert(Strict(h,'b',101));h.queue:CancelRequester('a')
 ADDON.GetContentMainScriptPosVis=function()return nil,nil,nil,nil,false end
 h.syncComplete=true;h.onSearch=function()return {Listing(101,594)}end;h:advance(10000)
 Eq(#h.deliveries,1);Eq(h.deliveries[1].requester,'b');Eq(h.deliveries[1].price,594)
end)
Test('admission waiters and new work share one bounded capacity',function()
 local h=Boot();Unknown(h);h.queue.maxQueue=3
 for id=1,3 do assert(Strict(h,'u'..id,id));h:advance(2000)end
 local ok=Strict(h,'overflow',4);Eq(ok,false,'parking cannot bypass queue bound')
end)
Test('uncached pending material requests are counted in diagnostics and cleared on blocked completion',function()
 local h=Boot();Unknown(h);local m=h:loadMaterialPrices()
 for id=3545,3547 do assert(m:RequestRevalidate({itemType=id,itemGrade=1,name='材料'..id},{}))end
 Eq(m:Describe().refreshPending,3);h:advance(90000);Eq(m:Describe().refreshPending,0)
end)
Test('service diagnostics do not trigger a cold persistence load or native probe',function()
 local h=Boot();local m=h:loadMaterialPrices();local before=m.storeLoadAttempts
 local calls=#h.calls;local vis=h.visibilityReads
 m:Describe();h.queue:Describe();h.query:Describe()
 Eq(m.storeLoadAttempts,before);Eq(#h.calls,calls);Eq(h.visibilityReads,vis)
end)
Test('fresh user listing query records no extra per-frame loop or auction-sidecar owner',function()
 local h=Boot();h.syncComplete=true;h.onSearch=function()return {Listing(101,594)}end;assert(Strict(h,'user',101));h:advance(10000)
 Eq(h.surface.started,false);Eq(h.S.NativeImports.apiOwners['feature:tools_auction'],nil)
 local previous=nil;for _,c in ipairs(h.calls)do if c.method=='SearchAuctionArticle' or c.method=='AskMarketPrice' or c.method=='GetLowestPrice' then
  if previous then assert(c.at-previous>=h.queue.intervalMs)end;previous=c.at end end
 Eq(h.tasks[h.queue.taskName],nil)
end)
Test('resuming equal-priority local waiters preserves original request order',function()
 local h=Boot();Unknown(h)
 for id=101,103 do assert(Strict(h,'user:'..id,id));h:advance(2000) end
 local order={};h.syncComplete=true;h.onSearch=function()
  local id=h.queue.pending.itemType;order[#order+1]=id;return {Listing(id,594)}end
 ADDON.GetContentMainScriptPosVis=function()return nil,nil,nil,nil,false end
 h:advance(18000);Eq(#order,3);for i=1,3 do Eq(order[i],100+i,'same-priority FIFO')end
end)
Test('a passive requester cannot publish stale cached ready while the same item is being revalidated',function()
 local h=Boot();h.queue.cache['101:1']={price=1500,at=h.now}
 assert(Strict(h,'user',101));h:advance(1000)
 assert(h:quote('passive',101,'材料101',{searchName='材料101'}))
 Eq(#h.deliveries,0,'must join strict in-flight identity before consulting older cache')
 h.syncComplete=true;h.onSearch=function()return {Listing(101,594)}end;h:advance(12000)
 Eq(#h.deliveries,2);for _,v in ipairs(h.deliveries)do Eq(v.price,594)end
end)
Test('accepted listing correction invalidates only that stale TTL and negative identity',function()
 local h=Boot();h.queue.cache['101:1']={price=1500,at=h.now};h.queue.cache['999:1']={price=88,at=h.now}
 h.queue.negativeCache['101:1']={at=h.now,snapshot={status='unavailable'}}
 h.syncComplete=true;h.onSearch=function()return {Listing(101,594)}end;assert(Strict(h,'user',101));h:advance(12000)
 local cached=h.queue:PeekCached(101,1);assert(cached==nil or cached==594,'contradictory old TTL survives new accepted listing')
 Eq(h.queue.negativeCache['101:1'],nil);Eq(h.queue:PeekCached(999,1),88,'unrelated item retained')
end)
Test('unknown visibility keeps read-only bounded evidence about the failing native boundary',function()
 local h=Boot();Unknown(h);assert(Strict(h,'user',101));h:advance(8000)
 local before=#h.calls;local reads=h.visibilityReads;local d=h.query:Describe()
 local p=d.visibility and d.visibility.probe;assert(type(p)=='table','missing visibility probe')
 Eq(p.contentId,9001);Eq(p.mainCallOk,true);Eq(p.mainReturnTypes,'nil,nil,nil,nil,nil');Eq(p.contentType,'nil')
 Eq(d.visibility.known,false);Eq(#h.calls,before);Eq(h.visibilityReads,reads)
 p.mainCallOk=false;Eq(h.query:Describe().visibility.probe.mainCallOk,true,'detached evidence')
 Eq(h.surface.started,false)
end)
Test('explicit false visibility remains a closed fact with no geometry guessed into the decision',function()
 local h=Boot();h.content=nil;ADDON.GetContentMainScriptPosVis=function()return nil,nil,nil,nil,false end
 local allowed=h.query:CanBackgroundSearch();Eq(allowed,true)
 local d=h.query:Describe();Eq(d.visibility.known,true);Eq(d.visibility.visible,false)
 Eq(d.visibility.probe.mainReturnTypes,'nil,nil,nil,nil,boolean')
end)
Test('cancelling the last watcher during an in-flight first observation never starts a second search',function()
 local h=Boot();local m=h:loadMaterialPrices();assert(m:ObserveConfirmedPrice(101,1,1500,'market_price:1'))
 assert(Strict(h,'user',101));h:untilSearch();h.queue:CancelRequester('user')
 h:searched({Listing(101,594)});h:advance(25000)
 Eq(h:count('SearchAuctionArticle'),1,'no new demand after cancellation')
 Eq(#h.deliveries,0);Eq(h.queue.running,false);Eq(m:GetPrice(101,1),1500)
 Eq(next(h.queue.negativeCache),nil,'cancel is not evidence of empty market')
end)
print('TRADE REQUOTE PIPELINE '..passed..'/'..total..' '.._VERSION)
assert(passed==total,'trade requote pipeline failures')
