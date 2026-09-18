------------------------------------------------------------------------
-- 中文维护注释（状态追踪管理 Authority）：
-- 问题：旧“冻结”只保留 tracked 行且复用 HUD；未出现的已追踪 ID 无处取消。
-- 本文件属于 BuffDisplay Feature：只拥有管理投影、持续Session留存与用户追踪命令。
-- 事实仍来自 AuraObservationV3；只读目录来自 StatusTrackingCatalogV3；写入只经 MutateStore。
-- 不调用业务写 API，不保留旧架构旁路，不把 Session 快照/筛选状态写进永久 Store。
-- 管理缓存按选择/数据 revision 失效；五种视图与悬浮窗各保留一个查询，禁止 live 与 tracked 互相驱逐后每 50ms 重建整库。
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S=ReplicatedSuite
local F=S.Features and S.Features.BuffDisplay
local Catalog=S.Data and S.Data.StatusTrackingCatalogV3
if type(F)~="table" or type(Catalog)~="table" then return end
F.ManagementProjectionContractVersion=2
F.RetentionContractVersion=1
-- 维护：会话留存只保存“观察到过”的状态，不是暂停 Native/HUD；关闭/重载释放。
-- 每 scope 最多 1024 个身份，达到上限保留最早证据并明确 overflow，不静默淘汰。
local RETAIN_MAX=1024
local RETAIN_TOKEN="management:retained"
local function EmptyCapture(revision,active)
    return {active=active==true,revision=revision or 0,rows={player={},target={}},
        byId={player={},target={}},coverage={},count=0,overflow=false,rejectedObservations=0}
end
F.managementFreeze=EmptyCapture(0,false)
local function Copy(value)
    if type(value)~="table" then return value end
    local out={};for key,item in pairs(value) do out[key]=Copy(item) end;return out
end
local function Publish(reason)
    if S.Events and type(S.Events.Publish)=="function" then S.Events:Publish("v3.buff_display.updated",reason) end
end
local function Settings() return F.State.settings end
local TRACKING_CHANNEL_ORDER = {
    {scope="player",category="buff",text="自身·Buff"},
    {scope="player",category="debuff",text="自身·Debuff"},
    {scope="target",category="buff",text="目标·Buff"},
    {scope="target",category="debuff",text="目标·Debuff"},
    {scope="player",category="auto",text="自身·自动"},
    {scope="target",category="auto",text="目标·自动"},
}
local function ChannelsForId(id,index)
    local channels,scopes,categories={},{},{}
    id=math.floor(tonumber(id) or 0)
    for _,def in ipairs(TRACKING_CHANNEL_ORDER) do
        local scoped=type(index[def.scope])=="table" and index[def.scope] or {}
        if type(scoped[def.category])=="table" and scoped[def.category][id]==true then
            channels[#channels+1]={scope=def.scope,category=def.category,text=def.text}
            scopes[def.scope],categories[def.category]=true,true
        end
    end
    return channels,scopes,categories
end
local function Decorate(row,index)
    local channels,scopes,categories=ChannelsForId(row.id,index)
    row.trackedChannels,row.trackedScopes,row.trackedCategories=channels,scopes,categories
    row.tracked=#channels>0
    local labels={};for _,channel in ipairs(channels) do labels[#labels+1]=channel.text end
    row.trackedText=row.tracked and table.concat(labels," / ") or "未追踪"
    if #channels==1 then row.trackedBucket=channels[1].category else row.trackedBucket=#channels>1 and "multi" or nil end
    local user=Settings().classification[row.id]
    if user=="buff" or user=="debuff" then row.category=user end
    row.effectType=row.category
    row.effectTypeText=row.category=="buff" and "Buff" or (row.category=="debuff" and "Debuff" or ((categories.auto==true) and "自动识别" or "待分类"))
    if row.scope=="player" then row.scopeText="自己"
    elseif row.scope=="target" then row.scopeText="目标"
    elseif scopes.player and scopes.target then row.scopeText="自己+目标"
    elseif scopes.player then row.scopeText="自己"
    elseif scopes.target then row.scopeText="目标"
    else row.scopeText="未追踪" end
    local meta=S.Services and S.Services.BuffMetadataV3
    if (row.iconPath==nil or row.iconPath=="") and meta and type(meta.GetCached)=="function" then
        local info=meta:GetCached(row.id)
        if info then row.iconPath=info.iconPath;if not row.name or row.name==tostring(row.id) then row.name=info.name end end
    end
    row.name=tostring(row.name or row.id);row.timeText=row.timeText or "--"
    return row
end
function F:GetManagementFreezeState()
    local frozen=self.managementFreeze
    return {active=frozen.active,capturedAt=frozen.capturedAt,targetIdentity=frozen.targetIdentity,
        revision=frozen.revision,coverage=Copy(frozen.coverage),count=frozen.count or 0,
        mode="retain_observed",overflow=frozen.overflow,rejectedObservations=frozen.rejectedObservations,
        capacityPerScope=RETAIN_MAX}
end
local function InvalidateManagement()
    F.managementCache=nil;F.managementCaches={}
end
function F:ClearFrozenRows()
    if self.clearingManagementCapture then return true end
    local previous=self.managementFreeze
    self.managementFreeze=EmptyCapture((previous.revision or 0)+1,false)
    -- 维护：留存是显式消费者，隐藏页面不停止；停止/Feature关闭/重载才释放。
    -- Demand在清空消费者的回调里也调用此函数，先置空会话并使用重入门，禁止递归Release。
    if self.Demand and self.Demand:Has(RETAIN_TOKEN) then
        self.clearingManagementCapture=true
        local released,err=self:ReleaseConsumer(RETAIN_TOKEN)
        self.clearingManagementCapture=false
        if released~=true then self.managementFreeze=previous;InvalidateManagement();return false,err end
    end
    InvalidateManagement()
    -- 此入口也用于 Demand 清理。只有仍有消费者时才重调原 aura 任务；绝不创建独立留存任务。
    if self.enabled and (self.consumerCount or 0)>0 then self:ReconcileLanes() end
    Publish("management_unfreeze")
    return true
end
function F:DropFrozenRows(_id)
    -- 取消追踪只改变用户选择，不删除已观察事实；清空记录是单独明确命令。
    return true
end
function F:ObserveManagementRows(scope,rows,coverage,at)
    local state=self.managementFreeze
    if not state.active or not state.rows[scope] then return false end
    local changed=false;local oldCoverage=state.coverage[scope] or {}
    state.coverage[scope]=Copy(coverage or {available=false,complete=false,reliable=false})
    if oldCoverage.available~=state.coverage[scope].available or oldCoverage.complete~=state.coverage[scope].complete then changed=true end
    -- 读失败不等于 Buff 消失：保留原事实，报告当前源不可读，不制造“已结束”的结论。
    if type(rows)=="table" then
        local seen={};local index=state.byId[scope]
        for _,raw in ipairs(rows) do
            local id=tonumber(raw.id)
            if id and id>0 then
                seen[id]=true;local row=index[id]
                if not row then
                    if #state.rows[scope]<RETAIN_MAX then
                        row=Copy(raw);row.scope=scope;row.frozen=true;row.present=true
                        row.firstSeenAt=at;row.lastSeenAt=at;row.timeText="已留存";row.capturedAt=at
                        index[id]=row;state.rows[scope][#state.rows[scope]+1]=row;state.count=state.count+1;changed=true
                    else
                        if not state.overflow then changed=true end
                        state.overflow=true;state.rejectedObservations=math.min(2147483647,state.rejectedObservations+1)
                    end
                else
                    if row.present~=true then row.present=true;changed=true end
                    -- 时间/层数保留初次捕获值，lastSeenAt单独更新；不因倒计时每50ms重排整份历史。
                    -- 后续再观察到新图标/正确分类时补全；同scope+ID跨目标复用，避免无限目标身份缓存。
                    for _,key in ipairs({"name","iconPath","category","detectionSource","confidence","sourceMask"}) do
                        local value=raw[key]
                        if value~=nil and value~="" and row[key]~=value then row[key]=value;changed=true end
                    end
                    row.lastSeenAt=at
                end
            end
        end
        -- 扫描不完整/不可读时“未看见”不等于“已消失”，只保留观察到的证据。
        if coverage and coverage.complete==true and coverage.reliable==true then
            for id,row in pairs(index) do if row.present==true and not seen[id] then row.present=false;changed=true end end
        end
    end
    if state.overflow then state.coverage[scope].complete=false end
    state.capturedAt=state.capturedAt or at
    if changed then state.revision=state.revision+1 end
    return changed
end
function F:CaptureManagementFreeze()
    local aura=S.Services and S.Services.AuraObservationV3
    if type(aura)~="table" or type(aura.GetSnapshot)~="function" then return false,"共享 Aura 服务不可用" end
    local token="buff_display:management_freeze"
    local held,err=aura:AcquireConsumer(token,{purpose="management_capture"})
    if held~=true then return false,err end
    local previous=self.managementFreeze
    if not previous.active then self.managementFreeze=EmptyCapture((previous.revision or 0)+1,true) end
    -- 维护：先读入有界暂存，双方读取均失败时不破坏已有留存；临时 lease 始终释放。
    -- 后续状态由原 aura lane / 事件边继续调用 ObserveManagementRows，不依赖 UI 是否正显示本页。
    local captured={};local count=0
    local ok,captureErr=pcall(function()
        for _,scope in ipairs({"player","target"}) do
            local raw,readErr=aura:GetSnapshot(scope,{buff=true,debuff=true,hidden=true,limit=128,ttlMs=0,forceRefresh=true})
            if type(raw)=="table" then
                local map,meta=aura:GetStatusMap(raw,{buff=true,debuff=true,hidden=true})
                local rows,coverage=self.ProjectStatusMap(map,meta,{showBuffs=true,showDebuffs=true,
                    classification=Settings().classification},scope,384,self:BuildTrackedIndex(Settings()))
                coverage.buffCount=raw.buff and raw.buff.count or 0;coverage.debuffCount=raw.debuff and raw.debuff.count or 0
                coverage.hiddenCount=raw.hidden and raw.hidden.count or 0
                captured[scope]={rows=rows,coverage=coverage,at=raw.at};if coverage.available then count=count+1 end
            else captured[scope]={coverage={available=false,complete=false,reliable=false,error=tostring(readErr)}} end
        end
    end)
    local released,releaseErr=aura:ReleaseConsumer(token)
    if not ok or released==false or count==0 then
        self.managementFreeze=previous
        return false,tostring(not ok and captureErr or released==false and releaseErr or "自己/目标状态均不可读，保留原记录")
    end
    for _,scope in ipairs({"player","target"}) do local v=captured[scope];self:ObserveManagementRows(scope,v.rows,v.coverage,v.at) end
    InvalidateManagement()
    if self.enabled and self.Demand and not self.Demand:Has(RETAIN_TOKEN) then
        local acquired,acquireErr=self:AcquireConsumer(RETAIN_TOKEN)
        if acquired~=true then self.managementFreeze=previous;InvalidateManagement();return false,acquireErr end
    end
    if self.enabled and (self.consumerCount or 0)>0 then self:ReconcileLanes() end
    Publish("management_capture")
    return true,"持续留存中：已记录 "..tostring(self.managementFreeze.count).." 条。新出现的状态会加入，消失后仍保留；HUD 继续实时更新。"
end
function F:ResetManagementCapture()
    -- 明确清空当前会话历史但保持捕获开关；与再次点击启用幂等命令区分，防止误丢证据。
    local active=self.managementFreeze.active
    self.managementFreeze=EmptyCapture(self.managementFreeze.revision+1,active);InvalidateManagement()
    Publish("management_capture_reset")
    return true,active and "记录已清空，继续留存随后观察到的状态。" or "记录已清空。"
end

-- 维护（图标只读链）：目录不嵌复制资源表。行绑定仅请求ID，绝不在渲染回调调用 Native。
-- Feature 用一个可取消的 one-shot 分批请求共享 BuffMetadataV3；每批最多8个、队列最多64个。
-- 仅页面可见期间运行，隐藏/销毁取消；命中或未命中都由共享服务缓存，不产生整库热遍历。
local META_TASK="v3_buff_management_metadata"
F.managementMetadata={active=false,queue={},pending={},queued=0,revision=0,batches=0,generation=0}
function F:SetManagementPageActive(active,token)
    -- 维护（compact-tracker-1）：大页面和小窗各持有元数据消费者；隐藏任一不能停止另一方。
    -- 限定两种token，防止任意视图创建无限引用；仅最后释放才取消批处理，旧bool调用默认page。
    token=token=="widget" and "widget" or "page"
    local m=self.managementMetadata;m.consumers=m.consumers or {}
    if active==true then m.consumers[token]=true else m.consumers[token]=nil end
    local was=m.active;m.active=next(m.consumers)~=nil
    if was==m.active then return true end
    m.generation=m.generation+1;m.revision=m.revision+1;InvalidateManagement()
    if not m.active then
        if S.Scheduler and type(S.Scheduler.RemoveTask)=="function" then S.Scheduler:RemoveTask(META_TASK) end
        m.queue={};m.pending={};m.queued=0;m.scheduled=false
    end
    return true
end
function F:QueueManagementMetadata(id)
    local m=self.managementMetadata;local service=S.Services and S.Services.BuffMetadataV3
    id=tonumber(id)
    -- Bounded counters distinguish a binder/lifecycle issue from an unavailable
    -- native icon. No logging or tooltip reads are performed on this render edge.
    m.requests=math.min(2147483647,(m.requests or 0)+1)
    if not m.active then m.inactiveSkips=math.min(2147483647,(m.inactiveSkips or 0)+1);return false end
    if not id or not service or type(service.GetInfo)~="function" then return false end
    if type(service.HasCached)=="function" and service:HasCached(id,true) then
        m.cacheSkips=math.min(2147483647,(m.cacheSkips or 0)+1);return true
    end
    local cached=type(service.GetCached)=="function" and service:GetCached(id) or nil
    if cached and type(cached.iconPath)=="string" and cached.iconPath~="" then return true end
    if m.pending[id] or m.queued>=64 then return true end
    m.queue[#m.queue+1]=id;m.pending[id]=true;m.queued=m.queued+1
    return self:_ScheduleManagementMetadata()
end
function F:_ScheduleManagementMetadata()
    local m=self.managementMetadata
    if m.scheduled or not m.active or m.queued==0 then return true end
    if not S.Scheduler or type(S.Scheduler.AddOneShot)~="function" then return false end
    local generation=m.generation
    local ok=S.Scheduler:AddOneShot(META_TASK,50,function()
        -- 调度器取消之后已取出的旧回调也不得消费重新打开页面的队列。
        if generation~=m.generation then return true end
        m.scheduled=false
        if not m.active then return true end
        local meta=S.Services and S.Services.BuffMetadataV3
        for _=1,math.min(8,m.queued) do
            local id=table.remove(m.queue,1);m.pending[id]=nil;m.queued=m.queued-1
            if meta and type(meta.GetInfo)=="function" then meta:GetInfo(id,true) end
        end
        m.batches=m.batches+1;m.revision=m.revision+1
        InvalidateManagement();Publish("management_metadata")
        F:_ScheduleManagementMetadata();return true
    end,self,"P3",1)
    m.scheduled=ok==true
    return ok==true
end
local function CatalogRow(entry)
    -- 缓存peek不触发Native；真正读取由页面可见行的延迟队列发起，禁止393+行逐帧查询。
    local meta=S.Services and S.Services.BuffMetadataV3
    local info=entry.kind=="effect" and meta and type(meta.GetCached)=="function" and meta:GetCached(entry.id) or nil
    return {id=entry.id,key=entry.key,name=entry.name,category=entry.category,iconPath=info and info.iconPath or "",
        detectionSource=entry.tags.hidden and "hidden" or (entry.tags.special_rule and "special_rule" or "normal"),
        confidence=entry.confidence,scope="catalog",timeText="--",kind=entry.kind}
end
function F:GetLibraryPacks()
    local rows={}
    for _,key in ipairs(Catalog.PackOrder) do
        local pack=Catalog.Packs[key]
        rows[#rows+1]={key=key,name=pack.name,count=pack.count,description=pack.description}
    end
    return rows,Catalog.version
end
local function Matches(row,options)
    local filter=options.filter or "all"
    if options.scope and options.scope~="all" and row.scope~=options.scope then return false end
    if (filter=="buff" or filter=="debuff") and row.category~=filter then return false end
    if filter=="tracked_buff" and not (row.tracked and type(row.trackedCategories)=="table" and row.trackedCategories.buff==true) then return false end
    if filter=="tracked_debuff" and not (row.tracked and type(row.trackedCategories)=="table" and row.trackedCategories.debuff==true) then return false end
    if filter=="auto" and not (row.category=="unknown" or (type(row.trackedCategories)=="table" and row.trackedCategories.auto==true)) then return false end
    if filter=="hidden" and row.detectionSource~="hidden" then return false end
    if filter=="untracked" and row.tracked then return false end
    if filter=="player" or filter=="target" then
        if row.scope=="tracked" or row.scope=="catalog" then
            if not (type(row.trackedScopes)=="table" and row.trackedScopes[filter]==true) then return false end
        elseif row.scope~=filter then return false end
    end
    local query=tostring(options.query or ""):lower()
    return query=="" or row.name:lower():find(query,1,true)~=nil or tostring(row.id):find(query,1,true)~=nil
end
function F:GetManagementProjection(options)
    options=type(options)=="table" and options or {}
    local view=options.view or "live"
    if view~="live" and view~="frozen" and view~="tracked" and view~="library" and view~="cooldowns" then view="live" end
    local frozen=self.managementFreeze
    -- 维护：小窗有明确“当前/留存”两个入口；保留旧页面live随冻结切换的兼容行为。
    if view=="live" and frozen.active and options.preserveLive~=true then view="frozen" end
    local revision=(view=="live" and self.revision) or (view=="frozen" and frozen.revision) or Catalog.version
    local metaService=S.Services and S.Services.BuffMetadataV3
    local metaRevision=metaService and type(metaService.GetRevision)=="function" and metaService:GetRevision() or 0
    local key=table.concat({view,tostring(options.filter or "all"),tostring(options.sort or "tracked"),
        tostring(options.query or ""),tostring(options.scope or "all"),tostring(options.pack or "all"),tostring(self.settingsRevision),tostring(revision),tostring(self.managementMetadata.revision),tostring(metaRevision)},"|")
    -- 中文维护注释：页面 live 与悬浮窗 tracked 是独立消费者。单槽缓存会使两者交错时每 50ms 重建 393 行。
    -- 固定八槽（含悬浮窗当前/留存/追踪）、每槽单查询，既阻止热路径整库复制，也避免任意筛选字符串形成无限缓存。
    self.managementCaches=self.managementCaches or {}
    -- 中文维护注释：同为 tracked 时，页面筛选与悬浮窗全量选择也不能共用一槽；仅允许固定 widget 标识。
    local cacheSlot=(options.cacheOwner=="widget" and (view=="tracked" or view=="live" or view=="frozen")) and (view.."_widget") or view
    local cached=self.managementCaches[cacheSlot]
    if cached and cached.key==key then return cached.rows,key,cached.coverage end
    local rows={};local index=self:BuildTrackedIndex(Settings())
    if view=="tracked" then
        local seen={};local tracked=Settings().tracked or {}
        for _,scope in ipairs({"player","target"}) do
            local scoped=type(tracked[scope])=="table" and tracked[scope] or {}
            for _,category in ipairs({"buff","debuff","auto"}) do
                for _,id in ipairs(scoped[category] or {}) do
                    if not seen[id] then
                        seen[id]=true;local entry=Catalog.ByEffectId[id]
                        local row=entry and CatalogRow(entry) or {id=id,key="effect:"..id,name=tostring(id),detectionSource="normal",category="unknown"}
                        row.scope="tracked";rows[#rows+1]=Decorate(row,index)
                    end
                end
            end
        end
    elseif view=="library" then
        local pack=Catalog.Packs[options.pack or "all"]
        for _,entry in ipairs(pack and pack.entries or {}) do
            local row=CatalogRow(entry)
            if entry.kind=="effect" then rows[#rows+1]=Decorate(row,index)
            else
                row.scopeText=entry.kind=="mate" and "伙伴 CD" or "自己 CD"
                row.effectTypeText="技能 CD";row.tracked=false;row.timeText="未接入冷却"
                for _,id in ipairs(Settings().trackedCooldowns[entry.kind] or {}) do if id==entry.id then row.tracked=true break end end
                row.trackedText=row.tracked and "已追踪" or "未追踪"
                rows[#rows+1]=row
            end
        end
    elseif view=="cooldowns" then
        for _,kind in ipairs({"skill","mate"}) do
            for _,id in ipairs(Settings().trackedCooldowns[kind] or {}) do
                local entry=Catalog.ByKey["cooldown:"..kind..":"..id]
                local row=entry and CatalogRow(entry) or {id=id,key="cooldown:"..kind..":"..id,name=tostring(id),kind=kind}
                row.scopeText=kind=="mate" and "伙伴 CD" or "自己 CD";row.effectTypeText="技能 CD"
                row.tracked=true;row.trackedText="已追踪";row.timeText="未接入冷却";rows[#rows+1]=row
            end
        end
    else
        local source=view=="frozen" and frozen.rows or self.projections
        for _,scope in ipairs({"player","target"}) do
            for _,raw in ipairs(source[scope] or {}) do
                local row=Copy(raw);row.scope=scope;rows[#rows+1]=Decorate(row,index)
            end
        end
    end
    local filtered={};for _,row in ipairs(rows) do if Matches(row,options) then filtered[#filtered+1]=row end end
    local sort=options.sort or "tracked"
    table.sort(filtered,function(a,b)
        if sort=="tracked" and a.tracked~=b.tracked then return a.tracked==true end
        if sort=="category" and a.category~=b.category then return tostring(a.category)<tostring(b.category) end
        if sort=="source" and a.scopeText~=b.scopeText then return tostring(a.scopeText)<tostring(b.scopeText) end
        if sort=="name" and a.name~=b.name then return a.name<b.name end
        if sort=="time" and a.timeLeft~=b.timeLeft then return (tonumber(a.timeLeft) or math.huge)<(tonumber(b.timeLeft) or math.huge) end
        if a.id~=b.id then return a.id<b.id end
        return tostring(a.key)<tostring(b.key)
    end)
    local coverage=view=="frozen" and frozen.coverage or (view=="live" and self.coverage or {})
    self.managementCaches[cacheSlot]={key=key,rows=filtered,coverage=coverage}
    return filtered,key,coverage
end
-- 维护（library-eventbus-2）：调用没成功时以前可能只留下旧的lastImport成功记录，
-- Core虽已记录保存失败，但缺少导入阶段/包名上下文，预检失败也可能只在短提示中。Feature拥有命令结果；
-- 每次点击从validate开始记录，只有Core耐久保存/回读完成后才标committed；不新增写入旁路。
-- 上下文只存数量/阶段，不复制目录或用户配置；未知包/容量/写保护/保存失败均进入既有分页报告。
F.LibraryIntegrationPatch="status-library-durable-3" -- Core now preserves long ID sequences on disk
function F:ImportBuiltinPack(key,newOnly)
    key=tostring(key or "")
    self.libraryImportAttempts=(self.libraryImportAttempts or 0)+1
    local attempt={pack=key,attempt=self.libraryImportAttempts,ok=false,stage="validate",newOnly=newOnly==true}
    self.lastLibraryImport=attempt
    local function Failed(reason)
        attempt.error=tostring(reason or "导入失败")
        if S.DiagnosticsManager and type(S.DiagnosticsManager.Emit)=="function" then
            S.DiagnosticsManager:Emit("error","buff_display","BUFF_LIBRARY_IMPORT_FAILED",attempt.error,
                {pack=key,attempt=attempt.attempt,stage=attempt.stage,result=Copy(attempt.result)})
        elseif type(S.RecordLog)=="function" then S.RecordLog("error","buff_display","BUFF_LIBRARY_IMPORT_FAILED "..key.." "..attempt.stage.." "..attempt.error) end
        return false,attempt.error,Copy(attempt.result)
    end
    local pack=Catalog.Packs[key]
    if not pack then return Failed("未知内置包") end
    if #pack.entries==0 then return Failed("当前内置库暂无可导入条目") end
    attempt.stage="prepare"
    local loaded,loadErr=self:EnsureStoreLoaded();if loaded~=true then return Failed(loadErr) end
    local result={included=#pack.entries,buff=0,debuff=0,auto=0,cooldown=0,existing=0,rejected=0}
    attempt.result=result
    -- 中文维护注释（.18.243 内置库导入）：recommended/all 包只属于 Tracking Authority。
    -- 一次用户点击现在物理上会写 inactive player/target/meta + manifest 四次，这是有意的两阶段提交，
    -- 不能为了恢复“单次 SaveData”测试指标而写回旧 monolith。只有 manifest 成功才把 attempt 标为 committed；
    -- 任一 inactive 写失败都保留上一代配置，准确率优先于写次数。
    local ok,err=self:MutateTrackingStore(function()
        attempt.stage="mutate"
        local settings=Settings();local index=self:BuildTrackedIndex(settings)
        local since=newOnly==true and (settings.library.importedPacks[key] or 0) or -1
        local function AddEffect(scope,category,id)
            local scoped=settings.tracked[scope];local list=scoped[category]
            if category=="auto" and ((index[scope].buff and index[scope].buff[id]) or (index[scope].debuff and index[scope].debuff[id])) then
                result.existing=result.existing+1;return true
            end
            if index[scope][category] and index[scope][category][id] then result.existing=result.existing+1;return true end
            if #list>=1024 then result.rejected=result.rejected+1;return false,"内置包超过追踪容量，本次整体未写入" end
            list[#list+1]=id;result[category]=result[category]+1;return true
        end
        for _,entry in ipairs(pack.entries) do
            if entry.introducedVersion>since then
                local category=entry.category
                if category~="buff" and category~="debuff" then category="auto" end
                if entry.kind=="effect" then
                    for _,scope in ipairs({"player","target"}) do
                        local added,addErr=AddEffect(scope,category,entry.id);if added~=true then return false,addErr end
                    end
                else
                    local list=settings.trackedCooldowns[entry.kind];local exists=false
                    for _,id in ipairs(list) do if id==entry.id then exists=true break end end
                    if exists then result.existing=result.existing+1
                    elseif #list>=256 then result.rejected=result.rejected+1;return false,"内置包超过追踪容量，本次整体未写入"
                    else list[#list+1]=entry.id;result.cooldown=result.cooldown+1 end
                end
            end
        end
        for _,scope in ipairs({"player","target"}) do for _,category in ipairs({"buff","debuff","auto"}) do table.sort(settings.tracked[scope][category]) end end
        table.sort(settings.trackedCooldowns.skill);table.sort(settings.trackedCooldowns.mate)
        settings.library.catalogVersion=Catalog.version;settings.library.importedPacks[key]=Catalog.version
        attempt.stage="commit"
        return true
    end,"builtin_pack:"..key)
    if ok~=true then return Failed(err) end
    attempt.ok=true;attempt.stage="committed"
    self.trackedIndex=self:BuildTrackedIndex(Settings());self:SyncTrackedProjectionFlags()
    -- 中文维护：成功结果来自持久化事务之后的真实选择，不以实时出现数量冒充导入数。
    result.total=0
    for _,scope in ipairs({"player","target"}) do for _,category in ipairs({"buff","debuff","auto"}) do result.total=result.total+#Settings().tracked[scope][category] end end
    return true,string.format("已保存：新增追踪通道 Buff %d / Debuff %d / 自动识别 %d / CD %d；已有 %d，状态通道合计 %d。",result.buff,result.debuff,result.auto,result.cooldown,result.existing,result.total),result
end
function F:SetTrackedCooldownId(id,kind,enabled)
    id=tonumber(id)
    if (kind~="skill" and kind~="mate") or not id or id<=0 or id~=math.floor(id) or id>2147483647 then return false,"冷却技能 ID/类型无效" end
    -- 中文维护注释（.18.243 CD 收藏归属）：trackedCooldowns 与 classification/library 一起属于
    -- tracking.meta，而非一般 settings。即使当前 CD Runtime 尚未实现，也必须通过同一 A/B generation
    -- 提交，避免 player/target 列表与其元数据跨重载错代。该入口低频，不使用 Tick/debounce 合并。
    return self:MutateTrackingStore(function()
        local list={};for _,value in ipairs(Settings().trackedCooldowns[kind] or {}) do if value~=id then list[#list+1]=value end end
        if enabled then if #list>=256 then return false,"冷却追踪达到上限" end;list[#list+1]=id end
        table.sort(list);Settings().trackedCooldowns[kind]=list;return true
    end,"tracked_cooldown")
end
function F:GetManagementHealth()
    -- 中文维护注释：CD 当前仅有持久化收藏和目录，不得用候选数量冒充运行时冷却支持。
    -- tracking-scope-v1：诊断既保留 player/target 六通道明细，也提供 buff/debuff/auto 通道总数；
    -- 后者只为旧诊断消费者兼容，不是新的持久化 Authority，也不是去重后的状态数量。
    local trackedSettings=Settings().tracked
    local player={buff=#trackedSettings.player.buff,debuff=#trackedSettings.player.debuff,auto=#trackedSettings.player.auto}
    local target={buff=#trackedSettings.target.buff,debuff=#trackedSettings.target.debuff,auto=#trackedSettings.target.auto}
    return {contract=self.ManagementProjectionContractVersion,cooldownRuntime="not_implemented",freeze=self:GetManagementFreezeState(),
        tracked={
            player=player,target=target,
            buff=player.buff+target.buff,debuff=player.debuff+target.debuff,auto=player.auto+target.auto,
            channelTotal=player.buff+player.debuff+player.auto+target.buff+target.debuff+target.auto,
        },
        classification=S.Services.StatusClassificationV3:GetHealth(),
        catalog=Catalog:GetHealth(),lastImport=Copy(self.lastLibraryImport),
        -- 中文维护注释（.18.243 诊断 Authority）：状态显示持久化已拆成多个 Store，诊断必须
        -- 直接暴露 manifest generation/slot 与一次性 legacyMigration 结果；禁止再用旧
        -- v3.buff_display 的 loadStatus 推断当前运行 Authority，否则旧损坏证据会被误报成当前故障。
        persistence=type(self.GetTrackingPersistenceHealth)=="function" and self:GetTrackingPersistenceHealth() or nil,
        -- 维护：只读已有解析结果/返回形态，用于区分未调度、Native未提供图标、界面未更新。
        -- GetHealth绝不触发新的tooltip读取；采样表有界，不能把整份tooltip正文塞进诊断。
        libraryPatch=self.LibraryIntegrationPatch,
        metadata={requests=self.managementMetadata.requests or 0,cacheSkips=self.managementMetadata.cacheSkips or 0,
            inactiveSkips=self.managementMetadata.inactiveSkips or 0,queued=self.managementMetadata.queued,batches=self.managementMetadata.batches,active=self.managementMetadata.active,
            resolver=S.Services.BuffMetadataV3 and type(S.Services.BuffMetadataV3.GetHealth)=="function" and S.Services.BuffMetadataV3:GetHealth() or nil}}
end
F.Commands.CaptureManagementFreeze=function() return F:CaptureManagementFreeze() end
F.Commands.ClearManagementFreeze=function() return F:ClearFrozenRows() end
F.Commands.ResetManagementCapture=function() return F:ResetManagementCapture() end
F.Commands.ImportBuiltinPack=function(_,key,newOnly) return F:ImportBuiltinPack(key,newOnly) end
F.Commands.SetTrackedCooldownId=function(_,id,kind,enabled) return F:SetTrackedCooldownId(id,kind,enabled) end

-- 中文维护注释：只读 revision 供导入预览防陈旧提交，不暴露 Store/私有缓存。
function F:GetManagementSettingsRevision() return tonumber(self.settingsRevision) or 0 end
