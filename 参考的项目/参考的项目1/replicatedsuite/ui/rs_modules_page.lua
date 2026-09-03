------------------------------------------------------------------------
-- Replicated Suite - Module center / unified settings search
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S=ReplicatedSuite; S.ModulesPage={}

local function StatusText(d)
    local state = d.state=="Faulted" and "故障" or (d.enabled and "已启用" or "已关闭")
    local hudIds = type(d.hudIds)=="table" and d.hudIds or {}
    if #hudIds > 0 and S.HudManager ~= nil then
        local visible = 0
        for _, id in ipairs(hudIds) do if S.HudManager:IsEffectiveVisible(id) then visible = visible + 1 end end
        return state .. " · HUD" .. tostring(visible) .. "/" .. tostring(#hudIds)
    end
    return state
end

function S.ModulesPage.Create(parent)
    local page={root=S.UI:CreatePanel(parent,"modules_page",0,0,100,100,"soft"),rows={},searchRows={}}
    if page.root.rsBorder and page.root.rsBorder.SetVisible then page.root.rsBorder:SetVisible(false) end
    if page.root.rsBackground and page.root.rsBackground.SetVisible then page.root.rsBackground:SetVisible(false) end
    page.title=S.UI:CreateLabel(page.root,"modules_title","模块管理",12,8,300,28,16,nil,ALIGN_LEFT)
    page.note=S.UI:CreateLabel(page.root,"modules_note","模块开关只控制 Runtime；关闭不会清空模块配置、统计或 HUD 长期偏好。专业模块新安装默认关闭。",12,36,760,22,9,"muted",ALIGN_LEFT)
    page.searchLabel=S.UI:CreateLabel(page.root,"modules_search_label","设置搜索",12,65,70,24,10,nil,ALIGN_LEFT)
    page.searchEdit=S.UI:CreateEditBox(page.root,"modules_search_edit",86,63,220,26,80)
    page.searchButton=S.UI:CreateButton(page.root,"modules_search_button","搜索",314,63,58,26,9,false)
    page.searchClear=S.UI:CreateButton(page.root,"modules_search_clear","清空",378,63,58,26,9,false)
    if page.searchButton.Enable then page.searchButton:Enable(page.searchEdit~=nil) end
    for i=1,4 do
        local b=S.UI:CreateButton(page.root,"modules_search_result_"..i,"",444,63+(i-1)*29,250,26,9,false)
        b:Show(false); page.searchRows[i]=b
    end

    local modules=S.ModuleManager and S.ModuleManager:List(false) or {}
    for i,d in ipairs(modules) do
        if S.Favorites then S.Favorites:Register("module:"..d.id,d.name,"module",d.id) end
        local label=S.UI:CreateLabel(page.root,"modules_row_label_"..i,d.name,12,102,190,26,10,nil,ALIGN_LEFT)
        local state=S.UI:CreateLabel(page.root,"modules_row_state_"..i,"",205,102,86,26,9,"muted",ALIGN_LEFT)
        local toggle=S.UI:CreateButton(page.root,"modules_row_toggle_"..i,"",296,102,72,26,9,false)
        local settings=S.UI:CreateButton(page.root,"modules_row_settings_"..i,"设置",374,102,64,26,9,false)
        local favorite=S.UI:CreateButton(page.root,"modules_row_favorite_"..i,"收",444,102,30,26,10,false)
        local retry=S.UI:CreateButton(page.root,"modules_row_retry_"..i,"重试",478,102,48,26,8,false)
        page.rows[i]={id=d.id,label=label,state=state,toggle=toggle,settings=settings,favorite=favorite,retry=retry}
        S.UI:SafeHandler(toggle,"OnClick",function()
            local enabled=S.ModuleManager:IsEnabled(d.id)
            local ok,err=S.ModuleManager:SetEnabled(d.id,not enabled)
            if not ok then S.SafeChat("模块“"..tostring(d.name).."”切换失败："..tostring(err)) end
            page:Refresh()
        end,"modules:toggle:"..d.id)
        S.UI:SafeHandler(settings,"OnClick",function()
            local ok,err=S.ModuleManager:OpenSettings(d.id)
            if not ok then S.SafeChat("模块入口暂不可用："..tostring(err or d.name)) end
        end,"modules:settings:"..d.id)
        S.UI:SafeHandler(favorite,"OnClick",function() if S.Favorites then S.Favorites:Toggle("module:"..d.id) end; page:Refresh() end,"modules:favorite:"..d.id)
        S.UI:SafeHandler(retry,"OnClick",function()
            local ok,err=S.ModuleManager:Retry(d.id)
            if not ok then S.SafeChat("模块重试失败："..tostring(err)) end
            page:Refresh()
        end,"modules:retry:"..d.id)
    end

    page.profileLabel=S.UI:CreateLabel(page.root,"modules_profile_label","功能方案",12,480,70,24,10,nil,ALIGN_LEFT)
    page.profileEdit=S.UI:CreateEditBox(page.root,"modules_profile_edit",86,478,132,26,32)
    page.nextProfile=S.UI:CreateButton(page.root,"modules_profile_next","选择",224,478,48,26,9,false)
    page.saveProfile=S.UI:CreateButton(page.root,"modules_profile_save","保存",278,478,48,26,9,false)
    page.applyProfile=S.UI:CreateButton(page.root,"modules_profile_apply","应用",332,478,48,26,9,false)
    page.deleteProfile=S.UI:CreateButton(page.root,"modules_profile_delete","删除",386,478,48,26,9,false)

    page.comboLabel=S.UI:CreateLabel(page.root,"modules_combo_label","组合快捷",12,510,70,24,10,nil,ALIGN_LEFT)
    page.comboEdit=S.UI:CreateEditBox(page.root,"modules_combo_edit",86,508,132,26,32)
    page.nextCombo=S.UI:CreateButton(page.root,"modules_combo_next","选择",224,508,48,26,9,false)
    page.saveCombo=S.UI:CreateButton(page.root,"modules_combo_save","保存当前",278,508,68,26,9,false)
    page.applyCombo=S.UI:CreateButton(page.root,"modules_combo_apply","应用",352,508,48,26,9,false)
    page.deleteCombo=S.UI:CreateButton(page.root,"modules_combo_delete","删除",406,508,48,26,9,false)

    local function CleanName(edit)
        local n=edit and tostring(edit:GetText() or "") or ""
        return (n:gsub("^%s+", ""):gsub("%s+$", ""))
    end
    local function ProfileName() return page.profileEdit and CleanName(page.profileEdit) or tostring(page.selectedProfileName or "") end
    local function ComboName() return page.comboEdit and CleanName(page.comboEdit) or tostring(page.selectedComboName or "") end
    local function Cycle(kind, edit)
        local current=kind=="combo" and ComboName() or ProfileName()
        local nextName=S.Profiles:NextName(kind,current)
        if nextName==nil then S.SafeChat(kind=="combo" and "还没有组合快捷方式。" or "还没有已保存的功能方案。"); return end
        if edit and edit.SetText then edit:SetText(nextName)
        elseif kind=="combo" then page.selectedComboName=nextName
        else page.selectedProfileName=nextName end
    end
    local function DeleteWithConfirm(kind,name)
        if name=="" then S.SafeChat(kind=="combo" and "请选择或输入组合名称。" or "请选择或输入功能方案名称。"); return end
        local now=S.NowMs and S.NowMs() or 0
        if page.deleteArmedKind==kind and page.deleteArmedName==name and now-(tonumber(page.deleteArmedAt) or 0)<=5000 then
            local ok,err=S.Profiles:Delete(kind,name)
            page.deleteArmedKind=nil; page.deleteArmedName=nil; page.deleteArmedAt=0
            if ok then S.SafeChat("已删除："..name) else S.SafeChat(tostring(err)) end
        else
            page.deleteArmedKind=kind; page.deleteArmedName=name; page.deleteArmedAt=now
            S.SafeChat("再次点击删除确认："..name)
        end
        page:Refresh()
    end
    S.UI:SafeHandler(page.nextProfile,"OnClick",function() Cycle("feature",page.profileEdit); page:Refresh() end,"modules:profile_next")
    S.UI:SafeHandler(page.saveProfile,"OnClick",function()
        if page.profileEdit==nil then S.SafeChat("当前客户端输入框不可用；可选择并应用已有功能方案，但不能新建名称。") return end
        local n=ProfileName(); if n=="" then S.SafeChat("请输入功能方案名称。") return end
        S.Profiles:SaveFeature(n); page.selectedProfileName=n; S.SafeChat("已保存功能方案："..n); page:Refresh()
    end,"modules:profile_save")
    S.UI:SafeHandler(page.applyProfile,"OnClick",function()
        local n=ProfileName(); local ok,err=S.Profiles:ApplyFeature(n); if not ok then S.SafeChat(tostring(err)) end; page:Refresh()
    end,"modules:profile_apply")
    S.UI:SafeHandler(page.deleteProfile,"OnClick",function() DeleteWithConfirm("feature",ProfileName()) end,"modules:profile_delete")
    S.UI:SafeHandler(page.nextCombo,"OnClick",function() Cycle("combo",page.comboEdit); page:Refresh() end,"modules:combo_next")
    S.UI:SafeHandler(page.saveCombo,"OnClick",function()
        if page.comboEdit==nil then S.SafeChat("当前客户端输入框不可用；可选择并应用已有组合，但不能新建名称。") return end
        local n=ComboName(); if n=="" then S.SafeChat("请输入组合名称。") return end
        local ok,err=S.Profiles:SaveCurrentCombo(n); if ok then page.selectedComboName=n; S.SafeChat("已保存当前功能 + HUD 组合："..n) else S.SafeChat(tostring(err)) end; page:Refresh()
    end,"modules:combo_save")
    S.UI:SafeHandler(page.applyCombo,"OnClick",function()
        local n=ComboName(); local ok,err=S.Profiles:ApplyCombo(n); if not ok then S.SafeChat(tostring(err)) end; page:Refresh()
    end,"modules:combo_apply")
    S.UI:SafeHandler(page.deleteCombo,"OnClick",function() DeleteWithConfirm("combo",ComboName()) end,"modules:combo_delete")

    function page:RunSearch()
        local q=self.searchEdit and tostring(self.searchEdit:GetText() or "") or ""
        local results=S.SettingsRegistry and S.SettingsRegistry:Search(q,4) or {}
        for i,b in ipairs(self.searchRows) do
            local item=results[i]
            if item then
                b.rsSearchId=item.Id; b:SetText(tostring(item.Category).."｜"..tostring(item.Title)); b:Show(true)
            else b.rsSearchId=nil; b:Show(false) end
        end
    end
    S.UI:SafeHandler(page.searchButton,"OnClick",function() page:RunSearch() end,"modules:search")
    S.UI:SafeHandler(page.searchClear,"OnClick",function()
        if page.searchEdit and page.searchEdit.SetText then page.searchEdit:SetText("") end
        for _,b in ipairs(page.searchRows) do b:Show(false); b.rsSearchId=nil end
    end,"modules:search_clear")
    for _,b in ipairs(page.searchRows) do
        S.UI:SafeHandler(b,"OnClick",function()
            if b.rsSearchId and S.SettingsRegistry then S.SettingsRegistry:Open(b.rsSearchId) end
        end,"modules:search_open")
    end

    function page:Refresh()
        local now=S.NowMs and S.NowMs() or 0
        if now-(tonumber(self.deleteArmedAt) or 0)>5000 then self.deleteArmedKind=nil; self.deleteArmedName=nil; self.deleteArmedAt=0 end
        self.deleteProfile:SetText(self.deleteArmedKind=="feature" and self.deleteArmedName==ProfileName() and "再删" or "删除")
        self.deleteCombo:SetText(self.deleteArmedKind=="combo" and self.deleteArmedName==ComboName() and "再删" or "删除")
        self.saveProfile:Enable(self.profileEdit~=nil)
        self.saveCombo:Enable(self.comboEdit~=nil)
        local store=type(S.State.profiles)=="table" and S.State.profiles or {}
        local features=type(store.features)=="table" and store.features or {}
        local combos=type(store.combos)=="table" and store.combos or {}
        local profileName=ProfileName(); local comboName=ComboName()
        local hasProfiles=S.Profiles and S.Profiles:NextName("feature","")~=nil
        local hasCombos=S.Profiles and S.Profiles:NextName("combo","")~=nil
        if self.nextProfile.Enable then self.nextProfile:Enable(hasProfiles) end
        if self.applyProfile.Enable then self.applyProfile:Enable(profileName~="" and type(features[profileName])=="table") end
        if self.deleteProfile.Enable then self.deleteProfile:Enable(profileName~="" and type(features[profileName])=="table") end
        if self.nextCombo.Enable then self.nextCombo:Enable(hasCombos) end
        if self.applyCombo.Enable then self.applyCombo:Enable(comboName~="" and type(combos[comboName])=="table") end
        if self.deleteCombo.Enable then self.deleteCombo:Enable(comboName~="" and type(combos[comboName])=="table") end
        for _,r in ipairs(self.rows) do
            local d=S.ModuleManager:Describe(r.id)
            if d then
                r.state:SetText(StatusText(d)); r.toggle:SetText(d.enabled and "关闭" or "启用")
                r.retry:Show(d.state=="Faulted")
                r.favorite:SetText(S.Favorites and S.Favorites:IsFavorite("module:"..r.id) and "已" or "收")
                local hasSettings=d.hasSettings==true
                r.settings:SetText(hasSettings and tostring(d.settingsLabel or "设置") or "无设置")
                r.settings:Enable(hasSettings and d.state~="Faulted")
            end
        end
    end

    function page:ApplyLayout(spec)
        S.UI:SetAnchor(self.root,parent,0,0); self.root:SetExtent(spec.contentWidth,spec.contentHeight)
        local sc=S.Layout:GetContext().addonScale
        local pad=10*sc
        local full=math.max(1,spec.contentWidth-pad*2)
        self.title:SetExtent(full,27*sc); S.UI:SetAnchor(self.title,self.root,pad,5*sc)
        self.note:SetExtent(full,21*sc); S.UI:SetAnchor(self.note,self.root,pad,32*sc)

        -- Search row is solved from the available width. EditBox is optional on
        -- some RU client builds, so buttons never depend on it existing.
        local searchY=58*sc
        local searchLabelW=64*sc
        self.searchLabel:SetExtent(searchLabelW,24*sc); S.UI:SetAnchor(self.searchLabel,self.root,pad,searchY+1*sc)
        local actionW=54*sc; local gap=5*sc
        local searchRight=pad+full
        self.searchClear:SetExtent(actionW,26*sc); S.UI:SetAnchor(self.searchClear,self.root,searchRight-actionW,searchY)
        self.searchButton:SetExtent(actionW,26*sc); S.UI:SetAnchor(self.searchButton,self.root,searchRight-actionW*2-gap,searchY)
        if self.searchEdit then
            local editX=pad+searchLabelW+5*sc
            local editRight=searchRight-actionW*2-gap*3
            self.searchEdit:SetExtent(math.max(70*sc,editRight-editX),26*sc); S.UI:SetAnchor(self.searchEdit,self.root,editX,searchY)
        end
        local resultY=88*sc; local resultGap=5*sc; local resultW=math.max(1,(full-resultGap*3)/4)
        for i,b in ipairs(self.searchRows) do b:SetExtent(resultW,23*sc); S.UI:SetAnchor(b,self.root,pad+(i-1)*(resultW+resultGap),resultY) end

        local top=116*sc
        local footerH=64*sc
        local count=math.max(1,#self.rows)
        local availableRows=math.max(1,spec.contentHeight-top-footerH-4*sc)
        local step=math.max(20*sc,math.min(30*sc,availableRows/count))
        local rowH=math.max(18*sc,step-2*sc)
        local stateW=82*sc
        local actionGap=3*sc
        local toggleW,settingsW,favoriteW,retryW=54*sc,48*sc,26*sc,38*sc
        local actionsW=toggleW+settingsW+favoriteW+retryW+actionGap*3
        local labelW=math.max(80*sc,full-stateW-actionsW-10*sc)
        local maxLabel=math.max(80*sc,full*0.40)
        labelW=math.min(labelW,maxLabel)
        for i,r in ipairs(self.rows) do
            local y=top+(i-1)*step
            r.label:SetExtent(labelW,rowH); S.UI:SetAnchor(r.label,self.root,pad,y)
            local stateX=pad+labelW+4*sc
            r.state:SetExtent(stateW,rowH); S.UI:SetAnchor(r.state,self.root,stateX,y)
            local x=stateX+stateW+4*sc
            for _,entry in ipairs({{r.toggle,toggleW},{r.settings,settingsW},{r.favorite,favoriteW},{r.retry,retryW}}) do
                entry[1]:SetExtent(entry[2],rowH); S.UI:SetAnchor(entry[1],self.root,x,y); x=x+entry[2]+actionGap
            end
        end

        local footerY=math.min(spec.contentHeight-58*sc,top+count*step+3*sc)
        local function LayoutProfileRow(label,edit,buttons,rowY)
            local labelW2=64*sc
            label:SetExtent(labelW2,24*sc); S.UI:SetAnchor(label,self.root,pad,rowY)
            local x=pad+labelW2+4*sc
            if edit~=nil then
                local desired=104*sc
                local buttonMin=40*sc*#buttons+4*sc*(#buttons-1)
                local ew=math.max(68*sc,math.min(desired,pad+full-x-buttonMin-4*sc))
                edit:SetExtent(ew,25*sc); S.UI:SetAnchor(edit,self.root,x,rowY-1*sc); x=x+ew+4*sc
            end
            local remain=math.max(1,pad+full-x)
            local bgap=4*sc
            local bw=math.max(34*sc,(remain-bgap*(#buttons-1))/#buttons)
            for _,b in ipairs(buttons) do b:SetExtent(bw,25*sc); S.UI:SetAnchor(b,self.root,x,rowY-1*sc); x=x+bw+bgap end
        end
        LayoutProfileRow(self.profileLabel,self.profileEdit,{self.nextProfile,self.saveProfile,self.applyProfile,self.deleteProfile},footerY)
        LayoutProfileRow(self.comboLabel,self.comboEdit,{self.nextCombo,self.saveCombo,self.applyCombo,self.deleteCombo},footerY+29*sc)
        self:Refresh()
    end
    S.UI.pages.modules=page; return page
end
