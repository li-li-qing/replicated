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
Test('three sampled listings provide a reference price without scanning later pages',function()
    local h=Boot();h.totalCount=50
    local result=Quote(h,{Listing(1813,900),Listing(600,100),Listing(400,1000),Listing(1,1)})
    assert(result.status=='ready' and result.price==400)
    assert(result.priceSource=='name_search_sampled_lower_unit')
    assert(h:count('SearchAuctionArticle')==1 and h:count('GetSearchedItemInfo')==3)
    local evidence=h.query:DescribePriceEvidence().requests[1]
    assert(evidence.readCount==3 and evidence.unreadRows==1 and h:count('GetSearchedItemTotalCount')==0)
end)
Test('three equal sample prices keep the first listing',function()
    local h=Boot();local result=Quote(h,{Listing(500,2),Listing(500,5),Listing(500,10)})
    local evidence=h.query:DescribePriceEvidence().requests[1]
    assert(result.status=='ready' and result.price==500 and evidence.acceptedIndex==1)
    assert(result.priceSource=='name_search_sampled_direct_unit' and evidence.sampleLowerLater==false)
    assert(h:count('GetSearchedItemInfo')==3)
end)
Test('descending ascending and shuffled three-row samples choose the lowest sampled unit price',function()
    local expensive=Listing(1813,900);local middle=Listing(600,100);local cheap=Listing(400,1000)
    for _,case in ipairs({
        {rows={expensive,middle,cheap},source='name_search_sampled_lower_unit'},
        {rows={cheap,middle,expensive},source='name_search_sampled_direct_unit'},
        {rows={middle,expensive,cheap},source='name_search_sampled_lower_unit'},
    }) do
        local h=Boot();local result=Quote(h,case.rows)
        assert(result.status=='ready' and result.price==400,'native sort changed material quote: '..tostring(result.price))
        assert(result.priceSource==case.source)
        assert(h:count('SearchAuctionArticle')==1 and h:count('GetSearchedItemInfo')==3)
        assert(h:count('AskMarketPrice')==0 and h:count('GetLowestPrice')==0)
        assert(h:count('GetSearchedItemTotalCount')==0 and h.textWrites==0 and not h.queue.running)
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
    local result=Quote(h,{Listing(1,1,999),Listing(400,3),bid,Listing(1,1,30899,2)})
    assert(result.status=='ready' and result.price==400 and h:count('GetSearchedItemInfo')==3)
end)
Test('a first-page sample is visible as a reference even when the search has more pages',function()
    local h=Boot();h.totalCount=60
    local result=Quote(h,{Listing(1813,900),Listing(1600,20)})
    assert(result.status=='ready' and result.price==1600 and result.priceSource=='name_search_sampled_lower_unit')
    assert(h:count('SearchAuctionArticle')==1 and h.queue:GetPriceByItemType(30899,0)==1600)
end)
Test('total-count getter is never called for a three-row reference sample',function()
    for _,kind in ipairs({'unknown','failed','negative','fractional','smaller'}) do
        local h=Boot()
        if kind=='unknown' then h.totalCountUnknown=true elseif kind=='failed' then h.totalCountError=true
        elseif kind=='negative' then h.totalCount=-1 elseif kind=='fractional' then h.totalCount=1.5 else h.totalCount=1 end
        local result=Quote(h,{Listing(1813,900),Listing(400,10)})
        assert(result.status=='ready' and result.price==400 and result.priceSource=='name_search_sampled_lower_unit')
        assert(h:count('GetSearchedItemTotalCount')==0)
    end
end)
Test('sample cap avoids reading forty rows and makes no claim about the later lowest listing',function()
    local h=Boot();local rows={}
    for i=1,40 do rows[i]=Listing(2000-i,10) end
    rows[40]=Listing(1,1)
    local result=Quote(h,rows)
    assert(result.status=='ready' and result.price==1997 and result.priceSource=='name_search_sampled_lower_unit')
    assert(h:count('GetSearchedItemInfo')==3 and h:count('SearchAuctionArticle')==1)
end)
Test('unreadable later listing does not erase an already verified sample reference',function()
    local h=Boot();local native=X2Auction.GetSearchedItemInfo
    X2Auction.GetSearchedItemInfo=function(self,index)if index==2 then error('unreadable listing') end;return native(self,index)end
    local result=Quote(h,{Listing(1813,900),Listing(400,10)})
    assert(result.status=='ready' and result.price==1813 and result.priceSource=='name_search_sampled_direct_unit')
end)
-- 字段不可读的行不参与报价；其它已核验行仍可提供明确标注的样本参考价。
Test('matching buyout with unreadable quantity leaves the valid sample visible',function()
    for _,kind in ipairs({'missing','zero','negative','fractional','malformed'}) do
        local h=Boot();local unknown=Listing(400,1)
        if kind=='missing' then unknown.stackCount=nil elseif kind=='zero' then unknown.stackCount=0
        elseif kind=='negative' then unknown.stackCount=-1 elseif kind=='fractional' then unknown.stackCount=1.5
        else unknown.stackCount='unreadable' end
        local result=Quote(h,{Listing(1813,1),unknown})
        assert(result.status=='ready' and result.price==1813,kind..' lost the valid sample')
        assert(h.queue:GetPriceByItemType(30899,0)==1813 and h:count('SearchAuctionArticle')==1)
    end
end)
Test('matching listing with unreadable buyout leaves the valid sample visible',function()
    for _,kind in ipairs({'missing','malformed','malformed_with_bid'}) do
        local h=Boot();local unknown=Listing(400,1)
        if kind=='missing' then unknown.directPriceStr=nil else unknown.directPriceStr='unreadable' end
        if kind=='malformed_with_bid' then unknown.bidPriceStr='100' end
        local result=Quote(h,{Listing(1813,1),unknown})
        assert(result.status=='ready' and result.price==1813,kind..' lost the valid sample')
        assert(h.queue:GetPriceByItemType(30899,0)==1813 and h:count('SearchAuctionArticle')==1)
    end
end)
Test('unreadable listing identity cannot become the sampled price',function()
    for _,kind in ipairs({'id_missing','grade_missing','id_fractional','grade_fractional'}) do
        local h=Boot();local unknown=Listing(400,1)
        if kind=='id_missing' then unknown.itemType=nil elseif kind=='grade_missing' then unknown.itemGrade=nil
        elseif kind=='id_fractional' then unknown.itemType=30899.5 else unknown.itemGrade=0.5 end
        local result=Quote(h,{Listing(1813,1),unknown})
        assert(result.status=='ready' and result.price==1813,kind..' became the sampled price')
        assert(h.queue:GetPriceByItemType(30899,0)==1813 and h:count('SearchAuctionArticle')==1)
    end
end)
Test('proven foreign identity and explicit bid-only rows remain safe exclusions',function()
    local h=Boot();local foreign=Listing(1,1,999);foreign.stackCount=nil
    local foreignGrade=Listing(1,1,30899,2);foreignGrade.directPriceStr='unreadable'
    local bidOnly=Listing(1,1);bidOnly.directPriceStr=nil;bidOnly.bidPriceStr='100';bidOnly.stackCount=nil
    local noBuyout=Listing(1,1);noBuyout.directPriceStr='0';noBuyout.stackCount=nil
    local result=Quote(h,{foreign,foreignGrade,Listing(400,2),bidOnly,noBuyout})
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
Test('first sampled reference replaces an old sort-dependent price without anomaly hold',function()
    local h=Boot();local m=h:loadMaterialPrices();assert(m:ObserveConfirmedPrice(30899,0,1813,'name_search_direct_unit'))
    local result=Quote(h,{Listing(1813,900),Listing(400,1000)})
    assert(result.status=='ready' and result.price==400 and result.priceAccepted==true)
    assert(m:GetTradePrice(30899,0)==400 and m.entries['30899:0'].source=='name_search_sampled_lower_unit')
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
Test('missing total-count getter does not block a three-row reference quote',function()
    local h=Boot();X2Auction.GetSearchedItemTotalCount=nil
    local result=Quote(h,{Listing(1813,900)})
    assert(result.status=='ready' and result.price==1813 and h:count('GetSearchedItemTotalCount')==0)
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
