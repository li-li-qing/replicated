------------------------------------------------------------------------
-- Replicated Suite V3 - Death Review Store
--
-- Account-scoped permanent storage. The lightweight settings/history index is
-- split from individual death records because RU SaveData has previously
-- truncated large aggregate tables. At most 30 records are referenced, while
-- 31 bounded physical record slots provide one transactional spare: a new
-- record is written to an unreferenced slot BEFORE the index is committed, so
-- an index write failure can never overwrite a record still referenced by the
-- previous authoritative index.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local P = S.Persistence
if type(P) ~= "table" or type(P.RegisterV3Store) ~= "function" then return end

S.Features = S.Features or {}
S.Features.DeathReview = S.Features.DeathReview or {}
local F = S.Features.DeathReview
local U = S.Utils

local INDEX_STORE = "v3.death_review"
local INDEX_SCHEMA = 1
local INDEX_CODEC_VERSION = 1
local RECORD_SCHEMA = 1
local RECORD_PREFIX = P.V3KeyPrefix .. "death_review_record_"
local MAX_HISTORY = 30
local RECORD_SLOTS = MAX_HISTORY + 1
local MAX_EVENTS = 96
local MAX_DEBUFFS = 10

-- Sized against encoded SaveData envelopes. Index stays small; every timeline
-- record is independently bounded so no setting can create an unbounded write.
local INDEX_BUDGET = { maxDepth = 6, maxNodes = 1800, maxStringBytes = 24000, maxEntriesPerTable = 128 }
local RECORD_BUDGET = { maxDepth = 7, maxNodes = 1800, maxStringBytes = 14000, maxEntriesPerTable = 128 }

-- The death-review index persists shared FloatingSurface state.  This state
-- MUST be canonicalized by the same pure Foundation normalizer on every
-- save/load. Keeping widgetWindow as an opaque table made Integrity v4 hash
-- serializer representation (for example omitted false/default fields) instead
-- of the logical window state, which produced a real RU cross-reload fence.
local Floating = S.RSUI and S.RSUI.FloatingSurface or nil
if type(Floating) ~= "table" or type(Floating.NormalizeState) ~= "function" then
    error("FloatingSurface unavailable for DeathReview store")
end

F.PersistenceCanonicalWindowContractVersion = 6
F.PersistenceIndexCodecVersion = INDEX_CODEC_VERSION
F.WidgetWindowSizePolicy = {
    defaultWidth = 470,
    defaultHeight = 330,
    minWidth = 1,
    minHeight = 1,
    defaultOverallOpacity = 0.96,
    defaultBackgroundOpacity = 1.0,
    defaultTextOpacity = 1.0,
}

local function NormalizeWidgetWindow(value)
    return Floating:NormalizeState(value, F.WidgetWindowSizePolicy)
end

local function DeepCopy(value)
    if U ~= nil and type(U.DeepCopy) == "function" then return U.DeepCopy(value) end
    return value
end

local function Trim(value)
    if U ~= nil and type(U.Trim) == "function" then return U.Trim(value) end
    return tostring(value or ""):match("^%s*(.-)%s*$") or ""
end

local function Text(value, fallback, maxBytes)
    local text = Trim(value)
    if text == "" then text = tostring(fallback or "") end
    maxBytes = math.max(8, math.floor(tonumber(maxBytes) or 160))
    if #text > maxBytes then text = string.sub(text, 1, maxBytes) end
    return text
end

local function ClampInt(value, minimum, maximum, fallback)
    local n = math.floor(tonumber(value) or tonumber(fallback) or minimum)
    if n < minimum then n = minimum end
    if n > maximum then n = maximum end
    return n
end

local function NormalizeSettings(value)
    value = type(value) == "table" and value or {}
    return {
        autoShow = value.autoShow ~= false,
        windowMs = ClampInt(value.windowMs, 3000, 20000, 10000),
        maxHistory = ClampInt(value.maxHistory, 1, MAX_HISTORY, 10),
        minDamage = ClampInt(value.minDamage, 0, 5000, 0),
        showDebuffs = value.showDebuffs ~= false,
    }
end

local function NormalizeDebuff(value)
    value = type(value) == "table" and value or {}
    return {
        effectId = tonumber(value.effectId),
        name = Text(value.name, "未知 Debuff", 120),
        stack = math.max(0, math.floor(tonumber(value.stack) or 0)),
        path = value.path ~= nil and Text(value.path, "", 240) or nil,
    }
end

local function NormalizeEvent(value)
    value = type(value) == "table" and value or {}
    return {
        time = math.max(0, tonumber(value.time) or 0),
        source = Text(value.source, "未知来源", 120),
        ability = Text(value.ability, "普通攻击", 160),
        amount = math.max(0, math.floor((tonumber(value.amount) or 0) + 0.5)),
        environmental = value.environmental == true and true or nil,
    }
end

local function NormalizeRecord(value, fallbackSerial)
    value = type(value) == "table" and value or {}
    local events = {}
    for index, row in ipairs(type(value.events) == "table" and value.events or {}) do
        if index > MAX_EVENTS then break end
        local event = NormalizeEvent(row)
        if event.amount > 0 then events[#events + 1] = event end
    end
    local debuffs = {}
    for index, row in ipairs(type(value.debuffs) == "table" and value.debuffs or {}) do
        if index > MAX_DEBUFFS then break end
        debuffs[#debuffs + 1] = NormalizeDebuff(row)
    end
    local lethal = type(value.lethal) == "table" and NormalizeEvent(value.lethal) or nil
    if lethal == nil and #events > 0 then lethal = NormalizeEvent(events[#events]) end
    local total = 0
    for _, row in ipairs(events) do total = total + (tonumber(row.amount) or 0) end
    return {
        schemaVersion = RECORD_SCHEMA,
        serial = math.max(1, math.floor(tonumber(value.serial) or tonumber(fallbackSerial) or 1)),
        time = math.max(0, tonumber(value.time) or 0),
        noticeTime = math.max(0, tonumber(value.noticeTime) or tonumber(value.time) or 0),
        clock = Text(value.clock, "--:--:--", 24),
        windowMs = ClampInt(value.windowMs, 3000, 20000, 10000),
        totalDamage = math.max(0, math.floor(tonumber(value.totalDamage) or total)),
        lethal = lethal,
        events = events,
        debuffs = debuffs,
    }
end

local function NormalizeSummary(value, fallbackSerial, fallbackStorageId)
    value = type(value) == "table" and value or {}
    local lethal = type(value.lethal) == "table" and value.lethal or {}
    local storageId = ClampInt(value.storageId, 1, RECORD_SLOTS, fallbackStorageId or 1)
    return {
        serial = math.max(1, math.floor(tonumber(value.serial) or tonumber(fallbackSerial) or 1)),
        storageId = storageId,
        time = math.max(0, tonumber(value.time) or 0),
        clock = Text(value.clock, "--:--:--", 24),
        windowMs = ClampInt(value.windowMs, 3000, 20000, 10000),
        totalDamage = math.max(0, math.floor(tonumber(value.totalDamage) or 0)),
        lethalSource = Text(value.lethalSource or lethal.source, "--", 120),
        lethalAbility = Text(value.lethalAbility or lethal.ability, "--", 160),
        lethalAmount = math.max(0, math.floor(tonumber(value.lethalAmount or lethal.amount) or 0)),
        eventCount = math.max(0, math.min(MAX_EVENTS, math.floor(tonumber(value.eventCount) or (type(value.events) == "table" and #value.events or 0)))),
        debuffCount = math.max(0, math.min(MAX_DEBUFFS, math.floor(tonumber(value.debuffCount) or (type(value.debuffs) == "table" and #value.debuffs or 0)))),
    }
end

local function SummaryFromRecord(record, storageId)
    return NormalizeSummary({
        serial = record.serial, storageId = storageId, time = record.time, clock = record.clock,
        windowMs = record.windowMs, totalDamage = record.totalDamage, lethal = record.lethal,
        eventCount = type(record.events) == "table" and #record.events or 0,
        debuffCount = type(record.debuffs) == "table" and #record.debuffs or 0,
    }, record.serial, storageId)
end

local function NormalizeIndexWithWindow(value, windowMode)
    value = type(value) == "table" and value or {}
    local settings = NormalizeSettings(value.settings)
    local sourceHistory = type(value.history) == "table" and value.history or {}
    local sourceEntries = type(sourceHistory.entries) == "table" and sourceHistory.entries or {}
    local entries, serial = {}, math.max(0, math.floor(tonumber(sourceHistory.serial) or tonumber(value.serial) or 0))
    for _, row in ipairs(sourceEntries) do
        if #entries >= MAX_HISTORY then break end
        if type(row) == "table" and tonumber(row.storageId) ~= nil then
            local normalized = NormalizeSummary(row, #entries + 1, row.storageId)
            serial = math.max(serial, normalized.serial)
            entries[#entries + 1] = normalized
        end
    end
    table.sort(entries, function(a, b) return (tonumber(a.serial) or 0) < (tonumber(b.serial) or 0) end)
    while #entries > settings.maxHistory do table.remove(entries, 1) end
    local widgetWindow
    if windowMode == "legacy_opaque_18_145" then
        -- .18.145 and earlier deliberately treated this Presentation subtree as
        -- opaque. Preserve that exact historical canonical SHAPE only for the
        -- persistence recovery hook; current Domain state never uses this path.
        widgetWindow = type(value.widgetWindow) == "table" and DeepCopy(value.widgetWindow) or {}
    else
        widgetWindow = NormalizeWidgetWindow(value.widgetWindow)
    end
    return {
        settings = settings,
        history = { serial = serial, entries = entries },
        widgetWindow = widgetWindow,
    }
end

local function NormalizeIndex(value)
    return NormalizeIndexWithWindow(value, "current")
end

-- Serializer-stable index codec (.18.149). The RU serializer may omit false,
-- so default-TRUE business flags must never rely on a literal false surviving
-- the native round-trip. Persist their NEGATED state as numeric sentinel 1;
-- missing sentinel then unambiguously means the default true. FloatingSurface
-- booleans remain safe because their semantic default is false and the shared
-- normalizer reconstructs omitted false members deterministically.
local function EncodeIndex(value)
    local normalized = NormalizeIndex(value)
    local settings = {
        windowMs = normalized.settings.windowMs,
        maxHistory = normalized.settings.maxHistory,
        minDamage = normalized.settings.minDamage,
    }
    if normalized.settings.autoShow == false then settings.autoShowDisabled = 1 end
    if normalized.settings.showDebuffs == false then settings.showDebuffsDisabled = 1 end
    return {
        codec = INDEX_CODEC_VERSION,
        payload = {
            settings = settings,
            history = DeepCopy(normalized.history),
            widgetWindow = DeepCopy(normalized.widgetWindow),
        },
    }
end

local function DecodeIndex(raw)
    if type(raw) ~= "table" then return nil, "death_review_index_payload_required" end
    if raw.codec ~= nil then
        if tonumber(raw.codec) ~= INDEX_CODEC_VERSION then
            return nil, "death_review_index_codec_version:" .. tostring(raw.codec)
        end
        local payload = type(raw.payload) == "table" and raw.payload or nil
        if payload == nil then return nil, "death_review_index_codec_payload_missing" end
        local encodedSettings = type(payload.settings) == "table" and payload.settings or {}
        local domain = {
            settings = {
                autoShow = tonumber(encodedSettings.autoShowDisabled) ~= 1,
                windowMs = encodedSettings.windowMs,
                maxHistory = encodedSettings.maxHistory,
                minDamage = encodedSettings.minDamage,
                showDebuffs = tonumber(encodedSettings.showDebuffsDisabled) ~= 1,
            },
            history = DeepCopy(payload.history),
            widgetWindow = DeepCopy(payload.widgetWindow),
        }
        return NormalizeIndex(domain), nil
    end

    -- Pre-.18.149 plain stores were persisted as { payload = Domain, __rsmeta }.
    -- The fallback also accepts a bare Domain for developer harness/migration
    -- probes. No old addon key is read; this is only the same V3 Store key.
    local source = type(raw.__rsmeta) == "table" and type(raw.payload) == "table" and raw.payload or raw
    return NormalizeIndex(source), nil
end

-- .18.143-.18.145 persisted widgetWindow as an opaque table. RU SaveData may
-- also omit false-valued members. .18.148 covered only missing FloatingSurface
-- fields, but a default-TRUE business flag (autoShow/showDebuffs) that was false
-- at stamp time can likewise disappear on disk; NormalizeSettings(nil) then turns
-- it back into true and makes the old v4 stamp impossible to reproduce.
--
-- Recovery remains fail-closed. We enumerate ONE bounded mutation set containing
-- only deterministic serializer ambiguities:
--   1) missing default-TRUE DeathReview booleans may historically have been false;
--   2) missing legacy opaque widgetWindow members may be restored from the current
--      pure FloatingSurface normalizer.
-- A candidate is returned only when its full canonical fingerprint EXACTLY equals
-- the already-stamped fingerprint. At most 12 mutations => 4096 candidates, only
-- on this one-time fenced historical-load path; there is no Tick/runtime cost.
local LEGACY_WINDOW_RECOVERABLE_KEYS = {
    "width", "height", "minimized", "locked",
    "overallOpacity", "backgroundOpacity", "textOpacity", "fontScale", "userMoved",
    "x", "y", "anchorH", "anchorV", "offsetX", "offsetY",
    "coordinateSpace", "savedUiScale",
}
local LEGACY_DEFAULT_TRUE_SETTING_KEYS = { "autoShow", "showDebuffs" }
local MAX_HISTORICAL_RECOVERY_MUTATIONS = 12

local function CountTableEntries(value)
    if type(value) ~= "table" then return 0 end
    local count = 0
    for _ in pairs(value) do count = count + 1 end
    return count
end

-- Historical-only collector for RU table-shape drift. Normal Domain/codec reads
-- intentionally retain the strict sequence contract above. Previous RU
-- persistence incidents proved that Lua table representation can cross a native
-- round-trip with a different sequence/map shape; when that happens ipairs()
-- may expose fewer rows than pairs(). Recovery may collect those rows only to
-- reconstruct an OLD canonical candidate, and the candidate is never trusted
-- unless its full fingerprint exactly equals the existing integrity stamp.
local function NormalizeHistoricalIndexWithRecoveredEntries(value)
    value = type(value) == "table" and value or {}
    local settings = NormalizeSettings(value.settings)
    local sourceHistory = type(value.history) == "table" and value.history or {}
    local sourceEntries = type(sourceHistory.entries) == "table" and sourceHistory.entries or {}
    local entries = {}
    local serial = math.max(0, math.floor(tonumber(sourceHistory.serial) or tonumber(value.serial) or 0))
    for _, row in pairs(sourceEntries) do
        if type(row) == "table" and tonumber(row.storageId) ~= nil then
            local normalized = NormalizeSummary(row, #entries + 1, row.storageId)
            serial = math.max(serial, normalized.serial)
            entries[#entries + 1] = normalized
            if #entries >= MAX_HISTORY then break end
        end
    end
    table.sort(entries, function(a, b)
        local aSerial, bSerial = tonumber(a.serial) or 0, tonumber(b.serial) or 0
        if aSerial ~= bSerial then return aSerial < bSerial end
        return (tonumber(a.storageId) or 0) < (tonumber(b.storageId) or 0)
    end)
    while #entries > settings.maxHistory do table.remove(entries, 1) end
    return {
        settings = settings,
        history = { serial = serial, entries = entries },
        widgetWindow = type(value.widgetWindow) == "table" and DeepCopy(value.widgetWindow) or {},
    }
end

local function RebuildV18_145Canonical(value, stampedFingerprint, currentCanonical, rawEnvelope)
    value = type(value) == "table" and value or {}
    local source = value
    if type(rawEnvelope) == "table" then
        -- Current codec data must verify through the current codec. Never let a
        -- malformed current envelope fall back into historical-shape recovery.
        if rawEnvelope.codec ~= nil then return nil end
        if type(rawEnvelope.payload) == "table" then source = rawEnvelope.payload end
    end
    source = type(source) == "table" and source or {}
    local strictHistorical = NormalizeIndexWithWindow(source, "legacy_opaque_18_145")
    local recoveredEntriesHistorical = NormalizeHistoricalIndexWithRecoveredEntries(source)
    local store = P:GetStore(INDEX_STORE)
    if store == nil or stampedFingerprint == nil then return strictHistorical, NormalizeIndex(strictHistorical) end

    -- Runtime-only, shape-only evidence for the next RU Fresh Reload if the old
    -- fingerprint still cannot be reconstructed. No player names, damage values,
    -- serials, or death payload contents are exposed.
    local sourceHistory = type(source.history) == "table" and source.history or {}
    local sourceEntries = type(sourceHistory.entries) == "table" and sourceHistory.entries or {}
    local sourceSettings = type(source.settings) == "table" and source.settings or {}
    local sourceWindowRaw = type(source.widgetWindow) == "table" and source.widgetWindow or {}
    local strictCount = #strictHistorical.history.entries
    local recoveredCount = #recoveredEntriesHistorical.history.entries
    local missingDefaultTrue = 0
    for _, key in ipairs(LEGACY_DEFAULT_TRUE_SETTING_KEYS) do
        if sourceSettings[key] == nil and strictHistorical.settings[key] == true then
            missingDefaultTrue = missingDefaultTrue + 1
        end
    end

    local normalizedWindow = NormalizeWidgetWindow(source.widgetWindow)
    local missingWindowFields = 0
    for _, key in ipairs(LEGACY_WINDOW_RECOVERABLE_KEYS) do
        if sourceWindowRaw[key] == nil and normalizedWindow[key] ~= nil then
            missingWindowFields = missingWindowFields + 1
        end
    end

    local bases = { strictHistorical }
    if recoveredCount > strictCount then bases[#bases + 1] = recoveredEntriesHistorical end
    store.lastHistoricalRecoveryProbe = string.format(
        "histIpairs=%d/histPairs=%d/rawEntryKeys=%d/winKeys=%d/defaultTrueMissing=%d/winRecoverable=%d/bases=%d",
        strictCount, recoveredCount, CountTableEntries(sourceEntries), CountTableEntries(sourceWindowRaw),
        missingDefaultTrue, missingWindowFields, #bases)

    local function Matches(candidate)
        local fingerprint = P:FingerprintCanonicalValue(store, candidate)
        return fingerprint ~= nil and tostring(fingerprint) == tostring(stampedFingerprint)
    end

    local function TryBase(historical, baseIndex)
        if Matches(historical) then
            store.lastHistoricalRecoveryProbe = store.lastHistoricalRecoveryProbe .. "/matchBase=" .. tostring(baseIndex) .. "/mask=0"
            return historical, NormalizeIndex(historical)
        end

        local mutations = {}
        for _, key in ipairs(LEGACY_DEFAULT_TRUE_SETTING_KEYS) do
            if sourceSettings[key] == nil and historical.settings[key] == true then
                mutations[#mutations + 1] = { kind = "setting_false", key = key }
            end
        end

        local sourceWindow = type(historical.widgetWindow) == "table" and historical.widgetWindow or {}
        for _, key in ipairs(LEGACY_WINDOW_RECOVERABLE_KEYS) do
            if sourceWindow[key] == nil and normalizedWindow[key] ~= nil then
                mutations[#mutations + 1] = { kind = "window_restore", key = key, value = normalizedWindow[key] }
            end
        end

        if #mutations == 0 or #mutations > MAX_HISTORICAL_RECOVERY_MUTATIONS then return nil end
        local combinations = 2 ^ #mutations
        for mask = 1, combinations - 1 do
            local candidate = DeepCopy(historical)
            candidate.widgetWindow = DeepCopy(sourceWindow)
            local bits = mask
            for index = 1, #mutations do
                if bits % 2 == 1 then
                    local mutation = mutations[index]
                    if mutation.kind == "setting_false" then
                        candidate.settings[mutation.key] = false
                    else
                        candidate.widgetWindow[mutation.key] = mutation.value
                    end
                end
                bits = math.floor(bits / 2)
            end
            if Matches(candidate) then
                store.lastHistoricalRecoveryProbe = store.lastHistoricalRecoveryProbe
                    .. "/matchBase=" .. tostring(baseIndex) .. "/mask=" .. tostring(mask)
                return candidate, NormalizeIndex(candidate)
            end
        end
        return nil
    end

    for baseIndex, historical in ipairs(bases) do
        local candidate, recoveredDomain = TryBase(historical, baseIndex)
        if candidate ~= nil then return candidate, recoveredDomain end
    end
    return strictHistorical
end

-- .18.151 one-time known-stamp bridge. The user's RU client has carried the
-- SAME legacy v4 index stamp (770CB0B8) unchanged across .18.146-.18.150 while
-- current canonicalization changed and every exact historical-shape solver
-- remained unable to invert the native representation loss. Treating that
-- exact stamp as a migration identifier is safer than continuing to grow an
-- unbounded shape brute-force search. Unknown hashes still fail closed.
--
-- The bridge is reached only after Persistence has already verified the v6+
-- envelope seal + metadata/schema + encoded/decode budgets and after exact
-- historical reconstruction failed. This Store then performs a second strict
-- legacy-Domain shape validation before returning a CURRENT normalized Domain
-- for immediate codec-v1 restamp. It never clears the Store and never accepts a
-- different fingerprint.
local KNOWN_LEGACY_V4_INDEX_FINGERPRINTS = {
    ["770CB0B8"] = "ru_2026_09_07_precodec_v4_index",
}

local LEGACY_INDEX_TOP_KEYS = { settings=true, history=true, widgetWindow=true }
local LEGACY_SETTINGS_KEYS = { autoShow=true, windowMs=true, maxHistory=true, minDamage=true, showDebuffs=true }
local LEGACY_HISTORY_KEYS = { serial=true, entries=true }
local LEGACY_SUMMARY_KEYS = {
    serial=true, storageId=true, time=true, clock=true, windowMs=true, totalDamage=true,
    lethalSource=true, lethalAbility=true, lethalAmount=true, eventCount=true, debuffCount=true,
}
local LEGACY_WINDOW_KEYS = { opacity=true }
for _, key in ipairs(LEGACY_WINDOW_RECOVERABLE_KEYS) do LEGACY_WINDOW_KEYS[key] = true end

local function HasOnlyKeys(value, allowed)
    if type(value) ~= "table" then return false, "table_required" end
    for key in pairs(value) do
        if allowed[key] ~= true then return false, "unknown_key:" .. tostring(key) end
    end
    return true
end

local function ValidateLegacyIndexPayload(value)
    if type(value) ~= "table" then return false, "payload_required" end
    local ok, err = HasOnlyKeys(value, LEGACY_INDEX_TOP_KEYS)
    if ok ~= true then return false, "top:" .. tostring(err) end

    if type(value.settings) ~= "table" then return false, "settings_required" end
    ok, err = HasOnlyKeys(value.settings, LEGACY_SETTINGS_KEYS)
    if ok ~= true then return false, "settings:" .. tostring(err) end
    for _, key in ipairs({ "autoShow", "showDebuffs" }) do
        if value.settings[key] ~= nil and type(value.settings[key]) ~= "boolean" then
            return false, "settings_type:" .. key
        end
    end
    for _, key in ipairs({ "windowMs", "maxHistory", "minDamage" }) do
        if value.settings[key] ~= nil and tonumber(value.settings[key]) == nil then
            return false, "settings_number:" .. key
        end
    end

    if value.history ~= nil then
        if type(value.history) ~= "table" then return false, "history_type" end
        ok, err = HasOnlyKeys(value.history, LEGACY_HISTORY_KEYS)
        if ok ~= true then return false, "history:" .. tostring(err) end
        if value.history.serial ~= nil and tonumber(value.history.serial) == nil then return false, "history_serial" end
        if value.history.entries ~= nil then
            if type(value.history.entries) ~= "table" then return false, "entries_type" end
            local count, serialSeen, storageSeen = 0, {}, {}
            for _, row in pairs(value.history.entries) do
                count = count + 1
                if count > MAX_HISTORY then return false, "entries_overflow" end
                if type(row) ~= "table" then return false, "entry_type" end
                ok, err = HasOnlyKeys(row, LEGACY_SUMMARY_KEYS)
                if ok ~= true then return false, "entry:" .. tostring(err) end
                local serial = tonumber(row.serial)
                local storageId = tonumber(row.storageId)
                if serial == nil or serial < 1 then return false, "entry_serial" end
                if storageId == nil or storageId < 1 or storageId > RECORD_SLOTS then return false, "entry_storage" end
                serial = math.floor(serial); storageId = math.floor(storageId)
                if serialSeen[serial] == true then return false, "entry_serial_duplicate" end
                if storageSeen[storageId] == true then return false, "entry_storage_duplicate" end
                serialSeen[serial], storageSeen[storageId] = true, true
                for _, key in ipairs({ "time", "windowMs", "totalDamage", "lethalAmount", "eventCount", "debuffCount" }) do
                    if row[key] ~= nil and tonumber(row[key]) == nil then return false, "entry_number:" .. key end
                end
                for _, key in ipairs({ "clock", "lethalSource", "lethalAbility" }) do
                    if row[key] ~= nil and type(row[key]) ~= "string" then return false, "entry_text:" .. key end
                end
            end
        end
    end

    if value.widgetWindow ~= nil then
        if type(value.widgetWindow) ~= "table" then return false, "window_type" end
        ok, err = HasOnlyKeys(value.widgetWindow, LEGACY_WINDOW_KEYS)
        if ok ~= true then return false, "window:" .. tostring(err) end
        for _, key in ipairs({ "minimized", "locked", "userMoved" }) do
            if value.widgetWindow[key] ~= nil and type(value.widgetWindow[key]) ~= "boolean" then
                return false, "window_bool:" .. key
            end
        end
        for _, key in ipairs({ "width", "height", "opacity", "overallOpacity", "backgroundOpacity", "textOpacity",
            "fontScale", "x", "y", "offsetX", "offsetY", "savedUiScale" }) do
            if value.widgetWindow[key] ~= nil and tonumber(value.widgetWindow[key]) == nil then
                return false, "window_number:" .. key
            end
        end
        for _, key in ipairs({ "anchorH", "anchorV", "coordinateSpace" }) do
            if value.widgetWindow[key] ~= nil and type(value.widgetWindow[key]) ~= "string" then
                return false, "window_text:" .. key
            end
        end
    end
    return true
end

local function RecoverKnownLegacyV4Index(decoded, stampedFingerprint, currentCanonical, rawEnvelope)
    local stamp = tostring(stampedFingerprint or "")
    local label = KNOWN_LEGACY_V4_INDEX_FINGERPRINTS[stamp]
    if label == nil then return nil end
    if type(rawEnvelope) ~= "table" or rawEnvelope.codec ~= nil or type(rawEnvelope.payload) ~= "table" then
        return nil
    end
    local source = rawEnvelope.payload
    local valid, reason = ValidateLegacyIndexPayload(source)
    local store = P:GetStore(INDEX_STORE)
    if valid ~= true then
        if store ~= nil then
            store.lastHistoricalRecoveryProbe = tostring(store.lastHistoricalRecoveryProbe or "")
                .. "/knownStamp=" .. stamp .. "/knownShape=reject:" .. tostring(reason)
        end
        return nil
    end

    -- Preserve every still-present summary row even if native changed sequence
    -- keys into map keys; normalize all remaining settings/window values through
    -- the CURRENT Domain contract, then the existing codec writes a stable v1
    -- representation. Missing values that the native serializer irreversibly
    -- removed cannot be guessed; current Domain defaults apply only after the
    -- exact known legacy stamp + strict shape gate identifies this migration.
    local recovered = NormalizeHistoricalIndexWithRecoveredEntries(source)
    recovered = NormalizeIndex(recovered)
    if store ~= nil then
        store.lastHistoricalRecoveryProbe = tostring(store.lastHistoricalRecoveryProbe or "")
            .. "/knownStamp=" .. stamp .. "/knownShape=ok"
    end
    return recovered, label
end

F.StoreId = INDEX_STORE
F.IndexBudget = INDEX_BUDGET
F.RecordBudget = RECORD_BUDGET
F.MaxHistory = MAX_HISTORY
F.RecordSlots = RECORD_SLOTS
F.State = NormalizeIndex(F.State)
F.Records = type(F.Records) == "table" and F.Records or {}
F.RecordStoreIds = type(F.RecordStoreIds) == "table" and F.RecordStoreIds or {}
F.StoreLoaded = F.StoreLoaded == true

local function ApplyIndex(value) F.State = NormalizeIndex(value) end

if P:GetStore(INDEX_STORE) == nil then
    local store, err = P:RegisterV3Store({
        id = INDEX_STORE,
        owner = "v3.death_review",
        scope = P.Scope.Account,
        lifetime = P.Lifetime.Permanent,
        schemaVersion = INDEX_SCHEMA,
        legacySchemaVersion = 0,
        key = P.V3KeyPrefix .. "death_review_index",
        budget = INDEX_BUDGET,
        default = function() return NormalizeIndex(nil) end,
        get = function() return NormalizeIndex(F.State) end,
        apply = ApplyIndex,
        encode = EncodeIndex,
        decode = DecodeIndex,
        migrate = function(value) return NormalizeIndex(value) end,
        -- .18.145 stamped an opaque widgetWindow and RU may omit false-valued
        -- business/window members on disk. Persistence may test this bounded
        -- historical candidate only after the envelope seal succeeds. It is
        -- accepted only when it EXACTLY reproduces the existing stamp; the exact
        -- historical logical value is then normalized by the current Store and
        -- immediately re-stamped.
        rebuildCanonicalForIntegrity = RebuildV18_145Canonical,
        recoverKnownLegacyCanonical = RecoverKnownLegacyV4Index,
        -- The index Domain is a fixed-shape normalize output, so the canonical
        -- v3 fingerprint is stable across RU representation changes. This opt-in
        -- additionally allows the one-generation gated recovery for stores
        -- stamped by the legacy v2 raw-envelope contract (envelope seal +
        -- full decode/budget validation still required; re-stamped v3 at the
        -- upgrade save).
        allowIntegrityUpgrade = true,
    })
    if store == nil and S.DiagnosticsManager ~= nil and type(S.DiagnosticsManager.Error) == "function" then
        S.DiagnosticsManager:Error("death_review_v3", "DEATH_REVIEW_INDEX_STORE_REGISTER_FAILED", "死亡回顾索引存档注册失败", { error = tostring(err) })
    end
end

local function RecordStoreId(storageId)
    return "v3.death_review.record." .. tostring(ClampInt(storageId, 1, RECORD_SLOTS, 1))
end

function F:EnsureRecordStore(storageId)
    storageId = ClampInt(storageId, 1, RECORD_SLOTS, 1)
    local id = RecordStoreId(storageId)
    if P:GetStore(id) ~= nil then self.RecordStoreIds[storageId] = id; return id end
    local sid = storageId
    self.Records[sid] = self.Records[sid] ~= nil and NormalizeRecord(self.Records[sid]) or nil
    local store, err = P:RegisterV3Store({
        id = id,
        owner = "v3.death_review",
        scope = P.Scope.Account,
        lifetime = P.Lifetime.Permanent,
        schemaVersion = RECORD_SCHEMA,
        legacySchemaVersion = 0,
        key = RECORD_PREFIX .. tostring(sid),
        budget = RECORD_BUDGET,
        default = function() return nil end,
        get = function() return self.Records[sid] ~= nil and NormalizeRecord(self.Records[sid]) or nil end,
        apply = function(value) self.Records[sid] = type(value) == "table" and NormalizeRecord(value) or nil end,
        migrate = function(value) return type(value) == "table" and NormalizeRecord(value) or nil end,
    })
    if store == nil then return nil, err end
    self.RecordStoreIds[sid] = id
    return id
end

function F:LoadRecord(storageId)
    storageId = ClampInt(storageId, 1, RECORD_SLOTS, 1)
    local id, regErr = self:EnsureRecordStore(storageId)
    if id == nil then return nil, regErr end
    local loaded = type(P.IsStoreLoaded) == "function" and P:IsStoreLoaded(id) or false
    if loaded == true then return self.Records[storageId] ~= nil and DeepCopy(self.Records[storageId]) or nil end
    local status, _, err = P:LoadStore(id)
    if status == true or status == "empty" then
        if status == "empty" then self.Records[storageId] = nil end
        return self.Records[storageId] ~= nil and DeepCopy(self.Records[storageId]) or nil
    end
    return nil, err or tostring(status or "death record load failed")
end

function F:SaveRecord(storageId, record)
    storageId = ClampInt(storageId, 1, RECORD_SLOTS, 1)
    local id, regErr = self:EnsureRecordStore(storageId)
    if id == nil then return false, regErr end
    local previous = self.Records[storageId] ~= nil and DeepCopy(self.Records[storageId]) or nil
    self.Records[storageId] = NormalizeRecord(record)
    local ok, err = P:SaveStore(id, { consumeDirty = true, allowUnloadedWrite = true, reason = "death_review_record" })
    if ok ~= true then self.Records[storageId] = previous; return false, err end
    return true
end

function F:FindHistoryMeta(serial)
    serial = tonumber(serial)
    local entries = self.State.history.entries
    if serial == nil then return entries[#entries] end
    for index = #entries, 1, -1 do
        if tonumber(entries[index].serial) == serial then return entries[index] end
    end
    return nil
end

function F:ChooseFreeRecordSlot()
    local used = {}
    for _, row in ipairs(self.State.history.entries) do used[tonumber(row.storageId)] = true end
    for storageId = 1, RECORD_SLOTS do if used[storageId] ~= true then return storageId end end
    return nil
end

function F:CommitDeathRecord(record)
    local loaded, loadErr = self:EnsureStoreLoaded()
    if loaded ~= true then return false, loadErr or "死亡回顾设置读取失败" end
    local previousIndex = DeepCopy(self.State.history)
    local serial = math.max(0, tonumber(previousIndex.serial) or 0) + 1
    record = NormalizeRecord(record, serial)
    record.serial = serial
    local storageId = self:ChooseFreeRecordSlot()
    if storageId == nil then return false, "死亡回顾记录分片没有可用事务槽" end
    local recordOk, recordErr = self:SaveRecord(storageId, record)
    if recordOk ~= true then return false, recordErr end

    self.State.history.serial = serial
    self.State.history.entries[#self.State.history.entries + 1] = SummaryFromRecord(record, storageId)
    local maximum = ClampInt(self.State.settings.maxHistory, 1, MAX_HISTORY, 10)
    while #self.State.history.entries > maximum do table.remove(self.State.history.entries, 1) end
    local indexOk, indexErr = P:SaveStore(INDEX_STORE, { consumeDirty = true, reason = "death_review_index_commit" })
    if indexOk ~= true then
        self.State.history = previousIndex
        return false, indexErr
    end
    return true, DeepCopy(record)
end

function F:MarkStoreDirty(delayMs, reason)
    return P:MarkDirty(INDEX_STORE, tonumber(delayMs) or 350, reason or "death_review_changed")
end

function F:MutateStore(mutator, delayMs, reason, durable)
    return P:MutateStore(INDEX_STORE, function() return mutator() end, {
        delayMs = tonumber(delayMs) or 350, reason = tostring(reason or "death_review_changed"), durable = durable == true,
    })
end

function F:EnsureStoreLoaded()
    if type(P.IsStoreLoaded) == "function" and P:IsStoreLoaded(INDEX_STORE) == true then self.StoreLoaded = true; return true end
    local store = P:GetStore(INDEX_STORE)
    if store == nil then return false, "死亡回顾索引存档不可用" end
    local status, _, err = P:LoadStore(INDEX_STORE)
    if status ~= true and status ~= "empty" then return false, err or tostring(status or "读取失败") end
    if status == "empty" then ApplyIndex(nil) end
    self.StoreLoaded = true
    return true
end

function F:GetSettings() return self.State.settings end

function F:ApplySettingRaw(key, value)
    local settings = self.State.settings
    key = tostring(key or "")
    if key == "autoShow" then settings.autoShow = value == true
    elseif key == "windowMs" then settings.windowMs = ClampInt(value, 3000, 20000, 10000)
    elseif key == "maxHistory" then settings.maxHistory = ClampInt(value, 1, MAX_HISTORY, 10)
    elseif key == "minDamage" then settings.minDamage = ClampInt(value, 0, 5000, 0)
    elseif key == "showDebuffs" then settings.showDebuffs = value == true
    else return false, "unknown death review setting" end
    return true
end

function F:SetMaxHistoryPersistent(value)
    return self:MutateStore(function()
        self.State.settings.maxHistory = ClampInt(value, 1, MAX_HISTORY, 10)
        while #self.State.history.entries > self.State.settings.maxHistory do table.remove(self.State.history.entries, 1) end
        return true
    end, 0, "death_review_max_history", true)
end

function F:DeleteHistoryRecord(serial)
    local loaded, loadErr = self:EnsureStoreLoaded()
    if loaded ~= true then return false, loadErr or "死亡回顾设置读取失败" end
    serial = tonumber(serial)
    if serial == nil then return false, "死亡回顾记录编号无效" end
    local entries = self.State.history.entries
    local removeIndex, meta = nil, nil
    for index = #entries, 1, -1 do
        if tonumber(entries[index].serial) == serial then
            removeIndex, meta = index, DeepCopy(entries[index])
            break
        end
    end
    if removeIndex == nil or meta == nil then return false, "死亡回顾记录不存在" end

    -- The lightweight index is the logical authority. Remove from that index
    -- transactionally first; a stale physical shard can never resurrect a row.
    local ok, err = self:MutateStore(function()
        table.remove(self.State.history.entries, removeIndex)
        return true
    end, 0, "death_review_delete_record", true)
    if ok ~= true then return false, err end

    local storageId = tonumber(meta.storageId)
    if storageId ~= nil then
        self.Records[storageId] = nil
        local id = self:EnsureRecordStore(storageId)
        if id ~= nil and type(P.ClearStore) == "function" then
            local cleared = P:ClearStore(id, { reason = "death_review_delete_record" })
            if cleared ~= true and S.DiagnosticsManager ~= nil and type(S.DiagnosticsManager.WarningRateLimited) == "function" then
                S.DiagnosticsManager:WarningRateLimited("death_review_v3", "DEATH_REVIEW_RECORD_CLEANUP_PARTIAL", 3000,
                    "死亡回顾记录已从索引删除，但对应分片未能物理清理", { serial = tostring(serial), storageId = tostring(storageId) })
            end
        end
    end
    return true
end

function F:ClearHistoryStore()
    local loaded, loadErr = self:EnsureStoreLoaded()
    if loaded ~= true then return false, loadErr or "死亡回顾设置读取失败" end
    local previous = DeepCopy(self.State.history)
    self.State.history = { serial = math.max(0, tonumber(previous and previous.serial) or 0), entries = {} }
    local ok, err = P:SaveStore(INDEX_STORE, { consumeDirty = true, reason = "death_review_clear_history" })
    if ok ~= true then self.State.history = previous; return false, err end

    -- The authoritative index is already empty. Physical shards are then
    -- cleared best-effort; cleanup failure cannot resurrect visible history.
    local cleanupFailures = 0
    for storageId = 1, RECORD_SLOTS do
        local id = self:EnsureRecordStore(storageId)
        if id ~= nil and type(P.ClearStore) == "function" then
            local cleared = P:ClearStore(id, { reason = "death_review_clear_history" })
            if cleared ~= true then cleanupFailures = cleanupFailures + 1 end
        else
            cleanupFailures = cleanupFailures + 1
        end
    end
    if cleanupFailures > 0 and S.DiagnosticsManager ~= nil and type(S.DiagnosticsManager.WarningRateLimited) == "function" then
        S.DiagnosticsManager:WarningRateLimited("death_review_v3", "DEATH_REVIEW_SHARD_CLEANUP_PARTIAL", 3000,
            "死亡回顾索引已清空，但部分旧记录分片未能物理删除", { failures = cleanupFailures })
    end
    return true
end
