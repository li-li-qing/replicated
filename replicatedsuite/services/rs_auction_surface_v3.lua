------------------------------------------------------------------------
-- Replicated Suite V3 - Native Auction Surface Observation Service
--
-- Read-only Service for the native Auction House window.  This service owns
-- exactly one bounded native-window observation while tools_auction is enabled
-- and publishes geometry/visibility facts to Presentation.  It never reads
-- favorites, never issues auction searches, and never owns a UI object.
--
-- RU compatibility note:
-- Some client builds return only x/y/width/height from
-- ADDON:GetContentMainScriptPosVis(UIC_AUCTION) and omit the final visibility
-- boolean.  The previous production implementation proved that behavior.  V2
-- therefore combines MainScript geometry with the native content/parent
-- IsVisible chain instead of requiring the fifth return value unconditionally.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
S.Services = S.Services or {}

local V = {
    version = 2,
    VisibilityContractVersion = 2,
    topic = "v3.auction_surface.updated",
    taskId = "v3_auction_surface_observer",
    started = false,
    revision = 0,
    snapshot = { status = "idle", visible = false, revision = 0, source = "none" },
    owner = nil,
}
V.owner = V
V.presentationBoundary = "service_only"
S.Services.AuctionSurfaceV3 = V

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
        x = Number(value.x), y = Number(value.y),
        width = Number(value.width), height = Number(value.height),
        source = tostring(value.source or "unknown"),
        reason = value.reason ~= nil and tostring(value.reason) or nil,
        revision = tonumber(value.revision) or 0,
    }
end

local function SameGeometry(a, b)
    if type(a) ~= "table" or type(b) ~= "table" then return false end
    if tostring(a.status or "") ~= tostring(b.status or "") or (a.visible == true) ~= (b.visible == true) then return false end
    if tostring(a.source or "") ~= tostring(b.source or "") or tostring(a.reason or "") ~= tostring(b.reason or "") then return false end
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
    if width < 120 or height < 120 then return false end
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

-- The ADDON content object can be a child proxy.  Visibility is considered
-- positive if any node in its short parent chain is visible.  If at least one
-- node exposes IsVisible and none are visible, the chain is known hidden.
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

local function ReadAuctionContent(addon, contentId)
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
                return Number(x), Number(y), Number(width), Number(height), depth == 0 and "auction-content" or ("auction-parent-" .. tostring(depth))
            end
        end
        if type(node.GetParent) ~= "function" then break end
        local ok, parent = pcall(function() return node:GetParent() end)
        if ok ~= true or parent == nil or parent == node then break end
        node = parent
    end
    return nil
end

function V:_Read()
    local addon = rawget(_G, "ADDON")
    local contentId = rawget(_G, "UIC_AUCTION")
    if addon == nil or contentId == nil then
        return { status = "unavailable", visible = false, source = "none", reason = "ADDON/UIC_AUCTION 不可用" }
    end
    if S.Api == nil or type(S.Api.IsCapabilityAllowed) ~= "function"
        or S.Api:IsCapabilityAllowed("ADDON:GetContentMainScriptPosVis") ~= true then
        return { status = "unavailable", visible = false, source = "none", reason = "拍卖窗口几何 API 未获能力许可" }
    end
    if type(addon.GetContentMainScriptPosVis) ~= "function" then
        return { status = "unavailable", visible = false, source = "none", reason = "拍卖窗口几何 getter 不可用" }
    end

    local logicalWidth, logicalHeight = LayoutBounds()
    local content = ReadAuctionContent(addon, contentId)
    local contentKnown, contentVisible = ReadContentChainVisible(content)

    -- Five-value native getter.  It is intentionally called directly behind the
    -- capability gate because the generic API wrapper historically carries a
    -- bounded return tuple and old RU builds may omit the final boolean.
    local ok, x, y, width, height, visible = pcall(function()
        return addon:GetContentMainScriptPosVis(contentId)
    end)
    x, y, width, height = Number(x), Number(y), Number(width), Number(height)
    local mainRect = ok == true and PlausibleRect(x, y, width, height, logicalWidth, logicalHeight)

    local resolvedVisible
    if type(visible) == "boolean" then
        resolvedVisible = visible == true
    elseif contentKnown == true then
        -- Prefer actual widget visibility over stale geometry when the native
        -- proxy exposes it.
        resolvedVisible = contentVisible == true
    elseif mainRect == true then
        -- Historical RU contract: some builds omit only the boolean while still
        -- clearing geometry when Auction House closes.  Numeric plausible
        -- geometry is therefore accepted as an open signal only when no stronger
        -- content visibility fact exists.
        resolvedVisible = true
    else
        resolvedVisible = false
    end

    if mainRect == true then
        return {
            status = "ready", visible = resolvedVisible,
            x = x, y = y, width = width, height = height,
            source = type(visible) == "boolean" and "main-script" or (contentKnown and "main-script+content-vis" or "main-script-geometry"),
            reason = nil,
        }
    end

    -- MainScript can be a content proxy with unusable geometry.  If the native
    -- content tree proves a window is visible, walk to the nearest plausible
    -- parent rectangle.  Hidden content without a rectangle remains a clean
    -- closed state; unknown visible geometry fails closed rather than floating
    -- a detached panel at a guessed coordinate.
    local px, py, pw, ph, source = ResolveContentRect(content, logicalWidth, logicalHeight)
    if px ~= nil then
        return { status = "ready", visible = contentKnown == true and contentVisible == true, x = px, y = py, width = pw, height = ph, source = source, reason = nil }
    end
    if contentKnown == true and contentVisible ~= true then
        return { status = "ready", visible = false, source = "content-hidden", reason = nil }
    end
    if ok ~= true then
        return { status = "unknown", visible = false, source = "none", reason = "拍卖窗口几何读取失败" }
    end
    return { status = "unknown", visible = false, source = "none", reason = "拍卖窗口几何/可见性返回值未知" }
end

function V:_Publish(nextSnapshot, force)
    nextSnapshot = type(nextSnapshot) == "table" and nextSnapshot or { status = "unknown", visible = false, source = "none" }
    if force ~= true and SameGeometry(self.snapshot, nextSnapshot) then return true, false end
    self.revision = (tonumber(self.revision) or 0) + 1
    nextSnapshot.revision = self.revision
    self.snapshot = CopySnapshot(nextSnapshot)
    if S.Events ~= nil and type(S.Events.Publish) == "function" then
        S.Events:Publish(self.topic, CopySnapshot(self.snapshot))
    end
    return true, true
end

function V:Refresh(reason, force)
    if self.started ~= true and force ~= true then return false, "auction surface observer stopped" end
    local nextSnapshot = self:_Read()
    nextSnapshot.reason = nextSnapshot.reason or (reason ~= nil and tostring(reason) or nil)
    return self:_Publish(nextSnapshot, force == true)
end

function V:GetSnapshot()
    return CopySnapshot(self.snapshot)
end

function V:Start()
    if self.started == true then return true end
    self.started = true
    self:_Publish(self:_Read(), true)
    if S.Scheduler == nil or type(S.Scheduler.AddTask) ~= "function" then
        self.started = false
        self:_Publish({ status = "unavailable", visible = false, source = "none", reason = "Scheduler 不可用" }, true)
        return false, "auction surface scheduler unavailable"
    end
    S.Scheduler:RemoveTask(self.taskId)
    local added = S.Scheduler:AddTask(self.taskId, 250, function()
        if V.started == true then V:Refresh("observer") end
    end, false, self.owner, "P2")
    if added ~= true then
        self.started = false
        self:_Publish({ status = "unavailable", visible = false, source = "none", reason = "拍卖窗口观察任务创建失败" }, true)
        return false, "auction surface observer task failed"
    end
    if type(S.Scheduler.SetTaskModule) == "function" then S.Scheduler:SetTaskModule(self.taskId, "tools_auction", true) end
    return true
end

function V:Stop(reason)
    if S.Scheduler ~= nil and type(S.Scheduler.RemoveTask) == "function" then S.Scheduler:RemoveTask(self.taskId) end
    self.started = false
    return self:_Publish({ status = "stopped", visible = false, source = "none", reason = tostring(reason or "feature_disabled") }, true)
end

function V:Describe()
    return {
        version = self.version,
        visibilityContractVersion = self.VisibilityContractVersion,
        started = self.started == true,
        revision = tonumber(self.revision) or 0,
        topic = self.topic,
        snapshot = self:GetSnapshot(),
    }
end
