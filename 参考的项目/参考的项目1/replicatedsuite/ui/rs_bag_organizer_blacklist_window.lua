------------------------------------------------------------------------
-- Replicated Suite - Bag Organizer blacklist management window
-- Author: Replicated
--
-- Plain popup (not a HUD): lists the items of the currently open bank/coffer
-- and lets the player block/unblock whole categories or single items per
-- storage kind. Persistence is the Suite account settings tree
-- (S.State.settings.bagOrganizerBlacklist) - never ADDON:SaveData.
--
-- List model: one merged scrollable list, category rows first, item rows
-- after them, sharing scrollOffset and the page label. Both wheel and the
-- bottom ▲/▼ buttons scroll (buttons are the guaranteed channel because the
-- wheel event is not verified on this engine).
--
-- Refresh policy:
--   * Full scan happens only on explicit user actions (Show / toggle click /
--     storage-kind change).
--   * While visible, a 400 ms light watcher reads native storage visibility
--     only (same class of getter as the service's 150 ms floating-bar
--     watcher). It re-scans the open storage only when the kind changed.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
S.BagOrganizerBlacklistWindow = {
    window = nil, rows = {}, scrollOffset = 0,
    kind = nil, items = {}, categoryList = {}, merged = {},
    storageLabel = nil, pageLabel = nil, emptyLabel = nil,
}
local W = S.BagOrganizerBlacklistWindow

local PANEL_W = 336
local PANEL_H = 390
local ROWS = 10
local ROW_H = 26
local LIST_Y = 86
local BOTTOM_Y = 352
local TASK_KIND = "bag_organizer_blacklist_kind"

local function Service()
    return S.Services and S.Services.BagOrganizer or nil
end

local function Blacklist()
    if S.State ~= nil and type(S.State.settings) == "table" then
        local blacklist = S.State.settings.bagOrganizerBlacklist
        if type(blacklist) ~= "table" then
            blacklist = { enabled = false, bank = { categories = {}, items = {} }, coffer = { categories = {}, items = {} } }
            S.State.settings.bagOrganizerBlacklist = blacklist
        end
        return blacklist
    end
    return { enabled = false, bank = { categories = {}, items = {} }, coffer = { categories = {}, items = {} } }
end

local function StorageName(kind)
    return kind == "coffer" and "箱子" or (kind == "bank" and "仓库" or "关闭")
end

-- Category display names from S.Data.CategoryNames (data/rs_category_names.lua,
-- loaded before ui/ in toc). Resolved at runtime so a missing data file can
-- never break the window: falls back to the raw id.
local function CategoryName(id)
    local data = ReplicatedSuite and ReplicatedSuite.Data and ReplicatedSuite.Data.CategoryNames
    if data ~= nil and type(data.Name) == "function" then return data.Name(id) end
    return tostring(id or "")
end

-- UTF-8 safe byte truncation: never splits a multi-byte sequence, keeps long
-- game item names inside the row button without relying on engine ellipsis.
local function Truncate(text, byteLimit) return S.Utils.TruncateUtf8(text, byteLimit) end

local function ToggleItemBlocked(kind, entry)
    local blacklist = Blacklist()
    local scope = type(blacklist[kind]) == "table" and blacklist[kind] or nil
    if scope == nil then scope = { categories = {}, items = {} }; blacklist[kind] = scope end
    local items = type(scope.items) == "table" and scope.items or nil
    if items == nil then items = {}; scope.items = items end
    -- Unblock clears both key shapes: SaveData serialization may have converted
    -- the numeric key into a string, leaving a stale entry that would keep the
    -- item blocked after the user pressed 取消.
    if items[entry.itemType] == true or items[tostring(entry.itemType)] == true then
        items[entry.itemType] = nil
        items[tostring(entry.itemType)] = nil
    else
        items[entry.itemType] = true
    end
    if S.Storage ~= nil and type(S.Storage.RequestSave) == "function" then S.Storage:RequestSave() end
end

local function ToggleCategoryBlocked(kind, category)
    local blacklist = Blacklist()
    local scope = type(blacklist[kind]) == "table" and blacklist[kind] or nil
    if scope == nil then scope = { categories = {}, items = {} }; blacklist[kind] = scope end
    local categories = type(scope.categories) == "table" and scope.categories or nil
    if categories == nil then categories = {}; scope.categories = categories end
    local key = tostring(category)
    if categories[key] == true then categories[key] = nil else categories[key] = true end
    if S.Storage ~= nil and type(S.Storage.RequestSave) == "function" then S.Storage:RequestSave() end
end

function W:Create()
    if self.window ~= nil then return self.window end
    if type(CreateEmptyWindow) ~= "function" or S.UI == nil then return nil end

    local panel = CreateEmptyWindow(S.PhysicalId("bag_organizer_blacklist_window"), "UIParent")
    if panel == nil then return nil end
    panel:SetExtent(PANEL_W, PANEL_H)
    if panel.Clickable ~= nil then pcall(function() panel:Clickable(true) end) end
    if panel.SetCloseOnEscape ~= nil then pcall(function() panel:SetCloseOnEscape(true) end) end
    S.UI:TrySetUILayer(panel, "system")
    if panel.SetDrawPriority ~= nil then pcall(function() panel:SetDrawPriority(12150) end) end
    S.Theme:AddBorder(panel, false)
    S.Theme:AddGradientBackground(panel, "card", nil)
    S.Theme:SetOpacity(panel, 1.0)

    S.UI:CreateLabel(panel, "bag_organizer_blacklist_title", "黑名单管理", 12, 8, 200, 24, 14, "accent", ALIGN_LEFT, true)
    local close = S.UI:CreateButton(panel, "bag_organizer_blacklist_close", "×", 298, 7, 26, 24, 13, false, true)
    self.storageLabel = S.UI:CreateLabel(panel, "bag_organizer_blacklist_storage", "当前仓储：关闭 · 黑名单：关", 12, 36, 312, 20, 9, "muted", ALIGN_LEFT)
    S.UI:CreateLabel(panel, "bag_organizer_blacklist_hint", "类别行（整行点击）= 屏蔽整类 · 物品行用右侧按钮", 12, 60, 312, 20, 9, "muted", ALIGN_LEFT)

    self.rows = {}
    for i = 1, ROWS do
        local y = LIST_Y + (i - 1) * ROW_H
        local row = S.UI:CreateButton(panel, "bag_organizer_blacklist_row_" .. tostring(i), "", 12, y, 312, 24, 9, false, false)
        local item = S.UI:CreateButton(panel, "bag_organizer_blacklist_item_" .. tostring(i), "", 12, y, 236, 24, 9, false, false)
        local toggle = S.UI:CreateButton(panel, "bag_organizer_blacklist_item_toggle_" .. tostring(i), "屏蔽", 254, y, 70, 24, 9, false, false)
        row:Show(false); item:Show(false); toggle:Show(false)
        self.rows[i] = { row = row, item = item, toggle = toggle, index = nil, kind = nil }
    end

    local prevBtn = S.UI:CreateButton(panel, "bag_organizer_blacklist_prev", "▲", 12, BOTTOM_Y, 38, 22, 10, false, false)
    self.pageLabel = S.UI:CreateLabel(panel, "bag_organizer_blacklist_page", "", 56, BOTTOM_Y + 2, 214, 22, 10, "muted", ALIGN_CENTER)
    local nextBtn = S.UI:CreateButton(panel, "bag_organizer_blacklist_next", "▼", 286, BOTTOM_Y, 38, 22, 10, false, false)
    self.emptyLabel = S.UI:CreateLabel(panel, "bag_organizer_blacklist_empty", "", 12, 150, 312, 60, 12, nil, ALIGN_CENTER)

    S.UI:SafeHandler(close, "OnClick", function() W:Show(false) end, "bag_organizer_blacklist:close")
    S.UI:SafeHandler(panel, "OnCloseByEsc", function() W:Show(false) end, "bag_organizer_blacklist:esc")
    S.UI:SafeHandler(prevBtn, "OnClick", function()
        if W.scrollOffset > 0 then W.scrollOffset = math.max(0, W.scrollOffset - ROWS); W:RefreshList(false) end
    end, "bag_organizer_blacklist:prev")
    S.UI:SafeHandler(nextBtn, "OnClick", function()
        local maxOffset = math.max(0, #W.merged - ROWS)
        if W.scrollOffset < maxOffset then W.scrollOffset = math.min(maxOffset, W.scrollOffset + ROWS); W:RefreshList(false) end
    end, "bag_organizer_blacklist:next")
    S.UI:SafeHandler(panel, "OnWheelUp", function()
        if W.scrollOffset > 0 then W.scrollOffset = W.scrollOffset - 1; W:RefreshList(false) end
    end, "bag_organizer_blacklist:wheel_up")
    S.UI:SafeHandler(panel, "OnWheelDown", function()
        local maxOffset = math.max(0, #W.merged - ROWS)
        if W.scrollOffset < maxOffset then W.scrollOffset = W.scrollOffset + 1; W:RefreshList(false) end
    end, "bag_organizer_blacklist:wheel_down")

    self.window = panel
    panel:Show(false)
    return panel
end

function W:RefreshStorageLabel()
    local svc = Service()
    local kind = svc and svc:GetOpenStorageKind() or nil
    local blacklist = Blacklist()
    if self.storageLabel ~= nil then
        self.storageLabel:SetText("当前仓储：" .. StorageName(kind) .. " · 黑名单：" .. (blacklist.enabled == true and "开" or "关"))
    end
end

function W:ScanCurrent(kind)
    local svc = Service()
    if svc == nil or (kind ~= "bank" and kind ~= "coffer") then
        self.kind = nil
        self.items = {}
        self.categoryList = {}
        self.merged = {}
        return
    end
    local scan = svc:ScanStorage(kind)
    local items = type(scan) == "table" and scan.items or {}
    local catOrder, catCount = {}, {}
    for _, entry in ipairs(items) do
        if entry.category ~= nil and catCount[entry.category] == nil then
            catOrder[#catOrder + 1] = entry.category
        end
        catCount[entry.category] = (catCount[entry.category] or 0) + 1
    end
    local blacklist = Blacklist()
    local scope = type(blacklist[kind]) == "table" and blacklist[kind] or nil
    local categories = type(scope) == "table" and scope.categories or nil
    local categoryList = {}
    for _, cat in ipairs(catOrder) do
        categoryList[#categoryList + 1] = {
            category = cat,
            count = catCount[cat] or 0,
            blocked = type(categories) == "table" and categories[tostring(cat)] == true,
        }
    end
    self.kind = kind
    self.items = items
    self.categoryList = categoryList
    -- One merged list: category rows first, item rows after them.
    local merged = {}
    for _, catEntry in ipairs(categoryList) do
        merged[#merged + 1] = { kind = "category", ref = catEntry }
    end
    for _, entry in ipairs(items) do
        merged[#merged + 1] = { kind = "item", ref = entry }
    end
    self.merged = merged
end

-- Recompute only the category blocked flags after a toggle; merged rows hold a
-- reference to the same catEntry objects, so no list rebuild is needed. Item
-- rows read IsBlocked live on every refresh.
function W:RefreshCategoryFlags()
    local blacklist = Blacklist()
    local scope = type(blacklist[self.kind]) == "table" and blacklist[self.kind] or nil
    local categories = type(scope) == "table" and scope.categories or nil
    for _, catEntry in ipairs(self.categoryList) do
        catEntry.blocked = type(categories) == "table" and categories[tostring(catEntry.category)] == true
    end
end

function W:RefreshList(clampToEnd)
    local panel = self:Create()
    if panel == nil then return end
    local hasStorage = self.kind == "bank" or self.kind == "coffer"
    local maxOffset = math.max(0, #self.merged - ROWS)
    if clampToEnd == true and self.scrollOffset > maxOffset then self.scrollOffset = maxOffset end
    self.scrollOffset = math.max(0, math.min(self.scrollOffset, maxOffset))

    local catCount, itemCount = 0, 0
    for _, row in ipairs(self.merged) do
        if row.kind == "category" then catCount = catCount + 1 else itemCount = itemCount + 1 end
    end

    for i = 1, ROWS do
        local cell = self.rows[i]
        local row = self.merged[self.scrollOffset + i]
        if hasStorage and cell and row and row.kind == "category" then
            local catEntry = row.ref
            cell.index = self.scrollOffset + i
            cell.kind = "category"
            cell.row:SetText((catEntry.blocked and "【已屏蔽】" or "")
                .. "类别 " .. CategoryName(catEntry.category) .. " · " .. tostring(catEntry.count) .. " 件")
            cell.row:Show(true)
            cell.item:Show(false)
            cell.toggle:Show(false)
            S.UI:SafeHandler(cell.row, "OnClick", function()
                local live = W.merged[W.scrollOffset + i]
                if live == nil or live.kind ~= "category" or (W.kind ~= "bank" and W.kind ~= "coffer") then return end
                ToggleCategoryBlocked(W.kind, live.ref.category)
                W:RefreshCategoryFlags()
                W:RefreshList(false)
            end, "bag_organizer_blacklist:category_" .. tostring(i))
        elseif hasStorage and cell and row and row.kind == "item" then
            local entry = row.ref
            local svc = Service()
            local blocked = svc ~= nil and svc:IsBlocked(self.kind, entry) == true
            cell.index = self.scrollOffset + i
            cell.kind = "item"
            -- The 【已屏蔽】 prefix eats ~60px; shrink the name budget so the
            -- blocked row never overflows the 236px button.
            local nameLimit = blocked and 24 or 36
            cell.item:SetText((blocked and "【已屏蔽】" or "") .. Truncate(entry.name, nameLimit)
                .. " · 类" .. (entry.category ~= nil and CategoryName(entry.category) or "-"))
            cell.item:Show(true)
            cell.toggle:Show(true)
            if entry.itemType == nil then
                cell.toggle:SetText("无ID")
                if cell.toggle.Enable then cell.toggle:Enable(false) end
            else
                cell.toggle:SetText(blocked and "取消" or "屏蔽")
                if cell.toggle.Enable then cell.toggle:Enable(true) end
            end
            S.UI:SafeHandler(cell.toggle, "OnClick", function()
                local live = W.merged[W.scrollOffset + i]
                if live == nil or live.kind ~= "item" or live.ref.itemType == nil or (W.kind ~= "bank" and W.kind ~= "coffer") then return end
                ToggleItemBlocked(W.kind, live.ref)
                W:RefreshList(false)
            end, "bag_organizer_blacklist:item_toggle_" .. tostring(i))
        elseif cell then
            cell.index = nil
            cell.kind = nil
            cell.row:SetText(""); cell.row:Show(false)
            cell.item:SetText(""); cell.item:Show(false)
            cell.toggle:SetText("屏蔽"); cell.toggle:Show(false)
        end
    end

    if self.emptyLabel ~= nil then
        self.emptyLabel:Show(not hasStorage)
        if not hasStorage then self.emptyLabel:SetText("请先打开仓库或箱子") end
    end
    if self.pageLabel ~= nil then
        if hasStorage and #self.merged > 0 then
            local first = self.scrollOffset + 1
            local last = math.min(#self.merged, self.scrollOffset + ROWS)
            self.pageLabel:SetText("类别 " .. tostring(catCount) .. " · 物品 " .. tostring(itemCount)
                .. " / " .. tostring(first) .. "-" .. tostring(last))
        elseif hasStorage then
            self.pageLabel:SetText("当前仓储没有物品")
        else
            self.pageLabel:SetText("")
        end
    end
    self:RefreshStorageLabel()
end

function W:RefreshAll()
    local panel = self:Create()
    if panel == nil then return end
    local svc = Service()
    local kind = svc and svc:GetOpenStorageKind() or nil
    self:ScanCurrent(kind)
    self.scrollOffset = 0
    self:RefreshList(true)
end

-- Light visibility-only watcher (same getter class as the service floating
-- bar watcher). Re-scans the open storage only when the kind changed.
function W:CheckKindRefresh()
    local panel = self.window
    if panel == nil or type(panel.IsVisible) ~= "function" then return end
    local ok, visible = pcall(function() return panel:IsVisible() end)
    if ok ~= true or visible ~= true then return end
    local svc = Service()
    if svc == nil then return end
    local kind = svc:GetOpenStorageKind()
    if kind ~= self.kind then self:RefreshAll() end
end

function W:Show(visible)
    local panel = self:Create()
    if panel == nil then return end
    if visible == true then self:ApplyAnchor() end
    panel:Show(visible == true)
    if visible == true then
        self:RefreshAll()
        if panel.Raise ~= nil then pcall(function() panel:Raise() end) end
        if S.Scheduler ~= nil and type(S.Scheduler.AddTask) == "function" and type(S.Scheduler.RemoveTask) == "function" then
            S.Scheduler:RemoveTask(TASK_KIND)
            S.Scheduler:AddTask(TASK_KIND, 400, function() W:CheckKindRefresh() end, false, W, "P3")
        end
    elseif S.Scheduler ~= nil and type(S.Scheduler.RemoveTask) == "function" then
        S.Scheduler:RemoveTask(TASK_KIND)
    end
end

function W:ApplyAnchor()
    local panel = self:Create(); if panel == nil then return end
    if panel.RemoveAllAnchors ~= nil then panel:RemoveAllAnchors() end
    local context = S.Layout and S.Layout:GetContext() or {}
    local logicalW = tonumber(context.logicalWidth) or 1024
    local logicalH = tonumber(context.logicalHeight) or 768
    local edge = math.max(6, tonumber(context.safeTop) or 10)
    local x = math.max(edge, math.floor((logicalW - PANEL_W) / 2))
    local y = math.max(edge, math.floor((logicalH - PANEL_H) / 2))
    if S.Layout ~= nil and type(S.Layout.ClampTopLeft) == "function" then
        x, y = S.Layout:ClampTopLeft(x, y, PANEL_W, PANEL_H, { edge = edge })
    else
        x = math.max(edge, math.min(x, math.max(edge, logicalW - edge - PANEL_W)))
        y = math.max(edge, math.min(y, math.max(edge, logicalH - edge - PANEL_H)))
    end
    panel:AddAnchor("TOPLEFT", "UIParent", math.floor(x + 0.5), math.floor(y + 0.5))
end
