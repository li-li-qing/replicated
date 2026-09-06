------------------------------------------------------------------------
-- Replicated Suite V3 - Auction Favorites Sidecar
--
-- Presentation-only companion to the native Auction House.  Native window
-- geometry comes from AuctionSurfaceV3; favorites/search state remains owned by
-- the existing tools_auction Feature + AuctionQueryV3.  No duplicate store and
-- no background auction search is introduced here.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local RSUI = S.RSUI
local Host = S.UIV3 and S.UIV3.WidgetHost or nil
local Floating = RSUI and RSUI.FloatingSurface or nil
local Feature = S.Features and S.Features.tools_auction or nil
local SurfaceService = S.Services and S.Services.AuctionSurfaceV3 or nil
if type(RSUI) ~= "table" or type(Host) ~= "table" or type(Floating) ~= "table"
    or type(Feature) ~= "table" or type(SurfaceService) ~= "table" then return end

local WIDGET_ID = "tools.auction_sidecar"
local OWNER = "v3:widget:auction_sidecar"
local WIDTH, HEIGHT = 300, 390

local Controller = {
    nativeVisible = false,
    dismissed = false,
    snapshot = nil,
}
S.UIV3 = S.UIV3 or {}
S.UIV3.AuctionSidecar = Controller

local function CopyState(target, source)
    if type(target) ~= "table" or type(source) ~= "table" then return false end
    for key in pairs(target) do target[key] = nil end
    for key, value in pairs(source) do target[key] = value end
    return true
end

local function FavoriteRows()
    local projection = Feature:GetProjection() or {}
    local out = {}
    for _, row in ipairs(type(projection.rows) == "table" and projection.rows or {}) do
        if type(row) == "table" and row.kind == "favorite" then
            out[#out + 1] = {
                key = tostring(row.key or ("favorite:" .. tostring(#out + 1))),
                favoriteIndex = tonumber(row.favoriteIndex),
                name = tostring(row.name or ""),
                status = "双击/点击查询",
            }
        end
    end
    return out, projection
end

local function SidecarPosition(snapshot)
    snapshot = type(snapshot) == "table" and snapshot or {}
    local context = S.Layout ~= nil and type(S.Layout.GetContext) == "function" and S.Layout:GetContext() or {}
    local safeLeft = tonumber(context.safeLeft) or 0
    local safeTop = tonumber(context.safeTop) or 0
    local safeRight = tonumber(context.safeRight) or 0
    local safeBottom = tonumber(context.safeBottom) or 0
    local logicalWidth = tonumber(context.logicalWidth) or 1024
    local logicalHeight = tonumber(context.logicalHeight) or 768
    local auctionX = tonumber(snapshot.x) or safeLeft
    local auctionY = tonumber(snapshot.y) or safeTop
    local auctionWidth = math.max(1, tonumber(snapshot.width) or 1)
    local gap = 8
    local x = auctionX - WIDTH - gap
    if x < safeLeft then x = auctionX + auctionWidth + gap end
    x = math.max(safeLeft, math.min(x, logicalWidth - safeRight - WIDTH))
    local y = math.max(safeTop, math.min(auctionY, logicalHeight - safeBottom - HEIGHT))
    return math.floor(x + 0.5), math.floor(y + 0.5)
end

local function CreateSidecar()
    local x, y = SidecarPosition(Controller.snapshot)
    local state = {
        width = WIDTH, height = HEIGHT, minimized = false, locked = true,
        overallOpacity = 0.96, backgroundOpacity = 1.0, textOpacity = 1.0, fontScale = 1.0,
        userMoved = true, x = x, y = y, coordinateSpace = "logical-free-v2",
    }
    local instance = { visible = false, acquired = false, subscribed = false, selectedIndex = nil, state = state }

    local surface, surfaceErr = Floating:Create({
        id = "v3_auction_sidecar", owner = OWNER, title = "拍卖收藏", status = "随拍卖行显示",
        width = WIDTH, height = HEIGHT, minWidth = WIDTH, minHeight = HEIGHT, maxWidth = WIDTH, maxHeight = HEIGHT,
        resizable = false, movable = false, footer = true, closeButton = true, appearanceControls = false,
        minimizeMode = "compact", boundaryMode = "free",
        statePolicy = { defaultWidth = WIDTH, defaultHeight = HEIGHT, minWidth = WIDTH, minHeight = HEIGHT, maxWidth = WIDTH, maxHeight = HEIGHT,
            defaultLocked = true, defaultOverallOpacity = 0.96, defaultBackgroundOpacity = 1.0, defaultTextOpacity = 1.0 },
        getState = function() return instance.state end,
        setState = function(value)
            if type(value) ~= "table" then return false, "sidecar state invalid" end
            CopyState(instance.state, value)
            instance.state.locked = true
            return true
        end,
        persist = function() return true end,
        onClosed = function(_, reason)
            Controller.dismissed = true
            return Host:NotifyWindowClosed(WIDGET_ID, { persist = false, source = tostring(reason or "auction_sidecar_close") })
        end,
    })
    if surface == nil then return nil, surfaceErr or "拍卖收藏侧窗创建失败" end
    instance.surface = surface
    instance.shell = surface.shell
    instance.windowController = surface.windowController

    local content = surface:GetContentRoot()
    local root = RSUI:VerticalBox({ id = "v3_auction_sidecar_content", parent = content, gap = 5,
        slot = { size = "fill", fill = 1, hAlign = "fill", vAlign = "fill" } })
    local searchRow = RSUI:HorizontalBox({ id = "v3_auction_sidecar_search_row", parent = root, gap = 4,
        slot = { size = "fixed", height = 30, hAlign = "fill" } })
    instance.input = RSUI:TextInput({ id = "v3_auction_sidecar_keyword", parent = searchRow, value = "", maxLength = 64,
        allowEmpty = false, placeholder = "物品名称", slot = { size = "fill", fill = 1, minWidth = 120 } })
    instance.searchButton = RSUI:Button({ id = "v3_auction_sidecar_search", parent = searchRow, text = "搜索", compact = true,
        slot = { size = "fixed", width = 52 } })
    instance.addButton = RSUI:Button({ id = "v3_auction_sidecar_add", parent = searchRow, text = "收藏", compact = true,
        slot = { size = "fixed", width = 52 } })

    local actionRow = RSUI:HorizontalBox({ id = "v3_auction_sidecar_action_row", parent = root, gap = 4,
        slot = { size = "fixed", height = 28, hAlign = "fill" } })
    instance.removeButton = RSUI:Button({ id = "v3_auction_sidecar_remove", parent = actionRow, text = "删除选中", compact = true,
        slot = { size = "fixed", width = 76 } })
    instance.status = RSUI:Text({ id = "v3_auction_sidecar_status", parent = actionRow, text = "收藏与主菜单共用同一数据", fontSize = 8,
        tone = "muted", overflow = "ellipsis", slot = { size = "fill", fill = 1, hAlign = "fill" } })

    instance.table = RSUI:TableView({
        id = "v3_auction_sidecar_table", parent = root, items = {}, rowHeight = 27, headerHeight = 26,
        desiredRows = 9, overscan = 1, scrollbar = true, selectable = true, columnResize = false, headerInteractive = false,
        getKey = function(item) return item and item.key or nil end,
        onSelectionChanged = function(index)
            instance.selectedIndex = tonumber(index)
            instance.removeButton:SetEnabled(instance.selectedIndex ~= nil)
        end,
        onItemActivated = function(item)
            if type(item) ~= "table" or tostring(item.name or "") == "" then return false end
            instance.input:SetValue(tostring(item.name), false, "auction_sidecar_activate")
            local ok, searchErr = Feature:Search(tostring(item.name))
            instance.status:SetText(ok == true and "已发送查询" or ("查询失败：" .. tostring(searchErr or "未执行")))
            return ok, searchErr
        end,
        columns = {
            { id = "name", title = "收藏关键词", field = "name", size = "fill", minWidth = 150, fill = 1.5 },
            { id = "status", title = "操作", field = "status", size = "fixed", width = 86, minWidth = 68, tone = "muted" },
        },
        slot = { size = "fill", fill = 1, hAlign = "fill", vAlign = "fill" },
    })
    if root == nil or instance.input == nil or instance.searchButton == nil or instance.addButton == nil
        or instance.removeButton == nil or instance.status == nil or instance.table == nil then
        return nil, "拍卖收藏侧窗控件构建失败"
    end

    local function Keyword()
        if type(instance.input.GetDraftValue) ~= "function" then return "" end
        return tostring(instance.input:GetDraftValue() or "")
    end

    instance.searchButton.onClick = function()
        local ok, searchErr = Feature:Search(Keyword())
        instance.status:SetText(ok == true and "已发送查询" or ("查询失败：" .. tostring(searchErr or "未执行")))
        instance:Refresh()
        return ok, searchErr
    end
    instance.addButton.onClick = function()
        local ok, addErr = Feature:AddFavorite(Keyword())
        instance.status:SetText(ok == true and "已加入收藏" or ("收藏失败：" .. tostring(addErr or "未执行")))
        if ok == true then Feature:Refresh("auction_sidecar_add") end
        instance:Refresh()
        return ok, addErr
    end
    instance.removeButton.onClick = function()
        local rows = instance.currentRows or {}
        local row = rows[tonumber(instance.selectedIndex) or 0]
        if type(row) ~= "table" or row.favoriteIndex == nil then
            instance.status:SetText("请先选择收藏关键词")
            return false
        end
        local ok, removeErr = Feature:RemoveFavorite(row.favoriteIndex)
        instance.status:SetText(ok == true and "已删除收藏" or ("删除失败：" .. tostring(removeErr or "未执行")))
        if ok == true then
            instance.selectedIndex = nil
            Feature:Refresh("auction_sidecar_remove")
        end
        instance:Refresh()
        return ok, removeErr
    end
    instance.removeButton:SetEnabled(false)

    function instance:ApplyAnchor(snapshot)
        if type(snapshot) == "table" then Controller.snapshot = snapshot end
        local nextX, nextY = SidecarPosition(Controller.snapshot)
        self.state.userMoved = true
        self.state.coordinateSpace = "logical-free-v2"
        self.state.x, self.state.y = nextX, nextY
        self.state.width, self.state.height = WIDTH, HEIGHT
        return self.surface:ApplyLayout(false)
    end

    function instance:Refresh()
        local rows, projection = FavoriteRows()
        self.currentRows = rows
        self.table:SetItems(rows, "auction_sidecar:" .. tostring(projection.revision or 0))
        if #rows == 0 then
            self.table:SetViewState("empty", { title = "暂无收藏", detail = "输入物品名称后点击“收藏”。" })
        else
            self.table:SetViewState("ready")
        end
        local queryStatus = tostring(projection.resultStatus or projection.searchStatus or "idle")
        self.surface:SetStatus("收藏 " .. tostring(#rows) .. " · " .. queryStatus, queryStatus == "failed" and "orange" or "muted")
        if self.selectedIndex ~= nil and rows[self.selectedIndex] == nil then self.selectedIndex = nil end
        self.removeButton:SetEnabled(self.selectedIndex ~= nil)
        return true
    end

    function instance:Subscribe()
        if self.subscribed == true then return true end
        if S.Events ~= nil and type(S.Events.SubscribeInternal) == "function" then
            S.Events:SubscribeInternal(Feature.UpdateTopic, self, function()
                if instance.visible == true then instance:Refresh() end
            end)
        end
        self.subscribed = true
        return true
    end

    function instance:Unsubscribe()
        if self.subscribed ~= true then return true end
        if S.Events ~= nil and type(S.Events.UnsubscribeInternalOwner) == "function" then S.Events:UnsubscribeInternalOwner(self) end
        self.subscribed = false
        return true
    end

    function instance:Show(context)
        context = type(context) == "table" and context or {}
        if type(context.snapshot) == "table" then Controller.snapshot = context.snapshot end
        self:ApplyAnchor(Controller.snapshot)
        if self.visible == true then self:Refresh(); return self.surface:Show(true) end
        self:Subscribe()
        local acquired, acquireErr = Feature:AcquireConsumer("widget:auction_sidecar")
        if acquired ~= true then self:Unsubscribe(); return false, acquireErr or "拍卖收藏侧窗 Consumer 获取失败" end
        self.acquired = true
        self:Refresh()
        local shown, showErr = self.surface:Show(true)
        if shown ~= true then
            Feature:ReleaseConsumer("widget:auction_sidecar")
            self.acquired = false
            self:Unsubscribe()
            return false, showErr or "拍卖收藏侧窗显示失败"
        end
        self.visible = true
        return true
    end

    function instance:Hide()
        local hidden, hideErr = self.surface:Show(false)
        if hidden ~= true then return false, hideErr end
        if self.acquired == true and Feature:HasConsumer("widget:auction_sidecar") then
            Feature:ReleaseConsumer("widget:auction_sidecar")
        end
        self.acquired = false
        self.visible = false
        self:Unsubscribe()
        return true
    end

    function instance:OnWindowClosed()
        if self.acquired == true and Feature:HasConsumer("widget:auction_sidecar") then
            Feature:ReleaseConsumer("widget:auction_sidecar")
        end
        self.acquired = false
        self.visible = false
        self:Unsubscribe()
        return true
    end
    function instance:Open(context) return self:Show(context) end
    function instance:Close(context) return self:Hide(context) end
    function instance:ApplyLayout(fromMetricsChange) return self.surface:ApplyLayout(fromMetricsChange == true) end
    return instance
end

local registered, registerErr = Host:Register(WIDGET_ID, {
    featureId = "tools_auction",
    create = CreateSidecar,
    ensurePreferences = function() return Feature:Initialize() end,
    lockable = false, minimizable = false, resettable = false,
    opacityAdjustable = false, backgroundOpacityAdjustable = false, textOpacityAdjustable = false,
})
if registered ~= true then error(registerErr) end

local function OnSurface(snapshot)
    snapshot = type(snapshot) == "table" and snapshot or {}
    local wasVisible = Controller.nativeVisible == true
    Controller.nativeVisible = snapshot.status == "ready" and snapshot.visible == true
    Controller.snapshot = snapshot
    if Controller.nativeVisible ~= true then
        Controller.dismissed = false
        if Host:IsVisible(WIDGET_ID) == true then Host:SetVisible(WIDGET_ID, false, { persist = false, source = "auction_native_close" }) end
        return true
    end
    if wasVisible ~= true then Controller.dismissed = false end
    if Controller.dismissed == true then return true end
    if Host:IsVisible(WIDGET_ID) ~= true then
        local shown = Host:SetVisible(WIDGET_ID, true, { persist = false, source = "auction_native_open", snapshot = snapshot })
        if shown ~= true then return false end
    end
    local instance = Host:GetInstance(WIDGET_ID)
    if type(instance) == "table" and type(instance.ApplyAnchor) == "function" then return instance:ApplyAnchor(snapshot) end
    return true
end

if S.Events ~= nil and type(S.Events.SubscribeInternal) == "function" then
    S.Events:SubscribeInternal(SurfaceService.topic or "v3.auction_surface.updated", Controller, function(_, snapshot)
        return OnSurface(snapshot)
    end)
end
OnSurface(SurfaceService:GetSnapshot())
