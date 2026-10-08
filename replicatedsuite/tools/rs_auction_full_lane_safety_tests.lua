-- 维护（2026-10-01，auction-full-lane-safety-1）：实际加载服务，Native/时钟/持久化使用既有边界宿主。
-- 复现本轮全 nil 可见性、前半段市场价仍发包、SWR 周期复活和后台需求未释放；不证明 RU 实机验收。
local Boot = dofile('tools/rs_trade_requote_test_host.lua')
local passed,total=0,0
local function Eq(a,b,m) assert(a==b,(m or 'value')..': expected='..tostring(b)..' actual='..tostring(a)) end
local function Test(name,fn) total=total+1;local ok,e=xpcall(fn,debug.traceback)
 if ok then passed=passed+1;print('PASS '..name) else print('FAIL '..name..': '..tostring(e)) end end
local function Unknown(h)
 h.content=nil
 ADDON.GetContentMainScriptPosVis=function()h.visibilityReads=h.visibilityReads+1;return nil,nil,nil,nil,nil end
 -- 中文维护注释（2026-10-02）：成功返回 nil 是实机关闭形态；unknown 用确实失败的内容读取证明。
 ADDON.GetContent=function()error('native_content_unreadable')end
end
local function NoRequests(h)
 Eq(h:count('AskMarketPrice'),0,'no market-price request')
 Eq(h:count('GetLowestPrice'),0,'no market-price read/request')
 Eq(h:count('SearchAuctionArticle'),0,'no name search')
end
local function Closed() ADDON.GetContentMainScriptPosVis=function()return nil,nil,nil,nil,false end end
Test('visible native auction blocks all three price endpoints, not only name fallback',function()
 local h=Boot();h.visible=true;h.lowest[101]=594;assert(h:quote('row',101));h:advance(30000)
 NoRequests(h);Eq(#h.deliveries,0,'pause is not completion');Eq(h.queue:GetActivitySnapshot().paused,true)
end)
Test('all-nil geometry with failed content read blocks requests and ends all local waiters',function()
 local h=Boot();Unknown(h)
 for id=101,112 do assert(h:quote('row:'..id,id))end
 h:advance(5000);NoRequests(h)
 h:advance(55000);Eq(#h.deliveries,12)
 for _,r in ipairs(h.deliveries)do Eq(r.status,'blocked');Eq(r.blockReason,'native_auction_visibility_unknown')end
 Eq(h.queue.running,false);Eq(h.queue.pending,nil);Eq(h.queue:Describe().admissionWaiting,0)
 Eq(next(h.queue.negativeCache),nil,'visibility is not evidence of no listings')
end)
Test('opening between Ask and Read yields before readback and restarts handshake after close',function()
 local h=Boot();h.lowest[101]=594;assert(h:quote('row',101));h:advance(2000)
 Eq(h:count('AskMarketPrice'),1);Eq(h:count('GetLowestPrice'),0)
 h.visible=true;h.lowest[101]=99999;h:advance(10000)
 Eq(h:count('GetLowestPrice'),0,'must not consume user-session data');Eq(#h.deliveries,0)
 h.visible=false;h.lowest[101]=594;h:advance(10000)
 Eq(h:count('AskMarketPrice'),2,'fresh Ask required after losing ownership')
 Eq(#h.deliveries,1);Eq(h.deliveries[1].price,594)
end)
Test('closed native auction still permits paced ID price requests',function()
 local h=Boot();h.lowest[101]=594;h.lowest[102]=8800
 assert(h:quote('a',101));assert(h:quote('b',102));h:advance(10000)
 Eq(#h.deliveries,2);Eq(h:count('AskMarketPrice'),2);Eq(h:count('GetLowestPrice'),2)
 local last=nil
 for _,c in ipairs(h.calls)do if c.method=='AskMarketPrice' or c.method=='GetLowestPrice' or c.method=='SearchAuctionArticle' then
  if last then assert(c.at-last>=h.queue.intervalMs,'native quote pacing violated')end;last=c.at
 end end
end)
Test('cached local quote stays readable while native auction is in use',function()
 local h=Boot();h.visible=true;h.queue.cache['101:1']={price=594,at=h.now}
 assert(h:quote('cached',101,'材料101',{searchName='材料101'}));h:advance(5000)
 NoRequests(h);Eq(#h.deliveries,1);Eq(h.deliveries[1].price,594)
end)
Test('explicit auction search remains available while every material query is parked',function()
 local h=Boot();Unknown(h);assert(h:quote('row',101));h:advance(5000);NoRequests(h)
 assert(h.query:Search('tools_auction','玩家关键词',{}));Eq(h:count('SearchAuctionArticle'),1)
 Eq(h:count('AskMarketPrice'),0);h:searched({});Eq(h.query.pending,nil)
end)
Test('unknown SWR failure does not resurrect on each route refresh',function()
 local h=Boot();Unknown(h);local m=h:loadMaterialPrices()
 local materials={{itemType=101,name='材料101'},{itemType=102,name='材料102'}}
 for _=1,30 do assert(m:QueueRevalidate(materials,{owner='life_trade'}));h:advance(10000)end
 Eq(m.stats.backgroundSubmitted,2,'one bounded attempt per material, not periodic resurrection')
 Eq(m:Describe().refreshPending,0);Eq(h.queue.running,false);NoRequests(h)
 Eq(h.queue:GetQuoteStateByItemType(101,1).status,'blocked','terminal state survives passive rebuilds')
end)
Test('closed evidence releases SWR circuit without reload and still obtains fresh prices',function()
 local h=Boot();Unknown(h);local m=h:loadMaterialPrices();local material={itemType=101,name='材料101'}
 assert(m:RequestRevalidate(material,{owner='life_trade'}));h:advance(60000)
 Closed();h.lowest[101]=594;assert(m:RequestRevalidate(material,{owner='life_trade'}));h:advance(10000)
 Eq(m:GetPrice(101,1),594);Eq(m:Describe().refreshPending,0);Eq(h:count('AskMarketPrice'),1)
end)
Test('cancelling background owner releases parked requests and prevents restart after close',function()
 local h=Boot();Unknown(h);local m=h:loadMaterialPrices()
 assert(m:RequestRevalidate({itemType=101,name='材料101'},{owner='life_trade'}));h:advance(5000)
 assert(type(m.CancelRevalidationOwner)=='function','background owner has no cancellation boundary')
 assert(m:CancelRevalidationOwner('life_trade'));Eq(m:Describe().refreshPending,0);Eq(h.queue.running,false)
 Closed();h:advance(60000);NoRequests(h)
end)
Test('background ownership cancellation preserves a second owner and explicit same-material watcher',function()
 local h=Boot();Unknown(h);local m=h:loadMaterialPrices();local material={itemType=101,name='材料101'}
 assert(m:RequestRevalidate(material,{owner='life_trade'}));assert(m:RequestRevalidate(material,{owner='craft'}))
 assert(h:quote('explicit',101));h:advance(5000)
 assert(type(m.CancelRevalidationOwner)=='function','background owner has no cancellation boundary')
 assert(m:CancelRevalidationOwner('life_trade'));Eq(m:Describe().refreshPending,1)
 assert(m:CancelRevalidationOwner('craft'));Eq(m:Describe().refreshPending,0);Eq(h.queue.running,true)
 Closed();h.lowest[101]=594;h:advance(10000);Eq(#h.deliveries,1);Eq(h.deliveries[1].requester,'explicit')
end)
Test('new diagnostics only read cached guard facts',function()
 local h=Boot();Unknown(h);local m=h:loadMaterialPrices();assert(h:quote('row',101));h:advance(5000)
 local reads,calls=h.visibilityReads,#h.calls;local q=h.queue:Describe();m:Describe()
 Eq(h.visibilityReads,reads);Eq(#h.calls,calls)
 Eq(q.nativeInteractionPatch,'auction-full-lane-safety-1')
end)
-- 维护（auction-full-lane-safety-1）：协议探针和恢复诊断也必须遵守同一边界。
Test('closed admission returns no contradictory blocked reason',function()
 local h=Boot();local allowed,reason=h.queue:CanNativeQuote()
 Eq(allowed,true);Eq(reason,nil);Eq(h.queue:Describe().nativeAdmission.reason,nil)
end)
Test('manual protocol probe cannot bypass visible or unknown native auction',function()
 local h=Boot();h.visible=true
 local ok,reason=h.queue:RunProtocolProbe();Eq(ok,false);Eq(reason,'native_auction_visible');NoRequests(h)
 Unknown(h);ok,reason=h.queue:RunProtocolProbe()
 Eq(ok,false);Eq(reason,'native_auction_visibility_unknown');NoRequests(h)
end)
Test('manual protocol probe respects quote ownership and shared interval',function()
 local h=Boot();assert(h:quote('row',101))
 local ok,reason=h.queue:RunProtocolProbe();Eq(ok,false);Eq(reason,'price_quote_busy');NoRequests(h)
 h.queue:CancelRequester('row');assert(h.queue:RunProtocolProbe());Eq(h:count('GetLowestPrice'),1)
 ok,reason=h.queue:RunProtocolProbe();Eq(ok,false);Eq(reason,'quote_cooldown');Eq(h:count('GetLowestPrice'),1)
 h:advance(h.queue.intervalMs);assert(h.queue:RunProtocolProbe());Eq(h:count('GetLowestPrice'),2)
end)
Test('native visibility is rechecked at the Ask boundary after local dequeue',function()
 local h=Boot();assert(h:quote('row',101));h:advance(1000)
 -- Next drain sees closed at entry, but the last-boundary probe observes the user's window.
 local reads=h.visibilityReads;h.onVisibilityRead=function(n)if n>=reads+2 then h.visible=true end end
 h:advance(1000);NoRequests(h);Eq(#h.deliveries,0)
 h.onVisibilityRead=nil;h.visible=false;h.lowest[101]=594;h:advance(10000)
 Eq(#h.deliveries,1);Eq(h.deliveries[1].price,594)
end)
print('AUCTION_FULL_LANE_SAFETY '..passed..'/'..total..' ('.._VERSION..')')
assert(passed==total,'auction full lane safety regressions failed')
