-- Development only: real quote service, injected synchronous API + paced scheduler.
local pass,fail=0,0
local function Test(name,fn) local ok,e=pcall(fn);if ok then pass=pass+1;print('PASS overview quote '..name)else fail=fail+1;print('FAIL overview quote '..name..': '..tostring(e))end end
local function Boot(value)
 local c={now=0,calls={},tasks={},events=0}
 ReplicatedSuite={Services={},NowMs=function()return c.now end,Api={CallCapability=function(_,cap,host,method,id,grade)c.calls[#c.calls+1]={id=id,grade=grade,at=c.now};c.now=c.now+17;return true,value end},
  Events={Publish=function()c.events=c.events+1 end},Scheduler={AddTask=function(_,name,ms,fn)c.tasks[name]=fn;return true end,RemoveTask=function(_,name)c.tasks[name]=nil;return true end}}
 dofile('services/rs_price_quote_queue_v3.lua');local Q=ReplicatedSuite.Services.PriceQuoteQueueV3
 local function tick(ms)c.now=c.now+(ms or 1000);local fn=c.tasks[Q.taskName];if fn then fn()end end
 return Q,c,tick
end
Test('normal query never spends calls on control-item probes or implicit grade ladder',function()
 local Q,c,tick=Boot(nil);assert(Q:RequestQuote('trade',55,2));for i=1,15 do tick()end
 assert(#c.calls==1 and c.calls[1].id==55 and c.calls[1].grade==2,'ordinary click expanded into unrelated queries')
 assert(not Q.running and not c.tasks[Q.taskName],'empty queue left running')
end)
Test('shared material executes once and delivers to both requesters',function()
 local Q,c,tick=Boot(100);local a,b=0,0
 Q:RequestQuote('trade',55,2,function()a=a+1 end);Q:RequestQuote('craft',55,2,function()b=b+1 end)
 for i=1,6 do tick()end;assert(#c.calls==1 and a==1 and b==1,'no shared in-flight dedup')
end)
Test('cancel removes only requester and preserves shared quote',function()
 local Q,c,tick=Boot(100);local a,b=0,0
 Q:RequestQuote('trade',55,2,function()a=a+1 end);Q:RequestQuote('craft',55,2,function()b=b+1 end)
 assert(Q:CancelRequester('trade'));for i=1,4 do tick()end;assert(a==0 and b==1 and #c.calls==1)
end)
Test('cancel final requester removes queued calls and stops lane',function()
 local Q,c,tick=Boot(100);Q:RequestQuote('trade',55,2);assert(Q:CancelRequester('trade'));for i=1,5 do tick()end
 assert(#c.calls==0 and not Q.running)
end)
Test('fresh cache reuses quote with no second native read',function()
 local Q,c,tick=Boot(120);Q:RequestQuote('a',55,2);tick();local got
 assert(Q:RequestQuote('b',55,2,function(s)got=s end));for i=1,4 do tick()end
 assert(#c.calls==1 and got and got.price==120 and got.cached==true)
end)
Test('negative cache stops repeated no-listing clicks',function()
 local Q,c,tick=Boot(nil);Q:RequestQuote('a',55,2);tick();local got
 Q:RequestQuote('b',55,2,function(s)got=s end);for i=1,4 do tick()end;assert(#c.calls==1 and got and got.status~='ready')
end)
Test('pacing is monotonic and at least one second including duration evidence',function()
 local Q,c,tick=Boot(120);Q:RequestQuote('a',55,2);Q:RequestQuote('a',56,2)
 tick(0);tick(100);assert(#c.calls==1);tick(1000);assert(#c.calls==2 and c.calls[2].at-c.calls[1].at>=1000)
 assert(Q:Describe().stats.nativeMaxMs==17)
end)
Test('caller explicitly expands grades without control probe',function()
 local Q,c,tick=Boot(nil);Q:RequestQuote('advanced',55,2,nil,{2,3,0});for i=1,10 do tick()end
 assert(#c.calls==3 and c.calls[3].grade==0)
end)
Test('freshness expires without mislabelling old session price as live',function()
 local Q,c,tick=Boot(120);Q:RequestQuote('a',55,2);tick();c.now=c.now+121000
 local p,source=Q:GetPriceWithProvenance(55,2);assert(p==120 and source=='reference','expired price called live')
end)
Test('different grades never reuse each others quote',function()
 local Q,c,tick=Boot(120);Q:RequestQuote('a',55,2);tick();local p=Q:GetPriceWithProvenance(55,3);assert(p==nil)
end)
local function TradeBoot()
 local H=dofile('tools/rs_udf_numeric_test_host.lua');local S,P=H.Boot();local T=S.Features.Trade
 assert(P:LoadStore(T.storeId));T.storeLoaded=true;T.enabled=true;T.consumerCount=1
 local c={clock=0,calls=0,tasks={}};S.NowMs=function()return c.clock end
 S.Events={Publish=function()end,UnsubscribeOwner=function()end}
 S.Scheduler={AddTask=function(_,k,ms,fn)c.tasks[k]=fn;return true end,RemoveTask=function(_,k)c.tasks[k]=nil;return true end,
  AddOneShot=function(_,k,ms,fn)c.tasks[k]=function()c.tasks[k]=nil;fn()end;return true end}
 S.Api.CallCapability=function()c.calls=c.calls+1;return true,nil end
 S.Data=S.Data or {};S.Data.TradeMaterialAuctionMeta={};local materials={}
 for i=1,10 do local k='mat'..i;S.Data.TradeMaterialAuctionMeta[k]={itemType=900+i,itemGrade=2};materials[i]={materialKey=k,costStatus='explicit_quote_required'}end
 T.Authority.rows={{key='r',materialRows=materials}}
 T.Authority.RefreshQuotedMaterial=function()c.refreshes=(c.refreshes or 0)+1;return true end
 dofile('services/rs_price_quote_queue_v3.lua');local Q=S.Services.PriceQuoteQueueV3
 local function tick()c.clock=c.clock+1000;local copy={};for k,fn in pairs(c.tasks)do copy[#copy+1]=fn end;for _,fn in ipairs(copy)do fn()end end
 return T,Q,c,tick
end
Test('trade batch at most four and repeated click cannot multiply queue',function()
 local T,Q,c,tick=TradeBoot();assert(T:QuotePendingMaterials());assert(#Q.queue==4,'batch expanded beyond four')
 assert(T:QuotePendingMaterials());assert(#Q.queue==4);for i=1,12 do tick()end
 assert(c.calls==4 and not T:GetQuoteBatch().active)
end)
Test('trade cancellation invalidates batch and stops future native calls',function()
 local T,Q,c,tick=TradeBoot();T:QuotePendingMaterials();assert(T:CancelQuoteBatch('user'))
 for i=1,6 do tick()end;assert(c.calls==0 and not T:GetQuoteBatch().active)
end)
Test('trade Disable cancels pending quotes as well as route task',function()
 local T,Q,c,tick=TradeBoot();T:QuotePendingMaterials();assert(T:Disable('test'));for i=1,6 do tick()end;assert(c.calls==0)
end)
Test('scheduler rejection cannot leave a successful immortal queued request',function()
 local Q,c=Boot(120);ReplicatedSuite.Scheduler.AddTask=function()return false end
 local ok=Q:RequestQuote('a',55,2);assert(ok==false and #Q.queue==0 and not Q.running)
end)
Test('negative cache expires and allows exactly one explicit retry',function()
 local Q,c,tick=Boot(nil);Q:RequestQuote('a',55,2);tick();c.now=c.now+31000
 Q:RequestQuote('a',55,2);tick();assert(#c.calls==2)
end)
Test('cancelled un-tokened name search is drained without late callback',function()
 local Q,c,tick=Boot(nil);local returned=0
 ReplicatedSuite.Services.AuctionQueryV3={Search=function()return true end,GetSnapshot=function()return {status='waiting'}end}
 Q:RequestQuote('a',55,2,function()returned=returned+1 end,{2},{searchName='test'})
 tick();assert(Q.pending and Q.pending.fallbackState=='searching');Q:CancelRequester('a')
 for i=1,18 do tick()end;assert(returned==0 and not Q.running and #c.calls==1)
end)
Test('two completion keys coalesce without dropping second material',function()
 local T,Q,c,tick=TradeBoot();local keys,refreshes
 T.Authority.RefreshQuotedMaterial=function(_,k)keys=k;refreshes=(refreshes or 0)+1;return true end
 T:_QueueQuoteRefresh('mat1',T.quoteGeneration);T:_QueueQuoteRefresh('mat2',T.quoteGeneration)
 tick();assert(refreshes==1 and keys.mat1 and keys.mat2)
end)
Test('old reference prices refresh via basic query not expanded search',function()
 local T,Q,c,tick=TradeBoot();for _,m in ipairs(T.Authority.rows[1].materialRows)do m.costStatus='quoted_reference' end
 assert(T:QuotePendingMaterials());for i=1,10 do tick()end;assert(c.calls==4)
end)
Test('standalone legacy material command cannot query disabled trade',function()
 local T,Q,c,tick=TradeBoot();T.enabled=false;assert(T:QuoteMaterial('mat1')==false);assert(#Q.queue==0)
end)
print('OVERVIEW QUOTE RESULT '..pass..' passed / '..fail..' failed');if fail>0 then error('overview quote failures')end
