------------------------------------------------------------------------
-- Replicated Suite - Global Target Detection Authority
-- Author: Replicated
--
-- Single Authority for "current target" observation. Consumers migrate to this
-- service incrementally; BUFF/Plates and the Target Inspector are the first
-- consumers, while DPS combat-event classification and Healer team observation
-- deliberately retain their own domain Authorities. The service is demand-driven:
-- it stays dormant until a consumer subscribes or global inspector mode is on.
--
-- Design principles:
--   * Single Authority      - one source of truth for the current target.
--   * Demand driven         - data sources only run when a field is wanted.
--   * Event first           - TARGET_CHANGED / BUFF_UPDATE / DEBUFF_UPDATE.
--   * Fail-Closed           - unavailable data is "unknown", never forged.
--   * No duplicate scanning - data is collected once, consumed by many.
--
-- This service only OBSERVES the current target. It never mutates game state,
-- never writes the target HUD, and never overrides the DPS event/identity
-- classification Authority. Runtime target state is session-local and is never
-- persisted; only user settings are persisted through Suite State.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
S.Services = S.Services or {}
S.TargetService = {
    started = false,
    initialized = false,
    globalDetection = false,
    consumers = {},
    cache = {},
    cacheOrder = {},
    cacheHits = 0,
    cacheMisses = 0,
    lastErrors = {},
    sourceStatus = {},
    -- Capture queue is initialized at module load so Describe()/page rendering
    -- work even before the runtime reaches the target_service init stage.
    capture = {
        enabled = false,
        sticky = true,
        scope = "target",
        effectType = "buff",
        serial = 0,
        cap = 256,
        buckets = {
            target = { buff = {}, debuff = {}, hidden = {} },
            player = { buff = {}, debuff = {}, hidden = {} },
        },
    },
}
local T = S.TargetService

local NOW = function() return S.NowMs and S.NowMs() or 0 end
local UNIT_TOKEN = "target"
local KEY_MISS_GRACE = 5 -- fast-lane samples before a lost target is committed

-- Domain -> scheduler lane. Identity/profession/gear are low-frequency; vitals
-- and distance are high-frequency; effects are normal frequency. This maps the
-- demand-driven "fields a consumer wants" onto the three Suite scheduler lanes.
local FIELD_LANES = {
    identity = "slow",
    vitals = "fast",
    distance = "fast",
    profession = "slow",
    gear = "slow",
    effects = "normal",
    targetOfTarget = "slow",
    watchAggro = "fast",
    watchDist = "fast",
}

local function FieldCount(set)
    local n = 0
    if type(set) == "table" then for _ in pairs(set) do n = n + 1 end end
    return n
end

local function CopyShallow(source)
    local out = {}
    if type(source) == "table" then for k, v in pairs(source) do out[k] = v end end
    return out
end

------------------------------------------------------------------------
-- Target state (session runtime, never persisted)
------------------------------------------------------------------------
local function FreshState()
    return {
        hasTarget = false,
        key = nil,             -- stable identity key "id:<unitId>" or "name:<name>"
        unitId = nil,          -- raw stable unit id when the API provides one
        unitToken = UNIT_TOKEN,
        name = nil,
        revision = 0,          -- increments only on a genuine target change
        changedReason = "none",-- none/acquired/lost/switched/same
        acquiredAt = 0,
        lastSeen = 0,
        lastUpdate = 0,
        validity = "no_target",-- no_target/valid/stale/api_unavailable
        staleSince = nil,
        keyMissStreak = 0,
        identity = { kind = "unknown", relation = "unknown", source = "none", level = nil, rawType = nil },
        vitals = { hp = nil, maxHp = nil, hpPct = nil, mana = nil, maxMana = nil, dead = false, valid = false, at = 0 },
        distance = { value = nil, lastValid = nil, at = 0, valid = false },
        profession = { key = nil, name = nil, role = "unknown", indices = nil, source = "none", at = 0 },
        gear = { score = nil, source = "none", at = 0 },
        effects = {
            buff = {}, debuff = {}, hidden = {}, hiddenDetected = {},
            rawCounts = { buff = 0, debuff = 0, hidden = 0 },
            revision = 0, lastScan = 0, reliable = true,
        },
        targetOfTarget = { name = nil, at = 0 },
        -- watchtarget lanes (report 七-C, P1-3 依赖链): the "target of target"
        -- aggro name and the distance to the watchtarget unit. Both are
        -- demand-driven like every other field; unreadable -> "--" by the
        -- consumer, never forged. watchtarget tokens availability is ⚠️ runtime.
        watchAggro = { name = nil, at = 0, valid = false },
        watchDist = { value = nil, at = 0, valid = false },
    }
end

T.state = FreshState()

local function ResetDomains()
    local st = T.state
    st.identity = { kind = "unknown", relation = "unknown", source = "none", level = nil, rawType = nil }
    st.vitals = { hp = nil, maxHp = nil, hpPct = nil, mana = nil, maxMana = nil, dead = false, valid = false, at = 0 }
    st.distance = { value = nil, lastValid = nil, at = 0, valid = false }
    st.profession = { key = nil, name = nil, role = "unknown", indices = nil, source = "none", at = 0 }
    st.gear = { score = nil, source = "none", at = 0 }
    st.effects = {
        buff = {}, debuff = {}, hidden = {}, hiddenDetected = {},
        rawCounts = { buff = 0, debuff = 0, hidden = 0 },
        revision = 0, lastScan = 0, reliable = true,
    }
    st.targetOfTarget = { name = nil, at = 0 }
    st.watchAggro = { name = nil, at = 0, valid = false }
    st.watchDist = { value = nil, at = 0, valid = false }
end

------------------------------------------------------------------------
-- Capability-gated read helpers. Every native read goes through the central
-- API Capability Registry; an unregistered / blocked capability returns nil
-- and records a source status instead of throwing or guessing.
------------------------------------------------------------------------
local function CapRead(capName, object, methodName, ...)
    if S.Api == nil or type(S.Api.CallCapability) ~= "function" then return nil end
    local ok, value = S.Api:CallCapability(capName, object, methodName, ...)
    return ok and value or nil
end

local function Number(value)
    local n = tonumber(value)
    return (n == nil or n ~= n) and nil or n
end

local function SetSource(key, status)
    T.sourceStatus[key] = tostring(status or "unknown")
end

function T:ReadUnitName()
    local name = CapRead("X2Unit:UnitName", X2Unit, "UnitName", UNIT_TOKEN)
    if type(name) ~= "string" or name == "" then
        SetSource("name", "unavailable")
        return nil
    end
    SetSource("name", "ok")
    return name
end

function T:ReadUnitId()
    local id = CapRead("X2Unit:GetUnitId", X2Unit, "GetUnitId", UNIT_TOKEN)
    if id == nil or tostring(id) == "" then
        -- Fallback to the target-specific getter where present.
        id = CapRead("X2Unit:GetTargetUnitId", X2Unit, "GetTargetUnitId")
    end
    if id == nil or tostring(id) == "" then
        SetSource("unitId", "unavailable")
        return nil
    end
    SetSource("unitId", "ok")
    return tostring(id)
end

function T:ReadPlayerName()
    local name = CapRead("X2Unit:UnitName", X2Unit, "UnitName", "player")
    return (type(name) == "string" and name ~= "") and name or nil
end

function T:ReadVitals()
    local st = T.state
    local hp = Number(CapRead("X2Unit:UnitHealth", X2Unit, "UnitHealth", UNIT_TOKEN))
    local maxHp = Number(CapRead("X2Unit:UnitMaxHealth", X2Unit, "UnitMaxHealth", UNIT_TOKEN))
    local mana = Number(CapRead("X2Unit:UnitMana", X2Unit, "UnitMana", UNIT_TOKEN))
    local maxMana = Number(CapRead("X2Unit:UnitMaxMana", X2Unit, "UnitMaxMana", UNIT_TOKEN))
    if hp == nil or maxHp == nil or maxHp <= 0 then
        -- Fail-Closed: never expose the previous target/sample as a current
        -- health value after the native read has failed.
        st.vitals.hp = nil
        st.vitals.maxHp = nil
        st.vitals.hpPct = nil
        st.vitals.mana = nil
        st.vitals.maxMana = nil
        st.vitals.dead = false
        st.vitals.valid = false
        st.vitals.at = NOW()
        SetSource("vitals", "unavailable")
        return
    end
    st.vitals.hp = math.max(0, math.min(maxHp, hp))
    st.vitals.maxHp = maxHp
    st.vitals.hpPct = st.vitals.hp / maxHp
    if mana ~= nil and maxMana ~= nil and maxMana > 0 then
        st.vitals.mana = math.max(0, math.min(maxMana, mana))
        st.vitals.maxMana = maxMana
    else
        st.vitals.mana = nil
        st.vitals.maxMana = nil
    end
    st.vitals.dead = st.vitals.hp <= 0
    st.vitals.valid = true
    st.vitals.at = NOW()
    SetSource("vitals", "ok")
end

function T:ReadDistance()
    local st = T.state
    local value = CapRead("X2Unit:UnitDistance", X2Unit, "UnitDistance", UNIT_TOKEN)
    local distance = type(value) == "table" and Number(value.distance) or Number(value)
    if distance == nil or distance < 0 then
        st.distance.value = nil
        st.distance.at = NOW()
        st.distance.valid = false
        SetSource("distance", "unavailable")
        return
    end
    st.distance.value = distance
    st.distance.lastValid = distance
    st.distance.at = NOW()
    st.distance.valid = true
    SetSource("distance", "ok")
end

local function FirstIconPath(info)
    if type(info) ~= "table" then return nil end
    local keys = { "path", "iconPath", "icon_path", "icon", "skillIcon", "skill_icon", "texture" }
    for _, key in ipairs(keys) do
        local value = info[key]
        if type(value) == "string" and value ~= "" then return value end
    end
    return nil
end

local function EffectId(info)
    if type(info) ~= "table" then return nil end
    local id = info.buff_id or info.buffId or info.buffID or info.id
        or info.buffType or info.buff_type or info.type
    return id ~= nil and tostring(id) or nil
end

local function EffectTimeLeft(info)
    if type(info) ~= "table" then return nil end
    return Number(info.timeLeft or info.time_left or info.remainTime or info.remainingTime or info.remain_time)
end

-- Buff-id -> icon/name resolution fallback, matching the mature Plates
-- GetBuffInfoById chain. Cached so repeated scans never re-issue X2Ability.
-- Bounded: a long session can only ever hold BUFF_INFO_CACHE_MAX distinct ids.
local buffInfoCache = {}
local buffInfoCacheCount = 0
local BUFF_INFO_CACHE_MAX = 512
local function ResolveBuffInfoById(idText)
    if not idText:match("^%d+$") then return nil end
    local key = tostring(idText)
    if buffInfoCache[key] ~= nil then
        return buffInfoCache[key] ~= false and buffInfoCache[key] or nil
    end
    if buffInfoCacheCount >= BUFF_INFO_CACHE_MAX then
        buffInfoCache = {}
        buffInfoCacheCount = 0
    end
    if S.Api == nil or type(S.Api.CallCapability) ~= "function" or X2Ability == nil then
        buffInfoCache[key] = false
        buffInfoCacheCount = buffInfoCacheCount + 1
        return nil
    end
    local numericId = tonumber(key)
    for _, itemLevel in ipairs({ 0, 1, 55 }) do
        local ok, info = S.Api:CallCapability("X2Ability:GetBuffTooltip", X2Ability, "GetBuffTooltip", numericId, itemLevel)
        if ok and type(info) == "table" then
            local iconPath = FirstIconPath(info)
            local name = tostring(info.name or "")
            if iconPath ~= nil or name ~= "" then
                local resolved = { iconPath = iconPath or "", name = name }
                buffInfoCache[key] = resolved
                buffInfoCacheCount = buffInfoCacheCount + 1
                return resolved
            end
        end
    end
    buffInfoCache[key] = false
    buffInfoCacheCount = buffInfoCacheCount + 1
    return nil
end

local EFFECT_METHODS = {
    buff = { count = "UnitBuffCount", data = "UnitBuff", tip = "UnitBuffTooltip" },
    debuff = { count = "UnitDeBuffCount", data = "UnitDeBuff", tip = "UnitDeBuffTooltip" },
    hidden = { count = "UnitHiddenBuffCount", data = "UnitHiddenBuff", tip = "UnitHiddenBuffTooltip" },
}
local EFFECT_CAP = {
    buff = { "X2Unit:UnitBuffCount", "X2Unit:UnitBuff", "X2Unit:UnitBuffTooltip" },
    debuff = { "X2Unit:UnitDeBuffCount", "X2Unit:UnitDeBuff", "X2Unit:UnitDeBuffTooltip" },
    hidden = { "X2Unit:UnitHiddenBuffCount", "X2Unit:UnitHiddenBuff", "X2Unit:UnitHiddenBuffTooltip" },
}

local function NormalizeEffect(effectType, index, extra, tip, now, requireIcon)
    extra = type(extra) == "table" and extra or {}
    tip = type(tip) == "table" and tip or {}
    local id = EffectId(extra) or EffectId(tip)
    if id == nil then return nil end
    local iconPath = FirstIconPath(extra) or FirstIconPath(tip)
    local name = tostring(tip.name or tip.buffName or extra.name or extra.buffName or "")
    if iconPath == nil or name == "" then
        local resolved = ResolveBuffInfoById(id)
        if resolved ~= nil then
            iconPath = iconPath or (resolved.iconPath ~= "" and resolved.iconPath or nil)
            if name == "" then name = tostring(resolved.name or "") end
        end
    end
    -- Display consumers require a renderable icon (mirrors the mature Plates
    -- rule "an effect without an icon cannot be rendered safely"). The raw
    -- inspector keeps icon-less rows as detection evidence.
    if requireIcon == true and (iconPath == nil or iconPath == "") then return nil end
    local timeLeftMs = EffectTimeLeft(tip) or EffectTimeLeft(extra) or 0
    timeLeftMs = math.max(0, timeLeftMs)
    -- Mirrors the validated Plates correction for Defiance hidden buff 22969.
    if effectType == "hidden" and id == "22969" then
        timeLeftMs = timeLeftMs - 1440000
        if timeLeftMs < 0 then return nil end
    end
    local stack = Number(tip.stack or tip.stackCount or tip.count or extra.stack or extra.stackCount or extra.count or 0) or 0
    return {
        stableId = id,
        id = id,
        name = name ~= "" and name or ("ID " .. id),
        iconPath = iconPath or "",
        stack = math.max(0, math.floor(stack + 0.5)),
        remainingMs = timeLeftMs,
        type = effectType,
        firstSeen = now,
        lastSeen = now,
        sourceIndex = index,
    }
end

-- Read one effect lane for the current target. This is the unified extraction
-- of the mature Plates aura scan (same field aliases / id precedence) rather
-- than a new, third scanner. Returns (effects, reliable).
function T:ScanEffects(effectType)
    local methods = EFFECT_METHODS[effectType]
    local caps = EFFECT_CAP[effectType]
    if methods == nil then return {}, true end
    local limit = math.max(1, math.min(64, math.floor(Number(S.State.settings.targetDetectionEffectLimit) or 24)))
    if S.Api == nil or type(S.Api.IsCapabilityAllowed) ~= "function"
        or S.Api:IsCapabilityAllowed(caps[1]) ~= true then
        SetSource("effects_" .. effectType, "unavailable")
        return {}, false
    end
    local count = Number(CapRead(caps[1], X2Unit, methods.count, UNIT_TOKEN))
    if count == nil then
        SetSource("effects_" .. effectType, "unavailable")
        return {}, false
    end
    count = math.max(0, math.floor(count))
    local now = NOW()
    local result = {}
    local reliable = true
    for index = 1, math.min(count, limit) do
        local extra = CapRead(caps[2], X2Unit, methods.data, UNIT_TOKEN, index)
        extra = type(extra) == "table" and extra or {}
        local tip = CapRead(caps[3], X2Unit, methods.tip, UNIT_TOKEN, index)
        if tip == nil and EffectId(extra) == nil then reliable = false end
        tip = type(tip) == "table" and tip or {}
        local effect = NormalizeEffect(effectType, index, extra, tip, now)
        if effect ~= nil then
            result[#result + 1] = effect
        end
    end
    table.sort(result, function(a, b)
        local aid, bid = tonumber(a.id), tonumber(b.id)
        if aid ~= nil and bid ~= nil and aid ~= bid then return aid < bid end
        return tostring(a.id or a.name or "") < tostring(b.id or b.name or "")
    end)
    SetSource("effects_" .. effectType, "ok")
    return result, reliable, count
end

function T:ReadEffects()
    local st = T.state
    local now = NOW()
    local reliable = true
    -- Cheap change signature (id:stack per lane). It deliberately ignores the
    -- continuously ticking remaining time so the Effect Revision only advances
    -- on add/remove/stack changes, never on a normal countdown.
    local signatureParts = {}
    for _, effectType in ipairs({ "buff", "debuff", "hidden" }) do
        local effects, laneReliable, rawCount = self:ScanEffects(effectType)
        if laneReliable ~= true then reliable = false end
        st.effects[effectType] = effects
        st.effects.rawCounts = st.effects.rawCounts or {}
        st.effects.rawCounts[effectType] = tonumber(rawCount) or 0
        if effectType == "hidden" then
            -- The service only "sees" hidden auras. Display whitelisting stays
            -- with the BUFF display Authority; an empty whitelist is irrelevant
            -- here because this list is a detection/capture candidate set only.
            st.effects.hiddenDetected = effects
        end
        local ids = {}
        for _, effect in ipairs(effects) do ids[#ids + 1] = tostring(effect.id) .. ":" .. tostring(effect.stack) end
        signatureParts[#signatureParts + 1] = effectType .. "=" .. table.concat(ids, ",")
    end
    st.effects.reliable = reliable
    local signature = table.concat(signatureParts, "|")
    local changed = signature ~= st.effects.signature
    if changed then
        st.effects.signature = signature
        st.effects.revision = st.effects.revision + 1
    end
    st.effects.lastScan = now
    return changed
end

-- Display-oriented effects query: the single scan authority for the BUFF HUD.
-- The tracked whitelist is passed as a filter parameter (it remains the BUFF
-- display Authority's domain); the Service owns the scan. This faithfully
-- reproduces the mature Plates semantics: cheap id rejection in tracked-only
-- mode, stop at `maximum` accepted rows in API-index order, deterministic sort,
-- and the GetBuffInfoById icon/name fallback. Returns Plates' display shape.
function T:GetDisplayEffects(effectType, maximum, tracked, trackedOnly)
    local methods = EFFECT_METHODS[effectType]
    local caps = EFFECT_CAP[effectType]
    if methods == nil then return {}, true end
    maximum = math.floor(tonumber(maximum) or 8)
    if maximum <= 0 then return {}, true end
    maximum = math.min(12, maximum)
    if S.Api == nil or type(S.Api.IsCapabilityAllowed) ~= "function"
        or S.Api:IsCapabilityAllowed(caps[1]) ~= true then
        SetSource("effects_" .. effectType, "unavailable")
        return {}, false
    end
    local count = Number(CapRead(caps[1], X2Unit, methods.count, UNIT_TOKEN))
    if count == nil then
        SetSource("effects_" .. effectType, "unavailable")
        return {}, false
    end
    count = math.max(0, math.floor(count))
    local now = NOW()
    local result = {}
    local reliable = true
    for index = 1, count do
        if #result >= maximum then break end
        local extra = CapRead(caps[2], X2Unit, methods.data, UNIT_TOKEN, index)
        extra = type(extra) == "table" and extra or {}
        local id = EffectId(extra)
        local tip = nil
        -- Keep tracked-only cheap when the data row already exposes an id.
        if trackedOnly == true and id == nil then
            local okTip, value = S.Api:CallCapability(caps[3], X2Unit, methods.tip, UNIT_TOKEN, index)
            if not okTip then reliable = false end
            tip = okTip and type(value) == "table" and value or {}
            local tooltipId = EffectId(tip)
            if tooltipId ~= nil then id = tostring(tooltipId) end
        end
        local trackedEntry = id ~= nil and type(tracked) == "table" and tracked[id] or nil
        local accept = trackedOnly ~= true or (type(trackedEntry) == "table" and trackedEntry.enabled ~= false)
        if accept then
            if tip == nil then
                local okTip, value = S.Api:CallCapability(caps[3], X2Unit, methods.tip, UNIT_TOKEN, index)
                if not okTip then reliable = false end
                tip = okTip and type(value) == "table" and value or {}
            end
            local effect = NormalizeEffect(effectType, index, extra, tip, now, true)
            if effect ~= nil then
                local displayName = tostring(effect.name or "")
                if type(trackedEntry) == "table" and tostring(trackedEntry.customName or "") ~= "" then
                    displayName = tostring(trackedEntry.customName)
                end
                local out = {
                    key = effectType .. ":" .. tostring(effect.id) .. ":" .. tostring(effect.name),
                    id = tostring(effect.id),
                    name = displayName ~= "" and displayName or ("ID " .. tostring(effect.id)),
                    iconPath = effect.iconPath,
                    timeLeftMs = tonumber(effect.remainingMs) or 0,
                    stack = tonumber(effect.stack) or 0,
                    sourceIndex = tonumber(effect.sourceIndex) or 0,
                }
                if type(trackedEntry) == "table" then out.trackedEntry = trackedEntry end
                result[#result + 1] = out
            elseif trackedOnly == true and type(trackedEntry) == "table" and trackedEntry.enabled ~= false then
                -- A tracked effect is known to exist but its row was incomplete.
                reliable = false
            end
        end
    end
    table.sort(result, function(left, right)
        local leftPriority = tonumber(left and left.trackedEntry and left.trackedEntry.priority) or 0
        local rightPriority = tonumber(right and right.trackedEntry and right.trackedEntry.priority) or 0
        if leftPriority ~= rightPriority then return leftPriority > rightPriority end
        local leftId, rightId = tonumber(left and left.id), tonumber(right and right.id)
        if leftId ~= nil and rightId ~= nil and leftId ~= rightId then return leftId < rightId end
        local leftKey = tostring(left and (left.id or left.key or left.name) or "")
        local rightKey = tostring(right and (right.id or right.key or right.name) or "")
        if leftKey ~= rightKey then return leftKey < rightKey end
        return tostring(left and left.name or "") < tostring(right and right.name or "")
    end)
    SetSource("effects_" .. effectType, "ok")
    return result, reliable
end

function T:ReadProfession()
    local st = T.state
    local function ClearProfession(source)
        st.profession.key = nil
        st.profession.name = nil
        st.profession.role = "unknown"
        st.profession.indices = nil
        st.profession.source = source or "unavailable"
        st.profession.at = NOW()
    end
    if S.Api == nil or type(S.Api.IsCapabilityAllowed) ~= "function"
        or S.Api:IsCapabilityAllowed("X2Unit:GetTargetAbilityTemplates") ~= true then
        ClearProfession("unavailable")
        SetSource("profession", "unavailable")
        return
    end
    local ok, templates = S.Api:CallCapability("X2Unit:GetTargetAbilityTemplates", X2Unit, "GetTargetAbilityTemplates", UNIT_TOKEN)
    if not ok or type(templates) ~= "table" or templates[1] == nil or templates[2] == nil or templates[3] == nil then
        ClearProfession("unavailable")
        SetSource("profession", "unavailable")
        return
    end
    local indices = { Number(templates[1].index), Number(templates[2].index), Number(templates[3].index) }
    if indices[1] == nil or indices[2] == nil or indices[3] == nil then
        ClearProfession("unavailable")
        SetSource("profession", "unavailable")
        return
    end
    table.sort(indices)
    local key = string.format("name_%d_%d_%d", indices[1], indices[2], indices[3])
    if key == "name_30_30_30" then
        ClearProfession("unknown")
        SetSource("profession", "unknown")
        return
    end
    local className = ""
    if X2Locale ~= nil and type(X2Locale.LocalizeUiText) == "function" and COMBINED_ABILITY_NAME_TEXT ~= nil then
        className = tostring(CapRead("X2Locale:LocalizeUiText", X2Locale, "LocalizeUiText", COMBINED_ABILITY_NAME_TEXT, key, "") or "")
    end
    if className == "" and type(GetUIText) == "function" and COMBINED_ABILITY_NAME_TEXT ~= nil then
        local okFallback, fallback = pcall(GetUIText, COMBINED_ABILITY_NAME_TEXT, key)
        if okFallback and fallback ~= nil then className = tostring(fallback) end
    end
    if className == "" then
        ClearProfession("unknown")
        SetSource("profession", "unknown")
        return
    end
    local role = type(nameMappings) == "table" and nameMappings[key] or "unknown"
    st.profession.key = key
    st.profession.name = className
    st.profession.role = role
    st.profession.indices = indices
    st.profession.source = "ability_templates"
    st.profession.at = NOW()
    SetSource("profession", "ok")
end

function T:ReadGear()
    local st = T.state
    local score = Number(CapRead("X2Unit:UnitGearScore", X2Unit, "UnitGearScore", UNIT_TOKEN, true))
    if score == nil or score <= 0 then
        st.gear.score = nil
        st.gear.source = "unavailable"
        st.gear.at = NOW()
        SetSource("gear", "unavailable")
        return
    end
    st.gear.score = score
    st.gear.source = "unit_gear_score"
    st.gear.at = NOW()
    SetSource("gear", "ok")
end

-- DPS kind/relation -> shared Target State vocabulary. "OTHER" and anything
-- unclassified stay "unknown" (Fail-Closed) rather than being guessed.
local function MapDpsKind(kind)
    kind = tostring(kind or "")
    if kind == "PLAYER" then return "player" end
    if kind == "NPC" then return "npc" end
    if kind == "MATE" or kind == "SLAVE" then return "summon" end
    return "unknown"
end

local function MapDpsRelation(relation)
    relation = tostring(relation or "")
    if relation == "SELF" or relation == "TEAM" or relation == "FRIENDLY" then return "friendly" end
    if relation == "OPPONENT" then return "enemy" end
    if relation == "NEUTRAL" then return "neutral" end
    return "unknown"
end

-- Normalize a unit name the way DPS indexes entities (trim + lowercase), then
-- tolerate world-qualified names by also matching the base before "@".
local function NormalizeDpsName(name)
    local text = tostring(name or "")
    text = string.gsub(text, "^%s+", "")
    text = string.gsub(text, "%s+$", "")
    text = string.lower(text)
    return text
end

-- Read-only identity enrichment from the validated DPS Identity Authority.
-- Performs a PURE read over DPS.Entities.byKey (no DPS method with side effects,
-- no mutation). Consumes DPS's effective kind/relation, which already resolve
-- manual override above automatic inference. Never overrides the locally proven
-- "self" relation. Ambiguous or unavailable results Fail-Closed to "unknown".
function T:ReadDpsIdentity()
    local st = T.state
    if st.identity.relation == "self" then return end
    if ReplicatedSuiteModuleSandbox == nil then SetSource("identity_dps", "unavailable"); return end
    local ok, dps = pcall(function() return ReplicatedSuiteModuleSandbox:GetExport("dps", "ReplicatedDps") end)
    if not ok or type(dps) ~= "table" or type(dps.Entities) ~= "table" or type(dps.Entities.byKey) ~= "table" then
        SetSource("identity_dps", "unavailable")
        return
    end
    local name = st.name
    if name == nil or name == "" then SetSource("identity_dps", "no_name"); return end
    local targetBase = NormalizeDpsName(name)
    if targetBase == "" then SetSource("identity_dps", "no_name"); return end

    -- Pure read. Accept only a single unambiguous concrete classification.
    local resolvedKind, resolvedRelation, resolvedKey = nil, nil, nil
    for key, entity in pairs(dps.Entities.byKey) do
        if type(entity) == "table" then
            local entityName = NormalizeDpsName(entity.name)
            local atIndex = string.find(entityName, "@", 1, true)
            local entityBase = atIndex ~= nil and string.sub(entityName, 1, atIndex - 1) or entityName
            if entityBase == targetBase then
                local kind = tostring(entity.kind or "UNKNOWN")
                if kind ~= "UNKNOWN" then
                    if resolvedKind == nil then
                        resolvedKind = kind
                        resolvedRelation = tostring(entity.relation or "UNKNOWN")
                        resolvedKey = tostring(entity.key or key)
                    elseif resolvedKind ~= kind then
                        SetSource("identity_dps", "conflict")
                        return
                    end
                end
            end
        end
    end
    if resolvedKind == nil then SetSource("identity_dps", "unknown"); return end

    st.identity.kind = MapDpsKind(resolvedKind)
    st.identity.relation = MapDpsRelation(resolvedRelation)
    st.identity.source = "dps"
    st.identity.dpsKey = resolvedKey
    SetSource("identity_dps", "ok")
end

function T:ReadIdentity()
    local st = T.state
    local playerName = self:ReadPlayerName()
    local targetName = st.name or self:ReadUnitName()
    local targetId = st.unitId or self:ReadUnitId()
    local playerId = CapRead("X2Unit:GetUnitId", X2Unit, "GetUnitId", "player")

    -- Only the self relation is reliably derivable from these whitelisted reads.
    -- Player/NPC/summon and friendly/enemy classification come from the validated
    -- DPS Identity Authority (consumed read-only below); the Target Service stays
    -- Fail-Closed (unknown) rather than guessing from names or behaviour.
    if targetName ~= nil and playerName ~= nil and targetName == playerName then
        st.identity.relation = "self"
        st.identity.source = "self_name"
    elseif targetId ~= nil and playerId ~= nil and tostring(targetId) == tostring(playerId) then
        st.identity.relation = "self"
        st.identity.source = "self_id"
    else
        st.identity.relation = "unknown"
        st.identity.source = "none"
    end
    st.identity.kind = "unknown" -- Fail-Closed; see note above.
    st.identity.level = Number(CapRead("X2Unit:UnitLevel", X2Unit, "UnitLevel", UNIT_TOKEN))
    st.identity.rawType = nil
    SetSource("identity", "ok")

    -- Enrich kind/relation from DPS (read-only; never overrides "self").
    self:ReadDpsIdentity()
end

function T:ReadTargetOfTarget()
    local st = T.state
    local name = CapRead("X2Unit:UnitName", X2Unit, "UnitName", "targettarget")
    st.targetOfTarget.name = (type(name) == "string" and name ~= "") and name or nil
    st.targetOfTarget.at = NOW()
end

-- watchtarget lanes (report 七-C). The watchtarget token family may or may not
-- be usable on this RU client; unreadable values stay invalid and the window
-- consumer renders "--" instead (fail-closed, zero errors).
function T:ReadWatchAggro()
    local st = T.state
    local name = CapRead("X2Unit:UnitName", X2Unit, "UnitName", "watchtargettarget")
    st.watchAggro.name = (type(name) == "string" and name ~= "") and name or nil
    st.watchAggro.valid = st.watchAggro.name ~= nil
    st.watchAggro.at = NOW()
end

function T:ReadWatchDist()
    local st = T.state
    local value = CapRead("X2Unit:UnitDistance", X2Unit, "UnitDistance", "watchtarget")
    local distance = type(value) == "table" and Number(value.distance) or Number(value)
    if distance == nil or distance < 0 then
        st.watchDist.value = nil
        st.watchDist.valid = false
    else
        st.watchDist.value = distance
        st.watchDist.valid = true
    end
    st.watchDist.at = NOW()
end

------------------------------------------------------------------------
-- Target lifecycle. A genuine target change (acquire/switch/lost) bumps
-- `revision` and resets every domain. Transient API misses keep the last known
-- target stale instead of wrongly declaring it gone.
------------------------------------------------------------------------
function T:RefreshTargetKey(forceEdge)
    local st = T.state
    local now = NOW()
    local unitId = self:ReadUnitId()
    local name = self:ReadUnitName()

    -- RU clients can expose GetUnitId intermittently while UnitName stays stable.
    -- Treat id:<x> <-> name:<same name> as a representation change, not a target
    -- switch. A concrete new unit id still wins and produces a real switch.
    local sameName = st.hasTarget == true
        and type(name) == "string" and name ~= ""
        and type(st.name) == "string" and st.name ~= ""
        and tostring(name) == tostring(st.name)

    local key = nil
    if unitId ~= nil then
        key = "id:" .. unitId
    elseif name ~= nil then
        if forceEdge ~= true and sameName and st.unitId ~= nil and type(st.key) == "string" and st.key:match("^id:") then
            -- Preserve the last proven id while this sample only lost the id API.
            unitId = st.unitId
            key = st.key
        else
            key = "name:" .. name
        end
    end

    if key == nil then
        if forceEdge == true then
            -- TARGET_CHANGED is an authoritative identity edge. Clear the old
            -- target immediately so A's effects can never remain visible while
            -- the client is warming B (or while the player has cleared target).
            if st.hasTarget then self:LostTarget("target_event") end
            return
        end
        st.keyMissStreak = (tonumber(st.keyMissStreak) or 0) + 1
        if st.hasTarget then
            if st.keyMissStreak >= KEY_MISS_GRACE then
                self:LostTarget("unreadable")
            else
                st.validity = "stale"
                st.staleSince = st.staleSince or now
            end
        else
            st.validity = "no_target"
            st.hasTarget = false
        end
        return
    end

    st.keyMissStreak = 0
    st.staleSince = nil
    st.lastSeen = now
    st.lastUpdate = now

    local representationUpgrade = st.hasTarget == true
        and sameName
        and st.unitId == nil
        and unitId ~= nil
        and type(st.key) == "string" and st.key == ("name:" .. tostring(name))

    if not st.hasTarget then
        st.hasTarget = true
        st.revision = st.revision + 1
        st.changedReason = "acquired"
        st.acquiredAt = now
        ResetDomains()
    elseif representationUpgrade then
        -- Name-only -> concrete-id is the same observed unit. Upgrade the stable
        -- representation without clearing domains or advancing Target Revision.
        st.changedReason = "same"
    elseif st.key ~= key then
        self:Remember(st.key, st.name)
        st.revision = st.revision + 1
        st.changedReason = "switched"
        st.acquiredAt = now
        ResetDomains()
    else
        st.changedReason = "same"
    end
    st.key = key
    st.unitId = unitId
    st.name = name or st.name
    st.validity = "valid"
end

function T:LostTarget(reason)
    local st = T.state
    if st.hasTarget then self:Remember(st.key, st.name) end
    st.hasTarget = false
    st.key = nil
    st.unitId = nil
    st.name = nil
    st.revision = st.revision + 1
    st.changedReason = tostring(reason or "lost")
    st.validity = "no_target"
    st.keyMissStreak = 0
    st.staleSince = nil
    ResetDomains()
end

function T:ClearTarget()
    self:LostTarget("cleared")
end

------------------------------------------------------------------------
-- Bounded recent-target cache (session-local, never persisted).
------------------------------------------------------------------------
function T:Remember(key, name)
    if key == nil or key == "" then return end
    local now = NOW()
    local max = math.max(1, math.min(128, math.floor(Number(S.State.settings.targetDetectionCacheSize) or 32)))
    local existing = self.cache[key]
    if existing ~= nil then
        self.cacheHits = self.cacheHits + 1
        existing.lastSeen = now
        existing.name = name or existing.name
        return
    end
    self.cacheMisses = self.cacheMisses + 1
    self.cache[key] = { key = key, name = name, lastSeen = now }
    self.cacheOrder[#self.cacheOrder + 1] = key
    while #self.cacheOrder > max do
        local oldest = table.remove(self.cacheOrder, 1)
        if oldest ~= nil then self.cache[oldest] = nil end
    end
end

function T:PruneCache()
    local ttl = math.max(5000, math.min(600000, math.floor(Number(S.State.settings.targetDetectionCacheTtlMs) or 120000)))
    local now = NOW()
    for key, row in pairs(self.cache) do
        if now - (tonumber(row.lastSeen) or 0) > ttl then self.cache[key] = nil end
    end
    local kept = {}
    for _, key in ipairs(self.cacheOrder) do
        if self.cache[key] ~= nil then kept[#kept + 1] = key end
    end
    self.cacheOrder = kept
end

------------------------------------------------------------------------
-- Consumers (demand-driven field subscription)
------------------------------------------------------------------------
function T:Subscribe(owner, fields)
    local key = tostring(owner or "anonymous")
    local set = {}
    if type(fields) == "table" then
        for _, field in ipairs(fields) do set[tostring(field)] = true end
    end
    self.consumers[key] = set
    self:ApplyDemand()
    return true
end

function T:Unsubscribe(owner)
    self.consumers[tostring(owner or "anonymous")] = nil
    self:ApplyDemand()
    return true
end

function T:IsFieldRequested(field)
    field = tostring(field or "")
    for _, set in pairs(self.consumers) do
        if set[field] == true then return true end
    end
    return false
end

function T:DescribeConsumers()
    local result = {}
    for owner, set in pairs(self.consumers) do
        local fields = {}
        for field in pairs(set) do fields[#fields + 1] = field end
        table.sort(fields)
        result[#result + 1] = { owner = owner, fields = fields }
    end
    table.sort(result, function(a, b) return tostring(a.owner) < tostring(b.owner) end)
    return result
end

------------------------------------------------------------------------
-- Scheduler lanes. One private monotonic driver is owned by the Suite
-- Scheduler; this service adds no OnUpdate handler of its own.
------------------------------------------------------------------------
function T:FastLane()
    self:RefreshTargetKey()
    -- The BUFF manager owns capture when active; otherwise use the local
    -- bounded ID-first fallback from this same scheduler lane.
    if self.capture.enabled == true and self:IsPlatesCaptureAuthorityActive() ~= true then
        self:CaptureFastFallback()
    end
    -- watchtarget lanes are independent of the current target: the window must
    -- keep showing "--"/distance even when no hard target is selected. Demand
    -- driven like every other field (no subscriber -> no reads).
    if self.globalDetection or self:IsFieldRequested("watchAggro") then self:ReadWatchAggro() end
    if self.globalDetection or self:IsFieldRequested("watchDist") then self:ReadWatchDist() end
    local st = T.state
    if not st.hasTarget then return end
    if self.globalDetection or self:IsFieldRequested("vitals") then self:ReadVitals() end
    if self.globalDetection or self:IsFieldRequested("distance") then self:ReadDistance() end
end

function T:NormalLane()
    if not T.state.hasTarget then return end
    if self.globalDetection or self:IsFieldRequested("effects") then
        self:ReadEffects()
        self.effectsDirty = false
    end
end

function T:SlowLane()
    self:RefreshTargetKey()
    local st = T.state
    if not st.hasTarget then return end
    if self.globalDetection or self:IsFieldRequested("identity") then self:ReadIdentity() end
    if self.globalDetection or self:IsFieldRequested("profession") then self:ReadProfession() end
    if self.globalDetection or self:IsFieldRequested("gear") then self:ReadGear() end
    if self.globalDetection or self:IsFieldRequested("targetOfTarget") then self:ReadTargetOfTarget() end
end

function T:ApplyDemand()
    if not self.initialized then return end
    local laneWanted = { fast = false, normal = false, slow = false }
    if self.started == true then
        for field, lane in pairs(FIELD_LANES) do
            if self.globalDetection or self:IsFieldRequested(field) then laneWanted[lane] = true end
        end
        -- Fallback capture (when the BUFF manager is not the capture Authority)
        -- also needs the cheap fast lane.
        if self.capture.enabled == true and self:IsPlatesCaptureAuthorityActive() ~= true then
            laneWanted.fast = true
        end
    end
    -- Key refresh must keep running whenever any lane is active; the fast lane
    -- carries it. Stop() is a real quiescence fence: no consumer may resurrect a
    -- lane while the service lifecycle is stopped.
    if S.Scheduler ~= nil and type(S.Scheduler.SetEnabled) == "function" then
        S.Scheduler:SetEnabled("target_fast", self.started == true and (laneWanted.fast or laneWanted.normal or laneWanted.slow))
        S.Scheduler:SetEnabled("target_normal", self.started == true and laneWanted.normal)
        S.Scheduler:SetEnabled("target_slow", self.started == true and laneWanted.slow)
        S.Scheduler:SetEnabled("target_prune", self.started == true)
    end
    self.lanes = laneWanted
end

function T:ApplyIntervals()
    local fast = math.max(60, math.min(1000, math.floor(Number(S.State.settings.targetDetectionFastMs) or 100)))
    local normal = math.max(120, math.min(2000, math.floor(Number(S.State.settings.targetDetectionNormalMs) or 250)))
    local slow = math.max(500, math.min(30000, math.floor(Number(S.State.settings.targetDetectionSlowMs) or 2000)))
    if S.Scheduler ~= nil and S.Scheduler.tasks then
        if S.Scheduler.tasks.target_fast then S.Scheduler.tasks.target_fast.intervalMs = fast end
        if S.Scheduler.tasks.target_normal then S.Scheduler.tasks.target_normal.intervalMs = normal end
        if S.Scheduler.tasks.target_slow then S.Scheduler.tasks.target_slow.intervalMs = slow end
    end
end

------------------------------------------------------------------------
-- Capture Authority bridge
--
-- BUFF/Plates already owns the production 100ms ID-only capture lane. When that
-- module is enabled, TargetService acts as a Proxy so two independent scanners
-- never run for the same target. If BUFF/Plates is disabled, TargetService uses
-- its bounded fallback queue so the global inspector remains usable.
------------------------------------------------------------------------
function T:GetPlatesManager()
    if S.ModuleManager ~= nil and type(S.ModuleManager.IsEnabled) == "function"
        and S.ModuleManager:IsEnabled("plates") ~= true then
        return nil
    end
    if ReplicatedSuiteModuleSandbox == nil then return nil end
    local ok, plates = pcall(function()
        return ReplicatedSuiteModuleSandbox:GetExport("plates", "ReplicatedPlates")
    end)
    if not ok or type(plates) ~= "table" or type(plates.Manager) ~= "table" then return nil end
    return plates.Manager
end

function T:IsPlatesCaptureAuthorityActive()
    local manager = self:GetPlatesManager()
    return manager ~= nil
        and type(manager.SetCaptureEnabled) == "function"
        and type(manager.GetCaptureList) == "function"
end

local function TrimFallbackCaptureBucket(bucket, cap)
    if type(bucket) ~= "table" then return end
    cap = math.max(32, math.min(512, math.floor(tonumber(cap) or 256)))
    local count = 0
    for _ in pairs(bucket) do count = count + 1 end
    while count >= cap do
        local oldestId, oldestSerial = nil, nil
        for id, entry in pairs(bucket) do
            local serial = tonumber(entry and entry.lastSeenSerial)
                or tonumber(entry and entry.firstSeenSerial) or 0
            if oldestSerial == nil or serial < oldestSerial then
                oldestId, oldestSerial = id, serial
            end
        end
        if oldestId == nil then break end
        bucket[oldestId] = nil
        count = count - 1
    end
end

local function PruneFallbackCaptureBucket(bucket, serial, sticky)
    if type(bucket) ~= "table" or sticky == true then return end
    for id, entry in pairs(bucket) do
        local age = (tonumber(serial) or 0) - (tonumber(entry and entry.lastSeenSerial) or 0)
        if age > 3 then bucket[id] = nil end
    end
end

function T:SetCaptureLane(scope, effectType)
    scope = scope == "player" and "player" or "target"
    if effectType ~= "debuff" and effectType ~= "hidden" then effectType = "buff" end
    self.capture.scope = scope
    self.capture.effectType = effectType
    local manager = self:GetPlatesManager()
    if manager ~= nil and type(manager.SetCaptureLane) == "function" then
        pcall(manager.SetCaptureLane, manager, scope, effectType)
    end
end

------------------------------------------------------------------------
-- Global inspector mode (user opt-in) + capture queue
------------------------------------------------------------------------
function T:SetGlobalDetection(enabled)
    -- The standalone Target Inspector was removed. Current-target data remains a
    -- shared Authority for professional consumers, but no hidden full-inspector
    -- demand is allowed to survive behind a removed UI.
    self.globalDetection = false
    S.State.settings.targetDetectionEnabled = false
    if S.Storage ~= nil and type(S.Storage.RequestSave) == "function" then S.Storage:RequestSave() end
    self:ApplyDemand()
    return false
end

function T:SetQueueRetain(enabled)
    S.State.settings.targetDetectionQueueRetain = enabled == true
    self.capture.sticky = enabled == true
    local manager = self:GetPlatesManager()
    if manager ~= nil and type(manager.SetCaptureSticky) == "function" then
        pcall(manager.SetCaptureSticky, manager, self.capture.sticky)
    end
    if S.Storage ~= nil and type(S.Storage.RequestSave) == "function" then S.Storage:RequestSave() end
    return self.capture.sticky
end

function T:IsQueueRetain()
    return self.capture.sticky ~= false
end

function T:IsCaptureEnabled()
    local manager = self:GetPlatesManager()
    if manager ~= nil and type(manager.IsCaptureEnabled) == "function" then
        local ok, enabled = pcall(manager.IsCaptureEnabled, manager)
        if ok then self.capture.enabled = enabled == true end
        if type(manager.capture) == "table" then
            self.capture.scope = manager.capture.scope == "player" and "player" or "target"
            local effectType = tostring(manager.capture.effectType or "buff")
            self.capture.effectType = (effectType == "debuff" or effectType == "hidden") and effectType or "buff"
        end
    end
    return self.capture.enabled == true
end

function T:StartCapture(scope, effectType)
    self:SetCaptureLane(scope or "target", effectType or "buff")
    self.capture.enabled = true
    local manager = self:GetPlatesManager()
    if manager ~= nil and type(manager.SetCaptureSticky) == "function" then
        pcall(manager.SetCaptureSticky, manager, self.capture.sticky ~= false)
    end
    if manager ~= nil and type(manager.SetCaptureEnabled) == "function" then
        local ok, enabled = pcall(manager.SetCaptureEnabled, manager, true, self.capture.scope, self.capture.effectType)
        if ok then self.capture.enabled = enabled == true end
    end
    self:ApplyDemand()
    return self.capture.enabled
end

function T:StopCapture()
    local manager = self:GetPlatesManager()
    if manager ~= nil and type(manager.SetCaptureEnabled) == "function" then
        pcall(manager.SetCaptureEnabled, manager, false, self.capture.scope, self.capture.effectType)
    end
    self.capture.enabled = false
    self:ApplyDemand()
    return false
end

function T:ClearQueue()
    local manager = self:GetPlatesManager()
    if manager ~= nil and type(manager.ClearCaptureQueue) == "function" then
        for _, scope in ipairs({ "target", "player" }) do
            for _, effectType in ipairs({ "buff", "debuff", "hidden" }) do
                pcall(manager.ClearCaptureQueue, manager, scope, effectType)
            end
        end
    end
    for _, scopeBucket in pairs(self.capture.buckets) do
        if type(scopeBucket) == "table" then
            for effectType in pairs(scopeBucket) do scopeBucket[effectType] = {} end
        end
    end
    self.capture.serial = 0
end

-- Capture the currently visible effect ids for a scope/lane into the sticky
-- queue. This mirrors the mature Plates rolling id-scan semantics: short-lived
-- auras that appeared even once remain in the candidate list while capture is
-- on and the queue retains entries.
function T:CaptureScan(scope, effectType, deep)
    scope = scope == "player" and "player" or "target"
    if effectType ~= "debuff" and effectType ~= "hidden" then effectType = "buff" end
    local unit = scope
    local methods = EFFECT_METHODS[effectType]
    local caps = EFFECT_CAP[effectType]
    local scopeBucket = self.capture.buckets[scope]
    if methods == nil or scopeBucket == nil then return end
    if S.Api == nil or S.Api:IsCapabilityAllowed(caps[1]) ~= true then return end
    local count = Number(CapRead(caps[1], X2Unit, methods.count, unit))
    if count == nil then return end
    count = math.max(0, math.floor(count))
    local limit = math.max(1, math.min(64, math.floor(Number(S.State.settings.targetDetectionEffectLimit) or 24)))
    local bucket = scopeBucket[effectType]
    if bucket == nil then return end

    self.capture.serial = (tonumber(self.capture.serial) or 0) + 1
    local serial = self.capture.serial
    local now = NOW()
    for index = 1, math.min(count, limit) do
        local extra = CapRead(caps[2], X2Unit, methods.data, unit, index)
        extra = type(extra) == "table" and extra or {}
        local id = EffectId(extra)
        local tip = {}
        -- Periodic fallback capture is ID-first. A full Tooltip decode is only
        -- performed for explicit/manual/event scans, never on the 100ms lane.
        if deep == true or id == nil then
            local rawTip = CapRead(caps[3], X2Unit, methods.tip, unit, index)
            tip = type(rawTip) == "table" and rawTip or {}
            id = id or EffectId(tip)
        end
        if id ~= nil then
            id = tostring(id)
            local existing = bucket[id]
            if existing == nil then
                TrimFallbackCaptureBucket(bucket, self.capture.cap)
                local resolved = ResolveBuffInfoById(id)
                existing = {
                    stableId = id,
                    id = id,
                    name = tostring((type(tip) == "table" and (tip.name or tip.buffName))
                        or extra.name or extra.buffName
                        or (resolved and resolved.name) or ("检测 ID " .. id)),
                    iconPath = tostring(FirstIconPath(extra) or FirstIconPath(tip)
                        or (resolved and resolved.iconPath) or "ui/icon/icon_unknown_item.dds"),
                    stack = 1,
                    remainingMs = 0,
                    type = effectType,
                    firstSeen = now,
                    lastSeen = now,
                    firstSeenSerial = serial,
                    lastSeenSerial = serial,
                    captured = true,
                }
                bucket[id] = existing
            end
            existing.lastSeen = now
            existing.lastSeenSerial = serial
            existing.captured = true
            if deep == true then
                local effect = NormalizeEffect(effectType, index, extra, tip, now)
                if effect ~= nil then
                    existing.name = tostring(effect.name or existing.name)
                    existing.iconPath = tostring(effect.iconPath or existing.iconPath)
                    existing.remainingMs = tonumber(effect.remainingMs) or existing.remainingMs
                    existing.stack = tonumber(effect.stack) or existing.stack
                end
            end
        end
    end
    PruneFallbackCaptureBucket(bucket, serial, self.capture.sticky ~= false)
end

function T:CaptureFastFallback()
    if self.capture.enabled ~= true or self:IsPlatesCaptureAuthorityActive() == true then return end
    self:CaptureScan(self.capture.scope, self.capture.effectType, false)
end

function T:CaptureOnEvent(hint)
    if self.capture.enabled ~= true then return end
    -- Plates runtime receives the same native aura event and owns its capture
    -- queue when enabled. Do not deep-decode the event a second time here.
    if self:IsPlatesCaptureAuthorityActive() == true then return end
    local selected = self.capture.effectType
    if hint == selected or (selected == "hidden" and hint == "buff") then
        self:CaptureScan(self.capture.scope, selected, true)
    end
end

-- Event-driven aura refresh: BUFF_UPDATE / DEBUFF_UPDATE is the authoritative
-- "an effect just changed" edge. When any consumer wants effects (or global
-- inspector is on), reflect the change immediately instead of waiting for the
-- normal poll lane; the throttle bounds burst cost under heavy combat.
function T:OnBuffEvent(hint)
    if self.capture.enabled == true then
        self:CaptureOnEvent(hint)
    end
    -- Do not run a full Buff+Debuff+Hidden Tooltip sweep directly inside a bursty
    -- aura event. The event marks the domain dirty; the Suite normal scheduler
    -- performs the bounded detailed refresh. Short-lived states are preserved by
    -- the ID-first capture lane/event capture above.
    if self.globalDetection or self:IsFieldRequested("effects") then
        self.effectsDirty = true
        self.effectsEventAt = NOW()
    end
end

function T:ScanNow(scope)
    scope = scope == "player" and "player" or (scope or self.capture.scope or "target")
    -- Manual scan is intentionally deep and bounded. It does not enable the
    -- continuous scanner and therefore has no persistent performance cost.
    for _, effectType in ipairs({ "buff", "debuff", "hidden" }) do
        self:CaptureScan(scope, effectType, true)
    end
end

------------------------------------------------------------------------
-- Query interface (read Proxy for consumers)
------------------------------------------------------------------------
function T:GetState()
    return self.state
end

function T:GetEffects(effectType)
    return self.state.effects[effectType] or {}
end

function T:GetHiddenDetected()
    return self.state.effects.hiddenDetected or {}
end

function T:GetCaptureBucket(scope, effectType)
    local scopeBucket = self.capture.buckets[scope or "target"]
    return (scopeBucket and scopeBucket[effectType or "buff"]) or {}
end

function T:GetCaptureList(scope, effectType)
    scope = scope == "player" and "player" or "target"
    if effectType ~= "debuff" and effectType ~= "hidden" then effectType = "buff" end
    local result, seen = {}, {}
    local manager = self:GetPlatesManager()
    if manager ~= nil and type(manager.GetCaptureList) == "function" then
        local ok, list = pcall(manager.GetCaptureList, manager, scope, effectType)
        if ok and type(list) == "table" then
            for _, entry in ipairs(list) do
                local id = tostring(entry.id or "")
                if id ~= "" then
                    result[#result + 1] = {
                        stableId = id,
                        id = id,
                        name = tostring(entry.name or ""),
                        iconPath = tostring(entry.iconPath or ""),
                        stack = tonumber(entry.stack) or 0,
                        remainingMs = tonumber(entry.timeLeftMs) or 0,
                        type = effectType,
                        captured = true,
                        lastSeenSerial = tonumber(entry.lastSeenSerial) or 0,
                    }
                    seen[id] = true
                end
            end
        end
    end

    -- Manual "立即扫描" is owned by the TargetService even when Plates is active,
    -- so merge the local bounded bucket instead of hiding those rows behind the
    -- production capture Authority.
    local bucket = self:GetCaptureBucket(scope, effectType)
    local serial = tonumber(self.capture.serial) or 0
    for id, entry in pairs(bucket) do
        local age = serial - (tonumber(entry.lastSeenSerial) or 0)
        if seen[tostring(id)] ~= true and (self.capture.sticky ~= false or age <= 3) then
            result[#result + 1] = entry
            seen[tostring(id)] = true
        end
    end
    table.sort(result, function(a, b)
        local as = tonumber(a.lastSeenSerial) or 0
        local bs = tonumber(b.lastSeenSerial) or 0
        if as ~= bs then return as > bs end
        return (tonumber(a.id) or 0) < (tonumber(b.id) or 0)
    end)
    return result
end

function T:GetInspectionEffects(scope, effectType)
    scope = scope == "player" and "player" or "target"
    if effectType ~= "debuff" and effectType ~= "hidden" then effectType = "buff" end
    local result, seen = {}, {}
    if scope == "target" then
        for _, effect in ipairs(self:GetEffects(effectType) or {}) do
            local id = tostring(effect.stableId or effect.id or "")
            if id ~= "" then
                effect.captured = false
                result[#result + 1] = effect
                seen[id] = true
            end
        end
    end
    for _, effect in ipairs(self:GetCaptureList(scope, effectType)) do
        local id = tostring(effect.stableId or effect.id or "")
        if id ~= "" and seen[id] ~= true then
            effect.captured = true
            result[#result + 1] = effect
            seen[id] = true
        end
    end
    return result
end

------------------------------------------------------------------------
-- Diagnostics (one-shot dump; no high-frequency chat output)
------------------------------------------------------------------------
function T:RecordError(stage, err)
    self.lastErrors[#self.lastErrors + 1] = { stage = stage, error = tostring(err or "unknown"), at = NOW() }
    while #self.lastErrors > 8 do table.remove(self.lastErrors, 1) end
end

function T:Describe()
    local st = self.state
    local captureEnabled = self:IsCaptureEnabled()
    return {
        hasTarget = st.hasTarget,
        key = st.key,
        unitId = st.unitId,
        name = st.name,
        revision = st.revision,
        changedReason = st.changedReason,
        validity = st.validity,
        lastSeen = st.lastSeen,
        lastUpdate = st.lastUpdate,
        identity = CopyShallow(st.identity),
        vitals = CopyShallow(st.vitals),
        distance = CopyShallow(st.distance),
        profession = CopyShallow(st.profession),
        gear = CopyShallow(st.gear),
        targetOfTarget = CopyShallow(st.targetOfTarget),
        watchAggro = CopyShallow(st.watchAggro),
        watchDist = CopyShallow(st.watchDist),
        effectCounts = {
            buff = #(st.effects.buff or {}),
            debuff = #(st.effects.debuff or {}),
            hidden = #(st.effects.hidden or {}),
        },
        effectsReliable = st.effects.reliable,
        effectsRevision = st.effects.revision,
        sourceStatus = CopyShallow(self.sourceStatus),
        consumers = self:DescribeConsumers(),
        consumerCount = FieldCount(self.consumers),
        globalDetection = self.globalDetection,
        captureEnabled = captureEnabled,
        captureSticky = self.capture.sticky,
        captureScope = self.capture.scope,
        captureEffectType = self.capture.effectType,
        cacheSize = #self.cacheOrder,
        cacheHits = self.cacheHits,
        cacheMisses = self.cacheMisses,
        lanes = CopyShallow(self.lanes or {}),
        lastErrors = CopyShallow(self.lastErrors),
    }
end

function T:PrintDiagnostic()
    local d = self:Describe()
    local lines = {
        "[目标检测诊断] 目标：" .. (d.hasTarget and (tostring(d.name) .. " (" .. tostring(d.key) .. ")") or "无"),
        "Revision " .. tostring(d.revision) .. " · " .. tostring(d.changedReason) .. " · " .. tostring(d.validity),
        "身份：" .. tostring(d.identity.kind) .. "/" .. tostring(d.identity.relation) .. " · 职业：" .. tostring(d.profession.name or "未知") .. "(" .. tostring(d.profession.source) .. ") · 装等：" .. tostring(d.gear.score or "不可用"),
        "血量：" .. tostring(d.vitals.hp or "?") .. "/" .. tostring(d.vitals.maxHp or "?") .. " · 距离：" .. tostring(d.distance.value or "不可用"),
        "Buff/Debuff/Hidden：" .. tostring(d.effectCounts.buff) .. "/" .. tostring(d.effectCounts.debuff) .. "/" .. tostring(d.effectCounts.hidden),
        "数据源：" .. table.concat(self:FormatSourceStatus(), " "),
        "消费者：" .. tostring(d.consumerCount) .. " · 缓存：" .. tostring(d.cacheSize) .. " · 命中/未命中 " .. tostring(d.cacheHits) .. "/" .. tostring(d.cacheMisses),
    }
    if type(S.DispatchSystemChat) == "function" then
        S.DispatchSystemChat(table.concat(lines, "  ║  "))
    end
end

function T:FormatSourceStatus()
    local parts = {}
    for _, key in ipairs({ "name", "unitId", "identity", "identity_dps", "vitals", "distance", "profession", "gear", "effects_buff", "effects_debuff", "effects_hidden" }) do
        parts[#parts + 1] = key .. "=" .. tostring(self.sourceStatus[key] or "unknown")
    end
    return parts
end

------------------------------------------------------------------------
-- Lifecycle
------------------------------------------------------------------------
function T:Initialize()
    if self.initialized then return true end
    self.initialized = true
    -- Standalone Target Inspector UI no longer exists. Clear legacy persisted
    -- opt-in so a user who once enabled it cannot keep an invisible full scanner.
    self.globalDetection = false
    S.State.settings.targetDetectionEnabled = false
    self.capture.sticky = S.State.settings.targetDetectionQueueRetain ~= false

    -- One-time scheduler lane installation. Lane enable/disable is governed by
    -- ApplyDemand(); the prune lane always runs (cheap, bounded).
    if S.Scheduler ~= nil and type(S.Scheduler.AddTask) == "function" then
        S.Scheduler:AddTask("target_fast", math.max(60, tonumber(S.State.settings.targetDetectionFastMs) or 100), function()
            local ok, err = xpcall(function() T:FastLane() end, S.SafeTraceback)
            if not ok then T:RecordError("fast", err) end
        end, false, self, "P2")
        S.Scheduler:AddTask("target_normal", math.max(120, tonumber(S.State.settings.targetDetectionNormalMs) or 250), function()
            local ok, err = xpcall(function() T:NormalLane() end, S.SafeTraceback)
            if not ok then T:RecordError("normal", err) end
        end, false, self, "P3")
        S.Scheduler:AddTask("target_slow", math.max(500, tonumber(S.State.settings.targetDetectionSlowMs) or 2000), function()
            local ok, err = xpcall(function() T:SlowLane() end, S.SafeTraceback)
            if not ok then T:RecordError("slow", err) end
        end, false, self, "P5")
        S.Scheduler:AddTask("target_prune", 5000, function()
            local ok, err = xpcall(function() T:PruneCache() end, S.SafeTraceback)
            if not ok then T:RecordError("prune", err) end
        end, false, self, "P5")
    end

    if S.Events ~= nil then
        S.Events:Subscribe("TARGET_CHANGED", self, function()
            -- The game just reported a target edge. Re-read the key immediately
            -- and force the next lane pass instead of trusting a stale poll.
            T.state.keyMissStreak = 0
            T:RefreshTargetKey(true)
        end)
        -- Aura edges drive capture + event-first effects refresh (see OnBuffEvent).
        S.Events:Subscribe("BUFF_UPDATE", self, function() T:OnBuffEvent("buff") end)
        S.Events:Subscribe("DEBUFF_UPDATE", self, function() T:OnBuffEvent("debuff") end)
    end

    self:ApplyIntervals()
    self:ApplyDemand()
    return true
end

function T:Start()
    if self.started then return true end
    if not self.initialized then self:Initialize() end
    self.started = true
    self:ApplyDemand()
    return true
end

function T:Stop()
    self.started = false
    self:StopCapture()
    self:ApplyDemand()
    return true
end
