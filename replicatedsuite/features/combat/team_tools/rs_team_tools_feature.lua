------------------------------------------------------------------------
-- Replicated Suite V3 - combat_team_tools Feature Authority
--
-- Phase 1 Batch D（2026-09-28）：从 features/rs_business_bridge.lua 机械搬迁。
-- 只改变源码边界，不改业务行为：Feature ID、Store ID/Schema、UpdateTopic、Demand owner、
-- Commands、Projection shape、ApiDependencies、Scheduler task name、roster token、
-- Enable/Disable 包装语义与 AutoRoleContractVersion 全部与被搬迁前逐字一致。
--
-- Authority 边界：成员/职责事实来自 TeamRosterV3 与 X2Team 只读接口；本文件拥有“本 Feature 的
-- 角色写入与自动职责观察”，但不复制团队快照，也不为其它 Feature 保留团队缓存。
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local FSF = S.FeatureSliceFactory
if type(FSF) ~= "table" then error("FeatureSliceFactory unavailable for combat_team_tools") end
local Action, Call, Copy, Number, Text, NewFeature = FSF.Action, FSF.Call, FSF.Copy, FSF.Number, FSF.Text, FSF.NewFeature
local Trim = FSF.Trim
local PersistStateMutation = FSF.PersistStateMutation
local Demand = S.Demand
local TeamApi = rawget(_G, "X2Team")

-- 中文维护注释（2026-09-28，Phase 1 Batch D 补漏）：成员序号校验是本 Feature 专属的输入契约
-- （1..maximum 的正整数），从 bridge 原样搬入；bridge 已删除副本，避免第二份 Authority。
local function TeamCommandInteger(value, label, maximum)
    local number = Number(value)
    if number == nil or number < 1 or number > maximum or number ~= math.floor(number) then
        return nil, label .. " 必须是 1-" .. tostring(maximum) .. " 的正整数"
    end
    return math.floor(number)
end

local TEAM_ROLE_MAX_TEAMS, TEAM_ROLE_MAX_MEMBERS = 2, 50
local TEAM_ROLE_MAX_ROWS = TEAM_ROLE_MAX_TEAMS * TEAM_ROLE_MAX_MEMBERS
local TEAM_ROLE_ROSTER_TOKEN = "combat_team_tools:roster"
-- 中文维护注释（2026-09-16，Lua5.1 主 chunk local 预算）：自动职责 roster token 使用稳定字面量
-- "combat_team_tools:auto_role_roster"，不再新增顶层 local。该文件已接近 Lua 5.1 每函数 200 local 上限；
-- 资源身份仍由 Demand token 保证唯一，避免为了可读性增加顶层 local 导致整个 business bridge 无法加载。

local function TeamRosterV3()
    return S.Services and S.Services.TeamRosterV3 or nil
end

local function NormalizeTeamRoleIndex(value)
    local number = Number(value)
    if number == nil or number ~= math.floor(number) then return nil end
    return math.floor(number)
end

local function TeamRoleKeyPart(value)
    local text = Trim(value)
    if text == "" then return "-" end
    return (text:gsub("[^%w_%-]", "_"))
end

local function BuildTeamRoleKey(member, ordinal, duplicateCount)
    local teamIndex = NormalizeTeamRoleIndex(type(member) == "table" and member.teamIndex or nil)
    local memberIndex = NormalizeTeamRoleIndex(type(member) == "table" and member.memberIndex or nil)
    local token = type(member) == "table" and Trim(member.unitToken) or ""
    local name = type(member) == "table" and Trim(member.name) or ""
    local identity = TeamRoleKeyPart(token ~= "" and token or name)
    local base = string.format("team_role:%s:%s:%s", tostring(teamIndex or 0), tostring(memberIndex or 0), identity)
    if (tonumber(duplicateCount) or 0) > 0 then base = base .. ":duplicate:" .. tostring(duplicateCount) end
    if base == "team_role:0:0:-" then base = base .. ":row:" .. tostring(ordinal) end
    return base
end

local function TeamRoleDisplayName(member)
    if type(member) ~= "table" then return "无效成员" end
    local name = Trim(member.name)
    if name ~= "" then return name end
    local token = Trim(member.unitToken)
    return token ~= "" and token or "未知成员"
end

local function TeamRoleReadRow(member, ordinal, slotCounts)
    local row = type(member) == "table" and member or {}
    local teamIndex = NormalizeTeamRoleIndex(row.teamIndex)
    local memberIndex = NormalizeTeamRoleIndex(row.memberIndex)
    local unitToken = Trim(row.unitToken)
    local name = TeamRoleDisplayName(member)
    local slotKey = teamIndex ~= nil and memberIndex ~= nil and string.format("%d:%d", teamIndex, memberIndex) or nil
    local duplicateCount = 0
    if slotKey ~= nil then
        duplicateCount = tonumber(slotCounts[slotKey]) or 0
        slotCounts[slotKey] = duplicateCount + 1
    end
    local rowKey = BuildTeamRoleKey(row, ordinal, duplicateCount)
    local result = {
        key = rowKey,
        name = name,
        unitToken = unitToken,
        teamIndex = teamIndex,
        memberIndex = memberIndex,
        role = nil,
        roleStatus = "invalid_index",
        roleText = "索引无效",
        text = string.format("%s · team %s / member %s · 职责：索引无效", unitToken ~= "" and unitToken or "unitToken 未知", tostring(teamIndex or "--"), tostring(memberIndex or "--")),
        statusText = "索引无效",
        tone = "warn",
    }

    if type(member) ~= "table" then
        result.roleStatus = "invalid_member"
        result.roleText, result.statusText = "成员记录无效", "成员无效"
        result.text = result.text:gsub(" · 职责：.*$", "") .. " · 职责：" .. result.roleText
        return result, "invalid"
    end
    if teamIndex == nil or memberIndex == nil or teamIndex < 1 or teamIndex > TEAM_ROLE_MAX_TEAMS or memberIndex < 1 or memberIndex > TEAM_ROLE_MAX_MEMBERS then
        return result, "invalid"
    end

    local ok, role, err = Call("X2Team:GetRole", TeamApi, "GetRole", teamIndex, memberIndex)
    if ok ~= true then
        result.roleStatus = "read_failed"
        result.roleText, result.statusText = "读取失败", "职责读取失败"
        result.error = Text(err, "X2Team:GetRole 未返回职责")
        result.text = result.text:gsub(" · 职责：.*$", "") .. " · 职责：" .. result.roleText
        result.tone = "warn"
        return result, "failed"
    end
    if role == nil then
        result.roleStatus = "empty"
        result.roleText, result.statusText = "未返回职责", "待确认"
        result.text = result.text:gsub(" · 职责：.*$", "") .. " · 职责：" .. result.roleText
        result.tone = "warn"
        return result, "failed"
    end

    result.role = role
    result.roleText = Text(role, "已读取")
    result.statusText = "已读取"
    result.text = result.text:gsub(" · 职责：.*$", "") .. " · 职责：" .. result.roleText
    result.tone = "default"
    if duplicateCount > 0 then
        result.roleStatus = "duplicate_slot"
        result.statusText = "重复槽位"
        result.tone = "warn"
        return result, "invalid"
    end
    result.roleStatus = "ready"
    return result, "ready"
end

local function ReadTeamRoleRoster(feature)
    local roster = TeamRosterV3()
    if type(roster) ~= "table" or type(roster.GetSnapshot) ~= "function" then
        feature.TeamRoleScan = { rosterRevision = 0, total = 0, ready = 0, failed = 0, invalid = 0, truncated = false, diagnostic = "TeamRosterV3 快照不可用" }
        return { { key = "team_role:unavailable", name = "当前团队职责", text = "TeamRosterV3 快照不可用", statusText = "不可用", tone = "warn", roleStatus = "roster_unavailable" } }, "unavailable", "TeamRosterV3:GetSnapshot 不可用"
    end

    local snapshot = roster:GetSnapshot()
    if type(snapshot) ~= "table" then
        feature.TeamRoleScan = { rosterRevision = 0, total = 0, ready = 0, failed = 0, invalid = 0, truncated = false, diagnostic = "团队名单快照返回无效" }
        return { { key = "team_role:unavailable", name = "当前团队职责", text = "团队名单快照返回无效", statusText = "不可用", tone = "warn", roleStatus = "roster_invalid" } }, "unavailable", "TeamRosterV3:GetSnapshot 返回无效值"
    end

    local members = snapshot.members
    if type(members) ~= "table" then members = {} end
    local rows, slotCounts = {}, {}
    local ready, failed, invalid = 0, 0, 0
    local limit = math.min(#members, TEAM_ROLE_MAX_ROWS)
    for ordinal = 1, limit do
        local row, result = TeamRoleReadRow(members[ordinal], ordinal, slotCounts)
        rows[#rows + 1] = row
        if result == "ready" then ready = ready + 1
        elseif result == "failed" then failed = failed + 1
        else invalid = invalid + 1 end
    end
    local truncated = #members > TEAM_ROLE_MAX_ROWS
    if truncated then
        rows[#rows + 1] = { key = "team_role:truncated", name = "当前团队职责", text = string.format("名单超过上限 %d，已截断", TEAM_ROLE_MAX_ROWS), statusText = "已截断", roleStatus = "truncated", tone = "warn" }
    end

    local rosterRevision = tonumber(snapshot.revision) or 0
    local total = #members
    if total == 0 then
        local diagnostic = "当前团队为空"
        feature.TeamRoleScan = { rosterRevision = rosterRevision, total = 0, ready = 0, failed = 0, invalid = 0, truncated = false, empty = true, diagnostic = diagnostic }
        return { { key = "team_role:empty", name = "当前团队职责", text = diagnostic, statusText = "空团队", roleStatus = "empty_team", tone = "muted" } }, "empty", diagnostic
    end

    local diagnosticParts = {}
    if failed > 0 then diagnosticParts[#diagnosticParts + 1] = "职责读取失败 " .. tostring(failed) end
    if invalid > 0 then diagnosticParts[#diagnosticParts + 1] = "无效/重复槽位 " .. tostring(invalid) end
    if truncated then diagnosticParts[#diagnosticParts + 1] = "名单已按 " .. tostring(TEAM_ROLE_MAX_ROWS) .. " 条截断" end
    local diagnostic = #diagnosticParts > 0 and table.concat(diagnosticParts, "；") or nil
    feature.TeamRoleScan = { rosterRevision = rosterRevision, total = total, returned = limit, ready = ready, failed = failed, invalid = invalid, truncated = truncated, diagnostic = diagnostic }
    if diagnostic ~= nil then return rows, "partial", diagnostic end
    return rows, "ready", nil
end

local function SubscribeTeamRoleRoster(feature)
    if feature.TeamRoleRosterSubscribed == true then return true end
    if S.Events == nil or type(S.Events.SubscribeInternal) ~= "function" then return false, "团队名单内部事件总线不可用" end
    local subscribed = S.Events:SubscribeInternal("v3.team_roster.updated", feature, function(_, revision, reason)
        if feature.enabled == true and (tonumber(feature.consumerCount) or 0) > 0 then
            return feature.Authority:Refresh("team_roster_updated:" .. tostring(reason or revision or "update"))
        end
    end)
    if subscribed ~= true then return false, "团队名单更新订阅失败" end
    feature.TeamRoleRosterSubscribed = true
    return true
end

local function UnsubscribeTeamRoleRoster(feature)
    if feature.TeamRoleRosterSubscribed == true and S.Events ~= nil and type(S.Events.UnsubscribeInternal) == "function" then
        S.Events:UnsubscribeInternal("v3.team_roster.updated", feature)
    end
    feature.TeamRoleRosterSubscribed = false
    return true
end

local function AcquireTeamRoleRoster(feature, before, after)
    local beforeCount = tonumber(before and before.count) or 0
    local afterCount = tonumber(after and after.count) or 0
    if beforeCount <= 0 and afterCount > 0 then
        local roster = TeamRosterV3()
        if type(roster) ~= "table" or type(roster.AcquireConsumer) ~= "function" then return false, "团队名单服务不可用" end
        local ok, err = roster:AcquireConsumer(TEAM_ROLE_ROSTER_TOKEN, { purpose = "combat_team_tools_roles" })
        if ok ~= true then return false, err or "团队名单服务获取失败" end
        feature.TeamRoleRosterHeld = true
        local subscribed, subscribeErr = SubscribeTeamRoleRoster(feature)
        if subscribed ~= true then
            if type(roster.ReleaseConsumer) == "function" then pcall(roster.ReleaseConsumer, roster, TEAM_ROLE_ROSTER_TOKEN) end
            feature.TeamRoleRosterHeld = false
            UnsubscribeTeamRoleRoster(feature)
            return false, subscribeErr
        end
    elseif beforeCount > 0 and afterCount <= 0 then
        if feature.TeamRoleRosterHeld == true then
            local roster = TeamRosterV3()
            if type(roster) ~= "table" or type(roster.ReleaseConsumer) ~= "function" then return false, "团队名单服务释放不可用" end
            local ok, err = roster:ReleaseConsumer(TEAM_ROLE_ROSTER_TOKEN)
            if ok ~= true then return false, err or "团队名单服务释放失败" end
            feature.TeamRoleRosterHeld = false
        end
        UnsubscribeTeamRoleRoster(feature)
    end
    return true
end

local function ReleaseTeamRoleRoster(feature)
    if feature.TeamRoleRosterHeld == true then
        local roster = TeamRosterV3()
        if type(roster) ~= "table" or type(roster.ReleaseConsumer) ~= "function" then return false, "团队名单服务释放不可用" end
        local ok, err = roster:ReleaseConsumer(TEAM_ROLE_ROSTER_TOKEN)
        if ok ~= true then return false, err or "团队名单服务释放失败" end
        feature.TeamRoleRosterHeld = false
    end
    UnsubscribeTeamRoleRoster(feature)
    return true
end

local function TeamRoleValues()
    local rows, seen = {}, {}
    for _, spec in ipairs({
        { key = "none", global = "TMROLE_NONE", label = "未标记" },
        { key = "tank", global = "TMROLE_TANKER", label = "坦克" },
        { key = "healer", global = "TMROLE_HEALER", label = "治疗" },
        { key = "dealer", global = "TMROLE_DEALER", label = "输出" },
        { key = "ranged", global = "TMROLE_RANGED_DEALER", label = "远程输出" },
    }) do
        local value = Number(rawget(_G, spec.global))
        if value ~= nil and not seen[value] then seen[value] = true; rows[#rows + 1] = { key = spec.key, value = value, text = spec.label } end
    end
    return rows
end
local function NormalizeTeamRole(value)
    local number = Number(value)
    for _, row in ipairs(TeamRoleValues()) do if row.value == number then return row.value end end
    return nil
end

local TeamTools = NewFeature("combat_team_tools", { apiDependencies = { "X2Team:GetRole", "X2Team:SetRole", "X2Unit:GetTargetAbilityTemplates", "X2Unit:UnitName" },
    -- 中文维护注释（2026-09-10，自动职责默认开启）：autoRoleEnabled 早已属于 default，因此 NewFeature 的持久化白名单事实上会保存它；这里把它同时写入 explicit persistentKeys，目的是把“新安装默认 true、旧用户显式 false 必须保留”变成可读且可测试的 Store 契约。Authority 仍是 TeamTools.State，UI 只通过 SetAutoRoleEnabled -> PersistStateMutation 修改；不会在 Reload/Enable 时强制把旧 false 改 true，也不会增加新的轮询任务。
    state = { role = nil, autoRoleEnabled = true }, default = { role = nil, autoRoleEnabled = true }, persistentKeys = { "role", "autoRoleEnabled" },
    reconcileDemand = AcquireTeamRoleRoster,
    onDisable = ReleaseTeamRoleRoster,
    projection = function(feature)
        local scan = feature.TeamRoleScan or {}
        return { teamRoleScan = Copy(scan), rosterRevision = tonumber(scan.rosterRevision) or 0, roleOptions = TeamRoleValues(), memberMoveAvailable = false,
            autoRoleEnabled = feature.State.autoRoleEnabled ~= false, autoRoleStatus = tostring(feature.AutoRoleStatus or "等待团队/职业变化"),
            autoRoleClassKey = feature.AutoRoleClassKey, autoRoleLabel = feature.AutoRoleLabel }
    end,
    read = ReadTeamRoleRoster,
    commands = {
        SetAutoRoleEnabled = function(feature, value)
            local enabled = value == true
            local ok, err = PersistStateMutation(feature, "team_auto_role", function(state) state.autoRoleEnabled = enabled; return true end)
            if ok ~= true then return false, err end
            -- 中文维护注释（2026-09-16，自动职责生命周期）：旧实现只改 Store，false 时不释放观察，且若 Feature 启动时 Store=false，
            -- 后续切回 true 只 Schedule 一次 Apply，并不会重新订阅 ABILITY/roster 事件。Authority 仍是 TeamTools.State，Command 负责把用户意图同步到运行时资源。
            -- 数据流：SetAutoRoleEnabled -> Start/StopAutoRoleObservation -> 独立 TeamRoster lease + 独立 Event owner；Presentation 不直接订阅 Native。
            -- 兼容边界：先提交用户配置，再调整本会话资源；若运行时资源建立失败，保留用户 true 意图并返回错误，下一次 Enable/重载仍会重试，不静默改回 false。
            if feature.enabled == true then
                if enabled then
                    local started, startErr = feature:StartAutoRoleObservation()
                    if started ~= true then feature.AutoRoleStatus = "自动职责启动失败：" .. tostring(startErr or "unknown"); return false, startErr end
                else
                    local stopped, stopErr = feature:StopAutoRoleObservation()
                    if stopped ~= true then feature.AutoRoleStatus = "自动职责停止不完整：" .. tostring(stopErr or "unknown"); return false, stopErr end
                    feature.AutoRoleStatus = "自动职责已关闭"
                end
            end
            return true
        end,
        SetRole = function(_, role)
            local value = NormalizeTeamRole(role)
            if value == nil then return false, "职责必须来自当前客户端 TMROLE_* 枚举" end
            return Action("X2Team:SetRole", TeamApi, "SetRole", value)
        end,
        MoveMember = function(_, from, to)
            local fromMember, err = TeamCommandInteger(from, "源成员", 50); if fromMember == nil then return false, err end
            local toMember; toMember, err = TeamCommandInteger(to, "目标成员", 50); if toMember == nil then return false, err end
            return false, "成员移动已安全停用：当前 RU 没有允许使用的队长/权限 getter，不能证明写操作权限"
        end,
        MoveMemberToParty = function(_, fromMember, toParty)
            local value, err = TeamCommandInteger(fromMember, "成员", 50); if value == nil then return false, err end
            toParty, err = TeamCommandInteger(toParty, "小队", 50); if toParty == nil then return false, err end
            return false, "成员移入小队已安全停用：当前 RU 没有允许使用的队长/权限 getter，不能证明写操作权限"
        end,
    },
})
TeamTools.TeamRoleRosterHeld = false
TeamTools.TeamRoleRosterSubscribed = false
TeamTools.TeamRoleContractVersion = 2
TeamTools.AutoRoleCatalogContractVersion = 2 -- 中文维护注释（2026-09-16）：v2 增加 8+9+14=治疗 与 6+8+9=远程的双规则验收；目录仍是精确 class-key Authority。
TeamTools.AutoRoleDefaultOnContractVersion = 1 -- 中文维护注释：发布门禁钉死“空 Store 默认开 + 旧显式关可持久化”的产品语义；它不代表功能无条件常驻，Feature Disabled 时观察任务仍全部释放。
TeamTools.AutoRoleRosterLeaseContractVersion = 1 -- 中文维护注释（2026-09-16）：自动职责开启时必须独立持有 TeamRosterV3，不能借页面/Healer 的 Consumer“碰巧运行”。
TeamTools.AutoRoleRosterHeld = false
TeamTools.AutoRoleSubscribed = false
TeamTools.AutoRoleEventOwner = { Id = "combat_team_tools:auto_role_observer" } -- 中文维护注释：事件 owner 与 Feature 本体分离；StopAutoRoleObservation 只回收自己的 Native/Internal 订阅，不能误删职责页面的 v3.team_roster.updated 订阅。

local TEAM_AUTO_ROLE_TASK="v3_team_auto_role_apply"
local function TeamAutoRoleCatalog() return S.Data and S.Data.TeamAutoRoleCatalog or nil end
local function ResolveAutoRole(feature)
    local ok,templates,err=Call("X2Unit:GetTargetAbilityTemplates",rawget(_G,"X2Unit"),"GetTargetAbilityTemplates","player")
    if ok~=true or type(templates)~="table" then return nil,nil,nil,"职业树不可读："..tostring(err or "unknown") end
    local indices={}
    for i=1,3 do local n=tonumber(type(templates[i])=="table" and templates[i].index or nil); if n==nil then return nil,nil,nil,"职业树返回不完整" end; indices[#indices+1]=math.floor(n) end
    table.sort(indices)
    local key=string.format("name_%d_%d_%d",indices[1],indices[2],indices[3])
    local catalog=TeamAutoRoleCatalog(); local row=type(catalog)=="table" and type(catalog.byClassKey)=="table" and catalog.byClassKey[key] or nil
    if type(row)~="table" then return NormalizeTeamRole(rawget(_G,"TMROLE_NONE")),key,"未标记","职业组合尚未登记" end
    local globalByRole={tank="TMROLE_TANKER",healer="TMROLE_HEALER",dealer="TMROLE_DEALER",ranged="TMROLE_RANGED_DEALER",none="TMROLE_NONE"}
    local role=NormalizeTeamRole(rawget(_G,globalByRole[row.role] or "TMROLE_NONE"))
    return role,key,({tank="坦克",healer="治疗",dealer="输出",ranged="远程输出",none="未标记"})[row.role] or "未标记",nil
end
local function FindPlayerRoleSlot()
    local roster=TeamRosterV3(); if type(roster)~="table" or type(roster.GetSnapshot)~="function" then return nil,nil,"团队名单不可用" end
    local ok,name,err=Call("X2Unit:UnitName",rawget(_G,"X2Unit"),"UnitName","player")
    name=ok==true and tostring(name or "") or ""; if name=="" then return nil,nil,"当前玩家名称不可读："..tostring(err or "unknown") end
    local wanted=string.lower(name)
    local snap=roster:GetSnapshot()
    for _,member in ipairs(type(snap)=="table" and type(snap.members)=="table" and snap.members or {}) do
        local memberName=string.lower(tostring(member.name or ""))
        if memberName==wanted then
            local teamIndex,memberIndex=tonumber(member.teamIndex),tonumber(member.memberIndex)
            -- 中文维护注释（2026-09-16，入团竞态）：TeamRosterV3 总会先以 player/0/0 种下本地身份，0/0 只证明“玩家存在”，
            -- 不能证明 native team slot 已稳定。旧代码把 0/0 当有效槽位，可能在 TEAM_MEMBERS_CHANGED 过早到达时调用 GetRole(0,0)/SetRole，
            -- RU 侧拒绝后又没有后续边沿，于是表现为“有时进团不改职责”。这里只接受 >0 的真实团队槽位；晚到槽位由 TeamRoster 的有界 settle refresh 补齐。
            -- 数据流仍只消费 TeamRosterV3 公共 Snapshot，不读取其私有 map；大小写归一化只用于当前玩家同名匹配，不建立第二份缓存。
            if teamIndex~=nil and teamIndex>0 and memberIndex~=nil and memberIndex>0 then return teamIndex,memberIndex,nil end
            return nil,nil,"当前玩家团队槽位尚未就绪"
        end
    end
    return nil,nil,"当前玩家尚未进入团队名单"
end
function TeamTools:ApplyAutoRole(reason)
    if self.enabled~=true or self.State.autoRoleEnabled==false then self.AutoRoleStatus="自动职责已关闭"; return true end
    local desired,classKey,label,resolveErr=ResolveAutoRole(self)
    self.AutoRoleClassKey,self.AutoRoleLabel=classKey,label
    if desired==nil then self.AutoRoleStatus=resolveErr or "无法识别职责"; return false,self.AutoRoleStatus end
    local teamIndex,memberIndex,slotErr=FindPlayerRoleSlot()
    if teamIndex==nil or memberIndex==nil then self.AutoRoleStatus=slotErr or "未在团队"; return true end
    local ok,current,currentErr=Call("X2Team:GetRole",TeamApi,"GetRole",teamIndex,memberIndex)
    if ok==true and tonumber(current)==tonumber(desired) then self.AutoRoleStatus="已匹配："..tostring(label); return true end
    local wrote,writeErr=Action("X2Team:SetRole",TeamApi,"SetRole",desired)
    if wrote~=true then self.AutoRoleStatus="设置失败："..tostring(writeErr or currentErr or "unknown"); return false,writeErr end
    self.AutoRoleStatus="已请求："..tostring(label).."（等待团队同步）"
    return true
end
function TeamTools:ScheduleAutoRole(reason,delayMs)
    if self.enabled~=true or self.State.autoRoleEnabled==false then return true end
    if S.Scheduler==nil or type(S.Scheduler.AddOneShot)~="function" then return false,"自动职责 Scheduler 不可用" end
    S.Scheduler:RemoveTask(TEAM_AUTO_ROLE_TASK)
    local ok=S.Scheduler:AddOneShot(TEAM_AUTO_ROLE_TASK,math.max(100,tonumber(delayMs) or 180),function() return TeamTools:ApplyAutoRole(reason) end,self,"P2",1)
    if ok==true and type(S.Scheduler.SetTaskModule)=="function" then S.Scheduler:SetTaskModule(TEAM_AUTO_ROLE_TASK,self.Id,true) end
    return ok==true,ok==true and nil or "自动职责任务创建失败"
end
function TeamTools:AcquireAutoRoleRoster()
    if self.AutoRoleRosterHeld == true then return true end
    local roster = TeamRosterV3()
    if type(roster) ~= "table" or type(roster.AcquireConsumer) ~= "function" then return false, "自动职责团队名单服务不可用" end
    local ok, err = roster:AcquireConsumer("combat_team_tools:auto_role_roster", { purpose = "combat_team_tools_auto_role" })
    if ok ~= true then return false, err or "自动职责团队名单获取失败" end
    self.AutoRoleRosterHeld = true
    return true
end

function TeamTools:ReleaseAutoRoleRoster()
    if self.AutoRoleRosterHeld ~= true then return true end
    local roster = TeamRosterV3()
    if type(roster) ~= "table" or type(roster.ReleaseConsumer) ~= "function" then return false, "自动职责团队名单释放不可用" end
    local ok, err = roster:ReleaseConsumer("combat_team_tools:auto_role_roster")
    if ok ~= true then return false, err or "自动职责团队名单释放失败" end
    self.AutoRoleRosterHeld = false
    return true
end

function TeamTools:StartAutoRoleObservation()
    if self.AutoRoleSubscribed==true and self.AutoRoleRosterHeld==true then return true end
    if S.Events==nil then return false,"自动职责事件总线不可用" end
    local rosterOk, rosterErr = self:AcquireAutoRoleRoster()
    if rosterOk ~= true then return false, rosterErr end
    local owner = self.AutoRoleEventOwner
    -- 中文维护注释（2026-09-16，独立观察所有权）：自动职责不能借 combat_team_tools 页面 Demand 持有 TeamRoster，也不能用 Feature 本体
    -- 作为 Event owner 后再 UnsubscribeOwner(self)，否则关闭自动职责会顺带删除页面只读职责订阅。这里把 Native ability 事件和内部 roster 事件都绑定到专属 owner。
    -- 生命周期：Feature Enabled + autoRoleEnabled=true 才持有；关闭设置/Feature Disable 时 RemoveTask + Unsubscribe + ReleaseConsumer 全部释放。无 Tick、无常驻扫描。
    S.Events:BindOwner(owner,self.Id)
    local ok1=S.Events:SubscribeOptional("ABILITY_SET_CHANGED",owner,function() TeamTools:ScheduleAutoRole("ability_set",150) end)
    local ok2=S.Events:SubscribeOptional("ABILITY_CHANGED",owner,function() TeamTools:ScheduleAutoRole("ability",150) end)
    local ok3=type(S.Events.SubscribeInternal)=="function" and S.Events:SubscribeInternal("v3.team_roster.updated",owner,function() TeamTools:ScheduleAutoRole("team_roster",250) end) or false
    if ok1~=true or ok2~=true or ok3~=true then
        if type(S.Events.UnsubscribeOwner)=="function" then S.Events:UnsubscribeOwner(owner) end
        if type(S.Events.UnsubscribeInternalOwner)=="function" then S.Events:UnsubscribeInternalOwner(owner) end
        self:ReleaseAutoRoleRoster()
        self.AutoRoleSubscribed=false
        return false,"自动职责事件订阅失败"
    end
    self.AutoRoleSubscribed=true
    local scheduled, scheduleErr = self:ScheduleAutoRole("enable",300)
    if scheduled ~= true then
        if type(S.Events.UnsubscribeOwner)=="function" then S.Events:UnsubscribeOwner(owner) end
        if type(S.Events.UnsubscribeInternalOwner)=="function" then S.Events:UnsubscribeInternalOwner(owner) end
        self:ReleaseAutoRoleRoster()
        self.AutoRoleSubscribed=false
        return false, scheduleErr or "自动职责任务启动失败"
    end
    return true
end
function TeamTools:StopAutoRoleObservation()
    if S.Scheduler and type(S.Scheduler.RemoveTask)=="function" then S.Scheduler:RemoveTask(TEAM_AUTO_ROLE_TASK) end
    local owner = self.AutoRoleEventOwner
    if S.Events then
        if type(S.Events.UnsubscribeOwner)=="function" then S.Events:UnsubscribeOwner(owner) end
        if type(S.Events.UnsubscribeInternalOwner)=="function" then S.Events:UnsubscribeInternalOwner(owner) end
    end
    self.AutoRoleSubscribed=false
    local released, releaseErr = self:ReleaseAutoRoleRoster()
    if released ~= true then return false, releaseErr end
    return true
end
local TeamToolsBaseEnable,TeamToolsBaseDisable=TeamTools.Enable,TeamTools.Disable
function TeamTools:Enable(reason)
    local ok,err=TeamToolsBaseEnable(self,reason); if ok~=true then return false,err end
    if self.State.autoRoleEnabled~=false then local obs,obsErr=self:StartAutoRoleObservation(); if obs~=true then TeamToolsBaseDisable(self,"auto_role_start_rollback"); return false,obsErr end end
    return true
end
function TeamTools:Disable(reason)
    local stopOk, stopErr = self:StopAutoRoleObservation()
    local baseOk, baseErr = TeamToolsBaseDisable(self,reason)
    if baseOk ~= true then return false, baseErr end
    if stopOk ~= true then return false, stopErr end
    return true
end
TeamTools.AutoRoleContractVersion=3 -- 中文维护注释（2026-09-16）：v3 固化独立 TeamRoster lease、独立 Event owner、关→开重建观察与真实>0团队槽位门；仍为事件驱动，不增加周期轮询。
