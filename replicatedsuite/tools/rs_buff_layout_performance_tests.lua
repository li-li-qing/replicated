------------------------------------------------------------------------
-- Replicated Suite · Buff 纯布局复用回归
-- 真实 Feature / Renderer / 调度宿主；只替换 Native 图形与游戏事实，不读写玩家存档。
-- 缓存只拥有静态几何，不能缓存位置、图标/时间事实或已接受的 Native 提交结果。
------------------------------------------------------------------------
local passed, failed = 0, 0
local function Test(name, fn)
    local ok, err = xpcall(fn, debug.traceback)
    if ok then passed = passed + 1; print('PASS buff-layout-performance ' .. name)
    else failed = failed + 1; print('FAIL buff-layout-performance ' .. name .. ': ' .. tostring(err)) end
end
local Host = dofile('tools/rs_pvp_hud_test_host.lua')
local function Boot()
    local h, S, F = Host({ runtimeHud = true, noRenderer = true })
    F.State.settings.headShowAll = true
    for _, scope in ipairs({ 'player', 'target' }) do
        for id = 1, 32 do h.facts[scope][id] = h:Fact(id) end
    end
    F:InvalidateSettingsCache(); assert(F:Refresh('layout_test', true))
    dofile('presentation/v3/widgets/rs_v3_buff_head_markers.lua')
    local P = S.UIV3.BuffHeadMarkersV3; assert(P and P.running)
    P:VisualTick()
    return h, S, F, P
end
local function LayoutCalls(P, fn)
    local count, target = 0, P.ComputePlateLayout
    debug.sethook(function() if debug.getinfo(2, 'f').func == target then count = count + 1 end end, 'c')
    local ok, err = pcall(fn)
    debug.sethook()
    assert(ok, err)
    return count
end
Test('unchanged content geometry avoids repeated layout construction', function()
    local _, _, _, P = Boot()
    assert(LayoutCalls(P, function() for _ = 1, 3 do P:VisualTick() end end) == 0,
        'unchanged HUD still constructs pure layout tables')
end)
Test('settings revision rebuilds geometry then resumes reuse', function()
    local _, _, F, P = Boot(); local width = P.pools.player.width
    F.State.settings.plate.width = F.State.settings.plate.width + 100
    F:InvalidateSettingsCache()
    assert(LayoutCalls(P, function() P:VisualTick() end) > 0)
    assert(P.pools.player.width ~= width, 'new geometry did not reach the renderer')
    assert(LayoutCalls(P, function() P:VisualTick() end) == 0)
end)
Test('buff counts and equipment presence invalidate only affected geometry', function()
    local h, _, F, P = Boot()
    h.facts.player = {}; assert(F:RefreshScope('player', true))
    assert(LayoutCalls(P, function() P:VisualTick() end) == 1, 'buff count did not rebuild exactly one scope')
    F.laneData.player.mainHand = { icon = 'new-equipment.dds' }
    P:VisualTick()
    F.laneData.player.mainHand = nil
    assert(LayoutCalls(P, function() P:VisualTick() end) == 1, 'equipment presence did not invalidate geometry')
end)
Test('fresh textures and countdown facts still render with unchanged geometry', function()
    local h, _, F, P = Boot()
    h.facts.player[1].iconPath = 'new-buff-icon.dds'
    h.facts.player[1].timeLeft = 5000
    assert(F:RefreshScope('player', true))
    assert(LayoutCalls(P, function() P:VisualTick() end) == 0)
    assert(P.pools.player.icons[1].icon.texture == 'new-buff-icon.dds')
    assert(P.pools.player.icons[1].time.text == '5.0')
end)
Test('cached geometry retains rejected Native anchor retry', function()
    local h, _, _, P = Boot(); local pool = P.pools.player
    local widget = pool.icons[1].root; local x = widget.x
    widget.x = x + 10; h.rejectAnchor = widget
    assert(LayoutCalls(P, function() P:VisualTick() end) == 0)
    assert(pool.ready == false and not pool.root.shown, 'failed Native geometry was accepted')
    h.rejectAnchor = nil; h.ms = h.ms + 60
    assert(LayoutCalls(P, function() P:MotionTick() end) == 0)
    assert(pool.ready and pool.root.shown and widget.x == x, 'cached geometry swallowed retry')
end)
Test('moving and missing units still update immediately without cached positions', function()
    local h, _, F, P = Boot(); local pool = P.pools.target
    local x, y = pool.root.x, pool.root.y
    h.points.target = { 900, 400, 1 }; F:PositionTick()
    assert(pool.root.x ~= x or pool.root.y ~= y)
    h.points.target = nil; F:PositionTick(); assert(not pool.root.shown)
    h.points.target = { 850, 350, 1 }; F:PositionTick(); assert(pool.root.shown)
end)
Test('public pure layouts stay detached from private renderer geometry', function()
    local _, _, F, P = Boot(); local width = P.pools.player.width
    local settings = F:GetScopeSettingsProjection('player')
    local a = P.ComputePlateLayout(0, 0, settings, 16, 0, {})
    local b = P.ComputePlateLayout(0, 0, settings, 16, 0, {})
    assert(a ~= b and a.bar ~= b.bar)
    a.bar.width, a.buff.size = 99999, 99999
    P:VisualTick(); assert(P.pools.player.width == width)
end)
Test('legacy unknown settings revision keeps uncached behavior', function()
    local _, _, F, P = Boot(); F.settingsRevision = nil
    assert(LayoutCalls(P, function() P:VisualTick() end) > 0)
    assert(LayoutCalls(P, function() P:VisualTick() end) > 0)
end)
Test('stop discards retained layouts before starting again', function()
    local _, _, _, P = Boot(); assert(P:Stop('test'))
    assert(LayoutCalls(P, function() assert(P:Start()) end) > 0)
    assert(LayoutCalls(P, function() P:VisualTick() end) == 0)
end)
print('BUFF LAYOUT PERFORMANCE RESULT ' .. passed .. ' passed / ' .. failed .. ' failed (' .. _VERSION .. ')')
if failed > 0 then error('buff layout performance failures: ' .. failed) end
