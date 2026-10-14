------------------------------------------------------------------------
-- Replicated Suite · 行情分析契约验收
-- 作者：Replicated
-- QQ群：1104129461
--
-- 仅验证行情分析Feature自身契约，保留所有逐项下限；缺实现不得静默返回，失败为blocker。
-- 同一判定中的AuctionQueryV3服务契约仍归Foundation，Core不直接依赖此Feature实现表。
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local G = S.FoundationGate
if type(G) ~= "table" or type(G.RegisterSequenceCase) ~= "function" then return end
local F = S.Features and S.Features.tools_market_analysis or nil

local function Fail(message) return false, tostring(message or "market_analysis_acceptance_failed") end

-- 显式接回只读运行时诊断；完整序列仍保留给离线验收。
G:RegisterSequenceCase("v3_tools_market_analysis_contract", function()
    if type(F) ~= "table" then return Fail("implementation_not_registered") end
    if (tonumber(F.AuctionQueryContractVersion) or 0) < 1 then return Fail("auction_query_contract_version") end
    if type(F.Commands) ~= "table" or type(F.Commands.Search) ~= "function" then return Fail("market_search_command") end
    return true
end, { runtime = true })
