------------------------------------------------------------------------
-- Replicated Suite · 提示菜单与焦点服务
-- 作者：Replicated
-- QQ群：1104129461
--
-- UMG 风格 RSUI 交互层，此处扩展服务，不再添加另一批控件。
-- 已确认 RU API：Suite 验证的 OnEnter/OnLeave/OnClick；客户端导出时的全局 SetTooltip(text, widget)；
-- Button/Edit SetFocus()、Edit ClearFocus()；焦点getter在RU清单中not allowed，不能调用。
-- 不假设通用 OnKeyDown/OnKeyUp、可靠全局右键或指针 delta API；ContextMenu 由明确调用或调用方选定的已验证事件打开，键盘导航能力报告 false。
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local UI, RSUI = S.UI, S.RSUI
if type(UI) ~= "table" or type(RSUI) ~= "table" then return end
local Tokens = S.UITokens or {}
RSUI.InteractionServiceContractVersion = 4
RSUI.InteractionPopupCoordinateConsumerContractVersion = 2 -- 目标型 Tooltip/ContextMenu 与 Dropdown 同样优先使用原生 Trigger 相对锚；仅鼠标/显式屏幕点走 point 路径。
RSUI.InteractionPopupCoordinateConsumerLane = "popup-native-relative-v1" -- Interactions 的目标型 detached Popup 显式登记 Native-relative lane；显式鼠标/屏幕点仍在函数内单独标记 popup-point-v1。
RSUI.InteractionPopupVisibilityContractVersion = 1

local function Token(path, fallback)
    if type(Tokens.Number) == "function" then return Tokens:Number(path, fallback) end
    return tonumber(fallback) or 0
end

local function N(v, fallback)
    v = tonumber(v)
    if v == nil then return tonumber(fallback) or 0 end
    return v
end
local function Clamp(v, a, b)
    v, a, b = N(v, a), N(a, 0), N(b, a)
    if v < a then return a end
    if v > b then return b end
    return v
end
local function ResolveNative(target)
    if RSUI:IsComponent(target) then return target:GetRoot(), target end
    if type(target) == "table" then return target, nil end
    return nil, nil
end
local function EnsureVisible(widget, visible, owner)
    if widget == nil then return false, "popup_widget_required" end
    if type(UI.EnsureVisible) ~= "function" then return false, "visibility_transaction_unavailable" end
    local accepted, _, detail = UI:EnsureVisible(widget, visible == true, owner)
    if accepted ~= true then return false, tostring(detail or "native_visibility_rejected") end
    return true, nil
end
local function UiMetrics()
    if S.Api ~= nil and type(S.Api.GetUiMetrics) == "function" then
        local ok, _, _, _, w, h = pcall(function() return S.Api:GetUiMetrics() end)
        if ok and tonumber(w) and tonumber(h) then return tonumber(w), tonumber(h) end
    end
    return 1024, 768
end
local function AnchorRect(target)
    local positioning = RSUI.PopupPositioning
    if type(positioning) == "table" and type(positioning.ResolveAnchorRect) == "function" then
        local rect = positioning:ResolveAnchorRect(target)
        if type(rect) == "table" then return rect.x, rect.y, rect.width, rect.height, rect end
    end
    return 0, 0, 1, 1, nil
end

------------------------------------------------------------------------
-- PointerService 指针服务。
--
-- 仅事件驱动采样；RU 证据提供绝对鼠标位置，未验证通用指针捕获，Native StartMoving/StartSizing 保持捕获权威。
------------------------------------------------------------------------
local Pointer = {
    version = 1,
    captureSupported = false,
    samples = 0,
    failures = 0,
}
RSUI.Pointer = Pointer
RSUI.PointerContractVersion = 1

function Pointer:GetLogicalPosition()
    if S.Api == nil or type(S.Api.GetMouseLogicalPosition) ~= "function" then
        self.failures = self.failures + 1
        return nil, nil, "pointer_position_unavailable"
    end
    local ok, x, y, err = pcall(function() return S.Api:GetMouseLogicalPosition() end)
    if ok ~= true or tonumber(x) == nil or tonumber(y) == nil then
        self.failures = self.failures + 1
        -- 回退最近有效样本；活动池行可自由重锚，行矩形可能远离光标，前次光标位置更可靠。
        if self.lastX ~= nil and self.lastY ~= nil then
            return self.lastX, self.lastY, nil
        end
        return nil, nil, tostring(err or "pointer_position_unavailable")
    end
    self.lastX, self.lastY = tonumber(x), tonumber(y)
    self.samples = self.samples + 1
    return tonumber(x), tonumber(y), nil
end

function Pointer:Delta(startX, startY, currentX, currentY)
    startX, startY = tonumber(startX), tonumber(startY)
    currentX, currentY = tonumber(currentX), tonumber(currentY)
    if startX == nil or startY == nil or currentX == nil or currentY == nil then
        return nil, nil, "pointer_delta_coordinates_required"
    end
    return currentX - startX, currentY - startY, nil
end

function Pointer:GetCapabilities()
    local coordinate = S.Layout and type(S.Layout.GetCoordinateSystemSnapshot) == "function" and S.Layout:GetCoordinateSystemSnapshot() or nil
    return {
        version = self.version,
        contractVersion = tonumber(RSUI.PointerContractVersion) or 0,
        absolutePosition = S.Api ~= nil and type(S.Api.GetMouseLogicalPosition) == "function",
        genericCapture = self.captureSupported == true,
        nativeMoveSizingAuthority = true,
        samples = tonumber(self.samples) or 0,
        failures = tonumber(self.failures) or 0,
        coordinateSystem = coordinate,
    }
end

local function PointerPosition()
    local x, y = Pointer:GetLogicalPosition()
    if x ~= nil and y ~= nil then return x, y, "mouse" end
    return nil, nil, "target"
end

local function Callback(label, fn, ...)
    if type(fn) ~= "function" then return true, nil end
    if type(RSUI.Callback) == "function" then return RSUI:Callback(label, fn, ...) end
    local args, argc = { ... }, select("#", ...)
    local ok, result = xpcall(function() return fn(unpack(args, 1, argc)) end, S.SafeTraceback)
    return ok, result
end

------------------------------------------------------------------------
-- TooltipService 提示服务。
--
-- 当前 RU 导出 Native SetTooltip 时优先使用，由客户端负责安全光标位置和关闭；否则使用统一 RSUI 提示池，绑定/位置仅事件驱动。
------------------------------------------------------------------------
local Tooltip = {
    version = 6,
    -- 提示池根须为 system 层实际临时 WINDOW，带 popup 绘制优先级；emptywidget 不能可靠越过背包/仓库等原生窗口，遵循已验证 ContextMenu 策略。
    TransientLayerContractVersion = 1,
    -- 提示池高度不小于可靠字形估计，避免测量缺失或与 Native LABEL 不一致时裁切提示（RU 背包快捷提示证据 .18.183）。
    LineEstimateContractVersion = 1,
    -- 周期表现窗口须能查询提示是否打开；每 350ms 重新 Raise 会在一秒内把用户提示压回游戏窗口下方。
    IsShowingContractVersion = 1,
    bindings = setmetatable({}, { __mode = "k" }),
    fallback = nil,
    owner = "rsui:tooltip_service",
}
RSUI.Tooltip = Tooltip

local function ResolveTooltipText(binding, component)
    local value = binding and binding.text
    if type(value) == "function" then
        local ok, result = Callback("rsui:tooltip_provider", value, component)
        if ok then value = result else value = nil end
    end
    if value == nil and binding ~= nil and type(binding.provider) == "function" then
        local ok, result = Callback("rsui:tooltip_provider", binding.provider, component)
        if ok then value = result end
    end
    return tostring(value or "")
end

-- RSUI.TextLayout 为测量权威，但可能在 RU 不可用或低估 Native LABEL 自行换行高度；此估计仅作下限，按中文全宽字形保守计算，只增高提示框，不裁切。
function Tooltip:EstimateWrappedLines(text, contentWidth, fontSize)
    -- 按宽度单位计算：ASCII 字节约为 CJK 字形的 0.6；迭代器把多字节序列作为一个字形，单字节分支仅处理 1..127。
    local units = 0
    for glyph in string.gmatch(tostring(text or ""), "[\1-\127\192-\244][\128-\191]*") do
        if #glyph == 1 then units = units + 0.6 else units = units + 1 end
    end
    local perLine = math.floor(math.max(1, N(contentWidth, 1)) / math.max(6, N(fontSize, 10) * 1.05))
    if perLine < 1 then perLine = 1 end
    return math.max(1, math.ceil(units / perLine))
end

function Tooltip:_EnsureFallback()
    if self.fallback ~= nil then return self.fallback end
    -- 兜底必须为 system 层顶层 transientWindow + popup 绘制优先级，避免根 emptywidget 被原生仓库/提示遮挡；
    -- 缓存/显示前先确立 pickable=false，遵循 ContextMenu 策略。
    local root = UI:CreatePanel(UIParent, "rsui_tooltip_popup", 0, 0, 220, 28, "card", {
        gradient = true, owner = self.owner, transientWindow = true, visible = false, pickable = false,
        drawPriority = Token("layer.popupPriority", 10000),
    })
    if root == nil then return nil end
    root.rsUiOwner = self.owner
    if type(UI.AdoptWidget) == "function" then UI:AdoptWidget(root, self.owner, "rsui_tooltip_popup") end
    if type(UI.TrySetUILayer) == "function" then UI:TrySetUILayer(root, "system") end
    if type(root.SetDrawPriority) == "function" then pcall(function() root:SetDrawPriority(Token("layer.popupPriority", 10000)) end) end
    -- 兜底提示复用普通 RSUI WrappedText；ArcheAge LABEL 为单行，不能把带换行的 TextLayout 字符串直接写入一个 Native 标签。
    local textComponent, textErr = RSUI:Text({
        id = "rsui_tooltip_text", parent = root, text = "", x = 8, y = 5, width = 204, height = 18,
        fontSize = 10, tone = "default", overflow = "wrap", maxLines = 8, nativeLineLimit = 8, shadow = true,
    })
    local label = textComponent and textComponent.lineLabels and textComponent.lineLabels[1] or nil
    if textComponent == nil or label == nil then
        UI:SetVisible(root, false, self.owner)
        if textComponent ~= nil and type(textComponent.Release) == "function" then pcall(function() textComponent:Release() end) end
        return nil, "tooltip_text_create_failed:" .. tostring(textErr or "label_unavailable")
    end
    if textComponent.root ~= nil then
        textComponent.root.rsUiOwner = self.owner
        if type(UI.AdoptWidget) == "function" then UI:AdoptWidget(textComponent.root, self.owner, "rsui_tooltip_text_host") end
    end
    -- 提示池仅表现，不能成为第二命中面而抢 OnLeave/点击/滚轮；若无法取消命中，不能缓存或显示，这属于正确性契约。
    if type(UI.EnsurePickable) ~= "function" then
        UI:SetVisible(root, false, self.owner)
        textComponent:Release()
        return nil, "tooltip_pickable_contract_unavailable"
    end
    local pickOk, _, pickErr = UI:EnsurePickable(root, false, self.owner)
    if pickOk ~= true then
        UI:SetVisible(root, false, self.owner)
        textComponent:Release()
        return nil, "tooltip_hit_test_disable_failed:" .. tostring(pickErr or "unknown")
    end
    local hidden, hideErr = EnsureVisible(root, false, self.owner)
    if hidden ~= true then
        textComponent:Release()
        return nil, "tooltip_initial_hide_failed:" .. tostring(hideErr or "unknown")
    end
    self.fallback = { root = root, label = label, textComponent = textComponent, text = nil }
    return self.fallback
end

function Tooltip:Show(target, text, options)
    options = type(options) == "table" and options or {}
    local native = ResolveNative(target)
    local value = tostring(text or "")
    if native == nil or value == "" then return false, "target_or_text_required" end

    RSUI.metrics.tooltipShows = (tonumber(RSUI.metrics.tooltipShows) or 0) + 1
    -- 决定位置路径前先采指针；cursorFollow 截断提示需贴光标，Native SetTooltip 锚定控件而非指针，因此此模式完全使用读取 PointerPosition 的池兜底。
    local mouseX, mouseY = PointerPosition()
    if type(SetTooltip) == "function" and options.forceFallback ~= true and options.cursorFollow ~= true then
        local ok = pcall(function() SetTooltip(value, native) end)
        if ok then return true, "native" end
    end

    local popup = self:_EnsureFallback()
    if popup == nil or popup.label == nil then return false, "tooltip_unavailable" end
    local fontSize = math.max(8, N(options.fontSize, 10))
    local maxWidth = Clamp(options.maxWidth or 320, 120, 480)
    local width = maxWidth
    if RSUI.TextLayout ~= nil and type(RSUI.TextLayout.MeasureWidth) == "function" then
        width = Clamp(RSUI.TextLayout:MeasureWidth(popup.label, value, fontSize) + 18, 120, maxWidth)
    end
    local vw, vh = UiMetrics()
    local lineHeight = (RSUI.TextLayout and RSUI.TextLayout:LineHeight(popup.label, fontSize)) or 14
    local maxHeight = Clamp(options.maxHeight or 360, 24, math.max(24, vh - 8))
    local heightLineLimit = math.max(1, math.floor((maxHeight - 10) / math.max(1, lineHeight)))
    local maxLines = math.max(1, math.floor(N(options.maxLines, heightLineLimit)))
    maxLines = math.min(maxLines, heightLineLimit)
    local textComponent = popup.textComponent
    if textComponent == nil then return false, "tooltip_wrapped_text_unavailable" end
    textComponent.maxLines = math.max(1, math.min(maxLines, tonumber(textComponent.nativeLineLimit) or 8))
    textComponent:SetFontSize(fontSize)
    textComponent:SetText(value)
    local _, desiredTextHeight = textComponent:Measure(math.max(1, width - 16), math.max(1, maxHeight - 10))
    local lines = math.max(1, math.ceil((tonumber(desiredTextHeight) or lineHeight) / math.max(1, lineHeight)))
    -- 以 EstimateWrappedLines 设行数下限，再推导组件上限；框恰好容纳允许绘制行，不能裁切或空带，nativeLineLimit 作为池标签数同时限制二者。
    local nativeLimit = tonumber(textComponent.nativeLineLimit) or 8
    lines = math.max(1, math.min(nativeLimit, math.max(lines,
        self:EstimateWrappedLines(value, width - 16, fontSize))))
    textComponent.maxLines = math.max(1, math.min(textComponent.maxLines or 1, nativeLimit))
    if textComponent.maxLines < lines then textComponent.maxLines = lines end
    local height = Clamp(lines * lineHeight + 10, 24, maxHeight)
    textComponent:Layout(8, 5, math.max(1, width - 16), math.max(1, height - 10))
    UI:SetExtent(popup.root, width, height, self.owner)

    local positioning = RSUI.PopupPositioning
    if type(positioning) ~= "table" or type(positioning.ResolvePoint) ~= "function"
        or type(positioning.ResolveAnchored) ~= "function" then
        return false, "tooltip_popup_positioning_contract_unavailable"
    end
    local gap = N(options.gap, 10) -- Tooltip 与 Trigger/鼠标之间只保留逻辑间距，不参与分辨率比例换算。
    local resolved, resolveErr -- resolved 仅为 point lane 或尺寸预算保存结果；目标型 Tooltip 的最终位置由 Native-relative Anchor 提交。
    local relativeTarget = false -- 默认认为当前 Tooltip 不是目标相对车道，只有无鼠标点且能证明 Trigger 时才切换。
    local targetW, targetH = 1, 1 -- 缓存 Trigger 逻辑尺寸供 Native-relative bottom offset 使用，尺寸来源仍是现有 AnchorRect 只读事实。
    if mouseX ~= nil and mouseY ~= nil then -- 鼠标跟随 Tooltip 属于显式 point lane，不强行改成 Trigger relative，以免丢失真实指针位置语义。
        -- 跟随光标仍只在 OnEnter 采样一次；共享弹层求解器负责视口逻辑空间的边缘翻转/限制。
        resolved, resolveErr = positioning:ResolvePoint(mouseX, mouseY, width, height, {
            id = "tooltip", gap = gap,
        })
    else
        local _, _, w, h, anchor = AnchorRect(target) -- 这里只用现有 AnchorRect 判断 Trigger 是否真实可用并取得逻辑尺寸，不再消费其绝对 X/Y 作为最终定位。
        targetW, targetH = math.max(1, tonumber(w) or 1), math.max(1, tonumber(h) or 1) -- 把 Trigger 尺寸归一为正逻辑值，后续相对 Anchor 只依赖 width/height。
        if type(anchor) == "table" and targetW > 2 and targetH > 2 then -- 有真实 Trigger 时切换到 .18.191 Native-relative lane，Shell/Scroll/UI Scale 均由 Native Anchor 系统处理。
            relativeTarget = true -- 标记最终位置必须相对目标控件提交，禁止后续 UIParent 绝对坐标写入。
            resolved = { width = width, height = height } -- 目标型 Tooltip 只需要已经 Measure 的 Popup 尺寸，不再运行绝对屏幕 placement solver。
        else -- 无法证明 Trigger 时继续使用既有 viewport 中央安全 fallback，避免 nil Anchor 产生异常。
            local viewport = positioning:GetViewport()
            resolved, resolveErr = positioning:ResolvePoint(
                viewport.x + viewport.width * 0.5 - width * 0.5,
                math.min(viewport.bottom - height - 4, viewport.y + 32),
                width, height, { id = "tooltip", gap = 0 })
        end
    end
    if resolved == nil then return false, "tooltip_popup_position_failed:" .. tostring(resolveErr or "unknown") end -- point/fallback solver 无结果时保持 fail-closed，不显示位置未知的 Tooltip。
    if relativeTarget == true then -- 目标型 Tooltip 使用 Trigger-local Native Anchor，完全绕开 UIParent 绝对坐标反推。
        local relativeOk, relativeErr = positioning:ApplyNativeRelativePopup(popup.root, target, self.owner, { id = "tooltip", width = width, height = height, triggerWidth = targetW, triggerHeight = targetH, gap = gap, placement = "bottom-start" }) -- 顶层 Tooltip Window 直接引用目标 Native Widget 作为 Anchor reference，解决不同分辨率/父级链造成的漂移。
        if relativeOk ~= true then return false, "tooltip_native_relative_anchor_failed:" .. tostring(relativeErr or "unknown") end -- Native-relative 失败时禁止退回旧绝对坐标猜测路径。
    else -- 鼠标/显式安全 fallback 没有 Trigger relative 语义，仍由 UIParent point lane 定位。
        UI:SetAnchor(popup.root, UIParent, resolved.x, resolved.y, self.owner) -- point lane 的 resolved 坐标已经属于 viewport logical；这里保持单次 UIParent Anchor 写入。
        popup.root.rsUiCoordinateLane = "popup-point-v1" -- 显式标记鼠标/point lane，诊断不再把它与 Trigger-relative 混为同一路径。
        popup.root.rsUiCoordinateSpace = "viewport-logical-v1" -- point lane 仍消费统一 viewport logical 坐标，不做二次 uiScale。
    end -- 结束 Tooltip relative/point 两条互斥定位车道。
    local shown, showErr = EnsureVisible(popup.root, true, self.owner) -- Native Anchor 建立后再显示 Tooltip，状态事务顺序保持与其他 Popup 一致。
    if shown ~= true then return false, "tooltip_show_failed:" .. tostring(showErr or "unknown") end -- 显示失败立即返回真实错误，不继续修正或 Raise。
    local correctionOk, correctionErr = positioning:CorrectNativePopupToScreen(popup.root, "tooltip") -- 无论 relative 还是 point lane，最终都让 RU Native 做屏幕边缘修正，避免低分辨率越界。
    if correctionOk ~= true then return false, "tooltip_screen_correction_failed:" .. tostring(correctionErr or "unknown") end -- Native 边缘修正存在但异常时 fail-closed，并把最终原始几何留在 Popup 诊断。
    -- Show 之后再 Raise，原生可见转换会重置临时窗口 z-slot，提前抬升不能保持。
    if type(popup.root.Raise) == "function" then pcall(function() popup.root:Raise() end) end
    popup.text = value
    popup.visible = true
    RSUI.metrics.tooltipRaises = (tonumber(RSUI.metrics.tooltipRaises) or 0) + 1
    return true, "fallback"
end

-- 周期 presenter 只读查询提示显现时让位；这是查询而非锁，提示仍是自身可见性唯一写入者，避免下次节拍掩埋提示。
function Tooltip:IsShowing()
    return self.fallback ~= nil and self.fallback.visible == true
end

function Tooltip:Hide()
    if self.fallback ~= nil and self.fallback.root ~= nil then
        local hidden, hideErr = EnsureVisible(self.fallback.root, false, self.owner)
        if hidden ~= true then return false, "tooltip_hide_failed:" .. tostring(hideErr or "unknown") end
        self.fallback.visible = false
    end
    RSUI.metrics.tooltipHides = (tonumber(RSUI.metrics.tooltipHides) or 0) + 1
    return true
end

function Tooltip:Bind(target, spec)
    local native, component = ResolveNative(target)
    if native == nil then return false, "target_required" end
    spec = type(spec) == "table" and spec or { text = spec }
    -- 裸 Native 无 RSUI 事件复用器，替换 OnEnter/OnLeave 可能破坏旧业务；迁移期须明确选择，直至控件转为 RSUI 组件。
    if component == nil and spec.allowRaw ~= true then return false, "component_required_or_allowRaw" end
    if component ~= nil and self.bindings[native] ~= nil and type(component.Off) == "function" then
        component:Off(native, "OnEnter", "rsui:tooltip_enter")
        component:Off(native, "OnLeave", "rsui:tooltip_leave")
    end
    self.bindings[native] = { text = spec.text, provider = spec.provider, options = spec, component = component }
    local service = self
    local function enter()
        local binding = service.bindings[native]
        if binding == nil then return false end
        local text = ResolveTooltipText(binding, binding.component)
        if text == "" then return false end
        return service:Show(binding.component or native, text, binding.options)
    end
    local function leave()
        -- Native SetTooltip 自行关闭；显式隐藏仅池兜底需要，其它情况无害。
        service:Hide()
        return true
    end
    local okA, okB
    if component ~= nil and type(component.On) == "function" then
        okA = component:On(native, "OnEnter", enter, "rsui:tooltip_enter")
        okB = component:On(native, "OnLeave", leave, "rsui:tooltip_leave")
    else
        okA = UI:SafeHandler(native, "OnEnter", enter, "rsui:tooltip_enter")
        okB = UI:SafeHandler(native, "OnLeave", leave, "rsui:tooltip_leave")
    end
    -- 悬浮 Enter/Leave 必须成对，单 Enter 可让提示常驻，单 Leave 永远不能显示；要求两者绑定，失败回滚部分订阅。
    if okA == true and okB == true then
        RSUI.metrics.tooltipBindings = (tonumber(RSUI.metrics.tooltipBindings) or 0) + 1
        return true
    end
    if component ~= nil and type(component.Off) == "function" then
        if okA == true then component:Off(native, "OnEnter", "rsui:tooltip_enter") end
        if okB == true then component:Off(native, "OnLeave", "rsui:tooltip_leave") end
    elseif type(native.ReleaseHandler) == "function" then
        if okA == true then pcall(function() native:ReleaseHandler("OnEnter") end) end
        if okB == true then pcall(function() native:ReleaseHandler("OnLeave") end) end
    end
    self.bindings[native] = nil
    self:Hide()
    RSUI.metrics.tooltipBindingPairFailures = (tonumber(RSUI.metrics.tooltipBindingPairFailures) or 0) + 1
    return false, "tooltip_handler_pair_required"
end

-- RSUI Text 的可复用提示绑定；调用方明确命中面，让标签鼠标穿透、行/卡/按钮负责输入，TableView 使用多列变体。
function Tooltip:BindOverflowText(textComponent, hitTarget, spec)
    if not RSUI:IsComponent(textComponent) or type(textComponent.GetOverflowTooltipText) ~= "function" then
        return false, "text_component_required"
    end
    if hitTarget == nil then return false, "hit_target_required" end
    local target = hitTarget
    spec = type(spec) == "table" and spec or {}
    local binding = {}
    for key, value in pairs(spec) do binding[key] = value end
    binding.provider = function() return textComponent:GetOverflowTooltipText() end
    -- 截断提示须跟光标，不能锚到单元格；此路径强制使用跟随光标池兜底。
    binding.cursorFollow = true
    return self:Bind(target, binding)
end

function Tooltip:Unbind(target)
    local native, component = ResolveNative(target)
    if native == nil then return false end
    local binding = self.bindings[native]
    component = component or (binding and binding.component)
    if component ~= nil and type(component.Off) == "function" then
        component:Off(native, "OnEnter", "rsui:tooltip_enter")
        component:Off(native, "OnLeave", "rsui:tooltip_leave")
    end
    self.bindings[native] = nil
    self:Hide()
    return true
end

------------------------------------------------------------------------
-- ContextMenuService 上下文菜单。
--
-- Suite 共用菜单池，明确打开；可绑定具体控件已验证事件，不能补造 ui_functions.lua 不存在的右键事件名。
------------------------------------------------------------------------
local ContextMenu = {
    version = 1,
    owner = "rsui:context_menu_service",
    root = nil,
    rows = {},
    items = {},
    open = false,
    maxItems = 24,
    rowHeight = 25,
    padding = 4,
}
RSUI.ContextMenu = ContextMenu
if RSUI.PopupCoordinator ~= nil and type(RSUI.PopupCoordinator.Register) == "function" then
    RSUI.PopupCoordinator:Register(ContextMenu)
end

function ContextMenu:_EnsureRoot()
    if self.root ~= nil then return self.root end
    local root = UI:CreatePanel(UIParent, "rsui_context_menu", 0, 0, 180, 30, "card", {
        gradient = true, owner = self.owner, transientWindow = true, visible = false, pickable = false,
        drawPriority = Token("layer.popupPriority", 10000),
    })
    if root == nil then return nil end
    root.rsUiOwner = self.owner
    if type(UI.AdoptWidget) == "function" then UI:AdoptWidget(root, self.owner, "rsui_context_menu") end
    if type(UI.TrySetUILayer) == "function" then UI:TrySetUILayer(root, "system") end
    if type(root.SetDrawPriority) == "function" then pcall(function() root:SetDrawPriority(Token("layer.popupPriority", 10000)) end) end
    if type(UI.EnsurePickable) ~= "function" or type(UI.EnsureEnabled) ~= "function" then
        UI:SetVisible(root, false, self.owner)
        return nil, "context_menu_interaction_contract_unavailable"
    end
    local pickOk, _, pickErr = UI:EnsurePickable(root, false, self.owner)
    local enabledOk, _, enabledErr = UI:EnsureEnabled(root, true, self.owner)
    if pickOk ~= true or enabledOk ~= true then
        UI:SetVisible(root, false, self.owner)
        return nil, "context_menu_interaction_failed:" .. tostring(pickErr or enabledErr or "unknown")
    end
    local hidden, hideErr = EnsureVisible(root, false, self.owner)
    if hidden ~= true then return nil, "context_menu_initial_hide_failed:" .. tostring(hideErr or "unknown") end
    self.root = root
    return root
end

function ContextMenu:_EnsureRow(index)
    if self.rows[index] ~= nil then return self.rows[index] end
    if self:_EnsureRoot() == nil then return nil end
    local button = UI:CreateButton(self.root, "rsui_context_item_" .. tostring(index), "", self.padding, self.padding + (index - 1) * self.rowHeight, 172, self.rowHeight - 1, 10, false, false)
    if button == nil then return nil end
    button.rsUiOwner = self.owner
    if type(UI.AdoptWidget) == "function" then UI:AdoptWidget(button, self.owner, "rsui_context_item_" .. tostring(index)) end
    local service = self
    local clickBound, clickErr = UI:RequireHandler(button, "OnClick", function()
        local row = service.rows[index]
        local item = row and row.item
        if item == nil or item.enabled == false or item.separator == true then return false end
        local callback = item.onClick or item.action
        local closeFirst = item.closeOnClick ~= false
        if closeFirst then service:Close() end
        RSUI.metrics.contextMenuActions = (tonumber(RSUI.metrics.contextMenuActions) or 0) + 1
        if type(callback) == "function" then Callback("rsui:context_menu:" .. tostring(item.id or index), callback, item, index) end
        return true
    end, "rsui:context_menu_click:" .. tostring(index))
    if clickBound ~= true then
        UI:SetVisible(button, false, self.owner)
        return nil, clickErr or "context_menu_click_bind_failed"
    end
    local row = { button = button, item = nil }
    self.rows[index] = row
    RSUI.metrics.contextMenuRowsCreated = (tonumber(RSUI.metrics.contextMenuRowsCreated) or 0) + 1
    return row
end

local function NormalizeMenuItems(items, maxItems)
    local out = {}
    for index, item in ipairs(type(items) == "table" and items or {}) do
        if #out >= maxItems then break end
        if type(item) ~= "table" then item = { text = tostring(item) } end
        out[#out + 1] = {
            id = tostring(item.id or index),
            text = tostring(item.text or item.label or item.title or ""),
            enabled = item.enabled ~= false,
            separator = item.separator == true,
            checked = item.checked == true,
            tone = item.tone,
            onClick = item.onClick,
            action = item.action,
            closeOnClick = item.closeOnClick,
            source = item,
        }
    end
    return out
end

function ContextMenu:Open(anchor, items, options)
    options = type(options) == "table" and options or {}
    if self:_EnsureRoot() == nil then return false, "context_menu_unavailable" end
    if RSUI.PopupCoordinator ~= nil then RSUI.PopupCoordinator:CloseAll(self) end
    local maxRequested = math.max(1, math.min(self.maxItems, N(options.maxItems, self.maxItems)))
    local normalized = NormalizeMenuItems(items, maxRequested)
    if #normalized == 0 then self:Close(); return false, "items_required" end
    local width = Clamp(options.width or 180, 120, 360)
    if options.autoWidth ~= false and RSUI.TextLayout ~= nil and type(RSUI.TextLayout.MeasureWidth) == "function" then
        local maxMeasured = width
        for _, item in ipairs(normalized) do
            if not item.separator then maxMeasured = math.max(maxMeasured, RSUI.TextLayout:MeasureWidth(nil, item.text, 10) + 42) end
        end
        width = Clamp(maxMeasured, 120, N(options.maxWidth, 360))
    end
    local rowHeight = Clamp(options.rowHeight or self.rowHeight, 20, 36)
    local padding = Clamp(options.padding or self.padding, 2, 12)
    self.rowHeight, self.padding = rowHeight, padding
    local vw, vh = UiMetrics()
    local screenRows = math.max(1, math.floor((math.max(1, vh - 8) - padding * 2) / rowHeight))
    while #normalized > screenRows do table.remove(normalized) end
    self.items = normalized
    local height = padding * 2 + #normalized * rowHeight

    for index, item in ipairs(normalized) do
        local row, rowErr = self:_EnsureRow(index)
        if row == nil then
            self:Close()
            return false, tostring(rowErr or ("context_menu_row_unavailable:" .. tostring(index)))
        end
        if row ~= nil then
            row.item = item
            local prefix = item.checked and "✓  " or ""
            local text = item.separator and "────────────" or (prefix .. item.text)
            UI:SetText(row.button, text, self.owner)
            UI:SetExtent(row.button, math.max(1, width - padding * 2), math.max(1, rowHeight - 1), self.owner)
            UI:SetAnchor(row.button, self.root, padding, padding + (index - 1) * rowHeight, self.owner)
            if type(UI.EnsureEnabled) ~= "function" then
                self:Close()
                return false, "context_menu_enabled_contract_unavailable"
            end
            local enableOk, _, enableErr = UI:EnsureEnabled(row.button, item.enabled and not item.separator, self.owner)
            if enableOk ~= true then
                self:Close()
                return false, "context_menu_row_enable_failed:" .. tostring(index) .. ":" .. tostring(enableErr or "unknown")
            end
            if type(UI.SetLabelTone) == "function" then UI:SetLabelTone(row.button, item.tone or "default", self.owner) end
            UI:SetVisible(row.button, true, self.owner)
        end
    end
    for index = #normalized + 1, #self.rows do
        local row = self.rows[index]
        if row ~= nil and row.button ~= nil then row.item = nil; UI:SetVisible(row.button, false, self.owner) end
    end

    UI:SetExtent(self.root, width, height, self.owner)
    local positioning = RSUI.PopupPositioning
    if type(positioning) ~= "table" or type(positioning.ResolveAnchorRect) ~= "function"
        or type(positioning.ResolveAnchored) ~= "function" then
        return false, "context_menu_popup_positioning_contract_unavailable"
    end
    local anchorRect, anchorErr = positioning:ResolveAnchorRect(anchor)
    if anchorRect == nil then return false, "context_menu_anchor_unavailable:" .. tostring(anchorErr or "unknown") end
    local resolved, resolveErr -- ContextMenu 只在显式 screen point 时需要绝对 solver；目标型菜单直接使用 Native-relative Anchor。
    local relativePlacement = nil -- nil 表示 point lane；bottom/right 表示相对 Trigger 的 Native Anchor 方向。
    if tonumber(options.x) ~= nil and tonumber(options.y) ~= nil then -- 调用方给出明确屏幕点时保留 point lane，不能擅自改成目标相对语义。
        resolved, resolveErr = positioning:ResolvePoint(tonumber(options.x), tonumber(options.y), width, height, { id = "context_menu", gap = 0 }) -- 显式 point 只经过统一 viewport solver 一次，并在 Show 后继续走 Native 屏幕修正。
    elseif options.position == "right" then -- 右侧菜单属于 Trigger-relative 语义，不再用 anchorRect.right 反推 UIParent 绝对坐标。
        relativePlacement = "right-start" -- 记录相对方向，由 ApplyNativeRelativePopup 使用 TriggerWidth + gap 生成本地 X。
        resolved = { width = width, height = height } -- 相对车道只保留 Popup 尺寸，不运行绝对 placement solver。
    else -- 默认 ContextMenu 紧贴 Trigger 下方，与 Dropdown/ColorField 使用同一 Native-relative 基础能力。
        relativePlacement = "bottom-start" -- 默认方向为 Trigger 下方，边缘越界由 CorrectOffsetByScreen 修正。
        resolved = { width = width, height = height } -- 相对车道不需要 anchorRect.x/y，因此不会受 Shell/Scroll/UI Scale 影响。
    end -- 结束 ContextMenu point/relative 路由选择。
    if resolved == nil then return false, "context_menu_popup_position_failed:" .. tostring(resolveErr or "unknown") end -- 显式 point solver 失败时保持 fail-closed。
    if relativePlacement ~= nil then -- 有目标相对方向时，顶层 Window 直接锚到 anchor Native Widget。
        local relativeOk, relativeErr = positioning:ApplyNativeRelativePopup(self.root, anchor, self.owner, { id = "context_menu", width = width, height = height, triggerWidth = anchorRect.width, triggerHeight = anchorRect.height, gap = 4, placement = relativePlacement }) -- ContextMenu 复用统一 Native-relative Authority，不再维护私有坐标算法。
        if relativeOk ~= true then return false, "context_menu_native_relative_anchor_failed:" .. tostring(relativeErr or "unknown") end -- 相对锚定失败时拒绝打开，禁止回退错误绝对坐标。
    else -- 只有显式 options.x/options.y 仍走 UIParent point lane。
        UI:SetAnchor(self.root, UIParent, resolved.x, resolved.y, self.owner) -- point lane 保持一次绝对 Anchor 写入，随后交给 Native 做边缘修正。
        self.root.rsUiCoordinateLane = "popup-point-v1" -- 标记显式点定位车道，便于诊断区分。
        self.root.rsUiCoordinateSpace = "viewport-logical-v1" -- 显式点仍使用 viewport logical 坐标空间。
    end -- 结束 ContextMenu 最终 Anchor 提交。
    -- 菜单与 Dropdown/ColorField 共用命中静默契约：Close() 取消拾取，Show 先恢复。
    local repickOk, _, repickErr = UI:EnsurePickable(self.root, true, self.owner)
    if repickOk ~= true then return false, "context_menu_repick_failed:" .. tostring(repickErr or "unknown") end
    local shown, showErr = EnsureVisible(self.root, true, self.owner) -- ContextMenu Anchor 成功后再显示，保持 Native/Presentation 状态事务顺序。
    if shown ~= true then return false, "context_menu_show_failed:" .. tostring(showErr or "unknown") end -- 显示失败立即停止，避免 hidden/pickable/open 状态分叉。
    local correctionOk, correctionErr = positioning:CorrectNativePopupToScreen(self.root, "context_menu") -- 由 RU CorrectOffsetByScreen 统一处理右/下屏幕边缘，分辨率适配不再依赖 Lua 固定偏移。
    if correctionOk ~= true then return false, "context_menu_screen_correction_failed:" .. tostring(correctionErr or "unknown") end -- Native 修正异常时 fail-closed，并保留实机几何证据。
    if type(self.root.Raise) == "function" then pcall(function() self.root:Raise() end) end -- 最终 Raise 保证 Menu 的 Popup Z-Layer 契约不因坐标重构改变。
    self.open = true
    RSUI.metrics.contextMenuOpens = (tonumber(RSUI.metrics.contextMenuOpens) or 0) + 1
    return true
end

function ContextMenu:Close()
    local changed = self.open == true
    if self.root ~= nil then
        local hidden, hideErr = EnsureVisible(self.root, false, self.owner)
        if hidden ~= true then return false, "context_menu_hide_failed:" .. tostring(hideErr or "unknown") end
        -- 隐藏菜单不能只依赖原生跳过命中。
        local unpickOk, _, unpickErr = UI:EnsurePickable(self.root, false, self.owner)
        if unpickOk ~= true then return false, "context_menu_unpick_failed:" .. tostring(unpickErr or "unknown") end
    end
    self.open = false
    if changed then RSUI.metrics.contextMenuCloses = (tonumber(RSUI.metrics.contextMenuCloses) or 0) + 1 end
    return changed
end

function ContextMenu:IsOpen() return self.open == true end

function ContextMenu:Bind(target, provider, eventName, options)
    local native, component = ResolveNative(target)
    if native == nil or type(provider) ~= "function" then return false, "target_provider_required" end
    options = type(options) == "table" and options or {}
    if component == nil and options.allowRaw ~= true then return false, "component_required_or_allowRaw" end
    -- 默认 OnClick 保守；其它事件须先确认具体 Native 控件支持。
    eventName = tostring(eventName or "OnClick")
    local service = self
    local handler = function()
        local ok, items = Callback("rsui:context_provider", provider, component or native)
        if not ok or type(items) ~= "table" then return false end
        return service:Open(component or native, items)
    end
    if component ~= nil and type(component.On) == "function" then
        return component:On(native, eventName, handler, "rsui:context_bind:" .. eventName)
    end
    return UI:SafeHandler(native, eventName, handler, "rsui:context_bind:" .. eventName)
end

------------------------------------------------------------------------
-- FocusService 焦点服务。
------------------------------------------------------------------------
local Focus = {
    version = 3,
    keyboardNavigationSupported = false,
    keyboardNavigationReason = "generic keyboard handlers undocumented; Native focus getter not allowed",
}
RSUI.Focus = Focus
RSUI.FocusContractVersion = 3

function Focus:CanSet(target)
    local native = ResolveNative(target)
    if native == nil then return false, "focus_target_required" end
    if type(native.SetFocus) ~= "function" then return false, "set_focus_unavailable" end
    return true, nil
end

function Focus:CanClear(target)
    local native = ResolveNative(target)
    if native == nil then return false, "focus_target_required" end
    if type(native.ClearFocus) ~= "function" then return false, "clear_focus_unavailable" end
    return true, nil
end

local function ApplyFocusInteraction(native, methodName)
    if type(UI.TryInteractionCall) == "function" then
        local accepted, interactionErr = UI:TryInteractionCall(native, methodName)
        if accepted == true then return true, nil end
        return false, tostring(interactionErr or (methodName .. "_failed"))
    end
    local ok, result = pcall(function() return native[methodName](native) end)
    if ok == true and result ~= false then return true, nil end
    return false, tostring(ok and "native_rejected" or result)
end

function Focus:Set(target)
    local supported, reason = self:CanSet(target)
    if supported ~= true then return false, reason end
    local native = ResolveNative(target)
    local accepted, focusErr = ApplyFocusInteraction(native, "SetFocus")
    if accepted == true then
        RSUI.metrics.focusChanges = (tonumber(RSUI.metrics.focusChanges) or 0) + 1
        return true, nil
    end
    return false, "set_focus_failed:" .. tostring(focusErr or "unknown")
end

function Focus:Clear(target)
    local supported, reason = self:CanClear(target)
    if supported ~= true then return false, reason end
    local native = ResolveNative(target)
    local accepted, focusErr = ApplyFocusInteraction(native, "ClearFocus")
    if accepted == true then
        RSUI.metrics.focusChanges = (tonumber(RSUI.metrics.focusChanges) or 0) + 1
        return true, nil
    end
    return false, "clear_focus_failed:" .. tostring(focusErr or "unknown")
end

function Focus:GetFocusedWidgetId()
    return nil, "get_focus_not_allowed"
end

function Focus:GetTargetWidgetId(target)
    local native = ResolveNative(target)
    if native == nil then return nil, "focus_target_required" end
    local physical = native.rsNativePhysicalId
    if physical ~= nil and tostring(physical) ~= "" then return tostring(physical), nil end
    -- 部分旧收养 Native 仅携带 RSUI 逻辑身份，可供诊断，但 IsFocused 不能假定全局焦点 API 返回该形式。
    local logical = native.rsNativeLogicalId or native.rsUiLogicalId
    if logical ~= nil and tostring(logical) ~= "" then return tostring(logical), "logical_identity_only" end
    return nil, "focus_target_identity_unavailable"
end

function Focus:IsFocused(target)
    local native = ResolveNative(target)
    if native == nil then return false, "focus_target_required" end
    -- 输入控件使用 UI 生命周期身份兼容验证；RU 焦点诊断可返回生成物理 id 或 Suite 逻辑 id。
    if native.rsUiKeyboardInput == true and type(UI.IsInputWidgetFocused) == "function" then
        return UI:IsInputWidgetFocused(native)
    end
    local focusedId, focusErr = self:GetFocusedWidgetId()
    if focusErr ~= nil then return false, focusErr end
    if focusedId == nil then return false, nil end
    local physical = native.rsNativePhysicalId
    if physical == nil or tostring(physical) == "" then return false, "focus_target_physical_identity_unavailable" end
    return tostring(physical) == tostring(focusedId), nil
end

function Focus:GetCapabilities(target)
    local targetProvided = target ~= nil
    local canSet = false
    local canClear = false
    if targetProvided then
        canSet = self:CanSet(target) == true
        canClear = self:CanClear(target) == true
    end
    return {
        version = self.version,
        contractVersion = tonumber(RSUI.FocusContractVersion) or 0,
        targetAware = true,
        targetProvided = targetProvided,
        setFocus = canSet,
        clearFocus = canClear,
        getFocusedWidgetId = false,
        getFocusedWidgetIdReason = "not_allowed",
        genericKeyboardNavigation = self.keyboardNavigationSupported == true,
        reason = self.keyboardNavigationReason,
    }
end
