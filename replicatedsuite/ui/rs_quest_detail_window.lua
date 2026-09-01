------------------------------------------------------------------------
-- Replicated Suite - Quest group detail window
-- Author: Replicated
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
S.QuestDetailWindow = { page = 1, pageSize = 11, detail = nil }
local W = S.QuestDetailWindow

function W.Create()
    local managed = S.UI:CreateManagedWindow({ id="quest_detail", width=540, height=420, minWidth=540, minHeight=420, maxWidth=540, maxHeight=420, resizable=false,
        defaultPlacement=function(window,width,height,ctx)
            local scale=ctx.addonScale; local x=math.max(ctx.safeLeft,ctx.logicalWidth-width-40*scale); local y=math.max(ctx.safeTop,105*scale)
            if window.RemoveAllAnchors~=nil then window:RemoveAllAnchors() end; window:AddAnchor("TOPLEFT","UIParent",x,y); window:SetExtent(width,height)
        end })
    if managed == nil then return nil end
    local win = managed.window
    S.Theme:AddBorder(win, false); S.Theme:AddGradientBackground(win, "panel", nil)
    W.window = win; W.managed = managed; S.UI.windows.questDetail = win

    local titleBar = S.UI:CreatePanel(win, "quest_detail_titlebar", 1, 1, 498, 30, "header")
    W.title = S.UI:CreateLabel(titleBar, "quest_detail_title", "任务详情", 10, 4, 420, 22, 15, nil, ALIGN_LEFT)
    W.close = S.UI:CreateButton(titleBar, "quest_detail_close", "X", 464, 3, 28, 24, 11, false)
    W.settings = managed:AttachSettingsControls(titleBar)
    W.scopeLabel = S.UI:CreateLabel(win, "quest_detail_scope", "", 12, 38, 470, 22, 11, "muted", ALIGN_LEFT)
    W.progressLabel = S.UI:CreateLabel(win, "quest_detail_progress", "", 12, 61, 470, 22, 11, "yellow", ALIGN_LEFT)
    W.rows = {}

    -- Tracking is a normal Suite button, exactly like the proven bond/filter
    -- controls. Quest Service owns the boolean Authority; this window only renders
    -- that value and sends a toggle command. Do not split one logical control into
    -- overlapping Button/Label widgets: the previous composite implementations
    -- introduced a second presentation state that could drift from Authority.
    local function ApplyTrackingVisual(row, tracked, selectable, visible)
        if row == nil or row.track == nil then return end
        local canShow = visible == true and selectable == true
        local isTracked = tracked == true
        row.track:Show(canShow)
        if row.track.Enable ~= nil then row.track:Enable(canShow) end
        if canShow then
            row.track:SetText(isTracked and "已追踪" or "未追踪")
            if S.Theme ~= nil and type(S.Theme.SetButtonActive) == "function" then
                S.Theme:SetButtonActive(row.track, isTracked)
            end
        end
    end

    local function RecomputeEventDetailProgress(detail)
        if type(detail) ~= "table" or detail.scope ~= "event" then return end
        local completed, total, readyCount, activeCount = 0, 0, 0, 0
        for _, item in ipairs(type(detail.children) == "table" and detail.children or {}) do
            if item.tracked == true then
                total = total + 1
                if item.state == S.Constants.QuestStatus.COMPLETED then
                    completed = completed + 1
                elseif item.ready == true then
                    completed = completed + 1
                    readyCount = readyCount + 1
                elseif item.active == true then
                    activeCount = activeCount + 1
                end
            end
        end
        detail.completed = completed
        detail.total = total
        detail.readyCount = readyCount
        detail.activeCount = activeCount
        detail.progressText = total > 0 and ("已完成 " .. tostring(completed) .. "/" .. tostring(total)
            .. (readyCount > 0 and (" · " .. tostring(readyCount) .. " 项可交付") or "")
            .. (activeCount > 0 and (" · " .. tostring(activeCount) .. " 项进行中") or ""))
            or "未选择追踪任务"
    end

    local function ToggleBoundTrackingRow(row)
        if row == nil or row.boundSelectable ~= true then return false end
        local groupKey = tostring(row.boundGroupKey or "")
        local trackingKey = tostring(row.boundTrackingKey or "")
        if groupKey == "" or trackingKey == "" then return false end
        local service = S.Services and S.Services.Quest
        if service == nil or type(service.ToggleEventObjectiveTracked) ~= "function" then return false end

        local ok, applied = service:ToggleEventObjectiveTracked(groupKey, trackingKey)
        if ok ~= true then return false end

        -- `applied` is the value re-read from Quest Service Authority after write.
        -- Update the open presentation snapshot first, then repaint the whole
        -- detail view through the same Refresh path used everywhere else.  Do
        -- not mutate the clicked native Button independently inside OnClick.
        row.boundTracked = applied == true
        local detail = W.detail
        if type(detail) == "table" and detail.scope == "event" and tostring(detail.key or "") == groupKey then
            for _, item in ipairs(type(detail.children) == "table" and detail.children or {}) do
                if tostring(item.trackingKey or "") == trackingKey then
                    item.tracked = row.boundTracked
                    item.counted = row.boundTracked
                    break
                end
            end
            RecomputeEventDetailProgress(detail)
        end

        -- ArcheRage's stock button handlers (globals/button.lua) and the Suite's
        -- working dynamic buttons use a nil-returning OnClick followed by a page
        -- Refresh. Keep this control on that proven contract as well. The normal
        -- 120 ms dirty flush will still Reload from Quest Service afterwards.
        W:Refresh()
        return true
    end

    for i = 1, W.pageSize do
        local rowIndex = i
        local name = S.UI:CreateLabel(win, "quest_detail_row_" .. i, "", 12, 0, 340, 25, 10, nil, ALIGN_LEFT)
        local track = S.UI:CreateButton(win, "quest_detail_track_" .. i, "未追踪", 356, 0, 68, 23, 8, false)
        local value = S.UI:CreateLabel(win, "quest_detail_value_" .. i, "", 428, 0, 100, 25, 10, "muted", ALIGN_RIGHT)
        W.rows[i] = { name = name, track = track, value = value }
        name:Show(false); track:Show(false); value:Show(false)
        S.UI:SafeHandler(track, "OnClick", function()
            -- OnClick is a notification handler, not an acceptance gate.  Do not
            -- propagate ToggleBoundTrackingRow's boolean result to the native
            -- button; drag-start is the event type that intentionally returns
            -- true in the client UI framework.
            ToggleBoundTrackingRow(W.rows[rowIndex])
        end, "quest_detail:toggle_tracking_" .. tostring(rowIndex))
    end
    W.prev = S.UI:CreateButton(win, "quest_detail_prev", "上一页", 12, 376, 72, 26, 9, false)
    W.pageLabel = S.UI:CreateLabel(win, "quest_detail_page", "1/1", 90, 378, 90, 22, 9, "muted", ALIGN_CENTER)
    W.next = S.UI:CreateButton(win, "quest_detail_next", "下一页", 186, 376, 72, 26, 9, false)
    W.hint = S.UI:CreateLabel(win, "quest_detail_hint", "活动任务可独立选择是否追踪", 270, 378, 236, 22, 9, "muted", ALIGN_RIGHT)
    W.pager = S.UI:CreatePager({ id = "quest_detail", pageSize = W.pageSize })

    managed:BindTitleBar(titleBar)
    S.UI:SafeHandler(W.close,"OnClick",function() managed:Show(false) end,"quest_detail:close")
    S.UI:SafeHandler(W.prev,"OnClick",function() W.page=W.pager:Move(-1); W:Refresh() end,"quest_detail:prev")
    S.UI:SafeHandler(W.next,"OnClick",function() W.pager:SetTotal(W.detail and #(W.detail.children or {}) or 0); W.page=W.pager:Move(1); W:Refresh() end,"quest_detail:next")
    if win.EnableScroll ~= nil then pcall(function() win:EnableScroll(true) end) end
    S.UI:SafeHandler(win,"OnWheelUp",function() W.page=W.pager:Move(-1); W:Refresh() end,"quest_detail:wheel_up")
    S.UI:SafeHandler(win,"OnWheelDown",function() W.pager:SetTotal(W.detail and #(W.detail.children or {}) or 0); W.page=W.pager:Move(1); W:Refresh() end,"quest_detail:wheel_down")

    function W:ApplyLayout(metricsChanged)
        local scale=S.Layout:GetContext().addonScale
        local width,height=540*scale,420*scale
        local wasVisible=win:IsVisible(); if not wasVisible or metricsChanged==true then managed:ApplyPlacement(width,height) else win:SetExtent(width,height) end
        if win.CorrectOffsetByScreen~=nil then pcall(function() win:CorrectOffsetByScreen() end) end
        titleBar:SetExtent(width-2,30*scale); W.title:SetExtent(width-78*scale,22*scale)
        W.close:SetExtent(28*scale,24*scale); S.UI:SetAnchor(W.close,titleBar,width-34*scale,3*scale)
        if W.settings and W.settings.ApplyLayout then W.settings:ApplyLayout(width) end
        W.scopeLabel:SetExtent(width-24*scale,22*scale); S.UI:SetAnchor(W.scopeLabel,win,12*scale,38*scale)
        W.progressLabel:SetExtent(width-24*scale,22*scale); S.UI:SetAnchor(W.progressLabel,win,12*scale,61*scale)
        for i, row in ipairs(W.rows) do
            local ry = (88 + (i - 1) * 25) * scale
            row.name:SetExtent(width - 200 * scale, 23 * scale); S.UI:SetAnchor(row.name, win, 12 * scale, ry)
            row.track:SetExtent(68 * scale, 23 * scale); S.UI:SetAnchor(row.track, win, width - 184 * scale, ry)
            row.value:SetExtent(100 * scale, 23 * scale); S.UI:SetAnchor(row.value, win, width - 112 * scale, ry)
        end
        local by=height-38*scale
        W.prev:SetExtent(72*scale,26*scale); S.UI:SetAnchor(W.prev,win,12*scale,by)
        W.pageLabel:SetExtent(90*scale,22*scale); S.UI:SetAnchor(W.pageLabel,win,90*scale,by+2*scale)
        W.next:SetExtent(72*scale,26*scale); S.UI:SetAnchor(W.next,win,186*scale,by)
        W.hint:SetExtent(width-282*scale,22*scale); S.UI:SetAnchor(W.hint,win,270*scale,by+2*scale)
    end

    function W:Refresh()
        local detail=self.detail; if detail==nil then return end
        local isInstanceRaid = detail.kind == "instanceRaid"
        local scopeText=detail.scope=="weekly" and "周常任务" or (detail.scope=="event" and "活动任务" or "日常任务")
        self.title:SetText(tostring(detail.title or "任务详情"))
        self.scopeLabel:SetText(scopeText .. (isInstanceRaid and " · 副本入场次数以客户端实例面板为准" or " · 子任务状态使用客户端官方任务标题"))
        self.progressLabel:SetText("组进度：" .. tostring(detail.progressText or "--"))
        self.hint:SetText(isInstanceRaid and "入场次数 1/1 = 已完成" or (detail.scope == "event" and "左侧√=已完成 · 右侧按钮=是否追踪" or "组进度为可可靠读取的子任务完成数"))
        local children=detail.children or {}; self.pager:SetTotal(#children); self.page=self.pager:SetPage(self.page)
        local pages=self.pager:GetPageCount(); self.pageLabel:SetText(tostring(self.page).."/"..tostring(pages))
        local pagerVisible=pages>1
        self.prev:Show(pagerVisible); self.pageLabel:Show(pagerVisible); self.next:Show(pagerVisible)
        if self.prev.Enable then self.prev:Enable(pagerVisible and self.page>1) end
        if self.next.Enable then self.next:Enable(pagerVisible and self.page<pages) end
        for i, row in ipairs(self.rows) do
            local index = (self.page - 1) * self.pageSize + i
            local item = children[index]
            local show = item ~= nil
            row.name:Show(show); row.value:Show(show)
            ApplyTrackingVisual(row, false, false, false)
            row.boundGroupKey = nil
            row.boundTrackingKey = nil
            row.boundSelectable = false
            row.boundTracked = false
            if show then
                local prefix
                if item.state == S.Constants.QuestStatus.COMPLETED then
                    prefix = "[√] "
                elseif item.ready then
                    prefix = "[可交] "
                elseif item.active then
                    prefix = "[进行] "
                else
                    prefix = "[未接] "
                end
                row.name:SetText(prefix .. tostring(item.name or ("任务 " .. tostring(item.id or ""))))
                S.Theme:SetLabelTone(row.name, item.tone)
                row.value:SetText(tostring(item.status or "--")); S.Theme:SetLabelTone(row.value, item.tone)
                if detail.scope == "event" then
                    row.boundGroupKey = tostring(detail.key or "")
                    row.boundTrackingKey = tostring(item.trackingKey or "")
                    row.boundSelectable = item.trackingSelectable == true and row.boundTrackingKey ~= ""
                    row.boundTracked = item.tracked == true
                    ApplyTrackingVisual(row, row.boundTracked, row.boundSelectable, true)
                end
            end
        end
    end

    function W:Reload()
        if self.detail==nil then return end
        local service=S.Services and S.Services.Quest; if service==nil or type(service.GetGroupDetail)~="function" then return end
        local detail=service:GetGroupDetail(self.detail.scope,self.detail.key); if detail~=nil then self.detail=detail; self:Refresh() end
    end

    function W:Open(scope,key)
        local service=S.Services and S.Services.Quest; if service==nil or type(service.GetGroupDetail)~="function" then return end
        local detail=service:GetGroupDetail(scope,key)
        if detail==nil then
            -- Surface the miss instead of failing silently: the user can then
            -- report the scope/key that no longer opens a detail panel.
            S.SafeChat("任务详情打开失败：未找到 " .. tostring(scope) .. "/" .. tostring(key) .. " 的详情数据。")
            return
        end
        self.detail=detail; self.pager:SetPage(1); self.page=1
        local ok, err = xpcall(function() self:ApplyLayout(); self:Refresh() end, S.SafeTraceback)
        if not ok then
            S.SafeChat("任务详情渲染失败：" .. tostring(err))
            return
        end
        managed:Show(true)
    end

    W:ApplyLayout(); managed:Show(false)
    if S.Layout~=nil and type(S.Layout.RegisterFloating)=="function" then
        S.Layout:RegisterFloating("quest_detail",win,{onlyWhenVisible=true,ensureNow=false,onMetricsChanged=function(changed) if changed==true then W:ApplyLayout(true) else S.Layout:EnsureWidgetVisible(win,{onlyWhenVisible=true}) end end})
    end
    return win
end
