------------------------------------------------------------------------
-- Replicated Suite - Smart Fishing floating widget
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S=ReplicatedSuite; S.FishingWidget={}
function S.FishingWidget.Create()
    local widget=S.WidgetBase:Create("fishing","智能钓鱼",S.Constants.Widget.fishing)
    local win=widget.window
    local status=S.UI:CreateLabel(win,"fishing_status","选中鱼后等待状态",12,0,330,25,12,"yellow",ALIGN_LEFT)
    local recommend=S.UI:CreateLabel(win,"fishing_recommend","推荐：--",12,0,200,32,17,"blue",ALIGN_LEFT)
    local auto=S.UI:CreateButton(win,"fishing_auto","自动R：关",0,0,104,28,9,false)
    local hint=S.UI:CreateLabel(win,"fishing_hint","自动R会临时改键；切换动作和关闭窗口都会恢复原按键。读不到原键则拒绝修改。",12,0,330,34,8,"muted",ALIGN_LEFT)
    local mini=S.UI:CreateLabel(win,"fishing_mini","钓鱼 --",8,4,250,22,10,"blue",ALIGN_LEFT); mini:Show(false)
    S.UI:SafeHandler(auto,"OnClick",function() local svc=S.Services and S.Services.Fishing; if svc then svc:ToggleAuto(); widget:Refresh() end end,"fishing:auto")
    local originalSetVisible=widget.SetVisible
    function widget:SetVisible(visible)
        if visible~=true then local svc=S.Services and S.Services.Fishing; if svc and svc.autoArmed then svc:DisarmAuto(true) end end
        originalSetVisible(self,visible)
    end
    function widget:Refresh()
        local d=S.State.data.fishing or {}; local slot=tonumber(d.slot)
        status:SetText(tostring(d.message or "等待目标"))
        recommend:SetText(slot and ("推荐：R / 技能栏 "..tostring(slot)) or "推荐：--")
        auto:SetText(d.auto==true and "自动R：开" or "自动R：关")
        mini:SetText(slot and ((d.auto==true and "自动R" or "推荐").." · 槽"..tostring(slot)) or "钓鱼 · 等待")
    end
    widget.OnLayout=function(self,width,height,titleHeight,mode)
        local scale=S.Layout:GetContext().addonScale; local standard=mode=="standard"; local miniMode=mode=="mini"
        mini:Show(miniMode); for _,c in ipairs({status,recommend,auto,hint}) do c:Show(standard) end
        if miniMode then mini:SetExtent(width-16*scale,math.max(18*scale,height-titleHeight-8*scale)); S.UI:SetAnchor(mini,win,8*scale,titleHeight+3*scale) end
        if standard then
            local y=titleHeight+10*scale; status:SetExtent(width-24*scale,26*scale); S.UI:SetAnchor(status,win,12*scale,y)
            y=y+34*scale; recommend:SetExtent(width-140*scale,32*scale); S.UI:SetAnchor(recommend,win,12*scale,y)
            auto:SetExtent(104*scale,28*scale); S.UI:SetAnchor(auto,win,width-116*scale,y)
            hint:SetExtent(width-24*scale,38*scale); S.UI:SetAnchor(hint,win,12*scale,height-47*scale)
        end
        self:Refresh()
    end
    widget:ApplyLayout(false); return widget
end
