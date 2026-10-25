-- Replicated Suite · 拍卖助手契约验收
-- 作者：Replicated
-- QQ群：1104129461
-- 验证拍卖Feature自身查询、Sidecar和工作区接口，保留所有版本下限；实现缺失不得静默返回，失败为blocker，由sequence_harness报告。
-- AuctionQueryV3、AuctionSurfaceV3、AuctionSidecar、AuctionSessionListV3、DailyAuctionMaterialsV3、QuestProgressV3等Service/UI契约仍归Foundation。
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local G = S.FoundationGate
if type(G) ~= "table" or type(G.RegisterSequenceCase) ~= "function" then return end
local F = S.Features and S.Features.tools_auction or nil

local function Fail(message) return false, tostring(message or "auction_acceptance_failed") end

-- 运行时只做只读诊断；完整序列测试仅离线执行。
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
end, { runtime = true })
