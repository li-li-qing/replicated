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
-- 维护（module-controls-diag-2）：重载后Native控件已由Bootstrap退役；不得复用旧surface/Hub闭包。
-- 只在同加载代复用共享窗口，下一代重新懒创建，防止报告写入隐藏的旧编辑框。
local previousWindow = S.UIV3.ModuleDiagnosticsWindowV3
S.UIV3.ModuleDiagnosticsWindowV3 = type(previousWindow) == "table"
    and previousWindow.generation == (tonumber(S.Generation) or 0) and previousWindow or {
    generation = tonumber(S.Generation) or 0,
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
    if self.previousButton ~= nil and type(self.previousButton.SetEnabled) == "function" then self.previousButton:SetEnabled(self.copyPageValid ~= false and index > 1) end
    if self.nextButton ~= nil and type(self.nextButton.SetEnabled) == "function" then self.nextButton:SetEnabled(self.copyPageValid ~= false and index > 0 and index < total) end
    SetText(self.pageLabel, self.copyPageValid == false and "写入失败" or (tostring(index) .. " / " .. tostring(total)))
    if self.retryButton and type(self.retryButton.SetEnabled) == "function" then
        self.retryButton:SetEnabled(self.pendingSnapshot ~= nil or self.snapshot ~= nil)
    end
    return true
end

function W:_ResetSnapshot(reason)
    if self.copyBox ~= nil and type(self.copyBox.Deactivate) == "function" then self.copyBox:Deactivate(reason or "snapshot_reset") end
    self.snapshot, self.pageIndex, self.pendingSnapshot, self.copyPageValid = nil, 0, nil, nil
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
    -- 维护（module-controls-diag-2）：复制失败只重切冻结正文，不重新取证；按钮明确且不会隐式翻页。
    self.retryButton = RSUI:Button({ id = self.id .. "_retry", parent = actions, text = "缩短分页", compact = true,
        slot = { size = "fixed", width = 88 } })
    self.moduleText = RSUI:Text({ id = self.id .. "_module", parent = actions, text = "", fontSize = 10, tone = "muted",
        overflow = "ellipsis", slot = { size = "fill", fill = 1 } })
    -- 维护（module-controls-diag-2）：特殊字段探测也是统一诊断窗的显式动作，绝不能在生成/翻页时自动执行。
    self.detailActions = RSUI:HorizontalBox({ id = self.id .. "_detail_actions", parent = stack, gap = 6,
        visible = false, slot = { size = "fixed", height = 28, hAlign = "fill" } })
    self.probeButton = RSUI:Button({ id = self.id .. "_aura_probe", parent = self.detailActions, text = "字段探测", compact = true,
        slot = { size = "fixed", width = 88 }, onClick = function() return W:ProbeAuraFields() end })
    self.storeReportButton = RSUI:Button({ id = self.id .. "_store_report", parent = self.detailActions, text = "存档短报告", compact = true,
        slot = { size = "fixed", width = 100 }, onClick = function()
            local diagnostics = S.DiagnosticsManager
            if type(diagnostics) ~= "table" or type(diagnostics.PrintPersistenceFailureReport) ~= "function" then return false, "存档报告不可用" end
            return diagnostics:PrintPersistenceFailureReport()
        end })
    RSUI:Text({ id = self.id .. "_detail_hint", parent = self.detailActions, text = "字段探测后请点生成诊断；不会自动更新已复制快照。",
        fontSize = 9, tone = "muted", overflow = "ellipsis", slot = { size = "fill", fill = 1 } })
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
    self.retryButton.onClick = function() return W:RetrySmallerPages() end
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
    if self.detailActions and type(self.detailActions.SetVisible) == "function" then
        self.detailActions:SetVisible(moduleId == "combat_buff_display")
    end
    local shown, showErr = self.surface:Show(true)
    if shown ~= true then return false, showErr or "模块诊断窗口显示失败" end
    self.visible = true
    return true
end

-- 维护（module-controls-diag-2）：Window 是分页展示 Authority，不是数据采集 Authority。
-- Capture / GetPage / Native 写入分阶段隔离；第一页回读成功才提交 snapshot/pageIndex。
-- 失败保留旧快照并挂起候选；禁止为了恢复复制而反复扫描模块或自动改写用户选中的文本。
function W:_ReportFailure(err)
    if self.surface and type(self.surface.SetStatus) == "function" then
        self.surface:SetStatus(tostring(err or "诊断操作失败"), "red")
    end
    self:_UpdateNavigation()
    return false, err
end

function W:_PresentSnapshot(snapshot, index)
    local got, text, err = pcall(Hub.GetPage, Hub, snapshot, index)
    if not got or text == nil then return self:_ReportFailure(got and err or text) end
    local accepted, wrote, writeErr = pcall(self.copyBox.SetPageText, self.copyBox, text, "page:" .. tostring(index))
    if not accepted or wrote ~= true then
        self.copyPageValid = false
        return self:_ReportFailure(accepted and writeErr or wrote)
    end
    self.snapshot, self.pageIndex, self.copyPageValid = snapshot, index, true
    self.pendingSnapshot = nil
    self:_UpdateNavigation()
    if self.surface and type(self.surface.SetStatus) == "function" then
        self.surface:SetStatus("报告 #" .. tostring(snapshot.id or "?") .. " · " .. tostring(index) .. "/" .. tostring(snapshot.parts)
            .. " 页 · 本页回读一致；点击文本框 Ctrl+A / Ctrl+C，翻页不重新采集。", "accent")
    end
    return true
end

function W:Generate()
    if self.moduleId == nil or self.copyBox == nil then return false, "尚未选择模块" end
    self.copyBox:Deactivate("new_capture")
    local capacity = type(self.copyBox.GetCapacity) == "function" and self.copyBox:GetCapacity() or 3500
    local ok, snapshot, err = pcall(Hub.Capture, Hub, self.moduleId, capacity)
    if not ok or snapshot == nil then return self:_ReportFailure("诊断生成失败：" .. tostring(ok and err or snapshot)) end
    self.pendingSnapshot = snapshot
    return self:_PresentSnapshot(snapshot, 1)
end

function W:ShowPage(index)
    if type(self.snapshot) ~= "table" then return false, "请先生成诊断" end
    index = math.floor(tonumber(index) or 0)
    local total = tonumber(self.snapshot.parts) or 0
    if index < 1 or index > total then return false, "页码超出范围" end
    return self:_PresentSnapshot(self.snapshot, index)
end

function W:RetrySmallerPages()
    local source = self.pendingSnapshot or self.snapshot
    if type(source) ~= "table" or type(Hub.Repage) ~= "function" then return self:_ReportFailure("没有可重新分页的报告") end
    local oldCapacity = source.session and tonumber(source.session.capacity) or 3500
    if oldCapacity <= 512 then return self:_ReportFailure("已达到最小分页；当前控件仍未通过回读，请重新加载后检查诊断窗口。") end
    local capacity = math.max(512, math.floor(oldCapacity * 0.7))
    self.copyBox:Deactivate("explicit_repage")
    local ok, snapshot, err = pcall(Hub.Repage, Hub, source, capacity)
    if not ok or snapshot == nil then return self:_ReportFailure(ok and err or snapshot) end
    self.pendingSnapshot = snapshot
    local shown, detail = self:_PresentSnapshot(snapshot, 1)
    if shown and type(self.copyBox.SetCapacity) == "function" then self.copyBox:SetCapacity(capacity) end
    return shown, detail
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
        local ok, err = self.surface:Show(false)
        if ok ~= true then return false, err end
        -- fallback Show 不触发 onClosed，必须在成功隐藏后显式释放，不得在 veto 前释放。
        if self.copyBox then self.copyBox:Deactivate("fallback_close") end
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

-- 维护：复用已验证的业务只读探测Command，保留聊天输出与短报告；仅缓存返回证据供下次Capture。
-- 不改变当前snapshot；诊断窗口不直接访问X2Unit、不写配置、不隐式启用模块。
function W:ProbeAuraFields()
    if self.moduleId ~= "combat_buff_display" then return false, "当前模块不支持状态字段探测" end
    local feature = S.Features and S.Features.BuffDisplay
    local command = feature and feature.Commands and feature.Commands.ProbeAuraFields
    if type(command) ~= "function" then return self:_ReportFailure("状态字段探测不可用") end
    local ok, accepted, detail = pcall(command, feature.Commands)
    local result = ok and detail or accepted
    -- 有界显式探测结果按UTF-8边界裁剪且声明损失，不能以截断文本冒充完整字段报告。
    local text = tostring(result or "无返回信息")
    if #text > 8192 then
        local finish = 8192
        while finish > 0 and (text:byte(finish + 1) or 0) >= 128 and (text:byte(finish + 1) or 0) < 192 do finish = finish - 1 end
        text = text:sub(1, finish) .. "[TRUNCATED originalBytes=" .. tostring(#text) .. "]"
    end
    self.lastAuraProbe = { success = ok and accepted == true, detail = text,
        capturedAt = type(S.NowMs) == "function" and S.NowMs() or 0 }
    if self.surface and type(self.surface.SetStatus) == "function" then
        self.surface:SetStatus((ok and accepted == true and "字段探测完成" or "字段探测失败") .. "；点生成诊断收录本次证据。",
            ok and accepted == true and "accent" or "red")
    end
    return ok and accepted == true, result
end
if type(Hub.RegisterProvider) == "function" then
    Hub:RegisterProvider("combat_buff_display", "explicit_aura_probe", function()
        return W.lastAuraProbe or { sampled = false, reason = "only_runs_on_explicit_probe_button" }
    end)
end
