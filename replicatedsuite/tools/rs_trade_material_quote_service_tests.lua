-- 2026-10-01: production services with Native/clock/persistence boundaries only.
local Boot=dofile('tools/rs_trade_requote_test_host.lua')
local function Eq(a,b,m) assert(a==b,(m or 'value')..': '..tostring(a)..' ~= '..tostring(b)) end
local function Fixture()
 local h=Boot(); h:loadMaterialPrices()
 dofile('services/rs_trade_material_quote_service_v3.lua')
 h.service=h.S.Services.TradeMaterialQuoteServiceV3
 h.syncComplete=true
 h.onSearch=function(keyword) local p=h.queue.pending; return {{itemType=p.itemType,itemGrade=p.itemGrade,itemStack=10,directPrice=1000,name=keyword}} end
 return h
end
local function Material(id) return {itemType=id,itemGrade=1,name='material'..id,materialKey='item:'..id,count=2} end
local passed,total=0,0
local function Test(name,fn) total=total+1;local ok,err=xpcall(fn,debug.traceback);if ok then passed=passed+1;print('PASS '..name) else print('FAIL '..name..': '..err) end end
Test('four unique materials use at most four sequential native queries and finish within five seconds',function()
 local h=Fixture();local result
 assert(h.service:RequestRecipe('row1',{Material(101),Material(102),Material(103),Material(104)},function(r)result=r end,{owner='life_trade'}))
 h:advance(5000);assert(result and not result.active);Eq(result.known,4);Eq(result.unknown,0);Eq(h:count('SearchAuctionArticle'),4);Eq(h:count('AskMarketPrice'),0);Eq(h:count('GetLowestPrice'),0)
 local last=-10000;for _,c in ipairs(h.calls)do if c.method=='SearchAuctionArticle' then assert(c.at-last>=500);last=c.at end end
end)
Test('duplicate ingredients and simultaneous recipes share each native identity once',function()
 local h=Fixture();local a,b
 assert(h.service:RequestRecipe('a',{Material(101),Material(101),Material(102)},function(r)a=r end,{owner='life_trade'}))
 assert(h.service:RequestRecipe('b',{Material(101),Material(102)},function(r)b=r end,{owner='life_trade'}))
 h:advance(5000);Eq(a.total,2);Eq(b.total,2);Eq(a.known,2);Eq(b.known,2);Eq(h:count('SearchAuctionArticle'),2)
end)
Test('seven-material recipe keeps querying past the former whole-recipe deadline',function()
 local h=Fixture();local materials={};for i=1,7 do materials[i]=Material(100+i)end;local result
 assert(h.service:RequestRecipe('large',materials,function(r)result=r end));h:advance(5000)
 Eq(result.total,7);assert(result.active and result.unknown==0,'unsent material must remain queued at five seconds')
 h:advance(10000);Eq(result.known,7);Eq(result.unknown,0);assert(not result.active);Eq(h:count('SearchAuctionArticle'),7)
end)
Test('cache age boundaries use fresh immediately and warm or stale SWR',function()
 local h=Fixture();local m=h.materialPrices
 for i=1,5 do assert(m:ObserveConfirmedPrice(100+i,1,100,'market_price:1'))end
 local ages={359,360,1440,10079,10080}
 for i,age in ipairs(ages)do m.entries[(100+i)..':1'].observedMinute=m.entries[(100+i)..':1'].observedMinute-age end
 h.syncComplete=false
 local result;assert(h.service:RequestRecipe('cache',{Material(101),Material(102),Material(103),Material(104),Material(105)},function(r)result=r end,{owner='life_trade'}))
 Eq(result.known,4);Eq(result.results['101:1'].freshness,'fresh');Eq(result.results['102:1'].freshness,'warm');Eq(result.results['103:1'].freshness,'stale');Eq(result.results['104:1'].freshness,'stale');assert(result.results['105:1']==nil)
 h:searched();h:advance(5000);assert(not result.active);Eq(result.known,5)
end)
Test('no result and repeated clicks terminate unknown without retry amplification',function()
 local h=Fixture();h.onSearch=function()return {}end;local r
 assert(h.service:RequestRecipe('empty',{Material(101)},function(x)r=x end));h:advance(5000)
 Eq(r.unknown,1);Eq(r.known,0);assert(not r.complete);Eq(h:count('SearchAuctionArticle'),1)
 for i=1,10 do assert(h.service:RequestRecipe('empty'..i,{Material(101)},function(x)r=x end))end
 h:advance(5000);Eq(h:count('SearchAuctionArticle'),1)
end)
Test('timeout and cancel detach consumers with bounded native cleanup',function()
 local h=Fixture();h.syncComplete=false;local r
 assert(h.service:RequestRecipe('timeout',{Material(101),Material(102)},function(x)r=x end,{owner='life_trade'}));h:advance(5000)
 assert(not r.active);Eq(r.unknown,2);Eq(h:count('SearchAuctionArticle'),1)
 h:advance(20000);assert(h.queue.pending==nil and h.query.pending==nil);assert(h.tasks[h.queue.taskName]==nil)
 local x=Fixture();x.syncComplete=false;local n=0;assert(x.service:RequestRecipe('cancel',{Material(101)},function()n=n+1 end,{owner='life_trade'}));assert(x.service:CancelOwner('life_trade'));local before=n;x:advance(20000);Eq(n,before);Eq(x:count('SearchAuctionArticle'),1)
end)
Test('native human open or visibility unknown returns blocked without server calls',function()
 for _,unknown in ipairs({false,true})do
  -- 中文维护注释（2026-10-02）：保持真正不可读与用户开窗两类保护；成功空内容的关闭窗应允许查询。
  local h=Fixture();if unknown then h.content=nil;ADDON.GetContentMainScriptPosVis=function()return nil end
   ADDON.GetContent=function()error('native_content_unreadable')end else h:open(false)end
  local r;assert(h.service:RequestRecipe('blocked',{Material(101)},function(x)r=x end));h:advance(5000)
  assert(not r.active);Eq(r.unknown,1);Eq(r.results['101:1'].status,'blocked');Eq(h:count('SearchAuctionArticle'),0);Eq(h:count('AskMarketPrice'),0)
 end
end)
Test('completion callback cancellation cannot resurrect warm SWR work',function()
 local h=Fixture();local m=h.materialPrices;assert(m:ObserveConfirmedPrice(101,1,100,'market_price:1'))
 m.entries['101:1'].observedMinute=m.entries['101:1'].observedMinute-400
 assert(h.service:RequestRecipe('reentrant',{Material(101)},function()h.service:CancelOwner('life_trade')end,{owner='life_trade'}))
 h:advance(20000);Eq(h:count('SearchAuctionArticle'),0);assert(next(m.refreshPending)==nil)
end)
Test('new operation recovers immediately after native auction closes',function()
 local h=Fixture();h:open(false);local r
 assert(h.service:RequestRecipe('open',{Material(101)},function(x)r=x end));Eq(r.results['101:1'].status,'blocked')
 h.visible=false
 assert(h.service:RequestRecipe('closed',{Material(101)},function(x)r=x end));h:advance(5000)
 Eq(r.known,1);Eq(h:count('SearchAuctionArticle'),1)
end)
Test('invalid material identities stay unknown without native calls',function()
 local h=Fixture();local r
 assert(h.service:RequestRecipe('bad',{{itemType=math.huge,itemGrade=1,name='bad'},{itemType=102,itemGrade=1.5,name='bad'}},function(x)r=x end))
 h:advance(5000);Eq(r.total,2);Eq(r.unknown,2);Eq(h:count('SearchAuctionArticle'),0)
end)
Test('immediate blocked return never reports a ready operation',function()
 local h=Fixture();h:open(false);local result
 local ok,status=h.service:RequestRecipe('return',{Material(101)},function(x)result=x end)
 assert(ok);assert(status~='ready');assert(not result.complete)
end)
-- 212459 实机报告：普通材料 raw itemGrade=0；缺失品质不能被捏造成 1 发包。
Test('missing grade remains unknown without native search',function()
 local h=Fixture();local r
 assert(h.service:RequestRecipe('grade_missing',{{itemType=773,name='苹果'}},function(x)r=x end))
 h:advance(5000);Eq(r.unknown,1);Eq(h:count('SearchAuctionArticle'),0)
end)
Test('captured common and rare native grades keep separate verified price keys',function()
 local h=Fixture();local r
 h.onSearch=function(keyword)
  if h.queue.pending.itemType==773 then return {{itemType=773,itemGrade=0,stackCount=1469,directPriceStr='4546555',bidPriceStr='3095',name=keyword}} end
  return {{itemType=3680,itemGrade=3,stackCount=4135,directPriceStr='7389245',bidPriceStr='1787',name=keyword}}
 end
 assert(h.service:RequestRecipe('captured_grades',{{itemType=773,itemGrade=0,name='苹果'},{itemType=3680,itemGrade=3,name='长脑参'}},function(x)r=x end))
 h:advance(5000);Eq(r.known,2);Eq(h.materialPrices:GetTradePrice(773,0),3095);Eq(h.materialPrices:GetTradePrice(3680,3),1787)
 assert(h.materialPrices.entries['773:1']==nil and h.materialPrices.entries['3680:1']==nil)
end)
-- 中文维护：215703 实机每次响应约 250~450ms，多货物共享一秒串行 lane；即时回包旧 fixture 隐藏了排队超时。
Test('eight rapid recipes finish queued materials with delayed native responses',function()
 local h=Fixture();h.syncComplete=false;local seq=0;local results={}
 h.onSearch=function(keyword)
  seq=seq+1;local p=h.queue.pending
  local rows={{itemType=p.itemType,itemGrade=1,stackCount=10,directPriceStr='1000',name=keyword}}
  h.S.Scheduler:AddOneShot('captured_latency:'..seq,350,function()h:searched(rows)end,h.service,'P2',1)
  return rows
 end
 for i=1,8 do
  local index=i
  assert(h.service:RequestRecipe('rapid:'..i,{Material(101),Material(200+i*3),Material(201+i*3),Material(202+i*3)},function(r)results[index]=r end))
  h:advance(750)
 end
 h:advance(60000)
 for i=1,8 do assert(results[i] and not results[i].active);Eq(results[i].known,4,'recipe '..i);Eq(results[i].unknown,0)end
 Eq(h:count('SearchAuctionArticle'),25);assert(next(h.service.failures)==nil)
end)
Test('native timeout is not a thirty-second material failure and explicit retry can recover',function()
 local h=Fixture();h.syncComplete=false;local first,second
 assert(h.service:RequestRecipe('first',{Material(101)},function(r)first=r end));h:advance(5000)
 Eq(first.unknown,1);assert(h.service.failures['101:1']==nil)
 h:advance(4000);h.syncComplete=true
 assert(h.service:RequestRecipe('second',{Material(101)},function(r)second=r end));h:advance(5000)
 Eq(second.known,1);Eq(h:count('SearchAuctionArticle'),2)
end)
Test('stage guard registration failure cannot send an unbounded query',function()
 local h=Fixture();local r;local original=h.S.Scheduler.AddOneShot
 h.S.Scheduler.AddOneShot=function(self,id,...)
  if id:find('v3_trade_material_deadline:',1,true)then return false end
  return original(self,id,...)
 end
 assert(h.service:RequestRecipe('no_guard',{Material(101)},function(x)r=x end))
 assert(not r.active);Eq(r.unknown,1);Eq(h:count('SearchAuctionArticle'),0)
end)
-- 中文维护：221122 实机由玩家开拍卖中断后三个材料。关闭后的显式重查应只补缺价，不能丢已确认价格。
Test('opening native auction stops remaining materials and close retry queries only missing identities',function()
 local h=Fixture();h.syncComplete=false;local seq=0;local first,second
 h.onSearch=function(keyword)
  seq=seq+1;local p=h.queue.pending
  local rows={{itemType=p.itemType,itemGrade=1,stackCount=10,directPriceStr='1000',name=keyword}}
  h.S.Scheduler:AddOneShot('visible_latency:'..seq,350,function()h:searched(rows)end,h.service,'P2',1)
  return rows
 end
 local materials={Material(101),Material(102),Material(103),Material(104)}
 assert(h.service:RequestRecipe('visibility_retry',materials,function(r)first=r end));h:advance(1800)
 h:open(false);h:advance(1500);assert(not first.active);Eq(first.known,2);Eq(first.unknown,2)
 Eq(h:count('SearchAuctionArticle'),2);assert(next(h.service.failures)==nil)
 h.visible=false
 assert(h.service:RequestRecipe('visibility_retry',materials,function(r)second=r end));h:advance(5000)
 assert(not second.active);Eq(second.known,4);Eq(second.unknown,0);Eq(h:count('SearchAuctionArticle'),4)
end)
print('TRADE_SINGLE_RECIPE '..passed..'/'..total);assert(passed==total,'single recipe service failures')
