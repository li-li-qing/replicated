------------------------------------------------------------------------
-- Replicated Suite - RSUI Selection Geometry + Layout Guides v1
--
-- Shared editor math for HUD/layout tools.  SelectionModel remains the sole
-- authority for *which* logical keys are selected; this module derives only
-- *where* those selections are and how editor handles/guides should resolve.
--
-- Coordinate contract inherited from S.Layout:
--   origin = top-left, +X = right, +Y = down.
-- Therefore "move up" always means negative Y.
--
-- Performance contract:
--   * no Tick / permanent OnUpdate;
--   * selection geometry resolves only on explicit caller request;
--   * guide candidates are bounded (default 256, hard cap 1024);
--   * all handle/snap math is O(selected + bounded candidates).
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local RSUI = S.RSUI
if type(RSUI) ~= "table" then return end

RSUI.SelectionGeometryContractVersion = 1
RSUI.LayoutGuideResolverContractVersion = 1

local HARD_MAX_SELECTED = 512
local HARD_MAX_CANDIDATES = 1024

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
    return { x = rect.x, y = rect.y, width = rect.width, height = rect.height,
        right = rect.right, bottom = rect.bottom, centerX = rect.centerX, centerY = rect.centerY }
end

local function NormalizeRect(rect)
    if type(rect) ~= "table" then return nil, "rect_required" end
    local x, y = tonumber(rect.x), tonumber(rect.y)
    local width = tonumber(rect.width or rect.w)
    local height = tonumber(rect.height or rect.h)
    if x == nil or y == nil or width == nil or height == nil then return nil, "rect_numbers_required" end
    if width <= 0 or height <= 0 then return nil, "rect_extent_must_be_positive" end
    return {
        x = x, y = y, width = width, height = height,
        right = x + width, bottom = y + height,
        centerX = x + width * 0.5, centerY = y + height * 0.5,
    }, nil
end

local function UnionRect(a, b)
    if a == nil then return CopyRect(b) end
    local left = math.min(a.x, b.x)
    local top = math.min(a.y, b.y)
    local right = math.max(a.right, b.right)
    local bottom = math.max(a.bottom, b.bottom)
    return {
        x = left, y = top, width = right - left, height = bottom - top,
        right = right, bottom = bottom,
        centerX = (left + right) * 0.5, centerY = (top + bottom) * 0.5,
    }
end

local SelectionGeometry = { version = 1 }
RSUI.SelectionGeometry = SelectionGeometry

function SelectionGeometry:NormalizeRect(rect)
    return NormalizeRect(rect)
end

function SelectionGeometry:UnionRects(rects, maxRects)
    if type(rects) ~= "table" then return nil, "rects_required" end
    maxRects = math.max(1, math.min(math.floor(N(maxRects, 64)), HARD_MAX_SELECTED))
    local bounds, scanned = nil, 0
    for _, value in ipairs(rects) do
        if scanned >= maxRects then return bounds, "rect_limit_exceeded", scanned end
        local rect, err = NormalizeRect(value)
        if rect == nil then return nil, err, scanned end
        bounds = UnionRect(bounds, rect)
        scanned = scanned + 1
    end
    return bounds, nil, scanned
end

------------------------------------------------------------------------
-- 8-way editor handle geometry
------------------------------------------------------------------------
local HANDLE_POINTS = {
    top_left = function(r) return r.x, r.y end,
    top = function(r) return r.centerX, r.y end,
    top_right = function(r) return r.right, r.y end,
    right = function(r) return r.right, r.centerY end,
    bottom_right = function(r) return r.right, r.bottom end,
    bottom = function(r) return r.centerX, r.bottom end,
    bottom_left = function(r) return r.x, r.bottom end,
    left = function(r) return r.x, r.centerY end,
}
local HANDLE_ORDER = { "top_left", "top_right", "bottom_right", "bottom_left", "top", "right", "bottom", "left" }
local HANDLE_CURSOR = {
    top_left = "D1", bottom_right = "D1", top_right = "D2", bottom_left = "D2",
    top = "V", bottom = "V", left = "H", right = "H",
}

function SelectionGeometry:GetHandleRects(rect, options)
    rect = NormalizeRect(rect)
    if rect == nil then return nil, "rect_required" end
    options = type(options) == "table" and options or {}
    local size = Clamp(options.size or 8, 4, 32)
    local hitSlop = Clamp(options.hitSlop or 3, 0, 12)
    local half = size * 0.5
    local result = {}
    for _, key in ipairs(HANDLE_ORDER) do
        local px, py = HANDLE_POINTS[key](rect)
        result[#result + 1] = {
            key = key, direction = key, cursor = HANDLE_CURSOR[key],
            x = px - half, y = py - half, width = size, height = size,
            hitX = px - half - hitSlop, hitY = py - half - hitSlop,
            hitWidth = size + hitSlop * 2, hitHeight = size + hitSlop * 2,
            centerX = px, centerY = py,
        }
    end
    return result, nil
end

function SelectionGeometry:HitTestHandle(x, y, rect, options)
    x, y = tonumber(x), tonumber(y)
    if x == nil or y == nil then return nil, "point_required" end
    local handles, err = self:GetHandleRects(rect, options)
    if handles == nil then return nil, err end
    for _, handle in ipairs(handles) do
        if x >= handle.hitX and x <= handle.hitX + handle.hitWidth
            and y >= handle.hitY and y <= handle.hitY + handle.hitHeight then
            return handle.key, handle
        end
    end
    return nil, nil
end

------------------------------------------------------------------------
-- SelectionGeometryModel: derives geometry from SelectionModel; never owns keys.
------------------------------------------------------------------------
local SelectionGeometryModel = {}
SelectionGeometryModel.__index = SelectionGeometryModel

function SelectionGeometryModel:SetRectProvider(provider)
    if type(provider) ~= "function" then return false, "rect_provider_required" end
    self.getRect = provider
    return true, nil
end

function SelectionGeometryModel:Resolve()
    local selection = self.selectionModel
    if type(selection) ~= "table" or type(selection.GetSelectedKeys) ~= "function"
        or type(selection.GetPrimaryKey) ~= "function" then
        self.lastError = "selection_model_required"
        return false, self.lastError
    end
    if type(self.getRect) ~= "function" then
        self.lastError = "rect_provider_required"
        return false, self.lastError
    end

    local keys = selection:GetSelectedKeys()
    if #keys > self.maxSelected then
        self.lastError = "selection_geometry_max_selected_exceeded"
        return false, self.lastError
    end

    local nextRects, nextBounds = {}, nil
    local nextPrimary = nil
    local primaryKey = selection:GetPrimaryKey()
    for _, key in ipairs(keys) do
        local ok, raw = pcall(self.getRect, key, self)
        if not ok then self.lastError = "selection_rect_provider_failed:" .. tostring(key); return false, self.lastError end
        local rect, err = NormalizeRect(raw)
        if rect == nil then
            self.lastError = "selection_rect_invalid:" .. tostring(key) .. ":" .. tostring(err)
            return false, self.lastError
        end
        nextRects[key] = rect
        nextBounds = UnionRect(nextBounds, rect)
        if key == primaryKey then nextPrimary = rect end
    end

    self.rects = nextRects
    self.bounds = nextBounds
    self.primaryRect = nextPrimary
    self.primaryKey = primaryKey
    self.count = #keys
    self.revision = (tonumber(self.revision) or 0) + 1
    self.lastError = nil
    RSUI.metrics.selectionGeometryResolves = (tonumber(RSUI.metrics.selectionGeometryResolves) or 0) + 1
    return true, nil
end

function SelectionGeometryModel:GetBounds()
    return self.bounds and CopyRect(self.bounds) or nil
end

function SelectionGeometryModel:GetPrimaryRect()
    return self.primaryRect and CopyRect(self.primaryRect) or nil
end

function SelectionGeometryModel:GetRect(key)
    key = key ~= nil and tostring(key) or nil
    local rect = key and self.rects[key] or nil
    return rect and CopyRect(rect) or nil
end

function SelectionGeometryModel:GetHandleRects(options)
    local rect = self:GetBounds()
    if rect == nil then return {}, nil end
    return SelectionGeometry:GetHandleRects(rect, options)
end

function SelectionGeometryModel:GetSnapshot()
    return {
        id = self.id,
        contractVersion = tonumber(RSUI.SelectionGeometryContractVersion) or 0,
        revision = tonumber(self.revision) or 0,
        count = tonumber(self.count) or 0,
        primaryKey = self.primaryKey,
        bounds = self:GetBounds(),
        lastError = self.lastError,
        maxSelected = self.maxSelected,
    }
end

function RSUI:CreateSelectionGeometryModel(options)
    options = type(options) == "table" and options or {}
    local model = setmetatable({
        id = tostring(options.id or "selection_geometry"),
        selectionModel = options.selectionModel,
        getRect = options.getRect,
        maxSelected = math.max(1, math.min(math.floor(N(options.maxSelected, 64)), HARD_MAX_SELECTED)),
        rects = {}, bounds = nil, primaryRect = nil, primaryKey = nil,
        count = 0, revision = 0, lastError = nil,
    }, SelectionGeometryModel)
    RSUI.metrics.selectionGeometryModelsCreated = (tonumber(RSUI.metrics.selectionGeometryModelsCreated) or 0) + 1
    if options.resolveOnCreate == true then model:Resolve() end
    return model
end

RSUI.SelectionGeometryModel = SelectionGeometryModel

------------------------------------------------------------------------
-- LayoutGuideResolver v1
--
-- Caller first computes a proposed rect (normally RectTransformTransaction),
-- then asks this resolver to align the active move/resize anchors.  The resolver
-- returns a new rect + at most one X and one Y guide. It never mutates widgets.
------------------------------------------------------------------------
local GuideResolver = { version = 1 }
RSUI.LayoutGuideResolver = GuideResolver

local function NormalizeHandle(handle)
    handle = tostring(handle or "move"):lower():gsub("%-", "_")
    if handle == "resize" then return "bottom_right" end
    local valid = {
        move=true, left=true, right=true, top=true, bottom=true,
        top_left=true, top_right=true, bottom_left=true, bottom_right=true,
    }
    if valid[handle] then return handle end
    return nil
end

local function HasLeft(handle) return handle == "left" or handle == "top_left" or handle == "bottom_left" end
local function HasRight(handle) return handle == "right" or handle == "top_right" or handle == "bottom_right" end
local function HasTop(handle) return handle == "top" or handle == "top_left" or handle == "top_right" end
local function HasBottom(handle) return handle == "bottom" or handle == "bottom_left" or handle == "bottom_right" end

local function XAnchors(rect, handle)
    if handle == "move" then
        return { { name="left", value=rect.x }, { name="center", value=rect.centerX }, { name="right", value=rect.right } }
    end
    if HasLeft(handle) then return { { name="left", value=rect.x } } end
    if HasRight(handle) then return { { name="right", value=rect.right } } end
    return {}
end

local function YAnchors(rect, handle)
    if handle == "move" then
        return { { name="top", value=rect.y }, { name="center", value=rect.centerY }, { name="bottom", value=rect.bottom } }
    end
    if HasTop(handle) then return { { name="top", value=rect.y } } end
    if HasBottom(handle) then return { { name="bottom", value=rect.bottom } } end
    return {}
end

local function CandidateAnchors(rect, axis)
    if axis == "x" then
        return { { name="left", value=rect.x }, { name="center", value=rect.centerX }, { name="right", value=rect.right } }
    end
    return { { name="top", value=rect.y }, { name="center", value=rect.centerY }, { name="bottom", value=rect.bottom } }
end

local function BetterSnap(current, delta, kind, movingAnchor, targetAnchor, sourceKey, sourceRect)
    local absDelta = math.abs(delta)
    local sameAnchor = movingAnchor == targetAnchor and 0 or 1
    local kindPenalty = kind == "alignment" and 0 or 1
    if current == nil or absDelta < current.absDelta - 0.0001
        or (math.abs(absDelta - current.absDelta) <= 0.0001 and sameAnchor < current.sameAnchor)
        or (math.abs(absDelta - current.absDelta) <= 0.0001 and sameAnchor == current.sameAnchor and kindPenalty < current.kindPenalty) then
        return {
            delta = delta, absDelta = absDelta, kind = kind,
            movingAnchor = movingAnchor, targetAnchor = targetAnchor,
            sameAnchor = sameAnchor, kindPenalty = kindPenalty,
            sourceKey = sourceKey, sourceRect = sourceRect,
        }
    end
    return current
end

local function ResolveAxis(axis, rect, handle, options)
    local threshold = Clamp(options.threshold or 6, 0, 32)
    local moving = axis == "x" and XAnchors(rect, handle) or YAnchors(rect, handle)
    if #moving == 0 then return nil, 0, false end
    local best, scanned = nil, 0
    local maxCandidates = math.max(1, math.min(math.floor(N(options.maxCandidates, 256)), HARD_MAX_CANDIDATES))
    local candidates = type(options.candidates) == "table" and options.candidates or {}
    if options.alignmentEnabled ~= false then
        for index, raw in ipairs(candidates) do
            if scanned >= maxCandidates then break end
            local candidate = raw
            local sourceKey = tostring((type(candidate) == "table" and candidate.key) or index)
            local sourceRaw = type(candidate) == "table" and (candidate.rect or candidate) or nil
            local sourceRect = NormalizeRect(sourceRaw)
            if sourceRect ~= nil then
                scanned = scanned + 1
                for _, ma in ipairs(moving) do
                    for _, ta in ipairs(CandidateAnchors(sourceRect, axis)) do
                        local delta = ta.value - ma.value
                        if math.abs(delta) <= threshold then
                            best = BetterSnap(best, delta, "alignment", ma.name, ta.name, sourceKey, sourceRect)
                        end
                    end
                end
            end
        end
    end

    local gridSize = N(options.gridSize, 0)
    if options.gridEnabled == true and gridSize > 0 then
        for _, ma in ipairs(moving) do
            local target = math.floor((ma.value / gridSize) + 0.5) * gridSize
            local delta = target - ma.value
            if math.abs(delta) <= threshold then
                best = BetterSnap(best, delta, "grid", ma.name, "grid", "__grid", nil)
            end
        end
    end
    return best, scanned, #candidates > maxCandidates
end

local function Recompute(rect)
    rect.right = rect.x + rect.width
    rect.bottom = rect.y + rect.height
    rect.centerX = rect.x + rect.width * 0.5
    rect.centerY = rect.y + rect.height * 0.5
    return rect
end

local function ApplyAxisSnap(rect, axis, handle, delta, minWidth, minHeight, maxWidth, maxHeight)
    if delta == nil or delta == 0 then return rect end
    if axis == "x" then
        if handle == "move" then
            rect.x = rect.x + delta
        elseif HasLeft(handle) then
            local fixedRight = rect.right
            local nextWidth = Clamp(rect.width - delta, minWidth, maxWidth)
            rect.width = nextWidth
            rect.x = fixedRight - nextWidth
        elseif HasRight(handle) then
            rect.width = Clamp(rect.width + delta, minWidth, maxWidth)
        end
    else
        if handle == "move" then
            rect.y = rect.y + delta
        elseif HasTop(handle) then
            local fixedBottom = rect.bottom
            local nextHeight = Clamp(rect.height - delta, minHeight, maxHeight)
            rect.height = nextHeight
            rect.y = fixedBottom - nextHeight
        elseif HasBottom(handle) then
            rect.height = Clamp(rect.height + delta, minHeight, maxHeight)
        end
    end
    return Recompute(rect)
end

local function GuideSegment(axis, snap, resolvedRect, canvasRect)
    if snap == nil then return nil end
    local position
    if axis == "x" then
        if snap.movingAnchor == "left" then position = resolvedRect.x
        elseif snap.movingAnchor == "right" then position = resolvedRect.right
        else position = resolvedRect.centerX end
        local y1, y2 = resolvedRect.y, resolvedRect.bottom
        if snap.sourceRect ~= nil then y1 = math.min(y1, snap.sourceRect.y); y2 = math.max(y2, snap.sourceRect.bottom)
        elseif canvasRect ~= nil then y1, y2 = canvasRect.y, canvasRect.bottom end
        return { axis="x", x=position, y1=y1, y2=y2, kind=snap.kind, sourceKey=snap.sourceKey,
            movingAnchor=snap.movingAnchor, targetAnchor=snap.targetAnchor, delta=snap.delta }
    end
    if snap.movingAnchor == "top" then position = resolvedRect.y
    elseif snap.movingAnchor == "bottom" then position = resolvedRect.bottom
    else position = resolvedRect.centerY end
    local x1, x2 = resolvedRect.x, resolvedRect.right
    if snap.sourceRect ~= nil then x1 = math.min(x1, snap.sourceRect.x); x2 = math.max(x2, snap.sourceRect.right)
    elseif canvasRect ~= nil then x1, x2 = canvasRect.x, canvasRect.right end
    return { axis="y", y=position, x1=x1, x2=x2, kind=snap.kind, sourceKey=snap.sourceKey,
        movingAnchor=snap.movingAnchor, targetAnchor=snap.targetAnchor, delta=snap.delta }
end

function GuideResolver:Resolve(proposedRect, handle, options)
    local rect, rectErr = NormalizeRect(proposedRect)
    if rect == nil then return nil, nil, rectErr end
    handle = NormalizeHandle(handle)
    if handle == nil then return nil, nil, "guide_handle_invalid" end
    options = type(options) == "table" and options or {}
    if options.enabled == false then
        RSUI.metrics.layoutGuideResolves = (tonumber(RSUI.metrics.layoutGuideResolves) or 0) + 1
        return CopyRect(rect), {}, nil, {
            candidateCount = 0, sourceCandidateCount = 0, scanned = 0, truncated = false,
            threshold = Clamp(options.threshold or 6, 0, 32), gridEnabled = false, alignmentEnabled = false,
        }
    end

    local canvasRect = nil
    if options.canvasRect ~= nil then canvasRect = NormalizeRect(options.canvasRect) end
    local maxCandidates = math.max(1, math.min(math.floor(N(options.maxCandidates, 256)), HARD_MAX_CANDIDATES))
    local sourceCandidates = type(options.candidates) == "table" and options.candidates or {}
    local candidates = {}
    local includeCanvas = canvasRect ~= nil and options.alignmentEnabled ~= false and options.includeCanvas ~= false
    if includeCanvas then candidates[#candidates + 1] = { key = "__canvas", rect = canvasRect } end
    local sourceBudget = math.max(0, maxCandidates - #candidates)
    local inspected = 0
    for _, candidate in ipairs(sourceCandidates) do
        if inspected >= sourceBudget then break end
        inspected = inspected + 1
        candidates[#candidates + 1] = candidate
    end
    local sourceTruncated = #sourceCandidates > inspected or options.candidatesTruncated == true
    local resolverOptions = {}
    for key, value in pairs(options) do resolverOptions[key] = value end
    resolverOptions.maxCandidates = maxCandidates
    resolverOptions.candidates = candidates

    local xSnap, xScanned, xTruncated = ResolveAxis("x", rect, handle, resolverOptions)
    local ySnap, yScanned, yTruncated = ResolveAxis("y", rect, handle, resolverOptions)
    local result = CopyRect(rect)
    local minWidth = math.max(1, N(options.minWidth, 1))
    local minHeight = math.max(1, N(options.minHeight, 1))
    local maxWidth = tonumber(options.maxWidth)
    local maxHeight = tonumber(options.maxHeight)
    if maxWidth ~= nil then maxWidth = math.max(minWidth, maxWidth) end
    if maxHeight ~= nil then maxHeight = math.max(minHeight, maxHeight) end
    if xSnap ~= nil then ApplyAxisSnap(result, "x", handle, xSnap.delta, minWidth, minHeight, maxWidth, maxHeight) end
    if ySnap ~= nil then ApplyAxisSnap(result, "y", handle, ySnap.delta, minWidth, minHeight, maxWidth, maxHeight) end

    local guides = {}
    local gx = GuideSegment("x", xSnap, result, canvasRect)
    local gy = GuideSegment("y", ySnap, result, canvasRect)
    if gx ~= nil then guides[#guides + 1] = gx end
    if gy ~= nil then guides[#guides + 1] = gy end

    RSUI.metrics.layoutGuideResolves = (tonumber(RSUI.metrics.layoutGuideResolves) or 0) + 1
    RSUI.metrics.layoutGuideCandidatesScanned = (tonumber(RSUI.metrics.layoutGuideCandidatesScanned) or 0) + math.max(xScanned, yScanned)
    RSUI.metrics.layoutGuideSnaps = (tonumber(RSUI.metrics.layoutGuideSnaps) or 0) + #guides

    return result, guides, nil, {
        candidateCount = #candidates,
        sourceCandidateCount = #sourceCandidates,
        scanned = math.max(xScanned, yScanned),
        truncated = sourceTruncated == true or xTruncated == true or yTruncated == true,
        threshold = Clamp(options.threshold or 6, 0, 32),
        gridEnabled = options.gridEnabled == true and N(options.gridSize, 0) > 0,
        alignmentEnabled = options.alignmentEnabled ~= false,
    }
end

function GuideResolver:GetSnapshot()
    return {
        version = self.version,
        contractVersion = tonumber(RSUI.LayoutGuideResolverContractVersion) or 0,
        hardMaxCandidates = HARD_MAX_CANDIDATES,
        coordinateSystem = S.Layout and type(S.Layout.GetCoordinateSystemSnapshot) == "function" and S.Layout:GetCoordinateSystemSnapshot() or nil,
    }
end

function SelectionGeometry:GetSnapshot()
    return {
        version = self.version,
        contractVersion = tonumber(RSUI.SelectionGeometryContractVersion) or 0,
        hardMaxSelected = HARD_MAX_SELECTED,
        handleCount = #HANDLE_ORDER,
        guideResolver = GuideResolver:GetSnapshot(),
    }
end

------------------------------------------------------------------------
-- Selection / Guide visual surfaces v1
--
-- These are presentation-only surfaces. They expose native move/resize hit
-- targets but deliberately do not own drag capture or transform transactions.
-- LayoutEditorGestureController binds those targets through the same proven
-- StartMoving/OnDragStart path used elsewhere; this surface remains visual only.
------------------------------------------------------------------------
RSUI.SelectionOverlayContractVersion = 1
RSUI.LayoutGuideOverlayContractVersion = 1

local UI = S.UI
if type(UI) == "table" and type(RSUI.RegisterType) == "function" then
    local function AccentRGBA(alpha)
        local tone = S.UITokens and type(S.UITokens.Color) == "function" and S.UITokens:Color("accent") or nil
        if type(tone) == "table" then
            return N(tone[1], 0.20), N(tone[2], 0.74), N(tone[3], 0.84), N(alpha, tone[4] or 1.0)
        end
        return 0.20, 0.74, 0.84, N(alpha, 1.0)
    end

    local function AddEdge(host, side, thickness, owner)
        if host == nil or type(host.CreateColorDrawable) ~= "function" then return nil end
        local r, g, b, a = AccentRGBA(0.96)
        local draw = host:CreateColorDrawable(r, g, b, a, "overlay")
        if draw == nil or type(draw.AddAnchor) ~= "function" then return draw end
        draw.rsUiOwner = owner
        if side == "top" then
            draw:AddAnchor("TOPLEFT", host, 0, 0); draw:AddAnchor("TOPRIGHT", host, 0, 0)
            if type(draw.SetHeight) == "function" then draw:SetHeight(thickness) elseif type(draw.SetExtent) == "function" then draw:SetExtent(1, thickness) end
        elseif side == "bottom" then
            draw:AddAnchor("BOTTOMLEFT", host, 0, 0); draw:AddAnchor("BOTTOMRIGHT", host, 0, 0)
            if type(draw.SetHeight) == "function" then draw:SetHeight(thickness) elseif type(draw.SetExtent) == "function" then draw:SetExtent(1, thickness) end
        elseif side == "left" then
            draw:AddAnchor("TOPLEFT", host, 0, 0); draw:AddAnchor("BOTTOMLEFT", host, 0, 0)
            if type(draw.SetWidth) == "function" then draw:SetWidth(thickness) elseif type(draw.SetExtent) == "function" then draw:SetExtent(thickness, 1) end
        else
            draw:AddAnchor("TOPRIGHT", host, 0, 0); draw:AddAnchor("BOTTOMRIGHT", host, 0, 0)
            if type(draw.SetWidth) == "function" then draw:SetWidth(thickness) elseif type(draw.SetExtent) == "function" then draw:SetExtent(thickness, 1) end
        end
        return draw
    end

    RSUI:RegisterType("SelectionOverlay", function(spec)
        local width = math.max(1, N(spec.width, 1))
        local height = math.max(1, N(spec.height, 1))
        local handleSize = Clamp(spec.handleSize or 8, 4, 32)
        local handleHitSlop = Clamp(spec.handleHitSlop or 3, 0, 12)
        local inset = handleSize * 0.5 + handleHitSlop
        -- The native root is expanded around the selected rect so handle hit
        -- targets remain inside their physical parent and cannot be clipped at
        -- the selection edge. The visible frame itself stays exact.
        local root = UI:CreateEmptyWidget(spec.parent, spec.id,
            N(spec.x, 0) - inset, N(spec.y, 0) - inset,
            width + inset * 2, height + inset * 2, false)
        if root == nil then return nil, "selection_overlay_create_failed" end
        local c = RSUI:NewComponent("SelectionOverlay", spec, root)
        c.handleSize = handleSize
        c.handleHitSlop = handleHitSlop
        c.overlayInset = inset
        c.handles = {}
        c.frame = UI:CreateEmptyWidget(root, spec.id .. "_frame", inset, inset, width, height, false, c.owner)
        if c.frame == nil then return nil, "selection_frame_create_failed" end
        c.edges = {
            AddEdge(c.frame, "top", 1, c.owner), AddEdge(c.frame, "bottom", 1, c.owner),
            AddEdge(c.frame, "left", 1, c.owner), AddEdge(c.frame, "right", 1, c.owner),
        }

        -- Full-frame move surface. It is created before resize handles so the
        -- eight handles keep hit-test priority at the perimeter. A tiny-alpha
        -- drawable gives RU clients a real hit surface without changing the
        -- visible selection frame.
        c.moveHit = UI:CreateEmptyWidget(c.frame, spec.id .. "_move_hit", 0, 0, width, height, true, c.owner)
        if c.moveHit == nil then return nil, "selection_move_hit_create_failed" end
        c.moveHit.rsSelectionHandle = "move"
        c.moveHit.rsSelectionCursorIntent = "MOVE"
        if type(c.moveHit.CreateColorDrawable) == "function" then
            local moveFill = c.moveHit:CreateColorDrawable(1, 1, 1, 0.001, "background")
            if moveFill ~= nil and type(moveFill.AddAnchor) == "function" then
                moveFill.rsUiOwner = c.owner
                moveFill:AddAnchor("TOPLEFT", c.moveHit, 0, 0)
                moveFill:AddAnchor("BOTTOMRIGHT", c.moveHit, 0, 0)
            end
            c.moveHit.rsSelectionVisual = moveFill
        end

        for _, key in ipairs(HANDLE_ORDER) do
            local hitSize = c.handleSize + c.handleHitSlop * 2
            local handle = UI:CreateEmptyWidget(root, spec.id .. "_handle_" .. key, 0, 0, hitSize, hitSize, true, c.owner)
            if handle == nil then return nil, "selection_handle_create_failed:" .. key end
            handle.rsSelectionHandle = key
            handle.rsSelectionCursorIntent = HANDLE_CURSOR[key]
            local fill = nil
            if type(handle.CreateColorDrawable) == "function" then
                local r, g, b, a = AccentRGBA(1.0)
                fill = handle:CreateColorDrawable(r, g, b, a, "overlay")
                if fill ~= nil and type(fill.AddAnchor) == "function" then
                    fill.rsUiOwner = c.owner
                    fill:AddAnchor("TOPLEFT", handle, c.handleHitSlop, c.handleHitSlop)
                    fill:AddAnchor("BOTTOMRIGHT", handle, -c.handleHitSlop, -c.handleHitSlop)
                end
            end
            handle.rsSelectionVisual = fill
            c.handles[key] = handle
        end

        function c:GetHandleNative(key)
            return self.handles[tostring(key or "")]
        end

        function c:GetMoveNative()
            return self.moveHit
        end

        function c:SetHandlesPickable(enabled)
            for _, handle in pairs(self.handles) do UI:SetPickable(handle, enabled == true, self.owner) end
            return enabled == true
        end

        function c:SetInteractionPickable(enabled)
            enabled = enabled == true
            if self.moveHit ~= nil then UI:SetPickable(self.moveHit, enabled, self.owner) end
            self:SetHandlesPickable(enabled)
            return enabled
        end

        function c:SetRect(rect)
            local normalized, err = NormalizeRect(rect)
            if normalized == nil then return false, err end
            local currentInset = self.overlayInset
            UI:SetAnchor(self.root, spec.parent, normalized.x - currentInset, normalized.y - currentInset, self.owner)
            UI:SetExtent(self.root, normalized.width + currentInset * 2, normalized.height + currentInset * 2, self.owner)
            UI:SetAnchor(self.frame, self.root, currentInset, currentInset, self.owner)
            UI:SetExtent(self.frame, normalized.width, normalized.height, self.owner)
            if self.moveHit ~= nil then
                UI:SetAnchor(self.moveHit, self.frame, 0, 0, self.owner)
                UI:SetExtent(self.moveHit, normalized.width, normalized.height, self.owner)
            end
            local visualHandles = SelectionGeometry:GetHandleRects({ x=0, y=0, width=normalized.width, height=normalized.height }, {
                size = self.handleSize, hitSlop = self.handleHitSlop,
            })
            for _, info in ipairs(visualHandles or {}) do
                local handle = self.handles[info.key]
                if handle ~= nil then
                    UI:SetAnchor(handle, self.root, info.hitX + currentInset, info.hitY + currentInset, self.owner)
                    UI:SetExtent(handle, info.hitWidth, info.hitHeight, self.owner)
                end
            end
            self:CommitLayoutState(normalized.x - currentInset, normalized.y - currentInset,
                normalized.width + currentInset * 2, normalized.height + currentInset * 2)
            self.lastRect = normalized
            RSUI.metrics.selectionOverlayLayouts = (tonumber(RSUI.metrics.selectionOverlayLayouts) or 0) + 1
            return true, nil
        end

        function c:GetSelectionRect()
            return self.lastRect and CopyRect(self.lastRect) or nil
        end

        function c:Layout(x, y, nextWidth, nextHeight)
            return self:SetRect({ x=N(x, 0), y=N(y, 0), width=math.max(1, N(nextWidth, width)), height=math.max(1, N(nextHeight, height)) })
        end

        function c:SetVisible(visible)
            self.visible = visible == true
            UI:SetVisible(self.root, self.visible, self.owner)
            return self.visible
        end

        c:SetInteractionPickable(spec.handlesPickable ~= false)
        c:SetRect({ x=N(spec.x, 0), y=N(spec.y, 0), width=width, height=height })
        return c
    end)

    local function CreateGuideLine(parent, id, owner)
        local line = UI:CreateEmptyWidget(parent, id, 0, 0, 1, 1, false, owner)
        if line == nil then return nil end
        if type(line.CreateColorDrawable) == "function" then
            local r, g, b, a = AccentRGBA(0.82)
            local fill = line:CreateColorDrawable(r, g, b, a, "overlay")
            if fill ~= nil and type(fill.AddAnchor) == "function" then
                fill.rsUiOwner = owner
                fill:AddAnchor("TOPLEFT", line, 0, 0)
                fill:AddAnchor("BOTTOMRIGHT", line, 0, 0)
            end
        end
        return line
    end

    RSUI:RegisterType("LayoutGuideOverlay", function(spec)
        local width = math.max(1, N(spec.width, 1))
        local height = math.max(1, N(spec.height, 1))
        local root = UI:CreateEmptyWidget(spec.parent, spec.id, N(spec.x, 0), N(spec.y, 0), width, height, false)
        if root == nil then return nil, "guide_overlay_create_failed" end
        local c = RSUI:NewComponent("LayoutGuideOverlay", spec, root)
        c.xLine = CreateGuideLine(root, spec.id .. "_x", c.owner)
        c.yLine = CreateGuideLine(root, spec.id .. "_y", c.owner)
        if c.xLine == nil or c.yLine == nil then return nil, "guide_line_create_failed" end
        UI:SetVisible(c.xLine, false, c.owner)
        UI:SetVisible(c.yLine, false, c.owner)

        function c:SetGuides(guides)
            local xGuide, yGuide = nil, nil
            for _, guide in ipairs(type(guides) == "table" and guides or {}) do
                if guide.axis == "x" and xGuide == nil then xGuide = guide end
                if guide.axis == "y" and yGuide == nil then yGuide = guide end
            end
            if xGuide ~= nil then
                local y1, y2 = N(xGuide.y1, 0), N(xGuide.y2, 0)
                if y2 < y1 then y1, y2 = y2, y1 end
                UI:SetAnchor(self.xLine, self.root, N(xGuide.x, 0), y1, self.owner)
                UI:SetExtent(self.xLine, 1, math.max(1, y2 - y1), self.owner)
                UI:SetVisible(self.xLine, true, self.owner)
            else UI:SetVisible(self.xLine, false, self.owner) end
            if yGuide ~= nil then
                local x1, x2 = N(yGuide.x1, 0), N(yGuide.x2, 0)
                if x2 < x1 then x1, x2 = x2, x1 end
                UI:SetAnchor(self.yLine, self.root, x1, N(yGuide.y, 0), self.owner)
                UI:SetExtent(self.yLine, math.max(1, x2 - x1), 1, self.owner)
                UI:SetVisible(self.yLine, true, self.owner)
            else UI:SetVisible(self.yLine, false, self.owner) end
            self.guides = guides
            RSUI.metrics.layoutGuideOverlayUpdates = (tonumber(RSUI.metrics.layoutGuideOverlayUpdates) or 0) + 1
            return true
        end

        function c:Layout(x, y, nextWidth, nextHeight)
            local nextX, nextY = N(x, 0), N(y, 0)
            local nextW, nextH = math.max(1, N(nextWidth, width)), math.max(1, N(nextHeight, height))
            UI:SetAnchor(self.root, spec.parent, nextX, nextY, self.owner)
            UI:SetExtent(self.root, nextW, nextH, self.owner)
            self:CommitLayoutState(nextX, nextY, nextW, nextH)
            return true
        end

        return c
    end)
end
