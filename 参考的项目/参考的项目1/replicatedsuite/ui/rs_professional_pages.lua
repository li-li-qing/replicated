------------------------------------------------------------------------
-- Replicated Suite - Professional module pages
-- Author: Replicated
--
-- The Suite owns the settings/navigation surface. Professional domains keep
-- their own business state and persistence Authority; this file only calls
-- narrow domain facades or domain-owned mutators.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
S.ProfessionalPages = {}
local PAGES = S.ProfessionalPages

local function Export(moduleId, exportName)
    local sandbox = ReplicatedSuiteModuleSandbox
    return sandbox ~= nil and sandbox:GetExport(moduleId, exportName) or nil
end
local function Clamp(v,a,b) v=tonumber(v) or a; if v<a then return a end; if v>b then return b end; return v end
local function BoolText(v) return v==true and "开" or "关" end
local function Cycle(list,current)
    if type(list)~="table" or #list==0 then return current end
    for i,v in ipairs(list) do if v==current or tonumber(v)==tonumber(current) then return list[(i%#list)+1] end end
    return list[1]
end
local function JoinIds(ids)
    local out={}; for _,id in ipairs(ids or {}) do out[#out+1]=tostring(id) end; return table.concat(out,",")
end
local function ModuleStatus(moduleId)
    local d=S.ModuleManager and S.ModuleManager:Describe(moduleId) or nil
    if d==nil then return "未注册","red",nil end
    if d.state=="Faulted" then return "初始化失败","red",d.lastError end
    if d.enabled==true then return "运行中","green",nil end
    return "已关闭","muted",nil
end

local function ParseTitleValue(text)
    local raw = tostring(text or "")
    local left,right = raw:match("^(.-)：%s*(.+)$")
    if left ~= nil then return left,right end
    left,right = raw:match("^(.-):%s*(.+)$")
    if left ~= nil then return left,right end
    return raw,nil
end


local function ControlActionText(titleText,currentValue)
    local v=tostring(currentValue or "")
    local t=tostring(titleText or "")
    if v=="开" or v=="关" or v=="团队" or v=="附近" or v=="PVP" or v=="PVE" then return "切换" end
    if currentValue~=nil then
        -- Continuous numeric values no longer use AddControl; they use the
        -- shared horizontal slider + input row below.  Any value-bearing card
        -- left here is therefore an enum/mode selector rather than a numeric
        -- adjuster, so describe the action as a switch instead of "调整".
        return "切换"
    end
    if t:find("删除",1,true) then return "删除" end
    if t:find("保存",1,true) then return "保存" end
    if t:find("恢复",1,true) then return "恢复" end
    if t:find("刷新",1,true) or t:find("扫描",1,true) or t:find("检查",1,true) then return "执行" end
    if t:find("新增",1,true) or t:find("追加",1,true) then return "添加" end
    return "执行"
end

local function NormalizeColor(c)
    c=type(c)=="table" and c or {}
    return {r=Clamp(tonumber(c.r) or 1,0,1),g=Clamp(tonumber(c.g) or 1,0,1),b=Clamp(tonumber(c.b) or 1,0,1),a=Clamp(tonumber(c.a) or 1,0.05,1)}
end
local function Color255(c)
    c=NormalizeColor(c)
    return math.floor(c.r*255+0.5),math.floor(c.g*255+0.5),math.floor(c.b*255+0.5),math.floor(c.a*255+0.5)
end
local function ColorText(c)
    local r,g,b,a=Color255(c); return string.format("RGBA %d / %d / %d / %d",r,g,b,a)
end
local function ParseColorText(text)
    local raw=tostring(text or ""):gsub("^%s+",""):gsub("%s+$","")
    local hex=raw:match("^#?([%x]+)$")
    if hex and (#hex==6 or #hex==8) then
        local function hc(pos) return tonumber(hex:sub(pos,pos+1),16) or 0 end
        return {r=hc(1)/255,g=hc(3)/255,b=hc(5)/255,a=(#hex==8 and hc(7) or 255)/255}
    end
    local nums={}
    for n in raw:gmatch("[%d%.]+") do nums[#nums+1]=tonumber(n) end
    if #nums<3 then return nil,"请输入 #RRGGBB / #RRGGBBAA，或 R,G,B,A，例如 255,80,80,220" end
    local function channel(v,alpha)
        v=tonumber(v) or (alpha and 255 or 0)
        if v>1 then v=v/255 end
        return Clamp(v,alpha and 0.05 or 0,1)
    end
    return {r=channel(nums[1]),g=channel(nums[2]),b=channel(nums[3]),a=channel(nums[4] or 255,true)}
end

local function SetColorPreview(widget,c)
    if widget==nil then return end
    c=NormalizeColor(c)
    local bg=widget.rsBackground
    if bg and type(bg.SetColor)=="function" then pcall(function() bg:SetColor(c.r,c.g,c.b,c.a) end) end
end

local function NewPage(parent,moduleId,key,title,note,sectionDefs)
    local page={
        moduleId=moduleId,key=key,parent=parent,
        root=S.UI:CreatePanel(parent,key.."_page",0,0,100,100,"soft"),
        sections={},sectionOrder={},activeSection=sectionDefs[1] and sectionDefs[1][1] or "main",
    }
    if page.root.rsBorder and page.root.rsBorder.SetVisible then page.root.rsBorder:SetVisible(false) end
    if page.root.rsBackground and page.root.rsBackground.SetVisible then page.root.rsBackground:SetVisible(false) end
    page.navSurface=S.UI:CreatePanel(page.root,key.."_nav_surface",0,0,120,120,"card")
    page.sectionSurface=S.UI:CreatePanel(page.root,key.."_section_surface",0,0,120,120,"card")
    page.title=S.UI:CreateLabel(page.root,key.."_title",title,12,8,360,28,16,nil,ALIGN_LEFT)
    page.status=S.UI:CreateLabel(page.root,key.."_status","",380,10,160,24,11,"muted",ALIGN_RIGHT)
    page.toggle=S.UI:CreateButton(page.root,key.."_toggle","启用",0,6,72,28,10,false)
    page.retry=S.UI:CreateButton(page.root,key.."_retry","重试初始化",0,6,92,28,9,false)
    page.note=S.UI:CreateLabel(page.root,key.."_note",note,12,40,720,32,9,"muted",ALIGN_LEFT)
    page.error=S.UI:CreateLabel(page.root,key.."_error","",12,72,720,32,9,"red",ALIGN_LEFT)
    page.sectionTitle=S.UI:CreateLabel(page.root,key.."_section_title","",0,0,200,26,14,nil,ALIGN_LEFT)
    page.sectionHint=S.UI:CreateLabel(page.root,key.."_section_hint","当前页面所有设置都在右侧面板中完成，无需再打开旧独立窗口。",0,0,200,22,9,"muted",ALIGN_LEFT)

    for _,def in ipairs(sectionDefs or {}) do
        local id,label=def[1],def[2]
        local sec={id=id,label=label,widgets={},controls={},numerics={},infos={},custom={}}
        -- Sub-tabs use the same gradient skin as the main-window tabs; the
        -- active one is highlighted through SetButtonActive instead of the old
        -- "◆" prefix + disable-on-select behaviour (which made the selected tab
        -- look greyed-out and therefore "disabled" to the user).
        sec.tab=S.UI:CreateButton(page.root,key.."_subtab_"..id,label,0,0,90,28,9,id==page.activeSection,true)
        page.sections[id]=sec; page.sectionOrder[#page.sectionOrder+1]=sec
        S.UI:SafeHandler(sec.tab,"OnClick",function() page:SetSection(id) end,key..":section:"..id)
    end

    S.UI:SafeHandler(page.toggle,"OnClick",function()
        if S.ModuleManager then
            local ok,err=S.ModuleManager:SetEnabled(moduleId,not S.ModuleManager:IsEnabled(moduleId))
            if ok~=true then S.SafeChat(title.." 切换失败："..tostring(err or "未知原因")) end
        end
        page:Refresh()
    end,key..":toggle")
    S.UI:SafeHandler(page.retry,"OnClick",function()
        if S.ModuleManager then
            local ok,err=S.ModuleManager:Retry(moduleId)
            if ok~=true then S.SafeChat(title.." 重试失败："..tostring(err or "未知原因")) end
        end
        page:Refresh()
    end,key..":retry")

    function page:RegisterWidget(sectionId,widget)
        local sec=self.sections[sectionId]; if sec and widget then sec.widgets[#sec.widgets+1]=widget end
        return widget
    end
    function page:AddInfo(sectionId,id,textFn,tone)
        -- Scope generated widget ids by sub-page. Semantic ids such as
        -- "mode", "save" and "emergency" are intentionally reusable in
        -- different sections, but physical/logical widget ids must be unique.
        local widgetKey=key.."_"..tostring(sectionId or "main")
        local panel=S.UI:CreatePanel(self.root,widgetKey.."_info_panel_"..id,0,0,100,26,"card")
        local label=S.UI:CreateLabel(self.root,widgetKey.."_info_"..id,"",0,0,100,22,9,tone or "muted",ALIGN_LEFT)
        self:RegisterWidget(sectionId,panel); self:RegisterWidget(sectionId,label)
        local sec=self.sections[sectionId]; sec.infos[#sec.infos+1]={panel=panel,widget=label,text=textFn}
        return label
    end
    function page:AddControl(sectionId,id,textFn,clickFn)
        local widgetKey=key.."_"..tostring(sectionId or "main")
        local panel=S.UI:CreatePanel(self.root,widgetKey.."_ctlpanel_"..id,0,0,180,36,"card")
        local titleLabel=S.UI:CreateLabel(self.root,widgetKey.."_ctltitle_"..id,"",0,0,160,18,10,nil,ALIGN_LEFT)
        local subLabel=S.UI:CreateLabel(self.root,widgetKey.."_ctlsub_"..id,"",0,0,160,16,8,"muted",ALIGN_LEFT)
        local button=S.UI:CreateButton(self.root,widgetKey.."_ctl_"..id,"",0,0,120,28,9,false)
        self:RegisterWidget(sectionId,panel); self:RegisterWidget(sectionId,titleLabel); self:RegisterWidget(sectionId,subLabel); self:RegisterWidget(sectionId,button)
        local sec=self.sections[sectionId]
        sec.controls[#sec.controls+1]={id=id,panel=panel,title=titleLabel,sub=subLabel,button=button,text=textFn}
        S.UI:SafeHandler(button,"OnClick",function()
            local ok,err=xpcall(clickFn,S.SafeTraceback)
            if not ok then S.SafeChat(title.." 设置失败："..tostring(err)) end
            self:Refresh()
        end,key..":"..tostring(sectionId or "main")..":"..id)
        return button
    end
    function page:AddNumericControl(sectionId,id,label,minv,maxv,step,getter,setter,opts)
        opts=type(opts)=="table" and opts or {}
        local sec=self.sections[sectionId]; if sec==nil then return nil end
        local widgetKey=key.."_"..tostring(sectionId or "main")
        local row={
            id=id,labelText=tostring(label or id),minimum=tonumber(minv) or 0,maximum=tonumber(maxv) or 100,
            step=math.abs(tonumber(step) or 1),getter=getter,setter=setter,
            integer=opts.integer==true,suffix=tostring(opts.suffix or ""),format=opts.format,
        }
        if row.maximum<row.minimum then row.minimum,row.maximum=row.maximum,row.minimum end
        row.panel=S.UI:CreatePanel(self.root,widgetKey.."_numpanel_"..id,0,0,180,42,"card")
        row.title=S.UI:CreateLabel(self.root,widgetKey.."_numtitle_"..id,row.labelText,0,0,110,20,9,nil,ALIGN_LEFT)
        row.minus=S.UI:CreateButton(self.root,widgetKey.."_numminus_"..id,"-",0,0,24,22,9,false)
        row.slider=S.UI.CreateSlider and S.UI:CreateSlider(self.root,widgetKey.."_numslider_"..id,0,0,110,20,row.minimum,row.maximum,row.step,row.minimum) or nil
        row.edit=S.UI:CreateEditBox(self.root,widgetKey.."_numedit_"..id,0,0,52,22,16)
        row.readout=S.UI:CreateLabel(self.root,widgetKey.."_numreadout_"..id,"",0,0,52,20,9,"muted",ALIGN_CENTER)
        row.plus=S.UI:CreateButton(self.root,widgetKey.."_numplus_"..id,"+",0,0,24,22,9,false)
        row.apply=S.UI:CreateButton(self.root,widgetKey.."_numapply_"..id,"应用",0,0,42,22,8,false)
        for _,w in ipairs({row.panel,row.title,row.minus,row.slider,row.readout,row.plus,row.apply}) do self:RegisterWidget(sectionId,w) end
        if row.edit then self:RegisterWidget(sectionId,row.edit) end
        if row.readout and row.readout.Show then row.readout:Show(row.edit==nil) end
        if row.apply and row.apply.Enable then row.apply:Enable(row.edit~=nil) end

        local function decimalsForStep()
            if row.integer or row.step>=1 then return 0 end
            if row.step>=0.1 then return 1 end
            if row.step>=0.01 then return 2 end
            return 3
        end
        local function normalize(v)
            v=tonumber(v); if v==nil then return nil end
            if row.step>0 then v=row.minimum+math.floor(((v-row.minimum)/row.step)+0.5)*row.step end
            if v<row.minimum then v=row.minimum end; if v>row.maximum then v=row.maximum end
            if row.integer then v=math.floor(v+0.5) end
            return v
        end
        local function display(v)
            v=tonumber(v) or row.minimum
            if type(row.format)=="function" then
                local ok,text=pcall(row.format,v); if ok and text~=nil then return tostring(text) end
            end
            local d=decimalsForStep()
            if d==0 then return tostring(math.floor(v+0.5)) end
            local text=string.format("%."..tostring(d).."f",v)
            text=text:gsub("0+$",""):gsub("%.$","")
            return text
        end
        row.Normalize=normalize; row.Display=display
        local function updateVisual(v)
            v=normalize(v); if v==nil then return end
            row.pending=v
            local text=display(v)
            if row.edit and row.edit.SetText then row.edit:SetText(text) end
            if row.readout and row.readout.SetText then row.readout:SetText(text..row.suffix) end
            if row.slider and row.slider.SetValue then pcall(function() row.slider:SetValue(v,false) end) end
            if row.slider and S.UI.UpdateSliderVisual then S.UI:UpdateSliderVisual(row.slider,v) end
        end
        local function commit(v)
            v=normalize(v); if v==nil then S.SafeChat(row.labelText.."：请输入数字。","warning",moduleId); return false end
            local ok,r1,r2=xpcall(function() return setter(v) end,S.SafeTraceback)
            if not ok then S.SafeChat(title.." 设置失败："..tostring(r1),"warning",moduleId); return false end
            if r1==false then S.SafeChat(row.labelText.." 设置失败："..tostring(r2 or "参数被拒绝"),"warning",moduleId); return false end
            row.pending=nil
            self:Refresh()
            return true
        end
        S.UI:SafeHandler(row.minus,"OnClick",function()
            local base=row.pending
            if base==nil then local ok,v=pcall(getter); if ok then base=tonumber(v) end end
            commit((base or row.minimum)-row.step)
        end,key..":"..tostring(sectionId)..":num_minus:"..id)
        S.UI:SafeHandler(row.plus,"OnClick",function()
            local base=row.pending
            if base==nil then local ok,v=pcall(getter); if ok then base=tonumber(v) end end
            commit((base or row.minimum)+row.step)
        end,key..":"..tostring(sectionId)..":num_plus:"..id)
        S.UI:SafeHandler(row.apply,"OnClick",function()
            if row.edit and row.edit.GetText then commit(tonumber(row.edit:GetText())) end
        end,key..":"..tostring(sectionId)..":num_apply:"..id)
        if row.slider and type(row.slider.SetValueChangedHandler)=="function" then
            -- Professional settings often persist in their owning Domain.  Do not
            -- write storage every 50 ms while dragging: preview the number/knob
            -- locally, then cross the Domain commit fence once on drag stop.
            row.slider:SetValueChangedHandler(function(rawValue,final)
                local v=normalize(rawValue); if v==nil then return end
                row.pending=v
                local text=display(v)
                if row.edit and row.edit.SetText then row.edit:SetText(text) end
                if row.readout and row.readout.SetText then row.readout:SetText(text..row.suffix) end
                if final==true then commit(v) end
            end)
        end
        sec.numerics[#sec.numerics+1]=row
        return row
    end
    function page:AddEditAction(sectionId,id,placeholder,maxLength,buttonText,fn,allowWithoutEdit)
        local widgetKey=key.."_"..tostring(sectionId or "main")
        local panel=S.UI:CreatePanel(self.root,widgetKey.."_editpanel_"..id,0,0,180,40,"card")
        local caption=S.UI:CreateLabel(self.root,widgetKey.."_editcaption_"..id,buttonText,0,0,180,18,10,nil,ALIGN_LEFT)
        local edit=S.UI:CreateEditBox(self.root,widgetKey.."_edit_"..id,0,0,180,27,maxLength or 64)
        local missing=S.UI:CreateLabel(self.root,widgetKey.."_editmissing_"..id,"当前客户端不支持文本输入框。",0,0,180,18,8,"muted",ALIGN_LEFT)
        local button=S.UI:CreateButton(self.root,widgetKey.."_editbtn_"..id,buttonText,0,0,96,27,9,false)
        self:RegisterWidget(sectionId,panel); self:RegisterWidget(sectionId,caption); self:RegisterWidget(sectionId,missing); self:RegisterWidget(sectionId,button)
        if edit then self:RegisterWidget(sectionId,edit) end
        if button.Enable then button:Enable(edit~=nil or allowWithoutEdit==true) end
        local sec=self.sections[sectionId]
        sec.custom[#sec.custom+1]={id=id,kind="edit",panel=panel,caption=caption,missing=missing,edit=edit,button=button,placeholder=placeholder,fn=fn}
        S.UI:SafeHandler(button,"OnClick",function()
            local text=edit and edit.GetText and tostring(edit:GetText() or "") or ""
            local ok,err=xpcall(function() return fn(text,edit) end,S.SafeTraceback)
            if not ok then S.SafeChat(title.." 设置失败："..tostring(err)) end
            self:Refresh()
        end,key..":"..tostring(sectionId or "main")..":edit:"..id)
        return edit,button
    end
    function page:HideInactiveSections()
        for _,sec in ipairs(self.sectionOrder or {}) do
            if sec.id~=self.activeSection then
                for _,w in ipairs(sec.widgets or {}) do if w and w.Show then w:Show(false) end end
            end
        end
    end
    function page:SetSection(id, reflow)
        if self.sections[id]==nil then return false end
        self.activeSection=id
        for _,sec in ipairs(self.sectionOrder) do
            local active=sec.id==id
            -- Gradient highlight marks the selected tab; text stays plain (no
            -- "◆" prefix).  Keep the selected tab enabled so it never renders
            -- with the disabled/greyed-out background, which read as "off".
            if sec.tab.Enable then sec.tab:Enable(true) end
            S.Theme:SetButtonActive(sec.tab, active)
            for _,w in ipairs(sec.widgets) do if w and w.Show then w:Show(active) end end
        end
        local activeSec=self.sections[id]
        if activeSec then
            self.sectionTitle:SetText(activeSec.label)
        end
        self:Refresh()
        if reflow ~= false and self.lastSpec then self:ApplyLayout(self.lastSpec) end
        return true
    end
    function page:RefreshBase()
        local text,tone,err=ModuleStatus(moduleId)
        self.status:SetText(text); S.Theme:SetLabelTone(self.status,tone)
        local enabled=S.ModuleManager and S.ModuleManager:IsEnabled(moduleId)
        self.toggle:SetText(enabled and "关闭模块" or "启用模块")
        self.retry:Show(err~=nil); self.error:SetText(err and ("错误："..tostring(err)) or ""); self.error:Show(err~=nil)
    end
    function page:RefreshGeneric()
        for _,sec in ipairs(self.sectionOrder) do
            for _,it in ipairs(sec.controls) do
                local ok,text=pcall(it.text)
                local left,right=ParseTitleValue(ok and tostring(text or "") or "状态不可用")
                if it.title then it.title:SetText(left or "") end
                if it.sub then it.sub:SetText(right and ("当前："..right) or "点击右侧执行操作") end
                it.button:SetText(ControlActionText(left,right))
            end
            for _,row in ipairs(sec.numerics or {}) do
                local dragging=row.slider and row.slider.rsDragging==true
                if not dragging then
                    local ok,value=pcall(row.getter)
                    local valid=ok and tonumber(value)~=nil
                    if valid then
                        value=row.Normalize(value)
                        row.pending=nil
                        local text=row.Display(value)
                        if row.edit and row.edit.SetText and sec.id==self.activeSection then row.edit:SetText(text) end
                        if row.readout and row.readout.SetText then row.readout:SetText(text..row.suffix) end
                        if row.slider and row.slider.SetValue then pcall(function() row.slider:SetValue(value,false) end) end
                        if row.slider and S.UI.UpdateSliderVisual then S.UI:UpdateSliderVisual(row.slider,value) end
                    end
                    if row.slider and row.slider.SetEnabled then row.slider:SetEnabled(valid) end
                    for _,button in ipairs({row.minus,row.plus,row.apply}) do if button and button.Enable then button:Enable(valid and (button~=row.apply or row.edit~=nil)) end end
                end
                if row.title then row.title:SetText(row.labelText..(row.suffix~="" and (" ("..row.suffix..")") or "")) end
            end
            for _,it in ipairs(sec.infos) do
                local ok,text=pcall(it.text)
                it.widget:SetText(ok and tostring(text or "") or "")
            end
        end
    end
    function page:ApplyBase(spec)
        self.lastSpec=spec
        S.UI:SetAnchor(self.root,parent,0,0); self.root:SetExtent(spec.contentWidth,spec.contentHeight)
        local sc=S.Layout:GetContext().addonScale; local pad=12*sc; local full=math.max(1,spec.contentWidth-pad*2)
        local headerGap=4*sc
        local toggleW=88*sc
        local retryW=96*sc
        local statusW=math.max(92*sc,math.min(134*sc,full*0.23))
        local titleW=math.max(80*sc,full-toggleW-retryW-statusW-headerGap*3)
        self.title:SetExtent(titleW,28*sc); S.UI:SetAnchor(self.title,self.root,pad,6*sc)
        local x=pad+titleW+headerGap
        self.status:SetExtent(statusW,24*sc); S.UI:SetAnchor(self.status,self.root,x,9*sc); x=x+statusW+headerGap
        self.retry:SetExtent(retryW,28*sc); S.UI:SetAnchor(self.retry,self.root,x,6*sc); x=x+retryW+headerGap
        self.toggle:SetExtent(toggleW,28*sc); S.UI:SetAnchor(self.toggle,self.root,x,6*sc)
        self.note:SetExtent(full,30*sc); S.UI:SetAnchor(self.note,self.root,pad,39*sc)
        self.error:SetExtent(full,30*sc); S.UI:SetAnchor(self.error,self.root,pad,70*sc)

        local bodyTop=(self.error and self.error:IsVisible() and 100*sc or 92*sc)
        local bodyH=math.max(1,spec.contentHeight-bodyTop-pad)
        local hideNav=self.hideSectionNav==true
        local navW=hideNav and 0 or math.max(96*sc,math.min(118*sc,full*0.18))
        local gap=hideNav and 0 or 10*sc
        local contentX=pad+navW+gap
        local contentW=math.max(1,full-navW-gap)
        self.contentPad=contentX
        self.contentWidth=contentW
        self.contentTop=bodyTop+38*sc
        self.contentBottom=spec.contentHeight-pad

        self.navSurface:Show(not hideNav)
        if not hideNav then
            self.navSurface:SetExtent(navW,bodyH)
            S.UI:SetAnchor(self.navSurface,self.root,pad,bodyTop)
        end
        self.sectionSurface:SetExtent(contentW,bodyH)
        S.UI:SetAnchor(self.sectionSurface,self.root,contentX,bodyTop)
        self.sectionTitle:SetExtent(contentW-24*sc,24*sc); S.UI:SetAnchor(self.sectionTitle,self.root,contentX+12*sc,bodyTop+10*sc)
        self.sectionHint:SetExtent(contentW-24*sc,18*sc); S.UI:SetAnchor(self.sectionHint,self.root,contentX+12*sc,bodyTop+30*sc)
        local contentOpacity=tonumber(S.State and S.State.settings and S.State.settings.contentOpacity) or 1.0
        S.Theme:SetBackgroundOpacity(self.navSurface,contentOpacity)
        S.Theme:SetBackgroundOpacity(self.sectionSurface,contentOpacity)
        -- Content-background transparency intentionally fades owned panels and
        -- button skins while leaving labels/icons fully opaque. This is the
        -- useful mode for tuning HUDs over the live character view.
        for _,sec in ipairs(self.sectionOrder or {}) do
            for _,w in ipairs(sec.widgets or {}) do S.Theme:SetBackgroundOpacity(w,contentOpacity) end
        end

        local tabGap=5*sc
        local tabH=28*sc
        local navInnerW=math.max(1,navW-12*sc)
        local tabY=bodyTop+8*sc
        local visibleIndex=0
        for _,sec in ipairs(self.sectionOrder) do
            local navVisible=not hideNav and sec.navHidden~=true
            sec.tab:Show(navVisible)
            if navVisible then
                sec.tab:SetExtent(navInnerW,tabH)
                S.UI:SetAnchor(sec.tab,self.root,pad+6*sc,tabY+visibleIndex*(tabH+tabGap))
                visibleIndex=visibleIndex+1
            end
        end
        return sc,contentX+12*sc,contentW-24*sc,bodyTop+56*sc
    end
    function page:LayoutGenericSection(sectionId,top,cols,maxRows)
        local sec=self.sections[sectionId]; if not sec then return top end
        local sc=S.Layout:GetContext().addonScale
        local pad=self.contentPad or 12*sc
        local full=self.contentWidth or math.max(1,(self.lastSpec and self.lastSpec.contentWidth or 600)-pad*2)
        local gap=10*sc
        local y=top
        for _,it in ipairs(sec.infos) do
            if it.panel then it.panel:SetExtent(full,30*sc); S.UI:SetAnchor(it.panel,self.root,pad,y-2*sc) end
            it.widget:SetExtent(full-16*sc,22*sc); S.UI:SetAnchor(it.widget,self.root,pad+8*sc,y+2*sc)
            y=y+34*sc
        end
        local numericCols=(full>=620*sc) and math.min(2,cols or 2) or 1
        if #(sec.numerics or {})>0 then
            local cellGap=8*sc
            local cellW=numericCols==1 and full or math.max(260*sc,(full-cellGap*(numericCols-1))/numericCols)
            local cardH=42*sc
            for i,row in ipairs(sec.numerics or {}) do
                local rr=math.floor((i-1)/numericCols); local cc=(i-1)%numericCols
                local xx=pad+cc*(cellW+cellGap); local yy=y+rr*(cardH+cellGap)
                if row.panel then row.panel:SetExtent(cellW,cardH); S.UI:SetAnchor(row.panel,self.root,xx,yy) end
                local labelW=math.max(86*sc,math.min(116*sc,cellW*0.28))
                local minusW,editW,plusW,applyW,g=24*sc,52*sc,24*sc,42*sc,3*sc
                local rightW=minusW+editW+plusW+applyW+g*3
                local sliderW=math.max(70*sc,cellW-labelW-rightW-22*sc)
                row.title:SetExtent(labelW,20*sc); S.UI:SetAnchor(row.title,self.root,xx+8*sc,yy+11*sc)
                if row.slider then
                    row.slider:SetExtent(sliderW,20*sc); S.UI:SetAnchor(row.slider,self.root,xx+8*sc+labelW,yy+11*sc)
                    if S.UI.UpdateSliderVisual then
                        local visualValue=row.pending
                        if visualValue==nil and row.slider.GetValue then visualValue=row.slider:GetValue() end
                        S.UI:UpdateSliderVisual(row.slider,visualValue or row.minimum)
                    end
                end
                local bx=xx+cellW-rightW-7*sc
                row.minus:SetExtent(minusW,22*sc); S.UI:SetAnchor(row.minus,self.root,bx,yy+10*sc); bx=bx+minusW+g
                if row.edit then row.edit:SetExtent(editW,22*sc); S.UI:SetAnchor(row.edit,self.root,bx,yy+10*sc); if row.readout then row.readout:Show(false) end
                else row.readout:SetExtent(editW,20*sc); S.UI:SetAnchor(row.readout,self.root,bx,yy+11*sc); row.readout:Show(true) end
                bx=bx+editW+g
                row.plus:SetExtent(plusW,22*sc); S.UI:SetAnchor(row.plus,self.root,bx,yy+10*sc); bx=bx+plusW+g
                row.apply:SetExtent(applyW,22*sc); S.UI:SetAnchor(row.apply,self.root,bx,yy+10*sc)
            end
            y=y+math.ceil(#sec.numerics/numericCols)*(cardH+cellGap)
        end
        for _,it in ipairs(sec.custom) do
            if it.kind=="edit" then
                if it.panel then it.panel:SetExtent(full,54*sc); S.UI:SetAnchor(it.panel,self.root,pad,y) end
                it.caption:SetExtent(full-16*sc,18*sc); S.UI:SetAnchor(it.caption,self.root,pad+8*sc,y+6*sc)
                local rowY=y+24*sc
                local bw=112*sc
                if it.edit then
                    local ew=math.max(120*sc,full-bw-24*sc)
                    it.edit:SetExtent(ew,27*sc); S.UI:SetAnchor(it.edit,self.root,pad+8*sc,rowY)
                    it.button:SetExtent(bw,27*sc); S.UI:SetAnchor(it.button,self.root,pad+full-bw-8*sc,rowY)
                    if it.missing then it.missing:Show(false) end
                else
                    if it.missing then it.missing:SetExtent(full-bw-24*sc,18*sc); S.UI:SetAnchor(it.missing,self.root,pad+8*sc,rowY+4*sc); it.missing:Show(true) end
                    it.button:SetExtent(bw,27*sc); S.UI:SetAnchor(it.button,self.root,pad+full-bw-8*sc,rowY)
                end
                y=y+60*sc
            end
        end
        cols=cols or 2
        if full < 420*sc then cols = 1 end
        local cellW=cols==1 and full or math.max(160*sc,(full-gap*(cols-1))/cols)
        local cardH=42*sc
        for i,it in ipairs(sec.controls) do
            local row=math.floor((i-1)/cols)
            local col=(i-1)%cols
            local xx=pad+col*(cellW+gap)
            local yy=y+row*(cardH+gap)
            if it.panel then it.panel:SetExtent(cellW,cardH); S.UI:SetAnchor(it.panel,self.root,xx,yy) end
            if it.title then it.title:SetExtent(cellW-126*sc,16*sc); S.UI:SetAnchor(it.title,self.root,xx+8*sc,yy+6*sc) end
            if it.sub then it.sub:SetExtent(cellW-126*sc,14*sc); S.UI:SetAnchor(it.sub,self.root,xx+8*sc,yy+22*sc) end
            it.button:SetExtent(112*sc,28*sc); S.UI:SetAnchor(it.button,self.root,xx+cellW-112*sc-8*sc,yy+7*sc)
        end
        return y+math.ceil(#sec.controls/cols)*(cardH+gap)
    end
    return page
end

function PAGES:SetSection(pageId,sectionId)
    local page=S.UI and S.UI.pages and S.UI.pages[pageId] or nil
    if page and type(page.SetSection)=="function" then return page:SetSection(sectionId) end
    return false
end

------------------------------------------------------------------------
-- DPS
------------------------------------------------------------------------
local function CommitDps(D,layout)
    if not D then return end
    if type(D.MarkConfigDirty)=="function" then D.MarkConfigDirty() end
    if layout and type(D.MarkLayoutDirty)=="function" then D.MarkLayoutDirty() end
    if type(D.MarkViewDirty)=="function" then D.MarkViewDirty() end
    if D.UI then
        if layout and type(D.UI.LayoutAll)=="function" then pcall(function() D.UI:LayoutAll() end) end
        if type(D.UI.ApplyVisibility)=="function" then pcall(function() D.UI:ApplyVisibility() end) end
        if type(D.UI.RefreshControls)=="function" then pcall(function() D.UI:RefreshControls() end) end
    end
end
function PAGES.CreateDps(parent)
    local page=NewPage(parent,"dps","dps","伤害统计",
        "统计 Domain 与设置全部保留；这里只替换旧独立设置窗口。PVP/PVE 仍按每条战斗事件独立分类。",
        {{"general","常用"},{"display","界面显示"},{"accuracy","判定准确率"},{"rules","名单/纠错"},{"advanced","性能/高级"},{"diag","诊断"}})
    local function D() return Export("dps","ReplicatedDps") end
    local function C() local d=D(); return d and d.State and d.State.config or nil end
    local function HudId(side) return side=="friendly" and "dps_friendly" or "dps_enemy" end
    local function HudVisible(side)
        local id=HudId(side)
        if S.HudManager and S.HudManager:Get(id) then return S.HudManager:IsVisible(id)==true end
        local c=C(); return c and c[side=="friendly" and "showFriendly" or "showEnemy"]==true
    end
    local function HudLocked(side)
        local id=HudId(side)
        if S.HudManager and S.HudManager:Get(id) then
            local placement=S.HudManager:GetPlacement(id)
            if placement then return placement.locked==true end
            return S.HudManager:IsLocked(id)==true
        end
        local c=C(); return c and c[side=="friendly" and "friendlyLocked" or "enemyLocked"]==true
    end
    local function Toggle(k,layout)
        local d,c=D(),C(); if not d or not c then return false,"DPS 配置未初始化" end
        if d.UI and type(d.UI.ToggleSetting)=="function" then return d.UI:ToggleSetting(k) end
        c[k]=not(c[k]==true); CommitDps(d,layout); return true
    end
    local function Step(k,values,layout) local d,c=D(),C(); if c then c[k]=Cycle(values,c[k]); CommitDps(d,layout) end end
    local function SetNumeric(k,value,layout)
        local d,c=D(),C(); if not d or not c then return false,"DPS 配置未初始化" end
        if d.UI and type(d.UI.SetNumericSetting)=="function" then return d.UI:SetNumericSetting(k,value,layout) end
        c[k]=value; CommitDps(d,layout); return true
    end
    local function RefreshDpsViews(d)
        if not d or not d.UI then return end
        if type(d.UI.RefreshQuickWindows)=="function" then d.UI:RefreshQuickWindows() end
        if type(d.UI.RefreshDetail)=="function" then d.UI:RefreshDetail() end
    end

    page:AddControl("general","scope",function()
        local c=C(); return "数据范围："..((c and c.scopeMode)=="team" and "团队" or "目标+团队")
    end,function()
        local d=D(); if not d then return end
        if d.UI and type(d.UI.ToggleScopeMode)=="function" then d.UI:ToggleScopeMode(); return end
        local c=C(); if not c then return end; c.scopeMode=c.scopeMode=="team" and "range" or "team"; CommitDps(d,false)
    end)
    page:AddControl("general","mode",function() local c=C(); return "当前模式："..tostring(c and c.currentMode or "PVP") end,function() local d,c=D(),C(); if d and c and d.UI and d.UI.SetMode then d.UI:SetMode(c.currentMode=="PVP" and "PVE" or "PVP") end end)
    page:AddControl("general","page",function() local c=C(); local m={DAMAGE="伤害",TAKEN="承伤",HEAL="治疗"}; return "当前页面："..tostring(m[c and c.currentPage] or "伤害") end,function() local d,c=D(),C(); if d and c and d.UI and d.UI.SetPage then local n=c.currentPage=="DAMAGE" and "TAKEN" or (c.currentPage=="TAKEN" and "HEAL" or "DAMAGE"); d.UI:SetPage(n) end end)
    page:AddControl("general","friendly",function() return "友军窗口："..BoolText(HudVisible("friendly")) end,function() Toggle("showFriendly",true) end)
    page:AddControl("general","enemy",function() return "敌军窗口："..BoolText(HudVisible("enemy")) end,function() Toggle("showEnemy",true) end)
    page:AddControl("general","flock",function() return "锁定友军："..BoolText(HudLocked("friendly")) end,function() Toggle("friendlyLocked",false) end)
    page:AddControl("general","elock",function() return "锁定敌军："..BoolText(HudLocked("enemy")) end,function() Toggle("enemyLocked",false) end)
    page:AddControl("general","resetpos",function() return "恢复全部 DPS UI 位置" end,function()
        local d=D(); if not d or not d.UI then return end
        if type(d.UI.ResetPositions)=="function" then d.UI:ResetPositions() end
        if S.HudManager then
            if S.HudManager:Get("dps_friendly") then S.HudManager:ResetPosition("dps_friendly") end
            if S.HudManager:Get("dps_enemy") then S.HudManager:ResetPosition("dps_enemy") end
        end
        RefreshDpsViews(d)
    end)
    page:AddControl("general","restoreclear",function() return "恢复上一次清空" end,function()
        local d=D(); if not d then return end
        if d.UI and type(d.UI.RestoreLastClearFromSettings)=="function" then d.UI:RestoreLastClearFromSettings(); return end
        if d.Stats and d.Stats.RestoreLastClear then local mode=d.Stats:RestoreLastClear(); if mode and d.Runtime and d.Runtime.RestoreClearedMode then d.Runtime:RestoreClearedMode(mode) end end
    end)

    for _,def in ipairs({
        {"compact","compactMode","简化模式",true},{"self","alwaysShowSelf","始终显示自己"},{"abbr","abbreviateNumbers","数值缩写"},{"percent","showPercent","显示占比"},
        {"suspect","showSuspect","显示推断标记"},{"pending","showPendingSummary","待确认摘要"},{"closure","showClosure","数据闭合率"},
        {"third","showThirdPartySummary","第三方摘要"},
    }) do
        local id,k,label,layout=def[1],def[2],def[3],def[4]
        page:AddControl("display",id,function() local c=C(); return label.."："..BoolText(c and c[k]) end,function() Toggle(k,layout) end)
    end
    page:AddNumericControl("display","rows","显示人数",10,150,1,function() local c=C(); return c and c.displayRows or 100 end,function(v) return SetNumeric("displayRows",math.floor(v+0.5),true) end,{integer=true,suffix="人"})
    page:AddNumericControl("display","opacity","排行榜透明度",50,100,1,function() local c=C(); return math.floor(((c and c.rankingOpacity) or 1)*100+0.5) end,function(v) return SetNumeric("rankingOpacity",v/100,true) end,{integer=true,suffix="%"})
    page:AddNumericControl("display","scale","排行榜缩放",60,120,1,function() local c=C(); return math.floor(((c and c.rankingScale) or 1)*100+0.5) end,function(v) return SetNumeric("rankingScale",v/100,true) end,{integer=true,suffix="%"})

    page:AddInfo("accuracy","policy",function() return "固定策略：数据优先收录；身份未确认先临时计入，后续由证据或人工纠错回填。" end)
    page:AddControl("accuracy","chinese",function() local c=C(); return "中文名视为 NPC："..BoolText(c and c.inferChineseNamesAsNpc) end,function() Toggle("inferChineseNamesAsNpc",false) end)
    page:AddControl("accuracy","social",function() local c=C(); return "好友/公会友军软先验："..BoolText(c and c.useSocialFriendlyPriors) end,function() Toggle("useSocialFriendlyPriors",false) end)
    page:AddInfo("accuracy","api",function() local d=D(); return d and d.Api and d.Api.GetStatusLine and d.Api:GetStatusLine() or "API 状态待 DPS 初始化" end)

    page.ruleOffset=0; page.selectedRuleId=nil; page.ruleRows={}
    for i=1,8 do
        local index=i
        local b=S.UI:CreateButton(page.root,"dps_rule_row_"..index,"",0,0,100,25,9,false); page:RegisterWidget("rules",b)
        page.ruleRows[index]={button=b,ruleId=nil}
        S.UI:SafeHandler(b,"OnClick",function() page.selectedRuleId=page.ruleRows[index].ruleId; page:Refresh() end,"dps:rule:"..index)
    end
    page.rulesPrev=S.UI:CreateButton(page.root,"dps_rules_prev","上一页",0,0,72,25,9,false); page:RegisterWidget("rules",page.rulesPrev)
    page.rulesNext=S.UI:CreateButton(page.root,"dps_rules_next","下一页",0,0,72,25,9,false); page:RegisterWidget("rules",page.rulesNext)
    page.rulesToggle=S.UI:CreateButton(page.root,"dps_rules_toggle","启用/禁用",0,0,90,25,9,false); page:RegisterWidget("rules",page.rulesToggle)
    page.rulesDelete=S.UI:CreateButton(page.root,"dps_rules_delete","删除选中",0,0,90,25,9,false); page:RegisterWidget("rules",page.rulesDelete)
    page.rulesRestore=S.UI:CreateButton(page.root,"dps_rules_restore","恢复本次忽略",0,0,100,25,9,false); page:RegisterWidget("rules",page.rulesRestore)
    page.rulesClear=S.UI:CreateButton(page.root,"dps_rules_clear","清空名单",0,0,90,25,9,false); page:RegisterWidget("rules",page.rulesClear)
    S.UI:SafeHandler(page.rulesPrev,"OnClick",function() page.ruleOffset=math.max(0,page.ruleOffset-8); page:Refresh() end,"dps:rules_prev")
    S.UI:SafeHandler(page.rulesNext,"OnClick",function() page.ruleOffset=page.ruleOffset+8; page:Refresh() end,"dps:rules_next")
    S.UI:SafeHandler(page.rulesToggle,"OnClick",function()
        local d=D(); if d and d.Rules and page.selectedRuleId then
            local r=d.Rules:GetById(page.selectedRuleId)
            if r then d.Rules:SetEnabled(page.selectedRuleId,r.enabled==false); RefreshDpsViews(d) end
        end
        page:Refresh()
    end,"dps:rules_toggle")
    S.UI:SafeHandler(page.rulesDelete,"OnClick",function()
        local d=D(); if not d or not d.Rules or not page.selectedRuleId then return end
        local now=S.NowMs and S.NowMs() or 0
        if tostring(page.rulesDeleteArmedId or "")~=tostring(page.selectedRuleId) or now-(tonumber(page.rulesDeleteArmedAt) or 0)>5000 then
            page.rulesDeleteArmedId=page.selectedRuleId; page.rulesDeleteArmedAt=now
            S.SafeChat("5秒内再次点击“删除选中”确认删除当前规则。")
            page:Refresh(); return
        end
        d.Rules:Remove(page.selectedRuleId); page.selectedRuleId=nil
        page.rulesDeleteArmedId=nil; page.rulesDeleteArmedAt=0; RefreshDpsViews(d); page:Refresh()
    end,"dps:rules_delete")
    S.UI:SafeHandler(page.rulesRestore,"OnClick",function()
        local d=D(); if d and d.Entities and d.Entities.ClearSessionIgnores then
            local count=d.Entities:ClearSessionIgnores(); S.SafeChat("已恢复本次运行忽略："..tostring(count or 0).." 个"); RefreshDpsViews(d)
        end
        page:Refresh()
    end,"dps:rules_restore")
    S.UI:SafeHandler(page.rulesClear,"OnClick",function()
        local d=D(); if not d or not d.Rules then return end
        local now=S.NowMs and S.NowMs() or 0
        if now-(tonumber(page.rulesClearArmedAt) or -10000)>5000 then page.rulesClearArmedAt=now; S.SafeChat("再次点击“清空名单”确认；5秒后自动取消。"); return end
        page.rulesClearArmedAt=0; d.Rules:ClearAll(); page.selectedRuleId=nil; page.ruleOffset=0; RefreshDpsViews(d); page:Refresh()
    end,"dps:rules_clear")

    local adv={
        {"personal","personalWindowMs","个人有效窗口",3000,10000,250,"ms"},
        {"side","sideWindowMs","阵营共享窗口",5000,15000,500,"ms"},
        {"ui","uiRefreshMs","UI刷新",250,2000,50,"ms"},
        {"roster","rosterScanMs","团队扫描",500,5000,100,"ms"},
        {"persist","persistenceMs","持久化周期",5000,120000,1000,"ms"},
        {"raw","rawEventLimit","原始事件缓存",100,1200,50,"条"},
    }
    for _,raw in ipairs(adv) do
        local a=raw
        page:AddNumericControl("advanced",a[1],a[3],a[4],a[5],a[6],function() local c=C(); return c and c[a[2]] or a[4] end,function(v) return SetNumeric(a[2],math.floor(v+0.5),false) end,{integer=true,suffix=a[7]})
    end
    page:AddControl("advanced","diag",function() local c=C(); return "诊断模式："..BoolText(c and c.diagnosticsEnabled) end,function() Toggle("diagnosticsEnabled",false) end)

    page:AddInfo("diag","status",function()
        local d=D(); if not d then return "DPS Domain 尚未加载" end
        local phase=d.Boot and d.Boot.phase or "?"; local ev=d.EventStore and #(d.EventStore.sessionEvents or {}) or 0
        local pending=d.EventStore and #(d.EventStore.pending or {}) or 0
        return "阶段="..tostring(phase).." · 事件="..tostring(ev).." · 待确认="..tostring(pending).." · Runtime="..BoolText(d.Runtime and d.Runtime.started)
    end)
    page:AddInfo("diag","event_transport",function()
        local d=D(); local r=d and d.Runtime; local counters=d and d.Diagnostics and d.Diagnostics.counters
        if not r then return "事件通道=未启动 · 原始事件=0" end
        return "事件通道="..tostring(r.eventTransport or "未启动").." · 原始事件="..tostring(counters and counters.rawEvents or 0)
    end)
    page:AddInfo("diag","team_identity",function()
        local d=D(); local r=d and d.Runtime; local e=d and d.Entities
        local counters=d and d.Diagnostics and d.Diagnostics.counters; local roster=0
        for _ in pairs(e and e.roster or {}) do roster=roster+1 end
        return "团队身份：布局="..tostring(r and r.teamLayoutName or "unknown")
            .." · 名单="..tostring(roster).." · 别名="..tostring(counters and counters.rosterAliasCount or 0)
            .." · 冲突="..tostring(counters and counters.rosterAliasConflicts or 0)
    end)
    page:AddControl("diag","save",function() return "立即保存 DPS 配置 / UI / 名单" end,function() local d=D(); if d and d.UI and type(d.UI.SaveNowFromSettings)=="function" then d.UI:SaveNowFromSettings() elseif d then if d.SaveConfigNow then d.SaveConfigNow() end; if d.SaveRulesNow then d.SaveRulesNow() end end end)
    page:AddControl("diag","rescan",function() return "立即扫描团队" end,function() local d=D(); if d and d.UI then if type(d.UI.PrintDiagnosticsToChat)=="function" then d.UI:PrintDiagnosticsToChat() end; if type(d.UI.RescanNowFromSettings)=="function" then d.UI:RescanNowFromSettings() elseif d.Runtime and d.Runtime.ScanRoster then d.Runtime:ScanRoster(true) end elseif d and d.Runtime then if d.Runtime.ScanRoster then d.Runtime:ScanRoster(true) end end end)
    page:AddControl("diag","repairui",function() return "刷新 / 修复 DPS HUD" end,function() local d=D(); if d and d.UI and type(d.UI.RepairHudFromSettings)=="function" then d.UI:RepairHudFromSettings() elseif d and d.UI then if d.UI.LayoutAll then d.UI:LayoutAll() end; if d.UI.RefreshControls then d.UI:RefreshControls() end end end)
    page:AddControl("diag","shardaudit",function() return "分片安全检查" end,function() local d=D(); if d and d.PersistenceSwitch and d.PersistenceSwitch.BeginSafetyAudit then local ok,msg=d.PersistenceSwitch:BeginSafetyAudit("SUITE_UI"); S.SafeChat(ok and "已启动分片安全检查。" or ("未启动分片检查："..tostring(msg or "未知原因"))) end end)
    page:AddControl("diag","shardclear",function() return "清理分片缓存（需二次确认）" end,function() local d=D(); if d and d.PersistenceSwitch and d.PersistenceSwitch.RequestClearShardStorage then local ok,state=d.PersistenceSwitch:RequestClearShardStorage(); if ok then S.SafeChat("已开始分帧清理分片缓存；主/备统计不会删除。") elseif state=="CONFIRM_AGAIN" then S.SafeChat("危险操作：8秒内再次点击确认。") else S.SafeChat("无法清理分片缓存："..tostring(state or "未知原因")) end end end)

    function page:Refresh()
        self:RefreshBase(); self:RefreshGeneric()
        local d=D(); local rules=d and d.Rules and d.Rules:List() or {}; self.ruleOffset=math.min(self.ruleOffset,math.max(0,math.floor(math.max(0,#rules-1)/8)*8))
        for i,row in ipairs(self.ruleRows) do local r=rules[self.ruleOffset+i]; row.ruleId=r and r.ruleId or nil
            if r then local selected=tostring(self.selectedRuleId)==tostring(r.ruleId) and "[选] " or ""; local state=r.enabled==false and "[关] " or "[开] "; local typeText=r.kind or r.relation or (r.ignored and "忽略") or "规则"; row.button:SetText(selected..state..tostring(r.displayName or r.matchValue).." · "..tostring(typeText)); row.button:Show(self.activeSection=="rules") else row.button:SetText(""); row.button:Show(false) end end
        if self.rulesPrev and self.rulesPrev.Enable then self.rulesPrev:Enable(self.ruleOffset>0) end
        if self.rulesNext and self.rulesNext.Enable then self.rulesNext:Enable(self.ruleOffset+#self.ruleRows<#rules) end
        local hasRule=self.selectedRuleId~=nil
        if self.rulesToggle and self.rulesToggle.Enable then self.rulesToggle:Enable(hasRule) end
        if self.rulesDelete then
            local now=S.NowMs and S.NowMs() or 0
            if tostring(self.rulesDeleteArmedId or "")~=tostring(self.selectedRuleId or "") or now-(tonumber(self.rulesDeleteArmedAt) or 0)>5000 then
                self.rulesDeleteArmedId=nil; self.rulesDeleteArmedAt=0
            end
            self.rulesDelete:SetText((tonumber(self.rulesDeleteArmedAt) or 0)>0 and "再点删除" or "删除选中")
            if self.rulesDelete.Enable then self.rulesDelete:Enable(hasRule) end
        end
    end
    function page:ApplyLayout(spec)
        local sc,pad,full,top=self:ApplyBase(spec)
        if self.activeSection=="rules" then
            local y=top; for i,row in ipairs(self.ruleRows) do row.button:SetExtent(full,25*sc); S.UI:SetAnchor(row.button,self.root,pad,y+(i-1)*29*sc) end
            local ay=y+8*29*sc+6*sc; local buttons={self.rulesPrev,self.rulesNext,self.rulesToggle,self.rulesDelete,self.rulesRestore,self.rulesClear}; local gap=5*sc; local w=(full-gap*(#buttons-1))/#buttons
            for i,b in ipairs(buttons) do b:SetExtent(w,25*sc); S.UI:SetAnchor(b,self.root,pad+(i-1)*(w+gap),ay) end
        else self:LayoutGenericSection(self.activeSection,top,2) end
        self:Refresh(); self:HideInactiveSections()
    end
    S.UI.pages.dps=page; return page
end

------------------------------------------------------------------------
-- Healer
------------------------------------------------------------------------
function PAGES.CreateHealer(parent)
    local page=NewPage(parent,"healer","healer","治疗辅助",
        "状态条件采用简单条件组：启用组、添加状态 ID、设置颜色；命中组内任意状态后显示该颜色。",
        {{"basic","常用"},{"score","救援评分"},{"colors","颜色"},{"buffs","BUFF条件组"},{"observe","实时观察"},{"rules","条件规则"},{"team","团队显示"},{"roles","职责覆盖"},{"cal","位置校准"}})
    page.sections.observe.navHidden=true
    page.sections.rules.navHidden=true
    local function H() return Export("healer","ReplicatedHealerModule") end
    local function Get(k,f) local h=H(); local v=h and h.GetSuiteSetting and h:GetSuiteSetting(k); if v==nil then return f end; return v end
    local function Set(k,v) local h=H(); if h and h.SetSuiteSetting then local ok,err=h:SetSuiteSetting(k,v); if ok==false and err then S.SafeChat("治疗设置失败："..tostring(err)) end; return ok,err end; return false,"治疗模块未初始化" end
    local function T(k,f) Set(k,not(Get(k,f)==true)) end
    local function C(k,list,f) Set(k,Cycle(list,Get(k,f))) end
    for _,a in ipairs({
        {"dist","maxDistance","最大治疗距离",1,100,1,27,"m"},{"enter","enterThreshold","进入候选血量",1,100,1,100,"%"},
        {"exit","exitThreshold","退出候选血量",1,100,1,100,"%"},{"self","selfThreshold","自己警戒血量",1,100,1,70,"%"},
        {"emergency","emergencyThreshold","紧急血量",1,100,1,50,"%"},{"low","lowHealthThreshold","低血量",1,100,1,70,"%"},
        {"healthscan","healthScanMs","血量扫描",100,1000,50,150,"ms"},{"buffscan","buffScanMs","Buff扫描",200,2000,50,300,"ms"},
        {"hold","minHoldMs","候选保持",0,5000,50,500,"ms"},{"lead","scoreLead","评分领先切换",0,50,1,5,""},
    }) do
        local item=a
        page:AddNumericControl("basic",item[1],item[3],item[4],item[5],item[6],function() return Get(item[2],item[7]) end,function(v) return Set(item[2],v) end,{integer=true,suffix=item[8]})
    end
    page:AddControl("basic","prox",function() return "治疗范围底色："..BoolText(Get("proximityMode",true)) end,function() T("proximityMode",true) end)
    page:AddControl("basic","hcurve",function() return "血量曲线：模式 "..tostring(Get("healthCurveMode",2)) end,function() C("healthCurveMode",{1,2,3,4},2) end)
    page:AddControl("basic","haccel",function() return "血量加速：模式 "..tostring(Get("healthAccelMode",2)) end,function() C("healthAccelMode",{1,2,3,4},2) end)
    page:AddControl("basic","dcurve",function() return "距离曲线：模式 "..tostring(Get("distanceCurveMode",2)) end,function() C("distanceCurveMode",{1,2,3,4},2) end)

    -- Rescue-score weights / level thresholds were historically hidden in the
    -- old advanced popup. They are first-class Suite settings now.
    for _,raw in ipairs({
        {"whealth","health","血量权重"},{"wdistance","distance","距离权重"},{"wmissing","missing","缺失血量权重"},{"wprotect","unprotected","未保护权重"},
    }) do
        local item=raw
        page:AddNumericControl("score",item[1],item[3],0,100,1,function() local h=H(); return h and h.GetSuiteWeight and h:GetSuiteWeight(item[2]) or 0 end,function(v) local h=H(); return h and h.SetSuiteWeight and h:SetSuiteWeight(item[2],v) end,{integer=true,suffix="%"})
    end
    for _,raw in ipairs({
        {"attention","attention","关注等级阈值"},{"high","high","高危等级阈值"},{"emergency","emergency","紧急等级阈值"},
    }) do
        local item=raw
        page:AddNumericControl("score",item[1],item[3],1,100,1,function() local h=H(); return h and h.GetSuiteLevelThreshold and h:GetSuiteLevelThreshold(item[2]) or 1 end,function(v) local h=H(); return h and h.SetSuiteLevelThreshold and h:SetSuiteLevelThreshold(item[2],v) end,{integer=true,suffix="%"})
    end
    page.levelColorIndex=4
    page.colorTarget={kind="suite",key="proximityColor",label="治疗范围"}
    page.colorRows={}
    local levelNames={"普通","关注","高危","紧急"}
    local function ColorForTarget(t)
        local h=H(); t=t or {}
        if not h then return {r=1,g=1,b=1,a=1},"未初始化" end
        if t.kind=="suite" then return h.GetSuiteColor and h:GetSuiteColor(t.key) or nil,t.label end
        if t.kind=="level" then return h.GetSuiteLevelColor and h:GetSuiteLevelColor(page.levelColorIndex) or nil,"救援等级 · "..tostring(levelNames[page.levelColorIndex] or page.levelColorIndex) end
        if t.kind=="rule" then local list=h.GetSuiteRules and h:GetSuiteRules() or {}; local r=list[page.selectedRule or 1]; return h.GetSuiteRuleColor and h:GetSuiteRuleColor(page.selectedRule or 1) or nil,"规则 · "..tostring(r and r.name or "未选择") end
        if t.kind=="buff" then local list=h.GetTrackedBuffs and h:GetTrackedBuffs() or {}; local e=list[t.index or 0]; return e and e.color or nil,"Buff · "..tostring(e and e.name or "未选择") end
        return nil,"颜色"
    end
    local function CurrentColorTarget() return ColorForTarget(page.colorTarget or {}) end
    local function SetCurrentColor(color)
        local h=H(); local t=page.colorTarget or {}; if not h then return false end
        color=NormalizeColor(color)
        if t.kind=="suite" and h.SetSuiteColor then return h:SetSuiteColor(t.key,color) end
        if t.kind=="level" and h.SetSuiteLevelColor then return h:SetSuiteLevelColor(page.levelColorIndex,color) end
        if t.kind=="rule" and h.SetSuiteRuleColor then return h:SetSuiteRuleColor(page.selectedRule or 1,color) end
        if t.kind=="buff" and h.SetTrackedBuffColor then return h:SetTrackedBuffColor(t.index,color) end
        return false
    end
    local function AddColorRow(id,label,targetFn)
        local panel=S.UI:CreatePanel(page.root,"healer_color_panel_"..id,0,0,100,34,"card")
        local name=S.UI:CreateLabel(page.root,"healer_color_name_"..id,label,0,0,100,18,10,nil,ALIGN_LEFT)
        local value=S.UI:CreateLabel(page.root,"healer_color_value_"..id,"",0,0,100,16,8,"muted",ALIGN_LEFT)
        local swatch=S.UI:CreatePanel(page.root,"healer_color_swatch_"..id,0,0,34,26,"card",{gradient=false})
        local edit=S.UI:CreateButton(page.root,"healer_color_edit_"..id,"编辑",0,0,54,26,9,false)
        for _,w in ipairs({panel,name,value,swatch,edit}) do page:RegisterWidget("colors",w) end
        local row={panel=panel,name=name,value=value,swatch=swatch,edit=edit,targetFn=targetFn,label=label}
        page.colorRows[#page.colorRows+1]=row
        S.UI:SafeHandler(edit,"OnClick",function() page.colorTarget=targetFn(); page:Refresh() end,"healer:color:"..id)
        return row
    end
    AddColorRow("proximity","治疗范围",function() return {kind="suite",key="proximityColor",label="治疗范围"} end)
    AddColorRow("low","低血量",function() return {kind="suite",key="lowHealthColor",label="低血量"} end)
    AddColorRow("emergency","紧急状态",function() return {kind="suite",key="emergencyColor",label="紧急状态"} end)
    AddColorRow("level","救援等级",function() return {kind="level",label="救援等级"} end)
    AddColorRow("rule","规则颜色",function() return {kind="rule",label="规则颜色"} end)

    page.colorLevel=S.UI:CreateButton(page.root,"healer_color_level","救援等级",0,0,100,26,9,false); page:RegisterWidget("colors",page.colorLevel)
    page.colorRule=S.UI:CreateButton(page.root,"healer_color_rule","规则",0,0,100,26,9,false); page:RegisterWidget("colors",page.colorRule)
    S.UI:SafeHandler(page.colorLevel,"OnClick",function() page.levelColorIndex=page.levelColorIndex%4+1; if page.colorTarget.kind=="level" then page:Refresh() end end,"healer:color_level")
    S.UI:SafeHandler(page.colorRule,"OnClick",function() local h=H(); local list=h and h.GetSuiteRules and h:GetSuiteRules() or {}; if #list>0 then page.selectedRule=((page.selectedRule or 1)%#list)+1; if page.colorTarget.kind=="rule" then page:Refresh() end end end,"healer:color_rule")

    page.colorEditorPanel=S.UI:CreatePanel(page.root,"healer_color_editor",0,0,100,140,"card"); page:RegisterWidget("colors",page.colorEditorPanel)
    page.colorEditorTitle=S.UI:CreateLabel(page.root,"healer_color_editor_title","编辑颜色",0,0,100,22,12,nil,ALIGN_LEFT); page:RegisterWidget("colors",page.colorEditorTitle)
    page.colorPreview=S.UI:CreatePanel(page.root,"healer_color_preview",0,0,64,64,"card",{gradient=false}); page:RegisterWidget("colors",page.colorPreview)
    page.colorValue=S.UI:CreateLabel(page.root,"healer_color_rgba","",0,0,100,20,9,"muted",ALIGN_LEFT); page:RegisterWidget("colors",page.colorValue)
    page.colorEdit=S.UI:CreateEditBox(page.root,"healer_color_rgba_edit",0,0,180,27,40); if page.colorEdit then page:RegisterWidget("colors",page.colorEdit) end
    page.colorApply=S.UI:CreateButton(page.root,"healer_color_apply","应用 RGBA",0,0,92,27,9,false); page:RegisterWidget("colors",page.colorApply)
    page.colorHint=S.UI:CreateLabel(page.root,"healer_color_hint","支持 #FF5050 / #FF5050DD / 255,80,80,220；预设颜色会保留当前透明度。",0,0,100,18,8,"muted",ALIGN_LEFT); page:RegisterWidget("colors",page.colorHint)
    if page.colorApply.Enable then page.colorApply:Enable(page.colorEdit~=nil) end
    S.UI:SafeHandler(page.colorApply,"OnClick",function()
        if not page.colorEdit or not page.colorEdit.GetText then return end
        local c,err=ParseColorText(page.colorEdit:GetText()); if not c then S.SafeChat(err); return end
        SetCurrentColor(c); page:Refresh()
    end,"healer:color_apply")
    page.colorPresets={}
    local presets={
        {"红",{r=1.00,g=0.20,b=0.20,a=0.90}},{"深红",{r=0.70,g=0.08,b=0.12,a=0.90}},
        {"橙",{r=1.00,g=0.50,b=0.10,a=0.90}},{"琥珀",{r=1.00,g=0.68,b=0.08,a=0.90}},
        {"黄",{r=1.00,g=0.88,b=0.16,a=0.90}},{"黄绿",{r=0.65,g=0.92,b=0.20,a=0.90}},
        {"绿",{r=0.20,g=0.90,b=0.35,a=0.90}},{"青绿",{r=0.10,g=0.88,b=0.66,a=0.90}},
        {"青",{r=0.10,g=0.86,b=0.92,a=0.90}},{"天蓝",{r=0.22,g=0.72,b=1.00,a=0.90}},
        {"蓝",{r=0.25,g=0.48,b=1.00,a=0.90}},{"靛蓝",{r=0.32,g=0.25,b=0.88,a=0.90}},
        {"紫",{r=0.72,g=0.30,b=1.00,a=0.90}},{"粉",{r=1.00,g=0.36,b=0.68,a=0.90}},
        {"白",{r=1.00,g=1.00,b=1.00,a=0.90}},{"灰",{r=0.55,g=0.58,b=0.62,a=0.90}},
    }
    for i,preset in ipairs(presets) do
        local b=S.UI:CreateButton(page.root,"healer_color_preset_"..i,preset[1],0,0,42,25,8,false); page:RegisterWidget("colors",b)
        page.colorPresets[i]={button=b,color=preset[2]}
        if type(b.rsButtonBgs)=="table" then
            local c=NormalizeColor(preset[2])
            for _,bg in ipairs(b.rsButtonBgs) do if bg and type(bg.SetColor)=="function" then pcall(function() bg:SetColor(c.r,c.g,c.b,0.92) end) end end
        end
        S.UI:SafeHandler(b,"OnClick",function() local cur=CurrentColorTarget(); local c=NormalizeColor(preset[2]); c.a=NormalizeColor(cur).a; SetCurrentColor(c); page:Refresh() end,"healer:color_preset:"..i)
    end
    page.colorAlphas={}
    for i,a in ipairs({0.20,0.35,0.50,0.65,0.80,1.00}) do
        local b=S.UI:CreateButton(page.root,"healer_color_alpha_"..i,tostring(math.floor(a*100)).."%",0,0,48,25,8,false); page:RegisterWidget("colors",b)
        page.colorAlphas[i]={button=b,alpha=a}
        S.UI:SafeHandler(b,"OnClick",function() local c=NormalizeColor(CurrentColorTarget()); c.a=a; SetCurrentColor(c); page:Refresh() end,"healer:color_alpha:"..i)
    end

    local function SetHealerStatusIcon(icon,path)
        if not icon then return end
        if type(path)~="string" or path=="" then icon:SetVisible(false);return end
        pcall(function() icon:ClearAllTextures();icon:AddTexture(path);icon:SetVisible(true) end)
    end
    local function FormatHealerRemaining(ms,known)
        if known==false then return "时间未知" end
        ms=tonumber(ms);if ms==nil or ms<=0 then return "--" end
        local sec=ms/1000;if sec<60 then return string.format(sec<10 and "%.1f秒" or "%.0f秒",sec) end
        return string.format("%.1f分",sec/60)
    end
    -- Status conditions use one simple mental model:
    --   condition group -> enable -> tracked status IDs -> display color.
    -- The old direct-color list and advanced rule editor remain load-compatible
    -- in the Healer domain, but are no longer exposed as competing workflows.
    page.statusMode="groups"
    page.statusModeTabs={}
    page.conditionGroupOffset=0
    page.conditionIdOffset=0
    page.selectedRule=nil
    page.conditionCandidates={}
    page.conditionCandidateOffset=0
    page.conditionCandidateSource="状态库"
    page.conditionGroupRows={}
    page.conditionIdRows={}
    page.conditionCandidateRows={}

    page.conditionHelp=S.UI:CreateLabel(page.root,"healer_condition_help",
        "使用方法：1 新建条件组  →  2 添加 Buff / Debuff / Hidden  →  3 设置颜色。组内任意一个状态命中时，就显示这个组的颜色。",
        0,0,100,34,9,"muted",ALIGN_LEFT);page:RegisterWidget("buffs",page.conditionHelp)
    page.conditionState=S.UI:CreateLabel(page.root,"healer_condition_state","尚未创建条件组",0,0,100,22,10,nil,ALIGN_LEFT);page:RegisterWidget("buffs",page.conditionState)

    for i=1,5 do
        local index=i
        local b=S.UI:CreateButton(page.root,"healer_condition_group_"..index,"",0,0,100,28,9,false,true);page:RegisterWidget("buffs",b)
        page.conditionGroupRows[index]={button=b,ruleIndex=nil}
        S.UI:SafeHandler(b,"OnClick",function()
            local ruleIndex=page.conditionGroupRows[index].ruleIndex
            if ruleIndex then page.selectedRule=ruleIndex;page.conditionIdOffset=0;page.conditionDeleteArmedAt=0;page.conditionDeleteArmedRule=nil;page:Refresh() end
        end,"healer:condition_group:"..index)
    end
    page.conditionAdd=S.UI:CreateButton(page.root,"healer_condition_add","+ 新建条件组",0,0,100,26,9,false,true);page:RegisterWidget("buffs",page.conditionAdd)
    page.conditionToggle=S.UI:CreateButton(page.root,"healer_condition_toggle","启用 / 停用",0,0,100,26,9,false);page:RegisterWidget("buffs",page.conditionToggle)
    page.conditionUp=S.UI:CreateButton(page.root,"healer_condition_up","上移",0,0,64,26,9,false);page:RegisterWidget("buffs",page.conditionUp)
    page.conditionDown=S.UI:CreateButton(page.root,"healer_condition_down","下移",0,0,64,26,9,false);page:RegisterWidget("buffs",page.conditionDown)
    page.conditionDelete=S.UI:CreateButton(page.root,"healer_condition_delete","删除组",0,0,70,26,9,false);page:RegisterWidget("buffs",page.conditionDelete)
    page.conditionPrev=S.UI:CreateButton(page.root,"healer_condition_prev","上一页",0,0,64,24,8,false);page:RegisterWidget("buffs",page.conditionPrev)
    page.conditionNext=S.UI:CreateButton(page.root,"healer_condition_next","下一页",0,0,64,24,8,false);page:RegisterWidget("buffs",page.conditionNext)
    S.UI:SafeHandler(page.conditionAdd,"OnClick",function()
        local h=H();if not h or not h.AddSuiteColorConditionGroup then return end
        local ok,index=h:AddSuiteColorConditionGroup();if ok then page.selectedRule=index else S.SafeChat(tostring(index)) end;page:Refresh()
    end,"healer:condition_add")
    S.UI:SafeHandler(page.conditionToggle,"OnClick",function()
        local h=H();if not h or not page.selectedRule then return end
        local rules=h:GetSuiteRules() or {};local r=rules[page.selectedRule]
        if r then h:SetSuiteRuleEnabled(page.selectedRule,not r.enabled) end;page:Refresh()
    end,"healer:condition_toggle")
    S.UI:SafeHandler(page.conditionUp,"OnClick",function() local h=H();if h and page.selectedRule and h.MoveSuiteConditionGroup then local ok,target=h:MoveSuiteConditionGroup(page.selectedRule,-1);if ok then page.selectedRule=target end end;page:Refresh() end,"healer:condition_up")
    S.UI:SafeHandler(page.conditionDown,"OnClick",function() local h=H();if h and page.selectedRule and h.MoveSuiteConditionGroup then local ok,target=h:MoveSuiteConditionGroup(page.selectedRule,1);if ok then page.selectedRule=target end end;page:Refresh() end,"healer:condition_down")
    S.UI:SafeHandler(page.conditionDelete,"OnClick",function()
        local h=H();if not h or not page.selectedRule then return end
        local now=S.NowMs and S.NowMs() or 0
        if page.conditionDeleteArmedRule~=page.selectedRule or now-(tonumber(page.conditionDeleteArmedAt) or 0)>5000 then
            page.conditionDeleteArmedRule=page.selectedRule;page.conditionDeleteArmedAt=now
            page.conditionDelete:SetText("再点删除")
            S.SafeChat("5秒内再次点击删除当前 BUFF 条件组。")
            return
        end
        h:RemoveSuiteRule(page.selectedRule);page.selectedRule=nil;page.conditionIdOffset=0;page.conditionDeleteArmedAt=0;page.conditionDeleteArmedRule=nil;page:Refresh()
    end,"healer:condition_delete")
    S.UI:SafeHandler(page.conditionPrev,"OnClick",function() page.conditionGroupOffset=math.max(0,(page.conditionGroupOffset or 0)-5);page:Refresh() end,"healer:condition_prev")
    S.UI:SafeHandler(page.conditionNext,"OnClick",function() page.conditionGroupOffset=(page.conditionGroupOffset or 0)+5;page:Refresh() end,"healer:condition_next")

    page.conditionNameEdit,page.conditionNameSave=page:AddEditAction("buffs","conditionname","条件组名称",32,"保存名称",function(text)
        local h=H();if h and page.selectedRule then local ok,err=h:SetSuiteRuleName(page.selectedRule,text);if not ok then S.SafeChat(tostring(err)) end end
    end)
    page.conditionIdEdit,page.conditionIdAdd=page:AddEditAction("buffs","conditionid","输入状态 ID（Buff / Debuff / Hidden）",12,"添加到组",function(text,edit)
        local h=H();if not h or not page.selectedRule then S.SafeChat("请先新建或选择条件组");return end
        local ok,err=h:AddSuiteRuleId(page.selectedRule,text);if not ok then S.SafeChat(tostring(err)) elseif edit and edit.SetText then edit:SetText("") end
    end)

    page.conditionColorPreview=S.UI:CreatePanel(page.root,"healer_condition_color_preview",0,0,38,26,"card",{gradient=false});page:RegisterWidget("buffs",page.conditionColorPreview)
    page.conditionColorMore=S.UI:CreateButton(page.root,"healer_condition_color_more","更多颜色",0,0,80,26,9,false);page:RegisterWidget("buffs",page.conditionColorMore)
    page.conditionColorPresets={}
    local conditionColors={
        {"红",{r=1.00,g=0.20,b=0.20,a=0.90}},{"橙",{r=1.00,g=0.50,b=0.10,a=0.90}},
        {"黄",{r=1.00,g=0.88,b=0.16,a=0.90}},{"绿",{r=0.20,g=0.90,b=0.35,a=0.90}},
        {"青",{r=0.10,g=0.86,b=0.92,a=0.90}},{"蓝",{r=0.25,g=0.48,b=1.00,a=0.90}},
        {"紫",{r=0.72,g=0.30,b=1.00,a=0.90}},{"粉",{r=1.00,g=0.36,b=0.68,a=0.90}},
    }
    for i,def in ipairs(conditionColors) do
        local b=S.UI:CreateButton(page.root,"healer_condition_color_"..i,def[1],0,0,46,24,8,false);page:RegisterWidget("buffs",b)
        page.conditionColorPresets[i]={button=b,color=def[2]}
        S.UI:SafeHandler(b,"OnClick",function() local h=H();if h and page.selectedRule and h.SetSuiteRuleColor then h:SetSuiteRuleColor(page.selectedRule,def[2]);page:Refresh() end end,"healer:condition_color:"..i)
    end
    S.UI:SafeHandler(page.conditionColorMore,"OnClick",function()
        if not page.selectedRule then S.SafeChat("请先选择条件组");return end
        page.colorTarget={kind="rule",label="条件组颜色"};page:SetSection("colors")
    end,"healer:condition_color_more")

    page.conditionIdsTitle=S.UI:CreateLabel(page.root,"healer_condition_ids_title","组内追踪状态（任意一个命中即可）",0,0,100,20,10,nil,ALIGN_LEFT);page:RegisterWidget("buffs",page.conditionIdsTitle)
    page.conditionIdPrev=S.UI:CreateButton(page.root,"healer_condition_id_prev","上一页",0,0,58,22,8,false);page:RegisterWidget("buffs",page.conditionIdPrev)
    page.conditionIdNext=S.UI:CreateButton(page.root,"healer_condition_id_next","下一页",0,0,58,22,8,false);page:RegisterWidget("buffs",page.conditionIdNext)
    S.UI:SafeHandler(page.conditionIdPrev,"OnClick",function() page.conditionIdOffset=math.max(0,(page.conditionIdOffset or 0)-6);page:Refresh() end,"healer:condition_id_prev")
    S.UI:SafeHandler(page.conditionIdNext,"OnClick",function() page.conditionIdOffset=(page.conditionIdOffset or 0)+6;page:Refresh() end,"healer:condition_id_next")
    for i=1,6 do
        local index=i;local row={}
        row.panel=S.UI:CreatePanel(page.root,"healer_condition_id_panel_"..index,0,0,100,42,"card");page:RegisterWidget("buffs",row.panel)
        row.icon=row.panel.CreateIconDrawable and row.panel:CreateIconDrawable("artwork") or nil
        if row.icon then row.icon:SetExtent(30,30);row.icon:AddAnchor("TOPLEFT",row.panel,6,6);row.icon:SetVisible(false) end
        row.name=S.UI:CreateLabel(page.root,"healer_condition_id_name_"..index,"",0,0,160,17,9,nil,ALIGN_LEFT);page:RegisterWidget("buffs",row.name)
        row.meta=S.UI:CreateLabel(page.root,"healer_condition_id_meta_"..index,"",0,0,180,15,8,"muted",ALIGN_LEFT);page:RegisterWidget("buffs",row.meta)
        row.remove=S.UI:CreateButton(page.root,"healer_condition_id_remove_"..index,"移除",0,0,50,24,8,false);page:RegisterWidget("buffs",row.remove)
        page.conditionIdRows[index]=row
        S.UI:SafeHandler(row.remove,"OnClick",function() local h=H();local id=row.id;if h and page.selectedRule and id and h.RemoveSuiteRuleId then local ok,err=h:RemoveSuiteRuleId(page.selectedRule,id);if not ok and err then S.SafeChat(tostring(err)) end end;page:Refresh() end,"healer:condition_remove_id:"..index)
    end

    page.conditionSearchEdit,page.conditionSearch=page:AddEditAction("buffs","conditionsearch","搜索状态名称或 ID",40,"搜索状态库",function(text)
        local query=tostring(text or ""):gsub("^%s+",""):gsub("%s+$","")
        local found={};local seen={};local plates=Export("plates","ReplicatedPlates")
        if plates and plates.Manager and plates.Manager.SearchKnown then
            for _,effect in ipairs({"buff","debuff","hidden"}) do
                for _,e in ipairs(plates.Manager:SearchKnown(query,effect,24) or {}) do
                    local id=math.floor(tonumber(e.id) or 0)
                    if id>0 and not seen[id] then seen[id]=true;found[#found+1]={id=id,name=tostring(e.name or ("状态 "..id)),iconPath=tostring(e.iconPath or ""),source=tostring(e.effectType or effect)} end
                end
            end
        end
        local h=H();if #found==0 and tonumber(query) and h and h.ResolveSuiteStatusId then local e=h:ResolveSuiteStatusId(query);if e and tonumber(e.id) and tonumber(e.id)>0 then found[1]={id=e.id,name=e.name,iconPath=e.iconPath,source="ID解析"} end end
        table.sort(found,function(a,b) if a.name~=b.name then return a.name<b.name end return a.id<b.id end)
        page.conditionCandidates=found;page.conditionCandidateOffset=0;page.conditionCandidateSource="状态库搜索"
        if #found==0 then S.SafeChat("状态库没有找到匹配项；可以直接输入 ID 添加。") end
        page:Refresh()
    end)
    local function ScanConditionScope(scope)
        local plates=Export("plates","ReplicatedPlates")
        if not plates or not plates.Api or not plates.Api.GetEffectCatalog then
            S.SafeChat("BUFF 条件组：状态扫描服务尚未就绪。")
            return
        end
        local found,seen={},{}
        local scopeName=scope=="player" and "自身" or "当前目标"
        for _,effect in ipairs({"buff","debuff","hidden"}) do
            for _,e in ipairs(plates.Api:GetEffectCatalog(scope,effect,64,false) or {}) do
                local id=math.floor(tonumber(e.id) or 0)
                if id>0 and e.trackable~=false and not seen[id] then
                    seen[id]=true
                    found[#found+1]={
                        id=id,
                        name=tostring(e.name or ("状态 "..id)),
                        iconPath=tostring(e.iconPath or ""),
                        effectType=effect,
                        stack=tonumber(e.stack) or 1,
                        timeLeftMs=tonumber(e.timeLeftMs) or 0,
                        remainingKnown=e.remainingKnown~=false,
                    }
                    found[#found].source=scopeName.." · "..(effect=="buff" and "Buff" or (effect=="debuff" and "Debuff" or "Hidden"))
                end
            end
        end
        table.sort(found,function(a,b)
            local order={buff=1,debuff=2,hidden=3}
            local ao,bo=order[a.effectType] or 9,order[b.effectType] or 9
            if ao~=bo then return ao<bo end
            if a.name~=b.name then return a.name<b.name end
            return a.id<b.id
        end)
        page.conditionCandidates=found
        page.conditionCandidateOffset=0
        page.conditionCandidateSource=scopeName.."实时状态"
        if #found==0 then S.SafeChat("BUFF 条件组："..scopeName.."当前没有可追踪状态。") end
        page:Refresh()
    end
    page.conditionScanSelf=S.UI:CreateButton(page.root,"healer_condition_scan_self","扫描自身",0,0,84,24,8,false);page:RegisterWidget("buffs",page.conditionScanSelf)
    page.conditionScanTarget=S.UI:CreateButton(page.root,"healer_condition_scan_target","扫描当前目标",0,0,96,24,8,false);page:RegisterWidget("buffs",page.conditionScanTarget)
    S.UI:SafeHandler(page.conditionScanSelf,"OnClick",function() ScanConditionScope("player") end,"healer:condition_scan_self")
    S.UI:SafeHandler(page.conditionScanTarget,"OnClick",function() ScanConditionScope("target") end,"healer:condition_scan_target")
    page.conditionCandidateTitle=S.UI:CreateLabel(page.root,"healer_condition_candidate_title","可追踪状态",0,0,100,20,10,nil,ALIGN_LEFT);page:RegisterWidget("buffs",page.conditionCandidateTitle)
    for i=1,4 do
        local index=i;local row={}
        row.panel=S.UI:CreatePanel(page.root,"healer_condition_candidate_panel_"..index,0,0,100,42,"soft");page:RegisterWidget("buffs",row.panel)
        row.icon=row.panel.CreateIconDrawable and row.panel:CreateIconDrawable("artwork") or nil
        if row.icon then row.icon:SetExtent(30,30);row.icon:AddAnchor("TOPLEFT",row.panel,6,6);row.icon:SetVisible(false) end
        row.name=S.UI:CreateLabel(page.root,"healer_condition_candidate_name_"..index,"",0,0,160,17,9,nil,ALIGN_LEFT);page:RegisterWidget("buffs",row.name)
        row.meta=S.UI:CreateLabel(page.root,"healer_condition_candidate_meta_"..index,"",0,0,180,15,8,"muted",ALIGN_LEFT);page:RegisterWidget("buffs",row.meta)
        row.add=S.UI:CreateButton(page.root,"healer_condition_candidate_add_"..index,"加入组",0,0,58,24,8,false);page:RegisterWidget("buffs",row.add)
        page.conditionCandidateRows[index]=row
        S.UI:SafeHandler(row.add,"OnClick",function()
            local h=H();local st=row.status
            if not page.selectedRule then S.SafeChat("请先选择条件组");return end
            if not h or not st then return end
            local rules=h.GetSuiteRules and h:GetSuiteRules() or {};local r=rules[page.selectedRule]
            local exists=false
            for _,id in ipairs(r and r.ids or {}) do if tonumber(id)==tonumber(st.id) then exists=true;break end end
            local ok,err
            if exists and h.RemoveSuiteRuleId then ok,err=h:RemoveSuiteRuleId(page.selectedRule,st.id)
            elseif h.AddSuiteRuleId then ok,err=h:AddSuiteRuleId(page.selectedRule,st.id) end
            if ok==false and err then S.SafeChat(tostring(err)) end
            page:Refresh()
        end,"healer:condition_candidate:"..index)
    end
    page.conditionCandidatePrev=S.UI:CreateButton(page.root,"healer_condition_candidate_prev","上一页",0,0,66,24,8,false);page:RegisterWidget("buffs",page.conditionCandidatePrev)
    page.conditionCandidateNext=S.UI:CreateButton(page.root,"healer_condition_candidate_next","下一页",0,0,66,24,8,false);page:RegisterWidget("buffs",page.conditionCandidateNext)
    S.UI:SafeHandler(page.conditionCandidatePrev,"OnClick",function() page.conditionCandidateOffset=math.max(0,page.conditionCandidateOffset-4);page:Refresh() end,"healer:condition_candidate_prev")
    S.UI:SafeHandler(page.conditionCandidateNext,"OnClick",function() page.conditionCandidateOffset=page.conditionCandidateOffset+4;page:Refresh() end,"healer:condition_candidate_next")

    -- Suite-native on-demand observer. It replaces the old floating observer
    -- window while preserving the important "see current status -> append" flow.
    page.observeMemberIndex=1; page.observeOffset=0; page.observeStatuses={}; page.observeMembers={}; page.observeRows={}
    page.observeDiagLabel=S.UI:CreateLabel(page.root,"healer_observe_diag","扫描诊断：尚未扫描",0,0,100,22,9,"muted",ALIGN_LEFT); page:RegisterWidget("observe",page.observeDiagLabel)
    page.observeMemberLabel=S.UI:CreateLabel(page.root,"healer_observe_member","观察对象：--",0,0,100,24,10,nil,ALIGN_LEFT); page:RegisterWidget("observe",page.observeMemberLabel)
    page.observePrevMember=S.UI:CreateButton(page.root,"healer_observe_prev_member","上一成员",0,0,76,24,9,false); page:RegisterWidget("observe",page.observePrevMember)
    page.observeNextMember=S.UI:CreateButton(page.root,"healer_observe_next_member","下一成员",0,0,76,24,9,false); page:RegisterWidget("observe",page.observeNextMember)
    page.observeScan=S.UI:CreateButton(page.root,"healer_observe_scan","扫描当前状态",0,0,96,24,9,false); page:RegisterWidget("observe",page.observeScan)
    page.observePrev=S.UI:CreateButton(page.root,"healer_observe_prev","上一页",0,0,68,24,9,false); page:RegisterWidget("observe",page.observePrev)
    page.observeNext=S.UI:CreateButton(page.root,"healer_observe_next","下一页",0,0,68,24,9,false); page:RegisterWidget("observe",page.observeNext)
    for i=1,6 do
        local index=i;local row={}
        row.panel=S.UI:CreatePanel(page.root,"healer_observe_panel_"..index,0,0,100,46,"card");page:RegisterWidget("observe",row.panel)
        row.icon=row.panel.CreateIconDrawable and row.panel:CreateIconDrawable("artwork") or nil
        if row.icon then row.icon:SetExtent(34,34);row.icon:AddAnchor("TOPLEFT",row.panel,7,6);row.icon:SetVisible(false) end
        row.name=S.UI:CreateLabel(page.root,"healer_observe_name_"..index,"",0,0,180,18,10,nil,ALIGN_LEFT);page:RegisterWidget("observe",row.name)
        row.meta=S.UI:CreateLabel(page.root,"healer_observe_meta_"..index,"",0,0,220,16,8,"muted",ALIGN_LEFT);page:RegisterWidget("observe",row.meta)
        row.add=S.UI:CreateButton(page.root,"healer_observe_add_"..index,"追踪颜色",0,0,68,24,8,false);page:RegisterWidget("observe",row.add)
        row.rule=S.UI:CreateButton(page.root,"healer_observe_rule_"..index,"加入条件",0,0,68,24,8,false);page:RegisterWidget("observe",row.rule)
        page.observeRows[index]=row
        S.UI:SafeHandler(row.add,"OnClick",function() local h=H(); local st=row.status; if h and st then local ok,err=h:AddTrackedBuffId(st.id,st.name,st.iconPath); if ok==false and err then S.SafeChat(tostring(err)) end end; page:Refresh() end,"healer:observe_add:"..index)
        S.UI:SafeHandler(row.rule,"OnClick",function()
            local h=H();local st=row.status;if not h or not st then return end;local rules=h.GetSuiteRules and h:GetSuiteRules() or {}
            if #rules==0 then local ok,idx=h:AddSuiteRule(5);if not ok then S.SafeChat(tostring(idx));return end;page.selectedRule=idx end
            if h.AddSuiteRuleId then local ok,err=h:AddSuiteRuleId(page.selectedRule,st.id);if not ok then S.SafeChat(tostring(err));return end end
            page.statusMode="rules";page:SetSection("rules")
        end,"healer:observe_rule:"..index)
    end
    function page:ScanObserved(resetOffset)
        local h=H(); if not h or not h.GetSuiteObservedMembers then return end
        self.observeMembers=h:GetSuiteObservedMembers() or {}
        if #self.observeMembers==0 then self.observeStatuses={}; self.observeMemberIndex=1; self.observeOffset=0; self:Refresh(); return end
        self.observeMemberIndex=Clamp(self.observeMemberIndex,1,#self.observeMembers)
        local statuses,err=h:GetSuiteObservedStatuses(self.observeMemberIndex)
        if statuses==nil then self.observeStatuses={}; if err then S.SafeChat(tostring(err)) end else self.observeStatuses=statuses end
        if resetOffset~=false then self.observeOffset=0 end
        self:Refresh()
    end
    S.UI:SafeHandler(page.observePrevMember,"OnClick",function() page.observeMemberIndex=math.max(1,page.observeMemberIndex-1); page:ScanObserved(true) end,"healer:observe_prev_member")
    S.UI:SafeHandler(page.observeNextMember,"OnClick",function() local h=H(); local members=h and h.GetSuiteObservedMembers and h:GetSuiteObservedMembers() or {}; page.observeMemberIndex=math.min(math.max(1,#members),page.observeMemberIndex+1); page:ScanObserved(true) end,"healer:observe_next_member")
    S.UI:SafeHandler(page.observeScan,"OnClick",function() page:ScanObserved(false) end,"healer:observe_scan")
    S.UI:SafeHandler(page.observePrev,"OnClick",function() page.observeOffset=math.max(0,page.observeOffset-6); page:Refresh() end,"healer:observe_prev")
    S.UI:SafeHandler(page.observeNext,"OnClick",function() page.observeOffset=math.min(math.max(0,math.floor(math.max(0,#page.observeStatuses-1)/6)*6),page.observeOffset+6); page:Refresh() end,"healer:observe_next")

    page.ruleOffset=0; page.selectedRule=page.selectedRule or nil; page.ruleRows={}
    for i=1,6 do local index=i; local b=S.UI:CreateButton(page.root,"healer_rule_row_"..index,"",0,0,100,24,9,false); page:RegisterWidget("rules",b); page.ruleRows[index]={button=b,index=nil}; S.UI:SafeHandler(b,"OnClick",function() if page.ruleRows[index].index then page.selectedRule=page.ruleRows[index].index end; page:Refresh() end,"healer:rule:"..index) end
    page.ruleAdd=S.UI:CreateButton(page.root,"healer_rule_add","新增规则",0,0,82,24,9,false); page:RegisterWidget("rules",page.ruleAdd)
    page.ruleToggle=S.UI:CreateButton(page.root,"healer_rule_toggle","启用/禁用",0,0,82,24,9,false); page:RegisterWidget("rules",page.ruleToggle)
    page.ruleDelete=S.UI:CreateButton(page.root,"healer_rule_delete","删除规则",0,0,82,24,9,false); page:RegisterWidget("rules",page.ruleDelete)
    page.ruleUp=S.UI:CreateButton(page.root,"healer_rule_up","上移",0,0,62,24,9,false); page:RegisterWidget("rules",page.ruleUp)
    page.ruleDown=S.UI:CreateButton(page.root,"healer_rule_down","下移",0,0,62,24,9,false); page:RegisterWidget("rules",page.ruleDown)
    page.ruleCopy=S.UI:CreateButton(page.root,"healer_rule_copy","复制规则",0,0,72,24,9,false); page:RegisterWidget("rules",page.ruleCopy)
    page.ruleDefault=S.UI:CreateButton(page.root,"healer_rule_default","默认回血规则",0,0,90,24,9,false); page:RegisterWidget("rules",page.ruleDefault)
    page.ruleGroup="match"; page.ruleGroupButtons={}
    local ruleGroups={{"match","匹配"},{"priority","优先级"},{"health","血量"},{"distance","距离/状态"}}
    for i,g in ipairs(ruleGroups) do
        -- Group switcher buttons behave like tabs; use the gradient skin and
        -- mark the active group with SetButtonActive (no "◆" prefix).
        local b=S.UI:CreateButton(page.root,"healer_rule_group_"..g[1],g[2],0,0,72,24,9,page.ruleGroup==g[1],true); page:RegisterWidget("rules",b); page.ruleGroupButtons[i]={id=g[1],button=b,label=g[2]}
        S.UI:SafeHandler(b,"OnClick",function() page.ruleGroup=g[1]; page:Refresh(); if page.lastSpec then page:ApplyLayout(page.lastSpec) end end,"healer:rule_group:"..g[1])
    end
    page.ruleGroupMap={
        match={rule_purpose=true,rule_source=true,rule_match=true,rule_effect=true,rule_unknown=true},
        priority={rule_scoremode=true,rule_score=true,rule_displayp=true,rule_rescuep=true,rule_protect=true,rule_retain=true},
        health={rule_healthrange=true,rule_healthmin=true,rule_healthmax=true,rule_healhp=true,rule_exclude=true},
        distance={rule_distmode=true,rule_customdist=true,rule_stacks=true,rule_remain=true,rule_stack=true},
    }
    page.ruleNameEdit,page.ruleNameSave=page:AddEditAction("rules","rulename","规则名称",32,"保存名称",function(text) local h=H(); if h then local ok,err=h:SetSuiteRuleName(page.selectedRule,text); if not ok then S.SafeChat(tostring(err)) end end end)
    page.ruleIdsEdit,page.ruleIdsSave=page:AddEditAction("rules","ruleids","高级：手动状态 ID，逗号分隔",128,"保存 ID",function(text) local h=H(); if h then h:SetSuiteRuleIds(page.selectedRule,text) end end)
    S.UI:SafeHandler(page.ruleAdd,"OnClick",function() local h=H(); if h then local ok,index=h:AddSuiteRule(5); if ok then page.selectedRule=index end end; page:Refresh() end,"healer:ruleadd")
    S.UI:SafeHandler(page.ruleToggle,"OnClick",function() local h=H(); local list=h and h:GetSuiteRules() or {}; local r=list[page.selectedRule]; if h and r then h:SetSuiteRuleEnabled(page.selectedRule,not r.enabled) end; page:Refresh() end,"healer:ruletoggle")
    S.UI:SafeHandler(page.ruleDelete,"OnClick",function() local h=H(); if h then h:RemoveSuiteRule(page.selectedRule); page.selectedRule=math.max(1,page.selectedRule-1) end; page:Refresh() end,"healer:ruledelete")
    S.UI:SafeHandler(page.ruleUp,"OnClick",function() local h=H(); if h and h:MoveSuiteRule(page.selectedRule,-1) then page.selectedRule=math.max(1,page.selectedRule-1) end; page:Refresh() end,"healer:ruleup")
    S.UI:SafeHandler(page.ruleDown,"OnClick",function() local h=H(); if h and h:MoveSuiteRule(page.selectedRule,1) then page.selectedRule=page.selectedRule+1 end; page:Refresh() end,"healer:ruledown")
    S.UI:SafeHandler(page.ruleCopy,"OnClick",function() local h=H(); if h and h.CopySuiteRule then local ok,index=h:CopySuiteRule(page.selectedRule); if ok then page.selectedRule=index elseif index then S.SafeChat(tostring(index)) end end; page:Refresh() end,"healer:rulecopy")
    S.UI:SafeHandler(page.ruleDefault,"OnClick",function() local h=H(); if h and h.AddDefaultHealingRule then local ok,index=h:AddDefaultHealingRule(); if ok then page.selectedRule=index elseif index then S.SafeChat(tostring(index)) end end; page:Refresh() end,"healer:ruledefault")
    for _,rdef in ipairs({
        {"purpose","purpose","用途",{1,2,3,4,5},1},{"source","sourceMode","来源模式",{1,2,3,4,5},1},{"match","matchMode","匹配模式",{1,2,3,4},1},
        {"effect","effectType","效果类型",{1,2,3,4,5},1},{"scoremode","scoreMode","评分模式",{1,2,3,4},1},
        {"distmode","distanceMode","距离模式",{1,2,3},1},{"exclude","excludeDisplayMode","排除显示模式",{1,2,3},1},
    }) do local item=rdef; page:AddControl("rules","rule_"..item[1],function() local h=H(); return item[3].."："..tostring(h and h:GetSuiteRuleSetting(page.selectedRule,item[2]) or item[5]) end,function() local h=H(); if h then local cur=h:GetSuiteRuleSetting(page.selectedRule,item[2]); h:SetSuiteRuleSetting(page.selectedRule,item[2],Cycle(item[4],cur)) end end) end
    for _,rdef in ipairs({
        {"score","scoreValue","评分值",-100,100,1,0,""},{"displayp","displayPriority","显示优先级",0,200,1,10,""},
        {"rescuep","rescuePriority","救援优先级",0,200,1,50,""},{"customdist","customDistance","自定义距离",1,100,1,27,"m"},
        {"healhp","healPriorityThreshold","治疗优先血量",0,100,1,70,"%"},{"stacks","minStacks","最低层数",1,99,1,1,"层"},
        {"remain","minRemainingMs","最低剩余",0,120000,100,0,"ms"},{"healthmin","healthMin","血量下限",0,100,1,0,"%"},
        {"healthmax","healthMax","血量上限",0,100,1,100,"%"},{"retain","emergencyRetainPercent","紧急保留",0,100,1,0,"%"},
    }) do
        local item=rdef
        page:AddNumericControl("rules","rule_"..item[1],item[3],item[4],item[5],item[6],function() if not page.selectedRule then return nil end; local h=H(); local v=h and h:GetSuiteRuleSetting(page.selectedRule,item[2]); return v~=nil and v or item[7] end,function(v) local h=H(); return h and h.SetSuiteRuleSetting and h:SetSuiteRuleSetting(page.selectedRule,item[2],v) end,{integer=true,suffix=item[8]})
    end
    for _,raw in ipairs({{"unknown","unknownRemainingValid","未知剩余也匹配"},{"healthrange","healthRangeEnabled","启用血量区间"},{"stack","allowStack","允许叠加"},{"protect","countsAsProtection","计入保护状态"}}) do local item=raw; page:AddControl("rules","rule_"..item[1],function() local h=H(); return item[3].."："..BoolText(h and h:GetSuiteRuleSetting(page.selectedRule,item[2])==true) end,function() local h=H(); if h then h:SetSuiteRuleSetting(page.selectedRule,item[2],not(h:GetSuiteRuleSetting(page.selectedRule,item[2])==true)) end end) end

    for _,a in ipairs({
        {"headname","showHeadName","头顶名字"},{"headdist","showHeadDistance","头顶距离"},{"headscore","showHeadScore","头顶评分"},
        {"showrank","showRaidRanks","团队格名次"},{"rolescore","roleScoringEnabled","职责评分"},
    }) do local id,k,label=a[1],a[2],a[3]; page:AddControl("team",id,function() return label.."："..BoolText(Get(k,false)) end,function() T(k,false) end) end
    for _,a in ipairs({
        {"rankcorner","raidRankCorner","名次角落",{1,2,3,4},2},{"raideffect","raidEffectMode","团队效果模式",{1,2,3,4},1},
        {"headeffect","headEffectMode","头标效果模式",{1,2,3,4},1},{"headshape","headShapeMode","头标形状",{1,2,3,4,5,6,7,8},4},
    }) do local id,k,label,vals,f=a[1],a[2],a[3],a[4],a[5]; page:AddControl("team",id,function() return label.."："..tostring(Get(k,f)) end,function() C(k,vals,f) end) end
    page:AddNumericControl("team","headcount","头顶标记人数",0,20,1,function() return Get("headMarkerCount",5) end,function(v) return Set("headMarkerCount",v) end,{integer=true,suffix="人"})
    page:AddNumericControl("team","rankcount","团队格名次数",0,50,1,function() return Get("raidRankCount",10) end,function(v) return Set("raidRankCount",v) end,{integer=true,suffix="人"})
    page:AddNumericControl("team","rankfont","名次字号",8,20,1,function() return Get("raidRankFontSize",10) end,function(v) return Set("raidRankFontSize",v) end,{integer=true})
    page:AddNumericControl("team","rankalpha","名次透明度",10,100,1,function() return math.floor((tonumber(Get("raidRankAlpha",1)) or 1)*100+0.5) end,function(v) return Set("raidRankAlpha",v/100) end,{integer=true,suffix="%"})
    page.headSizeLevel=1
    page:AddControl("team","headsizelevel",function() return "头标大小等级：L"..tostring(page.headSizeLevel) end,function() page.headSizeLevel=page.headSizeLevel%4+1 end)
    page:AddNumericControl("team","headsize","当前等级头标大小",12,60,1,function() local h=H(); return h and h.GetSuiteHeadSize and h:GetSuiteHeadSize(page.headSizeLevel) or 18 end,function(v) local h=H(); return h and h.SetSuiteHeadSize and h:SetSuiteHeadSize(page.headSizeLevel,v) end,{integer=true})
    page:AddNumericControl("team","rankx","名次 X偏移",-50,50,1,function() return Get("raidRankOffsetX",1) end,function(v) return Set("raidRankOffsetX",v) end,{integer=true})
    page:AddNumericControl("team","ranky","名次 Y偏移",-50,50,1,function() return Get("raidRankOffsetY",1) end,function(v) return Set("raidRankOffsetY",v) end,{integer=true})
    page:AddNumericControl("team","proxydist","范围底色距离",1,100,1,function() return Get("proximityDistance",27) end,function(v) return Set("proximityDistance",v) end,{integer=true,suffix="m"})
    page:AddNumericControl("team","edge","距离边缘权重",0,100,1,function() return Get("distanceEdgePercent",20) end,function(v) return Set("distanceEdgePercent",v) end,{integer=true,suffix="%"})
    page:AddNumericControl("team","missing","缺失数据容忍",0,120000,1000,function() return Get("missingSensitivity",30000) end,function(v) return Set("missingSensitivity",v) end,{integer=true,suffix="ms"})
    page:AddControl("team","raidpage",function() return "手动团队页："..tostring(Get("manualRaidPage",1)).."团" end,function() C("manualRaidPage",{1,2},1) end)
    page:AddControl("team","raidlock",function() return "锁定手动团队页："..BoolText(Get("manualRaidPageLocked",false)) end,function() T("manualRaidPageLocked",false) end)

    page.roleMode=1; page.roleOffset=0; page.roleRows={}
    page:AddControl("roles","enabled",function() return "职责评分："..BoolText(Get("roleScoringEnabled",false)) end,function() T("roleScoringEnabled",false) end)
    for _,raw in ipairs({{"mainTank","主坦"},{"offTank","副坦"},{"healer","治疗"},{"normal","普通成员"},{"unknown","未识别"}}) do
        local item=raw
        page:AddNumericControl("roles","score_"..item[1],item[2].."评分",-100,100,1,function() local h=H(); return h and h.GetSuiteRoleScore and h:GetSuiteRoleScore(item[1]) or 0 end,function(v) local h=H(); return h and h.SetSuiteRoleScore and h:SetSuiteRoleScore(item[1],v) end,{integer=true})
    end
    page:AddControl("roles","mode",function() local h=H(); return "新增覆盖职责："..tostring(h and h.GetSuiteRoleLabel and h:GetSuiteRoleLabel(page.roleMode) or page.roleMode) end,function() page.roleMode=page.roleMode%5+1 end)
    page.roleNameEdit,page.roleAdd=page:AddEditAction("roles","rolename","玩家名称",64,"添加/更新",function(text,edit) local h=H(); if h and h.SetSuiteRoleOverride then local ok,err=h:SetSuiteRoleOverride(text,page.roleMode); if ok==false then S.SafeChat(tostring(err)) elseif edit and edit.SetText then edit:SetText("") end end end)
    for i=1,6 do
        local index=i; local b=S.UI:CreateButton(page.root,"healer_role_row_"..index,"",0,0,100,24,9,false); page:RegisterWidget("roles",b); page.roleRows[index]={button=b,name=nil}
        S.UI:SafeHandler(b,"OnClick",function() local h=H(); local name=page.roleRows[index].name; if h and name then h:RemoveSuiteRoleOverride(name) end; page:Refresh() end,"healer:role_delete:"..index)
    end
    page.rolePrev=S.UI:CreateButton(page.root,"healer_role_prev","上一页",0,0,70,24,9,false); page:RegisterWidget("roles",page.rolePrev)
    page.roleNext=S.UI:CreateButton(page.root,"healer_role_next","下一页",0,0,70,24,9,false); page:RegisterWidget("roles",page.roleNext)
    S.UI:SafeHandler(page.rolePrev,"OnClick",function() page.roleOffset=math.max(0,page.roleOffset-6); page:Refresh() end,"healer:role_prev")
    S.UI:SafeHandler(page.roleNext,"OnClick",function() page.roleOffset=page.roleOffset+6; page:Refresh() end,"healer:role_next")

    page:AddInfo("cal","help",function()
        local h=H(); local active=h and h.GetSuiteCalibrationMode and h:GetSuiteCalibrationMode()==true
        if active then return "校准已开启：四个团队覆盖框会同时显示。直接拖动任意一个框到对应团队区域；四个框彼此独立，无需选择“当前区域”。完成后关闭校准模式即可。" end
        return "开启“校准模式”后会一次显示四个蓝色校准框（1团上/下、2团上/下），直接拖动需要调整的框。"
    end)
    page:AddControl("cal","mode",function()
        local h=H(); local active=h and h.GetSuiteCalibrationMode and h:GetSuiteCalibrationMode()==true
        return "四框校准模式："..BoolText(active)
    end,function()
        local h=H(); if not h or not h.SetSuiteCalibrationMode then return end
        local current=h.GetSuiteCalibrationMode and h:GetSuiteCalibrationMode()==true
        local ok,err=h:SetSuiteCalibrationMode(not current)
        if ok==false then S.SafeChat("治疗校准失败："..tostring(err or "未知原因")) end
    end)
    page:AddControl("cal","resetall",function() return "恢复四个校准框默认位置" end,function()
        local h=H(); if h then
            local ok,err=h:ResetSuiteCalibration(true)
            if ok==false then S.SafeChat("恢复校准失败："..tostring(err or "未知原因")) end
        end
    end)

    -- A calibration overlay owns mouse input while active.  Leaving the
    -- calibration sub-page must release that ownership so the raid list never
    -- remains blocked by an invisible settings state.
    function page:ApplyStatusVisibility()
        local active=self.activeSection
        -- Base SetSection already shows the active section.  Here we only
        -- enforce hiding of inactive sections; do not blanket-show the active
        -- widgets after Refresh(), otherwise empty/paged rows that Refresh hid
        -- are resurrected and appear as stray controls.
        for _,sec in ipairs(self.sectionOrder or {}) do
            if sec.id~=active then
                for _,w in ipairs(sec.widgets or {}) do if w and w.Show then w:Show(false) end end
            end
        end
        local statusActive=active=="buffs" or active=="observe" or active=="rules"
        if statusActive then
            for _,it in ipairs(self.statusModeTabs or {}) do if it.button and it.button.Show then it.button:Show(true) end;S.Theme:SetButtonActive(it.button,it.mode==self.statusMode) end
            if self.sections.buffs and self.sections.buffs.tab then S.Theme:SetButtonActive(self.sections.buffs.tab,true) end
            if self.sections.observe and self.sections.observe.tab then S.Theme:SetButtonActive(self.sections.observe.tab,false) end
            if self.sections.rules and self.sections.rules.tab then S.Theme:SetButtonActive(self.sections.rules.tab,false) end
            self.sectionTitle:SetText("BUFF条件组")
        end
        if active=="rules" then
            local allowed=self.ruleGroupMap and self.ruleGroupMap[self.ruleGroup] or {}
            for _,it in ipairs(self.sections.rules.controls or {}) do
                local visible=allowed[it.id]==true
                for _,w in ipairs({it.panel,it.title,it.sub,it.button}) do if w and w.Show then w:Show(visible) end end
            end
            for _,row in ipairs(self.sections.rules.numerics or {}) do
                local visible=allowed[row.id]==true
                for _,w in ipairs({row.panel,row.title,row.minus,row.slider,row.edit,row.readout,row.plus,row.apply}) do if w and w.Show then w:Show(visible) end end
            end
        end
    end

    local BaseHealerSetSection=page.SetSection
    function page:SetSection(id,reflow)
        if id=="buffs" then self.statusMode="groups" elseif id=="observe" then self.statusMode="current" elseif id=="rules" then self.statusMode="rules" end
        if self.activeSection=="cal" and id~="cal" then
            local h=H(); if h and h.SetSuiteCalibrationMode then h:SetSuiteCalibrationMode(false) end
        end
        local ok=BaseHealerSetSection(self,id,reflow)
        self:ApplyStatusVisibility()
        return ok
    end

    function page:Refresh()
        self:RefreshBase(); self:RefreshGeneric(); local h=H()
        for _,it in ipairs(self.statusModeTabs or {}) do S.Theme:SetButtonActive(it.button,it.mode==self.statusMode) end
        if h then
            local currentColor,currentLabel=CurrentColorTarget(); currentColor=NormalizeColor(currentColor)
            self.colorEditorTitle:SetText("编辑颜色 · "..tostring(currentLabel or ""))
            self.colorValue:SetText(ColorText(currentColor))
            SetColorPreview(self.colorPreview,currentColor)
            if self.colorEdit and self.colorEdit.SetText and self.activeSection=="colors" then
                local r,g,b,a=Color255(currentColor); self.colorEdit:SetText(string.format("%d,%d,%d,%d",r,g,b,a))
            end
            self.colorLevel:SetText("救援等级："..tostring(levelNames[self.levelColorIndex] or self.levelColorIndex))
            local rules=h.GetSuiteRules and h:GetSuiteRules() or {}; local rr=rules[self.selectedRule or 1]
            self.colorRule:SetText("规则："..tostring(rr and rr.name or "无规则"))
            for _,row in ipairs(self.colorRows or {}) do
                local target=row.targetFn(); local c=NormalizeColor(ColorForTarget(target)); row.value:SetText(ColorText(c)); SetColorPreview(row.swatch,c)
                local active=self.colorTarget and target.kind==self.colorTarget.kind and (target.key==nil or target.key==self.colorTarget.key)
                row.name:SetText((active and "[选] " or "")..tostring(row.label))
            end
        end
        if h and h.GetSuiteConditionGroups then
            local groups=h:GetSuiteConditionGroups() or {}
            local selectedExists=false
            for _,g in ipairs(groups) do if tonumber(g.ruleIndex)==tonumber(self.selectedRule) then selectedExists=true;break end end
            if not selectedExists then self.selectedRule=groups[1] and groups[1].ruleIndex or nil end
            self.conditionGroupOffset=math.min(self.conditionGroupOffset or 0,math.max(0,math.floor(math.max(0,#groups-1)/5)*5))
            for i,row in ipairs(self.conditionGroupRows or {}) do
                local g=groups[(self.conditionGroupOffset or 0)+i];row.ruleIndex=g and g.ruleIndex or nil
                if g then
                    row.button:SetText((tonumber(g.ruleIndex)==tonumber(self.selectedRule) and "[选] " or "")..(g.enabled and "[开] " or "[关] ")..tostring(g.name).." · "..tostring(#(g.ids or {})).." 个状态")
                    row.button:Show(self.activeSection=="buffs");S.Theme:SetButtonActive(row.button,tonumber(g.ruleIndex)==tonumber(self.selectedRule))
                else row.button:Show(false) end
            end
            local rules=h.GetSuiteRules and h:GetSuiteRules() or {};local r=self.selectedRule and rules[self.selectedRule] or nil
            if self.conditionState then
                self.conditionState:SetText(r and ((r.enabled and "已启用" or "已停用").." · "..tostring(r.name).." · 命中组内任意状态时显示该颜色") or "尚未创建条件组：点击“+ 新建条件组”开始")
            end
            local selected=r~=nil and r.simpleDisplayGroup==true
            local deleteNow=S.NowMs and S.NowMs() or 0
            if page.conditionDeleteArmedRule~=page.selectedRule or deleteNow-(tonumber(page.conditionDeleteArmedAt) or 0)>5000 then page.conditionDeleteArmedAt=0;page.conditionDeleteArmedRule=nil end
            if self.conditionDelete then self.conditionDelete:SetText((tonumber(page.conditionDeleteArmedAt) or 0)>0 and "再点删除" or "删除组") end
            local selectedPos=nil
            for pos,g in ipairs(groups) do if tonumber(g.ruleIndex)==tonumber(self.selectedRule) then selectedPos=pos;break end end
            for _,b in ipairs({self.conditionToggle,self.conditionDelete,self.conditionColorMore,self.conditionNameSave,self.conditionIdAdd}) do if b and b.Enable then b:Enable(selected) end end
            if self.conditionUp and self.conditionUp.Enable then self.conditionUp:Enable(selected and selectedPos~=nil and selectedPos>1) end
            if self.conditionDown and self.conditionDown.Enable then self.conditionDown:Enable(selected and selectedPos~=nil and selectedPos<#groups) end
            if self.conditionPrev and self.conditionPrev.Enable then self.conditionPrev:Enable((self.conditionGroupOffset or 0)>0) end
            if self.conditionNext and self.conditionNext.Enable then self.conditionNext:Enable((self.conditionGroupOffset or 0)+5<#groups) end
            for _,it in ipairs(self.conditionColorPresets or {}) do if it.button and it.button.Enable then it.button:Enable(selected) end end
            if self.conditionNameEdit and self.conditionNameEdit.SetText and self.activeSection=="buffs" then self.conditionNameEdit:SetText(selected and tostring(r.name or "") or "") end
            local color=selected and h.GetSuiteRuleColor and h:GetSuiteRuleColor(self.selectedRule) or {r=0.25,g=0.25,b=0.25,a=0.5};SetColorPreview(self.conditionColorPreview,color)
            local ids=selected and r.ids or {}
            self.conditionIdOffset=math.min(self.conditionIdOffset or 0,math.max(0,math.floor(math.max(0,#ids-1)/6)*6))
            if self.conditionIdsTitle then
                local pageNo=math.floor((self.conditionIdOffset or 0)/6)+1
                local pageCount=math.max(1,math.ceil(#ids/6))
                self.conditionIdsTitle:SetText("组内追踪状态 · "..tostring(#ids).." 个 · "..tostring(pageNo).."/"..tostring(pageCount))
            end
            local idPagerVisible=#ids>6 and self.activeSection=="buffs"
            if self.conditionIdPrev then self.conditionIdPrev:Show(idPagerVisible);if self.conditionIdPrev.Enable then self.conditionIdPrev:Enable((self.conditionIdOffset or 0)>0) end end
            if self.conditionIdNext then self.conditionIdNext:Show(idPagerVisible);if self.conditionIdNext.Enable then self.conditionIdNext:Enable((self.conditionIdOffset or 0)+6<#ids) end end
            for i,row in ipairs(self.conditionIdRows or {}) do
                local id=ids and ids[(self.conditionIdOffset or 0)+i] or nil;row.id=id
                if id then
                    local meta=h.ResolveSuiteStatusId and h:ResolveSuiteStatusId(id) or nil
                    row.name:SetText(tostring(meta and meta.name or ("状态 "..tostring(id))))
                    row.meta:SetText("ID "..tostring(id).." · 条件：存在即命中")
                    SetHealerStatusIcon(row.icon,meta and meta.iconPath or "")
                    for _,w in ipairs({row.panel,row.name,row.meta,row.remove}) do if w and w.Show then w:Show(self.activeSection=="buffs") end end
                else
                    if row.icon then row.icon:SetVisible(false) end
                    for _,w in ipairs({row.panel,row.name,row.meta,row.remove}) do if w and w.Show then w:Show(false) end end
                end
            end
            self.conditionCandidateOffset=math.min(self.conditionCandidateOffset or 0,math.max(0,math.floor(math.max(0,#(self.conditionCandidates or {})-1)/4)*4))
            if self.conditionCandidateTitle then self.conditionCandidateTitle:SetText("可追踪状态 · "..tostring(self.conditionCandidateSource or "状态库").." · "..tostring(#(self.conditionCandidates or {})).." 个") end
            for i,row in ipairs(self.conditionCandidateRows or {}) do
                local st=(self.conditionCandidates or {})[(self.conditionCandidateOffset or 0)+i];row.status=st
                if st then
                    row.name:SetText(tostring(st.name or ("状态 "..tostring(st.id))))
                    local extra=""
                    if st.effectType then extra=" · "..tostring(tonumber(st.stack) or 1).."层 · "..FormatHealerRemaining(st.timeLeftMs,st.remainingKnown) end
                    row.meta:SetText("ID "..tostring(st.id).." · "..tostring(st.source or "状态库")..extra)
                    local exists=false
                    for _,id in ipairs(selected and r.ids or {}) do if tonumber(id)==tonumber(st.id) then exists=true;break end end
                    row.add:SetText(exists and "移出组" or "加入组")
                    SetHealerStatusIcon(row.icon,st.iconPath)
                    for _,w in ipairs({row.panel,row.name,row.meta,row.add}) do if w and w.Show then w:Show(self.activeSection=="buffs") end end
                    if row.add and row.add.Enable then row.add:Enable(selected) end
                else
                    if row.icon then row.icon:SetVisible(false) end
                    for _,w in ipairs({row.panel,row.name,row.meta,row.add}) do if w and w.Show then w:Show(false) end end
                end
            end
            if self.conditionCandidatePrev and self.conditionCandidatePrev.Enable then self.conditionCandidatePrev:Enable((self.conditionCandidateOffset or 0)>0) end
            if self.conditionCandidateNext and self.conditionCandidateNext.Enable then self.conditionCandidateNext:Enable((self.conditionCandidateOffset or 0)+4<#(self.conditionCandidates or {})) end
        end
        if h and h.GetSuiteRules then
            local list=h:GetSuiteRules() or {}
            if self.activeSection=="rules" then
                if #list>0 then self.selectedRule=Clamp(self.selectedRule or 1,1,#list) else self.selectedRule=1 end
                self.ruleOffset=math.floor((self.selectedRule-1)/6)*6
                for i,row in ipairs(self.ruleRows) do local idx=self.ruleOffset+i;local r=list[idx];row.index=r and idx or nil;if r then row.button:SetText((idx==self.selectedRule and "[选] " or "")..(r.enabled and "[开] " or "[关] ")..tostring(r.name).." · "..JoinIds(r.ids));row.button:Show(true) else row.button:Show(false) end end
                local r=list[self.selectedRule];if r then if self.ruleNameEdit and self.ruleNameEdit.SetText then self.ruleNameEdit:SetText(r.name or "") end;if self.ruleIdsEdit and self.ruleIdsEdit.SetText then self.ruleIdsEdit:SetText(JoinIds(r.ids)) end end
            else
                for _,row in ipairs(self.ruleRows or {}) do if row.button then row.button:Show(false) end end
            end
        end
        if self.activeSection=="rules" then
            local allowed=self.ruleGroupMap and self.ruleGroupMap[self.ruleGroup] or {}
            for _,it in ipairs(self.sections.rules.controls or {}) do
                local visible=allowed[it.id]==true
                for _,w in ipairs({it.panel,it.title,it.sub,it.button}) do if w and w.Show then w:Show(visible) end end
            end
            for _,row in ipairs(self.sections.rules.numerics or {}) do
                local visible=allowed[row.id]==true
                for _,w in ipairs({row.panel,row.title,row.minus,row.slider,row.edit,row.readout,row.plus,row.apply}) do if w and w.Show then w:Show(visible) end end
            end
            for _,g in ipairs(self.ruleGroupButtons or {}) do S.Theme:SetButtonActive(g.button, g.id==self.ruleGroup) end
        end
        if h and h.GetSuiteObservedMembers then
            if #self.observeMembers==0 then self.observeMembers=h:GetSuiteObservedMembers() or {} end
            self.observeMemberIndex=Clamp(self.observeMemberIndex,1,math.max(1,#self.observeMembers))
            local member=self.observeMembers[self.observeMemberIndex]
            self.observeMemberLabel:SetText(member and ("观察对象："..tostring(member.name).." · "..tostring(member.raidIndex).."团 #"..tostring(member.memberIndex)) or "观察对象：当前没有可读取成员")
            if self.observeDiagLabel and h.GetSuiteBuffDiagnostics then
                local d=h:GetSuiteBuffDiagnostics() or {}
                self.observeDiagLabel:SetText("扫描 B/D/H="..tostring(d.buffCount or 0).."/"..tostring(d.debuffCount or 0).."/"..tostring(d.hiddenCount or 0).." · 解析="..tostring(d.resolved or 0).." · Tooltip补ID="..tostring(d.tooltipOnly or 0).." · 缺ID="..tostring(d.skippedNoId or 0))
            end
            self.observeOffset=math.min(self.observeOffset,math.max(0,math.floor(math.max(0,#self.observeStatuses-1)/6)*6))
            for i,row in ipairs(self.observeRows) do
                local st=self.observeStatuses[self.observeOffset+i];row.status=st
                if st then
                    row.name:SetText(tostring(st.name or ("状态 "..tostring(st.id))))
                    row.meta:SetText("ID "..tostring(st.id).." · "..tostring(st.source).." · "..tostring(tonumber(st.stack) or 1).."层 · "..FormatHealerRemaining(st.timeLeftMs,st.timeKnown))
                    SetHealerStatusIcon(row.icon,st.iconPath)
                    local show=self.activeSection=="observe"
                    for _,w in ipairs({row.panel,row.name,row.meta,row.add,row.rule}) do if w and w.Show then w:Show(show) end end
                else
                    if row.icon then row.icon:SetVisible(false) end
                    for _,w in ipairs({row.panel,row.name,row.meta,row.add,row.rule}) do if w and w.Show then w:Show(false) end end
                end
            end
        end
        if h and h.GetSuiteRoleOverrides then
            local list=h:GetSuiteRoleOverrides() or {}; self.roleOffset=math.min(self.roleOffset,math.max(0,math.floor(math.max(0,#list-1)/6)*6))
            for i,row in ipairs(self.roleRows) do local entry=list[self.roleOffset+i]; row.name=entry and entry.name or nil; if entry then row.button:SetText(tostring(entry.name).." → "..tostring(h:GetSuiteRoleLabel(entry.role)).." · 点击删除"); row.button:Show(self.activeSection=="roles") else row.button:Show(false) end end
            if self.rolePrev and self.rolePrev.Enable then self.rolePrev:Enable(self.roleOffset>0) end
            if self.roleNext and self.roleNext.Enable then self.roleNext:Enable(self.roleOffset+#self.roleRows<#list) end
        end
    end
    function page:ApplyLayout(spec)
        local sc,pad,full,top=self:ApplyBase(spec)
        if self.activeSection=="colors" then
            local y=top
            local selectorGap=6*sc; local selectorW=(full-selectorGap)/2
            self.colorLevel:SetExtent(selectorW,26*sc); self.colorRule:SetExtent(selectorW,26*sc)
            S.UI:SetAnchor(self.colorLevel,self.root,pad,y); S.UI:SetAnchor(self.colorRule,self.root,pad+selectorW+selectorGap,y); y=y+32*sc
            for _,row in ipairs(self.colorRows) do
                row.panel:SetExtent(full,34*sc); S.UI:SetAnchor(row.panel,self.root,pad,y)
                row.name:SetExtent(math.max(80*sc,full-174*sc),16*sc); S.UI:SetAnchor(row.name,self.root,pad+8*sc,y+4*sc)
                row.value:SetExtent(math.max(80*sc,full-174*sc),14*sc); S.UI:SetAnchor(row.value,self.root,pad+8*sc,y+18*sc)
                row.swatch:SetExtent(38*sc,24*sc); S.UI:SetAnchor(row.swatch,self.root,pad+full-96*sc,y+5*sc)
                row.edit:SetExtent(50*sc,24*sc); S.UI:SetAnchor(row.edit,self.root,pad+full-54*sc,y+5*sc)
                y=y+38*sc
            end
            local editorH=196*sc
            self.colorEditorPanel:SetExtent(full,editorH); S.UI:SetAnchor(self.colorEditorPanel,self.root,pad,y+2*sc)
            self.colorEditorTitle:SetExtent(full-88*sc,20*sc); S.UI:SetAnchor(self.colorEditorTitle,self.root,pad+10*sc,y+10*sc)
            self.colorPreview:SetExtent(58*sc,58*sc); S.UI:SetAnchor(self.colorPreview,self.root,pad+full-70*sc,y+10*sc)
            self.colorValue:SetExtent(full-90*sc,18*sc); S.UI:SetAnchor(self.colorValue,self.root,pad+10*sc,y+32*sc)
            local inputY=y+54*sc; local applyW=88*sc
            if self.colorEdit then self.colorEdit:SetExtent(math.max(80*sc,full-applyW-30*sc),27*sc); S.UI:SetAnchor(self.colorEdit,self.root,pad+10*sc,inputY) end
            self.colorApply:SetExtent(applyW,27*sc); S.UI:SetAnchor(self.colorApply,self.root,pad+full-applyW-10*sc,inputY)
            self.colorHint:SetExtent(full-20*sc,16*sc); S.UI:SetAnchor(self.colorHint,self.root,pad+10*sc,y+84*sc)
            local presetY=y+104*sc; local presetGap=4*sc; local cols=full>=520*sc and 10 or 6; local pW=math.max(24*sc,(full-presetGap*(cols-1))/cols)
            local palette={}
            for _,it in ipairs(self.colorPresets) do palette[#palette+1]=it end
            for _,it in ipairs(self.colorAlphas) do palette[#palette+1]=it end
            for i,it in ipairs(palette) do local rr=math.floor((i-1)/cols); local cc=(i-1)%cols; it.button:SetExtent(pW,24*sc); S.UI:SetAnchor(it.button,self.root,pad+cc*(pW+presetGap),presetY+rr*28*sc) end
        elseif self.activeSection=="buffs" then
            local gap=8*sc
            local leftW=math.max(170*sc,math.min(235*sc,full*0.29))
            local rightX=pad+leftW+gap
            local rightW=math.max(220*sc,full-leftW-gap)
            local y=top
            self.conditionHelp:SetExtent(full,34*sc);S.UI:SetAnchor(self.conditionHelp,self.root,pad,y);y=y+38*sc

            -- Left: condition groups. One glance shows what exists and whether it
            -- is enabled; no second "tracking vs rule" navigation model.
            local groupTop=y
            for i,row in ipairs(self.conditionGroupRows or {}) do row.button:SetExtent(leftW,29*sc);S.UI:SetAnchor(row.button,self.root,pad,groupTop+(i-1)*33*sc) end
            local groupActionY=groupTop+5*33*sc+3*sc
            self.conditionAdd:SetExtent(leftW,27*sc);S.UI:SetAnchor(self.conditionAdd,self.root,pad,groupActionY)
            local half=(leftW-5*sc)/2
            self.conditionToggle:SetExtent(half,26*sc);self.conditionDelete:SetExtent(half,26*sc)
            S.UI:SetAnchor(self.conditionToggle,self.root,pad,groupActionY+31*sc);S.UI:SetAnchor(self.conditionDelete,self.root,pad+half+5*sc,groupActionY+31*sc)
            self.conditionUp:SetExtent(half,25*sc);self.conditionDown:SetExtent(half,25*sc)
            S.UI:SetAnchor(self.conditionUp,self.root,pad,groupActionY+61*sc);S.UI:SetAnchor(self.conditionDown,self.root,pad+half+5*sc,groupActionY+61*sc)
            self.conditionPrev:SetExtent(half,24*sc);self.conditionNext:SetExtent(half,24*sc)
            S.UI:SetAnchor(self.conditionPrev,self.root,pad,groupActionY+91*sc);S.UI:SetAnchor(self.conditionNext,self.root,pad+half+5*sc,groupActionY+91*sc)

            -- Right: selected group. Common controls remain visible together.
            local ry=y
            self.conditionState:SetExtent(rightW,22*sc);S.UI:SetAnchor(self.conditionState,self.root,rightX,ry);ry=ry+25*sc
            local custom=self.sections.buffs.custom or {}
            local function LayoutEditAction(it,yy)
                if not it then return yy end
                if it.panel then it.panel:SetExtent(rightW,48*sc);S.UI:SetAnchor(it.panel,self.root,rightX,yy) end
                if it.caption then it.caption:SetExtent(rightW-14*sc,16*sc);S.UI:SetAnchor(it.caption,self.root,rightX+7*sc,yy+3*sc) end
                local bw=92*sc;local rowY=yy+20*sc
                if it.edit then it.edit:SetExtent(math.max(80*sc,rightW-bw-21*sc),24*sc);S.UI:SetAnchor(it.edit,self.root,rightX+7*sc,rowY) end
                if it.button then it.button:SetExtent(bw,24*sc);S.UI:SetAnchor(it.button,self.root,rightX+rightW-bw-7*sc,rowY) end
                if it.missing then it.missing:Show(false) end
                return yy+52*sc
            end
            ry=LayoutEditAction(custom[1],ry)

            self.conditionColorPreview:SetExtent(36*sc,26*sc);S.UI:SetAnchor(self.conditionColorPreview,self.root,rightX,ry)
            local colorX=rightX+42*sc;local colorGap=4*sc;local moreW=72*sc
            local colorW=math.max(28*sc,(rightW-42*sc-moreW-colorGap*8)/8)
            for _,it in ipairs(self.conditionColorPresets or {}) do it.button:SetExtent(colorW,25*sc);S.UI:SetAnchor(it.button,self.root,colorX,ry);colorX=colorX+colorW+colorGap end
            self.conditionColorMore:SetExtent(moreW,25*sc);S.UI:SetAnchor(self.conditionColorMore,self.root,rightX+rightW-moreW,ry);ry=ry+32*sc

            self.conditionIdsTitle:SetExtent(math.max(120*sc,rightW-128*sc),20*sc);S.UI:SetAnchor(self.conditionIdsTitle,self.root,rightX,ry)
            self.conditionIdPrev:SetExtent(58*sc,20*sc);self.conditionIdNext:SetExtent(58*sc,20*sc)
            S.UI:SetAnchor(self.conditionIdPrev,self.root,rightX+rightW-122*sc,ry);S.UI:SetAnchor(self.conditionIdNext,self.root,rightX+rightW-60*sc,ry);ry=ry+22*sc
            local idGap=5*sc;local idCols=rightW>=420*sc and 2 or 1;local idW=(rightW-idGap*(idCols-1))/idCols;local idH=42*sc
            for i,row in ipairs(self.conditionIdRows or {}) do
                local rr=math.floor((i-1)/idCols);local cc=(i-1)%idCols;local xx=rightX+cc*(idW+idGap);local yy=ry+rr*(idH+4*sc)
                row.panel:SetExtent(idW,idH);S.UI:SetAnchor(row.panel,self.root,xx,yy)
                row.name:SetExtent(math.max(65*sc,idW-100*sc),17*sc);S.UI:SetAnchor(row.name,self.root,xx+40*sc,yy+4*sc)
                row.meta:SetExtent(math.max(65*sc,idW-100*sc),15*sc);S.UI:SetAnchor(row.meta,self.root,xx+40*sc,yy+21*sc)
                row.remove:SetExtent(48*sc,23*sc);S.UI:SetAnchor(row.remove,self.root,xx+idW-54*sc,yy+9*sc)
            end
            ry=ry+math.ceil(6/idCols)*(idH+4*sc)+2*sc
            ry=LayoutEditAction(custom[2],ry)
            ry=LayoutEditAction(custom[3],ry)
            local scanGap=5*sc;local scanW=(rightW-scanGap)/2
            self.conditionScanSelf:SetExtent(scanW,24*sc);self.conditionScanTarget:SetExtent(scanW,24*sc)
            S.UI:SetAnchor(self.conditionScanSelf,self.root,rightX,ry);S.UI:SetAnchor(self.conditionScanTarget,self.root,rightX+scanW+scanGap,ry);ry=ry+29*sc
            self.conditionCandidateTitle:SetExtent(rightW,20*sc);S.UI:SetAnchor(self.conditionCandidateTitle,self.root,rightX,ry);ry=ry+22*sc
            local candGap=5*sc;local candCols=rightW>=420*sc and 2 or 1;local candW=(rightW-candGap*(candCols-1))/candCols;local candH=42*sc
            for i,row in ipairs(self.conditionCandidateRows or {}) do
                local rr=math.floor((i-1)/candCols);local cc=(i-1)%candCols;local xx=rightX+cc*(candW+candGap);local yy=ry+rr*(candH+4*sc)
                row.panel:SetExtent(candW,candH);S.UI:SetAnchor(row.panel,self.root,xx,yy)
                row.name:SetExtent(math.max(65*sc,candW-108*sc),17*sc);S.UI:SetAnchor(row.name,self.root,xx+40*sc,yy+4*sc)
                row.meta:SetExtent(math.max(65*sc,candW-108*sc),15*sc);S.UI:SetAnchor(row.meta,self.root,xx+40*sc,yy+21*sc)
                row.add:SetExtent(56*sc,23*sc);S.UI:SetAnchor(row.add,self.root,xx+candW-62*sc,yy+9*sc)
            end
            local pagesY=ry+math.ceil(4/candCols)*(candH+4*sc)+1*sc
            self.conditionCandidatePrev:SetExtent(66*sc,23*sc);self.conditionCandidateNext:SetExtent(66*sc,23*sc)
            S.UI:SetAnchor(self.conditionCandidatePrev,self.root,rightX,pagesY);S.UI:SetAnchor(self.conditionCandidateNext,self.root,rightX+72*sc,pagesY)
        elseif self.activeSection=="observe" then
            local modeGap=6*sc;local modeW=(full-modeGap*2)/3
            for i,it in ipairs(self.statusModeTabs) do it.button:SetExtent(modeW,25*sc);S.UI:SetAnchor(it.button,self.root,pad+(i-1)*(modeW+modeGap),top) end
            local baseTop=top+32*sc
            self.observeDiagLabel:SetExtent(full,20*sc); S.UI:SetAnchor(self.observeDiagLabel,self.root,pad,baseTop)
            self.observeMemberLabel:SetExtent(full,22*sc); S.UI:SetAnchor(self.observeMemberLabel,self.root,pad,baseTop+21*sc)
            local x=pad; local ay=baseTop+47*sc
            local observeButtons={self.observePrevMember,self.observeNextMember,self.observeScan,self.observePrev,self.observeNext}
            local observeGap=5*sc;local observeW=math.max(1,(full-observeGap*(#observeButtons-1))/#observeButtons)
            for _,b in ipairs(observeButtons) do b:SetExtent(observeW,24*sc); S.UI:SetAnchor(b,self.root,x,ay); x=x+observeW+observeGap end
            local y=ay+30*sc;local rowH=48*sc
            for i,row in ipairs(self.observeRows) do
                local yy=y+(i-1)*(rowH+3*sc);row.panel:SetExtent(full,rowH);S.UI:SetAnchor(row.panel,self.root,pad,yy)
                row.name:SetExtent(math.max(100*sc,full-210*sc),18*sc);S.UI:SetAnchor(row.name,self.root,pad+48*sc,yy+6*sc)
                row.meta:SetExtent(math.max(100*sc,full-210*sc),16*sc);S.UI:SetAnchor(row.meta,self.root,pad+48*sc,yy+25*sc)
                row.add:SetExtent(68*sc,24*sc);row.rule:SetExtent(68*sc,24*sc);S.UI:SetAnchor(row.add,self.root,pad+full-144*sc,yy+12*sc);S.UI:SetAnchor(row.rule,self.root,pad+full-72*sc,yy+12*sc)
            end
        elseif self.activeSection=="roles" then
            local y=self:LayoutGenericSection("roles",top,2); local gap=6*sc; local cell=(full-gap)/2
            for i,row in ipairs(self.roleRows) do local rr=math.floor((i-1)/2); local cc=(i-1)%2; row.button:SetExtent(cell,25*sc); S.UI:SetAnchor(row.button,self.root,pad+cc*(cell+gap),y+rr*29*sc) end
            local py=y+3*29*sc+4*sc; self.rolePrev:SetExtent(72*sc,24*sc); self.roleNext:SetExtent(72*sc,24*sc); S.UI:SetAnchor(self.rolePrev,self.root,pad,py); S.UI:SetAnchor(self.roleNext,self.root,pad+78*sc,py)
        elseif self.activeSection=="rules" then
            local modeGap=6*sc;local modeW=(full-modeGap*2)/3
            for i,it in ipairs(self.statusModeTabs) do it.button:SetExtent(modeW,25*sc);S.UI:SetAnchor(it.button,self.root,pad+(i-1)*(modeW+modeGap),top) end
            local baseTop=top+32*sc
            local listW=math.max(128*sc,math.min(full*0.36,210*sc))
            local rightX=pad+listW+10*sc; local rightW=full-listW-10*sc
            local y=baseTop
            for i,row in ipairs(self.ruleRows) do row.button:SetExtent(listW,28*sc); S.UI:SetAnchor(row.button,self.root,pad,y+(i-1)*32*sc) end
            local ay=y+6*32*sc+5*sc; local actionGap=5*sc; local actionW=(listW-actionGap)/2
            local actions={self.ruleAdd,self.ruleToggle,self.ruleDelete,self.ruleUp,self.ruleDown,self.ruleCopy,self.ruleDefault}
            for i,b in ipairs(actions) do local rr=math.floor((i-1)/2); local cc=(i-1)%2; b:SetExtent(actionW,25*sc); S.UI:SetAnchor(b,self.root,pad+cc*(actionW+actionGap),ay+rr*29*sc) end

            local groupGap=5*sc; local groupCols=rightW<300*sc and 2 or 4; local groupW=(rightW-groupGap*(groupCols-1))/groupCols
            local groupRows=math.ceil(#self.ruleGroupButtons/groupCols)
            for i,g in ipairs(self.ruleGroupButtons) do local rr=math.floor((i-1)/groupCols); local cc=(i-1)%groupCols; g.button:SetExtent(groupW,24*sc); S.UI:SetAnchor(g.button,self.root,rightX+cc*(groupW+groupGap),baseTop+rr*29*sc) end
            local editY=baseTop+groupRows*29*sc+4*sc
            for _,it in ipairs(self.sections.rules.custom) do
                if it.panel then it.panel:SetExtent(rightW,52*sc); S.UI:SetAnchor(it.panel,self.root,rightX,editY) end
                if it.caption then it.caption:SetExtent(rightW-14*sc,16*sc); S.UI:SetAnchor(it.caption,self.root,rightX+7*sc,editY+5*sc) end
                local rowY=editY+22*sc; local bw=84*sc
                if it.edit then local ew=math.max(52*sc,rightW-bw-19*sc); it.edit:SetExtent(ew,25*sc); S.UI:SetAnchor(it.edit,self.root,rightX+7*sc,rowY); it.button:SetExtent(bw,25*sc); S.UI:SetAnchor(it.button,self.root,rightX+rightW-bw-7*sc,rowY); if it.missing then it.missing:Show(false) end
                else if it.missing then it.missing:SetExtent(rightW-bw-19*sc,16*sc); S.UI:SetAnchor(it.missing,self.root,rightX+7*sc,rowY+4*sc); it.missing:Show(true) end; it.button:SetExtent(bw,25*sc); S.UI:SetAnchor(it.button,self.root,rightX+rightW-bw-7*sc,rowY) end
                editY=editY+57*sc
            end
            local active={}; local activeNums={}; local allowed=self.ruleGroupMap and self.ruleGroupMap[self.ruleGroup] or {}
            for _,row in ipairs(self.sections.rules.numerics or {}) do if allowed[row.id]==true then activeNums[#activeNums+1]=row end end
            local ngap=5*sc; local ncols=rightW>=560*sc and 2 or 1; local ncell=ncols==2 and (rightW-ngap)/2 or rightW; local ncard=40*sc
            for i,row in ipairs(activeNums) do
                local rr=math.floor((i-1)/ncols); local cc=(i-1)%ncols; local xx=rightX+cc*(ncell+ngap); local yy=editY+rr*(ncard+ngap)
                row.panel:SetExtent(ncell,ncard);S.UI:SetAnchor(row.panel,self.root,xx,yy)
                local labelW=math.max(74*sc,math.min(102*sc,ncell*0.26));local minusW,editW,plusW,applyW,g=22*sc,48*sc,22*sc,40*sc,3*sc
                local rightTotal=minusW+editW+plusW+applyW+g*3;local sliderW=math.max(58*sc,ncell-labelW-rightTotal-18*sc)
                row.title:SetExtent(labelW,18*sc);S.UI:SetAnchor(row.title,self.root,xx+7*sc,yy+11*sc)
                if row.slider then
                    row.slider:SetExtent(sliderW,18*sc);S.UI:SetAnchor(row.slider,self.root,xx+7*sc+labelW,yy+11*sc)
                    if S.UI.UpdateSliderVisual then
                        local visualValue=row.pending
                        if visualValue==nil and row.slider.GetValue then visualValue=row.slider:GetValue() end
                        S.UI:UpdateSliderVisual(row.slider,visualValue or row.minimum)
                    end
                end
                local bx=xx+ncell-rightTotal-6*sc;row.minus:SetExtent(minusW,22*sc);S.UI:SetAnchor(row.minus,self.root,bx,yy+9*sc);bx=bx+minusW+g
                if row.edit then row.edit:SetExtent(editW,22*sc);S.UI:SetAnchor(row.edit,self.root,bx,yy+9*sc);if row.readout then row.readout:Show(false) end else row.readout:SetExtent(editW,20*sc);S.UI:SetAnchor(row.readout,self.root,bx,yy+10*sc);row.readout:Show(true) end
                bx=bx+editW+g;row.plus:SetExtent(plusW,22*sc);S.UI:SetAnchor(row.plus,self.root,bx,yy+9*sc);bx=bx+plusW+g;row.apply:SetExtent(applyW,22*sc);S.UI:SetAnchor(row.apply,self.root,bx,yy+9*sc)
            end
            if #activeNums>0 then editY=editY+math.ceil(#activeNums/ncols)*(ncard+ngap) end
            for _,it in ipairs(self.sections.rules.controls or {}) do if allowed[it.id]==true then active[#active+1]=it end end
            local cols=rightW>=330*sc and 2 or 1; local gap=6*sc; local cellW=cols==2 and (rightW-gap)/2 or rightW; local cardH=38*sc
            for i,it in ipairs(active) do
                local rr=math.floor((i-1)/cols); local cc=(i-1)%cols; local xx=rightX+cc*(cellW+gap); local yy=editY+rr*(cardH+gap)
                if it.panel then it.panel:SetExtent(cellW,cardH); S.UI:SetAnchor(it.panel,self.root,xx,yy) end
                if it.title then it.title:SetExtent(cellW-86*sc,15*sc); S.UI:SetAnchor(it.title,self.root,xx+7*sc,yy+5*sc) end
                if it.sub then it.sub:SetExtent(cellW-86*sc,13*sc); S.UI:SetAnchor(it.sub,self.root,xx+7*sc,yy+20*sc) end
                it.button:SetExtent(72*sc,24*sc); S.UI:SetAnchor(it.button,self.root,xx+cellW-79*sc,yy+7*sc)
            end
        else self:LayoutGenericSection(self.activeSection,top,2) end
        self:Refresh(); self:ApplyStatusVisibility()
    end
    S.UI.pages.healer=page; return page
end

------------------------------------------------------------------------
-- Gear
------------------------------------------------------------------------
function PAGES.CreateGear(parent)
    local page=NewPage(parent,"gear","gear","一键换装",
        "方案、参与槽位、称号和快捷按钮都直接编辑 Gear Domain；不再打开旧独立配置窗口。",
        {{"sets","方案管理"},{"slots","装备部位"},{"quick","快捷与行为"}})
    local function G() return Export("gear","ReplicatedGear") end
    -- Gear is one editing workflow, not three unrelated destinations. Use the
    -- full content width and keep scheme/slots/quick settings visible together.
    page.hideSectionNav=true
    page.selectedId=nil; page.draft=nil; page.setRows={}; page.setOffset=0; page.slotOffset=0
    page.setListPanel=S.UI:CreatePanel(page.root,"gear_set_list_panel",0,0,100,100,"card"); page:RegisterWidget("sets",page.setListPanel)
    page.setEditPanel=S.UI:CreatePanel(page.root,"gear_set_edit_panel",0,0,100,100,"card"); page:RegisterWidget("sets",page.setEditPanel)
    page.slotPanel=S.UI:CreatePanel(page.root,"gear_slot_panel",0,0,100,100,"card"); page:RegisterWidget("slots",page.slotPanel)
    page.slotTitle=S.UI:CreateLabel(page.root,"gear_slot_title","装备部位",0,0,120,22,13,nil,ALIGN_LEFT); page:RegisterWidget("slots",page.slotTitle)
    page.setListTitle=S.UI:CreateLabel(page.root,"gear_set_list_title","方案列表",0,0,120,22,13,nil,ALIGN_LEFT); page:RegisterWidget("sets",page.setListTitle)
    page.setEditTitle=S.UI:CreateLabel(page.root,"gear_set_edit_title","当前方案",0,0,160,22,13,nil,ALIGN_LEFT); page:RegisterWidget("sets",page.setEditTitle)
    page.setSummary=S.UI:CreateLabel(page.root,"gear_set_summary","请选择方案",0,0,220,20,9,"muted",ALIGN_LEFT); page:RegisterWidget("sets",page.setSummary)
    page.nameEdit,page.create=page:AddEditAction("sets","newname","新方案名称",32,"新建方案",function(text,edit) local g=G(); if not g or not g.Core then return end; if text=="" then text="方案 "..tostring(#g.Core:GetSets(true)+1) end; local set,err=g.Core:CreateSet(text); if not set then S.SafeChat("新建失败："..tostring(err)); return end; page.selectedId=set.id; page.draft=g.Core:GetSetCopy(set.id); if edit and edit.SetText then edit:SetText("") end end,true)
    page.renameEdit,page.renameSave=page:AddEditAction("sets","rename","选中方案名称",32,"保存名称",function(text) local g=G(); if not g or not g.Core or not page.draft then S.SafeChat("请先选择方案"); return end; if text=="" then S.SafeChat("方案名称不能为空"); return end; page.draft.name=text; local ok,err=g.Core:CommitMetadata(page.draft,"suite_rename"); if not ok then S.SafeChat("保存名称失败："..tostring(err)) end end)
    for i=1,4 do local index=i; local rowPanel=S.UI:CreatePanel(page.root,"gear_set_row_panel_"..index,0,0,100,30,"soft"); local label=S.UI:CreateLabel(page.root,"gear_set_name_"..index,"",0,0,100,25,9,nil,ALIGN_LEFT); local select=S.UI:CreateButton(page.root,"gear_set_select_"..index,"编辑",0,0,52,25,8,false); local use=S.UI:CreateButton(page.root,"gear_set_use_"..index,"切换",0,0,52,25,8,false); page:RegisterWidget("sets",rowPanel); page:RegisterWidget("sets",label); page:RegisterWidget("sets",select); page:RegisterWidget("sets",use); page.setRows[index]={panel=rowPanel,label=label,select=select,use=use,setId=nil}; S.UI:SafeHandler(select,"OnClick",function() local g=G(); local id=page.setRows[index].setId; page.selectedId=id; page.draft=g and g.Core and id and g.Core:GetSetCopy(id) or nil; page:Refresh() end,"gear:select:"..index); S.UI:SafeHandler(use,"OnClick",function() local g=G(); local id=page.setRows[index].setId; if g and g.Runtime and id then g.Runtime:Start(id) end end,"gear:use:"..index) end
    page.setPrev=S.UI:CreateButton(page.root,"gear_set_prev","上一页",0,0,72,24,9,false); page:RegisterWidget("sets",page.setPrev)
    page.setNext=S.UI:CreateButton(page.root,"gear_set_next","下一页",0,0,72,24,9,false); page:RegisterWidget("sets",page.setNext)
    S.UI:SafeHandler(page.setPrev,"OnClick",function() page.setOffset=math.max(0,page.setOffset-4); page:Refresh() end,"gear:setprev")
    S.UI:SafeHandler(page.setNext,"OnClick",function() page.setOffset=page.setOffset+4; page:Refresh() end,"gear:setnext")
    page:AddControl("sets","capture",function() return "获取当前装备到选中方案" end,function() local g=G(); if not g or not g.Core or not page.selectedId then S.SafeChat("请先选择方案"); return end; local d,err=g.Core:CaptureDraft(page.selectedId); if not d then S.SafeChat("读取失败："..tostring(err)); return end; page.draft=d end)
    page:AddControl("sets","save",function() return "保存当前编辑" end,function() local g=G(); if g and g.Core and page.draft then local ok,err=g.Core:CommitPayloadDraft(page.draft,"suite_save_current_edit"); if not ok then S.SafeChat("保存失败："..tostring(err)) else page.draft=g.Core:GetSetCopy(page.draft.id) end end end)
    page:AddControl("sets","delete",function()
        local armed=page.deleteArmedId~=nil and tostring(page.deleteArmedId)==tostring(page.selectedId)
            and (S.NowMs and S.NowMs() or 0)-(tonumber(page.deleteArmedAt) or 0)<=5000
        return armed and "再次点击确认删除方案" or "删除选中方案"
    end,function()
        local g=G(); if not g or not g.Core or not page.selectedId then return end
        local now=S.NowMs and S.NowMs() or 0
        if tostring(page.deleteArmedId or "")~=tostring(page.selectedId) or now-(tonumber(page.deleteArmedAt) or 0)>5000 then
            page.deleteArmedId=page.selectedId;page.deleteArmedAt=now
            S.SafeChat("5秒内再次点击“删除选中方案”确认。")
            return
        end
        local ok,err=g.Core:DeleteSet(page.selectedId)
        if not ok then S.SafeChat("删除失败："..tostring(err)) else page.selectedId=nil;page.draft=nil end
        page.deleteArmedId=nil;page.deleteArmedAt=0
    end)
    page:AddControl("sets","up",function() return "方案上移" end,function() local g=G(); if g and g.Core and page.selectedId then g.Core:MoveSet(page.selectedId,-1) end end)
    page:AddControl("sets","down",function() return "方案下移" end,function() local g=G(); if g and g.Core and page.selectedId then g.Core:MoveSet(page.selectedId,1) end end)
    page:AddControl("sets","discard",function() return "放弃当前未保存修改" end,function() local g=G(); if g and g.Core and page.selectedId then page.draft=g.Core:GetSetCopy(page.selectedId); if page.renameEdit and page.renameEdit.SetText and page.draft then page.renameEdit:SetText(page.draft.name or "") end end end)

    local function TitleCanApply(draft)
        local title=type(draft)=="table" and draft.title or nil
        return type(title)=="table" and type(title.effect)=="table" and title.effect.id~=nil
    end
    local function ManagedEntryCount(draft,g)
        if type(draft)~="table" then return 0 end
        local count=g and g.Core and g.Core:CountManagedItems(draft) or 0
        if TitleCanApply(draft) and draft.title.apply==true then count=count+1 end
        return count
    end
    page:AddInfo("slots","slotstate",function() local g=G(); return page.draft and ("当前方案："..tostring(page.draft.name).." · 参与 "..tostring(ManagedEntryCount(page.draft,g)).." 项") or "请先在“方案”中选择并获取当前配置" end)
    page:AddControl("slots","all",function() return "全部非空项目参与" end,function() if page.draft then for _,it in ipairs(page.draft.items or {}) do it.managed=it.empty~=true end; if TitleCanApply(page.draft) then page.draft.title.apply=true end end end)
    page:AddControl("slots","weapons",function() return "仅武器 / 弓 / 乐器参与" end,function() local g=G(); if page.draft and g and g.Core then for _,it in ipairs(page.draft.items or {}) do it.managed=it.empty~=true and g.Core:IsWeaponSlot(it.slot) end; if type(page.draft.title)=="table" then page.draft.title.apply=false end end end)
    page:AddControl("slots","armor",function() return "防具 / 饰品参与" end,function()
        local g=G()
        if page.draft and g and g.Core then
            g.Core:ApplyManagedPreset(page.draft,"ARMOR")
            -- 本页惯例(同 weapons/none):预设排除称号参与。
            if type(page.draft.title)=="table" then page.draft.title.apply=false end
        end
    end)
    page:AddControl("slots","titleonly",function() return "仅称号参与" end,function()
        local g=G()
        if page.draft and g and g.Core then
            local changed,titleMissing=g.Core:ApplyManagedPreset(page.draft,"TITLE")
            if titleMissing then S.SafeChat("当前配置没有可切换的称号信息，请先在游戏中选择称号后重新获取当前配置") end
        end
    end)
    page:AddControl("slots","none",function() return "清空参与项目" end,function() if page.draft then for _,it in ipairs(page.draft.items or {}) do it.managed=false end; if type(page.draft.title)=="table" then page.draft.title.apply=false end end end)
    page:AddControl("slots","saveslots",function() return "保存参与项目" end,function() local g=G(); if g and g.Core and page.draft then local ok,err=g.Core:CommitPayloadDraft(page.draft,"suite_save_slots"); if not ok then S.SafeChat(tostring(err)) end end end)
    page.slotRows={}
    for i=1,24 do
        local index=i
        local b=S.UI:CreateButton(page.root,"gear_slot_"..index,"",0,0,100,25,9,false)
        page:RegisterWidget("slots",b)
        page.slotRows[index]={button=b,slot=nil,kind=nil}
        S.UI:SafeHandler(b,"OnClick",function()
            local row=page.slotRows[index]
            if not page.draft or not row then return end
            if row.kind=="title" then
                if not TitleCanApply(page.draft) then return end
                page.draft.title.apply=page.draft.title.apply~=true
                page:Refresh()
                return
            end
            local slot=row.slot
            if not slot then return end
            for _,it in ipairs(page.draft.items or {}) do
                if tonumber(it.slot)==tonumber(slot) and it.empty~=true then
                    it.managed=it.managed==false
                    break
                end
            end
            page:Refresh()
        end,"gear:slot:"..index)
    end

    page:AddControl("quick","quick",function() return "独立快捷按钮："..BoolText(page.draft and page.draft.quick~=false) end,function() if page.draft then page.draft.quick=page.draft.quick==false end end)
    page:AddControl("quick","snap",function() local g=G();return "快捷按钮吸附："..BoolText(g and g.Core and g.Core.IsQuickButtonSnapEnabled and g.Core:IsQuickButtonSnapEnabled()) end,function() local g=G();if g and g.Core and g.Core.SetQuickButtonSnapEnabled then local nextOn=not g.Core:IsQuickButtonSnapEnabled();local ok,err=g.Core:SetQuickButtonSnapEnabled(nextOn);if not ok then S.SafeChat("保存快捷按钮吸附设置失败："..tostring(err or "unknown")) end end end)
    page:AddControl("quick","save",function() return "保存快捷设置" end,function() local g=G(); if g and g.Core and page.draft then local ok,err=g.Core:CommitPayloadDraft(page.draft,"suite_save_quick_title"); if not ok then S.SafeChat(tostring(err)) elseif g.UI and g.UI.RefreshQuick then g.UI:RefreshQuick() end end end)
    page:AddInfo("quick","combat",function() return "战斗规则：公开 Addon EquipBagItem 在战斗中不可用时，事务会延后不支持的槽位；不会靠猜测绕过 API 限制。" end)

    function page:Refresh()
        self:RefreshBase(); self:RefreshGeneric()
        -- In the compact Gear workspace, the button itself carries the full
        -- command/state text; separate title/subtitle labels stay hidden.
        for _,sid in ipairs({"sets","quick"}) do
            local sec=self.sections[sid]
            for _,it in ipairs(sec and sec.controls or {}) do
                local ok,text=pcall(it.text);if it.button then it.button:SetText(ok and tostring(text or "操作") or "操作不可用") end
            end
        end
        local g=G(); local sets=g and g.Core and g.Core:GetSets(true) or {}
        if not self.selectedId and sets[1] then self.selectedId=sets[1].id; self.draft=g.Core:GetSetCopy(self.selectedId) end
        self.setOffset=math.min(self.setOffset,math.max(0,math.floor(math.max(0,#sets-1)/4)*4))
        for i,row in ipairs(self.setRows) do
            local set=sets[self.setOffset+i]; row.setId=set and set.id or nil
            if set then
                row.label:SetText((tostring(set.id)==tostring(self.selectedId) and "[选] " or "")..tostring(set.name)..(set.configured and "" or "（未配置）"))
                for _,w in ipairs({row.panel,row.label,row.select,row.use}) do if w then w:Show(true) end end
                row.use:Enable(set.configured==true and S.ModuleManager~=nil and S.ModuleManager:IsEnabled("gear"))
            else
                for _,w in ipairs({row.panel,row.label,row.select,row.use}) do if w then w:Show(false) end end
            end
        end
        if self.setPrev and self.setPrev.Enable then self.setPrev:Enable(self.setOffset>0) end
        if self.setNext and self.setNext.Enable then self.setNext:Enable(self.setOffset+#self.setRows<#sets) end
        if self.renameEdit and self.renameEdit.SetText and self.draft then self.renameEdit:SetText(self.draft.name or "") end
        if self.setSummary then
            if self.draft then
                local managed=ManagedEntryCount(self.draft,g)
                self.setSummary:SetText(tostring(self.draft.name or "未命名").." · 参与 "..tostring(managed).." 项"..(self.draft.configured==false and " · 尚未配置" or ""))
            else self.setSummary:SetText("请选择左侧方案进行编辑") end
        end
        local now=S.NowMs and S.NowMs() or 0
        if now-(tonumber(self.deleteArmedAt) or 0)>5000 then self.deleteArmedId=nil;self.deleteArmedAt=0 end
        -- Commands that require a selected draft should look unavailable rather
        -- than accepting a click that silently does nothing.
        local hasDraft=self.draft~=nil and self.selectedId~=nil
        local draftRequired={
            sets={capture=true,save=true,delete=true,up=true,down=true,discard=true},
            slots={all=true,weapons=true,none=true,saveslots=true},
            quick={quick=true,save=true},
        }
        for _,sid in ipairs({"sets","slots","quick"}) do
            for _,it in ipairs(self.sections[sid] and self.sections[sid].controls or {}) do
                if it and it.button and it.button.Enable and draftRequired[sid] and draftRequired[sid][it.id] then
                    it.button:Enable(hasDraft)
                end
            end
        end
        if self.renameSave and self.renameSave.Enable then self.renameSave:Enable(hasDraft and self.renameEdit~=nil) end

        local items=self.draft and self.draft.items or {}
        -- Equipment and title share one participation grid. Title is intentionally
        -- rendered as the row immediately after the final equipment slot so the
        -- user can manage it with the exact same [√] / [ ] interaction.
        self.slotOffset=0
        local titleRowIndex=self.draft and (#items+1) or nil
        for i,row in ipairs(self.slotRows) do
            local it=items[i]
            row.slot=it and it.slot or nil
            row.kind=it and "equipment" or nil
            if it then
                row.button:SetText((it.managed==false and "[ ] " or "[√] ")..tostring(it.slotName or it.key or it.slot).."："..tostring(it.empty and "空（保持当前）" or it.name or "未知"))
                row.button:Show(true)
                if row.button.Enable then row.button:Enable(hasDraft and it.empty~=true) end
            elseif titleRowIndex==i then
                row.kind="title"
                local titleText=g and g.Core and g.Core.TitleText and g.Core:TitleText(self.draft.title) or "未读取"
                local canApply=TitleCanApply(self.draft)
                local prefix=canApply and (self.draft.title.apply==true and "[√] " or "[ ] ") or "[ ] "
                row.button:SetText(prefix.."称号："..tostring(titleText))
                row.button:Show(true)
                if row.button.Enable then row.button:Enable(hasDraft and canApply) end
            else
                row.button:Show(false)
            end
        end
    end
    local function LayoutGearControlCards(items,x,y,w,sc,cols)
        -- Gear actions are simple commands/toggles, so a full explanatory card
        -- for every action wastes vertical space.  Use one readable button per
        -- action; the button itself carries the complete action/state text.
        local gap=4*sc;cols=math.max(1,cols or 1);local cellW=(w-gap*(cols-1))/cols;local cellH=26*sc
        for i,it in ipairs(items or {}) do
            local rr=math.floor((i-1)/cols);local cc=(i-1)%cols;local xx=x+cc*(cellW+gap);local yy=y+rr*(cellH+gap)
            if it.panel then it.panel:Show(false) end
            if it.title then it.title:Show(false) end
            if it.sub then it.sub:Show(false) end
            if it.button then it.button:SetExtent(cellW,cellH);S.UI:SetAnchor(it.button,page.root,xx,yy);it.button:Show(true) end
        end
        return y+math.ceil(#(items or {})/cols)*(cellH+gap)
    end
    function page:ApplyLayout(spec)
        local sc,pad,full,top=self:ApplyBase(spec)
        -- Gear intentionally combines three logical sections. Reveal them before
        -- laying out, then let the layout/Refresh decide which individual widgets
        -- stay hidden. Doing this at the end used to resurrect edit-box fallback
        -- labels at their construction coordinate (top-left of the page).
        for _,sid in ipairs({"sets","slots","quick"}) do
            for _,w in ipairs(self.sections[sid].widgets or {}) do if w and w.Show then w:Show(true) end end
        end
        self.sectionTitle:SetText("装备管理")
        self.sectionHint:SetText("方案、装备部位、称号和快捷按钮集中在同一页面；称号与装备一样在下方勾选参与。")
        local gap=8*sc
        local avail=math.max(300*sc,(self.contentBottom or spec.contentHeight)-top)
        local listW=math.max(220*sc,math.min(310*sc,full*0.34))
        local editX=pad+listW+gap;local editW=full-listW-gap
        local controlCols=editW>=590*sc and 4 or (editW>=390*sc and 3 or 2)
        local nameBlockH=editW>=470*sc and 43*sc or 86*sc
        local commandCount=#(self.sections.sets.controls or {})+#(self.sections.quick.controls or {})
        local commandRows=math.ceil(commandCount/controlCols)
        local desiredTopH=43*sc+nameBlockH+commandRows*30*sc+5*sc
        -- On normal 1024+ widths this is ~181 px.  Narrow windows may grow
        -- the manager enough to keep every action readable, but equipment still
        -- owns the majority of the page.
        local topH=math.max(170*sc,math.min(desiredTopH,avail-285*sc))
        local bottomY=top+topH+gap
        local bottomH=math.max(150*sc,(self.contentBottom or spec.contentHeight)-bottomY)

        self.setListPanel:SetExtent(listW,topH);S.UI:SetAnchor(self.setListPanel,self.root,pad,top)
        self.setEditPanel:SetExtent(editW,topH);S.UI:SetAnchor(self.setEditPanel,self.root,editX,top)
        self.slotPanel:SetExtent(full,bottomH);S.UI:SetAnchor(self.slotPanel,self.root,pad,bottomY)
        self.setListTitle:SetExtent(listW-18*sc,20*sc);S.UI:SetAnchor(self.setListTitle,self.root,pad+9*sc,top+7*sc)
        self.setEditTitle:SetExtent(editW-18*sc,20*sc);S.UI:SetAnchor(self.setEditTitle,self.root,editX+9*sc,top+7*sc)
        self.setSummary:SetExtent(editW-18*sc,18*sc);S.UI:SetAnchor(self.setSummary,self.root,editX+9*sc,top+27*sc)
        self.slotTitle:SetExtent(full-18*sc,20*sc);S.UI:SetAnchor(self.slotTitle,self.root,pad+9*sc,bottomY+7*sc)

        -- Keep only four scheme rows in the compact manager.  Equipment parts
        -- are the frequently edited data and therefore receive most of the page.
        local listTop=top+31*sc;local pagerH=25*sc
        local rowGap=2*sc;local rowH=math.max(21*sc,math.min(27*sc,(topH-35*sc-pagerH-rowGap*3)/4))
        for i,row in ipairs(self.setRows) do
            local yy=listTop+(i-1)*(rowH+rowGap)
            row.panel:SetExtent(listW-14*sc,rowH);S.UI:SetAnchor(row.panel,self.root,pad+7*sc,yy)
            local actionW=40*sc;local nameW=math.max(54*sc,listW-14*sc-actionW*2-13*sc)
            row.label:SetExtent(nameW,math.max(18*sc,rowH-4*sc));S.UI:SetAnchor(row.label,self.root,pad+12*sc,yy+2*sc)
            row.select:SetExtent(actionW,math.max(19*sc,rowH-4*sc));row.use:SetExtent(actionW,math.max(19*sc,rowH-4*sc))
            S.UI:SetAnchor(row.select,self.root,pad+listW-actionW*2-11*sc,yy+2*sc);S.UI:SetAnchor(row.use,self.root,pad+listW-actionW-7*sc,yy+2*sc)
        end
        local pagerY=top+topH-pagerH
        self.setPrev:SetExtent(68*sc,23*sc);self.setNext:SetExtent(68*sc,23*sc);S.UI:SetAnchor(self.setPrev,self.root,pad+7*sc,pagerY);S.UI:SetAnchor(self.setNext,self.root,pad+81*sc,pagerY)

        -- Name creation/rename are one compact row each (side by side when wide).
        local custom=self.sections.sets.custom or {};local ey=top+43*sc
        local sideBySide=editW>=470*sc and #custom>=2;local cGap=6*sc;local cW=sideBySide and (editW-18*sc-cGap)/2 or (editW-18*sc)
        for i,it in ipairs(custom) do
            local xx=sideBySide and (editX+9*sc+(i-1)*(cW+cGap)) or (editX+9*sc)
            local yy=sideBySide and ey or (ey+(i-1)*43*sc)
            it.panel:SetExtent(cW,40*sc);S.UI:SetAnchor(it.panel,self.root,xx,yy)
            it.caption:SetExtent(cW-14*sc,14*sc);S.UI:SetAnchor(it.caption,self.root,xx+7*sc,yy+2*sc)
            local bw=78*sc;local inputY=yy+15*sc
            if it.edit then it.edit:SetExtent(math.max(54*sc,cW-bw-18*sc),22*sc);S.UI:SetAnchor(it.edit,self.root,xx+7*sc,inputY) end
            it.button:SetExtent(bw,22*sc);S.UI:SetAnchor(it.button,self.root,xx+cW-bw-7*sc,inputY)
            if it.missing then it.missing:Show(false) end
        end
        ey=ey+(sideBySide and 43*sc or (#custom*43*sc))
        local combined={}
        for _,it in ipairs(self.sections.sets.controls or {}) do combined[#combined+1]=it end
        for _,it in ipairs(self.sections.quick.controls or {}) do combined[#combined+1]=it end
        LayoutGearControlCards(combined,editX+9*sc,ey,editW-18*sc,sc,controlCols)

        -- Slot area consumes the entire lower panel. Bulk actions wrap onto
        -- multiple rows (max 4 columns each); every equipment slot uses a
        -- responsive 5/4/3-column grid.
        local slotInfo=self.sections.slots.infos and self.sections.slots.infos[1]
        local sy=bottomY+31*sc
        if slotInfo then
            slotInfo.panel:SetExtent(full-16*sc,28*sc);S.UI:SetAnchor(slotInfo.panel,self.root,pad+8*sc,sy)
            slotInfo.widget:SetExtent(full-30*sc,20*sc);S.UI:SetAnchor(slotInfo.widget,self.root,pad+15*sc,sy+4*sc);sy=sy+33*sc
        end
        local slotControls=self.sections.slots.controls or {};local bulkGap=5*sc;local bulkCols=math.min(4,#slotControls);local bulkW=(full-16*sc-bulkGap*(bulkCols-1))/bulkCols
        local bulkRows=math.max(1,math.ceil(#slotControls/bulkCols))
        for i,it in ipairs(slotControls) do
            local col=(i-1)%bulkCols;local row=math.floor((i-1)/bulkCols)
            local xx=pad+8*sc+col*(bulkW+bulkGap)
            local yy=sy+row*44*sc
            it.panel:SetExtent(bulkW,38*sc);S.UI:SetAnchor(it.panel,self.root,xx,yy)
            it.title:SetExtent(math.max(40*sc,bulkW-80*sc),14*sc);S.UI:SetAnchor(it.title,self.root,xx+6*sc,yy+4*sc);it.sub:SetExtent(math.max(40*sc,bulkW-80*sc),12*sc);S.UI:SetAnchor(it.sub,self.root,xx+6*sc,yy+19*sc);it.button:SetExtent(66*sc,23*sc);S.UI:SetAnchor(it.button,self.root,xx+bulkW-72*sc,yy+7*sc)
        end
        sy=sy+bulkRows*44*sc
        local visibleSlots=self.draft and math.min(#(self.draft.items or {})+1,#self.slotRows) or 0
        local cols=full>=760*sc and 5 or (full>=470*sc and 4 or 3)
        local slotGap=5*sc;local slotW=(full-16*sc-slotGap*(cols-1))/cols
        local slotCount=math.max(1,visibleSlots)
        local slotRowsNeeded=math.ceil(slotCount/cols)
        local remainingForSlots=math.max(120*sc,bottomY+bottomH-sy-34*sc)
        local slotH=math.max(24*sc,math.min(34*sc,(remainingForSlots/math.max(1,slotRowsNeeded))-4*sc))
        for i,row in ipairs(self.slotRows) do
            local cc=(i-1)%cols;local rr=math.floor((i-1)/cols)
            row.button:SetExtent(slotW,slotH);S.UI:SetAnchor(row.button,self.root,pad+8*sc+cc*(slotW+slotGap),sy+rr*(slotH+4*sc))
        end
        -- Slot pagination is deliberately retired: every equipment part is
        -- visible on the same page.
        local py=sy+slotRowsNeeded*(slotH+4*sc)+2*sc
        local combat=self.sections.quick.infos and self.sections.quick.infos[1]
        if combat then
            local room=(bottomY+bottomH)-py
            combat.panel:Show(room>=28*sc);combat.widget:Show(room>=28*sc)
            if room>=28*sc then
                combat.panel:SetExtent(full-16*sc,28*sc);S.UI:SetAnchor(combat.panel,self.root,pad+8*sc,py)
                combat.widget:SetExtent(full-30*sc,20*sc);S.UI:SetAnchor(combat.widget,self.root,pad+15*sc,py+4*sc)
            end
        end

        -- All three logical groups already share this surface; Refresh now only
        -- updates content/visibility and cannot resurrect unlaid-out fallback UI.
        self:Refresh()
    end
    S.UI.pages.gear=page; return page
end

------------------------------------------------------------------------
-- Plates
------------------------------------------------------------------------
function PAGES.CreatePlates(parent)
    local page=NewPage(parent,"plates","plates","BUFF显示",
        "BUFF 显示 UI2：目标/自身独立设置，真实 Icon 追踪，Hidden 严格白名单，实时/模拟校准与分范围导入导出。",
        {{"display","显示设置"},{"tracking","状态追踪"},{"alerts","战斗警报"},{"buffcap","buff上限追踪"},{"magiccircle","魔法阵距离"},{"layout","外观布局"},{"lines","单位连线"},{"colors","颜色与样式"},{"transfer","导入导出"},{"diag","诊断"}})

    local function P() return Export("plates","ReplicatedPlates") end
    local function Cfg(scope) local p=P(); return p and p.Storage and p.Storage:GetPlate(scope) or nil end
    local function EffectLayout(scope,effect) local p=P(); return p and p.Storage and p.Storage:GetEffectLayout(scope,effect) or nil end
    local function RestoreTable(dst,src)
        if type(dst)~="table" or type(src)~="table" then return end
        for k in pairs(dst) do dst[k]=nil end
        for k,v in pairs(src) do dst[k]=S.Utils.DeepCopy(v) end
    end
    local function RefreshNow(p,scope)
        if not p then return end
        if p.UI and p.UI.ApplyPlateLayout then pcall(function() p.UI:ApplyPlateLayout(scope) end) end
        local rt=p.Runtime and p.Runtime.scopes and p.Runtime.scopes[scope] or nil
        local cfg=Cfg(scope)
        if p.UI and p.UI.MovePlate and type(rt)=="table" and rt.positionValid==true and type(cfg)=="table" then
            pcall(function() p.UI:MovePlate(scope,(tonumber(rt.lastScreenX) or 0)+(tonumber(cfg.offsetX) or 0),(tonumber(rt.lastScreenY) or 0)+(tonumber(cfg.offsetY) or 0)) end)
        end
        -- Mock preview is its own visual Authority: Runtime ForceScope is
        -- intentionally ignored while mock mode is active so real auras cannot
        -- overwrite the samples. Re-render the mock slots explicitly after every
        -- settings mutation, otherwise colour/style changes are saved but the
        -- already-visible mock icons keep their old appearance.
        local mock = p.UI and p.UI.GetPreviewMode and p.UI:GetPreviewMode(scope)=="mock"
        if mock and p.UI.RefreshMockPreview then
            pcall(function() p.UI:RefreshMockPreview(scope) end)
        elseif p.Runtime and p.Runtime.ForceScope and S.ModuleManager and S.ModuleManager:IsEnabled("plates") then
            p.Runtime:ForceScope(scope)
        end
    end
    local function Mutate(scope,fn,tracking)
        local p=P(); if not p or not p.Storage then S.SafeChat("BUFF显示尚未初始化。","warning","plates"); return false end
        local cfg=Cfg(scope); if type(cfg)~="table" then return false end
        local before=S.Utils.DeepCopy(cfg); local dirty,trackingDirty=p.Storage.dirty,p.Storage.trackingDirty
        local ok,err=xpcall(function() fn(cfg,p.Storage) end,S.SafeTraceback)
        if not ok then S.SafeChat("BUFF显示设置修改失败："..tostring(err),"error","plates"); return false end
        if tracking then p.Storage:MarkTrackingDirty() else p.Storage:MarkDirty() end
        local saved,saveErr=p.Storage:Save(true)
        if not saved then
            RestoreTable(cfg,before); p.Storage.dirty,p.Storage.trackingDirty=dirty,trackingDirty
            S.SafeChat("BUFF显示保存失败："..tostring(saveErr),"error","plates"); return false
        end
        RefreshNow(p,scope); return true
    end
    local function Stage(scope,fn)
        local p=P(); if not p or not p.Storage then return false end
        local cfg=Cfg(scope); if type(cfg)~="table" then return false end
        local ok,err=xpcall(function() fn(cfg,p.Storage) end,S.SafeTraceback)
        if not ok then S.SafeChat("BUFF显示实时调整失败："..tostring(err),"error","plates"); return false end
        p.Storage:MarkDirty(); RefreshNow(p,scope)
        if S.Scheduler then
            S.Scheduler:RemoveTask("plates_ui2_delayed_save")
            S.Scheduler:AddTask("plates_ui2_delayed_save",350,function()
                S.Scheduler:RemoveTask("plates_ui2_delayed_save")
                local pp=P(); if pp and pp.Storage then local saved,e=pp.Storage:Save(true); if not saved then S.SafeChat("BUFF显示延迟保存失败："..tostring(e),"error","plates") end end
            end,false,page,"P2")
        end
        return true
    end
    local function Toggle(scope,key) Mutate(scope,function(c) c[key]=not(c[key]==true) end) end
    local function SetHudVisible(scope)
        local id=scope=="target" and "plates_target" or "plates_player"
        if S.HudManager and S.HudManager:Get(id) then S.HudManager:ToggleVisible(id) else Toggle(scope,"enabled") end
    end
    local function HudVisible(scope)
        local id=scope=="target" and "plates_target" or "plates_player"
        local v=S.HudManager and S.HudManager:IsVisible(id); if v==nil then local c=Cfg(scope);v=c and c.enabled end; return v==true
    end
    local function TrackTypeTitle(t) return ({buff="Buff",debuff="Debuff",hidden="Hidden"})[t] or tostring(t) end
    local function ScopeTitle(scope) return scope=="target" and "目标 HUD" or "自身 HUD" end

    page.hudScope="target"; page.trackScope="target"; page.trackType="buff"; page.trackView="tracked"; page.trackSource="tracked"
    page.layoutScope="target"; page.layoutType="buff"; page.layoutGroup="effect"; page.colorScope="target"; page.colorType="buff"; page.colorTarget="border"
    local TRACK_ROW_CAP=10
    page.trackPageSize=4
    local function ActiveTrackPageSize()
        return math.max(1,math.min(TRACK_ROW_CAP,tonumber(page.trackPageSize) or 4))
    end
    page.trackOffset=0; page.trackLive={}; page.showRawHidden=false; page.selectedTrackId=nil; page.trackAdvanced=false; page.trackClearAllArmedAt=0
    page.transferMode="library"; page.pendingImportText=nil; page.pendingImportSummary=nil; page.customColorOffset=0; page.colorRuleMode=false
    page.transferChunks={};page.transferChunkIndex=1;page.transferExportInfo=nil;page.auraImportPolicy="merge"

    local function MakeTabs(section,id,items,getter,setter)
        local result={}
        for i,item in ipairs(items) do
            local value,label=item[1],item[2]
            local b=S.UI:CreateButton(page.root,"plates_"..id.."_"..value,label,0,0,92,26,9,false,true)
            page:RegisterWidget(section,b); result[#result+1]={button=b,value=value,label=label}
            S.UI:SafeHandler(b,"OnClick",function() setter(value); page:Refresh(); if page.lastSpec then page:ApplyLayout(page.lastSpec) end end,"plates:"..id..":"..value)
        end
        result.getter=getter; return result
    end
    page.displayScopeTabs=MakeTabs("display","display_scope",{{"target","目标 HUD"},{"player","自身 HUD"}},function() return page.hudScope end,function(v) page.hudScope=v end)
    page.trackScopeTabs=MakeTabs("tracking","track_scope",{{"target","目标 HUD"},{"player","自身 HUD"}},function() return page.trackScope end,function(v)
        page.trackScope=v;page.trackOffset=0;page.trackLive={};page.selectedTrackId=nil
        local p=P();if p and p.Manager and p.Manager.SetCaptureLane then p.Manager:SetCaptureLane(page.trackScope,page.trackType) end
    end)
    page.trackTypeTabs=MakeTabs("tracking","track_type",{{"buff","Buff"},{"debuff","Debuff"},{"hidden","Hidden"}},function() return page.trackType end,function(v)
        page.trackType=v;page.trackOffset=0;page.trackLive={};page.selectedTrackId=nil
        local p=P();if p and p.Manager and p.Manager.SetCaptureLane then p.Manager:SetCaptureLane(page.trackScope,page.trackType) end
    end)
    page.trackViewTabs=MakeTabs("tracking","track_view",{{"tracked","已追踪"},{"current","当前检测"}},function() return page.trackView end,function(v)
        page.trackView=v;page.trackOffset=0
        if v=="current" then local p=P();if p and p.Manager and p.Manager:IsCaptureEnabled() then page.trackSource="capture" end end
    end)
    page.layoutScopeTabs=MakeTabs("layout","layout_scope",{{"target","目标 HUD"},{"player","自身 HUD"}},function() return page.layoutScope end,function(v)
        local p=P();local old=page.layoutScope
        if p and p.UI and old~=v then
            if p.UI.SetPreviewMode then p.UI:SetPreviewMode(old,"real") end
            if p.UI.SetCalibration then p.UI:SetCalibration(nil) end
            if p.UI.SetLayoutEdit then p.UI:SetLayoutEdit(nil,nil) end
        end
        page.layoutScope=v
        -- 玩家信息/距离/施法条只属于目标 HUD。切到自身 HUD 时自动回到状态区域，
        -- 避免留下一个“看得见但不会生效”的无效设置面板。
        if v=="player" and (page.layoutGroup=="metadata" or page.layoutGroup=="distance" or page.layoutGroup=="cast") then page.layoutGroup="effect" end
    end)
    page.layoutGroupTabs=MakeTabs("layout","layout_group",{{"effect","状态区域"},{"hud","整体 HUD"},{"metadata","玩家信息"},{"distance","距离"},{"cast","施法条"}},function() return page.layoutGroup end,function(v)
        if (v=="metadata" or v=="distance" or v=="cast") and page.layoutScope~="target" then page.layoutScope="target" end
        local p=P()
        if p and p.UI then
            if p.UI.SetCalibration then p.UI:SetCalibration(nil) end
            if p.UI.SetLayoutEdit then p.UI:SetLayoutEdit(nil,nil) end
        end
        page.layoutGroup=v
    end)
    page.layoutTypeTabs=MakeTabs("layout","layout_type",{{"buff","Buff"},{"debuff","Debuff"},{"hidden","Hidden"}},function() return page.layoutType end,function(v) page.layoutType=v end)
    page.colorScopeTabs=MakeTabs("colors","color_scope",{{"target","目标 HUD"},{"player","自身 HUD"}},function() return page.colorScope end,function(v) page.colorRuleMode=false;page.colorScope=v end)
    page.colorTypeTabs=MakeTabs("colors","color_type",{{"buff","Buff"},{"debuff","Debuff"},{"hidden","Hidden"}},function() return page.colorType end,function(v) page.colorRuleMode=false;page.colorType=v end)

    page:AddInfo("display","summary",function()
        local c=Cfg(page.hudScope) or {}; local p=P(); local n=p and p.Storage and p.Storage:ActiveTrackedCount(page.hudScope,"hidden") or 0
        return ScopeTitle(page.hudScope).." · Buff "..BoolText(c.showBuffs).." / Debuff "..BoolText(c.showDebuffs).." / Hidden "..BoolText(c.showHidden).." · Hidden 白名单启用 "..tostring(n)
    end)
    page:AddControl("display","hud",function() return ScopeTitle(page.hudScope).."显示："..BoolText(HudVisible(page.hudScope)) end,function() SetHudVisible(page.hudScope) end)
    page:AddControl("display","buff",function() local c=Cfg(page.hudScope);return "Buff 显示："..BoolText(c and c.showBuffs) end,function() Toggle(page.hudScope,"showBuffs") end)
    page:AddControl("display","debuff",function() local c=Cfg(page.hudScope);return "Debuff 显示："..BoolText(c and c.showDebuffs) end,function() Toggle(page.hudScope,"showDebuffs") end)
    page:AddControl("display","hidden",function() local c=Cfg(page.hudScope);return "Hidden 显示："..BoolText(c and c.showHidden) end,function() Toggle(page.hudScope,"showHidden") end)
    page:AddControl("display","tracked",function() local c=Cfg(page.hudScope);return "Buff/Debuff 筛选："..((c and c.trackedOnly) and "仅追踪" or "全部") end,function() Toggle(page.hudScope,"trackedOnly") end)
    page:AddControl("display","pvp",function() local c=Cfg(page.hudScope);return "会话候选发现："..BoolText(c and c.autoPvPRelevant) end,function() Toggle(page.hudScope,"autoPvPRelevant") end)
    page:AddControl("display","specific1",function()
        local c=Cfg(page.hudScope) or {}; return page.hudScope=="target" and ("施法条："..BoolText(c.showCast)) or ("装备图标："..BoolText(c.showEquipment))
    end,function() Toggle(page.hudScope,page.hudScope=="target" and "showCast" or "showEquipment") end)
    page:AddControl("display","specific2",function()
        local c=Cfg(page.hudScope) or {}; return page.hudScope=="target" and ("距离："..BoolText(c.showDistance)) or ("重要冷却："..BoolText(c.showImportantCooldowns))
    end,function() Toggle(page.hudScope,page.hudScope=="target" and "showDistance" or "showImportantCooldowns") end)
    page:AddControl("display","specific3",function()
        local c=Cfg(page.hudScope) or {}; return page.hudScope=="target" and ("职业/装等/武器："..BoolText(c.showClass or c.showGear or c.showLoadout)) or "自身 HUD：无额外目标信息"
    end,function()
        if page.hudScope=="target" then Mutate("target",function(c) local on=not(c.showClass==true and c.showGear==true and c.showLoadout==true);c.showClass=on;c.showGear=on;c.showLoadout=on end) end
    end)

    --------------------------------------------------------------------------
    -- watchtarget aggro/distance mini-windows (report 七-C). Two toggles live
    -- in the existing 显示设置 section; the distance thresholds live in the
    -- existing 颜色与样式 section. No new section, so no three-piece layout.
    -- Config is top-level plates storage .watchtarget, same pattern as buffcap.
    --------------------------------------------------------------------------
    local function WatchCfg()
        local p=P(); if not p or not p.Storage then return nil end
        local cfg=p.Storage:Get().watchtarget
        if type(cfg)~="table" then cfg={}; p.Storage:Get().watchtarget=cfg end
        return cfg
    end
    local function MutateWatch(fn,label)
        local p=P(); if not p or not p.Storage then return false end
        local cfg=p.Storage:Get().watchtarget
        if type(cfg)~="table" then return false end
        local ok,err=xpcall(function() fn(cfg) end,S.SafeTraceback)
        if not ok then S.SafeChat((label or "追踪目标设置").."修改失败："..tostring(err),"error","plates"); return false end
        p.Storage:MarkDirty()
        local saved,saveErr=p.Storage:Save(true)
        if not saved then S.SafeChat((label or "追踪目标设置").."保存失败："..tostring(saveErr),"error","plates"); return false end
        if p.Runtime and type(p.Runtime.UpdateWatchWindows)=="function" then
            pcall(function() p.Runtime:UpdateWatchWindows() end)
        end
        return true
    end
    page:AddControl("display","watch_aggro",function()
        local c=WatchCfg(); return "追踪目标仇恨窗："..BoolText(c and c.aggroEnabled) end,
        function() MutateWatch(function(c) c.aggroEnabled=not(c.aggroEnabled==true) end,"仇恨窗") end)
    page:AddControl("display","watch_dist",function()
        local c=WatchCfg(); return "追踪目标距离窗："..BoolText(c and c.distEnabled) end,
        function() MutateWatch(function(c) c.distEnabled=not(c.distEnabled==true) end,"距离窗") end)
    page:AddNumericControl("colors","watch_orange","距离橙色阈值(米)",10,500,1,
        function() local c=WatchCfg(); return c and c.orangeAt or 150 end,
        function(v) return MutateWatch(function(c) c.orangeAt=math.floor(v+0.5); if tonumber(c.redAt)~=nil and c.redAt<c.orangeAt then c.redAt=c.orangeAt end end,"距离橙色阈值") end,{integer=true})
    page:AddNumericControl("colors","watch_red","距离红色阈值(米)",10,500,1,
        function() local c=WatchCfg(); return c and c.redAt or 200 end,
        function(v) return MutateWatch(function(c) c.redAt=math.floor(v+0.5) end,"距离红色阈值") end,{integer=true})

    --------------------------------------------------------------------------
    -- Combat alerts (report 七-方案A). Top-level plates storage .alerts; same
    -- save/live-refresh pattern as buffcap/magiccircle. Layout branch is added
    -- in ApplyLayout; SearchSettings + OpenSuitePage map to this section (C14
    -- three-piece).
    --------------------------------------------------------------------------
    local function AlertCfg()
        local p=P(); if not p or not p.Storage then return nil end
        local cfg=p.Storage:Get().alerts
        if type(cfg)~="table" then cfg={}; p.Storage:Get().alerts=cfg end
        return cfg
    end
    local function MutateAlerts(fn,label)
        local p=P(); if not p or not p.Storage then return false end
        local cfg=p.Storage:Get().alerts
        if type(cfg)~="table" then return false end
        local ok,err=xpcall(function() fn(cfg) end,S.SafeTraceback)
        if not ok then S.SafeChat((label or "战斗警报设置").."修改失败："..tostring(err),"error","plates"); return false end
        p.Storage:MarkDirty()
        local saved,saveErr=p.Storage:Save(true)
        if not saved then S.SafeChat((label or "战斗警报设置").."保存失败："..tostring(saveErr),"error","plates"); return false end
        if p.Runtime and type(p.Runtime.UpdateAlerts)=="function" then
            pcall(function() p.Runtime:UpdateAlerts() end)
        end
        return true
    end
    page:AddControl("alerts","enabled",function()
        local c=AlertCfg(); return "战斗警报："..BoolText(c and c.enabled) end,
        function() MutateAlerts(function(c) c.enabled=not(c.enabled==true) end,"战斗警报") end)
    page:AddControl("alerts","scope",function()
        local c=AlertCfg(); local scope=c and c.scope or "target+player"
        local label=scope=="target" and "目标" or scope=="player" and "自己" or "目标+自己"
        return "监视范围："..label end,
        function() MutateAlerts(function(c)
            c.scope=c.scope=="target" and "player" or c.scope=="player" and "target+player" or "target"
        end,"监视范围") end)
    page:AddControl("alerts","style",function()
        local c=AlertCfg(); local style=c and c.style or "countdown"
        return "警报样式："..(style=="countdown" and "倒计时+大字" or "仅大字") end,
        function() MutateAlerts(function(c) c.style=c.style=="countdown" and "bigtext" or "countdown" end,"警报样式") end)
    page:AddControl("alerts","anchor",function()
        local c=AlertCfg(); local anchor=c and c.anchorMode or "center"
        return "警报位置："..(anchor=="center" and "屏幕中央" or "顶部中央") end,
        function() MutateAlerts(function(c) c.anchorMode=c.anchorMode=="center" and "top" or "center" end,"警报位置") end)
    page:AddNumericControl("alerts","scale","警报大小",60,200,1,
        function() local c=AlertCfg(); return c and c.scale or 100 end,
        function(v) return MutateAlerts(function(c) c.scale=math.floor(v+0.5) end,"警报大小") end,{integer=true,suffix="%"})

    -- Data-driven per-alert switches (S.Data.BossAlerts). items[key]==false -> off.
    local function AlertItemsCfg()
        local c=AlertCfg()
        if type(c.items)~="table" then c.items={} end
        return c.items
    end
    local function AlertEnabled(key)
        return AlertItemsCfg()[key] ~= false
    end
    page:AddControl("alerts","items_header",function()
        return "── 内置警报（数据驱动） ──" end,
        function() end)
    local bossAlerts = S.Data and S.Data.BossAlerts or {}
    for _, entry in ipairs(bossAlerts) do
        local key = tostring(entry.key or "")
        if key ~= "" then
            local alertKey = key
            local alertText = tostring(entry.alert or key)
            page:AddControl("alerts","item_"..alertKey,function()
                return alertText.."："..BoolText(AlertEnabled(alertKey))
            end,function()
                return MutateAlerts(function(c)
                    if type(c.items)~="table" then c.items={} end
                    c.items[alertKey]=not (c.items[alertKey]==true)
                end,"警报开关")
            end)
        end
    end
    -- Custom debuff alert by id (reuses the tracking-page "add by id" pattern).
    page:AddControl("alerts","custom",function()
        local c=AlertCfg(); local count=0
        if type(c.custom)=="table" then for _ in pairs(c.custom) do count=count+1 end end
        return "自定义 Debuff 警报："..tostring(count).." 条（点击添加）" end,
        function() MutateAlerts(function(c)
            if type(c.custom)~="table" then c.custom={} end
            S.SafeChat("输入格式：DebuffID|文案（如 9999|快躲开）")
        end,"自定义警报") end)
    -- Preview alert (3·2·1) - mock self-test of the styles, no real boss needed.
    page:AddControl("alerts","preview",function()
        return "预览警报（3·2·1）" end,
        function()
            local alerts=S.Services and S.Services.Alerts
            if alerts==nil or type(alerts.Push)~="function" then
                S.SafeChat("警报通道尚未就绪"); return false
            end
            local c=AlertCfg()
            alerts:Push({ text="警报预览", style="bigtext", durationMs=1000, remainingMs=0 })
            local function CountdownStep(n)
                if n<=0 then
                    alerts:Push({ text="警报预览！", style="countdown", durationMs=2000, remainingMs=2000 })
                    return
                end
                alerts:Push({ text="警报预览", style="countdown", durationMs=1000, remainingMs=n*1000 })
                if S.Scheduler~=nil and type(S.Scheduler.AddTask)=="function" then
                    S.Scheduler:AddTask("alerts_preview", 1000, function() CountdownStep(n-1) end, false, nil, "P5")
                end
            end
            CountdownStep(3)
            return true
        end)
    -- F3: full-pipeline simulation. Injects a mock cast (e.g. 黑龙"大地强击")
    -- through the REAL AlertMatch -> Push -> render -> expire path, so the user
    -- can test position/size/style without fighting a boss. Text carries
    -- "[模拟]" to distinguish it from real alerts.
    page:AddControl("alerts","simulate",function()
        return "模拟警报（完整链路测试）" end,
        function()
            local p=P(); if not p or not p.Runtime then
                S.SafeChat("BUFF显示运行时未就绪"); return false
            end
            if type(p.Runtime.SimulateAlert)~="function" then
                S.SafeChat("模拟警报尚未实现"); return false
            end
            local ok,err=xpcall(function() return p.Runtime:SimulateAlert(nil) end,S.SafeTraceback)
            if not ok then S.SafeChat("模拟警报失败："..tostring(err)); return false end
            return true
        end)

    --------------------------------------------------------------------------
    -- Unit connection lines (report 七-方案B). Top-level plates storage .lines;
    -- same save/live-refresh pattern. Layout branch added in ApplyLayout;
    -- SearchSettings + OpenSuitePage map to this section (C14 three-piece).
    --------------------------------------------------------------------------
    local function LinesCfg()
        local p=P(); if not p or not p.Storage then return nil end
        local cfg=p.Storage:Get().lines
        if type(cfg)~="table" then cfg={}; p.Storage:Get().lines=cfg end
        return cfg
    end
    local function MutateLines(fn,label)
        local p=P(); if not p or not p.Storage then return false end
        local cfg=p.Storage:Get().lines
        if type(cfg)~="table" then return false end
        local ok,err=xpcall(function() fn(cfg) end,S.SafeTraceback)
        if not ok then S.SafeChat((label or "单位连线设置").."修改失败："..tostring(err),"error","plates"); return false end
        p.Storage:MarkDirty()
        local saved,saveErr=p.Storage:Save(true)
        if not saved then S.SafeChat((label or "单位连线设置").."保存失败："..tostring(saveErr),"error","plates"); return false end
        if p.Runtime and type(p.Runtime.UpdateLines)=="function" then
            pcall(function() p.Runtime:UpdateLines() end)
        end
        return true
    end
    page:AddControl("lines","enabled",function()
        local c=LinesCfg(); return "单位连线："..BoolText(c and c.enabled) end,
        function() MutateLines(function(c) c.enabled=not(c.enabled==true) end,"单位连线") end)
    local linePairLabels = {
        target="目标", targetoftarget="目标的目标", watchtarget="追踪目标", watchtargettarget="追踪目标的目标",
    }
    for _, key in ipairs({"target","targetoftarget","watchtarget","watchtargettarget"}) do
        local pairKey = key
        local pairLabel = linePairLabels[key] or key
        page:AddControl("lines","pair_"..key,function()
            local c=LinesCfg(); local on=(type(c)=="table" and type(c.pairs)=="table" and c.pairs[pairKey]==true)
            return pairLabel.."连线："..BoolText(on) end,
            function() MutateLines(function(c)
                if type(c.pairs)~="table" then c.pairs={} end
                c.pairs[pairKey]=not (c.pairs[pairKey]==true)
            end,"连线开关") end)
    end
    page:AddControl("lines","from_target",function()
        local c=LinesCfg(); return "目标线起点："..((c and c.targetFromPlayer) and "玩家" or "目标") end,
        function() MutateLines(function(c) c.targetFromPlayer=not(c.targetFromPlayer==true) end,"目标线起点") end)
    page:AddControl("lines","from_watch",function()
        local c=LinesCfg(); return "追踪线起点："..((c and c.watchFromPlayer) and "玩家" or "追踪目标") end,
        function() MutateLines(function(c) c.watchFromPlayer=not(c.watchFromPlayer==true) end,"追踪线起点") end)
    page:AddNumericControl("lines","minDots","最小点数",4,128,1,
        function() local c=LinesCfg(); return c and c.minDots or 8 end,
        function(v) return MutateLines(function(c) c.minDots=math.floor(v+0.5); if c.maxDots<c.minDots then c.maxDots=c.minDots end end,"最小点数") end,{integer=true})
    page:AddNumericControl("lines","maxDots","最大点数",4,128,1,
        function() local c=LinesCfg(); return c and c.maxDots or 64 end,
        function(v) return MutateLines(function(c) c.maxDots=math.floor(v+0.5) end,"最大点数") end,{integer=true})
    page:AddNumericControl("lines","dotFontSize","点大小(字号)",8,40,1,
        function() local c=LinesCfg(); return c and c.dotFontSize or 15 end,
        function(v) return MutateLines(function(c) c.dotFontSize=math.floor(v+0.5) end,"点大小") end,{integer=true})
    page:AddNumericControl("lines","dotAlpha","点透明度",20,100,1,
        function() local c=LinesCfg(); return c and c.dotAlpha or 100 end,
        function(v) return MutateLines(function(c) c.dotAlpha=math.floor(v+0.5) end,"点透明度") end,{integer=true,suffix="%"})
    page:AddControl("lines","preview",function()
        return "预览：对当前目标画线" end,
        function()
            local p=P(); if not p or not p.Runtime then return false end
            local c=LinesCfg()
            if type(c)~="table" or c.enabled~=true then
                MutateLines(function(x) x.enabled=true end,"预览")
            end
            if p.Runtime and type(p.Runtime.UpdateLines)=="function" then
                pcall(function() p.Runtime:UpdateLines() end)
            end
            S.SafeChat("已开启单位连线并刷新（关闭当前目标可隐藏）")
            return true
        end)

    -- F5: player-centred distance circle. Config nests under lines.circle;
    -- colour/font/alpha reuse the lines dot config above.
    local function CircleCfg()
        local c=LinesCfg()
        if type(c.circle)~="table" then c.circle={} end
        return c.circle
    end
    page:AddControl("lines","circle_enabled",function()
        local c=CircleCfg(); return "自身距离圆："..BoolText(c.enabled) end,
        function() MutateLines(function(x)
            if type(x.circle)~="table" then x.circle={} end
            x.circle.enabled=not(x.circle.enabled==true)
        end,"自身距离圆") end)
    page:AddNumericControl("lines","circle_radius","距离圆半径(米)",5,50,1,
        function() local c=CircleCfg(); return c.radiusM or 20 end,
        function(v) return MutateLines(function(x)
            if type(x.circle)~="table" then x.circle={} end
            x.circle.radiusM=math.floor(v+0.5)
        end,"距离圆半径") end,{integer=true,suffix="m"})
    page:AddNumericControl("lines","circle_dots","距离圆点数",24,128,4,
        function() local c=CircleCfg(); return c.dots or 72 end,
        function(v) return MutateLines(function(x)
            if type(x.circle)~="table" then x.circle={} end
            x.circle.dots=math.max(24, math.min(128, math.floor(v/4+0.5)*4))
        end,"距离圆点数") end,{integer=true})
    -- Optimize 1: configurable line/circle update cadence (ms). Higher = lighter.
    page:AddNumericControl("lines","update_ms","连线更新频率(毫秒)",50,500,10,
        function() local c=LinesCfg(); return c and c.updateMs or 100 end,
        function(v) return MutateLines(function(c)
            c.updateMs=math.max(50, math.min(500, math.floor(v/10+0.5)*10))
        end,"连线更新频率") end,{integer=true,suffix="ms"})

    --------------------------------------------------------------------------
    -- Buff-cap warning (report 八-P0-1). Config lives at the top level of
    -- plates storage (not per-scope), so these controls use their own save
    -- path; every change fires UpdateBuffCap immediately for live feedback.
    --------------------------------------------------------------------------
    local function BuffCapCfg()
        local p=P(); if not p or not p.Storage then return nil end
        local cfg=p.Storage:Get().buffcap
        if type(cfg)~="table" then cfg={}; p.Storage:Get().buffcap=cfg end
        return cfg
    end
    local function MutateBuffCap(fn)
        local p=P(); if not p or not p.Storage then return false end
        local cfg=p.Storage:Get().buffcap
        if type(cfg)~="table" then return false end
        local ok,err=xpcall(function() fn(cfg) end,S.SafeTraceback)
        if not ok then S.SafeChat("BUFF上限设置修改失败："..tostring(err),"error","plates"); return false end
        p.Storage:MarkDirty()
        local saved,saveErr=p.Storage:Save(true)
        if not saved then S.SafeChat("BUFF上限设置保存失败："..tostring(saveErr),"error","plates"); return false end
        if p.Runtime and type(p.Runtime.UpdateBuffCap)=="function" then
            pcall(function() p.Runtime:UpdateBuffCap() end)
        end
        return true
    end
    page:AddControl("buffcap","enabled",function()
        local c=BuffCapCfg(); return "buff上限提醒："..BoolText(c and c.enabled) end,
        function() MutateBuffCap(function(c) c.enabled=not(c.enabled==true) end) end)
    page:AddNumericControl("buffcap","threshold","阈值",20,50,1,
        function() local c=BuffCapCfg(); return c and c.threshold or 36 end,
        function(v) return MutateBuffCap(function(c) c.threshold=math.floor(v+0.5) end) end,{integer=true})
    page:AddNumericControl("buffcap","font","字号",9,18,1,
        function() local c=BuffCapCfg(); return c and c.fontSize or 12 end,
        function(v) return MutateBuffCap(function(c) c.fontSize=math.floor(v+0.5) end) end,{integer=true})
    page:AddNumericControl("buffcap","offsetx","横向偏移",-400,400,10,
        function() local c=BuffCapCfg(); return c and c.offsetX or 0 end,
        function(v) return MutateBuffCap(function(c) c.offsetX=math.floor(v+0.5) end) end,{integer=true})
    page:AddNumericControl("buffcap","offsety","纵向偏移",0,400,10,
        function() local c=BuffCapCfg(); return c and c.offsetY or 8 end,
        function(v) return MutateBuffCap(function(c) c.offsetY=math.floor(v+0.5) end) end,{integer=true})

    --------------------------------------------------------------------------
    -- Magic-circle distance (report 八-P1-1). Config lives at the top level
    -- of plates storage; same save/live-refresh pattern as buffcap. buffIds
    -- are shown read-only (editing goes through export/import) because they
    -- are only verified on a live client.
    --------------------------------------------------------------------------
    local function MagicCircleCfg()
        local p=P(); if not p or not p.Storage then return nil end
        local cfg=p.Storage:Get().magiccircle
        if type(cfg)~="table" then cfg={}; p.Storage:Get().magiccircle=cfg end
        return cfg
    end
    local function MutateMagicCircle(fn)
        local p=P(); if not p or not p.Storage then return false end
        local cfg=p.Storage:Get().magiccircle
        if type(cfg)~="table" then return false end
        local ok,err=xpcall(function() fn(cfg) end,S.SafeTraceback)
        if not ok then S.SafeChat("魔法阵距离设置修改失败："..tostring(err),"error","plates"); return false end
        p.Storage:MarkDirty()
        local saved,saveErr=p.Storage:Save(true)
        if not saved then S.SafeChat("魔法阵距离设置保存失败："..tostring(saveErr),"error","plates"); return false end
        if p.Runtime and type(p.Runtime.UpdateMagicCircle)=="function" then
            pcall(function() p.Runtime:UpdateMagicCircle() end)
        end
        return true
    end
    page:AddControl("magiccircle","enabled",function()
        local c=MagicCircleCfg(); return "魔法阵距离提醒："..BoolText(c and c.enabled) end,
        function() MutateMagicCircle(function(c) c.enabled=not(c.enabled==true) end) end)
    page:AddNumericControl("magiccircle","fontSize","字号",9,18,1,
        function() local c=MagicCircleCfg(); return c and c.fontSize or 11 end,
        function(v) return MutateMagicCircle(function(c) c.fontSize=math.floor(v+0.5) end) end,{integer=true})
    page:AddNumericControl("magiccircle","alpha","透明度",30,100,1,
        function() local c=MagicCircleCfg(); return c and c.alpha or 95 end,
        function(v) return MutateMagicCircle(function(c) c.alpha=math.floor(v+0.5) end) end,{integer=true})
    page:AddNumericControl("magiccircle","offsetX","横向偏移",-200,200,2,
        function() local c=MagicCircleCfg(); return c and c.offsetX or 18 end,
        function(v) return MutateMagicCircle(function(c) c.offsetX=math.floor(v+0.5) end) end,{integer=true})
    page:AddNumericControl("magiccircle","offsetY","纵向偏移",-200,200,2,
        function() local c=MagicCircleCfg(); return c and c.offsetY or -6 end,
        function(v) return MutateMagicCircle(function(c) c.offsetY=math.floor(v+0.5) end) end,{integer=true})
    page:AddNumericControl("magiccircle","warnM","警告距离(米)",10,40,0.5,
        function() local c=MagicCircleCfg(); return c and c.warnM or 25 end,
        function(v) return MutateMagicCircle(function(c) c.warnM=v end) end)
    page:AddNumericControl("magiccircle","maxM","最大距离(米)",15,45,0.1,
        function() local c=MagicCircleCfg(); return c and c.maxM or 29.9 end,
        function(v) return MutateMagicCircle(function(c) c.maxM=v end) end)
    page:AddInfo("magiccircle","buffids",function()
        local c=MagicCircleCfg()
        local ids=type(c)=="table" and type(c.buffIds)=="table" and c.buffIds or {}
        return "追踪 Buff ID："..table.concat(ids,",").."(只读,修改走导入导出;待真机验证)"
    end)

    --------------------------------------------------------------------------
    -- Target-only appearance helpers.
    -- 玩家信息与距离属于 HUD 的视觉组成，不再占用独立一级选项卡。
    -- 这里只创建开关卡片；数值滑块在统一 Layout 数值控件建立后追加，
    -- 从而与 Buff/Debuff/Hidden 使用完全相同的紧凑横向布局。
    --------------------------------------------------------------------------
    local function TargetGroup(group)
        local c=Cfg("target");return c and type(c[group])=="table" and c[group] or nil
    end
    local function SetTargetGroup(group,key,value,staged)
        local f=function(c)
            c[group]=type(c[group])=="table" and c[group] or {}
            c[group][key]=value
        end
        if staged then return Stage("target",f) end
        return Mutate("target",f)
    end

    page.layoutMetadataControls={}
    page.layoutDistanceControls={}
    page.layoutCastControls={}
    page.layoutEquipmentControls={}
    local function AddLayoutControl(bucket,id,textFn,clickFn)
        page:AddControl("layout",id,textFn,clickFn)
        local sec=page.sections.layout
        local it=sec and sec.controls and sec.controls[#sec.controls] or nil
        if it then bucket[#bucket+1]=it end
        return it
    end

    page.layoutMetadataHint=S.UI:CreateLabel(page.root,"plates_layout_metadata_hint",
        "目标 HUD：职业/装等/武器均为独立位置；拖出基础框不会撑大外框，也不会挤动其他元素。",
        0,0,100,34,9,"muted",ALIGN_LEFT);page:RegisterWidget("layout",page.layoutMetadataHint)
    page.layoutDistanceHint=S.UI:CreateLabel(page.root,"plates_layout_distance_hint",
        "目标 HUD · 距离：显示位置与字号属于外观；提醒/危险阈值只改变距离文字提示样式。",
        0,0,100,34,9,"muted",ALIGN_LEFT);page:RegisterWidget("layout",page.layoutDistanceHint)
    page.layoutCastHint=S.UI:CreateLabel(page.root,"plates_layout_cast_hint",
        "目标 HUD · 施法条：条体、图标、技能名称和时间文字均为独立坐标；可拖出基础框，不会撑大外框或挤动其他元素。",
        0,0,100,34,9,"muted",ALIGN_LEFT);page:RegisterWidget("layout",page.layoutCastHint)
    page.layoutEquipmentHint=S.UI:CreateLabel(page.root,"plates_layout_equipment_hint",
        "自身 HUD · 装备图标：可整体关闭，也可单独隐藏背部/滑翔翼、主手、副手或远程武器。",
        0,0,100,34,9,"muted",ALIGN_LEFT);page:RegisterWidget("layout",page.layoutEquipmentHint)

    AddLayoutControl(page.layoutMetadataControls,"meta_class_show",function() local c=Cfg("target");return "职业信息："..BoolText(c and c.showClass) end,function() Toggle("target","showClass") end)
    AddLayoutControl(page.layoutMetadataControls,"meta_class_icon",function() local c=TargetGroup("class");return "职业图标："..BoolText(c and c.showIcon) end,function() Mutate("target",function(c) c.class=type(c.class)=="table" and c.class or {};c.class.showIcon=not(c.class.showIcon==true) end) end)
    AddLayoutControl(page.layoutMetadataControls,"meta_class_name",function() local c=TargetGroup("class");return "职业名称："..BoolText(c and c.showName) end,function() Mutate("target",function(c) c.class=type(c.class)=="table" and c.class or {};c.class.showName=not(c.class.showName==true) end) end)
    AddLayoutControl(page.layoutMetadataControls,"meta_gear_show",function() local c=Cfg("target");return "装等："..BoolText(c and c.showGear) end,function() Toggle("target","showGear") end)
    AddLayoutControl(page.layoutMetadataControls,"meta_loadout_show",function() local c=Cfg("target");return "武器状态："..BoolText(c and c.showLoadout) end,function() Toggle("target","showLoadout") end)

    AddLayoutControl(page.layoutDistanceControls,"distance_show",function() local c=Cfg("target");return "距离显示："..BoolText(c and c.showDistance) end,function() Toggle("target","showDistance") end)

    local function TargetCast()
        local c=Cfg("target")
        return c and type(c.cast)=="table" and c.cast or nil
    end
    local function ToggleTargetCastValue(key, defaultOn)
        Mutate("target",function(c)
            c.cast=type(c.cast)=="table" and c.cast or {}
            local current=c.cast[key]
            if current==nil then current=defaultOn==true end
            c.cast[key]=not(current==true)
        end)
    end
    AddLayoutControl(page.layoutCastControls,"cast_show",function()
        local c=Cfg("target");return "施法条显示："..BoolText(c and c.showCast)
    end,function() Toggle("target","showCast") end)
    AddLayoutControl(page.layoutCastControls,"cast_name_show",function()
        local c=TargetCast();return "技能名称文字："..BoolText(c==nil or c.showName~=false)
    end,function() ToggleTargetCastValue("showName",true) end)
    AddLayoutControl(page.layoutCastControls,"cast_time_show",function()
        local c=TargetCast();return "时间文字："..BoolText(c==nil or c.showTime~=false)
    end,function() ToggleTargetCastValue("showTime",true) end)
    AddLayoutControl(page.layoutCastControls,"cast_width_mode",function()
        local c=TargetCast();return "宽度模式："..((c and (tonumber(c.width) or 0)>0) and "固定" or "自动")
    end,function()
        Mutate("target",function(c)
            c.cast=type(c.cast)=="table" and c.cast or {}
            local w=tonumber(c.cast.width) or 0
            if w>0 then c.cast.width=0 else c.cast.width=math.max(90,math.min(450,(tonumber(c.width) or 286)-14)) end
        end)
    end)

    local function PlayerEquipment()
        local c=Cfg("player")
        return c and type(c.equipment)=="table" and c.equipment or nil
    end
    local function TogglePlayerEquipmentSlot(key)
        Mutate("player",function(c)
            c.equipment=type(c.equipment)=="table" and c.equipment or {}
            c.equipment[key]=not(c.equipment[key]==true)
        end)
    end
    AddLayoutControl(page.layoutEquipmentControls,"equipment_show",function()
        local c=Cfg("player");return "装备图标总开关："..BoolText(c and c.showEquipment)
    end,function() Toggle("player","showEquipment") end)
    AddLayoutControl(page.layoutEquipmentControls,"equipment_glider",function()
        local c=PlayerEquipment();return "背部 / 滑翔翼："..BoolText(c and c.showGlider)
    end,function() TogglePlayerEquipmentSlot("showGlider") end)
    AddLayoutControl(page.layoutEquipmentControls,"equipment_mainhand",function()
        local c=PlayerEquipment();return "主手："..BoolText(c and c.showMainhand)
    end,function() TogglePlayerEquipmentSlot("showMainhand") end)
    AddLayoutControl(page.layoutEquipmentControls,"equipment_offhand",function()
        local c=PlayerEquipment();return "副手："..BoolText(c and c.showOffhand)
    end,function() TogglePlayerEquipmentSlot("showOffhand") end)
    AddLayoutControl(page.layoutEquipmentControls,"equipment_ranged",function()
        local c=PlayerEquipment();return "远程武器："..BoolText(c and c.showRanged)
    end,function() TogglePlayerEquipmentSlot("showRanged") end)

    --------------------------------------------------------------------------
    -- Tracking: icon-first rows + live scan / manual id / known database.
    --------------------------------------------------------------------------
    page.trackState=S.UI:CreateLabel(page.root,"plates_track_state","",0,0,100,20,9,"muted",ALIGN_LEFT);page:RegisterWidget("tracking",page.trackState)
    page.trackDetect=S.UI:CreateButton(page.root,"plates_track_detect","开始检测",0,0,88,26,9,false,true);page:RegisterWidget("tracking",page.trackDetect)
    page.trackQueue=S.UI:CreateButton(page.root,"plates_track_queue","队列保留：开",0,0,100,26,9,false,true);page:RegisterWidget("tracking",page.trackQueue)
    page.trackClearQueue=S.UI:CreateButton(page.root,"plates_track_clear_queue","清空队列",0,0,78,26,9,false,true);page:RegisterWidget("tracking",page.trackClearQueue)
    page.trackScan=S.UI:CreateButton(page.root,"plates_track_scan","立即扫描",0,0,82,26,9,false,true);page:RegisterWidget("tracking",page.trackScan)
    page.trackRaw=S.UI:CreateButton(page.root,"plates_track_raw","原始/未知：关",0,0,104,26,9,false,true);page:RegisterWidget("tracking",page.trackRaw)
    page.trackSync=S.UI:CreateButton(page.root,"plates_track_sync","同步加入：关",0,0,92,26,9,false,true);page:RegisterWidget("tracking",page.trackSync)
    page.trackSyncMode=S.UI:CreateButton(page.root,"plates_track_sync_mode","同步范围：同类",0,0,100,26,9,false,true);page:RegisterWidget("tracking",page.trackSyncMode)
    page.trackPrev=S.UI:CreateButton(page.root,"plates_track_prev","上一页",0,0,70,24,8,false);page:RegisterWidget("tracking",page.trackPrev)
    page.trackNext=S.UI:CreateButton(page.root,"plates_track_next","下一页",0,0,70,24,8,false);page:RegisterWidget("tracking",page.trackNext)
    local function EnsureCaptureUiRefresh()
        if S.Scheduler==nil or type(S.Scheduler.AddTask)~="function" then return end
        S.Scheduler:RemoveTask("plates_ui_capture_refresh")
        S.Scheduler:AddTask("plates_ui_capture_refresh",250,function()
            local p=P();if not p or not p.Manager or not p.Manager:IsCaptureEnabled() then S.Scheduler:RemoveTask("plates_ui_capture_refresh");return end
            if S.UI and S.UI.currentPage=="plates" and page.activeSection=="tracking" and page.trackSource=="capture" then page:Refresh() end
        end,false,page,"P3")
    end
    S.UI:SafeHandler(page.trackDetect,"OnClick",function()
        local p=P();if not p or not p.Manager then return end
        local nextOn=not p.Manager:IsCaptureEnabled()
        p.Manager:SetCaptureEnabled(nextOn,page.trackScope,page.trackType)
        if nextOn then
            page.trackView="current";page.trackSource="capture";page.trackOffset=0;page.selectedTrackId=nil
            p.Manager:CaptureFast();EnsureCaptureUiRefresh()
            S.SafeChat("BUFF显示：持续检测已开始；目标与自身 HUD 的 Buff / Debuff 同时捕获。")
        else
            if S.Scheduler then S.Scheduler:RemoveTask("plates_ui_capture_refresh") end
            S.SafeChat("BUFF显示：持续检测已停止；已捕获队列仍保留。")
        end
        page:Refresh()
    end,"plates:track_detect")
    S.UI:SafeHandler(page.trackQueue,"OnClick",function()
        local p=P();if not p or not p.Manager then return end
        -- Read the authoritative source the same way the button label is drawn
        -- in Refresh(), so the value we toggle always matches what the user sees.
        -- The sticky setting is owned by TargetService (persisted to
        -- S.State.settings.targetDetectionQueueRetain) and only mirrored into the
        -- Plates Manager, so derive the next state from there, not from Manager.
        -- NOTE: the service is registered as S.TargetService, NOT S.Services.Target
        -- (that field is never assigned), so use the correct reference.
        local targetSvc = S.TargetService
        local function CurrentSticky()
            if targetSvc ~= nil and type(targetSvc.IsQueueRetain) == "function" then return targetSvc:IsQueueRetain() end
            return p.Manager:IsCaptureSticky()
        end
        local nextSticky = not CurrentSticky()
        if targetSvc ~= nil and type(targetSvc.SetQueueRetain) == "function" then
            targetSvc:SetQueueRetain(nextSticky)
        else
            p.Manager:SetCaptureSticky(nextSticky)
            if S.Storage ~= nil and type(S.Storage.RequestSave) == "function" then S.Storage:RequestSave() end
        end
        page.trackSource="capture";page.trackView="current";page.trackOffset=0;page:Refresh()
    end,"plates:track_queue")
    S.UI:SafeHandler(page.trackClearQueue,"OnClick",function()
        local p=P();if not p or not p.Manager then return end
        -- All-lanes capture: clearing without args drops every lane at once.
        if p.Manager.capture and p.Manager.capture.allLanes==true then
            p.Manager:ClearCaptureQueue(nil,nil)
        else
            p.Manager:ClearCaptureQueue(page.trackScope,page.trackType)
        end
        page.trackSource="capture";page.trackView="current";page.trackOffset=0;page:Refresh()
    end,"plates:track_clear_queue")
    S.UI:SafeHandler(page.trackRaw,"OnClick",function() if page.trackType=="hidden" then page.showRawHidden=not page.showRawHidden;page.trackLive={};page.trackOffset=0;page:Refresh() end end,"plates:track_raw")
    S.UI:SafeHandler(page.trackSync,"OnClick",function()
        local p=P();if not p or not p.Storage or page.trackType=="hidden" then return end
        local ok,err=p.Storage:SetAuraSyncEnabled(not p.Storage:IsAuraSyncEnabled())
        if not ok then S.SafeChat("同步设置保存失败："..tostring(err),"error","plates") end
        page:Refresh()
    end,"plates:track_sync")
    S.UI:SafeHandler(page.trackSyncMode,"OnClick",function()
        local p=P();if not p or not p.Storage or page.trackType=="hidden" then return end
        local nextMode=p.Storage:GetAuraSyncMode()=="all" and "same" or "all"
        local ok,err=p.Storage:SetAuraSyncMode(nextMode);if not ok then S.SafeChat("同步范围保存失败："..tostring(err),"error","plates") end
        page:Refresh()
    end,"plates:track_sync_mode")
    local function ScanCurrent()
        local p=P(); if not p or not p.Api or not p.Api.GetEffectCatalog then return end
        page.trackLive=p.Api:GetEffectCatalog(page.trackScope,page.trackType,128,page.trackType=="hidden" and page.showRawHidden) or {}
        page.trackView="current";page.trackSource="live";page.trackOffset=0;page.selectedTrackId=nil
        S.SafeChat("BUFF显示："..ScopeTitle(page.trackScope).."扫描到 "..tostring(#page.trackLive).." 个"..TrackTypeTitle(page.trackType).."候选。")
        page:Refresh()
    end
    S.UI:SafeHandler(page.trackScan,"OnClick",ScanCurrent,"plates:track_scan")
    S.UI:SafeHandler(page.trackPrev,"OnClick",function() local n=ActiveTrackPageSize();page.trackOffset=math.max(0,page.trackOffset-n);page:Refresh() end,"plates:track_prev")
    S.UI:SafeHandler(page.trackNext,"OnClick",function() local n=ActiveTrackPageSize();page.trackOffset=page.trackOffset+n;page:Refresh() end,"plates:track_next")

    local function AddCandidateToTracking(p,id,entry)
        if not p or not p.Storage then return false,"Storage 未初始化" end
        if page.trackType~="hidden" and p.Storage.IsAuraSyncEnabled and p.Storage:IsAuraSyncEnabled() and p.Storage.AddAuraMasked then
            local mask=p.Storage:GetAuraSyncMask(page.trackScope,page.trackType);local bit=p.Storage:AuraLaneBit(page.trackScope,page.trackType)
            if bit and not p.Storage:AuraMaskHas(mask,bit) then mask=mask+bit end
            return p.Storage:AddAuraMasked(id,entry,mask)
        end
        return p.Storage:AddTracked(page.trackScope,page.trackType,id,entry)
    end

    page.trackIdEdit,page.trackIdAdd=page:AddEditAction("tracking","manual_id","输入 Buff / Debuff / Hidden ID",12,"按 ID 追加",function(text,edit)
        local p=P();local id=tostring(math.floor(tonumber(text) or -1));if not id:match("^%d+$") then S.SafeChat("请输入有效数字 ID。","warning","plates");return end
        local resolved={name="手动 ID "..id,iconPath=""}; if p and p.Api and p.Api.ResolveTrackedEntry then local e=p.Api:ResolveTrackedEntry(id,resolved.name,"");if type(e)=="table" then resolved=e end end
        local ok,err=AddCandidateToTracking(p,id,resolved);if not ok then S.SafeChat("追加失败："..tostring(err),"error","plates");return end
        if edit and edit.SetText then edit:SetText("") end;page.selectedTrackId=id;RefreshNow(p,page.trackScope)
    end)
    page.trackSearchEdit,page.trackSearch=page:AddEditAction("tracking","known_search","输入名称或 ID 搜索内置状态库",40,"搜索状态库",function(text)
        local p=P();if not p or not p.Manager or not p.Manager.SearchKnown then return end
        page.trackLive=p.Manager:SearchKnown(text,page.trackType,40) or {};page.trackView="current";page.trackSource="known";page.trackOffset=0;page.selectedTrackId=nil
    end)

    local function FormatRemaining(ms)
        ms=tonumber(ms) or 0;if ms<=0 then return "--" end;local sec=ms/1000;if sec<60 then return string.format(sec<10 and "%.1f秒" or "%.0f秒",sec) end;return string.format("%.1f分",sec/60)
    end
    local function SetRowIcon(icon,path)
        if not icon then return end
        if type(path)~="string" or path=="" then icon:SetVisible(false);return end
        pcall(function() icon:ClearAllTextures();icon:AddTexture(path);icon:SetVisible(true) end)
    end
    page.trackRows={}
    for i=1,TRACK_ROW_CAP do
        local row={}
        row.panel=S.UI:CreatePanel(page.root,"plates_track_row_panel_"..i,0,0,100,46,"card");page:RegisterWidget("tracking",row.panel)
        row.icon=row.panel.CreateIconDrawable and row.panel:CreateIconDrawable("artwork") or nil
        if row.icon then row.icon:SetExtent(34,34);row.icon:AddAnchor("TOPLEFT",row.panel,7,6);row.icon:SetVisible(false) end
        row.name=S.UI:CreateLabel(page.root,"plates_track_row_name_"..i,"",0,0,200,18,10,nil,ALIGN_LEFT);page:RegisterWidget("tracking",row.name)
        row.meta=S.UI:CreateLabel(page.root,"plates_track_row_meta_"..i,"",0,0,260,16,8,"muted",ALIGN_LEFT);page:RegisterWidget("tracking",row.meta)
        row.detail=S.UI:CreateButton(page.root,"plates_track_row_detail_"..i,"详情",0,0,48,24,8,false);page:RegisterWidget("tracking",row.detail)
        row.action=S.UI:CreateButton(page.root,"plates_track_row_action_"..i,"",0,0,58,24,8,false);page:RegisterWidget("tracking",row.action)
        page.trackRows[i]=row
        S.UI:SafeHandler(row.detail,"OnClick",function()
            if not row.item then return end
            if page.trackView=="tracked" then
                page.selectedTrackId=row.item.id;page.trackAdvanced=false;page:Refresh()
                return
            end
            local e=row.item.entry or {};local id=tostring(row.item.id or "")
            local raw=e.diagnosticOnly and " · 仅诊断候选" or ""
            S.SafeChat("状态详情："..tostring(e.name or "未命名").." · ID "..(id~="" and id or "无稳定ID").." · "..TrackTypeTitle(page.trackType).." · 层数 "..tostring(tonumber(e.stack) or 1).." · 剩余 "..FormatRemaining(e.timeLeftMs)..raw)
        end,"plates:track_detail:"..i)
        S.UI:SafeHandler(row.action,"OnClick",function()
            local p=P();local item=row.item;if not p or not item then return end
            if page.trackView=="tracked" then
                local ok,err=p.Storage:RemoveTracked(page.trackScope,page.trackType,item.id);if not ok then S.SafeChat("删除失败："..tostring(err),"error","plates") else if page.selectedTrackId==item.id then page.selectedTrackId=nil end;RefreshNow(p,page.trackScope) end
            else
                if item.entry and item.entry.trackable==false then return end
                local e=item.entry or {};local exists=p.Storage:GetTrackedEntry(page.trackScope,page.trackType,item.id)~=nil
                local ok,err
                if exists then
                    ok,err=p.Storage:RemoveTracked(page.trackScope,page.trackType,item.id)
                    if ok and page.selectedTrackId==item.id then page.selectedTrackId=nil end
                else
                    ok,err=AddCandidateToTracking(p,item.id,{name=e.name,iconPath=e.iconPath,category=e.category})
                    if ok then page.selectedTrackId=item.id end
                end
                if not ok then S.SafeChat((exists and "取消追踪失败：" or "追加失败：")..tostring(err),"error","plates") else RefreshNow(p,page.trackScope) end
            end
            page:Refresh()
        end,"plates:track_action:"..i)
    end
    page.trackSelected=S.UI:CreateLabel(page.root,"plates_track_selected","未选择追踪项",0,0,200,20,9,"muted",ALIGN_LEFT);page:RegisterWidget("tracking",page.trackSelected)
    page.trackEnable=S.UI:CreateButton(page.root,"plates_track_enable","启用/禁用",0,0,76,24,8,false);page:RegisterWidget("tracking",page.trackEnable)
    page.trackPriorityDown=S.UI:CreateButton(page.root,"plates_track_priority_down","优先级 -",0,0,70,24,8,false);page:RegisterWidget("tracking",page.trackPriorityDown)
    page.trackPriorityUp=S.UI:CreateButton(page.root,"plates_track_priority_up","优先级 +",0,0,70,24,8,false);page:RegisterWidget("tracking",page.trackPriorityUp)
    page.trackAdvancedButton=S.UI:CreateButton(page.root,"plates_track_advanced","高级选项 >",0,0,82,24,8,false);page:RegisterWidget("tracking",page.trackAdvancedButton)
    page.trackClearAll=S.UI:CreateButton(page.root,"plates_track_clear_all","清空所有已追踪",0,0,150,26,9,false);page:RegisterWidget("tracking",page.trackClearAll)
    page.trackAdvTime=S.UI:CreateButton(page.root,"plates_track_adv_time","时间：继承",0,0,74,23,8,false);page:RegisterWidget("tracking",page.trackAdvTime)
    page.trackAdvStack=S.UI:CreateButton(page.root,"plates_track_adv_stack","层数：继承",0,0,74,23,8,false);page:RegisterWidget("tracking",page.trackAdvStack)
    page.trackAdvBorder=S.UI:CreateButton(page.root,"plates_track_adv_border","边框：继承",0,0,74,23,8,false);page:RegisterWidget("tracking",page.trackAdvBorder)
    page.trackAdvTooltip=S.UI:CreateButton(page.root,"plates_track_adv_tooltip","悬浮：继承",0,0,74,23,8,false);page:RegisterWidget("tracking",page.trackAdvTooltip)
    page.trackAdvExpire=S.UI:CreateButton(page.root,"plates_track_adv_expire","到期：继承",0,0,74,23,8,false);page:RegisterWidget("tracking",page.trackAdvExpire)
    page.trackAdvIconDown=S.UI:CreateButton(page.root,"plates_track_adv_icon_down","图标 -",0,0,54,23,8,false);page:RegisterWidget("tracking",page.trackAdvIconDown)
    page.trackAdvIconUp=S.UI:CreateButton(page.root,"plates_track_adv_icon_up","图标 +",0,0,54,23,8,false);page:RegisterWidget("tracking",page.trackAdvIconUp)
    page.trackAdvIconReset=S.UI:CreateButton(page.root,"plates_track_adv_icon_reset","图标：继承",0,0,70,23,8,false);page:RegisterWidget("tracking",page.trackAdvIconReset)
    page.trackNameEdit=S.UI:CreateEditBox(page.root,"plates_track_custom_name",0,0,140,24,48);if page.trackNameEdit then page:RegisterWidget("tracking",page.trackNameEdit) end
    page.trackNameApply=S.UI:CreateButton(page.root,"plates_track_custom_name_apply","名称应用",0,0,62,23,8,false);page:RegisterWidget("tracking",page.trackNameApply)
    local function SelectedEntry()
        local p=P();if not p or not p.Storage or not page.selectedTrackId then return nil end
        return p.Storage:GetTrackedEntry(page.trackScope,page.trackType,page.selectedTrackId)
    end
    local function UpdateSelected(changes,clearFields)
        local p=P();if not p or not p.Storage or not page.selectedTrackId then return end
        local ok,err=p.Storage:UpdateTracked(page.trackScope,page.trackType,page.selectedTrackId,changes,clearFields);if not ok then S.SafeChat("规则保存失败："..tostring(err),"error","plates") else RefreshNow(p,page.trackScope) end
    end
    S.UI:SafeHandler(page.trackEnable,"OnClick",function() local e=SelectedEntry();if e then UpdateSelected({enabled=e.enabled==false}) end;page:Refresh() end,"plates:track_enable")
    S.UI:SafeHandler(page.trackPriorityDown,"OnClick",function() local e=SelectedEntry();if e then UpdateSelected({priority=math.max(-100,(tonumber(e.priority) or 0)-1)}) end;page:Refresh() end,"plates:track_priority_down")
    S.UI:SafeHandler(page.trackPriorityUp,"OnClick",function() local e=SelectedEntry();if e then UpdateSelected({priority=math.min(100,(tonumber(e.priority) or 0)+1)}) end;page:Refresh() end,"plates:track_priority_up")
    S.UI:SafeHandler(page.trackAdvancedButton,"OnClick",function() page.trackAdvanced=not page.trackAdvanced;page:Refresh();if page.lastSpec then page:ApplyLayout(page.lastSpec) end end,"plates:track_advanced")
    -- 清空所有已追踪（危险）：放在高级选项内，需二次点击确认。
    S.UI:SafeHandler(page.trackClearAll,"OnClick",function()
        local p=P();if not p or not p.Storage then return end
        local scope=page.trackScope
        local now=S.NowMs and S.NowMs() or 0
        if (tonumber(page.trackClearAllArmedAt) or 0)<=0 or now-(tonumber(page.trackClearAllArmedAt) or 0)>5000 then
            page.trackClearAllArmedAt=now
            local n=p.Storage:TrackedCount(scope,"buff")+p.Storage:TrackedCount(scope,"debuff")+p.Storage:TrackedCount(scope,"hidden")
            S.SafeChat("危险操作：再次点击“清空所有已追踪”确认；将清空【全部 HUD（自身+目标）】全部已追踪的 Buff/Debuff/Hidden 共 "..tostring(n).." 项，且不可撤销。","warning","plates")
            page:Refresh()
            return
        end
        page.trackClearAllArmedAt=0
        local count,err=p.Storage:ClearAllTracked(scope)
        if count==nil then S.SafeChat("清空失败："..tostring(err),"error","plates");page:Refresh();return end
        page.selectedTrackId=nil;page.trackOffset=0
        if p.Manager and p.Manager.Refresh then p.Manager:Refresh(false) end
        S.SafeChat("已清空【全部 HUD（自身+目标）】全部已追踪 ID 共 "..tostring(count).." 项。")
        page:Refresh()
    end,"plates:track_clear_all")
    local function NextTri(v) if v==nil then return true elseif v==true then return false else return nil end end
    for _,d in ipairs({{page.trackAdvTime,"showDuration"},{page.trackAdvStack,"showStack"},{page.trackAdvBorder,"showBorder"},{page.trackAdvTooltip,"showTooltip"},{page.trackAdvExpire,"expireEnabled"}}) do
        S.UI:SafeHandler(d[1],"OnClick",function() local e=SelectedEntry();if e then local v=NextTri(e[d[2]]);if v==nil then UpdateSelected(nil,{d[2]}) else UpdateSelected({[d[2]]=v}) end end;page:Refresh() end,"plates:track_adv_"..d[2])
    end
    S.UI:SafeHandler(page.trackAdvIconDown,"OnClick",function() local e=SelectedEntry();if e then local base=EffectLayout(page.trackScope,page.trackType);local v=e.iconSize and math.max(18,e.iconSize-1) or math.max(18,(tonumber(base and base.iconSize) or 24)-1);UpdateSelected({iconSize=v}) end;page:Refresh() end,"plates:track_icon_down")
    S.UI:SafeHandler(page.trackAdvIconUp,"OnClick",function() local e=SelectedEntry();if e then local base=EffectLayout(page.trackScope,page.trackType);local v=e.iconSize and math.min(42,e.iconSize+1) or math.min(42,(tonumber(base and base.iconSize) or 24)+1);UpdateSelected({iconSize=v}) end;page:Refresh() end,"plates:track_icon_up")
    S.UI:SafeHandler(page.trackAdvIconReset,"OnClick",function() local e=SelectedEntry();if e then UpdateSelected(nil,{"iconSize"}) end;page:Refresh() end,"plates:track_icon_reset")
    S.UI:SafeHandler(page.trackNameApply,"OnClick",function() if page.trackNameEdit and page.trackNameEdit.GetText then UpdateSelected({customName=tostring(page.trackNameEdit:GetText() or "")}) end;page:Refresh() end,"plates:track_name")

    --------------------------------------------------------------------------
    -- Layout: slider + exact edit + +/-; live/mock calibration.
    --------------------------------------------------------------------------
    page.numericRows={layout={},colors={}}
    page.numericById={}
    local function AddNumeric(section,id,label,minv,maxv,step,getter,setter,integer)
        local row={id=id,labelText=label,min=minv,max=maxv,step=step,getter=getter,setter=setter,integer=integer~=false}
        row.panel=S.UI:CreatePanel(page.root,"plates_num_panel_"..id,0,0,100,34,"card");page:RegisterWidget(section,row.panel)
        row.label=S.UI:CreateLabel(page.root,"plates_num_label_"..id,label,0,0,115,18,9,nil,ALIGN_LEFT);page:RegisterWidget(section,row.label)
        row.minus=S.UI:CreateButton(page.root,"plates_num_minus_"..id,"-",0,0,28,22,10,false);page:RegisterWidget(section,row.minus)
        row.slider=S.UI.CreateSlider and S.UI:CreateSlider(page.root,"plates_num_slider_"..id,0,0,120,20,minv,maxv,step,getter()) or nil;if row.slider then page:RegisterWidget(section,row.slider) end
        row.edit=S.UI:CreateEditBox(page.root,"plates_num_edit_"..id,0,0,58,22,12);if row.edit then page:RegisterWidget(section,row.edit) end
        row.apply=S.UI:CreateButton(page.root,"plates_num_apply_"..id,"应用",0,0,42,22,8,false);page:RegisterWidget(section,row.apply)
        row.plus=S.UI:CreateButton(page.root,"plates_num_plus_"..id,"+",0,0,24,22,9,false);page:RegisterWidget(section,row.plus)
        local function normalize(v) v=Clamp(v,minv,maxv);if row.integer then v=math.floor(v+0.5) end;return v end
        S.UI:SafeHandler(row.minus,"OnClick",function() setter(normalize((tonumber(getter()) or minv)-step),false);page:Refresh() end,"plates:num_minus:"..id)
        S.UI:SafeHandler(row.plus,"OnClick",function() setter(normalize((tonumber(getter()) or minv)+step),false);page:Refresh() end,"plates:num_plus:"..id)
        S.UI:SafeHandler(row.apply,"OnClick",function() if row.edit and row.edit.GetText then local v=tonumber(row.edit:GetText());if v then setter(normalize(v),false) else S.SafeChat(label.."：请输入数字。","warning","plates") end end;page:Refresh() end,"plates:num_apply:"..id)
        if row.slider then
            if type(row.slider.SetValueChangedHandler)=="function" then
                -- 1.0.22 custom horizontal slider: live changes are staged for
                -- immediate HUD preview; drag-stop commits once. Avoid a full
                -- page Refresh on every drag sample because that would rebuild
                -- layout while the transparent drag transaction is active.
                row.slider:SetValueChangedHandler(function(rawValue,final)
                    local v=normalize(rawValue)
                    setter(v,final~=true)
                    row.label:SetText(row.labelText.."："..tostring(row.integer and math.floor(v+0.5) or v))
                    if row.edit and row.edit.SetText then row.edit:SetText(tostring(row.integer and math.floor(v+0.5) or v)) end
                    if final==true then page:Refresh() end
                end)
                row.sliderEventAttached=true
            else
                local handler=function() local v=row.slider.GetValue and row.slider:GetValue() or nil;if v~=nil then v=normalize(v);setter(v,true);if S.UI.UpdateSliderVisual then S.UI:UpdateSliderVisual(row.slider,v) end;page:Refresh() end end
                local attached=false
                for _,eventName in ipairs({"OnValueChanged","OnSliderChanged"}) do
                    if S.UI:SafeHandler(row.slider,eventName,handler,"plates:num_slider:"..id..":"..eventName) == true then
                        attached=true
                        break
                    end
                end
                row.sliderEventAttached=attached
            end
        end
        page.numericRows[section][#page.numericRows[section]+1]=row
        page.numericById[id]=row
        return row
    end
    local function SetLayoutValue(key,v,staged)
        local scope,effect=page.layoutScope,page.layoutType
        local f=function(c) local l=c.effects and c.effects[effect];if l then l[key]=v end end
        if staged then Stage(scope,f) else Mutate(scope,f) end
    end
    local function SetBaseLayoutValue(key,v,staged)
        local scope=page.layoutScope
        local f=function(c) c[key]=v end
        if staged then Stage(scope,f) else Mutate(scope,f) end
    end
    page.layoutBaseRows=page.layoutBaseRows or {}
    page.layoutBaseRows[#page.layoutBaseRows+1]=AddNumeric("layout","hud_width","整体宽度",230,460,1,function() local c=Cfg(page.layoutScope);return c and c.width or 286 end,function(v,s) SetBaseLayoutValue("width",v,s) end)
    page.layoutBaseRows[#page.layoutBaseRows+1]=AddNumeric("layout","hud_gap","区域间距",0,20,1,function() local c=Cfg(page.layoutScope);return c and c.sectionGap or 4 end,function(v,s) SetBaseLayoutValue("sectionGap",v,s) end)
    page.layoutBaseRows[#page.layoutBaseRows+1]=AddNumeric("layout","hud_x","整体 X",-1200,1200,1,function() local c=Cfg(page.layoutScope);return c and c.offsetX or 0 end,function(v,s) SetBaseLayoutValue("offsetX",v,s) end)
    page.layoutBaseRows[#page.layoutBaseRows+1]=AddNumeric("layout","hud_y","整体 Y",-1200,1200,1,function() local c=Cfg(page.layoutScope);return c and c.offsetY or 0 end,function(v,s) SetBaseLayoutValue("offsetY",v,s) end)
    page.layoutEffectRows=page.layoutEffectRows or {}
    page.layoutEffectRows[#page.layoutEffectRows+1]=AddNumeric("layout","icon","图标大小",18,42,1,function() local l=EffectLayout(page.layoutScope,page.layoutType);return l and l.iconSize or 24 end,function(v,s) SetLayoutValue("iconSize",v,s) end)
    page.layoutEffectRows[#page.layoutEffectRows+1]=AddNumeric("layout","font","字体大小",8,18,1,function() local l=EffectLayout(page.layoutScope,page.layoutType);return l and l.fontSize or 10 end,function(v,s) SetLayoutValue("fontSize",v,s) end)
    page.layoutEffectRows[#page.layoutEffectRows+1]=AddNumeric("layout","max","最大数量",1,12,1,function() local l=EffectLayout(page.layoutScope,page.layoutType);return l and l.maxCount or 8 end,function(v,s) SetLayoutValue("maxCount",v,s) end)
    page.layoutEffectRows[#page.layoutEffectRows+1]=AddNumeric("layout","cols","每行数量",1,12,1,function() local l=EffectLayout(page.layoutScope,page.layoutType);return l and l.columns or 6 end,function(v,s) SetLayoutValue("columns",v,s) end)
    page.layoutEffectRows[#page.layoutEffectRows+1]=AddNumeric("layout","gap","横向间距",0,12,1,function() local l=EffectLayout(page.layoutScope,page.layoutType);return l and l.gap or 2 end,function(v,s) SetLayoutValue("gap",v,s) end)
    page.layoutEffectRows[#page.layoutEffectRows+1]=AddNumeric("layout","rowgap","纵向间距",0,12,1,function() local l=EffectLayout(page.layoutScope,page.layoutType);return l and l.rowGap or 2 end,function(v,s) SetLayoutValue("rowGap",v,s) end)
    page.layoutEffectRows[#page.layoutEffectRows+1]=AddNumeric("layout","x","区域 X",-300,300,1,function() local l=EffectLayout(page.layoutScope,page.layoutType);return l and l.offsetX or 0 end,function(v,s) SetLayoutValue("offsetX",v,s) end)
    page.layoutEffectRows[#page.layoutEffectRows+1]=AddNumeric("layout","y","区域 Y",-300,300,1,function() local l=EffectLayout(page.layoutScope,page.layoutType);return l and l.offsetY or 0 end,function(v,s) SetLayoutValue("offsetY",v,s) end)

    -- 玩家信息与距离现在是“外观布局”的同级子组。它们仍然只写入
    -- Plates Storage 的目标 HUD 配置，UI 这里只负责展示/编辑，不复制 Authority。
    page.layoutMetadataRows={}
    page.layoutMetadataRows[#page.layoutMetadataRows+1]=AddNumeric("layout","meta_class_icon_size","职业图标大小",18,36,1,function() local c=TargetGroup("class");return c and c.iconSize or 26 end,function(v,s) return SetTargetGroup("class","iconSize",v,s) end)
    page.layoutMetadataRows[#page.layoutMetadataRows+1]=AddNumeric("layout","meta_class_font","职业字号",9,20,1,function() local c=TargetGroup("class");return c and c.fontSize or 12 end,function(v,s) return SetTargetGroup("class","fontSize",v,s) end)
    page.layoutMetadataRows[#page.layoutMetadataRows+1]=AddNumeric("layout","meta_class_x","职业 X",-300,300,1,function() local c=TargetGroup("class");return c and c.offsetX or 0 end,function(v,s) return SetTargetGroup("class","offsetX",v,s) end)
    page.layoutMetadataRows[#page.layoutMetadataRows+1]=AddNumeric("layout","meta_class_y","职业 Y",-300,300,1,function() local c=TargetGroup("class");return c and c.offsetY or 0 end,function(v,s) return SetTargetGroup("class","offsetY",v,s) end)
    page.layoutMetadataRows[#page.layoutMetadataRows+1]=AddNumeric("layout","meta_gear_font","装等字号",9,20,1,function() local c=TargetGroup("gear");return c and c.fontSize or 12 end,function(v,s) return SetTargetGroup("gear","fontSize",v,s) end)
    page.layoutMetadataRows[#page.layoutMetadataRows+1]=AddNumeric("layout","meta_gear_x","装等 X",-300,300,1,function() local c=TargetGroup("gear");return c and c.offsetX or 0 end,function(v,s) return SetTargetGroup("gear","offsetX",v,s) end)
    page.layoutMetadataRows[#page.layoutMetadataRows+1]=AddNumeric("layout","meta_gear_y","装等 Y",-300,300,1,function() local c=TargetGroup("gear");return c and c.offsetY or 0 end,function(v,s) return SetTargetGroup("gear","offsetY",v,s) end)
    page.layoutMetadataRows[#page.layoutMetadataRows+1]=AddNumeric("layout","meta_loadout_font","武器状态字号",9,20,1,function() local c=TargetGroup("loadout");return c and c.fontSize or 11 end,function(v,s) return SetTargetGroup("loadout","fontSize",v,s) end)
    page.layoutMetadataRows[#page.layoutMetadataRows+1]=AddNumeric("layout","meta_loadout_x","武器状态 X",-300,300,1,function() local c=TargetGroup("loadout");return c and c.offsetX or 0 end,function(v,s) return SetTargetGroup("loadout","offsetX",v,s) end)
    page.layoutMetadataRows[#page.layoutMetadataRows+1]=AddNumeric("layout","meta_loadout_y","武器状态 Y",-300,300,1,function() local c=TargetGroup("loadout");return c and c.offsetY or 0 end,function(v,s) return SetTargetGroup("loadout","offsetY",v,s) end)

    local function SetDistanceThreshold(key,value,staged)
        local f=function(c)
            c.distance=type(c.distance)=="table" and c.distance or {}
            if key=="warningAt" then
                c.distance.warningAt=value
                if (tonumber(c.distance.dangerAt) or value)<value then c.distance.dangerAt=value end
            else
                c.distance.dangerAt=math.max(value,tonumber(c.distance.warningAt) or 0)
            end
        end
        if staged then return Stage("target",f) end
        return Mutate("target",f)
    end
    page.layoutDistanceRows={}
    page.layoutDistanceRows[#page.layoutDistanceRows+1]=AddNumeric("layout","distance_font","距离字号",8,24,1,function() local c=TargetGroup("distance");return c and c.fontSize or 12 end,function(v,s) return SetTargetGroup("distance","fontSize",v,s) end)
    page.layoutDistanceRows[#page.layoutDistanceRows+1]=AddNumeric("layout","distance_x","距离 X",-300,300,1,function() local c=TargetGroup("distance");return c and c.offsetX or 0 end,function(v,s) return SetTargetGroup("distance","offsetX",v,s) end)
    page.layoutDistanceRows[#page.layoutDistanceRows+1]=AddNumeric("layout","distance_y","距离 Y",-300,300,1,function() local c=TargetGroup("distance");return c and c.offsetY or 0 end,function(v,s) return SetTargetGroup("distance","offsetY",v,s) end)
    page.layoutDistanceRows[#page.layoutDistanceRows+1]=AddNumeric("layout","distance_warn","提醒距离 (m)",0,200,1,function() local c=TargetGroup("distance");return c and c.warningAt or 25 end,function(v,s) return SetDistanceThreshold("warningAt",v,s) end)
    page.layoutDistanceRows[#page.layoutDistanceRows+1]=AddNumeric("layout","distance_danger","危险距离 (m)",0,300,1,function() local c=TargetGroup("distance");return c and c.dangerAt or 30 end,function(v,s) return SetDistanceThreshold("dangerAt",v,s) end)

    -- Casting bar geometry/text belong to the target HUD layout Authority.  The
    -- bar can be wider than the outer plate; offsets never participate in parent
    -- sizing, matching the fixed-canvas rule used by Buff/Debuff/metadata.
    local function SetCastValue(key,v,staged)
        return SetTargetGroup("cast",key,v,staged)
    end
    page.layoutCastRows={}
    page.layoutCastRows[#page.layoutCastRows+1]=AddNumeric("layout","cast_width","施法条宽度",90,450,1,function()
        local c=TargetCast();local w=tonumber(c and c.width) or 0
        if w<=0 then local base=Cfg("target");w=math.max(90,math.min(450,(tonumber(base and base.width) or 286)-14)) end
        return w
    end,function(v,s) return SetCastValue("width",v,s) end)
    page.layoutCastRows[#page.layoutCastRows+1]=AddNumeric("layout","cast_height","施法条高度",10,40,1,function() local c=TargetCast();return c and c.height or 16 end,function(v,s) return SetCastValue("height",v,s) end)
    page.layoutCastRows[#page.layoutCastRows+1]=AddNumeric("layout","cast_icon","施法图标大小",16,42,1,function() local c=TargetCast();return c and c.iconSize or 20 end,function(v,s) return SetCastValue("iconSize",v,s) end)
    page.layoutCastRows[#page.layoutCastRows+1]=AddNumeric("layout","cast_x","施法条 X",-300,300,1,function() local c=TargetCast();return c and c.offsetX or 0 end,function(v,s) return SetCastValue("offsetX",v,s) end)
    page.layoutCastRows[#page.layoutCastRows+1]=AddNumeric("layout","cast_y","施法条 Y",-300,300,1,function() local c=TargetCast();return c and c.offsetY or 0 end,function(v,s) return SetCastValue("offsetY",v,s) end)
    page.layoutCastRows[#page.layoutCastRows+1]=AddNumeric("layout","cast_name_font","技能名称字号",8,24,1,function() local c=TargetCast();return c and c.nameFontSize or 9 end,function(v,s) return SetCastValue("nameFontSize",v,s) end)
    page.layoutCastRows[#page.layoutCastRows+1]=AddNumeric("layout","cast_name_x","技能名称 X",-300,300,1,function() local c=TargetCast();return c and c.nameOffsetX or 0 end,function(v,s) return SetCastValue("nameOffsetX",v,s) end)
    page.layoutCastRows[#page.layoutCastRows+1]=AddNumeric("layout","cast_name_y","技能名称 Y",-300,300,1,function() local c=TargetCast();local v=c and c.nameOffsetY;return v~=nil and v or -2 end,function(v,s) return SetCastValue("nameOffsetY",v,s) end)
    page.layoutCastRows[#page.layoutCastRows+1]=AddNumeric("layout","cast_time_font","时间文字字号",8,24,1,function() local c=TargetCast();return c and c.timeFontSize or 9 end,function(v,s) return SetCastValue("timeFontSize",v,s) end)
    page.layoutCastRows[#page.layoutCastRows+1]=AddNumeric("layout","cast_time_x","时间文字 X",-300,300,1,function() local c=TargetCast();return c and c.timeOffsetX or 0 end,function(v,s) return SetCastValue("timeOffsetX",v,s) end)
    page.layoutCastRows[#page.layoutCastRows+1]=AddNumeric("layout","cast_time_y","时间文字 Y",-300,300,1,function() local c=TargetCast();local v=c and c.timeOffsetY;return v~=nil and v or -2 end,function(v,s) return SetCastValue("timeOffsetY",v,s) end)

    -- Player equipment icon appearance belongs to the same HUD layout Authority
    -- as the other visual components.  These controls edit the existing Plates
    -- equipment table; they do not create a second settings/runtime path.
    local function SetPlayerEquipmentValue(key,v,staged)
        local f=function(c)
            c.equipment=type(c.equipment)=="table" and c.equipment or {}
            c.equipment[key]=v
        end
        if staged then return Stage("player",f) end
        return Mutate("player",f)
    end
    page.layoutEquipmentRows={}
    page.layoutEquipmentRows[#page.layoutEquipmentRows+1]=AddNumeric("layout","equipment_icon","装备图标大小",18,42,1,function() local c=PlayerEquipment();return c and c.iconSize or 26 end,function(v,s) return SetPlayerEquipmentValue("iconSize",v,s) end)
    page.layoutEquipmentRows[#page.layoutEquipmentRows+1]=AddNumeric("layout","equipment_x","装备区域 X",-300,300,1,function() local c=PlayerEquipment();return c and c.offsetX or 0 end,function(v,s) return SetPlayerEquipmentValue("offsetX",v,s) end)
    page.layoutEquipmentRows[#page.layoutEquipmentRows+1]=AddNumeric("layout","equipment_y","装备区域 Y",-300,300,1,function() local c=PlayerEquipment();return c and c.offsetY or 0 end,function(v,s) return SetPlayerEquipmentValue("offsetY",v,s) end)
    page.layoutEquipmentDirection=S.UI:CreateButton(page.root,"plates_layout_equipment_direction","装备方向：RIGHT",0,0,110,25,8,false);page:RegisterWidget("layout",page.layoutEquipmentDirection)
    S.UI:SafeHandler(page.layoutEquipmentDirection,"OnClick",function()
        local c=PlayerEquipment();local nextv=Cycle({"RIGHT","LEFT","DOWN","UP"},c and c.direction or "RIGHT")
        SetPlayerEquipmentValue("direction",nextv,false);page:Refresh()
    end,"plates:layout_equipment_direction")

    page.layoutDirection=S.UI:CreateButton(page.root,"plates_layout_direction","区域方向：RIGHT",0,0,100,25,8,false);page:RegisterWidget("layout",page.layoutDirection)
    page.layoutAnchor=S.UI:CreateButton(page.root,"plates_layout_anchor","整体锚点：TOP",0,0,100,25,8,false);page:RegisterWidget("layout",page.layoutAnchor)
    page.layoutPreview=S.UI:CreateButton(page.root,"plates_layout_preview","预览：真实",0,0,92,25,8,false);page:RegisterWidget("layout",page.layoutPreview)
    page.layoutDragAll=S.UI:CreateButton(page.root,"plates_layout_drag_all","拖动整体 HUD",0,0,94,25,8,false);page:RegisterWidget("layout",page.layoutDragAll)
    page.layoutDragPart=S.UI:CreateButton(page.root,"plates_layout_drag_part","拖动当前区域",0,0,94,25,8,false);page:RegisterWidget("layout",page.layoutDragPart)
    page.layoutStop=S.UI:CreateButton(page.root,"plates_layout_stop","结束校准",0,0,78,25,8,false);page:RegisterWidget("layout",page.layoutStop)
    page.layoutReset=S.UI:CreateButton(page.root,"plates_layout_reset","恢复区域默认",0,0,88,25,8,false);page:RegisterWidget("layout",page.layoutReset)
    page.layoutCopy=S.UI:CreateButton(page.root,"plates_layout_copy","复制到另一 HUD",0,0,100,25,8,false);page:RegisterWidget("layout",page.layoutCopy)
    page.layoutHint=S.UI:CreateLabel(page.root,"plates_layout_hint","",0,0,100,34,9,"muted",ALIGN_LEFT);page:RegisterWidget("layout",page.layoutHint)
    S.UI:SafeHandler(page.layoutDirection,"OnClick",function() local l=EffectLayout(page.layoutScope,page.layoutType);local nextv=Cycle({"RIGHT","LEFT","DOWN","UP"},l and l.direction or "RIGHT");SetLayoutValue("direction",nextv,false);page:Refresh() end,"plates:layout_dir")
    S.UI:SafeHandler(page.layoutAnchor,"OnClick",function() local c=Cfg(page.layoutScope);local nextv=(c and c.anchorMode)=="BOTTOM" and "TOP" or "BOTTOM";SetBaseLayoutValue("anchorMode",nextv,false);page:Refresh() end,"plates:layout_anchor")
    S.UI:SafeHandler(page.layoutPreview,"OnClick",function() local p=P();if p and p.UI and p.UI.SetPreviewMode then local mode=p.UI:GetPreviewMode(page.layoutScope)=="mock" and "real" or "mock";p.UI:SetPreviewMode(page.layoutScope,mode) end;page:Refresh() end,"plates:layout_preview")
    S.UI:SafeHandler(page.layoutDragAll,"OnClick",function() local p=P();if p and p.UI and p.UI.SetCalibration then p.UI:SetCalibration(page.layoutScope) end end,"plates:layout_drag_all")
    S.UI:SafeHandler(page.layoutDragPart,"OnClick",function()
        local p=P();if not p or not p.UI or not p.UI.SetLayoutEdit then return end
        local key=page.layoutGroup=="cast" and "cast" or page.layoutType
        p.UI:SetLayoutEdit(page.layoutScope,key)
    end,"plates:layout_drag_part")
    S.UI:SafeHandler(page.layoutStop,"OnClick",function() local p=P();if p and p.UI then if p.UI.SetCalibration then p.UI:SetCalibration(nil) end;if p.UI.SetLayoutEdit then p.UI:SetLayoutEdit(nil,nil) end;if p.UI.SetPreviewMode then p.UI:SetPreviewMode(page.layoutScope,"real") end end;page:Refresh() end,"plates:layout_stop")
    S.UI:SafeHandler(page.layoutReset,"OnClick",function() local p=P();if p and p.Storage then local ok,err=p.Storage:ResetEffectLayout(page.layoutScope,page.layoutType);if not ok then S.SafeChat("恢复失败："..tostring(err),"error","plates") else RefreshNow(p,page.layoutScope) end end;page:Refresh() end,"plates:layout_reset")
    S.UI:SafeHandler(page.layoutCopy,"OnClick",function()
        local from,to=page.layoutScope,page.layoutScope=="target" and "player" or "target";local src=Cfg(from)
        if src then
            Mutate(to,function(c)
                c.width=src.width;c.sectionGap=src.sectionGap;c.showBuffs=src.showBuffs;c.showDebuffs=src.showDebuffs;c.showHidden=src.showHidden;c.trackedOnly=src.trackedOnly
                if type(src.effects)=="table" and type(c.effects)=="table" then for _,effect in ipairs({"buff","debuff","hidden"}) do if src.effects[effect] and c.effects[effect] then RestoreTable(c.effects[effect],src.effects[effect]) end end end
            end)
            S.SafeChat("已把 "..ScopeTitle(from).." 的 HUD 外观复制到 "..ScopeTitle(to).."；位置与追踪名单保持独立。")
        end
    end,"plates:layout_copy")

    --------------------------------------------------------------------------
    -- Color + style: precise RGBA/HEX, 16 presets, user presets.
    --------------------------------------------------------------------------
    page.colorPreview=S.UI:CreatePanel(page.root,"plates_color_preview",0,0,80,32,"card");page:RegisterWidget("colors",page.colorPreview)
    page.colorValue=S.UI:CreateLabel(page.root,"plates_color_value","",0,0,200,20,9,nil,ALIGN_LEFT);page:RegisterWidget("colors",page.colorValue)
    page.colorBorder=S.UI:CreateButton(page.root,"plates_color_border","编辑：边框",0,0,84,25,8,false,true);page:RegisterWidget("colors",page.colorBorder)
    page.colorExpire=S.UI:CreateButton(page.root,"plates_color_expire","编辑：到期",0,0,84,25,8,false,true);page:RegisterWidget("colors",page.colorExpire)
    page.colorRuleTarget=S.UI:CreateButton(page.root,"plates_color_rule_target","编辑对象：区域",0,0,94,23,8,false);page:RegisterWidget("colors",page.colorRuleTarget)
    page.colorRuleClear=S.UI:CreateButton(page.root,"plates_color_rule_clear","规则颜色：恢复继承",0,0,110,23,8,false);page:RegisterWidget("colors",page.colorRuleClear)
    page.colorHint=S.UI:CreateLabel(page.root,"plates_color_hint","",0,0,100,34,9,"muted",ALIGN_LEFT);page:RegisterWidget("colors",page.colorHint)
    local function SetRuleValue(key,value,staged)
        local p=P();local e=SelectedEntry();if not p or not p.Storage or not e or page.selectedTrackId==nil then return false end
        if staged then
            e[key]=value;p.Storage:MarkTrackingDirty();RefreshNow(p,page.trackScope)
            if S.Scheduler then
                S.Scheduler:RemoveTask("plates_ui2_delayed_save")
                S.Scheduler:AddTask("plates_ui2_delayed_save",350,function()
                    S.Scheduler:RemoveTask("plates_ui2_delayed_save");local pp=P();if pp and pp.Storage then pp.Storage:Save(true) end
                end,false,page,"P2")
            else p.Storage:Save(true) end
        else
            UpdateSelected({[key]=value})
        end
        return true
    end
    local function CurrentColor()
        local l=EffectLayout(page.colorScope,page.colorType) or {};local key=page.colorTarget=="expire" and "expireColor" or "borderColor"
        if page.colorRuleMode and page.selectedTrackId and page.trackScope==page.colorScope and page.trackType==page.colorType then
            local e=SelectedEntry();if e and type(e[key])=="table" then return NormalizeColor(e[key]) end
        end
        return NormalizeColor(l[key])
    end
    local function SetCurrentColor(color,staged)
        color=NormalizeColor(color);local key=page.colorTarget=="expire" and "expireColor" or "borderColor";local scope,effect=page.colorScope,page.colorType
        if page.colorRuleMode and page.selectedTrackId and page.trackScope==scope and page.trackType==effect then
            SetRuleValue(key,S.Utils.DeepCopy(color),staged);return
        end
        local f=function(c) if c.effects and c.effects[effect] then c.effects[effect][key]=color end end
        if staged then Stage(scope,f) else Mutate(scope,f) end
    end
    S.UI:SafeHandler(page.colorBorder,"OnClick",function() page.colorTarget="border";page:Refresh() end,"plates:color_border")
    S.UI:SafeHandler(page.colorExpire,"OnClick",function() page.colorTarget="expire";page:Refresh() end,"plates:color_expire")
    S.UI:SafeHandler(page.colorRuleTarget,"OnClick",function()
        if page.selectedTrackId==nil then S.SafeChat("请先在“状态追踪”中选择一个已追踪状态。","warning","plates");return end
        page.colorRuleMode=not page.colorRuleMode
        if page.colorRuleMode then page.colorScope=page.trackScope;page.colorType=page.trackType end
        page:Refresh();if page.lastSpec then page:ApplyLayout(page.lastSpec) end
    end,"plates:color_rule_target")
    S.UI:SafeHandler(page.colorRuleClear,"OnClick",function()
        if not page.colorRuleMode or page.selectedTrackId==nil then return end
        UpdateSelected(nil,{"borderColor","expireColor"})
        page:Refresh()
    end,"plates:color_rule_clear")
    for _,ch in ipairs({{"r","R"},{"g","G"},{"b","B"},{"a","A"}}) do
        AddNumeric("colors","color_"..ch[1],ch[2],0,255,1,function() local c=CurrentColor();return math.floor((c[ch[1]] or 0)*255+0.5) end,function(v,staged) local c=CurrentColor();c[ch[1]]=v/255;SetCurrentColor(c,staged) end)
    end
    page.colorHexEdit=S.UI:CreateEditBox(page.root,"plates_color_hex",0,0,120,25,12);if page.colorHexEdit then page:RegisterWidget("colors",page.colorHexEdit) end
    page.colorHexApply=S.UI:CreateButton(page.root,"plates_color_hex_apply","应用 HEX",0,0,72,25,8,false);page:RegisterWidget("colors",page.colorHexApply)
    S.UI:SafeHandler(page.colorHexApply,"OnClick",function() if page.colorHexEdit and page.colorHexEdit.GetText then local c,e=ParseColorText(page.colorHexEdit:GetText());if c then SetCurrentColor(c,false) else S.SafeChat(tostring(e),"warning","plates") end end;page:Refresh() end,"plates:color_hex")
    page.colorToggleTime=S.UI:CreateButton(page.root,"plates_color_time","显示时间",0,0,70,23,8,false);page:RegisterWidget("colors",page.colorToggleTime)
    page.colorToggleStack=S.UI:CreateButton(page.root,"plates_color_stack","显示层数",0,0,70,23,8,false);page:RegisterWidget("colors",page.colorToggleStack)
    page.colorToggleBorder=S.UI:CreateButton(page.root,"plates_color_showborder","显示边框",0,0,70,23,8,false);page:RegisterWidget("colors",page.colorToggleBorder)
    page.colorToggleTooltip=S.UI:CreateButton(page.root,"plates_color_tooltip_on","悬浮提示",0,0,70,23,8,false);page:RegisterWidget("colors",page.colorToggleTooltip)
    page.colorToggleExpire=S.UI:CreateButton(page.root,"plates_color_expire_on","到期提醒",0,0,70,23,8,false);page:RegisterWidget("colors",page.colorToggleExpire)
    local function ToggleLayoutFlag(key)
        if page.colorRuleMode and page.selectedTrackId and page.trackScope==page.colorScope and page.trackType==page.colorType then
            local e=SelectedEntry();if e then local v=NextTri(e[key]);if v==nil then UpdateSelected(nil,{key}) else UpdateSelected({[key]=v}) end end
        else
            local l=EffectLayout(page.colorScope,page.colorType);local v=not(l and l[key]==true);Mutate(page.colorScope,function(c) c.effects[page.colorType][key]=v end)
        end
        page:Refresh()
    end
    S.UI:SafeHandler(page.colorToggleTime,"OnClick",function() ToggleLayoutFlag("showDuration") end,"plates:color_time")
    S.UI:SafeHandler(page.colorToggleStack,"OnClick",function() ToggleLayoutFlag("showStack") end,"plates:color_stack")
    S.UI:SafeHandler(page.colorToggleBorder,"OnClick",function() ToggleLayoutFlag("showBorder") end,"plates:color_showborder")
    S.UI:SafeHandler(page.colorToggleTooltip,"OnClick",function() ToggleLayoutFlag("showTooltip") end,"plates:color_tooltip_on")
    S.UI:SafeHandler(page.colorToggleExpire,"OnClick",function() ToggleLayoutFlag("expireEnabled") end,"plates:color_expire_on")
    AddNumeric("colors","expire_threshold","提醒秒数",1,30,1,function()
        local l=EffectLayout(page.colorScope,page.colorType);local base=l and l.expireThreshold or 5
        if page.colorRuleMode and page.selectedTrackId and page.trackScope==page.colorScope and page.trackType==page.colorType then local e=SelectedEntry();if e and e.expireThreshold~=nil then return e.expireThreshold end end
        return base
    end,function(v,s)
        if page.colorRuleMode and page.selectedTrackId and page.trackScope==page.colorScope and page.trackType==page.colorType then SetRuleValue("expireThreshold",v,s);return end
        local scope,effect=page.colorScope,page.colorType;local f=function(c)c.effects[effect].expireThreshold=v end;if s then Stage(scope,f) else Mutate(scope,f) end
    end)
    local presetColors={
        {"红","FF4B4BFF"},{"橙","FF9838FF"},{"黄","FFD84AFF"},{"绿","48D66BFF"},{"青","40D8D8FF"},{"蓝","4A90FFFF"},{"深蓝","3657D9FF"},{"紫","A764FFFF"},
        {"粉","FF6EC7FF"},{"白","FFFFFFFF"},{"灰","A8B0BAFF"},{"黑","30343AFF"},{"金","E7B64AFF"},{"浅绿","8BE28BFF"},{"浅蓝","8CCBFFFF"},{"亮紫","D18AFFFF"},
    }
    page.colorPresetButtons={}
    for i,preset in ipairs(presetColors) do
        local b=S.UI:CreateButton(page.root,"plates_color_preset_"..i,preset[1],0,0,44,22,8,false);page:RegisterWidget("colors",b);page.colorPresetButtons[#page.colorPresetButtons+1]=b
        S.UI:SafeHandler(b,"OnClick",function() local c=ParseColorText("#"..preset[2]);SetCurrentColor(c,false);page:Refresh() end,"plates:color_preset:"..i)
    end
    page.colorPresetName=S.UI:CreateEditBox(page.root,"plates_color_preset_name",0,0,130,24,24);if page.colorPresetName then page:RegisterWidget("colors",page.colorPresetName) end
    page.colorPresetSave=S.UI:CreateButton(page.root,"plates_color_preset_save","保存当前颜色",0,0,92,24,8,false);page:RegisterWidget("colors",page.colorPresetSave)
    page.customColorButtons={}
    for i=1,6 do local b=S.UI:CreateButton(page.root,"plates_color_custom_"..i,"",0,0,76,22,8,false);page:RegisterWidget("colors",b);page.customColorButtons[i]=b;S.UI:SafeHandler(b,"OnClick",function() local p=P();local preset=p and p.Storage and p.Storage:GetColorPresets()[page.customColorOffset+i] or nil;if preset then page.selectedCustomPreset=tostring(preset.name or "");SetCurrentColor(preset.color,false);page:Refresh() end end,"plates:color_custom:"..i) end
    page.customPrev=S.UI:CreateButton(page.root,"plates_color_custom_prev","<",0,0,24,22,8,false);page:RegisterWidget("colors",page.customPrev)
    page.customNext=S.UI:CreateButton(page.root,"plates_color_custom_next",">",0,0,24,22,8,false);page:RegisterWidget("colors",page.customNext)
    page.customDelete=S.UI:CreateButton(page.root,"plates_color_custom_delete","删除所选预设",0,0,88,22,8,false);page:RegisterWidget("colors",page.customDelete);page.selectedCustomPreset=nil
    S.UI:SafeHandler(page.colorPresetSave,"OnClick",function() local p=P();if p and p.Storage and page.colorPresetName and page.colorPresetName.GetText then local ok,err=p.Storage:AddColorPreset(page.colorPresetName:GetText(),CurrentColor());if not ok then S.SafeChat("保存颜色预设失败："..tostring(err),"warning","plates") end end;page:Refresh() end,"plates:color_preset_save")
    S.UI:SafeHandler(page.customPrev,"OnClick",function() page.customColorOffset=math.max(0,page.customColorOffset-6);page:Refresh() end,"plates:custom_prev")
    S.UI:SafeHandler(page.customNext,"OnClick",function() local p=P();local n=p and p.Storage and #p.Storage:GetColorPresets() or 0;if page.customColorOffset+6<n then page.customColorOffset=page.customColorOffset+6 end;page:Refresh() end,"plates:custom_next")
    S.UI:SafeHandler(page.customDelete,"OnClick",function()
        local p=P();if not p or not p.Storage or not page.selectedCustomPreset then return end
        local now=S.NowMs and S.NowMs() or 0
        if tostring(page.customDeleteArmedName or "")~=tostring(page.selectedCustomPreset) or now-(tonumber(page.customDeleteArmedAt) or 0)>5000 then
            page.customDeleteArmedName=page.selectedCustomPreset;page.customDeleteArmedAt=now
            S.SafeChat("5秒内再次点击删除当前颜色预设："..tostring(page.selectedCustomPreset))
            page:Refresh();return
        end
        p.Storage:RemoveColorPreset(page.selectedCustomPreset);page.selectedCustomPreset=nil;page.customDeleteArmedName=nil;page.customDeleteArmedAt=0;page:Refresh()
    end,"plates:custom_delete")

    --------------------------------------------------------------------------
    -- Transfer: all / tracking / layout / single rule, preview before import.
    --------------------------------------------------------------------------
    page.transferModeTabs=MakeTabs("transfer","transfer_mode",{{"library","状态库"},{"all","全部配置"},{"tracking","只追踪"},{"layout","只布局"},{"rule","单个规则"}},function() return page.transferMode end,function(v)
        page.transferMode=v;page.pendingImportText=nil;page.pendingImportSummary=nil;page.transferChunks={};page.transferChunkIndex=1;page.transferExportInfo=nil
    end)
    page.transferSummary=S.UI:CreateLabel(page.root,"plates_transfer_summary","",0,0,100,44,9,"muted",ALIGN_LEFT);page:RegisterWidget("transfer",page.transferSummary)
    page.transferEdit=S.UI.CreateMultiEditBox and S.UI:CreateMultiEditBox(page.root,"plates_transfer_text",0,0,420,170,65535) or nil;if page.transferEdit then page:RegisterWidget("transfer",page.transferEdit) end
    page.transferExport=S.UI:CreateButton(page.root,"plates_transfer_export","一键导出",0,0,88,27,9,false);page:RegisterWidget("transfer",page.transferExport)
    page.transferCopyAll=S.UI:CreateButton(page.root,"plates_transfer_copy_all","再次复制全部",0,0,88,27,9,false);page:RegisterWidget("transfer",page.transferCopyAll)
    page.transferCopyCurrent=S.UI:CreateButton(page.root,"plates_transfer_copy_current","复制当前片",0,0,88,27,9,false);page:RegisterWidget("transfer",page.transferCopyCurrent)
    page.transferChunkPrev=S.UI:CreateButton(page.root,"plates_transfer_chunk_prev","上一片",0,0,72,27,9,false);page:RegisterWidget("transfer",page.transferChunkPrev)
    page.transferChunkNext=S.UI:CreateButton(page.root,"plates_transfer_chunk_next","下一片",0,0,72,27,9,false);page:RegisterWidget("transfer",page.transferChunkNext)
    page.transferPolicy=S.UI:CreateButton(page.root,"plates_transfer_policy","状态库：合并",0,0,92,27,9,false,true);page:RegisterWidget("transfer",page.transferPolicy)
    page.transferParse=S.UI:CreateButton(page.root,"plates_transfer_parse","解析导入",0,0,88,27,9,false);page:RegisterWidget("transfer",page.transferParse)
    page.transferConfirm=S.UI:CreateButton(page.root,"plates_transfer_confirm","确认导入",0,0,88,27,9,false);page:RegisterWidget("transfer",page.transferConfirm)
    page.transferPreset=S.UI:CreateButton(page.root,"plates_transfer_preset","导入内置实战库",0,0,110,27,9,false);page:RegisterWidget("transfer",page.transferPreset)

    local function ShowTransferChunk(index)
        local chunks=page.transferChunks or {};local count=#chunks
        if count<=0 or not page.transferEdit then return end
        index=math.max(1,math.min(count,math.floor(tonumber(index) or 1)))
        page.transferChunkIndex=index;page.transferEdit:SetText(chunks[index] or "");page.pendingImportText=nil
    end

    local function EnsureTransferClipboardMessage()
        local widget=page.transferClipboardMessage
        if widget and type(widget.CopyTextToClipboard)=="function" then return widget end
        local created=nil
        local widgetType=UOT_MESSAGE or (OBJECT_TYPE and OBJECT_TYPE.MESSAGE)
        if widgetType~=nil and page.root and type(page.root.CreateChildWidgetByType)=="function" then
            local ok,value=pcall(function()
                return page.root:CreateChildWidgetByType(widgetType,S.PhysicalId("plates_transfer_clipboard"),0,true)
            end)
            if ok then created=value end
        end
        if created==nil and UIParent~=nil and type(UIParent.CreateWidget)=="function" then
            local ok,value=pcall(function()
                return UIParent:CreateWidget("message",S.PhysicalId("plates_transfer_clipboard_fallback"),page.root)
            end)
            if ok then created=value end
        end
        if not created then return nil,"无法创建 Message 剪贴板控件" end
        if type(created.CopyTextToClipboard)~="function" or type(created.AddMessage)~="function" or type(created.Clear)~="function" then
            if type(created.Show)=="function" then pcall(created.Show,created,false) end
            return nil,"Message:CopyTextToClipboard 不可用"
        end
        -- The RU client lays Message text lazily.  A hidden 1x1 widget can have
        -- an empty/partial backing layout when CopyTextToClipboard() runs.  Keep
        -- a real, extremely transparent layout surface instead.  It is clipped
        -- by the page, but its own text layout still exists for the copy call.
        if type(created.SetMaxLines)=="function" then pcall(created.SetMaxLines,created,32767) end
        if type(created.SetLineSpace)=="function" then pcall(created.SetLineSpace,created,0) end
        if type(created.SetInset)=="function" then pcall(created.SetInset,created,0,0,0,0) end
        if type(created.SetExtent)=="function" then pcall(created.SetExtent,created,12000,1200) end
        if type(created.SetAlpha)=="function" then pcall(created.SetAlpha,created,0.01) end
        if type(created.AddAnchor)=="function" then
            local anchorTarget=page.transferEdit or page.root
            pcall(created.AddAnchor,created,"TOPLEFT",anchorTarget,0,0)
        end
        if type(created.Show)=="function" then pcall(created.Show,created,false) end
        page.transferClipboardMessage=created
        return created
    end

    local function BuildClipboardMessages(lines)
        -- Keep the common 5k-ID case in one backing Message object while still
        -- avoiding an oversized single AddMessage() if the library eventually
        -- grows far beyond that.  Chunk boundaries are preserved verbatim.
        local messages,cur={},""
        local cap=60000
        for i=1,#lines do
            local line=tostring(lines[i] or "")
            if line~="" then
                local candidate=cur=="" and line or (cur.."\n"..line)
                if cur~="" and #candidate>cap then
                    messages[#messages+1]=cur
                    cur=line
                else
                    cur=candidate
                end
            end
        end
        if cur~="" then messages[#messages+1]=cur end
        return messages,table.concat(lines,"\n")
    end

    local function FinishClipboardCopy(widget,label)
        local ok,result=pcall(function()
            if type(widget.ScrollToTop)=="function" then widget:ScrollToTop() end
            return widget:CopyTextToClipboard()
        end)
        if type(widget.Show)=="function" then pcall(widget.Show,widget,false) end
        page.transferClipboardBusy=false
        if not ok or result==false then
            S.SafeChat("BUFF显示：客户端剪贴板复制失败："..tostring(ok and "CopyTextToClipboard 返回 false" or result),"warning","plates")
            return false
        end
        S.SafeChat("BUFF显示："..tostring(label or "导出文本").."已调用客户端一键复制。")
        return true
    end

    local function CopyTransferLines(lines,label)
        if type(lines)~="table" or #lines<=0 then
            S.SafeChat("BUFF显示：没有可复制的导出文本。","warning","plates");return false
        end
        local widget,reason=EnsureTransferClipboardMessage()
        if not widget then
            S.SafeChat("BUFF显示：当前客户端无法使用 Message 剪贴板接口（"..tostring(reason or "未知原因").."），请使用“复制当前片”逐片复制。","warning","plates")
            return false
        end
        local messages,fullText=BuildClipboardMessages(lines)
        if #messages<=0 or fullText=="" then
            S.SafeChat("BUFF显示：导出文本为空。","warning","plates");return false
        end
        local ok,err=pcall(function()
            widget:Clear()
            for i=1,#messages do widget:AddMessage(messages[i]) end
            -- Show for a real layout pass.  Previous hidden/1x1 implementations
            -- copied only an empty/current page on some RU clients.
            if type(widget.Show)=="function" then widget:Show(true) end
        end)
        if not ok then
            if type(widget.Show)=="function" then pcall(widget.Show,widget,false) end
            S.SafeChat("BUFF显示：准备剪贴板文本失败："..tostring(err),"warning","plates");return false
        end
        page.transferClipboardText=fullText
        page.transferClipboardBusy=true
        local taskName="plates_transfer_clipboard_once"
        if S.Scheduler and type(S.Scheduler.RemoveTask)=="function" then S.Scheduler:RemoveTask(taskName) end
        if S.Scheduler and type(S.Scheduler.AddTask)=="function" then
            S.Scheduler:AddTask(taskName,80,function()
                S.Scheduler:RemoveTask(taskName)
                FinishClipboardCopy(widget,label)
            end,false,"plates_transfer_clipboard","P1")
            return true
        end
        return FinishClipboardCopy(widget,label)
    end

    local function CopyTransferText(text,label)
        text=tostring(text or "")
        if text=="" then S.SafeChat("BUFF显示：没有可复制的导出文本。","warning","plates");return false end
        return CopyTransferLines({text},label)
    end

    S.UI:SafeHandler(page.transferExport,"OnClick",function()
        local p=P();if not p or not p.Manager or not page.transferEdit then return end
        local text,err
        page.pendingImportText=nil;page.pendingImportSummary=nil;page.transferChunks={};page.transferChunkIndex=1;page.transferExportInfo=nil
        if page.transferMode=="library" then
            local copyText,e,info,chunks
            if p.Manager.ExportAuraLibraryCopyText then copyText,e,info,chunks=p.Manager:ExportAuraLibraryCopyText()
            else chunks,e,info=p.Manager:ExportAuraLibraryChunks();if chunks then copyText=table.concat(chunks,"\n") end end
            err=e
            if chunks then
                page.transferChunks=chunks;page.transferExportInfo=info;page.transferClipboardText=copyText;ShowTransferChunk(1)
                CopyTransferLines(chunks,"全部 "..tostring(#chunks).." 个状态库分片")
            end
        elseif page.transferMode=="all" then text=p.Manager:ExportConfig()
        elseif page.transferMode=="tracking" then text=p.Manager:ExportTracking()
        elseif page.transferMode=="layout" then text=p.Manager:ExportLayout()
        else text,err=p.Manager:ExportRule(page.trackScope,page.trackType,page.selectedTrackId) end
        if text then page.transferEdit:SetText(text);CopyTransferText(text,"当前导出文本")
        elseif page.transferMode~="library" or not page.transferExportInfo then S.SafeChat(tostring(err or "没有可导出的内容"),"warning","plates") end
        page:Refresh()
    end,"plates:transfer_export")
    S.UI:SafeHandler(page.transferCopyAll,"OnClick",function()
        local chunks=page.transferChunks or {}
        if page.transferMode=="library" and #chunks>0 then
            -- Clipboard is not constrained by the in-game multi-edit length. Keep one
            -- RPPLATESAURA3 chunk per physical line so external backups/sharing preserve
            -- exact chunk boundaries; imports must still be pasted one chunk at a time.
            CopyTransferLines(chunks,"全部 "..tostring(#chunks).." 个状态库分片")
        elseif page.transferEdit and page.transferEdit.GetText then
            CopyTransferText(page.transferEdit:GetText(),"当前导出文本")
        end
    end,"plates:transfer_copy_all")
    S.UI:SafeHandler(page.transferCopyCurrent,"OnClick",function()
        local chunks=page.transferChunks or {};local count=#chunks
        if page.transferMode=="library" and count>0 then
            local index=math.max(1,math.min(count,math.floor(tonumber(page.transferChunkIndex) or 1)))
            CopyTransferText(chunks[index],"状态库第 "..tostring(index).."/"..tostring(count).." 片")
        elseif page.transferEdit and page.transferEdit.GetText then
            CopyTransferText(page.transferEdit:GetText(),"当前导出文本")
        end
    end,"plates:transfer_copy_current")
    S.UI:SafeHandler(page.transferChunkPrev,"OnClick",function() ShowTransferChunk((page.transferChunkIndex or 1)-1);page:Refresh() end,"plates:transfer_chunk_prev")
    S.UI:SafeHandler(page.transferChunkNext,"OnClick",function() ShowTransferChunk((page.transferChunkIndex or 1)+1);page:Refresh() end,"plates:transfer_chunk_next")
    S.UI:SafeHandler(page.transferPolicy,"OnClick",function() page.auraImportPolicy=page.auraImportPolicy=="replace" and "merge" or "replace";page:Refresh() end,"plates:transfer_policy")
    S.UI:SafeHandler(page.transferParse,"OnClick",function()
        local p=P();if not p or not p.Manager or not page.transferEdit then return end
        local raw=tostring(page.transferEdit:GetText() or "")
        if raw:find("RPPLATESAURA3",1,true) and p.Manager.StageAuraImportText then
            local staged,stageErr=p.Manager:StageAuraImportText(raw)
            if not staged then
                page.pendingImportText=nil;page.pendingImportSummary=nil;S.SafeChat("状态库分片暂存失败："..tostring(stageErr),"warning","plates")
            else
                page.pendingImportText=nil;page.pendingImportSummary=staged
                local pasted=tonumber(staged.pasted) or 1
                S.SafeChat("状态库：本次识别 "..tostring(pasted).." 个分片，累计 "..tostring(staged.received).."/"..tostring(staged.total)..(staged.complete and ("，校验完成，共 "..tostring(staged.unique).." 个 ID。") or "。"))
            end
        else
            local info,err=p.Manager:PreviewImportPackage(raw)
            if not info then
                page.pendingImportText=nil;page.pendingImportSummary=nil;S.SafeChat("导入解析失败："..tostring(err),"warning","plates")
            else
                page.pendingImportText=raw;page.pendingImportSummary=info
            end
        end
        page:Refresh()
    end,"plates:transfer_parse")
    S.UI:SafeHandler(page.transferConfirm,"OnClick",function()
        local p=P();if not p or not p.Manager then return end
        local stage=p.Manager.GetAuraImportStageInfo and p.Manager:GetAuraImportStageInfo() or nil
        local ok,err,info
        if stage and stage.complete==true and page.pendingImportSummary and page.pendingImportSummary.kind=="aura_stage" then
            ok,err,info=p.Manager:CommitAuraImport(page.auraImportPolicy)
        elseif page.pendingImportText then
            ok,err,info=p.Manager:ImportPackage(page.pendingImportText)
        else return end
        if not ok then S.SafeChat("导入失败："..tostring(err),"error","plates")
        else
            local extra=info and info.kind=="aura_library" and (" · 状态 ID "..tostring(info.unique or 0).." · "..(info.policy=="replace" and "替换" or "合并")) or ""
            S.SafeChat("BUFF显示："..tostring(info and info.label or "配置").."导入完成"..extra.."。");page.pendingImportText=nil;page.pendingImportSummary=nil
        end
        page:Refresh()
    end,"plates:transfer_confirm")
    S.UI:SafeHandler(page.transferPreset,"OnClick",function() local p=P();if p and p.Manager and p.Manager.ImportCorePreset then local ok,err=p.Manager:ImportCorePreset();if not ok then S.SafeChat("实战库导入失败："..tostring(err),"error","plates") else S.SafeChat("BUFF显示：内置实战库已覆盖（当前追踪已替换为新库）。") end end;page:Refresh() end,"plates:transfer_preset")

    --------------------------------------------------------------------------
    -- Diagnostics: make Hidden whitelist / unknown candidates directly visible.
    --------------------------------------------------------------------------
    page:AddInfo("diag","counts",function() local p=P();if not p or not p.Storage then return "Storage 未初始化" end;local aura=p.Storage.AuraCount and p.Storage:AuraCount() or 0;return "Aura唯一="..tostring(aura).." · Proxy：目标 B/D/H="..p.Storage:TrackedCount("target","buff").."/"..p.Storage:TrackedCount("target","debuff").."/"..p.Storage:TrackedCount("target","hidden").." · 自身="..p.Storage:TrackedCount("player","buff").."/"..p.Storage:TrackedCount("player","debuff").."/"..p.Storage:TrackedCount("player","hidden") end)
    page:AddInfo("diag","hidden",function()
        local p=P();local r=p and p.Runtime;local function one(scope) local st=r and r.scopes and r.scopes[scope] or {};local active=p and p.Storage and p.Storage:ActiveTrackedCount(scope,"hidden") or 0;return (scope=="target" and "目标" or "自身").." Hidden 白名单="..tostring(active).." · 空白名单="..tostring(st.hiddenWhitelistEmpty==true) end;return one("target").." · "..one("player").."（严格白名单，不存在显示全部回退）"
    end)
    page:AddInfo("diag","runtime",function() local p=P();local r=p and p.Runtime;if type(r)~="table" then return "Runtime 未初始化" end;return "Runtime="..(r.running==true and "运行中" or "停止").." · 心跳 "..tostring(r.heartbeatSerial or 0).." · 成功更新 "..tostring(r.successfulUpdateSerial or 0).." · Watchdog "..tostring(r.watchdogRecoveries or 0) end)
    page:AddControl("diag","refresh",function() return "立即刷新两个 HUD" end,function() local p=P();if p and p.Runtime and p.Runtime.ForceAll then p.Runtime:ForceAll() end end)
    page:AddControl("diag","scan_hidden",function() return "深度扫描当前 Hidden（仅诊断）" end,function()
        local p=P();if not p or not p.Api then return end;local a=p.Api:GetEffectCatalog("target","hidden",128,true) or {};local b=p.Api:GetEffectCatalog("player","hidden",128,true) or {};local function stats(list) local known,unknown,trackable=0,0,0;for _,e in ipairs(list) do if e.diagnosticOnly then unknown=unknown+1 else known=known+1 end;if e.trackable then trackable=trackable+1 end end;return known,unknown,trackable end;local ak,au,at=stats(a);local bk,bu,bt=stats(b);S.SafeChat("Hidden深扫：目标 正常/未知/可追踪="..ak.."/"..au.."/"..at.."；自身="..bk.."/"..bu.."/"..bt)
    end)
    page:AddControl("diag","recover",function() return "一键恢复基础显示（不放开 Hidden）" end,function()
        local p=P();if not p or not p.Storage then return end;for _,scope in ipairs({"target","player"}) do local c=p.Storage:GetPlate(scope);if c then c.enabled=true;c.showBuffs=true;c.showDebuffs=true;c.trackedOnly=true end end;p.Storage:MarkDirty();p.Storage:Save(true);if S.HudManager then S.HudManager:SetVisible("plates_target",true,true);S.HudManager:SetVisible("plates_player",true,true) end;if p.Runtime and p.Runtime.ForceAll then p.Runtime:ForceAll() end
    end)
    page.diagReport=S.UI.CreateMultiEditBox and S.UI:CreateMultiEditBox(page.root,"plates_diag_report_ui2",0,0,420,150,65535) or nil;if page.diagReport then page:RegisterWidget("diag",page.diagReport) end
    page.diagBuild=S.UI:CreateButton(page.root,"plates_diag_build_ui2","生成可复制诊断",0,0,118,27,9,false);page:RegisterWidget("diag",page.diagBuild)
    S.UI:SafeHandler(page.diagBuild,"OnClick",function() local p=P();if p and p.Diagnostics and page.diagReport then local report=p.Diagnostics:BuildReport() or "";page.diagReport:SetText(report);S.SafeChat("BUFF显示：诊断已生成，可 Ctrl+A / Ctrl+C 复制。") end end,"plates:diag_build_ui2")

    function page:OnPageHidden()
        if self.transferClipboardMessage and type(self.transferClipboardMessage.Show)=="function" then pcall(self.transferClipboardMessage.Show,self.transferClipboardMessage,false) end
        if S.Scheduler and type(S.Scheduler.RemoveTask)=="function" then S.Scheduler:RemoveTask("plates_transfer_clipboard_once") end
        self.transferClipboardBusy=false
        local p=P()
        if p and p.UI then
            if p.UI.SetPreviewMode then p.UI:SetPreviewMode(self.layoutScope,"real") end
            if p.UI.SetCalibration then p.UI:SetCalibration(nil) end
            if p.UI.SetLayoutEdit then p.UI:SetLayoutEdit(nil,nil) end
        end
    end

    function page:ApplySubVisibility()
        -- Enforce section ownership after custom layout. This replaces the old
        -- post-layout SetSection(..., false) call that re-showed unpositioned
        -- controls at (0,0).
        -- Base SetSection owns showing the active section.  Only hide inactive
        -- sections here so Refresh() remains authoritative for paged/empty rows.
        -- Re-showing every active widget here was the cause of (0,0) controls
        -- and blank list rows after a custom layout pass.
        for _,sec in ipairs(self.sectionOrder or {}) do
            if sec.id~=self.activeSection then
                for _,w in ipairs(sec.widgets or {}) do if w and w.Show then w:Show(false) end end
            end
        end
        local tracking=self.activeSection=="tracking"
        local adv=tracking and self.trackAdvanced==true and self.selectedTrackId~=nil
        local advGlobal=tracking and self.trackAdvanced==true
        for _,w in ipairs({self.trackAdvTime,self.trackAdvStack,self.trackAdvBorder,self.trackAdvTooltip,self.trackAdvExpire,self.trackAdvIconDown,self.trackAdvIconUp,self.trackAdvIconReset,self.trackNameApply}) do if w and w.Show then w:Show(adv) end end
        if self.trackNameEdit and self.trackNameEdit.Show then self.trackNameEdit:Show(adv) end
        if self.trackClearAll and self.trackClearAll.Show then self.trackClearAll:Show(tracking) end

        local layout=self.activeSection=="layout"
        local effectMode=layout and self.layoutGroup=="effect"
        local hudMode=layout and self.layoutGroup=="hud"
        local metadataMode=layout and self.layoutScope=="target" and self.layoutGroup=="metadata"
        local distanceMode=layout and self.layoutScope=="target" and self.layoutGroup=="distance"
        local castMode=layout and self.layoutScope=="target" and self.layoutGroup=="cast"
        local equipmentMode=layout and self.layoutScope=="player" and self.layoutGroup=="hud"
        local function ShowNumericRow(row,show)
            for _,w in ipairs({row.panel,row.label,row.minus,row.slider,row.edit,row.apply,row.plus}) do if w and w.Show then w:Show(show) end end
        end
        local function ShowControlCard(it,show)
            for _,w in ipairs({it and it.panel,it and it.title,it and it.sub,it and it.button}) do if w and w.Show then w:Show(show) end end
        end
        for _,row in ipairs(self.layoutBaseRows or {}) do ShowNumericRow(row,hudMode) end
        for _,row in ipairs(self.layoutEffectRows or {}) do ShowNumericRow(row,effectMode) end
        for _,row in ipairs(self.layoutMetadataRows or {}) do ShowNumericRow(row,metadataMode) end
        for _,row in ipairs(self.layoutDistanceRows or {}) do ShowNumericRow(row,distanceMode) end
        for _,row in ipairs(self.layoutCastRows or {}) do ShowNumericRow(row,castMode) end
        for _,row in ipairs(self.layoutEquipmentRows or {}) do ShowNumericRow(row,equipmentMode) end
        for _,it in ipairs(self.layoutMetadataControls or {}) do ShowControlCard(it,metadataMode) end
        for _,it in ipairs(self.layoutDistanceControls or {}) do ShowControlCard(it,distanceMode) end
        for _,it in ipairs(self.layoutCastControls or {}) do ShowControlCard(it,castMode) end
        for _,it in ipairs(self.layoutEquipmentControls or {}) do ShowControlCard(it,equipmentMode) end

        for _,it in ipairs(self.layoutGroupTabs or {}) do
            local targetOnly=it.value=="metadata" or it.value=="distance" or it.value=="cast"
            if it.button and it.button.Show then it.button:Show(layout and (not targetOnly or self.layoutScope=="target")) end
        end
        for _,it in ipairs(self.layoutTypeTabs or {}) do if it.button and it.button.Show then it.button:Show(effectMode) end end
        if self.layoutDirection and self.layoutDirection.Show then self.layoutDirection:Show(effectMode) end
        if self.layoutReset and self.layoutReset.Show then self.layoutReset:Show(effectMode) end
        if self.layoutDragPart and self.layoutDragPart.Show then self.layoutDragPart:Show(effectMode or castMode) end
        if self.layoutAnchor and self.layoutAnchor.Show then self.layoutAnchor:Show(hudMode) end
        if self.layoutPreview and self.layoutPreview.Show then self.layoutPreview:Show(layout and not castMode) end
        if self.layoutStop and self.layoutStop.Show then self.layoutStop:Show(layout) end
        for _,w in ipairs({self.layoutDragAll,self.layoutCopy}) do
            if w and w.Show then w:Show(effectMode or hudMode) end
        end
        if self.layoutHint and self.layoutHint.Show then self.layoutHint:Show(effectMode or hudMode) end
        if self.layoutMetadataHint and self.layoutMetadataHint.Show then self.layoutMetadataHint:Show(metadataMode) end
        if self.layoutDistanceHint and self.layoutDistanceHint.Show then self.layoutDistanceHint:Show(distanceMode) end
        if self.layoutCastHint and self.layoutCastHint.Show then self.layoutCastHint:Show(castMode) end
        if self.layoutEquipmentHint and self.layoutEquipmentHint.Show then self.layoutEquipmentHint:Show(equipmentMode) end
        if self.layoutEquipmentDirection and self.layoutEquipmentDirection.Show then self.layoutEquipmentDirection:Show(equipmentMode) end
    end

    local BasePlatesSetSection=page.SetSection
    function page:SetSection(id,reflow)
        -- 兼容热重载前的旧入口：原“玩家信息/距离设置”一级页签现在都归入外观布局。
        if id=="metadata" or id=="distance" then
            self.layoutScope="target"
            self.layoutGroup=id
            id="layout"
        end
        if self.activeSection=="layout" and id~="layout" then
            local p=P()
            if p and p.UI then
                if p.UI.SetPreviewMode then p.UI:SetPreviewMode(self.layoutScope,"real") end
                if p.UI.SetCalibration then p.UI:SetCalibration(nil) end
                if p.UI.SetLayoutEdit then p.UI:SetLayoutEdit(nil,nil) end
            end
        end
        local ok=BasePlatesSetSection(self,id,reflow)
        self:ApplySubVisibility()
        return ok
    end

    local function RefreshTabs(tabs)
        for _,it in ipairs(tabs or {}) do S.Theme:SetButtonActive(it.button,tabs.getter()==it.value) end
    end
    local function SetNumericEnabled(row,enabled)
        if not row then return end
        enabled=enabled~=false
        for _,w in ipairs({row.minus,row.plus,row.apply,row.edit}) do if w and w.Enable then w:Enable(enabled) end end
        if row.slider and type(row.slider.SetEnabled)=="function" then row.slider:SetEnabled(enabled) end
        row.enabled=enabled
    end
    local function TriText(v) return v==nil and "继承" or (v and "开" or "关") end
    function page:Refresh()
        self:RefreshBase();self:RefreshGeneric()
        RefreshTabs(self.displayScopeTabs);RefreshTabs(self.trackScopeTabs);RefreshTabs(self.trackTypeTabs);RefreshTabs(self.trackViewTabs);RefreshTabs(self.layoutScopeTabs);RefreshTabs(self.layoutGroupTabs);RefreshTabs(self.layoutTypeTabs);RefreshTabs(self.colorScopeTabs);RefreshTabs(self.colorTypeTabs);RefreshTabs(self.transferModeTabs)
        local p=P()
        self.trackRaw:SetText("原始/未知："..BoolText(self.showRawHidden));if self.trackRaw.Enable then self.trackRaw:Enable(self.trackType=="hidden") end
        if p and p.Storage then
            local captureOn=p.Manager and p.Manager.IsCaptureEnabled and p.Manager:IsCaptureEnabled() or false
            local captureSticky
            local targetSvc2=S.TargetService
            if targetSvc2~=nil and type(targetSvc2.IsQueueRetain)=="function" then captureSticky=targetSvc2:IsQueueRetain()
            else captureSticky=p.Manager and p.Manager.IsCaptureSticky and p.Manager:IsCaptureSticky() or true end
            local captureCount=p.Manager and p.Manager.GetCaptureCount and p.Manager:GetCaptureCount(self.trackScope,self.trackType) or 0
            local syncOn=self.trackType~="hidden" and p.Storage.IsAuraSyncEnabled and p.Storage:IsAuraSyncEnabled() or false
            self.trackDetect:SetText(captureOn and "停止检测" or "开始检测")
            self.trackQueue:SetText("队列保留："..(captureSticky and "开" or "关"))
            local syncMode=p.Storage.GetAuraSyncMode and p.Storage:GetAuraSyncMode() or "same"
            self.trackSync:SetText("同步加入："..(syncOn and "开" or "关"));if self.trackSync.Enable then self.trackSync:Enable(self.trackType~="hidden") end
            self.trackSyncMode:SetText("同步范围："..(syncMode=="all" and "四向" or "同类"));if self.trackSyncMode.Enable then self.trackSyncMode:Enable(self.trackType~="hidden") end
            S.Theme:SetButtonActive(self.trackDetect,captureOn);S.Theme:SetButtonActive(self.trackQueue,captureSticky);S.Theme:SetButtonActive(self.trackSync,syncOn);S.Theme:SetButtonActive(self.trackSyncMode,syncMode=="all")
            local auraCount=p.Storage.AuraCount and p.Storage:AuraCount() or 0
            self.trackState:SetText(ScopeTitle(self.trackScope).." / "..TrackTypeTitle(self.trackType).." · 已追踪 "..p.Storage:TrackedCount(self.trackScope,self.trackType).." · Aura库 "..tostring(auraCount).." · 捕获 "..tostring(captureCount).." · "..(self.trackType=="hidden" and "Hidden=严格白名单" or (syncOn and (syncMode=="all" and "新增 ID 同步自身/目标 Buff+Debuff" or "新增 ID 同步自身/目标同类型") or "新增 ID 仅加入当前范围")))
            local entries={}
            if self.trackView=="tracked" then for id,e in pairs(p.Storage:GetTracked(self.trackScope,self.trackType) or {}) do entries[#entries+1]={id=tostring(id),entry=e} end;table.sort(entries,function(a,b) local pa,pb=tonumber(a.entry.priority) or 0,tonumber(b.entry.priority) or 0;if pa~=pb then return pa>pb end;return (tonumber(a.id) or 0)<(tonumber(b.id) or 0) end)
            elseif self.trackSource=="capture" and p.Manager and p.Manager.GetCaptureList then for _,e in ipairs(p.Manager:GetCaptureList(self.trackScope,self.trackType) or {}) do entries[#entries+1]={id=tostring(e.id or ""),entry=e} end
            else for _,e in ipairs(self.trackLive or {}) do entries[#entries+1]={id=tostring(e.id or ""),entry=e} end end
            local pageSize=ActiveTrackPageSize()
            self.trackOffset=math.min(self.trackOffset,math.max(0,math.floor(math.max(0,#entries-1)/pageSize)*pageSize))
            for i,row in ipairs(self.trackRows) do
                local item=i<=pageSize and entries[self.trackOffset+i] or nil;row.item=item
                if item then
                    local e=item.entry or {};local id=item.id~="" and item.id or "无稳定ID";local name=tostring(e.customName or "")~="" and tostring(e.customName) or tostring(e.name or ("ID "..id));row.name:SetText(name)
                    if self.trackView=="current" then row.meta:SetText("ID "..id.." · "..TrackTypeTitle(self.trackType).." · "..tostring(tonumber(e.stack) or 1).."层 · "..FormatRemaining(e.timeLeftMs)..(e.diagnosticOnly and " · 原始/未知" or ""));local exists=id:match("^%d+$") and p.Storage:GetTrackedEntry(self.trackScope,self.trackType,id)~=nil;row.action:SetText(e.trackable==false and "仅诊断" or (exists and "取消追踪" or "追加"));if row.action.Enable then row.action:Enable(e.trackable~=false) end
                    else local maskText="";if self.trackType~="hidden" and p.Storage.GetAuraMask then maskText=" · 范围 "..string.format("%X",p.Storage:GetAuraMask(id)) end;row.meta:SetText("ID "..id.." · "..TrackTypeTitle(self.trackType)..maskText.." · 优先级 "..tostring(e.priority or 0).." · "..(e.enabled==false and "已禁用" or "启用"));row.action:SetText("删除");if row.action.Enable then row.action:Enable(true) end end
                    SetRowIcon(row.icon,e.iconPath);row.panel:Show(self.activeSection=="tracking");row.name:Show(self.activeSection=="tracking");row.meta:Show(self.activeSection=="tracking");row.detail:Show(self.activeSection=="tracking");row.action:Show(self.activeSection=="tracking")
                else if row.icon then row.icon:SetVisible(false) end;row.panel:Show(false);row.name:Show(false);row.meta:Show(false);row.detail:Show(false);row.action:Show(false) end
            end
            if self.trackPrev.Enable then self.trackPrev:Enable(self.trackOffset>0) end;if self.trackNext.Enable then self.trackNext:Enable(self.trackOffset+pageSize<#entries) end
            local e=SelectedEntry();local has=e~=nil
            self.trackSelected:SetText(has and ("编辑："..tostring(e.customName~="" and e.customName or e.name or self.selectedTrackId).." · ID "..tostring(self.selectedTrackId).." · 优先级 "..tostring(e.priority or 0)) or "未选择已追踪状态；点“详情”进入单项编辑。")
            for _,b in ipairs({self.trackEnable,self.trackPriorityDown,self.trackPriorityUp,self.trackAdvancedButton,self.trackAdvTime,self.trackAdvStack,self.trackAdvBorder,self.trackAdvTooltip,self.trackAdvExpire,self.trackAdvIconDown,self.trackAdvIconUp,self.trackAdvIconReset,self.trackNameApply}) do if b.Enable then b:Enable(has) end end
            self.trackEnable:SetText(has and (e.enabled==false and "启用此项" or "禁用此项") or "启用/禁用");            self.trackAdvancedButton:SetText(self.trackAdvanced and "高级选项 v" or "高级选项 >")
            self.trackAdvTime:SetText("时间："..TriText(has and e.showDuration));self.trackAdvStack:SetText("层数："..TriText(has and e.showStack));self.trackAdvBorder:SetText("边框："..TriText(has and e.showBorder));self.trackAdvTooltip:SetText("悬浮："..TriText(has and e.showTooltip));self.trackAdvExpire:SetText("到期："..TriText(has and e.expireEnabled));self.trackAdvIconDown:SetText("图标 -");self.trackAdvIconUp:SetText(has and ("图标 + ("..tostring(e.iconSize or "继承")..")") or "图标 +");self.trackAdvIconReset:SetText("图标：继承")
            if self.trackClearAll then
                local armedNow=(tonumber(self.trackClearAllArmedAt) or 0)>0
                if armedNow and (S.NowMs and S.NowMs() or 0)-(tonumber(self.trackClearAllArmedAt) or 0)>5000 then armedNow=false;self.trackClearAllArmedAt=0 end
                self.trackClearAll:SetText(armedNow and "再点确认清空" or "清空所有已追踪")
                if self.trackClearAll.Enable then self.trackClearAll:Enable(self.activeSection=="tracking") end
            end
            if self.trackNameEdit and self.trackNameEdit.SetText and self.activeSection=="tracking" and has then self.trackNameEdit:SetText(tostring(e.customName or "")) end
        end
        local l=EffectLayout(self.layoutScope,self.layoutType);if l then self.layoutDirection:SetText("区域方向："..tostring(l.direction or "RIGHT")) end;local lc=Cfg(self.layoutScope);if lc then self.layoutAnchor:SetText("整体锚点："..tostring(lc.anchorMode or "TOP")) end;self.layoutCopy:SetText(self.layoutScope=="target" and "复制目标→自身" or "复制自身→目标")
        local equipmentCfg=PlayerEquipment();if self.layoutEquipmentDirection then self.layoutEquipmentDirection:SetText("装备方向："..tostring(equipmentCfg and equipmentCfg.direction or "RIGHT")) end
        if self.layoutDragPart then self.layoutDragPart:SetText(self.layoutGroup=="cast" and "拖动施法条" or "拖动当前区域") end
        local previewMock=p and p.UI and p.UI.GetPreviewMode and p.UI:GetPreviewMode(self.layoutScope)=="mock"
        if p and p.UI and p.UI.GetPreviewMode then self.layoutPreview:SetText("预览："..(previewMock and "模拟状态" or "真实状态")) end
        local dir=tostring(l and l.direction or "RIGHT")
        local horizontal=dir=="RIGHT" or dir=="LEFT"
        local effectActive=self.layoutGroup=="effect"
        SetNumericEnabled(self.numericById.cols,effectActive and horizontal)
        SetNumericEnabled(self.numericById.gap,effectActive and horizontal)
        if self.layoutHint then
            local hint=""
            if self.layoutGroup=="hud" then
                hint="整体 HUD：这里只控制基础画布宽度、区域间距和整体位置；子元素自己的偏移不会反向改变画布尺寸。"
            elseif self.layoutGroup=="effect" and horizontal then
                hint=(previewMock and "模拟预览会持续重绘。" or "真实状态数量不足时，最大数量/每行数量可能暂时看不出差异，可切到模拟预览。").." 横向排列：每行数量、横向间距生效；纵向间距在发生换行后才明显。"
            elseif self.layoutGroup=="effect" then
                hint=(previewMock and "模拟预览会持续重绘。" or "真实状态数量不足时，最大数量可能暂时看不出差异，可切到模拟预览。").." 当前为纵向排列：每行数量与横向间距不参与布局，已自动禁用；纵向间距控制图标之间的距离。"
            end
            self.layoutHint:SetText(hint)
        end
        for section,rows in pairs(self.numericRows) do for _,row in ipairs(rows) do local v=tonumber(row.getter()) or row.min;local suffix=row.enabled==false and "（当前方向不适用）" or "";row.label:SetText(row.labelText.."："..tostring(row.integer and math.floor(v+0.5) or v)..suffix);if row.edit and row.edit.SetText and self.activeSection==section then row.edit:SetText(tostring(row.integer and math.floor(v+0.5) or v)) end;if row.slider and row.slider.SetValue then pcall(function() row.slider:SetValue(v,false) end);if S.UI.UpdateSliderVisual then S.UI:UpdateSliderVisual(row.slider,v) end end end end
        local cc=CurrentColor();SetColorPreview(self.colorPreview,cc);local r,g,b,a=Color255(cc);self.colorValue:SetText((self.colorTarget=="expire" and "到期颜色 · " or "边框颜色 · ")..string.format("RGBA %d/%d/%d/%d · #%02X%02X%02X%02X",r,g,b,a,r,g,b,a));S.Theme:SetButtonActive(self.colorBorder,self.colorTarget=="border");S.Theme:SetButtonActive(self.colorExpire,self.colorTarget=="expire")
        if self.selectedTrackId==nil then self.colorRuleMode=false end;self.colorRuleTarget:SetText(self.colorRuleMode and ("编辑规则：ID "..tostring(self.selectedTrackId)) or "编辑对象：区域");if self.colorRuleTarget.Enable then self.colorRuleTarget:Enable(self.selectedTrackId~=nil) end;S.Theme:SetButtonActive(self.colorRuleTarget,self.colorRuleMode);if self.colorRuleClear.Enable then self.colorRuleClear:Enable(self.colorRuleMode and self.selectedTrackId~=nil) end;self.colorRuleClear:SetText("规则颜色：恢复继承")
        local cl=EffectLayout(self.colorScope,self.colorType) or {};local cre=self.colorRuleMode and SelectedEntry() or nil
        if cre then
            self.colorToggleTime:SetText("时间："..TriText(cre.showDuration));self.colorToggleStack:SetText("层数："..TriText(cre.showStack));self.colorToggleBorder:SetText("边框："..TriText(cre.showBorder));self.colorToggleTooltip:SetText("悬浮："..TriText(cre.showTooltip));self.colorToggleExpire:SetText("到期："..TriText(cre.expireEnabled))
        else
            self.colorToggleTime:SetText("时间："..BoolText(cl.showDuration~=false));self.colorToggleStack:SetText("层数："..BoolText(cl.showStack~=false));self.colorToggleBorder:SetText("边框："..BoolText(cl.showBorder~=false));self.colorToggleTooltip:SetText("悬浮提示："..BoolText(cl.showTooltip==true));self.colorToggleExpire:SetText("到期提醒："..BoolText(cl.expireEnabled==true))
        end
        if self.colorHint then
            local function EffectiveBool(ruleValue,baseValue,defaultValue)
                if ruleValue~=nil then return ruleValue==true end
                if baseValue~=nil then return baseValue==true end
                return defaultValue==true
            end
            local showBorder=EffectiveBool(cre and cre.showBorder,cl.showBorder,true)
            local expireOn=EffectiveBool(cre and cre.expireEnabled,cl.expireEnabled,false)
            local mock=p and p.UI and p.UI.GetPreviewMode and p.UI:GetPreviewMode(self.colorScope)=="mock"
            if self.colorTarget=="border" and not showBorder then
                self.colorHint:SetText("当前边框显示为关：RGBA 会保存，但 HUD 不会显示边框颜色。先打开“边框”即可立即看到效果；这里不会修改原始 Buff 图标颜色。")
            elseif self.colorTarget=="expire" and not expireOn then
                self.colorHint:SetText("当前到期提醒为关：到期颜色/提醒秒数会保存，但只有打开“到期提醒”并进入阈值后才显示。")
            elseif self.colorTarget=="expire" then
                self.colorHint:SetText((mock and "模拟预览已包含 1.8秒/3.8秒短状态，可直接验证到期颜色。" or "真实状态只有剩余时间进入提醒阈值时才会使用到期颜色。").." RGBA 中 A 为边框透明度。")
            else
                self.colorHint:SetText((mock and "模拟预览会在每次 RGBA/样式修改后立即重绘。" or "如果当前没有可见状态，颜色只能在上方色块预览；可到外观布局切换模拟预览。").." RGBA 中 A 为边框透明度；不会修改原始 Buff 图标颜色。")
            end
        end
        if self.colorHexEdit and self.colorHexEdit.SetText and self.activeSection=="colors" then self.colorHexEdit:SetText(string.format("#%02X%02X%02X%02X",r,g,b,a)) end
        local presets=p and p.Storage and p.Storage:GetColorPresets() or {};for i,b in ipairs(self.customColorButtons) do local preset=presets[self.customColorOffset+i];if preset then b:SetText((self.selectedCustomPreset==tostring(preset.name or "") and "[选] " or "")..tostring(preset.name));b:Show(self.activeSection=="colors");if b.Enable then b:Enable(true) end else b:SetText("-");if b.Enable then b:Enable(false) end end end;if self.customPrev.Enable then self.customPrev:Enable(self.customColorOffset>0) end;if self.customNext.Enable then self.customNext:Enable(self.customColorOffset+6<#presets) end
        local now=S.NowMs and S.NowMs() or 0;if tostring(self.customDeleteArmedName or "")~=tostring(self.selectedCustomPreset or "") or now-(tonumber(self.customDeleteArmedAt) or 0)>5000 then self.customDeleteArmedName=nil;self.customDeleteArmedAt=0 end
        if self.customDelete then self.customDelete:SetText((tonumber(self.customDeleteArmedAt) or 0)>0 and "再点删除" or "删除所选预设");if self.customDelete.Enable then self.customDelete:Enable(self.selectedCustomPreset~=nil) end end
        local stage=p and p.Manager and p.Manager.GetAuraImportStageInfo and p.Manager:GetAuraImportStageInfo() or nil
        self.transferPolicy:SetText("状态库："..(self.auraImportPolicy=="replace" and "替换" or "合并"));S.Theme:SetButtonActive(self.transferPolicy,self.auraImportPolicy=="replace")
        if self.transferPolicy.Enable then self.transferPolicy:Enable(self.transferMode=="library" or (stage~=nil)) end
        local chunkCount=#(self.transferChunks or {});local chunkIndex=math.max(1,math.min(chunkCount>0 and chunkCount or 1,tonumber(self.transferChunkIndex) or 1))
        if self.transferChunkPrev.Enable then self.transferChunkPrev:Enable(chunkCount>0 and chunkIndex>1) end
        if self.transferChunkNext.Enable then self.transferChunkNext:Enable(chunkCount>0 and chunkIndex<chunkCount) end
        local exportTextReady=self.transferEdit and self.transferEdit.GetText and tostring(self.transferEdit:GetText() or "")~=""
        if self.transferCopyAll.Enable then self.transferCopyAll:Enable((self.transferMode=="library" and chunkCount>0) or exportTextReady) end
        if self.transferCopyCurrent.Enable then self.transferCopyCurrent:Enable((self.transferMode=="library" and chunkCount>0) or exportTextReady) end
        if self.pendingImportSummary and self.pendingImportSummary.kind=="aura_stage" then
            local inf=self.pendingImportSummary
            self.transferSummary:SetText("状态库分片批次 "..tostring(inf.batch).." · 已收到 "..tostring(inf.received).."/"..tostring(inf.total)..(inf.complete and (" · 校验通过 · 唯一 ID "..tostring(inf.unique or 0).."。可确认"..(self.auraImportPolicy=="replace" and "替换" or "合并").."导入。") or " · 继续粘贴下一片并点“解析导入”。"))
        elseif self.pendingImportSummary then
            local inf=self.pendingImportSummary;local c=inf.counts;self.transferSummary:SetText("已解析："..tostring(inf.label)..(c and (" · 追踪项 "..tostring(c.total or 0)) or "")..(inf.colorPresets and (" · 颜色预设 "..tostring(inf.colorPresets)) or "").."。确认无误后点击“确认导入”。")
        elseif self.transferExportInfo and chunkCount>0 then
            local inf=self.transferExportInfo;self.transferSummary:SetText("状态库导出 · 唯一 ID "..tostring(inf.unique or 0).." · 批次 "..tostring(inf.batch).." · 当前 "..tostring(chunkIndex).."/"..tostring(chunkCount).."。“一键导出”会把全部分片作为一个剪贴板载荷复制；游戏内可一次解析多个完整分片，超长时仍可逐片恢复。")
        else
            self.transferSummary:SetText("导出范围："..({library="状态库（内部安全分片 / 外部一键复制）",all="全部配置",tracking="只追踪",layout="只布局",rule="单个规则"})[self.transferMode].."。导入分片会先暂存，收齐并校验后才允许 Commit。")
        end
        local canConfirm=self.pendingImportText~=nil or (stage~=nil and stage.complete==true and self.pendingImportSummary and self.pendingImportSummary.kind=="aura_stage")
        if self.transferConfirm.Enable then self.transferConfirm:Enable(canConfirm) end
    end

    local function LayoutTabs(tabs,x,y,w,h,gap)
        local n=#tabs;if n<=0 then return end;local bw=(w-gap*(n-1))/n;for i,it in ipairs(tabs) do it.button:SetExtent(bw,h);S.UI:SetAnchor(it.button,page.root,x+(i-1)*(bw+gap),y) end
    end
    local function LayoutNumericRows(rows,x,y,w,sc,cols)
        cols=cols or 1
        local gap=8*sc;local rowH=38*sc;local cellW=(w-gap*(cols-1))/cols
        for i,row in ipairs(rows or {}) do
            local rr=math.floor((i-1)/cols);local cc=(i-1)%cols;local xx=x+cc*(cellW+gap);local yy=y+rr*rowH
            row.panel:SetExtent(cellW,34*sc);S.UI:SetAnchor(row.panel,page.root,xx,yy)
            local labelW=math.max(70*sc,math.min(132*sc,cellW*0.25));row.label:SetExtent(labelW,18*sc);S.UI:SetAnchor(row.label,page.root,xx+7*sc,yy+8*sc)
            local innerRight=xx+cellW-7*sc
            local minusW,editW,plusW,applyW=28*sc,52*sc,28*sc,42*sc
            local cg=2*sc
            local groupW=minusW+editW+plusW+applyW+cg*3
            local groupX=innerRight-groupW
            row.minus:SetExtent(minusW,22*sc);S.UI:SetAnchor(row.minus,page.root,groupX,yy+6*sc)
            if row.edit then row.edit:SetExtent(editW,22*sc);S.UI:SetAnchor(row.edit,page.root,groupX+minusW+cg,yy+6*sc) end
            row.plus:SetExtent(plusW,22*sc);S.UI:SetAnchor(row.plus,page.root,groupX+minusW+cg+editW+cg,yy+6*sc)
            row.apply:SetExtent(applyW,22*sc);S.UI:SetAnchor(row.apply,page.root,innerRight-applyW,yy+6*sc)
            local sliderX=xx+labelW+10*sc;local sliderW=math.max(36*sc,groupX-sliderX-8*sc)
            if row.slider then row.slider:SetExtent(sliderW,20*sc);row.slider.rsWidth=sliderW;row.slider.rsHeight=20*sc;S.UI:SetAnchor(row.slider,page.root,sliderX,yy+7*sc);if S.UI.UpdateSliderVisual then S.UI:UpdateSliderVisual(row.slider,row.getter()) end end
        end
        return y+math.ceil(#(rows or {})/cols)*rowH
    end
    local function LayoutTabGrid(tabs,x,y,w,h,gap,cols)
        local n=#(tabs or {});if n<=0 then return y end
        cols=math.max(1,math.min(cols or n,n))
        local bw=(w-gap*(cols-1))/cols
        for i,it in ipairs(tabs) do
            local rr=math.floor((i-1)/cols);local cc=(i-1)%cols
            it.button:SetExtent(bw,h);S.UI:SetAnchor(it.button,page.root,x+cc*(bw+gap),y+rr*(h+gap))
        end
        return y+math.ceil(n/cols)*(h+gap)
    end
    local function LayoutControlCards(items,x,y,w,sc,cols)
        local n=#(items or {});if n<=0 then return y end
        local gap=8*sc;local cardH=42*sc
        cols=math.max(1,math.min(cols or 1,n))
        local cellW=(w-gap*(cols-1))/cols
        for i,it in ipairs(items) do
            local rr=math.floor((i-1)/cols);local cc=(i-1)%cols
            local xx=x+cc*(cellW+gap);local yy=y+rr*(cardH+gap)
            it.panel:SetExtent(cellW,cardH);S.UI:SetAnchor(it.panel,page.root,xx,yy)
            local buttonW=76*sc
            it.title:SetExtent(math.max(54*sc,cellW-buttonW-24*sc),16*sc);S.UI:SetAnchor(it.title,page.root,xx+8*sc,yy+6*sc)
            it.sub:SetExtent(math.max(54*sc,cellW-buttonW-24*sc),14*sc);S.UI:SetAnchor(it.sub,page.root,xx+8*sc,yy+22*sc)
            it.button:SetExtent(buttonW,27*sc);S.UI:SetAnchor(it.button,page.root,xx+cellW-buttonW-8*sc,yy+7*sc)
        end
        return y+math.ceil(n/cols)*(cardH+gap)
    end
    function page:ApplyLayout(spec)
        local sc,pad,full,top=self:ApplyBase(spec);local gap=6*sc
        if self.activeSection=="display" then
            LayoutTabs(self.displayScopeTabs,pad,top,math.min(full,310*sc),27*sc,gap);self:LayoutGenericSection("display",top+34*sc,2)
        elseif self.activeSection=="buffcap" then
            -- Generic rows only; no scope tabs above, so layout starts at top.
            self:LayoutGenericSection("buffcap",top,2)
        elseif self.activeSection=="alerts" then
            -- Combat alerts (report 七-方案A). Generic rows only (C14: layout
            -- branch required for the new section to position its widgets).
            self:LayoutGenericSection("alerts",top,2)
        elseif self.activeSection=="lines" then
            -- Unit connection lines (report 七-方案B). Generic rows only.
            self:LayoutGenericSection("lines",top,2)
        elseif self.activeSection=="magiccircle" then
            -- Magic-circle distance (report 八-P1-1). Generic rows only.
            self:LayoutGenericSection("magiccircle",top,2)
        elseif self.activeSection=="tracking" then
            LayoutTabs(self.trackScopeTabs,pad,top,210*sc,25*sc,gap);LayoutTabs(self.trackTypeTabs,pad+220*sc,top,math.min(260*sc,full-220*sc),25*sc,gap)
            LayoutTabs(self.trackViewTabs,pad,top+31*sc,190*sc,25*sc,gap)
            local controlY=top+31*sc
            local wide=full>=760*sc
            if wide then
                local x=pad+200*sc
                for _,pair in ipairs({{self.trackDetect,72},{self.trackQueue,80},{self.trackClearQueue,64},{self.trackScan,64},{self.trackRaw,78},{self.trackSync,82},{self.trackSyncMode,92}}) do local b,w=pair[1],pair[2]*sc;b:SetExtent(w,25*sc);S.UI:SetAnchor(b,self.root,x,controlY);x=x+w+4*sc end
                self.trackState:SetExtent(full,20*sc);S.UI:SetAnchor(self.trackState,self.root,pad,top+61*sc)
            else
                self.trackDetect:SetExtent(86*sc,25*sc);S.UI:SetAnchor(self.trackDetect,self.root,pad+200*sc,controlY)
                self.trackQueue:SetExtent(100*sc,25*sc);S.UI:SetAnchor(self.trackQueue,self.root,pad+291*sc,controlY)
                local y2=top+59*sc;local x=pad
                for _,pair in ipairs({{self.trackClearQueue,74},{self.trackScan,74},{self.trackRaw,90},{self.trackSync,84},{self.trackSyncMode,94}}) do local b,w=pair[1],pair[2]*sc;b:SetExtent(w,25*sc);S.UI:SetAnchor(b,self.root,x,y2);x=x+w+5*sc end
                self.trackState:SetExtent(full,20*sc);S.UI:SetAnchor(self.trackState,self.root,pad,top+89*sc)
            end
            local y=top+(wide and 84*sc or 112*sc)
            -- Manual ID and state-library search become a compact toolbar on
            -- wide windows. This leaves the expandable list the majority of the
            -- available height instead of hard-coding a four-row viewport.
            local sec=self.sections.tracking
            local edits={};for _,it in ipairs(sec.custom) do if it.kind=="edit" then edits[#edits+1]=it end end
            local sideBySide=full>=620*sc and #edits>=2
            local editGap=6*sc;local editW=sideBySide and (full-editGap)/2 or full
            for i,it in ipairs(edits) do
                local xx=sideBySide and (pad+(i-1)*(editW+editGap)) or pad
                local yy=sideBySide and y or (y+(i-1)*49*sc)
                it.panel:SetExtent(editW,46*sc);S.UI:SetAnchor(it.panel,self.root,xx,yy)
                it.caption:SetExtent(math.max(70*sc,editW-16*sc),16*sc);S.UI:SetAnchor(it.caption,self.root,xx+7*sc,yy+4*sc)
                local bw=92*sc
                if it.edit then it.edit:SetExtent(math.max(70*sc,editW-bw-18*sc),23*sc);S.UI:SetAnchor(it.edit,self.root,xx+7*sc,yy+20*sc) end
                it.button:SetExtent(bw,22*sc);S.UI:SetAnchor(it.button,self.root,xx+editW-bw-7*sc,yy+20*sc)
                if it.missing then it.missing:Show(it.edit==nil and self.activeSection=="tracking") end
            end
            y=y+(sideBySide and 49*sc or (#edits*49*sc))
            local rowH=48*sc
            local advOpen=self.trackAdvanced==true
            local advVisible=self.trackAdvanced==true and self.selectedTrackId~=nil
            -- footer 行 + 常驻的“清空所有已追踪”按钮需要固定预留高度（无论高级选项是否展开）。
            local footerReserve=(advOpen and 250*sc or 98*sc)
            local available=math.max(rowH,(self.contentBottom or (y+rowH*4))-y-footerReserve)
            self.trackPageSize=math.max(2,math.min(TRACK_ROW_CAP,math.floor(available/(rowH+3*sc))))
            local pageSize=ActiveTrackPageSize()
            for i,row in ipairs(self.trackRows) do
                if i<=pageSize then
                    local yy=y+(i-1)*(rowH+3*sc);row.panel:SetExtent(full,rowH);S.UI:SetAnchor(row.panel,self.root,pad,yy);row.name:SetExtent(math.max(120*sc,full-210*sc),18*sc);S.UI:SetAnchor(row.name,self.root,pad+48*sc,yy+6*sc);row.meta:SetExtent(math.max(120*sc,full-210*sc),16*sc);S.UI:SetAnchor(row.meta,self.root,pad+48*sc,yy+25*sc);row.detail:SetExtent(48*sc,24*sc);S.UI:SetAnchor(row.detail,self.root,pad+full-112*sc,yy+12*sc);row.action:SetExtent(56*sc,24*sc);S.UI:SetAnchor(row.action,self.root,pad+full-60*sc,yy+12*sc)
                end
            end
            local py=y+pageSize*(rowH+3*sc);self.trackPrev:SetExtent(70*sc,24*sc);self.trackNext:SetExtent(70*sc,24*sc);S.UI:SetAnchor(self.trackPrev,self.root,pad,py);S.UI:SetAnchor(self.trackNext,self.root,pad+76*sc,py);self.trackSelected:SetExtent(full-160*sc,20*sc);S.UI:SetAnchor(self.trackSelected,self.root,pad+154*sc,py+2*sc)
            local sy=py+29*sc;local bx=pad;for _,b in ipairs({self.trackEnable,self.trackPriorityDown,self.trackPriorityUp,self.trackAdvancedButton}) do b:SetExtent(78*sc,23*sc);S.UI:SetAnchor(b,self.root,bx,sy);bx=bx+84*sc end
            -- 高级选项：清空所有已追踪（危险，常驻显示，二次确认）；单项高级设置在选中后显示。
            local clearAllY=sy+28*sc
            if self.trackClearAll then self.trackClearAll:SetExtent(150*sc,26*sc);S.UI:SetAnchor(self.trackClearAll,self.root,pad,clearAllY) end
            local advY=clearAllY+34*sc
            for _,b in ipairs({self.trackAdvTime,self.trackAdvStack,self.trackAdvBorder,self.trackAdvTooltip,self.trackAdvExpire,self.trackAdvIconDown,self.trackAdvIconUp,self.trackAdvIconReset,self.trackNameApply}) do b:Show(advVisible and self.activeSection=="tracking") end
            if self.trackNameEdit then self.trackNameEdit:Show(advVisible and self.activeSection=="tracking") end
            if advVisible then local advButtons={self.trackAdvTime,self.trackAdvStack,self.trackAdvBorder,self.trackAdvTooltip,self.trackAdvExpire,self.trackAdvIconDown,self.trackAdvIconUp,self.trackAdvIconReset};local cols=4;local ag=5*sc;local aw=(full-ag*(cols-1))/cols;for i,b in ipairs(advButtons) do local rr=math.floor((i-1)/cols);local cc=(i-1)%cols;b:SetExtent(aw,23*sc);S.UI:SetAnchor(b,self.root,pad+cc*(aw+ag),advY+rr*27*sc) end;local nameY=advY+56*sc;if self.trackNameEdit then self.trackNameEdit:SetExtent(math.max(90*sc,full-78*sc),24*sc);S.UI:SetAnchor(self.trackNameEdit,self.root,pad,nameY) end;self.trackNameApply:SetExtent(72*sc,23*sc);S.UI:SetAnchor(self.trackNameApply,self.root,pad+full-72*sc,nameY) end
        elseif self.activeSection=="layout" then
            -- 外观布局现在是一张完整的 HUD 画布设置页：
            -- 目标/自身是 Scope，状态区域/整体/玩家信息/距离是同级视觉分组。
            -- 1024x768 下优先使用两列数值卡；更窄时自动退化为单列，避免文字省略和控件重叠。
            LayoutTabs(self.layoutScopeTabs,pad,top,math.min(full,230*sc),25*sc,gap)

            local groups={}
            for _,it in ipairs(self.layoutGroupTabs or {}) do
                if self.layoutScope=="target" or (it.value~="metadata" and it.value~="distance" and it.value~="cast") then groups[#groups+1]=it end
            end
            local groupY=top+31*sc
            local groupCols=(full>=360*sc) and #groups or math.min(2,#groups)
            local y=LayoutTabGrid(groups,pad,groupY,full,25*sc,gap,groupCols)+2*sc

            local mode=self.layoutGroup
            local numericCols=full>=620*sc and 2 or 1
            if mode=="effect" then
                LayoutTabs(self.layoutTypeTabs,pad,y,math.min(full,330*sc),25*sc,gap)
                y=y+31*sc
                y=LayoutNumericRows(self.layoutEffectRows,pad,y,full,sc,numericCols)
                local buttons={self.layoutDirection,self.layoutPreview,self.layoutDragAll,self.layoutDragPart,self.layoutStop,self.layoutReset,self.layoutCopy}
                local bcols=full>=560*sc and math.min(4,#buttons) or 2
                local bw=(full-gap*(bcols-1))/bcols
                for i,b in ipairs(buttons) do local rr=math.floor((i-1)/bcols);local cc=(i-1)%bcols;b:SetExtent(bw,25*sc);S.UI:SetAnchor(b,self.root,pad+cc*(bw+gap),y+4*sc+rr*30*sc) end
                local buttonRows=math.ceil(#buttons/bcols)
                self.layoutHint:SetExtent(full,34*sc);S.UI:SetAnchor(self.layoutHint,self.root,pad,y+8*sc+buttonRows*30*sc)
            elseif mode=="hud" then
                y=LayoutNumericRows(self.layoutBaseRows,pad,y,full,sc,numericCols)
                local buttons={self.layoutAnchor,self.layoutPreview,self.layoutDragAll,self.layoutStop,self.layoutCopy}
                local bcols=full>=560*sc and math.min(4,#buttons) or 2
                local bw=(full-gap*(bcols-1))/bcols
                for i,b in ipairs(buttons) do local rr=math.floor((i-1)/bcols);local cc=(i-1)%bcols;b:SetExtent(bw,25*sc);S.UI:SetAnchor(b,self.root,pad+cc*(bw+gap),y+4*sc+rr*30*sc) end
                local buttonRows=math.ceil(#buttons/bcols)
                local hintY=y+8*sc+buttonRows*30*sc
                self.layoutHint:SetExtent(full,34*sc);S.UI:SetAnchor(self.layoutHint,self.root,pad,hintY)
                if self.layoutScope=="player" then
                    y=hintY+38*sc
                    self.layoutEquipmentHint:SetExtent(full,34*sc);S.UI:SetAnchor(self.layoutEquipmentHint,self.root,pad,y)
                    y=y+38*sc
                    local cardCols=full>=620*sc and 3 or (full>=430*sc and 2 or 1)
                    y=LayoutControlCards(self.layoutEquipmentControls,pad,y,full,sc,cardCols)+4*sc
                    y=LayoutNumericRows(self.layoutEquipmentRows,pad,y,full,sc,numericCols)
                    self.layoutEquipmentDirection:SetExtent(math.min(180*sc,full),25*sc);S.UI:SetAnchor(self.layoutEquipmentDirection,self.root,pad,y+4*sc)
                end
            elseif mode=="metadata" and self.layoutScope=="target" then
                self.layoutMetadataHint:SetExtent(full,34*sc);S.UI:SetAnchor(self.layoutMetadataHint,self.root,pad,y)
                y=y+38*sc
                local cardCols=full>=620*sc and 3 or (full>=430*sc and 2 or 1)
                y=LayoutControlCards(self.layoutMetadataControls,pad,y,full,sc,cardCols)+4*sc
                y=LayoutNumericRows(self.layoutMetadataRows,pad,y,full,sc,numericCols)
                self.layoutPreview:SetExtent(math.min(150*sc,(full-gap)/2),25*sc);S.UI:SetAnchor(self.layoutPreview,self.root,pad,y+4*sc)
                self.layoutStop:SetExtent(math.min(150*sc,(full-gap)/2),25*sc);S.UI:SetAnchor(self.layoutStop,self.root,pad+math.min(156*sc,full/2),y+4*sc)
            elseif mode=="distance" and self.layoutScope=="target" then
                self.layoutDistanceHint:SetExtent(full,34*sc);S.UI:SetAnchor(self.layoutDistanceHint,self.root,pad,y)
                y=y+38*sc
                y=LayoutControlCards(self.layoutDistanceControls,pad,y,math.min(full,360*sc),sc,1)+4*sc
                y=LayoutNumericRows(self.layoutDistanceRows,pad,y,full,sc,numericCols)
                self.layoutPreview:SetExtent(math.min(150*sc,(full-gap)/2),25*sc);S.UI:SetAnchor(self.layoutPreview,self.root,pad,y+4*sc)
                self.layoutStop:SetExtent(math.min(150*sc,(full-gap)/2),25*sc);S.UI:SetAnchor(self.layoutStop,self.root,pad+math.min(156*sc,full/2),y+4*sc)
            elseif mode=="cast" and self.layoutScope=="target" then
                self.layoutCastHint:SetExtent(full,34*sc);S.UI:SetAnchor(self.layoutCastHint,self.root,pad,y)
                y=y+38*sc
                local cardCols=full>=620*sc and 4 or (full>=430*sc and 2 or 1)
                y=LayoutControlCards(self.layoutCastControls,pad,y,full,sc,cardCols)+4*sc
                y=LayoutNumericRows(self.layoutCastRows,pad,y,full,sc,numericCols)
                local bw=math.min(160*sc,(full-gap)/2)
                self.layoutDragPart:SetExtent(bw,25*sc);S.UI:SetAnchor(self.layoutDragPart,self.root,pad,y+4*sc)
                self.layoutStop:SetExtent(bw,25*sc);S.UI:SetAnchor(self.layoutStop,self.root,pad+bw+gap,y+4*sc)
            end
        elseif self.activeSection=="colors" then
            LayoutTabs(self.colorScopeTabs,pad,top,210*sc,25*sc,gap);LayoutTabs(self.colorTypeTabs,pad+220*sc,top,math.min(260*sc,full-220*sc),25*sc,gap)
            -- 2026-08-24 fix: watch_orange/watch_red are AddNumericControl rows
            -- (section .numerics: .title/.readout/.apply), but this branch only
            -- ran LayoutNumericRows (the OTHER shape: .label/.edit). Those rows
            -- were never laid out -> their widgets sat at (0,0) in the page
            -- corner ("应用" + "(米)" controls). Lay out section numerics via
            -- LayoutGenericSection first, then the RGBA/expire rows continue.
            local y = self:LayoutGenericSection("colors", top + 34*sc, 2) + 8*sc
            self.colorPreview:SetExtent(56*sc,30*sc);S.UI:SetAnchor(self.colorPreview,self.root,pad,y);self.colorValue:SetExtent(full-250*sc,20*sc);S.UI:SetAnchor(self.colorValue,self.root,pad+64*sc,y+5*sc);self.colorBorder:SetExtent(80*sc,25*sc);self.colorExpire:SetExtent(80*sc,25*sc);S.UI:SetAnchor(self.colorBorder,self.root,pad+full-168*sc,y+3*sc);S.UI:SetAnchor(self.colorExpire,self.root,pad+full-82*sc,y+3*sc);y=y+38*sc;y=LayoutNumericRows(self.numericRows.colors,pad,y,full,sc,full>=650*sc and 2 or 1);if self.colorHint then self.colorHint:SetExtent(full,34*sc);S.UI:SetAnchor(self.colorHint,self.root,pad,y);y=y+36*sc end;local styleButtons={self.colorToggleTime,self.colorToggleStack,self.colorToggleBorder,self.colorToggleTooltip,self.colorToggleExpire,self.colorRuleTarget,self.colorRuleClear};local compact=full<650*sc;local sbcols=compact and 3 or 4;local sbw=(full-gap*(sbcols-1))/sbcols;for i,b in ipairs(styleButtons) do local rr=math.floor((i-1)/sbcols);local cc=(i-1)%sbcols;b:SetExtent(sbw,23*sc);S.UI:SetAnchor(b,self.root,pad+cc*(sbw+gap),y+rr*27*sc) end;local sbrows=math.ceil(#styleButtons/sbcols);y=y+sbrows*27*sc+2*sc;if self.colorHexEdit then self.colorHexEdit:SetExtent(math.max(100*sc,full-82*sc),24*sc);S.UI:SetAnchor(self.colorHexEdit,self.root,pad,y) end;self.colorHexApply:SetExtent(76*sc,24*sc);S.UI:SetAnchor(self.colorHexApply,self.root,pad+full-76*sc,y);y=y+30*sc;local pw=(full-gap*7)/8;for i,b in ipairs(self.colorPresetButtons) do local row=math.floor((i-1)/8);local col=(i-1)%8;b:SetExtent(pw,22*sc);S.UI:SetAnchor(b,self.root,pad+col*(pw+gap),y+row*26*sc) end;y=y+56*sc;if self.colorPresetName then self.colorPresetName:SetExtent(130*sc,24*sc);S.UI:SetAnchor(self.colorPresetName,self.root,pad,y) end;self.colorPresetSave:SetExtent(94*sc,24*sc);S.UI:SetAnchor(self.colorPresetSave,self.root,pad+136*sc,y);self.customPrev:SetExtent(24*sc,22*sc);S.UI:SetAnchor(self.customPrev,self.root,pad+236*sc,y);local cx=pad+264*sc;local cw=math.max(54*sc,(full-264*sc-120*sc-gap*5)/6);for _,b in ipairs(self.customColorButtons) do b:SetExtent(cw,22*sc);S.UI:SetAnchor(b,self.root,cx,y);cx=cx+cw+gap end;self.customNext:SetExtent(24*sc,22*sc);S.UI:SetAnchor(self.customNext,self.root,pad+full-114*sc,y);self.customDelete:SetExtent(84*sc,22*sc);S.UI:SetAnchor(self.customDelete,self.root,pad+full-84*sc,y+26*sc)
        elseif self.activeSection=="transfer" then
            LayoutTabs(self.transferModeTabs,pad,top,math.min(full,560*sc),25*sc,gap)
            self.transferSummary:SetExtent(full,44*sc);S.UI:SetAnchor(self.transferSummary,self.root,pad,top+32*sc)
            local y=top+80*sc;local bottom=self.contentBottom or (y+190*sc)
            if self.transferEdit then self.transferEdit:SetExtent(full,math.max(92*sc,bottom-y-68*sc));S.UI:SetAnchor(self.transferEdit,self.root,pad,y) end
            local by=bottom-61*sc
            local row1={self.transferExport,self.transferCopyAll,self.transferCopyCurrent,self.transferChunkPrev,self.transferChunkNext};local bw1=(full-gap*4)/5;local x=pad
            for _,b in ipairs(row1) do b:SetExtent(bw1,27*sc);S.UI:SetAnchor(b,self.root,x,by);x=x+bw1+gap end
            local row2={self.transferPolicy,self.transferParse,self.transferConfirm,self.transferPreset};local bw2=(full-gap*3)/4;x=pad
            for _,b in ipairs(row2) do b:SetExtent(bw2,27*sc);S.UI:SetAnchor(b,self.root,x,by+32*sc);x=x+bw2+gap end
        elseif self.activeSection=="diag" then
            local y=self:LayoutGenericSection("diag",top,2);if self.diagReport then self.diagBuild:SetExtent(120*sc,27*sc);S.UI:SetAnchor(self.diagBuild,self.root,pad,y);y=y+32*sc;self.diagReport:SetExtent(full,math.max(80*sc,(self.contentBottom or y+120*sc)-y));S.UI:SetAnchor(self.diagReport,self.root,pad,y) end
        end
        self:Refresh();self:ApplySubVisibility()
    end
    S.UI.pages.plates=page;return page
end
