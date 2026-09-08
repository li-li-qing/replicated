 ------------------------------------------------------------------------
 -- Replicated Suite V3 - Bag Quick Take/Put Overlay
 --
 -- Presentation-only companion for tools_bag. It follows the native bag window
 -- only while a verified bank/coffer window is open. Inventory scans/moves stay
 -- inside the Feature and run only after an explicit click.
 --
 -- Two buttons only (user report, .18.183): the third 停 button never had a
 -- visible effect, while the refusal it existed for ("已经在运行，请先停止") is
 -- what made a 取/放 click look dead. Cancellation is now carried by the same
 -- two buttons through the Feature's start/stop/switch contract, and the
 -- Feature self-heals a queue that lost its executor.
 ------------------------------------------------------------------------
 if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
 local S = ReplicatedSuite
 local feature = S.Features and S.Features.tools_bag or nil
 if type(feature) ~= "table" or type(S.UI) ~= "table" then return end
 S.UIV3 = S.UIV3 or {}
 local P = {
     version=8, ReloadVisibilityContractVersion=2, NativeTransientHostContractVersion=2,
     VisibleRetryContractVersion=2, TooltipLayerContractVersion=1, TwoButtonContractVersion=1,
     -- v8: the bar is *two buttons*. The label is empty by default and only
     -- carries a transient message (run in progress / why a click refused), then
     -- clears itself and the bar shrinks back. An always-on "银行 · 可快捷取放"
     -- sentence is noise on a game overlay (user report: 简单方便最重要).
     QuietByDefaultContractVersion=1,
     -- v7: the 350 ms heartbeat used to rewrite geometry/text and Raise the bar
     -- on every beat. Raising a periodic surface over a transient hint buries the
     -- hint within a second (RU report) and breaks the diff-rendering rule, so
     -- writes are now diffed and the keep-on-top raise yields to an open hint.
     DiffRenderContractVersion=1, HintYieldContractVersion=1,
     owner="v3:bag_quick_overlay",
     root=nil, take=nil, put=nil, status=nil, shown=false,
     createAttempts=0, createFailures=0, refreshes=0, visibleRefreshes=0, lastError=nil,
     appliedGeometry=nil, appliedStatus=nil,
 }
 S.UIV3.BagQuickOverlay = P
 -- Widths: the two buttons end at 98 px.  The label starts at 104 px and is only
 -- visible while there is something the user has to read; with nothing to say the
 -- bar shrinks to COMPACT_WIDTH so it is literally just 取 / 放.
 local TAKE_X, TAKE_W = 4, 46
 local PUT_X, PUT_W = 52, 46
 local STATUS_X = 104
 local COMPACT_WIDTH = 102
 local MIN_WIDTH, MAX_WIDTH = 240, 320
 -- A refusal/stop message stays readable long enough to be read once, then the
 -- bar returns to its quiet form.  Expiry is evaluated on the beats the existing
 -- 350 ms observer already publishes: no new task, no Tick.
 local MESSAGE_TTL_MS = 6000

-- A failed host build during a visible transition must not wait for the next
-- 350 ms storage heartbeat to retry: RU can reject the first transient-window
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
    return status
end

function P:EnsureCreated()
    if self.root ~= nil then return true end
    self.createAttempts=(tonumber(self.createAttempts) or 0)+1
    -- Top-level emptywidgets are not a reliable RU system-layer host. The UI
    -- primitive contract already records the same failure class that once made
    -- Unit Lines have valid projection but zero visible dots. Quick actions are
    -- interactive screen presentation, so use the proven transient WINDOW path
    -- used by Dropdown/ColorField/ContextMenu instead of a root emptywidget.
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
    -- Two buttons only.  停 was reported as useless: a stop is now the same
    -- button pressed again, and the decision lives in tools_bag (the business
    -- Authority), not in the presentation layer.
    local take=S.UI:CreateButton(root,"v3_bag_quick_take","取",TAKE_X,4,TAKE_W,24,10,true,true,self.owner)
    local put=S.UI:CreateButton(root,"v3_bag_quick_put","放",PUT_X,4,PUT_W,24,10,true,true,self.owner)
    local status=S.UI:CreateLabel(root,"v3_bag_quick_status","",STATUS_X,4,MIN_WIDTH-STATUS_X-4,24,9,"muted","LEFT",true,self.owner)
    if take==nil or put==nil or status==nil then
        S.UI:SetVisible(root,false,self.owner); if type(S.UI.ReleaseOwner)=="function" then S.UI:ReleaseOwner(self.owner) end
        self.root=nil; self.createFailures=(tonumber(self.createFailures) or 0)+1; self.lastError="bag_quick_overlay_child_failed"
        return false,self.lastError
    end
    self.root,self.take,self.put,self.status=root,take,put,status
    local function bind(widget,name,fn)
        if type(S.UI.RequireHandler) ~= "function" then return false, "critical_interaction_contract_unavailable" end
        return S.UI:RequireHandler(widget,"OnClick",function()
            local ok,actionErr=fn(feature.Commands)
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
    end
    if takeBound~=true or putBound~=true then
        S.UI:SetVisible(root,false,self.owner); if type(S.UI.ReleaseOwner)=="function" then S.UI:ReleaseOwner(self.owner) end
        self.root,self.take,self.put,self.status=nil,nil,nil,nil
        self.createFailures=(tonumber(self.createFailures) or 0)+1
        self.lastError=tostring(takeErr or putErr or "bag_quick_required_handler_failed")
        return false,self.lastError
    end
    S.UI:SetVisible(root,false,self.owner)
    self.lastError=nil
    return true
end

function P:Refresh()
    self.refreshes=(tonumber(self.refreshes) or 0)+1
    local projection=feature:GetProjection() or {}
    local overlay=type(projection.quickOverlay)=="table" and projection.quickOverlay or {}
    if overlay.visible~=true then
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
    local x,y=tonumber(overlay.x) or 0,tonumber(overlay.y) or 0
    local now=type(S.NowMs)=="function" and tonumber(S.NowMs()) or 0
    local statusText=OverlayStatusText(overlay,now)
    -- Nothing to say -> buttons only.  Something to say -> grow the bar, but
    -- never below the width that fits the message.
    local width=statusText=="" and COMPACT_WIDTH
        or math.max(MIN_WIDTH,math.min(MAX_WIDTH,tonumber(overlay.width) or MIN_WIDTH))
    local geometryKey=tostring(math.floor(x))..":"..tostring(math.floor(y))..":"..tostring(width)
    local firstShow=self.shown~=true
    local geometryChanged=self.appliedGeometry~=geometryKey
    if geometryChanged or firstShow then
        S.UI:SetAnchor(self.root,UIParent,math.floor(x),math.floor(y),self.owner)
        S.UI:SetExtent(self.root,width,32,self.owner)
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
        S.UI:SetVisible(self.root,true,self.owner)
        self.shown=true
        S.UI:TrySetUILayer(self.root,"system")
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
        version=tonumber(self.version) or 0, buttons=2, labelVisible=self.appliedStatus~=nil and self.appliedStatus~="",
        created=self.root~=nil, visible=self.shown==true,
        createAttempts=tonumber(self.createAttempts) or 0, createFailures=tonumber(self.createFailures) or 0,
        refreshes=tonumber(self.refreshes) or 0, visibleRefreshes=tonumber(self.visibleRefreshes) or 0,
        retryScheduled=self.retryScheduled==true, retryCount=tonumber(self.retryCount) or 0, lastError=self.lastError,
    }
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
