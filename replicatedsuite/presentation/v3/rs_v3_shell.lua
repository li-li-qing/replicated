------------------------------------------------------------------------
-- Replicated Suite V3 - Application Shell
--
-- The V3 shell is the only active application window. It owns chrome,
-- navigation, PageHost/ModalHost and responsive geometry only. All top-level
-- movement/resizing is delegated to the shared RSUI Windowing foundation.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local UI, RSUI, Adapter = S.UI, S.RSUI, S.UIV3NativeAdapter
local Router = S.UIV3 and S.UIV3.Router or nil
local PageHost = S.UIV3 and S.UIV3.PageHost or nil
local ModalHost = S.UIV3 and S.UIV3.ModalHost or nil
local ToastHost = S.UIV3 and S.UIV3.ToastHost or nil
local Windowing = RSUI and RSUI.Windowing or nil
if type(UI) ~= "table" or type(RSUI) ~= "table" or type(Adapter) ~= "table"
    or type(Router) ~= "table" or type(PageHost) ~= "table" or type(Windowing) ~= "table"
    or type(ModalHost) ~= "table" or type(ToastHost) ~= "table" then return end

S.UIV3 = S.UIV3 or {}
local V3 = S.UIV3
V3.Shell = V3.Shell or {
    owner = "v3:shell",
    logicalId = "v3_shell_root",
    created = false,
    window = nil,
    root = nil,
    background = nil,
    appStack = nil,
    topBar = nil,
    body = nil,
    navFrame = nil,
    navColumn = nil,
    navScroll = nil,
    navStack = nil,
    navPager = nil,
    systemFrame = nil,
    contentFrame = nil,
    contentRoot = nil,
    footer = nil,
    status = nil,
    menuTip = nil,
    menuTipIndex = 0,
    topmost = false,
    topmostButton = nil,
    minimizeButton = nil,
    reloadButton = nil,
    navButtons = {},
    navFeatureIds = {},
    lastRect = nil,
    lastRoute = nil,
    windowController = nil,
    failedBuildGeneration = nil,
    failedBuildError = nil,
    buildQuarantinedRejects = 0,
}
local Shell = V3.Shell
Shell.navigationCallbackContractVersion = 1
Shell.NavigationCallbackCaptureContractVersion = 1
Shell.StateMutationTransactionContractVersion = 1
Shell.TopmostLayerContractVersion = 1
Shell.CommittedGeometryPersistenceContractVersion = 1
Shell.DevelopmentNavigationPresentationContractVersion = 1 -- 中文维护注释：Shell v1 开始只用 navigationTitle 展示“未完成”后缀，页面 title/route/Feature identity 均保持原语义。

local SCROLL_CATEGORY_ORDER = { "home", "combat", "life", "tools" }
local SYSTEM_ROUTES = { "system.workspace", "system.widgets", "system.features", "system.settings", "system.diagnostics" }
-- 中文维护：提示仅是主菜单展示内容，按成功的隐藏→显示边沿循环；不读取 Feature 状态，也不写入配置。
local MENU_TIPS = {
    "“债券功能”需要在西、东大陆任意一个区域，方可获取到本地区的所有的债券信息",
    "装备升级或者翻新之后，记得在“换装”中重新保存应用喔",
    "血条太大挡视野？团战人数太多看不到标记？不妨点开“头顶标记/血条”看看呢",
    "想给朋友取别称吗？状态显示中可对目标添加自定义名称",
    "经常被圣所盾聚到？看看范围辅助呢",
    "整理背包怕放错物品，可以添加黑名单",
    "死于不明吗？打开死亡回顾看看吧",
}

local function SetButtonSelected(button, selected)
    if button ~= nil and type(button.SetSelected) == "function" then button:SetSelected(selected == true) end
end

local function MarkDirty(reason)
    if type(V3.MarkShellStoreDirty) == "function" then V3:MarkShellStoreDirty(350, reason or "shell_changed") end
end

-- 维护（viewport-recovery-1）：读取主窗配置只过滤运行值；不改 v3.shell schema/历史指纹。
local function Finite(value,fallback)
    local n=tonumber(value)
    if n==nil or n~=n or n==math.huge or n==-math.huge then return fallback end
    return n
end

function Shell:ResolveRect(designWidth, designHeight)
    local context = S.Layout:GetContext()
    local scale = math.max(0.01, tonumber(context.addonScale) or 1)
    local state = V3.ShellState or {}
    local size = V3.ShellSizePolicy or { defaultWidth = 1040, defaultHeight = 700, minWidth = 1, minHeight = 1 }
    local dw = math.max(size.minWidth, Finite(designWidth) or Finite(state.width) or size.defaultWidth)
    local normalDh = math.max(size.minHeight, Finite(designHeight) or Finite(state.height) or size.defaultHeight)
    local width = dw * scale
    local height = normalDh * scale
    -- 维护：主窗保留自己的隐藏式最小化/导航/Modal 生命周期，只共享 placement 求解。
    -- 消费运行时 fit 的宽高；原设计尺寸 dw/normalDh 不写回，回大屏时仍从原 Store 恢复。
    local fittedW,fittedH = math.min(width,context.usableWidth),math.min(height,context.usableHeight)
    local centerX = (context.logicalWidth-fittedW)*0.5
    local centerY = (context.logicalHeight-fittedH)*0.5
    local x,y
    x,y,width,height,self.placementInfo = S.Layout:ResolvePlacement(state.userMoved and state or nil,width,height,centerX,centerY,
        {mode="free",topLevel=true,topReachHeight=50,reason=self.placementReason})
    return x, y, width, height, dw, normalDh
end

function Shell:SetStatus(text, tone)
    if self.status ~= nil then
        self.status:SetText(tostring(text or ""))
        if tone ~= nil and type(self.status.SetTone) == "function" then self.status:SetTone(tone) end
    end
end

function Shell:AdvanceMenuTip()
    if self.menuTip == nil then return false end
    local nextIndex = ((tonumber(self.menuTipIndex) or 0) % #MENU_TIPS) + 1
    -- 中文维护：先写当前可见文本，再推进索引；失败时下次打开仍显示这一条，不让轮换越过未展示内容。
    if self.menuTip:SetText("小提示：" .. MENU_TIPS[nextIndex]) ~= true then return false end
    self.menuTipIndex = nextIndex
    if type(RSUI.FlushLayoutQueue) == "function" then RSUI:FlushLayoutQueue(16) end
    return true
end

function Shell:RefreshNavScrollHint()
    if self.navScroll == nil or self.navScrollHint == nil then return false end
    local entries = self.navScroll:GetScrollableEntries()
    local total = #entries
    local first = math.max(1, tonumber(self.navScroll.visibleStart) or 1)
    local last = math.max(0, tonumber(self.navScroll.visibleEnd) or 0)
    if total == 0 then first, last = 0, 0 end
    self.navScrollHint:SetText(tostring(first) .. "-" .. tostring(last) .. " / " .. tostring(total))
    if self.navUp ~= nil then self.navUp:SetEnabled(self.navScroll.canScrollBackward == true) end
    if self.navDown ~= nil then self.navDown:SetEnabled(self.navScroll.canScrollForward == true) end
    return true
end

-- 维护（module-controls-diag-2）：红绿仅表示FeatureRuntime真实启停，选中态仍由路由决定。
-- 构建时缓存路由->Feature映射；生命周期事件/导航/按钮事务后刷新，禁止轮询GetHealth。
function Shell:RefreshFeatureStates(featureId)
    local controls = V3.ModuleControlsV3
    if not controls then return true end
    for route, id in pairs(self.navFeatureIds or {}) do
        if featureId == nil or featureId == id then
            local button = self.navButtons[route]
            if button and type(button.SetStatusTone) == "function" then
                button:SetStatusTone(controls:ReadState(id).enabled == true and "green" or "red")
            end
        end
    end
    -- 启停事件同时刷新“已开启”筛选及顶栏计数；不新增周期性扫描。
    self:RefreshNavigation(false)
    self:RefreshRunningSummary()
    return true
end

-- 个人工作台：按钮只创建一次。重排使用 RSUI 同父顺序 API，隐藏仅改变导航可见性，
-- 不启停模块。全部模式忽略用户隐藏，Registry.navigationVisible=false 仍不可复活。
function Shell:BuildScrollableNavigation()
    if not self.navScroll then return false end
    for _, categoryId in ipairs(SCROLL_CATEGORY_ORDER) do
        for _, route in ipairs(Router:List(categoryId)) do
            local routeRef = route
            local button = RSUI:Button({ id="v3_nav_"..routeRef.id:gsub("[^%w]","_"), parent=self.navScroll,
                text=tostring(routeRef.navigationTitle or routeRef.title), compact=true,
                onClick=function()return self:Navigate(routeRef.id,{source="navigation"})end,
                slot={size="fixed",height=28,hAlign="fill"} })
            self.navButtons[routeRef.id]=button
            local meta=S.FeatureRegistry:GetByRoute(routeRef.id)
            self.navFeatureIds[routeRef.id]=V3.ModuleControlsV3 and V3.ModuleControlsV3:ControlId(meta) or nil
        end
    end
    self:RefreshNavigation(true)
    self:RefreshFeatureStates()
    return true
end

function Shell:RefreshNavigation(reset)
    local preferences=V3.Workspace
    if not preferences or not self.navScroll then return true end
    local rows=preferences:GetNavigation(self.navMode or "custom",self.navQuery or "")
    local wanted,ordered={},{}
    for _,route in ipairs(rows)do
        local button=self.navButtons[route.id]
        if button then
            wanted[route.id]=true;ordered[#ordered+1]=button
            local pref=preferences:GetNavPreference(route.id)
            local id=self.navFeatureIds[route.id]
            local state=id and preferences:ReadControl(id) or nil
            local label=(state and (state.enabled and "[开] " or "[关] ") or "")
                ..(pref.favorite and "常用 · " or "")..tostring(route.navigationTitle or route.title)
            button:SetText(label)
        end
    end
    for id,button in pairs(self.navButtons)do
        if button.parentComponent==self.navScroll then button:SetVisible(wanted[id]==true)end
    end
    local ok,err=self.navScroll:ReorderChildren(ordered)
    if not ok then return false,err end
    if reset then self.navScroll:ScrollToTop()end
    self.navScroll:InvalidateMeasure("navigation_preferences")
    self:RefreshNavScrollHint()
    return true
end

function Shell:RefreshRunningSummary()
    if not self.runningButton or not V3.Workspace then return true end
    local state=V3.Workspace:GetRunningSummary()
    self.runningButton:SetText("已开启 "..state.enabled.." · 异常 "..state.faulted)
    if type(self.runningButton.SetStatusTone)=="function"then self.runningButton:SetStatusTone(state.faulted>0 and "red" or state.enabled>0 and "green" or nil)end
    return true
end

function Shell:BuildSystemNavigation()
    if self.systemFrame == nil then return false end
    local stack = RSUI:VerticalBox({ id = "v3_nav_system_stack", parent = self.systemFrame, gap = 3 })
    RSUI:Text({ id = "v3_nav_system_title", parent = stack, text = "系统", fontSize = 10, tone = "muted", overflow = "ellipsis", slot = { size = "fixed", height = 20, hAlign = "fill" } })
    for _, routeId in ipairs(SYSTEM_ROUTES) do
        local route = Router:Get(routeId)
        if route ~= nil then
            local routeRef = route
            local button = RSUI:Button({
                id = "v3_nav_" .. routeRef.id:gsub("[^%w]", "_"), parent = stack, text = tostring(routeRef.navigationTitle or routeRef.title), compact = true, -- 中文维护注释：系统导航同样消费专用 navigationTitle；当前系统项均为完成态，因此视觉文本保持原样。
                onClick = function() return self:Navigate(routeRef.id, { source = "system_navigation" }) end,
                slot = { size = "fixed", height = 27, hAlign = "fill" },
            })
            self.navButtons[routeRef.id] = button
        end
    end
    self.reloadButton = RSUI:Button({
        id = "v3_nav_reload", parent = stack, text = "重新加载文件", compact = true,
        onClick = function()
            if type(S.ReloadCodeFromDisk) ~= "function" then return false end
            return S.ReloadCodeFromDisk("v3_navigation")
        end,
        slot = { size = "fixed", height = 27, hAlign = "fill" },
    })
    return true
end

local function EnsureComponentVisibility(component, visibility, label)
    if component == nil then return true, nil end
    if type(component.SetVisibility) ~= "function" then return false, tostring(label or "component") .. "_visibility_contract_missing" end
    local _, accepted, detail = component:SetVisibility(visibility)
    if accepted ~= true then return false, detail or (tostring(label or "component") .. "_visibility_rejected") end
    return true, nil
end

function Shell:ApplyMinimizedState(persist)
    local state = V3.ShellState or {}
    local minimized = state.minimized == true
    -- The main application minimizes back to the persistent R launcher. It no
    -- longer compresses into a title-only strip, which was visually ambiguous
    -- and consumed screen space without providing useful content. Every Native
    -- or Component state transition must be accepted before this projection is
    -- considered applied; callers own the ShellState transaction itself.
    local bodyOk, bodyErr = EnsureComponentVisibility(self.body, "visible", "shell_body")
    if bodyOk ~= true then return false, bodyErr end
    local footerOk, footerErr = EnsureComponentVisibility(self.footer, "visible", "shell_footer")
    if footerOk ~= true then return false, footerErr end
    if self.minimizeButton ~= nil then self.minimizeButton:SetText("—") end
    if self.windowController ~= nil then
        local lockOk, _, lockDetail = self.windowController:SetLocked(state.locked == true)
        if lockOk ~= true then return false, lockDetail or "主窗口锁定状态应用失败" end
        local resizeOk, _, _, resizeDetail = self.windowController:SetResizeEnabled(true)
        if resizeOk ~= true then return false, resizeDetail or "主窗口缩放状态应用失败" end
    end
    if minimized then
        if RSUI.DropdownService ~= nil and type(RSUI.DropdownService.CloseAll) == "function" then
            RSUI.DropdownService:CloseAll()
        end
        if self.window ~= nil then
            local hidden, hideErr = Adapter:SetVisible(self.window, self.owner, false)
            if hidden ~= true then return false, hideErr or "主窗口最小化隐藏失败" end
        end
    end
    if persist ~= false then MarkDirty("minimized_changed") end
    return true, minimized
end

function Shell:ToggleMinimized()
    local state = V3.ShellState or {}
    local previous = state.minimized == true
    if previous then return true end
    state.minimized = true
    local applied, applyErr = self:ApplyMinimizedState(false)
    if applied ~= true then
        state.minimized = previous
        self:ApplyMinimizedState(false)
        return false, applyErr or "主窗口最小化状态应用失败"
    end
    local closed, closeErr = self:Close("minimized_to_launcher")
    if closed ~= true then
        state.minimized = previous
        self:ApplyMinimizedState(false)
        if previous ~= true and self.window ~= nil then Adapter:SetVisible(self.window, self.owner, true) end
        return false, closeErr or "主窗口最小化关闭失败"
    end
    MarkDirty("minimized_changed")
    return true
end

function Shell:SetLocked(locked, persist)
    local state = V3.ShellState or {}
    local nextValue = locked == true
    if state.locked == nextValue then return true, false end
    if self.windowController ~= nil then
        local accepted, _, detail = self.windowController:SetLocked(nextValue)
        if accepted ~= true then return false, detail or "主窗口锁定状态应用失败" end
    end
    state.locked = nextValue
    if persist ~= false then MarkDirty("window_locked") end
    return true, true
end

function Shell:IsLocked()
    return (V3.ShellState or {}).locked == true
end

function Shell:CommitWindowGeometry(_, x, y, width, height, reason)
    local state = V3.ShellState or {}
    local previous = {}
    for key, value in pairs(state) do previous[key] = value end
    local context = S.Layout:GetContext()
    local scale = math.max(0.01, tonumber(context.addonScale) or 1)
    if state.minimized ~= true and tostring(reason or "") == "resize" then
        local size = V3.ShellSizePolicy or { minWidth = 1, minHeight = 1 }
        state.width = math.max(size.minWidth, width / scale)
        state.height = math.max(size.minHeight, height / scale)
    end
    -- 维护（2026-09-16，main-shell-committed-geometry-1）：Windowing 已把最终逻辑矩形
    -- 作为参数交给这里；禁止再次从 Native 读回坐标。主菜单与悬浮窗使用同一 Layout Authority，
    -- 保持原 free-v2 / normalized-center 持久化格式，旧配置无需迁移。
    if S.Layout ~= nil and type(S.Layout.StorePlacementRect) == "function" then
        S.Layout:StorePlacementRect(state, x, y, width, height, { mode = "free" })
    elseif S.Layout ~= nil and type(S.Layout.StorePlacement) == "function" then
        S.Layout:StorePlacement(state, self.window, { mode = "free" })
    end
    state.userMoved = true
    local layoutOk, layoutErr = self:ApplyLayout(false)
    if layoutOk ~= true then
        for key in pairs(state) do state[key] = nil end
        for key, value in pairs(previous) do state[key] = value end
        pcall(function() self:ApplyLayout(false) end)
        return false, layoutErr or "主窗口几何提交失败"
    end
    -- Geometry is a low-frequency commit edge. Mark due immediately so a user
    -- who drags the window and exits the client right away does not lose the final rect.
    if type(V3.MarkShellStoreDirty) == "function" then V3:MarkShellStoreDirty(0, "window_" .. tostring(reason or "geometry")) end
    return true
end

function Shell:SetTopmost(value, persist)
    local nextValue = value == true
    local previous = self.topmost == true
    if previous == nextValue then SetButtonSelected(self.topmostButton, nextValue); return true, nextValue, false end
    if self.window == nil or type(Adapter.SetRootLayer) ~= "function" then return false, "主窗口层级能力不可用" end
    local layerOk, layerErr = Adapter:SetRootLayer(self.window, nextValue)
    if layerOk ~= true then return false, layerErr or "主窗口层级切换失败" end
    self.topmost = nextValue
    SetButtonSelected(self.topmostButton, nextValue)
    if persist ~= false then
        local prefs = RSUI.WindowPreferences
        if type(prefs) ~= "table" or type(prefs.SetTopmost) ~= "function" then
            Adapter:SetRootLayer(self.window, previous); self.topmost = previous; SetButtonSelected(self.topmostButton, previous)
            return false, "窗口层级偏好存档不可用"
        end
        local ok, accepted, detail = pcall(function() return prefs:SetTopmost("main_shell", nextValue, true) end)
        if ok ~= true or accepted ~= true then
            Adapter:SetRootLayer(self.window, previous); self.topmost = previous; SetButtonSelected(self.topmostButton, previous)
            return false, tostring(detail or accepted or "主窗口置顶保存失败")
        end
    end
    if nextValue and type(Adapter.Raise) == "function" then Adapter:Raise(self.window) end
    return true, nextValue, true
end

function Shell:GetTopmost() return self.topmost == true end

-- 主菜单复用悬浮窗的 Windowing alpha 和 RSUI 局部外观通道。提交失败恢复已保存值，
-- 不修改旧 ShellState，也不扫描其它顶层窗口；新建页面/虚拟行由 AddChild 继承这些通道。
function Shell:ApplyAppearanceSettings(settings)
    if not self.created or not self.root or not self.window then return false,"主窗口尚未创建"end
    local previous=self.mainAppearance or {}
    if previous.overallOpacity~=settings.overallOpacity then
        local ok,err
        if self.windowController and type(self.windowController.SetOpacity)=="function"then
            local value,changed;ok,value,changed,err=self.windowController:SetOpacity(settings.overallOpacity)
        elseif type(UI.EnsureAlpha)=="function"then
            local _;ok,_,err=UI:EnsureAlpha(self.window,settings.overallOpacity,self.owner)
        else return false,"主窗口透明度能力不可用"end
        if ok~=true then return false,err or "主窗口透明度应用失败"end
    end
    if previous.backgroundOpacity~=settings.backgroundOpacity or previous.textOpacity~=settings.textOpacity then
        if RSUI:ApplyOpacityChannels(self.root,settings.backgroundOpacity,settings.textOpacity)~=true then return false,"主窗口背景或文字透明度应用失败"end
    end
    if previous.fontScale~=settings.fontScale then
        if RSUI:ApplyFontScale(self.root,settings.fontScale)~=true then return false,"主窗口字号应用失败"end
    end
    self.mainAppearance={overallOpacity=settings.overallOpacity,backgroundOpacity=settings.backgroundOpacity,textOpacity=settings.textOpacity,fontScale=settings.fontScale}
    if previous.fontScale~=settings.fontScale then
        local ok,err=self:ApplyLayout(false);if ok~=true then return false,err end
    end
    return true
end
function Shell:SetAppearance(patch,persist)
    local appearance=V3.MainAppearance
    if not appearance then return false,"主菜单外观设置不可用"end
    local loaded,err=appearance:EnsureLoaded();if loaded~=true then return false,err end
    local previous=appearance:GetSettings()
    local candidate;candidate,err=appearance:Candidate(patch);if not candidate then return false,err end
    local ok;ok,err=self:ApplyAppearanceSettings(candidate)
    if ok==true and persist~=false then ok,err=appearance:Save(candidate)end
    if ok~=true then
        -- 失败可能发生在任一通道；清理镜像后完整撤回，不能用“值相同”短路漏掉部分 Native 写入。
        self.mainAppearance=nil
        local restored,restoreErr=self:ApplyAppearanceSettings(previous)
        if restored~=true then return false,tostring(err).."；外观恢复失败："..tostring(restoreErr)end
    end
    return ok,err
end
function Shell:RestoreAppearancePreview()
    if not V3.MainAppearance or not self.created then return true end
    return self:ApplyAppearanceSettings(V3.MainAppearance:GetSettings())
end
function Shell:ResetAppearance()return self:SetAppearance({overallOpacity=1,backgroundOpacity=1,textOpacity=1,fontScale=1},true)end

function Shell:Create()
    if self.created ~= true then S.Layout:GetContext(true) end -- 维护：首次创建不用启动早期的 provisional context。
    if self.created == true and self.window ~= nil then return true end
    if tonumber(self.failedBuildGeneration) == tonumber(S.Generation) then
        self.buildQuarantinedRejects = (tonumber(self.buildQuarantinedRejects) or 0) + 1
        return false, tostring(self.failedBuildError or "主窗口构建已隔离")
    end
    local loaded, loadErr = true, nil
    if type(V3.EnsureShellStoreLoaded) == "function" then loaded, loadErr = V3:EnsureShellStoreLoaded() end
    if loaded ~= true then return false, loadErr or "主窗口配置读取失败" end

    -- 读取 UI 偏好失败不阻断诊断/恢复入口；写操作仍被新 Store 拒绝。
    if V3.Workspace then
        V3.Workspace:EnsureLoaded()
        if S.Theme and type(S.Theme.ApplyWorkspacePalette)=="function" then S.Theme:ApplyWorkspacePalette(V3.Workspace:GetSettings().appearance) end
    end
    local scope = type(RSUI.BeginBuildScope) == "function" and RSUI:BeginBuildScope("main_shell") or nil
    local function FailBuild(err)
        if scope ~= nil and type(RSUI.EndBuildScope) == "function" then RSUI:EndBuildScope(scope, false); scope = nil end
        self.created = false
        self.failedBuildGeneration = S.Generation
        self.failedBuildError = tostring(err or "主窗口构建失败")
        if S.DiagnosticsManager ~= nil and type(S.DiagnosticsManager.Error) == "function" then
            S.DiagnosticsManager:Error("ui_v3", "V3_SHELL_BUILD_QUARANTINED", "V3 主窗口构建失败，本次 Generation 已隔离重试", {
                generation = tostring(S.Generation or ""), error = self.failedBuildError,
            })
        end
        return false, self.failedBuildError
    end

    -- 维护（2026-09-16，main-shell-topmost-1）：主窗口默认 normal，只有用户显式保存 [顶]
    -- 才请求 system。偏好由 RSUI.WindowPreferences 独立持久化，避免修改 v3.shell schema。
    local prefs = RSUI.WindowPreferences
    self.topmost = type(prefs) == "table" and type(prefs.GetTopmost) == "function" and prefs:GetTopmost("main_shell") == true or false
    local window, createErr = Adapter:CreateRootWindow(self.logicalId, self.owner, self.topmost and "system" or "normal")
    if window == nil then return FailBuild(createErr) end
    self.window = window
    self.window.rsUiTopmost = self.topmost == true
    -- DrawPriority orders Replicated Suite roots only inside the selected Native layer.
    local shellPriority = (S.UITokens and type(S.UITokens.Number) == "function"
        and S.UITokens:Number("layer.shellPriority", 100)) or 100
    if type(window.SetDrawPriority) == "function" then pcall(function() window:SetDrawPriority(shellPriority) end) end
    window.rsUiLayerRole = "shell"
    window.rsUiLayerPriority = shellPriority

    local root, rootErr = RSUI:Overlay({ id = "v3_shell_overlay", parent = window, width = 1, height = 1 })
    self.root = root
    if self.root == nil then return FailBuild("主窗口组件创建失败：" .. tostring(rootErr or "未知错误")) end

    self.background = RSUI:Border({
        id = "v3_shell_background", parent = self.root, variant = "card", gradient = false,
        padding = 0, slot = { hAlign = "fill", vAlign = "fill" },
    })
    self.appStack = RSUI:VerticalBox({ id = "v3_shell_app_stack", parent = self.background, gap = 0, slot = { hAlign = "fill", vAlign = "fill" } })

    self.topBar = RSUI:Border({
        id = "v3_shell_top_bar", parent = self.appStack, variant = "header", padding = 6, pickable = true,
        slot = { size = "fixed", height = 50, hAlign = "fill" },
    })
    local topRow = RSUI:HorizontalBox({ id = "v3_shell_top_row", parent = self.topBar, gap = 4 })
    local brand = RSUI:VerticalBox({ id = "v3_shell_brand", parent = topRow, gap = 1, slot = { size = "fill", fill = 1 } })
    -- 维护：发行标记紧跟 QQ 群；第二行只是联系文案，不添加邮件发送或业务写入口。
    -- Authority / 数据流：仍由 v3:shell 经 RSUI:Text 创建展示文本，不直接写 Native 或业务 Store。
    -- 兼容边界：保留逻辑 ID、响应式宽度及样式；不改 ESC 注册名、聊天前缀或用户配置，无迁移。
    -- 后续维护：联系信息仅在此展示；窄窗沿用省略规则，不扩大拖动命中区或挤占右侧按钮。
    self.brandTitle=RSUI:Text({ id = "v3_shell_title", parent = brand, text = "作者:Replicated   QQ群:1104129461   正式版5.0", fontSize = 15, tone = "accent", overflow = "ellipsis", slot = { size = "fixed", height = 20 } })
    self.supportText=RSUI:Text({ id = "v3_shell_support_text", parent = brand, text = "如果觉得功能好用，可以邮件给作者提供一点打赏", fontSize = 9, tone = "muted", overflow = "ellipsis", slot = { size = "fixed", height = 14 } })
    -- 中文维护：窄窗可省略顶栏文字，悬停时仍能读到完整文案；不改变右侧按钮的命中区域。
    if RSUI.Tooltip and type(RSUI.Tooltip.BindOverflowText) == "function" then RSUI.Tooltip:BindOverflowText(self.brandTitle,self.brandTitle,{cursorFollow=true,maxWidth=440}); RSUI.Tooltip:BindOverflowText(self.supportText,self.supportText,{cursorFollow=true,maxWidth=440}) end
    self.runningButton=RSUI:Button({id="v3_shell_running",parent=topRow,text="已开启 0 · 异常 0",compact=true,
        onClick=function()return self:Navigate("system.features",{source="running_summary"})end,slot={size="fixed",width=138}})
    -- 中文维护（2026-10-05）：外观快捷入口移到 Shell 标题栏，从任意模块复用工作台原页面与保存路径。
    -- 窄窗只允许此按钮在 50..78 内收缩，既有诊断/置顶/关闭尺寸和标题省略规则保持不变；不扩大拖动命中区。
    RSUI:Button({id="v3_shell_appearance_button",parent=topRow,text="界面外观",compact=true,
        slot={size="auto",minWidth=50,maxWidth=78},onClick=function()
            if not V3.WorkspacePage then return false,"外观设置页面不可用" end
            V3.WorkspacePage.requestedTab="appearance"
            return self:Navigate("system.workspace",{source="topbar"})
        end})
    RSUI:Button({ id = "v3_shell_diag_button", parent = topRow, text = "诊断", compact = true,
        onClick = function() return self:Navigate("system.diagnostics", { source = "topbar" }) end,
        slot = { size = "fixed", width = 64 } })
    self.topmostButton = RSUI:Button({ id = "v3_shell_topmost_button", parent = topRow, text = "顶", compact = true,
        onClick = function() return self:SetTopmost(not self.topmost, true) end,
        slot = { size = "fixed", width = 36 } })
    SetButtonSelected(self.topmostButton, self.topmost == true)
    self.minimizeButton = RSUI:Button({ id = "v3_shell_minimize_button", parent = topRow, text = "—", compact = true,
        onClick = function() return self:ToggleMinimized() end,
        slot = { size = "fixed", width = 36 } })
    RSUI:Button({ id = "v3_shell_close_button", parent = topRow, text = "×", compact = true,
        onClick = function() return self:Close("close_button") end,
        slot = { size = "fixed", width = 36 } })

    self.body = RSUI:HorizontalBox({ id = "v3_shell_body", parent = self.appStack, gap = 0, slot = { size = "fill", fill = 1, hAlign = "fill", vAlign = "fill" } })

    self.navFrame = RSUI:Border({ id = "v3_shell_nav_frame", parent = self.body, variant = "soft", padding = 7, slot = { size = "fixed", width = 204, hAlign = "fill", vAlign = "fill" } })
    self.navColumn = RSUI:VerticalBox({ id = "v3_shell_nav_column", parent = self.navFrame, gap = 5, slot = { hAlign = "fill", vAlign = "fill" } })
    local navTools=RSUI:HorizontalBox({id="v3_nav_tools",parent=self.navColumn,gap=4,slot={size="fixed",height=28,hAlign="fill"}})
    RSUI:Dropdown({id="v3_nav_mode",parent=navTools,items={{value="custom",text="我的导航"},{value="all",text="显示全部"},{value="favorites",text="常用功能"},{value="enabled",text="已开启"}},
        get=function()return self.navMode or "custom"end,set=function(value)self.navMode=value;return self:RefreshNavigation(true)end,slot={size="fill",fill=1}})
    RSUI:Button({id="v3_nav_customize",parent=navTools,text="自定义",compact=true,slot={size="fixed",width=58},
        onClick=function()V3.WorkspacePage.requestedTab="navigation";return self:Navigate("system.workspace",{source="nav_customize"})end})
    -- 搜索仅提交后更新当前导航投影，输入草稿期间不重排按钮/抢焦点。
    local searchRow=RSUI:HorizontalBox({id="v3_nav_search_row",parent=self.navColumn,gap=4,slot={size="fixed",height=27,hAlign="fill"}})
    local search=RSUI:TextInput({id="v3_nav_search_text",parent=searchRow,placeholder="搜索功能",maxLength=64,allowEmpty=true,submitOnLostFocus=false,
        get=function()return self.navQuery or ""end,set=function(value)self.navQuery=tostring(value or "");return true end,
        onSubmit=function()return self:RefreshNavigation(true)end,slot={size="fill",fill=1,minWidth=64}})
    RSUI:Button({id="v3_nav_search_apply",parent=searchRow,text="查",compact=true,slot={size="fixed",width=28},onClick=function()return search:CommitAndEndEditing("navigation_search")end})
    RSUI:Button({id="v3_nav_search_clear",parent=searchRow,text="清",compact=true,slot={size="fixed",width=28},onClick=function()
        search:CancelEditing("navigation_clear");self.navQuery="";search:SetValue("",false);return self:RefreshNavigation(true)end})
    self.navScroll = RSUI:ScrollBox({ id = "v3_shell_nav_scroll", parent = self.navColumn, scrollStep = 2, gap = 3, slot = { size = "fill", fill = 1, hAlign = "fill", vAlign = "fill" } })
    self.navStack = nil
    self:BuildScrollableNavigation()

    self.navPager = RSUI:HorizontalBox({ id = "v3_shell_nav_pager", parent = self.navColumn, gap = 4, slot = { size = "fixed", height = 27, hAlign = "fill" } })
    self.navUp = RSUI:Button({ id = "v3_shell_nav_up", parent = self.navPager, text = "上", compact = true, slot = { size = "fixed", width = 38 }, onClick = function() local changed = self.navScroll:ScrollBy(-2); self:RefreshNavScrollHint(); return changed end })
    self.navScrollHint = RSUI:Text({ id = "v3_shell_nav_hint", parent = self.navPager, text = "滚动", fontSize = 9, tone = "muted", overflow = "ellipsis", align = ALIGN_CENTER, slot = { size = "fill", fill = 1 } })
    self.navDown = RSUI:Button({ id = "v3_shell_nav_down", parent = self.navPager, text = "下", compact = true, slot = { size = "fixed", width = 38 }, onClick = function() local changed = self.navScroll:ScrollBy(2); self:RefreshNavScrollHint(); return changed end })
    local rawScrollBy = self.navScroll.ScrollBy
    self.navScroll.ScrollBy = function(scroll, delta)
        local changed = rawScrollBy(scroll, delta)
        self:RefreshNavScrollHint()
        return changed
    end

    self.systemFrame = RSUI:Border({ id = "v3_shell_system_frame", parent = self.navColumn, variant = "card", padding = 5, slot = { size = "fixed", height = 214, hAlign = "fill" } })
    self:BuildSystemNavigation()
    -- 单个代内订阅；后续热重载由旧 Events/Runtime teardown 释放，不增加周期任务。
    if S.Events and V3.Workspace then
        S.Events:SubscribeInternal("v3.workspace.updated",self,function(_,kind)
            if kind=="navigation" then self:RefreshNavigation(true) end
            if kind=="appearance" and S.Theme and type(S.Theme.ApplyWorkspacePalette)=="function"then S.Theme:ApplyWorkspacePalette(V3.Workspace:GetSettings().appearance)end
            self:RefreshRunningSummary()
        end)
    end
    self:RefreshRunningSummary()

    self.contentFrame = RSUI:Border({ id = "v3_shell_content_frame", parent = self.body, variant = "card", padding = 14, slot = { size = "fill", fill = 1, hAlign = "fill", vAlign = "fill" } })
    self.contentRoot = RSUI:Overlay({ id = "v3_shell_content_root", parent = self.contentFrame })
    if PageHost:Attach(self.contentRoot) ~= true then return FailBuild("页面宿主挂载失败") end

    -- 中文维护：底栏增加两行提示空间；状态保留左侧，提示占右侧剩余宽度，缩窗时由 Text 有界换行。
    self.footer = RSUI:Border({ id = "v3_shell_footer", parent = self.appStack, variant = "soft", padding = 6, slot = { size = "fixed", height = 44, hAlign = "fill" } })
    local footerRow = RSUI:HorizontalBox({ id = "v3_shell_footer_row", parent = self.footer, gap = 8 })
    self.status = RSUI:Text({ id = "v3_shell_status", parent = footerRow, text = "就绪", fontSize = 9, tone = "muted", overflow = "ellipsis", slot = { size = "fixed", width = 150 } })
    self.menuTip = RSUI:Text({ id = "v3_shell_menu_tip", parent = footerRow, text = "小提示：", fontSize = 9, tone = "muted", overflow = "wrap", maxLines = 2, slot = { size = "fill", fill = 1, hAlign = "fill" } })
    -- 中文维护：两行仍截断时才显示悬停全文，不把提示铺到页面内容或覆盖窗口操作区。
    if RSUI.Tooltip and type(RSUI.Tooltip.BindOverflowText) == "function" then RSUI.Tooltip:BindOverflowText(self.menuTip,self.menuTip,{cursorFollow=true,maxWidth=440}) end

    -- Toast is above normal page chrome but below the modal scrim. This keeps
    -- notifications visible without allowing them to bypass a blocking modal.
    local toastLayer = RSUI:Overlay({ id = "v3_shell_toast_layer", parent = self.root, slot = { hAlign = "fill", vAlign = "fill" } })
    local toastOk, toastErr = ToastHost:Attach(toastLayer)
    if toastOk ~= true then return FailBuild("通知宿主挂载失败：" .. tostring(toastErr or "未知错误")) end

    if ModalHost == nil or type(ModalHost.Attach) ~= "function" then return FailBuild("模态窗口宿主不可用") end
    local modalLayer = RSUI:Overlay({ id = "v3_shell_modal_layer", parent = self.root, slot = { hAlign = "fill", vAlign = "fill" } })
    local modalOk, modalErr = ModalHost:Attach(modalLayer)
    if modalOk ~= true then return FailBuild("模态窗口宿主挂载失败：" .. tostring(modalErr or "未知错误")) end

    self.windowController = Windowing:Attach({
        id = "main_shell", window = self.window, owner = self.owner, dragHandle = self.topBar,
        resizable = true, locked = (V3.ShellState or {}).locked == true,
        minWidth = (V3.ShellSizePolicy or {}).minWidth or 1, minHeight = (V3.ShellSizePolicy or {}).minHeight or 1,
        boundaryMode = "free", dragHandleHeight = 50,
        canResize = function() return true end,
        onGeometryChanged = function(controller, x, y, width, height, reason) return self:CommitWindowGeometry(controller, x, y, width, height, reason) end,
        onLiveGeometry = function(controller, x, y, width, height, kind) return self:ApplyInteractiveGeometry(x, y, width, height, kind) end,
    })
    if self.windowController == nil then return FailBuild("主窗口拖动/缩放能力创建失败") end
    -- 维护：手势跨 viewport 后先丢弃旧坐标，再从持久 intent 重排，不能保存混合坐标空间。
    self.windowController.onPlacementReady=function() return self:ApplyLayout(true) end

    self.created = true
    if V3.MainAppearance then
        local ready,appearanceErr=V3.MainAppearance:EnsureLoaded()
        self.mainAppearanceLoadError=ready~=true and appearanceErr or nil
        self.mainAppearance=nil
        local applied,applyErr=self:ApplyAppearanceSettings(V3.MainAppearance:GetSettings())
        if applied~=true then return FailBuild(applyErr)end
    end
    local minimizedOk, minimizedErr = self:ApplyMinimizedState(false)
    if minimizedOk ~= true then return FailBuild(minimizedErr or "主窗口初始状态应用失败") end
    local ok, layoutErr = self:ApplyLayout(false)
    if ok ~= true then return FailBuild(layoutErr) end

    local state = V3.ShellState or {}
    local initialRoute = Router:Resolve(state.lastRoute or "home") and tostring(state.lastRoute or "home") or "home"
    if initialRoute == "foundation" then initialRoute = "home" end
    local routed = self:Navigate(initialRoute, { source = "restore", keepHidden = true })
    if routed ~= true then self:Navigate("home", { source = "fallback", keepHidden = true }) end
    self:Close("create")
    if scope ~= nil and type(RSUI.EndBuildScope) == "function" then
        local committed, scopeErr = RSUI:EndBuildScope(scope, true)
        scope = nil
        if committed ~= true then return FailBuild(scopeErr or "主窗口严格构建失败") end
    end
    return true
end


function Shell:ApplyInteractiveGeometry(_, _, width, height, kind)
    if self.created ~= true or self.root == nil then return false end
    if tostring(kind or "") ~= "resize" then return true end
    width, height = math.max(1, tonumber(width) or 1), math.max(1, tonumber(height) or 1)
    self.root:LayoutIfNeeded(0, 0, width, height, true)
    if self.windowController ~= nil then
        local handlesOk, handlesErr = self.windowController:LayoutHandles(width, height)
        if handlesOk ~= true then return false, handlesErr or "主窗口缩放句柄布局失败" end
    end
    if type(RSUI.FlushLayoutQueue) == "function" then RSUI:FlushLayoutQueue(24) end
    return true
end

function Shell:ApplyLayout(fromMetricsChange, designWidth, designHeight)
    if self.created ~= true or self.window == nil or self.root == nil then return false, "主窗口尚未创建" end
    -- 局部字号放大不能仍塞进固定 20px 标题行；只扩展标题 chrome，不改持久窗口大小。
    local font=math.max(1,tonumber(self.mainAppearance and self.mainAppearance.fontScale) or 1)
    if self.topBar then self.topBar.slot.height=math.ceil(50*font)end
    if self.brandTitle then self.brandTitle.slot.height=math.ceil(20*font)end
    if self.supportText then self.supportText.slot.height=math.ceil(14*font)end
    if self.footer then self.footer.slot.height=math.ceil(44*font)end
    if self.windowController then self.windowController.dragHandleHeight=math.ceil(50*font)end
    -- 布局偏好由页面声明；普通页面恢复原边距，保留同一个内容 Border/Native parent。
    local contentPadding = PageHost.compactPageChrome == true and 6 or 14
    if self.contentFrame and self.contentFrame.padding.top ~= contentPadding then
        self.contentFrame.padding = { left = contentPadding, right = contentPadding, top = contentPadding, bottom = contentPadding }
        self.contentFrame.spec.padding = contentPadding
        self.contentFrame:InvalidateMeasure("page_chrome_changed")
    end
    local x, y, width, height, dw, dh = self:ResolveRect(designWidth, designHeight)
    if self.windowController ~= nil and self.windowController:IsInteracting() == true then
        -- 维护：活动手势沿固定 effective 单位读取；resolution 只标记，停止后再应用。
        if fromMetricsChange == true then self.windowController.pendingPlacement=true;return true end
        local ix, iy, iw, ih = self.windowController:GetLogicalRect()
        x, y, width, height = tonumber(ix) or x, tonumber(iy) or y, tonumber(iw) or width, tonumber(ih) or height
        if self.windowController:IsResizing() == true then
            self:ApplyInteractiveGeometry(x, y, width, height, "resize")
        end
        self.lastRect = { x = x, y = y, width = width, height = height, designWidth = dw, designHeight = dh, metricsChange = fromMetricsChange == true, interacting = true }
        return true, self.lastRect
    end
    -- 维护：Native 写入统一走 Windowing；已知 metrics/reset 强制失效几何缓存而非猜测缩放。
    local rectOk, rectErr = Windowing:ApplyGeometry(self.window,self.owner,x,y,width,height,fromMetricsChange==true or self.placementReason=="explicit_reset")
    if rectOk ~= true then return false, rectErr or "主窗口原生几何应用失败" end
    self.root:LayoutIfNeeded(0, 0, width, height, true)
    if self.windowController ~= nil then
        local handlesOk, handlesErr = self.windowController:LayoutHandles(width, height)
        if handlesOk ~= true then return false, handlesErr or "主窗口缩放句柄布局失败" end
    end
    -- Scroll visibility is known only after the first arrangement. Updating the
    -- hint can invalidate text/button measure, so do it BEFORE the final bounded
    -- stabilization flush; otherwise ApplyLayout would return a dirty tree.
    self:RefreshNavScrollHint()
    if type(RSUI.FlushLayoutQueue) == "function" then RSUI:FlushLayoutQueue(32) end
    self.lastRect = { x = x, y = y, width = width, height = height, designWidth = dw, designHeight = dh, metricsChange = fromMetricsChange == true, minimized = (V3.ShellState or {}).minimized == true }
    return true, self.lastRect
end

function Shell:Open()
    -- 维护：显式打开是允许的采样边沿，防启动 fallback 留在缓存。主窗仍不注册永久 Tick。
    S.Layout:GetContext(true)
    local created, err = self:Create()
    if created ~= true then return false, err end
    local wasVisible = Adapter:IsVisible(self.window)
    local state = V3.ShellState or {}
    local wasMinimized = state.minimized == true
    if wasMinimized then
        state.minimized = false
        local restored, restoreErr = self:ApplyMinimizedState(false)
        if restored ~= true then
            state.minimized = true
            self:ApplyMinimizedState(false)
            return false, restoreErr or "主窗口恢复状态应用失败"
        end
    end
    local layoutOk, layoutErr = self:ApplyLayout(false)
    if layoutOk ~= true then
        if wasMinimized then
            state.minimized = true
            self:ApplyMinimizedState(false)
        end
        return false, layoutErr or "主窗口布局应用失败"
    end
    if not wasVisible and type(UI.InvalidateNativeState)=="function" then UI:InvalidateNativeState(self.window,"visible") end
    local shown, showErr = Adapter:SetVisible(self.window, self.owner, true)
    if shown ~= true then
        if wasMinimized then
            state.minimized = true
            self:ApplyMinimizedState(false)
        end
        return false, showErr or "主窗口显示失败"
    end
    if not wasVisible then
        -- 中文维护（2026-10-05）：隐藏时的布局已建立 Diff 镜像，但 Native Show 仍可能
        -- 调整出生锚点。只在真实显示边沿通过 Windowing 重新提交同一矩形；不能等到
        -- 下一次导航才把这个合法交接记为 strict 越权，也不能强制跳过可见窗口的校验。
        local rect = self.lastRect
        local rectOk, rectErr = Windowing:ApplyGeometry(self.window,self.owner,rect.x,rect.y,rect.width,rect.height,true)
        if rectOk ~= true then
            local hidden, hideErr = Adapter:SetVisible(self.window,self.owner,false)
            if wasMinimized then
                state.minimized = true
                self:ApplyMinimizedState(false)
            end
            local detail = tostring(rectErr or "主窗口显示后位置应用失败")
            if hidden ~= true then detail = detail .. ":visibility_rollback_rejected:" .. tostring(hideErr) end
            return false, detail
        end
    end
    -- 中文维护：Navigate 也会调用 Open；只有本次真正从隐藏变为可见才轮换，显示失败不消费提示。
    if not wasVisible then self:AdvanceMenuTip() end
    if wasMinimized then MarkDirty("minimized_changed") end
    Adapter:Raise(self.window)
    return true
end

-- 维护：主窗硬恢复统一入口，设置页只调用它；先当前 viewport Native transaction，
-- 再标记原 Store dirty，失败恢复原状态。位置/尺寸属 ShellState，Workspace/Modal 不改。
function Shell:ResetLayout(persist)
    if self.window == nil or not self.created then return false,"main_window_unavailable" end
    S.Layout:GetContext(true)
    if self.windowController then self.windowController:CancelInteraction() end
    local state=V3.ShellState
    if type(state)~="table" then return false,"shell_state_unavailable" end
    local before={};for k,v in pairs(state)do before[k]=v end
    local shown=Adapter:IsVisible(self.window)
    local size=V3.ShellSizePolicy or {defaultWidth=1040,defaultHeight=700}
    state.width,state.height=size.defaultWidth,size.defaultHeight
    state.userMoved,state.minimized=false,false
    for _,key in ipairs({"x","y","anchorH","anchorV","offsetX","offsetY","coordinateSpace","savedUiScale",
        "savedLogicalWidth","savedLogicalHeight","normalizedCenterX","normalizedCenterY"})do state[key]=nil end
    self.placementReason="explicit_reset"
    local ok,err=self:ApplyLayout(true)
    if ok==true and shown then
        if type(UI.InvalidateNativeState)=="function" then UI:InvalidateNativeState(self.window,"visible") end
        ok,err=Adapter:SetVisible(self.window,self.owner,true)
    end
    if ok==true and persist~=false and type(V3.MarkShellStoreDirty)=="function" then ok,err=V3:MarkShellStoreDirty(0,"shell_layout_reset") end
    self.placementReason=nil
    if ok~=true then
        for k in pairs(state)do state[k]=nil end;for k,v in pairs(before)do state[k]=v end
        self:ApplyLayout(true)
        return false,err
    end
    return true
end

function Shell:GetPlacementDiagnostics()
    local d={};for k,v in pairs(self.placementInfo or {})do d[k]=v end
    d.windowId="main_shell";d.nativeVisible=Adapter:IsVisible(self.window);d.visibleRequested=d.nativeVisible
    if self.window then
        d.x,d.y,d.width,d.height=S.Layout:GetWindowLogicalRect(self.window,self.windowController and self.windowController.geometryUnitScale)
        d.fullyVisible=S.Layout:IsRectFullyVisible(d.x,d.y,d.width,d.height)
        d.recoverable=S.Layout:IsWindowRecoverable(d.x,d.y,d.width,d.height,50)
    end
    return d
end

function Shell:Close(reason)
    if RSUI.DropdownService ~= nil and type(RSUI.DropdownService.CloseAll) == "function" then
        RSUI.DropdownService:CloseAll()
    end
    if self.window == nil then return true end
    local restored,restoreErr=self:RestoreAppearancePreview()
    if restored~=true then return false,restoreErr end
    local hidden, hideErr = Adapter:SetVisible(self.window, self.owner, false)
    if hidden ~= true then return false, hideErr or "主窗口隐藏失败" end
    self.lastCloseReason = tostring(reason or "close")
    if ModalHost ~= nil and type(ModalHost.Clear) == "function" then ModalHost:Clear() end
    if ToastHost ~= nil and type(ToastHost.Clear) == "function" then ToastHost:Clear("shell_close") end
    return true
end

local function ReportNavigationFailure(routeId, reason, context)
    reason = tostring(reason or "未知错误")
    local source = tostring(type(context) == "table" and context.source or "")
    if S.DiagnosticsManager ~= nil and type(S.DiagnosticsManager.Error) == "function" then
        S.DiagnosticsManager:Error("v3_navigation", "PAGE_NAVIGATION_FAILED", "V3 页面打开失败", {
            route = tostring(routeId or ""), source = source, error = reason,
        })
    end
    if source == "navigation" or source == "system_navigation" or source == "topbar" then
        if ToastHost ~= nil and type(ToastHost.Notify) == "function" then
            ToastHost:Notify({
                id = "nav_failed_" .. tostring(routeId or "page"):gsub("[^%w]", "_"),
                title = "页面打开失败", detail = tostring(routeId or "页面") .. " · " .. reason,
                tone = "red", durationMs = 5200,
            })
        end
        if type(Shell.SetStatus) == "function" then Shell:SetStatus("页面打开失败 · " .. reason, "red") end
    end
    return false, reason
end

function Shell:Navigate(routeId, context)
    context = type(context) == "table" and context or {}
    local resolved = Router:Resolve(routeId)
    if resolved == nil then return ReportNavigationFailure(routeId, "页面不存在", context) end
    if resolved.probe == true then self.lastRoute = "foundation:probe"; return true end
    local ok, err = PageHost:Navigate(resolved.id, context)
    if ok ~= true then
        pcall(function() self:ApplyLayout(false) end)
        return ReportNavigationFailure(resolved.id, err or "页面创建/激活失败", context)
    end
    self.lastRoute = resolved.id
    Router.current = resolved.id
    -- 中文维护注释：隐藏子页属于语义子导航；这里仅修正侧栏选中态，PageHost 仍以 resolved.id 持有独立页面生命周期，禁止把子页业务合并进父 Feature。
    local navigationRoute = tostring(resolved.navigationParentRoute or "") -- 中文维护注释：优先采用 Registry/Router 明确声明的父导航路由，避免 Shell 写死团队中心等业务标识。
    if navigationRoute == "" or self.navButtons[navigationRoute] == nil then navigationRoute = resolved.id end -- 中文维护注释：没有合法父导航按钮时退回真实路由，保证普通页面和未知元数据继续按旧逻辑工作。
    for route, button in pairs(self.navButtons) do SetButtonSelected(button, route == navigationRoute) end -- 中文维护注释：只切换主导航视觉状态，不触发二次 Navigate、Consumer 获取或 Authority 读取。
    self:RefreshFeatureStates()
    local state = V3.ShellState or {}
    if state.lastRoute ~= resolved.id then state.lastRoute = resolved.id; MarkDirty("route_changed") end
    self:SetStatus(resolved.title)
    if context.keepHidden ~= true then return self:Open() end
    local layoutOk, layoutErr = self:ApplyLayout(false)
    if layoutOk ~= true then return false, layoutErr end
    return true
end

function Shell:RefreshData(dirty)
    if PageHost ~= nil and type(PageHost.RefreshData) == "function" then return PageHost:RefreshData(dirty) end
    return true
end

function Shell:GetSnapshot()
    local width, height = Adapter:GetExtent(self.window)
    local authority = self.window and UI:GetNativeAuthority(self.window) or nil
    return {
        created = self.created == true,
        visible = Adapter:IsVisible(self.window),
        width = width,
        height = height,
        owner = authority and authority.owner or nil,
        authorityMode = authority and authority.mode or nil,
        rootDirty = self.root and self.root:IsLayoutDirty() == true or false,
        buildQuarantined = tonumber(self.failedBuildGeneration) == tonumber(S.Generation),
        buildQuarantinedRejects = tonumber(self.buildQuarantinedRejects) or 0,
        buildError = self.failedBuildError,
        stackDirty = self.appStack and self.appStack:IsLayoutDirty() == true or false,
        lastRoute = self.lastRoute,
        minimized = (V3.ShellState or {}).minimized == true,
        locked = (V3.ShellState or {}).locked == true,
        pageHost = PageHost and PageHost:Describe() or nil,
        windowing = Windowing and Windowing:Describe() or nil,
        toastHost = ToastHost and ToastHost:Describe() or nil,
        modalHost = ModalHost and ModalHost:Describe() or nil,
        window = self.window,
        lastRect = self.lastRect,
    }
end
