ReplicatedSuiteModuleSandbox:Enter('dps', {'ReplicatedDps', 'ReplicatedDpsConfig'})
------------------------------------------------------------------------
-- Replicated DPS - Runtime event pipeline and scanners
-- Author: Replicated
------------------------------------------------------------------------

if ReplicatedDps == nil or ReplicatedDps.Boot == nil then return end
local D = ReplicatedDps
local Boot = D.Boot
local U = D.Util
local C = D.Const
local E = D.Entities
local Actors = D.ActorRegistry
local S = D.Stats
local R = D.Runtime
local Store = D.EventStore
local Api = D.Api
local EventFacts = D.EventFacts
local EventBlocks = D.EventBlocks
local EventClassifications = D.EventClassifications
local LocalReplay = D.LocalReplayPlanner
local LocalStatsShadow = D.LocalStatsShadow
local LocalStatsCandidate = D.LocalStatsCandidate
local LocalDerivedShadow = D.LocalDerivedShadow
local LocalCommitEnvelope = D.LocalCommitEnvelope
local PersistenceShards = D.PersistenceShards
local PersistenceLoadGate = D.PersistenceLoadGate
local PersistenceSwitch = D.PersistenceSwitch
local EventShadow = D.EventShadow
-- Professional files run in isolated environments where `_G` is the module
-- table.  Resolve through the environment's root fallback instead of rawget,
-- otherwise the Suite monitor is invisible and this critical path is omitted.
local SuitePerformance = ReplicatedSuite and ReplicatedSuite.PerformanceMonitor or nil

if Boot.phase == "FAILED" or R.uiReady ~= true then return end
if type(Api) ~= "table" then
    Boot:Fail("runtime:api_facade", "rdps_api.lua is unavailable")
    return
end
if type(Actors) ~= "table" then
    Boot:Fail("runtime:actor_registry", "rdps_actor_registry.lua is unavailable")
    return
end
if type(EventFacts) ~= "table" or type(EventFacts.WriteLegacyField) ~= "function" then
    Boot:Fail("runtime:event_facts", "rdps_event_facts.lua is unavailable")
    return
end
if type(EventBlocks) ~= "table" or type(EventBlocks.StepBackfill) ~= "function" then
    Boot:Fail("runtime:event_blocks", "rdps_event_blocks.lua is unavailable")
    return
end
if type(EventClassifications) ~= "table"
    or type(EventClassifications.WriteLegacyField) ~= "function" then
    Boot:Fail("runtime:event_classification", "rdps_event_classification.lua is unavailable")
    return
end
if type(LocalReplay) ~= "table" or type(LocalReplay.Step) ~= "function" then
    Boot:Fail("runtime:local_replay", "rdps_local_replay.lua is unavailable")
    return
end
if type(LocalStatsShadow) ~= "table" or type(LocalStatsShadow.GetStatusLine) ~= "function" then
    Boot:Fail("runtime:local_stats_shadow", "rdps_local_stats_shadow.lua is unavailable")
    return
end
if type(LocalStatsCandidate) ~= "table" or type(LocalStatsCandidate.GetStatusLine) ~= "function" then
    Boot:Fail("runtime:local_stats_candidate", "rdps_local_stats_candidate.lua is unavailable")
    return
end
if type(LocalDerivedShadow) ~= "table" or type(LocalDerivedShadow.GetStatusLine) ~= "function" then
    Boot:Fail("runtime:local_derived_shadow", "rdps_local_derived_shadow.lua is unavailable")
    return
end
if type(LocalCommitEnvelope) ~= "table" or type(LocalCommitEnvelope.GetStatusLine) ~= "function" then
    Boot:Fail("runtime:local_commit_envelope", "rdps_local_commit_envelope.lua is unavailable")
    return
end
if type(PersistenceShards) ~= "table" or type(PersistenceShards.Step) ~= "function" then
    Boot:Fail("runtime:persistence_shards", "rdps_persistence_shards.lua is unavailable")
    return
end
if type(PersistenceLoadGate) ~= "table" or type(PersistenceLoadGate.Step) ~= "function" then
    Boot:Fail("runtime:persistence_load_gate", "rdps_persistence_load_gate.lua is unavailable")
    return
end
if type(PersistenceSwitch) ~= "table" or type(PersistenceSwitch.StepMaintenance) ~= "function" then
    Boot:Fail("runtime:persistence_switch", "rdps_persistence_switch.lua is unavailable")
    return
end
if type(EventShadow) ~= "table" or type(EventShadow.ObserveClassification) ~= "function" then
    Boot:Fail("runtime:event_shadow", "rdps_event_shadow.lua is unavailable")
    return
end
Boot:SetPhase("RUNTIME_STARTING")

R.circuitBreakers = R.circuitBreakers or {}

local function RecordRuntimeSuccess(key)
    local breaker = R.circuitBreakers[key]
    if breaker == nil then return end
    breaker.failures = 0
    breaker.disabled = false
    breaker.disabledAt = nil
    breaker.retrying = nil
    breaker.lastError = nil
    breaker.warnedCritical = nil
end

local function RecordRuntimeFailure(key, err, allowDisable)
    -- A classification batch stages values without touching mirrors. Any
    -- protected runtime failure must discard that overlay before another event
    -- is processed, otherwise a stale event could retain the mutation slot.
    if type(EventClassifications) == "table"
        and type(EventClassifications.AbortMutation) == "function" then
        pcall(EventClassifications.AbortMutation, EventClassifications,
            "RUNTIME_FAILURE:" .. tostring(key or "unknown"))
    end
    local breaker = R.circuitBreakers[key] or { failures = 0, disabled = false }
    local now = U.NowMs()
    breaker.failures = (tonumber(breaker.failures) or 0) + 1
    breaker.lastError = tostring(err)
    breaker.lastFailureAt = now

    if allowDisable ~= false and breaker.failures >= 3 then
        if breaker.disabled ~= true then
            D.Diagnostics:AddWarning("circuit", key .. " disabled after 3 consecutive failures")
        end
        breaker.disabled = true
        breaker.disabledAt = now
        breaker.retrying = nil
    else
        -- COMBAT_MSG and death notifications are critical data feeds. A bad or
        -- newly introduced event shape must not permanently stop all later
        -- damage statistics. Keep reporting the error, but never open a circuit
        -- on these handlers. Also clear a disabled flag left by an older build.
        breaker.disabled = false
        breaker.disabledAt = nil
        if breaker.failures >= 3 and breaker.warnedCritical ~= true then
            breaker.warnedCritical = true
            D.Diagnostics:AddWarning("circuit", key .. " continues despite repeated event errors")
        end
    end

    R.circuitBreakers[key] = breaker
    local shouldLog = allowDisable ~= false
        or breaker.failures <= 3
        or now - (tonumber(breaker.lastLoggedAt) or 0) >= 5000
    if shouldLog then
        breaker.lastLoggedAt = now
        D.Diagnostics:AddError("runtime:" .. key, tostring(err))
    end
    return false, err
end

local function Protected(label, fn)
    local key = tostring(label or "unknown")
    local breaker = R.circuitBreakers[key]
    if breaker ~= nil and breaker.disabled == true then
        local now = U.NowMs()
        if now - (tonumber(breaker.disabledAt) or now) < C.CIRCUIT_RETRY_MS then
            return false, "circuit_open"
        end
        -- Half-open after a cooldown. One failed probe immediately reopens the
        -- circuit; one success resets it. Scanners/save/update work can therefore
        -- recover from transient client API errors without user intervention.
        breaker.disabled = false
        breaker.failures = 2
        breaker.retrying = true
        D.Diagnostics:AddInfo("circuit", key .. " retrying after cooldown")
    end
    local ok, err = xpcall(fn, Boot.SafeTraceback)
    if not ok then return RecordRuntimeFailure(key, err, true) end
    RecordRuntimeSuccess(key)
    return true
end

-- 高频 OnUpdate/扫描任务使用直接参数保护调用。与 Protected 的 xpcall
-- 闭包路径相比，这个入口不会在每个游戏帧为每个后台任务创建匿名闭包。
-- pcall 在 ArcheAge 使用的旧 Lua 版本中支持直接传参；错误本身仍包含源文件
-- 与行号，熔断、重试和诊断语义保持一致。
local function ProtectedCall(label, fn, ...)
    local key = tostring(label or "unknown")
    local breaker = R.circuitBreakers[key]
    if breaker ~= nil and breaker.disabled == true then
        local now = U.NowMs()
        if now - (tonumber(breaker.disabledAt) or now) < C.CIRCUIT_RETRY_MS then
            return false, "circuit_open"
        end
        breaker.disabled = false
        breaker.failures = 2
        breaker.retrying = true
        D.Diagnostics:AddInfo("circuit", key .. " retrying after cooldown")
    end
    local ok, result = pcall(fn, ...)
    if not ok then return RecordRuntimeFailure(key, result, true) end
    RecordRuntimeSuccess(key)
    return true, result
end

local function CriticalCall(label, fn, ...)
    local key = tostring(label or "critical")
    local breaker = R.circuitBreakers[key]
    if breaker ~= nil then breaker.disabled = false end
    local ok, result = pcall(fn, ...)
    if not ok then return RecordRuntimeFailure(key, result, false) end
    RecordRuntimeSuccess(key)
    return true, result
end

local function CriticalPreferenceSave(label, timerKey, saveFn)
    local ok = CriticalCall(label, saveFn)
    if not ok and D.State ~= nil and D.State.timers ~= nil then
        -- Preserve dirty for a later retry, but restart the debounce window.
        -- Otherwise an exception before Save*Now resets its timer retries every frame.
        D.State.timers[timerKey] = 0
    end
    return ok
end

function R:ResetCircuitBreakers()
    self.circuitBreakers = {}
    D.Diagnostics:AddInfo("circuit", "all runtime circuit breakers reset")
end

R.verifiedUnitNameCache = type(R.verifiedUnitNameCache) == "table" and R.verifiedUnitNameCache or {}
R.verifiedUnitNameCacheCount = U.TableCount(R.verifiedUnitNameCache)
R.verifiedUnitNameCacheQueue = type(R.verifiedUnitNameCacheQueue) == "table" and R.verifiedUnitNameCacheQueue or {}
R.officialUnitKindCache = type(R.officialUnitKindCache) == "table" and R.officialUnitKindCache or {}
R.officialUnitKindCacheCount = U.TableCount(R.officialUnitKindCache)
R.officialUnitKindCacheQueue = type(R.officialUnitKindCacheQueue) == "table" and R.officialUnitKindCacheQueue or {}

-- Timed caches keep one queue record per write so the oldest live value can be
-- evicted without scanning the whole cache. Repeated refreshes of the same key
-- leave stale queue records behind; without periodic rebuilding, a cache with
-- only a few live entries can still grow an unbounded sparse queue over a long
-- session. Rebuilding is rare and bounded by the live cache capacity.
local function RebuildTimedCacheQueue(cache, queueState)
    cache = type(cache) == "table" and cache or {}
    queueState = type(queueState) == "table" and queueState or {}
    local serial = math.max(0, math.floor(tonumber(queueState.serial) or 0))
    local items = {}
    for key, value in pairs(cache) do
        local entrySerial = type(value) == "table" and tonumber(value.repdpsCacheSerial) or nil
        if entrySerial == nil then
            serial = serial + 1
            entrySerial = serial
            if type(value) == "table" then value.repdpsCacheSerial = entrySerial end
        elseif entrySerial > serial then
            serial = entrySerial
        end
        items[#items + 1] = { key = key, serial = entrySerial }
    end
    table.sort(items, function(left, right)
        if left.serial ~= right.serial then return left.serial < right.serial end
        return tostring(left.key) < tostring(right.key)
    end)
    queueState.items = items
    queueState.head = 1
    queueState.tail = #items
    queueState.serial = serial
    return queueState, #items
end

local function CompactTimedCacheQueueIfNeeded(cache, queueState, maximum)
    queueState = type(queueState) == "table" and queueState or {}
    local head = math.max(1, math.floor(tonumber(queueState.head) or 1))
    local tail = math.max(0, math.floor(tonumber(queueState.tail) or 0))
    local span = math.max(0, tail - head + 1)
    local threshold = math.max(256, math.max(32, math.floor(tonumber(maximum) or 2048)) * 3)
    if span > threshold or (head > 4096 and head > math.floor(tail / 2)) then
        return RebuildTimedCacheQueue(cache, queueState)
    end
    return queueState
end

local function PutBoundedTimedCache(cache, count, key, value, now, maximum, retainedMaximum, queueState)
    cache = type(cache) == "table" and cache or {}
    count = math.max(0, math.floor(tonumber(count) or U.TableCount(cache)))
    queueState = type(queueState) == "table" and queueState or { items = {}, head = 1, tail = 0, serial = 0 }
    queueState.items = type(queueState.items) == "table" and queueState.items or {}
    queueState.head = math.max(1, math.floor(tonumber(queueState.head) or 1))
    queueState.tail = math.max(0, math.floor(tonumber(queueState.tail) or 0))
    queueState.serial = math.max(0, math.floor(tonumber(queueState.serial) or 0)) + 1
    if cache[key] == nil then count = count + 1 end
    if type(value) == "table" then value.repdpsCacheSerial = queueState.serial end
    cache[key] = value
    queueState.tail = queueState.tail + 1
    queueState.items[queueState.tail] = { key = key, serial = queueState.serial }

    maximum = math.max(32, math.floor(tonumber(maximum) or 2048))
    retainedMaximum = math.max(16, math.min(maximum, math.floor(tonumber(retainedMaximum) or maximum)))
    if count > maximum then
        while count > retainedMaximum and queueState.head <= queueState.tail do
            local queued = queueState.items[queueState.head]
            queueState.items[queueState.head] = nil
            queueState.head = queueState.head + 1
            local current = queued and cache[queued.key] or nil
            if queued ~= nil and cache[queued.key] ~= nil
                and (type(current) ~= "table" or current.repdpsCacheSerial == queued.serial) then
                cache[queued.key] = nil
                count = count - 1
            end
        end
    end
    queueState = CompactTimedCacheQueueIfNeeded(cache, queueState, maximum)
    return cache, count, queueState
end

local function GetVerifiedUnitNameById(stableId)
    local id = stableId ~= nil and tostring(stableId) or ""
    if id == "" or id == "-1" or id == "0" then return nil end
    local now = U.NowMs()
    local cached = R.verifiedUnitNameCache[id]
    if type(cached) == "table" and now <= (tonumber(cached.expiresAt) or 0) then
        return cached.name
    end
    if not Api:Has("unit.get_unit_name_by_id") then return nil end
    local value = Api:GetUnitNameById(id)
    local text = U.Trim(value)
    local ttl = text ~= "" and C.UNIT_NAME_CACHE_HIT_TTL_MS or C.UNIT_NAME_CACHE_MISS_TTL_MS
    R.verifiedUnitNameCache, R.verifiedUnitNameCacheCount, R.verifiedUnitNameCacheQueue = PutBoundedTimedCache(
        R.verifiedUnitNameCache, R.verifiedUnitNameCacheCount, id,
        { name = text ~= "" and text or nil, expiresAt = now + ttl },
        now, C.UNIT_NAME_CACHE_MAX, C.UNIT_NAME_CACHE_RETAIN, R.verifiedUnitNameCacheQueue
    )
    return text ~= "" and text or nil
end

local function IsSentinelText(trimmedText)
    local lower = string.lower(tostring(trimmedText or ""))
    return lower == "" or lower == "unknown" or lower == "未知"
        or lower == "nil" or lower == "none"
end

local function IsSentinelName(name)
    return IsSentinelText(U.Trim(name))
end

local function IsNumericSentinelText(trimmedText)
    return trimmedText == "-1" or trimmedText == "0"
end

local function IsNumericSentinel(value)
    return IsNumericSentinelText(U.Trim(value))
end

local function IsNamePresent(name)
    local text = U.Trim(name)
    return not IsSentinelText(text) and not IsNumericSentinelText(text)
end

-- Unit APIs may return cross-world names as "Name@World" while COMBAT_MSG uses
-- only "Name". Exact normalized equality remains the strongest match; a
-- short-name match is accepted only when at least one side actually carries a
-- world suffix. This avoids rejecting a valid stable ID without broadly merging
-- arbitrary same-name units.
local function SplitWorldQualifiedName(name)
    local normalized = U.NormalizeName(name)
    local short, world = string.match(normalized, "^([^@]+)@(.+)$")
    if short ~= nil and short ~= "" and world ~= nil and world ~= "" then
        return short, world, normalized
    end
    return normalized, nil, normalized
end

local function NamesEquivalentForVerifiedId(left, right)
    local leftShort, leftWorld, leftFull = SplitWorldQualifiedName(left)
    local rightShort, rightWorld, rightFull = SplitWorldQualifiedName(right)
    if leftFull == rightFull then return true end
    if leftWorld == nil and rightWorld == nil then return false end
    return leftShort ~= "" and leftShort == rightShort
end

-- Verify a name/ID pair with the official reverse lookup before it becomes a
-- temporal binding. Unit lists and target/team slots can change between two API
-- calls; binding the old name to the new ID would be worse than keeping the
-- event name-only. When verification is unavailable or inconclusive, retain the
-- visible name but discard the ID.
local function ValidateObservedNameId(name, id, source)
    local visibleName = IsNamePresent(name) and U.Trim(name) or nil
    local stableId = id ~= nil and tostring(id) ~= "" and tostring(id) or nil
    if stableId == nil or IsNumericSentinel(stableId) then return visibleName, nil, "NO_ID" end
    if not Api:Has("unit.get_unit_name_by_id") then
        return visibleName, nil, "NO_REVERSE_LOOKUP"
    end
    local resolvedName = GetVerifiedUnitNameById(stableId)
    if not IsNamePresent(resolvedName) then
        return visibleName, nil, "ID_NAME_UNAVAILABLE"
    end
    resolvedName = U.Trim(resolvedName)
    if visibleName ~= nil and not NamesEquivalentForVerifiedId(visibleName, resolvedName) then
        if D.State.config.diagnosticsEnabled then
            D.Diagnostics:AddWarning("identity_pair_mismatch", table.concat({
                tostring(source or "unit_api"), visibleName, stableId, resolvedName
            }, " | "))
        end
        return visibleName, nil, "NAME_ID_MISMATCH"
    end
    return visibleName or resolvedName, stableId, "VERIFIED_ID"
end

local function NormalizeCombatActorName(name, role)
    local text = U.Trim(name)
    local fallback = role == "target" and "未识别目标" or "未识别来源"
    -- 已经得到裁剪后的文本，直接检查，避免每个端点再次执行两轮 gsub。
    if IsSentinelText(text) then return fallback end
    -- -1/0 are not proven to mean environmental damage. Preserve such combat
    -- events under an explicit synthetic actor instead of discarding them or
    -- merging them with every other unknown source.
    if IsNumericSentinelText(text) then return fallback .. "(" .. text .. ")" end
    return text
end

local function ApplyConfiguredNameKind(entity)
    if E.ApplyChineseNameKind == nil then return false end
    return E:ApplyChineseNameKind(entity) == true
end

local function ResolveEffectiveSource(entity)
    -- No reliable owner API is published. Keep source identity unchanged.
    return entity
end

local function EventEndpointKind(event, role, entity)
    local prefix = role == "target" and "target" or "source"
    -- 类型优先级必须允许后到达的权威证据纠正旧事件：
    --   人工/名单 > 当前官方 hardKind > 事件创建时 observed kind > 临时推断。
    -- 旧实现把 observed kind 放在当前 hardKind 之前，导致某条事件早期被观察成
    -- UNKNOWN/NPC 后，即使团队、自身或人工规则后来确认 PLAYER，历史重放仍可能
    -- 继续沿用旧类型并留在 PVE。
    local manualKind = type(entity) == "table" and type(entity.manualOverride) == "table"
        and entity.manualOverride.kind or nil
    if manualKind == "PLAYER" or manualKind == "NPC" or manualKind == "MATE"
        or manualKind == "SLAVE" or manualKind == "OTHER" then
        return manualKind
    end
    local hardKind = type(entity) == "table" and entity.hardKind or nil
    if hardKind == "PLAYER" or hardKind == "NPC" or hardKind == "MATE"
        or hardKind == "SLAVE" or hardKind == "OTHER" then
        return hardKind
    end
    local observed = type(event) == "table" and event[prefix .. "ObservedKind"] or nil
    if observed == "PLAYER" or observed == "NPC" or observed == "MATE"
        or observed == "SLAVE" or observed == "OTHER" then
        return observed
    end
    return entity and entity.kind or "UNKNOWN"
end

local function IsKnownNonPlayerKindValue(kind)
    return kind == "NPC" or kind == "MATE" or kind == "SLAVE" or kind == "OTHER"
end

-- Only stable/manual Authority may be persisted into a temporal name binding.
-- Provisional inferred kinds and undocumented API samples must never become a
-- historical type fact merely because the same ID was observed again.
local function StableBindingKind(entity)
    if type(entity) ~= "table" then return nil, nil end
    if type(entity.manualOverride) == "table" and entity.manualOverride.kind ~= nil then
        return entity.manualOverride.kind, "manual_override"
    end
    if entity.hardKind ~= nil then
        local flags = type(entity.flags) == "table" and entity.flags or nil
        return entity.hardKind, flags and flags.hardKindReason or "hard_kind"
    end
    if entity.hardRelation == "SELF" or entity.hardRelation == "TEAM" then
        return "PLAYER", "team_relation"
    end
    return nil, nil
end


local function CandidateMode(source, target, event)
    if source == nil or target == nil then return "UNKNOWN" end
    local sourceKind = EventEndpointKind(event, "source", source)
    local targetKind = EventEndpointKind(event, "target", target)
    if sourceKind == "PLAYER" and targetKind == "PLAYER" then return "PVP" end
    if sourceKind == "PLAYER" and IsKnownNonPlayerKindValue(targetKind) then return "PVE" end
    if IsKnownNonPlayerKindValue(sourceKind) and targetKind == "PLAYER" then return "PVE" end
    if IsKnownNonPlayerKindValue(sourceKind) and IsKnownNonPlayerKindValue(targetKind) then return "PVE" end
    return "UNKNOWN"
end

-- Damage direction and retaliation establish relation evidence only. They do
-- not establish unit type: ordinary NPCs also attack back. rc15 therefore has
-- no combat-pattern path that can write PLAYER/NPC kind Authority.

-- v0.2.25（性能）：读取关系缓存值。缓存值可能是 false（如"非友军"），必须区分
-- "未缓存"（返回 nil，调用方回退现算）与"缓存为 false"。若直接用
-- `relCache ~= nil and relCache.sf or IsFriendlyForEvent(...)`，sf=false 时
-- `false or ...` 会继续现算，使缓存完全失效。
local function RelCacheValue(relCache, field)
    if type(relCache) == "table" and relCache[field] ~= nil then return relCache[field] end
    return nil
end

local function RelationFlagsForEvent(entity, timestamp)
    if entity == nil then return false, false end
    local relation = E:GetRelationAt(entity, timestamp)
    return relation == "SELF" or relation == "TEAM" or relation == "FRIENDLY",
        relation == "OPPONENT"
end

local function IsFriendlyForEvent(entity, timestamp)
    local friendly = RelationFlagsForEvent(entity, timestamp)
    return friendly
end

local function IsOpponentForEvent(entity, timestamp)
    local _, opponent = RelationFlagsForEvent(entity, timestamp)
    return opponent
end

local function IsSelfOrTeamPlayerAt(entity, timestamp, event, role)
    if type(entity) ~= "table" then return false end
    local relation = E:GetRelationAt(entity, timestamp)
    if relation ~= "SELF" and relation ~= "TEAM" then return false end
    return EventEndpointKind(event, role, entity) == "PLAYER"
end

local function FillRelationCache(cache, source, target, timestamp)
    cache.srcKey = source ~= nil and source.key or nil
    cache.tgtKey = target ~= nil and target.key or nil
    cache.sf, cache.so = RelationFlagsForEvent(source, timestamp)
    cache.tf, cache.to = RelationFlagsForEvent(target, timestamp)
    return cache
end

local SHARED_HEAL_BACKING_MODE = "PVE"

local function IsBossName(name)
    return D.Analysis ~= nil and type(D.Analysis.IsBoss) == "function"
        and D.Analysis:IsBoss(name) == true
end

local function ResolveHealMode(source, target, timestamp)
    -- Healing ownership is resolved by friendly/enemy relation inside ApplyHeal.
    -- PVP/PVE combat context must not delay, split or discard an otherwise valid
    -- heal. Keep one canonical backing bucket only for schema compatibility;
    -- the UI/read layer merges historical healing from both legacy buckets.
    return SHARED_HEAL_BACKING_MODE, "SHARED_HEAL_BUCKET", false
end


local function ResolveEventMode(event, source, target, relCache)
    if event.environmental == true then
        return "PVE", "ENVIRONMENT", false
    end
    -- Healing is classified only by friendly/enemy relation. PVP/PVE is an
    -- internal legacy storage concern and must not affect whether the heal counts.
    if event.category == "HEAL" then
        return ResolveHealMode(source, target, event.timestamp)
    end

    local direct = CandidateMode(source, target, event)
    if direct ~= "UNKNOWN" then
        return direct, "KIND", false
    end

    local sourceKind = EventEndpointKind(event, "source", source)
    local targetKind = EventEndpointKind(event, "target", target)

    -- A manual Boss designation is explicit user Authority and is allowed to
    -- classify an otherwise name-only target as PVE. Confirmed PLAYER evidence
    -- still wins so accidentally marking a player as Boss cannot route PVP into
    -- the PVE table.
    if targetKind ~= "PLAYER" and IsBossName(event.targetName) then
        return "PVE", "MANUAL_BOSS_TARGET", targetKind == "UNKNOWN"
    end

    local sourceFriendly = RelCacheValue(relCache, "sf")
    local targetFriendly = RelCacheValue(relCache, "tf")
    if sourceFriendly == nil then sourceFriendly = IsFriendlyForEvent(source, event.timestamp) end
    if targetFriendly == nil then targetFriendly = IsFriendlyForEvent(target, event.timestamp) end

    if sourceFriendly ~= targetFriendly then
        local otherKind = sourceFriendly and targetKind or sourceKind
        if IsKnownNonPlayerKindValue(otherKind) then
            return "PVE", "RELATION_ANCHORED_NONPLAYER", false
        end

        if event.category == "DAMAGE" then
            -- Data must not disappear merely because the allowed unit-info API
            -- did not expose a recognized type field for this client build. Use
            -- only SELF/TEAM as a narrow provisional anchor; ordinary FRIENDLY
            -- relation is not sufficient because pets/NPCs can inherit it.
            --
            -- Outgoing SELF/TEAM damage is provisionally PVE (the dominant farm
            -- path). Incoming damage to SELF/TEAM is provisionally PVP so a
            -- player hitting us appears immediately. Both are retained as
            -- modeProvisional and are fully replayable when explicit PLAYER/NPC
            -- evidence or a manual correction arrives.
            if sourceKind == "PLAYER" and targetKind == "UNKNOWN"
                and IsSelfOrTeamPlayerAt(source, event.timestamp, event, "source") then
                return "PVE", "SELF_TEAM_OUTGOING_UNKNOWN_PROVISIONAL_PVE", true
            end
            if sourceKind == "UNKNOWN" and targetKind == "PLAYER"
                and IsSelfOrTeamPlayerAt(target, event.timestamp, event, "target") then
                return "PVP", "UNKNOWN_INCOMING_TO_SELF_TEAM_PROVISIONAL_PVP", true
            end
            return "UNKNOWN", "ENDPOINT_KIND_PENDING", false
        end
    end

    -- Automatic name-level PVE hints are intentionally not classification
    -- evidence. They are mutable, can collide across same-name units and, during
    -- replay, used to apply a later observation retroactively to earlier events.
    -- Only current endpoint kinds or an explicit Boss rule may choose PVE.
    return "UNKNOWN", "UNRESOLVED", false
end

-- Final classification invariant at the Authority boundary. This protects the
-- Stats writer even if a future resolver branch accidentally returns a weak
-- mode. PVP requires two PLAYER endpoints. PVE requires at least one confirmed
-- non-player endpoint or an explicit Boss target. Anything else remains pending.
local function EnforceModeInvariant(event, source, target, mode, reason, provisional)
    if event.category == "HEAL" or event.environmental == true then
        return mode, reason, provisional
    end
    local sourceKind = EventEndpointKind(event, "source", source)
    local targetKind = EventEndpointKind(event, "target", target)
    local bothPlayers = sourceKind == "PLAYER" and targetKind == "PLAYER"
    local hasNonPlayer = IsKnownNonPlayerKindValue(sourceKind)
        or IsKnownNonPlayerKindValue(targetKind)
    local explicitBoss = targetKind ~= "PLAYER" and IsBossName(event.targetName)
    local outgoingSelfTeamFallback = mode == "PVE"
        and reason == "SELF_TEAM_OUTGOING_UNKNOWN_PROVISIONAL_PVE"
        and sourceKind == "PLAYER" and targetKind == "UNKNOWN"
        and IsSelfOrTeamPlayerAt(source, event.timestamp, event, "source")
    local incomingSelfTeamFallback = mode == "PVP"
        and reason == "UNKNOWN_INCOMING_TO_SELF_TEAM_PROVISIONAL_PVP"
        and sourceKind == "UNKNOWN" and targetKind == "PLAYER"
        and IsSelfOrTeamPlayerAt(target, event.timestamp, event, "target")

    if bothPlayers then
        return "PVP", mode == "PVP" and reason or "MODE_GUARD_PLAYER_PAIR", provisional
    end
    if outgoingSelfTeamFallback or incomingSelfTeamFallback then
        return mode, reason, true
    end
    if mode == "PVP" then
        return "UNKNOWN", "PVP_REQUIRES_TWO_PLAYERS", false
    end
    if mode == "PVE" and not hasNonPlayer and not explicitBoss then
        return "UNKNOWN", "PVE_REQUIRES_NONPLAYER_OR_BOSS", false
    end
    return mode, reason, provisional
end

-- relCache = { srcKey=, tgtKey=, sf=, tf=, so=, to= }：同一事件内只计算一次的关系
-- 快照（v0.2.25 性能）。返回 modified：本函数是否通过 ApplyStrongRelation 修改了
-- 任何实体的关系。调用方在 modified 时必须重算快照，否则下游会读到过期关系。
local function ApplyCombatEvidence(event, relCache, source, target)
    source = source or event.sourceEntity
    target = target or event.targetEntity
    local sourceFriendly = RelCacheValue(relCache, "sf")
    local targetFriendly = RelCacheValue(relCache, "tf")
    local sourceOpponent = RelCacheValue(relCache, "so")
    local targetOpponent = RelCacheValue(relCache, "to")
    if sourceFriendly == nil then sourceFriendly = IsFriendlyForEvent(source, event.timestamp) end
    if targetFriendly == nil then targetFriendly = IsFriendlyForEvent(target, event.timestamp) end
    if sourceOpponent == nil then sourceOpponent = IsOpponentForEvent(source, event.timestamp) end
    if targetOpponent == nil then targetOpponent = IsOpponentForEvent(target, event.timestamp) end
    local modified = false

    event.friendlyFire = nil
    event.opponentInternalDamage = nil
    event.healRelationConflict = nil

    if event.category == "DAMAGE" then
        if event.environmental == true then return modified end

        -- Effective damage anchored to our side is deterministic hostility. It
        -- establishes enemy relation but deliberately does not guess PLAYER/NPC.
        if targetFriendly then
            if sourceFriendly then
                event.friendlyFire = true
                if D.RelationConflicts ~= nil then
                    D.RelationConflicts:Record("FRIENDLY_FIRE", source, target, event,
                        "friendly attacked friendly; duel/force attack/faction change requires review")
                end
            elseif not sourceOpponent then
                if E:ApplyStrongRelation(source, "OPPONENT", "strong_damage_to_friendly",
                    event.timestamp, target, event) then modified = true end
            end
        end
        if sourceFriendly then
            if not targetFriendly and not targetOpponent then
                if E:ApplyStrongRelation(target, "OPPONENT", "strong_damaged_by_friendly",
                    event.timestamp, source, event) then modified = true end
            end
        end
        if sourceOpponent and targetOpponent then
            event.opponentInternalDamage = true
            if D.RelationConflicts ~= nil then
                D.RelationConflicts:Record("OPPONENT_INTERNAL_DAMAGE", source, target, event,
                    "enemy attacked enemy; third faction/duel/stale relation requires review")
            end
        end
    elseif event.category == "HEAL" then
        -- On this server an effective heal can only target the same faction.
        -- Propagate whichever side is already known; never infer unit type.
        if sourceFriendly or targetFriendly then
            if sourceOpponent or targetOpponent then
                event.healRelationConflict = true
                if D.RelationConflicts ~= nil then
                    D.RelationConflicts:Record("HEAL_RELATION_CONFLICT", source, target, event,
                        "effective heal crossed known friendly/opponent relations")
                end
            else
                if not sourceFriendly then
                    if E:ApplyStrongRelation(source, "FRIENDLY", "strong_heals_friendly",
                        event.timestamp, target, event) then modified = true end
                end
                if not targetFriendly then
                    if E:ApplyStrongRelation(target, "FRIENDLY", "strong_healed_by_friendly",
                        event.timestamp, source, event) then modified = true end
                end
            end
        elseif sourceOpponent or targetOpponent then
            if not sourceOpponent then
                if E:ApplyStrongRelation(source, "OPPONENT", "strong_heals_opponent",
                    event.timestamp, target, event) then modified = true end
            end
            if not targetOpponent then
                if E:ApplyStrongRelation(target, "OPPONENT", "strong_healed_by_opponent",
                    event.timestamp, source, event) then modified = true end
            end
        end
    end
    return modified
end

local EVENT_TYPE_PARSE_CACHE = type(R.eventTypeParseCache) == "table" and R.eventTypeParseCache or {}
R.eventTypeParseCache = EVENT_TYPE_PARSE_CACHE
R.eventTypeParseCacheCount = math.max(0, math.floor(tonumber(R.eventTypeParseCacheCount) or 0))
local EVENT_TYPE_PARSE_CACHE_LIMIT = 128

local function MatchesQualifiedEventType(upper, token)
    if upper == token then return true end
    if #upper <= #token then return false end
    local suffix = string.sub(upper, -#token - 1)
    return suffix == "." .. token or suffix == ":" .. token
        or suffix == "/" .. token or suffix == "_" .. token
end

local function IsEnvironmentalEventTypeUpper(upper)
    -- z_api_functions exposes CMF_COMBAT_ENVIRONMENTAL_DMANAGE with the
    -- historical client typo. Accept both spellings so the diagnostic event is
    -- normalized and excluded deliberately instead of being reported as an
    -- unknown parse failure.
    return MatchesQualifiedEventType(upper, "ENVIRONMENTAL_DAMAGE")
        or MatchesQualifiedEventType(upper, "ENVIRONMENTAL_DMANAGE")
end

local function GetEventTypeDescriptor(eventType)
    local raw = tostring(eventType or "")
    local cached = EVENT_TYPE_PARSE_CACHE[raw]
    if type(cached) == "table" then return cached end
    local upper = string.upper(U.Trim(raw))
    local kind = "OTHER"
    local category = "OTHER"
    local environmental = false
    if string.find(upper, "MELEE_DAMAGE", 1, true) ~= nil then
        kind, category = "MELEE", "DAMAGE"
    elseif string.find(upper, "SPELL_DAMAGE", 1, true) ~= nil then
        kind, category = "SPELL_DAMAGE", "DAMAGE"
    elseif IsEnvironmentalEventTypeUpper(upper) then
        kind, category, environmental = "ENVIRONMENT", "DAMAGE", true
    elseif string.find(upper, "SPELL_HEALED", 1, true) ~= nil
        or string.find(upper, "HEALED", 1, true) ~= nil then
        kind, category = "HEAL", "HEAL"
    elseif string.find(upper, "MISSED", 1, true) ~= nil then
        kind, category = "MISS", "MISS"
    elseif string.find(upper, "DEAD", 1, true) ~= nil then
        kind, category = "DEATH", "DEATH"
    end
    local descriptor = { kind = kind, category = category, environmental = environmental }
    if R.eventTypeParseCacheCount < EVENT_TYPE_PARSE_CACHE_LIMIT then
        EVENT_TYPE_PARSE_CACHE[raw] = descriptor
        R.eventTypeParseCacheCount = R.eventTypeParseCacheCount + 1
    end
    return descriptor
end

local function ParseAmount(eventType, abilityId, damageType, effectType)
    local descriptor = GetEventTypeDescriptor(eventType)
    local kind = descriptor.kind
    if kind == "MELEE" then
        return math.abs(tonumber(abilityId) or 0), descriptor.category, false
    end
    if kind == "SPELL_DAMAGE" then
        return math.abs(tonumber(effectType) or 0), descriptor.category, false
    end
    if kind == "ENVIRONMENT" then
        return math.abs(tonumber(damageType) or 0), descriptor.category, true
    end
    if kind == "HEAL" then
        return math.abs(tonumber(effectType) or 0), descriptor.category, false
    end
    return 0, descriptor.category, false
end

local OFFICIAL_KIND_CACHE_HIT_TTL_MS = 60000
local OFFICIAL_KIND_CACHE_MISS_TTL_MS = 1500
local OFFICIAL_KIND_CACHE_MAX = 2048
local OFFICIAL_KIND_CACHE_RETAIN = 1792

-- GetUnitInfoById is explicitly listed in the uploaded allowed API set. Its
-- complete return schema is not documented, so formal classification accepts
-- only exact unit/object kind fields and values that map to published UO_*
-- constants (or exact textual equivalents). Generic nested `type` fields,
-- class IDs, levels and positional values are never interpreted.
local OFFICIAL_KIND_FIELD_NAMES = {
    unittype = true, objecttype = true, unittypeid = true, objecttypeid = true,
    unitobjecttype = true, unitkind = true, unitkindtype = true,
}

local function MapExplicitUnitKindValue(value)
    local numeric = tonumber(value)
    if numeric ~= nil then
        local playerObjectType = tonumber(UO_CHARACTER) or tonumber(UO_PLAYER)
        if playerObjectType ~= nil and numeric == playerObjectType then return "PLAYER" end
        if tonumber(UO_NPC) ~= nil and numeric == tonumber(UO_NPC) then return "NPC" end
        if tonumber(UO_SLAVE) ~= nil and numeric == tonumber(UO_SLAVE) then return "SLAVE" end
        if tonumber(UO_MATE) ~= nil and numeric == tonumber(UO_MATE) then return "MATE" end
        if (tonumber(UO_HOUSING) ~= nil and numeric == tonumber(UO_HOUSING))
            or (tonumber(UO_TRANSFER) ~= nil and numeric == tonumber(UO_TRANSFER))
            or (tonumber(UO_SHIPYARD) ~= nil and numeric == tonumber(UO_SHIPYARD))
            or (tonumber(UO_BUTLER) ~= nil and numeric == tonumber(UO_BUTLER)) then
            return "OTHER"
        end
        return nil
    end
    if type(value) ~= "string" then return nil end
    local normalized = string.upper(U.Trim(value)):gsub("[%s_%-]", "")
    if normalized == "PLAYER" or normalized == "CHARACTER" or normalized == "PC"
        or normalized == "UOCHARACTER" then return "PLAYER" end
    if normalized == "NPC" or normalized == "MONSTER" or normalized == "MOB"
        or normalized == "UONPC" then return "NPC" end
    if normalized == "MATE" or normalized == "PET" or normalized == "MOUNT"
        or normalized == "UOMATE" then return "MATE" end
    if normalized == "SLAVE" or normalized == "SUMMON" or normalized == "SUMMONED"
        or normalized == "UOSLAVE" then return "SLAVE" end
    if normalized == "OTHER" or normalized == "HOUSING" or normalized == "TRANSFER"
        or normalized == "SHIPYARD" or normalized == "BUTLER" then return "OTHER" end
    return nil
end

local function ExtractExplicitOfficialUnitKind(info)
    if type(info) ~= "table" then return nil, "NO_TABLE" end
    local queue = { { value = info, depth = 0 } }
    local head, inspected = 1, 0
    local observedKinds = {}
    local observedCount = 0
    local function Observe(kind)
        if kind == nil or observedKinds[kind] == true then return end
        observedKinds[kind] = true
        observedCount = observedCount + 1
    end
    while head <= #queue and inspected < 64 do
        local frame = queue[head]
        head = head + 1
        for key, value in pairs(frame.value) do
            inspected = inspected + 1
            if inspected > 64 then break end
            if type(key) == "string" then
                local normalizedKey = string.lower(key):gsub("[%s_%-]", "")
                -- Root `type` is accepted for client variants that expose the
                -- unit category there. Owner type fields are deliberately not
                -- accepted: a summon owned by a player is still a summon, not a
                -- PLAYER endpoint. Collect every explicit claim and fail closed
                -- on conflicts instead of returning the first hash-order value.
                if OFFICIAL_KIND_FIELD_NAMES[normalizedKey] == true
                    or (normalizedKey == "type" and frame.depth == 0) then
                    Observe(MapExplicitUnitKindValue(value))
                elseif normalizedKey == "isplayer" and value == true then
                    Observe("PLAYER")
                elseif (normalizedKey == "isnpc" or normalizedKey == "ismonster") and value == true then
                    Observe("NPC")
                end
            end
            if frame.depth < 1 and type(value) == "table" and #queue < 12 then
                queue[#queue + 1] = { value = value, depth = frame.depth + 1 }
            end
        end
    end
    if observedCount == 1 then
        for kind in pairs(observedKinds) do return kind, "EXPLICIT_KIND" end
    end
    if observedCount > 1 then return nil, "CONFLICTING_EXPLICIT_KINDS" end
    return nil, "NO_EXPLICIT_KIND"
end

function R:ObserveOfficialUnitInfoKind(entity, stableId, visibleName, seenAt, source)
    local id = stableId ~= nil and tostring(stableId) or ""
    if type(entity) ~= "table" or id == "" or IsNumericSentinel(id) then return nil, false end
    local now = U.FiniteNumber(seenAt, nil) or U.NowMs()
    local cached = self.officialUnitKindCache[id]
    local kind = nil
    local parseState = nil
    if type(cached) == "table" and now <= (tonumber(cached.expiresAt) or 0) then
        kind = cached.kind
        parseState = cached.parseState
    else
        if not Api:Has("unit.get_unit_info_by_id") then return nil, false end
        kind, parseState = ExtractExplicitOfficialUnitKind(Api:GetUnitInfoById(id))
        local ttl = kind ~= nil and OFFICIAL_KIND_CACHE_HIT_TTL_MS or OFFICIAL_KIND_CACHE_MISS_TTL_MS
        self.officialUnitKindCache, self.officialUnitKindCacheCount, self.officialUnitKindCacheQueue =
            PutBoundedTimedCache(self.officialUnitKindCache, self.officialUnitKindCacheCount, id,
                { kind = kind, parseState = parseState, expiresAt = now + ttl }, now,
                OFFICIAL_KIND_CACHE_MAX, OFFICIAL_KIND_CACHE_RETAIN,
                self.officialUnitKindCacheQueue)
    end
    if kind == nil then
        if parseState == "CONFLICTING_EXPLICIT_KINDS"
            and D.State.config.diagnosticsEnabled == true then
            D.Diagnostics:AddWarning("unit_info_kind_conflict",
                tostring(visibleName or entity.name or id) .. " | id=" .. id)
        end
        return nil, false
    end

    local reason = tostring(source or "unit_info_by_id") .. "_explicit_unit_type"
    local kindChanged = E:SetHardKind(entity, kind, reason) == true
    local _, bindingChanged = E:RecordNameBinding(visibleName or entity.name, id, kind,
        tostring(source or "unit_info_by_id"), now, true, reason)
    local mirrorChanged, mirrorEntity = false, nil
    if kindChanged and type(E.SyncPlayerHistoryCorrectionsByName) == "function" then
        mirrorChanged, mirrorEntity = E:SyncPlayerHistoryCorrectionsByName(visibleName or entity.name)
    end
    local changed = kindChanged or bindingChanged == true or mirrorChanged == true
    if changed then
        local hasCorrectionEvidence = self:HasDormantEvidenceForEntity(entity, visibleName, id)
        if mirrorChanged == true then
            hasCorrectionEvidence = true
        end
        if (kindChanged or bindingChanged == true or mirrorChanged == true) and #(Store.sessionEvents or {}) > 0
            and (hasCorrectionEvidence or self.dormantEvidenceIndexComplete ~= true) then
            -- A newly verified stable-id/name binding can wake already-applied
            -- provisional rows even when the entity hard kind itself did not
            -- change. Pending-only retry would leave those committed rows in
            -- their old mode forever, so route material binding evidence through
            -- the same bounded transactional replay as a kind change.
            self:RequestReclassify(false, "EXPLICIT_UNIT_IDENTITY", {
                key = mirrorEntity and mirrorEntity.key or entity.key,
                name = visibleName or entity.name,
            })
        else
            D.RequestPendingReclassify()
        end
    end
    return kind, changed
end

local function IsUntrustedAutomaticKindReason(reason)
    local text = string.lower(tostring(reason or ""))
    if string.sub(text, -19) == "_explicit_unit_type" then return false end
    if string.find(text, "_official", 1, true) ~= nil then return true end
    if string.find(text, "sight_", 1, true) == 1
        and string.find(text, "_type_", 1, true) ~= nil then
        return true
    end
    return false
end

-- One-time policy migration. rc14/early rc15 could persist PLAYER/NPC kinds
-- parsed from undocumented GetUnitInfoById fields or undeclared sight rows.
-- Remove only those weak type claims while preserving stable IDs, team/self,
-- manual rules and official SELF/TEAM relation history.
function R:ClearUntrustedAutomaticKindEvidence()
    local clearedEntities, clearedBindings = 0, 0
    for _, entity in pairs(E.byKey or {}) do
        if type(entity) == "table" then
            entity.flags = entity.flags or {}
            if entity.inferredKind == "PLAYER"
                and entity.inferredKindReason == "reciprocal_damage_player" then
                entity.inferredKind = nil
                entity.inferredKindReason = nil
                entity.inferredKindAt = nil
                entity.flags.kindProvisional = nil
                if entity.hardKind == nil and not (type(entity.manualOverride) == "table"
                    and entity.manualOverride.kind ~= nil) then
                    entity.kind = "UNKNOWN"
                    entity.flags.kindReason = "unknown"
                end
                clearedEntities = clearedEntities + 1
            end
            local reason = entity.flags.hardKindReason or entity.flags.kindReason
            if entity.hardKind ~= nil and IsUntrustedAutomaticKindReason(reason) then
                entity.hardKind = nil
                entity.flags.hardKindReason = nil
                entity.flags.kindEvidenceRank = nil
                entity.flags.kindEvidenceConflict = nil
                if type(entity.manualOverride) == "table" and entity.manualOverride.kind ~= nil then
                    entity.kind = entity.manualOverride.kind
                    entity.flags.kindReason = "manual_override"
                elseif entity.hardRelation == "SELF" or entity.hardRelation == "TEAM" then
                    entity.hardKind = "PLAYER"
                    entity.flags.hardKindReason = entity.hardRelation == "SELF" and "self" or "team_slot"
                    entity.flags.kindEvidenceRank = 100
                    entity.kind = "PLAYER"
                    entity.flags.kindReason = entity.flags.hardKindReason
                else
                    entity.kind = entity.inferredKind or "UNKNOWN"
                    entity.flags.kindReason = entity.inferredKindReason or "unknown"
                    E:Resolve(entity)
                end
                clearedEntities = clearedEntities + 1
            end
        end
    end
    for _, bucket in pairs(E.nameBindings or {}) do
        if type(bucket) == "table" and type(bucket.byId) == "table" then
            for _, record in pairs(bucket.byId) do
                if type(record) == "table" then
                    local kindSource = record.kindSource or record.source
                    if record.kind ~= nil and IsUntrustedAutomaticKindReason(kindSource) then
                        record.kind = nil
                        record.kindSource = nil
                        clearedBindings = clearedBindings + 1
                    elseif record.kind ~= nil and record.kindSource == nil then
                        -- Legacy records did not keep kindSource. current_target,
                        -- combat_raw_unit and sight_* kinds came from the same
                        -- undocumented parsers, so clear only their type field;
                        -- retain the verified name<->ID interval itself. New
                        -- records with an explicit trusted kindSource (manual,
                        -- SELF/TEAM) must not be cleared merely because their
                        -- latest identity observation came from current_target.
                        local legacySource = string.lower(tostring(record.source or ""))
                        if legacySource == "current_target" or legacySource == "combat_raw_unit"
                            or string.find(legacySource, "sight_", 1, true) == 1 then
                            record.kind = nil
                            record.kindSource = nil
                            clearedBindings = clearedBindings + 1
                        end
                    end
                end
            end
        end
    end
    self.officialUnitKindCache = {}
    self.officialUnitKindCacheCount = 0
    self.officialUnitKindCacheQueue = {}
    if (clearedEntities > 0 or clearedBindings > 0) and D.State.config.diagnosticsEnabled == true then
        D.Diagnostics:AddInfo("kind_policy_migration",
            "entities=" .. tostring(clearedEntities) .. " bindings=" .. tostring(clearedBindings))
    end
    return clearedEntities, clearedBindings
end

local function ResolveRawCombatEndpoint(unitId, sourceName, targetName, timestamp)
    local rawId = unitId ~= nil and tostring(unitId) or ""
    if rawId == "" or IsNumericSentinel(rawId) then return nil, nil, nil end
    local resolvedName = GetVerifiedUnitNameById(rawId)
    if not IsNamePresent(resolvedName) then return nil, nil, nil end
    local sourceMatch = NamesEquivalentForVerifiedId(resolvedName, sourceName)
    local targetMatch = NamesEquivalentForVerifiedId(resolvedName, targetName)
    if sourceMatch == targetMatch then return nil, nil, nil end
    local role = sourceMatch and "source" or "target"
    local visibleName = sourceMatch and sourceName or targetName
    local entity = nil
    local rosterAlias = type(E.ResolveTeamNameAlias) == "function"
        and E:ResolveTeamNameAlias(visibleName, timestamp) or nil
    if type(rosterAlias) == "table" then
        local rosterId = rosterAlias.stringId ~= nil and tostring(rosterAlias.stringId) or nil
        if rosterId == rawId then
            entity = rosterAlias
        elseif rosterId == nil and type(E.PromoteTeamNameToStableId) == "function" then
            -- COMBAT_MSG commonly exposes a stable ID for the source while the
            -- native roster slot exposes only a name. Without this bridge the
            -- same healer/damage dealer becomes a TEAM teamname:* entity plus a
            -- non-team id:* entity; team scope then admits their incoming taken
            -- rows but silently rejects their outgoing damage/healing metrics.
            -- ResolveTeamNameAlias is collision-checked and resolvedName above
            -- validates the ID/name pair, so this is the same official promotion
            -- Authority used when a roster slot reveals its ID on a later scan.
            local rosterRecord = E.roster and E.roster[rosterAlias.key] or nil
            entity = E:PromoteTeamNameToStableId(
                rosterAlias.name or visibleName,
                rawId,
                type(rosterRecord) == "table" and rosterRecord.token or nil,
                timestamp
            )
        end
    end
    if type(entity) ~= "table" then entity = E:GetOrCreate(visibleName, rawId, timestamp) end
    R:ObserveOfficialUnitInfoKind(entity, rawId, visibleName, timestamp, "combat_raw_unit")
    local bindingKind, bindingKindSource = StableBindingKind(entity)
    E:RecordNameBinding(visibleName, rawId, bindingKind, "combat_raw_unit", timestamp, true, bindingKindSource)
    return role, entity, rawId
end

local function ResolveCombatProjectionEndpoint(role, rawRole, rawEntity, rawBoundId, visibleName, timestamp)
    if rawRole ~= role then
        return E:ResolveEventEntity(visibleName, nil, timestamp)
    end

    -- The raw COMBAT_MSG unit ID is valuable identity evidence, but some client
    -- layouts expose a different ID through the official team slot.  In that
    -- case ResolveRawCombatEndpoint deliberately keeps the two IDs separate.
    -- Ranking projection can still safely use the collision-checked current
    -- roster alias: its exact visible name proves this endpoint is that current
    -- team member.  Keep rawBoundId for historical replay/identity diagnostics.
    local rosterAlias = type(E.ResolveTeamNameAlias) == "function"
        and E:ResolveTeamNameAlias(visibleName, timestamp) or nil
    if type(rosterAlias) == "table" then
        return rosterAlias, "COMBAT_RAW_TEAM_ALIAS", rawBoundId
    end
    return rawEntity, "COMBAT_RAW_VERIFIED", rawBoundId
end

function R:NormalizeCombatEvent(unitId, eventType, sourceName, targetName, abilityId, abilityName,
    damageType, effectType, isActive, more, more2, more3, more4, more5, observedAt)
    local amount, category, environmental = ParseAmount(eventType, abilityId, damageType, effectType)
    -- 排队事件必须从归一化/名称绑定阶段就使用原接收时间；旧版先按当前时间
    -- 解析实体，再仅覆盖 event.timestamp，可能把历史事件绑定到后来出现的同名 ID。
    -- 实时路径同时省去第二次官方时钟查询。
    local timestamp = U.FiniteNumber(observedAt, nil) or U.NowMs()
    if environmental then
        -- The client may report the victim itself, -1, 0 or an empty value as
        -- the source of fall/drowning/fire damage.  None of those values is a
        -- combat actor.  Always normalize environmental damage to a synthetic
        -- source and keep it out of the main PVP/PVE rankings.
        sourceName = "环境"
        local rawAbilityName = U.Trim(abilityName)
        local rawAbilityId = U.Trim(abilityId)
        if rawAbilityName == "" or rawAbilityName == "HEALTH" or IsSentinelName(rawAbilityName) or IsNumericSentinel(rawAbilityName) then
            if IsSentinelName(rawAbilityId) or IsNumericSentinel(rawAbilityId) then abilityName = "环境伤害"
            else abilityName = rawAbilityId end
        end
    elseif tostring(abilityName or "") == "HEALTH" then
        abilityName = "普通攻击"
    end
    if not environmental then
        sourceName = NormalizeCombatActorName(sourceName, "source")
        targetName = NormalizeCombatActorName(targetName, "target")
    end
    local rawRole, rawEntity, rawBoundId = ResolveRawCombatEndpoint(unitId, sourceName, targetName, timestamp)
    local source, sourceBindingQuality, sourceBoundId
    local target, targetBindingQuality, targetBoundId
    source, sourceBindingQuality, sourceBoundId = ResolveCombatProjectionEndpoint(
        "source", rawRole, rawEntity, rawBoundId, sourceName, timestamp)
    target, targetBindingQuality, targetBoundId = ResolveCombatProjectionEndpoint(
        "target", rawRole, rawEntity, rawBoundId, targetName, timestamp)
    if environmental then
        E:SetHardKind(source, "OTHER", "environmental_damage")
    else
        ApplyConfiguredNameKind(source)
        ApplyConfiguredNameKind(target)
    end
    local parseStatus = "UNPARSED"
    if amount > 0 or category == "MISS" or category == "DEATH" then parseStatus = "OK" end
    -- 直接从紧凑布局创建事件：字段经 REPLAY_META.__newindex 落到位置槽，
    -- 不先分配一个几十个字符串键的哈希表、再被 PackReplayEvent 复制成紧凑表。
    -- 普通事件因此只有一张表；repdpsPacked 标记使 HandleCombatMessage 里的
    -- PackReplayEvent 走快速路径（只更新序号、清实体引用），不再复制。
    local event = EventFacts:CreateLegacyDraft(R.replayMeta or {},
        Store.nextId, timestamp, tostring(eventType or ""), category,
        U.SafeName(sourceName, "未知"), U.SafeName(targetName, "未知"),
        abilityId, U.SafeName(abilityName, category == "HEAL" and "未知治疗" or "普通攻击"),
        amount, parseStatus, environmental == true and true or nil)
    event.sourceKey = source.key
    event.targetKey = target.key
    -- rawUnitId/damageType/effectType 只参与本次解析，成功后没有任何统计、
    -- 重放或 UI 读取点。诊断/失败场景已由 rawArgs 保存，不把这三个字段
    -- 写入历史事件，避免稀有区字段把普通事件扩到 64 槽。
    -- Raw argument arrays are only needed for diagnostics or failed parses.
    -- Avoid allocating a 14-element table for every successful combat event.
    event.rawArgs = (D.State.config.diagnosticsEnabled == true or parseStatus ~= "OK")
        and { unitId, eventType, sourceName, targetName, abilityId, abilityName, damageType, effectType, isActive, more, more2, more3, more4, more5 } or nil
    EventClassifications:WriteLiveDraft(event, "UNKNOWN", "NEW",
        sourceBindingQuality, targetBindingQuality, sourceBoundId, targetBoundId,
        sourceBindingQuality == "AMBIGUOUS_TIME_BINDING",
        targetBindingQuality == "AMBIGUOUS_TIME_BINDING")
    -- verified raw ID 已保存在 sourceBoundId/targetBoundId。未来重放在当前
    -- 时间窗口找不到绑定时会使用该 storedBoundId，不需要再写一份高位
    -- authoritative 标志；这避免常见带 unitId 的事件创建稀有扩展表。
    -- applied/pending/thirdParty 的默认值均为 nil=false。不要在草稿阶段
    -- 把三个 false 写到紧凑数组尾部；成功事件只需要最终 applied=true。
    Store.nextId = Store.nextId + 1
    -- source/target 只在当前回调栈使用，不写入紧凑历史事件。把实体引用写到
    -- 58/59 槽后即使再置 nil，Lua 数组容量也不会可靠缩回；长时间团战会让
    -- 每条普通事件都退化成 64 槽数组。调用方通过额外返回值完成实时归类。
    return event, source, target
end

-- Resolve one combat-log endpoint using only evidence valid for that event time.
-- COMBAT_MSG names are not documented stable IDs, so an old id:* key is never
-- treated as authoritative unless a future caller explicitly marks it so.
local function ResolveHistoricalEndpoint(event, role)
    if type(event) ~= "table" then return nil end
    local prefix = role == "target" and "target" or "source"
    local name = event[prefix .. "Name"]
    local key = event[prefix .. "Key"]
    local qualityKey = prefix .. "BindingQuality"
    local boundKey = prefix .. "BoundId"
    local ambiguousKey = prefix .. "BindingAmbiguous"
    local authoritativeKey = prefix .. "KeyAuthoritative"
    local resolvedKey = prefix .. "ResolvedKey"

    local rememberedId = event[boundKey]
    local oldQuality = event[qualityKey]
    if rememberedId == nil and (oldQuality == "UNIQUE_TIME_BINDING"
        or oldQuality == "STORED_TIME_BINDING") then
        rememberedId = string.match(tostring(key or ""), "^id:(.+)$")
    end

    local entity, quality, resolvedId = E:ResolveEventEntity(
        name, key, event.timestamp, rememberedId,
        event[ambiguousKey] == true, event[authoritativeKey] == true
    )
    event[qualityKey] = quality
    local observedKind, kindQuality = E:ResolveNameKind(name, event.timestamp)
    event[prefix .. "ObservedKind"] = observedKind
    event[prefix .. "ObservedKindQuality"] = kindQuality
    if quality == "AMBIGUOUS_TIME_BINDING" or quality == "LOCKED_AMBIGUOUS_BINDING" then
        event[ambiguousKey] = true
    elseif resolvedId ~= nil then
        event[boundKey] = tostring(resolvedId)
    end
    event[resolvedKey] = entity and entity.key or nil
    return entity, quality, resolvedId
end

local function EmptySummary()
    return { events = 0, damage = 0, taken = 0, heal = 0 }
end

local function AddSummaryValue(summary, event, delta)
    if type(summary) ~= "table" or type(event) ~= "table" then return end
    delta = tonumber(delta) or 1
    summary.events = math.max(0, (tonumber(summary.events) or 0) + delta)
    local amount = (tonumber(event.amount) or 0) * delta
    if event.category == "DAMAGE" then
        summary.damage = math.max(0, (tonumber(summary.damage) or 0) + amount)
        summary.taken = math.max(0, (tonumber(summary.taken) or 0) + amount)
    elseif event.category == "HEAL" then
        summary.heal = math.max(0, (tonumber(summary.heal) or 0) + amount)
    end
end

local function SummaryFor(statsRoot, mode, thirdParty)
    if mode ~= "PVP" and mode ~= "PVE" then return nil end
    if type(statsRoot) ~= "table" or type(statsRoot[mode]) ~= "table" then return nil end
    local key = thirdParty and "thirdParty" or "pending"
    statsRoot[mode][key] = statsRoot[mode][key] or EmptySummary()
    return statsRoot[mode][key]
end

local function BaselineThirdParty(mode)
    local baseline = Store.baselineStats
    local summary = SummaryFor(baseline, mode, true)
    return summary or EmptySummary()
end

-- 统计写入根：分帧重放期间落到单工作副本，否则落到当前显示统计。
local function LiveStatsRoot()
    return S.replayWorkingStats or D.State.stats
end

local function TrackPendingSummary(event, deferMutation)
    if type(event) ~= "table" or event.applied == true or event.repdpsSummaryTracked == true then return end
    local mode = event.candidateMode
    if mode ~= "PVP" and mode ~= "PVE" then return end
    local thirdParty = event.thirdParty == true
    local summary = SummaryFor(LiveStatsRoot(), mode, thirdParty)
    if summary == nil then return end
    AddSummaryValue(summary, event, 1)
    event.repdpsSummaryTracked = true
    event.repdpsSummaryMode = mode
    event.repdpsSummaryThirdParty = thirdParty
    if deferMutation ~= true and S.MarkStatsMutated ~= nil then S:MarkStatsMutated(false) end
end

local function UntrackPendingSummary(event, deferMutation)
    if type(event) ~= "table" or event.repdpsSummaryTracked ~= true then return end
    local summary = SummaryFor(LiveStatsRoot(), event.repdpsSummaryMode, event.repdpsSummaryThirdParty == true)
    if summary ~= nil then AddSummaryValue(summary, event, -1) end
    event.repdpsSummaryTracked = nil
    event.repdpsSummaryMode = nil
    event.repdpsSummaryThirdParty = nil
    if deferMutation ~= true and S.MarkStatsMutated ~= nil then S:MarkStatsMutated(false) end
end

local function FreezeTrackedSummary(event)
    if type(event) ~= "table" or event.repdpsSummaryTracked ~= true then return end
    -- Current live stats already include this event. Copy the same contribution
    -- into the replay baseline, then clear only the tracking marker so a future
    -- rebuild starts with the frozen aggregate without double-counting it now.
    local baseline = SummaryFor(Store.baselineStats, event.repdpsSummaryMode, event.repdpsSummaryThirdParty == true)
    if baseline ~= nil then AddSummaryValue(baseline, event, 1) end
    event.repdpsSummaryTracked = nil
    event.repdpsSummaryMode = nil
    event.repdpsSummaryThirdParty = nil
end

function R:RecomputePendingSummaries()
    for _, mode in ipairs({ "PVP", "PVE" }) do
        -- forWrite=true：重放收尾阶段写到工作副本，避免 UI 读到半重放摘要。
        local m = S:GetMode(mode, true)
        m.pending = EmptySummary()
        -- Frozen third-party aggregates live in baselineStats. Active five-second
        -- correction-window events are added on top below.
        local frozen = BaselineThirdParty(mode)
        m.thirdParty = {
            events = tonumber(frozen.events) or 0,
            damage = tonumber(frozen.damage) or 0,
            taken = tonumber(frozen.taken) or 0,
            heal = tonumber(frozen.heal) or 0,
        }
    end
    local thirdPartyCount = 0
    local validPending = {}
    for _, event in ipairs(type(Store.pending) == "table" and Store.pending or {}) do
        if type(event) == "table" then
            event.repdpsSummaryTracked = nil
            event.repdpsSummaryMode = nil
            event.repdpsSummaryThirdParty = nil
            if event.applied ~= true and event.retiredThirdParty ~= true then
                validPending[#validPending + 1] = event
                TrackPendingSummary(event, true)
                if event.thirdParty == true then thirdPartyCount = thirdPartyCount + 1 end
            end
        end
    end
    Store.pending = validPending
    Store.pendingCursor = 1
    D.Diagnostics.counters.pendingEvents = #(Store.pending or {})
    D.Diagnostics.counters.thirdPartyEvents = thirdPartyCount
    if S.MarkStatsMutated ~= nil then S:MarkStatsMutated(false) end
end

local ReplaceSessionEvent

------------------------------------------------------------------------
-- 可纠错事件证据索引
--
-- 除第三方/待确认事件外，已经写入 Stats 的 provisional 事件同样必须被
-- 索引。后到达的官方 PLAYER/NPC 证据若只重试 pending，错误的临时贡献
-- 不会从原面板撤销。这里索引所有仍可由身份证据改变结果的事件端点；命中
-- 后请求空闲期分帧完整重放。索引是派生缓存，可分帧重建，不影响统计真值。
------------------------------------------------------------------------
R.dormantEvidenceIndex = type(R.dormantEvidenceIndex) == "table" and R.dormantEvidenceIndex or {}
R.dormantEvidenceIndexGeneration = math.floor(tonumber(R.dormantEvidenceIndexGeneration) or -1)
R.dormantEvidenceIndexCursor = math.max(1, math.floor(tonumber(R.dormantEvidenceIndexCursor) or 1))
R.dormantEvidenceIndexComplete = R.dormantEvidenceIndexComplete == true

local function AddDormantEvidenceToken(runtime, token)
    if type(token) ~= "string" or token == "" then return end
    runtime.dormantEvidenceIndex[token] = true
end

local function RegisterDormantEvidenceEvent(runtime, event)
    if type(runtime) ~= "table" or type(event) ~= "table" then return end
    for _, prefix in ipairs({ "source", "target" }) do
        local key = event[prefix .. "ResolvedKey"] or event[prefix .. "Key"]
        if type(key) == "string" and key ~= "" then
            AddDormantEvidenceToken(runtime, "key:" .. key)
        end
        local name = U.NormalizeName(event[prefix .. "Name"])
        if name ~= "" then AddDormantEvidenceToken(runtime, "name:" .. name) end
    end
end

function R:ResetDormantEvidenceIndex(complete)
    self.dormantEvidenceIndex = {}
    self.dormantEvidenceIndexGeneration = math.floor(tonumber(Store.identityGeneration) or 0)
    self.dormantEvidenceIndexCursor = 1
    self.dormantEvidenceIndexComplete = complete == true
end

function R:StepDormantEvidenceIndex(eventBudget)
    local generation = math.floor(tonumber(Store.identityGeneration) or 0)
    if self.dormantEvidenceIndexGeneration ~= generation then
        self:ResetDormantEvidenceIndex(false)
    end
    if self.dormantEvidenceIndexComplete == true then return true end
    local events = Store.sessionEvents or {}
    local cursor = math.max(1, math.floor(tonumber(self.dormantEvidenceIndexCursor) or 1))
    local budget = math.max(1, math.floor(tonumber(eventBudget) or 500))
    local processed = 0
    while cursor <= #events and processed < budget do
        local event = events[cursor]
        if type(event) == "table" and (event.dormantThirdParty == true or event.dormantPending == true
            or (event.applied == true
                and (event.modeProvisional == true or event.relationProvisional == true))) then
            RegisterDormantEvidenceEvent(self, event)
        end
        cursor = cursor + 1
        processed = processed + 1
    end
    self.dormantEvidenceIndexCursor = cursor
    if cursor > #events then
        self.dormantEvidenceIndexComplete = true
        return true
    end
    return false
end

function R:HasDormantEvidenceForEntity(entity, visibleName, stableId)
    local index = self.dormantEvidenceIndex
    if type(index) ~= "table" then return false end
    local key = type(entity) == "table" and entity.key or nil
    if type(key) == "string" and index["key:" .. key] == true then return true end
    if stableId ~= nil and index["key:id:" .. tostring(stableId)] == true then return true end
    local name = U.NormalizeName(visibleName or (type(entity) == "table" and entity.name or nil))
    return name ~= "" and index["name:" .. name] == true
end

local function RetireOverflowItem(runtime, item)
    if type(item) ~= "table" then return end
    if item.thirdParty == true then
        -- Stop actively retrying, but keep the compact replay event. Manual
        -- correction or stronger official-unit evidence can still wake it and
        -- move the historical amount into the correct ranking.
        if item.repdpsSummaryTracked ~= true then TrackPendingSummary(item) end
        if item.repdpsSummaryTracked == true then FreezeTrackedSummary(item) end
        item.dormantThirdParty = true
        item.dormantSummaryMode = item.candidateMode
        item.retiredThirdParty = false
        item.applied = false
        item.pending = false
        item.classificationStatus = "THIRD_PARTY_DORMANT_CAP"
        RegisterDormantEvidenceEvent(runtime, item)
        runtime.retiredThirdPartySinceCompact =
            (tonumber(runtime.retiredThirdPartySinceCompact) or 0) + 1
        ReplaceSessionEvent(item, false)
        return
    end

    UntrackPendingSummary(item)
    item.pending = false
    item.dormantPending = true
    item.evictedPending = nil
    item.classificationStatus = "PENDING_DORMANT_CAP"
    RegisterDormantEvidenceEvent(runtime, item)
    ReplaceSessionEvent(item, false)
end

function R:TrimPendingOverflow(dropBudgetOverride)
    Store.pending = Store.pending or {}
    local pending = Store.pending
    local count = #pending
    local maximum = math.max(1, math.floor(tonumber(C.MAX_PENDING_EVENTS) or 3000))
    local hysteresis = math.max(0, math.floor(tonumber(C.PENDING_TRIM_HYSTERESIS) or 100))

    -- 大型战斗中 pending 可能长期贴着上限。旧实现每增加约 100 条事件就
    -- 扫描并重建整张 3000 行数组，形成可重复的 GC 峰值。现在只登记一个
    -- “降到低水位”的任务，每次事件/更新帧最多原地淘汰少量元素。
    if count > maximum and self.pendingTrimTarget == nil then
        self.pendingTrimTarget = math.max(0, maximum - hysteresis)
        self.pendingTrimCursor = math.max(1, math.floor(tonumber(self.pendingTrimCursor) or 1))
    end
    local target = tonumber(self.pendingTrimTarget)
    if target == nil then
        D.Diagnostics.counters.pendingEvents = count
        return 0
    end
    if count <= target then
        self.pendingTrimTarget = nil
        self.pendingTrimCursor = 1
        D.Diagnostics.counters.pendingEvents = count
        return 0
    end

    local budget = math.max(1, math.floor(tonumber(dropBudgetOverride)
        or tonumber(C.PENDING_TRIM_BATCH) or 8))
    local dropped = 0
    local cursor = math.max(1, math.floor(tonumber(self.pendingTrimCursor) or 1))
    if cursor > count then cursor = 1 end

    -- 每次在一个小窗口内优先淘汰 third-party/损坏项；找不到时才淘汰当前
    -- 待确认项。窗口固定，因此单次复杂度不随 pending 总量增长。
    local searchWindow = 24
    while count > target and dropped < budget do
        if count <= 0 then break end
        if cursor > count then cursor = 1 end
        local chosen = cursor
        for offset = 0, math.min(searchWindow - 1, count - 1) do
            local index = ((cursor + offset - 1) % count) + 1
            local item = pending[index]
            if type(item) ~= "table" or item.thirdParty == true
                or item.dormantPending == true or item.dormantThirdParty == true then
                chosen = index
                break
            end
        end

        local item = pending[chosen]
        local wasThirdParty = type(item) == "table" and item.thirdParty == true
        RetireOverflowItem(self, item)
        local last = pending[count]
        pending[count] = nil
        count = count - 1
        if chosen <= count then pending[chosen] = last end
        if wasThirdParty then
            D.Diagnostics.counters.thirdPartyEvents = math.max(0,
                (tonumber(D.Diagnostics.counters.thirdPartyEvents) or 0) - 1)
        end
        dropped = dropped + 1
        cursor = chosen
        if cursor > count then cursor = 1 end
    end

    self.pendingTrimCursor = cursor
    if count <= target then
        self.pendingTrimTarget = nil
        self.pendingTrimCursor = 1
    end
    D.Diagnostics.counters.droppedPendingEvents =
        (tonumber(D.Diagnostics.counters.droppedPendingEvents) or 0) + dropped
    D.Diagnostics.counters.pendingEvents = count
    return dropped
end

function R:QueuePending(event)
    if type(event) ~= "table" then return end
    event.repdpsRetryCount = math.max(0, math.floor(tonumber(event.repdpsRetryCount) or 0))
    event.repdpsNextRetryAt = tonumber(event.repdpsNextRetryAt) or (U.NowMs() + 500)
    Store:PushPending(event)
    TrackPendingSummary(event)
    if event.thirdParty == true then
        D.Diagnostics.counters.thirdPartyEvents =
            (tonumber(D.Diagnostics.counters.thirdPartyEvents) or 0) + 1
    end
    self:TrimPendingOverflow()
end

local function IsTeamScopeMode()
    return D.State ~= nil and D.State.config ~= nil and D.State.config.scopeMode == "team"
end

local function IsFormalTeamScopeActor(entity, timestamp)
    if not IsTeamScopeMode() then return true end
    if type(entity) ~= "table" then return false end
    local relation = E:GetRelationAt(entity, timestamp)
    return relation == "SELF" or relation == "TEAM"
end

local function AddScopedMetric(mode, sideName, entity, metric, amount, event, primary)
    if not IsFormalTeamScopeActor(entity, event and event.timestamp or nil) then
        if type(event) == "table" then event.scopeContextOnly = true end
        D.Diagnostics.counters.scopeContextOnlyMetrics =
            (tonumber(D.Diagnostics.counters.scopeContextOnlyMetrics) or 0) + 1
        return false
    end
    S:AddMetric(mode, sideName, entity, metric, amount, event, primary)
    return true
end

local function ApplyScopedDamagePair(mode, sourceSide, targetSide, source, target, event, reason)
    local sourceWritten = AddScopedMetric(mode, sourceSide, source, "damage", event.amount, event, true)
    local targetWritten = AddScopedMetric(mode, targetSide, target, "taken", event.amount, event)
    if not sourceWritten and not targetWritten then
        -- A route can be semantically resolved before a freshly observed team
        -- member has acquired a stable TEAM relation.  Treat that as pending,
        -- rather than applied, so a roster scan can replay the retained event.
        return false, nil, nil, "DAMAGE_OUTSIDE_TEAM_SCOPE"
    end
    return true, sourceSide, targetSide, reason
end

local function ApplyDamage(event, mode, relCache, source, target)
    source = source or event.sourceEntity
    target = target or event.targetEntity
    local modeStats = S:GetMode(mode, true)
    if event.expiredModes ~= nil and event.expiredModes[mode] == true then
        event.classificationStatus = "EXPIRED_" .. mode
        return true, nil, nil, nil
    end
    if event.timestamp < (tonumber(modeStats.epochStart) or 0) then
        EventClassifications:SetExpiredMode(event, mode, true, "MODE_EPOCH_EXPIRED")
        event.classificationStatus = "EXPIRED_" .. mode
        return true, nil, nil, nil
    end

    local sourceFriendly = RelCacheValue(relCache, "sf")
    local targetFriendly = RelCacheValue(relCache, "tf")
    local sourceOpponent = RelCacheValue(relCache, "so")
    local targetOpponent = RelCacheValue(relCache, "to")
    if sourceFriendly == nil then sourceFriendly = IsFriendlyForEvent(source, event.timestamp) end
    if targetFriendly == nil then targetFriendly = IsFriendlyForEvent(target, event.timestamp) end
    if sourceOpponent == nil then sourceOpponent = IsOpponentForEvent(source, event.timestamp) end
    if targetOpponent == nil then targetOpponent = IsOpponentForEvent(target, event.timestamp) end

    if sourceFriendly and not targetFriendly then
        return ApplyScopedDamagePair(mode, "friendly", "enemy", source, target, event, nil)
    end
    if targetFriendly and not sourceFriendly then
        return ApplyScopedDamagePair(mode, "enemy", "friendly", source, target, event, nil)
    end
    if sourceFriendly and targetFriendly then
        event.friendlyFire = true
        return ApplyScopedDamagePair(mode, "friendly", "friendly", source, target, event, nil)
    end

    local sourceKind = EventEndpointKind(event, "source", source)
    local targetKind = EventEndpointKind(event, "target", target)

    if mode == "PVE"
        and event.modeReason == "SELF_TEAM_OUTGOING_UNKNOWN_PROVISIONAL_PVE"
        and sourceKind == "PLAYER" and targetKind == "UNKNOWN"
        and sourceFriendly and not targetFriendly then
        event.modeProvisional = true
        event.relationProvisional = true
        event.provisionalFallbackMode = "SELF_TEAM_OUTGOING_UNKNOWN_PROVISIONAL_PVE"
        return ApplyScopedDamagePair(mode, "friendly", "enemy", source, target, event,
            "SELF_TEAM_OUTGOING_UNKNOWN_PROVISIONAL_PVE")
    end

    if mode == "PVP"
        and event.modeReason == "UNKNOWN_INCOMING_TO_SELF_TEAM_PROVISIONAL_PVP"
        and sourceKind == "UNKNOWN" and targetKind == "PLAYER"
        and targetFriendly and not sourceFriendly then
        event.modeProvisional = true
        event.relationProvisional = true
        event.provisionalFallbackMode = "UNKNOWN_INCOMING_TO_SELF_TEAM_PROVISIONAL_PVP"
        return ApplyScopedDamagePair(mode, "enemy", "friendly", source, target, event,
            "UNKNOWN_INCOMING_TO_SELF_TEAM_PROVISIONAL_PVP")
    end

    -- Data-first PVP anchor: official/manual PLAYER kinds already prove the
    -- event belongs to PVP.  When exactly one endpoint has a known OPPONENT
    -- relation, use it as the side anchor and provisionally place the other
    -- player on our side instead of dropping a valid outside-player event into
    -- pending.  This is common when a green player outside the raid attacks a
    -- known red player, or a known red player attacks a green player not yet
    -- observed by roster/sight APIs.  No permanent relation is written here;
    -- recent events remain correctable by manual rules/full replay.
    if mode == "PVP"
        and EventEndpointKind(event, "source", source) == "PLAYER"
        and EventEndpointKind(event, "target", target) == "PLAYER" then
        if targetOpponent and not sourceOpponent and not sourceFriendly then
            event.relationProvisional = true
            event.modeProvisional = true
            return ApplyScopedDamagePair(mode, "friendly", "enemy", source, target, event,
                "PVP_TARGET_OPPONENT_ANCHOR")
        end
        if sourceOpponent and not targetOpponent and not targetFriendly then
            event.relationProvisional = true
            event.modeProvisional = true
            return ApplyScopedDamagePair(mode, "enemy", "friendly", source, target, event,
                "PVP_SOURCE_OPPONENT_ANCHOR")
        end

        -- rc9 data-first outside-player fallback: both endpoints are confirmed
        -- PLAYERs, but neither has a usable friendly/opponent relation.  The
        -- client API cannot expose the green-name faction state for arbitrary
        -- nearby players, so keeping this event in third-party/pending makes
        -- same-faction duels invisible.  Admit the event provisionally to our
        -- PVP friendly side (damage + taken) without writing any permanent
        -- relation.  A later manual FRIENDLY/OPPONENT correction can still
        -- replay the retained journal and move the event to the exact sides.
        if not sourceFriendly and not targetFriendly
            and not sourceOpponent and not targetOpponent then
            event.friendlyFire = true
            event.relationProvisional = true
            event.modeProvisional = true
            event.provisionalFallbackMode = "PVP_UNKNOWN_PLAYER_PAIR_AS_FRIENDLY"
            return ApplyScopedDamagePair(mode, "friendly", "friendly", source, target, event,
                "PVP_UNKNOWN_PLAYER_PAIR_AS_FRIENDLY")
        end
    end

    if sourceOpponent and targetOpponent then
        event.thirdParty = true
        return false, nil, nil, "OPPONENT_INTERNAL_DAMAGE"
    end

    if mode == "PVE" then
        local targetPve = IsKnownNonPlayerKindValue(targetKind)
            or (targetKind ~= "PLAYER" and IsBossName(event.targetName))

        -- A confirmed non-player or explicit Boss target makes the mode certain
        -- even when an outside friendly attacker's type/relation is incomplete.
        -- Automatic name hints are excluded: they cannot prove identity.
        if targetPve and not sourceOpponent and not IsKnownNonPlayerKindValue(sourceKind) then
            if not sourceFriendly then
                -- The target proves PVE, but the attacker's Side is still only a
                -- data-first guess. Preserve that distinction even when the
                -- attacker is already known PLAYER so later OPPONENT evidence can
                -- replay this committed row out of the friendly table.
                event.relationProvisional = true
                event.provisionalFallbackMode = "PVE_TARGET_NONPLAYER_SOURCE_RELATION_UNKNOWN_AS_FRIENDLY"
            end
            if sourceKind ~= "PLAYER" then
                event.modeProvisional = true
            end
            return ApplyScopedDamagePair(mode, "friendly", "enemy", source, target, event, nil)
        end

        local sourcePve = IsKnownNonPlayerKindValue(sourceKind)
        if sourcePve and not targetOpponent and not IsKnownNonPlayerKindValue(targetKind) then
            if not targetFriendly then
                event.relationProvisional = true
                event.provisionalFallbackMode = "PVE_SOURCE_NONPLAYER_TARGET_RELATION_UNKNOWN_AS_FRIENDLY"
            end
            if targetKind ~= "PLAYER" then
                event.modeProvisional = true
            end
            return ApplyScopedDamagePair(mode, "enemy", "friendly", source, target, event, nil)
        end
    end
    return false, nil, nil, "UNRESOLVED_DAMAGE_ROUTE"
end

local function ApplyHeal(event, mode, relCache, source, target)
    source = source or event.sourceEntity
    target = target or event.targetEntity
    mode = SHARED_HEAL_BACKING_MODE
    local pvpMode = S:GetMode("PVP", true)
    local pveMode = S:GetMode("PVE", true)
    local sharedEpochStart = math.max(
        tonumber(pvpMode and pvpMode.epochStart) or 0,
        tonumber(pveMode and pveMode.epochStart) or 0
    )
    if event.expiredModes ~= nil and event.expiredModes[mode] == true then
        event.classificationStatus = "EXPIRED_SHARED_HEAL"
        return true, nil, nil, nil
    end
    if event.timestamp < sharedEpochStart then
        EventClassifications:SetExpiredMode(event, mode, true, "MODE_EPOCH_EXPIRED")
        event.classificationStatus = "EXPIRED_SHARED_HEAL"
        return true, nil, nil, nil
    end

    local sourceFriendly = RelCacheValue(relCache, "sf")
    local targetFriendly = RelCacheValue(relCache, "tf")
    local sourceOpponent = RelCacheValue(relCache, "so")
    local targetOpponent = RelCacheValue(relCache, "to")
    if sourceFriendly == nil then sourceFriendly = IsFriendlyForEvent(source, event.timestamp) end
    if targetFriendly == nil then targetFriendly = IsFriendlyForEvent(target, event.timestamp) end
    if sourceOpponent == nil then sourceOpponent = IsOpponentForEvent(source, event.timestamp) end
    if targetOpponent == nil then targetOpponent = IsOpponentForEvent(target, event.timestamp) end

    if sourceFriendly and targetFriendly then
        if not AddScopedMetric(mode, "friendly", source, "heal", event.amount, event) then
            return false, nil, nil, "HEAL_SOURCE_OUTSIDE_TEAM_SCOPE"
        end
        return true, "friendly", "friendly", nil
    end
    if sourceOpponent and targetOpponent then
        if not AddScopedMetric(mode, "enemy", source, "heal", event.amount, event) then
            return false, nil, nil, "HEAL_SOURCE_OUTSIDE_TEAM_SCOPE"
        end
        return true, "enemy", "enemy", nil
    end

    -- rc3：治疗量优先入榜。有效治疗在本服务器通常意味着同势力关系；
    -- 即使当前只确认一端或两端均未扫描，也先按来源/已知端推断并标记临时。
    -- 关系冲突不再直接丢到 pending，而是保留数值等待人工纠错。
    event.relationProvisional = true
    event.modeProvisional = true
    if (sourceFriendly and targetOpponent) or (sourceOpponent and targetFriendly) then
        event.healRelationConflict = true
    end
    local sideName
    if sourceFriendly then sideName = "friendly"
    elseif sourceOpponent then sideName = "enemy"
    elseif targetFriendly then sideName = "friendly"
    elseif targetOpponent then sideName = "enemy"
    else sideName = "friendly" end
    if not AddScopedMetric(mode, sideName, source, "heal", event.amount, event) then
        return false, nil, nil, "HEAL_SOURCE_OUTSIDE_TEAM_SCOPE"
    end
    return true, sideName, sideName, event.healRelationConflict and "HEAL_CONFLICT_DATA_FIRST" or nil
end

local function ApplyKill(event, mode, relCache, source, target)
    source = source or event.sourceEntity
    target = target or event.targetEntity
    local modeStats = S:GetMode(mode, true)
    if event.expiredModes ~= nil and event.expiredModes[mode] == true then
        event.classificationStatus = "EXPIRED_" .. mode
        return true, nil, nil, nil
    end
    if event.timestamp < (tonumber(modeStats.epochStart) or 0) then
        EventClassifications:SetExpiredMode(event, mode, true, "MODE_EPOCH_EXPIRED")
        event.classificationStatus = "EXPIRED_" .. mode
        return true, nil, nil, nil
    end

    -- v0.2.25（性能）：同一事件内关系已经计算过一次并传入（relCache），直接复用。
    local sourceFriendly = RelCacheValue(relCache, "sf")
    local targetFriendly = RelCacheValue(relCache, "tf")
    if sourceFriendly == nil then sourceFriendly = IsFriendlyForEvent(source, event.timestamp) end
    if targetFriendly == nil then targetFriendly = IsFriendlyForEvent(target, event.timestamp) end
    if sourceFriendly and not targetFriendly then
        AddScopedMetric(mode, "friendly", source, "kills", 1, event)
        return true, "friendly", nil, nil
    end
    if targetFriendly and not sourceFriendly then
        AddScopedMetric(mode, "enemy", source, "kills", 1, event)
        return true, "enemy", nil, nil
    end

    -- Keep inferred last-hit ownership consistent with the corresponding PVE
    -- damage path. Otherwise an outside player can accumulate Boss damage but
    -- never receive the inferred last hit solely because no permanent FRIENDLY
    -- relation was established. Explicit opponents are never placed on our side.
    if mode == "PVE" then
        local sourceOpponent = RelCacheValue(relCache, "so")
        local targetOpponent = RelCacheValue(relCache, "to")
        if sourceOpponent == nil then sourceOpponent = IsOpponentForEvent(source, event.timestamp) end
        if targetOpponent == nil then targetOpponent = IsOpponentForEvent(target, event.timestamp) end
        local sourceKind = EventEndpointKind(event, "source", source)
        local targetKind = EventEndpointKind(event, "target", target)
        if sourceKind == "PLAYER" and IsKnownNonPlayerKindValue(targetKind)
            and not sourceOpponent then
            AddScopedMetric(mode, "friendly", source, "kills", 1, event)
            return true, "friendly", nil, nil
        end
        if IsKnownNonPlayerKindValue(sourceKind) and targetKind == "PLAYER"
            and not targetOpponent then
            AddScopedMetric(mode, "enemy", source, "kills", 1, event)
            return true, "enemy", nil, nil
        end
    end
    return false, nil, nil, "UNRESOLVED_KILL_ROUTE"
end

local function CallEventBlocks(methodName, ...)
    if D.State == nil or D.State.config == nil
        or D.State.config.diagnosticsEnabled ~= true then return nil end
    local method = type(EventBlocks) == "table" and EventBlocks[methodName] or nil
    if type(method) ~= "function" or EventBlocks.failed == true then return nil end
    local ok, result = pcall(method, EventBlocks, ...)
    if not ok then
        if type(EventBlocks.DisableAfterFailure) == "function" then
            pcall(EventBlocks.DisableAfterFailure, EventBlocks, result)
        end
        return nil
    end
    return result
end

local function CallLocalReplay(methodName, ...)
    if D.State == nil or D.State.config == nil
        or D.State.config.diagnosticsEnabled ~= true then return nil end
    local method = type(LocalReplay) == "table" and LocalReplay[methodName] or nil
    if type(method) ~= "function" or LocalReplay.failed == true then return nil end
    local ok, result = pcall(method, LocalReplay, ...)
    if not ok then
        if type(LocalReplay.DisableAfterFailure) == "function" then
            pcall(LocalReplay.DisableAfterFailure, LocalReplay, result)
        end
        return nil
    end
    return result
end

local function CallEventShadow(methodName, ...)
    if D.State == nil or D.State.config == nil
        or D.State.config.diagnosticsEnabled ~= true then return nil end
    local method = type(EventShadow) == "table" and EventShadow[methodName] or nil
    if type(method) ~= "function" or EventShadow.failed == true then return nil end
    local ok, result = pcall(method, EventShadow, ...)
    if not ok then
        if type(EventShadow.DisableAfterFailure) == "function" then
            pcall(EventShadow.DisableAfterFailure, EventShadow, result)
        end
        return nil
    end
    return result
end

local function InferClassificationContext(runtime, event, refreshCombatEvidence,
    providedSource, providedTarget, explicitContext, previousStatus)
    if explicitContext ~= nil and tostring(explicitContext) ~= "" then
        return tostring(explicitContext)
    end
    if type(EventShadow.transaction) == "table" then
        return tostring(EventShadow.transaction.reason or "FULL_REPLAY")
    end
    if previousStatus == "ROLLBACK_REAPPLY" then return "ROLLBACK_REAPPLY" end
    if refreshCombatEvidence == true then return "PENDING_RETRY" end
    if type(providedSource) == "table" and type(providedTarget) == "table" then
        return runtime.processingReplayQueue == true and "REPLAY_DRAIN_LIVE" or "LIVE"
    end
    if event ~= nil and event.dormantPending == true then return "DORMANT_RETRY" end
    return "HISTORICAL_RETRY"
end

local function TryClassifyAndApplyAuthority(self, event, refreshCombatEvidence, relCache, evidenceModified,
    reuseResolvedEndpoints, providedRawSource, providedSource, providedTarget, liveNormalized)
    if type(event) ~= "table" then return false end
    if event.applied == true then return true end

    -- Live parsing already normalizes these fields. This guard protects hot
    -- reload/replay journals from an older or partially corrupted in-memory
    -- event so one bad row cannot disable all later reclassification work.
    local validTimestamp = U.FiniteNumber(event.timestamp, nil)
    if validTimestamp == nil then validTimestamp = U.NowMs() end
    local normalizedAmount = math.abs(U.FiniteNumber(event.amount, 0) or 0)
    local category = event.category
    if category ~= "DAMAGE" and category ~= "HEAL" and category ~= "KILL"
        and category ~= "MISS" and category ~= "DEATH" and category ~= "OTHER" then
        category = string.upper(tostring(category or "OTHER"))
    end
    if category ~= "DAMAGE" and category ~= "HEAL" and category ~= "KILL"
        and category ~= "MISS" and category ~= "DEATH" and category ~= "OTHER" then
        category = "OTHER"
    end
    if liveNormalized ~= true then
        EventFacts:RepairForClassification(event, validTimestamp, normalizedAmount, category,
            "CLASSIFICATION_SANITIZE")
    end
    if type(event.expiredModes) ~= "table" then event.expiredModes = nil end
    -- Mode belongs to this CombatEvent, never to the Actor.  Clear the prior
    -- committed mode before every retry/replay so a player who previously dealt
    -- PVP damage can still have a later NPC hit committed independently to PVE
    -- (and vice versa).  Only a successful projection below may set it again.
    event.appliedMode = nil
    if (event.category == "DAMAGE" or event.category == "HEAL") and event.amount <= 0 then
        event.applied = true
        event.pending = false
        event.thirdParty = false
        event.classificationStatus = "INVALID_REPLAY_AMOUNT"
        return true
    end

    -- These are outcomes of one classification attempt, not permanent facts.
    -- Clear them before every replay so a formerly conflicting/friendly-fire
    -- event cannot retain stale diagnostics after relations are corrected.
    event.healRelationConflict = nil
    event.friendlyFire = nil
    event.relationProvisional = nil
    event.provisionalFallbackMode = nil

    -- Historical replay must re-evaluate name/ID evidence because later official
    -- observations can reveal a same-name conflict. The live event path has just
    -- completed the same resolution in NormalizeCombatEvent, so resolving both
    -- endpoints again here doubles name normalization, binding lookup and entity
    -- access for every combat message. Reuse those exact same-timestamp objects
    -- only for the synchronous live attempt; persisted/retried events still take
    -- the full historical path below.
    local rawSource = providedRawSource
    local source = providedSource
    local target = providedTarget
    if type(source) == "table" and type(target) == "table" then
        rawSource = type(rawSource) == "table" and rawSource or source
        event.sourceResolvedKey = source.key
        event.targetResolvedKey = target.key
    elseif reuseResolvedEndpoints == true
        and type(event.rawSourceEntity or event.sourceEntity) == "table"
        and type(event.targetEntity) == "table" then
        rawSource = event.rawSourceEntity or event.sourceEntity
        source = ResolveEffectiveSource(rawSource)
        target = event.targetEntity
        event.sourceResolvedKey = source and source.key or nil
        event.targetResolvedKey = target and target.key or nil
    else
        rawSource = ResolveHistoricalEndpoint(event, "source")
        source = ResolveEffectiveSource(rawSource)
        target = ResolveHistoricalEndpoint(event, "target")
        event.sourceResolvedKey = source and source.key or nil
        event.targetResolvedKey = target and target.key or nil
    end
    if liveNormalized ~= true then
        ApplyConfiguredNameKind(rawSource)
        ApplyConfiguredNameKind(target)
    end

    -- v0.2.25（性能）：关系快照贯穿整个事件链路。调用方（live 路径）可能已经
    -- 计算并传入 relCache（含端点 key 校验）；重放/纠错路径未传则在此现算。
    -- 证据（ApplyCombatEvidence）可能通过 ApplyStrongRelation 修改关系，因此
    -- 它之后必须用最新关系；而 ResolveEventMode/ApplyDamage/ApplyHeal/ApplyKill/
    -- 第三方判断之间关系不再变化，全部复用同一快照。旧实现每个事件最多重复
    -- 多次 GetRelationAt 二分查询在每秒上万事件时
    -- 是主要卡顿源；现在每个事件最多计算 4 次（无关系修改时）。
    local relCacheValid = type(relCache) == "table"
        and relCache.srcKey == (source ~= nil and source.key or nil)
        and relCache.tgtKey == (target ~= nil and target.key or nil)
    if not relCacheValid or evidenceModified == true then relCache = nil end
    if relCache == nil then
        -- 待确认和完整重放过去会为每条历史事件创建一张 6 字段哈希表。
        -- 十万事件重算会制造十万张短命对象并触发连续 GC。客户端回调与
        -- 重放状态机均在同一 Lua 主线程串行执行，下游不会保存该引用，
        -- 因此可安全复用一张专用快照表。
        relCache = self.replayRelationCache
        if type(relCache) ~= "table" then
            relCache = {}
            self.replayRelationCache = relCache
        end
        FillRelationCache(relCache, source, target, event.timestamp)
    end

    -- A pending event may become informative only after a later roster, sight,
    -- social or manual observation establishes one endpoint. Refresh the
    -- deterministic relation edge before retrying statistics so historical
    -- heals/damage can propagate the newly known side without waiting for a
    -- full-session replay. Live events and full rebuilds already run this step.
    if refreshCombatEvidence == true
        and event.environmental ~= true
        and (event.category == "DAMAGE" or event.category == "HEAL")
        and event.amount > 0 then
        if ApplyCombatEvidence(event, relCache, source, target) then
            -- 证据修改了关系：用最新关系重算快照供下游使用。
            relCache = self.replayRelationCache
            if type(relCache) ~= "table" then
                relCache = {}
                self.replayRelationCache = relCache
            end
            FillRelationCache(relCache, source, target, event.timestamp)
        end
    end

    if E:IsIgnored(source) or E:IsIgnored(target) then
        event.applied = true
        event.pending = false
        event.thirdParty = false
        event.classificationStatus = "IGNORED_MANUAL"
        return true
    end
    if event.environmental == true then
        -- Environmental damage is retained in the short diagnostic ring only.
        -- It must never create a damage actor, self-damage skill, taken row,
        -- combat context or last-hit candidate in the main statistics.
        event.applied = true
        event.pending = false
        event.thirdParty = false
        event.candidateMode = "PVE"
        event.modeReason = "ENVIRONMENT_EXCLUDED"
        event.modeProvisional = nil
        event.classificationStatus = "ENVIRONMENT_EXCLUDED"
        D.Diagnostics.counters.environmentalEvents = (tonumber(D.Diagnostics.counters.environmentalEvents) or 0) + 1
        D.Diagnostics.counters.environmentalDamage = (tonumber(D.Diagnostics.counters.environmentalDamage) or 0) + (tonumber(event.amount) or 0)
        return true
    end
    -- v0.2.25（性能）：关系快照已在证据之后就绪，直接复用（见上方说明）。
    local mode, modeReason, modeProvisional = ResolveEventMode(event, source, target, relCache)
    mode, modeReason, modeProvisional = EnforceModeInvariant(
        event, source, target, mode, modeReason, modeProvisional)
    event.candidateMode = mode
    event.modeReason = modeReason
    event.modeProvisional = modeProvisional == true and true or nil

    -- Team scope is an admission policy, not a new event classifier. Keep the
    -- raw fact and its PVP/PVE mode, but do not create formal ranking actors when
    -- neither endpoint was SELF/TEAM at the event timestamp.
    if IsTeamScopeMode()
        and not IsFormalTeamScopeActor(source, event.timestamp)
        and not IsFormalTeamScopeActor(target, event.timestamp) then
        event.applied = true
        event.pending = false
        event.thirdParty = false
        event.appliedMode = mode ~= "UNKNOWN" and mode or nil
        event.scopeContextOnly = true
        event.classificationStatus = "CONTEXT_ONLY_TEAM_SCOPE"
        D.Diagnostics.counters.scopeContextOnlyEvents =
            (tonumber(D.Diagnostics.counters.scopeContextOnlyEvents) or 0) + 1
        return true
    end

    if mode ~= "UNKNOWN" and event.expiredModes ~= nil and event.expiredModes[mode] == true then
        event.applied = true
        event.pending = false
        event.thirdParty = false
        event.classificationStatus = "EXPIRED_" .. mode
        return true
    end

    local applied = false
    local sourceProjectionSide = nil
    local targetProjectionSide = nil
    local pendingReason = nil
    if event.category == "DAMAGE" and event.amount > 0 and mode ~= "UNKNOWN" then
        applied, sourceProjectionSide, targetProjectionSide, pendingReason =
            ApplyDamage(event, mode, relCache, source, target)
    elseif event.category == "HEAL" and event.amount > 0 and mode ~= "UNKNOWN" then
        applied, sourceProjectionSide, targetProjectionSide, pendingReason =
            ApplyHeal(event, mode, relCache, source, target)
    elseif event.category == "KILL" and mode ~= "UNKNOWN" then
        applied, sourceProjectionSide, targetProjectionSide, pendingReason =
            ApplyKill(event, mode, relCache, source, target)
    elseif event.category == "MISS" or event.category == "DEATH" or event.category == "OTHER" then
        event.classificationStatus = "DIAGNOSTIC_ONLY"
        event.applied = true
        return true, sourceProjectionSide, targetProjectionSide, nil
    end

    if applied then
        event.applied = true
        -- Persist the exact mode chosen for this one event.  Ranking actors may
        -- legitimately exist in both PVP and PVE; no mode affinity is stored on
        -- the Entity/Actor itself.
        event.appliedMode = mode
        -- Fresh live drafts use nil as the compact false value. Only stage a
        -- clearing write when this row is being retried from a real pending or
        -- third-party state; the common success path therefore avoids two
        -- sidecar columns and two tail-slot mirror writes.
        if event.pending == true then event.pending = nil end
        if event.thirdParty == true then event.thirdParty = nil end
        local appliedLabel = event.category == "HEAL" and "SHARED_HEAL" or mode
        event.classificationStatus = "APPLIED_" .. appliedLabel .. (event.modeProvisional and "_PROVISIONAL" or "")
        if event.category == "DAMAGE" then S:MarkClosureDirty(mode) end
        D.State.dirty.statsSave = true
        D.MarkViewDirty()
        return true
    end

    local thirdParty = false
    if mode == "PVP" and EventEndpointKind(event, "source", source) == "PLAYER"
        and EventEndpointKind(event, "target", target) == "PLAYER"
        and not relCache.sf and not relCache.tf then
        thirdParty = true
    elseif mode == "PVE" and not relCache.sf and not relCache.tf then
        thirdParty = true
    end
    event.pending = true
    event.thirdParty = thirdParty
    if event.healRelationConflict == true then
        event.classificationStatus = "PENDING_HEAL_RELATION_CONFLICT"
    else
        event.classificationStatus = thirdParty and "THIRD_PARTY" or "PENDING"
    end
    pendingReason = pendingReason
        or (event.healRelationConflict == true and "HEAL_RELATION_CONFLICT")
        or (thirdParty and "THIRD_PARTY_UNOWNED")
        or (mode == "UNKNOWN" and "MODE_UNKNOWN")
        or "UNRESOLVED_RELATION"
    return false, nil, nil, pendingReason
end

function R:TryClassifyAndApply(event, refreshCombatEvidence, relCache, evidenceModified,
    reuseResolvedEndpoints, providedRawSource, providedSource, providedTarget, explicitContext,
    liveNormalized)
    local previousStatus = type(event) == "table" and event.classificationStatus or nil
    local mutationStarted = type(EventClassifications.IsMutating) == "function"
        and EventClassifications:IsMutating(event)
    if not mutationStarted and type(EventClassifications.BeginMutation) == "function" then
        mutationStarted = EventClassifications:BeginMutation(
            event, explicitContext or "CLASSIFICATION_ATTEMPT") == true
    end
    local applied, sourceProjectionSide, targetProjectionSide, pendingReason =
        TryClassifyAndApplyAuthority(self, event, refreshCombatEvidence, relCache,
            evidenceModified, reuseResolvedEndpoints, providedRawSource, providedSource, providedTarget,
            liveNormalized)
    local context = InferClassificationContext(self, event, refreshCombatEvidence,
        providedSource, providedTarget, explicitContext, previousStatus)
    local status = type(event) == "table" and tostring(event.classificationStatus or "") or ""
    local sideQuality = (sourceProjectionSide ~= nil or targetProjectionSide ~= nil)
        and "EXACT_ATTEMPT"
        or (string.sub(status, 1, 8) == "APPLIED_" and "MISSING_ROUTE" or "NOT_APPLICABLE")
    local diagnosticsEnabled = D.State ~= nil and D.State.config ~= nil
        and D.State.config.diagnosticsEnabled == true
    if mutationStarted and type(EventClassifications.CommitMutation) == "function" then
        if diagnosticsEnabled then
            EventClassifications:CommitMutation(event, context,
                "sourceProjectionSide", sourceProjectionSide,
                "targetProjectionSide", targetProjectionSide,
                "projectionSideQuality", sideQuality,
                "pendingReason", pendingReason,
                "classificationContext", context,
                "classificationObservedAt", U.NowMs())
        else
            -- Product totals and replay compatibility use the staged common
            -- fields. Exact route/context columns exist only for diagnostic
            -- local-replay proofs, so normal combat commits no extra metadata.
            EventClassifications:CommitMutation(event, context)
        end
    else
        if diagnosticsEnabled then
            EventClassifications:SetMany(event, context,
                "sourceProjectionSide", sourceProjectionSide,
                "targetProjectionSide", targetProjectionSide,
                "projectionSideQuality", sideQuality,
                "pendingReason", pendingReason,
                "classificationContext", context,
                "classificationObservedAt", U.NowMs())
        else
            EventClassifications:SetMany(event, context)
        end
    end

    -- The diagnostic immutable shadow mirrors only replay-journal members.
    local sessionIndex = type(event) == "table"
        and math.floor(tonumber(event.repdpsSessionIndex) or 0) or 0
    if sessionIndex > 0 and diagnosticsEnabled then
        CallEventShadow("ObserveClassification", event, context,
            sourceProjectionSide, targetProjectionSide, pendingReason)
    end
    return applied, sourceProjectionSide, targetProjectionSide, pendingReason
end

-- Replay events dominate memory during long raids. A normal Lua hash table
-- with dozens of string keys costs far more than the values it stores. Keep the
-- public event.field access contract, but place replay fields in one shared
-- positional layout. Pending rows may retain runtime entity references; applied
-- rows release them and resolve endpoints again only during an explicit replay.
local REPLAY_FIELDS = {
    -- v0.2.29：真实已归类事件保存稳定绑定与重放解析键，但普通事件
    -- 不再因高位字段或临时实体引用被扩展为 64 槽数组。所有常见字段
    -- 保持在前 32 槽；待确认、冲突、死亡和其他稀有状态进入独立扩展表。
    "repdpsPacked", "repdpsCompact", "repdpsSessionIndex",
    "eventId", "timestamp", "eventType", "category",
    "sourceKey", "targetKey", "sourceName", "targetName",
    "abilityId", "abilityName", "amount", "parseStatus",
    "candidateMode", "modeReason", "classificationStatus",
    "sourceBindingQuality", "targetBindingQuality",
    "sourceBoundId", "targetBoundId",
    "sourceResolvedKey", "targetResolvedKey",
    -- 事件时间点的官方类型观察会在完整重算时写入大多数有效事件，必须
    -- 保持在前 32 槽。旧布局把它们放在 42～45，重算一次就会让整本日志
    -- 重新膨胀为 64 槽数组。
    "sourceObservedKind", "targetObservedKind",
    "sourceObservedKindQuality", "targetObservedKindQuality",
    "environmental", "applied", "pending", "thirdParty",

    -- 稀有/临时状态。默认 false 的字段在写入时尽量保持 nil，避免普通
    -- 已归类事件因一个 false 值扩展到 64 槽数组。
    "damageType", "effectType", "appliedMode", "rawUnitId",
    "inferredLastHit", "modeProvisional", "relationProvisional", "provisionalFallbackMode",
    "sourceBindingAmbiguous", "targetBindingAmbiguous",
    "sourceKeyAuthoritative", "targetKeyAuthoritative",
    "expiredModes", "retiredThirdParty", "dormantThirdParty",
    "dormantPending", "dormantSummaryMode", "healRelationConflict",
    "friendlyFire", "opponentInternalDamage", "repdpsSummaryTracked",
    "repdpsSummaryMode", "repdpsSummaryThirdParty",
    "repdpsRetryCount", "repdpsNextRetryAt",
    "sourceEntity", "targetEntity", "rawSourceEntity",
    "deathNoticeAt", "lastHitMatchReason", "linkedDamageEventId",
}

local REPLAY_COMMON_FIELD_LIMIT = 32
local REPLAY_FIELD_INDEX = {}
local REPLAY_RARE_FIELDS = {}
for index, fieldName in ipairs(REPLAY_FIELDS) do
    if index <= REPLAY_COMMON_FIELD_LIMIT then REPLAY_FIELD_INDEX[fieldName] = index
    else REPLAY_RARE_FIELDS[fieldName] = true end
end
local REPLAY_EXTRA_KEY = "__repdpsExtra"

local REPLAY_LAYOUT_VERSION = 6
local previousReplayMeta = type(R.replayMeta) == "table" and R.replayMeta or nil
local replayMetaReusable = previousReplayMeta ~= nil
    and tonumber(R.replayLayoutVersion) == REPLAY_LAYOUT_VERSION
local REPLAY_META = replayMetaReusable and previousReplayMeta or {}
-- 热重载必须原地更新同一个 metatable。否则几十万条既有事件仍指向旧
-- metatable，插件只能扫描并重新打包整本日志。
local function ReadReplayMirrorRaw(target, key)
    if getmetatable(target) ~= REPLAY_META then return rawget(target, key) end
    local index = REPLAY_FIELD_INDEX[key]
    if index ~= nil then return rawget(target, index) end
    if REPLAY_RARE_FIELDS[key] == true then
        local extra = rawget(target, REPLAY_EXTRA_KEY)
        return type(extra) == "table" and extra[key] or nil
    end
    return rawget(target, key)
end

local function WriteReplayMirrorRaw(target, key, value)
    if getmetatable(target) ~= REPLAY_META then
        rawset(target, key, value)
        return true
    end
    local index = REPLAY_FIELD_INDEX[key]
    if index ~= nil then
        rawset(target, index, value)
    elseif REPLAY_RARE_FIELDS[key] == true then
        local extra = rawget(target, REPLAY_EXTRA_KEY)
        if value == nil then
            if type(extra) == "table" then
                extra[key] = nil
                if next(extra) == nil then rawset(target, REPLAY_EXTRA_KEY, nil) end
            end
        else
            if type(extra) ~= "table" then
                extra = {}
                rawset(target, REPLAY_EXTRA_KEY, extra)
            end
            extra[key] = value
        end
    else
        rawset(target, key, value)
    end
    return true
end

-- Fact and Classification sidecars are the Authorities. Legacy packed slots
-- remain compatibility mirrors. Creation writes reach raw mirrors until the row
-- is published; after publish, Fact writes must be idempotent while mutable
-- Classification writes enter its sidecar first. Both field-set lookups are
-- captured once so unrelated event reads stay allocation-free.
local EVENT_FACT_FIELD_SET = EventFacts:GetAdapterFieldSet()
local EVENT_CLASSIFICATION_FIELD_SET = EventClassifications:GetAdapterFieldSet()
REPLAY_META.__index = function(target, key)
    local mirrorValue = ReadReplayMirrorRaw(target, key)
    -- Sidecars remain the formal audit/recovery Authorities, but every product
    -- write updates the compact mirror in the same transaction. In normal mode
    -- use that synchronized mirror as the hot read cache; diagnostic mode still
    -- routes every field through the Authority and detects mirror tampering.
    local productFastRead = mirrorValue ~= nil
        and D.State ~= nil and D.State.config ~= nil
        and D.State.config.diagnosticsEnabled ~= true
    if productFastRead then return mirrorValue end
    if EVENT_FACT_FIELD_SET[key] == true then
        return EventFacts:Get(target, key, mirrorValue)
    end
    if EVENT_CLASSIFICATION_FIELD_SET[key] == true then
        return EventClassifications:Get(target, key, mirrorValue)
    end
    return mirrorValue
end
REPLAY_META.__newindex = function(target, key, value)
    if EVENT_FACT_FIELD_SET[key] == true then
        EventFacts:WriteLegacyField(target, key, value, "REPLAY_META_WRITE")
        return
    end
    if EVENT_CLASSIFICATION_FIELD_SET[key] == true then
        EventClassifications:WriteLegacyField(target, key, value, "REPLAY_META_WRITE")
        return
    end
    WriteReplayMirrorRaw(target, key, value)
end
EventFacts:RegisterLegacyMirrorAdapter(ReadReplayMirrorRaw, WriteReplayMirrorRaw)
EventClassifications:RegisterLegacyMirrorAdapter(ReadReplayMirrorRaw, WriteReplayMirrorRaw)
R.replayFieldIndex = REPLAY_FIELD_INDEX
R.replayRareFields = REPLAY_RARE_FIELDS
R.replayExtraKey = REPLAY_EXTRA_KEY
R.replayMeta = REPLAY_META
R.replayMetaReused = replayMetaReusable
R.replayLayoutVersion = REPLAY_LAYOUT_VERSION

local function IsPackedReplayEvent(event)
    return type(event) == "table" and getmetatable(event) == REPLAY_META
        and event.repdpsPacked == true
end

local REPLAY_FALSE_IS_DEFAULT = {
    modeProvisional = true,
    relationProvisional = true,
    sourceBindingAmbiguous = true,
    targetBindingAmbiguous = true,
    sourceKeyAuthoritative = true,
    targetKeyAuthoritative = true,
    retiredThirdParty = true,
    dormantThirdParty = true,
    dormantPending = true,
    healRelationConflict = true,
    friendlyFire = true,
    opponentInternalDamage = true,
    repdpsSummaryTracked = true,
    repdpsSummaryThirdParty = true,
}

local function PackReplayEvent(event, retainRuntimeEntities, sessionIndex)
    if type(event) ~= "table" then return event end
    if IsPackedReplayEvent(event) then
        if sessionIndex ~= nil then event.repdpsSessionIndex = sessionIndex end
        if retainRuntimeEntities ~= true then
            event.sourceEntity = nil
            event.targetEntity = nil
            event.rawSourceEntity = nil
        end
        return event
    end

    local packed = {}
    setmetatable(packed, REPLAY_META)
    for _, fieldName in ipairs(REPLAY_FIELDS) do
        local value = event[fieldName]
        if fieldName == "sourceKeyAuthoritative" and event.sourceBoundId ~= nil then value = nil end
        if fieldName == "targetKeyAuthoritative" and event.targetBoundId ~= nil then value = nil end
        if fieldName == "expiredModes" and type(value) == "table" then value = U.DeepCopy(value) end
        if value ~= nil and not (value == false and REPLAY_FALSE_IS_DEFAULT[fieldName] == true) then
            packed[fieldName] = value
        end
    end
    packed.repdpsPacked = true
    packed.repdpsCompact = true
    if sessionIndex ~= nil then packed.repdpsSessionIndex = sessionIndex end
    if retainRuntimeEntities ~= true then
        packed.sourceEntity = nil
        packed.targetEntity = nil
        packed.rawSourceEntity = nil
    end
    return packed
end

ReplaceSessionEvent = function(event, retainRuntimeEntities)
    if type(event) ~= "table" then return event end
    local index = math.floor(tonumber(event.repdpsSessionIndex) or 0)
    if index < 1 or type(Store.sessionEvents) ~= "table" then
        return PackReplayEvent(event, retainRuntimeEntities, nil)
    end
    local current = Store.sessionEvents[index]
    if current ~= event and type(current) == "table"
        and tonumber(current.eventId) == tonumber(event.eventId) then
        event = current
    end
    local packed = PackReplayEvent(event, retainRuntimeEntities, index)
    Store.sessionEvents[index] = packed
    return packed
end

function R:MaybeCompactSession()
    if Store.journalState == "ValidatedDense"
        and tonumber(Store.journalReplayLayoutVersion) == REPLAY_LAYOUT_VERSION
        and self.replayMetaReused == true then
        return
    end
    -- New events are packed before entering the replay journal. This path now
    -- exists only to migrate an older hot-reload journal without a single-frame
    -- rewrite.
    if self.sessionCompactionRequested == true then return end
    local events = Store.sessionEvents or {}
    local cursor = math.max(1, math.floor(tonumber(self.sessionCompactionCursor) or 1))
    for index = cursor, #events do
        if not IsPackedReplayEvent(events[index]) then
            self.sessionCompactionRequested = true
            self.sessionCompactionRequestedAt = tonumber(self.sessionCompactionRequestedAt) or U.NowMs()
            self.sessionCompactionCursor = index
            return
        end
    end
end

function R:CompactSessionNow(batchLimit)
    if self.sessionCompactionRequested ~= true then return false end
    local events = Store.sessionEvents or {}
    if #events == 0 then
        self.sessionCompactionRequested = false
        self.sessionCompactionRequestedAt = nil
        self.sessionCompactionCursor = 1
        return false
    end

    local batch = math.max(25, math.min(1000,
        math.floor(tonumber(batchLimit) or C.SESSION_COMPACT_BATCH or 160)))
    local cursor = math.max(1, math.floor(tonumber(self.sessionCompactionCursor) or 1))
    local processed = 0
    local changed = 0
    local count = #events
    while cursor <= count and processed < batch do
        local event = events[cursor]
        if type(event) == "table" then
            event.repdpsSessionIndex = cursor
            if not IsPackedReplayEvent(event) then
                local retainEntities = event.applied ~= true
                    and event.dormantThirdParty ~= true
                    and event.dormantPending ~= true
                    and event.retiredThirdParty ~= true
                events[cursor] = PackReplayEvent(event, retainEntities, cursor)
                changed = changed + 1
            elseif event.applied == true or event.dormantThirdParty == true
                or event.dormantPending == true or event.retiredThirdParty == true then
                event.sourceEntity = nil
                event.targetEntity = nil
                event.rawSourceEntity = nil
            end
        end
        cursor = cursor + 1
        processed = processed + 1
    end
    self.sessionCompactionCursor = cursor
    D.Diagnostics.counters.compactedReplayEvents =
        (tonumber(D.Diagnostics.counters.compactedReplayEvents) or 0) + changed

    if cursor > #events then
        self.sessionCompactionRequested = false
        self.sessionCompactionRequestedAt = nil
        self.sessionCompactionCursor = #events + 1
        self.sessionCompactionDeferredCount = nil
        self.retiredThirdPartySinceCompact = 0
        -- 整本旧布局已原地分帧迁移完成；下一次热重载可直接走同布局 O(1) 接管。
        Store.journalReplayLayoutVersion = REPLAY_LAYOUT_VERSION
        Store.journalState = "ValidatedDense"
        Store.journalStateVersion = (tonumber(Store.journalStateVersion) or 0) + 1
        D.Diagnostics.counters.sessionCompactions =
            (tonumber(D.Diagnostics.counters.sessionCompactions) or 0) + 1
        if D.State.config.diagnosticsEnabled then
            D.Diagnostics:AddInfo("session", "packed replay migration completed; retained=" .. tostring(#events))
        end
        return true
    end
    return changed > 0
end

local LAST_HIT_WINDOW_MS = 20000
local DEATH_FORWARD_WINDOW_MS = 2500
local LAST_HIT_DEDUP_MS = LAST_HIT_WINDOW_MS + DEATH_FORWARD_WINDOW_MS + 1000
local MAX_RECENT_DAMAGE_CANDIDATES = 2000
local MAX_PENDING_DEATH_NOTICES = 50
local PENDING_DEATH_RETRY_INTERVAL_MS = 100

------------------------------------------------------------------------
-- 最后一击候选：真正固定容量环形缓冲（问题 10 修复）
--
-- 数据所有权：Store.recentDamageCandidates 是容量固定的槽数组，
--   recentDamageHead/Tail/Count 三个指针描述逻辑顺序。所有条目只写入
--   槽位，绝不整体搬移数组——旧实现周期性创建新数组复制 1700~2000 个
--   引用，高事件率下反复制造 GC 峰值。
-- 生命周期：与战斗会话同生；ClearAllCombatData 时整体清空。
-- 是否允许失效：允许。候选窗口只是"最近 20 秒伤害"的加速缓存，语义上
--   任何时刻都能安全清空重来，不影响最终统计（最后击关联失败只降级为
--   未匹配）。
-- 是否可重建：可。NormalizeEventStore 热重载时按逻辑顺序重放槽位。
-- 为什么不能搬移：搬移是 O(容量) 的数组分配+复制，20 秒窗口在高事件率
--   下每秒触发多次；环形缓冲的写入、过期清理、倒扫都是 O(1)/O(容量)
--   的原地操作。
------------------------------------------------------------------------
local RingBufferCapacity = MAX_RECENT_DAMAGE_CANDIDATES

local function RingNext(index)
    return index >= RingBufferCapacity and 1 or index + 1
end

local function RingPrev(index)
    return index <= 1 and RingBufferCapacity or index - 1
end

-- 清空环形缓冲（保留槽数组引用，避免反复分配大表）。
local function ResetRecentDamageRing()
    -- rc3：最后一击已停用，直接释放旧候选表，不再同步清 2000 个槽。
    Store.recentDamageCandidates = {}
    Store.recentDamageHead = 1
    Store.recentDamageTail = 1
    Store.recentDamageCount = 0
end

-- 逻辑遍历：从最新到最旧访问每个候选（回调 candidate；返回 true 停止）。
local function ForEachRecentDamageNewestFirst(visitor)
    local slots = Store.recentDamageCandidates or {}
    local count = math.max(0, math.floor(tonumber(Store.recentDamageCount) or 0))
    local index = RingPrev(math.max(1, math.floor(tonumber(Store.recentDamageTail) or 1)))
    for _ = 1, count do
        local candidate = slots[index]
        if type(candidate) == "table" then
            if visitor(candidate) == true then return true end
        end
        index = RingPrev(index)
    end
    return false
end

-- 按时间清理过期项：只推进 head 指针，不做数组搬移。
local function TrimRecentDamageCandidates(now)
    local slots = Store.recentDamageCandidates or {}
    local count = math.max(0, math.floor(tonumber(Store.recentDamageCount) or 0))
    local head = math.max(1, math.floor(tonumber(Store.recentDamageHead) or 1))
    local expired = false
    while count > 0 do
        local item = slots[head]
        local at = tonumber(item and item.at) or 0
        if now - at > LAST_HIT_WINDOW_MS + 10000 then
            slots[head] = nil
            head = RingNext(head)
            count = count - 1
            expired = true
        else
            break
        end
    end
    Store.recentDamageHead = head
    Store.recentDamageCount = count
    return expired
end

local function RememberDamageCandidate(event, resolvedTarget)
    if type(event) ~= "table" or event.category ~= "DAMAGE"
        or (tonumber(event.amount) or 0) <= 0 or event.environmental == true then return end
    local slots = Store.recentDamageCandidates or {}
    Store.recentDamageCandidates = slots
    local head = math.max(1, math.floor(tonumber(Store.recentDamageHead) or 1))
    local tail = math.max(1, math.floor(tonumber(Store.recentDamageTail) or 1))
    local count = math.max(0, math.floor(tonumber(Store.recentDamageCount) or 0))

    -- 环形槽满后原地复用最旧候选表。旧实现虽然不再搬移槽数组，但仍为
    -- 每条伤害分配一张 5 字段哈希表；大型团战会持续制造短命对象并触发 GC。
    -- 候选只在匹配函数调用期间被临时引用，覆盖最旧槽不会改变 20 秒窗口语义。
    local candidate = slots[tail]
    if type(candidate) ~= "table" then candidate = {} end
    candidate.event = event
    candidate.at = tonumber(event.timestamp) or U.NowMs()
    candidate.targetKey = tostring(event.targetKey or "")
    candidate.targetName = U.NormalizeName(event.targetName)

    local stableId = nil
    if event.targetBindingAmbiguous ~= true then
        stableId = event.targetBoundId or (resolvedTarget ~= nil and resolvedTarget.stringId or nil)
        if stableId == nil and event.targetKeyAuthoritative == true then
            stableId = string.match(candidate.targetKey, "^id:(.+)$")
        end
    end
    candidate.targetId = stableId

    if count >= RingBufferCapacity then
        head = RingNext(head)
    else
        count = count + 1
    end
    slots[tail] = candidate
    tail = RingNext(tail)
    Store.recentDamageHead = head
    Store.recentDamageTail = tail
    Store.recentDamageCount = count
    TrimRecentDamageCandidates(candidate.at)
end

local function PushToken(set, value)
    local text = U.Trim(value)
    if text ~= "" then set[string.lower(text)] = true end
end

local function ExtractDeathTokens(...)
    local args = { ... }
    local argCount = select("#", ...)
    local preferredNames, names, ids = {}, {}, {}
    for index = 1, argCount do
        local value = args[index]
        if type(value) == "table" then
            for key, item in pairs(value) do
                local lowerKey = string.lower(tostring(key))
                if type(item) == "string" or type(item) == "number" then
                    local isIdentityField = string.find(lowerKey, "dead", 1, true) ~= nil
                        or string.find(lowerKey, "victim", 1, true) ~= nil
                        or string.find(lowerKey, "target", 1, true) ~= nil
                        or lowerKey == "name" or lowerKey == "unitname" or lowerKey == "stringid" or lowerKey == "unitid" or lowerKey == "id"
                    if isIdentityField then
                        if string.find(lowerKey, "id", 1, true) ~= nil then PushToken(ids, item)
                        else PushToken(preferredNames, item) PushToken(names, item) end
                    end
                end
            end
        elseif type(value) == "string" then
            if index == 1 then PushToken(preferredNames, value) end
            PushToken(names, value)
            PushToken(ids, value)
        elseif type(value) == "number" then
            PushToken(ids, value)
        end
    end
    return preferredNames, names, ids
end

local function LastHitOutcomeSignature(candidate)
    local event = candidate and candidate.event or nil
    if type(event) ~= "table" then return nil end
    local at = U.FiniteNumber(event.timestamp, candidate.at) or candidate.at or U.NowMs()
    local rawSource = ResolveHistoricalEndpoint(event, "source")
    local source = ResolveEffectiveSource(rawSource)
    local target = ResolveHistoricalEndpoint(event, "target")
    local mode = event.candidateMode or event.appliedMode or CandidateMode(source, target, event)
    local sourceSide = IsFriendlyForEvent(source, at) and "F" or (IsOpponentForEvent(source, at) and "E" or "U")
    local targetSide = IsFriendlyForEvent(target, at) and "F" or (IsOpponentForEvent(target, at) and "E" or "U")
    return table.concat({ tostring(source and source.key or ""), tostring(mode), sourceSide, targetSide }, "|")
end

local function FindRecentDamageForDeath(observedAt, ...)
    local preferredNames, names, ids = ExtractDeathTokens(...)
    local now = U.TimestampOrNow(observedAt)
    local best, bestScore = nil, -1
    local tiedBest = {}
    -- 环形缓冲：从最新到最旧遍历（逻辑顺序，不依赖数组长度/搬移）。
    ForEachRecentDamageNewestFirst(function(candidate)
        local age = now - (tonumber(candidate and candidate.at) or 0)
        if age >= 0 and age <= LAST_HIT_WINDOW_MS then
            local damageEvent = candidate and candidate.event or nil
            if type(damageEvent) == "table" then
                local resolvedTarget = ResolveHistoricalEndpoint(damageEvent, "target")
                if damageEvent.targetBindingAmbiguous == true then
                    candidate.targetId = nil
                else
                    candidate.targetId = damageEvent.targetBoundId
                        or (resolvedTarget ~= nil and resolvedTarget.stringId or nil)
                end
            end
            local score = 0
            if candidate.targetId ~= nil and ids[string.lower(tostring(candidate.targetId))] then score = score + 120 end
            if candidate.targetName ~= "" and preferredNames[candidate.targetName] then score = score + 100
            elseif candidate.targetName ~= "" and names[candidate.targetName] then score = score + 70 end
            if age <= 2000 then score = score + 20 elseif age <= 5000 then score = score + 10 end
            if score > bestScore then
                bestScore = score
                best = candidate
                tiedBest = { candidate }
            elseif score == bestScore then
                tiedBest[#tiedBest + 1] = candidate
            end
        end
        return false
    end)
    if bestScore < 70 then return nil, "NO_MATCH" end
    if #tiedBest > 1 then
        -- Equal-score damage rows are safe only when they produce exactly the
        -- same observable last-hit outcome (same source identity, mode and side
        -- assignment). This commonly happens when one player lands several hits
        -- in the same coarse timestamp bucket. Different possible killers or
        -- PVP/PVE outcomes remain unassigned rather than guessed.
        local signature = LastHitOutcomeSignature(tiedBest[1])
        for index = 2, #tiedBest do
            if signature == nil or LastHitOutcomeSignature(tiedBest[index]) ~= signature then
                return best, "AMBIGUOUS_LATEST"
            end
        end
        return best, "MATCH_SAME_OUTCOME_TIE"
    end
    return best, "MATCH"
end

local function DeathArgsText(args)
    local parts = {}
    for index = 1, 4 do parts[#parts + 1] = tostring(type(args) == "table" and args[index] or nil) end
    return table.concat(parts, " | ")
end

local function QueuePendingDeathNotice(observedAt, ...)
    R.pendingDeathNotices = R.pendingDeathNotices or {}
    local args = { ... }
    local argCount = select("#", ...)
    R.pendingDeathNotices[#R.pendingDeathNotices + 1] = {
        at = U.TimestampOrNow(observedAt),
        args = args,
        argCount = argCount,
    }
    while #R.pendingDeathNotices > MAX_PENDING_DEATH_NOTICES do
        table.remove(R.pendingDeathNotices, 1)
        D.Diagnostics.counters.deathUnmatched = (tonumber(D.Diagnostics.counters.deathUnmatched) or 0) + 1
    end
    D.Diagnostics.counters.deathDeferred = (tonumber(D.Diagnostics.counters.deathDeferred) or 0) + 1
end

function R:CreateLastHitFromDamage(damageEvent, rawArgs, matchReason)
    if type(damageEvent) ~= "table" then return false end
    self.lastDeathByEventId = self.lastDeathByEventId or {}
    local now = U.NowMs()
    local damageAt = U.FiniteNumber(damageEvent.timestamp, now) or now
    local damageEventId = tostring(damageEvent.eventId or "")
    if damageEventId ~= "" and self.lastDeathByEventId[damageEventId] ~= nil
        and now - self.lastDeathByEventId[damageEventId] < LAST_HIT_DEDUP_MS then return false end
    if damageEventId ~= "" then self.lastDeathByEventId[damageEventId] = now end

    local source, sourceQuality, sourceBoundId = ResolveHistoricalEndpoint(damageEvent, "source")
    local target, targetQuality, targetBoundId = ResolveHistoricalEndpoint(damageEvent, "target")
    -- 与 NormalizeCombatEvent 相同的紧凑直建路径：不先分配字符串键哈希表。
    -- rawArgs 是死亡通知原始参数（≤4 项），仅诊断/重放匹配需要，直接存原表。
    -- Relation/type history must be evaluated at the final damage, not
    -- at the later death-notice delivery time. Team changes inside the
    -- 20-second candidate window must not move an already-linked last hit.
    local event = EventFacts:CreateLegacyDraft(REPLAY_META,
        Store.nextId, damageAt, "INFERRED_LAST_HIT", "KILL",
        source.name, target.name, damageEvent.abilityId, damageEvent.abilityName,
        1, "OK", nil, true, now, matchReason, damageEvent.eventId)
    event.sourceKey = source.key
    event.targetKey = target.key
    event.rawArgs = rawArgs or {}
    event.candidateMode = damageEvent.candidateMode or damageEvent.appliedMode or "UNKNOWN"
    event.provisionalFallbackMode = damageEvent.provisionalFallbackMode
    event.classificationStatus = "NEW"
    event.sourceBindingQuality = sourceQuality
    event.targetBindingQuality = targetQuality
    event.sourceBoundId = sourceBoundId
    event.targetBoundId = targetBoundId
    event.sourceBindingAmbiguous = (damageEvent.sourceBindingAmbiguous == true
        or sourceQuality == "AMBIGUOUS_TIME_BINDING" or sourceQuality == "LOCKED_AMBIGUOUS_BINDING") and true or nil
    event.targetBindingAmbiguous = (damageEvent.targetBindingAmbiguous == true
        or targetQuality == "AMBIGUOUS_TIME_BINDING" or targetQuality == "LOCKED_AMBIGUOUS_BINDING") and true or nil
    event.sourceKeyAuthoritative = nil
    event.targetKeyAuthoritative = nil
    event.applied = false
    event.pending = false
    event.thirdParty = false
    Store.nextId = Store.nextId + 1
    Store:PushRaw(event)
    Store.sessionEvents = Store.sessionEvents or {}
    -- v0.2.25（问题 4/1）：KILL 事件走统一追加入口（索引 + 稠密校验）。
    local sessionIndex = Store:AppendSessionEvent(event)
    if sessionIndex < 1 then
        self:NormalizeEventStore()
        sessionIndex = Store:AppendSessionEvent(event)
    end
    local effectiveSource = ResolveEffectiveSource(source)
    local applied = self:TryClassifyAndApply(event, false, nil, false, false,
        source, effectiveSource, target)
    local storedEvent = PackReplayEvent(event, false, sessionIndex)
    Store.sessionEvents[sessionIndex] = storedEvent
    if not applied then
        self:QueuePending(storedEvent)
    end
    D.Diagnostics.counters.deathMatched = (tonumber(D.Diagnostics.counters.deathMatched) or 0) + 1
    return true
end

function R:ResolvePendingDeathNotices()
    if type(self.pendingDeathNotices) ~= "table" or #self.pendingDeathNotices == 0 then return end
    local now = U.NowMs()
    local kept = {}
    for _, item in ipairs(self.pendingDeathNotices or {}) do
        local age = now - (tonumber(item.at) or now)
        if age >= 0 and age <= DEATH_FORWARD_WINDOW_MS then
            local deathArgs = item.args or {}
            local deathArgCount = tonumber(item.argCount) or #deathArgs
            local candidate, reason = FindRecentDamageForDeath(now, unpack(deathArgs, 1, deathArgCount))
            if candidate ~= nil and candidate.event ~= nil
                and (tonumber(candidate.at) or 0) >= (tonumber(item.at) or 0) - 250 then
                if reason == "AMBIGUOUS_LATEST" then
                    D.Diagnostics.counters.deathAmbiguous = (tonumber(D.Diagnostics.counters.deathAmbiguous) or 0) + 1
                    -- Do not invent a killer when two candidates are equally
                    -- plausible. Keep waiting inside the short forward window;
                    -- if no unique match appears, the notice is discarded.
                    kept[#kept + 1] = item
                else
                    local created = self:CreateLastHitFromDamage(candidate.event, item.args, "FORWARD_" .. tostring(reason))
                    if created then
                        D.Diagnostics.counters.deathRecoveredForward = (tonumber(D.Diagnostics.counters.deathRecoveredForward) or 0) + 1
                    end
                end
            else
                kept[#kept + 1] = item
            end
        else
            D.Diagnostics.counters.deathUnmatched = (tonumber(D.Diagnostics.counters.deathUnmatched) or 0) + 1
            if D.State.config.diagnosticsEnabled then
                D.Diagnostics:AddWarning("death_unmatched", DeathArgsText(item.args))
            end
        end
    end
    self.pendingDeathNotices = kept
end

function R:RecordCombatLoad(now)
    now = tonumber(now) or U.NowMs()
    self.loadWindowStartedAt = tonumber(self.loadWindowStartedAt) or now
    self.loadWindowEvents = (tonumber(self.loadWindowEvents) or 0) + 1
    local elapsed = now - self.loadWindowStartedAt
    if elapsed >= 1000 then
        self.combatEventRate = self.loadWindowEvents * 1000 / math.max(elapsed, 1)
        if self.combatEventRate >= C.HIGH_LOAD_EVENT_RATE then
            self.highLoadUntil = now + C.HIGH_LOAD_HOLD_MS
        end
        self.loadWindowStartedAt = now
        self.loadWindowEvents = 0
    end
end

function R:IsHighLoad(now)
    now = tonumber(now) or U.NowMs()
    return now < (tonumber(self.highLoadUntil) or 0)
end

function R:BeginBaselineInitialization()
    if Store.baselineStats ~= nil then return false end
    self.baselineInitializing = true
    self.baselineSnapshotPurpose = "STARTUP"
    self.baselineCopyRevision = tonumber(S.statsMutationRevision) or 0
    self.baselineCopyRoot = D.State.stats
    self.baselineCopyJob = U.BeginIncrementalDeepCopy(D.State.stats)
    self.baselineEventQueue = type(self.baselineEventQueue) == "table" and self.baselineEventQueue or {}
    self.baselineQueueCursor = math.max(1, math.floor(tonumber(self.baselineQueueCursor) or 1))
    return true
end

-- Freeze the already-committed totals before releasing a full correction
-- window. Incoming callbacks are queued while the detached baseline is copied,
-- so the snapshot cannot accidentally include half of the next window. This is
-- what makes bounded-window replay safe after the complete historical journal
-- has rolled.
function R:BeginCorrectionWindowBaseline(reason)
    if self.baselineInitializing == true then return false end
    Store.baselineStats = nil
    Store.windowReplaySafe = false
    self.baselineInitializing = true
    self.baselineSnapshotPurpose = "CORRECTION_WINDOW"
    self.baselineSnapshotReason = tostring(reason or "CORRECTION_WINDOW_ROLLED")
    self.baselineCopyRevision = tonumber(S.statsMutationRevision) or 0
    self.baselineCopyRoot = D.State.stats
    self.baselineCopyJob = U.BeginIncrementalDeepCopy(D.State.stats)
    self.baselineEventQueue = {}
    self.baselineQueueCursor = 1
    return true
end

function R:QueueBaselineCombat(receivedAt, unitId, eventType, sourceName, targetName,
    abilityId, abilityName, damageType, effectType, isActive, more, more2, more3, more4, more5)
    self.baselineEventQueue = self.baselineEventQueue or {}
    -- 启动基线复制期间可能积压数百条战斗消息；直接构造位置行，不先创建
    -- 一张临时 vararg 数组再逐字段复制。
    self.baselineEventQueue[#self.baselineEventQueue + 1] = {
        1, receivedAt, unitId, eventType, sourceName, targetName, abilityId, abilityName,
        damageType, effectType, isActive, more, more2, more3, more4, more5,
    }
    D.Diagnostics.counters.baselineQueuedEvents =
        (tonumber(D.Diagnostics.counters.baselineQueuedEvents) or 0) + 1
end

function R:QueueBaselineDeath(receivedAt, info1, info2, info3, info4)
    self.baselineEventQueue = self.baselineEventQueue or {}
    self.baselineEventQueue[#self.baselineEventQueue + 1] = { 2, receivedAt, info1, info2, info3, info4 }
    D.Diagnostics.counters.baselineQueuedEvents =
        (tonumber(D.Diagnostics.counters.baselineQueuedEvents) or 0) + 1
end

function R:ProcessBaselineInitialization(copyBudget, drainBudget)
    if self.baselineInitializing ~= true then return true end
    if Store.baselineStats ~= nil then
        self.baselineCopyJob = nil
    elseif self.baselineCopyRoot ~= D.State.stats
        or tonumber(self.baselineCopyRevision) ~= (tonumber(S.statsMutationRevision) or 0) then
        self.baselineCopyRevision = tonumber(S.statsMutationRevision) or 0
        self.baselineCopyRoot = D.State.stats
        self.baselineCopyJob = U.BeginIncrementalDeepCopy(D.State.stats)
        D.Diagnostics.counters.baselineCopyRestarts =
            (tonumber(D.Diagnostics.counters.baselineCopyRestarts) or 0) + 1
    end

    if Store.baselineStats == nil then
        local done, processed, err = U.StepIncrementalDeepCopy(
            self.baselineCopyJob,
            math.max(1, math.floor(tonumber(copyBudget) or 3000))
        )
        D.Diagnostics.counters.baselineCopyFields =
            (tonumber(D.Diagnostics.counters.baselineCopyFields) or 0) + (tonumber(processed) or 0)
        if err ~= nil then error(err) end
        if not done then return false end
        Store.baselineStats = self.baselineCopyJob.result
        if self.baselineSnapshotPurpose == "CORRECTION_WINDOW" then
            Store.windowReplaySafe = Store.baselineStats ~= D.State.stats
        elseif Store.historyCoverageComplete ~= false then
            Store.windowReplaySafe = true
        end
        self.baselineCopyJob = nil
        self.baselineCopyRoot = nil
    end

    local queue = self.baselineEventQueue or {}
    local cursor = math.max(1, math.floor(tonumber(self.baselineQueueCursor) or 1))
    local budget = math.max(1, math.floor(tonumber(drainBudget) or 200))
    local processed = 0
    self.processingBaselineQueue = true
    while cursor <= #queue and processed < budget do
        local row = queue[cursor]
        -- Do not create holes while the queue is draining: Lua's length
        -- operator is undefined for sparse arrays and could end the drain early.
        -- Rows are released together when the cursor reaches the stable tail.
        cursor = cursor + 1
        processed = processed + 1
        if type(row) == "table" and row[1] == 1 then
            self:HandleCombatMessage(
                row[3], row[4], row[5], row[6], row[7], row[8], row[9], row[10],
                row[11], row[12], row[13], row[14], row[15], row[16], row[2]
            )
        elseif type(row) == "table" and row[1] == 2 then
            self:HandleDeathNotice(row[3], row[4], row[5], row[6], row[2])
        end
    end
    self.processingBaselineQueue = false
    self.baselineQueueCursor = cursor
    D.Diagnostics.counters.baselineDrainedEvents =
        (tonumber(D.Diagnostics.counters.baselineDrainedEvents) or 0) + processed

    if cursor > #queue then
        self.baselineInitializing = false
        self.baselineEventQueue = {}
        self.baselineQueueCursor = 1
        self.baselineSnapshotPurpose = nil
        self.baselineSnapshotReason = nil
        self.correctionRotationContext = nil
        -- A very large burst can fill another correction window while the first
        -- detached baseline is still being copied/drained. Start the next roll
        -- only after the current queue is completely stable; no callback is lost
        -- and the event handler never recursively rotates inside the drain loop.
        local correctionLimit = math.max(1000,
            math.floor(tonumber(C.MAX_CORRECTION_JOURNAL_EVENTS) or 4000))
        if #(Store.sessionEvents or {}) >= correctionLimit then
            self:RotateCorrectionJournal("MAX_CORRECTION_JOURNAL_EVENTS_AFTER_DRAIN")
            return false
        end
        return true
    end
    return false
end

-- rc18 滚动纠错窗口：正式累计 Stats 是产品 Authority；事件日志只承担近期纠错。
-- 达到上限时先分帧冻结独立基线，再释放旧 Fact/Classification/EventBlock。
-- 窗口以前的累计不变；最近窗口仍可进行完整事务重放，连续轮换也不会永久
-- 禁用人工纠错或后到 PLAYER/NPC 证据迁移。
-- Abort an in-progress correction-window freeze when an urgent manual/rule
-- correction arrives. The old retained journal is kept transactionally until
-- the detached baseline has fully committed, so a user click during those few
-- frames cannot make the just-released window permanently uncorrectable.
function R:AbortCorrectionWindowBaselineForReclassify(reason)
    local context = self.correctionRotationContext
    if self.baselineInitializing ~= true
        or self.baselineSnapshotPurpose ~= "CORRECTION_WINDOW"
        or type(context) ~= "table" then
        return false
    end

    local restored = {}
    for _, event in ipairs(type(context.events) == "table" and context.events or {}) do
        restored[#restored + 1] = event
    end
    -- Some queued callbacks may already have been normalized while the baseline
    -- queue was draining. Keep those journal rows exactly once; only raw rows at
    -- baselineQueueCursor and later are transferred to the replay queue.
    for _, event in ipairs(type(Store.sessionEvents) == "table" and Store.sessionEvents or {}) do
        restored[#restored + 1] = event
    end

    local queued = self.baselineEventQueue or {}
    local firstUnprocessed = math.max(1, math.floor(tonumber(self.baselineQueueCursor) or 1))
    self.replayEventQueue = type(self.replayEventQueue) == "table" and self.replayEventQueue or {}
    for index = firstUnprocessed, #queued do
        self.replayEventQueue[#self.replayEventQueue + 1] = queued[index]
    end

    Store.sessionEvents = restored
    Store.pending = {}
    Store.pendingCursor = 1
    Store.baselineStats = context.previousBaselineStats
    Store.historyCoverageComplete = context.previousHistoryCoverageComplete ~= false
    Store.historyCoverageReason = context.previousHistoryCoverageReason
    Store.windowReplaySafe = context.previousWindowReplaySafe == true
    -- Event Fact / Classification sidecars were reset when rotation began.
    -- Force bounded journal normalization before replay so they are rebuilt from
    -- the restored packed events rather than exposing an empty generation.
    Store.journalState = "NeedsRepair"
    Store.journalReplayLayoutVersion = REPLAY_LAYOUT_VERSION
    Store.journalStateVersion = (tonumber(Store.journalStateVersion) or 0) + 1

    self.baselineInitializing = false
    self.baselineCopyJob = nil
    self.baselineCopyRoot = nil
    self.baselineCopyRevision = nil
    self.baselineSnapshotPurpose = nil
    self.baselineSnapshotReason = nil
    self.baselineEventQueue = {}
    self.baselineQueueCursor = 1
    self.processingBaselineQueue = false
    self.correctionRotationContext = nil

    if Store.ResetIdentityIndex ~= nil then Store:ResetIdentityIndex() end
    EventFacts:OnEventStoreReset("correction_window_rotation_aborted")
    CallEventBlocks("OnEventStoreReset", "correction_window_rotation_aborted")
    EventClassifications:OnEventStoreReset("correction_window_rotation_aborted")
    CallEventShadow("OnEventStoreReset", "correction_window_rotation_aborted")
    self:ResetDormantEvidenceIndex(true)

    local released = math.max(0, math.floor(tonumber(context.released) or 0))
    D.Diagnostics.counters.correctionJournalRollovers = math.max(0,
        (tonumber(D.Diagnostics.counters.correctionJournalRollovers) or 0) - 1)
    D.Diagnostics.counters.correctionJournalEventsReleased = math.max(0,
        (tonumber(D.Diagnostics.counters.correctionJournalEventsReleased) or 0) - released)
    D.Diagnostics.counters.correctionJournalRotationAborts =
        (tonumber(D.Diagnostics.counters.correctionJournalRotationAborts) or 0) + 1
    if D.State.config.diagnosticsEnabled == true then
        D.Diagnostics:AddInfo("journal_window",
            "rotation aborted for reclassification; restored=" .. tostring(#restored)
                .. "; queued=" .. tostring(math.max(0, #queued - firstUnprocessed + 1))
                .. "; reason=" .. tostring(reason or "URGENT_RECLASSIFY"))
    end
    return true
end

function R:RotateCorrectionJournal(reason)
    local events = Store.sessionEvents or {}
    local released = #events
    if released <= 0 then return false end
    if self.baselineInitializing == true then return false end
    -- Never freeze a window while a full/manual reclassification is waiting or
    -- executing. Otherwise the rotation clears its dirty flags and the exact
    -- events needed to migrate the old Side/mode become unrecoverable.
    if self.replayJob ~= nil or self.fullReclassifyRequested == true
        or self.reclassifyAfterReplay == true then
        if self.correctionRotationDeferred ~= true then
            D.Diagnostics.counters.correctionJournalRotationsDeferred =
                (tonumber(D.Diagnostics.counters.correctionJournalRotationsDeferred) or 0) + 1
        end
        self.correctionRotationDeferred = true
        return false
    end

    -- pending/third-party summaries are diagnostic projections, not product
    -- totals. They cannot be frozen into the detached baseline because the old
    -- rows are no longer retryable after this window is released.
    for _, modeName in ipairs({ "PVP", "PVE" }) do
        local modeStats = S:GetMode(modeName, true)
        modeStats.pending = EmptySummary()
        modeStats.thirdParty = EmptySummary()
    end
    if S.MarkStatsMutated ~= nil then S:MarkStatsMutated(false) end

    -- Freeze all committed totals incrementally. Keep the released journal in a
    -- short-lived transaction until the baseline and queued-event drain finish.
    -- An urgent manual correction can then abort the rotation and restore the
    -- exact current window instead of losing its reclassification facts.
    self.correctionRotationContext = {
        events = events,
        released = released,
        previousBaselineStats = Store.baselineStats,
        previousHistoryCoverageComplete = Store.historyCoverageComplete,
        previousHistoryCoverageReason = Store.historyCoverageReason,
        previousWindowReplaySafe = Store.windowReplaySafe,
    }
    if not self:BeginCorrectionWindowBaseline(reason) then
        self.correctionRotationContext = nil
        return false
    end

    Store.sessionEvents = {}
    Store.pending = {}
    Store.pendingCursor = 1
    Store.journalState = "ValidatedDense"
    Store.journalReplayLayoutVersion = REPLAY_LAYOUT_VERSION
    Store.journalStateVersion = (tonumber(Store.journalStateVersion) or 0) + 1
    Store.historyCoverageComplete = false
    Store.historyCoverageReason = tostring(reason or "CORRECTION_WINDOW_ROLLED")
    Store.windowReplaySafe = false
    if Store.ResetIdentityIndex ~= nil then Store:ResetIdentityIndex() end
    EventFacts:OnEventStoreReset("correction_window_rolled")
    CallEventBlocks("OnEventStoreReset", "correction_window_rolled")
    EventClassifications:OnEventStoreReset("correction_window_rolled")
    CallEventShadow("OnEventStoreReset", "correction_window_rolled")
    self:ResetDormantEvidenceIndex(true)

    self.pendingTrimTarget = nil
    self.pendingTrimCursor = 1
    self.fullReclassifyRequested = false
    self.reclassifyRequestedAt = nil
    self.lastPendingReclassifyAt = nil
    self.pendingEvidenceChanged = false
    self.pendingEvidenceRequestedAt = nil
    self.correctionRotationDeferred = nil
    D.State.dirty.reclassify = false
    D.Diagnostics.counters.pendingEvents = 0
    D.Diagnostics.counters.thirdPartyEvents = 0
    D.Diagnostics.counters.correctionJournalRollovers =
        (tonumber(D.Diagnostics.counters.correctionJournalRollovers) or 0) + 1
    D.Diagnostics.counters.correctionJournalEventsReleased =
        (tonumber(D.Diagnostics.counters.correctionJournalEventsReleased) or 0) + released
    if D.State.config.diagnosticsEnabled == true then
        D.Diagnostics:AddInfo("journal_window",
            "released=" .. tostring(released)
            .. "; totals frozen; current window remains replayable after baseline copy")
    end
    return true
end

function R:HandleCombatMessage(unitId, eventType, sourceName, targetName, abilityId, abilityName, damageType, effectType, isActive, more, more2, more3, more4, more5, queuedTimestamp)
    if D.State.runtime.paused then return end
    local processingNow = U.NowMs()
    local receivedAt = U.FiniteNumber(queuedTimestamp, processingNow) or processingNow
    -- v0.2.25（问题 7）：分帧重放期间，新战斗事件进入有序队列，等待
    -- 重放提交后按原接收时间、原顺序补处理，保证不丢失、不重复、
    -- 不混入半重放状态。
    if self.replaying == true and self.processingReplayQueue ~= true then
        self.replayEventQueue = self.replayEventQueue or {}
        -- Replay can overlap a resumed raid for several seconds. Store queued
        -- callbacks as a positional row rather than a 17-key hash table so a
        -- burst does not create another large short-lived object graph.
        self.replayEventQueue[#self.replayEventQueue + 1] = {
            1, receivedAt,
            unitId, eventType, sourceName, targetName, abilityId, abilityName,
            damageType, effectType, isActive, more, more2, more3, more4, more5,
        }
        return
    end
    if self.baselineInitializing == true and self.processingBaselineQueue ~= true then
        self:QueueBaselineCombat(receivedAt, unitId, eventType, sourceName, targetName, abilityId,
            abilityName, damageType, effectType, isActive, more, more2, more3, more4, more5)
        return
    end
    -- Roll the bounded correction window before normalizing or publishing the
    -- callback that crosses the limit. The callback is queued while the detached
    -- baseline is copied, guaranteeing it belongs wholly to the new window and
    -- can never be half-frozen into the old baseline.
    if self.processingBaselineQueue ~= true then
        Store.sessionEvents = Store.sessionEvents or {}
        local correctionLimit = math.max(1000,
            math.floor(tonumber(C.MAX_CORRECTION_JOURNAL_EVENTS) or 4000))
        if #Store.sessionEvents >= correctionLimit
            and self:RotateCorrectionJournal("MAX_CORRECTION_JOURNAL_EVENTS") then
            self:QueueBaselineCombat(receivedAt, unitId, eventType, sourceName, targetName, abilityId,
                abilityName, damageType, effectType, isActive, more, more2, more3, more4, more5)
            return
        end
    end
    local now = receivedAt
    self.lastCombatEventAt = processingNow
    self:RecordCombatLoad(processingNow)
    local event, rawSource, target = self:NormalizeCombatEvent(unitId, eventType, sourceName, targetName, abilityId,
        abilityName, damageType, effectType, isActive, more, more2, more3, more4, more5, now)
    D.Diagnostics.counters.rawEvents = D.Diagnostics.counters.rawEvents + 1
    if D.State.config.diagnosticsEnabled == true then
        D.Diagnostics.lastCombatSample = event
    end
    Store:PushRaw(event)

    -- rc3：最后一击功能已从正式运行链路停用。旧实现会为每条伤害维护
    -- 2000 槽候选环并在死亡通知时倒扫；300 人世界 Boss 中这是纯额外热路径。
    -- 伤害、承伤和治疗统计不依赖该缓存，因此直接跳过。

    if event.parseStatus ~= "OK" and event.category ~= "MISS" and event.category ~= "DEATH" then
        D.Diagnostics.counters.parseFailures = D.Diagnostics.counters.parseFailures + 1
        if D.State.config.diagnosticsEnabled then
            D.Diagnostics:AddWarning("combat_parse", event.eventType .. " amount unresolved")
        end
        EventClassifications:DiscardUnjournaled(event, "PARSE_FAILURE")
        return
    end

    D.Diagnostics.counters.parsedEvents = D.Diagnostics.counters.parsedEvents + 1
    local source = ResolveEffectiveSource(rawSource)
    if event.environmental == true then
        -- Raw diagnostics already received the event above. Environmental rows
        -- never enter the correction journal or formal statistics, so do not
        -- open an EventClassification mutation that cannot acquire a published
        -- Authority row. Discard both live drafts directly.
        event.classificationStatus = "ENVIRONMENT_EXCLUDED"
        EventFacts:DiscardUnjournaled(event, "ENVIRONMENT_EXCLUDED")
        EventClassifications:DiscardUnjournaled(event, "ENVIRONMENT_EXCLUDED")
        D.MarkViewDirty()
        return
    end
    if event.category ~= "DAMAGE" and event.category ~= "HEAL" then
        -- MISS/DEATH/OTHER 只属于诊断，不会影响三张核心榜。RC3 不再调用
        -- TryClassifyAndApply，确保 COMBAT_MSG 中的死亡形态也不会产生新 kills。
        EventFacts:DiscardUnjournaled(event, "NON_STAT_EVENT")
        EventClassifications:DiscardUnjournaled(event, "NON_STAT_EVENT")
        return
    end
    Store.sessionEvents = Store.sessionEvents or {}
    -- v0.2.25（问题 4/1）：统一追加入口（稠密日志直接追加 + 增量登记索引）。
    local sessionIndex = Store:AppendSessionEvent(event)
    if sessionIndex < 1 then
        -- 日志处于修复中：先修复再追加（罕见路径）。
        self:NormalizeEventStore()
        sessionIndex = Store:AppendSessionEvent(event)
    end
    -- RC4：从正式日志发布完成开始，把本次事件的所有可变分类写入同一
    -- sidecar mutation。ApplyCombatEvidence、模式解析和最终状态只提交一次，
    -- 避免一条 COMBAT_MSG 触发几十次列写入和 revision 更新。
    if type(EventClassifications.BeginMutation) == "function" then
        EventClassifications:BeginMutation(event, "LIVE")
    end

    -- v0.2.25（性能）：live 路径同样先计算一次关系快照。ApplyCombatEvidence
    -- 若通过 ApplyStrongRelation 修改了关系会返回 modified，TryClassifyAndApply
    -- 据此用最新关系重算；未修改时全链路只做 4 次关系判断（旧实现 12 次）。
    -- 关系快照只在本次同步回调中使用，复用一张运行时表，避免每条战斗
    -- 消息再创建一个短命哈希表。事件回调在客户端 Lua 主线程串行执行，
    -- 下游不会保存该引用；重放路径仍使用自己的局部快照。
    local liveRelCache = self.liveRelationCache
    if type(liveRelCache) ~= "table" then
        liveRelCache = {}
        self.liveRelationCache = liveRelCache
    end
    FillRelationCache(liveRelCache, source, target, event.timestamp)
    local evidenceModified = ApplyCombatEvidence(event, liveRelCache, source, target)
    local applied, sourceProjectionSide, targetProjectionSide =
        self:TryClassifyAndApply(event, false, liveRelCache, evidenceModified, false,
            rawSource, source, target, nil, true)
    if applied and event.modeProvisional == true then
        D.Diagnostics.counters.dataFirstAdmissions =
            (tonumber(D.Diagnostics.counters.dataFirstAdmissions) or 0) + 1
    end
    local storedEvent = PackReplayEvent(event, false, sessionIndex)
    Store.sessionEvents[sessionIndex] = storedEvent
    if applied and (storedEvent.modeProvisional == true
        or storedEvent.relationProvisional == true) then
        RegisterDormantEvidenceEvent(self, storedEvent)
    elseif not applied then
        self:QueuePending(storedEvent)
        D.MarkViewDirty()
    end
end

function R:ClearAllCombatData()
    -- Clearing statistics is a hard session boundary. Remove every pre-clear
    -- replay source so old PVP/PVE damage, taken, healing or inferred last hits
    -- cannot flow back into the fresh tables during a later reclassification.
    Store.baselineStats = U.DeepCopy(D.State.stats)
    Store.sessionEvents = {}
    Store.pending = {}
    Store.pendingCursor = 1
    Store.journalState = "ValidatedDense"
    Store.journalReplayLayoutVersion = REPLAY_LAYOUT_VERSION
    Store.journalStateVersion = (tonumber(Store.journalStateVersion) or 0) + 1
    Store.historyCoverageComplete = true
    Store.historyCoverageReason = nil
    Store.windowReplaySafe = true
    -- A clear can occur while a startup/correction baseline is being copied or
    -- drained. Cancel every snapshot/queue cursor so a stale pre-clear baseline
    -- or queued callback cannot resurrect old totals after the new empty session
    -- has already been published.
    self.baselineInitializing = false
    self.baselineCopyJob = nil
    self.baselineCopyRoot = nil
    self.baselineCopyRevision = nil
    self.baselineSnapshotPurpose = nil
    self.baselineSnapshotReason = nil
    self.correctionRotationContext = nil
    self.correctionRotationDeferred = nil
    self.baselineEventQueue = {}
    self.baselineQueueCursor = 1
    self.processingBaselineQueue = false
    if Store.ResetRawRing ~= nil then Store:ResetRawRing() else Store.raw = {} end
    -- v0.2.25（问题 10）：清空环形缓冲（保留槽数组引用，不重建大表）。
    ResetRecentDamageRing()
    Store.nextId = 1
    -- v0.2.25（问题 1）：日志被整体替换，反向索引必须失效并惰性重建。
    if Store.ResetIdentityIndex ~= nil then Store:ResetIdentityIndex() end
    EventFacts:OnEventStoreReset("clear_all_combat_data")
    CallEventBlocks("OnEventStoreReset", "clear_all_combat_data")
    EventClassifications:OnEventStoreReset("clear_all_combat_data")
    CallEventShadow("OnEventStoreReset", "clear_all_combat_data")
    self:ResetDormantEvidenceIndex(true)

    self.pendingDeathNotices = {}
    self.lastDeathByEventId = {}
    -- v0.2.25（问题 7）：清空必须取消进行中的分帧重放，防止重放
    -- 在已清空的新统计上继续写入。
    S.replayWorkingStats = nil
    self.replayJob = nil
    self.replaying = false
    D.State.runtime.replaying = false
    self.replayEventQueue = {}
    self.processingReplayQueue = false
    self.sessionCompactionRequested = false
    self.sessionCompactionRequestedAt = nil
    self.sessionCompactionCursor = 1
    self.sessionCompactionNextAt = nil
    self.sessionCompactionDeferredCount = nil
    self.retiredThirdPartySinceCompact = 0
    self.pendingTrimTarget = nil
    self.pendingTrimCursor = 1
    self.nextPendingDeathResolveAt = nil
    self.reclassifyRequestedAt = nil
    self.lastPendingReclassifyAt = nil
    self.fullReclassifyRequested = false
    self.pendingEvidenceChanged = false
    self.pendingEvidenceRequestedAt = nil
    self.reclassifyAfterReplay = nil
    self.reclassifyAfterReplayReason = nil
    self.reclassifyAfterReplayActor = nil
    self.pendingEvidenceAfterReplay = nil
    self.loadWindowStartedAt = U.NowMs()
    self.loadWindowEvents = 0
    self.combatEventRate = 0
    self.highLoadUntil = 0
    self.coverageWarningShown = nil

    -- rc3：清空只重置累计统计与事件日志，不再清除已学到的友军/敌军关系。
    -- 实机确认，清掉软关系后团队外绿名会重新变成 UNKNOWN，导致清空后新数据
    -- 长时间全部进入 pending。身份观察、人工规则和关系证据属于归类知识，
    -- 应跨统计清空保留；冲突提示本身仍可清空。
    if D.RelationConflicts ~= nil and D.RelationConflicts.Reset ~= nil then
        D.RelationConflicts:Reset()
    end

    D.State.dirty.reclassify = false
    D.Diagnostics.counters.pendingEvents = 0
    D.Diagnostics.counters.thirdPartyEvents = 0
    self:RecomputePendingSummaries()
    D.MarkViewDirty()
    return true
end

function R:RestoreClearedMode(mode)
    if mode == "ALL" then
        -- ClearAllCombatData established an empty post-clear baseline and
        -- journal. Merge any post-clear compacted totals into the restored
        -- snapshot, then replay the remaining post-clear events exactly once.
        local restoredBaseline = U.DeepCopy(D.State.stats)
        if type(Store.baselineStats) == "table" and S.MergeStatsRoot ~= nil then
            restoredBaseline = S:MergeStatsRoot(restoredBaseline, Store.baselineStats)
        end
        Store.baselineStats = restoredBaseline
        D.State.dirty.reclassify = true
        self.reclassifyReason = "RESTORE_CLEAR_ALL"
        self:BeginReplaySessionStats()
        return true
    end

    if mode ~= "PVP" and mode ~= "PVE" then return false end
    Store.baselineStats = Store.baselineStats or U.DeepCopy(D.State.stats)
    Store.baselineStats[mode] = U.DeepCopy(D.State.stats[mode])
    -- Pre-clear events are already represented by the restored snapshot and
    -- remain marked expired for this mode. Post-clear events are replayed on
    -- top, while the other mode's session journal is preserved.
    D.State.dirty.reclassify = true
    self.reclassifyReason = "RESTORE_CLEAR_MODE"
    self:BeginReplaySessionStats()
    return true
end

function R:CanReplayCurrentWindow()
    if self.baselineInitializing == true then return false end
    if Store.baselineStats == nil or Store.baselineStats == D.State.stats then return false end
    if Store.historyCoverageComplete ~= false then return true end
    return Store.windowReplaySafe == true
end

function R:RequestReclassify(preferImmediate, reason, affectedActor)
    local now = U.NowMs()
    D.State.dirty.reclassify = true

    -- A correction-window baseline is a reversible transaction until commit.
    -- Urgent user/rule edits must restore that journal before requesting replay;
    -- otherwise the just-rotated 4,000 rows are frozen under the old identity.
    if preferImmediate == true and self.baselineInitializing == true
        and self.baselineSnapshotPurpose == "CORRECTION_WINDOW" then
        self:AbortCorrectionWindowBaselineForReclassify(reason)
    end

    if self.replayJob ~= nil and preferImmediate ~= true then
        -- Non-urgent evidence can arrive after the current replay cursor has
        -- already passed the affected event.  The old DONE path cleared every
        -- dirty flag unconditionally, swallowing that request.  Preserve one
        -- coalesced follow-up transaction; urgent user edits still cancel and
        -- restart immediately through the existing path below.
        self.reclassifyAfterReplay = true
        if reason ~= nil and tostring(reason) ~= "" then
            self.reclassifyAfterReplayReason = tostring(reason)
        end
        if type(affectedActor) == "table" then
            self.reclassifyAfterReplayActor = affectedActor
        end
        self.reclassifyRequestedAt = tonumber(self.reclassifyRequestedAt) or now
        return false
    end

    if Store.historyCoverageComplete == false and not self:CanReplayCurrentWindow() then
        -- Keep the full request itself alive. Downgrading it to a pending-only
        -- pass loses already-applied wrong-Side/provisional rows; once the
        -- detached baseline becomes safe, OnUpdate starts this same transaction.
        self.fullReclassifyRequested = true
        self.reclassifyUrgent = preferImmediate == true or self.reclassifyUrgent == true
        if reason ~= nil and tostring(reason) ~= "" then self.reclassifyReason = tostring(reason) end
        self.reclassifyRequestedAt = tonumber(self.reclassifyRequestedAt) or now
        self.pendingEvidenceChanged = true
        self.pendingEvidenceRequestedAt = tonumber(self.pendingEvidenceRequestedAt) or now
        D.Diagnostics.counters.fullReplaysBlockedByCoverage =
            (tonumber(D.Diagnostics.counters.fullReplaysBlockedByCoverage) or 0) + 1
        if self.coverageWarningShown ~= true then
            self.coverageWarningShown = true
            D.Diagnostics:AddWarning("reclassify",
                "correction baseline not ready; full current-window replay retained")
        end
        return false
    end
    if Store.historyCoverageComplete == false and self.coverageWindowInfoShown ~= true then
        self.coverageWindowInfoShown = true
        D.Diagnostics:AddInfo("reclassify",
            "older totals frozen; replaying retained correction window only")
    end
    self.fullReclassifyRequested = true
    self.reclassifyUrgent = preferImmediate == true or self.reclassifyUrgent == true
    if reason ~= nil and tostring(reason) ~= "" then self.reclassifyReason = tostring(reason) end
    self.reclassifyRequestedAt = tonumber(self.reclassifyRequestedAt) or now

    -- v0.2.25（问题 7）：新人工纠错到达时，正在进行的重放基于旧身份
    -- 状态，结果已过时——取消旧重放并重新开始，避免提交混合结果。
    -- 已排队的战斗/死亡事件立即按原顺序补处理（它们只是被延迟了，
    -- 不能被丢弃；重放被取消后无需再等下次重放）。
    if self.replayJob ~= nil and preferImmediate == true then
        local cancelledJob = self.replayJob
        -- The urgent request supersedes any coalesced follow-up that belonged
        -- to the cancelled transaction. The replacement replay will observe the
        -- latest Authority state from its first event.
        self.reclassifyAfterReplay = nil
        self.reclassifyAfterReplayReason = nil
        self.reclassifyAfterReplayActor = nil
        self.pendingEvidenceAfterReplay = nil
        -- 重算可能已经进入 DRAIN_QUEUE：其中一部分排队事件已追加到日志并
        -- 写入刚提交的工作统计。只丢弃 workingStats 会让这些事件“在日志中
        -- 但不在回滚后的统计中”；再从队列头重放又会重复追加。统一回滚原始
        -- 事件/实体状态，再按 eventTotal 之后的现有日志增量重新投影，并只处理
        -- drainCursor 之后尚未消费的队列行。
        self:RollbackReplaySessionStats(cancelledJob)
        S.replayWorkingStats = nil
        self.replayJob = nil
        self.replaying = false
        D.State.runtime.replaying = false
        self:RecoverReplayQueueAfterRollback(cancelledJob)
        self:ResetDormantEvidenceIndex(false)
        D.Diagnostics.counters.replayCancels =
            (tonumber(D.Diagnostics.counters.replayCancels) or 0) + 1
    end

    -- prep10：人工单 Actor 纠错先建立诊断影响闭包。正式结果仍只由
    -- 完整事务重放提交；规划器只在重放后验证事件覆盖是否安全。
    CallLocalReplay("BeginPlan", affectedActor, self.reclassifyReason or reason or "FULL_REPLAY")

    -- 不在按钮回调栈里直接开始重放。连续设置“玩家/友军/敌军”时可能在
    -- 数十毫秒内产生多次人工修改；由 OnUpdate 在 100ms 后合并为一次紧急、
    -- 分帧重放，既能及时刷新归属，也避免第一项修改启动的 PREPARE 任务被第二
    -- 项修改立即取消并回滚。
    return false
end

function R:RequestPendingReclassify()
    D.State.dirty.reclassify = true
    if self.replayJob ~= nil then
        -- Keep evidence that arrived after the replay cursor.  It may already be
        -- included, but one bounded pending pass after commit is cheaper and
        -- safer than silently losing a valid wake-up.
        self.pendingEvidenceAfterReplay = true
        return false
    end
    self.pendingEvidenceChanged = true
    self.pendingEvidenceRequestedAt = tonumber(self.pendingEvidenceRequestedAt) or U.NowMs()
    return false
end

------------------------------------------------------------------------
-- 分帧事务重放（问题 4/5/7/8 修复）
--
-- 设计目标：
--   1. 重放绝不一次性处理全部历史事件（问题 7）：StepReplaySessionStats
--      每帧只处理固定预算，由 OnUpdate 分帧驱动。
--   2. 全程只有一份工作统计（问题 5）：统计写入 S.replayWorkingStats，
--      旧 D.State.stats 继续供 UI 显示；提交时才原子替换引用。
--   3. 日志状态（问题 4）：只有 NeedsRepair 才调用 NormalizeEventStore；
--      ValidatedDense/ValidatedSparse 直接接管，不做重复全量检查。
--   4. 热重载快速路径（问题 8）：稠密数组直接接管，索引分帧重建。
--
-- 状态机阶段：
--   PREPARE         记录回滚引用（不深拷贝统计）、分帧快照实体/事件状态
--   RESET_EVIDENCE  分帧重置实体软证据（StepResetSoftEvidence）
--   REPLAY_EVIDENCE 分帧重建战斗证据（ApplyCombatEvidence）
--   DECAY           分帧衰减分数（BeginDecayScores + Step）
--   CREATE_WORKING  分帧深拷贝基线 → 单工作副本；处理 dormant third-party
--   REPLAY_BATCH    分帧 TryClassifyAndApply 每个事件（写入工作副本）
--   FINALIZE        RecomputePendingSummaries / UpdateClosure（作用于工作副本）
--   REBUILD_INDEX   分帧重建身份反向索引
--   COMMIT          原子替换 D.State.stats 与 Store.baselineStats 引用
--   DRAIN_QUEUE     按原顺序补处理重放期间排队的新事件
--
-- 失败语义：任意阶段抛错 → 恢复旧统计引用与实体/事件状态快照，丢弃工作
--   副本，dirty.reclassify 保留以便重试；旧统计全程可用，绝无混合。
------------------------------------------------------------------------

-- v0.2.29：完整重放失败时需要恢复事件状态，但旧版为每条事件保存 35 个
-- 数字槽，其中 17 个只是 true/false/nil。十万事件会创建 350 万槽，百万
-- 事件时单是回滚快照就可能耗尽客户端内存。Lua number 可精确表示 53 位
-- 整数；这里用 2 bit 编码一个三态布尔（nil/false/true），17 项只占 34 bit。
-- 其余字符串/ID 保持原值，失败回滚仍逐字段等价。
local REPLAY_BOOLEAN_FIELDS = {
    "applied", "pending", "thirdParty", "retiredThirdParty",
    "dormantThirdParty", "dormantPending", "repdpsSummaryTracked",
    "repdpsSummaryThirdParty", "modeProvisional", "relationProvisional",
    "healRelationConflict", "friendlyFire", "opponentInternalDamage",
    "sourceBindingAmbiguous", "targetBindingAmbiguous",
    "sourceKeyAuthoritative", "targetKeyAuthoritative",
}

local function EncodeReplayBooleanState(event)
    local code = 0
    local factor = 1
    for index = 1, #REPLAY_BOOLEAN_FIELDS do
        local value = event[REPLAY_BOOLEAN_FIELDS[index]]
        local state = value == true and 2 or (value == false and 1 or 0)
        code = code + state * factor
        factor = factor * 4
    end
    return code
end

local function RestoreReplayBooleanState(event, code)
    code = math.max(0, math.floor(tonumber(code) or 0))
    for index = 1, #REPLAY_BOOLEAN_FIELDS do
        local state = code % 4
        code = math.floor(code / 4)
        event[REPLAY_BOOLEAN_FIELDS[index]] = state == 2 and true
            or (state == 1 and false or nil)
    end
end

local REPLAY_STATE_WIDTH = 19
R.replayStateWidth = REPLAY_STATE_WIDTH
R.replayBooleanFieldCount = #REPLAY_BOOLEAN_FIELDS

function R:BeginReplaySessionStats()
    if self.replayJob ~= nil or self.baselineInitializing == true then return false end
    if not self:CanReplayCurrentWindow() then
        D.Diagnostics.counters.fullReplaysBlockedByCoverage =
            (tonumber(D.Diagnostics.counters.fullReplaysBlockedByCoverage) or 0) + 1
        if Store.historyCoverageComplete == false then
            self.fullReclassifyRequested = false
            self.pendingEvidenceChanged = true
        end
        return false
    end
    -- 只有日志需要修复时才执行 NormalizeEventStore（问题 4）。
    if Store.journalState ~= "ValidatedDense" and Store.journalState ~= "ValidatedSparse" then
        self:NormalizeEventStore()
    end
    self.replaying = true
    self.reclassifyUrgent = false
    D.State.runtime.replaying = true
    -- 保留上一次取消重放时已排队的战斗/死亡事件：它们尚未被任何重放
    -- 提交处理过，必须继续累积到本次重放结束后统一补处理（不丢失）。
    self.replayEventQueue = type(self.replayEventQueue) == "table" and self.replayEventQueue or {}
    self.replayJob = {
        phase = "PREPARE",
        previousStats = D.State.stats,
        previousBaselineStats = Store.baselineStats,
        previousPending = Store.pending or {},
        previousStatsSaveDirty = D.State.dirty.statsSave,
        previousPendingCounter = D.Diagnostics.counters.pendingEvents,
        previousThirdPartyCounter = D.Diagnostics.counters.thirdPartyEvents,
        previousEvidenceCooldowns = U.DeepCopy(E.evidenceCooldowns or {}),
        previousBossRuntime = D.Analysis ~= nil and D.Analysis.SnapshotBossRuntime ~= nil
            and D.Analysis:SnapshotBossRuntime() or nil,
        previousEntityKeys = {},
        entityStates = {},
        replayStates = {},
        entitySnapshotJob = nil,
        eventSnapshotCursor = 1,
        replayStateCount = 0,
        eventTotal = #(Store.sessionEvents or {}),
        -- When complete history has rolled, baselineStats contains every frozen
        -- contribution before this retained window. Replay must preserve old
        -- relation evidence and rebuild only current-window classifications.
        partialWindowReplay = Store.historyCoverageComplete == false,
        eventCount = 0,
        entityBudget = 0,
        evidenceCursor = 1,
        workingStats = nil,
        workingCopyJob = nil,
        workingDormantCursor = 1,
        replayCursor = 1,
        lastReplayAt = U.NowMs(),
        startedAt = U.NowMs(),
    }
    CallLocalReplay("OnFullReplayBegin",
        self.reclassifyReason or "FULL_REPLAY", #(Store.sessionEvents or {}))
    EventClassifications:BeginTransaction(
        self.reclassifyReason or "FULL_REPLAY", #(Store.sessionEvents or {}))
    CallEventShadow("BeginClassificationTransaction",
        self.reclassifyReason or "FULL_REPLAY", #(Store.sessionEvents or {}))
    return true
end

-- 回滚：恢复统计引用 + 分帧恢复实体/事件状态。返回 true 表示完成。
function R:RollbackReplaySessionStats(job)
    D.State.stats = job.previousStats
    Store.baselineStats = job.previousBaselineStats
    Store.pending = job.previousPending
    Store.pendingCursor = 1
    D.State.dirty.statsSave = job.previousStatsSaveDirty == true
    D.State.dirty.reclassify = true
    self.fullReclassifyRequested = true
    D.Diagnostics.counters.pendingEvents = job.previousPendingCounter
    D.Diagnostics.counters.thirdPartyEvents = job.previousThirdPartyCounter
    E.evidenceCooldowns = job.previousEvidenceCooldowns
    if D.Analysis ~= nil and D.Analysis.RestoreBossRuntime ~= nil then
        D.Analysis:RestoreBossRuntime(job.previousBossRuntime)
    end
    for entity, state in pairs(job.entityStates) do
        entity.relation = state.relation
        entity.strongRelation = state.strongRelation
        entity.strongRelationSince = state.strongRelationSince
        entity.strongRelationLastSeenAt = state.strongRelationLastSeenAt
        entity.strongRelationReason = state.strongRelationReason
        entity.historyRelation = state.historyRelation
        entity.relationHistory = U.DeepCopy(state.relationHistory or {})
        -- v0.2.25（问题 12）：回滚恢复的区间顺序可能不同于已缓存的标志。
        entity.repdpsRelationHistorySorted = nil
        entity.relationSince = state.relationSince
        entity.relationScores = U.DeepCopy(state.relationScores or {})
        entity.relationEvidenceKinds = U.DeepCopy(state.relationEvidenceKinds or {})
        entity.evidenceKinds = U.DeepCopy(state.evidenceKinds or {})
        entity.firstRelationEvidenceAt = state.firstRelationEvidenceAt
        entity.lastEvidenceAt = state.lastEvidenceAt
        entity.lastScoreDecayAt = state.lastScoreDecayAt
        entity.flags = entity.flags or {}
        entity.flags.relationReason = state.relationReason
    end
    for key in pairs(E.byKey or {}) do
        if job.previousEntityKeys[key] ~= true then E.byKey[key] = nil end
    end
    for normalized, key in pairs(E.byName or {}) do
        if E.byKey[key] == nil then E.byName[normalized] = nil end
    end
    for alias, key in pairs(E.aliases or {}) do
        if E.byKey[key] == nil then E.aliases[alias] = nil end
    end
    for index = 1, job.replayStateCount do
        local base = (index - 1) * REPLAY_STATE_WIDTH
        local event = job.replayStates[base + 1]
        RestoreReplayBooleanState(event, job.replayStates[base + 2])
        event.dormantSummaryMode = job.replayStates[base + 3]
        event.repdpsSummaryMode = job.replayStates[base + 4]
        event.classificationStatus = job.replayStates[base + 5]
        event.candidateMode = job.replayStates[base + 6]
        event.modeReason = job.replayStates[base + 7]
        event.provisionalFallbackMode = job.replayStates[base + 8]
        local expiredModes = job.replayStates[base + 9]
        event.expiredModes = expiredModes and U.DeepCopy(expiredModes) or nil
        event.sourceBindingQuality = job.replayStates[base + 10]
        event.targetBindingQuality = job.replayStates[base + 11]
        event.sourceBoundId = job.replayStates[base + 12]
        event.targetBoundId = job.replayStates[base + 13]
        event.sourceResolvedKey = job.replayStates[base + 14]
        event.targetResolvedKey = job.replayStates[base + 15]
        event.sourceObservedKind = job.replayStates[base + 16]
        event.targetObservedKind = job.replayStates[base + 17]
        event.sourceObservedKindQuality = job.replayStates[base + 18]
        event.targetObservedKindQuality = job.replayStates[base + 19]
    end
    EventClassifications:RollbackTransaction("production_replay_rollback")
    CallEventShadow("RollbackClassificationTransaction", "production_replay_rollback")
    CallLocalReplay("OnFullReplayRolledBack", "production_replay_rollback")
    D.MarkViewDirty()
end

-- 回滚后的排队事件恢复：
-- 1. eventTotal 之后已经追加到 sessionEvents 的行只重新投影，不再次追加；
-- 2. drainCursor 之后尚未消费的原始回调才重新走 Handle* 入口；
-- 3. 失败行保留到 replayEventQueue，下一次空闲重算仍可继续，不静默丢弃。
function R:RecoverReplayQueueAfterRollback(job)
    if type(job) ~= "table" then return true end
    local events = Store.sessionEvents or {}
    local firstAppended = math.max(1, math.floor(tonumber(job.eventTotal) or #events) + 1)
    local failed = {}

    -- DRAIN_QUEUE 已处理的行已经变成正式日志事件。旧统计引用刚刚恢复，
    -- 因此只清理本次投影状态并重新分类，绝不能重新生成 eventId/日志行。
    for index = firstAppended, #events do
        local event = events[index]
        if type(event) == "table" then
            event.applied = false
            event.pending = false
            event.thirdParty = false
            event.dormantThirdParty = nil
            event.dormantPending = nil
            event.dormantSummaryMode = nil
            event.repdpsSummaryTracked = nil
            event.repdpsSummaryMode = nil
            event.repdpsSummaryThirdParty = nil
            event.classificationStatus = "ROLLBACK_REAPPLY"
            local ok, applied = xpcall(function()
                return self:TryClassifyAndApply(event, true, nil, false, false)
            end, Boot.SafeTraceback)
            local stored = ReplaceSessionEvent(event, false)
            if ok then
                if not applied then self:QueuePending(stored) end
            else
                -- 事件已经安全留在日志中；保持为待确认，避免一次异常让它
                -- 从后续重放真值源中消失。
                stored.applied = false
                stored.pending = true
                stored.thirdParty = false
                stored.classificationStatus = "ROLLBACK_REAPPLY_FAILED"
                self:QueuePending(stored)
                D.Diagnostics:AddError("replay_rollback_event", tostring(applied))
            end
        end
    end

    local queue = self.replayEventQueue or {}
    local firstQueued = 1
    if job.phase == "DRAIN_QUEUE" or job.phase == "DONE" then
        firstQueued = math.max(1, math.floor(tonumber(job.drainCursor) or 1))
    end
    self.processingReplayQueue = true
    for index = firstQueued, #queue do
        local row = queue[index]
        local ok, err = xpcall(function()
            if type(row) == "table" and row[1] == 1 then
                self:HandleCombatMessage(
                    row[3], row[4], row[5], row[6], row[7], row[8], row[9], row[10],
                    row[11], row[12], row[13], row[14], row[15], row[16], row[2]
                )
            elseif type(row) == "table" and row[1] == 2 then
                self:HandleDeathNotice(row[3], row[4], row[5], row[6], row[2])
            elseif type(row) == "table" and row.kind == "combat" then
                self:HandleCombatMessage(
                    row.unitId, row.eventType, row.sourceName, row.targetName,
                    row.abilityId, row.abilityName, row.damageType, row.effectType,
                    row.isActive, row.more, row.more2, row.more3, row.more4, row.more5,
                    row.receivedAt
                )
            elseif type(row) == "table" and row.kind == "death" then
                self:HandleDeathNotice(row.info1, row.info2, row.info3, row.info4, row.receivedAt)
            end
        end, Boot.SafeTraceback)
        if not ok then
            failed[#failed + 1] = row
            D.Diagnostics:AddError("replay_rollback_queue", tostring(err))
        end
    end
    self.processingReplayQueue = false
    self.replayEventQueue = failed
    return #failed == 0
end

-- 推进一次重放事务。返回 true 表示全部完成。预算按阶段语义使用：
-- 事件处理按 eventBudget，实体处理按 entityBudget。
function R:StepReplaySessionStats(eventBudget, entityBudget)
    local job = self.replayJob
    if type(job) ~= "table" then return true end
    eventBudget = math.max(1, math.floor(tonumber(eventBudget) or 500))
    entityBudget = math.max(1, math.floor(tonumber(entityBudget) or 120))
    local protectedStep = function()
        local phase = job.phase

        if phase == "PREPARE" then
            -- 分帧构建实体状态快照（实体数量通常远小于事件数，但仍分帧）。
            local snapshotJob = job.entitySnapshotJob
            if snapshotJob == nil then
                snapshotJob = { lastKey = nil, root = E.byKey }
                job.entitySnapshotJob = snapshotJob
            end
            if snapshotJob.root ~= E.byKey then
                snapshotJob.root = E.byKey
                snapshotJob.lastKey = nil
            end
            local processed = 0
            local doneSnapshot = false
            while processed < entityBudget do
                local ok, key, entity = pcall(next, snapshotJob.root, snapshotJob.lastKey)
                if not ok then key = nil end
                if key == nil then
                    doneSnapshot = true
                    break
                end
                snapshotJob.lastKey = key
                job.previousEntityKeys[key] = true
                if type(entity) == "table" then
                    job.entityStates[entity] = {
                        relation = entity.relation,
                        strongRelation = entity.strongRelation,
                        strongRelationSince = entity.strongRelationSince,
                        strongRelationLastSeenAt = entity.strongRelationLastSeenAt,
                        strongRelationReason = entity.strongRelationReason,
                        historyRelation = entity.historyRelation,
                        relationHistory = U.DeepCopy(entity.relationHistory or {}),
                        relationSince = entity.relationSince,
                        relationScores = U.DeepCopy(entity.relationScores or {}),
                        relationEvidenceKinds = U.DeepCopy(entity.relationEvidenceKinds or {}),
                        evidenceKinds = U.DeepCopy(entity.evidenceKinds or {}),
                        firstRelationEvidenceAt = entity.firstRelationEvidenceAt,
                        lastEvidenceAt = entity.lastEvidenceAt,
                        lastScoreDecayAt = entity.lastScoreDecayAt,
                        relationReason = entity.flags and entity.flags.relationReason or nil,
                    }
                end
                processed = processed + 1
            end
            if not doneSnapshot then
                return false
            end
            job.entitySnapshotJob = nil
            job.phase = "EVENT_SNAPSHOT"
            return false
        end

        if phase == "EVENT_SNAPSHOT" then
            -- 分帧保存事件状态快照（回滚需要）。
            local events = Store.sessionEvents or {}
            local processed = 0
            local cursor = job.eventSnapshotCursor
            while cursor <= #events and processed < eventBudget do
                local event = events[cursor]
                if type(event) == "table" then
                    job.replayStateCount = job.replayStateCount + 1
                    local base = (job.replayStateCount - 1) * REPLAY_STATE_WIDTH
                    local rs = job.replayStates
                    rs[base + 1] = event
                    rs[base + 2] = EncodeReplayBooleanState(event)
                    rs[base + 3] = event.dormantSummaryMode
                    rs[base + 4] = event.repdpsSummaryMode
                    rs[base + 5] = event.classificationStatus
                    rs[base + 6] = event.candidateMode
                    rs[base + 7] = event.modeReason
                    rs[base + 8] = event.provisionalFallbackMode
                    local expiredModes = event.expiredModes
                    rs[base + 9] = type(expiredModes) == "table" and U.DeepCopy(expiredModes) or nil
                    rs[base + 10] = event.sourceBindingQuality
                    rs[base + 11] = event.targetBindingQuality
                    rs[base + 12] = event.sourceBoundId
                    rs[base + 13] = event.targetBoundId
                    rs[base + 14] = event.sourceResolvedKey
                    rs[base + 15] = event.targetResolvedKey
                    rs[base + 16] = event.sourceObservedKind
                    rs[base + 17] = event.targetObservedKind
                    rs[base + 18] = event.sourceObservedKindQuality
                    rs[base + 19] = event.targetObservedKindQuality
                    -- Seed every row into both production and diagnostic
                    -- working generations before replay. Retired rows skipped by
                    -- REPLAY_BATCH must still exist so commit is one pointer swap.
                    EventClassifications:SeedTransactionEvent(event, "REPLAY_SNAPSHOT")
                    CallEventShadow("ObserveClassification", event, "REPLAY_SNAPSHOT")
                end
                cursor = cursor + 1
                processed = processed + 1
            end
            job.eventSnapshotCursor = cursor
            if cursor <= #(Store.sessionEvents or {}) then return false end
            if job.partialWindowReplay == true then
                -- Frozen history still owns older relation scores/evidence. Do
                -- not erase or decay them when only the retained correction
                -- window can be replayed; just re-resolve current event identity
                -- and then rebuild its projections on top of the detached base.
                job.phase = "REPLAY_EVIDENCE"
                job.evidenceCursor = 1
                job.preserveHistoricalEvidence = true
            else
                job.phase = "RESET_EVIDENCE"
                job.softResetJob = E:BeginResetSoftEvidence()
            end
            return false
        end

        if phase == "RESET_EVIDENCE" then
            local doneReset, processed, nextJob = E:StepResetSoftEvidence(job.softResetJob, entityBudget)
            job.softResetJob = nextJob
            if not doneReset then return false end
            job.phase = "REPLAY_EVIDENCE"
            job.evidenceCursor = 1
            return false
        end

        if phase == "REPLAY_EVIDENCE" then
            -- 重建战斗证据（分帧）。
            local events = Store.sessionEvents or {}
            local processed = 0
            local cursor = job.evidenceCursor
            while cursor <= #events and processed < eventBudget do
                local event = events[cursor]
                if type(event) == "table" and event.retiredThirdParty ~= true
                    and event.environmental ~= true
                    and (event.category == "DAMAGE" or event.category == "HEAL")
                    and (tonumber(event.amount) or 0) > 0 then
                    local rawSource = ResolveHistoricalEndpoint(event, "source")
                    local source = ResolveEffectiveSource(rawSource)
                    local target = ResolveHistoricalEndpoint(event, "target")
                    ApplyConfiguredNameKind(rawSource)
                    ApplyConfiguredNameKind(target)
                    if job.preserveHistoricalEvidence ~= true
                        and not E:IsIgnored(source) and not E:IsIgnored(target) then
                        ApplyCombatEvidence(event, nil, source, target)
                    end
                end
                cursor = cursor + 1
                processed = processed + 1
            end
            job.evidenceCursor = cursor
            if cursor <= #(Store.sessionEvents or {}) then return false end
            if job.preserveHistoricalEvidence == true then
                job.phase = "CREATE_WORKING"
                job.workingCopyJob = U.BeginIncrementalDeepCopy(Store.baselineStats)
            else
                job.phase = "DECAY"
                E:BeginDecayScores(U.NowMs())
            end
            return false
        end

        if phase == "DECAY" then
            local decayDone, _ = E:DecayScoresStep(entityBudget)
            if not decayDone then return false end
            job.phase = "CREATE_WORKING"
            job.workingCopyJob = U.BeginIncrementalDeepCopy(Store.baselineStats)
            return false
        end

        if phase == "CREATE_WORKING" then
            local copyDone, processed, copyErr = U.StepIncrementalDeepCopy(job.workingCopyJob, 3000)
            D.Diagnostics.counters.baselineCopyFields =
                (tonumber(D.Diagnostics.counters.baselineCopyFields) or 0) + (tonumber(processed) or 0)
            if copyErr ~= nil then error(copyErr) end
            if not copyDone then return false end
            job.workingStats = job.workingCopyJob.result
            job.workingCopyJob = nil
            S.replayWorkingStats = job.workingStats
            -- Dormant third-party rows are represented once in the frozen
            -- baseline and once by their retained replay event. Remove the
            -- frozen copy before waking the event（分帧遍历）。
            job.phase = "WORKING_DORMANT"
            job.workingDormantCursor = 1
            return false
        end

        if phase == "WORKING_DORMANT" then
            local events = Store.sessionEvents or {}
            local processed = 0
            local cursor = job.workingDormantCursor
            while cursor <= #events and processed < eventBudget do
                local event = events[cursor]
                if type(event) == "table" and event.dormantThirdParty == true then
                    local frozenMode = event.dormantSummaryMode or event.candidateMode
                    local summary = SummaryFor(job.workingStats, frozenMode, true)
                    if summary ~= nil then AddSummaryValue(summary, event, -1) end
                end
                cursor = cursor + 1
                processed = processed + 1
            end
            job.workingDormantCursor = cursor
            if cursor <= #(Store.sessionEvents or {}) then return false end
            job.phase = "REPLAY_BATCH"
            job.replayCursor = 1
            Store.pending = {}
            Store.pendingCursor = 1
            return false
        end

        if phase == "REPLAY_BATCH" then
            local events = Store.sessionEvents or {}
            local processed = 0
            local cursor = job.replayCursor
            while cursor <= #events and processed < eventBudget do
                local event = events[cursor]
                if type(event) == "table" and event.retiredThirdParty ~= true then
                    event.applied = false
                    event.pending = false
                    event.thirdParty = false
                    event.dormantThirdParty = nil
                    event.dormantPending = nil
                    event.dormantSummaryMode = nil
                    event.repdpsSummaryTracked = nil
                    event.repdpsSummaryMode = nil
                    event.repdpsSummaryThirdParty = nil
                    event.classificationStatus = "REPLAY"
                    -- DAMAGE/HEAL 已在 REPLAY_EVIDENCE 阶段按相同事件时间完成
                    -- 端点解析，并把原始来源键/目标键写入前 32 槽。第二阶段
                    -- 直接按键取实体，避免整本日志再次执行名称绑定、同名冲突
                    -- 和类型窗口查询。键被清理或实体不存在时仍走完整回退。
                    local rawSource = nil
                    local source = nil
                    local target = nil
                    if event.category == "DAMAGE" or event.category == "HEAL" then
                        rawSource = Actors:GetEntityByKey(event.sourceResolvedKey)
                        target = Actors:GetEntityByKey(event.targetResolvedKey)
                        if rawSource ~= nil and target ~= nil then
                            source = ResolveEffectiveSource(rawSource)
                            if D.State.config.diagnosticsEnabled == true then
                                D.Diagnostics.counters.replayEndpointReuses =
                                    (tonumber(D.Diagnostics.counters.replayEndpointReuses) or 0) + 1
                            end
                        else
                            rawSource, source, target = nil, nil, nil
                        end
                    end
                    if not self:TryClassifyAndApply(event, false, nil, false, false,
                        rawSource, source, target) then
                        Store.pending[#Store.pending + 1] = event
                    end
                end
                cursor = cursor + 1
                processed = processed + 1
            end
            job.replayCursor = cursor
            D.Diagnostics.counters.replayBatchEvents =
                (tonumber(D.Diagnostics.counters.replayBatchEvents) or 0) + processed
            if cursor <= #(Store.sessionEvents or {}) then
                -- 高负载时动态降低预算（由 OnUpdate 传入），这里不强制。
                return false
            end
            job.phase = "FINALIZE"
            return false
        end

        if phase == "FINALIZE" then
            -- 这些函数通过 S:GetMode / LiveStatsRoot 落到工作副本。
            self:RecomputePendingSummaries()
            self:TrimPendingOverflow()
            S:UpdateClosure("PVP", true)
            S:UpdateClosure("PVE", true)
            job.phase = "COMMIT"
            return false
        end

        if phase == "COMMIT" then
            -- 原子替换：工作副本成为显示统计，绝无第二份。
            D.State.stats = job.workingStats

            -- rc23：完整重放会替换整棵 Stats Authority。热事件期间排行榜缓存
            -- 通过 actor 脏队列增量修补，但 replayWorkingStats 写入时这些缓存
            -- 故意不接收脏通知；若提交后只 MarkViewDirty，缓存仍持有旧统计树
            -- 的 actor 指针，表现为详情已迁移到新 Side，而排行榜仍显示旧行。
            -- 必须在 Authority 根切换的同一提交阶段失效所有结构缓存，并让
            -- breakdown 审计重新绑定新根。该操作只发生在完整重放提交，不在
            -- 战斗事件热路径执行。
            if S.MarkBreakdownsMutated ~= nil then
                -- MarkBreakdownsMutated(true) also calls MarkStatsMutated(true),
                -- so the Authority-root revision advances exactly once.
                S:MarkBreakdownsMutated(true)
            elseif S.MarkStatsMutated ~= nil then
                S:MarkStatsMutated(true)
            end

            if D.Analysis ~= nil and D.Analysis.RebuildBossFromStats ~= nil then
                D.Analysis:RebuildBossFromStats()
            end
            -- v0.2.25（重放修复）：Store.baselineStats 保持重放前的值，绝不更新为
            -- 本次重放结果。不变量：baseline 只含"基础统计"（启动加载/清空后的
            -- 空统计），不含 sessionEvents 中任何事件；重放 = baseline + 全部事件。
            -- 若把 baseline 更新为 workingStats，第二次重放会重复计算全部历史
            -- 事件（数据翻倍），且重放工作量翻倍导致长时间卡在 replaying=true、
            -- 期间新事件全部排队，表现为"数据没有任何进入"。
            S.replayWorkingStats = nil
            job.workingStats = nil
            -- 事件 key 可能在重放中变化（identity 升级），索引必须重建。
            if Store.ResetIdentityIndex ~= nil then Store:ResetIdentityIndex() end
            job.phase = "REBUILD_INDEX"
            return false
        end

        if phase == "REBUILD_INDEX" then
            if Store.EnsureIdentityIndex ~= nil then
                local indexed = Store:EnsureIdentityIndex(eventBudget, Store.identityGeneration)
                if not indexed then return false end
            end
            job.phase = "DRAIN_QUEUE"
            job.drainCursor = 1
            return false
        end

        if phase == "DRAIN_QUEUE" then
            -- 重放期间排队的新事件按原顺序补处理（不丢失、不重复）。
            -- 补处理时 HandleCombatMessage/HandleDeathNotice 会看到
            -- processingReplayQueue == true，不再重新排队。
            self.processingReplayQueue = true
            local queue = self.replayEventQueue or {}
            local processed = 0
            local cursor = job.drainCursor
            while cursor <= #queue and processed < eventBudget do
                local row = queue[cursor]
                if type(row) == "table" and row[1] == 1 then
                    self:HandleCombatMessage(
                        row[3], row[4], row[5], row[6], row[7], row[8], row[9], row[10],
                        row[11], row[12], row[13], row[14], row[15], row[16], row[2]
                    )
                elseif type(row) == "table" and row[1] == 2 then
                    self:HandleDeathNotice(row[3], row[4], row[5], row[6], row[2])
                elseif type(row) == "table" and row.kind == "combat" then
                    self:HandleCombatMessage(
                        row.unitId, row.eventType, row.sourceName, row.targetName,
                        row.abilityId, row.abilityName, row.damageType, row.effectType,
                        row.isActive, row.more, row.more2, row.more3, row.more4, row.more5,
                        row.receivedAt
                    )
                elseif type(row) == "table" and row.kind == "death" then
                    self:HandleDeathNotice(row.info1, row.info2, row.info3, row.info4, row.receivedAt)
                end
                cursor = cursor + 1
                processed = processed + 1
            end
            job.drainCursor = cursor
            if cursor <= #queue then
                self.processingReplayQueue = false
                return false
            end
            self.processingReplayQueue = false
            self.replayEventQueue = {}
            job.phase = "DONE"
            return false
        end

        -- DONE
        return true
    end

    local ok, err = xpcall(protectedStep, Boot.SafeTraceback)
    if not ok then
        -- 失败：回滚并保留 dirty 标记，下次空闲重试。
        self:RollbackReplaySessionStats(job)
        S.replayWorkingStats = nil
        self.replayJob = nil
        self.replaying = false
        D.State.runtime.replaying = false
        self:RecoverReplayQueueAfterRollback(job)
        self:ResetDormantEvidenceIndex(false)
        D.Diagnostics.counters.replayCancels =
            (tonumber(D.Diagnostics.counters.replayCancels) or 0) + 1
        D.Diagnostics:AddError("replay", "分帧重放失败，已回滚旧统计：" .. tostring(err))
        return true
    end

    if job.phase == "DONE" then
        -- DRAIN_QUEUE 运行时 replaying 仍为 true，实时队列中的 Boss 伤害会
        -- 正确进入最终统计，但 TrackBossDamage 为防重放翻倍会跳过增量投影。
        -- 队列全部补处理后再从最终统计重建一次，保证重放期间新事件不丢失。
        if D.Analysis ~= nil and D.Analysis.RebuildBossFromStats ~= nil then
            D.Analysis:RebuildBossFromStats()
        end
        local committedReason = self.reclassifyReason or "FULL_REPLAY"
        local followupFull = self.reclassifyAfterReplay == true
        local followupPending = self.pendingEvidenceAfterReplay == true
        local followupReason = self.reclassifyAfterReplayReason
        local followupActor = self.reclassifyAfterReplayActor
        self.reclassifyAfterReplay = nil
        self.reclassifyAfterReplayReason = nil
        self.reclassifyAfterReplayActor = nil
        self.pendingEvidenceAfterReplay = nil

        self.fullReclassifyRequested = false
        self.pendingEvidenceChanged = false
        self.pendingEvidenceRequestedAt = nil
        D.State.dirty.statsSave = true
        D.MarkViewDirty()
        self.replayJob = nil
        self.replaying = false
        D.State.runtime.replaying = false
        self.reclassifyRequestedAt = nil
        self.lastPendingReclassifyAt = nil
        EventClassifications:CommitTransaction()
        CallEventShadow("CommitClassificationTransaction")
        CallLocalReplay("OnFullReplayCommitted", committedReason)
        self.reclassifyReason = nil

        if followupFull then
            D.State.dirty.reclassify = true
            self.fullReclassifyRequested = true
            self.reclassifyUrgent = true
            self.reclassifyReason = followupReason or "EVIDENCE_DURING_REPLAY"
            self.reclassifyRequestedAt = U.NowMs()
            CallLocalReplay("BeginPlan", followupActor,
                self.reclassifyReason or "EVIDENCE_DURING_REPLAY")
            D.Diagnostics.counters.replaysQueuedAfterReplay =
                (tonumber(D.Diagnostics.counters.replaysQueuedAfterReplay) or 0) + 1
        elseif followupPending then
            D.State.dirty.reclassify = true
            self.pendingEvidenceChanged = true
            self.pendingEvidenceRequestedAt = U.NowMs()
            D.Diagnostics.counters.pendingPassesQueuedAfterReplay =
                (tonumber(D.Diagnostics.counters.pendingPassesQueuedAfterReplay) or 0) + 1
        else
            D.State.dirty.reclassify = false
        end

        -- FINALIZE/队列补处理仍可能产生新的休眠行（尤其超过 pending 上限
        -- 时）。不能把空索引直接标记 complete，否则这些行以后取得官方
        -- 类型证据也无法唤醒；从新日志状态分帧重建派生索引。
        self:ResetDormantEvidenceIndex(false)
        D.Diagnostics.counters.replayBatches =
            (tonumber(D.Diagnostics.counters.replayBatches) or 0) + 1
        D.Diagnostics.counters.replayCommits =
            (tonumber(D.Diagnostics.counters.replayCommits) or 0) + 1
        return true
    end
    return false
end

-- 兼容入口：启动分帧重放。调用方不应假定同步完成；OnUpdate 驱动推进。
function R:RebuildSessionStats()
    if self.replayJob ~= nil then return false end
    return self:BeginReplaySessionStats()
end


function R:ReprocessPending(force, batchLimitOverride)
    Store.pending = Store.pending or {}
    local pending = Store.pending
    local count = #pending
    if count == 0 then
        Store.pendingCursor = 1
        D.Diagnostics.counters.pendingEvents = 0
        D.Diagnostics.counters.thirdPartyEvents = 0
        return
    end

    local now = U.NowMs()
    local requestedLimit = tonumber(batchLimitOverride)
    local defaultLimit = force == true and C.RECLASSIFY_PENDING_BATCH or C.PENDING_RETRY_BATCH
    local batchLimit = requestedLimit ~= nil and math.max(1, math.floor(requestedLimit))
        or math.max(1, math.floor(tonumber(defaultLimit) or 400))
    batchLimit = math.min(batchLimit, math.max(1, tonumber(C.MAX_PENDING_EVENTS) or 3000))

    -- Old code rebuilt two new arrays after scanning all 3000 rows every retry.
    -- In sustained raid traffic that created a permanent GC load even when only
    -- a few rows were due. A rotating cursor plus swap-removal gives O(1)
    -- deletion and bounds both inspected and classified rows per update.
    local scanBudget
    if force == true then
        scanBudget = math.min(count, math.max(batchLimit, math.floor(batchLimit * 1.5)))
    else
        scanBudget = math.min(count, math.max(batchLimit,
            batchLimit * math.max(1, math.floor(tonumber(C.PENDING_RETRY_SCAN_MULTIPLIER) or 4))))
    end

    local cursor = math.max(1, math.floor(tonumber(Store.pendingCursor) or 1))
    if cursor > count then cursor = 1 end
    local processed = 0
    local inspected = 0
    local changed = false
    local thirdPartyCount = math.max(0, math.floor(
        tonumber(D.Diagnostics.counters.thirdPartyEvents) or 0))
    if thirdPartyCount > count then
        thirdPartyCount = 0
        for index = 1, count do
            if type(pending[index]) == "table" and pending[index].thirdParty == true then
                thirdPartyCount = thirdPartyCount + 1
            end
        end
    end

    local function AdvanceCursor()
        if count <= 0 then cursor = 1
        else
            cursor = cursor + 1
            if cursor > count then cursor = 1 end
        end
    end

    local function RemoveCurrent(wasThirdParty)
        local last = pending[count]
        pending[count] = nil
        count = count - 1
        if cursor <= count then pending[cursor] = last end
        if wasThirdParty == true then thirdPartyCount = math.max(0, thirdPartyCount - 1) end
        if count <= 0 then cursor = 1
        elseif cursor > count then cursor = 1 end
    end

    while count > 0 and inspected < scanBudget and processed < batchLimit do
        local event = pending[cursor]
        inspected = inspected + 1
        if type(event) ~= "table" or event.applied == true or event.retiredThirdParty == true
            or event.dormantThirdParty == true or event.dormantPending == true then
            if type(event) == "table" then UntrackPendingSummary(event) end
            RemoveCurrent(type(event) == "table" and event.thirdParty == true)
            changed = true
        else
            local age = now - (U.FiniteNumber(event.timestamp, now) or now)
            if event.thirdParty == true and age >= C.THIRD_PARTY_RETENTION_MS then
                if event.repdpsSummaryTracked ~= true then TrackPendingSummary(event) end
                if event.repdpsSummaryTracked == true then FreezeTrackedSummary(event) end
                event.dormantThirdParty = true
                event.dormantSummaryMode = event.candidateMode
                event.retiredThirdParty = false
                event.applied = false
                event.pending = false
                event.classificationStatus = "THIRD_PARTY_DORMANT"
                RegisterDormantEvidenceEvent(self, event)
                self.retiredThirdPartySinceCompact =
                    (tonumber(self.retiredThirdPartySinceCompact) or 0) + 1
                ReplaceSessionEvent(event, false)
                RemoveCurrent(true)
                changed = true
            elseif event.thirdParty == true and force ~= true then
                AdvanceCursor()
            elseif force ~= true and now < (tonumber(event.repdpsNextRetryAt) or 0) then
                AdvanceCursor()
            else
                processed = processed + 1
                local wasThirdParty = event.thirdParty == true
                UntrackPendingSummary(event)
                if self:TryClassifyAndApply(event, true) then
                    event.repdpsRetryCount = nil
                    event.repdpsNextRetryAt = nil
                    ReplaceSessionEvent(event, false)
                    RemoveCurrent(wasThirdParty)
                    changed = true
                else
                    TrackPendingSummary(event)
                    local isThirdParty = event.thirdParty == true
                    if wasThirdParty ~= isThirdParty then
                        thirdPartyCount = math.max(0, thirdPartyCount + (isThirdParty and 1 or -1))
                    end
                    local retryCount = math.min(8,
                        math.max(0, math.floor(tonumber(event.repdpsRetryCount) or 0)) + 1)
                    event.repdpsRetryCount = retryCount
                    local delay = math.min(tonumber(C.PENDING_RETRY_MAX_MS) or 30000,
                        500 * (2 ^ retryCount))
                    event.repdpsNextRetryAt = now + delay
                    AdvanceCursor()
                end
            end
        end
    end

    Store.pendingCursor = cursor
    D.Diagnostics.counters.pendingEvents = count
    D.Diagnostics.counters.thirdPartyEvents = math.min(count, thirdPartyCount)
    D.Diagnostics.counters.pendingRowsInspected =
        (tonumber(D.Diagnostics.counters.pendingRowsInspected) or 0) + inspected
    D.Diagnostics.counters.pendingRowsProcessed =
        (tonumber(D.Diagnostics.counters.pendingRowsProcessed) or 0) + processed
    if changed or force then D.MarkViewDirty() end
end

local teamSchemes = {
    {
        name = "team_plain",
        build = function()
            local result = {}
            for i = 1, 50 do result[#result + 1] = "team" .. tostring(i) end
            return result
        end,
    },
    {
        name = "team_padded",
        build = function()
            local result = {}
            for i = 1, 50 do result[#result + 1] = string.format("team%02d", i) end
            return result
        end,
    },
    {
        name = "coraid_plain",
        build = function()
            local result = {}
            -- Interleave raid 1/2 by slot. The old raid-major order did not
            -- reach team_2_1 until after fifty empty team_1_* probes, so members
            -- in the second joint raid could deal an entire short boss pull
            -- before the addon ever established TEAM Authority for them.
            for i = 1, 50 do
                for raid = 1, 2 do
                    result[#result + 1] = "team_" .. tostring(raid) .. "_" .. tostring(i)
                end
            end
            return result
        end,
    },
    {
        name = "coraid_padded",
        build = function()
            local result = {}
            for i = 1, 50 do
                for raid = 1, 2 do
                    -- Native padded joint-raid tokens pad both indices. The old
                    -- `team_1_01` spelling does not match the proven
                    -- `team_01_01` contract used by Healer and reference addons.
                    result[#result + 1] = string.format("team_%02d_%02d", raid, i)
                end
            end
            return result
        end,
    },
}
for _, scheme in ipairs(teamSchemes) do scheme.tokens = scheme.build() end

local function AddRosterAliasName(result, seen, value)
    local text = U.Trim(value)
    if not IsNamePresent(text) then return end
    local normalized = U.NormalizeName(text)
    if normalized ~= "" and seen[normalized] ~= true then
        seen[normalized] = true
        result[#result + 1] = text
    end
    -- UnitNameWithWorld commonly returns Name@World while COMBAT_MSG reports
    -- only Name. Derive the short spelling from the official world-qualified
    -- value, but keep it only as a collision-checked current-roster alias.
    local short = string.match(text, "^([^@]+)@.+$")
    if short ~= nil then
        short = U.Trim(short)
        local shortNormalized = U.NormalizeName(short)
        if shortNormalized ~= "" and seen[shortNormalized] ~= true then
            seen[shortNormalized] = true
            result[#result + 1] = short
        end
    end
end

local function CollectRosterNames(token)
    local names, seen = {}, {}
    AddRosterAliasName(names, seen, Api:GetUnitName(token))
    if Api:Has("unit.unit_name_with_world") then
        AddRosterAliasName(names, seen, Api:GetUnitNameWithWorld(token))
    end
    return names
end

local function ChooseRosterDisplayName(names)
    -- Prefer the shortest official spelling for compact rankings. World-qualified
    -- aliases remain attached to the same current roster entity.
    local best = nil
    for _, name in ipairs(type(names) == "table" and names or {}) do
        if best == nil or #tostring(name) < #tostring(best) then best = name end
    end
    return best
end

-- `teamN` is not an independent roster layout while a joint raid is active: it
-- aliases whichever raid page the native UI currently exposes. Mixing that alias
-- with stable `team_<raid>_<slot>` tokens can bind one slot to different people
-- after a page switch and later expire valid TEAM relations. Detect the joint
-- family first and keep it mutually exclusive from the normal family. A full
-- discovery pass may test padded/plain spellings inside that one family; member
-- deduplication makes aliases converge and later passes retain only spellings
-- that actually produced unique roster rows.
local function ProbeRosterSchemeAnchors(schemeIndex)
    local scheme = teamSchemes[schemeIndex]
    local tokens = scheme and scheme.tokens or {}
    -- Joint-raid tokens are interleaved, so indexes 1/2 cover raid 1/2 slot 1.
    -- Indexes 3/4 cover both slot-2 fallbacks. Normal layouts probe their first
    -- four packed slots. This avoids treating one unavailable anchor as proof
    -- that the whole native layout is absent without spraying fifty errors for
    -- an unsupported family.
    local calls, failures = 0, 0
    local viable = false
    local detected = false
    local jointRaidPages = {}
    local maximumAnchors = math.min(4, #tokens)
    for tokenIndex = 1, maximumAnchors do
        local token = tokens[tokenIndex]
        local ok, name
        if type(Api.TryGetUnitName) == "function" then
            ok, name = Api:TryGetUnitName(token)
        else
            ok, name = true, Api:GetUnitName(token)
        end
        calls = calls + 1
        if ok ~= true then
            failures = failures + 1
            -- A failed normal token proves that spelling is unsupported. Joint
            -- tokens are paired by raid page, so inspect both sides of slot 1
            -- before deciding whether the whole spelling is unavailable.
            if schemeIndex < 3 then
                return false, calls, failures, viable
            end
        else
            viable = true
            if schemeIndex >= 3 then
                jointRaidPages[((tokenIndex - 1) % 2) + 1] = true
            end
        end
        if ok == true and IsNamePresent(name) then detected = true end
        if schemeIndex >= 3 and tokenIndex % 2 == 0 then
            -- Once slot 1 found a member, both raid-page capabilities are now
            -- known. If neither page even accepted slot 1, later packed slots
            -- cannot establish this spelling and would only repeat errors.
            if detected then break end
            if tokenIndex == 2 and not jointRaidPages[1] and not jointRaidPages[2] then break end
        elseif schemeIndex < 3 and detected then
            break
        end
    end
    return detected, calls, failures, viable, jointRaidPages
end

local function DetectRosterSchemeIndexes()
    -- Plain and padded spellings within the same family are safe aliases and
    -- are scanned together. What must remain mutually exclusive is joint
    -- `team_<raid>_<slot>` versus normal/current-page `teamN`; mixing those two
    -- families can rebind a slot when the visible joint-raid page changes.
    local layoutOrder = {
        { indexes = { 4, 3 }, name = "coraid" }, -- proven padded spelling first
        { indexes = { 2, 1 }, name = "team" },   -- proven padded spelling first
    }
    local diagnostics = { calls = 0, failures = 0, jointPagesByScheme = {} }
    for _, layout in ipairs(layoutOrder) do
        local viableIndexes = {}
        for _, schemeIndex in ipairs(layout.indexes) do
            local detected, calls, failures, viable, jointRaidPages =
                ProbeRosterSchemeAnchors(schemeIndex)
            diagnostics.calls = diagnostics.calls + calls
            diagnostics.failures = diagnostics.failures + failures
            if viable then
                viableIndexes[#viableIndexes + 1] = schemeIndex
                if schemeIndex >= 3 then
                    diagnostics.jointPagesByScheme[schemeIndex] = jointRaidPages
                end
            end
            if detected then
                -- Include earlier same-family spellings only when their native
                -- calls succeeded but anchors were empty. Explicitly failing
                -- spellings are excluded so the full pass cannot emit one
                -- engine warning for every absent member slot.
                return viableIndexes, layout.name, diagnostics
            end
        end
    end
    return {}, "none", diagnostics
end

local function IsRosterPlanTokenAllowed(schemeIndex, tokenIndex, jointPagesByScheme)
    if schemeIndex < 3 then return true end
    local pages = type(jointPagesByScheme) == "table" and jointPagesByScheme[schemeIndex] or nil
    if type(pages) ~= "table" then return true end
    local raidPage = ((tokenIndex - 1) % 2) + 1
    return pages[raidPage] == true
end

local function ValidateRosterNameId(names, rawId, token)
    local fallback = ChooseRosterDisplayName(names)
    if rawId == nil then return fallback, nil, "NO_ID" end
    local bestName, bestId, bestQuality = fallback, nil, "NO_VERIFIED_ALIAS"
    for _, name in ipairs(type(names) == "table" and names or {}) do
        local visibleName, stableId, quality = ValidateObservedNameId(
            name, rawId, "team_slot:" .. tostring(token))
        if visibleName ~= nil and bestName == nil then bestName = visibleName end
        if stableId ~= nil then
            return fallback or visibleName, stableId, quality
        end
        bestQuality = quality or bestQuality
    end
    return bestName, bestId, bestQuality
end

local function NormalizedRosterAliases(names)
    local result, seen = {}, {}
    for _, name in ipairs(type(names) == "table" and names or {}) do
        local normalized = U.NormalizeName(name)
        if normalized ~= "" and seen[normalized] ~= true then
            seen[normalized] = true
            result[#result + 1] = normalized
        end
    end
    return result
end

local function ProcessRosterToken(token, now, seen)
    local rosterNames = CollectRosterNames(token)
    local displayName = ChooseRosterDisplayName(rosterNames)
    if not IsNamePresent(displayName) then return 0, false end

    local rawId = Api:GetUnitId(token)
    local name, id = ValidateRosterNameId(rosterNames, rawId, token)
    name = IsNamePresent(name) and name or displayName
    local normalized = U.NormalizeName(name)
    local candidateKey = id ~= nil and ("id:" .. tostring(id)) or ("teamname:" .. normalized)
    if seen[candidateKey] ~= nil then return 0, false end

    local changed = false
    local entity = id ~= nil and E:GetOrCreate(name, id, now) or E:GetTeamNameEntity(name, now)
    if id ~= nil then
        local bindingKind, bindingKindSource = "PLAYER", "team_slot"
        -- Register every official spelling against the same verified ID. This
        -- makes a short COMBAT_MSG source and Name@World roster row converge
        -- without a permanent broad name merge.
        for _, aliasName in ipairs(rosterNames) do
            local _, bindingChanged = E:RecordNameBinding(aliasName, id,
                bindingKind, "team_slot", now, true, bindingKindSource)
            changed = bindingChanged == true or changed
        end
        if E.PromoteTeamNameToStableId ~= nil then
            local promotedEntity, promoted = E:PromoteTeamNameToStableId(name, id, token, now)
            if promotedEntity ~= nil then entity = promotedEntity end
            changed = promoted == true or changed
        end
    end
    seen[candidateKey] = true
    seen[entity.key] = true
    changed = E:SetHardKind(entity, "PLAYER", "team_slot") or changed
    if E:GetRelationAt(entity, now) ~= "SELF" then
        changed = E:SetHardRelation(entity, "TEAM", "team_slot", now) or changed
    end

    local rosterRecord = E.roster[entity.key]
    if type(rosterRecord) ~= "table" then
        rosterRecord = {}
        E.roster[entity.key] = rosterRecord
    end
    rosterRecord.token = token
    rosterRecord.name = name
    rosterRecord.id = id
    rosterRecord.seenAt = now
    rosterRecord.firstSeenAt = math.min(
        U.FiniteNumber(rosterRecord.firstSeenAt, now) or now,
        now
    )
    rosterRecord.aliases = NormalizedRosterAliases(rosterNames)
    E.teamMissingSince[entity.key] = nil
    return 1, changed
end

local function TeamAliasMapsEqual(left, right)
    left = type(left) == "table" and left or {}
    right = type(right) == "table" and right or {}
    for key, value in pairs(left) do if right[key] ~= value then return false end end
    for key, value in pairs(right) do if left[key] ~= value then return false end end
    return true
end

local function RebuildCurrentTeamAliases()
    local owners, conflicts = {}, {}
    for rosterKey, record in pairs(E.roster or {}) do
        local resolvedKey = E.aliases[rosterKey] or rosterKey
        local entity = E:GetByKey(resolvedKey) or E.byKey[resolvedKey]
        if type(entity) == "table" then
            for _, normalized in ipairs(type(record) == "table" and record.aliases or {}) do
                if normalized ~= "" then
                    local existing = owners[normalized]
                    if existing == nil then
                        owners[normalized] = entity.key
                    elseif existing ~= entity.key then
                        owners[normalized] = nil
                        conflicts[normalized] = true
                    end
                end
            end
        end
    end
    for normalized in pairs(conflicts) do owners[normalized] = nil end
    local changed = not TeamAliasMapsEqual(E.teamNameAliases, owners)
    E.teamNameAliases = owners
    D.Diagnostics.counters.rosterAliasCount = U.TableCount(owners)
    D.Diagnostics.counters.rosterAliasConflicts = U.TableCount(conflicts)
    return changed
end

function R:BeginRosterScan(forceFull, options)
    if not Api:Has("unit.unit_name") then return false, "UNIT_NAME_UNAVAILABLE" end
    if self.rosterScanJob ~= nil and forceFull ~= true then return false, "SCAN_IN_PROGRESS" end
    options = type(options) == "table" and options or {}

    local now = U.NowMs()
    local activeIndexes = self.teamSchemeIndexes
    local fullProbeDue = forceFull == true or type(activeIndexes) ~= "table" or #activeIndexes == 0
        or now - (tonumber(self.lastTeamSchemeProbeAt) or 0) >= C.TEAM_SCHEME_REPROBE_MS
    local schemeIndexes = {}
    local detectedLayoutName = nil
    local detectionDiagnostics = nil
    local jointPagesByScheme
    if fullProbeDue then
        schemeIndexes, detectedLayoutName, detectionDiagnostics = DetectRosterSchemeIndexes()
        jointPagesByScheme = detectionDiagnostics and detectionDiagnostics.jointPagesByScheme or nil
    else
        jointPagesByScheme = self.teamJointRaidPagesByScheme
        for _, schemeIndex in ipairs(activeIndexes) do
            if teamSchemes[schemeIndex] ~= nil then schemeIndexes[#schemeIndexes + 1] = schemeIndex end
        end
    end

    -- Numeric probe plan, not per-token tables. Layout detection above keeps the
    -- joint and normal aliases mutually exclusive; this plan only advances the
    -- verified spelling(s) selected inside the current native roster family.
    local probePlan = {}
    if fullProbeDue then
        local maximumTokens = 0
        for _, schemeIndex in ipairs(schemeIndexes) do
            maximumTokens = math.max(maximumTokens, #(teamSchemes[schemeIndex].tokens or {}))
        end
        for tokenIndex = 1, maximumTokens do
            for _, schemeIndex in ipairs(schemeIndexes) do
                if teamSchemes[schemeIndex].tokens[tokenIndex] ~= nil
                    and IsRosterPlanTokenAllowed(schemeIndex, tokenIndex, jointPagesByScheme) then
                    probePlan[#probePlan + 1] = schemeIndex * 1000 + tokenIndex
                end
            end
        end
    else
        for _, schemeIndex in ipairs(schemeIndexes) do
            local tokens = teamSchemes[schemeIndex].tokens or {}
            local cachedLimit = tonumber(self.teamSchemeTokenLimits
                and self.teamSchemeTokenLimits[schemeIndex])
            local tokenLimit = #tokens
            if cachedLimit ~= nil and cachedLimit > 0 then
                tokenLimit = math.min(tokenLimit, math.floor(cachedLimit))
            end
            for tokenIndex = 1, tokenLimit do
                if IsRosterPlanTokenAllowed(schemeIndex, tokenIndex, jointPagesByScheme) then
                    probePlan[#probePlan + 1] = schemeIndex * 1000 + tokenIndex
                end
            end
        end
    end

    self.rosterScanJob = {
        startedAt = now,
        probePlan = probePlan,
        probeCursor = 1,
        seen = {},
        found = 0,
        changed = false,
        fullProbe = fullProbeDue,
        foundByScheme = {},
        lastFoundTokenByScheme = {},
        previousRosterCount = U.TableCount(E.roster),
        layoutName = detectedLayoutName,
        detectionCalls = tonumber(detectionDiagnostics and detectionDiagnostics.calls) or 0,
        detectionFailures = tonumber(detectionDiagnostics and detectionDiagnostics.failures) or 0,
        jointPagesByScheme = jointPagesByScheme,
        reportResult = options.reportResult == true,
        reprocessPending = options.reprocessPending == true,
    }
    return true, nil
end

function R:FinalizeRosterScan(job)
    if type(job) ~= "table" then return end
    local now = U.NowMs()
    local seen = job.seen or {}
    local changed = job.changed == true
    local found = tonumber(job.found) or 0

    if job.fullProbe == true then
        local detected = {}
        for index = 1, #teamSchemes do
            if (tonumber(job.foundByScheme and job.foundByScheme[index]) or 0) > 0 then
                detected[#detected + 1] = index
            end
        end
        self.teamSchemeIndexes = detected
        local retainedJointPages = {}
        local retainedTokenLimits = {}
        for _, schemeIndex in ipairs(detected) do
            if schemeIndex >= 3 and type(job.jointPagesByScheme) == "table" then
                retainedJointPages[schemeIndex] = job.jointPagesByScheme[schemeIndex]
            end
            local lastFoundToken = tonumber(job.lastFoundTokenByScheme
                and job.lastFoundTokenByScheme[schemeIndex])
            if lastFoundToken ~= nil and lastFoundToken > 0 then
                retainedTokenLimits[schemeIndex] = math.floor(lastFoundToken)
            end
        end
        self.teamJointRaidPagesByScheme = retainedJointPages
        self.teamSchemeTokenLimits = retainedTokenLimits
        self.lastTeamSchemeProbeAt = now
        self.teamLayoutName = #detected > 0 and tostring(job.layoutName or "detected") or "none"
        D.Diagnostics.counters.rosterLayoutDetections =
            (tonumber(D.Diagnostics.counters.rosterLayoutDetections) or 0) + 1
    end

    if found == 0 and U.TableCount(E.roster) > 0 then
        self.emptyRosterScans = (tonumber(self.emptyRosterScans) or 0) + 1
        if self.emptyRosterScans >= 3 then
            self.teamSchemeIndexes = nil
            self.teamJointRaidPagesByScheme = nil
            self.teamSchemeTokenLimits = nil
            self.lastTeamSchemeProbeAt = 0
            self.emptyRosterScans = 0
        end
    else
        self.emptyRosterScans = 0
    end

    if E.RepairOfficialTeamNameDuplicates ~= nil then
        changed = E:RepairOfficialTeamNameDuplicates(now) == true or changed
    end

    for key in pairs(E.roster) do
        if not seen[key] and not seen[E.aliases[key] or key] then
            if E.teamMissingSince[key] == nil then E.teamMissingSince[key] = now end
            if now - E.teamMissingSince[key] >= C.TEAM_GRACE_MS then
                local entity = E.byKey[key]
                if entity ~= nil and entity.hardRelation == "TEAM" then
                    entity.hardRelation = nil
                    entity.lastHardRelationEndedAt = now
                    changed = E:TransitionRelation(entity, "UNKNOWN", now, "team_grace_expired") or changed
                    E:Resolve(entity)
                end
                E.roster[key] = nil
                E.teamMissingSince[key] = nil
            end
        end
    end

    local aliasChanged = RebuildCurrentTeamAliases()
    changed = aliasChanged or changed

    local previousRosterCount = math.max(0, math.floor(tonumber(job.previousRosterCount) or 0))
    if job.fullProbe ~= true and found < previousRosterCount then
        -- A token scheme can change when entering an instance/joint raid without
        -- a reliable TEAM_MEMBERS_CHANGED callback. If the active scheme sees
        -- fewer members than the last authoritative roster, immediately schedule
        -- one interleaved all-scheme probe instead of waiting thirty seconds.
        self.teamSchemeIndexes = nil
        self.teamJointRaidPagesByScheme = nil
        self.teamSchemeTokenLimits = nil
        self.lastTeamSchemeProbeAt = 0
        D.State.timers.roster = D.State.config.rosterScanMs
        D.Diagnostics.counters.rosterDeficitReprobes =
            (tonumber(D.Diagnostics.counters.rosterDeficitReprobes) or 0) + 1
    end

    self.lastRosterScanCompletedAt = now
    self.rosterScanJob = nil
    self.lastRosterScanResult = {
        found = found,
        rosterCount = U.TableCount(E.roster),
        layoutName = tostring(self.teamLayoutName or job.layoutName or "none"),
        detectionCalls = math.max(0, math.floor(tonumber(job.detectionCalls) or 0)),
        detectionFailures = math.max(0, math.floor(tonumber(job.detectionFailures) or 0)),
        completedAt = now,
    }
    D.Diagnostics.counters.rosterScanPasses =
        (tonumber(D.Diagnostics.counters.rosterScanPasses) or 0) + 1
    if changed then self:RequestReclassify(false) end
    if job.reprocessPending == true and type(self.ReprocessPending) == "function" then
        self:ReprocessPending(true)
    end
    if job.reportResult == true and D.Boot ~= nil and type(D.Boot.SafeChat) == "function" then
        local result = self.lastRosterScanResult
        if found > 0 then
            D.Boot.SafeChat("DPS 团队扫描完成：本次识别 " .. tostring(result.found)
                .. " 人，当前名单 " .. tostring(result.rosterCount)
                .. " 人，布局 " .. tostring(result.layoutName)
                .. "；待确认事件已重新处理。")
        else
            D.Boot.SafeChat("DPS 团队扫描完成，但未识别到团队成员（布局 none，令牌调用 "
                .. tostring(result.detectionCalls) .. " 次、失败 "
                .. tostring(result.detectionFailures)
                .. " 次）。请保持在队伍/团队中并把这条结果反馈回来。")
        end
    end
end

function R:ProcessRosterScanStep(tokenBudget)
    local job = self.rosterScanJob
    if type(job) ~= "table" then return false end
    local budget = math.max(1, math.floor(tonumber(tokenBudget) or 24))
    local processed = 0
    local plan = job.probePlan or {}
    while processed < budget and job.probeCursor <= #plan do
        local encoded = math.floor(tonumber(plan[job.probeCursor]) or 0)
        job.probeCursor = job.probeCursor + 1
        local schemeIndex = math.floor(encoded / 1000)
        local tokenIndex = encoded - schemeIndex * 1000
        local scheme = teamSchemes[schemeIndex]
        local token = scheme and scheme.tokens and scheme.tokens[tokenIndex] or nil
        if token ~= nil then
            processed = processed + 1
            local found, changed = ProcessRosterToken(token, job.startedAt, job.seen)
            job.found = job.found + found
            job.changed = job.changed or changed
            if found > 0 then
                job.foundByScheme[schemeIndex] =
                    (tonumber(job.foundByScheme[schemeIndex]) or 0) + found
                job.lastFoundTokenByScheme[schemeIndex] = math.max(
                    tonumber(job.lastFoundTokenByScheme[schemeIndex]) or 0,
                    tokenIndex
                )
            end
        end
    end
    D.Diagnostics.counters.rosterTokensProcessed =
        (tonumber(D.Diagnostics.counters.rosterTokensProcessed) or 0) + processed
    if job.probeCursor > #plan then
        self:FinalizeRosterScan(job)
        return true
    end
    return false
end

function R:ScanRoster(forceFull, options)
    local started, reason = self:BeginRosterScan(forceFull == true, options)
    if started ~= true then return false, reason end
    local job = self.rosterScanJob
    local initialBudget = C.ROSTER_SCAN_INITIAL_BATCH or 24
    if type(options) == "table" and options.completeNow == true then
        initialBudget = math.max(initialBudget, #(job and job.probePlan or {}))
    end
    self:ProcessRosterScanStep(initialBudget)
    return true, self.lastRosterScanResult
end


-- RU 2026-08-19 disabled broad GetUnitsInSight enumeration, but the narrow
-- current-target getters remain allowed and are still required to classify the
-- NPC/Boss endpoint of another team member's COMBAT_MSG.  Keep this path
-- independent from broad sight discovery so an API cleanup cannot remove both.
function R:GetCurrentTargetSnapshot()
    if not Api:Has("unit.unit_name") then return nil, "当前环境没有单位名称 API" end
    local name, id = Api:GetCurrentTargetRawSnapshot()
    name, id = ValidateObservedNameId(name, id, "current_target")
    if not IsNamePresent(name) or id == nil then
        return nil, "当前没有可验证目标"
    end
    local entity = E:GetOrCreate(name, id)
    return { name = name, id = tostring(id), entity = entity }
end

function R:ScanCurrentTarget(deferReclassify)
    local snapshot = self:GetCurrentTargetSnapshot()
    if snapshot ~= nil then
        local name, id, entity = snapshot.name, snapshot.id, snapshot.entity
        local observedAt = U.NowMs()
        local _, kindChanged = self:ObserveOfficialUnitInfoKind(entity, id, name, observedAt, "current_target")
        local bindingKind, bindingKindSource = StableBindingKind(entity)
        local _, bindingChanged = E:RecordNameBinding(name, id, bindingKind, "current_target", observedAt, true, bindingKindSource)
        local changed = bindingChanged == true or kindChanged == true
        if changed and deferReclassify ~= true then
            if self:HasDormantEvidenceForEntity(entity, name, id) then
                self:RequestReclassify(false)
            else
                D.RequestPendingReclassify()
            end
        end
        return changed == true
    end
    return false
end



function R:HandleDeathNotice(info1, info2, info3, info4, queuedTimestamp)
    local processingNow = U.NowMs()
    local receivedAt = U.FiniteNumber(queuedTimestamp, processingNow) or processingNow
    -- v0.2.25（问题 7）：重放期间死亡通知同样排队，提交后补处理。
    if self.replaying == true and self.processingReplayQueue ~= true then
        self.replayEventQueue = self.replayEventQueue or {}
        self.replayEventQueue[#self.replayEventQueue + 1] = {
            2, receivedAt, info1, info2, info3, info4,
        }
        return
    end
    if self.baselineInitializing == true and self.processingBaselineQueue ~= true then
        self:QueueBaselineDeath(receivedAt, info1, info2, info3, info4)
        return
    end
    local observedAt = receivedAt
    D.Diagnostics.counters.deathNotices = D.Diagnostics.counters.deathNotices + 1
    local candidate, reason = FindRecentDamageForDeath(observedAt, info1, info2, info3, info4)
    if candidate == nil or candidate.event == nil then
        QueuePendingDeathNotice(observedAt, info1, info2, info3, info4)
        if D.State.config.diagnosticsEnabled then
            D.Diagnostics:AddInfo("death_deferred", table.concat({ tostring(info1), tostring(info2), tostring(info3), tostring(info4) }, " | "))
        end
        return
    end
    if reason == "AMBIGUOUS_LATEST" then
        D.Diagnostics.counters.deathAmbiguous = (tonumber(D.Diagnostics.counters.deathAmbiguous) or 0) + 1
        QueuePendingDeathNotice(observedAt, info1, info2, info3, info4)
        if D.State.config.diagnosticsEnabled then
            D.Diagnostics:AddInfo("death_ambiguous", table.concat({ tostring(info1), tostring(info2), tostring(info3), tostring(info4) }, " | "))
        end
        return
    end
    self:CreateLastHitFromDamage(candidate.event, { info1, info2, info3, info4 }, reason)
end

local function TryReleaseEventHost(host, eventConstant, handler)
    if host == nil or host.ReleaseEventHandler == nil then return false end
    local ok, result = pcall(function() return host:ReleaseEventHandler(eventConstant, handler) end)
    return ok == true and result ~= false
end

-- DPS deliberately registers the global team-combat fallback on both UI and
-- UIParent because different RU client builds deliver different slices there.
-- Cleanup must mirror that fan-out exactly; releasing UIParent alone left the
-- UI callback alive after the module was disabled.
local function ReleaseGlobalCombatHandler(runtime)
    local handler = runtime.globalCombatHandler
    local eventConstant = runtime.globalCombatEventConstant
    if handler ~= nil and eventConstant ~= nil then
        local seen = {}
        local function Release(host)
            if host == nil or seen[host] == true then return end
            seen[host] = true
            TryReleaseEventHost(host, eventConstant, handler)
        end
        for _, host in ipairs(runtime.globalCombatHostObjects or {}) do Release(host) end
        -- Compatibility with generations created before host objects were
        -- tracked: attempt both known global hosts without touching handlers
        -- belonging to any other addon.
        Release(UI)
        Release(UIParent)
    end
    runtime.globalCombatHandler = nil
    runtime.globalCombatEventConstant = nil
    runtime.globalCombatHosts = nil
    runtime.globalCombatHostObjects = nil
end

local function TryUnregisterWidgetEvent(host, eventName)
    if host == nil or type(host.UnregisterEvent) ~= "function" then return false end
    local ok, result = pcall(function() return host:UnregisterEvent(eventName) end)
    return ok == true and result ~= false
end

local function ReleaseNativeHandler(host, handlerName)
    local shared = rawget(_G, "ReplicatedSuiteShared")
    local native = shared and shared.NativeSafe or nil
    if native ~= nil and type(native.ReleaseHandler) == "function" then return native.ReleaseHandler(host, handlerName) end
    if host == nil or type(host.ReleaseHandler) ~= "function" then return false end
    if type(host.HasHandler) == "function" then
        local ok, has = pcall(host.HasHandler, host, handlerName)
        if ok and has ~= true then return true end
    end
    local ok, result = pcall(host.ReleaseHandler, host, handlerName)
    return ok == true and result ~= false
end

local function ReleaseOldEvent(eventName)
    local old = R.eventHandlers[eventName]
    if old == nil then return end
    local eventConstant = UIEVENT_TYPE ~= nil and UIEVENT_TYPE[eventName] or eventName
    local hostName = R.eventHandlerHosts and R.eventHandlerHosts[eventName] or nil
    local released = false

    if hostName == "private_widget" then
        released = TryUnregisterWidgetEvent(R.eventHost, eventName)
    elseif hostName == "UI" then
        released = TryReleaseEventHost(UI, eventConstant, old)
        if not released then released = TryReleaseEventHost(UIParent, eventConstant, old) end
    elseif hostName == "UIParent" then
        released = TryReleaseEventHost(UIParent, eventConstant, old)
        if not released then released = TryReleaseEventHost(UI, eventConstant, old) end
    else
        -- Older builds did not remember the host. Follow the official API host
        -- first, then use UIParent only as a compatibility fallback.
        released = TryReleaseEventHost(UI, eventConstant, old)
        if not released then released = TryReleaseEventHost(UIParent, eventConstant, old) end
    end

    if not released then
        D.Diagnostics:AddWarning("event", eventName .. " old handler release failed")
    end
    if R.eventHandlerHosts ~= nil then R.eventHandlerHosts[eventName] = nil end
end

local function PreparePrivateEventHost(generation)
    local host = R.eventHost
    if host == nil then
        host = CreateEmptyWindow("repdps_event_host", "UIParent")
        if host == nil then return false, "CreateEmptyWindow returned nil" end
        R.eventHost = host
    end
    if type(host.SetHandler) ~= "function" or type(host.RegisterEvent) ~= "function" then
        return false, "event widget methods unavailable"
    end
    ReleaseNativeHandler(host, "OnEvent")
    if type(host.SetExtent) == "function" then pcall(function() host:SetExtent(1, 1) end) end
    if type(host.EnablePick) == "function" then pcall(function() host:EnablePick(false, true) end) end
    if type(host.Show) == "function" then pcall(function() host:Show(false) end) end

    -- Keep the high-frequency COMBAT_MSG path allocation-free: explicit event
    -- arguments are forwarded directly, without the generic Suite bus' vararg
    -- snapshot table. A private widget cannot be overwritten by another addon
    -- calling UI/UIParent:SetEventHandler for the same global event.
    local ok, result = pcall(host.SetHandler, host, "OnEvent", function(_, eventName,
        arg1, arg2, arg3, arg4, arg5, arg6, arg7, arg8,
        arg9, arg10, arg11, arg12, arg13, arg14, arg15)
        if Boot.generation ~= generation then return end
        local label = eventName == "COMBAT_MSG" and "event:dps_combat" or "event:dps:" .. tostring(eventName)
        local token = SuitePerformance and SuitePerformance:Begin(label, "dps") or nil
        local handler = R.eventHandlers and R.eventHandlers[eventName] or nil
        if type(handler) == "function" then
            handler(arg1, arg2, arg3, arg4, arg5, arg6, arg7, arg8,
                arg9, arg10, arg11, arg12, arg13, arg14, arg15)
        end
        if SuitePerformance ~= nil then SuitePerformance:End(token) end
    end)
    if not ok then return false, tostring(result) end
    if result == false then return false, "OnEvent handler returned false" end
    return true, nil
end

local function RegisterPrivateEvent(eventName)
    local host = R.eventHost
    if host == nil or type(host.RegisterEvent) ~= "function" then return false, "host unavailable" end
    local ok, result = pcall(function() return host:RegisterEvent(eventName) end)
    if not ok then return false, tostring(result) end
    if result == false then return false, "returned false" end
    R.eventHandlerHosts[eventName] = "private_widget"
    return true, nil
end

function R:RegisterEvents(generation)
    -- Release the previous generation first. This also removes the legacy global
    -- UI:SetEventHandler callbacks installed by builds before the private host.
    for eventName in pairs(self.eventHandlers or {}) do ReleaseOldEvent(eventName) end
    self.eventHandlers = {}
    self.eventHandlerHosts = {}
    ReleaseGlobalCombatHandler(self)

    local combatHandler = function(unitId, eventType, sourceName, targetName, abilityId, abilityName, damageType, effectType, isActive, more, more2, more3, more4, more5)
        if Boot.generation ~= generation then return end
        -- Avoid allocating an argument table and closure for every combat log
        -- entry. More importantly, critical event errors are recorded but never
        -- allowed to permanently disable all later COMBAT_MSG processing.
        CriticalCall(
            "combat_event",
            R.HandleCombatMessage,
            self,
            unitId,
            eventType,
            sourceName,
            targetName,
            abilityId,
            abilityName,
            damageType,
            effectType,
            isActive,
            more,
            more2,
            more3,
            more4,
            more5
        )
    end

    local teamHandler = function()
        if Boot.generation ~= generation then return end
        Protected("team_event", function()
            self.teamSchemeIndexes = nil
            self.teamJointRaidPagesByScheme = nil
            self.teamSchemeTokenLimits = nil
            self.lastTeamSchemeProbeAt = 0
            -- Debounce: TEAM_MEMBERS_CHANGED can fire repeatedly while the
            -- native roster UI rebuilds (member OnShow/OnHide, page flips).
            -- Keep the FIRST timestamp of a burst so the one-second stability
            -- fence in OnUpdate actually opens; refreshing it every event kept
            -- teamRosterStable false forever and the automatic roster scan
            -- never ran (only the manual button worked -- live-client evidence
            -- 2026-08-24: 团队中名单=0 until a manual scan).
            local nowMs = U.NowMs()
            local lastChange = tonumber(self.lastTeamMembersChangedAt) or 0
            if nowMs - lastChange >= 1000 then self.lastTeamMembersChangedAt = nowMs end
            -- Do NOT cancel an in-flight roster scan (was: rosterScanJob = nil).
            -- ProcessRosterToken reads the CURRENT native slots and dedups via
            -- job.seen keyed by id:/teamname:, so a mid-scan roster change can
            -- only ADD a new id, never corrupt an existing one. Cancelling made
            -- a high-frequency event stream kill every job before
            -- ProcessRosterScanStep finished, so the roster never materialized
            -- and team data stayed CONTEXT_ONLY_TEAM_SCOPE.
            D.State.timers.roster = D.State.config.rosterScanMs
        end)
    end

    self.eventHandlers.COMBAT_MSG = combatHandler
    self.eventHandlers.TEAM_MEMBERS_CHANGED = teamHandler
    local hostOk, hostError = PreparePrivateEventHost(generation)
    if not hostOk then error("DPS private event host failed: " .. tostring(hostError)) end
    local combatOk, combatError = RegisterPrivateEvent("COMBAT_MSG")
    if not combatOk then
        error("COMBAT_MSG registration failed; combat totals cannot work: " .. tostring(combatError))
    end
    local teamOk, teamError = RegisterPrivateEvent("TEAM_MEMBERS_CHANGED")
    if not teamOk then
        D.Diagnostics:AddWarning("event", "TEAM_MEMBERS_CHANGED register failed: " .. tostring(teamError))
    end

    -- Live-client evidence 2026-08-24: the private widget host only receives
    -- COMBAT_MSG rows where the local player is one endpoint. Team members'
    -- damage/healing rows are delivered through the GLOBAL UIParent event
    -- handler (dpsmeter and the legacy suite both use UIParent:SetEventHandler
    -- and show team rows). Register a global COMBAT_MSG handler as the team
    -- event source; the private host keeps the SELF-related slice (defence
    -- against another addon overwriting the global handler). Dedup: the global
    -- route only forwards rows where NEITHER endpoint is the local player, so
    -- the two routes never double-count.
    local globalCombatHandler = nil
    local globalOk = false
    local globalError = nil
    local eventConstant = UIEVENT_TYPE ~= nil and UIEVENT_TYPE.COMBAT_MSG or "COMBAT_MSG"
    -- Dedup guard: the private host already delivers every row where the local
    -- player is an endpoint. The global route must forward ONLY rows where
    -- NEITHER endpoint is the local player, otherwise every SELF-related row
    -- would arrive twice and be double-counted.
    local function IsLocalPlayerName(name)
        local text = U.Trim(tostring(name or ""))
        if text == "" then return false end
        local normalized = U.NormalizeName(text)
        return normalized ~= "" and (normalized == U.NormalizeName(D.Identity.playerName)
            or normalized == U.NormalizeName(D.Identity.playerNameWithWorld))
    end
    if (UIParent ~= nil and type(UIParent.SetEventHandler) == "function")
        or (UI ~= nil and type(UI.SetEventHandler) == "function") then
        globalCombatHandler = function(unitId, eventType, sourceName, targetName, abilityId, abilityName, damageType, effectType, isActive, more, more2, more3, more4, more5)
            if Boot.generation ~= generation then return end
            if IsLocalPlayerName(sourceName) or IsLocalPlayerName(targetName) then return end
            local token = SuitePerformance and SuitePerformance:Begin("event:dps_global_combat", "dps") or nil
            -- Both global hosts (UI + UIParent) may deliver the SAME row when
            -- both registrations succeed. Dedupe with a short-window signature:
            -- identical (eventType, source, target, abilityId, effectType)
            -- within 300ms is the same client row forwarded twice.
            local nowMs = U.NowMs()
            local signature = tostring(eventType or "") .. "|" .. tostring(sourceName or "")
                .. "|" .. tostring(targetName or "") .. "|" .. tostring(abilityId or "")
                .. "|" .. tostring(effectType or "")
            local dedup = self.globalCombatDedup
            if type(dedup) ~= "table" then dedup = {}; self.globalCombatDedup = dedup end
            local prior = dedup[signature]
            if prior ~= nil and nowMs - prior < 300 then return end
            dedup[signature] = nowMs
            -- Bound the dedup table: drop stale signatures lazily.
            local dedupCount = 0
            for key, at in pairs(dedup) do
                dedupCount = dedupCount + 1
                if nowMs - at >= 1000 then dedup[key] = nil end
            end
            if dedupCount > 512 then dedup = {}; self.globalCombatDedup = dedup end
            -- Count every team/opponent row that actually arrived on the global
            -- route, so the diagnostics line can prove the route is live.
            D.Diagnostics.counters.globalCombatRows =
                (tonumber(D.Diagnostics.counters.globalCombatRows) or 0) + 1
            -- Ring buffer of the most recent global-route rows so the chat
            -- diagnostics can show exactly WHAT arrived (team damage? team taken?
            -- casts?), pinpointing whether team damage rows are missing entirely.
            local sample = self.globalCombatSample
            if type(sample) ~= "table" then
                sample = {}
                self.globalCombatSample = sample
            end
            sample[#sample + 1] = {
                eventType = tostring(eventType or "?"),
                source = tostring(sourceName or "?"),
                target = tostring(targetName or "?"),
                ability = tostring(abilityName or "?"),
                amount = tonumber(effectType) or 0,
            }
            if #sample > 12 then
                local kept = {}
                for i = #sample - 11, #sample do kept[#kept + 1] = sample[i] end
                self.globalCombatSample = kept
            end
            -- Team/opponent-only row: forward into the same pipeline.
            CriticalCall(
                "combat_event_global",
                R.HandleCombatMessage,
                self,
                unitId,
                eventType,
                sourceName,
                targetName,
                abilityId,
                abilityName,
                damageType,
                effectType,
                isActive,
                more,
                more2,
                more3,
                more4,
                more5
            )
            if SuitePerformance ~= nil then SuitePerformance:End(token) end
        end
        -- Register on BOTH global hosts when available. The legacy suite and
        -- dpsmeter register COMBAT_MSG through UI (the legacy suite tries UI
        -- first, UIParent as fallback); some client builds deliver the full
        -- stream (including TEAM->NPC damage rows) on one host but only a
        -- subset on the other. Registering both maximises coverage; the shared
        -- SELF-filter keeps the private host and both global routes disjoint
        -- (SELF rows only on private, non-SELF rows forwarded once per host --
        -- a row delivered by both global hosts would double-count, so each
        -- host keeps its own handler and we accept the small duplicate risk in
        -- exchange for guaranteed delivery, matching dpsmeter's behaviour).
        local hosts = {}
        if UI ~= nil and type(UI.SetEventHandler) == "function" then hosts[#hosts + 1] = { host = UI, label = "UI" } end
        if UIParent ~= nil and type(UIParent.SetEventHandler) == "function" then hosts[#hosts + 1] = { host = UIParent, label = "UIParent" } end
        local registeredHosts, registeredHostObjects = {}, {}
        for _, entry in ipairs(hosts) do
            local ok2, result2 = pcall(function()
                return entry.host:SetEventHandler(eventConstant, globalCombatHandler)
            end)
            if ok2 == true and result2 ~= false then
                registeredHosts[#registeredHosts + 1] = entry.label
                registeredHostObjects[#registeredHostObjects + 1] = entry.host
            else
                D.Diagnostics:AddWarning("event", "COMBAT_MSG global " .. tostring(entry.label)
                    .. " handler failed: " .. tostring(ok2 and (result2 == false and "returned false" or nil) or tostring(result2)))
            end
        end
        globalOk = #registeredHosts > 0
        if globalOk then
            self.globalCombatHandler = globalCombatHandler
            self.globalCombatEventConstant = eventConstant
            self.globalCombatHosts = registeredHosts
            self.globalCombatHostObjects = registeredHostObjects
            D.Diagnostics:AddInfo("event", "COMBAT_MSG global handler registered on: " .. table.concat(registeredHosts, "+"))
        else
            D.Diagnostics:AddWarning("event", "COMBAT_MSG global handler failed on all hosts")
        end
    else
        D.Diagnostics:AddWarning("event", "COMBAT_MSG global handler unavailable (SetEventHandler missing)")
    end
    self.eventTransport = "private_widget+global"
end

function R:AbortStart()
    for eventName in pairs(self.eventHandlers or {}) do
        ReleaseOldEvent(eventName)
    end
    self.eventHandlers = {}
    ReleaseGlobalCombatHandler(self)
    local eventHost = self.eventHost
    if eventHost ~= nil then
        ReleaseNativeHandler(eventHost, "OnEvent")
        if type(eventHost.Show) == "function" then pcall(function() eventHost:Show(false) end) end
    end
    self.eventTransport = "stopped"
    self.baselineInitializing = false
    self.baselineCopyJob = nil
    self.baselineEventQueue = {}
    self.baselineQueueCursor = 1
    self.eventHandlerHosts = {}
    self.rosterScanJob = nil
    ReleaseNativeHandler(self.updateHost, "OnUpdate")
    self.started = false
end

function R:RegisterEscMenu()
    if ReplicatedSuiteEmbedded == true then return true end
    if self.escRegistered == true then return end

    -- Register the actual config window as native content. RegisterContentTriggerFunc
    -- alone does not make ADDON:GetContent(contentId) return a widget, which made
    -- Replicated Suite incorrectly report "waiting for entry registration".
    local widgetCallOk, widgetResult = Api:RegisterContentWidget(C.CONTENT_ID, D.UI.windows.config)
    local widgetOk = widgetCallOk and widgetResult ~= false
    if not widgetOk then
        local widgetError = widgetCallOk and "returned false" or tostring(widgetResult)
        D.Diagnostics:AddWarning("esc_menu", "content widget registration failed: " .. widgetError)
    end

    local triggerCallOk, triggerResult = Api:RegisterContentTrigger(C.CONTENT_ID, function(show)
        if Boot.generation ~= D.State.runtime.generation then return end
        local currentVisible = D.UI.windows.config:IsVisible() == true
        local desiredVisible = ReplicatedEscMenuPolicy ~= nil
            and ReplicatedEscMenuPolicy:ResolveVisibility(show, currentVisible)
            or (show == true or (type(show) == "number" and show ~= 0))
        D.UI.windows.config:Show(desiredVisible)
        if desiredVisible then
            if D.UI.windows.config.Raise ~= nil then D.UI.windows.config:Raise() end
            D.UI:RefreshConfig()
        end
    end)
    local triggerOk = triggerCallOk and triggerResult ~= false
    if not triggerOk then
        local triggerError = triggerCallOk and "returned false" or tostring(triggerResult)
        D.Diagnostics:AddWarning("esc_menu", "content trigger failed: " .. triggerError)
        return
    end

    local buttonOk, buttonError
    if ReplicatedEscMenuPolicy ~= nil and type(ReplicatedEscMenuPolicy.RegisterButton) == "function" then
        buttonOk, buttonError = ReplicatedEscMenuPolicy:RegisterButton(3, C.CONTENT_ID, "info", "伤害统计 · Replicated")
    else
        local buttonCallOk, buttonResult = Api:AddEscMenuButton(3, C.CONTENT_ID, "info", "伤害统计 · Replicated")
        buttonOk = buttonCallOk and buttonResult ~= false
        buttonError = buttonCallOk and "returned false" or tostring(buttonResult)
    end
    if buttonOk then
        self.escRegistered = true
    else
        D.Diagnostics:AddWarning("esc_menu", "button registration failed: " .. tostring(buttonError or "unknown"))
    end
end

function R:CreateUpdateHost(generation)
    local host = self.updateHost
    if host == nil then
        host = CreateEmptyWindow("repdps_update_host", "UIParent")
        host:SetExtent(1, 1)
        host:Show(true)
        if host.EnablePick ~= nil then host:EnablePick(false, true) end
        if host.Clickable ~= nil then host:Clickable(false, true) end
        self.updateHost = host
    end
    ReleaseNativeHandler(host, "OnUpdate")
    local bindOk, bindResult = pcall(host.SetHandler, host, "OnUpdate", function(_, dt)
        if Boot.generation ~= generation then return end
        -- 全局调度器自身不能进入 30 秒熔断。否则一次 UI 边界异常会让
        -- 分帧任务与自动刷新全部停止，只剩人工按钮能直接刷新一次。
        local token = SuitePerformance and SuitePerformance:Begin("onupdate:dps_runtime", "dps") or nil
        CriticalCall("update_host", R.OnUpdate, self, tonumber(dt) or 0)
        if SuitePerformance ~= nil then SuitePerformance:End(token) end
    end)
    if not bindOk then error("DPS OnUpdate handler registration failed: " .. tostring(bindResult)) end
    if bindResult == false then error("DPS OnUpdate handler registration returned false") end
    return true
end

function R:BeginTransientCleanup()
    if type(self.transientCleanupJob) == "table" then return self.transientCleanupJob end
    self.transientCleanupJob = {
        now = U.NowMs(),
        phase = 1,
        lastKey = nil,
        verifiedRetained = 0,
        socialRetained = 0,
        -- 四个来源引用只在任务创建时保存一次。旧实现每个分帧步骤都新建
        -- 四个描述表，清理持续数十帧时会产生不必要的短命垃圾。
        sources = {
            self.verifiedUnitNameCache or {},
            self.officialUnitKindCache or {},
            self.socialRelationCache or {},
        },
        kinds = { "verified", "official_kind", "social" },
    }
    return self.transientCleanupJob
end

function R:StepTransientCleanup(entryBudget)
    local job = self.transientCleanupJob
    if type(job) ~= "table" then return true end
    local budget = math.max(1, math.floor(tonumber(entryBudget)
        or tonumber(C.TRANSIENT_CLEANUP_BATCH) or 96))
    local sources = job.sources or {}
    local kinds = job.kinds or {}
    local processed = 0
    while processed < budget and job.phase <= #sources do
        local source = sources[job.phase] or {}
        local kind = kinds[job.phase]
        local ok, key, value = pcall(next, source, job.lastKey)
        if not ok then key = nil end
        if key == nil then
            -- Combat callbacks can add or refresh cache entries between cleanup
            -- frames. Recount the final live table instead of trusting only the
            -- rows visited by this job, then collapse stale queue records.
            if kind == "verified" then
                self.verifiedUnitNameCacheQueue, self.verifiedUnitNameCacheCount =
                    RebuildTimedCacheQueue(source, self.verifiedUnitNameCacheQueue)
            elseif kind == "official_kind" then
                self.officialUnitKindCacheQueue, self.officialUnitKindCacheCount =
                    RebuildTimedCacheQueue(source, self.officialUnitKindCacheQueue)
            elseif kind == "social" then
                self.socialRelationCacheQueue, self.socialRelationCacheCount =
                    RebuildTimedCacheQueue(source, self.socialRelationCacheQueue)
            end
            job.phase = job.phase + 1
            job.lastKey = nil
        else
            job.lastKey = key
            local keep = true
            if kind == "verified" or kind == "official_kind" or kind == "social" then
                keep = type(value) == "table" and job.now <= (tonumber(value.expiresAt) or 0)
                if keep and kind == "verified" then
                    job.verifiedRetained = job.verifiedRetained + 1
                elseif keep and kind == "social" then
                    job.socialRetained = job.socialRetained + 1
                end
            elseif kind == "death" then
                keep = job.now - (tonumber(value) or 0) <= LAST_HIT_DEDUP_MS + 5000
            end
            if not keep then source[key] = nil end
            processed = processed + 1
        end
    end
    if job.phase > #sources then
        self.transientCleanupJob = nil
        -- 最后一击正式链路已停用，不再在周期清理中扫描死亡通知或伤害候选。
        D.Diagnostics.counters.transientCleanupPasses =
            (tonumber(D.Diagnostics.counters.transientCleanupPasses) or 0) + 1
        return true
    end
    self.transientCleanupJob = job
    return false
end

-- Hot reload keeps the global addon table alive. Normalize its transient
-- journals before replay so a partial prior version, duplicate event ID or one
-- damaged array entry cannot double-count data or stop COMBAT_MSG processing.
function R:NormalizeEventStore()
    -- 同一布局的热重载直接复用全局日志及 metatable；上一次运行已经维护了
    -- 稠密、有序和 pending 引用约束，不应再次 O(全部历史事件) 校验。
    if Store.journalState == "ValidatedDense"
        and tonumber(Store.journalReplayLayoutVersion) == REPLAY_LAYOUT_VERSION
        and self.replayMetaReused == true then
        D.Diagnostics.counters.hotReloadJournalFastPaths =
            (tonumber(D.Diagnostics.counters.hotReloadJournalFastPaths) or 0) + 1
        return 0
    end

    -- 旧布局日志已经由运行时持续维护为稠密、有序结构。升级到当前布局
    -- 时无需在加载帧再次遍历几十万条事件；旧事件仍可通过原 metatable
    -- 按字段名读取。这里只安排后台分帧重打包，pending、最后一击、
    -- 身份索引的对象引用和事件序号保持不变。
    if Store.journalState == "ValidatedDense"
        and tonumber(Store.journalReplayLayoutVersion) == 3
        and self.replayMetaReused ~= true
        and type(Store.sessionEvents) == "table" then
        self.sessionCompactionRequested = #Store.sessionEvents > 0
        self.sessionCompactionRequestedAt = self.sessionCompactionRequested and U.NowMs() or nil
        self.sessionCompactionCursor = 1
        self.sessionCompactionNextAt = nil
        if #Store.sessionEvents == 0 then
            Store.journalReplayLayoutVersion = REPLAY_LAYOUT_VERSION
        end
        D.Diagnostics.counters.hotReloadLegacyLayoutFastPaths =
            (tonumber(D.Diagnostics.counters.hotReloadLegacyLayoutFastPaths) or 0) + 1
        return 0
    end
    local repairs = 0
    local maxEventId = 0

    local function OrderedValues(source)
        if type(source) ~= "table" then return {} end
        local denseLength = #source
        local numericCount = 0
        local dense = true
        for index in pairs(source) do
            if type(index) == "number" and index >= 1 and index == math.floor(index) then
                numericCount = numericCount + 1
                if index > denseLength then dense = false end
            end
        end
        if dense and numericCount == denseLength then
            for index = 1, denseLength do
                if source[index] == nil then dense = false break end
            end
            if dense then return source end
        end

        -- Sparse/corrupted hot-reload arrays are rare. Repair them exactly, but
        -- keep the normal dense path allocation-free so a long raid journal is
        -- not duplicated and sorted merely because the addon was reloaded.
        local indexes = {}
        for index in pairs(source) do
            if type(index) == "number" and index >= 1 and index == math.floor(index) then
                indexes[#indexes + 1] = index
            end
        end
        table.sort(indexes)
        local values = {}
        for _, index in ipairs(indexes) do values[#values + 1] = source[index] end
        return values
    end

    local orderedSessions = OrderedValues(Store.sessionEvents)
    local sessions = {}
    local seenObjects = {}
    local byEventId = {}
    local denseSessionFastPath = orderedSessions == Store.sessionEvents
    local previousId = 0
    if denseSessionFastPath then
        for index, event in ipairs(orderedSessions) do
            local numericId = type(event) == "table" and U.FiniteNumber(event.eventId, nil) or nil
            if numericId == nil or numericId < 1 then
                denseSessionFastPath = false
                break
            end
            numericId = math.floor(numericId)
            if numericId <= previousId then
                denseSessionFastPath = false
                break
            end
            previousId = numericId
            event.eventId = numericId
            event.repdpsSessionIndex = index
        end
    end

    local denseSessionSorted = true
    local function FindDenseSessionEvent(numericId)
        if denseSessionSorted ~= true then
            for _, candidate in ipairs(sessions) do
                if type(candidate) == "table" and tonumber(candidate.eventId) == numericId then return candidate end
            end
            return nil
        end
        local low, high = 1, #sessions
        while low <= high do
            local middle = math.floor((low + high) / 2)
            local candidate = sessions[middle]
            local candidateId = type(candidate) == "table" and tonumber(candidate.eventId) or nil
            if candidateId == numericId then return candidate end
            if candidateId == nil or candidateId > numericId then high = middle - 1
            else low = middle + 1 end
        end
        return nil
    end

    local AddSessionEvent
    if denseSessionFastPath then
        sessions = orderedSessions
        maxEventId = previousId
        AddSessionEvent = function(event)
            if type(event) ~= "table" then repairs = repairs + 1 return nil end
            local index = math.floor(tonumber(event.repdpsSessionIndex) or 0)
            if index >= 1 and sessions[index] == event then return event end
            local numericId = U.FiniteNumber(event.eventId, nil)
            if numericId ~= nil and numericId >= 1 then
                numericId = math.floor(numericId)
                local canonical = FindDenseSessionEvent(numericId)
                if canonical ~= nil then
                    if canonical ~= event then repairs = repairs + 1 end
                    return canonical
                end
                event.eventId = numericId
                if numericId <= maxEventId then denseSessionSorted = false end
                maxEventId = math.max(maxEventId, numericId)
            else
                denseSessionSorted = false
            end
            sessions[#sessions + 1] = event
            event.repdpsSessionIndex = #sessions
            repairs = repairs + 1
            return event
        end
        D.Diagnostics.counters.denseEventStoreLoads =
            (tonumber(D.Diagnostics.counters.denseEventStoreLoads) or 0) + 1
    else
        AddSessionEvent = function(event)
            if type(event) ~= "table" then repairs = repairs + 1 return nil end
            local numericId = U.FiniteNumber(event.eventId, nil)
            local idKey = nil
            if numericId ~= nil and numericId >= 1 then
                numericId = math.floor(numericId)
                event.eventId = numericId
                idKey = numericId
                maxEventId = math.max(maxEventId, numericId)
                if byEventId[idKey] ~= nil then
                    if byEventId[idKey] ~= event then repairs = repairs + 1 end
                    return byEventId[idKey]
                end
            end
            if seenObjects[event] then return event end
            seenObjects[event] = true
            sessions[#sessions + 1] = event
            if idKey ~= nil then byEventId[idKey] = event end
            return event
        end
        for _, event in ipairs(orderedSessions) do AddSessionEvent(event) end
    end

    -- The pending array is the authoritative queue. Clear stale per-event flags
    -- first, then set them only for events that survive canonicalization below.
    -- Otherwise an already-applied event can remain labelled pending after a
    -- hot reload even though it is no longer retried or included in summaries.
    for _, event in ipairs(sessions) do
        EventClassifications:Set(event, "pending", false, "JOURNAL_NORMALIZE")
    end

    local pending = {}
    local seenPending = {}
    for _, event in ipairs(OrderedValues(Store.pending)) do
        local canonical = nil
        if type(event) == "table" then
            local numericId = U.FiniteNumber(event.eventId, nil)
            if numericId ~= nil then
                numericId = math.floor(numericId)
                canonical = denseSessionFastPath and FindDenseSessionEvent(numericId) or byEventId[numericId]
            end
        end
        canonical = canonical or AddSessionEvent(event)
        if canonical ~= nil and canonical.applied ~= true and canonical.retiredThirdParty ~= true
            and canonical.dormantThirdParty ~= true and canonical.dormantPending ~= true
            and seenPending[canonical] ~= true then
            EventClassifications:Set(canonical, "pending", true, "JOURNAL_PENDING_RECOVER")
            pending[#pending + 1] = canonical
            seenPending[canonical] = true
        elseif canonical ~= nil and seenPending[canonical] == true then
            repairs = repairs + 1
        end
    end
    -- A hot reload can preserve the replay journal but lose the separately
    -- maintained pending array. Recover every still-unapplied event here.
    for _, event in ipairs(sessions) do
        if event.applied ~= true and event.retiredThirdParty ~= true
            and event.dormantThirdParty ~= true and event.dormantPending ~= true
            and seenPending[event] ~= true then
            EventClassifications:Set(event, "pending", true, "JOURNAL_PENDING_REBUILD")
            pending[#pending + 1] = event
            seenPending[event] = true
            repairs = repairs + 1
        end
    end

    local raw = {}
    local rawLimit = U.Clamp(D.State.config.rawEventLimit or C.MAX_RAW_EVENTS, 100, C.MAX_RAW_EVENTS)
    local orderedRaw = Store.GetRawOrdered ~= nil and Store:GetRawOrdered() or OrderedValues(Store.raw)
    for _, event in ipairs(orderedRaw) do
        if type(event) == "table" then
            raw[#raw + 1] = event
        else
            repairs = repairs + 1
        end
    end
    if #raw > rawLimit then
        raw = U.TrimArrayFront(raw, rawLimit, #raw - rawLimit)
        repairs = repairs + 1
    end

    -- v0.2.25（问题 10）：环形缓冲热重载重建。按逻辑顺序收集有效条目，
    -- 再以相同顺序写入新环形槽（无需依赖物理数组顺序）。
    local candidateItems = {}
    ForEachRecentDamageNewestFirst(function(item)
        local candidateEvent = type(item) == "table" and item.event or nil
        if type(candidateEvent) == "table" then
            local candidateId = U.FiniteNumber(candidateEvent.eventId, nil)
            if candidateId ~= nil then
                candidateId = math.floor(candidateId)
                candidateEvent = denseSessionFastPath and FindDenseSessionEvent(candidateId) or byEventId[candidateId]
            elseif denseSessionFastPath then
                local index = math.floor(tonumber(candidateEvent.repdpsSessionIndex) or 0)
                if index < 1 or sessions[index] ~= candidateEvent then candidateEvent = nil end
            elseif seenObjects[candidateEvent] ~= true then
                candidateEvent = nil
            end
        end
        if type(item) == "table" and type(candidateEvent) == "table"
            and string.upper(tostring(candidateEvent.category or "")) == "DAMAGE" then
            if item.event ~= candidateEvent then repairs = repairs + 1 end
            item.event = candidateEvent
            local candidateAt = U.FiniteNumber(candidateEvent.timestamp, nil)
            item.at = U.FiniteNumber(item.at, candidateAt) or U.NowMs()
            item.targetName = U.NormalizeName(item.targetName or candidateEvent.targetName)
            item.targetKey = tostring(item.targetKey or candidateEvent.targetKey or "")
            candidateItems[#candidateItems + 1] = item
        else
            repairs = repairs + 1
        end
        return false
    end)
    local candidates = {}
    Store.recentDamageCandidates = candidates
    Store.recentDamageHead = 1
    Store.recentDamageTail = 1
    Store.recentDamageCount = 0
    for _, item in ipairs(candidateItems) do
        if Store.recentDamageCount >= RingBufferCapacity then
            candidates[Store.recentDamageHead] = nil
            Store.recentDamageHead = RingNext(Store.recentDamageHead)
            Store.recentDamageCount = Store.recentDamageCount - 1
        end
        candidates[Store.recentDamageTail] = item
        Store.recentDamageTail = RingNext(Store.recentDamageTail)
        Store.recentDamageCount = Store.recentDamageCount + 1
    end

    for index, event in ipairs(sessions) do
        if type(event) == "table" then event.repdpsSessionIndex = index end
    end
    Store.sessionEvents = sessions
    Store.pending = pending
    Store.pendingCursor = 1
    self.sessionCompactionCursor = 1
    Store.raw = raw
    Store.rawRingCapacity = 0
    Store.rawRingCount = 0
    Store.rawRingWrite = 1
    if Store.EnsureRawRing ~= nil then Store:EnsureRawRing(rawLimit) end
    Store.recentDamageCandidates = candidates
    -- 环形缓冲状态已在重建循环中维护（head/tail/count），这里不再重置。
    Store.nextId = math.max(1, math.floor(U.FiniteNumber(Store.nextId, 1) or 1), maxEventId + 1)
    -- v0.2.25（问题 4）：根据修复结果设置日志状态。
    -- 稠密快速路径（无修复）→ ValidatedDense；发生过修复 → ValidatedSparse；
    -- 空日志 → ValidatedDense（无内容可检查）。
    local dense = denseSessionFastPath == true and repairs == 0
    if Store.journalState ~= nil then
        Store.journalState = (#sessions == 0 or dense) and "ValidatedDense" or "ValidatedSparse"
        Store.journalStateVersion = (tonumber(Store.journalStateVersion) or 0) + 1
        Store.journalReplayLayoutVersion = REPLAY_LAYOUT_VERSION
    end
    -- v0.2.25（问题 1）：热重载重建了整本日志，反向索引必须失效。
    -- 索引本身是派生缓存，语义上可随时重建；重建由 OnUpdate 中的
    -- EnsureIdentityIndex 分帧完成，避免单帧扫描全部历史事件。
    if Store.ResetIdentityIndex ~= nil then Store:ResetIdentityIndex() end
    -- A repaired/reordered journal defines a new immutable-fact generation.
    -- Reset only the diagnostic sidecar and rebuild it with bounded steps; the
    -- production EventStore and statistics remain untouched.
    EventFacts:OnEventStoreReset(
        repairs > 0 and "journal_repaired" or "journal_normalized")
    CallEventBlocks("OnEventStoreReset",
        repairs > 0 and "journal_repaired" or "journal_normalized")
    EventClassifications:OnEventStoreReset(
        repairs > 0 and "journal_repaired" or "journal_normalized")
    CallEventShadow("OnEventStoreReset", repairs > 0 and "journal_repaired" or "journal_normalized")
    -- 热重载后立即尝试小批量预建，让身份升级尽量走索引路径。
    if Store.EnsureIdentityIndex ~= nil and self.started == true then
        Store:EnsureIdentityIndex(2000, Store.identityGeneration)
    end

    if repairs > 0 then
        D.Diagnostics:AddWarning("event_store", "已修复热重载事件缓存：" .. tostring(repairs))
    end
    return repairs
end

function R:OnUpdate(dt)
    if type(U.AdvanceClock) == "function" then U.AdvanceClock(dt) end
    local timers = D.State.timers
    timers.ui = timers.ui + dt
    timers.roster = timers.roster + dt
    timers.save = timers.save + dt
    timers.decay = timers.decay + dt
    timers.pending = timers.pending + dt
    timers.breakdown = (timers.breakdown or 0) + dt
    timers.configSave = (timers.configSave or 0) + dt
    timers.uiSave = (timers.uiSave or 0) + dt
    timers.rulesSave = (timers.rulesSave or 0) + dt
    timers.viewport = (timers.viewport or 0) + dt
    timers.snapshotSave = (timers.snapshotSave or 0) + dt

    local now = U.NowMs()
    -- TEAM_MEMBERS_CHANGED may fire while raidTeamManager is still inside native
    -- member OnShow/OnHide. The event handler itself is data-only; keep the
    -- incremental team-token probe fenced for one second as well so the next
    -- OnUpdate cannot immediately race the native roster rebuild.
    local teamRosterStable = now - (tonumber(self.lastTeamMembersChangedAt) or 0) >= 1000
    if self.baselineInitializing == true then
        ProtectedCall("baseline_initialize", R.ProcessBaselineInitialization, self,
            C.BASELINE_COPY_FIELDS or 3000, C.BASELINE_DRAIN_EVENTS or 200)
    end
    local highLoad = self:IsHighLoad(now)
    local idleFor = now - (tonumber(self.lastCombatEventAt) or 0)
    -- 小队 Boss 事件率可能低于 HIGH_LOAD_EVENT_RATE，但主线程仍在持续处理
    -- 战斗、动画和 UI。所有非紧急后台任务按“是否正在战斗”降批次，避免
    -- roster/sight/pending/decay/ranking/replay 在同一帧叠加空闲预算。
    local combatActive = idleFor < (tonumber(C.ACTIVE_COMBAT_MAINTENANCE_MS) or 1500)
    local maintenanceThrottled = highLoad or combatActive

    -- 每项后台工作即使都有固定预算，若团队扫描、视野解析、待确认、
    -- 排行榜和日志整理恰好落在同一帧，预算仍会叠加成可感知尖峰。
    -- 战斗期间把可延迟维护分成四条轮转通道；空闲时全部放开以快速追平。
    if combatActive then
        self.maintenanceLane = ((math.floor(tonumber(self.maintenanceLane) or 0)) % 4) + 1
    else
        self.maintenanceLane = 0
    end
    local runIdentityLane = not combatActive or self.maintenanceLane == 1 -- 团队、视野
    local runEvidenceLane = not combatActive or self.maintenanceLane == 2 -- 待确认、衰减、清理
    local runProjectionLane = not combatActive or self.maintenanceLane == 3 -- 明细、排行榜
    local runJournalLane = not combatActive or self.maintenanceLane == 4 -- 日志、反向索引

    local rosterInterval = highLoad and math.max(D.State.config.rosterScanMs, C.HIGH_LOAD_ROSTER_MS) or D.State.config.rosterScanMs
    local pendingInterval = highLoad and C.HIGH_LOAD_PENDING_MS or C.PENDING_RETRY_INTERVAL_MS
    local uiInterval = highLoad and math.max(D.State.config.uiRefreshMs, C.HIGH_LOAD_UI_MS) or D.State.config.uiRefreshMs
    local uiGeometryBusy = D.UI ~= nil
        and ((tonumber(D.UI.movingCount) or 0) > 0 or (tonumber(D.UI.resizingCount) or 0) > 0)
    if uiGeometryBusy and (tonumber(D.UI.movingCount) or 0) > 0
        and type(D.UI.StepDragTransaction) == "function" then
        CriticalCall("ui_drag_transaction", D.UI.StepDragTransaction, D.UI)
    end

    if runIdentityLane and teamRosterStable and timers.roster >= rosterInterval then
        timers.roster = 0
        ProtectedCall("roster_begin", R.BeginRosterScan, self, false)
        -- Target observation is a cheap, legal replacement for the accidentally
        -- removed target half of the old sight scan. It lets TEAM sources route
        -- their NPC/Boss damage even though broad nearby enumeration is disabled.
        ProtectedCall("current_target", R.ScanCurrentTarget, self, false)
    end
    if runIdentityLane and teamRosterStable and self.rosterScanJob ~= nil then
        local rosterBatch = maintenanceThrottled and (C.HIGH_LOAD_ROSTER_BATCH or 10)
            or (C.NORMAL_ROSTER_BATCH or 24)
        ProtectedCall("roster_step", R.ProcessRosterScanStep, self, rosterBatch)
    end
    if runEvidenceLane and timers.pending >= pendingInterval then
        timers.pending = 0
        Protected("pending", function()
            local pendingBatch = maintenanceThrottled and (C.HIGH_LOAD_PENDING_BATCH or 8)
                or (C.PENDING_RETRY_BATCH or 48)
            self:ReprocessPending(false, pendingBatch)
        end)
    end
    if runEvidenceLane and timers.decay >= 30000 then
        timers.decay = 0
        Protected("decay_begin", function()
            E:BeginDecayScores(now)
            self:BeginTransientCleanup()
        end)
    end
    if runEvidenceLane and self.transientCleanupJob ~= nil then
        local cleanupBudget = maintenanceThrottled and math.max(16, math.floor((C.TRANSIENT_CLEANUP_BATCH or 96) / 3))
            or (C.TRANSIENT_CLEANUP_BATCH or 96)
        ProtectedCall("transient_cleanup", R.StepTransientCleanup, self, cleanupBudget)
    end
    if runEvidenceLane and self.pendingTrimTarget ~= nil then
        ProtectedCall("pending_trim", R.TrimPendingOverflow, self, C.PENDING_TRIM_BATCH or 8)
    end
    if runEvidenceLane and E.decayJob ~= nil then
        local decayBudget = maintenanceThrottled and (C.HIGH_LOAD_DECAY_ENTITIES or 40)
            or (C.NORMAL_DECAY_ENTITIES or 160)
        ProtectedCall("decay_step", E.DecayScoresStep, E, decayBudget)
    end
    if runProjectionLane and timers.breakdown >= (tonumber(C.BREAKDOWN_COMPACT_INTERVAL_MS) or 5000) then
        timers.breakdown = 0
        local actorBudget = maintenanceThrottled and (C.HIGH_LOAD_BREAKDOWN_ACTORS or 6)
            or (C.NORMAL_BREAKDOWN_ACTORS or 24)
        ProtectedCall("breakdown_compact", S.CompactBreakdownsStep, S, actorBudget)
    end

    -- v0.2.25（问题 2）：排行榜分帧重建。事件到达只递增版本号并标记
    -- 脏，真正的全量重算在这里按预算推进；UI 刷新读取已提交的缓存。
    if runProjectionLane and (S.rankingRebuildJob ~= nil
        or (type(S.rankingRebuildQueue) == "table"
            and (tonumber(S.rankingRebuildQueueHead) or 1)
                <= (tonumber(S.rankingRebuildQueueTail) or 0))) then
        local rankingBudget = maintenanceThrottled and 80 or 320
        ProtectedCall("ranking_rebuild", S.StepRankingRebuild, S, rankingBudget)
    end
    if runProjectionLane and S.rankingCachesDirty == true then
        local patchBudget = maintenanceThrottled and 24 or 64
        ProtectedCall("ranking_patch", S.StepRankingCachePatches, S, patchBudget)
    end

    if runJournalLane and self.sessionCompactionRequested == true
        and now >= (tonumber(self.sessionCompactionNextAt) or 0) then
        self.sessionCompactionRequestedAt = tonumber(self.sessionCompactionRequestedAt) or now
        self.sessionCompactionNextAt = now + (tonumber(C.SESSION_COMPACT_STEP_MS) or 50)
        local batch = maintenanceThrottled and math.max(40, math.floor((C.SESSION_COMPACT_BATCH or 160) / 2))
            or (C.SESSION_COMPACT_BATCH or 160)
        ProtectedCall("session_compact", R.CompactSessionNow, self, batch)
    end

    -- prep8：正式不可变 Fact sidecar 通过固定预算覆盖旧日志。普通
    -- 战斗事件在追加时 O(1) 导入；这里只处理热重载历史。
    if runJournalLane and EventFacts.backfillJob ~= nil then
        local factBudget = maintenanceThrottled and 160 or 640
        ProtectedCall("event_fact_backfill", EventFacts.StepBackfill, EventFacts, factBudget)
    end

    -- prep9：EventBlock 仅在诊断开启时并行构建。每块固定 512 条，
    -- 现有日志回填按预算推进；正式 EventStore 完整重放路径不读取它。
    if runJournalLane and D.State.config.diagnosticsEnabled == true
        and EventBlocks.backfillJob ~= nil then
        local eventBlockBudget = maintenanceThrottled and 120 or 480
        CallEventBlocks("StepBackfill", eventBlockBudget)
    end

    -- prep14：局部重放闭包、Stats 稀疏候选、派生状态门禁、完整
    -- IdentityProjection 重建和只读提交信封均由同一分帧计划推进。
    -- 正式局部提交仍硬关闭；信封只描述提交/回滚顺序，不执行写回。
    if runJournalLane and D.State.config.diagnosticsEnabled == true
        and LocalReplay.activePlan ~= nil then
        local localReplayBudget = maintenanceThrottled and 100 or 400
        CallLocalReplay("Step", localReplayBudget)
    end

    -- rc1：固定 16-shard 现在是 rotating 成功保存后的正式镜像。构建、
    -- manifest 提交与维护仍只在空闲帧分批推进；任何失败都保留 rotating
    -- primary/backup 作为权威回退，不改变 dirty 标记。
    if PersistenceShards.activeJob ~= nil
        and idleFor >= C.SAVE_IDLE_MS and not highLoad
        and self.replayJob == nil and self.replaying ~= true
        and self.baselineInitializing ~= true then
        ProtectedCall("persistence_shards_step", PersistenceShards.Step,
            PersistenceShards, maintenanceThrottled and 8 or 32)
    end

    -- rc1：流式双读门禁不会同时构造第二棵完整 Stats 根。最新 shard
    -- generation 需要审计或已有任务时，在空闲帧推进；通过后只更新下一次
    -- 完整启动可用的切换 marker，本帧不替换 D.State.stats。
    if (PersistenceLoadGate.activeJob ~= nil
            or (type(PersistenceLoadGate.ShouldAutoAudit) == "function"
                and PersistenceLoadGate:ShouldAutoAudit()))
        and idleFor >= C.SAVE_IDLE_MS and not highLoad
        and self.replayJob == nil and self.replaying ~= true
        and self.baselineInitializing ~= true then
        ProtectedCall("persistence_load_gate_step", PersistenceLoadGate.Step,
            PersistenceLoadGate, maintenanceThrottled and 80 or 240)
    end

    -- 分片清理等破坏性维护只由用户明确触发。每帧最多执行有限个固定
    -- SaveData/ClearData 操作，避免在战斗或 UI 刷新中同步清理全部 51 个键。
    if (PersistenceShards.maintenanceJob ~= nil or PersistenceSwitch.maintenanceJob ~= nil)
        and idleFor >= C.SAVE_IDLE_MS and not highLoad
        and self.replayJob == nil and self.replaying ~= true
        and self.baselineInitializing ~= true then
        ProtectedCall("persistence_switch_maintenance", PersistenceSwitch.StepMaintenance,
            PersistenceSwitch, maintenanceThrottled and 1 or 2)
    end

    -- prep7：正式 EventClassification sidecar 必须覆盖整本日志，但回填
    -- 仍按固定预算分帧执行，不允许在加载帧或战斗回调中同步扫描。
    if runJournalLane and EventClassifications.backfillJob ~= nil
        and EventClassifications.transaction == nil then
        local classificationBudget = maintenanceThrottled and 160 or 640
        ProtectedCall("event_classification_backfill",
            EventClassifications.StepBackfill, EventClassifications, classificationBudget)
    end

    -- prep6：诊断模式下分帧回填不可变 Fact / Classification 影子。
    -- 每帧固定预算；普通模式 CallEventShadow 只执行配置分支。
    if runJournalLane and D.State.config.diagnosticsEnabled == true
        and EventShadow.backfillJob ~= nil then
        local eventShadowBudget = maintenanceThrottled and 120 or 480
        CallEventShadow("StepBackfill", eventShadowBudget)
    end

    -- v0.2.25（问题 1）：热重载后反向索引尚未建完时，分帧推进重建。
    -- 正常运行时每次事件追加都会增量登记，index.complete 为 true，此分支
    -- 是 O(1) 检查，不会扫描日志。
    if runJournalLane and Store.EnsureIdentityIndex ~= nil
        and Store.identityIndex ~= nil and Store.identityIndex.complete ~= true then
        local identityBudget = maintenanceThrottled and 500 or 2000
        ProtectedCall("identity_index", Store.EnsureIdentityIndex, Store,
            identityBudget, Store.identityGeneration)
    end
    if runJournalLane and self.dormantEvidenceIndexComplete ~= true then
        local dormantBudget = maintenanceThrottled and 500 or 2000
        ProtectedCall("dormant_evidence_index", R.StepDormantEvidenceIndex, self, dormantBudget)
    end

    local reclassifyPendingBatch = maintenanceThrottled
        and (C.HIGH_LOAD_RECLASSIFY_PENDING_BATCH or 12)
        or (C.RECLASSIFY_PENDING_BATCH or 200)
    if Store.historyCoverageComplete == false and self.fullReclassifyRequested == true
        and not self:CanReplayCurrentWindow() then
        -- Retain the full replay request until the correction baseline commits.
        -- A bounded pending pass may still run below, but it is not a substitute
        -- for migrating already-applied Side/mode contributions.
        self.pendingEvidenceChanged = true
    end

    if D.State.dirty.reclassify then
        if self.fullReclassifyRequested == true then
            self.reclassifyRequestedAt = tonumber(self.reclassifyRequestedAt) or now
            local reclassifyAge = now - (tonumber(self.reclassifyRequestedAt) or now)
            if (not highLoad and idleFor >= C.RECLASSIFY_IDLE_MS)
                or (self.reclassifyUrgent == true and reclassifyAge >= 100) then
                -- v0.2.25（问题 7）：分帧事务重放。空闲时启动任务，之后
                -- 每帧按预算推进；绝不在单帧同步重放全部历史事件。
                -- 日志需要修复时先驱动 NormalizeEventStore（分帧完成，
                -- 由 reclassify_begin 幂等调用），修复完成后才开始重放。
                if self.replayJob == nil and Store.journalState ~= nil
                    and Store.journalState ~= "ValidatedDense" and Store.journalState ~= "ValidatedSparse" then
                    ProtectedCall("journal_repair", R.NormalizeEventStore, self)
                elseif self.replayJob == nil and self.baselineInitializing ~= true then
                    ProtectedCall("reclassify_begin", R.BeginReplaySessionStats, self)
                end
            elseif now - (tonumber(self.lastPendingReclassifyAt) or 0) >= C.RECLASSIFY_PENDING_PASS_MS then
                if reclassifyAge >= C.RECLASSIFY_MAX_DELAY_MS then
                    D.Diagnostics.counters.deferredLiveReclassifies =
                        (tonumber(D.Diagnostics.counters.deferredLiveReclassifies) or 0) + 1
                end
                self.lastPendingReclassifyAt = now
                ProtectedCall("reclassify_pending", R.ReprocessPending, self,
                    true, reclassifyPendingBatch)
            end
        elseif self.pendingEvidenceChanged == true then
            -- New official identity evidence only needs unresolved rows retried.
            -- Process one bounded pass and then return to exponential backoff.
            if now - (tonumber(self.lastPendingReclassifyAt) or 0) >= 500 then
                self.lastPendingReclassifyAt = now
                ProtectedCall("identity_pending", R.ReprocessPending, self,
                    true, reclassifyPendingBatch)
                self.pendingEvidenceChanged = false
                self.pendingEvidenceRequestedAt = nil
                D.State.dirty.reclassify = false
            end
        else
            -- Legacy direct dirty marks are treated as bounded pending evidence,
            -- not permission to replay the complete session automatically.
            self.pendingEvidenceChanged = true
        end
    else
        self.reclassifyRequestedAt = nil
        self.lastPendingReclassifyAt = nil
        self.pendingEvidenceRequestedAt = nil
    end

    -- v0.2.25（问题 7）：分帧重放任务持续推进（每帧固定预算，高负载减半）。
    if self.replayJob ~= nil then
        -- 重放通常在空闲期启动，但玩家可能在任务完成前重新开战。
        -- 此时仍需继续推进以免直播事件队列无限增长，不过使用极小批次，
        -- 不再把 1200 条历史事件压进一个正在战斗的帧。
        local replayEventBudget
        local replayEntityBudget
        if combatActive then
            replayEventBudget = highLoad and 40 or 80
            replayEntityBudget = highLoad and 10 or 20
        else
            replayEventBudget = highLoad and 300 or 1200
            replayEntityBudget = highLoad and 60 or 200
        end
        ProtectedCall("replay_step", R.StepReplaySessionStats, self,
            replayEventBudget, replayEntityBudget)
    end

    -- DRAIN_QUEUE may append more than one correction-window worth of callbacks
    -- while rotation is deliberately blocked by the active replay transaction.
    -- Rotate as soon as the replay and any follow-up correction are fully settled;
    -- otherwise a fight that ends on the commit frame can retain an oversized
    -- journal indefinitely until another COMBAT_MSG happens to arrive.
    if self.correctionRotationDeferred == true
        and self.replayJob == nil and self.replaying ~= true
        and self.baselineInitializing ~= true
        and self.fullReclassifyRequested ~= true
        and self.reclassifyAfterReplay ~= true
        and D.State.dirty.reclassify ~= true then
        local correctionLimit = math.max(1000,
            math.floor(tonumber(C.MAX_CORRECTION_JOURNAL_EVENTS) or 4000))
        if #(Store.sessionEvents or {}) >= correctionLimit then
            ProtectedCall("correction_window_deferred", R.RotateCorrectionJournal,
                self, "DEFERRED_AFTER_REPLAY")
        else
            self.correctionRotationDeferred = nil
        end
    end

    if timers.viewport >= 1000 then
        timers.viewport = 0
        if D.UI.CheckViewportChanged ~= nil then
            ProtectedCall("viewport", D.UI.CheckViewportChanged, D.UI)
        end
    end

    if D.State.dirty.layout and D.UI.movingCount == 0 and D.UI.resizingCount == 0 then
        ProtectedCall("layout", D.UI.LayoutAll, D.UI)
    end
    -- Keep ranking content/layout redraws out of the native move/resize loop.
    -- ArcheRage redraws child anchors synchronously; refreshing rows while the
    -- parent is being moved is the main source of visible drag flashing. Leave
    -- the timer saturated so the first frame after release refreshes at once.
    if timers.ui >= uiInterval and not uiGeometryBusy then
        timers.ui = 0
        local needsRateRefresh = false
        if D.UI ~= nil and D.UI.NeedsRateRefresh ~= nil then
            local okRate, result = CriticalCall("ui_needs_refresh", D.UI.NeedsRateRefresh, D.UI)
            needsRateRefresh = okRate and result == true
        end
        local renderedRevision = tonumber(D.UI and D.UI.lastRenderedStatsRevision) or -1
        local statsRevision = tonumber(S.statsMutationRevision) or 0
        local revisionChanged = renderedRevision ~= statsRevision
        if D.State.dirty.stats or D.State.dirty.view or revisionChanged or needsRateRefresh then
            -- quick_refresh 失败后必须继续按刷新周期重试，不能熔断 30 秒。
            CriticalCall("quick_refresh", D.UI.RefreshQuickWindows, D.UI)
        end
        local configWindow = D.UI and D.UI.windows and D.UI.windows.config or nil
        local configVisible = false
        if configWindow ~= nil and configWindow.IsVisible ~= nil then
            local okVisible, result = CriticalCall("config_visible", configWindow.IsVisible, configWindow)
            configVisible = okVisible and result == true
        end
        if configVisible then CriticalCall("config_refresh", D.UI.RefreshConfig, D.UI) end
    end
    if D.State.dirty.configSave and timers.configSave >= 1500 then
        CriticalPreferenceSave("config_save", "configSave", D.SaveConfigNow)
    end
    if D.State.dirty.uiSave and timers.uiSave >= 1500 then
        CriticalPreferenceSave("ui_save", "uiSave", D.SaveUiNow)
    end
    if D.State.dirty.rulesSave and timers.rulesSave >= 500 then
        CriticalPreferenceSave("rules_save", "rulesSave", D.SaveRulesNow)
    end

    if timers.save >= D.State.config.persistenceMs and D.State.dirty.statsSave then
        -- v0.2.26（小队 Boss 卡顿修复）：完整统计快照绝不能在持续战斗中启动。
        -- v0.2.25 的 SAVE_FORCE_MS 分支会在 120 秒后绕过 idleFor 条件：
        -- 5 人 Boss 场景通常低于 HIGH_LOAD_EVENT_RATE，因此被误判为“可保存”。
        -- 每个新战斗事件随后又通过 MarkStatsMutated 作废快照，下一帧从头复制，
        -- 形成“120 秒后每帧复制数百/数千字段”的永久抖动。现在只在真正连续
        -- 空闲 SAVE_IDLE_MS 后推进完整快照；持续战斗期间只累计 dirty 标记。
        if idleFor >= C.SAVE_IDLE_MS and not highLoad
            and self.replayJob == nil and self.replaying ~= true
            and self.baselineInitializing ~= true then
            -- Do not begin a synchronous all-actor breakdown sweep at the save
            -- boundary. Finish the same maintenance incrementally over a few
            -- idle frames, then snapshot only when the pass covers the latest
            -- statistics revision.
            if not S:IsBreakdownCompactionCurrent() then
                ProtectedCall("save_breakdown_compact", S.CompactBreakdownsStep, S,
                    C.SAVE_BREAKDOWN_ACTORS or 96)
                if not S:IsBreakdownCompactionCurrent() then
                    D.Diagnostics.counters.deferredSavesForCompaction =
                        (tonumber(D.Diagnostics.counters.deferredSavesForCompaction) or 0) + 1
                end
            end
            if S:IsBreakdownCompactionCurrent() then
                local snapshotReady = false
                local snapshotPayload = nil
                Protected("save_snapshot_step", function()
                    snapshotReady, snapshotPayload = S:StepPersistenceSnapshot(C.SAVE_SNAPSHOT_FIELDS or 2500)
                end)
                if snapshotReady == true and type(snapshotPayload) == "table" then
                    local committed = false
                    Protected("save_stats_commit", function()
                        committed = D.SavePreparedStats(snapshotPayload) == true
                    end)
                    if committed then timers.save = 0 end
                end
            end
        else
            -- 只记录一次“正在因战斗/重放延期”，避免每帧增加诊断计数本身成为热点。
            if self.statsSaveDeferredForCombat ~= true then
                self.statsSaveDeferredForCombat = true
                D.Diagnostics.counters.deferredActiveCombatSaves =
                    (tonumber(D.Diagnostics.counters.deferredActiveCombatSaves) or 0) + 1
            end
        end
    elseif timers.save >= D.State.config.persistenceMs and D.State.dirty.statsSave ~= true then
        timers.save = 0
        self.statsSaveDeferredForCombat = false
    end
    if idleFor >= C.SAVE_IDLE_MS and self.replayJob == nil and self.replaying ~= true
        and self.baselineInitializing ~= true then
        self.statsSaveDeferredForCombat = false
    end

    -- v0.2.25（清空修复）：清空快照延迟持久化。序列化旧统计是同步大事务，
    -- 只允许在低负载空闲帧执行；失败保留 dirty 标记稍后重试，不影响清空本身。
    if D.State.dirty.snapshotSave == true and timers.snapshotSave >= 2000 then
        if highLoad or idleFor < C.SAVE_IDLE_MS then
            timers.snapshotSave = 0
        else
            local snapshotSaved = false
            Protected("clear_snapshot_save", function()
                snapshotSaved = P.SaveTransactional("snapshot", D.State.pendingClearSnapshot) == true
            end)
            if snapshotSaved then
                D.State.dirty.snapshotSave = false
                D.State.pendingClearSnapshot = nil
                D.Diagnostics.counters.clearSnapshotsSaved =
                    (tonumber(D.Diagnostics.counters.clearSnapshotsSaved) or 0) + 1
            else
                -- 保存失败：保留待保存快照，稍后重试（内存快照始终可用于本会话恢复）。
                timers.snapshotSave = 0
            end
        end
    end
end

local MODE_CLASSIFICATION_POLICY_VERSION = 8

function R:DescribeScope()
    local rosterCount = 0
    if type(E.roster) == "table" then
        for _ in pairs(E.roster) do rosterCount = rosterCount + 1 end
    end
    return {
        scopeMode = IsTeamScopeMode() and "team" or "range",
        teamRosterCount = rosterCount,
        teamLayoutName = tostring(self.teamLayoutName or "unknown"),
        eventTransport = tostring(self.eventTransport or "not_started"),
        -- Nearby/range scope has no broad-sight enumeration since GetUnitsInSight
        -- was disabled by RU 2026-08-19; observation degrades to target+team.
        nearbyMode = not IsTeamScopeMode(),
        scopeContextOnlyEvents = tonumber(D.Diagnostics.counters.scopeContextOnlyEvents) or 0,
        scopeContextOnlyMetrics = tonumber(D.Diagnostics.counters.scopeContextOnlyMetrics) or 0,
    }
end

local function FlushPendingPreferenceSaves(reason)
    -- Config/UI/rules are small user preferences with short debounce timers.
    -- They live in DPS-owned SaveData keys, so Suite Storage:SaveNow() cannot
    -- flush them on logout/reload.  Close that ownership gap at the DPS Runtime
    -- boundary. Combat/stat snapshots stay on their dedicated persistence path
    -- because forcing those large writes during shutdown can stall the client.
    if rawget(_G, "ReplicatedSuiteFactoryResetPending") == true then return true end
    if D.State == nil or type(D.State.dirty) ~= "table" then return true end

    local failures = {}
    local function Flush(label, dirtyKey, saveFn)
        if D.State.dirty[dirtyKey] ~= true or type(saveFn) ~= "function" then return end
        local ok, result = xpcall(saveFn, Boot.SafeTraceback)
        if not ok or result ~= true then
            failures[#failures + 1] = tostring(label) .. ":" .. tostring(ok and result or "error")
        end
    end

    Flush("config", "configSave", D.SaveConfigNow)
    Flush("ui", "uiSave", D.SaveUiNow)
    Flush("rules", "rulesSave", D.SaveRulesNow)

    if #failures > 0 then
        D.Diagnostics = type(D.Diagnostics) == "table" and D.Diagnostics or {}
        D.Diagnostics.counters = type(D.Diagnostics.counters) == "table" and D.Diagnostics.counters or {}
        D.Diagnostics.counters.preferenceFlushFailures =
            (tonumber(D.Diagnostics.counters.preferenceFlushFailures) or 0) + 1
        if tostring(reason or "") ~= "shutdown" and D.Boot ~= nil and type(D.Boot.SafeChat) == "function" then
            D.Boot.SafeChat("DPS 设置收尾保存失败：" .. table.concat(failures, ", "))
        end
        return false
    end
    return true
end

function R:Stop(reason)
    FlushPendingPreferenceSaves(reason)
    -- Stop must also clean a partially-started Runtime.  In embedded mode the
    -- ModuleManager can call Disable as compensation after Start() faults
    -- between RegisterEvents/CreateUpdateHost and the final started=true.
    -- Gating cleanup on self.started would leak event/update handlers and
    -- create a ghost Runtime while Suite correctly reports the module OFF.
    self:AbortStart()
    self.started = false
    if D.State ~= nil and D.State.runtime ~= nil then D.State.runtime.paused = true end
    if D.UI ~= nil and D.UI.windows ~= nil then
        for _, key in ipairs({ "friendly", "enemy", "detail", "confirm" }) do
            local window = D.UI.windows[key]
            if window ~= nil then pcall(function() window:Show(false) end) end
        end
    elseif D.UI ~= nil and type(D.UI.ApplyVisibility) == "function" then
        D.UI:ApplyVisibility()
    end
    return true
end

function R:Start()
    if self.started == true and self.generation == Boot.generation then return end
    self.generation = Boot.generation
    D.State.runtime.generation = Boot.generation
    local previousModePolicy = math.floor(tonumber(Store.modeClassificationPolicyVersion) or 0)
    local modePolicyUpgraded = previousModePolicy < MODE_CLASSIFICATION_POLICY_VERSION
    Store.modeClassificationPolicyVersion = MODE_CLASSIFICATION_POLICY_VERSION
    if modePolicyUpgraded then
        -- v8 keeps the detached rolling correction baseline and extends the
        -- multi-projection correction contract: relation-provisional PVE rows
        -- participate in dormant evidence replay, cross-world clicked projections
        -- follow verified identity aliases, and unique-player ignore mirrors are
        -- reversible across id:/history: representations.
        -- Older frozen totals remain authoritative because their event facts no
        -- longer exist and cannot be split safely.
        self:ClearUntrustedAutomaticKindEvidence()
    end
    self:NormalizeEventStore()
    if Store.baselineStats == nil then self:BeginBaselineInitialization() end
    Store.sessionEvents = Store.sessionEvents or {}
    Store.pending = Store.pending or {}
    Store.pendingCursor = math.max(1, math.floor(tonumber(Store.pendingCursor) or 1))
    Store.recentDamageHead = math.max(1, tonumber(Store.recentDamageHead) or 1)
    -- v0.2.25（问题 10）：环形缓冲指针初始化。
    Store.recentDamageTail = math.max(1, tonumber(Store.recentDamageTail) or 1)
    -- rc3：最后一击正式链路已停用，热重载时直接释放旧候选与死亡通知缓存。
    ResetRecentDamageRing()
    self.pendingDeathNotices = {}
    self.lastDeathByEventId = {}
    self.replaying = false
    D.State.runtime.replaying = false
    self.processingReplayQueue = false
    self.replayEventQueue = type(self.replayEventQueue) == "table" and self.replayEventQueue or {}
    self.sessionCompactionCursor = math.max(1, math.floor(tonumber(self.sessionCompactionCursor) or 1))
    self:MaybeCompactSession()
    if modePolicyUpgraded and #Store.sessionEvents > 0 then
        if self:CanReplayCurrentWindow() then
            self.fullReclassifyRequested = true
            self.reclassifyReason = "MODE_POLICY_ROLLING_WINDOW_V8"
            self.reclassifyRequestedAt = tonumber(self.reclassifyRequestedAt) or U.NowMs()
            D.State.dirty.reclassify = true
        else
            D.Diagnostics:AddWarning("mode_policy_upgrade",
                "retained window replay deferred until a detached correction baseline is available")
        end
    elseif D.State.dirty.reclassify == true and #Store.sessionEvents > 0 then
        self.fullReclassifyRequested = true
        self.reclassifyRequestedAt = tonumber(self.reclassifyRequestedAt) or U.NowMs()
    end
    self.loadWindowStartedAt = U.NowMs()
    self.loadWindowEvents = 0
    self.combatEventRate = 0
    self:RegisterEvents(self.generation)
    self:RegisterEscMenu()
    self:CreateUpdateHost(self.generation)
    self:ScanRoster()
    -- Prime target identity immediately; the periodic identity lane keeps it
    -- fresh afterwards. Failure/no target is an expected no-op.
    ProtectedCall("current_target_start", R.ScanCurrentTarget, self, true)
    if D.Rules ~= nil and D.Rules.ApplyAll ~= nil then D.Rules:ApplyAll(true) end
    -- Normalize legacy/hot-reload pending summaries before the first retry pass.
    self:RecomputePendingSummaries()
    self:TrimPendingOverflow()
    self:ReprocessPending(true, C.STARTUP_PENDING_BATCH)
    D.UI:LayoutAll()
    D.UI:ApplyVisibility()
    D.UI:RefreshQuickWindows()
    D.UI:RefreshConfig()
    self.started = true
end

if ReplicatedSuiteEmbedded ~= true then
    local ok, err = xpcall(function() R:Start() end, Boot.SafeTraceback)
    if not ok then
        pcall(function() R:AbortStart() end)
        Boot:Fail("runtime", err)
        return
    end
    Boot:CompletePhase("RUNTIME_READY")
    D.Diagnostics.status = "RUNTIME_READY"
else
    -- Code/data/UI are loaded, but Suite ModuleManager is the only runtime
    -- lifecycle Authority. Fresh installs therefore remain idle until enabled.
    Boot:CompletePhase("MODULE_LOADED")
    D.Diagnostics.status = "MODULE_LOADED"
end
