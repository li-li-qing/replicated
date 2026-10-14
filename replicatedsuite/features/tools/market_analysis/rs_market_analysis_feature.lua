------------------------------------------------------------------------
-- Replicated Suite · 行情分析功能入口
-- 作者：Replicated
-- QQ群：1104129461
--
-- 独立源码单元必须保持 Feature ID、Store ID/Schema、UpdateTopic、Demand所有者、Commands、Projection 与 ApiDependencies 的契约；禁止重复注册业务实现。
-- 共享读模型归属：当前挂单查询/投影整形与 tools_auction 共用同一份实现，
-- Authority 是 features/tools/auction/rs_auction_read_model.lua（不拥有事实，
-- 事实仍归 AuctionQueryV3 / PriceQuoteQueueV3 / AuctionSearchBridgeV3）。
-- 本文件不认识 tools_auction 的私有 State，也不建立第二个查询 Authority。
------------------------------------------------------------------------
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
