------------------------------------------------------------------------
-- Replicated Suite V3 - DPS Page
--
-- Rich live projection for combat statistics. Presentation consumes only DPS
-- Feature Projection/Commands; no native combat/target API is read here.
------------------------------------------------------------------------
-- 维护（module-controls-diag-2）：总开关领取PageHost左上角的同一实例；原Feature/Consumer/保存回滚回调不变。
-- 只调整呈现归属，禁止在刷新中另造开关状态、重设Native父级或绑定第二个OnClick；局部选项开关保持原位。
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local RSUI, D = S.RSUI, S.UIV3Design
local PageHost = S.UIV3 and S.UIV3.PageHost or nil
local WidgetHost = S.UIV3 and S.UIV3.WidgetHost or nil
local Feature = S.Features and S.Features.DPS or nil
if type(RSUI) ~= "table" or type(D) ~= "table" or type(PageHost) ~= "table" or type(WidgetHost) ~= "table" or type(Feature) ~= "table" then return end

local FEATURE_ID, STORE_ID = "combat_stats", "v3.dps"
local CLEAR_CONFIRM_TASK = "v3_dps_clear_confirm_expire"
local function Settings() return Feature:GetSettingsProjection() end

local function N(value) return math.max(0, math.floor((tonumber(value) or 0) + 0.5)) end
local function ModeText(value) return tostring(value or "PVE") == "PVP" and "PVP" or "PVE" end
local function MetricText(value)
    value = tostring(value or "damage")
    if value == "taken" then return "承伤" end
    if value == "heal" then return "治疗" end
    return "伤害"
end
local function CompactNumber(value)
    local n = tonumber(value) or 0
    local abs = math.abs(n)
    if abs < 1000 then return tostring(math.floor(n + 0.5)) end
    if abs >= 1000000000 then return string.format(abs >= 100000000000 and "%.0fB" or "%.1fB", n / 1000000000) end
    if abs >= 1000000 then return string.format(abs >= 100000000 and "%.0fM" or "%.1fM", n / 1000000) end
    return string.format(abs >= 100000 and "%.0fK" or "%.1fK", n / 1000)
end
local function TotalsText(label, projected, shownRows)
    projected = type(projected) == "table" and projected or {}
    local totals = type(projected.totals) == "table" and projected.totals or {}
    local shown = math.max(0, tonumber(shownRows) or #(projected.rows or {}))
    local total = math.max(0, tonumber(projected.totalRows) or shown)
    local suffix = total > shown and (" · 显示 " .. tostring(shown) .. "/" .. tostring(total)) or ""
    return tostring(label) .. " · 伤 " .. CompactNumber(totals.damage)
        .. " · 承 " .. CompactNumber(totals.taken)
        .. " · 治 " .. CompactNumber(totals.heal)
        .. " · 单位 " .. tostring(N(totals.actorCount)) .. suffix
end

local function RankingColumns()
    local function Score(field)
        return function(row)
            return row.statsAvailable and tostring(N(row[field])) or "关闭"
        end
    end
    return {
        { id = "rank", title = "#", field = "rank", size = "fixed", width = 26, minWidth = 20, sortable = false,
            getTone = function(row) return row.self == true and "accent" or "default" end },
        { id = "name", title = "玩家 / 单位", field = "name", size = "fill", minWidth = 60, fill = 1 },
        { id = "damage", title = "伤害", field = "damage", size = "fixed", width = 76, minWidth = 42,
            format = CompactNumber, getTone = function() return "red" end },
        { id = "kills", title = "击杀玩家", field = "kills", size = "fixed", width = 76, minWidth = 56, getText=Score("kills") },
        { id = "heal", title = "治疗", field = "heal", size = "fixed", width = 76, minWidth = 42,
            format = CompactNumber, getTone = function() return "green" end },
        { id = "taken", title = "承伤", field = "taken", size = "fixed", width = 76, minWidth = 42, format = CompactNumber },
        { id = "deaths", title = "死亡", field = "deaths", size = "fixed", width = 46, minWidth = 28, getText=Score("deaths") },
    }
end

local function CounterpartColumns(nameTitle)
    return {
        { id = "rank", title = "#", field = "rank", size = "fixed", width = 28, minWidth = 24, sortable = false },
        { id = "name", title = nameTitle, field = "name", size = "fill", minWidth = 90, fill = 1 },
        { id = "amount", title = "数值", field = "amount", size = "fixed", width = 78, minWidth = 60, format = CompactNumber },
        { id = "events", title = "次数", field = "events", size = "fixed", width = 52, minWidth = 44 },
    }
end

local function AbilityColumns()
    return {
        { id = "icon", title = "", field = "iconPath", cellType = "icon", iconSize = 18, fallbackIcon = "ui/icon/icon_unknown_item.dds",
            size = "fixed", width = 26, minWidth = 24, sortable = false, resizable = false },
        { id = "name", title = "技能", field = "name", size = "fill", minWidth = 88, fill = 1 },
        { id = "skillId", title = "技能ID", field = "skillIdText", size = "fixed", width = 62, minWidth = 52 },
        { id = "amount", title = "数值", field = "amount", size = "fixed", width = 70, minWidth = 56,
            getText=function(row)return row.killOnly and "—" or CompactNumber(row.amount)end },
        { id = "share", title = "占比", field = "shareText", size = "fixed", width = 50, minWidth = 44 },
        { id = "events", title = "次数", field = "events", size = "fixed", width = 46, minWidth = 40,
            getText=function(row)return row.killOnly and "—" or tostring(N(row.events))end },
        { id = "kills", title = "击杀玩家", field = "kills", size = "fixed", width = 74, minWidth = 54,
            getText=function(row)return row.skillKillsAvailable==false and "—" or tostring(N(row.kills))end },
    }
end

local function CopyAndSortRows(source, sortState, limit)
    local rows = {}
    for _, row in ipairs(type(source) == "table" and source or {}) do
        local copy = {}
        for key, value in pairs(row) do copy[key] = value end
        rows[#rows + 1] = copy
    end
    sortState = type(sortState) == "table" and sortState or {}
    local columnId = tostring(sortState.columnId or "")
    local direction = tostring(sortState.direction or "desc")
    if columnId ~= "" and direction ~= "none" then
        local sign = direction == "asc" and 1 or -1
        table.sort(rows, function(a, b)
            local av, bv
            if columnId == "name" then
                av, bv = tostring(a.name or a.key or ""), tostring(b.name or b.key or "")
                if av ~= bv then if sign>0 then return av<bv else return av>bv end end
            else
                av, bv = tonumber(a[columnId]) or 0, tonumber(b[columnId]) or 0
                if av ~= bv then if sign>0 then return av<bv else return av>bv end end
            end
            return tostring(a.name or a.key or "") < tostring(b.name or b.key or "")
        end)
    end
    limit = math.max(1, math.floor(tonumber(limit) or #rows))
    while #rows > limit do rows[#rows] = nil end
    for index, row in ipairs(rows) do row.rank = index end
    return rows
end

local function PendingRows(projected, metric)
    local rows = {}
    for _, row in ipairs(type(projected) == "table" and projected.rows or {}) do
        rows[#rows + 1] = {
            rank = tonumber(row.rank) or (#rows + 1),
            name = tostring(row.name or row.key or "未知单位"),
            amount = math.max(0, tonumber(row.metricValue or row[metric]) or 0),
            events = math.max(0, tonumber(row.events) or 0),
        }
    end
    return rows
end

local function SetTableItems(view,rows,token)
    -- 同一投影/选择版本不重复触发 ListView 的 items_changed 排版；新事件、排序、模式仍重新提交。
    if view.dpsItemsToken==token then return true end
    local ok=view:SetItems(rows,token)
    if ok==true then view.dpsItemsToken=token end
    return ok
end

local function Build(parent, route)
    local loaded,loadErr=Feature:EnsureStoreLoaded()
    if loaded~=true then error("战斗统计设置读取失败："..tostring(loadErr)) end
    local root, rootErr = D:PageRoot(parent, {id="v3_page_dps",gap=7,padding=4})
    if root == nil then error("DPS PageRoot 创建失败：" .. tostring(rootErr or "unknown")) end
    root.route = route
    root.subscribed = false
    root.clearConfirmUntil = 0
    root.selectedActorKey = nil
    root.selectedSide = nil
    root.pendingView = false
    root.detailView = "skills"
    root.selectedSkillKillKey=nil
    root.rankingSide = "all"
    root.overviewRows = {}
    root.rankingSort = { columnId = "damage", direction = "desc" }
    root.detailMode=Settings().mode or "PVE"

    D:PageHeader(root, "v3_dps_header", "战斗统计与分析 · 战斗总览",
        "每人一行显示伤害、治疗、承伤、击杀玩家、死亡；汇总当前统计期，点击行查看技能明细。")
    local statisticsScope=D:CombatStatisticsControls(root,"damage")

    local function NowMs() return math.max(0, tonumber(S.NowMs and S.NowMs()) or 0) end
    local clear
    local function RefreshClearButton()
        local confirming = (tonumber(root.clearConfirmUntil) or 0) >= NowMs()
        if clear ~= nil then clear:SetText(confirming and "确认清空" or "清空实时") end
        return confirming
    end

    local top = RSUI:UniformGrid({ id = "v3_dps_top", parent = root, columnGap=6,rowGap=4,minCellWidth=100,minCellHeight=30,maxColumns=5,preferredColumns=5,
        slot = { size = "auto", hAlign = "fill" } })
    local enableBtn = D:ModuleToggleButton({ id = "v3_dps_enable", parent = top, text = "启用伤害统计", compact = true,
        slot = { hAlign = "fill",vAlign="fill" } })
    -- FloatingSurface already owns logical id `v3_dps_widget`.  Page controls
    -- must never alias a floating root because V3 component IDs are ownership
    -- identities, not labels.
    local showWidget = RSUI:Button({ id = "v3_dps_widget_toggle", parent = top, text = "显示悬浮窗", compact = true,
        slot = { hAlign="fill",vAlign="fill" } })
    clear = RSUI:Button({ id = "v3_dps_clear", parent = top, text = "清空统计", compact = true,
        slot = { hAlign="fill",vAlign="fill" } })
    local pendingBtn = RSUI:Button({ id = "v3_dps_pending_view", parent = top, text = "查看待确认", compact = true,
        slot = { hAlign="fill",vAlign="fill" } })
    local advancedBtn = RSUI:Button({ id = "v3_dps_advanced_toggle", parent = top, text = "统计设置", compact = true,
        slot = { hAlign="fill",vAlign="fill" } })
    local healthText = RSUI:Text({ id = "v3_dps_health", parent = root, text = "--", fontSize = 9, tone = "muted",
        overflow = "ellipsis", slot = { size="fixed",height=18,hAlign="fill" } })

    local modeToggle,metricSelector

    local body = RSUI:VerticalBox({ id = "v3_dps_body", parent = root, gap = 6,
        slot = { size = "fill", fill = 1, hAlign = "fill", vAlign = "fill" } })
    -- 基础统计共用一个全宽列表，阵营只是过滤条件，不再拆两张窄表。
    local rankingSideSelector = RSUI:SegmentedSelector({
        id="v3_dps_ranking_side",parent=body,itemWidth=100,gap=3,
        items={{value="all",text="全部单位"},{value="friendly",text="友方 / 自己"},{value="enemy",text="敌方 / 目标"}},
        get=function() return root.rankingSide end,
        set=function(value)
            root.rankingSide=value=="enemy" and "enemy" or (value=="friendly" and "friendly" or "all")
            return root:RefreshStats()
        end,
        slot={size="fixed",height=28,hAlign="fill"},
    })
    local rankings = RSUI:HorizontalBox({ id = "v3_dps_rankings", parent = body, gap = 6,
        slot = { size = "fill", fill = 1.35, hAlign = "fill", vAlign = "fill" } })

    local function RankingPanel()
        local panel = RSUI:Border({ id = "v3_dps_overview_panel", parent = rankings, padding = 4, variant = "card",
            slot = { size = "fill", fill = 1, hAlign = "fill", vAlign = "fill" } })
        local stack = RSUI:VerticalBox({ id = "v3_dps_overview_stack", parent = panel, gap = 3 })
        local summary = RSUI:Text({ id = "v3_dps_overview_summary", parent = stack, text = "当前统计期 · 尚无数据",
            fontSize = 10, tone = "strong", overflow = "ellipsis", slot = { size = "fixed", height = 20 } })
        local tableView = RSUI:TableView({
            id = "v3_dps_overview_table", parent = stack, items = {}, rowHeight = 24, headerHeight = 24, desiredRows = 6,
            columnGap=1,cellPaddingX=2,rowFontSize=10,headerFontSize=9,
            scrollbar = true, selectable = true, selectionMode = "single", columnResize = true, headerInteractive = true, columns = RankingColumns(),
            onSortChanged = function(columnId, direction, view)
                if type(root.ApplyRankingSort) == "function" then return root:ApplyRankingSort(columnId, direction, view) end
                return false
            end,
            onSelectionChanged = function(index)
                if index ~= nil and type(root.SelectActor) == "function" then root:SelectActor(index) end
            end,
            slot = { size = "fill", fill = 1, hAlign = "fill", vAlign = "fill" },
        })
        return { panel = panel, summary = summary, table = tableView }
    end

    local overviewPanel=RankingPanel()
    overviewPanel.table:SetSortState("damage","desc",false)

    function root:UpdateRankingLayout(selfOnly)
        -- 中文维护（2026-10-07）：短正文先保住一个玩家行，再给可滚动明细留空间；不改表格列/采集。
        local rankingHeight=116
        if selfOnly and self.detailExpanded and tonumber(self.lastBodyHeight) then
            rankingHeight=math.max(80,math.min(116,self.lastBodyHeight-102))
        end
        local token=tostring(selfOnly)..":"..tostring(rankingHeight)
        if self.rankingLayoutToken==token then return true end
        self.rankingLayoutToken=token
        rankingSideSelector:SetVisible(not selfOnly)
        rankings:SetSlot(selfOnly and {size="fixed",height=rankingHeight,hAlign="fill"}
            or {size="fill",fill=1.35,hAlign="fill",vAlign="fill"})
        rankingSideSelector:Render()
        return true
    end

    local detailPanel = RSUI:Border({ id = "v3_dps_detail_panel", parent = body, padding = 5, variant = "card",
        slot = { size = "fill", fill = 0.85, hAlign = "fill", vAlign = "fill" } })
    -- 中文维护：明细头部和表格在高度不足时逐项滚动，不能把固定控件压进 1px 的表格中。
    local detailStack = RSUI:ScrollBox({ id = "v3_dps_detail_stack", parent = detailPanel, gap = 3,
        scrollStep=1,scrollbar=true,scrollbarWidth=14,scrollbarGap=4 })
    local detailSummary = RSUI:Text({ id = "v3_dps_detail_summary", parent = detailStack,
        text = "明细：点击上方任意单位", fontSize = 10, tone = "strong", overflow = "ellipsis",minHeight=20,
        slot = { size = "fixed", height = 20 } })
    -- 类型筛选属于所选人的技能明细，主列表的基础统计始终一起显示。
    local detailFilters=RSUI:HorizontalBox({id="v3_dps_detail_filters",parent=detailStack,gap=6,minHeight=30,slot={size="fixed",height=30,hAlign="fill"}})
    modeToggle=RSUI:Toggle({id="v3_dps_mode",parent=detailFilters,onText="明细模式：PVE",offText="明细模式：PVP",
        get=function()return root.detailMode=="PVE"end,set=function(v)root.detailMode=v and "PVE" or "PVP";return root:RefreshDetail()end,
        slot={size="fixed",width=150}})
    metricSelector=RSUI:SegmentedSelector({id="v3_dps_metric",parent=detailFilters,itemWidth=50,gap=2,
        items={{value="damage",text="伤害"},{value="taken",text="承伤"},{value="heal",text="治疗"}},
        get=function()return Settings().metric or "damage"end,
        set=function(v)return Feature.Commands:ApplySettingFromBinding("metric",v)end,
        storeId=STORE_ID,persistDelayMs=300,persistReason="dps_metric",slot={size="fixed",width=154}})
    if not metricSelector then error("技能明细选择器创建失败") end
    local detailSelector=RSUI:SegmentedSelector({id="v3_dps_detail_selector",parent=detailStack,itemWidth=100,gap=3,minHeight=28,
        items={{value="skills",text="技能明细"},{value="counterparts",text="目标 / 来源"},{value="kill_targets",text="击杀名单"}},
        get=function() return root.detailView end,set=function(value)
            root.detailView=value
            if value=="kill_targets" then root.selectedSkillKillKey=nil end
            return root:RefreshDetail()
        end,
        slot={size="fixed",height=28,hAlign="fill"}})
    local detailViewport=RSUI:SizeBox({id="v3_dps_detail_viewport",parent=detailStack,heightOverride=127,
        slot={size="auto",hAlign="fill"}})
    local detailTables = RSUI:HorizontalBox({ id = "v3_dps_detail_tables", parent = detailViewport, gap = 6,
        slot = { size = "fill", fill = 1, hAlign = "fill", vAlign = "fill" } })
    function root:SelectKillSkill(index)
        local row=index and self.abilityRows and self.abilityRows[index]
        if not row or not row.killSkillKey or (tonumber(row.kills) or 0)<=0 then return false end
        if self.selectedSkillKillKey==row.killSkillKey and self.detailView=="kill_targets" then return true end
        self.selectedSkillKillKey=row.killSkillKey;self.detailView="kill_targets"
        return self:RefreshDetail()
    end
    local abilityTable = RSUI:TableView({
        id = "v3_dps_ability_table", parent = detailTables, items = {}, rowHeight = 21, headerHeight = 22, desiredRows = 5,
        scrollbar = true, selectable = true, selectionMode="single", columnResize = true, columns = AbilityColumns(),
        onSelectionChanged=function(index)return root:SelectKillSkill(index)end,
        onItemActivated=function(_,index)return root:SelectKillSkill(index)end,
        slot = { size = "fill", fill = 1, hAlign = "fill", vAlign = "fill" },
    })
    local counterpartTable = RSUI:TableView({
        id = "v3_dps_counterpart_table", parent = detailTables, items = {}, rowHeight = 21, headerHeight = 22, desiredRows = 5,
        scrollbar = true, selectable = false, columnResize = true, columns = CounterpartColumns("目标/来源"),
        slot = { size = "fill", fill = 1, hAlign = "fill", vAlign = "fill" },
    })
    local pendingModeTable = RSUI:TableView({
        -- 其它待确认表继续只显示金额，不参与玩家击杀归属。
        id = "v3_dps_pending_mode_table", parent = detailTables, items = {}, rowHeight = 21, headerHeight = 22, desiredRows = 5,
        scrollbar = true, selectable = false, columnResize = true, columns = CounterpartColumns("模式未定单位"),
        slot = { size = "fill", fill = 1, hAlign = "fill", vAlign = "fill" },
    })
    local pendingSideTable = RSUI:TableView({
        id = "v3_dps_pending_side_table", parent = detailTables, items = {}, rowHeight = 21, headerHeight = 22, desiredRows = 5,
        scrollbar = true, selectable = false, columnResize = true, columns = CounterpartColumns("阵营未定单位"),
        slot = { size = "fill", fill = 1, hAlign = "fill", vAlign = "fill" },
    })
    pendingModeTable:SetVisible(false)
    pendingSideTable:SetVisible(false)
    local skillKillTargetsTable=RSUI:TableView({id="v3_dps_skill_kill_targets_table",parent=detailTables,items={},
        rowHeight=21,headerHeight=22,desiredRows=5,scrollbar=true,selectable=false,columnResize=true,
        columns={{id="name",title="被击杀玩家",field="name",size="fill",fill=1,minWidth=90},
            {id="skill",title="技能",field="skillName",size="fill",fill=1,minWidth=100},
            {id="kills",title="击杀次数",field="kills",size="fixed",width=74,minWidth=54}},
        slot={size="fill",fill=1,hAlign="fill",vAlign="fill"}})
    skillKillTargetsTable:SetVisible(false)

    local bodyLayout,detailLayout=body.Layout,detailStack.Layout
    function body:Layout(x,y,width,height)
        root.lastBodyHeight=tonumber(height)
        root:UpdateRankingLayout(statisticsScope:GetValue()=="self")
        return bodyLayout(self,x,y,width,height)
    end
    function detailStack:Layout(x,y,width,height)
        -- 明细表格正常时填满剩余空间；短面板保留表头/至少一行（空状态也需32px），其它行可滚动。
        local fixed,count=0,0
        for _,entry in ipairs(self.slots)do
            if entry.child.visible~=false and entry.child~=detailViewport then
                local _,h=RSUI.LayoutUtil.Measure(entry.child,width,nil)
                fixed=fixed+math.max(tonumber(entry.slot.height)or 0,h);count=count+1
            end
        end
        local target=math.min(math.max(1,tonumber(height)or 1),math.max(64,(tonumber(height)or 1)-fixed-self.gap*count))
        if detailViewport.spec.heightOverride~=target then
            detailViewport.spec.heightOverride=target;detailViewport:InvalidateMeasure("detail_viewport_height")
        end
        return detailLayout(self,x,y,width,height)
    end

    -- 采集校验由模块诊断展示；HUD/首领配置归统计设置，结果页不堆叠低频控制。

    function root:ApplyRankingSort(columnId, direction, view)
        columnId = tostring(columnId or "")
        direction = tostring(direction or "none")
        -- Ranking headers use a two-state sort. Generic TableView cycles
        -- asc -> desc -> none; on the third state it reports columnId=nil. A
        -- ranking cannot have a meaningful unsorted state, so interpret that
        -- transition as ascending on the previous column. The next click then
        -- becomes descending again: desc <-> asc with visible feedback.
        if direction == "none" then
            local previous = self.rankingSort.columnId
            columnId = tostring(previous or Settings().metric or "damage")
            direction = "asc"
            if view ~= nil and type(view.SetSortState) == "function" then
                view:SetSortState(columnId, direction, false)
            end
        end
        local supported={name=true,damage=true,taken=true,heal=true,kills=true,deaths=true}
        if not supported[columnId] then return false,"统计列不可用" end
        if columnId == "damage" or columnId == "taken" or columnId == "heal" then
            local settingsValue = Settings()
            if tostring(settingsValue.metric or "damage") ~= columnId then
                local ok, err = Feature.Commands:SetMetric(columnId)
                if ok ~= true then return false, err end
            end
        end
        local overview=Feature:GetCombatOverview()
        if (columnId=="kills" or columnId=="deaths") and not overview.statsAvailable then
            if view then view:SetSortState(self.rankingSort.columnId,self.rankingSort.direction,false) end
            return false,"当前战绩数值未采集"
        end
        self.rankingSort = { columnId = columnId ~= "" and columnId or nil, direction = direction }
        overviewPanel.table:SetSortState(columnId,direction,false)
        return self:RefreshStats()
    end

    function root:SelectActor(index)
        local row = self.overviewRows[index]
        if row == nil then return false end
        self.pendingView = false
        pendingBtn:SetText("查看待确认")
        self.selectedSide = row.side
        if self.selectedActorKey~=row.key then self.selectedSkillKillKey=nil end
        self.selectedActorKey = row.key
        self.selectedRow=row
        local metric=Settings().metric or "damage"
        local values=row.modeValues[self.detailMode] or {}
        local otherMode=self.detailMode=="PVP" and "PVE" or "PVP"
        if (tonumber(values[metric]) or 0)==0 and (tonumber((row.modeValues[otherMode] or {})[metric]) or 0)>0 then self.detailMode=otherMode end
        modeToggle:Render()
        return self:RefreshDetail()
    end

    function root:SetDetailExpanded(expanded)
        expanded=expanded==true
        self.detailExpanded=expanded
        local filtersVisible=self.selectedRow~=nil and not self.pendingView
        local token=tostring(expanded)..":"..tostring(filtersVisible)
        if self.detailLayoutToken~=token then
            self.detailLayoutToken=token
            detailPanel:SetSlot(expanded and {size="fill",fill=0.85,hAlign="fill",vAlign="fill"}
                or {size="fixed",height=filtersVisible and 70 or 34,hAlign="fill"})
        end
        detailFilters:SetVisible(filtersVisible)
        detailTables:SetVisible(expanded)
        detailViewport:SetVisible(expanded)
        detailSelector:SetVisible(expanded and not self.pendingView)
        return true
    end

    function root:RefreshDetail()
        local settingsValue = Settings()
        if self.pendingView == true then
            skillKillTargetsTable:SetVisible(false)
            self:SetDetailExpanded(true)
            detailSelector:SetVisible(false)
            abilityTable:SetVisible(false)
            counterpartTable:SetVisible(false)
            pendingModeTable:SetVisible(true)
            pendingSideTable:SetVisible(true)
            pendingBtn:SetText("返回单位明细")
            local projection = Feature:GetProjection({
                mode = settingsValue.mode, metric = settingsValue.metric, displayRows = settingsValue.displayRows,
            })
            local p = projection.projection or {}
            local sides = type(p.sides) == "table" and p.sides or {}
            local unresolved = type(p.unresolved) == "table" and p.unresolved or {}
            local sideUnknown = type(sides.unknown) == "table" and sides.unknown or {}
            local token = tostring(p.revision or 0) .. ":" .. tostring(p.mode or "") .. ":" .. tostring(p.metric or "")
            SetTableItems(pendingModeTable,PendingRows(unresolved, p.metric), "dps:pending:mode:" .. token)
            SetTableItems(pendingSideTable,PendingRows(sideUnknown, p.metric), "dps:pending:side:" .. token)
            detailSummary:SetText("待确认明细 · " .. ModeText(settingsValue.mode) .. " · 按" .. MetricText(settingsValue.metric)
                .. "排序 · 左：PVP/PVE 模式未定 · 右：阵营未定（数据均已保留，不代表丢失）")
            return true
        end

        abilityTable:SetVisible(self.detailView=="skills")
        counterpartTable:SetVisible(self.detailView=="counterparts")
        skillKillTargetsTable:SetVisible(self.detailView=="kill_targets")
        pendingModeTable:SetVisible(false)
        pendingSideTable:SetVisible(false)
        pendingBtn:SetText("查看待确认")
        local key = tostring(self.selectedActorKey or "")
        if key == "" or self.selectedSide == nil then
            self:SetDetailExpanded(false)
            detailSummary:SetText("选择单位后显示技能与目标 / 来源明细")
            SetTableItems(abilityTable,{}, "dps:detail:empty")
            SetTableItems(counterpartTable,{}, "dps:detail:empty")
            SetTableItems(skillKillTargetsTable,{}, "dps:detail:empty")
            return true
        end
        local detail = Feature:GetActorDetail({
            mode = self.detailMode, side = (self.selectedRow and self.selectedRow.modeSides[self.detailMode]) or self.selectedSide,
            metric = settingsValue.metric, actorKey = key, limit = 100,
            actorName=self.selectedRow and self.selectedRow.name,
        })
        local actor = detail and detail.actor or nil
        if actor == nil then
            self:SetDetailExpanded(false)
            detailSummary:SetText("明细 · "..tostring(self.selectedRow and self.selectedRow.name or key).." · "..ModeText(self.detailMode).." 暂无伤害/治疗技能记录")
            SetTableItems(abilityTable,{}, "dps:detail:missing")
            SetTableItems(counterpartTable,{}, "dps:detail:missing")
            SetTableItems(skillKillTargetsTable,{}, "dps:detail:missing")
            return true
        end
        self:SetDetailExpanded(true)
        detailSelector:SetVisible(true);detailSelector:Render()
        local metricText = MetricText(detail.metric)
        local summaryText="明细 · " .. tostring(actor.name or actor.key) .. " · " .. ModeText(self.detailMode)
            .. " · " .. (self.selectedSide == "enemy" and "敌方" or "友方") .. " · " .. metricText
            .. " " .. CompactNumber(actor[detail.metric])
        local token = tostring(detail.revision or 0) .. ":" .. tostring(actor.key) .. ":" .. tostring(detail.metric)..":"..self.detailMode..":"..tostring(detail.killRevision)
        local abilityRows = type(detail.abilities) == "table" and detail.abilities or {}
        local metricTotal = math.max(0, tonumber(actor[detail.metric]) or 0)
        for _, row in ipairs(abilityRows) do
            local skillId = tonumber(row.skillId or row.abilityId)
            row.skillIdText = skillId ~= nil and tostring(math.floor(skillId + 0.5)) or "—"
            row.iconPath = tostring(row.iconPath or "ui/icon/icon_unknown_item.dds")
            row.shareText = row.killOnly and "—" or (metricTotal > 0 and string.format("%.1f%%", (math.max(0, tonumber(row.amount) or 0) / metricTotal) * 100) or "0%")
            row.skillKillsAvailable=detail.skillKillsAvailable
        end
        self.abilityRows=abilityRows
        SetTableItems(abilityTable,abilityRows, "dps:ability:" .. token)
        SetTableItems(counterpartTable,type(detail.counterparts) == "table" and detail.counterparts or {}, "dps:counterpart:" .. token)
        local targets,omitted,selectedName={},0,nil
        for _,skill in ipairs(detail.killSkills or {}) do
            if self.selectedSkillKillKey==nil or self.selectedSkillKillKey==skill.key then
                selectedName=self.selectedSkillKillKey and skill.name or selectedName
                omitted=omitted+(tonumber(skill.omittedTargets) or 0)
                for _,target in ipairs(skill.targets or {}) do
                    targets[#targets+1]={name=target.name,skillName=skill.name,kills=target.kills}
                end
            end
        end
        table.sort(targets,function(a,b)if a.kills~=b.kills then return a.kills>b.kills end
            if a.name~=b.name then return a.name<b.name end return a.skillName<b.skillName end)
        SetTableItems(skillKillTargetsTable,targets,"dps:kill_targets:"..token..":"..tostring(self.selectedSkillKillKey))
        if self.detailView=="kill_targets" then
            detailSummary:SetText("击杀名单 · "..tostring(actor.name).." · "..tostring(selectedName or "全部技能").." · 当前统计期"
                ..(omitted>0 and (" · 容量外 "..tostring(omitted).." 次未保留姓名") or ""))
        else
            detailSummary:SetText(summaryText.." · 击杀按本期；点技能看名单")
        end
        return true
    end

    function root:RefreshStats()
        local settingsValue = Settings()
        -- 单人一行的汇总先组合/排序，再按显示行数截取。
        local projection = Feature:GetProjection({ mode = settingsValue.mode, metric = settingsValue.metric, displayRows = 150 })
        local p = projection.projection or {}
        local sides = type(p.sides) == "table" and p.sides or {}
        local sideUnknown = type(sides.unknown) == "table" and sides.unknown or {}
        local unresolved = type(p.unresolved) == "table" and p.unresolved or {}
        local selfOnly=statisticsScope:GetValue()=="self"
        local overview=Feature:GetCombatOverview()
        local candidates,totals={},{damage=0,heal=0,taken=0}
        for _,row in ipairs(overview.rows or {}) do
            if selfOnly or self.rankingSide=="all" or row.side==self.rankingSide then
                candidates[#candidates+1]=row
                for _,key in ipairs({"damage","heal","taken"}) do totals[key]=totals[key]+(tonumber(row[key]) or 0) end
            end
        end
        totals.actorCount=#candidates
        self.overviewRows=CopyAndSortRows(candidates,self.rankingSort,settingsValue.displayRows)
        local token=tostring(overview.revision)..":"..tostring(self.rankingSort.columnId)..":"..tostring(self.rankingSort.direction)..":"..self.rankingSide..":"..tostring(settingsValue.displayRows)
        SetTableItems(overviewPanel.table,self.overviewRows,"dps:overview:"..token)
        self:UpdateRankingLayout(selfOnly)
        local found
        if not self.pendingView then
            for index,row in ipairs(self.overviewRows) do
                if (selfOnly and row.self==true) or row.key==self.selectedActorKey then
                    found=true;self.selectedRow=row;self.selectedSide=row.side
                    if overviewPanel.table:GetSelectedIndex()~=index then overviewPanel.table:SetSelectedIndex(index) end
                    if self.selectedActorKey~=row.key then self:SelectActor(index) end
                    break
                end
            end
            if not found then self.selectedActorKey,self.selectedSide,self.selectedRow=nil,nil,nil;overviewPanel.table:ClearSelection() end
        end
        local labels={name="名称",damage="伤害",taken="承伤",heal="治疗",kills="击杀玩家",deaths="死亡"}
        local label=(labels[self.rankingSort.columnId] or "伤害")..(self.rankingSort.direction=="asc" and "↑" or "↓")
        overviewPanel.summary:SetText(TotalsText((selfOnly and "我的战斗总览 · " or "战斗总览 · ")..label,{totals=totals,totalRows=#candidates},#self.overviewRows))

        local unresolvedTotals = type(unresolved.totals) == "table" and unresolved.totals or {}
        local sideUnknownTotals = type(sideUnknown.totals) == "table" and sideUnknown.totals or {}
        local h = projection.health or {}
        local unresolvedAmount = N(unresolvedTotals.damage) + N(unresolvedTotals.taken) + N(unresolvedTotals.heal)
            + N(sideUnknownTotals.damage) + N(sideUnknownTotals.taken) + N(sideUnknownTotals.heal)
        pendingBtn:SetText(self.pendingView and "返回单位明细" or (unresolvedAmount > 0 and "查看待确认 !" or "查看待确认"))

        enableBtn:SetText(projection.enabled == true and "暂停统计" or "开始统计")
        local widgetVisible = WidgetHost:IsVisible("combat.dps") == true
        showWidget:SetText(widgetVisible and "隐藏悬浮窗" or "显示悬浮窗")
        showWidget:SetEnabled(projection.enabled == true)
        healthText:SetText("当前统计期 · 伤害汇总 PVP/PVE · 战绩"..(overview.statsAvailable and "开启" or "已关闭").." · PVP " .. tostring(N(h.classificationPVP))
            .. " · PVE " .. tostring(N(h.classificationPVE)) .. " · 治疗 " .. tostring(N(h.classificationHeal))
            .. " · 未知 " .. tostring(N(h.classificationUnknown)) .. " · 事件 " .. tostring(N(h.events)))
        statisticsScope:Render();modeToggle:Render(); metricSelector:Render()
        RefreshClearButton()
        self:RefreshDetail()
        return true
    end

    function root:Refresh()
        self:RefreshStats()
        return true
    end

    function root:Subscribe()
        if self.subscribed then return true end
        if S.Events and type(S.Events.SubscribeInternal) == "function" then
            S.Events:SubscribeInternal("v3.dps.updated", self, function() root:RefreshStats() end)
            S.Events:SubscribeInternal("v3.combat_analytics.updated", self, function() root:RefreshStats() end)
            S.Events:SubscribeInternal("v3.combat_analytics.feature_updated", self, function() root:RefreshStats() end)
            S.Events:SubscribeInternal("v3.dps.settings", self, function(_, key)
                root:RefreshStats()
            end)
            S.Events:SubscribeInternal((S.FeatureRuntime and S.FeatureRuntime.LifecycleTopic) or "v3.feature.lifecycle", self,
                function(_, featureId) if tostring(featureId or "") == FEATURE_ID then root:RefreshStats() end end)
        end
        self.subscribed = true
        return true
    end

    function root:Unsubscribe()
        if not self.subscribed then return true end
        if S.Events and type(S.Events.UnsubscribeInternalOwner) == "function" then S.Events:UnsubscribeInternalOwner(self) end
        self.subscribed = false
        return true
    end

    function root:OnActivated()
        local ok, err = Feature:EnsureStoreLoaded()
        if ok ~= true then return false, err end
        self:Subscribe()
        return self:Refresh()
    end

    function root:OnDeactivated()
        self:Unsubscribe()
        self.clearConfirmUntil = 0
        if S.Scheduler ~= nil and type(S.Scheduler.RemoveTask) == "function" then
            pcall(function() S.Scheduler:RemoveTask(CLEAR_CONFIRM_TASK) end)
        end
        RefreshClearButton()
        return true
    end

    enableBtn.spec.onClick = function()
        local projection = Feature:GetProjection({})
        local nextEnabled = not (projection and projection.enabled == true)
        return S.ActionRunner:Run({
            id = "dps.toggle", button = enableBtn, idleText = enableBtn.text, busyText = "处理中…", notify = true,
            successText = function() return nextEnabled and "伤害统计已启用。" or "伤害统计已停用；本次统计数据已保留。" end,
            errorText = function(reason) return tostring(reason or "状态切换失败") end,
            execute = function() return Feature.Commands:SetEnabled(nextEnabled, "dps_page") end,
            onSuccess = function() root:RefreshStats() end,
        })
    end

    advancedBtn.spec.onClick = function()
        return S.UIV3.Shell:Navigate("combat.statistics_settings",{source="dps_settings"})
    end

    pendingBtn.spec.onClick = function()
        root.pendingView = root.pendingView ~= true
        if root.pendingView == true then
            overviewPanel.table:ClearSelection()
        end
        return root:RefreshDetail()
    end

    showWidget.spec.onClick = function()
        local nextVisible = not (WidgetHost:IsVisible("combat.dps") == true)
        return S.ActionRunner:Run({
            id = "dps.widget_visibility", button = showWidget, idleText = showWidget.text, busyText = "处理中…", notify = true,
            successText = function() return nextVisible and "DPS 悬浮窗已显示。" or "DPS 悬浮窗已隐藏。" end,
            errorText = function(reason) return tostring(reason or "悬浮窗切换失败") end,
            execute = function()
                if S.FeatureRuntime:IsEnabled(FEATURE_ID) ~= true then return false, "请先启用伤害统计" end
                return WidgetHost:SetVisible("combat.dps", nextVisible, { source = "dps_page", persist = false })
            end,
            onSuccess = function() root:RefreshStats() end,
        })
    end

    clear.spec.onClick = function()
        local now = NowMs()
        if (tonumber(root.clearConfirmUntil) or 0) < now then
            root.clearConfirmUntil = now + 5000
            RefreshClearButton()
            if S.Scheduler ~= nil and type(S.Scheduler.AddOneShot) == "function" then
                S.Scheduler:AddOneShot(CLEAR_CONFIRM_TASK, 5050, function()
                    root.clearConfirmUntil = 0
                    RefreshClearButton()
                    return true
                end, root, "P3", 1)
            end
            return true
        end
        root.clearConfirmUntil = 0
        return S.ActionRunner:Run({
            id = "dps.clear", button = clear, idleText = clear.text, busyText = "清空中…", notify = true,
            successText = "实时战斗总览已清空，个人历史保留。", errorText = function(reason) return tostring(reason or "清空失败") end,
            execute = function() return Feature.Commands:ClearOverview("dps_page") end,
            onSuccess = function()
                root.selectedActorKey, root.selectedSide = nil, nil
                root.selectedRow=nil;overviewPanel.table:ClearSelection()
                root:RefreshStats()
            end,
        })
    end
    local layout=root.Layout
    local function Rect(node)
        return {x=node.x,y=node.y,width=node.width,height=node.height,visible=node.visible~=false,
            viewportVisible=node.viewportVisible~=false,measureDirty=node.measureDirty==true,layoutDirty=node.layoutDirty==true}
    end
    local function LayoutFacts()
        return {page=Rect(root),toolbar=Rect(top),body=Rect(body),ranking=Rect(rankings),overview=Rect(overviewPanel.table),
            detailPanel=Rect(detailPanel),detailStack=Rect(detailStack),detailViewport=Rect(detailViewport),
            ability=Rect(abilityTable),counterpart=Rect(counterpartTable),
            detailExpanded=root.detailExpanded==true,detailScrollOffset=detailStack.scrollOffset,
            detailMaxScrollOffset=detailStack.maxScrollOffset,rankingLayoutToken=root.rankingLayoutToken}
    end
    function root:GetLayoutDiagnostic()
        return {version=1,patch="combat-statistics-first-layout-1",layoutPasses=self.statisticsLayoutPasses or 0,
            firstLayout=S.Utils.DeepCopy(self.firstStatisticsLayout),current=LayoutFacts()}
    end
    function root:Layout(x,y,width,height)
        self:UpdateRankingLayout(statisticsScope:GetValue()=="self")
        local result=layout(self,x,y,width,height)
        self.statisticsLayoutPasses=(self.statisticsLayoutPasses or 0)+1
        if self.firstStatisticsLayout==nil then self.firstStatisticsLayout=LayoutFacts()end
        return result
    end
    -- PageHost 的 WidgetSwitcher 会在 OnActivated 之前同步排版新页；先准备真实投影和显隐。
    -- 仅消费已有事实，不获取采集 Consumer，也不等待下一次战斗事件才修正首屏。
    root:RefreshStats()
    return root
end

local ok, err = PageHost:RegisterFactory("combat.stats", Build)
if ok ~= true then error(err) end
local diagnostics=S.ModuleDiagnosticsHub
if diagnostics and type(diagnostics.RegisterProvider)=="function" then
    diagnostics:RegisterProvider(FEATURE_ID,"combat_statistics_layout",function()
        local page=PageHost.pages and PageHost.pages["combat.stats"]
        if page and type(page.GetLayoutDiagnostic)=="function" then return page:GetLayoutDiagnostic()end
        return {version=1,created=false}
    end,35,{detailOnly=true}) -- 纯读已存在的逻辑几何；不创建页面、不执行 Layout 或 Native getter。
end
