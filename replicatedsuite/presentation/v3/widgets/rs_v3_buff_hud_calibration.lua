------------------------------------------------------------------------
-- Replicated Suite V3 - Buff HUD Calibration Overlay v3
--
-- Transient editor for player/target head HUD profiles.  It deliberately
-- owns no Scheduler task and no Aura/Combat consumer: the preview uses bounded
-- synthetic rows plus the already-known screen anchor when available.
--
-- Persistence boundary:
--   Store -> detached CalibrationDraft -> preview/control edits -> Save only
--   Cancel never mutates Store.  The main Shell is minimized transiently and
--   restored to its pre-calibration state on exit.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local Feature = S.Features and S.Features.BuffDisplay or nil
local Markers = S.UIV3 and S.UIV3.BuffHeadMarkersV3 or nil
if type(Feature) ~= "table" or type(S.UI) ~= "table" then return end

S.UIV3 = S.UIV3 or {}
S.UIV3.BuffHudCalibrationV3 = S.UIV3.BuffHudCalibrationV3 or {}
local C = S.UIV3.BuffHudCalibrationV3
C.version = 3
C.owner = "v3:buff_hud_calibration"
C.visible = C.visible == true
C.scope = C.scope or "player"
C.component = C.component or "buffs"
C.step = tonumber(C.step) or 1
C.controls = C.controls or {}
C.inputs = C.inputs or {}
C.preview = C.preview or { icons = {} }
C.globalPreview = C.globalPreview or { items = {} }
C.globalPreviewEnabled = C.globalPreviewEnabled ~= false
C.dragging = false

-- 中文维护注释（HUD 校准专项诊断，2026-09-11）：
-- 问题原因：HUD 校准横跨 Presentation / Shell / Store / Renderer 四层，过去一旦出现“能打开但
-- 不能保存、目标不跟随、主菜单不恢复、拖动不生效”，基础框架摘要只能看到状态显示整体健康，
-- 无法证明故障发生在哪一层。Authority：此表只属于校准 Presentation 的瞬时运行态，不持久化、
-- 不参与 BuffDisplay 业务判定；Store/Feature 仍是配置唯一 Authority。数据流：用户显式校准动作 ->
--  bounded diagnostics -> DiagnosticsManager 按需读取。兼容边界：不注册 Scheduler、不进入 50ms HUD
-- 热路径、不输出逐帧聊天。实现理由：保留 12 条以内事件轨迹和聚合计数，实机一次“输出诊断摘要”
-- 即可定位。潜在风险：新增动作时必须只在用户事件边界 Trace，禁止从 LayoutPreview Tick 化采样。
-- .18.206 追加 global preview 与 live HUD suppression：校准期间正式 Renderer 只隐藏 Presentation，
-- 不释放 Consumer/Aura/位置 Lane；全局预览仅由 Draft + 既有 anchor 计算，禁止形成第二套业务数据源。
C.DiagnosticsContractVersion = 4
C.Diagnostics = C.Diagnostics or {
    contractVersion = 3, openCount = 0, openFailures = 0, saveCount = 0, saveFailures = 0,
    cancelCount = 0, syncCount = 0, resetCount = 0, dragCommitCount = 0, dragFailures = 0,
    shellMinimizeFailures = 0, shellRestoreFailures = 0, previewRefreshes = 0,
    panelDragCount = 0, panelDragFailures = 0,
    lastAction = "idle", lastError = nil, lastAt = 0, lastScope = nil, lastComponent = nil,
    dirty = false, visible = false, previewSource = "none", previewX = nil, previewY = nil,
    shellWasMinimized = nil, shellRestored = nil, panelX = nil, panelY = nil,
    lastScreenDy = nil, lastLogicalDy = nil, lastStoredDy = nil, yAdapter = "normal",
    globalPreviewEnabled = true, globalPreviewRefreshes = 0, liveHudSuppressed = false,
    suppressionFailures = 0, suppressionRestoreFailures = 0,
    templateOutputCount = 0, templateOutputFailures = 0, lastTemplateLines = 0,
    trace = {}, traceMax = 12,
}

local UNKNOWN_ICON = "ui/icon/icon_unknown_item.dds"
local COMPONENTS = {
    { key="plate",    label="血条基准" },
    { key="buffs",    label="Buff" },
    { key="debuffs",  label="Debuff" },
    { key="info",     label="基础信息" },
    { key="mainHand", label="主手" },
    { key="offHand",  label="副手" },
    { key="ranged",   label="远程" },
    { key="wings",    label="背部" },
    { key="castBar",  label="施法条" },
}
local COMPONENT_LABEL = {}
for _, row in ipairs(COMPONENTS) do COMPONENT_LABEL[row.key] = row.label end

local function Copy(value)
    if type(S.Utils) == "table" and type(S.Utils.DeepCopy) == "function" then return S.Utils.DeepCopy(value) end
    if type(value) ~= "table" then return value end
    local out = {}; for k, v in pairs(value) do out[k] = Copy(v) end; return out
end
local function NowMs() return math.max(0, tonumber(S.NowMs and S.NowMs()) or 0) end

-- 中文维护注释（诊断事件边界）：Trace 只允许被 Open/Exit/Sync/Reset/Drag 等显式用户动作
-- 调用；普通 RefreshControls/LayoutPreview 只能更新当前快照字段，避免校准期间反复布局导致轨迹
-- 被噪声淹没。traceMax 固定有界，诊断从不成为第二份业务历史缓存。
local function Trace(action, fields)
    local d = C.Diagnostics
    if type(d) ~= "table" then return end
    d.contractVersion = C.DiagnosticsContractVersion
    d.lastAction = tostring(action or "unknown")
    d.lastAt = NowMs()
    d.lastScope = tostring(C.scope or "player")
    d.lastComponent = tostring(C.component or "buffs")
    d.dirty = C.dirty == true
    d.visible = C.visible == true
    if type(fields) == "table" then
        if fields.error ~= nil then d.lastError = tostring(fields.error) end
        if fields.clearError == true then d.lastError = nil end
        if fields.shellWasMinimized ~= nil then d.shellWasMinimized = fields.shellWasMinimized == true end
        if fields.shellRestored ~= nil then d.shellRestored = fields.shellRestored == true end
    end
    local row = { at=d.lastAt, action=d.lastAction, scope=d.lastScope, component=d.lastComponent, dirty=d.dirty }
    if type(fields) == "table" then
        for key, value in pairs(fields) do
            if key ~= "clearError" and (type(value) == "string" or type(value) == "number" or type(value) == "boolean") then row[key] = value end
        end
    end
    d.trace = type(d.trace) == "table" and d.trace or {}
    d.trace[#d.trace + 1] = row
    local maxRows = math.max(4, math.min(20, math.floor(tonumber(d.traceMax) or 12)))
    while #d.trace > maxRows do table.remove(d.trace, 1) end
end

function C:GetDiagnostics()
    local d = self.Diagnostics or {}
    d.contractVersion = self.DiagnosticsContractVersion or 0
    d.visible = self.visible == true
    d.dirty = self.dirty == true
    d.lastScope = tostring(self.scope or d.lastScope or "player")
    d.lastComponent = tostring(self.component or d.lastComponent or "buffs")
    d.globalPreviewEnabled = self.globalPreviewEnabled == true
    d.liveHudSuppressed = Markers ~= nil and type(Markers.IsCalibrationSuppressed) == "function" and Markers:IsCalibrationSuppressed() == true or false
    return Copy(d)
end

local function N(value, fallback) return tonumber(value) or tonumber(fallback) or 0 end
local function Clamp(value, lo, hi, fallback)
    local n = tonumber(value); if n == nil then n = tonumber(fallback) or lo end
    if n < lo then n = lo elseif n > hi then n = hi end
    return n
end
local function Round(value)
    local n = tonumber(value) or 0
    if n >= 0 then return math.floor(n + 0.5) end
    return math.ceil(n - 0.5)
end
local function ScopeName(scope) return tostring(scope) == "target" and "目标 HUD" or "自己 HUD" end

-- 中文维护注释（HUD 校准屏幕坐标适配，2026-09-11）：
-- 问题原因：正式 Renderer 的 Buff Y 不是普通屏幕坐标。buffCfg.y 会增加“Buff 到血条的间距”，
-- 因此 storedY 越大，Buff 实际越往上；Debuff/Info/装备/施法条则仍是 storedY 越大越往下。
-- 若校准器直接把 Store 的 y 暴露给用户，就会出现 ↑/↓ 在不同组件上方向相反。
-- Authority：Store/Renderer 的历史字段语义保持不变；本适配层只负责 Presentation 中“用户看到的 Y”。
-- 数据流：屏幕语义 Y -> ScreenYToStoredY -> Draft -> 保存；预览仍由 ComputePlateLayout 读取原始 storedY。
-- 兼容边界：不改 schema5、不迁移旧配置、不改正式 Renderer；只有 Buff 需要反号。
-- 维护注意：以后若新增“正值代表向上”的组件，必须只在 UsesInvertedStoredY 中登记，禁止到按钮/拖动
-- 各自加特判，否则三条输入路径会再次漂移。
local function UsesInvertedStoredY(key) return tostring(key or "") == "buffs" end
local function StoredYToScreenY(key, value)
    local y = N(value, 0)
    return UsesInvertedStoredY(key) and -y or y
end
local function ScreenYToStoredY(key, value)
    local y = N(value, 0)
    return UsesInvertedStoredY(key) and -y or y
end
local function YAdapterName(key) return UsesInvertedStoredY(key) and "buff_gap_inverted" or "screen_normal" end

C.ScreenCoordinateAdapterContractVersion = 1
C.PanelDragContractVersion = 1
C.ContextualControlsContractVersion = 1
C.GlobalPreviewContractVersion = 1
C.LiveHudSuppressionContractVersion = 1
C.TemplateSnapshotContractVersion = 1

local function ScreenSize()
    -- 优先使用统一 UI metrics 的逻辑尺寸，避免 UI Scale!=1 时把 panel clamp 到物理像素边界。
    if S.Api ~= nil and type(S.Api.GetUiMetrics) == "function" then
        local ok, sw, sh, scale, lw, lh = pcall(S.Api.GetUiMetrics, S.Api)
        if ok then
            scale = tonumber(scale) or 1
            local w = tonumber(lw) or ((tonumber(sw) or 1024) / math.max(0.001, scale))
            local h = tonumber(lh) or ((tonumber(sh) or 768) / math.max(0.001, scale))
            if w > 0 and h > 0 then return w, h end
        end
    end
    if UIParent ~= nil and type(UIParent.GetExtent) == "function" then
        local ok, w, h = pcall(function() return UIParent:GetExtent() end)
        if ok and tonumber(w) and tonumber(h) then return tonumber(w), tonumber(h) end
    end
    return 1024, 768
end

local function SafeVisible(widget, visible)
    if widget ~= nil then S.UI:SetVisible(widget, visible == true, C.owner) end
end
local function SafeText(widget, text)
    if widget ~= nil and type(widget.SetText) == "function" then pcall(widget.SetText, widget, tostring(text or "")) end
end
local function SetDrawableColor(drawable, r, g, b, a)
    if drawable ~= nil and type(S.UI.SetColor) == "function" then S.UI:SetColor(drawable, r, g, b, a, C.owner) end
end

local function MakeFill(parent, layer, r, g, b, a)
    if parent == nil or type(parent.CreateColorDrawable) ~= "function" then return nil end
    local d = parent:CreateColorDrawable(r, g, b, a, layer or "background")
    if d ~= nil and type(d.AddAnchor) == "function" then
        d:AddAnchor("TOPLEFT", parent, 0, 0); d:AddAnchor("BOTTOMRIGHT", parent, 0, 0)
    end
    return d
end

local function MakeButton(parent, id, text, x, y, width, height, onClick)
    local button, err = S.UI:CreateButton(parent, id, text, x, y, width, height, 10, false, true, C.owner)
    if button == nil then return nil, err end
    if type(S.UI.RequireHandler) ~= "function" then return nil, "handler_contract_unavailable" end
    local ok, bindErr = S.UI:RequireHandler(button, "OnClick", function()
        if C.visible ~= true then return false end
        local accepted, detail = true, nil
        if type(onClick) == "function" then accepted, detail = onClick() end
        return accepted ~= false, detail
    end, "buff_hud_calibration:" .. tostring(id))
    if ok ~= true then return nil, bindErr end
    return button
end

local function MakeInput(parent, id, x, y, width, height)
    local edit, err = S.UI:CreateEditBox(parent, id, x, y, width, height, 12)
    if edit == nil then return nil, err or "edit_create_failed" end
    if type(S.UI.BindDeferredInputActivation) == "function" then
        local ok, bindErr = S.UI:BindDeferredInputActivation(edit, C.owner, id)
        if ok ~= true then return nil, bindErr or "input_activation_failed" end
    end
    return edit
end

local function Profile()
    local draft = type(C.draft) == "table" and C.draft or {}
    local profile = draft[C.scope]
    if type(profile) ~= "table" then profile = {}; draft[C.scope] = profile; C.draft = draft end
    profile.components = type(profile.components) == "table" and profile.components or {}
    profile.plate = type(profile.plate) == "table" and profile.plate or {}
    profile.info = type(profile.info) == "table" and profile.info or {}
    return profile
end

local function Component()
    local profile = Profile()
    if C.component == "plate" then return profile.plate end
    if C.component == "info" then return profile.info end
    profile.components[C.component] = type(profile.components[C.component]) == "table" and profile.components[C.component] or {}
    return profile.components[C.component]
end

local function CurrentFields()
    local profile, component = Profile(), Component()
    local key = C.component
    local fields = { x=N(component.x,0), y=StoredYToScreenY(key, component.y), size=nil, font=nil, alpha=nil, spacing=nil, perRow=nil, rows=nil, width=nil, scale=N(profile.plateScale,1) }
    if key == "plate" then
        fields.width=N(component.width,150); fields.size=N(component.height,20)
    elseif key == "info" then
        fields.font=N(component.fontSize,12)
    else
        fields.size=N(component.size, key == "castBar" and 7 or 26)
        fields.alpha=N(component.alpha,1)
        if key == "buffs" or key == "debuffs" or key == "castBar" then
            local fallbackFont = (key == "buffs" or key == "debuffs") and 11 or 12
            fields.font=N(component.fontSize, fallbackFont)
        end
        if key == "buffs" or key == "debuffs" then
            fields.spacing=N(component.spacing,2)
            fields.perRow=N(component.maxPerRow,8)
            fields.rows=N(component.maxRows,2)
        end
        if key == "castBar" then fields.width=N(component.width,120) end
    end
    return fields
end

local function ApplyField(name, value)
    local profile, component = Profile(), Component()
    local key = C.component
    if name == "x" then
        local lo, hi = -400, 400
        component.x = Round(Clamp(value, lo, hi, component.x or 0))
    elseif name == "y" then
        local lo, hi = -400, 400
        if key == "plate" then lo, hi = -500, 500
        elseif key == "info" then lo, hi = -120, 120 end
        -- value 始终是用户/屏幕语义：负数向上、正数向下。Store 继续保留历史字段语义。
        local currentScreenY = StoredYToScreenY(key, component.y)
        local screenY = Round(Clamp(value, lo, hi, currentScreenY))
        component.y = ScreenYToStoredY(key, screenY)
    elseif name == "size" then
        if key == "plate" then component.height = Round(Clamp(value, 8, 40, component.height or 20))
        else component.size = Round(Clamp(value, key == "castBar" and 4 or 8, 64, component.size or 26)) end
    elseif name == "font" then
        if key == "info" then component.fontSize = Round(Clamp(value, 8, 24, component.fontSize or 12))
        elseif component.fontSize ~= nil or key == "buffs" or key == "debuffs" or key == "castBar" then
            component.fontSize = Round(Clamp(value, 8, 32, component.fontSize or 12))
        end
    elseif name == "alpha" and key ~= "plate" and key ~= "info" then
        component.alpha = Clamp(value, 0.1, 1.0, component.alpha or 1.0)
    elseif name == "spacing" and (key == "buffs" or key == "debuffs") then
        component.spacing = Round(Clamp(value, 0, 24, component.spacing or 2))
    elseif name == "perRow" and (key == "buffs" or key == "debuffs") then
        component.maxPerRow = Round(Clamp(value, 1, 16, component.maxPerRow or 8))
    elseif name == "rows" and (key == "buffs" or key == "debuffs") then
        component.maxRows = Round(Clamp(value, 1, 4, component.maxRows or 2))
    elseif name == "width" then
        if key == "plate" then component.width = Round(Clamp(value, 80, 320, component.width or 150))
        elseif key == "castBar" then component.width = Round(Clamp(value, 20, 480, component.width or 120)) end
    elseif name == "scale" then
        profile.plateScale = Clamp(value, 0.5, 2.0, profile.plateScale or 1.0)
    end
    return true
end

local function CurrentEnabled()
    local profile, component = Profile(), Component()
    if C.component == "plate" then return true end -- proxy only; never rendered as a visual element
    if C.component == "info" then return profile.info.enabled ~= false end
    return component.enabled ~= false
end

local function SetCurrentEnabled(value)
    local profile, component = Profile(), Component()
    if C.component == "plate" then return false, "血条基准仅作为锚点，不提供显示开关" end
    if C.component == "info" then profile.info.enabled = value == true else component.enabled = value == true end
    C.dirty = true
    return C:RefreshControls()
end

local function PreviewAnchor(scope)
    local x, y = nil, nil
    if type(Feature.GetPlatesAnchor) == "function" then x, y = Feature:GetPlatesAnchor(scope) end
    if tonumber(x) ~= nil and tonumber(y) ~= nil then return tonumber(x), tonumber(y), true end
    local w, h = ScreenSize()
    if scope == "target" then return math.floor(w * 0.68), math.floor(h * 0.38), false end
    return math.floor(w * 0.50), math.floor(h * 0.48), false
end

local function FindEquipSlot(layout, key)
    for _, group in ipairs({ layout.leftGroup, layout.rightGroup }) do
        for _, slot in ipairs(type(group) == "table" and type(group.slots) == "table" and group.slots or {}) do
            if slot.key == key then return slot end
        end
    end
    return nil
end

local function PreviewRect(key)
    local profile = Profile()
    local anchorX, anchorY, liveAnchor = PreviewAnchor(C.scope)
    local compute = Markers and Markers.ComputePlateLayout or nil
    if type(compute) ~= "function" then return { x=anchorX-70, y=anchorY-20, width=140, height=40 }, liveAnchor end
    local layout = compute(anchorX, anchorY, profile, 4, 4, { mainHand=true, offHand=true, ranged=true, wings=true })
    key = tostring(key or C.component or "buffs")
    local scale = N(layout.scale, 1)
    if key == "plate" then
        return { x=layout.bar.left, y=layout.bar.top, width=layout.bar.width, height=layout.bar.height }, liveAnchor
    elseif key == "buffs" or key == "debuffs" then
        local region = key == "buffs" and layout.buff or layout.debuff
        local cfg = profile.components[key] or {}
        local count = math.min(4, math.max(1, Round(N(cfg.maxPerRow, 8))))
        local width = count * region.size + math.max(0, count - 1) * region.spacing
        local x = layout.bar.centerX + N(cfg.x, 0) - width / 2
        local y = region.firstTop
        return { x=Round(x), y=Round(y), width=Round(width), height=Round(region.size) }, liveAnchor
    elseif key == "info" then
        local width = math.max(160, Round(220 * scale))
        return { x=Round(layout.bar.centerX + N(profile.info.x,0) - width/2), y=Round(layout.info.top), width=width, height=math.max(18, Round(layout.info.height)) }, liveAnchor
    elseif key == "castBar" then
        local cfg = profile.components.castBar or {}
        local width = math.max(24, Round(N(cfg.width,120) * scale))
        local height = math.max(12, Round(N(cfg.size,7) * scale) + 16)
        local y = layout.bar.bottom + (layout.debuff.actualRows * layout.debuff.rowGap) + 6 * scale + N(cfg.y,0) * scale
        return { x=Round(layout.bar.centerX + N(cfg.x,0)*scale - width/2), y=Round(y), width=width, height=height }, liveAnchor
    else
        local slot = FindEquipSlot(layout, key)
        if slot ~= nil then return { x=Round(slot.x), y=Round(slot.y), width=Round(slot.size), height=Round(slot.size) }, liveAnchor end
    end
    return { x=anchorX-20, y=anchorY-20, width=40, height=40 }, liveAnchor
end

local function ComponentEnabledFor(profile, key)
    profile = type(profile) == "table" and profile or {}
    if key == "plate" then return true end
    if key == "info" then return type(profile.info) ~= "table" or profile.info.enabled ~= false end
    local components = type(profile.components) == "table" and profile.components or {}
    local component = type(components[key]) == "table" and components[key] or nil
    return component == nil or component.enabled ~= false
end

local function EnsureGlobalPreviewWidgets()
    C.globalPreview = type(C.globalPreview) == "table" and C.globalPreview or { items = {} }
    C.globalPreview.items = type(C.globalPreview.items) == "table" and C.globalPreview.items or {}
    for _, row in ipairs(COMPONENTS) do
        local key = row.key
        if C.globalPreview.items[key] == nil then
            local root, err = S.UI:CreateEmptyWidget(UIParent, "v3_buff_hud_calibration_global_" .. key, 0, 0, 40, 24, false, C.owner)
            if root == nil then return false, err or ("全局预览创建失败：" .. tostring(key)) end
            root.rsUiOwner = C.owner
            local bg = MakeFill(root, "background", key == "debuffs" and 0.45 or 0.08, key == "debuffs" and 0.08 or 0.34, 0.52, 0.18)
            local label = S.UI:CreateLabel(root, "v3_buff_hud_calibration_global_label_" .. key, row.label, 2, 2, 120, 16, 8, "strong", "CENTER", true)
            C.globalPreview.items[key] = { root = root, bg = bg, label = label }
            SafeVisible(root, false)
        end
    end
    return true
end

function C:LayoutGlobalPreview()
    if self.visible ~= true then return true end
    local created, createErr = EnsureGlobalPreviewWidgets()
    if created ~= true then return false, createErr end
    local profile = Profile()
    for _, row in ipairs(COMPONENTS) do
        local key, item = row.key, self.globalPreview.items[row.key]
        local show = self.globalPreviewEnabled == true and key ~= self.component
        if item ~= nil then
            SafeVisible(item.root, show)
            if show then
                local rect = select(1, PreviewRect(key))
                local w, h = math.max(18, N(rect.width, 40)), math.max(16, N(rect.height, 24))
                S.UI:SetAnchor(item.root, UIParent, N(rect.x,0), N(rect.y,0), self.owner)
                S.UI:SetExtent(item.root, w, h, self.owner)
                local enabled = ComponentEnabledFor(profile, key)
                S.UI:SetAlpha(item.root, enabled and 0.62 or 0.28, self.owner)
                local label = row.label
                if key == "buffs" then label = "Buff ×4"
                elseif key == "debuffs" then label = "Debuff ×4"
                elseif key == "info" then label = "职业 · 12345 · 28m"
                elseif key == "castBar" then label = "施法条"
                end
                SafeText(item.label, label .. (enabled and "" or "（关）"))
                S.UI:SetAnchor(item.label, item.root, 1, math.max(0, math.floor((h-16)/2)), self.owner)
                S.UI:SetExtent(item.label, math.max(16,w-2), 16, self.owner)
                if item.bg ~= nil then
                    if key == "debuffs" then SetDrawableColor(item.bg,0.50,0.08,0.08,0.22)
                    elseif key == "plate" then SetDrawableColor(item.bg,0.08,0.46,0.72,0.34)
                    else SetDrawableColor(item.bg,0.08,0.36,0.55,0.22) end
                end
            end
        end
    end
    self.Diagnostics.globalPreviewEnabled = self.globalPreviewEnabled == true
    self.Diagnostics.globalPreviewRefreshes = (tonumber(self.Diagnostics.globalPreviewRefreshes) or 0) + 1
    return true
end

function C:ToggleGlobalPreview()
    self.globalPreviewEnabled = self.globalPreviewEnabled ~= true
    self.Diagnostics.globalPreviewEnabled = self.globalPreviewEnabled == true
    Trace("global_preview_toggle", { globalPreview=self.globalPreviewEnabled == true, clearError=true })
    return self:RefreshControls()
end

-- 中文维护注释（发行模板快照，2026-09-11）：用户会在 RU 客户端把自己/目标 HUD 调整到
-- 最终发行模板后，把结果回传给维护者写入默认值。Authority 必须是当前 Calibration Draft，
-- 不能强迫 Save & Exit 后再从 Store 读取，否则“眼前已经调好但尚未保存”的最后一次微调会丢失。
-- 输出只包含视觉布局，不包含 tracked ID、敌我分类、Aura 业务规则等用户数据；格式固定为
-- HUD_TEMPLATE_V1 并按 META/BASE/AURA/EQUIP/CAST 分行，降低游戏聊天单行截断风险。该能力
-- 只在用户点击按钮时执行，不注册 Scheduler、不进入 50ms Renderer，也不会修改 Draft/Store。
local function TemplateNumber(value, fallback)
    local n = tonumber(value)
    if n == nil then n = tonumber(fallback) or 0 end
    if math.abs(n - Round(n)) < 0.0001 then return tostring(Round(n)) end
    local text = string.format("%.3f", n)
    text = text:gsub("0+$", ""):gsub("%.$", "")
    return text
end
local function TemplateBool(value, defaultValue)
    if value == nil then value = defaultValue end
    return value == false and "0" or "1"
end
local function TemplateComponent(profile, key, defaults)
    profile = type(profile) == "table" and profile or {}
    local components = type(profile.components) == "table" and profile.components or {}
    local c = type(components[key]) == "table" and components[key] or {}
    defaults = type(defaults) == "table" and defaults or {}
    local fields = {
        "x="..TemplateNumber(c.x, defaults.x or 0),
        "y="..TemplateNumber(StoredYToScreenY(key, c.y), defaults.y or 0),
        "size="..TemplateNumber(c.size, defaults.size or 26),
        "alpha="..TemplateNumber(c.alpha, defaults.alpha or 1),
        "enabled="..TemplateBool(c.enabled, defaults.enabled ~= false),
    }
    return key .. "{" .. table.concat(fields, ",") .. "}"
end

function C:BuildTemplateSnapshotLines(meta)
    local draft = type(self.draft) == "table" and self.draft or nil
    if type(draft) ~= "table" or type(draft.player) ~= "table" or type(draft.target) ~= "table" then
        return nil, "HUD 校准 Draft 不完整，无法输出模板"
    end
    meta = type(meta) == "table" and meta or {}
    local logicalW, logicalH = tonumber(meta.viewportWidth), tonumber(meta.viewportHeight)
    local uiScale = tonumber(meta.uiScale)
    if logicalW == nil or logicalH == nil or uiScale == nil then
        if S.Api ~= nil and type(S.Api.GetUiMetrics) == "function" then
            local ok, sw, sh, scale, lw, lh = pcall(S.Api.GetUiMetrics, S.Api)
            if ok then
                uiScale = uiScale or tonumber(scale)
                logicalW = logicalW or tonumber(lw) or ((tonumber(sw) or 0) / math.max(0.001, tonumber(scale) or 1))
                logicalH = logicalH or tonumber(lh) or ((tonumber(sh) or 0) / math.max(0.001, tonumber(scale) or 1))
            end
        end
    end
    if logicalW == nil or logicalH == nil then logicalW, logicalH = ScreenSize() end
    uiScale = uiScale or 1

    local lines = {
        "HUD_TEMPLATE_V1|META|build="..tostring(S.BuildTag or "unknown")
            ..";viewport="..TemplateNumber(logicalW,1024).."x"..TemplateNumber(logicalH,768)
            ..";uiScale="..TemplateNumber(uiScale,1)..";source=draft;coords=screen-y-v1",
    }
    local function AddScope(scopeName, profile)
        profile = type(profile) == "table" and profile or {}
        local plate = type(profile.plate) == "table" and profile.plate or {}
        local info = type(profile.info) == "table" and profile.info or {}
        local components = type(profile.components) == "table" and profile.components or {}
        local buffs = type(components.buffs) == "table" and components.buffs or {}
        local debuffs = type(components.debuffs) == "table" and components.debuffs or {}
        local castBar = type(components.castBar) == "table" and components.castBar or {}
        lines[#lines+1] = "HUD_TEMPLATE_V1|"..scopeName.."|BASE|scale="..TemplateNumber(profile.plateScale,1)
            ..";plate{x="..TemplateNumber(plate.x,0)..",y="..TemplateNumber(plate.y,0)..",w="..TemplateNumber(plate.width,180)..",h="..TemplateNumber(plate.height,24).."}"
            ..";info{x="..TemplateNumber(info.x,0)..",y="..TemplateNumber(info.y,0)..",font="..TemplateNumber(info.fontSize,12)
            ..",enabled="..TemplateBool(info.enabled,true)..",class="..TemplateBool(info.showClass,true)
            ..",gear="..TemplateBool(info.showGear,true)..",distance="..TemplateBool(info.showDistance,true).."}"
        local function Aura(key, c)
            return key.."{x="..TemplateNumber(c.x,0)..",y="..TemplateNumber(StoredYToScreenY(key,c.y),0)
                ..",size="..TemplateNumber(c.size,29)..",font="..TemplateNumber(c.fontSize,11)
                ..",spacing="..TemplateNumber(c.spacing,2)..",perRow="..TemplateNumber(c.maxPerRow,8)
                ..",rows="..TemplateNumber(c.maxRows,2)..",alpha="..TemplateNumber(c.alpha,1)
                ..",enabled="..TemplateBool(c.enabled,true).."}"
        end
        lines[#lines+1] = "HUD_TEMPLATE_V1|"..scopeName.."|AURA|"..Aura("buffs",buffs)..";"..Aura("debuffs",debuffs)
        lines[#lines+1] = "HUD_TEMPLATE_V1|"..scopeName.."|EQUIP|"
            ..TemplateComponent(profile,"mainHand",{size=26})..";"
            ..TemplateComponent(profile,"offHand",{size=26})..";"
            ..TemplateComponent(profile,"ranged",{size=26})..";"
            ..TemplateComponent(profile,"wings",{size=26})
        lines[#lines+1] = "HUD_TEMPLATE_V1|"..scopeName.."|CAST|castBar{x="..TemplateNumber(castBar.x,0)
            ..",y="..TemplateNumber(castBar.y,0)..",w="..TemplateNumber(castBar.width,120)
            ..",h="..TemplateNumber(castBar.size,7)..",font="..TemplateNumber(castBar.fontSize,12)
            ..",alpha="..TemplateNumber(castBar.alpha,1)..",enabled="..TemplateBool(castBar.enabled,true)
            ..",text="..TemplateBool(castBar.showText,true).."}"
    end
    AddScope("PLAYER", draft.player)
    AddScope("TARGET", draft.target)
    return lines
end

function C:OutputTemplateSnapshot()
    local lines, err = self:BuildTemplateSnapshotLines()
    if type(lines) ~= "table" then
        self.Diagnostics.templateOutputFailures = (tonumber(self.Diagnostics.templateOutputFailures) or 0) + 1
        Trace("template_output_failed", { error=tostring(err or "模板快照生成失败") })
        SafeText(self.statusLabel, "模板输出失败：" .. tostring(err or "未知错误"))
        return false, err
    end
    if type(S.SafeChat) ~= "function" then
        self.Diagnostics.templateOutputFailures = (tonumber(self.Diagnostics.templateOutputFailures) or 0) + 1
        Trace("template_output_failed", { error="SafeChat unavailable", templateLines=#lines })
        SafeText(self.statusLabel, "模板输出失败：聊天输出不可用")
        return false, "聊天输出不可用"
    end
    for _, line in ipairs(lines) do S.SafeChat(line, "info", "hud_template") end
    self.Diagnostics.templateOutputCount = (tonumber(self.Diagnostics.templateOutputCount) or 0) + 1
    self.Diagnostics.lastTemplateLines = #lines
    Trace("template_output", { templateLines=#lines, clearError=true })
    SafeText(self.statusLabel, "已输出 " .. tostring(#lines) .. " 条 HUD_TEMPLATE_V1，请完整复制给维护者")
    return true, lines
end

local function SetLiveHudSuppressed(value, reason)
    if type(Markers) ~= "table" or type(Markers.SetCalibrationSuppressed) ~= "function" then
        C.Diagnostics.suppressionFailures = (tonumber(C.Diagnostics.suppressionFailures) or 0) + 1
        C.Diagnostics.liveHudSuppressed = false
        return false, "正式 HUD Renderer 不支持校准隐藏"
    end
    local ok, err = Markers:SetCalibrationSuppressed(value == true, reason)
    if ok ~= true then
        if value == true then C.Diagnostics.suppressionFailures = (tonumber(C.Diagnostics.suppressionFailures) or 0) + 1
        else C.Diagnostics.suppressionRestoreFailures = (tonumber(C.Diagnostics.suppressionRestoreFailures) or 0) + 1 end
        return false, err or "正式 HUD 校准隐藏切换失败"
    end
    C.Diagnostics.liveHudSuppressed = value == true
    return true
end

local function SetPreviewChildrenVisible(kind)
    for _, icon in ipairs(C.preview.icons or {}) do SafeVisible(icon.root, kind == "icons") end
    SafeVisible(C.preview.infoLabel, kind == "info")
    SafeVisible(C.preview.castBg, kind == "cast")
    SafeVisible(C.preview.castFill, kind == "cast")
    SafeVisible(C.preview.castText, kind == "cast")
end

local function LivePreviewRows(category)
    local rows = type(Feature.GetProjection) == "function" and select(1, Feature:GetProjection(C.scope, 12)) or {}
    local out = {}
    for _, row in ipairs(type(rows) == "table" and rows or {}) do
        if tostring(row.category or "buff") == category then out[#out+1] = row; if #out >= 4 then break end end
    end
    return out
end

function C:LayoutPreview()
    if self.preview.root == nil then return false end
    local rect, liveAnchor = PreviewRect()
    self.preview.expectedRect = Copy(rect)
    -- 中文维护注释（预览定位取证）：这里只更新“最近快照”，不写 Trace；LayoutPreview 会被按钮
    -- 和输入框频繁调用，若每次入环会快速覆盖真正有价值的 Open/Save/Drag 事件。
    if type(self.Diagnostics) == "table" then
        self.Diagnostics.previewRefreshes = (tonumber(self.Diagnostics.previewRefreshes) or 0) + 1
        self.Diagnostics.previewSource = liveAnchor and "live" or "synthetic"
        self.Diagnostics.previewX, self.Diagnostics.previewY = Round(rect.x), Round(rect.y)
        self.Diagnostics.lastScope = tostring(self.scope or "player")
        self.Diagnostics.lastComponent = tostring(self.component or "buffs")
    end
    S.UI:SetAnchor(self.preview.root, UIParent, rect.x, rect.y, self.owner)
    S.UI:SetExtent(self.preview.root, math.max(1, rect.width), math.max(1, rect.height), self.owner)
    local visualFields = CurrentFields()
    S.UI:SetAlpha(self.preview.root, visualFields.alpha or 1, self.owner)
    SafeText(self.preview.caption, ScopeName(self.scope) .. " · " .. tostring(COMPONENT_LABEL[self.component] or self.component))
    local key = self.component
    if key == "buffs" or key == "debuffs" then
        SetPreviewChildrenVisible("icons")
        local fields = CurrentFields(); local size = math.max(8, Round(fields.size or 29)); local spacing = math.max(0, Round(fields.spacing or 2))
        local rows = LivePreviewRows(key == "debuffs" and "debuff" or "buff")
        for i, icon in ipairs(self.preview.icons) do
            local visible = i <= 4
            SafeVisible(icon.root, visible)
            if visible then
                S.UI:SetAnchor(icon.root, self.preview.root, (i-1)*(size+spacing), 0, self.owner)
                S.UI:SetExtent(icon.root, size, size, self.owner)
                if icon.texture ~= nil then
                    local path = rows[i] and rows[i].iconPath or UNKNOWN_ICON
                    S.UI:SetIconTexture(icon.texture, tostring(path or UNKNOWN_ICON), self.owner)
                    if type(icon.texture.SetExtent) == "function" then icon.texture:SetExtent(size, size) end
                    if type(icon.texture.RemoveAllAnchors) == "function" then icon.texture:RemoveAllAnchors() end
                    if type(icon.texture.AddAnchor) == "function" then icon.texture:AddAnchor("TOPLEFT", icon.root, 0, 0) end
                end
                SafeText(icon.time, rows[i] and rows[i].timeText or ({"12.4","8.0","25.7","1.20"})[i])
                -- 中文维护注释（预览/正式渲染一致性）：fontSize 与正式 Renderer 一样属于
                -- profile 的逻辑字体尺寸，最终必须乘 plateScale；否则校准框看到的大小和保存后
                -- 世界 HUD 不一致。这里仅做预览数值换算，不读取/写入 Store。
                S.UI:SetFontSize(icon.time, math.max(8, Round((fields.font or 11) * N(Profile().plateScale, 1))), self.owner)
                S.UI:SetAnchor(icon.time, icon.root, 0, math.max(0, size-13), self.owner)
                S.UI:SetExtent(icon.time, size, 13, self.owner)
            end
        end
    elseif key == "info" then
        SetPreviewChildrenVisible("info")
        local profile = Profile(); local parts = {}
        if (profile.components.class or {}).enabled ~= false and profile.info.showClass ~= false then parts[#parts+1] = "职业预览" end
        if (profile.components.gearScore or {}).enabled ~= false and profile.info.showGear ~= false then parts[#parts+1] = "12345" end
        if (profile.components.distance or {}).enabled ~= false and profile.info.showDistance ~= false then parts[#parts+1] = "28.4m" end
        SafeText(self.preview.infoLabel, #parts > 0 and table.concat(parts, " · ") or "基础信息已全部关闭")
        S.UI:SetFontSize(self.preview.infoLabel, math.max(8, Round((CurrentFields().font or 12) * N(Profile().plateScale, 1))), self.owner)
        S.UI:SetAnchor(self.preview.infoLabel, self.preview.root, 0, 0, self.owner)
        S.UI:SetExtent(self.preview.infoLabel, rect.width, rect.height, self.owner)
    elseif key == "castBar" then
        SetPreviewChildrenVisible("cast")
        local barH = math.max(4, Round((CurrentFields().size or 7) * N(Profile().plateScale,1)))
        S.UI:SetAnchor(self.preview.castBg, self.preview.root, 0, 0, self.owner); S.UI:SetExtent(self.preview.castBg, rect.width, barH, self.owner)
        S.UI:SetAnchor(self.preview.castFill, self.preview.root, 0, 0, self.owner); S.UI:SetExtent(self.preview.castFill, math.max(1, Round(rect.width*0.62)), barH, self.owner)
        SafeText(self.preview.castText, "施法预览")
        SafeVisible(self.preview.castText, (Profile().components.castBar or {}).showText ~= false)
        S.UI:SetFontSize(self.preview.castText, math.max(8, Round((CurrentFields().font or 12) * N(Profile().plateScale, 1))), self.owner)
        S.UI:SetAnchor(self.preview.castText, self.preview.root, 0, barH+1, self.owner); S.UI:SetExtent(self.preview.castText, rect.width, 15, self.owner)
    elseif key == "plate" then
        SetPreviewChildrenVisible("none")
    else
        SetPreviewChildrenVisible("icons")
        for i, icon in ipairs(self.preview.icons) do SafeVisible(icon.root, i == 1) end
        local icon = self.preview.icons[1]
        local size = math.max(8, Round(CurrentFields().size or 26))
        if icon ~= nil then
            S.UI:SetAnchor(icon.root, self.preview.root, 0, 0, self.owner); S.UI:SetExtent(icon.root, size, size, self.owner)
            if icon.texture ~= nil then S.UI:SetIconTexture(icon.texture, UNKNOWN_ICON, self.owner); if type(icon.texture.SetExtent)=="function" then icon.texture:SetExtent(size,size) end end
            SafeText(icon.time, "")
        end
    end
    if self.preview.bg ~= nil then
        if key == "debuffs" then SetDrawableColor(self.preview.bg, 0.50,0.08,0.08,0.20)
        elseif key == "plate" then SetDrawableColor(self.preview.bg, 0.08,0.46,0.72,0.32)
        else SetDrawableColor(self.preview.bg, 0.08,0.36,0.55,0.18) end
    end
    SafeText(self.anchorHint, liveAnchor and "锚点：游戏实时位置" or "锚点：当前无单位，使用校准预览位置")
    if type(self.preview.root.Raise) == "function" then pcall(self.preview.root.Raise, self.preview.root) end
    return true
end

local function FieldText(name, value)
    local edit = C.inputs[name]
    if edit ~= nil and type(edit.SetText) == "function" then pcall(edit.SetText, edit, tostring(value == nil and "--" or value)) end
end

function C:ToggleAux(index)
    local profile = Profile()
    if self.component == "info" then
        local keys = { "class", "gearScore", "distance" }
        local infoFields = { "showClass", "showGear", "showDistance" }
        local i = tonumber(index) or 0
        local key, infoField = keys[i], infoFields[i]
        local component = key and profile.components[key] or nil
        if type(component) ~= "table" or infoField == nil then return false, "基础信息子项不存在" end
        local current = component.enabled ~= false and profile.info[infoField] ~= false
        local nextValue = not current
        -- 两个旧字段在 Renderer 中共同决定可见性；校准器把它们作为一个用户开关写入，
        -- 避免“按钮显示开启但旧 showClass=false 仍不显示”的双 Authority 迷惑。
        component.enabled = nextValue
        profile.info[infoField] = nextValue
        self.dirty = true
        return self:RefreshControls()
    elseif self.component == "castBar" and tonumber(index) == 1 then
        local component = profile.components.castBar
        if type(component) ~= "table" then return false, "施法条配置不存在" end
        component.showText = component.showText == false
        self.dirty = true
        return self:RefreshControls()
    end
    return true
end

local FIELD_ORDER = { "x","y","size","font","spacing","perRow","rows","width","scale","alpha" }
local FIELD_VISIBLE = {
    plate   = { x=true,y=true,size=true,width=true,scale=true },
    buffs   = { x=true,y=true,size=true,font=true,spacing=true,perRow=true,rows=true,scale=true,alpha=true },
    debuffs = { x=true,y=true,size=true,font=true,spacing=true,perRow=true,rows=true,scale=true,alpha=true },
    info    = { x=true,y=true,font=true,scale=true },
    mainHand= { x=true,y=true,size=true,scale=true,alpha=true },
    offHand = { x=true,y=true,size=true,scale=true,alpha=true },
    ranged  = { x=true,y=true,size=true,scale=true,alpha=true },
    wings   = { x=true,y=true,size=true,scale=true,alpha=true },
    castBar = { x=true,y=true,size=true,font=true,width=true,scale=true,alpha=true },
}

local function LayoutContextFields()
    local rows = C.fieldRows or {}
    local visible = FIELD_VISIBLE[C.component] or {}
    local y = 210
    for _, name in ipairs(FIELD_ORDER) do
        local row = rows[name]
        local show = visible[name] == true
        if type(row) == "table" then
            SafeVisible(row.label, show); SafeVisible(row.edit, show); SafeVisible(row.minus, show); SafeVisible(row.plus, show)
            if show ~= true and row.edit ~= nil and type(S.UI.DeactivateInputWidget) == "function" then
                -- 组件切换后隐藏的 EditBox 不得继续持有输入焦点，否则键盘输入可能落到不可见控件。
                pcall(function() S.UI:DeactivateInputWidget(row.edit, C.owner, "hud_calibration_context_hide") end)
            end
            if show then
                S.UI:SetAnchor(row.label, C.panel, 126, y+4, C.owner)
                S.UI:SetAnchor(row.edit, C.panel, 181, y, C.owner)
                S.UI:SetAnchor(row.minus, C.panel, 258, y, C.owner)
                S.UI:SetAnchor(row.plus, C.panel, 289, y, C.owner)
                y = y + 27
            end
        end
    end
    return y
end

function C:RefreshControls()
    if self.visible ~= true then return true end
    SafeText(self.scopeLabel, "当前：" .. ScopeName(self.scope))
    SafeText(self.componentLabel, tostring(COMPONENT_LABEL[self.component] or self.component))
    for value, button in pairs(self.stepButtons or {}) do
        if button ~= nil then S.UI:SetButtonActive(button, tonumber(value) == tonumber(self.step), self.owner) end
    end
    if self.dirtyLabel ~= nil then
        SafeText(self.dirtyLabel, self.dirty == true and "● 未保存修改" or "已同步到存档")
    end
    if self.syncButton ~= nil then
        SafeVisible(self.syncButton, self.scope == "target")
        S.UI:SetButtonActive(self.syncButton, self.scope == "target", self.owner)
    end
    LayoutContextFields()
    local f = CurrentFields()
    FieldText("x", Round(f.x)); FieldText("y", Round(f.y)); FieldText("size", f.size and Round(f.size) or "--")
    FieldText("font", f.font and Round(f.font) or "--")
    FieldText("alpha", f.alpha and string.format("%.2f", N(f.alpha,1)) or "--")
    FieldText("spacing", f.spacing and Round(f.spacing) or "--")
    FieldText("perRow", f.perRow and Round(f.perRow) or "--"); FieldText("rows", f.rows and Round(f.rows) or "--")
    FieldText("width", f.width and Round(f.width) or "--"); FieldText("scale", string.format("%.2f", N(f.scale,1)))
    if self.enabledButton ~= nil then
        if self.component == "plate" then
            SafeText(self.enabledButton, "锚点基准")
            S.UI:SetButtonActive(self.enabledButton, false, self.owner)
        else
            SafeText(self.enabledButton, CurrentEnabled() and "显示：开" or "显示：关")
            S.UI:SetButtonActive(self.enabledButton, CurrentEnabled(), self.owner)
        end
    end
    for _, row in ipairs(COMPONENTS) do
        local button = self.controls["component_" .. row.key]
        if button ~= nil then S.UI:SetButtonActive(button, row.key == self.component, self.owner) end
    end
    if self.playerButton ~= nil then S.UI:SetButtonActive(self.playerButton, self.scope == "player", self.owner) end
    if self.targetButton ~= nil then S.UI:SetButtonActive(self.targetButton, self.scope == "target", self.owner) end
    -- 中文维护注释（旧布局能力兼容）：旧编辑器可独立开关职业/装分/距离并控制
    -- castBar.showText。新校准器把三项信息合并成一个可拖动“基础信息”区域，但不能因此
    -- 丢掉这些细粒度开关；辅助按钮只修改 Draft，仍由保存并退出统一提交。
    local profile = Profile()
    for i, button in ipairs(self.auxButtons or {}) do
        local visible = self.component == "info" or (self.component == "castBar" and i == 1)
        SafeVisible(button, visible)
        if visible then
            if self.component == "info" then
                local keys, labels = { "class", "gearScore", "distance" }, { "职业", "装分", "距离" }
                local infoFields = { "showClass", "showGear", "showDistance" }
                local item = profile.components[keys[i]] or {}
                local active = item.enabled ~= false and profile.info[infoFields[i]] ~= false
                SafeText(button, labels[i] .. (active and "：开" or "：关"))
                S.UI:SetButtonActive(button, active, self.owner)
            elseif i == 1 then
                local cast = profile.components.castBar or {}
                SafeText(button, cast.showText ~= false and "文字：开" or "文字：关")
                S.UI:SetButtonActive(button, cast.showText ~= false, self.owner)
            end
        end
    end
    if self.globalPreviewButton ~= nil then
        SafeText(self.globalPreviewButton, self.globalPreviewEnabled == true and "全局：开" or "全局：关")
        S.UI:SetButtonActive(self.globalPreviewButton, self.globalPreviewEnabled == true, self.owner)
    end
    self:LayoutGlobalPreview()
    self:LayoutPreview()
    return true
end

local function ReadInput(name)
    local edit = C.inputs[name]
    if edit == nil or type(edit.GetText) ~= "function" then return nil end
    local ok, text = pcall(edit.GetText, edit); if ok then return tonumber(text) end
    return nil
end

function C:ApplyInputFields()
    local component = Component()
    local beforeFields = CurrentFields()
    local beforeStoredY = N(component.y,0)
    for _, name in ipairs({"x","y","size","font","alpha","spacing","perRow","rows","width","scale"}) do
        local value = ReadInput(name)
        if value ~= nil then ApplyField(name, value) end
    end
    local afterFields = CurrentFields()
    local screenDy = N(afterFields.y,0) - N(beforeFields.y,0)
    local storedDy = N(component.y,0) - beforeStoredY
    self.dirty = true
    self.Diagnostics.lastScreenDy, self.Diagnostics.lastLogicalDy, self.Diagnostics.lastStoredDy = screenDy, screenDy, storedDy
    self.Diagnostics.yAdapter = YAdapterName(self.component)
    Trace("apply_inputs", { screenDy=screenDy, logicalDy=screenDy, storedDy=storedDy, yAdapter=YAdapterName(self.component), clearError=true })
    return self:RefreshControls()
end

function C:SetStep(step)
    step = tonumber(step) or 1
    if step ~= 1 and step ~= 5 and step ~= 10 then step = 1 end
    self.step = step
    return self:RefreshControls()
end

function C:Nudge(dx, dy)
    local f = CurrentFields()
    local component = Component()
    local beforeStoredY = N(component.y, 0)
    local screenDx = N(dx,0) * self.step
    local screenDy = N(dy,0) * self.step
    ApplyField("x", f.x + screenDx)
    ApplyField("y", f.y + screenDy)
    local afterStoredY = N(component.y, 0)
    self.dirty = true
    if type(self.Diagnostics) == "table" then
        self.Diagnostics.lastScreenDy = screenDy
        self.Diagnostics.lastLogicalDy = screenDy
        self.Diagnostics.lastStoredDy = afterStoredY - beforeStoredY
        self.Diagnostics.yAdapter = YAdapterName(self.component)
    end
    Trace("nudge", { screenDy=screenDy, logicalDy=screenDy, storedDy=afterStoredY-beforeStoredY, yAdapter=YAdapterName(self.component), clearError=true })
    return self:RefreshControls()
end
function C:Adjust(name, delta)
    local f = CurrentFields(); local current = f[name]
    if current == nil then return true end
    local component = Component(); local beforeStoredY = N(component.y,0)
    ApplyField(name, current + delta); self.dirty = true
    if name == "y" then
        local after = CurrentFields(); local screenDy = N(after.y,0)-N(f.y,0); local storedDy = N(component.y,0)-beforeStoredY
        self.Diagnostics.lastScreenDy, self.Diagnostics.lastLogicalDy, self.Diagnostics.lastStoredDy = screenDy, screenDy, storedDy
        self.Diagnostics.yAdapter = YAdapterName(self.component)
        Trace("adjust_y", { screenDy=screenDy, logicalDy=screenDy, storedDy=storedDy, yAdapter=YAdapterName(self.component), clearError=true })
    end
    return self:RefreshControls()
end

function C:SetScope(scope)
    scope = scope == "target" and "target" or "player"
    self.scope = scope
    if type(self.Diagnostics) == "table" then self.Diagnostics.lastScope = scope end
    Trace("scope_changed", { scope=scope, clearError=true })
    return self:RefreshControls()
end
function C:SetComponent(key)
    if COMPONENT_LABEL[key] == nil then return false, "未知 HUD 组件" end
    self.component = key
    if type(self.Diagnostics) == "table" then self.Diagnostics.lastComponent = key end
    Trace("component_changed", { component=key, clearError=true })
    return self:RefreshControls()
end
function C:SyncPlayerToTarget()
    if type(self.draft) ~= "table" or type(self.draft.player) ~= "table" then
        Trace("sync_failed", { error="自身 HUD 草稿不存在" })
        return false, "自身 HUD 草稿不存在"
    end
    self.draft.target = Copy(self.draft.player)
    self.scope = "target"; self.dirty = true
    self.Diagnostics.syncCount = (tonumber(self.Diagnostics.syncCount) or 0) + 1
    Trace("sync_player_to_target", { clearError=true })
    SafeText(self.statusLabel, "已复制 自身 → 目标（尚未保存）")
    return self:RefreshControls()
end
function C:ResetCurrentComponent()
    local defaults = Feature.Commands:GetDefaultHudCalibrationSnapshot()
    local defaultProfile = type(defaults) == "table" and defaults[self.scope] or nil
    if type(defaultProfile) ~= "table" then
        Trace("reset_component_failed", { error="默认 HUD 配置不可用" })
        return false, "默认 HUD 配置不可用"
    end
    local profile = Profile()
    if self.component == "plate" then
        profile.plate = Copy(defaultProfile.plate or {})
    elseif self.component == "info" then
        profile.info = Copy(defaultProfile.info or {})
        -- 基础信息的三个可见性子项属于同一编辑区域，恢复组件时一起恢复，避免 UI 显示与旧
        -- showClass/showGear/showDistance 双字段再次出现不一致。
        for _, key in ipairs({"class","gearScore","distance"}) do
            profile.components[key] = Copy((defaultProfile.components or {})[key] or {})
        end
    else
        profile.components[self.component] = Copy((defaultProfile.components or {})[self.component] or {})
    end
    self.dirty = true
    self.Diagnostics.resetCount = (tonumber(self.Diagnostics.resetCount) or 0) + 1
    Trace("reset_component", { clearError=true })
    SafeText(self.statusLabel, tostring(COMPONENT_LABEL[self.component] or self.component) .. " 已恢复默认（尚未保存）")
    return self:RefreshControls()
end

function C:ResetCurrentScope()
    local defaults = Feature.Commands:GetDefaultHudCalibrationSnapshot()
    if type(defaults) ~= "table" or type(defaults[self.scope]) ~= "table" then
        Trace("reset_failed", { error="默认 HUD 配置不可用" })
        return false, "默认 HUD 配置不可用"
    end
    self.draft[self.scope] = Copy(defaults[self.scope]); self.dirty = true
    self.Diagnostics.resetCount = (tonumber(self.Diagnostics.resetCount) or 0) + 1
    Trace("reset_scope", { clearError=true })
    SafeText(self.statusLabel, ScopeName(self.scope) .. " 已恢复默认（尚未保存）")
    return self:RefreshControls()
end

local function RestoreShell()
    local shell, state = S.UIV3 and S.UIV3.Shell or nil, S.UIV3 and S.UIV3.ShellState or nil
    if shell == nil or state == nil then return true end
    local previous = type(C.previousShell) == "table" and C.previousShell or { minimized=false }
    state.minimized = previous.minimized == true
    if previous.minimized == true then
        if type(shell.ApplyMinimizedState) == "function" then return shell:ApplyMinimizedState(false) end
        return true
    end
    if type(shell.Open) == "function" then return shell:Open() end
    if type(shell.ApplyMinimizedState) == "function" then return shell:ApplyMinimizedState(false) end
    return true
end

function C:HideOverlay()
    self.visible = false
    SafeVisible(self.panel, false); SafeVisible(self.preview.root, false)
    for _, item in pairs(type(self.globalPreview) == "table" and type(self.globalPreview.items) == "table" and self.globalPreview.items or {}) do SafeVisible(item.root, false) end
    for _, edit in pairs(self.inputs) do
        if type(S.UI.DeactivateInputWidget) == "function" then pcall(function() S.UI:DeactivateInputWidget(edit, self.owner, "hud_calibration_close") end) end
    end
    self.dragging = false
    self.panelDragging = false
    return true
end

function C:Exit(save)
    -- 中文维护注释（保存/退出诊断边界）：Save 失败时校准器必须保持打开，方便用户修复存档后
    -- 再次保存；只有持久化成功或明确取消后才隐藏 Overlay。Shell 恢复失败与 Store 保存失败分开
    -- 计数，避免摘要把“配置没写入”和“主菜单没回来”混成同一故障。
    if save == true then
        local canWrite, writeErr = Feature.Commands:CanPersistLayoutSettings()
        if canWrite ~= true then
            self.Diagnostics.saveFailures = (tonumber(self.Diagnostics.saveFailures) or 0) + 1
            Trace("save_blocked", { error=tostring(writeErr or "存档不可写") })
            SafeText(self.statusLabel, "保存失败：" .. tostring(writeErr or "存档不可写")); return false, writeErr
        end
        local ok, err = Feature.Commands:PersistHudCalibrationSnapshot(self.draft, "hud_calibration_save_exit")
        if ok ~= true then
            self.Diagnostics.saveFailures = (tonumber(self.Diagnostics.saveFailures) or 0) + 1
            Trace("save_failed", { error=tostring(err or "未知错误") })
            SafeText(self.statusLabel, "保存失败：" .. tostring(err or "未知错误")); return false, err
        end
        self.Diagnostics.saveCount = (tonumber(self.Diagnostics.saveCount) or 0) + 1
        Trace("save_committed", { clearError=true })
    else
        self.Diagnostics.cancelCount = (tonumber(self.Diagnostics.cancelCount) or 0) + 1
        Trace("cancel_exit", { clearError=true })
    end
    self:HideOverlay()
    local hudRestored, hudRestoreErr = SetLiveHudSuppressed(false, "hud_calibration_exit")
    if hudRestored ~= true then
        Trace("live_hud_restore_failed", { error=tostring(hudRestoreErr or "正式 HUD 恢复失败"), liveHudSuppressed=true })
    else
        Trace("live_hud_restored", { clearError=true, liveHudSuppressed=false })
    end
    local restored, restoreErr = RestoreShell()
    if restored == false then
        self.Diagnostics.shellRestoreFailures = (tonumber(self.Diagnostics.shellRestoreFailures) or 0) + 1
        Trace("shell_restore_failed", { error=tostring(restoreErr or "主菜单恢复失败"), shellRestored=false })
    else
        Trace("shell_restored", { clearError=true, shellRestored=true })
    end
    local exitCallback = self.exitCallback
    self.draft, self.previousShell, self.exitCallback, self.dirty = nil, nil, nil, false
    self.Diagnostics.dirty = false; self.Diagnostics.visible = false
    -- Callback runs only after the Shell is restored so the page may safely
    -- refresh its persisted summary; callback failure must not re-open editor state.
    if type(exitCallback) == "function" then
        pcall(exitCallback, save == true, restored ~= false, restoreErr)
    end
    return restored ~= false, restoreErr
end

function C:EnsureCreated()
    if self.panel ~= nil and self.preview.root ~= nil then
        return EnsureGlobalPreviewWidgets()
    end
    if UIParent == nil then return false, "UIParent 不可用" end
    -- 中文维护注释（校准 UI 生命周期）：ArcheRage RU 没有经过验证的通用 DestroyWidget，
    -- 因此首次创建后采用“隐藏 + 失焦 + 无 Scheduler/无 Consumer”的静默复用策略；退出时
    -- 不保留任何高频逻辑或事件订阅。直接尝试销毁 Native Widget 反而有悬空回调风险。
    local PANEL_W, PANEL_H = 420, 640
    local panel, panelErr = S.UI:CreateEmptyWidget(UIParent, "v3_buff_hud_calibration_panel", 18, 70, PANEL_W, PANEL_H, true, self.owner)
    if panel == nil then return false, panelErr or "校准面板创建失败" end
    self.panel = panel; panel.rsUiOwner = self.owner
    self.panelBg = MakeFill(panel, "background", 0.015,0.025,0.035,0.96)

    -- 中文维护注释（校准控制面板拖动）：旧实现只有 HUD 预览框可拖，控制面板自身固定在
    -- 左侧；低分辨率或与技能栏/聊天重叠时用户无法挪开。这里使用独立标题栏 handle 接手
    -- DragStart/DragStop，真正 StartMoving 的仍是 panel。Authority 只是瞬时 Native geometry，
    -- 不写入 BuffDisplay Store。DragStop 统一 clamp 到逻辑屏幕并记录 bounded diagnostics。
    self.panelDragHandle = S.UI:CreateEmptyWidget(panel, "v3_buff_hud_calibration_panel_drag_handle", 0, 0, PANEL_W, 32, true, self.owner)
    self.title = S.UI:CreateLabel(panel, "v3_buff_hud_calibration_title", "状态显示 · HUD 校准", 12, 8, 220, 22, 13, "strong", "LEFT", true)
    self.dragHint = S.UI:CreateLabel(panel, "v3_buff_hud_calibration_drag_hint", "拖动标题栏移动", 280, 10, 128, 18, 9, "muted", "RIGHT", true)
    self.scopeLabel = S.UI:CreateLabel(panel, "v3_buff_hud_calibration_scope_label", "", 12, 36, 180, 18, 10, "default", "LEFT", false)
    self.dirtyLabel = S.UI:CreateLabel(panel, "v3_buff_hud_calibration_dirty", "已同步到存档", 250, 36, 158, 18, 9, "muted", "RIGHT", false)
    self.playerButton = MakeButton(panel, "v3_buff_hud_calibration_player", "自己 HUD", 12, 56, 84, 26, function() return C:SetScope("player") end)
    self.targetButton = MakeButton(panel, "v3_buff_hud_calibration_target", "目标 HUD", 100, 56, 84, 26, function() return C:SetScope("target") end)
    self.syncButton = MakeButton(panel, "v3_buff_hud_calibration_sync", "复制自身 → 目标", 190, 56, 132, 26, function() return C:SyncPlayerToTarget() end)
    self.globalPreviewButton = MakeButton(panel, "v3_buff_hud_calibration_global_preview", "全局：开", 326, 56, 82, 26, function() return C:ToggleGlobalPreview() end)

    self.componentLabel = S.UI:CreateLabel(panel, "v3_buff_hud_calibration_component_label", "", 12, 90, 100, 18, 10, "strong", "LEFT", false)
    local cy = 112
    for _, row in ipairs(COMPONENTS) do
        local key = row.key
        local button = MakeButton(panel, "v3_buff_hud_calibration_component_" .. key, row.label, 12, cy, 96, 25, function() return C:SetComponent(key) end)
        self.controls["component_" .. key] = button; cy = cy + 28
    end

    local rx = 126
    S.UI:CreateLabel(panel, "v3_buff_hud_calibration_position", "位置微调（↑永远向屏幕上）", rx, 90, 220, 18, 10, "strong", "LEFT", false)
    MakeButton(panel, "v3_buff_hud_calibration_up", "↑", rx+42, 112, 42, 26, function() return C:Nudge(0,-1) end)
    MakeButton(panel, "v3_buff_hud_calibration_left", "←", rx, 141, 42, 26, function() return C:Nudge(-1,0) end)
    MakeButton(panel, "v3_buff_hud_calibration_right", "→", rx+84, 141, 42, 26, function() return C:Nudge(1,0) end)
    MakeButton(panel, "v3_buff_hud_calibration_down", "↓", rx+42, 170, 42, 26, function() return C:Nudge(0,1) end)
    S.UI:CreateLabel(panel, "v3_buff_hud_calibration_step_label", "步长", rx+146, 112, 70, 18, 9, "muted", "LEFT", false)
    self.stepButtons = {}
    self.stepButtons[1] = MakeButton(panel, "v3_buff_hud_calibration_step_1", "1", rx+146, 134, 34, 24, function() return C:SetStep(1) end)
    self.stepButtons[5] = MakeButton(panel, "v3_buff_hud_calibration_step_5", "5", rx+183, 134, 34, 24, function() return C:SetStep(5) end)
    self.stepButtons[10] = MakeButton(panel, "v3_buff_hud_calibration_step_10", "10", rx+220, 134, 38, 24, function() return C:SetStep(10) end)

    self.fieldRows = {}
    local function Field(name, label)
        local labelWidget = S.UI:CreateLabel(panel, "v3_buff_hud_calibration_label_"..name, label, rx, 214, 52, 18, 9, "muted", "LEFT", false)
        local edit = MakeInput(panel, "v3_buff_hud_calibration_input_"..name, rx+55, 210, 72, 24)
        self.inputs[name] = edit
        local minus = MakeButton(panel, "v3_buff_hud_calibration_minus_"..name, "-", rx+132, 210, 28, 24, function()
            local delta = (name == "scale" or name == "alpha") and -0.05 or -1; return C:Adjust(name, delta)
        end)
        local plus = MakeButton(panel, "v3_buff_hud_calibration_plus_"..name, "+", rx+163, 210, 28, 24, function()
            local delta = (name == "scale" or name == "alpha") and 0.05 or 1; return C:Adjust(name, delta)
        end)
        self.fieldRows[name] = { label=labelWidget, edit=edit, minus=minus, plus=plus }
    end
    Field("x","X"); Field("y","Y"); Field("size","尺寸"); Field("font","字号")
    Field("spacing","间距"); Field("perRow","每行"); Field("rows","行数")
    Field("width","宽度"); Field("scale","缩放"); Field("alpha","透明")
    self.enabledButton = MakeButton(panel, "v3_buff_hud_calibration_enabled", "显示：开", rx, 458, 88, 28, function()
        if C.component == "plate" then return true end
        return SetCurrentEnabled(not CurrentEnabled())
    end)
    MakeButton(panel, "v3_buff_hud_calibration_apply_inputs", "应用输入值", rx+94, 458, 112, 28, function() return C:ApplyInputFields() end)
    self.auxButtons = self.auxButtons or {}
    for i = 1, 3 do
        local index = i
        self.auxButtons[i] = MakeButton(panel, "v3_buff_hud_calibration_aux_"..tostring(i), "", rx + (i-1)*72, 490, 68, 26, function() return C:ToggleAux(index) end)
    end
    self.anchorHint = S.UI:CreateLabel(panel, "v3_buff_hud_calibration_anchor_hint", "", rx, 522, 276, 18, 9, "muted", "LEFT", false)
    self.statusLabel = S.UI:CreateLabel(panel, "v3_buff_hud_calibration_status", "拖动预览框或使用按钮微调", 12, 544, 396, 18, 9, "muted", "LEFT", false)
    MakeButton(panel, "v3_buff_hud_calibration_default_component", "恢复当前组件", 12, 568, 116, 26, function() return C:ResetCurrentComponent() end)
    MakeButton(panel, "v3_buff_hud_calibration_default", "恢复当前 HUD", 134, 568, 116, 26, function() return C:ResetCurrentScope() end)
    -- 中文维护注释（模板输出入口）：此按钮只读取当前 Draft 并分行输出 HUD_TEMPLATE_V1，
    -- 不触发 Save、不退出校准，也不改变自己/目标 HUD。用户可以在最终微调完成但尚未保存时
    -- 先复制模板给维护者，避免“为记录模板而额外改变存档”的隐性副作用。
    MakeButton(panel, "v3_buff_hud_calibration_template", "输出模板快照", 256, 568, 152, 26, function() return C:OutputTemplateSnapshot() end)
    MakeButton(panel, "v3_buff_hud_calibration_cancel", "取消并退出", 12, 602, 148, 28, function() return C:Exit(false) end)
    MakeButton(panel, "v3_buff_hud_calibration_save", "保存并退出", 166, 602, 156, 28, function() return C:Exit(true) end)

    if type(S.UI.EnsurePickable) ~= "function" or type(S.UI.TryInteractionCall) ~= "function" or type(S.UI.RequireHandler) ~= "function" then
        return false, "HUD 校准拖动交互契约不可用"
    end
    if self.panelDragHandle == nil then return false, "HUD 校准标题拖动区创建失败" end
    if type(S.UI.EnsureEnabled) == "function" then
        local panelEnabled = S.UI:EnsureEnabled(self.panelDragHandle, true, self.owner)
        if panelEnabled ~= true then return false, "HUD 校准标题拖动区未启用" end
    end
    local panelPick = S.UI:EnsurePickable(self.panelDragHandle, true, self.owner)
    if panelPick ~= true then return false, "HUD 校准标题拖动区不可点击" end
    local panelDragEnabled, panelDragErr = S.UI:TryInteractionCall(self.panelDragHandle, "EnableDrag", true)
    if panelDragEnabled ~= true then return false, "HUD 校准面板拖动启用失败："..tostring(panelDragErr or "rejected") end
    if type(self.panelDragHandle.SetDragCondition)=="function" and DC_ALWAYS ~= nil then
        local okCondition, conditionErr = S.UI:TryInteractionCall(self.panelDragHandle, "SetDragCondition", DC_ALWAYS)
        if okCondition ~= true then return false, "HUD 校准面板拖动条件失败："..tostring(conditionErr or "rejected") end
    end
    local panelStartOk, panelStartErr = S.UI:RequireHandler(self.panelDragHandle, "OnDragStart", function()
        if C.visible ~= true then return false end
        if type(S.UI.BeginNativeGeometryLease)=="function" and S.UI:BeginNativeGeometryLease(panel,C.owner,"buff_hud_calibration_panel_drag") ~= true then
            C.Diagnostics.panelDragFailures = (tonumber(C.Diagnostics.panelDragFailures) or 0) + 1
            Trace("panel_drag_lease_failed", { error="geometry_lease_rejected" }); return false
        end
        local moving = S.UI:TryInteractionCall(panel, "StartMoving")
        if moving ~= true then
            if type(S.UI.EndNativeGeometryLease)=="function" then S.UI:EndNativeGeometryLease(panel,C.owner) end
            C.Diagnostics.panelDragFailures = (tonumber(C.Diagnostics.panelDragFailures) or 0) + 1
            Trace("panel_drag_start_failed", { error="start_moving_rejected" }); return false
        end
        C.panelDragging = true
        return true
    end, "buff_hud_calibration:panel_drag_start")
    local panelStopOk, panelStopErr = S.UI:RequireHandler(self.panelDragHandle, "OnDragStop", function()
        if C.panelDragging ~= true then return false end
        if type(panel.StopMovingOrSizing)=="function" then pcall(function() panel:StopMovingOrSizing() end) end
        if type(S.UI.EndNativeGeometryLease)=="function" then S.UI:EndNativeGeometryLease(panel,C.owner) end
        C.panelDragging = false
        local x,y = nil,nil
        if S.Layout ~= nil and type(S.Layout.GetLogicalRect)=="function" then x,y = S.Layout:GetLogicalRect(panel) end
        if tonumber(x)==nil or tonumber(y)==nil then
            C.Diagnostics.panelDragFailures = (tonumber(C.Diagnostics.panelDragFailures) or 0) + 1
            Trace("panel_drag_stop_failed", { error="logical_rect_unavailable" }); return false
        end
        local sw,sh = ScreenSize()
        local clampedX = math.max(2, math.min(math.max(2, sw-PANEL_W-2), tonumber(x)))
        local clampedY = math.max(2, math.min(math.max(2, sh-PANEL_H-2), tonumber(y)))
        S.UI:SetAnchor(panel, UIParent, clampedX, clampedY, C.owner)
        C.panelRect = { x=clampedX, y=clampedY, width=PANEL_W, height=PANEL_H }
        C.Diagnostics.panelDragCount = (tonumber(C.Diagnostics.panelDragCount) or 0) + 1
        C.Diagnostics.panelX, C.Diagnostics.panelY = Round(clampedX), Round(clampedY)
        Trace("panel_drag_commit", { panelX=Round(clampedX), panelY=Round(clampedY), clearError=true })
        return true
    end, "buff_hud_calibration:panel_drag_stop")
    if panelStartOk ~= true or panelStopOk ~= true then return false, tostring(panelStartErr or panelStopErr or "HUD 校准面板拖动绑定失败") end

    local preview, previewErr = S.UI:CreateEmptyWidget(UIParent, "v3_buff_hud_calibration_preview", 0, 0, 120, 40, true, self.owner)
    if preview == nil then return false, previewErr or "HUD 校准预览框创建失败" end
    self.preview.root = preview; preview.rsUiOwner = self.owner
    self.preview.bg = MakeFill(preview, "background", 0.08,0.36,0.55,0.18)
    self.preview.caption = S.UI:CreateLabel(preview, "v3_buff_hud_calibration_preview_caption", "", 0, -18, 220, 16, 9, "strong", "LEFT", true)
    self.preview.infoLabel = S.UI:CreateLabel(preview, "v3_buff_hud_calibration_preview_info", "职业预览 · 12345 · 28.4m", 0, 0, 220, 18, 12, "strong", "CENTER", true)
    self.preview.castBg = preview.CreateColorDrawable and preview:CreateColorDrawable(0.10,0.10,0.12,0.90,"overlay") or nil
    self.preview.castFill = preview.CreateColorDrawable and preview:CreateColorDrawable(0.96,0.72,0.12,0.95,"overlay") or nil
    self.preview.castText = S.UI:CreateLabel(preview, "v3_buff_hud_calibration_preview_cast_text", "施法预览", 0, 8, 120, 15, 10, "default", "CENTER", true)
    for i=1,4 do
        local iconRoot = S.UI:CreateEmptyWidget(preview, "v3_buff_hud_calibration_preview_icon_"..tostring(i), 0,0,29,29,false,self.owner)
        local texture = iconRoot and iconRoot.CreateIconDrawable and iconRoot:CreateIconDrawable("artwork") or nil
        local time = iconRoot and S.UI:CreateLabel(iconRoot, "v3_buff_hud_calibration_preview_time_"..tostring(i), "", 0,16,29,13,8,"strong","RIGHT",true) or nil
        self.preview.icons[i] = { root=iconRoot, texture=texture, time=time }
    end
    local globalOk, globalErr = EnsureGlobalPreviewWidgets()
    if globalOk ~= true then return false, globalErr end
    if type(S.UI.EnsurePickable) ~= "function" or type(S.UI.TryInteractionCall) ~= "function" or type(S.UI.RequireHandler) ~= "function" then
        return false, "HUD 校准拖动交互契约不可用"
    end
    local pickOk = S.UI:EnsurePickable(preview, true, self.owner)
    if pickOk ~= true then return false, "HUD 校准预览不可点击" end
    local dragOk, dragErr = S.UI:TryInteractionCall(preview, "EnableDrag", true)
    if dragOk ~= true then return false, "HUD 校准拖动启用失败："..tostring(dragErr or "rejected") end
    if type(preview.SetDragCondition)=="function" and DC_ALWAYS ~= nil then
        local conditionOk, conditionErr = S.UI:TryInteractionCall(preview, "SetDragCondition", DC_ALWAYS)
        if conditionOk ~= true then return false, "HUD 校准拖动条件失败："..tostring(conditionErr or "rejected") end
    end
    local startOk, startErr = S.UI:RequireHandler(preview, "OnDragStart", function()
        if C.visible ~= true then return false end
        if type(S.UI.BeginNativeGeometryLease)=="function" and S.UI:BeginNativeGeometryLease(preview,C.owner,"buff_hud_calibration_drag") ~= true then
            C.Diagnostics.dragFailures = (tonumber(C.Diagnostics.dragFailures) or 0) + 1
            Trace("drag_lease_failed", { error="geometry_lease_rejected" })
            return false
        end
        local moving = S.UI:TryInteractionCall(preview,"StartMoving")
        if moving ~= true then
            if type(S.UI.EndNativeGeometryLease)=="function" then S.UI:EndNativeGeometryLease(preview,C.owner) end
            C.Diagnostics.dragFailures = (tonumber(C.Diagnostics.dragFailures) or 0) + 1
            Trace("drag_start_failed", { error="start_moving_rejected" })
            return false
        end
        C.dragging=true; C.dragStartRect=Copy(C.preview.expectedRect); return true
    end, "buff_hud_calibration:preview_drag_start")
    local stopOk, stopErr = S.UI:RequireHandler(preview, "OnDragStop", function()
        if C.dragging ~= true then return false end
        if type(preview.StopMovingOrSizing)=="function" then pcall(function() preview:StopMovingOrSizing() end) end
        if type(S.UI.EndNativeGeometryLease)=="function" then S.UI:EndNativeGeometryLease(preview,C.owner) end
        C.dragging=false
        local x,y = nil,nil
        if S.Layout ~= nil and type(S.Layout.GetLogicalRect)=="function" then x,y = S.Layout:GetLogicalRect(preview) end
        local before = type(C.dragStartRect)=="table" and C.dragStartRect or C.preview.expectedRect
        if tonumber(x) ~= nil and tonumber(y) ~= nil and type(before)=="table" then
            local dx,dy = tonumber(x)-N(before.x,0), tonumber(y)-N(before.y,0)
            local profile,key = Profile(),C.component; local scale=N(profile.plateScale,1)
            local fields=CurrentFields()
            local component = Component(); local beforeStoredY = N(component.y,0)
            local logicalDy = dy/math.max(0.01,scale)
            if key=="buffs" or key=="debuffs" or key=="info" then
                ApplyField("x", fields.x + dx); ApplyField("y", fields.y + logicalDy)
            else
                ApplyField("x", fields.x + dx/math.max(0.01,scale)); ApplyField("y", fields.y + logicalDy)
            end
            local storedDy = N(component.y,0)-beforeStoredY
            C.dirty=true
            C.Diagnostics.dragCommitCount = (tonumber(C.Diagnostics.dragCommitCount) or 0) + 1
            C.Diagnostics.lastScreenDy, C.Diagnostics.lastLogicalDy, C.Diagnostics.lastStoredDy = Round(dy), logicalDy, storedDy
            C.Diagnostics.yAdapter = YAdapterName(key)
            Trace("drag_commit", { dx=Round(dx), screenDy=Round(dy), logicalDy=logicalDy, storedDy=storedDy, yAdapter=YAdapterName(key), clearError=true })
        else
            C.Diagnostics.dragFailures = (tonumber(C.Diagnostics.dragFailures) or 0) + 1
            Trace("drag_stop_failed", { error="logical_rect_unavailable" })
        end
        return C:RefreshControls()
    end, "buff_hud_calibration:preview_drag_stop")
    if startOk ~= true or stopOk ~= true then return false, tostring(startErr or stopErr or "HUD 校准拖动绑定失败") end
    self:HideOverlay()
    return true
end

function C:Open(context)
    if self.visible == true then
        SetLiveHudSuppressed(true, "hud_calibration_reopen")
        return self:RefreshControls()
    end
    self.Diagnostics.openCount = (tonumber(self.Diagnostics.openCount) or 0) + 1
    if type(Feature.EnsureStoreLoaded)=="function" then
        local loaded, loadErr = Feature:EnsureStoreLoaded()
        if loaded ~= true then
            self.Diagnostics.openFailures = (tonumber(self.Diagnostics.openFailures) or 0) + 1
            Trace("open_store_failed", { error=tostring(loadErr or "状态显示配置读取失败") })
            return false, loadErr or "状态显示配置读取失败"
        end
    end
    local created, createErr = self:EnsureCreated()
    if created ~= true then
        self.Diagnostics.openFailures = (tonumber(self.Diagnostics.openFailures) or 0) + 1
        Trace("open_create_failed", { error=tostring(createErr or "校准 UI 创建失败") })
        return false, createErr
    end
    local snapshot = Feature.Commands:GetHudCalibrationSnapshot()
    if type(snapshot)~="table" or type(snapshot.player)~="table" or type(snapshot.target)~="table" then
        self.Diagnostics.openFailures = (tonumber(self.Diagnostics.openFailures) or 0) + 1
        Trace("open_snapshot_failed", { error="HUD 双配置快照不可用" })
        return false,"HUD 双配置快照不可用"
    end
    self.draft=Copy(snapshot); self.scope=type(context)=="table" and context.scope=="target" and "target" or "player"; self.component="buffs"; self.step=1; self.dirty=false
    self.globalPreviewEnabled = true
    self.Diagnostics.globalPreviewEnabled = true
    self.exitCallback = type(context) == "table" and context.onExit or nil
    local suppressed, suppressErr = SetLiveHudSuppressed(true, "hud_calibration_open")
    if suppressed ~= true then
        self.Diagnostics.openFailures = (tonumber(self.Diagnostics.openFailures) or 0) + 1
        Trace("open_live_hud_suppress_failed", { error=tostring(suppressErr or "正式 HUD 隐藏失败"), liveHudSuppressed=false })
        self.draft, self.exitCallback = nil, nil
        return false, suppressErr or "正式 HUD 隐藏失败"
    end
    Trace("live_hud_suppressed", { clearError=true, liveHudSuppressed=true, globalPreview=true })
    local shell,state=S.UIV3 and S.UIV3.Shell or nil,S.UIV3 and S.UIV3.ShellState or nil
    if shell~=nil and state~=nil then
        self.previousShell={minimized=state.minimized==true}
        self.Diagnostics.shellWasMinimized = self.previousShell.minimized == true
        state.minimized=true
        if type(shell.ApplyMinimizedState)=="function" then
            local minimized,minErr=shell:ApplyMinimizedState(false)
            if minimized~=true then
                state.minimized=self.previousShell.minimized
                self.Diagnostics.openFailures = (tonumber(self.Diagnostics.openFailures) or 0) + 1
                self.Diagnostics.shellMinimizeFailures = (tonumber(self.Diagnostics.shellMinimizeFailures) or 0) + 1
                SetLiveHudSuppressed(false, "hud_calibration_open_rollback")
                Trace("open_shell_minimize_failed", { error=tostring(minErr or "主菜单临时最小化失败"), shellWasMinimized=self.previousShell.minimized, liveHudSuppressed=false })
                return false,minErr or "主菜单临时最小化失败"
            end
        end
    end
    self.visible=true; SafeVisible(self.panel,true); SafeVisible(self.preview.root,true)
    if type(self.panelRect)=="table" then
        local sw,sh=ScreenSize(); local pw,ph=N(self.panelRect.width,420),N(self.panelRect.height,640)
        local px=math.max(2,math.min(math.max(2,sw-pw-2),N(self.panelRect.x,18)))
        local py=math.max(2,math.min(math.max(2,sh-ph-2),N(self.panelRect.y,70)))
        S.UI:SetAnchor(self.panel,UIParent,px,py,self.owner)
        self.Diagnostics.panelX,self.Diagnostics.panelY=Round(px),Round(py)
    end
    self.Diagnostics.visible = true; self.Diagnostics.dirty = false
    Trace("open", { clearError=true, shellWasMinimized=self.previousShell and self.previousShell.minimized == true or false, liveHudSuppressed=true, globalPreview=true })
    SafeText(self.statusLabel,"全局预览已开启 · 正式 HUD 已隐藏 · 拖动预览框移动当前组件")
    if type(self.preview.root.Raise)=="function" then pcall(self.preview.root.Raise,self.preview.root) end
    if type(self.panel.Raise)=="function" then pcall(self.panel.Raise,self.panel) end
    return self:RefreshControls()
end

function C:IsOpen() return self.visible == true end
function C:GetDraftSnapshot() return Copy(self.draft) end

-- Presentation contract: no feature enable is required to edit layout, and no
-- transient calibration state is persisted until Save & Exit.
Feature.HudCalibrationPresentationContractVersion = 5 -- 中文维护注释：v5 在 v4 全局预览/正式 HUD suppression 基础上新增 HUD_TEMPLATE_V1 Draft 快照输出；仍不新增 Scheduler/Consumer，模板输出不写 Store。
