------------------------------------------------------------------------
-- Replicated Suite · 背包快捷操作工具条
-- 作者：Replicated
-- QQ群：1104129461
--
-- tools_bag 的表现侧栏；仅已验证 bank/coffer 窗口打开时显示可自由移动的工具条。背包扫描/移动留在 Feature 内，只在明确点击后执行。
-- 取 / 放 / 全放 / 设置；搬运按钮沿用再点停止及方向切换契约。
-- 位置由独立 Presentation Store 保存；不再跟随原生背包移动。
------------------------------------------------------------------------
 if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
 local S = ReplicatedSuite
 local feature = S.Features and S.Features.tools_bag or nil
 if type(feature) ~= "table" or type(S.UI) ~= "table" then return end
 S.UIV3 = S.UIV3 or {}
 local P = {
     version=10, ReloadVisibilityContractVersion=2, NativeTransientHostContractVersion=2,
     VisibleRetryContractVersion=2, TooltipLayerContractVersion=1, TwoButtonContractVersion=1, ReleasedRootRecoveryContractVersion=1,
     -- 工具条默认标签为空，仅短暂显示执行状态或拒绝原因，消息清除后恢复紧凑宽度。
    -- 常驻“银行 · 可快捷取放”会给游戏覆盖层增加无用信息，应保持简单方便。
     QuietByDefaultContractVersion=1,
     -- 350 ms 心跳中的几何/文本写入必须按差异提交；保顶 Raise 应让位于已打开提示，避免周期性窗口在一秒内把用户提示压住，并保持差异渲染契约。
     DiffRenderContractVersion=1, HintYieldContractVersion=1,
     FourButtonContractVersion=1,
     FreePlacementContractVersion=1, DurablePlacementContractVersion=1,
     owner="v3:bag_quick_overlay",
     root=nil, dragHandle=nil, windowController=nil, take=nil, put=nil, allPut=nil, settings=nil, status=nil, shown=false,
     createAttempts=0, createFailures=0, releasedRootRecoveries=0, refreshes=0, visibleRefreshes=0, lastError=nil,
     appliedGeometry=nil, appliedStatus=nil,
 }
 S.UIV3.BagQuickOverlay = P
 -- 独立拖动把手使操作点击不受原生拖动捕获影响；安静模式仅使用 COMPACT_WIDTH，保留四个控件。
 local TAKE_X, TAKE_W = 32, 40
 local PUT_X, PUT_W = 76, 40
 local ALL_X, ALL_W = 120, 48
 local SETTINGS_X, SETTINGS_W = 172, 56
 local STATUS_X = 236
 local COMPACT_WIDTH = 232
 local MIN_WIDTH, MAX_WIDTH = 388, 508
 -- 拒绝/停止信息保留足够阅读时间后恢复安静形态；到期判断使用已有 100 ms 只读窗口观察节拍，不添加任务或 Tick。
 local MESSAGE_TTL_MS = 6000

local STORE_ID = "v3.presentation.bag_quick_overlay"
local WINDOW_ID = "v3_bag_quick_overlay"
local Persistence = S.Persistence
local Windowing = S.RSUI and S.RSUI.Windowing
local function NormalizePosition(value)
    value=type(value)=="table" and value or {}
    local out={userMoved=value.userMoved==true}
    if out.userMoved then
        out.coordinateSpace="logical-free-v2"
        for _,key in ipairs({"x","y","savedUiScale","savedLogicalWidth","savedLogicalHeight","normalizedCenterX","normalizedCenterY"}) do
            local n=tonumber(value[key])
            if n~=nil and n==n and n~=math.huge and n~=-math.huge then out[key]=n end
        end
        if out.x==nil or out.y==nil then return {userMoved=false} end
    end
    return out
end
P.positionState=NormalizePosition(nil)
P.storeId=STORE_ID
if type(Persistence)=="table" and type(Persistence.RegisterV3Store)=="function" then
    local store,err=Persistence:RegisterV3Store({
        id=STORE_ID,owner=STORE_ID,scope=Persistence.Scope.Account,lifetime=Persistence.Lifetime.Permanent,
        schemaVersion=1,key=Persistence.V3KeyPrefix.."presentation_bag_quick_overlay",
        budget={maxDepth=3,maxNodes=32,maxStringBytes=256,maxEntriesPerTable=16},
        default=function()return NormalizePosition(nil) end,
        get=function()return NormalizePosition(P.positionState) end,
        apply=function(value)P.positionState=NormalizePosition(value) end,
    })
    if store==nil then P.positionError=tostring(err or "悬浮栏位置存档注册失败") end
else P.positionError="悬浮栏位置存档不可用" end

function P:EnsurePositionLoaded(retry)
    if type(Persistence)~="table" then return false,self.positionError end
    if Persistence:IsStoreLoaded(STORE_ID)==true then return true end
    -- 失败存档只在首次显示或显式拖动/重置时重试，100ms 可见心跳不反复读盘。
    if self.positionLoadAttempted==true and retry~=true then return false,self.positionError end
    self.positionLoadAttempted=true
    local status,_,err=Persistence:LoadStore(STORE_ID)
    if status~=true and status~="empty" then
        self.positionError=tostring(err or status or "悬浮栏位置读取失败");return false,self.positionError
    end
    self.positionError=nil
    return true
end

function P:CommitPosition(x,y,width,height)
    local loaded,err=self:EnsurePositionLoaded()
    if loaded~=true then return false,err end
    local ok,saveErr=Persistence:MutateStore(STORE_ID,function()
        local state={userMoved=true}
        -- 使用 Windowing 已提交的实际矩形；宽栏若仍按232保存，后续缩窄便无法识别原来的右边缘。
        S.Layout:StorePlacementRect(state,x,y,math.max(1,tonumber(width) or COMPACT_WIDTH),math.max(1,tonumber(height) or 32),{mode="free"})
        self.positionState=NormalizePosition(state)
        return true
    end,{durable=true,reason="bag_quick_overlay:drag"})
    self.positionError=ok~=true and tostring(saveErr or "悬浮栏位置保存失败") or nil
    self.appliedGeometry=nil
    if ok~=true then
        self.actionError="位置保存失败";self.actionErrorAt=type(S.NowMs)=="function" and S.NowMs() or 0
        -- Persistence 已回滚位置意图；立即恢复 Native，不能留下看似保存成功的位置。
        self:Refresh(true)
    end
    return ok,saveErr
end

function P:ResetPosition()
    local loaded,err=self:EnsurePositionLoaded(true)
    if loaded~=true then return false,err end
    if self.windowController then self.windowController:CancelInteraction() end
    local ok,saveErr=Persistence:MutateStore(STORE_ID,function()
        self.positionState=NormalizePosition(nil);return true
    end,{durable=true,reason="bag_quick_overlay:reset"})
    self.positionError=ok~=true and tostring(saveErr or "悬浮栏位置重置失败") or nil
    if ok==true then self.defaultPositionState=nil end
    self.appliedGeometry=nil;self:Refresh(true)
    return ok,saveErr
end

-- 可见转换时宿主构建失败应在帧节拍有界重试，不等待下一次 100 ms 仓库心跳；RU 可能在仓库开启动画中拒绝首次临时窗口创建，用户若提前关闭会错过整个会话。
-- one-shot 在回调前自动移除，不引入永久 Tick。
local CREATE_RETRY_TASK = "v3_bag_quick_overlay_create_retry"
-- 重试周期状态保存在 P，不能作为闭包局部变量；回调再次调用此方法时须保留计数，仅外部启动新周期才重置，否则上限不会触发而无限重试。此控制流边界需由 Lua 模拟验证。
function P:ScheduleCreateRetry(freshCampaign)
    if S.Scheduler == nil or type(S.Scheduler.AddHighFrequencyOneShot) ~= "function" then return false end
    -- 同一时刻只允许一个在途重试；运行中的任务已覆盖此次请求。
    if self.retryScheduled == true then return true end
    if freshCampaign ~= false then self.retryCount = 0 end
    local added = S.Scheduler:AddHighFrequencyOneShot(CREATE_RETRY_TASK, 64, function()
        P.retryScheduled = false
        if P.root ~= nil then return true end
        local ok, err = P:EnsureCreated()
        if ok == true then return P:Refresh() end
        P.lastError = tostring(err or "bag_quick_overlay_retry_create_failed")
        -- 仍失败时再次安排重试，但限制连续次数，避免原生契约永久不可用时无限循环。
        P.retryCount = (tonumber(P.retryCount) or 0) + 1
        if P.retryCount < 8 then return P:ScheduleCreateRetry(false) end
        return false
    end, P, "P1", 1)
    if added == true then
        self.retryScheduled = true
    end
    return added == true
end

-- 用户正在阅读的提示优先于保顶 Raise；提示服务无法判断时不抬升，避免抢走无法观测窗口的层级。
local function HintIsShowing()
    local tooltip = S.RSUI and S.RSUI.Tooltip or nil
    if type(tooltip) ~= "table" or type(tooltip.IsShowing) ~= "function" then return true end
    local ok, showing = pcall(function() return tooltip:IsShowing() == true end)
    if ok ~= true then return true end
    return showing == true
end

-- 空字符串表示不显示文字；仓库类型可从刚打开的窗口识别，工具条不应常驻说明标签。
local function OverlayStatusText(overlay, now)
    if overlay.running == true then
        -- 进度取代“停”按钮作为操作反馈，使用户看见
        -- 操作正在执行，再次点击同一按钮即可结束。
        return tostring(overlay.status or "正在处理") .. " " .. tostring(tonumber(overlay.moved) or 0)
            .. "/" .. tostring(tonumber(overlay.queued) or 0)
    end
    local status = tostring(overlay.status or "")
    if status == "" or status == "可快捷取放" or status == "等待仓库/箱子" then return "" end
    local at = tonumber(overlay.statusAt) or 0
    if at <= 0 then return "" end
    if (tonumber(now) or 0) - at > MESSAGE_TTL_MS then return "" end
    if status=="已完成" then
        return "完成 "..tostring(tonumber(overlay.moved) or 0).." · 跳过 "..tostring(tonumber(overlay.skipped) or 0)
    end
    return status
end

function P:EnsureCreated()
    -- UI:ReleaseOwner 标记原生控件已释放，但 Lua 引用可能在热重载/宿主拆除后存留；该引用应视为无效并重建，不能宣称 presenter 已创建。
    if self.root ~= nil and self.root.rsUiReleased == true then
        if Windowing then Windowing:Detach(WINDOW_ID) end
        if S.Layout then S.Layout:UnregisterFloating(WINDOW_ID) end
        self.windowController,self.dragHandle=nil,nil
        self.root,self.take,self.put,self.allPut,self.settings,self.status=nil,nil,nil,nil,nil,nil
        self.shown=false; self.appliedGeometry=nil; self.appliedStatus=nil
        self.releasedRootRecoveries=(tonumber(self.releasedRootRecoveries) or 0)+1
    end
    if self.root ~= nil then return true end
    self.createAttempts=(tonumber(self.createAttempts) or 0)+1
    -- RU 顶层 emptywidget 不能可靠作为 system 层宿主，可能投影有效却完全不可见。快捷操作属于交互式屏幕表现，须用临时 WINDOW；
    -- 该条不是组件弹层，Windowing 负责 UIParent 几何与原生拖动租约，Feature 仅负责可见性/操作。
    local root,err=S.UI:CreatePanel(UIParent,"v3_bag_quick_overlay_root",0,0,MIN_WIDTH,32,"soft",{
        transientWindow=true, visible=false, pickable=false, gradient=false,
        accentStrip=false, owner=self.owner,
        drawPriority=S.UITokens and type(S.UITokens.Number)=="function" and S.UITokens:Number("layer.popupPriority",10000) or 10000,
    })
    if root==nil or root.rsUiDegraded==true then
        self.createFailures=(tonumber(self.createFailures) or 0)+1
        self.lastError=tostring(err or (root and root.rsUiDegradedReason) or "bag_quick_overlay_root_failed")
        return false,self.lastError
    end
    if type(S.UI.EnsurePickable)~="function" or type(S.UI.EnsureEnabled)~="function" then
        S.UI:SetVisible(root,false,self.owner); if type(S.UI.ReleaseOwner)=="function" then S.UI:ReleaseOwner(self.owner) end
        self.createFailures=(tonumber(self.createFailures) or 0)+1; self.lastError="bag_quick_overlay_interaction_contract_unavailable"
        return false,self.lastError
    end
    local pickOk,_,pickErr=S.UI:EnsurePickable(root,false,self.owner)
    local enabledOk,_,enabledErr=S.UI:EnsureEnabled(root,true,self.owner)
    if pickOk~=true or enabledOk~=true then
        S.UI:SetVisible(root,false,self.owner); if type(S.UI.ReleaseOwner)=="function" then S.UI:ReleaseOwner(self.owner) end
        self.createFailures=(tonumber(self.createFailures) or 0)+1
        self.lastError="bag_quick_overlay_interaction_failed:"..tostring(pickErr or enabledErr or "unknown")
        return false,self.lastError
    end
    -- 再次点击正在执行的同一按钮即可停止；此决定归 tools_bag 业务权威层，不归表现层。
    local take=S.UI:CreateButton(root,"v3_bag_quick_take","取",TAKE_X,4,TAKE_W,24,10,true,true,self.owner)
    local put=S.UI:CreateButton(root,"v3_bag_quick_put","放",PUT_X,4,PUT_W,24,10,true,true,self.owner)
    local allPut=S.UI:CreateButton(root,"v3_bag_quick_all_put","全放",ALL_X,4,ALL_W,24,10,true,true,self.owner)
    local settings=S.UI:CreateButton(root,"v3_bag_quick_settings","设置",SETTINGS_X,4,SETTINGS_W,24,10,true,true,self.owner)
    local dragHandle=S.UI:CreateButton(root,"v3_bag_quick_drag","≡",4,4,24,24,11,true,true,self.owner)
    local status=S.UI:CreateLabel(root,"v3_bag_quick_status","",STATUS_X,4,MIN_WIDTH-STATUS_X-4,24,9,"muted","LEFT",true,self.owner)
    if take==nil or put==nil or allPut==nil or settings==nil or status==nil or dragHandle==nil then
        S.UI:SetVisible(root,false,self.owner); if type(S.UI.ReleaseOwner)=="function" then S.UI:ReleaseOwner(self.owner) end
        self.root=nil; self.createFailures=(tonumber(self.createFailures) or 0)+1; self.lastError="bag_quick_overlay_child_failed"
        return false,self.lastError
    end
    self.root,self.take,self.put,self.allPut,self.settings,self.status=root,take,put,allPut,settings,status
    self.dragHandle=dragHandle
    root.rsUiCoordinateLane="managed-window-v1"
    root.rsUiCoordinateSpace="viewport-logical-v1"
    local function bind(widget,name,fn)
        if type(S.UI.RequireHandler) ~= "function" then return false, "critical_interaction_contract_unavailable" end
        return S.UI:RequireHandler(widget,"OnClick",function()
            local ok,actionErr=fn(feature.Commands)
            if ok~=true then self.actionError=name=="settings" and "设置失败" or "操作失败";self.actionErrorAt=type(S.NowMs)=="function" and S.NowMs() or 0;self.lastError=tostring(actionErr or "未执行")
            else self.actionError=nil end
            -- 标签只允许一个写入者：Feature 为每次点击发布简短状态与完整原因，presenter 从投影刷新；下方直接写仅在刷新无法显示时兜底。
            P:Refresh()
            if ok~=true and self.shown~=true then
                S.UI:SetText(status,tostring(actionErr or "失败"),P.owner)
            end
            return ok,actionErr
        end,"v3_bag_quick:"..name)
    end
    local takeBound,takeErr=bind(take,"take",function(c) return c:QuickWithdraw() end)
    local putBound,putErr=bind(put,"put",function(c) return c:QuickDeposit() end)
    local allBound,allErr=bind(allPut,"all_put",function(c) return c:QuickDepositAll() end)
    local settingsBound,settingsErr=bind(settings,"settings",function()
        local menu=S.UIV3 and S.UIV3.BagSettingsFloatingV3
        if type(menu)~="table" or type(menu.Open)~="function" then return false,"背包设置浮窗不可用" end
        return menu:Open()
    end)
    local tooltip=S.RSUI and S.RSUI.Tooltip or nil
    if type(tooltip)=="table" and type(tooltip.Bind)=="function" then
        -- “停”按钮移除后，停止规则须在其它位置清楚说明；
        -- 用户点击前会查看按钮悬浮提示；仅保留两条短行，提示池按原生标签测量，长句会裁切。切换规则和“仅同类”的完整说明放在能自动换行的页面提示 Text 中。
        tooltip:Bind(take,{ text="取：取出与背包同类的物品（只移两边都有的）。再点一次＝停止。", allowRaw=true, cursorFollow=true, maxWidth=320 })
        tooltip:Bind(put,{ text="放：存入与仓库同类的物品（仓库满时仍会堆叠）。再点一次＝停止。", allowRaw=true, cursorFollow=true, maxWidth=320 })
        tooltip:Bind(allPut,{ text="全放：尝试存入所有非黑名单物品，不能存的会跳过。再点一次＝停止。", allowRaw=true, cursorFollow=true, maxWidth=360 })
        tooltip:Bind(settings,{ text="设置：从背包物品列表直接添加或移除整理黑名单。", allowRaw=true, cursorFollow=true, maxWidth=320 })
        tooltip:Bind(dragHandle,{ text="拖动此处调整悬浮栏位置，松开自动保存。设置中可重置位置。", allowRaw=true, cursorFollow=true, maxWidth=320 })
    end
    if takeBound~=true or putBound~=true or allBound~=true or settingsBound~=true then
        S.UI:SetVisible(root,false,self.owner); if type(S.UI.ReleaseOwner)=="function" then S.UI:ReleaseOwner(self.owner) end
        self.root,self.take,self.put,self.allPut,self.settings,self.status=nil,nil,nil,nil,nil,nil
        self.createFailures=(tonumber(self.createFailures) or 0)+1
        self.lastError=tostring(takeErr or putErr or allErr or settingsErr or "bag_quick_required_handler_failed")
        return false,self.lastError
    end
    local controller,dragErr
    if type(Windowing)=="table" and type(Windowing.Attach)=="function" then
        controller,dragErr=Windowing:Attach({
            id=WINDOW_ID,owner=self.owner,window=root,dragHandle=dragHandle,
            resizable=false,locked=false,scaleWithAddon=false,boundaryMode="free",dragHandleHeight=32,
            canDrag=function()
                if self.shown~=true then return false end
                local loaded=self:EnsurePositionLoaded(true)
                if loaded~=true then
                    self.actionError="位置读取失败";self.actionErrorAt=type(S.NowMs)=="function" and S.NowMs() or 0
                    self:Refresh()
                end
                return loaded==true
            end,
            onGeometryChanged=function(_,x,y,w,h)return self:CommitPosition(x,y,w,h) end,
            onDragStop=function()self.appliedGeometry=nil;return self:Refresh() end,
        })
    end
    if controller==nil then
        S.UI:SetVisible(root,false,self.owner);if type(S.UI.ReleaseOwner)=="function" then S.UI:ReleaseOwner(self.owner) end
        self.root,self.take,self.put,self.allPut,self.settings,self.status=nil,nil,nil,nil,nil,nil
        self.dragHandle=nil;self.createFailures=(tonumber(self.createFailures) or 0)+1
        self.lastError=tostring(dragErr or "悬浮栏拖动控件不可用");return false,self.lastError
    end
    self.windowController=controller
    controller.onPlacementReady=function()self.appliedGeometry=nil;return self:Refresh(true) end
    S.Layout:RegisterFloating(WINDOW_ID,root,{ensureNow=false,safetyMode="free",onMetricsChanged=function(changed)
        if controller:IsInteracting()==true then controller.pendingPlacement=true;return true end
        self.appliedGeometry=nil;return self:Refresh(changed==true)
    end})
    S.UI:SetVisible(root,false,self.owner)
    self.lastError=nil
    return true
end

function P:Refresh(forceGeometry)
    self.refreshes=(tonumber(self.refreshes) or 0)+1
    local projection=feature:GetProjection() or {}
    local overlay=type(projection.quickOverlay)=="table" and projection.quickOverlay or {}
    if overlay.visible~=true then
        if self.windowController then self.windowController:CancelInteraction() end
        if self.root~=nil and self.shown==true then S.UI:SetVisible(self.root,false,self.owner) end
        self.shown=false; self.appliedGeometry=nil; self.appliedStatus=nil
        return true
    end
    self.visibleRefreshes=(tonumber(self.visibleRefreshes) or 0)+1
    local ok,err=self:EnsureCreated()
    if ok~=true then
        self.lastError=tostring(err or "bag_quick_overlay_create_failed")
        -- 仓库当前打开；宿主构建失败应在帧节拍自愈，不等待观察器下次心跳。
        self:ScheduleCreateRetry()
        return false,err
    end
    self:EnsurePositionLoaded()
    -- 可见观察心跳不能抢回 Native 正在拖动的坐标，也不能在手势中更改栏宽。
    if self.windowController and self.windowController:IsInteracting()==true then return true end
    local now=type(S.NowMs)=="function" and tonumber(S.NowMs()) or 0
    local statusText=OverlayStatusText(overlay,now)
    if self.actionError~=nil and now-(tonumber(self.actionErrorAt) or 0)<=MESSAGE_TTL_MS then statusText=self.actionError end
    -- 无消息时仅显示按钮；有消息时扩大工具条，宽度不能小于消息所需宽度。
    local width=statusText=="" and COMPACT_WIDTH
        or math.max(MIN_WIDTH,math.min(MAX_WIDTH,tonumber(overlay.width) or MIN_WIDTH))
    local viewport=S.Layout and type(S.Layout.GetContext)=="function" and S.Layout:GetContext() or {}
    local logicalWidth,logicalHeight=tonumber(viewport.logicalWidth) or 1024,tonumber(viewport.logicalHeight) or 768
    local defaultX=(logicalWidth-COMPACT_WIDTH)*0.5
    local defaultY=logicalHeight-(tonumber(viewport.safeBottom) or 0)-100
    if self.defaultPositionState==nil and type(overlay.bagRect)=="table"
        and tonumber(overlay.bagRect.x) and tonumber(overlay.bagRect.y) then
        -- 首次显示以已校准背包边界摆在上方；之后保留独立位置，不跟随原生窗口。
        local initial={userMoved=true}
        S.Layout:StorePlacementRect(initial,overlay.bagRect.x,overlay.bagRect.y-32-8,COMPACT_WIDTH,32,{mode="free"})
        self.defaultPositionState=initial
    end
    local intent=self.positionState.userMoved==true and self.positionState or self.defaultPositionState
    width=math.min(width,tonumber(viewport.usableWidth) or logicalWidth)
    local x,y=S.Layout:ResolvePlacement(intent,width,32,defaultX,defaultY,{mode="free",topLevel=true,topReachHeight=32})
    x,y=S.Layout:ClampTopLeft(x,y,width,32)
    self.placement={x=x,y=y,width=width,height=32,
        source=self.positionState.userMoved==true and "saved_free_position" or "default_free_position",
        anchorMode="free",coordinateSpace="viewport-logical-v1",
        uiScale=viewport.uiScale,logicalWidth=viewport.logicalWidth,logicalHeight=viewport.logicalHeight}
    local geometryKey=tostring(math.floor(x))..":"..tostring(math.floor(y))..":"..tostring(width)
        ..":"..tostring(viewport.uiScale)..":"..tostring(viewport.logicalWidth)..":"..tostring(viewport.logicalHeight)
    local firstShow=self.shown~=true
    local geometryChanged=self.appliedGeometry~=geometryKey
    -- 约束（2026-10-04）：仅 Windowing 提交/校验自由位置，永不引用原生背包锚点。
    self.anchorChecks=(tonumber(self.anchorChecks) or 0)+1
    local anchored,anchorErr=Windowing:ApplyGeometry(self.root,self.owner,x,y,width,32,forceGeometry==true or firstShow)
    if anchored~=true then
        self.anchorFailures=(tonumber(self.anchorFailures) or 0)+1
        self.lastError=tostring(anchorErr or "悬浮栏位置提交失败");return false,self.lastError
    end
    self.lastError=nil
    if geometryChanged or firstShow then
        S.UI:SetAnchor(self.status,self.root,STATUS_X,4,self.owner)
        S.UI:SetExtent(self.status,math.max(44,width-STATUS_X-4),24,self.owner)
        self.appliedGeometry=geometryKey
    end
    -- 仅句子实际变化时重写标签；每 350ms 重写原生文字会造成额外工作，部分 RU 写入还会重新声明窗口状态。
    if self.appliedStatus~=statusText then
        S.UI:SetText(self.status,statusText,self.owner)
        S.UI:SetVisible(self.status,statusText~="" and true or false,self.owner)
        self.appliedStatus=statusText
    end
    if geometryChanged or firstShow then
        local visible,_,showErr=S.UI:EnsureVisible(self.root,true,self.owner)
        if visible~=true then self.lastError=tostring(showErr or "悬浮栏显示失败");return false,self.lastError end
        self.shown=true
        S.UI:TrySetUILayer(self.root,"system")
        if firstShow then
            -- 与 WindowShell 的 show 边沿一致：原生首次显示可重置锚点，显示后再提交一次。
            local confirmed,confirmErr=Windowing:ApplyGeometry(self.root,self.owner,x,y,width,32,true)
            if confirmed~=true then
                S.UI:SetVisible(self.root,false,self.owner);self.shown=false;self.appliedGeometry=nil
                self.lastError=tostring(confirmErr or "悬浮栏显示后位置提交失败");return false,self.lastError
            end
        end
        if type(self.root.Raise)=="function" then pcall(function() self.root:Raise() end) end
        return true
    end
    -- 稳定节拍保持工具条在原生背包上方，但不能覆盖用户正在阅读的提示。
    if HintIsShowing()~=true and type(self.root.Raise)=="function" then
        pcall(function() self.root:Raise() end)
    end
    return true
end


function P:GetHealth()
    return {
        version=tonumber(self.version) or 0, buttons=4, movable=true, positionStore=STORE_ID,
        positionLoaded=Persistence and Persistence:IsStoreLoaded(STORE_ID)==true or false,positionError=self.positionError,
        positionState=NormalizePosition(self.positionState),dragging=self.windowController and self.windowController:IsInteracting()==true or false,
        defaultPositionState=S.Utils and type(S.Utils.DeepCopy)=="function" and S.Utils.DeepCopy(self.defaultPositionState) or nil,
        labelVisible=self.appliedStatus~=nil and self.appliedStatus~="",
        created=self.root~=nil, visible=self.shown==true,
        createAttempts=tonumber(self.createAttempts) or 0, createFailures=tonumber(self.createFailures) or 0,
        releasedRootRecoveries=tonumber(self.releasedRootRecoveries) or 0,
        refreshes=tonumber(self.refreshes) or 0, visibleRefreshes=tonumber(self.visibleRefreshes) or 0,
        anchorChecks=tonumber(self.anchorChecks) or 0, anchorRecoveries=tonumber(self.anchorRecoveries) or 0,
        anchorFailures=tonumber(self.anchorFailures) or 0,
        retryScheduled=self.retryScheduled==true, retryCount=tonumber(self.retryCount) or 0, lastError=self.lastError,
        placement=S.Utils and type(S.Utils.DeepCopy)=="function" and S.Utils.DeepCopy(self.placement) or self.placement,
        settings=S.UIV3.BagSettingsFloatingV3 and S.UIV3.BagSettingsFloatingV3:GetHealth() or nil,
    }
end

if type(S.ModuleDiagnosticsHub)=="table" and type(S.ModuleDiagnosticsHub.RegisterProvider)=="function" then
    -- 只复制已采集的布局/保存结果；诊断不创建窗口、不读档、不扫描背包。
    S.ModuleDiagnosticsHub:RegisterProvider(feature.Id,"bag_free_position",function()return P:GetHealth() end,55,{detailOnly=true})
end

if S.Events ~= nil and type(S.Events.SubscribeInternal)=="function" then
    S.Events:SubscribeInternal(feature.UpdateTopic,P,function() return P:Refresh() end)
    S.Events:SubscribeInternal("v3.feature.lifecycle",P,function(_,featureId)
        if tostring(featureId or "")=="tools_bag" then return P:Refresh() end
    end)
end
-- 模块准入时构建隐藏临时宿主；首次可见事件若遇原生创建暂时失败，后续可见心跳仍可通过 Refresh() 重试，消除首次打开竞态。
P:EnsureCreated()
P:Refresh()
