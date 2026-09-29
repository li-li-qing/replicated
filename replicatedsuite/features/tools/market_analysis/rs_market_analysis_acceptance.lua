------------------------------------------------------------------------
-- Replicated Suite V3 - tools_market_analysis Contract Acceptance
--
-- Phase 3 Batch I（2026-09-29，core-feature-decoupling-1）：本文件承载行情分析模块的 Feature 侧契约
-- （原先由 core/rs_foundation_gate.lua 的 v3_auction_query_contract 直接点名实现表检查）。
-- 搬到这里之后 Core 不再认识具体业务 Feature。失败同样是 blocker。
--
-- 边界：同一判定里的 AuctionQueryV3 Service 契约留在 Foundation；本文件只管本 Feature 自己。
-- 判定与旧版**逐条等价**，外加“实现缺失不再静默 return”。
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local G = S.FoundationGate
if type(G) ~= "table" or type(G.RegisterSequenceCase) ~= "function" then return end
local F = S.Features and S.Features.tools_market_analysis or nil

local function Fail(message) return false, tostring(message or "market_analysis_acceptance_failed") end

G:RegisterSequenceCase("v3_tools_market_analysis_contract", function()
    if type(F) ~= "table" then return Fail("implementation_not_registered") end
    if (tonumber(F.AuctionQueryContractVersion) or 0) < 1 then return Fail("auction_query_contract_version") end
    if type(F.Commands) ~= "table" or type(F.Commands.Search) ~= "function" then return Fail("market_search_command") end
    return true
end)
