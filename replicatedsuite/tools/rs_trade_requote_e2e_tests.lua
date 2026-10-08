-- Cache-first Trade integration. Recipe quantities and payout arithmetic are unchanged;
-- legacy force/anomaly verification remains covered in rs_trade_requote_pipeline_tests.lua.
dofile('tools/rs_trade_tests.lua')
local baseS=ReplicatedSuite
local Boot=dofile('tools/rs_trade_requote_test_host.lua')
local passed,total=0,0
local function Eq(a,b,m) assert(a==b,(m or 'value')..': expected='..tostring(b)..' actual='..tostring(a)) end
local function Test(name,fn) total=total+1;local ok,err=xpcall(fn,debug.traceback)
 if ok then passed=passed+1;print('PASS '..name)else print('FAIL '..name..': '..tostring(err))end end
local function Fixture(mode,blocked)
 local h=Boot(baseS);local S=h.S;local T=S.Features.Trade;local TA=T.Authority
 local m=h:loadMaterialPrices()
 if mode~='missing' then
  local old = mode=='old_fresh' or mode=='sort_dependent'
  local source = mode=='sort_dependent' and 'name_search_direct_unit' or 'market_price:1'
  assert(m:ObserveConfirmedPrice(30901,0,old and 1500 or 594,source))
  assert(m:ObserveConfirmedPrice(14627,3,old and 8950 or 8800,source))
  if mode=='warm' or mode=='stale' then
   for _,entry in pairs(m.entries)do entry.observedMinute=entry.observedMinute-(mode=='warm' and 420 or 2880)end
  end
 end
 T.PriceQuoteSubscribed=false;T.PriceQuoteActivityTopic=nil
 T.enabled=true;T.consumerCount=1;T.Preferences.viewMode='all'
 T.State.fromZone,T.State.toZone=2,5;T.State.commerceMode,T.State.ratioMode='observe','current'
 T.quoteJobsByRowKey={};T.quoteJobOrder={};T.lastQuoteJob=nil;T.quoteEpoch=(T.quoteEpoch or 0)+1
 TA.commerceSkill,TA.commerceStatus=50000,'ready';TA.selectedKey=nil;TA.rows={}
 TA.rawRows={{key='2:5:31855',name='[玛瑞诺普]新鲜特产',sourceName='[玛瑞诺普]新鲜特产',currentRatio=108,ratio=108,originZone=2,destinationZone=5,itemType=31855,ratioUpdatedAt=h.now}}
 h.syncComplete=true
 h.onSearch=function(keyword)
  local pending=h.queue.pending;local id=pending and pending.itemType
  local unit=id==30901 and 594 or 8800
  return {{itemType=id,itemGrade=id==30901 and 0 or 3,itemStack=100,directPrice=unit*100,name=keyword}}
 end
 -- 中文维护注释（2026-10-02）：阻断场景模拟真正不可读的 Native，而非成功返回 nil 的正常关闭窗。
 if blocked then h.content=nil;ADDON.GetContentMainScriptPosVis=function()return nil,nil,nil,nil end
  ADDON.GetContent=function()error('native_content_unreadable')end end
 assert(TA:RebuildDisplayRows('requote_fixture'));assert(#TA.rows==1)
 local row=TA.rows[1];row.priceCopper=253900 -- observed screenshot sale input; production payout formula is unchanged
 assert(T:EnsurePriceQuoteSubscription())
 h.T,h.TA,h.row,h.m=T,TA,row,m
 return h
end
local function Unknown(h)
 h.content=nil;ADDON.GetContentMainScriptPosVis=function()return nil,nil,nil,nil end
 -- 中文维护注释：保留 unknown 的价格/终态回归，关闭全空形态在 transport 用例单独验证。
 ADDON.GetContent=function()error('native_content_unreadable')end
end
Test('missing recipe prices yield 12g45s20c cost and 12g93s80c margin within five seconds',function()
 local h=Fixture('missing');local start=h.now;assert(h.T:QuoteRowMaterials(h.row.key));h:advance(5000)
 Eq(h.row.materialRows[1].itemType,30901);Eq(h.row.materialRows[1].count,180)
 Eq(h.row.materialRows[2].itemType,14627);Eq(h.row.materialRows[2].count,2)
 Eq(h.row.materialCostCopper,124520);Eq(h.row.profitCopper,129380)
 Eq(h.row.quoteJobActive,false);Eq(h.row.quoteJobState,'ready')
 Eq(h:count('SearchAuctionArticle'),2,'one request per missing identity')
 assert(h.T:GetQuoteJob(h.row.key).completedAt-start<=5000)
end)
Test('descending native listings repair old sort-dependent cache through the actual Trade cost projection',function()
 local h=Fixture('sort_dependent')
 Eq(h.row.materialCostComplete,false);Eq(h.row.materialCostCopper,nil)
 assert(h.row.materialRows[1].detailText:find('旧缓存未核验挂单排序',1,true))
 h.onSearch=function()
  local id=h.queue.pending.itemType;local grade=id==30901 and 0 or 3;local unit=id==30901 and 594 or 8800
  return {{itemType=id,itemGrade=grade,itemStack=10,directPrice=unit*3*10},
   {itemType=id,itemGrade=grade,itemStack=100,directPrice=unit*100}}
 end
 assert(h.T:QuoteRowMaterials(h.row.key));h:advance(5000)
 Eq(h.row.materialCostComplete,true);Eq(h.row.materialCostCopper,124520);Eq(h.row.profitCopper,129380)
 Eq(h:count('SearchAuctionArticle'),2);Eq(h:count('GetSearchedItemInfo'),4)
 Eq(h.row.quoteJobState,'ready');Eq(h.m.entries['30901:0'].source,'name_search_min_direct_unit')
end)
-- 中文维护注释（2026-10-02）：整条跑商消费者链必须在真实报告的“两个 getter 成功全空”条件下
-- 得到两份可靠报价并更新成本/利润，不能只证明底层 known=false 被改成 known=true。
Test('cold absent auction still completes real Trade row materials and economics',function()
 local h=Fixture('missing');h.content=nil;ADDON.GetContentMainScriptPosVis=function()return nil,nil,nil,nil,nil end
 assert(h.T:QuoteRowMaterials(h.row.key));h:advance(5000)
 Eq(h:count('SearchAuctionArticle'),2);Eq(h:count('AskMarketPrice'),0);Eq(h.textWrites,0)
 Eq(h.row.materialCostCopper,124520);Eq(h.row.profitCopper,129380)
 Eq(h.row.quoteJobActive,false);Eq(h.row.quoteJobState,'ready');Eq(h.row.materialCostComplete,true)
 local d=h.query:Describe();Eq(d.visibility.known,true);Eq(d.visibility.visible,false);Eq(d.visibility.source,'content-absent')
end)
Test('fresh cached row completes immediately without revalidating or changing accepted arithmetic',function()
 local h=Fixture('old_fresh');assert(h.T:QuoteRowMaterials(h.row.key))
 Eq(h.row.materialCostCopper,287900);Eq(h.row.profitCopper,-34000)
 Eq(h.row.quoteJobActive,false);Eq(h.row.profitStatus,'ready')
 h:advance(15000);Eq(#h.calls,0,'fresh prices cannot issue native calls')
end)
Test('second double click after completion reuses fresh prices with no extra native query',function()
 local h=Fixture('missing');assert(h.T:QuoteRowMaterials(h.row.key));h:advance(5000)
 local before=h:count('SearchAuctionArticle');assert(h.T:QuoteRowMaterials(h.row.key));h:advance(15000)
 Eq(before,2);Eq(h:count('SearchAuctionArticle'),before);Eq(h.row.profitCopper,129380)
end)
Test('double clicking an active missing row does not duplicate native work',function()
 local h=Fixture('missing');assert(h.T:QuoteRowMaterials(h.row.key));local job=h.T.quoteJobsByRowKey[h.row.key]
 Eq(job.active,true)
 for _=1,5 do assert(h.T:QuoteRowMaterials(h.row.key));Eq(h.T.quoteJobsByRowKey[h.row.key],job)end
 h:advance(5000);Eq(h:count('SearchAuctionArticle'),2);Eq(job.active,false)
end)
Test('blocked stale background refresh retains numeric cost and foreground ready result',function()
 local h=Fixture('stale',true)
 assert(h.T:QuoteRowMaterials(h.row.key));Eq(h.row.quoteJobActive,false);Eq(h.row.profitStatus,'ready')
 h:advance(90000)
 Eq(h.row.materialCostCopper,124520);Eq(h.row.profitCopper,129380);Eq(h.row.quoteJobState,'ready')
 Eq(h:count('SearchAuctionArticle'),0);Eq(h:count('AskMarketPrice'),0)
 Eq(h.m:Describe().refreshPending,0)
end)
Test('shared material event recomputes both quoted row and another row using it',function()
 local h=Fixture('missing');local other={};for k,v in pairs(h.row)do other[k]=v end
 other.key='other';other.priceCopper=300000;h.TA.rows[2]=other
 assert(h.T:QuoteRowMaterials(h.row.key));h:advance(5000)
 Eq(other.materialCostCopper,124520);Eq(other.profitCopper,175480)
end)
Test('fast native rate publication retains active missing job without reading material prices',function()
 local h=Fixture('missing');assert(h.T:QuoteRowMaterials(h.row.key))
 local original=h.m.GetTradePrice;h.m.GetTradePrice=function()error('fast publish read material service')end
 local ok,err=pcall(h.TA.RebuildDisplayRows,h.TA,'ratio_result',{includeMaterials=false})
 h.m.GetTradePrice=original;assert(ok,err)
 local row=h.TA.rows[1];Eq(row.quoteJobActive,true);Eq(row.profitCopper,nil)
 assert(row.profitNote and row.profitNote:find('缺失材料',1,true))
end)
Test('fast native rate publication cannot erase a blocked missing-price terminal',function()
 local h=Fixture('missing');Unknown(h);assert(h.T:QuoteRowMaterials(h.row.key));h:advance(5000)
 assert(h.TA:RebuildDisplayRows('ratio_result',{includeMaterials=false}))
 Eq(h.TA.rows[1].quoteJobActive,false);Eq(h.TA.rows[1].profitStatus,'revalidate_blocked')
 assert(h.TA.rows[1].profitNote:find('拍卖',1,true));Eq(h.TA.rows[1].profitCopper,nil)
end)
Test('priced detail button remains enabled and finishes from fresh cache',function()
 local h=Fixture();local d=h.S.UIV3.TradeDetailFloatingV3;d.rowKey=h.row.key
 assert(d:Refresh('requote_test'));Eq(d.quoteButton.enabled,true,'cached prices cannot disable explicit action')
 assert(d.quoteButton.onClick());Eq(h.row.quoteJobActive,false);Eq(h.row.materialCostCopper,124520)
 h:advance(15000);Eq(#h.calls,0)
end)
Test('detail status shows missing-price blocked reason and allows retry',function()
 local h=Fixture('missing');Unknown(h);assert(h.T:QuoteRowMaterials(h.row.key));h:advance(5000)
 local d=h.S.UIV3.TradeDetailFloatingV3;d.rowKey=h.row.key;assert(d:Refresh('requote_blocked'))
 local text=d.hint.props and d.hint.props.text or d.hint.text
 assert(tostring(text):find('无法确认原生拍卖窗口已关闭',1,true),'actual blocked cause must be visible: '..tostring(text))
 Eq(d.quoteButton.enabled,true,'terminal blocked allows explicit retry')
end)
Test('floating footer shows terminal missing-price blocked cause after active queue ends',function()
 local h=Fixture('missing');Unknown(h);assert(h.T:QuoteRowMaterials(h.row.key));h:advance(5000)
 local projection=h.T:GetProjection();local spec=h.S.UIV3.LifeEconomyContent.specs.Trade
 local message=spec.status(projection,h.TA.rows)
 assert(message:find('拍卖',1,true),'must not display generic refresh advice: '..tostring(message))
 assert(projection.quoteBatch.lastJobReason and projection.quoteBatch.lastJobReason:find('拍卖',1,true))
end)
Test('negative actual margin is retained without clamping',function()
 local h=Fixture('missing');h.row.priceCopper=100000;assert(h.T:QuoteRowMaterials(h.row.key));h:advance(5000)
 Eq(h.row.materialCostCopper,124520);Eq(h.row.profitCopper,-24520);Eq(h.row.profitStatus,'ready')
end)
Test('floating two-click action reruns row calculation but fresh prices cause no native work',function()
 local h=Fixture('missing');assert(h.T:QuoteRowMaterials(h.row.key));h:advance(5000)
 local before=h:count('SearchAuctionArticle');local oldJob=h.T.quoteJobsByRowKey[h.row.key]
 local spec=h.S.UIV3.LifeEconomyContent.specs.Trade;local instance={Refresh=function()return true end}
 assert(spec.onItemActivated(instance,h.row,h.T));Eq(h.T.quoteJobsByRowKey[h.row.key],oldJob)
 h.now=h.now+100;assert(spec.onItemActivated(instance,h.row,h.T))
 assert(h.T.quoteJobsByRowKey[h.row.key]~=oldJob);Eq(h.row.quoteJobActive,false)
 h:advance(15000);Eq(h:count('SearchAuctionArticle'),before)
end)
Test('unrelated consumer cached event cannot falsely finish active Trade operation',function()
 local h=Fixture('missing');h.syncComplete=false;h.queue.cache['30901:1']={price=1500,at=h.now}
 assert(h.T:QuoteRowMaterials(h.row.key));local job=h.T.quoteJobsByRowKey[h.row.key]
 assert(h:quote('other-view',30901,'香料',{searchName='香料'}))
 Eq(job.completed,0,'cached ready event prematurely completed authoritative RowJob')
 h.syncComplete=true;h:searched();h:advance(5000);Eq(job.ready,2);Eq(h.row.profitCopper,129380)
end)
Test('warm cache yields immediate margin while background single queries refresh it',function()
 local h=Fixture('warm');local before=h:count('SearchAuctionArticle');assert(h.T:QuoteRowMaterials(h.row.key))
 Eq(h.row.quoteJobActive,false);Eq(h.row.materialCostCopper,124520);Eq(h:count('SearchAuctionArticle'),before,'foreground cannot duplicate SWR work')
 h:advance(15000);Eq(h:count('SearchAuctionArticle'),2);Eq(h.row.profitCopper,129380)
 Eq(h.m:GetTradePrice(30901,0),594);Eq(h.m:GetTradePrice(14627,3),8800)
end)
Test('ratio change recalculates margin from complete cached costs without extra native work',function()
 local h=Fixture();assert(h.TA:RebuildDisplayRows('cached_ratio_before'))
 h.row=h.TA.rows[1];assert(h.T:QuoteRowMaterials(h.row.key))
 local beforePrice=h.row.priceCopper;Eq(h.row.materialCostCopper,124520)
 local beforeCalls=#h.calls
 h.TA.rawRows[1].currentRatio=130;h.TA.rawRows[1].ratio=130
 h.TA:MarkEconomicsPayoutInput('ratio_result')
 assert(h.TA:RebuildDisplayRows('ratio_result',{includeMaterials=false}))
 local row=h.TA.rows[1];assert(row.priceCopper>beforePrice)
 Eq(row.currentRatio,130);Eq(row.materialCostCopper,124520)
 Eq(row.profitCopper,row.priceCopper-124520);Eq(row.quoteJobActive,false);Eq(row.profitStatus,'ready')
 h:advance(15000);Eq(#h.calls,beforeCalls,'rate-only change must not query materials')
end)
Test('duplicate live recipe ingredient counts both quantities but queries its identity once',function()
 local h=Fixture('missing');local identity=h.S.Services.TradeMaterialIdentityV3
 local id=654321;local previous=identity.liveCache[id]
 identity.liveCache[id]={status='ready',at=h.now,craftType=654322,rows={
  {itemType=30901,itemGrade=1,materialKey='Ground Spices',count=2},
  {itemType=30901,itemGrade=1,materialKey='Ground Spices',count=3}}}
 h.TA.rawRows[1].itemType=id;h.TA.rawRows[1].name='重复材料测试配方';h.TA.rawRows[1].sourceName='重复材料测试配方'
 local ok,err=pcall(function()
  assert(h.TA:RebuildDisplayRows('duplicate_live_recipe'));h.row=h.TA.rows[1];h.row.priceCopper=10000
  Eq(#h.row.materialRows,2);Eq(h.row.materialRows[1].count,2);Eq(h.row.materialRows[2].count,3)
  assert(h.T:QuoteRowMaterials(h.row.key));h:advance(5000)
  Eq(h:count('SearchAuctionArticle'),1);Eq(h.T:GetQuoteJob(h.row.key).total,1)
  Eq(h.row.materialCostCopper,(2+3)*594);Eq(h.row.profitCopper,10000-(2+3)*594)
  Eq(h.row.quoteJobActive,false);Eq(h.row.quoteJobState,'ready')
 end)
 identity.liveCache[id]=previous;assert(ok,err)
end)
Test('module TXT preserves selected missing-grade evidence without native calls or budget truncation',function()
 local h=Fixture('missing');h.TA.selectedKey=h.row.key
 h.onSearch=function(keyword)
  return {{itemType=h.queue.pending.itemType,itemStack=100,directPrice=59400,name=keyword,sellerName='PRIVATE_SELLER'}}
 end
 assert(h.T:QuoteRowMaterials(h.row.key));h:advance(5000)
 Eq(h.row.materialCostComplete,false);assert(h.row.profitStatus~='ready')
 -- 中文维护（发布审查）：未知品级不能提交成本/利润；每种材料只读本次单包并保留诊断，
 -- 不能因为失败原因从“无匹配”变成“字段不可读”而削弱业务终态及无额外 Native 调用断言。
 Eq(h.row.materialCostCopper,nil);Eq(h.row.profitCopper,nil);Eq(h:count('SearchAuctionArticle'),2)
 Eq(h.m:GetTradePrice(30901,0),nil);Eq(h.m:GetTradePrice(14627,3),nil)
 dofile('ui/framework/rs_ui_floating_surface.lua')
 dofile('presentation/v3/rs_v3_aux_window_store.lua')
 dofile('core/rs_report_copy_transport.lua')
 dofile('core/rs_module_diagnostics.lua')
 dofile('presentation/v3/widgets/rs_v3_trade_diagnostics.lua')
 local calls,reads,writes=#h.calls,h.m:Describe().stats.reads,h.m:Describe().stats.writes
 local report=assert(h.S.ModuleDiagnosticsHub:BuildReport('life_trade'))
 local line=assert(report:match('provider.describepriceevidence=([^\n]+)'),'price evidence provider was not registered')
 assert(line:find('grade_missing=1',1,true),line)
 assert(line:find('root.itemType=number:',1,true),line)
 assert(not line:find('<serialization_budget>',1,true));assert(not line:find('PRIVATE_SELLER',1,true))
 Eq(#h.calls,calls);Eq(h.m:Describe().stats.reads,reads);Eq(h.m:Describe().stats.writes,writes)
 local d=h.T:DescribePriceEvidence();Eq(#d.requests,2)
 for _,r in ipairs(d.requests)do assert(r.itemType==30901 or r.itemType==14627)end
 local snap=assert(h.S.ModuleDiagnosticsHub:Capture('life_trade',900))
 assert(snap.exportReport:find('provider.describediagnosticdetail',1,true))
 assert(snap.exportReport:find('listingDetails',1,true) and snap.exportReport:find('grade_missing',1,true))
 -- 本轮补录的 Native 事件和九参数必须穿过真实 Hub 进入 TXT，不能只在服务 Describe 中可见。
 assert(snap.exportReport:find('eventPacket',1,true) and snap.exportReport:find('searchArguments',1,true)
  and snap.exportReport:find('searchReturn',1,true),'search packet missing from full TXT')
 assert(snap.exportReport:find('rawRouteRows',1,true));assert(not snap.exportReport:find('PRIVATE_SELLER',1,true))
 assert(snap.exportReport:find('failureTtlMs',1,true) and snap.exportReport:find('grade_missing',1,true))
 Eq(#h.calls,calls);Eq(h.m:Describe().stats.reads,reads);Eq(h.m:Describe().stats.writes,writes)
 local describe=h.queue.Describe;h.queue.Describe=function()error('one_service_diagnostic_failed')end
 local isolated=h.T:DescribeDiagnosticDetail()
 assert(isolated.queue.available==false and isolated.queue.error:find('one_service_diagnostic_failed',1,true))
 assert(isolated.auctionRequests.requests[1].listingDetails[1].reason=='grade_missing' and #isolated.rows==1)
 h.queue.Describe=describe;Eq(#h.calls,calls)
 -- 最坏字段包装/样本数量也必须完整导出；不能只是通常两个请求未触发预算。
 h.onSearch=function()
  local rows={}
  for i=1,3 do
   local r={itemType=30901,itemGrade=1}
   for _,key in ipairs({'itemTypeId','item_type','grade','item_grade','item_grade_id','itemStack','stackCount','stack',
    'count','amount','itemCount','quantity','stackSize','directPriceStr','directPrice','buyoutPriceStr','buyoutPrice',
    'bidPriceStr','bidPrice','currentBidPriceStr','currentBidPrice'})do r[key]=string.rep('x',48)end
   rows[i]=r
  end
  return rows
 end
 for i=1,8 do assert(h.query:Search('diagnostic_stress','材料30901',{firstValidBuyout={itemType=30901,itemGrade=1},searchGeneration=i}))end
 calls=#h.calls
 report=assert(h.S.ModuleDiagnosticsHub:BuildReport('life_trade'))
 line=assert(report:match('provider.describepriceevidence=([^\n]+)'))
 assert(not line:find('<serialization_budget>',1,true),'worst-case price evidence exceeded report budget')
 Eq(#h.T:DescribePriceEvidence().requests,8);Eq(#h.calls,calls)
end)
-- 中文维护：全表必须提供明确品质；覆盖已报错普通材料与遗漏的固定稀有材料，而非只改一个配方。
Test('canonical metadata supplies native grades for all 73 trade material identities',function()
 local h=Fixture('missing');local meta=h.S.Data.TradeMaterialAuctionMeta;local count=0
 for name,m in pairs(meta)do
  count=count+1;assert(type(m.itemGrade)=='number' and m.itemGrade>=0 and m.itemGrade<=20 and m.itemGrade==math.floor(m.itemGrade),name)
 end
 Eq(count,73)
 for _,name in ipairs({'Apple','Goose Down','Orchard Puree','Medicinal Powder','Hay Bale','Ground Spices'})do Eq(meta[name].itemGrade,0,name)end
 for _,name in ipairs({'Cultivated Ginseng','Cherry','Moringa Fruit','Turmeric','Saffron'})do Eq(meta[name].itemGrade,3,name)end
 Eq(meta['Bay Leaf'].itemGrade,2);Eq(meta['Cornflower'].itemGrade,2);Eq(meta['Time-Space Rift Shard'].itemGrade,5)
end)
-- 中文维护：复现原报告的大量 raw 字段。允许原始记录明示截断，任务/货物/核心来源必须先完整落盘。
Test('large raw listing ring cannot truncate Trade state or later core diagnostics',function()
 local h=Fixture('missing');h.TA.selectedKey=h.row.key
 dofile('ui/framework/rs_ui_floating_surface.lua');dofile('presentation/v3/rs_v3_aux_window_store.lua')
 dofile('core/rs_report_copy_transport.lua');dofile('core/rs_module_diagnostics.lua')
 dofile('presentation/v3/widgets/rs_v3_trade_diagnostics.lua')
 h.onSearch=function()
  local rows={}
  for i=1,9 do
   local row={itemType=30901,itemGrade=1,itemStack=100,directPrice=59400}
   for k=1,58 do row['capturedField'..k]=string.rep('x',128) end
   rows[i]=row
  end
  return rows
 end
 for i=1,16 do assert(h.query:Search('retained_stress','香料',{firstValidBuyout={itemType=30901,itemGrade=0},searchGeneration=i}))end
 local calls=#h.calls;local snap=assert(h.S.ModuleDiagnosticsHub:Capture('life_trade',900));local report=snap.exportReport
 local current=assert(report:find('SOURCE provider.describediagnosticdetail',1,true))
 local core=assert(report:find('SOURCE scheduler.ownedTasks',1,true))
 local raw=assert(report:find('SOURCE provider.describeauctionlistingdetail',1,true))
 assert(current<core and core<raw,'raw must be serialized after all core state')
 assert(report:find('materialOperations',1,true) and report:find('rawRouteRows',1,true) and report:find('quoteBatch',1,true))
 assert(report:find('OMITTED',1,true),'large raw source must report its real budget omission')
 assert(#report<=1048576);Eq(#h.calls,calls)
end)
-- 中文维护：222712 TXT 暴露了 static accessor 未接入投影，Gilda 被错误标记可拍卖/market。
Test('commercial Gilda recipe retains bound-resource policy from canonical accessor',function()
 local h=Fixture('missing')
 h.T.State.fromZone=1;h.TA.rawRows={{key='1:5:31831',name='[格威尔]标准特制特产',sourceName='[格威尔]标准特制特产',originZone=1,destinationZone=5,itemType=31831,currentRatio=122,ratio=122,ratioUpdatedAt=h.now}}
 h.onSearch=function(keyword)
  local id=h.queue.pending.itemType
  return {{itemType=id,itemGrade=0,stackCount=100,directPriceStr=tostring((id==30899 and 1611 or 1699)*100),name=keyword}}
 end
 assert(h.TA:RebuildDisplayRows('resource_policy'));h.row=h.TA.rows[1]
 local gilda=h.row.materialRows[3];Eq(gilda.itemType,23633);Eq(gilda.count,2)
 Eq(gilda.includeInCost,false);Eq(gilda.auctionable,false);Eq(gilda.costKind,'bound_resource')
 Eq(h.row.boundResourceCount,1);Eq(h.row.nonMarketResourceCount,0)
 assert(h.T:QuoteRowMaterials(h.row.key));h:advance(5000)
 Eq(h:count('SearchAuctionArticle'),2);Eq(h.row.materialCostCopper,500290);Eq(h.row.materialCostComplete,true)
end)
-- 中文维护：222712 中只有债券 41488 返回空列表；用户确认本服绑定且不可上架。
-- 覆盖共享运输配方与仅 ItemID 的 Live 配方，禁止空列表把其他市场材料当成绑定资源。
local function BondTransportFixture(live)
 local h=Fixture('missing');local product=live and 654331 or 47110
 h.T.State.fromZone=1
 h.TA.rawRows={{key='1:5:'..product,name=live and '绑定凭证回归货物' or '蓝盐商会运输品梦之流放者',
  sourceName=live and '绑定凭证回归货物' or '蓝盐商会运输品梦之流放者',originZone=1,destinationZone=5,
  itemType=product,currentRatio=130,ratio=130,ratioUpdatedAt=h.now}}
 if live then
  h.S.Services.TradeMaterialIdentityV3.liveCache[product]={status='ready',at=h.now,craftType=654332,
   rows={{itemType=41488,itemGrade=2,count=1},{itemType=19448,itemGrade=0,count=1},
    {itemType=19449,itemGrade=0,count=1},{itemType=19450,itemGrade=0,count=1}}}
 end
 h.onSearch=function(keyword)
  local id=h.queue.pending.itemType
  assert(id~=41488,'bound bond must never enter Native search')
  return {{itemType=id,itemGrade=0,itemStack=1,directPrice=10000,name=keyword}}
 end
 assert(h.TA:RebuildDisplayRows('bond_transport'));h.row=h.TA.rows[1];h.row.priceCopper=100000
 return h,product
end
local function AssertBondPolicy(h)
 Eq(#h.row.materialRows,4)
 local bond=h.row.materialRows[1];Eq(bond.itemType,41488);Eq(bond.count,1)
 Eq(bond.includeInCost,false);Eq(bond.auctionable,false);Eq(bond.costKind,'bound_resource')
 Eq(bond.costStatus,'bound_resource');Eq(bond.unitCostCopper,nil)
 Eq(h.row.boundResourceCount,1);Eq(h.row.materialCostBasis,'gold_only_with_resources')
 assert(h.T:QuoteRowMaterials(h.row.key));h:advance(10000)
 Eq(h:count('SearchAuctionArticle'),3);Eq(h.T:GetQuoteJob(h.row.key).total,3)
 Eq(h.row.materialCostComplete,true);Eq(h.row.quoteJobState,'ready');Eq(h.row.profitStatus,'ready')
 Eq(h.row.materialCostCopper,30000);Eq(h.row.profitCopper,70000)
 assert(h.row.profitNote:find('未折价',1,true),'bound resource cost must remain explicit')
 local before=h:count('SearchAuctionArticle');assert(h.T:QuoteRowMaterials(h.row.key));h:advance(10000)
 Eq(h:count('SearchAuctionArticle'),before,'retry must reuse accepted market prices')
end
Test('shared transport quotes only three market materials and retains one bound bond',function()
 local h=BondTransportFixture(false);AssertBondPolicy(h)
end)
Test('ItemID-only live transport obeys the same bound bond policy',function()
 local h,product=BondTransportFixture(true)
 local ok,err=pcall(AssertBondPolicy,h)
 h.S.Services.TradeMaterialIdentityV3.liveCache[product]=nil;assert(ok,err)
end)
Test('empty listing for a market transport ingredient remains unknown',function()
 local h=BondTransportFixture(false)
 h.onSearch=function(keyword)
  local id=h.queue.pending.itemType;assert(id~=41488)
  if id==19449 then return {} end
  return {{itemType=id,itemGrade=0,itemStack=1,directPrice=10000,name=keyword}}
 end
 assert(h.T:QuoteRowMaterials(h.row.key));h:advance(10000)
 Eq(h:count('SearchAuctionArticle'),3);Eq(h.row.materialCostComplete,false);Eq(h.row.profitCopper,nil)
 local missing=h.row.materialRows[3];Eq(missing.itemType,19449);Eq(missing.includeInCost,true)
 Eq(missing.auctionable,true);Eq(missing.costKind,'market');Eq(missing.unitCostCopper,nil)
end)
print('TRADE REQUOTE E2E '..passed..'/'..total..' '.._VERSION)
assert(passed==total,'trade requote end-to-end failures')
