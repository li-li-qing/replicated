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
    ["life.craft_planner"] = { state = "incomplete", incomplete = true },
    ["life.housing"] = { state = "incomplete", incomplete = true },
    ["life.butler"] = { state = "incomplete", incomplete = true },
    ["tools.auction_favorites"] = { state = "incomplete", incomplete = true },
    ["tools.social"] = { state = "incomplete", incomplete = true },
    ["tools.craft_assist"] = { state = "incomplete", incomplete = true },
}

local byRoute = {}
for _, row in pairs(R.features or {}) do
    byRoute[row.route] = row
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
