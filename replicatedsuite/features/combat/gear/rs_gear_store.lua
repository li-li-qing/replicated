------------------------------------------------------------------------
-- Replicated Suite V3 - Gear / Title Store
--
-- Character-scoped permanent storage. The lightweight set index and every
-- equipment/title payload are split into separate SaveData keys. Reliability
-- v3 further protects every payload with a two-bank A/B journal: the inactive
-- bank is written + readback-verified before the index pointer is committed.
-- A failed payload write or failed index commit therefore cannot destroy the
-- last index-referenced loadout.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local P = S.Persistence
if type(P) ~= "table" or type(P.RegisterV3Store) ~= "function" then return end

S.Features = S.Features or {}
S.Features.Gear = S.Features.Gear or {}
local F = S.Features.Gear

local INDEX_STORE = "v3.gear.index"
local PAYLOAD_PREFIX = P.V3KeyPrefix .. "gear_payload_"
local MAX_SETS = 40
local QUICK_SNAP_DISTANCE_DEFAULT = 16
local QUICK_BUTTON_GAP_DEFAULT = 0
local QUICK_SNAP_DISTANCE_MAX = 80
local QUICK_BUTTON_GAP_MAX = 40
local PAYLOAD_SCHEMA = 2
local PAYLOAD_FORMAT = 2
local VALID_BANK = { legacy = true, a = true, b = true }

-- Domain budgets remain deliberately bounded even though the on-disk payload
-- now uses a compact encoder. The domain snapshot is still inspected before
-- every save; the encoded envelope receives the framework's separate overhead.
local INDEX_BUDGET = { maxDepth = 6, maxNodes = 1280, maxStringBytes = 18000, maxEntriesPerTable = 160 }
local PAYLOAD_BUDGET = { maxDepth = 8, maxNodes = 640, maxStringBytes = 18000, maxEntriesPerTable = 64 }

local function Trim(value)
    return tostring(value or ""):match("^%s*(.-)%s*$") or ""
end

local function DeepCopy(value, seen)
    if type(value) ~= "table" then return value end
    seen = seen or {}
    if seen[value] ~= nil then return seen[value] end
    local out = {}; seen[value] = out
    for k, v in pairs(value) do
        if type(k) ~= "userdata" and type(v) ~= "userdata" and type(v) ~= "function" and type(v) ~= "thread" then
            out[DeepCopy(k, seen)] = DeepCopy(v, seen)
        end
    end
    return out
end

local function NormalizeBank(value)
    local text = Trim(value):lower()
    return VALID_BANK[text] == true and text or nil
end

local SLOT_DEFS = {}
for _, def in ipairs(S.Services and S.Services.GearV3 and S.Services.GearV3.EquipmentSlots or {}) do
    local slot = tonumber(def.slot)
    if slot ~= nil then SLOT_DEFS[slot] = def end
end

local function NormalizeItem(item)
    item = type(item) == "table" and item or {}
    local slot = tonumber(item.slot or item.s)
    local def = slot ~= nil and SLOT_DEFS[slot] or nil
    local empty = item.empty == true or item.e == true or item.e == 1
    local managedValue = item.managed
    if managedValue == nil then managedValue = item.m end
    return {
        slot = slot,
        key = def ~= nil and tostring(def.key or "") or Trim(item.key),
        slotName = def ~= nil and tostring(def.name or "") or Trim(item.slotName),
        alternative = def ~= nil and def.alternative == true or item.alternative == true,
        empty = empty,
        managed = (not empty) and managedValue ~= false and managedValue ~= 0,
        name = empty and nil or Trim(item.name or item.n),
        grade = empty and nil or tonumber(item.grade or item.g),
        itemType = empty and nil or (item.itemType ~= nil and item.itemType or item.t),
        icon = empty and nil or (item.icon ~= nil and item.icon or item.i),
        modifierSignature = empty and nil or Trim(item.modifierSignature or item.x),
    }
end

local function NormalizePackedAppellation(value)
    if type(value) ~= "table" then return nil end
    local source = type(value.values) == "table" and value.values or type(value.v) == "table" and value.v or value
    local result = { values = {} }
    for i = 1, 6 do
        local v = source[i]
        if type(v) == "string" or type(v) == "number" or type(v) == "boolean" then result.values[i] = v end
    end
    result.id = value.id ~= nil and value.id or value.i ~= nil and value.i or result.values[1]
    result.name = Trim(value.name or value.n)
    if result.name == "" then result.name = nil end
    return result
end

local function NormalizeTitle(title)
    title = type(title) == "table" and title or {}
    return {
        apply = title.apply == true or title.a == true or title.a == 1,
        showing = NormalizePackedAppellation(title.showing or title.s),
        effect = NormalizePackedAppellation(title.effect or title.e),
        displayName = Trim(title.displayName or title.d),
    }
end

local function NormalizePayload(value)
    value = type(value) == "table" and value or {}
    local sourceItems = type(value.items) == "table" and value.items or type(value.it) == "table" and value.it or {}
    local items = {}
    for _, item in ipairs(sourceItems) do
        if #items >= 19 then break end
        local normalized = NormalizeItem(item)
        if normalized.slot ~= nil then items[#items + 1] = normalized end
    end
    table.sort(items, function(a, b) return (tonumber(a.slot) or 0) < (tonumber(b.slot) or 0) end)
    local setId = Trim(value.setId or value.set)
    if setId == "" then setId = nil end
    local storageId = tonumber(value.storageId or value.sid)
    return {
        revision = math.max(0, math.floor(tonumber(value.revision or value.r) or 0)),
        configured = value.configured == true or value.c == true or value.c == 1,
        storageId = storageId ~= nil and math.max(1, math.floor(storageId)) or nil,
        setId = setId,
        items = items,
        title = NormalizeTitle(value.title or value.ti),
        capturedAt = tonumber(value.capturedAt or value.at),
    }
end

local function CompactPackedAppellation(value)
    value = NormalizePackedAppellation(value)
    if value == nil then return nil end
    local out = { v = {} }
    for i = 1, 6 do if value.values[i] ~= nil then out.v[i] = value.values[i] end end
    if value.id ~= nil then out.i = value.id end
    if value.name ~= nil then out.n = value.name end
    return out
end

-- Compact on-disk representation. Slot labels/keys/alternative flags are static
-- service metadata and are reconstructed from slot id on load rather than being
-- duplicated 19 times in every SaveData payload.
local function EncodeCompactPayload(value)
    value = NormalizePayload(value)
    local raw = {
        v = PAYLOAD_FORMAT,
        r = value.revision,
        c = value.configured == true,
        sid = value.storageId,
        set = value.setId,
        at = value.capturedAt,
        it = {},
        ti = {
            a = value.title and value.title.apply == true or false,
            d = value.title and value.title.displayName or "",
            s = value.title and CompactPackedAppellation(value.title.showing) or nil,
            e = value.title and CompactPackedAppellation(value.title.effect) or nil,
        },
    }
    for _, item in ipairs(value.items or {}) do
        local row = { s = item.slot, e = item.empty == true, m = item.managed ~= false }
        if item.empty ~= true then
            row.n, row.g, row.t, row.i, row.x = item.name, item.grade, item.itemType, item.icon, item.modifierSignature
        end
        raw.it[#raw.it + 1] = row
    end
    return raw
end

local function DecodePayloadEnvelope(raw)
    if type(raw) ~= "table" then return nil, "gear payload raw must be table" end
    -- Schema 1 / pre-Reliability-v3 payloads used the framework default wrapper.
    if raw.payload ~= nil then return NormalizePayload(raw.payload), nil end
    if tonumber(raw.v) ~= PAYLOAD_FORMAT then return nil, "unsupported gear payload format:" .. tostring(raw.v) end
    return NormalizePayload(raw), nil
end

local function NormalizeFingerprint(value)
    local text = Trim(value)
    if text == "" then return nil end
    if #text > 32 then text = string.sub(text, 1, 32) end
    return text
end

local function NormalizeSetMeta(value, index)
    value = type(value) == "table" and value or {}
    local storageId = math.max(1, math.floor(tonumber(value.storageId) or tonumber(index) or 1))
    local quickX, quickY = tonumber(value.quickX), tonumber(value.quickY)
    local quickCustomized = value.quickPositionCustomized == true and quickX ~= nil and quickY ~= nil
    local quickCoordinateSpace = tostring(value.quickCoordinateSpace or "")
    local quickAnchorH = tostring(value.quickAnchorH or "")
    local quickAnchorV = tostring(value.quickAnchorV or "")
    local quickOffsetX, quickOffsetY = tonumber(value.quickOffsetX), tonumber(value.quickOffsetY)
    local quickResponsive = quickCustomized
        and quickCoordinateSpace == "logical-edge-v1"
        and (quickAnchorH == "LEFT" or quickAnchorH == "RIGHT")
        and (quickAnchorV == "TOP" or quickAnchorV == "BOTTOM")
        and quickOffsetX ~= nil and quickOffsetY ~= nil
    return {
        id = Trim(value.id) ~= "" and Trim(value.id) or ("set_" .. tostring(index or storageId)),
        name = Trim(value.name) ~= "" and Trim(value.name) or ("换装" .. tostring(index or storageId)),
        order = math.max(1, math.floor(tonumber(value.order) or tonumber(index) or 1)),
        storageId = storageId,
        configured = value.configured == true,
        quick = value.quick ~= false,
        quickX = quickCustomized and math.floor(quickX + 0.5) or nil,
        quickY = quickCustomized and math.floor(quickY + 0.5) or nil,
        quickPositionCustomized = quickCustomized,
        -- Responsive screen-button placement. quickX/quickY remain as the
        -- backward-compatible last logical TOPLEFT coordinate; the edge anchor
        -- is the authoritative placement once available so resolution changes
        -- can re-resolve without rewriting the user's saved layout.
        quickCoordinateSpace = quickResponsive and "logical-edge-v1" or nil,
        quickAnchorH = quickResponsive and quickAnchorH or nil,
        quickAnchorV = quickResponsive and quickAnchorV or nil,
        quickOffsetX = quickResponsive and math.max(0, math.floor(quickOffsetX + 0.5)) or nil,
        quickOffsetY = quickResponsive and math.max(0, math.floor(quickOffsetY + 0.5)) or nil,
        payloadRevision = math.max(0, math.floor(tonumber(value.payloadRevision) or 0)),
        payloadBank = NormalizeBank(value.payloadBank),
        payloadFingerprint = NormalizeFingerprint(value.payloadFingerprint),
        backupPayloadBank = NormalizeBank(value.backupPayloadBank),
        backupPayloadRevision = math.max(0, math.floor(tonumber(value.backupPayloadRevision) or 0)),
        backupPayloadFingerprint = NormalizeFingerprint(value.backupPayloadFingerprint),
    }
end

-- Kept under the historical quickHud key for schema compatibility, but V3 M4
-- no longer owns a large HUD window. This table stores GLOBAL behavior for the
-- independent per-plan screen buttons only.
local function NormalizeQuickHud(value)
    value = type(value) == "table" and value or {}
    local buttonMode = tostring(value.layoutMode or "") == "buttons-v1"
    local visible = true
    if buttonMode then visible = value.visible ~= false end
    local snapDistance = math.floor((tonumber(value.snapDistance) or QUICK_SNAP_DISTANCE_DEFAULT) + 0.5)
    local buttonGap = math.floor((tonumber(value.buttonGap) or QUICK_BUTTON_GAP_DEFAULT) + 0.5)
    snapDistance = math.max(1, math.min(QUICK_SNAP_DISTANCE_MAX, snapDistance))
    buttonGap = math.max(0, math.min(QUICK_BUTTON_GAP_MAX, buttonGap))
    return {
        layoutMode = "buttons-v1",
        visible = visible,
        locked = value.locked == true,
        snapEnabled = value.snapEnabled ~= false,
        snapDistance = snapDistance,
        buttonGap = buttonGap,
        overallOpacity = math.max(0, math.min(1, tonumber(value.overallOpacity) or 0.94)),
        backgroundOpacity = math.max(0, math.min(1, tonumber(value.backgroundOpacity) or 1.0)),
        textOpacity = math.max(0, math.min(1, tonumber(value.textOpacity) or 1.0)),
    }
end

local function NormalizeIndex(value)
    value = type(value) == "table" and value or {}
    local sets, maxStorage = {}, 0
    for index, row in ipairs(type(value.sets) == "table" and value.sets or {}) do
        if #sets >= MAX_SETS then break end
        local normalized = NormalizeSetMeta(row, index)
        maxStorage = math.max(maxStorage, normalized.storageId)
        sets[#sets + 1] = normalized
    end
    table.sort(sets, function(a, b)
        if a.order ~= b.order then return a.order < b.order end
        return a.id < b.id
    end)
    for index, set in ipairs(sets) do set.order = index end
    return {
        revision = math.max(0, math.floor(tonumber(value.revision) or 0)),
        nextId = math.max(1, math.floor(tonumber(value.nextId) or (#sets + 1))),
        nextStorageId = math.max(maxStorage + 1, math.floor(tonumber(value.nextStorageId) or 1)),
        sets = sets,
        quickHud = NormalizeQuickHud(value.quickHud),
    }
end

F.IndexBudget = INDEX_BUDGET
F.PayloadBudget = PAYLOAD_BUDGET
F.PayloadSchemaVersion = PAYLOAD_SCHEMA
F.PayloadJournalContractVersion = 2
F.PayloadIntegrityContractVersion = 1
F.PayloadBanks = { "a", "b" }

F.State = NormalizeIndex(F.State)
F.Payloads = type(F.Payloads) == "table" and F.Payloads or {}
F.PayloadStoreIds = type(F.PayloadStoreIds) == "table" and F.PayloadStoreIds or {}
F.StoreLoaded = F.StoreLoaded == true

local function ApplyIndex(value)
    F.State = NormalizeIndex(value)
end

if P:GetStore(INDEX_STORE) == nil then
    local store, err = P:RegisterV3Store({
        id = INDEX_STORE,
        owner = "v3.gear",
        scope = P.Scope.Character,
        lifetime = P.Lifetime.Permanent,
        schemaVersion = 5,
        legacySchemaVersion = 4,
        key = P.V3KeyPrefix .. "gear_index",
        budget = INDEX_BUDGET,
        verifyAfterSave = true,
        default = function() return NormalizeIndex(nil) end,
        get = function() return NormalizeIndex(F.State) end,
        apply = ApplyIndex,
        migrate = function(value) return NormalizeIndex(value) end,
    })
    if store == nil and S.DiagnosticsManager ~= nil and type(S.DiagnosticsManager.Error) == "function" then
        S.DiagnosticsManager:Error("gear_v3", "GEAR_INDEX_STORE_REGISTER_FAILED", "换装索引存档注册失败", { error = tostring(err) })
    end
end

local function PayloadCacheKey(storageId, bank)
    return tostring(math.max(1, math.floor(tonumber(storageId) or 1))) .. ":" .. tostring(NormalizeBank(bank) or "legacy")
end

local function PayloadStoreId(storageId, bank)
    storageId = math.max(1, math.floor(tonumber(storageId) or 1))
    bank = NormalizeBank(bank) or "legacy"
    if bank == "legacy" then return "v3.gear.payload." .. tostring(storageId) end
    return "v3.gear.payload." .. tostring(storageId) .. "." .. bank
end

local function PayloadSaveKey(storageId, bank)
    storageId = math.max(1, math.floor(tonumber(storageId) or 1))
    bank = NormalizeBank(bank) or "legacy"
    if bank == "legacy" then return PAYLOAD_PREFIX .. tostring(storageId) end
    return PAYLOAD_PREFIX .. tostring(storageId) .. "_" .. bank
end

function F:PayloadFingerprint(payload)
    if type(P.FingerprintPayload) ~= "function" then return nil, "persistence fingerprint unavailable" end
    return P:FingerprintPayload(NormalizePayload(payload), PAYLOAD_BUDGET)
end

-- A configured loadout is never legitimately an empty shell. SaveDraft already
-- enforces the same business rule before writing; repeating the invariant here
-- turns a partially truncated historical shard into an explicit recovery case
-- instead of letting Apply/Validate continue with missing equipment identity.
function F:ValidatePayloadStructure(payload)
    payload = NormalizePayload(payload)
    if payload.configured ~= true then return true end
    local managed = 0
    for _, item in ipairs(payload.items or {}) do
        if item.empty ~= true and item.managed ~= false then
            if tonumber(item.slot) == nil then return false, "managed item missing slot" end
            if Trim(item.name) == "" then return false, "managed item missing name:" .. tostring(item.slot) end
            managed = managed + 1
        end
    end
    local titleManaged = type(payload.title) == "table" and payload.title.apply == true
    if titleManaged then
        local effect = payload.title.effect
        if type(effect) ~= "table" or effect.id == nil or effect.id == false or effect.id == 0 or Trim(effect.id) == "" then
            return false, "managed title missing effect id"
        end
    end
    if managed <= 0 and not titleManaged then return false, "configured payload has no managed content" end
    return true
end

function F:EnsurePayloadStore(storageId, bank)
    storageId = math.max(1, math.floor(tonumber(storageId) or 1))
    bank = NormalizeBank(bank) or "legacy"
    local id = PayloadStoreId(storageId, bank)
    local cacheKey = PayloadCacheKey(storageId, bank)
    if P:GetStore(id) ~= nil then self.PayloadStoreIds[cacheKey] = id; return id end
    self.Payloads[cacheKey] = NormalizePayload(self.Payloads[cacheKey])
    local sid, bankName, localCacheKey = storageId, bank, cacheKey
    local store, err = P:RegisterV3Store({
        id = id,
        owner = "v3.gear",
        scope = P.Scope.Character,
        lifetime = P.Lifetime.Permanent,
        schemaVersion = PAYLOAD_SCHEMA,
        legacySchemaVersion = 1,
        key = PayloadSaveKey(sid, bankName),
        budget = PAYLOAD_BUDGET,
        verifyAfterSave = bankName ~= "legacy",
        recoverableReplacement = bankName ~= "legacy",
        default = function() return NormalizePayload(nil) end,
        get = function() return NormalizePayload(F.Payloads[localCacheKey]) end,
        apply = function(value) F.Payloads[localCacheKey] = NormalizePayload(value) end,
        encode = EncodeCompactPayload,
        decode = DecodePayloadEnvelope,
        migrate = function(value) return NormalizePayload(value) end,
    })
    if store == nil then return nil, err end
    self.PayloadStoreIds[localCacheKey] = id
    return id
end

function F:LoadPayload(storageId, bank, options)
    options = type(options) == "table" and options or {}
    storageId = math.max(1, math.floor(tonumber(storageId) or 1))
    bank = NormalizeBank(bank) or "legacy"
    local id, regErr = self:EnsurePayloadStore(storageId, bank)
    if id == nil then return nil, regErr end
    local cacheKey = PayloadCacheKey(storageId, bank)
    local loaded, loadStatus = false, nil
    if type(P.IsStoreLoaded) == "function" then loaded, loadStatus = P:IsStoreLoaded(id) end
    if loaded == true and options.forceReload ~= true then return DeepCopy(self.Payloads[cacheKey]), nil end
    local store = type(P.GetStore) == "function" and P:GetStore(id) or nil
    if options.forceReload ~= true and type(store) == "table" and store.loaded == true and store.writeFenced == true then
        return nil, store.lastError or store.writeFenceReason or tostring(loadStatus or "payload load fenced")
    end
    local status, _, err = P:LoadStore(id, options.forceReload == true and { discardDirty = false } or nil)
    if status == true or status == "empty" then
        if status == "empty" then self.Payloads[cacheKey] = NormalizePayload(nil) end
        return DeepCopy(self.Payloads[cacheKey]), nil
    end
    return nil, err or tostring(status or "payload load failed")
end

local function EmitRecovery(set, activeBank, backupBank, activeErr)
    if S.DiagnosticsManager ~= nil and type(S.DiagnosticsManager.WarningRateLimited) == "function" then
        S.DiagnosticsManager:WarningRateLimited("gear_v3", "GEAR_PAYLOAD_BANK_RECOVERED", 3000,
            "换装主分片不可用，已使用上一份已验证分片继续工作", {
                setId = tostring(set and set.id or ""), storageId = tostring(set and set.storageId or ""),
                activeBank = tostring(activeBank or ""), backupBank = tostring(backupBank or ""), error = tostring(activeErr or "unknown"),
            })
    end
end

function F:LoadPayloadForSet(set)
    if type(set) ~= "table" then return nil, "换装方案元数据无效" end
    local storageId = math.max(1, math.floor(tonumber(set.storageId) or 1))
    local configured = set.configured == true
    local activeBank = NormalizeBank(set.payloadBank) or "legacy"
    local activeFingerprint = NormalizeFingerprint(set.payloadFingerprint)

    local function Try(bank, expectedFingerprint)
        bank = NormalizeBank(bank)
        if bank == nil then return nil, nil, "payload bank invalid" end
        local payload, loadErr = self:LoadPayload(storageId, bank)
        if payload == nil then return nil, nil, loadErr end
        if payload.storageId ~= nil and tonumber(payload.storageId) ~= storageId then return nil, nil, "payload storageId mismatch" end
        if payload.setId ~= nil and Trim(payload.setId) ~= "" and tostring(payload.setId) ~= tostring(set.id) then return nil, nil, "payload setId mismatch" end
        if configured and payload.configured ~= true then return nil, nil, "configured index points to empty payload" end
        local structureOk, structureErr = self:ValidatePayloadStructure(payload)
        if structureOk ~= true then return nil, nil, "payload structure invalid:" .. tostring(structureErr or "unknown") end
        local fingerprint, fingerprintErr = self:PayloadFingerprint(payload)
        if fingerprint == nil then return nil, nil, fingerprintErr end
        if expectedFingerprint ~= nil and tostring(fingerprint) ~= tostring(expectedFingerprint) then
            return nil, nil, "payload fingerprint mismatch:" .. tostring(expectedFingerprint) .. ">" .. tostring(fingerprint)
        end
        return payload, fingerprint, nil
    end

    local payload, fingerprint, activeErr = Try(activeBank, activeFingerprint)
    if payload ~= nil then return payload, nil, { bank = activeBank, fingerprint = fingerprint, recovered = false } end

    local backupBank = NormalizeBank(set.backupPayloadBank)
    local backupFingerprint = NormalizeFingerprint(set.backupPayloadFingerprint)
    if backupBank ~= nil and backupBank ~= activeBank then
        local backupPayload, backupActualFingerprint, backupErr = Try(backupBank, backupFingerprint)
        if backupPayload ~= nil then
            EmitRecovery(set, activeBank, backupBank, activeErr)
            return backupPayload, nil, { bank = backupBank, fingerprint = backupActualFingerprint, recovered = true, activeError = activeErr }
        end
        activeErr = tostring(activeErr or "active payload unavailable") .. "; backup=" .. tostring(backupErr or "unavailable")
    end

    -- Schema 4 indexes did not contain bank metadata. The historical single-key
    -- shard remains readable forever; it is only retired from the write path.
    if activeBank ~= "legacy" and backupBank ~= "legacy" then
        local legacyPayload, legacyFingerprint, legacyErr = Try("legacy", nil)
        if legacyPayload ~= nil and legacyPayload.configured == true then
            EmitRecovery(set, activeBank, "legacy", activeErr)
            return legacyPayload, nil, { bank = "legacy", fingerprint = legacyFingerprint, recovered = true, activeError = activeErr }
        end
        activeErr = tostring(activeErr or "active payload unavailable") .. "; legacy=" .. tostring(legacyErr or "unavailable")
    end

    return nil, "换装方案分片不可用：" .. tostring(activeErr or "unknown")
end

function F:SavePayload(storageId, payload, bank)
    storageId = math.max(1, math.floor(tonumber(storageId) or 1))
    bank = NormalizeBank(bank)
    if bank ~= "a" and bank ~= "b" then return false, "gear payload writes require bank a/b" end
    local id, regErr = self:EnsurePayloadStore(storageId, bank)
    if id == nil then return false, regErr end
    local cacheKey = PayloadCacheKey(storageId, bank)
    local previous = DeepCopy(self.Payloads[cacheKey])
    self.Payloads[cacheKey] = NormalizePayload(payload)
    local ok, err = P:SaveStore(id, {
        consumeDirty = true,
        allowUnloadedWrite = true,
        verifyAfterSave = true,
        replaceCorrupt = true,
        reason = "gear_payload_bank_replace",
    })
    if ok ~= true then self.Payloads[cacheKey] = previous; return false, err end
    local fingerprint, fingerprintErr = self:PayloadFingerprint(self.Payloads[cacheKey])
    if fingerprint == nil then self.Payloads[cacheKey] = previous; return false, fingerprintErr end
    return true, nil, fingerprint
end

function F:ClearPayload(storageId)
    storageId = math.max(1, math.floor(tonumber(storageId) or 1))
    if type(P.ClearStore) ~= "function" then return false, "persistence ClearStore unavailable" end
    local failures = {}
    for _, bank in ipairs({ "legacy", "a", "b" }) do
        local id, regErr = self:EnsurePayloadStore(storageId, bank)
        if id == nil then
            failures[#failures + 1] = tostring(bank) .. ":" .. tostring(regErr or "register failed")
        else
            local cleared, clearErr = P:ClearStore(id, { reason = "gear_clear_payload_" .. bank })
            if cleared ~= true then failures[#failures + 1] = tostring(bank) .. ":" .. tostring(clearErr or "clear failed") end
        end
    end
    if #failures > 0 then return false, table.concat(failures, "; ") end
    return true
end

function F:EnsureStoreLoaded()
    if type(P.IsStoreLoaded) == "function" and P:IsStoreLoaded(INDEX_STORE) == true then self.StoreLoaded = true; return true end
    local status, _, err = P:LoadStore(INDEX_STORE)
    if status ~= true and status ~= "empty" then return false, err or tostring(status or "读取换装索引失败") end
    if status == "empty" then ApplyIndex(nil) end
    self.StoreLoaded = true
    return true
end

function F:MarkIndexDirty(delayMs, reason)
    local previousRevision = math.max(0, math.floor(tonumber(self.State.revision) or 0))
    self.State.revision = previousRevision + 1
    local marked, markErr = P:MarkDirty(INDEX_STORE, tonumber(delayMs) or 300, reason or "gear_index_changed")
    if marked ~= true then self.State.revision = previousRevision end
    return marked, markErr
end

function F:MutateIndex(mutator, delayMs, reason, durable)
    return P:MutateStore(INDEX_STORE, function()
        local ok, err = mutator()
        if ok == false then return false, err end
        self.State.revision = math.max(0, math.floor(tonumber(self.State.revision) or 0)) + 1
        return true
    end, { delayMs = tonumber(delayMs) or 300, reason = tostring(reason or "gear_index_changed"), durable = durable == true })
end

function F:SaveIndexNow(reason)
    local loaded, loadErr = self:EnsureStoreLoaded()
    if loaded ~= true then return false, loadErr or "读取换装索引失败" end
    local previous = math.max(0, math.floor(tonumber(self.State.revision) or 0))
    self.State.revision = previous + 1
    local ok, err = P:SaveStore(INDEX_STORE, { consumeDirty = true, reason = reason })
    if ok ~= true then self.State.revision = previous end
    return ok, err
end

F.IndexStoreId = INDEX_STORE
F.MaxSets = MAX_SETS
F.DeepCopy = DeepCopy
F.NormalizePayload = NormalizePayload
F.NormalizePayloadBank = NormalizeBank
F.NormalizeQuickHud = NormalizeQuickHud
F.PayloadCodec = { contractVersion = PAYLOAD_FORMAT, Encode = EncodeCompactPayload, Decode = DecodePayloadEnvelope }
