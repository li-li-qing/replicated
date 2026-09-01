------------------------------------------------------------------------
-- Replicated Suite - Blue Salt Bond / Resident Board floating widget
-- Author: Replicated
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S=ReplicatedSuite; S.BondWidget={}

function S.BondWidget.Create()
    local widget=S.WidgetBase:Create("bond","债券 / 居民板",S.Constants.Widget.bond); local win=widget.window
    local MAX_ROWS=18
    widget.page=1; widget.pageSize=10; widget.settingsOpen=false
    local settingsBtn=S.UI:CreateButton(widget.refs.titleBar,"bond_widget_settings","设置",0,2,58,22,8,false)
    local current=S.UI:CreateLabel(win,"bond_widget_current","当前大陆：--",12,0,230,22,11,"blue",ALIGN_LEFT)
    local capture=S.UI:CreateLabel(win,"bond_widget_capture","今日已记录：--",245,0,300,22,9,"muted",ALIGN_RIGHT)
    local hint=S.UI:CreateLabel(win,"bond_widget_hint","进入对应大陆可读取居民板的区域后，当天信息只记录一次",12,0,530,20,9,"muted",ALIGN_LEFT)

    local headerContinent=S.UI:CreateLabel(win,"bond_widget_header_continent","大陆",12,0,58,18,8,"muted",ALIGN_LEFT)
    local headerMaterial=S.UI:CreateLabel(win,"bond_widget_header_material","类型",72,0,84,18,8,"muted",ALIGN_LEFT)
    local headerQuantity=S.UI:CreateLabel(win,"bond_widget_header_quantity","数量",158,0,46,18,8,"muted",ALIGN_CENTER)
    local headerRequirement=S.UI:CreateLabel(win,"bond_widget_header_requirement","今日需求",206,0,210,18,8,"muted",ALIGN_LEFT)
    local headerStatus=S.UI:CreateLabel(win,"bond_widget_header_status","状态",420,0,62,18,8,"muted",ALIGN_CENTER)
    local headerBag=S.UI:CreateLabel(win,"bond_widget_header_bag","背包",486,0,52,18,8,"muted",ALIGN_RIGHT)

    local rows={}
    for i=1,MAX_ROWS do
        rows[i]={
            continent=S.UI:CreateLabel(win,"bond_widget_continent_"..i,"",12,0,58,22,9,"muted",ALIGN_LEFT),
            material=S.UI:CreateLabel(win,"bond_widget_material_"..i,"",72,0,84,22,9,nil,ALIGN_LEFT),
            quantity=S.UI:CreateLabel(win,"bond_widget_quantity_"..i,"",158,0,46,22,9,"blue",ALIGN_CENTER),
            requirement=S.UI:CreateLabel(win,"bond_widget_requirement_"..i,"",206,0,210,22,9,nil,ALIGN_LEFT),
            status=S.UI:CreateLabel(win,"bond_widget_status_"..i,"",420,0,62,22,9,"muted",ALIGN_CENTER),
            bag=S.UI:CreateLabel(win,"bond_widget_bag_"..i,"",486,0,52,22,9,"muted",ALIGN_RIGHT),
        }
        for _,c in pairs(rows[i]) do c:Show(false) end
    end
    local prev=S.UI:CreateButton(win,"bond_widget_prev","上一页",12,0,66,24,9,false)
    local pageLabel=S.UI:CreateLabel(win,"bond_widget_page","1/1",84,0,72,22,9,"muted",ALIGN_CENTER)
    local next=S.UI:CreateButton(win,"bond_widget_next","下一页",162,0,66,24,9,false)
    local printBtn=S.UI:CreateButton(win,"bond_widget_print","打印已记录",0,0,100,24,9,false)
    local mini=S.UI:CreateLabel(win,"bond_widget_mini","债券：西- 东- 原-",8,4,300,20,10,"blue",ALIGN_LEFT); mini:Show(false)

    ------------------------------------------------------------------------
    -- Bond settings window
    --
    -- IMPORTANT: this is deliberately a top-level window, not a child panel of
    -- the floating bond HUD.  ArcheRage can restore a child widget's visible
    -- state when its parent HUD is shown again; keeping settings in an
    -- independent window makes "open HUD" and "open settings" two explicit,
    -- separate actions.
    ------------------------------------------------------------------------
    local settingsWindow=CreateEmptyWindow(S.PhysicalId("bond_settings_window"),"UIParent")
    S.UI:TrySetUILayer(settingsWindow,"system")
    if settingsWindow.Enable~=nil then settingsWindow:Enable(true) end
    if settingsWindow.Clickable~=nil then settingsWindow:Clickable(true) end
    S.Theme:AddBorder(settingsWindow,false)
    S.Theme:AddGradientBackground(settingsWindow,"panel",nil)
    settingsWindow:Show(false)
    if type(S.UI.windows)=="table" then S.UI.windows.bondSettings=settingsWindow end

    local settingsHeader=S.UI:CreatePanel(settingsWindow,"bond_settings_header",1,1,418,30,"header")
    local settingsTitle=S.UI:CreateLabel(settingsHeader,"bond_settings_title","债券设置",10,4,330,22,14,nil,ALIGN_LEFT)
    local settingsClose=S.UI:CreateButton(settingsHeader,"bond_settings_close","X",382,3,28,24,10,false)
    local settingsIntro=S.UI:CreateLabel(settingsWindow,"bond_settings_intro","只调整债券列表的显示方式，不会删除今天已经记录的数据。",12,38,396,20,9,"muted",ALIGN_LEFT)

    local sortLabel=S.UI:CreateLabel(settingsWindow,"bond_settings_sort_label","列表排序",12,68,86,22,10,"blue",ALIGN_LEFT)
    local sortHint=S.UI:CreateLabel(settingsWindow,"bond_settings_sort_hint","先按什么分组显示",102,68,300,22,9,"muted",ALIGN_LEFT)
    local sortContinent=S.UI:CreateButton(settingsWindow,"bond_settings_sort_continent","按大陆排序",12,92,188,28,10,false)
    local sortQuantity=S.UI:CreateButton(settingsWindow,"bond_settings_sort_quantity","按数量排序",208,92,188,28,10,false)

    local typeLabel=S.UI:CreateLabel(settingsWindow,"bond_settings_type_label","显示哪些债券",12,132,120,22,10,"blue",ALIGN_LEFT)
    local filterButtons={
        q20=S.UI:CreateButton(settingsWindow,"bond_settings_filter_q20","20材料：开",12,156,92,28,9,false),
        q60=S.UI:CreateButton(settingsWindow,"bond_settings_filter_q60","60材料：开",110,156,92,28,9,false),
        q100=S.UI:CreateButton(settingsWindow,"bond_settings_filter_q100","100材料：开",208,156,92,28,9,false),
        auroria=S.UI:CreateButton(settingsWindow,"bond_settings_filter_auroria","原大陆：开",306,156,92,28,9,false),
    }

    local duplicateLabel=S.UI:CreateLabel(settingsWindow,"bond_settings_duplicate_label","遇到重复债券",12,196,120,22,10,"blue",ALIGN_LEFT)
    local duplicateHint=S.UI:CreateLabel(settingsWindow,"bond_settings_duplicate_hint","西/东大陆材料和数量完全相同时",138,196,264,22,9,"muted",ALIGN_LEFT)
    local duplicateKeep=S.UI:CreateButton(settingsWindow,"bond_settings_duplicate_keep","全部保留",12,220,188,28,10,false)
    local duplicateExclude=S.UI:CreateButton(settingsWindow,"bond_settings_duplicate_exclude","排除相同",208,220,188,28,10,false)

    local priorityLabel=S.UI:CreateLabel(settingsWindow,"bond_settings_priority_label","重复时保留",12,260,100,22,10,"blue",ALIGN_LEFT)
    local priorityHint=S.UI:CreateLabel(settingsWindow,"bond_settings_priority_hint","只在“排除相同”开启时生效",116,260,286,22,9,"muted",ALIGN_LEFT)
    local priorityWest=S.UI:CreateButton(settingsWindow,"bond_settings_priority_west","保留西大陆",12,284,188,28,10,false)
    local priorityEast=S.UI:CreateButton(settingsWindow,"bond_settings_priority_east","保留东大陆",208,284,188,28,10,false)
    local settingsFootHint=S.UI:CreateLabel(settingsWindow,"bond_settings_foot_hint","设置即时保存；刷新会重新读取居民板与三阶段。",12,320,210,20,9,"muted",ALIGN_LEFT)
    local settingsRefresh=S.UI:CreateButton(settingsWindow,"bond_settings_refresh","刷新数据",230,316,84,26,9,false)
    local settingsDone=S.UI:CreateButton(settingsWindow,"bond_settings_done","完成",322,316,76,26,9,false)

    local ApplySettingsLayout
    local function CloseSettingsWindow()
        widget.settingsOpen=false
        settingsWindow:Show(false)
    end
    local function GetDisplayEntries()
        local board=S.State.data.bondBoard or {}; local resident=S.Services and S.Services.Resident
        return resident and type(resident.GetDisplayBondEntries)=="function" and resident:GetDisplayBondEntries(board.entries or {}) or (board.entries or {})
    end

    local function SetCheckVisual(button,checked)
        if button==nil or type(button.rsButtonBgs)~="table" then return end
        local opacity=tonumber(S.State.ui.widgets.bond.opacity) or tonumber(S.State.settings.opacity) or 0.90
        local base=checked and {0.84,0.67,0.33,0.98} or {0.075,0.095,0.120,0.97}
        local hover=checked and {1.00,0.78,0.18,0.99} or {0.14,0.19,0.24,0.99}
        local colors={base,hover,{0.045,0.060,0.078,0.99},{0.050,0.052,0.058,0.70}}
        button.rsButtonBgColors=button.rsButtonBgColors or {}
        for i,drawable in ipairs(button.rsButtonBgs) do
            local c=colors[i]
            if c~=nil then
                button.rsButtonBgColors[i]={c[1],c[2],c[3],c[4]}
                if drawable~=nil and type(drawable.SetColor)=="function" then
                    pcall(function() drawable:SetColor(c[1],c[2],c[3],c[4]*opacity) end)
                end
            end
        end
    end

    local function RefreshSettingsControls()
        local resident=S.Services and S.Services.Resident
        local mode=resident and type(resident.GetBondSortMode)=="function" and resident:GetBondSortMode() or "continent"
        SetCheckVisual(sortContinent,mode=="continent")
        SetCheckVisual(sortQuantity,mode=="quantity")
        sortContinent:SetText("按大陆排序")
        sortQuantity:SetText("按数量排序")

        local filter=resident and type(resident.GetBondFilter)=="function" and resident:GetBondFilter()
            or {q20=true,q60=true,q100=true,auroria=true,excludeSame=false,priority="west"}
        local names={q20="20材料",q60="60材料",q100="100材料",auroria="原大陆"}
        for key,button in pairs(filterButtons) do
            local checked=filter[key]==true
            SetCheckVisual(button,checked)
            button:SetText(tostring(names[key] or key).."："..(checked and "开" or "关"))
        end

        local excludeSame=filter.excludeSame==true
        SetCheckVisual(duplicateKeep,not excludeSame)
        SetCheckVisual(duplicateExclude,excludeSame)
        duplicateKeep:SetText("全部保留")
        duplicateExclude:SetText("排除相同")

        local priority=tostring(filter.priority or "west")
        priorityLabel:Show(excludeSame)
        priorityHint:Show(excludeSame)
        priorityWest:Show(excludeSame)
        priorityEast:Show(excludeSame)
        SetCheckVisual(priorityWest,excludeSame and priority=="west")
        SetCheckVisual(priorityEast,excludeSame and priority=="east")
        priorityWest:SetText("保留西大陆")
        priorityEast:SetText("保留东大陆")
        if ApplySettingsLayout~=nil then ApplySettingsLayout(false) end
    end

    local function RefreshEverywhere()
        widget.page=1
        RefreshSettingsControls()
        widget:Refresh()
        if S.LifePage and S.LifePage.instance and type(S.LifePage.instance.Refresh)=="function" then S.LifePage.instance:Refresh() end
        local workspace=S.UI and S.UI.pages and S.UI.pages.life_bond
        if workspace~=nil and type(workspace.Refresh)=="function" then workspace:Refresh() end
    end

    local function SelectSortMode(mode)
        local resident=S.Services and S.Services.Resident
        if resident and type(resident.SetBondSortMode)=="function" then resident:SetBondSortMode(mode) end
        RefreshEverywhere()
    end

    local function ToggleFilter(key)
        local resident=S.Services and S.Services.Resident
        if resident and type(resident.ToggleBondFilterOption)=="function" then resident:ToggleBondFilterOption(key) end
        RefreshEverywhere()
    end

    local function SetDuplicateMode(excludeSame)
        local resident=S.Services and S.Services.Resident
        local filter=resident and type(resident.GetBondFilter)=="function" and resident:GetBondFilter() or {}
        if (filter.excludeSame==true)~=(excludeSame==true) and resident and type(resident.ToggleBondFilterOption)=="function" then
            resident:ToggleBondFilterOption("excludeSame")
        end
        RefreshEverywhere()
    end

    local function SelectDuplicatePriority(priority)
        local resident=S.Services and S.Services.Resident
        if resident and type(resident.SetBondDuplicatePriority)=="function" then resident:SetBondDuplicatePriority(priority) end
        RefreshEverywhere()
    end

    S.UI:SafeHandler(sortContinent,"OnClick",function() SelectSortMode("continent") end,"bond:sort:continent")
    S.UI:SafeHandler(sortQuantity,"OnClick",function() SelectSortMode("quantity") end,"bond:sort:quantity")
    for key,button in pairs(filterButtons) do
        local option=key
        S.UI:SafeHandler(button,"OnClick",function() ToggleFilter(option) end,"bond:filter:"..option)
    end
    S.UI:SafeHandler(duplicateKeep,"OnClick",function() SetDuplicateMode(false) end,"bond:duplicate:keep")
    S.UI:SafeHandler(duplicateExclude,"OnClick",function() SetDuplicateMode(true) end,"bond:duplicate:exclude")
    S.UI:SafeHandler(priorityWest,"OnClick",function() SelectDuplicatePriority("west") end,"bond:priority:west")
    S.UI:SafeHandler(priorityEast,"OnClick",function() SelectDuplicatePriority("east") end,"bond:priority:east")
    S.UI:SafeHandler(settingsClose,"OnClick",CloseSettingsWindow,"bond:settings_close")
    S.UI:SafeHandler(settingsRefresh,"OnClick",function()
        local resident=S.Services and S.Services.Resident
        if resident~=nil then
            if type(resident.Refresh)=="function" then resident:Refresh() end
            if type(resident.RefreshStages)=="function" then resident:RefreshStages() end
        end
        RefreshEverywhere()
    end,"bond:settings_refresh")
    S.UI:SafeHandler(settingsDone,"OnClick",CloseSettingsWindow,"bond:settings_done")
    if type(settingsHeader.EnableDrag)=="function" then settingsHeader:EnableDrag(true) end
    if type(settingsHeader.Clickable)=="function" then settingsHeader:Clickable(true) end
    S.UI:SafeHandler(settingsHeader,"OnDragStart",function()
        settingsHeader.rsSafeMoving=S.Layout~=nil and type(S.Layout.BeginSafeMove)=="function" and S.Layout:BeginSafeMove("bond_settings",settingsWindow,{clamp=true})==true
        if settingsHeader.rsSafeMoving==true then return true end
        if type(settingsWindow.StartMoving)~="function" then return false end
        settingsWindow:StartMoving(); return true
    end,"bond:settings_drag_start")
    S.UI:SafeHandler(settingsHeader,"OnDragStop",function()
        if settingsHeader.rsSafeMoving==true and S.Layout~=nil and type(S.Layout.EndSafeMove)=="function" then S.Layout:EndSafeMove("bond_settings",false)
        elseif type(settingsWindow.StopMovingOrSizing)=="function" then settingsWindow:StopMovingOrSizing() end
        settingsHeader.rsSafeMoving=false
        if S.Layout~=nil then S.Layout:EnsureWidgetVisible(settingsWindow,{onlyWhenVisible=false}) end
        return true
    end,"bond:settings_drag_stop")

    S.UI:SafeHandler(prev,"OnClick",function() widget.page=math.max(1,widget.page-1); widget:Refresh() end,"bond:prev")
    S.UI:SafeHandler(next,"OnClick",function() local entries=GetDisplayEntries(); local pages=math.max(1,math.ceil(#entries/widget.pageSize)); widget.page=math.min(pages,widget.page+1); widget:Refresh() end,"bond:next")
    if win.EnableScroll ~= nil then pcall(function() win:EnableScroll(true) end) end
    S.UI:SafeHandler(win,"OnWheelUp",function() widget.page=math.max(1,widget.page-1); widget:Refresh() end,"bond:wheel_up")
    S.UI:SafeHandler(win,"OnWheelDown",function() local entries=GetDisplayEntries(); local pages=math.max(1,math.ceil(#entries/widget.pageSize)); widget.page=math.min(pages,widget.page+1); widget:Refresh() end,"bond:wheel_down")
    S.UI:SafeHandler(printBtn,"OnClick",function() if S.Services and S.Services.Resident then S.Services.Resident:PrintFull() end end,"bond:print")
    local function OpenSettingsWindow()
        local placement=S.State.ui.widgets.bond
        if placement.mode~="standard" then placement.mode="standard" end
        widget.settingsLaunchPending=true
        widget:SetVisible(true)
        widget.settingsLaunchPending=false
        widget.settingsOpen=true
        RefreshSettingsControls()
        if ApplySettingsLayout~=nil then ApplySettingsLayout(true) end
        settingsWindow:Show(true)
        if settingsWindow.Raise~=nil then pcall(function() settingsWindow:Raise() end) end
        S.Storage:RequestSave()
    end

    S.UI:SafeHandler(settingsBtn,"OnClick",function()
        if widget.settingsOpen==true and settingsWindow:IsVisible() then CloseSettingsWindow() else OpenSettingsWindow() end
    end,"bond:settings_toggle")

    function widget:OpenSettingsPanel()
        OpenSettingsWindow()
    end

    function widget:OnEffectiveVisibilityChanged(visible)
        -- A normal HUD open must never imply "open settings".  The only path
        -- allowed to keep/open the settings window is OpenSettingsWindow(),
        -- which marks the visibility transition explicitly.
        if visible~=true or self.settingsLaunchPending~=true then
            CloseSettingsWindow()
        end
    end

    function widget:Refresh()
        local board=S.State.data.bondBoard or {}
        local entries=GetDisplayEntries()
        local cached=board.continents or {}
        settingsBtn:SetText("设置")
        RefreshSettingsControls()
        local continentLabel = board.currentContinent == "west" and "西大陆" or board.currentContinent == "east" and "东大陆" or board.currentContinent == "auroria" and "原大陆" or "--"
        current:SetText("当前大陆："..continentLabel)
        local marks={ cached.west and "西大陆已" or "西大陆未", cached.east and "东大陆已" or "东大陆未", cached.auroria and "原大陆已" or "原大陆未" }
        capture:SetText("今日已记录："..table.concat(marks,"  "))
        if board.error then hint:SetText(tostring(board.error)) else
            local active={}
            for _,stage in ipairs(S.State.data.residentStages or {}) do if stage.zoneId~=nil then active[#active+1]=tostring(stage.name).."="..tostring(stage.status) end end
            hint:SetText(#active>0 and ("三阶段："..table.concat(active," · ")) or "已=债券任务已完成，未=未完成；当前未发现居民3阶段")
        end

        local pages=math.max(1,math.ceil(#entries/self.pageSize)); self.page=math.max(1,math.min(self.page,pages)); pageLabel:SetText(tostring(self.page).."/"..tostring(pages))
        local pagerVisible=S.State.ui.widgets.bond.mode=="standard" and pages>1
        prev:Show(pagerVisible); pageLabel:Show(pagerVisible); next:Show(pagerVisible)
        if prev.Enable then prev:Enable(pagerVisible and self.page>1) end
        if next.Enable then next:Enable(pagerVisible and self.page<pages) end
        for i,w in ipairs(rows) do
            local index=(self.page-1)*self.pageSize+i; local r=entries[index]; local show=r~=nil and S.State.ui.widgets.bond.mode=="standard" and i<=self.pageSize
            local showRequirement=show and self.showRequirementColumn==true
            w.continent:Show(show); w.material:Show(show); w.quantity:Show(show); w.requirement:Show(showRequirement); w.status:Show(show); w.bag:Show(show)
            if show then
                local bagCount=(r.materialKey~=nil and board.materials and board.materials[r.materialKey]) or nil
                w.continent:SetText(tostring(r.continentLabel or "--"))
                w.material:SetText(tostring(r.material or "--"))
                w.quantity:SetText(tonumber(r.quantity) and tostring(math.floor(tonumber(r.quantity))) or "--")
                w.requirement:SetText(tostring(r.text or "--"))
                local statusText=r.questId~=nil and (r.completed==true and "已完成" or "未完成") or tostring(r.status or "--")
                w.status:SetText(statusText); S.Theme:SetLabelTone(w.status,r.tone or (r.completed==true and "green" or "red"))
                w.bag:SetText(bagCount~=nil and tostring(math.floor(tonumber(bagCount) or 0)) or "--")
                S.Theme:SetLabelTone(w.bag,bagCount~=nil and "blue" or "muted")
            end
        end
        mini:SetText("债券："..table.concat({cached.west and "西已" or "西-", cached.east and "东已" or "东-", cached.auroria and "原已" or "原-"},"  "))
    end

    ApplySettingsLayout=function(centerOnScreen)
        local scale=S.Layout:GetContext().addonScale
        local resident=S.Services and S.Services.Resident
        local filter=resident and type(resident.GetBondFilter)=="function" and resident:GetBondFilter() or {}
        local hasPriority=filter.excludeSame==true
        local width=420*scale
        local height=(hasPriority and 352 or 306)*scale
        settingsWindow:SetExtent(width,height)
        settingsHeader:SetExtent(width-2,30*scale)
        settingsTitle:SetExtent(width-78*scale,22*scale)
        settingsClose:SetExtent(28*scale,24*scale); S.UI:SetAnchor(settingsClose,settingsHeader,width-36*scale,3*scale)
        settingsIntro:SetExtent(width-24*scale,20*scale); S.UI:SetAnchor(settingsIntro,settingsWindow,12*scale,38*scale)

        sortLabel:SetExtent(86*scale,22*scale); S.UI:SetAnchor(sortLabel,settingsWindow,12*scale,68*scale)
        sortHint:SetExtent(width-114*scale,22*scale); S.UI:SetAnchor(sortHint,settingsWindow,102*scale,68*scale)
        sortContinent:SetExtent(188*scale,28*scale); S.UI:SetAnchor(sortContinent,settingsWindow,12*scale,92*scale)
        sortQuantity:SetExtent(188*scale,28*scale); S.UI:SetAnchor(sortQuantity,settingsWindow,208*scale,92*scale)

        typeLabel:SetExtent(120*scale,22*scale); S.UI:SetAnchor(typeLabel,settingsWindow,12*scale,132*scale)
        local filterW=92*scale
        local filterXs={12,110,208,306}
        for index,key in ipairs({"q20","q60","q100","auroria"}) do
            local button=filterButtons[key]
            button:SetExtent(filterW,28*scale); S.UI:SetAnchor(button,settingsWindow,filterXs[index]*scale,156*scale)
        end

        duplicateLabel:SetExtent(120*scale,22*scale); S.UI:SetAnchor(duplicateLabel,settingsWindow,12*scale,196*scale)
        duplicateHint:SetExtent(width-150*scale,22*scale); S.UI:SetAnchor(duplicateHint,settingsWindow,138*scale,196*scale)
        duplicateKeep:SetExtent(188*scale,28*scale); S.UI:SetAnchor(duplicateKeep,settingsWindow,12*scale,220*scale)
        duplicateExclude:SetExtent(188*scale,28*scale); S.UI:SetAnchor(duplicateExclude,settingsWindow,208*scale,220*scale)

        if hasPriority then
            priorityLabel:SetExtent(100*scale,22*scale); S.UI:SetAnchor(priorityLabel,settingsWindow,12*scale,260*scale)
            priorityHint:SetExtent(width-128*scale,22*scale); S.UI:SetAnchor(priorityHint,settingsWindow,116*scale,260*scale)
            priorityWest:SetExtent(188*scale,28*scale); S.UI:SetAnchor(priorityWest,settingsWindow,12*scale,284*scale)
            priorityEast:SetExtent(188*scale,28*scale); S.UI:SetAnchor(priorityEast,settingsWindow,208*scale,284*scale)
        end
        local footerY=(hasPriority and 322 or 276)*scale
        settingsFootHint:SetExtent(width-210*scale,20*scale); S.UI:SetAnchor(settingsFootHint,settingsWindow,12*scale,footerY+2*scale)
        settingsRefresh:SetExtent(84*scale,26*scale); S.UI:SetAnchor(settingsRefresh,settingsWindow,width-190*scale,footerY)
        settingsDone:SetExtent(76*scale,26*scale); S.UI:SetAnchor(settingsDone,settingsWindow,width-98*scale,footerY)

        local opacity=tonumber(S.State.ui.widgets.bond.opacity) or tonumber(S.State.settings.opacity) or 0.90
        S.Theme:SetBackgroundOpacity(settingsWindow,opacity)
        for _,button in ipairs({sortContinent,sortQuantity,filterButtons.q20,filterButtons.q60,filterButtons.q100,filterButtons.auroria,duplicateKeep,duplicateExclude,priorityWest,priorityEast,settingsRefresh,settingsDone,settingsClose}) do
            S.Theme:SetBackgroundOpacity(button,opacity)
        end

        if centerOnScreen==true or settingsWindow:IsVisible()~=true then
            local ctx=S.Layout:GetContext()
            local x=math.max(ctx.safeLeft,(ctx.logicalWidth-width)/2)
            local y=math.max(ctx.safeTop,(ctx.logicalHeight-height)/2)
            if settingsWindow.RemoveAllAnchors~=nil then settingsWindow:RemoveAllAnchors() end
            settingsWindow:AddAnchor("TOPLEFT","UIParent",x,y)
        end
        if settingsWindow.CorrectOffsetByScreen~=nil then pcall(function() settingsWindow:CorrectOffsetByScreen() end) end
    end

    widget.OnLayout=function(self,width,height,titleHeight,mode)
        local scale=S.Layout:GetContext().addonScale; local standard=mode=="standard"; local miniMode=mode=="mini"
        if not standard then self.settingsOpen=false end
        local layoutPages=math.max(1,math.ceil(#GetDisplayEntries()/self.pageSize))
        local pagerVisible=standard and layoutPages>1
        self.refs.titleBar:Show(true); settingsBtn:Show(standard); current:Show(standard); capture:Show(standard); hint:Show(standard); prev:Show(pagerVisible); pageLabel:Show(pagerVisible); next:Show(pagerVisible); printBtn:Show(standard); mini:Show(miniMode)
        for _,header in ipairs({headerContinent,headerMaterial,headerQuantity,headerRequirement,headerStatus,headerBag}) do header:Show(standard) end
        if prev.Enable then prev:Enable(pagerVisible and self.page>1) end
        if next.Enable then next:Enable(pagerVisible and self.page<layoutPages) end
        if standard then
            -- One bond-specific title action keeps the title bar readable and
            -- avoids exposing separate sort/filter interaction models.
            self.refs.titleLabel:SetExtent(96*scale,math.max(12*scale,titleHeight-4*scale))
            settingsBtn:SetExtent(58*scale,22*scale); S.UI:SetAnchor(settingsBtn,self.refs.titleBar,104*scale,math.max(1*scale,(titleHeight-22*scale)/2))

        end
        if miniMode then mini:SetExtent(width-16*scale,math.max(18*scale,height-titleHeight-8*scale)); S.UI:SetAnchor(mini,win,8*scale,titleHeight+3*scale) end
        if standard then
            current:SetExtent(width*0.38,22*scale); capture:SetExtent(width*0.55,22*scale)
            S.UI:SetAnchor(current,win,12*scale,titleHeight+7*scale); S.UI:SetAnchor(capture,win,width*0.42,titleHeight+7*scale)
            hint:SetExtent(width-24*scale,20*scale); S.UI:SetAnchor(hint,win,12*scale,titleHeight+31*scale)

            local headerY=titleHeight+53*scale
            local rowStart=headerY+21*scale; local footerH=31*scale; local rowH=27*scale
            local maxFit=math.max(1,math.min(#rows,math.floor((height-rowStart-footerH)/rowH))); self.pageSize=maxFit
            layoutPages=math.max(1,math.ceil(#GetDisplayEntries()/self.pageSize))
            self.page=math.max(1,math.min(self.page,layoutPages))
            pagerVisible=layoutPages>1
            prev:Show(pagerVisible); pageLabel:Show(pagerVisible); next:Show(pagerVisible)
            if prev.Enable then prev:Enable(pagerVisible and self.page>1) end
            if next.Enable then next:Enable(pagerVisible and self.page<layoutPages) end
            local left=12*scale; local right=width-12*scale; local total=math.max(1,right-left)
            self.showRequirementColumn=total>=500*scale
            local continentW=math.min(74*scale,math.max(52*scale,total*0.12))
            local quantityW=math.min(54*scale,math.max(42*scale,total*0.08))
            local statusW=math.min(72*scale,math.max(56*scale,total*0.11))
            local bagW=math.min(58*scale,math.max(46*scale,total*0.09))
            local gap=5*scale
            local requirementW=self.showRequirementColumn and math.min(210*scale,math.max(100*scale,total*0.32)) or 0
            local materialW=math.max(50*scale,total-continentW-quantityW-statusW-bagW-requirementW-gap*(self.showRequirementColumn and 5 or 4))
            local xContinent=left
            local xMaterial=xContinent+continentW+gap
            local xQuantity=xMaterial+materialW+gap
            local xRequirement=xQuantity+quantityW+gap
            local xStatus=(self.showRequirementColumn and (xRequirement+requirementW+gap) or xRequirement)
            local xBag=xStatus+statusW+gap

            headerContinent:SetExtent(continentW,18*scale); headerMaterial:SetExtent(materialW,18*scale); headerQuantity:SetExtent(quantityW,18*scale); headerRequirement:SetExtent(requirementW,18*scale); headerStatus:SetExtent(statusW,18*scale); headerBag:SetExtent(bagW,18*scale)
            S.UI:SetAnchor(headerContinent,win,xContinent,headerY); S.UI:SetAnchor(headerMaterial,win,xMaterial,headerY); S.UI:SetAnchor(headerQuantity,win,xQuantity,headerY); S.UI:SetAnchor(headerRequirement,win,xRequirement,headerY); S.UI:SetAnchor(headerStatus,win,xStatus,headerY); S.UI:SetAnchor(headerBag,win,xBag,headerY)
            headerRequirement:Show(self.showRequirementColumn)

            for i,w in ipairs(rows) do
                local y=rowStart+(i-1)*rowH
                w.continent:SetExtent(continentW,22*scale); w.material:SetExtent(materialW,22*scale); w.quantity:SetExtent(quantityW,22*scale); w.requirement:SetExtent(requirementW,22*scale); w.status:SetExtent(statusW,22*scale); w.bag:SetExtent(bagW,22*scale)
                S.UI:SetAnchor(w.continent,win,xContinent,y); S.UI:SetAnchor(w.material,win,xMaterial,y); S.UI:SetAnchor(w.quantity,win,xQuantity,y); S.UI:SetAnchor(w.requirement,win,xRequirement,y); S.UI:SetAnchor(w.status,win,xStatus,y); S.UI:SetAnchor(w.bag,win,xBag,y)
                if i>maxFit then for _,c in pairs(w) do c:Show(false) end end
            end
            local fy=height-28*scale; prev:SetExtent(66*scale,24*scale); pageLabel:SetExtent(72*scale,22*scale); next:SetExtent(66*scale,24*scale); printBtn:SetExtent(100*scale,24*scale)
            S.UI:SetAnchor(prev,win,12*scale,fy); S.UI:SetAnchor(pageLabel,win,84*scale,fy+1*scale); S.UI:SetAnchor(next,win,162*scale,fy); S.UI:SetAnchor(printBtn,win,width-112*scale,fy)
        else
            for _,header in ipairs({headerContinent,headerMaterial,headerQuantity,headerRequirement,headerStatus,headerBag}) do header:Show(false) end
            for _,w in ipairs(rows) do for _,c in pairs(w) do c:Show(false) end end
        end
        self:Refresh()
    end
    widget:ApplyLayout(false)
    if S.Layout~=nil and type(S.Layout.RegisterFloating)=="function" then
        S.Layout:RegisterFloating("bond_settings",settingsWindow,{onlyWhenVisible=true,ensureNow=false,onMetricsChanged=function(changed) if changed==true and ApplySettingsLayout~=nil then ApplySettingsLayout(true) else S.Layout:EnsureWidgetVisible(settingsWindow,{onlyWhenVisible=true}) end end})
    end
    return widget
end
