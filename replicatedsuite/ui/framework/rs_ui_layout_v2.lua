------------------------------------------------------------------------
-- Replicated Suite - UI Layout Primitives v2
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local UI = S.UI
if type(UI) ~= "table" then return end

local Tokens = S.UITokens or {}
local Layout = { version = 2.1, metrics = { passes = 0, placements = 0, responsive = 0 } }
UI.LayoutV2 = Layout

local function N(value, fallback)
    value = tonumber(value)
    if value == nil then return tonumber(fallback) or 0 end
    return value
end

local function Token(path, fallback)
    if type(Tokens.Number) == "function" then return Tokens:Number(path, fallback) end
    return N(fallback, 0)
end

local function Place(widget, parent, x, y, width, height, owner)
    if widget == nil then return false end
    Layout.metrics.placements = Layout.metrics.placements + 1
    if width ~= nil and height ~= nil and type(UI.SetExtent) == "function" then UI:SetExtent(widget, width, height, owner) end
    if type(UI.SetAnchor) == "function" then return UI:SetAnchor(widget, parent, x, y, owner) end
    if widget.RemoveAllAnchors ~= nil then widget:RemoveAllAnchors() end
    if widget.AddAnchor ~= nil then widget:AddAnchor("TOPLEFT", parent, x, y); return true end
    return false
end

local function NewStack(axis, parent, spec)
    spec = type(spec) == "table" and spec or {}
    local self = {
        kind = axis == "x" and "hstack" or "vstack", parent = parent,
        x = N(spec.x, 0), y = N(spec.y, 0), cursor = 0,
        gap = N(spec.gap, Token("spacing.sm", 8)),
        defaultWidth = tonumber(spec.width), defaultHeight = tonumber(spec.height),
        owner = spec.owner, count = 0,
    }
    function self:Reset() self.cursor, self.count = 0, 0; return self end
    function self:Add(widget, options)
        options = type(options) == "table" and options or {}
        local width = tonumber(options.width) or self.defaultWidth
        local height = tonumber(options.height) or self.defaultHeight
        local x, y = self.x, self.y
        if axis == "x" then x = x + self.cursor else y = y + self.cursor end
        Place(widget, self.parent, x + N(options.offsetX, 0), y + N(options.offsetY, 0), width, height, options.owner or self.owner)
        local extent = axis == "x" and N(width, 0) or N(height, 0)
        self.cursor = self.cursor + extent + N(options.gapAfter, self.gap)
        self.count = self.count + 1
        Layout.metrics.passes = Layout.metrics.passes + 1
        return widget, x, y
    end
    function self:Spacer(size) self.cursor = self.cursor + N(size, self.gap); return self.cursor end
    function self:Used() return math.max(0, self.cursor - (self.count > 0 and self.gap or 0)) end
    return self
end

function Layout:VStack(parent, spec) return NewStack("y", parent, spec) end
function Layout:HStack(parent, spec) return NewStack("x", parent, spec) end

function Layout:Grid(parent, spec)
    spec = type(spec) == "table" and spec or {}
    local self = {
        parent = parent, x = N(spec.x, 0), y = N(spec.y, 0),
        columns = math.max(1, math.floor(N(spec.columns, 2))),
        cellWidth = N(spec.cellWidth, 180), cellHeight = N(spec.cellHeight, Token("size.rowH", 28)),
        gapX = N(spec.gapX, Token("component.grid.gapX", 8)), gapY = N(spec.gapY, Token("component.grid.gapY", 8)),
        owner = spec.owner, index = 0,
    }
    function self:Reset() self.index = 0; return self end
    function self:Add(widget, options)
        options = type(options) == "table" and options or {}
        local index = self.index
        local row, col = math.floor(index / self.columns), index % self.columns
        local x = self.x + col * (self.cellWidth + self.gapX)
        local y = self.y + row * (self.cellHeight + self.gapY)
        local span = math.max(1, math.min(self.columns - col, math.floor(N(options.colSpan, 1))))
        local width = tonumber(options.width) or (self.cellWidth * span + self.gapX * (span - 1))
        local height = tonumber(options.height) or self.cellHeight
        Place(widget, self.parent, x, y, width, height, options.owner or self.owner)
        self.index = self.index + span
        Layout.metrics.passes = Layout.metrics.passes + 1
        return widget, x, y
    end
    function self:UsedHeight()
        local rows = math.ceil(self.index / self.columns)
        return rows > 0 and (rows * self.cellHeight + (rows - 1) * self.gapY) or 0
    end
    return self
end

-- Resolve a stable responsive column count without coupling LayoutV2 to any
-- specific page.  The caller supplies the available logical width and the
-- smallest usable card width.  This is intentionally pure math: screen-safe
-- clamping and addon scale remain S.Layout Authority.
function Layout:ResolveResponsiveColumns(availableWidth, spec)
    spec = type(spec) == "table" and spec or {}
    local width = math.max(1, N(availableWidth, 1))
    local minCellWidth = math.max(1, N(spec.minCellWidth, 260))
    local gap = math.max(0, N(spec.gapX, Token("component.grid.gapX", 8)))
    local minColumns = math.max(1, math.floor(N(spec.minColumns, 1)))
    local maxColumns = math.max(minColumns, math.floor(N(spec.maxColumns, 3)))
    local columns = math.floor((width + gap) / (minCellWidth + gap))
    columns = math.max(minColumns, math.min(maxColumns, columns))
    -- If the requested minimum cannot physically fit, degrade to one column
    -- instead of producing negative/overlapping card extents.
    if columns > 1 and ((width - gap * (columns - 1)) / columns) < minCellWidth then
        columns = math.max(1, columns - 1)
    end
    return columns, math.max(1, (width - gap * (columns - 1)) / columns)
end

function Layout:ResponsiveGrid(parent, spec)
    spec = type(spec) == "table" and spec or {}
    local width = math.max(1, N(spec.width, 1))
    local columns, cellWidth = self:ResolveResponsiveColumns(width, spec)
    self.metrics.responsive = self.metrics.responsive + 1
    local grid = self:Grid(parent, {
        x = N(spec.x, 0), y = N(spec.y, 0), columns = columns,
        cellWidth = cellWidth,
        cellHeight = N(spec.cellHeight, Token("component.form.fieldH", 52)),
        gapX = N(spec.gapX, Token("component.grid.gapX", 8)),
        gapY = N(spec.gapY, Token("component.grid.gapY", 8)),
        owner = spec.owner,
    })
    grid.availableWidth = width
    grid.responsive = true
    return grid
end

function Layout:Form(parent, spec)
    spec = type(spec) == "table" and spec or {}
    local self = {
        parent = parent, x = N(spec.x, 0), y = N(spec.y, 0), index = 0,
        rowHeight = N(spec.rowHeight, Token("component.form.rowH", 28)),
        gap = N(spec.gap, Token("component.form.gap", 6)),
        labelWidth = N(spec.labelWidth, Token("component.form.labelW", 116)),
        controlWidth = N(spec.controlWidth, Token("component.form.controlW", 180)),
        columnGap = N(spec.columnGap, Token("spacing.sm", 8)), owner = spec.owner,
    }
    function self:Reset() self.index = 0; return self end
    function self:Row(label, control, options)
        options = type(options) == "table" and options or {}
        local y = self.y + self.index * (self.rowHeight + self.gap)
        local labelW = N(options.labelWidth, self.labelWidth)
        local controlW = N(options.controlWidth, self.controlWidth)
        if label ~= nil then Place(label, self.parent, self.x, y, labelW, self.rowHeight, options.owner or self.owner) end
        if control ~= nil then Place(control, self.parent, self.x + labelW + self.columnGap, y, controlW, self.rowHeight, options.owner or self.owner) end
        self.index = self.index + 1
        Layout.metrics.passes = Layout.metrics.passes + 1
        return y
    end
    function self:UsedHeight() return self.index > 0 and (self.index * self.rowHeight + (self.index - 1) * self.gap) or 0 end
    return self
end

function Layout:GetSnapshot()
    return { version = self.version, passes = self.metrics.passes, placements = self.metrics.placements, responsive = self.metrics.responsive }
end

function Layout:ResetMetrics()
    self.metrics.passes, self.metrics.placements, self.metrics.responsive = 0, 0, 0
end
