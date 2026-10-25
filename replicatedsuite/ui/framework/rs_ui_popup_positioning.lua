-- Replicated Suite · 弹层位置求解
-- 作者：Replicated
-- QQ群：1104129461
-- 目标弹层使用 Trigger-relative；ColorField 先解算 viewport-logical，再锚 UIParent。
-- RU Effective 几何可能已缩放或已逻辑化，盲除 uiScale 会让离原点越远的弹层偏差越大。
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local UI, RSUI, Layout = S.UI, S.RSUI, S.Layout
if type(UI) ~= "table" or type(RSUI) ~= "table" or type(Layout) ~= "table" then return end

RSUI.PopupPositioningContractVersion = 4
RSUI.PopupNativeRelativeAnchorContractVersion = 1
RSUI.PopupViewportResolvedAnchorContractVersion = 1
RSUI.PopupCoordinateSpaceContractVersion = 1
RSUI.PopupSuiteAnchorAuthorityContractVersion = 1

local P = RSUI.PopupPositioning or {
    version = 4,
    coordinateSpace = "viewport-logical-v1",
    metrics = {
        resolves = 0,
        flips = 0,
        horizontalClamps = 0,
        verticalClamps = 0,
        shrinks = 0,
        anchorFallbacks = 0,
        nativeRelativeApplies = 0,
        viewportResolvedApplies = 0,
        nativeScreenCorrections = 0,
        nativeScreenCorrectionFailures = 0,
    },
    recent = {},
    recentOrder = {},
    recentLimit = 12,
}
RSUI.PopupPositioning = P
-- 热重载复用旧表，补齐计数器而不丢已有诊断。
P.version = 4
P.metrics.nativeRelativeApplies = tonumber(P.metrics.nativeRelativeApplies) or 0
P.metrics.viewportResolvedApplies = tonumber(P.metrics.viewportResolvedApplies) or 0
P.metrics.nativeScreenCorrections = tonumber(P.metrics.nativeScreenCorrections) or 0
P.metrics.nativeScreenCorrectionFailures = tonumber(P.metrics.nativeScreenCorrectionFailures) or 0

local function N(value, fallback)
    value = tonumber(value)
    if value == nil then return tonumber(fallback) or 0 end
    return value
end

local function Clamp(value, minimum, maximum)
    value, minimum, maximum = N(value, minimum), N(minimum, 0), N(maximum, minimum)
    if value < minimum then return minimum end
    if value > maximum then return maximum end
    return value
end

local function CopyRect(rect)
    if type(rect) ~= "table" then return nil end
    local x, y = tonumber(rect.x), tonumber(rect.y)
    local w, h = tonumber(rect.width), tonumber(rect.height)
    if x == nil or y == nil or w == nil or h == nil then return nil end
    return {
        x = x, y = y,
        width = math.max(1, w), height = math.max(1, h),
        right = x + math.max(1, w), bottom = y + math.max(1, h),
        coordinateSpace = tostring(rect.coordinateSpace or "viewport-logical-v1"),
        source = rect.source,
    }
end

local function ResolveNative(target)
    if RSUI:IsComponent(target) then return target:GetRoot(), target end
    if type(target) == "table" then return target, nil end
    return nil, nil
end

-- 仅显式打开时采原始 Native 几何供诊断，不换算单位或参与定位；recent 最多留 12 条。
local function ReadNativePopupGeometry(widget)
    local row = {}
    if widget == nil then return row end
    if type(widget.GetOffset) == "function" then pcall(function() row.offsetX, row.offsetY = widget:GetOffset() end) end
    if type(widget.GetExtent) == "function" then pcall(function() row.extentW, row.extentH = widget:GetExtent() end) end
    if type(widget.GetEffectiveOffset) == "function" then pcall(function() row.effectiveX, row.effectiveY = widget:GetEffectiveOffset() end) end
    if type(widget.GetEffectiveExtent) == "function" then pcall(function() row.effectiveW, row.effectiveH = widget:GetEffectiveExtent() end) end
    row.logicalId = tostring(widget.rsNativeLogicalId or widget.rsUiLogicalId or widget.rsUiOwner or "?")
    return row
end

-- 两条定位车道共用有界 recent，同 ID 只覆盖快照。
function P:_TouchRecentId(id)
    id = tostring(id or "popup")
    if self.recent[id] == nil then self.recentOrder[#self.recentOrder + 1] = id end
    while #self.recentOrder > math.max(1, tonumber(self.recentLimit) or 12) do local oldest = table.remove(self.recentOrder, 1); self.recent[oldest] = nil end
    return id
end

-- 相对坐标与尺寸取组件布局，不能再乘除 uiScale 或加宿主原点。
function P:ApplyNativeRelativePopup(popup, target, owner, options)
    options = type(options) == "table" and options or {}
    local targetNative = select(1, ResolveNative(target))
    if popup == nil or targetNative == nil then return false, "popup_native_relative_target_unavailable" end
    local width = math.max(1, N(options.width, 1))
    local height = math.max(1, N(options.height, 1))
    local triggerWidth = math.max(1, N(options.triggerWidth, 1))
    local triggerHeight = math.max(1, N(options.triggerHeight, 1))
    local gap = math.max(0, N(options.gap, 2))
    local placement = tostring(options.placement or "bottom-start")
    local relativeX, relativeY = N(options.offsetX, 0), triggerHeight + gap
    if placement == "top-start" then relativeY = -(height + gap) elseif placement == "right-start" then relativeX, relativeY = triggerWidth + gap, 0 end
    local extentOk, _, extentErr = UI:EnsureExtent(popup, width, height, owner)
    if extentOk ~= true then return false, "popup_native_relative_extent_failed:" .. tostring(extentErr or "unknown") end
    -- 屏幕修正可能改 Native 偏移；重开前失效锚缓存，避免将合法修正误报为外部写入。
    if type(UI.InvalidateNativeState) == "function" then UI:InvalidateNativeState(popup, "anchorParent") end
    local anchorOk, _, anchorErr = UI:EnsureAnchor(popup, targetNative, relativeX, relativeY, owner)
    if anchorOk ~= true then return false, "popup_native_relative_anchor_failed:" .. tostring(anchorErr or "unknown") end
    popup.rsUiCoordinateLane = "popup-native-relative-v1"
    popup.rsUiCoordinateSpace = "native-trigger-relative-v1"
    self.metrics.nativeRelativeApplies = N(self.metrics.nativeRelativeApplies) + 1
    local id = self:_TouchRecentId(options.id)
    self.recent[id] = { id = id, mode = "native_relative", coordinateSpace = "native-trigger-relative-v1", anchorSource = "native_relative_trigger", placement = placement, relative = { x = relativeX, y = relativeY, width = width, height = height, triggerWidth = triggerWidth, triggerHeight = triggerHeight }, targetNative = ReadNativePopupGeometry(targetNative), popupNativeBeforeCorrection = ReadNativePopupGeometry(popup) }
    return true, nil, { placement = placement, relativeX = relativeX, relativeY = relativeY, width = width, height = height }
end

-- ColorField 跨层锚按钮曾留在 (0,0)；此入口只收已解算逻辑坐标，再锚 UIParent。
function P:ApplyResolvedViewportPopup(popup, anchor, resolved, owner, options)
    options = type(options) == "table" and options or {}
    if popup == nil or type(resolved) ~= "table" then return false, "popup_viewport_resolved_target_unavailable" end
    if tostring(resolved.coordinateSpace or "") ~= "viewport-logical-v1" then return false, "popup_viewport_resolved_space_invalid" end
    local x, y = tonumber(resolved.x), tonumber(resolved.y)
    local width, height = tonumber(resolved.width), tonumber(resolved.height)
    if x == nil or y == nil or width == nil or height == nil then return false, "popup_viewport_resolved_geometry_invalid" end
    -- 先提交尺寸，避免屏幕修正使用旧范围；任一步拒写都不能发布成功。
    local extentOk, _, extentErr = UI:EnsureExtent(popup, math.max(1, width), math.max(1, height), owner)
    if extentOk ~= true then return false, "popup_viewport_resolved_extent_failed:" .. tostring(extentErr or "unknown") end
    if type(UI.InvalidateNativeState) == "function" then UI:InvalidateNativeState(popup, "anchorParent") end
    local anchorOk, _, anchorErr = UI:EnsureAnchor(popup, UIParent, x, y, owner)
    if anchorOk ~= true then return false, "popup_viewport_resolved_anchor_failed:" .. tostring(anchorErr or "unknown") end
    popup.rsUiCoordinateLane = "popup-viewport-resolved-v1"
    popup.rsUiCoordinateSpace = "viewport-logical-v1"
    self.metrics.viewportResolvedApplies = N(self.metrics.viewportResolvedApplies) + 1
    local id = self:_TouchRecentId(options.id)
    local row = self.recent[id] or { id = id }
    row.id = id
    row.mode = "viewport_resolved"
    row.coordinateSpace = "viewport-logical-v1"
    row.anchor = CopyRect(anchor) or row.anchor
    row.result = CopyRect(resolved) or row.result
    row.anchorSource = anchor and anchor.source or row.anchorSource
    row.resolvedXY = { x = x, y = y, width = width, height = height }
    row.popupNativeBeforeCorrection = ReadNativePopupGeometry(popup)
    self.recent[id] = row
    return true, nil, { x = x, y = y, width = width, height = height }
end

-- 锚定后才做屏幕修正；缺方法可降级，抛异常才拒绝，Native false 不代表失败。
function P:CorrectNativePopupToScreen(popup, id)
    id = tostring(id or "popup")
    if popup == nil then return false, "popup_screen_correction_target_unavailable" end
    local corrected = false
    if type(popup.CorrectOffsetByScreen) == "function" then local ok = pcall(function() popup:CorrectOffsetByScreen() end); corrected = ok == true; self.metrics.nativeScreenCorrections = N(self.metrics.nativeScreenCorrections) + 1; if ok ~= true then self.metrics.nativeScreenCorrectionFailures = N(self.metrics.nativeScreenCorrectionFailures) + 1 end end
    local row = self.recent[id]
    if type(row) == "table" then
        row.nativeCorrectionAvailable = type(popup.CorrectOffsetByScreen) == "function"
        row.nativeCorrectionOk = corrected
        row.popupNativeAfterCorrection = ReadNativePopupGeometry(popup)
        local after = row.popupNativeAfterCorrection or {}
        row.finalNativeXY = { x = after.offsetX or after.effectiveX, y = after.offsetY or after.effectiveY }
    end
    return corrected or type(popup.CorrectOffsetByScreen) ~= "function", corrected and nil or (type(popup.CorrectOffsetByScreen) == "function" and "popup_screen_correction_failed" or nil)
end

function P:GetViewport(context)
    context = type(context) == "table" and context or (type(Layout.GetContext) == "function" and Layout:GetContext() or nil)
    local width = math.max(1, N(context and context.logicalWidth, 1024))
    local height = math.max(1, N(context and context.logicalHeight, 768))
    local left = math.max(0, N(context and context.safeLeft, 4))
    local top = math.max(0, N(context and context.safeTop, 4))
    local rightMargin = math.max(0, N(context and context.safeRight, 4))
    local bottomMargin = math.max(0, N(context and context.safeBottom, 4))
    return {
        x = left,
        y = top,
        width = math.max(1, width - left - rightMargin),
        height = math.max(1, height - top - bottomMargin),
        right = math.max(left + 1, width - rightMargin),
        bottom = math.max(top + 1, height - bottomMargin),
        viewportWidth = width,
        viewportHeight = height,
        coordinateSpace = "viewport-logical-v1",
    }
end

function P:_Record(id, anchor, result, meta)
    id = tostring(id or "popup")
    if self.recent[id] == nil then
        self.recentOrder[#self.recentOrder + 1] = id
        while #self.recentOrder > math.max(1, tonumber(self.recentLimit) or 12) do
            local oldest = table.remove(self.recentOrder, 1)
            self.recent[oldest] = nil
        end
    end
    self.recent[id] = {
        id = id,
        anchor = CopyRect(anchor),
        result = CopyRect(result),
        placement = meta and meta.placement or nil,
        flipped = meta and meta.flipped == true or false,
        clampedX = meta and meta.clampedX == true or false,
        clampedY = meta and meta.clampedY == true or false,
        visibleRows = meta and tonumber(meta.visibleRows) or nil,
        coordinateSpace = "viewport-logical-v1",
        anchorSource = anchor and anchor.source or nil,
        normalization = meta and meta.normalization or nil,
    }
end

function P:GetSnapshot()
    local rows = {}
    for _, id in ipairs(self.recentOrder) do
        local row = self.recent[id]
        if row ~= nil then rows[#rows + 1] = row end
    end
    return {
        version = tonumber(self.version) or 0,
        contractVersion = tonumber(RSUI.PopupPositioningContractVersion) or 0,
        coordinateSpaceContractVersion = tonumber(RSUI.PopupCoordinateSpaceContractVersion) or 0,
        coordinateSpace = self.coordinateSpace,
        metrics = {
            resolves = N(self.metrics.resolves),
            flips = N(self.metrics.flips),
            horizontalClamps = N(self.metrics.horizontalClamps),
            verticalClamps = N(self.metrics.verticalClamps),
            shrinks = N(self.metrics.shrinks),
            anchorFallbacks = N(self.metrics.anchorFallbacks),
            nativeRelativeApplies = N(self.metrics.nativeRelativeApplies),
            viewportResolvedApplies = N(self.metrics.viewportResolvedApplies),
            nativeScreenCorrections = N(self.metrics.nativeScreenCorrections),
            nativeScreenCorrectionFailures = N(self.metrics.nativeScreenCorrectionFailures),
        },
        recent = rows,
    }
end

-- EffectiveOffset 还受控件类型和父级语义影响，统一单位校准也曾无法消除偏移。
-- Suite 控件优先读已提交的完整缓存父链；链不完整时拒绝，不能退回 Effective 猜位置。
function P:ResolveAnchorRect(target)
    local native, component = ResolveNative(target)
    if native == nil then return nil, "popup_anchor_rect_unavailable" end
    local cache = UI and UI.NativeStateCache or nil
    local suiteOwned = component ~= nil or (type(cache) == "table" and type(cache[native]) == "table")
    if suiteOwned == true and type(Layout.ResolveSuiteOwnedViewportLogicalRect) == "function" then
        local ok, x, y, w, h, meta = pcall(function() return Layout:ResolveSuiteOwnedViewportLogicalRect(native) end)
        if ok == true and tonumber(x) ~= nil and tonumber(y) ~= nil and tonumber(w) ~= nil and tonumber(h) ~= nil then
            return {
                x = tonumber(x), y = tonumber(y), width = math.max(1, tonumber(w)), height = math.max(1, tonumber(h)),
                right = tonumber(x) + math.max(1, tonumber(w)), bottom = tonumber(y) + math.max(1, tonumber(h)),
                coordinateSpace = "viewport-logical-v1",
                source = "suite_native_state_anchor_chain",
                normalization = meta,
            }, nil
        end
        self.metrics.anchorFallbacks = N(self.metrics.anchorFallbacks) + 1
        return nil, "popup_suite_anchor_chain_unavailable"
    end
    -- 外部 Native 使用有界 Effective 单位校准，结果仍须归一为 viewport-logical。
    if type(Layout.ResolveViewportLogicalRect) == "function" then
        local ok, x, y, w, h, meta = pcall(function() return Layout:ResolveViewportLogicalRect(native) end)
        if ok == true and tonumber(x) ~= nil and tonumber(y) ~= nil and tonumber(w) ~= nil and tonumber(h) ~= nil then
            local source = type(meta) == "table" and tostring(meta.source or "") or "external_native_effective"
            self.metrics.anchorFallbacks = N(self.metrics.anchorFallbacks) + 1
            return {
                x = tonumber(x), y = tonumber(y), width = math.max(1, tonumber(w)), height = math.max(1, tonumber(h)),
                right = tonumber(x) + math.max(1, tonumber(w)), bottom = tonumber(y) + math.max(1, tonumber(h)),
                coordinateSpace = "viewport-logical-v1",
                source = source ~= "" and source or "external_native_effective",
                normalization = meta,
            }, nil
        end
    end
    return nil, "popup_anchor_rect_unavailable"
end

-- 默认放下方，不足时择侧翻转并限制在安全视口；结果不能再缩放或加宿主原点。
function P:ResolveAnchored(anchor, popupWidth, popupHeight, options)
    options = type(options) == "table" and options or {}
    anchor = CopyRect(anchor)
    if anchor == nil then return nil, "popup_anchor_invalid" end
    local viewport = self:GetViewport(options.context)
    local gap = math.max(0, N(options.gap, 2))
    local width = math.max(1, math.min(N(popupWidth, anchor.width), viewport.width))
    local height = math.max(1, math.min(N(popupHeight, 1), viewport.height))
    local preferred = tostring(options.preferred or "bottom-start")
    local alignEnd = preferred:find("end", 1, true) ~= nil or options.align == "end"
    local preferAbove = preferred:find("top", 1, true) ~= nil or options.preferAbove == true

    local belowSpace = math.max(0, viewport.bottom - (anchor.bottom + gap))
    local aboveSpace = math.max(0, (anchor.y - gap) - viewport.y)
    local useAbove = preferAbove
    if preferAbove then
        if height > aboveSpace and belowSpace >= height then useAbove = false
        elseif height > aboveSpace and belowSpace > aboveSpace then useAbove = false end
    else
        if height > belowSpace and aboveSpace >= height then useAbove = true
        elseif height > belowSpace and aboveSpace > belowSpace then useAbove = true end
    end

    local rawX = alignEnd and (anchor.right - width) or anchor.x
    local rawY = useAbove and (anchor.y - gap - height) or (anchor.bottom + gap)
    local x = Clamp(rawX, viewport.x, math.max(viewport.x, viewport.right - width))
    local y = Clamp(rawY, viewport.y, math.max(viewport.y, viewport.bottom - height))
    local clampedX, clampedY = math.abs(x - rawX) > 0.01, math.abs(y - rawY) > 0.01

    self.metrics.resolves = N(self.metrics.resolves) + 1
    if useAbove ~= preferAbove then self.metrics.flips = N(self.metrics.flips) + 1 end
    if clampedX then self.metrics.horizontalClamps = N(self.metrics.horizontalClamps) + 1 end
    if clampedY then self.metrics.verticalClamps = N(self.metrics.verticalClamps) + 1 end

    local result = {
        x = x, y = y, width = width, height = height,
        right = x + width, bottom = y + height,
        coordinateSpace = "viewport-logical-v1",
    }
    local meta = {
        placement = useAbove and "top" or "bottom",
        flipped = useAbove ~= preferAbove,
        clampedX = clampedX,
        clampedY = clampedY,
        belowSpace = belowSpace,
        aboveSpace = aboveSpace,
        normalization = anchor.normalization,
    }
    if options.record ~= false then self:_Record(options.id, anchor, result, meta) end
    return result, nil, meta
end

-- 下拉按选定侧和视口预算分配整行高度，行池与滚动仍由原控件管理。
function P:ResolveDropdown(target, options)
    options = type(options) == "table" and options or {}
    local anchor, anchorErr = self:ResolveAnchorRect(target)
    if anchor == nil then return nil, anchorErr end
    local viewport = self:GetViewport(options.context)
    local rowHeight = math.max(1, N(options.rowHeight, anchor.height))
    local itemCount = math.max(0, math.floor(N(options.itemCount, 0)))
    local maxVisible = math.max(1, math.floor(N(options.maxVisible, 8)))
    local wantedRows = math.max(1, math.min(maxVisible, math.max(1, itemCount)))
    local gap = math.max(0, N(options.gap, 2))
    local below = math.max(0, viewport.bottom - (anchor.bottom + gap))
    local above = math.max(0, (anchor.y - gap) - viewport.y)
    local ratio = Clamp(N(options.maxViewportHeightRatio, 0.60), 0.20, 0.95)
    local viewportBudget = math.max(rowHeight, math.floor(viewport.height * ratio))
    local desiredHeight = wantedRows * rowHeight

    local useAbove = false
    local sideSpace = below
    if desiredHeight > below then
        if desiredHeight <= above or above > below then useAbove, sideSpace = true, above end
    end
    local heightBudget = math.max(rowHeight, math.min(viewportBudget, sideSpace > 0 and sideSpace or viewportBudget))
    local visibleRows = math.max(1, math.min(wantedRows, math.floor(heightBudget / rowHeight)))
    local popupHeight = visibleRows * rowHeight
    if visibleRows < wantedRows then self.metrics.shrinks = N(self.metrics.shrinks) + 1 end

    local desiredWidth = math.max(anchor.width, N(options.popupWidth, anchor.width))
    local result, resolveErr, meta = self:ResolveAnchored(anchor, desiredWidth, popupHeight, {
        id = options.id,
        context = options.context,
        gap = gap,
        preferred = useAbove and "top-start" or "bottom-start",
        record = false,
    })
    if result == nil then return nil, resolveErr end
    -- 下拉已先选好上下侧，此处补回相对默认下方的 flip 标志，避免漏记翻转。
    if useAbove == true and meta.flipped ~= true then
        self.metrics.flips = N(self.metrics.flips) + 1
    end
    meta.flipped = useAbove == true
    meta.placement = useAbove and "top" or "bottom"
    meta.visibleRows = visibleRows
    meta.wantedRows = wantedRows
    meta.maxVisible = maxVisible
    meta.itemCount = itemCount
    meta.rowHeight = rowHeight
    meta.normalization = anchor.normalization
    self:_Record(options.id, anchor, result, meta)
    return result, nil, meta
end

function P:ResolvePoint(x, y, popupWidth, popupHeight, options)
    options = type(options) == "table" and options or {}
    x, y = tonumber(x), tonumber(y)
    if x == nil or y == nil then return nil, "popup_point_invalid" end
    local gap = math.max(0, N(options.gap, 8))
    local anchor = {
        x = x, y = y, width = 1, height = 1,
        right = x + 1, bottom = y + 1,
        coordinateSpace = "viewport-logical-v1", source = "logical_point",
    }
    local viewport = self:GetViewport(options.context)
    local width = math.max(1, math.min(N(popupWidth, 1), viewport.width))
    local height = math.max(1, math.min(N(popupHeight, 1), viewport.height))
    local rawX, rawY = x + gap, y + gap
    if rawX + width > viewport.right then rawX = x - width - gap end
    if rawY + height > viewport.bottom then rawY = y - height - gap end
    local px = Clamp(rawX, viewport.x, math.max(viewport.x, viewport.right - width))
    local py = Clamp(rawY, viewport.y, math.max(viewport.y, viewport.bottom - height))
    local result = { x = px, y = py, width = width, height = height, right = px + width, bottom = py + height, coordinateSpace = "viewport-logical-v1" }
    local meta = {
        placement = "point",
        flipped = rawX < x or rawY < y,
        clampedX = math.abs(px - rawX) > 0.01,
        clampedY = math.abs(py - rawY) > 0.01,
    }
    self.metrics.resolves = N(self.metrics.resolves) + 1
    if meta.clampedX then self.metrics.horizontalClamps = N(self.metrics.horizontalClamps) + 1 end
    if meta.clampedY then self.metrics.verticalClamps = N(self.metrics.verticalClamps) + 1 end
    self:_Record(options.id, anchor, result, meta)
    return result, nil, meta
end
