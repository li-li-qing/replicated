-- Native-only host: these assertions load the real Queue, AuctionQuery, Api and Surface.
local Boot = dofile('tools/rs_trade_requote_test_host.lua')
local passed, total = 0, 0
local function Eq(a,b,m) assert(a==b,(m or 'value')..': expected='..tostring(b)..' actual='..tostring(a)) end
local function Test(name,fn) total=total+1;local ok,err=xpcall(fn,debug.traceback)
 if ok then passed=passed+1;print('PASS '..name) else print('FAIL '..name..': '..tostring(err)) end end
local function Listing(id,price,grade,stack)
 return {itemType=id,itemGrade=grade==nil and 1 or grade,itemStack=stack or 10,directPrice=price*(stack or 10)}
end
local function Strict(h,token,id,options,callback)
 options=options or {};options.singleQuery=true;options.searchName=options.searchName or ('材料'..id)
 options.priority=options.priority or 'user'
 return h.queue:RequestQuote(token,id,1,callback or function(r)h.deliveries[#h.deliveries+1]=r end,{0,1,2,3},options)
end
-- 中文维护注释（2026-10-02）：复现 MD1.3.life_trade 实机报告：两个受许可 getter 均成功，
-- UIC_AUCTION 未创建/已关闭时内容对象与五个 MainScript 字段全为空。不得继续把这个现场当 API 故障。
local function Absent(h)
 h.content=nil
 ADDON.GetContentMainScriptPosVis=function()h.visibilityReads=h.visibilityReads+1;return nil,nil,nil,nil,nil end
end
Test('live all-nil geometry plus successfully absent content proves closed without starting observer',function()
 local h=Boot();Absent(h);local events,revision=#h.events,h.surface.revision
 local known,visible,source,probe=h.surface:ReadVisibility()
 Eq(known,true);Eq(visible,false);Eq(source,'content-absent');Eq(probe.contentReadOk,true);Eq(probe.contentAbsent,true)
 local snapshot=h.surface:_Read();Eq(snapshot.status,'ready');Eq(snapshot.visible,false);Eq(snapshot.source,'content-absent')
 Eq(#h.events,events);Eq(h.surface.revision,revision);Eq(next(h.tasks),nil,'observation remains demand-only')
end)
Test('cold absent native auction allows one strict material search and reliable price',function()
 local h=Boot();Absent(h);h.syncComplete=true;h.onSearch=function()return {Listing(101,70)}end
 assert(Strict(h,'user',101));h:advance(3000)
 Eq(h:count('SearchAuctionArticle'),1);Eq(h:count('AskMarketPrice'),0);Eq(h:count('GetLowestPrice'),0)
 Eq(#h.deliveries,1);Eq(h.deliveries[1].status,'ready');Eq(h.deliveries[1].price,70);Eq(h.textWrites,0)
 Eq(h.queue.running,false);Eq(#h.queue.admissionWaiting,0)
end)
Test('open native auction parks background then resumes when content disappears on close',function()
 local h=Boot();h.visible=true;assert(Strict(h,'bg',101,{priority='background'}));h:advance(5000)
 Eq(h:count('SearchAuctionArticle'),0);Eq(#h.deliveries,0)
 Absent(h);h.syncComplete=true;h.onSearch=function()return {Listing(101,70)}end;h:advance(3000)
 Eq(h:count('SearchAuctionArticle'),1);Eq(#h.deliveries,1);Eq(h.deliveries[1].price,70);Eq(h.textWrites,0)
 Eq(h.queue.running,false);Eq(#h.queue.admissionWaiting,0)
end)
Test('absent content cannot turn failures blocked capabilities or malformed geometry into closed',function()
 for _,kind in ipairs({'main_error','content_error','main_missing','content_missing','main_blocked','content_blocked',
   'wrapper_missing','content_false','unreadable_object','partial_geometry','zero_geometry','invalid_category'})do
  local h=Boot();Absent(h)
  if kind=='main_error'then ADDON.GetContentMainScriptPosVis=function()error('native_failed')end
  elseif kind=='content_error'then ADDON.GetContent=function()error('native_failed')end
  elseif kind=='main_missing'then ADDON.GetContentMainScriptPosVis=nil
  elseif kind=='content_missing'then ADDON.GetContent=nil
  elseif kind=='main_blocked'or kind=='content_blocked'then
   local denied=kind=='main_blocked'and 'ADDON:GetContentMainScriptPosVis'or 'ADDON:GetContent'
   local allowed=h.S.Api.IsCapabilityAllowed;h.S.Api.IsCapabilityAllowed=function(api,name)if name==denied then return false end;return allowed(api,name)end
  elseif kind=='wrapper_missing'then h.S.Api.CallCapability=nil
  elseif kind=='content_false'then h.content=false
  elseif kind=='unreadable_object'then h.content={}
  elseif kind=='partial_geometry'then ADDON.GetContentMainScriptPosVis=function()return 200,nil,nil,nil,nil end
  elseif kind=='zero_geometry'then ADDON.GetContentMainScriptPosVis=function()return 0,0,0,0,nil end
  elseif kind=='invalid_category'then UIC_AUCTION=nil end
  local known=h.surface:ReadVisibility();Eq(known,false,kind)
  assert(Strict(h,'user',101));Eq(h:count('SearchAuctionArticle'),0,kind);Eq(#h.deliveries,1);Eq(h.deliveries[1].status,'blocked',kind)
 end
end)
Test('plausible native geometry stays open even when content getter returns nil',function()
 local h=Boot();h.content=nil;h.omitVisibility=true
 local known,visible=h.surface:ReadVisibility();Eq(known,true);Eq(visible,true)
 assert(Strict(h,'user',101));Eq(h:count('SearchAuctionArticle'),0);Eq(h.deliveries[1].status,'blocked')
end)
Test('native opens between absent admission and query boundary so no search is sent',function()
 local h=Boot();Absent(h)
 ADDON.GetContentMainScriptPosVis=function()
  h.visibilityReads=h.visibilityReads+1
  if h.visibilityReads>=2 then return 200,150,800,600,true end
  return nil,nil,nil,nil,nil
 end
 assert(Strict(h,'user',101));Eq(h:count('SearchAuctionArticle'),0);Eq(#h.deliveries,1);Eq(h.deliveries[1].status,'blocked')
end)
Test('singleQuery sends one nine-argument search and compares at most three sampled unit buyouts',function()
 local h=Boot();h.syncComplete=true
 h.onSearch=function()return {Listing(999,1),Listing(101,20,3),Listing(101,70),Listing(101,1)}end
 assert(Strict(h,'user',101));h:advance(1000)
 Eq(h:count('AskMarketPrice'),0);Eq(h:count('GetLowestPrice'),0);Eq(h:count('SearchAuctionArticle'),1)
 Eq(h:count('GetSearchedItemInfo'),3);Eq(h:count('GetSearchedItemTotalCount'),0);Eq(#h.deliveries,1);Eq(h.deliveries[1].price,70)
 -- 名称是候选筛选，精确身份在真实 Query 的 firstValidBuyout 边界验证；不强制 Native exact 名称。
 local args=h.calls[1].args;Eq(#args,9);Eq(args[1],1);Eq(args[4],1);Eq(args[5],0);Eq(args[6],false)
 Eq(h.deliveries[1].singleQuery,true);Eq(h.queue.running,false)
end)
Test('strict rejects absent identity grade quantity and bid-only evidence',function()
 for _,kind in ipairs({'id','grade','quantity','bid'})do
  local h=Boot();h.syncComplete=true
  h.onSearch=function()local r=Listing(101,70);if kind=='id'then r.itemType=nil elseif kind=='grade'then r.itemGrade=nil
   elseif kind=='quantity'then r.itemStack=nil else r.directPrice=nil;r.bidPrice=700 end;return {r}end
  assert(Strict(h,'user',101));h:advance(6000)
  Eq(#h.deliveries,1);Eq(h.deliveries[1].status,'unavailable');Eq(h:count('SearchAuctionArticle'),1)
 end
end)
Test('strict anomaly records once retains accepted price and never triggers second search',function()
 local h=Boot();local m=h:loadMaterialPrices();assert(m:ObserveConfirmedPrice(101,1,1500,'market_price:1'))
 h.syncComplete=true;h.onSearch=function()return {Listing(101,594)}end
 assert(Strict(h,'user',101));h:advance(20000)
 Eq(h:count('SearchAuctionArticle'),1);Eq(#h.deliveries,1);Eq(h.deliveries[1].status,'review_required')
 Eq(h.deliveries[1].price,nil);Eq(m:GetPrice(101,1),1500);Eq(h.queue.running,false)
end)
Test('unknown or open native surface is immediately blocked with no native request or parked work',function()
 for _,kind in ipairs({'unknown','visible'})do
  -- 中文维护注释：unknown 必须模拟实际读取失败；正常成功返回 nil 的关闭窗口已有独立回归。
  local h=Boot();if kind=='visible'then h.visible=true else Absent(h);ADDON.GetContent=function()error('native_content_failed')end end
  assert(Strict(h,'user',101));Eq(#h.deliveries,1);Eq(h.deliveries[1].status,'blocked')
  Eq(h:count('SearchAuctionArticle'),0);Eq(h:count('AskMarketPrice'),0);Eq(h.queue.pending,nil)
  Eq(#h.queue.admissionWaiting,0);Eq(h.queue.running,false);Eq(next(h.queue.negativeCache),nil)
 end
end)
Test('deadline terminal releases strict queue but quarantines original un-tokened native lifetime',function()
 local h=Boot();local at=h.now;assert(Strict(h,'user',101,{deadlineAt=at+2100}))
 Eq(h:count('SearchAuctionArticle'),1);local nativeExpiry=h.query.pending.expiresAt
 h:advance(2100);Eq(#h.deliveries,1);Eq(h.deliveries[1].status,'timeout');Eq(h.queue.pending,nil)
 Eq(h.queue.running,false);Eq(h.query.pending.discarded,true);Eq(h.query.pending.expiresAt,nativeExpiry)
 h:searched({Listing(101,70)});Eq(h:count('GetSearchedItemInfo'),0);Eq(#h.deliveries,1)
 h:advance(nativeExpiry-h.now);Eq(h.query.pending,nil);Eq(next(h.tasks),nil)
end)
Test('default strict wait ends at five seconds without native response',function()
 local h=Boot();assert(Strict(h,'user',101));h:advance(5000)
 Eq(#h.deliveries,1);Eq(h.deliveries[1].status,'timeout');Eq(h.queue.running,false)
 Eq(h:count('SearchAuctionArticle'),1)
end)
Test('strict coalesces id and grade despite different names and leaves another watcher alive on cancel',function()
 local h=Boot();assert(Strict(h,'a',101,{searchName='甲'}));assert(Strict(h,'b',101,{searchName='乙'}))
 h.queue:CancelRequester('a');h:searched({Listing(101,70)});h:advance(1000)
 Eq(h:count('SearchAuctionArticle'),1);Eq(#h.deliveries,1);Eq(h.deliveries[1].requester,'b')
 Eq(h.deliveries[1].price,70);Eq(h.queue.running,false)
end)
Test('strict final cancellation yields owned native and fences stale search callbacks from later generation',function()
 local h=Boot();assert(Strict(h,'same',101));local oldFn;for _,fn in pairs(h.native.AUCTION_ITEM_SEARCHED)do oldFn=fn end
 local oldAt=h.query.pending.expiresAt;h.queue:CancelRequester('same')
 Eq(h.queue.pending,nil);Eq(h.query.pending.discarded,true);Eq(h.queue.running,false)
 h:advance(oldAt-h.now);assert(Strict(h,'same',102));oldFn();Eq(#h.deliveries,0)
 h:searched({Listing(102,90)});Eq(#h.deliveries,1);Eq(h.deliveries[1].itemType,102)
 Eq(h.deliveries[1].price,90)
end)
Test('strict user yields an unsent background legacy pending without joining its weaker request',function()
 local h=Boot();h.lowest[101]=12
 assert(h:quote('legacy',101,'材料101',{priority='background',searchName='材料101'}));h:advance(1000)
 Eq(h:count('AskMarketPrice'),0);assert(h.queue.pending~=nil)
 h.syncComplete=true;h.onSearch=function()return {Listing(101,70)}end
 assert(Strict(h,'user',101));Eq(h:count('SearchAuctionArticle'),1)
 Eq(#h.deliveries,1);Eq(h.deliveries[1].requester,'user');Eq(h.deliveries[1].price,70)
 h:advance(4000);Eq(#h.deliveries,2);Eq(h.deliveries[2].requester,'legacy');Eq(h.deliveries[2].price,12)
end)
Test('strict user does not preempt an already sent un-tokened background query',function()
 local h=Boot();assert(Strict(h,'bg',101,{priority='background'}));h:advance(1000)
 Eq(h:count('SearchAuctionArticle'),1);assert(Strict(h,'user',102));Eq(h:count('SearchAuctionArticle'),1)
 h:searched({Listing(101,70)});h:advance(1000);Eq(h:count('SearchAuctionArticle'),2)
 h:searched({Listing(102,90)});Eq(#h.deliveries,2);Eq(h.deliveries[2].requester,'user')
end)
Test('four sequential fast materials use four paced searches inside five seconds',function()
 local h=Boot();h.syncComplete=true;h.onSearch=function(name)local id=tonumber(name:match('%d+'));return {Listing(id,id)}end
 local completed=0;local function Next(r)completed=completed+1;if completed<4 then assert(Strict(h,'row:'..completed,101+completed,nil,Next))end end
 local start=h.now;assert(Strict(h,'row:0',101,nil,Next));h:advance(4000)
 Eq(completed,4);Eq(h:count('SearchAuctionArticle'),4);Eq(h:count('AskMarketPrice'),0)
 local prev;for _,call in ipairs(h.calls)do if call.method=='SearchAuctionArticle'then
  if prev then assert(call.at-prev>=1000,'cooldown respected')end;prev=call.at end end
 assert(prev-start<5000,'no two-tick startup per material')
end)
Test('lost internal completion notification is recovered by bounded queue poll without requery',function()
 local h=Boot();assert(Strict(h,'user',101));h.internal[h.query.Topic]={}
 h:searched({Listing(101,70)});h:advance(1000);Eq(#h.deliveries,1);Eq(h.deliveries[1].price,70)
 Eq(h:count('SearchAuctionArticle'),1);Eq(h.queue.running,false)
end)
Test('requester reuse fences earlier callback even without explicit cancellation',function()
 local h=Boot();assert(Strict(h,'same',101));assert(Strict(h,'same',102))
 h:searched({Listing(101,70)});h:advance(1000);h:searched({Listing(102,90)})
 Eq(#h.deliveries,1);Eq(h.deliveries[1].itemType,102)
end)
Test('strict sharing respects the earlier caller deadline without sending a second search',function()
 local h=Boot();assert(Strict(h,'a',101,{deadlineAt=h.now+5000}));assert(Strict(h,'b',101,{deadlineAt=h.now+1200}))
 h:advance(1200);Eq(#h.deliveries,2);for _,r in ipairs(h.deliveries)do Eq(r.status,'timeout')end
 Eq(h:count('SearchAuctionArticle'),1);Eq(h.queue.pending,nil)
end)
Test('finished strict generations release their AuctionQuery snapshots including canceled drains',function()
 local h=Boot();h.syncComplete=true;h.onSearch=function()return {Listing(101,70)}end
 assert(Strict(h,'one',101));Eq(next(h.query.snapshots),nil,'strict snapshot consumed')
 h:advance(1000);h.syncComplete=false;assert(Strict(h,'two',101));h.queue:CancelRequester('two')
 h:advance(8000);Eq(next(h.query.snapshots),nil,'drained snapshot released');Eq(next(h.queue.singleQueryWatchers),nil)
end)
Test('strict result identity is exact rather than floored from malformed numeric grades or ids',function()
 for _,field in ipairs({'itemType','itemGrade'})do
  local h=Boot();h.syncComplete=true;h.onSearch=function()local r=Listing(101,70);r[field]=r[field]+0.9;return {r}end
  assert(Strict(h,'user',101));Eq(h.deliveries[1].status,'unavailable')
 end
end)
Test('queued strict deadline expires during a pre-existing manual native query without preemption',function()
 local h=Boot();assert(h.query:Search('manual','用户查询',{}));assert(Strict(h,'user',101,{deadlineAt=h.now+1000}))
 h:advance(1000);Eq(#h.deliveries,1);assert(h.deliveries[1].status=='blocked' or h.deliveries[1].status=='timeout')
 Eq(h:count('SearchAuctionArticle'),1);Eq(h.query.pending.requester,'manual');Eq(h.query.pending.discarded,nil)
end)
Test('strict requester snapshot retention stays bounded across immediate blocked requests',function()
 local h=Boot();h.visible=true
 for i=1,h.queue.cacheMax+10 do assert(Strict(h,'blocked:'..i,101))end
 local n=0;for _ in pairs(h.queue.snapshots)do n=n+1 end
 assert(n<=h.queue.cacheMax,'strict requester snapshots must be bounded: '..n)
end)
Test('new strict watcher immediately stops sharing when native visibility becomes unsafe',function()
 local h=Boot();assert(Strict(h,'a',101));h.visible=true;assert(Strict(h,'b',101))
 Eq(#h.deliveries,2);for _,r in ipairs(h.deliveries)do Eq(r.status,'blocked')end
 Eq(h:count('SearchAuctionArticle'),1);Eq(h.query.pending.discarded,true)
end)
Test('missing capability boundary emits one terminal and removes strict deadline resources',function()
 local h=Boot();h.S.Api=nil;assert(Strict(h,'user',101));Eq(next(h.tasks),nil,'immediate terminal cleanup');h:advance(6000)
 Eq(#h.deliveries,1);Eq(next(h.tasks),nil);Eq(h.queue.running,false)
 Eq(next(h.queue.singleQueryWatchers),nil)
end)
Test('strict deadline registration failure sends no unbounded native request',function()
 local h=Boot();local original=h.S.Scheduler.AddOneShot
 function h.S.Scheduler:AddOneShot(id,...)if id:find('v3_price_quote_single_deadline:',1,true)then return false end;return original(self,id,...)end
 assert(Strict(h,'user',101));Eq(#h.deliveries,1);Eq(h.deliveries[1].status,'unavailable')
 Eq(h:count('SearchAuctionArticle'),0);Eq(next(h.tasks),nil);Eq(h.queue.running,false)
end)
Test('native synchronous rejection is terminal once without retry',function()
 local h=Boot();h.rejectSearch=true;assert(Strict(h,'user',101));h:advance(12000)
 Eq(#h.deliveries,1);Eq(h.deliveries[1].status,'unavailable');Eq(h:count('SearchAuctionArticle'),1)
 Eq(next(h.tasks),nil);Eq(next(h.query.snapshots),nil)
end)
Test('strict background parked while open resumes one search only after verified close',function()
 local h=Boot();h.visible=true;assert(Strict(h,'bg',101,{priority='background'}));h:advance(20000)
 Eq(#h.deliveries,0);Eq(h:count('SearchAuctionArticle'),0);Eq(#h.queue.admissionWaiting,1)
 h.visible=false;h.syncComplete=true;h.onSearch=function()return {Listing(101,70)}end;h:advance(3000)
 Eq(#h.deliveries,1);Eq(h.deliveries[1].price,70);Eq(h:count('SearchAuctionArticle'),1);Eq(h.queue.running,false)
end)
Test('canceling parked strict background releases lane and never resumes after closing',function()
 local h=Boot();h.visible=true;assert(Strict(h,'bg',101,{priority='background'}));h:advance(20000)
 h.queue:CancelRequester('bg');Eq(h.queue.running,false);Eq(next(h.tasks),nil);Eq(#h.queue.admissionWaiting,0)
 h.visible=false;h:advance(10000);Eq(h:count('SearchAuctionArticle'),0);Eq(#h.deliveries,0)
end)
Test('strict background unknown admission expires once at existing bounded limit',function()
 local h=Boot();Absent(h);ADDON.GetContent=function()error('native_content_failed')end
 assert(Strict(h,'bg',101,{priority='background'}));h:advance(44000);Eq(#h.deliveries,0)
 h:advance(1000);Eq(#h.deliveries,1);Eq(h.deliveries[1].status,'blocked');Eq(h:count('SearchAuctionArticle'),0)
 Eq(h.queue.running,false);Eq(next(h.tasks),nil);Eq(#h.queue.admissionWaiting,0)
end)
Test('foreground joining parked strict background immediately blocks both without native calls',function()
 local h=Boot();h.visible=true;assert(Strict(h,'bg',101,{priority='background'}));h:advance(10000)
 assert(Strict(h,'user',101));Eq(#h.deliveries,2);for _,r in ipairs(h.deliveries)do Eq(r.status,'blocked')end
 Eq(h:count('SearchAuctionArticle'),0);Eq(h.queue.running,false);Eq(#h.queue.admissionWaiting,0)
end)
Test('strict background dispatch owns five-second terminal after prolonged open admission',function()
 local h=Boot();h.visible=true;assert(Strict(h,'bg',101,{priority='background'}));h:advance(20000);h.visible=false
 h:advance(3000);Eq(h:count('SearchAuctionArticle'),1);local sentAt
 for _,call in ipairs(h.calls)do if call.method=='SearchAuctionArticle'then sentAt=call.at end end
 h:advance(sentAt+5000-h.now);Eq(#h.deliveries,1);Eq(h.deliveries[1].status,'timeout')
 Eq(h.queue.running,false);Eq(h.query.pending.discarded,true)
end)
Test('user promotion of queued strict background also yields an unsent legacy background pending',function()
 local h=Boot();assert(h:quote('legacy',99,'材料99',{priority='background',searchName='材料99'}));h:advance(1000)
 h.queue.lastNativeCallAt=h.now;assert(Strict(h,'bg',101,{priority='background'}));assert(Strict(h,'user',101))
 h.syncComplete=true;h.onSearch=function()return {Listing(101,70)}end;h:advance(1000)
 Eq(h:count('SearchAuctionArticle'),1);Eq(h:count('AskMarketPrice'),0);Eq(#h.deliveries,2)
end)
Test('bounded strict snapshot eviction preserves active requester state',function()
 local h=Boot();assert(Strict(h,'active',101));h.now=h.now+1;h.visible=true
 for i=1,h.queue.cacheMax+10 do assert(Strict(h,'blocked:'..i,102))end
 assert(h.queue:GetSnapshot('active').status~='idle','active snapshot must not be evicted by blocked callers')
 h.queue:CancelRequester('active')
end)
Test('strict rejection evidence identifies missing fields without inventing prices or retaining sellers',function()
 for _,kind in ipairs({'id_missing','id_mismatch','grade_missing','grade_mismatch','quantity_invalid','buyout_invalid'})do
  local h=Boot();h.syncComplete=true
  h.onSearch=function()
   local r=Listing(101,70);r.sellerName='PRIVATE_SELLER'
   if kind=='id_missing'then r.itemType=nil elseif kind=='id_mismatch'then r.itemType=102
   elseif kind=='grade_missing'then r.itemGrade=nil elseif kind=='grade_mismatch'then r.itemGrade=2
   elseif kind=='quantity_invalid'then r.itemStack=nil else r.directPrice=nil;r.bidPrice=700 end
   return {r}
  end
  assert(Strict(h,'user',101));h:advance(6000)
  Eq(h.deliveries[1].status,'unavailable');Eq(h.deliveries[1].price,nil)
  local calls=#h.calls;local d=h.query:DescribePriceEvidence();local r=d.requests[1]
  Eq(r.itemType,101);Eq(r.sourceCount,1);Eq(r.readCount,1);Eq(r.acceptedIndex,nil)
  assert(r.rejections:find(kind..'=1',1,true),r.rejections)
  assert(r.samples[1]:find(kind,1,true));assert(not r.samples[1]:find('PRIVATE_SELLER',1,true))
  Eq(#h.calls,calls,'evidence inspection cannot call native')
 end
end)
Test('price evidence distinguishes empty result from deadline without a callback',function()
 local h=Boot();h.syncComplete=true;h.onSearch=function()return {}end
 assert(Strict(h,'empty',101));h:advance(5000)
 local r=h.query:DescribePriceEvidence().requests[1]
 Eq(r.status,'empty');Eq(r.sourceCount,0);Eq(r.readCount,0);assert(r.callbackAt~=nil)
 h=Boot();assert(Strict(h,'timeout',101));h:advance(5000)
 r=h.query:DescribePriceEvidence().requests[1]
 Eq(r.error,'quote_deadline');assert(r.sentAt~=nil);Eq(r.callbackAt,nil);Eq(r.readCount,0)
 local sent=r.sentAt;h:advance(10000)
 r=h.query:DescribePriceEvidence().requests[1];Eq(r.error,'quote_deadline');Eq(r.sentAt,sent)
end)
Test('price evidence records unreadable native rows and detached nested money without altering normalization',function()
 for _,kind in ipairs({'info_call_failed','info_shape_invalid','candidate'})do
  local h=Boot();h.syncComplete=true
  h.onSearch=function()return {{item={itemTypeId='101',grade='1',stackCount='10',buyoutPrice={gold=0,silver=7,copper=0}}}}end
  if kind=='info_call_failed'then X2Auction.GetSearchedItemInfo=function()error('native getter failed')end
  elseif kind=='info_shape_invalid'then X2Auction.GetSearchedItemInfo=function()return 'unreadable' end end
  assert(Strict(h,'nested',101));h:advance(5000)
  local d=h.query:DescribePriceEvidence();local r=d.requests[1]
  Eq(r.readCount,1);Eq(r.countReturn,'number:1');assert(r.samples[1]:find(kind,1,true))
  if kind=='candidate'then
   Eq(h.deliveries[1].price,70);Eq(r.acceptedIndex,1)
   assert(r.samples[1]:find('qty=10 total=700 unit=70',1,true));assert(r.samples[1]:find('item.buyoutPrice=table',1,true))
  else Eq(h.deliveries[1].price,nil)end
 end
end)
Test('price evidence ring is bounded detached and survives strict snapshot release',function()
 local h=Boot();h.syncComplete=true;h.onSearch=function()return {Listing(h.queue.pending.itemType,70)}end
 for i=1,22 do assert(Strict(h,'user:'..i,100+i));h:advance(1100)end
 local d=h.query:DescribePriceEvidence();Eq(d.retained,16);Eq(#d.requests,8);Eq(d.requests[1].itemType,122)
 Eq(d.requests[1].acceptedIndex,1);Eq(d.requests[1].status,'ready')
 d.requests[1].samples[1]='changed';d.requests[1].itemType=999
 Eq(h.query:DescribePriceEvidence().requests[1].itemType,122)
 assert(h.query:DescribePriceEvidence().requests[1].samples[1]~='changed')
 local selected=h.query:DescribePriceEvidence({[105]=true,[120]=true})
 Eq(#selected.requests,1);Eq(selected.requests[1].itemType,120)
 Eq(next(h.query.snapshots),nil,'strict snapshots have been released')
end)
Test('detail retains only three already-read rejected listings including unfamiliar fields',function()
 local h=Boot();h.syncComplete=true
 h.onSearch=function()
  local rows={};for i=1,20 do rows[i]={itemType=101,itemGrade=1,itemStack=10,
   unknown_direct_money=123,mysteryDetails={qualityTier=i},sellerName='PRIVATE_SELLER'}end;return rows
 end
 assert(Strict(h,'user',101));h:advance(5000)
 Eq(h.queue.fallbackSearchLimit,20);Eq(h:count('GetSearchedItemInfo'),3);local calls=#h.calls
 local d=h.query:DescribePriceEvidenceDetail();local r=d.requests[1]
 Eq(r.sourceCount,20);Eq(r.unreadRows,17);Eq(#r.listingDetails,3);Eq(r.listingDetails[3].reason,'buyout_invalid')
 Eq(r.listingDetails[3].raw.unknown_direct_money,123);Eq(r.listingDetails[3].raw.mysteryDetails.qualityTier,3)
 Eq(r.listingDetails[1].raw.sellerName,nil);r.listingDetails[1].raw.itemType=999
 Eq(h.query:DescribePriceEvidenceDetail().requests[1].listingDetails[1].raw.itemType,101);Eq(#h.calls,calls)
 Eq(h.deliveries[1].price,nil)
end)
-- 维护（2026-10-02）：210656 实机报告中 16 个 Count 均为 number:0，不能据此推导事件没有数据。
-- 此处只验证参数保全和未知形状不报价；事件表的业务 schema 必须等真实 TXT，不能反造 ABI。
Test('empty cache preserves owner-first native event packet including nil and unknown fields without accepting its price',function()
 local h=Boot();assert(Strict(h,'event-packet',101))
 local packet={unknownPayload={itemType=101,directPrice=700},sellerName='PRIVATE_SELLER'};packet.cycle=packet
 h:searched({},packet,nil,false,0,'返回文本')
 Eq(#h.deliveries,1);Eq(h.deliveries[1].status,'unavailable');Eq(h.deliveries[1].price,nil)
 Eq(h.deliveries[1].error,'auction_search_empty')
 local calls=#h.calls;local r=h.query:DescribePriceEvidenceDetail().requests[1]
 Eq(r.eventPacket.argCount,5);Eq(r.eventPacket.types[1],'table');Eq(r.eventPacket.types[2],'nil')
 Eq(r.eventPacket.values[3],false);Eq(r.eventPacket.values[4],0);Eq(r.eventPacket.values[5],'返回文本')
 Eq(r.eventPacket.values[1].unknownPayload.directPrice,700);Eq(r.eventPacket.values[1].sellerName,nil)
 Eq(r.eventPacket.values[1].cycle,'<cycle>');packet.unknownPayload.directPrice=999
 Eq(h.query:DescribePriceEvidenceDetail().requests[1].eventPacket.values[1].unknownPayload.directPrice,700)
 Eq(r.searchArguments.page,1);Eq(r.searchArguments.minLevel,0);Eq(r.searchArguments.maxLevel,0)
 Eq(r.searchArguments.grade,1);Eq(r.searchArguments.exactMatch,false);Eq(r.searchArguments.keyword,'材料101')
 Eq(r.searchReturn.callOk,true);Eq(r.searchReturn.values[1],true);Eq(#h.calls,calls,'Describe stays native-read-free')
 local compact=h.query:DescribePriceEvidence().requests[1]
 Eq(compact.eventPacket,nil,'raw packet cannot consume the compact provider budget');Eq(compact.eventArgCount,5)
end)
Test('invalid count is unknown rather than a manufactured zero-listing result',function()
 for _,value in ipairs({'nil','text','negative','fraction','nan','infinity'})do
  local h=Boot();X2Auction.GetSearchedItemCount=function()
   if value=='nil'then return nil elseif value=='text'then return 'unreadable' elseif value=='negative'then return -1
   elseif value=='fraction'then return 1.5 elseif value=='nan'then return 0/0 else return math.huge end
  end
  assert(Strict(h,'bad-count',101));h:searched({})
  Eq(h.deliveries[1].status,'unavailable');Eq(h.deliveries[1].error,'auction_search_count_invalid')
  Eq(h.deliveries[1].price,nil);Eq(h:count('GetSearchedItemInfo'),0)
  local r=h.query:DescribePriceEvidenceDetail().requests[1];Eq(r.status,'failed');Eq(r.sourceCount,nil)
  assert(r.countReturn~=nil,'actual count return must survive failure')
 end
end)
Test('packet diagnostics are bounded and late callbacks cannot attach to another generation',function()
 local h=Boot();assert(Strict(h,'old-packet',101));local oldFn
 for _,fn in pairs(h.native.AUCTION_ITEM_SEARCHED)do oldFn=fn end
 h.queue:CancelRequester('old-packet');h:advance(8000);assert(Strict(h,'new-packet',102))
 oldFn(h.query.owner,{late='must_not_attach'})
 local d=h.query:DescribePriceEvidenceDetail();Eq(d.requests[2].eventPacket,nil)
 h:searched({},1,2,3,4,5,6,7,8,9,10)
 local r=h.query:DescribePriceEvidenceDetail().requests[2];Eq(r.eventPacket.argCount,10)
 Eq(r.eventPacket.omittedArguments,2);Eq(r.eventPacket.values[8],8);Eq(r.eventPacket.values[9],nil)
end)
-- 维护：这是名称筛选的明确故障模型，验证候选召回和最终价格身份是两层；不宣称已复现 RU 分词 ABI。
-- 普通搜索可以返回同名变体/相似材料，但数量/品质/ID/一口价仍必须严格匹配，且只发一包。
Test('name candidate filtering cannot replace strict item identity or suppress a qualified-name matching listing',function()
 local h=Boot();h.syncComplete=true
 local wrong=Listing(102,1);wrong.name='苹果汁'
 local grade=Listing(101,2,3);grade.name='新鲜苹果'
 -- 中文维护（发布审查）：名称召回独立验证已知身份；未知品质另案必须阻止最低价提交。
 local otherGrade=Listing(101,3,2);otherGrade.name='新鲜苹果'
 local accepted=Listing(101,70);accepted.name='新鲜苹果'
 local market={wrong,grade,accepted,otherGrade}
 h.onSearch=function(keyword,_,args)
  local rows={};for _,row in ipairs(market)do
   if args[6] and row.name==keyword or not args[6] and row.name:find(keyword,1,true)then rows[#rows+1]=row end
  end;return rows
 end
 assert(Strict(h,'qualified-name',101,{searchName='苹果'}));h:advance(1000)
 Eq(h.deliveries[1].status,'ready');Eq(h.deliveries[1].price,70)
 Eq(h:count('SearchAuctionArticle'),1);Eq(h:count('GetSearchedItemInfo'),3)
 local r=h.query:DescribePriceEvidenceDetail().requests[1]
 Eq(r.searchArguments.exactMatch,false);Eq(r.reasons.id_mismatch,1);Eq(r.reasons.grade_mismatch,1)
 Eq(r.acceptedIndex,3)
end)
Test('unknown-grade row is excluded while a known valid row remains a reference',function()
 local h=Boot();h.syncComplete=true
 local missing=Listing(101,3);missing.name='新鲜苹果';missing.itemGrade=nil
 local accepted=Listing(101,70);accepted.name='新鲜苹果'
 h.onSearch=function()return {missing,accepted}end
 assert(Strict(h,'qualified-name-unknown',101,{searchName='苹果'}));h:advance(1000)
 Eq(h.deliveries[1].status,'ready');Eq(h.deliveries[1].price,70)
 Eq(h:count('SearchAuctionArticle'),1);Eq(h:count('GetSearchedItemInfo'),2)
 Eq(h.queue:GetPriceByItemType(101,1),70)
 local r=h.query:DescribePriceEvidenceDetail().requests[1]
 Eq(r.searchArguments.exactMatch,false);Eq(r.reasons.grade_missing,1);Eq(r.acceptedIndex,2)
end)
-- 中文维护：分阶段计时只放宽有限本地排队，不能延长发包后响应、抢占已有 Native 或追加重试。
Test('Trade staged wait survives queue time then retains five-second native response limit',function()
 local h=Boot();local results={}
 assert(Strict(h,'first',101,{},function(r)results.first=r end))
 assert(Strict(h,'trade-wait',102,{waitForDispatch=true,deadlineAt=h.now+20000},function(r)results.second=r end))
 h:advance(4500);h:searched({Listing(101,100)})
 h:advance(1500);assert(results.first and results.first.status=='ready');assert(results.second==nil)
 local request=h.queue.pending;assert(request and request.itemType==102);local sent=request.dispatchedAt
 assert(sent>=5000);Eq(request.deadlineAt,sent+5000)
 h:advance(sent+5000-h.now);Eq(results.second.status,'timeout');Eq(results.second.error,'quote_deadline')
 Eq(results.second.dispatchedAt,sent);Eq(h:count('SearchAuctionArticle'),2)
end)
Test('staged queue expiry is explicit and cannot cancel another active native owner',function()
 local h=Boot();local result
 assert(Strict(h,'first',101))
 assert(Strict(h,'queued',102,{waitForDispatch=true,deadlineAt=h.now+1200},function(r)result=r end))
 h:advance(1200);Eq(result.status,'timeout');Eq(result.error,'quote_queue_wait_timeout');Eq(result.dispatchedAt,nil)
 assert(h.queue.pending and h.queue.pending.itemType==101);Eq(h:count('SearchAuctionArticle'),1)
end)
Test('default shared consumer may shorten staged deadline but cannot extend it',function()
 local h=Boot();local results={}
 assert(Strict(h,'first',101))
 assert(Strict(h,'staged',102,{waitForDispatch=true,deadlineAt=h.now+20000},function(r)results.a=r end))
 assert(Strict(h,'default',102,{deadlineAt=h.now+1200},function(r)results.b=r end))
 h:advance(1200);Eq(results.a.status,'timeout');Eq(results.b.status,'timeout');Eq(h:count('SearchAuctionArticle'),1)
end)
print(('Single-query transport: %d/%d passed'):format(passed,total));assert(passed==total,'single-query transport failures')
