------------------------------------------------------------------------
-- Replicated Suite V3 - Shared Alert HUD Presenter
-- 中文维护（2026-09-13，boss-hud-clock-1）：服务持有单调计时/截止点，
-- 本文件只接收文本与几何；不自建 OnUpdate/读技能。Native 失败不能冒充文本已显示。
-- 校准只在显式编辑期间取得鼠标，通过统一 Windowing 提交 Feature 的耐久事务；
-- 正常战斗穿透，离页/停用释放。位置保存为逻辑偏移，分辨率变化不重写用户存档。
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local Alerts = S.Services and S.Services.Alerts or nil
if type(Alerts) ~= "table" or type(S.UI) ~= "table" then return end
S.UIV3 = S.UIV3 or {}
S.UIV3.AlertHudV3 = S.UIV3.AlertHudV3 or {}
local P = S.UIV3.AlertHudV3
P.version, P.patch, P.owner = 2, "boss-hud-clock-1", "v3:alert_hud"
P.visible, P.editing, P.alertVisible = false, false, false
P.textWrites, P.textFailures = 0, 0
local EDIT_TEXT = "拖动此框调整位置 · 在设置页完成调整"

local function Number(value, fallback, low, high)
    local n = tonumber(value)
    if n == nil or n ~= n or n == math.huge or n == -math.huge then n = fallback end
    return math.max(low, math.min(high, n))
end
local function Metrics()
    local _, _, _, w, h = S.Api:GetUiMetrics()
    return Number(w, 1024, 1, 16384), Number(h, 768, 1, 16384)
end
local function CopyConfig(cfg)
    cfg = type(cfg) == "table" and cfg or {}
    return { anchorMode = cfg.anchorMode == "top" and "top" or "center",
        fontSize = Number(cfg.fontSize, 34, 18, 56), width = Number(cfg.width, 720, 280, 1200),
        offsetX = Number(cfg.offsetX, 0, -8192, 8192), offsetY = Number(cfg.offsetY, 0, -8192, 8192) }
end
local function Geometry(cfg)
    local w, h = Metrics()
    local width = math.min(cfg.width, math.max(1, w - 40))
    local height = math.min(h, math.max(64, math.min(126, cfg.fontSize * 2.25)))
    local baseX, baseY = math.floor((w - width) / 2), cfg.anchorMode == "top" and 58 or math.floor(h * 0.30)
    return math.floor(math.max(0, math.min(w - width, baseX + cfg.offsetX))),
        math.floor(math.max(0, math.min(h - height, baseY + cfg.offsetY))), width, height, baseX, baseY
end
local function Visible(widget, value)
    if widget == nil then return false, "alert_widget_missing" end
    if type(S.UI.EnsureVisible) == "function" then
        local ok, _, err = S.UI:EnsureVisible(widget, value, P.owner); return ok, err
    end
    S.UI:SetVisible(widget, value, P.owner); return true
end

function P:EnsureCreated()
    if self.root ~= nil and self.label ~= nil then
        if type(S.UI.IsWidgetUsable) ~= "function" or
            (S.UI:IsWidgetUsable(self.root) == true and S.UI:IsWidgetUsable(self.label) == true) then return true end
        -- 中文维护：已退役的原生对象不能因非 nil 被复用；只释放本 Presenter，不影响其他 UI。
        if S.RSUI and S.RSUI.Windowing then S.RSUI.Windowing:Detach(self.owner) end
        self.root, self.label, self.background, self.controller = nil, nil, nil, nil
    end
    local root, err = S.UI:CreateEmptyWidget(UIParent, "v3_alert_hud_root", 0, 0, 720, 84, false, self.owner)
    if root == nil then return false, err or "alert_hud_root_create_failed" end
    local ok, bg = pcall(function() return root:CreateColorDrawable(0.02, 0.04, 0.05, 0.82, "artwork") end)
    local label = S.UI:CreateLabel(root, "v3_alert_hud_label", "", 8, 6, 704, 72, 34, "strong", "CENTER", true)
    if not ok or bg == nil or label == nil then
        Visible(root, false)
        if type(S.UI.ReleaseOwner) == "function" then S.UI:ReleaseOwner(self.owner) end
        return false, "alert_hud_child_create_failed"
    end
    self.root, self.background, self.label, self.lastText = root, bg, label, nil
    Visible(root, false)
    return true
end

function P:WriteText(text)
    if self.label == nil then return false, "alert_label_missing" end
    text = tostring(text or "")
    local accepted = S.UI:SetText(self.label, text, self.owner)
    -- 中文维护：DiffRenderer false 既可能无变化也可能拒写，不能简单把 false 当错误。
    -- 已核验 label:GetText 可回读时以 Native 为准；无读接口时只承认成功写入或本代已确认的同值。
    local read, value = false, nil
    if type(self.label.GetText) == "function" then read, value = pcall(self.label.GetText, self.label) end
    local confirmed = (read and tostring(value or "") == text)
        or (not read and (accepted == true or self.lastText == text))
    if not confirmed then
        self.textFailures = self.textFailures + 1
        self.lastError = "alert_text_not_applied"
        return false, self.lastError
    end
    self.lastText, self.textWrites = text, self.textWrites + 1
    return true
end

function P:ApplyLayout(cfg)
    if self.root == nil then return false, "alert_root_missing" end
    -- 中文维护：新机制提示可以改文字，但 Native 鼠标正在移动时不能重新锚定旧位置。
    -- Windowing 结束手势后提交几何，届时设置事务再应用布局，避免“边拖边跳回”。
    if self.controller and self.controller:IsInteracting() then return true end
    local nextConfig = CopyConfig(cfg)
    local x, y, width, height = Geometry(nextConfig)
    -- 中文维护：使用 Ensure* 的 accepted 语义，避免 no-op 被当成失败；布局只在推送/设置变更执行。
    for _, item in ipairs({ {self.root, UIParent, x, y, width, height},
        {self.background, self.root, 0, 0, width, height},
        {self.label, self.root, 8, 4, math.max(1, width - 16), math.max(1, height - 8)} }) do
        local anchored, _, anchorErr = S.UI:EnsureAnchor(item[1], item[2], item[3], item[4], self.owner)
        if anchored ~= true then return false, tostring(anchorErr or "alert_anchor_rejected") end
        local sized, _, sizeErr = S.UI:EnsureExtent(item[1], item[5], item[6], self.owner)
        if sized ~= true then return false, tostring(sizeErr or "alert_extent_rejected") end
    end
    S.UI:SetFontSize(self.label, nextConfig.fontSize, self.owner)
    self.config = nextConfig
    self.x, self.y, self.width, self.height = x, y, width, height
    return true
end

function P:Show(text, cfg)
    local ok, err = self:EnsureCreated(); if ok ~= true then return false, err end
    ok, err = self:ApplyLayout(cfg); if ok ~= true then return false, err end
    ok, err = self:WriteText(text); if ok ~= true then return false, err end
    ok, err = Visible(self.root, true); if ok ~= true then return false, err end
    S.UI:TrySetUILayer(self.root, "system")
    if type(self.root.Raise) == "function" then pcall(self.root.Raise, self.root) end
    self.visible, self.alertVisible = true, true
    return true
end
function P:UpdateText(text) return self:WriteText(text) end

function P:EditLayout(enabled, cfg, onCommit)
    local windowing = S.RSUI and S.RSUI.Windowing
    if enabled ~= true then
        self.editGeneration = (self.editGeneration or 0) + 1
        if windowing then windowing:Detach(self.owner) end
        self.controller, self.editing, self.onCommit = nil, false, nil
        if self.root and type(S.UI.EnsurePickable) == "function" then S.UI:EnsurePickable(self.root, false, self.owner) end
        if not self.alertVisible then return self:Hide() end
        return true
    end
    if not windowing or type(windowing.Attach) ~= "function" or type(onCommit) ~= "function" then
        return false, "alert_layout_editor_unavailable"
    end
    local ok, err = self:EnsureCreated(); if ok ~= true then return false, err end
    ok, err = self:ApplyLayout(cfg); if ok ~= true then return false, err end
    self.onCommit = onCommit
    if self.controller == nil then
        self.editGeneration = (self.editGeneration or 0) + 1
        local generation = self.editGeneration
        local controller, attachErr = windowing:Attach({id=self.owner, owner=self.owner, window=self.root,
            dragHandle=self.root, locked=false, resizable=false, boundaryMode="strict",
            onGeometryChanged=function(_, x, y)
                -- 中文维护：退出/重新进入编辑使旧 Native 排队回调失效，不能提交到新一轮配置。
                if P.editing ~= true or P.editGeneration ~= generation or type(P.onCommit) ~= "function" then
                    return false, "retired_alert_layout_callback"
                end
                local current = CopyConfig(P.config)
                local _, _, _, _, baseX, baseY = Geometry(current)
                -- 中文维护：Native 拖拽 -> Windowing 逻辑坐标 -> Feature 偏移持久化。
                -- 保存失败回到上次确认的几何；不使临时拖动污染永久配置，不重新启动倒计时。
                local saved, saveErr = P.onCommit(math.floor(x - baseX), math.floor(y - baseY), current.width)
                if saved ~= true then
                    P:ApplyLayout(current); P.lastError = tostring(saveErr or "alert_layout_save_failed")
                    if S.WarnOnce then S.WarnOnce("boss_hud_layout_save", "首领 HUD 位置保存失败：" .. P.lastError) end
                    return false, P.lastError
                end
                return true
            end})
        if controller == nil then
            S.UI:EnsurePickable(self.root, false, self.owner)
            self.onCommit = nil
            return false, attachErr
        end
        self.controller = controller
    end
    self.editing = true
    if not self.alertVisible then
        ok, err = self:WriteText(EDIT_TEXT)
        if ok ~= true then self:EditLayout(false); return false, err end
    end
    ok, err = Visible(self.root, true)
    if ok ~= true then self:EditLayout(false); return false, err end
    self.visible = true
    S.UI:TrySetUILayer(self.root, "system")
    return true
end

function P:Hide()
    self.alertVisible = false
    if self.editing and self.root then
        self:WriteText(EDIT_TEXT); Visible(self.root, true); self.visible = true
    else
        if self.root ~= nil then Visible(self.root, false) end
        self.visible = false
    end
    return true
end
function P:Describe()
    return {version=self.version, patch=self.patch, created=self.root~=nil, visible=self.visible,
        editing=self.editing, textWrites=self.textWrites, textFailures=self.textFailures, lastError=self.lastError,
        x=self.x, y=self.y, width=self.width, height=self.height}
end
Alerts:SetPresenter(P)
Alerts:Start()
