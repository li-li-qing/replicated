-- Replicated Suite · 行情分析功能入口
-- 作者：Replicated
-- QQ群：1104129461
-- 与拍卖助手共用 AuctionReadModel，查询/报价/原生同步仍归共享服务；不读 tools_auction 私有 State 或另建查询模型。
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local FSF = S.FeatureSliceFactory
local ARM = S.AuctionReadModel
if type(FSF) ~= "table" then error("FeatureSliceFactory unavailable for tools_market_analysis") end
if type(ARM) ~= "table" then error("AuctionReadModel unavailable for tools_market_analysis") end
local NewFeature = FSF.NewFeature
local AuctionQueryReconcile, AuctionRows, AuctionProjection = ARM.ReconcileDemand, ARM.Rows, ARM.Projection

local marketCommands = ARM.SettingsCommands()
local MarketAnalysis = NewFeature("tools_market_analysis",{apiDependencies={"X2Auction:SearchAuctionArticle","X2Auction:GetSearchedItemCount","X2Auction:GetSearchedItemInfo"},state={keyword="",exactMatch=false,resultLimit=20},default={keyword="",exactMatch=false,resultLimit=20},
    reconcileDemand=AuctionQueryReconcile,read=function(feature)
        local rows,snapshot=AuctionRows(feature,false)
        if #rows==0 and snapshot.status~="waiting" then rows[1]={key="market:hint",name="当前拍卖挂单",text="输入物品名称后显式查询；这里展示当前搜索结果，不把挂单伪装成历史成交价。",statusText="按需查询",tone="muted"} end
        local status=snapshot.status=="failed" and "unavailable" or snapshot.status=="waiting" and "partial" or #rows>0 and "ready" or "empty"
        return rows,status,snapshot.error
    end,projection=AuctionProjection,commands=marketCommands})
MarketAnalysis.AuctionQueryContractVersion = 1
