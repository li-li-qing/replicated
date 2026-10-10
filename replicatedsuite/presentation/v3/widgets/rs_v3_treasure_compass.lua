------------------------------------------------------------------------
-- 寻宝地面圈 Presenter：只消费 Feature 同帧投影，不扫背包、不自建调度。
-- 对照 GroundCompass 的可显示 ColorDrawable；固定316点＋5文字，变色不叠绘制层。
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local F = S.Features and S.Features.Treasure
if type(F) ~= "table" or type(S.UI) ~= "table" then return end
S.UIV3 = S.UIV3 or {}
local P = { owner = "v3:treasure_compass", pool = {}, cardinalLabels = {} }
S.UIV3.TreasureCompassV3 = P
local MAX_POINTS = 316
local COLORS = { ring = { 0.15, 0.90, 1.00, 0.85 }, treasure = { 1.00, 0.78, 0.18, 1.00 },
    center = { 1.00, 0.28, 0.22, 1.00 }, label = { 1.00, 1.00, 1.00, 1.00 } }
local function ValidPoint(point)
    if type(point) ~= "table" or point.visible ~= true then return false end
    local x, y = tonumber(point.x), tonumber(point.y)
    return x and y and x == x and y == y and math.abs(x) < math.huge and math.abs(y) < math.huge
end
local function ReadableGroundFrame(frame)
    local center = frame.center
    if not ValidPoint(center) then return false, "center_unavailable" end
    local radiusSquared = 0
    for _, point in ipairs(frame.points or {}) do
        if point.kind == "ring" and ValidPoint(point) then
            local dx, dy = point.x - center.x, point.y - center.y
            radiusSquared = math.max(radiusSquared, dx * dx + dy * dy)
        end
    end
    if radiusSquared < 65 * 65 then return false, "too_small" end -- 阈值比较不需要逐环点开方。
    local cardinals = frame.cardinals or {}
    for i = 1, #cardinals do
        for j = i + 1, #cardinals do
            local a, b = cardinals[i], cardinals[j]
            -- 极低俯角或抬头会把南北压到同一屏幕线；28×20文字至少留4px间距。
            if ValidPoint(a) and ValidPoint(b) and math.abs(a.x - b.x) < 32 and math.abs(a.y - b.y) < 24 then
                return false, "directions_overlap"
            end
        end
    end
    return true
end
local function Invalidate(node)
    node.x, node.y, node.color, node.width, node.height, node.font, node.text, node.visible = nil, nil, nil, nil, nil, nil, nil, nil
    if type(S.UI.InvalidateNativeState) == "function" then
        S.UI:InvalidateNativeState(node.root)
        if node.drawable then S.UI:InvalidateNativeState(node.drawable) end
    end
end
local function Visibility(node, value)
    if node.visible == value then return true end
    -- 控件只由本Presenter持有且不可交互；缓存成功提交的显隐，环境变化统一失效。
    -- EnsureVisible的第一返回值是接受状态，不能把SetVisible的no-op误判为拒写。
    local accepted
    if type(S.UI.EnsureVisible) == "function" then accepted = S.UI:EnsureVisible(node.root, value, P.owner)
    else accepted = S.UI:SetVisible(node.root, value, P.owner) end
    if accepted == true then node.visible = value end
    return accepted == true
end
local function SetExtent(node, width, height)
    if node.width == width and node.height == height then return true end
    local ok
    if type(S.UI.EnsureExtent) == "function" then ok = S.UI:EnsureExtent(node.root, width, height, P.owner)
    else ok = S.UI:SetExtent(node.root, width, height, P.owner) end
    if ok == true then node.width, node.height = width, height end
    return ok == true
end
local function Place(node, x, y)
    x, y = math.floor(x + 0.5), math.floor(y + 0.5)
    if node.x == x and node.y == y then return true end
    local ok
    if type(S.UI.EnsureAnchor) == "function" then ok = S.UI:EnsureAnchor(node.root, P.host, x, y, P.owner)
    else ok = S.UI:SetAnchor(node.root, P.host, x, y, P.owner) end
    if ok == true then node.x, node.y = x, y end
    return ok == true
end
local function Color(node, key)
    if node.color == key then return true end
    local c = COLORS[key]
    local changed = S.UI:SetColor(node.drawable or node.root, c[1], c[2], c[3], c[4], P.owner)
    -- 仅需变色时调用；拒写不能提交已显示缓存，下帧继续尝试。
    if changed == true then node.color = key end
    return changed == true
end
function P:Hide()
    if self.hostNode then return Visibility(self.hostNode, false) end
    return true
end
function P:CreateDot(index, size)
    local node = self.pool[index]
    if node == nil then
        local root, err = S.UI:CreateEmptyWidget(self.host, "v3_treasure_compass_dot_" .. index, 0, 0, size, size, false, self.owner)
        if root == nil then return nil, err end
        node = { root = root, width = size, height = size }
        self.pool[index] = node -- 创建中途失败也保留所有权，下帧不能重新叠加同名控件。
    end
    if node.drawable == nil then
        if node.drawableAttemptRevision == self.environmentRevision then return nil, "寻宝圆点颜色绘制不可用" end
        node.drawableAttemptRevision = self.environmentRevision -- Native创建结果未知时，每个环境仅尝试一次。
        local ok, drawable = pcall(function() return node.root:CreateColorDrawable(0.15, 0.90, 1.00, 0.85, "artwork") end)
        if ok ~= true or drawable == nil then return nil, "寻宝圆点颜色绘制不可用" end
        node.drawable = drawable
        drawable.rsUiOwner = self.owner
    end
    if type(node.drawable.SetColor) ~= "function" then return nil, "寻宝圆点变色不可用" end
    for _, corner in ipairs({ "TOPLEFT", "BOTTOMRIGHT" }) do
        if node[corner] ~= true then
            local ok, result = pcall(function() return node.drawable:AddAnchor(corner, node.root, 0, 0) end)
            if ok ~= true or result == false then return nil, "寻宝圆点锚点未被接受" end
            node[corner] = true
        end
    end
    S.UI:SetPickable(node.root, false, self.owner)
    node.ready = true
    return node
end
function P:CreateLabel(id, width, height)
    local root, err = S.UI:CreateLabel(self.host, id, "", 0, 0, width, height, 12, "strong", "CENTER", true)
    if root == nil then return nil, err end
    root.rsManualTypography, root.rsManualTextColor = true, true
    S.UI:SetPickable(root, false, self.owner)
    return { root = root, width = width, height = height }
end
function P:RenderLabel(node, point, color, width, height, ox, oy)
    if not ValidPoint(point) then Visibility(node, false);return false end
    local accepted = SetExtent(node, width, height)
    if node.font ~= 12 and type(S.UI.EnsureFontSize) == "function" then
        if S.UI:EnsureFontSize(node.root, 12, self.owner) == true then node.font = 12 else accepted = false end
    end
    local text = tostring(point.text or "")
    if node.text ~= text then
        if S.UI:SetText(node.root, text, self.owner) == true then node.text = text else accepted = false end
    end
    if not Color(node, color) then accepted = false end
    if not Place(node, point.x - ox - width / 2, point.y - oy - height / 2) then accepted = false end
    if not Visibility(node, accepted) then accepted = false end
    return accepted
end
function P:Render()
    local frame = F.Authority and F.Authority.compass or {}
    local points = frame.points or {}
    local revision = S.Layout and tonumber(S.Layout.metricsRevision) or 0
    if S.Layout and type(S.Layout.GetUiEnvironmentRevision) == "function" then
        local environmentRevision = S.Layout:GetUiEnvironmentRevision()
        revision = tonumber(environmentRevision) or 0
    end
    if self.environmentRevision ~= revision then
        self.environmentRevision = revision
        if self.hostNode then Invalidate(self.hostNode) end
        for _, dot in ipairs(self.pool) do Invalidate(dot) end
        for _, label in ipairs(self.cardinalLabels) do Invalidate(label) end
        if self.distanceLabel then Invalidate(self.distanceLabel) end
    end
    -- 隐藏帧也先处理环境失效，避免重载后把旧的“已隐藏”缓存当成Native事实。
    if F.enabled ~= true or (tonumber(F.consumerCount) or 0) <= 0 or #points == 0 then return self:Hide() end
    local readable, hiddenReason = ReadableGroundFrame(frame)
    self.hiddenReason = hiddenReason
    if readable ~= true then return self:Hide() end
    if self.host == nil then
        local host, err = S.UI:CreateOverlayWindow("v3_treasure_compass_host", self.owner)
        if host == nil then return false, err end
        self.host = host -- 统一game层、不Raise、不抢输入。
        self.hostNode = { root = host }
    end
    -- 圈与文字扩到UI父客户区，避免旧200×200宿主裁剪子控件。
    if S.Layout and type(S.Layout.GetContext) == "function" and type(S.UI.EnsureExtent) == "function" then
        local context = S.Layout:GetContext()
        local width, height = context and tonumber(context.logicalWidth), context and tonumber(context.logicalHeight)
        if width and height and SetExtent(self.hostNode, width, height) ~= true then self:Hide();return false, "寻宝覆盖层尺寸未被接受" end
    end
    local ox, oy = 0, 0
    if S.Layout and type(S.Layout.GetUiParentLocalOrigin) == "function" then
        local ok, x, y, known = pcall(S.Layout.GetUiParentLocalOrigin, S.Layout, self.host)
        if ok and known == true then ox, oy = tonumber(x) or 0, tonumber(y) or 0 end
    end
    local visible = 0
    for i = 1, math.min(MAX_POINTS, #points) do
        local point = points[i]
        local size = math.max(3, math.min(6, tonumber(point.size) or 3))
        local dot = self.pool[i]
        if dot == nil or dot.ready ~= true then
            local err;dot, err = self:CreateDot(i, size)
            if dot == nil then self:Hide();return false, err end
        end
        if ValidPoint(point) then
            local key = point.kind == "center" and "center" or (point.kind == "arrow" or frame.near == true) and "treasure" or "ring"
            local accepted = SetExtent(dot, size, size)
            if not Color(dot, key) then accepted = false end
            -- 投影是UIParent原生坐标，仅扣宿主原点和半个点尺寸，不乘插件缩放。
            if not Place(dot, point.x - ox - size / 2, point.y - oy - size / 2) then accepted = false end
            if not Visibility(dot, accepted) then accepted = false end
            if accepted then visible = visible + 1 end
        else Visibility(dot, false) end
    end
    for i = math.min(MAX_POINTS, #points) + 1, #self.pool do Visibility(self.pool[i], false) end
    for i = 1, 4 do
        local label = self.cardinalLabels[i]
        if label == nil then
            local err;label, err = self:CreateLabel("v3_treasure_compass_direction_" .. i, 28, 20)
            if label == nil then self:Hide();return false, err end
            self.cardinalLabels[i] = label
        end
        if self:RenderLabel(label, (frame.cardinals or {})[i], "label", 28, 20, ox, oy) then visible = visible + 1 end
    end
    if self.distanceLabel == nil then
        local err;self.distanceLabel, err = self:CreateLabel("v3_treasure_compass_distance", 180, 24)
        if self.distanceLabel == nil then self:Hide();return false, err end
    end
    if self:RenderLabel(self.distanceLabel, frame.distanceLabel, "treasure", 180, 24, ox, oy) then visible = visible + 1 end
    return Visibility(self.hostNode, visible > 0)
end
if S.Events and type(S.Events.SubscribeInternal) == "function" then
    S.Events:SubscribeInternal(F.CompassTopic, P, function()
        local ok, err = P:Render()
        if ok ~= true and S.DiagnosticsManager and type(S.DiagnosticsManager.WarnRateLimited) == "function" then
            S.DiagnosticsManager:WarnRateLimited("treasure_compass", "RENDER_FAILED", 3000, "寻宝圈/箭头渲染失败", { error = tostring(err or "unknown") })
        end
    end)
end
