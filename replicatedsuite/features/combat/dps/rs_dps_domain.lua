------------------------------------------------------------------------
-- Replicated Suite · 伤害与治疗统计业务领域
-- 作者：Replicated
-- QQ群：1104129461
--
-- 纯战斗统计 Domain：CombatEventBus 拥有 Native COMBAT_MSG，CombatRelationV3 拥有 SELF/TEAM/FRIENDLY/OPPONENT 事实；本 Domain 负责逐事件 PVP/PVE 分类、累加、重放和投影。
-- 热路径禁止持久化、UI、Native 名单扫描、Tick/OnUpdate 和回调内全 pending 扫描；显示上限不能限制累加。
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local F = S.Features and S.Features.DPS or nil
if type(F) ~= "table" then return end

local U = S.Utils
local function NowMs() return math.max(0, tonumber(S.NowMs and S.NowMs()) or 0) end
local function Trim(value) return U and U.Trim and U.Trim(value) or (tostring(value or ""):match("^%s*(.-)%s*$") or "") end
local function Relation() return S.Services and S.Services.CombatRelationV3 or nil end
local function ProxyCatalog() return S.Data and S.Data.CombatSourceProxyCatalog or nil end

local A = {
    version = 7,
    modes = {},
    unclassified = nil,
    selfKey = nil,
    segment = nil,
    segments = {},
    segmentMax = 24,
    segmentIdleMs = 8000,
    pendingRows = {},
    pendingOrder = {},
    pendingHead = 1,
    pendingCount = 0,
    pendingMax = 512,
    pendingEvicted = 0,
    events = 0,
    damageEvents = 0,
    healEvents = 0,
    classified = { PVP = 0, PVE = 0, UNKNOWN = 0, HEAL = 0 },
    provisionalSeen = 0,
    replays = 0,
    replayUpgrades = 0,
    replayReclassifications = 0,
    droppedNoIdentity = 0,
    unknownRelations = 0,
    proxySourceHeals = 0,
    proxySourceHealAmount = 0,
    lastEventAt = 0,
    revision = 0,
}
F.Domain = A

A.Const = {
    MAX_RANKING_ROWS = 150,
    DEFAULT_DISPLAY_ROWS = 12,
    SEGMENT_IDLE_MS = 8000,
    MIN_EFFECTIVE_AMOUNT = 1,
    PROVISIONAL_MAX = 512,
    DETAIL_MAX_ABILITIES = 128,
    DETAIL_MAX_COUNTERPARTS = 256,
}

local MODES = { "PVP", "PVE" }
local SIDES = { friendly = "friendly", enemy = "enemy", unknown = "unknown" }

local function NewBucket()
    return { damage = 0, heal = 0, taken = 0, hits = 0, actors = {}, actorCount = 0, events = 0 }
end

local function NewMode(mode)
    return {
        mode = mode,
        friendly = NewBucket(),
        enemy = NewBucket(),
        unknown = NewBucket(),
        events = 0,
        startedAt = 0,
        lastEventAt = 0,
    }
end

local function EnsureMode(mode)
    if A.modes[mode] == nil then A.modes[mode] = NewMode(mode) end
    return A.modes[mode]
end

local function ResetBuckets()
    A.modes = {}
    for _, mode in ipairs(MODES) do EnsureMode(mode) end
    A.unclassified = NewBucket()
    -- 单凭友方治疗两端不能真实分到 PVP/PVE；保留一个共享账本，合并到任一模式投影，保证 PVP 治疗不丢失且不重复累加。
    A.healing = { friendly = NewBucket(), enemy = NewBucket(), unknown = NewBucket() }
end
ResetBuckets()

local function NormalizeActorName(value)
    local text = string.lower(Trim(value))
    if text == "" then return nil end
    -- 两个明确跨服身份不能合并角色。UnitIdentityV3 查询可将短 Name 与 Name@World 视作等价，但禁止合并 Name@WorldA 和 Name@WorldB。
    -- 短传输名保持独立保守 key，直至未来有已验证稳定 ID 别名层可安全迁移；宁可保留可能的短/全名重复，也不能牺牲准确性。
    return text
end

local function ActorKey(name)
    local key = NormalizeActorName(name)
    return key ~= nil and ("name:" .. key) or nil
end

local function TouchBucketActor(bucket, key, name)
    if bucket == nil or key == nil then return nil end
    local row = bucket.actors[key]
    if row == nil then
        row = {
            key = key, name = Trim(name), damage = 0, heal = 0, taken = 0,
            hits = 0, events = 0, firstAt = 0, lastAt = 0, activeMs = 1000, activityEvents = 0,
            abilityDetails = {}, abilityDetailCount = 0,
            counterpartDetails = {}, counterpartDetailCount = 0,
        }
        bucket.actors[key] = row
        bucket.actorCount = bucket.actorCount + 1
    else
        local nextName = Trim(name)
        if nextName ~= "" and (#nextName > #(tostring(row.name or "")) or row.name == "") then row.name = nextName end
    end
    return row
end

local function TrackActorActivity(actor, at)
    if type(actor) ~= "table" then return end
    at = tonumber(at) or NowMs()
    local count = math.max(0, tonumber(actor.activityEvents) or 0)
    if count <= 0 or (tonumber(actor.firstAt) or 0) <= 0 or (tonumber(actor.lastAt) or 0) <= 0 then
        actor.firstAt, actor.lastAt, actor.activeMs, actor.activityEvents = at, at, 1000, 1
        return
    end
    local firstAt, lastAt = tonumber(actor.firstAt) or at, tonumber(actor.lastAt) or at
    if at > lastAt then
        actor.activeMs = math.max(1000, (tonumber(actor.activeMs) or 1000) + math.min(at - lastAt, A.segmentIdleMs))
        actor.lastAt = at
    elseif at < firstAt then
        -- 重放可能在较新已确认行之后提交更早的暂定事实；仅扩展前边界，避免分类前修改时钟造成永久多计。窗口中段插入不增加时长。
        actor.activeMs = math.max(1000, (tonumber(actor.activeMs) or 1000) + math.min(firstAt - at, A.segmentIdleMs))
        actor.firstAt = at
    end
    actor.activityEvents = count + 1
end

local function DetailKey(value, fallback)
    local text = Trim(value)
    if text == "" then text = tostring(fallback or "其它") end
    return string.lower(text), text
end

local function TouchDetail(actor, mapField, countField, key, label, maximum, metadata)
    local map = actor[mapField]
    local row = map[key]
    if row ~= nil then
        if row.abilityId == nil and type(metadata) == "table" and tonumber(metadata.abilityId) ~= nil then row.abilityId = tonumber(metadata.abilityId) end
        return row, key
    end
    local count = tonumber(actor[countField]) or 0
    if count >= maximum then
        key, label = "__other__", "其它"
        row = map[key]
        if row ~= nil then return row, key end
    else
        actor[countField] = count + 1
    end
    row = { key = key, name = label, damage = 0, heal = 0, taken = 0, events = 0 }
    if type(metadata) == "table" and tonumber(metadata.abilityId) ~= nil and key ~= "__other__" then row.abilityId = tonumber(metadata.abilityId) end
    map[key] = row
    return row, key
end

local function AddDetail(actor, mapField, countField, value, fallback, field, amount, maximum)
    local key, label = DetailKey(value, fallback)
    local row, resolvedKey = TouchDetail(actor, mapField, countField, key, label, maximum)
    row[field] = (tonumber(row[field]) or 0) + amount
    row.events = (tonumber(row.events) or 0) + 1
    return {
        actor = actor, mapField = mapField, countField = countField,
        key = resolvedKey, field = field, amount = amount,
    }
end

-- 技能详情优先使用已核实战斗 skill ID；基础近战/环境事实不含真实技能 ID，RU MELEE_DAMAGE 用 rawAbilityId 表示伤害量，故名称仍作回退。
local function AddAbilityDetail(actor, abilityName, abilityId, field, amount)
    local id = tonumber(abilityId)
    if id ~= nil and id > 0 then id = math.floor(id + 0.5) else id = nil end
    local key, label
    if id ~= nil then
        key = "id:" .. tostring(id)
        label = Trim(abilityName)
        if label == "" then label = "技能 " .. tostring(id) end
    else
        key, label = DetailKey(abilityName, "普通攻击/未知技能")
    end
    local row, resolvedKey = TouchDetail(actor, "abilityDetails", "abilityDetailCount", key, label, A.Const.DETAIL_MAX_ABILITIES, { abilityId = id })
    row[field] = (tonumber(row[field]) or 0) + amount
    row.events = (tonumber(row.events) or 0) + 1
    return { actor = actor, mapField = "abilityDetails", countField = "abilityDetailCount", key = resolvedKey, field = field, amount = amount }
end

local function RemoveDetail(ref)
    if type(ref) ~= "table" or type(ref.actor) ~= "table" then return end
    local map = ref.actor[ref.mapField]
    local row = type(map) == "table" and map[ref.key] or nil
    if row == nil then return end
    local amount = math.max(0, tonumber(ref.amount) or 0)
    row[ref.field] = math.max(0, (tonumber(row[ref.field]) or 0) - amount)
    row.events = math.max(0, (tonumber(row.events) or 0) - 1)
    if (tonumber(row.damage) or 0) <= 0 and (tonumber(row.heal) or 0) <= 0 and (tonumber(row.taken) or 0) <= 0 then
        map[ref.key] = nil
        if ref.key ~= "__other__" and ref.countField ~= nil then
            ref.actor[ref.countField] = math.max(0, (tonumber(ref.actor[ref.countField]) or 0) - 1)
        end
    end
end

local function IsKnownNonPlayer(kind)
    kind = tostring(kind or "")
    return kind == "NPC" or kind == "MATE" or kind == "SLAVE" or kind == "OTHER"
end

local function IsFriendlyRelation(value)
    return value == "SELF" or value == "TEAM" or value == "FRIENDLY"
end

local function SideFor(relation)
    if IsFriendlyRelation(relation) then return SIDES.friendly end
    if relation == "OPPONENT" then return SIDES.enemy end
    return nil
end

local function OppositeSide(side)
    if side == SIDES.friendly then return SIDES.enemy end
    if side == SIDES.enemy then return SIDES.friendly end
    return nil
end

local function ResolveSides(sourceRel, targetRel, category)
    local sourceSide, targetSide = SideFor(sourceRel), SideFor(targetRel)
    local isHeal = tostring(category or "") == "heal"

    if isHeal then
        -- ArcheRage 治疗是同阵营证据；任一端已有阵营时，另一端归同阵营。此捷径仅限治疗；用于伤害会让 OPPONENT 攻击无关 NPC 时制造虚假友方，污染承伤/排行。
        if sourceSide == nil and targetSide ~= nil then sourceSide = targetSide end
        if targetSide == nil and sourceSide ~= nil then targetSide = sourceSide end
        return sourceSide or SIDES.unknown, targetSide or SIDES.unknown
    end

    -- 伤害仅可从可信本地团队锚点推断相反阵营：SELF/TEAM 由 UnitIdentity/TeamRoster 核实，FRIENDLY/OPPONENT 为推断关系，禁止递归推断第三单位。
    -- EnemyPlayer(OPPONENT)→NeutralNpc(UNKNOWN) 必须保持 enemy→unknown，不能变 enemy→friendly。
    if sourceSide == nil and (targetRel == "SELF" or targetRel == "TEAM") then
        sourceSide = SIDES.enemy
    end
    if targetSide == nil and (sourceRel == "SELF" or sourceRel == "TEAM") then
        targetSide = SIDES.enemy
    end
    return sourceSide or SIDES.unknown, targetSide or SIDES.unknown
end

-- 返回 mode、reason、provisional；provisional 行立即展示，同时保留到明确 kind 证据出现后重放。
local function ResolveEventMode(fact, sourceRel, targetRel, sourceKind, targetKind)
    if fact.environmental == true then return "PVE", "ENVIRONMENT", false end
    local category = tostring(fact.category or "")
    if category == "heal" then return "HEAL", "HEAL_SHARED", false end

    if sourceKind == "PLAYER" and targetKind == "PLAYER" then return "PVP", "KIND_PLAYER_PAIR", false end
    if sourceKind == "PLAYER" and IsKnownNonPlayer(targetKind) then return "PVE", "KIND_PLAYER_TO_NONPLAYER", false end
    if IsKnownNonPlayer(sourceKind) and targetKind == "PLAYER" then return "PVE", "KIND_NONPLAYER_TO_PLAYER", false end
    if IsKnownNonPlayer(sourceKind) and IsKnownNonPlayer(targetKind) then return "PVE", "KIND_NONPLAYER_PAIR", false end

    if targetKind ~= "PLAYER" and type(F.IsBossName) == "function" and F:IsBossName(fact.targetName) == true then
        return "PVE", "MANUAL_BOSS_TARGET", targetKind == nil
    end
    if sourceKind ~= "PLAYER" and type(F.IsBossName) == "function" and F:IsBossName(fact.sourceName) == true then
        return "PVE", "MANUAL_BOSS_SOURCE", sourceKind == nil
    end

    local sourceFriendly, targetFriendly = IsFriendlyRelation(sourceRel), IsFriendlyRelation(targetRel)
    if sourceFriendly ~= targetFriendly then
        -- b 可能为 nil 时，Lua a and b or c 不是安全三元式；必须明确使用目标端点，避免 SELF→未知目标回退 sourceKind=PLAYER，把首次 NPC 命中误判 PVP。
        local otherKind = nil
        if sourceFriendly then otherKind = targetKind else otherKind = sourceKind end
        if IsKnownNonPlayer(otherKind) then return "PVE", "RELATION_ANCHORED_NONPLAYER", false end
        if otherKind == "PLAYER" then return "PVP", "RELATION_ANCHORED_PLAYER", false end

        -- SELF/TEAM 输出命中保持立即暂定 PVE 体验且可重放；未知 kind 的承伤来源可能为 NPC 或玩家，禁止猜测。
        if (sourceRel == "SELF" or sourceRel == "TEAM") and targetKind == nil then
            return "PVE", "SELF_TEAM_OUTGOING_PROVISIONAL_PVE", true
        end
        return "UNKNOWN", "ENDPOINT_KIND_PENDING", false
    end

    if sourceRel == "UNKNOWN" and targetRel == "UNKNOWN" then return "UNKNOWN", "RELATION_UNKNOWN", false end
    return "UNKNOWN", "SAME_SIDE_OR_AMBIGUOUS", false
end

local function AddContribution(bucket, key, name, field, amount, at, abilityName, abilityId, counterpartName, trackActivity)
    local actor = TouchBucketActor(bucket, key, name)
    if actor == nil then return nil end
    if trackActivity == true then TrackActorActivity(actor, at) end
    actor[field] = (tonumber(actor[field]) or 0) + amount
    actor.events = actor.events + 1
    if field == "damage" then actor.hits = actor.hits + 1; bucket.hits = bucket.hits + 1 end
    bucket[field] = (tonumber(bucket[field]) or 0) + amount
    bucket.events = bucket.events + 1
    local detailRefs = {
        AddAbilityDetail(actor, abilityName, abilityId, field, amount),
        AddDetail(actor, "counterpartDetails", "counterpartDetailCount", counterpartName, "未知单位", field, amount, A.Const.DETAIL_MAX_COUNTERPARTS),
    }
    return { bucket = bucket, key = key, field = field, amount = amount, hit = field == "damage", detailRefs = detailRefs }
end

local function RemoveContribution(c)
    if type(c) ~= "table" or type(c.bucket) ~= "table" then return end
    local bucket = c.bucket
    local actor = bucket.actors[c.key]
    local amount = math.max(0, tonumber(c.amount) or 0)
    if type(c.detailRefs) == "table" then
        for _, ref in ipairs(c.detailRefs) do RemoveDetail(ref) end
    end
    if actor ~= nil then
        actor[c.field] = math.max(0, (tonumber(actor[c.field]) or 0) - amount)
        actor.events = math.max(0, (tonumber(actor.events) or 0) - 1)
        if c.hit == true then actor.hits = math.max(0, (tonumber(actor.hits) or 0) - 1) end
        if (tonumber(actor.damage) or 0) <= 0 and (tonumber(actor.heal) or 0) <= 0 and (tonumber(actor.taken) or 0) <= 0 then
            bucket.actors[c.key] = nil
            bucket.actorCount = math.max(0, (tonumber(bucket.actorCount) or 0) - 1)
        end
    end
    bucket[c.field] = math.max(0, (tonumber(bucket[c.field]) or 0) - amount)
    bucket.events = math.max(0, (tonumber(bucket.events) or 0) - 1)
    if c.hit == true then bucket.hits = math.max(0, (tonumber(bucket.hits) or 0) - 1) end
end

local function ClearApplied(row)
    if type(row.appliedContributions) == "table" then
        for _, c in ipairs(row.appliedContributions) do RemoveContribution(c) end
    end
    if row.appliedMode == "PVP" or row.appliedMode == "PVE" then
        A.classified[row.appliedMode] = math.max(0, (tonumber(A.classified[row.appliedMode]) or 0) - 1)
        local mode = EnsureMode(row.appliedMode)
        mode.events = math.max(0, (tonumber(mode.events) or 0) - 1)
    elseif row.appliedMode == "HEAL" then
        A.classified.HEAL = math.max(0, (tonumber(A.classified.HEAL) or 0) - 1)
    elseif row.appliedMode == "UNKNOWN" then
        A.classified.UNKNOWN = math.max(0, (tonumber(A.classified.UNKNOWN) or 0) - 1)
    end
    row.appliedContributions = nil
    row.appliedMode = nil
    row.activityCommitted = false
    row.appliedSourceSide, row.appliedTargetSide = nil, nil
end

local function AddSourceTargetContributions(row, sourceBucket, targetBucket, trackActivity)
    local out = {}
    local sourceKey, targetKey = ActorKey(row.sourceName), ActorKey(row.targetName)
    local analytics = S.Services and S.Services.CombatAnalyticsV3
    if analytics and type(analytics.GetCollectionScope) == "function" and analytics:GetCollectionScope() == "self" then
        if analytics:IsSelfActor(row.sourceName) ~= true then sourceKey = nil end
        if analytics:IsSelfActor(row.targetName) ~= true then targetKey = nil end
    end
    if row.category == "damage" then
        if sourceKey ~= nil then
            out[#out + 1] = AddContribution(sourceBucket, sourceKey, row.sourceName, "damage", row.amount, row.at, row.abilityName, row.abilityId, row.targetName, trackActivity)
        end
        if targetKey ~= nil then
            out[#out + 1] = AddContribution(targetBucket, targetKey, row.targetName, "taken", row.amount, row.at, row.abilityName, row.abilityId, row.sourceName, trackActivity)
        end
    elseif row.category == "heal" then
        if sourceKey ~= nil then
            out[#out + 1] = AddContribution(sourceBucket, sourceKey, row.sourceName, "heal", row.amount, row.at, row.abilityName, row.abilityId, row.targetName, trackActivity)
        end
    end
    return out
end

function A:ApplyResolved(row, mode, modeReason, provisional)
    ClearApplied(row)
    local m = EnsureMode(mode)
    local sourceSide, targetSide = ResolveSides(row.sourceRel, row.targetRel, row.category)
    local activityCommitted = provisional ~= true and sourceSide ~= SIDES.unknown and targetSide ~= SIDES.unknown
    row.appliedSourceSide, row.appliedTargetSide = sourceSide, targetSide
    row.appliedContributions = AddSourceTargetContributions(row, m[sourceSide], m[targetSide], activityCommitted)
    row.appliedMode = mode
    row.modeReason = modeReason
    row.provisional = provisional == true
    row.activityCommitted = activityCommitted
    m.events = m.events + 1
    if activityCommitted then
        if m.startedAt == 0 or row.at < m.startedAt then m.startedAt = row.at end
        if row.at > m.lastEventAt then m.lastEventAt = row.at end
    end
    self.classified[mode] = (tonumber(self.classified[mode]) or 0) + 1
    return true
end

function A:ApplySharedHeal(row, reason)
    ClearApplied(row)
    local sourceSide, targetSide = ResolveSides(row.sourceRel, row.targetRel, "heal")
    local activityCommitted = sourceSide ~= SIDES.unknown and targetSide ~= SIDES.unknown
    row.appliedSourceSide, row.appliedTargetSide = sourceSide, targetSide
    row.appliedContributions = AddSourceTargetContributions(row, self.healing[sourceSide], self.healing[targetSide], activityCommitted)
    row.appliedMode = "HEAL"
    row.activityCommitted = activityCommitted
    row.modeReason = tostring(reason or "HEAL_SHARED")
    row.provisional = false
    self.classified.HEAL = (tonumber(self.classified.HEAL) or 0) + 1
    return true
end

function A:ApplyUnclassified(row, reason)
    ClearApplied(row)
    row.appliedContributions = AddSourceTargetContributions(row, self.unclassified, self.unclassified, false)
    row.appliedMode = "UNKNOWN"
    row.activityCommitted = false
    row.modeReason = reason
    row.provisional = false
    self.classified.UNKNOWN = (tonumber(self.classified.UNKNOWN) or 0) + 1
    return true
end

local function CompactPendingOrder(force)
    if force ~= true and A.pendingHead <= 256 and A.pendingHead <= (#A.pendingOrder / 2) then return end
    local compact = {}
    for index = A.pendingHead, #A.pendingOrder do
        local key = A.pendingOrder[index]
        if key ~= nil and A.pendingRows[key] ~= nil then compact[#compact + 1] = key end
    end
    A.pendingOrder, A.pendingHead = compact, 1
end

local function RemovePending(key)
    local row = key ~= nil and A.pendingRows[key] or nil
    if row == nil then return false end
    A.pendingRows[key] = nil
    row.pending = false
    A.pendingCount = math.max(0, (tonumber(A.pendingCount) or 0) - 1)
    while A.pendingHead <= #A.pendingOrder and A.pendingRows[A.pendingOrder[A.pendingHead]] == nil do
        A.pendingHead = A.pendingHead + 1
    end
    CompactPendingOrder(false)
    return true
end

local function EvictOldestPending()
    while A.pendingHead <= #A.pendingOrder do
        local key = A.pendingOrder[A.pendingHead]
        A.pendingHead = A.pendingHead + 1
        if key ~= nil and A.pendingRows[key] ~= nil then
            local victim = A.pendingRows[key]
            A.pendingRows[key] = nil
            victim.pending = false
            A.pendingCount = math.max(0, (tonumber(A.pendingCount) or 0) - 1)
            A.pendingEvicted = A.pendingEvicted + 1
            CompactPendingOrder(false)
            return true
        end
    end
    CompactPendingOrder(true)
    return false
end

local function QueuePending(row)
    if row.pending == true then return end
    while (tonumber(A.pendingCount) or 0) >= A.pendingMax do
        if EvictOldestPending() ~= true then break end
    end
    local key = tostring(row.eventKey)
    row.pending = true
    A.pendingRows[key] = row
    A.pendingOrder[#A.pendingOrder + 1] = key
    A.pendingCount = (tonumber(A.pendingCount) or 0) + 1
    CompactPendingOrder(false)
end

local function RefreshRowEvidence(row)
    local relation = Relation()
    if relation == nil then return false end
    local now = NowMs()
    if row.sourceName ~= "" and type(relation.GetRelationAt) == "function" then row.sourceRel = relation:GetRelationAt(row.sourceName, now) end
    if row.targetName ~= "" and type(relation.GetRelationAt) == "function" then row.targetRel = relation:GetRelationAt(row.targetName, now) end
    if type(relation.GetUnit) == "function" then
        local src = row.sourceName ~= "" and relation:GetUnit(row.sourceName) or nil
        local tgt = row.targetName ~= "" and relation:GetUnit(row.targetName) or nil
        row.sourceKind = (src ~= nil and src.kind ~= nil and src.kind ~= "") and src.kind or row.sourceKind
        row.targetKind = (tgt ~= nil and tgt.kind ~= nil and tgt.kind ~= "") and tgt.kind or row.targetKind
    end
    return true
end

-- 安全点重放由 Feature 通过统一 Scheduler 调度，禁止在 Native COMBAT_MSG 调用栈执行。
function A:ReplayPending(reason)
    local replayed, upgraded, reclassified = 0, 0, 0
    local keys = {}
    for index = self.pendingHead, #self.pendingOrder do keys[#keys + 1] = self.pendingOrder[index] end
    for _, key in ipairs(keys) do
        local row = self.pendingRows[key]
        if row ~= nil then
            replayed = replayed + 1
            local oldMode = row.appliedMode
            RefreshRowEvidence(row)
            local sourceSide, targetSide = ResolveSides(row.sourceRel, row.targetRel, row.category)
            if row.category == "heal" then
                local changed = oldMode ~= "HEAL" or row.appliedSourceSide ~= sourceSide
                    or row.appliedTargetSide ~= targetSide
                if changed then
                    self:ApplySharedHeal(row, "HEAL_SHARED_REPLAY")
                    reclassified = reclassified + 1
                end
                if sourceSide ~= SIDES.unknown then RemovePending(key) end
            else
                local mode, modeReason, provisional = ResolveEventMode(row, row.sourceRel, row.targetRel, row.sourceKind, row.targetKind)
                local sidePending = sourceSide == SIDES.unknown or targetSide == SIDES.unknown
                if mode == "UNKNOWN" then
                    if oldMode ~= "UNKNOWN" then self:ApplyUnclassified(row, modeReason); reclassified = reclassified + 1 end
                else
                    local changed = oldMode ~= mode or row.modeReason ~= modeReason
                        or row.appliedSourceSide ~= sourceSide or row.appliedTargetSide ~= targetSide
                    if changed then
                        self:ApplyResolved(row, mode, modeReason, provisional)
                        if oldMode == "UNKNOWN" then upgraded = upgraded + 1 else reclassified = reclassified + 1 end
                    end
                end
                if provisional ~= true and mode ~= "UNKNOWN" and sidePending ~= true then RemovePending(key) end
            end
        end
    end
    CompactPendingOrder(false)
    self.replays = self.replays + replayed
    self.replayUpgrades = self.replayUpgrades + upgraded
    self.replayReclassifications = self.replayReclassifications + reclassified
    if replayed > 0 then self.revision = self.revision + 1 end
    return true, replayed, upgraded, reclassified
end

function A:CloseSegment(at, reason)
    local segment = self.segment
    self.segment = nil
    if segment == nil then return true end
    segment.endedAt = tonumber(at) or NowMs()
    segment.durationMs = math.max(0, segment.endedAt - segment.startedAt)
    segment.reason = tostring(reason or "idle")
    self.segments[#self.segments + 1] = segment
    while #self.segments > self.segmentMax do table.remove(self.segments, 1) end
    return true
end

function A:TouchSegment(at, category, amount)
    at = tonumber(at) or NowMs()
    if self.segment ~= nil and at - (tonumber(self.segment.lastEventAt) or at) > self.segmentIdleMs then
        self:CloseSegment(self.segment.lastEventAt, "idle_gap")
    end
    if self.segment == nil then self.segment = { startedAt = at, lastEventAt = at, events = 0, damage = 0, heal = 0 } end
    self.segment.lastEventAt = at
    self.segment.events = self.segment.events + 1
    if category == "damage" then self.segment.damage = self.segment.damage + amount else self.segment.heal = self.segment.heal + amount end
    return self.segment
end

-- Native 战斗回调入口返回元数据，Feature 获得新 kind 证据时可在 Native 调用栈外安排重放。
function A:OnCombatFact(fact)
    if F.enabled ~= true or type(fact) ~= "table" then return false end
    local category = tostring(fact.category or "")
    if category ~= "damage" and category ~= "heal" then return false end
    local amount = tonumber(fact.amount) or 0
    if amount < A.Const.MIN_EFFECTIVE_AMOUNT then return false end

    local at = tonumber(fact.receivedAt) or NowMs()
    local sourceName, targetName = Trim(fact.sourceName), Trim(fact.targetName)
    if sourceName == "" and targetName == "" then self.droppedNoIdentity = self.droppedNoIdentity + 1; return false end

    local proxyCatalog = ProxyCatalog()
    local proxySpec = category == "heal" and type(proxyCatalog) == "table" and type(proxyCatalog.ResolveSource) == "function"
        and proxyCatalog:ResolveSource(sourceName, category) or nil
    if proxySpec ~= nil then
        -- 放置技能对象不是角色；当前 RU API 无可靠通用所有者关联，禁止把治疗归给猜测/最近施法者。以明确未归属的技能代理治疗保留数值，不给 CombatRelation 注入代理实体关系。
        self.events = self.events + 1
        self.healEvents = self.healEvents + 1
        self.classified.HEAL = (tonumber(self.classified.HEAL) or 0) + 1
        self.proxySourceHeals = self.proxySourceHeals + 1
        self.proxySourceHealAmount = self.proxySourceHealAmount + amount
        self.lastEventAt = at
        self:TouchSegment(at, category, amount)
        self.revision = self.revision + 1
        return true, { replaySuggested = false, provisional = false, mode = "HEAL", proxySource = true, proxyFamily = tostring(proxySpec.id or "") }
    end

    local relation = Relation()
    local sourceRel, targetRel = "UNKNOWN", "UNKNOWN"
    local sourceKind, targetKind = fact.sourceKind, fact.targetKind
    local evidenceChanged = false

    if relation ~= nil then
        if sourceName ~= "" and sourceKind ~= nil and type(relation.ApplyKind) == "function" then
            local ok, _, changed = relation:ApplyKind(sourceName, sourceKind, at)
            evidenceChanged = evidenceChanged or (ok == true and changed == true)
        end
        if targetName ~= "" and targetKind ~= nil and type(relation.ApplyKind) == "function" then
            local ok, _, changed = relation:ApplyKind(targetName, targetKind, at)
            evidenceChanged = evidenceChanged or (ok == true and changed == true)
        end

        local ok, r1, r2 = pcall(function() return relation:RecordCombatFact(fact) end)
        if ok == true and r1 == true and type(r2) == "table" then
            sourceRel = tostring(r2.sourceRelation or "UNKNOWN")
            targetRel = tostring(r2.targetRelation or "UNKNOWN")
            evidenceChanged = evidenceChanged or r2.relationChanged == true
        else
            self.droppedNoIdentity = self.droppedNoIdentity + 1
            if type(relation.GetRelationAt) == "function" then
                if sourceName ~= "" then sourceRel = relation:GetRelationAt(sourceName, at) end
                if targetName ~= "" then targetRel = relation:GetRelationAt(targetName, at) end
            end
        end
        if type(relation.GetUnit) == "function" then
            local src = sourceName ~= "" and relation:GetUnit(sourceName) or nil
            local tgt = targetName ~= "" and relation:GetUnit(targetName) or nil
            sourceKind = (src ~= nil and src.kind ~= nil and src.kind ~= "") and src.kind or sourceKind
            targetKind = (tgt ~= nil and tgt.kind ~= nil and tgt.kind ~= "") and tgt.kind or targetKind
        end
    end

    if sourceRel == "UNKNOWN" and targetRel == "UNKNOWN" then self.unknownRelations = self.unknownRelations + 1 end

    local sourceKey, targetKey = ActorKey(sourceName), ActorKey(targetName)
    if sourceRel == "SELF" and sourceKey ~= nil then self.selfKey = sourceKey end
    if targetRel == "SELF" and targetKey ~= nil then self.selfKey = targetKey end

    self.events = self.events + 1
    if category == "damage" then self.damageEvents = self.damageEvents + 1 else self.healEvents = self.healEvents + 1 end
    self.lastEventAt = at
    self:TouchSegment(at, category, amount)

    local mode, modeReason, provisional = ResolveEventMode(fact, sourceRel, targetRel, sourceKind, targetKind)
    local row = {
        eventKey = tostring(fact.sequence or self.events) .. ":" .. tostring(at) .. ":" .. tostring(sourceKey or targetKey or "?"),
        -- CombatFact 为借用且不可变；禁止回调结束后持有，只复制 DPS Domain 拥有的重放/详情字段。
        environmental = fact.environmental == true,
        abilityName = Trim(fact.abilityName),
        -- RU MELEE_DAMAGE 的 rawAbilityId 表示伤害量；仅 spell/heal 事实可将它提升为真实技能身份。
        abilityId = ((tostring(fact.kind or "") == "spell_damage" or tostring(fact.kind or "") == "heal")
            and tonumber(fact.rawAbilityId) ~= nil and tonumber(fact.rawAbilityId) > 0)
            and math.floor(tonumber(fact.rawAbilityId) + 0.5) or nil,
        at = at,
        category = category,
        amount = amount,
        sourceName = sourceName,
        targetName = targetName,
        sourceRel = sourceRel,
        targetRel = targetRel,
        sourceKind = sourceKind,
        targetKind = targetKind,
        modeReason = modeReason,
    }

    if category == "heal" then
        self:ApplySharedHeal(row, modeReason)
        local sourceSide = ResolveSides(sourceRel, targetRel, category)
        if sourceSide == SIDES.unknown then QueuePending(row) end
    elseif mode == "UNKNOWN" then
        self:ApplyUnclassified(row, modeReason)
        QueuePending(row)
    else
        self:ApplyResolved(row, mode, modeReason, provisional)
        local sourceSide, targetSide = ResolveSides(sourceRel, targetRel, category)
        local sidePending = sourceSide == SIDES.unknown or targetSide == SIDES.unknown
        if provisional == true then self.provisionalSeen = self.provisionalSeen + 1 end
        if provisional == true or sidePending == true then QueuePending(row) end
    end

    self.revision = self.revision + 1
    return true, { replaySuggested = evidenceChanged == true and next(self.pendingRows) ~= nil, provisional = provisional == true, mode = mode }
end

function A:ClearStats(reason)
    ResetBuckets()
    self.selfKey = nil
    self.segments, self.segment = {}, nil
    self.pendingRows, self.pendingOrder, self.pendingHead, self.pendingCount = {}, {}, 1, 0
    self.pendingEvicted = 0
    self.events, self.damageEvents, self.healEvents = 0, 0, 0
    self.classified = { PVP = 0, PVE = 0, UNKNOWN = 0, HEAL = 0 }
    self.provisionalSeen, self.replays, self.replayUpgrades, self.replayReclassifications = 0, 0, 0, 0
    self.droppedNoIdentity, self.unknownRelations, self.lastEventAt = 0, 0, 0
    self.proxySourceHeals, self.proxySourceHealAmount = 0, 0
    self.revision = self.revision + 1
    return true
end

function A:ResetTransient(reason)
    -- 停止运行仅释放 replay/segment 状态；用户显式 Clear 前保留会话统计，Enabled 与 Stats 为独立权威。pending 行已贡献可见总量。
    for key, row in pairs(self.pendingRows) do if row ~= nil then row.pending = false end; self.pendingRows[key] = nil end
    self.pendingOrder, self.pendingHead, self.pendingCount = {}, 1, 0
    self:CloseSegment(self.lastEventAt > 0 and self.lastEventAt or NowMs(), reason or "transient_reset")
    self.revision = self.revision + 1
    return true
end

local function NormalizeMetric(value)
    value = tostring(value or "damage")
    if value ~= "damage" and value ~= "taken" and value ~= "heal" then value = "damage" end
    return value
end

local function ProjectBucket(bucket, sharedHealBucket, limit, alwaysShowSelf, metric, includeZero)
    metric = NormalizeMetric(metric)
    bucket = type(bucket) == "table" and bucket or NewBucket()
    sharedHealBucket = type(sharedHealBucket) == "table" and sharedHealBucket or nil

    local merged, actorCount = {}, 0
    local function TouchMerged(key, name)
        if key == nil then return nil end
        local row = merged[key]
        if row == nil then
            row = {
                key = key, name = tostring(name or key), damage = 0, heal = 0, taken = 0, hits = 0, events = 0,
                damageActiveMs = 1000, healActiveMs = 1000,
            }
            merged[key] = row
            actorCount = actorCount + 1
        else
            local nextName = tostring(name or "")
            if nextName ~= "" and #nextName > #(tostring(row.name or "")) then row.name = nextName end
        end
        return row
    end

    for key, source in pairs(bucket.actors or {}) do
        local row = TouchMerged(key, source.name)
        row.damage = math.max(0, tonumber(source.damage) or 0)
        row.taken = math.max(0, tonumber(source.taken) or 0)
        row.heal = math.max(0, tonumber(source.heal) or 0)
        row.hits = math.max(0, tonumber(source.hits) or 0)
        row.events = math.max(0, tonumber(source.events) or 0)
        row.damageActiveMs = math.max(1000, tonumber(source.activeMs) or 1000)
        if row.heal > 0 then row.healActiveMs = math.max(1000, tonumber(source.activeMs) or 1000) end
    end
    if sharedHealBucket ~= nil then
        for key, source in pairs(sharedHealBucket.actors or {}) do
            local row = TouchMerged(key, source.name)
            row.heal = row.heal + math.max(0, tonumber(source.heal) or 0)
            row.events = row.events + math.max(0, tonumber(source.events) or 0)
            row.healActiveMs = math.max(1000, tonumber(source.activeMs) or 1000)
        end
    end

    local rows = {}
    for _, row in pairs(merged) do
        if includeZero==true or (tonumber(row[metric]) or 0) > 0 then rows[#rows + 1] = row end
    end
    table.sort(rows, function(a, b)
        local av, bv = tonumber(a[metric]) or 0, tonumber(b[metric]) or 0
        if av ~= bv then return av > bv end
        local atotal = (tonumber(a.damage) or 0) + (tonumber(a.heal) or 0) + (tonumber(a.taken) or 0)
        local btotal = (tonumber(b.damage) or 0) + (tonumber(b.heal) or 0) + (tonumber(b.taken) or 0)
        if atotal ~= btotal then return atotal > btotal end
        return tostring(a.key or "") < tostring(b.key or "")
    end)
    for index, row in ipairs(rows) do row.rank = index end
    local totalRows = #rows
    while #rows > limit do table.remove(rows) end

    if alwaysShowSelf == true and A.selfKey ~= nil and merged[A.selfKey] ~= nil then
        local found = false
        for _, row in ipairs(rows) do if row.key == A.selfKey then found = true; break end end
        if found ~= true then
            table.insert(rows, 1, merged[A.selfKey])
            while #rows > limit do table.remove(rows) end
        end
    end

    local projected = {}
    for _, row in ipairs(rows) do
        local damageActiveMs = math.max(1000, tonumber(row.damageActiveMs) or 1000)
        local healActiveMs = math.max(1000, tonumber(row.healActiveMs) or 1000)
        projected[#projected + 1] = {
            rank = tonumber(row.rank) or 0,
            key = row.key,
            name = tostring(row.name or row.key),
            damage = math.max(0, tonumber(row.damage) or 0),
            heal = math.max(0, tonumber(row.heal) or 0),
            taken = math.max(0, tonumber(row.taken) or 0),
            hits = math.max(0, tonumber(row.hits) or 0),
            events = math.max(0, tonumber(row.events) or 0),
            dps = math.floor(((tonumber(row.damage) or 0) / (damageActiveMs / 1000)) + 0.5),
            hps = math.floor(((tonumber(row.heal) or 0) / (healActiveMs / 1000)) + 0.5),
            self = row.key ~= nil and row.key == A.selfKey or false,
            activeMs = metric == "heal" and healActiveMs or damageActiveMs,
            metric = metric,
            metricValue = math.max(0, tonumber(row[metric]) or 0),
        }
    end

    return {
        rows = projected,
        totals = {
            damage = math.max(0, tonumber(bucket.damage) or 0),
            heal = math.max(0, tonumber(bucket.heal) or 0) + (sharedHealBucket ~= nil and math.max(0, tonumber(sharedHealBucket.heal) or 0) or 0),
            taken = math.max(0, tonumber(bucket.taken) or 0),
            events = math.max(0, tonumber(bucket.events) or 0) + (sharedHealBucket ~= nil and math.max(0, tonumber(sharedHealBucket.events) or 0) or 0),
            actorCount = actorCount,
        },
        metric = metric,
        truncated = totalRows > limit,
        totalRows = totalRows,
    }
end

local function DetailRows(map, metric, limit)
    local rows = {}
    metric = NormalizeMetric(metric)
    for _, row in pairs(type(map) == "table" and map or {}) do
        local amount = math.max(0, tonumber(row[metric]) or 0)
        if amount > 0 then
            rows[#rows + 1] = { key = row.key, name = row.name, abilityId = tonumber(row.abilityId), amount = amount, events = math.max(0, tonumber(row.events) or 0) }
        end
    end
    table.sort(rows, function(a, b)
        if a.amount ~= b.amount then return a.amount > b.amount end
        return tostring(a.name or a.key or "") < tostring(b.name or b.key or "")
    end)
    local totalRows = #rows
    while #rows > limit do table.remove(rows) end
    for index, row in ipairs(rows) do row.rank = index end
    return rows, totalRows
end

function A:GetActorDetail(request)
    request = type(request) == "table" and request or {}
    local modeName = tostring(request.mode or "PVE")
    if modeName ~= "PVP" and modeName ~= "PVE" then modeName = "PVE" end
    local sideName = tostring(request.side or "friendly")
    if sideName ~= "friendly" and sideName ~= "enemy" and sideName ~= "unknown" then sideName = "friendly" end
    local metric = NormalizeMetric(request.metric)
    local actorKey = tostring(request.actorKey or "")
    local limit = math.max(1, math.min(100, math.floor(tonumber(request.limit) or 24)))
    if actorKey == "" then return { actor = nil, abilities = {}, counterparts = {}, metric = metric, revision = self.revision } end
    local bucket = EnsureMode(modeName)[sideName]
    local primary = bucket.actors[actorKey]
    local healBucket = self.healing and self.healing[sideName] or nil
    local healing = healBucket and healBucket.actors[actorKey] or nil
    if primary == nil and healing == nil then
        return { actor = nil, abilities = {}, counterparts = {}, metric = metric, revision = self.revision }
    end
    local detailSource = metric == "heal" and healing or primary
    local abilities, abilityTotal = DetailRows(detailSource and detailSource.abilityDetails or nil, metric, limit)
    local counterparts, counterpartTotal = DetailRows(detailSource and detailSource.counterpartDetails or nil, metric, limit)
    return {
        actor = {
            key = actorKey,
            name = tostring((primary and primary.name) or (healing and healing.name) or actorKey),
            damage = primary and primary.damage or 0,
            heal = (primary and primary.heal or 0) + (healing and healing.heal or 0),
            taken = primary and primary.taken or 0,
            hits = primary and primary.hits or 0,
        },
        abilities = abilities, abilityTotal = abilityTotal,
        counterparts = counterparts, counterpartTotal = counterpartTotal,
        metric = metric, revision = self.revision, mode = modeName, side = sideName,
    }
end

function A:GetProjection(request)
    request = type(request) == "table" and request or {}
    local settings = F:GetSettings()
    -- 总览读取有界候选集后统一排序，不把零伤害治疗者或仅承伤单位提前筛掉。
    local maxRows=request.overview==true and 512 or A.Const.MAX_RANKING_ROWS
    local limit = math.max(1, math.min(maxRows,
        math.floor(tonumber(request.displayRows) or tonumber(settings.displayRows) or A.Const.DEFAULT_DISPLAY_ROWS)))
    local modeName = tostring(request.mode or settings.mode or "PVE")
    if modeName ~= "PVP" and modeName ~= "PVE" then modeName = "PVE" end
    local sideName = tostring(request.side or settings.side or "friendly")
    if sideName ~= "friendly" and sideName ~= "enemy" and sideName ~= "unknown" then sideName = "friendly" end
    local metric = NormalizeMetric(request.metric or settings.metric)

    local m = EnsureMode(modeName)
    local friendly = ProjectBucket(m.friendly, self.healing.friendly, limit, settings.alwaysShowSelf == true, metric, request.includeZero)
    local enemy = ProjectBucket(m.enemy, self.healing.enemy, limit, false, metric, request.includeZero)
    local unknown = ProjectBucket(m.unknown, self.healing.unknown, limit, false, metric, request.includeZero)
    local unresolved = ProjectBucket(self.unclassified, nil, limit, false, metric)
    local selected = sideName == "enemy" and enemy or (sideName == "unknown" and unknown or friendly)
    local durationMs = m.startedAt > 0 and math.max(0, (tonumber(m.lastEventAt) or 0) - (tonumber(m.startedAt) or 0)) or 0

    return {
        revision = self.revision,
        mode = modeName,
        side = sideName,
        metric = metric,
        displayRows = limit,
        maxRankingRows = A.Const.MAX_RANKING_ROWS,
        rows = selected.rows,
        totals = selected.totals,
        truncated = selected.truncated,
        totalRows = selected.totalRows,
        durationMs = durationMs,
        sides = { friendly = friendly, enemy = enemy, unknown = unknown },
        unresolved = unresolved,
        modeEvents = tonumber(m.events) or 0,
    }
end

function A:GetHealth()
    local pending = tonumber(self.pendingCount) or 0
    local actors = 0
    for _, mode in pairs(self.modes) do
        actors = actors + (tonumber(mode.friendly.actorCount) or 0) + (tonumber(mode.enemy.actorCount) or 0) + (tonumber(mode.unknown.actorCount) or 0)
    end
    actors = actors + (tonumber(self.unclassified.actorCount) or 0)
    if type(self.healing) == "table" then
        actors = actors + (tonumber(self.healing.friendly.actorCount) or 0)
            + (tonumber(self.healing.enemy.actorCount) or 0) + (tonumber(self.healing.unknown.actorCount) or 0)
    end
    return {
        version = self.version,
        revision = self.revision,
        events = self.events,
        damageEvents = self.damageEvents,
        healEvents = self.healEvents,
        classifiedPVP = tonumber(self.classified.PVP) or 0,
        classifiedPVE = tonumber(self.classified.PVE) or 0,
        classifiedUnknown = tonumber(self.classified.UNKNOWN) or 0,
        classifiedHeal = tonumber(self.classified.HEAL) or 0,
        provisional = self.provisionalSeen,
        pendingRows = pending,
        pendingLedgerSlots = math.max(0, #self.pendingOrder - self.pendingHead + 1),
        pendingEvicted = self.pendingEvicted,
        replays = self.replays,
        replayUpgrades = self.replayUpgrades,
        replayReclassifications = self.replayReclassifications,
        droppedNoIdentity = self.droppedNoIdentity,
        unknownRelations = self.unknownRelations,
        unresolvedDamage = math.max(0, tonumber(self.unclassified.damage) or 0),
        unresolvedHeal = math.max(0, tonumber(self.unclassified.heal) or 0),
        sideUnknownHeal = self.healing and math.max(0, tonumber(self.healing.unknown.heal) or 0) or 0,
        proxySourceHeals = self.proxySourceHeals,
        proxySourceHealAmount = self.proxySourceHealAmount,
        unresolvedTaken = math.max(0, tonumber(self.unclassified.taken) or 0),
        actors = actors,
        segments = #self.segments + (self.segment ~= nil and 1 or 0),
    }
end
