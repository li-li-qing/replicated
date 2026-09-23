-- Replicated Suite V3 - ActivityLists split-layout regression
-- 开发期离线测试；不进入 toc.g。验证活动时间/实时区域的表示层几何，不模拟 RU Native。
-- 维护（2026-09-22，activity-row-quantized-split-1）：除了“内容已全部显示后的剩余空间”，还要覆盖
-- “距离下一完整行只差几像素”的窗口高度。ListView 不绘制半行，因此 timeline 视口必须按整行量化，
-- 否则余数会夹在最后一条活动与“实时区域”表头之间。
local pass, fail = 0, 0
local function Test(name, fn)
    local ok, err = xpcall(fn, debug.traceback)
    if ok then pass = pass + 1; print("PASS activity_lists_layout " .. name)
    else fail = fail + 1; print("FAIL activity_lists_layout " .. name .. ": " .. tostring(err)) end
end

local function Boot()
    ReplicatedSuite = { BootError = nil, Generation = 11, UIV3 = {} }
    local S = ReplicatedSuite
    local R = {}
    S.RSUI = R
    function R:VerticalBox(spec)
        local c = { spec = spec, visible = true }
        function c:SetBounds(x,y,w,h) self.x,self.y,self.width,self.height=x,y,w,h return true end
        function c:InvalidateMeasure() self.measureDirty = true return true end
        return c
    end
    function R:TableView(spec)
        local t = { spec = spec, items = spec.items or {}, visible = true, headerVisible = true,
            rowHeight = tonumber(spec.rowHeight) or 24, headerHeight = tonumber(spec.headerHeight) or 22 }
        t.list = { rowHeight = t.rowHeight }
        function t:SetItems(items) self.items = items or {}; return true end
        function t:SetViewState() return true end
        function t:GetViewState() return "ready" end
        function t:GetSelectedKey() return nil end
        function t:GetSelectedIndex() return nil end
        function t:SetSelectedIndex() return true end
        function t:ClearSelection() return true end
        function t:RefreshVisible() return true end
        function t:SetRuntimeRowHeight(value) self.rowHeight=tonumber(value) or self.rowHeight;self.list.rowHeight=self.rowHeight;return true,self.rowHeight end
        function t:SetVisible(value) self.visible = value == true; return true end
        function t:SetHeaderVisible(value) self.headerVisible = value == true; return true end
        function t:Layout(x,y,w,h)
            self.layout = { x=x, y=y, width=w, height=h }
            return true
        end
        return t
    end
    dofile("presentation/v3/widgets/rs_v3_activity_lists.lua")
    return S.UIV3.ActivityLists:Create({
        id = "activity_layout_test", parent = {}, items = {}, rowHeight = 24, headerHeight = 22,
        columns = { { id = "name", field = "name", title = "活动" } },
        getKey = function(item) return item and item.key end,
    })
end

local function Rows(timelineCount, liveCount)
    local out = {}
    for i = 1, timelineCount do out[#out+1] = { key = "event:" .. i, name = "活动" .. i } end
    for i = 1, liveCount do out[#out+1] = { key = "zone:" .. i, name = "区域" .. i, zoneState = true } end
    return out
end

Test("specific-height surplus cannot create middle blank band", function()
    local lists = Boot()
    lists:SetItems(Rows(4,4), 1)
    lists:Layout(0,0,180,240)
    assert(lists.timeline.visible and lists.live.visible)
    assert(math.abs(lists.lastLayoutMetrics.timeTail) < 0.001, "timeline must not retain a partial-row tail")
    assert(math.abs(lists.lastLayoutMetrics.liveTail) < 0.001, "live section must absorb the old footer-side tail")
    assert(lists.live.layout.y == lists.timeline.layout.height, "live header must immediately follow timeline content")
    assert(math.abs(lists.live.layout.y + lists.live.layout.height - 240) < 0.001, "last section must consume the remaining viewport")
end)

Test("dense timeline still scrolls while live section keeps target capacity", function()
    local lists = Boot()
    lists:SetItems(Rows(10,4), 2)
    lists:Layout(0,0,180,240)
    assert(math.abs(lists.lastLayoutMetrics.timeTail) < 0.001, "dense timeline must have no internal tail")
    assert(math.abs(lists.lastLayoutMetrics.liveTail) < 0.001, "dense live section must have no footer tail")
    assert(lists.live.layout.y == lists.timeline.layout.height)
    assert(math.abs(lists.live.layout.y + lists.live.layout.height - 240) < 0.001)
end)

Test("medium height keeps both sections contiguous", function()
    local lists = Boot()
    lists:SetItems(Rows(4,4), 3)
    lists:Layout(0,0,180,150)
    assert(lists.timeline.layout.height == 46)
    assert(lists.live.layout.y == 46)
    assert(lists.live.layout.y + lists.live.layout.height == 150)
end)

Test("tiny height fails closed to live section without overlap", function()
    local lists = Boot()
    lists:SetItems(Rows(4,4), 4)
    lists:Layout(0,0,180,87)
    assert(lists.timeline.visible == false)
    assert(lists.live.visible == true)
    assert(lists.live.layout.y == 0 and lists.live.layout.height == 87)
end)

Test("all supported mixed counts and heights never reserve empty timeline tail", function()
    for timelineCount = 1, 6 do
        for liveCount = 1, 6 do
            for height = 96, 340 do
                local lists = Boot()
                lists:SetItems(Rows(timelineCount, liveCount), timelineCount * 100000 + liveCount * 1000 + height)
                lists:Layout(0,0,180,height)
                if lists.timeline.visible then
                    assert((tonumber(lists.lastLayoutMetrics.timeTail) or 0) < 0.001,
                        string.format("timeline tail leaked t=%d l=%d h=%d tail=%s", timelineCount, liveCount, height, tostring(lists.lastLayoutMetrics.timeTail)))
                    assert(math.abs(lists.live.layout.y - lists.timeline.layout.height) < 0.001,
                        string.format("section gap drift t=%d l=%d h=%d", timelineCount, liveCount, height))
                else
                    assert(lists.live.layout.y == 0)
                end
                assert(math.abs(lists.live.layout.y + lists.live.layout.height - height) < 0.001,
                    string.format("viewport not fully allocated t=%d l=%d h=%d", timelineCount, liveCount, height))
                if (tonumber(lists.lastLayoutMetrics.liveTail) or 0) > 0.001 then
                    -- 只有条目太少、所有可见行都已达到 soft max 时才允许真正的内容不足空白；
                    -- 不能再出现“还有数据但差几像素才多一行”的临界尾带。
                    assert(lists.lastLayoutMetrics.liveVisibleRows >= liveCount,
                        string.format("live threshold tail with hidden data t=%d l=%d h=%d tail=%s", timelineCount, liveCount, height, tostring(lists.lastLayoutMetrics.liveTail)))
                    assert(lists.lastLayoutMetrics.liveRowHeight >= 23.999,
                        string.format("live tail before max stretch t=%d l=%d h=%d row=%s", timelineCount, liveCount, height, tostring(lists.lastLayoutMetrics.liveRowHeight)))
                end
            end
        end
    end
end)


Test("one-pixel-before-next-row threshold leaves no middle band", function()
    local lists = Boot()
    lists:SetItems(Rows(5,5), 7)
    -- With a 22px header and 24px rows, 4 timeline rows need 118px and the
    -- fifth needs 142px. Heights between those thresholds must never produce
    -- a 1..23px empty tail inside the timeline viewport.
    for height = 244, 267 do
        lists:Layout(0,0,180,height)
        if lists.timeline.visible then
            assert((tonumber(lists.lastLayoutMetrics.timeTail) or 0) < 0.001, "timeline contains partial-row slack at height=" .. tostring(height))
            assert(math.abs(lists.live.layout.y - lists.timeline.layout.height) < 0.001, "live section detached at height=" .. tostring(height))
        end
        assert((tonumber(lists.lastLayoutMetrics.liveTail) or 0) < 0.001 or lists.lastLayoutMetrics.liveVisibleRows >= #lists.liveItems,
            "live threshold tail exists while hidden rows remain at height=" .. tostring(height))
    end
end)

Test("reported 3 timeline plus 5 live rows consumes footer-side remainder", function()
    local lists = Boot()
    lists:SetItems(Rows(3,5), 8)
    -- 真实截图对应的 body viewport 约 231px：timeline=22+3*24=94，live=137；
    -- live list 可用 115px。固定 20px 会留下 15px；新算法应把 5 行调整为 23px。
    lists:Layout(0,0,180,231)
    assert(math.abs(lists.timeline.layout.height - 94) < 0.001)
    assert(math.abs(lists.lastLayoutMetrics.liveRowHeight - 23) < 0.001, "live row height must absorb 15px tail")
    assert(lists.lastLayoutMetrics.liveVisibleRows == 5)
    assert(math.abs(lists.lastLayoutMetrics.liveTail) < 0.001, "reported footer-side blank band must be gone")
    assert(math.abs(lists.live.layout.y + lists.live.layout.height - 231) < 0.001)
end)

Test("single-section modes retain full viewport", function()
    local lists = Boot()
    lists:SetItems(Rows(4,0), 5)
    lists:Layout(0,0,180,240)
    assert(lists.timeline.visible == true and lists.timeline.layout.height == 240)
    assert(lists.live.visible == false)
    lists:SetItems(Rows(0,4), 6)
    lists:Layout(0,0,180,240)
    assert(lists.timeline.visible == false and lists.live.visible == true)
    assert(lists.live.layout.y == 0 and lists.live.layout.height == 240)
end)

print(string.format("ACTIVITY LISTS LAYOUT RESULT: %d passed, %d failed", pass, fail))
if fail > 0 then error("activity lists layout suite failures: " .. fail) end
