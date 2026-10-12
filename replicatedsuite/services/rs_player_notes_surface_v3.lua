------------------------------------------------------------------------
-- 中文维护：用户实机证明社交UIC的GetContent/MainScript均返回nil，因此不再轮询窗口。
-- 使用社交名单/团队窗口事件：观测已有回包，不主动RequestFriendList或远征分页请求；家族只在视图需求时读getter。
-- 事件不能证明社交窗口显示/关闭，也没有窗口坐标；Presentation弹出独立备注窗，由用户手动关闭。
------------------------------------------------------------------------
if ReplicatedSuite==nil or ReplicatedSuite.BootError~=nil then return end
local S=ReplicatedSuite
S.Services=S.Services or {}
local V={topic="v3.player_notes_surface.updated",taskId="v3_player_notes_surface",started=false,revision=0,
    eventName="FRIENDLIST_INFO",eventSubscribed=false,friendListEvents=0,friendListRevision=0,invalidEvents=0,
    snapshot={popupRequested=false,status="idle",source="friend_list_event"}}
-- 中文维护：服务仅拥有脱离原始回包的只读名单事实；窗口/草稿/存档仍属于Presentation和Feature。
V.presentationBoundary="service_only"
S.Services.PlayerNotesSurfaceV3=V
local function Copy(value)local t={};for k,v in pairs(value or {})do t[k]=v end;return t end
local function CopyList(value)
    if value==nil then return nil end
    local list={};for i,row in ipairs(value)do list[i]=type(row)=="table"and Copy(row)or row end;return list
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
        for _,key in ipairs({"popupRequested","status","source","friendListRevision","friendListCount","reason","listKind","listRevision"})do
            if self.snapshot[key]~=snapshot[key]then same=false;break end
        end
        if same then return true end
    end
    self.revision=self.revision+1;snapshot.revision=self.revision;self.snapshot=Copy(snapshot)
    if S.Events then S.Events:Publish(self.topic,Copy(snapshot))end
    return true
end
-- 中文维护（2026-10-13）：名单类型是回包来源，不证明原生窗口开关。统一revision让手动收起后
-- 新的对应名单仍可弹出；Service不控制窗口、不读备注、不请求未允许的远征成员接口。
function V:NotifyList(kind,reason)
    if not self.started or ReplicatedSuite~=S then return false end
    self.listRevision=(self.listRevision or 0)+1
    return self:Publish({popupRequested=true,status="ready",source=kind=="friends"and "friend_list_event"or "social_list_event",
        listKind=kind,listRevision=self.listRevision,reason=reason,friendListRevision=self.friendListRevision,
        friendListCount=self.friendListCount},true)
end
function V:OnFriendList(first,list)
    if not self.started or ReplicatedSuite~=S then return false end
    -- 中文维护：参考插件的FRIENDLIST_INFO回包名单位于第二参数；不把任意其它table误当名单，不猜窗口开关。
    self.lastArgumentTypes=type(first)..","..type(list)
    if not DenseList(list)then self.invalidEvents=self.invalidEvents+1;return false end
    self.friendList=BoundedList(list);self.friendListEvents=self.friendListEvents+1;self.friendListRevision=self.friendListRevision+1
    self.lastEventAtMs=S.NowMs and S.NowMs()or nil;self.friendListCount=#list;self.friendListTruncated=#list>200
    return self:NotifyList("friends","friend_list_received")
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
    return self:NotifyList("expedition","expedition_list_received")
end
function V:GetSnapshot()return Copy(self.snapshot)end
function V:GetFriendListSnapshot()return CopyList(self.friendList),self.friendListCount end
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
    d.nativeVisibilityKnown=false;d.polling=false;return d
end
function V:Refresh()
    if not self.started then return false end
    return self:Publish(Copy(self.snapshot),false)
end
function V:Start()
    if self.started then return true end
    self.started=true;self.friendList=nil;self.friendListCount=0;self.friendListTruncated=false
    -- 中文维护：回包缓存属于当前观察会话；禁用/重启后不能复活上一会话的名单或callback。
    self.epoch=(self.epoch or 0)+1;local epoch=self.epoch
    self.expeditionList,self.expeditionCount,self.expeditionTotal,self.expeditionStart=nil,nil,nil,nil
    -- 中文维护：远征回包诊断是本次观察会话的事实，重新启用不能把上一会话拒收次数当成本次错误。
    self.expeditionResponses,self.expeditionRejected,self.expeditionArgumentTypes=0,0,nil
    self.listSubscriptions={}
    local events=S.Events
    if events and type(events.BindOwner)=="function"then events:BindOwner(self,"tools_player_notes")end
    -- 中文维护：只用共享EventBus的可选订阅；注册失败仍允许手动备注，不生成Tick/重试请求，不接管原生社交事件处理器。
    local function Subscribe(name,fn)
        local ok=events and type(events.SubscribeOptional)=="function"and events:SubscribeOptional(name,self,function(owner,...)
            if owner.epoch~=epoch then return false end;return fn(owner,...)
        end)==true or false
        self.listSubscriptions[name]=ok;return ok
    end
    -- 中文维护：所有监听均走共享EventBus可选订阅，缺某事件不阻断本地备注；不覆盖UIParent处理器。
    Subscribe("EXPEDITION_MANAGEMENT_MEMBERS_INFO",function(owner,...)return owner:OnExpeditionList(...)end)
    for _,event in ipairs({"BLOCKED_USERS_INFO","BLOCKED_USER_LIST","BLOCKED_USER_UPDATE"})do
        Subscribe(event,function(owner)return owner:NotifyList("block","block_list_changed")end)
    end
    for _,event in ipairs({"FAMILY_REFRESH","FAMILY_INFO_REFRESH","FAMILY_MEMBER_ONLINE","FAMILY_MEMBER_ADDED",
        "FAMILY_MEMBER_LEFT","FAMILY_MEMBER_KICKED","FAMILY_OWNER_CHANGED","FAMILY_REMOVED","FAMILY_NAME_CHANGED"})do
        Subscribe(event,function(owner)return owner:NotifyList("family","family_list_changed")end)
    end
    for _,event in ipairs({"TOGGLE_RAID_FRAME2","TOGGLE_RAID_FRAME_PARTY"})do
        Subscribe(event,function(owner)return owner:NotifyList("team","team_window_requested")end)
    end
    self.eventSubscribed=Subscribe(self.eventName,function(owner,first,list)return owner:OnFriendList(first,list)end)
    return self:Publish({popupRequested=false,status=self.eventSubscribed and "awaiting_event"or "unavailable",source="friend_list_event",
        reason=self.eventSubscribed and "waiting_friend_list"or "friend_event_unavailable"},true)
end
function V:Stop()
    self.started=false
    self.epoch=(self.epoch or 0)+1
    if S.Events and type(S.Events.UnsubscribeOwner)=="function"then S.Events:UnsubscribeOwner(self)end
    self.eventSubscribed=false;self.friendList=nil
    self.expeditionList,self.expeditionCount,self.expeditionTotal,self.expeditionStart=nil,nil,nil,nil
    return self:Publish({popupRequested=false,status="idle",source="friend_list_event",reason="feature_disabled"},true)
end
