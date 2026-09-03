------------------------------------------------------------------------
-- Replicated Suite - Quick actions
-- Keep only genuinely quick actions here. Full feature configuration belongs
-- to first-level pages such as 团队辅助 / 伤害统计 / 治疗辅助 / 一键换装.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S=ReplicatedSuite; S.QuickPage={}

function S.QuickPage.Create(parent)
    local page={key="quick",root=S.UI:CreatePanel(parent,"quick_page",0,0,100,100,"soft"),widgetRows={},favoriteCursor=1}
    if page.root.rsBorder and page.root.rsBorder.SetVisible then page.root.rsBorder:SetVisible(false) end
    if page.root.rsBackground and page.root.rsBackground.SetVisible then page.root.rsBackground:SetVisible(false) end

    page.title=S.UI:CreateLabel(page.root,"quick_title","快捷",12,12,280,28,16,nil,ALIGN_LEFT)
    page.note=S.UI:CreateLabel(page.root,"quick_note","这里只保留常用入口和悬浮窗快速控制；团队辅助等完整功能已移到左侧一级选项卡。",12,43,700,24,10,"muted",ALIGN_LEFT)

    page.favoriteTitle=S.UI:CreateLabel(page.root,"quick_favorite_title","我的常用",12,70,160,22,13,nil,ALIGN_LEFT)
    page.pageFavorites={}
    local pageDefs={{"dps","伤害"},{"healer","治疗"},{"gear","换装"},{"plates","BUFF"},{"hud","HUD"},{"settings","设置"},{"diagnostics","诊断"}}
    for i,d in ipairs(pageDefs) do
        local b=S.UI:CreateButton(page.root,"quick_page_favorite_"..d[1],"[收]"..d[2],12,96,66,25,8,false)
        page.pageFavorites[i]={key=d[1],base=d[2],button=b}
        S.UI:SafeHandler(b,"OnClick",function() if S.Favorites then S.Favorites:Toggle("page:"..d[1]) end; page:Refresh() end,"quick:page_favorite:"..d[1])
    end

    page.favoriteCurrent=S.UI:CreateButton(page.root,"quick_favorite_current","常用：无",12,126,194,25,8,false)
    page.favoriteUp=S.UI:CreateButton(page.root,"quick_favorite_up","上移",212,126,48,25,8,false)
    page.favoriteDown=S.UI:CreateButton(page.root,"quick_favorite_down","下移",264,126,48,25,8,false)
    page.favoriteRemove=S.UI:CreateButton(page.root,"quick_favorite_remove","移除",316,126,48,25,8,false)
    local function CurrentFavorite()
        local list=S.Favorites and S.Favorites:List() or {}
        if #list==0 then page.favoriteCursor=1; return nil,nil,list end
        page.favoriteCursor=math.max(1,math.min(#list,tonumber(page.favoriteCursor) or 1))
        return list[page.favoriteCursor] and list[page.favoriteCursor].id or nil,list[page.favoriteCursor],list
    end
    S.UI:SafeHandler(page.favoriteCurrent,"OnClick",function()
        local _,_,list=CurrentFavorite(); if #list==0 then return end
        page.favoriteCursor=(page.favoriteCursor % #list)+1; page:Refresh()
    end,"quick:favorite_cycle")
    S.UI:SafeHandler(page.favoriteUp,"OnClick",function()
        local id=CurrentFavorite(); if id and S.Favorites then S.Favorites:Move(id,-1); page.favoriteCursor=math.max(1,page.favoriteCursor-1) end; page:Refresh()
    end,"quick:favorite_up")
    S.UI:SafeHandler(page.favoriteDown,"OnClick",function()
        local id,_,list=CurrentFavorite(); if id and S.Favorites then S.Favorites:Move(id,1); page.favoriteCursor=math.min(#list,page.favoriteCursor+1) end; page:Refresh()
    end,"quick:favorite_down")
    S.UI:SafeHandler(page.favoriteRemove,"OnClick",function()
        local id=CurrentFavorite(); if id and S.Favorites then S.Favorites:Remove(id) end; page:Refresh()
    end,"quick:favorite_remove")

    -- P2: personal-portal quick toggle. One click flips OIT_AUTO_USE_ONLY_MY_PORTAL
    -- and the button colour reflects the current value (green = all portals,
    -- red = own portals only). Value is read once when the page refreshes --
    -- never polled. Runs behind the capability boundary; on clients where the
    -- option API is unavailable the button stays disabled (safe fallback).
    page.portalTitle=S.UI:CreateLabel(page.root,"quick_portal_title","传送门",12,160,120,22,13,nil,ALIGN_LEFT)
    page.portalButton=S.UI:CreateButton(page.root,"quick_portal_toggle","全部可见",130,160,120,25,9,false)
    page.portalHint=S.UI:CreateLabel(page.root,"quick_portal_hint","点一下切换“仅自己可见”；绿=全部、红=仅自己",12,183,600,20,9,"muted",ALIGN_LEFT)
    local function ReadPortalOption()
        if S.Api == nil or S.Api:IsCapabilityAllowed("X2Option:GetOptionItemValue") ~= true then return nil end
        local ok, value = S.Api:CallCapability("X2Option:GetOptionItemValue", X2Option, "GetOptionItemValue", OIT_AUTO_USE_ONLY_MY_PORTAL)
        if ok ~= true then return nil end
        return tonumber(value)
    end
    local function PortalToggleColour(button, ownOnly)
        if button.rsButtonBgs and button.rsButtonBgs[1] then
            pcall(function() button.rsButtonBgs[1]:SetColor(ownOnly and 0.42 or 0.10, ownOnly and 0.10 or 0.42, ownOnly and 0.10 or 0.16, 0.97) end)
        end
    end
    S.UI:SafeHandler(page.portalButton,"OnClick",function()
        if S.Api == nil or S.Api:IsCapabilityAllowed("X2Option:SetItemFloatValue") ~= true then
            S.SafeChat("传送门选项 API 当前不可用"); return
        end
        local current = ReadPortalOption()
        local nextValue = (current == 1) and 0 or 1
        local ok = S.Api:ActionCapability("X2Option:SetItemFloatValue", X2Option, "SetItemFloatValue", OIT_AUTO_USE_ONLY_MY_PORTAL, nextValue)
        if ok ~= true then
            S.SafeChat("传送门选项切换失败，请稍后重试"); return
        end
        S.SafeChat(nextValue == 1 and "传送门：仅自己可见" or "传送门：全部可见")
        page:Refresh()
    end,"quick:portal_toggle")

    page.hudTitle=S.UI:CreateLabel(page.root,"quick_hud_title","悬浮窗快速控制",12,168,200,22,13,nil,ALIGN_LEFT)
    page.hudHint=S.UI:CreateLabel(page.root,"quick_hud_hint","这里只控制显示/隐藏与鼠标穿透；完整尺寸、透明度和布局请到 HUD 页。",12,192,600,20,9,"muted",ALIGN_LEFT)
    local defs={{"task","任务追踪"},{"trade","跑商货率"},{"bond","债券居民板"},{"event","活动倒计时"},{"treasure","寻宝助手"},{"fishing","智能钓鱼"}}
    for i,d in ipairs(defs) do
        local panel=S.UI:CreatePanel(page.root,"quick_card_"..d[1],0,0,100,42,"card")
        local label=S.UI:CreateLabel(page.root,"quick_label_"..d[1],d[2],12,220,150,26,11,nil,ALIGN_LEFT)
        local toggle=S.UI:CreateButton(page.root,"quick_toggle_"..d[1],"显示",170,220,72,27,9,false)
        local pass=S.UI:CreateButton(page.root,"quick_pass_"..d[1],"穿透：关",250,220,88,27,9,false)
        page.widgetRows[i]={key=d[1],panel=panel,label=label,toggle=toggle,pass=pass}
        S.UI:SafeHandler(toggle,"OnClick",function() S.UI:ToggleWidget(d[1]); page:Refresh() end,"quick:toggle:"..d[1])
        S.UI:SafeHandler(pass,"OnClick",function()
            local place=S.State.ui.widgets[d[1]]
            place.clickThrough=not place.clickThrough
            local w=S.UI.widgets[d[1]]
            if w and w.SetClickThrough then w:SetClickThrough(place.clickThrough) end
            S.Storage:RequestSave(); page:Refresh()
        end,"quick:pass:"..d[1])
    end

    function page:Refresh()
        for _,item in ipairs(self.pageFavorites or {}) do
            item.button:SetText((S.Favorites and S.Favorites:IsFavorite("page:"..item.key)) and ("[已]"..item.base) or ("[收]"..item.base))
        end
        local _,favorite,list=CurrentFavorite()
        if favorite then self.favoriteCurrent:SetText("常用 "..tostring(self.favoriteCursor).."/"..tostring(#list).."｜"..tostring(favorite.title))
        else self.favoriteCurrent:SetText("常用：无") end
        if self.favoriteCurrent.Enable then self.favoriteCurrent:Enable(favorite~=nil) end
        self.favoriteUp:Enable(favorite~=nil and self.favoriteCursor>1)
        self.favoriteDown:Enable(favorite~=nil and self.favoriteCursor<#list)
        self.favoriteRemove:Enable(favorite~=nil)

        for _,r in ipairs(self.widgetRows) do
            local place=S.State.ui.widgets[r.key]
            local w=S.UI.widgets[r.key]
            local shown=w and w.window and w.window:IsVisible()
            r.toggle:SetText(shown and "隐藏" or "显示")
            r.pass:SetText(place.clickThrough and "穿透：开" or "穿透：关")
        end
        local portalValue = ReadPortalOption()
        local ownOnly = portalValue == 1
        if self.portalButton then
            self.portalButton:SetText(ownOnly and "仅自己可见" or "全部可见")
            PortalToggleColour(self.portalButton, ownOnly)
            if self.portalButton.Enable then self.portalButton:Enable(portalValue ~= nil) end
        end
    end

    function page:ApplyLayout(spec)
        S.UI:SetAnchor(self.root,parent,0,0); self.root:SetExtent(spec.contentWidth,spec.contentHeight)
        local sc=S.Layout:GetContext().addonScale
        local pad=12*sc
        local full=math.max(1,spec.contentWidth-pad*2)
        self.title:SetExtent(full,27*sc); S.UI:SetAnchor(self.title,self.root,pad,7*sc)
        self.note:SetExtent(full,22*sc); S.UI:SetAnchor(self.note,self.root,pad,36*sc)

        self.favoriteTitle:SetExtent(full,22*sc); S.UI:SetAnchor(self.favoriteTitle,self.root,pad,67*sc)
        local favGap=5*sc
        local favCols=math.max(2,math.min(7,math.floor((full+favGap)/(66*sc+favGap))))
        local favW=math.max(1,(full-favGap*(favCols-1))/favCols)
        local favY=94*sc
        for i,item in ipairs(self.pageFavorites) do
            local col=(i-1)%favCols; local row=math.floor((i-1)/favCols)
            item.button:SetExtent(favW,24*sc); S.UI:SetAnchor(item.button,self.root,pad+col*(favW+favGap),favY+row*28*sc)
        end
        local favRows=math.max(1,math.ceil(#self.pageFavorites/favCols))
        local manageY=favY+favRows*28*sc+4*sc
        local smallW=48*sc; local gap=5*sc
        local currentW=math.max(90*sc,full-smallW*3-gap*3)
        self.favoriteCurrent:SetExtent(currentW,24*sc); S.UI:SetAnchor(self.favoriteCurrent,self.root,pad,manageY)
        local fx=pad+currentW+gap
        for _,b in ipairs({self.favoriteUp,self.favoriteDown,self.favoriteRemove}) do b:SetExtent(smallW,24*sc); S.UI:SetAnchor(b,self.root,fx,manageY); fx=fx+smallW+gap end

        local hudTitleY=manageY+58*sc
        self.portalTitle:SetExtent(full,22*sc); S.UI:SetAnchor(self.portalTitle,self.root,pad,hudTitleY-22*sc)
        self.portalButton:SetExtent(120*sc,25*sc); S.UI:SetAnchor(self.portalButton,self.root,pad+120*sc,hudTitleY-25*sc)
        self.portalHint:SetExtent(full,20*sc); S.UI:SetAnchor(self.portalHint,self.root,pad,hudTitleY+1*sc)
        self.hudTitle:SetExtent(full,22*sc); S.UI:SetAnchor(self.hudTitle,self.root,pad,hudTitleY+24*sc)
        self.hudHint:SetExtent(full,20*sc); S.UI:SetAnchor(self.hudHint,self.root,pad,hudTitleY+48*sc)
        local y=hudTitleY+74*sc
        local cardGap=7*sc
        local twoCols=full>=500*sc
        local cols=twoCols and 2 or 1
        local cardW=(full-cardGap*(cols-1))/cols
        local cardH=43*sc
        for i,r in ipairs(self.widgetRows) do
            local col=(i-1)%cols; local row=math.floor((i-1)/cols)
            local x=pad+col*(cardW+cardGap); local yy=y+row*(cardH+cardGap)
            r.panel:SetExtent(cardW,cardH); S.UI:SetAnchor(r.panel,self.root,x,yy)
            local toggleW=58*sc; local passW=80*sc; local igap=5*sc
            local labelW=math.max(72*sc,cardW-toggleW-passW-igap*2-16*sc)
            r.label:SetExtent(labelW,24*sc); S.UI:SetAnchor(r.label,self.root,x+8*sc,yy+9*sc)
            r.toggle:SetExtent(toggleW,25*sc); S.UI:SetAnchor(r.toggle,self.root,x+cardW-passW-toggleW-igap-8*sc,yy+9*sc)
            r.pass:SetExtent(passW,25*sc); S.UI:SetAnchor(r.pass,self.root,x+cardW-passW-8*sc,yy+9*sc)
        end
        self:Refresh()
    end

    S.UI.pages.quick=page
    return page
end
