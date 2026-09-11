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
local INDEX_SCHEMA = 2 -- 中文维护注释：.18.193 把 DeathReview Index 的 codec1 + FloatingSurface v11 canonical 正式划为 schema2，结束 schema1 内多代 canonical 共存造成的重复假损坏。
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

F.PersistenceCanonicalWindowContractVersion = 7 -- 中文维护注释：v7 表示 DeathReview 窗口 canonical 已由 Store 显式字段投影冻结，未来 FloatingSurface 新字段不得无 schema bump 进入指纹。
F.PersistenceIndexSchemaContractVersion = INDEX_SCHEMA -- 中文维护注释：向 Acceptance/Foundation 暴露 Index schema2 边界，防止增量包只改 Store 而漏改门禁。
F.PersistenceKnownLegacyRecoveryContractVersion = 5 -- 中文维护注释：该契约版本保持不变；`.18.200` 实机 itrace 已证明 73DF7418 属于 Framework2/schema1/codec1，而不是先前误判的 schema2。这里不通过抬高版本号制造“已修复”假象，真实修复由下方 Store-owned exact old/new pair + generation gate 承担，未知 mismatch 继续 fail-closed。
F.PersistenceSchema2Framework2RecoveryContractVersion = 2 -- 中文维护注释：v2 表示 `.18.199` Framework2 冷路径可组合恢复 history 表形 + RU 数值 0 省略；只在 integrity mismatch 执行，不改变正常 schema2 codec、Feature Authority 或运行时 History 数据结构。
F.PersistenceTransportV1ZeroOmissionRecoveryContractVersion = 2 -- 中文维护注释：v2 修正 `.18.198` 候选爆炸：移除 canonical 无影响的 offsetX/offsetY，并与 history 表形恢复组合；最大候选固定为 2^10，仍只在完整性 mismatch 冷启动执行。
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

local CURRENT_WINDOW_KEYS = { -- 中文维护注释：schema2 自己声明 DeathReview HUD 的可持久化窗口字段，避免共享 FloatingSurface Foundation 演进时再次偷换 Index canonical。
    "width", "height", "minimized", "locked", -- 中文维护注释：尺寸与锁定/最小化仍是用户 Presentation 偏好，不影响死亡记录 Gameplay Authority。
    "overallOpacity", "backgroundOpacity", "textOpacity", "fontScale", "userMoved", -- 中文维护注释：外观与移动意图属于 HUD 状态，继续由 Index Store 保存。
    "x", "y", "anchorH", "anchorV", "offsetX", "offsetY", "coordinateSpace", "savedUiScale", -- 中文维护注释：保留既有自由/边缘定位语义用于同分辨率恢复。
    "savedLogicalWidth", "savedLogicalHeight", "normalizedCenterX", "normalizedCenterY", -- 中文维护注释：schema2 正式纳入 FloatingSurface v11 的跨分辨率响应式位置元数据。
} -- 中文维护注释：结束 schema2 窗口字段白名单；新增字段必须配套 schema3 与 historical canonical。
local HISTORICAL_SCHEMA1_CODEC_WINDOW_KEYS = { -- 中文维护注释：冻结 codec1 schema1 在响应式元数据进入 Store 之前的窗口 canonical，只用于旧盖章 exact recovery。
    "width", "height", "minimized", "locked", -- 中文维护注释：历史 schema1 codec1 基础窗口字段保持原形。
    "overallOpacity", "backgroundOpacity", "textOpacity", "fontScale", "userMoved", -- 中文维护注释：历史 schema1 codec1 外观字段必须保持，Core 才能用旧 Hash 证明逻辑内容。
    "x", "y", "anchorH", "anchorV", "offsetX", "offsetY", "coordinateSpace", "savedUiScale", -- 中文维护注释：历史 schema1 codec1 不包含后加入的 source viewport/normalized center 元数据。
} -- 中文维护注释：该列表只读且不可随当前 Foundation 增长，否则旧 Hash 证据会失去意义。

local function ProjectWindow(normalized, keys) -- 中文维护注释：共享 normalizer 负责坐标语义，DeathReview Store 负责每个 schema 的持久化字段 Authority。
    local out = {} -- 中文维护注释：新建 bounded 表，禁止未来共享 normalizer 的未知成员自动漏入既有 schema。
    for _, key in ipairs(keys) do -- 中文维护注释：固定小列表只在存档 Load/Save canonical 边界运行，不进入战斗事件或 Tick 热路径。
        if normalized[key] ~= nil then out[key] = normalized[key] end -- 中文维护注释：nil 仍不落盘，false/0 等有业务含义的值保持原样参与当前 canonical。
    end -- 中文维护注释：结束 schema-owned 字段复制。
    return out -- 中文维护注释：返回独立窗口表，避免 Persistence/Feature 共享同一引用产生隐式写入。
end -- 中文维护注释：结束窗口 schema 投影 helper。

local function NormalizeWidgetWindow(value) -- 中文维护注释：当前 schema2 的唯一窗口 canonical 入口，Feature Get/Set 仍复用同一 Store policy。
    return ProjectWindow(Floating:NormalizeState(value, F.WidgetWindowSizePolicy), CURRENT_WINDOW_KEYS) -- 中文维护注释：先按 RSUI 语义归一，再冻结 schema2 物理字段，兼顾 UI 一致性与指纹稳定性。
end -- 中文维护注释：结束当前 DeathReview 窗口 canonical。

local function NormalizeHistoricalSchema1CodecWindow(value) -- 中文维护注释：只用于 schema1 codec1 mismatch 的历史候选，正常 Domain/Widget 不得调用。
    return ProjectWindow(Floating:NormalizeState(value, F.WidgetWindowSizePolicy), HISTORICAL_SCHEMA1_CODEC_WINDOW_KEYS) -- 中文维护注释：剥离 schema2 响应式字段后交给 Core exact-hash 验证，不能凭形状直接信任。
end -- 中文维护注释：结束 schema1 codec1 历史窗口 canonical。

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

local function RebuildHistoricalCodecV1Canonical(rawEnvelope) -- 中文维护注释：schema1 已经写入 codec1 后仍经历过 Floating canonical 演进；该 helper 重建“codec 不变、窗口字段旧一代”的精确历史候选。
    if type(rawEnvelope) ~= "table" or tonumber(rawEnvelope.codec) ~= INDEX_CODEC_VERSION or type(rawEnvelope.payload) ~= "table" then return nil end -- 中文维护注释：只接受真正的 codec1 Index 包封，pre-codec 数据继续走原 `.18.145` 历史恢复器。
    local decoded, decodeErr = DecodeIndex(rawEnvelope) -- 中文维护注释：复用正式 codec decoder 还原 settings/history；decoder 为纯 Normalize，不触发 Apply/Native 写入。
    if type(decoded) ~= "table" or decodeErr ~= nil then return nil end -- 中文维护注释：codec 无法完整解码时保持 fail-closed，不构造猜测候选。
    local encodedSettings = { -- 中文维护注释：历史候选必须保持 codec1 的稳定负向 sentinel 设计，禁止退回 pre-codec default-true 布尔表示。
        windowMs = decoded.settings.windowMs, -- 中文维护注释：死亡前窗口数值直接来自已解码 Domain，仍受 NormalizeSettings 范围约束。
        maxHistory = decoded.settings.maxHistory, -- 中文维护注释：历史条数继续使用 codec1 的规范化整数。
        minDamage = decoded.settings.minDamage, -- 中文维护注释：最低伤害继续使用 codec1 的规范化整数。
    } -- 中文维护注释：结束 codec1 基础设置编码表。
    if decoded.settings.autoShow == false then encodedSettings.autoShowDisabled = 1 end -- 中文维护注释：显式关闭自动弹出必须保留 numeric sentinel，避免 RU 省略 false 再次产生歧义。
    if decoded.settings.showDebuffs == false then encodedSettings.showDebuffsDisabled = 1 end -- 中文维护注释：显式关闭 Debuff 同样只使用 codec1 sentinel。
    local historicalCanonical = { -- 中文维护注释：构造 Store-owned schema1 codec1 canonical；Core 之后会重新 Hash，候选本身不拥有信任权。
        codec = INDEX_CODEC_VERSION, -- 中文维护注释：物理 codec 仍为 v1，本轮 schema bump 不改 DeathReview Index 数据编码协议。
        payload = { -- 中文维护注释：codec1 业务 payload 仅包含 settings/history/widgetWindow 三个固定根字段。
            settings = encodedSettings, -- 中文维护注释：设置使用上方稳定 sentinel 形状。
            history = DeepCopy(decoded.history), -- 中文维护注释：历史摘要从正式 decoder 保留，不扫描记录分片、不改变 serial/storageId Authority。
            widgetWindow = NormalizeHistoricalSchema1CodecWindow(rawEnvelope.payload.widgetWindow), -- 中文维护注释：只把窗口 canonical 回退到 schema1 历史字段，业务 settings/history 不做猜测。
        }, -- 中文维护注释：结束 schema1 codec1 payload。
    } -- 中文维护注释：结束 schema1 codec1 历史候选。
    return historicalCanonical, decoded -- 中文维护注释：若旧 Hash 精确命中，Core 应用 recovered Domain 时仍使用当前 Normalize 后的 decoded 值并立即迁移到 schema2。
end -- 中文维护注释：结束 codec1 历史 canonical 重建 helper。

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

-- 中文维护注释：`.18.199` 将 Framework2（无 Transport）与 Framework3/Transport v1
-- 的“RU 原生 serializer 省略合法数值 0”统一到同一个 Store-owned exact recovery。
-- Authority 边界：Persistence Core 仍负责 envelope seal / budget / 最终 fingerprint 决策；
-- DeathReview 只知道自己的 codec1 与 widgetWindow schema，不读取 Native UI、当前屏幕坐标或 record 分片。
--
-- 旧 `.18.198` 把 offsetX/offsetY 也放进候选位是错误的：FloatingSurface 在 edge 模式下
-- 对缺失 offset 本来就 deterministic fallback=0，在 free 模式下 offset 又不会进入 canonical，
-- 所以补 0 永远不可能改变 Hash，却会把候选位从 10 扩大到 12。free 布局里这两个字段通常都缺失，
-- 于是 2^12=4096 会超过 1024 冷路径预算并直接 skip，真正的 x/y=0 反而无法恢复。
-- 新列表只保留“nil 与 0 会改变当前 canonical”的字段，最大固定 10 位 => 1024 组合。
local ZERO_OMISSION_WINDOW_KEYS = {
    "x", "y", -- 中文维护注释：free 模式成立条件；任一 0 被删都会让整组 free 定位字段塌陷。
    "normalizedCenterX", "normalizedCenterY", -- 中文维护注释：跨分辨率归一化中心允许边界值 0。
    "savedLogicalWidth", "savedLogicalHeight", -- 中文维护注释：free 模式下直接参与 schema2 canonical。
    "overallOpacity", "backgroundOpacity", "textOpacity", -- 中文维护注释：显式 0 与默认 0.96/1/1 不等价。
    "savedUiScale", -- 中文维护注释：moved 状态下显式 0 与 nil 不等价；保留用于历史 exact reconstruction。
}
local MAX_ZERO_OMISSION_CANDIDATES = 1024

local function TryRebuildZeroOmittedWindowCanonical(baseDomain, rawWindow, stampedFingerprint, probePrefix, metaDesc)
    local store = P:GetStore(INDEX_STORE) -- 中文维护注释：仅用于 exact Hash 与 runtime-only probe；业务状态 Authority 仍在 F.State。
    local function Probe(reason, extra)
        if type(store) ~= "table" then return end
        store.lastHistoricalRecoveryProbe = tostring(probePrefix or "deathReviewZero") .. "/" .. tostring(reason)
            .. (extra ~= nil and ("/" .. tostring(extra)) or "")
    end

    if type(baseDomain) ~= "table" or type(rawWindow) ~= "table" or type(store) ~= "table" then
        Probe("skip_shape", metaDesc)
        return nil
    end

    local missing, present = {}, {}
    for _, key in ipairs(ZERO_OMISSION_WINDOW_KEYS) do
        if rawWindow[key] == nil then missing[#missing + 1] = key else present[#present + 1] = key end
    end
    if #missing == 0 then
        Probe("skip_no_missing_zero_key", tostring(metaDesc or "") .. "/present=" .. table.concat(present, ","))
        return nil
    end

    local combinations = 2 ^ #missing
    if combinations > MAX_ZERO_OMISSION_CANDIDATES then
        -- 中文维护注释：理论上当前字段表最多 10 位，因此只有未来维护错误扩大列表才会命中此保护。
        -- 宁可保持 write fence，也禁止冷启动无界暴力枚举。
        Probe("skip_too_many", tostring(metaDesc or "") .. "/missing=" .. table.concat(missing, ","))
        return nil
    end

    -- 中文维护注释：settings/history 固定来自同一已解码/已恢复 Domain，只枚举窗口中“缺失字段原值是否为 0”。
    -- EncodeIndex 会再次经过当前 Store normalizer；候选仍必须逐个命中旧 stamped fingerprint 才能返回。
    local baseCanonical = EncodeIndex({
        settings = DeepCopy(baseDomain.settings),
        history = DeepCopy(baseDomain.history),
        widgetWindow = rawWindow,
    })
    if type(baseCanonical) ~= "table" or type(baseCanonical.payload) ~= "table" then
        Probe("skip_encode_failed", metaDesc)
        return nil
    end

    for mask = 1, combinations - 1 do
        local candidateWindow = DeepCopy(rawWindow)
        local bits = mask
        for index = 1, #missing do
            if bits % 2 == 1 then candidateWindow[missing[index]] = 0 end
            bits = math.floor(bits / 2)
        end

        local candidateWindowCanonical = NormalizeWidgetWindow(candidateWindow)
        local candidate = {
            codec = baseCanonical.codec,
            payload = {
                settings = baseCanonical.payload.settings,
                history = baseCanonical.payload.history,
                widgetWindow = candidateWindowCanonical,
            },
        }
        local candidateFingerprint = P:FingerprintCanonicalValue(store, candidate)
        if candidateFingerprint ~= nil and tostring(candidateFingerprint) == tostring(stampedFingerprint) then
            Probe("match", "mask=" .. tostring(mask)
                .. "/bits=" .. tostring(#missing)
                .. "/missing=" .. table.concat(missing, ",")
                .. "/" .. tostring(metaDesc or ""))
            return candidate, NormalizeIndex({
                settings = DeepCopy(baseDomain.settings),
                history = DeepCopy(baseDomain.history),
                widgetWindow = candidateWindow,
            })
        end
    end

    Probe("no_match", "tried=" .. tostring(combinations - 1)
        .. "/missing=" .. table.concat(missing, ",")
        .. "/present=" .. table.concat(present, ",")
        .. "/" .. tostring(metaDesc or ""))
    return nil
end

local function RebuildFramework2Schema2CodecV1Canonical(rawEnvelope, stampedFingerprint) -- 中文维护注释：该结构化恢复器只服务“真实元数据就是 Framework2/schema2/codec1”的旧档，负责 sequence/map 表形与可证明的数值 0 省略；`.18.200` 诊断已排除 73DF7418 属于此世代，因此禁止再把该事故写进本分支，所有候选仍必须 exact 命中旧盖章。

    local meta = type(rawEnvelope) == "table" and rawEnvelope.__rsmeta or nil
    if type(meta) ~= "table" or tonumber(meta.framework) ~= 2 or tonumber(meta.schema) ~= INDEX_SCHEMA then return nil end
    if tonumber(type(rawEnvelope) == "table" and rawEnvelope.codec or nil) ~= INDEX_CODEC_VERSION or type(rawEnvelope.payload) ~= "table" then return nil end

    local decoded, decodeErr = DecodeIndex(rawEnvelope)
    if type(decoded) ~= "table" or decodeErr ~= nil then return nil end
    local payload = rawEnvelope.payload
    local sourceHistory = type(payload.history) == "table" and payload.history or {}
    local sourceEntries = type(sourceHistory.entries) == "table" and sourceHistory.entries or {}
    local ipairsCount, pairsCount = 0, 0
    for _ in ipairs(sourceEntries) do ipairsCount = ipairsCount + 1 end
    for _ in pairs(sourceEntries) do pairsCount = pairsCount + 1 end

    local recoveredDomain = NormalizeHistoricalIndexWithRecoveredEntries({
        settings = DeepCopy(decoded.settings),
        history = DeepCopy(sourceHistory),
        widgetWindow = DeepCopy(payload.widgetWindow),
    })
    recoveredDomain.settings = DeepCopy(decoded.settings)
    recoveredDomain.widgetWindow = NormalizeWidgetWindow(payload.widgetWindow)

    local store = P:GetStore(INDEX_STORE)
    local historicalCanonical = EncodeIndex(recoveredDomain)
    local metaDesc = "schema=2/fw=2/codec=1/ipairs=" .. tostring(ipairsCount) .. "/pairs=" .. tostring(pairsCount)
    if type(store) == "table" and type(historicalCanonical) == "table" then
        local fingerprint = P:FingerprintCanonicalValue(store, historicalCanonical)
        if fingerprint ~= nil and tostring(fingerprint) == tostring(stampedFingerprint) then
            store.lastHistoricalRecoveryProbe = "schema2fw2_codec1/base_match/" .. metaDesc
            return historicalCanonical, recoveredDomain
        end
    end

    local zeroCanonical, zeroDomain = TryRebuildZeroOmittedWindowCanonical(
        recoveredDomain, type(payload.widgetWindow) == "table" and payload.widgetWindow or nil,
        stampedFingerprint, "schema2fw2_zero", metaDesc)
    if type(zeroCanonical) == "table" then return zeroCanonical, zeroDomain end

    -- 中文维护注释：返回原表形候选保持既有 fail-closed 行为；Core 仍会重新 Hash，不匹配就继续 known-stamp/Fence。
    return historicalCanonical, recoveredDomain
end

local function RebuildTransportV1ZeroOmissionCanonical(decoded, stampedFingerprint, currentCanonical, rawEnvelope) -- 中文维护注释：`.18.199` Transport v1 也改用 shared solver；同时先恢复 history map/sequence 表形，防止同一次 Native 往返出现两种表示漂移时只能修其中一种。
    local store = P:GetStore(INDEX_STORE)
    local function Probe(reason, extra)
        if type(store) ~= "table" then return end
        store.lastHistoricalRecoveryProbe = "transportV1Zero/" .. tostring(reason)
            .. (extra ~= nil and ("/" .. tostring(extra)) or "")
    end

    local meta = type(rawEnvelope) == "table" and rawEnvelope.__rsmeta or nil
    local metaSchema = meta ~= nil and tonumber(meta.schema) or nil
    local metaFramework = meta ~= nil and tonumber(meta.framework) or nil
    local metaTransport = meta ~= nil and tonumber(meta.transportVersion) or nil
    local metaCodec = tonumber(type(rawEnvelope) == "table" and rawEnvelope.codec or nil)
    local metaDesc = "schema=" .. tostring(metaSchema) .. "/fw=" .. tostring(metaFramework)
        .. "/tv=" .. tostring(metaTransport) .. "/codec=" .. tostring(metaCodec)

    if type(meta) ~= "table" or metaSchema ~= INDEX_SCHEMA or metaFramework ~= 3 then
        Probe("skip_generation", metaDesc)
        return nil
    end
    if metaTransport ~= 1 then
        Probe("skip_transport_v2", metaDesc)
        return nil
    end
    if metaCodec ~= INDEX_CODEC_VERSION or type(rawEnvelope.payload) ~= "table" then
        Probe("skip_codec", metaDesc)
        return nil
    end

    local payload = rawEnvelope.payload
    local sourceHistory = type(payload.history) == "table" and payload.history or {}
    local recoveredDomain = NormalizeHistoricalIndexWithRecoveredEntries({
        settings = DeepCopy(decoded.settings),
        history = DeepCopy(sourceHistory),
        widgetWindow = DeepCopy(payload.widgetWindow),
    })
    recoveredDomain.settings = DeepCopy(decoded.settings)
    recoveredDomain.widgetWindow = NormalizeWidgetWindow(payload.widgetWindow)

    -- 中文维护注释：先测试“只有 sequence/map 漂移”这一候选；若已经命中，无需进入零值枚举。
    local baseCanonical = EncodeIndex(recoveredDomain)
    if type(store) == "table" and type(baseCanonical) == "table" then
        local baseFingerprint = P:FingerprintCanonicalValue(store, baseCanonical)
        if baseFingerprint ~= nil and tostring(baseFingerprint) == tostring(stampedFingerprint) then
            Probe("base_match", metaDesc)
            return baseCanonical, recoveredDomain
        end
    end

    return TryRebuildZeroOmittedWindowCanonical(
        recoveredDomain, type(payload.widgetWindow) == "table" and payload.widgetWindow or nil,
        stampedFingerprint, "transportV1Zero", metaDesc)
end -- 中文维护注释：结束 Framework3/Transport v1 零值省略结构化恢复器。

local function RebuildHistoricalIndexCanonical(value, stampedFingerprint, currentCanonical, rawEnvelope) -- 中文维护注释：统一 Index 历史恢复入口，按 schema/framework/codec 明确分代，避免内容相关 known-pair 继续承担可以结构化证明的兼容职责。
    local meta = type(rawEnvelope) == "table" and rawEnvelope.__rsmeta or nil -- 中文维护注释：历史候选必须绑定已通过 Envelope Seal 的真实 schema/framework 元数据。
    -- 中文维护注释：`.18.198` 入口即写 probe。此前只有进入具体分支才写，而所有分支都不命中时
    -- hook 返回 nil、probe 保持 nil，导致摘要里「恢复探针」段整个消失——维护者无法区分
    -- 「hook 没被调用」和「调用了但分支不匹配」。现在入口先记录真实世代，分支内部再覆盖为更细的原因。
    do
        local entryStore = P:GetStore(INDEX_STORE) -- 中文维护注释：仅写 runtime-only probe，不建立第二 Persistence Authority。
        if type(entryStore) == "table" then
            entryStore.lastHistoricalRecoveryProbe = "enter/schema=" .. tostring(meta ~= nil and tonumber(meta.schema) or nil)
                .. "/fw=" .. tostring(meta ~= nil and tonumber(meta.framework) or nil)
                .. "/tv=" .. tostring(meta ~= nil and tonumber(meta.transportVersion) or nil)
                .. "/codec=" .. tostring(type(rawEnvelope) == "table" and tonumber(rawEnvelope.codec) or nil)
                .. "/stamped=" .. tostring(stampedFingerprint) -- 中文维护注释：stamped 只是 32 位 Hash，不含任何业务内容。
        end -- 中文维护注释：结束入口 probe 写入。
    end
    if type(meta) == "table" and tonumber(meta.schema) == INDEX_SCHEMA and tonumber(meta.framework) == 2 and tonumber(type(rawEnvelope) == "table" and rawEnvelope.codec or nil) == INDEX_CODEC_VERSION then -- 中文维护注释：`.18.193` 已升级到 schema2 但 Framework2 尚无 Transport v1；优先使用通用表形 exact recovery，覆盖任意合法用户内容而不是新增 Hash 白名单。
        return RebuildFramework2Schema2CodecV1Canonical(rawEnvelope, stampedFingerprint) -- 中文维护注释：`.18.199` 组合恢复 Framework2 的 history 表形与合法 0 省略；Core 仍对候选做第二次 exact Hash 验证。
    end -- 中文维护注释：结束 Framework2 schema2 codec1 分支；Framework3 mismatch 不进入兼容器。
    if type(meta) == "table" and tonumber(meta.schema) == INDEX_SCHEMA and tonumber(meta.framework) == 3
        and tonumber(meta.transportVersion) == 1 and tonumber(type(rawEnvelope) == "table" and rawEnvelope.codec or nil) == INDEX_CODEC_VERSION then -- 中文维护注释：`.18.198` 新增分支——当前 schema2 在 Framework3 下已由 Transport v1 写盘，而 v1 未保护数值 0；这是可结构化证明的物理机制，优先级高于任何内容相关 known-pair。
        return RebuildTransportV1ZeroOmissionCanonical(value, stampedFingerprint, currentCanonical, rawEnvelope) -- 中文维护注释：候选仍需 Core 用旧 stamped fingerprint 做 exact Hash 认证；命不中即回落到既有 known-pair 桥，最后才 Fence。
    end -- 中文维护注释：结束 Framework3 Transport v1 零值省略分支。
    if type(meta) == "table" and tonumber(meta.schema) == 1 and tonumber(type(rawEnvelope) == "table" and rawEnvelope.codec or nil) == INDEX_CODEC_VERSION then -- 中文维护注释：schema1 + codec1 是 `.18.149-.18.192` 世代，继续尝试冻结窗口字段的 exact canonical。
        return RebuildHistoricalCodecV1Canonical(rawEnvelope) -- 中文维护注释：Core 会验证返回候选 Hash；命不中旧 stamp 后才允许进入既有 known-pair 最终桥。
    end -- 中文维护注释：结束 codec1 schema1 分支。
    return RebuildV18_145Canonical(value, stampedFingerprint, currentCanonical, rawEnvelope) -- 中文维护注释：无 codec 的旧 schema1 继续使用既有 opaque-window/default-false bounded exact 搜索；future schema 不会从这里获得绕过。
end -- 中文维护注释：结束 DeathReview 多世代历史 canonical 路由。

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
local KNOWN_LEGACY_V4_INDEX_FINGERPRINTS = { -- 中文维护注释：known-stamp 仅记录真实 RU 事故身份；未知 Hash 永远不能通过该表。
    ["770CB0B8"] = { label = "ru_2026_09_07_precodec_v4_index", representation = "precodec" }, -- 中文维护注释：保留 `.18.151` 已验证的 pre-codec 桥；其安全边界仍是 strict legacy shape + exact old stamp。
    ["014277AB"] = { label = "ru_2026_09_09_schema1_codec1_window_generation", representation = "codec1", currentFingerprint = "0CF5BCC1" }, -- 中文维护注释：`.18.192` 实机新事故必须同时命中 old=014277AB 与 current=0CF5BCC1，防止真实内容变化被误迁移。
    ["73DF7418"] = { label = "ru_2026_09_11_schema1_framework2_codec1_index_drift", representation = "schema1_framework2_codec1", currentFingerprint = "224E5B9D" }, -- 中文维护注释：`.18.200` 实机 itrace 明确给出 fw=2/schema=1/transport=nil/codec=1，且同一磁盘内容 current canonical=224E5B9D；此前把它错误登记成 schema2，导致 known-stamp 在 generation gate 被提前拒绝。此条仍要求 Store/owner、Framework2、schema1、无 Transport、codec1 strict shape 与 old/new 双 Hash 全部精确命中，Authority 仅限 DeathReview Store，未知或未来世代绝不借用。
    ["55BD6B0A"] = { label = "ru_2026_09_10_schema2_transport1_window_field_loss", representation = "schema2_transport1", currentFingerprint = "44CFFAF4" }, -- 中文维护注释：`.18.198` 实机事故。磁盘取证证实 RU udf 落盘时丢弃了 widgetWindow 的 4 个响应式字段（savedLogicalWidth/Height、normalizedCenterX/Y），而 stamp 是对含这些字段的 canonical 计算的——字段值来自保存时输入，物理丢失后无法从 32 位 Hash 反推，因此走 exact pair；恢复后立即按当前 Transport 版本重写。
} -- 中文维护注释：结束 DeathReview known-stamp allowlist；新增事故必须有真实诊断证据与对应 current Hash。

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

local CODEC_V1_PAYLOAD_KEYS = { settings = true, history = true, widgetWindow = true } -- 中文维护注释：codec1 payload 根字段固定，known-pair 恢复不得接受附加业务子树。
local CODEC_V1_SETTINGS_KEYS = { autoShowDisabled = true, windowMs = true, maxHistory = true, minDamage = true, showDebuffsDisabled = true } -- 中文维护注释：codec1 设置只允许稳定 numeric sentinel 与三个数值设置。
local CODEC_V1_WINDOW_KEYS = { opacity = true } -- 中文维护注释：窗口验证允许历史 opacity 别名，但当前保存仍只写 overallOpacity。
for _, key in ipairs(CURRENT_WINDOW_KEYS) do CODEC_V1_WINDOW_KEYS[key] = true end -- 中文维护注释：schema1 codec1 可能跨 Floating v11 前后保存，因此验证允许所有已知当前窗口字段，但不允许未知未来字段。

local function ValidateCodecV1IndexPayload(rawEnvelope) -- 中文维护注释：`.18.193` 新 known-pair 桥的 Store-owned codec1 结构验证，避免只凭 Hash 字符串接受任意表。
    if type(rawEnvelope) ~= "table" or tonumber(rawEnvelope.codec) ~= INDEX_CODEC_VERSION or type(rawEnvelope.payload) ~= "table" then return false, "codec_envelope" end -- 中文维护注释：必须是真正 codec1 Index 包封。
    local payload = rawEnvelope.payload -- 中文维护注释：只验证业务 payload；元数据已由 Persistence Envelope Seal 在调用 hook 前验证。
    local ok, err = HasOnlyKeys(payload, CODEC_V1_PAYLOAD_KEYS) -- 中文维护注释：先拒绝 codec1 未定义的根字段，防止 future schema 被旧桥降级读取。
    if ok ~= true then return false, "payload:" .. tostring(err) end -- 中文维护注释：根字段异常直接 fail-closed。
    if type(payload.settings) ~= "table" then return false, "settings_required" end -- 中文维护注释：codec1 settings 是必需子表，缺失不允许用默认值掩盖。
    ok, err = HasOnlyKeys(payload.settings, CODEC_V1_SETTINGS_KEYS) -- 中文维护注释：设置只允许 v1 codec 明确字段。
    if ok ~= true then return false, "settings:" .. tostring(err) end -- 中文维护注释：未知设置字段拒绝恢复。
    for _, key in ipairs({ "autoShowDisabled", "showDebuffsDisabled", "windowMs", "maxHistory", "minDamage" }) do if payload.settings[key] ~= nil and tonumber(payload.settings[key]) == nil then return false, "settings_number:" .. key end end -- 中文维护注释：sentinel 与设置值必须保持数值可解析，字符串业务漂移不进入迁移。
    local historyOk, historyReason = ValidateLegacyIndexPayload({ settings = {}, history = payload.history }) -- 中文维护注释：history 摘要结构与 pre-codec Domain 相同，复用既有 bounded serial/storageId/type 验证而不复制第二套规则。
    if historyOk ~= true then return false, "history:" .. tostring(historyReason) end -- 中文维护注释：历史摘要任何异常都保持原 fence。
    if payload.widgetWindow ~= nil then -- 中文维护注释：窗口可缺失，但存在时必须完全属于已知 Floating 字段。
        ok, err = HasOnlyKeys(payload.widgetWindow, CODEC_V1_WINDOW_KEYS) -- 中文维护注释：允许 schema1 生命周期中已知的 v10/v11 字段集合，拒绝 future/未知成员。
        if ok ~= true then return false, "window:" .. tostring(err) end -- 中文维护注释：窗口未知字段可能代表未来版本或损坏，不能降级吞掉。
        for _, key in ipairs({ "minimized", "locked", "userMoved" }) do if payload.widgetWindow[key] ~= nil and type(payload.widgetWindow[key]) ~= "boolean" then return false, "window_bool:" .. key end end -- 中文维护注释：窗口布尔维持严格 Lua 类型。
        for _, key in ipairs({ "width", "height", "opacity", "overallOpacity", "backgroundOpacity", "textOpacity", "fontScale", "x", "y", "offsetX", "offsetY", "savedUiScale", "savedLogicalWidth", "savedLogicalHeight", "normalizedCenterX", "normalizedCenterY" }) do if payload.widgetWindow[key] ~= nil and tonumber(payload.widgetWindow[key]) == nil then return false, "window_number:" .. key end end -- 中文维护注释：几何/透明度只允许数值表示漂移。
        for _, key in ipairs({ "anchorH", "anchorV", "coordinateSpace" }) do if payload.widgetWindow[key] ~= nil and type(payload.widgetWindow[key]) ~= "string" then return false, "window_text:" .. key end end -- 中文维护注释：锚点/坐标空间必须仍是字符串枚举。
    end -- 中文维护注释：结束 codec1 窗口验证。
    return true -- 中文维护注释：结构验证通过后仍必须由 known old/new fingerprint pair 才能恢复。
end -- 中文维护注释：结束 codec1 Index shape validator。

local function RecoverKnownLegacyV4Index(decoded, stampedFingerprint, currentCanonical, rawEnvelope) -- 中文维护注释：DeathReview known-stamp 最终桥按表示世代分流；Core 的 exact historical reconstruction 永远先于本函数。
    local stamp = tostring(stampedFingerprint or "") -- 中文维护注释：只把实机 stamped fingerprint 作为迁移身份，不从 Domain 数据推断版本。
    local known = KNOWN_LEGACY_V4_INDEX_FINGERPRINTS[stamp] -- 中文维护注释：allowlist 未命中时立即返回 nil，继续通用 fail-closed。
    if type(known) ~= "table" then return nil end -- 中文维护注释：不存在或格式异常的条目不能获得恢复权限。
    local meta = type(rawEnvelope) == "table" and rawEnvelope.__rsmeta or nil -- 中文维护注释：再次绑定 schema/store/owner，防止相同 Hash 在其它 Store/未来 schema 中误触。
    local store = P:GetStore(INDEX_STORE) -- 中文维护注释：获取当前注册 Store 仅用于当前 canonical Hash 与 runtime-only probe，不建立第二 Persistence Authority。
    if type(meta) ~= "table" or tostring(meta.store or "") ~= INDEX_STORE or tostring(meta.owner or "") ~= "v3.death_review" then
        if store ~= nil then store.lastHistoricalRecoveryProbe = "knownStamp=" .. stamp .. "/identity=reject:store=" .. tostring(type(meta) == "table" and meta.store or nil) .. ",owner=" .. tostring(type(meta) == "table" and meta.owner or nil) end -- 中文维护注释：只输出 Store/owner 契约身份，不输出任何死亡记录业务内容。
        return nil
    end -- 中文维护注释：Store/owner 身份必须精确匹配。
    if known.representation == "schema1_framework2_codec1" then -- 中文维护注释：`.18.200` 实机 trace 已把 73DF7418 的真实世代锁定为 Framework2/schema1/transport=nil/codec1；该分支只纠正先前错误的 schema2 代际映射，不扩大 old/new Hash allowlist，也不改变 Persistence Core 的恢复 Authority。
        if tonumber(meta.schema) ~= 1 or tonumber(meta.framework) ~= 2 or meta.transportVersion ~= nil then -- 中文维护注释：兼容边界必须逐项与实机元数据一致；schema2、Framework3 或已有 Transport 标记都属于其它世代，继续 fail-closed，禁止因为 Hash 相同跨代恢复。
            if store ~= nil then store.lastHistoricalRecoveryProbe = "knownStamp=" .. stamp .. "/schema1Fw2Generation=reject:s=" .. tostring(meta.schema) .. ",fw=" .. tostring(meta.framework) .. ",tv=" .. tostring(meta.transportVersion) end -- 中文维护注释：runtime-only probe 只暴露代际元数据，不输出死亡记录内容；后续若再次失败可直接判断是否又发生世代误分类。
            return nil -- 中文维护注释：代际证据不完整时不构造候选、不清档，让 Core 维持 write fence，避免把真实损坏误当兼容迁移。
        end -- 中文维护注释：Framework2/schema1 的合法旧 envelope 不带 transportVersion；这也是与 schema2/Transport v1/v2 路径的硬隔离边界。
        local valid, reason = ValidateCodecV1IndexPayload(rawEnvelope) -- 中文维护注释：即使 old Hash 命中，仍由 DeathReview Store 对 codec1 payload 做字段白名单与类型验证；Hash 只能标识事故，不能替代结构安全检查。
        if valid ~= true then -- 中文维护注释：shape/type 不符合已知 codec1 结构时视为未知损坏，不允许进入 pair 迁移。
            if store ~= nil then store.lastHistoricalRecoveryProbe = "knownStamp=" .. stamp .. "/schema1Fw2Shape=reject:" .. tostring(reason) end -- 中文维护注释：仅记录 bounded 结构拒绝原因，便于实机定位且不泄露历史战斗业务值。
            return nil -- 中文维护注释：拒绝异常 shape 并把最终处置权交还 Core fence；不修改 F.State、不触发保存。
        end -- 中文维护注释：结束 codec1 strict-shape 安全门。
        local currentFingerprint = store ~= nil and P:FingerprintCanonicalValue(store, currentCanonical) or nil -- 中文维护注释：数据流为“磁盘 raw → codec1 decode/当前 canonical → current Hash”；必须精确得到实机观测 224E5B9D，才证明这是同一表示事故而不是内容变化。
        if tostring(currentFingerprint or "") ~= tostring(known.currentFingerprint or "") then -- 中文维护注释：old=73DF7418 单独没有恢复权限；new Hash 不同意味着当前业务内容或 canonical 已发生其它变化，继续 fail-closed。
            if store ~= nil then store.lastHistoricalRecoveryProbe = "knownStamp=" .. stamp .. "/schema1Fw2Shape=ok/current=reject:" .. tostring(currentFingerprint) .. "!=" .. tostring(known.currentFingerprint) end -- 中文维护注释：保留 exact-pair 第二半的拒绝证据，下一次日志无需再猜 generation/shape/current 哪一层失败。
            return nil -- 中文维护注释：current Hash 未命中时绝不套用已知迁移，防止同 old stamp 下吞掉真实配置变化。
        end -- 中文维护注释：结束 73DF7418→224E5B9D 双 Hash 认证门。
        if store ~= nil then store.lastHistoricalRecoveryProbe = "knownStamp=" .. stamp .. "/schema1Fw2Shape=ok/current=" .. tostring(currentFingerprint) end -- 中文维护注释：只记录恢复证据；真正 Apply/migrate/restamp 仍由 Persistence Core 统一事务执行，Store 不直接写盘。
        return NormalizeIndex(decoded), tostring(known.label or "death_review_schema1_framework2_known_pair") -- 中文维护注释：保留 decoder 已成功解释的全部 Domain 数据，随后 Core 继续执行 schema1→2 migrate，并按当前 Framework3/Transport v2 立即重盖；不会依赖高频战斗模块或 UI 生命周期。
    end
    if known.representation == "schema2_transport1" then -- 中文维护注释：`.18.198` 新增分支——schema2/Framework3/Transport v1 的窗口字段物理丢失。磁盘取证证实：stamp 是对含响应式字段的 canonical 计算的，而 RU udf 落盘时丢弃了它们，字段值无法反推，只能 exact pair 一次性迁移。
        if tonumber(meta.schema) ~= INDEX_SCHEMA or tonumber(meta.framework) ~= 3 or tonumber(meta.transportVersion) ~= 1 then return nil end -- 中文维护注释：世代必须精确匹配，禁止放宽成 wildcard。
        if type(store) == "table" then store.lastHistoricalRecoveryProbe = "knownStamp=" .. stamp .. "/transport1Shape=check" end -- 中文维护注释：runtime-only probe。
        local valid, reason = ValidateCodecV1IndexPayload(rawEnvelope) -- 中文维护注释：codec1 物理形状与 schema1 世代相同，复用既有严格 shape/type 验证。
        if valid ~= true then if store ~= nil then store.lastHistoricalRecoveryProbe = "knownStamp=" .. stamp .. "/transport1Shape=reject:" .. tostring(reason) end; return nil end -- 中文维护注释：shape 异常保留 probe 后拒绝。
        local currentFingerprint = store ~= nil and P:FingerprintCanonicalValue(store, currentCanonical) or nil -- 中文维护注释：必须同时证明当前磁盘解码内容正好落在已观测的新 Hash。
        if tostring(currentFingerprint or "") ~= tostring(known.currentFingerprint or "") then return nil end -- 中文维护注释：old/new pair 不完整即 fail-closed。
        if store ~= nil then store.lastHistoricalRecoveryProbe = "knownStamp=" .. stamp .. "/transport1Shape=ok/current=" .. tostring(currentFingerprint) end -- 中文维护注释：记录恢复证据，便于下一次 Fresh Reload 确认已重写。
        return NormalizeIndex(decoded), tostring(known.label or "death_review_transport1_known_pair") -- 中文维护注释：保留 decoder 已恢复的 settings/history/window；Core 仍执行预算、Apply 与按当前 Transport 版本立即重写。
    end -- 中文维护注释：结束 schema2_transport1 分支。
    if tonumber(meta.schema) ~= 1 then return nil end -- 中文维护注释：其余 known-stamp 分支只服务旧 schema1；当前 schema 的 mismatch 由结构化恢复器处理。
    if known.representation == "codec1" then -- 中文维护注释：2026-09-09 事故来自已采用 codec1、但 schema 尚未划分新 canonical generation 的旧存档。
        local valid, reason = ValidateCodecV1IndexPayload(rawEnvelope) -- 中文维护注释：old stamp 命中后仍必须通过严格 codec1 shape/type 验证。
        if valid ~= true then if store ~= nil then store.lastHistoricalRecoveryProbe = tostring(store.lastHistoricalRecoveryProbe or "") .. "/knownStamp=" .. stamp .. "/codec1Shape=reject:" .. tostring(reason) end; return nil end -- 中文维护注释：shape 异常保留 probe 后拒绝，绝不清档或套默认值。
        local currentFingerprint = store ~= nil and P:FingerprintCanonicalValue(store, currentCanonical) or nil -- 中文维护注释：计算同一磁盘数据在当前 schema2 canonical 下的 Hash，用 real-machine old/new pair 双重证明内容未跨事故边界变化。
        if tostring(currentFingerprint or "") ~= tostring(known.currentFingerprint or "") then return nil end -- 中文维护注释：只认 014277AB→0CF5BCC1；同 old stamp 但 current 内容不同仍视为真实损坏。
        if store ~= nil then store.lastHistoricalRecoveryProbe = tostring(store.lastHistoricalRecoveryProbe or "") .. "/knownStamp=" .. stamp .. "/codec1Shape=ok/current=" .. tostring(currentFingerprint) end -- 中文维护注释：记录无敏感业务内容的恢复证据，便于下一次 Fresh Reload 验收是否已重盖 schema2。
        return NormalizeIndex(decoded), tostring(known.label or "death_review_codec1_known_pair") -- 中文维护注释：保留 decoder 已恢复的 settings/history/window；Core 仍执行预算、schema1→2 migrate、Apply 与立即保存。
    end -- 中文维护注释：结束 codec1 known-pair 分支。
    if known.representation ~= "precodec" or type(rawEnvelope) ~= "table" or rawEnvelope.codec ~= nil or type(rawEnvelope.payload) ~= "table" then return nil end -- 中文维护注释：旧 770CB0B8 只允许无 codec 的 pre-.18.149 包封，禁止与 codec1 新桥混用。
    local source = rawEnvelope.payload -- 中文维护注释：pre-codec 恢复只读取已封印 envelope 的业务 payload。
    local valid, reason = ValidateLegacyIndexPayload(source) -- 中文维护注释：继续复用 `.18.151` 的严格 legacy Domain 白名单与 bounded history 验证。
    if valid ~= true then -- 中文维护注释：即使 770CB0B8 命中，旧 Domain shape 不合法也必须拒绝。
        if store ~= nil then store.lastHistoricalRecoveryProbe = tostring(store.lastHistoricalRecoveryProbe or "") .. "/knownStamp=" .. stamp .. "/knownShape=reject:" .. tostring(reason) end -- 中文维护注释：只记录结构原因，不输出玩家/伤害内容。
        return nil -- 中文维护注释：返回 nil 让 Persistence Core 保持原 integrity_failed/write fence。
    end -- 中文维护注释：结束 pre-codec shape 拒绝分支。
    local recovered = NormalizeHistoricalIndexWithRecoveredEntries(source) -- 中文维护注释：仅恢复磁盘仍存在的摘要行，继续兼容 RU sequence→map 表形漂移。
    recovered = NormalizeIndex(recovered) -- 中文维护注释：恢复值进入当前 Domain normalizer 后再由 codec1/schema2 保存，不保留 opaque 历史形状。
    if store ~= nil then store.lastHistoricalRecoveryProbe = tostring(store.lastHistoricalRecoveryProbe or "") .. "/knownStamp=" .. stamp .. "/knownShape=ok" end -- 中文维护注释：记录一次性 pre-codec 恢复命中，不暴露死亡记录内容。
    return recovered, tostring(known.label or "death_review_precodec_known_stamp") -- 中文维护注释：Core 后续仍执行预算与重盖，770 桥不会进入正常 Save/Tick 路径。
end -- 中文维护注释：结束 DeathReview known-stamp 多世代恢复桥。

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
        schemaVersion = INDEX_SCHEMA, -- 中文维护注释：Index 当前写入 schema2；record 分片仍保持独立 schema1，本轮只修 Index canonical generation。
        legacySchemaVersion = 0, -- 中文维护注释：保留无元数据历史档的原 fallback 口径，带元数据 schema1 由正式 migrate/hook 迁移到 schema2。
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
        rebuildCanonicalForIntegrity = RebuildHistoricalIndexCanonical, -- 中文维护注释：统一处理 pre-codec opaque canonical 与 schema1 codec1 历史窗口 canonical；所有候选仍由 Core exact Hash 认证。
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
