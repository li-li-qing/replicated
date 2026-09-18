------------------------------------------------------------------------
-- Replicated Suite - user acceptance navigation status regression
--
-- 维护说明（2026-09-13）：导航开发态必须以用户实机验收为准，不能因为离线实现或 API 完整度
-- 自动上移。此测试只验证 Presentation 元数据，不得影响 FeatureRuntime/Persistence/Authority。
------------------------------------------------------------------------
ReplicatedSuite = { BootError = nil }
dofile("features/rs_feature_registry.lua")
local R = assert(ReplicatedSuite.FeatureRegistry, "FeatureRegistry missing")

local expected = {
    ["combat.buff_display"] = { state = "complete", incomplete = false },
    ["life.activities"] = { state = "complete", incomplete = false },
    ["life.trade"] = { state = "complete", incomplete = false },
    ["life.bonds"] = { state = "complete", incomplete = false },
    ["life.fishing"] = { state = "complete", incomplete = false },
    ["life.housing"] = { state = "incomplete", incomplete = true },
    ["life.butler"] = { state = "incomplete", incomplete = true },
    -- 中文维护注释（2026-09-15）：用户已实机确认拍卖收藏进入完成区；该路由仍可能保留
    -- 原生搜索框“增强同步”的可选验证，但直接 AuctionQuery/收藏/Sidecar/独立开关均已形成产品闭环。
    ["tools.auction_favorites"] = { state = "complete", incomplete = false },
    ["tools.social"] = { state = "incomplete", incomplete = true },
    ["tools.craft_assist"] = { state = "incomplete", incomplete = true },
}

local byRoute = {}
for _, row in pairs(R.features or {}) do
    byRoute[row.route] = row
end

assert(byRoute["life.craft_planner"] == nil, "制作规划已按用户要求删除，不应继续出现在 Registry/导航")


local hiddenRoutes = {
    ["tools.market_analysis"] = true,
    ["tools.craft_assist"] = true,
    ["tools.social"] = true,
    ["life.housing"] = true,
}
for route in pairs(hiddenRoutes) do
    local row = assert(byRoute[route], "missing hidden route: " .. route)
    assert(row.navigationVisible == false, route .. " must be removed from main navigation")
end

local checked = 0
for route, want in pairs(expected) do
    local row = assert(byRoute[route], "missing route: " .. route)
    assert(row.navigationDevelopmentState == want.state,
        route .. " state expected " .. want.state .. " got " .. tostring(row.navigationDevelopmentState))
    assert(row.navigationIncomplete == want.incomplete,
        route .. " navigationIncomplete expected " .. tostring(want.incomplete) .. " got " .. tostring(row.navigationIncomplete))
    checked = checked + 1
end

print("NAVIGATION_STATUS_ACCEPTANCE PASS: " .. tostring(checked) .. " user-accepted route states")
