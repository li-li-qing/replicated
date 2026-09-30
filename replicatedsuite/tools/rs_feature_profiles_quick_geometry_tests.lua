-- 中文维护（2026-09-25，feature-profile-quick-relog-1）：
-- 功能方案屏幕快捷按钮的 viewport/重登几何离线回归。
-- 真实被测代码：Api -> Layout -> RSUI.Windowing -> FeatureProfile Feature -> FeatureProfile Quick Widget。
-- 只有 Native 叶节点、事件总线、Scheduler 与磁盘是替身；不进入 toc.g，失败不得标记为 RU 实机通过。
-- 运行：cd replicatedsuite && lua tools/rs_feature_profiles_quick_geometry_tests.lua
local BootHost = dofile('tools/rs_window_viewport_test_host.lua')
_G.unpack = _G.unpack or table.unpack -- Lua 5.4 宿主兼容；游戏客户端为 5.1。

local pass, fail = 0, 0
local function Test(name, fn)
    local ok, err = xpcall(fn, debug.traceback)
    if ok then pass = pass + 1; print('PASS quick-geometry ' .. name)
    else fail = fail + 1; print('FAIL quick-geometry ' .. name .. ': ' .. tostring(err)) end
end
local function Eq(a, b, msg)
    if tonumber(a) ~= nil and tonumber(b) ~= nil then
        assert(math.abs(tonumber(a) - tonumber(b)) < 0.01, (msg or 'not equal') .. ': ' .. tostring(a) .. ' / ' .. tostring(b))
        return
    end
    assert(a == b, (msg or 'not equal') .. ': ' .. tostring(a) .. ' / ' .. tostring(b))
end
local function Truth(v, msg) assert(v == true, (msg or 'assert true') .. ': ' .. tostring(v)) end

local function DeepCopy(value, seen)
    if type(value) ~= 'table' then return value end
    seen = seen or {}; if seen[value] then return seen[value] end
    local out = {}; seen[value] = out
    for k, v in pairs(value) do out[DeepCopy(k, seen)] = DeepCopy(v, seen) end
    return out
end
local function Snap(value)
    if type(value) ~= 'table' then return tostring(value) end
    local keys = {}; for k in pairs(value) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    local parts = {}; for _, k in ipairs(keys) do parts[#parts + 1] = tostring(k) .. '=' .. Snap(value[k]) end
    return '{' .. table.concat(parts, ';') .. '}'
end

local PROFILES = {
    { id = 1, name = '塔塔开' },
    { id = 2, name = '塔塔关' },
    { id = 3, name = 'One Piece' },
}
local STORE_ID = 'v3.business.tools_feature_profiles'

local metas = {
    { id = 'tools_feature_profiles', route = 'tools.feature_profiles', name = '功能方案', category = 'tools', lifecycle = 'independent', controlFeatureId = 'tools_feature_profiles', defaultEnabled = true },
    { id = 'life_trade', route = 'life.trade', name = '跑商', category = 'life', lifecycle = 'independent', controlFeatureId = 'life_trade', defaultEnabled = false },
    { id = 'combat_range_assist', route = 'combat.range_assist', name = '范围辅助', category = 'combat', lifecycle = 'independent', controlFeatureId = 'combat_range_assist', defaultEnabled = false },
}
local metaById = {}
for _, meta in ipairs(metas) do metaById[meta.id] = meta end

local function NewSuite(options)
    options = options or {}
    local h = BootHost()
    local S = h.S
    S.Utils = { DeepCopy = DeepCopy }
    S.NowMs = function() return 1000 end
    local diagnostics = { warnings = {}, errors = {} }
    S.DiagnosticsManager = {
        Emit = function() end, Error = function() end,
        ErrorRateLimited = function(_, source, code) diagnostics.errors[#diagnostics.errors + 1] = code end,
        WarningRateLimited = function(_, source, code) diagnostics.warnings[#diagnostics.warnings + 1] = code end,
    }
    S.Features = {}

    local listeners = {}
    S.Events = {
        SubscribeInternal = function(_, topic, owner, cb)
            listeners[topic] = listeners[topic] or {}
            table.insert(listeners[topic], { owner = owner, cb = cb }); return true
        end,
        UnsubscribeInternalOwner = function(_, owner)
            for _, rows in pairs(listeners) do
                for i = #rows, 1, -1 do if rows[i].owner == owner then table.remove(rows, i) end end
            end
            return true
        end,
        SubscribeOptional = function() return true end,
        UnsubscribeOwner = function() return true end,
        Publish = function(_, topic, ...)
            local rows = {}; for _, row in ipairs(listeners[topic] or {}) do rows[#rows + 1] = row end
            for _, row in ipairs(rows) do row.cb(row.owner, ...) end
            return true
        end,
    }

    S.FeatureRegistry = { categories = { life = { name = '生活' }, combat = { name = '战斗' }, tools = { name = '工具' } } }
    function S.FeatureRegistry:Get(id) return metaById[id] end
    function S.FeatureRegistry:List() return metas end

    S.Persistence = {
        Scope = { Account = 'account' }, Lifetime = { Permanent = 'permanent' }, V3KeyPrefix = 'replicated_suite_v1_v3_',
        stores = {}, disk = DeepCopy(options.disk or {}), writes = 0,
    }
    local P = S.Persistence
    function P:GetStore(id) return self.stores[id] end
    function P:RegisterV3Store(spec) self.stores[spec.id] = spec; return spec end
    function P:LoadStore(id)
        local spec = self.stores[id]; if spec == nil then return false, nil, 'missing' end
        if self.disk[id] ~= nil then spec.apply(DeepCopy(self.disk[id])); return true end
        local default = type(spec.default) == 'function' and spec.default() or {}
        spec.apply(DeepCopy(default)); self.disk[id] = DeepCopy(default); return 'empty'
    end
    function P:CanWrite(id) return self.stores[id] ~= nil end
    function P:MutateStore(id, mutator)
        local spec = self.stores[id]; if spec == nil then return false, 'missing' end
        local before = DeepCopy(spec.get())
        local ok, a, b = pcall(mutator)
        if not ok or a == false then spec.apply(before); return false, ok and b or a end
        self.writes = self.writes + 1
        self.disk[id] = DeepCopy(spec.get())
        return true, b
    end

    S.Demand = { leases = {} }
    function S.Demand:Create(spec)
        local lease = { id = spec.id, owner = spec.owner, spec = spec, count = 0, tokens = {} }
        function lease:_apply(nextCount)
            local before = { count = self.count }; local after = { count = nextCount }
            if type(self.spec.reconcile) == 'function' then
                local ok, err = self.spec.reconcile(self, before, after); if ok == false then return false, err end
            end
            self.count = nextCount; return true
        end
        function lease:Acquire(token) if self.tokens[token] then return true end; local ok, err = self:_apply(self.count + 1); if ok ~= true then return false, err end; self.tokens[token] = true; return true end
        function lease:Release(token) if not self.tokens[token] then return true end; local ok, err = self:_apply(math.max(0, self.count - 1)); if ok ~= true then return false, err end; self.tokens[token] = nil; return true end
        function lease:Clear() local ok, err = self:_apply(0); if ok ~= true then return false, err end; self.tokens = {}; return true end
        self.leases[spec.id] = lease; return lease
    end
    function S.Demand:Get(id) return self.leases[id] end

    local UI = S.UI
    function UI:CreateButton(parent, id, text, x, y, w, hh)
        local node = h.Native(parent, id, x, y, w, hh)
        node.text = tostring(text or '')
        node:SetExtent(w, hh)
        node:AddAnchor('TOPLEFT', UIParent, x, y)
        self:EnsureExtent(node, w, hh)
        self:EnsureAnchor(node, UIParent, x, y)
        self:EnsureVisible(node, true)
        return node
    end
    function UI:SetText(node, text) node.text = text; return true end
    function UI:SetButtonActive(node, active) node.active = active; return true end
    function UI:RegisterScreenSnap(id, widget, snapOptions) return S.Layout:RegisterScreenSnap(id, widget, snapOptions) end
    function UI:UnregisterScreenSnap(id) return S.Layout:UnregisterScreenSnap(id) end

    dofile('features/rs_feature_runtime.lua')
    local Runtime = S.FeatureRuntime
    for _, id in ipairs({ 'life_trade', 'combat_range_assist' }) do
        local impl = { enabled = false }
        function impl:Initialize() return true end
        function impl:Enable() self.enabled = true; return true end
        function impl:Disable() self.enabled = false; return true end
        assert(Runtime:RegisterImplementation(id, impl))
    end

    dofile('features/tools/rs_feature_profiles_feature.lua')

    local widgetSpec, widgetVisible = nil, false
    S.UIV3 = S.UIV3 or {}
    S.UIV3.WidgetHost = {
        Register = function(_, _, spec) widgetSpec = spec; return true end,
        IsVisible = function() return widgetVisible end,
        SetVisible = function(_, _, visible)
            widgetVisible = visible == true
            local instance = S.UIV3.WidgetHost._instance
            if instance == nil then instance = widgetSpec.create(); S.UIV3.WidgetHost._instance = instance end
            if widgetVisible then return instance:Show() end
            return instance:Hide()
        end,
        NotifyProjectionChanged = function() local instance = S.UIV3.WidgetHost._instance; if instance then return instance:Refresh() end; return true end,
        BindFeatureLifecycle = function() return true end,
        ApplyResponsiveLayout = function(_, fromMetrics)
            local instance = S.UIV3.WidgetHost._instance
            if instance ~= nil and widgetVisible == true and type(instance.ApplyLayout) == 'function' then
                return instance:ApplyLayout(fromMetrics == true)
            end
            return true
        end,
    }
    S.UIHostManager = {
        ApplyResponsiveLayout = function(_, fromMetrics) return S.UIV3.WidgetHost:ApplyResponsiveLayout(fromMetrics) end,
    }

    dofile('presentation/v3/widgets/rs_v3_feature_profiles_widget.lua')
    return { h = h, S = S, Runtime = Runtime, spec = widgetSpec, diagnostics = diagnostics }
end

local function SeedStore(placements)
    local store = { profiles = {}, nextId = #placements + 1, selectedId = 1 }
    for index, profile in ipairs(PROFILES) do
        local row = { id = profile.id, name = profile.name, modules = {}, quick = true }
        local placement = placements and placements[profile.id]
        if placement ~= nil then for key, value in pairs(placement) do row[key] = value end end
        store.profiles[index] = row
    end
    return { [STORE_ID] = store }
end

-- 记录 “用户真实拖动” 的结果：与 Widget OnDragStop 完全相同的提交边界。
local function CommitDrag(ctx, profileId, x, y)
    local S = ctx.S
    local instance = ctx.S.UIV3.WidgetHost._instance
    local record = assert(instance.buttons[tostring(profileId)], 'button not created for profile ' .. tostring(profileId))
    local width = record.button.w
    local height = record.button.h
    record.button.handlers.OnDragStart()
    record.button.x, record.button.y = x, y
    record.button.handlers.OnDragStop()
    return record, width, height
end

local function PlaceAll(ctx, targets)
    local ordered = {}
    for index, profile in ipairs(PROFILES) do
        local target = targets[profile.id]
        local record = CommitDrag(ctx, profile.id, target[1], target[2])
        ordered[index] = record
    end
    return ordered
end

local function BootSession(disk, viewport)
    local ctx = NewSuite({ disk = disk })
    ctx.h:Viewport(viewport[1], viewport[2], viewport[3], viewport[4], viewport[5])
    ctx.S.Layout:Invalidate()
    ctx.S.Layout:PrimeCurrentSignature()
    assert(ctx.Runtime:Enable('tools_feature_profiles', 'quick_geometry_test'))
    -- 新用户流程：先在页面里创建方案，再由 Host 显示快捷按钮。
    local feature = ctx.S.Features.FeatureProfiles
    if #(feature.State.profiles or {}) == 0 then
        for _, profile in ipairs(PROFILES) do assert(feature.Commands:CreateProfile(profile.name)) end
    end
    assert(ctx.S.UIV3.WidgetHost:SetVisible('tools.feature_profiles.quick', true), 'quick widget did not show')
    return ctx
end

local function Records(ctx)
    local instance = ctx.S.UIV3.WidgetHost._instance
    local rows = {}
    for _, profile in ipairs(PROFILES) do
        local record = assert(instance.buttons[tostring(profile.id)], 'missing button ' .. tostring(profile.id))
        rows[#rows + 1] = { id = profile.id, name = profile.name, record = record,
            x = record.button.x, y = record.button.y, w = record.button.w, h = record.button.h,
            visible = record.button.visible == true }
    end
    return rows
end

local function AssertNoOverlap(rows, label)
    for i = 1, #rows do
        for j = i + 1, #rows do
            local a, b = rows[i], rows[j]
            local overlap = a.x < b.x + b.w and b.x < a.x + a.w and a.y < b.y + b.h and b.y < a.y + a.h
            assert(overlap ~= true, string.format('%s: buttons overlap %s(%s,%s) / %s(%s,%s)',
                label or 'overlap', tostring(a.id), tostring(a.x), tostring(a.y), tostring(b.id), tostring(b.x), tostring(b.y)))
        end
    end
end

local function AssertFullyVisible(ctx, rows, label)
    local context = ctx.S.Layout:GetContext()
    for _, row in ipairs(rows) do
        assert(row.visible == true, (label or 'visible') .. ': button ' .. tostring(row.id) .. ' was hidden')
        assert(row.x >= context.safeLeft - 0.01 and row.y >= context.safeTop - 0.01
            and row.x + row.w <= context.logicalWidth - context.safeRight + 0.01
            and row.y + row.h <= context.logicalHeight - context.safeBottom + 0.01,
            string.format('%s: button %s outside viewport %.2f,%.2f %.2fx%.2f in %.2fx%.2f',
                label or 'visible', tostring(row.id), row.x, row.y, row.w, row.h, context.logicalWidth, context.logicalHeight))
    end
end

local function SnapshotPlacements(rows)
    local out = {}
    for _, row in ipairs(rows) do out[#out + 1] = string.format('%s@%.3f,%.3f', tostring(row.id), row.x, row.y) end
    return table.concat(out, '|')
end

----------------------------------------------------------------------
-- A. 同 viewport 重登：三个位置精确恢复、全部可见、不重叠
----------------------------------------------------------------------
Test('A same-viewport relog restores exact positions (3 buttons, visible, no overlap)', function()
    local first = BootSession(nil, { 1920, 1080 })
    PlaceAll(first, { [1] = { 1180, 150 }, [2] = { 1290, 150 }, [3] = { 1500, 150 } })
    local saved = SnapshotPlacements(Records(first))
    local disk = DeepCopy(first.S.Persistence.disk)
    assert(disk[STORE_ID] ~= nil, 'store was not written by real drag')

    local second = BootSession(disk, { 1920, 1080 })
    local rows = Records(second)
    AssertFullyVisible(second, rows, 'A')
    AssertNoOverlap(rows, 'A')
    Eq(SnapshotPlacements(rows), saved, 'A: same-viewport restore drifted')
    Eq(second.S.Persistence.writes, 0, 'A: restore wrote the Store')
end)

----------------------------------------------------------------------
-- B. 1920 保存 -> 较窄 viewport 恢复：全部留在 safe viewport 且不重叠
----------------------------------------------------------------------
Test('B wide save restored into narrower viewport stays fully visible and separated', function()
    local first = BootSession(nil, { 1920, 1080 })
    PlaceAll(first, { [1] = { 1180, 150 }, [2] = { 1290, 150 }, [3] = { 1500, 150 } })
    local savedRows = Records(first)
    local disk = DeepCopy(first.S.Persistence.disk)

    local narrow = BootSession(disk, { 1280, 720 })
    local rows = Records(narrow)
    AssertFullyVisible(narrow, rows, 'B')
    AssertNoOverlap(rows, 'B')
    Eq(narrow.S.Persistence.writes, 0, 'B: reprojection wrote the Store')

    -- 回到原 viewport 必须逐像素回到保存位置（无累计漂移）
    narrow.h:Viewport(1920, 1080)
    narrow.S.Layout:PollChanges()
    local restored = Records(narrow)
    for index = 1, #savedRows do
        Eq(restored[index].x, savedRows[index].x, 'B: x' .. index .. ' not restored')
        Eq(restored[index].y, savedRows[index].y, 'B: y' .. index .. ' not restored')
    end
    Eq(narrow.S.Persistence.writes, 0, 'B: reflow wrote the Store')
end)

----------------------------------------------------------------------
-- C. 启动期临时 1024x768 -> 稍后静默稳定到最终 viewport，Store write = 0
----------------------------------------------------------------------
Test('C startup temporary viewport settles into final viewport with zero Store writes', function()
    local first = BootSession(nil, { 1920, 1080 })
    PlaceAll(first, { [1] = { 1180, 150 }, [2] = { 1290, 150 }, [3] = { 1500, 150 } })
    local savedRows = Records(first)
    local disk = DeepCopy(first.S.Persistence.disk)

    local relog = NewSuite({ disk = disk })
    relog.h:Viewport(1024, 768)
    relog.S.Layout:Invalidate()
    relog.S.Layout:PrimeCurrentSignature()
    assert(relog.Runtime:Enable('tools_feature_profiles', 'temporary_viewport'))
    relog.S.Layout:StartMetricsEvents()
    assert(relog.S.UIV3.WidgetHost:SetVisible('tools.feature_profiles.quick', true))
    local temporary = Records(relog)
    assert(math.abs(temporary[3].x - savedRows[3].x) > 0.5, 'C: fixture did not produce a temporary projection')

    relog.h:Viewport(1920, 1080)
    local drains = 0
    while next(relog.h.tasks) ~= nil and drains < 20 do relog.h:Drain(); drains = drains + 1 end
    local rows = Records(relog)
    AssertFullyVisible(relog, rows, 'C')
    for index = 1, #savedRows do
        Eq(rows[index].x, savedRows[index].x, 'C: x' .. index)
        Eq(rows[index].y, savedRows[index].y, 'C: y' .. index)
    end
    Eq(relog.S.Persistence.writes, 0, 'C: metrics-only recovery wrote the Store')
end)

----------------------------------------------------------------------
-- D. 靠近右边缘保存后重登
----------------------------------------------------------------------
Test('D button saved at the right edge survives relog and stays inside', function()
    local first = BootSession(nil, { 1920, 1080 })
    PlaceAll(first, { [1] = { 1800, 180 }, [2] = { 1800, 220 }, [3] = { 1800, 260 } })
    local disk = DeepCopy(first.S.Persistence.disk)
    local saved = SnapshotPlacements(Records(first))

    local second = BootSession(disk, { 1920, 1080 })
    local rows = Records(second)
    AssertFullyVisible(second, rows, 'D')
    AssertNoOverlap(rows, 'D')
    Eq(SnapshotPlacements(rows), saved, 'D: right-edge relog drifted')
end)

----------------------------------------------------------------------
-- E. LEFT / RIGHT 混合历史 edge placement
----------------------------------------------------------------------
Test('E mixed LEFT and RIGHT legacy edge placements restore contained and separated', function()
    -- 手工构造历史 Store：1 号 LEFT/TOP，2 号 RIGHT/TOP，3 号 RIGHT/BOTTOM（无 viewport intent）
    local disk = SeedStore({
        [1] = { quickPositionCustomized = true, quickX = 200, quickY = 160,
            quickCoordinateSpace = 'logical-edge-v1', quickAnchorH = 'LEFT', quickAnchorV = 'TOP', quickOffsetX = 188, quickOffsetY = 148 },
        [2] = { quickPositionCustomized = true, quickX = 1600, quickY = 160,
            quickCoordinateSpace = 'logical-edge-v1', quickAnchorH = 'RIGHT', quickAnchorV = 'TOP', quickOffsetX = 204, quickOffsetY = 148 },
        [3] = { quickPositionCustomized = true, quickX = 1600, quickY = 900,
            quickCoordinateSpace = 'logical-edge-v1', quickAnchorH = 'RIGHT', quickAnchorV = 'BOTTOM', quickOffsetX = 204, quickOffsetY = 142 },
    })
    local ctx = BootSession(disk, { 1920, 1080 })
    local rows = Records(ctx)
    AssertFullyVisible(ctx, rows, 'E')
    AssertNoOverlap(rows, 'E')
    Eq(rows[1].x, 200, 'E: LEFT anchor x'); Eq(rows[1].y, 160, 'E: TOP anchor y')
    Eq(rows[2].x, 1600, 'E: RIGHT anchor x'); Eq(rows[3].y, 900, 'E: BOTTOM anchor y')
    Eq(ctx.S.Persistence.writes, 0, 'E: legacy edge projection wrote the Store')
end)

----------------------------------------------------------------------
-- F. restore -> metrics change -> restore -> metrics change 不产生累计漂移
----------------------------------------------------------------------
Test('F repeated restore and metrics changes never accumulate drift', function()
    local first = BootSession(nil, { 1920, 1080 })
    PlaceAll(first, { [1] = { 1180, 150 }, [2] = { 1290, 150 }, [3] = { 1500, 150 } })
    local disk = DeepCopy(first.S.Persistence.disk)
    local baseline = nil

    for round = 1, 5 do
        local ctx = BootSession(disk, { 1920, 1080 })
        local rows = Records(ctx)
        local snapshot = SnapshotPlacements(rows)
        if baseline == nil then baseline = snapshot else Eq(snapshot, baseline, 'F: round ' .. round .. ' restore drifted') end
        AssertFullyVisible(ctx, rows, 'F'); AssertNoOverlap(rows, 'F')
        for _, viewport in ipairs({ { 1366, 768 }, { 2560, 1440 }, { 1280, 720 } }) do
            ctx.h:Viewport(viewport[1], viewport[2])
            ctx.S.Layout:PollChanges()
            local live = Records(ctx)
            AssertFullyVisible(ctx, live, 'F'); AssertNoOverlap(live, 'F')
        end
        ctx.h:Viewport(1920, 1080)
        ctx.S.Layout:PollChanges()
        Eq(SnapshotPlacements(Records(ctx)), baseline, 'F: round ' .. round .. ' final projection drifted')
        Eq(ctx.S.Persistence.writes, 0, 'F: metrics reflow wrote the Store')
    end
end)

----------------------------------------------------------------------
-- G. 旧 quickX/quickY（无 edge、无 viewport intent）仍可恢复
----------------------------------------------------------------------
Test('G legacy quickX/quickY rows still restore exactly on the same viewport', function()
    local disk = SeedStore({
        [1] = { quickPositionCustomized = true, quickX = 320, quickY = 190 },
        [2] = { quickPositionCustomized = true, quickX = 432, quickY = 190 },
        [3] = { quickPositionCustomized = true, quickX = 544, quickY = 190 },
    })
    local ctx = BootSession(disk, { 1920, 1080 })
    local rows = Records(ctx)
    Eq(rows[1].x, 320, 'G: x1'); Eq(rows[2].x, 432, 'G: x2'); Eq(rows[3].x, 544, 'G: x3'); Eq(rows[1].y, 190, 'G: y1')
    AssertFullyVisible(ctx, rows, 'G'); AssertNoOverlap(rows, 'G')
    Eq(ctx.S.Persistence.writes, 0, 'G: legacy absolute projection wrote the Store')
    -- 加载期不得把旧配置升级成新格式
    local stored = ctx.S.Persistence.disk[STORE_ID].profiles[1]
    Eq(stored.quickSavedLogicalWidth, nil, 'G: startup upgraded legacy placement format')
end)

----------------------------------------------------------------------
-- H. 旧 logical-edge-v1（无 viewport intent）仍可恢复
----------------------------------------------------------------------
Test('H legacy logical-edge-v1 rows still restore without format upgrade', function()
    local disk = SeedStore({
        [1] = { quickPositionCustomized = true, quickX = 700, quickY = 300,
            quickCoordinateSpace = 'logical-edge-v1', quickAnchorH = 'LEFT', quickAnchorV = 'TOP', quickOffsetX = 688, quickOffsetY = 288 },
        [2] = { quickPositionCustomized = true, quickX = 810, quickY = 300,
            quickCoordinateSpace = 'logical-edge-v1', quickAnchorH = 'LEFT', quickAnchorV = 'TOP', quickOffsetX = 798, quickOffsetY = 288 },
        [3] = { quickPositionCustomized = true, quickX = 920, quickY = 300,
            quickCoordinateSpace = 'logical-edge-v1', quickAnchorH = 'LEFT', quickAnchorV = 'TOP', quickOffsetX = 908, quickOffsetY = 288 },
    })
    local ctx = BootSession(disk, { 1920, 1080 })
    local rows = Records(ctx)
    Eq(rows[1].x, 700, 'H: x1'); Eq(rows[3].x, 920, 'H: x3'); Eq(rows[2].y, 300, 'H: y2')
    AssertFullyVisible(ctx, rows, 'H'); AssertNoOverlap(rows, 'H')
    local stored = ctx.S.Persistence.disk[STORE_ID].profiles[3]
    Eq(stored.quickSavedLogicalWidth, nil, 'H: startup upgraded legacy edge format')
    Eq(ctx.S.Persistence.writes, 0, 'H: legacy edge projection wrote the Store')
end)

----------------------------------------------------------------------
-- I. 位置恢复不得改变 quick 状态
----------------------------------------------------------------------
Test('I placement restore never changes profile quick state or row count', function()
    local first = BootSession(nil, { 1920, 1080 })
    PlaceAll(first, { [1] = { 1180, 150 }, [2] = { 1290, 150 }, [3] = { 1500, 150 } })
    local disk = DeepCopy(first.S.Persistence.disk)

    local second = BootSession(disk, { 1366, 768 })
    local feature = second.S.Features.FeatureProfiles
    local rows = feature:GetQuickRows()
    Eq(#rows, 3, 'I: quick row count changed')
    for _, row in ipairs(rows) do
        Truth(row.quick == true, 'I: quick state changed for ' .. tostring(row.name))
        Truth(row.quickPositionCustomized == true, 'I: customized flag lost for ' .. tostring(row.name))
    end
    AssertFullyVisible(second, Records(second), 'I')
    -- 投影过程不得改写 Store 内容
    local before = Snap(disk[STORE_ID])
    second.h:Viewport(1920, 1080); second.S.Layout:PollChanges()
    Eq(Snap(second.S.Persistence.disk[STORE_ID]), before, 'I: metrics reflow mutated stored profiles')
end)

----------------------------------------------------------------------
-- J. 碰撞恢复：多个按钮被压到同一矩形时必须分离（不得完全覆盖）
----------------------------------------------------------------------
Test('J identical resolved rects are separated instead of stacking', function()
    -- 历史 edge 行给出同一组锚点：三个按钮 ResolvePlacement 会得到完全相同的矩形。
    local disk = SeedStore({
        [1] = { quickPositionCustomized = true, quickX = 1500, quickY = 600,
            quickCoordinateSpace = 'logical-edge-v1', quickAnchorH = 'RIGHT', quickAnchorV = 'BOTTOM', quickOffsetX = 304, quickOffsetY = 568 },
        [2] = { quickPositionCustomized = true, quickX = 1500, quickY = 600,
            quickCoordinateSpace = 'logical-edge-v1', quickAnchorH = 'RIGHT', quickAnchorV = 'BOTTOM', quickOffsetX = 304, quickOffsetY = 568 },
        [3] = { quickPositionCustomized = true, quickX = 1500, quickY = 600,
            quickCoordinateSpace = 'logical-edge-v1', quickAnchorH = 'RIGHT', quickAnchorV = 'BOTTOM', quickOffsetX = 304, quickOffsetY = 568 },
    })
    local ctx = BootSession(disk, { 1920, 1080 })
    local rows = Records(ctx)
    AssertFullyVisible(ctx, rows, 'J')
    AssertNoOverlap(rows, 'J')
    local deoverlap = ctx.S.Layout:GetScreenDeoverlapSnapshot()
    assert((tonumber(deoverlap.adjusted) or 0) >= 2, 'J: de-overlap solver did not run')
    Eq(ctx.S.Persistence.writes, 0, 'J: de-overlap recovery wrote the Store')
end)

----------------------------------------------------------------------
-- K. 原生几何被拒绝时 fail-soft：按钮仍可见、widget 仍可被重排，随后可自愈
--    （根因回归：旧实现会隐藏按钮 + 整体 Show 失败 -> WidgetHost 把 widget 移出重排名单）
----------------------------------------------------------------------
Test('K native geometry rejection keeps buttons visible, reflowable and self-healing', function()
    local first = BootSession(nil, { 1920, 1080 })
    PlaceAll(first, { [1] = { 1180, 150 }, [2] = { 1290, 150 }, [3] = { 1500, 150 } })
    local disk = DeepCopy(first.S.Persistence.disk)
    local baseline = SnapshotPlacements(Records(first))

    local ctx = NewSuite({ disk = disk })
    ctx.h:Viewport(1920, 1080)
    ctx.S.Layout:Invalidate(); ctx.S.Layout:PrimeCurrentSignature()
    ctx.h.rejectAnchor = true
    assert(ctx.Runtime:Enable('tools_feature_profiles', 'rejection_test'))
    local shown = ctx.S.UIV3.WidgetHost:SetVisible('tools.feature_profiles.quick', true)
    Truth(shown, 'K: widget reported not visible while native geometry was rejecting')
    Truth(ctx.S.UIV3.WidgetHost:IsVisible(), 'K: WidgetHost dropped the widget from the reflow set')
    local instance = ctx.S.UIV3.WidgetHost._instance
    Truth(instance.visible == true, 'K: instance marked hidden after geometry rejection')
    for _, profile in ipairs(PROFILES) do
        local record = instance.buttons[tostring(profile.id)]
        Truth(record ~= nil and record.button.visible == true, 'K: button hidden after geometry rejection')
    end
    local diagnostics = instance:GetQuickButtonDiagnostics()
    assert((tonumber(diagnostics.metrics.geometryRejects) or 0) >= 1, 'K: geometry rejection was not recorded')
    assert((tonumber(diagnostics.metrics.createFailures) or 0) == 0, 'K: button creation failed in the fail-soft path')

    -- 原生恢复后，同一 metrics 重排必须把三个按钮放回正确位置（自愈）
    ctx.h.rejectAnchor = false
    Truth(ctx.S.UIV3.WidgetHost:ApplyResponsiveLayout(true), 'K: reflow after native recovery failed')
    Eq(SnapshotPlacements(Records(ctx)), baseline, 'K: reflow did not heal the rejected geometry')
    Eq(ctx.S.Persistence.writes, 0, 'K: healing wrote the Store')
end)

----------------------------------------------------------------------
-- L. 诊断快照必须给出每个按钮的完整证据（供实机定位四类根因）
----------------------------------------------------------------------
Test('L on-demand diagnostics expose per-button placement and native geometry evidence', function()
    local ctx = BootSession(nil, { 1920, 1080 })
    PlaceAll(ctx, { [1] = { 1180, 150 }, [2] = { 1290, 150 }, [3] = { 1500, 150 } })
    local instance = ctx.S.UIV3.WidgetHost._instance
    local payload = instance:GetQuickButtonDiagnostics()
    Eq(payload.contractVersion, 1, 'L: contract version')
    Eq(#payload.buttons, 3, 'L: button evidence count')
    assert(type(payload.context) == 'table' and tonumber(payload.context.logicalWidth) ~= nil, 'L: layout context missing')
    assert(type(payload.events) == 'table' and #payload.events > 0, 'L: bounded event log missing')
    for _, row in ipairs(payload.buttons) do
        assert(tonumber(row.profileId) ~= nil, 'L: profileId missing')
        Truth(row.created == true, 'L: created flag')
        Truth(row.geometryOk == true, 'L: geometryOk flag')
        assert(tonumber(row.nativeX) ~= nil and tonumber(row.nativeY) ~= nil, 'L: native rect missing')
        Truth(row.inLogicalViewport == true, 'L: inLogicalViewport flag')
        Eq(row.quickPositionCustomized, true, 'L: quickPositionCustomized')
        Truth(row.hasViewportIntent == true, 'L: viewport intent after real drag')
    end
end)


-- 2026-09-30: lifecycle native reset without a viewport change, not just resolution migration.
Test('M same-metrics reload repairs every existing profile button without Store writes',function()
    local ctx=BootSession(nil,{1280,960,.8,1024,768});local h,S=ctx.h,ctx.S
    PlaceAll(ctx,{[1]={300,150},[2]={430,150},[3]={560,150}})
    local before=Snap(S.Persistence.disk);local writes=S.Persistence.writes
    assert(S.Layout:StartMetricsEvents())
    local records=Records(ctx)
    for _,entry in ipairs(records)do entry.record.button.x=entry.record.button.x+100 end
    h:Drain()
    for i,entry in ipairs(records)do Eq(entry.record.button.x,entry.x,'M restored x')end
    Eq(S.Persistence.writes,writes);assert(Snap(S.Persistence.disk)==before)
end)
Test('N same-metrics repair leaves an in-progress profile drag untouched',function()
    local ctx=BootSession(nil,{1920,1080});local h,S=ctx.h,ctx.S
    local record=Records(ctx)[1].record;record.button.handlers.OnDragStart();record.button.x=400
    local writes=S.Persistence.writes;assert(S.Layout:StartMetricsEvents());h:Drain()
    Eq(record.button.x,400);Truth(record.dragging==true);Eq(S.Persistence.writes,writes)
    record.button.handlers.OnDragStop();local committed=record.button.x;for _=1,9 do h:Drain()end;Eq(record.button.x,committed)
end)

print(string.format('FEATURE_PROFILES_QUICK_GEOMETRY RESULT %d passed / %d failed (%s)', pass, fail, _VERSION))
assert(fail == 0, 'feature profile quick geometry regression failures: ' .. tostring(fail))
