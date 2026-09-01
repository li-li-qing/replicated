------------------------------------------------------------------------
-- Replicated Suite V3 - Combat Analytics Page
-- Player-facing analytics workspace. Presentation consumes Feature projections
-- and bounded actor drill-downs only; metric state/native combat APIs stay behind
-- the CombatAnalytics Feature/Service boundary.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S=ReplicatedSuite
local RSUI,D=S.RSUI,S.UIV3Design
local PageHost=S.UIV3 and S.UIV3.PageHost or nil
local Feature=S.Features and S.Features.CombatAnalytics or nil
if type(RSUI)~="table" or type(D)~="table" or type(PageHost)~="table" or type(Feature)~="table" then return end
local FEATURE_ID = "combat_analytics"

local function Compact(value)
    local n=tonumber(value) or 0;local a=math.abs(n)
    if a<1000 then return tostring(math.floor(n+0.5)) end
    if a>=1000000 then return string.format(a>=100000000 and "%.0fM" or "%.1fM",n/1000000) end
    return string.format(a>=100000 and "%.0fK" or "%.1fK",n/1000)
end
local function FormatValue(key,value)
    key=tostring(key or "")
    value=tonumber(value) or 0
    if key:find("Ms",1,true) or key:find("Duration",1,true) or key=="durationMs" then return string.format("%.1fs",value/1000) end
    return Compact(value)
end
local function MetricItems(metrics)
    local out={};for _,row in ipairs(type(metrics)=="table" and metrics or {}) do out[#out+1]={value=row.id,text=row.title} end;return out
end
local function HistoryRows(projection,valueKey)
    valueKey=tostring(valueKey or "durationMs")
    local rows={};for index,row in ipairs(type(projection.history)=="table" and projection.history or {}) do
        rows[#rows+1]={rank=index,key="encounter:"..tostring(row.id or index),name="战斗 #"..tostring(row.id or "?"),value=tonumber(row[valueKey]) or 0,
            extra="伤 "..Compact(row.damage).." · 治 "..Compact(row.healing).." · 死 "..tostring(row.deaths or 0),durationMs=row.durationMs}
    end;return rows
end
local function RankingRows(projection)
    local rows={};for _,row in ipairs(type(projection.rows)=="table" and projection.rows or {}) do
        rows[#rows+1]={rank=row.rank,key=row.key,name=row.name,value=row.value,source=row,extra=""}
    end;return rows
end

local SCALAR_LABELS={
    kills="击杀",assists="助攻",deaths="死亡",skillActivities="技能活动",exactCasts="精确施法",
    peak5sDps="5秒峰值DPS",peak5sDamage="5秒峰值伤害",highestHit="最高单击",damage="总伤害",
    controlHits="控制命中",controlActivities="控制释放",controlMs="控制时长",controlled="被控次数",controlledMs="被控时长",
    songMs="演奏时长",songStarts="开始演奏",songSwitches="切歌",songActivities="演奏活动",songBuffMs="歌曲覆盖时长",songBuffApplies="歌曲覆盖次数",
    utilityActivities="辅助技能活动",utilityExact="精确辅助使用",interrupt="打断",dispel="驱散",cleanse="净化/解控",resurrection="复活",defensive="防御技能",
    buffUptimeMs="Buff观察时长",debuffUptimeMs="Debuff观察时长",buffApplies="Buff施加",debuffApplies="Debuff施加",mechanics="机制命中",
}
local SECTION_LABELS={
    killTargets="击杀目标",killAbilities="击杀技能",assistTargets="助攻目标",
    skills="技能活动",exactSkills="精确施法",
    controlActivityTypes="控制释放类型",controlHitTypes="控制命中类型",controlDurationByAura="控制时长",
    songDurationBySkill="演奏时长",songs="演奏技能",songBuffs="歌曲Buff",songBuffDuration="歌曲覆盖时长",nativeSongs="精确演奏",
    utilityTypes="辅助类型",utilitySkills="辅助技能",utilitySkillsExact="精确辅助技能",
    buffAppliesByAura="Buff施加",debuffAppliesByAura="Debuff施加",buffDurationByAura="Buff观察时长",debuffDurationByAura="Debuff观察时长",
    mechanicTypes="机制类型",mechanicSources="机制来源",
}
local function SectionValue(sectionId,value)
    sectionId=tostring(sectionId or "")
    if sectionId:find("Duration",1,true) then return FormatValue("durationMs",value) end
    return Compact(value)
end
local function ScalarSummary(detail)
    local parts={}
    for key,label in pairs(SCALAR_LABELS) do
        local value=detail and detail.scalars and tonumber(detail.scalars[key]) or nil
        if value~=nil and value~=0 then parts[#parts+1]={label=label,key=key,value=value} end
    end
    table.sort(parts,function(a,b) return a.label<b.label end)
    local out={}
    for index,row in ipairs(parts) do if index>8 then break end;out[#out+1]=row.label.." "..FormatValue(row.key,row.value) end
    return table.concat(out," · ")
end
local function DetailRows(detail)
    local rows={}
    if type(detail)~="table" then return rows end
    if type(detail.opener)=="table" and #detail.opener>0 then
        local names={};for _,entry in ipairs(detail.opener) do if tostring(entry.skill or "")~="" then names[#names+1]=tostring(entry.skill) end end
        if #names>0 then rows[#rows+1]={category="起手顺序",name=table.concat(names," → "),valueText=tostring(#names).." 个动作"} end
    end
    for _,section in ipairs(type(detail.sections)=="table" and detail.sections or {}) do
        local label=SECTION_LABELS[section.id] or tostring(section.id or "明细")
        for _,entry in ipairs(type(section.rows)=="table" and section.rows or {}) do
            rows[#rows+1]={category=label,name=tostring(entry.name or entry.key or "未知"),valueText=SectionValue(section.id,entry.value)}
            if #rows>=96 then return rows end
        end
    end
    return rows
end
local function CoverageText(value)
    value=tostring(value or "--")
    local known={
        FULL="完整事件覆盖", SELF_ONLY="仅自身事件", INACTIVE="尚未采集",
        TEAM_ACTIVITY_INFERRED_SELF_NATIVE_EXACT_WHEN_AVAILABLE="团队活动推断；自身施法尽量精确",
        SELF_NATIVE_WHEN_AVAILABLE_TEAM_ACTIVITY_AND_AURA_OBSERVED="自身原生事件优先；团队活动与光环按可见事件补充",
        CATALOG_ACTIVITY_SELF_NATIVE_ENRICHMENT="按技能目录识别活动；自身原生事件可用时补充精确信息",
        ACTIVITY_INFERRED_AURA_DURATION_OBSERVED="技能活动用于推断；光环持续时间按实际可见事件统计",
        OBSERVED_AURA_EVENTS_ONLY="仅统计客户端实际观察到的 Buff/Debuff 事件",
        EXACT_CATALOG_MATCH_TARGET_FIRST="按已核验技能/机制目录匹配，目标信息优先",
        DIRECT_DAMAGE_BOUNDED_5S_WINDOW="直接伤害事件；使用有界 5 秒窗口计算爆发",
        DIRECT_DEATH_PLUS_BOUNDED_DAMAGE_INFERENCE="死亡事件直接确认；助攻由死亡前有界伤害窗口推断",
        DIRECT_COMBAT_FACTS_ANCHORED_BY_DAMAGE_HEAL_DEATH="按伤害、治疗、死亡事件划分并汇总战斗段",
    }
    return known[value] or value
end
local function RunAction(id,button,successText,execute,onSuccess)
    if S.ActionRunner and type(S.ActionRunner.Run)=="function" then
        return S.ActionRunner:Run({id="combat_analytics."..tostring(id),button=button,busyText="处理中…",notify=true,
            successText=successText,errorText=function(reason) return tostring(reason or "操作失败") end,execute=execute,onSuccess=onSuccess})
    end
    local ok,err=execute();if ok==true and type(onSuccess)=="function" then onSuccess() end;return ok,err
end

local function Build(parent)
    local root,rootErr=D:ScrollablePageRoot(parent,{id="v3_combat_analytics_page",padding=8,gap=7})
    if root==nil then error("战斗分析 PageRoot 创建失败："..tostring(rootErr or "unknown")) end
    root.subscribed=false;root.rows={};root.compareA=nil;root.compareB=nil;root.selectedRow=nil

    RSUI:Text({id="v3_analytics_title",parent=root,text="战斗分析",fontSize=16,tone="strong",slot={size="fixed",height=27}})
    RSUI:Text({id="v3_analytics_subtitle",parent=root,
        text="这是 DPS 之外的战斗行为分析：查看击杀/助攻、技能释放、爆发、控制、演奏、辅助、Buff/Debuff 与 Boss 机制。选择玩家后可继续查看具体明细。",
        fontSize=9,tone="muted",overflow="wrap",slot={size="auto",minHeight=34}})

    local toolbar=RSUI:HorizontalBox({id="v3_analytics_toolbar",parent=root,gap=6,slot={size="fixed",height=34,hAlign="fill"}})
    local enable=RSUI:Button({id="v3_analytics_enable",parent=toolbar,text="开始分析",compact=true,slot={size="fixed",width=92}})
    local metric,metricErr=RSUI:Dropdown({id="v3_analytics_metric",parent=toolbar,items={},maxVisible=9,
        get=function() return Feature:GetSelectedMetric() end,
        set=function(id) local ok,err=Feature.Commands:SetSelectedMetric(id);if ok==true then root.compareA,root.compareB,root.selectedRow=nil,nil,nil;root:RefreshData() end;return ok,err end,
        slot={size="fixed",width=170}})
    if metric==nil then error("战斗分析项目下拉框创建失败："..tostring(metricErr or "unknown")) end
    -- Metric value is a direct one-of-many choice, not a nested menu.  The old
    -- Dropdown made the visible "击杀" trigger look like a button but depended
    -- on a second popup interaction, which was both easy to miss and unreliable
    -- in some RU layers. Build one bounded segmented selector per metric and only
    -- show the active metric's selector; every segment writes through the same
    -- Feature Command / Store authority.
    local metricToggle=RSUI:Button({id="v3_analytics_metric_toggle",parent=toolbar,text="暂停当前项目",compact=true,slot={size="fixed",width=112}})
    local clear=RSUI:Button({id="v3_analytics_clear",parent=toolbar,text="清空当前",compact=true,slot={size="fixed",width=88}})
    local clearAll=RSUI:Button({id="v3_analytics_clear_all",parent=toolbar,text="清空全部",compact=true,slot={size="fixed",width=88}})

    local valueStrip=RSUI:HorizontalBox({id="v3_analytics_value_strip",parent=root,gap=6,slot={size="fixed",height=30,hAlign="fill"}})
    RSUI:Text({id="v3_analytics_value_label",parent=valueStrip,text="排行：",fontSize=9,tone="muted",slot={size="fixed",width=42,vAlign="center"}})
    local valueHost=RSUI:Overlay({id="v3_analytics_value_host",parent=valueStrip,slot={size="fill",fill=1,hAlign="fill",vAlign="fill"}})
    root.valueSelectors={}
    local selectorModels=type(Feature.GetValueSelectorModels)=="function" and Feature:GetValueSelectorModels() or {}
    if type(selectorModels)~="table" or #selectorModels==0 then error("战斗分析排行切换模型不可用") end
    for _,selectorModel in ipairs(selectorModels) do
        local capturedMetric=tostring(selectorModel and selectorModel.id or "")
        local options=type(selectorModel)=="table" and selectorModel.options or nil
        if type(options)=="table" and #options>=2 then
            local segmentItems={}
            for _,option in ipairs(options) do
                local text=tostring(option.text or option.value or "")
                local width=math.max(48,math.min(104,34+#text*7))
                segmentItems[#segmentItems+1]={value=option.value,text=text,width=width}
            end
            local selector,selectorErr=RSUI:SegmentedSelector({
                id="v3_analytics_value_"..capturedMetric,parent=valueHost,items=segmentItems,maxItems=8,gap=2,height=25,fontSize=9,
                get=function() return Feature:GetSelectedValueKey(capturedMetric) end,
                set=function(key)
                    local ok,err=Feature.Commands:SetSelectedValue(capturedMetric,key)
                    if ok==true then root:RefreshData() end
                    return ok,err
                end,
                slot={hAlign="left",vAlign="center"},
            })
            if selector==nil then error("战斗分析数值切换器创建失败："..capturedMetric.." · "..tostring(selectorErr or "unknown")) end
            selector:SetVisibility("collapsed")
            root.valueSelectors[capturedMetric]=selector
        elseif type(options)=="table" and #options==1 then
            local only=options[1]
            local label=RSUI:Text({id="v3_analytics_value_"..capturedMetric.."_single",parent=valueHost,text=tostring(only.text or only.value or "--"),fontSize=9,tone="strong",slot={hAlign="left",vAlign="center"}})
            label:SetVisibility("collapsed")
            root.valueSelectors[capturedMetric]=label
        end
    end

    local explanation=RSUI:Text({id="v3_analytics_explanation",parent=root,text="用途：--",fontSize=10,tone="strong",overflow="wrap",slot={size="auto",minHeight=28}})
    local coverage=RSUI:Text({id="v3_analytics_coverage",parent=root,text="采集：--",fontSize=9,tone="muted",overflow="ellipsis",slot={size="fixed",height=20}})
    local compare=RSUI:Text({id="v3_analytics_compare",parent=root,text="玩家对比：先选 A，再选 B",fontSize=9,tone="muted",overflow="ellipsis",slot={size="fixed",height=20}})
    local emptyHint=RSUI:Text({id="v3_analytics_empty_hint",parent=root,text="",fontSize=10,tone="warn",overflow="wrap",slot={size="auto",minHeight=22}})

    local tableView=RSUI:TableView({id="v3_analytics_table",parent=root,items={},rowHeight=23,headerHeight=24,desiredRows=10,scrollbar=true,selectable=true,selectionMode="single",columnResize=true,
        columns={
            {id="rank",title="#",field="rank",size="fixed",width=38,minWidth=32,sortable=false},
            {id="name",title="玩家 / 战斗",field="name",size="fill",fill=1,minWidth=150},
            {id="value",title="当前数值",field="valueText",size="fixed",width=112,minWidth=86},
            {id="extra",title="补充",field="extra",size="fill",fill=1,minWidth=170},
        },slot={size="fixed",height=280,hAlign="fill"},
        onSelectionChanged=function(index) if type(root.SelectRow)=="function" then root:SelectRow(index) end end})

    local detailTitle=RSUI:Text({id="v3_analytics_detail_title",parent=root,text="玩家明细：选择排行中的玩家",fontSize=10,tone="strong",overflow="wrap",slot={size="auto",minHeight=24}})
    local detailTable=RSUI:TableView({id="v3_analytics_detail_table",parent=root,items={},rowHeight=22,headerHeight=23,desiredRows=7,scrollbar=true,selectable=false,columnResize=true,
        columns={
            {id="category",title="分类",field="category",size="fixed",width=116,minWidth=88,sortable=false},
            {id="name",title="明细",field="name",size="fill",fill=1,minWidth=160,sortable=false},
            {id="value",title="数值",field="valueText",size="fixed",width=100,minWidth=74,sortable=false},
        },slot={size="fixed",height=190,hAlign="fill"}})
    local health=RSUI:Text({id="v3_analytics_health",parent=root,text="运行状态：--",fontSize=9,tone="muted",overflow="wrap",slot={size="auto",minHeight=34}})

    function root:SelectRow(index)
        local row=self.rows[tonumber(index) or 0];if row==nil then return true end
        self.selectedRow=row
        if row.source~=nil then
            if self.compareA==nil or self.compareB~=nil then self.compareA=row.name;self.compareB=nil else self.compareB=row.name end
        end
        self:RefreshCompare();self:RefreshDetail(row);return true
    end
    function root:RefreshCompare()
        if self.compareA==nil then compare:SetText("玩家对比：先选择一名玩家作为 A");return true end
        if self.compareB==nil then compare:SetText("玩家对比：A="..tostring(self.compareA).." · 再选择一名玩家作为 B");return true end
        local id=Feature:GetSelectedMetric();local key=Feature:GetSelectedValueKey(id);local c=Feature:Compare(id,self.compareA,self.compareB,key)
        local av=c.left and c.left.value or 0;local bv=c.right and c.right.value or 0
        compare:SetText("玩家对比："..self.compareA.." "..FormatValue(key,av).."  VS  "..self.compareB.." "..FormatValue(key,bv))
        return true
    end
    function root:RefreshDetail(row)
        if row==nil then detailTitle:SetText("玩家明细：选择排行中的玩家");detailTable:SetItems({},"analytics:detail:empty");return true end
        if row.source==nil or tostring(row.key or ""):find("encounter:",1,true)==1 then
            detailTitle:SetText("战斗明细："..tostring(row.name).." · "..tostring(row.extra or ""));detailTable:SetItems({},"analytics:detail:encounter");return true
        end
        local id=Feature:GetSelectedMetric();local actorKey=tostring(row.source.key or row.key or "")
        local detail,err=Feature:GetActorDetail(id,actorKey,{limit=24,maxSections=8})
        if type(detail)~="table" then detailTitle:SetText("玩家明细："..tostring(row.name).." · "..tostring(err or "暂无可展开明细"));detailTable:SetItems({},"analytics:detail:missing");return true end
        local summary=ScalarSummary(detail)
        detailTitle:SetText("玩家明细 · "..tostring(detail.actor and detail.actor.name or row.name)..(summary~="" and (" · "..summary) or ""))
        local rows=DetailRows(detail)
        detailTable:SetItems(rows,"analytics:detail:"..id..":"..actorKey..":"..tostring(detail.revision or 0))
        return true
    end
    function root:RefreshData()
        local id=Feature:GetSelectedMetric();local result=Feature:GetProjection(id,{valueKey=Feature:GetSelectedValueKey(id)})
        local p=type(result.projection)=="table" and result.projection or {}
        metric:SetItems(MetricItems(result.metrics));metric:SetSelectedValue(id,true,"render")
        local selectedValue=Feature:GetSelectedValueKey(id)
        for metricId,selector in pairs(self.valueSelectors or {}) do
            local active=tostring(metricId)==id
            selector:SetVisibility(active and "visible" or "collapsed")
            if active and type(selector.Render)=="function" then selector:Render(selectedValue) end
        end
        enable:SetText(result.enabled==true and "暂停分析" or "开始分析")
        metricToggle:SetText(result.metricEnabled==true and "暂停当前项目" or "启用当前项目")
        local metricDescription=""
        for _,info in ipairs(type(result.metrics)=="table" and result.metrics or {}) do if info.id==id then metricDescription=tostring(info.description or "");break end end
        explanation:SetText("用途："..(metricDescription~="" and metricDescription or "当前分析项用于补充 DPS 无法表达的战斗行为。"))
        local key=p.valueKey or selectedValue;local rows=id=="encounter" and HistoryRows(p,key) or RankingRows(p)
        for _,row in ipairs(rows) do row.valueText=FormatValue(key,row.value);row.extra=row.extra or "" end
        self.rows=rows;tableView:SetItems(rows,"analytics:"..id..":"..tostring(p.revision or 0)..":"..key)
        local current=p.current;local currentText=type(current)=="table" and (" · 当前战斗 "..string.format("%.1fs",(tonumber(current.durationMs) or 0)/1000)) or ""
        coverage:SetText("采集覆盖："..CoverageText(p.coverage or p.nativeCoverage)..currentText)
        if result.enabled~=true then emptyHint:SetText("战斗分析尚未开始。点击“开始分析”后才会采集这些扩展指标。")
        elseif result.metricEnabled~=true then emptyHint:SetText("当前分析项目已暂停采集。点击“启用当前项目”即可恢复。")
        elseif #rows==0 then emptyHint:SetText("当前项目正在采集，暂时没有匹配到可显示的战斗事件。")
        else emptyHint:SetText("") end
        local h=result.health or {};health:SetText("运行状态："..(result.enabled==true and "分析中" or "已暂停").." · 已启用项目 "..tostring(h.activeMetrics or 0).." · 已接收事件 "..tostring(h.factsReceived or 0).." · 分析错误 "..tostring(h.metricErrors or 0))
        self:RefreshCompare()
        if self.selectedRow~=nil then self:RefreshDetail(self.selectedRow) else self:RefreshDetail(nil) end
        return true
    end
    function root:Subscribe()
        if self.subscribed then return true end
        if S.Events and type(S.Events.SubscribeInternal)=="function" then
            S.Events:SubscribeInternal("v3.combat_analytics.updated",self,function() root:RefreshData() end)
            S.Events:SubscribeInternal("v3.combat_analytics.feature_updated",self,function() root:RefreshData() end)
            S.Events:SubscribeInternal((S.FeatureRuntime and S.FeatureRuntime.LifecycleTopic) or "v3.feature.lifecycle",self,function(_,featureId) if tostring(featureId or "")==FEATURE_ID then root:RefreshData() end end)
        end
        self.subscribed=true;return true
    end
    function root:Unsubscribe() if self.subscribed and S.Events and type(S.Events.UnsubscribeInternalOwner)=="function" then S.Events:UnsubscribeInternalOwner(self) end;self.subscribed=false;return true end
    function root:OnActivated() local ok,err=Feature:EnsureStoreLoaded();if ok~=true then return false,err end;self:Subscribe();return self:RefreshData() end
    function root:OnDeactivated() self:Unsubscribe();return true end

    enable.spec.onClick=function()
        local snap=S.FeatureRuntime:GetSnapshot(FEATURE_ID);local target=not (snap and snap.enabled==true)
        return RunAction("toggle",enable,target and "战斗分析已开始" or "战斗分析已暂停",function() return Feature.Commands:SetEnabled(target,"analytics_page") end,function() root:RefreshData() end)
    end
    metricToggle.spec.onClick=function()
        local id=Feature:GetSelectedMetric();local target=not Feature:IsMetricPreferenceEnabled(id)
        return RunAction("metric_toggle",metricToggle,target and "当前分析项目已启用" or "当前分析项目已暂停",function() return Feature.Commands:SetMetricEnabled(id,target) end,function() root:RefreshData() end)
    end
    clear.spec.onClick=function()
        local id=Feature:GetSelectedMetric()
        return RunAction("clear_metric",clear,"当前分析数据已清空",function() return Feature.Commands:ClearMetric(id) end,function() root.compareA,root.compareB,root.selectedRow=nil,nil,nil;root:RefreshData() end)
    end
    clearAll.spec.onClick=function()
        return RunAction("clear_all",clearAll,"全部战斗分析数据已清空",function() return Feature.Commands:ClearAll() end,function() root.compareA,root.compareB,root.selectedRow=nil,nil,nil;root:RefreshData() end)
    end
    return root
end
local ok,err=PageHost:RegisterFactory("combat.analytics",Build);if ok~=true then error(err) end
