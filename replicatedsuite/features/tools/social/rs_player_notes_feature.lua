------------------------------------------------------------------------
-- Replicated Suite · 人员备注功能入口
-- 作者：Replicated
-- QQ群：1104129461
--
-- 人员备注拥有独立账号 Store；精确完整名字是唯一键，绝不折叠同名跨服身份。
-- 只在页面持有 Demand 时复用 TeamRoster，退出即释放；无窗口枚举、io.open 或自己的轮询。
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S, TOKEN = ReplicatedSuite, "player_notes:roster"
local Factory = S.FeatureSliceFactory
local MAX_NOTES, MAX_NAME, MAX_NOTE = 200, 96, 384
local function Clean(value, limit)
    if type(value) ~= "string" then return nil end
    value = value:match("^%s*(.-)%s*$")
    if #value > limit or value:find("[%c]") then return nil end
    return value
end
local function Roster() return S.Services and S.Services.TeamRosterV3 end
local function SyncRoster(feature,count)
    -- 只有可见消费者正在看团队时持有共享Roster；好友/家族/已保存备注不触发整团UnitName扫描，也不另建名单轮询。
    local wanted=feature.view=="team"and (tonumber(count)or 0)>0
    if wanted and not feature.rosterHeld then
        local roster=Roster();local ok,why=false,"团队名单服务不可用"
        if roster then ok,why=roster:AcquireConsumer(TOKEN,{purpose="player_notes"})end
        feature.rosterHeld=ok==true;feature.rosterError=ok~=true and why or nil
    elseif not wanted and feature.rosterHeld then
        local roster=Roster();local ok,why=false,"团队名单服务不可用"
        if roster then ok,why=roster:ReleaseConsumer(TOKEN)end
        if ok~=true then return false,why or "团队名单释放失败"end
        feature.rosterHeld=false;feature.rosterError=nil
    end
    return true
end
local function Refresh(feature, reason) return feature.Authority:Refresh(reason or "notes_changed") end
-- 四种社交名单与团队/已保存共用唯一备注Store，视图和分页只活在会话。
local VIEW_LABEL={friends="好友",block="黑名单",family="家族",expedition="远征队",team="团队",saved="已保存"}
local function NameSort(feature)
    return feature.nameSortByView and feature.nameSortByView[feature.view or "saved"]or ((feature.view=="friends"or feature.view==nil or feature.view=="saved")and "asc"or "none")
end
local function SortRows(feature,rows)
    -- 原生好友LISTCTRL首次装载按完整名字升序，远征回包已有服务器排序；各视图显式表头选择仅改变本地只读投影。
    local direction=NameSort(feature)
    if direction=="asc"then table.sort(rows,function(a,b)return a.name<b.name end)
    elseif direction=="desc"then table.sort(rows,function(a,b)return a.name>b.name end)end
    -- 已保存备注的编号固定按完整名字升序，与 /bzdel 序号共用；其它名单编号仅代表当前显示顺序。
    for i,row in ipairs(rows)do row.listIndex=row.noteIndex or i end
    return rows
end
local function AppendMembers(feature,list,label,onlineIndex)
    local rows,seen,unknown={},{},false
    -- 真正空表才表示无人；未知外壳/稀疏数组不能被Lua长度运算吞成空名单。
    local scanned=0
    for key in pairs(list)do
        scanned=scanned+1
        if scanned>1000 then return {},true end
        if type(key)~="number"or key<1 or key~=math.floor(key)or key>#list then unknown=true end
    end
    for i=1,math.min(#list,200)do
        local entry=list[i]
        local name=type(entry)=="table"and (entry.name or entry.characterName or entry.memberName or entry.charName or entry.unitName or entry[1])or entry
        name=Clean(name,MAX_NAME)
        if name and name~=""then
            if not seen[name]then
                local online
                -- 已核expnote好友6/远征7位及命名boolean才是在线事实，缺字段显示未知。
                if type(entry)=="table"then
                    if type(entry.online)=="boolean"then online=entry.online
                    elseif type(entry.isOnline)=="boolean"then online=entry.isOnline
                    elseif onlineIndex and type(entry[onlineIndex])=="boolean"then online=entry[onlineIndex]end
                end
                seen[name]=true;rows[#rows+1]={key=name,name=name,memberName=name,note=feature.State.notes[name]or "",
                    source=label,online=online,statusText=online==nil and "未知"or (online and "在线"or "离线")}
            end
        else unknown=true end
    end
    return rows,unknown
end
local function ReadSocialMembers(feature,view,reason)
    local observer=S.Services and S.Services.PlayerNotesSurfaceV3
    local list,total,start,count,ok,why
    if view=="friends"and observer and type(observer.GetFriendListSnapshot)=="function"then
        if (reason=="notes_manual"or reason=="notes_popup_manual")and type(observer.ReadFriendList)=="function"then
            ok,list,total,why=observer:ReadFriendList()
            if ok~=true then return {},"unavailable",why or "好友名单暂不可读"end
        else list,total=observer:GetFriendListSnapshot()end
    end
    if view=="expedition"then
        if observer and type(observer.GetExpeditionListSnapshot)=="function"then list,total,start,count=observer:GetExpeditionListSnapshot()end
        if type(list)~="table"then
            -- 获取失败分清未订阅/未回包/第三参数形态未知；全部来自名单Service冷事实，不另发Native请求。
            local d=observer and type(observer.GetDiagnostics)=="function"and observer:GetDiagnostics()or {}
            local subscribed=d.listSubscriptions and d.listSubscriptions.EXPEDITION_MANAGEMENT_MEMBERS_INFO
            if subscribed==false then return {},"unavailable","远征队成员事件订阅失败；请重新启用人员备注。"end
            if (d.expeditionRejected or 0)>0 then return {},"unavailable","已收到远征队回包，但成员结构未识别（"..tostring(d.expeditionArgumentTypes).."）。"end
            return {},"unavailable","尚未收到远征队成员回包；请打开原生成员页并翻页或切换在线筛选。"
        end
    elseif type(list)~="table"then
        if view=="family"then
            -- 名单Service拥有家族Native lazy能力，Feature只把脱离客户端的名字与唯一备注Store汇合。
            if not observer or type(observer.ReadFamilyList)~="function"then return {},"unavailable","家族名单服务不可用"end
            ok,list,total,why=observer:ReadFamilyList()
        elseif view=="block"then ok,list,why=Factory.Call("X2Friend:GetBlockList",rawget(_G,"X2Friend"),"GetBlockList")
        else ok,list,why=Factory.Call("X2Friend:GetFriendList",rawget(_G,"X2Friend"),"GetFriendList",true)end
        if ok~=true or type(list)~="table"then return {},"unavailable",why or (VIEW_LABEL[view].."名单暂不可读；可切换已保存备注")end
    end
    local rows,unknown=AppendMembers(feature,list,VIEW_LABEL[view],view=="friends"and 6 or (view=="expedition"and 7 or nil))
    feature.listCount,feature.listTotal,feature.listStart=count or #list,total or #list,start
    local status=unknown and "partial"or (#rows>0 and "ready"or "empty")
    local error=unknown and ("部分"..VIEW_LABEL[view].."名字无法识别")or nil
    if view=="expedition"and (total==nil or start==nil or start~=1 or count~=total)then
        -- 未提供可信分页参数或仅返回局部页，一律说明部分覆盖；不主动请求禁用成员API。
        feature.listTotal=total;status="partial"
        error=(unknown and "部分名字未识别；"or "").."已读"..tostring(#rows).."人 / "..tostring(total or "总数未知").."；在原生远征队成员页翻页可查看对应名单。"
    elseif (total or #list)>200 then error="仅显示前200名"..VIEW_LABEL[view];status="partial"end
    return SortRows(feature,rows),status,error
end
local function Commit(feature, name, note)
    name, note = Clean(name, MAX_NAME), Clean(note, MAX_NOTE)
    if not name or name == "" or note == nil then return false, "完整角色名最多96字节，备注最多384字节；不接受控制字符" end
    local ready, err = Factory.Load(feature); if not ready then return false, err end
    local count = 0; for _ in pairs(feature.State.notes) do count = count + 1 end
    if note ~= "" and feature.State.notes[name] == nil and count >= MAX_NOTES then return false, "备注已达200条上限" end
    -- 清空备注是显式删除，全部变更仍走 Core 事务；保存拒绝不能提前改变界面或覆盖损坏 Store。
    local ok, why = Factory.PersistStateMutation(feature, "player_note", function(state)
        state.notes[name] = note ~= "" and note or nil; return true
    end)
    if ok then Refresh(feature, "notes_changed") end
    return ok, why
end
local F = Factory.NewFeature("tools_player_notes", {
    state={notes={}}, default={notes={}}, apiDependencies={"X2Unit:UnitName","X2Friend:GetFriendList","X2Friend:GetBlockList"},
    onEnable=function()
        local surface=S.Services and S.Services.PlayerNotesSurfaceV3
        if surface then return surface:Start()end;return true
    end,
    onDisable=function()
        local surface=S.Services and S.Services.PlayerNotesSurfaceV3
        if surface then return surface:Stop()end;return true
    end,
    persistenceBudget={maxDepth=4,maxNodes=1024,maxStringBytes=100000,maxEntriesPerTable=220},
    apply=function(value, state)
        -- 新增独立 Store 无旧文件猜测迁移；非法/超量数据由读取事务拒绝，不能静默截断后写回。
        assert(type(value)=="table" and type(value.notes)=="table", "invalid_player_notes")
        local notes, count = {}, 0
        for name, note in pairs(value.notes) do
            assert(Clean(name,MAX_NAME)==name and name~="" and Clean(note,MAX_NOTE)==note and note~="", "invalid_player_note")
            count=count+1; assert(count<=MAX_NOTES,"player_notes_limit");notes[name]=note
        end
        state.notes=notes
    end,
    reconcileDemand=function(feature,before,after)
        local b,a=tonumber(before.count) or 0,tonumber(after.count) or 0
        local rosterOk,rosterErr=SyncRoster(feature,a);if rosterOk~=true then return false,rosterErr end
        if b<=0 and a>0 then
            if S.Events then S.Events:SubscribeInternal("v3.team_roster.updated",feature,function()
                if feature.enabled and (feature.consumerCount or 0)>0 and feature.view=="team" then Refresh(feature,"team_changed") end
            end) end
            -- 页面可独立消费名单更新；浮窗未显示时也能刷新当前视图，不另建事件所有者。
            local observer=S.Services and S.Services.PlayerNotesSurfaceV3
            if S.Events and observer then S.Events:SubscribeInternal(observer.topic,feature,function(_,snapshot)
                if feature.enabled and (feature.consumerCount or 0)>0 and snapshot.listKind==feature.view then Refresh(feature,"notes_list_changed")end
            end)end
        elseif b>0 and a<=0 then
            feature.rosterHeld=false
            if S.Events then S.Events:UnsubscribeInternalOwner(feature) end
        end
        return true
    end,
    read=function(feature,reason)
        local rows={}
        feature.listCount,feature.listTotal,feature.listStart=nil,nil,nil
        if feature.view=="friends"or feature.view=="block"or feature.view=="family"or feature.view=="expedition"then
            return ReadSocialMembers(feature,feature.view,reason)
        end
        if feature.view=="team" then
            local roster=Roster();local snapshot=feature.rosterHeld and roster and roster:GetSnapshot() or {}
            -- 原生团队信息请求只在本次打开时选人数较多的联队；初次共享Roster尚未采齐则等首个有效更新，手动筛选立即取消自动选择。
            if feature.autoPickTeam then
                local counts={0,0};for _,member in ipairs(snapshot.members or {})do
                    local team,index=tonumber(member.teamIndex),tonumber(member.memberIndex)
                    if (team==1 or team==2)and index and index>0 then counts[team]=counts[team]+1 end
                end
                if counts[1]+counts[2]>0 then feature.teamScope=counts[1]>=counts[2]and 1 or 2;feature.autoPickTeam=false end
            end
            for _,member in ipairs(snapshot.members or {}) do
                -- 联合团队筛选只投影共享Roster，队伍号由已核memberIndex每五槽分组，不猜unit token。
                if (tonumber(member.teamIndex)or 0)>0 and (tonumber(member.memberIndex)or 0)>0
                    and ((feature.teamScope or 0)==0 or tonumber(member.teamIndex)==feature.teamScope)then
                local group="团"..tostring(member.teamIndex).." · "..tostring(math.ceil(member.memberIndex/5)).."队"
                rows[#rows+1]={key=member.name,name=member.name,note=feature.State.notes[member.name] or "",
                    source=group,statusText=group,teamIndex=member.teamIndex,memberIndex=member.memberIndex,
                    partyIndex=math.ceil(member.memberIndex/5),memberName=member.name}
                end
            end
            -- 共享Roster会把玩家seed放在首位，团队备注按真实团号/成员槽排序，才能与原生每五槽一队一致；不重排共享快照。
            table.sort(rows,function(a,b)
                if a.teamIndex~=b.teamIndex then return a.teamIndex<b.teamIndex end
                if a.memberIndex~=b.memberIndex then return a.memberIndex<b.memberIndex end
                return a.name<b.name
            end)
            return SortRows(feature,rows),feature.rosterHeld and (#rows>0 and "ready" or "empty") or "unavailable",feature.rosterError
        end
        for name,note in pairs(feature.State.notes) do rows[#rows+1]={key=name,name=name,note=note,source="已保存",memberName=name} end
        table.sort(rows,function(a,b)return a.name<b.name end)
        for i,row in ipairs(rows)do row.noteIndex=i end
        return SortRows(feature,rows),#rows>0 and "ready" or "empty"
    end,
    -- 列表覆盖和团队筛选均为脱离Store的会话标量，旧备注canonical/schema保持不变。
    projection=function(feature)return {view=feature.view or "saved",viewLabel=VIEW_LABEL[feature.view or "saved"],teamScope=feature.teamScope or 0,nameSort=NameSort(feature),
        listCount=feature.listCount,listTotal=feature.listTotal,listStart=feature.listStart,
        noteCount=(function()local n=0;for _ in pairs(feature.State.notes)do n=n+1 end;return n end)()}end,
    commands={
        SetNameSort=function(feature,direction)
            if direction~="asc"and direction~="desc"and direction~="none"then return false,"未知名字排序方式"end
            -- 排序是各视图会话状态，不写账号Store，不读Native，不改变名字/备注身份键。
            feature.nameSortByView=feature.nameSortByView or {};feature.nameSortByView[feature.view or "saved"]=direction
            return Refresh(feature,"notes_sort")
        end,
        SaveNote=function(feature,name,note)return Commit(feature,name,note)end,
        DeleteNote=function(feature,name)return Commit(feature,name,"")end,
        SetView=function(feature,view)
            if VIEW_LABEL[view]==nil then return false,"未知备注视图" end
            local ok,why=Factory.Load(feature);if not ok then return false,why end
            local previous=feature.view;feature.view=view
            local synced,err=SyncRoster(feature,feature.consumerCount)
            if synced~=true then feature.view=previous;return false,err end
            return Refresh(feature,"notes_view")
        end,
        SetTeamScope=function(feature,scope)
            scope=tonumber(scope);if scope~=0 and scope~=1 and scope~=2 then return false,"请选择全部团队、团队1或团队2"end
            feature.autoPickTeam=false;feature.teamScope=scope;return Refresh(feature,"notes_team_scope")
        end,
        SelectLargestTeam=function(feature)
            local ok,why=Factory.Load(feature);if not ok then return false,why end
            local previous=feature.view;feature.view="team"
            local synced,err=SyncRoster(feature,feature.consumerCount);if synced~=true then feature.view=previous;return false,err end
            feature.teamScope=0;feature.autoPickTeam=true;return Refresh(feature,"notes_team_open")
        end,
        GetTargetName=function()
            local ok,name,why=Factory.Call("X2Unit:UnitName",rawget(_G,"X2Unit"),"UnitName","target")
            name=ok and Clean(name,MAX_NAME) or nil
            if not name or name=="" then return false,why or "当前目标名字不可读" end
            return true,name
        end,
    },
})
-- 社交页等读者仅拿标量备注；getter 不读 Native，也不订阅名单或暴露可变 Store 表。
function F:GetNote(name)
    local ok=Factory.Load(self);if not ok then return "" end
    return self.State.notes[tostring(name or "")] or ""
end
function F:HandleChatCommand(sender,message)
    -- 只响应精确命令前缀和当前玩家的聊天回包，不能由别人的同文本修改备注；普通聊天零Native读取。
    if not self.enabled or type(message)~="string"then return false end
    local command=message:match("^(%S+)")
    if command~="/bz"and command~="/bzdel"and command~="/bzlist"then return false end
    local known,player=Factory.Call("X2Unit:UnitName",rawget(_G,"X2Unit"),"UnitName","player")
    if known~=true or type(player)~="string"or sender~=player then return false end
    local function Feedback(ok,text)
        -- 沿用 Suite 的本地系统消息出口，主菜单隐藏时也能看到成功/失败；不调用任何向频道或其他玩家发送消息的 API。
        if type(S.SafeChat)=="function"then S.SafeChat("人员备注："..tostring(text or ""))end
        if S.Events then S.Events:Publish("v3.player_notes.command_feedback",{ok=ok==true,text=tostring(text or "")})end
        return ok,text
    end
    message=Clean(message,MAX_NAME+MAX_NOTE+16)
    if not message then return Feedback(false,"命令过长或含控制字符")end
    local ready,why=Factory.Load(self);if not ready then return Feedback(false,why)end
    local rest=message:match("^/%w+%s*(.-)%s*$")or ""
    if command=="/bzlist"then
        if rest~=""then return Feedback(false,"用法：/bzlist")end
        -- 命令列表采用同一已保存视图，可滚动查看完整名字/备注；显式意图由Presentation消费，Feature不拥有窗口。
        self.nameSortByView=self.nameSortByView or {};self.nameSortByView.saved="asc"
        if S.Events then S.Events:Publish("v3.player_notes.user_intent",{view="saved"})end
        local count=0;for _ in pairs(self.State.notes)do count=count+1 end
        return Feedback(true,"已保存备注 "..count.." 条；可按列表编号使用 /bzdel 序号")
    end
    local name,note
    if command=="/bz"then
        if rest==""then return Feedback(false,"用法：/bz 备注（当前目标）或 /bz 玩家名 备注")end
        name,note=rest:match("^(%S+)%s+(.+)$")
        if not name then local ok,target=self.Commands:GetTargetName();if not ok then return Feedback(false,target)end;name,note=target,rest end
        local ok,err=self.Commands:SaveNote(name,note);return Feedback(ok,ok and ("已备注："..name)or err)
    end
    if rest==""then local ok,target=self.Commands:GetTargetName();if not ok then return Feedback(false,target)end;name=target
    elseif rest:match("^%d+$")then
        local index=tonumber(rest);local keys={};for key in pairs(self.State.notes)do keys[#keys+1]=key end;table.sort(keys)
        name=index and keys[index];if not name then return Feedback(false,"备注序号无效")end
    else name=rest end
    if self.State.notes[name]==nil then return Feedback(false,"该角色没有已保存备注")end
    local ok,err=self.Commands:DeleteNote(name);return Feedback(ok,ok and ("已删除备注："..name)or err)
end
S.Features.PlayerNotes=F
