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

local function NormalizeIndex(value)
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
    return {
        settings = settings,
        history = { serial = serial, entries = entries },
        widgetWindow = type(value.widgetWindow) == "table" and value.widgetWindow or {},
    }
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
        migrate = function(value) return NormalizeIndex(value) end,
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
    local ok, err = P:SaveStore(id, { consumeDirty = true, reason = "death_review_record" })
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

function F:EnsureStoreLoaded()
    if self.StoreLoaded == true then return true end
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
    local previousHistory = DeepCopy(self.State.history)
    local previousValue = self.State.settings.maxHistory
    self.State.settings.maxHistory = ClampInt(value, 1, MAX_HISTORY, 10)
    while #self.State.history.entries > self.State.settings.maxHistory do table.remove(self.State.history.entries, 1) end
    local ok, err = P:SaveStore(INDEX_STORE, { consumeDirty = true, reason = "death_review_max_history" })
    if ok ~= true then
        self.State.settings.maxHistory = previousValue
        self.State.history = previousHistory
        return false, err
    end
    return true
end

function F:DeleteHistoryRecord(serial)
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
    local previous = DeepCopy(self.State.history)
    table.remove(self.State.history.entries, removeIndex)
    local ok, err = P:SaveStore(INDEX_STORE, { consumeDirty = true, reason = "death_review_delete_record" })
    if ok ~= true then self.State.history = previous; return false, err end

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
