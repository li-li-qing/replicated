------------------------------------------------------------------------
-- Replicated Suite V3 - Quest / Activity Floating Detail
--
-- Session-only Presentation surface used when a HUD tracker row is activated.
-- Unlike the main-page modal it never wakes or redirects the application shell.
-- Data remains owned by QuestProgressV3; no X2Quest/X2BattleField access here.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local RSUI = S.RSUI
local Floating = RSUI and RSUI.FloatingSurface or nil
if type(RSUI) ~= "table" or type(Floating) ~= "table" then return end

S.UIV3 = S.UIV3 or {}
S.UIV3.QuestDetailFloatingV3 = S.UIV3.QuestDetailFloatingV3 or {
    id = "v3_quest_detail_floating",
    created = false,
    revision = 0,
    state = {
        width = 560, height = 420, minimized = false, locked = false,
        overallOpacity = 0.96, backgroundOpacity = 1.0, textOpacity = 1.0, fontScale = 1.0,
    },
}
local M = S.UIV3.QuestDetailFloatingV3

local function NotifyUnavailable(detail)
    local host = S.UIV3 and S.UIV3.ToastHost or nil
    if type(host) == "table" and type(host.Notify) == "function" then
        host:Notify({ id = "v3_quest_detail_floating_unavailable", title = "任务详情", detail = tostring(detail or "任务详情暂不可用。"),
            tone = "yellow", durationMs = 2800 })
        return true
    end
    if type(S.SafeChat) == "function" then S.SafeChat(tostring(detail or "任务详情暂不可用。")) end
    return false
end

function M:EnsureCreated()
    if self.created == true and self.surface ~= nil then return true end
    local surface, err = Floating:Create({
        id = self.id,
        owner = "v3:quest_detail:floating",
        title = "任务详情",
        status = "--",
        footer = true,
        movable = true,
        resizable = true,
        minimizeMode = "compact",
        boundaryMode = "free",
        defaultPlacement = "center",
        statePolicy = {
            defaultWidth = 560, defaultHeight = 420, minWidth = 420, minHeight = 260,
            defaultOverallOpacity = 0.96, defaultBackgroundOpacity = 1.0, defaultTextOpacity = 1.0,
            defaultFontScale = 1.0, minFontScale = 0.80, maxFontScale = 1.25,
        },
        getState = function() return M.state end,
        -- This is deliberately session-only. Opening a detail must not create
        -- a second feature/store authority or mutate Task/Activity settings.
        persist = function() return true end,
        onClosed = function()
            M.visible = false
            return true
        end,
    })
    if surface == nil then return false, err or "任务详情悬浮窗创建失败" end
    self.surface, self.shell = surface, surface.shell

    local stack = RSUI:VerticalBox({ id = self.id .. "_stack", parent = surface:GetContentRoot(), gap = 6,
        slot = { hAlign = "fill", vAlign = "fill" } })
    self.summary = RSUI:Text({ id = self.id .. "_summary", parent = stack, text = "--", fontSize = 10, tone = "muted",
        overflow = "wrap", maxLines = 3, slot = { size = "fixed", height = 48, hAlign = "fill" } })
    self.table = RSUI:TableView({
        id = self.id .. "_table", parent = stack, items = {}, rowHeight = 27, headerHeight = 26, desiredRows = 10,
        scrollbar = true, selectable = false, columnResize = true, headerInteractive = false,
        getKey = function(item, index) return item and item.key or tostring(index or 0) end,
        columns = {
            { id = "category", title = "类型", field = "category", size = "fill", minWidth = 54, absoluteMinWidth = 30, fill = 0.65,
                getTone = function(item) return item and item.related and "accent" or "muted" end },
            { id = "name", title = "任务 / 阶段", field = "name", size = "fill", minWidth = 210, absoluteMinWidth = 96, fill = 1.6,
                getTone = function(item) return item and item.tone or "default" end },
            { id = "status", title = "状态", field = "status", size = "fill", minWidth = 68, absoluteMinWidth = 42, fill = 0.9,
                getTone = function(item) return item and item.tone or "muted" end },
        },
        slot = { size = "fill", fill = 1, hAlign = "fill", vAlign = "fill" },
    })
    self.hint = RSUI:Text({ id = self.id .. "_hint", parent = stack, text = "--", fontSize = 9, tone = "muted",
        overflow = "wrap", maxLines = 2, slot = { size = "fixed", height = 34, hAlign = "fill" } })
    if self.summary == nil or self.table == nil or self.hint == nil then
        surface:Destroy()
        self.surface, self.shell = nil, nil
        return false, "任务详情悬浮窗内容创建失败"
    end
    surface:Show(false)
    self.created = true
    return true
end

function M:Open(scope, key, sourceRow)
    scope, key = tostring(scope or "event"), tostring(key or "")
    if key == "" then return NotifyUnavailable("该条目没有已核验的任务 / 副本关联。") end
    local service = S.Services and S.Services.QuestProgressV3 or nil
    if type(service) ~= "table" or type(service.GetGroupDetail) ~= "function" then
        return NotifyUnavailable("新版任务进度服务不可用。")
    end
    local detail = service:GetGroupDetail(scope, key)
    if type(detail) ~= "table" then
        return NotifyUnavailable("没有找到 " .. tostring(sourceRow and (sourceRow.rawName or sourceRow.name or sourceRow.shortName) or key) .. " 的任务详情。")
    end
    local ok, err = self:EnsureCreated()
    if ok ~= true then return false, err end

    self.revision = (tonumber(self.revision) or 0) + 1
    local title = tostring(detail.title or (sourceRow and (sourceRow.rawName or sourceRow.name or sourceRow.shortName)) or "任务详情")
    if self.shell ~= nil and type(self.shell.SetTitle) == "function" then self.shell:SetTitle(title) end
    self.summary:SetText(tostring(detail.summaryText or "--"))
    local children = type(detail.children) == "table" and detail.children or {}
    self.table:SetItems(children, "floating_detail:" .. tostring(self.revision))
    if #children == 0 then
        self.table:SetViewState("empty", { title = "暂无子任务详情", detail = "当前条目没有已核验的关联 / Boss / 公会任务明细。" })
    else
        self.table:SetViewState("ready")
    end
    self.table:ScrollToTop()
    if scope == "event" then
        self.hint:SetText("主任务计入活动进度；关联 / Boss / 公会任务只在详情中展示，不会擅自扩大主进度分母。")
    else
        self.hint:SetText("主任务计入该" .. (scope == "weekly" and "周常" or "日常") .. "进度；关联任务只作详情参考，不会擅自扩大主进度分母。")
    end
    self.surface:SetStatus(scope == "event" and "活动详情" or (scope == "weekly" and "周常详情" or "日常详情"), "muted")
    -- Activating a new row is an explicit request to read the detail; restore
    -- a previously compact-minimized session window instead of leaving only
    -- the tiny square visible.
    self.surface:SetMinimized(false, false)
    self.visible = true
    return self.surface:Show(true)
end

function M:Close(reason)
    if self.surface == nil then return true end
    self.visible = false
    return self.surface:Close(reason or "quest_detail_close")
end
