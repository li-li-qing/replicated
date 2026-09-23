------------------------------------------------------------------------
-- 今日总览 / personal-workspace-1（2026-09-18）。
-- 首页只组织已有 Feature 的投影，不拥有进度/货率/追踪事实；Workspace 拥有卡片偏好。
-- 所有卡片固定 Native parent，按行视口显示；只有已排列且可见的卡片申请自己的 lease。
-- 收起/隐藏页面释放本页需求，不能停用他人开启的模块；无 Tick、无自动询价、无隐式启用。
-- 兼容：沿用旧业务 Store 和原 ToggleFloating 事务，主题/布局不修改业务配置。
------------------------------------------------------------------------
if ReplicatedSuite==nil or ReplicatedSuite.BootError~=nil then return end
local S=ReplicatedSuite
local R,D=S.RSUI,S.UIV3Design
if not R or not D then return end
S.UIV3=S.UIV3 or {}
local Home={patch='personal-workspace-1'};S.UIV3.HomeOverview=Home
local W=S.UIV3.Workspace
local TASK='v3_home_refresh'
local GAP=8
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
    if type(row.value) ~= "number" then return "—" end
    local n = math.abs(row.value)
    if row.key == "gold" then
        if row.value==0 then return "0金" end
        return (row.value < 0 and "−" or "+") .. math.floor(n/10000) .. "金" .. math.floor(n/100)%100 .. "银" .. (n%100>0 and (tostring(n%100).."铜") or "")
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
    local root,err=D:PageRoot(parent,{id='v3_page_home',gap=6,padding=4});if not root then return nil,err end
    root.route,root.active,root.cards=route or 'home',false,{}
    root.patch=Home.patch;root.cardByKey={};root.presentation=W:GetSettings()
    local header=R:HorizontalBox({id='v3_home_header',parent=root,gap=6,slot={size='fixed',height=30,hAlign='fill'}})
    Text(header,'v3_home_header_title','今日总览',16,'accent',{size='fill',fill=1})
    local dateText=Text(header,'v3_home_date','服务器日期 · 等待读取',10,'muted',{size='fixed',width=160})
    R:Button({id='v3_home_customize',parent=header,text='自定义首页',compact=true,slot={size='fixed',width=92},
        onClick=function()return S.UIV3.WorkspacePage:Open('home')end})
    local ledgerToggle=R:Button({id='v3_home_stats_toggle',parent=header,text='暂停统计',compact=true,slot={size='fixed',width=88},onClick=function()
        local ledger=S.Features and S.Features.DailyLedger
        if not Enabled('life_daily_stats')then return false,'请先在左上角开启今日统计'end
        if not ledger or not ledger.SetPaused then return false,'统计接口不可用'end
        local ok,why=ledger:SetPaused(not ledger.paused,'home_toggle');if ok then root:RefreshStats()end;return ok,why
    end})
    -- 共享宿主已有左上诊断时领取同一实例；独立页面宿主仍使用统一 helper。
    D:ModuleDiagnosticsButton(header,'v3_home_diagnostics',66)
    local stats=R:UniformGrid({id='v3_home_stats_grid',parent=root,columns=4,minCellWidth=70,cellHeight=52,minCellHeight=52,gap=6,
        slot={size='auto',hAlign='fill'}})
    local statViews={}
    for _,spec in ipairs({{'gold','金币净变化'},{'honor','荣誉净变化'},{'experience','经验变化'},{'living','生活点净变化'}})do
        local key=spec[1]
        local box=R:GroupBox({id='v3_home_stat_box_'..key,parent=stats,variant='card',headerHeight=0,padding=5,gap=1,slot={hAlign='fill',vAlign='fill'}})
        local content=R:VerticalBox({id='v3_home_stat_content_'..key,parent=box,gap=1,slot={hAlign='fill',vAlign='fill'}})
        Text(content,'v3_home_stat_title_'..key,spec[2],10,'muted',{size='fixed',height=17})
        statViews[key]=Text(content,'v3_home_stat_'..key,'—',14,'default',{size='fill',fill=1})
    end
    local note=Text(root,'v3_home_stats_note','统计只包含已观测变动；未取得数据时显示 —。',10,'muted',{size='fixed',height=20})
    local nav=R:HorizontalBox({id='v3_home_card_navigation',parent=root,gap=6,slot={size='fixed',height=28,hAlign='fill'}})
    local context=Text(nav,'v3_home_workspace_note','我的卡片',10,'muted',{size='fill',fill=1})
    local previous=R:Button({id='v3_home_previous',parent=nav,text='向上',compact=true,slot={size='fixed',width=52},onClick=function()return root.grid:ScrollBy(-1)end})
    local nextButton=R:Button({id='v3_home_next',parent=nav,text='向下',compact=true,slot={size='fixed',width=52},onClick=function()return root.grid:ScrollBy(1)end})
    local empty=Text(root,'v3_home_empty','首页未显示卡片。点击“自定义首页”选择内容；不会自动启用功能。',11,'muted',{size='fixed',height=30})
    empty:SetVisible(false);root.empty=empty
    -- 使用已验证 ScrollBox 轮滚/滚动条契约；只将其滚动单位从“单项”改为“卡片行”。
    -- 不使用未公开裁剪 API：离开视口的整卡隐藏，重排始终保持同一 Native parent。
    local grid=R:ScrollBox({id='v3_home_data_grid',parent=root,gap=GAP,scrollStep=1,scrollbar=true,
        slot={size='fill',fill=1,hAlign='fill',vAlign='fill'}});root.grid=grid
    local function Customize(spec)return S.UIV3.WorkspacePage:Open('lists',spec.key=='activities' and 'activities' or spec.scope)end
    for _,definition in ipairs(W:GetCards(true))do
        local spec={key=definition.id,name=definition.feature,id=definition.featureId,title=definition.name,scope=definition.scope,
            route=definition.route,widgetId=definition.widget,token='home:'..definition.id,prefix='v3_home_'..definition.id..'_'}
        local panel=R:GroupBox({id=spec.prefix..'panel',parent=grid,variant='card',headerHeight=0,padding=8,gap=0,slot={hAlign='fill',vAlign='fill'}})
        local body=R:VerticalBox({id=spec.prefix..'body',parent=panel,gap=5,slot={hAlign='fill',vAlign='fill'}})
        local bar=R:HorizontalBox({id=spec.prefix..'header',parent=body,gap=5,slot={size='fixed',height=27,hAlign='fill'}})
        Text(bar,spec.prefix..'title',spec.title,12,'accent',{size='fill',fill=1})
        R:Button({id=spec.prefix..'open',parent=bar,text='管理',compact=true,slot={size='fixed',width=46},onClick=function()return Open(spec.route)end})
        local widget=R:Button({id=spec.prefix..'widget',parent=bar,text='打开悬浮',compact=true,slot={size='fixed',width=94},onClick=function()
            local ok,why=ToggleFloating(spec.id,spec.widgetId);root:RefreshWidgetButtons();return ok,why
        end})
        local card={spec=spec,feature=S.Features and S.Features[spec.name],held=false,panel=panel,body=body,widgetButton=widget}
        root.cards[#root.cards+1]=card;root.cardByKey[spec.key]=card;panel:SetViewportVisible(false)
        if spec.name=='Trade' or spec.name=='Bonds'then
            local contents=S.UIV3.LifeEconomyContent
            if contents then card.content,card.error=contents:Create(body,spec.name,spec.prefix,{overview=true})end
            if not card.content then Text(body,spec.prefix..'unavailable',card.error or '内容服务未加载',11,'muted')end
        else
            local actions=R:HorizontalBox({id=spec.prefix..'actions',parent=body,gap=5,slot={size='fixed',height=26,hAlign='fill'}})
            card.badge=Text(actions,spec.prefix..'badge','我的关注',10,'muted',{size='fill',fill=1})
            R:Button({id=spec.prefix..'customize',parent=actions,text='自定义',compact=true,slot={size='fixed',width=60},onClick=function()return Customize(spec)end})
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
            card.table=BuildTable({id=spec.prefix..'table',parent=body,items={},rowHeight=26,headerHeight=26,desiredRows=10,overscan=1,
                scrollbar=true,selectable=true,selectionMode='single',columnResize=true,headerInteractive=false,columns=columns,
                getKey=function(item)return item and (item.id or item.key)end,
                -- TableView 的 Activated 是单击，不是假定的双击。任务单击只选中，详情走显式按钮。
                onItemActivated=not isTask and function(item)return Detail(item)end or nil,
                onSelectionChanged=function(index)card.selected=card.table:GetItem(index);if card.detail then card.detail:SetEnabled(card.selected~=nil)end end,
                slot={size='fill',fill=1,hAlign='fill',vAlign='fill'}})
            local footer=R:HorizontalBox({id=spec.prefix..'footer',parent=body,gap=5,slot={size='fixed',height=26,hAlign='fill'}})
            card.status=Text(footer,spec.prefix..'status','',10,'muted',{size='fill',fill=1})
            card.detail=R:Button({id=spec.prefix..'detail',parent=footer,text='详情',compact=true,enabled=false,slot={size='fixed',width=48},onClick=function()return Detail(card.selected)end})
        end
    end
    local function Release(card)
        if not card.held then return true end
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
        for key,view in pairs(statViews)do if not seen[key]then view:SetText('—');view:SetTone('muted')end end
        note:SetText(projection.error and ('账本：'..tostring(projection.error)) or not Enabled('life_daily_stats') and '统计未开启；已保存数据不代表当前仍在统计。'
            or projection.paused and '统计已暂停；已累计结果保留。' or '按服务器日期换日 · 仅统计已观测变动；未连接来源显示 —。')
        return true
    end
    function root:RefreshWidgetButtons()
        local host=S.UIV3.WidgetHost
        for _,card in ipairs(self.cards)do
            local visible=host and host:IsVisible(card.spec.widgetId)
            card.widgetButton:SetText(visible and '隐藏悬浮' or not Enabled(card.spec.id) and '启用并打开' or '打开悬浮')
            card.widgetButton:SetEnabled(host~=nil and type(host.SetVisible)=='function')
        end
        return true
    end
    local function RefreshCard(card)
        if not root.active or card.panel.viewportVisible==false then return Release(card)end
        local available=Enabled(card.spec.id) and card.feature~=nil;local reason='功能未开启'
        if available and not card.held then
            card.held=true -- Acquire 可同步广播，先标记防重复 lease；失败立即回滚。
            local ok,why=card.feature:AcquireConsumer(card.spec.token)
            if not ok then card.held=false;available=false;reason='读取失败：'..tostring(why)end
        elseif not available then Release(card)end
        if card.content then return card.content:SetAvailable(available,reason)end
        if not card.table then return true end
        if not available then
            card.table:SetItems({},'off');card.table:SetViewState('empty',{title=reason,detail='可打开设置，或明确选择“启用并打开”。'})
            card.selected=nil;card.detail:SetEnabled(false);card.badge:SetText('未运行');card.status:SetText(reason);return true
        end
        local rows,revision
        if card.spec.name=='Tasks'then
            local projection=card.feature:GetOverviewProjection({scope=card.spec.scope,view='tracked',status='all',query=''})
            rows=W:ProjectRows('tasks',projection.rows or {});revision=projection.revision
        else rows,revision=card.feature:GetRows();rows=W:ProjectRows('activities',rows or {})end
        card.table:SetItems(rows,tostring(revision or 0)..':'..W.revision)
        card.table:SetViewState(#rows>0 and 'ready' or 'empty',{title='当前没有关注内容',detail='点击自定义选择；完成项也可能已被隐藏。'})
        if card.selected then local selected=nil;for _,row in ipairs(rows)do if (row.id or row.key)==(card.selected.id or card.selected.key)then selected=row;break end end;card.selected=selected end
        card.detail:SetEnabled(card.selected~=nil);card.badge:SetText('我的关注 · '..#rows..' 项')
        card.status:SetText(card.spec.name=='Tasks' and '进度来自任务服务；选中后查看详情' or '时间线 / 区域状态；点击查看任务')
        return true
    end
    function root:RefreshData()
        if not self.active or self.refreshing then return true end
        self.refreshing=true
        local ok,why=xpcall(function()
            self:RefreshStats();self:RefreshWidgetButtons()
            for _,card in ipairs(self.cards)do
                local good,value,err=pcall(RefreshCard,card)
                if not good or value==false then
                    local reason=tostring(good and err or value)
                    if card.status then card.status:SetText('读取失败：'..reason)end
                    if S.DiagnosticsManager then S.DiagnosticsManager:Error('home','HOME_CARD_REFRESH_FAILED',reason,{feature=card.spec.id})end
                end
            end
        end,S.SafeTraceback or tostring)
        self.refreshing=false;return ok,why
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
    function grid:ResolveColumns(w)return w>=700 and 2 or 1 end
    function grid:Measure(w,h)self.desiredWidth=w or 350;self.desiredHeight=math.min(h or 400,600);self.measureDirty=false;return self.desiredWidth,self.desiredHeight end
    function grid:Layout(x,y,w,h)
        w,h=math.max(1,w or 1),math.max(1,h or 1);self:SetBounds(x,y,w,h)
        local definitions=root.visibleDefinitions or W:GetCards();local columns=self:ResolveColumns(w)
        local count=#definitions;local rows=math.ceil(count/columns)
        local target=root.presentation.density=='compact' and 240 or 300
        local visibleRows=math.max(1,math.min(math.max(1,rows),math.floor((h+GAP)/(target+GAP))))
        self.rowEntries={};for i=1,rows do self.rowEntries[i]={child=root.cardByKey[definitions[(i-1)*columns+1].id].panel}end
        self.maxScrollOffset=math.max(0,rows-visibleRows);self.scrollOffset=math.min(self.scrollOffset,self.maxScrollOffset)
        self.visibleStart=self.scrollOffset+1;self.visibleEnd=math.min(rows,self.scrollOffset+visibleRows)
        local reserve=self:GetScrollbarReserve(self.maxScrollOffset>0);local width=math.max(1,(w-reserve-GAP*(columns-1))/columns)
        local cellHeight=math.max(1,(h-GAP*(visibleRows-1))/visibleRows)
        local positions={};for index,definition in ipairs(definitions)do positions[definition.id]=index end
        local changed=false
        for _,card in ipairs(root.cards)do
            local index=positions[card.spec.key];local row=index and math.floor((index-1)/columns)+1
            local show=row~=nil and row>=self.visibleStart and row<=self.visibleEnd
            if (card.panel.viewportVisible~=false)~=show then changed=true end
            card.panel:SetViewportVisible(show)
            if show then card.panel:Layout(((index-1)%columns)*(width+GAP),(row-self.visibleStart)*(cellHeight+GAP),width,cellHeight)end
        end
        self.canScrollBackward=self.scrollOffset>0;self.canScrollForward=self.scrollOffset<self.maxScrollOffset
        previous:SetEnabled(self.canScrollBackward);nextButton:SetEnabled(self.canScrollForward)
        context:SetText(count==0 and '未选择卡片' or ('我的卡片 '..count..' 项 · 第 '..self.visibleStart..'–'..self.visibleEnd..' / '..rows..' 行 · 滚轮翻阅'))
        if self.scrollbar then self.scrollbar:Layout(w-self.scrollbarWidth,0,self.scrollbarWidth,h,visibleRows,math.max(1,rows))end
        if changed then root:QueueRefresh()end
        return h
    end
    function root:RefreshPreferences()
        self.presentation=W:GetSettings();self.visibleDefinitions=W:GetCards();stats:SetVisible(self.presentation.home.stats);note:SetVisible(self.presentation.home.stats)
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
                                if c.content then c.content:Refresh()else needsRefresh=true end
                            end
                        end
                        if needsRefresh then return root:QueueRefresh()end
                        return true
                    end)
                end
            end
            S.Events:SubscribeInternal('v3.daily_ledger.updated',self,function()return root:RefreshStats()end)
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
    root.OnDispose=root.OnDeactivated
    return root
end
