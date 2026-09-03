------------------------------------------------------------------------
-- Replicated Suite - RSUI Multi Selection Transform Model v1
--
-- Pure editor model for group-transforming 2+ selected rectangles.
--
-- Authority split:
--   * SelectionModel                 = who is selected.
--   * SelectionGeometryModel         = where the group bounds/handles are.
--   * RectTransformTransaction       = group bounds move/resize math.
--   * MultiSelectionTransformModel   = how a resolved group rect maps back to
--                                      each selected child rect.
--   * Feature/Store                  = persistence after a successful commit.
--
-- This model deliberately does NOT own Native widgets, pointer capture, Tick,
-- Snap discovery, Anchor/Pivot, or Feature persistence.  A future editor
-- coordinator can feed the final/snap-resolved group rect from Gesture into a
-- ProjectionSession and commit all child rects atomically once.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local RSUI = S.RSUI
if type(RSUI) ~= "table" then return end

RSUI.MultiSelectionTransformContractVersion = 1

local HARD_MAX_ITEMS = 1024
local DEFAULT_MAX_ITEMS = 256

local function RecordReject()
    RSUI.metrics.multiSelectionTransformRejects = (tonumber(RSUI.metrics.multiSelectionTransformRejects) or 0) + 1
end

local function N(value, fallback)
    local result = tonumber(value)
    if result == nil then result = tonumber(fallback) or 0 end
    return result
end

local function CopyRect(rect)
    if type(rect) ~= "table" then return nil end
    local x, y = tonumber(rect.x), tonumber(rect.y)
    local width, height = tonumber(rect.width or rect.w), tonumber(rect.height or rect.h)
    if x == nil or y == nil or width == nil or height == nil or width <= 0 or height <= 0 then return nil end
    return { x = x, y = y, width = width, height = height }
end

local function CopyItem(item)
    if type(item) ~= "table" then return nil end
    local key = item.key ~= nil and tostring(item.key) or (item.id ~= nil and tostring(item.id) or nil)
    local rect = CopyRect(item.rect or item)
    if key == nil or key == "" or rect == nil then return nil end
    return { key = key, rect = rect }
end

local function CopyItems(items)
    local out = {}
    for index, item in ipairs(type(items) == "table" and items or {}) do
        local copied = CopyItem(item)
        if copied == nil then return nil, "multi_transform_item_invalid:" .. tostring(index) end
        out[#out + 1] = copied
    end
    return out, nil
end

local function BoundsOf(items)
    if type(items) ~= "table" or #items == 0 then return nil end
    local left, top, right, bottom = nil, nil, nil, nil
    for _, item in ipairs(items) do
        local rect = item.rect
        left = left == nil and rect.x or math.min(left, rect.x)
        top = top == nil and rect.y or math.min(top, rect.y)
        right = right == nil and (rect.x + rect.width) or math.max(right, rect.x + rect.width)
        bottom = bottom == nil and (rect.y + rect.height) or math.max(bottom, rect.y + rect.height)
    end
    if left == nil or right <= left or bottom <= top then return nil end
    return { x = left, y = top, width = right - left, height = bottom - top }
end

local function ValidateItems(items, maxItems)
    if type(items) ~= "table" then return nil, "multi_transform_items_required" end
    local count = #items
    if count < 2 then return nil, "multi_transform_requires_multiple_items" end
    if count > maxItems then return nil, "multi_transform_item_limit_exceeded:" .. tostring(count) end
    local copied, copyErr = CopyItems(items)
    if copied == nil then return nil, copyErr end
    local seen = {}
    for index, item in ipairs(copied) do
        if seen[item.key] then return nil, "multi_transform_duplicate_key:" .. item.key end
        seen[item.key] = index
    end
    if BoundsOf(copied) == nil then return nil, "multi_transform_bounds_invalid" end
    return copied, nil
end

local function BuildProjection(startItems, startBounds, targetBounds)
    targetBounds = CopyRect(targetBounds)
    if targetBounds == nil then return nil, "multi_transform_target_bounds_invalid" end
    if startBounds == nil or startBounds.width <= 0 or startBounds.height <= 0 then
        return nil, "multi_transform_start_bounds_invalid"
    end
    local scaleX = targetBounds.width / startBounds.width
    local scaleY = targetBounds.height / startBounds.height
    if scaleX <= 0 or scaleY <= 0 then return nil, "multi_transform_scale_invalid" end
    local projected = {}
    for _, item in ipairs(startItems) do
        local source = item.rect
        projected[#projected + 1] = {
            key = item.key,
            rect = {
                x = targetBounds.x + (source.x - startBounds.x) * scaleX,
                y = targetBounds.y + (source.y - startBounds.y) * scaleY,
                width = source.width * scaleX,
                height = source.height * scaleY,
            },
        }
    end
    return projected, nil
end

local function BuildMinimumGroupExtent(items, bounds, minChildWidth, minChildHeight)
    local minimumScaleX, minimumScaleY = 0, 0
    minChildWidth = math.max(1, N(minChildWidth, 1))
    minChildHeight = math.max(1, N(minChildHeight, 1))
    for _, item in ipairs(items) do
        minimumScaleX = math.max(minimumScaleX, minChildWidth / item.rect.width)
        minimumScaleY = math.max(minimumScaleY, minChildHeight / item.rect.height)
    end
    return math.max(1, bounds.width * minimumScaleX), math.max(1, bounds.height * minimumScaleY)
end

local Model = {}
Model.__index = Model
local Session = {}
Session.__index = Session

function Model:GetItems()
    return CopyItems(self.items)
end

function Model:GetBounds()
    return BoundsOf(self.items)
end

function Model:GetSnapshot()
    return {
        id = self.id,
        contractVersion = tonumber(RSUI.MultiSelectionTransformContractVersion) or 0,
        revision = tonumber(self.revision) or 0,
        count = #(self.items or {}),
        bounds = self:GetBounds(),
        maxItems = self.maxItems,
        hardMaxItems = HARD_MAX_ITEMS,
        activeSession = self.activeSession ~= nil,
        lastSource = self.lastSource,
        lastError = self.lastError,
    }
end

function Model:SetItems(items, source)
    if self.activeSession ~= nil then
        self.lastError = "multi_transform_session_active"
        RecordReject()
        return false, self.lastError
    end
    local copied, err = ValidateItems(items, self.maxItems)
    if copied == nil then self.lastError = err; RecordReject(); return false, err end
    self.items = copied
    self.revision = (tonumber(self.revision) or 0) + 1
    self.lastSource = tostring(source or "set_items")
    self.lastError = nil
    return true, nil
end

function Model:GetGroupConstraints(options)
    options = type(options) == "table" and options or {}
    if options.minChildWidth ~= nil and (tonumber(options.minChildWidth) == nil or tonumber(options.minChildWidth) <= 0) then
        return nil, "multi_transform_min_child_width_invalid"
    end
    if options.minChildHeight ~= nil and (tonumber(options.minChildHeight) == nil or tonumber(options.minChildHeight) <= 0) then
        return nil, "multi_transform_min_child_height_invalid"
    end
    local bounds = self:GetBounds()
    if bounds == nil then return nil, "multi_transform_bounds_invalid" end
    local minimumWidth, minimumHeight = BuildMinimumGroupExtent(self.items, bounds,
        options.minChildWidth or self.minChildWidth, options.minChildHeight or self.minChildHeight)
    return { minWidth = minimumWidth, minHeight = minimumHeight }, nil
end

function Model:BeginProjectionSession(options)
    if self.activeSession ~= nil then RecordReject(); return nil, "multi_transform_session_already_active" end
    options = type(options) == "table" and options or {}
    local startItems, err = CopyItems(self.items)
    if startItems == nil then return nil, err end
    local startBounds = BoundsOf(startItems)
    if startBounds == nil then return nil, "multi_transform_bounds_invalid" end
    local constraints, constraintErr = self:GetGroupConstraints(options)
    if constraints == nil then RecordReject(); return nil, constraintErr end
    local minimumWidth, minimumHeight = constraints.minWidth, constraints.minHeight
    local session = setmetatable({
        model = self,
        baseRevision = tonumber(self.revision) or 0,
        startItems = startItems,
        startBounds = startBounds,
        previewItems = nil,
        previewBounds = nil,
        minGroupWidth = minimumWidth,
        minGroupHeight = minimumHeight,
        active = true,
        revision = 0,
        lastError = nil,
    }, Session)
    self.activeSession = session
    RSUI.metrics.multiSelectionTransformSessions = (tonumber(RSUI.metrics.multiSelectionTransformSessions) or 0) + 1
    return session, nil
end

function Session:GetConstraints()
    return { minWidth = self.minGroupWidth, minHeight = self.minGroupHeight }
end

function Session:GetStartBounds()
    return CopyRect(self.startBounds)
end

function Session:GetPreviewItems()
    if self.previewItems == nil then return CopyItems(self.startItems) end
    return CopyItems(self.previewItems)
end

function Session:GetSnapshot()
    return {
        contractVersion = tonumber(RSUI.MultiSelectionTransformContractVersion) or 0,
        active = self.active == true,
        baseRevision = self.baseRevision,
        revision = tonumber(self.revision) or 0,
        startBounds = CopyRect(self.startBounds),
        previewBounds = CopyRect(self.previewBounds),
        count = #(self.startItems or {}),
        minGroupWidth = self.minGroupWidth,
        minGroupHeight = self.minGroupHeight,
        lastError = self.lastError,
    }
end

function Session:Project(targetBounds)
    if self.active ~= true then RecordReject(); return nil, "multi_transform_session_not_active" end
    if self.model == nil or self.model.activeSession ~= self then RecordReject(); return nil, "multi_transform_session_detached" end
    if (tonumber(self.model.revision) or 0) ~= self.baseRevision then
        self.lastError = "multi_transform_revision_changed"
        RecordReject()
        return nil, self.lastError
    end
    targetBounds = CopyRect(targetBounds)
    if targetBounds == nil then self.lastError = "multi_transform_target_bounds_invalid"; RecordReject(); return nil, self.lastError end
    if targetBounds.width + 0.0001 < self.minGroupWidth or targetBounds.height + 0.0001 < self.minGroupHeight then
        self.lastError = "multi_transform_target_below_child_minimum"
        RecordReject()
        return nil, self.lastError
    end
    local projected, err = BuildProjection(self.startItems, self.startBounds, targetBounds)
    if projected == nil then self.lastError = err; return nil, err end
    self.previewItems = projected
    self.previewBounds = targetBounds
    self.revision = (tonumber(self.revision) or 0) + 1
    self.lastError = nil
    RSUI.metrics.multiSelectionTransformProjections = (tonumber(RSUI.metrics.multiSelectionTransformProjections) or 0) + 1
    return CopyItems(projected), nil
end

function Session:Commit(targetBounds, source)
    if self.active ~= true then return nil, "multi_transform_session_not_active" end
    local projected, err
    if targetBounds ~= nil then
        projected, err = self:Project(targetBounds)
    elseif self.previewItems ~= nil then
        projected = CopyItems(self.previewItems)
    else
        projected = CopyItems(self.startItems)
    end
    if projected == nil then return nil, err or "multi_transform_projection_missing" end
    if self.model == nil or self.model.activeSession ~= self then return nil, "multi_transform_session_detached" end
    if (tonumber(self.model.revision) or 0) ~= self.baseRevision then
        self.lastError = "multi_transform_revision_changed"
        return nil, self.lastError
    end
    -- Atomic commit: all projected rows were validated before this assignment.
    self.model.items = projected
    self.model.revision = self.baseRevision + 1
    self.model.lastSource = tostring(source or "multi_transform_commit")
    self.model.lastError = nil
    self.model.activeSession = nil
    self.active = false
    local result = self.model:GetItems()
    RSUI.metrics.multiSelectionTransformCommits = (tonumber(RSUI.metrics.multiSelectionTransformCommits) or 0) + 1
    return result, nil
end

function Session:Cancel()
    if self.active ~= true then return false, "multi_transform_session_not_active" end
    if self.model ~= nil and self.model.activeSession == self then self.model.activeSession = nil end
    self.active = false
    self.previewItems, self.previewBounds = nil, nil
    RSUI.metrics.multiSelectionTransformCancels = (tonumber(RSUI.metrics.multiSelectionTransformCancels) or 0) + 1
    return true, nil
end

function Session:Release()
    if self.active == true then return self:Cancel() end
    return true, nil
end

function RSUI:CreateMultiSelectionTransformModel(options)
    options = type(options) == "table" and options or {}
    if options.maxItems ~= nil and (tonumber(options.maxItems) == nil or tonumber(options.maxItems) < 2) then
        RecordReject()
        return nil, "multi_transform_max_items_invalid"
    end
    if options.minChildWidth ~= nil and (tonumber(options.minChildWidth) == nil or tonumber(options.minChildWidth) <= 0) then
        RecordReject()
        return nil, "multi_transform_min_child_width_invalid"
    end
    if options.minChildHeight ~= nil and (tonumber(options.minChildHeight) == nil or tonumber(options.minChildHeight) <= 0) then
        RecordReject()
        return nil, "multi_transform_min_child_height_invalid"
    end
    local maxItems = math.floor(math.min(tonumber(options.maxItems) or DEFAULT_MAX_ITEMS, HARD_MAX_ITEMS))
    local items, err = ValidateItems(options.items, maxItems)
    if items == nil then
        RecordReject()
        return nil, err
    end
    local model = setmetatable({
        id = tostring(options.id or "multi_selection_transform"),
        items = items,
        maxItems = maxItems,
        minChildWidth = math.max(1, N(options.minChildWidth, 1)),
        minChildHeight = math.max(1, N(options.minChildHeight, 1)),
        revision = 0,
        activeSession = nil,
        lastSource = "init",
        lastError = nil,
    }, Model)
    RSUI.metrics.multiSelectionTransformModelsCreated = (tonumber(RSUI.metrics.multiSelectionTransformModelsCreated) or 0) + 1
    return model, nil
end

RSUI.MultiSelectionTransformModel = Model
RSUI.MultiSelectionTransformSession = Session
