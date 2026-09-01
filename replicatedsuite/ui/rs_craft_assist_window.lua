------------------------------------------------------------------------
-- Replicated Suite - Craft Station Material Assist window (P1-3)
-- Author: Replicated
--
-- Attached panel shown while a craft station is open. Lists the packs
-- producible in the current zone group; the top row cycles through packs
-- (< >), and each material row shows 名称/需X/有Y plus the P1-2 取/放/拍
-- buttons (directed BagOrganizer move + auction favorites chain).
--
-- Structure follows the auction-favorites window (plain window, × close,
-- system layer). Anchor: left of the detected craft station when its native
-- rect is readable, otherwise a fixed safe position on the right edge.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
S.CraftAssistWindow = {
    window = nil, rows = {}, packIndex = 1, scrollOffset = 0,
    packPrev = nil, packNext = nil, packLabel = nil, refresh = nil, hint = nil,
    sessionDismissed = false, -- H3: the player's own × disarms auto-show until the next session
}
local W = S.CraftAssistWindow

local PANEL_W = 560
local PANEL_H = 430
local MIN_W = 420
local MAX_W = 840
local MIN_H = 320
local MAX_H = 680
local DEFAULT_W = 560
local DEFAULT_H = 430
local ROWS = 12
local ROW_H = 24
local TITLE_Y = 9
local PACK_Y = 40
local HEADER_Y = 70
local LIST_Y = 92
local BOTTOM_Y = 338
local NAME_W = 150

-- G2: persisted window size from settings (clamped in rs_state).
local function WindowSize()
    local craft = (S.State and S.State.settings and S.State.settings.craftAssist) or {}
    local w = math.floor(tonumber(craft.width) or DEFAULT_W)
    local h = math.floor(tonumber(craft.height) or DEFAULT_H)
    return math.max(MIN_W, math.min(MAX_W, w)), math.max(MIN_H, math.min(MAX_H, h))
end

-- G2: pure visible-row-count adaptivity. floor((height - topOccupancy) / rowH),
-- capped at the pool size. Zero side effects, unit-testable.
function W:VisibleRowCount(height)
    height = tonumber(height)
    if height == nil then return ROWS end
    local top = LIST_Y -- header + pack row + title occupy up to LIST_Y
    local bottom = PANEL_H - BOTTOM_Y -- hint/diagnose row reserve
    local usable = height - top - bottom
    local n = math.max(1, math.floor(usable / ROW_H))
    return math.min(ROWS, n)
end

local function Service()
    return S.Services and S.Services.CraftAssist or nil
end

local function TruncateName(text, byteLimit) return S.Utils.TruncateUtf8(text, byteLimit, "…") end

-- Bug 3: material buttons act on the flat list entry at the visible row index.
local function RowMaterial(i)
    local svc = Service()
    if svc == nil then return nil end
    local allRows = type(svc.BuildAllRows) == "function"
        and svc:BuildAllRows(svc:GetPacks(), svc.bagCountByType, svc.lastZoneGroup) or {}
    local entry = allRows[W.scrollOffset + i]
    if entry == nil or entry.type ~= "material" then return nil end
    return entry
end

local function MaterialMove(i, direction)
    local mat = RowMaterial(i)
    if mat == nil then return end
    local bo = S.Services and S.Services.BagOrganizer
    if bo == nil or type(bo.Begin) ~= "function" then S.SafeChat("整理背包服务尚未就绪"); return end
    local itemType = tonumber(mat.itemType)
    if itemType == nil then
        S.SafeChat("该材料无物品ID（静态配方无 itemType 映射），无法" .. (direction == "withdraw" and "取出" or "放入") .. "。")
        return
    end
    local ok, count = bo:Begin(direction, { itemType = itemType })
    if ok ~= true then return end
    local planned = tonumber(count) or 0
    if planned <= 0 then
        S.SafeChat(direction == "withdraw" and "未找到仓库中与背包同身份且为该材料的物品。" or "未找到背包中与仓库同身份且为该材料的物品。")
    end
end

local function MaterialAuction(i)
    local mat = RowMaterial(i)
    if mat == nil then return end
    local fav = S.Services and S.Services.AuctionFavorites
    if fav == nil then S.SafeChat("拍卖收藏夹服务尚未就绪"); return end
    -- Official CN display name is the temp-row text AND the search keyword.
    -- mat.name (EN) is identity only and never appears in UI/search (F1).
    local official
    if type(fav.ResolveOfficialName) == "function" then
        official = fav:ResolveOfficialName(mat.itemType, mat.displayName or mat.name)
    else
        official = mat.displayName or mat.name
    end
    if official == nil or tostring(official) == "" then S.SafeChat("该材料缺少官方名称。"); return end
    local okPush, pushErr = fav:PushTemp(official)
    if okPush ~= true and pushErr ~= nil then S.SafeChat("加入临时搜索失败：" .. tostring(pushErr)) end
    local ui = S.AuctionFavoritesWindow
    if ui ~= nil and type(ui.Show) == "function" then
        if type(ui.Create) == "function" then ui:Create() end
        ui:Show(true)
        if type(ui.SetMode) == "function" then ui:SetMode("temp") end
        if type(ui.RefreshList) == "function" then ui:RefreshList(true) end
    end
end

function W:Create()
    if self.window ~= nil then return self.window end
    if type(CreateEmptyWindow) ~= "function" or S.UI == nil then return nil end

    local panel = CreateEmptyWindow(S.PhysicalId("craft_assist_window"), "UIParent")
    if panel == nil then return nil end
    local savedW, savedH = WindowSize()
    panel:SetExtent(savedW, savedH)
    -- Enable() is REQUIRED for drag picking on this client: every draggable
    -- Suite window (main / trade_detail / daily_custom / quest_detail /
    -- widget_base) calls window:Enable(true), and without it the native window
    -- does not dispatch input to child widgets, so the title bar's
    -- OnDragStart never fires even though the window renders. (2026-08-24)
    if panel.Enable ~= nil then pcall(function() panel:Enable(true) end) end
    if panel.Clickable ~= nil then pcall(function() panel:Clickable(true) end) end
    if panel.SetCloseOnEscape ~= nil then pcall(function() panel:SetCloseOnEscape(true) end) end
    S.UI:TrySetUILayer(panel, "system")
    if panel.SetDrawPriority ~= nil then pcall(function() panel:SetDrawPriority(12100) end) end
    S.Theme:AddBorder(panel, false)
    S.Theme:AddGradientBackground(panel, "card", nil)
    S.Theme:SetOpacity(panel, 1.0)

    -- G2: draggable title bar (mature trade-detail pattern). Position persists
    -- through S.Layout floating storage; BeginSafeMove clamps on-screen.
    local titleBar = S.UI:CreatePanel(panel, "craft_assist_titlebar", 1, 1, savedW - 2, 30, "header")
    self.titleBar = titleBar
    S.UI:CreateLabel(titleBar, "craft_assist_title", "制作台材料助手", 10, 4, savedW - 90, 22, 14, "accent", ALIGN_LEFT, true)
    local close = S.UI:CreateButton(titleBar, "craft_assist_close", "×", savedW - 38, 3, 26, 24, 13, false, true)
    self.close = close
    -- Match the exact proven drag surface of the working windows (main /
    -- trade_detail / daily_custom / quest_detail): Enable + EnableDrag +
    -- Clickable, and crucially NO EnablePick on the drag surface itself. The
    -- earlier EnablePick(true, true) here made the panel the only drag surface
    -- in the whole Suite that called it, and on the live client the title bar
    -- then never received the drag pickup. (2026-08-24)
    if type(titleBar.Enable) == "function" then titleBar:Enable(true) end
    if type(titleBar.EnableDrag) == "function" then titleBar:EnableDrag(true) end
    if type(titleBar.Clickable) == "function" then titleBar:Clickable(true) end
    if titleBar.SetDragCondition ~= nil and DC_ALWAYS ~= nil then
        pcall(function() titleBar:SetDragCondition(DC_ALWAYS) end)
    end
    S.UI:SafeHandler(titleBar, "OnDragStart", function()
        titleBar.rsSafeMoving = S.Layout ~= nil and type(S.Layout.BeginSafeMove) == "function"
            and S.Layout:BeginSafeMove("craft_assist", panel, { clamp = true }) == true
        if titleBar.rsSafeMoving == true then return true end
        if type(panel.StartMoving) ~= "function" then return false end
        panel:StartMoving(); return true
    end, "craft_assist:drag_start")
    S.UI:SafeHandler(titleBar, "OnDragStop", function()
        if titleBar.rsSafeMoving == true and S.Layout ~= nil and type(S.Layout.EndSafeMove) == "function" then
            S.Layout:EndSafeMove("craft_assist", false)
        elseif type(panel.StopMovingOrSizing) == "function" then
            panel:StopMovingOrSizing()
        end
        titleBar.rsSafeMoving = false
        if S.Layout ~= nil and type(S.Layout.EnsureWidgetVisible) == "function" then
            S.Layout:EnsureWidgetVisible(panel, { onlyWhenVisible = false })
        end
        return true
    end, "craft_assist:drag_stop")

    -- Top row: list title (full width; the list scrolls via the mouse wheel,
    -- Bug2/R3 -- no < > page buttons).
    self.packLabel = S.UI:CreateLabel(panel, "craft_assist_pack_name", "--", 12, PACK_Y + 2, savedW - 108, 22, 11, nil, ALIGN_LEFT)
    self.refresh = S.UI:CreateButton(panel, "craft_assist_refresh", "刷新", savedW - 90, PACK_Y, 24, 24, 9, false, true)

    S.UI:CreateLabel(panel, "craft_assist_header", "材料                    需        有      操作", 12, HEADER_Y, savedW - 24, 20, 9, "muted", ALIGN_LEFT)

    self.rows = {}
    for i = 1, ROWS do
        local y = LIST_Y + (i - 1) * ROW_H
        self.rows[i] = {
            name = S.UI:CreateLabel(panel, "craft_assist_mat_name_" .. i, "", 12, y, NAME_W, 20, 10, nil, ALIGN_LEFT),
            need = S.UI:CreateLabel(panel, "craft_assist_mat_need_" .. i, "", 12 + NAME_W, y, 44, 20, 10, "muted", ALIGN_RIGHT),
            have = S.UI:CreateLabel(panel, "craft_assist_mat_have_" .. i, "", 12 + NAME_W + 46, y, 44, 20, 10, "green", ALIGN_RIGHT),
            take = S.UI:CreateButton(panel, "craft_assist_mat_take_" .. i, "取", 12 + NAME_W + 92, y, 32, 22, 9, false),
            put = S.UI:CreateButton(panel, "craft_assist_mat_put_" .. i, "放", 12 + NAME_W + 128, y, 32, 22, 9, false),
            auc = S.UI:CreateButton(panel, "craft_assist_mat_auc_" .. i, "拍", 12 + NAME_W + 164, y, 32, 22, 9, false),
        }
        for _, c in pairs(self.rows[i]) do
            if type(c.Show) == "function" then c:Show(false) end
        end
        S.UI:SafeHandler(self.rows[i].take, "OnClick", function() MaterialMove(i, "withdraw") end, "craft_assist:mat_" .. i .. "_take")
        S.UI:SafeHandler(self.rows[i].put, "OnClick", function() MaterialMove(i, "deposit") end, "craft_assist:mat_" .. i .. "_put")
        S.UI:SafeHandler(self.rows[i].auc, "OnClick", function() MaterialAuction(i) end, "craft_assist:mat_" .. i .. "_auc")
    end

    self.hint = S.UI:CreateLabel(panel, "craft_assist_hint", "", 12, BOTTOM_Y, savedW - 108, 22, 9, "muted", ALIGN_LEFT)
    -- F2: detection diagnostic (click-triggered, never polled). Outputs the
    -- visible UIC enumeration to chat so the real craft-station constant can be
    -- identified on the live client.
    self.diagnose = S.UI:CreateButton(panel, "craft_assist_diagnose", "检测诊断", savedW - 92, BOTTOM_Y, 80, 22, 8, false, true)

    -- G2: bottom-right resize handle ("◢" 16x16). Uses the engine sizing API
    -- guarded by pcall; on stop, clamps and persists the size, then re-lays out.
    self.resize = S.UI:CreateButton(panel, "craft_assist_resize", "◢", savedW - 20, savedH - 20, 16, 16, 8, false, true)
    if self.resize.Enable ~= nil then self.resize:Enable(true) end
    if self.resize.EnableDrag ~= nil then self.resize:EnableDrag(true) end
    if self.resize.SetDragCondition ~= nil and DC_ALWAYS ~= nil then
        pcall(function() self.resize:SetDragCondition(DC_ALWAYS) end)
    end
    S.UI:SafeHandler(self.resize, "OnDragStart", function()
        if type(panel.StartSizing) == "function" then
            pcall(function() panel:StartSizing("BOTTOMRIGHT") end)
        end
        return true
    end, "craft_assist:resize_start")
    S.UI:SafeHandler(self.resize, "OnDragStop", function()
        if type(panel.StopMovingOrSizing) == "function" then
            pcall(function() panel:StopMovingOrSizing() end)
        end
        local w, h = nil, nil
        if type(panel.GetExtent) == "function" then
            local ow = panel:GetExtent()
            if type(ow) == "table" then w, h = tonumber(ow[1]), tonumber(ow[2]) end
        end
        if (w == nil or h == nil) and type(panel.GetWidth) == "function" and type(panel.GetHeight) == "function" then
            w, h = tonumber(panel:GetWidth()), tonumber(panel:GetHeight())
        end
        w = math.max(MIN_W, math.min(MAX_W, w or savedW))
        h = math.max(MIN_H, math.min(MAX_H, h or savedH))
        local craft = (S.State and S.State.settings and S.State.settings.craftAssist) or {}
        if type(craft) == "table" then
            craft.width = w
            craft.height = h
        end
        if S.Storage ~= nil and type(S.Storage.RequestSave) == "function" then S.Storage:RequestSave() end
        W:ApplyLayout()
    end, "craft_assist:resize_stop")

    -- H3: the player's own close disarms the auto-show until the next craft
    -- session (BeginSession resets it). The service keeps the carried work
    -- order alive when the native Craft Book closes, but never re-opens a
    -- window the player explicitly dismissed.
    S.UI:SafeHandler(close, "OnClick", function()
        W.sessionDismissed = true
        panel:Show(false)
        -- Reset the service-side session so the NEXT craft-station open goes
        -- through the full approval path again (2026-08-24: without this, the
        -- service kept approved+visible=true, the stable-follow watcher
        -- short-circuited, and the panel never reappeared on the second open).
        local svc = Service()
        if svc ~= nil and type(svc.OnSidecarDismissed) == "function" then svc:OnSidecarDismissed() end
    end, "craft_assist:close")
    S.UI:SafeHandler(panel, "OnCloseByEsc", function()
        W.sessionDismissed = true
        panel:Show(false)
        local svc = Service()
        if svc ~= nil and type(svc.OnSidecarDismissed) == "function" then svc:OnSidecarDismissed() end
    end, "craft_assist:esc")
    -- Bug 2: the list is a scroll box -- mouse wheel scrolls it.
    S.UI:SafeHandler(panel, "OnWheelUp", function() W:Page(-1) end, "craft_assist:wheel_up")
    S.UI:SafeHandler(panel, "OnWheelDown", function() W:Page(1) end, "craft_assist:wheel_down")
    S.UI:SafeHandler(self.refresh, "OnClick", function()
        local svc = Service(); if svc == nil then return end
        svc:ManualRefresh()
        W:Refresh()
    end, "craft_assist:refresh")
    S.UI:SafeHandler(self.diagnose, "OnClick", function()
        local svc = Service(); if svc == nil then return end
        if type(svc.DiagnoseCraftDetection) == "function" then
            svc:DiagnoseCraftDetection()
        else
            S.SafeChat("制作台诊断服务尚未就绪")
        end
    end, "craft_assist:diagnose")

    self.window = panel
    panel:Show(false)
    -- G2: position persistence via the shared floating registry; the panel is a
    -- plain window (no HudManager, per G-batch rule).
    if S.Layout ~= nil and type(S.Layout.RegisterFloating) == "function" and self.registered ~= true then
        S.Layout:RegisterFloating("craft_assist", panel, {
            onlyWhenVisible = true,
            ensureNow = false,
            onMetricsChanged = function(changed)
                if changed == true then W:ApplyLayout()
                else S.Layout:EnsureWidgetVisible(panel, { onlyWhenVisible = true }) end
            end,
        })
        self.registered = true
    end
    self:ApplyLayout()
    return panel
end

function W:CyclePack(delta)
    local svc = Service()
    local packs = svc and svc:GetPacks() or {}
    if #packs == 0 then return end
    local next = ((W.packIndex - 1 + (tonumber(delta) or 1)) % #packs) + 1
    W.packIndex = next
    W.scrollOffset = 0
    W:Refresh()
end

-- Bug 3: list view paging. The < > buttons page through the flat all-packs
-- list (pack headers + material rows) instead of switching a single pack.
function W:Page(delta)
    local svc = Service()
    local allRows = svc and type(svc.BuildAllRows) == "function"
        and svc:BuildAllRows(svc:GetPacks(), svc.bagCountByType, svc.lastZoneGroup) or {}
    local _, curH = WindowSize()
    local visibleRows = self:VisibleRowCount(curH)
    local maxOffset = math.max(0, #allRows - visibleRows)
    self.scrollOffset = math.max(0, math.min(maxOffset, (self.scrollOffset or 0) + (tonumber(delta) or 0)))
    self:Refresh()
end

function W:CurrentAssembled()
    local svc = Service()
    if svc == nil then return nil end
    local packs = svc:GetPacks()
    local pack = packs[W.packIndex]
    if pack == nil then return nil end
    return svc:AssembleRows(packs, pack.name, svc.bagCountByType, svc.lastZoneGroup)
end

function W:Refresh()
    local svc = Service()
    if svc ~= nil and type(svc.stats) == "table" then
        svc.stats.windowRefresh = (svc.stats.windowRefresh or 0) + 1
    end
    local panel = self:Create()
    if panel == nil then return end
    local packs = svc and svc:GetPacks() or {}
    local _, curH = WindowSize()
    local visibleRows = self:VisibleRowCount(curH)

    -- Bug 3: flat all-packs list (pack headers + material rows), paged.
    local allRows = svc and type(svc.BuildAllRows) == "function"
        and svc:BuildAllRows(packs, svc.bagCountByType, svc.lastZoneGroup) or {}
    local maxOffset = math.max(0, #allRows - visibleRows)
    self.scrollOffset = math.max(0, math.min(self.scrollOffset or 0, maxOffset))

    if self.packLabel ~= nil then
        if #packs > 0 then
            self.packLabel:SetText(string.format("当前产区特产（%d 种，共 %d 行，滚轮滚动）", #packs, #allRows))
        else
            self.packLabel:SetText("当前区域无特产列表")
        end
    end

    for i, row in ipairs(self.rows) do
        local entry = allRows[self.scrollOffset + i]
        -- H3 (2026-08-24, second round): rows beyond the height-adaptive
        -- visible window must stay hidden. Without the i <= visibleRows cap
        -- the 11th/12th pool rows rendered at LIST_Y + 10*ROW_H and collided
        -- with the hint row placed at LIST_Y + visibleRows*ROW_H + 4 (the
        -- "滚轮滚动查看全部材料" text overlapped material text).
        local show = entry ~= nil and i <= visibleRows
        row.name:Show(show); row.need:Show(show); row.have:Show(show)
        row.take:Show(show); row.put:Show(show); row.auc:Show(show)
        if show then
            if entry.type == "pack" then
                -- pack header row: full-width name (no truncation, Bug 3),
                -- buttons fully hidden (it is the thing being crafted, not a
                -- material -- Bug 4).
                row.name:SetText("【" .. tostring(entry.name) .. "】")
                row.need:SetText(""); row.have:SetText("")
                row.take:Show(false); row.put:Show(false); row.auc:Show(false)
            else
                -- Official name: runtime bag/storage read first (client returns
                -- the official localized name), then the static ZH fallback.
                local official = entry.displayName or entry.name
                local fav = S.Services and S.Services.AuctionFavorites
                if fav ~= nil and type(fav.ResolveOfficialName) == "function" then
                    official = fav:ResolveOfficialName(entry.itemType, official)
                    if svc ~= nil and type(svc.stats) == "table" then
                        svc.stats.officialNameScans = (svc.stats.officialNameScans or 0) + 1
                    end
                end
                row.name:SetText(TruncateName(official, 22))
                row.need:SetText("需" .. tostring(entry.count or 0))
                row.have:SetText("有" .. tostring(entry.bagCount or 0))
                local canMove = tonumber(entry.itemType) ~= nil
                if row.take.Enable ~= nil then row.take:Enable(canMove) end
                if row.put.Enable ~= nil then row.put:Enable(canMove) end
            end
        end
    end

    if self.hint ~= nil then
        local svcText = svc and svc.lastError or nil
        if svcText ~= nil then
            self.hint:SetText(svcText)
        elseif #packs == 0 then
            self.hint:SetText("打开制作台后自动读取当前产区特产；点“刷新”重试")
        else
            self.hint:SetText("滚轮滚动查看全部材料")
        end
    end
end

-- G2: re-layout from the persisted window size (called on open and after
-- resize). Repositions every child to the current width/height; rows use the
-- height-adaptive visible count. C10: all sizes are logical, scaled by the
-- engine layout as usual.
function W:ApplyLayout()
    local panel = self:Create()
    if panel == nil then return end
    local w, h = WindowSize()
    panel:SetExtent(w, h)
    if self.titleBar ~= nil and self.titleBar.SetExtent ~= nil then self.titleBar:SetExtent(w - 2, 30) end
    if self.close ~= nil and self.close.SetExtent ~= nil then self.close:SetExtent(26, 24); S.UI:SetAnchor(self.close, self.titleBar, w - 38, 3) end
    if self.packLabel ~= nil and self.packLabel.SetExtent ~= nil then self.packLabel:SetExtent(w - 108, 22) end
    if self.refresh ~= nil and self.refresh.SetExtent ~= nil then S.UI:SetAnchor(self.refresh, panel, w - 90, PACK_Y) end
    -- hint and diagnose share the bottom row, placed right below the last
    -- visible material row so they can never overlap the list (Bug: fixed
    -- BOTTOM_Y collided with rows once the window grew past ~11 rows).
    local visibleRows = self:VisibleRowCount(h)
    local bottomRowY = LIST_Y + visibleRows * ROW_H + 4
    if self.hint ~= nil and self.hint.SetExtent ~= nil then
        self.hint:SetExtent(w - 200, 22)
        S.UI:SetAnchor(self.hint, panel, 12, bottomRowY)
    end
    if self.diagnose ~= nil and self.diagnose.SetExtent ~= nil then S.UI:SetAnchor(self.diagnose, panel, w - 92, bottomRowY) end
    if self.resize ~= nil and self.resize.SetExtent ~= nil then S.UI:SetAnchor(self.resize, panel, w - 20, h - 20) end
    self:Refresh()
end

-- H3: a new craft session re-arms the auto-show after the player dismissed it.
function W:BeginSession()
    self.sessionDismissed = false
end

function W:ApplyAnchor(craftRect)
    local panel = self:Create()
    if panel == nil then return end
    if panel.RemoveAllAnchors ~= nil then panel:RemoveAllAnchors() end
    local context = S.Layout and S.Layout:GetContext() or {}
    local logicalW = tonumber(context.logicalWidth) or 1024
    local logicalH = tonumber(context.logicalHeight) or 768
    local edge = math.max(6, tonumber(context.safeTop) or 10)
    local scale = tonumber(context.addonScale) or 1
    local savedW, savedH = WindowSize()
    local panelW = math.floor(savedW * scale + 0.5)
    local panelH = math.floor(savedH * scale + 0.5)
    local x, y
    local rect = craftRect
    if type(rect) ~= "table" then
        local svc = Service()
        rect = svc and type(svc.GetOpenRect) == "function" and svc:GetOpenRect() or nil
    end
    if type(rect) == "table" then
        x = (tonumber(rect.x) or 0) - panelW - math.floor(6 * scale)
        y = tonumber(rect.y) or edge
        if S.Layout and type(S.Layout.ClampTopLeft) == "function" then
            x, y = S.Layout:ClampTopLeft(x, y, panelW, panelH, { edge = edge })
        else
            x = math.max(edge, math.min(x, math.max(edge, logicalW - edge - panelW)))
            y = math.max(edge, math.min(y, math.max(edge, logicalH - edge - panelH)))
        end
    else
        -- No readable station rect: fixed safe position on the right edge.
        x = math.max(edge, logicalW - edge - panelW)
        y = math.max(edge, math.floor((logicalH - panelH) / 2))
    end
    panel:AddAnchor("TOPLEFT", "UIParent", math.floor(x + 0.5), math.floor(y + 0.5))
end

function W:OnDataChanged()
    local panel = self:Create()
    if panel == nil then return end
    self:Refresh()
end

function W:OnClosed()
    if self.window ~= nil then self.window:Show(false) end
end

function W:Close()
    if self.window ~= nil then self.window:Show(false) end
end

function W:Show(visible, craftRect)
    local panel = self:Create()
    if panel == nil then return end
    self:ApplyLayout()
    self:ApplyAnchor(craftRect)
    panel:Show(visible == true)
    if visible == true then
        self:Refresh()
        if panel.Raise ~= nil then pcall(function() panel:Raise() end) end
    end
end
