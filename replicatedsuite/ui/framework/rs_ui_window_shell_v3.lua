------------------------------------------------------------------------
-- Replicated Suite - RSUI Window Shell v3
--
-- Generic top-level window composition for future V3 dialogs/tools.  It uses
-- the common RSUI Windowing authority instead of the retired ManagedWindow path
-- (S.State 已删除, 旧版架构).  Feature/application code may supply persistence callbacks,
-- but this shell never owns domain state and never creates a private Tick.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local UI, RSUI = S.UI, S.RSUI
if type(UI) ~= "table" or type(RSUI) ~= "table" or type(RSUI.Windowing) ~= "table" then return end

local Shell = {
    version = 22,
    visibilityTransactionContract = 1,
    stateMutationTransactionContract = 1,
    stateCallbackTransactionContract = 1,
    idempotentMutationContract = 1,
    compactMinimizeContract = 1,
    titleAppearanceContract = 3,
    consumedById = {},
    metrics = {
        created = 0, shown = 0, hidden = 0, minimized = 0, restored = 0, destroyed = 0, layouts = 0, failures = 0,
        closeRequests = 0, closeVetoes = 0, closeCallbackFailures = 0, closedCallbacks = 0, quarantinedRejects = 0,
        layoutInvalidations = 0, layoutInvalidationCoalesces = 0, appearancePanelToggles = 0,
        visibilityFailures = 0, minimizeRollbacks = 0, stateCallbackRejects = 0,
    },
}
UI.WindowShell = Shell

local function Clamp(value, minimum, maximum, fallback)
    local n = tonumber(value) or tonumber(fallback) or minimum
    if n < minimum then n = minimum end
    if maximum ~= nil and n > maximum then n = maximum end
    return n
end

local function ReadExtent(window, fallbackW, fallbackH)
    local width, height = tonumber(fallbackW) or 620, tonumber(fallbackH) or 520
    if window ~= nil and type(window.GetWidth) == "function" then pcall(function() width = tonumber(window:GetWidth()) or width end) end
    if window ~= nil and type(window.GetHeight) == "function" then pcall(function() height = tonumber(window:GetHeight()) or height end) end
    -- WindowShell Layout() consumes the same logical/native UI units that
    -- Windowing and UI:SetExtent use. Dividing the live extent by addonScale
    -- here caused every parameterless Layout() (SettingsPage does this) to
    -- shrink the window again when addonScale ~= 1.
    return math.max(1, width), math.max(1, height)
end

local function EnsureWindowVisible(shell, visible, reason)
    if shell == nil or shell.window == nil then return false, "window_unavailable" end
    if type(UI.EnsureVisible) ~= "function" then return false, "visibility_transaction_unavailable" end
    local accepted, _, detail = UI:EnsureVisible(shell.window, visible == true, shell.owner)
    if accepted ~= true then
        Shell.metrics.visibilityFailures = (tonumber(Shell.metrics.visibilityFailures) or 0) + 1
        if S.DiagnosticsManager ~= nil and type(S.DiagnosticsManager.Error) == "function" then
            S.DiagnosticsManager:Error("ui", "WINDOW_VISIBILITY_TRANSACTION_FAILED", "窗口可见性状态切换失败，已拒绝发布逻辑状态", {
                id = tostring(shell.id or ""), owner = tostring(shell.owner or ""), visible = tostring(visible == true),
                reason = tostring(reason or "visibility"), error = tostring(detail or "native_visibility_rejected"),
            })
        end
        return false, tostring(detail or "native_visibility_rejected")
    end
    return true, nil
end

local function EnsureComponentVisibility(component, visibility, role)
    if component == nil then return true, nil end
    if type(component.SetVisibility) ~= "function" then return false, tostring(role or "component") .. "_visibility_contract_missing" end
    local _, accepted, detail = component:SetVisibility(visibility)
    if accepted ~= true then
        Shell.metrics.visibilityFailures = (tonumber(Shell.metrics.visibilityFailures) or 0) + 1
        return false, tostring(detail or (tostring(role or "component") .. "_visibility_rejected"))
    end
    return true, nil
end

local function DefaultRect(spec)
    local context = S.Layout and S.Layout:GetContext() or { logicalWidth = 1024, logicalHeight = 768, safeLeft = 0, safeTop = 0, safeRight = 0, safeBottom = 0 }
    local minW = math.max(1, tonumber(spec.minWidth) or 1)
    local minH = math.max(1, tonumber(spec.minHeight) or 1)
    local maxW = tonumber(spec.maxWidth); if maxW ~= nil then maxW = math.max(minW, maxW) end
    local maxH = tonumber(spec.maxHeight); if maxH ~= nil then maxH = math.max(minH, maxH) end
    local usableW = math.max(1, (tonumber(context.logicalWidth) or 1024) - (tonumber(context.safeLeft) or 0) - (tonumber(context.safeRight) or 0))
    local usableH = math.max(1, (tonumber(context.logicalHeight) or 768) - (tonumber(context.safeTop) or 0) - (tonumber(context.safeBottom) or 0))
    local width = Clamp(spec.width, minW, maxW, 620)
    local height = Clamp(spec.height, minH, maxH, 520)
    local x = (tonumber(context.safeLeft) or 0) + (usableW - width) / 2
    local y = (tonumber(context.safeTop) or 0) + (usableH - height) / 2
    if S.Layout ~= nil and type(S.Layout.ClampRecoverableTopLeft) == "function" then
        x, y = S.Layout:ClampRecoverableTopLeft(x, y, width, height, { visibleX = 72, visibleY = 14, topReachHeight = math.max(28, tonumber(spec.titleHeight) or 34) })
    end
    return x, y, width, height
end

function Shell:Create(spec)
    spec = type(spec) == "table" and spec or {}
    local id = tostring(spec.id or "")
    if id == "" then return nil, "window shell identity required" end
    if S.NativeObjectFactory == nil or type(S.NativeObjectFactory.CreateWindow) ~= "function" then return nil, "native window factory unavailable" end
    if tonumber(self.consumedById[id]) == tonumber(S.Generation) then
        self.metrics.quarantinedRejects = (tonumber(self.metrics.quarantinedRejects) or 0) + 1
        return nil, "window shell identity already consumed this generation: " .. id
    end

    local scope = type(RSUI.BeginBuildScope) == "function" and RSUI:BeginBuildScope("window_shell:" .. id) or nil
    local function FailBuild(err)
        if scope ~= nil and type(RSUI.EndBuildScope) == "function" then RSUI:EndBuildScope(scope, false); scope = nil end
        self.metrics.failures = (tonumber(self.metrics.failures) or 0) + 1
        local detail = tostring(err or "window shell build failed")
        if S.DiagnosticsManager ~= nil and type(S.DiagnosticsManager.Error) == "function" then
            S.DiagnosticsManager:Error("ui", "WINDOW_SHELL_BUILD_QUARANTINED", "窗口构建失败，本次 Generation 已隔离同 ID 重试", {
                id = id, generation = tostring(S.Generation or ""), error = detail,
            })
        end
        return nil, detail
    end

    local owner = tostring(spec.owner or ("v3:window_shell:" .. id))
    local physicalId = S.PhysicalId("window_shell_" .. id)
    local window, nativeErr = S.NativeObjectFactory:CreateWindow(physicalId, "UIParent", "")
    if window == nil then
        if scope ~= nil and type(RSUI.EndBuildScope) == "function" then RSUI:EndBuildScope(scope, false); scope = nil end
        self.metrics.failures = (tonumber(self.metrics.failures) or 0) + 1
        return nil, nativeErr or "window create failed"
    end
    self.consumedById[id] = S.Generation
    if type(RSUI.TrackBuildWidget) == "function" then RSUI:TrackBuildWidget(window) end
    window.rsUiOwner = owner
    if type(UI.ClaimNativeAuthority) == "function" then UI:ClaimNativeAuthority(window, owner, "strict") end

    local shell = {
        id = id,
        owner = owner,
        window = window,
        spec = spec,
        title = tostring(spec.title or id),
        minimized = spec.minimized == true,
        minimizeMode = tostring(spec.minimizeMode or "hide"),
        compactChrome = spec.compactChrome == true,
        minimizedSize = math.max(30, tonumber(spec.minimizedSize) or 32),
        locked = spec.locked == true,
        opacity = Clamp(spec.opacity, 0.00, 1.00, 1.0),
        backgroundOpacity = Clamp(spec.backgroundOpacity, 0.00, 1.00, 1.0),
        textOpacity = Clamp(spec.textOpacity, 0.00, 1.00, 1.0),
        fontScale = Clamp(spec.fontScale, 0.50, 2.00, 1.0),
        normalWidth = tonumber(spec.width) or 620,
        normalHeight = tonumber(spec.height) or 520,
        visible = false,
        destroyed = false,
    }

    local minimumTitleH = shell.compactChrome and 22 or 28
    local titleH = math.max(minimumTitleH, tonumber(spec.titleHeight) or (shell.compactChrome and 24 or 34))
    local footerH = spec.footer == false and 0 or math.max(shell.compactChrome and 20 or 24, tonumber(spec.footerHeight) or (shell.compactChrome and 22 or 28))
    local gap = math.max(2, tonumber(spec.gap) or 8)
    local padding = math.max(0, tonumber(spec.padding) or 10)
    -- Floating surfaces use a compact chrome profile, while ordinary dialogs
    -- keep the historical defaults. Keep these dimensions declarative so HUD
    -- windows do not need to fork WindowShell or manually reposition controls.
    local titlePadding = math.max(0, tonumber(spec.titlePadding) or 5)
    local titleGap = math.max(0, tonumber(spec.titleGap) or 6)
    local titleControlWidth = math.max(22, tonumber(spec.titleControlWidth) or 30)
    local footerPadding = math.max(0, tonumber(spec.footerPadding) or 4)

    -- WindowShell is a custom chrome compositor: title/body/footer own explicit
    -- geometry in shell:Layout(). Its logical root must never be auto-arranged by
    -- the generic Overlay invalidation queue, otherwise a late child invalidation
    -- can stretch bodyFrame over the title bar until the next drag/resize.
    shell.root = RSUI:Overlay({ id = id .. "_window_root", parent = window, autoRelayout = false, slot = { hAlign = "fill", vAlign = "fill" } })
    shell.chrome = RSUI:Border({ id = id .. "_window_chrome", parent = shell.root, variant = "card", padding = 0, slot = { hAlign = "fill", vAlign = "fill" } })
    shell.titleBar = RSUI:Border({ id = id .. "_title_bar", parent = shell.root, variant = "header", padding = titlePadding,
        slot = { size = "fixed", height = titleH, hAlign = "fill", vAlign = "top" } })
    shell.titleRow = RSUI:HorizontalBox({ id = id .. "_title_row", parent = shell.titleBar, gap = titleGap, slot = { hAlign = "fill", vAlign = "fill" } })
    shell.titleText = RSUI:Text({ id = id .. "_title", parent = shell.titleRow, text = shell.title, fontSize = tonumber(spec.titleFontSize) or 13,
        tone = "accent", overflow = "ellipsis", slot = { size = "fill", fill = 1 } })
    shell.appearanceButton = spec.appearanceControls == true and RSUI:Button({ id = id .. "_appearance", parent = shell.titleRow, text = "外", compact = true,
        slot = { size = "fixed", width = titleControlWidth } }) or nil
    shell.minimizeButton = RSUI:Button({ id = id .. "_minimize", parent = shell.titleRow, text = "—", compact = true,
        slot = { size = "fixed", width = titleControlWidth } })
    shell.closeButton = spec.closeButton == false and nil or RSUI:Button({ id = id .. "_close", parent = shell.titleRow, text = "×", compact = true,
        slot = { size = "fixed", width = titleControlWidth } })
    shell.bodyFrame = RSUI:Border({ id = id .. "_body_frame", parent = shell.root, variant = "soft", padding = padding,
        slot = { hAlign = "fill", vAlign = "fill" } })
    shell.body = RSUI:Overlay({ id = id .. "_body", parent = shell.bodyFrame, slot = { hAlign = "fill", vAlign = "fill" } })
    if footerH > 0 then
        shell.footer = RSUI:Border({ id = id .. "_footer", parent = shell.root, variant = "soft", padding = footerPadding,
            slot = { size = "fixed", height = footerH, hAlign = "fill", vAlign = "bottom" } })
        shell.statusText = RSUI:Text({ id = id .. "_status", parent = shell.footer, text = tostring(spec.status or ""), fontSize = 9,
            tone = "muted", overflow = "ellipsis", slot = { hAlign = "fill", vAlign = "fill" } })
    end

    -- Appearance controls are intentionally lazy. Every FloatingSurface gets a
    -- tiny title-bar entry, but the heavier Slider/NumericInput panel is only
    -- constructed after the user asks for it. This keeps closed/unused HUDs
    -- cheap and prevents a visual preference surface from becoming a window
    -- construction dependency.
    shell.appearanceOpen = false
    shell.appearancePanelHeight = 154

    if shell.root == nil or shell.titleBar == nil or shell.body == nil then
        -- Keep construction-failure cleanup on the same Native Authority path
        -- as every other WindowShell visibility mutation.  The build scope
        -- will perform the final idempotent hide as well; this early hide only
        -- prevents a partially-created native window from flashing before the
        -- transaction reports failure.
        if type(UI.SetVisible) == "function" then UI:SetVisible(window, false, owner) end
        return FailBuild("window shell component create failed")
    end

    function shell:NotifyState(reason, geometryKind)
        if type(self.spec.onStateChanged) ~= "function" then return true, nil end
        local x, y, w, h = 0, 0, self.normalWidth, self.normalHeight
        if S.Layout ~= nil and type(S.Layout.GetLogicalRect) == "function" then pcall(function() x, y, w, h = S.Layout:GetLogicalRect(self.window) end) end
        local ok, accepted, detail = pcall(self.spec.onStateChanged, self, {
            x = tonumber(x) or 0, y = tonumber(y) or 0,
            width = tonumber(w) or self.normalWidth, height = tonumber(h) or self.normalHeight,
            normalWidth = tonumber(self.normalWidth) or tonumber(w) or 1, normalHeight = tonumber(self.normalHeight) or tonumber(h) or 1,
            minimized = self.minimized == true, locked = self.locked == true, opacity = self.opacity,
            overallOpacity = self.opacity, backgroundOpacity = self.backgroundOpacity, textOpacity = self.textOpacity, fontScale = self.fontScale,
            reason = tostring(reason or "state"), geometryKind = tostring(geometryKind or ""),
        })
        if ok ~= true then
            Shell.metrics.stateCallbackRejects = (tonumber(Shell.metrics.stateCallbackRejects) or 0) + 1
            return false, tostring(accepted or "state_callback_exception")
        end
        if accepted == false then
            Shell.metrics.stateCallbackRejects = (tonumber(Shell.metrics.stateCallbackRejects) or 0) + 1
            return false, tostring(detail or "state_callback_rejected")
        end
        return true, nil
    end


    local function IsCompactMinimized(self)
        return self.minimized == true and self.minimizeMode == "compact"
    end

    local function ApplyMinimizedChrome(self)
        local compact = IsCompactMinimized(self)
        local titleOk, titleErr = EnsureComponentVisibility(self.titleText, compact and "collapsed" or "visible", "title_text")
        if titleOk ~= true then return false, compact, titleErr end
        local appearanceOk, appearanceErr = EnsureComponentVisibility(self.appearanceButton, compact and "collapsed" or "visible", "appearance_button")
        if appearanceOk ~= true then return false, compact, appearanceErr end
        local closeOk, closeErr = EnsureComponentVisibility(self.closeButton, compact and "collapsed" or "visible", "close_button")
        if closeOk ~= true then return false, compact, closeErr end
        if self.minimized == true and self.appearanceOpen == true then
            local panelOk, panelErr = EnsureComponentVisibility(self.appearancePanel, "collapsed", "appearance_panel")
            if panelOk ~= true then return false, compact, panelErr end
            self.appearanceOpen = false
        end
        return true, compact, nil
    end

    function shell:LayoutInteractive(width, height)
        if self.destroyed then return false end
        width, height = math.max(1, tonumber(width) or self.normalWidth), math.max(1, tonumber(height) or self.normalHeight)
        local chromeOk, compact, chromeErr = ApplyMinimizedChrome(self)
        if chromeOk ~= true then return false, chromeErr or "window_chrome_visibility_failed" end
        local currentW = compact and self.minimizedSize or width
        local currentH = compact and self.minimizedSize or (self.minimized and titleH or height)
        self.root:Layout(0, 0, currentW, currentH)
        self.chrome:Layout(0, 0, currentW, currentH)
        self.titleBar:Layout(0, 0, currentW, compact and currentH or titleH)
        if self.appearancePanel ~= nil then
            local panelW = math.max(1, math.min(currentW - 4, tonumber(spec.appearancePanelWidth) or 340))
            local panelH = math.max(1, math.min(self.appearancePanelHeight, math.max(1, currentH - titleH - 2)))
            self.appearancePanel:Layout(math.max(2, currentW - panelW - 2), titleH + 1, panelW, panelH)
            local panelOk, panelErr = EnsureComponentVisibility(self.appearancePanel, self.appearanceOpen == true and not self.minimized and "visible" or "collapsed", "appearance_panel")
            if panelOk ~= true then return false, panelErr end
            if self.appearanceOpen == true and self.appearancePanel.root ~= nil and type(self.appearancePanel.root.Raise) == "function" then pcall(function() self.appearancePanel.root:Raise() end) end
        end
        if self.minimized then
            local bodyOk, bodyErr = EnsureComponentVisibility(self.bodyFrame, "collapsed", "body_frame")
            if bodyOk ~= true then return false, bodyErr end
            local footerOk, footerErr = EnsureComponentVisibility(self.footer, "collapsed", "footer")
            if footerOk ~= true then return false, footerErr end
        else
            local bodyOk, bodyErr = EnsureComponentVisibility(self.bodyFrame, "visible", "body_frame")
            if bodyOk ~= true then return false, bodyErr end
            local bodyBottom = footerH > 0 and (footerH + gap) or 0
            local bodyY = titleH + gap
            local bodyH = math.max(1, height - bodyY - bodyBottom)
            self.bodyFrame:Layout(0, bodyY, width, bodyH)
            if self.footer ~= nil then
                local footerOk, footerErr = EnsureComponentVisibility(self.footer, "visible", "footer")
                if footerOk ~= true then return false, footerErr end
                self.footer:Layout(0, math.max(titleH, height - footerH), width, footerH)
            end
        end
        if self.windowController ~= nil then
            local handlesOk, handlesErr = self.windowController:LayoutHandles(currentW, currentH)
            if handlesOk ~= true then return false, handlesErr or "window_handle_layout_failed" end
        end
        if type(RSUI.FlushLayoutQueue) == "function" then RSUI:FlushLayoutQueue(16) end
        return true
    end

    function shell:Layout(width, height)
        if self.destroyed then return false end
        width = tonumber(width)
        height = tonumber(height)
        if width == nil or height == nil then width, height = ReadExtent(self.window, self.normalWidth, self.normalHeight) end
        if self.windowController ~= nil and self.windowController:IsResizing() == true then
            local _, _, liveW, liveH = S.Layout:GetLogicalRect(self.window)
            return self:LayoutInteractive(liveW, liveH)
        end
        local chromeOk, compact, chromeErr = ApplyMinimizedChrome(self)
        if chromeOk ~= true then return false, chromeErr or "window_chrome_visibility_failed" end
        local currentW = compact and self.minimizedSize or width
        local currentH = compact and self.minimizedSize or (self.minimized and titleH or height)
        UI:SetExtent(self.window, currentW, currentH, self.owner)
        self.root:Layout(0, 0, currentW, currentH)
        self.chrome:Layout(0, 0, currentW, currentH)
        self.titleBar:Layout(0, 0, currentW, compact and currentH or titleH)
        if self.appearancePanel ~= nil then
            local panelW = math.max(1, math.min(currentW - 4, tonumber(spec.appearancePanelWidth) or 340))
            local panelH = math.max(1, math.min(self.appearancePanelHeight, math.max(1, currentH - titleH - 2)))
            self.appearancePanel:Layout(math.max(2, currentW - panelW - 2), titleH + 1, panelW, panelH)
            local panelOk, panelErr = EnsureComponentVisibility(self.appearancePanel, self.appearanceOpen == true and not self.minimized and "visible" or "collapsed", "appearance_panel")
            if panelOk ~= true then return false, panelErr end
            if self.appearanceOpen == true and self.appearancePanel.root ~= nil and type(self.appearancePanel.root.Raise) == "function" then pcall(function() self.appearancePanel.root:Raise() end) end
        end
        if self.minimized then
            local bodyOk, bodyErr = EnsureComponentVisibility(self.bodyFrame, "collapsed", "body_frame")
            if bodyOk ~= true then return false, bodyErr end
            local footerOk, footerErr = EnsureComponentVisibility(self.footer, "collapsed", "footer")
            if footerOk ~= true then return false, footerErr end
        else
            local bodyOk, bodyErr = EnsureComponentVisibility(self.bodyFrame, "visible", "body_frame")
            if bodyOk ~= true then return false, bodyErr end
            local bodyBottom = footerH > 0 and (footerH + gap) or 0
            local bodyY = titleH + gap
            local bodyH = math.max(1, height - bodyY - bodyBottom)
            self.bodyFrame:Layout(0, bodyY, width, bodyH)
            if self.footer ~= nil then
                local footerOk, footerErr = EnsureComponentVisibility(self.footer, "visible", "footer")
                if footerOk ~= true then return false, footerErr end
                self.footer:Layout(0, math.max(titleH, height - footerH), width, footerH)
            end
            self.normalWidth, self.normalHeight = width, height
        end
        if self.windowController ~= nil then
            local handlesOk, handlesErr = self.windowController:LayoutHandles(currentW, currentH)
            if handlesOk ~= true then return false, handlesErr or "window_handle_layout_failed" end
        end
        Shell.metrics.layouts = (tonumber(Shell.metrics.layouts) or 0) + 1
        if type(RSUI.FlushLayoutQueue) == "function" then RSUI:FlushLayoutQueue(16) end
        return true
    end

    -- Descendant Measure changes are routed back through WindowShell's explicit
    -- title/body/footer compositor instead of generic Overlay layout. Coalesce
    -- bursts (table row virtualization, wrapped text updates) into one bounded
    -- one-shot reflow; when Scheduler is unavailable, fail open synchronously.
    shell.layoutTaskName = "rsui_window_shell_reflow:" .. tostring(S.Generation or 0) .. ":" .. id
    function shell:_RequestLayout(reason)
        if self.destroyed == true then return false end
        Shell.metrics.layoutInvalidations = (tonumber(Shell.metrics.layoutInvalidations) or 0) + 1
        if self.layoutTaskScheduled == true then
            Shell.metrics.layoutInvalidationCoalesces = (tonumber(Shell.metrics.layoutInvalidationCoalesces) or 0) + 1
            return true
        end
        local scheduler = S.Scheduler
        if scheduler ~= nil and type(scheduler.AddOneShot) == "function" then
            self.layoutTaskScheduled = true
            if type(scheduler.RemoveTask) == "function" then scheduler:RemoveTask(self.layoutTaskName) end
            local queued = scheduler:AddOneShot(self.layoutTaskName, 50, function()
                self.layoutTaskScheduled = false
                if self.destroyed == true then return true end
                return self:Layout(self.normalWidth, self.normalHeight)
            end, self, "P1", 1)
            if queued == true then return true end
            self.layoutTaskScheduled = false
        end
        return self:Layout(self.normalWidth, self.normalHeight)
    end
    function shell:InvalidateMeasure(reason) return self:_RequestLayout(reason or "measure") end
    function shell:InvalidateLayout(reason) return self:_RequestLayout(reason or "layout") end
    if self.root ~= nil and type(self.root.SetLayoutHost) == "function" then self.root:SetLayoutHost(self) end

    function shell:Show(visible)
        if self.destroyed then return false, "window_destroyed" end
        local nextValue = visible ~= false
        local previousMinimized = self.minimized == true
        if nextValue then
            if self.minimized == true and self.minimizeMode ~= "collapse" and self.minimizeMode ~= "compact" then
                self.minimized = false
                self.minimizeButton:SetText("—")
            end
            local layoutOk, layoutErr = self:Layout(self.normalWidth, self.normalHeight)
            if layoutOk ~= true then
                self.minimized = previousMinimized
                self.minimizeButton:SetText(self.minimized and "+" or "—")
                return false, layoutErr or "window_layout_failed"
            end
        end
        local visibleOk, visibleErr = EnsureWindowVisible(self, nextValue, nextValue and "show" or "hide")
        if visibleOk ~= true then
            if nextValue then
                self.minimized = previousMinimized
                self.minimizeButton:SetText(self.minimized and "+" or "—")
            end
            return false, visibleErr
        end
        self.visible = nextValue
        if nextValue then
            if self.windowController ~= nil then self.windowController:BringToFront() end
            Shell.metrics.shown = (tonumber(Shell.metrics.shown) or 0) + 1
        else
            Shell.metrics.hidden = (tonumber(Shell.metrics.hidden) or 0) + 1
        end
        return true
    end

    function shell:Close(reason)
        if self.destroyed == true then return false end
        reason = tostring(reason or "close")
        Shell.metrics.closeRequests = (tonumber(Shell.metrics.closeRequests) or 0) + 1

        -- Closing a user-facing window is fail-open by default. Historically a
        -- callback returning false vetoed the close, which made FloatingSurface
        -- windows impossible to dismiss whenever a domain cleanup path failed.
        -- Only windows that explicitly opt into allowCloseVeto may block X.
        if type(self.spec.onClose) == "function" then
            local ok, result, detail = pcall(self.spec.onClose, self, reason)
            if ok ~= true then
                Shell.metrics.closeCallbackFailures = (tonumber(Shell.metrics.closeCallbackFailures) or 0) + 1
                if S.DiagnosticsManager ~= nil and type(S.DiagnosticsManager.WarningRateLimited) == "function" then
                    S.DiagnosticsManager:WarningRateLimited("rsui_window_shell", "WINDOW_CLOSE_CALLBACK_FAILED", 3000,
                        "窗口关闭前回调失败，已继续执行视觉关闭。", { id = tostring(self.id), reason = reason, error = tostring(result) })
                end
            elseif result == false and self.spec.allowCloseVeto == true then
                Shell.metrics.closeVetoes = (tonumber(Shell.metrics.closeVetoes) or 0) + 1
                return false, detail or "window close vetoed"
            end
        end

        local hidden = self:Show(false)
        if hidden ~= true then return false, "window hide failed" end
        if type(self.spec.onClosed) == "function" then
            local ok, result, detail = pcall(self.spec.onClosed, self, reason)
            Shell.metrics.closedCallbacks = (tonumber(Shell.metrics.closedCallbacks) or 0) + 1
            if ok ~= true or result == false then
                Shell.metrics.closeCallbackFailures = (tonumber(Shell.metrics.closeCallbackFailures) or 0) + 1
                if S.DiagnosticsManager ~= nil and type(S.DiagnosticsManager.WarningRateLimited) == "function" then
                    S.DiagnosticsManager:WarningRateLimited("rsui_window_shell", "WINDOW_CLOSED_CLEANUP_FAILED", 3000,
                        "窗口已经关闭，但关闭后的业务清理失败。", { id = tostring(self.id), reason = reason, error = tostring(ok and detail or result) })
                end
            end
        end
        return true
    end

    -- SettingsPage owns a WindowShell when it is created without an explicit
    -- parent, and its Release() contract calls shell:Destroy(). Keep teardown
    -- idempotent: stop native drag/resize first, detach Windowing handlers, then
    -- release the logical RSUI tree and hide the retained native window wrapper.
    function shell:Destroy()
        if self.destroyed == true then return 0 end
        self.destroyed = true
        self.visible = false
        if S.Scheduler ~= nil and type(S.Scheduler.RemoveTask) == "function" and self.layoutTaskName ~= nil then
            S.Scheduler:RemoveTask(self.layoutTaskName)
        end
        self.layoutTaskScheduled = false
        if self.windowController ~= nil and RSUI.Windowing ~= nil and type(RSUI.Windowing.Detach) == "function" then
            pcall(function() RSUI.Windowing:Detach(self.windowController.id) end)
        end
        self.windowController = nil
        local released = 0
        if self.root ~= nil and type(self.root.Release) == "function" then
            local ok, count = pcall(function() return self.root:Release() end)
            if ok then released = tonumber(count) or 0 end
        end
        UI:SetVisible(self.window, false, self.owner)
        Shell.metrics.destroyed = (tonumber(Shell.metrics.destroyed) or 0) + 1
        return released
    end

    function shell:SetMinimized(minimized, persist)
        if self.destroyed == true then return false, "window_destroyed" end
        local nextValue = minimized == true
        if self.minimized == nextValue then return true, false end
        local previous = self.minimized == true
        local previousVisible = self.visible == true

        -- Establish Native/layout state first. Only after every required step
        -- succeeds do we publish self.minimized/self.visible and persist it.
        if self.minimizeMode == "collapse" or self.minimizeMode == "compact" then
            self.minimized = nextValue
            local layoutOk, layoutErr = self:Layout(self.normalWidth, self.normalHeight)
            if layoutOk ~= true then
                self.minimized = previous
                self:Layout(self.normalWidth, self.normalHeight)
                Shell.metrics.minimizeRollbacks = (tonumber(Shell.metrics.minimizeRollbacks) or 0) + 1
                return false, layoutErr or "window_minimize_layout_failed"
            end
            if previousVisible then
                local visibleOk, visibleErr = EnsureWindowVisible(self, true, "minimize_compact")
                if visibleOk ~= true then
                    self.minimized = previous
                    self:Layout(self.normalWidth, self.normalHeight)
                    Shell.metrics.minimizeRollbacks = (tonumber(Shell.metrics.minimizeRollbacks) or 0) + 1
                    return false, visibleErr
                end
                if self.windowController ~= nil then self.windowController:BringToFront() end
            end
        elseif nextValue then
            local hiddenOk, hiddenErr = EnsureWindowVisible(self, false, "minimize_hide")
            if hiddenOk ~= true then return false, hiddenErr end
            self.minimized = true
            self.visible = false
        else
            self.minimized = false
            local layoutOk, layoutErr = self:Layout(self.normalWidth, self.normalHeight)
            if layoutOk ~= true then
                self.minimized = previous
                Shell.metrics.minimizeRollbacks = (tonumber(Shell.metrics.minimizeRollbacks) or 0) + 1
                return false, layoutErr or "window_restore_layout_failed"
            end
            local shownOk, shownErr = EnsureWindowVisible(self, true, "minimize_restore")
            if shownOk ~= true then
                self.minimized = previous
                self:Layout(self.normalWidth, self.normalHeight)
                Shell.metrics.minimizeRollbacks = (tonumber(Shell.metrics.minimizeRollbacks) or 0) + 1
                return false, shownErr
            end
            self.visible = true
            if self.windowController ~= nil then self.windowController:BringToFront() end
        end

        self.minimizeButton:SetText(self.minimized and "+" or "—")
        if persist ~= false then
            local stateOk, stateErr = self:NotifyState("minimize")
            if stateOk ~= true then
                self.minimized = previous
                self.visible = previousVisible
                self:Layout(self.normalWidth, self.normalHeight)
                local visibilityOk = EnsureWindowVisible(self, previousVisible, "minimize_persist_rollback")
                self.minimizeButton:SetText(self.minimized and "+" or "—")
                Shell.metrics.minimizeRollbacks = (tonumber(Shell.metrics.minimizeRollbacks) or 0) + 1
                if visibilityOk ~= true then return false, "minimize_persist_rollback_visibility_failed:" .. tostring(stateErr or "state_rejected") end
                return false, stateErr or "minimize_state_rejected"
            end
        end
        if nextValue then Shell.metrics.minimized = (tonumber(Shell.metrics.minimized) or 0) + 1
        else Shell.metrics.restored = (tonumber(Shell.metrics.restored) or 0) + 1 end
        return true, true
    end

    function shell:SetLocked(locked, persist)
        if self.destroyed == true then return false, "window_destroyed" end
        local nextValue = locked == true
        local previous = self.locked == true
        if previous == nextValue then return true, false end
        if self.windowController ~= nil then
            local accepted, _, detail = self.windowController:SetLocked(nextValue)
            if accepted ~= true then return false, detail or "window_lock_native_rejected" end
        end
        self.locked = nextValue
        if self.appearanceLock ~= nil then self.appearanceLock:SetText(self.locked and "解锁" or "锁定") end
        if persist ~= false then
            local stateOk, stateErr = self:NotifyState("lock")
            if stateOk ~= true then
                if self.windowController ~= nil then self.windowController:SetLocked(previous) end
                self.locked = previous
                if self.appearanceLock ~= nil then self.appearanceLock:SetText(self.locked and "解锁" or "锁定") end
                return false, stateErr or "window_lock_state_rejected"
            end
        end
        return true, true
    end
    function shell:IsLocked() return self.locked == true end

    function shell:SetOpacity(value, persist)
        if self.destroyed == true then return false, "window_destroyed" end
        local previous = tonumber(self.opacity) or 1.0
        local nextValue = Clamp(value, 0.00, 1.00, previous)
        if math.abs(nextValue - previous) <= 0.0001 then return true, self.opacity, false end
        local accepted, detail
        if self.windowController ~= nil then
            local ok, _, _, err = self.windowController:SetOpacity(nextValue)
            accepted, detail = ok == true, err
        elseif type(UI.EnsureAlpha) == "function" then
            local ok, _, err = UI:EnsureAlpha(self.window, nextValue, self.owner)
            accepted, detail = ok == true, err
        else
            accepted, detail = false, "alpha_transaction_unavailable"
        end
        if accepted ~= true then return false, detail or "window_opacity_native_rejected" end
        self.opacity = nextValue
        if persist ~= false then
            local stateOk, stateErr = self:NotifyState("opacity")
            if stateOk ~= true then
                if self.windowController ~= nil then self.windowController:SetOpacity(previous)
                elseif type(UI.EnsureAlpha) == "function" then UI:EnsureAlpha(self.window, previous, self.owner) end
                self.opacity = previous
                return false, stateErr or "window_opacity_state_rejected"
            end
        end
        return true, self.opacity, true
    end
    function shell:GetOpacity() return self.opacity end
    function shell:SetOverallOpacity(value, persist) return self:SetOpacity(value, persist) end
    function shell:GetOverallOpacity() return self.opacity end

    function shell:SetBackgroundOpacity(value, persist)
        if self.destroyed == true then return false, "window_destroyed" end
        local previous = tonumber(self.backgroundOpacity) or 1.0
        local nextValue = Clamp(value, 0.00, 1.00, previous)
        if math.abs(nextValue - previous) <= 0.0001 then return true, self.backgroundOpacity, false end
        if RSUI:ApplyOpacityChannels(self.root, nextValue, nil) ~= true then return false, "background_opacity_apply_failed" end
        self.backgroundOpacity = nextValue
        if persist ~= false then
            local stateOk, stateErr = self:NotifyState("background_opacity")
            if stateOk ~= true then
                RSUI:ApplyOpacityChannels(self.root, previous, nil)
                self.backgroundOpacity = previous
                return false, stateErr or "background_opacity_state_rejected"
            end
        end
        return true, self.backgroundOpacity, true
    end
    function shell:GetBackgroundOpacity() return self.backgroundOpacity end

    function shell:SetTextOpacity(value, persist)
        if self.destroyed == true then return false, "window_destroyed" end
        local previous = tonumber(self.textOpacity) or 1.0
        local nextValue = Clamp(value, 0.00, 1.00, previous)
        if math.abs(nextValue - previous) <= 0.0001 then return true, self.textOpacity, false end
        if RSUI:ApplyOpacityChannels(self.root, nil, nextValue) ~= true then return false, "text_opacity_apply_failed" end
        self.textOpacity = nextValue
        if persist ~= false then
            local stateOk, stateErr = self:NotifyState("text_opacity")
            if stateOk ~= true then
                RSUI:ApplyOpacityChannels(self.root, nil, previous)
                self.textOpacity = previous
                return false, stateErr or "text_opacity_state_rejected"
            end
        end
        return true, self.textOpacity, true
    end
    function shell:GetTextOpacity() return self.textOpacity end

    function shell:SetFontScale(value, persist)
        if self.destroyed == true then return false, "window_destroyed" end
        local previous = tonumber(self.fontScale) or 1.0
        local nextValue = Clamp(value, 0.50, 2.00, previous)
        if nextValue == previous then return true, self.fontScale end
        if type(RSUI.ApplyFontScale) ~= "function" or RSUI:ApplyFontScale(self.root, nextValue) ~= true then
            return false, "font_scale_apply_failed"
        end
        self.fontScale = nextValue
        local layoutOk, layoutErr = self:Layout(self.normalWidth, self.normalHeight)
        if layoutOk ~= true then
            self.fontScale = previous
            RSUI:ApplyFontScale(self.root, previous)
            self:Layout(self.normalWidth, self.normalHeight)
            return false, layoutErr or "font_scale_layout_failed"
        end
        if persist ~= false then
            local stateOk, stateErr = self:NotifyState("font_scale")
            if stateOk ~= true then
                self.fontScale = previous
                RSUI:ApplyFontScale(self.root, previous)
                self:Layout(self.normalWidth, self.normalHeight)
                return false, stateErr or "font_scale_state_rejected"
            end
        end
        return true, self.fontScale
    end
    function shell:GetFontScale() return self.fontScale end

    function shell:EnsureAppearancePanel()
        if self.appearancePanel ~= nil then return true end
        if self.appearanceBuildFailed == true then return false, self.appearanceBuildError or "appearance panel failed in this generation" end
        if spec.appearanceControls ~= true or self.appearanceButton == nil or type(RSUI.NumericField) ~= "function" then
            return false, "appearance controls unavailable"
        end
        local buildScope = type(RSUI.BeginBuildScope) == "function" and RSUI:BeginBuildScope("window_appearance:" .. id) or nil
        local function Rollback(reason)
            self.appearanceBuildFailed = true
            self.appearanceBuildError = tostring(reason or "appearance panel build failed")
            if buildScope ~= nil and type(RSUI.EndBuildScope) == "function" then RSUI:EndBuildScope(buildScope, false) end
            self.appearancePanel, self.appearanceStack = nil, nil
            self.appearanceOverall, self.appearanceBackground, self.appearanceText, self.appearanceFont = nil, nil, nil, nil
            self.appearanceActions, self.appearanceLock, self.appearanceReset, self.appearanceDone = nil, nil, nil, nil
            return false, self.appearanceBuildError
        end
        local panel, panelErr = RSUI:Border({ id = id .. "_appearance_panel", parent = self.root, variant = "card", padding = 3,
            slot = { hAlign = "fill", vAlign = "top" }, buildOptional = true })
        if panel == nil then return Rollback(panelErr or "appearance panel unavailable") end
        self.appearancePanel = panel
        local stack, stackErr = RSUI:VerticalBox({ id = id .. "_appearance_stack", parent = panel, gap = 2,
            slot = { hAlign = "fill", vAlign = "fill" }, buildOptional = true })
        if stack == nil then return Rollback(stackErr or "appearance stack unavailable") end
        self.appearanceStack = stack

        local function Percent(value) return math.floor((tonumber(value) or 0) * 100 + 0.5) end
        local function Preview(channel, value)
            value = Clamp((tonumber(value) or 100) / 100, channel == "font" and 0.50 or 0.00, channel == "font" and 2.00 or 1.00, 1.00)
            if channel == "overall" then
                if self.windowController ~= nil then
                    local accepted, _, _, detail = self.windowController:SetOpacity(value)
                    if accepted ~= true then return false, detail or "appearance_preview_opacity_rejected" end
                elseif type(UI.EnsureAlpha) == "function" then
                    local accepted, _, detail = UI:EnsureAlpha(self.window, value, self.owner)
                    if accepted ~= true then return false, detail or "appearance_preview_opacity_rejected" end
                else
                    return false, "appearance_preview_alpha_transaction_unavailable"
                end
            elseif channel == "background" then
                if RSUI:ApplyOpacityChannels(self.root, value, nil) ~= true then return false, "appearance_preview_background_rejected" end
            elseif channel == "text" then
                if RSUI:ApplyOpacityChannels(self.root, nil, value) ~= true then return false, "appearance_preview_text_rejected" end
            elseif channel == "font" then
                if type(RSUI.ApplyFontScale) ~= "function" or RSUI:ApplyFontScale(self.root, value) ~= true then
                    return false, "appearance_preview_font_rejected"
                end
            end
            return true
        end
        local function MakeField(suffix, label, getValue, applyValue, channel, minimum, maximum)
            return RSUI:NumericField({
                id = id .. "_appearance_" .. suffix, parent = stack, label = label, inline = true, slider = true,
                min = minimum, max = maximum, step = 1, integer = true, unit = "%",
                padding = 1, labelFontSize = 9,
                -- Appearance labels are only two Chinese characters. Keep them
                -- compact and reserve the majority of a narrow HUD row for the
                -- actual drag target; exact percentage entry remains on the right.
                labelWidth = 26, labelMinWidth = 24, labelMaxShare = 0.18,
                inputWidth = 46, inputMinWidth = 42, sliderMinWidth = 52, sliderPreferredShare = 0.46,
                controlGap = 2, controlHeight = 20, minHeight = 27,
                get = getValue,
                set = function(value) return applyValue((tonumber(value) or 100) / 100, true) end,
                onPreview = function(value) return Preview(channel, value) end,
                slot = { size = "fixed", height = 27, hAlign = "fill" }, buildOptional = true,
            })
        end
        self.appearanceOverall = MakeField("overall", "整体", function() return Percent(self.opacity) end, function(v, persist) return self:SetOverallOpacity(v, persist) end, "overall", 10, 100)
        self.appearanceBackground = MakeField("background", "背景", function() return Percent(self.backgroundOpacity) end, function(v, persist) return self:SetBackgroundOpacity(v, persist) end, "background", 0, 100)
        self.appearanceText = MakeField("text", "文字", function() return Percent(self.textOpacity) end, function(v, persist) return self:SetTextOpacity(v, persist) end, "text", 10, 100)
        self.appearanceFont = MakeField("font", "字号", function() return Percent(self.fontScale) end, function(v, persist) return self:SetFontScale(v, persist) end, "font", 50, 200)
        if self.appearanceOverall == nil or self.appearanceBackground == nil or self.appearanceText == nil or self.appearanceFont == nil then
            return Rollback("appearance numeric field unavailable")
        end
        self.appearanceActions = RSUI:HorizontalBox({ id = id .. "_appearance_actions", parent = stack, gap = 3,
            slot = { size = "fixed", height = 24, hAlign = "fill" }, buildOptional = true })
        if self.appearanceActions == nil then return Rollback("appearance actions unavailable") end
        self.appearanceLock = RSUI:Button({ id = id .. "_appearance_lock", parent = self.appearanceActions, text = self.locked and "解锁" or "锁定", compact = true,
            slot = { size = "fill", fill = 1 }, buildOptional = true })
        self.appearanceReset = RSUI:Button({ id = id .. "_appearance_reset", parent = self.appearanceActions, text = "重置布局", compact = true,
            slot = { size = "fill", fill = 1 }, buildOptional = true })
        self.appearanceDone = RSUI:Button({ id = id .. "_appearance_done", parent = self.appearanceActions, text = "收起", compact = true,
            slot = { size = "fill", fill = 1 }, buildOptional = true })
        if self.appearanceLock == nil or self.appearanceReset == nil or self.appearanceDone == nil then return Rollback("appearance action button unavailable") end

        self.appearancePanel:SetVisibility("collapsed")
        self.appearanceLock.onClick = function() return self:SetLocked(not self.locked, true) end
        self.appearanceReset.onClick = function()
            local ok, err
            if type(spec.onAppearanceReset) == "function" then ok, err = spec.onAppearanceReset(self)
            else ok, err = self:ResetLayout(true) end
            if ok == true then self:RefreshAppearanceControls() end
            return ok, err
        end
        self.appearanceDone.onClick = function() return self:SetAppearanceOpen(false) end
        if buildScope ~= nil and type(RSUI.EndBuildScope) == "function" then
            local committed, commitErr = RSUI:EndBuildScope(buildScope, true)
            if committed ~= true then return Rollback(commitErr or "appearance build commit failed") end
        end
        return true
    end

    function shell:RefreshAppearanceControls()
        for _, field in ipairs({ self.appearanceOverall, self.appearanceBackground, self.appearanceText, self.appearanceFont }) do
            if field ~= nil and type(field.Render) == "function" then field:Render() end
        end
        if self.appearanceLock ~= nil then self.appearanceLock:SetText(self.locked and "解锁" or "锁定") end
        return true
    end

    function shell:SetAppearanceOpen(open)
        local nextValue = open == true and self.minimized ~= true
        if nextValue and self.appearancePanel == nil then
            local built, buildErr = self:EnsureAppearancePanel()
            if built ~= true then return false, buildErr end
        end
        if self.appearancePanel == nil then return nextValue == false, nextValue == false and false or "appearance controls unavailable" end
        if self.appearanceOpen == nextValue then return true, false end
        local previous = self.appearanceOpen == true
        self.appearanceOpen = nextValue
        if nextValue then self:RefreshAppearanceControls() end
        local layoutOk, layoutErr = self:Layout()
        if layoutOk ~= true then
            self.appearanceOpen = previous
            self:Layout()
            return false, layoutErr or "appearance_layout_failed"
        end
        local _, visibilityAccepted, visibilityErr = self.appearancePanel:SetVisibility(nextValue and "visible" or "collapsed")
        if visibilityAccepted ~= true then
            self.appearanceOpen = previous
            self:Layout()
            self.appearancePanel:SetVisibility(previous and "visible" or "collapsed")
            return false, visibilityErr or "appearance_visibility_failed"
        end
        if nextValue and self.appearancePanel.root ~= nil and type(self.appearancePanel.root.Raise) == "function" then pcall(function() self.appearancePanel.root:Raise() end) end
        Shell.metrics.appearancePanelToggles = (tonumber(Shell.metrics.appearancePanelToggles) or 0) + 1
        return true, true
    end

    function shell:ToggleAppearance() return self:SetAppearanceOpen(self.appearanceOpen ~= true) end

    function shell:SetTitle(text) self.title = tostring(text or ""); self.titleText:SetText(self.title); return true end
    function shell:SetStatus(text, tone)
        if self.statusText == nil then return false end
        self.statusText:SetText(tostring(text or ""))
        if tone ~= nil then self.statusText:SetTone(tostring(tone)) end
        return true
    end
    -- Preserve the historical Native-root accessor for low-level callers, but
    -- expose the logical RSUI content component separately. Presentation code
    -- must parent RSUI components to the logical body so parentComponent /
    -- children / Measure / Layout / Release remain connected to the shell tree.
    function shell:GetContentRoot() return self.body.root end
    function shell:GetNativeContentRoot() return self.body.root end
    function shell:GetContentComponent() return self.body end
    function shell:GetWindow() return self.window end

    function shell:ResetLayout(persist)
        if self.destroyed == true then return false end
        local x, y, width, height = DefaultRect(self.spec)
        self.minimized = false
        self.appearanceOpen = false
        if self.appearancePanel ~= nil then self.appearancePanel:SetVisibility("collapsed") end
        self.normalWidth, self.normalHeight = width, height
        UI:SetAnchor(self.window, UIParent, x, y, self.owner)
        UI:SetExtent(self.window, width, height, self.owner)
        self:Layout(width, height)
        if persist ~= false then self:NotifyState("reset") end
        return true
    end

    if shell.appearanceButton ~= nil then
        shell.appearanceButton.onClick = function() return shell:ToggleAppearance() end
    end
    if shell.minimizeButton ~= nil then
        shell.minimizeButton:SetText(shell.minimized and "+" or "—")
        shell.minimizeButton.onClick = function() return shell:SetMinimized(not shell.minimized, true) end
    end
    if shell.closeButton ~= nil then
        shell.closeButton.onClick = function() return shell:Close("button") end
    end

    local x, y, width, height = DefaultRect(spec)
    if type(spec.initialRect) == "table" then
        x = tonumber(spec.initialRect.x) or x; y = tonumber(spec.initialRect.y) or y
        local minW = math.max(1, tonumber(spec.minWidth) or 1)
        local minH = math.max(1, tonumber(spec.minHeight) or 1)
        local maxW = tonumber(spec.maxWidth); if maxW ~= nil then maxW = math.max(minW, maxW) end
        local maxH = tonumber(spec.maxHeight); if maxH ~= nil then maxH = math.max(minH, maxH) end
        width = Clamp(spec.initialRect.width, minW, maxW, width)
        height = Clamp(spec.initialRect.height, minH, maxH, height)
    end
    shell.normalWidth, shell.normalHeight = width, height
    UI:SetAnchor(window, UIParent, x, y, owner)
    local initialCompact = shell.minimized == true and shell.minimizeMode == "compact"
    UI:SetExtent(window, initialCompact and shell.minimizedSize or width, initialCompact and shell.minimizedSize or (shell.minimized and titleH or height), owner)
    local initialHidden, initialHideErr = EnsureWindowVisible(shell, false, "initial_hide")
    if initialHidden ~= true then return FailBuild("window initial hide failed:" .. tostring(initialHideErr or "unknown")) end
    shell.windowController = RSUI.Windowing:Attach({
        id = "window_shell:" .. id,
        owner = owner,
        window = window,
        dragHandle = shell.titleBar,
        resizable = spec.resizable ~= false,
        locked = shell.locked,
        opacity = shell.opacity,
        minWidth = math.max(1, tonumber(spec.minWidth) or 1),
        minHeight = math.max(1, tonumber(spec.minHeight) or 1),
        maxWidth = tonumber(spec.maxWidth),
        maxHeight = tonumber(spec.maxHeight),
        boundaryMode = tostring(spec.boundaryMode or "free"),
        canDrag = function() return spec.movable ~= false end,
        recoveryVisibleX = math.max(32, tonumber(spec.recoveryVisibleX) or 72),
        recoveryVisibleY = math.max(8, tonumber(spec.recoveryVisibleY) or 14),
        dragHandleHeight = titleH,
        canResize = function() return shell.minimized ~= true end,
        onGeometryChanged = function(_, _, _, w, h, geometryKind)
            local previousW, previousH = shell.normalWidth, shell.normalHeight
            if shell.minimized ~= true then shell.normalWidth, shell.normalHeight = w, h end
            local layoutOk, layoutErr = shell:Layout(shell.normalWidth, shell.normalHeight)
            if layoutOk ~= true then
                shell.normalWidth, shell.normalHeight = previousW, previousH
                shell:Layout(previousW, previousH)
                return false, layoutErr or "geometry_layout_rejected"
            end
            local stateOk, stateErr = shell:NotifyState("geometry", geometryKind)
            if stateOk ~= true then
                shell.normalWidth, shell.normalHeight = previousW, previousH
                shell:Layout(previousW, previousH)
                return false, stateErr or "geometry_state_rejected"
            end
            return true
        end,
        onLiveGeometry = function(_, _, _, w, h, kind)
            if tostring(kind or "") == "resize" then return shell:LayoutInteractive(w, h) end
            return true
        end,
    })
    if shell.windowController == nil then return FailBuild("windowing attach failed") end
    RSUI:ApplyOpacityChannels(shell.root, shell.backgroundOpacity, shell.textOpacity)
    if type(RSUI.ApplyFontScale) == "function" then RSUI:ApplyFontScale(shell.root, shell.fontScale) end
    shell:Layout(width, height)
    if scope ~= nil and type(RSUI.EndBuildScope) == "function" then
        local committed, commitErr = RSUI:EndBuildScope(scope, true)
        scope = nil
        if committed ~= true then
            self.metrics.failures = (tonumber(self.metrics.failures) or 0) + 1
            return nil, "window shell build transaction commit failed: " .. tostring(commitErr or "unknown")
        end
    end
    self.metrics.created = (tonumber(self.metrics.created) or 0) + 1
    return shell
end

function Shell:GetSnapshot()
    return self:Describe()
end

function Shell:Describe()
    return {
        version = self.version,
        created = tonumber(self.metrics.created) or 0,
        shown = tonumber(self.metrics.shown) or 0,
        hidden = tonumber(self.metrics.hidden) or 0,
        minimized = tonumber(self.metrics.minimized) or 0,
        restored = tonumber(self.metrics.restored) or 0,
        destroyed = tonumber(self.metrics.destroyed) or 0,
        layouts = tonumber(self.metrics.layouts) or 0,
        failures = tonumber(self.metrics.failures) or 0,
        quarantinedRejects = tonumber(self.metrics.quarantinedRejects) or 0,
        closeRequests = tonumber(self.metrics.closeRequests) or 0,
        closeVetoes = tonumber(self.metrics.closeVetoes) or 0,
        closeCallbackFailures = tonumber(self.metrics.closeCallbackFailures) or 0,
        closedCallbacks = tonumber(self.metrics.closedCallbacks) or 0,
        layoutInvalidations = tonumber(self.metrics.layoutInvalidations) or 0,
        layoutInvalidationCoalesces = tonumber(self.metrics.layoutInvalidationCoalesces) or 0,
        appearancePanelToggles = tonumber(self.metrics.appearancePanelToggles) or 0,
        idempotentMutationContract = tonumber(self.idempotentMutationContract) or 0,
        compactMinimizeContract = tonumber(self.compactMinimizeContract) or 0,
        titleAppearanceContract = tonumber(self.titleAppearanceContract) or 0,
        visibilityTransactionContract = tonumber(self.visibilityTransactionContract) or 0,
        stateMutationTransactionContract = tonumber(self.stateMutationTransactionContract) or 0,
        stateCallbackTransactionContract = tonumber(self.stateCallbackTransactionContract) or 0,
        stateCallbackRejects = tonumber(self.metrics.stateCallbackRejects) or 0,
    }
end

function UI:CreateWindowShell(spec) return Shell:Create(spec) end
