------------------------------------------------------------------------
-- Replicated Suite · 原生控件工厂
-- 作者：Replicated
-- QQ群：1104129461
--
-- 仅活跃 V3 Foundation；旧 ManagedWindow/Page 导航 helper 已移 legacy_reference/ui 且不加载。
-- 本文件仅构造/注册原生原语，后续几何/表现修改归 rs_ui_framework.lua。
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite

S.UI = {
    controls = {},
    registryMetrics = { duplicates = 0, v3Duplicates = 0, degraded = 0 },
    -- Native 交互契约：全部命中方法使用已验证单参数 RU WidgetBase ABI；布尔 false 状态返回与操作拒绝分开；单/多行输入明确配置鼠标/键盘焦点，降级原语拒绝返回为健康控件。
    NativeInteractionContractVersion = 7,
    CriticalInteractionDeliveryContractVersion = 1,
    -- 根临时弹层/菜单使用真实 Native Window，树内普通 Panel 保持 emptywidget，避免 RU 跨根层级失效。
    TopLevelTransientWindowContractVersion = 1,
    -- 约束（2026-09-17，visual-guide-native-layer-1）：世界空间 HUD 引导（当前仅范围圆/单位连线）
    -- 与普通插件 Window/Popup 的层级 Authority 分离。CreateOverlayWindow 必须固定进入 game 层，
    -- 让背包/拍卖/地图等 normal/dialog/system 原生窗口天然覆盖这些点；不能让 Feature/Presenter 自行
    -- Raise/切 system。数据流：CombatVisualGuides -> CreateOverlayWindow -> Native SetUILayer("game")。
    -- 兼容边界：只改变这类 non-pickable transient overlay host 的 Native z-layer，不改变投影坐标、
    -- 点池、Feature 生命周期、刷新频率或 Store。风险：若 RU 客户端未来改变 game 层可见性，需要通过
    -- 实机诊断升级此契约，而不能回退到 system 以免再次遮挡原生窗口。
    WorldHudNativeLayerContractVersion = 1,
}
local UIX = S.UI

local function TrackNativeBuildWidget(widget)
    local rsui = S.RSUI
    if widget ~= nil and type(rsui) == "table" and type(rsui.TrackBuildWidget) == "function" then rsui:TrackBuildWidget(widget) end
    return widget
end

local function MarkPrimitiveDegraded(widget, id, detail)
    if widget == nil then return nil end
    UIX.registryMetrics.degraded = (tonumber(UIX.registryMetrics.degraded) or 0) + 1
    pcall(function()
        local owner = widget.rsUiOwner
        if widget.rsUiKeyboardInput == true then
            if type(widget.ClearFocus) == "function" then pcall(function() widget:ClearFocus() end) end
            if type(widget.EnableKeyboard) == "function" then pcall(function() widget:EnableKeyboard(false) end) end
            if type(widget.EnableFocus) == "function" then pcall(function() widget:EnableFocus(false) end) end
        end
        -- 先应用最终防御状态再标降级，Diff 权威有意拒绝已降级控件。
        if type(UIX.SetEnabled) == "function" then UIX:SetEnabled(widget, false, owner) end
        if type(UIX.SetPickable) == "function" then UIX:SetPickable(widget, false, owner) end
        if type(UIX.SetVisible) == "function" then UIX:SetVisible(widget, false, owner) end
        widget.rsUiDegraded = true
        widget.rsUiDegradedReason = tostring(detail or "native primitive configuration failed")
    end)
    local diagnostics = S.DiagnosticsManager
    if type(diagnostics) == "table" and type(diagnostics.Emit) == "function" then
        diagnostics:Emit("error", "ui", "NATIVE_PRIMITIVE_DEGRADED", "原生控件已创建但初始化失败，已隐藏并隔离", {
            id = tostring(id or ""), error = tostring(detail or "configuration_failed"),
        })
    end
    return widget
end

local NATIVE_BOOLEAN_STATE_SETTERS = {
    Enable = true,
    EnableFocus = true,
    EnableKeyboard = true,
    EnablePick = true,
    Clickable = true,
    EnableDrag = true,
    EnableScroll = true,
    SetReClickable = true,
    SetReadOnly = true,
}

local function CallNativeAccepted(widget, methodName, ...)
    if widget == nil then return false, "nil_widget" end
    local method = widget[methodName]
    if type(method) ~= "function" then return false, tostring(methodName) .. "_unavailable" end
    local args, count = { ... }, select("#", ...)
    local ok, result = pcall(function() return method(widget, unpack(args, 1, count)) end)
    if ok ~= true then return false, tostring(result or methodName .. "_failed") end
    -- Native setter 无成功返回文档，布尔 setter 可返回最终状态，SetReadOnly(false)/EnablePick(false) 的 false 合法；
    -- 仅精确 false 状态写接受歧义，StartMoving 等操作与 true 状态写显式 false 仍拒绝。
    if result == false then
        local falseStateSetter = NATIVE_BOOLEAN_STATE_SETTERS[tostring(methodName or "")] == true
            and count >= 1 and args[1] == false
        if not falseStateSetter then return false, tostring(methodName) .. "_rejected" end
    end
    return true, result
end

local function ConfigureNativePickable(widget, enabled)
    if widget == nil then return false end
    local value = enabled == true
    local calls = 0
    if type(widget.EnablePick) == "function" then
        local ok = CallNativeAccepted(widget, "EnablePick", value)
        if ok ~= true then return false end
        calls = calls + 1
    end
    if type(widget.Clickable) == "function" then
        local ok = CallNativeAccepted(widget, "Clickable", value)
        if ok ~= true then return false end
        calls = calls + 1
    end
    return calls > 0
end

local function PrimitiveFailureDetail(code, err)
    local prefix = tostring(code or "native_primitive_configuration_failed")
    local detail = tostring(err or ""):gsub("[\r\n]+", " ")
    if #detail > 220 then detail = detail:sub(1, 220) .. "..." end
    if detail == "" then return prefix end
    return prefix .. ":" .. detail
end

local function FailPrimitive(widget, id, detail)
    detail = tostring(detail or "native primitive configuration failed")
    MarkPrimitiveDegraded(widget, id, detail)
    -- 保留 Native 身份/生命周期注册，防当前 Generation 复用已有 C++ 名；降级对象不能作为可用控件返回。
    UIX:Register(id, widget)
    return nil, detail
end

local function IsRootParent(parent)
    return parent == "UIParent" or parent == UIParent
end

local function RootNativeParent(parent)
    if IsRootParent(parent) then return "UIParent" end
    return parent
end

local function RootAnchorParent(parent)
    if IsRootParent(parent) then return "UIParent" end
    return parent
end

local function RootStateParent(parent)
    if IsRootParent(parent) then return UIParent end
    return parent
end

function UIX:Register(id, widget)
    TrackNativeBuildWidget(widget)
    if id ~= nil and widget ~= nil then
        local key = tostring(id)
        local previous = self.controls[key]
        local owner = tostring(widget.rsUiOwner or "")
        if previous ~= nil and previous ~= widget then
            self.registryMetrics.duplicates = (tonumber(self.registryMetrics.duplicates) or 0) + 1
            local previousOwner = tostring(previous.rsUiOwner or "")
            local strictV3 = owner:sub(1, 3) == "v3:" or previousOwner:sub(1, 3) == "v3:"
            if strictV3 then
                -- V3 ID 表示地址/所有权，不能作为标签或在严格树保留旧后写覆盖。
                self.registryMetrics.v3Duplicates = (tonumber(self.registryMetrics.v3Duplicates) or 0) + 1
                widget.rsUiRegistrationRejected = true
                -- SetVisible(false) 缓存命中可合法 false，仍是拒绝 V3 UI 的唯一显隐权威。
                if type(UIX.SetVisible) == "function" then pcall(function() UIX:SetVisible(widget, false, owner) end) end
                if type(S.RecordLog) == "function" then
                    S.RecordLog("error", "ui_v3", "DUPLICATE_COMPONENT_ID:" .. key .. ":owner=" .. owner .. ":previous=" .. previousOwner)
                end
                local d = S.DiagnosticsManager
                if type(d) == "table" and type(d.Emit) == "function" then
                    d:Emit("error", "ui_v3", "DUPLICATE_COMPONENT_ID", "V3 UI 控件 ID 重复，已安全拒绝新控件", {
                        id = key, owner = owner, previousOwner = previousOwner,
                    })
                end
                -- 不能把被拒 Native 别名到先前注册对象；返回旧对象会用错误父/类型继续布局，并以旧几何跨 Lua/Native 所有权边界。
                return nil
            end
            -- 迁移期保留旧兼容，但每次重复仍计数，清理不能依赖静默别名。
            S.WarnOnce("ui_control_duplicate:" .. key, "界面控件编号重复：" .. key)
        end
        self.controls[key] = widget
        if owner:sub(1, 3) == "v3:" and type(self.AdoptV3Widget) == "function" then
            self:AdoptV3Widget(widget, owner, key)
        elseif type(self.AdoptWidget) == "function" then
            self:AdoptWidget(widget, widget.rsUiOwner, key)
        end
    end
    return widget
end

function UIX:GetRegistrySnapshot()
    return {
        duplicates = tonumber(self.registryMetrics and self.registryMetrics.duplicates) or 0,
        v3Duplicates = tonumber(self.registryMetrics and self.registryMetrics.v3Duplicates) or 0,
        degraded = tonumber(self.registryMetrics and self.registryMetrics.degraded) or 0,
    }
end

function UIX:TryInteractionCall(widget, methodName, ...)
    return CallNativeAccepted(widget, tostring(methodName or ""), ...)
end

function UIX:RequireHandler(widget, eventName, fn, label)
    local bound = self:SafeHandler(widget, eventName, fn, label)
    if bound == true then return true end
    local detail = "required_handler_bind_failed:" .. tostring(eventName or "") .. ":" .. tostring(label or "")
    local diagnostics = S.DiagnosticsManager
    if type(diagnostics) == "table" and type(diagnostics.Error) == "function" then
        diagnostics:Error("ui_event", "UI_REQUIRED_HANDLER_BIND_FAILED", "关键界面事件绑定失败，控件已拒绝继续构建", {
            event = tostring(eventName or ""), label = tostring(label or eventName or ""),
            logicalId = tostring(widget and (widget.rsUiLogicalId or widget.rsNativeLogicalId) or ""),
        })
    end
    return false, detail
end

function UIX:SafeHandler(widget, eventName, fn, label)
    if widget == nil or type(widget.SetHandler) ~= "function" or type(fn) ~= "function" then return false end
    -- 绑定处理器也是 Native 写；拒绝/陈旧控件不能接收超出 RSUI owner 或跨热重载代际的回调。框架在本模块后安装 IsWidgetUsable，可用时须遵循。
    if type(self.IsWidgetUsable) == "function" and self:IsWidgetUsable(widget) ~= true then return false end
    local generation = S.Generation
    -- 每次绑定只创建一次 packer，不每事件分配；滑块拖动可产生大量回调。
    local function Pack(...)
        local packed = { ... }
        packed.n = select("#", ...)
        return packed
    end
    local function handler(...)
        if S.Generation ~= generation then return nil end
        if type(UIX.IsWidgetUsable) == "function" and UIX:IsWidgetUsable(widget) ~= true then return nil end
        local args = { ... }
        local argCount = select("#", ...)
        local result = nil
        local token = S.PerformanceMonitor and S.PerformanceMonitor:Begin("ui:" .. tostring(label or eventName)) or nil
        local ok, err = xpcall(function()
            -- 保持精确返回数量；`{ fn(...) }` 丢尾部/中间 nil，可能改变拖动开始 `false,nil` 契约。
            result = Pack(fn(unpack(args, 1, argCount)))
        end, S.SafeTraceback)
        if S.PerformanceMonitor ~= nil then S.PerformanceMonitor:End(token) end
        if not ok then
            local diagnostics = S.DiagnosticsManager
            if type(diagnostics) == "table" and type(diagnostics.Error) == "function" then
                diagnostics:Error("ui_event", "UI_HANDLER_EXCEPTION", "原生界面事件回调执行失败", {
                    event = tostring(eventName or ""), label = tostring(label or eventName or ""),
                    logicalId = tostring(widget and (widget.rsUiLogicalId or widget.rsNativeLogicalId) or ""),
                    owner = tostring(widget and widget.rsUiOwner or ""), error = tostring(err),
                })
            end
            S.SafeChat("界面错误 " .. tostring(label or eventName) .. "：" .. tostring(err))
            return nil
        end
        if result ~= nil then return unpack(result, 1, tonumber(result.n) or #result) end
        return nil
    end
    -- 部分 RU 仅支持多个历史事件名中的一个；安全探测 SetHandler 并返回成功状态，在首个支持别名停止，避免重复绑定。
    local ok, bindResult = pcall(function() return widget:SetHandler(eventName, handler) end)
    -- 未知 handler 可返回 false 而不抛错；同样当探测失败，继续下个已支持事件名。
    local bound = ok == true and bindResult ~= false
    if bound and type(self.RegisterHandlerBinding) == "function" then self:RegisterHandlerBinding(widget, eventName) end
    if not bound then
        -- 未绑 OnClick 会呈现死按钮，应每标签报告一次，不能只返回调用方常忽略的标志。
        local diagnostics = S.DiagnosticsManager
        if type(diagnostics) == "table" and type(diagnostics.Warn) == "function" then
            diagnostics:Warn("ui_event", "UI_HANDLER_BIND_FAILED", "原生界面事件绑定失败，该控件点击将无响应", {
                event = tostring(eventName or ""), label = tostring(label or eventName or ""),
                logicalId = tostring(widget and (widget.rsUiLogicalId or widget.rsNativeLogicalId) or ""),
            })
        end
        if type(S.WarnOnce) == "function" then
            S.WarnOnce("rsui_bind_failed_" .. tostring(label or eventName),
                "界面事件绑定失败：" .. tostring(label or eventName) .. "（" .. tostring(eventName) .. "），该按钮可能无响应，请在诊断页查看详情")
        end
    end
    return bound
end

-- SetUILayer 为可选能力，ui_functions 在 Window 提供，但若干 WidgetBase 无实现；V3 不能直接调用或假设旧工厂加载。
-- 适配器允许兜底 draw priority，避免整个 Page/Dropdown 事务失败。
function UIX:TrySetUILayer(widget, layerName)
    if widget == nil or type(widget.SetUILayer) ~= "function" then return false end
    local ok, result = pcall(function() return widget:SetUILayer(layerName or "system") end)
    return ok == true and result ~= false
end

-- 普通对话框标准生命周期；HUD 继续用 WidgetBase/HudManager，对话框提供更小 API，但共用逻辑位置、安全拖动、尺寸边界、透明度、字体归属。
function UIX:CreateEmptyWidget(parent, id, x, y, width, height, pickable, explicitOwner)
    local factory = S.NativeObjectFactory
    if type(factory) ~= "table" or parent == nil then return nil, "native_factory_or_parent_unavailable" end
    local rootParent = IsRootParent(parent)
    if rootParent ~= true and type(parent.CreateChildWidget) ~= "function" then return nil, "CreateChildWidget unavailable" end
    local widget, nativeErr
    if rootParent then
        widget, nativeErr = factory:CreateEmptyWidget(S.PhysicalId(id), "UIParent")
    else
        widget, nativeErr = factory:CreateChild(parent, "emptywidget", S.PhysicalId(id), 0, true)
    end
    if widget == nil then return nil, nativeErr or "emptywidget_create_failed" end
    TrackNativeBuildWidget(widget)
    local anchorParent = RootAnchorParent(parent)
    local stateParent = RootStateParent(parent)
    local ownerParent = rootParent and nil or parent
    widget.rsHudOwner = ownerParent and ownerParent.rsHudOwner or nil
    widget.rsUiOwner = explicitOwner or (ownerParent and (ownerParent.rsUiOwner or (ownerParent.rsHudOwner and ("hud:" .. tostring(ownerParent.rsHudOwner)))) or nil)
    widget.rsUiParent = stateParent
    local configured, configureErr = pcall(function()
        widget:SetExtent(math.max(1, tonumber(width) or 1), math.max(1, tonumber(height) or 1))
        widget:AddAnchor("TOPLEFT", anchorParent, tonumber(x) or 0, tonumber(y) or 0)
        if widget.Enable ~= nil then
            local accepted = CallNativeAccepted(widget, "Enable", true)
            if accepted ~= true then error("emptywidget Enable rejected") end
        end
        local nativePickable = ConfigureNativePickable(widget, pickable == true)
        if nativePickable ~= true then error("emptywidget hit-test state unavailable") end
        widget:Show(true)
    end)
    if not configured then
        return FailPrimitive(widget, id, PrimitiveFailureDetail("emptywidget_configuration_failed", configureErr))
    end
    if type(self.PrimeNativeState) == "function" then
        self:PrimeNativeState(widget, {
            width = math.max(1, tonumber(width) or 1), height = math.max(1, tonumber(height) or 1),
            visible = true, enabled = true, pickable = pickable == true,
            anchorTopLeft = { parent = stateParent, x = tonumber(x) or 0, y = tonumber(y) or 0 },
        })
    end
    return self:Register(id, widget)
end

function UIX:CreatePanel(parent, id, x, y, width, height, kind, opts)
    opts = type(opts) == "table" and opts or {}
    local factory = S.NativeObjectFactory
    if type(factory) ~= "table" or parent == nil then return nil, "native_factory_or_parent_unavailable" end
    local rootParent = IsRootParent(parent)
    local nativeParent = RootNativeParent(parent)
    local anchorParent = RootAnchorParent(parent)
    local stateParent = RootStateParent(parent)
    -- 交互顶层临时面必须真实 Window；RU 根 emptywidget 不可靠进入 system，弹层/菜单可能活跃却被应用窗口遮挡；树内普通面板仍 emptywidget。
    local transientWindow = rootParent == true and opts.transientWindow == true
    local panel, nativeErr
    if transientWindow then
        if type(factory.CreateWindow) ~= "function" then return nil, "transient_window_factory_unavailable" end
        panel, nativeErr = factory:CreateWindow(S.PhysicalId(id), "UIParent", "")
    else
        panel, nativeErr = factory:CreateEmptyWidget(S.PhysicalId(id), nativeParent)
    end
    if panel == nil then return nil, nativeErr or (transientWindow and "transient_window_create_failed" or "panel_create_failed") end
    TrackNativeBuildWidget(panel)
    local ownerParent = rootParent and nil or parent
    panel.rsHudOwner = ownerParent and ownerParent.rsHudOwner or nil
    -- 顶层弹层/提示/菜单物理父为 UIParent 保层级，逻辑归创建页面/组件；Register 前提供明确 owner，维持严格 V3 重复 ID/生命周期检查，不短暂注册成无主旧控件。
    panel.rsUiOwner = opts.owner or (ownerParent and (ownerParent.rsUiOwner or (ownerParent.rsHudOwner and ("hud:" .. tostring(ownerParent.rsHudOwner)))) or nil)
    panel.rsUiParent = stateParent
    panel.rsUiTransientWindow = transientWindow == true

    local function ApplyTransientWindowPolicy()
        if transientWindow ~= true then return true end
        -- 窗口策略与应用根一致：不能模态，也不让 Native Escape 绕过 V3 生命周期/持久化关闭。
        if type(panel.SetUILayer) == "function" then
            local ok, result = pcall(function() return panel:SetUILayer(tostring(opts.uiLayer or "system")) end)
            if ok ~= true or result == false then return false, "transient_window_layer_rejected" end
        end
        for _, row in ipairs({
            { method = "SetCloseOnEscape", value = false },
            { method = "SetWindowModal", value = false },
        }) do
            if type(panel[row.method]) == "function" then
                local ok = pcall(function() panel[row.method](panel, row.value) end)
                if ok ~= true then return false, "transient_window_policy_failed:" .. tostring(row.method) end
            end
        end
        local priority = tonumber(opts.drawPriority)
            or (S.UITokens and type(S.UITokens.Number) == "function" and S.UITokens:Number("layer.popupPriority", 10000))
            or 10000
        if type(panel.SetDrawPriority) == "function" then pcall(function() panel:SetDrawPriority(priority) end) end
        return true
    end

    local policyOk, policyErr = ApplyTransientWindowPolicy()
    if policyOk ~= true then
        return FailPrimitive(panel, id, tostring(policyErr or "transient_window_policy_failed"))
    end

    local configured, configureErr = pcall(function()
        panel:AddAnchor("TOPLEFT", anchorParent, x or 0, y or 0)
        panel:SetExtent(math.max(1, width or 1), math.max(1, height or 1))
        S.Theme:AddBorder(panel, kind == "soft")
        local theme = S.Constants and S.Constants.Theme or {}
        -- 卡片/表头/柔和面板默认现代渐变，Theme.modern 关闭或 {gradient=false} 明确退出；小覆盖条等平面外观须传 gradient=false。
        local useGradient = opts.gradient
        if useGradient == nil then
            useGradient = theme.modern ~= false
                and ((kind == "card" and theme.gradientPanels ~= false)
                    or (kind == "soft" and theme.gradientPanels ~= false)
                    or (kind == "header" and theme.gradientHeaders ~= false))
        end
        if useGradient == true then
            -- kind 同时选择 titlebar/header/card 渐变 band 集。
            local gradientKind = opts.gradientKind
                or (kind == "header" and "header" or (kind == "card" and "card" or (kind == "titlebar" and "titlebar" or nil)))
            S.Theme:AddGradientBackground(panel, gradientKind or kind, nil)
            -- 表头默认金色强调条，允许覆写。
            if kind == "header" and opts.accentStrip ~= false and theme.gradientHeaders ~= false then
                S.Theme:AddAccentStrip(panel, nil, nil)
            end
        else
            S.Theme:AddPanelBackground(panel, kind == "header" and "header" or (kind == "card" and "card" or nil))
        end
        if opts.accentStrip == true then
            S.Theme:AddAccentStrip(panel, nil, nil)
        elseif type(opts.accentStrip) == "number" then
            S.Theme:AddAccentStrip(panel, opts.accentStrip, nil)
        end
        if opts.divider ~= nil then
            S.Theme:AddDivider(panel, opts.divider, opts.dividerSoft == true)
        end
        if type(panel.Enable) == "function" then
            local accepted = CallNativeAccepted(panel, "Enable", true)
            if accepted ~= true then error("panel Enable rejected") end
        end
        local nativePickable = ConfigureNativePickable(panel, opts.pickable == true)
        if nativePickable ~= true then error("panel hit-test state unavailable") end
        panel:Show(opts.visible ~= false)
    end)
    if not configured then
        return FailPrimitive(panel, id, PrimitiveFailureDetail("panel_configuration_failed", configureErr))
    end
    if type(self.PrimeNativeState) == "function" then
        self:PrimeNativeState(panel, {
            width = math.max(1, width or 1), height = math.max(1, height or 1), visible = opts.visible ~= false, enabled = true,
            pickable = opts.pickable == true, anchorTopLeft = { parent = stateParent, x = x or 0, y = y or 0 },
        })
    end
    return self:Register(id, panel)
end

-- 单位连线/范围圆点池的非交互屏幕宿主必须为真实 Native WINDOW；RU emptywidget 不可见。
-- WINDOW 类型不代表 system 层；世界 HUD 固定 game 层，使 normal/dialog/system 原生窗口自然覆盖。
-- DrawPriority 仅负责 game 层内部排序，host 保持不可拾取，不截获鼠标。
-- 层级策略不改变投影坐标、子点、可见性或生命周期；不能为解决显示问题升到 system 遮挡背包/拍卖/地图。
function UIX:CreateOverlayWindow(id, explicitOwner)
    local factory = S.NativeObjectFactory
    if type(factory) ~= "table" or type(factory.CreateWindow) ~= "function" then return nil, "overlay_window_factory_unavailable" end
    local window, nativeErr = factory:CreateWindow(S.PhysicalId(id), "UIParent", "")
    if window == nil then return nil, nativeErr or "overlay_window_create_failed" end
    TrackNativeBuildWidget(window)
    window.rsHudOwner = nil
    window.rsUiOwner = explicitOwner ~= nil and tostring(explicitOwner) or nil
    window.rsUiParent = UIParent
    window.rsUiTransientWindow = true
    local configured, configureErr = pcall(function()
        if type(window.SetUILayer) == "function" then
            -- 维护（2026-09-17）：范围辅助/单位连线只应覆盖 3D 世界，不应覆盖原生窗口。
            -- Authority 在本 Primitive：所有 CreateOverlayWindow consumer 统一 game；Presenter 禁止另行升层。
            -- 若 Native 拒绝 game，fail-closed 隐藏/隔离 host，不能静默回退 system。
            local ok, result = pcall(function() return window:SetUILayer("game") end)
            if ok ~= true or result == false then error("overlay window layer rejected:game") end
        end
        for _, row in ipairs({
            { method = "SetCloseOnEscape", value = false },
            { method = "SetWindowModal", value = false },
        }) do
            if type(window[row.method]) == "function" then
                local ok = pcall(function() window[row.method](window, row.value) end)
                if ok ~= true then error("overlay window policy failed:" .. tostring(row.method)) end
            end
        end
        -- 绘制优先级属已验证 CreatePanel/popup 策略，缺少时窗口可能在应用/世界下方，全部子点不可见。
        local priority = S.UITokens and type(S.UITokens.Number) == "function" and S.UITokens:Number("layer.popupPriority", 10000) or 10000
        if type(window.SetDrawPriority) == "function" then pcall(function() window:SetDrawPriority(priority) end) end
        -- 维护（overlay-root-anchor-1）：实机日志在此拒绝 UIParent Table 参数。
        -- 复用同文件的根锚点转换，Native 用 "UIParent"，下方 Diff 缓存仍持有真实对象；
        -- 不改变层级、拾取、坐标或刷新频率。避免构造被隔离而影响世界 HUD 显示。
        if window.AddAnchor ~= nil then window:AddAnchor("TOPLEFT", RootAnchorParent(UIParent), 0, 0) end
        -- 参考宿主保持小尺寸，子点锚可越 extent（rp_ui.lua EnsureLinesHost SetExtent(200,200)）。
        if window.SetExtent ~= nil then window:SetExtent(200, 200) end
        if ConfigureNativePickable(window, false) ~= true then error("overlay window hit-test unavailable") end
        if window.CorrectOffsetByScreen ~= nil then pcall(function() window:CorrectOffsetByScreen() end) end
        window:Show(false)
    end)
    if not configured then
        return FailPrimitive(window, id, PrimitiveFailureDetail("overlay_window_configure_failed", configureErr))
    end
    if type(self.PrimeNativeState) == "function" then
        self:PrimeNativeState(window, {
            width = 200, height = 200, visible = false, enabled = true, pickable = false,
            anchorTopLeft = { parent = UIParent, x = 0, y = 0 },
        })
    end
    return self:Register(id, window)
end

function UIX:CreateLabel(parent, id, text, x, y, width, height, fontSize, tone, align, shadow)
    local factory = S.NativeObjectFactory
    if type(factory) ~= "table" or parent == nil then return nil, "native_factory_or_parent_unavailable" end
    local rootParent = IsRootParent(parent)
    if rootParent ~= true and type(parent.CreateChildWidget) ~= "function" then return nil, "CreateChildWidget unavailable" end
    local label, nativeErr
    if rootParent then
        label, nativeErr = factory:Create("label", S.PhysicalId(id), "UIParent")
    else
        label, nativeErr = factory:CreateChild(parent, "label", S.PhysicalId(id), 0, true)
    end
    if label == nil then return nil, nativeErr or "label_create_failed" end
    TrackNativeBuildWidget(label)
    local anchorParent = RootAnchorParent(parent)
    local stateParent = RootStateParent(parent)
    local ownerParent = rootParent and nil or parent
    label.rsHudOwner = ownerParent and ownerParent.rsHudOwner or nil
    label.rsUiOwner = ownerParent and (ownerParent.rsUiOwner or (ownerParent.rsHudOwner and ("hud:" .. tostring(ownerParent.rsHudOwner)))) or nil
    label.rsUiParent = stateParent
    label.rsBaseFontSize = tonumber(fontSize)
    local configured, configureErr = pcall(function()
        label:AddAnchor("TOPLEFT", anchorParent, x or 0, y or 0)
        if label.SetAutoResize ~= nil then label:SetAutoResize(false) end
        label:SetExtent(math.max(1, width or 1), math.max(1, height or 1))
        if ConfigureNativePickable(label, false) ~= true then error("label hit-test state unavailable") end
        -- fontSize>=13 标签默认细阴影，除总开关关闭或调用方显式 false。
        local theme = S.Constants and S.Constants.Theme or {}
        local useShadow = shadow
        if useShadow == nil then
            useShadow = theme.modern ~= false and theme.labelShadow ~= false and tonumber(fontSize) ~= nil and tonumber(fontSize) >= 13
        end
        S.Theme:StyleLabel(label, fontSize or (S.UITokens and S.UITokens:Number("font.body", 11)) or 11, tone, align, useShadow)
        label:SetText(tostring(text or ""))
        label:Show(true)
    end)
    if not configured then
        return FailPrimitive(label, id, PrimitiveFailureDetail("label_configuration_failed", configureErr))
    end
    if type(self.PrimeNativeState) == "function" then
        self:PrimeNativeState(label, {
            text = tostring(text or ""), width = math.max(1, width or 1), height = math.max(1, height or 1),
            visible = true, pickable = false, anchorTopLeft = { parent = stateParent, x = x or 0, y = y or 0 },
            fontSize = label.rsAppliedFontSize,
        })
    end
    return self:Register(id, label)
end

UIX.EditBoxCaretVisualContractVersion = 2
UIX.EditBoxNormalSelectionContractVersion = 1

local EDIT_BORDER_IDLE = { 0.34, 0.43, 0.52, 0.98 }
local EDIT_BORDER_FOCUS = { 0.88, 0.68, 0.28, 1.00 }

function UIX:SetEditBoxFocusVisual(edit, focused)
    if edit == nil then return false end
    focused = focused == true
    edit.rsUiInputFocusVisual = focused
    local border = edit.rsUiEditBorderDrawable
    if border ~= nil and type(border.SetColor) == "function" then
        local ok = pcall(function()
            if S.Theme and S.Theme.BindColorDrawable then S.Theme:BindColorDrawable(edit,border,focused and 'input.focus' or 'input.border')
            else local c = focused and EDIT_BORDER_FOCUS or EDIT_BORDER_IDLE;border:SetColor(c[1],c[2],c[3],c[4]) end
        end)
        if ok ~= true then return false end
    end
    return true
end

function UIX:ConfigureEditCaret(edit, height)
    if edit == nil then return false, nil end
    -- 约束（2026-09-14，RU 单行 EditBox caret 几何）：实机 .18.215 证明
    -- SetCursorHeight(14) 并不是 14px 最终高度，而会渲染为约 29px 的竖线（接近 2*N+1），
    -- 因此旧实现把“最终像素高度”直接传给 Native，导致 caret 穿过输入框下边界。这里统一把
    -- 目标视觉高度转换为 Native half-extent，并把最终视觉预算限制在单行输入框内部。Authority
    -- 仍由 Native 控制闪烁/选择，Suite 只设置颜色和有界几何；不在 Layout/Tick 中重复写。
    local outer = math.max(18, math.floor(tonumber(height) or 24))
    local desiredVisual = math.max(11, math.min(19, outer - 6))
    local nativeHalf = math.max(5, math.min(9, math.floor((desiredVisual - 1) * 0.5)))
    if type(edit.SetCursorColor) == "function" then
        -- 约束（2026-10-09）：布局只调光标几何，颜色仍遵循 Theme 的透明表面策略，不能恢复浅底深色。
        local c=S.Theme and type(S.Theme.ResolveTextColor)=='function' and S.Theme:ResolveTextColor('input.caret',edit) or (S.UITokens and S.UITokens.input and S.UITokens.input.caret) or {1,.82,.36,1};edit:SetCursorColor(unpack(c))
    end
    if type(edit.SetCursorHeight) == "function" then
        edit:SetCursorHeight(nativeHalf)
        edit.rsUiCursorHalfHeight = nativeHalf
        edit.rsUiCursorVisualBudget = nativeHalf * 2 + 1
        return true, nativeHalf
    end
    return true, nil
end

function UIX:CreateEditBox(parent, id, x, y, width, height, maxLength)
    if parent == nil or type(parent.CreateChildWidgetByType) ~= "function" then return nil end
    -- RU 单行输入 token 导出不一致，优先 X2_EDITBOX，再普通 EDITBOX；缺文本框不能破坏整个 Suite 布局。
    local factory = S.NativeObjectFactory
    if type(factory) ~= "table" or type(factory.CreateChildByObject) ~= "function" then return nil end
    local edit = factory:CreateChildByObject(parent, "X2_EDITBOX", S.PhysicalId(id), 0, true)
    if edit == nil then edit = factory:CreateChildByObject(parent, "EDITBOX", S.PhysicalId(id), 0, true) end
    if edit == nil then return nil end
    TrackNativeBuildWidget(edit)
    local anchorParent = RootAnchorParent(parent)
    local stateParent = RootStateParent(parent)
    edit.rsUiParent = stateParent
    edit.rsUiKeyboardInput = true
    edit.rsUiOwner = parent and (parent.rsUiOwner or (parent.rsHudOwner and ("hud:" .. tostring(parent.rsHudOwner)))) or nil
    local configured, configureErr = pcall(function()
        edit:SetExtent(math.max(1, width or 120), math.max(1, height or 26))
        if edit.SetInset ~= nil then edit:SetInset(5,5,5,5) end
        -- RU typed EditBox 初建未必可鼠标交互；共享 Native 边界负责命中/焦点，让 TextInput/NumericInput 继承同一契约。
        local accepted = CallNativeAccepted(edit, "Enable", true)
        if accepted ~= true then error("editbox Enable rejected") end
        accepted = CallNativeAccepted(edit, "EnableFocus", true)
        if accepted ~= true then error("editbox focus unavailable") end
        -- 仅构造 EditBox 不能抢 ArcheAge 移动/技能键；通过 RSUI 输入生命周期明确点击后才启键盘。
        accepted = CallNativeAccepted(edit, "EnableKeyboard", false)
        if accepted ~= true then error("editbox keyboard inert state unavailable") end
        edit.rsUiKeyboardArmed = false
        if ConfigureNativePickable(edit, true) ~= true then error("editbox hit-test unavailable") end
        if edit.SetReClickable ~= nil then
            accepted = CallNativeAccepted(edit, "SetReClickable", true)
            if accepted ~= true then error("editbox reclick rejected") end
        end
        if edit.SetReadOnly ~= nil then
            accepted = CallNativeAccepted(edit, "SetReadOnly", false)
            if accepted ~= true then error("editbox readonly state rejected") end
        end
        if edit.UseSelectAllWhenFocused ~= nil then edit:UseSelectAllWhenFocused(false) end
        UIX:ConfigureEditCaret(edit, height)
        -- RSUI 持有 Draft -> Commit；部分 RU EditBox Enter 会在处理器读取前清 Native 文本，须关闭此已验证标志。
        if edit.ClearTextOnEnter ~= nil then
            accepted = CallNativeAccepted(edit, "ClearTextOnEnter", false)
            if accepted ~= true then error("editbox clear-on-enter state rejected") end
        end
        if edit.SetMaxTextLength ~= nil then edit:SetMaxTextLength(math.max(1, tonumber(maxLength) or 64)) end
        if edit.style ~= nil then
            if edit.style.SetAlign ~= nil then edit.style:SetAlign(ALIGN_LEFT) end
            if edit.style.SetColor ~= nil then edit.style:SetColor(1.00,0.96,0.84,1.00) end
        end
        if edit.CreateColorDrawable ~= nil then
            local border=edit:CreateColorDrawable(EDIT_BORDER_IDLE[1],EDIT_BORDER_IDLE[2],EDIT_BORDER_IDLE[3],EDIT_BORDER_IDLE[4],"background")
            edit.rsUiEditBorderDrawable = border
            if border and border.AddAnchor then border:AddAnchor("TOPLEFT",edit,0,0); border:AddAnchor("BOTTOMRIGHT",edit,0,0) end
            local bg=edit:CreateColorDrawable(0.015,0.022,0.032,0.995,"background")
            edit.rsUiEditBackgroundDrawable=bg
            if bg and bg.AddAnchor then bg:AddAnchor("TOPLEFT",edit,1,1); bg:AddAnchor("BOTTOMRIGHT",edit,-1,-1) end
            -- 原生输入底板显式归入背景通道，避免透明页面变亮字后仍留一块不透明浅底。
            if S.Theme and S.Theme.BindColorDrawable then S.Theme:BindColorDrawable(edit,bg,'input.background',nil,'background') end
        end
        if S.Theme and S.Theme.RefreshTextColor then edit.rsThemeTextRole='input.text';S.Theme:RefreshTextColor(edit) end
        edit:AddAnchor("TOPLEFT", anchorParent, x or 0, y or 0)
        edit:Show(true)
        UIX:SetEditBoxFocusVisual(edit, false)
    end)
    if not configured then
        return FailPrimitive(edit, id, PrimitiveFailureDetail("editbox_configuration_failed", configureErr))
    end
    if type(self.PrimeNativeState) == "function" then
        self:PrimeNativeState(edit, {
            width = math.max(1, width or 120), height = math.max(1, height or 26),
            visible = true, enabled = true, pickable = true,
            anchorTopLeft = { parent = stateParent, x = x or 0, y = y or 0 },
        })
    end
    return self:Register(id, edit)
end

function UIX:CreateMultiEditBox(parent, id, x, y, width, height, maxLength)
    if parent == nil or type(parent.CreateChildWidgetByType) ~= "function" then return nil end
    local factory = S.NativeObjectFactory
    if type(factory) ~= "table" or type(factory.CreateChildByObject) ~= "function" then return nil end
    local edit = factory:CreateChildByObject(parent, "EDITBOX_MULTILINE", S.PhysicalId(id), 0, true)
    if edit == nil then return nil end
    TrackNativeBuildWidget(edit)
    local anchorParent = RootAnchorParent(parent)
    local stateParent = RootStateParent(parent)
    edit.rsUiParent = stateParent
    edit.rsUiKeyboardInput = true
    edit.rsUiOwner = parent and (parent.rsUiOwner or (parent.rsHudOwner and ("hud:" .. tostring(parent.rsHudOwner)))) or nil
    local configured, configureErr = pcall(function()
        edit:SetExtent(math.max(1, width or 220), math.max(1, height or 96))
        if edit.SetInset ~= nil then edit:SetInset(8,8,10,8) end
        -- EDITBOX_MULTILINE 继承 WidgetBase 交互标志，但 RU 参考无 Edit:SetReClickable；仅配置已验证共享 WidgetBase/Editmultiline 接口。
        local accepted = CallNativeAccepted(edit, "Enable", true)
        if accepted ~= true then error("multieditbox Enable rejected") end
        accepted = CallNativeAccepted(edit, "EnableFocus", true)
        if accepted ~= true then error("multieditbox focus unavailable") end
        -- 与单行共用延迟键盘契约，隐藏页签在明确点击前保持键盘静默。
        accepted = CallNativeAccepted(edit, "EnableKeyboard", false)
        if accepted ~= true then error("multieditbox keyboard inert state unavailable") end
        edit.rsUiKeyboardArmed = false
        if ConfigureNativePickable(edit, true) ~= true then error("multieditbox hit-test unavailable") end
        if edit.SetReadOnly ~= nil then
            accepted = CallNativeAccepted(edit, "SetReadOnly", false)
            if accepted ~= true then error("multieditbox readonly state rejected") end
        end
        if edit.UseSelectAllWhenFocused ~= nil then edit:UseSelectAllWhenFocused(false) end
        UIX:ConfigureEditCaret(edit, height)
        if edit.SetMaxTextLength ~= nil then edit:SetMaxTextLength(math.max(1, tonumber(maxLength) or 65535)) end
        if edit.style ~= nil then
            if edit.style.SetAlign ~= nil then edit.style:SetAlign(ALIGN_TOP_LEFT or ALIGN_LEFT) end
            if edit.style.SetColor ~= nil then edit.style:SetColor(1.00,0.96,0.84,1.00) end
        end
        if edit.guideTextStyle ~= nil and edit.guideTextStyle.SetAlign ~= nil then
            edit.guideTextStyle:SetAlign(ALIGN_TOP_LEFT or ALIGN_LEFT)
        end
        if edit.CreateColorDrawable ~= nil then
            local border=edit:CreateColorDrawable(EDIT_BORDER_IDLE[1],EDIT_BORDER_IDLE[2],EDIT_BORDER_IDLE[3],EDIT_BORDER_IDLE[4],"background")
            edit.rsUiEditBorderDrawable = border
            if border and border.AddAnchor then border:AddAnchor("TOPLEFT",edit,0,0); border:AddAnchor("BOTTOMRIGHT",edit,0,0) end
            local bg=edit:CreateColorDrawable(0.015,0.022,0.032,0.995,"background")
            edit.rsUiEditBackgroundDrawable=bg
            if bg and bg.AddAnchor then bg:AddAnchor("TOPLEFT",edit,1,1); bg:AddAnchor("BOTTOMRIGHT",edit,-1,-1) end
            if S.Theme and S.Theme.BindColorDrawable then S.Theme:BindColorDrawable(edit,bg,'input.background',nil,'background') end
        end
        if S.Theme and S.Theme.RefreshTextColor then edit.rsThemeTextRole='input.text';S.Theme:RefreshTextColor(edit) end
        edit:AddAnchor("TOPLEFT", anchorParent, x or 0, y or 0)
        edit:Show(true)
        UIX:SetEditBoxFocusVisual(edit, false)
    end)
    if not configured then
        return FailPrimitive(edit, id, PrimitiveFailureDetail("multieditbox_configuration_failed", configureErr))
    end
    if type(self.PrimeNativeState) == "function" then
        self:PrimeNativeState(edit, {
            width = math.max(1, width or 220), height = math.max(1, height or 96),
            visible = true, enabled = true, pickable = true,
            anchorTopLeft = { parent = stateParent, x = x or 0, y = y or 0 },
        })
    end
    return self:Register(id, edit)
end

function UIX:EnsureHorizontalSlider(slider)
    -- 旧 UI2 前调用方兼容垫片；Suite 滑块用可移动 EmptyWidget 而非 Native Slider，仅取 X delta，原生 Slider 朝向不影响拖动轴。
    return slider ~= nil and slider.rsCustomHorizontal == true
end

local function ClampSliderValue(slider, value)
    local minimum = tonumber(slider and slider.rsMinimum) or 0
    local maximum = tonumber(slider and slider.rsMaximum) or 100
    if maximum < minimum then minimum, maximum = maximum, minimum end
    local step = math.abs(tonumber(slider and slider.rsStep) or 1)
    local v = tonumber(value) or minimum
    if step > 0 then
        v = minimum + math.floor(((v - minimum) / step) + 0.5) * step
    end
    if v < minimum then v = minimum end
    if v > maximum then v = maximum end
    return v
end

function UIX:UpdateSliderVisual(slider, explicitValue)
    if slider == nil then return false end
    local thumb = slider.rsThumbButton
    if thumb == nil then return false end
    local minimum = tonumber(slider.rsMinimum) or 0
    local maximum = tonumber(slider.rsMaximum) or 100
    local value = ClampSliderValue(slider, explicitValue ~= nil and explicitValue or slider.rsValue)
    slider.rsValue = value
    local width = slider.GetWidth and slider:GetWidth() or tonumber(slider.rsWidth) or 140
    local height = slider.GetHeight and slider:GetHeight() or tonumber(slider.rsHeight) or 20
    local dragging = slider.rsDragging == true

    -- 自定义滑块为组合，根缩放不自动缩 rail/drag；单独缓存视觉几何，让 SetExtent 低成本同步旧子节点，无永久 OnUpdate/Tick。
    if tonumber(slider.rsVisualWidth) == tonumber(width)
        and tonumber(slider.rsVisualHeight) == tonumber(height)
        and tonumber(slider.rsVisualValue) == tonumber(value)
        and slider.rsVisualDragging == dragging then
        slider.rsWidth, slider.rsHeight = width, height
        return false
    end

    slider.rsWidth, slider.rsHeight = width, height
    local track = slider.rsTrack
    if track ~= nil then
        if track.RemoveAllAnchors ~= nil then track:RemoveAllAnchors() end
        if track.SetExtent ~= nil then track:SetExtent(math.max(1, width - 12), 4) end
        if track.AddAnchor ~= nil then track:AddAnchor("TOPLEFT", slider, 6, math.max(0, math.floor((height - 4) / 2))) end
    end
    local thumbW = math.max(10, tonumber(slider.rsThumbWidth) or 18)
    local thumbH = math.max(10, math.min(height, tonumber(slider.rsThumbHeight) or 14))
    local travel = math.max(1, width - thumbW)
    local ratio = maximum > minimum and ((value - minimum) / (maximum - minimum)) or 0
    local tx = math.floor(travel * ratio + 0.5)
    local ty = math.max(0, math.floor((height - thumbH) / 2))
    if thumb.RemoveAllAnchors ~= nil then thumb:RemoveAllAnchors() end
    if thumb.AddAnchor ~= nil then thumb:AddAnchor("TOPLEFT", slider, tx, ty) end
    if thumb.SetExtent ~= nil then thumb:SetExtent(thumbW, thumbH) end
    if thumb.Raise ~= nil then pcall(function() thumb:Raise() end) end

    -- 拖动面刻意不可见，按鼠标时可纵向移动；仅事务结束重锚，期间有效 X 作为光标替代。
    local drag = slider.rsDragSurface
    if drag ~= nil and slider.rsDragging ~= true then
        if drag.RemoveAllAnchors ~= nil then drag:RemoveAllAnchors() end
        if drag.SetExtent ~= nil then drag:SetExtent(width, height) end
        if drag.AddAnchor ~= nil then drag:AddAnchor("TOPLEFT", slider, 0, 0) end
        if drag.Raise ~= nil then pcall(function() drag:Raise() end) end
    end
    slider.rsVisualWidth = width
    slider.rsVisualHeight = height
    slider.rsVisualValue = value
    slider.rsVisualDragging = dragging
    return true
end

function UIX:CreateSlider(parent, id, x, y, width, height, minimum, maximum, step, value)
    if parent == nil or type(parent.CreateChildWidget) ~= "function" then return nil end

    -- 禁止 UOT_SLIDER，RU 即便 SetOrientation("HORIZONTAL") 仍可能纵轴拖动；
    -- 透明移动面自行实现横拖，StartMoving 提供移动，仅 X delta 改值，完全忽略 Y。
    local slider = S.NativeObjectFactory and S.NativeObjectFactory:CreateChild(parent, "emptywidget", S.PhysicalId(id), 0, true) or nil
    if slider == nil then return nil end
    TrackNativeBuildWidget(slider)

    local configured, configureErr = pcall(function()
        local sliderW = math.max(30, tonumber(width) or 140)
        local sliderH = math.max(14, tonumber(height) or 20)
        slider:SetExtent(sliderW, sliderH)
        slider:AddAnchor("TOPLEFT", parent, x or 0, y or 0)
        slider.rsCustomHorizontal = true
        slider.rsMinimum = tonumber(minimum) or 0
        slider.rsMaximum = tonumber(maximum) or 100
        slider.rsStep = math.abs(tonumber(step) or 1)
        slider.rsWidth = sliderW
        slider.rsHeight = sliderH
        slider.rsThumbWidth = 18
        slider.rsThumbHeight = math.max(12, math.min(16, sliderH - 2))
        slider.rsValue = ClampSliderValue(slider, value)
        slider.rsDragging = false
        slider.rsEnabled = true
        slider.rsValueChanged = nil
        slider.rsNotifyElapsed = 0

        if slider.CreateColorDrawable ~= nil then
            local track = slider:CreateColorDrawable(0.26, 0.31, 0.37, 0.95, "background")
            slider.rsTrack = track
            if S.Theme and S.Theme.BindColorDrawable then S.Theme:BindColorDrawable(slider,track,'slider.track') end
        end

        local thumb = S.NativeObjectFactory:CreateChild(slider, "emptywidget", S.PhysicalId(id .. "_thumb"), 0, true)
        if thumb == nil then error("slider thumb creation failed") end
        thumb:SetExtent(slider.rsThumbWidth, slider.rsThumbHeight)
        pcall(function() ConfigureNativePickable(thumb, false) end)
        if thumb.CreateColorDrawable ~= nil then
            local outer = thumb:CreateColorDrawable(0.82, 0.68, 0.34, 1.00, "artwork")
            if outer and outer.AddAnchor then outer:AddAnchor("TOPLEFT", thumb, 0, 0); outer:AddAnchor("BOTTOMRIGHT", thumb, 0, 0) end
            local inner = thumb:CreateColorDrawable(0.18, 0.21, 0.25, 0.98, "artwork")
            if inner and inner.AddAnchor then inner:AddAnchor("TOPLEFT", thumb, 2, 2); inner:AddAnchor("BOTTOMRIGHT", thumb, -2, -2) end
            if S.Theme and S.Theme.BindColorDrawable then
                S.Theme:BindColorDrawable(slider,outer,'slider.thumbBorder');S.Theme:BindColorDrawable(slider,inner,'slider.thumb')
            end
        end
        slider.rsThumbButton = thumb
        thumb:Show(true)

        -- 全宽透明拖动面可在 Native 双轴移动但不可见，仅采有效 X；可见滑块始终放横轨，纵拖不能改值或视觉 Y。
        local drag = S.NativeObjectFactory:CreateChild(slider, "emptywidget", S.PhysicalId(id .. "_drag"), 0, true)
        if drag == nil then error("slider drag surface creation failed") end
        drag:SetExtent(sliderW, sliderH)
        drag:AddAnchor("TOPLEFT", slider, 0, 0)
        local accepted = CallNativeAccepted(drag, "Enable", true)
        if accepted ~= true then error("slider drag Enable rejected") end
        if ConfigureNativePickable(drag, true) ~= true then error("slider drag hit-test unavailable") end
        accepted = CallNativeAccepted(drag, "EnableDrag", true)
        if accepted ~= true then error("slider drag EnableDrag rejected") end
        if type(drag.StartMoving) ~= "function" then error("slider drag StartMoving unavailable") end
        if type(drag.StopMovingOrSizing) ~= "function" then error("slider drag StopMovingOrSizing unavailable") end
        if drag.SetDragCondition ~= nil and DC_ALWAYS ~= nil then
            accepted = CallNativeAccepted(drag, "SetDragCondition", DC_ALWAYS)
            if accepted ~= true then error("slider drag condition rejected") end
        end
        if drag.CreateColorDrawable ~= nil then
            local hit = drag:CreateColorDrawable(0, 0, 0, 0.001, "overlay")
            if hit and hit.AddAnchor then hit:AddAnchor("TOPLEFT", drag, 0, 0); hit:AddAnchor("BOTTOMRIGHT", drag, 0, 0) end
        end
        slider.rsDragSurface = drag

        function slider:GetValue()
            return tonumber(self.rsValue) or tonumber(self.rsMinimum) or 0
        end
        function slider:SetValue(v, notify)
            local nv = ClampSliderValue(self, v)
            local changed = nv ~= self.rsValue
            self.rsValue = nv
            UIX:UpdateSliderVisual(self, nv)
            if changed and notify == true and type(self.rsValueChanged) == "function" then
                self.rsValueChanged(nv, false)
            end
            return nv
        end
        -- 自适应范围仅 NumericInput 提交事件更新；扩端点不能重建 Native Slider，同一拖动面/滑块保持附着，避免悬浮/拖动状态抖动。
        function slider:SetRange(minimumValue, maximumValue, stepValue)
            local minimumNext = tonumber(minimumValue)
            local maximumNext = tonumber(maximumValue)
            if minimumNext == nil or maximumNext == nil then return false, "invalid_slider_range" end
            if maximumNext < minimumNext then minimumNext, maximumNext = maximumNext, minimumNext end
            if self.rsDragging == true then return false, "slider_drag_active" end
            local stepNext = math.abs(tonumber(stepValue) or tonumber(self.rsStep) or 1)
            local changed = tonumber(self.rsMinimum) ~= minimumNext or tonumber(self.rsMaximum) ~= maximumNext or tonumber(self.rsStep) ~= stepNext
            self.rsMinimum, self.rsMaximum, self.rsStep = minimumNext, maximumNext, stepNext
            self.rsValue = ClampSliderValue(self, self.rsValue)
            UIX:UpdateSliderVisual(self, self.rsValue)
            return true, changed
        end
        function slider:GetRange()
            return tonumber(self.rsMinimum), tonumber(self.rsMaximum), tonumber(self.rsStep)
        end
        function slider:SetValueChangedHandler(fn)
            self.rsValueChanged = type(fn) == "function" and fn or nil
        end

        local dragTaskName = "ui_custom_slider:" .. tostring(id)
        local function StopSliderInteraction(target, restorePreview)
            if target == nil then return end
            if S.Scheduler ~= nil and type(S.Scheduler.RemoveTask) == "function" then S.Scheduler:RemoveTask(dragTaskName) end
            if type(drag.ReleaseHandler) == "function" then pcall(function() drag:ReleaseHandler("OnUpdate") end) end
            if target.rsDragging == true and type(drag.StopMovingOrSizing) == "function" then
                pcall(function() drag:StopMovingOrSizing() end)
            end
            if restorePreview == true and target.rsDragStartValue ~= nil then target.rsValue = target.rsDragStartValue end
            target.rsDragging = false
            target.rsDragStartX, target.rsDragStartValue = nil, nil
            UIX:UpdateSliderVisual(target, target.rsValue)
        end

        local function ApplySliderEnabled(target, enabled)
            target.rsEnabled = enabled ~= false
            if target.rsEnabled ~= true then StopSliderInteraction(target, true) end
            local accepted = CallNativeAccepted(drag, "Enable", target.rsEnabled)
            if accepted ~= true then error("slider drag Enable rejected") end
            if ConfigureNativePickable(drag, target.rsEnabled) ~= true then error("slider drag hit-test unavailable") end
            if target.rsTrack ~= nil and type(target.rsTrack.SetColor) == "function" then
                if S.Theme and S.Theme.BindColorDrawable then S.Theme:BindColorDrawable(target,target.rsTrack,target.rsEnabled and 'slider.track' or 'slider.disabled')
                elseif target.rsEnabled then target.rsTrack:SetColor(0.26, 0.31, 0.37, 0.95)
                else target.rsTrack:SetColor(0.16, 0.18, 0.21, 0.55) end
            end
            if target.rsThumbButton ~= nil and target.rsThumbButton.Show ~= nil then target.rsThumbButton:Show(true) end
            UIX:UpdateSliderVisual(target, target.rsValue)
            return true, target.rsEnabled
        end
        -- UI:SetEnabled 通常作用根，但此组合实际命中为透明拖动子节点，须明确适配器；仅根 Enable(false) 会留下视觉禁用仍交互的 Slider。
        slider.rsUiSetEnabledAdapter = ApplySliderEnabled
        function slider:SetEnabled(enabled) return ApplySliderEnabled(self, enabled) end

        local function EffectiveX(widget)
            if widget == nil then return nil end
            if type(widget.GetEffectiveOffset) == "function" then
                local okOffset, ox = pcall(function() local xx = widget:GetEffectiveOffset(); return xx end)
                if okOffset and tonumber(ox) ~= nil then return tonumber(ox) end
            end
            if type(widget.GetOffset) == "function" then
                local okOffset, ox = pcall(function() local xx = widget:GetOffset(); return xx end)
                if okOffset and tonumber(ox) ~= nil then return tonumber(ox) end
            end
            return nil
        end

        local function SyncFromDrag(final)
            if slider.rsDragging ~= true and final ~= true then return end
            local currentX = EffectiveX(drag)
            local startX = tonumber(slider.rsDragStartX)
            if currentX == nil or startX == nil then return end
            local range = (tonumber(slider.rsMaximum) or 100) - (tonumber(slider.rsMinimum) or 0)
            local thumbW = math.max(10, tonumber(slider.rsThumbWidth) or 18)
            local currentW = slider.GetWidth and slider:GetWidth() or slider.rsWidth
            local travel = math.max(1, (tonumber(currentW) or sliderW) - thumbW)
            local startValue = tonumber(slider.rsDragStartValue) or tonumber(slider.rsValue) or 0
            local nv = ClampSliderValue(slider, startValue + ((currentX - startX) / travel) * range)
            local changed = nv ~= slider.rsValue
            slider.rsValue = nv
            UIX:UpdateSliderVisual(slider, nv)
            if changed and type(slider.rsValueChanged) == "function" then
                slider.rsValueChanged(nv, final == true)
            elseif final == true and type(slider.rsValueChanged) == "function" then
                -- 量化回同值也提交，使暂存预览获得最终持久化边界。
                slider.rsValueChanged(nv, true)
            end
        end

        local dragStartBound = UIX:SafeHandler(drag, "OnDragStart", function()
            if slider.rsEnabled == false then return false end
            local moving = CallNativeAccepted(drag, "StartMoving")
            if moving ~= true then return false end
            slider.rsDragging = true
            slider.rsDragStartX = EffectiveX(drag)
            slider.rsDragStartValue = slider.rsValue
            -- 手势期间借单一 Suite 帧驱动，普通服务保 50 ms 下限，滑块可约 16 ms 预览而不常驻 Tick。
            local scheduled = false
            if S.Scheduler ~= nil and type(S.Scheduler.AddInteractiveTask) == "function" then
                S.Scheduler:RemoveTask(dragTaskName)
                scheduled = S.Scheduler:AddInteractiveTask(dragTaskName, 16, function()
                    if slider.rsUiReleased == true then
                        slider.rsDragging = false
                        if S.Scheduler ~= nil then S.Scheduler:RemoveTask(dragTaskName) end
                        return true
                    end
                    if slider.rsDragging == true then SyncFromDrag(false) end
                    return true
                end, true, slider, "P0", 1) == true
            end
            if scheduled ~= true then
                -- 启动早期与 Scheduler 拒绝的兜底仅本手势存在，停止即释放，闲置滑块无永久 OnUpdate/Tick。
                UIX:SafeHandler(drag, "OnUpdate", function()
                    if slider.rsDragging == true then SyncFromDrag(false) end
                    return true
                end, "slider:" .. tostring(id) .. ":drag_update_fallback")
            end
            SyncFromDrag(false)
            return true
        end, "slider:" .. tostring(id) .. ":drag_start")
        if dragStartBound ~= true then error("slider OnDragStart binding failed") end

        local dragStopBound = UIX:SafeHandler(drag, "OnDragStop", function()
            SyncFromDrag(true)
            StopSliderInteraction(slider, false)
            return true
        end, "slider:" .. tostring(id) .. ":drag_stop")
        if dragStopBound ~= true then error("slider OnDragStop binding failed") end

        UIX:UpdateSliderVisual(slider, slider.rsValue)
        drag:Show(true)
        slider:Show(true)
    end)
    if not configured then
        return FailPrimitive(slider, id, PrimitiveFailureDetail("slider_configuration_failed", configureErr))
    end
    slider.rsUiOwner = parent and (parent.rsUiOwner or (parent.rsHudOwner and ("hud:" .. tostring(parent.rsHudOwner)))) or nil
    if type(self.PrimeNativeState) == "function" then
        self:PrimeNativeState(slider, { width = math.max(20, tonumber(width) or 140), height = math.max(14, tonumber(height) or 20), visible = true, anchorTopLeft = { parent = parent, x = x or 0, y = y or 0 } })
    end
    return self:Register(id, slider)
end

function UIX:CreateButton(parent, id, text, x, y, width, height, fontSize, active, useGradient, explicitOwner)
    local factory = S.NativeObjectFactory
    if type(factory) ~= "table" then return nil, "native_factory_unavailable" end

    -- RU UIParent 并非普通子宿主；顶层屏幕控件须 UIParent:CreateWidget（CreateButton），树内仍 CreateChildWidget。
    -- 根按钮当子创建可静默 nil，导致 Gear 有状态却无控件。
    local rootParent = IsRootParent(parent)
    local anchorTarget = RootAnchorParent(parent)
    local anchorStateParent = RootStateParent(parent)
    local button, nativeErr
    if rootParent then
        button, nativeErr = factory:CreateButton(S.PhysicalId(id), "UIParent", "")
    else
        button, nativeErr = factory:CreateChild(parent, "button", S.PhysicalId(id), 0, true)
    end
    if button == nil then return nil, nativeErr or "button_create_failed" end
    TrackNativeBuildWidget(button)

    local ownerParent = rootParent and nil or parent
    button.rsHudOwner = ownerParent and ownerParent.rsHudOwner or nil
    button.rsUiOwner = explicitOwner or (ownerParent and (ownerParent.rsUiOwner or (ownerParent.rsHudOwner and ("hud:" .. tostring(ownerParent.rsHudOwner)))) or nil)
    button.rsUiParent = anchorStateParent
    button.rsBaseFontSize = tonumber(fontSize)
    local configured, configureErr = pcall(function()
        button:SetText(tostring(text or ""))
        S.Theme:StyleButton(button, width, height or (S.UITokens and S.UITokens:Number("size.buttonH", 26)) or 26, fontSize or (S.UITokens and S.UITokens:Number("font.body", 11)) or 11, active, useGradient)
        button:AddAnchor("TOPLEFT", anchorTarget, x or 0, y or 0)
        local accepted = CallNativeAccepted(button, "Enable", true)
        if accepted ~= true then error("button Enable rejected") end
        if ConfigureNativePickable(button, true) ~= true then error("button hit-test unavailable") end
        button:Show(true)
    end)
    if not configured then
        return FailPrimitive(button, id, PrimitiveFailureDetail("button_configuration_failed", configureErr))
    end
    if type(self.PrimeNativeState) == "function" then
        self:PrimeNativeState(button, {
            text = tostring(text or ""), width = math.max(1, width or 80), height = math.max(1, height or 26),
            visible = true, enabled = true, pickable = true, anchorTopLeft = { parent = anchorStateParent, x = x or 0, y = y or 0 },
            fontSize = button.rsAppliedFontSize,
        })
    end
    return self:Register(id, button)
end
