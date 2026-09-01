------------------------------------------------------------------------
-- Replicated Suite V3 - Gear / Title Store
--
-- Character-scoped permanent storage. The lightweight set index and every
-- equipment/title payload are deliberately split into separate SaveData keys;
-- RU clients have previously truncated large aggregate Gear tables silently.
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

-- These budgets are sized against the FINAL SaveData envelope, not only the
-- Domain table. A fully populated 19-slot loadout is ~511 nodes before the
-- persistence metadata wrapper and ~531 nodes after encoding. Keep bounded
-- headroom without falling back to the framework-wide 4096-node allowance.
local INDEX_BUDGET = { maxDepth = 6, maxNodes = 1120, maxStringBytes = 16000, maxEntriesPerTable = 128 }
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

local function NormalizeItem(item)
    item = type(item) == "table" and item or {}
    local empty = item.empty == true
    return {
        slot = tonumber(item.slot),
        key = Trim(item.key),
        slotName = Trim(item.slotName),
        alternative = item.alternative == true,
        empty = empty,
        managed = empty and false or item.managed ~= false,
        name = empty and nil or Trim(item.name),
        grade = empty and nil or tonumber(item.grade),
        itemType = empty and nil or item.itemType,
        icon = empty and nil or item.icon,
        modifierSignature = empty and nil or Trim(item.modifierSignature),
    }
end

local function NormalizePackedAppellation(value)
    if type(value) ~= "table" then return nil end
    local result = { values = {} }
    for i = 1, 6 do
        local v = type(value.values) == "table" and value.values[i] or value[i]
        if type(v) == "string" or type(v) == "number" or type(v) == "boolean" then result.values[i] = v end
    end
    result.id = value.id ~= nil and value.id or result.values[1]
    result.name = Trim(value.name)
    if result.name == "" then result.name = nil end
    return result
end

local function NormalizeTitle(title)
    title = type(title) == "table" and title or {}
    return {
        apply = title.apply == true,
        showing = NormalizePackedAppellation(title.showing),
        effect = NormalizePackedAppellation(title.effect),
        displayName = Trim(title.displayName),
    }
end

local function NormalizePayload(value)
    value = type(value) == "table" and value or {}
    local items = {}
    for _, item in ipairs(type(value.items) == "table" and value.items or {}) do
        if #items >= 19 then break end
        local normalized = NormalizeItem(item)
        if normalized.slot ~= nil then items[#items + 1] = normalized end
    end
    return {
        revision = math.max(0, math.floor(tonumber(value.revision) or 0)),
        configured = value.configured == true,
        items = items,
        title = NormalizeTitle(value.title),
        capturedAt = tonumber(value.capturedAt),
    }
end

local function NormalizeSetMeta(value, index)
    value = type(value) == "table" and value or {}
    local storageId = math.max(1, math.floor(tonumber(value.storageId) or tonumber(index) or 1))
    local quickX, quickY = tonumber(value.quickX), tonumber(value.quickY)
    local quickCustomized = value.quickPositionCustomized == true and quickX ~= nil and quickY ~= nil
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
        payloadRevision = math.max(0, math.floor(tonumber(value.payloadRevision) or 0)),
    }
end

-- Kept under the historical quickHud key for schema compatibility, but V3 M4
-- no longer owns a large HUD window. This table now stores GLOBAL behavior for
-- the independent per-plan screen buttons only.
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
        -- The obsolete M2 big-window visibility must not make all restored
        -- per-plan buttons disappear. Once migrated, the user's explicit
        -- global show/hide choice remains authoritative.
        visible = visible,
        locked = value.locked == true,
        -- Quick-button snapping is a user preference, not a layout invariant.
        -- Keep it character-scoped and exact-entry friendly so players can
        -- freely disable snapping or tune the magnetic range/gap.
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
        schemaVersion = 4,
        legacySchemaVersion = 3,
        key = P.V3KeyPrefix .. "gear_index",
        budget = INDEX_BUDGET,
        default = function() return NormalizeIndex(nil) end,
        get = function() return NormalizeIndex(F.State) end,
        apply = ApplyIndex,
        migrate = function(value) return NormalizeIndex(value) end,
    })
    if store == nil and S.DiagnosticsManager ~= nil and type(S.DiagnosticsManager.Error) == "function" then
        S.DiagnosticsManager:Error("gear_v3", "GEAR_INDEX_STORE_REGISTER_FAILED", "换装索引存档注册失败", { error = tostring(err) })
    end
end

local function PayloadStoreId(storageId)
    return "v3.gear.payload." .. tostring(math.max(1, math.floor(tonumber(storageId) or 1)))
end

function F:EnsurePayloadStore(storageId)
    storageId = math.max(1, math.floor(tonumber(storageId) or 1))
    local id = PayloadStoreId(storageId)
    if P:GetStore(id) ~= nil then self.PayloadStoreIds[storageId] = id; return id end
    self.Payloads[storageId] = NormalizePayload(self.Payloads[storageId])
    local sid = storageId
    local store, err = P:RegisterV3Store({
        id = id,
        owner = "v3.gear",
        scope = P.Scope.Character,
        lifetime = P.Lifetime.Permanent,
        schemaVersion = 1,
        legacySchemaVersion = 0,
        key = PAYLOAD_PREFIX .. tostring(sid),
        budget = PAYLOAD_BUDGET,
        default = function() return NormalizePayload(nil) end,
        get = function() return NormalizePayload(F.Payloads[sid]) end,
        apply = function(value) F.Payloads[sid] = NormalizePayload(value) end,
        migrate = function(value) return NormalizePayload(value) end,
    })
    if store == nil then return nil, err end
    self.PayloadStoreIds[sid] = id
    return id
end

function F:LoadPayload(storageId)
    storageId = math.max(1, math.floor(tonumber(storageId) or 1))
    local id, regErr = self:EnsurePayloadStore(storageId)
    if id == nil then return nil, regErr end
    local loaded = type(P.IsStoreLoaded) == "function" and P:IsStoreLoaded(id) or false
    if loaded == true then return DeepCopy(self.Payloads[storageId]), nil end
    local status, _, err = P:LoadStore(id)
    if status == true or status == "empty" then
        if status == "empty" then self.Payloads[storageId] = NormalizePayload(nil) end
        return DeepCopy(self.Payloads[storageId]), nil
    end
    return nil, err or tostring(status or "payload load failed")
end

function F:SavePayload(storageId, payload)
    storageId = math.max(1, math.floor(tonumber(storageId) or 1))
    local id, regErr = self:EnsurePayloadStore(storageId)
    if id == nil then return false, regErr end
    local previous = DeepCopy(self.Payloads[storageId])
    self.Payloads[storageId] = NormalizePayload(payload)
    local ok, err = P:SaveStore(id, { consumeDirty = true })
    if ok ~= true then self.Payloads[storageId] = previous; return false, err end
    return true
end

function F:ClearPayload(storageId)
    storageId = math.max(1, math.floor(tonumber(storageId) or 1))
    local id = self:EnsurePayloadStore(storageId)
    if id == nil then return false end
    if type(P.ClearStore) ~= "function" then return false, "persistence ClearStore unavailable" end
    return P:ClearStore(id, { reason = "gear_clear_payload" })
end

function F:EnsureStoreLoaded()
    if self.StoreLoaded == true then return true end
    local status, _, err = P:LoadStore(INDEX_STORE)
    if status ~= true and status ~= "empty" then return false, err or tostring(status or "读取换装索引失败") end
    if status == "empty" then ApplyIndex(nil) end
    self.StoreLoaded = true
    return true
end

function F:MarkIndexDirty(delayMs, reason)
    self.State.revision = math.max(0, math.floor(tonumber(self.State.revision) or 0)) + 1
    return P:MarkDirty(INDEX_STORE, tonumber(delayMs) or 300, reason or "gear_index_changed")
end

function F:SaveIndexNow(reason)
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
F.NormalizeQuickHud = NormalizeQuickHud
