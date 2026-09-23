------------------------------------------------------------------------
-- Replicated Suite V3 - Hotkey Profiles Feature
------------------------------------------------------------------------
-- 中文维护总约束（2026-09-23，hotkey-profile-v2）：
-- 1) 问题原因：用户需要把常用快捷键方案跨角色复用，但 RU API 没有完整 action registry；
--    v1 因此只覆盖已由 FishingHotkeyV3 实机使用的 mode_action_bar_button 1..12。
-- 2) Authority：本 Feature 独占“账号级快捷键方案 + 显式应用/恢复事务”；Native 当前键位始终由
--    X2Hotkey 权威读取。Fishing Auto-R 的临时 R 迁移继续由 FishingHotkeyV3 独占，检测到其事务
--    活动时本 Feature fail-closed，禁止两个写 Authority 同时操作 X2Hotkey。
-- 3) v2 白名单：主动作栏仍为 Suite 已验证组；team_target(1..4) 与 over_head_marker(1..3)
--    只有在当前客户端通过 IsValidActionName + IsOverridableAction 双验证后才允许保存/应用。
--    这两个 arg 范围来自历史 binding.g 公开格式，但历史资料本身绝不能绕过当前 RU Runtime 验证。
-- 4) 数据流：Save=显式探测白名单 -> 读取各组 -> durable Account Store；Apply=按方案包含组再次预检
--    -> 读取当前同组 -> durable recovery -> 非战斗逐项写 -> 单次 SaveHotKey -> 全组 readback。
--    任一写/读回失败均使用 recovery 回滚；只有精确恢复成功才允许清除恢复记录。
-- 5) 跨角色：方案是 Account scope；pendingRecovery 绑定 UnitNameWithWorld，仅原角色可恢复，防止切角色
--    后把 A 角色的原键位覆盖到 B。v1 Store 自动迁移为 v2 groups.main，旧方案不丢失。
-- 6) 性能：无 Tick/无 Scheduler/无事件扫描；Runtime action 探测与 Native I/O 只发生在用户点击保存、
--    应用、恢复时。禁止为了“找更多快捷键”循环猜 action 名或扩大未知 arg 范围。
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local P, Runtime, Demand = S.Persistence, S.FeatureRuntime, S.Demand
if type(P) ~= "table" or type(Runtime) ~= "table" or type(Demand) ~= "table" then return end
S.Features = S.Features or {}

local F = {
    Id = "tools_hotkey_profiles",
    storeId = "v3.business.tools_hotkey_profiles",
    enabled = false,
    storeLoaded = false,
    consumerCount = 0,
    State = { profiles = {}, nextId = 1, selectedId = nil, pendingRecovery = nil },
    Authority = { version = 2, revision = 0, rows = {}, status = "idle", error = nil, lastOperation = nil },
    ProfileContractVersion = 2,
    ActionWhitelistVersion = 2,
    ApiDependencies = {
        "X2Hotkey:GetOptionBinding", "X2Hotkey:IsValidActionName", "X2Hotkey:IsOverridableAction",
        "X2Hotkey:BindingToOption", "X2Hotkey:SetOptionBindingWithIndex",
        "X2Hotkey:RemoveOptionBinding", "X2Hotkey:SaveHotKey", "X2Player:PlayerInCombat", "X2Unit:UnitNameWithWorld",
    },
}
S.Features[F.Id] = F
F.UpdateTopic = "v3.business.tools_hotkey_profiles.updated"

local PROFILE_MAX = 8
local READ_OPTIONS = { false, true, 0, 1 }
local GROUP_ORDER = { "main", "teamTarget", "overHeadMarker" }
local GROUPS = {
    main = {
        id = "main", label = "主动作栏", action = "mode_action_bar_button", index = 1, slotMax = 12,
        suiteVerified = true,
    },
    teamTarget = {
        id = "teamTarget", label = "队伍目标", action = "team_target", index = 1, slotMax = 4,
        requireRuntimeValidation = true,
    },
    overHeadMarker = {
        id = "overHeadMarker", label = "头顶标记", action = "over_head_marker", index = 1, slotMax = 3,
        requireRuntimeValidation = true,
    },
}

local function Copy(value)
    if S.Utils and type(S.Utils.DeepCopy) == "function" then return S.Utils.DeepCopy(value) end
    if type(value) ~= "table" then return value end
    local out = {}; for k, v in pairs(value) do out[Copy(k)] = Copy(v) end; return out
end
local function Call(capability, hostName, method, ...)
    if S.Api == nil or type(S.Api.CallCapability) ~= "function" then return false, nil, "API boundary unavailable" end
    return S.Api:CallCapability(capability, rawget(_G, hostName), method, ...)
end
local function Action(capability, hostName, method, ...)
    if S.Api == nil or type(S.Api.ActionCapability) ~= "function" then return false, "API boundary unavailable" end
    return S.Api:ActionCapability(capability, rawget(_G, hostName), method, ...)
end
local function Normalize(value)
    if type(value) == "table" then
        for _, key in ipairs({ "key", "binding", "text", "value", "name" }) do
            if type(value[key]) == "string" or type(value[key]) == "number" then value = value[key]; break end
        end
    end
    if type(value) ~= "string" and type(value) ~= "number" then return nil end
    local text = tostring(value):gsub("^%s+", ""):gsub("%s+$", "")
    return text ~= "" and text or nil
end
local function NativeTrue(value)
    if value == true then return true end
    local number = tonumber(value)
    return number ~= nil and number == 1
end
local function SlotValue(slots, slot)
    if type(slots) ~= "table" then return false end
    local value = slots[slot]; if value == nil then value = slots[tostring(slot)] end
    return value == nil and false or value
end
local function IsAllowed(name)
    return S.Api ~= nil and type(S.Api.IsCapabilityAllowed) == "function" and S.Api:IsCapabilityAllowed(name) == true
end
local function InCombat()
    if not IsAllowed("X2Player:PlayerInCombat") then return true end
    local ok, value = Call("X2Player:PlayerInCombat", "X2Player", "PlayerInCombat")
    return ok ~= true or value == nil or value == true or tonumber(value) == 1
end
local function FishingConflict()
    local fishing = S.Services and S.Services.FishingHotkeyV3 or nil
    return type(fishing) == "table" and (fishing.sessionSnapshot ~= nil or fishing.pendingRecovery == true or fishing.currentSlot ~= nil)
end
local function Owner()
    if not IsAllowed("X2Unit:UnitNameWithWorld") then return nil end
    local ok, value = Call("X2Unit:UnitNameWithWorld", "X2Unit", "UnitNameWithWorld", "player")
    return ok == true and Normalize(value) or nil
end
local function DescribeGroups(groups)
    local parts, total = {}, 0
    for _, groupId in ipairs(GROUP_ORDER) do
        local def, group = GROUPS[groupId], type(groups) == "table" and groups[groupId] or nil
        if type(group) == "table" and type(group.slots) == "table" then
            local bound = 0
            for slot = 1, def.slotMax do if SlotValue(group.slots, slot) ~= false then bound = bound + 1 end end
            parts[#parts + 1] = def.label .. " " .. tostring(bound) .. "/" .. tostring(def.slotMax)
            total = total + def.slotMax
        end
    end
    return #parts > 0 and table.concat(parts, " · ") or "无有效键位组", total
end

local function ValidateAction(def)
    if type(def) ~= "table" then return false, "快捷键组定义缺失" end
    if def.suiteVerified == true then return true end
    if def.requireRuntimeValidation ~= true then return false, "未定义安全验证策略" end
    if not IsAllowed("X2Hotkey:IsValidActionName") or not IsAllowed("X2Hotkey:IsOverridableAction") then
        return false, "当前客户端缺少 action 安全验证能力"
    end
    local ok, valid, err = Call("X2Hotkey:IsValidActionName", "X2Hotkey", "IsValidActionName", def.action)
    if ok ~= true then return false, tostring(err or "IsValidActionName 调用失败") end
    if NativeTrue(valid) ~= true then return false, def.action .. " 不是当前客户端有效 action" end
    ok, valid, err = Call("X2Hotkey:IsOverridableAction", "X2Hotkey", "IsOverridableAction", def.action)
    if ok ~= true then return false, tostring(err or "IsOverridableAction 调用失败") end
    if NativeTrue(valid) ~= true then return false, def.action .. " 当前不可覆盖" end
    return true
end

local function ReadGroupSlot(def, slot)
    local anyCall = false
    for _, option in ipairs(READ_OPTIONS) do
        local ok, value = Call("X2Hotkey:GetOptionBinding", "X2Hotkey", "GetOptionBinding", def.action, def.index, option, slot)
        if ok == true then
            anyCall = true
            local binding = Normalize(value)
            if binding ~= nil then return true, binding end
        end
    end
    if anyCall then return true, nil end
    return false, nil, def.label .. "槽位 " .. tostring(slot) .. " 读取失败"
end

local function CaptureGroup(def)
    local safe, safeErr = ValidateAction(def)
    if safe ~= true then return nil, safeErr end
    local slots = {}
    for slot = 1, def.slotMax do
        local ok, binding, err = ReadGroupSlot(def, slot)
        if ok ~= true then return nil, err end
        slots[slot] = binding == nil and false or binding -- false 明确表示“未绑定”，避免 nil 经 SaveData 序列化后丢槽。
    end
    return { action = def.action, index = def.index, slotMax = def.slotMax, slots = slots }
end

local function CaptureForSave()
    -- 中文维护注释：main 是当前项目已验证的强制组；扩展组必须 Runtime 双验证成功才加入。
    -- 扩展组不可用时保存仍可成功，但绝不能以“全空组”写入 Store，否则跨角色应用会误清合法键位。
    local groups, skipped = {}, {}
    local main, err = CaptureGroup(GROUPS.main)
    if main == nil then return nil, nil, err end
    groups.main = main
    for _, groupId in ipairs({ "teamTarget", "overHeadMarker" }) do
        local def = GROUPS[groupId]
        local group, groupErr = CaptureGroup(def)
        if group ~= nil then groups[groupId] = group
        else skipped[#skipped + 1] = def.label .. "（" .. tostring(groupErr or "不可用") .. "）" end
    end
    return groups, skipped
end

local function CaptureMatching(groups)
    local out = {}
    for _, groupId in ipairs(GROUP_ORDER) do
        if type(groups) == "table" and type(groups[groupId]) == "table" then
            local def = GROUPS[groupId]
            local current, err = CaptureGroup(def)
            if current == nil then return nil, err end
            out[groupId] = current
        end
    end
    return out
end

local function SetGroupSlot(def, slot, binding)
    if binding == false or binding == nil then
        return Action("X2Hotkey:RemoveOptionBinding", "X2Hotkey", "RemoveOptionBinding", def.action, def.index, slot)
    end
    return Action("X2Hotkey:SetOptionBindingWithIndex", "X2Hotkey", "SetOptionBindingWithIndex", def.action, tostring(binding), def.index, slot)
end

local function VerifyGroups(groups)
    for _, groupId in ipairs(GROUP_ORDER) do
        local group = type(groups) == "table" and groups[groupId] or nil
        if type(group) == "table" and type(group.slots) == "table" then
            local def = GROUPS[groupId]
            for slot = 1, def.slotMax do
                local ok, actual, err = ReadGroupSlot(def, slot); if ok ~= true then return false, err end
                local expected = SlotValue(group.slots, slot); expected = expected == false and nil or Normalize(expected); actual = Normalize(actual)
                if expected ~= actual then
                    return false, def.label .. "槽位 " .. tostring(slot) .. " 读回不一致：期望=" .. tostring(expected or "空") .. "，实际=" .. tostring(actual or "空")
                end
            end
        end
    end
    return true
end

local function PreflightGroups(groups)
    local count = 0
    for _, groupId in ipairs(GROUP_ORDER) do
        local group = type(groups) == "table" and groups[groupId] or nil
        if type(group) == "table" and type(group.slots) == "table" then
            local def = GROUPS[groupId]
            local safe, err = ValidateAction(def)
            if safe ~= true then return false, def.label .. "预检失败：" .. tostring(err) end
            count = count + 1
        end
    end
    if count <= 0 then return false, "方案没有可应用的快捷键组" end
    return true
end

local function WriteGroups(groups)
    if InCombat() then return false, "战斗中不能修改快捷键" end
    if FishingConflict() then return false, "钓鱼 Auto-R 正在占用快捷键事务，请先关闭 Auto-R" end
    local ready, readyErr = PreflightGroups(groups)
    if ready ~= true then return false, readyErr end
    local ok, err = Action("X2Hotkey:BindingToOption", "X2Hotkey", "BindingToOption")
    if ok ~= true then return false, err or "无法进入快捷键编辑状态" end
    for _, groupId in ipairs(GROUP_ORDER) do
        local group = type(groups) == "table" and groups[groupId] or nil
        if type(group) == "table" and type(group.slots) == "table" then
            local def = GROUPS[groupId]
            for slot = 1, def.slotMax do
                ok, err = SetGroupSlot(def, slot, SlotValue(group.slots, slot))
                if ok ~= true then return false, def.label .. "槽位 " .. tostring(slot) .. " 写入失败：" .. tostring(err or "unknown") end
            end
        end
    end
    ok, err = Action("X2Hotkey:SaveHotKey", "X2Hotkey", "SaveHotKey")
    if ok ~= true then return false, err or "SaveHotKey 失败" end
    return VerifyGroups(groups)
end

local function NormalizeGroup(groupId, value)
    local def = GROUPS[groupId]
    if def == nil or type(value) ~= "table" then return nil end
    local sourceSlots = type(value.slots) == "table" and value.slots or value
    local slots = {}
    for slot = 1, def.slotMax do slots[slot] = SlotValue(sourceSlots, slot) end
    return { action = def.action, index = def.index, slotMax = def.slotMax, slots = slots }
end

local function NormalizeProfile(profile)
    if type(profile) ~= "table" then return nil end
    local id = tonumber(profile.id); if id == nil then return nil end
    local groups = {}
    if type(profile.groups) == "table" then
        for _, groupId in ipairs(GROUP_ORDER) do
            local group = NormalizeGroup(groupId, profile.groups[groupId])
            if group ~= nil then groups[groupId] = group end
        end
    elseif type(profile.slots) == "table" then
        -- 中文维护注释：v1 profile 只有 slots；迁移时只映射 main，绝不凭新版白名单给旧方案补空扩展组。
        groups.main = NormalizeGroup("main", profile.slots)
    end
    if groups.main == nil and groups.teamTarget == nil and groups.overHeadMarker == nil then return nil end
    return { id = math.floor(id), name = tostring(profile.name or ("方案 " .. tostring(math.floor(id)))), contractVersion = 2, groups = groups }
end

local function NormalizeRecovery(value)
    if type(value) ~= "table" then return nil end
    local groups = {}
    if type(value.groups) == "table" then
        for _, groupId in ipairs(GROUP_ORDER) do
            local group = NormalizeGroup(groupId, value.groups[groupId])
            if group ~= nil then groups[groupId] = group end
        end
    elseif type(value.slots) == "table" then
        groups.main = NormalizeGroup("main", value.slots)
    end
    if next(groups) == nil then return nil end
    return { owner = Normalize(value.owner), profileId = tonumber(value.profileId), groups = groups }
end

local function NormalizeState(value)
    value = type(value) == "table" and value or {}
    local profiles = {}
    for _, profile in ipairs(type(value.profiles) == "table" and value.profiles or {}) do
        local normalized = NormalizeProfile(profile)
        if normalized ~= nil and #profiles < PROFILE_MAX then profiles[#profiles + 1] = normalized end
    end
    local nextId = math.max(1, math.floor(tonumber(value.nextId) or 1))
    for _, profile in ipairs(profiles) do if tonumber(profile.id) and profile.id >= nextId then nextId = profile.id + 1 end end
    return {
        profiles = profiles,
        nextId = nextId,
        selectedId = tonumber(value.selectedId),
        pendingRecovery = NormalizeRecovery(value.pendingRecovery),
    }
end

local function ProfileById(profileId)
    profileId = tonumber(profileId)
    for index, profile in ipairs(type(F.State.profiles) == "table" and F.State.profiles or {}) do
        if tonumber(profile.id) == profileId then return profile, index end
    end
    return nil
end
local function PersistentState()
    return { profiles = Copy(F.State.profiles or {}), nextId = tonumber(F.State.nextId) or 1, selectedId = F.State.selectedId, pendingRecovery = Copy(F.State.pendingRecovery) }
end
local function ApplyState(value)
    local normalized = NormalizeState(value)
    F.State.profiles = normalized.profiles
    F.State.nextId = normalized.nextId
    F.State.selectedId = normalized.selectedId
    F.State.pendingRecovery = normalized.pendingRecovery
end

if P:GetStore(F.storeId) == nil then
    local store, err = P:RegisterV3Store({
        id = F.storeId, owner = "v3.tools_hotkey_profiles", scope = P.Scope.Account, lifetime = P.Lifetime.Permanent,
        schemaVersion = 2, legacySchemaVersion = 1, key = P.V3KeyPrefix .. "business_tools_hotkey_profiles",
        budget = { maxDepth = 8, maxNodes = 520, maxStringBytes = 6144, maxEntriesPerTable = 128 },
        default = function() return { profiles = {}, nextId = 1 } end,
        get = PersistentState, apply = ApplyState,
        migrate = function(value)
            -- 中文维护注释：纯数据迁移，不读取 Native、不补猜扩展组；v1 slots -> v2 groups.main，保证旧方案原样可用。
            return NormalizeState(value)
        end,
    })
    if store == nil then error(err or "hotkey profile store register failed") end
end

function F:LoadStore()
    if self.storeLoaded then return true end
    local status, _, err = P:LoadStore(self.storeId)
    if status ~= true and status ~= "empty" then return false, err or tostring(status or "store load failed") end
    self.storeLoaded = true; return true
end
function F:Persist(reason, mutator)
    local loaded, err = self:LoadStore(); if loaded ~= true then return false, err end
    return P:MutateStore(self.storeId, function() return mutator(self.State) end, { durable = true, reason = reason })
end
function F.Authority:Refresh(reason)
    local rows = {}
    for _, profile in ipairs(type(F.State.profiles) == "table" and F.State.profiles or {}) do
        local summary, total = DescribeGroups(profile.groups)
        rows[#rows + 1] = {
            profileId = profile.id,
            name = tostring(profile.name or ("方案 " .. tostring(profile.id))),
            text = summary,
            statusText = tonumber(F.State.selectedId) == tonumber(profile.id) and "已选择" or ("共 " .. tostring(total) .. " 项"),
            tone = tonumber(F.State.selectedId) == tonumber(profile.id) and "success" or "muted",
        }
    end
    self.rows, self.status, self.error = rows, (#rows > 0 and "ready" or "empty"), nil
    self.revision = (tonumber(self.revision) or 0) + 1
    if S.Events and type(S.Events.Publish) == "function" then S.Events:Publish(F.UpdateTopic, self.revision, tostring(reason or "refresh")) end
    return true
end
function F:Initialize()
    local ok, err = self:LoadStore(); if ok ~= true then return false, err end
    return self.Authority:Refresh("initialize")
end
function F:Enable() self.enabled = true; return true end
function F:Disable(reason)
    local ok, err = self.Demand:Clear(reason or "hotkey_profiles_disable"); if ok ~= true then return false, err end
    self.enabled = false; return true
end
function F:ReconcileDemand(_, before, after)
    self.consumerCount = tonumber(after and after.count) or 0
    if (tonumber(before and before.count) or 0) <= 0 and self.consumerCount > 0 then return self.Authority:Refresh("consumer_acquire") end
    return true
end
function F:AcquireConsumer(token) if not self.enabled then return false, "功能已关闭" end return self.Demand:Acquire(token, {}, "hotkey_profile_consumer") end
function F:ReleaseConsumer(token) return self.Demand:Release(token, "hotkey_profile_consumer") end
function F:HasConsumer(token) return self.Demand and type(self.Demand.Has) == "function" and self.Demand:Has(token) == true end
function F:Refresh(reason) if not self.enabled or (tonumber(self.consumerCount) or 0) <= 0 then return true end return self.Authority:Refresh(reason or "manual") end
function F:GetProjection()
    local pending = self.State.pendingRecovery
    return {
        revision = self.Authority.revision, rows = Copy(self.Authority.rows), status = self.Authority.status, error = self.Authority.error,
        selectedId = self.State.selectedId, profileCount = #(self.State.profiles or {}), profileLimit = PROFILE_MAX,
        pendingRecovery = pending ~= nil, pendingRecoveryOwner = pending and pending.owner or nil,
        scopeText = "主动作栏 1-12 + 运行时验证的队伍目标 1-4 / 头顶标记 1-3",
        whitelistVersion = self.ActionWhitelistVersion, lastOperation = self.Authority.lastOperation,
    }
end

F.Commands = {}
function F.Commands:Refresh(reason) return F:Refresh(reason) end
function F.Commands:SelectProfile(profileId)
    local profile = ProfileById(profileId); if profile == nil then return false, "方案不存在" end
    F.State.selectedId = profile.id; F.Authority:Refresh("hotkey_profile_select"); return true
end
function F.Commands:SaveProfile(name)
    name = tostring(name or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if name == "" then return false, "请输入方案名称" end
    if #name > 32 then return false, "方案名称最多 32 个字符" end
    -- 中文维护注释：保存只读 GetOptionBinding，不受 RU“战斗中禁止写 Hotkey”约束；这里不能把写限制误扩散到读取。
    -- 唯一需要拒绝的并发来源是 Fishing Auto-R，因为它可能持有临时迁移后的键位视图。
    if FishingConflict() then return false, "钓鱼 Auto-R 正在占用快捷键事务，请先关闭 Auto-R 后再保存方案" end
    if #(F.State.profiles or {}) >= PROFILE_MAX then return false, "最多保存 " .. tostring(PROFILE_MAX) .. " 个方案" end
    local groups, skipped, err = CaptureForSave(); if groups == nil then return false, err end
    local newId = math.max(1, math.floor(tonumber(F.State.nextId) or 1))
    local ok, persistErr = F:Persist("hotkey_profile_save_v2", function(state)
        state.profiles = type(state.profiles) == "table" and state.profiles or {}
        state.profiles[#state.profiles + 1] = { id = newId, name = name, contractVersion = 2, groups = Copy(groups) }
        state.nextId, state.selectedId = newId + 1, newId; return true
    end)
    if ok == true then
        local summary = DescribeGroups(groups)
        local suffix = type(skipped) == "table" and #skipped > 0 and ("；未纳入：" .. table.concat(skipped, "、")) or ""
        F.Authority.lastOperation = "已保存 " .. summary .. suffix
        F.Authority:Refresh("hotkey_profile_saved_v2")
        return true, F.Authority.lastOperation
    end
    return false, persistErr
end
function F.Commands:DeleteProfile(profileId)
    local _, index = ProfileById(profileId); if index == nil then return false, "方案不存在" end
    local ok, err = F:Persist("hotkey_profile_delete", function(state)
        table.remove(state.profiles, index)
        if tonumber(state.selectedId) == tonumber(profileId) then state.selectedId = state.profiles[1] and state.profiles[1].id or nil end
        return true
    end)
    if ok == true then F.Authority.lastOperation = "方案已删除；当前游戏键位未改变"; F.Authority:Refresh("hotkey_profile_deleted") end
    return ok, err
end
function F.Commands:ApplyProfile(profileId)
    if InCombat() then return false, "战斗中不能应用快捷键方案" end
    if FishingConflict() then return false, "钓鱼 Auto-R 正在占用快捷键事务，请先关闭 Auto-R" end
    local profile = ProfileById(profileId); if profile == nil then return false, "请选择要应用的方案" end
    local ready, readyErr = PreflightGroups(profile.groups); if ready ~= true then return false, readyErr end
    local owner = Owner(); if owner == nil then return false, "无法确认当前角色身份，拒绝修改快捷键" end
    local before, err = CaptureMatching(profile.groups); if before == nil then return false, err end
    local ok, persistErr = F:Persist("hotkey_profile_recovery_arm_v2", function(state)
        state.pendingRecovery = { owner = owner, groups = Copy(before), profileId = profile.id }; state.selectedId = profile.id; return true
    end)
    if ok ~= true then return false, "恢复快照保存失败，未修改快捷键：" .. tostring(persistErr) end
    ok, err = WriteGroups(profile.groups or {})
    if ok ~= true then
        local rollbackOk, rollbackErr = WriteGroups(before)
        if rollbackOk == true then F:Persist("hotkey_profile_recovery_clear_after_rollback_v2", function(state) state.pendingRecovery = nil; return true end) end
        F.Authority.lastOperation = "应用失败：" .. tostring(err)
        F.Authority:Refresh("hotkey_profile_apply_failed_v2")
        return false, "应用失败：" .. tostring(err) .. (rollbackOk == true and "；已恢复应用前键位" or ("；自动恢复也失败：" .. tostring(rollbackErr)))
    end
    local cleared, clearErr = F:Persist("hotkey_profile_apply_commit_v2", function(state) state.pendingRecovery = nil; return true end)
    local summary = DescribeGroups(profile.groups)
    F.Authority.lastOperation = "已应用 " .. summary .. "，并通过逐项读回校验"
    F.Authority:Refresh("hotkey_profile_applied_v2")
    if cleared ~= true then return false, "键位已应用，但恢复记录清理失败：" .. tostring(clearErr) end
    return true, F.Authority.lastOperation
end
function F.Commands:RecoverPending()
    local pending = F.State.pendingRecovery
    if type(pending) ~= "table" or type(pending.groups) ~= "table" then return false, "没有待恢复键位" end
    local owner = Owner(); if owner == nil or tostring(owner) ~= tostring(pending.owner) then return false, "待恢复记录属于其他角色，当前角色不能应用" end
    local ok, err = WriteGroups(pending.groups); if ok ~= true then return false, err end
    ok, err = F:Persist("hotkey_profile_manual_recover_v2", function(state) state.pendingRecovery = nil; return true end)
    if ok == true then
        F.Authority.lastOperation = "已恢复本角色应用前快捷键并通过读回校验"
        F.Authority:Refresh("hotkey_profile_recovered_v2")
        return true, F.Authority.lastOperation
    end
    F.Authority:Refresh("hotkey_profile_recover_failed_v2")
    return false, err
end

local lease, leaseErr = Demand:Create({
    id = "feature:" .. F.Id, owner = F, projectionOwner = F, projectionConsumersField = "consumers", projectionCountField = "consumerCount",
    reconcile = function(l, before, after) return F:ReconcileDemand(l, before, after) end,
})
if lease == nil then error(leaseErr or "hotkey profile demand failed") end
F.Demand = lease
local registered, registerErr = Runtime:RegisterImplementation(F.Id, F)
if registered ~= true then error(registerErr or "hotkey profile runtime registration failed") end
