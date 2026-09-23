-- Replicated Suite V3 - Activity detail click bridge regression
-- 开发期离线测试；不进入 toc.g。验证双列表点击转发和诊断证据，不模拟 RU Native 鼠标驱动。
local pass, fail = 0, 0
local function Test(name, fn)
    local ok, err = xpcall(fn, debug.traceback)
    if ok then pass = pass + 1; print("PASS activity_detail_click " .. name)
    else fail = fail + 1; print("FAIL activity_detail_click " .. name .. ": " .. tostring(err)) end
end

local function Boot(callback)
    ReplicatedSuite = {
        BootError = nil,
        Generation = 7,
        UIV3 = {},
        SafeTraceback = function(err) return tostring(err) end,
        NowMs = function() return 1234 end,
        SafeChat = function() return true end,
    }
    local S = ReplicatedSuite
    local capturedProvider = nil
    S.ModuleDiagnosticsHub = {
        RegisterProvider = function(_, moduleId, id, provider)
            assert(moduleId == "life_activities" and id == "activity_detail_click")
            capturedProvider = provider
            return true
        end,
    }
    local R = {}
    S.RSUI = R
    function R:VerticalBox(spec)
        local c = { spec = spec, visible = true }
        function c:SetBounds(x,y,w,h) self.x,self.y,self.width,self.height=x,y,w,h return true end
        function c:InvalidateMeasure() return true end
        return c
    end
    function R:TableView(spec)
        local t = { spec = spec, items = spec.items or {}, selected = nil, visible = true }
        function t:SetItems(items) self.items = items; return true end
        function t:SetViewState() return true end
        function t:GetViewState() return "ready" end
        function t:GetSelectedKey() return self.selected end
        function t:GetSelectedIndex() return nil end
        function t:SetSelectedIndex(index) self.selectedIndex = index; return true end
        function t:ClearSelection() self.selected = nil; return true end
        function t:RefreshVisible() return true end
        function t:SetVisible(value) self.visible = value == true; return true end
        function t:SetHeaderVisible() return true end
        function t:Layout() return true end
        return t
    end
    dofile("presentation/v3/widgets/rs_v3_activity_lists.lua")
    local lists = S.UIV3.ActivityLists:Create({
        id = "activity_test", parent = {}, items = {}, rowHeight = 24, headerHeight = 22,
        columns = { { id = "name", field = "name", title = "活动" } },
        getKey = function(item) return item and item.key end,
        onItemActivated = callback,
    })
    return S, lists, function() return capturedProvider and capturedProvider() or nil end
end

Test("timeline activation forwards full failure reason to diagnostics", function()
    local lists
    local S, built, Diagnose = Boot(function(item, index, key, view, reason)
        assert(item.key == "event:a" and index == 1 and key == "event:a")
        assert(view == lists and reason == "row_click")
        return false, "floating_generation_retired"
    end)
    lists = built
    lists:SetItems({ { key = "event:a", name = "活动A" } }, 1)
    local ok, detail = lists.timeline.spec.onItemActivated(lists.timeline.items[1], 1, "event:a", lists.timeline, "row_click")
    assert(ok == false and detail == "floating_generation_retired")
    local diag = Diagnose()
    assert(diag.attempts == 1 and diag.failures == 1 and diag.successes == 0)
    assert(diag.lastError == "floating_generation_retired" and diag.lastKey == "event:a")
end)

Test("live activation translates section index and records success", function()
    local seenIndex = nil
    local S, lists, Diagnose = Boot(function(item, index)
        seenIndex = index
        return true
    end)
    lists:SetItems({
        { key = "event:a", name = "活动A" },
        { key = "zone:b", name = "区域B", zoneState = true },
    }, 2)
    local ok = lists.live.spec.onItemActivated(lists.live.items[1], 1, "zone:b", lists.live, "row_click")
    assert(ok == true and seenIndex == 2, "live row did not translate to combined index")
    local diag = Diagnose()
    assert(diag.attempts == 1 and diag.successes == 1 and diag.failures == 0)
    assert(diag.lastSection == "live" and diag.lastKey == "zone:b")
end)

print(string.format("ACTIVITY DETAIL CLICK RESULT: %d passed, %d failed", pass, fail))
if fail > 0 then error("activity detail click suite failures: " .. fail) end
