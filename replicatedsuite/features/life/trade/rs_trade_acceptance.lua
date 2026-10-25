-- Replicated Suite · 贸易助手契约验收
-- 作者：Replicated
-- QQ群：1104129461
-- 验证贸易Feature自身Authority、契约版本下限、命令面及两个读接口；实现缺失不得静默返回，失败为blocker，由sequence_harness报告。
-- TradePayoutV3、MaterialPriceServiceV3、PriceQuoteQueueV3、TradeDetailFloatingV3、LifeM16PagesContract等Service/UI契约仍归Foundation，不得耦合进Feature检查。
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local G = S.FoundationGate
if type(G) ~= "table" or type(G.RegisterSequenceCase) ~= "function" then return end
local F = S.Features and S.Features.Trade or nil

local function Fail(message) return false, tostring(message or "trade_acceptance_failed") end

-- 运行时只做只读诊断；完整序列测试仅离线执行。
G:RegisterSequenceCase("v3_life_trade_detail_favorites_contract", function()
    if type(F) ~= "table" then return Fail("implementation_not_registered") end
    if type(F.Authority) ~= "table" then return Fail("authority_missing") end
    if (tonumber(F.Authority.version) or 0) < 6 then return Fail("Authority.version_floor") end
    if (tonumber(F.Authority.TradePayoutProjectionContractVersion) or 0) < 1 then return Fail("Authority.TradePayoutProjectionContractVersion_floor") end
    if (tonumber(F.MultiRowQuoteJobsContractVersion) or 0) < 1 then return Fail("MultiRowQuoteJobsContractVersion_floor") end
    if (tonumber(F.QuoteTerminalRefreshContractVersion) or 0) < 2 then return Fail("QuoteTerminalRefreshContractVersion_floor") end
    if (tonumber(F.MaterialPriceCacheContractVersion) or 0) < 1 then return Fail("MaterialPriceCacheContractVersion_floor") end
    if (tonumber(F.BackgroundMaterialRevalidateContractVersion) or 0) < 1 then return Fail("BackgroundMaterialRevalidateContractVersion_floor") end
    if (tonumber(F.EconomicsRevisionContractVersion) or 0) < 1 then return Fail("EconomicsRevisionContractVersion_floor") end
    if (tonumber(F.AutoRefreshBackgroundLeaseContractVersion) or 0) < 2 then return Fail("AutoRefreshBackgroundLeaseContractVersion_floor") end
    if (tonumber(F.AutoRefreshRuntimeContractVersion) or 0) < 1 then return Fail("AutoRefreshRuntimeContractVersion_floor") end
    if (tonumber(F.Authority.AutoRefreshWatchdogContractVersion) or 0) < 3 then return Fail("Authority.AutoRefreshWatchdogContractVersion_floor") end
    if (tonumber(F.Authority.RatioFastPublishContractVersion) or 0) < 2 then return Fail("Authority.RatioFastPublishContractVersion_floor") end
    if (tonumber(F.Authority.RouteRefreshRetryContractVersion) or 0) < 2 then return Fail("Authority.RouteRefreshRetryContractVersion_floor") end
    if (tonumber(F.Authority.SingleFlightLatestRouteContractVersion) or 0) < 1 then return Fail("Authority.SingleFlightLatestRouteContractVersion_floor") end
    if (tonumber(F.Authority.RequestTimeoutContractVersion) or 0) < 1 then return Fail("Authority.RequestTimeoutContractVersion_floor") end
    if type(F.GetFavoriteItems) ~= "function" then return Fail("GetFavoriteItems_missing") end
    if type(F.GetRow) ~= "function" then return Fail("GetRow_missing") end
    if type(F.Commands) ~= "table" then return Fail("commands_table_missing") end
    for _, name in ipairs({ "ToggleCurrentFavorite", "SelectFavorite", "SetSortMode", "SelectRow", "QuoteRowMaterials", "QuotePendingMaterials", "CancelQuoteRowMaterials" }) do
        if type(F.Commands[name]) ~= "function" then return Fail("command." .. name) end
    end
    return true
end, { runtime = true })
