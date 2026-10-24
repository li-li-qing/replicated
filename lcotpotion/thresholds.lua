-- 中文维护：阈值编辑消费配套Replicated Suite的RSUI/ModalHost；LCot只拥有草稿和原私有配置，不复制Native输入/层级机制。
local P = LCotPotionSignal
local function IsCurrent(editor)
    return P:IsCurrent() and P.thresholdEditor == editor and P:GetThresholdUI() == editor.suite
        and editor.suite.Generation == editor.suiteGeneration and editor.suite.BootError == nil
end
local function CancelInputs(editor, reason)
    for _, input in ipairs(editor.inputs) do input:CancelEditing(reason or "lcot_threshold_cancel") end -- 中文维护：输入资格与Lua草稿交回RSUI统一撤销，不操作全局焦点。
end
local function Feedback(editor, message)
    editor.status:SetText(tostring(message or "")) -- 中文维护：反馈写当前Suite模态窗口，不能被LCot主面板遮住。
end
local function Action(editor, label, run)
    return function()
        if not IsCurrent(editor) or not editor.open then return false end -- 中文维护：LCot/Suite任一代次退休、关闭后迟到的按钮都不能保存。
        local ok, result, detail = pcall(run)
        if not ok then
            editor.lastError = tostring(result)
            Feedback(editor, label .. "失败，请取消后重开设置。")
            P:Disable(label .. "失败")
            local diagnostics = editor.suite.DiagnosticsManager
            if diagnostics and type(diagnostics.Error) == "function" then diagnostics:Error("lcotpotion", "THRESHOLD_ACTION_FAILED", label .. "失败", { error = editor.lastError:sub(1, 240) }) end
            return false
        end
        return result, detail
    end
end
local function RestoreMain(editor)
    if not editor.returnToMain or not P:IsCurrent() then return end
    editor.returnToMain = false; P.panelOpen = true; P.panel:Show(true); P:RefreshText() -- 中文维护：仅恢复进入模态前的LCot设置面板，保持信号暂停。
end
local function OnClosed(editor)
    editor.open = false
    CancelInputs(editor, "lcot_threshold_closed")
    RestoreMain(editor)
end
function P:CloseThresholds()
    local editor = self.thresholdEditor
    if not editor or not editor.open then return true end
    local closed, err = editor.host:Pop(editor.id, "lcot_threshold_close") -- 中文维护：ModalHost统一移除本弹窗和遮罩，不清别的模态窗口。
    if closed == nil then Feedback(editor, "关闭失败，请重试取消调整。"); return false, err end
    return true
end
function P:ReleaseThresholdEditor()
    local editor = self.thresholdEditor
    if not editor then return end
    self.thresholdEditor = nil -- 中文维护：Suite换代时仍须恢复LCot返回面板；LCot自身Shutdown由IsCurrent阻止复活窗口。
    pcall(editor.host.Pop, editor.host, editor.id, "lcot_threshold_retired")
    OnClosed(editor) -- 中文维护：旧Suite的Native代次已失效时Pop会拒绝且不派发onClosed；本Addon的草稿释放/返回面板必须独立幂等完成。
    editor.card:Release() -- 中文维护：释放整棵RSUI组件/Binding/输入资格；不会把Suite控件塞进LCot的Native widgets数组。
end
function P:ReconcileThresholdEditor()
    if self.thresholdEditor and not IsCurrent(self.thresholdEditor) then self:ReleaseThresholdEditor() end -- 中文维护：借现有LCot更新入口只比较双代次；变化时回收一次，不增加Native轮询或新任务。
end
local function BuildEditor(suite, host)
    P.thresholdEditorSerial = (P.thresholdEditorSerial or 0) + 1
    local id = "lcot_threshold_" .. P.generation .. "_" .. tostring(suite.Generation) .. "_" .. P.thresholdEditorSerial
    local editor = { id = id, suite = suite, suiteGeneration = suite.Generation, host = host, inputs = {}, plus = {}, minus = {}, drafts = {}, open = false }
    local R = suite.RSUI
    local built, _, buildError = R:WithBuildScope(id .. ":build", function()
        local parent = host:GetContentRoot()
        if parent == nil then return false, "Suite模态宿主尚未挂载" end
        editor.card = assert(R:Border({ id = id, parent = parent, variant = "card", padding = 16, width = 660, minHeight = 370,
            slot = { size = "auto", hAlign = "center", vAlign = "center", padding = 16 } }))
        local stack = assert(R:VerticalBox({ id = id .. "_stack", parent = editor.card, gap = 10 }))
        assert(R:Text({ id = id .. "_title", parent = stack, text = "LCot 用药血量阈值 · Suite 控件直载", fontSize = 17, tone = "accent", slot = { size = "fixed", height = 30 } }))
        assert(R:Text({ id = id .. "_hint", parent = stack, text = "输入0～100的整数或点击加减。0%停用该药；保存后重新启用信号。",
            overflow = "wrap", maxLines = 2, fontSize = 12, slot = { size = "fixed", height = 40 } }))
        for index = 1, 3 do
            local i = index; editor.drafts[i] = P:Threshold(i)
            local row = assert(R:HorizontalBox({ id = id .. "_row_" .. i, parent = stack, gap = 8, slot = { size = "fixed", height = 40 } }))
            assert(R:Text({ id = id .. "_name_" .. i, parent = row, text = P.Specs[i].name, fontSize = 14, slot = { size = "fill", fill = 1 } }))
            editor.inputs[i] = assert(R:NumericInput({ id = id .. "_input_" .. i, parent = row, min = 0, max = 100, step = 1, integer = true, maxLength = 3,
                draftCommitMode = "explicit", slot = { size = "fixed", width = 76 },
                get = function() return editor.drafts[i] end,
                set = function(value) local valid = P.ThresholdNumber(value); if not valid then return false end; editor.drafts[i] = valid; return true end })) -- 中文维护：Binding只改模态会话草稿，Enter/失焦都不能写药品实际阈值或存档。
            assert(R:Text({ id = id .. "_unit_" .. i, parent = row, text = "%", slot = { size = "fixed", width = 20 } }))
            local function Step(delta)
                return Action(editor, "调整血量阈值", function()
                    local value = P.ThresholdNumber(editor.inputs[i]:GetDraftValue()) -- 中文维护：使用RSUI跨失焦草稿契约；按钮先于/后于LostFocus派发都读同一用户值。
                    if value == nil then Feedback(editor, "图" .. i .. "请输入0到100的整数，再点击加减。"); return false end
                    editor.inputs[i]:CancelEditing("lcot_threshold_step")
                    editor.drafts[i] = math.max(0, math.min(100, value + delta))
                    editor.inputs[i]:Render(editor.drafts[i], "commit")
                    Feedback(editor, "图" .. i .. "已调整为 " .. editor.drafts[i] .. "%（尚未保存）")
                    return true
                end)
            end
            editor.minus[i] = assert(R:Button({ id = id .. "_minus_" .. i, parent = row, text = "−1%", slot = { size = "fixed", width = 72 }, onClick = Step(-1) }))
            editor.plus[i] = assert(R:Button({ id = id .. "_plus_" .. i, parent = row, text = "+1%", slot = { size = "fixed", width = 72 }, onClick = Step(1) }))
        end
        local buttons = assert(R:HorizontalBox({ id = id .. "_actions", parent = stack, gap = 8, slot = { size = "fixed", height = 34 } }))
        editor.save = assert(R:Button({ id = id .. "_save", parent = buttons, text = "保存血量阈值", slot = { size = "fill", fill = 1 },
            onClick = Action(editor, "保存血量阈值", function()
                local values = {}
                for i = 1, 3 do values[i] = P.ThresholdNumber(editor.inputs[i]:GetDraftValue()); if values[i] == nil then Feedback(editor, "图" .. i .. "阈值请输入0到100的整数。"); return false end end
                local ok, err = P:ApplyThresholds(values, true) -- 中文维护：完整校验后仍由LCot原配置所有者保存及回读，RSUI不注册第二份永久Store。
                if not ok then Feedback(editor, err); return false end
                P.reason = "血量阈值已保存：" .. values[1] .. "% / " .. values[2] .. "% / " .. values[3] .. "%，请重新启用"
                P:RefreshText()
                return P:CloseThresholds()
            end) }))
        editor.defaults = assert(R:Button({ id = id .. "_defaults", parent = buttons, text = "默认：88 / 62 / 62", slot = { size = "fill", fill = 1 },
            onClick = Action(editor, "恢复默认", function()
                CancelInputs(editor, "lcot_threshold_defaults")
                for i = 1, 3 do editor.drafts[i] = P.Specs[i].threshold; editor.inputs[i]:Render(editor.drafts[i], "commit") end
                Feedback(editor, "已填入默认值，点击保存后生效。")
                return true
            end) }))
        editor.cancel = assert(R:Button({ id = id .. "_cancel", parent = buttons, text = "取消调整", slot = { size = "fill", fill = 1 }, onClick = Action(editor, "取消调整", function() return P:CloseThresholds() end) }))
        editor.status = assert(R:Text({ id = id .. "_status", parent = stack, text = "调整后点击保存；取消保留原阈值。", overflow = "wrap", maxLines = 3, fontSize = 12,
            slot = { size = "fixed", height = 54 } }))
        editor.card:SetVisibility("collapsed")
        return true
    end)
    if not built then return nil, tostring(buildError or "Suite阈值窗口构建失败") end
    return editor
end
function P:OpenThresholds()
    self:Disable("正在调整血量阈值：保存后重新启用"); self:ClosePreset()
    local suite = self:GetThresholdUI()
    local host = suite and suite.UIV3 and suite.UIV3.ModalHost
    self:ReconcileThresholdEditor()
    if not suite or suite.BootError or not suite.RSUI or not host or type(host.EnsureApplicationVisible) ~= "function" then
        self.reason = "Suite基础控件未就绪：" .. tostring(self.uiLibraryError or (suite and suite.BootError) or "公共UI文件缺失"); self:RefreshText(); return false, self.reason
    end -- 中文维护：两个Addon的TOC顺序不作为依赖就绪证据；只在用户点击时解析已就绪的Suite。
    local ready, wakeError = host:EnsureApplicationVisible()
    if not ready then self.reason = "Suite设置窗口不可用：" .. tostring(wakeError); self:RefreshText(); return false, self.reason end
    local editor, err = self.thresholdEditor
    if not editor then editor, err = BuildEditor(suite, host); self.thresholdEditor = editor end
    if not editor then self.reason = "阈值设置不可用：" .. tostring(err); self:RefreshText(); return false, self.reason end
    if editor.open then return host:Push(editor.id, editor.card, { dismissOnBackdrop = false, onClosed = function() OnClosed(editor) end }) end -- 中文维护：重复入口只激活同一模态，不能清输入或覆盖首次返回面板的意图。
    CancelInputs(editor, "lcot_threshold_open")
    for i = 1, 3 do editor.drafts[i] = self:Threshold(i); editor.inputs[i]:Render(editor.drafts[i], "commit") end
    Feedback(editor, "调整后点击保存；取消保留原阈值。")
    local opened, openError = host:Push(editor.id, editor.card, { dismissOnBackdrop = false, onClosed = function() OnClosed(editor) end })
    if not opened then self.reason = "阈值窗口打开失败：" .. tostring(openError); self:RefreshText(); return false, self.reason end
    editor.open = true; editor.returnToMain = self.panelOpen == true
    if type(host.Layout) == "function" then host:Layout() end -- 中文维护：独立Addon库宿主在用户打开时布局一次，仍消费生产RSUI布局，不新增Tick。
    self.panel:Show(false); self.panelOpen = false -- 中文维护：避免旧LCot Native面板覆盖Suite模态；编辑期间原有采样空闲门自动停读，不添加Tick。
    return true
end
