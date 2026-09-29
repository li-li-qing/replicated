
------------------------------------------------------------------------
-- Replicated Suite V3 - Trade 详情/收藏契约 Acceptance
--
-- Phase 3 Batch Q（2026-09-29，core-feature-decoupling-1）：本文件承载交易模块的 Feature 侧契约
--（Authority 与自身的多个契约版本下限 + 命令面 + 两个读取函数），原先由
-- core/rs_foundation_gate.lua 的 v3_trade_detail_favorites_contract 直接点名实现表逐条检查；
-- 搬到这里之后 Core 不再认识具体业务 Feature。失败同样是 blocker
--（sequence case 失败 → sequence_harness 检查）。
--
-- 边界：**同一条判定里的 Service / UIV3 契约留在 Foundation**（TradePayoutV3 /
-- MaterialPriceServiceV3 / PriceQuoteQueueV3 / TradeDetailFloatingV3 / LifeM16PagesContract）
-- —— 它们不是 Feature 债。判定与旧版**逐条等价**（下限照搬），外加实现缺失不再静默 return。
--
-- 本文件由脚本从 Foundation 机械生成（避免手抄遗漏），生成后已通过 luac 语法检查。
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local G = S.FoundationGate
if type(G) ~= "table" or type(G.RegisterSequenceCase) ~= "function" then return end
local F = S.Features and S.Features.Trade or nil

local function Fail(message) return false, tostring(message or "trade_acceptance_failed") end

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
end)
