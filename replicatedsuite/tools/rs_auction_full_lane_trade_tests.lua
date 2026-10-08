-- 维护（2026-10-01，auction-full-lane-safety-1）：真实 Trade/配方/Query/Queue/材料价联测。
dofile('tools/rs_trade_tests.lua')
local baseS=ReplicatedSuite
local Boot=dofile('tools/rs_trade_requote_test_host.lua')
local passed,total=0,0
local function Eq(a,b,m)assert(a==b,(m or 'value')..': expected='..tostring(b)..' actual='..tostring(a))end
local function Test(name,fn)total=total+1;local ok,e=xpcall(fn,debug.traceback)
 if ok then passed=passed+1;print('PASS '..name)else print('FAIL '..name..': '..tostring(e))end end
local function Fixture(source)
 local h=Boot(baseS);local S=h.S;local T=S.Features.Trade;local A=T.Authority;local m=h:loadMaterialPrices()
 for _,pair in ipairs({{19448,148000},{19449,155080},{19450,146488}})do
  -- 本组的“已知可用缓存”须来自完整最低单价观察；旧首条来源另有下方回归，不能冒充已验价。
  -- 当前 rs_trade_static_v2 的三种加工材料均为普通品质0；旧宿主误用1导致原有缓存回归缺价。
  assert(m:ObserveConfirmedPrice(pair[1],0,pair[2],source or 'name_search_min_direct_unit'))
  m.entries[tostring(pair[1])..':0'].observedMinute=m.entries[tostring(pair[1])..':0'].observedMinute-4203
 end
 h.content=nil;ADDON.GetContentMainScriptPosVis=function()return nil,nil,nil,nil,nil end
 -- 中文维护注释（2026-10-02）：本组验证 API 不可读时的阻断，不能用正常空内容关闭形态代替故障。
 ADDON.GetContent=function()error('native_content_unreadable')end
 T.PriceQuoteSubscribed=false;T.PriceQuoteActivityTopic=nil;T.enabled=true;T.consumerCount=1
 T.Preferences.viewMode='all';T.State.fromZone,T.State.toZone=1,5;T.State.commerceMode,T.State.ratioMode='observe','current'
 T.quoteJobsByRowKey={};T.quoteJobOrder={};T.lastQuoteJob=nil;T.quoteEpoch=(T.quoteEpoch or 0)+1
 A.commerceSkill,A.commerceStatus=50000,'ready';A.selectedKey=nil;A.rows={}
 A.rawRows={{key='1:5:蓝盐商会运输品梦之流放者',name='蓝盐商会运输品梦之流放者',sourceName='蓝盐商会运输品梦之流放者',currentRatio=117,ratio=117,originZone=1,destinationZone=5,itemType=47110,ratioUpdatedAt=h.now}}
 assert(T:EnsurePriceQuoteSubscription());assert(A:RebuildDisplayRows('fixture'))
 assert(#A.rows==1);h.T,h.A,h.m,h.row=T,A,m,A.rows[1];return h
end
Test('Blue Salt row keeps three verified prices and excludes its bound bond from market cost',function()
 local h=Fixture();Eq(h.row.materialCount,4);assert(h.T:QuoteRowMaterials(h.row.key))
 h:advance(5000);Eq(h.T:GetQuoteJob(h.row.key).active,false)
 Eq(h.T:GetQuoteJob(h.row.key).ready,3);Eq(h.T:GetQuoteJob(h.row.key).failed,0)
 for _=1,20 do h:advance(10000);assert(h.A:RebuildDisplayRows('ratio_result'))end
 local row=h.A.rows[1];Eq(h.T:GetQuoteJob(row.key).state,'ready')
 -- 当前配方政策：41488为绑定债券资源，保留需求但不折算拍卖成本，不能反造一个“缺价”失败。
 Eq(row.materialCostComplete,true);Eq(row.boundResourceCount,1)
 assert(type(row.profitCopper)=='number');Eq(row.profitCopper,row.priceCopper-row.materialCostCopper)
 Eq(h.m:Describe().refreshPending,0);Eq(h.queue.running,false)
 Eq(h:count('AskMarketPrice'),0);Eq(h:count('SearchAuctionArticle'),0)
 local bond;for _,material in ipairs(row.materialRows)do if material.itemType==41488 then bond=material end end
 assert(bond,'bound bond remains in recipe');Eq(bond.includeInCost,false)
end)
Test('old first-listing cache cannot supply numeric Trade costs while native admission is blocked',function()
 local h=Fixture('name_search_direct_unit');assert(h.T:QuoteRowMaterials(h.row.key));h:advance(5000)
 Eq(h.row.materialCostComplete,false);Eq(h.row.profitCopper,nil);Eq(h.T:GetQuoteJob(h.row.key).ready,0)
 Eq(h:count('SearchAuctionArticle'),0);Eq(h.m.entries['19448:0'].price,148000)
end)
Test('trade cancellation also releases its material-service background owner',function()
 local h=Fixture();h:advance(5000);assert(h.m:Describe().refreshPending>0)
 assert(h.T:QuoteRowMaterials(h.row.key));assert(h.T:CancelQuoteBatch('no_consumers'))
 Eq(h.m:Describe().refreshPending,0);Eq(h.queue.running,false)
 local before=#h.calls;ADDON.GetContentMainScriptPosVis=function()return nil,nil,nil,nil,false end
 h:advance(60000);Eq(#h.calls,before,'closing native auction cannot revive cancelled background')
end)
Test('trade background cancellation does not cancel another feature on the same materials',function()
 local h=Fixture();assert(h.m:RequestRevalidate({itemType=19448,itemGrade=0,name='园艺精品'},{owner='craft'}))
 h:advance(5000);assert(h.T:CancelQuoteBatch('route_changed'));Eq(h.m:Describe().refreshPending,1)
 Eq(h.queue.running,true);assert(h.m:CancelRevalidationOwner('craft'));Eq(h.queue.running,false)
end)
Test('blocked cost revalidation preserves three existing material prices',function()
 local h=Fixture();assert(h.T:QuoteRowMaterials(h.row.key));h:advance(60000)
 Eq(h.m:GetPrice(19448,0),148000);Eq(h.m:GetPrice(19449,0),155080);Eq(h.m:GetPrice(19450,0),146488)
 Eq(h.m:GetPrice(41488,1),nil,'missing bond must not be invented as free')
end)
Test('module diagnostic exposes full-lane guard and block evidence without Native reads',function()
 local h=Fixture();h:advance(60000)
 local before=#h.calls;local state=h.T:DescribeQuoteState()
 Eq(state.queue.nativeInteractionPatch,'auction-full-lane-safety-1')
 Eq(state.queue.nativeAdmission.allowed,false);Eq(state.queue.nativeAdmission.reason,'native_auction_visibility_unknown')
 Eq(state.materialPriceCache.backgroundInteractionPatch,'auction-full-lane-safety-1')
 Eq(state.materialPriceCache.backgroundBlockReason,'native_auction_visibility_unknown');Eq(#h.calls,before)
end)
print('AUCTION_FULL_LANE_TRADE '..passed..'/'..total..' ('.._VERSION..')')
assert(passed==total,'auction full lane trade regressions failed')
