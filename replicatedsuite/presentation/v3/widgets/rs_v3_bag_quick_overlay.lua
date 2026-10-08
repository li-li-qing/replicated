 ------------------------------------------------------------------------
 -- Replicated Suite V3 - Bag Quick Take/Put Overlay
 --
 -- Presentation-only companion for tools_bag. A freely movable bar is shown
 -- only while a verified bank/coffer window is open. Inventory scans/moves stay
 -- inside the Feature and run only after an explicit click.
 --
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
     -- Quiet bar: the label is empty by default and only
     -- carries a transient message (run in progress / why a click refused), then
     -- clears itself and the bar shrinks back. An always-on "银行 · 可快捷取放"
     -- sentence is noise on a game overlay (user report: 简单方便最重要).
     QuietByDefaultContractVersion=1,
     -- v7: the 350 ms heartbeat used to rewrite geometry/text and Raise the bar
     -- on every beat. Raising a periodic surface over a transient hint buries the
     -- hint within a second (RU report) and breaks the diff-rendering rule, so
     -- writes are now diffed and the keep-on-top raise yields to an open hint.
     DiffRenderContractVersion=1, HintYieldContractVersion=1,
     FourButtonContractVersion=1,
     FreePlacementContractVersion=1, DurablePlacementContractVersion=1,
     owner="v3:bag_quick_overlay",
     root=nil, dragHandle=nil, windowController=nil, take=nil, put=nil, allPut=nil, settings=nil, status=nil, shown=false,
     createAttempts=0, createFailures=0, releasedRootRecoveries=0, refreshes=0, visibleRefreshes=0, lastError=nil,
     appliedGeometry=nil, appliedStatus=nil,
 }
 S.UIV3.BagQuickOverlay = P
 -- A dedicated grip leaves action clicks independent from native drag capture.
 -- Quiet mode uses only COMPACT_WIDTH and retains all four controls.
 local TAKE_X, TAKE_W = 32, 40
 local PUT_X, PUT_W = 76, 40
 local ALL_X, ALL_W = 120, 48
 local SETTINGS_X, SETTINGS_W = 172, 56
 local STATUS_X = 236
 local COMPACT_WIDTH = 232
 local MIN_WIDTH, MAX_WIDTH = 388, 508
 -- A refusal/stop message stays readable long enough to be read once, then the
 -- bar returns to its quiet form.  Expiry is evaluated on the beats the existing
 -- 100 ms read-only window observer already publishes: no new task, no Tick.
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

function P:CommitPosition(x,y)
    local loaded,err=self:EnsurePositionLoaded()
    if loaded~=true then return false,err end
    local ok,saveErr=Persistence:MutateStore(STORE_ID,function()
        local state={userMoved=true}
        -- 固定使用静默栏尺寸记录位置意图，进度/错误文字扩展不能改变保存的中心点。
        S.Layout:StorePlacementRect(state,x,y,COMPACT_WIDTH,32,{mode="free"})
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

-- A failed host build during a visible transition must not wait for the next
-- 100 ms storage heartbeat to retry: RU can reject the first transient-window
-- creation while the native bank/coffer window is still animating open, and if
-- the user closes it again before the next heartbeat the overlay never appears
-- for that session. Retry on the frame-cadence lane instead (bounded one-shot,
-- auto-removed before the callback runs, so no permanent Tick is introduced).
local CREATE_RETRY_TASK = "v3_bag_quick_overlay_create_retry"
-- Campaign state lives on P, NOT as a closure local: the in-callback re-arm
-- calls this same method. The counter may only reset when a NEW campaign is
-- armed from outside; a re-arm must preserve it, or the cap never triggers and
-- the retry loops forever (caught by the Lua simulator, not static fences --
-- exactly why control-flow tests exist).
function P:ScheduleCreateRetry(freshCampaign)
    if S.Scheduler == nil or type(S.Scheduler.AddHighFrequencyOneShot) ~= "function" then return false end
    -- One in-flight retry at a time; the running task already covers this request.
    if self.retryScheduled == true then return true end
    if freshCampaign ~= false then self.retryCount = 0 end
    local added = S.Scheduler:AddHighFrequencyOneShot(CREATE_RETRY_TASK, 64, function()
        P.retryScheduled = false
        if P.root ~= nil then return true end
        local ok, err = P:EnsureCreated()
        if ok == true then return P:Refresh() end
        P.lastError = tostring(err or "bag_quick_overlay_retry_create_failed")
        -- Still failing: re-arm once more, but cap consecutive retries so a
        -- permanently unavailable native contract cannot loop forever.
        P.retryCount = (tonumber(P.retryCount) or 0) + 1
        if P.retryCount < 8 then return P:ScheduleCreateRetry(false) end
        return false
    end, P, "P1", 1)
    if added == true then
        self.retryScheduled = true
    end
    return added == true
end

-- A hint the user is currently reading outranks our keep-on-top raise. When the
-- tooltip service cannot answer, we do not raise at all: stealing z-order from
-- something we cannot see is worse than losing one beat of re-assertion.
local function HintIsShowing()
    local tooltip = S.RSUI and S.RSUI.Tooltip or nil
    if type(tooltip) ~= "table" or type(tooltip.IsShowing) ~= "function" then return true end
    local ok, showing = pcall(function() return tooltip:IsShowing() == true end)
    if ok ~= true then return true end
    return showing == true
end

-- "" means say nothing.  The idle sentence ("银行 · 可快捷取放") carried no
-- information, and the storage kind is already obvious from the window the user
-- just opened -- a game overlay must not wear a permanent label.
local function OverlayStatusText(overlay, now)
    if overlay.running == true then
        -- Progress is the affordance that replaces 停: the user can see that a
        -- run is live, and that clicking the same button again is what ends it.
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
    -- UI:ReleaseOwner marks native widgets as released but an owner-side Lua
    -- reference can survive a hot reload / host teardown. Treat that reference
    -- as dead and rebuild instead of claiming the presenter is already created.
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
    -- Top-level emptywidgets are not a reliable RU system-layer host. The UI
    -- primitive contract already records the same failure class that once made
    -- Unit Lines have valid projection but zero visible dots. Quick actions are
    -- interactive screen presentation, so use a transient WINDOW. IMPORTANT:
    -- this bar is NOT a component popup. Windowing owns the UIParent geometry
    -- and the native drag lease; the Feature owns only visibility/actions.
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
    -- 停 was reported as useless: a stop is now the same
    -- button pressed again, and the decision lives in tools_bag (the business
    -- Authority), not in the presentation layer.
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
            -- One writer per label: the Feature publishes a short status plus the
            -- long reason for every click, so the presenter refreshes from that
            -- projection instead of painting the label itself.  The direct write
            -- below is only the fallback for a refresh that could not display.
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
        -- The stop rule has to be discoverable somewhere now that 停 is gone, and
        -- the button hover is where the user looks before clicking. Keep it to two
        -- short lines: the pooled hint box is measured against a native label, and
        -- a long sentence is exactly what the user screenshotted as clipped. The
        -- switch rule and the full "same-kind only" explanation live in the page
        -- hint line, which is a real wrapped Text with room to breathe.
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
            onGeometryChanged=function(_,x,y)return self:CommitPosition(x,y) end,
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
        -- The storage is open right now; a failed host build must self-heal on
        -- frame cadence instead of waiting for the next observer heartbeat.
        self:ScheduleCreateRetry()
        return false,err
    end
    self:EnsurePositionLoaded()
    -- 可见观察心跳不能抢回 Native 正在拖动的坐标，也不能在手势中更改栏宽。
    if self.windowController and self.windowController:IsInteracting()==true then return true end
    local now=type(S.NowMs)=="function" and tonumber(S.NowMs()) or 0
    local statusText=OverlayStatusText(overlay,now)
    if self.actionError~=nil and now-(tonumber(self.actionErrorAt) or 0)<=MESSAGE_TTL_MS then statusText=self.actionError end
    -- Nothing to say -> buttons only.  Something to say -> grow the bar, but
    -- never below the width that fits the message.
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
    local x,y=S.Layout:ResolvePlacement(intent,COMPACT_WIDTH,32,defaultX,defaultY,{mode="free",topLevel=true,topReachHeight=32})
    width=math.min(width,tonumber(viewport.usableWidth) or logicalWidth)
    x,y=S.Layout:ClampTopLeft(x,y,width,32)
    self.placement={x=x,y=y,width=width,height=32,
        source=self.positionState.userMoved==true and "saved_free_position" or "default_free_position",
        anchorMode="free",coordinateSpace="viewport-logical-v1",
        uiScale=viewport.uiScale,logicalWidth=viewport.logicalWidth,logicalHeight=viewport.logicalHeight}
    local geometryKey=tostring(math.floor(x))..":"..tostring(math.floor(y))..":"..tostring(width)
        ..":"..tostring(viewport.uiScale)..":"..tostring(viewport.logicalWidth)..":"..tostring(viewport.logicalHeight)
    local firstShow=self.shown~=true
    local geometryChanged=self.appliedGeometry~=geometryKey
    -- 中文维护（2026-10-04）：仅 Windowing 提交/校验自由位置，永不引用原生背包锚点。
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
    -- Only rewrite the label when the sentence actually changed; a native text
    -- write every 350ms is churn, and RU re-asserts window state on some writes.
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
    -- Steady beat: keep the bar above the native bag window, but never over a
    -- hint the user is reading (that was the "it sinks in under a second" bug).
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
-- Build the hidden transient host during module admission. This removes the old
-- first-open race: if the first visible event arrives during a transient native
-- creation failure, later visible heartbeats still retry through Refresh().
P:EnsureCreated()
P:Refresh()
