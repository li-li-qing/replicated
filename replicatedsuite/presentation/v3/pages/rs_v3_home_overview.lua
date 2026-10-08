------------------------------------------------------------------------
-- 今日总览 / personal-workspace-1（2026-09-18）。
-- 首页只组织 Feature/Shared Service 的投影，不拥有进度/货率/提醒事实；Workspace 拥有卡片偏好。
-- 所有卡片固定 Native parent，按整卡视口显示；只有已排列且可见的卡片申请自己的 lease。
-- 收起/隐藏页面释放本页需求，不能停用他人开启的模块；无 Tick、无自动询价、无隐式启用。
-- 兼容：沿用旧业务 Store 和原 ToggleFloating 事务，主题/布局不修改业务配置。
------------------------------------------------------------------------
if ReplicatedSuite==nil or ReplicatedSuite.BootError~=nil then return end
local S=ReplicatedSuite
local R,D=S.RSUI,S.UIV3Design
if not R or not D then return end
S.UIV3=S.UIV3 or {}
local Home={patch='home-compact-paired-reminders-3'};S.UIV3.HomeOverview=Home
local W=S.UIV3.Workspace
local TASK='v3_home_refresh'
local GAP=6
local Reminders=S.Services and S.Services.HomeRemindersV3
if Reminders and S.ModuleDiagnosticsHub and type(S.ModuleDiagnosticsHub.RegisterProvider)=='function' then
    S.ModuleDiagnosticsHub:RegisterProvider('life_daily_stats','home_reminders',function()return Reminders:GetHealth()end,90,{detailOnly=true,detailDeferred=true})
end
local function Enabled(id)return S.FeatureRuntime and S.FeatureRuntime:IsEnabled(id)==true end
local function Open(route)
    -- 中文维护注释（2026-09-15，今日总览管理按钮）：UIV3 本身从未拥有 Navigate；
    -- 统一导航 Authority 是 UIV3.Shell，UIV3Host 只是宿主适配器。旧代码调用不存在的
    -- S.UIV3:Navigate() 导致按钮静默失败。这里只走既有 Shell/Host，不直接构建页面、
    -- 不改变 Router/PageHost 数据流，旧路由字符串完全兼容。
    local shell = S.UIV3 and S.UIV3.Shell or nil
    if type(shell) == "table" and type(shell.Navigate) == "function" then
        return shell:Navigate(route, { source="home_card" })
    end
    local host = S.UIV3Host
    if type(host) == "table" and type(host.Navigate) == "function" then
        return host:Navigate(route, { source="home_card" })
    end
    return false, "导航不可用"
end

local function ToggleFloating(featureId, widgetId)
    -- 中文维护注释（2026-09-15，首页快捷悬浮）：Presentation 只发显式用户动作。WidgetHost 仍是
    -- 窗口生命周期 Authority，FeatureRuntime 仍是功能启停 Authority；首页绝不直接 Create/Destroy Native。
    -- 若功能原本关闭，用户点“悬浮”即明确要求启用；若窗口构建失败则回滚本次启用，避免半启用状态。
    -- 兼容边界：Feature 自己的 widgetVisible/window placement Store 仍由原 Commands 持久化。
    local host = S.UIV3 and S.UIV3.WidgetHost or nil
    if type(host) ~= "table" or type(host.SetVisible) ~= "function" or type(host.IsVisible) ~= "function" then
        return false, "悬浮组件不可用"
    end
    local visible = host:IsVisible(widgetId) == true
    if visible then return host:SetVisible(widgetId, false, { source="home_widget_shortcut", persist=true }) end

    local wasEnabled = Enabled(featureId)
    if not wasEnabled then
        if S.FeatureRuntime == nil or type(S.FeatureRuntime.SetPreferredEnabled) ~= "function" then return false, "功能管理不可用" end
        local enabledOk, enabledErr = S.FeatureRuntime:SetPreferredEnabled(featureId, true, "home_widget_shortcut")
        if enabledOk ~= true then return false, enabledErr end
    end
    local shown, showErr = host:SetVisible(widgetId, true, { source="home_widget_shortcut", persist=true })
    if shown ~= true and not wasEnabled and S.FeatureRuntime ~= nil and type(S.FeatureRuntime.SetPreferredEnabled) == "function" then
        S.FeatureRuntime:SetPreferredEnabled(featureId, false, "home_widget_shortcut_rollback")
    end
    return shown, showErr
end
local function Text(parent,id,text,size,tone,slot)
    return R:Text({id=id,parent=parent,text=text or "",fontSize=size or 11,tone=tone or "default",
        overflow="ellipsis",slot=slot or {size="fixed",height=22,hAlign="fill"}})
end
local function Amount(row)
    -- 中文维护（2026-10-04）：统计符号使用 ASCII；金币曾独用 U+2212 减号，
    -- 未采集占位用 U+2014，部分客户端字体可能显示缺字方框。未知仍不伪造为零。
    if type(row.value) ~= "number" then return "--" end
    local n = math.abs(row.value)
    if row.key == "gold" then
        if row.value==0 then return "0金" end
        return (row.value < 0 and "-" or "+") .. math.floor(n/10000) .. "金" .. math.floor(n/100)%100 .. "银" .. (n%100>0 and (tostring(n%100).."铜") or "")
    end
    return (row.value < 0 and "" or "+") .. string.format("%.0f", row.value)
end
local function Detail(item)
    local service = S.UIV3.QuestDetailFloatingV3
    if not item or not service or type(service.Open) ~= "function" then return false,"任务详情不可用" end
    return service:Open(item.scope or item.questScope or "event", item.groupKey or item.questKey or item.key, item)
end

function Home:Build(parent,route)
    if not W then return nil,'个人工作台偏好未加载' end
    W:EnsureLoaded()
    local root,err=D:PageRoot(parent,{id='v3_page_home',gap=2,padding=2});if not root then return nil,err end
    root.route,root.active,root.cards=route or 'home',false,{}
    root.compactPageChrome=true -- 宿主只消费布局元数据，不识别首页业务或改变开关/诊断入口。
    root.patch=Home.patch;root.cardByKey={};root.presentation=W:GetSettings()
    local statViews,reminderViews={},{}
    local ledgerToggle,note
    local header=R:HorizontalBox({id='v3_home_header',parent=root,gap=4,slot={size='fixed',height=22,hAlign='fill'}})
    Text(header,'v3_home_header_title','今日总览',14,'accent',{size='fixed',width=74})
    local context=Text(header,'v3_home_workspace_note','我的卡片',9,'muted',{size='fill',fill=1})
    local dateText=Text(header,'v3_home_date','服务器日期 · 等待读取',9,'muted',{size='fixed',width=138})
    R:Button({id='v3_home_customize',parent=header,text='自定义首页',compact=true,slot={size='fixed',width=80},
        onClick=function()return S.UIV3.WorkspacePage:Open('home')end})
    -- 共享宿主已有左上诊断时领取同一实例；独立页面宿主仍使用统一 helper。
    D:ModuleDiagnosticsButton(header,'v3_home_diagnostics',66)
    local nav=R:HorizontalBox({id='v3_home_card_navigation',parent=header,gap=2,slot={size='fixed',width=70,hAlign='fill'}})
    local previous=R:Button({id='v3_home_previous',parent=nav,text='向上',compact=true,slot={size='fixed',width=34},onClick=function()return root.grid:ScrollBy(-1)end})
    local nextButton=R:Button({id='v3_home_next',parent=nav,text='向下',compact=true,slot={size='fixed',width=34},onClick=function()return root.grid:ScrollBy(1)end})
    local layoutPage=root.Layout
    function root:Layout(x,y,w,h)
        -- 窄窗口省略辅助日期/计数，始终保留自定义与翻页；不挪动任何 Native parent。
        dateText:SetVisible((w or 0)>=620);context:SetVisible((w or 0)>=540)
        return layoutPage(self,x,y,w,h)
    end
    local empty=Text(root,'v3_home_empty','首页未显示卡片。点击“自定义首页”选择内容；不会自动启用功能。',11,'muted',{size='fixed',height=30})
    empty:SetVisible(false);root.empty=empty
    -- 使用已验证 ScrollBox 轮滚/滚动条契约；离散滚动位置对应卡片起点与末屏。
    -- 不使用未公开裁剪 API：离开视口的整卡隐藏，重排始终保持同一 Native parent。
    local grid=R:ScrollBox({id='v3_home_data_grid',parent=root,gap=GAP,scrollStep=1,scrollbar=true,
        slot={size='fill',fill=1,hAlign='fill',vAlign='fill'}});root.grid=grid
    local function Customize(spec)return S.UIV3.WorkspacePage:Open('lists',spec.key=='activities' and 'activities' or spec.scope)end
    for _,definition in ipairs(W:GetCards(true))do
        local spec={key=definition.id,name=definition.feature,id=definition.featureId,title=definition.name,scope=definition.scope,kind=definition.kind,
            route=definition.route,widgetId=definition.widget,token='home:'..definition.id,prefix='v3_home_'..definition.id..'_'}
        local panel=R:GroupBox({id=spec.prefix..'panel',parent=grid,variant='card',headerHeight=0,padding=4,gap=0,slot={hAlign='fill',vAlign='fill'}})
        local body=R:VerticalBox({id=spec.prefix..'body',parent=panel,gap=2,slot={hAlign='fill',vAlign='fill'}})
        local bar=R:HorizontalBox({id=spec.prefix..'header',parent=body,gap=4,slot={size='fixed',height=22,hAlign='fill'}})
        local title=Text(bar,spec.prefix..'title',spec.title,11,'accent',{size='fill',fill=1})
        local card={spec=spec,feature=spec.name and S.Features and S.Features[spec.name],held=false,panel=panel,body=body}
        card.title,card.header=title,bar
        root.cards[#root.cards+1]=card;root.cardByKey[spec.key]=card;panel:SetViewportVisible(false)
        if not spec.kind then
            R:Button({id=spec.prefix..'open',parent=bar,text='管理',compact=true,slot={size='fixed',width=40},onClick=function()return Open(spec.route)end})
            card.widgetButton=R:Button({id=spec.prefix..'widget',parent=bar,text='悬浮',compact=true,slot={size='fixed',width=64},onClick=function()
                local ok,why=ToggleFloating(spec.id,spec.widgetId);root:RefreshWidgetButtons();return ok,why
            end})
        end
        if spec.kind=='stats'then
            ledgerToggle=R:Button({id='v3_home_stats_toggle',parent=bar,text='暂停统计',compact=true,slot={size='fixed',width=76},onClick=function()
                local ledger=S.Features and S.Features.DailyLedger
                if not Enabled('life_daily_stats')then return false,'请先在左上角开启今日统计'end
                if not ledger or not ledger.SetPaused then return false,'统计接口不可用'end
                local ok,why=ledger:SetPaused(not ledger.paused,'home_toggle');if ok then root:RefreshStats()end;return ok,why
            end})
            local stats=R:VerticalBox({id='v3_home_stats_grid',parent=body,gap=1,slot={size='auto',hAlign='fill'}})
            for _,field in ipairs({{'gold','金币净变化'},{'honor','荣誉净变化'},{'experience','经验变化'},{'living','生活点净变化'}})do
                local line=R:HorizontalBox({id='v3_home_stat_row_'..field[1],parent=stats,gap=4,slot={size='fixed',height=21,hAlign='fill'}})
                Text(line,'v3_home_stat_title_'..field[1],field[2],10,'muted',{size='fill',fill=1})
                statViews[field[1]]=Text(line,'v3_home_stat_'..field[1],'--',12,'default',{size='fixed',width=145})
            end
            note=Text(body,'v3_home_stats_note','仅统计已观测变化；未知显示 --。',9,'muted',{size='fixed',height=15})
        elseif spec.kind=='reminders'then
            card.service=Reminders
            R:Button({id=spec.prefix..'refresh',parent=bar,text='刷新',compact=true,slot={size='fixed',width=48},onClick=function()
                if not root.active or not card.held or not Reminders then return false,'提醒卡片当前不可读取'end
                return Reminders:Refresh('manual')
            end})
            for _,pair in ipairs({{{'costume','时装',28},{'underwear','内衣',28}},{{'daily','每日任务',48},{'guild','公会任务',48}}})do
                local line=R:HorizontalBox({id=spec.prefix..'row_'..pair[1][1],parent=body,gap=8,slot={size='fixed',height=22,hAlign='fill'}})
                for _,field in ipairs(pair)do
                    local cell=R:HorizontalBox({id=spec.prefix..'field_'..field[1],parent=line,gap=4,slot={size='fill',fill=1,hAlign='fill'}})
                    Text(cell,spec.prefix..'name_'..field[1],field[2],10,'muted',{size='fixed',width=field[3]})
                    reminderViews[field[1]]=Text(cell,'v3_home_reminder_'..field[1],'待确认',10,'muted',{size='fill',fill=1})
                end
            end
            card.status=Text(body,spec.prefix..'status','',9,'orange',{size='fixed',height=14})
            card.status:SetVisible(false)
        elseif spec.name=='Trade' or spec.name=='Bonds'then
            local contents=S.UIV3.LifeEconomyContent
            if contents then card.content,card.error=contents:Create(body,spec.name,spec.prefix,{overview=true,headerParent=bar})end
            if not card.content then Text(body,spec.prefix..'unavailable',card.error or '内容服务未加载',11,'muted')end
        else
            R:Button({id=spec.prefix..'customize',parent=bar,text='自定义',compact=true,slot={size='fixed',width=50},onClick=function()return Customize(spec)end})
            local isTask=spec.name=='Tasks'
            local columns=isTask and {
                {id='name',title='任务',field='rawName',size='fill',fill=2,minWidth=80},
                {id='progress',title='进度',field='progressText',width=54,minWidth=40},
                {id='status',title='状态',field='status',width=68,minWidth=46,getTone=function(item)return item.tone or 'muted'end},
            } or {
                {id='name',title='活动',field='shortName',size='fill',minWidth=75},
                {id='status',title='状态 / 时间',field='status',size='fill',fill=1.4,minWidth=94,getTone=function(item)return item.tone or 'muted'end},
                {id='progress',title='进度',field='progressText',width=48,minWidth=32},
            }
            -- 活动卡与页面/悬浮共用双视口；任务卡继续使用单表，不新增数据消费者。
            local tableFactory=not isTask and S.UIV3.ActivityLists or nil
            local function BuildTable(options)
                if tableFactory then return tableFactory:Create(options) end
                return R:TableView(options)
            end
            card.table=BuildTable({id=spec.prefix..'table',parent=body,items={},rowHeight=21,headerHeight=20,desiredRows=4,overscan=1,
                scrollbar=true,selectable=true,selectionMode='single',columnResize=true,headerInteractive=false,columns=columns,
                getKey=function(item)return item and (item.id or item.key)end,
                -- TableView 的 Activated 是单击，不是假定的双击。任务单击只选中，详情走显式按钮。
                onItemActivated=not isTask and function(item)return Detail(item)end or nil,
                onSelectionChanged=function(index)card.selected=card.table:GetItem(index);if card.detail then card.detail:SetEnabled(card.selected~=nil)end end,
                slot={size='fill',fill=1,hAlign='fill',vAlign='fill'}})
            local footer=R:HorizontalBox({id=spec.prefix..'footer',parent=body,gap=4,slot={size='fixed',height=18,hAlign='fill'}})
            card.status=Text(footer,spec.prefix..'status','',10,'muted',{size='fill',fill=1})
            card.badge=card.status
            card.detail=R:Button({id=spec.prefix..'detail',parent=footer,text='详情',compact=true,enabled=false,slot={size='fixed',width=48},onClick=function()return Detail(card.selected)end})
        end
    end
    local function ReminderStatus(card,message)
        card.status:SetText(message or '');card.status:SetVisible(message~=nil and message~='')
    end
    local function Release(card)
        if card.content and card.content.CloseHeaderSettings then card.content:CloseHeaderSettings()end
        if not card.held then return true end
        if card.service then local ok,why=card.service:ReleaseConsumer(card.spec.token);if ok then card.held=false end;return ok,why end
        if not Enabled(card.spec.id)then card.held=false;return true end -- Runtime Disable 已释放该 Feature 的 Demand。
        local ok,why=card.feature:ReleaseConsumer(card.spec.token);if ok then card.held=false end;return ok,why
    end
    function root:RefreshStats()
        if not self.active then return true end
        local ledger=S.Features and S.Features.DailyLedger
        local projection=ledger and ledger.GetProjection and ledger:GetProjection() or {rows={},error='账本未加载'}
        dateText:SetText((projection.clockAvailable==false and '上次确认 · ' or '服务器日期 · ')..tostring(projection.day or '等待读取'))
        ledgerToggle:SetText(not Enabled('life_daily_stats') and '统计未开启' or projection.paused and '继续统计' or '暂停统计')
        ledgerToggle:SetEnabled(Enabled('life_daily_stats'))
        local seen={}
        for _,row in ipairs(projection.rows or {})do local view=statViews[row.key]
            if view then seen[row.key]=true;view:SetText(Amount(row));view:SetTone(type(row.value)=='number' and (row.value<0 and 'orange' or 'green') or 'muted')end
        end
        for key,view in pairs(statViews)do if not seen[key]then view:SetText('--');view:SetTone('muted')end end
        note:SetText(projection.error and ('账本：'..tostring(projection.error)) or not Enabled('life_daily_stats') and '统计未开启；已保存数据不代表当前仍在统计。'
            or projection.paused and '统计已暂停；已累计结果保留。' or '按服务器日期换日 · 仅统计已观测变动；未连接来源显示 --。')
        return true
    end
    function root:RefreshWidgetButtons()
        local host=S.UIV3.WidgetHost
        for _,card in ipairs(self.cards)do
            if card.widgetButton then
                local visible=host and host:IsVisible(card.spec.widgetId)
                card.widgetButton:SetText(visible and '收起悬浮' or not Enabled(card.spec.id) and '启用悬浮' or '悬浮')
                card.widgetButton:SetEnabled(host~=nil and type(host.SetVisible)=='function')
            end
        end
        return true
    end
    local function RefreshCard(card)
        if not root.active or card.panel.viewportVisible==false then return Release(card)end
        if card.spec.kind=='stats'then return true end
        if card.spec.kind=='reminders'then
            if card.service and not card.held then
                card.held=true;local ok,why=card.service:AcquireConsumer(card.spec.token)
                if not ok then card.held=false;ReminderStatus(card,'读取失败：'..tostring(why))end
            end
            return root:RefreshReminders()
        end
        local available=Enabled(card.spec.id) and card.feature~=nil;local reason='功能未开启'
        if available and not card.held then
            card.held=true -- Acquire 可同步广播，先标记防重复 lease；失败立即回滚。
            local ok,why=card.feature:AcquireConsumer(card.spec.token)
            if not ok then card.held=false;available=false;reason='读取失败：'..tostring(why)end
        elseif not available then Release(card)end
        if card.content then
            local ok,why=card.content:SetAvailable(available,reason)
            if ok then card.dataKnown=true;if card.content.routeTitle then card.title:SetText('跑商 · '..card.content.routeTitle)end end
            return ok,why
        end
        if not card.table then return true end
        if not available then
            card.table:SetItems({},'off');card.table:SetViewState('empty',{title=reason,detail='可打开设置，或明确选择“启用并打开”。'})
            card.selected=nil;card.detail:SetEnabled(false);card.badge:SetText('未运行');card.status:SetText(reason);card.dataKnown=true;return true
        end
        local rows,revision
        if card.spec.name=='Tasks'then
            local projection=card.feature:GetOverviewProjection({scope=card.spec.scope,view='tracked',status='all',query=''})
            rows=W:ProjectRows('tasks',projection.rows or {});revision=projection.revision
        else rows,revision=card.feature:GetRows();rows=W:ProjectRows('activities',rows or {})end
        card.table:SetItems(rows,tostring(revision or 0)..':'..W.revision)
        card.dataKnown=true
        card.table:SetViewState(#rows>0 and 'ready' or 'empty',{title='当前没有关注内容',detail='点击自定义选择；完成项也可能已被隐藏。'})
        if card.selected then local selected=nil;for _,row in ipairs(rows)do if (row.id or row.key)==(card.selected.id or card.selected.key)then selected=row;break end end;card.selected=selected end
        card.detail:SetEnabled(card.selected~=nil);card.badge:SetText('我的关注 · '..#rows..' 项')
        card.status:SetText('共 '..#rows..' 项 · '..(card.spec.name=='Tasks' and '选中查看详情' or '活动 / 区域状态'))
        return true
    end
    function root:RefreshReminders()
        local card=self.cardByKey.reminders
        if not self.active or not card or not card.held or card.panel.viewportVisible==false then return true end
        local projection=card.service and card.service:GetProjection() or {rows={}}
        local seen={}
        for _,row in ipairs(projection.rows or {})do
            local view=reminderViews[row.key]
            if view then seen[row.key]=true;view:SetText(row.text or '待确认');view:SetTone(row.tone or 'muted')end
        end
        for key,view in pairs(reminderViews)do if not seen[key]then view:SetText('待确认');view:SetTone('muted')end end
        ReminderStatus(card,projection.error and ('读取失败：'..tostring(projection.error)))
        if not self.refreshing then self:ArrangeCardsIfNeeded()end
        return true
    end
    function root:RefreshData()
        if not self.active or self.refreshing then return true end
        self.refreshing=true
        local needsRefresh=false
        local ok,why=xpcall(function()
            self:RefreshStats();self:RefreshWidgetButtons()
            for _,card in ipairs(self.cards)do
                local good,value,err=pcall(RefreshCard,card)
                if not good or value==false then
                    local reason=tostring(good and err or value)
                    if card.status then
                        if card.spec.kind=='reminders'then ReminderStatus(card,'读取失败：'..reason)else card.status:SetText('读取失败：'..reason)end
                    end
                    if S.DiagnosticsManager then S.DiagnosticsManager:Error('home','HOME_CARD_REFRESH_FAILED',reason,{feature=card.spec.id})end
                end
            end
            needsRefresh=self:ArrangeCardsIfNeeded()
        end,S.SafeTraceback or tostring)
        self.refreshing=false
        if ok and needsRefresh then self:QueueRefresh()end
        return ok,why
    end
    function root:QueueRefresh()
        if not self.active or self.refreshing or self.refreshQueued then return true end
        self.refreshQueued=true
        if S.Scheduler and S.Scheduler.AddOneShot then
            local ok=S.Scheduler:AddOneShot(TASK,100,function()root.refreshQueued=false;return root:RefreshData()end,self,'P3',1)
            if ok then return true end
        end
        self.refreshQueued=false;return self:RefreshData()
    end
    function grid:GetScrollableEntries()return self.rowEntries or {}end
    function grid:ResolveColumns(w)return w>=1080 and 3 or w>=700 and 2 or 1 end
    function grid:Measure(w,h)self.desiredWidth=w or 350;self.desiredHeight=math.min(h or 400,600);self.measureDirty=false;return self.desiredWidth,self.desiredHeight end
    function grid:CardHeight(card)
        if card.spec.kind=='stats'then return 134 end
        if card.spec.kind=='reminders'then return card.status.visible and 94 or 78 end
        local view=card.table or card.content and card.content.table
        if not view then return 100 end
        local compact=root.presentation.density=='compact'
        local cap=card.spec.name=='Trade' and (compact and 5 or 6) or (compact and 3 or 4)
        local count=card.dataKnown and view:GetItemCount() or cap
        -- 基准行高独立于 TableView 的尾部自适应行高，报价/选择刷新不能来回改变卡片高度。
        local tableHeight=math.max(count==0 and 64 or 50,(view.headerHeight or 20)+math.min(cap,count)*(card.content and 22 or 21))
        if card.spec.name=='Activities' and view.timeline then
            local timeCount=card.dataKnown and #view.timelineItems or 2
            local liveCount=card.dataKnown and #view.liveItems or 5
            if timeCount>0 and liveCount>0 then
                tableHeight=(view.timeline.headerHeight or 20)+math.min(compact and 1 or 2,timeCount)*21
                    +(view.live.headerHeight or 20)+math.min(5,liveCount)*20
            elseif timeCount>0 then tableHeight=math.max(50,(view.timeline.headerHeight or 20)+math.min(4,timeCount)*21)
            elseif liveCount>0 then tableHeight=math.max(50,(view.live.headerHeight or 20)+math.min(5,liveCount)*20)end
        end
        return tableHeight+(card.content and 50 or 52)
    end
    function grid:ExpansionSteps(card)
        local steps={}
        if not card.dataKnown or card.spec.kind then return steps end
        local view=card.table or card.content and card.content.table
        if not view then return steps end
        local compact=root.presentation.density=='compact'
        local function Rows(first,count,height)
            -- 本地已读取行数决定扩展，不采集更多数据；单表最多显示 12 行，保持有界虚拟池。
            for i=first+1,math.min(12,count)do steps[#steps+1]=height end
        end
        if card.spec.name=='Activities' and view.timeline then
            local timeCount,liveCount=#view.timelineItems,#view.liveItems
            Rows(liveCount>0 and (compact and 1 or 2) or 4,timeCount,21)
            Rows(5,liveCount,20)
        else
            Rows(card.spec.name=='Trade' and (compact and 5 or 6) or (compact and 3 or 4),view:GetItemCount(),card.content and 22 or 21)
        end
        return steps
    end
    function grid:SizeSignature()
        local parts={}
        for _,definition in ipairs(root.visibleDefinitions or W:GetCards())do
            local card=root.cardByKey[definition.id]
            parts[#parts+1]=definition.id..':'..self:CardHeight(card)..':'..table.concat(self:ExpansionSteps(card),',')
        end
        return table.concat(parts,'|')
    end
    function root:ArrangeCardsIfNeeded()
        if not grid.width or not grid.height or grid.layoutSignature==grid:SizeSignature()then return false end
        grid:Layout(grid.x,grid.y,grid.width,grid.height)
        return grid.visibilityChanged
    end
    function grid:Layout(x,y,w,h)
        w,h=math.max(1,w or 1),math.max(1,h or 1);self:SetBounds(x,y,w,h)
        local definitions=root.visibleDefinitions or W:GetCards();local columns=self:ResolveColumns(w)
        -- 中文维护（2026-10-04，用户截图反馈）：固定轨道/跨行导致短列表也占满大框。
        -- 现在按本地投影行数计算有界高度，每列接着上张卡排；不拉伸短卡、不删数据。
        -- 滚动停靠到卡片起点及末屏，只有完全进入视口的卡申请 lease；Native parent 始终固定。
        local bottoms,positions,starts,columnCards,totalHeight={},{},{},{},0
        for column=1,columns do bottoms[column]=0;columnCards[column]={} end
        for _,definition in ipairs(definitions)do
            local card=root.cardByKey[definition.id];local column=1
            for candidate=2,columns do if bottoms[candidate]<bottoms[column]then column=candidate end end
            local height=math.min(h,self:CardHeight(card));local top=bottoms[column]
            positions[definition.id]={column=column,y=top,height=height};starts[#starts+1]=top
            columnCards[column][#columnCards[column]+1]={position=positions[definition.id],steps=self:ExpansionSteps(card),next=1}
            bottoms[column]=top+height+GAP;totalHeight=math.max(totalHeight,top+height)
        end
        -- 全部卡片已能放入时，把列底空白按整行分给仍有隐藏数据的列表。
        -- 短卡保持原高度，原列归属固定；报价变化不会触发尺寸签名变化或重排。
        if totalHeight<=h then
            starts={};totalHeight=0
            for column=1,columns do
                local spare=h-math.max(0,bottoms[column]-GAP)
                local added=true
                while added do
                    added=false
                    for _,entry in ipairs(columnCards[column])do
                        local step=entry.steps[entry.next]
                        if step and step<=spare then
                            entry.position.height=entry.position.height+step;entry.next=entry.next+1
                            spare=spare-step;added=true
                        end
                    end
                end
                local top=0
                for _,entry in ipairs(columnCards[column])do
                    entry.position.y=top;starts[#starts+1]=top
                    totalHeight=math.max(totalHeight,top+entry.position.height);top=top+entry.position.height+GAP
                end
            end
        end
        local maxY=math.max(0,totalHeight-h)
        local stops,seen={0},{[0]=true}
        starts[#starts+1]=maxY
        for _,start in ipairs(starts)do local value=math.min(maxY,start)
            if not seen[value]then seen[value]=true;stops[#stops+1]=value end
        end
        table.sort(stops)
        self.rowEntries={};for i,stop in ipairs(stops)do self.rowEntries[i]={offset=stop}end
        self.maxScrollOffset=#stops-1;self.scrollOffset=math.min(self.scrollOffset,self.maxScrollOffset)
        local offset=stops[self.scrollOffset+1] or 0
        self.visibleStart,self.visibleEnd=self.scrollOffset+1,self.scrollOffset+1
        self.totalContentHeight,self.pixelOffset=totalHeight,offset
        local reserve=self:GetScrollbarReserve(self.maxScrollOffset>0);local width=math.max(1,(w-reserve-GAP*(columns-1))/columns)
        local changed,shown=false,0
        for _,card in ipairs(root.cards)do
            local position=positions[card.spec.key]
            local show=position~=nil and position.y>=offset-0.01 and position.y+position.height<=offset+h+0.01
            if (card.panel.viewportVisible~=false)~=show then changed=true end
            card.panel:SetViewportVisible(show)
            if show then
                shown=shown+1
                card.panel:Layout((position.column-1)*(width+GAP),position.y-offset,width,position.height)
            end
            if not show and card.held then Release(card)end
        end
        self.layoutSignature=self:SizeSignature();self.visibilityChanged=changed
        self.canScrollBackward=self.scrollOffset>0;self.canScrollForward=self.scrollOffset<self.maxScrollOffset
        previous:SetEnabled(self.canScrollBackward);nextButton:SetEnabled(self.canScrollForward)
        context:SetText(#definitions==0 and '未选择卡片' or (#definitions..' 项 · 显示 '..shown..' 项'))
        if self.scrollbar then self.scrollbar:Layout(w-self.scrollbarWidth,0,self.scrollbarWidth,h,h,math.max(h,totalHeight))end
        if changed then root:QueueRefresh()end
        return h
    end
    function root:RefreshPreferences()
        self.presentation=W:GetSettings();self.visibleDefinitions=W:GetCards()
        empty:SetVisible(#self.visibleDefinitions==0);grid.scrollOffset=0
        if grid.width and grid.height then grid:Layout(grid.x,grid.y,grid.width,grid.height)end
        self:InvalidateMeasure('home_preferences');return self:QueueRefresh()
    end
    function root:OnActivated()
        if self.active then return self:RefreshData()end
        self.active=true;self:RefreshPreferences()
        if S.Events then
            local seen={}
            for _,card in ipairs(self.cards)do
                local topic=card.feature and card.feature.UpdateTopic or card.spec.name=='Tasks' and 'v3.tasks.updated' or card.spec.name=='Activities' and 'v3.activities.updated'
                if topic and not seen[topic]then
                    seen[topic]=true
                    S.Events:SubscribeInternal(topic,self,function()
                        if not root.active then return end
                        -- Authority 推送只影响持有 lease 且可见的对应卡。隐藏任务/活动不触发首页全量刷新；
                        -- 经济查询结果直接喂给同源内容，不重复询价，也不顺带排队刷新其他模块。
                        local needsRefresh=false
                        for _,c in ipairs(root.cards)do
                            local ownTopic=c.feature and c.feature.UpdateTopic or c.spec.name=='Tasks' and 'v3.tasks.updated' or c.spec.name=='Activities' and 'v3.activities.updated'
                            if ownTopic==topic and c.held and c.panel.viewportVisible~=false and Enabled(c.spec.id)then
                                if c.content then
                                    c.content:Refresh();c.dataKnown=true
                                    if c.content.routeTitle then c.title:SetText('跑商 · '..c.content.routeTitle)end
                                    if not root.refreshing and root:ArrangeCardsIfNeeded()then needsRefresh=true end
                                else needsRefresh=true end
                            end
                        end
                        if needsRefresh then return root:QueueRefresh()end
                        return true
                    end)
                end
            end
            S.Events:SubscribeInternal('v3.daily_ledger.updated',self,function()return root:RefreshStats()end)
            S.Events:SubscribeInternal('v3.home.reminders.updated',self,function()return root:RefreshReminders()end)
            S.Events:SubscribeInternal('v3.workspace.updated',self,function(_,kind)
                if kind=='home' or kind=='density'then return root:RefreshPreferences()end
                if kind=='lists'then return root:QueueRefresh()end
            end)
            S.Events:SubscribeInternal('v3.widgets.changed',self,function()return root:RefreshWidgetButtons()end)
            S.Events:SubscribeInternal('v3.feature.lifecycle',self,function(_,id)
                for _,card in ipairs(root.cards)do if card.spec.id==id and not Enabled(id)then card.held=false end end
                return root:QueueRefresh()
            end)
        end
        return self:RefreshData()
    end
    function root:OnDeactivated()
        self.active=false;self.refreshQueued=false;if S.Events then S.Events:UnsubscribeInternalOwner(self)end
        if S.Scheduler then S.Scheduler:RemoveTask(TASK)end
        local ok,why=true,nil;for _,card in ipairs(self.cards)do local good,err=Release(card);if not good then ok=false;why=err end end
        return ok,why
    end
    function root:OnDispose()
        local ok,err=self:OnDeactivated()
        for _,card in ipairs(self.cards)do
            if card.content and card.content.DisposeHeaderSettings then card.content:DisposeHeaderSettings()end
        end
        return ok,err
    end
    return root
end
