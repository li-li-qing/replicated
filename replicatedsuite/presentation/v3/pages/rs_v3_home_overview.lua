------------------------------------------------------------------------
-- 今日总览 / overview-workbench-3
-- Authority: Feature owns facts/preferences and Commands own writes. This page
-- owns only view selection, controls and its Demand tokens. No native getters
-- in row rendering, no shared widget reparenting, no automatic price queries.
-- Maintenance: the old row pager hid tasks behind an unrelated "下一行" and
-- wasted the header on four unconnected paragraphs. Measured card surfaces,
-- named workspaces and a narrow-width card selector replace that hierarchy.
-- Hidden cards release only our leases. No polling or persistent UI schema.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local R, D = S.RSUI, S.UIV3Design
if type(R) ~= "table" or type(D) ~= "table" then return end
S.UIV3 = S.UIV3 or {}
local Home = { patch="overview-workbench-3" }
S.UIV3.HomeOverview = Home
local TASK = "v3_home_refresh"
local MIN_PAIR_WIDTH = 820
local GAP = 12
local function Enabled(id)
    return S.FeatureRuntime and S.FeatureRuntime:IsEnabled(id) == true
end
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
    local root,err = D:PageRoot(parent,{id="v3_page_home",gap=10,padding=4})
    if not root then return nil,err end
    root.route,root.active,root.cards = route or "home",false,{}
    root.workspace,root.compactChoice = "world",{world=1,tasks=1}
    root.taskFilters = {scope="all",view="tracked",status="all",query=""}
    root.patch = "overview-workbench-2"
    local header = R:HorizontalBox({id="v3_home_header",parent=root,gap=10,slot={size="fixed",height=34,hAlign="fill"}})
    Text(header,"v3_home_header_title","今日总览",19,"accent",{size="fill",fill=1})
    local dateText = Text(header,"v3_home_date","服务器日期 · 等待读取",11,"muted",{size="fixed",width=188})
    -- 中文维护注释（2026-09-18）：首页使用自定义抬头而不是 D:PageHeader，因此只在这里放置
    -- DesignSystem 共享诊断按钮；moduleId/Window/Feature 生命周期全部仍由共享 helper 管理，
    -- 禁止本页直接引用诊断窗口实现。
    D:ModuleDiagnosticsButton(header,"v3_home_diagnostics",76)
    local ledgerToggle = R:Button({id="v3_home_stats_toggle",parent=header,text="暂停统计",compact=true,slot={size="fixed",width=90},
        onClick=function()
            local ledger=S.Features and S.Features.DailyLedger
            -- 维护（module-controls-diag-2）：暂停仅暂停统计，不暗中启动Feature；总开关统一归左上角。
            if not Enabled("life_daily_stats") then return false,"请先从左上角启动今日统计" end
            if type(ledger)~="table" or type(ledger.SetPaused)~="function" then return false,"统计暂停接口不可用" end
            local ok,why=ledger:SetPaused(ledger.paused~=true,"home_toggle")
            if ok then root:QueueRefresh() end
            return ok,why
        end})
    -- GroupBox is a measured surface, unlike a decorative Border wrapping an
    -- unmeasured child. Values stay nil for missing data, not fabricated zeros.
    local stats = R:UniformGrid({id="v3_home_stats_grid",parent=root,minCellWidth=128,maxColumns=4,cellHeight=82,minCellHeight=82,gap=8,
        slot={size="auto",hAlign="fill"}})
    local statViews={}
    for _,spec in ipairs({{"gold","金币净变化"},{"honor","荣誉净变化"},{"experience","经验变化"},{"living","生活点净变化"}}) do
        local key=spec[1]
        local card=R:GroupBox({id="v3_home_stat_box_"..key,parent=stats,variant="card",padding=10,gap=0,headerHeight=0,
            slot={hAlign="fill",vAlign="fill"}})
        local stack=R:VerticalBox({id="v3_home_stat_content_"..key,parent=card,gap=2,slot={hAlign="fill",vAlign="fill"}})
        Text(stack,"v3_home_stat_title_"..key,spec[2],11,"muted",{size="fixed",height=18})
        local value=Text(stack,"v3_home_stat_"..key,"—",18,"default",{size="fixed",height=25})
        local source=Text(stack,"v3_home_stat_source_"..key,"待接入",10,"muted",{size="fixed",height=17})
        statViews[key]={value=value,source=source}
    end
    local note=Text(root,"v3_home_stats_note","按服务器日期换日 · 只统计已观测变动",10,"muted",{size="fixed",height=20,hAlign="fill"})
    local tabRow=R:HorizontalBox({id="v3_home_navigation",parent=root,gap=10,slot={size="fixed",height=30,hAlign="fill"}})
    local tabs=R:SegmentedSelector({id="v3_home_workspace_tabs",parent=tabRow,itemWidth=130,height=28,fontSize=12,gap=4,
        items={{value="world",text="活动与跑商"},{value="tasks",text="任务与居民板"}},
        get=function()return root.workspace end,set=function(v)return root:SetWorkspace(v)end,slot={size="auto"}})
    local context=Text(tabRow,"v3_home_workspace_note","",10,"muted",{size="fill",fill=1})
    local compact=R:SegmentedSelector({id="v3_home_compact_tabs",parent=root,itemWidth=128,height=26,gap=4,
        items={{value=1,text="活动"},{value=2,text="跑商"}},get=function()return root.compactChoice[root.workspace]end,
        set=function(v)return root:SetCompactCard(v)end,slot={size="fixed",height=28,hAlign="fill"}})
    compact:SetVisible(false)
    local grid=R:UniformGrid({id="v3_home_data_grid",parent=root,minCellWidth=390,maxColumns=2,cellHeight=400,minCellHeight=220,gap=GAP,
        slot={size="fill",fill=1,hAlign="fill",vAlign="fill"}})
    local specs={
        {name="Activities",id="life_activities",token="home:activities",title="活动 / 世界状态",prefix="v3_home_activity_",route="life.activities",widgetId="life.activities",topic="v3.activities.updated",workspace="world",position=1},
        {name="Trade",id="life_trade",token="home:trade",title="当前跑商路线",prefix="v3_home_trade_",route="life.trade",widgetId="life.trade",workspace="world",position=2},
        {name="Tasks",id="life_tasks",token="home:tasks",title="我的任务",prefix="v3_home_tasks_",route="life.tasks",widgetId="life.tasks",topic="v3.tasks.updated",workspace="tasks",position=1},
        {name="Bonds",id="life_bonds",token="home:bonds",title="债券 / 居民板",prefix="v3_home_bonds_",route="life.bonds",widgetId="life.bonds",workspace="tasks",position=2},
    }
    local taskCard
    for _,spec in ipairs(specs) do
        local definition=spec -- one binding per Lua 5.1 callback closure
        local panel=R:GroupBox({id=spec.prefix.."panel",parent=grid,variant="card",padding=12,gap=0,headerHeight=0,
            slot={hAlign="fill",vAlign="fill"}})
        local body=R:VerticalBox({id=spec.prefix.."body",parent=panel,gap=7,slot={hAlign="fill",vAlign="fill"}})
        local titleRow=R:HorizontalBox({id=spec.prefix.."header",parent=body,gap=8,slot={size="fixed",height=28,hAlign="fill"}})
        Text(titleRow,spec.prefix.."title",spec.title,13,"accent",{size="fill",fill=1})
        local badge=Text(titleRow,spec.prefix.."badge","",10,"muted",{size="fixed",width=65})
        R:Button({id=spec.prefix.."open",parent=titleRow,text="管理",compact=true,slot={size="fixed",width=52},onClick=function()return Open(definition.route)end})
        local widgetButton = R:Button({id=spec.prefix.."widget",parent=titleRow,text="悬浮",compact=true,slot={size="fixed",width=68},onClick=function()
            local ok, why = ToggleFloating(definition.id, definition.widgetId)
            if type(root.RefreshWidgetButtons) == "function" then root:RefreshWidgetButtons() end
            return ok, why
        end})
        local card={spec=spec,feature=S.Features and S.Features[spec.name],held=false,panel=panel,body=body,badge=badge,widgetButton=widgetButton}
        root.cards[#root.cards+1]=card
        -- Some hosts activate before first arrange. Start with only the first
        -- card visible; measured layout reveals the second and reconciles its
        -- lease. Unarranged task cards must never trigger a hidden acquisition.
        panel:SetViewportVisible(spec.workspace=="world" and spec.position==1)
        if spec.name=="Trade" or spec.name=="Bonds" then
            local contents=S.UIV3.LifeEconomyContent
            if contents then card.content,card.error=contents:Create(body,spec.name,spec.prefix,{overview=true}) end
            if not card.content then Text(body,spec.prefix.."unavailable",card.error or "内容服务未加载",11,"muted") end
        else
            local task=spec.name=="Tasks"
            if task then
                taskCard=card
                local filters=R:HorizontalBox({id=spec.prefix.."filters",parent=body,gap=5,slot={size="fixed",height=28,hAlign="fill"}})
                local function Select(name,items,width)
                    return R:Dropdown({id=spec.prefix..name,parent=filters,items=items,maxVisible=5,
                        get=function()return root.taskFilters[name=="filter" and "status" or name]end,
                        set=function(v)root.taskFilters[name=="filter" and "status" or name]=v;return root:RefreshTasks(true)end,
                        slot={size="fill",fill=1,minWidth=width}})
                end
                Select("scope",{{value="all",text="日常与周常"},{value="daily",text="仅日常"},{value="weekly",text="仅周常"}},84)
                Select("view",{{value="tracked",text="已追踪"},{value="all",text="全部任务"}},76)
                Select("filter",{{value="all",text="全部状态"},{value="unfinished",text="未完成"},{value="ready",text="可交付"},{value="completed",text="已完成"}},76)
                -- 使用现有 TextInput 草稿生命周期；显式搜索按钮不依赖客户端 Enter 事件。
                -- 未提交草稿不触发全表过滤，搜索仅改本页内存状态，不写用户追踪配置。
                local searchRow=R:HorizontalBox({id=spec.prefix.."search_row",parent=body,gap=5,slot={size="fixed",height=28,hAlign="fill"}})
                card.search=R:TextInput({id=spec.prefix.."query",parent=searchRow,placeholder="搜索任务名称 / 分组",maxLength=96,
                    value="",allowEmpty=true,submitOnLostFocus=false,
                    get=function()return root.taskFilters.query end,
                    set=function(v)root.taskFilters.query=tostring(v or "");return true end,
                    onSubmit=function()return root:RefreshTasks(true)end,
                    slot={size="fill",fill=1,minWidth=88}})
                R:Button({id=spec.prefix.."search",parent=searchRow,text="搜索",compact=true,slot={size="fixed",width=48},
                    onClick=function()return card.search:CommitAndEndEditing("home_search")end})
                R:Button({id=spec.prefix.."clear_search",parent=searchRow,text="清空",compact=true,slot={size="fixed",width=48},
                    onClick=function()card.search:CancelEditing("home_search_clear");card.search:SetValue("",false);return root:RefreshTasks(true)end})
                card.summary=Text(body,spec.prefix.."summary","",10,"muted",{size="fixed",height=19})
            end
            local columns=task and {
                {id="cycle",title="周期",field="cycleText",width=46,minWidth=34},
                {id="name",title="任务",field="rawName",size="fill",fill=2,minWidth=85},
                {id="progress",title="进度",field="progressText",width=55,minWidth=40},
                {id="status",title="状态",field="status",width=68,minWidth=50,getTone=function(item)return item.tone or "muted"end},
                {id="tracked",title="追踪",width=48,minWidth=38,getText=function(item)return item.tracked and "已追踪" or "未追踪"end},
            } or {
                {id="name",title="活动",field="shortName",size="fill",minWidth=80,getTone=function(item)return "default"end},
                {id="status",title="状态 / 时间",field="status",size="fill",fill=1.35,minWidth=105,getTone=function(item)return item.tone or "muted"end},
                {id="progress",title="进度",field="progressText",width=55,minWidth=40,getTone=function(item)return item.progressTone or "muted"end},
            }
            card.table=R:TableView({id=spec.prefix.."table",parent=body,items={},rowHeight=26,headerHeight=26,desiredRows=12,overscan=1,
                scrollbar=true,columnResize=true,headerInteractive=false,selectable=task,selectionMode="single",columns=columns,
                getKey=function(item,index)return item and (item.id or item.key) or tostring(index)end,
                slot={size="fill",fill=1,hAlign="fill",vAlign="fill"},
                onItemActivated=not task and function(item)return Detail(item)end or nil,
                onSelectionChanged=task and function(index)root:SelectTask(card.table:GetItem(index))end or nil})
            if task then
                local commands=R:HorizontalBox({id=spec.prefix.."commands",parent=body,gap=6,slot={size="fixed",height=28,hAlign="fill"}})
                card.toggle=R:Button({id=spec.prefix.."toggle",parent=commands,text="选择任务",compact=true,slot={size="fixed",width=94},onClick=function()
                    local item=root.selectedTask
                    if not item or not Enabled("life_tasks") then return false,"请先选择任务"end
                    local ok,why=card.feature.Commands:ToggleTracked(item.scope,item.groupKey,"home_task_tracking")
                    if ok then root:RefreshTasks(false) else card.status:SetText("追踪未保存："..tostring(why)) end
                    return ok,why
                end})
                card.detail=R:Button({id=spec.prefix.."detail",parent=commands,text="任务详情",compact=true,slot={size="fixed",width=82},onClick=function()return Detail(root.selectedTask)end})
                Text(commands,spec.prefix.."hint","选中管理 · 点击查看详情",10,"muted",{size="fill",fill=1})
                card.toggle:SetEnabled(false);card.detail:SetEnabled(false)
            end
            card.status=Text(body,spec.prefix.."status","",10,"muted",{size="fixed",height=19})
        end
    end
    function root:SelectTask(item)
        self.selectedTask=item
        if taskCard then
            taskCard.toggle:SetEnabled(item~=nil and Enabled("life_tasks"))
            taskCard.toggle:SetText(item and (item.tracked and "取消追踪" or "加入追踪") or "选择任务")
            taskCard.detail:SetEnabled(item~=nil and Enabled("life_tasks"))
        end
        return true
    end
    function root:RefreshTasks(resetScroll)
        if not self.active or not taskCard or not taskCard.held then return true end
        local f=taskCard.feature
        if type(f.GetOverviewProjection)~="function" then return false,"任务总览投影未加载"end
        local projection=f:GetOverviewProjection(self.taskFilters)
        local rows,summary=projection.rows or {},projection.summary or {}
        local wanted=self.selectedTask and self.selectedTask.id
        taskCard.table:SetItems(rows,projection.revision or 0)
        taskCard.table:SetViewState(#rows>0 and "ready" or "empty",{title="没有符合条件的任务",detail="切换为全部任务，或调整周期与状态筛选。"})
        if resetScroll and type(taskCard.table.ScrollToTop)=="function" then taskCard.table:ScrollToTop()end
        local selected
        if wanted then for _,item in ipairs(rows)do if item.id==wanted then selected=item;break end end end
        self:SelectTask(selected)
        taskCard.badge:SetText(tostring(#rows).." 组")
        taskCard.summary:SetText(string.format("已追踪 %d · 已完成 %d · 可交付 %d · 未完成 %d",summary.tracked or 0,summary.completed or 0,summary.ready or 0,summary.unfinished or 0))
        taskCard.status:SetText((summary.unavailable or 0)>0 and ("其中 "..summary.unavailable.." 组进度暂不可用；不会标为完成") or "进度来自任务服务 · 选择不影响其他窗口")
        return true
    end
    local function Release(card)
        if not card.held then return true end
        if not Enabled(card.spec.id) then card.held=false;return true end -- disabled Feature already clears its Demand
        local ok,why=card.feature:ReleaseConsumer(card.spec.token)
        if ok==true then card.held=false end
        return ok,why
    end
    local function RefreshCard(card)
        local visible=card.panel.viewportVisible~=false and root.active
        if not visible then return Release(card)end
        local available=Enabled(card.spec.id) and type(card.feature)=="table"
        local why="功能已关闭"
        if available and not card.held then
            card.held=true -- Acquire may publish synchronously; avoid a duplicate lease.
            local ok,reason=card.feature:AcquireConsumer(card.spec.token)
            if ok~=true then card.held=false;available=false;why="读取失败："..tostring(reason)end
        elseif not available then Release(card)end
        card.badge:SetText(available and "实时" or "已关闭")
        if card.content then return card.content:SetAvailable(available,why)end
        if not available then
            card.table:SetItems({},"off");card.table:SetViewState("empty",{title=why,detail="点击管理可启用；总览不会自动开启功能。"})
            card.status:SetText(why)
            if card==taskCard then root:SelectTask(nil);card.summary:SetText("")end
            return true
        end
        if card==taskCard then return root:RefreshTasks(false)end
        local rows,revision=card.feature:GetRows();rows=type(rows)=="table" and rows or {}
        card.table:SetItems(rows,revision or 0);card.table:SetViewState(#rows>0 and "ready" or "empty",{title="暂无活动",detail="检查活动页的显示选择。"})
        local active=0;for _,item in ipairs(rows)do if item.active then active=active+1 end end
        card.badge:SetText(tostring(#rows).." 项")
        card.status:SetText("当前 "..active.." · 显示 "..#rows.." 项 · 点击查看详情")
        return true
    end
    function root:RefreshWidgetButtons()
        local host = S.UIV3 and S.UIV3.WidgetHost or nil
        for _, card in ipairs(self.cards) do
            if card.widgetButton ~= nil then
                local visible = type(host) == "table" and type(host.IsVisible) == "function" and host:IsVisible(card.spec.widgetId) == true
                card.widgetButton:SetText(visible and "关闭悬浮" or "悬浮")
                card.widgetButton:SetEnabled(type(host) == "table" and type(host.SetVisible) == "function")
            end
        end
        return true
    end

    function root:RefreshStats()
        if not self.active then return true end
        local ledger=S.Features and S.Features.DailyLedger
        local projection=ledger and ledger:GetProjection() or {rows={},error="账本未加载"}
        dateText:SetText((not Enabled("life_daily_stats") and "统计日期 · " or projection.clockAvailable==false and "上次确认 · " or "服务器日期 · ")..tostring(projection.day or "等待读取"))
        ledgerToggle:SetText(not Enabled("life_daily_stats") and "统计未开启" or projection.paused==true and "继续统计" or "暂停统计")
        ledgerToggle:SetEnabled(Enabled("life_daily_stats"))
        local ready=0
        for _,row in ipairs(projection.rows or {})do
            local view=statViews[row.key]
            if view then
                view.value:SetText(Amount(row));view.value:SetTone(type(row.value)=="number" and (row.value<0 and "orange" or "green") or "default")
                local state=({unconnected="待接入",probing="监听中 · 等待变化",baselined="基线已建立 · 等待变化",unavailable="数据不可用",waiting="等待首条变化",off="已关闭",paused="已暂停",ready="本日已观测",retained="已保存 · 等待新观测"})[row.status] or "数据不可用"
                view.source:SetText(state..(row.coverageGap and " · 已修正旧统计" or ""))
                if row.status=="ready" or row.status=="retained"then ready=ready+1 end
            end
        end
        note:SetText(projection.error and ("账本状态："..tostring(projection.error)) or projection.paused==true and "统计已暂停 · 今日已累计结果保留 · 点击继续统计恢复监听" or
            (ready==0 and ((projection.verifiedSources or 0)==0 and "金币/荣誉/经验/生活点监听已启动 · 等待首次真实变化" or "收益来源等待首条变化") or "按服务器自然日重置 · Native变化到达后立即刷新"))
        return true
    end
    function root:RefreshData()
        if not self.active or self.refreshing then return true end
        self.refreshing=true
        local ok,why=xpcall(function()
            root:RefreshStats()
            root:RefreshWidgetButtons()
            for _,card in ipairs(self.cards)do
                local success,result,reason=pcall(RefreshCard,card)
                if not success or result==false then
                    local errText=tostring(success and reason or result)
                    card.error=errText
                    if card.status then card.status:SetText("读取失败："..errText)end
                    if card.content then card.content:SetAvailable(false,"读取失败："..errText)end
                    if S.DiagnosticsManager then S.DiagnosticsManager:Error("home","HOME_CARD_REFRESH_FAILED",errText,{feature=card.spec.id})end
                end
            end
        end,S.SafeTraceback or tostring)
        self.refreshing=false
        return ok,why
    end
    function root:QueueRefresh()
        if not self.active or self.refreshing or self.refreshQueued then return true end
        self.refreshQueued=true
        if S.Scheduler and type(S.Scheduler.AddOneShot)=="function" then
            local ok=S.Scheduler:AddOneShot(TASK,100,function()root.refreshQueued=false;if root.active then return root:RefreshData()end;return true end,self,"P3",1)
            if ok then return true end
        end
        self.refreshQueued=false;return self:RefreshData()
    end
    -- Fixed card parents and a bounded 2-column layout. No clipping tricks or
    -- reparenting; small widths expose a named selector rather than hiding the
    -- second panel behind a row index. Layout schedules demand reconciliation
    -- only when visibility changes, never performs Native reads itself.
    function grid:ResolveColumns(width) return width>=MIN_PAIR_WIDTH and 2 or 1 end
    function grid:Measure(w,h)self.desiredWidth=w or 360;self.desiredHeight=math.min(h or 400,400);self.measureDirty=false;return self.desiredWidth,self.desiredHeight end
    function grid:Layout(x,y,w,h)
        w,h=math.max(1,w or 1),math.max(1,h or 1);self:SetBounds(x,y,w,h)
        local columns=self:ResolveColumns(w);local changed=false
        local narrow=columns==1
        if compact.visible~=narrow then compact:SetVisible(narrow)end
        local firstWidth=columns==1 and w or math.floor((w-GAP)*(root.workspace=="world" and 0.46 or 0.55))
        for _,card in ipairs(root.cards)do
            local show=card.spec.workspace==root.workspace and (columns==2 or card.spec.position==root.compactChoice[root.workspace])
            if (card.panel.viewportVisible~=false)~=show then changed=true end
            -- Hidden native input must release its draft/keyboard lease, even
            -- when only changing an in-page workspace rather than the full route.
            if not show and card.search and card.search:IsEditing() then card.search:CancelEditing("home_task_card_hidden") end
            card.panel:SetViewportVisible(show)
            if show then
                local right=columns==2 and card.spec.position==2
                card.panel:Layout(right and firstWidth+GAP or 0,0,right and (w-GAP-firstWidth)or firstWidth,h)
            end
        end
        context:SetText(root.workspace=="world" and "共享实时数据 · 不自动询价" or "日常 / 周常筛选 · 追踪与详情")
        if changed and root.active then root:QueueRefresh()end
        return h
    end
    function root:SetWorkspace(value)
        if value~="world" and value~="tasks"then return false,"无效总览页签"end
        self.workspace=value
        compact.items=value=="world" and {{value=1,text="活动"},{value=2,text="跑商"}} or {{value=1,text="任务追踪"},{value=2,text="居民板"}}
        if type(compact.SetItems)=="function"then compact:SetItems(compact.items)end
        tabs:Render();compact:Render()
        if grid.width then grid:Layout(grid.x,grid.y,grid.width,grid.height)end
        if S.Scheduler then S.Scheduler:RemoveTask(TASK)end;self.refreshQueued=false
        return self:RefreshData()
    end
    function root:SetCompactCard(value)
        value=tonumber(value);if value~=1 and value~=2 then return false,"无效卡片"end
        self.compactChoice[self.workspace]=value;compact:Render()
        if grid.width then grid:Layout(grid.x,grid.y,grid.width,grid.height)end
        if S.Scheduler then S.Scheduler:RemoveTask(TASK)end;self.refreshQueued=false
        return self:RefreshData()
    end
    function root:OnActivated()
        if self.active then return self:RefreshData()end
        self.active=true
        if S.Events then
            for _,card in ipairs(self.cards)do
                local c=card
                local topic=c.spec.topic or (c.feature and c.feature.UpdateTopic)
                if topic then S.Events:SubscribeInternal(topic,self,function()
                    if c.panel.viewportVisible==false then return true end
                    -- 中文维护注释（trade-home-immediate-projection-1）：完整跑商页直接消费 Feature 更新，而首页过去把
                    -- Trade 结果也塞进共享 100ms 全页刷新队列。Native 货率已经返回时，首页可能仍停留在“正在查询/暂无货率”，
                    -- 形成“跑商页有数据、今日总览没数据”的双视图分叉。Trade 更新频率低且只影响自己的轻量内容，
                    -- 因此可见时直接刷新本卡；其它首页卡仍走 QueueRefresh，避免扩大高频重绘。
                    if c.spec.name=="Trade" and c.content and type(c.content.Refresh)=="function" then
                        return c.content:Refresh()
                    end
                    return root:QueueRefresh()
                end)end
            end
            -- Maintenance (overview-workbench-3): money/honor/living events are user-visible
            -- transaction feedback. Updating four stat labels is bounded and does not touch Native
            -- APIs or economy tables, so do it synchronously instead of competing for the shared
            -- P3 100ms one-shot queue. If a full card refresh is already in progress, that call
            -- already invokes RefreshStats and the event can safely coalesce into it.
            S.Events:SubscribeInternal("v3.daily_ledger.updated",self,function()
                if root.refreshing then return true end
                return root:RefreshStats()
            end)
            S.Events:SubscribeInternal("v3.feature.lifecycle",self,function(_,id)
                for _,card in ipairs(root.cards)do if card.spec.id==id and not Enabled(id)then card.held=false end end
                return root:QueueRefresh()
            end)
        end
        return self:RefreshData()
    end
    function root:OnDeactivated()
        self.active=false;self.refreshQueued=false
        if S.Events then S.Events:UnsubscribeInternalOwner(self)end
        if S.Scheduler then S.Scheduler:RemoveTask(TASK)end
        if taskCard and taskCard.search then taskCard.search:CancelEditing("home_hidden") end
        local ok,why=true,nil
        for _,card in ipairs(self.cards)do local released,reason=Release(card);if released~=true then ok=false;why=reason end end
        return ok,why
    end
    root.OnDispose=root.OnDeactivated
    return root
end
