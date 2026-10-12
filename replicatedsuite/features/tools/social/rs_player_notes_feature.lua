------------------------------------------------------------------------
-- 中文维护：人员备注拥有独立账号 Store；精确完整名字是唯一键，绝不折叠同名跨服身份。
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
local function Refresh(feature, reason) return feature.Authority:Refresh(reason or "notes_changed") end
local function Commit(feature, name, note)
    name, note = Clean(name, MAX_NAME), Clean(note, MAX_NOTE)
    if not name or name == "" or note == nil then return false, "完整角色名最多96字节，备注最多384字节；不接受控制字符" end
    local ready, err = Factory.Load(feature); if not ready then return false, err end
    local count = 0; for _ in pairs(feature.State.notes) do count = count + 1 end
    if note ~= "" and feature.State.notes[name] == nil and count >= MAX_NOTES then return false, "备注已达200条上限" end
    -- 中文维护：清空备注是显式删除，全部变更仍走 Core 事务；保存拒绝不能提前改变界面或覆盖损坏 Store。
    local ok, why = Factory.PersistStateMutation(feature, "player_note", function(state)
        state.notes[name] = note ~= "" and note or nil; return true
    end)
    if ok then Refresh(feature, "notes_changed") end
    return ok, why
end
local F = Factory.NewFeature("tools_player_notes", {
    state={notes={}}, default={notes={}}, apiDependencies={"X2Unit:UnitName","X2Friend:GetFriendList"},
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
        -- 中文维护：新增独立 Store 无旧文件猜测迁移；非法/超量数据由读取事务拒绝，不能静默截断后写回。
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
        if b<=0 and a>0 then
            local roster=Roster()
            if roster then
                local ok,why=roster:AcquireConsumer(TOKEN,{purpose="player_notes"})
                feature.rosterHeld=ok==true;feature.rosterError=ok~=true and why or nil
            end
            if S.Events then S.Events:SubscribeInternal("v3.team_roster.updated",feature,function()
                if feature.enabled and (feature.consumerCount or 0)>0 and feature.view=="team" then Refresh(feature,"team_changed") end
            end) end
        elseif b>0 and a<=0 then
            if feature.rosterHeld and Roster() then
                local ok,why=Roster():ReleaseConsumer(TOKEN);if ok~=true then return false,why end
            end
            feature.rosterHeld=false
            if S.Events then S.Events:UnsubscribeInternalOwner(feature) end
        end
        return true
    end,
    read=function(feature)
        local rows={}
        if feature.view=="friends" then
            -- 中文维护：刚收到的事件快照优先，避免弹窗再次读取旧Native缓存；无本次会话回包时手动页面沿用Getter。
            local observer=S.Services and S.Services.PlayerNotesSurfaceV3
            local list,total
            if observer and type(observer.GetFriendListSnapshot)=="function"then list,total=observer:GetFriendListSnapshot()end
            local ok,why=type(list)=="table",nil
            if not ok then total=nil;ok,list,why=Factory.Call("X2Friend:GetFriendList",rawget(_G,"X2Friend"),"GetFriendList",true)end
            if not ok or type(list)~="table"then return {},"unavailable",why or "好友名单不可读；可切换已保存备注"end
            local seen,unrecognized={},false
            for i=1,math.min(#list,200)do
                local entry=list[i]
                local name=type(entry)=="table" and (entry.name or entry.characterName or entry.memberName or entry.charName or entry[1])or entry
                name=Clean(name,MAX_NAME)
                if name and name~=""then
                    if not seen[name]then seen[name]=true;rows[#rows+1]={key=name,name=name,note=feature.State.notes[name]or "",source="好友",memberName=name}end
                else unrecognized=true end
            end
            return rows,unrecognized and "partial"or (#rows>0 and "ready"or "empty"),unrecognized and "部分好友名字无法识别"or ((total or #list)>200 and "仅显示前200名好友"or nil)
        end
        if feature.view=="team" then
            local roster=Roster();local snapshot=feature.rosterHeld and roster and roster:GetSnapshot() or {}
            for _,member in ipairs(snapshot.members or {}) do
                rows[#rows+1]={key=member.name,name=member.name,note=feature.State.notes[member.name] or "",
                    source="团队"..tostring(member.teamIndex or 1).." · "..tostring(member.memberIndex or ""),memberName=member.name}
            end
            return rows,feature.rosterHeld and (#rows>0 and "ready" or "empty") or "unavailable",feature.rosterError
        end
        for name,note in pairs(feature.State.notes) do rows[#rows+1]={key=name,name=name,note=note,source="已保存",memberName=name} end
        table.sort(rows,function(a,b)return a.name<b.name end)
        return rows,#rows>0 and "ready" or "empty"
    end,
    projection=function(feature)return {view=feature.view or "saved",noteCount=(function()local n=0;for _ in pairs(feature.State.notes)do n=n+1 end;return n end)()}end,
    commands={
        SaveNote=function(feature,name,note)return Commit(feature,name,note)end,
        DeleteNote=function(feature,name)return Commit(feature,name,"")end,
        SetView=function(feature,view)
            if view~="saved" and view~="team" and view~="friends" then return false,"未知备注视图" end
            local ok,why=Factory.Load(feature);if not ok then return false,why end
            feature.view=view;return Refresh(feature,"notes_view")
        end,
        GetTargetName=function()
            local ok,name,why=Factory.Call("X2Unit:UnitName",rawget(_G,"X2Unit"),"UnitName","target")
            name=ok and Clean(name,MAX_NAME) or nil
            if not name or name=="" then return false,why or "当前目标名字不可读" end
            return true,name
        end,
    },
})
-- 中文维护：社交页等读者仅拿标量备注；getter 不读 Native，也不订阅名单或暴露可变 Store 表。
function F:GetNote(name)
    local ok=Factory.Load(self);if not ok then return "" end
    return self.State.notes[tostring(name or "")] or ""
end
S.Features.PlayerNotes=F
