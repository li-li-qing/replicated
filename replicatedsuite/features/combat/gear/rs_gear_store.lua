------------------------------------------------------------------------
-- Replicated Suite · 装备与称号方案设置存储
-- 作者：Replicated
-- QQ群：1104129461
--
-- 角色永久存储将轻量方案索引与装备/称号 payload 分开 SaveData key；每 payload 使用双库 A/B journal。
-- 先写 inactive 库并读回核实，再提交索引指针；payload 写入或索引提交失败不能破坏最后仍被索引引用的装备方案。
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

-- 磁盘 payload 虽采用紧凑编码，Domain 预算仍有界；每次保存前检查 Domain 快照，编码封装另有框架开销。
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
local SLOT_ORDER = {}
for index, def in ipairs(S.Services and S.Services.GearV3 and S.Services.GearV3.EquipmentSlots or {}) do
    local slot = tonumber(def.slot)
    if slot ~= nil then
        SLOT_DEFS[slot] = def
        SLOT_ORDER[slot] = index
    end
end

local function EquipmentOrder(slot)
    slot = tonumber(slot)
    return slot ~= nil and (SLOT_ORDER[slot] or (1000 + slot)) or 9999
end

local function NormalizeRingIdentity(value)
    -- 可选的戒指身份元数据；旧方案保持 nil，不改变旧载荷 canonical，也不自动补写/升级用户存档。
    if type(value)~='table' then return nil end
    return {version=tonumber(value.version),status=Trim(value.status),signature=value.signature~=nil and Trim(value.signature) or nil,
        summary=Trim(value.summary),reason=value.reason~=nil and Trim(value.reason) or nil}
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
        ringIdentity = not empty and (slot==12 or slot==13) and NormalizeRingIdentity(item.ringIdentity or item.ri) or nil,
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
    -- 保存payload顺序是业务/表现语义，不是稀疏Native槽ID顺序；Capture遵守GearV3.EquipmentSlots，必须保留此顺序，避免获取当前→保存→重载后列表重排。
    table.sort(items, function(a, b)
        local ao, bo = EquipmentOrder(a and a.slot), EquipmentOrder(b and b.slot)
        if ao ~= bo then return ao < bo end
        return (tonumber(a and a.slot) or 0) < (tonumber(b and b.slot) or 0)
    end)
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

-- 紧凑磁盘表示：槽标签/key/替代标志是 Service 静态元数据，加载按 slot ID 重建，不能在每个 payload 重复 19 次。
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
            if item.ringIdentity~=nil then row.ri=DeepCopy(item.ringIdentity) end
        end
        raw.it[#raw.it + 1] = row
    end
    return raw
end

-- compact-v2 的 EncodeCompactPayload 必然输出 c/ti.a/item.e/item.m；有效 v2 payload 缺这些字段表示 RU 序列化器省略 false，不是可选业务字段。
-- Persistence 接受重建候选前仍比对原盖章 canonical 指纹，禁止截断/损坏借此绕过验证。
local function RebuildCompactV2Canonical(decoded, _stampedFingerprint, _currentCanonical, raw)
    local meta = type(raw) == "table" and raw.__rsmeta or nil
    if type(meta) ~= "table" or (tonumber(meta.framework) or 0) > 2 or tonumber(meta.schema) ~= PAYLOAD_SCHEMA
        or tonumber(raw and raw.v) ~= PAYLOAD_FORMAT or type(raw.it) ~= "table" then return nil end
    local candidate = DeepCopy(raw)
    candidate.__rsmeta = nil
    local recovered = NormalizePayload(decoded)
    local changed = false
    if candidate.c == nil then candidate.c = false; changed = true end
    candidate.ti = type(candidate.ti) == "table" and candidate.ti or {}
    if candidate.ti.a == nil then candidate.ti.a = false; changed = true end
    local recoveredBySlot = {}
    for _, item in ipairs(recovered.items or {}) do recoveredBySlot[tonumber(item.slot)] = item end
    for _, row in ipairs(candidate.it) do
        if type(row) == "table" then
            if row.e == nil then row.e = false; changed = true end
            if row.m == nil then
                row.m = false; changed = true
                local item = recoveredBySlot[tonumber(row.s)]
                if item ~= nil and item.empty ~= true then item.managed = false end
            end
        end
    end
    if changed ~= true then return nil end
    return candidate, recovered
end

local function DecodePayloadEnvelope(raw)
    if type(raw) ~= "table" then return nil, "gear payload raw must be table" end
    -- schema1 与旧 Reliability-v3 前 payload 使用框架默认包装。
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
        -- 响应式按钮位置：quickX/quickY 保留为兼容的最后逻辑 TOPLEFT 坐标；一旦存在 edge anchor 就以其为权威，分辨率变化可重解析，禁止重写用户布局。
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

-- 历史 quickHud key 为 schema 兼容保留；该表仅保存各方案独立按钮的全局行为，不拥有大型 HUD 窗口。
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
        -- 可选数值哨兵：历史行完全省略它，一次性启动意图修复真正提交前不能扰动旧 canonical 指纹。
        runtimePreferenceLink = tonumber(value.runtimePreferenceLink) == 1 and 1 or nil,
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

-- 2026-09-05前旧分片按槽数值顺序归一化并盖章；当前EquipmentSlots显示顺序改变数组与指纹。兼容桥对数字顺序副本重新算指纹，匹配证明内容完整，可接受一次。
-- 下次SavePayload按新顺序归一化并重盖索引，禁止旧方案直接落入分片不可用。
local function LegacyDigitOrderPayload(payload)
    local normalized = NormalizePayload(payload)
    local items = {}
    for _, item in ipairs(type(normalized.items) == "table" and normalized.items or {}) do items[#items + 1] = item end
    table.sort(items, function(a, b) return (tonumber(a.slot) or 0) < (tonumber(b.slot) or 0) end)
    normalized.items = items
    return normalized
end

function F:LegacyPayloadFingerprint(payload)
    if type(P.FingerprintPayload) ~= "function" then return nil, "persistence fingerprint unavailable" end
    return P:FingerprintPayload(LegacyDigitOrderPayload(payload), PAYLOAD_BUDGET)
end

-- 已配置方案不可能合法为空壳。SaveDraft 写前遵守同一规则；这里重复验证，使历史分片局部截断成为显式恢复场景，禁止缺装备身份时继续 Apply/Validate。
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
        rebuildCanonicalForIntegrity = RebuildCompactV2Canonical,
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
            -- 旧顺序兼容：数字顺序指纹匹配证明分片完整，仅早于稳定显示顺序；可以接受，延后保存迁移索引 stamp。
            local legacyFingerprint, legacyErr = self:LegacyPayloadFingerprint(payload)
            if legacyFingerprint ~= nil and tostring(legacyFingerprint) == tostring(expectedFingerprint) then
                return payload, fingerprint, nil, "legacy_slot_order_migrated"
            end
            return nil, nil, "payload fingerprint mismatch:" .. tostring(expectedFingerprint) .. ">" .. tostring(fingerprint)
                .. (legacyErr ~= nil and ("; legacy=" .. tostring(legacyErr)) or "")
        end
        return payload, fingerprint, nil
    end

    local payload, fingerprint, activeErr, migrated = Try(activeBank, activeFingerprint)
    if payload ~= nil then
        if migrated ~= nil then EmitRecovery(set, activeBank, activeBank .. "(legacy slot order)", "payload fingerprint order migration") end
        return payload, nil, { bank = activeBank, fingerprint = fingerprint, recovered = migrated ~= nil }
    end

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

    -- schema4 索引不含 bank 元数据；历史单 key 分片持续可读，但禁止再写入。
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
    -- 快捷按钮拖动结束/位置重置必须在返回前确认真实磁盘读回，不能把Native接受但丢写的位置当成已保存；其它索引命令保持原验证策略。
    local geometry = reason == "gear_quick_button_position" or reason == "gear_quick_button_positions_reset"
    local ok, err = P:SaveStore(INDEX_STORE, { consumeDirty = true, reason = reason, durable = geometry })
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
