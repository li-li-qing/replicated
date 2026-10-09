------------------------------------------------------------------------
-- 中文维护（2026-10-09）：寻宝世界指引只消费 Feature 的屏幕帧；背包/选择/坐标归属 Treasure，
-- 相机与深度否决归属 ScreenProjectionV3。参考 GroundCompass 的圈+箭头行为，不导入其独立运行时。
-- Native 点池固定上限 96，复用现有可显示的 Label 字形；不叠 Drawable、不抢输入、不建立常驻 Scheduler。
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local F = S.Features and S.Features.Treasure
if type(F) ~= "table" or type(S.UI) ~= "table" then return end
S.UIV3 = S.UIV3 or {}
local P = { owner = "v3:treasure_compass", pool = {} }
S.UIV3.TreasureCompassV3 = P

function P:Hide()
    -- 中文维护：空目标/停用/缺坐标同样收起整个宿主，已创建的点保留供下次开窗复用。
    if self.host then S.UI:SetVisible(self.host, false, self.owner) end
    return true
end
function P:Render()
    local frame = F.Authority and F.Authority.compass or {}
    local points = frame.points or {}
    if F.enabled ~= true or (tonumber(F.consumerCount) or 0) <= 0 or #points == 0 then return self:Hide() end
    -- 中文维护（2026-10-09）：分辨率/画质/UI 重载可能清掉 Native TextStyle；同现有世界引导一起失效两层缓存。
    -- 检查只读环境 revision，不查询配置、不扫背包；下一帧重放样式与位置，仍复用原池。
    local revision = S.Layout and tonumber(S.Layout.metricsRevision) or 0
    if S.Layout and type(S.Layout.GetUiEnvironmentRevision) == "function" then revision = tonumber(S.Layout:GetUiEnvironmentRevision()) or 0 end
    if self.environmentRevision ~= revision then
        self.environmentRevision = revision
        if self.host and type(S.UI.InvalidateNativeState) == "function" then S.UI:InvalidateNativeState(self.host) end
        for _, dot in ipairs(self.pool) do
            dot.x, dot.y, dot.color = nil, nil, nil
            if type(S.UI.InvalidateNativeState) == "function" then S.UI:InvalidateNativeState(dot.root) end
        end
    end
    if self.host == nil then
        local host, err = S.UI:CreateOverlayWindow("v3_treasure_compass_host", self.owner)
        if host == nil then return false, err end
        self.host = host -- 中文维护：统一 game 层，背包/地图窗口可以自然遮住世界引导；不自行 Raise 或切 system。
    end
    local ox, oy = 0, 0
    if S.Layout and type(S.Layout.GetUiParentLocalOrigin) == "function" then
        local ok, x, y, known = pcall(S.Layout.GetUiParentLocalOrigin, S.Layout, self.host)
        if ok and known == true then ox, oy = tonumber(x) or 0, tonumber(y) or 0 end
    end
    -- 中文维护：投影已在 UIParent 原生坐标系，只扣除宿主原点；不能再乘插件缩放，否则箭头会漂离玩家。
    local visible = 0
    for i = 1, math.min(96, #points) do
        local point = points[i]
        local dot = self.pool[i]
        if dot == nil then
            local label, err = S.UI:CreateLabel(self.host, "v3_treasure_compass_dot_" .. i, ".", 0, 0, 1, 1, 15, "strong", "CENTER", false)
            if label == nil then self:Hide(); return false, err end
            label.rsManualTypography, label.rsManualTextColor = true, true
            -- 中文维护：世界点字号固定为原生像素，避免创建时继承的插件字体缩放改变圆环粗细。
            if type(S.UI.EnsureFontSize) == "function" then S.UI:EnsureFontSize(label, 15, self.owner) end
            S.UI:SetPickable(label, false, self.owner)
            dot = { root = label }; self.pool[i] = dot
        end
        if type(point) == "table" and point.visible == true and tonumber(point.x) and tonumber(point.y) then
            -- 中文维护：Ensure 的 accepted/no-op 契约允许低成本恢复已被 Native 重置的字号，不把缓存命中误当失败。
            if type(S.UI.EnsureFontSize) == "function" then S.UI:EnsureFontSize(dot.root, 15, self.owner) end
            local x, y = math.floor(point.x - ox + 0.5), math.floor(point.y - oy + 0.5)
            local accepted = true
            if dot.x ~= x or dot.y ~= y then
                -- 中文维护：锚点只有 Native 接受后才提交缓存；拒写则隐藏并在下一帧重试，不能冒充已显示。
                if type(S.UI.EnsureAnchor) == "function" then accepted = S.UI:EnsureAnchor(dot.root, self.host, x, y, self.owner)
                else accepted = S.UI:SetAnchor(dot.root, self.host, x, y, self.owner) end
                if accepted == true then dot.x, dot.y = x, y end
            end
            local color = i <= 64 and (frame.near and "near" or "ring") or "arrow"
            if dot.color ~= color then
                local r, g, b = 0.25, 0.82, 1.0
                if color == "arrow" then r, g, b = 1.0, 0.78, 0.16
                elseif color == "near" then r, g, b = 0.25, 1.0, 0.4 end
                S.UI:SetColor(dot.root, r, g, b, 0.92, self.owner); dot.color = color
            end
            S.UI:SetVisible(dot.root, accepted == true, self.owner)
            if accepted == true then visible = visible + 1 end
        else S.UI:SetVisible(dot.root, false, self.owner) end
    end
    for i = #points + 1, #self.pool do S.UI:SetVisible(self.pool[i].root, false, self.owner) end
    S.UI:SetVisible(self.host, visible > 0, self.owner)
    return true
end
if S.Events and type(S.Events.SubscribeInternal) == "function" then
    -- 中文维护：Feature 最后 Consumer 离开时发布空帧，Presenter 同步隐藏；自己不 AcquireConsumer，避免永久自保活。
    S.Events:SubscribeInternal(F.CompassTopic, P, function()
        local ok, err = P:Render()
        if ok ~= true and S.DiagnosticsManager and type(S.DiagnosticsManager.WarnRateLimited) == "function" then
            S.DiagnosticsManager:WarnRateLimited("treasure_compass", "RENDER_FAILED", 3000, "寻宝圈/箭头渲染失败", { error = tostring(err or "unknown") })
        end
    end)
end
