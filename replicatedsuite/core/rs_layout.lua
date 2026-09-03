------------------------------------------------------------------------
-- Replicated Suite - Responsive Layout Authority
------------------------------------------------------------------------

if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local C = S.Constants

S.Layout = {
    context = nil,
    invalidated = true,
    lastSignature = nil,
    defaultFloatingBoundary = "free",
}
local L = S.Layout

-- ArcheAge / CryEngine UI logical coordinate contract. The logical origin is
-- the viewport top-left. Positive X travels right; positive Y travels down.
-- Keep this explicit so feature/layout code never guesses the sign of a
-- human instruction such as "move this icon upward".
L.CoordinateSystemContractVersion = 1
L.RectTransformTransactionContractVersion = 2
L.coordinateSystem = {
    origin = "top_left",
    xPositive = "right",
    xNegative = "left",
    yPositive = "down",
    yNegative = "up",
}
L.geometryMetrics = { transformBegins = 0, transformPreviews = 0, transformOverrides = 0, transformCommits = 0, transformCancels = 0, transformRejects = 0 }

local function Clamp(value, minimum, maximum)
    local number = tonumber(value) or 0
    if number < minimum then return minimum end
    if number > maximum then return maximum end
    return number
end

local function CopyRect(rect)
    rect = type(rect) == "table" and rect or {}
    return {
        x = tonumber(rect.x) or 0,
        y = tonumber(rect.y) or 0,
        width = math.max(1, tonumber(rect.width) or 1),
        height = math.max(1, tonumber(rect.height) or 1),
    }
end

local function NormalizeHandle(handle)
    handle = tostring(handle or ""):lower():gsub("%-", "_")
    local valid = {
        top = true, bottom = true, left = true, right = true,
        top_left = true, top_right = true, bottom_left = true, bottom_right = true,
    }
    if valid[handle] then return handle end
    return nil
end

function L:GetCoordinateSystemSnapshot()
    return {
        contractVersion = tonumber(self.CoordinateSystemContractVersion) or 0,
        origin = self.coordinateSystem.origin,
        xPositive = self.coordinateSystem.xPositive,
        xNegative = self.coordinateSystem.xNegative,
        yPositive = self.coordinateSystem.yPositive,
        yNegative = self.coordinateSystem.yNegative,
    }
end

-- Semantic point movement. Distance is treated as a magnitude; the helper owns
-- the sign. In this coordinate system Move Up therefore subtracts Y.
function L:OffsetPoint(x, y, direction, distance)
    x, y = tonumber(x) or 0, tonumber(y) or 0
    local d = math.max(0, tonumber(distance) or 0)
    direction = tostring(direction or ""):lower()
    if direction == "up" then return x, y - d end
    if direction == "down" then return x, y + d end
    if direction == "left" then return x - d, y end
    if direction == "right" then return x + d, y end
    return nil, nil, "coordinate_direction_invalid:" .. tostring(direction)
end

function L:MoveRect(rect, direction, distance)
    local out = CopyRect(rect)
    local x, y, err = self:OffsetPoint(out.x, out.y, direction, distance)
    if err ~= nil then return nil, err end
    out.x, out.y = x, y
    return out, nil
end

-- Pure RectTransform transaction used by editor-like UI. It owns only math and
-- rollback semantics; native pointer capture remains Windowing/Input authority.
-- Delta values are always measured from Begin(), never accumulated frame-to-frame.
function L:CreateRectTransformTransaction(spec)
    spec = type(spec) == "table" and spec or {}
    local tx = {
        active = false, kind = nil, handle = nil, revision = 0,
        minWidth = math.max(1, tonumber(spec.minWidth) or 1),
        minHeight = math.max(1, tonumber(spec.minHeight) or 1),
        maxWidth = tonumber(spec.maxWidth), maxHeight = tonumber(spec.maxHeight),
    }
    if tx.maxWidth ~= nil then tx.maxWidth = math.max(tx.minWidth, tx.maxWidth) end
    if tx.maxHeight ~= nil then tx.maxHeight = math.max(tx.minHeight, tx.maxHeight) end

    function tx:Begin(rect, kind, handle)
        if self.active == true then return false, "rect_transform_already_active" end
        kind = tostring(kind or "move"):lower()
        if kind ~= "move" and kind ~= "resize" then
            L.geometryMetrics.transformRejects = (tonumber(L.geometryMetrics.transformRejects) or 0) + 1
            return false, "rect_transform_kind_invalid:" .. kind
        end
        if kind == "resize" then
            handle = NormalizeHandle(handle)
            if handle == nil then
                L.geometryMetrics.transformRejects = (tonumber(L.geometryMetrics.transformRejects) or 0) + 1
                return false, "rect_transform_handle_invalid"
            end
        else
            handle = nil
        end
        self.startRect = CopyRect(rect)
        self.currentRect = CopyRect(rect)
        self.kind, self.handle, self.active = kind, handle, true
        self.revision = self.revision + 1
        L.geometryMetrics.transformBegins = (tonumber(L.geometryMetrics.transformBegins) or 0) + 1
        return true, CopyRect(self.currentRect)
    end

    local function ClampSize(value, minimum, maximum)
        value = math.max(minimum, tonumber(value) or minimum)
        if maximum ~= nil then value = math.min(value, maximum) end
        return value
    end

    function tx:PreviewDelta(deltaX, deltaY)
        if self.active ~= true or self.startRect == nil then return nil, "rect_transform_not_active" end
        local dx, dy = tonumber(deltaX) or 0, tonumber(deltaY) or 0
        local start = self.startRect
        local out = CopyRect(start)
        if self.kind == "move" then
            out.x, out.y = start.x + dx, start.y + dy
        else
            local left, top = start.x, start.y
            local right, bottom = start.x + start.width, start.y + start.height
            local h = self.handle or ""
            local usesLeft = h == "left" or h == "top_left" or h == "bottom_left"
            local usesRight = h == "right" or h == "top_right" or h == "bottom_right"
            local usesTop = h == "top" or h == "top_left" or h == "top_right"
            local usesBottom = h == "bottom" or h == "bottom_left" or h == "bottom_right"
            if usesLeft then left = left + dx end
            if usesRight then right = right + dx end
            if usesTop then top = top + dy end
            if usesBottom then bottom = bottom + dy end

            local width = ClampSize(right - left, self.minWidth, self.maxWidth)
            local height = ClampSize(bottom - top, self.minHeight, self.maxHeight)
            if usesLeft then left = right - width else right = left + width end
            if usesTop then top = bottom - height else bottom = top + height end
            out.x, out.y, out.width, out.height = left, top, width, height
        end
        self.currentRect = out
        self.revision = self.revision + 1
        L.geometryMetrics.transformPreviews = (tonumber(L.geometryMetrics.transformPreviews) or 0) + 1
        return CopyRect(out), nil
    end

    function tx:OverridePreview(rect)
        if self.active ~= true or self.currentRect == nil then return nil, "rect_transform_not_active" end
        if type(rect) ~= "table" or tonumber(rect.x) == nil or tonumber(rect.y) == nil
            or tonumber(rect.width) == nil or tonumber(rect.height) == nil then
            L.geometryMetrics.transformRejects = (tonumber(L.geometryMetrics.transformRejects) or 0) + 1
            return nil, "rect_transform_override_invalid"
        end
        local out = {
            x = tonumber(rect.x), y = tonumber(rect.y),
            width = ClampSize(rect.width, self.minWidth, self.maxWidth),
            height = ClampSize(rect.height, self.minHeight, self.maxHeight),
        }
        -- When a snapped resize override is clamped, keep the opposite edge
        -- fixed just like PreviewDelta(). This prevents the selection frame from
        -- jumping across the user's stationary edge.
        if self.kind == "resize" then
            local h = self.handle or ""
            local usesLeft = h == "left" or h == "top_left" or h == "bottom_left"
            local usesTop = h == "top" or h == "top_left" or h == "top_right"
            if usesLeft then
                local requestedRight = tonumber(rect.x) + tonumber(rect.width)
                out.x = requestedRight - out.width
            end
            if usesTop then
                local requestedBottom = tonumber(rect.y) + tonumber(rect.height)
                out.y = requestedBottom - out.height
            end
        end
        self.currentRect = out
        self.revision = self.revision + 1
        L.geometryMetrics.transformOverrides = (tonumber(L.geometryMetrics.transformOverrides) or 0) + 1
        return CopyRect(out), nil
    end

    function tx:Commit()
        if self.active ~= true or self.currentRect == nil then return nil, "rect_transform_not_active" end
        local result = CopyRect(self.currentRect)
        self.active = false
        self.startRect = nil
        self.currentRect = nil
        L.geometryMetrics.transformCommits = (tonumber(L.geometryMetrics.transformCommits) or 0) + 1
        return result, nil
    end

    function tx:Cancel()
        if self.active ~= true or self.startRect == nil then return nil, "rect_transform_not_active" end
        local result = CopyRect(self.startRect)
        self.active = false
        self.startRect = nil
        self.currentRect = nil
        L.geometryMetrics.transformCancels = (tonumber(L.geometryMetrics.transformCancels) or 0) + 1
        return result, nil
    end

    function tx:GetSnapshot()
        return {
            contractVersion = tonumber(L.RectTransformTransactionContractVersion) or 0,
            active = self.active == true,
            kind = self.kind, handle = self.handle, revision = tonumber(self.revision) or 0,
            rect = self.currentRect and CopyRect(self.currentRect) or nil,
            coordinateSystem = L:GetCoordinateSystemSnapshot(),
        }
    end
    return tx
end

function L:GetGeometryContractSnapshot()
    return {
        coordinate = self:GetCoordinateSystemSnapshot(),
        rectTransformTransactionContractVersion = tonumber(self.RectTransformTransactionContractVersion) or 0,
        metrics = {
            transformBegins = tonumber(self.geometryMetrics.transformBegins) or 0,
            transformPreviews = tonumber(self.geometryMetrics.transformPreviews) or 0,
            transformOverrides = tonumber(self.geometryMetrics.transformOverrides) or 0,
            transformCommits = tonumber(self.geometryMetrics.transformCommits) or 0,
            transformCancels = tonumber(self.geometryMetrics.transformCancels) or 0,
            transformRejects = tonumber(self.geometryMetrics.transformRejects) or 0,
        },
    }
end

local function ActiveSettings()
    if S.AppState ~= nil and type(S.AppState.settings) == "table" then return S.AppState.settings end
    return {}
end

local function ActiveMainPlacement()
    -- V3 Shell owns its geometry in v3.shell. Layout remains a pure metrics
    -- authority and must not reach back into retired state trees (S.State 已删除).
    return {}
end

function L:BuildContext()
    local screenWidth, screenHeight, uiScale, logicalWidth, logicalHeight = S.Api:GetUiMetrics()
    local addonScale = Clamp(ActiveSettings().addonScale or 1, C.MinAddonScale, C.MaxAddonScale)
    local designWidth = logicalWidth / addonScale
    local designHeight = logicalHeight / addonScale

    local breakpoint = "ULTRAWIDE"
    if designWidth < C.Breakpoint.COMPACT then
        breakpoint = "COMPACT"
    elseif designWidth < C.Breakpoint.STANDARD then
        breakpoint = "STANDARD"
    elseif designWidth < C.Breakpoint.WIDE then
        breakpoint = "WIDE"
    end

    local columns = 3
    if breakpoint == "COMPACT" then
        columns = designWidth < C.Breakpoint.NARROW_ONE_COLUMN and 1 or 2
    end

    local safe = C.SafeArea
    return {
        screenWidth = screenWidth,
        screenHeight = screenHeight,
        uiScale = uiScale,
        addonScale = addonScale,
        effectiveScale = uiScale * addonScale,
        logicalWidth = logicalWidth,
        logicalHeight = logicalHeight,
        designWidth = designWidth,
        designHeight = designHeight,
        safeLeft = safe,
        safeTop = safe,
        safeRight = safe,
        safeBottom = safe,
        usableWidth = math.max(1, logicalWidth - safe * 2),
        usableHeight = math.max(1, logicalHeight - safe * 2),
        aspectRatio = logicalHeight > 0 and logicalWidth / logicalHeight or 1,
        breakpoint = breakpoint,
        columns = columns,
    }
end

function L:GetContext(force)
    if self.context == nil or self.invalidated == true or force == true then
        self.context = self:BuildContext()
        self.invalidated = false
    end
    return self.context
end

-- Synthetic logical viewport used only by on-demand M6 acceptance diagnostics.
-- It intentionally bypasses S.Api and does not update L.context / lastSignature.
function L:BuildSyntheticContext(logicalWidth, logicalHeight, addonScale)
    local width = math.max(1, tonumber(logicalWidth) or 1)
    local height = math.max(1, tonumber(logicalHeight) or 1)
    local scale = Clamp(tonumber(addonScale) or 1, C.MinAddonScale, C.MaxAddonScale)
    local designWidth = width / scale
    local designHeight = height / scale
    local breakpoint = "ULTRAWIDE"
    if designWidth < C.Breakpoint.COMPACT then breakpoint = "COMPACT"
    elseif designWidth < C.Breakpoint.STANDARD then breakpoint = "STANDARD"
    elseif designWidth < C.Breakpoint.WIDE then breakpoint = "WIDE" end
    local columns = 3
    if breakpoint == "COMPACT" then columns = designWidth < C.Breakpoint.NARROW_ONE_COLUMN and 1 or 2 end
    local safe = C.SafeArea
    return {
        screenWidth = width, screenHeight = height, uiScale = 1, addonScale = scale, effectiveScale = scale,
        logicalWidth = width, logicalHeight = height, designWidth = designWidth, designHeight = designHeight,
        safeLeft = safe, safeTop = safe, safeRight = safe, safeBottom = safe,
        usableWidth = math.max(1, width - safe * 2), usableHeight = math.max(1, height - safe * 2),
        aspectRatio = height > 0 and width / height or 1, breakpoint = breakpoint, columns = columns, synthetic = true,
    }
end

function L:Scale(value)
    return (tonumber(value) or 0) * self:GetContext().addonScale
end

function L:Invalidate()
    self.invalidated = true
end

function L:MakeSignature(context)
    return table.concat({
        tostring(math.floor((context.screenWidth or 0) + 0.5)),
        tostring(math.floor((context.screenHeight or 0) + 0.5)),
        string.format("%.4f", tonumber(context.uiScale) or 1),
        string.format("%.2f", tonumber(context.addonScale) or 1),
        tostring(context.breakpoint),
        tostring(context.columns),
    }, ":")
end

function L:PrimeCurrentSignature()
    local context = self:GetContext(true)
    self.lastSignature = self:MakeSignature(context)
    return context
end

-- Apply one responsive presentation transaction. In V3 rebuild mode the
-- active presentation Authority is UIHostManager, not the legacy UI factory.
-- Keeping this bridge here prevents resolution/UI-scale changes from falling
-- through into legacy state-dependent code (S.State 已删除, 不加载).
function L:ApplyResponsivePresentation(fromMetricsChange)
    if S.Theme ~= nil and type(S.Theme.RefreshTypography) == "function" then
        S.Theme:RefreshTypography()
    end
    if S.RSUI ~= nil and type(S.RSUI.RefreshResolutionRoots) == "function" then
        pcall(function() S.RSUI:RefreshResolutionRoots(true) end)
    end
    if tostring(S.ArchitectureMode or "") == "v3_rebuild" then
        if S.UIHostManager ~= nil and type(S.UIHostManager.ApplyResponsiveLayout) == "function"
            and type(S.UIHostManager.GetActive) == "function" and S.UIHostManager:GetActive() ~= nil then
            return S.UIHostManager:ApplyResponsiveLayout(fromMetricsChange == true)
        end
        return false, "V3 presentation host unavailable"
    end
    if S.UI ~= nil and type(S.UI.ApplyResponsiveLayout) == "function" then
        return S.UI:ApplyResponsiveLayout(fromMetricsChange == true)
    end
    return false, "responsive presentation unavailable"
end

-- Immediate refresh used by application-level UI settings. It updates the
-- signature now so the scheduler does not perform a duplicate reflow on its
-- next metrics poll.
function L:RefreshNow(fromMetricsChange)
    local fresh = self:GetContext(true)
    self.lastSignature = self:MakeSignature(fresh)
    self.invalidated = false
    return self:ApplyResponsivePresentation(fromMetricsChange == true)
end

function L:PollChanges()
    local fresh = self:BuildContext()
    local signature = self:MakeSignature(fresh)

    -- Bootstrap is a real layout transition too. Older builds only remembered
    -- the first post-load signature and returned without reflowing. If UIParent
    -- still exposed provisional metrics while the addon was constructing its
    -- widgets, the dashboard stayed packed against those stale dimensions until
    -- the user manually resized the window. Treat the first observation as a
    -- reflow unless Runtime explicitly primed the startup signature.
    if self.lastSignature == nil then
        self.lastSignature = signature
        self.context = fresh
        self.invalidated = false
        self:ApplyResponsivePresentation(true)
        return true
    end
    if signature ~= self.lastSignature then
        self.lastSignature = signature
        self.context = fresh
        self.invalidated = false
        self:ApplyResponsivePresentation(true)
        return true
    end
    return false
end

function L:GetLogicalRect(widget)
    local context = self:GetContext()
    local x, y, width, height = nil, nil, nil, nil
    if widget ~= nil and widget.GetEffectiveOffset ~= nil then
        local ok, a, b = pcall(function() return widget:GetEffectiveOffset() end)
        if ok then x, y = tonumber(a), tonumber(b) end
    end
    if widget ~= nil and widget.GetEffectiveExtent ~= nil then
        local ok, a, b = pcall(function() return widget:GetEffectiveExtent() end)
        if ok then width, height = tonumber(a), tonumber(b) end
    end
    if x ~= nil and y ~= nil then
        x = x / context.uiScale
        y = y / context.uiScale
    else
        local ok, a, b = pcall(function() return widget:GetOffset() end)
        if ok then x, y = tonumber(a) or 0, tonumber(b) or 0 else x, y = 0, 0 end
    end
    if width ~= nil and height ~= nil then
        width = width / context.uiScale
        height = height / context.uiScale
    else
        width = tonumber(widget and widget:GetWidth()) or 1
        height = tonumber(widget and widget:GetHeight()) or 1
    end
    return x, y, width, height
end

------------------------------------------------------------------------
-- Resolution Safety Authority
--
-- Persistence remains owned by each Domain (Suite placement, DPS rects, Gear
-- quick positions, Healer anchors, etc.).  This layer only guarantees that the
-- live presentation is operable on the CURRENT logical UIParent canvas.  A
-- resolution fallback is therefore deliberately non-persistent unless the user
-- explicitly drags/saves the control in that resolution.
------------------------------------------------------------------------
L.floatingRegistry = L.floatingRegistry or {}
L.screenSnapRegistry = L.screenSnapRegistry or {}
L.screenSnapMetrics = L.screenSnapMetrics or { resolves = 0, snaps = 0, candidates = 0 }
L.safeDrag = L.safeDrag or nil
L.safeDragProxy = L.safeDragProxy or nil

local function WidgetVisible(widget)
    if widget == nil then return false end
    if type(widget.IsVisible) ~= "function" then return true end
    local ok, value = pcall(function() return widget:IsVisible() end)
    return not ok or value == true
end

function L:GetSafeSpawn(index, width, height, options)
    options = type(options) == "table" and options or {}
    local context = self:GetContext()
    local safety = C.ResolutionSafety or {}
    local edge = math.max(0, tonumber(options.edge) or tonumber(safety.edge) or tonumber(C.SafeArea) or 12)
    width = math.max(1, tonumber(width) or 1)
    height = math.max(1, tonumber(height) or 1)
    local maxX = math.max(edge, context.logicalWidth - edge - width)
    local maxY = math.max(edge, context.logicalHeight - edge - height)
    local baseX = Clamp(tonumber(options.baseX) or tonumber(safety.spawnX) or 300, edge, maxX)
    local baseY = Clamp(tonumber(options.baseY) or tonumber(safety.spawnY) or 100, edge, maxY)
    local gapX = math.max(0, tonumber(options.gapX) or tonumber(safety.spawnGapX) or 8)
    local gapY = math.max(0, tonumber(options.gapY) or tonumber(safety.spawnGapY) or 8)
    local stepX = math.max(1, width + gapX)
    local stepY = math.max(1, height + gapY)
    local maxColumns = math.max(1, math.floor(tonumber(options.maxColumns) or tonumber(safety.maxColumns) or 4))
    local columnsThatFit = math.floor((context.logicalWidth - edge - baseX + gapX) / stepX)
    local columns = math.max(1, math.min(maxColumns, columnsThatFit))
    local n = math.max(0, math.floor(tonumber(index) or 1) - 1)
    local x = baseX + (n % columns) * stepX
    local y = baseY + math.floor(n / columns) * stepY
    return Clamp(x, edge, maxX), Clamp(y, edge, maxY)
end

-- Pure sibling-snap solver for small floating controls. It does not write
-- geometry, clamp screen placement, or persist state; callers retain Authority.
-- Candidate placements preserve a caller-defined horizontal/vertical gap and
-- snap only when BOTH axes are within the threshold, avoiding surprising jumps
-- to distant rows/columns.
function L:ResolveSiblingSnap(x, y, width, height, siblings, options)
    options = type(options) == "table" and options or {}
    x, y = tonumber(x), tonumber(y)
    width, height = math.max(1, tonumber(width) or 1), math.max(1, tonumber(height) or 1)
    if x == nil or y == nil then return x, y, false end

    local distance = math.max(0, tonumber(options.distance) or self:Scale(C.SnapDistance or 16))
    local gapX = math.max(0, tonumber(options.gapX) or 0)
    local gapY = math.max(0, tonumber(options.gapY) or 0)
    local bestX, bestY, bestScore, bestIndex = x, y, nil, nil

    local function Consider(cx, cy, index)
        cx, cy = tonumber(cx), tonumber(cy)
        if cx == nil or cy == nil then return end
        local dx, dy = math.abs(cx - x), math.abs(cy - y)
        if dx > distance or dy > distance then return end
        local score = dx * dx + dy * dy
        if bestScore == nil or score < bestScore then
            bestX, bestY, bestScore, bestIndex = cx, cy, score, index
        end
    end

    for index, other in ipairs(type(siblings) == "table" and siblings or {}) do
        local ox, oy = tonumber(other.x), tonumber(other.y)
        local ow, oh = math.max(1, tonumber(other.width) or width), math.max(1, tonumber(other.height) or height)
        if ox ~= nil and oy ~= nil then
            local yAlign = { oy, oy + oh - height, oy + (oh - height) * 0.5 }
            local xAlign = { ox, ox + ow - width, ox + (ow - width) * 0.5 }

            -- Horizontal neighbours: right/left with a stable visual gap.
            for _, ay in ipairs(yAlign) do
                Consider(ox + ow + gapX, ay, index)
                Consider(ox - width - gapX, ay, index)
            end
            -- Vertical neighbours: below/above with a stable visual gap.
            for _, ax in ipairs(xAlign) do
                Consider(ax, oy + oh + gapY, index)
                Consider(ax, oy - height - gapY, index)
            end
        end
    end

    return bestX, bestY, bestScore ~= nil, bestIndex
end

function L:ClampTopLeft(x, y, width, height, options)
    options = type(options) == "table" and options or {}
    local context = self:GetContext()
    local edge = math.max(0, tonumber(options.edge) or context.safeLeft or C.SafeArea or 12)
    width = math.max(1, tonumber(width) or 1)
    height = math.max(1, tonumber(height) or 1)
    local maxX = math.max(edge, context.logicalWidth - edge - math.min(width, math.max(1, context.logicalWidth - edge * 2)))
    local maxY = math.max(edge, context.logicalHeight - edge - math.min(height, math.max(1, context.logicalHeight - edge * 2)))
    return Clamp(tonumber(x) or edge, edge, maxX), Clamp(tonumber(y) or edge, edge, maxY)
end

-- V3 free-placement safety. Normal dragging is intentionally NOT clamped to
-- keep the full window inside the viewport. We only intervene when the window
-- would become unrecoverable: at least a small horizontal grip and a small
-- portion of the top drag handle must remain reachable. This preserves player
-- freedom (including partially off-screen windows) without creating settings
-- that can strand a window permanently outside the current resolution.
function L:ClampRecoverableTopLeft(x, y, width, height, options)
    options = type(options) == "table" and options or {}
    local context = self:GetContext()
    local left = tonumber(context.safeLeft) or 0
    local top = tonumber(context.safeTop) or 0
    local right = math.max(left + 1, (tonumber(context.logicalWidth) or width) - (tonumber(context.safeRight) or 0))
    local bottom = math.max(top + 1, (tonumber(context.logicalHeight) or height) - (tonumber(context.safeBottom) or 0))
    width = math.max(1, tonumber(width) or 1)
    height = math.max(1, tonumber(height) or 1)

    local visibleX = math.max(8, math.min(width, tonumber(options.visibleX) or 72))
    local visibleY = math.max(8, tonumber(options.visibleY) or 18)
    local topReachHeight = math.max(visibleY, math.min(height, tonumber(options.topReachHeight) or height))

    -- Horizontal recovery may use either side of the title/drag surface.
    local minX = left - width + visibleX
    local maxX = right - visibleX

    -- Vertically the drag handle lives at the top of outer windows. Keep a
    -- reachable strip of that handle visible rather than merely keeping some
    -- arbitrary part of the body on-screen. For widgets whose whole surface is
    -- draggable (for example the R launcher), topReachHeight == height.
    local minY = top - topReachHeight + visibleY
    local maxY = bottom - visibleY

    return Clamp(tonumber(x) or left, minX, math.max(minX, maxX)),
        Clamp(tonumber(y) or top, minY, math.max(minY, maxY))
end

function L:IsRectFullyVisible(x, y, width, height, options)
    options = type(options) == "table" and options or {}
    local context = self:GetContext()
    local edge = math.max(0, tonumber(options.edge) or context.safeLeft or C.SafeArea or 12)
    x, y = tonumber(x), tonumber(y)
    width, height = math.max(1, tonumber(width) or 1), math.max(1, tonumber(height) or 1)
    if x == nil or y == nil then return false end
    return x >= edge and y >= edge
        and x + width <= context.logicalWidth - edge
        and y + height <= context.logicalHeight - edge
end

function L:EnsureWidgetVisible(widget, options)
    options = type(options) == "table" and options or {}
    if widget == nil then return false end
    if options.onlyWhenVisible ~= false and not WidgetVisible(widget) then return false end
    local context = self:GetContext()
    local x, y, width, height = self:GetLogicalRect(widget)
    local edge = math.max(0, tonumber(options.edge) or context.safeLeft or C.SafeArea or 12)
    local targetWidth, targetHeight = width, height
    if options.fitSize == true then
        targetWidth = math.min(targetWidth, math.max(1, context.logicalWidth - edge * 2))
        targetHeight = math.min(targetHeight, math.max(1, context.logicalHeight - edge * 2))
    end
    local safeX, safeY = self:ClampTopLeft(x, y, targetWidth, targetHeight, { edge = edge })
    local changed = math.abs((tonumber(x) or 0) - safeX) >= 0.5 or math.abs((tonumber(y) or 0) - safeY) >= 0.5
        or math.abs((tonumber(width) or 1) - targetWidth) >= 0.5 or math.abs((tonumber(height) or 1) - targetHeight) >= 0.5
    if changed then
        if widget.RemoveAllAnchors ~= nil then widget:RemoveAllAnchors() end
        widget:AddAnchor("TOPLEFT", "UIParent", safeX, safeY)
        if options.fitSize == true and widget.SetExtent ~= nil then widget:SetExtent(targetWidth, targetHeight) end
    end
    return changed, safeX, safeY, targetWidth, targetHeight
end

function L:RegisterFloating(id, widget, options)
    id = tostring(id or "")
    if id == "" or widget == nil then return false end
    self.floatingRegistry[id] = { widget = widget, options = type(options) == "table" and options or {} }
    local item = self.floatingRegistry[id]
    if item.options.ensureNow ~= false then
        if type(item.options.onMetricsChanged) == "function" then
            pcall(item.options.onMetricsChanged, false)
        elseif tostring(item.options.safetyMode or "free") ~= "free" then
            -- V3 floating surfaces are free by default. Legacy/exceptional
            -- callers must explicitly request safety enforcement.
            self:EnsureWidgetVisible(widget, item.options)
        end
    end
    return true
end

function L:UnregisterFloating(id)
    self.floatingRegistry[tostring(id or "")] = nil
end

------------------------------------------------------------------------
-- Screen Snap Registry
--
-- Deliberately separate from floatingRegistry. FloatingRegistry owns
-- resolution-safety callbacks; ScreenSnapRegistry owns only snap discovery.
-- Keeping those lifecycles independent prevents a module from accidentally
-- replacing its safety callback when it opts into screen-button snapping.
------------------------------------------------------------------------
function L:RegisterScreenSnap(id, widget, options)
    id = tostring(id or "")
    if id == "" or widget == nil then return false end
    options = type(options) == "table" and options or {}
    self.screenSnapRegistry[id] = { id = id, widget = widget, options = options }
    return true
end

function L:UnregisterScreenSnap(id)
    self.screenSnapRegistry[tostring(id or "")] = nil
    return true
end

-- Generic screen-control snap solver. Business modules own persistence and
-- user settings; this layer owns only cross-module target discovery and
-- geometry. Hidden controls are excluded, so disabled features have no
-- candidate cost. snapGroup prevents unrelated surfaces from coupling;
-- snapKind can further separate buttons/windows when required.
function L:ResolveScreenSnap(id, x, y, width, height, overrides)
    id = tostring(id or "")
    overrides = type(overrides) == "table" and overrides or {}
    local active = self.screenSnapRegistry[id]
    local activeOptions = active and type(active.options) == "table" and active.options or {}
    local enabled = overrides.enabled
    if enabled == nil then enabled = activeOptions.snapEnabled end
    if enabled == nil then enabled = active ~= nil end
    if enabled == true and type(activeOptions.snapEnabledProvider) == "function" then
        local ok, value = pcall(activeOptions.snapEnabledProvider)
        enabled = ok == true and value == true
    end
    if enabled ~= true then return x, y, false, nil end

    local group = tostring(overrides.group or activeOptions.snapGroup or "screen_controls")
    local kind = tostring(overrides.kind or activeOptions.snapKind or "")
    local siblings, siblingIds = {}, {}
    for otherId, item in pairs(self.screenSnapRegistry or {}) do
        local opts = item and type(item.options) == "table" and item.options or {}
        local widget = item and item.widget or nil
        local targetEnabled = opts.snapEnabled ~= false
        if targetEnabled == true and type(opts.snapEnabledProvider) == "function" then
            local ok, value = pcall(opts.snapEnabledProvider)
            targetEnabled = ok == true and value == true
        end
        if tostring(otherId) ~= id and widget ~= nil and targetEnabled and WidgetVisible(widget) then
            local otherGroup = tostring(opts.snapGroup or "screen_controls")
            local otherKind = tostring(opts.snapKind or "")
            if otherGroup == group and (kind == "" or otherKind == "" or otherKind == kind) then
                local ox, oy, ow, oh = self:GetLogicalRect(widget)
                if tonumber(ox) ~= nil and tonumber(oy) ~= nil then
                    siblings[#siblings + 1] = { x = ox, y = oy, width = ow, height = oh }
                    siblingIds[#siblings] = tostring(otherId)
                end
            end
        end
    end

    self.screenSnapMetrics.resolves = (tonumber(self.screenSnapMetrics.resolves) or 0) + 1
    self.screenSnapMetrics.candidates = (tonumber(self.screenSnapMetrics.candidates) or 0) + #siblings
    local gap = math.max(0, tonumber(overrides.gap) or tonumber(activeOptions.snapGap) or 0)
    local sx, sy, snapped, siblingIndex = self:ResolveSiblingSnap(x, y, width, height, siblings, {
        distance = math.max(0, tonumber(overrides.distance) or tonumber(activeOptions.snapDistance) or self:Scale(C.SnapDistance or 16)),
        gapX = math.max(0, tonumber(overrides.gapX) or gap),
        gapY = math.max(0, tonumber(overrides.gapY) or gap),
    })
    if snapped == true then self.screenSnapMetrics.snaps = (tonumber(self.screenSnapMetrics.snaps) or 0) + 1 end
    return sx, sy, snapped, siblingIds[tonumber(siblingIndex) or -1]
end

function L:GetScreenSnapSnapshot()
    local registered, visible = 0, 0
    for _, item in pairs(self.screenSnapRegistry or {}) do
        registered = registered + 1
        if item and item.widget ~= nil and WidgetVisible(item.widget) then visible = visible + 1 end
    end
    return {
        version = 1,
        registered = registered,
        visible = visible,
        resolves = tonumber(self.screenSnapMetrics.resolves) or 0,
        snaps = tonumber(self.screenSnapMetrics.snaps) or 0,
        candidates = tonumber(self.screenSnapMetrics.candidates) or 0,
    }
end

function L:RefreshFloatingSafety(metricsChanged)
    if self._refreshingFloatingSafety == true then return end
    self._refreshingFloatingSafety = true
    for _, item in pairs(self.floatingRegistry or {}) do
        local widget = item and item.widget or nil
        local options = item and item.options or nil
        if widget ~= nil and type(options) == "table" then
            if type(options.onMetricsChanged) == "function" then
                pcall(options.onMetricsChanged, metricsChanged == true)
            elseif tostring(options.safetyMode or "free") ~= "free" then
                self:EnsureWidgetVisible(widget, options)
            end
        end
    end
    self._refreshingFloatingSafety = false
end

local function EnsureSafeDragProxy()
    if L.safeDragProxy ~= nil then return L.safeDragProxy end
    local factory = S.NativeObjectFactory
    if type(factory) ~= "table" or type(factory.CreateEmptyWidget) ~= "function" then return nil end
    local proxy = factory:CreateEmptyWidget(S.PhysicalId("resolution_drag_proxy"), "UIParent")
    if proxy == nil then return nil end
    proxy:SetExtent(1, 1)
    proxy:AddAnchor("TOPLEFT", "UIParent", 0, 0)
    if proxy.Enable ~= nil then pcall(function() proxy:Enable(true) end) end
    if proxy.Clickable ~= nil then pcall(function() proxy:Clickable(false) end) end
    if proxy.EnablePick ~= nil then pcall(function() proxy:EnablePick(false, true) end) end
    proxy:Show(false)
    L.safeDragProxy = proxy
    return proxy
end

function L:StepSafeMove()
    -- During a safe drag the target is anchored to the native moving proxy, so
    -- CryEngine performs the visual follow at native frame rate with zero Lua
    -- polling. This function remains as a compatibility/query point and only
    -- reports the current logical target position.
    local drag = self.safeDrag
    if type(drag) ~= "table" or drag.target == nil then return false end
    local x, y = self:GetLogicalRect(drag.target)
    drag.lastX, drag.lastY = tonumber(x) or drag.startX, tonumber(y) or drag.startY
    return true
end

function L:BeginSafeMove(key, target, options)
    -- IMPORTANT: do not try to transfer an active drag gesture to a different
    -- invisible window here. ArcheRage RU does not reliably hand the current
    -- mouse-drag capture to a proxy that did not receive OnDragStart itself.
    -- The old global proxy path could therefore return success while the proxy
    -- never moved, which made every caller skip its proven native StartMoving()
    -- fallback and left Suite/Gear/Healer/Plates/HUD windows undraggable.
    --
    -- Resolution safety remains centralized in RegisterFloating(),
    -- RefreshFloatingSafety(), EnsureWidgetVisible() and the drag-stop clamps.
    -- Consumers must use their native drag path unless a module owns a complete
    -- proxy transaction (DPS ranking windows do, including their own frame
    -- driver). Returning false is an explicit capability result, not an error.
    return false
end

function L:EndSafeMove(key, cancel)
    local drag = self.safeDrag
    if type(drag) ~= "table" then return false end
    if key ~= nil and tostring(key) ~= tostring(drag.key) then return false end

    local x, y = drag.startX, drag.startY
    if cancel ~= true and drag.target ~= nil then
        local currentX, currentY = self:GetLogicalRect(drag.target)
        x, y = tonumber(currentX) or drag.startX, tonumber(currentY) or drag.startY
        if drag.clamp ~= false then
            x, y = self:ClampTopLeft(x, y, drag.width, drag.height, drag.options)
        end
    end

    if drag.proxy ~= nil then
        if drag.proxy.StopMovingOrSizing ~= nil then pcall(function() drag.proxy:StopMovingOrSizing() end) end
    end
    if drag.target ~= nil then
        if drag.target.RemoveAllAnchors ~= nil then drag.target:RemoveAllAnchors() end
        drag.target:AddAnchor("TOPLEFT", "UIParent", x, y)
    end
    if drag.proxy ~= nil then
        drag.proxy:Show(false)
        if drag.proxy.RemoveAllAnchors ~= nil then drag.proxy:RemoveAllAnchors() end
        drag.proxy:AddAnchor("TOPLEFT", "UIParent", 0, 0)
        if drag.proxy.SetExtent ~= nil then drag.proxy:SetExtent(1, 1) end
    end
    local width, height = drag.width, drag.height
    self.safeDrag = nil
    return true, x, y, width, height
end

function L:StorePlacement(target, widget, options)
    if type(target) ~= "table" or widget == nil then return end
    options = type(options) == "table" and options or {}
    local context = self:GetContext()
    local x, y, width, height = self:GetLogicalRect(widget)
    local mode = tostring(options.mode or "free")
    width = math.max(1, tonumber(width) or 1)
    height = math.max(1, tonumber(height) or 1)

    -- Free/recoverable placement is allowed to be larger than the viewport.
    -- Strict/edge placement keeps the historical fit-to-current-resolution rule.
    if mode ~= "free" and mode ~= "recoverable" then
        width = Clamp(width, 1, context.usableWidth)
        height = Clamp(height, 1, context.usableHeight)
    end

    if mode == "free" or mode == "recoverable" then
        if mode == "recoverable" then
            x, y = self:ClampRecoverableTopLeft(x, y, width, height, options)
        end
        target.x = tonumber(x) or 0
        target.y = tonumber(y) or 0
        target.anchorH = nil
        target.anchorV = nil
        target.offsetX = nil
        target.offsetY = nil
        target.coordinateSpace = "logical-free-v2"
        target.savedUiScale = context.uiScale
        return target.x, target.y, width, height
    end

    x = Clamp(x, context.safeLeft, math.max(context.safeLeft, context.logicalWidth - context.safeRight - width))
    y = Clamp(y, context.safeTop, math.max(context.safeTop, context.logicalHeight - context.safeBottom - height))

    if x + width / 2 <= context.logicalWidth / 2 then
        target.anchorH = "LEFT"
        target.offsetX = math.max(0, x - context.safeLeft)
    else
        target.anchorH = "RIGHT"
        target.offsetX = math.max(0, context.logicalWidth - context.safeRight - x - width)
    end
    if y + height / 2 <= context.logicalHeight / 2 then
        target.anchorV = "TOP"
        target.offsetY = math.max(0, y - context.safeTop)
    else
        target.anchorV = "BOTTOM"
        target.offsetY = math.max(0, context.logicalHeight - context.safeBottom - y - height)
    end
    target.x, target.y = nil, nil
    target.coordinateSpace = "logical-edge-v1"
    target.savedUiScale = context.uiScale
    return x, y, width, height
end

function L:ResolvePlacement(placement, width, height, defaultX, defaultY, options)
    options = type(options) == "table" and options or {}
    local context = self:GetContext()
    local mode = tostring(options.mode or "free")
    width = math.max(1, tonumber(width) or 1)
    height = math.max(1, tonumber(height) or 1)
    if mode ~= "free" and mode ~= "recoverable" then
        width = Clamp(width, 1, context.usableWidth)
        height = Clamp(height, 1, context.usableHeight)
    end

    local x = tonumber(defaultX) or context.safeLeft
    local y = tonumber(defaultY) or context.safeTop
    if type(placement) == "table" and tostring(placement.coordinateSpace or "") == "logical-free-v2"
        and tonumber(placement.x) ~= nil and tonumber(placement.y) ~= nil then
        x = tonumber(placement.x)
        y = tonumber(placement.y)
        if mode == "recoverable" then
            x, y = self:ClampRecoverableTopLeft(x, y, width, height, options)
        elseif mode == "strict" then
            x, y = self:ClampTopLeft(x, y, width, height, options)
        end
        return x, y, width, height
    end

    if type(placement) == "table" then
        local offsetX = math.max(0, tonumber(placement.offsetX) or 0)
        local offsetY = math.max(0, tonumber(placement.offsetY) or 0)
        if placement.anchorH == "RIGHT" then
            x = context.logicalWidth - context.safeRight - offsetX - width
        else
            x = context.safeLeft + offsetX
        end
        if placement.anchorV == "BOTTOM" then
            y = context.logicalHeight - context.safeBottom - offsetY - height
        else
            y = context.safeTop + offsetY
        end
    end

    if mode == "recoverable" then
        x, y = self:ClampRecoverableTopLeft(x, y, width, height, options)
    elseif mode == "strict" then
        x = Clamp(x, context.safeLeft, math.max(context.safeLeft, context.logicalWidth - context.safeRight - width))
        y = Clamp(y, context.safeTop, math.max(context.safeTop, context.logicalHeight - context.safeBottom - height))
    end
    return x, y, width, height
end

function L:ApplyPlacement(widget, placement, width, height, defaultX, defaultY, options)
    if widget == nil then return end
    local x, y, resolvedWidth, resolvedHeight = self:ResolvePlacement(placement, width, height, defaultX, defaultY, options)
    if widget.RemoveAllAnchors ~= nil then widget:RemoveAllAnchors() end
    widget:AddAnchor("TOPLEFT", "UIParent", x, y)
    widget:SetExtent(resolvedWidth, resolvedHeight)
    return x, y, resolvedWidth, resolvedHeight
end

function L:SnapAndStore(target, widget)
    if widget == nil then return end
    local context = self:GetContext()
    local x, y, width, height = self:GetLogicalRect(widget)
    local snap = self:Scale(C.SnapDistance)
    local left = context.safeLeft
    local top = context.safeTop
    local right = context.logicalWidth - context.safeRight - width
    local bottom = context.logicalHeight - context.safeBottom - height

    -- HUD snapping is an editor-only affordance. Normal unlocked HUD dragging
    -- stays free, preventing the "window suddenly jumps" behavior called out in
    -- the v1.1 spec. The main Suite window keeps its historical edge snapping.
    local isHud = widget.rsHudOwner ~= nil
    local snapHud = isHud and S.HudManager ~= nil and S.HudManager:IsEditMode() == true
        and ActiveSettings().hudSnapEnabled ~= false
    local snapScreen = (not isHud) or snapHud

    if snapScreen then
        if math.abs(x - left) <= snap then x = left end
        if math.abs(x - right) <= snap then x = right end
        if math.abs(y - top) <= snap then y = top end
        if math.abs(y - bottom) <= snap then y = bottom end
    end

    if snapHud and type(S.HudManager.GetSnapWindows) == "function" then
        local function SnapAxis(value, size, otherValue, otherSize)
            local candidates = {
                otherValue,                         -- left/top align
                otherValue + otherSize - size,      -- right/bottom align
                otherValue + otherSize,             -- place after
                otherValue - size,                  -- place before
            }
            local best, bestDistance = value, snap + 0.001
            for _, candidate in ipairs(candidates) do
                local distance = math.abs(value - candidate)
                if distance <= snap and distance < bestDistance then best, bestDistance = candidate, distance end
            end
            return best
        end
        for _, other in ipairs(S.HudManager:GetSnapWindows(widget)) do
            local ox, oy, ow, oh = self:GetLogicalRect(other)
            x = SnapAxis(x, width, ox, ow)
            y = SnapAxis(y, height, oy, oh)
        end
    end

    -- Persisted/live result always keeps an operable area inside the safe area.
    x = Clamp(x, left, math.max(left, right))
    y = Clamp(y, top, math.max(top, bottom))

    if widget.RemoveAllAnchors ~= nil then widget:RemoveAllAnchors() end
    widget:AddAnchor("TOPLEFT", "UIParent", x, y)
    self:StorePlacement(target, widget)
end

-- Pure main-window spec solver. M6 exposes this separately from GetMainSpec so
-- Diagnostics can simulate the supported resolution / UI-scale matrix without
-- mutating UIParent or the player's saved settings. Runtime still calls the same
-- solver, therefore the acceptance matrix cannot drift into a second layout
-- implementation.
function L:BuildMainSpec(context, placement, fontScale)
    context = type(context) == "table" and context or self:GetContext()
    local scale = math.max(0.01, tonumber(context.addonScale) or 1)
    placement = type(placement) == "table" and placement or {}

    local defaultColumns = tonumber(context.columns) or 2
    local baseWidth, baseHeight
    if defaultColumns == 3 then
        baseWidth, baseHeight = C.MainWindow.threeColumnWidth, C.MainWindow.threeColumnHeight
    elseif defaultColumns == 2 then
        baseWidth, baseHeight = C.MainWindow.twoColumnWidth, C.MainWindow.twoColumnHeight
    else
        baseWidth, baseHeight = C.MainWindow.oneColumnWidth, C.MainWindow.oneColumnHeight
    end

    local designWidth = math.max(C.MainWindow.minWidth or 560, tonumber(placement.width) or baseWidth)
    local designHeight = math.max(C.MainWindow.minHeight or 600, tonumber(placement.height) or baseHeight)

    -- Outer-surface size is user authority. Responsive breakpoints below decide
    -- how content reflows INSIDE that surface; they must not silently clamp the
    -- window back to the current viewport or to historical 1180x900 defaults.
    -- Native Windowing owns the technical resize floor/limit separately.
    local width = designWidth * scale
    local height = designHeight * scale

    -- Column count is derived from the *actual* user-sized main window, not
    -- just the physical monitor. This keeps cards readable when the user
    -- narrows the dashboard and lets a wider resized dashboard expose more.
    local actualDesignWidth = width / scale
    -- M1 App Shell uses a real grouped navigation rail instead of the former
    -- 82px flat tab strip. Keep the rail readable on wide windows, then
    -- compress it progressively on narrow user-sized windows. The page content
    -- remains the flexible side of the split; no resolution-specific branch is
    -- hardcoded here.
    local navDesignWidth = 218
    if actualDesignWidth < 900 then navDesignWidth = 196 end
    if actualDesignWidth < 720 then navDesignWidth = 166 end
    local actualContentDesignWidth = math.max(1, actualDesignWidth - navDesignWidth - (C.Layout.margin or 10) * 3)
    local requestedFont = fontScale
    if requestedFont == nil then requestedFont = ActiveSettings().fontScale end
    local fontDensity = math.max(1.0, math.min(1.50, tonumber(requestedFont) or 1.2))
    local oneColumnThreshold = 400
    local threeColumnThreshold = 780 * fontDensity
    local columns = 3
    if actualContentDesignWidth < oneColumnThreshold then
        columns = 1
    elseif actualContentDesignWidth < threeColumnThreshold or context.breakpoint == "COMPACT" then
        columns = 2
    end

    local margin = C.Layout.margin * scale
    local titleHeight = C.Layout.titleHeight * scale * fontDensity
    local tabHeight = C.Layout.tabHeight * scale * math.max(1.0, math.min(1.15, fontDensity))
    local navWidth = navDesignWidth * scale
    local navGap = C.Layout.cardGap * scale
    return {
        width = width,
        height = height,
        columns = columns,
        margin = margin,
        titleHeight = titleHeight,
        tabHeight = tabHeight,
        navWidth = navWidth,
        navGap = navGap,
        contentX = margin + navWidth + navGap,
        contentY = titleHeight + margin,
        contentWidth = math.max(1, width - margin * 2 - navWidth - navGap),
        contentHeight = math.max(1, height - titleHeight - margin * 2),
        gap = C.Layout.cardGap * scale,
        rowHeight = C.Layout.rowHeight * scale * fontDensity,
        compactRowHeight = C.Layout.compactRowHeight * scale * fontDensity,
    }
end

function L:GetMainSpec()
    return self:BuildMainSpec(self:GetContext(), ActiveMainPlacement(), ActiveSettings().fontScale)
end

