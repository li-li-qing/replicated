------------------------------------------------------------------------
-- 中文维护：用户实机证明社交UIC的GetContent/MainScript均返回nil，因此不再轮询窗口。
-- 改用用户认可的FRIENDLIST_INFO名单返回事件：仅观测已有回包，不主动RequestFriendList。
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
local function BoundedList(value)
    local list={}
    for i=1,math.min(#value,200)do
        local row=value[i]
        if type(row)=="string"then list[i]=#row<=96 and row or ""
        elseif type(row)=="table"then
            local item={}
            -- 中文维护：只保留现有Normalizer使用的名字字段，拒绝任意嵌套对象/客户端私有引用；原始名字是否有效由Feature校验。
            for _,key in ipairs({1,"name","characterName","memberName","charName"})do
                if type(row[key])=="string"and #row[key]<=96 then item[key]=row[key]end
            end
            list[i]=item
        else list[i]={}end
    end
    return list
end
function V:Publish(snapshot,force)
    if not force then
        local same=true
        for _,key in ipairs({"popupRequested","status","source","friendListRevision","friendListCount","reason"})do
            if self.snapshot[key]~=snapshot[key]then same=false;break end
        end
        if same then return true end
    end
    self.revision=self.revision+1;snapshot.revision=self.revision;self.snapshot=Copy(snapshot)
    if S.Events then S.Events:Publish(self.topic,Copy(snapshot))end
    return true
end
function V:OnFriendList(first,list)
    if not self.started or ReplicatedSuite~=S then return false end
    -- 中文维护：参考插件的FRIENDLIST_INFO回包名单位于第二参数；不把任意其它table误当名单，不猜窗口开关。
    self.lastArgumentTypes=type(first)..","..type(list)
    if type(list)~="table"then self.invalidEvents=self.invalidEvents+1;return false end
    self.friendList=BoundedList(list);self.friendListEvents=self.friendListEvents+1;self.friendListRevision=self.friendListRevision+1
    self.lastEventAtMs=S.NowMs and S.NowMs()or nil;self.friendListCount=#list;self.friendListTruncated=#list>200
    return self:Publish({popupRequested=true,status="ready",source="friend_list_event",reason="friend_list_received",
        friendListRevision=self.friendListRevision,friendListCount=#list},true)
end
function V:GetSnapshot()return Copy(self.snapshot)end
function V:GetFriendListSnapshot()return CopyList(self.friendList),self.friendListCount end
function V:GetDiagnostics()
    local d=Copy(self.snapshot);d.started=self.started;d.eventName=self.eventName;d.eventSubscribed=self.eventSubscribed
    d.friendListEvents=self.friendListEvents;d.friendListCount=self.friendListCount or 0;d.friendListTruncated=self.friendListTruncated==true
    d.lastEventAtMs=self.lastEventAtMs;d.invalidEvents=self.invalidEvents;d.lastArgumentTypes=self.lastArgumentTypes
    d.nativeVisibilityKnown=false;d.polling=false;return d
end
function V:Refresh()
    if not self.started then return false end
    return self:Publish(Copy(self.snapshot),false)
end
function V:Start()
    if self.started then return true end
    self.started=true;self.friendList=nil;self.friendListCount=0;self.friendListTruncated=false
    local events=S.Events
    if events and type(events.BindOwner)=="function"then events:BindOwner(self,"tools_player_notes")end
    -- 中文维护：只用共享EventBus的可选订阅；注册失败仍允许手动备注，不生成Tick/重试请求，不接管原生社交事件处理器。
    self.eventSubscribed=events and type(events.SubscribeOptional)=="function"and events:SubscribeOptional(self.eventName,self,function(owner,first,list)
        return owner:OnFriendList(first,list)
    end)==true or false
    return self:Publish({popupRequested=false,status=self.eventSubscribed and "awaiting_event"or "unavailable",source="friend_list_event",
        reason=self.eventSubscribed and "waiting_friend_list"or "friend_event_unavailable"},true)
end
function V:Stop()
    self.started=false
    if S.Events and type(S.Events.UnsubscribeOwner)=="function"then S.Events:UnsubscribeOwner(self)end
    self.eventSubscribed=false;self.friendList=nil
    return self:Publish({popupRequested=false,status="idle",source="friend_list_event",reason="feature_disabled"},true)
end
