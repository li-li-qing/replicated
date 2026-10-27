-- Replicated Suite · 自检报告格式化
-- 作者：Replicated
-- QQ群：1104129461
-- 用户打印时收集一次 Gate 只读检查、错误与故障 Store 证据，冻结成完整文本，由页面分页供 Ctrl+C。
-- 不恢复或写入业务，不启用 Feature；聊天仅发一条交付回执，报告只存当前页面内存。
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local D = S.DiagnosticsManager
if type(D) ~= "table" then return end

-- 分页不应被旧2048字节摘要上限提前截断；单条16KiB、64条仍有界，重复只计数。
-- 日志先保留字符串片段，打印时一次连接，避免每个高频错误都复制整个报告。
local ISSUE_MAX, MESSAGE_MAX = 64, 16384
local REPORT_MAX, DETAIL_MAX, EVIDENCE_COUNT_MAX = 1048576, 196608, 8
D.SelfCheckReportContractVersion = 3
D.SelfCheckReportMaxBytes = REPORT_MAX
D.SelfCheckGeneration = S.Generation
local issues, issueOrder, evicted, clippedMessages = {}, {}, 0, 0
local reportSequence, building = 0, false

local function Now()
    return type(S.NowMs) == "function" and math.max(0, tonumber(S.NowMs()) or 0) or 0
end
local function Text(value)
    if type(value) == "string" then return value end
    if value == nil then return "nil" end
    local ok, str = pcall(tostring, value)
    return ok and str or "<unprintable>"
end
local function Clip(value, limit)
    local str = Text(value)
    local shortened = #str > limit
    -- 旧诊断可能先按字节截断中文，留下不完整 UTF-8；系统剪贴板不能可靠传输
    -- 这些字节。只在展示层逐字节校验并用 \xHH 明示原字节，不猜测原字、不改 HEX 原档。
    -- 在扫描前限长，避免早期巨型日志在错误路径形成无界临时分配；丢尾明确标识。
    if shortened then str=str:sub(1,limit) end
    str=str:gsub("\r\n", "\n"):gsub("\r", "\n")
    local out,index={},1
    while index<=#str do
        local byte=str:byte(index)
        local width=byte<128 and 1 or (byte>=194 and byte<=223 and 2 or (byte>=224 and byte<=239 and 3 or (byte>=240 and byte<=244 and 4 or 0)))
        local valid=width>0 and index+width-1<=#str
        if valid and width>1 then
            for offset=1,width-1 do local tail=str:byte(index+offset);if tail<128 or tail>191 then valid=false;break end end
            local second=str:byte(index+1)
            if (byte==224 and second<160) or (byte==237 and second>159) or (byte==240 and second<144) or (byte==244 and second>143) then valid=false end
        end
        if valid and (byte>=32 or byte==10 or byte==9) and byte~=127 then
            out[#out+1]=str:sub(index,index+width-1);index=index+width
        else
            out[#out+1]=string.format("\\x%02X",byte);index=index+1
        end
    end
    str=table.concat(out)
    if #str<=limit and not shortened then return str,false end
    local cut=math.max(0,limit-20)
    local nextByte=str:byte(cut+1)
    while cut>0 and nextByte and nextByte>=128 and nextByte<192 do cut=cut-1;nextByte=str:byte(cut+1) end
    return str:sub(1,cut).."<text_omitted>",true
end

-- 统一 RecordLog 是捕获入口，避免 Diagnostics.Record 与 SafeChat 双重计数。
-- 普通 info 不进入错误环；同一 level/source/message 聚合次数，最老的不同错误超过 64
-- 才淘汰并计数。只保存字符串/时间，不能持有 Domain/Native 对象。没有轮询和日志递归。
function D:CaptureSelfCheckIssue(row)
    if type(row) ~= "table" then return end
    local level = Text(row.level):lower()
    if level == "warn" then level = "warning" end
    if level ~= "warning" and level ~= "error" then return end
    local source = Clip(row.source or "suite", 96)
    local message, clipped = Clip(row.message or "", MESSAGE_MAX)
    if clipped then clippedMessages = clippedMessages + 1 end
    local key = level .. "\0" .. source .. "\0" .. message
    local item = issues[key]
    if item then
        item.count = item.count + 1; item.lastAt = tonumber(row.at) or Now()
        item.lastSeq = tonumber(row.seq) or item.lastSeq
        return
    end
    if #issueOrder >= ISSUE_MAX then
        issues[table.remove(issueOrder, 1)] = nil; evicted = evicted + 1
    end
    issueOrder[#issueOrder + 1] = key
    issues[key] = {level=level, source=source, message=message, count=1,
        firstAt=tonumber(row.at) or Now(), lastAt=tonumber(row.at) or Now(),
        firstSeq=tonumber(row.seq) or 0, lastSeq=tonumber(row.seq) or 0, clipped=clipped}
end

function D:GetSelfCheckIssueSnapshot()
    local rows = {}
    for _, key in ipairs(issueOrder) do
        local copy = {}; for k, value in pairs(issues[key]) do copy[k] = value end
        rows[#rows + 1] = copy
    end
    return {rows=rows, evicted=evicted, clippedMessages=clippedMessages,
        captureFailures=tonumber(S.SelfCheckCaptureFailures) or 0,
        suppressed=tonumber(self.suppressed) or 0, generation=S.Generation}
end
-- TOC 在 Bootstrap 之后才装载本模块；回放现有有界日志补齐早期错误，不读取旧存档。
-- 新 generation 新建此环，不能将上轮进程内存冒充本次错误；覆盖丢失会在报告中说明。
for _, row in ipairs(type(S.LogBuffer) == "table" and S.LogBuffer or {}) do D:CaptureSelfCheckIssue(row) end

function D:RunSelfCheck()
    local gate = S.FoundationGate
    local ok, result
    if type(gate) == "table" and type(gate.Run) == "function" then
        ok, result = pcall(gate.Run, gate, {skipSequences=true})
    else ok, result = false, "FoundationGate unavailable" end
    if not ok or type(result) ~= "table" then
        -- 自检自身出错不是通过；不复用旧 Gate.last 的 READY，不阻止后续证据收集。
        result = {status="ERROR", blockers=0, warnings=0, checks={},
            error=Clip(result or "self_check_return_type", 4096)}
    end
    self.lastSelfCheck = result
    self.lastSelfCheckAt = Now()
    return result
end

-- 快照格式化只用于诊断，不是存档序列化。节点/深度/字数都有界；任何丢失明确标识。
-- 对受控公共 getter 逐个 pcall；一个 Provider 坏掉不能让剩余故障和只读存档一起消失。
local function Format(value)
    local parts, bytes, nodes, seen, partial = {}, 0, 0, {}, false
    local function Add(str)
        if bytes + #str > 32768 then error("section_byte_limit") end
        parts[#parts + 1] = str; bytes = bytes + #str
    end
    local function Walk(item, depth)
        nodes = nodes + 1
        if nodes > 4096 then partial=true;Add("<nodes_omitted>");return end
        local kind = type(item)
        if kind ~= "table" then
            if kind == "function" or kind == "userdata" or kind == "thread" then Add("<" .. kind .. ">");return end
            local str, clipped = Clip(item, MESSAGE_MAX);partial=partial or clipped
            Add(kind == "string" and ("\"" .. str:gsub("\n", "\\n"):gsub('"','\\"') .. "\"") or str)
            return
        end
        if seen[item] then partial=true;Add("<cycle>");return end
        if depth > 8 then partial=true;Add("<depth_omitted>");return end
        seen[item] = true
        local keys = {};for k in pairs(item) do
            keys[#keys + 1] = k
            if #keys > 256 then break end
        end
        table.sort(keys, function(a,b)
            if type(a) ~= type(b) then return type(a) < type(b) end
            if type(a) == "number" or type(a) == "string" then return a < b end
            return Text(a) < Text(b)
        end)
        Add("{")
        for index = 1, math.min(#keys, 256) do
            if index > 1 then Add(", ") end
            local key, clipped = Clip(keys[index], 96);partial=partial or clipped
            Add(key .. "=");Walk(item[keys[index]], depth + 1)
        end
        if #keys > 256 then partial=true;Add(", <entries_omitted>") end
        Add("}");seen[item]=nil
    end
    local ok, err = pcall(Walk, value, 0)
    if not ok then partial=true;parts[#parts+1]="\n<section_incomplete:"..Clip(err,160)..">" end
    return table.concat(parts), partial
end

-- paged沿用完整失败/历史/原档收集，只不重复全量健康快照和info日志；编辑框容量
-- 只影响分段，不影响内容选择。旧全量/短报告接口保留内部兼容，不再充当默认页面路径。
local function BuildReport(self, mode)
    local check = self:RunSelfCheck()
    reportSequence = reportSequence + 1
    local meta = {id=tostring(S.Generation or 0).."."..reportSequence, check=check, partial=check.status=="ERROR",
        providersFailed=0, evidenceIncluded=0, evidenceFailed=0, evidenceOmitted=0, kind=mode}
    local parts, bytes, detailBytes = {}, 0, 0
    local detailWriter = type(S.DiagnosticDetail)=='table' and S.DiagnosticDetail:New() or nil
    if detailWriter then detailWriter:Add('selfCheck.allChecks',check) end
    local function Add(str, raw)
        str = Text(str) .. "\n"
        if #str + bytes > REPORT_MAX - 2048 or (not raw and #str + detailBytes > DETAIL_MAX) then
            meta.partial=true;meta.sectionsOmitted=(meta.sectionsOmitted or 0)+1
            return false
        end
        parts[#parts+1]=str;bytes=bytes+#str
        if not raw then detailBytes=detailBytes+#str end
        return true
    end
    local function Section(label, value)
        if detailWriter then detailWriter:Add(label, value) end
        local str, incomplete = Format(value);meta.partial=meta.partial or incomplete
        return Add("["..label.."]\n"..str)
    end
    local function Collect(label, object, method, ...)
        if type(object) ~= "table" or type(object[method]) ~= "function" then
            if detailWriter then detailWriter:Add(label,{available=false,reason='provider_unavailable',method=method}) end
            Add("["..label.."] unavailable");return nil
        end
        local ok, result, err = pcall(object[method],object,...)
        if not ok or result == nil or result == false then
            if detailWriter then detailWriter:Add(label,{available=false,error=not ok and result or err or 'no_snapshot'}) end
            meta.providersFailed=meta.providersFailed+1;meta.partial=true
            Add("["..label.."] ERROR "..Clip(not ok and result or err or "no_snapshot",4096))
            return nil
        end
        Section(label,result);return result
    end
    Add("RS-SELF-CHECK-1\nID="..meta.id.."\nBUILD="..Text(S.BuildTag).."\nLUA="..Text(_VERSION).."\nPATCH=paged-udf-proof-1\nCAPTURED_MS="..Now())
    Add("范围：本次加载以来本插件已记录的错误；未记录/已淘汰/重载前/其他插件与客户端内部错误无法自动补回。")
    Add("隐私：报告可能含角色名、配置、死亡记录；仅本地生成，未自动上传。故障存档为本次 LoadData 快照，未验证，不是磁盘原始字节。")
    -- 正常检查的说明可能比失败多数十倍，不能先序列化全部 healthy 检查耗尽
    -- 32KiB section 预算而截掉尾部阻断。总数保留，失败逐项输出，未运行与异常独立标记。
    Section("SELF_CHECK",{status=check.status,blockers=check.blockers,warnings=check.warnings,
        checkCount=type(check.checks)=="table" and #check.checks or 0,error=check.error,sequences=check.sequences})
    -- 只复制配方扫描已有证据，不因生成报告触发读取或新建消费端。
    local craft=S.Features and S.Features.tools_craft
    if craft and type(craft.GetRecipeReadDiagnostics)=='function' then Collect('CRAFT_RECIPE_READ',craft,'GetRecipeReadDiagnostics') end
    for _,row in ipairs(type(check.checks)=="table" and check.checks or {}) do
        if row.ok~=true then Section("FAILED_CHECK",row) end
    end
    Section("BOOT",{generation=S.Generation,ready=S.Ready,stage=S.BootStage})
    -- 历史错误先于庞大快照写入预算，防止健康信息挤掉真正需要定位的异常。
    local history=self:GetSelfCheckIssueSnapshot()
    meta.issueCount=#history.rows
    Add("[COVERAGE] issueEvicted="..history.evicted.." logDropped="..tostring(S.LogDropped or 0)
        .." clippedMessages="..history.clippedMessages.." suppressed="..history.suppressed.." captureFailures="..history.captureFailures)
    if history.evicted>0 or history.clippedMessages>0 or history.captureFailures>0 or (tonumber(S.LogDropped)or 0)>0 then meta.partial=true end
    for _,row in ipairs(history.rows) do Section("RECORDED_ERROR",row) end

    -- 分页报告也读取现有性能、调度和输入计数，不启动采样或抢焦点；帧间隔和零计时不能当作回调耗时。
    local performance = Collect("PERFORMANCE",S.PerformanceMonitor,"Snapshot")
    Section("PERFORMANCE_COVERAGE",{
        patch="mouse-load-evidence-1",capturedAtMs=Now(),
        callbackTimingCaptured=type(performance)=="table" and performance.capture~=nil and performance.timerAvailable==true,
        interpretation="帧间隔不是原生 API 耗时；未启动详细捕获时，零耗时不代表调用免费；标签关联不能证明视角突转根因。",
    })
    Collect("SCHEDULER_RUNTIME",S.Scheduler,"DescribeBacklog")
    -- 只枚举名字，任务字段通过既有公开 GetTaskState；不导出 callback/owner 或 Native 对象。
    local scheduler=S.Scheduler
    if type(scheduler)=="table" and type(scheduler.tasks)=="table" and type(scheduler.GetTaskState)=="function" then
        local names={};for name in pairs(scheduler.tasks)do names[#names+1]=tostring(name)end
        table.sort(names)
        for index=1,math.min(#names,128)do Collect("SCHEDULER_TASK:"..names[index],scheduler,"GetTaskState",names[index])end
        if #names>128 then meta.partial=true;Section("SCHEDULER_TASK_COVERAGE",{total=#names,omitted=#names-128})end
    end
    Collect("UI_INPUT_AND_WRITES",S.UI,"GetFrameworkSnapshot")
    -- 独立插件是可选被观察对象；只复制当前代次标量，不调用它的 Sample/Update/Save/UI。
    local potion=rawget(_G,"LCotPotionSignal")
    if type(potion)=="table" then
        local rows={}
        for index=1,3 do
            local row=type(potion.rows)=="table" and potion.rows[index] or nil
            if type(row)=="table" then rows[index]={itemId=row.itemId,skillId=row.skillId,slot=row.slot,
                stock=row.stock,remaining=row.remaining,at=row.at,emptyScanAt=row.emptyScanAt,emptyConfirmed=row.emptyConfirmed}end
        end
        Section("LCOT_POTION_RUNTIME",{present=true,generation=potion.generation,running=potion.running,
            enabled=potion.enabled,panelOpen=potion.panelOpen,error=potion.error,nowMs=potion.now,
            bagDirty=potion.bagDirty,bagScanAt=potion.bagScanAt,signalIndex=potion.signalIndex,signalVisible=potion.signalVisible,
            recording=potion.arm~=nil,crossRecording=potion.armCross~=nil,rows=rows,
            coverage="仅插件缓存状态；不包含外部 LCot 程序、鼠标位移或药品 API 执行耗时。"})
    else Section("LCOT_POTION_RUNTIME",{present=false,coverage="全局实例未观察到，不证明外部 LCot 程序是否运行。"})end

    if mode=='paged' then
        Collect("PERSISTENCE_FAILURES",self,"BuildPersistenceFailureReport")
        -- 物理恢复探针只存在于本次 Load 缓存，RAW_STORE 不含候选拒绝原因，因此也复制 lastPhysicalTransportRepair*。
        -- 只附当前故障 Store，页面翻页共用冻结文本；不重读盘或运行恢复。单字符串仍限 16KiB。
        local physicalRows = {}
        for _, st in pairs(type(S.Persistence)=='table' and S.Persistence.stores or {}) do
            if type(st)=='table' and (st.writeFenced==true or st.loadStatus=='integrity_failed')
                and (st.lastPhysicalTransportRepairProbe~=nil or st.lastPhysicalTransportRepairError~=nil) then
                physicalRows[#physicalRows+1] = {
                    store=st.id,
                    ok=st.lastPhysicalTransportRepairOk==true,
                    at=st.lastPhysicalTransportRepairAt,
                    probe=st.lastPhysicalTransportRepairProbe,
                    error=st.lastPhysicalTransportRepairError,
                }
            end
        end
        table.sort(physicalRows,function(a,b)return Text(a.store)<Text(b.store)end)
        if #physicalRows>0 then Section("PERSISTENCE_PHYSICAL_REPAIR",physicalRows) end
        -- 只读已有诊断页输入计数，区分失焦与重复布局；不读正文，也不把它当剪贴板成功证明。
        local host=S.UIV3 and S.UIV3.PageHost
        local page=host and type(host.pages)=="table" and host.pages["system.diagnostics"] or nil
        if type(page)=="table" and type(page.GetReportInputSnapshot)=="function" then
            Collect("REPORT_INPUT",page,"GetReportInputSnapshot")
        end
        Collect("RUNTIME",S.Runtime,"Describe")
        Collect("PAGE_HOST",S.UIV3 and S.UIV3.PageHost,"Describe")
        Collect("ACTIONS",S.ActionRunner,"GetSnapshot")
        Collect("FEATURE_STATUS",self,"BuildFeatureStatusRows")
        -- 只读 AuctionSearchBridgeV3 快照，区分直接查询可用与原生搜索框未同步，不因报告触发搜索。
        if type(S.Services and S.Services.AuctionSearchBridgeV3) == "table"
            and type(S.Services.AuctionSearchBridgeV3.GetSnapshot) == "function" then
            Collect("AUCTION_SEARCH_BRIDGE",S.Services.AuctionSearchBridgeV3,"GetSnapshot")
        end
        if type(S.Services and S.Services.DailyAuctionMaterialsV3) == "table" and type(S.Services.DailyAuctionMaterialsV3.GetDiagnosticsSnapshot) == "function" then
            Collect("DAILY_AUCTION_MATERIALS",S.Services.DailyAuctionMaterialsV3,"GetDiagnosticsSnapshot")
        end
    else
    local persistence=Collect("PERSISTENCE",S.Persistence,"Describe")
    meta.fenced=type(persistence)=="table" and persistence.fenced or nil
    Collect("PERSISTENCE_DETAILS",self,"BuildPersistenceFailureReport")
    Collect("PERSISTENCE_ACCEPTANCE",S.Persistence,"BuildRuntimeAcceptanceSnapshot",{includeAllV3=true})
    Collect("RUNTIME",S.Runtime,"Describe")
    Collect("FEATURE_RUNTIME",S.FeatureRuntime,"Describe")
    Collect("FEATURE_STATUS",self,"BuildFeatureStatusRows")
    if type(S.Services and S.Services.AuctionSearchBridgeV3) == "table"
        and type(S.Services.AuctionSearchBridgeV3.GetSnapshot) == "function" then
        Collect("AUCTION_SEARCH_BRIDGE",S.Services.AuctionSearchBridgeV3,"GetSnapshot")
    end
    if type(S.Services and S.Services.DailyAuctionMaterialsV3) == "table" and type(S.Services.DailyAuctionMaterialsV3.GetDiagnosticsSnapshot) == "function" then
        Collect("DAILY_AUCTION_MATERIALS",S.Services.DailyAuctionMaterialsV3,"GetDiagnosticsSnapshot")
    end
    Collect("SCHEDULER",S.Scheduler,"DescribeBacklog")
    Collect("DEMAND",S.Demand,"Describe")
    Collect("REFRESH",S.RefreshCoordinator,"Describe")
    Collect("NATIVE",S.NativeCapabilities,"Describe")
    local v3=S.UIV3 or {};local ui=S.UI or {};local rsui=S.RSUI or {}
    Collect("PAGE_HOST",v3.PageHost,"Describe")
    Collect("WIDGET_HOST",v3.WidgetHost,"Describe")
    Collect("ACTIONS",S.ActionRunner,"GetSnapshot")
    Collect("UI",ui,"GetFrameworkSnapshot")
    Collect("UI_THEME",S.Theme,"GetPaletteDiagnostics")
    Collect("UI_AUTHORITY",ui,"GetAuthoritySnapshot")
    Collect("BINDINGS",ui.Binding,"GetSnapshot")
    Collect("VIEW_STATE",rsui.ViewState,"GetSnapshot")
    -- 这里只读取 RSUI 输入事务快照，不 Acquire 功能、
    -- 不读取/输出草稿文本，避免报告泄露用户正在输入的内容；用于实机区分 draft/focus/keyboard 生命周期。
    Collect("INPUT_DRAFTS",rsui,"GetInputDraftSessionSnapshot")
    Collect("POPUP",self,"BuildPopupPositioningReport")
    Collect("STATUS_HUD",self,"BuildBuffHudReport")
    -- 公共 Service 健康快照按名称排序，未来模块也能进入报告；只调用已存在 getter，
    -- 绝不 Acquire/Enable。超出 64 个服务显式标记，不把功能分类等同于一起运行。
    local names={};for name,service in pairs(S.Services or {}) do
        if type(service)=="table" and type(service.GetHealth)=="function" then names[#names+1]=name end
    end
    table.sort(names)
    for i=1,math.min(#names,64) do Collect("SERVICE:"..names[i],S.Services[names[i]],"GetHealth") end
    if #names>64 then meta.partial=true;Add("services_omitted="..(#names-64)) end

    -- 保留未结构化旧日志（包括旧 SafeChat info 级错误），但报告自己的回执不嵌套。
    -- 原始大报告不是错误历史的副本；每行截断明确标识，原 LogBuffer 不修改。
    for _,row in ipairs(type(S.LogBuffer)=="table" and S.LogBuffer or {}) do
        if row.source~="diagnostics.report" then
            local str,clipped=Clip(row.message or "",2048);meta.partial=meta.partial or clipped
            Add("[LOG #"..Text(row.seq).." "..Text(row.level).."/"..Clip(row.source,96).." +"..Text(row.at).."ms] "..str)
        end
    end
    end
    -- 普通分页诊断也保留窗口位置证据，不要求先打开各模块。
    -- 只读取现有 Native/缓存，不移动窗口、不改存档；逐窗分节，避免一个大数组先被 32KiB 截断。
    local windowing=S.RSUI and S.RSUI.Windowing
    if windowing and type(windowing.GetPositionDiagnostics)=="function" then
        local ok,positions=pcall(windowing.GetPositionDiagnostics,windowing)
        if ok and type(positions)=="table" then
            local summary={};for key,value in pairs(positions)do if key~="windows" then summary[key]=value end end
            Section("UI_POSITION",summary)
            for _,row in ipairs(type(positions.windows)=="table" and positions.windows or {})do Section("UI_WINDOW",row)end
            if (tonumber(positions.omitted)or 0)>0 or (tonumber(positions.providerFailures)or 0)>0 then meta.partial=true end
            meta.providersFailed=meta.providersFailed+(tonumber(positions.providerFailures)or 0)
        else
            meta.partial=true;meta.providersFailed=meta.providersFailed+1
            Add("[UI_POSITION] ERROR "..Clip(positions,4096))
        end
    end
    -- 点击“打印”即显式只读取证请求。枚举当前加载/保存失败 Store，无需切换页面逐个
    -- 复制；每个最多一次 Native LoadData，失败独立记录。Core 仍检查 scope/预算/权限。
    local ok,choices=pcall(self.GetPersistenceFailureChoices,self)
    if not ok or type(choices)~="table" then
        meta.partial=true;meta.evidenceFailed=meta.evidenceFailed+1;Add("[RAW_STORES] ERROR "..Clip(choices,512))
    else
        -- 失败保存不等于加载写保护；两者单独计数。
        -- 仍每份最多读取一次，只改变选择覆盖，不改变固定快照/分页与原档预算。
        meta.failedStores=#choices;meta.fenced=0
        for _,choice in ipairs(choices) do
            local store=S.Persistence and S.Persistence.stores and S.Persistence.stores[choice.value]
            if type(store)=="table" and store.writeFenced==true then meta.fenced=meta.fenced+1 end
        end
        for index,choice in ipairs(choices) do
            local id=Text(choice.value)
            if index>EVIDENCE_COUNT_MAX or bytes>REPORT_MAX-264192 then
                meta.partial=true;meta.evidenceOmitted=meta.evidenceOmitted+1
                Add("[RAW_STORE "..id.."] evidence_omitted:report_budget",true)
            else
                local read,raw,err=pcall(self.BuildPersistenceEvidenceText,self,id,mode=="paged" and {compact=true} or nil)
                if not read or type(raw)~="string" then
                    meta.partial=true;meta.evidenceFailed=meta.evidenceFailed+1
                    Add("[RAW_STORE "..id.."] ERROR "..Clip(read and err or raw,2048),true)
                elseif #raw>263168 or not Add("[RAW_STORE "..id.."]\n"..raw.."\n[/RAW_STORE "..id.."]",true) then
                    meta.partial=true;meta.evidenceOmitted=meta.evidenceOmitted+1
                    Add("[RAW_STORE "..id.."] evidence_omitted:section_budget",true)
                else meta.evidenceIncluded=meta.evidenceIncluded+1 end
            end
        end
    end
    -- 尾标和长度用于发现复制丢尾；不声称这是持久化 integrity 或密码学认证。
    local footer="[RESULT] partial="..Text(meta.partial).." providersFailed="..meta.providersFailed
        .." sectionsOmitted="..tostring(meta.sectionsOmitted or 0).." evidenceIncluded="..meta.evidenceIncluded
        .." evidenceFailed="..meta.evidenceFailed.." evidenceOmitted="..meta.evidenceOmitted
    parts[#parts+1]=footer.."\nBODY_BYTES="..bytes.."\nRS-SELF-CHECK-END ID="..meta.id
    local text=table.concat(parts)
    meta.bytes=#text
    if detailWriter then
        detailWriter:Add('diagnostics.retention',{recent=self.recent,counters=self.counters,sequence=self.sequence,
            suppressed=self.suppressed,issueEvicted=history.evicted,clippedMessages=history.clippedMessages})
        meta.exportReport,meta.detail=detailWriter:Finish(text)
        meta.exportBytes=#meta.exportReport
    end
    return text,meta
end

function D:BuildSelfCheckReport()
    if building then return nil,"self_check_report_busy" end
    building=true
    local ok,text,meta=pcall(BuildReport,self)
    building=false
    if not ok then return nil,"self_check_report_exception:"..Clip(text,1024) end
    return text,meta
end

-- RS-FOCUS-1 仅供旧工具兼容，新页面用 BuildPaged。只汇总失败检查、完整指纹组和已登记错误。
-- 最多读一份简单故障档，容纳不下则整项省略并计数；摘录不能称全量证据。
-- 3500 字节是低于已成功接收 3963 字节片段的保守预算，展示仍须精确回读。
local FOCUS_MAX, FOCUS_FOOTER_RESERVE, FOCUS_RAW_MAX = 3500, 576, 16384
D.FocusedSelfCheckMaxBytes = FOCUS_MAX
D.FocusedSelfCheckContractVersion = 1
local function FocusText(value, limit)
    local text, clipped = Clip(value, limit)
    -- 故障摘录采用一行自然换行显示，避免Native吞掉LF；原错误换行/竖线以转义保留语义。
    text=text:gsub("\n","\\n"):gsub("\t","\\t"):gsub("|","\\x7C")
    local final, shortened=Clip(text,limit)
    return final,clipped or shortened
end
local function FocusFingerprint(value)
    if value==nil then return '-' end
    if type(value)~='string' or #value~=8 or value:find('[^%x]') then return '?' end
    return value:upper()
end
local function BuildFocused(self)
    local check=self:RunSelfCheck()
    reportSequence=reportSequence+1
    local history=self:GetSelfCheckIssueSnapshot()
    local meta={id=tostring(S.Generation or 0)..'.'..reportSequence,kind='focused',check=check,
        issueCount=#history.rows,historyEvicted=history.evicted,historyOmitted=0,storesOmitted=0,
        checksOmitted=0,detailsClipped=0,evidenceIncluded=0,evidenceOmitted=0,evidenceFailed=0,
        providersFailed=0,numericEvidenceIncluded=0,numericEvidenceOmitted=0,partial=check.status=='ERROR'}
    local failures={}
    local stores=type(S.Persistence)=='table' and S.Persistence.stores or nil
    for _,st in pairs(type(stores)=='table' and stores or {}) do
        if type(st)=='table' and st.writeFenced==true then failures[#failures+1]=st end
    end
    table.sort(failures,function(a,b)return Text(a.id)<Text(b.id)end)
    meta.fenced=type(stores)=='table' and #failures or nil
    local function Short(value,limit)
        local text,clipped=FocusText(value,limit)
        if clipped then meta.detailsClipped=meta.detailsClipped+1 end
        return text
    end
    -- 优先同schema、无自定义codec、较小声明预算的故障，减少迁移/编码变量。
    -- 选择只决定取哪一份样本，不证明该Store是根因。最多一次Native读取，不逐个重试读盘。
    local candidates={};for _,st in ipairs(failures)do candidates[#candidates+1]=st end
    local function Rank(st)
        local ev=type(st.lastIntegrityMismatchEvidence)=='table' and st.lastIntegrityMismatchEvidence or {}
        local same=ev.storedSchema~=nil and ev.storedSchema==st.schemaVersion
        return same and 0 or 1,ev.codec==nil and 0 or 1,
            tonumber(type(st.encodedBudget)=='table' and st.encodedBudget.maxNodes) or 999999
    end
    table.sort(candidates,function(a,b)
        local x,y,z=Rank(a);local X,Y,Z=Rank(b)
        if x~=X then return x<X elseif y~=Y then return y<Y elseif z~=Z then return z<Z end
        return Text(a.id)<Text(b.id)
    end)
    local packet,rawStatus='','not_requested'
    if type(stores)~='table' then
        meta.partial=true;meta.providersFailed=1;rawStatus='persistence_unavailable'
    end
    local transport=S.ReportCopyTransport
    if candidates[1] then
        local id=Text(candidates[1].id);meta.evidenceStore=id
        local ok,raw,err=pcall(self.BuildPersistenceEvidenceText,self,id,{compact=true})
        if not ok or type(raw)~='string' then
            meta.evidenceFailed=1;rawStatus='read_failed:'..Short(ok and err or raw,100)
        elseif #raw>FOCUS_RAW_MAX then rawStatus='raw_size_limit:'..#raw
        elseif type(transport)~='table' or type(transport.Encode)~='function' then rawStatus='codec_unavailable'
        else
            local encoded,value,why=pcall(transport.Encode,transport,raw)
            if not encoded or type(value)~='string' then rawStatus='encode_failed:'..Short(encoded and why or value,70)
            else
                -- 旧复制包只含固定ASCII字母表且无~，只替换外层LF；原raw字节由旧协议校验。
                packet='RAW_BEGIN store='..id..' '..value:gsub('\n','~')..' RAW_END'
                if #packet>FOCUS_MAX-FOCUS_FOOTER_RESERVE-1100 then packet='';rawStatus='copy_budget'
                else meta.evidenceIncluded=1;rawStatus='complete_native_unverified' end
            end
        end
    end
    meta.evidenceOmitted=#failures-meta.evidenceIncluded
    meta.rawStatus=rawStatus
    -- 原档被短预算省略时，重复打印不会补齐；转用随包离线 udf 采集器。
    -- 采集须由用户退出客户端并确认整个 udf 范围，游戏内不能自动运行。
    if rawStatus=="copy_budget" or rawStatus:match("^raw_size_limit:") then
        meta.evidenceNextStep="udf_snapshot"
    end
    local parts,bytes={},0
    local limit=FOCUS_MAX-FOCUS_FOOTER_RESERVE-(packet~='' and (#packet+3) or 0)
    local function Add(text)
        local needed=#text+(#parts>0 and 3 or 0)
        if bytes+needed>limit then return false end
        parts[#parts+1]=text;bytes=bytes+needed;return true
    end
    Add('RS-FOCUS-1 ID='..meta.id..' BUILD='..Short(S.BuildTag,72)..' LUA='..Short(_VERSION,16)
        ..' status='..Short(check.status,16)..' B'..Text(check.blockers)..'/W'..Text(check.warnings)
        ..' F'..Text(meta.fenced)..' E'..meta.issueCount..' scope=current_load_faults')
    -- 指纹组原子加入，预算不足整项省略并计数；禁止截半个Hash或把未知补成0。
    for _,st in ipairs(failures)do
        local ev=type(st.lastIntegrityMismatchEvidence)=='table' and st.lastIntegrityMismatchEvidence or {}
        local row='S:'..Short(st.id,64)..' schema='..Short(ev.storedSchema or '-',8)..'>'..Short(st.schemaVersion or '-',8)
            ..' fp='..FocusFingerprint(ev.stampedFingerprint)..'>'..FocusFingerprint(ev.actualFingerprint)
            ..' raw='..FocusFingerprint(ev.rawFingerprint)..' m='..Short(ev.framework or '-',8)..'/'..Short(ev.transportVersion or '-',8)..'/'..Short(ev.codec or '-',8)
            ..' hook='..Short(st.lastHistoricalRecoveryHookState or '-',20)
        local seq=type(st.lastHistoricalRecoveryProbe)=='string' and st.lastHistoricalRecoveryProbe:match('sequence=([^/;]+)')
        if seq then row=row..' seq='..Short(seq,18) end
        if next(ev)==nil then row=row..' reason='..Short(st.lastError or st.loadStatus,72) end
        -- transport 修复候选可能解码成功后才被业务指纹拒绝，因此不能只在 transport_* 错误时展示修复探针。
        -- 有物理恢复证据就复制本次 Load 缓存的 probe/error，区分无候选、歧义与指纹不符，不重读或重算。
        local physical=st.lastPhysicalTransportRepairProbe or st.lastPhysicalTransportRepairError
        if physical then
            -- 修复探针最多 2300 字节，含缺块索引、twin 关系和首个同 count 块差异；仍受 3500 字节总预算限制。
            row=row..' phy='..Short(physical,2300)
        end
        if not Add(row) then meta.storesOmitted=meta.storesOmitted+1 end
    end
    -- 逐 Store 附本次失败 Load 缓存的两轴 17g 值、6g token 和恢复结果。
    -- 这些是已检查 raw 的节选，不是完整原档；缺证据时留空，不能取当前默认值补零。
    for _,st in ipairs(failures) do
        local proof=st.lastWindowNumericEvidence
        if type(proof)=='table' then
            local row='N:'..Short(st.id,64)..' fixed6='..Short(proof.status,20)
                ..' tries='..Short(proof.attempts or 0,4)..' hits='..Short(proof.matches or 0,4)
            for _,pair in ipairs({{'normalizedCenterX','X'},{'normalizedCenterY','Y'}}) do
                local field=type(proof.fields)=='table' and proof.fields[pair[1]] or nil
                if type(field)=='table' then
                    row=row..' '..pair[2]..'='..Short(field.raw,32)..'/'..Short(field.token,20)
                        ..'('..Short(field.reason,20)..')'
                    if field.canonical~=field.raw then row=row..' canon='..Short(field.canonical,32) end
                end
            end
            if Add(row) then meta.numericEvidenceIncluded=meta.numericEvidenceIncluded+1
            else meta.numericEvidenceOmitted=meta.numericEvidenceOmitted+1 end
        end
    end
    if check.error and not Add('CHECK_ERROR='..Short(check.error,180)) then meta.checksOmitted=meta.checksOmitted+1 end
    -- 当前失败先于健康快照/历史冗余。只记录失败；检查的长detail允许摘要并明确计数。
    local failedChecks={}
    for _,row in ipairs(type(check.checks)=='table' and check.checks or {})do
        if type(row)=='table' and row.ok~=true then failedChecks[#failedChecks+1]=row end
    end
    table.sort(failedChecks,function(a,b)
        if (a.severity=='blocker')~=(b.severity=='blocker')then return a.severity=='blocker' end
        return Text(a.id)<Text(b.id)
    end)
    for _,row in ipairs(failedChecks)do
        local label='C:'..Short(row.severity or '?',12)..'/'..Short(row.id,64)
        local detail=Short(row.detail or row.error or '',72)
        if not Add(label..'='..detail) and not Add(label) then meta.checksOmitted=meta.checksOmitted+1 end
    end
    -- 最新错误优先；已在S组列过的存档失败只保留code/Store/次数，避免同一长轨迹输出三遍。
    -- 其它错误仍保留原因片段；重复次数来自原有错误环，不能合并不同错误伪造同一根因。
    for index=#history.rows,1,-1 do
        local row=history.rows[index]
        local message=Text(row.message)
        local store=message:match('store=([%w_.%-]+)')
        local code=message:match('^%[([%w_]+)%]')
        if code=='STORE_INTEGRITY_FAILED' and store and type(stores)=='table' and type(stores[store])=='table' and stores[store].writeFenced==true then
            message=code..'/'..store..'(see S)'
        end
        if not Add('H:'..Short(row.level,8)..'/'..Short(row.source,32)..' x'..Text(row.count)..' '..Short(message,140)) then
            meta.historyOmitted=meta.historyOmitted+1
        end
    end
    if packet~='' then parts[#parts+1]=packet end
    -- 取证失效/省略原因不受正文剩余空间影响，固定尾区必须可见。范围声明始终写明非全量。
    parts[#parts+1]='COVERAGE fullDump=not_included raw='..meta.evidenceIncluded..'/'..#failures
        ..' rawStatus='..rawStatus..' numeric='..meta.numericEvidenceIncluded..'/'..#failures
        ..' numericOmit='..meta.numericEvidenceOmitted..' storeOmit='..meta.storesOmitted..' checkOmit='..meta.checksOmitted
        ..' historyOmit='..meta.historyOmitted..' clipped='..meta.detailsClipped..' evicted='..meta.historyEvicted
        ..' preclipped='..Text(history.clippedMessages or 0)..' captureFail='..Text(history.captureFailures or 0)
        ..' logDropped='..Text(S.LogDropped or 0)..' sample='..Short(meta.evidenceStore or '-',64)
        ..(meta.evidenceNextStep and (' next='..meta.evidenceNextStep) or '')
    local body=table.concat(parts,' | ')
    if type(transport)~='table' or type(transport.CopyChecksum)~='function' then error('focus_checksum_unavailable')end
    local checksum=assert(transport:CopyChecksum(body))
    local text=body..' | BODY_BYTES='..#body..' CHECK='..checksum..' RS-FOCUS-END ID='..meta.id
    if #text>FOCUS_MAX then error('focus_report_budget')end
    meta.bytes=#text
    meta.partial=meta.partial or meta.numericEvidenceOmitted>0 or meta.evidenceFailed>0 or meta.evidenceOmitted>0 or meta.storesOmitted>0
        or meta.historyOmitted>0 or meta.checksOmitted>0 or meta.detailsClipped>0 or meta.historyEvicted>0
        or (tonumber(history.clippedMessages) or 0)>0 or (tonumber(history.captureFailures) or 0)>0
    return text,meta
end
function D:BuildFocusedSelfCheckReport()
    if building then return nil,'self_check_report_busy' end
    building=true
    local ok,text,meta=pcall(BuildFocused,self)
    building=false
    if not ok then return nil,'focused_report_exception:'..Clip(text,512) end
    return text,meta
end
function D:PrintFocusedSelfCheckReport(present)
    local text,meta=self:BuildFocusedSelfCheckReport()
    if not text then return false,meta end
    return self:PresentSelfCheckReport(text,meta,present)
end

-- 先生成一次，再由 present 回报页面可见、回读和焦点结果，最后只发一条真实回执。
-- 翻段复用同一 text/meta，不重跑 Gate 或读盘。delivered 表示完整报告到达，partReady 只表示一段到达。
-- 内部无 presenter 时只承诺已返回文本，不能声称文本框或系统剪贴板已就绪。
function D:PresentSelfCheckReport(text,meta,present)
    if type(text)~="string" or type(meta)~="table" or type(meta.check)~="table" then
        return false,"self_check_snapshot_required"
    end
    -- ADDON:SetClipboardText 属于 Available/not allowed，不调用或探测；用户通过已激活的 Native 文本框手动 Ctrl+C。
    meta.clipboard="manual"
    meta.clipboardError="api_reference_not_allowed:ADDON:SetClipboardText"
    meta.presentation={state="unavailable",code="NO_PRESENTER",focused=false}
    if type(present)=="function" then
        local shown,result=pcall(present,text,meta)
        if shown and type(result)=="table" and (result.state=="plain" or result.state=="packed" or result.state=="part" or result.state=="failed") then
            meta.presentation=result
        else
            meta.presentation={state="failed",code="PRESENT_ERROR",error=Clip(result,512),focused=false}
        end
    end
    local delivery=meta.presentation
    meta.delivered=delivery.state=="plain" or delivery.state=="packed"
    meta.partReady=delivery.state=="part"
    local state
    if delivery.state=="plain" or delivery.state=="packed" then
        state=(delivery.focused==true and "报告框已激活，" or "点报告框，").."Ctrl+A/C 全选复制后发来。"
    elseif delivery.state=="part" then
        -- 同一打印按钮只生成报告；新分页使用显式导航，不能再指示用户隐式翻段。
        state=meta.kind=="paged" and "当前页就绪，Ctrl+A/C复制；用上一页/下一页，需全部页。"
            or "当前一段就绪，Ctrl+A/C复制；再点打印取下一段，需全部段。"
    else state="完整报告未送达；请查看页面失败提示。" end
    -- 聚焦报告只承诺本份摘录到达，不能把raw=1/3误称全量数据已交付。
    if meta.kind=="focused" then
        state=meta.delivered and "故障报告1/1已就绪；Ctrl+A/C复制本框即可。" or "故障报告未送达；请查看页面失败提示。"
    end
    local code=tostring(delivery.code or "-"):gsub("[^%w_%-]","_"):sub(1,32)
    local chat=(meta.kind=="focused" and "RS-CHECK-4 #" or "RS-CHECK-3 #")..meta.id.." B"..Text(meta.check.blockers).."/W"..Text(meta.check.warnings)
        .." status="..Text(meta.check.status).." F"..Text(meta.fenced).." E"..meta.issueCount.." bytes="..meta.bytes
        .." copy="..meta.clipboard.." view="..delivery.state
        ..(delivery.state=="part" and (" part="..tostring(delivery.index).."/"..tostring(delivery.parts)) or "")
        .." code="..code
        -- 失败回执带 Set/Get 类型、长度和首差异，不带正文或额外 Native 读取。
        ..(delivery.state=="failed" and type(delivery.readback)=="table"
            and type(S.ReportCopyTransport)=="table" and type(S.ReportCopyTransport.FormatReadback)=="function"
            and (" "..S.ReportCopyTransport:FormatReadback(delivery.readback)) or "")
        .." "..state.." END"
    -- 只发一次回执；不把正文压成聊天/日志，不因回执失败重新读取证据或执行交付回调。
    local send=type(S.SafeChat)=="function" and S.SafeChat or S.DispatchSystemChat
    if type(send)=="function" then
        local sent,accepted=pcall(send,chat,"info","diagnostics.report")
        meta.chatSent=sent and accepted==true
    else meta.chatSent=false end
    return true,text,meta
end


-- 完整错误一次采集，分页不改变故障或存档。重载后由新 Generation 重建错误环。
function D:BuildPagedSelfCheckReport()
    if building then return nil,"self_check_report_busy" end
    building=true
    local ok,text,meta=pcall(BuildReport,self,"paged")
    building=false
    if not ok then return nil,"paged_report_exception:"..Clip(text,1024) end
    return text,meta
end
function D:PrintPagedSelfCheckReport(present)
    local text,meta=self:BuildPagedSelfCheckReport()
    if not text then return false,meta end
    return self:PresentSelfCheckReport(text,meta,present)
end

function D:PrintSelfCheckReport(present)
    local text,meta=self:BuildSelfCheckReport()
    if not text then return false,meta end
    return self:PresentSelfCheckReport(text,meta,present)
end
