------------------------------------------------------------------------
-- Replicated Suite - RSUI Data Views / Virtualization v2
--
-- UMG-like ListView / TableView foundation. Large data sets must not create
-- one native widget per item. VirtualList keeps a bounded row pool sized from
-- the viewport and rebinds pooled rows only when their logical item changes.
--
-- IMPORTANT:
--   * No permanent Tick work. Reconciliation happens on data/scroll/layout.
--     Scrollbar and column-resize gestures borrow the shared ~16 ms interactive
--     scheduler lane only while the mouse gesture is active, then release it.
--   * Row height is fixed in v1 so index -> viewport position is O(1).
--   * Data tables are referenced, not copied. Call RefreshVisible/SetItems when
--     in-place data changes so the visible pool can be rebound explicitly.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local UI, RSUI = S.UI, S.RSUI
if type(UI) ~= "table" or type(RSUI) ~= "table" then return end
-- v2 selection callback contract: List/Tile/Table expose GetSelectedKey() on
-- the View and dispatch SelectionChanged as
-- (index, previousIndex, view, model, reason, key, selected, context).
RSUI.DataViewSelectionContractVersion = 2
RSUI.DataViewViewportContractVersion = 2
RSUI.DataViewOverlayScrollbarContractVersion = 1
RSUI.DataViewDeferredCallbackContractVersion = 1
RSUI.DataViewCallbackCaptureContractVersion = 1
local U = RSUI.LayoutUtil
if type(U) ~= "table" then return end
local N, Pad, Arrange, Host = U.N, U.Pad, U.Arrange, U.Host
local Tokens = S.UITokens or {}

local function Token(path, fallback)
    if type(Tokens.Number) == "function" then return Tokens:Number(path, fallback) end
    return tonumber(fallback) or 0
end

local function Clamp(value, lo, hi)
    local v = tonumber(value) or 0
    if lo ~= nil then v = math.max(v, tonumber(lo) or v) end
    if hi ~= nil then v = math.min(v, tonumber(hi) or v) end
    return v
end

-- Read the native widget's current on-screen/logical offset without assuming
-- which of GetEffectiveOffset/GetOffset the RU client exposes on a subtype.
-- Kept at file scope because both VirtualList scrollbar and TableView column
-- resize handles must use the same native event-owner drag transaction.
local function WidgetEffectiveOffset(widget)
    if widget == nil then return nil, nil end
    if type(widget.GetEffectiveOffset) == "function" then
        local ok, x, y = pcall(function() return widget:GetEffectiveOffset() end)
        if ok and (tonumber(x) ~= nil or tonumber(y) ~= nil) then return tonumber(x), tonumber(y) end
    end
    if type(widget.GetOffset) == "function" then
        local ok, x, y = pcall(function() return widget:GetOffset() end)
        if ok and (tonumber(x) ~= nil or tonumber(y) ~= nil) then return tonumber(x), tonumber(y) end
    end
    return nil, nil
end

local function WidgetEffectiveX(widget)
    local x = WidgetEffectiveOffset(widget)
    return tonumber(x)
end

local function WidgetEffectiveY(widget)
    local _, y = WidgetEffectiveOffset(widget)
    return tonumber(y)
end

local function CountArray(value)
    if type(value) ~= "table" then return 0 end
    return #value
end

local function DefaultItemText(item, index)
    if type(item) == "table" then
        if item.text ~= nil then return tostring(item.text) end
        if item.label ~= nil then return tostring(item.label) end
        if item.name ~= nil then return tostring(item.name) end
        if item.title ~= nil then return tostring(item.title) end
    end
    if item == nil then return tostring(index or "") end
    return tostring(item)
end

local function SafeCall(label, fn, ...)
    if type(fn) ~= "function" then return true, nil end
    return RSUI:Callback(label, fn, ...)
end

local function SetViewport(component, visible)
    if type(component) == "table" and type(component.SetViewportVisible) == "function" then
        component:SetViewportVisible(visible == true)
    end
end

local function NormalizeColumn(column, index)
    column = type(column) == "table" and column or {}
    local id = tostring(column.id or column.key or column.field or ("column_" .. tostring(index)))
    local size = tostring(column.size or (column.fill and "fill") or (column.width and "fixed") or "auto"):lower()
    if size ~= "fill" and size ~= "fixed" then size = "auto" end
    -- minWidth is the layout/preferred minimum used by Auto/Fill resolution.
    -- absoluteMinWidth is the hard interaction floor used when the user explicitly
    -- resizes a column. Keeping those concepts separate prevents the framework
    -- from fighting an intentional manual resize while still giving responsive
    -- layout a sensible preferred width.
    local minWidth = math.max(1, tonumber(column.minWidth) or 48)
    local absoluteMinWidth = math.max(1, math.min(minWidth, tonumber(column.absoluteMinWidth) or 1))
    -- maxWidth is a responsive-layout preference only. Manual dragging must not
    -- hit that recommendation; only absoluteMaxWidth may impose a real user
    -- interaction ceiling. This mirrors minWidth/absoluteMinWidth and keeps
    -- tables freely editable unless a feature explicitly declares a hard cap.
    local maxWidth = tonumber(column.maxWidth)
    if maxWidth ~= nil then maxWidth = math.max(absoluteMinWidth, maxWidth) end
    local absoluteMaxWidth = tonumber(column.absoluteMaxWidth)
    if absoluteMaxWidth ~= nil then absoluteMaxWidth = math.max(absoluteMinWidth, absoluteMaxWidth) end
    local width = tonumber(column.width or column.preferredWidth)
    if width ~= nil then width = Clamp(width, absoluteMinWidth, maxWidth) end
    return {
        id = id,
        title = tostring(column.title or column.label or id),
        field = column.field,
        size = size,
        width = width,
        manualWidth = nil,
        minWidth = minWidth,
        maxWidth = maxWidth,
        absoluteMinWidth = absoluteMinWidth,
        absoluteMaxWidth = absoluteMaxWidth,
        fill = math.max(0.0001, tonumber(column.fill or column.fillWeight) or 1),
        align = column.align,
        tone = column.tone,
        headerTone = column.headerTone,
        getText = column.getText or column.value,
        getTone = column.getTone,
        getIcon = column.getIcon or column.getIconPath,
        cellType = tostring(column.cellType or column.type or (column.icon == true and "icon" or "text")):lower(),
        iconSize = math.max(8, tonumber(column.iconSize) or 20),
        fallbackIcon = column.fallbackIcon,
        format = column.format,
        sortable = column.sortable ~= false,
        resizable = column.resizable ~= false,
        visible = column.visible ~= false,
        source = column,
    }
end

local function NormalizeColumns(columns)
    local out = {}
    for index, column in ipairs(type(columns) == "table" and columns or {}) do
        local normalized = NormalizeColumn(column, index)
        if normalized.visible then out[#out + 1] = normalized end
    end
    return out
end

local function ColumnResizeBounds(column)
    column = type(column) == "table" and column or {}
    local minimum = math.max(1, tonumber(column.absoluteMinWidth) or 1)
    local maximum = tonumber(column.absoluteMaxWidth)
    if maximum ~= nil then maximum = math.max(minimum, maximum) end
    return minimum, maximum
end

local function ClampColumnResizeWidth(column, width)
    local minimum, maximum = ColumnResizeBounds(column)
    return Clamp(tonumber(width) or minimum, minimum, maximum)
end

-- Keep a manually resized Fill column responsive. Converting every dragged
-- Fill column to Fixed makes the table stop consuming newly available width
-- after the outer window is resized. A Fill column therefore stores the
-- committed drag width as a responsive base while preserving its Fill weight;
-- Fixed/Auto columns retain the historical explicit-width semantics.
local function CommitColumnResizeWidth(column, width)
    if type(column) ~= "table" then return false, nil end
    local nextWidth = math.floor(ClampColumnResizeWidth(column, width) + 0.5)
    local previous = tonumber(column.manualWidth) or tonumber(column.width)
    local changed = previous == nil or math.abs((previous or 0) - nextWidth) > 0.01 or column.size ~= "fixed" and column.size ~= "fill"
    column.manualWidth = nextWidth
    if column.size ~= "fill" then column.width, column.size = nextWidth, "fixed" end
    return changed, nextWidth
end

-- Column resize preview must be geometrically stable. Re-running the full Fill
-- solver on every pointer sample makes unrelated Fill columns breathe while a
-- separator is dragged; every pooled text label then changes extent/ellipsis at
-- once and the RU native UI visibly jitters. Freeze the resolved widths at drag
-- start and move one boundary by resizing the adjacent pair only. This keeps the
-- table's total width constant and confines native writes to the two affected
-- cells per row. Widths are quantized to logical pixels to avoid sub-pixel
-- oscillation from GetEffectiveOffset on different RU builds.
local function ResolveAdjacentResizePreview(columns, baselineWidths, index, requestedWidth)
    if type(columns) ~= "table" or type(baselineWidths) ~= "table" then return nil end
    index = math.floor(tonumber(index) or 0)
    if index < 1 or index >= #columns then return nil end
    local leftColumn = columns[index]
    if leftColumn == nil then return nil end

    local compensationIndex = nil
    for candidate = index + 1, #columns do
        local column = columns[candidate]
        if column ~= nil and column.resizable ~= false then compensationIndex = candidate; break end
    end
    -- A visible boundary always has a right-side column. If every right-side
    -- column is explicitly non-resizable, use the immediate neighbour only as
    -- the layout compensation cell so the viewport edge remains stable.
    compensationIndex = compensationIndex or (index + 1)
    local rightColumn = columns[compensationIndex]
    if rightColumn == nil then return nil end

    local widths = {}
    for i = 1, #columns do widths[i] = math.max(1, math.floor((tonumber(baselineWidths[i]) or 1) + 0.5)) end
    local startLeft = widths[index]
    local startRight = widths[compensationIndex]
    local wantedLeft = math.floor(ClampColumnResizeWidth(leftColumn, requestedWidth) + 0.5)
    local delta = wantedLeft - startLeft

    local leftMin, leftMax = ColumnResizeBounds(leftColumn)
    local rightMin, rightMax = ColumnResizeBounds(rightColumn)
    leftMin, rightMin = math.floor(leftMin + 0.5), math.floor(rightMin + 0.5)
    if leftMax ~= nil then leftMax = math.floor(leftMax + 0.5) end
    if rightMax ~= nil then rightMax = math.floor(rightMax + 0.5) end

    local minDelta = leftMin - startLeft
    local maxDelta = leftMax ~= nil and (leftMax - startLeft) or math.huge
    -- Positive delta shrinks the compensation column; negative delta grows it.
    maxDelta = math.min(maxDelta, startRight - rightMin)
    if rightMax ~= nil then minDelta = math.max(minDelta, startRight - rightMax) end
    delta = math.max(minDelta, math.min(maxDelta, delta))

    widths[index] = startLeft + delta
    widths[compensationIndex] = startRight - delta
    return widths, widths[index], compensationIndex, widths[compensationIndex]
end

local function SameWidths(a, b)
    if type(a) ~= "table" or type(b) ~= "table" or #a ~= #b then return false end
    for index = 1, #a do
        if math.abs((tonumber(a[index]) or 0) - (tonumber(b[index]) or 0)) > 0.01 then return false end
    end
    return true
end

local function ResolveColumnWidths(columns, availableWidth, gap)
    local count = #columns
    local widths = {}
    if count <= 0 then return widths, 0, false end
    local usable = math.max(0, tonumber(availableWidth) or 0) - math.max(0, tonumber(gap) or 0) * math.max(0, count - 1)
    local total = 0
    local fillWeight = 0
    local fillIndexes = {}
    local shrinkable = 0

    for index, column in ipairs(columns) do
        local width
        if column.manualWidth ~= nil then
            -- Explicit user geometry is authoritative. Preferred layout caps do
            -- not silently pull a manually-resized column back on the next reflow.
            width = Clamp(column.manualWidth, column.absoluteMinWidth, column.absoluteMaxWidth)
            if column.size == "fill" then
                fillWeight = fillWeight + column.fill
                fillIndexes[#fillIndexes + 1] = index
            else
                shrinkable = shrinkable + math.max(0, width - column.absoluteMinWidth)
            end
        elseif column.size == "fill" then
            width = Clamp(column.minWidth, column.absoluteMinWidth, column.maxWidth)
            fillWeight = fillWeight + column.fill
            fillIndexes[#fillIndexes + 1] = index
        else
            if column.width ~= nil then
                width = Clamp(column.width, column.absoluteMinWidth, column.maxWidth)
            else
                width = Clamp(column.minWidth, column.minWidth, column.maxWidth)
            end
            shrinkable = shrinkable + math.max(0, width - column.absoluteMinWidth)
        end
        widths[index] = width
        total = total + width
    end

    local compressed = false
    if total > usable + 0.01 then
        compressed = true
        local deficit = total - usable
        if shrinkable > 0 then
            local used = math.min(deficit, shrinkable)
            for index, column in ipairs(columns) do
                if column.size ~= "fill" then
                    local room = math.max(0, widths[index] - column.absoluteMinWidth)
                    if room > 0 then widths[index] = widths[index] - used * (room / shrinkable) end
                end
            end
            total = total - used
            deficit = total - usable
        end
        if deficit > 0.01 then
            local fillShrinkable = 0
            for _, index in ipairs(fillIndexes) do
                local column = columns[index]
                fillShrinkable = fillShrinkable + math.max(0, widths[index] - column.absoluteMinWidth)
            end
            if fillShrinkable > 0 then
                local used = math.min(deficit, fillShrinkable)
                for _, index in ipairs(fillIndexes) do
                    local column = columns[index]
                    local room = math.max(0, widths[index] - column.absoluteMinWidth)
                    if room > 0 then widths[index] = widths[index] - used * (room / fillShrinkable) end
                end
                total = total - used
            end
        end
    end

    local remaining = math.max(0, usable - total)
    if remaining > 0 and fillWeight > 0 then
        local undistributed = remaining
        local activeWeight = fillWeight
        local active = {}
        for _, index in ipairs(fillIndexes) do active[index] = true end
        -- A few bounded passes are enough to respect maxWidth without a generic
        -- solver. Column count is tiny and this only runs during layout changes.
        for _ = 1, math.min(4, #fillIndexes + 1) do
            if undistributed <= 0.01 or activeWeight <= 0 then break end
            local consumed = 0
            for _, index in ipairs(fillIndexes) do
                if active[index] then
                    local column = columns[index]
                    local share = undistributed * (column.fill / activeWeight)
                    local nextWidth = widths[index] + share
                    if column.maxWidth ~= nil and nextWidth >= column.maxWidth then
                        share = math.max(0, column.maxWidth - widths[index])
                        active[index] = nil
                        activeWeight = activeWeight - column.fill
                    end
                    widths[index] = widths[index] + share
                    consumed = consumed + share
                end
            end
            if consumed <= 0.001 then break end
            undistributed = math.max(0, undistributed - consumed)
        end
        total = usable - undistributed
    end

    local emergencyClamp = false
    local preRoundTotal = 0
    for _, width in ipairs(widths) do preRoundTotal = preRoundTotal + width end
    if preRoundTotal > usable + 0.01 and preRoundTotal > 0 then
        -- Impossible constraint: even configured absolute minima do not fit.
        -- Safety wins over preferred readability; proportionally compress below
        -- the normal minimum so columns never overlap the parent viewport.
        emergencyClamp = true
        compressed = true
        local scale = math.max(0, usable) / preRoundTotal
        for index = 1, #widths do widths[index] = math.max(1, widths[index] * scale) end
    end

    local roundedTotal = 0
    for index, width in ipairs(widths) do
        widths[index] = math.max(1, math.floor(width + 0.5))
        roundedTotal = roundedTotal + widths[index]
    end
    -- Rounding each column independently can otherwise push the final cell a
    -- few pixels outside the parent. Pull any rounding excess back from the
    -- right-most columns while respecting their hard safety minimum.
    local target = math.max(0, math.floor(usable + 0.5))
    local excess = math.max(0, roundedTotal - target)
    if excess > 0 then
        for index = #widths, 1, -1 do
            if excess <= 0 then break end
            local minimum = emergencyClamp and 1 or math.max(1, math.floor((columns[index].absoluteMinWidth or 1) + 0.5))
            local room = math.max(0, widths[index] - minimum)
            local take = math.min(room, excess)
            widths[index] = widths[index] - take
            excess = excess - take
        end
    end
    return widths, total, compressed, emergencyClamp
end

RSUI.DataViewUtil = {
    NormalizeColumns = NormalizeColumns,
    ResolveColumnWidths = ResolveColumnWidths,
    ColumnResizeBounds = ColumnResizeBounds,
    ClampColumnResizeWidth = ClampColumnResizeWidth,
    ResolveAdjacentResizePreview = ResolveAdjacentResizePreview,
    CommitColumnResizeWidth = CommitColumnResizeWidth,
}

------------------------------------------------------------------------
-- VirtualList / ListView
------------------------------------------------------------------------
local function NewVirtualList(kind, spec)
    local c, err = Host(kind, spec)
    if c == nil then return nil, err end

    c.items = type(spec.items) == "table" and spec.items or {}
    c.getCount = spec.getCount
    c.getItem = spec.getItem
    c.getKey = spec.getKey
    c.itemText = spec.itemText or spec.getItemText
    c.rowFactory = spec.rowFactory or spec.createRow
    c.bindRow = spec.bindRow or spec.onBindRow
    c.unbindRow = spec.unbindRow or spec.onUnbindRow
    c.rowHeight = math.max(12, tonumber(spec.rowHeight) or Token("size.rowH", 28))
    c.rowGap = math.max(0, tonumber(spec.rowGap or spec.gap) or 0)
    c.overscan = math.max(0, math.min(8, math.floor(tonumber(spec.overscan) or 1)))
    c.maxPoolSize = math.max(4, math.min(256, math.floor(tonumber(spec.maxPoolSize) or 96)))
    c.desiredRows = math.max(1, math.min(32, math.floor(tonumber(spec.desiredRows) or 8)))
    c.scrollStep = math.max(1, math.floor(tonumber(spec.scrollStep) or 1))
    c.scrollOffset = math.max(0, math.floor(tonumber(spec.scrollOffset) or 0))
    c.pool = {}
    c.poolByIndex = {}
    c.visibleCapacity = 0
    c.visibleStart, c.visibleEnd = 0, 0
    c.dataRevision = spec.dataRevision ~= nil and tostring(spec.dataRevision) or "0"
    c.internalRevision = 0
    c.selectedIndex = tonumber(spec.selectedIndex)
    c.onSelectionChanged = spec.onSelectionChanged
    c.onItemActivated = spec.onItemActivated or spec.onRowActivated
    c.selectable = spec.selectable == true or spec.selectionModel ~= nil or spec.selectionMode ~= nil
    c.selectionMode = tostring(spec.selectionMode or "single"):lower()
    c.wheelTargets = setmetatable({}, { __mode = "k" })
    -- Shared behavior owns the Native drag proxy; this view owns only logical
    -- row offset and viewport capacity. Wheel and drag therefore share one
    -- scroll Authority instead of maintaining parallel state.
    c.scrollbarEnabled = spec.scrollbar ~= false
    c.scrollbarReserve = spec.reserveScrollbar == true
    c.scrollbarOverlay = spec.overlayScrollbar == true
    c.scrollbarWidth = math.max(6, tonumber(spec.scrollbarWidth) or 14)
    c.scrollbarGap = math.max(2, tonumber(spec.scrollbarGap) or 4)
    c.scrollbarMinThumb = math.max(6, tonumber(spec.scrollbarMinThumb) or 12)

    -- ArcheRage RU dispatches wheel input to the native widget currently under
    -- the cursor. A virtualized row therefore cannot rely on the ListView root
    -- receiving bubbled wheel events. Bind the viewport and every pooled row
    -- root to the same logical scroll Authority. This is event-driven only; no
    -- focus polling/Tick is introduced.
    function c:BindWheelTarget(componentOrRoot)
        local root = type(componentOrRoot) == "table" and componentOrRoot.root or componentOrRoot
        if root == nil or self.wheelTargets[root] == true then return false end
        self.wheelTargets[root] = true
        if type(root.EnableScroll) == "function" then pcall(function() root:EnableScroll(true) end) end
        if type(UI.SetPickable) == "function" then UI:SetPickable(root, true, self.owner) end
        self:On(root, "OnWheelUp", function() return self:ScrollBy(-self.scrollStep) end, "rsui:" .. self.id .. ":wheel_up_target")
        self:On(root, "OnWheelDown", function() return self:ScrollBy(self.scrollStep) end, "rsui:" .. self.id .. ":wheel_down_target")
        return true
    end
    c:BindWheelTarget(c.root)

    c.selectionModel = spec.selectionModel
    if c.selectionModel == nil and c.selectable and type(RSUI.CreateSelectionModel) == "function" then
        c.selectionModel = RSUI:CreateSelectionModel({ id = c.id .. "_selection", mode = c.selectionMode })
    end
    if c.selectionModel ~= nil and type(c.selectionModel.Subscribe) == "function" then
        c.selectionModel:Subscribe(c.id, function(model, reason, key, selected, context)
            for _, slot in ipairs(c.pool) do c:_ApplySelection(slot) end
            SafeCall("rsui:" .. c.id .. ":selection", c.onSelectionChanged, c:GetSelectedIndex(), nil, c, model, reason, key, selected, context)
        end)
    end

    c.scrollbar = nil

    function c:GetScrollbarReserve(viewportHeight)
        if self.scrollbarEnabled ~= true or self.scrollbarOverlay == true then return 0 end
        if self.scrollbarReserve == true then return self.scrollbarWidth + self.scrollbarGap end
        local h = math.max(1, tonumber(viewportHeight) or tonumber(self.height) or self.rowHeight)
        local p = Pad(self.spec.padding)
        local innerH = math.max(1, h - p.top - p.bottom)
        local stride = math.max(1, self.rowHeight + self.rowGap)
        local capacity = math.max(1, math.floor((innerH + self.rowGap) / stride))
        return self:GetItemCount() > capacity and (self.scrollbarWidth + self.scrollbarGap) or 0
    end

    if c.scrollbarEnabled and type(RSUI.ScrollbarBehavior) == "table" and type(RSUI.ScrollbarBehavior.Attach) == "function" then
        c.scrollbar = RSUI.ScrollbarBehavior:Attach(c, {
            id = c.id .. "_scrollbar",
            orientation = "vertical",
            thickness = c.scrollbarWidth,
            minThumb = c.scrollbarMinThumb,
            getMaxOffset = function(host) return host:GetMaxOffset() end,
            getOffset = function(host) return host.scrollOffset end,
            setOffset = function(host, value, relayout) return host:SetScrollOffset(value, relayout) end,
            getVisibleUnits = function(host) return math.max(1, tonumber(host.visibleCapacity) or 1) end,
            getTotalUnits = function(host) return math.max(1, host:GetItemCount()) end,
        })
    end

    if spec.viewState ~= false and type(RSUI.CreateViewState) == "function" then
        local viewSpec = type(spec.viewState) == "table" and spec.viewState or {}
        if viewSpec.onRetry == nil then viewSpec.onRetry = spec.onRetry end
        if viewSpec.autoEmpty == nil then viewSpec.autoEmpty = spec.autoEmptyState ~= false end
        c.viewState = RSUI:CreateViewState(c, viewSpec)
    end
    function c:GetViewState() return self.viewState and self.viewState:Get() or "ready" end
    function c:SetViewState(state, options)
        if self.viewState == nil then return false end
        local changed = self.viewState:Set(state, options)
        if self.width and self.height then self:Layout(self.x or 0, self.y or 0, self.width, self.height) end
        return changed
    end
    function c:_SyncViewState()
        if self.viewState ~= nil then self.viewState:AutoFromCount(self:GetItemCount()) end
    end

    local baseAdd = c.AddChild
    function c:AddChild(child, slot)
        return baseAdd(self, child, slot)
    end

    function c:GetItemCount()
        if type(self.getCount) == "function" then
            local ok, value = SafeCall("rsui:" .. self.id .. ":get_count", self.getCount, self)
            if ok and tonumber(value) ~= nil then return math.max(0, math.floor(tonumber(value))) end
        end
        return CountArray(self.items)
    end

    function c:GetItem(index)
        if type(self.getItem) == "function" then
            local ok, value = SafeCall("rsui:" .. self.id .. ":get_item", self.getItem, index, self)
            if ok then return value end
            return nil
        end
        return self.items[index]
    end

    function c:GetItemKey(item, index)
        if type(self.getKey) == "function" then
            local ok, value = SafeCall("rsui:" .. self.id .. ":get_key", self.getKey, item, index, self)
            if ok and value ~= nil then return tostring(value) end
        end
        if type(item) == "table" and item.id ~= nil then return tostring(item.id) end
        return tostring(index)
    end

    function c:GetMaxOffset()
        return math.max(0, self:GetItemCount() - math.max(1, tonumber(self.visibleCapacity) or self.desiredRows))
    end

    function c:GetVisibleRange()
        return tonumber(self.visibleStart) or 0, tonumber(self.visibleEnd) or 0
    end

    function c:GetVisibleCapacity()
        return math.max(0, tonumber(self.visibleCapacity) or 0)
    end

    function c:GetRowForIndex(index)
        local slot = self.poolByIndex[math.floor(tonumber(index) or 0)]
        return slot and slot.row or nil
    end

    function c:SetRowHeight(value)
        local height = math.max(12, tonumber(value) or self.rowHeight)
        if height == self.rowHeight then return false end
        self.rowHeight = height
        self:InvalidateMeasure("row_height")
        if self.width and self.height then self:Layout(self.x or 0, self.y or 0, self.width, self.height) end
        return true
    end

    function c:GetPoolStats()
        local bound, visible = 0, 0
        for _, slot in ipairs(self.pool) do
            if slot.boundIndex ~= nil then bound = bound + 1 end
            if slot.viewportVisible == true then visible = visible + 1 end
        end
        return {
            poolSize = #self.pool,
            bound = bound,
            visible = visible,
            itemCount = self:GetItemCount(),
            visibleCapacity = tonumber(self.visibleCapacity) or 0,
            visibleStart = tonumber(self.visibleStart) or 0,
            visibleEnd = tonumber(self.visibleEnd) or 0,
            scrollOffset = tonumber(self.scrollOffset) or 0,
        }
    end

    function c:_CreatePoolRow(poolIndex)
        local row = nil
        if type(self.rowFactory) == "function" then
            local ok, value = SafeCall("rsui:" .. self.id .. ":row_factory", self.rowFactory, self, poolIndex)
            if ok and RSUI:IsComponent(value) then row = value end
        end
        if row == nil then
            if self.selectable then
                row = RSUI:Button({
                    id = self.id .. "_row_" .. tostring(poolIndex),
                    parent = self,
                    text = "",
                    width = 1,
                    height = self.rowHeight,
                    onClick = function(button)
                        local index = button.state and button.state.listIndex
                        if index ~= nil then self:HandleRowClick(index) end
                    end,
                })
            else
                row = RSUI:Text({
                    id = self.id .. "_row_" .. tostring(poolIndex),
                    parent = self,
                    text = "",
                    width = 1,
                    height = self.rowHeight,
                    overflow = "ellipsis",
                    vAlign = "center",
                })
            end
        end
        if row == nil then return nil end
        self:BindWheelTarget(row)
        local slot = {
            row = row,
            poolIndex = poolIndex,
            boundIndex = nil,
            boundKey = nil,
            boundRevision = nil,
            viewportVisible = false,
        }
        self.pool[#self.pool + 1] = slot
        RSUI.metrics.virtualPoolRowsCreated = (tonumber(RSUI.metrics.virtualPoolRowsCreated) or 0) + 1
        return slot
    end

    function c:_EnsurePool(required)
        required = math.max(0, math.min(self.maxPoolSize, math.floor(tonumber(required) or 0)))
        while #self.pool < required do
            if self:_CreatePoolRow(#self.pool + 1) == nil then break end
        end
        return #self.pool
    end

    function c:_UnbindSlot(slot)
        if type(slot) ~= "table" then return end
        if slot.boundIndex ~= nil and type(self.unbindRow) == "function" then
            SafeCall("rsui:" .. self.id .. ":row_unbind", self.unbindRow, slot.row, slot.boundIndex, self)
        end
        if RSUI.SelectionVisual ~= nil and type(RSUI.SelectionVisual.Clear) == "function" then RSUI.SelectionVisual:Clear(slot.row) end
        if slot.row and slot.row.state then slot.row.state.listIndex, slot.row.state.listKey = nil, nil end
        slot.boundIndex, slot.boundKey, slot.boundRevision = nil, nil, nil
        slot.viewportVisible = false
        SetViewport(slot.row, false)
    end

    function c:_BindSlot(slot, index, force)
        if type(slot) ~= "table" or index == nil then return false end
        local item = self:GetItem(index)
        local key = self:GetItemKey(item, index)
        local revision = tostring(self.dataRevision or "0")
        local changedIndex = slot.boundIndex ~= index or slot.boundKey ~= key
        local needsBind = force == true or changedIndex or slot.boundRevision ~= revision
        if not needsBind then
            RSUI.metrics.virtualRowReuses = (tonumber(RSUI.metrics.virtualRowReuses) or 0) + 1
            return false
        end
        if changedIndex and slot.boundIndex ~= nil and type(self.unbindRow) == "function" then
            SafeCall("rsui:" .. self.id .. ":row_unbind", self.unbindRow, slot.row, slot.boundIndex, self)
        end
        if type(self.bindRow) == "function" then
            SafeCall("rsui:" .. self.id .. ":row_bind", self.bindRow, slot.row, item, index, key, self)
        elseif type(slot.row.SetText) == "function" then
            local text = nil
            if type(self.itemText) == "function" then
                local ok, value = SafeCall("rsui:" .. self.id .. ":item_text", self.itemText, item, index, self)
                if ok then text = value end
            end
            slot.row:SetText(text ~= nil and tostring(text) or DefaultItemText(item, index))
        end
        slot.row.state = slot.row.state or {}
        slot.row.state.listIndex, slot.row.state.listKey = index, key
        slot.boundIndex, slot.boundKey, slot.boundRevision = index, key, revision
        RSUI.metrics.virtualRowBinds = (tonumber(RSUI.metrics.virtualRowBinds) or 0) + 1
        return true
    end

    function c:_ApplySelection(slot)
        if type(slot) ~= "table" or type(slot.row) ~= "table" then return end
        local selected = false
        if self.selectionModel ~= nil and slot.boundKey ~= nil and type(self.selectionModel.IsSelected) == "function" then
            selected = self.selectionModel:IsSelected(slot.boundKey)
        else
            selected = self.selectedIndex ~= nil and slot.boundIndex == self.selectedIndex
        end
        if RSUI.SelectionVisual ~= nil and type(RSUI.SelectionVisual.Apply) == "function" then
            RSUI.SelectionVisual:Apply(slot.row, selected)
        elseif type(slot.row.SetSelected) == "function" then
            slot.row:SetSelected(selected)
        end
        slot.row.state = slot.row.state or {}
        slot.row.state.listSelected = selected
    end

    function c:_ReconcilePool(firstVisible, visibleCount, forceBind)
        local count = self:GetItemCount()
        if count <= 0 or visibleCount <= 0 then
            self.poolByIndex = {}
            for _, slot in ipairs(self.pool) do self:_UnbindSlot(slot) end
            return
        end

        -- Overscan is opportunistic. Visible rows always have priority over
        -- prefetch rows, even when maxPoolSize is configured very small.
        local spare = math.max(0, self.maxPoolSize - visibleCount)
        local before = math.min(self.overscan, math.floor(spare / 2))
        local after = math.min(self.overscan, math.max(0, spare - before))
        local desiredStart = math.max(1, firstVisible - before)
        local desiredEnd = math.min(count, firstVisible + visibleCount - 1 + after)
        -- Reuse spare capacity from a clipped edge (top/end of data).
        local desiredCount = math.max(0, desiredEnd - desiredStart + 1)
        local spareAfterClamp = math.max(0, math.min(self.maxPoolSize, visibleCount + spare) - desiredCount)
        if spareAfterClamp > 0 and desiredStart > 1 then
            local extra = math.min(spareAfterClamp, desiredStart - 1, self.overscan - math.min(self.overscan, firstVisible - desiredStart))
            desiredStart = desiredStart - math.max(0, extra)
        end
        desiredCount = math.max(0, desiredEnd - desiredStart + 1)
        self:_EnsurePool(desiredCount)

        local keep = {}
        local free = {}
        for _, slot in ipairs(self.pool) do
            if slot.boundIndex ~= nil and slot.boundIndex >= desiredStart and slot.boundIndex <= desiredEnd and keep[slot.boundIndex] == nil then
                keep[slot.boundIndex] = slot
            else
                free[#free + 1] = slot
            end
        end

        for index = desiredStart, desiredEnd do
            local slot = keep[index]
            if slot == nil then
                slot = table.remove(free)
                if slot == nil then break end
                self:_BindSlot(slot, index, true)
                keep[index] = slot
            else
                self:_BindSlot(slot, index, forceBind)
            end
            self:_ApplySelection(slot)
        end

        for _, slot in ipairs(free) do self:_UnbindSlot(slot) end
        self.poolByIndex = keep
        RSUI.metrics.virtualReconciles = (tonumber(RSUI.metrics.virtualReconciles) or 0) + 1
    end

    function c:RefreshVisible(revision, force)
        if revision ~= nil then self.dataRevision = tostring(revision)
        else
            self.internalRevision = self.internalRevision + 1
            self.dataRevision = "internal:" .. tostring(self.internalRevision)
        end
        for _, slot in ipairs(self.pool) do
            if slot.boundIndex ~= nil then
                self:_BindSlot(slot, slot.boundIndex, force ~= false)
                self:_ApplySelection(slot)
            end
        end
        RSUI.metrics.virtualDataRefreshes = (tonumber(RSUI.metrics.virtualDataRefreshes) or 0) + 1
        return true
    end

    function c:InvalidateItem(index)
        index = math.floor(tonumber(index) or 0)
        local slot = self.poolByIndex[index]
        if slot == nil then return false end
        local changed = self:_BindSlot(slot, index, true)
        self:_ApplySelection(slot)
        return changed
    end

    function c:SetItems(items, revision)
        self.items = type(items) == "table" and items or {}
        self.getCount, self.getItem = nil, nil
        self.internalRevision = self.internalRevision + 1
        self.dataRevision = revision ~= nil and tostring(revision) or ("items:" .. tostring(self.internalRevision))
        self.scrollOffset = math.max(0, math.min(self.scrollOffset, self:GetMaxOffset()))
        self:_SyncViewState()
        self:InvalidateMeasure("items_changed")
        RSUI.metrics.virtualDataRefreshes = (tonumber(RSUI.metrics.virtualDataRefreshes) or 0) + 1
        if self.width and self.height then self:Layout(self.x or 0, self.y or 0, self.width, self.height) end
        return true
    end

    function c:SetDataSource(source, revision)
        source = type(source) == "table" and source or {}
        self.items = type(source.items) == "table" and source.items or {}
        self.getCount = source.getCount
        self.getItem = source.getItem
        self.getKey = source.getKey
        self.itemText = source.itemText
        self.internalRevision = self.internalRevision + 1
        self.dataRevision = revision ~= nil and tostring(revision) or tostring(source.revision or ("source:" .. tostring(self.internalRevision)))
        self.scrollOffset = 0
        self:_SyncViewState()
        self:InvalidateMeasure("data_source_changed")
        RSUI.metrics.virtualDataRefreshes = (tonumber(RSUI.metrics.virtualDataRefreshes) or 0) + 1
        if self.width and self.height then self:Layout(self.x or 0, self.y or 0, self.width, self.height) end
        return true
    end

    function c:GetSelectionModel() return self.selectionModel end

    -- Presentation should consume the View contract rather than depending on
    -- SelectionModel callback argument positions. Keys remain stable even when
    -- a selected row is outside the current virtualized pool.
    function c:GetSelectedKey()
        if self.selectionModel ~= nil and type(self.selectionModel.GetPrimaryKey) == "function" then
            return self.selectionModel:GetPrimaryKey()
        end
        if self.selectedIndex ~= nil then
            local item = self:GetItem(self.selectedIndex)
            return self:GetItemKey(item, self.selectedIndex)
        end
        return nil
    end

    function c:GetSelectedIndex()
        if self.selectionModel ~= nil and type(self.selectionModel.GetPrimaryKey) == "function" then
            local key = self.selectionModel:GetPrimaryKey()
            if key ~= nil then
                for _, slot in ipairs(self.pool) do
                    if slot.boundKey == key then return slot.boundIndex end
                end
            end
        end
        return self.selectedIndex
    end

    function c:SetSelectedIndex(index)
        local count = self:GetItemCount()
        local nextIndex = tonumber(index)
        if nextIndex ~= nil then nextIndex = math.max(1, math.min(count, math.floor(nextIndex))) end
        if self.selectionModel ~= nil then
            if nextIndex == nil then
                -- SelectionModel notifies synchronously. Clear the local index
                -- first so the callback cannot observe a stale selectedIndex
                -- when the selected row is outside the virtualized pool.
                self.selectedIndex = nil
                return self.selectionModel:Clear("set_index", { view = self, index = nil })
            end
            local item = self:GetItem(nextIndex)
            local key = self:GetItemKey(item, nextIndex)
            -- SelectOnly() dispatches synchronously; publish the requested index
            -- before entering the SelectionModel so callbacks receive the local
            -- programmatic index even before a pool row has been bound.
            local previousIndex = self.selectedIndex
            self.selectedIndex = nextIndex
            local changed = self.selectionModel:SelectOnly(key, "set_index", { view = self, index = nextIndex })
            if changed ~= true and type(self.selectionModel.IsSelected) == "function" and self.selectionModel:IsSelected(key) ~= true then
                self.selectedIndex = previousIndex
            end
            return changed
        end
        if nextIndex == self.selectedIndex then return false end
        local previous = self.selectedIndex
        self.selectedIndex = nextIndex
        for _, slot in ipairs(self.pool) do self:_ApplySelection(slot) end
        local key = nil
        if nextIndex ~= nil then
            local item = self:GetItem(nextIndex)
            key = self:GetItemKey(item, nextIndex)
        end
        SafeCall("rsui:" .. self.id .. ":selection", self.onSelectionChanged,
            nextIndex, previous, self, nil, "set_index", key, nextIndex ~= nil, { view = self, index = nextIndex })
        return true
    end

    function c:SetItemSelected(index, selected)
        index = math.floor(tonumber(index) or 0)
        if index < 1 or index > self:GetItemCount() then return false end
        if self.selectionModel == nil then return selected == true and self:SetSelectedIndex(index) or (self.selectedIndex == index and self:SetSelectedIndex(nil)) end
        local item = self:GetItem(index)
        local key = self:GetItemKey(item, index)
        return self.selectionModel:SetSelected(key, selected == true, "set_item", { view = self, index = index })
    end

    function c:ToggleSelection(index)
        index = math.floor(tonumber(index) or 0)
        if index < 1 or index > self:GetItemCount() or self.selectionModel == nil then return false end
        local item = self:GetItem(index)
        local key = self:GetItemKey(item, index)
        return self.selectionModel:Toggle(key, "toggle_item", { view = self, index = index })
    end

    function c:ActivateItem(index, reason)
        index = math.floor(tonumber(index) or 0)
        if index < 1 or index > self:GetItemCount() or type(self.onItemActivated) ~= "function" then return false end
        local item = self:GetItem(index)
        local key = self:GetItemKey(item, index)
        local ok, result = SafeCall("rsui:" .. self.id .. ":activate", self.onItemActivated, item, index, key, self, tostring(reason or "click"))
        return ok == true and result ~= false
    end

    function c:HandleRowClick(index)
        index = math.floor(tonumber(index) or 0)
        if index < 1 or index > self:GetItemCount() then return false end
        local selectionChanged = false
        if self.selectable == true then
            if self.selectionModel ~= nil and self.selectionModel:GetMode() == "multi" then
                selectionChanged = self:ToggleSelection(index) == true
            else
                selectionChanged = self:SetSelectedIndex(index) == true
            end
        end
        local activated = self:ActivateItem(index, "row_click")
        return selectionChanged or activated
    end

    function c:GetSelectedKeys()
        return self.selectionModel ~= nil and self.selectionModel:GetSelectedKeys() or {}
    end

    function c:IsItemSelected(index)
        index = math.floor(tonumber(index) or 0)
        if self.selectionModel == nil or index < 1 or index > self:GetItemCount() then return false end
        local item = self:GetItem(index)
        return self.selectionModel:IsSelected(self:GetItemKey(item, index))
    end

    function c:ClearSelection()
        if self.selectionModel ~= nil then return self.selectionModel:Clear("view_clear", self) end
        return self:SetSelectedIndex(nil)
    end

    function c:SetScrollOffset(offset, relayout)
        local value = math.max(0, math.min(self:GetMaxOffset(), math.floor(tonumber(offset) or self.scrollOffset)))
        if value == self.scrollOffset then return false end
        self.scrollOffset = value
        self:InvalidateLayout("virtual_scroll")
        RSUI.metrics.scrollChanges = (tonumber(RSUI.metrics.scrollChanges) or 0) + 1
        if relayout ~= false and self.width and self.height then self:Layout(self.x or 0, self.y or 0, self.width, self.height) end
        return true
    end

    function c:ScrollBy(delta) return self:SetScrollOffset(self.scrollOffset + math.floor(tonumber(delta) or 0)) end
    function c:ScrollToTop() return self:SetScrollOffset(0) end
    function c:ScrollToBottom() return self:SetScrollOffset(self:GetMaxOffset()) end
    function c:ScrollToIndex(index)
        index = math.max(1, math.min(self:GetItemCount(), math.floor(tonumber(index) or 1)))
        return self:SetScrollOffset(index - 1)
    end
    function c:EnsureIndexVisible(index)
        index = math.max(1, math.min(self:GetItemCount(), math.floor(tonumber(index) or 1)))
        if index >= self.visibleStart and index <= self.visibleEnd then return false end
        if index < self.visibleStart then return self:SetScrollOffset(index - 1) end
        return self:SetScrollOffset(index - math.max(1, self.visibleCapacity))
    end

    function c:ForEachPooledRow(fn)
        if type(fn) ~= "function" then return 0 end
        local count = 0
        for _, slot in ipairs(self.pool) do
            if slot.row ~= nil then fn(slot.row, slot.boundIndex, slot); count = count + 1 end
        end
        return count
    end

    function c:Measure(availableW, availableH)
        local p = Pad(self.spec.padding)
        local count = self:GetItemCount()
        local rows = math.min(math.max(1, count), self.desiredRows)
        local desiredH = rows * self.rowHeight + math.max(0, rows - 1) * self.rowGap + p.top + p.bottom
        local desiredW = tonumber(self.spec.width or self.spec.desiredWidth) or tonumber(availableW) or 240
        if tonumber(self.spec.maxDesiredHeight) ~= nil then desiredH = math.min(desiredH, tonumber(self.spec.maxDesiredHeight)) end
        if tonumber(availableW) ~= nil and self.spec.allowOverflow ~= true then desiredW = math.min(desiredW, math.max(1, tonumber(availableW))) end
        if tonumber(availableH) ~= nil and self.spec.allowOverflow ~= true then desiredH = math.min(desiredH, math.max(1, tonumber(availableH))) end
        self.desiredWidth, self.desiredHeight = math.max(1, desiredW), math.max(1, desiredH)
        self.measureDirty = false
        return self.desiredWidth, self.desiredHeight
    end

    function c:Layout(x, y, width, height)
        width = math.max(1, tonumber(width) or tonumber(self.width) or tonumber(self.spec.width) or 240)
        height = math.max(1, tonumber(height) or tonumber(self.height) or tonumber(self.spec.height) or self.rowHeight)
        self:SetBounds(x, y, width, height)
        local p = Pad(self.spec.padding)
        local rawInnerW = math.max(1, width - p.left - p.right)
        local innerH = math.max(1, height - p.top - p.bottom)
        local reserve = self:GetScrollbarReserve(height)
        local innerW = math.max(1, rawInnerW - reserve)
        local stride = math.max(1, self.rowHeight + self.rowGap)
        local capacity = math.max(1, math.floor((innerH + self.rowGap) / stride))
        capacity = math.min(capacity, self.maxPoolSize)
        self.visibleCapacity = capacity
        self.scrollOffset = math.max(0, math.min(self:GetMaxOffset(), self.scrollOffset))
        local first = self.scrollOffset + 1
        local count = self:GetItemCount()
        self.visibleStart = count > 0 and first or 0
        self.visibleEnd = count > 0 and math.min(count, first + capacity - 1) or 0
        self:_ReconcilePool(first, capacity, false)
        if self.scrollbar ~= nil then
            local scrollbarX
            if self.scrollbarOverlay == true then
                scrollbarX = p.left + math.max(0, rawInnerW - self.scrollbarWidth)
            else
                scrollbarX = p.left + innerW + self.scrollbarGap
            end
            self.scrollbar:Layout(scrollbarX, p.top, self.scrollbarWidth, innerH, capacity, math.max(1, count))
        end

        local dataVisible = self.viewState == nil or self.viewState:IsDataVisible()
        for _, slot in ipairs(self.pool) do
            local index = slot.boundIndex
            local visible = dataVisible and index ~= nil and index >= self.visibleStart and index <= self.visibleEnd
            slot.viewportVisible = visible
            SetViewport(slot.row, visible)
            if visible then
                local rowY = p.top + (index - first) * stride
                local rowH = math.min(self.rowHeight, math.max(1, innerH - (rowY - p.top)))
                Arrange(slot.row, p.left, rowY, innerW, rowH)
            end
        end
        if self.viewState ~= nil then
            if dataVisible ~= true and self.scrollbar ~= nil then
                UI:SetVisible(self.scrollbar.track, false, self.owner); UI:SetVisible(self.scrollbar.thumb, false, self.owner); UI:SetVisible(self.scrollbar.dragProxy, false, self.owner)
            end
            self.viewState:Layout(0, 0, width, height)
        end
        RSUI.metrics.virtualVisibleRowsPeak = math.max(tonumber(RSUI.metrics.virtualVisibleRowsPeak) or 0, math.max(0, self.visibleEnd - self.visibleStart + 1))
        self.measureDirty, self.layoutDirty = false, false
        return height
    end

    c:_SyncViewState()
    local baseRelease = c.Release
    function c:Release()
        if self.selectionModel ~= nil and type(self.selectionModel.Unsubscribe) == "function" then self.selectionModel:Unsubscribe(self.id) end
        if self.scrollbar ~= nil and type(self.scrollbar.Release) == "function" then self.scrollbar:Release() end
        self.scrollbar = nil
        return baseRelease(self)
    end
    return c
end

RSUI:RegisterType("VirtualList", function(spec) return NewVirtualList("VirtualList", spec) end)
RSUI:RegisterType("ListView", function(spec) return NewVirtualList("ListView", spec) end)

------------------------------------------------------------------------
-- VirtualGrid / TileView
--
-- Fixed-size virtual tile layout. Like UMG TileView, the data set may be very
-- large while native widgets remain bounded by viewport rows * columns plus a
-- small overscan band.  The view scrolls by logical rows, never by pixels.
------------------------------------------------------------------------
local function NewTileView(kind, spec)
    local c, err = Host(kind, spec)
    if c == nil then return nil, err end

    c.items = type(spec.items) == "table" and spec.items or {}
    c.getCount = spec.getCount
    c.getItem = spec.getItem
    c.getKey = spec.getKey
    c.itemText = spec.itemText or spec.getItemText
    c.tileFactory = spec.tileFactory or spec.itemFactory or spec.createTile
    c.bindTile = spec.bindTile or spec.onBindTile or spec.bindItem
    c.unbindTile = spec.unbindTile or spec.onUnbindTile
    c.tileWidth = math.max(16, tonumber(spec.tileWidth or spec.itemWidth) or 72)
    c.tileHeight = math.max(16, tonumber(spec.tileHeight or spec.itemHeight) or 72)
    c.minTileWidth = math.max(16, tonumber(spec.minTileWidth or spec.minItemWidth) or c.tileWidth)
    c.maxTileWidth = tonumber(spec.maxTileWidth or spec.maxItemWidth)
    if c.maxTileWidth ~= nil then c.maxTileWidth = math.max(c.minTileWidth, c.maxTileWidth) end
    c.columnGap = math.max(0, tonumber(spec.columnGap or spec.gap) or Token("spacing.xs", 4))
    c.rowGap = math.max(0, tonumber(spec.rowGap or spec.gap) or Token("spacing.xs", 4))
    c.fixedColumns = tonumber(spec.columns) and math.max(1, math.floor(tonumber(spec.columns))) or nil
    c.maxColumns = math.max(1, math.min(32, math.floor(tonumber(spec.maxColumns) or 12)))
    c.desiredColumns = math.max(1, math.min(c.maxColumns, math.floor(tonumber(spec.desiredColumns) or 4)))
    c.desiredRows = math.max(1, math.min(32, math.floor(tonumber(spec.desiredRows) or 3)))
    c.overscanRows = math.max(0, math.min(4, math.floor(tonumber(spec.overscanRows or spec.overscan) or 1)))
    c.maxPoolSize = math.max(4, math.min(512, math.floor(tonumber(spec.maxPoolSize) or 120)))
    c.scrollStep = math.max(1, math.floor(tonumber(spec.scrollStep) or 1))
    c.scrollRowOffset = math.max(0, math.floor(tonumber(spec.scrollRowOffset or spec.scrollOffset) or 0))
    c.scrollbarEnabled = spec.scrollbar ~= false
    c.scrollbarReserve = spec.reserveScrollbar == true
    c.scrollbarWidth = math.max(10, tonumber(spec.scrollbarWidth) or 14)
    c.scrollbarGap = math.max(2, tonumber(spec.scrollbarGap) or 4)
    c.scrollbarMinThumb = math.max(6, tonumber(spec.scrollbarMinThumb) or 12)
    c.scrollbar = nil
    c.columns = 1
    c.visibleRows = 1
    c.visibleStart, c.visibleEnd = 0, 0
    c.pool = {}
    c.poolByIndex = {}
    c.dataRevision = spec.dataRevision ~= nil and tostring(spec.dataRevision) or "0"
    c.internalRevision = 0
    c.onSelectionChanged = spec.onSelectionChanged
    c.selectable = spec.selectable ~= false and (spec.selectable == true or spec.selectionMode ~= nil or spec.selectionModel ~= nil or spec.selectOnClick == true)
    c.selectionMode = tostring(spec.selectionMode or "single"):lower()
    c.selectionModel = spec.selectionModel
    if c.selectionModel == nil and c.selectable and type(RSUI.CreateSelectionModel) == "function" then
        c.selectionModel = RSUI:CreateSelectionModel({ id = c.id .. "_selection", mode = c.selectionMode })
    end
    if c.selectionModel ~= nil and type(c.selectionModel.Subscribe) == "function" then
        c.selectionModel:Subscribe(c.id, function(model, reason, key, selected, context)
            for _, slot in ipairs(c.pool) do c:_ApplySelection(slot) end
            -- Keep SelectionChanged signature aligned with ListView/TableView:
            -- index, previousIndex, view, model, reason, key, selected, context.
            SafeCall("rsui:" .. c.id .. ":selection", c.onSelectionChanged, c:GetSelectedIndex(), nil, c, model, reason, key, selected, context)
        end)
    end

    if spec.viewState ~= false and type(RSUI.CreateViewState) == "function" then
        local viewSpec = type(spec.viewState) == "table" and spec.viewState or {}
        if viewSpec.onRetry == nil then viewSpec.onRetry = spec.onRetry end
        if viewSpec.autoEmpty == nil then viewSpec.autoEmpty = spec.autoEmptyState ~= false end
        c.viewState = RSUI:CreateViewState(c, viewSpec)
    end
    function c:GetViewState() return self.viewState and self.viewState:Get() or "ready" end
    function c:SetViewState(state, options)
        if self.viewState == nil then return false end
        local changed = self.viewState:Set(state, options)
        if self.width and self.height then self:Layout(self.x or 0, self.y or 0, self.width, self.height) end
        return changed
    end
    function c:_SyncViewState()
        if self.viewState ~= nil then self.viewState:AutoFromCount(self:GetItemCount()) end
    end

    function c:GetItemCount()
        if type(self.getCount) == "function" then
            local ok, value = SafeCall("rsui:" .. self.id .. ":get_count", self.getCount, self)
            if ok and tonumber(value) ~= nil then return math.max(0, math.floor(tonumber(value))) end
        end
        return CountArray(self.items)
    end

    function c:GetItem(index)
        if type(self.getItem) == "function" then
            local ok, value = SafeCall("rsui:" .. self.id .. ":get_item", self.getItem, index, self)
            if ok then return value end
            return nil
        end
        return self.items[index]
    end

    function c:GetItemKey(item, index)
        if type(self.getKey) == "function" then
            local ok, value = SafeCall("rsui:" .. self.id .. ":get_key", self.getKey, item, index, self)
            if ok and value ~= nil then return tostring(value) end
        end
        if type(item) == "table" and item.id ~= nil then return tostring(item.id) end
        return tostring(index)
    end

    function c:GetColumns() return math.max(1, tonumber(self.columns) or 1) end
    function c:GetVisibleRange() return tonumber(self.visibleStart) or 0, tonumber(self.visibleEnd) or 0 end
    function c:GetTileForIndex(index)
        local slot = self.poolByIndex[math.floor(tonumber(index) or 0)]
        return slot and slot.tile or nil
    end
    function c:GetSelectionModel() return self.selectionModel end

    function c:_TotalRows()
        local columns = self:GetColumns()
        return math.max(0, math.ceil(self:GetItemCount() / columns))
    end

    function c:GetMaxScrollRow()
        return math.max(0, self:_TotalRows() - math.max(1, tonumber(self.visibleRows) or self.desiredRows))
    end

    function c:GetScrollbarReserve(needsScrollbar)
        if self.scrollbarEnabled ~= true then return 0 end
        if needsScrollbar == true or self.scrollbarReserve == true then return self.scrollbarWidth + self.scrollbarGap end
        return 0
    end

    if c.scrollbarEnabled and type(RSUI.ScrollbarBehavior) == "table" and type(RSUI.ScrollbarBehavior.Attach) == "function" then
        c.scrollbar = RSUI.ScrollbarBehavior:Attach(c, {
            id = c.id .. "_scrollbar",
            orientation = "vertical",
            thickness = c.scrollbarWidth,
            minThumb = c.scrollbarMinThumb,
            getMaxOffset = function(host) return host:GetMaxScrollRow() end,
            getOffset = function(host) return host.scrollRowOffset end,
            setOffset = function(host, value, relayout) return host:SetScrollRow(value, relayout) end,
            getVisibleUnits = function(host) return math.max(1, tonumber(host.visibleRows) or 1) end,
            getTotalUnits = function(host) return math.max(1, host:_TotalRows()) end,
        })
    end

    function c:GetPoolStats()
        local bound, visible = 0, 0
        for _, slot in ipairs(self.pool) do
            if slot.boundIndex ~= nil then bound = bound + 1 end
            if slot.viewportVisible == true then visible = visible + 1 end
        end
        return {
            poolSize = #self.pool,
            bound = bound,
            visible = visible,
            itemCount = self:GetItemCount(),
            columns = self:GetColumns(),
            visibleRows = self.visibleRows,
            visibleStart = self.visibleStart,
            visibleEnd = self.visibleEnd,
            scrollRowOffset = self.scrollRowOffset,
        }
    end

    function c:_CreatePoolTile(poolIndex)
        local tile = nil
        if type(self.tileFactory) == "function" then
            local ok, value = SafeCall("rsui:" .. self.id .. ":tile_factory", self.tileFactory, self, poolIndex)
            if ok and RSUI:IsComponent(value) then tile = value end
        end
        if tile == nil then
            tile = RSUI:Button({
                id = self.id .. "_tile_" .. tostring(poolIndex),
                parent = self,
                text = "",
                width = self.tileWidth,
                height = self.tileHeight,
                onClick = function(button)
                    local index = button.state and button.state.tileIndex
                    if index ~= nil then self:HandleTileClick(index) end
                end,
            })
        end
        if tile == nil then return nil end
        local slot = {
            tile = tile,
            poolIndex = poolIndex,
            boundIndex = nil,
            boundKey = nil,
            boundRevision = nil,
            viewportVisible = false,
        }
        self.pool[#self.pool + 1] = slot
        RSUI.metrics.tilePoolItemsCreated = (tonumber(RSUI.metrics.tilePoolItemsCreated) or 0) + 1
        return slot
    end

    function c:_EnsurePool(required)
        required = math.max(0, math.min(self.maxPoolSize, math.floor(tonumber(required) or 0)))
        while #self.pool < required do
            if self:_CreatePoolTile(#self.pool + 1) == nil then break end
        end
        return #self.pool
    end

    function c:_UnbindSlot(slot)
        if type(slot) ~= "table" then return end
        if slot.boundIndex ~= nil and type(self.unbindTile) == "function" then
            SafeCall("rsui:" .. self.id .. ":tile_unbind", self.unbindTile, slot.tile, slot.boundIndex, self)
        end
        if RSUI.SelectionVisual ~= nil and type(RSUI.SelectionVisual.Clear) == "function" then RSUI.SelectionVisual:Clear(slot.tile) end
        if slot.tile and slot.tile.state then slot.tile.state.tileIndex, slot.tile.state.tileKey = nil, nil end
        slot.boundIndex, slot.boundKey, slot.boundRevision = nil, nil, nil
        slot.viewportVisible = false
        SetViewport(slot.tile, false)
    end

    function c:_BindSlot(slot, index, force)
        if type(slot) ~= "table" or index == nil then return false end
        local item = self:GetItem(index)
        local key = self:GetItemKey(item, index)
        local revision = tostring(self.dataRevision or "0")
        local changed = slot.boundIndex ~= index or slot.boundKey ~= key
        if force ~= true and not changed and slot.boundRevision == revision then
            RSUI.metrics.tileItemReuses = (tonumber(RSUI.metrics.tileItemReuses) or 0) + 1
            return false
        end
        if changed and slot.boundIndex ~= nil and type(self.unbindTile) == "function" then
            SafeCall("rsui:" .. self.id .. ":tile_unbind", self.unbindTile, slot.tile, slot.boundIndex, self)
        end
        if type(self.bindTile) == "function" then
            SafeCall("rsui:" .. self.id .. ":tile_bind", self.bindTile, slot.tile, item, index, key, self)
        elseif type(slot.tile.SetText) == "function" then
            local text = nil
            if type(self.itemText) == "function" then
                local ok, value = SafeCall("rsui:" .. self.id .. ":item_text", self.itemText, item, index, self)
                if ok then text = value end
            end
            slot.tile:SetText(text ~= nil and tostring(text) or DefaultItemText(item, index))
        end
        slot.tile.state = slot.tile.state or {}
        slot.tile.state.tileIndex, slot.tile.state.tileKey = index, key
        slot.boundIndex, slot.boundKey, slot.boundRevision = index, key, revision
        RSUI.metrics.tileItemBinds = (tonumber(RSUI.metrics.tileItemBinds) or 0) + 1
        return true
    end

    function c:_ApplySelection(slot)
        if type(slot) ~= "table" or type(slot.tile) ~= "table" then return end
        local selected = self.selectionModel ~= nil and slot.boundKey ~= nil and self.selectionModel:IsSelected(slot.boundKey)
        if RSUI.SelectionVisual ~= nil and type(RSUI.SelectionVisual.Apply) == "function" then
            RSUI.SelectionVisual:Apply(slot.tile, selected == true)
        elseif type(slot.tile.SetSelected) == "function" then
            slot.tile:SetSelected(selected == true)
        end
        slot.tile.state = slot.tile.state or {}
        slot.tile.state.tileSelected = selected == true
    end

    function c:GetSelectedKey()
        if self.selectionModel ~= nil and type(self.selectionModel.GetPrimaryKey) == "function" then
            return self.selectionModel:GetPrimaryKey()
        end
        return nil
    end

    function c:GetSelectedIndex()
        if self.selectionModel == nil then return nil end
        local key = self:GetSelectedKey()
        if key == nil then return nil end
        for _, slot in ipairs(self.pool) do if slot.boundKey == key then return slot.boundIndex end end
        return nil
    end

    function c:SetSelectedIndex(index)
        if self.selectionModel == nil then return false end
        if index == nil then return self.selectionModel:Clear("set_index", self) end
        index = math.max(1, math.min(self:GetItemCount(), math.floor(tonumber(index) or 1)))
        local item = self:GetItem(index)
        return self.selectionModel:SelectOnly(self:GetItemKey(item, index), "set_index", { view = self, index = index })
    end

    function c:SetItemSelected(index, selected)
        if self.selectionModel == nil then return false end
        index = math.floor(tonumber(index) or 0)
        if index < 1 or index > self:GetItemCount() then return false end
        local item = self:GetItem(index)
        return self.selectionModel:SetSelected(self:GetItemKey(item, index), selected == true, "set_item", { view = self, index = index })
    end

    function c:ToggleSelection(index)
        if self.selectionModel == nil then return false end
        index = math.floor(tonumber(index) or 0)
        if index < 1 or index > self:GetItemCount() then return false end
        local item = self:GetItem(index)
        return self.selectionModel:Toggle(self:GetItemKey(item, index), "toggle_item", { view = self, index = index })
    end

    function c:HandleTileClick(index)
        if self.selectionModel == nil then return false end
        if self.selectionModel:GetMode() == "multi" then return self:ToggleSelection(index) end
        return self:SetSelectedIndex(index)
    end

    function c:GetSelectedKeys() return self.selectionModel ~= nil and self.selectionModel:GetSelectedKeys() or {} end
    function c:IsItemSelected(index)
        index = math.floor(tonumber(index) or 0)
        if self.selectionModel == nil or index < 1 or index > self:GetItemCount() then return false end
        local item = self:GetItem(index)
        return self.selectionModel:IsSelected(self:GetItemKey(item, index))
    end

    function c:ClearSelection()
        return self.selectionModel ~= nil and self.selectionModel:Clear("view_clear", self) or false
    end

    function c:_Reconcile(firstIndex, lastIndex, forceBind)
        if firstIndex <= 0 or lastIndex < firstIndex then
            self.poolByIndex = {}
            for _, slot in ipairs(self.pool) do self:_UnbindSlot(slot) end
            return
        end
        local desiredCount = math.max(0, lastIndex - firstIndex + 1)
        self:_EnsurePool(desiredCount)
        local keep, free = {}, {}
        for _, slot in ipairs(self.pool) do
            if slot.boundIndex ~= nil and slot.boundIndex >= firstIndex and slot.boundIndex <= lastIndex and keep[slot.boundIndex] == nil then
                keep[slot.boundIndex] = slot
            else
                free[#free + 1] = slot
            end
        end
        for index = firstIndex, lastIndex do
            local slot = keep[index]
            if slot == nil then
                slot = table.remove(free)
                if slot == nil then break end
                self:_BindSlot(slot, index, true)
                keep[index] = slot
            else
                self:_BindSlot(slot, index, forceBind)
            end
            self:_ApplySelection(slot)
        end
        for _, slot in ipairs(free) do self:_UnbindSlot(slot) end
        self.poolByIndex = keep
        RSUI.metrics.tileReconciles = (tonumber(RSUI.metrics.tileReconciles) or 0) + 1
    end

    function c:SetItems(items, revision)
        self.items = type(items) == "table" and items or {}
        self.getCount, self.getItem = nil, nil
        self.internalRevision = self.internalRevision + 1
        self.dataRevision = revision ~= nil and tostring(revision) or ("items:" .. tostring(self.internalRevision))
        self.scrollRowOffset = math.max(0, math.min(self.scrollRowOffset, self:GetMaxScrollRow()))
        self:_SyncViewState()
        self:InvalidateMeasure("items_changed")
        RSUI.metrics.virtualDataRefreshes = (tonumber(RSUI.metrics.virtualDataRefreshes) or 0) + 1
        if self.width and self.height then self:Layout(self.x or 0, self.y or 0, self.width, self.height) end
        return true
    end

    function c:SetDataSource(source, revision)
        source = type(source) == "table" and source or {}
        self.items = type(source.items) == "table" and source.items or {}
        self.getCount, self.getItem, self.getKey = source.getCount, source.getItem, source.getKey
        self.itemText = source.itemText
        self.internalRevision = self.internalRevision + 1
        self.dataRevision = revision ~= nil and tostring(revision) or tostring(source.revision or ("source:" .. tostring(self.internalRevision)))
        self.scrollRowOffset = 0
        self:_SyncViewState()
        self:InvalidateMeasure("data_source_changed")
        RSUI.metrics.virtualDataRefreshes = (tonumber(RSUI.metrics.virtualDataRefreshes) or 0) + 1
        if self.width and self.height then self:Layout(self.x or 0, self.y or 0, self.width, self.height) end
        return true
    end

    function c:RefreshVisible(revision, force)
        if revision ~= nil then self.dataRevision = tostring(revision)
        else self.internalRevision = self.internalRevision + 1; self.dataRevision = "internal:" .. tostring(self.internalRevision) end
        for _, slot in ipairs(self.pool) do
            if slot.boundIndex ~= nil then
                self:_BindSlot(slot, slot.boundIndex, force ~= false)
                self:_ApplySelection(slot)
            end
        end
        RSUI.metrics.virtualDataRefreshes = (tonumber(RSUI.metrics.virtualDataRefreshes) or 0) + 1
        return true
    end

    function c:InvalidateItem(index)
        index = math.floor(tonumber(index) or 0)
        local slot = self.poolByIndex[index]
        if slot == nil then return false end
        local changed = self:_BindSlot(slot, index, true)
        self:_ApplySelection(slot)
        return changed
    end

    function c:SetScrollRow(offset, relayout)
        local value = math.max(0, math.min(self:GetMaxScrollRow(), math.floor(tonumber(offset) or self.scrollRowOffset)))
        if value == self.scrollRowOffset then return false end
        self.scrollRowOffset = value
        self:InvalidateLayout("tile_scroll")
        RSUI.metrics.scrollChanges = (tonumber(RSUI.metrics.scrollChanges) or 0) + 1
        if relayout ~= false and self.width and self.height then self:Layout(self.x or 0, self.y or 0, self.width, self.height) end
        return true
    end

    function c:SetScrollOffset(offset, relayout) return self:SetScrollRow(offset, relayout) end
    function c:ScrollBy(delta) return self:SetScrollRow(self.scrollRowOffset + math.floor(tonumber(delta) or 0)) end
    function c:ScrollToTop() return self:SetScrollRow(0) end
    function c:ScrollToBottom() return self:SetScrollRow(self:GetMaxScrollRow()) end
    function c:ScrollToIndex(index)
        index = math.max(1, math.min(self:GetItemCount(), math.floor(tonumber(index) or 1)))
        return self:SetScrollRow(math.floor((index - 1) / self:GetColumns()))
    end
    function c:EnsureIndexVisible(index)
        index = math.max(1, math.min(self:GetItemCount(), math.floor(tonumber(index) or 1)))
        local row = math.floor((index - 1) / self:GetColumns())
        if row >= self.scrollRowOffset and row < self.scrollRowOffset + self.visibleRows then return false end
        if row < self.scrollRowOffset then return self:SetScrollRow(row) end
        return self:SetScrollRow(row - self.visibleRows + 1)
    end

    function c:Measure(availableW, availableH)
        local p = Pad(self.spec.padding)
        local columns = self.fixedColumns or self.desiredColumns
        local rows = math.min(math.max(1, math.ceil(self:GetItemCount() / math.max(1, columns))), self.desiredRows)
        local desiredW = columns * self.tileWidth + math.max(0, columns - 1) * self.columnGap + p.left + p.right
        local desiredH = rows * self.tileHeight + math.max(0, rows - 1) * self.rowGap + p.top + p.bottom
        if tonumber(availableW) ~= nil and self.spec.allowOverflow ~= true then desiredW = math.min(desiredW, math.max(1, tonumber(availableW))) end
        if tonumber(availableH) ~= nil and self.spec.allowOverflow ~= true then desiredH = math.min(desiredH, math.max(1, tonumber(availableH))) end
        self.desiredWidth, self.desiredHeight = math.max(1, desiredW), math.max(1, desiredH)
        self.measureDirty = false
        return self.desiredWidth, self.desiredHeight
    end

    function c:Layout(x, y, width, height)
        width = math.max(1, tonumber(width) or tonumber(self.width) or tonumber(self.spec.width) or 320)
        height = math.max(1, tonumber(height) or tonumber(self.height) or tonumber(self.spec.height) or 240)
        self:SetBounds(x, y, width, height)
        local p = Pad(self.spec.padding)
        local rawInnerW, innerH = math.max(1, width - p.left - p.right), math.max(1, height - p.top - p.bottom)
        local rowStride = math.max(1, self.tileHeight + self.rowGap)
        local preliminaryVisibleRows = math.max(1, math.floor((innerH + self.rowGap) / rowStride))
        local function ResolveColumns(availableWidth)
            local value
            if self.fixedColumns ~= nil then
                value = math.max(1, math.min(self.fixedColumns, self.maxColumns))
            else
                value = math.max(1, math.floor((availableWidth + self.columnGap) / math.max(1, self.minTileWidth + self.columnGap)))
                value = math.min(value, self.maxColumns)
            end
            return math.max(1, math.min(value, self.maxPoolSize))
        end
        local preliminaryColumns = ResolveColumns(rawInnerW)
        local preliminaryRows = math.max(0, math.ceil(self:GetItemCount() / preliminaryColumns))
        local reserve = self:GetScrollbarReserve(preliminaryRows > preliminaryVisibleRows)
        local innerW = math.max(1, rawInnerW - reserve)
        local previousColumns = self.columns
        local columns = ResolveColumns(innerW)
        self.columns = columns
        if previousColumns ~= columns then
            RSUI.metrics.tileColumnChanges = (tonumber(RSUI.metrics.tileColumnChanges) or 0) + 1
            -- Preserve the first visible logical item across a responsive column change.
            local oldColumns = math.max(1, tonumber(previousColumns) or columns)
            local firstIndex = self.scrollRowOffset * oldColumns + 1
            self.scrollRowOffset = math.floor((math.max(1, firstIndex) - 1) / columns)
        end
        local cellW = math.max(1, (innerW - self.columnGap * math.max(0, columns - 1)) / columns)
        if self.maxTileWidth ~= nil then cellW = math.min(cellW, self.maxTileWidth) end
        local gridW = cellW * columns + self.columnGap * math.max(0, columns - 1)
        local startX = p.left + math.max(0, (innerW - gridW) / 2)
        self.visibleRows = math.max(1, math.floor((innerH + self.rowGap) / rowStride))
        self.visibleRows = math.max(1, math.min(self.visibleRows, math.floor(self.maxPoolSize / columns)))
        self.scrollRowOffset = math.max(0, math.min(self:GetMaxScrollRow(), self.scrollRowOffset))
        local count = self:GetItemCount()
        local firstVisible = self.scrollRowOffset * columns + 1
        local visibleCount = math.min(count > 0 and (self.visibleRows * columns) or 0, math.max(0, count - firstVisible + 1))
        self.visibleStart = visibleCount > 0 and firstVisible or 0
        self.visibleEnd = visibleCount > 0 and math.min(count, firstVisible + visibleCount - 1) or 0
        local totalRows = math.max(0, math.ceil(count / columns))
        local targetPoolRows = math.min(totalRows, self.visibleRows + self.overscanRows * 2)
        local firstPoolRow = math.max(0, self.scrollRowOffset - self.overscanRows)
        local lastPoolRowExclusive = math.min(totalRows, self.scrollRowOffset + self.visibleRows + self.overscanRows)
        -- Borrow a clipped overscan row from the opposite edge so the pool is
        -- fully warmed on the first layout and does not grow on the first scroll.
        local haveRows = math.max(0, lastPoolRowExclusive - firstPoolRow)
        if haveRows < targetPoolRows then
            local addAfter = math.min(targetPoolRows - haveRows, math.max(0, totalRows - lastPoolRowExclusive))
            lastPoolRowExclusive = lastPoolRowExclusive + addAfter
            haveRows = math.max(0, lastPoolRowExclusive - firstPoolRow)
        end
        if haveRows < targetPoolRows then
            firstPoolRow = math.max(0, firstPoolRow - (targetPoolRows - haveRows))
        end
        local firstPool = count > 0 and (firstPoolRow * columns + 1) or 0
        local lastPool = count > 0 and math.min(count, lastPoolRowExclusive * columns) or 0
        local visibleItems = math.max(0, self.visibleEnd - self.visibleStart + 1)
        local desiredItems = math.max(0, lastPool - firstPool + 1)
        if desiredItems > self.maxPoolSize then
            firstPool = self.visibleStart
            lastPool = math.min(count, firstPool + self.maxPoolSize - 1)
        elseif desiredItems < visibleItems then
            firstPool = self.visibleStart
            lastPool = math.min(count, firstPool + math.max(visibleItems, self.maxPoolSize) - 1)
        end
        self:_Reconcile(firstPool, lastPool, false)

        local dataVisible = self.viewState == nil or self.viewState:IsDataVisible()
        for _, slot in ipairs(self.pool) do
            local index = slot.boundIndex
            local visible = dataVisible and index ~= nil and index >= self.visibleStart and index <= self.visibleEnd
            slot.viewportVisible = visible
            SetViewport(slot.tile, visible)
            if visible then
                local relative = index - firstVisible
                local row = math.floor(relative / columns)
                local column = relative % columns
                local tileX = startX + column * (cellW + self.columnGap)
                local tileY = p.top + row * rowStride
                Arrange(slot.tile, tileX, tileY, cellW, math.min(self.tileHeight, math.max(1, innerH - row * rowStride)))
            end
        end
        if self.scrollbar ~= nil then
            self.scrollbar:Layout(p.left + innerW + self.scrollbarGap, p.top, self.scrollbarWidth, innerH, self.visibleRows, math.max(1, totalRows))
        end
        if self.viewState ~= nil then
            if dataVisible ~= true and self.scrollbar ~= nil then
                UI:SetVisible(self.scrollbar.track, false, self.owner); UI:SetVisible(self.scrollbar.thumb, false, self.owner); UI:SetVisible(self.scrollbar.dragProxy, false, self.owner)
            end
            self.viewState:Layout(0, 0, width, height)
        end
        RSUI.metrics.tileVisibleItemsPeak = math.max(tonumber(RSUI.metrics.tileVisibleItemsPeak) or 0, math.max(0, self.visibleEnd - self.visibleStart + 1))
        self.measureDirty, self.layoutDirty = false, false
        return height
    end

    c:On(c.root, "OnWheelUp", function() return c:ScrollBy(-c.scrollStep) end, "rsui:" .. c.id .. ":wheel_up")
    c:On(c.root, "OnWheelDown", function() return c:ScrollBy(c.scrollStep) end, "rsui:" .. c.id .. ":wheel_down")
    c:_SyncViewState()
    local baseRelease = c.Release
    function c:Release()
        if self.selectionModel ~= nil and type(self.selectionModel.Unsubscribe) == "function" then self.selectionModel:Unsubscribe(self.id) end
        if self.scrollbar ~= nil and type(self.scrollbar.Release) == "function" then self.scrollbar:Release() end
        self.scrollbar = nil
        return baseRelease(self)
    end
    return c
end

RSUI:RegisterType("VirtualGrid", function(spec) return NewTileView("VirtualGrid", spec) end)
RSUI:RegisterType("TileView", function(spec) return NewTileView("TileView", spec) end)

------------------------------------------------------------------------
-- TableRow
------------------------------------------------------------------------
local function ColumnValue(column, item, index, row)
    local value = nil
    if type(column.getText) == "function" then
        local ok, result = SafeCall("rsui:" .. row.id .. ":column:" .. column.id, column.getText, item, index, column.source, row)
        if ok then value = result end
    elseif type(column.field) == "string" and type(item) == "table" then
        value = item[column.field]
    elseif type(item) == "table" then
        value = item[column.id]
    end
    if type(column.format) == "function" then
        local ok, result = SafeCall("rsui:" .. row.id .. ":format:" .. column.id, column.format, value, item, index, row)
        if ok then value = result end
    end
    return value == nil and "" or tostring(value)
end

local function ColumnIconValue(column, item, index, row)
    local value = nil
    if type(column.getIcon) == "function" then
        local ok, result = SafeCall("rsui:" .. row.id .. ":icon:" .. column.id, column.getIcon, item, index, column.source, row)
        if ok then value = result end
    elseif type(column.field) == "string" and type(item) == "table" then
        value = item[column.field]
    elseif type(item) == "table" then
        value = item.iconPath or item.icon or item[column.id]
    end
    if value == nil or tostring(value) == "" then value = column.fallbackIcon end
    return value == nil and "" or tostring(value)
end

local function NewTableRow(kind, spec)
    spec = type(spec) == "table" and spec or {}
    -- Body rows are the single mouse-hit surface for scrolling/clicking. Keep
    -- truncation tooltips on that same surface instead of making every label
    -- pickable (which would steal wheel/click events from the virtual list).
    local autoTooltip = spec.header ~= true and spec.autoTooltip ~= false
    if type(spec.onClick) == "function" or autoTooltip then spec.pickable = true end
    local c, err = Host(kind, spec)
    if c == nil then return nil, err end
    local parentComponent = type(spec.parent) == "table" and spec.parent or nil
    local tableOwner = parentComponent and (parentComponent.tableOwner or (type(parentComponent.spec) == "table" and parentComponent.spec.tableOwner)) or nil
    c.columns = NormalizeColumns(spec.columns)
    c.resolvedWidths = type(spec.resolvedWidths) == "table" and spec.resolvedWidths or nil
    c.columnGap = math.max(0, tonumber(spec.columnGap or spec.gap) or tonumber(tableOwner and tableOwner.columnGap) or Token("spacing.xs", 4))
    c.cellPaddingX = math.max(0, tonumber(spec.cellPaddingX) or tonumber(tableOwner and tableOwner.cellPaddingX) or ((S.VisualTokens ~= nil and S.VisualTokens:Metric("spacing", "sm", 5)) or 4))
    c.rowHeight = math.max(12, tonumber(spec.rowHeight or spec.height) or tonumber(tableOwner and tableOwner.rowHeight) or Token("size.rowH", 28))
    c.rowFontSize = math.max(1, tonumber(spec.fontSize) or tonumber(tableOwner and tableOwner.rowFontSize) or Token("font.body", 11))
    c.header = spec.header == true
    c.autoTooltip = autoTooltip
    c.autoTooltipBound = false
    c.interactiveHeader = c.header and spec.interactive == true
    c.onHeaderClick = spec.onHeaderClick
    c.sortColumnId = spec.sortColumnId
    c.sortDirection = spec.sortDirection
    c.cells = {}
    c.gridLines = {}

    -- M6-v2 visual parity: TableView keeps virtualization, but pooled rows now
    -- draw the subtle cell grid used by the target ArcheAge-style console. The
    -- drawables are created once per pooled row/header and only reposition on
    -- layout; no per-Tick allocation or table-wide widget explosion.
    local gridColor = (S.Constants and S.Constants.Color and (c.header and S.Constants.Color.divider or S.Constants.Color.dividerSoft)) or { 0.12, 0.28, 0.30, 0.5 }
    if c.header and S.Theme and type(S.Theme.AddGradientBackground) == "function" then
        S.Theme:AddGradientBackground(c.root, "header", "background")
    end
    if c.root ~= nil and type(c.root.CreateColorDrawable) == "function" then
        local bottom = c.root:CreateColorDrawable(gridColor[1], gridColor[2], gridColor[3], gridColor[4], "artwork")
        if bottom ~= nil and bottom.AddAnchor ~= nil then
            bottom:AddAnchor("BOTTOMLEFT", c.root, 0, 0)
            bottom:AddAnchor("BOTTOMRIGHT", c.root, 0, 0)
            if bottom.SetHeight ~= nil then bottom:SetHeight(1) end
        end
        c.bottomGridLine = bottom
        for i = 1, math.max(0, #c.columns - 1) do
            local line = c.root:CreateColorDrawable(gridColor[1], gridColor[2], gridColor[3], gridColor[4], "artwork")
            if line ~= nil and line.SetWidth ~= nil then line:SetWidth(1) end
            c.gridLines[i] = line
        end
    end

    if S.Visual ~= nil and S.Visual.TableSkin ~= nil and type(S.Visual.TableSkin.Decorate) == "function" then
        S.Visual.TableSkin:Decorate(c)
    end

    local function HeaderText(column)
        local text = column.title
        if c.sortColumnId == column.id then
            if c.sortDirection == "asc" then text = text .. " ↑"
            elseif c.sortDirection == "desc" then text = text .. " ↓" end
        end
        return text
    end

    for index, column in ipairs(c.columns) do
        -- Lua 5.1 generic-for control variables are reused by the loop. Capture
        -- stable references before installing deferred header callbacks, or every
        -- header can resolve to the final column after construction.
        local columnIndex = index
        local columnRef = column
        local common = {
            id = c.id .. "_cell_" .. tostring(columnIndex),
            parent = c,
            text = c.header and HeaderText(columnRef) or "",
            width = 1,
            fontSize = c.rowFontSize,
            tone = c.header and (columnRef.headerTone or spec.headerTone or "tableHeader") or (columnRef.tone or spec.tone or "default"),
            overflow = "ellipsis",
            align = columnRef.align,
            height = c.rowHeight,
        }
        local cell
        if not c.header and columnRef.cellType == "icon" then
            cell = RSUI:Icon({
                id = common.id, parent = c, path = "", size = columnRef.iconSize,
                width = columnRef.iconSize, height = columnRef.iconSize, pickable = false,
            })
        elseif c.interactiveHeader then
            common.compact = true
            common.enabled = columnRef.sortable ~= false
            common.onClick = function()
                RSUI.metrics.tableHeaderClicks = (tonumber(RSUI.metrics.tableHeaderClicks) or 0) + 1
                return SafeCall("rsui:" .. c.id .. ":header:" .. columnRef.id, c.onHeaderClick, columnRef, columnIndex, c)
            end
            cell = RSUI:Button(common)
        else
            cell = RSUI:Text(common)
        end
        c.cells[columnIndex] = cell
    end

    function c:GetTruncatedTooltipText()
        local clipped = {}
        for index, cell in ipairs(self.cells or {}) do
            local full = ""
            if type(cell) == "table" and type(cell.GetOverflowTooltipText) == "function" then
                full = tostring(cell:GetOverflowTooltipText() or "")
            else
                local state = type(cell) == "table" and cell.state or nil
                local isTruncated = type(state) == "table" and (state.textTruncated == true or state.textClipped == true or state.textOverflow == true)
                if isTruncated then full = tostring(cell.text or "") end
            end
            if full ~= "" then
                local column = self.columns and self.columns[index] or nil
                local title = type(column) == "table" and tostring(column.tooltipTitle or column.title or "") or ""
                clipped[#clipped + 1] = { title = title, text = full }
            end
        end
        if #clipped == 0 then return "" end
        if #clipped == 1 then return clipped[1].text end
        local lines = {}
        for _, entry in ipairs(clipped) do
            if entry.title ~= "" then lines[#lines + 1] = entry.title .. "：" .. entry.text
            else lines[#lines + 1] = entry.text end
        end
        return table.concat(lines, "\n")
    end

    function c:EnsureAutoTooltip()
        if self.autoTooltip ~= true or self.autoTooltipBound == true then return self.autoTooltipBound == true end
        local tooltip = RSUI.Tooltip
        if type(tooltip) ~= "table" or type(tooltip.Bind) ~= "function" then return false end
        local ok = tooltip:Bind(self, {
            provider = function(row) return row:GetTruncatedTooltipText() end,
            maxWidth = 440,
        })
        self.autoTooltipBound = ok == true
        return self.autoTooltipBound
    end

    c.onClick = spec.onClick
    if c.header ~= true and type(c.onClick) == "function" and c.root ~= nil then
        c:On(c.root, "OnClick", function()
            local ok, result = SafeCall("rsui:" .. c.id .. ":row_click", c.onClick, c, c.item, c.itemIndex)
            return ok == true and result ~= false
        end, "rsui:" .. c.id .. ":row_click")
    end

    function c:SetSortState(columnId, direction)
        columnId = columnId ~= nil and tostring(columnId) or nil
        direction = tostring(direction or "none"):lower()
        if direction ~= "asc" and direction ~= "desc" then direction = "none" end
        local changed = self.sortColumnId ~= columnId or self.sortDirection ~= direction
        self.sortColumnId, self.sortDirection = columnId, direction
        if not self.header then return changed end
        for index, column in ipairs(self.columns) do
            local cell = self.cells[index]
            if cell ~= nil and type(cell.SetText) == "function" then
                local text = column.title
                if columnId == column.id then
                    if direction == "asc" then text = text .. " ↑"
                    elseif direction == "desc" then text = text .. " ↓" end
                end
                cell:SetText(text)
                if type(cell.SetSelected) == "function" then cell:SetSelected(columnId == column.id and direction ~= "none") end
            end
        end
        return changed
    end

    function c:SetResolvedWidths(widths, interactive)
        local nextWidths = type(widths) == "table" and widths or nil
        if SameWidths(self.resolvedWidths, nextWidths) then return false end
        self.resolvedWidths = nextWidths
        -- Column drag preview is already scoped to visible/pooled rows. Re-layout
        -- those established rows immediately instead of queueing a root invalidation
        -- that would not flush until drag commit. This mirrors live window resize.
        if interactive == true and tonumber(self.width) ~= nil and tonumber(self.height) ~= nil then
            self:Layout(self.x or 0, self.y or 0, self.width, self.height)
            return true
        end
        self:InvalidateLayout("table_widths")
        return true
    end

    function c:SetItem(item, index)
        self.item, self.itemIndex = item, index
        self:EnsureAutoTooltip()
        if S.Visual ~= nil and S.Visual.TableSkin ~= nil and type(S.Visual.TableSkin.ApplyItem) == "function" then
            S.Visual.TableSkin:ApplyItem(self, index)
        end
        if self.header then return false end
        for columnIndex, column in ipairs(self.columns) do
            local cell = self.cells[columnIndex]
            if cell ~= nil then
                if column.cellType == "icon" and type(cell.SetIcon) == "function" then
                    cell:SetIcon(ColumnIconValue(column, item, index, self))
                else
                    cell:SetText(ColumnValue(column, item, index, self))
                    local tone = column.tone or self.spec.tone or "default"
                    if type(column.getTone) == "function" then
                        local ok, value = SafeCall("rsui:" .. self.id .. ":tone:" .. column.id, column.getTone, item, index, column.source, self)
                        if ok and value ~= nil then tone = value end
                    end
                    if type(cell.SetTone) == "function" then cell:SetTone(tone) end
                end
            end
        end
        return true
    end

    function c:SetSelected(selected)
        self.state = self.state or {}
        local value = selected == true
        if self.state.selected == value then return false end
        self.state.selected = value
        if S.Visual ~= nil and S.Visual.TableSkin ~= nil and type(S.Visual.TableSkin.SetSelected) == "function" then
            return S.Visual.TableSkin:SetSelected(self, value)
        end
        return true
    end

    function c:Measure(availableW, availableH)
        local width = tonumber(availableW) or tonumber(self.spec.width) or 320
        local height = math.min(math.max(1, self.rowHeight), tonumber(availableH) or self.rowHeight)
        self.desiredWidth, self.desiredHeight = math.max(1, width), height
        self.measureDirty = false
        return self.desiredWidth, self.desiredHeight
    end

    function c:Layout(x, y, width, height)
        width = math.max(1, tonumber(width) or tonumber(self.width) or 320)
        height = math.max(1, tonumber(height) or self.rowHeight)
        self:SetBounds(x, y, width, height)
        local widths = self.resolvedWidths
        if type(widths) ~= "table" or #widths ~= #self.columns then widths = ResolveColumnWidths(self.columns, width, self.columnGap) end
        local cursor = 0
        for index, cell in ipairs(self.cells) do
            local cellW = math.max(1, tonumber(widths[index]) or 1)
            local column = self.columns[index]
            if column ~= nil and column.cellType == "icon" and not self.header then
                local iconSize = math.max(8, math.min(tonumber(column.iconSize) or 20, cellW - 4, height - 4))
                Arrange(cell, cursor + math.max(0, (cellW - iconSize) * 0.5), math.max(0, (height - iconSize) * 0.5), iconSize, iconSize)
            else
                local padX = math.min(math.max(0, tonumber(self.cellPaddingX) or 0), math.max(0, (cellW - 1) * 0.25))
                Arrange(cell, cursor + padX, 0, math.max(1, cellW - padX * 2), height)
            end
            cursor = cursor + cellW + self.columnGap
            local line = self.gridLines and self.gridLines[index] or nil
            if line ~= nil and index < #self.cells then
                local lineX = math.max(0, math.floor(cursor - math.max(1, self.columnGap * 0.5) + 0.5))
                self.state.gridLineX = type(self.state.gridLineX) == "table" and self.state.gridLineX or {}
                if self.state.gridLineX[index] ~= lineX then
                    if line.RemoveAllAnchors ~= nil then pcall(function() line:RemoveAllAnchors() end) end
                    if line.AddAnchor ~= nil then
                        pcall(function()
                            line:AddAnchor("TOPLEFT", self.root, lineX, 1)
                            line:AddAnchor("BOTTOMLEFT", self.root, lineX, -1)
                        end)
                    end
                    if line.SetWidth ~= nil then pcall(function() line:SetWidth(1) end) end
                    self.state.gridLineX[index] = lineX
                end
            end
        end
        self.measureDirty, self.layoutDirty = false, false
        return height
    end
    local baseRelease = c.Release
    function c:Release()
        if self.autoTooltipBound == true and RSUI.Tooltip ~= nil and type(RSUI.Tooltip.Unbind) == "function" then
            RSUI.Tooltip:Unbind(self)
        end
        self.autoTooltipBound = false
        return baseRelease(self)
    end
    return c
end

RSUI:RegisterType("TableRow", function(spec) return NewTableRow("TableRow", spec) end)
RSUI:RegisterType("TableHeader", function(spec)
    spec = type(spec) == "table" and spec or {}
    spec.header = true
    return NewTableRow("TableHeader", spec)
end)

------------------------------------------------------------------------
-- TableView / Table
------------------------------------------------------------------------
local function NewTableView(kind, spec)
    local c, err = Host(kind, spec)
    if c == nil then return nil, err end
    c.columns = NormalizeColumns(spec.columns)
    c.columnGap = math.max(0, tonumber(spec.columnGap) or Token("spacing.xs", 4))
    c.cellPaddingX = math.max(0, tonumber(spec.cellPaddingX) or ((S.VisualTokens ~= nil and S.VisualTokens:Metric("spacing", "sm", 5)) or 4))
    c.rowFontSize = math.max(1, tonumber(spec.rowFontSize or spec.fontSize) or Token("font.body", 11))
    c.headerFontSize = math.max(1, tonumber(spec.headerFontSize or spec.fontSize) or c.rowFontSize)
    -- Default-on for ellipsized table rows. A view can opt out with
    -- autoTooltip=false; fully visible rows remain silent.
    c.autoTooltip = spec.autoTooltip ~= false
    c.headerVisible = spec.headerVisible ~= false
    c.headerHeight = math.max(12, tonumber(spec.headerHeight) or Token("size.rowH", 28))
    c.rowHeight = math.max(12, tonumber(spec.rowHeight) or Token("size.rowH", 28))
    c.resolvedWidths = {}
    c.padding = Pad(spec.padding)
    c.headerInteractive = spec.headerInteractive == true
    c.onSortChanged = spec.onSortChanged
    c.sortColumnId = spec.sortColumnId ~= nil and tostring(spec.sortColumnId) or nil
    c.sortDirection = tostring(spec.sortDirection or "none"):lower()
    if c.sortDirection ~= "asc" and c.sortDirection ~= "desc" then c.sortDirection = "none" end

    c.header = RSUI:TableHeader({
        id = c.id .. "_header",
        parent = c,
        columns = c.columns,
        interactive = c.headerInteractive,
        rowHeight = c.headerHeight,
        columnGap = c.columnGap,
        headerTone = spec.headerTone,
        fontSize = c.headerFontSize,
        cellPaddingX = c.cellPaddingX,
        sortColumnId = c.sortColumnId,
        sortDirection = c.sortDirection,
        onHeaderClick = function(column)
            return c:ToggleSort(column.id)
        end,
    })

    local userRowFactory = spec.rowFactory or spec.createRow
    local userBind = spec.bindRow or spec.onBindRow
    c.list = RSUI:ListView({
        id = c.id .. "_list",
        parent = c,
        items = spec.items,
        getCount = spec.getCount,
        getItem = spec.getItem,
        getKey = spec.getKey,
        dataRevision = spec.dataRevision,
        rowHeight = c.rowHeight,
        rowGap = tonumber(spec.rowGap) or 0,
        tableOwner = c,
        overscan = spec.overscan,
        maxPoolSize = spec.maxPoolSize,
        desiredRows = spec.desiredRows,
        scrollStep = spec.scrollStep,
        scrollbar = spec.scrollbar ~= false,
        reserveScrollbar = false,
        overlayScrollbar = spec.overlayScrollbar == true,
        scrollbarWidth = spec.scrollbarWidth,
        scrollbarGap = spec.scrollbarGap,
        selectable = spec.selectable,
        selectionMode = spec.selectionMode,
        selectionModel = spec.selectionModel,
        onSelectionChanged = type(spec.onSelectionChanged) == "function" and function(index, previousIndex, listView, model, reason, key, selected, context)
            -- TableView owns the public callback surface; do not leak its inner
            -- ListView implementation as the View argument. The ListView's own
            -- SafeCall already fences this wrapper, so do not add a nested fence.
            return spec.onSelectionChanged(index, previousIndex, c, model, reason, key, selected, context)
        end or nil,
        onItemActivated = spec.onItemActivated or spec.onRowActivated,
        viewState = spec.viewState,
        autoEmptyState = spec.autoEmptyState,
        onRetry = spec.onRetry,
        rowFactory = function(list, poolIndex)
            if type(userRowFactory) == "function" then
                local ok, row = SafeCall("rsui:" .. c.id .. ":table_row_factory", userRowFactory, list, poolIndex, c)
                if ok and RSUI:IsComponent(row) then return row end
            end
            local interactive = spec.selectable == true or type(spec.onItemActivated or spec.onRowActivated) == "function"
            return RSUI:TableRow({
                id = c.id .. "_row_" .. tostring(poolIndex),
                parent = list,
                columns = c.columns,
                resolvedWidths = c.resolvedWidths,
                rowHeight = c.rowHeight,
                columnGap = c.columnGap,
                tone = spec.rowTone,
                fontSize = c.rowFontSize,
                cellPaddingX = c.cellPaddingX,
                autoTooltip = c.autoTooltip,
                pickable = interactive or c.autoTooltip,
                onClick = interactive and function(row)
                    local index = row and row.itemIndex or nil
                    if index ~= nil and c.list ~= nil then return c.list:HandleRowClick(index) end
                    return false
                end or nil,
            })
        end,
        bindRow = function(row, item, index, key, list)
            if type(row.SetResolvedWidths) == "function" then row:SetResolvedWidths(c.resolvedWidths) end
            if type(row.SetItem) == "function" then row:SetItem(item, index) end
            if type(userBind) == "function" then SafeCall("rsui:" .. c.id .. ":table_bind", userBind, row, item, index, key, list, c) end
        end,
        unbindRow = spec.unbindRow or spec.onUnbindRow,
    })

    -- Header separators use a preview/commit transaction.  Preview updates only
    -- header + pooled visible rows and never rebinds table data.  The normalized
    -- column model is mutated only once on drag commit.
    function c:ApplyColumnResizePreview(index, width, baselineWidths)
        index = math.floor(tonumber(index) or 0)
        local column = self.columns[index]
        if column == nil then return false end
        local baseline = type(baselineWidths) == "table" and baselineWidths or self.resolvedWidths
        local widths, leftWidth, compensationIndex, compensationWidth = ResolveAdjacentResizePreview(self.columns, baseline, index, width)
        if type(widths) ~= "table" then return false end
        if SameWidths(self.previewResolvedWidths, widths) then
            return false, leftWidth, compensationIndex, compensationWidth
        end
        self.previewResolvedWidths = widths
        if self.header ~= nil and type(self.header.SetResolvedWidths) == "function" then self.header:SetResolvedWidths(widths, true) end
        if self.list ~= nil and type(self.list.ForEachPooledRow) == "function" then
            self.list:ForEachPooledRow(function(row) if type(row.SetResolvedWidths) == "function" then row:SetResolvedWidths(widths, true) end end)
        end
        if type(self.LayoutColumnResizeHandles) == "function" then self:LayoutColumnResizeHandles(widths) end
        return true, leftWidth, compensationIndex, compensationWidth
    end

    function c:ClearColumnResizePreview()
        self.previewResolvedWidths = nil
        local widths = self.resolvedWidths or {}
        if self.header ~= nil and type(self.header.SetResolvedWidths) == "function" then self.header:SetResolvedWidths(widths, true) end
        if self.list ~= nil and type(self.list.ForEachPooledRow) == "function" then
            self.list:ForEachPooledRow(function(row) if type(row.SetResolvedWidths) == "function" then row:SetResolvedWidths(widths, true) end end)
        end
        if type(self.LayoutColumnResizeHandles) == "function" then self:LayoutColumnResizeHandles(widths) end
        return true
    end

    c.columnResizeEnabled = spec.columnResize ~= false
    c.columnResizeHandles = {}

    function c:LayoutColumnResizeHandles(widths)
        widths = type(widths) == "table" and widths or self.resolvedWidths or {}
        if type(self.columnResizeHandles) ~= "table" then return false end
        local p = self.padding or Pad(nil)
        local boundary = 0
        local handleByIndex = {}
        for _, record in ipairs(self.columnResizeHandles) do handleByIndex[record.index] = record end
        for index = 1, #self.columns - 1 do
            boundary = boundary + (tonumber(widths[index]) or 0)
            local record = handleByIndex[index]
            if record ~= nil and record.root ~= nil then
                local handleW = 14
                local x = p.left + boundary + math.max(0, (index - 1) * self.columnGap) + math.floor(self.columnGap * 0.5) - math.floor(handleW * 0.5)
                -- The active separator is owned by native StartMoving. Re-anchor
                -- only its siblings so every visible boundary follows preview live.
                if record.dragging ~= true then UI:SetAnchor(record.root, self.root, x, p.top, self.owner) end
                UI:SetExtent(record.root, handleW, self.headerHeight, self.owner)
                UI:SetVisible(record.root, self.headerVisible, self.owner)
                if record.root.Raise then pcall(function() record.root:Raise() end) end
            end
        end
        return true
    end
    if c.columnResizeEnabled and type(UI.CreateEmptyWidget)=="function" then
        for index = 1, math.max(0, #c.columns - 1) do
            local column = c.columns[index]
            if column ~= nil and column.resizable ~= false then
                local handle = UI:CreateEmptyWidget(c.root, c.id .. "_col_resize_" .. tostring(index), 0, 0, 14, c.headerHeight, true)
                if handle ~= nil then
                    if handle.Enable then pcall(function() handle:Enable(true) end) end
                    if handle.EnablePick then pcall(function() handle:EnablePick(true,true) end) end
                    if handle.Clickable then pcall(function() handle:Clickable(true,true) end) end
                    if handle.EnableDrag then pcall(function() handle:EnableDrag(true) end) end
                    if handle.SetDragCondition and DC_ALWAYS ~= nil then pcall(function() handle:SetDragCondition(DC_ALWAYS) end) end
                    local line = nil
                    if handle.CreateColorDrawable then
                        local color=(S.VisualTokens and S.VisualTokens:Color("separator")) or {0.08,0.28,0.31,0.58}
                        line=handle:CreateColorDrawable(color[1],color[2],color[3],color[4] or 0.58,"overlay")
                        if line and line.SetWidth then line:SetWidth(1) end
                        if line and line.AddAnchor then line:AddAnchor("TOP",handle,0,2);line:AddAnchor("BOTTOM",handle,0,-2) end
                    end
                    local record={root=handle,line=line,index=index,column=column,dragging=false}
                    c.columnResizeHandles[#c.columnResizeHandles+1]=record
                    local function SetLine(active)
                        if line and line.SetColor then
                            local color=(S.VisualTokens and S.VisualTokens:Color(active and "cyan" or "separator")) or (active and {0.2,0.74,0.84,1} or {0.08,0.28,0.31,0.58})
                            pcall(function() line:SetColor(color[1],color[2],color[3],color[4] or 1) end)
                        end
                    end
                    UI:SafeHandler(handle,"OnEnter",function() SetLine(true) end,"rsui:"..c.id..":col_resize_enter:"..index)
                    UI:SafeHandler(handle,"OnLeave",function() if not record.dragging then SetLine(false) end end,"rsui:"..c.id..":col_resize_leave:"..index)
                    local taskName="rsui_table_col_drag:"..c.id..":"..tostring(index)
                    record.taskName = taskName
                    local function StopPreviewTask()
                        if S.Scheduler~=nil and type(S.Scheduler.RemoveTask)=="function" then S.Scheduler:RemoveTask(taskName) end
                        if record.updateFallback == true and handle ~= nil and type(handle.ReleaseHandler) == "function" then
                            pcall(function() handle:ReleaseHandler("OnUpdate") end)
                        end
                        record.updateFallback = false
                    end
                    local function PreviewFromHandle()
                        local currentX=WidgetEffectiveX(handle)
                        if currentX==nil or record.startX==nil or record.startWidth==nil then return nil end
                        local width=math.floor(record.startWidth+(currentX-record.startX)+0.5)
                        width=Clamp(width,record.minWidth,record.maxWidth)
                        if record.lastRequestedWidth == width and record.lastPreviewWidth ~= nil then
                            return record.lastPreviewWidth, record.compensationIndex, record.compensationWidth
                        end
                        record.lastRequestedWidth=width
                        local _, previewWidth, compensationIndex, compensationWidth = c:ApplyColumnResizePreview(index,width,record.startResolvedWidths)
                        record.lastPreviewWidth=previewWidth or record.lastPreviewWidth or record.startWidth
                        record.compensationIndex=compensationIndex or record.compensationIndex
                        record.compensationWidth=compensationWidth or record.compensationWidth
                        return record.lastPreviewWidth, record.compensationIndex, record.compensationWidth
                    end
                    UI:SafeHandler(handle,"OnDragStart",function()
                        local startX=WidgetEffectiveX(handle)
                        if startX==nil or type(handle.StartMoving)~="function" then return false end
                        local currentW=tonumber(c.resolvedWidths[index]) or tonumber(column.width) or tonumber(column.minWidth) or 48
                        record.dragging=true
                        record.startX=startX
                        record.startWidth=math.floor(currentW+0.5)
                        record.startResolvedWidths={}
                        for widthIndex,value in ipairs(c.resolvedWidths or {}) do record.startResolvedWidths[widthIndex]=math.max(1,math.floor((tonumber(value) or 1)+0.5)) end
                        record.minWidth,record.maxWidth=ColumnResizeBounds(column)
                        -- maxWidth/minWidth are responsive layout suggestions.
                        -- Only absoluteMaxWidth/absoluteMinWidth may constrain a
                        -- user's live drag gesture. Keep this single source of
                        -- truth so the native handler cannot reintroduce hidden
                        -- limits after DataViewUtil has already removed them.
                        record.lastRequestedWidth,record.lastPreviewWidth,record.compensationIndex,record.compensationWidth=nil,nil,nil,nil
                        SetLine(true)
                        handle:StartMoving()
                        StopPreviewTask()
                        local scheduled = false
                        if S.Scheduler~=nil and type(S.Scheduler.AddInteractiveTask)=="function" then
                            scheduled = S.Scheduler:AddInteractiveTask(taskName,16,function() if record.dragging then PreviewFromHandle() end return true end,true,c,"P0",1) == true
                        end
                        -- Older RU builds/scheduler failures still get live preview,
                        -- but OnUpdate exists only for the active gesture and is
                        -- released immediately on drag stop. No permanent Tick.
                        if scheduled ~= true then
                            record.updateFallback = UI:SafeHandler(handle,"OnUpdate",function() if record.dragging then PreviewFromHandle() end return true end,"rsui:"..c.id..":col_resize_update:"..index) == true
                        end
                        PreviewFromHandle()
                        return true
                    end,"rsui:"..c.id..":col_resize_start:"..index)
                    UI:SafeHandler(handle,"OnDragStop",function()
                        local width, compensationIndex, compensationWidth=PreviewFromHandle()
                        width=width or record.startWidth
                        compensationIndex=compensationIndex or record.compensationIndex
                        compensationWidth=compensationWidth or record.compensationWidth
                        StopPreviewTask()
                        if type(handle.StopMovingOrSizing)=="function" then pcall(function() handle:StopMovingOrSizing() end) end
                        local startWidth=record.startWidth
                        record.dragging=false
                        SetLine(false)
                        if width~=nil and startWidth~=nil and compensationIndex~=nil and compensationWidth~=nil and math.abs(width-startWidth)>0.5 then
                            -- Commit the exact pair shown during preview in one layout
                            -- transaction so DragStop cannot trigger a second Fill solve
                            -- and visually jump to different geometry.
                            c:CommitColumnResizePair(index,width,compensationIndex,compensationWidth)
                        else
                            -- Returning to the original boundary is a true no-op: clear
                            -- preview without converting Auto/Fill columns to Fixed.
                            c:ClearColumnResizePreview()
                            if c.width and c.height then c:Layout(c.x or 0,c.y or 0,c.width,c.height) end
                        end
                        record.startX,record.startWidth,record.startResolvedWidths,record.minWidth,record.maxWidth=nil,nil,nil,nil,nil
                        record.lastRequestedWidth,record.lastPreviewWidth,record.compensationIndex,record.compensationWidth=nil,nil,nil,nil
                        return true
                    end,"rsui:"..c.id..":col_resize_stop:"..index)
                end
            end
        end
    end

    function c:SetHeaderVisible(visible)
        local nextValue = visible ~= false
        if self.headerVisible == nextValue then return false end
        self.headerVisible = nextValue
        self:InvalidateMeasure("header_visibility")
        if self.width and self.height then self:Layout(self.x or 0, self.y or 0, self.width, self.height) end
        return true
    end

    function c:GetListView() return self.list end
    function c:GetSelectionModel() return self.list:GetSelectionModel() end
    function c:GetViewState() return self.list:GetViewState() end
    function c:SetViewState(state, options) return self.list:SetViewState(state, options) end
    function c:GetColumns() return self.columns end

    function c:GetSortState()
        return { columnId = self.sortColumnId, direction = self.sortDirection }
    end

    function c:SetSortState(columnId, direction, notify)
        columnId = columnId ~= nil and tostring(columnId) or nil
        direction = tostring(direction or "none"):lower()
        if direction ~= "asc" and direction ~= "desc" then direction = "none" end
        if columnId ~= nil then
            local found = false
            for _, column in ipairs(self.columns) do
                if column.id == columnId and column.sortable ~= false then found = true; break end
            end
            if not found then columnId, direction = nil, "none" end
        end
        if direction == "none" then columnId = nil end
        if self.sortColumnId == columnId and self.sortDirection == direction then return false end
        self.sortColumnId, self.sortDirection = columnId, direction
        if self.header ~= nil and type(self.header.SetSortState) == "function" then self.header:SetSortState(columnId, direction) end
        RSUI.metrics.tableSortChanges = (tonumber(RSUI.metrics.tableSortChanges) or 0) + 1
        if notify ~= false then
            SafeCall("rsui:" .. self.id .. ":sort_changed", self.onSortChanged, columnId, direction, self)
        end
        return true
    end

    function c:ToggleSort(columnId)
        columnId = tostring(columnId or "")
        if columnId == "" then return false end
        if self.sortColumnId ~= columnId then return self:SetSortState(columnId, "asc", true) end
        if self.sortDirection == "asc" then return self:SetSortState(columnId, "desc", true) end
        if self.sortDirection == "desc" then return self:SetSortState(nil, "none", true) end
        return self:SetSortState(columnId, "asc", true)
    end
    function c:GetResolvedColumns()
        local result = {}
        for index, column in ipairs(self.columns) do
            result[#result + 1] = { id = column.id, width = tonumber(self.resolvedWidths[index]) or 0, size = column.size, manualWidth = tonumber(column.manualWidth) }
        end
        return result
    end

    function c:SetItems(items, revision) return self.list:SetItems(items, revision) end
    function c:SetDataSource(source, revision) return self.list:SetDataSource(source, revision) end
    function c:RefreshVisible(revision, force) return self.list:RefreshVisible(revision, force) end
    function c:InvalidateItem(index) return self.list:InvalidateItem(index) end
    function c:SetScrollOffset(offset, relayout) return self.list:SetScrollOffset(offset, relayout) end
    function c:ScrollBy(delta) return self.list:ScrollBy(delta) end
    function c:ScrollToTop() return self.list:ScrollToTop() end
    function c:ScrollToBottom() return self.list:ScrollToBottom() end
    function c:ScrollToIndex(index) return self.list:ScrollToIndex(index) end
    function c:EnsureIndexVisible(index) return self.list:EnsureIndexVisible(index) end
    function c:GetVisibleRange() return self.list:GetVisibleRange() end
    function c:GetVisibleCapacity() return self.list:GetVisibleCapacity() end
    function c:GetPoolStats() return self.list:GetPoolStats() end
    function c:SetSelectedIndex(index) return self.list:SetSelectedIndex(index) end
    function c:GetSelectedIndex() return self.list:GetSelectedIndex() end
    function c:GetSelectedKey() return self.list:GetSelectedKey() end
    function c:SetItemSelected(index, selected) return self.list:SetItemSelected(index, selected) end
    function c:ToggleSelection(index) return self.list:ToggleSelection(index) end
    function c:GetSelectedKeys() return self.list:GetSelectedKeys() end
    function c:IsItemSelected(index) return self.list:IsItemSelected(index) end
    function c:ClearSelection() return self.list:ClearSelection() end
    function c:ActivateItem(index, reason) return self.list:ActivateItem(index, reason) end

    function c:CommitColumnResizePair(index, leftWidth, compensationIndex, compensationWidth)
        index = math.floor(tonumber(index) or 0)
        compensationIndex = math.floor(tonumber(compensationIndex) or 0)
        local leftColumn, rightColumn = self.columns[index], self.columns[compensationIndex]
        if leftColumn == nil or rightColumn == nil or index == compensationIndex then return false end
        local leftChanged = CommitColumnResizeWidth(leftColumn, leftWidth)
        local rightChanged = CommitColumnResizeWidth(rightColumn, compensationWidth)
        if leftChanged ~= true and rightChanged ~= true then return false end
        self.previewResolvedWidths = nil
        RSUI.metrics.tableColumnWidthChanges = (tonumber(RSUI.metrics.tableColumnWidthChanges) or 0) + 1
        self:InvalidateLayout("column_resize_pair:" .. tostring(leftColumn.id))
        if self.width and self.height then self:Layout(self.x or 0, self.y or 0, self.width, self.height) end
        return true
    end

    function c:SetColumnWidth(id, width)
        id = tostring(id or "")
        for _, column in ipairs(self.columns) do
            if column.id == id then
                local nextWidth = ClampColumnResizeWidth(column, tonumber(width) or column.manualWidth or column.width or column.minWidth)
                if column.size == "fixed" and tonumber(column.manualWidth) == nextWidth then return false end
                column.width = nextWidth
                column.size = "fixed"
                column.manualWidth = nextWidth
                RSUI.metrics.tableColumnWidthChanges = (tonumber(RSUI.metrics.tableColumnWidthChanges) or 0) + 1
                self:InvalidateLayout("column_width:" .. id)
                if self.width and self.height then self:Layout(self.x or 0, self.y or 0, self.width, self.height) end
                return true
            end
        end
        return false
    end

    function c:AdjustColumnWidth(id, delta)
        id = tostring(id or "")
        for _, column in ipairs(self.columns) do
            if column.id == id and column.resizable ~= false then
                local current = tonumber(column.manualWidth) or tonumber(column.width) or tonumber(column.minWidth) or 48
                return self:SetColumnWidth(id, current + (tonumber(delta) or 0))
            end
        end
        return false
    end

    function c:SetColumnSizeMode(id, mode, value)
        id, mode = tostring(id or ""), tostring(mode or "auto"):lower()
        if mode ~= "fixed" and mode ~= "fill" then mode = "auto" end
        for _, column in ipairs(self.columns) do
            if column.id == id then
                local changed = column.size ~= mode
                column.size = mode
                if mode == "fixed" and tonumber(value) ~= nil then column.width = ClampColumnResizeWidth(column, tonumber(value)) end
                if mode == "fill" and tonumber(value) ~= nil then column.fill = math.max(0.0001, tonumber(value)) end
                -- Explicit mode/weight changes reset the drag-derived responsive
                -- baseline; the next layout starts from the newly declared mode.
                if changed or value ~= nil then column.manualWidth = nil end
                if not changed and value == nil then return false end
                RSUI.metrics.tableColumnWidthChanges = (tonumber(RSUI.metrics.tableColumnWidthChanges) or 0) + 1
                self:InvalidateLayout("column_mode:" .. id)
                if self.width and self.height then self:Layout(self.x or 0, self.y or 0, self.width, self.height) end
                return true
            end
        end
        return false
    end

    function c:Measure(availableW, availableH)
        local p = self.padding
        local listW, listH = self.list:Measure(availableW, availableH)
        local headerH = self.headerVisible and self.headerHeight or 0
        local width = listW + p.left + p.right
        local height = listH + headerH + p.top + p.bottom
        if tonumber(availableW) ~= nil and self.spec.allowOverflow ~= true then width = math.min(width, math.max(1, tonumber(availableW))) end
        if tonumber(availableH) ~= nil and self.spec.allowOverflow ~= true then height = math.min(height, math.max(1, tonumber(availableH))) end
        self.desiredWidth, self.desiredHeight = math.max(1, width), math.max(1, height)
        self.measureDirty = false
        return self.desiredWidth, self.desiredHeight
    end

    function c:Layout(x, y, width, height)
        width = math.max(1, tonumber(width) or tonumber(self.width) or tonumber(self.spec.width) or 360)
        height = math.max(1, tonumber(height) or tonumber(self.height) or tonumber(self.spec.height) or 240)
        self:SetBounds(x, y, width, height)
        local p = self.padding
        local innerW = math.max(1, width - p.left - p.right)
        local innerH = math.max(1, height - p.top - p.bottom)
        local listY = p.top + (self.headerVisible and self.headerHeight or 0)
        local listH = math.max(1, innerH - (self.headerVisible and self.headerHeight or 0))
        local scrollbarReserve = self.list ~= nil and type(self.list.GetScrollbarReserve)=="function" and self.list:GetScrollbarReserve(listH) or 0
        local columnW = math.max(1, innerW - scrollbarReserve)
        self.lastColumnAvailableWidth = columnW
        local widths, _, compressed, emergencyClamp = ResolveColumnWidths(self.columns, columnW, self.columnGap)
        self.resolvedWidths = widths
        if compressed then RSUI.metrics.layoutCompressionEvents = (tonumber(RSUI.metrics.layoutCompressionEvents) or 0) + 1 end
        if emergencyClamp then RSUI.metrics.tableEmergencyClamps = (tonumber(RSUI.metrics.tableEmergencyClamps) or 0) + 1 end
        RSUI.metrics.tableColumnResolves = (tonumber(RSUI.metrics.tableColumnResolves) or 0) + 1

        if self.header ~= nil then
            self.header:SetViewportVisible(self.headerVisible)
            self.header:SetResolvedWidths(widths)
            if self.headerVisible then Arrange(self.header, p.left, p.top, columnW, self.headerHeight) end
        end
        self:LayoutColumnResizeHandles(widths)
        self.list:ForEachPooledRow(function(row)
            if type(row.SetResolvedWidths) == "function" then row:SetResolvedWidths(widths) end
        end)
        Arrange(self.list, p.left, listY, innerW, listH)
        self.measureDirty, self.layoutDirty = false, false
        return height
    end

    local tableBaseRelease = c.Release
    function c:Release()
        if type(self.columnResizeHandles) == "table" then
            for _, record in ipairs(self.columnResizeHandles) do
                if S.Scheduler ~= nil and type(S.Scheduler.RemoveTask) == "function" and record.taskName ~= nil then
                    S.Scheduler:RemoveTask(record.taskName)
                end
                record.dragging = false
                if record.root ~= nil and type(record.root.StopMovingOrSizing) == "function" then pcall(function() record.root:StopMovingOrSizing() end) end
                if record.root ~= nil and type(record.root.ReleaseHandler) == "function" then
                    for _, eventName in ipairs({ "OnEnter", "OnLeave", "OnDragStart", "OnDragStop", "OnUpdate" }) do pcall(function() record.root:ReleaseHandler(eventName) end) end
                end
            end
        end
        self.previewResolvedWidths = nil
        return tableBaseRelease(self)
    end

    return c
end

local function ValidateTableViewSpec(spec)
    if type(spec.columns) ~= "table" or #spec.columns < 1 then return false, "table_columns_required" end
    if #spec.columns > 32 then return false, "table_column_limit_exceeded" end
    local seen = {}
    for index, column in ipairs(spec.columns) do
        if type(column) ~= "table" then return false, "table_column_invalid:" .. tostring(index) end
        local id = tostring(column.id or column.key or column.field or ("column_" .. tostring(index)))
        if id == "" then return false, "table_column_id_required:" .. tostring(index) end
        if seen[id] then return false, "table_column_duplicate:" .. id end
        seen[id] = true
    end
    if (type(spec.getCount) == "function") ~= (type(spec.getItem) == "function") then
        return false, "table_data_provider_pair_required"
    end
    return true
end

RSUI:RegisterType("TableView", function(spec) return NewTableView("TableView", spec) end, ValidateTableViewSpec)
RSUI:RegisterType("Table", function(spec) return NewTableView("Table", spec) end, ValidateTableViewSpec)
