------------------------------------------------------------------------
-- 中文维护：恢复用户实测有效的打开路径：原生好友/远征成员页请求后的有效名单回包带出备注窗；窗口Getter全nil不阻断这条链路。
-- 上线、家族/黑名单成员变化只更新数据；原生团队信息的无参用户请求可带出团队备注，不代表社交可见性；不主动RequestFriendList或远征分页请求。
-- 整个 UIC_COMMUNITY 可见性复用拍卖的只读探测；可读时只按窗口打开边沿启窗、关闭边沿收起，未知时保留有效回包路径。
-- Service拥有名单/可见性事实和响应序号，Presentation拥有独立浮窗与草稿；不上调名单请求频率。
------------------------------------------------------------------------
if ReplicatedSuite==nil or ReplicatedSuite.BootError~=nil then return end
local S=ReplicatedSuite
S.Services=S.Services or {}
local V={topic="v3.player_notes_surface.updated",taskId="v3_player_notes_surface",started=false,revision=0,openRevision=0,
    eventName="FRIENDLIST_INFO",eventSubscribed=false,friendListEvents=0,friendListRevision=0,invalidEvents=0,
    -- 中文维护：2026-10-13 MD1.1 对照证明带 self 调用可读取拍卖五字段，而社交及四个页签分类均零返回。
    -- 临时多形式调用审计默认停用，避免每次重载重复无效试读；标准可见性观察和有效名单回包降级路径继续独立运行。
    nativeCallAuditEnabled=false,
    snapshot={popupRequested=false,status="idle",source="friend_list_event"}}
-- 中文维护：服务仅拥有脱离原始回包的只读名单事实；窗口/草稿/存档仍属于Presentation和Feature。
V.presentationBoundary="service_only"
S.Services.PlayerNotesSurfaceV3=V
local function Copy(value)local t={};for k,v in pairs(value or {})do t[k]=v end;return t end
local function CopyList(value)
    if value==nil then return nil end
    local list={};for i,row in ipairs(value)do list[i]=type(row)=="table"and Copy(row)or row end;return list
end
local function CopyAudit(value)
    -- 中文维护：只深拷贝本服务构造的有界标量审计，不复制 Native 返回对象或原始名单。
    if type(value)~="table"then return value end
    local result={};for key,item in pairs(value)do result[key]=CopyAudit(item)end;return result
end
local function RawCallShape(ok,...)
    local count=select("#",...);local first=...;local row={callOk=ok==true,returnCount=ok and count or 0,values={}}
    if not ok then
        row.errorType=type(first);row.error=tostring(first):gsub("[%c]"," "):sub(1,160);return row
    end
    local types={};row.firstType=type(first)
    for i=1,math.min(count,8)do
        local value=select(i,...);local kind=type(value);types[i]=kind
        if kind=="boolean"or (kind=="number"and value==value and value~=math.huge and value~=-math.huge)then row.values[i]=value end
    end
    row.returnTypes=table.concat(types,",");row.truncated=count>8;return row
end
function V:CaptureNativeCallAudit(reason)
    if not self.started or ReplicatedSuite~=S or self.nativeCallAuditEnabled~=true or (self.nativeCallAuditCount or 0)>=12 then return false end
    local addon,api=rawget(_G,"ADDON"),S.Api
    if not addon or not api or type(api.IsCapabilityAllowed)~="function"then return false end
    local epoch,generation=self.epoch,S.Generation
    local function Live()return self.started and ReplicatedSuite==S and self.epoch==epoch and S.Generation==generation end
    local function Read(fn,...)
        if not Live()then return nil end
        local shape=RawCallShape(pcall(fn,...));if not Live()then return nil end;return shape
    end
    local frame={atMs=S.NowMs and S.NowMs()or nil,reason=tostring(reason or "observer"),targets={}}
    frame.mainAllowed=api:IsCapabilityAllowed("ADDON:GetContentMainScriptPosVis")==true
    frame.contentAllowed=api:IsCapabilityAllowed("ADDON:GetContent")==true
    frame.mainMethodType,frame.contentMethodType=type(addon.GetContentMainScriptPosVis),type(addon.GetContent)
    -- 中文维护：仅比较客户端已导出的类别，绝不猜数字ID；拍卖是同时间的正向对照，缺失的旧页签常量也如实记录。
    -- 带 self 的函数调用与官方冒号调用等价；不带 self 仅在有限审计组内试读，结果不会自动改变启窗策略。
    for _,name in ipairs({"UIC_COMMUNITY","UIC_FRIEND","UIC_FAMILY","UIC_EXPEDITION","UIC_NATION","UIC_AUCTION"})do
        if not Live()then return false end
        local id=rawget(_G,name);local row={idType=type(id)};frame.targets[name]=row
        if type(id)=="number"and id==id and id>=0 and id<=10000 and id==math.floor(id)then
            row.id=id
            if frame.mainAllowed and frame.mainMethodType=="function"then
                row.mainWithSelf=Read(addon.GetContentMainScriptPosVis,addon,id)
                row.mainWithoutSelf=Read(addon.GetContentMainScriptPosVis,id)
            end
            if frame.contentAllowed and frame.contentMethodType=="function"then
                row.contentWithSelf=Read(addon.GetContent,addon,id)
                row.contentWithoutSelf=Read(addon.GetContent,id)
            end
        end
    end
    if not Live()then return false end
    self.nativeCallAudit=self.nativeCallAudit or {};self.nativeCallAudit[#self.nativeCallAudit+1]=frame
    self.nativeCallAuditCount=(self.nativeCallAuditCount or 0)+1;self.lastNativeCallAuditAtMs=frame.atMs
    return true
end
local function DenseList(value,allowMetadata)
    -- 中文维护：客户端事件契约是数组；只对声明的dense序列采集，不把未知外壳或洞补成无人。
    if type(value)~="table"then return false end
    local n,count,scanned=#value,0,0
    for key in pairs(value)do
        -- 中文维护：expnote按1..#arg3读取远征数组，不依赖额外计数字段；仅该调用方可忽略字符串元数据。
        -- 仍要求实际有连续数字成员槽，未知wrapper/稀疏表不能冒充空名单；扫描有界，元数据不进入缓存。
        scanned=scanned+1;if scanned>1000 then return false end
        if type(key)=="number"then
            if key<1 or key~=math.floor(key)or key>n then return false end
            count=count+1
        elseif type(key)~="string"or allowMetadata~=true or n==0 then return false end
    end
    return count==n
end
local function BoundedList(value)
    local list={}
    for i=1,math.min(#value,200)do
        local row=value[i]
        if type(row)=="string"then list[i]=#row<=96 and row or ""
        elseif type(row)=="table"then
            local item={}
            -- 中文维护：只保留现有Normalizer使用的名字字段，拒绝任意嵌套对象/客户端私有引用；原始名字是否有效由Feature校验。
            for _,key in ipairs({1,"name","characterName","memberName","charName","unitName"})do
                if type(row[key])=="string"and #row[key]<=96 then item[key]=row[key]end
            end
            -- 中文维护：expnote好友第6位、远征第7位仅复制boolean；未知在线态不变造为离线。
            for _,key in ipairs({6,7,"online","isOnline"})do if type(row[key])=="boolean"then item[key]=row[key]end end
            list[i]=item
        else list[i]={}end
    end
    return list
end
function V:Publish(snapshot,force)
    if not force then
        local same=true
        for _,key in ipairs({"popupRequested","status","source","friendListRevision","friendListCount","reason","listKind","listRevision","openRevision","openSignal"})do
            if self.snapshot[key]~=snapshot[key]then same=false;break end
        end
        if same then return true end
    end
    self.revision=self.revision+1;snapshot.revision=self.revision;self.snapshot=Copy(snapshot)
    if S.Events then S.Events:Publish(self.topic,Copy(snapshot))end
    return true
end
-- 中文维护：只有经dense验证的好友/远征名单响应可产生打开序号；背景NotifyList默认只刷新，不能清除关闭状态或抢焦点。
function V:NotifyList(kind,reason,openFromResponse)
    if not self.started or ReplicatedSuite~=S then return false end
    self.listRevision=(self.listRevision or 0)+1
    local snapshot=Copy(self.snapshot)
    snapshot.status,snapshot.listKind,snapshot.listRevision="ready",kind,self.listRevision
    snapshot.listReason,snapshot.friendListRevision,snapshot.friendListCount=reason,self.friendListRevision,self.friendListCount
    if openFromResponse==true and self.nativeVisibilityKnown~=true then
        self.openRevision=self.openRevision+1
        snapshot.popupRequested,snapshot.openRevision,snapshot.openSignal=true,self.openRevision,"native_list_response"
        snapshot.openView,snapshot.source,snapshot.reason=kind,"social_list_response",reason
    end
    -- 中文维护：背景事件保留原打开序号；窗口是否已关闭由Presentation掌握，不能用此处的名单revision解除dismissed。
    return self:Publish(snapshot,true)
end
function V:OnFriendList(first,list)
    if not self.started or ReplicatedSuite~=S then return false end
    -- 中文维护：参考插件的FRIENDLIST_INFO回包名单位于第二参数；不把任意其它table误当名单，不猜窗口开关。
    self.lastArgumentTypes=type(first)..","..type(list)
    if not DenseList(list)then self.invalidEvents=self.invalidEvents+1;return false end
    self.friendList=BoundedList(list);self.friendListEvents=self.friendListEvents+1;self.friendListRevision=self.friendListRevision+1
    self.lastEventAtMs=S.NowMs and S.NowMs()or nil;self.friendListCount=#list;self.friendListTruncated=#list>200
    self:CaptureNativeCallAudit("friend_response");self.nativeCallAuditPending=true
    return self:NotifyList("friends","friend_list_received",true)
end
function V:OnExpeditionList(total,start,list)
    if not self.started or ReplicatedSuite~=S then return false end
    -- 中文维护：只保存参数类型/次数供冷诊断，区分未收到回包与已收到但结构未知，不采集玩家隐私或输出刷屏日志。
    self.expeditionResponses=(self.expeditionResponses or 0)+1
    self.expeditionArgumentTypes=type(total)..","..type(start)..","..type(list)
    -- 中文维护：expnote回包第三参数是成员数组；总数/起点来自Native分页消费契约。
    -- 每次替换当前批次，不把不同排序、在线筛选或不同公会的页混成伪造全量名单。
    if not DenseList(list,true)then self.invalidEvents=self.invalidEvents+1;self.expeditionRejected=(self.expeditionRejected or 0)+1;return false end
    local function Integer(value)
        local n=tonumber(value);return n and n==n and n>=0 and n<=100000 and n==math.floor(n)and n or nil
    end
    total,start=Integer(total),Integer(start)
    -- 中文维护：expnote只以第三参数成员数组读取名字/在线态，没有依赖前两参数的页码解释。
    -- 客户端若回零起点/不同分页语义，不能因辅助元数据而整批丢掉有效成员；仅撤下不可信页码，按partial显示。
    if (start~=nil and start<1)or (total~=nil and ((total==0 and #list>0)
        or (start~=nil and total>0 and (start>total or start+#list-1>total))))then
        total,start=nil,nil
    end
    self.expeditionList=BoundedList(list);self.expeditionCount=#list
    self.expeditionTotal,self.expeditionStart=total,start
    self.expeditionEvents=(self.expeditionEvents or 0)+1
    self:CaptureNativeCallAudit("expedition_response");self.nativeCallAuditPending=true
    return self:NotifyList("expedition","expedition_list_received",true)
end
function V:OnTeamWindowRequest(...)
    -- 中文维护：原生 raidframe.lua 的 ToggleSecondRaidFrame 是无参用户切换入口；成员变化/带未知参数的事件不能打开备注。
    -- 与 expnote 保持“请求时带出团队备注”的能力，不把无参请求伪装成原生可见性或关闭事实。
    if not self.started or select("#",...)~=0 then return false end
    local snapshot=Copy(self.snapshot);self.openRevision=self.openRevision+1;self.listRevision=(self.listRevision or 0)+1
    snapshot.status,snapshot.popupRequested,snapshot.openRevision="ready",true,self.openRevision
    snapshot.openSignal,snapshot.openView,snapshot.source="native_team_request","team","team_window_request"
    snapshot.listKind,snapshot.listRevision,snapshot.reason="team",self.listRevision,"team_window_requested"
    return self:Publish(snapshot,true)
end
function V:GetSnapshot()return Copy(self.snapshot)end
function V:GetFriendListSnapshot()return CopyList(self.friendList),self.friendListCount end
function V:ReadFriendList()
    -- 中文维护：只有用户明确刷新才重新读取允许的本地Getter；更新脱离Native的缓存，不请求服务器，也不生成启窗响应。
    if not self.started then return false,nil,nil,"名单观察已停止"end
    local api=S.Api
    if not api or type(api.CallCapability)~="function"then return false,nil,nil,"好友名单读取能力暂不可用"end
    local ok,list,why=api:CallCapability("X2Friend:GetFriendList",rawget(_G,"X2Friend"),"GetFriendList",true)
    if ok~=true or not DenseList(list)then return false,nil,nil,why or "好友名单返回结构暂未识别"end
    self.friendList=BoundedList(list);self.friendListCount=#list;self.friendListTruncated=#list>200
    self.friendListRevision=self.friendListRevision+1
    return true,CopyList(self.friendList),self.friendListCount
end
function V:ReadFamilyList()
    -- 中文维护（2026-10-13）：家族名单是共享只读事实，Native lazy所有权收口到名单Service；
    -- 只有选家族/对应事件刷新才取得FAMILY，不升为备注启动硬依赖，也不在此读取/保存个人备注。
    local imports,api=S.ApiImports,S.Api
    if not self.started then return false,nil,nil,"名单观察已停止"end
    if not imports or type(imports.AcquireApi)~="function"then return false,nil,nil,"家族名单导入服务不可用"end
    if not api or type(api.CallCapability)~="function"then return false,nil,nil,"家族名单读取能力暂不可用"end
    -- 中文维护：IsAllowed会检查宿主方法是否已存在，冷启动不能在lazy导入前使用；
    -- 先取得namespace，再让CallCapability执行官方/运行时/方法存在性门控，禁用getter仍不会调用。
    local imported,err=imports:AcquireApi("service:PlayerNotesSurfaceV3:family","X2Family:GetMemberList")
    if imported~=true then return false,nil,nil,err or "家族名单暂不可读"end
    local ok,list,why=api:CallCapability("X2Family:GetMemberList",rawget(_G,"X2Family"),"GetMemberList",true)
    if ok~=true or not DenseList(list)then return false,nil,nil,why or "家族名单返回结构暂未识别"end
    -- 中文维护：只传脱离Native的有界名单和原始条数；被截断/名字缺失由Feature解释成partial。
    return true,BoundedList(list),#list
end
function V:GetExpeditionListSnapshot()
    -- 中文维护：getter只复制已有批次及分页标量，不新增Native请求、不持有原始客户端对象。
    return CopyList(self.expeditionList),self.expeditionTotal,self.expeditionStart,self.expeditionCount
end
function V:GetDiagnostics()
    local d=Copy(self.snapshot);d.started=self.started;d.eventName=self.eventName;d.eventSubscribed=self.eventSubscribed
    d.friendListEvents=self.friendListEvents;d.friendListCount=self.friendListCount or 0;d.friendListTruncated=self.friendListTruncated==true
    d.lastEventAtMs=self.lastEventAtMs;d.invalidEvents=self.invalidEvents;d.lastArgumentTypes=self.lastArgumentTypes
    d.listSubscriptions=Copy(self.listSubscriptions);d.expeditionEvents=self.expeditionEvents or 0
    d.expeditionCount=self.expeditionCount;d.expeditionTotal=self.expeditionTotal;d.expeditionStart=self.expeditionStart
    d.expeditionResponses=self.expeditionResponses or 0;d.expeditionRejected=self.expeditionRejected or 0;d.expeditionArgumentTypes=self.expeditionArgumentTypes
    d.socialEventFactsVersion=2;d.socialEventFacts={};for name,fact in pairs(self.socialEventFacts or {})do d.socialEventFacts[name]=Copy(fact)end
    d.globalSubscriptions=Copy(self.globalSubscriptions);d.globalEventFacts={};for name,fact in pairs(self.globalEventFacts or {})do d.globalEventFacts[name]=Copy(fact)end
    d.eventTrace=CopyList(self.eventTrace)
    d.nativeVisibilityKnown=self.nativeVisibilityKnown==true;d.nativeVisible=self.nativeVisible==true
    d.polling=self.polling==true;d.visibilitySamples=self.visibilitySamples or 0
    d.visibilityKnownSamples=self.visibilityKnownSamples or 0;d.visibilityUnknownStreak=self.visibilityUnknownStreak or 0
    d.visibilityIntervalMs=self.visibilityIntervalMs
    d.visibilitySource=self.visibilitySource;d.visibilityProbe=Copy(self.visibilityProbe)
    d.nativeCallAuditVersion=1;d.nativeCallAuditEnabled=self.nativeCallAuditEnabled==true
    d.nativeCallAuditCount=self.nativeCallAuditCount or 0;d.nativeCallAudit=CopyAudit(self.nativeCallAudit or {})
    return d
end
local function RecordEvent(facts,trace,transport,name,...)
    -- 中文维护：家族切页没有已核实的响应契约；先保存有界、无角色名的事件形态供冷诊断，不凭成员事件猜启窗/关闭。
    local fact=facts[name]or {count=0};facts[name]=fact
    fact.count=fact.count+1;fact.atMs=S.NowMs and S.NowMs()or nil
    local count=select("#",...);local types={}
    for i=1,math.min(count,4)do types[i]=type(select(i,...))end
    fact.argumentCount=count;fact.argumentTypes=table.concat(types,",")..(count>4 and ",..."or "")
    local first,data=...;fact.firstBoolean=nil
    if type(first)=="boolean"then fact.firstBoolean=first end
    local uic=type(data)=="table"and rawget(data,"uic")or nil
    fact.uic=type(uic)=="number"and uic==uic and uic>=0 and uic<=10000 and uic==math.floor(uic)and uic or nil
    if #trace>=24 then table.remove(trace,1)end
    local edge=Copy(fact);edge.event=name;edge.transport=transport;trace[#trace+1]=edge
end
function V:RecordSocialEvent(name,...)
    return RecordEvent(self.socialEventFacts,self.eventTrace,"window",name,...)
end
function V:RecordGlobalEvent(name,...)
    -- 中文维护：复用同一无名字、无嵌套对象的格式，分开统计传输，不能把 Window 事件未收到误判成所有 UI 入口均无信号。
    return RecordEvent(self.globalEventFacts,self.eventTrace,"global",name,...)
end
function V:Refresh()
    if not self.started then return false end
    return self:Publish(Copy(self.snapshot),false)
end
function V:RefreshNativeVisibility()
    if not self.started or ReplicatedSuite~=S then return false end
    local reader=S.Services.AuctionSurfaceV3
    if not reader or type(reader.ReadNativeVisibility)~="function"then return false end
    local known,visible,source,probe=reader:ReadNativeVisibility(rawget(_G,"UIC_COMMUNITY"),false)
    self.visibilitySamples=(self.visibilitySamples or 0)+1
    if known==true then
        self.visibilityKnownSamples=(self.visibilityKnownSamples or 0)+1;self.visibilityUnknownStreak=0
    else self.visibilityUnknownStreak=(self.visibilityUnknownStreak or 0)+1 end
    -- 中文维护：MD1.1 实机采样117次后 UIC_COMMUNITY 的 getter 仍全空，且有效回包也未观察到原生打开。
    -- 连续8次未知后降到2秒，恢复可读立即回到250ms；只改本服务任务，不缓存“已关闭”、不停止对晚创建窗口的检查。
    local interval=self.visibilityUnknownStreak>=8 and 2000 or 250
    if self.polling and interval~=self.visibilityIntervalMs and S.Scheduler and type(S.Scheduler.SetTaskInterval)=="function"then
        if S.Scheduler:SetTaskInterval(self.taskId,interval)==true then self.visibilityIntervalMs=interval end
    end
    self.visibilitySource,self.visibilityProbe=source,Copy(probe)
    local now=S.NowMs and S.NowMs()or 0
    -- 中文维护：只保留本次加载最多12组原始调用对照；回包后下一次调度补采一次，区分 Native OnEvent 与窗口已完成显示的时机。
    if self.nativeCallAuditEnabled==true and (self.nativeCallAuditPending or self.lastNativeCallAuditAtMs==nil or now-self.lastNativeCallAuditAtMs>=2000)then
        self:CaptureNativeCallAudit(self.nativeCallAuditPending and "after_list_response"or "observer")
        self.nativeCallAuditPending=false
    end
    local changed=self.nativeVisibilityKnown~=(known==true)or (known==true and self.nativeVisible~=(visible==true))
    self.nativeVisibilityKnown,self.nativeVisible=known==true,visible==true
    if not changed then return true end
    local snapshot=Copy(self.snapshot);snapshot.nativeVisibilityKnown=known==true;snapshot.nativeVisible=visible==true
    if known==true then
        local edge=self.lastKnownNativeVisible~=(visible==true)
        self.lastKnownNativeVisible=visible==true
        snapshot.status,snapshot.source="ready","native_community_visibility"
        snapshot.popupRequested=visible==true;snapshot.reason=visible and "native_community_open"or "native_community_closed"
        if visible==true and edge then
            self.openRevision=self.openRevision+1;snapshot.openRevision=self.openRevision
            snapshot.openSignal="native_community_visible"
            -- 中文维护：整个社交可见性不泄露选中页签；保留备注自己的视图，不猜四个原生按钮当前选择。
            snapshot.openView=nil
        elseif visible~=true and edge then
            self.nativeCloseRevision=(self.nativeCloseRevision or 0)+1;snapshot.nativeCloseRevision=self.nativeCloseRevision
        end
    end
    return self:Publish(snapshot,true)
end
function V:Start()
    if self.started then return true end
    self.started=true;self.friendList=nil;self.friendListCount=0;self.friendListTruncated=false
    -- 中文维护：回包缓存属于当前观察会话；禁用/重启后不能复活上一会话的名单或callback。
    self.epoch=(self.epoch or 0)+1;local epoch=self.epoch
    self.expeditionList,self.expeditionCount,self.expeditionTotal,self.expeditionStart=nil,nil,nil,nil
    -- 中文维护：远征回包诊断是本次观察会话的事实，重新启用不能把上一会话拒收次数当成本次错误。
    self.expeditionResponses,self.expeditionRejected,self.expeditionArgumentTypes=0,0,nil
    self.listSubscriptions={};self.socialEventFacts={};self.globalSubscriptions={};self.globalEventFacts={};self.eventTrace={}
    self.nativeVisibilityKnown,self.nativeVisible,self.polling=false,false,false
    self.lastKnownNativeVisible=nil;self.nativeCloseRevision=self.nativeCloseRevision or 0
    self.visibilitySamples,self.visibilitySource,self.visibilityProbe=0,nil,nil
    self.visibilityKnownSamples,self.visibilityUnknownStreak,self.visibilityIntervalMs=0,0,nil
    self.nativeCallAudit,self.nativeCallAuditCount,self.lastNativeCallAuditAtMs,self.nativeCallAuditPending={},0,nil,false
    local events=S.Events
    if events and type(events.BindOwner)=="function"then events:BindOwner(self,"tools_player_notes")end
    -- 中文维护：只用共享EventBus的可选订阅；注册失败仍允许手动备注，不生成Tick/重试请求，不接管原生社交事件处理器。
    local function Subscribe(name,fn,record)
        local ok=events and type(events.SubscribeOptional)=="function"and events:SubscribeOptional(name,self,function(owner,...)
            if owner.epoch~=epoch then return false end;if record~=false then owner:RecordSocialEvent(name,...)end;return fn(owner,...)
        end)==true or false
        self.listSubscriptions[name]=ok;return ok
    end
    -- 中文维护：所有监听均走共享EventBus可选订阅，缺某事件不阻断本地备注；不覆盖UIParent处理器。
    Subscribe("EXPEDITION_MANAGEMENT_MEMBERS_INFO",function(owner,...)return owner:OnExpeditionList(...)end)
    -- 中文维护：这两个名称已在本地客户端事件表/参考插件中声明，参数语义尚待实机；可选监听只记录，不接管原生Trigger。
    Subscribe("TOGGLE_COMMUNITY",function()return true end)
    for _,name in ipairs({"TOGGLE_COMMUNITY","FAMILY_REFRESH","FAMILY_INFO_REFRESH","FAMILY_MEMBER","FAMILY_MGR","TOGGLE_RAID_FRAME","TOGGLE_RAID_FRAME2"})do
        -- 中文维护：参考 expnote 的 UIParent:SetEventHandler 注册入口；使用共享 EventBus 的精确释放/代次保护，不接管原生窗口。
        self.globalSubscriptions[name]=events and type(events.SubscribeGlobalOptional)=="function"and events:SubscribeGlobalOptional(name,self,function(owner,...)
            if owner.epoch~=epoch then return false end;owner:RecordGlobalEvent(name,...)
            if name=="TOGGLE_RAID_FRAME2"then return owner:OnTeamWindowRequest(...)end;return true
        end)==true or false
    end
    if self.globalSubscriptions.TOGGLE_RAID_FRAME2~=true then Subscribe("TOGGLE_RAID_FRAME2",function(owner,...)return owner:OnTeamWindowRequest(...)end)end
    -- 中文维护：普通聊天不记录内容、不读取身份、不扫名单；仅匹配本人备注命令后走 Feature 的唯一 Store 事务。
    Subscribe("CHAT_MESSAGE",function(_,channel,relation,sender,message)
        local feature=S.Features and S.Features.PlayerNotes
        if feature and type(feature.HandleChatCommand)=="function"then return feature:HandleChatCommand(sender,message)end
    end,false)
    for _,event in ipairs({"BLOCKED_USERS_INFO","BLOCKED_USER_LIST","BLOCKED_USER_UPDATE"})do
        Subscribe(event,function(owner)return owner:NotifyList("block","block_list_changed")end)
    end
    for _,event in ipairs({"FAMILY_REFRESH","FAMILY_INFO_REFRESH","FAMILY_MEMBER","FAMILY_MGR","FAMILY_MEMBER_ONLINE","FAMILY_MEMBER_ADDED",
        "FAMILY_MEMBER_LEFT","FAMILY_MEMBER_KICKED","FAMILY_OWNER_CHANGED","FAMILY_REMOVED","FAMILY_NAME_CHANGED"})do
        Subscribe(event,function(owner)return owner:NotifyList("family","family_list_changed")end)
    end
    -- 中文维护：社交名单与团队信息请求各有明确来源，团队请求不能冒充社交开关；团队名单仍由既有Roster按需更新。
    self.eventSubscribed=Subscribe(self.eventName,function(owner,first,list)return owner:OnFriendList(first,list)end)
    self:Publish({popupRequested=false,status=self.eventSubscribed and "awaiting_event"or "unavailable",source="friend_list_event",
        reason=self.eventSubscribed and "waiting_friend_list"or "friend_event_unavailable"},true)
    -- 中文维护：复用拍卖侧窗的 250ms 共享 Scheduler；每次最多两次 ADDON 读取，兼容父链最多9层，不读名单/请求服务器/枚举窗口。
    -- 即便初次返回 unknown 仍保留观察，因为社交可能尚未创建；停止/旧代次回调立即失效，不新增每帧 OnUpdate。
    local reader=S.Services.AuctionSurfaceV3;local scheduler=S.Scheduler
    if reader and type(reader.ReadNativeVisibility)=="function"and scheduler and type(scheduler.AddTask)=="function"then
        self.polling=scheduler:AddTask(self.taskId,250,function()
            if V.started and V.epoch==epoch and ReplicatedSuite==S then V:RefreshNativeVisibility()end
        end,false,self,"P2")==true
        if self.polling then self.visibilityIntervalMs=250 end
        if self.polling and type(scheduler.SetTaskModule)=="function"then scheduler:SetTaskModule(self.taskId,"tools_player_notes",true)end
        self:RefreshNativeVisibility()
    end
    return true
end
function V:Stop()
    self.started=false
    if S.Scheduler and type(S.Scheduler.RemoveTask)=="function"then S.Scheduler:RemoveTask(self.taskId)end
    self.polling=false;self.nativeVisibilityKnown=false;self.nativeVisible=false
    self.visibilityIntervalMs=nil
    self.nativeCallAuditPending=false
    self.epoch=(self.epoch or 0)+1
    if S.Events and type(S.Events.UnsubscribeOwner)=="function"then S.Events:UnsubscribeOwner(self)end
    if S.Events and type(S.Events.UnsubscribeGlobalOwner)=="function"then S.Events:UnsubscribeGlobalOwner(self)end
    self.eventSubscribed=false;self.friendList=nil
    self.expeditionList,self.expeditionCount,self.expeditionTotal,self.expeditionStart=nil,nil,nil,nil
    return self:Publish({popupRequested=false,status="idle",source="friend_list_event",reason="feature_disabled"},true)
end
