------------------------------------------------------------------------
-- Replicated Suite RSUI - Diagnostic Copy Box
--
-- 中文维护注释（2026-09-18，diagnostic-copy-box-1）：
-- 原因：通用 EditBox/DraftSession 必须在 LostFocus 时释放键盘，而 RU 的多行只读框会偶发
-- 迟到/伪 OnLostFocus；旧诊断框复用通用 BindDeferredInputActivation 后，用户选中文字等待片刻
-- 再 Ctrl+C 会得到空内容。历史上直接改通用输入生命周期又破坏了 Gear/数值框的删除与输入。
-- Authority：本控制器只拥有“诊断报告临时复制缓冲 + 复制交互”；正文 Authority 仍在 Diagnostics，
-- 普通输入 Authority 仍在 DraftSession/RSUI input lifecycle。两者禁止再次合并。
-- 数据流：Window 显式 SetPageText -> Native EDITBOX_MULTILINE；用户点击 -> Keyboard true + Focus；
-- LostFocus 仅记 telemetry，不改正文/键盘/焦点；模块切换/窗口关闭/Release 才 Deactivate。
-- 兼容边界：仍复用经过 RU 验证的 CreateMultiEditBox 构造和 Native ObjectFactory，但绝不调用
-- BindDeferredInputActivation、DraftSession 或后台 Scheduler。未来若 RU 复制行为变化，只改本文件，
-- 禁止为了诊断复制修改普通 EditBox/MultiEditBox 的生命周期。
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local UI = S.UI
if type(UI) ~= "table" or type(UI.CreateMultiEditBox) ~= "function" then return end

UI.DiagnosticCopyBoxContractVersion = 2

local function NowMs()
    return type(S.NowMs) == "function" and (tonumber(S.NowMs()) or 0) or 0
end

local function PhysicalId(widget)
    if type(widget) ~= "table" then return nil end
    return widget.rsNativePhysicalId or widget.rsUiPhysicalId or widget.rsPhysicalId
end

local function IsOwnFocus(widget)
    local id = PhysicalId(widget)
    if id == nil or type(GetFocusedWidgetId) ~= "function" then return false end
    local ok, focused = pcall(GetFocusedWidgetId)
    return ok == true and focused ~= nil and tostring(focused) == tostring(id)
end

local function AcceptedCall(widget, method, ...)
    if widget == nil or type(widget[method]) ~= "function" then return false, method .. "_unavailable" end
    local args, count = { ... }, select("#", ...)
    local ok, a = pcall(function() return widget[method](widget, unpack(args, 1, count)) end)
    if ok ~= true then return false, tostring(a) end
    if a == false then return false, method .. "_rejected" end
    return true
end

function UI:CreateDiagnosticCopyBox(spec)
    spec = type(spec) == "table" and spec or {}
    local parent = spec.parent
    local id = tostring(spec.id or "")
    local owner = spec.owner or (parent and parent.rsUiOwner) or nil
    if parent == nil or id == "" or owner == nil then return nil, "diagnostic copy box identity required" end

    local edit = self:CreateMultiEditBox(parent, id, tonumber(spec.x) or 0, tonumber(spec.y) or 0,
        math.max(1, tonumber(spec.width) or 520), math.max(1, tonumber(spec.height) or 300),
        math.max(1024, tonumber(spec.maxLength) or 32768))
    if edit == nil then return nil, "diagnostic multiline editor unavailable" end

    -- 中文维护注释（2026-09-18，diagnostic-copy-box-2）：
    -- RU 实机证明多行 EditBox 在 SetReadOnly(true) 后虽然 SetFocus/EnableKeyboard 均返回成功，
    -- 但 Ctrl+A/C 仍可能没有可复制选区。报告 Authority 本来就不在 Native EditBox，而在
    -- ModuleDiagnosticsHub 的冻结 snapshot；因此“防止用户改报告”不应靠 Native read-only。
    -- 这里保持复制缓冲可编辑：用户即使误改，只影响当前 Native 缓冲；翻页/正常分页/重新生成
    -- 会从 immutable snapshot 重写原文，不会写回诊断记录、Store 或业务配置。
    -- 兼容边界：SetReadOnly 在部分 RU 构建可能不存在，故只做 best-effort false，绝不能因为
    -- 该方法缺失再次阻断诊断窗口。普通输入框生命周期仍不复用本 CopyBox。
    if type(edit.SetReadOnly) == "function" then pcall(edit.SetReadOnly, edit, false) end

    local box = {
        version = 1, id = id, owner = owner, edit = edit, text = "", active = false,
        copyCapacity = math.max(512, math.min(32768, math.floor(tonumber(spec.copyCapacity) or 3500))),
        geometry = nil,
        stats = { textWrites = 0, geometryWrites = 0, geometrySkips = 0, activations = 0,
            activationFailures = 0, lostFocusNotifications = 0, deactivations = 0, lastReason = "created" },
    }

    function box:SetPageText(text, reason)
        text = tostring(text or "")
        -- 维护（module-controls-diag-2）：只在显式翻页/生成时写 Native。旧代控件不能触碰；
        -- SetText 返回成功不代表未被 RU 字数上限截短，正文必须完整回读一致后才提交缓存。
        -- 失败不伪报已复制；不绑定普通 EditBox、不轮询 GetText，保证等待复制时选区稳定。
        if self.edit.rsNativeGeneration ~= nil and tonumber(self.edit.rsNativeGeneration) ~= tonumber(S.Generation) then
            return false, "diagnostic editor generation retired"
        end
        if self.text == text and self.textVerified ~= false then
            -- 编辑缓冲现在允许选择/编辑。仅在显式 SetPageText 时做一次回读：若用户没有改动，
            -- 保留当前选区；若误改，则从冻结 snapshot 恢复正文。这里没有后台轮询。
            if type(self.edit.GetText) == "function" then
                local sameOk, sameText = pcall(self.edit.GetText, self.edit)
                if sameOk == true and sameText == text then return true end
            end
        end
        if type(self.edit.SetText) ~= "function" then return false, "diagnostic set text unavailable" end
        local ok, result = pcall(self.edit.SetText, self.edit, text)
        if ok ~= true or result == false then return false, ok and "diagnostic set text rejected" or tostring(result) end
        self.stats.textWrites = (tonumber(self.stats.textWrites) or 0) + 1
        local readOk, actual = false, nil
        if type(self.edit.GetText) == "function" then readOk, actual = pcall(self.edit.GetText, self.edit) end
        self.stats.expectedBytes = #text
        self.stats.actualBytes = readOk and type(actual) == "string" and #actual or -1
        if readOk ~= true or type(actual) ~= "string" or actual ~= text then
            self.textVerified = false
            self.stats.readbackFailures = (tonumber(self.stats.readbackFailures) or 0) + 1
            self.stats.lastReason = "readback_mismatch"
            return false, "复制页回读不一致：预期 " .. tostring(#text) .. " 字节，实际 "
                .. tostring(self.stats.actualBytes) .. "；请使用缩短分页重试，本页不可作为完整报告。"
        end
        self.text, self.textVerified = text, true
        self.stats.lastTextAt = NowMs(); self.stats.lastReason = tostring(reason or "page")
        if type(self.edit.SetCursorOffset) == "function" then pcall(self.edit.SetCursorOffset, self.edit, 0) end
        return true
    end

    function box:Clear(reason)
        return self:SetPageText("", reason or "clear")
    end

    function box:Activate(reason)
        if self.edit.rsNativeGeneration ~= nil and tonumber(self.edit.rsNativeGeneration) ~= tonumber(S.Generation) then
            return false, "diagnostic editor generation retired"
        end
        local armed, armErr = AcceptedCall(self.edit, "EnableKeyboard", true)
        if armed ~= true then
            self.stats.activationFailures = (tonumber(self.stats.activationFailures) or 0) + 1
            return false, armErr
        end
        self.edit.rsUiKeyboardArmed = true
        local focused, focusErr = AcceptedCall(self.edit, "SetFocus")
        if focused ~= true then
            AcceptedCall(self.edit, "EnableKeyboard", false); self.edit.rsUiKeyboardArmed = false
            self.stats.activationFailures = (tonumber(self.stats.activationFailures) or 0) + 1
            return false, focusErr
        end
        self.active = true
        self.stats.activations = (tonumber(self.stats.activations) or 0) + 1
        self.stats.lastReason = tostring(reason or "activate")
        self.stats.lastActivationAt = NowMs()
        if type(UI.SetEditBoxFocusVisual) == "function" then pcall(UI.SetEditBoxFocusVisual, UI, self.edit, true) end
        return true
    end

    function box:Deactivate(reason)
        -- 中文维护注释：这是诊断 CopyBox 唯一主动撤销 Keyboard 的正常生命周期边界。
        -- LostFocus 不能在这里偷跑，否则 RU 迟到通知又会复现“等待后复制为空”。
        AcceptedCall(self.edit, "EnableKeyboard", false)
        self.edit.rsUiKeyboardArmed = false
        if IsOwnFocus(self.edit) and type(self.edit.ClearFocus) == "function" then pcall(self.edit.ClearFocus, self.edit) end
        self.active = false
        self.stats.deactivations = (tonumber(self.stats.deactivations) or 0) + 1
        self.stats.lastReason = tostring(reason or "deactivate")
        self.stats.lastDeactivateAt = NowMs()
        if type(UI.SetEditBoxFocusVisual) == "function" then pcall(UI.SetEditBoxFocusVisual, UI, self.edit, false) end
        return true
    end

    function box:SetVisible(visible)
        if type(self.edit.Show) ~= "function" then return false, "diagnostic show unavailable" end
        local ok, result = pcall(self.edit.Show, self.edit, visible == true)
        if visible ~= true then self:Deactivate("hidden") end
        return ok == true and result ~= false, ok and nil or result
    end

    function box:Layout(x, y, width, height)
        x, y = tonumber(x) or 0, tonumber(y) or 0
        width, height = math.max(1, tonumber(width) or 1), math.max(1, tonumber(height) or 1)
        local g = self.geometry
        if type(g) == "table" and g.parent == parent and g.x == x and g.y == y and g.width == width and g.height == height then
            self.stats.geometrySkips = (tonumber(self.stats.geometrySkips) or 0) + 1
            return true
        end
        local extentOk, extentErr
        if type(UI.EnsureExtent) == "function" then
            local callOk, accepted, _, detail = pcall(UI.EnsureExtent, UI, self.edit, width, height, owner)
            extentOk = callOk and accepted == true; extentErr = callOk and detail or accepted
        else
            extentOk, extentErr = AcceptedCall(self.edit, "SetExtent", width, height)
        end
        if extentOk ~= true then return false, extentErr or "diagnostic extent failed" end
        local anchorOk, anchorErr
        if type(UI.EnsureAnchor) == "function" then
            local callOk, accepted, _, detail = pcall(UI.EnsureAnchor, UI, self.edit, parent, x, y, owner)
            anchorOk = callOk and accepted == true; anchorErr = callOk and detail or accepted
        else
            if type(self.edit.RemoveAllAnchors) == "function" then pcall(self.edit.RemoveAllAnchors, self.edit) end
            anchorOk, anchorErr = AcceptedCall(self.edit, "AddAnchor", "TOPLEFT", parent, x, y)
        end
        if anchorOk ~= true then return false, anchorErr or "diagnostic anchor failed" end
        self.geometry = { parent = parent, x = x, y = y, width = width, height = height }
        self.stats.geometryWrites = (tonumber(self.stats.geometryWrites) or 0) + 1
        self.stats.lastGeometryAt = NowMs()
        return true
    end

    -- 维护：容量只在用户显式重新分页且成功回读后更新；不写文本，不触碰选区。
    function box:SetCapacity(capacity)
        self.copyCapacity = math.max(512, math.min(32768, math.floor(tonumber(capacity) or 3500)))
        return true
    end
    function box:GetCapacity() return self.copyCapacity end

    function box:GetDiagnostics()
        return {
            version = self.version, active = self.active == true, keyboardArmed = self.edit.rsUiKeyboardArmed == true,
            textWrites = tonumber(self.stats.textWrites) or 0, geometryWrites = tonumber(self.stats.geometryWrites) or 0,
            geometrySkips = tonumber(self.stats.geometrySkips) or 0, activations = tonumber(self.stats.activations) or 0,
            activationFailures = tonumber(self.stats.activationFailures) or 0,
            readbackFailures = tonumber(self.stats.readbackFailures) or 0, textVerified = self.textVerified ~= false,
            expectedBytes = tonumber(self.stats.expectedBytes) or 0, actualBytes = tonumber(self.stats.actualBytes) or 0,
            lostFocusNotifications = tonumber(self.stats.lostFocusNotifications) or 0,
            deactivations = tonumber(self.stats.deactivations) or 0, lastReason = self.stats.lastReason,
        }
    end

    function box:Destroy(reason)
        self:Deactivate(reason or "destroy")
        if type(UI.RetireInputWidget) == "function" then pcall(UI.RetireInputWidget, UI, self.edit, owner, "diagnostic_copy_destroy") end
        if type(self.edit.Show) == "function" then pcall(self.edit.Show, self.edit, false) end
        return true
    end

    -- 中文维护注释：只绑定两个事件。OnClick 是用户显式取得复制键盘 Authority；OnLostFocus
    -- 故意只计数，不做任何 Native 写操作，也不调度“一帧后复核”。这是与普通输入框最重要的
    -- 隔离点。窗口关闭/模块切换会显式 Deactivate，所以不会永久持有键盘。
    if type(self.SafeHandler) ~= "function" then return nil, "diagnostic handler contract unavailable" end
    local clickOk = self:SafeHandler(edit, "OnClick", function() return box:Activate("click") end, id .. ":diagnostic_activate")
    if clickOk ~= true then box:Destroy("click_bind_failed"); return nil, "diagnostic click bind failed" end
    local lostOk = self:SafeHandler(edit, "OnLostFocus", function()
        box.stats.lostFocusNotifications = (tonumber(box.stats.lostFocusNotifications) or 0) + 1
        box.stats.lastLostFocusAt = NowMs()
        return true
    end, id .. ":diagnostic_lost_focus_observe")
    if lostOk ~= true then box:Destroy("lost_focus_bind_failed"); return nil, "diagnostic lost focus bind failed" end

    return box
end
