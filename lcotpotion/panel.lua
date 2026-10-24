-- 中文维护：本文件只拥有本插件的诊断窗口与色块；不接管游戏快捷栏、不修改热键、不复用Suite窗口。
local P = LCotPotionSignal -- 中文维护：所有控件归属同一个独立代次。
function P:SetObservedText(widget, value) -- 中文维护：只缓存本插件只读呈现文字，不接管输入草稿；相同内容不跨Native触发布局。
    self.textValues = self.textValues or {} -- 中文维护：缓存归属本代次及其现有控件生命周期，热重载不继承旧控件身份。
    if self.textValues[widget] == value then return end -- 中文维护：包括暂停面板的静态名称/编号/按钮，250ms诊断刷新不应反复重写。
    self.textValues[widget] = nil -- 中文维护：新值可能只写成部分Native行，开始前撤销旧签名；失败后即使回退旧文本也必须重新写完整，不能命中已失真的旧缓存。
    local result = widget:SetText(value) -- 中文维护：仍使用原公开SetText；抛错沿原Guard处理，不用缓存掩盖拒写。
    if result ~= false then self.textValues[widget] = value end -- 中文维护：void setter允许nil返回，但明确false不能提交缓存，后续刷新仍可重试。
end -- 中文维护：该缓存只减少呈现写入，不参与HP、库存、CD或Ready决策。
local serial = 0 -- 中文维护：控件物理身份唯一，避免热重载与旧窗口重名。
function P:Widget(kind, parent, x, y, width, height) -- 中文维护：统一核实过的公开 CreateWidget ABI，顶层父级用可靠的UIParent字符串。
    serial = serial + 1 -- 中文维护：即使同种控件也不能复用Native物理名称。
    local name = "lcot_potion_" .. tostring(self.generation) .. "_" .. tostring(serial) -- 中文维护：代次参与名称，旧控件迟到回调不得映射到新控件。
    local widget -- 中文维护：构造失败由上层Guard停止信号，不造mock窗口。
    if kind == "window" or kind == "button" then widget = UIParent:CreateWidget(kind, name, parent or "UIParent", "") -- 中文维护：window/button第四参数是category字符串，不能传布尔。
    else widget = UIParent:CreateWidget(kind, name, parent or "UIParent") end -- 中文维护：label使用项目已验证的三参数构造车道。
    assert(widget, "无法创建" .. kind) -- 中文维护：Native nil是失败，不是空控件。
    self.widgets[#self.widgets + 1] = widget -- 中文维护：先登记所有权，后续布局失败也可清理。
    widget:SetExtent(width, height) -- 中文维护：所有正文明确尺寸，避免出现1×1内容。
    widget:AddAnchor("TOPLEFT", parent or "UIParent", x, y) -- 中文维护：左上角坐标为正X向右、正Y向下，不进行未核实的DPI补偿。
    widget:Show(true) -- 中文维护：初始诊断可见；信号窗口随后立即隐藏。
    return widget -- 中文维护：不读取任何药品事实。
end -- 中文维护：构造仅属于UI层。
function P:Text(parent, x, y, width, height, text, size) -- 中文维护：正文和提示统一使用可读字号，不让配置挤在单行表格中。
    local lineHeight = (size or 15) + 4 -- 中文维护：RU截图已显示Label会压平换行；用真实独立行矩形保证说明、诊断和ID面板不会互相覆盖。
    local count = math.max(1, math.floor(height / lineHeight)) -- 中文维护：行数由已分配区域有界决定，不随高频内容增建Native控件。
    if count > 1 then -- 中文维护：多行显示属于呈现层，不复制药品状态或调度任务。
        local view = { labels = {}, text = nil } -- 中文维护：轻量呈现对象只保留文本签名，所有Native行仍在本实例widgets中拥有生命周期。
        for i = 1, count do view.labels[i] = self:Text(parent, x, y + (i - 1) * lineHeight, width, lineHeight, "", size) end -- 中文维护：每个子行高度仅能容纳一行，递归在单行分支结束，避免依赖Native多行语义。
        function view:SetText(value) -- 中文维护：各行投影由统一文本入口维护，调用方无需手动拆说明文字。
            value = tostring(value or ""); if self.text == value then return true end -- 中文维护：只有上次整组写入完成才可命中缓存，不能在第一行拒写前先认定整段已显示。
            self.text = nil -- 中文维护：子行即将分步写入，旧整段签名先失效；第二行拒写或抛错后回退旧值也必须恢复首行，不能留下新旧混合文本。
            local lines = {}; for line in (value .. "\n"):gmatch("(.-)\n") do lines[#lines + 1] = line end -- 中文维护：保留明确空行，单行不含隐藏换行字符。
            for i, row in ipairs(self.labels) do -- 中文维护：逐行确认setter未明确拒绝；任一false透传到外层文本缓存，异常也不得提前提交本层签名。
                if row:SetText(lines[i] or "") == false then return false end -- 中文维护：子Label明确拒写时保留旧签名，下一次250ms刷新仍会重试整段。
                if row:Show(lines[i] ~= nil and lines[i] ~= "") == false then return false end -- 中文维护：空余行隐藏也属于本次呈现提交，不能缓存尚未完成的行可见性。
            end -- 中文维护：成功写完全部子行后才允许外层跳过相同文本。
            self.text = value; return true -- 中文维护：缓存提交是最后一步，子控件抛错或拒写都不会让失败文本永久失去重试机会。
        end -- 中文维护：呈现对象不成为Native父容器，不能用于游戏状态读取。
        view:SetText(text); return view -- 中文维护：首次显示即拆行，后续诊断仍复用这些真实Label。
    end -- 中文维护：药名、编号、按钮标题等明确单行区域保留原生对象。
    local label = self:Widget("label", parent, x, y, width, height) -- 中文维护：label自身不能捕获鼠标，避免挡住游戏。
    label:EnablePick(false) -- 中文维护：显示文字不接管点击。
    label:SetText(text or "") -- 中文维护：动态内容由明确的诊断刷新提交。
    label.style:SetFontSize(size or 15) -- 中文维护：诊断不依赖外部字体或参考项目样式。
    label.style:SetColor(1, 1, 1, 1) -- 中文维护：深色背景上保持足够对比。
    if ALIGN_LEFT ~= nil then label.style:SetAlign(ALIGN_LEFT) end -- 中文维护：使用客户端导出的常量，不猜对齐枚举值。
    return label -- 中文维护：可供后续增量SetText。
end -- 中文维护：没有数据采集副作用。
function P:Background(widget, r, g, b, a) -- 中文维护：纯颜色Drawable只用白名单方法，色块没有纹理、渐变或透明中心。
    local drawable = widget:CreateColorDrawable(r, g, b, a, "background") -- 中文维护：固定背景层，禁止放到会吞掉输入的公共全局控件。
    assert(drawable, "无法创建颜色背景") -- 中文维护：绘制失败不能留下错误Ready外观。
    drawable:AddAnchor("TOPLEFT", widget, 0, 0) -- 中文维护：与本控件同源锚点，不手算屏幕位置。
    drawable:AddAnchor("BOTTOMRIGHT", widget, 0, 0) -- 中文维护：随已明确尺寸的控件填满。
    return drawable -- 中文维护：渲染层持有Drawable生命周期。
end -- 中文维护：颜色不受图片资源库的缩放影响。
function P:Button(parent, x, y, width, text, action) -- 中文维护：所有动作有明确文本，不引入无标题窗口。
    local button = self:Widget("button", parent, x, y, width, 30) -- 中文维护：统一30px点击区，避免小字号按钮。
    local normal = self:Background(button, 0.14, 0.23, 0.33, 1) -- 中文维护：按钮四态由Native按钮状态机显示，不按每帧鼠标位置猜悬浮。
    local hover = self:Background(button, 0.24, 0.40, 0.57, 1) -- 中文维护：悬浮提升亮度与对比，用户能明确知道当前位置可点击。
    local pushed = self:Background(button, 0.09, 0.16, 0.25, 1) -- 中文维护：按下后背景加深；松开由Native自动恢复当前正常或悬浮态。
    local disabled = self:Background(button, 0.10, 0.12, 0.15, 1) -- 中文维护：不可用按钮保留边界，状态Drawable仅属于本按钮。
    button:SetNormalBackground(normal); button:SetHighlightBackground(hover); button:SetPushedBackground(pushed); button:SetDisabledBackground(disabled) -- 中文维护：白名单ABI与本机Theme的ColorDrawable背景一致，所有本插件按钮共用此入口。
    button:SetText(text) -- 中文维护：不使用用户不理解的虚拟键码入口。
    button.style:SetFontSize(14) -- 中文维护：整段按钮名称可以读完。
    button.style:SetColor(1, 1, 1, 1) -- 中文维护：保持可读性。
    button:SetHandler("OnClick", self:Guard(function(_, mouse) -- 中文维护：每个点击受代次和异常护栏保护。
        if mouse == nil or mouse == "LeftButton" then action() end -- 中文维护：仅接受左键，右键不执行配置。
    end)) -- 中文维护：处理器由本实例Shutdown精确释放。
    return button -- 中文维护：业务层可以修改状态文字。
end -- 中文维护：没有隐藏的自动吃药动作。
function P:ApplySignalGeometry(force) -- 中文维护：这是本插件32物理像素输出协议的唯一缩放入口，不改变游戏全局UI或面板偏好。
    if not self.signal then return false end -- 中文维护：Native信号尚未创建时不能推进几何缓存。
    if not force and self.signalUiScale and self.signalScaleAt and self.now - self.signalScaleAt < 250 then return true end -- 中文维护：最多每250ms读取一次全局UI比例，避免16ms药品采样反复查询布局。
    local ok, scale = false, nil -- 中文维护：缺少公开Getter属于未知，不能把90%静默当100%。
    if UIParent and type(UIParent.GetUIScale) == "function" then ok, scale = pcall(UIParent.GetUIScale, UIParent) end -- 中文维护：本地api_functions.lua允许此读取，签名与Suite当前GetUiMetrics一致，不探测私有渲染API。
    scale = ok and tonumber(scale) or nil -- 中文维护：全局缩放只消费有效标量，未读取成功不沿用旧值。
    if not scale or scale ~= scale or scale < 0.5 or scale > 2 then self.signalUiScale = nil; self:Disable("UI缩放读取无效，药品色块已撤下"); return false end -- 中文维护：有界正比例保护除法和Native布局，0/NaN/缺接口不得留下旧Ready。
    self.signalScaleAt = self.now -- 中文维护：仅有效读取推进补采时间；Native写入失败仍不提交比例缓存。
    if self.signalUiScale == scale then return true end -- 中文维护：同一比例零几何写入，降低游戏主线程渲染与布局压力。
    self.signalUiScale = nil -- 中文维护：发现比例变化立即废弃旧几何；Native写入异常后重新启用不能命中旧缓存。
    self:HideSignal() -- 中文维护：先同步撤色再调整几何，不能让LCot识别变形中的旧状态。
    if type(self.signal.SetScale) ~= "function" or type(self.signal.RemoveAllAnchors) ~= "function" then self.signalUiScale = nil; self:Disable("客户端无法固定色块像素大小"); return false end -- 中文维护：只依赖当前白名单Widget方法，能力缺失保持停用。
    if self.signal:SetScale(1 / scale) == false then self:Disable("色块缩放写入失败"); return false end -- 中文维护：抵消UiParent比例；32/28/24和2像素边框只继承一次补偿，明确拒写不能提交缓存。
    if self.signal:RemoveAllAnchors() == false then self:Disable("色块锚点清理失败"); return false end -- 中文维护：只清自己的信号锚点，明确失败保持撤色，不能在旧约束上叠加新位置。
    if self.signal:AddAnchor("TOPLEFT", "UIParent", 16 / scale, 16 / scale) == false then self:Disable("色块位置写入失败"); return false end -- 中文维护：锚点属于UiParent逻辑坐标，固定16物理像素只转换一次，明确拒写不得发色。
    self.signalUiScale = scale -- 中文维护：完成全部Native写入后才缓存几何；发色仍需下一次实时药品Ready决定。
    return true -- 中文维护：这里只验证布局契约，真实RU像素仍需90%和100%实机识别验收。
end -- 中文维护：全局UI缩放与面板缩放是独立状态，不持久化临时像素或Ready结果。
function P:RenderSignal(index) -- 中文维护：每一轮重算结果必须提交；nil要真正Hide，不能仍保留绿色方块。
    if not index then self:HideSignal(); return end -- 中文维护：CD开始、缺货、死亡、暂停及未知时同步撤色。
    if not self:ApplySignalGeometry(false) then return end -- 中文维护：缩放未知或布局不可用时禁止发色；配置变化后必须重新采样当前药品状态。
    if self.signalIndex ~= index then -- 中文维护：只有颜色变更时跨Native写入，避免每帧重建控件。
        local rgb = self.Specs[index].rgb -- 中文维护：单色协议1绿、3蓝、2黄；识别ROI只覆盖此控件。
        self.signalColor:SetColor(rgb[1], rgb[2], rgb[3], 1) -- 中文维护：alpha必须1，背景游戏画面不能混入颜色。
        self.signalVisible = nil -- 中文维护：写Show前把旧隐藏缓存置未知，读回失败时Guard必须真正尝试撤色。
        self.signal:Show(true) -- 中文维护：只有当轮严格Ready结果才会显色。
        assert(self.signal:IsVisible() == true, "色块显示未确认") -- 中文维护：setter未抛错不是可见性证据，读回失败就由Guard停用。
        self.signalVisible = true -- 中文维护：只在控件确实可见后记显示缓存。
        self.signalIndex = index -- 中文维护：成功写入后才推进显示缓存。
    end -- 中文维护：持续可用时保留颜色，让LCot持续重新识别后按药键。
end -- 中文维护：本插件不生成按键队列。
function P:Swatch(parent, x, y, rgb) -- 中文维护：真实信号与面板参考色块共用几何，用户可按实际游戏缩放截取模板。
    local outer = self:Widget("window", parent, x, y, 32, 32) -- 中文维护：32px逻辑几何，实机像素大小由客户端当前UI缩放决定。
    outer:EnablePick(false) -- 中文维护：色块不挡鼠标。
    self:Background(outer, 1, 1, 1, 1) -- 中文维护：白色外边框。
    local inner = self:Widget("window", outer, 2, 2, 28, 28) -- 中文维护：黑框保持与真实信号相同的层级和偏移。
    inner:EnablePick(false) -- 中文维护：纯显示。
    self:Background(inner, 0, 0, 0, 1) -- 中文维护：黑色边框。
    local center = self:Widget("window", inner, 2, 2, 24, 24) -- 中文维护：固定24px核心。
    center:EnablePick(false) -- 中文维护：核心不捕获输入。
    local fill = self:Background(center, rgb[1], rgb[2], rgb[3], 1) -- 中文维护：RGB不透明，不把背景颜色混入模板。
    return outer, fill -- 中文维护：参考色块永远留在设置面板，不能出现在LCot的左上信号ROI。
end -- 中文维护：预览不会改动药品Ready事实。
function P:SetPanelScale(percent, persist) -- 中文维护：缩放只影响设置面板，真实信号尺寸和位置必须稳定供LCot识别。
    percent = math.max(75, math.min(125, tonumber(percent) or 100)) -- 中文维护：字号与点击区有可读下限，不能缩到无法操作。
    if type(self.panel.SetScale) ~= "function" then self.reason = "客户端不支持窗口缩放，可用右上角收起"; return false end -- 中文维护：Native能力缺失给出可执行替代，不破坏整个插件。
    local ok, result = pcall(self.panel.SetScale, self.panel, percent / 100) -- 中文维护：仅调用白名单Widget:SetScale，不改变游戏全局UI比例。
    if not ok or result == false then self.reason = "窗口缩放失败，可用右上角收起"; return false end -- 中文维护：setter失败不能显示已生效的比例。
    self.panelScale = percent -- 中文维护：只有Native接受后才保存偏好。
    if self.titleLabel then self:SetObservedText(self.titleLabel, "LCot 药品信号 · 设置（" .. percent .. "%）") end -- 中文维护：缩放与常规诊断共用文字缓存，不能绕过缓存留下错误的旧标题。
    for _, swatch in ipairs(self.referenceSwatches or {}) do if type(swatch.SetScale) == "function" then swatch:SetScale(100 / percent) end end -- 中文维护：模板参考块抵消面板缩放，核心大小保持与真实信号一致。
    if persist then self:SaveBindings() end -- 中文维护：偏好与绑定同一存档，重开不会又变大。
    return true -- 中文维护：实际Native视觉与命中范围仍需用户实机检查。
end -- 中文维护：不缩放调度宿主、启动入口或信号区域。
function P:ClosePreset() -- 中文维护：只释放本插件分享输入的键盘资格，不调用全局ClearFocus抢走游戏聊天焦点。
    if self.presetEdit then if type(self.presetEdit.EnableKeyboard) == "function" then self.presetEdit:EnableKeyboard(false) end; if type(self.presetEdit.EnableFocus) == "function" then self.presetEdit:EnableFocus(false) end end -- 中文维护：隐藏前停止本输入控件接收按键。
    if self.presetWindow then self.presetWindow:Show(false) end -- 中文维护：保存内容仍在内存，关闭不丢已提交药品。
end -- 中文维护：输入框只由用户显式点击激活。
function P:CollapsePanel() -- 中文维护：顶部收起无需滚到窗口底部，记录状态与配置不因隐藏丢失。
    self:ClosePreset(); self:CloseThresholds() -- 中文维护：收起只关闭本插件两类编辑焦点，不清游戏聊天或其它插件输入。
    if self.selector then self.selector:Show(false) end -- 中文维护：子窗口不能在主窗口收起后挡住游戏。
    self.panelOpen = false; self.panel:Show(false) -- 中文维护：保持已暂停状态或当前记录，让用户能手动在游戏里用药。
end -- 中文维护：左上设置入口可重新展开。
function P:BuildPresetWindow() -- 中文维护：仅构造显式分享界面；输入能力缺失交由OpenPreset隔离，不影响基础药品功能。
    self:Disable("分享或导入预设：色块已撤下") -- 中文维护：编辑输入期间绝不输出自动按药信号。
    if not self.presetWindow then -- 中文维护：首次显式打开才创建输入，不增加冷启动键盘焦点。
        self.presetWindow = self:Widget("window", self.panel, 16, 100, 708, 324) -- 中文维护：属于设置面板，缩小与收起同时生效。
        self:Background(self.presetWindow, 0.08, 0.13, 0.19, 1) -- 中文维护：弹窗文字和输入区不被原三行读数干扰。
        self:Text(self.presetWindow, 16, 12, 676, 30, "药品 ID 与冷却记录 · 复制 / 导入", 18) -- 中文维护：明确这是共享校准结果，不是注册码或游戏快捷键。
        self:Text(self.presetWindow, 16, 48, 676, 44, "测试后点“选中复制码”，按 Ctrl+C，把整行发给我，就能直接写入插件预设。\n下面同时显示物品ID与已验证技能ID；未记录部分不会冒充验证成功。", 14) -- 中文维护：不能把未验证0占位宣传成可用药品。
        self.presetInfoLabel = self:Text(self.presetWindow, 16, 94, 676, 92, "", 14) -- 中文维护：四行分列三种药ID与两个关联方向，不把所有参数塞进单行。
        serial = serial + 1 -- 中文维护：输入控件与其他控件使用同一物理唯一身份。
        local name = "lcot_potion_" .. self.generation .. "_" .. serial -- 中文维护：代次确保旧输入不能映射到新插件。
        self.presetEdit = self.presetWindow:CreateChildWidgetByType(3, name, 0, true) -- 中文维护：NativeContract核实的EDITBOX=3，采用本工程真实typed child ABI。
        assert(self.presetEdit, "无法创建预设输入框") -- 中文维护：不存在输入控件不能宣称可复制导入。
        self.widgets[#self.widgets + 1] = self.presetEdit -- 中文维护：归属本实例，重载时释放处理器与键盘资格。
        local edit = self.presetEdit -- 中文维护：输入对象不泄露到公共全局。
        edit:SetExtent(676, 38); edit:AddAnchor("TOPLEFT", self.presetWindow, 16, 192) -- 中文维护：最长160字符上限，实际分享码通常不到100字符。
        edit:SetMaxTextLength(160); edit:Enable(true); edit:EnablePick(true); edit:EnableFocus(false); edit:EnableKeyboard(false) -- 中文维护：构造和仅展示分享码时不抢游戏键盘。
        edit:ClearTextOnEnter(false); edit:SetReadOnly(false); edit:UseSelectAllWhenFocused(true) -- 中文维护：用户点入后便于Ctrl+C或Ctrl+V，不用无法核实的通用键盘回调。
        edit.style:SetFontSize(14); edit.style:SetColor(1, 1, 1, 1); self:Background(edit, 0.02, 0.04, 0.06, 1) -- 中文维护：输入区与弹窗清楚区分。
        edit:SetHandler("OnClick", self:Guard(function(_, mouse) if mouse == nil or mouse == "LeftButton" then edit:EnableFocus(true); edit:EnableKeyboard(true); edit:SetFocus() end end)) -- 中文维护：仅明确左键激活本输入，不依赖未验证OnKeyDown事件。
        edit:SetHandler("OnLostFocus", self:Guard(function() edit:EnableKeyboard(false) end)) -- 中文维护：焦点离开时关闭本控件键盘资格，不清别人焦点。
        self:Button(self.presetWindow, 16, 244, 210, "选中复制码（Ctrl+C）", function() edit:SetText(self:ExportPreset()); edit:EnableFocus(true); edit:EnableKeyboard(true); edit:SetFocus() end) -- 中文维护：用户明确点击才选中当前真实映射，Ctrl+C由游戏Native输入负责，不调用未知剪贴板接口。
        self:Button(self.presetWindow, 234, 244, 210, "导入并保存预设", function() local ok, err = self:ApplyPreset(edit:GetText(), true); self.reason = ok and "预设已导入并保存，请核对库存后启用" or err; if ok then self:ClosePreset() end; self:RefreshText() end) -- 中文维护：完整校验成功后才提交，错误不覆盖原记录。
        self:Button(self.presetWindow, 452, 244, 240, "关闭预设窗口", function() self:ClosePreset() end) -- 中文维护：关闭停止输入但不取消已保存结果。
    end -- 中文维护：后续打开复用同一个输入框，避免累积Native控件。
    self.presetInfoLabel:SetText(self:FormatIdInfo()) -- 中文维护：每次显式打开取得最新已提交映射，不显示上次窗口遗留的技能编号。
    self:ClosePreset(); self.presetEdit:SetText(self:ExportPreset()); self.presetEdit:Show(true); self.presetWindow:Show(true); self.presetWindow:Raise() -- 中文维护：仅显示不会自动SetFocus，用户点击后才接收键盘。
end -- 中文维护：分享码不包含本机配置路径或游戏账户。
function P:OpenPreset() -- 中文维护：可选分享输入构造失败只关闭弹窗，不将整个药品插件置永久错误。
    local before = #self.widgets -- 中文维护：记录本次新建的精确所有权范围，清理不触碰其它窗口。
    local ok, err = pcall(self.BuildPresetWindow, self) -- 中文维护：当前客户端可能缺少typed edit能力，不能把存在ImportObject等同已验证。
    if not ok then -- 中文维护：仅清理本次失败的分享控件，设置窗口与既有记录仍可用。
        if self.presetEdit and type(self.presetEdit.EnableKeyboard) == "function" then pcall(self.presetEdit.EnableKeyboard, self.presetEdit, false) end -- 中文维护：失败前若有输入资格也必须释放。
        for i = before + 1, #self.widgets do local widget = self.widgets[i]; if type(widget.Show) == "function" then pcall(widget.Show, widget, false) end end -- 中文维护：已登记但半构造的子控件不能继续遮挡或接收输入。
        if self.presetWindow then pcall(self.presetWindow.Show, self.presetWindow, false) end -- 中文维护：已有弹窗重开失败同样撤下。
        self.presetWindow, self.presetEdit = nil, nil -- 中文维护：下次明确点击可以重试，不复用无效的半构造对象。
        self.reason = "预设输入窗口不可用：" .. tostring(err); self:RefreshText() -- 中文维护：显示实际失败，保留基础记录、启用与缩放入口。
    end -- 中文维护：分享失败不丢掉本机保存的校准结果。
end -- 中文维护：不捕获全局键盘，不需要任何外部通讯。
function P:RefreshPreviews() -- 中文维护：运行时隐藏面板固定预览色，防止LCot误把常亮样本当成真实用药信号。
    local visible = not self.enabled -- 中文维护：只有暂停状态可供截取参考模板，真实信号生命周期独立。
    if self.previewsVisible == visible then return end; self.previewsVisible = visible -- 中文维护：可见性变化时才写Native，不每250ms重复布局。
    for _, swatch in ipairs(self.referenceSwatches or {}) do swatch:Show(visible) end -- 中文维护：只隐藏本插件预览，不改真实信号、游戏画面或其它插件窗口。
end -- 中文维护：模板参考不能拥有Ready权限。
function P:RefreshSignalToggle() -- 中文维护：主按钮只投影真实enabled，关闭再打开不能显示过时的启用文字。
    if self.signalToggle then self:SetObservedText(self.signalToggle, self.enabled and "停止用药信号" or "启用用药信号") end -- 中文维护：启停变化才写按钮，错误/切世界/用户停止仍在当前回调立即更新，不等低频刷新。
end -- 中文维护：按钮文字不授予或撤销用药权限。
function P:SetPanelVisible(visible) -- 中文维护：菜单和收起共用可见性入口；只查看运行状态不会暂停或夺取游戏聊天焦点。
    if not visible then self:CollapsePanel(); return end -- 中文维护：关闭精确释放本插件输入控件，不清全局焦点。
    self.panelOpen = true; self.panel:Show(true); self.panel:Raise(); self:Sample(); self:RefreshText() -- 中文维护：重新展开立即投影实际血量和CD，不显示旧Ready缓存。
end -- 中文维护：只变配置面板需求，不改变当前信号授权。
function P:RegisterEscMenu() -- 中文维护：采用本工程已核实的ADDON菜单ABI；独立固定内容ID与Suite的91730分开。
    if self.escRegistered then return true end -- 中文维护：同代次注册幂等，不因反复打开窗口添加重复按钮。
    local contentId = 91731 -- 中文维护：稳定私有菜单身份；游戏重载通过同ID替换内容回调，不能每代次换编号。
    local function Call(method, ...) -- 中文维护：仅列出的三项白名单注册方法可跨Native边界，返回false或抛错必须保留失败。
        if type(ADDON[method]) ~= "function" then return false, method .. "不可用" end -- 中文维护：缺接口时不能收起唯一可访问的设置窗口。
        local ok, result = pcall(ADDON[method], ADDON, ...) -- 中文维护：ADDON冒号ABI保留真实参数，不沿官方公告的X2拼法猜命名空间。
        return ok and result ~= false, result -- 中文维护：这些注册setter允许nil返回；不是用nil推断药品就绪。
    end -- 中文维护：本闭包不导入其它插件的菜单桥或公共globals。
    local ok, err = Call("RegisterContentWidget", contentId, self.panel) -- 中文维护：真实窗口先登记，再登记控制其显示的本代次回调。
    if ok then -- 中文维护：部分注册失败不得伪称入口完成，也不隐藏当前诊断窗口。
        self.escTrigger = self:Guard(function(show) -- 中文维护：Native迟到的旧代次菜单回调保持惰性，不能复活旧窗口或颜色。
            local kind, visible = type(show), nil -- 中文维护：兼容当前Suite实际使用的布尔/数字/明确字符串开关合同。
            if kind == "boolean" then visible = show elseif kind == "number" then visible = show ~= 0 elseif kind == "string" then -- 中文维护：只解释明确的开关词，不把任意非空字符串当打开。
                local value = string.lower(show); if value == "1" or value == "true" or value == "on" or value == "show" then visible = true elseif value == "0" or value == "false" or value == "off" or value == "hide" then visible = false end -- 中文维护：未经识别的命令回退为本窗口切换，不执行其它动作。
            end -- 中文维护：所有类型最终都只控制本插件的面板。
            if visible == nil then visible = not self.panelOpen end -- 中文维护：无参数菜单触发按当前本插件可见需求切换，不猜公共UI状态。
            self:SetPanelVisible(visible) -- 中文维护：打开状态页不暂停；编辑映射和复制输入仍各自先暂停。
        end) -- 中文维护：回调由内容ID替换注册及代次护栏共同管理。
        ok, err = Call("RegisterContentTriggerFunc", contentId, self.escTrigger) -- 中文维护：真实触发函数与真实窗口使用同一个固定ID。
    end -- 中文维护：两个注册均成功之后才添加可见菜单入口。
    if ok and not self.escButtonRegistered then -- 中文维护：同Lua会话已创建的Native按钮不再追加，内容与回调在上方更新。
        ok, err = Call("AddEscMenuButton", 3, contentId, "info", "LCot 用药信号") -- 中文维护：分类3与info图标来自本机Suite已用的四参数ABI。
        if not ok then ok, err = Call("AddEscMenuButton", 3, contentId, "info", "LCot 用药信号", { buttonType = 1, buttonValue = 1, colorKey = "situation_01" }) end -- 中文维护：仅使用本工程已存在的新版五参数兼容路径，不尝试其它编号或未知图标。
        self.escButtonRegistered = ok -- 中文维护：按钮失败不能推进已注册缓存，后续明确重载仍可恢复。
    end -- 中文维护：稳定按钮不拥有实时Ready权限。
    self.escRegistered = ok; if not ok then self:Disable("Esc 菜单入口注册失败：" .. tostring(err)); self:SetPanelVisible(true) end -- 中文维护：失败保持设置可访问并可见诊断，不重新引入屏幕悬浮按钮。
    return ok -- 中文维护：菜单调用成功仍需用户重载后在原生菜单核对真实入口。
end -- 中文维护：运行HUD只剩满足条件时出现的色块，不显示常驻设置按钮。
function P:BuildPanel() -- 中文维护：独立UI先建隐藏信号，再建诊断，初始化失败不能出现可匹配颜色。
    self.driver = self:Widget("window", nil, 0, 0, 1, 1) -- 中文维护：独立插件自己的唯一调度/事件宿主，不占用Suite的OnUpdate。
    self.driver:EnablePick(false) -- 中文维护：1px宿主不截获游戏输入。
    self.signal, self.signalColor = self:Swatch(nil, 16, 16, { 0, 0, 0 }) -- 中文维护：初始化只能短暂构造黑色，不存在可用绿/蓝/黄。
    self:HideSignal() -- 中文维护：构造完成立即Hide并读回确认，后续只有纯决策Ready才能显示。
    self:ApplySignalGeometry(true) -- 中文维护：冷启动按当前UI比例固定32物理像素及16像素偏移，朋友90%无需重新截图模板。
    self.panel = self:Widget("window", nil, 64, 64, 740, 664) -- 中文维护：关联CD验证有独立一行，不挤压原有读数或取消入口。
    self.panelOpen = true -- 中文维护：记录本插件实际显示操作的窗口需求，不每帧调用Native可见性getter。
    self:Background(self.panel, 0.045, 0.065, 0.085, 0.97) -- 中文维护：正文背景自足，不依赖外部窗口皮肤。
    self.titleLabel = self:Text(self.panel, 16, 12, 406, 30, "LCot 药品信号 · 设置", 18) -- 中文维护：标题为右上缩放和收起留足空间，窗口小屏也可操作。
    self:Button(self.panel, 430, 12, 82, "缩小", function() self:SetPanelScale((self.panelScale or 100) - 5, true) end) -- 中文维护：每次缩小5%，下限75%，只作用设置面板。
    self:Button(self.panel, 520, 12, 82, "放大", function() self:SetPanelScale((self.panelScale or 100) + 5, true) end) -- 中文维护：放大到125%，不改变LCot真实色块。
    self:Button(self.panel, 610, 12, 96, "收起", function() self:CollapsePanel() end) -- 中文维护：顶部即可收起，不要求找到底部按钮。
    self:Text(self.panel, 16, 46, 700, 52, "三种物品与技能ID已内置，自动定位背包；直接点“启用用药信号”。\n低血量优先图3，再图1，图2备用；重新记录和关联核对仅用于可选校验。", 14) -- 中文维护：流程直接放在UI中，不新增操作文档。
    self.healthLabel = self:Text(self.panel, 16, 101, 700, 30, "血量：等待读取", 16) -- 中文维护：诊断与决策共享同轮血量，不能伪造百分比。
    self.referenceSwatches = {} -- 中文维护：参考模板抵消面板缩放，避免截图大小与真实信号不一致。
    self.thresholdButtons, self.thresholdButtonValues = {}, {} -- 中文维护：各药血线提供明确可点击入口，显示与保存/决策共用Threshold，不再看起来是固定只读值。
    self.rowLabels, self.rowDetailLabels, self.itemButtons, self.candidateButtons, self.idLabels = {}, {}, {}, {}, {} -- 中文维护：固定3行，不每帧重建控件。
    for index, spec in ipairs(self.Specs) do -- 中文维护：每行独立配置，颜色名称和阈值始终可见。
        local i, y = index, 139 + (index - 1) * 89 -- 中文维护：Lua5.1闭包显式捕获当行身份，禁止循环结束后全指向图3。
        self.rowLabels[i] = self:Text(self.panel, 16, y, 242, 21, spec.name, 15) -- 中文维护：药名和血线设置分区，给数字入口留足宽度，不覆盖右侧物品ID。
        self.thresholdButtons[i] = self:Button(self.panel, 270, y - 2, 100, "≤" .. self:Threshold(i) .. "% 设置", function() self:OpenThresholds() end) -- 中文维护：沿用完整数字编辑、保存/取消和恢复默认流程；进入时先撤色，草稿不驱动用药信号。
        self.thresholdButtons[i]:SetExtent(100, 24); self.thresholdButtonValues[i] = self:Threshold(i) -- 中文维护：按钮下沿止于下一行状态起点，缩放75%至125%仍与正文共用同一布局空间。
        self.rowDetailLabels[i] = self:Text(self.panel, 16, y + 22, 644, 21, "等待读取库存与冷却", 14) -- 中文维护：库存/CD/状态用第二个单行Label，明确与上方药名和编号隔开。
        self.idLabels[i] = self:Text(self.panel, 382, y, 278, 21, "物品 ID：" .. self.FixedItemIds[i] .. "  | 技能 ID：未记录", 12) -- 中文维护：独立右侧只读信息与药名同排，下方库存和验证状态不被挤成一行。
        self.referenceSwatches[i] = self:Swatch(self.panel, 668, y + 2, spec.rgb) -- 中文维护：单独保存外层供反向缩放，核心大小保持真实信号模板。
        self.itemButtons[i] = self:Button(self.panel, 16, y + 45, 306, "选择背包中的药品", function() self:OpenSelector(i) end) -- 中文维护：用户选择真实名称，不需要输入物品ID。
        self:Button(self.panel, 330, y + 45, 122, "重录（可选）", function() self:Arm(i) end) -- 中文维护：记录必须由用户显式开始。
        self.candidateButtons[i] = self:Button(self.panel, 460, y + 45, 246, "等待手动用药记录", function() self:BindCandidate(i) end) -- 中文维护：候选不能未经用户核对自动升级为药品身份。
    end -- 中文维护：配置行只消费本插件状态。
    self.messageLabel = self:Text(self.panel, 16, 396, 700, 75, "当前暂停。三种映射已内置，血量与CD可读后即可启用。", 14) -- 中文维护：解释未知状态，不把无反应隐藏掉。
    self.signalToggle = self:Button(self.panel, 16, 483, 174, "启用用药信号", function() if self.enabled then self:Disable("用户停止用药信号"); self:RefreshText() else self:EnableSignal() end end) -- 中文维护：单一启停入口消费真实运行态，重开显示停止；停止同步撤色。
    self:Button(self.panel, 198, 483, 144, "血量阈值设置", function() self:OpenThresholds() end) -- 中文维护：三个百分比可自由调整并保存；启停合并到左侧主按钮，避免同时显示启用与暂停。
    self:Button(self.panel, 350, 483, 166, "取消冷却记录", function() self.arm = nil; self.armCross = nil; self:Disable("记录已取消"); self:RefreshText() end) -- 中文维护：取消覆盖普通记录和关联记录，不保存、不继续收集事件。
    self:Button(self.panel, 524, 483, 182, "收起窗口", function() self:CollapsePanel() end) -- 中文维护：收起和启用是两个明确动作。
    self:Button(self.panel, 16, 523, 276, "关联冷却实测（可选）", function() self:BeginCross() end) -- 中文维护：可选记录只补观察证据；正常用药始终同时检查实际CD与用户确认的30/60秒规则。
    self.crossLabel = self:Text(self.panel, 302, 523, 404, 44, "图3→图2：待核对\n图2→图3：待核对", 14) -- 中文维护：两个方向各保留证据，不把一次成功当双向合同。
    self:Text(self.panel, 16, 573, 700, 39, "右侧参考色块可截成模板；LCot搜索范围只框左上真实信号位置。\nLCot每次重新匹配后只按一次，持续匹配时重复；未找到时不执行动作。", 14) -- 中文维护：预览不能被运行规则全屏搜索匹配，避免设置面板常亮色导致持续误按。
    self:Button(self.panel, 16, 619, 216, "分享 / 导入药品预设", function() self:OpenPreset() end) -- 中文维护：已验证结果可跨用户复用，不共享背包位置。
    self:Button(self.panel, 240, 619, 216, "重新定位背包药品", function() local ok, err = self:LocateItems(); self.reason = ok and "已按固定ID重新定位，冷却记录保留" or err; self:RefreshText() end) -- 中文维护：排序或移动后恢复位置，不重新消耗药验证。
    self:Button(self.panel, 464, 619, 242, "查看 / 复制三种药品 ID", function() self:OpenPreset() end) -- 中文维护：明确提供给用户实测后回传ID的入口，复用同一预设窗口和验证Authority。
    self:SetPanelScale(self.panelScale or 100, false) -- 中文维护：启动恢复缩放但不写存档，真实信号不参与。
end -- 中文维护：布局完成不代表Native API已实机验证。
function P:OpenSelector(index) -- 中文维护：背包读取仅在用户明确选药时全量扫描，不在每帧扫描240格。
    self:Disable("选择药品：色块已撤下") -- 中文维护：配置改变之前先撤掉信号。
    local entries, err = self:ScanBag() -- 中文维护：有界只读扫描，失败不把背包当空。
    if not entries then self.reason = err; self:RefreshText(); return end -- 中文维护：实际未知留给用户诊断。
    local filtered = {}; for _, entry in ipairs(entries) do if entry.itemId == self.FixedItemIds[index] then filtered[#filtered + 1] = entry end end; entries = filtered -- 中文维护：固定药品选择器只列对应物品，不能误绑其它药。
    if self.selector then self.selector:Show(false) end -- 中文维护：仅隐藏本插件旧选择器。
    self.selector = self:Widget("window", self.panel, 16, 70, 700, 490) -- 中文维护：独立窗口具有明确标题与返回入口。
    self:Background(self.selector, 0.07, 0.10, 0.14, 1) -- 中文维护：不透明列表避免游戏背景降低可读性。
    self:Text(self.selector, 16, 12, 668, 28, "为 " .. self.Specs[index].name .. " 选择背包药品", 17) -- 中文维护：避免不知道当前给哪瓶药做配置。
    local buttons, page, pageLabel = {}, 1 -- 中文维护：固定10个可复用行，支持整个背包而不创建几百个Native控件。
    pageLabel = self:Text(self.selector, 16, 408, 280, 30, "", 14) -- 中文维护：显示翻页位置，长列表可到达末尾。
    local function Refresh() -- 中文维护：分页仅改现有行的文本与可见性。
        for row, button in ipairs(buttons) do -- 中文维护：每个按钮在点击时根据当前页解析条目。
            local entry = entries[(page - 1) * 10 + row] -- 中文维护：超出列表长度的行必须隐藏，不能留下上一页旧药。
            button:Show(entry ~= nil) -- 中文维护：空背包没有可点的旧项。
            if entry then button:SetText(entry.name .. "  ×" .. tostring(entry.stock) .. "  [背包格" .. entry.slot .. "]") end -- 中文维护：同名药仍显示实际位置与数量供人工核对。
        end -- 中文维护：无Native物品操作。
        pageLabel:SetText("第" .. page .. "/" .. math.max(1, math.ceil(#entries / 10)) .. "页 · " .. #entries .. "个物品") -- 中文维护：空列表仍显示第1/1页。
    end -- 中文维护：分页状态只属于本选择器。
    for row = 1, 10 do -- 中文维护：行高35px，按钮完整可见。
        local r = row -- 中文维护：捕获各行，禁止Lua5.1闭包混淆。
        buttons[r] = self:Button(self.selector, 16, 48 + (r - 1) * 35, 668, "", function() -- 中文维护：点击选择，不自动使用药品。
            local entry = entries[(page - 1) * 10 + r] -- 中文维护：消费当前页，不能缓存失效的数组位置。
            if entry then self:SelectItem(index, entry); self.selector:Show(false) end -- 中文维护：重读身份在SelectItem内完成。
        end) -- 中文维护：按钮闭包受Guard保护。
    end -- 中文维护：只构造10行。
    self:Button(self.selector, 294, 408, 122, "上一页", function() page = math.max(1, page - 1); Refresh() end) -- 中文维护：有界分页。
    self:Button(self.selector, 424, 408, 122, "下一页", function() page = math.min(math.max(1, math.ceil(#entries / 10)), page + 1); Refresh() end) -- 中文维护：不能越界复用旧药品。
    self:Button(self.selector, 554, 408, 130, "取消选择", function() self.selector:Show(false) end) -- 中文维护：取消不修改配置。
    self:Text(self.selector, 16, 445, 668, 30, "只列当前对应药品；按固定ID自动定位，背包排序不会清掉冷却记录。", 14) -- 中文维护：第一版明确固定背包位置契约，禁止猜移动后的物品身份。
    Refresh() -- 中文维护：首次打开必须安排真实列表，而不是空壳。
end -- 中文维护：全量读取结束后不会启动自动背包操作。
