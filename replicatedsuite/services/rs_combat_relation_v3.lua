------------------------------------------------------------------------
-- Replicated Suite V3 - Combat Relation / Classification Facts
--
-- Independent relation Domain. It owns ONE question only: is a unit SELF,
-- TEAM, FRIENDLY, OPPONENT or UNKNOWN?
--
-- It deliberately does NOT own:
--   * identity facts        -> UnitIdentityV3 (names, explicit unit kind)
--   * aura/buff facts       -> AuraObservationV3
--   * combat occurrence     -> CombatEventBusV3
--   * DPS/HPS/ranking/PVP-PVE business conclusions -> DPS Domain
--
-- Design rules carried over from the legacy Professional DPS evidence:
--   * relation is resolved AT A TIMESTAMP (faction/team can change mid-fight)
--   * UNKNOWN is a first-class answer; the Domain never guesses
--   * manual user override outranks every inferred source
--   * "friendly attacked friendly" is recorded as a CONFLICT for review
--     (duel / force attack / faction change) instead of silently flipping
--   * soft evidence is forgettable; hard evidence keeps a timestamp
--
-- No Tick, no OnUpdate, no background scan. Consumer Demand owns the lifecycle
-- and all maps are bounded.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
S.Services = S.Services or {}

local R = {
    Id = "v3.combat_relation",
    version = 4,
    units = {},
    unitOrder = {},
    unitHead = 1,
    unitSerial = 0,
    unitMax = 512,
    manual = {},
    conflicts = {},
    conflictOrder = {},
    conflictHead = 1,
    conflictMax = 64,
    -- diagnostics
    reads = 0,
    binds = 0,
    evidenceApplied = 0,
    evidenceRejected = 0,
    conflictsRecorded = 0,
    manualOverrides = 0,
    provisionalDowngrades = 0,
    rosterHeld = false,
    rosterSubscribed = false,
}
R.presentationBoundary = "service_only"
S.Services.CombatRelationV3 = R

local U = S.Utils
local function NowMs() return math.max(0, tonumber(S.NowMs and S.NowMs()) or 0) end
local function Trim(value) return U and U.Trim and U.Trim(value) or (tostring(value or ""):match("^%s*(.-)%s*$") or "") end
local function IdentityService() return S.Services and S.Services.UnitIdentityV3 or nil end
local function TeamRoster() return S.Services and S.Services.TeamRosterV3 or nil end

local function IsSelfName(value)
    local identity = IdentityService()
    if identity == nil or type(identity.IsPlayerName) ~= "function" then return false end
    if type(identity.IsPlayerIdentityReady) == "function" and identity:IsPlayerIdentityReady() ~= true then
        if type(identity.RefreshPlayerIdentity) == "function" then identity:RefreshPlayerIdentity(false) end
        if identity:IsPlayerIdentityReady() ~= true then return false end
    end
    return identity:IsPlayerName(value) == true
end

-- Relation values -------------------------------------------------------
R.Relation = {
    SELF = "SELF",
    TEAM = "TEAM",
    FRIENDLY = "FRIENDLY",
    OPPONENT = "OPPONENT",
    UNKNOWN = "UNKNOWN",
}

-- Evidence sources, ordered by authority (higher wins). MANUAL is the user's
-- explicit mark and can never be displaced by inference.
R.Evidence = {
    MANUAL = 100,
    SELF = 90,
    TEAM_DATA = 80,
    STRONG_ATTACK = 70,   -- unit effectively damaged SELF
    STRONG_ATTACKED = 65, -- unit was effectively damaged by SELF
    HEAL_RELATION = 50,
    GUILD_ID = 45,
    KIND_NPC = 40,
    KIND_PLAYER = 40,
    NAME_HINT = 10,       -- RU localisation-only heuristic; low confidence
}

local RELATION_SET = {}
for _, value in pairs(R.Relation) do RELATION_SET[value] = true end

local function IsRelation(value) return RELATION_SET[tostring(value or "")] == true end

local function Emit(level, code, message, context)
    local diag = S.DiagnosticsManager
    if type(diag) == "table" and type(diag.RateLimited) == "function" then
        return diag:RateLimited(level, "combat_relation", code, 3000, message, context)
    elseif type(diag) == "table" and type(diag.Emit) == "function" then
        return diag:Emit(level, "combat_relation", code, message, context)
    end
end

------------------------------------------------------------------------
-- Bounded unit table
------------------------------------------------------------------------
local function CompactOrder(self, orderField, headField)
    local order = self[orderField]
    local head = math.max(1, tonumber(self[headField]) or 1)
    if type(order) ~= "table" then self[orderField], self[headField] = {}, 1; return end
    -- The map is bounded, but repeatedly advancing a head index without
    -- compacting the backing array still leaks slots over a long raid. Compact
    -- only after a sizeable stale prefix so this never becomes hot-path churn.
    if head <= 256 or head <= math.floor(#order / 2) then return end
    local nextOrder = {}
    for index = head, #order do
        local key = order[index]
        if key ~= nil then nextOrder[#nextOrder + 1] = key end
    end
    self[orderField], self[headField] = nextOrder, 1
end

local function TouchUnit(self, key, now)
    local row = self.units[key]
    if row ~= nil then return row end
    while #self.unitOrder - self.unitHead + 1 >= self.unitMax do
        local oldest = self.unitOrder[self.unitHead]
        self.unitHead = self.unitHead + 1
        if oldest ~= nil then
            local victim = self.units[oldest]
            -- Manual overrides are the user's long-term intent; never evict them.
            if victim == nil or victim.manual ~= true then self.units[oldest] = nil end
        end
    end
    self.unitSerial = self.unitSerial + 1
    row = {
        key = key,
        serial = self.unitSerial,
        relation = R.Relation.UNKNOWN,
        evidence = nil,
        evidenceAt = 0,
        hardAt = 0,
        softAt = 0,
        createdAt = now,
        manual = false,
        kind = nil,
        guildId = nil,
        lastSeenAt = now,
    }
    self.units[key] = row
    self.unitOrder[#self.unitOrder + 1] = key
    CompactOrder(self, "unitOrder", "unitHead")
    return row
end

local function KeyFor(name)
    name = Trim(name)
    return name ~= "" and name or nil
end

------------------------------------------------------------------------
-- Public queries
------------------------------------------------------------------------
function R:GetUnit(key)
    key = KeyFor(key)
    if key == nil then return nil end
    return self.units[key]
end

-- Relation facts are time-aware because team/faction can change inside one
-- fight. Callers pass the event timestamp.
function R:GetRelationAt(name, at)
    local key = KeyFor(name)
    if key == nil then return R.Relation.UNKNOWN, nil, 0 end
    self.reads = self.reads + 1
    local row = self.units[key]
    -- Manual correction remains the highest user-owned Authority. SELF is then
    -- verified from UnitIdentity; live roster membership is a dynamic TEAM fact
    -- and is deliberately NOT persisted into the bounded evidence table.
    if row ~= nil and row.manual == true then return row.relation, row.evidence, row.evidenceAt end
    if IsSelfName(key) then return R.Relation.SELF, "SELF", tonumber(at) or NowMs() end
    local roster = TeamRoster()
    if roster ~= nil and type(roster.IsMemberName) == "function" and roster:IsMemberName(key) == true then
        return R.Relation.TEAM, "TEAM_DATA", tonumber(at) or NowMs()
    end
    if row == nil then return R.Relation.UNKNOWN, nil, 0 end
    at = tonumber(at) or NowMs()
    -- A hard mark stays valid forever; a soft mark decays so a stale
    -- provisional classification cannot outlive the fight that produced it.
    if row.hardAt > 0 and at >= row.hardAt then return row.relation, row.evidence, row.evidenceAt end
    if row.softAt > 0 and at - row.softAt <= 60000 and at >= row.softAt then
        return row.relation, row.evidence, row.evidenceAt
    end
    if row.hardAt > 0 or row.softAt > 0 then return R.Relation.UNKNOWN, "EXPIRED", row.evidenceAt end
    return row.relation, row.evidence, row.evidenceAt
end

function R:IsFriendlyAt(name, at)
    local relation = self:GetRelationAt(name, at)
    return relation == R.Relation.SELF or relation == R.Relation.TEAM or relation == R.Relation.FRIENDLY
end

function R:IsOpponentAt(name, at)
    return self:GetRelationAt(name, at) == R.Relation.OPPONENT
end

------------------------------------------------------------------------
-- Evidence ingestion
------------------------------------------------------------------------
local function ApplyEvidence(self, key, relation, source, at, hard, counterpart)
    if not IsRelation(relation) then return false, "invalid relation" end
    key = KeyFor(key)
    if key == nil then return false, "name required" end
    local now = tonumber(at) or NowMs()
    local row = TouchUnit(self, key, now)
    row.lastSeenAt = now
    local weight = tonumber(R.Evidence[source]) or 0
    local currentWeight = tonumber(R.Evidence[row.evidence]) or 0

    if row.manual == true and source ~= "MANUAL" then
        -- Manual user intent wins. Record that inference tried to disagree so
        -- the disagreement is visible instead of silently ignored.
        self.evidenceRejected = self.evidenceRejected + 1
        return true, row.relation
    end
    if weight < currentWeight then
        self.evidenceRejected = self.evidenceRejected + 1
        return true, row.relation
    end

    row.relation = relation
    row.evidence = tostring(source)
    row.evidenceAt = now
    if hard == true then row.hardAt = now else row.softAt = now end
    if counterpart ~= nil then row.counterpart = tostring(counterpart) end
    self.evidenceApplied = self.evidenceApplied + 1
    return true, relation
end

function R:ApplyManual(key, relation)
    if not IsRelation(relation) then return false, "invalid relation" end
    key = KeyFor(key)
    if key == nil then return false, "name required" end
    local row = TouchUnit(self, key, NowMs())
    local changed = row.manual ~= true or row.relation ~= relation
    row.manual = true
    row.relation = relation
    row.evidence = "MANUAL"
    row.evidenceAt = NowMs()
    row.hardAt = row.evidenceAt
    self.manual[key] = relation
    self.manualOverrides = self.manualOverrides + 1
    if changed and S.Events ~= nil and type(S.Events.Publish) == "function" then
        S.Events:Publish("v3.combat_relation.updated", "manual", key, relation)
    end
    return true
end

function R:ClearManual(key)
    key = KeyFor(key)
    if key == nil then return false, "name required" end
    local row = self.units[key]
    local changed = row ~= nil and row.manual == true
    if row ~= nil then
        row.manual = false
        row.relation = R.Relation.UNKNOWN
        row.evidence = nil
        row.evidenceAt = 0
        row.hardAt, row.softAt = 0, 0
    end
    self.manual[key] = nil
    if changed and S.Events ~= nil and type(S.Events.Publish) == "function" then
        S.Events:Publish("v3.combat_relation.updated", "manual_clear", key, R.Relation.UNKNOWN)
    end
    return true
end

-- Identity facts supplied by UnitIdentityV3. Only explicit kinds are accepted;
-- a missing or conflicting kind field stays UNKNOWN (fail-closed).
function R:ApplyKind(name, kind, at)
    local key = KeyFor(name)
    if key == nil then return false, "name required" end
    local row = TouchUnit(self, key, tonumber(at) or NowMs())
    local previous = row.kind
    row.kind = tostring(kind or "")
    -- Unit kind and combat relation are separate facts. NPC/MATE/SLAVE can be
    -- friendly, so kind must never silently manufacture OPPONENT evidence.
    return true, row.relation, previous ~= row.kind
end

function R:SetGuild(name, guildId, at)
    local key = KeyFor(name)
    if key == nil then return false, "name required" end
    local row = TouchUnit(self, key, tonumber(at) or NowMs())
    row.guildId = tostring(guildId or "")
    return true
end

-- RU localisation heuristic: a Chinese-character name is very likely an NPC in
-- the RU client. This is OPTIONAL and LOW confidence; it must never override
-- any stronger evidence and defaults to disabled.
function R:ApplyChineseNameHint(name, at)
    if self.nameHintEnabled ~= true then return false, "name hint disabled" end
    local key = KeyFor(name)
    if key == nil then return false, "name required" end
    if key:find("[\228-\233][\128-\191][\128-\191]") == nil then return false, "not a CJK name" end
    local row = self.units[key]
    if row ~= nil and row.manual == true then return false, "manual override" end
    return ApplyEvidence(self, key, R.Relation.OPPONENT, "NAME_HINT", at, false)
end

------------------------------------------------------------------------
-- Combat-derived evidence
--
-- One combat fact can produce up to two hard marks:
--   * unit damaged SELF          -> OPPONENT
--   * unit was damaged by SELF   -> OPPONENT
--   * unit healed SELF / SELF healed unit -> FRIENDLY (soft: pets and NPCs
--     can inherit friendly-looking heals, so this never outranks hard marks)
--
-- "Friendly attacked friendly" is a conflict, not a silent flip.
------------------------------------------------------------------------
local MIN_EFFECTIVE_AMOUNT = 1

function R:RecordCombatFact(fact)
    if type(fact) ~= "table" then return false, "fact required" end
    local identity = IdentityService()
    if identity == nil or type(identity.IsPlayerIdentityReady) ~= "function" or identity:IsPlayerIdentityReady() ~= true then
        -- Without a verified SELF endpoint there is no anchor for any relation
        -- inference. Returning false keeps the caller's counters honest.
        return false, "player identity unavailable"
    end
    local category = tostring(fact.category or "")
    local amount = tonumber(fact.amount) or 0
    local at = tonumber(fact.receivedAt) or NowMs()
    local sourceName = Trim(fact.sourceName)
    local targetName = Trim(fact.targetName)

    local sourceRel = sourceName ~= "" and self:GetRelationAt(sourceName, at) or R.Relation.UNKNOWN
    if sourceName ~= "" and IsSelfName(sourceName) then sourceRel = R.Relation.SELF end
    local targetRel = targetName ~= "" and self:GetRelationAt(targetName, at) or R.Relation.UNKNOWN
    if targetName ~= "" and IsSelfName(targetName) then targetRel = R.Relation.SELF end
    local beforeSourceRel, beforeTargetRel = sourceRel, targetRel

    if category == "damage" and amount >= MIN_EFFECTIVE_AMOUNT then
        if sourceName ~= "" and targetRel == R.Relation.SELF then
            ApplyEvidence(self, sourceName, R.Relation.OPPONENT, "STRONG_ATTACK", at, true, targetName)
        elseif targetName ~= "" and sourceRel == R.Relation.SELF then
            ApplyEvidence(self, targetName, R.Relation.OPPONENT, "STRONG_ATTACKED", at, true, sourceName)
        elseif sourceRel == R.Relation.FRIENDLY and targetRel == R.Relation.FRIENDLY
            and sourceName ~= targetName then
            self:RecordConflict("FRIENDLY_FIRE", sourceName, targetName, at,
                "friendly attacked friendly; duel/force attack/faction change requires review")
        end
    elseif category == "heal" and amount >= MIN_EFFECTIVE_AMOUNT then
        if sourceName ~= "" and targetRel == R.Relation.SELF then
            ApplyEvidence(self, sourceName, R.Relation.FRIENDLY, "HEAL_RELATION", at, false, targetName)
        elseif targetName ~= "" and sourceRel == R.Relation.SELF then
            ApplyEvidence(self, targetName, R.Relation.FRIENDLY, "HEAL_RELATION", at, false, sourceName)
        end
    end
    -- Re-read after evidence application. The previous implementation returned
    -- the pre-hit snapshot, so the very hit that established an opponent was
    -- classified with stale UNKNOWN relation and disappeared from DPS.
    if sourceName ~= "" then sourceRel = self:GetRelationAt(sourceName, at) end
    if targetName ~= "" then targetRel = self:GetRelationAt(targetName, at) end
    self.binds = self.binds + 1
    return true, {
        sourceRelation = sourceRel,
        targetRelation = targetRel,
        relationChanged = sourceRel ~= beforeSourceRel or targetRel ~= beforeTargetRel,
    }
end

function R:RecordConflict(code, sourceName, targetName, at, reason)
    local row = {
        code = tostring(code or "UNKNOWN"),
        source = tostring(sourceName or ""),
        target = tostring(targetName or ""),
        at = tonumber(at) or NowMs(),
        reason = tostring(reason or ""),
    }
    while #self.conflictOrder - self.conflictHead + 1 >= self.conflictMax do
        local oldest = self.conflictOrder[self.conflictHead]
        self.conflictHead = self.conflictHead + 1
        if oldest ~= nil then self.conflicts[oldest] = nil end
    end
    local key = row.code .. "|" .. row.source .. "|" .. row.target .. "|" .. tostring(row.at)
    self.conflicts[key] = row
    self.conflictOrder[#self.conflictOrder + 1] = key
    CompactOrder(self, "conflictOrder", "conflictHead")
    self.conflictsRecorded = self.conflictsRecorded + 1
    Emit("warning", "RELATION_CONFLICT", "战斗关系出现需要人工复核的冲突", row)
    return true
end

------------------------------------------------------------------------
-- Lifecycle
------------------------------------------------------------------------
function R:ResetTransient(reason)
    local kept = {}
    for key, row in pairs(self.units) do
        -- Manual marks are the user's durable intent and survive a session reset.
        if row ~= nil and row.manual == true then kept[key] = row end
    end
    self.units = kept
    self.unitOrder, self.unitHead = {}, 1
    for key in pairs(self.units) do self.unitOrder[#self.unitOrder + 1] = key end
    self.conflicts, self.conflictOrder, self.conflictHead = {}, {}, 1
    self.provisionalDowngrades = 0
    return true
end

function R:GetHealth()
    local count, manual, unknown = 0, 0, 0
    for _, row in pairs(self.units) do
        count = count + 1
        if row.manual == true then manual = manual + 1 end
        if row.relation == R.Relation.UNKNOWN then unknown = unknown + 1 end
    end
    return {
        version = self.version,
        consumers = tonumber(self.consumerCount) or 0,
        units = count,
        manual = manual,
        unknown = unknown,
        conflicts = self.conflictsRecorded,
        reads = self.reads,
        binds = self.binds,
        evidenceApplied = self.evidenceApplied,
        evidenceRejected = self.evidenceRejected,
        manualOverrides = self.manualOverrides,
        nameHintEnabled = self.nameHintEnabled == true,
        rosterHeld = self.rosterHeld == true,
        rosterMembers = (function()
            local roster = TeamRoster()
            local snap = roster ~= nil and type(roster.GetSnapshot) == "function" and roster:GetSnapshot() or nil
            return snap and tonumber(snap.count) or 0
        end)(),
    }
end

local function StartRosterDependency()
    local roster = TeamRoster()
    local acquiredNow = false
    if roster ~= nil and type(roster.AcquireConsumer) == "function" and R.rosterHeld ~= true then
        local ok, err = roster:AcquireConsumer("combat_relation", { purpose = "combat_relation" })
        if ok ~= true then return false, err end
        R.rosterHeld = true
        acquiredNow = true
    end
    if R.rosterSubscribed ~= true then
        if S.Events == nil or type(S.Events.SubscribeInternal) ~= "function" then
            if acquiredNow and roster ~= nil and type(roster.ReleaseConsumer) == "function" then roster:ReleaseConsumer("combat_relation") end
            if acquiredNow then R.rosterHeld = false end
            return false, "combat relation internal event bus unavailable"
        end
        local subscribed = S.Events:SubscribeInternal("v3.team_roster.updated", R, function(_, revision, reason)
            if S.Events ~= nil and type(S.Events.Publish) == "function" then
                S.Events:Publish("v3.combat_relation.updated", "team_roster", revision, reason)
            end
        end)
        if subscribed ~= true then
            if acquiredNow and roster ~= nil and type(roster.ReleaseConsumer) == "function" then roster:ReleaseConsumer("combat_relation") end
            if acquiredNow then R.rosterHeld = false end
            return false, "team roster internal subscribe failed"
        end
        R.rosterSubscribed = true
    end
    return true
end

local function StopRosterDependency()
    if S.Events ~= nil and type(S.Events.UnsubscribeInternal) == "function" and R.rosterSubscribed == true then
        S.Events:UnsubscribeInternal("v3.team_roster.updated", R)
    end
    R.rosterSubscribed = false
    local roster = TeamRoster()
    if roster ~= nil and type(roster.ReleaseConsumer) == "function" and R.rosterHeld == true then
        local ok = roster:ReleaseConsumer("combat_relation")
        if ok ~= true then return false end
    end
    R.rosterHeld = false
    return true
end

if S.Demand ~= nil and type(S.Demand.Create) == "function" then
    R.demand = S.Demand:Create({
        id = "service.combat_relation",
        owner = R,
        normalize = function(options)
            options = type(options) == "table" and options or {}
            return { purpose = tostring(options.purpose or "general") }
        end,
        reconcile = function(_, before, after)
            local beforeCount = tonumber(before and before.count) or 0
            local afterCount = tonumber(after and after.count) or 0
            if beforeCount <= 0 and afterCount > 0 then return StartRosterDependency() end
            if beforeCount > 0 and afterCount <= 0 then
                local ok = StopRosterDependency()
                R:ResetTransient("demand_zero")
                return ok
            end
            return true
        end,
        quiesce = function()
            local ok = StopRosterDependency()
            R:ResetTransient("quiesce")
            return ok
        end,
        projectionOwner = R,
        projectionConsumersField = "consumerOptions",
        projectionCountField = "consumerCount",
    })
end

function R:AcquireConsumer(token, options)
    if self.demand == nil then return false, "relation demand unavailable" end
    return self.demand:Acquire(token, options, "relation_consumer")
end

function R:ReleaseConsumer(token)
    if self.demand == nil then return false, "relation demand unavailable" end
    return self.demand:Release(token, "relation_consumer")
end
