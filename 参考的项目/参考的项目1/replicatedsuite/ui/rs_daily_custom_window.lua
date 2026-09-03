------------------------------------------------------------------------
-- Replicated Suite - Custom daily tracking window
-- Author: Replicated
--
-- This window edits only the user's tracking set.  Quest state remains owned by
-- rs_quest_service.lua and is never duplicated here.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
S.DailyCustomWindow = { page=1, pageSize=12, rows={} }
local W = S.DailyCustomWindow

local function Service()
    return S.Services and S.Services.Quest
end

function W.Create()
    local managed = S.UI:CreateManagedWindow({ id="daily_custom", width=600, height=470, minWidth=600, minHeight=470, maxWidth=600, maxHeight=470, resizable=false,
        defaultPlacement=function(window,width,height,ctx)
            local scale=ctx.addonScale; local x=math.max(ctx.safeLeft,ctx.logicalWidth-width-54*scale); local y=math.max(ctx.safeTop,118*scale)
            if window.RemoveAllAnchors~=nil then window:RemoveAllAnchors() end; window:AddAnchor("TOPLEFT","UIParent",x,y); window:SetExtent(width,height)
        end })
    if managed == nil then return nil end
    local win = managed.window
    S.Theme:AddBorder(win, false)
    S.Theme:AddGradientBackground(win, "panel", nil)
    W.window = win; W.managed = managed
    S.UI.windows.dailyCustom = win

    local titleBar = S.UI:CreatePanel(win, "daily_custom_titlebar", 1, 1, 558, 30, "header")
    W.title = S.UI:CreateLabel(titleBar, "daily_custom_title", "自定义日常追踪", 10, 4, 470, 22, 15, nil, ALIGN_LEFT)
    W.close = S.UI:CreateButton(titleBar, "daily_custom_close", "X", 524, 3, 28, 24, 11, false)
    W.settings = managed:AttachSettingsControls(titleBar)
    W.help = S.UI:CreateLabel(win, "daily_custom_help", "只勾选你想在主面板和任务悬浮窗中追踪的日常。", 12, 39, 536, 22, 10, "muted", ALIGN_LEFT)
    W.count = S.UI:CreateLabel(win, "daily_custom_count", "追踪 0/0", 12, 62, 536, 22, 11, "blue", ALIGN_LEFT)

    for i=1,W.pageSize do
        local row = {}
        row.button = S.UI:CreateButton(win, "daily_custom_row_"..i, "", 12, 0, 400, 25, 10, false)
        if row.button.style and row.button.style.SetAlign then pcall(function() row.button.style:SetAlign(ALIGN_LEFT) end) end
        row.status = S.UI:CreateLabel(win, "daily_custom_status_"..i, "", 420, 0, 128, 25, 10, "muted", ALIGN_RIGHT)
        row.button:Show(false); row.status:Show(false)
        W.rows[i] = row
        local rowRef = row
        S.UI:SafeHandler(row.button, "OnClick", function()
            local service = Service()
            if rowRef.key ~= nil and service ~= nil and type(service.ToggleDailyTracked)=="function" then
                service:ToggleDailyTracked(rowRef.key)
                W:Refresh()
            end
        end, "daily_custom:toggle:"..i)
    end

    W.selectAll = S.UI:CreateButton(win, "daily_custom_all", "全部勾选", 12, 420, 90, 27, 9, false)
    W.selectNone = S.UI:CreateButton(win, "daily_custom_none", "全部取消", 108, 420, 90, 27, 9, false)
    W.prev = S.UI:CreateButton(win, "daily_custom_prev", "上一页", 278, 420, 72, 27, 9, false)
    W.pageLabel = S.UI:CreateLabel(win, "daily_custom_page", "1/1", 354, 423, 70, 22, 9, "muted", ALIGN_CENTER)
    W.next = S.UI:CreateButton(win, "daily_custom_next", "下一页", 428, 420, 72, 27, 9, false)
    W.pager = S.UI:CreatePager({ id = "daily_custom", pageSize = W.pageSize })

    managed:BindTitleBar(titleBar)
    S.UI:SafeHandler(W.close,"OnClick",function() managed:Show(false) end,"daily_custom:close")
    S.UI:SafeHandler(W.selectAll,"OnClick",function()
        local service=Service(); if service and type(service.SetAllDailyTracked)=="function" then service:SetAllDailyTracked(true); W.page=1; W:Refresh() end
    end,"daily_custom:all")
    S.UI:SafeHandler(W.selectNone,"OnClick",function()
        local service=Service(); if service and type(service.SetAllDailyTracked)=="function" then service:SetAllDailyTracked(false); W.page=1; W:Refresh() end
    end,"daily_custom:none")
    S.UI:SafeHandler(W.prev,"OnClick",function() W.page=W.pager:Move(-1); W:Refresh() end,"daily_custom:prev")
    S.UI:SafeHandler(W.next,"OnClick",function()
        local service=Service(); local groups=service and service:GetDailyGroups() or {}
        W.pager:SetTotal(#groups); W.page=W.pager:Move(1); W:Refresh()
    end,"daily_custom:next")
    if win.EnableScroll~=nil then pcall(function() win:EnableScroll(true) end) end
    S.UI:SafeHandler(win,"OnWheelUp",function() W.page=W.pager:Move(-1); W:Refresh() end,"daily_custom:wheel_up")
    S.UI:SafeHandler(win,"OnWheelDown",function()
        local service=Service(); local groups=service and service:GetDailyGroups() or {}
        W.pager:SetTotal(#groups); W.page=W.pager:Move(1); W:Refresh()
    end,"daily_custom:wheel_down")

    function W:ApplyLayout(metricsChanged)
        local scale=S.Layout:GetContext().addonScale
        local width,height=600*scale,470*scale
        local wasVisible=win:IsVisible()
        if not wasVisible or metricsChanged==true then managed:ApplyPlacement(width,height) else win:SetExtent(width,height) end
        if win.CorrectOffsetByScreen~=nil then pcall(function() win:CorrectOffsetByScreen() end) end
        titleBar:SetExtent(width-2,30*scale)
        W.title:SetExtent(width-84*scale,22*scale)
        W.close:SetExtent(28*scale,24*scale); S.UI:SetAnchor(W.close,titleBar,width-34*scale,3*scale)
        if W.settings and W.settings.ApplyLayout then W.settings:ApplyLayout(width) end
        W.help:SetExtent(width-24*scale,22*scale); S.UI:SetAnchor(W.help,win,12*scale,39*scale)
        W.count:SetExtent(width-24*scale,22*scale); S.UI:SetAnchor(W.count,win,12*scale,62*scale)
        local statusW=132*scale
        for i,row in ipairs(W.rows) do
            local y=(88+(i-1)*27)*scale
            row.button:SetExtent(width-statusW-34*scale,25*scale); S.UI:SetAnchor(row.button,win,12*scale,y)
            row.status:SetExtent(statusW,25*scale); S.UI:SetAnchor(row.status,win,width-statusW-12*scale,y)
        end
        local by=height-39*scale
        W.selectAll:SetExtent(90*scale,27*scale); S.UI:SetAnchor(W.selectAll,win,12*scale,by)
        W.selectNone:SetExtent(90*scale,27*scale); S.UI:SetAnchor(W.selectNone,win,108*scale,by)
        W.prev:SetExtent(72*scale,27*scale); S.UI:SetAnchor(W.prev,win,width-282*scale,by)
        W.pageLabel:SetExtent(70*scale,22*scale); S.UI:SetAnchor(W.pageLabel,win,width-206*scale,by+3*scale)
        W.next:SetExtent(72*scale,27*scale); S.UI:SetAnchor(W.next,win,width-132*scale,by)
    end

    function W:Refresh()
        local service=Service(); if service==nil then return end
        local groups=service:GetDailyGroups()
        local selected,total=service:GetDailyTrackingStats()
        self.count:SetText("已追踪 "..tostring(selected).."/"..tostring(total).." · 取消勾选不会删除任务数据")
        self.pager:SetTotal(#groups); self.page=self.pager:SetPage(self.page)
        local pages=self.pager:GetPageCount()
        self.pageLabel:SetText(tostring(self.page).."/"..tostring(pages))
        local rowByKey={}
        for _,row in ipairs(S.State.data.daily or {}) do rowByKey[tostring(row.key or "")]=row end
        for i,row in ipairs(self.rows) do
            local index=(self.page-1)*self.pageSize+i
            local group=groups[index]
            local show=group~=nil
            row.key=show and tostring(group.key) or nil
            row.button:Show(show); row.status:Show(show)
            if show then
                local tracked=service:IsDailyTracked(group.key)
                row.button:SetText((tracked and "[已] " or "[ ] ")..tostring(group.title or group.key or "日常"))
                local stateRow=rowByKey[tostring(group.key)]
                if stateRow~=nil then
                    row.status:SetText(tostring(stateRow.status or "--")); S.Theme:SetLabelTone(row.status,stateRow.tone or "muted")
                else
                    row.status:SetText("--"); S.Theme:SetLabelTone(row.status,"muted")
                end
            end
        end
        self.prev:Show(pages>1); self.next:Show(pages>1); self.pageLabel:Show(pages>1)
        if self.prev.Enable then self.prev:Enable(pages>1 and self.page>1) end
        if self.next.Enable then self.next:Enable(pages>1 and self.page<pages) end
    end

    function W:Open()
        self.page=math.max(1,tonumber(self.page) or 1)
        self:ApplyLayout(false); self:Refresh(); managed:Show(true)
    end

    W:ApplyLayout(false); managed:Show(false)
    if S.Layout~=nil and type(S.Layout.RegisterFloating)=="function" then
        S.Layout:RegisterFloating("daily_custom",win,{onlyWhenVisible=true,ensureNow=false,onMetricsChanged=function(changed) if changed==true then W:ApplyLayout(true) else S.Layout:EnsureWidgetVisible(win,{onlyWhenVisible=true}) end end})
    end
    return win
end
