------------------------------------------------------------------------
-- Replicated Suite V3 - Unit Identity Facts
--
-- Shared conservative identity facts for combat/target consumers.
-- This service never owns faction/relation/PVP-PVE/business classification.
-- Stable IDs are accepted only from native getters; COMBAT_MSG's raw unit id
-- is bound to source/target only after GetUnitNameById verifies exactly one
-- visible endpoint name.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
S.Services = S.Services or {}

local I = {
    Id = "v3.unit_identity",
    version = 1,
    cache = {},
    cacheOrder = {},
    cacheHead = 1,
    cacheSerial = 0,
    cacheCount = 0,
    cacheMax = 1024,
    nameHitTtlMs = 60000,
    nameMissTtlMs = 1500,
    kindHitTtlMs = 60000,
    kindMissTtlMs = 1500,
    playerTtlMs = 1000,
    player = nil,
    reads = 0,
    cacheHits = 0,
    cacheMisses = 0,
    endpointBinds = 0,
    endpointAmbiguous = 0,
    kindConflicts = 0,
}
I.presentationBoundary = "service_only"
S.Services.UnitIdentityV3 = I

local U = S.Utils
local function NowMs() return math.max(0, tonumber(S.NowMs and S.NowMs()) or 0) end
local function Trim(value) return U and U.Trim and U.Trim(value) or (tostring(value or ""):match("^%s*(.-)%s*$") or "") end

local function ValidId(value)
    local text = Trim(value)
    if text == "" or text == "0" or text == "-1" or text == "nil" then return nil end
    return text
end

local function NormalizeName(value)
    return string.lower(Trim(value))
end

local function SplitWorldName(value)
    local full = NormalizeName(value)
    if full == "" then return "", "", nil end
    local base, world = string.match(full, "^(.-)@(.+)$")
    if base ~= nil and base ~= "" and world ~= nil and world ~= "" then return full, base, world end
    return full, full, nil
end

local function NamesEquivalent(left, right)
    local lf, lb, lw = SplitWorldName(left)
    local rf, rb, rw = SplitWorldName(right)
    if lf == "" or rf == "" then return false end
    if lf == rf then return true end
    -- COMBAT_MSG commonly emits the short name while official unit getters may
    -- return Name@World. Never merge two explicitly different world-qualified
    -- names; accept short<->qualified only.
    if lb ~= rb then return false end
    return (lw == nil) ~= (rw == nil)
end

local EXPLICIT_KIND_FIELDS = {
    unittype = true,
    objecttype = true,
    unittypeid = true,
    objecttypeid = true,
    unitobjecttype = true,
    unitkind = true,
    unitkindtype = true,
}

local function MapExplicitKind(value)
    local numeric = tonumber(value)
    if numeric ~= nil then
        local playerType = tonumber(rawget(_G, "UO_CHARACTER")) or tonumber(rawget(_G, "UO_PLAYER"))
        if playerType ~= nil and numeric == playerType then return "PLAYER" end
        if tonumber(rawget(_G, "UO_NPC")) ~= nil and numeric == tonumber(rawget(_G, "UO_NPC")) then return "NPC" end
        if tonumber(rawget(_G, "UO_SLAVE")) ~= nil and numeric == tonumber(rawget(_G, "UO_SLAVE")) then return "SLAVE" end
        if tonumber(rawget(_G, "UO_MATE")) ~= nil and numeric == tonumber(rawget(_G, "UO_MATE")) then return "MATE" end
        if (tonumber(rawget(_G, "UO_HOUSING")) ~= nil and numeric == tonumber(rawget(_G, "UO_HOUSING")))
            or (tonumber(rawget(_G, "UO_TRANSFER")) ~= nil and numeric == tonumber(rawget(_G, "UO_TRANSFER")))
            or (tonumber(rawget(_G, "UO_SHIPYARD")) ~= nil and numeric == tonumber(rawget(_G, "UO_SHIPYARD")))
            or (tonumber(rawget(_G, "UO_BUTLER")) ~= nil and numeric == tonumber(rawget(_G, "UO_BUTLER"))) then
            return "OTHER"
        end
        return nil
    end
    if type(value) ~= "string" then return nil end
    local normalized = string.upper(Trim(value)):gsub("[%s_%-]", "")
    if normalized == "PLAYER" or normalized == "CHARACTER" or normalized == "PC" or normalized == "UOCHARACTER" then return "PLAYER" end
    if normalized == "NPC" or normalized == "MONSTER" or normalized == "MOB" or normalized == "UONPC" then return "NPC" end
    if normalized == "MATE" or normalized == "PET" or normalized == "MOUNT" or normalized == "UOMATE" then return "MATE" end
    if normalized == "SLAVE" or normalized == "SUMMON" or normalized == "SUMMONED" or normalized == "UOSLAVE" then return "SLAVE" end
    if normalized == "OTHER" or normalized == "HOUSING" or normalized == "TRANSFER" or normalized == "SHIPYARD" or normalized == "BUTLER" then return "OTHER" end
    return nil
end

function I:ParseExplicitKind(info)
    if type(info) ~= "table" then return nil, "NO_TABLE" end
    local queue = { { value = info, depth = 0 } }
    local head, inspected = 1, 0
    local observed, observedCount = {}, 0
    local function Observe(kind)
        if kind == nil or observed[kind] == true then return end
        observed[kind] = true
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
                if EXPLICIT_KIND_FIELDS[normalizedKey] == true or (normalizedKey == "type" and frame.depth == 0) then
                    Observe(MapExplicitKind(value))
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
        for kind in pairs(observed) do return kind, "EXPLICIT_KIND" end
    end
    if observedCount > 1 then
        self.kindConflicts = self.kindConflicts + 1
        return nil, "CONFLICTING_EXPLICIT_KINDS"
    end
    return nil, "NO_EXPLICIT_KIND"
end

function I:_TouchEntry(id)
    local entry = self.cache[id]
    if entry ~= nil then return entry end
    self.cacheSerial = self.cacheSerial + 1
    entry = { id = id, serial = self.cacheSerial, createdAt = NowMs(), lastAccessAt = NowMs() }
    self.cache[id] = entry
    self.cacheCount = self.cacheCount + 1
    self.cacheOrder[#self.cacheOrder + 1] = { id = id, serial = entry.serial }
    while self.cacheCount > self.cacheMax do
        local row = self.cacheOrder[self.cacheHead]
        self.cacheHead = self.cacheHead + 1
        if row ~= nil then
            local current = self.cache[row.id]
            if current ~= nil and current.serial == row.serial then
                self.cache[row.id] = nil
                self.cacheCount = self.cacheCount - 1
            end
        end
    end
    if self.cacheHead > 512 and self.cacheHead > (#self.cacheOrder / 2) then
        local compact = {}
        for index = self.cacheHead, #self.cacheOrder do compact[#compact + 1] = self.cacheOrder[index] end
        self.cacheOrder, self.cacheHead = compact, 1
    end
    return entry
end

function I:_ReadNameById(id, now)
    local entry = self:_TouchEntry(id)
    entry.lastAccessAt = now
    if entry.nameExpiresAt ~= nil and now <= entry.nameExpiresAt then
        self.cacheHits = self.cacheHits + 1
        return entry.name, entry.nameReliable == true
    end
    self.cacheMisses = self.cacheMisses + 1
    local allowed = S.Api and S.Api:IsCapabilityAllowed("X2Unit:GetUnitNameById") == true
    local name = nil
    if allowed and X2Unit ~= nil then
        self.reads = self.reads + 1
        local ok, value = S.Api:Call(X2Unit, "GetUnitNameById", id)
        if ok == true then name = Trim(value); if name == "" then name = nil end end
    end
    entry.name = name
    entry.nameReliable = name ~= nil
    entry.nameExpiresAt = now + (name ~= nil and self.nameHitTtlMs or self.nameMissTtlMs)
    return name, name ~= nil
end

function I:_ReadKindById(id, now)
    local entry = self:_TouchEntry(id)
    entry.lastAccessAt = now
    if entry.kindExpiresAt ~= nil and now <= entry.kindExpiresAt then
        self.cacheHits = self.cacheHits + 1
        return entry.kind, entry.kindState
    end
    self.cacheMisses = self.cacheMisses + 1
    local kind, state = nil, "API_UNAVAILABLE"
    local allowed = S.Api and S.Api:IsCapabilityAllowed("X2Unit:GetUnitInfoById") == true
    if allowed and X2Unit ~= nil then
        self.reads = self.reads + 1
        local ok, info = S.Api:Call(X2Unit, "GetUnitInfoById", id)
        if ok == true then kind, state = self:ParseExplicitKind(info) else state = "READ_FAILED" end
    end
    entry.kind, entry.kindState = kind, state
    entry.kindExpiresAt = now + (kind ~= nil and self.kindHitTtlMs or self.kindMissTtlMs)
    return kind, state
end

function I:GetById(rawId, options)
    local id = ValidId(rawId)
    if id == nil then return nil, "invalid unit id" end
    local now = NowMs()
    local name, nameReliable = self:_ReadNameById(id, now)
    local kind, kindState = nil, nil
    if type(options) == "table" and options.includeKind == true then kind, kindState = self:_ReadKindById(id, now) end
    return {
        id = id,
        name = name,
        nameReliable = nameReliable == true,
        kind = kind,
        kindReliable = kind ~= nil,
        kindState = kindState,
        at = now,
    }
end

function I:ResolveCombatEndpoint(rawId, sourceName, targetName)
    local id = ValidId(rawId)
    if id == nil then return nil end
    local officialName = self:_ReadNameById(id, NowMs())
    if officialName == nil then return nil end
    local sourceMatch = NamesEquivalent(officialName, sourceName)
    local targetMatch = NamesEquivalent(officialName, targetName)
    if sourceMatch == targetMatch then
        if sourceMatch then self.endpointAmbiguous = self.endpointAmbiguous + 1 end
        return nil
    end
    self.endpointBinds = self.endpointBinds + 1
    return {
        role = sourceMatch and "source" or "target",
        id = id,
        officialName = officialName,
        confidence = "verified_id_name",
    }
end

function I:RefreshPlayerIdentity(force)
    local now = NowMs()
    if force ~= true and type(self.player) == "table" and now - (tonumber(self.player.at) or 0) <= self.playerTtlMs then
        return self.player
    end
    local name, worldName, id
    if S.Api ~= nil and X2Unit ~= nil then
        if S.Api:IsCapabilityAllowed("X2Unit:UnitName") == true then
            local ok, value = S.Api:Call(X2Unit, "UnitName", "player")
            if ok then name = Trim(value); if name == "" then name = nil end end
        end
        if S.Api:IsCapabilityAllowed("X2Unit:UnitNameWithWorld") == true then
            local ok, value = S.Api:Call(X2Unit, "UnitNameWithWorld", "player")
            if ok then worldName = Trim(value); if worldName == "" then worldName = nil end end
        end
        if S.Api:IsCapabilityAllowed("X2Unit:GetUnitId") == true then
            local ok, value = S.Api:Call(X2Unit, "GetUnitId", "player")
            if ok then id = ValidId(value) end
        end
    end
    self.player = {
        id = id,
        name = name,
        nameWithWorld = worldName,
        normalizedName = NormalizeName(name),
        normalizedWorldName = NormalizeName(worldName),
        at = now,
        reliable = name ~= nil or worldName ~= nil,
    }
    if id ~= nil and (name ~= nil or worldName ~= nil) then
        local entry = self:_TouchEntry(id)
        entry.name = worldName or name
        entry.nameReliable = true
        entry.nameExpiresAt = now + self.nameHitTtlMs
    end
    return self.player
end


function I:IsPlayerIdentityReady()
    return type(self.player) == "table" and self.player.reliable == true
end

function I:IsPlayerName(value)
    local normalized = NormalizeName(value)
    if normalized == "" then return false end
    local player = self.player
    if type(player) ~= "table" then player = self:RefreshPlayerIdentity(false) end
    if type(player) ~= "table" then return false end
    if normalized == tostring(player.normalizedName or "") or normalized == tostring(player.normalizedWorldName or "") then return true end
    return NamesEquivalent(value, player.name) or NamesEquivalent(value, player.nameWithWorld)
end

function I:ClearCache(reason)
    self.cache = {}
    self.cacheOrder = {}
    self.cacheHead = 1
    self.cacheCount = 0
    self.player = nil
    return true
end

function I:GetHealth()
    return {
        version = self.version,
        cache = self.cacheCount,
        cacheMax = self.cacheMax,
        reads = self.reads,
        hits = self.cacheHits,
        misses = self.cacheMisses,
        endpointBinds = self.endpointBinds,
        endpointAmbiguous = self.endpointAmbiguous,
        kindConflicts = self.kindConflicts,
        playerReady = type(self.player) == "table" and self.player.reliable == true,
    }
end
