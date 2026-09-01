------------------------------------------------------------------------
-- Replicated Suite - RSUI Shared Scrollbar Behavior v3
--
-- One reusable scrollbar contract for ScrollBox/ListView/TileView.  The
-- visible thumb is presentation geometry owned by RSUI.  A transparent native
-- drag proxy owns input capture only; native StartMoving is never allowed to
-- become the visual geometry authority.
--
-- No permanent OnUpdate/Tick is created. While a drag is active the behavior
-- borrows Scheduler:AddInteractiveTask (~16 ms). Scheduler absence/rejection
-- falls back to a gesture-only OnUpdate on the dedicated drag proxy.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local UI, RSUI = S.UI, S.RSUI
if type(UI) ~= "table" or type(RSUI) ~= "table" then return end

local Scrollbar = { version = 3 }
RSUI.ScrollbarBehavior = Scrollbar

local function Clamp(value, lo, hi)
    local v = tonumber(value) or 0
    if lo ~= nil then v = math.max(v, tonumber(lo) or v) end
    if hi ~= nil then v = math.min(v, tonumber(hi) or v) end
    return v
end

local function EffectiveOffset(widget)
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

local function SetPickable(widget)
    if widget == nil then return end
    if type(widget.Enable) == "function" then pcall(function() widget:Enable(true) end) end
    if type(widget.EnablePick) == "function" then pcall(function() widget:EnablePick(true, true) end) end
    if type(widget.Clickable) == "function" then pcall(function() widget:Clickable(true, true) end) end
end

local function ReleaseHandler(widget, eventName)
    if widget ~= nil and type(widget.ReleaseHandler) == "function" then
        pcall(function() widget:ReleaseHandler(eventName) end)
    end
end

-- Pure geometry policy. In particular, when the thumb fills the track there is
-- exactly zero travel; we never fabricate a 1px drag range that can push the
-- input proxy outside an extremely small viewport.
function Scrollbar:ComputeGeometry(primary, minThumb, visibleUnits, totalUnits, offset, maxOffset)
    primary = math.max(0, tonumber(primary) or 0)
    minThumb = math.max(0, tonumber(minThumb) or 0)
    visibleUnits = math.max(1, tonumber(visibleUnits) or 1)
    totalUnits = math.max(visibleUnits, tonumber(totalUnits) or visibleUnits)
    maxOffset = math.max(0, tonumber(maxOffset) or 0)
    local thumbPrimary = math.max(minThumb, math.floor(primary * math.min(1, visibleUnits / totalUnits) + 0.5))
    thumbPrimary = math.min(primary, thumbPrimary)
    local travel = math.max(0, primary - thumbPrimary)
    local ratio = maxOffset > 0 and Clamp((tonumber(offset) or 0) / maxOffset, 0, 1) or 0
    local thumbAxis = math.floor(travel * ratio + 0.5)
    return { thumbPrimary = thumbPrimary, travel = travel, thumbAxis = thumbAxis, draggable = travel > 0 and maxOffset > 0 }
end

function Scrollbar:Attach(host, spec)
    spec = type(spec) == "table" and spec or {}
    if type(host) ~= "table" or host.root == nil then return nil, "host_required" end
    local id = tostring(spec.id or (host.id .. "_scrollbar"))
    local orientation = tostring(spec.orientation or "vertical"):lower()
    if orientation ~= "horizontal" then orientation = "vertical" end
    local thickness = math.max(6, tonumber(spec.thickness or spec.width) or 14)
    -- Keep the visual thumb usable without making small viewports non-draggable.
    -- Callers may still request a larger explicit minimum.
    local minThumb = math.max(6, tonumber(spec.minThumb) or 12)
    local hitPadding = math.max(0, tonumber(spec.hitPadding) or 3)
    local parent = spec.parent or host.root

    local track = type(UI.CreateEmptyWidget) == "function" and UI:CreateEmptyWidget(parent, id .. "_track", 0, 0, thickness, 40, true) or nil
    if track == nil then return nil, "track_create_failed" end
    local thumb = UI:CreateEmptyWidget(track, id .. "_thumb", 0, 0, thickness, minThumb, true)
    local drag = UI:CreateEmptyWidget(track, id .. "_drag_proxy", 0, 0, thickness + hitPadding * 2, minThumb, true)
    if thumb == nil or drag == nil then return nil, "thumb_create_failed" end

    SetPickable(drag)
    if type(drag.EnableDrag) == "function" then pcall(function() drag:EnableDrag(true) end) end
    if type(drag.SetDragCondition) == "function" and DC_ALWAYS ~= nil then pcall(function() drag:SetDragCondition(DC_ALWAYS) end) end

    if type(track.CreateColorDrawable) == "function" then
        local bg = (S.VisualTokens and S.VisualTokens:Color("cardInset")) or {0.01, 0.03, 0.04, 0.90}
        local drawable = track:CreateColorDrawable(bg[1], bg[2], bg[3], math.min(0.78, bg[4] or 0.72), "background")
        if drawable and drawable.AddAnchor then drawable:AddAnchor("TOPLEFT", track, 0, 0); drawable:AddAnchor("BOTTOMRIGHT", track, 0, 0) end
    end
    if type(thumb.CreateThreeColorDrawable) == "function" then
        local drawable = thumb:CreateThreeColorDrawable(thickness, minThumb, "artwork")
        if drawable ~= nil then
            if drawable.AddAnchor then drawable:AddAnchor("TOPLEFT", thumb, 1, 0); drawable:AddAnchor("BOTTOMRIGHT", thumb, -1, 0) end
            local a = (S.VisualTokens and S.VisualTokens:Color("cyanSoft")) or {0.13,0.49,0.57,0.88}
            local b = (S.VisualTokens and S.VisualTokens:Color("cyanDim")) or {0.08,0.28,0.33,0.72}
            if drawable.ChangeColor1 then drawable:ChangeColor1(a[1],a[2],a[3],a[4] or 1) end
            if drawable.ChangeColor2 then drawable:ChangeColor2(b[1],b[2],b[3],b[4] or 1) end
            if drawable.ChangeColor3 then drawable:ChangeColor3(a[1],a[2],a[3],a[4] or 1) end
        end
    elseif type(thumb.CreateColorDrawable) == "function" then
        local a = (S.VisualTokens and S.VisualTokens:Color("cyanSoft")) or {0.13,0.49,0.57,0.88}
        local drawable = thumb:CreateColorDrawable(a[1],a[2],a[3],a[4] or 0.88,"artwork")
        if drawable and drawable.AddAnchor then drawable:AddAnchor("TOPLEFT",thumb,1,0); drawable:AddAnchor("BOTTOMRIGHT",thumb,-1,0) end
    end

    local behavior = {
        version = 3, id = id, host = host, owner = host.owner,
        orientation = orientation, thickness = thickness, minThumb = minThumb,
        hitPadding = hitPadding, track = track, thumb = thumb, dragProxy = drag,
        dragging = false, travel = 0, maxOffset = 0, offset = 0,
        taskName = "rsui_scrollbar_drag:" .. id,
        getMaxOffset = spec.getMaxOffset,
        getOffset = spec.getOffset,
        setOffset = spec.setOffset,
        getVisibleUnits = spec.getVisibleUnits,
        getTotalUnits = spec.getTotalUnits,
    }

    function behavior:GetMaxOffset()
        if type(self.getMaxOffset) ~= "function" then return 0 end
        local ok, value = pcall(self.getMaxOffset, self.host)
        return ok and math.max(0, tonumber(value) or 0) or 0
    end

    function behavior:GetOffset()
        if type(self.getOffset) ~= "function" then return 0 end
        local ok, value = pcall(self.getOffset, self.host)
        return ok and math.max(0, tonumber(value) or 0) or 0
    end

    function behavior:SetOffset(value, relayout)
        if type(self.setOffset) ~= "function" then return false end
        local ok, result = pcall(self.setOffset, self.host, value, relayout)
        return ok and result ~= false
    end

    function behavior:StopInteractiveTask()
        local scheduler = S.Scheduler
        if scheduler ~= nil and type(scheduler.RemoveTask) == "function" then scheduler:RemoveTask(self.taskName) end
        if self.updateFallback == true and self.dragProxy ~= nil and type(self.dragProxy.ReleaseHandler) == "function" then
            pcall(function() self.dragProxy:ReleaseHandler("OnUpdate") end)
        end
        self.updateFallback = false
    end

    function behavior:SyncFromProxy(final)
        if self.dragging ~= true and final ~= true then return false end
        local x, y = EffectiveOffset(self.dragProxy)
        local current = self.orientation == "horizontal" and x or y
        local start = tonumber(self.dragStartAxis)
        local travel = tonumber(self.travel) or 0
        local maxOffset = self:GetMaxOffset()
        if current == nil or start == nil or travel <= 0 or maxOffset <= 0 then return false end
        local nextOffset = Clamp((tonumber(self.dragStartOffset) or 0) + ((current - start) / travel) * maxOffset, 0, maxOffset)
        return self:SetOffset(math.floor(nextOffset + 0.5), final ~= true)
    end

    function behavior:Layout(x, y, width, height, visibleUnits, totalUnits)
        width, height = math.max(1, tonumber(width) or 1), math.max(1, tonumber(height) or 1)
        UI:SetAnchor(self.track, parent, tonumber(x) or 0, tonumber(y) or 0, self.owner)
        UI:SetExtent(self.track, width, height, self.owner)
        local maxOffset = self:GetMaxOffset()
        self.maxOffset = maxOffset
        local visible = maxOffset > 0
        UI:SetVisible(self.track, visible, self.owner)
        UI:SetVisible(self.thumb, visible, self.owner)
        UI:SetVisible(self.dragProxy, visible, self.owner)
        if not visible then self.travel = 0; return false end

        if visibleUnits == nil and type(self.getVisibleUnits) == "function" then
            local ok, value = pcall(self.getVisibleUnits, self.host); if ok then visibleUnits = value end
        end
        if totalUnits == nil and type(self.getTotalUnits) == "function" then
            local ok, value = pcall(self.getTotalUnits, self.host); if ok then totalUnits = value end
        end
        visibleUnits = math.max(1, tonumber(visibleUnits) or 1)
        totalUnits = math.max(visibleUnits, tonumber(totalUnits) or (visibleUnits + maxOffset))
        local primary = self.orientation == "horizontal" and width or height
        local geometry = Scrollbar:ComputeGeometry(primary, self.minThumb, visibleUnits, totalUnits, self:GetOffset(), maxOffset)
        local thumbPrimary, travel, thumbAxis = geometry.thumbPrimary, geometry.travel, geometry.thumbAxis
        self.travel = travel

        if self.orientation == "horizontal" then
            UI:SetAnchor(self.thumb, self.track, thumbAxis, 0, self.owner)
            UI:SetExtent(self.thumb, thumbPrimary, height, self.owner)
            if self.dragging ~= true then
                UI:SetAnchor(self.dragProxy, self.track, thumbAxis - self.hitPadding, 0, self.owner)
                UI:SetExtent(self.dragProxy, thumbPrimary + self.hitPadding * 2, height, self.owner)
            end
        else
            UI:SetAnchor(self.thumb, self.track, 0, thumbAxis, self.owner)
            UI:SetExtent(self.thumb, width, thumbPrimary, self.owner)
            if self.dragging ~= true then
                UI:SetAnchor(self.dragProxy, self.track, -self.hitPadding, thumbAxis, self.owner)
                UI:SetExtent(self.dragProxy, width + self.hitPadding * 2, thumbPrimary, self.owner)
            end
        end
        if type(self.dragProxy.Raise) == "function" then pcall(function() self.dragProxy:Raise() end) end
        return true
    end

    UI:SafeHandler(drag, "OnDragStart", function()
        local maxOffset = behavior:GetMaxOffset()
        if maxOffset <= 0 or (tonumber(behavior.travel) or 0) <= 0 or type(drag.StartMoving) ~= "function" then return false end
        local x, y = EffectiveOffset(drag)
        local axis = behavior.orientation == "horizontal" and x or y
        if axis == nil then return false end
        behavior.dragging = true
        behavior.dragStartAxis = axis
        behavior.dragStartOffset = behavior:GetOffset()
        drag:StartMoving()
        behavior:StopInteractiveTask()
        local scheduler = S.Scheduler
        local scheduled = false
        if scheduler ~= nil and type(scheduler.AddInteractiveTask) == "function" then
            scheduled = scheduler:AddInteractiveTask(behavior.taskName, 16, function()
                if behavior.dragging ~= true then behavior:StopInteractiveTask(); return true end
                behavior:SyncFromProxy(false)
                return true
            end, true, host, "P0", 1) == true
        end
        if scheduled ~= true then
            behavior.updateFallback = UI:SafeHandler(drag, "OnUpdate", function()
                if behavior.dragging then behavior:SyncFromProxy(false) end
                return true
            end, "rsui:" .. id .. ":drag_update") == true
        end
        behavior:SyncFromProxy(false)
        return true
    end, "rsui:" .. id .. ":drag_start")

    UI:SafeHandler(drag, "OnDragStop", function()
        behavior:SyncFromProxy(true)
        behavior:StopInteractiveTask()
        if type(drag.StopMovingOrSizing) == "function" then pcall(function() drag:StopMovingOrSizing() end) end
        behavior.dragging = false
        behavior.dragStartAxis, behavior.dragStartOffset = nil, nil
        -- Host layout restores the input proxy to the visual thumb.  A direct
        -- call is intentional here: it is the finite end of the gesture, not a
        -- background polling path.
        if host.width and host.height and type(host.Layout) == "function" then
            pcall(function() host:Layout(host.x or 0, host.y or 0, host.width, host.height) end)
        end
        return true
    end, "rsui:" .. id .. ":drag_stop")

    UI:SetVisible(track, false, behavior.owner); UI:SetVisible(thumb, false, behavior.owner); UI:SetVisible(drag, false, behavior.owner)

    function behavior:Release()
        self:StopInteractiveTask()
        if self.dragging == true and self.dragProxy ~= nil and type(self.dragProxy.StopMovingOrSizing) == "function" then
            pcall(function() self.dragProxy:StopMovingOrSizing() end)
        end
        self.dragging = false
        self.dragStartAxis, self.dragStartOffset = nil, nil
        ReleaseHandler(self.dragProxy, "OnDragStart")
        ReleaseHandler(self.dragProxy, "OnDragStop")
        ReleaseHandler(self.dragProxy, "OnUpdate")
        if self.track ~= nil then UI:SetVisible(self.track, false, self.owner) end
        if self.thumb ~= nil then UI:SetVisible(self.thumb, false, self.owner) end
        if self.dragProxy ~= nil then UI:SetVisible(self.dragProxy, false, self.owner) end
        return true
    end

    return behavior
end
