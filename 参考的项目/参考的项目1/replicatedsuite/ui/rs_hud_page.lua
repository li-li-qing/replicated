------------------------------------------------------------------------
-- Replicated Suite - Central HUD management
-- Architecture v1.1: one HUD Authority, appearance inheritance and recovery.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S=ReplicatedSuite; S.HudPage={}

local BG_STEPS={1.00,0.85,0.70,0.55,0.35,0.20,0.00}
local function NextBackground(value)
    local current=tonumber(value) or 0.90
    if current>0.85 and current<1.00 then return 0.85 end
    for i,v in ipairs(BG_STEPS) do
        if math.abs(v-current)<0.001 then return BG_STEPS[i<#BG_STEPS and i+1 or 1] end
    end
    return 0.85
end
local function Percent(value) return tostring(math.floor((tonumber(value) or 0)*100+0.5)).."%" end

function S.HudPage.Create(parent)
    local page={root=S.UI:CreatePanel(parent,"hud_page",0,0,100,100,"soft"),rows={},selectedId=nil,recoverArmedAt=0,resetAllArmedAt=0,resetAllArmedId=nil}
    if page.root.rsBorder and page.root.rsBorder.SetVisible then page.root.rsBorder:SetVisible(false) end
    if page.root.rsBackground and page.root.rsBackground.SetVisible then page.root.rsBackground:SetVisible(false) end
    page.title=S.UI:CreateLabel(page.root,"hud_title","HUD 管理",12,7,300,26,16,nil,ALIGN_LEFT)
    page.note=S.UI:CreateLabel(page.root,"hud_note","显示偏好 / 模块启用 / 折叠互相独立；外观可继承全局，也可单 HUD 覆盖。",12,33,780,20,9,"muted",ALIGN_LEFT)

    page.edit=S.UI:CreateButton(page.root,"hud_edit","编辑布局：关",12,57,106,25,9,false)
    page.unlock=S.UI:CreateButton(page.root,"hud_unlock","临时解锁：关",122,57,106,25,9,false)
    page.snap=S.UI:CreateButton(page.root,"hud_snap","吸附：开",232,57,76,25,9,false)
    page.closeToggle=S.UI:CreateButton(page.root,"hud_close_toggle","关闭键：开",312,57,88,25,9,false)
    page.temp=S.UI:CreateButton(page.root,"hud_temp","临时隐藏",404,57,84,25,9,false)
    page.recover=S.UI:CreateButton(page.root,"hud_recover","紧急恢复全部",492,57,106,25,9,false)

    page.globalFontMinus=S.UI:CreateButton(page.root,"hud_global_font_minus","全局字 -",12,87,70,24,9,false)
    page.globalFont=S.UI:CreateLabel(page.root,"hud_global_font","字100%",86,89,62,22,9,"yellow",ALIGN_CENTER)
    page.globalFontPlus=S.UI:CreateButton(page.root,"hud_global_font_plus","全局字 +",152,87,70,24,9,false)
    page.globalBg=S.UI:CreateButton(page.root,"hud_global_bg","背景90%",228,87,78,24,9,false)
    page.globalCompact=S.UI:CreateButton(page.root,"hud_global_compact","紧凑：关",312,87,76,24,9,false)

    S.UI:SafeHandler(page.edit,"OnClick",function() S.HudManager:SetEditMode(not S.HudManager:IsEditMode()); page:Refresh() end,"hud:edit")
    S.UI:SafeHandler(page.unlock,"OnClick",function()
        if not S.HudManager:IsEditMode() then S.HudManager:SetEditMode(true) end
        S.HudManager:SetTemporaryUnlockAll(not S.HudManager:IsTemporaryUnlockAll()); page:Refresh()
    end,"hud:unlock")
    S.UI:SafeHandler(page.snap,"OnClick",function() S.State.settings.hudSnapEnabled=not (S.State.settings.hudSnapEnabled~=false); S.Storage:RequestSave(); page:Refresh() end,"hud:snap")
    S.UI:SafeHandler(page.closeToggle,"OnClick",function()
        S.State.settings.hudCloseButtonEnabled=not (S.State.settings.hudCloseButtonEnabled~=false)
        S.Storage:RequestSave()
        if S.HudManager then S.HudManager:ApplyAll() end
        page:Refresh()
    end,"hud:close_toggle")
    S.UI:SafeHandler(page.temp,"OnClick",function() if S.HudManager.temporaryHidden then S.HudManager:RestoreTemporaryHidden() else S.HudManager:TemporaryHideAll() end; page:Refresh() end,"hud:temp")
    S.UI:SafeHandler(page.recover,"OnClick",function()
        local now=S.NowMs and S.NowMs() or 0
        if now-(tonumber(page.recoverArmedAt) or 0)<=5000 then
            page.recoverArmedAt=0; S.HudManager:RecoverAll(); S.SafeChat("已执行紧急 HUD 恢复。")
        else
            page.recoverArmedAt=now; S.SafeChat("再次点击“紧急恢复全部”确认。")
        end
        page:Refresh()
    end,"hud:recover_all")
    S.UI:SafeHandler(page.globalFontMinus,"OnClick",function() S.HudManager:AdjustGlobalFontScale(-0.10); page:Refresh() end,"hud:gfont_minus")
    S.UI:SafeHandler(page.globalFontPlus,"OnClick",function() S.HudManager:AdjustGlobalFontScale(0.10); page:Refresh() end,"hud:gfont_plus")
    S.UI:SafeHandler(page.globalBg,"OnClick",function() S.HudManager:SetGlobalBackgroundAlpha(NextBackground(S.State.settings.globalHudBackgroundAlpha)); page:Refresh() end,"hud:gbg")
    S.UI:SafeHandler(page.globalCompact,"OnClick",function() S.HudManager:SetGlobalCompact(not (S.State.settings.globalCompactMode==true)); page:Refresh() end,"hud:gcompact")

    local list=S.HudManager and S.HudManager:List() or {}
    for i,d in ipairs(list) do
        if S.Favorites then S.Favorites:Register("hud:"..d.id,d.title,"hud",d.id) end
        local label=S.UI:CreateLabel(page.root,"hud_row_label_"..i,d.title,12,120,190,24,9,nil,ALIGN_LEFT)
        local module=S.UI:CreateLabel(page.root,"hud_row_module_"..i,d.moduleId,205,120,70,24,8,"muted",ALIGN_LEFT)
        local show=S.UI:CreateButton(page.root,"hud_row_show_"..i,"",280,120,62,24,8,false)
        local collapse=S.UI:CreateButton(page.root,"hud_row_collapse_"..i,"",346,120,54,24,8,false)
        local favorite=S.UI:CreateButton(page.root,"hud_row_favorite_"..i,"收",404,120,28,24,10,false)
        local select=S.UI:CreateButton(page.root,"hud_row_select_"..i,"设置",436,120,48,24,8,false)
        page.rows[i]={id=d.id,label=label,module=module,show=show,collapse=collapse,favorite=favorite,select=select}
        S.UI:SafeHandler(show,"OnClick",function() S.HudManager:ToggleVisible(d.id); page:Refresh() end,"hud:show:"..d.id)
        S.UI:SafeHandler(collapse,"OnClick",function() S.HudManager:ToggleCollapsed(d.id); page:Refresh() end,"hud:collapse:"..d.id)
        S.UI:SafeHandler(favorite,"OnClick",function() if S.Favorites then S.Favorites:Toggle("hud:"..d.id) end; page:Refresh() end,"hud:favorite:"..d.id)
        S.UI:SafeHandler(select,"OnClick",function() page.selectedId=d.id; page:Refresh() end,"hud:select:"..d.id)
    end
    if #list>0 then page.selectedId=list[1].id end

    page.detailTitle=S.UI:CreateLabel(page.root,"hud_detail_title","当前 HUD：--",12,390,430,22,10,"yellow",ALIGN_LEFT)
    local function B(id,text,w) return S.UI:CreateButton(page.root,id,text,0,0,w or 58,24,8,false) end
    page.find=B("hud_detail_find","找回",48); page.lock=B("hud_detail_lock","锁定：关",62); page.resetPos=B("hud_detail_pos","位置默认",64); page.resetSize=B("hud_detail_size","尺寸默认",64)
    page.fontMinus=B("hud_detail_font_minus","字 -",44); page.fontPlus=B("hud_detail_font_plus","字 +",44); page.fontInherit=B("hud_detail_font_inherit","字体继承",64)
    page.bg=B("hud_detail_bg","背景",62); page.bgInherit=B("hud_detail_bg_inherit","背景继承",64)
    page.compact=B("hud_detail_compact","紧凑",62); page.compactInherit=B("hud_detail_compact_inherit","紧凑继承",64)
    page.resetTitle=B("hud_detail_title_reset","标题恢复",64); page.resetAppearance=B("hud_detail_appearance","外观恢复",64); page.resetAll=B("hud_detail_all","全部恢复",64)
    local function Selected() return page.selectedId end
    S.UI:SafeHandler(page.find,"OnClick",function() S.HudManager:Recover(Selected()); page:Refresh() end,"hud:detail_find")
    S.UI:SafeHandler(page.lock,"OnClick",function() S.HudManager:ToggleLocked(Selected()); page:Refresh() end,"hud:detail_lock")
    S.UI:SafeHandler(page.resetPos,"OnClick",function() S.HudManager:ResetPosition(Selected()); page:Refresh() end,"hud:detail_pos")
    S.UI:SafeHandler(page.resetSize,"OnClick",function() S.HudManager:ResetSize(Selected()); page:Refresh() end,"hud:detail_size")
    S.UI:SafeHandler(page.fontMinus,"OnClick",function() S.HudManager:AdjustFontScale(Selected(),-0.10); page:Refresh() end,"hud:detail_font_minus")
    S.UI:SafeHandler(page.fontPlus,"OnClick",function() S.HudManager:AdjustFontScale(Selected(),0.10); page:Refresh() end,"hud:detail_font_plus")
    S.UI:SafeHandler(page.fontInherit,"OnClick",function() S.HudManager:RestoreFontInheritance(Selected()); page:Refresh() end,"hud:detail_font_inherit")
    S.UI:SafeHandler(page.bg,"OnClick",function() local id=Selected(); S.HudManager:SetBackgroundAlpha(id,NextBackground(S.HudManager:GetEffectiveBackgroundAlpha(id))); page:Refresh() end,"hud:detail_bg")
    S.UI:SafeHandler(page.bgInherit,"OnClick",function() S.HudManager:RestoreBackgroundInheritance(Selected()); page:Refresh() end,"hud:detail_bg_inherit")
    S.UI:SafeHandler(page.compact,"OnClick",function() local id=Selected(); S.HudManager:SetCompact(id,not S.HudManager:IsCompact(id)); page:Refresh() end,"hud:detail_compact")
    S.UI:SafeHandler(page.compactInherit,"OnClick",function() S.HudManager:RestoreCompactInheritance(Selected()); page:Refresh() end,"hud:detail_compact_inherit")
    S.UI:SafeHandler(page.resetTitle,"OnClick",function() S.HudManager:ResetTitle(Selected()); page:Refresh() end,"hud:detail_title_reset")
    S.UI:SafeHandler(page.resetAppearance,"OnClick",function() S.HudManager:ResetHudAppearance(Selected()); page:Refresh() end,"hud:detail_appearance")
    S.UI:SafeHandler(page.resetAll,"OnClick",function()
        local id=Selected(); if not id then return end
        local now=S.NowMs and S.NowMs() or 0
        if page.resetAllArmedId==id and now-(tonumber(page.resetAllArmedAt) or 0)<=5000 then
            page.resetAllArmedAt=0; page.resetAllArmedId=nil; S.HudManager:ResetHudAll(id); S.SafeChat("已恢复 HUD 默认项："..tostring(id))
        else
            page.resetAllArmedAt=now; page.resetAllArmedId=id; S.SafeChat("再次点击“全部恢复”确认当前 HUD。")
        end
        page:Refresh()
    end,"hud:detail_all")

    page.profileLabel=S.UI:CreateLabel(page.root,"hud_profile_label","HUD方案",12,470,70,24,9,nil,ALIGN_LEFT)
    page.profileEdit=S.UI:CreateEditBox(page.root,"hud_profile_edit",86,468,116,24,32)
    page.nextProfile=S.UI:CreateButton(page.root,"hud_profile_next","选择",208,468,46,24,8,false)
    page.saveProfile=S.UI:CreateButton(page.root,"hud_profile_save","保存布局",260,468,62,24,8,false)
    page.applyProfile=S.UI:CreateButton(page.root,"hud_profile_apply","应用布局",328,468,62,24,8,false)
    page.deleteProfile=S.UI:CreateButton(page.root,"hud_profile_delete","删除",396,468,46,24,8,false)
    local function ProfileName()
        local n=page.profileEdit and tostring(page.profileEdit:GetText() or "") or tostring(page.selectedProfileName or "")
        return (n:gsub("^%s+", ""):gsub("%s+$", ""))
    end
    S.UI:SafeHandler(page.nextProfile,"OnClick",function()
        local n=S.Profiles:NextName("hud",ProfileName())
        if n==nil then S.SafeChat("还没有已保存的 HUD 方案。")
        elseif page.profileEdit and page.profileEdit.SetText then page.profileEdit:SetText(n)
        else page.selectedProfileName=n end
        page:Refresh()
    end,"hud:profile_next")
    S.UI:SafeHandler(page.saveProfile,"OnClick",function()
        if page.profileEdit==nil then S.SafeChat("当前客户端输入框不可用；可选择并应用已有 HUD 方案，但不能新建名称。"); return end
        local n=ProfileName(); if n=="" then S.SafeChat("请输入 HUD 方案名称。") else page.selectedProfileName=n; S.Profiles:SaveHud(n); S.SafeChat("已保存 HUD 方案："..n); page:Refresh() end
    end,"hud:profile_save")
    S.UI:SafeHandler(page.applyProfile,"OnClick",function() local ok,err=S.Profiles:ApplyHud(ProfileName()); if not ok then S.SafeChat(tostring(err)) end; page:Refresh() end,"hud:profile_apply")
    S.UI:SafeHandler(page.deleteProfile,"OnClick",function()
        local n=ProfileName(); if n=="" then S.SafeChat("请选择或输入 HUD 方案名称。"); return end
        local now=S.NowMs and S.NowMs() or 0
        if page.profileDeleteArmedName==n and now-(tonumber(page.profileDeleteArmedAt) or 0)<=5000 then
            local ok,err=S.Profiles:Delete("hud",n); page.profileDeleteArmedName=nil; page.profileDeleteArmedAt=0
            if ok then S.SafeChat("已删除 HUD 方案："..n) else S.SafeChat(tostring(err)) end
        else
            page.profileDeleteArmedName=n; page.profileDeleteArmedAt=now; S.SafeChat("再次点击删除确认 HUD 方案："..n)
        end
        page:Refresh()
    end,"hud:profile_delete")

    function page:Refresh()
        local now=S.NowMs and S.NowMs() or 0
        if now-(tonumber(self.recoverArmedAt) or 0)>5000 then self.recoverArmedAt=0 end
        if now-(tonumber(self.resetAllArmedAt) or 0)>5000 then self.resetAllArmedAt=0; self.resetAllArmedId=nil end
        if now-(tonumber(self.profileDeleteArmedAt) or 0)>5000 then self.profileDeleteArmedName=nil; self.profileDeleteArmedAt=0 end
        self.deleteProfile:SetText(self.profileDeleteArmedName==ProfileName() and self.profileDeleteArmedAt>0 and "再删" or "删除")
        self.saveProfile:Enable(self.profileEdit~=nil)
        local hudName=ProfileName(); local profileStore=type(S.State.profiles)=="table" and S.State.profiles or {}
        local hudProfiles=type(profileStore.huds)=="table" and profileStore.huds or {}
        local hasHudProfiles=S.Profiles and S.Profiles:NextName("hud","")~=nil
        if self.nextProfile.Enable then self.nextProfile:Enable(hasHudProfiles) end
        if self.applyProfile.Enable then self.applyProfile:Enable(hudName~="" and type(hudProfiles[hudName])=="table") end
        if self.deleteProfile.Enable then self.deleteProfile:Enable(hudName~="" and type(hudProfiles[hudName])=="table") end
        self.edit:SetText(S.HudManager:IsEditMode() and "编辑布局：开" or "编辑布局：关")
        self.unlock:SetText(S.HudManager:IsTemporaryUnlockAll() and "临时解锁：开" or "临时解锁：关")
        self.unlock:Enable(S.HudManager:IsEditMode())
        self.snap:SetText(S.State.settings.hudSnapEnabled~=false and "吸附：开" or "吸附：关")
        self.closeToggle:SetText(S.State.settings.hudCloseButtonEnabled~=false and "关闭键：开" or "关闭键：关")
        self.temp:SetText(S.HudManager.temporaryHidden and "恢复显示" or "临时隐藏")
        self.recover:SetText(self.recoverArmedAt>0 and "再次确认恢复" or "紧急恢复全部")
        self.globalFont:SetText("字"..Percent(S.State.settings.globalHudFontScale))
        self.globalBg:SetText("背景"..Percent(S.State.settings.globalHudBackgroundAlpha))
        self.globalCompact:SetText(S.State.settings.globalCompactMode==true and "紧凑：开" or "紧凑：关")
        for _,r in ipairs(self.rows) do
            local d=S.HudManager:Get(r.id); local visible=S.HudManager:IsVisible(r.id); local effective=S.HudManager:IsEffectiveVisible(r.id)
            r.show:SetText(visible and (effective and "显示中" or "已保存") or "隐藏")
            r.collapse:SetText(S.HudManager:IsCollapsed(r.id) and "展开" or "缩小")
            r.collapse:Show(d~=nil and d.SupportsCollapsed~=false)
            r.favorite:SetText(S.Favorites and S.Favorites:IsFavorite("hud:"..r.id) and "已" or "收")
            r.select:SetText(self.selectedId==r.id and "[设置]" or "设置")
        end
        local id=self.selectedId; local def=id and S.HudManager:Get(id) or nil; local p=id and S.HudManager:GetPlacement(id) or nil
        self.detailTitle:SetText(def and ("当前 HUD："..def.Title) or "当前 HUD：--")
        self.resetAll:SetText((def and self.resetAllArmedId==id and self.resetAllArmedAt>0) and "再次确认" or "全部恢复")
        local has=def~=nil
        for _,b in ipairs({self.find,self.lock,self.resetPos,self.resetTitle,self.resetAppearance,self.resetAll}) do b:Enable(has) end
        self.lock:SetText(has and ((p and p.locked==true) and "锁定：开" or "锁定：关") or "锁定：关")
        self.resetSize:Enable(has and def.SupportsResize~=false); self.resetSize:Show(has and def.SupportsResize~=false)
        local fontCap=has and def.SupportsFont~=false; self.fontMinus:Show(fontCap); self.fontPlus:Show(fontCap); self.fontInherit:Show(fontCap)
        local bgCap=has and def.SupportsBackground~=false; self.bg:Show(bgCap); self.bgInherit:Show(bgCap)
        local compactCap=has and def.SupportsCompact~=false; self.compact:Show(compactCap); self.compactInherit:Show(compactCap)
        if fontCap then self.fontInherit:SetText((p and p.fontInherited~=false) and ("字体继承 "..Percent(S.HudManager:GetEffectiveFontScale(id))) or ("独立字 "..Percent(S.HudManager:GetEffectiveFontScale(id)))) end
        if bgCap then self.bg:SetText("背景 "..Percent(S.HudManager:GetEffectiveBackgroundAlpha(id))); self.bgInherit:SetText((p and p.backgroundInherited~=false) and "背景继承" or "独立背景") end
        if compactCap then self.compact:SetText(S.HudManager:IsCompact(id) and "紧凑：开" or "紧凑：关"); self.compactInherit:SetText((p and p.compactInherited~=false) and "紧凑继承" or "独立紧凑") end
    end

    function page:ApplyLayout(spec)
        S.UI:SetAnchor(self.root,parent,0,0); self.root:SetExtent(spec.contentWidth,spec.contentHeight)
        local sc=S.Layout:GetContext().addonScale; local pad=10*sc; local full=math.max(1,spec.contentWidth-pad*2)
        self.title:SetExtent(full,26*sc); S.UI:SetAnchor(self.title,self.root,pad,5*sc)
        self.note:SetExtent(full,20*sc); S.UI:SetAnchor(self.note,self.root,pad,31*sc)

        local gap=4*sc
        local top1=54*sc
        local topButtons={self.edit,self.unlock,self.snap,self.closeToggle,self.temp,self.recover}
        local topW=math.max(1,(full-gap*(#topButtons-1))/#topButtons)
        local x=pad
        for _,b in ipairs(topButtons) do b:SetExtent(topW,25*sc); S.UI:SetAnchor(b,self.root,x,top1); x=x+topW+gap end
        local top2=83*sc
        local globalButtons={self.globalFontMinus,self.globalFont,self.globalFontPlus,self.globalBg,self.globalCompact}
        local globalW=math.max(1,(full-gap*(#globalButtons-1))/#globalButtons)
        x=pad
        for _,b in ipairs(globalButtons) do b:SetExtent(globalW,24*sc); S.UI:SetAnchor(b,self.root,x,top2); x=x+globalW+gap end

        local rowsTop=112*sc
        local bottomReserve=132*sc
        local usable=math.max(1,spec.contentHeight-rowsTop-bottomReserve)
        local step=math.max(20*sc,math.min(27*sc,usable/math.max(1,#self.rows)))
        local rowH=math.max(18*sc,step-2*sc)
        local moduleW=54*sc
        local actionGap=3*sc
        local showW,collapseW,favW,selectW=54*sc,46*sc,26*sc,44*sc
        local actionW=showW+collapseW+favW+selectW+actionGap*3
        local labelW=math.max(70*sc,full-moduleW-actionW-10*sc)
        labelW=math.min(labelW,full*0.42)
        for i,r in ipairs(self.rows) do
            local y=rowsTop+(i-1)*step
            r.label:SetExtent(labelW,rowH); S.UI:SetAnchor(r.label,self.root,pad,y)
            local moduleX=pad+labelW+3*sc
            r.module:SetExtent(moduleW,rowH); S.UI:SetAnchor(r.module,self.root,moduleX,y)
            local bx=moduleX+moduleW+4*sc
            for _,entry in ipairs({{r.show,showW},{r.collapse,collapseW},{r.favorite,favW},{r.select,selectW}}) do
                entry[1]:SetExtent(entry[2],rowH); S.UI:SetAnchor(entry[1],self.root,bx,y); bx=bx+entry[2]+actionGap
            end
        end

        local detailY=rowsTop+#self.rows*step+3*sc
        self.detailTitle:SetExtent(full,22*sc); S.UI:SetAnchor(self.detailTitle,self.root,pad,detailY); detailY=detailY+23*sc
        local detailButtons={self.find,self.lock,self.resetPos,self.resetSize,self.fontMinus,self.fontPlus,self.fontInherit,self.bg,self.bgInherit,self.compact,self.compactInherit,self.resetTitle,self.resetAppearance,self.resetAll}
        x=pad; local detailRow=0
        for _,b in ipairs(detailButtons) do
            local designW=(b==self.fontMinus or b==self.fontPlus or b==self.find) and 46 or 64
            local bw=designW*sc
            if x+bw>pad+full then detailRow=detailRow+1; x=pad end
            b:SetExtent(bw,23*sc); S.UI:SetAnchor(b,self.root,x,detailY+detailRow*26*sc); x=x+bw+4*sc
        end
        local profileY=math.min(spec.contentHeight-26*sc,detailY+(detailRow+1)*26*sc+3*sc)
        local profileLabelW=64*sc
        self.profileLabel:SetExtent(profileLabelW,23*sc); S.UI:SetAnchor(self.profileLabel,self.root,pad,profileY)
        local px=pad+profileLabelW+4*sc
        if self.profileEdit then
            local buttonCount=4; local buttonMin=38*sc*buttonCount+4*sc*(buttonCount-1)
            local ew=math.max(66*sc,math.min(104*sc,pad+full-px-buttonMin-4*sc))
            self.profileEdit:SetExtent(ew,24*sc); S.UI:SetAnchor(self.profileEdit,self.root,px,profileY-1*sc); px=px+ew+4*sc
        end
        local buttons={self.nextProfile,self.saveProfile,self.applyProfile,self.deleteProfile}
        local remain=math.max(1,pad+full-px); local bgap=4*sc; local bw=math.max(32*sc,(remain-bgap*(#buttons-1))/#buttons)
        for _,b in ipairs(buttons) do b:SetExtent(bw,24*sc); S.UI:SetAnchor(b,self.root,px,profileY-1*sc); px=px+bw+bgap end
        self:Refresh()
    end
    S.UI.pages.hud=page; return page
end
