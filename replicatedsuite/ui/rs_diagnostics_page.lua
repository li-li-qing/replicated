------------------------------------------------------------------------
-- Replicated Suite - Diagnostics page
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S=ReplicatedSuite; S.DiagnosticsPage={}
function S.DiagnosticsPage.Create(parent)
    local page={key="diagnostics",root=S.UI:CreatePanel(parent,"diagnostics_page",0,0,100,100,"soft"),lines={},dynamicPage=1}
    if page.root.rsBorder and page.root.rsBorder.SetVisible then page.root.rsBorder:SetVisible(false) end
    if page.root.rsBackground and page.root.rsBackground.SetVisible then page.root.rsBackground:SetVisible(false) end
    page.title=S.UI:CreateLabel(page.root,"diagnostics_title","诊断",12,8,300,28,16,nil,ALIGN_LEFT)
    page.note=S.UI:CreateLabel(page.root,"diagnostics_note","统一记录本次加载以来的 Suite 日志；点击“打印全部日志”会一次输出一整段，方便直接复制。不会收集聊天内容或无关账号信息。",12,36,780,22,9,"muted",ALIGN_LEFT)
    page.refresh=S.UI:CreateButton(page.root,"diagnostics_refresh","刷新诊断",12,66,90,27,9,false)
    page.print=S.UI:CreateButton(page.root,"diagnostics_print","打印全部日志",108,66,120,27,9,false)
    page.acceptance=S.UI:CreateButton(page.root,"diagnostics_ui_acceptance","全页验收",234,66,82,27,9,false)
    page.foundation=S.UI:CreateButton(page.root,"diagnostics_foundation","V3地基验收",322,66,92,27,9,false)
    page.visualPreview=S.UI:CreateButton(page.root,"diagnostics_visual_preview","视觉预览",322,66,82,27,9,false)
    page.capture=S.UI:CreateButton(page.root,"diagnostics_capture","采样30秒",410,66,88,27,9,false)
    page.clearCapture=S.UI:CreateButton(page.root,"diagnostics_clear_capture","清除采样",328,66,88,27,9,false)
    page.captureLong=S.UI:CreateButton(page.root,"diagnostics_capture_long","采样120秒",422,66,88,27,9,false)
    page.prev=S.UI:CreateButton(page.root,"diagnostics_prev","上一页",516,66,62,27,8,false)
    page.next=S.UI:CreateButton(page.root,"diagnostics_next","下一页",582,66,62,27,8,false)
    page.pageLabel=S.UI:CreateLabel(page.root,"diagnostics_page_label","1/1",650,68,76,22,8,"muted",ALIGN_LEFT)
    for i=1,20 do page.lines[i]=S.UI:CreateLabel(page.root,"diagnostics_line_"..i,"",12,104+(i-1)*24,760,22,10,i<=7 and nil or "muted",ALIGN_LEFT) end
    S.UI:SafeHandler(page.refresh,"OnClick",function() page:Refresh() end,"diagnostics:refresh")
    S.UI:SafeHandler(page.prev,"OnClick",function() page.dynamicPage=math.max(1,(page.dynamicPage or 1)-1);page:Refresh() end,"diagnostics:prev")
    S.UI:SafeHandler(page.next,"OnClick",function() page.dynamicPage=(page.dynamicPage or 1)+1;page:Refresh() end,"diagnostics:next")
    S.UI:SafeHandler(page.print,"OnClick",function()
        if S.DiagnosticsManager ~= nil and type(S.DiagnosticsManager.PrintAllLogs) == "function" then
            S.DiagnosticsManager:PrintAllLogs()
        else
            S.SafeChat("诊断不可用")
        end
    end,"diagnostics:print")
    S.UI:SafeHandler(page.acceptance,"OnClick",function()
        if S.UIAcceptance ~= nil and type(S.UIAcceptance.Run) == "function" then
            S.UIAcceptance:Run(true)
            page:Refresh()
        else
            S.SafeChat("UI验收不可用")
        end
    end,"diagnostics:ui_acceptance")
    S.UI:SafeHandler(page.foundation,"OnClick",function()
        if S.FoundationGate ~= nil and type(S.FoundationGate.PrintReport) == "function" then
            S.FoundationGate:PrintReport()
            page:Refresh()
        else
            S.SafeChat("V3 Foundation Gate 不可用")
        end
    end,"diagnostics:foundation")
    S.UI:SafeHandler(page.visualPreview,"OnClick",function()
        if S.Visual ~= nil and S.Visual.Preview ~= nil and type(S.Visual.Preview.Open) == "function" then
            S.Visual.Preview:Open()
        else
            S.SafeChat("视觉预览不可用")
        end
    end,"diagnostics:visual_preview")
    S.UI:SafeHandler(page.capture,"OnClick",function()
        local monitor=S.PerformanceMonitor
        if monitor==nil or type(monitor.StartCapture)~="function" then S.SafeChat("性能监控不可用"); return end
        local ok,message=monitor:StartCapture(30); S.SafeChat(tostring(message or (ok and "性能采样已开始" or "性能采样启动失败"))); page:Refresh()
    end,"diagnostics:capture")
    S.UI:SafeHandler(page.captureLong,"OnClick",function()
        local monitor=S.PerformanceMonitor
        if monitor==nil or type(monitor.StartCapture)~="function" then S.SafeChat("性能监控不可用"); return end
        local ok,message=monitor:StartCapture(120); S.SafeChat(tostring(message or (ok and "性能采样已开始" or "性能采样启动失败"))); page:Refresh()
    end,"diagnostics:capture_long")
    S.UI:SafeHandler(page.clearCapture,"OnClick",function()
        if S.PerformanceMonitor~=nil and type(S.PerformanceMonitor.ClearCapture)=="function" then S.PerformanceMonitor:ClearCapture(); S.SafeChat("性能采样已清除") end
        page:Refresh()
    end,"diagnostics:clear_capture")
    function page:Refresh()
        local snap=S.DiagnosticsManager and S.DiagnosticsManager:Snapshot() or {}
        -- Keep the fixed summary compact and paginate the dynamic rows.  The
        -- Suite currently has more external modules than one 16-row page can
        -- show together with diagnostics history; silently truncating the tail
        -- made a healthy-looking first page hide a later Faulted module.
        local lines={
            "版本："..tostring(snap.version or "?")..(snap.buildTag and snap.buildTag~="" and (" · "..tostring(snap.buildTag)) or "").."  ·  Schema "..tostring(snap.saveSchema or "?").."  ·  语言 "..tostring(snap.clientLanguage or "Unknown"),
            "Scheduler："..tostring(snap.schedulerTasks or 0).." 任务 · Backlog "..tostring(snap.backlog and snap.backlog.health or "Unknown").."/"..tostring(snap.backlog and snap.backlog.pending or 0).." · Budget延期 "..tostring(snap.backlog and snap.backlog.deferredByBudget or 0).." · Storage "..(snap.storageError and ("异常 "..tostring(snap.storageError)) or "正常"),
            snap.frameBudget and ("FrameBudget｜"..tostring(snap.frameBudget.pressure or "Normal").." · Credit "..tostring(snap.frameBudget.creditsRemaining or 0).."/"..tostring(snap.frameBudget.creditsTotal or 0).." · 执行 "..tostring(snap.frameBudget.granted or 0).." · 延期 "..tostring(snap.frameBudget.deferred or 0).." · 保底 "..tostring(snap.frameBudget.starvationRuns or 0)) or "FrameBudget｜未加载",
            snap.performance and ("性能｜原生帧 "..string.format("%.1f",tonumber(snap.performance.lastFrameMs) or 0).."ms · 脚本间隔 "..(snap.performance.lastClockGapMs and string.format("%.1f",tonumber(snap.performance.lastClockGapMs) or 0) or "--").."ms · 卡顿 "..tostring(snap.performance.jankCount or 0).." / 未归因 "..tostring(snap.performance.unattributedStalls or 0)) or "性能｜未加载",
            snap.performance and ("详细采样｜"..(snap.performance.capture and (snap.performance.capture.active and ("进行中 "..tostring(snap.performance.capture.secondsRemaining or 0).."s") or "已完成") or "未开始").." · 回调计时 "..(snap.performance.timerAvailable and tostring(snap.performance.timerName or "可用") or "不可用")) or "",
            "API：可用 "..tostring(snap.api and snap.api.allowed or 0).." / 缺失 "..tostring(snap.api and snap.api.unavailable or 0).." / 已移除 "..tostring(snap.api and snap.api.retired or 0).." / 冲突 "..tostring(snap.api and snap.api.conflicts or 0),
            "诊断｜结构化 "..tostring(snap.structured and snap.structured.recent or 0).." · 限频抑制 "..tostring(snap.structured and snap.structured.suppressed or 0).." · 聚合键 "..tostring(snap.structured and snap.structured.rateKeys or 0),
            "GameData｜记录 "..tostring(snap.gameData and snap.gameData.totalRecords or 0).." · 集合 "..tostring(snap.gameData and snap.gameData.totalSets or 0).." · 无效 "..tostring(snap.gameData and snap.gameData.invalid or 0).." · 重复Key "..tostring(snap.gameData and snap.gameData.duplicateKeys or 0),
            "StaticDataV2｜目录 "..tostring(snap.staticDataV2 and snap.staticDataV2.catalogs or 0).." · 记录 "..tostring(snap.staticDataV2 and snap.staticDataV2.records or 0).." · 引用 "..tostring(snap.staticDataV2 and snap.staticDataV2.references or 0).." · 缺引用 "..tostring(snap.staticDataV2 and snap.staticDataV2.missingRefs or 0).." · 缺ID "..tostring(snap.staticDataV2 and snap.staticDataV2.missingRequiredIds or 0),
            "Persistence｜Store "..tostring(snap.persistence and snap.persistence.total or 0).." · Dirty "..tostring(snap.persistence and snap.persistence.dirty or 0).." · 写保护 "..tostring(snap.persistence and snap.persistence.fenced or 0).." · Save失败 "..tostring(snap.persistence and snap.persistence.stats and snap.persistence.stats.saveFailures or 0),
            "UI Framework｜Diff "..tostring(snap.ui and snap.ui.attempts or 0).." · Native写 "..tostring(snap.ui and snap.ui.nativeCalls or 0).." · 跳过 "..tostring(snap.ui and snap.ui.skips or 0).." ("..string.format("%.1f%%",(tonumber(snap.ui and snap.ui.skipRatio) or 0)*100)..") · Cache "..tostring(snap.ui and snap.ui.cachedWidgets or 0),
            "UI Design｜Token v"..tostring(snap.ui and snap.ui.design and snap.ui.design.tokens or "--").." · Layout "..tostring(snap.ui and snap.ui.design and snap.ui.design.layout and snap.ui.design.layout.placements or 0).."/响应 "..tostring(snap.ui and snap.ui.design and snap.ui.design.layout and snap.ui.design.layout.responsive or 0).." · Binding写 "..tostring(snap.ui and snap.ui.design and snap.ui.design.binding and snap.ui.design.binding.writes or 0).." · RSUI "..tostring(snap.ui and snap.ui.design and snap.ui.design.rsui and snap.ui.design.rsui.created or 0).."/"..tostring(snap.ui and snap.ui.design and snap.ui.design.rsui and snap.ui.design.rsui.registeredTypes or 0).."类 · 越界 "..tostring(snap.ui and snap.ui.design and snap.ui.design.rsui and snap.ui.design.rsui.layoutOverflowEvents or 0).."/边界 "..tostring(snap.ui and snap.ui.design and snap.ui.design.rsui and snap.ui.design.rsui.screenBoundaryIssues or 0).." · M跳过 "..tostring(snap.ui and snap.ui.design and snap.ui.design.rsui and snap.ui.design.rsui.measureSkips or 0).." · L跳过 "..tostring(snap.ui and snap.ui.design and snap.ui.design.rsui and snap.ui.design.rsui.layoutSkips or 0).." · 虚拟池 "..tostring(snap.ui and snap.ui.design and snap.ui.design.rsui and snap.ui.design.rsui.virtualPoolRowsCreated or 0).."/绑定 "..tostring(snap.ui and snap.ui.design and snap.ui.design.rsui and snap.ui.design.rsui.virtualRowBinds or 0).." · Tile "..tostring(snap.ui and snap.ui.design and snap.ui.design.rsui and snap.ui.design.rsui.tilePoolItemsCreated or 0).."/"..tostring(snap.ui and snap.ui.design and snap.ui.design.rsui and snap.ui.design.rsui.tileItemBinds or 0).." · 选择 "..tostring(snap.ui and snap.ui.design and snap.ui.design.rsui and snap.ui.design.rsui.selectionChanges or 0).." · 事件 "..tostring(snap.ui and snap.ui.design and snap.ui.design.rsui and snap.ui.design.rsui.eventDispatches or 0).." · Menu "..tostring(snap.ui and snap.ui.design and snap.ui.design.rsui and snap.ui.design.rsui.contextMenuOpens or 0),
            "UI验收｜"..tostring(S.UIAcceptance and type(S.UIAcceptance.GetLastSummaryText)=="function" and S.UIAcceptance:GetLastSummaryText() or "未加载"),
            "V3地基｜"..tostring(S.FoundationGate and type(S.FoundationGate.GetLastSummary)=="function" and S.FoundationGate:GetLastSummary() or "未运行").." · Host "..tostring(snap.uiHosts and snap.uiHosts.activeId or "--"),
            "模块故障 "..tostring(snap.moduleFaults or 0).." · HUD注册 "..tostring(#(snap.hudStates or {})).." · Observation "..(S.Observation and ("缓存 "..tostring((S.Observation:Describe() or {}).cacheCount or 0).."/订阅 "..tostring((S.Observation:Describe() or {}).subscriberCount or 0)) or "未加载"),
            "迁移："..tostring(snap.migration and snap.migration.suiteStatus or "unknown").." · 旧专业 Runtime 不启用",
        }
        -- Dynamic rows: module states first, then recent errors, within the
        -- fixed row pool.  Order preserves priority (faulted modules matter more
        -- than a deep error history that is also available via 打印全部日志).
        local dynamic = {}
        for _,d in ipairs(snap.moduleStates or {}) do
            if d.internal~=true then dynamic[#dynamic+1]="模块｜"..tostring(d.name).."："..tostring(d.state)..(d.lastError and (" · "..tostring(d.lastError)) or "") end
        end
        for _,store in ipairs(snap.persistence and snap.persistence.rows or {}) do
            if store.writeFenced or store.lastError then
                dynamic[#dynamic+1]="存储｜"..tostring(store.id).."："..tostring(store.loadStatus or "unknown").." · "..tostring(store.writeFenceReason or store.lastError or "异常")
            end
        end
        if snap.ui and type(snap.ui.byOwner)=="table" then
            for i=1,math.min(4,#snap.ui.byOwner) do
                local row=snap.ui.byOwner[i]
                dynamic[#dynamic+1]=string.format("UI写｜%s：Native %d · 写 %d · 跳过 %d",tostring(row.owner),tonumber(row.nativeCalls) or 0,tonumber(row.writes) or 0,tonumber(row.skips) or 0)
            end
        end
        if snap.frameBudget and type(snap.frameBudget.topDeferred)=="table" then
            for i=1,math.min(4,#snap.frameBudget.topDeferred) do
                local row=snap.frameBudget.topDeferred[i]
                dynamic[#dynamic+1]=string.format("预算｜%s：请求 %d · 延期 %d · 保底 %d · 最大连续延期 %d",tostring(row.owner),tonumber(row.requests) or 0,tonumber(row.deferred) or 0,tonumber(row.starvationRuns) or 0,tonumber(row.maxConsecutiveDefers) or 0)
            end
        end
        if snap.performance and type(snap.performance.top)=="table" then
            for _,row in ipairs(snap.performance.topModules or {}) do
                local calls=tonumber(row.calls) or 0; local avg=calls>0 and (tonumber(row.totalMs) or 0)/calls or 0
                dynamic[#dynamic+1]=string.format("模块性能｜%s：%d 次 · 总 %.3fms · 均 %.3fms · 最大 %.3fms · 卡顿 %d",tostring(row.moduleId),calls,tonumber(row.totalMs) or 0,avg,tonumber(row.maxMs) or 0,tonumber(row.jankHits) or 0)
            end
            for _,row in ipairs(snap.performance.top) do
                local calls=tonumber(row.calls) or 0; local avg=calls>0 and (tonumber(row.totalMs) or 0)/calls or 0
                dynamic[#dynamic+1]=string.format("性能｜%s：%d 次 · 总 %.3fms · 均 %.3fms · 最大 %.3fms · 卡顿 %d",tostring(row.label),calls,tonumber(row.totalMs) or 0,avg,tonumber(row.maxMs) or 0,tonumber(row.jankHits) or 0)
            end
        end
        if snap.performance and type(snap.performance.worstJank)=="table" then
            for _,row in ipairs(snap.performance.worstJank) do
                dynamic[#dynamic+1]=string.format("最长卡顿｜%.1fms（原生 %.1fms%s）· %s · %s",tonumber(row.dtMs) or 0,tonumber(row.nativeDtMs) or tonumber(row.dtMs) or 0,row.clockGapMs and (" / 脚本 "..string.format("%.1f",tonumber(row.clockGapMs) or 0).."ms") or "",tostring(row.kind or "关联上一帧 Suite 回调"),tostring(row.labels or "无 Suite 回调"))
            end
        end
        for _,e in ipairs(snap.recentErrors or {}) do
            dynamic[#dynamic+1]="最近｜"..tostring(e.source).." ["..tostring(e.code or "LEGACY").."]："..tostring(e.message)..((tonumber(e.count) or 1)>1 and (" · x"..tostring(e.count)) or "")
        end
        for _,row in ipairs(snap.structured and snap.structured.counters or {}) do
            dynamic[#dynamic+1]="计数｜"..tostring(row.source).." ["..tostring(row.code).."]："..tostring(row.count)
        end
        local maxDynamic = math.max(1,#self.lines - #lines)
        local pageCount = math.max(1,math.ceil(#dynamic/maxDynamic))
        self.dynamicPage = math.max(1,math.min(pageCount,math.floor(tonumber(self.dynamicPage) or 1)))
        local startIndex=(self.dynamicPage-1)*maxDynamic+1
        for i=0,maxDynamic-1 do lines[#lines+1] = dynamic[startIndex+i] or "" end
        S.UI:SetEnabled(self.prev,pageCount>1 and self.dynamicPage>1,"diagnostics")
        S.UI:SetEnabled(self.next,pageCount>1 and self.dynamicPage<pageCount,"diagnostics")
        S.UI:SetText(self.pageLabel,tostring(self.dynamicPage).."/"..tostring(pageCount),"diagnostics")
        for i,l in ipairs(self.lines) do
            local text=lines[i] or ""
            S.UI:SetText(l,text,"diagnostics")
            S.UI:SetVisible(l,text~="","diagnostics")
        end
    end
    function page:ApplyLayout(spec)
        S.UI:SetAnchor(self.root,parent,0,0,"diagnostics"); S.UI:SetExtent(self.root,spec.contentWidth,spec.contentHeight,"diagnostics")
        local sc=S.Layout:GetContext().addonScale; local pad=12*sc; local full=math.max(1,spec.contentWidth-pad*2)
        S.UI:SetExtent(self.title,full,28*sc,"diagnostics"); S.UI:SetAnchor(self.title,self.root,pad,6*sc,"diagnostics"); S.UI:SetExtent(self.note,full,22*sc,"diagnostics"); S.UI:SetAnchor(self.note,self.root,pad,34*sc,"diagnostics")

        -- M6 responsive toolbar: button widths remain readable, but the row wraps
        -- from the actual content width. This replaces the former fixed 638px
        -- anchor chain that overflowed 1024x768 at 120% addon scale.
        local toolbarY=62*sc; local toolbarGap=6*sc; local toolbarH=27*sc
        local toolbar={
            {self.refresh,90},{self.print,120},{self.acceptance,82},{self.foundation,92},{self.visualPreview,82},{self.capture,88},{self.clearCapture,88},{self.captureLong,88},{self.prev,62},{self.next,62},{self.pageLabel,60,true},
        }
        local x=pad; local y=toolbarY; local rows=1
        for _,entry in ipairs(toolbar) do
            local control=entry[1]; local w=entry[2]*sc; local h=(entry[3] and 22 or 27)*sc
            if x>pad and x+w>pad+full then x=pad; y=y+toolbarH+5*sc; rows=rows+1 end
            S.UI:SetExtent(control,w,h,"diagnostics"); S.UI:SetAnchor(control,self.root,x,y+(entry[3] and 2*sc or 0),"diagnostics")
            x=x+w+toolbarGap
        end
        local top=toolbarY+rows*(toolbarH+5*sc)+3*sc
        local available=math.max(1,spec.contentHeight-top-6*sc)
        local step=math.max(14*sc,math.min(26*sc,available/#self.lines))
        for i,l in ipairs(self.lines) do S.UI:SetExtent(l,full,step,"diagnostics"); S.UI:SetAnchor(l,self.root,pad,top+(i-1)*step,"diagnostics") end
        self:Refresh()
    end
    S.UI.pages.diagnostics=page; return page
end
