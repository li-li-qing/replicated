------------------------------------------------------------------------
-- Replicated Suite - Utility tools
--
-- Context tools only. Navigation favorites and HUD controls were removed from
-- this page because the left rail and HUD Manager already own those concerns.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
S.QuickPage = {}

local function ReadPortalOption()
    if S.Api == nil or S.Api:IsCapabilityAllowed("X2Option:GetOptionItemValue") ~= true then return nil end
    local ok, value = S.Api:CallCapability("X2Option:GetOptionItemValue", X2Option, "GetOptionItemValue", OIT_AUTO_USE_ONLY_MY_PORTAL)
    if ok ~= true then return nil end
    return tonumber(value)
end

local function SetPortalButtonColour(button, ownOnly)
    if button and button.rsButtonBgs and button.rsButtonBgs[1] then
        pcall(function()
            button.rsButtonBgs[1]:SetColor(ownOnly and 0.42 or 0.10, ownOnly and 0.10 or 0.42, ownOnly and 0.10 or 0.16, 0.97)
        end)
    end
end

local function CraftSettings()
    S.State.settings.craftAssist = type(S.State.settings.craftAssist) == "table" and S.State.settings.craftAssist or {}
    return S.State.settings.craftAssist
end

function S.QuickPage.Create(parent)
    local page = { key="quick", root=S.UI:CreatePanel(parent,"quick_page",0,0,100,100,"soft") }
    if page.root.rsBorder and page.root.rsBorder.SetVisible then page.root.rsBorder:SetVisible(false) end
    if page.root.rsBackground and page.root.rsBackground.SetVisible then page.root.rsBackground:SetVisible(false) end

    page.title = S.UI:CreateLabel(page.root,"quick_title","实用工具",12,10,320,28,16,nil,ALIGN_LEFT)
    page.note = S.UI:CreateLabel(page.root,"quick_note","这里只放不属于战斗/生活主流程的上下文工具；HUD、模块开关和功能入口不再重复出现。",12,40,760,24,9,"muted",ALIGN_LEFT)

    page.portalTitle = S.UI:CreateLabel(page.root,"quick_portal_title","传送门显示",12,82,150,24,12,nil,ALIGN_LEFT)
    page.portalButton = S.UI:CreateButton(page.root,"quick_portal_toggle","全部可见",170,80,126,28,9,false)
    page.portalHint = S.UI:CreateLabel(page.root,"quick_portal_hint","切换游戏的“仅自己传送门可见”选项；绿色=全部，红色=仅自己。",12,112,620,22,9,"muted",ALIGN_LEFT)

    page.auctionTitle = S.UI:CreateLabel(page.root,"quick_auction_title","拍卖辅助",12,158,150,24,12,nil,ALIGN_LEFT)
    page.auctionFavorites = S.UI:CreateButton(page.root,"quick_auction_favorites","打开拍卖收藏夹",170,156,150,28,9,false)
    page.auctionHint = S.UI:CreateLabel(page.root,"quick_auction_hint","收藏夹仍由 AuctionFavoritesService 管理，并会在原生拍卖场景复用同一数据。",12,188,700,22,9,"muted",ALIGN_LEFT)

    page.craftTitle = S.UI:CreateLabel(page.root,"quick_craft_title","制作台助手",12,234,150,24,12,nil,ALIGN_LEFT)
    page.craftEnabled = S.UI:CreateButton(page.root,"quick_craft_enabled","助手：开",170,232,104,28,9,false)
    page.craftAuto = S.UI:CreateButton(page.root,"quick_craft_auto","自动弹出：开",282,232,116,28,9,false)
    page.craftOpen = S.UI:CreateButton(page.root,"quick_craft_open","手动打开",406,232,92,28,9,false)
    page.craftHint = S.UI:CreateLabel(page.root,"quick_craft_hint","制作台助手属于跑商上下文工具；关闭只影响显示行为，不改变跑商数据 Authority。",12,264,720,22,9,"muted",ALIGN_LEFT)

    page.organizerTitle = S.UI:CreateLabel(page.root,"quick_organizer_title","背包工具",12,310,150,24,12,nil,ALIGN_LEFT)
    page.organizerOpen = S.UI:CreateButton(page.root,"quick_organizer_open","打开整理背包",170,308,126,28,9,false)
    page.organizerHint = S.UI:CreateLabel(page.root,"quick_organizer_hint","整理规则、黑名单、仓库/箱子交互统一在“工具 → 整理背包”页面管理。",12,340,700,22,9,"muted",ALIGN_LEFT)

    S.UI:SafeHandler(page.portalButton,"OnClick",function()
        if S.Api == nil or S.Api:IsCapabilityAllowed("X2Option:SetItemFloatValue") ~= true then
            S.SafeChat("传送门选项 API 当前不可用")
            return
        end
        local current = ReadPortalOption()
        if current == nil then S.SafeChat("无法读取当前传送门显示选项") return end
        local nextValue = current == 1 and 0 or 1
        local ok = S.Api:ActionCapability("X2Option:SetItemFloatValue", X2Option, "SetItemFloatValue", OIT_AUTO_USE_ONLY_MY_PORTAL, nextValue)
        if ok ~= true then S.SafeChat("传送门选项切换失败") return end
        page:Refresh()
    end,"quick:portal_toggle")

    S.UI:SafeHandler(page.auctionFavorites,"OnClick",function()
        if S.AuctionFavoritesWindow and type(S.AuctionFavoritesWindow.Show)=="function" then
            S.AuctionFavoritesWindow:Show(true)
        else
            S.SafeChat("拍卖收藏夹当前不可用")
        end
    end,"quick:auction_favorites")

    S.UI:SafeHandler(page.craftEnabled,"OnClick",function()
        local craft=CraftSettings(); craft.enabled=not (craft.enabled==true)
        S.Storage:RequestSave(); page:Refresh()
        if craft.enabled~=true and S.CraftAssistWindow and type(S.CraftAssistWindow.Show)=="function" then S.CraftAssistWindow:Show(false) end
    end,"quick:craft_enabled")
    S.UI:SafeHandler(page.craftAuto,"OnClick",function()
        local craft=CraftSettings(); craft.autoShow=not (craft.autoShow~=false)
        S.Storage:RequestSave(); page:Refresh()
    end,"quick:craft_auto")
    S.UI:SafeHandler(page.craftOpen,"OnClick",function()
        if S.CraftAssistWindow and type(S.CraftAssistWindow.Show)=="function" then S.CraftAssistWindow:Show(true)
        else S.SafeChat("制作台助手当前不可用") end
    end,"quick:craft_open")
    S.UI:SafeHandler(page.organizerOpen,"OnClick",function()
        if S.UI and type(S.UI.ShowPage)=="function" then S.UI:ShowPage("bagorganizer") end
    end,"quick:organizer_open")

    function page:Refresh()
        local portalValue=ReadPortalOption()
        local ownOnly=portalValue==1
        self.portalButton:SetText(portalValue==nil and "API不可用" or (ownOnly and "仅自己可见" or "全部可见"))
        if self.portalButton.Enable then self.portalButton:Enable(portalValue~=nil) end
        SetPortalButtonColour(self.portalButton,ownOnly)

        local craft=CraftSettings()
        self.craftEnabled:SetText(craft.enabled==true and "助手：开" or "助手：关")
        self.craftAuto:SetText(craft.autoShow~=false and "自动弹出：开" or "自动弹出：关")
        if self.craftAuto.Enable then self.craftAuto:Enable(craft.enabled==true) end
        if self.craftOpen.Enable then self.craftOpen:Enable(craft.enabled==true) end
    end

    function page:ApplyLayout(spec)
        S.UI:SetAnchor(self.root,parent,0,0); self.root:SetExtent(spec.contentWidth,spec.contentHeight)
        local sc=S.Layout:GetContext().addonScale
        local pad=12*sc
        local full=math.max(1,spec.contentWidth-pad*2)
        self.title:SetExtent(full,28*sc); S.UI:SetAnchor(self.title,self.root,pad,8*sc)
        self.note:SetExtent(full,24*sc); S.UI:SetAnchor(self.note,self.root,pad,38*sc)

        local labelW=148*sc; local buttonX=pad+158*sc
        local function Place(title,controls,hint,y)
            title:SetExtent(labelW,24*sc); S.UI:SetAnchor(title,self.root,pad,y)
            local x=buttonX
            for _,entry in ipairs(controls) do
                local b,w=entry[1],entry[2]*sc
                b:SetExtent(w,28*sc); S.UI:SetAnchor(b,self.root,x,y-2*sc); x=x+w+8*sc
            end
            hint:SetExtent(full,22*sc); S.UI:SetAnchor(hint,self.root,pad,y+30*sc)
        end
        Place(self.portalTitle,{{self.portalButton,126}},self.portalHint,82*sc)
        Place(self.auctionTitle,{{self.auctionFavorites,150}},self.auctionHint,158*sc)
        Place(self.craftTitle,{{self.craftEnabled,104},{self.craftAuto,116},{self.craftOpen,92}},self.craftHint,234*sc)
        Place(self.organizerTitle,{{self.organizerOpen,126}},self.organizerHint,310*sc)
        self:Refresh()
    end

    page:Refresh(); S.UI.pages.quick=page; return page
end
