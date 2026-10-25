-- Replicated Suite · 诊断报告复制框
-- 作者：Replicated
-- QQ群：1104129461
-- 诊断复制缓冲独立于普通输入。RU 多行框会迟到或伪派 LostFocus，
-- 旧框按普通规则撤键盘后，选区仍在却无法 Ctrl+C；修改通用输入又曾破坏数值、换装输入。
-- 此处点击取得键盘，LostFocus 只计数；切模块、关闭、释放时才撤权。
-- 正文仍取诊断冻结快照，不用 DraftSession 或后台任务维持选区。
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local UI = S.UI
if type(UI) ~= "table" or type(UI.CreateMultiEditBox) ~= "function" then return end

UI.DiagnosticCopyBoxContractVersion = 3

local function NowMs()
    return type(S.NowMs) == "function" and (tonumber(S.NowMs()) or 0) or 0
end

local function PhysicalId(widget)
    if type(widget) ~= "table" then return nil end
    return widget.rsNativePhysicalId or widget.rsUiPhysicalId or widget.rsPhysicalId
end

-- 仅复用焦点身份读取，不绑定普通 DraftSession/LostFocus 生命周期。
-- 同一 Native 输入可返回 logical/physical ID；只接受精确身份，不根据窗口名猜测。
local function IsOwnFocus(widget)
    if widget == nil then return false, false end
    if type(UI.IsInputWidgetFocused) == "function" then
        local ok, focused, err = pcall(UI.IsInputWidgetFocused, UI, widget)
        if ok and err == nil and focused == true then return true, true end
    end
    return false, false -- RU不允许Native焦点getter，不能以裸全局重试。
end

local function Retired(box)
    return box.destroyed == true or box.edit.rsUiInputLifecycleRetired == true
        or (box.edit.rsNativeGeneration ~= nil
            and tonumber(box.edit.rsNativeGeneration) ~= tonumber(S.Generation))
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

    -- RU SetReadOnly(true) 后即使聚焦成功，仍可能无法 Ctrl+A/C，故复制缓冲保持可编辑。
    -- 误改只影响当前 Native 缓冲，翻页或重生成从冻结快照重写；不写诊断记录或配置。
    -- SetReadOnly(false) 尽力调用，缺方法不能阻断窗口。
    if type(edit.SetReadOnly) == "function" then pcall(edit.SetReadOnly, edit, false) end

    local box = {
        version = 1, id = id, owner = owner, edit = edit, text = "", active = false,
        copyCapacity = math.max(512, math.min(32768, math.floor(tonumber(spec.copyCapacity) or 2048))),
        geometry = nil,
        stats = { textWrites = 0, geometryWrites = 0, geometrySkips = 0, activations = 0,
            activationFailures = 0, lostFocusNotifications = 0, deactivations = 0, lastReason = "created" },
    }

    function box:SetPageText(text, reason)
        text = tostring(text or "")
        -- 只在显式翻页/生成时写 Native。旧代控件不能触碰；
        -- SetText 返回成功不代表未被 RU 字数上限截短，正文必须完整回读一致后才提交缓存。
        -- 失败不伪报已复制；不绑定普通 EditBox、不轮询 GetText，保证等待复制时选区稳定。
        if Retired(self) then
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
        if Retired(self) then return false, "diagnostic editor generation retired" end
        local function Failure(err)
            self.stats.activationFailures = (tonumber(self.stats.activationFailures) or 0) + 1
            self.stats.lastActivationError = tostring(err or "activation_failed"):sub(1, 160)
            return false, err
        end
        local wasArmed = self.edit.rsUiKeyboardArmed == true
        local ownFocus, focusKnown = IsOwnFocus(self.edit)
        self.stats.lastFocusBefore = not focusKnown and "unknown" or (ownFocus and "own" or "other_or_none")
        self.stats.lastActivationError = nil
        -- 已 armed 且 focused 时不重复 SetFocus，否则点击选区会将它折叠。
        -- 不能只看 ID：RU 可能先发布 ID 再激活键盘，首次提升仍须聚焦。
        if wasArmed and ownFocus then
            self.active = true
            self.stats.reusedFocus = (tonumber(self.stats.reusedFocus) or 0) + 1
            self.stats.lastReason = tostring(reason or "activate")
            return true
        end
        if not wasArmed then
            local armed, armErr = AcceptedCall(self.edit, "EnableKeyboard", true)
            if armed ~= true then return Failure(armErr) end
            self.edit.rsUiKeyboardArmed = true
        end
        local focused, focusErr = AcceptedCall(self.edit, "SetFocus")
        if focused ~= true then
            AcceptedCall(self.edit, "EnableKeyboard", false); self.edit.rsUiKeyboardArmed = false
            self.active = false
            return Failure(focusErr)
        end
        self.active = true
        self.stats.activations = (tonumber(self.stats.activations) or 0) + 1
        self.stats.lastReason = tostring(reason or "activate")
        self.stats.lastActivationAt = NowMs()
        if type(UI.SetEditBoxFocusVisual) == "function" then pcall(UI.SetEditBoxFocusVisual, UI, self.edit, true) end
        return true
    end

    function box:Deactivate(reason)
        -- 这是诊断 CopyBox 唯一主动撤销 Keyboard 的正常生命周期边界。
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

    -- 容量只在用户显式重新分页且成功回读后更新；不写文本，不触碰选区。
    function box:SetCapacity(capacity)
        self.copyCapacity = math.max(512, math.min(32768, math.floor(tonumber(capacity) or 2048)))
        return true
    end
    function box:GetCapacity() return self.copyCapacity end

    function box:GetDiagnostics()
        local focused, focusKnown = IsOwnFocus(self.edit)
        return {
            patch = "diagnostic-copy-selection-1", focused = focused, focusKnown = focusKnown,
            retired = Retired(self), clipboardVerified = false,
            reusedFocus = tonumber(self.stats.reusedFocus) or 0,
            lastFocusBefore = self.stats.lastFocusBefore, lastActivationError = self.stats.lastActivationError,
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
        self.destroyed = true
        self:Deactivate(reason or "destroy")
        if type(UI.RetireInputWidget) == "function" then pcall(UI.RetireInputWidget, UI, self.edit, owner, "diagnostic_copy_destroy") end
        if type(self.edit.Show) == "function" then pcall(self.edit.Show, self.edit, false) end
        return true
    end

    -- 仅绑定点击和失焦。失焦只计数，不改 Native 或延迟复核；关闭、切模块时显式撤键盘权。
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
