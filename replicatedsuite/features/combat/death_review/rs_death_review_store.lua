-- Replicated Suite · 死亡复盘设置存储
-- 作者：Replicated
-- QQ群：1104129461
-- 账号永久存储将轻量设置/历史索引与单次死亡记录拆开，避免 RU SaveData 大表截断。最多引用 30 条记录，31 个有界物理槽提供一个事务备用位。
-- 新记录必须先写入未引用槽，再提交索引；索引写失败不能覆盖旧权威索引仍引用的记录。
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local P = S.Persistence
if type(P) ~= "table" or type(P.RegisterV3Store) ~= "function" then return end

S.Features = S.Features or {}
S.Features.DeathReview = S.Features.DeathReview or {}
local F = S.Features.DeathReview
local U = S.Utils

local INDEX_STORE = "v3.death_review"
local INDEX_SCHEMA = 2 -- schema2 正式冻结 codec1/FloatingSurface v11 canonical；旧 schema1 只读迁移。
local INDEX_CODEC_VERSION = 1
local RECORD_SCHEMA = 2
local RECORD_PREFIX = P.V3KeyPrefix .. "death_review_record_"
local MAX_HISTORY = 30
local RECORD_SLOTS = MAX_HISTORY + 1
local MAX_EVENTS = 96
local MAX_DEBUFFS = 10
local MAX_STATUSES = 32

-- 预算按编码后的 SaveData 封装计算；索引保持小型，每条时间线独立有界，任何设置都不能产生无界写入。
local INDEX_BUDGET = { maxDepth = 6, maxNodes = 1800, maxStringBytes = 24000, maxEntriesPerTable = 128 }
local RECORD_BUDGET = { maxDepth = 7, maxNodes = 2400, maxStringBytes = 48000, maxEntriesPerTable = 128 }
local RECORD_ENCODED_BUDGET = { maxDepth = 7, maxNodes = 2400, maxStringBytes = 48000, maxEntriesPerTable = 512 }

-- 死亡复盘索引保存共享 FloatingSurface 状态；每次保存/加载必须用同一纯 Foundation normalizer 生成 canonical。
-- widgetWindow 不能是不透明表，否则 Integrity v4 会哈希序列化表示（如省略 false/默认字段）而非逻辑状态，引发 RU 跨重载写保护。
local Floating = S.RSUI and S.RSUI.FloatingSurface or nil
if type(Floating) ~= "table" or type(Floating.NormalizeState) ~= "function" then
    error("FloatingSurface unavailable for DeathReview store")
end

F.PersistenceCanonicalWindowContractVersion = 7 -- 窗口字段由 Store 显式冻结，新增字段须升级 schema。
F.PersistenceIndexSchemaContractVersion = INDEX_SCHEMA
F.PersistenceKnownLegacyRecoveryContractVersion = 5 -- 73DF7418 已确认属于 Framework2/schema1/codec1，不能借抬高契约版本接受其它世代；恢复须走精确 old/new pair。
F.PersistenceSchema2Framework2RecoveryContractVersion = 2 -- v2 在 mismatch 冷路径组合恢复 history 表形与数值 0 省略，不改正常 codec/Domain。
F.PersistenceTransportV1ZeroOmissionRecoveryContractVersion = 2 -- 0 省略与表形恢复组合，最多 2^10 候选；不枚举无影响的 offsetX/Y。
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

local CURRENT_WINDOW_KEYS = { -- 当前 schema2 窗口字段白名单，不随共享 Foundation 自动扩展。
    "width", "height", "minimized", "locked",
    "overallOpacity", "backgroundOpacity", "textOpacity", "fontScale", "userMoved",
    "x", "y", "anchorH", "anchorV", "offsetX", "offsetY", "coordinateSpace", "savedUiScale",
    "savedLogicalWidth", "savedLogicalHeight", "normalizedCenterX", "normalizedCenterY",
}
local HISTORICAL_SCHEMA1_CODEC_WINDOW_KEYS = { -- schema1/codec1 历史字段，仅用于旧章恢复。
    "width", "height", "minimized", "locked",
    "overallOpacity", "backgroundOpacity", "textOpacity", "fontScale", "userMoved",
    "x", "y", "anchorH", "anchorV", "offsetX", "offsetY", "coordinateSpace", "savedUiScale",
}

local function ProjectWindow(normalized, keys)
    local out = {}
    for _, key in ipairs(keys) do
        if normalized[key] ~= nil then out[key] = normalized[key] end -- 保留显式 false/0。
    end
    return out
end

local function NormalizeWidgetWindow(value)
    return ProjectWindow(Floating:NormalizeState(value, F.WidgetWindowSizePolicy), CURRENT_WINDOW_KEYS)
end

local function NormalizeHistoricalSchema1CodecWindow(value) -- 仅旧 schema1/codec1 mismatch 调用。
    return ProjectWindow(Floating:NormalizeState(value, F.WidgetWindowSizePolicy), HISTORICAL_SCHEMA1_CODEC_WINDOW_KEYS)
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

local function NormalizeDebuff(value, extended)
    value = type(value) == "table" and value or {}
    local out = {
        effectId = tonumber(value.effectId),
        name = Text(value.name, "未知 Debuff", 120),
        stack = math.max(0, math.floor(tonumber(value.stack) or 0)),
        path = value.path ~= nil and Text(value.path, "", 240) or nil,
    }
    if extended and tonumber(value.timeLeft) ~= nil then out.timeLeft = math.max(0, tonumber(value.timeLeft)) end
    return out
end

local function NormalizeEvent(value, extended)
    value = type(value) == "table" and value or {}
    local out = {
        time = math.max(0, tonumber(value.time) or 0),
        source = Text(value.source, "未知来源", 120),
        ability = Text(value.ability, "普通攻击", 160),
        amount = math.max(0, math.floor((tonumber(value.amount) or 0) + 0.5)),
        environmental = value.environmental == true and true or nil,
    }
    if extended then
        out.abilityId = tonumber(value.abilityId) and tonumber(value.abilityId) > 0 and math.floor(tonumber(value.abilityId)) or nil
        out.iconPath = value.iconPath ~= nil and Text(value.iconPath, "", 240) or nil
    end
    return out
end

local function NormalizeRecord(value, fallbackSerial)
    value = type(value) == "table" and value or {}
    -- 保留 schema1 完整字段与默认值，旧章认证不会因新 Buff 字段而改变。
    local extended = tonumber(value.schemaVersion) == 2
    local events = {}
    for index, row in ipairs(type(value.events) == "table" and value.events or {}) do
        if index > MAX_EVENTS then break end
        local event = NormalizeEvent(row, extended)
        if event.amount > 0 then events[#events + 1] = event end
    end
    local debuffs = {}
    for index, row in ipairs(type(value.debuffs) == "table" and value.debuffs or {}) do
        if index > (extended and MAX_STATUSES or MAX_DEBUFFS) then break end
        debuffs[#debuffs + 1] = NormalizeDebuff(row, extended)
    end
    local lethal = type(value.lethal) == "table" and NormalizeEvent(value.lethal, extended) or nil
    if lethal == nil and #events > 0 then lethal = NormalizeEvent(events[#events], extended) end
    local total = 0
    for _, row in ipairs(events) do total = total + (tonumber(row.amount) or 0) end
    local out = {
        schemaVersion = extended and 2 or 1,
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
    if extended then
        out.buffs = {}
        for index, row in ipairs(type(value.buffs) == "table" and value.buffs or {}) do
            if index > MAX_STATUSES then break end
            out.buffs[#out.buffs + 1] = NormalizeDebuff(row, true)
        end
        local snapshot = type(value.statusSnapshot) == "table" and value.statusSnapshot or {}
        local function State(v)
            return (v == "complete" or v == "partial" or v == "unavailable" or v == "disabled") and v or "uncollected"
        end
        out.statusSnapshot = { time = tonumber(snapshot.time) and math.max(0, tonumber(snapshot.time)) or nil,
            buff = State(snapshot.buff), debuff = State(snapshot.debuff) }
    end
    return out
end

-- codec3 显式保留数字精度：RU 隐式转串可能把时间写成六位科学计数法，
-- decode 后变成整数再编码便无法命中原指纹。禁止把 number 直接交 table.concat。
-- 字典、行结构及 14336 Native 字节硬门不变；schema1 与 codec2 继续可读。
local function EncodeRecord(value)
    local r = NormalizeRecord(value)
    if r.schemaVersion == 1 then return r end
    local pool, keys = {}, {}
    local function Ref(v)
        if v == nil then return 0 end
        if keys[v] == nil then pool[#pool + 1] = v; keys[v] = #pool end
        return keys[v]
    end
    local function NumericRow(values)
        for i = 1, #values do values[i] = string.format("%.17g", values[i]) end
        return table.concat(values, ",")
    end
    local function Event(e)
        if e == nil then return "" end
        return NumericRow({ e.time, Ref(e.source), Ref(e.ability), e.amount, e.environmental and 1 or 0, e.abilityId or 0, Ref(e.iconPath) })
    end
    local function Status(rows)
        local result = {}
        for _, row in ipairs(rows) do result[#result + 1] = NumericRow({ row.effectId or 0, Ref(row.name), row.stack, row.timeLeft or -1, Ref(row.path) }) end
        return table.concat(result, ";")
    end
    local out = { codec = 3, serial = r.serial, time = r.time, noticeTime = r.noticeTime, clock = r.clock,
        windowMs = r.windowMs, totalDamage = r.totalDamage, lethal = Event(r.lethal), events = {},
        statusSnapshot = r.statusSnapshot }
    for _, row in ipairs(r.events) do out.events[#out.events + 1] = Event(row) end
    out.events = table.concat(out.events, ";")
    out.debuffs, out.buffs = Status(r.debuffs), Status(r.buffs)
    local packed = {}
    for _, text in ipairs(pool) do packed[#packed + 1] = tostring(#text) .. ":" .. text end
    out.strings = table.concat(packed)
    return out
end

local function DecodeRecord(raw)
    if type(raw) ~= "table" then return nil, "death record shape invalid" end
    if raw.codec == nil then return NormalizeRecord(raw.payload or raw) end
    if (raw.codec ~= 2 and raw.codec ~= 3) or type(raw.strings) ~= "string" then return nil, "death record codec invalid" end
    local strings, cursor = {}, 1
    while cursor <= #raw.strings do
        local start, finish, length = raw.strings:find("^(%d+):", cursor)
        length = tonumber(length)
        if start == nil or length > 240 or #strings >= 512 or finish + length > #raw.strings then return nil, "death record dictionary invalid" end
        strings[#strings + 1] = raw.strings:sub(finish + 1, finish + length)
        cursor = finish + length + 1
    end
    local function Lines(packed, maximum)
        if type(packed) ~= "string" or #packed > maximum * 256 then error("death record rows invalid") end
        if packed == "" then return {} end
        if packed:sub(1,1) == ";" or packed:sub(-1) == ";" or packed:find(";;",1,true) then error("death record empty row") end
        local rows = {}
        for line in packed:gmatch("[^;]+") do rows[#rows + 1] = line;if #rows > maximum then error("death record too many rows") end end
        return rows
    end
    local function Numbers(line, count)
        if type(line) ~= "string" or #line > 256 or line:sub(1,1) == "," or line:sub(-1) == "," or line:find(",,",1,true) then error("death record row invalid") end
        local row = {}
        for token in line:gmatch("[^,]+") do
            local n = tonumber(token); if n == nil or n ~= n or n == math.huge or n == -math.huge then error("death record number invalid") end
            row[#row + 1] = n
        end
        if #row ~= count then error("death record column count invalid") end
        return row
    end
    local function Str(index)
        if index == 0 then return nil end
        if index % 1 ~= 0 or type(strings[index]) ~= "string" then error("death record string reference invalid") end
        return strings[index]
    end
    local function Event(line)
        if line == "" then return nil end
        local n = Numbers(line, 7)
        return { time = n[1], source = Str(n[2]), ability = Str(n[3]), amount = n[4], environmental = n[5] == 1 and true or nil,
            abilityId = n[6] > 0 and n[6] or nil, iconPath = Str(n[7]) }
    end
    local function Status(rows)
        rows = Lines(rows, MAX_STATUSES)
        local out = {}
        for _, line in ipairs(rows) do local n = Numbers(line, 5);out[#out + 1] = { effectId = n[1] ~= 0 and n[1] or nil,
            name = Str(n[2]), stack = n[3], timeLeft = n[4] >= 0 and n[4] or nil, path = Str(n[5]) } end
        return out
    end
    local r = { schemaVersion = 2, serial = raw.serial, time = raw.time, noticeTime = raw.noticeTime, clock = raw.clock,
        windowMs = raw.windowMs, totalDamage = raw.totalDamage, lethal = Event(raw.lethal), events = {},
        debuffs = Status(raw.debuffs), buffs = Status(raw.buffs), statusSnapshot = raw.statusSnapshot }
    for _, line in ipairs(Lines(raw.events, MAX_EVENTS)) do r.events[#r.events + 1] = Event(line) end
    return NormalizeRecord(r)
end

-- codec2 的原行文本就是旧 canonical 证据；重新格式化会丢掉旧数字表示。
-- Core 已验证身份、元数据封印、decode 和预算，此处仍须全份旧指纹精确匹配。
-- 不枚举业务数值、不重盖坏章、不用于新 codec3 或本次保存回读的容错。
local function RebuildLegacyRecordCanonical(value, stamp, canonical, raw)
    local meta = type(raw) == "table" and raw.__rsmeta or nil
    if type(meta) ~= "table" or raw.codec ~= 2 or tonumber(meta.schema) ~= RECORD_SCHEMA
        or tonumber(meta.framework) ~= 3 or tonumber(meta.transportVersion) ~= 3
        or tonumber(meta.integrityVersion) ~= 4 or meta.owner ~= "v3.death_review" then return nil end
    local store = P:GetStore(meta.store)
    if store == nil or store.owner ~= "v3.death_review" or store.decode ~= DecodeRecord then return nil end
    local allowed = { codec=true, serial=true, time=true, noticeTime=true, clock=true, windowMs=true,
        totalDamage=true, lethal=true, events=true, statusSnapshot=true, debuffs=true, buffs=true, strings=true }
    local candidate = {}
    for key, field in pairs(raw) do
        if key ~= "__rsmeta" then
            if allowed[key] ~= true then return nil end
            candidate[key] = DeepCopy(field)
        end
    end
    if P:FingerprintCanonicalValue(store, candidate) ~= stamp then return nil end
    return candidate
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
        -- 旧版将 Presentation 子树视为不透明；其精确历史 canonical 形态仅用于持久恢复 hook，当前 Domain 禁止走此路径。
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

local function DefaultIndex()
    -- 仅发行默认使用20；旧 schema2 缺失字段仍按 NormalizeSettings 的10验章。
    return NormalizeIndex({ settings = { maxHistory = 20 } })
end

-- 索引 codec 必须稳定往返 RU 序列化器，后者可能省略 false。默认 true 的业务开关保存反向状态为数值哨兵 1，缺哨兵明确表示默认 true。
-- FloatingSurface 布尔默认 false，共享 normalizer 确定性补回缺失 false，因此仍安全。
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

    -- 旧普通 Store 包装为 {payload=Domain,__rsmeta}；回退也接受开发测试/迁移探测的裸 Domain。只读取同一 Store key，禁止读取旧插件 key。
    local source = type(raw.__rsmeta) == "table" and type(raw.payload) == "table" and raw.payload or raw
    return NormalizeIndex(source), nil
end

local function RebuildHistoricalCodecV1Canonical(rawEnvelope)
    if type(rawEnvelope) ~= "table" or tonumber(rawEnvelope.codec) ~= INDEX_CODEC_VERSION or type(rawEnvelope.payload) ~= "table" then return nil end
    local decoded, decodeErr = DecodeIndex(rawEnvelope)
    if type(decoded) ~= "table" or decodeErr ~= nil then return nil end
    local encodedSettings = { -- codec1 保留数值 sentinel，不能退回旧默认 true 布尔形状。
        windowMs = decoded.settings.windowMs,
        maxHistory = decoded.settings.maxHistory,
        minDamage = decoded.settings.minDamage,
    }
    if decoded.settings.autoShow == false then encodedSettings.autoShowDisabled = 1 end -- 关闭用数值 sentinel，避免 false 被省略。
    if decoded.settings.showDebuffs == false then encodedSettings.showDebuffsDisabled = 1 end
    local historicalCanonical = {
        codec = INDEX_CODEC_VERSION,
        payload = {
            settings = encodedSettings,
            history = DeepCopy(decoded.history), -- 历史摘要用正式 decoder，不读分片或改 serial/storageId。
            widgetWindow = NormalizeHistoricalSchema1CodecWindow(rawEnvelope.payload.widgetWindow), -- 只回退窗口字段，其余业务内容不猜。
        },
    }
    return historicalCanonical, decoded
end -- 旧 codec1 将 widgetWindow 当不透明表；默认 true 的开关若 false 被 RU 省略，会无法复现旧章。
-- 仅枚举缺失默认 true 开关曾为 false，以及纯 Floating normalizer 可补的窗口字段；全 canonical 精确命中旧章才返回。
-- 最多 12 处变化/4096 候选，只运行于历史写保护加载。
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

-- 恢复器可收集 RU 序列/map 形态漂移的行；正常 codec 仍要求严格序列，候选必须精确命中旧章。
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
        -- 当前 codec 数据必须由当前 codec 验证；畸形当前封装禁止回退到历史形态恢复。
        if rawEnvelope.codec ~= nil then return nil end
        if type(rawEnvelope.payload) == "table" then source = rawEnvelope.payload end
    end
    source = type(source) == "table" and source or {}
    local strictHistorical = NormalizeIndexWithWindow(source, "legacy_opaque_18_145")
    local recoveredEntriesHistorical = NormalizeHistoricalIndexWithRecoveredEntries(source)
    local store = P:GetStore(INDEX_STORE)
    if store == nil or stampedFingerprint == nil then return strictHistorical, NormalizeIndex(strictHistorical) end

    -- 旧指纹无法重建时，为下一次 RU Fresh Reload 保留仅会话、仅形态证据；禁止暴露玩家名称、伤害值、serial 或死亡 payload 内容。
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

-- Framework2 和 Framework3/Transport1 共用数值 0 省略恢复；Core 仍校验 seal、预算和最终指纹。
-- 只枚举 nil/0 会改变 canonical 的 10 个字段，最多 1024 组合。offsetX/Y 缺省本就为 0，不能列入候选白增预算。
-- 不读 Native、屏幕或记录分片。
local ZERO_OMISSION_WINDOW_KEYS = {
    "x", "y", -- free 模式成立条件；任一 0 被删都会让整组 free 定位字段塌陷。
    "normalizedCenterX", "normalizedCenterY", -- 跨分辨率归一化中心允许边界值 0。
    "savedLogicalWidth", "savedLogicalHeight", -- free 模式下直接参与 schema2 canonical。
    "overallOpacity", "backgroundOpacity", "textOpacity", -- 显式 0 与默认 0.96/1/1 不等价。
    "savedUiScale", -- moved 状态下显式 0 与 nil 不等价；保留用于历史 exact reconstruction。
}
local MAX_ZERO_OMISSION_CANDIDATES = 1024

local function TryRebuildZeroOmittedWindowCanonical(baseDomain, rawWindow, stampedFingerprint, probePrefix, metaDesc)
    local store = P:GetStore(INDEX_STORE) -- 仅用于 exact Hash 与 runtime-only probe；业务状态 Authority 仍在 F.State。
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
        -- 理论上当前字段表最多 10 位，因此只有未来维护错误扩大列表才会命中此保护。
        -- 宁可保持 write fence，也禁止冷启动无界暴力枚举。
        Probe("skip_too_many", tostring(metaDesc or "") .. "/missing=" .. table.concat(missing, ","))
        return nil
    end

    -- settings/history 固定来自同一已解码/已恢复 Domain，只枚举窗口中“缺失字段原值是否为 0”。
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

local function RebuildFramework2Schema2CodecV1Canonical(rawEnvelope, stampedFingerprint) -- 仅 Framework2/schema2/codec1 的表形与 0 省略恢复，仍须精确命中旧章；73DF7418 不属于此世代。

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

    -- 返回原表形候选保持既有 fail-closed 行为；Core 仍会重新 Hash，不匹配就继续 known-stamp/Fence。
    return historicalCanonical, recoveredDomain
end

local function RebuildTransportV1ZeroOmissionCanonical(decoded, stampedFingerprint, currentCanonical, rawEnvelope) -- `.18.199` Transport v1 也改用 shared solver；同时先恢复 history map/sequence 表形，防止同一次 Native 往返出现两种表示漂移时只能修其中一种。
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

    -- 先测试“只有 sequence/map 漂移”这一候选；若已经命中，无需进入零值枚举。
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
end

-- 旧 decode 的 ipairs 会先丢字符串序号，恢复须从已过预算/seal 的 raw 按原序号重建，再经原 Decode/Encode 比整份旧章。
-- 仅完整 1..N、最多 MAX_HISTORY，拒绝稀疏/重复/非法序号；不补 serial/storageId、不读分片。
-- 删除无 storageId 行只会复现失败 canonical，不能作为恢复；引用丢失且无法证明原内容时继续写保护。
local function DescribeIncompleteHistory(rawEnvelope)
    local payload = type(rawEnvelope) == "table" and rawEnvelope.payload or nil
    local history = type(payload) == "table" and payload.history or nil
    if type(history) ~= "table" or type(P.RebuildDenseSequenceForIntegrity) ~= "function" then return nil end
    local rows = P:RebuildDenseSequenceForIntegrity(history.entries, MAX_HISTORY)
    if type(rows) ~= "table" then return nil end -- 非法/稀疏序列的拒绝证据由既有 sequence 门保留。
    local bad, first, fieldCount, missing = 0, nil, 0, {}
    for index, row in ipairs(rows) do
        local sid = type(row) == "table" and tonumber(row.storageId) or nil
        if sid == nil or sid ~= sid or sid < 1 or sid > RECORD_SLOTS or sid ~= math.floor(sid) then
            bad = bad + 1
            if first == nil then
                first = index
                for _ in pairs(type(row) == "table" and row or {}) do fieldCount = fieldCount + 1 end
                for _, key in ipairs({ "serial", "storageId", "time", "clock", "windowMs", "totalDamage",
                    "lethalSource", "lethalAbility", "lethalAmount", "eventCount", "debuffCount" }) do
                    if type(row) ~= "table" or row[key] == nil then missing[#missing + 1] = key end
                end
            end
        end
    end
    if bad == 0 then return nil end
    return "history=incomplete/rows=" .. tostring(#rows) .. "/kept=" .. tostring(#rows - bad)
        .. "/invalid=" .. tostring(bad) .. "/row=" .. tostring(first) .. "/fields=" .. tostring(fieldCount)
        .. "/missing=" .. table.concat(missing, "+")
end

local function RebuildTransportV2SequenceCanonical(rawEnvelope, stampedFingerprint)
    -- v3 只解决标量精度，不改变序列键风险；已解码 v2/v3 共用严格索引重建。
    -- 这里不是死亡回顾未知数值指纹的恢复；仍须整表原指纹精确一致。
    local probe = "schema2tv" .. tostring(rawEnvelope.__rsmeta.transportVersion)
    local store = P:GetStore(INDEX_STORE)
    local payload = type(rawEnvelope.payload) == "table" and rawEnvelope.payload or nil
    local history = payload and type(payload.history) == "table" and payload.history or nil
    if history == nil or type(P.RebuildDenseSequenceForIntegrity) ~= "function" then
        if store then store.lastHistoricalRecoveryProbe = probe .. "/sequence=unavailable" end
        return nil
    end
    local rows, reason, changed = P:RebuildDenseSequenceForIntegrity(history.entries, MAX_HISTORY)
    if rows == nil or not changed then
        if store then store.lastHistoricalRecoveryProbe = probe .. "/sequence=" .. tostring(reason or "unchanged") end
        -- 第三返回值是严格序列检查的结构事实，不解析诊断文本决定是否能恢复。
        -- 改日志措辞/禁用日志不得改变业务门禁；非法序列明确false，完整未改序列才true。
        return nil, nil, rows ~= nil and changed ~= true
    end
    local recoveredRaw = DeepCopy(rawEnvelope)
    recoveredRaw.payload.history.entries = rows
    local recovered = DecodeIndex(recoveredRaw)
    if recovered == nil then
        if store then store.lastHistoricalRecoveryProbe = probe .. "/sequence=decode_failed" end
        return nil
    end
    local canonical = EncodeIndex(recovered)
    local fingerprint = store and P:FingerprintCanonicalValue(store, canonical) or nil
    local matched = fingerprint ~= nil and tostring(fingerprint) == tostring(stampedFingerprint)
    if store then store.lastHistoricalRecoveryProbe = probe .. "/rows=" .. tostring(#rows)
        .. "/hfp=" .. tostring(fingerprint) .. "/old=" .. tostring(stampedFingerprint) .. "/matched=" .. tostring(matched) end
    -- 表形重建不是内容认证；不匹配时不得提前返回候选。
    -- false 明确表示序列发生过变化，不能借后续“未变序列”精度桥组合猜测多个损失。
    if not matched then return nil, nil, false end
    return canonical, recovered
end

-- binary32 可能把非整数毫秒变整数，使旧指纹格式从 %.6g 切到 %.0f。
-- 仅当前 codec1/schema2/Transport2 的 time token 可试，最多 8 个 time/255 子集，其余字段完全不动；唯一旧章命中才接受。
-- 返回仍是读到的数值/顺序，不伪造丢失小数、不读分片。模型只解释本次证据，正常 Load/Transport3 不走此路。
local function RebuildRoundedHistoryTimeCanonical(value, stamp, canonical, rawEnvelope)
    local st=P:GetStore(INDEX_STORE)
    local meta=type(rawEnvelope)=='table' and rawEnvelope.__rsmeta or nil
    if type(st)~='table' or type(meta)~='table' or meta.store~=INDEX_STORE or meta.owner~=st.owner
        or tonumber(meta.framework)~=3 or tonumber(meta.schema)~=2 or tonumber(meta.transportVersion)~=2
        or tonumber(meta.integrityVersion)~=4 or rawEnvelope.codec~=1
        or type(stamp)~='string' or #stamp~=8 or stamp:find('[^%x]') then return nil end
    local function Probe(text)st.lastHistoricalRecoveryProbe=tostring(st.lastHistoricalRecoveryProbe or '')..'/timestamp='..text end
    if type(canonical)~='table' or canonical.codec~=1 or type(canonical.payload)~='table'
        or P:InspectPayload(canonical,st.encodedBudget).ok~=true then return nil end
    -- 先严格对照完整codec业务树；拒绝靠normalizer删未知字段/记录后借time匹配。
    local function Equal(a,b,depth)
        if type(a)~=type(b) or depth>12 then return false end
        if type(a)~='table'then return a==b end
        for k,v in pairs(a)do if not Equal(v,b[k],depth+1)then return false end end
        for k in pairs(b)do if a[k]==nil then return false end end
        return true
    end
    if not Equal(canonical.payload,rawEnvelope.payload,0)then Probe('shape');return nil end
    local history=canonical.payload.history
    local entries=type(history)=='table'and history.entries or nil
    if type(entries)~='table' then return nil end
    local indices,witnesses={},{}
    for i,row in ipairs(entries)do
        local n=type(row)=='table'and row.time or nil
        -- 此范围确保binary32 ULP<=1且%.6g非整数分支为科学计数；小时间/大时间未获本次证明。
        if type(n)=='number' and n==math.floor(n) and n>=1000000 and n<16777216 then
            indices[#indices+1]=i
            if #indices>8 then Probe('budget');return nil end
            local _,exponent=math.frexp(n)
            local fraction=2^(exponent-26) -- binary32 ULP/4，严格位于同一个round-to-nearest单元
            witnesses[#witnesses+1]=n+fraction
        end
    end
    if #indices==0 then Probe('no_candidates');return nil end
    local candidate=DeepCopy(canonical)
    local matches,matched,changed=0,nil,0
    for mask=1,2^#indices-1 do
        local count=0
        for j,index in ipairs(indices)do
            local use=math.floor(mask/2^(j-1))%2==1
            candidate.payload.history.entries[index].time=use and witnesses[j]or entries[index].time
            if use then count=count+1 end
        end
        if P:FingerprintCanonicalValue(st,candidate)==stamp then
            matches=matches+1;matched=DeepCopy(candidate);changed=count
        end
    end
    Probe('tested'..tostring(2^#indices-1)..':hits'..matches..':changed'..changed)
    if matches==1 then return matched,DeepCopy(value) end
    return nil
end

-- 仅 settings 与摘要尾部同时丢失的 schema2/tv3 冷路径，
-- 经 Persistence 验证最多31个记录分片。保留字段逐项相同、序列完整、唯一原指纹命中
-- 才返回候选；Core仍拥有最终Apply/重写/回读/Fence。正常加载不扫描、未知损坏不默认化。
local function RebuildTruncatedIndexFromRecords(raw, stamp)
    local st=P:GetStore(INDEX_STORE)
    local meta=type(raw)=='table' and raw.__rsmeta or nil
    local payload=type(raw)=='table' and raw.payload or nil
    local history=type(payload)=='table' and payload.history or nil
    if type(meta)~='table' or meta.store~=INDEX_STORE or meta.owner~='v3.death_review'
        or meta.framework~=3 or meta.schema~=2 or meta.transportVersion~=3 or meta.integrityVersion~=4
        or raw.codec~=1 or type(payload)~='table' or payload.settings~=nil
        or type(history)~='table' or type(history.serial)~='number' or history.serial<MAX_HISTORY or history.serial>16777216
        or history.serial~=math.floor(history.serial) or type(F.LoadRecord)~='function'
        or P:FingerprintEnvelopeIntegrity(raw)~=meta.envelopeFingerprint then return nil end
    local rows=P:RebuildDenseSequenceForIntegrity(history.entries,MAX_HISTORY)
    if type(rows)~='table' or #rows<1 or #rows>=MAX_HISTORY then return nil end
    local function Probe(reason)st.lastHistoricalRecoveryProbe=tostring(st.lastHistoricalRecoveryProbe or '')..'/shard_rebuild='..reason end
    local bySerial,entries={},{}
    for slot=1,RECORD_SLOTS do
        local record,err=F:LoadRecord(slot)
        if record==nil and err~=nil then Probe('record_rejected:'..slot);return nil end
        if record and record.serial>history.serial-MAX_HISTORY and record.serial<=history.serial then
            if bySerial[record.serial] then Probe('duplicate_serial');return nil end
            bySerial[record.serial]=SummaryFromRecord(record,slot)
        end
    end
    for serial=history.serial-MAX_HISTORY+1,history.serial do
        local row=bySerial[serial]
        if row==nil then Probe('missing_serial:'..serial);return nil end
        entries[#entries+1]=row
    end
    for i,row in ipairs(rows) do
        if type(row)~='table' then Probe('retained_row_type');return nil end
        for key,v in pairs(row) do
            if entries[i][key]==nil or entries[i][key]~=v then Probe('retained_mismatch:'..i..':'..tostring(key));return nil end
        end
    end
    local windowMs=entries[1].windowMs
    for _,row in ipairs(entries) do if row.windowMs~=windowMs then Probe('mixed_window');return nil end end
    local hits,matched,domain=0,nil,nil
    for mask=0,3 do
        local candidateDomain={settings={maxHistory=MAX_HISTORY,windowMs=windowMs,minDamage=0,
            autoShow=mask%2==0,showDebuffs=math.floor(mask/2)%2==0},widgetWindow=DeepCopy(payload.widgetWindow),
            history={serial=history.serial,entries=DeepCopy(entries)}}
        local candidate=EncodeIndex(candidateDomain)
        if P:FingerprintCanonicalValue(st,candidate)==stamp then hits=hits+1;matched=candidate;domain=candidateDomain end
    end
    Probe('rows='..#entries..'/hits='..hits)
    if hits==1 then return matched,domain end
    return nil
end

local function RebuildHistoricalIndexCanonical(value, stampedFingerprint, currentCanonical, rawEnvelope) -- 按 schema/framework/codec 分代路由历史恢复，先结构证明，再 known-pair。
    local meta = type(rawEnvelope) == "table" and rawEnvelope.__rsmeta or nil
    -- 入口先记真实世代，再由分支补原因，区分 hook 未调用与调用后无匹配。
    do
        local entryStore = P:GetStore(INDEX_STORE)
        if type(entryStore) == "table" then
            entryStore.lastHistoricalRecoveryProbe = "enter/schema=" .. tostring(meta ~= nil and tonumber(meta.schema) or nil)
                .. "/fw=" .. tostring(meta ~= nil and tonumber(meta.framework) or nil)
                .. "/tv=" .. tostring(meta ~= nil and tonumber(meta.transportVersion) or nil)
                .. "/codec=" .. tostring(type(rawEnvelope) == "table" and tonumber(rawEnvelope.codec) or nil)
                .. "/stamped=" .. tostring(stampedFingerprint) -- stamped 只是 32 位 Hash，不含任何业务内容。
        end
    end
    -- 当前世代也可能仅序列键形变化；身份/schema/codec/transport 明确匹配。
    if type(meta) == "table" and meta.store == INDEX_STORE and meta.owner == "v3.death_review"
        and tonumber(meta.schema) == INDEX_SCHEMA and tonumber(meta.framework) == 3
        -- 数值传输升级后保留原 schema/codec/owner 门，不能让已修复的字符串序号回读回归。
        and (tonumber(meta.transportVersion) == 2 or tonumber(meta.transportVersion) == 3 or tonumber(meta.transportVersion) == 6)
        and tonumber(rawEnvelope.codec) == INDEX_CODEC_VERSION then
        local candidate, domain, sequenceUnchanged = RebuildTransportV2SequenceCanonical(rawEnvelope, stampedFingerprint)
        if candidate ~= nil then return candidate, domain end
        -- 缺引用是残缺索引，不是可以凭删除行修复的数值误差。
        -- 这里明确报告首次残缺行及缺字段；正常序列继续走原有精度桥，未知内容仍保留写保护。
        local incomplete = DescribeIncompleteHistory(rawEnvelope)
        if incomplete ~= nil then
            local failedStore = P:GetStore(INDEX_STORE)
            if failedStore then failedStore.lastHistoricalRecoveryProbe = tostring(failedStore.lastHistoricalRecoveryProbe or "") .. "/" .. incomplete end
            return RebuildTruncatedIndexFromRecords(rawEnvelope,stampedFingerprint)
        end
        -- codec1的原指纹覆盖{codec,payload}，不能拿Domain直接算。
        -- 严格序列已证明未改变时才尝试两个既有中心比例；稀疏/坏序列不得借窗口桥丢掉历史。
        -- Core验旧章后才Apply；不读record分片、不依赖DPS、不变更schema2或history排序。
        local st = P:GetStore(INDEX_STORE)
        if sequenceUnchanged and type(P.RebuildFixed6WindowCanonical) == "function" then
            local windowCandidate,windowDomain=P:RebuildFixed6WindowCanonical(st, value, stampedFingerprint, currentCanonical,
                rawEnvelope, INDEX_SCHEMA, INDEX_CODEC_VERSION)
            if windowCandidate~=nil then return windowCandidate,windowDomain end
        end
        -- 实际udf已证明time分支；仅严格未变序列可进入，窗口桥不命中才尝试，不能组合任意损失。
        if sequenceUnchanged then
            return RebuildRoundedHistoryTimeCanonical(value,stampedFingerprint,currentCanonical,rawEnvelope)
        end
        return nil
    end
    if type(meta) == "table" and tonumber(meta.schema) == INDEX_SCHEMA and tonumber(meta.framework) == 2 and tonumber(type(rawEnvelope) == "table" and rawEnvelope.codec or nil) == INDEX_CODEC_VERSION then -- Framework2/schema2 尚无 Transport，先试表形与零值组合恢复。
        return RebuildFramework2Schema2CodecV1Canonical(rawEnvelope, stampedFingerprint)
    end
    if type(meta) == "table" and tonumber(meta.schema) == INDEX_SCHEMA and tonumber(meta.framework) == 3
        and tonumber(meta.transportVersion) == 1 and tonumber(type(rawEnvelope) == "table" and rawEnvelope.codec or nil) == INDEX_CODEC_VERSION then -- Transport1 的数值 0 省略先作结构化证明。
        return RebuildTransportV1ZeroOmissionCanonical(value, stampedFingerprint, currentCanonical, rawEnvelope)
    end
    if type(meta) == "table" and tonumber(meta.schema) == 1 and tonumber(type(rawEnvelope) == "table" and rawEnvelope.codec or nil) == INDEX_CODEC_VERSION then
        return RebuildHistoricalCodecV1Canonical(rawEnvelope)
    end
    return RebuildV18_145Canonical(value, stampedFingerprint, currentCanonical, rawEnvelope) -- pre-codec schema1 用有界 opaque-window/default-false 恢复，不接受未来 schema。
end
-- Core 先验证 v6+ seal、metadata/schema 和预算，精确历史重建失败后才试已知 pair。严格验证旧 Domain 后立即按当前 codec 重盖，不能清档或扩大搜索。
local KNOWN_LEGACY_V4_INDEX_FINGERPRINTS = { -- known-stamp 仅记录真实 RU 事故身份；未知 Hash 永远不能通过该表。
    ["770CB0B8"] = { label = "ru_2026_09_07_precodec_v4_index", representation = "precodec" }, -- 保留 `.18.151` 已验证的 pre-codec 桥；其安全边界仍是 strict legacy shape + exact old stamp。
    ["014277AB"] = { label = "ru_2026_09_09_schema1_codec1_window_generation", representation = "codec1", currentFingerprint = "0CF5BCC1" }, -- `.18.192` 实机新事故必须同时命中 old=014277AB 与 current=0CF5BCC1，防止真实内容变化被误迁移。
    ["73DF7418"] = { label = "ru_2026_09_11_schema1_framework2_codec1_index_drift", representation = "schema1_framework2_codec1", currentFingerprint = "224E5B9D" }, -- 73DF7418 的恢复只接受 Framework2/schema1/无 Transport/codec1，并同时匹配 Store/owner、严格形状和 old/new 双 Hash；不能借用到未来世代。
    ["55BD6B0A"] = { label = "ru_2026_09_10_schema2_transport1_window_field_loss", representation = "schema2_transport1", currentFingerprint = "44CFFAF4" }, -- RU 已丢失窗口四个响应式字段，无法从 Hash 反推原值，只能按已核实 exact pair 迁移，再用当前 Transport 重写。
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

local CODEC_V1_PAYLOAD_KEYS = { settings = true, history = true, widgetWindow = true } -- codec1 只接受固定 payload 根字段。
local CODEC_V1_SETTINGS_KEYS = { autoShowDisabled = true, windowMs = true, maxHistory = true, minDamage = true, showDebuffsDisabled = true } -- 设置仅允许数值 sentinel 和三个数值项。
local CODEC_V1_WINDOW_KEYS = { opacity = true } -- 验证兼容旧 opacity，保存仍用 overallOpacity。
for _, key in ipairs(CURRENT_WINDOW_KEYS) do CODEC_V1_WINDOW_KEYS[key] = true end -- 允许 schema1 已有 v10/v11 窗口字段，拒绝未来字段。

local function ValidateCodecV1IndexPayload(rawEnvelope)
    if type(rawEnvelope) ~= "table" or tonumber(rawEnvelope.codec) ~= INDEX_CODEC_VERSION or type(rawEnvelope.payload) ~= "table" then return false, "codec_envelope" end
    local payload = rawEnvelope.payload
    local ok, err = HasOnlyKeys(payload, CODEC_V1_PAYLOAD_KEYS)
    if ok ~= true then return false, "payload:" .. tostring(err) end
    if type(payload.settings) ~= "table" then return false, "settings_required" end
    ok, err = HasOnlyKeys(payload.settings, CODEC_V1_SETTINGS_KEYS)
    if ok ~= true then return false, "settings:" .. tostring(err) end
    for _, key in ipairs({ "autoShowDisabled", "showDebuffsDisabled", "windowMs", "maxHistory", "minDamage" }) do if payload.settings[key] ~= nil and tonumber(payload.settings[key]) == nil then return false, "settings_number:" .. key end end
    local historyOk, historyReason = ValidateLegacyIndexPayload({ settings = {}, history = payload.history }) -- 复用原有 bounded serial/storageId/type 验证。
    if historyOk ~= true then return false, "history:" .. tostring(historyReason) end
    if payload.widgetWindow ~= nil then
        ok, err = HasOnlyKeys(payload.widgetWindow, CODEC_V1_WINDOW_KEYS)
        if ok ~= true then return false, "window:" .. tostring(err) end
        for _, key in ipairs({ "minimized", "locked", "userMoved" }) do if payload.widgetWindow[key] ~= nil and type(payload.widgetWindow[key]) ~= "boolean" then return false, "window_bool:" .. key end end
        for _, key in ipairs({ "width", "height", "opacity", "overallOpacity", "backgroundOpacity", "textOpacity", "fontScale", "x", "y", "offsetX", "offsetY", "savedUiScale", "savedLogicalWidth", "savedLogicalHeight", "normalizedCenterX", "normalizedCenterY" }) do if payload.widgetWindow[key] ~= nil and tonumber(payload.widgetWindow[key]) == nil then return false, "window_number:" .. key end end
        for _, key in ipairs({ "anchorH", "anchorV", "coordinateSpace" }) do if payload.widgetWindow[key] ~= nil and type(payload.widgetWindow[key]) ~= "string" then return false, "window_text:" .. key end end
    end
    return true
end

local function RecoverKnownLegacyV4Index(decoded, stampedFingerprint, currentCanonical, rawEnvelope) -- known-stamp 只作最终恢复桥，必须在精确历史重建失败后使用。
    local stamp = tostring(stampedFingerprint or "")
    local known = KNOWN_LEGACY_V4_INDEX_FINGERPRINTS[stamp]
    if type(known) ~= "table" then return nil end
    local meta = type(rawEnvelope) == "table" and rawEnvelope.__rsmeta or nil
    local store = P:GetStore(INDEX_STORE)
    if type(meta) ~= "table" or tostring(meta.store or "") ~= INDEX_STORE or tostring(meta.owner or "") ~= "v3.death_review" then
        if store ~= nil then store.lastHistoricalRecoveryProbe = "knownStamp=" .. stamp .. "/identity=reject:store=" .. tostring(type(meta) == "table" and meta.store or nil) .. ",owner=" .. tostring(type(meta) == "table" and meta.owner or nil) end
        return nil
    end
    if known.representation == "schema1_framework2_codec1" then
        if tonumber(meta.schema) ~= 1 or tonumber(meta.framework) ~= 2 or meta.transportVersion ~= nil then -- Framework/schema/transport 必须与实机事故同代，不能因 Hash 相同跨代恢复。
            if store ~= nil then store.lastHistoricalRecoveryProbe = "knownStamp=" .. stamp .. "/schema1Fw2Generation=reject:s=" .. tostring(meta.schema) .. ",fw=" .. tostring(meta.framework) .. ",tv=" .. tostring(meta.transportVersion) end
            return nil
        end -- Framework2/schema1 必须没有 transportVersion。
        local valid, reason = ValidateCodecV1IndexPayload(rawEnvelope) -- Hash 标识事故，不能代替 payload 形状/类型验证。
        if valid ~= true then
            if store ~= nil then store.lastHistoricalRecoveryProbe = "knownStamp=" .. stamp .. "/schema1Fw2Shape=reject:" .. tostring(reason) end
            return nil
        end
        local currentFingerprint = store ~= nil and P:FingerprintCanonicalValue(store, currentCanonical) or nil -- 当前章须精确等于实机 224E5B9D，才证明同一表示事故。
        if tostring(currentFingerprint or "") ~= tostring(known.currentFingerprint or "") then
            if store ~= nil then store.lastHistoricalRecoveryProbe = "knownStamp=" .. stamp .. "/schema1Fw2Shape=ok/current=reject:" .. tostring(currentFingerprint) .. "!=" .. tostring(known.currentFingerprint) end
            return nil
        end
        if store ~= nil then store.lastHistoricalRecoveryProbe = "knownStamp=" .. stamp .. "/schema1Fw2Shape=ok/current=" .. tostring(currentFingerprint) end
        return NormalizeIndex(decoded), tostring(known.label or "death_review_schema1_framework2_known_pair") -- 保留已解码 Domain，由 Core 迁移 schema1→2 并按当前 Transport 重盖。
    end
    if known.representation == "schema2_transport1" then -- schema2/Framework3/Transport1 的响应式窗口字段物理丢失，只接受已核实 exact pair，一次性迁移。
        if tonumber(meta.schema) ~= INDEX_SCHEMA or tonumber(meta.framework) ~= 3 or tonumber(meta.transportVersion) ~= 1 then return nil end
        if type(store) == "table" then store.lastHistoricalRecoveryProbe = "knownStamp=" .. stamp .. "/transport1Shape=check" end
        local valid, reason = ValidateCodecV1IndexPayload(rawEnvelope)
        if valid ~= true then if store ~= nil then store.lastHistoricalRecoveryProbe = "knownStamp=" .. stamp .. "/transport1Shape=reject:" .. tostring(reason) end; return nil end
        local currentFingerprint = store ~= nil and P:FingerprintCanonicalValue(store, currentCanonical) or nil
        if tostring(currentFingerprint or "") ~= tostring(known.currentFingerprint or "") then return nil end
        if store ~= nil then store.lastHistoricalRecoveryProbe = "knownStamp=" .. stamp .. "/transport1Shape=ok/current=" .. tostring(currentFingerprint) end
        return NormalizeIndex(decoded), tostring(known.label or "death_review_transport1_known_pair")
    end
    if tonumber(meta.schema) ~= 1 then return nil end -- 其余 known-stamp 分支只服务旧 schema1；当前 schema 的 mismatch 由结构化恢复器处理。
    if known.representation == "codec1" then
        local valid, reason = ValidateCodecV1IndexPayload(rawEnvelope)
        if valid ~= true then if store ~= nil then store.lastHistoricalRecoveryProbe = tostring(store.lastHistoricalRecoveryProbe or "") .. "/knownStamp=" .. stamp .. "/codec1Shape=reject:" .. tostring(reason) end; return nil end
        local currentFingerprint = store ~= nil and P:FingerprintCanonicalValue(store, currentCanonical) or nil
        if tostring(currentFingerprint or "") ~= tostring(known.currentFingerprint or "") then return nil end -- 只认 014277AB→0CF5BCC1，同旧章但当前内容不同仍拒绝。
        if store ~= nil then store.lastHistoricalRecoveryProbe = tostring(store.lastHistoricalRecoveryProbe or "") .. "/knownStamp=" .. stamp .. "/codec1Shape=ok/current=" .. tostring(currentFingerprint) end
        return NormalizeIndex(decoded), tostring(known.label or "death_review_codec1_known_pair")
    end
    if known.representation ~= "precodec" or type(rawEnvelope) ~= "table" or rawEnvelope.codec ~= nil or type(rawEnvelope.payload) ~= "table" then return nil end -- 770CB0B8 只供无 codec 的 pre-.18.149，不与 codec1 混用。
    local source = rawEnvelope.payload
    local valid, reason = ValidateLegacyIndexPayload(source)
    if valid ~= true then
        if store ~= nil then store.lastHistoricalRecoveryProbe = tostring(store.lastHistoricalRecoveryProbe or "") .. "/knownStamp=" .. stamp .. "/knownShape=reject:" .. tostring(reason) end
        return nil
    end
    local recovered = NormalizeHistoricalIndexWithRecoveredEntries(source) -- 只保留磁盘尚存摘要，兼容 sequence→map，不猜记录。
    recovered = NormalizeIndex(recovered)
    if store ~= nil then store.lastHistoricalRecoveryProbe = tostring(store.lastHistoricalRecoveryProbe or "") .. "/knownStamp=" .. stamp .. "/knownShape=ok" end
    return recovered, tostring(known.label or "death_review_precodec_known_stamp")
end

F.StoreId = INDEX_STORE
F.IndexBudget = INDEX_BUDGET
F.RecordBudget = RECORD_BUDGET
F.MaxHistory = MAX_HISTORY
F.RecordSlots = RECORD_SLOTS
F.State = type(F.State) == "table" and NormalizeIndex(F.State) or DefaultIndex()
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
        schemaVersion = INDEX_SCHEMA, -- Index 仍为 schema2；record 分片独立支持 schema1 历史和 schema2 状态图标。
        legacySchemaVersion = 0, -- 保留无元数据历史档的原 fallback 口径，带元数据 schema1 由正式 migrate/hook 迁移到 schema2。
        key = P.V3KeyPrefix .. "death_review_index",
        budget = INDEX_BUDGET,
        transportVersion = 6, -- 仅物理摘要压紧；历史1..5解码永久兼容，Domain/schema/指纹不变。
        nativeByteBudget = 14336, -- 预留实机16383字节边界余量，超预算先拒绝再写入。
        default = DefaultIndex,
        get = function() return NormalizeIndex(F.State) end,
        apply = ApplyIndex,
        encode = EncodeIndex,
        decode = DecodeIndex,
        migrate = function(value) return NormalizeIndex(value) end,
        -- 旧存档为不透明 widgetWindow 盖章，RU 可能省略 false 业务/窗口字段。只有 envelope seal 成功后，Persistence 才可测试此有界历史候选。
        -- 必须精确复现原 stamp 才能接受，再由当前 Store 归一化历史逻辑值并立即重打指纹。
        rebuildCanonicalForIntegrity = RebuildHistoricalIndexCanonical, -- 统一处理 pre-codec opaque canonical 与 schema1 codec1 历史窗口 canonical；所有候选仍由 Core exact Hash 认证。
        -- 当前索引序列已覆盖保存回读回归；只授权 Core 精确表示验真，
        -- 不开放旧世代回读迁移，不改历史记录 Authority 或分片生命周期。
        recoverReadbackRepresentation = true,
        recoverKnownLegacyCanonical = RecoverKnownLegacyV4Index,
        -- 索引 Domain 是固定形态归一化输出，canonical v3 指纹不随 RU 表示变化。该显式选项允许单代受控恢复旧 v2 原始封装指纹；仍需 envelope seal、完整 decode/预算验证，升级保存时改盖 v3。
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
        encodedBudget = RECORD_ENCODED_BUDGET,
        nativeByteBudget = 14336,
        encode = EncodeRecord,
        decode = DecodeRecord,
        rebuildCanonicalForIntegrity = RebuildLegacyRecordCanonical,
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
    -- 分片必须立即回读验真后才能把引用提交到索引。
    -- 只对本次事务写启用验证；不更改 Store 注册 flag，避免改变旧 integrity 世代的兼容门。
    local ok, err = P:SaveStore(id, { consumeDirty = true, allowUnloadedWrite = true, verifyAfterSave = true, reason = "death_review_record" })
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
    -- SaveData=true 不代表完整落盘。Core 回读失败保留物理写入
    -- 未验证证据，下面只回滚 RAM；不能声称已经还原磁盘，也不能向调用者发布“提交成功”。
    local indexOk, indexErr = P:SaveStore(INDEX_STORE, { consumeDirty = true, verifyAfterSave = true, reason = "death_review_index_commit" })
    if indexOk ~= true then
        self.State.history = previousIndex
        return false, indexErr
    end
    return true, DeepCopy(record)
end

function F:MarkStoreDirty(delayMs, reason)
    -- 窗口位置、折叠、锁定只立即提交轻量索引并回读，不写记录分片；连续预览不走此入口。
    if reason == "widget_geometry" or reason == "widget_layout_reset" or reason == "widget_minimized" or reason == "widget_locked" or reason == "widget_lock"
        or reason == "widget_overall_opacity" or reason == "widget_background_opacity" or reason == "widget_text_opacity" or reason == "widget_font_scale" then
        return P:SaveStore(INDEX_STORE, { durable=true, consumeDirty=true, reason=reason })
    end
    return P:MarkDirty(INDEX_STORE, tonumber(delayMs) or 350, reason or "death_review_changed")
end

function F:MutateStore(mutator, delayMs, reason, durable)
    return P:MutateStore(INDEX_STORE, function() return mutator() end, {
        delayMs = tonumber(delayMs) or 350, reason = tostring(reason or "death_review_changed"), durable = durable == true,
    })
end

function F:EnsureStoreLoaded()
    -- 分片重建已获旧章认证后，必须立即经 Core 写入紧凑格式并完整回读，
    -- 再向 Feature 发布 ready；不把仅 RAM 恢复或 SaveData=true 当作磁盘恢复成功。
    local function Finish()
        local st=P:GetStore(INDEX_STORE)
        if st and st.dirty==true and tostring(st.lastHistoricalRecoveryProbe or ''):find('/shard_rebuild=rows=30/hits=1',1,true) then
            local ok,err=P:SaveStore(INDEX_STORE,{consumeDirty=true,verifyAfterSave=true,reason='death_index_truncation_recovery'})
            if ok~=true then self.StoreLoaded=false;return false,err end
        end
        self.StoreLoaded=true;return true
    end
    if type(P.IsStoreLoaded) == "function" and P:IsStoreLoaded(INDEX_STORE) == true then return Finish() end
    local store = P:GetStore(INDEX_STORE)
    if store == nil then return false, "死亡回顾索引存档不可用" end
    local status, _, err = P:LoadStore(INDEX_STORE)
    if status ~= true and status ~= "empty" then return false, err or tostring(status or "读取失败") end
    if status == "empty" then ApplyIndex(DefaultIndex()) end
    return Finish()
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

    -- 轻量索引是逻辑权威；先事务性从索引删除，陈旧物理分片不能复活记录。
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
    -- 只有空索引立即回读通过，才允许清理后面的记录分片；
    -- 否则旧索引可能仍引用这些分片，提前 ClearData 会把可诊断故障扩大成不可逆数据丢失。
    local ok, err = P:SaveStore(INDEX_STORE, { consumeDirty = true, verifyAfterSave = true, reason = "death_review_clear_history" })
    if ok ~= true then self.State.history = previous; return false, err end

    -- 权威索引已经清空，之后尽力清理物理分片；清理失败不能恢复可见历史。
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
