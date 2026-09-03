------------------------------------------------------------------------
-- Replicated Suite - Floating entry button
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S=ReplicatedSuite; S.MainButton={}; local B=S.MainButton
function B.Create()
    -- Adopt the bootstrap recovery button when available.  This guarantees that
    -- the same visible R survives the entire toc load and is only upgraded here
    -- after State/Layout/Theme are ready.
    local button=S.RecoveryEntry
    if button==nil then button=UIParent:CreateWidget("button",S.PhysicalId("entry"),"UIParent","") end
    button:SetText("R")
    -- The Suite entry is a persistent HUD control, not a modal window. Keep it
    -- on normal z-order so native game windows can cover it.
    if button.Enable then button:Enable(true) end; if button.Clickable then button:Clickable(true) end; if button.EnableDrag then button:EnableDrag(true) end
    S.Theme:StyleButton(button,42,42,18,true,true); S.UI.controls.entry=button; S.RecoveryEntry=button
    local badge=S.UI:CreateLabel(button,"entry_badge","",28,-5,22,20,10,"orange",ALIGN_CENTER)
    local tooltip=S.UI:CreatePanel("UIParent","entry_tooltip",0,0,190,112,"card")
    S.UI:CreateLabel(tooltip,"entry_tip_title","生活摘要",8,6,165,18,11,nil,ALIGN_LEFT)
    local lines={}
    for i=1,4 do lines[i]=S.UI:CreateLabel(tooltip,"entry_tip_"..i,"",10,26+(i-1)*19,165,18,10,"muted",ALIGN_LEFT) end
    tooltip:Show(false); S.UI.controls.entryTooltip=tooltip; B.button=button; B.badge=badge; B.tooltip=tooltip; B.tooltipLines=lines
    S.UI:SafeHandler(button,"OnDragStart",function()
        if S.State.settings.entryLocked then return false end
        button.rsMoving=true
        button.rsSafeMoving=S.Layout~=nil and type(S.Layout.BeginSafeMove)=="function"
            and S.Layout:BeginSafeMove("entry",button,{clamp=true})==true
        if button.rsSafeMoving~=true then
            if type(button.StartMoving)~="function" then button.rsMoving=false; return false end
            button:StartMoving()
        end
        return true
    end,"entry:drag_start")
    S.UI:SafeHandler(button,"OnDragStop",function()
        if button.rsSafeMoving==true and S.Layout~=nil and type(S.Layout.EndSafeMove)=="function" then
            S.Layout:EndSafeMove("entry",false)
        elseif type(button.StopMovingOrSizing)=="function" then
            button:StopMovingOrSizing()
        end
        button.rsSafeMoving=false; button.rsMoving=false; button.rsIgnoreClick=true
        S.Layout:SnapAndStore(S.State.ui.entry,button); S.Storage:RequestSave(); B:ApplyLayout(false); return true
    end,"entry:drag_stop")
    S.UI:SafeHandler(button,"OnClick",function() if button.rsIgnoreClick then button.rsIgnoreClick=false; return end; S.UI:ToggleMain() end,"entry:click")
    S.UI:SafeHandler(button,"OnEnter",function() B:PositionTooltip(); B:RefreshData(); tooltip:Show(true); if tooltip.Raise then tooltip:Raise() end end,"entry:enter")
    S.UI:SafeHandler(button,"OnLeave",function() tooltip:Show(false) end,"entry:leave")
    function B:RefreshData()
        local s=S.State.data.summary or {}; local count=(tonumber(s.unfinished) or 0)+(tonumber(s.turnIn) or 0)
        badge:SetText(count>0 and tostring(count) or "OK"); S.Theme:SetLabelTone(badge,count>0 and "orange" or "green")
        local values={{"未完成",s.unfinished or 0,"muted"},{"可交付",s.turnIn or 0,"orange"},{"活动",s.nextEvent or "--","blue"},{"债券",s.bonds~=nil and s.bonds or "--","blue"}}
        for i,v in ipairs(values) do lines[i]:SetText(string.format("%-8s  %s",v[1],tostring(v[2]))); S.Theme:SetLabelTone(lines[i],v[3]) end
    end
    function B:PositionTooltip()
        local c=S.Layout:GetContext(); local x,y,w=S.Layout:GetLogicalRect(button); local tw,th=190*c.addonScale,112*c.addonScale; local tx=x+w+8*c.addonScale; if tx+tw>c.logicalWidth-c.safeRight then tx=x-tw-8*c.addonScale end; local ty=y; tx,ty=S.Layout:ClampTopLeft(tx,ty,tw,th,{edge=c.safeLeft}); tooltip:RemoveAllAnchors(); tooltip:AddAnchor("TOPLEFT","UIParent",tx,ty); tooltip:SetExtent(tw,th)
    end
    function B:ApplyLayout()
        local c=S.Layout:GetContext()
        local size=math.max(S.Constants.Layout.entryMinHitSize,S.Constants.Layout.entryBaseSize*c.addonScale)
        S.Layout:ApplyPlacement(button,S.State.ui.entry,size,size,300,100)
        S.Theme:StyleButton(button,size,size,math.max(13,18*c.addonScale),true,true)
        badge:SetExtent(22*c.addonScale,20*c.addonScale)
        S.UI:SetAnchor(badge,button,size-14*c.addonScale,-5*c.addonScale)
        self:PositionTooltip()
        -- This is the Suite's canonical recovery entry. Never let a stale
        -- persisted showEntry=false strand the user without a way back in.
        S.State.settings.showEntry = true
        button:Show(true)
    end
    B:RefreshData(); B:ApplyLayout()
    if S.Layout~=nil and type(S.Layout.RegisterFloating)=="function" then
        S.Layout:RegisterFloating("suite_entry",button,{
            onlyWhenVisible=true,
            onMetricsChanged=function() B:ApplyLayout(true) end,
        })
    end
    return button
end
