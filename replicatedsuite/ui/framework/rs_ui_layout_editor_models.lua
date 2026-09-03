------------------------------------------------------------------------
-- Replicated Suite - RSUI Layout Editor Models v1
--
-- Shared, UI-agnostic state for the future HUD/Layout editor.
--
-- Coordinate contract (ArcheAge / CryEngine UI):
--   origin = top-left, +X = right, +Y = down.
--   move up therefore means negative Y.
--
-- This file deliberately does NOT create Native widgets and does NOT own Tick.
-- It provides two small reusable Authorities:
--   * AnchorPivotModel: point-anchor + pivot + rect/offset conversion.
--   * LayoutEditorSnapSettingsModel: bounded snap/guide settings projection.
--
-- Stretch anchors are intentionally out of v1 scope. The current Suite stores
-- top-left rect geometry; silently introducing min/max stretch anchors would
-- reinterpret existing placement data and create upgrade ambiguity.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local RSUI = S.RSUI
if type(RSUI) ~= "table" then return end

RSUI.AnchorPivotContractVersion = 2
RSUI.LayoutEditorSnapSettingsContractVersion = 1

local function N(value, fallback)
    local result = tonumber(value)
    if result == nil then result = tonumber(fallback) or 0 end
    return result
end

local function Clamp(value, minimum, maximum)
    value = N(value, minimum)
    if minimum ~= nil and value < minimum then value = minimum end
    if maximum ~= nil and value > maximum then value = maximum end
    return value
end

local function CopyRect(rect)
    if type(rect) ~= "table" then return nil end
    local x, y = tonumber(rect.x), tonumber(rect.y)
    local width, height = tonumber(rect.width or rect.w), tonumber(rect.height or rect.h)
    if x == nil or y == nil or width == nil or height == nil or width <= 0 or height <= 0 then return nil end
    return { x = x, y = y, width = width, height = height }
end

local ANCHOR_PRESETS = {
    top_left = { x = 0.0, y = 0.0, label = "左上" },
    top = { x = 0.5, y = 0.0, label = "上中" },
    top_right = { x = 1.0, y = 0.0, label = "右上" },
    left = { x = 0.0, y = 0.5, label = "左中" },
    center = { x = 0.5, y = 0.5, label = "中心" },
    right = { x = 1.0, y = 0.5, label = "右中" },
    bottom_left = { x = 0.0, y = 1.0, label = "左下" },
    bottom = { x = 0.5, y = 1.0, label = "下中" },
    bottom_right = { x = 1.0, y = 1.0, label = "右下" },
}
local ANCHOR_PRESET_ORDER = {
    "top_left", "top", "top_right",
    "left", "center", "right",
    "bottom_left", "bottom", "bottom_right",
}

local function NormalizePoint01(x, y)
    x, y = tonumber(x), tonumber(y)
    if x == nil or y == nil then return nil, nil, "normalized_point_required" end
    if x < 0 or x > 1 or y < 0 or y > 1 then return nil, nil, "normalized_point_out_of_range" end
    return x, y, nil
end

local function ResolveAnchorAbsolute(parentRect, anchorX, anchorY)
    return parentRect.x + parentRect.width * anchorX, parentRect.y + parentRect.height * anchorY
end

local function BuildPlacement(parentRect, rect, anchorX, anchorY, pivotX, pivotY)
    local anchorAbsX, anchorAbsY = ResolveAnchorAbsolute(parentRect, anchorX, anchorY)
    return {
        positionX = (rect.x + rect.width * pivotX) - anchorAbsX,
        positionY = (rect.y + rect.height * pivotY) - anchorAbsY,
        width = rect.width,
        height = rect.height,
        anchorX = anchorX,
        anchorY = anchorY,
        pivotX = pivotX,
        pivotY = pivotY,
    }
end

local function BuildRect(parentRect, placement)
    local anchorAbsX, anchorAbsY = ResolveAnchorAbsolute(parentRect, placement.anchorX, placement.anchorY)
    return {
        x = anchorAbsX + placement.positionX - placement.width * placement.pivotX,
        y = anchorAbsY + placement.positionY - placement.height * placement.pivotY,
        width = placement.width,
        height = placement.height,
    }
end

local AnchorPivotModel = {}
AnchorPivotModel.__index = AnchorPivotModel

function AnchorPivotModel:_Commit(nextState, source)
    self.parentRect = nextState.parentRect
    self.rect = nextState.rect
    self.anchorX, self.anchorY = nextState.anchorX, nextState.anchorY
    self.pivotX, self.pivotY = nextState.pivotX, nextState.pivotY
    self.positionX, self.positionY = nextState.positionX, nextState.positionY
    self.revision = (tonumber(self.revision) or 0) + 1
    self.lastSource = tostring(source or "program")
    self.lastError = nil
    RSUI.metrics.layoutEditorAnchorPivotChanges = (tonumber(RSUI.metrics.layoutEditorAnchorPivotChanges) or 0) + 1
    return true, nil
end

function AnchorPivotModel:_StateFromRect(parentRect, rect, anchorX, anchorY, pivotX, pivotY)
    parentRect, rect = CopyRect(parentRect), CopyRect(rect)
    if parentRect == nil then return nil, "anchor_parent_rect_invalid" end
    if rect == nil then return nil, "anchor_rect_invalid" end
    local placement = BuildPlacement(parentRect, rect, anchorX, anchorY, pivotX, pivotY)
    return {
        parentRect = parentRect, rect = rect,
        anchorX = anchorX, anchorY = anchorY, pivotX = pivotX, pivotY = pivotY,
        positionX = placement.positionX, positionY = placement.positionY,
    }
end

function AnchorPivotModel:GetPreset()
    for _, key in ipairs(ANCHOR_PRESET_ORDER) do
        local preset = ANCHOR_PRESETS[key]
        if math.abs(self.anchorX - preset.x) < 0.0001 and math.abs(self.anchorY - preset.y) < 0.0001 then return key end
    end
    return "custom"
end

function AnchorPivotModel:GetRect()
    return CopyRect(self.rect)
end

function AnchorPivotModel:GetParentRect()
    return CopyRect(self.parentRect)
end

function AnchorPivotModel:GetPlacement()
    return {
        positionX = self.positionX, positionY = self.positionY,
        width = self.rect.width, height = self.rect.height,
        anchorX = self.anchorX, anchorY = self.anchorY,
        pivotX = self.pivotX, pivotY = self.pivotY,
    }
end

function AnchorPivotModel:GetSnapshot()
    return {
        id = self.id,
        contractVersion = tonumber(RSUI.AnchorPivotContractVersion) or 0,
        revision = tonumber(self.revision) or 0,
        rect = self:GetRect(), parentRect = self:GetParentRect(),
        anchorX = self.anchorX, anchorY = self.anchorY, anchorPreset = self:GetPreset(),
        pivotX = self.pivotX, pivotY = self.pivotY,
        positionX = self.positionX, positionY = self.positionY,
        stretchSupported = false,
        coordinateSystem = S.Layout and type(S.Layout.GetCoordinateSystemSnapshot) == "function" and S.Layout:GetCoordinateSystemSnapshot() or nil,
        lastSource = self.lastSource, lastError = self.lastError,
    }
end

function AnchorPivotModel:SetRect(rect, source)
    local nextState, err = self:_StateFromRect(self.parentRect, rect, self.anchorX, self.anchorY, self.pivotX, self.pivotY)
    if nextState == nil then self.lastError = err; return false, err end
    return self:_Commit(nextState, source or "rect")
end

-- Full-state restore for editor transactions. This is intentionally stricter
-- than SetRect(): anchor/pivot changes are part of the same user edit and must
-- roll back together when an external persistence adapter rejects the commit.
function AnchorPivotModel:ApplySnapshot(snapshot, source)
    if type(snapshot) ~= "table" then self.lastError = "anchor_snapshot_required"; return false, self.lastError end
    local parentRect = CopyRect(snapshot.parentRect)
    local rect = CopyRect(snapshot.rect)
    if parentRect == nil then self.lastError = "anchor_snapshot_parent_rect_invalid"; return false, self.lastError end
    if rect == nil then self.lastError = "anchor_snapshot_rect_invalid"; return false, self.lastError end
    local anchorX, anchorY = tonumber(snapshot.anchorX), tonumber(snapshot.anchorY)
    local pivotX, pivotY = tonumber(snapshot.pivotX), tonumber(snapshot.pivotY)
    local _, _, err = NormalizePoint01(anchorX, anchorY)
    if err ~= nil then self.lastError = "anchor_snapshot_anchor_invalid"; return false, self.lastError end
    _, _, err = NormalizePoint01(pivotX, pivotY)
    if err ~= nil then self.lastError = "anchor_snapshot_pivot_invalid"; return false, self.lastError end
    local nextState, stateErr = self:_StateFromRect(parentRect, rect, anchorX, anchorY, pivotX, pivotY)
    if nextState == nil then self.lastError = stateErr; return false, stateErr end
    return self:_Commit(nextState, source or "snapshot_restore")
end

function AnchorPivotModel:SetAnchor(anchorX, anchorY, preserveVisual, source)
    anchorX, anchorY, source = tonumber(anchorX), tonumber(anchorY), source or "anchor"
    local _, _, err = NormalizePoint01(anchorX, anchorY)
    if err ~= nil then self.lastError = err; return false, err end
    local nextState
    if preserveVisual ~= false then
        nextState, err = self:_StateFromRect(self.parentRect, self.rect, anchorX, anchorY, self.pivotX, self.pivotY)
    else
        local placement = self:GetPlacement()
        placement.anchorX, placement.anchorY = anchorX, anchorY
        local rect = BuildRect(self.parentRect, placement)
        nextState, err = self:_StateFromRect(self.parentRect, rect, anchorX, anchorY, self.pivotX, self.pivotY)
    end
    if nextState == nil then self.lastError = err; return false, err end
    return self:_Commit(nextState, source)
end

function AnchorPivotModel:SetAnchorPreset(key, preserveVisual, source)
    key = tostring(key or "")
    local preset = ANCHOR_PRESETS[key]
    if preset == nil then self.lastError = "anchor_preset_invalid:" .. key; return false, self.lastError end
    return self:SetAnchor(preset.x, preset.y, preserveVisual, source or ("anchor_preset:" .. key))
end

function AnchorPivotModel:SetPivot(pivotX, pivotY, preserveVisual, source)
    pivotX, pivotY, source = tonumber(pivotX), tonumber(pivotY), source or "pivot"
    local _, _, err = NormalizePoint01(pivotX, pivotY)
    if err ~= nil then self.lastError = err; return false, err end
    local nextState
    if preserveVisual ~= false then
        nextState, err = self:_StateFromRect(self.parentRect, self.rect, self.anchorX, self.anchorY, pivotX, pivotY)
    else
        local placement = self:GetPlacement()
        placement.pivotX, placement.pivotY = pivotX, pivotY
        local rect = BuildRect(self.parentRect, placement)
        nextState, err = self:_StateFromRect(self.parentRect, rect, self.anchorX, self.anchorY, pivotX, pivotY)
    end
    if nextState == nil then self.lastError = err; return false, err end
    return self:_Commit(nextState, source)
end

-- Parent resize/reflow must be explicit. `preserveVisual=true` keeps the exact
-- current screen rect and merely recomputes offsets. `false` keeps anchor/pivot
-- placement offsets so the widget follows its anchor when the parent changes.
function AnchorPivotModel:SetParentRect(parentRect, preserveVisual, source)
    parentRect = CopyRect(parentRect)
    if parentRect == nil then self.lastError = "anchor_parent_rect_invalid"; return false, self.lastError end
    local nextState, err
    if preserveVisual == true then
        nextState, err = self:_StateFromRect(parentRect, self.rect, self.anchorX, self.anchorY, self.pivotX, self.pivotY)
    else
        local placement = self:GetPlacement()
        local rect = BuildRect(parentRect, placement)
        nextState, err = self:_StateFromRect(parentRect, rect, self.anchorX, self.anchorY, self.pivotX, self.pivotY)
    end
    if nextState == nil then self.lastError = err; return false, err end
    return self:_Commit(nextState, source or "parent_rect")
end

function AnchorPivotModel:SetPlacement(positionX, positionY, width, height, source)
    positionX, positionY = tonumber(positionX), tonumber(positionY)
    width, height = tonumber(width), tonumber(height)
    if positionX == nil or positionY == nil or width == nil or height == nil or width <= 0 or height <= 0 then
        self.lastError = "anchor_placement_invalid"
        return false, self.lastError
    end
    local placement = {
        positionX = positionX, positionY = positionY, width = width, height = height,
        anchorX = self.anchorX, anchorY = self.anchorY, pivotX = self.pivotX, pivotY = self.pivotY,
    }
    local nextState, err = self:_StateFromRect(self.parentRect, BuildRect(self.parentRect, placement),
        self.anchorX, self.anchorY, self.pivotX, self.pivotY)
    if nextState == nil then self.lastError = err; return false, err end
    return self:_Commit(nextState, source or "placement")
end

function AnchorPivotModel:Nudge(deltaX, deltaY, source)
    deltaX, deltaY = tonumber(deltaX) or 0, tonumber(deltaY) or 0
    local rect = self:GetRect()
    rect.x, rect.y = rect.x + deltaX, rect.y + deltaY
    return self:SetRect(rect, source or "nudge")
end
function AnchorPivotModel:MoveUp(distance) return self:Nudge(0, -math.abs(N(distance, 1)), "move_up") end
function AnchorPivotModel:MoveDown(distance) return self:Nudge(0, math.abs(N(distance, 1)), "move_down") end
function AnchorPivotModel:MoveLeft(distance) return self:Nudge(-math.abs(N(distance, 1)), 0, "move_left") end
function AnchorPivotModel:MoveRight(distance) return self:Nudge(math.abs(N(distance, 1)), 0, "move_right") end

function RSUI:CreateAnchorPivotModel(options)
    options = type(options) == "table" and options or {}
    local parentRect, rect = CopyRect(options.parentRect), CopyRect(options.rect)
    if parentRect == nil then return nil, "anchor_parent_rect_required" end
    if rect == nil then return nil, "anchor_rect_required" end
    local anchorX, anchorY = N(options.anchorX, 0), N(options.anchorY, 0)
    local pivotX, pivotY = N(options.pivotX, 0), N(options.pivotY, 0)
    local _, _, err = NormalizePoint01(anchorX, anchorY)
    if err ~= nil then return nil, err end
    _, _, err = NormalizePoint01(pivotX, pivotY)
    if err ~= nil then return nil, err end
    local placement = BuildPlacement(parentRect, rect, anchorX, anchorY, pivotX, pivotY)
    local model = setmetatable({
        id = tostring(options.id or "anchor_pivot"),
        parentRect = parentRect, rect = rect,
        anchorX = anchorX, anchorY = anchorY, pivotX = pivotX, pivotY = pivotY,
        positionX = placement.positionX, positionY = placement.positionY,
        revision = 0, lastSource = "init", lastError = nil,
    }, AnchorPivotModel)
    RSUI.metrics.layoutEditorAnchorPivotModelsCreated = (tonumber(RSUI.metrics.layoutEditorAnchorPivotModelsCreated) or 0) + 1
    return model, nil
end

RSUI.AnchorPivotModel = AnchorPivotModel
RSUI.AnchorPresets = { order = ANCHOR_PRESET_ORDER, values = ANCHOR_PRESETS }

------------------------------------------------------------------------
-- LayoutEditorSnapSettingsModel v1
------------------------------------------------------------------------
local HARD_MAX_CANDIDATES = 1024
local SnapSettingsModel = {}
SnapSettingsModel.__index = SnapSettingsModel

local function PickBool(source, previous, key, fallback)
    if source[key] ~= nil then return source[key] == true end
    if previous[key] ~= nil then return previous[key] == true end
    return fallback == true
end

local SNAP_BOOLEAN_KEYS = {
    "enabled", "gridEnabled", "alignmentEnabled", "canvasEnabled", "showGuides",
}
local SNAP_NUMBER_KEYS = {
    "gridSize", "threshold", "maxCandidates",
}

local function ValidateSnapPatch(source)
    if type(source) ~= "table" then return false, "snap_settings_patch_required" end
    for _, key in ipairs(SNAP_BOOLEAN_KEYS) do
        if source[key] ~= nil and type(source[key]) ~= "boolean" then
            return false, "snap_settings_" .. key .. "_boolean_required"
        end
    end
    for _, key in ipairs(SNAP_NUMBER_KEYS) do
        if source[key] ~= nil and tonumber(source[key]) == nil then
            return false, "snap_settings_" .. key .. "_number_required"
        end
    end
    return true, nil
end

local function NormalizeSnapState(source, previous)
    source = type(source) == "table" and source or {}
    previous = type(previous) == "table" and previous or {}
    local nextState = {
        enabled = PickBool(source, previous, "enabled", true),
        gridEnabled = PickBool(source, previous, "gridEnabled", true),
        alignmentEnabled = PickBool(source, previous, "alignmentEnabled", true),
        canvasEnabled = PickBool(source, previous, "canvasEnabled", true),
        showGuides = PickBool(source, previous, "showGuides", true),
        gridSize = Clamp(source.gridSize ~= nil and source.gridSize or previous.gridSize or 8, 1, 128),
        threshold = Clamp(source.threshold ~= nil and source.threshold or previous.threshold or 6, 0, 32),
        maxCandidates = math.floor(Clamp(source.maxCandidates ~= nil and source.maxCandidates or previous.maxCandidates or 256, 1, HARD_MAX_CANDIDATES)),
    }
    return nextState
end

function SnapSettingsModel:GetSnapshot()
    return {
        id = self.id,
        contractVersion = tonumber(RSUI.LayoutEditorSnapSettingsContractVersion) or 0,
        revision = tonumber(self.revision) or 0,
        enabled = self.enabled == true,
        gridEnabled = self.gridEnabled == true,
        alignmentEnabled = self.alignmentEnabled == true,
        canvasEnabled = self.canvasEnabled == true,
        showGuides = self.showGuides == true,
        gridSize = self.gridSize,
        threshold = self.threshold,
        maxCandidates = self.maxCandidates,
        hardMaxCandidates = HARD_MAX_CANDIDATES,
        lastSource = self.lastSource,
        lastError = self.lastError,
    }
end

function SnapSettingsModel:SetPatch(patch, source)
    local valid, validationError = ValidateSnapPatch(patch)
    if valid ~= true then
        self.lastError = validationError
        return false, validationError
    end
    local nextState = NormalizeSnapState(patch, self)
    self.enabled = nextState.enabled
    self.gridEnabled = nextState.gridEnabled
    self.alignmentEnabled = nextState.alignmentEnabled
    self.canvasEnabled = nextState.canvasEnabled
    self.showGuides = nextState.showGuides
    self.gridSize = nextState.gridSize
    self.threshold = nextState.threshold
    self.maxCandidates = nextState.maxCandidates
    self.revision = (tonumber(self.revision) or 0) + 1
    self.lastSource = tostring(source or "snap_settings")
    self.lastError = nil
    RSUI.metrics.layoutEditorSnapSettingsChanges = (tonumber(RSUI.metrics.layoutEditorSnapSettingsChanges) or 0) + 1
    return true, nil
end

function SnapSettingsModel:ToResolverOptions(extra)
    extra = type(extra) == "table" and extra or {}
    local out = {}
    for key, value in pairs(extra) do out[key] = value end
    out.enabled = self.enabled == true
    out.gridEnabled = self.enabled == true and self.gridEnabled == true
    out.alignmentEnabled = self.enabled == true and self.alignmentEnabled == true
    out.includeCanvas = out.alignmentEnabled == true and self.canvasEnabled == true and extra.includeCanvas ~= false
    out.showGuides = self.showGuides == true
    out.gridSize = self.gridSize
    out.threshold = self.threshold
    out.maxCandidates = self.maxCandidates
    return out
end

function RSUI:CreateLayoutEditorSnapSettingsModel(options)
    options = type(options) == "table" and options or {}
    local valid, validationError = ValidateSnapPatch(options)
    if valid ~= true then return nil, validationError end
    local initial = NormalizeSnapState(options, {
        enabled = true, gridEnabled = true, alignmentEnabled = true,
        canvasEnabled = true, showGuides = true,
        gridSize = 8, threshold = 6, maxCandidates = 256,
    })
    local model = setmetatable({
        id = tostring(options.id or "layout_editor_snap"),
        enabled = initial.enabled, gridEnabled = initial.gridEnabled,
        alignmentEnabled = initial.alignmentEnabled, canvasEnabled = initial.canvasEnabled,
        showGuides = initial.showGuides, gridSize = initial.gridSize,
        threshold = initial.threshold, maxCandidates = initial.maxCandidates,
        revision = 0, lastSource = "init", lastError = nil,
    }, SnapSettingsModel)
    RSUI.metrics.layoutEditorSnapSettingsModelsCreated = (tonumber(RSUI.metrics.layoutEditorSnapSettingsModelsCreated) or 0) + 1
    return model
end

RSUI.LayoutEditorSnapSettingsModel = SnapSettingsModel
