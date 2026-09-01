------------------------------------------------------------------------
-- Replicated Suite V3 - Quest / Activity Detail Modal
--
-- Presentation only. Detail data is projected by QuestProgressService V3;
-- this modal never calls X2Quest/X2BattleField directly and never revives the
-- legacy QuestService / QuestDetailWindow.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local RSUI = S.RSUI
if type(RSUI) ~= "table" then return end

S.UIV3 = S.UIV3 or {}
S.UIV3.QuestDetailModalV3 = {
    id = "v3_quest_detail_modal",
    created = false,
    failedGeneration = nil,
    failedError = nil,
    revision = 0,
    detail = nil,
}
local M = S.UIV3.QuestDetailModalV3

local function NotifyUnavailable(detail)
    local host = S.UIV3 and S.UIV3.ToastHost or nil
    if type(host) == "table" and type(host.Notify) == "function" then
        host:Notify({
            id = "v3_quest_detail_unavailable",
            title = "任务详情",
            detail = tostring(detail or "该活动目前没有可核验的任务 / 副本详情。"),
            tone = "yellow",
            durationMs = 3200,
        })
        return true
    end
    if type(S.SafeChat) == "function" then S.SafeChat(tostring(detail or "任务详情暂不可用。")) end
    return false
end

function M:EnsureCreated()
    if self.created == true and self.card ~= nil then return true end
    if tonumber(self.failedGeneration) == tonumber(S.Generation) then return false, tostring(self.failedError or "任务详情 Modal 已在当前 Generation 隔离") end
    local modalHost = S.UIV3 and S.UIV3.ModalHost or nil
    local parent = type(modalHost) == "table" and type(modalHost.GetContentRoot) == "function" and modalHost:GetContentRoot() or nil
    if parent == nil then return false, "模态窗口宿主尚未挂载" end

    local buildOk, _, buildErr = RSUI:WithBuildScope(self.id .. ":build", function()
        self.card = RSUI:Border({
            id = self.id .. "_card", parent = parent, variant = "card", padding = 12,
            width = 640, height = 500,
            slot = { size = "auto", hAlign = "center", vAlign = "center", padding = 18 },
        })
        if self.card == nil then return false, "任务详情容器创建失败" end

        local stack = RSUI:VerticalBox({ id = self.id .. "_stack", parent = self.card, gap = 7 })
        if stack == nil then return false, "任务详情内容栈创建失败" end
        local header = RSUI:HorizontalBox({ id = self.id .. "_header", parent = stack, gap = 8, slot = { size = "fixed", height = 30, hAlign = "fill" } })
        if header == nil then return false, "任务详情标题栏创建失败" end
        self.title = RSUI:Text({ id = self.id .. "_title", parent = header, text = "任务详情", fontSize = 15, tone = "accent", overflow = "ellipsis", slot = { size = "fill", fill = 1 } })
        self.close = RSUI:Button({
            id = self.id .. "_close", parent = header, text = "×", compact = true,
            slot = { size = "fixed", width = 34 },
            onClick = function() return M:Close("close_button") end,
        })
        if self.title == nil or self.close == nil then return false, "任务详情标题控件创建失败" end
        self.summary = RSUI:Text({
            id = self.id .. "_summary", parent = stack, text = "--", fontSize = 10, tone = "muted", overflow = "wrap", maxLines = 2,
            slot = { size = "fixed", height = 38, hAlign = "fill" },
        })
        if self.summary == nil then return false, "任务详情摘要创建失败" end
        self.table = RSUI:TableView({
            id = self.id .. "_table", parent = stack, items = {},
            rowHeight = 28, headerHeight = 28, desiredRows = 11, overscan = 1,
            scrollbar = true, selectable = false, columnResize = true, headerInteractive = false,
            getKey = function(item, index) return item and item.key or tostring(index or 0) end,
            columns = {
                { id = "category", title = "类型", field = "category", size = "auto", minWidth = 56, maxWidth = 150,
                    getTone = function(item) return item and item.related and "accent" or "muted" end },
                { id = "name", title = "任务 / 阶段", field = "name", size = "fill", minWidth = 180, fill = 1.0,
                    getTone = function(item) return item and item.tone or "default" end },
                { id = "status", title = "状态", field = "status", size = "auto", minWidth = 72, maxWidth = 150,
                    getTone = function(item) return item and item.tone or "muted" end },
            },
            slot = { size = "fill", fill = 1, hAlign = "fill", vAlign = "fill" },
        })
        if self.table == nil then return false, "任务详情表格创建失败" end
        self.hint = RSUI:Text({
            id = self.id .. "_hint", parent = stack,
            text = "主任务计入活动 x/y；关联 / Boss / 公会任务只在详情中展示，不会擅自扩大主进度分母。",
            fontSize = 9, tone = "muted", overflow = "wrap", maxLines = 2,
            slot = { size = "auto", minHeight = 34, hAlign = "fill" },
        })
        if self.hint == nil then return false, "任务详情提示创建失败" end
        self.card:SetVisibility("collapsed")
        return true
    end)
    if buildOk ~= true then
        self.created = false
        self.failedGeneration = S.Generation
        self.failedError = tostring(buildErr or "任务详情 Modal 构建失败")
        self.card, self.title, self.close, self.summary, self.table, self.hint = nil, nil, nil, nil, nil, nil
        return false, self.failedError
    end
    self.created = true
    return true
end

function M:Open(scope, key, sourceRow)
    scope, key = tostring(scope or "event"), tostring(key or "")
    local modalHost = S.UIV3 and S.UIV3.ModalHost or nil
    if type(modalHost) ~= "table" or type(modalHost.EnsureApplicationVisible) ~= "function" then
        return false, "模态窗口宿主不可用"
    end
    local hostOk, hostErr = modalHost:EnsureApplicationVisible()
    if hostOk ~= true then return false, hostErr end
    -- Wake the application before reporting an unavailable detail as well.
    -- Otherwise ToastHost is attached to a hidden shell and the floating-row
    -- click appears to do nothing.
    if key == "" then return NotifyUnavailable("该活动没有已核验的任务 / 副本关联。") end
    local service = S.Services and S.Services.QuestProgressV3 or nil
    if type(service) ~= "table" or type(service.GetGroupDetail) ~= "function" then
        return NotifyUnavailable("新版任务进度服务不可用。")
    end
    local detail = service:GetGroupDetail(scope, key)
    if type(detail) ~= "table" then
        return NotifyUnavailable("没有找到 " .. tostring(sourceRow and sourceRow.name or key) .. " 的任务详情。")
    end
    local ok, err = self:EnsureCreated()
    if ok ~= true then return false, err end

    self.detail = detail
    self.revision = (tonumber(self.revision) or 0) + 1
    self.title:SetText(tostring(detail.title or (sourceRow and sourceRow.name) or "任务详情"))
    self.summary:SetText(tostring(detail.summaryText or "--"))
    local children = type(detail.children) == "table" and detail.children or {}
    self.table:SetItems(children, "detail:" .. tostring(self.revision))
    if #children == 0 then
        self.table:SetViewState("empty", { title = "暂无子任务详情", detail = "当前条目没有已核验的关联 / Boss / 公会任务明细。" })
    else
        self.table:SetViewState("ready")
    end
    self.table:ScrollToTop()
    if scope == "event" then
        self.hint:SetText("主任务计入活动 x/y；关联 / Boss / 公会任务只在详情中展示，不会擅自扩大主进度分母。")
    else
        self.hint:SetText("主任务计入该" .. (scope == "weekly" and "周常" or "日常") .. "进度；关联 / 阵营任务只作详情参考，不会擅自扩大主进度分母。")
    end

    modalHost = S.UIV3 and S.UIV3.ModalHost or modalHost
    if type(modalHost) ~= "table" or type(modalHost.Push) ~= "function" then return false, "模态窗口宿主不可用" end
    return modalHost:Push(self.id, self.card, { dismissOnBackdrop = true })
end

function M:Close(reason)
    local modalHost = S.UIV3 and S.UIV3.ModalHost or nil
    if type(modalHost) ~= "table" or type(modalHost.Pop) ~= "function" then return false end
    return modalHost:Pop(self.id, reason or "close") ~= nil
end
