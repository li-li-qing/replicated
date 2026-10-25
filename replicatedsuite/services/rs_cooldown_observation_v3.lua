-- Replicated Suite · 技能冷却观察
-- 作者：Replicated
-- QQ群：1104129461
-- 只追踪真实 Skill ID，不能把 Aura/Effect ID 当冷却 ID。手动追踪不需战斗总线，自动发现仅订阅 SELF 施放成功。
-- 普通/翼类读 GetCooldown，坐骑/战宠读 GetMateCooldown；正读数确认 mateType，未知不猜来源。
-- READY 每 250ms 有限轮转，ACTIVE 每 100ms 更新；读失败仅老化已知快照，不用静态 expectedSec 造计时。
-- 最后消费者释放时停任务并清瞬态缓存，保留用户选择。事实只代表本机，远端冷却需独立投影。
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
S.Services = S.Services or {}

local C = {
    Id = "v3.cooldown_observation",
    version = 5,
    taskName = "v3_cooldown_observation_active",
    intervalMs = 100,
    probeTaskName = "v3_cooldown_observation_probe",
    probeIntervalMs = 250,
    probeBudget = 8,
    tracked = { skill = {}, mate = {} },
    trackedCount = 0,
    manualTracked = { skill = {}, mate = {} },
    localIds = {},
    localSourceById = {},
    discoveredSkills = {},
    autoProbePending = {},
    autoProbeSerial = 0,
    automaticEnabled = false,
    autoSubscribed = false,
    autoEpoch = 0,
    autoLimit = 64,
    autoEvents = 0,
    autoIgnored = 0,
    autoEvicted = 0,
    autoDropped = 0,
    autoError = nil,
    active = {},
    mateTypeById = {},
    metadata = {},
    nativeEvidence = {},
    revision = 0,
    taskActive = false,
    taskGeneration = 0,
    probeOrder = {},
    probeCursor = 1,
    probeTaskActive = false,
    probeGeneration = 0,
    probeCycles = 0,
    probeQueries = 0,
    probeHits = 0,
    nativeReads = 0,
    nativeFailures = 0,
    -- X2Skill 随首个消费者惰性导入，服务自己持有 owner；失败只使冷却不可用，不阻断其它 HUD。
    nativeOwnerId = "service.cooldown_observation_v3",
    nativeSkillLease = false,
    nativeSkillLeaseState = "idle",
    nativeSkillLeaseError = nil,
    activations = 0,
    completions = 0,
    mateRideResolved = 0,
    mateBattleResolved = 0,
    activeReadGaps = 0,
    estimatedExpirations = 0,
    parseFailures = 0,
    rejectedEffectIds = 0,
}
C.presentationBoundary = "service_only"
C.LocalNativeAuthorityContractVersion = 4
C.FallbackProbeContractVersion = 3
C.NativeEvidenceContractVersion = 2
C.NativeSkillIdContractVersion = 1
C.AutomaticDiscoveryContractVersion = 1
S.Services.CooldownObservationV3 = C

local UNKNOWN_ICON = "ui/icon/icon_unknown_item.dds"
local function NowMs() return math.max(0, tonumber(S.NowMs and S.NowMs()) or 0) end
local function NormalizeId(value)
    local id = tonumber(value)
    if id == nil or id ~= id or id <= 0 or id > 2147483647 then return nil end
    id = math.floor(id)
    return id > 0 and id or nil
end
local function CopySet(list, limit)
    local out, count = {}, 0
    for _, value in ipairs(type(list) == "table" and list or {}) do
        local id = NormalizeId(value)
        if id ~= nil and out[id] ~= true and count < (limit or 256) then
            out[id] = true
            count = count + 1
        end
    end
    return out, count
end
local function CountSet(set)
    local count = 0
    for _ in pairs(type(set) == "table" and set or {}) do count = count + 1 end
    return count
end
local function HasRows(t) return type(t) == "table" and next(t) ~= nil end
local function FormatTime(ms)
    ms = tonumber(ms)
    if ms == nil then return "--" end
    ms = math.max(0, ms)
    if ms < 1000 then return string.format("%.1f", math.floor(ms / 100) / 10) end
    if ms < 60000 then return tostring(math.ceil(ms / 1000)) end
    local sec = math.ceil(ms / 1000)
    return string.format("%d:%02d", math.floor(sec / 60), sec % 60)
end

-- RU 返回形状随代际变化；未知形状失败封闭，解析器绝不退回数据库或理论冷却。
local REMAIN_KEYS = { "remaining", "remainTime", "remain_time", "remainingTime", "timeLeft", "left", "cooldown", "cooldownTime", "time" }
local TOTAL_KEYS = { "duration", "total", "totalTime", "total_time", "cooldownDuration", "cooldownTotal", "max" }
local function FiniteNumber(value)
    value = tonumber(value)
    if value == nil or value ~= value or value == math.huge or value == -math.huge then return nil end
    return value
end
local function TableNumber(value, keys)
    if type(value) ~= "table" then return nil end
    for _, key in ipairs(keys) do
        local number = FiniteNumber(value[key])
        if number ~= nil then return number end
    end
    return nil
end
function C:ParseCooldownResult(first, second, third, fourth)
    local values = { first, second, third, fourth }
    local remaining, total
    for _, value in ipairs(values) do
        if type(value) == "table" then
            remaining = remaining or TableNumber(value, REMAIN_KEYS)
            total = total or TableNumber(value, TOTAL_KEYS)
        end
    end
    if remaining == nil then
        local numeric = {}
        for _, value in ipairs(values) do
            if type(value) ~= "table" then
                local number = FiniteNumber(value)
                if number ~= nil then numeric[#numeric + 1] = number end
            end
        end
        remaining = numeric[1]
        total = total or numeric[2]
    elseif total == nil then
        for _, value in ipairs(values) do
            if type(value) ~= "table" then
                local number = FiniteNumber(value)
                if number ~= nil and number ~= remaining then total = number; break end
            end
        end
    end
    if remaining == nil then
        self.parseFailures = self.parseFailures + 1
        return nil, nil, "cooldown_return_unrecognized"
    end
    remaining = math.max(0, remaining)
    if total ~= nil then total = math.max(remaining, math.max(0, total)) end
    return remaining, total, nil
end

function C:_Call(capability, methodName, skillId, mateType)
    if S.Api == nil or type(S.Api.CallCapability) ~= "function" then return nil, nil, "api_unavailable" end
    self.nativeReads = self.nativeReads + 1
    local ok, first, err, second, third, fourth
    if mateType ~= nil then
        ok, first, err, second, third, fourth = S.Api:CallCapability(capability, nil, methodName, skillId, true, mateType)
    else
        ok, first, err, second, third, fourth = S.Api:CallCapability(capability, nil, methodName, skillId, true)
    end
    if ok ~= true then
        self.nativeFailures = self.nativeFailures + 1
        return nil, nil, err
    end
    return self:ParseCooldownResult(first, second, third, fourth)
end

function C:_QuerySkill(skillId)
    local remaining, total, err = self:_Call("X2Skill:GetCooldown", "GetCooldown", skillId, nil)
    return remaining, total, "skill", nil, err
end

local function RideType()
    local value = rawget(_G, "MATE_TYPE_RIDE")
    return tonumber(value) or 1
end
local function BattleType()
    local value = rawget(_G, "MATE_TYPE_BATTLE")
    return tonumber(value) or 2
end

function C:_QueryMate(skillId)
    local cached = self.mateTypeById[skillId]
    local order = cached ~= nil and { cached } or { RideType(), BattleType() }
    local firstError, sawValidReady = nil, false
    for _, mateType in ipairs(order) do
        local remaining, total, err = self:_Call("X2Skill:GetMateCooldown", "GetMateCooldown", skillId, mateType)
        if remaining ~= nil then
            sawValidReady = true
            if remaining > 0 and self.mateTypeById[skillId] == nil then
                self.mateTypeById[skillId] = mateType
                if mateType == RideType() then self.mateRideResolved = self.mateRideResolved + 1
                elseif mateType == BattleType() then self.mateBattleResolved = self.mateBattleResolved + 1 end
            end
            -- 正值读取证明 mate 类型；已缓存类型返回零证明 Ready。初次发现仅零值不能区分 ride/battle，因此
            -- 须查两种类型。
            if remaining > 0 or cached ~= nil then return remaining, total, "mate", mateType, err end
        elseif firstError == nil then
            firstError = err
        end
    end
    if sawValidReady and firstError==nil then return 0, nil, "mate", cached, nil end
    return nil, nil, "mate", cached, firstError or "mate_cooldown_unavailable"
end

-- 玩家只选 Skill ID；未确认来源时在原预算内查两个 getter，正读数才确认。
-- 来源仅存本次 Runtime，不读目标冷却，确认后 active lane 只读该来源。
function C:_QueryLocal(skillId)
    local known=self.localSourceById[skillId]
    if known=="skill" then return self:_QuerySkill(skillId) end
    if known=="mate" then return self:_QueryMate(skillId) end
    local own,total,source,mateType,err=self:_QuerySkill(skillId)
    if own and own>0 then self.localSourceById[skillId]="skill";return own,total,source,mateType,err end
    local mate,mateTotal,mateSource,resolvedType,mateError=self:_QueryMate(skillId)
    if mate and mate>0 then self.localSourceById[skillId]="mate";return mate,mateTotal,mateSource,resolvedType,mateError end
    -- 来源未确认时，一个 Getter 的零值不能掩盖其他候选来源的读取失败。
    if own~=nil and mate~=nil then return 0,total,source,mateType,nil end
    return nil,nil,"local",nil,err or mateError or "local_cooldown_partial_coverage"
end

function C:_ProbeCost(kind,id)
    if kind=="mate" then return self.mateTypeById[id]~=nil and 1 or 2 end
    if self.localIds[id] then
        local known=self.localSourceById[id]
        if known=="skill" then return 1 end
        if known=="mate" then return self.mateTypeById[id]~=nil and 1 or 2 end
        return 3
    end
    return 1
end

function C:_RecordNativeEvidence(kind, skillId, remaining, total, source, mateType, err)
    local key = tostring(kind) .. ":" .. tostring(skillId)
    local row = self.nativeEvidence[key] or { key=key, kind=kind, id=skillId, queries=0, positives=0, ready=0, unknown=0 }
    row.queries = math.min(2147483647, (tonumber(row.queries) or 0) + 1)
    row.lastAt = NowMs(); row.source = source; row.mateType = mateType
    row.remaining = remaining; row.total = total; row.error = err ~= nil and tostring(err) or nil
    if remaining == nil then row.status="unknown"; row.unknown=(tonumber(row.unknown) or 0)+1
    elseif remaining > 0 then row.status="active"; row.positives=(tonumber(row.positives) or 0)+1
    else row.status="ready"; row.ready=(tonumber(row.ready) or 0)+1 end
    self.nativeEvidence[key] = row
end

function C:_Query(kind, skillId)
    local remaining,total,source,mateType,err
    if kind=="skill" and self.localIds[skillId] then remaining,total,source,mateType,err=self:_QueryLocal(skillId)
    elseif kind == "mate" then remaining,total,source,mateType,err = self:_QueryMate(skillId)
    else remaining,total,source,mateType,err = self:_QuerySkill(skillId) end
    self:_RecordNativeEvidence(kind, skillId, remaining, total, source, mateType, err)
    return remaining,total,source,mateType,err
end

function C:_ResolveMetadata(kind, skillId, fallbackName)
    local key = kind .. ":" .. tostring(skillId)
    local cached = self.metadata[key]
    if cached ~= nil then return cached end
    local discovered=kind=="skill" and self.discoveredSkills[skillId] or nil
    local name, iconPath = tostring(fallbackName or (discovered and discovered.name) or ""), UNKNOWN_ICON
    local catalog = S.Data and S.Data.StatusTrackingCatalogV3 or nil
    local entry = type(catalog) == "table" and type(catalog.ByKey) == "table" and catalog.ByKey["cooldown:" .. kind .. ":" .. tostring(skillId)] or nil
    if type(entry) == "table" and tostring(entry.name or "") ~= "" then name = tostring(entry.name) end
    local metadata = S.Services and S.Services.SkillMetadataV3 or nil
    local resolved, source = false, "fallback"
    if type(metadata) == "table" and type(metadata.GetSkillInfo) == "function" then
        local info = metadata:GetSkillInfo(skillId, name)
        if type(info) == "table" then
            if tostring(info.name or "") ~= "" then name = tostring(info.name) end
            if tostring(info.iconPath or "") ~= "" then iconPath = tostring(info.iconPath) end
            resolved = info.resolved == true
            source = tostring(info.source or source)
        end
    end
    if name == "" then name = "技能 " .. tostring(skillId) end
    cached = { name=name, iconPath=iconPath, resolved=resolved, source=source }
    self.metadata[key] = cached
    return cached
end

-- 命令/UI 边界显式验证 Skill ID；已知 Effect ID 被拒绝，除非同一数字也独立证明或解析为技能，防止 Buff/CD 跟
-- 踪混淆。
function C:ValidateSkillId(skillId, kind)
    local id = NormalizeId(skillId)
    if id == nil then return false, "技能 ID 无效" end
    kind = tostring(kind or "")
    if kind ~= "skill" and kind ~= "mate" then return false, "冷却类型无效" end
    local catalog = S.Data and S.Data.StatusTrackingCatalogV3 or nil
    local knownEffect = type(catalog) == "table" and type(catalog.ByEffectId) == "table" and catalog.ByEffectId[id] ~= nil
    local knownSkill = type(catalog) == "table" and type(catalog.BySkillId) == "table" and catalog.BySkillId[id] ~= nil
    local cooldownSeed = type(catalog) == "table" and type(catalog.ByKey) == "table" and catalog.ByKey["cooldown:"..kind..":"..tostring(id)] ~= nil
    local meta = self:_ResolveMetadata(kind, id, nil)
    local resolvedSkill = type(meta) == "table" and meta.resolved == true
    if knownEffect and not knownSkill and not cooldownSeed and not resolvedSkill then
        self.rejectedEffectIds = self.rejectedEffectIds + 1
        return false, "ID "..tostring(id).." 是已知 Buff/Effect ID；技能 CD 必须填写 Skill ID"
    end
    return true, {
        id=id, kind=kind, name=meta and meta.name or ("技能 "..tostring(id)),
        iconPath=meta and meta.iconPath or UNKNOWN_ICON,
        resolved=resolvedSkill or knownSkill or cooldownSeed,
        source=meta and meta.source or "unknown",
        knownEffect=knownEffect, knownSkill=knownSkill, cooldownSeed=cooldownSeed,
    }
end

function C:_PublishUpdate(key)
    self.revision = self.revision + 1
    if S.Events ~= nil and type(S.Events.Publish) == "function" then
        S.Events:Publish("v3.cooldown.updated", key, self.revision)
    end
end

function C:_SetActive(kind, skillId, remaining, total, source, mateType)
    local key = kind .. ":" .. tostring(skillId)
    local old = self.active[key]
    local meta = self:_ResolveMetadata(kind, skillId, nil)
    local now = NowMs()
    local remainingMs = math.max(0, tonumber(remaining) or 0)
    self.active[key] = {
        key=key,id=skillId,skillId=skillId,kind=kind,source=source or kind,mateType=mateType,
        name=meta.name,iconPath=meta.iconPath,remainingMs=remainingMs,
        totalMs=total ~= nil and math.max(0, tonumber(total) or 0) or nil,
        updatedAt=now,authority="LocalNative",stale=false,
        lastNativeRemainingMs=remainingMs,lastNativeAt=now,readFailureStreak=0,
    }
    if old == nil then self.activations = self.activations + 1 end
    self:_PublishUpdate(key)
end

function C:_RemoveActive(key, estimated)
    if self.active[key] == nil then return false end
    self.active[key] = nil
    self.completions = self.completions + 1
    if estimated == true then self.estimatedExpirations = self.estimatedExpirations + 1 end
    self:_PublishUpdate(key)
    return true
end

function C:_StopTask()
    self.taskGeneration = self.taskGeneration + 1
    if S.Scheduler ~= nil and type(S.Scheduler.RemoveTask) == "function" then S.Scheduler:RemoveTask(self.taskName) end
    self.taskActive = false
    return true
end
function C:_EnsureTask()
    if self.taskActive == true then return true end
    if not HasRows(self.active) then return true end
    if S.Scheduler == nil or type(S.Scheduler.AddTask) ~= "function" then return false, "Cooldown Scheduler unavailable" end
    self.taskGeneration = self.taskGeneration + 1
    local generation = self.taskGeneration
    local ok = S.Scheduler:AddTask(self.taskName, self.intervalMs, function()
        if C.taskGeneration ~= generation or S.Services.CooldownObservationV3 ~= C then return true end
        return C:Refresh("scheduled")
    end, true, self, "P1", 1)
    if ok ~= true then return false, "Cooldown active task create failed" end
    self.taskActive = true
    if type(S.Scheduler.SetTaskModule) == "function" then S.Scheduler:SetTaskModule(self.taskName, self.Id, false) end
    return true
end

function C:_StopProbeTask()
    self.probeGeneration = self.probeGeneration + 1
    if S.Scheduler ~= nil and type(S.Scheduler.RemoveTask) == "function" then S.Scheduler:RemoveTask(self.probeTaskName) end
    self.probeTaskActive = false
    return true
end
function C:_RebuildProbeOrder()
    local order = {}
    for _, kind in ipairs({ "skill", "mate" }) do
        for id in pairs(self.tracked[kind]) do order[#order + 1] = { kind=kind, id=id } end
    end
    table.sort(order, function(a,b) if a.kind~=b.kind then return a.kind<b.kind end return a.id<b.id end)
    self.probeOrder = order
    if #order <= 0 then self.probeCursor = 1
    else self.probeCursor = math.max(1, math.min(tonumber(self.probeCursor) or 1, #order)) end
end

-- 不依赖事件的 READY 发现按 Native 调用次数计预算；未分类 mate ID 可能消耗 ride+battle 两次读取。
function C:_ProbeTrackedReady(kind,id)
    self.probeQueries=self.probeQueries+1
    local remaining,totalMs,source,mateType=self:_Query(kind,id)
    if remaining~=nil and remaining>0 then
        self.probeHits=self.probeHits+1
        self:_SetActive(kind,id,remaining,totalMs,source,mateType)
        self:_EnsureTask()
    end
end

function C:ProbeReady(reason, budget)
    local order = self.probeOrder
    local total = type(order) == "table" and #order or 0
    if total <= 0 or self.trackedCount <= 0 then return true end
    budget = math.max(1, math.floor(tonumber(budget) or self.probeBudget))
    local visited, readsAtStart = 0, self.nativeReads
    self.probeCycles = self.probeCycles + 1
    -- 刚施放的自身技能优先确认，避免64个 Ready 项把短 CD 拖过期。
    -- 最多使用原8次预算中的4次，余量继续轮询；待查表最多64项，不增加调度任务或总查询量。
    local urgent,queried=0,{}
    while urgent<math.min(4,budget) do
        local id,serial
        for candidate,order in pairs(self.autoProbePending) do
            if serial==nil or order<serial then id,serial=candidate,order end
        end
        if not id then break end
        local cost=self:_ProbeCost("skill",id)
        if self.tracked.skill[id] and not self.active["skill:"..id] and (self.nativeReads-readsAtStart)+cost>math.min(4,budget) then break end
        self.autoProbePending[id]=nil;urgent=urgent+1
        if self.tracked.skill[id] and not self.active["skill:"..id] then
            queried[id]=true
            self:_ProbeTrackedReady("skill",id)
        end
    end
    while visited < total and (self.nativeReads - readsAtStart) < budget do
        if self.probeCursor > total then self.probeCursor = 1 end
        local candidate = order[self.probeCursor]
        self.probeCursor = self.probeCursor + 1
        visited = visited + 1
        if type(candidate) == "table" and self.tracked[candidate.kind][candidate.id] == true then
            local key = candidate.kind .. ":" .. tostring(candidate.id)
            if self.active[key] == nil and not (candidate.kind=="skill" and queried[candidate.id]) then
                local estimatedCost = self:_ProbeCost(candidate.kind,candidate.id)
                if (self.nativeReads - readsAtStart) + estimatedCost > budget then
                    -- 预算不足的候选留到下个周期；提前消耗游标会让每轮末尾同一 ID 永久漏采。
                    self.probeCursor=self.probeCursor-1
                    break
                end
                self:_ProbeTrackedReady(candidate.kind,candidate.id)
            end
        end
    end
    return true
end

function C:_EnsureProbeTask()
    if self.probeTaskActive == true then return true end
    if self.trackedCount <= 0 then return true end
    if self.Demand ~= nil and (tonumber(self.Demand.count) or 0) <= 0 then return true end
    if S.Scheduler == nil or type(S.Scheduler.AddTask) ~= "function" then return false, "Cooldown probe Scheduler unavailable" end
    self.probeGeneration = self.probeGeneration + 1
    local generation = self.probeGeneration
    local ok = S.Scheduler:AddTask(self.probeTaskName, self.probeIntervalMs, function()
        if C.probeGeneration ~= generation or S.Services.CooldownObservationV3 ~= C then return true end
        return C:ProbeReady("scheduled", C.probeBudget)
    end, true, self, "P4", 1)
    if ok ~= true then return false, "Cooldown probe task create failed" end
    self.probeTaskActive = true
    if type(S.Scheduler.SetTaskModule) == "function" then S.Scheduler:SetTaskModule(self.probeTaskName, self.Id, false) end
    return true
end

function C:Refresh(reason)
    local now = NowMs()
    for key, row in pairs(self.active) do
        local remaining, total, source, mateType = self:_Query(row.kind, row.id)
        if remaining == nil then
            self.activeReadGaps = self.activeReadGaps + 1
            row.readFailureStreak = (tonumber(row.readFailureStreak) or 0) + 1
            local lastAt = tonumber(row.lastNativeAt) or tonumber(row.updatedAt) or now
            local lastRemaining = math.max(0, tonumber(row.lastNativeRemainingMs) or tonumber(row.remainingMs) or 0)
            local estimated = math.max(0, lastRemaining - math.max(0, now - lastAt))
            if estimated <= 0 then
                self:_RemoveActive(key, true)
            else
                local changedBucket = math.ceil((tonumber(row.remainingMs) or 0) / 100) ~= math.ceil(estimated / 100)
                row.remainingMs, row.updatedAt = estimated, now
                row.authority, row.stale = "LocalNativeSnapshot", true
                if changedBucket then self:_PublishUpdate(key) end
            end
        elseif remaining <= 0 then
            self:_RemoveActive(key, false)
        else
            local changedBucket = math.ceil((tonumber(row.remainingMs) or 0) / 100) ~= math.ceil(remaining / 100)
            local authorityRecovered = row.authority ~= "LocalNative" or row.stale == true
            row.remainingMs, row.totalMs = remaining, total or row.totalMs
            row.source, row.mateType, row.updatedAt = source or row.source, mateType or row.mateType, now
            row.authority, row.stale, row.readFailureStreak = "LocalNative", false, 0
            row.lastNativeRemainingMs, row.lastNativeAt = remaining, now
            if changedBucket or authorityRecovered then self:_PublishUpdate(key) end
        end
    end
    if not HasRows(self.active) then self:_StopTask() end
    return true
end

function C:_ApplyTracked(skillSet, mateSet)
    self.tracked = { skill=skillSet, mate=mateSet }
    self.trackedCount = CountSet(skillSet) + CountSet(mateSet)
    local changed, validKeys = false, {}
    for id in pairs(skillSet) do validKeys["skill:"..tostring(id)] = true end
    for id in pairs(mateSet) do validKeys["mate:"..tostring(id)] = true end
    for key, row in pairs(self.active) do
        if self.tracked[row.kind][row.id] ~= true then self.active[key]=nil; changed=true end
    end
    for key in pairs(self.metadata) do if validKeys[key] ~= true then self.metadata[key]=nil end end
    for key in pairs(self.nativeEvidence) do if validKeys[key] ~= true then self.nativeEvidence[key]=nil end end
    for id in pairs(self.autoProbePending) do if skillSet[id]~=true then self.autoProbePending[id]=nil end end
    for id in pairs(self.mateTypeById) do if mateSet[id] ~= true and self.localIds[id]~=true then self.mateTypeById[id]=nil end end
    for id in pairs(self.localSourceById) do if self.localIds[id]~=true then self.localSourceById[id]=nil end end
    self:_RebuildProbeOrder()
    if changed then self:_PublishUpdate("tracked_set") end
end

-- 自身施放成功只证明 Skill ID，实际冷却仍由 Native lane 确认，不在事件回调读 API。
-- 自动发现最多 64 个会话技能，只淘汰最久未用且非活动项；不扫描技能库或写用户选择。
function C:_MergedTracked()
    local skills,mates={},{}
    for id in pairs(self.manualTracked.skill) do skills[id]=true end
    for id in pairs(self.manualTracked.mate) do mates[id]=true end
    if self.automaticEnabled then for id in pairs(self.discoveredSkills) do skills[id]=true end end
    return skills,mates
end

function C:_QueueAutomaticProbe(id)
    if not self.active["skill:"..id] and not self.autoProbePending[id] then
        self.autoProbeSerial=self.autoProbeSerial+1
        self.autoProbePending[id]=self.autoProbeSerial
    end
    local ok,err=self:_EnsureProbeTask()
    self.autoError=not ok and tostring(err or "auto_probe_unavailable") or nil
    return ok
end

function C:_ObserveAutomaticSkill(fact)
    if not self.automaticEnabled or not self.autoSubscribed or self.Demand.count<=0 or type(fact)~="table" then return true end
    local event=string.upper(tostring(fact.rawEventType or ""))
    -- CamelCase CastSuccess 已有 RU 原始样本；SPELL_CAST_SUCCESS 有客户端参考消费端。
    -- CastStart/伤害/状态应用不作为自动 ID 入口，防止取消施法及 Buff/Skill namespace 混淆。
    if event~="CASTSUCCESS" and event~="SPELL_CAST_SUCCESS" then return true end
    self.autoEvents=self.autoEvents+1
    local identity=S.Services and S.Services.UnitIdentityV3
    if type(identity)~="table" or type(identity.IsPlayerIdentityReady)~="function" or not identity:IsPlayerIdentityReady()
        or type(identity.IsPlayerName)~="function" or not identity:IsPlayerName(fact.sourceName) then
        self.autoIgnored=self.autoIgnored+1;return true
    end
    local number=FiniteNumber(fact.rawAbilityId)
    local id=NormalizeId(number)
    if not id or number~=id then self.autoIgnored=self.autoIgnored+1;return true end
    local known=self.discoveredSkills[id]
    if known then known.lastAt=NowMs();self:_QueueAutomaticProbe(id);return true end
    if CountSet(self.discoveredSkills)>=self.autoLimit then
        local oldest,oldestAt
        for candidate,row in pairs(self.discoveredSkills) do
            if self.active["skill:"..candidate]==nil and (oldestAt==nil or row.lastAt<oldestAt) then oldest,oldestAt=candidate,row.lastAt end
        end
        if not oldest then self.autoDropped=self.autoDropped+1;return true end
        self.discoveredSkills[oldest]=nil;self.autoEvicted=self.autoEvicted+1
    end
    local name=tostring(fact.abilityName or "")
    if #name>256 then name="" end
    self.discoveredSkills[id]={name=name,lastAt=NowMs()}
    local skills,mates=self:_MergedTracked()
    self:_ApplyTracked(skills,mates)
    self:_QueueAutomaticProbe(id)
    self:_PublishUpdate("auto_discovered")
    return true
end

function C:_SetAutomaticDiscovery(enabled)
    enabled=enabled==true
    local bus=S.Services and S.Services.CombatEventBusV3
    if not enabled then
        -- 先使已捕获回调失效；释放被拒绝交回真实 Demand rollback，不能谎称 lease 已释放。
        self.automaticEnabled=false;self.autoEpoch=self.autoEpoch+1
        if self.autoSubscribed then
            if type(bus)~="table" or type(bus.Unsubscribe)~="function" then return false,"auto_discovery_release_unavailable" end
            local ok,err=bus:Unsubscribe(self)
            if not ok then self.autoError=tostring(err or "auto_discovery_release_failed");return false,self.autoError end
            self.autoSubscribed=false
        end
        self.autoError=nil
        return true
    end
    if self.automaticEnabled and self.autoSubscribed then return true end
    self.automaticEnabled=true;self.autoEpoch=self.autoEpoch+1
    if type(bus)~="table" or type(bus.Subscribe)~="function" then self.autoError="auto_discovery_bus_unavailable";return true end
    local epoch,generation=self.autoEpoch,S.Generation
    local ok,err=bus:Subscribe(self,function(_,fact)
        if C.autoEpoch~=epoch or S.Generation~=generation or S.Services.CooldownObservationV3~=C then return true end
        return C:_ObserveAutomaticSkill(fact)
    end,{scope="self"})
    self.autoSubscribed=ok==true
    self.autoError=not ok and tostring(err or "auto_discovery_subscribe_failed") or nil
    -- 发现入口不可用只使自动识别降级，不阻断已手动追踪的 Native CD 或无关 HUD。
    return true
end

function C:_ResetRuntime(publishReason)
    local released,err=self:_SetAutomaticDiscovery(false)
    if not released then return false,err end
    self:_StopTask(); self:_StopProbeTask()
    self.discoveredSkills={};self.manualTracked={skill={},mate={}}
    self.localIds={};self.localSourceById={}
    self.autoProbePending={};self.autoProbeSerial=0
    self.tracked, self.trackedCount = { skill={}, mate={} }, 0
    self.probeOrder, self.probeCursor = {}, 1
    self.active, self.metadata, self.mateTypeById, self.nativeEvidence = {}, {}, {}, {}
    if publishReason ~= nil then self:_PublishUpdate(publishReason) end
    return true
end

function C:_Reconcile(before, after)
    local afterCount = tonumber(after and after.count) or 0
    if afterCount <= 0 then return self:_ResetRuntime("release") end
    local skills, mates, locals, automatic = {}, {}, {}, false
    for _, options in pairs(type(after.consumers)=="table" and after.consumers or {}) do
        if type(options)=="table" then
            automatic=automatic or options.automatic==true
            for id in pairs(type(options.skillIds)=="table" and options.skillIds or {}) do skills[id]=true end
            for id in pairs(type(options.mateIds)=="table" and options.mateIds or {}) do mates[id]=true end
            for id in pairs(type(options.localIds)=="table" and options.localIds or {}) do locals[id]=true;skills[id]=true end
        end
    end
    local ok,err=self:_SetAutomaticDiscovery(automatic)
    if not ok then return false,err end
    self.manualTracked={skill=skills,mate=mates}
    self.localIds=locals
    if not automatic then self.discoveredSkills={};self.autoProbePending={};self.autoProbeSerial=0 end
    local mergedSkills,mergedMates=self:_MergedTracked()
    self:_ApplyTracked(mergedSkills,mergedMates)
    if self.trackedCount <= 0 then
        self:_StopTask(); self:_StopProbeTask()
        self.active, self.metadata, self.mateTypeById, self.nativeEvidence = {}, {}, {}, {}
        return true
    end
    local probeOk, probeErr = self:_EnsureProbeTask()
    if probeOk ~= true then return false, probeErr end
    if HasRows(self.active) then return self:_EnsureTask() end
    self:_StopTask()
    return true
end

-- X2Skill 的 namespace ID=35，来源见 native/rs_native_contract.lua。
-- 服务在实际需要冷却时领取 owner；失败返回 false 并留诊断，不抛错。
function C:EnsureNativeSkillLease()
    if self.nativeSkillLease == true then return true end
    local imports = S.ApiImports
    if type(imports) ~= "table" or type(imports.AcquireApi) ~= "function" then
        self.nativeSkillLeaseState = "imports_unavailable"
        return false
    end
    local ok, err = imports:AcquireApi(self.nativeOwnerId, "X2Skill")
    if ok ~= true then
        self.nativeSkillLeaseState = "failed"
        self.nativeSkillLeaseError = tostring(err or "x2skill_import_failed")
        return false
    end
    self.nativeSkillLease = true
    self.nativeSkillLeaseState = "acquired"
    self.nativeSkillLeaseError = nil
    return true
end

function C:AcquireConsumer(token, options)
    if self.Demand == nil then return false, "cooldown demand unavailable" end
    -- 首个消费者才导入；失败保留需求并按冷却不可用降级。
    self:EnsureNativeSkillLease()
    local ok,err=self.Demand:Acquire(token, options, "cooldown_consumer")
    if ok and self.automaticEnabled and not self.autoSubscribed then self:_SetAutomaticDiscovery(true) end
    return ok,err
end
function C:ReleaseConsumer(token)
    if self.Demand == nil then return false, "cooldown demand unavailable" end
    if self.Demand:Has(token) ~= true then return true end
    return self.Demand:Release(token, "cooldown_consumer")
end

function C:GetActiveRows()
    local rows = {}
    for _, row in pairs(self.active) do
        rows[#rows+1] = {
            key=row.key,id=row.id,skillId=row.skillId,kind=row.kind,source=row.source,mateType=row.mateType,
            name=row.name,iconPath=row.iconPath,remainingMs=row.remainingMs,totalMs=row.totalMs,
            timeLeft=row.remainingMs,timeText=FormatTime(row.remainingMs),authority=row.authority,updatedAt=row.updatedAt,stale=row.stale==true,
            active=true,ready=false,tracked=self.manualTracked[row.kind][row.id]==true,
            automatic=row.kind=="skill" and self.discoveredSkills[row.id]~=nil,
            trackedText=self.manualTracked[row.kind][row.id] and "已追踪" or "自动识别",idType="skill",
        }
    end
    table.sort(rows,function(a,b)
        if a.remainingMs~=b.remainingMs then return (a.remainingMs or math.huge)<(b.remainingMs or math.huge) end
        return a.id<b.id
    end)
    return rows,self.revision
end

function C:GetTrackedRows()
    local rows = {}
    for _, kind in ipairs({"skill","mate"}) do
        for id in pairs(self.tracked[kind]) do
            local key = kind..":"..tostring(id)
            local live = self.active[key]
            local meta = self:_ResolveMetadata(kind,id,nil)
            local evidence = self.nativeEvidence[key]
            local idleText,idleAuthority,idleReady = "待读取","LocalNativePending",false
            if type(evidence)=="table" then
                if evidence.status=="ready" then idleText,idleAuthority,idleReady="就绪","LocalNative",true
                elseif evidence.status=="unknown" then idleText,idleAuthority,idleReady="Native 未读取","LocalNativeUnknown",false end
            end
            rows[#rows+1] = {
                key="cooldown:"..kind..":"..tostring(id),id=id,skillId=id,kind=kind,idType="skill",
                source=live and live.source or (evidence and evidence.source) or kind,
                mateType=live and live.mateType or (evidence and evidence.mateType) or self.mateTypeById[id],
                name=live and live.name or meta.name,iconPath=live and live.iconPath or meta.iconPath,
                remainingMs=live and live.remainingMs or 0,totalMs=live and live.totalMs or (evidence and evidence.total) or nil,
                timeLeft=live and live.remainingMs or nil,timeText=live and FormatTime(live.remainingMs) or idleText,
                authority=live and live.authority or idleAuthority,stale=live and live.stale==true or false,
                active=live~=nil,ready=live~=nil and false or idleReady,tracked=self.manualTracked[kind][id]==true,
                automatic=kind=="skill" and self.discoveredSkills[id]~=nil,
                trackedText=self.manualTracked[kind][id] and "已追踪" or "自动识别",
                nativeStatus=evidence and evidence.status or "unseen",nativeError=evidence and evidence.error or nil,
                skillIdentityResolved=meta.resolved==true,skillIdentitySource=meta.source,
            }
        end
    end
    table.sort(rows,function(a,b)
        if a.active~=b.active then return a.active==true end
        if a.kind~=b.kind then return a.kind<b.kind end
        return a.id<b.id
    end)
    return rows,self.revision
end

function C:GetNativeEvidence(limit, manualFirst)
    limit=math.max(1,math.min(32,math.floor(tonumber(limit) or 16)))
    local rows={}
    for _,row in pairs(self.nativeEvidence or {}) do
        local metadata=self.metadata[row.key]
        rows[#rows+1]={key=row.key,kind=row.kind,id=row.id,status=row.status,remaining=row.remaining,total=row.total,
            source=row.source,mateType=row.mateType,error=row.error,lastAt=row.lastAt,queries=row.queries,positives=row.positives,ready=row.ready,unknown=row.unknown,
            tracked=self.manualTracked[row.kind] and self.manualTracked[row.kind][row.id]==true,
            iconPath=metadata and metadata.iconPath or nil}
    end
    -- 显式诊断优先保留已保存技能，避免低 ID 自动候选挤掉高 ID 追踪项。
    -- 这里只复制 Native/元数据缓存，绝不借 GetTrackedRows 触发元数据解析或额外 Native 查询。
    table.sort(rows,function(a,b)
        if manualFirst==true and a.tracked~=b.tracked then return a.tracked==true end
        if a.kind~=b.kind then return a.kind<b.kind end return a.id<b.id
    end)
    local count=#rows
    while #rows>limit do rows[#rows]=nil end
    return rows,count
end

-- 给页面的有界状态投影，不复制逐 ID 诊断证据，也不采集 Native。
function C:GetDiscoveryState()
    return {enabled=self.automaticEnabled==true,subscribed=self.autoSubscribed==true,
        discovered=CountSet(self.discoveredSkills),active=CountSet(self.active),error=self.autoError}
end

function C:GetHealth()
    return {
        version=self.version,ok=self.Demand~=nil,consumers=self.Demand and self.Demand.count or 0,
        tracked=self.trackedCount,skillTracked=CountSet(self.tracked.skill),mateTracked=CountSet(self.tracked.mate),
        localTracked=CountSet(self.localIds),localSourcesResolved=CountSet(self.localSourceById),localSourceContract=1,
        active=CountSet(self.active),pending=0,busScope=self.autoSubscribed and "self" or "none",
        subscribed=self.autoSubscribed==true,eventIndependent=self.automaticEnabled~=true,
        nativeTimerEventIndependent=true,automatic=self.automaticEnabled==true,
        autoDiscovered=CountSet(self.discoveredSkills),autoLimit=self.autoLimit,autoEvents=self.autoEvents,
        autoProbePending=CountSet(self.autoProbePending),
        autoIgnored=self.autoIgnored,autoEvicted=self.autoEvicted,autoDropped=self.autoDropped,autoError=self.autoError,
        automaticDiscoveryContract=self.AutomaticDiscoveryContractVersion,
        idContract="skill_id_only",nativeSkillIdContract=self.NativeSkillIdContractVersion,rejectedEffectIds=self.rejectedEffectIds,
        taskActive=self.taskActive==true,intervalMs=self.intervalMs,revision=self.revision,
        probeTaskActive=self.probeTaskActive==true,probeIntervalMs=self.probeIntervalMs,probeBudget=self.probeBudget,
        probeCycles=self.probeCycles,probeQueries=self.probeQueries,probeHits=self.probeHits,
        metadataCache=CountSet(self.metadata),mateTypeCache=CountSet(self.mateTypeById),
        nativeReads=self.nativeReads,nativeFailures=self.nativeFailures,parseFailures=self.parseFailures,
        -- 只读导入状态，区分尚无需求和导入失败。
        nativeSkillLease=self.nativeSkillLease==true,nativeSkillLeaseState=self.nativeSkillLeaseState,
        nativeSkillLeaseError=self.nativeSkillLeaseError,nativeSkillOwner=self.nativeOwnerId,
        activations=self.activations,completions=self.completions,mateRideResolved=self.mateRideResolved,mateBattleResolved=self.mateBattleResolved,
        pendingExpired=0,pendingMaxAttempts=0,activeReadGaps=self.activeReadGaps,estimatedExpirations=self.estimatedExpirations,
        nativeEvidenceContract=self.NativeEvidenceContractVersion,nativeEvidence=self:GetNativeEvidence(16),
        authority="LocalNative",proxyRows=0,
    }
end

if S.Demand == nil or type(S.Demand.Create) ~= "function" then error("Demand unavailable for CooldownObservationV3") end
local demand,demandErr = S.Demand:Create({
    id=C.Id,owner=C,projectionOwner=C,
    projectionConsumersField="consumers",projectionCountField="consumerCount",
    normalize=function(options)
        options=type(options)=="table" and options or {}
        local skills=select(1,CopySet(options.skillIds,256))
        local mates=select(1,CopySet(options.mateIds,256))
        local locals=select(1,CopySet(options.localIds,512)) -- 旧保存 own/mate 各 256，合并后不丢已有选择。
        return {skillIds=skills,mateIds=mates,localIds=locals,automatic=options.automatic==true,purpose=tostring(options.purpose or "generic")}
    end,
    reconcile=function(_,before,after) return C:_Reconcile(before,after) end,
    quiesce=function() return C:_ResetRuntime(nil) end,
})
if demand==nil then error(demandErr) end
C.Demand=demand
