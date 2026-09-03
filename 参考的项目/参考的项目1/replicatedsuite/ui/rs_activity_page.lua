------------------------------------------------------------------------
-- Replicated Suite - Activity focus page
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S=ReplicatedSuite; S.ActivityPage={}
function S.ActivityPage.Create(parent)
    local page={root=S.UI:CreatePanel(parent,"activity_page",0,0,100,100,"soft"),rows={}}
    if page.root.rsBorder and page.root.rsBorder.SetVisible then page.root.rsBorder:SetVisible(false) end
    if page.root.rsBackground and page.root.rsBackground.SetVisible then page.root.rsBackground:SetVisible(false) end
    page.title=S.UI:CreateLabel(page.root,"activity_title","活动",12,8,300,28,16,nil,ALIGN_LEFT)
    page.note=S.UI:CreateLabel(page.root,"activity_note","活动页只做展示与入口；时间/阶段 Authority 仍由 Event Service 持有。",12,36,680,22,9,"muted",ALIGN_LEFT)
    page.hud=S.UI:CreateButton(page.root,"activity_hud","活动 HUD",12,64,90,27,9,false)
    page.refresh=S.UI:CreateButton(page.root,"activity_refresh","刷新活动",108,64,90,27,9,false)
    page.reminder=S.UI:CreateButton(page.root,"activity_reminder","提醒：关",204,64,110,27,9,false)
    S.UI:SafeHandler(page.hud,"OnClick",function() S.HudManager:ToggleVisible("event"); page:Refresh() end,"activity:hud")
    S.UI:SafeHandler(page.refresh,"OnClick",function() if S.Services and S.Services.Event then S.Services.Event:Refresh(true) end; page:Refresh() end,"activity:refresh")
    S.UI:SafeHandler(page.reminder,"OnClick",function()
        local m=tostring(S.State.settings.eventReminderMode or "off"); S.State.settings.eventReminderMode=(m=="off" and "5" or m=="5" and "15_5" or "off"); S.Storage:RequestSave(); page:Refresh()
    end,"activity:reminder")
    for i=1,15 do
        local name=S.UI:CreateLabel(page.root,"activity_row_name_"..i,"",12,104+(i-1)*28,360,25,10,nil,ALIGN_LEFT)
        local status=S.UI:CreateLabel(page.root,"activity_row_status_"..i,"",380,104+(i-1)*28,230,25,10,"muted",ALIGN_LEFT)
        page.rows[i]={name=name,status=status}
    end
    function page:Refresh()
        self.hud:SetText(S.HudManager:IsVisible("event") and "活动HUD：显" or "活动HUD：隐")
        local m=tostring(S.State.settings.eventReminderMode or "off"); self.reminder:SetText(m=="15_5" and "提醒：15/5/开始" or m=="5" and "提醒：5分/开始" or "提醒：关")
        local data=S.State.data.events or {}
        for i,r in ipairs(self.rows) do local d=data[i]; if d then r.name:SetText(tostring(d.name or d.title or d.label or "活动")); r.status:SetText(tostring(d.timeText or d.status or d.phase or d.meta or "--")); r.name:Show(true); r.status:Show(true) else r.name:Show(false); r.status:Show(false) end end
    end
    function page:ApplyLayout(spec)
        S.UI:SetAnchor(self.root,parent,0,0); self.root:SetExtent(spec.contentWidth,spec.contentHeight)
        local sc=S.Layout:GetContext().addonScale; local pad=12*sc; local full=math.max(1,spec.contentWidth-pad*2)
        self.title:SetExtent(full,28*sc); S.UI:SetAnchor(self.title,self.root,pad,6*sc); self.note:SetExtent(full,22*sc); S.UI:SetAnchor(self.note,self.root,pad,34*sc)
        local x=pad; for _,b in ipairs({self.hud,self.refresh,self.reminder}) do local w=b==self.reminder and 110*sc or 90*sc; b:SetExtent(w,27*sc); S.UI:SetAnchor(b,self.root,x,60*sc); x=x+w+6*sc end
        local top=96*sc; local step=math.max(22*sc,math.min(30*sc,(spec.contentHeight-top-4*sc)/#self.rows)); local nameW=math.max(120*sc,full*0.62); for i,r in ipairs(self.rows) do local y=top+(i-1)*step; r.name:SetExtent(nameW,step-2*sc); S.UI:SetAnchor(r.name,self.root,pad,y); r.status:SetExtent(math.max(1,full-nameW-8*sc),step-2*sc); S.UI:SetAnchor(r.status,self.root,pad+nameW+8*sc,y) end
        self:Refresh()
    end
    S.UI.pages.activity=page; return page
end
