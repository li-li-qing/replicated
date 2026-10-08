-- Cache-first contract migration: exercise real MaterialPrice/TradeQuote services.
-- Monetary samples are synthetic boundary inputs, not live market evidence.
dofile('tools/rs_trade_tests.lua')
local baseS=ReplicatedSuite
local Boot=dofile('tools/rs_trade_requote_test_host.lua')
local passed,total=0,0
local function Test(name,fn)
 total=total+1;local ok,err=xpcall(fn,debug.traceback)
 if ok then passed=passed+1;print('PASS '..name)else print('FAIL '..name..': '..tostring(err))end
end
local function Fixture(candidate,missing)
 local h=Boot(baseS);local S=h.S;local T=S.Features.Trade;local TA=T.Authority;local m=h:loadMaterialPrices()
 -- 中文维护（发布审查）：真实材料身份服务使用已核 Native 品质：香辛料0、樱桃3；
 -- 旧测试统一写品质1只会缓存另一身份，不能为了命中旧 fixture 改生产成本或默认品质。
 if not missing then
  assert(m:ObserveConfirmedPrice(30901,0,559,'market_price:0'))
  assert(m:ObserveConfirmedPrice(14627,3,9000,'market_price:3'))
  if candidate then local ok,err=m:ObserveConfirmedPrice(30901,0,candidate,'market_price:0');assert(ok==false and err=='anomaly_candidate_held')end
 end
 T.PriceQuoteSubscribed=false;T.PriceQuoteActivityTopic=nil;T.enabled=true;T.consumerCount=1;T.Preferences.viewMode='all'
 T.State.fromZone,T.State.toZone=2,8;T.State.commerceMode,T.State.ratioMode='observe','current'
 T.quoteJobsByRowKey={};T.quoteJobOrder={};T.lastQuoteJob=nil;T.quoteEpoch=(T.quoteEpoch or 0)+1
 TA.commerceSkill,TA.commerceStatus=50000,'ready';TA.selectedKey=nil;TA.rows={}
 TA.rawRows={{key='2:8:31855',name='[玛瑞诺普]新鲜特产',sourceName='[玛瑞诺普]新鲜特产',
  currentRatio=108,ratio=108,originZone=2,destinationZone=8,itemType=31855,ratioUpdatedAt=h.now}}
 assert(T:EnsurePriceQuoteSubscription());assert(TA:RebuildDisplayRows('cost_retry_fixture'));assert(#TA.rows==1)
 h.T,h.TA,h.m,h.row=T,TA,m,TA.rows[1];return h
end
Test('installed Marianople ordinary Fine recipe uses spices180 and cherry2',function()
 local h=Fixture();local row=h.row;assert(#row.materialRows==2)
 assert(row.materialRows[1].itemType==30901 and row.materialRows[1].count==180)
 assert(row.materialRows[2].itemType==14627 and row.materialRows[2].count==2)
 assert(row.materialRows[1].itemGrade==0 and row.materialRows[2].itemGrade==3,'native material identities drifted')
 assert(row.materialCostCopper==559*180+9000*2)
 assert(row.profitCopper==row.priceCopper-row.materialCostCopper)
end)
Test('explicit double click uses fresh accepted prices despite previous failed transport state',function()
 local h=Fixture();local row=h.row
 for _,m in ipairs(row.materialRows)do h.queue.quoteStateByItemType[m.itemType]={status='failed',itemGrade=m.itemGrade,at=h.now,error='cold_read_error'}end
 local ok,err,totalItems=h.T:QuoteRowMaterials(row.key,'basic');assert(ok,err);assert(totalItems==2)
 local job=h.T.quoteJobsByRowKey[row.key];assert(job and not job.active and job.total==2 and job.ready==2)
 assert(row.materialCostCopper==118620 and row.profitCopper==row.priceCopper-118620)
 h:advance(15000);assert(#h.queue.queue==0 and h:count('SearchAuctionArticle')==0 and h:count('AskMarketPrice')==0)
end)
Test('repeat missing-price failure respects bounded cooldown without native retry fanout',function()
 local h=Fixture(nil,true);h.syncComplete=true;h.onSearch=function()return {}end
 assert(h.T:QuoteRowMaterials(h.row.key));h:advance(5000)
 local first=h:count('SearchAuctionArticle');assert(first==2,'each missing identity gets one attempt')
 assert(not h.T:GetQuoteJob(h.row.key).active and h.row.profitCopper==nil)
 assert(h.T:_StartRowQuoteJob(h.row,'basic',{force=false}));h:advance(5000)
 assert(h:count('SearchAuctionArticle')==first and not h.T:GetQuoteJob(h.row.key).active,'failed identities must not fan out again during cooldown')
 h:advance(31000);assert(h.T:QuoteRowMaterials(h.row.key));h:advance(5000)
 assert(h:count('SearchAuctionArticle')==first+2,'new action may retry after bounded cooldown')
end)
Test('repeat double click joins same active row instead of cloning tasks',function()
 local h=Fixture(nil,true);assert(h.T:QuoteRowMaterials(h.row.key));local job=h.T.quoteJobsByRowKey[h.row.key]
 assert(job.active);local count=h:count('SearchAuctionArticle')
 assert(h.T:QuoteRowMaterials(h.row.key));assert(h.T.quoteJobsByRowKey[h.row.key]==job)
 assert(h:count('SearchAuctionArticle')==count and #h.queue.queue<=1,'recipe requests are sequential')
 assert(h.T:CancelQuoteBatch('test_cleanup'))
end)
Test('candidate outlier stays out of material arithmetic and is visible in details',function()
 local h=Fixture(1499);local row=h.row;local m=row.materialRows[1]
 assert(m.unitCostCopper==559 and m.totalCostCopper==559*180)
 assert(m.priceCandidateCopper==1499 and m.priceCandidateCount==1,'candidate evidence missing')
 assert(m.detailText:find('待复核',1,true),'candidate status hidden from material detail')
 assert(h.T:SelectRow(row.key));local d=h.T:DescribeSelectedEconomics()
 assert(d.materials[1]:find('candidateCopper=1499',1,true),'candidate omitted from selected diagnostic')
end)
Test('genuinely expensive confirmed materials remain negative not clamped or absolutized',function()
 local h=Fixture(nil,true)
 assert(h.m:ObserveConfirmedPrice(30901,0,50000,'market_price:0'))
 assert(h.m:ObserveConfirmedPrice(14627,3,50000,'market_price:3'))
 assert(h.TA:RebuildDisplayRows('negative_is_valid'));local row=h.TA.rows[1]
 assert(row.materialCostCopper==50000*182 and row.profitCopper<0 and row.profitCopper==row.priceCopper-row.materialCostCopper)
end)
print(string.format('TRADE_COST_RETRY: %d/%d passed (%s)',passed,total,_VERSION))
assert(passed==total,'Trade cost/retry failures')
