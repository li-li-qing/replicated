------------------------------------------------------------------------
-- Replicated Suite V3 - tools_auction Contract Acceptance
--
-- Phase 3 Batch I（2026-09-29，core-feature-decoupling-1）：本文件承载拍卖模块的 Feature 侧契约。
-- 它们原先由 core/rs_foundation_gate.lua 的三个 AddCheck（v3_auction_query_contract /
-- v3_auction_sidecar_contract / v3_auction_workspace_contract）直接点名实现表检查；
-- 搬到这里之后 Core 不再认识具体业务 Feature。失败同样是 blocker
-- （sequence case 失败 → sequence_harness 检查）。
--
-- 边界：**同一条 AddCheck 里的 Service / UIV3 契约留在 Foundation**（AuctionQueryV3 /
-- AuctionSurfaceV3 / AuctionSidecar / AuctionSessionListV3 / DailyAuctionMaterialsV3 /
-- QuestProgressV3 —— 它们不是 Feature 债）。本文件只承载“这个 Feature 自己必须提供什么”。
-- 判定与旧版**逐条等价**（下限照搬），外加“实现缺失不再静默 return”。
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local G = S.FoundationGate
if type(G) ~= "table" or type(G.RegisterSequenceCase) ~= "function" then return end
local F = S.Features and S.Features.tools_auction or nil

local function Fail(message) return false, tostring(message or "auction_acceptance_failed") end

G:RegisterSequenceCase("v3_tools_auction_contract", function()
    if type(F) ~= "table" then return Fail("implementation_not_registered") end
    -- v3_auction_query_contract 的 Feature 侧
    if (tonumber(F.AuctionQueryContractVersion) or 0) < 1 then return Fail("auction_query_contract_version") end
    if type(F.Commands) ~= "table" or type(F.Commands.Search) ~= "function" then return Fail("auction_search_command") end
    -- v3_auction_sidecar_contract 的 Feature 侧
    if (tonumber(F.SidecarPreferenceContractVersion) or 0) < 1 then return Fail("sidecar_preference_contract_version") end
    if type(F.IsSidecarEnabled) ~= "function" then return Fail("sidecar_enabled_reader") end
    if type(F.Commands.SetSidecarEnabled) ~= "function" then return Fail("sidecar_enabled_command") end
    -- v3_auction_workspace_contract 的 Feature 侧（收藏 CRUD）
    for _, name in ipairs({ "RenameFavorite", "MoveFavorite", "RemoveFavoriteByKeyword", "ClearFavorites" }) do
        if type(F.Commands[name]) ~= "function" then return Fail("favorites_command:" .. name) end
    end
    return true
end)
