-- Replicated Suite V3 - Quest Detail Floating lifecycle regression
-- 开发期离线测试；不进入 toc.g。验证 Presentation Consumer/事件边界，不冒充 RU Native 实机验收。
local pass, fail = 0, 0
local function Test(name, fn)
    local ok, err = xpcall(fn, debug.traceback)
    if ok then pass = pass + 1; print("PASS quest_detail " .. name)
    else fail = fail + 1; print("FAIL quest_detail " .. name .. ": " .. tostring(err)) end
end

local function Boot()
    ReplicatedSuite = {
        BootError = nil,
        Generation = 1,
        Services = {},
        Features = {},
        UIV3 = {},
        RSUI = {},
        SafeTraceback = function(err) return tostring(err) end,
        Utils = { DeepCopy = function(value)
            if type(value) ~= "table" then return value end
            local out = {}; for key, item in pairs(value) do out[key] = item end; return out
        end },
    }
    local S = ReplicatedSuite
    local subscriptions = {}
    S.Events = {}
    function S.Events:SubscribeInternal(topic, owner, callback)
        subscriptions[topic] = subscriptions[topic] or {}
        subscriptions[topic][owner] = callback
        return true
    end
    function S.Events:UnsubscribeInternalOwner(owner)
        for _, bucket in pairs(subscriptions) do bucket[owner] = nil end
        return true
    end
    function S.Events:Publish(topic, ...)
        local bucket = subscriptions[topic] or {}
        for owner, callback in pairs(bucket) do callback(owner, ...) end
        return true
    end

    local service = {
        acquireCalls = {}, releaseCalls = 0, detailReads = 0, refreshCalls = 0,
        held = false, objectiveText = "击败目标 17/30",
    }
    service.Demand = { Has = function() return service.held end }
    function service:GetGroupKind(scope, key)
        if key == "crimson" then return "activity" end
        if key == "red_dragon" then return "instanceRaid" end
        return nil
    end
    function service:AcquireConsumer(token, options)
        local previous = self.held and self.lastInstances == (options and options.instances == true)
        self.held = true; self.lastInstances = options and options.instances == true
        self.acquireCalls[#self.acquireCalls + 1] = { token = token, instances = self.lastInstances }
        return true, not previous
    end
    function service:ReleaseConsumer(token)
        assert(self.held == true, "release without held consumer")
        self.held = false; self.releaseCalls = self.releaseCalls + 1; self.releaseToken = token
        return true
    end
    function service:Refresh(reason, forceInstances)
        self.refreshCalls = self.refreshCalls + 1
        self.refreshReason = reason; self.refreshForceInstances = forceInstances
        return true
    end
    function service:GetGroupDetail(scope, key, options)
        self.detailReads = self.detailReads + 1
        if key == "red_dragon" then
            return { scope = scope, key = key, title = "红龙", kind = "instanceRaid", summaryText = "副本参与 0/1",
                children = { { key = "instance", trackingKey = "instance:entry", category = "副本", name = "副本参与次数", status = "0/1" } } }
        end
        if key ~= "crimson" then return nil end
        return { scope = scope, key = key, title = "征兆之痕", kind = "activity", progressSelectionEnabled = true,
            completed = 1, total = 3, activeCount = 1, readyCount = 0, relatedCount = 1,
            summaryText = "已完成 1/3 · 1 项进行中 · 1 项关联任务",
            children = {
                { key = "main:1", trackingKey = "main:101,102", category = "主任务", name = "阶段一", status = "已完成", state = "COMPLETED", counted = true, related = false },
                { key = "journal:1:1", parentTrackingKey = "main:101,102", journal = true, category = "目标", name = "└ " .. self.objectiveText, status = "" },
                { key = "main:2", trackingKey = "main:201", category = "主任务", name = "阶段二", status = "进行中", state = "IN_PROGRESS", counted = true, related = false },
                { key = "main:3", trackingKey = "main:301", category = "主任务", name = "阶段三", status = "未接", state = "NOT_ACCEPTED", counted = true, related = false },
                { key = "related:1", trackingKey = "related:501", category = "关联", name = "守护者", status = "已完成", state = "COMPLETED", counted = false, related = true },
            } }
    end
    S.Services.QuestProgressV3 = service

    local activityTracking = {} -- nil bucket means implicit all main objectives selected.
    local Activities = { Commands = {}, detailLoadOk = true }
    S.Features.Activities = Activities
    function Activities:EnsureDetailTrackingLoaded()
        if self.detailLoadOk == true then return true end
        return false, "detail_tracking_fenced"
    end
    local function MainTokens(detail)
        local out = {}
        for _, row in ipairs(type(detail.children) == "table" and detail.children or {}) do
            if row.journal ~= true and row.related ~= true and row.counted == true and tostring(row.trackingKey or "") ~= "" then
                out[#out + 1] = tostring(row.trackingKey)
            end
        end
        return out
    end
    local function SelectedSet(eventKey, tokens)
        local explicit = activityTracking[tostring(eventKey or "")]
        local selected = {}
        if type(explicit) == "table" then
            for _, token in ipairs(tokens) do if explicit[token] == true then selected[token] = true end end
        else
            for _, token in ipairs(tokens) do selected[token] = true end
        end
        return selected
    end
    function Activities:ProjectActivityDetail(detail)
        if type(detail) ~= "table" or detail.progressSelectionEnabled ~= true then return detail end
        local tokens = MainTokens(detail)
        local selected = SelectedSet(detail.key, tokens)
        local out = {}; for k,v in pairs(detail) do out[k] = v end; out.children = {}
        local completed, active, ready, total = 0, 0, 0, 0
        for _, source in ipairs(detail.children or {}) do
            local row = {}; for k,v in pairs(source) do row[k] = v end
            if row.journal == true then
                row.progressSelectable = false; row.progressSelected = selected[tostring(row.parentTrackingKey or "")] == true
            elseif row.related ~= true and row.counted == true then
                row.progressSelectable = true; row.progressSelected = selected[tostring(row.trackingKey or "")] == true
                if row.progressSelected then
                    total = total + 1
                    if row.state == "COMPLETED" or row.state == "READY_TO_TURN_IN" then completed = completed + 1 end
                    if row.state == "IN_PROGRESS" then active = active + 1 end
                    if row.state == "READY_TO_TURN_IN" then ready = ready + 1 end
                end
            else
                row.progressSelectable = false; row.progressSelected = false
            end
            out.children[#out.children + 1] = row
        end
        out.completed, out.total, out.activeCount, out.readyCount = completed, total, active, ready
        out.progressSelectionEligible, out.progressSelectionSelected = #tokens, total
        out.progressSelectionAvailable = self.detailLoadOk == true
        out.progressSelectionError = self.detailLoadOk == true and nil or "detail_tracking_fenced"
        out.summaryText = "个人进度 " .. tostring(completed) .. "/" .. tostring(total)
        return out
    end
    function Activities.Commands:SetProgressTaskSelected(eventKey, token, enabled)
        eventKey, token = tostring(eventKey or ""), tostring(token or "")
        if Activities.detailLoadOk ~= true then return false, "detail_tracking_fenced" end
        local raw = service:GetGroupDetail("event", eventKey, { journal = false })
        service.detailReads = service.detailReads - 1 -- command uses cached fact contract in production; keep harness accounting equivalent.
        if type(raw) ~= "table" then return false, "missing activity" end
        local tokens, known = MainTokens(raw), {}
        for _, candidate in ipairs(tokens) do known[candidate] = true end
        if known[token] ~= true then return false, "not main objective" end
        local selected = SelectedSet(eventKey, tokens)
        selected[token] = enabled == true or nil
        local count = 0; for _, value in pairs(selected) do if value == true then count = count + 1 end end
        if count < 1 then return false, "至少保留 1 个活动进度任务" end
        if count == #tokens then activityTracking[eventKey] = nil else activityTracking[eventKey] = selected end
        return true
    end

    local aux = {}
    S.UIV3.AuxWindowStoreV3 = aux
    function aux:EnsureLoaded() return true end
    function aux:GetPolicy() return { defaultWidth = 560, defaultHeight = 420 } end
    function aux:GetWindowState() return {} end
    function aux:SetWindowState() return true end
    function aux:PersistWindow() return true end

    local RSUI = S.RSUI
    RSUI.FloatingSurface = {}
    function RSUI.FloatingSurface:NormalizeState(state, policy)
        local out = {}
        for key, value in pairs(type(state) == "table" and state or {}) do out[key] = value end
        out.width = tonumber(out.width) or tonumber(policy and policy.defaultWidth) or 560
        out.height = tonumber(out.height) or tonumber(policy and policy.defaultHeight) or 420
        return out
    end
    local surfaceSpec
    function RSUI.FloatingSurface:Create(spec)
        surfaceSpec = spec
        local surface = { visible = false, status = nil, shell = { title = nil } }
        function surface.shell:SetTitle(value) self.title = value end
        function surface:GetContentRoot() return {} end
        function surface:Show(value) self.visible = value == true; return true end
        function surface:SetStatus(value) self.status = value; return true end
        function surface:SetMinimized() return true end
        function surface:Destroy() return true end
        function surface:Close(reason)
            self.visible = false
            if type(spec.onClosed) == "function" then spec.onClosed(self, reason) end
            return true
        end
        return surface
    end
    local function Basic(spec)
        local c = { spec = spec, visible = true, enabled = spec.enabled ~= false, selected = spec.selected == true, text = spec.text }
        function c:SetVisible(value) self.visible = value == true; return true end
        function c:SetEnabled(value) self.enabled = value == true; return true end
        function c:SetSelected(value) self.selected = value == true; return true end
        function c:SetText(value) self.text = value; return true end
        return c
    end
    function RSUI:VerticalBox(spec) return Basic(spec) end
    function RSUI:HorizontalBox(spec) return Basic(spec) end
    function RSUI:Text(spec) return Basic(spec) end
    function RSUI:StatusChip(spec)
        local c = Basic(spec)
        function c:SetStatus(status, text, tone) self.status, self.text, self.tone = status, text, tone; return true end
        return c
    end
    function RSUI:Button(spec)
        local c = Basic(spec)
        c.onClick = spec.onClick
        return c
    end
    function RSUI:TableView(spec)
        local c = Basic(spec)
        c.items, c.scrollTopCalls, c.state, c.selectedKey, c.selectedIndex = spec.items or {}, 0, nil, nil, nil
        function c:SetItems(items, revision) self.items = items; self.revision = revision; return true end
        function c:SetViewState(state, options) self.state = state; self.stateOptions = options; return true end
        function c:ScrollToTop() self.scrollTopCalls = self.scrollTopCalls + 1; return true end
        function c:GetSelectedKey() return self.selectedKey end
        function c:GetItem(index) return self.items[tonumber(index) or 0] end
        function c:SetSelectedIndex(index)
            local previous = self.selectedIndex
            local nextIndex = tonumber(index)
            local key = nil
            if nextIndex ~= nil then
                nextIndex = math.floor(nextIndex)
                local item = self.items[nextIndex]; key = item and item.key or nil
            end
            local changed = previous ~= nextIndex or self.selectedKey ~= key
            self.selectedIndex, self.selectedKey = nextIndex, key
            if changed and type(spec.onSelectionChanged) == "function" then
                return spec.onSelectionChanged(nextIndex, previous, self, nil, "set_index", key, nextIndex ~= nil, { view = self, index = nextIndex }) ~= false
            end
            return changed
        end
        function c:ClearSelection() return self:SetSelectedIndex(nil) end
        function c:ClickKey(key)
            for index, row in ipairs(self.items or {}) do
                if tostring(row.key) == tostring(key) then return self:SetSelectedIndex(index) end
            end
            return false, "item not found"
        end
        return c
    end

    dofile("presentation/v3/widgets/rs_v3_quest_detail_floating.lua")
    return S, S.UIV3.QuestDetailFloatingV3, service, function() return surfaceSpec end, activityTracking, Activities
end

Test("mapped activity owns consumer and refreshes objective text on refresh epoch", function()
    local S, M, service = Boot()
    assert(M:Open("event", "crimson", { key = "event:征兆", name = "征兆之痕", status = "还剩8分", progressText = "2/6" }))
    assert(M.consumerHeld == true and service.held == true, "detail consumer not held")
    assert(service.acquireCalls[1].instances == false, "ordinary activity woke instance catalog")
    assert(M.table.scrollTopCalls == 1, "explicit open should scroll to top once")
    assert(M.table.items[2].name == "└ 击败目标 17/30")
    service.objectiveText = "击败目标 18/30"
    S.Events:Publish("v3.quest_progress.refreshed", 2, 1, "QUEST_CONTEXT_OBJECTIVE_EVENT")
    assert(M.table.items[2].name == "└ 击败目标 18/30", "objective text did not live refresh")
    assert(M.table.scrollTopCalls == 1, "live refresh must preserve table viewport")
    assert(service.detailReads >= 2, "detail was not reread after refresh epoch")
end)

Test("switching regular activity to instance updates same lease options only", function()
    local S, M, service, getSurfaceSpec = Boot()
    assert(M:Open("event", "crimson", { name = "征兆之痕" }))
    assert(M:Open("event", "red_dragon", { name = "红龙" }))
    assert(#service.acquireCalls == 2, "consumer token should be updated, not duplicated")
    assert(service.acquireCalls[1].instances == false and service.acquireCalls[2].instances == true, "instance demand options mismatch")
    assert(service.releaseCalls == 0, "switching mapped rows must not tear down the lease between opens")
    assert(getSurfaceSpec().footer == false, "activity detail footer should be removed to avoid duplicate status")
end)

Test("unmapped activity opens consistent detail without keeping quest service alive", function()
    local S, M, service = Boot()
    assert(M:Open("event", "crimson", { name = "征兆之痕" }))
    assert(M:Open("event", nil, { key = "event:unknown", name = "未知活动", status = "23分后", scheduleText = "周日 20:00", progressText = "--" }))
    assert(M.visible == true, "unmapped activity detail did not open")
    assert(M.consumerHeld == false and service.held == false, "unmapped detail kept QuestProgress consumer")
    assert(service.releaseCalls == 1, "previous mapped consumer was not released")
    assert(M.shell.title == "未知活动", "activity title not preserved")
    local found = false
    for _, row in ipairs(M.table.items) do if row.key == "activity_no_verified_tasks" then found = true end end
    assert(found, "no verified-task row missing")
end)

Test("native/programmatic close releases consumer and subscription", function()
    local S, M, service = Boot()
    assert(M:Open("event", "crimson", { name = "征兆之痕" }))
    local reads = service.detailReads
    assert(M:Close("test_close"))
    assert(M.visible == false and M.consumerHeld == false and M.current == nil, "close did not clear detail lifecycle")
    assert(service.releaseCalls == 1 and service.held == false, "close did not release QuestProgress consumer")
    service.objectiveText = "击败目标 19/30"
    S.Events:Publish("v3.quest_progress.refreshed", 3, 1, "safety")
    assert(service.detailReads == reads, "closed detail still received progress refresh")
end)


Test("generation reload discards retired floating presenter and rebuilds native surface", function()
    local S, M = Boot()
    assert(M:Open("event", nil, { name = "未映射活动", status = "进行中" }))
    local oldPresenter, oldSurface = M, M.surface
    assert(oldPresenter.created == true and oldSurface ~= nil, "first generation did not create surface")

    S.Generation = 2
    dofile("presentation/v3/widgets/rs_v3_quest_detail_floating.lua")
    local fresh = S.UIV3.QuestDetailFloatingV3
    assert(fresh ~= oldPresenter, "new generation reused retired presenter table")
    assert(fresh.generation == 2 and fresh.created ~= true, "new presenter inherited retired created state")
    assert(fresh:Open("event", nil, { name = "第二代活动", status = "进行中" }))
    assert(fresh.surface ~= oldSurface, "new generation reused retired native surface")
    assert(fresh.shell.title == "第二代活动", "new generation detail did not render")
end)

Test("presentation layout store failure degrades to ephemeral geometry instead of blocking detail", function()
    local S, M = Boot()
    function S.UIV3.AuxWindowStoreV3:EnsureLoaded() return false, "layout_store_fenced" end
    assert(M:Open("event", nil, { name = "无存档活动", status = "23分后" }))
    assert(M.visible == true, "detail was blocked by presentation-only layout store")
    assert(M.layoutDurable == false and M.layoutLoadError == "layout_store_fenced", "layout degradation evidence missing")
end)

Test("crimson row toggles directly change personal denominator without native reread", function()
    local S, M, service, _, tracking = Boot()
    assert(M:Open("event", "crimson", { name = "征兆之痕" }))
    assert(M.trackingAvailable == true, "activity progress-selection store not available")
    assert(M.progressChip.text == "个人进度 1/3", "default all-main progress mismatch")
    assert(M.trackingChip.text == "追踪 3/3", "default all-main selection mismatch")
    assert(M.summary.visible == false and M.summary.text == "", "mapped activity duplicate summary should be hidden")
    assert(M.table.items[1].trackingText == "已选", "first main row should be selected by default")
    assert(M.table.items[3].trackingText == "已选" and M.table.items[4].trackingText == "已选", "main selection glyphs missing")
    assert(M.table.items[5].trackingText == "—", "related row must not be selectable")
    local reads = service.detailReads

    -- Remove completed stage 1: denominator becomes 2, numerator becomes 0.
    assert(M.table:ClickKey("main:1") == true, "main row click failed")
    assert(type(tracking.crimson) == "table" and tracking.crimson["main:101,102"] ~= true, "explicit subset not stored")
    assert(tracking.crimson["main:201"] == true and tracking.crimson["main:301"] == true, "wrong subset stored")
    assert(M.progressChip.text == "个人进度 0/2", "deselection did not change x/y")
    assert(M.trackingChip.text == "追踪 2/3", "selection summary did not change")
    assert(M.trackingChip.status == "pending" and M.trackingChip.tone == "yellow", "partial selection should be visually distinct")
    assert(M.table.items[1].trackingText == "未选", "deselected text did not refresh")
    assert(M.table.selectedKey == nil and M.selectedRowKey == nil, "transport selection must not remain highlighted")
    assert(M.progressToggleAttempts == 1 and M.progressToggleSuccesses == 1 and M.progressToggleFailures == 0, "toggle diagnostics mismatch")
    assert(service.detailReads == reads, "selection change reread Native quest detail")

    -- Related rows remain reference-only even when activated.
    assert(M.table:ClickKey("related:1") == true, "related row click should be harmless")
    assert(M.progressChip.text == "个人进度 0/2" and M.trackingChip.text == "追踪 2/3", "related row changed denominator")
    assert(service.detailReads == reads, "related click reread Native quest detail")

    -- Keep only stage 3, then reject removing the final task (never render 0/0).
    assert(M.table:ClickKey("main:2") == true, "second main deselection failed")
    assert(M.progressChip.text == "个人进度 0/1" and M.trackingChip.text == "追踪 1/3", "single-task denominator mismatch")
    M.table:ClickKey("main:3")
    assert(M.progressToggleFailures == 1 and tostring(M.lastProgressToggleError or ""):find("至少保留 1", 1, true) ~= nil, "final main task removal should be rejected")
    assert(M.progressChip.text == "个人进度 0/1" and M.trackingChip.text == "追踪 1/3", "rejected removal changed projection")
    assert(M.table.selectedKey == nil, "rejected toggle left sticky selection")

    -- Re-add the completed stage. Numerator and denominator both respond immediately.
    assert(M.table:ClickKey("main:1") == true, "main reselect failed")
    assert(M.progressChip.text == "个人进度 1/2", "reselect did not restore completed numerator")
    assert(M.trackingChip.text == "追踪 2/3", "reselect summary mismatch")
    assert(service.detailReads == reads, "reprojection should still use cached raw detail")
end)

Test("same main row can be toggled repeatedly without sticky table selection", function()
    local _, M = Boot()
    assert(M:Open("event", "crimson", { name = "征兆之痕" }))
    assert(M.table:ClickKey("main:1") == true)
    assert(M.table.items[1].trackingText == "未选" and M.table.selectedKey == nil)
    assert(M.table:ClickKey("main:1") == true)
    assert(M.table.items[1].trackingText == "已选" and M.table.selectedKey == nil)
    assert(M.progressToggleAttempts == 2 and M.progressToggleSuccesses == 2 and M.progressToggleFailures == 0)
end)

Test("progress-selection store failure falls back to all tasks but disables edits", function()
    local S, M, service, _, _, Activities = Boot()
    Activities.detailLoadOk = false
    assert(M:Open("event", "crimson", { name = "征兆之痕" }))
    assert(M.visible == true and M.trackingAvailable == false, "selection-store failure blocked or misreported detail")
    assert(M.progressChip.text == "个人进度 1/3" and M.trackingChip.text == "追踪 3/3", "degraded mode must keep truthful default-all progress")
    assert(string.find(M.hint.text or "", "个人进度追踪暂不可保存", 1, true) ~= nil, "degraded selection hint missing")
    M.table:ClickKey("main:1")
    assert(M.progressToggleFailures == 1 and tostring(M.lastProgressToggleError or ""):find("fenced", 1, true) ~= nil, "fenced selection should reject edit")
    assert(M.progressChip.text == "个人进度 1/3", "rejected edit changed x/y")
    assert(M.table.selectedKey == nil, "fenced toggle left sticky selection")
    assert(service.detailReads == 1, "quest detail should still render once")
end)

print(string.format("QUEST DETAIL FLOATING RESULT: %d passed, %d failed", pass, fail))
if fail > 0 then error("quest detail floating suite failures: " .. fail) end
