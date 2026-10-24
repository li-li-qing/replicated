-- 中文维护：独立只读插件；TOC复用Suite公共UI源码，不依赖另一个Addon的全局运行实例，不使用非白名单吃药或背包冷却接口。
local previous = LCotPotionSignal -- 中文维护：重载先让旧代次失效，防止旧 OnUpdate/事件继续显示 Ready。
if previous and type(previous.Shutdown) == "function" then pcall(previous.Shutdown, previous) end -- 中文维护：旧窗口和回调清理失败也不能阻止代次切换。
LCotPotionSignal = { generation = (previous and previous.generation or 0) + 1, widgets = {}, rows = {}, now = 0, enabled = false, running = true, error = nil } -- 中文维护：冷启动默认暂停，用户尚未核对药品和 CD 时不得发出颜色。
LCotPotionSignal.previousUsage = previous and { now = previous.now, usage = previous.usage } or nil -- 中文维护：只传递同一Lua会话的保守用药限制；重载不能消除刚使用药品的关联限制，不传递Ready或启用状态。
LCotPotionSignal.escButtonRegistered = previous and previous.escButtonRegistered == true or false -- 中文维护：同一Lua会话复用稳定菜单按钮身份；热重载只更新内容窗口和回调，不累积多个入口。
local P = LCotPotionSignal -- 中文维护：后续闭包只拥有本代次。
local allowed = { -- 中文维护：按2026-09本地白名单及RU官方更新核对；只登记本功能需要的公开读取，不借导出可见性放开其它API。
    X2Unit = { UnitHealth = true, UnitMaxHealth = true, UnitName = true }, -- 中文维护：只读取 player，本插件不监控其他玩家。
    X2Bag = { GetBagItemInfo = true, ItemStack = true, Capacity = true }, -- 中文维护：GetBagCooldown、X2Item:Cooldown、X2Action 冷却不可调用。
    X2Skill = { GetCooldown = true }, -- 中文维护：仅查用户手动用药观测到且明确选择的技能编号，禁止枚举猜 ID。
} -- 中文维护：本插件自身不使用 UseItem、技能释放、热键修改或文件系统 API。
function P:IsCurrent() return LCotPotionSignal == self and self.running end -- 中文维护：所有 Native 回调与控件操作先检查代次。
function P:Read(namespace, method, ...) -- 中文维护：统一公开读取边界，未知、抛错和逻辑返回分别由调用方处理。
    local object = _G[namespace] -- 中文维护：只使用已按核实 ABI ImportAPI 的公开对象。
    if not allowed[namespace] or not allowed[namespace][method] or not object or type(object[method]) ~= "function" then return false, nil, nil end -- 中文维护：对象存在不代表方法属于白名单。
    local ok, first, second = pcall(object[method], object, ...) -- 中文维护：保留两个 CD 返回值，不用表长度吞掉中间 nil。
    return ok, first, second -- 中文维护：ok仅表示调用未抛错，不代表药已使用或冷却为零。
end -- 中文维护：业务态归纯决策层，不由 Native 包装层猜测。
function P:HideSignal() -- 中文维护：停止颜色必须同步，不经过低频诊断刷新，也不等待下一次UI布局。
    self.signalIndex = nil -- 中文维护：缓存同时失效，下一次相同药可用时仍会重新 Show。
    if self.signal and self.signalVisible ~= false then -- 中文维护：仅在需要撤色或可见性未知时写Native，不每50ms重复Hide已隐藏的窗口。
        local ok, result = pcall(self.signal.Show, self.signal, false) -- 中文维护：Hide是撤色边界，不能在异常处理器中再次抛错递归。
        local readOk, visible = pcall(self.signal.IsVisible, self.signal) -- 中文维护：Show返回值语义不猜测，用允许的可见性getter核对真实控件状态。
        if ok and readOk and visible == false then self.signalVisible = false -- 中文维护：确认已隐藏之后才推进UI缓存。
        else self.enabled = false; self.error = "撤下色块未确认，请先停止LCot：" .. tostring(result) end -- 中文维护：物理Hide未确认不能宣称已撤色。
    end -- 中文维护：本插件不能改变卡住客户端的最后一帧；LCot实测先使用有时限的运行。
end -- 中文维护：隐藏窗口之后不排队任何按键，本插件永不发送键盘输入。
function P:Disable(reason) -- 中文维护：统一处理用户停用、配置、初始化异常和离开世界。
    self.enabled = false; if self.RefreshSignalToggle then self:RefreshSignalToggle() end -- 中文维护：撤销授权同时投影主按钮停止状态，所有停用路径不能留过时文字。
    self.reason = reason or "已暂停" -- 中文维护：保留可读原因，避免“看起来没反应”。
    self:HideSignal() -- 中文维护：用户按停用按钮当次回调就撤色。
    if self.RefreshPreviews then self:RefreshPreviews() end -- 中文维护：暂停后恢复参考模板；运行时预览从来不替代真实信号。
end -- 中文维护：不会清除药品配置或其它插件配置。
function P:Guard(action) -- 中文维护：控件/Native 处理器同用异常隔离，失败必须停止发色而不能只打印日志。
    return function(...) -- 中文维护：捕获本代次，旧控件收到迟到点击也不能修改新插件。
        if not self:IsCurrent() then return end -- 中文维护：注销API缺失时旧处理器仍保持惰性。
        local ok, err = pcall(action, ...) -- 中文维护：Lua5.1 pcall透传真实参数，不使用xpcall扩展形状。
        if not ok then self.error = tostring(err); self:Disable("插件错误：" .. self.error) end -- 中文维护：渲染/读取错误不允许留下旧色块。
    end -- 中文维护：不静默重试有副作用操作。
end -- 中文维护：UI与观察只读路径共用生命周期检查。
function P:Shutdown() -- 中文维护：精确释放本插件控件的回调，不清理公共UIParent或其它插件的全局事件。
    self.running = false; if self.CloseThresholds then pcall(self.CloseThresholds, self) end -- 中文维护：先失效闭包并释放自己阈值输入的键盘资格，旧控件不能继续捕获游戏按键。
    if self.ReleaseThresholdEditor then pcall(self.ReleaseThresholdEditor, self) end -- 中文维护：配套Suite的RSUI树、Binding和模态身份由阈值编辑器精确释放，不能只隐藏Native主面板。
    if self.ReleaseThresholdUI then pcall(self.ReleaseThresholdUI, self) end -- 中文维护：共享源码在本Addon中的UI库实例独立清理，不跨Addon操作Suite运行体。
    self:HideSignal() -- 中文维护：重载前撤掉旧色块。
    if self.presetEdit and type(self.presetEdit.EnableKeyboard) == "function" then pcall(self.presetEdit.EnableKeyboard, self.presetEdit, false) end -- 中文维护：旧分享输入必须停止捕获键盘，不清游戏聊天焦点。
    for _, widget in ipairs(self.widgets) do -- 中文维护：只处理自己建立的窗口，不触碰Suite窗口。
        for _, name in ipairs({ "OnUpdate", "OnEvent", "OnClick", "OnLostFocus" }) do -- 中文维护：控件无对应处理器时也允许幂等释放。
            if type(widget.ReleaseHandler) == "function" then pcall(widget.ReleaseHandler, widget, name) end -- 中文维护：客户端版本缺释放能力时依靠代次护栏。
        end -- 中文维护：结束本控件的处理器释放。
        if type(widget.Show) == "function" then pcall(widget.Show, widget, false) end -- 中文维护：可恢复地隐藏旧控件，不猜Destroy ABI。
    end -- 中文维护：不清空持久化配置。
end -- 中文维护：实例生命周期只由本插件拥有。
if not ADDON or type(ADDON.ImportAPI) ~= "function" or type(ADDON.ImportObject) ~= "function" then P.error = "缺少 Addon 加载接口"; return end -- 中文维护：未进入客户端时拒绝构造假运行环境。
for _, id in ipairs({ 5, 35, 42 }) do -- 中文维护：ABI来自本机rs_native_contract：BAG=5，SKILL=35（历史apitypes证据已核），UNIT=42，禁止暴力枚举。
    local ok, result = pcall(ADDON.ImportAPI, ADDON, id) -- 中文维护：只导入声明过的三种公开读取对象。
    if not ok or result == false then P.error = "读取接口导入失败：" .. tostring(id) end -- 中文维护：导入失败是未知，不能继续发Ready。
end -- 中文维护：不因一次失败重试其它数字编号。
for _, id in ipairs({ 0, 1, 2, 6, 7, 13 }) do -- 中文维护：本机NativeContract核实的WINDOW/LABEL/BUTTON/DRAWABLE/COLOR_DRAWABLE/TEXT_STYLE；不依赖共享OBJECT_TYPE。
    local ok, result = pcall(ADDON.ImportObject, ADDON, id) -- 中文维护：只导入当前界面实际需要的对象。
    if not ok or result == false then P.error = "界面对象导入失败：" .. tostring(id) end -- 中文维护：失败保留诊断原因，禁止继续发色。
end -- 中文维护：初始化不调用任何游戏消耗品或键盘API。
pcall(ADDON.ImportObject, ADDON, 3) -- 中文维护：EDITBOX=3来自NativeContract；仅显式分享窗口使用，缺失不影响基础药品信号。
