------------------------------------------------------------------------
-- Replicated Suite V3 - Bag Quick Take/Put Overlay
--
-- Presentation-only companion for tools_bag. It follows the native bag window
-- only while a verified bank/coffer window is open. Inventory scans/moves stay
-- inside the Feature and run only after an explicit click.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local feature = S.Features and S.Features.tools_bag or nil
if type(feature) ~= "table" or type(S.UI) ~= "table" then return end
S.UIV3 = S.UIV3 or {}
local P = {
    version=4, ReloadVisibilityContractVersion=2, NativeTransientHostContractVersion=1,
    VisibleRetryContractVersion=1, owner="v3:bag_quick_overlay",
    root=nil, take=nil, put=nil, stop=nil, status=nil, shown=false,
    createAttempts=0, createFailures=0, refreshes=0, visibleRefreshes=0, lastError=nil,
}
S.UIV3.BagQuickOverlay = P

function P:EnsureCreated()
    if self.root ~= nil then return true end
    self.createAttempts=(tonumber(self.createAttempts) or 0)+1
    -- Top-level emptywidgets are not a reliable RU system-layer host. The UI
    -- primitive contract already records the same failure class that once made
    -- Unit Lines have valid projection but zero visible dots. Quick actions are
    -- interactive screen presentation, so use the proven transient WINDOW path
    -- used by Dropdown/ColorField/ContextMenu instead of a root emptywidget.
    local root,err=S.UI:CreatePanel(UIParent,"v3_bag_quick_overlay_root",0,0,220,32,"soft",{
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
    local take=S.UI:CreateButton(root,"v3_bag_quick_take","取",4,4,42,24,10,true,true,self.owner)
    local put=S.UI:CreateButton(root,"v3_bag_quick_put","放",50,4,42,24,10,true,true,self.owner)
    local stop=S.UI:CreateButton(root,"v3_bag_quick_stop","停",96,4,42,24,10,true,true,self.owner)
    local status=S.UI:CreateLabel(root,"v3_bag_quick_status","",142,4,74,24,9,"muted","LEFT",true,self.owner)
    if take==nil or put==nil or stop==nil or status==nil then
        S.UI:SetVisible(root,false,self.owner); if type(S.UI.ReleaseOwner)=="function" then S.UI:ReleaseOwner(self.owner) end
        self.root=nil; self.createFailures=(tonumber(self.createFailures) or 0)+1; self.lastError="bag_quick_overlay_child_failed"
        return false,self.lastError
    end
    self.root,self.take,self.put,self.stop,self.status=root,take,put,stop,status
    local function bind(widget,name,fn)
        if type(S.UI.RequireHandler) ~= "function" then return false, "critical_interaction_contract_unavailable" end
        return S.UI:RequireHandler(widget,"OnClick",function()
            local ok,actionErr=fn(feature.Commands)
            if ok~=true then S.UI:SetText(status,tostring(actionErr or "失败"),P.owner) end
            P:Refresh()
            return ok,actionErr
        end,"v3_bag_quick:"..name)
    end
    local takeBound,takeErr=bind(take,"take",function(c) return c:QuickWithdraw() end)
    local putBound,putErr=bind(put,"put",function(c) return c:QuickDeposit() end)
    local stopBound,stopErr=bind(stop,"stop",function(c) return c:QuickCancel() end)
    local tooltip=S.RSUI and S.RSUI.Tooltip or nil
    if type(tooltip)=="table" and type(tooltip.Bind)=="function" then
        tooltip:Bind(take,{ text="取：从当前打开的银行/箱子连续取出与当前选中物品同类的堆叠。", allowRaw=true, cursorFollow=true, maxWidth=360 })
        tooltip:Bind(put,{ text="放：把背包中的同类物品连续存入当前银行/箱子；仓库没有空格时仍会尝试已有的未满堆叠。", allowRaw=true, cursorFollow=true, maxWidth=390 })
        tooltip:Bind(stop,{ text="停：立即停止当前批量取出/存入队列。", allowRaw=true, cursorFollow=true, maxWidth=320 })
    end
    if takeBound~=true or putBound~=true or stopBound~=true then
        S.UI:SetVisible(root,false,self.owner); if type(S.UI.ReleaseOwner)=="function" then S.UI:ReleaseOwner(self.owner) end
        self.root,self.take,self.put,self.stop,self.status=nil,nil,nil,nil,nil
        self.createFailures=(tonumber(self.createFailures) or 0)+1
        self.lastError=tostring(takeErr or putErr or stopErr or "bag_quick_required_handler_failed")
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
    if overlay.visible~=true then if self.root~=nil then S.UI:SetVisible(self.root,false,self.owner) end; self.shown=false; return true end
    self.visibleRefreshes=(tonumber(self.visibleRefreshes) or 0)+1
    local ok,err=self:EnsureCreated(); if ok~=true then self.lastError=tostring(err or "bag_quick_overlay_create_failed"); return false,err end
    local x,y=tonumber(overlay.x) or 0,tonumber(overlay.y) or 0
    local width=math.max(190,math.min(300,tonumber(overlay.width) or 220))
    S.UI:SetAnchor(self.root,UIParent,math.floor(x),math.floor(y),self.owner)
    S.UI:SetExtent(self.root,width,32,self.owner)
    S.UI:SetAnchor(self.status,self.root,142,4,self.owner); S.UI:SetExtent(self.status,math.max(44,width-146),24,self.owner)
    local storage=overlay.storageKind=="coffer" and "箱子" or "银行"
    local statusText=tostring(overlay.status or "可快捷取放")
    if tonumber(overlay.moved or 0)>0 then statusText=statusText.." "..tostring(overlay.moved) end
    S.UI:SetText(self.status,storage.." · "..statusText,self.owner)
    S.UI:SetVisible(self.root,true,self.owner); self.shown=true; S.UI:TrySetUILayer(self.root,"system")
    if type(self.root.Raise)=="function" then pcall(function() self.root:Raise() end) end
    return true
end


function P:GetHealth()
    return {
        version=tonumber(self.version) or 0, created=self.root~=nil, visible=self.shown==true,
        createAttempts=tonumber(self.createAttempts) or 0, createFailures=tonumber(self.createFailures) or 0,
        refreshes=tonumber(self.refreshes) or 0, visibleRefreshes=tonumber(self.visibleRefreshes) or 0, lastError=self.lastError,
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
