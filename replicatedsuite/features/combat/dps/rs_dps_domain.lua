------------------------------------------------------------------------
-- Replicated Suite V3 - DPS Domain
--
-- Pure combat-statistics Domain. CombatEventBus owns native COMBAT_MSG;
-- CombatRelationV3 owns SELF/TEAM/FRIENDLY/OPPONENT facts; this Domain owns
-- per-event PVP/PVE classification, accumulation, replay and projections.
--
-- Hot-path constraints:
--   * no persistence / UI / native roster scan
--   * no Tick / OnUpdate
--   * no full pending scan from the combat callback
--   * display limits never cap accumulation
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
    -- Healing cannot be truthfully assigned to PVP/PVE from a friendly pair
    -- alone. Keep one shared ledger and merge it into either mode projection.
    -- This prevents PVP healing from disappearing without double-accumulating.
    A.healing = { friendly = NewBucket(), enemy = NewBucket(), unknown = NewBucket() }
end
ResetBuckets()

local function NormalizeActorName(value)
    local text = string.lower(Trim(value))
    if text == "" then return nil end
    -- Never collapse two explicit cross-world identities into the same actor.
    -- UnitIdentityV3 may consider short Name <-> Name@World equivalent for a
    -- lookup, but it explicitly forbids merging Name@WorldA with Name@WorldB.
    -- A short transport name therefore remains its own conservative key until a
    -- future verified stable-id alias layer can move it safely. Accuracy wins
    -- over cosmetically hiding a possible short/full duplicate.
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
        -- Replay can commit an older provisional fact after newer confirmed
        -- rows already exist. Extending only the leading edge is conservative
        -- and avoids the permanent over-count caused by mutating time before
        -- classification was final. Mid-window insertion needs no extra span.
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

-- A verified combat skill id is the preferred identity for ability drill-down.
-- Name remains the fallback because basic melee/environmental facts do not carry
-- a real skill id on ArcheRage RU (MELEE_DAMAGE reuses rawAbilityId as amount).
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
        -- ArcheRage healing is same-faction evidence. If either endpoint already
        -- has a side, project the other endpoint onto that same side. This is a
        -- deliberately heal-only rule; using the same shortcut for damage would
        -- let an OPPONENT attacking an unrelated NPC manufacture a fake friendly
        -- target and pollute friendly taken/rankings.
        if sourceSide == nil and targetSide ~= nil then sourceSide = targetSide end
        if targetSide == nil and sourceSide ~= nil then targetSide = sourceSide end
        return sourceSide or SIDES.unknown, targetSide or SIDES.unknown
    end

    -- Damage may infer an opposite side ONLY from a trusted local-team anchor.
    -- SELF/TEAM are verified by UnitIdentity/TeamRoster. FRIENDLY/OPPONENT are
    -- inferred combat relations and must not recursively infer a third unit.
    -- Example: EnemyPlayer(OPPONENT) -> NeutralNpc(UNKNOWN) must remain
    -- enemy -> unknown, never enemy -> friendly.
    if sourceSide == nil and (targetRel == "SELF" or targetRel == "TEAM") then
        sourceSide = SIDES.enemy
    end
    if targetSide == nil and (sourceRel == "SELF" or sourceRel == "TEAM") then
        targetSide = SIDES.enemy
    end
    return sourceSide or SIDES.unknown, targetSide or SIDES.unknown
end

-- Returns mode, reason, provisional. Provisional means the row is displayed now
-- but retained for replay when explicit kind evidence arrives.
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
        -- Lua's `a and b or c` is not a safe ternary when b can be nil.
        -- The old form turned SELF -> unknown target into sourceKind=PLAYER and
        -- misclassified the first NPC hit as PVP. Keep the endpoint explicit.
        local otherKind = nil
        if sourceFriendly then otherKind = targetKind else otherKind = sourceKind end
        if IsKnownNonPlayer(otherKind) then return "PVE", "RELATION_ANCHORED_NONPLAYER", false end
        if otherKind == "PLAYER" then return "PVP", "RELATION_ANCHORED_PLAYER", false end

        -- Preserve the legacy immediate PVE experience for SELF/TEAM outgoing
        -- hits, but keep the row replayable. Incoming unknown-kind traffic is not
        -- guessed because NPC and player attackers are both common.
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

-- Safe-point replay. The Feature schedules this with the unified Scheduler;
-- never call it from a native COMBAT_MSG stack.
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

-- Native combat callback entry. Returns metadata so the Feature can schedule a
-- replay outside the native stack when new kind evidence was learned.
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
        -- A placed skill object is not an Actor. The current RU API contract has
        -- no reliable generic owner link, so accuracy wins over assigning this
        -- heal to a guessed/latest caster. Keep the amount visible as explicitly
        -- unattributed skill-proxy healing and do not teach CombatRelation about
        -- the proxy entity.
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
        -- CombatFact is borrowed+immutable. Never retain it beyond this callback.
        -- Copy only replay/detail fields owned by the DPS Domain.
        environmental = fact.environmental == true,
        abilityName = Trim(fact.abilityName),
        -- On RU, MELEE_DAMAGE stores the damage amount in rawAbilityId. Only
        -- spell/heal facts may promote that field to a real skill identity.
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
    -- Runtime stop releases only replay/segment state. Session statistics remain
    -- visible until the user explicitly presses Clear; Enabled and Stats are
    -- separate authorities. Pending rows already contributed to visible totals.
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

local function ProjectBucket(bucket, sharedHealBucket, limit, alwaysShowSelf, metric)
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
        if (tonumber(row[metric]) or 0) > 0 then rows[#rows + 1] = row end
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
    local limit = math.max(1, math.min(A.Const.MAX_RANKING_ROWS,
        math.floor(tonumber(request.displayRows) or tonumber(settings.displayRows) or A.Const.DEFAULT_DISPLAY_ROWS)))
    local modeName = tostring(request.mode or settings.mode or "PVE")
    if modeName ~= "PVP" and modeName ~= "PVE" then modeName = "PVE" end
    local sideName = tostring(request.side or settings.side or "friendly")
    if sideName ~= "friendly" and sideName ~= "enemy" and sideName ~= "unknown" then sideName = "friendly" end
    local metric = NormalizeMetric(request.metric or settings.metric)

    local m = EnsureMode(modeName)
    local friendly = ProjectBucket(m.friendly, self.healing.friendly, limit, settings.alwaysShowSelf == true, metric)
    local enemy = ProjectBucket(m.enemy, self.healing.enemy, limit, false, metric)
    local unknown = ProjectBucket(m.unknown, self.healing.unknown, limit, false, metric)
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
