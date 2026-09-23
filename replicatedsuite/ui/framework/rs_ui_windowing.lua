------------------------------------------------------------------------
-- Replicated Suite - RSUI Outer Window Foundation v16
--
-- Every V3 top-level/native window binds its movement and resizing here.
-- Presentation code supplies policy/persistence callbacks; this layer owns the
-- native drag transaction, eight-edge resize handles, unrestricted free-placement
-- safety and strict-authority cache reconciliation after native movement.
--
-- No permanent Tick/OnUpdate is created. Native StartMoving/StartSizing owns
-- the mouse gesture. During an active resize only, one bounded ~16ms interactive task on the
-- shared Scheduler reflows RSUI content to the live Native extent. If scheduling
-- is unavailable/rejected, the dedicated resize handle owns a gesture-only
-- OnUpdate fallback. Both paths are removed immediately at drag stop.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local UI, RSUI = S.UI, S.RSUI
if type(UI) ~= "table" or type(RSUI) ~= "table" then return end

RSUI.Windowing = RSUI.Windowing or { version = 19, bindings = {}, metrics = { attached = 0, detached = 0, drags = 0, resizes = 0, locks = 0, raises = 0, opacityChanges = 0, resizeHover = 0, liveResizeFrames = 0, interactionBegins = 0, interactionEnds = 0, freePlacementCommits = 0, recoveryClamps = 0, geometryCallbackRejects = 0, resizeStartAttempts = 0, resizeStartRejects = 0, resizeSurfaceRaises = 0 } }
RSUI.Windowing.version = 19
RSUI.Windowing.StateMutationTransactionContractVersion = 1
RSUI.Windowing.GeometryCallbackTransactionContractVersion = 1
RSUI.Windowing.IdempotentStateContractVersion = 1
RSUI.Windowing.CallbackCaptureContractVersion = 1
RSUI.Windowing.CriticalInteractionContractVersion = 3
RSUI.Windowing.DragSurfaceHitTestContractVersion = 1
RSUI.Windowing.ExplicitDragConditionContractVersion = 1
RSUI.Windowing.ResizeHitSurfaceContractVersion = 2
RSUI.Windowing.ResizeCaptureStabilityContractVersion = 2
RSUI.Windowing.metrics = RSUI.Windowing.metrics or {}
local W = RSUI.Windowing
local NATIVE_RESIZE_LIMIT = 16384 -- technical guard only; not a user-facing window cap

local function NativeOf(value)
    if type(value) == "table" and value.root ~= nil then return value.root end
    return value
end

local function Clamp(value, minimum, maximum)
    value = tonumber(value) or minimum
    return math.max(minimum, math.min(maximum, value))
end

local function EnsureNativeResizing(window, enabled)
    if window == nil or type(window.UseResizing) ~= "function" then return true, nil end
    if type(UI.TryInteractionCall) ~= "function" then return false, "interaction_contract_unavailable" end
    local accepted, detail = UI:TryInteractionCall(window, "UseResizing", enabled == true)
    if accepted ~= true then return false, tostring(detail or "native_resize_mode_rejected") end
    return true, nil
end

-- 维护（viewport-recovery-1）：只从校准后的 viewport logical 读顶层窗口，
-- 不沿用 GetLogicalRect 无条件 /uiScale。手势中使用 Begin 固定单位，防止 native resize
-- 改变 extent 后用旧 cache 误判比例；同一链只变换一次，持久化仅在 CommitGeometry。
local function ReadLogicalRect(window, pinnedScale)
    if S.Layout ~= nil and type(S.Layout.GetWindowLogicalRect) == "function" then
        local ok, x, y, width, height, info = pcall(function() return S.Layout:GetWindowLogicalRect(window, pinnedScale) end)
        if ok and x ~= nil then return x, y, width, height, info end
    end
    local x, y, width, height = 0, 0, 1, 1
    if window ~= nil and type(window.GetOffset) == "function" then pcall(function() x, y = window:GetOffset() end) end
    if window ~= nil and type(window.GetWidth) == "function" then pcall(function() width = window:GetWidth() end) end
    if window ~= nil and type(window.GetHeight) == "function" then pcall(function() height = window:GetHeight() end) end
    return tonumber(x) or 0, tonumber(y) or 0, math.max(1, tonumber(width) or 1), math.max(1, tonumber(height) or 1)
end

-- 维护：Windowing 是顶层 Native 几何写入 Authority。reset/metrics/手势结束强制失效
-- 仅几何缓存，避免沿用旧 anchor 命中；不清除颜色/可见性等其它状态，也不碰任何 Store。
-- extent/anchor 任一拒绝就返回失败并尽力回滚；Native 若连回滚也拒绝，明确报告而非假成功。
function W:ApplyGeometry(window, owner, x, y, width, height, force)
    for _,v in ipairs({x,y,width,height}) do
        if type(v) ~= "number" or v ~= v or v == math.huge or v == -math.huge then return false, "non_finite_window_rect" end
    end
    if x == nil or y == nil or width == nil or height == nil or width <= 0 or height <= 0 then return false, "invalid_window_rect" end
    if type(UI.EnsureAnchor) ~= "function" or type(UI.EnsureExtent) ~= "function" then return false,"geometry_transaction_unavailable" end
    -- 维护：内容刷新可能很频繁，常规布局只用 DiffRenderer 已提交矩形作为回滚基线。
    -- 只有 create（无缓存）/show/reset/metrics/手势结束 force 边沿读取 Native，禁止变相逐帧读坐标。
    local row=UI.NativeStateCache and UI.NativeStateCache[window]
    local bx,by,bw,bh
    if force~=true and row and type(row.anchorX)=="number" and type(row.anchorY)=="number"
        and type(row.width)=="number" and type(row.height)=="number" then
        bx,by,bw,bh=row.anchorX,row.anchorY,row.width,row.height
    else bx,by,bw,bh=ReadLogicalRect(window) end
    local function Invalidate()
        if type(UI.InvalidateNativeState) == "function" then
            for _,field in ipairs({"width","height","anchorParent","anchorX","anchorY","anchorTopLeft"}) do UI:InvalidateNativeState(window,field) end
        end
    end
    if force == true then Invalidate() end
    local ok,_,err = UI:EnsureExtent(window,width,height,owner)
    if ok == true then ok,_,err = UI:EnsureAnchor(window,UIParent,x,y,owner) end
    if ok ~= true then
        Invalidate()
        local sizeOk = UI:EnsureExtent(window,bw,bh,owner)
        local anchorOk = UI:EnsureAnchor(window,UIParent,bx,by,owner)
        return false, tostring(err or "native_geometry_rejected") .. ((sizeOk ~= true or anchorOk ~= true) and ":rollback_rejected" or "")
    end
    return true,x,y,width,height
end

local function ReconcileWindow(controller, window, owner, x, y, width, height)
    if window == nil then return false end
    local originalX, originalY = tonumber(x) or 0, tonumber(y) or 0
    local boundaryMode = tostring(controller and controller.boundaryMode or "free")
    -- 维护（2026-09-22，viewport-contained-floating-1）：Windowing 是真实用户 Drag/Resize
    -- 提交 Authority。若这里只做“标题仍可抓取”的 recoverable clamp，后续 FloatingSurface 会把
    -- 这个部分离屏矩形原样持久化，下一次登录/切分辨率仍会从错误 intent 开始。普通 free/strict
    -- 顶层窗口在手势提交时统一做 full-safe clamp；只有显式 recoverable 模式保留部分离屏语义。
    -- 这样 Native 最终矩形与 StorePlacementRect 收到的 committed rect 始终一致，不产生二次修正漂移。
    if (boundaryMode == "strict" or boundaryMode == "free") and S.Layout ~= nil and type(S.Layout.ClampTopLeft) == "function" then
        -- 手势可能来自较大分辨率遗留窗口，也可能是用户把 Resize 拉到当前 viewport 之外。
        -- 运行时 extent 先拟合当前 usable area，再夹紧 top-left；FloatingSurface 对 drag 不会把
        -- 此运行时拟合写回 preferred width/height，因此“低分辨率拖一下”不会永久损失大屏尺寸。
        local context = S.Layout:GetContext()
        width = math.min(math.max(1, tonumber(width) or 1), math.max(1, tonumber(context.usableWidth) or 1))
        height = math.min(math.max(1, tonumber(height) or 1), math.max(1, tonumber(context.usableHeight) or 1))
        x, y = S.Layout:ClampTopLeft(x, y, width, height)
    elseif boundaryMode == "recoverable" and S.Layout ~= nil and type(S.Layout.ClampRecoverableTopLeft) == "function" then
        x, y = S.Layout:ClampRecoverableTopLeft(x, y, width, height, {
            visibleX = controller and controller.recoveryVisibleX or 72,
            visibleY = controller and controller.recoveryVisibleY or 18,
            topReachHeight = controller and controller.dragHandleHeight or nil,
        })
    end
    if controller ~= nil and (math.abs((tonumber(x) or 0) - originalX) > 0.5 or math.abs((tonumber(y) or 0) - originalY) > 0.5) then
        W.metrics.recoveryClamps = (tonumber(W.metrics.recoveryClamps) or 0) + 1
    end

    -- Native movement/sizing intentionally changes geometry outside DiffRenderer
    -- while the mouse is captured. Clear the cached native snapshot BEFORE the
    -- strict owner writes the committed geometry back, so this valid transaction
    -- never looks like an authority violation.
    return W:ApplyGeometry(window, owner, x, y, width, height, true)
end

local HANDLE_SPECS = {
    { key = "top", direction = "TOP", cursor = "V", x = function(_, _, t) return t end, y = function() return 0 end, w = function(width, _, t) return math.max(1, width - t * 2) end, h = function(_, _, t) return t end },
    { key = "bottom", direction = "BOTTOM", cursor = "V", x = function(_, _, t) return t end, y = function(_, height, t) return math.max(0, height - t) end, w = function(width, _, t) return math.max(1, width - t * 2) end, h = function(_, _, t) return t end },
    { key = "left", direction = "LEFT", cursor = "H", x = function() return 0 end, y = function(_, _, t) return t end, w = function(_, _, t) return t end, h = function(_, height, t) return math.max(1, height - t * 2) end },
    { key = "right", direction = "RIGHT", cursor = "H", x = function(width, _, t) return math.max(0, width - t) end, y = function(_, _, t) return t end, w = function(_, _, t) return t end, h = function(_, height, t) return math.max(1, height - t * 2) end },
    { key = "top_left", direction = "TOPLEFT", cursor = "D1", x = function() return 0 end, y = function() return 0 end, w = function(_, _, t) return t end, h = function(_, _, t) return t end },
    { key = "top_right", direction = "TOPRIGHT", cursor = "D2", x = function(width, _, t) return math.max(0, width - t) end, y = function() return 0 end, w = function(_, _, t) return t end, h = function(_, _, t) return t end },
    { key = "bottom_left", direction = "BOTTOMLEFT", cursor = "D2", x = function() return 0 end, y = function(_, height, t) return math.max(0, height - t) end, w = function(_, _, t) return t end, h = function(_, _, t) return t end },
    { key = "bottom_right", direction = "BOTTOMRIGHT", cursor = "D1", x = function(width, _, t) return math.max(0, width - t) end, y = function(_, height, t) return math.max(0, height - t) end, w = function(_, _, t) return t end, h = function(_, _, t) return t end },
}

function W:Attach(spec)
    spec = type(spec) == "table" and spec or {}
    local id = tostring(spec.id or "")
    local owner = tostring(spec.owner or "")
    local window = NativeOf(spec.window)
    local dragHandle = NativeOf(spec.dragHandle)
    if id == "" or window == nil or dragHandle == nil or owner == "" then return nil, "windowing identity required" end
    if self.bindings[id] ~= nil then return self.bindings[id] end

    -- A top-level window has no UX minimum in the foundation. Feature code may
    -- opt into a semantic minimum explicitly; otherwise only the native 1px
    -- technical floor remains. Layout compression/clipping owns tiny extents.
    local minWidth = math.max(1, tonumber(spec.minWidth) or 1)
    local minHeight = math.max(1, tonumber(spec.minHeight) or 1)
    local maxWidth = tonumber(spec.maxWidth)
    local maxHeight = tonumber(spec.maxHeight)
    if maxWidth ~= nil then maxWidth = math.max(minWidth, maxWidth) end
    if maxHeight ~= nil then maxHeight = math.max(minHeight, maxHeight) end

    local controller = {
        id = id, owner = owner, window = window, dragHandle = dragHandle,
        handles = {}, enabled = true, locked = spec.locked == true, resizeEnabled = spec.resizable ~= false,
        minWidth = minWidth,
        minHeight = minHeight,
        maxWidth = maxWidth,
        maxHeight = maxHeight,
        handleThickness = math.max(5, tonumber(spec.handleThickness) or 8),
        boundaryMode = tostring(spec.boundaryMode or "free"),
        recoveryVisibleX = math.max(8, tonumber(spec.recoveryVisibleX) or 72),
        recoveryVisibleY = math.max(8, tonumber(spec.recoveryVisibleY) or 18),
        dragHandleHeight = math.max(8, tonumber(spec.dragHandleHeight) or 36),
        scaleWithAddon = spec.scaleWithAddon ~= false,
        onGeometryChanged = spec.onGeometryChanged,
        canDrag = spec.canDrag,
        canResize = spec.canResize,
        onDragStart = spec.onDragStart,
        onDragStop = spec.onDragStop,
        onResizeStart = spec.onResizeStart,
        onResizeStop = spec.onResizeStop,
        onLiveGeometry = spec.onLiveGeometry,
        opacity = math.max(0.0, math.min(1.0, tonumber(spec.opacity) or 1.0)),
    }


    -- 维护：Metrics 在手势中只标记，停止后放弃旧 viewport 的提交并重放原 intent。
    -- Reset 主动取消 lease 和捕获；迟到 OnDragStop 不能再写 Store 或移动恢复后的窗口。
    function controller:GetLogicalRect() return ReadLogicalRect(self.window, self.geometryUnitScale) end
    function controller:CancelInteraction()
        if self:IsInteracting() and type(self.window.StopMovingOrSizing) == "function" then
            pcall(function() self.window:StopMovingOrSizing() end)
        end
        self.dragging = false
        for _,handle in pairs(self.handles) do handle.rsWindowSizing = false end
        self:EndInteraction()
        self.geometryUnitScale, self.pendingPlacement, self.interactionViewport = nil, nil, nil
        return true
    end

    function controller:IsInteracting()
        return self.interactionKind ~= nil
    end

    function controller:IsDragging()
        return self.interactionKind == "drag"
    end

    function controller:IsResizing()
        return self.interactionKind == "resize"
    end

    function controller:GetInteractionKind()
        return self.interactionKind
    end

    function controller:StopLiveGeometryTask()
        if self.liveTaskName ~= nil and S.Scheduler ~= nil and type(S.Scheduler.RemoveTask) == "function" then
            S.Scheduler:RemoveTask(self.liveTaskName)
        end
        self.liveTaskName = nil
        if self.liveUpdateFallback == true and self.liveFallbackWidget ~= nil and type(self.liveFallbackWidget.ReleaseHandler) == "function" then
            pcall(function() self.liveFallbackWidget:ReleaseHandler("OnUpdate") end)
        end
        self.liveUpdateFallback = false
        self.liveFallbackWidget = nil
        return true
    end

    function controller:PulseLiveGeometry(force)
        if self:IsResizing() ~= true or self.pendingPlacement or type(self.onLiveGeometry) ~= "function" then return false end
        local x, y, width, height = self:GetLogicalRect()
        local changed = force == true
            or self.lastLiveWidth == nil or self.lastLiveHeight == nil
            or math.abs(width - self.lastLiveWidth) > 0.5 or math.abs(height - self.lastLiveHeight) > 0.5
            or math.abs(x - (self.lastLiveX or x)) > 0.5 or math.abs(y - (self.lastLiveY or y)) > 0.5
        if changed ~= true then return false end
        self.lastLiveX, self.lastLiveY, self.lastLiveWidth, self.lastLiveHeight = x, y, width, height
        local ok = pcall(self.onLiveGeometry, self, x, y, width, height, self.interactionKind, self.interactionDirection)
        if ok then W.metrics.liveResizeFrames = (tonumber(W.metrics.liveResizeFrames) or 0) + 1 end
        return ok
    end

    function controller:StartLiveGeometryTask(fallbackWidget)
        self:StopLiveGeometryTask()
        if self:IsResizing() ~= true or type(self.onLiveGeometry) ~= "function" then return false end
        local scheduler = S.Scheduler
        local taskName = "rsui_window_live_resize:" .. self.id
        local added = false
        if scheduler ~= nil and type(scheduler.AddInteractiveTask) == "function" then
            self.liveTaskName = taskName
            scheduler:RemoveTask(taskName)
            added = scheduler:AddInteractiveTask(taskName, 16, function()
                if controller:IsResizing() ~= true then
                    controller:StopLiveGeometryTask()
                    return true
                end
                controller:PulseLiveGeometry(false)
                return true
            end, true, controller, "P0", 1) == true
            if added ~= true then self.liveTaskName = nil end
        end
        if added ~= true and fallbackWidget ~= nil then
            self.liveFallbackWidget = fallbackWidget
            self.liveUpdateFallback = UI:SafeHandler(fallbackWidget, "OnUpdate", function()
                if controller:IsResizing() then controller:PulseLiveGeometry(false) end
                return true
            end, "v3_window:" .. self.id .. ":live_resize_update") == true
            if self.liveUpdateFallback ~= true then self.liveFallbackWidget = nil end
        end
        return added == true or self.liveUpdateFallback == true
    end

    function controller:BeginInteraction(kind, direction)
        kind = tostring(kind or "")
        if kind ~= "drag" and kind ~= "resize" then return false end
        if self.interactionKind ~= nil then return false end
        if type(UI.BeginNativeGeometryLease) == "function" then
            local ok = UI:BeginNativeGeometryLease(self.window, self.owner, kind)
            if ok ~= true then return false end
        end
        local _,_,_,_,info = ReadLogicalRect(self.window)
        self.geometryUnitScale = type(info) == "table" and info.effectiveScale or nil
        self.interactionViewport = S.Layout and S.Layout:MakeSignature(S.Layout:GetContext()) or nil
        self.interactionKind = kind
        self.interactionDirection = direction
        self.lastLiveX, self.lastLiveY, self.lastLiveWidth, self.lastLiveHeight = self:GetLogicalRect()
        W.metrics.interactionBegins = (tonumber(W.metrics.interactionBegins) or 0) + 1
        return true
    end

    function controller:EndInteraction()
        if self.interactionKind == nil then return true end
        self:StopLiveGeometryTask()
        if type(UI.EndNativeGeometryLease) == "function" then UI:EndNativeGeometryLease(self.window, self.owner) end
        self.interactionKind = nil
        self.interactionDirection = nil
        self.lastLiveX, self.lastLiveY, self.lastLiveWidth, self.lastLiveHeight = nil, nil, nil, nil
        W.metrics.interactionEnds = (tonumber(W.metrics.interactionEnds) or 0) + 1
        return true
    end

    function controller:IsDragAllowed()
        if self.enabled ~= true or self.locked == true then return false end
        if type(self.canDrag) == "function" then
            local ok, value = pcall(self.canDrag, self)
            return ok and value ~= false
        end
        return true
    end

    function controller:IsResizeAllowed()
        if self.enabled ~= true or self.locked == true or self.resizeEnabled ~= true then return false end
        if type(self.canResize) == "function" then
            local ok, value = pcall(self.canResize, self)
            return ok and value ~= false
        end
        return true
    end

    function controller:ApplyNativeResizeBounds()
        if self.window == nil then return false, "window_required" end
        local context = S.Layout and S.Layout:GetContext() or { addonScale = 1 }
        local scale = self.scaleWithAddon == false and 1 or math.max(0.01, tonumber(context.addonScale) or 1)
        local minW = math.max(1, (tonumber(self.minWidth) or 1) * scale)
        local minH = math.max(1, (tonumber(self.minHeight) or 1) * scale)
        -- 维护：语义 min 不能大于当前 viewport，否则运行时 fit 被 native resize 限制撤销。
        -- 原 min/preferred 不改，返回大屏时自动恢复；这里只更新本次 native bounds。
        minW = math.min(minW, context.usableWidth or minW)
        minH = math.min(minH, context.usableHeight or minH)
        -- Native APIs require a finite maximum on some RU clients. When the
        -- caller has no semantic max, use a very large technical guard instead
        -- of silently capping to the current viewport.
        local maxW = math.max(minW, (tonumber(self.maxWidth) or NATIVE_RESIZE_LIMIT) * scale)
        local maxH = math.max(minH, (tonumber(self.maxHeight) or NATIVE_RESIZE_LIMIT) * scale)
        local resizingOk, resizingErr = EnsureNativeResizing(self.window, self.resizeEnabled == true and self.locked ~= true)
        if resizingOk ~= true then return false, resizingErr end
        if type(UI.TryInteractionCall) ~= "function" then return false, "interaction_contract_unavailable" end
        if type(self.window.SetMinResizingExtent) == "function" then
            local minOk, minErr = UI:TryInteractionCall(self.window, "SetMinResizingExtent", minW, minH)
            if minOk ~= true then return false, tostring(minErr or "native_min_resize_extent_rejected") end
        end
        if type(self.window.SetMaxResizingExtent) == "function" then
            local maxOk, maxErr = UI:TryInteractionCall(self.window, "SetMaxResizingExtent", maxW, maxH)
            if maxOk ~= true then return false, tostring(maxErr or "native_max_resize_extent_rejected") end
        end
        return true, nil
    end

    function controller:CommitGeometry(reason)
        -- 手势结束允许新鲜读取一次；Metrics 未通知但此时已变化也不能将旧坐标标成新空间。
        if S.Layout and self.interactionViewport then
            S.Layout:GetContext(true)
            if self.interactionViewport ~= S.Layout:MakeSignature(S.Layout:GetContext()) then self.pendingPlacement = true end
        end
        if self.pendingPlacement then
            self.pendingPlacement, self.geometryUnitScale, self.interactionViewport = nil, nil, nil
            if type(self.onPlacementReady) == "function" then return self.onPlacementReady() end
            return false, "viewport_changed_during_gesture"
        end
        local x, y, width, height = self:GetLogicalRect()
        self.geometryUnitScale, self.interactionViewport = nil, nil
        local context = S.Layout and S.Layout:GetContext() or { addonScale = 1 }
        local scale = self.scaleWithAddon == false and 1 or math.max(0.01, tonumber(context.addonScale) or 1)
        -- 维护：drag 只改位置；compact / runtime-fitted 尺寸不能被语义 min 拉大，
        -- 更不能当作用户 resize 写回 preferred size。只有 resize 才应用尺寸约束。
        if tostring(reason) == "resize" then
            width = math.max(math.min((tonumber(self.minWidth) or 1)*scale,context.usableWidth or width),width)
            height = math.max(math.min((tonumber(self.minHeight) or 1)*scale,context.usableHeight or height),height)
            if self.maxWidth ~= nil then width = math.min(width,self.maxWidth*scale) end
            if self.maxHeight ~= nil then height = math.min(height,self.maxHeight*scale) end
        end
        local ok
        ok, x, y, width, height = ReconcileWindow(self, self.window, self.owner, x, y, width, height)
        if ok ~= true then return false, x end
        if type(self.onGeometryChanged) == "function" then
            local callbackOk, accepted, detail = pcall(self.onGeometryChanged, self, x, y, width, height, tostring(reason or "geometry"))
            if callbackOk ~= true then
                W.metrics.geometryCallbackRejects = (tonumber(W.metrics.geometryCallbackRejects) or 0) + 1
                return false, tostring(accepted or "geometry_callback_exception")
            end
            if accepted == false then
                W.metrics.geometryCallbackRejects = (tonumber(W.metrics.geometryCallbackRejects) or 0) + 1
                return false, tostring(detail or "geometry_callback_rejected")
            end
        end
        if self.boundaryMode ~= "strict" then W.metrics.freePlacementCommits = (tonumber(W.metrics.freePlacementCommits) or 0) + 1 end
        return true, x, y, width, height
    end

    function controller:LayoutHandles(width, height)
        width, height = math.max(1, tonumber(width) or 1), math.max(1, tonumber(height) or 1)
        -- 维护（2026-09-22，window-resize-capture-stability-1）：StartSizing 之后 Native 窗口本身
        -- 是唯一 capture/geometry Authority。旧实现的 16ms live reflow 会再次进入 LayoutHandles，
        -- 对 8 个手柄持续重锚，并且每帧重新调用 UseResizing/SetMinResizingExtent/SetMaxResizingExtent。
        -- RU 客户端对活动中的 sizing transaction 不保证这些配置调用幂等，实机表现就是“按住边缘有时
        -- 没反应 / 刚开始又失效”。Slider 与 Table separator 已经遵守“活动 drag surface 不重锚”规则，
        -- Windowing 现在统一同一语义：手势期间只让内容跟随 live extent，手柄和 Native resize bounds
        -- 冻结到 DragStart；DragStop/Commit 后一次性重排。无 Tick 新增，不改变 Store 或窗口尺寸 Authority。
        if self:IsResizing() == true then return true end
        local t = self.handleThickness
        local interactive = self.resizeEnabled == true and self.locked ~= true and self.enabled ~= false
        if type(UI.EnsureVisible) ~= "function" or type(UI.EnsureEnabled) ~= "function" or type(UI.EnsurePickable) ~= "function" then
            return false, "window_handle_state_transaction_unavailable"
        end
        for _, definition in ipairs(HANDLE_SPECS) do
            local handle = self.handles[definition.key]
            if handle ~= nil then
                local x = definition.x(width, height, t)
                local y = definition.y(width, height, t)
                local w = definition.w(width, height, t)
                local h = definition.h(width, height, t)
                if type(UI.EnsureAnchor) ~= "function" or type(UI.EnsureExtent) ~= "function" then
                    return false, "window_handle_geometry_transaction_unavailable"
                end
                local anchorOk, _, anchorErr = UI:EnsureAnchor(handle, self.window, x, y, self.owner)
                if anchorOk ~= true then return false, tostring(anchorErr or "window_handle_anchor_rejected") end
                local extentOk, _, extentErr = UI:EnsureExtent(handle, w, h, self.owner)
                if extentOk ~= true then return false, tostring(extentErr or "window_handle_extent_rejected") end
                local visibleOk, _, visibleErr = UI:EnsureVisible(handle, interactive, self.owner)
                local enabledOk, _, enabledErr = UI:EnsureEnabled(handle, interactive, self.owner)
                local pickOk, _, pickErr = UI:EnsurePickable(handle, interactive, self.owner)
                if visibleOk ~= true or enabledOk ~= true or pickOk ~= true then
                    return false, tostring(visibleErr or enabledErr or pickErr or "window_handle_state_rejected")
                end
                -- FloatingSurface 的 Feature 内容是在 WindowShell 创建后才追加的；如果不重新 Raise，
                -- 后创建的 ListView/Scrollbar/Border 可能位于 resize emptywidget 之上，导致同一条边有时命中
                -- 内容、有时命中手柄。这里只在非活动手势的低频 Layout/Show/ResizeStop 边沿重建 z-order。
                if interactive and type(handle.Raise) == "function" then
                    local raised = pcall(function() handle:Raise() end)
                    if raised then W.metrics.resizeSurfaceRaises = (tonumber(W.metrics.resizeSurfaceRaises) or 0) + 1 end
                end
            end
        end
        return self:ApplyNativeResizeBounds()
    end

    function controller:SetResizeEnabled(enabled)
        local nextValue = enabled == true
        if self.resizeEnabled == nextValue then return true, self.resizeEnabled, false end
        local resizeOk, resizeErr = EnsureNativeResizing(self.window, nextValue and self.locked ~= true)
        if resizeOk ~= true then return false, self.resizeEnabled, false, resizeErr end
        local previous = self.resizeEnabled == true
        self.resizeEnabled = nextValue
        local _, _, width, height = ReadLogicalRect(self.window)
        local layoutOk, layoutErr = self:LayoutHandles(width, height)
        if layoutOk ~= true then
            self.resizeEnabled = previous
            EnsureNativeResizing(self.window, previous and self.locked ~= true)
            self:LayoutHandles(width, height)
            return false, self.resizeEnabled, false, layoutErr or "window_resize_handle_layout_failed"
        end
        return true, self.resizeEnabled, true
    end

    function controller:SetLocked(locked)
        local nextValue = locked == true
        if self.locked == nextValue then return true, false end
        local resizeOk, resizeErr = EnsureNativeResizing(self.window, self.resizeEnabled == true and nextValue ~= true)
        if resizeOk ~= true then return false, false, resizeErr end
        local previous = self.locked == true
        self.locked = nextValue
        local _, _, width, height = ReadLogicalRect(self.window)
        local layoutOk, layoutErr = self:LayoutHandles(width, height)
        if layoutOk ~= true then
            self.locked = previous
            EnsureNativeResizing(self.window, self.resizeEnabled == true and previous ~= true)
            self:LayoutHandles(width, height)
            return false, false, layoutErr or "window_lock_handle_layout_failed"
        end
        W.metrics.locks = (tonumber(W.metrics.locks) or 0) + 1
        return true, true
    end

    function controller:IsLocked()
        return self.locked == true
    end

    function controller:BringToFront()
        if self.window == nil or type(self.window.Raise) ~= "function" then return false end
        local ok = pcall(function() self.window:Raise() end)
        if ok then W.metrics.raises = (tonumber(W.metrics.raises) or 0) + 1 end
        return ok
    end

    function controller:SetOpacity(value)
        local previous = tonumber(self.opacity)
        local nextValue = math.max(0.0, math.min(1.0, tonumber(value) or previous or 1.0))
        if type(UI.EnsureAlpha) ~= "function" then return false, previous or nextValue, false, "alpha_transaction_unavailable" end
        local accepted, changed, detail = UI:EnsureAlpha(self.window, nextValue, self.owner)
        if accepted ~= true then return false, previous or nextValue, false, detail or "native_alpha_rejected" end
        local logicalChanged = previous == nil or math.abs(nextValue - previous) > 0.0001
        self.opacity = nextValue
        if changed == true or logicalChanged then W.metrics.opacityChanges = (tonumber(W.metrics.opacityChanges) or 0) + 1 end
        return true, nextValue, logicalChanged
    end

    function controller:GetOpacity()
        return tonumber(self.opacity) or 1.0
    end

    local function AbortAttach(detail)
        local function Release(widget, eventName)
            if widget ~= nil and type(widget.ReleaseHandler) == "function" then pcall(function() widget:ReleaseHandler(eventName) end) end
        end
        Release(dragHandle, "OnDragStart"); Release(dragHandle, "OnDragStop")
        for _, handle in pairs(controller.handles or {}) do
            Release(handle, "OnDragStart"); Release(handle, "OnDragStop"); Release(handle, "OnEnter"); Release(handle, "OnLeave"); Release(handle, "OnUpdate")
            UI:SetVisible(handle, false, owner)
        end
        if controller:IsInteracting() == true then
            if type(UI.TryInteractionCall) == "function" then UI:TryInteractionCall(window, "StopMovingOrSizing") end
            controller:EndInteraction()
        end
        return nil, tostring(detail or "window_interaction_attach_failed")
    end

    if type(UI.TryInteractionCall) ~= "function" or type(UI.RequireHandler) ~= "function"
        or type(UI.EnsureEnabled) ~= "function" or type(UI.EnsurePickable) ~= "function" then
        return AbortAttach("critical_interaction_contract_unavailable")
    end
    -- Windowing is the Authority for its drag surface. Do not assume the caller
    -- happened to create a pickable Border/EmptyWidget: establish hit-testing
    -- before enabling native drag, otherwise OnDragStart can never be delivered.
    local handleEnabled, _, handleEnableErr = UI:EnsureEnabled(dragHandle, true, owner)
    if handleEnabled ~= true then return AbortAttach("window_drag_handle_enable_failed:" .. tostring(handleEnableErr or "rejected")) end
    local handlePickable, _, handlePickErr = UI:EnsurePickable(dragHandle, true, owner)
    if handlePickable ~= true then return AbortAttach("window_drag_handle_pickable_failed:" .. tostring(handlePickErr or "rejected")) end
    local dragEnabled, dragErr = UI:TryInteractionCall(dragHandle, "EnableDrag", true)
    if dragEnabled ~= true then return AbortAttach("window_enable_drag_failed:" .. tostring(dragErr or "rejected")) end
    -- ArcheRage RU does not consistently emit OnDragStart from WidgetBase
    -- after EnableDrag(true) alone. Every window drag surface therefore uses
    -- the same verified DC_ALWAYS contract as sliders/splitters/gear buttons.
    if type(dragHandle.SetDragCondition) == "function" and DC_ALWAYS ~= nil then
        local conditionOk, conditionErr = UI:TryInteractionCall(dragHandle, "SetDragCondition", DC_ALWAYS)
        if conditionOk ~= true then return AbortAttach("window_drag_condition_failed:" .. tostring(conditionErr or "rejected")) end
    end
    local startBound, startErr = UI:RequireHandler(dragHandle, "OnDragStart", function()
        if controller:IsDragAllowed() ~= true or type(window.StartMoving) ~= "function" then return false end
        controller:BringToFront()
        if controller:BeginInteraction("drag") ~= true then return false end
        local moving = UI:TryInteractionCall(window, "StartMoving")
        controller.dragging = moving == true
        if controller.dragging ~= true then controller:EndInteraction(); return false end
        if type(controller.onDragStart) == "function" then pcall(controller.onDragStart, controller) end
        W.metrics.drags = (tonumber(W.metrics.drags) or 0) + 1
        return true
    end, "v3_window:" .. id .. ":drag_start")
    local stopBound, stopErr = UI:RequireHandler(dragHandle, "OnDragStop", function()
        if controller.dragging ~= true then return true end -- 取消/重载后的旧手势不得再次提交。
        if controller.dragging == true and type(window.StopMovingOrSizing) == "function" then pcall(function() window:StopMovingOrSizing() end) end
        controller.dragging = false
        controller:EndInteraction()
        controller:CommitGeometry("drag")
        if type(controller.onDragStop) == "function" then pcall(controller.onDragStop, controller) end
        return true
    end, "v3_window:" .. id .. ":drag_stop")
    if startBound ~= true or stopBound ~= true then
        return AbortAttach(startErr or stopErr or "window_required_drag_handler_failed")
    end

    if controller.resizeEnabled then
        for _, definition in ipairs(HANDLE_SPECS) do
            -- Deferred native drag callbacks must not capture the reused Lua 5.1
            -- generic-for variable. A stable per-handle definition preserves the
            -- correct resize direction for every edge/corner.
            local handleDefinition = definition
            local handle = UI:CreateEmptyWidget(window, "v3_window_" .. id .. "_resize_" .. handleDefinition.key, 0, 0, 1, 1, true)
            if handle ~= nil then
                controller.handles[handleDefinition.key] = handle
                local handleDragOk, handleDragErr = UI:TryInteractionCall(handle, "EnableDrag", true)
                if handleDragOk ~= true then return AbortAttach("window_resize_enable_drag_failed:" .. tostring(handleDefinition.key) .. ":" .. tostring(handleDragErr or "rejected")) end
                if type(handle.SetDragCondition) == "function" and DC_ALWAYS ~= nil then
                    local conditionOk, conditionErr = UI:TryInteractionCall(handle, "SetDragCondition", DC_ALWAYS)
                    if conditionOk ~= true then return AbortAttach("window_resize_drag_condition_failed:" .. tostring(handleDefinition.key) .. ":" .. tostring(conditionErr or "rejected")) end
                end
                -- ArcheRage RU exposes X2Cursor:SetCursorImage, but the project
                -- does not yet contain a verified resize-cursor texture path.
                -- Until that native asset is verified, provide an immediate
                -- framework-owned edge highlight on hover rather than guessing a
                -- client resource name. The hit target and actual resize gesture
                -- remain identical.
                local hoverLine = nil
                if type(handle.CreateColorDrawable) == "function" then
                    -- 维护（window-resize-hit-plane-1）：完全 alpha=0 的 EmptyWidget 在 RU 不同父层/后创建
                    -- 子控件组合下命中不稳定。0.001 是肉眼不可见的 Native hit plane，与自定义 Slider 已验证
                    -- 的透明拖动面保持一致；hover 才提高到 0.72。该 Drawable 不拥有几何或持久化。
                    hoverLine = handle:CreateColorDrawable(0.84, 0.68, 0.28, 0.001, "overlay")
                    if hoverLine ~= nil and type(hoverLine.AddAnchor) == "function" then
                        hoverLine:AddAnchor("TOPLEFT", handle, 0, 0)
                        hoverLine:AddAnchor("BOTTOMRIGHT", handle, 0, 0)
                    end
                end
                local function SetResizeHover(active)
                    if hoverLine ~= nil and type(hoverLine.SetColor) == "function" then
                        pcall(function() hoverLine:SetColor(0.84, 0.68, 0.28, active and 0.72 or 0.001) end)
                    end
                    if active then W.metrics.resizeHover = (tonumber(W.metrics.resizeHover) or 0) + 1 end
                end
                UI:SafeHandler(handle, "OnEnter", function() SetResizeHover(true); return true end, "v3_window:" .. id .. ":resize_enter:" .. handleDefinition.key)
                UI:SafeHandler(handle, "OnLeave", function() if handle.rsWindowSizing ~= true then SetResizeHover(false) end; return true end, "v3_window:" .. id .. ":resize_leave:" .. handleDefinition.key)
                local resizeStartBound, resizeStartErr = UI:RequireHandler(handle, "OnDragStart", function()
                    W.metrics.resizeStartAttempts = (tonumber(W.metrics.resizeStartAttempts) or 0) + 1
                    if controller:IsResizeAllowed() ~= true or type(window.StartSizing) ~= "function" then
                        W.metrics.resizeStartRejects = (tonumber(W.metrics.resizeStartRejects) or 0) + 1
                        W.metrics.lastResizeStartReject = "not_allowed_or_start_sizing_unavailable"
                        return false
                    end
                    controller:BringToFront()
                    -- 内容控件可能在最近一次布局后创建/重排；DragStart 再把实际命中的 surface 提到
                    -- 当前窗口最上层，然后整个 sizing transaction 内保持静止，避免捕获对象被自己移动。
                    if type(handle.Raise) == "function" then pcall(function() handle:Raise() end) end
                    if controller:BeginInteraction("resize", handleDefinition.direction) ~= true then
                        W.metrics.resizeStartRejects = (tonumber(W.metrics.resizeStartRejects) or 0) + 1
                        W.metrics.lastResizeStartReject = "geometry_lease_rejected"
                        return false
                    end
                    local sizing = UI:TryInteractionCall(window, "StartSizing", handleDefinition.direction)
                    handle.rsWindowSizing = sizing == true
                    if handle.rsWindowSizing ~= true then
                        controller:EndInteraction()
                        W.metrics.resizeStartRejects = (tonumber(W.metrics.resizeStartRejects) or 0) + 1
                        W.metrics.lastResizeStartReject = "native_start_sizing_rejected"
                        return false
                    end
                    W.metrics.lastResizeStartReject = nil
                    if type(controller.onResizeStart) == "function" then pcall(controller.onResizeStart, controller, handleDefinition.direction) end
                    controller:PulseLiveGeometry(true)
                    controller:StartLiveGeometryTask(handle)
                    W.metrics.resizes = (tonumber(W.metrics.resizes) or 0) + 1
                    SetResizeHover(true)
                    return true
                end, "v3_window:" .. id .. ":resize_start:" .. handleDefinition.key)
                local resizeStopBound, resizeStopErr = UI:RequireHandler(handle, "OnDragStop", function()
                    if handle.rsWindowSizing ~= true then return true end -- Reset 后迟到回调无效。
                    if handle.rsWindowSizing == true and type(window.StopMovingOrSizing) == "function" then pcall(function() window:StopMovingOrSizing() end) end
                    handle.rsWindowSizing = false
                    controller:PulseLiveGeometry(true)
                    controller:EndInteraction()
                    SetResizeHover(false)
                    controller:CommitGeometry("resize")
                    local _, _, width, height = ReadLogicalRect(window)
                    controller:LayoutHandles(width, height)
                    if type(controller.onResizeStop) == "function" then pcall(controller.onResizeStop, controller, handleDefinition.direction) end
                    return true
                end, "v3_window:" .. id .. ":resize_stop:" .. handleDefinition.key)
                if resizeStartBound ~= true or resizeStopBound ~= true then
                    return AbortAttach(resizeStartErr or resizeStopErr or ("window_required_resize_handler_failed:" .. tostring(handleDefinition.key)))
                end
            else
                return AbortAttach("window_resize_handle_create_failed:" .. tostring(handleDefinition.key))
            end
        end
    end

    local initialOpacityOk, _, _, initialOpacityErr = controller:SetOpacity(controller.opacity)
    if initialOpacityOk ~= true then return AbortAttach("window_initial_opacity_failed:" .. tostring(initialOpacityErr or "rejected")) end
    local _, _, initialWidth, initialHeight = ReadLogicalRect(window)
    local initialLayoutOk, initialLayoutErr = controller:LayoutHandles(initialWidth, initialHeight)
    if initialLayoutOk ~= true then return AbortAttach("window_initial_handle_layout_failed:" .. tostring(initialLayoutErr or "rejected")) end
    self.bindings[id] = controller
    self.metrics.attached = (tonumber(self.metrics.attached) or 0) + 1
    return controller
end

function W:Detach(id)
    id = tostring(id or "")
    local controller = self.bindings[id]
    if controller == nil then return false end
    controller.enabled = false
    controller.locked = true
    -- Detach can happen during page/shell teardown while native mouse capture is
    -- still active. Release the RU StartMoving/StartSizing transaction before
    -- dropping the geometry lease/handlers, otherwise a hidden stale window may
    -- keep moving or sizing until the next mouse event.
    if controller:IsInteracting() == true and controller.window ~= nil and type(controller.window.StopMovingOrSizing) == "function" then
        pcall(function() controller.window:StopMovingOrSizing() end)
    end
    controller.dragging = false
    for _, handle in pairs(controller.handles or {}) do handle.rsWindowSizing = false end
    controller:EndInteraction()
    if controller.window ~= nil and type(controller.window.UseResizing) == "function" then
        pcall(function() controller.window:UseResizing(false) end)
    end
    local function Release(widget, eventName)
        if widget ~= nil and type(widget.ReleaseHandler) == "function" then pcall(function() widget:ReleaseHandler(eventName) end) end
    end
    Release(controller.dragHandle, "OnDragStart")
    Release(controller.dragHandle, "OnDragStop")
    for _, handle in pairs(controller.handles or {}) do
        Release(handle, "OnDragStart")
        Release(handle, "OnDragStop")
        Release(handle, "OnEnter")
        Release(handle, "OnLeave")
        UI:SetVisible(handle, false, controller.owner)
    end
    self.bindings[id] = nil
    self.metrics.detached = (tonumber(self.metrics.detached) or 0) + 1
    return true
end

function W:Describe()
    local count, locked = 0, 0
    for _, controller in pairs(self.bindings or {}) do
        count = count + 1
        if controller.locked == true then locked = locked + 1 end
    end
    return {
        version = self.version,
        attached = count,
        locked = locked,
        detached = tonumber(self.metrics.detached) or 0,
        drags = tonumber(self.metrics.drags) or 0,
        resizes = tonumber(self.metrics.resizes) or 0,
        lockChanges = tonumber(self.metrics.locks) or 0,
        raises = tonumber(self.metrics.raises) or 0,
        opacityChanges = tonumber(self.metrics.opacityChanges) or 0,
        resizeHover = tonumber(self.metrics.resizeHover) or 0,
        liveResizeFrames = tonumber(self.metrics.liveResizeFrames) or 0,
        resizeStartAttempts = tonumber(self.metrics.resizeStartAttempts) or 0,
        resizeStartRejects = tonumber(self.metrics.resizeStartRejects) or 0,
        resizeSurfaceRaises = tonumber(self.metrics.resizeSurfaceRaises) or 0,
        lastResizeStartReject = self.metrics.lastResizeStartReject,
        resizeHitSurfaceContractVersion = tonumber(self.ResizeHitSurfaceContractVersion) or 0,
        resizeCaptureStabilityContractVersion = tonumber(self.ResizeCaptureStabilityContractVersion) or 0,
        interactionBegins = tonumber(self.metrics.interactionBegins) or 0,
        interactionEnds = tonumber(self.metrics.interactionEnds) or 0,
        freePlacementCommits = tonumber(self.metrics.freePlacementCommits) or 0,
        recoveryClamps = tonumber(self.metrics.recoveryClamps) or 0,
        idempotentStateContractVersion = tonumber(self.IdempotentStateContractVersion) or 0,
        callbackCaptureContractVersion = tonumber(self.CallbackCaptureContractVersion) or 0,
    }
end
