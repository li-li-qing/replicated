-- 2026-09-30: production Trade projection + cold module report. Quotes below are
-- synthetic boundary data, NOT observed RU prices or the user's expected margin.
dofile("tools/rs_trade_tests.lua")
local S = ReplicatedSuite
local Trade, TA = S.Features.Trade, S.Features.Trade.Authority
local Queue = S.Services.PriceQuoteQueueV3
local passed, total = 0, 0
local function Test(name, fn)
    total = total + 1
    local ok, err = xpcall(fn, debug.traceback)
    if ok then passed = passed + 1; print("PASS " .. name)
    else print("FAIL " .. name .. ": " .. tostring(err)) end
end
local function Fixture()
    Trade.enabled = false; Trade.consumerCount = 0
    Trade.Preferences.viewMode = "all"
    Trade.State.fromZone, Trade.State.toZone = 26, 8
    Trade.State.commerceMode, Trade.State.ratioMode = "observe", "current"
    TA.commerceSkill, TA.commerceStatus = 50000, "ready"
    TA.selectedKey = nil; TA.rows = {}
    TA.rawRows = {{key="26:8:31861",name="[地狱]保存特产",sourceName="[地狱]保存特产",
        currentRatio=126,ratio=126,originZone=26,destinationZone=8,itemType=31861,ratioUpdatedAt=100}}
    S.Services.MaterialPriceServiceV3 = {
        GetRevision=function()return 9 end,
        GetTradePrice=function(_, id)
            if id == 30899 then return 1710,{freshness="stale",source="auction_name",ageMinutes=2900,refreshing=true} end
            if id == 14630 then return 1320,{freshness="fresh",source="market_average",ageMinutes=5,refreshing=false} end
            return nil,{freshness="missing"}
        end,
    }
    assert(TA:RebuildDisplayRows("economics_fixture"))
    assert(#TA.rows == 1)
    return TA.rows[1]
end
local function Selected()
    local row=Fixture();assert(Trade:SelectRow(row.key));return row
end
local function Describe()
    assert(type(Trade.DescribeSelectedEconomics)=="function", "selected economics diagnostic missing")
    return Trade:DescribeSelectedEconomics()
end
Test("preserved specialty uses installed exact product and both ingredient quantities", function()
    local row=Fixture()
    assert(row.itemType==31861 and row.recipeLabel=="Hellswamp Preserved Specialty")
    assert(#row.materialRows==2)
    assert(row.materialRows[1].itemType==30899 and row.materialRows[1].count==200)
    assert(row.materialRows[2].itemType==14630 and row.materialRows[2].count==15)
    assert(row.materialCostCopper==361800)
    assert(row.profitCopper==row.priceCopper-row.materialCostCopper,"do not alter margin formula")
end)
Test("price source age and refresh state survive the pricing branch", function()
    local m=Fixture().materialRows[1]
    assert(m.priceSource=="auction_name", "lost priceMeta.source across block scope")
    assert(m.priceFreshness=="stale" and m.priceAgeMinutes==2900 and m.priceRefreshing==true)
end)
Test("metadata is ingredient-local not carried into the second material", function()
    local m=Fixture().materialRows[2]
    assert(m.priceSource=="market_average" and m.priceFreshness=="fresh")
    assert(m.priceAgeMinutes==5 and m.priceRefreshing==false)
end)
Test("cached material detail honestly states its age", function()
    local m=Fixture().materialRows[1]
    assert(m.detailText:find("2天前",1,true), "cached age absent from player detail")
end)
Test("unrelated global priceMeta cannot inject false provenance", function()
    _G.priceMeta={source="UNRELATED_GLOBAL",ageMinutes=1,freshness="fresh",refreshing=false}
    local row=Fixture();_G.priceMeta=nil
    assert(row.materialRows[1].priceSource=="auction_name", "global metadata contaminated material")
end)
Test("legacy compatibility without the Trade price API preserves queue source and age", function()
    local row=Fixture();local getPrice=S.Services.MaterialPriceServiceV3.GetTradePrice
    local legacy=Queue.GetPriceWithProvenance
    S.Services.MaterialPriceServiceV3.GetTradePrice=nil
    Queue.GetPriceWithProvenance=function()return 200,"reference",{source="queue_reference",freshness="old",ageMinutes=20000}end
    assert(TA:RebuildDisplayRows("legacy_price_evidence"))
    S.Services.MaterialPriceServiceV3.GetTradePrice=getPrice;Queue.GetPriceWithProvenance=legacy
    assert(TA.rows[1].materialRows[1].priceSource=="queue_reference")
    assert(TA.rows[1].materialRows[1].priceAgeMinutes==20000)
end)
Test("authoritative missing Trade price cannot resurrect unbounded legacy reference", function()
    Fixture();local prices=S.Services.MaterialPriceServiceV3
    local getPrice=prices.GetTradePrice;local legacy=Queue.GetPriceWithProvenance
    prices.GetTradePrice=function()return nil,{freshness="old",ageMinutes=20000}end
    Queue.GetPriceWithProvenance=function()error("old reference fallback bypassed Trade cache policy")end
    local ok,err=pcall(TA.RebuildDisplayRows,TA,"old_price_is_missing")
    prices.GetTradePrice=getPrice;Queue.GetPriceWithProvenance=legacy
    assert(ok,err);assert(TA.rows[1].materialCostCopper==nil and TA.rows[1].profitCopper==nil)
end)
Test("ratio fast publish retains metadata without reading prices again", function()
    local row=Fixture();local cost=row.materialCostCopper
    local getPrice=S.Services.MaterialPriceServiceV3.GetTradePrice
    S.Services.MaterialPriceServiceV3.GetTradePrice=function()error("unexpected price read")end
    TA.rawRows[1].currentRatio=130;TA.rawRows[1].ratio=130
    local ok,err=pcall(TA.RebuildDisplayRows,TA,"fast_evidence",{includeMaterials=false})
    S.Services.MaterialPriceServiceV3.GetTradePrice=getPrice
    assert(ok,err);row=TA.rows[1]
    assert(row.fastMaterialCarryForward==true and row.materialCostCopper==cost)
    assert(row.materialRows[1].priceAgeMinutes==2900)
    assert(row.profitCopper==row.priceCopper-cost)
end)
Test("no selected row is explicit and does not guess the first row", function()
    Fixture();local d=Describe()
    assert(d.available==false and d.reason=="select_trade_row")
end)
Test("selected report shows exact copper arithmetic and ingredient evidence", function()
    local row=Selected();local d=Describe()
    assert(d.patch=="trade-selected-economics-1" and d.available==true and d.currencyUnit=="copper")
    assert(d.row.itemType==31861 and d.row.originZone==26 and d.row.destinationZone==8)
    assert(d.economics.materialCostCopper==361800 and d.economics.profitCopper==row.profitCopper)
    assert(d.economics.arithmeticDeltaCopper==0 and d.materialCount==2)
    assert(d.materials[1]:find("unitCostCopper=1710",1,true) and d.materials[1]:find("count=200",1,true))
    assert(d.materials[1]:find("priceSource=auction_name",1,true) and d.materials[1]:find("ageMinutes=2900",1,true))
    assert(d.payout.packCategory=="preserved" and d.payout.packMultiplier==1.03)
end)
Test("selected diagnostics never reprice acquire demand or query Native", function()
    Selected()
    local p=S.Services.MaterialPriceServiceV3.GetTradePrice;local native=S.Api.CallCapability
    local acquire=Trade.AcquireConsumer;local before=TA.revision
    S.Services.MaterialPriceServiceV3.GetTradePrice=function()error("repriced")end
    S.Api.CallCapability=function()error("queried Native")end
    Trade.AcquireConsumer=function()error("acquired demand")end
    local ok,d=pcall(Describe)
    S.Services.MaterialPriceServiceV3.GetTradePrice=p;S.Api.CallCapability=native;Trade.AcquireConsumer=acquire
    assert(ok,d);assert(d.available and before==TA.revision)
end)
Test("snapshot is detached and does not change with subsequent display row mutation", function()
    local row=Selected();local d=Describe();local old=d.economics.profitCopper
    row.profitCopper=old+1;row.materialRows[1].unitCostCopper=1
    assert(d.economics.profitCopper==old and d.materials[1]:find("unitCostCopper=1710",1,true))
    d.row.itemType=42;assert(row.itemType==31861)
end)
Test("missing costs remain nil not a fabricated zero profit", function()
    local row=Selected();row.materialCostCopper=nil;row.profitCopper=nil;row.materialCostComplete=false
    local d=Describe()
    assert(d.economics.materialCostCopper==nil and d.economics.profitCopper==nil)
    assert(d.economics.arithmeticDeltaCopper==nil and d.economics.materialCostComplete==false)
end)
Test("diagnostics expose arithmetic mismatch but never rewrite its source", function()
    local row=Selected();local before=row.profitCopper;row.profitCopper=before+19
    local d=Describe();assert(d.economics.arithmeticDeltaCopper==19 and row.profitCopper==before+19)
end)
Test("registered Trade module provider keeps all 32 bounded material lines", function()
    local row=Selected()
    for i=3,32 do row.materialRows[i]={name="材料"..i,itemType=60000+i,count=i,
        unitCostCopper=i,totalCostCopper=i*i,priceSource="source",priceFreshness="fresh",priceAgeMinutes=i,
        includeInCost=true,costStatus="quoted"} end
    dofile("core/rs_module_diagnostics.lua")
    -- Only UI construction boundary is supplied. Loading this file must register,
    -- not create a legacy diagnostics window or acquire a consumer.
    S.RSUI.FloatingSurface=S.RSUI.FloatingSurface or {}
    S.UIV3.AuxWindowStoreV3=S.UIV3.AuxWindowStoreV3 or {}
    dofile("presentation/v3/widgets/rs_v3_trade_diagnostics.lua")
    local H=S.ModuleDiagnosticsHub
    local providers=H.providers.life_trade or {}
    local found=false
    for _,p in ipairs(providers) do if p.id=="describeselectedeconomics" then found=true end end
    assert(found,"Trade provider registration missing")
    local text=assert(H:BuildReport("life_trade"))
    assert(text:find("trade-selected-economics-1",1,true),"economic evidence absent")
    local section=assert(text:match("provider%.describeselectedeconomics=([^\n]*)"))
    assert(not section:find("<serialization_budget>",1,true),"selected evidence exhausted budget")
    assert(section:find("itemType=60032",1,true),"last material lost to serializer limits")
    local d=Describe();assert(d.materialCount==32 and d.materialsOmitted==0)
end)
Test("unexpected over-limit materials are counted not silently discarded", function()
    local row=Selected()
    for i=3,40 do row.materialRows[i]={name="材料"..i,itemType=70000+i,count=1} end
    local d=Describe();assert(#d.materials==32 and d.materialCount==40 and d.materialsOmitted==8)
end)
print(string.format("TRADE_ECONOMICS_EVIDENCE: %d/%d passed (%s)",passed,total,_VERSION))
assert(passed==total,"Trade economics evidence failures")
