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
local P = { version=1, owner="v3:bag_quick_overlay", root=nil, take=nil, put=nil, stop=nil, status=nil }
S.UIV3.BagQuickOverlay = P

function P:EnsureCreated()
    if self.root ~= nil then return true end
    local root,err=S.UI:CreateEmptyWidget(UIParent,"v3_bag_quick_overlay_root",0,0,220,32,false,self.owner)
    if root==nil then return false,err or "bag_quick_overlay_root_failed" end
    local take=S.UI:CreateButton(root,"v3_bag_quick_take","取",4,4,42,24,10,true,true,self.owner)
    local put=S.UI:CreateButton(root,"v3_bag_quick_put","放",50,4,42,24,10,true,true,self.owner)
    local stop=S.UI:CreateButton(root,"v3_bag_quick_stop","停",96,4,42,24,10,true,true,self.owner)
    local status=S.UI:CreateLabel(root,"v3_bag_quick_status","",142,4,74,24,9,"muted","LEFT",true,self.owner)
    if take==nil or put==nil or stop==nil or status==nil then
        S.UI:SetVisible(root,false,self.owner); if type(S.UI.ReleaseOwner)=="function" then S.UI:ReleaseOwner(self.owner) end
        self.root=nil; return false,"bag_quick_overlay_child_failed"
    end
    self.root,self.take,self.put,self.stop,self.status=root,take,put,stop,status
    local function bind(widget,name,fn)
        S.UI:SafeHandler(widget,"OnClick",function()
            local ok,actionErr=fn(feature.Commands)
            if ok~=true then S.UI:SetText(status,tostring(actionErr or "失败"),P.owner) end
            P:Refresh()
            return ok,actionErr
        end,"v3_bag_quick:"..name)
    end
    bind(take,"take",function(c) return c:QuickWithdraw() end)
    bind(put,"put",function(c) return c:QuickDeposit() end)
    bind(stop,"stop",function(c) return c:QuickCancel() end)
    S.UI:SetVisible(root,false,self.owner)
    return true
end

function P:Refresh()
    local projection=feature:GetProjection() or {}
    local overlay=type(projection.quickOverlay)=="table" and projection.quickOverlay or {}
    if overlay.visible~=true then if self.root~=nil then S.UI:SetVisible(self.root,false,self.owner) end; return true end
    local ok,err=self:EnsureCreated(); if ok~=true then return false,err end
    local x,y=tonumber(overlay.x) or 0,tonumber(overlay.y) or 0
    local width=math.max(190,math.min(300,tonumber(overlay.width) or 220))
    S.UI:SetAnchor(self.root,UIParent,math.floor(x),math.floor(y),self.owner)
    S.UI:SetExtent(self.root,width,32,self.owner)
    S.UI:SetAnchor(self.status,self.root,142,4,self.owner); S.UI:SetExtent(self.status,math.max(44,width-146),24,self.owner)
    local storage=overlay.storageKind=="coffer" and "箱子" or "银行"
    local statusText=tostring(overlay.status or "可快捷取放")
    if tonumber(overlay.moved or 0)>0 then statusText=statusText.." "..tostring(overlay.moved) end
    S.UI:SetText(self.status,storage.." · "..statusText,self.owner)
    S.UI:SetVisible(self.root,true,self.owner); S.UI:TrySetUILayer(self.root,"system")
    if type(self.root.Raise)=="function" then pcall(function() self.root:Raise() end) end
    return true
end

if S.Events ~= nil and type(S.Events.SubscribeInternal)=="function" then
    S.Events:SubscribeInternal(feature.UpdateTopic,P,function() return P:Refresh() end)
    S.Events:SubscribeInternal("v3.feature.lifecycle",P,function(_,featureId)
        if tostring(featureId or "")=="tools_bag" then return P:Refresh() end
    end)
end
P:Refresh()
