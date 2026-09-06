------------------------------------------------------------------------
-- Replicated Suite V3 - Native Craft Surface Observation Service
--
-- Read-only bridge between verified native craft-window facts and V3
-- Presentation.  This Service never owns craft recipes, bag state, auction
-- queries, or a UI object.  It polls only three governed UIC constants while
-- tools_craft explicitly enables automatic sidecar observation.
--
-- RU safety contract:
--   * only ADDON:GetContent / GetContentMainScriptPosVis are used;
--   * candidate order is bounded: MAKE_CRAFT_ORDER -> CRAFT_ORDER -> CRAFT_BOOK;
--   * no unverified craft events are subscribed;
--   * four-value MainScript builds require a positive Content/parent visibility
--     fact before a window is considered open.  Geometry alone is not enough;
--   * no inventory/craft getter is called from this observer loop.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
S.Services = S.Services or {}

local V = {
    version = 1,
    VisibilityContractVersion = 1,
    topic = "v3.craft_surface.updated",
    taskId = "v3_craft_surface_observer",
    intervalMs = 400,
    started = false,
    revision = 0,
    snapshot = { status = "idle", visible = false, revision = 0, source = "none", kind = nil },
    owner = nil,
    candidates = {
        { globalName = "UIC_MAKE_CRAFT_ORDER", kind = "make" },
        { globalName = "UIC_CRAFT_ORDER", kind = "order" },
        { globalName = "UIC_CRAFT_BOOK", kind = "book" },
    },
}
V.owner = V
V.presentationBoundary = "service_only"
S.Services.CraftSurfaceV3 = V

local function Number(value)
    local n = tonumber(value)
    if n == nil or n ~= n then return nil end
    return n
end

local function CopySnapshot(value)
    value = type(value) == "table" and value or {}
    return {
        status = tostring(value.status or "unknown"),
        visible = value.visible == true,
        x = Number(value.x), y = Number(value.y), width = Number(value.width), height = Number(value.height),
        source = tostring(value.source or "unknown"),
        reason = value.reason ~= nil and tostring(value.reason) or nil,
        kind = value.kind ~= nil and tostring(value.kind) or nil,
        contentGlobal = value.contentGlobal ~= nil and tostring(value.contentGlobal) or nil,
        revision = tonumber(value.revision) or 0,
    }
end

local function SameSnapshot(a, b)
    if type(a) ~= "table" or type(b) ~= "table" then return false end
    for _, key in ipairs({ "status", "source", "reason", "kind", "contentGlobal" }) do
        if tostring(a[key] or "") ~= tostring(b[key] or "") then return false end
    end
    if (a.visible == true) ~= (b.visible == true) then return false end
    for _, key in ipairs({ "x", "y", "width", "height" }) do
        local av, bv = Number(a[key]), Number(b[key])
        if av == nil or bv == nil then
            if av ~= bv then return false end
        elseif math.abs(av - bv) >= 1 then
            return false
        end
    end
    return true
end

local function LayoutBounds()
    local context = S.Layout ~= nil and type(S.Layout.GetContext) == "function" and S.Layout:GetContext() or {}
    return math.max(320, Number(context.logicalWidth) or 1024), math.max(240, Number(context.logicalHeight) or 768)
end

local function PlausibleRect(x, y, width, height, logicalWidth, logicalHeight)
    x, y, width, height = Number(x), Number(y), Number(width), Number(height)
    if x == nil or y == nil or width == nil or height == nil then return false end
    if width < 100 or height < 100 then return false end
    if width > logicalWidth * 0.98 or height > logicalHeight * 0.98 then return false end
    if x > logicalWidth + 64 or y > logicalHeight + 64 or x + width < -64 or y + height < -64 then return false end
    return true
end

local function ReadWidgetVisible(widget)
    if widget == nil or type(widget.IsVisible) ~= "function" then return false, false end
    local ok, visible = pcall(function() return widget:IsVisible() end)
    if ok ~= true then return false, false end
    return true, visible == true
end

local function ReadContentChainVisible(content)
    local node, anyKnown = content, false
    for _ = 0, 8 do
        if node == nil then break end
        local known, visible = ReadWidgetVisible(node)
        if known == true then
            anyKnown = true
            if visible == true then return true, true end
        end
        if type(node.GetParent) ~= "function" then break end
        local ok, parent = pcall(function() return node:GetParent() end)
        if ok ~= true or parent == nil or parent == node then break end
        node = parent
    end
    return anyKnown, false
end

local function ReadContent(addon, contentId)
    if addon == nil or contentId == nil or S.Api == nil or type(S.Api.IsCapabilityAllowed) ~= "function" then return nil end
    if S.Api:IsCapabilityAllowed("ADDON:GetContent") ~= true or type(addon.GetContent) ~= "function" then return nil end
    local ok, content = S.Api:CallCapability("ADDON:GetContent", addon, "GetContent", contentId)
    if ok == true then return content end
    return nil
end

local function ResolveContentRect(content, logicalWidth, logicalHeight)
    local node = content
    for depth = 0, 8 do
        if node == nil then break end
        if S.Layout ~= nil and type(S.Layout.GetLogicalRect) == "function" then
            local ok, x, y, width, height = pcall(function() return S.Layout:GetLogicalRect(node) end)
            if ok == true and PlausibleRect(x, y, width, height, logicalWidth, logicalHeight) then
                return Number(x), Number(y), Number(width), Number(height), depth == 0 and "craft-content" or ("craft-parent-" .. tostring(depth))
            end
        end
        if type(node.GetParent) ~= "function" then break end
        local ok, parent = pcall(function() return node:GetParent() end)
        if ok ~= true or parent == nil or parent == node then break end
        node = parent
    end
    return nil
end

function V:_ReadCandidate(addon, candidate, logicalWidth, logicalHeight)
    local contentId = rawget(_G, candidate.globalName)
    if contentId == nil then return { status = "unavailable", visible = false, kind = candidate.kind, contentGlobal = candidate.globalName, source = "missing-uic" } end

    local content = ReadContent(addon, contentId)
    local contentKnown, contentVisible = ReadContentChainVisible(content)
    local ok, x, y, width, height, visible = pcall(function() return addon:GetContentMainScriptPosVis(contentId) end)
    x, y, width, height = Number(x), Number(y), Number(width), Number(height)
    local mainRect = ok == true and PlausibleRect(x, y, width, height, logicalWidth, logicalHeight)

    local visibilityKnown, resolvedVisible = false, false
    if type(visible) == "boolean" then
        visibilityKnown, resolvedVisible = true, visible == true
    elseif contentKnown == true then
        visibilityKnown, resolvedVisible = true, contentVisible == true
    end

    if visibilityKnown == true and resolvedVisible ~= true then
        return { status = "ready", visible = false, kind = candidate.kind, contentGlobal = candidate.globalName, source = contentKnown and "content-hidden" or "main-script-hidden" }
    end
    if visibilityKnown == true and resolvedVisible == true and mainRect == true then
        return {
            status = "ready", visible = true, kind = candidate.kind, contentGlobal = candidate.globalName,
            x = x, y = y, width = width, height = height,
            source = type(visible) == "boolean" and "main-script" or "main-script+content-vis",
        }
    end
    if visibilityKnown == true and resolvedVisible == true then
        local px, py, pw, ph, source = ResolveContentRect(content, logicalWidth, logicalHeight)
        if px ~= nil then
            return { status = "ready", visible = true, kind = candidate.kind, contentGlobal = candidate.globalName, x = px, y = py, width = pw, height = ph, source = source }
        end
        return { status = "unknown", visible = false, kind = candidate.kind, contentGlobal = candidate.globalName, source = "visible-no-geometry", reason = "制作窗口可见但几何无法安全解析" }
    end
    if ok ~= true then
        return { status = "unknown", visible = false, kind = candidate.kind, contentGlobal = candidate.globalName, source = "main-script-error", reason = "制作窗口几何读取失败" }
    end
    if mainRect == true then
        -- Unlike AuctionSurfaceV3, craft candidates do not accept geometry-only
        -- as an open signal. Multiple craft UICs can retain stale rectangles;
        -- without a boolean or Content visibility fact we fail closed.
        return { status = "unknown", visible = false, kind = candidate.kind, contentGlobal = candidate.globalName, source = "geometry-only", reason = "制作窗口仅返回几何，缺少可见性事实" }
    end
    return { status = "unknown", visible = false, kind = candidate.kind, contentGlobal = candidate.globalName, source = "unknown", reason = "制作窗口返回值未知" }
end

function V:_Read()
    local addon = rawget(_G, "ADDON")
    if addon == nil then return { status = "unavailable", visible = false, source = "none", reason = "ADDON 不可用" } end
    if S.Api == nil or type(S.Api.IsCapabilityAllowed) ~= "function"
        or S.Api:IsCapabilityAllowed("ADDON:GetContentMainScriptPosVis") ~= true then
        return { status = "unavailable", visible = false, source = "none", reason = "制作窗口几何 API 未获能力许可" }
    end
    if type(addon.GetContentMainScriptPosVis) ~= "function" then
        return { status = "unavailable", visible = false, source = "none", reason = "制作窗口几何 getter 不可用" }
    end

    local logicalWidth, logicalHeight = LayoutBounds()
    local available, unknown, firstReason = 0, 0, nil
    for _, candidate in ipairs(self.candidates) do
        local snapshot = self:_ReadCandidate(addon, candidate, logicalWidth, logicalHeight)
        if snapshot.status ~= "unavailable" then available = available + 1 end
        if snapshot.status == "ready" and snapshot.visible == true then return snapshot end
        if snapshot.status == "unknown" then unknown = unknown + 1; firstReason = firstReason or snapshot.reason end
    end
    if available == 0 then return { status = "unavailable", visible = false, source = "none", reason = "制作窗口 UIC 常量不可用" } end
    if unknown > 0 then return { status = "unknown", visible = false, source = "candidate-scan", reason = firstReason or "制作窗口可见性未知" } end
    return { status = "ready", visible = false, source = "candidates-hidden", reason = nil }
end

function V:_Publish(nextSnapshot, force)
    nextSnapshot = type(nextSnapshot) == "table" and nextSnapshot or { status = "unknown", visible = false, source = "none" }
    if force ~= true and SameSnapshot(self.snapshot, nextSnapshot) then return true, false end
    self.revision = (tonumber(self.revision) or 0) + 1
    nextSnapshot.revision = self.revision
    self.snapshot = CopySnapshot(nextSnapshot)
    if S.Events ~= nil and type(S.Events.Publish) == "function" then S.Events:Publish(self.topic, CopySnapshot(self.snapshot)) end
    return true, true
end

function V:Refresh(reason, force)
    if self.started ~= true and force ~= true then return false, "craft surface observer stopped" end
    local nextSnapshot = self:_Read()
    nextSnapshot.reason = nextSnapshot.reason or (reason ~= nil and tostring(reason) or nil)
    return self:_Publish(nextSnapshot, force == true)
end

function V:GetSnapshot() return CopySnapshot(self.snapshot) end

function V:Start()
    if self.started == true then return true end
    if S.Scheduler == nil or type(S.Scheduler.AddTask) ~= "function" then
        return false, "craft surface scheduler unavailable"
    end
    self.started = true
    self:_Publish(self:_Read(), true)
    S.Scheduler:RemoveTask(self.taskId)
    local added = S.Scheduler:AddTask(self.taskId, self.intervalMs, function()
        if V.started == true then V:Refresh("observer") end
    end, false, self.owner, "P2")
    if added ~= true then
        self.started = false
        self:_Publish({ status = "unavailable", visible = false, source = "none", reason = "制作窗口观察任务创建失败" }, true)
        return false, "craft surface observer task failed"
    end
    if type(S.Scheduler.SetTaskModule) == "function" then S.Scheduler:SetTaskModule(self.taskId, "tools_craft", true) end
    return true
end

function V:Stop(reason)
    if S.Scheduler ~= nil and type(S.Scheduler.RemoveTask) == "function" then S.Scheduler:RemoveTask(self.taskId) end
    self.started = false
    return self:_Publish({ status = "stopped", visible = false, source = "none", reason = tostring(reason or "feature_disabled") }, true)
end

function V:Describe()
    return {
        version = self.version, visibilityContractVersion = self.VisibilityContractVersion,
        started = self.started == true, intervalMs = self.intervalMs, revision = self.revision,
        topic = self.topic, snapshot = self:GetSnapshot(),
    }
end
