-- Replicated Suite · 活动时间线与实时区域列表
-- 作者：Replicated
-- QQ群：1104129461
-- 时间线与实时区域独立滚动，空分区不占位；两个有界表格共用列定义副本。
-- 数据和排序取 Activity 投影，个人顺序取 Workspace；父页面或组件管理 Consumer。
-- 未知阶段不按 0 秒排序，SetItems/Selection 保留稳定 key 和原行引用。
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S=ReplicatedSuite
local R=S.RSUI
if type(R)~='table' then return end
S.UIV3=S.UIV3 or {}
local generation=tonumber(S.Generation) or 0
local previousDiagnostics=S.UIV3.ActivityDetailInteractionDiagnostics
local Interaction=type(previousDiagnostics)=='table' and tonumber(previousDiagnostics.generation)==generation and previousDiagnostics or {
    generation=generation,attempts=0,successes=0,failures=0,lastKey=nil,lastSection=nil,lastReason=nil,lastResult=nil,lastError=nil,lastAtMs=nil,
}
S.UIV3.ActivityDetailInteractionDiagnostics=Interaction
-- ActivateItem 只消费回调首个返回值，曾丢掉 detail:Open 的错误原因。
-- 点击时记录有界证据：attempts=0 表示未进入回调，failures>0 保留真实打开失败原因。
local hub=S.ModuleDiagnosticsHub
if type(hub)=='table' and type(hub.RegisterProvider)=='function' then
    hub:RegisterProvider('life_activities','activity_detail_click',function()
        local detail=S.UIV3 and S.UIV3.QuestDetailFloatingV3 or nil
        local floating=nil
        if type(detail)=='table' and type(detail.GetInteractionDiagnostics)=='function' then
            local ok,value=pcall(function()return detail:GetInteractionDiagnostics()end);if ok then floating=value end
        end
        return {attempts=tonumber(Interaction.attempts) or 0,successes=tonumber(Interaction.successes) or 0,
            failures=tonumber(Interaction.failures) or 0,lastKey=Interaction.lastKey,lastSection=Interaction.lastSection,
            lastReason=Interaction.lastReason,lastResult=Interaction.lastResult,lastError=Interaction.lastError,
            lastAtMs=Interaction.lastAtMs,floating=floating}
    end,45)
end
local Lists={version=4,ActivationDiagnosticsContractVersion=1,RowQuantizedSplitContractVersion=1,AdaptiveTailFillContractVersion=1};S.UIV3.ActivityLists=Lists
local function Live(row)return row and (row.presentationSection=='live' or row.zoneState==true)end
local function Copy(value)local out={};for k,v in pairs(value or {})do out[k]=v end;return out end

-- 虚拟列表只画整行，固定行高会留下不足一行的尾带。
-- 按实际视口选择接近基准值的行数和行高：有更多数据时略压缩，已显示完整时略拉伸。
-- Native 下限 12px；内容太少时仍限制行高，保留合理空白，不改数据、排序或滚动位置。
local function ResolveAdaptiveRowHeight(viewportHeight,headerHeight,itemCount,baseRowHeight,softMin,softMax)
    local listHeight=math.max(0,(tonumber(viewportHeight) or 0)-(tonumber(headerHeight) or 0))
    local count=math.max(0,math.floor(tonumber(itemCount) or 0))
    local base=math.max(12,tonumber(baseRowHeight) or 20)
    local minSoft=math.max(12,tonumber(softMin) or math.max(12,base-4))
    local maxSoft=math.max(minSoft,tonumber(softMax) or (base+4))
    if count<=0 or listHeight<=0 then return base,0,listHeight end

    local hardMin=12
    local maxCandidate=math.min(count,32,math.max(1,math.floor(listHeight/hardMin)))
    local bestRows,bestHeight,bestScore=nil,nil,nil
    for rows=1,maxCandidate do
        local rowHeight=listHeight/rows
        if rowHeight>=hardMin then
            local score=math.abs(rowHeight-base)
            -- 软边界不是硬截断：临界高度宁可轻微压缩/拉伸，也不要重新制造明显尾带。
            if rowHeight<minSoft then score=score+(minSoft-rowHeight)*2.5 end
            if rowHeight>maxSoft then score=score+(rowHeight-maxSoft)*2.5 end
            -- 同分时略偏向更多可见行，让“再拉一点点才突然出现下一行”的跳变更少。
            score=score-rows*0.0001
            if bestScore==nil or score<bestScore then bestRows,bestHeight,bestScore=rows,rowHeight,score end
        end
    end
    if bestRows==nil then return math.max(12,math.min(base,listHeight)),1,math.max(0,listHeight-math.max(12,math.min(base,listHeight))) end

    -- 当条目太少、viewport 高到必须把一行拉得非常夸张时，不为了“零空白”破坏可读性；
    -- 这类尾部是真正的内容不足，不是临界行高造成的布局洞。
    if bestHeight>maxSoft and count==bestRows then
        bestHeight=maxSoft
    end
    local tail=math.max(0,listHeight-bestRows*bestHeight)
    return bestHeight,bestRows,tail
end

local function SetRuntimeRowHeight(view,height)
    if type(view)~='table' then return false end
    if type(view.SetRuntimeRowHeight)=='function' then
        local ok=select(1,view:SetRuntimeRowHeight(height,false));return ok==true
    end
    -- 兼容开发期旧测试替身；正式 toc 的 TableView 提供 SetRuntimeRowHeight。
    view.rowHeight=height
    if type(view.list)=='table' then view.list.rowHeight=height end
    return true
end
local function RecordActivation(section,item,reason,ok,result,detail)
    Interaction.attempts=(tonumber(Interaction.attempts) or 0)+1
    Interaction.lastKey=tostring(type(item)=='table' and (item.key or item.questKey) or '')
    Interaction.lastSection=tostring(section or '');Interaction.lastReason=tostring(reason or 'row_click')
    Interaction.lastAtMs=type(S.NowMs)=='function' and S.NowMs() or 0
    if ok==true and result~=false then
        Interaction.successes=(tonumber(Interaction.successes) or 0)+1;Interaction.lastResult='opened';Interaction.lastError=nil;return true
    end
    Interaction.failures=(tonumber(Interaction.failures) or 0)+1;Interaction.lastResult=ok==true and 'rejected' or 'callback_error'
    Interaction.lastError=tostring(ok==true and (detail or 'activation_returned_false') or result or 'activation_failed');return false
end
function Lists:Create(spec)
    spec=spec or {}
    local c,err=R:VerticalBox({id=spec.id,parent=spec.parent,gap=0,slot=spec.slot})
    if not c then return nil,err end
    c.items,c.timelineItems,c.liveItems={},{},{}
    c.sectionVersion=1
    local function Table(section)
        local cfg=Copy(spec);cfg.id=spec.id..'_'..section;cfg.parent=c;cfg.slot=nil;cfg.items={};cfg.columns={}
        cfg.getKey=spec.getKey or function(item)return item and (item.key or item.id)end
        cfg.desiredRows=1 -- 外层视口决定容量，不能用整个目录的 desiredRows 撑高父窗口。
        if section=='live' then cfg.rowHeight=math.min(tonumber(spec.rowHeight) or 24,20) end
        cfg.headerHeight=math.min(tonumber(spec.headerHeight) or 22,22)
        cfg.overlayScrollbar=true
        for i,column in ipairs(spec.columns or {})do cfg.columns[i]=Copy(column)end
        if cfg.columns[1] then cfg.columns[1].title=section=='live' and '实时区域' or '活动时间' end
        -- 显式建立双列表 activation trampoline，不依赖浅拷贝偶然携带回调。Native Row -> TableView ->
        -- 本桥 -> 页面/Widget -> QuestDetailFloatingV3；同时保留 Open 的第二返回值供模块诊断。
        cfg.onItemActivated=type(spec.onItemActivated)=='function' and function(item,index,key,_,reason)
            local combined=tonumber(index) or 0;if combined>0 and section=='live' then combined=combined+#c.timelineItems end
            local ok,result,detail=xpcall(function()return spec.onItemActivated(item,combined,key,c,reason)end,S.SafeTraceback or tostring)
            local accepted=RecordActivation(section,item,reason,ok,result,detail)
            if accepted~=true and ok==true and result==false and (detail==nil or tostring(detail)=='') and type(S.SafeChat)=='function' then
                S.SafeChat('[Replicated Suite] 活动详情入口不可用；请打开活动模块诊断查看 activity_detail_click。')
            end
            return accepted,detail
        end or nil
        -- DataViewSelectionContractVersion=2：index,previousIndex,view,model,reason,key,selected,context。
        cfg.onSelectionChanged=function(index,previousIndex,view,model,reason,key,selected,context)
            if c.changingSelection then return end
            c.changingSelection=true
            if tonumber(index) and index>0 then
                c.selectedView=section=='live' and c.live or c.timeline
                local other=section=='live' and c.timeline or c.live
                if other then other:ClearSelection() end
            elseif c.selectedView==view or c.selectedView==(section=='live' and c.live or c.timeline) then c.selectedView=nil end
            c.changingSelection=false
            if type(spec.onSelectionChanged)=='function' then
                local combined=tonumber(index) or 0
                if combined>0 and section=='live' then combined=combined+#c.timelineItems end
                spec.onSelectionChanged(combined,previousIndex,c,model,reason,key,selected,context)
            end
        end
        return R:TableView(cfg)
    end
    c.timeline=assert(Table('timeline'),'activity timeline table unavailable')
    c.live=assert(Table('live'),'activity live table unavailable')
    c.rowHeight=tonumber(spec.rowHeight) or 24
    c.headerHeight=math.min(tonumber(spec.headerHeight) or 22,22)
    -- 基准行高必须和运行时自适应值分离；否则下一次 Layout 会把上一次拉伸后的值当成新基准，
    -- 多次拖动窗口后产生行高漂移。
    c.timelineBaseRowHeight=math.max(12,tonumber(c.timeline.rowHeight) or c.rowHeight)
    c.liveBaseRowHeight=math.max(12,tonumber(c.live.rowHeight) or math.min(c.rowHeight,20))
    function c:SetItems(items,revision)
        if revision~=nil and self.itemRevision==revision then return false end
        local timeline,live={},{}
        for _,row in ipairs(type(items)=='table' and items or {})do
            local dest=Live(row) and live or timeline;dest[#dest+1]=row
        end
        local countChanged=#timeline~=#self.timelineItems or #live~=#self.liveItems
        self.timelineItems,self.liveItems,self.itemRevision=timeline,live,revision
        self.items={};for _,row in ipairs(timeline)do self.items[#self.items+1]=row end
        for _,row in ipairs(live)do self.items[#self.items+1]=row end
        self.timeline:SetItems(timeline,revision);self.live:SetItems(live,revision)
        if countChanged then self:InvalidateMeasure('activity_section_count') end
        if countChanged and self.width and self.height then self:Layout(self.x or 0,self.y or 0,self.width,self.height)end
        return true
    end
    function c:SetViewState(state,options)
        self.timeline:SetViewState(state,options);self.live:SetViewState(state,options);return true
    end
    function c:GetViewState()return self.timeline:GetViewState()end
    function c:GetItem(index)return self.items[tonumber(index) or 0]end
    function c:GetItemCount()return #self.items end
    function c:GetSelectedKey()return self.selectedView and self.selectedView:GetSelectedKey() or nil end
    function c:GetSelectedIndex()
        local index=self.selectedView and self.selectedView:GetSelectedIndex() or nil
        if index and index>0 and self.selectedView==self.live then return index+#self.timelineItems end
        return index
    end
    function c:SetSelectedIndex(index)
        index=tonumber(index) or 0
        if index<=0 then return self:ClearSelection() end
        if index>#self.timelineItems then return self.live:SetSelectedIndex(index-#self.timelineItems) end
        return self.timeline:SetSelectedIndex(index)
    end
    function c:ClearSelection(reason)
        self.changingSelection=true;self.timeline:ClearSelection();self.live:ClearSelection();self.selectedView=nil;self.changingSelection=false
        if type(spec.onSelectionChanged)=='function' then spec.onSelectionChanged(0,nil,self,nil,tostring(reason or 'clear'),nil,false,{view=self}) end
        return true
    end
    c.selectionFacade={Clear=function(_,reason)return c:ClearSelection(reason)end}
    function c:GetSelectionModel()return self.selectionFacade end
    function c:RefreshVisible(revision,force)self.timeline:RefreshVisible(revision,force);self.live:RefreshVisible(revision,force);return true end
    function c:Measure(w,h)
        -- 不在 Measure 写 Native；保持可压缩视口，否则小窗口会被五行区域的理想高度反向撑大。
        self.desiredWidth,self.desiredHeight=math.max(1,w or 260),math.max(1,math.min(h or 220,280))
        self.measureDirty=false;return self.desiredWidth,self.desiredHeight
    end
    function c:Layout(x,y,w,h)
        w,h=math.max(1,w or 1),math.max(1,h or 1);self:SetBounds(x,y,w,h)
        local timeCount=#self.timelineItems
        local liveCount=#self.liveItems
        local showLive=liveCount>0
        local showTime=timeCount>0 or not showLive
        -- 两分区之间不留装饰间隙。列表容量为 floor(viewport / rowHeight)，不画半行，
        -- 因此前置 timeline 必须量化为“表头 + 完整行”；余数交给最后的 live 视口，避免中间空带。

        local gap=0









        local timeRowHeight=math.max(1,tonumber(self.timelineBaseRowHeight) or self.rowHeight)
        local liveRowHeight=math.max(1,tonumber(self.liveBaseRowHeight) or math.min(self.rowHeight,20))
        local timeHeaderHeight=math.max(0,tonumber(self.timeline and self.timeline.headerHeight) or self.headerHeight)
        local liveHeaderHeight=math.max(0,tonumber(self.live and self.live.headerHeight) or self.headerHeight)
        local lh,th=0,h
        if showLive then
            if not showTime then
                lh,th=h,0
            else
                local timeMin=timeHeaderHeight+timeRowHeight
                local liveMin=liveHeaderHeight+liveRowHeight
                if h>=timeMin+liveMin+gap then
                    -- 优先给实时区域保留最多 5 行的稳定目标容量；如果窗口不足，再退到至少 1 行。
                    -- 无论走哪条分支，timeline 都只拿完整行，剩余像素统一归 live。
                    local liveWanted=liveHeaderHeight+math.min(5,liveCount)*liveRowHeight
                    local liveReserve=math.min(liveWanted,math.max(liveMin,h-timeMin-gap))
                    local availableForTime=math.max(timeMin,h-liveReserve-gap)
                    local visibleTimeRows=math.floor(math.max(0,availableForTime-timeHeaderHeight)/timeRowHeight)
                    visibleTimeRows=math.max(1,math.min(timeCount,visibleTimeRows))
                    th=timeHeaderHeight+visibleTimeRows*timeRowHeight
                    lh=h-th-gap
                    -- 数值防线：若未来 header/row policy 改动导致 live 低于 1 行，退回最小 live，
                    -- 再重新量化 timeline；禁止用负高度或半行“补齐”。
                    if lh<liveMin then
                        local maxTimeHeight=math.max(timeMin,h-liveMin-gap)
                        visibleTimeRows=math.floor(math.max(0,maxTimeHeight-timeHeaderHeight)/timeRowHeight)
                        visibleTimeRows=math.max(1,math.min(timeCount,visibleTimeRows))
                        th=timeHeaderHeight+visibleTimeRows*timeRowHeight
                        lh=h-th-gap
                    end
                else
                    -- 小到不足两个分区各“表头 + 1 行”时只保留实时区域；这和旧行为一致，
                    -- 避免两个 TableView 都进入半行/表头重叠状态。
                    showTime=false;gap=0;lh=h;th=0
                end
            end
        elseif showTime then
            -- 单分区沿用完整父视口；没有后续分区，因此尾部余数不会形成“中间空白带”。
            th=h
        end
        -- 视口确定后再微调行高：双分区 timeline 通常保持 24px，live 吸收尾数；单分区也适用。
        local runtimeTimeRow,timeVisibleRows,timeTail=timeRowHeight,0,0
        local runtimeLiveRow,liveVisibleRows,liveTail=liveRowHeight,0,0
        if showTime then
            runtimeTimeRow,timeVisibleRows,timeTail=ResolveAdaptiveRowHeight(th,timeHeaderHeight,timeCount,timeRowHeight,math.max(16,timeRowHeight-4),timeRowHeight+4)
            SetRuntimeRowHeight(self.timeline,runtimeTimeRow)
        else
            SetRuntimeRowHeight(self.timeline,timeRowHeight)
        end
        if showLive then
            runtimeLiveRow,liveVisibleRows,liveTail=ResolveAdaptiveRowHeight(lh,liveHeaderHeight,liveCount,liveRowHeight,math.max(16,liveRowHeight-2),liveRowHeight+4)
            SetRuntimeRowHeight(self.live,runtimeLiveRow)
        else
            SetRuntimeRowHeight(self.live,liveRowHeight)
        end

        -- live 已全显示且达到每行 +4px 上限时，将剩余像素分给 timeline 可见行，再重算 live。
        if showTime and showLive and liveTail>0.001 and timeVisibleRows>0 then
            local timeStretchCapacity=math.max(0,(timeRowHeight+4-runtimeTimeRow)*timeVisibleRows)
            local shift=math.min(liveTail,timeStretchCapacity)
            if shift>0.001 then
                runtimeTimeRow=runtimeTimeRow+shift/timeVisibleRows
                th=th+shift;lh=math.max(1,lh-shift)
                SetRuntimeRowHeight(self.timeline,runtimeTimeRow)
                runtimeLiveRow,liveVisibleRows,liveTail=ResolveAdaptiveRowHeight(lh,liveHeaderHeight,liveCount,liveRowHeight,math.max(16,liveRowHeight-2),liveRowHeight+4)
                SetRuntimeRowHeight(self.live,runtimeLiveRow)
            end
        end

        self.timeline:SetVisible(showTime);self.live:SetVisible(showLive)
        if showTime then self.timeline:SetHeaderVisible(th>=timeHeaderHeight+math.min(timeRowHeight,runtimeTimeRow));self.timeline:Layout(0,0,w,th)end
        if showLive then self.live:SetHeaderVisible(lh>=liveHeaderHeight+math.min(liveRowHeight,runtimeLiveRow));self.live:Layout(0,showTime and th+gap or 0,w,lh)end
        self.lastLayoutMetrics={timeHeight=th,liveHeight=lh,timeRowHeight=runtimeTimeRow,liveRowHeight=runtimeLiveRow,
            timeVisibleRows=timeVisibleRows,liveVisibleRows=liveVisibleRows,timeTail=timeTail,liveTail=liveTail}
        self.layoutDirty=false;return true
    end
    c:SetItems(spec.items or {},spec.revision)
    return c
end
