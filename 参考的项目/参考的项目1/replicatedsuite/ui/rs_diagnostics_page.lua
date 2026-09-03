------------------------------------------------------------------------
-- Replicated Suite - Diagnostics page
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S=ReplicatedSuite; S.DiagnosticsPage={}
function S.DiagnosticsPage.Create(parent)
    local page={root=S.UI:CreatePanel(parent,"diagnostics_page",0,0,100,100,"soft"),lines={},dynamicPage=1}
    if page.root.rsBorder and page.root.rsBorder.SetVisible then page.root.rsBorder:SetVisible(false) end
    if page.root.rsBackground and page.root.rsBackground.SetVisible then page.root.rsBackground:SetVisible(false) end
    page.title=S.UI:CreateLabel(page.root,"diagnostics_title","诊断",12,8,300,28,16,nil,ALIGN_LEFT)
    page.note=S.UI:CreateLabel(page.root,"diagnostics_note","统一记录本次加载以来的 Suite 日志；点击“打印全部日志”会一次输出一整段，方便直接复制。不会收集聊天内容或无关账号信息。",12,36,780,22,9,"muted",ALIGN_LEFT)
    page.refresh=S.UI:CreateButton(page.root,"diagnostics_refresh","刷新诊断",12,66,90,27,9,false)
    page.print=S.UI:CreateButton(page.root,"diagnostics_print","打印全部日志",108,66,120,27,9,false)
    page.capture=S.UI:CreateButton(page.root,"diagnostics_capture","采样30秒",234,66,88,27,9,false)
    page.clearCapture=S.UI:CreateButton(page.root,"diagnostics_clear_capture","清除采样",328,66,88,27,9,false)
    page.captureLong=S.UI:CreateButton(page.root,"diagnostics_capture_long","采样120秒",422,66,88,27,9,false)
    page.prev=S.UI:CreateButton(page.root,"diagnostics_prev","上一页",516,66,62,27,8,false)
    page.next=S.UI:CreateButton(page.root,"diagnostics_next","下一页",582,66,62,27,8,false)
    page.pageLabel=S.UI:CreateLabel(page.root,"diagnostics_page_label","1/1",650,68,76,22,8,"muted",ALIGN_LEFT)
    for i=1,16 do page.lines[i]=S.UI:CreateLabel(page.root,"diagnostics_line_"..i,"",12,104+(i-1)*24,760,22,10,i<=7 and nil or "muted",ALIGN_LEFT) end
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
            "版本："..tostring(snap.version or "?").."  ·  Schema "..tostring(snap.saveSchema or "?").."  ·  语言 "..tostring(snap.clientLanguage or "Unknown"),
            "Scheduler："..tostring(snap.schedulerTasks or 0).." 任务 · Backlog "..tostring(snap.backlog and snap.backlog.health or "Unknown").."/"..tostring(snap.backlog and snap.backlog.pending or 0).." · Storage "..(snap.storageError and ("异常 "..tostring(snap.storageError)) or "正常"),
            snap.performance and ("性能｜原生帧 "..string.format("%.1f",tonumber(snap.performance.lastFrameMs) or 0).."ms · 脚本间隔 "..(snap.performance.lastClockGapMs and string.format("%.1f",tonumber(snap.performance.lastClockGapMs) or 0) or "--").."ms · 卡顿 "..tostring(snap.performance.jankCount or 0).." / 未归因 "..tostring(snap.performance.unattributedStalls or 0)) or "性能｜未加载",
            snap.performance and ("详细采样｜"..(snap.performance.capture and (snap.performance.capture.active and ("进行中 "..tostring(snap.performance.capture.secondsRemaining or 0).."s") or "已完成") or "未开始").." · 回调计时 "..(snap.performance.timerAvailable and tostring(snap.performance.timerName or "可用") or "不可用")) or "",
            "API：可用 "..tostring(snap.api and snap.api.allowed or 0).." / 缺失 "..tostring(snap.api and snap.api.unavailable or 0).." / 已移除 "..tostring(snap.api and snap.api.retired or 0).." / 冲突 "..tostring(snap.api and snap.api.conflicts or 0),
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
        for _,e in ipairs(snap.recentErrors or {}) do dynamic[#dynamic+1]="最近｜"..tostring(e.source).."："..tostring(e.message) end
        local maxDynamic = math.max(1,#self.lines - #lines)
        local pageCount = math.max(1,math.ceil(#dynamic/maxDynamic))
        self.dynamicPage = math.max(1,math.min(pageCount,math.floor(tonumber(self.dynamicPage) or 1)))
        local startIndex=(self.dynamicPage-1)*maxDynamic+1
        for i=0,maxDynamic-1 do lines[#lines+1] = dynamic[startIndex+i] or "" end
        if self.prev.Enable then self.prev:Enable(pageCount>1 and self.dynamicPage>1) end
        if self.next.Enable then self.next:Enable(pageCount>1 and self.dynamicPage<pageCount) end
        self.pageLabel:SetText(tostring(self.dynamicPage).."/"..tostring(pageCount))
        for i,l in ipairs(self.lines) do local text=lines[i] or ""; l:SetText(text); l:Show(text~="") end
    end
    function page:ApplyLayout(spec)
        S.UI:SetAnchor(self.root,parent,0,0); self.root:SetExtent(spec.contentWidth,spec.contentHeight)
        local sc=S.Layout:GetContext().addonScale; local pad=12*sc; local full=math.max(1,spec.contentWidth-pad*2)
        self.title:SetExtent(full,28*sc); S.UI:SetAnchor(self.title,self.root,pad,6*sc); self.note:SetExtent(full,22*sc); S.UI:SetAnchor(self.note,self.root,pad,34*sc)
        self.refresh:SetExtent(90*sc,27*sc); S.UI:SetAnchor(self.refresh,self.root,pad,62*sc); self.print:SetExtent(120*sc,27*sc); S.UI:SetAnchor(self.print,self.root,pad+96*sc,62*sc)
        self.capture:SetExtent(88*sc,27*sc);S.UI:SetAnchor(self.capture,self.root,pad+222*sc,62*sc);self.clearCapture:SetExtent(88*sc,27*sc);S.UI:SetAnchor(self.clearCapture,self.root,pad+316*sc,62*sc);self.captureLong:SetExtent(88*sc,27*sc);S.UI:SetAnchor(self.captureLong,self.root,pad+410*sc,62*sc)
        self.prev:SetExtent(62*sc,27*sc);S.UI:SetAnchor(self.prev,self.root,pad+504*sc,62*sc);self.next:SetExtent(62*sc,27*sc);S.UI:SetAnchor(self.next,self.root,pad+570*sc,62*sc);self.pageLabel:SetExtent(76*sc,22*sc);S.UI:SetAnchor(self.pageLabel,self.root,pad+638*sc,65*sc)
        local top=96*sc; local step=math.max(20*sc,math.min(26*sc,(spec.contentHeight-top-6*sc)/#self.lines)); for i,l in ipairs(self.lines) do l:SetExtent(full,step); S.UI:SetAnchor(l,self.root,pad,top+(i-1)*step) end
        self:Refresh()
    end
    S.UI.pages.diagnostics=page; return page
end
