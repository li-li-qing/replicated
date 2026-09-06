------------------------------------------------------------------------
-- Replicated Suite V3 - Craft Assistant Native Sidecar
--
-- Presentation-only companion to verified native craft windows. Recipe/material
-- state remains owned by tools_craft.  The sidecar never performs background
-- auction queries: market quotes are submitted only by the user's explicit
-- "材料询价" action through the Feature command / PriceQuoteQueueV3.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local RSUI = S.RSUI
local Host = S.UIV3 and S.UIV3.WidgetHost or nil
local Floating = RSUI and RSUI.FloatingSurface or nil
local Feature = S.Features and S.Features.tools_craft or nil
local SurfaceService = S.Services and S.Services.CraftSurfaceV3 or nil
if type(RSUI) ~= "table" or type(Host) ~= "table" or type(Floating) ~= "table"
    or type(Feature) ~= "table" or type(SurfaceService) ~= "table" then return end

local WIDGET_ID = "tools.craft_sidecar"
local OWNER = "v3:widget:craft_sidecar"
local WIDTH, HEIGHT = 360, 430

local Controller = { nativeVisible = false, dismissed = false, snapshot = nil }
S.UIV3 = S.UIV3 or {}
S.UIV3.CraftSidecar = Controller

local function CopyState(target, source)
    if type(target) ~= "table" or type(source) ~= "table" then return false end
    for key in pairs(target) do target[key] = nil end
    for key, value in pairs(source) do target[key] = value end
    return true
end

local function SidecarPosition(snapshot)
    snapshot = type(snapshot) == "table" and snapshot or {}
    local context = S.Layout ~= nil and type(S.Layout.GetContext) == "function" and S.Layout:GetContext() or {}
    local safeLeft, safeTop = tonumber(context.safeLeft) or 0, tonumber(context.safeTop) or 0
    local safeRight, safeBottom = tonumber(context.safeRight) or 0, tonumber(context.safeBottom) or 0
    local logicalWidth, logicalHeight = tonumber(context.logicalWidth) or 1024, tonumber(context.logicalHeight) or 768
    local nativeX, nativeY = tonumber(snapshot.x) or safeLeft, tonumber(snapshot.y) or safeTop
    local nativeWidth, gap = math.max(1, tonumber(snapshot.width) or 1), 8
    local x = nativeX - WIDTH - gap
    if x < safeLeft then x = nativeX + nativeWidth + gap end
    x = math.max(safeLeft, math.min(x, logicalWidth - safeRight - WIDTH))
    local y = math.max(safeTop, math.min(nativeY, logicalHeight - safeBottom - HEIGHT))
    return math.floor(x + 0.5), math.floor(y + 0.5)
end

local function MaterialRows(projection)
    local craft = type(projection) == "table" and type(projection.craft) == "table" and projection.craft or {}
    local rows = {}
    for _, recipe in ipairs(type(craft.recipes) == "table" and craft.recipes or {}) do
        local materials = type(recipe.materials) == "table" and recipe.materials.items or nil
        for _, item in ipairs(type(materials) == "table" and materials or {}) do
            rows[#rows + 1] = {
                key = "craft-sidecar:" .. tostring(recipe.craftType or 0) .. ":" .. tostring(item.itemType or #rows + 1),
                name = tostring(item.name or (item.itemType ~= nil and ("物品 " .. tostring(item.itemType)) or "材料")),
                need = item.count ~= nil and tostring(item.count) or "?",
                held = item.held ~= nil and tostring(item.held) or "?",
                shortage = item.shortage ~= nil and tostring(item.shortage) or "?",
            }
        end
    end
    return rows
end

local function CreateSidecar()
    local x, y = SidecarPosition(Controller.snapshot)
    local state = {
        width = WIDTH, height = HEIGHT, minimized = false, locked = true,
        overallOpacity = 0.96, backgroundOpacity = 1.0, textOpacity = 1.0, fontScale = 1.0,
        userMoved = true, x = x, y = y, coordinateSpace = "logical-free-v2",
    }
    local instance = { visible = false, acquired = false, subscribed = false, state = state }
    local surface, surfaceErr = Floating:Create({
        id = "v3_craft_sidecar", owner = OWNER, title = "制作台助手", status = "随制作窗口显示",
        width = WIDTH, height = HEIGHT, minWidth = WIDTH, minHeight = HEIGHT, maxWidth = WIDTH, maxHeight = HEIGHT,
        resizable = false, movable = false, footer = true, closeButton = true, appearanceControls = false,
        minimizeMode = "compact", boundaryMode = "free",
        statePolicy = { defaultWidth = WIDTH, defaultHeight = HEIGHT, minWidth = WIDTH, minHeight = HEIGHT, maxWidth = WIDTH, maxHeight = HEIGHT,
            defaultLocked = true, defaultOverallOpacity = 0.96, defaultBackgroundOpacity = 1.0, defaultTextOpacity = 1.0 },
        getState = function() return instance.state end,
        setState = function(value)
            if type(value) ~= "table" then return false, "sidecar state invalid" end
            CopyState(instance.state, value); instance.state.locked = true; return true
        end,
        persist = function() return true end,
        onClosed = function(_, reason)
            Controller.dismissed = true
            return Host:NotifyWindowClosed(WIDGET_ID, { persist = false, source = tostring(reason or "craft_sidecar_close") })
        end,
    })
    if surface == nil then return nil, surfaceErr or "制作台助手侧窗创建失败" end
    instance.surface, instance.shell, instance.windowController = surface, surface.shell, surface.windowController

    local content = surface:GetContentRoot()
    local root = RSUI:VerticalBox({ id = "v3_craft_sidecar_content", parent = content, gap = 5,
        slot = { size = "fill", fill = 1, hAlign = "fill", vAlign = "fill" } })
    local recipeRow = RSUI:HorizontalBox({ id = "v3_craft_sidecar_recipe_row", parent = root, gap = 4,
        slot = { size = "fixed", height = 31, hAlign = "fill" } })
    instance.recipe = RSUI:Dropdown({ id = "v3_craft_sidecar_recipe", parent = recipeRow, items = {}, maxVisible = 12, popupWidth = 300,
        get = function() return (Feature:GetProjection() or {}).selectedRecipeKey end,
        set = function(value)
            if type(Feature.Commands.SelectRecipe) ~= "function" then return false, "制作物选择命令不可用" end
            local ok, err = Feature.Commands:SelectRecipe(value); if ok == true then instance:Refresh() end; return ok, err
        end,
        placeholder = "选择制作物", slot = { size = "fill", fill = 1, minWidth = 180 } })
    instance.refresh = RSUI:Button({ id = "v3_craft_sidecar_refresh", parent = recipeRow, text = "刷新", compact = true, slot = { size = "fixed", width = 52 } })
    instance.quote = RSUI:Button({ id = "v3_craft_sidecar_quote", parent = recipeRow, text = "材料询价", compact = true, enabled = false, slot = { size = "fixed", width = 76 } })

    instance.status = RSUI:Text({ id = "v3_craft_sidecar_status", parent = root,
        text = "选择制作物后显示材料；普通刷新不会自动查询拍卖行。", fontSize = 8, tone = "muted", overflow = "wrap", maxLines = 2,
        slot = { size = "fixed", height = 30, hAlign = "fill" } })

    instance.table = RSUI:TableView({
        id = "v3_craft_sidecar_table", parent = root, items = {}, rowHeight = 27, headerHeight = 26,
        desiredRows = 10, overscan = 1, scrollbar = true, selectable = false, columnResize = false, headerInteractive = false,
        getKey = function(item) return item and item.key or nil end,
        columns = {
            { id = "name", title = "材料", field = "name", size = "fill", minWidth = 132, fill = 1.6 },
            { id = "need", title = "需", field = "need", size = "fixed", width = 44, minWidth = 36 },
            { id = "held", title = "有", field = "held", size = "fixed", width = 44, minWidth = 36 },
            { id = "shortage", title = "缺", field = "shortage", size = "fixed", width = 44, minWidth = 36 },
        },
        slot = { size = "fill", fill = 1, hAlign = "fill", vAlign = "fill" },
    })
    if root == nil or instance.recipe == nil or instance.refresh == nil or instance.quote == nil or instance.status == nil or instance.table == nil then
        return nil, "制作台助手侧窗控件构建失败"
    end

    instance.refresh.onClick = function()
        local ok, err = Feature.Commands:Refresh("craft_sidecar_manual")
        instance.status:SetText(ok == true and "已刷新制作材料" or ("刷新失败：" .. tostring(err or "未执行")))
        if ok == true then instance:Refresh() end
        return ok, err
    end
    instance.quote.onClick = function()
        if type(Feature.Commands.QuotePendingMaterials) ~= "function" then return false, "材料询价命令不可用" end
        local ok, message = Feature.Commands:QuotePendingMaterials()
        instance.status:SetText(ok == true and tostring(message or "询价已提交") or ("询价失败：" .. tostring(message or "未执行")))
        if ok == true then instance:Refresh() end
        return ok, message
    end

    function instance:ApplyAnchor(snapshot)
        if type(snapshot) == "table" then Controller.snapshot = snapshot end
        local nextX, nextY = SidecarPosition(Controller.snapshot)
        self.state.userMoved = true; self.state.coordinateSpace = "logical-free-v2"
        self.state.x, self.state.y, self.state.width, self.state.height = nextX, nextY, WIDTH, HEIGHT
        return self.surface:ApplyLayout(false)
    end

    function instance:Refresh()
        local projection = Feature:GetProjection() or {}
        self.recipe.items = type(projection.recipeOptions) == "table" and projection.recipeOptions or {}
        if type(self.recipe.Render) == "function" then self.recipe:Render() end
        local rows = MaterialRows(projection)
        self.table:SetItems(rows, "craft-sidecar:" .. tostring(projection.revision or 0))
        if #rows == 0 then self.table:SetViewState("empty", { title = "暂无材料", detail = "先选择制作物，再读取材料与背包持有量。" }) else self.table:SetViewState("ready") end
        local pending = math.max(0, tonumber(projection.pendingQuoteCount) or 0)
        self.quote:SetEnabled(pending > 0)
        self.quote:SetText(pending > 0 and ("询价(" .. tostring(pending) .. ")") or "材料询价")
        local craft = type(projection.craft) == "table" and projection.craft or {}
        local status = tostring(craft.status or projection.status or "idle")
        self.surface:SetStatus((Controller.snapshot and Controller.snapshot.kind and ("制作窗:" .. tostring(Controller.snapshot.kind) .. " · ") or "") .. status .. " · 材料 " .. tostring(#rows), (status == "failed" or status == "unavailable") and "orange" or "muted")
        return true
    end

    function instance:Subscribe()
        if self.subscribed == true then return true end
        if S.Events ~= nil and type(S.Events.SubscribeInternal) == "function" then
            S.Events:SubscribeInternal(Feature.UpdateTopic, self, function() if instance.visible == true then instance:Refresh() end end)
        end
        self.subscribed = true; return true
    end
    function instance:Unsubscribe()
        if self.subscribed ~= true then return true end
        if S.Events ~= nil and type(S.Events.UnsubscribeInternalOwner) == "function" then S.Events:UnsubscribeInternalOwner(self) end
        self.subscribed = false; return true
    end
    function instance:Show(context)
        context = type(context) == "table" and context or {}
        if type(context.snapshot) == "table" then Controller.snapshot = context.snapshot end
        self:ApplyAnchor(Controller.snapshot)
        if self.visible == true then self:Refresh(); return self.surface:Show(true) end
        self:Subscribe()
        local acquired, acquireErr = Feature:AcquireConsumer("widget:craft_sidecar")
        if acquired ~= true then self:Unsubscribe(); return false, acquireErr or "制作台助手侧窗 Consumer 获取失败" end
        self.acquired = true; self:Refresh()
        local shown, showErr = self.surface:Show(true)
        if shown ~= true then Feature:ReleaseConsumer("widget:craft_sidecar"); self.acquired = false; self:Unsubscribe(); return false, showErr or "制作台助手侧窗显示失败" end
        self.visible = true; return true
    end
    function instance:Hide()
        local hidden, hideErr = self.surface:Show(false)
        if hidden ~= true then return false, hideErr end
        if self.acquired == true then Feature:ReleaseConsumer("widget:craft_sidecar") end
        self.acquired = false; self.visible = false; self:Unsubscribe(); return true
    end
    function instance:OnWindowClosed()
        if self.acquired == true then Feature:ReleaseConsumer("widget:craft_sidecar") end
        self.acquired = false; self.visible = false; self:Unsubscribe(); return true
    end
    function instance:Open(context) return self:Show(context) end
    function instance:Close(context) return self:Hide(context) end
    function instance:ApplyLayout(fromMetricsChange) return self.surface:ApplyLayout(fromMetricsChange == true) end
    return instance
end

local registered, registerErr = Host:Register(WIDGET_ID, {
    featureId = "tools_craft", create = CreateSidecar,
    ensurePreferences = function() return Feature:Initialize() end,
    lockable = false, minimizable = false, resettable = false,
    opacityAdjustable = false, backgroundOpacityAdjustable = false, textOpacityAdjustable = false,
})
if registered ~= true then error(registerErr) end

local function OnSurface(snapshot)
    snapshot = type(snapshot) == "table" and snapshot or {}
    local wasVisible = Controller.nativeVisible == true
    local projection = Feature:GetProjection() or {}
    Controller.nativeVisible = S.FeatureRuntime ~= nil and S.FeatureRuntime:IsEnabled("tools_craft") == true
        and projection.autoSidecar ~= false and snapshot.status == "ready" and snapshot.visible == true
    Controller.snapshot = snapshot
    if Controller.nativeVisible ~= true then
        if snapshot.status == "ready" and snapshot.visible ~= true then Controller.dismissed = false end
        if Host:IsVisible(WIDGET_ID) == true then Host:SetVisible(WIDGET_ID, false, { persist = false, source = "craft_native_close" }) end
        return true
    end
    if wasVisible ~= true then Controller.dismissed = false end
    if Controller.dismissed == true then return true end
    if Host:IsVisible(WIDGET_ID) ~= true then
        local shown = Host:SetVisible(WIDGET_ID, true, { persist = false, source = "craft_native_open", snapshot = snapshot })
        if shown ~= true then return false end
    end
    local instance = Host:GetInstance(WIDGET_ID)
    if type(instance) == "table" and type(instance.ApplyAnchor) == "function" then return instance:ApplyAnchor(snapshot) end
    return true
end

if S.Events ~= nil and type(S.Events.SubscribeInternal) == "function" then
    S.Events:SubscribeInternal(SurfaceService.topic or "v3.craft_surface.updated", Controller, function(_, snapshot) return OnSurface(snapshot) end)
end
OnSurface(SurfaceService:GetSnapshot())
