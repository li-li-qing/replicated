------------------------------------------------------------------------
-- Replicated Suite - Global Settings
--
-- Only Suite-wide presentation/runtime preferences live here. Feature-owned
-- settings belong to their feature page; HUD appearance belongs to HUD Manager.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
S.SettingsPage = {}

local function NextOption(list,current)
    local values=list or {}; if #values==0 then return current end
    local index=1
    for i,value in ipairs(values) do if tostring(value)==tostring(current) or tonumber(value)==tonumber(current) then index=i break end end
    index=index+1; if index>#values then index=1 end
    return values[index]
end

local function OpenPage(id)
    if S.UI and type(S.UI.ShowPage)=="function" then return S.UI:ShowPage(id)==true end
    return false
end

function S.SettingsPage.Create(parent)
    local page={key="settings",root=S.UI:CreatePanel(parent,"settings_page",0,0,100,100,"soft"),scaleButtons={}}
    if page.root.rsBorder and page.root.rsBorder.SetVisible then page.root.rsBorder:SetVisible(false) end
    if page.root.rsBackground and page.root.rsBackground.SetVisible then page.root.rsBackground:SetVisible(false) end

    page.title=S.UI:CreateLabel(page.root,"settings_title","全局设置",12,10,320,28,16,nil,ALIGN_LEFT)
    page.noteTop=S.UI:CreateLabel(page.root,"settings_note_top","这里只保留 Suite 全局行为。跑商、活动、任务等设置已经回到各自功能页面；悬浮窗外观统一由“悬浮窗管理”负责。",12,40,780,24,9,"muted",ALIGN_LEFT)

    page.scaleLabel=S.UI:CreateLabel(page.root,"settings_scale_label","整体 UI 缩放",12,78,120,24,11,nil,ALIGN_LEFT)
    page.scaleValue=S.UI:CreateLabel(page.root,"settings_scale_value","100%",140,78,70,24,11,"blue",ALIGN_RIGHT)
    for i,scale in ipairs(S.Constants.ScaleOptions) do
        local b=S.UI:CreateButton(page.root,"settings_scale_"..i,tostring(math.floor(scale*100+0.5)).."%",12+(i-1)*66,106,60,27,9,false)
        page.scaleButtons[i]={button=b,scale=scale}
        S.UI:SafeHandler(b,"OnClick",function()
            S.State.settings.addonScale=scale
            S.Layout:Invalidate(); S.Layout:GetContext(true); S.UI:ApplyResponsiveLayout(true); page:Refresh(); S.Storage:RequestSave()
        end,"settings:scale:"..i)
    end

    page.fontSize=S.UI:CreateButton(page.root,"settings_font_size","字体大小：120%",12,150,170,28,9,false)
    page.opacity=S.UI:CreateButton(page.root,"settings_opacity","整窗透明：90%",190,150,170,28,9,false)
    page.contentOpacity=S.UI:CreateButton(page.root,"settings_content_opacity","内容背景：100%",368,150,170,28,9,false)
    page.startPage=S.UI:CreateButton(page.root,"settings_start_page","启动页：首页",546,150,150,28,9,false)

    S.UI:SafeHandler(page.fontSize,"OnClick",function()
        S.State.settings.fontScale=NextOption(S.Constants.FontScaleOptions,S.State.settings.fontScale)
        S.Theme:RefreshTypography(); S.UI:ApplyResponsiveLayout(false); page:Refresh(); S.Storage:RequestSave()
    end,"settings:font_size")
    S.UI:SafeHandler(page.opacity,"OnClick",function()
        S.State.settings.opacity=NextOption({1.00,0.90,0.80,0.70,0.60,0.50,0.40,0.35},tonumber(S.State.settings.opacity) or 0.90)
        S.UI:ApplyResponsiveLayout(false); page:Refresh(); S.Storage:RequestSave()
    end,"settings:opacity")
    S.UI:SafeHandler(page.contentOpacity,"OnClick",function()
        S.State.settings.contentOpacity=NextOption({1.00,0.85,0.70,0.55,0.40,0.25,0.10,0.00},tonumber(S.State.settings.contentOpacity) or 1.00)
        S.UI:ApplyResponsiveLayout(false); page:Refresh(); S.Storage:RequestSave()
    end,"settings:content_opacity")
    S.UI:SafeHandler(page.startPage,"OnClick",function()
        local options=S.UICatalog and S.UICatalog:GetStartPages() or {"life","last"}
        local current=tostring(S.State.settings.defaultStartPage or "life")
        if S.UICatalog then current=S.UICatalog:NormalizePage(current) end
        local idx=1; for i,v in ipairs(options) do if v==current then idx=i break end end
        idx=idx+1; if idx>#options then idx=1 end
        S.State.settings.defaultStartPage=options[idx]; page:Refresh(); S.Storage:RequestSave()
    end,"settings:start_page")

    page.runtimeTitle=S.UI:CreateLabel(page.root,"settings_runtime_title","全局运行",12,204,160,24,12,nil,ALIGN_LEFT)
    page.dataRefresh=S.UI:CreateButton(page.root,"settings_data_refresh","数据刷新：15秒",12,234,170,28,9,false)
    page.refreshNow=S.UI:CreateButton(page.root,"settings_refresh_now","立即刷新全部数据",190,234,170,28,9,false)
    page.entryLock=S.UI:CreateButton(page.root,"settings_entry_lock","主入口：可拖动",368,234,170,28,9,false)
    page.mainLock=S.UI:CreateButton(page.root,"settings_main_lock","主面板：可拖动",546,234,150,28,9,false)
    S.UI:SafeHandler(page.dataRefresh,"OnClick",function()
        S.State.settings.dataRefreshMs=NextOption(S.Constants.DataRefreshOptionsMs,S.State.settings.dataRefreshMs)
        if S.Runtime and S.Runtime.ApplyRefreshSettings then S.Runtime:ApplyRefreshSettings() end
        page:Refresh(); S.Storage:RequestSave()
    end,"settings:data_refresh")
    S.UI:SafeHandler(page.refreshNow,"OnClick",function()
        if S.Runtime and S.Runtime.RefreshAll then S.Runtime:RefreshAll(true,true) end
    end,"settings:refresh_now")
    S.UI:SafeHandler(page.entryLock,"OnClick",function()
        S.State.settings.entryLocked=not (S.State.settings.entryLocked==true); page:Refresh(); S.Storage:RequestSave()
    end,"settings:entry_lock")
    S.UI:SafeHandler(page.mainLock,"OnClick",function()
        S.State.settings.mainLocked=not (S.State.settings.mainLocked==true); page:Refresh(); if S.MainWindow then S.MainWindow:RefreshChrome() end; S.Storage:RequestSave()
    end,"settings:main_lock")

    page.manageTitle=S.UI:CreateLabel(page.root,"settings_manage_title","管理入口",12,290,160,24,12,nil,ALIGN_LEFT)
    page.openHud=S.UI:CreateButton(page.root,"settings_open_hud","悬浮窗管理",12,320,160,28,9,false)
    page.openModules=S.UI:CreateButton(page.root,"settings_open_modules","功能开关 / 方案",180,320,160,28,9,false)
    page.openTools=S.UI:CreateButton(page.root,"settings_open_tools","实用工具",348,320,160,28,9,false)
    page.openDiagnostics=S.UI:CreateButton(page.root,"settings_open_diagnostics","诊断与维护",516,320,160,28,9,false)
    S.UI:SafeHandler(page.openHud,"OnClick",function() OpenPage("hud") end,"settings:open_hud")
    S.UI:SafeHandler(page.openModules,"OnClick",function() OpenPage("modules") end,"settings:open_modules")
    S.UI:SafeHandler(page.openTools,"OnClick",function() OpenPage("quick") end,"settings:open_tools")
    S.UI:SafeHandler(page.openDiagnostics,"OnClick",function() OpenPage("diagnostics") end,"settings:open_diagnostics")

    page.maintenanceTitle=S.UI:CreateLabel(page.root,"settings_maintenance_title","维护",12,378,160,24,12,nil,ALIGN_LEFT)
    page.reloadAll=S.UI:CreateButton(page.root,"settings_reload_all","刷新数据 / UI",12,408,160,28,9,false)
    page.reloadCode=S.UI:CreateButton(page.root,"settings_reload_code","重载插件代码",180,408,160,28,9,false)
    page.restore=S.UI:CreateButton(page.root,"settings_restore","恢复默认布局 / 大小",348,408,160,28,9,false)
    page.factoryReset=S.UI:CreateButton(page.root,"settings_factory_reset","恢复全部默认设置",516,408,160,28,9,false)
    page.note=S.UI:CreateLabel(page.root,"settings_note","“恢复默认布局”只重置窗口位置/大小；“恢复全部默认设置”会清空 Suite 与专业模块保存数据。",12,446,760,28,9,"muted",ALIGN_LEFT)

    S.UI:SafeHandler(page.reloadAll,"OnClick",function()
        if type(S.SafeSuiteRefresh)=="function" then S.SafeSuiteRefresh("settings")
        elseif type(S.ForceUiReload)=="function" then S.ForceUiReload("settings")
        else S.SafeChat("刷新失败：Suite 内部刷新函数不可用。") end
    end,"settings:reload_all")
    S.UI:SafeHandler(page.reloadCode,"OnClick",function()
        if type(S.ReloadCodeFromDisk)=="function" then S.ReloadCodeFromDisk("settings") else S.SafeChat("重载失败：代码重载入口不可用。") end
    end,"settings:reload_code")

    S.UI:SafeHandler(page.restore,"OnClick",function()
        local now=S.NowMs and S.NowMs() or 0
        if now-(tonumber(page.restoreArmedAt) or 0)>5000 then
            page.restoreArmedAt=now; page.restore:SetText("再次点击确认恢复")
            if S.Scheduler and type(S.Scheduler.AddTask)=="function" then
                S.Scheduler:RemoveTask("settings_restore_confirm_expire")
                S.Scheduler:AddTask("settings_restore_confirm_expire",5100,function()
                    S.Scheduler:RemoveTask("settings_restore_confirm_expire")
                    if (S.NowMs and S.NowMs() or 0)-(tonumber(page.restoreArmedAt) or 0)>=5000 then page.restoreArmedAt=0; if page.restore and page.restore.SetText then page.restore:SetText("恢复默认布局 / 大小") end end
                end,false,page,"P5")
            end
            S.SafeChat("恢复默认布局会重置主窗口和全部 HUD 的位置/大小；5秒内再次点击确认。")
            return
        end
        page.restoreArmedAt=0
        S.State.ui.entry.anchorH,S.State.ui.entry.anchorV,S.State.ui.entry.offsetX,S.State.ui.entry.offsetY="LEFT","TOP",16,170
        S.State.ui.main.anchorH,S.State.ui.main.anchorV,S.State.ui.main.offsetX,S.State.ui.main.offsetY="LEFT","TOP",95,105
        S.State.ui.main.width,S.State.ui.main.height,S.State.ui.main.collapsed=nil,nil,false
        local defaults={task={16,80},trade={16,120},bond={16,160},event={16,200},treasure={16,240},fishing={16,280}}
        for n,v in pairs(defaults) do
            local pos=S.State.ui.widgets[n]
            if type(pos)=="table" then
                pos.anchorH,pos.anchorV,pos.offsetX,pos.offsetY="RIGHT","TOP",v[1],v[2]
                pos.width,pos.height,pos.opacity,pos.userMoved=nil,nil,nil,false
            end
        end
        if S.HudManager and type(S.HudManager.List)=="function" then
            for _,hud in ipairs(S.HudManager:List()) do
                if hud and hud.id then
                    if type(S.HudManager.ResetPosition)=="function" then S.HudManager:ResetPosition(hud.id) end
                    if hud.supportsResize~=false and type(S.HudManager.ResetSize)=="function" then S.HudManager:ResetSize(hud.id) end
                end
            end
        end
        S.UI:ApplyResponsiveLayout(true); S.Storage:RequestSave(0); page:Refresh()
    end,"settings:restore")

    S.UI:SafeHandler(page.factoryReset,"OnClick",function()
        local now=S.NowMs and S.NowMs() or 0
        if now-(tonumber(page.factoryResetArmedAt) or 0)>8000 then
            page.factoryResetArmedAt=now; page.factoryReset:SetText("再次点击确认全部重置")
            if S.Scheduler and type(S.Scheduler.AddTask)=="function" then
                S.Scheduler:RemoveTask("settings_factory_reset_confirm_expire")
                S.Scheduler:AddTask("settings_factory_reset_confirm_expire",8100,function()
                    S.Scheduler:RemoveTask("settings_factory_reset_confirm_expire")
                    if (S.NowMs and S.NowMs() or 0)-(tonumber(page.factoryResetArmedAt) or 0)>=8000 then page.factoryResetArmedAt=0; if page.factoryReset and page.factoryReset.SetText then page.factoryReset:SetText("恢复全部默认设置") end end
                end,false,page,"P5")
            end
            S.SafeChat("警告：这会清空 Suite、HUD、换装方案、治疗设置、BUFF追踪/布局、DPS配置/规则/统计等全部保存数据。8秒内再次点击确认。")
            return
        end
        page.factoryResetArmedAt=0; page.factoryReset:SetText("正在清空全部配置")
        local ok,summary=false,nil
        if S.Storage and type(S.Storage.ResetAllPersistedData)=="function" then ok,summary=S.Storage:ResetAllPersistedData() else summary={error="Storage 出厂重置入口不可用"} end
        if ok~=true then
            local detail=type(summary)=="table" and summary.error or summary
            S.SafeChat("恢复全部默认设置失败，未重新载入："..tostring(detail or "unknown")); page.factoryReset:SetText("恢复全部默认设置"); return
        end
        local count=type(summary)=="table" and tonumber(summary.cleared) or nil
        S.SafeChat("已清空"..tostring(count or 0).."个保存槽，正在以首次安装状态重新载入。")
        if type(S.ReloadCodeFromDisk)=="function" then
            local reloadOk=S.ReloadCodeFromDisk("factory_reset")
            if reloadOk~=true then S.SafeChat("保存数据已清空，但自动重载失败；当前会话保持写保护，请重新登录或手动重载。"); page.factoryReset:SetText("已清空，等待重载") end
        else
            S.SafeChat("保存数据已清空，但重载入口不可用；请重新登录后继续测试。"); page.factoryReset:SetText("已清空，等待重载")
        end
    end,"settings:factory_reset")

    function page:Refresh()
        local now=S.NowMs and S.NowMs() or 0
        if now-(tonumber(self.restoreArmedAt) or 0)>5000 then self.restoreArmedAt=0 end
        if now-(tonumber(self.factoryResetArmedAt) or 0)>8000 then self.factoryResetArmedAt=0 end
        self.restore:SetText((tonumber(self.restoreArmedAt) or 0)>0 and "再次点击确认恢复" or "恢复默认布局 / 大小")
        local resetPending=S.Storage and S.Storage.factoryResetPending==true
        self.factoryReset:SetText(resetPending and "已清空，等待重载" or ((tonumber(self.factoryResetArmedAt) or 0)>0 and "再次点击确认全部重置" or "恢复全部默认设置"))
        if self.factoryReset.Enable then self.factoryReset:Enable(resetPending~=true) end
        self.scaleValue:SetText(tostring(math.floor((S.State.settings.addonScale or 1)*100+0.5)).."%")
        self.fontSize:SetText("字体大小："..tostring(math.floor((S.State.settings.fontScale or 1.2)*100+0.5)).."%")
        self.opacity:SetText("整窗透明："..tostring(math.floor((S.State.settings.opacity or 0.9)*100+0.5)).."%")
        self.contentOpacity:SetText("内容背景："..tostring(math.floor((S.State.settings.contentOpacity or 1.0)*100+0.5)).."%")
        local start=tostring(S.State.settings.defaultStartPage or "life")
        local label=S.UICatalog and S.UICatalog:GetPageLabel(start) or start
        self.startPage:SetText("启动页："..tostring(label))
        self.dataRefresh:SetText("数据刷新："..tostring(math.floor((S.State.settings.dataRefreshMs or 15000)/1000)).."秒")
        self.entryLock:SetText(S.State.settings.entryLocked and "主入口：已锁定" or "主入口：可拖动")
        self.mainLock:SetText(S.State.settings.mainLocked and "主面板：已锁定" or "主面板：可拖动")
    end

    function page:ApplyLayout(spec)
        S.UI:SetAnchor(self.root,parent,0,0); self.root:SetExtent(spec.contentWidth,spec.contentHeight)
        local sc=S.Layout:GetContext().addonScale; local pad=12*sc; local gap=8*sc; local full=math.max(1,spec.contentWidth-pad*2)
        self.title:SetExtent(full,28*sc); S.UI:SetAnchor(self.title,self.root,pad,8*sc)
        self.noteTop:SetExtent(full,24*sc); S.UI:SetAnchor(self.noteTop,self.root,pad,38*sc)
        self.scaleLabel:SetExtent(120*sc,22*sc); S.UI:SetAnchor(self.scaleLabel,self.root,pad,72*sc)
        self.scaleValue:SetExtent(70*sc,22*sc); S.UI:SetAnchor(self.scaleValue,self.root,pad+122*sc,72*sc)
        local sy=98*sc; local sg=6*sc; local sw=math.max(44*sc,(full-sg*4)/5)
        for i,item in ipairs(self.scaleButtons) do item.button:SetExtent(sw,26*sc); S.UI:SetAnchor(item.button,self.root,pad+(i-1)*(sw+sg),sy) end

        local four=math.max(1,(full-gap*3)/4)
        local function Quad(items,y)
            for i,b in ipairs(items) do b:SetExtent(four,28*sc); S.UI:SetAnchor(b,self.root,pad+(i-1)*(four+gap),y) end
        end
        Quad({self.fontSize,self.opacity,self.contentOpacity,self.startPage},142*sc)
        self.runtimeTitle:SetExtent(full,24*sc); S.UI:SetAnchor(self.runtimeTitle,self.root,pad,190*sc)
        Quad({self.dataRefresh,self.refreshNow,self.entryLock,self.mainLock},220*sc)
        self.manageTitle:SetExtent(full,24*sc); S.UI:SetAnchor(self.manageTitle,self.root,pad,276*sc)
        Quad({self.openHud,self.openModules,self.openTools,self.openDiagnostics},306*sc)
        self.maintenanceTitle:SetExtent(full,24*sc); S.UI:SetAnchor(self.maintenanceTitle,self.root,pad,362*sc)
        Quad({self.reloadAll,self.reloadCode,self.restore,self.factoryReset},392*sc)
        self.note:SetExtent(full,30*sc); S.UI:SetAnchor(self.note,self.root,pad,430*sc)
        self:Refresh()
    end

    page:Refresh(); S.UI.pages.settings=page; return page
end
