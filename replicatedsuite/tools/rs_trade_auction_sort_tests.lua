-- Actual Native boundary / Queue / Query; controlled listing order, not client acceptance.
-- 1813c is the supplied diagnostic observation; 400c is a constructed counterexample, not recovered market data.
local Boot=dofile('tools/rs_trade_requote_test_host.lua')
local passed,failed=0,0
local function Test(name,fn)
    local ok,err=xpcall(fn,debug.traceback)
    if ok then passed=passed+1;print('PASS auction-sort '..name)
    else failed=failed+1;print('FAIL auction-sort '..name..'\n'..tostring(err)) end
end
local function Listing(price,quantity,id,grade)
    return {itemType=id or 30899,itemGrade=grade or 0,stackCount=quantity,directPriceStr=tostring(price*quantity)}
end
local function Quote(h,rows)
    h.onSearch=function()return rows end;h.syncComplete=true
    assert(h.queue:RequestQuote('sort_test',30899,0,function(r)h.deliveries[#h.deliveries+1]=r end,{0},
        {singleQuery=true,priority='user',searchName='浓缩的果汁'}))
    h:advance(1000)
    assert(#h.deliveries==1,'exactly one terminal callback')
    return h.deliveries[1]
end
Test('descending ascending and shuffled listings produce the same minimum unit price',function()
    local expensive=Listing(1813,900);local middle=Listing(600,100);local cheap=Listing(400,1000)
    for _,rows in ipairs({{expensive,middle,cheap},{cheap,middle,expensive},{middle,expensive,cheap}}) do
        local h=Boot();local result=Quote(h,rows)
        assert(result.status=='ready' and result.price==400,'native sort changed material quote: '..tostring(result.price))
        assert(result.priceSource=='name_search_min_direct_unit')
        assert(h:count('SearchAuctionArticle')==1 and h:count('GetSearchedItemInfo')==3)
        assert(h:count('AskMarketPrice')==0 and h:count('GetLowestPrice')==0)
        assert(h:count('GetSearchedItemTotalCount')==1 and h.textWrites==0 and not h.queue.running)
    end
end)
Test('lowest listing total cannot replace lowest price per unit',function()
    local h=Boot();local result=Quote(h,{Listing(500,1),Listing(400,10000),Listing(600,3)})
    assert(result.status=='ready' and result.price==400)
    local evidence=h.query:DescribePriceEvidence().requests[1]
    assert(evidence.acceptedIndex==2 and evidence.readCount==3 and evidence.unreadRows==0 and evidence.candidateCount==3)
end)
Test('foreign ID grade and bid-only rows cannot become the minimum',function()
    local h=Boot();local bid=Listing(1,1);bid.directPriceStr=nil;bid.bidPriceStr='1'
    local result=Quote(h,{Listing(1,1,999),Listing(1,1,30899,2),bid,Listing(1813,900),Listing(400,3)})
    assert(result.status=='ready' and result.price==400 and h:count('GetSearchedItemInfo')==5)
end)
Test('multiple pages cannot promote the highest-price first page to an accepted market price',function()
    local h=Boot();h.totalCount=60
    local result=Quote(h,{Listing(1813,900),Listing(1600,20)})
    assert(result.status=='unavailable' and result.price==nil and result.errorCode=='auction_search_coverage_incomplete')
    assert(result.error:find('搜索结果未完整返回',1,true))
    assert(h:count('SearchAuctionArticle')==1 and h.queue:GetPriceByItemType(30899,0)==nil)
end)
Test('unknown failed and malformed total counts do not certify complete coverage',function()
    for _,kind in ipairs({'unknown','failed','negative','fractional','smaller'}) do
        local h=Boot()
        if kind=='unknown' then h.totalCountUnknown=true elseif kind=='failed' then h.totalCountError=true
        elseif kind=='negative' then h.totalCount=-1 elseif kind=='fractional' then h.totalCount=1.5 else h.totalCount=1 end
        local result=Quote(h,{Listing(1813,900),Listing(400,10)})
        assert(result.status=='unavailable' and result.price==nil,kind..' falsely certified as a minimum')
    end
end)
Test('result cap cannot commit a minimum before examining the returned candidates',function()
    local h=Boot();local rows={}
    for i=1,40 do rows[i]=Listing(2000-i,10) end
    rows[40]=Listing(1,1)
    local result=Quote(h,rows)
    assert(result.status=='unavailable' and result.price==nil)
    assert(h:count('GetSearchedItemInfo')<=h.queue.fallbackSearchLimit and h:count('SearchAuctionArticle')==1)
end)
Test('unreadable listing cannot conceal a lower price while committing the other row',function()
    local h=Boot();local native=X2Auction.GetSearchedItemInfo
    X2Auction.GetSearchedItemInfo=function(self,index)if index==2 then error('unreadable listing') end;return native(self,index)end
    local result=Quote(h,{Listing(1813,900),Listing(400,10)})
    assert(result.status=='unavailable' and result.price==nil)
end)
-- 中文维护（发布审查）：可读表中的字段缺失同样不能证明最低价；测试走真实 Query/Queue
-- 的单包 Native 边界，防止跳过未知匹配挂单后把剩余高价写进材料成本缓存。
Test('matching buyout with unreadable quantity cannot certify the remaining higher price',function()
    for _,kind in ipairs({'missing','zero','negative','fractional','malformed'}) do
        local h=Boot();local unknown=Listing(400,1)
        if kind=='missing' then unknown.stackCount=nil elseif kind=='zero' then unknown.stackCount=0
        elseif kind=='negative' then unknown.stackCount=-1 elseif kind=='fractional' then unknown.stackCount=1.5
        else unknown.stackCount='unreadable' end
        local result=Quote(h,{Listing(1813,1),unknown})
        assert(result.status=='unavailable' and result.price==nil,kind..' quantity certified a false minimum')
        assert(h.queue:GetPriceByItemType(30899,0)==nil and h:count('SearchAuctionArticle')==1)
    end
end)
Test('matching listing with unreadable buyout cannot certify the remaining higher price',function()
    for _,kind in ipairs({'missing','malformed','malformed_with_bid'}) do
        local h=Boot();local unknown=Listing(400,1)
        if kind=='missing' then unknown.directPriceStr=nil else unknown.directPriceStr='unreadable' end
        if kind=='malformed_with_bid' then unknown.bidPriceStr='100' end
        local result=Quote(h,{Listing(1813,1),unknown})
        assert(result.status=='unavailable' and result.price==nil,kind..' buyout certified a false minimum')
        assert(h.queue:GetPriceByItemType(30899,0)==nil and h:count('SearchAuctionArticle')==1)
    end
end)
Test('unreadable listing identity cannot be treated as a proven foreign item',function()
    for _,kind in ipairs({'id_missing','grade_missing','id_fractional','grade_fractional'}) do
        local h=Boot();local unknown=Listing(400,1)
        if kind=='id_missing' then unknown.itemType=nil elseif kind=='grade_missing' then unknown.itemGrade=nil
        elseif kind=='id_fractional' then unknown.itemType=30899.5 else unknown.itemGrade=0.5 end
        local result=Quote(h,{Listing(1813,1),unknown})
        assert(result.status=='unavailable' and result.price==nil,kind..' identity certified a false minimum')
        assert(h.queue:GetPriceByItemType(30899,0)==nil and h:count('SearchAuctionArticle')==1)
    end
end)
Test('proven foreign identity and explicit bid-only rows remain safe exclusions',function()
    local h=Boot();local foreign=Listing(1,1,999);foreign.stackCount=nil
    local foreignGrade=Listing(1,1,30899,2);foreignGrade.directPriceStr='unreadable'
    local bidOnly=Listing(1,1);bidOnly.directPriceStr=nil;bidOnly.bidPriceStr='100';bidOnly.stackCount=nil
    local noBuyout=Listing(1,1);noBuyout.directPriceStr='0';noBuyout.stackCount=nil
    local result=Quote(h,{foreign,foreignGrade,bidOnly,noBuyout,Listing(400,2)})
    assert(result.status=='ready' and result.price==400 and h:count('SearchAuctionArticle')==1)
end)
Test('old sort-dependent cache remains stored but cannot supply a Trade cost',function()
    local h=Boot();local m=h:loadMaterialPrices()
    assert(m:ObserveConfirmedPrice(30899,0,1813,'name_search_direct_unit'))
    local stored=m.entries['30899:0'];local revision=m.revision
    local price,meta=m:GetTradePrice(30899,0)
    assert(price==nil and meta.needsRefresh and meta.sortUnverified)
    assert(m.entries['30899:0']==stored and stored.price==1813 and m.revision==revision,'read modified the old canonical state')
end)
Test('first newly verified minimum replaces an unverified old high price without anomaly hold',function()
    local h=Boot();local m=h:loadMaterialPrices();assert(m:ObserveConfirmedPrice(30899,0,1813,'name_search_direct_unit'))
    local result=Quote(h,{Listing(1813,900),Listing(400,1000)})
    assert(result.status=='ready' and result.price==400 and result.priceAccepted==true)
    assert(m:GetTradePrice(30899,0)==400 and m.entries['30899:0'].source=='name_search_min_direct_unit')
    assert(#m.entries['30899:0'].samples==0,'unverified historical sample contaminated trusted anomaly baseline')
end)
Test('sort fix retains anomaly protection for a previously verified quote',function()
    local h=Boot();local m=h:loadMaterialPrices();assert(m:ObserveConfirmedPrice(30899,0,400,'market_price:0'))
    local result=Quote(h,{Listing(2000,20),Listing(1500,100)})
    assert(result.status=='review_required' and result.price==nil and m:GetTradePrice(30899,0)==400)
    assert(h:count('SearchAuctionArticle')==1)
end)
Test('normal auction UI search still returns all requested detached rows',function()
    local h=Boot();h.onSearch=function()return {Listing(1813,900),Listing(400,10)}end;h.syncComplete=true
    assert(h.query:Search('ui_search','浓缩的果汁',{}))
    local result=h.query:GetSnapshot('ui_search')
    assert(result.status=='ready' and #result.rows==2 and result.rows[1].unitDirectPrice==1813)
    assert(h:count('GetSearchedItemTotalCount')==0)
end)
Test('missing total-count getter only declines that quote and releases its lifetime',function()
    local h=Boot();X2Auction.GetSearchedItemTotalCount=nil
    local result=Quote(h,{Listing(1813,900)})
    assert(result.status=='unavailable' and result.price==nil and result.errorCode=='auction_search_total_count_invalid')
    assert(not h.queue.running and h.query.pending==nil and h:count('SearchAuctionArticle')==1)
end)
Test('stamped old material cache reloads intact and replacement does not clear unrelated prices',function()
    local function CacheBoot(disk)
        local h=dofile('tools/rs_gear_page_test_host.lua')({disk=disk})
        h.S.Utils.GetServerTime=function()return {year=2026,month=10,day=7,hour=12,minute=0}end
        dofile('services/rs_material_price_service_v3.lua')
        h.m=h.S.Services.MaterialPriceServiceV3
        assert(h.m:EnsureStoreLoaded());return h
    end
    local h=CacheBoot()
    assert(h.m:ObserveConfirmedPrice(30899,0,1813,'name_search_direct_unit'))
    assert(h.m:ObserveConfirmedPrice(3628,2,500,'market_price:2'))
    assert(h.S.Persistence:SaveStore(h.m.StoreId,{durable=true}))
    local r=CacheBoot(h.Copy(h.disk));local p=r.S.Persistence
    local store=p:GetStore(r.m.StoreId);assert(store.loadStatus=='loaded' and not store.writeFenced)
    local fingerprint=p:FingerprintCanonicalValue(store,{entries=r.m.entries})
    local reads,writes=r.reads,r.writes
    assert(r.m:GetTradePrice(30899,0)==nil and r.m.entries['30899:0'].price==1813)
    assert(r.m:GetTradePrice(3628,2)==500)
    assert(p:FingerprintCanonicalValue(store,{entries=r.m.entries})==fingerprint and r.reads==reads and r.writes==writes)
    assert(r.m:ObserveConfirmedPrice(30899,0,400,'name_search_min_direct_unit'))
    assert(p:SaveStore(r.m.StoreId,{durable=true}))
    local again=CacheBoot(r.Copy(r.disk))
    assert(again.m:GetTradePrice(30899,0)==400 and again.m:GetTradePrice(3628,2)==500 and again.clears==0)
end)
print(string.format('TRADE_AUCTION_SORT: %d passed / %d failed (Lua %s)',passed,failed,_VERSION))
if failed>0 then os.exit(1) end
