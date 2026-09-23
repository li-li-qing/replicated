------------------------------------------------------------------------
-- Replicated Suite V3 - Module page controls
-- 维护（module-controls-diag-2，2026-09-18）：页面开关/诊断原先散落在标题、卡片、保护页里。
-- PageHost 在滚动正文外为每个路由创建一个左上角控制条；业务页只领取同一按钮引用，
-- 不重设 Native parent、不复制 Enabled 状态、不复制 Consumer 启停流程。原页面 Command/
-- ActionRunner 仍拥有启停事务；FeatureRuntime 是运行状态 Authority，Registry 是性能预估元数据。
-- 只在构建、路由切换、生命周期事件、显式点击后刷新薄状态；无 Tick、Native 扫描或后台取证。
-- 诊断可观察关闭/故障模块；创建或点击诊断绝不能顺带 Initialize/Enable/AcquireConsumer。
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local RSUI = S.RSUI
if type(RSUI) ~= "table" then return end
S.UIV3 = S.UIV3 or {}
local M = { version = 1, contractVersion = 1 }
S.UIV3.ModuleControlsV3 = M

local function SetText(control, text)
    if control and type(control.SetText) == "function" and control.text ~= text then control:SetText(text) end
end
local function SetEnabled(control, value)
    if control and type(control.SetEnabled) == "function" and control.enabled ~= value then control:SetEnabled(value) end
end

function M:ControlId(meta)
    if type(meta) ~= "table" then return nil end
    if meta.controlFeatureId ~= nil then return meta.controlFeatureId ~= "" and meta.controlFeatureId or nil end
    if meta.lifecycle == "shell" or meta.category == "system" or tostring(meta.id):sub(1, 7) == "system_" then return nil end
    return meta.id
end

function M:ReadState(id)
    local runtime = S.FeatureRuntime
    if id == nil or type(runtime) ~= "table" then return { implemented = false, enabled = false } end
    if type(runtime.GetControlState) == "function" then return runtime:GetControlState(id) end
    -- 兼容隔离页面/旧宿主：只调用廉价布尔查询，不以 GetSnapshot/GetHealth 代替状态读取。
    return { implemented = type(runtime.IsImplemented) == "function" and runtime:IsImplemented(id) == true,
        enabled = type(runtime.IsEnabled) == "function" and runtime:IsEnabled(id) == true }
end

function M:OpenDiagnostics(moduleId, route)
    local window = S.UIV3 and S.UIV3.ModuleDiagnosticsWindowV3
    if type(window) ~= "table" or type(window.Open) ~= "function" then return false, "模块诊断窗口不可用" end
    local ok, accepted, err = pcall(window.Open, window, moduleId)
    if not ok or accepted ~= true then
        local detail = ok and err or accepted
        if S.DiagnosticsManager and type(S.DiagnosticsManager.Error) == "function" then
            S.DiagnosticsManager:Error("ui_v3", "MODULE_DIAGNOSTICS_OPEN_FAILED", "模块诊断窗口打开失败",
                { moduleId = moduleId, route = route, error = tostring(detail or "unknown") })
        end
        return false, detail
    end
    return true
end

function M:Create(parent, route, meta)
    local id = "v3_module_controls_" .. tostring(route):gsub("[^%w_]", "_")
    local bar = { route = route, meta = meta, featureId = self:ControlId(meta),
        actionMetrics = { clicks = 0, completed = 0, rejected = 0, lastError = nil }, actionReady = false }
    bar.root = RSUI:HorizontalBox({ id = id, parent = parent, gap = 6,
        slot = { hAlign = "fill", vAlign = "fill" } })
    if not bar.root then return nil, "module_controls_root_failed" end
    local controlMeta = bar.featureId and S.FeatureRegistry and S.FeatureRegistry:Get(bar.featureId) or meta
    bar.controlMeta = controlMeta
    if bar.featureId then
        -- 中文维护注释（2026-09-20，module-toggle-native-trampoline-1）：和同一控制条里一直可用的
        -- “诊断”按钮保持一致，启动按钮在 Native Button 创建当下就必须拥有 OnClick 逻辑。后续页面
        -- 只替换 bar.invoke 指向的业务动作，不再依赖“按钮创建后再装回调”。这样 Authority 仍是
        -- FeatureRuntime，但 Native 事件入口在整个控件生命周期内保持稳定。无 Tick/轮询，仅用户点击执行。
        bar.trampoline = function(...)
            local metrics = bar.actionMetrics
            metrics.clicks = (tonumber(metrics.clicks) or 0) + 1
            if type(bar.invoke) ~= "function" then
                metrics.rejected = (tonumber(metrics.rejected) or 0) + 1
                metrics.lastError = "module_toggle_action_not_ready"
                return false, metrics.lastError
            end
            return bar.invoke(...)
        end
        bar.toggle = RSUI:Button({ id = id .. "_toggle", parent = bar.root, text = "启动", compact = true,
            slot = { size = "fixed", width = 92 }, onClick = bar.trampoline })
        bar.performance = RSUI:Text({ id = id .. "_performance", parent = bar.root,
            text = "性能：" .. tostring(controlMeta and controlMeta.performanceLabel or "中") .. "（预估）",
            fontSize = 10, tone = "muted", overflow = "ellipsis", slot = { size = "fixed", width = 154 } })
        if not bar.toggle or not bar.performance then return nil, "module_controls_action_failed" end
    end
    local moduleId = bar.featureId or (meta and meta.id)
    if moduleId and moduleId ~= "system_diagnostics" then
        bar.diagnostics = RSUI:Button({ id = id .. "_diagnostics", parent = bar.root, text = "诊断", compact = true,
            slot = { size = "fixed", width = 64 }, onClick = function() return M:OpenDiagnostics(moduleId, route) end })
        if not bar.diagnostics then return nil, "module_controls_diagnostics_failed" end
    end
    bar.status = RSUI:Text({ id = id .. "_status", parent = bar.root,
        text = bar.featureId and "状态读取中" or "系统页面 · 无独立运行开关", fontSize = 10, tone = "muted",
        overflow = "ellipsis", slot = { size = "fill", fill = 1 } })
    if not bar.status then return nil, "module_controls_status_failed" end
    return bar
end

function M:Refresh(bar)
    if not bar or not bar.featureId then return true end
    local state = self:ReadState(bar.featureId)
    local blocked = bar.controlMeta and bar.controlMeta.runtimeBlocked == true
    local unavailable = bar.page and bar.page.persistenceUnavailable == true
    local enabled = state.enabled == true
    -- 仅缓存薄状态供模块诊断读取；绝不触发 GetHealth/Store Load/API 调用。
    bar.lastControlState = { implemented = state.implemented == true, initialized = state.initialized == true,
        enabled = enabled, faulted = state.faulted == true, blocked = blocked, unavailable = unavailable,
        lastError = state.lastError }
    SetText(bar.toggle, enabled and "关闭" or "启动")
    if type(bar.toggle.SetStatusTone) == "function" then bar.toggle:SetStatusTone(enabled and "green" or "red") end
    -- 保护/未实现不能被新按钮解锁；运行中的故障模块仍允许尝试正常停用。
    if not bar.inAction then SetEnabled(bar.toggle, enabled or (state.implemented == true and not blocked and not unavailable)) end
    local label = enabled and "已开启" or "未开启"
    if blocked then label = label .. " · 暂不可用"
    elseif unavailable then label = label .. " · 配置读取受保护"
    elseif state.faulted then label = label .. " · 有故障，请诊断"
    elseif state.implemented ~= true then label = label .. " · 尚未接入"
    end
    SetText(bar.status, label)
    return true
end

function M:Finish(bar, page)
    bar.page = page
    if not bar.toggle then return true end
    local button = bar.toggle

    -- 中文维护注释（2026-09-20，module-toggle-native-trampoline-1）：页面存在三种历史绑定方式：
    -- DesignSystem 传入 onClick、直接写 component.onClick、只写 component.spec.onClick。这里全部
    -- 兼容，但必须排除 Create() 自己安装的 trampoline；最终 Native/RSUI Button 仍保持 trampoline，
    -- 真正业务动作放在 bar.invoke 后面。这样不会修改页面业务语义，也不会把共享控制条强耦合到模块。
    local directAction = button.onClick
    local specAction = type(button.spec) == "table" and button.spec.onClick or nil
    local action = type(bar.pageAction) == "function" and bar.pageAction or nil
    if action == nil and type(directAction) == "function" and directAction ~= bar.trampoline then action = directAction end
    if action == nil and type(specAction) == "function" and specAction ~= bar.trampoline then action = specAction end
    if type(action) ~= "function" then
        -- 无旧总开关的模块（例如换装）只补运行时入口；不自动执行换装/游戏操作。
        action = function()
            local runtime = S.FeatureRuntime
            if type(runtime) ~= "table" or type(runtime.SetPreferredEnabled) ~= "function" then return false, "功能管理不可用" end
            local target = not runtime:IsEnabled(bar.featureId)
            local accepted, detail = runtime:SetPreferredEnabled(bar.featureId, target, "module_toolbar")
            if accepted ~= true then return false, detail end
            if page and type(page.RefreshData) == "function" then page:RefreshData({ feature = true })
            elseif page and type(page.Refresh) == "function" then page:Refresh() end
            return true
        end
    end
    local function Invoke(...)
        if bar.inAction then return false, "功能操作进行中" end
        local args, count = { ... }, select("#", ...)
        bar.inAction = true
        local ok, result, detail = xpcall(function() return action(unpack(args, 1, count)) end, S.SafeTraceback or tostring)
        bar.inAction = false
        M:Refresh(bar)
        local shell = S.UIV3 and S.UIV3.Shell
        if shell and type(shell.RefreshFeatureStates) == "function" then shell:RefreshFeatureStates(bar.featureId) end
        local metrics = bar.actionMetrics or {}
        if not ok or result == false then
            local reason = ok and detail or result
            metrics.rejected = (tonumber(metrics.rejected) or 0) + 1
            metrics.lastError = tostring(reason or "action returned false")
            SetText(bar.status, "操作未完成 · 请诊断")
            if S.DiagnosticsManager and type(S.DiagnosticsManager.Error) == "function" then
                S.DiagnosticsManager:Error("ui_v3", "MODULE_CONTROL_REJECTED", "模块启动/关闭操作未完成",
                    { moduleId = bar.featureId, route = bar.route, error = metrics.lastError })
            end
            return false, reason
        end
        metrics.completed = (tonumber(metrics.completed) or 0) + 1
        metrics.lastError = nil
        return result, detail
    end
    bar.invoke, bar.actionReady = Invoke, true

    -- 强制恢复为创建期 trampoline；SetOnClick 失败属于交互完整性故障，不能返回一个可见死按钮。
    local bound, bindErr = true, nil
    if type(button.SetOnClick) == "function" then bound, bindErr = button:SetOnClick(bar.trampoline)
    else
        button.onClick, button.spec.onClick = bar.trampoline, bar.trampoline
    end
    if bound == false then
        bar.actionReady = false
        return false, "module_toggle_trampoline_restore_failed:" .. tostring(bindErr or "unknown")
    end
    self:Refresh(bar)
    return true
end

function M:BindLifecycle()
    if self.lifecycleBound then return true end
    if type(S.Events) ~= "table" or type(S.Events.SubscribeInternal) ~= "function" then return false end
    local accepted = S.Events:SubscribeInternal("v3.feature.lifecycle", "v3:module_controls", function(_, featureId)
        local host, shell = S.UIV3.PageHost, S.UIV3.Shell
        if host then
            for _, bar in pairs(host.moduleControls or {}) do
                if bar.featureId == featureId then M:Refresh(bar) end
            end
        end
        if shell and type(shell.RefreshFeatureStates) == "function" then shell:RefreshFeatureStates(featureId) end
    end)
    self.lifecycleBound = accepted == true
    return self.lifecycleBound
end
