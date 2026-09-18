------------------------------------------------------------------------
-- Replicated Suite V3 - Shared Module Diagnostics Floating Window
--
-- 中文维护注释（2026-09-18，module-diagnostics-window-1）：
-- 原因：每个 Feature 自建诊断窗会复制 Floating/分页/输入生命周期，最终再次分叉；因此全 Suite
-- 只保留一个共享窗口，moduleId 仅是当前展示上下文。Authority：报告由 ModuleDiagnosticsHub 生成，
-- 窗口只持有一次 Capture 的 immutable snapshot/pageIndex；Feature 生命周期/Store 均不归这里。
-- 数据流：PageHeader 诊断按钮 -> Open(moduleId)（零采集）-> 用户点生成 -> Hub:Capture ->
-- DiagnosticCopyBox:SetPageText；上一页/下一页只 Hub:GetPage(snapshot)，绝不重新采集。
-- 兼容/风险：模块切换和窗口关闭必须 Deactivate CopyBox，避免键盘 Authority 泄漏；未来禁止
-- 为单个业务模块复制第二个诊断 Floating Window，特殊证据应注册 Provider 而不是另建 UI。
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local RSUI = S.RSUI
local UI = S.UI
local Floating = RSUI and RSUI.FloatingSurface or nil
local AuxStore = S.UIV3 and S.UIV3.AuxWindowStoreV3 or nil
local Hub = S.ModuleDiagnosticsHub
if type(RSUI) ~= "table" or type(UI) ~= "table" or type(Floating) ~= "table"
    or type(AuxStore) ~= "table" or type(Hub) ~= "table" then return end

S.UIV3 = S.UIV3 or {}
S.UIV3.ModuleDiagnosticsWindowV3 = S.UIV3.ModuleDiagnosticsWindowV3 or {
    version = 1,
    contractVersion = 1,
    id = "v3_module_diagnostics_window",
    created = false,
    visible = false,
    moduleId = nil,
    snapshot = nil,
    pageIndex = 0,
}
local W = S.UIV3.ModuleDiagnosticsWindowV3

local function ModuleMeta(id)
    local registry = S.FeatureRegistry
    return type(registry) == "table" and type(registry.Get) == "function" and registry:Get(id) or nil
end

local function SetText(control, text)
    if control ~= nil and type(control.SetText) == "function" then return control:SetText(tostring(text or "")) end
    return false
end

function W:_UpdateNavigation()
    local total = self.snapshot and tonumber(self.snapshot.parts) or 0
    local index = tonumber(self.pageIndex) or 0
    if self.previousButton ~= nil and type(self.previousButton.SetEnabled) == "function" then self.previousButton:SetEnabled(index > 1) end
    if self.nextButton ~= nil and type(self.nextButton.SetEnabled) == "function" then self.nextButton:SetEnabled(index > 0 and index < total) end
    SetText(self.pageLabel, tostring(index) .. " / " .. tostring(total))
    return true
end

function W:_ResetSnapshot(reason)
    if self.copyBox ~= nil and type(self.copyBox.Deactivate) == "function" then self.copyBox:Deactivate(reason or "snapshot_reset") end
    self.snapshot, self.pageIndex = nil, 0
    if self.copyBox ~= nil and type(self.copyBox.Clear) == "function" then self.copyBox:Clear(reason or "snapshot_reset") end
    self:_UpdateNavigation()
    if self.surface ~= nil and type(self.surface.SetStatus) == "function" then
        self.surface:SetStatus("点击“生成诊断”采集当前模块快照；翻页不会重新采集。", "muted")
    end
    return true
end

local function WarnAuxStoreDegraded(reason)
    if W.auxStoreDegradedWarned == true then return end
    W.auxStoreDegradedWarned = true
    local diagnostics = S.DiagnosticsManager
    if type(diagnostics) == "table" and type(diagnostics.Warn) == "function" then
        diagnostics:Warn("ui_v3", "MODULE_DIAGNOSTICS_AUX_STORE_DEGRADED",
            "模块诊断窗口布局存档不可用；已降级为本次 Session 内存布局，诊断功能仍可使用。",
            { moduleId = W.moduleId, error = tostring(reason or "unknown"), route = "system.diagnostics" })
    end
end

function W:EnsureCreated()
    if self.created == true and self.surface ~= nil then return true end

    -- 中文维护注释（2026-09-18，module-diagnostics-aux-fail-open-1）：
    -- 原因：模块诊断是故障观察面，不得依赖另一个持久化 Store 健康后才能打开；否则
    -- v3.presentation.aux_windows 恰好损坏时，用户会在最需要诊断的时刻失去诊断入口。
    -- Authority：AuxWindowStore 只拥有“窗口几何/透明度”等 Presentation 状态，绝不拥有
    -- 报告、Feature 生命周期或业务配置；因此读取失败可以安全退化为 Session-only 内存状态。
    -- 数据流：优先 AuxStore -> 若 Load/Get/Set/Persist 任一失败，则永久切换本窗口实例到
    -- fallbackState；FloatingSurface 后续仍能移动/缩放，但本次位置不再写盘。
    -- 兼容边界：这里只对 module_diagnostics 这一诊断窗口 fail-open，其他业务辅助窗继续遵循
    -- 各自持久化策略。禁止未来因为“保存位置失败”而 return false 阻断诊断窗口创建。
    -- 风险：降级 Session 的窗口位置重载后会回默认值，这是可接受的 Presentation 损失；
    -- 绝不能为了保位置而绕过 Persistence Fence 或直接写 Native SaveData。
    local policy = AuxStore:GetPolicy("module_diagnostics")
    local loaded, loadErr = AuxStore:EnsureLoaded()
    local auxHealthy = loaded == true
    local fallbackState = Floating:NormalizeState(nil, policy)
    if auxHealthy ~= true then
        self.auxPersistenceDegraded = true
        WarnAuxStoreDegraded(loadErr or "aux_window_store_load_failed")
    end

    local function UseFallback(reason)
        auxHealthy = false
        W.auxPersistenceDegraded = true
        WarnAuxStoreDegraded(reason)
        return fallbackState
    end

    local function ReadWindowState()
        if auxHealthy == true then
            local state, err = AuxStore:GetWindowState("module_diagnostics")
            if type(state) == "table" then
                fallbackState = Floating:NormalizeState(state, policy)
                return fallbackState
            end
            UseFallback(err or "aux_window_state_unavailable")
        end
        return fallbackState
    end

    local function CommitWindowState(value, reason)
        local normalized = Floating:NormalizeState(value, policy)
        if auxHealthy == true then
            local ok, err = AuxStore:SetWindowState("module_diagnostics", normalized, reason)
            if ok == true then
                -- 即使这次 Set 成功，也同步 Session shadow；若紧接着 Persist 失败，窗口仍保留
                -- 用户刚完成的几何事务，而不是跳回创建时默认位置。shadow 不是磁盘 Authority。
                fallbackState = normalized
                return true
            end
            UseFallback(err or "aux_window_state_commit_failed")
        end
        fallbackState = normalized
        return true
    end

    local function PersistWindowState(reason, delayMs)
        if auxHealthy == true then
            local ok, err = AuxStore:PersistWindow("module_diagnostics", reason, delayMs)
            if ok == true then return true end
            UseFallback(err or "aux_window_state_persist_failed")
        end
        -- Session fallback 已在 CommitWindowState 中成为当前 Presentation Authority。
        -- 返回 true 是为了让 FloatingSurface 不把一次“位置不能持久化”误判为窗口事务失败。
        return true
    end

    local surface, err = Floating:Create({
        id = self.id,
        owner = "v3:module_diagnostics:floating",
        title = "模块诊断",
        status = "点击生成诊断",
        footer = true,
        movable = true,
        resizable = true,
        appearanceControls = false,
        minimizeMode = "compact",
        boundaryMode = "free",
        defaultPlacement = "center",
        statePolicy = policy,
        getState = ReadWindowState,
        setState = CommitWindowState,
        persist = PersistWindowState,
        onClosed = function()
            W.visible = false
            if W.copyBox ~= nil and type(W.copyBox.Deactivate) == "function" then W.copyBox:Deactivate("window_closed") end
            return true
        end,
    })
    if surface == nil then return false, err or "模块诊断悬浮窗创建失败" end
    self.surface, self.shell = surface, surface.shell

    local stack = RSUI:VerticalBox({ id = self.id .. "_stack", parent = surface:GetContentRoot(), gap = 6,
        slot = { hAlign = "fill", vAlign = "fill" } })
    local actions = RSUI:HorizontalBox({ id = self.id .. "_actions", parent = stack, gap = 6,
        slot = { size = "fixed", height = 30, hAlign = "fill" } })
    self.generateButton = RSUI:Button({ id = self.id .. "_generate", parent = actions, text = "生成诊断", compact = true,
        slot = { size = "fixed", width = 96 } })
    self.previousButton = RSUI:Button({ id = self.id .. "_prev", parent = actions, text = "上一页", compact = true,
        slot = { size = "fixed", width = 82 } })
    self.pageLabel = RSUI:Text({ id = self.id .. "_page", parent = actions, text = "0 / 0", fontSize = 10, tone = "accent",
        overflow = "ellipsis", slot = { size = "fixed", width = 74 } })
    self.nextButton = RSUI:Button({ id = self.id .. "_next", parent = actions, text = "下一页", compact = true,
        slot = { size = "fixed", width = 82 } })
    self.moduleText = RSUI:Text({ id = self.id .. "_module", parent = actions, text = "", fontSize = 10, tone = "muted",
        overflow = "ellipsis", slot = { size = "fill", fill = 1 } })
    local copyHost = RSUI:Border({ id = self.id .. "_copy_host", parent = stack, variant = "card", padding = 4,
        slot = { size = "fill", fill = 1, hAlign = "fill", vAlign = "fill" } })
    if self.generateButton == nil or self.previousButton == nil or self.pageLabel == nil or self.nextButton == nil
        or self.moduleText == nil or copyHost == nil or copyHost.root == nil then
        return false, "模块诊断窗口控件创建失败"
    end
    local copyBox, copyErr = UI:CreateDiagnosticCopyBox({ parent = copyHost.root, id = self.id .. "_copy",
        owner = copyHost.owner or "v3:module_diagnostics:floating", width = 600, height = 360,
        maxLength = 32768, copyCapacity = 3500 })
    if copyBox == nil then return false, copyErr or "诊断专用复制框创建失败" end
    self.copyBox, self.copyHost = copyBox, copyHost

    -- 中文维护注释：Raw Native DiagnosticCopyBox 不是 RSUI logical child；只有 copyHost 的
    -- Layout 可以提交几何。相同几何由 CopyBox 自己 diff，任何 Feature Refresh/Tick 都不会
    -- SetText/SetExtent，因此用户 Ctrl+A 后的选区不会被后台布局刷新破坏。
    if type(copyHost.Layout) == "function" then
        local baseLayout = copyHost.Layout
        function copyHost:Layout(x, y, width, height)
            local result = baseLayout(self, x, y, width, height)
            local ok, layoutErr = W.copyBox:Layout(4, 4, math.max(1, (tonumber(width) or 1) - 8), math.max(1, (tonumber(height) or 1) - 8))
            if ok ~= true then return false, layoutErr end
            return result
        end
    end

    self.generateButton.onClick = function() return W:Generate() end
    self.previousButton.onClick = function() return W:ShowPage((tonumber(W.pageIndex) or 0) - 1) end
    self.nextButton.onClick = function() return W:ShowPage((tonumber(W.pageIndex) or 0) + 1) end
    self.created = true
    self:_UpdateNavigation()
    return true
end

function W:Open(moduleId)
    moduleId = tostring(moduleId or "")
    local meta = ModuleMeta(moduleId)
    if meta == nil then return false, "未知模块：" .. moduleId end
    local created, createErr = self:EnsureCreated()
    if created ~= true then return false, createErr end
    if self.moduleId ~= moduleId then
        self:_ResetSnapshot("module_switch")
        self.moduleId = moduleId
    end
    if self.shell ~= nil and type(self.shell.SetTitle) == "function" then self.shell:SetTitle(tostring(meta.name or moduleId) .. " · 模块诊断") end
    SetText(self.moduleText, tostring(meta.name or moduleId) .. " · " .. tostring(meta.route or ""))
    local shown, showErr = self.surface:Show(true)
    if shown ~= true then return false, showErr or "模块诊断窗口显示失败" end
    self.visible = true
    return true
end

function W:Generate()
    if self.moduleId == nil then return false, "尚未选择模块" end
    if self.copyBox ~= nil then self.copyBox:Deactivate("new_capture") end
    local capacity = self.copyBox and type(self.copyBox.GetCapacity) == "function" and self.copyBox:GetCapacity() or 3500
    local snapshot, err = Hub:Capture(self.moduleId, capacity)
    if snapshot == nil then
        if self.surface ~= nil and type(self.surface.SetStatus) == "function" then self.surface:SetStatus("诊断生成失败：" .. tostring(err or "unknown"), "red") end
        return false, err
    end
    self.snapshot, self.pageIndex = snapshot, 0
    return self:ShowPage(1)
end

function W:ShowPage(index)
    if type(self.snapshot) ~= "table" then return false, "请先生成诊断" end
    index = math.floor(tonumber(index) or 0)
    local total = tonumber(self.snapshot.parts) or 0
    if index < 1 or index > total then return false, "页码超出范围" end
    local text, err = Hub:GetPage(self.snapshot, index)
    if text == nil then return false, err or "诊断页读取失败" end
    local wrote, writeErr = self.copyBox:SetPageText(text, "page:" .. tostring(index))
    if wrote ~= true then return false, writeErr end
    self.pageIndex = index
    self:_UpdateNavigation()
    if self.surface ~= nil and type(self.surface.SetStatus) == "function" then
        self.surface:SetStatus("报告 #" .. tostring(self.snapshot.id or "?") .. " · 第 " .. tostring(index) .. "/" .. tostring(total)
            .. " 页 · 点击文本框后 Ctrl+A / Ctrl+C 复制。", "accent")
    end
    return true
end

function W:Close()
    -- 中文维护注释（2026-09-18）：CopyBox 的键盘 Authority 只允许在“窗口确实关闭”
    -- 的 onClosed 生命周期里释放。这里禁止提前 Deactivate；否则 FloatingSurface:Close()
    -- 随后再次触发 onClosed，会造成双重释放/焦点抖动，也会让未来 Close 被 veto 时出现
    -- “窗口仍可见但复制框已经失去 Authority”的半关闭状态。
    if self.surface ~= nil and type(self.surface.Close) == "function" then
        local ok, err = self.surface:Close("module_diagnostics_close")
        if ok ~= true then return false, err end
    elseif self.surface ~= nil and type(self.surface.Show) == "function" then
        self.surface:Show(false)
    end
    self.visible = false
    return true
end

function W:Describe()
    return { version = self.version, contractVersion = self.contractVersion, created = self.created == true,
        visible = self.visible == true, moduleId = self.moduleId, pageIndex = tonumber(self.pageIndex) or 0,
        parts = self.snapshot and tonumber(self.snapshot.parts) or 0,
        auxPersistenceDegraded = self.auxPersistenceDegraded == true,
        copy = self.copyBox and type(self.copyBox.GetDiagnostics) == "function" and self.copyBox:GetDiagnostics() or nil }
end
