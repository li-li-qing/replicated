ReplicatedSuiteModuleSandbox:Enter('dps', {'ReplicatedDps', 'ReplicatedDpsConfig'})
------------------------------------------------------------------------
-- Replicated DPS - Core state, persistence, entities and statistics
-- Author: Replicated
------------------------------------------------------------------------

if ReplicatedDps == nil or ReplicatedDps.Boot == nil then
    return
end

local D = ReplicatedDps
local Boot = D.Boot
Boot:SetPhase("CORE_LOADING")

local Api = D.Api
local Migrations = D.Migrations
if type(Api) ~= "table" or type(Api.InitializeImports) ~= "function" then
    Boot:Fail("core:api_facade", "rdps_api.lua is missing or incomplete")
    return
end
if type(Migrations) ~= "table" or type(Migrations.SelectConfig) ~= "function" then
    Boot:Fail("core:migrations", "rdps_migrations.lua is missing or incomplete")
    return
end

local importsOk, importsError = Api:InitializeImports()
if not importsOk then
    Boot:Fail("core:imports", importsError)
    return
end

D.Const = {
    CONFIG_SCHEMA_VERSION = Migrations.CONFIG_SCHEMA_VERSION,
    STATS_SCHEMA_VERSION = 3,
    RULES_SCHEMA_VERSION = 1,
    MAX_PERSISTENT_RULES = 500,
    MAX_ROWS = 24,
    MAX_RANKING_ROWS = 150,
    MAX_RAW_EVENTS = 1200,
    MAX_PENDING_EVENTS = 3000,
    -- rc3：只保留最近一段可纠错事件。达到上限后轮换日志但继续累计正式 Stats；
    -- 这样 300 人世界 Boss 不会因每事件事实/分类旁路无限增长而在数分钟后卡死。
    MAX_CORRECTION_JOURNAL_EVENTS = 4000,
    MAX_DIAGNOSTICS = 300,
    MAX_BREAKDOWN_KEYS = 120,
    MAX_TRANSIENT_CACHE_AGE_MS = 120000,
    -- 稳定 ID→名称反查缓存。官方 GetUnitNameById 会在视野、团队和事件
    -- 归一化路径中重复触发；短 TTL 保证 ID 复用时不会长期污染，固定容量
    -- 则防止长期战斗中缓存无界增长。
    UNIT_NAME_CACHE_HIT_TTL_MS = 5000,
    UNIT_NAME_CACHE_MISS_TTL_MS = 1000,
    UNIT_NAME_CACHE_MAX = 2048,
    UNIT_NAME_CACHE_RETAIN = 1792,
    -- Large raid traffic can exceed twenty thousand events in roughly three
    -- minutes. The old one-frame journal rewrite at that threshold allocated
    -- tens of thousands of Lua tables at once and could freeze the client.
    -- Start memory compaction early and process only a bounded slice per update.
    SESSION_COMPACT_BATCH = 160,
    SESSION_COMPACT_STEP_MS = 50,
    BREAKDOWN_COMPACT_INTERVAL_MS = 5000,
    HIGH_LOAD_BREAKDOWN_ACTORS = 6,
    NORMAL_BREAKDOWN_ACTORS = 24,
    SAVE_BREAKDOWN_ACTORS = 96,
    SAVE_SNAPSHOT_FIELDS = 2500,
    BASELINE_COPY_FIELDS = 3000,
    BASELINE_DRAIN_EVENTS = 200,
    THIRD_PARTY_RETENTION_MS = 5000,
    NAME_BINDING_PAST_MS = 15000,
    NAME_BINDING_FUTURE_MS = 5000,
    -- Kind-only observations are safer than ID attribution: even when two
    -- same-name units are visible, they can still prove PLAYER/NPC if every
    -- official observation agrees on the type. Use a wider window so a
    -- low-frequency sight scan can classify nearby PVP events without binding
    -- historical damage to the wrong concrete unit ID.
    NAME_KIND_PAST_MS = 30000,
    NAME_KIND_FUTURE_MS = 15000,
    NAME_BINDING_RETENTION_MS = 180000,
    NAME_BINDING_SEGMENT_GAP_MS = 8000,
    MAX_NAME_BINDINGS_PER_NAME = 16,
    MAX_NAME_BINDING_SEGMENTS = 12,
    -- 待确认重试改为高频小批次，避免每 2 秒集中扫描 1600 行。
    PENDING_RETRY_INTERVAL_MS = 250,
    PENDING_RETRY_BATCH = 48,
    HIGH_LOAD_PENDING_BATCH = 8,
    PENDING_RETRY_SCAN_MULTIPLIER = 4,
    PENDING_TRIM_BATCH = 8,
    PENDING_TRIM_HYSTERESIS = 100,
    PENDING_RETRY_MAX_MS = 30000,
    STARTUP_PENDING_BATCH = 200,
    HIGH_LOAD_EVENT_RATE = 35,
    HIGH_LOAD_HOLD_MS = 8000,
    -- 低事件率的小队 Boss 仍属于持续战斗。后台维护不能只看“每秒事件数”，
    -- 否则 5 人战斗会使用大型空闲批次并在周期任务对齐时产生顿挫。
    ACTIVE_COMBAT_MAINTENANCE_MS = 1500,
    -- RC4：高事件率时 UI 只降低显示刷新频率，后台累计仍逐事件执行。
    -- 大型世界 Boss 下减少文本重排与 100 行控件更新对战斗主线程的争用。
    HIGH_LOAD_UI_MS = 2000,
    HIGH_LOAD_ROSTER_MS = 10000,
    ROSTER_SCAN_INITIAL_BATCH = 16,
    HIGH_LOAD_ROSTER_BATCH = 6,
    NORMAL_ROSTER_BATCH = 24,
    HIGH_LOAD_PENDING_MS = 1000,
    HIGH_LOAD_DECAY_ENTITIES = 40,
    NORMAL_DECAY_ENTITIES = 160,
    TEAM_SCHEME_REPROBE_MS = 30000,
    RECLASSIFY_IDLE_MS = 2500,
    RECLASSIFY_PENDING_PASS_MS = 5000,
    RECLASSIFY_PENDING_BATCH = 200,
    HIGH_LOAD_RECLASSIFY_PENDING_BATCH = 12,
    RECLASSIFY_MAX_DELAY_MS = 10000,
    SAVE_IDLE_MS = 5000,
    SAVE_FORCE_MS = 120000,
    TRANSIENT_CLEANUP_BATCH = 96,
    CIRCUIT_RETRY_MS = 30000,
    FRIENDLY_WINDOW_W = 360,
    ENEMY_WINDOW_W = 360,
    QUICK_WINDOW_H = 286,
    QUICK_WINDOW_MIN_H = 150,
    CONFIG_W = 560,
    CONFIG_H = 470,
    HEADER_H = 58,
    ROW_H = 20,
    FOOTER_H = 22,
    CONTENT_ID = 91731,
    ENTRY_THRESHOLD = 70,
    EXIT_THRESHOLD = 45,
    SUSPECT_THRESHOLD = 35,
    SCORE_CONFLICT_GAP = 20,
    EVIDENCE_COOLDOWN_MS = 2000,
    TEAM_GRACE_MS = 10000,
}

D.Util = D.Util or {}
local U = D.Util

function U.Clamp(value, minValue, maxValue)
    value = tonumber(value)
    if value == nil or value ~= value or value == math.huge or value == -math.huge then value = minValue end
    if value < minValue then return minValue end
    if value > maxValue then return maxValue end
    return value
end

function U.FiniteNumber(value, fallback)
    local number = tonumber(value)
    if number == nil or number ~= number or number == math.huge or number == -math.huge then
        return fallback
    end
    return number
end

function U.DeepCopy(value, seen)
    if type(value) ~= "table" then return value end
    seen = seen or {}
    if seen[value] ~= nil then return seen[value] end
    local result = {}
    seen[value] = result
    for key, item in pairs(value) do
        result[U.DeepCopy(key, seen)] = U.DeepCopy(item, seen)
    end
    return result
end

-- Incremental deep-copy job for large plain-data snapshots. Statistics are
-- acyclic string/number-keyed tables, but the seen map also keeps the helper
-- safe if a future schema shares a nested table. Work is counted per copied
-- field so Runtime can spread a large snapshot across multiple idle frames.
function U.BeginIncrementalDeepCopy(source)
    if type(source) ~= "table" then
        return { done = true, result = source, processed = 0 }
    end
    local result = {}
    return {
        done = false,
        result = result,
        processed = 0,
        seen = { [source] = result },
        stack = { { source = source, target = result, lastKey = nil } },
    }
end

function U.StepIncrementalDeepCopy(job, budget)
    if type(job) ~= "table" then return true, 0, "NO_JOB" end
    if job.done == true then return true, 0, nil end
    budget = math.max(1, math.floor(tonumber(budget) or 1000))
    local processed = 0
    while processed < budget and #job.stack > 0 do
        local frame = job.stack[#job.stack]
        local ok, key, value = pcall(next, frame.source, frame.lastKey)
        if not ok then
            job.done = true
            job.error = tostring(key)
            return true, processed, job.error
        end
        if key == nil then
            job.stack[#job.stack] = nil
        else
            frame.lastKey = key
            local copiedKey = type(key) == "table" and U.DeepCopy(key) or key
            if type(value) == "table" then
                local existing = job.seen[value]
                if existing ~= nil then
                    frame.target[copiedKey] = existing
                else
                    local child = {}
                    job.seen[value] = child
                    frame.target[copiedKey] = child
                    job.stack[#job.stack + 1] = { source = value, target = child, lastKey = nil }
                end
            else
                frame.target[copiedKey] = value
            end
            processed = processed + 1
            job.processed = (tonumber(job.processed) or 0) + 1
        end
    end
    if #job.stack == 0 then
        job.done = true
        job.seen = nil
        return true, processed, nil
    end
    return false, processed, nil
end

function U.MergeDefaults(target, defaults)
    if type(target) ~= "table" then target = {} end
    for key, value in pairs(defaults) do
        local current = target[key]
        if current == nil then
            target[key] = U.DeepCopy(value)
        elseif type(value) == "table" then
            if type(current) ~= "table" then
                -- A matching schema number is not enough to trust every nested
                -- field. Replace type-corrupted branches before callers index them.
                target[key] = U.DeepCopy(value)
            else
                U.MergeDefaults(current, value)
            end
        elseif type(current) == "table" then
            -- Scalar defaults must not retain a table injected by a partial or
            -- corrupted save. Domain-specific normalization runs afterwards.
            target[key] = value
        end
    end
    return target
end

function U.Trim(value)
    local text = tostring(value or "")
    return (text:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- v0.2.25（全局性能）：名称规范化缓存。
-- NormalizeName 在每条战斗事件热路径中被多次调用（source/target 名称、
-- 实体 key、按名索引、中文检测）。Memoize 输入→结果，避免每条事件重复
-- Trim + 2×gsub + lower。这是纯函数记忆化，结果与无缓存时完全一致。
-- 数据所有权：归 D.Caches；生命周期：随插件运行，LRU 风格有界淘汰。
-- 是否允许失效：允许；语义上任何时刻清空都只影响速度不影响正确性。
D.Caches = D.Caches or {}
D.Caches.normalizedName = type(D.Caches.normalizedName) == "table" and D.Caches.normalizedName or {}
D.Caches.normalizedNameOrder = type(D.Caches.normalizedNameOrder) == "table" and D.Caches.normalizedNameOrder or {}
D.Caches.normalizedNameOrderHead = math.max(1, math.floor(tonumber(D.Caches.normalizedNameOrderHead) or 1))
D.Caches.normalizedNameOrderTail = math.max(0, math.floor(tonumber(D.Caches.normalizedNameOrderTail) or #D.Caches.normalizedNameOrder))
local NORMALIZE_CACHE_LIMIT = 8192

function U.NormalizeName(value)
    local raw = tostring(value or "")
    local cached = D.Caches.normalizedName[raw]
    if cached ~= nil then
        if D.State ~= nil and D.State.config ~= nil and D.State.config.diagnosticsEnabled == true
            and D.Diagnostics ~= nil and D.Diagnostics.counters ~= nil then
            D.Diagnostics.counters.nameNormalizeCacheHits =
                (tonumber(D.Diagnostics.counters.nameNormalizeCacheHits) or 0) + 1
        end
        return cached
    end
    if D.State ~= nil and D.State.config ~= nil and D.State.config.diagnosticsEnabled == true
        and D.Diagnostics ~= nil and D.Diagnostics.counters ~= nil then
        D.Diagnostics.counters.nameNormalizeCacheMisses =
            (tonumber(D.Diagnostics.counters.nameNormalizeCacheMisses) or 0) + 1
    end
    local text = U.Trim(raw)
    text = text:gsub("%s+", " ")
    text = string.lower(text)
    -- 只缓存非空字符串键；缓存淘汰用顺序数组（超过上限时丢弃最旧一半）。
    if raw ~= "" then
        D.Caches.normalizedName[raw] = text
        local order = D.Caches.normalizedNameOrder
        local tail = (tonumber(D.Caches.normalizedNameOrderTail) or 0) + 1
        local head = math.max(1, math.floor(tonumber(D.Caches.normalizedNameOrderHead) or 1))
        order[tail] = raw
        D.Caches.normalizedNameOrderTail = tail
        -- 真正的游标队列：只删除超出上限的最老项，不再一次复制 4096 个引用。
        while tail - head + 1 > NORMALIZE_CACHE_LIMIT do
            local expired = order[head]
            order[head] = nil
            head = head + 1
            if expired ~= nil then D.Caches.normalizedName[expired] = nil end
        end
        D.Caches.normalizedNameOrderHead = head
    end
    return text
end

-- ArcheRage RU does not permit Chinese player names, while the optional
-- Chinese localization translates many NPC names. Decode UTF-8 explicitly
-- because the client may not expose Lua's utf8 library. This is a one-way type
-- heuristic only: Chinese => NPC; non-Chinese never implies PLAYER.
D.Caches = D.Caches or {}
D.Caches.chineseNameNpc = D.Caches.chineseNameNpc or {}
D.Caches.chineseNameNpcOrder = type(D.Caches.chineseNameNpcOrder) == "table"
    and D.Caches.chineseNameNpcOrder or {}
D.Caches.chineseNameNpcOrderHead = math.max(1, math.floor(tonumber(D.Caches.chineseNameNpcOrderHead) or 1))
D.Caches.chineseNameNpcOrderTail = math.max(0, math.floor(tonumber(D.Caches.chineseNameNpcOrderTail) or #D.Caches.chineseNameNpcOrder))

local function NextUtf8Codepoint(text, index)
    local first = string.byte(text, index)
    if first == nil then return nil, index + 1 end
    if first < 0x80 then return first, index + 1 end
    local length, minimum
    if first >= 0xC2 and first <= 0xDF then length, minimum = 2, 0x80
    elseif first >= 0xE0 and first <= 0xEF then length, minimum = 3, 0x800
    elseif first >= 0xF0 and first <= 0xF4 then length, minimum = 4, 0x10000
    else return nil, index + 1 end
    local code = first % (2 ^ (8 - length - 1))
    for offset = 1, length - 1 do
        local byte = string.byte(text, index + offset)
        if byte == nil or byte < 0x80 or byte > 0xBF then return nil, index + 1 end
        code = code * 64 + (byte - 0x80)
    end
    if code < minimum or code > 0x10FFFF or (code >= 0xD800 and code <= 0xDFFF) then
        return nil, index + 1
    end
    return code, index + length
end

function U.ContainsChineseCharacter(value)
    local text = tostring(value or "")
    local normalized = U.NormalizeName(text)
    if normalized == "" then return false end
    local cached = D.Caches.chineseNameNpc[normalized]
    if cached ~= nil then return cached == true end
    local index = 1
    local found = false
    while index <= #text do
        local code
        code, index = NextUtf8Codepoint(text, index)
        if code ~= nil and ((code >= 0x3400 and code <= 0x4DBF)
            or (code >= 0x4E00 and code <= 0x9FFF)
            or (code >= 0xF900 and code <= 0xFAFF)
            or (code >= 0x20000 and code <= 0x323AF)) then
            found = true
            break
        end
    end
    if D.Caches.chineseNameNpc[normalized] == nil then
        local order = D.Caches.chineseNameNpcOrder
        local tail = (tonumber(D.Caches.chineseNameNpcOrderTail) or 0) + 1
        local head = math.max(1, math.floor(tonumber(D.Caches.chineseNameNpcOrderHead) or 1))
        order[tail] = normalized
        D.Caches.chineseNameNpcOrderTail = tail
        while tail - head + 1 > 4096 do
            local expired = order[head]
            order[head] = nil
            head = head + 1
            if expired ~= nil then D.Caches.chineseNameNpc[expired] = nil end
        end
        D.Caches.chineseNameNpcOrderHead = head
    end
    D.Caches.chineseNameNpc[normalized] = found
    return found
end

function U.SafeName(value, fallback)
    local text = U.Trim(value)
    if text == "" then return fallback or "未知" end
    return text
end

D.Clock = D.Clock or { lastRaw = nil, lastMs = 0, offset = 0 }

function U.NowMs()
    -- GetCurrentTimeStamp is the official client clock used by the addon. Do
    -- not guess seconds versus milliseconds from magnitude: a legitimate
    -- millisecond uptime crosses 100,000,000 after about 27.8 hours. Magnitude
    -- conversion would then create a 1000x jump and expire every timing window.
    local clock = D.Clock
    if UI ~= nil and UI.GetCurrentTimeStamp ~= nil then
        -- 高频时钟读取直接传入 self，避免每次 NowMs 都分配匿名闭包。
        local ok, result = pcall(UI.GetCurrentTimeStamp, UI)
        local raw = ok and U.FiniteNumber(result, nil) or nil
        if raw ~= nil and raw >= 0 then
            raw = math.floor(raw + 0.5)
            local lastRaw = U.FiniteNumber(clock.lastRaw, nil)
            local lastMs = math.max(0, U.FiniteNumber(clock.lastMs, 0) or 0)
            local offset = math.max(0, U.FiniteNumber(clock.offset, 0) or 0)
            -- UI reloads or client transitions may reset the raw clock. Carry
            -- an offset forward so all event windows remain monotonic.
            if lastRaw ~= nil and raw < lastRaw then
                offset = math.max(offset, lastMs - raw)
            end
            local value = math.max(lastMs, raw + offset)
            clock.lastRaw = raw
            clock.lastMs = value
            clock.offset = offset
            return value
        end
    end
    -- A failed clock query must not switch to os.clock (CPU time). Freeze at
    -- the last official timestamp and resume naturally when the API recovers.
    return math.max(0, U.FiniteNumber(clock.lastMs, 0) or 0)
end

function U.TimestampOrNow(value)
    local number = U.FiniteNumber(value, nil)
    if number ~= nil then return number end
    return U.NowMs()
end

function U.TrimArrayFront(list, maxCount, trimBatch)
    if type(list) ~= "table" then return {} end
    maxCount = math.max(1, tonumber(maxCount) or 1)
    if #list <= maxCount then return list end
    local keep = math.max(1, maxCount - math.max(1, tonumber(trimBatch) or math.floor(maxCount * 0.10)))
    local first = math.max(1, #list - keep + 1)
    local compacted = {}
    for index = first, #list do compacted[#compacted + 1] = list[index] end
    return compacted
end

function U.OrderedArrayValues(source)
    if type(source) ~= "table" then return {} end
    local indexes = {}
    for index in pairs(source) do
        if type(index) == "number" and index >= 1 and index == math.floor(index) then
            indexes[#indexes + 1] = index
        end
    end
    table.sort(indexes)
    local values = {}
    for _, index in ipairs(indexes) do values[#values + 1] = source[index] end
    return values
end

local function TryUiNumber(host, methodName)
    if host == nil or host[methodName] == nil then return nil end
    local ok, result = pcall(function() return host[methodName](host) end)
    if not ok then return nil end
    return U.FiniteNumber(result, nil)
end

function U.GetUiMetrics()
    local uiScale = TryUiNumber(UIParent, "GetUIScale") or TryUiNumber(UI, "GetUIScale") or 1
    if uiScale <= 0 then uiScale = 1 end

    -- UIParent extent is the logical viewport Authority.  On some RU builds
    -- UI:GetScreenWidth/Height can briefly retain a previous larger resolution,
    -- so using it as the primary clamp space can leave launchers off-screen.
    local logicalWidth, logicalHeight = nil, nil
    if UIParent ~= nil and UIParent.GetExtent ~= nil then
        local ok, width, height = pcall(function() return UIParent:GetExtent() end)
        if ok then logicalWidth, logicalHeight = U.FiniteNumber(width, nil), U.FiniteNumber(height, nil) end
    end
    if logicalWidth == nil or logicalWidth <= 0 then logicalWidth = TryUiNumber(UIParent, "GetWidth") end
    if logicalHeight == nil or logicalHeight <= 0 then logicalHeight = TryUiNumber(UIParent, "GetHeight") end

    local screenWidth, screenHeight
    if logicalWidth ~= nil and logicalWidth > 0 then
        screenWidth = logicalWidth * uiScale
    else
        screenWidth = TryUiNumber(UI, "GetScreenWidth") or TryUiNumber(UIParent, "GetScreenWidth") or 1920
        logicalWidth = screenWidth / uiScale
    end
    if logicalHeight ~= nil and logicalHeight > 0 then
        screenHeight = logicalHeight * uiScale
    else
        screenHeight = TryUiNumber(UI, "GetScreenHeight") or TryUiNumber(UIParent, "GetScreenHeight") or 1080
        logicalHeight = screenHeight / uiScale
    end

    return screenWidth, screenHeight, uiScale, logicalWidth, logicalHeight
end

function U.GetLogicalPosition(widget)
    local _, _, uiScale = U.GetUiMetrics()
    local x, y
    -- Native StartMoving() may temporarily replace a TOPLEFT/UIParent anchor
    -- with an internal movement anchor. GetOffset() then becomes parent-local
    -- on some RU builds and is not a stable screen position. EffectiveOffset
    -- remains the viewport-space Authority throughout the drag transaction.
    if widget ~= nil and widget.GetEffectiveOffset ~= nil then
        local ok, effectiveX, effectiveY = pcall(function() return widget:GetEffectiveOffset() end)
        if ok then x, y = effectiveX, effectiveY end
    end
    if x ~= nil and y ~= nil then
        return (tonumber(x) or 0) / uiScale, (tonumber(y) or 0) / uiScale
    end
    if widget ~= nil and widget.GetOffset ~= nil then
        local ok, localX, localY = pcall(function() return widget:GetOffset() end)
        if ok then return tonumber(localX) or 0, tonumber(localY) or 0 end
    end
    return 0, 0
end

local function RectVisualScale(rect, widget)
    local scale = widget ~= nil and tonumber(widget.repdpsScale) or nil
    if scale == nil and type(rect) == "table" then scale = tonumber(rect.visualScale) end
    if scale == nil or scale <= 0 then scale = 1 end
    return U.Clamp(scale, 0.10, 4.00)
end

function U.GetLogicalRect(widget)
    local _, _, uiScale = U.GetUiMetrics()
    local x, y = U.GetLogicalPosition(widget)
    -- Ranking windows keep an unscaled geometry Authority. Their native
    -- presentation scale is handled separately as a viewport footprint so a
    -- movement save can never feed the rendered size back into SetExtent().
    if widget ~= nil and widget.repdpsScale ~= nil then
        return x, y, tonumber(widget:GetWidth()) or 1, tonumber(widget:GetHeight()) or 1
    end
    local width, height
    if widget ~= nil and widget.GetEffectiveExtent ~= nil then
        local ok, effectiveWidth, effectiveHeight = pcall(function() return widget:GetEffectiveExtent() end)
        if ok then width, height = effectiveWidth, effectiveHeight end
    end
    if width == nil or height == nil then
        width = (tonumber(widget:GetWidth()) or 1) * uiScale
        height = (tonumber(widget:GetHeight()) or 1) * uiScale
    end
    return x, y, (tonumber(width) or 1) / uiScale, (tonumber(height) or 1) / uiScale
end

function U.StoreRect(target, widget)
    local x, y, width, height = U.GetLogicalRect(widget)
    local _, _, uiScale, logicalWidth, logicalHeight = U.GetUiMetrics()
    width = U.Clamp(width, 1, logicalWidth)
    height = U.Clamp(height, 1, logicalHeight)
    local visualScale = RectVisualScale(target, widget)
    local footprintWidth = math.min(logicalWidth, width * visualScale)
    local footprintHeight = math.min(logicalHeight, height * visualScale)
    x = U.Clamp(x, 0, math.max(0, logicalWidth - footprintWidth))
    y = U.Clamp(y, 0, math.max(0, logicalHeight - footprintHeight))
    target.coordinateSpace = "logical"
    target.savedUiScale = uiScale
    target.visualScale = visualScale
    target.userMoved = true
    target.width = width
    target.height = height
    if x + footprintWidth / 2 <= logicalWidth / 2 then
        target.anchorH = "LEFT"
        target.offsetX = x
    else
        target.anchorH = "RIGHT"
        target.offsetX = logicalWidth - x - footprintWidth
    end
    if y + footprintHeight / 2 <= logicalHeight / 2 then
        target.anchorV = "TOP"
        target.offsetY = y
    else
        target.anchorV = "BOTTOM"
        target.offsetY = logicalHeight - y - footprintHeight
    end
    target.offsetX = math.max(0, tonumber(target.offsetX) or 0)
    target.offsetY = math.max(0, tonumber(target.offsetY) or 0)
end

function U.SetRectFromLogical(target, x, y, width, height)
    local _, _, uiScale, logicalWidth, logicalHeight = U.GetUiMetrics()
    width = U.Clamp(width or 1, 1, logicalWidth)
    height = U.Clamp(height or 1, 1, logicalHeight)
    local visualScale = RectVisualScale(target, nil)
    local footprintWidth = math.min(logicalWidth, width * visualScale)
    local footprintHeight = math.min(logicalHeight, height * visualScale)
    x = U.Clamp(x or 0, 0, math.max(0, logicalWidth - footprintWidth))
    y = U.Clamp(y or 0, 0, math.max(0, logicalHeight - footprintHeight))
    target.coordinateSpace = "logical"
    target.savedUiScale = uiScale
    target.visualScale = visualScale
    target.width = width
    target.height = height
    if x + footprintWidth / 2 <= logicalWidth / 2 then
        target.anchorH = "LEFT"
        target.offsetX = x
    else
        target.anchorH = "RIGHT"
        target.offsetX = logicalWidth - x - footprintWidth
    end
    if y + footprintHeight / 2 <= logicalHeight / 2 then
        target.anchorV = "TOP"
        target.offsetY = y
    else
        target.anchorV = "BOTTOM"
        target.offsetY = logicalHeight - y - footprintHeight
    end
    target.offsetX = math.max(0, tonumber(target.offsetX) or 0)
    target.offsetY = math.max(0, tonumber(target.offsetY) or 0)
end

function U.ResolveRect(rect, defaultWidth, defaultHeight)
    local _, _, _, logicalWidth, logicalHeight = U.GetUiMetrics()
    local width = U.Clamp(tonumber(rect.width) or defaultWidth, 1, logicalWidth)
    local height = U.Clamp(tonumber(rect.height) or defaultHeight, 1, logicalHeight)
    local visualScale = RectVisualScale(rect, nil)
    local footprintWidth = math.min(logicalWidth, width * visualScale)
    local footprintHeight = math.min(logicalHeight, height * visualScale)
    local x
    local y
    if rect.anchorH == "RIGHT" then
        x = logicalWidth - (tonumber(rect.offsetX) or 0) - footprintWidth
    else
        x = tonumber(rect.offsetX) or 0
    end
    if rect.anchorV == "BOTTOM" then
        y = logicalHeight - (tonumber(rect.offsetY) or 0) - footprintHeight
    else
        y = tonumber(rect.offsetY) or 0
    end
    x = U.Clamp(x, 0, math.max(0, logicalWidth - footprintWidth))
    y = U.Clamp(y, 0, math.max(0, logicalHeight - footprintHeight))
    return x, y, width, height
end

function U.ApplyRect(widget, rect, defaultWidth, defaultHeight)
    if widget == nil then return nil end
    rect = type(rect) == "table" and rect or {}
    local x, y, width, height = U.ResolveRect(rect, defaultWidth, defaultHeight)
    if widget.RemoveAllAnchors ~= nil then widget:RemoveAllAnchors() end
    widget:AddAnchor("TOPLEFT", "UIParent", x, y)
    widget:SetExtent(width, height)
    return x, y, width, height
end

function U.FormatNumber(value)
    local n = tonumber(value) or 0
    local absN = math.abs(n)
    if absN >= 1000000000 then return string.format("%.2fB", n / 1000000000) end
    if absN >= 1000000 then return string.format("%.2fM", n / 1000000) end
    if absN >= 1000 then return string.format("%.1fK", n / 1000) end
    return string.format("%d", math.floor(n + 0.5))
end

function U.HashString(value)
    local text = tostring(value or "")
    local hash = 5381
    for i = 1, #text do
        hash = (hash * 33 + string.byte(text, i)) % 2147483647
    end
    return tostring(hash)
end

function U.TableCount(value)
    local count = 0
    if type(value) == "table" then
        for _ in pairs(value) do count = count + 1 end
    end
    return count
end

local Config = type(ReplicatedDpsConfig) == "table" and ReplicatedDpsConfig or {}
D.Defaults = type(Config.Defaults) == "table" and Config.Defaults or { config = {}, rules = {}, ui = {} }

D.Persistence = D.Persistence or {}
local P = D.Persistence
P.lastBackupAt = P.lastBackupAt or {}

local function GetIdentity()
    local player = "unknown_player"
    local world = "unknown_world"
    local value = Api:GetUnitNameWithWorld("player")
    if U.Trim(value) ~= "" then player = U.Trim(value) end
    if player == "unknown_player" then
        value = Api:GetUnitName("player")
        if U.Trim(value) ~= "" then player = U.Trim(value) end
    end
    value = Api:GetWorldNameOptional()
    if U.Trim(value) ~= "" then world = U.Trim(value) end
    return player, world
end

D.Identity = D.Identity or {}
D.Identity.playerNameWithWorld, D.Identity.worldName = GetIdentity()
local localPlayerName = Api:GetUnitName("player")
D.Identity.playerName = U.Trim(localPlayerName) ~= ""
    and U.SafeName(localPlayerName, D.Identity.playerNameWithWorld)
    or D.Identity.playerNameWithWorld
D.Identity.keySuffix = U.HashString(D.Identity.worldName .. "|" .. D.Identity.playerNameWithWorld)

function P.Key(name, slot)
    local prefix = tostring((type(ReplicatedDpsConfig) == "table" and ReplicatedDpsConfig.PersistencePrefix) or "repdps")
    return prefix .. "_" .. tostring(name) .. "_" .. tostring(slot or "primary") .. "_" .. D.Identity.keySuffix
end

function P.LoadRawStatus(key)
    local ok, result = Api:LoadData(key)
    if ok then return result, nil end
    return nil, tostring(result or "LoadData failed")
end

function P.LoadRaw(key)
    local result = P.LoadRawStatus(key)
    return result
end

local function PersistenceError(category, detail)
    if D.Diagnostics ~= nil and D.Diagnostics.AddError ~= nil then
        D.Diagnostics:AddError(category, tostring(detail))
    end
end

function P.ClearRaw(key)
    local ok, result = Api:ClearData(key)
    if not ok then
        PersistenceError("clear", result)
        return false, tostring(result)
    end
    if result == false then
        -- Some API builds report false for an already-empty key. Verify the
        -- observable state before treating it as a failure; all RepDPS slots
        -- contain tables, so nil/false means there is no retained payload.
        local verifyOk, remaining = Api:LoadData(key)
        if not verifyOk or (remaining ~= nil and remaining ~= false) then
            local detail = verifyOk and "ClearData returned false and data remains" or remaining
            PersistenceError("clear", detail)
            return false, tostring(detail)
        end
    end
    return true
end

function P.SaveRaw(key, value)
    -- Public ArcheRage addon examples replace saved tables by clearing the key
    -- first. Transaction safety comes from separate pending/backup slots.
    local cleared, clearError = P.ClearRaw(key)
    if not cleared then return false, clearError end

    local ok, result = Api:SaveData(key, value)
    if not ok or result == false then
        local detail = ok and "SaveData returned false" or result
        PersistenceError("save", detail)
        return false, tostring(detail)
    end
    return true
end

P.writeFences = type(P.writeFences) == "table" and P.writeFences or {}
P.writeFenceWarned = type(P.writeFenceWarned) == "table" and P.writeFenceWarned or {}

function P:SetWriteFence(name, reason)
    name = tostring(name or "")
    if name == "" then return false end
    if self.writeFences[name] == nil then
        self.writeFences[name] = tostring(reason or "write_fenced")
    end
    return true
end

function P:GetWriteFence(name)
    return self.writeFences[tostring(name or "")]
end

function P:IsWriteFenced(name)
    return self:GetWriteFence(name) ~= nil
end

function P:WarnWriteFence(name)
    name = tostring(name or "")
    if self.writeFenceWarned[name] == true then return end
    self.writeFenceWarned[name] = true
    local reason = tostring(self:GetWriteFence(name) or "write_fenced")
    if D.Diagnostics ~= nil and type(D.Diagnostics.AddWarning) == "function" then
        D.Diagnostics:AddWarning("persistence_write_fence", name .. ": " .. reason)
    end
end

function P.ClearSlots(name)
    if P:IsWriteFenced(name) then
        P:WarnWriteFence(name)
        return false
    end
    local ok = true
    for _, slot in ipairs({ "primary", "backup", "pending" }) do
        ok = P.ClearRaw(P.Key(name, slot)) and ok
    end
    return ok
end

function P.SaveTransactional(name, value, backupIntervalMs)
    if P:IsWriteFenced(name) then
        P:WarnWriteFence(name)
        return false, "WRITE_FENCED"
    end
    local primaryKey = P.Key(name, "primary")
    local backupKey = P.Key(name, "backup")
    local pendingKey = P.Key(name, "pending")

    -- Loading a large persisted statistics table is itself synchronous. The old
    -- path loaded the full previous payload on every save even when the backup
    -- interval had not elapsed, then discarded it. Decide whether a backup is
    -- due first and only materialize the previous payload when it will be used.
    local shouldBackup = true
    if tonumber(backupIntervalMs) ~= nil then
        local now = U.NowMs()
        local lastBackupAt = tonumber(P.lastBackupAt[name])
        shouldBackup = lastBackupAt == nil or now - lastBackupAt >= tonumber(backupIntervalMs)
    end
    local previous = shouldBackup and P.LoadRaw(primaryKey) or nil
    if not shouldBackup and D.Diagnostics ~= nil and D.Diagnostics.counters ~= nil then
        D.Diagnostics.counters.skippedPersistenceReloads =
            (tonumber(D.Diagnostics.counters.skippedPersistenceReloads) or 0) + 1
    end
    shouldBackup = shouldBackup and previous ~= nil

    local okPending = P.SaveRaw(pendingKey, value)
    if not okPending then return false end
    if shouldBackup then
        local backupOk = P.SaveRaw(backupKey, previous)
        if backupOk then P.lastBackupAt[name] = U.NowMs() end
    end
    local okPrimary = P.SaveRaw(primaryKey, value)
    if okPrimary then
        P.ClearRaw(pendingKey)
        return true
    end
    return false
end

-- Large statistics snapshots use a rotating two-slot transaction instead of
-- writing the same payload to pending + primary on every checkpoint.  The slot
-- not being written remains a complete previous snapshot, so a ClearData or
-- SaveData failure cannot destroy the last known-good statistics.  Legacy raw
-- primary/pending/backup payloads remain readable during migration.
P.STATS_ENVELOPE_VERSION = 1
P.statsSequence = math.max(0, math.floor(tonumber(P.statsSequence) or 0))
P.statsActiveSlot = P.statsActiveSlot == "primary" and "primary"
    or P.statsActiveSlot == "backup" and "backup" or nil
P.statsShardObserver = type(P.statsShardObserver) == "table" and P.statsShardObserver or nil

-- prep15 boundary: the fixed-shard persistence shadow may observe only an
-- already-successful formal rotating save. It cannot veto the Authority save,
-- replace recovery slots, or load a shard generation into D.State.stats.
function P:SetStatsShardObserver(observer)
    if observer ~= nil and (type(observer) ~= "table"
        or type(observer.OnFormalStatsSaved) ~= "function") then
        return false, "INVALID_STATS_SHARD_OBSERVER"
    end
    self.statsShardObserver = observer
    return true
end

function P:NotifyStatsShardObserver(payload, context)
    local observer = self.statsShardObserver
    if type(observer) ~= "table" or type(observer.OnFormalStatsSaved) ~= "function" then
        return false, "NO_STATS_SHARD_OBSERVER"
    end
    local ok, result, reason = pcall(observer.OnFormalStatsSaved, observer, payload, context)
    if not ok then
        if D.Diagnostics ~= nil and type(D.Diagnostics.AddWarning) == "function" then
            D.Diagnostics:AddWarning("persistence_shards", tostring(result))
        end
        return false, tostring(result)
    end
    return result == true, reason
end

function P.WrapStatsPayload(value, sequence)
    return {
        repdpsStatsEnvelope = P.STATS_ENVELOPE_VERSION,
        sequence = math.max(0, math.floor(tonumber(sequence) or 0)),
        savedAt = U.NowMs(),
        payload = value,
    }
end

function P.UnwrapStatsPayload(raw)
    if type(raw) == "table"
        and tonumber(raw.repdpsStatsEnvelope) == P.STATS_ENVELOPE_VERSION
        and type(raw.payload) == "table" then
        return raw.payload,
            math.max(0, math.floor(tonumber(raw.sequence) or 0)),
            true
    end
    return raw, 0, false
end

function P.SaveRotatingStats(value)
    local active = P.statsActiveSlot
    local target = active == "primary" and "backup" or "primary"
    local sequence = math.max(0, math.floor(tonumber(P.statsSequence) or 0)) + 1
    local envelope = P.WrapStatsPayload(value, sequence)
    local ok = P.SaveRaw(P.Key("stats", target), envelope)
    if not ok then return false end

    P.statsSequence = sequence
    P.statsActiveSlot = target
    -- A tiny head record avoids loading both full rotating snapshots at normal
    -- startup. It is only an acceleration hint: if it is missing or damaged,
    -- loading falls back to validating both complete slots by sequence.
    P.SaveRaw(P.Key("stats_head", "primary"), {
        schemaVersion = 1,
        slot = target,
        sequence = sequence,
    })
    -- A pending slot may be left by v0.2.23 or an older interrupted two-write
    -- transaction.  Once one rotating slot is safely committed it is obsolete.
    P.ClearRaw(P.Key("stats", "pending"))
    if D.State ~= nil and D.State.config ~= nil and D.State.config.diagnosticsEnabled == true
        and D.Diagnostics ~= nil and D.Diagnostics.counters ~= nil then
        D.Diagnostics.counters.rotatingStatsSaves =
            (tonumber(D.Diagnostics.counters.rotatingStatsSaves) or 0) + 1
        D.Diagnostics.counters.avoidedStatsPayloadWrites =
            (tonumber(D.Diagnostics.counters.avoidedStatsPayloadWrites) or 0) + 1
    end
    return true
end

function P.LoadValidated(name, defaults, schemaVersion)
    local candidates = {}
    local futureVersion = nil
    for _, slot in ipairs({ "primary", "pending", "backup" }) do
        local value, loadErr = P.LoadRawStatus(P.Key(name, slot))
        candidates[slot] = value
        if loadErr ~= nil then
            P:SetWriteFence(name, "load_failed:" .. tostring(slot))
        end
        local version = type(value) == "table" and tonumber(value.schemaVersion) or nil
        if version ~= nil and version > schemaVersion then
            futureVersion = math.max(tonumber(futureVersion) or version, version)
        end
    end
    if futureVersion ~= nil then
        P:SetWriteFence(name, "future_schema:" .. tostring(futureVersion) .. ">" .. tostring(schemaVersion))
        P:WarnWriteFence(name)
    end

    local primary = candidates.primary
    if type(primary) == "table" and tonumber(primary.schemaVersion) == schemaVersion then
        return U.MergeDefaults(primary, defaults), "primary"
    end
    local pending = candidates.pending
    if type(pending) == "table" and tonumber(pending.schemaVersion) == schemaVersion then
        if D.Diagnostics ~= nil and D.Diagnostics.AddWarning ~= nil then D.Diagnostics:AddWarning("load", name .. " primary invalid; pending transaction restored") end
        return U.MergeDefaults(pending, defaults), "pending"
    end
    local backup = candidates.backup
    if type(backup) == "table" and tonumber(backup.schemaVersion) == schemaVersion then
        if D.Diagnostics ~= nil and D.Diagnostics.AddWarning ~= nil then D.Diagnostics:AddWarning("load", name .. " primary invalid; backup restored") end
        return U.MergeDefaults(backup, defaults), "backup"
    end
    return U.DeepCopy(defaults), "default"
end

D.Diagnostics = D.Diagnostics or {
    entries = {},
    errors = {},
    warnings = {},
    counters = {
        rawEvents = 0,
        globalCombatRows = 0, -- rows received via the global UIParent COMBAT_MSG route (team events)
        parsedEvents = 0,
        parseFailures = 0,
        pendingEvents = 0,
        thirdPartyEvents = 0,
        uiErrors = 0,
        saveErrors = 0,
        deathNotices = 0,
        deathMatched = 0,
        deathUnmatched = 0,
        deathAmbiguous = 0,
        deathDeferred = 0,
        deathRecoveredForward = 0,
        sessionCompactions = 0,
        dataFirstAdmissions = 0,
        correctionJournalRollovers = 0,
        correctionJournalEventsReleased = 0,
        fullReplaysBlockedByCoverage = 0,
        environmentalEvents = 0,
        environmentalDamage = 0,
        relationConflicts = 0,
        strongFriendlyRelations = 0,
        strongOpponentRelations = 0,
        compactedReplayEvents = 0,
        deferredLiveReclassifies = 0,
        deferredSavesForCompaction = 0,
        deferredActiveCombatSaves = 0,
        skippedPersistenceReloads = 0,
        rotatingStatsSaves = 0,
        avoidedStatsPayloadWrites = 0,
        incrementalStatsSnapshots = 0,
        cancelledStatsSnapshots = 0,
        statsSnapshotFields = 0,
        statsHeadHits = 0,
        statsHeadFallbacks = 0,
        fastStatsLoads = 0,
        repairedStatsLoads = 0,
        baselineCopyFields = 0,
        baselineQueuedEvents = 0,
        baselineDrainedEvents = 0,
        baselineCopyRestarts = 0,
        decayPasses = 0,
        -- v0.2.25（问题 1/2/3/7/10 诊断）：性能计数器
        identityIndexEvents = 0,
        identityUpgradeEventsRewritten = 0,
        denseEventStoreLoads = 0,
        rankingRebuilds = 0,
        replayBatches = 0,
        replayBatchEvents = 0,
        replayCommits = 0,
        replayCancels = 0,
        relationBinaryLookups = 0,
        nameNormalizeCacheHits = 0,
        nameNormalizeCacheMisses = 0,
        saveFinalizeActors = 0,
        saveFinalizeFrames = 0,
        -- v0.3.0-prep6：不可变事件事实 / 分类影子诊断。正常模式不分配。
        eventShadowFacts = 0,
        eventShadowAppends = 0,
        eventShadowClassifications = 0,
        eventShadowTransitions = 0,
        eventShadowMismatches = 0,
        eventShadowInvariantFailures = 0,
        eventShadowFailures = 0,
        eventShadowReplayBegins = 0,
        eventShadowReplayCommits = 0,
        eventShadowReplayRollbacks = 0,
        eventShadowBackfills = 0,
        eventShadowAuditChecks = 0,
        -- v0.3.0-prep10：局部重放影响闭包与完整重放覆盖审计。
        localReplayPlans = 0,
        localReplayFallbacks = 0,
        localReplayEquivalentPlans = 0,
        localReplayUnsafePlans = 0,
        localReplayChangedEvents = 0,
        localReplayChangedOutside = 0,
        localReplayRollbacks = 0,
        localReplayFailures = 0,
        -- v0.3.0-prep11：局部 Stats 撤销/重投影影子事务。
        localStatsShadowTransactions = 0,
        localStatsShadowEquivalent = 0,
        localStatsShadowMismatches = 0,
        localStatsShadowFallbacks = 0,
        localStatsShadowFailures = 0,
        -- v0.3.0-prep12：局部可提交工作副本与正式门禁（提交仍关闭）。
        localStatsCandidateTransactions = 0,
        localStatsCandidateVerified = 0,
        localStatsCandidateCommitDisabled = 0,
        localStatsCandidateFallbacks = 0,
        localStatsCandidateFailures = 0,
    },
    lastCombatSample = nil,
    lastUnitInfoSample = nil,
    status = "CORE_LOADING",
}

function D.Diagnostics:Push(level, category, message)
    local entry = {
        time = U.NowMs(),
        level = tostring(level or "INFO"),
        category = tostring(category or "general"),
        message = tostring(message or ""),
    }
    self.entries[#self.entries + 1] = entry
    if #self.entries > D.Const.MAX_DIAGNOSTICS then
        self.entries = U.TrimArrayFront(self.entries, D.Const.MAX_DIAGNOSTICS, 30)
    end
end

function D.Diagnostics:AddError(category, message)
    self.errors[#self.errors + 1] = { time = U.NowMs(), category = category, message = tostring(message) }
    if #self.errors > 30 then self.errors = U.TrimArrayFront(self.errors, 30, 5) end
    if category == "save" then self.counters.saveErrors = self.counters.saveErrors + 1 end
    self:Push("ERROR", category, message)
end

function D.Diagnostics:AddWarning(category, message)
    self.warnings[#self.warnings + 1] = { time = U.NowMs(), category = category, message = tostring(message) }
    if #self.warnings > 30 then self.warnings = U.TrimArrayFront(self.warnings, 30, 5) end
    self:Push("WARN", category, message)
end

function D.Diagnostics:AddInfo(category, message)
    self:Push("INFO", category, message)
end

D.State = D.State or {}
local configCandidates = {}
if type(D.State.config) == "table" then
    configCandidates[#configCandidates + 1] = { source = "memory", value = D.State.config }
end
for _, slot in ipairs({ "primary", "pending", "backup" }) do
    local payload, loadErr = P.LoadRawStatus(P.Key("config", slot))
    if loadErr ~= nil then
        P:SetWriteFence("config", "load_failed:" .. tostring(slot))
    end
    if type(payload) == "table" then
        local version = tonumber(payload.schemaVersion)
        if version ~= nil and version > D.Const.CONFIG_SCHEMA_VERSION then
            P:SetWriteFence("config", "future_schema:" .. tostring(version) .. ">" .. tostring(D.Const.CONFIG_SCHEMA_VERSION))
        end
        configCandidates[#configCandidates + 1] = { source = slot, value = payload }
    end
end
if type(D.State.config) == "table" then
    local memoryVersion = tonumber(D.State.config.schemaVersion)
    if memoryVersion ~= nil and memoryVersion > D.Const.CONFIG_SCHEMA_VERSION then
        P:SetWriteFence("config", "future_memory_schema:" .. tostring(memoryVersion) .. ">" .. tostring(D.Const.CONFIG_SCHEMA_VERSION))
    end
end
if P:IsWriteFenced("config") then P:WarnWriteFence("config") end
local configMigrationReport
D.State.config, configMigrationReport = Migrations:SelectConfig(configCandidates, D.Defaults.config)
if type(D.State.ui) ~= "table" or tonumber(D.State.ui.schemaVersion) ~= 1 then
    D.State.ui = P.LoadValidated("ui", D.Defaults.ui, 1)
end
if type(D.State.rules) ~= "table" or tonumber(D.State.rules.schemaVersion) ~= D.Const.RULES_SCHEMA_VERSION then
    D.State.rules = P.LoadValidated("rules", D.Defaults.rules, D.Const.RULES_SCHEMA_VERSION)
end
D.State.config = U.MergeDefaults(D.State.config, D.Defaults.config)
D.State.rules = U.MergeDefaults(D.State.rules, D.Defaults.rules)
local configSanitized = false
local function NormalizeBoolean(key, fallback)
    local value = D.State.config[key]
    local normalized
    if value == true or value == false then normalized = value else normalized = fallback == true end
    if value ~= normalized then D.State.config[key] = normalized configSanitized = true end
end
for key, fallback in pairs({
    enabled = false, showFriendly = true, showEnemy = true, alwaysShowSelf = true,
    abbreviateNumbers = true, showPercent = true, showSuspect = true,
    showPendingSummary = true, inferChineseNamesAsNpc = true,
    useSocialFriendlyPriors = true, showThirdPartySummary = true, showClosure = true,
    friendlyLocked = false, enemyLocked = false, compactMode = false,
    diagnosticsEnabled = false,
}) do NormalizeBoolean(key, fallback) end
if D.State.config.scopeMode ~= "team" and D.State.config.scopeMode ~= "range" then
    D.State.config.scopeMode = "team" configSanitized = true
end
if D.State.config.currentMode ~= "PVP" and D.State.config.currentMode ~= "PVE" then
    D.State.config.currentMode = "PVP" configSanitized = true
end
if D.State.config.currentPage ~= "DAMAGE" and D.State.config.currentPage ~= "TAKEN"
    and D.State.config.currentPage ~= "HEAL" then
    -- rc3：最后一击页已移除；旧配置自动回到伤害页。
    D.State.config.currentPage = "DAMAGE" configSanitized = true
end
local function NormalizeNumber(key, fallback, minimum, maximum)
    local normalized = U.Clamp(tonumber(D.State.config[key]) or fallback, minimum, maximum)
    if D.State.config[key] ~= normalized then D.State.config[key] = normalized configSanitized = true end
end
NormalizeNumber("personalWindowMs", 5000, 3000, 10000)
NormalizeNumber("sideWindowMs", 8000, 5000, 15000)
NormalizeNumber("uiRefreshMs", 500, 250, 2000)
NormalizeNumber("rosterScanMs", 1000, 500, 5000)
NormalizeNumber("persistenceMs", 30000, 5000, 120000)
NormalizeNumber("rawEventLimit", 1200, 100, D.Const.MAX_RAW_EVENTS)
NormalizeNumber("displayRows", 100, 10, D.Const.MAX_RANKING_ROWS)
NormalizeNumber("rankingOpacity", 1.00, 0.50, 1.00)
NormalizeNumber("launcherOpacity", 1.00, 0.20, 1.00)
NormalizeNumber("rankingScale", 1.00, 0.60, 1.20)
D.State.config.schemaVersion = D.Const.CONFIG_SCHEMA_VERSION

Api:FlushDiagnostics(D.Diagnostics)
D.Diagnostics:AddInfo("migration", Migrations:DescribeConfigReport(configMigrationReport))
D.State.ui = U.MergeDefaults(D.State.ui, D.Defaults.ui)
local launcherLayoutMigrated = false
-- ui31: cluster the four independent Replicated launchers around the Suite R
-- entry. Only the historical untouched DPS anchor is moved; user-dragged
-- coordinates are preserved. The launcher itself is not resizable, so its
-- visual size is normalized for everyone to keep all four entries identical.
do
    local launcherRect = D.State.ui.launcher
    if type(launcherRect) == "table" then
        local x = tonumber(launcherRect.offsetX)
        local y = tonumber(launcherRect.offsetY)
        if x ~= nil and y ~= nil and math.abs(x - 12) < 0.01 and math.abs(y - 118) < 0.01 then
            launcherRect.offsetX = 300
            launcherRect.offsetY = 100
            launcherLayoutMigrated = true
        end
        if tonumber(launcherRect.width) ~= 88 or tonumber(launcherRect.height) ~= 26 then
            launcherRect.width = 88
            launcherRect.height = 26
            launcherLayoutMigrated = true
        end
    end
end
if tonumber(configMigrationReport and configMigrationReport.fromVersion) ~= nil
    and tonumber(configMigrationReport.fromVersion) < 3 then
    -- ui12 intentionally normalizes the three primary Replicated launchers into
    -- one 104x26 stack.  Older launcher positions can also contain coordinates
    -- saved before the viewport/drag fixes, so reset this primary entry once.
    D.State.ui.launcher = U.DeepCopy(D.Defaults.ui.launcher)
    launcherLayoutMigrated = true
end
D.State.dirty = {
    stats = true,
    view = true,
    layout = true,
    reclassify = configMigrationReport.requiresReclassify == true,
    configSave = (configMigrationReport.needsSave == true or configSanitized) and not P:IsWriteFenced("config"),
    uiSave = launcherLayoutMigrated and not P:IsWriteFenced("ui"),
    rulesSave = false,
    statsSave = false,
    -- v0.2.25（清空修复）：清空快照延迟保存标记。由 OnUpdate 在空闲帧持久化，
    -- 避免清空按钮点击路径上的同步大序列化（见 ClearAll/ClearMode）。
    snapshotSave = false,
}
D.State.timers = { ui = 0, roster = 0, save = 0, decay = 0, pending = 0, breakdown = 0, configSave = 0, uiSave = 0, rulesSave = 0, snapshotSave = 0 }
D.State.runtime = { paused = D.State.config.enabled ~= true, generation = Boot.generation, replaying = false }

function D.MarkViewDirty()
    D.State.dirty.stats = true
    D.State.dirty.view = true
end

function D.MarkLayoutDirty()
    D.State.dirty.layout = true
end

function D.MarkConfigDirty()
    D.State.dirty.configSave = not P:IsWriteFenced("config")
    D.State.dirty.view = true
    D.State.timers.configSave = 0
    if P:IsWriteFenced("config") then P:WarnWriteFence("config") end
end

function D.MarkUiDirty()
    D.State.dirty.uiSave = not P:IsWriteFenced("ui")
    D.State.timers.uiSave = 0
    if P:IsWriteFenced("ui") then P:WarnWriteFence("ui") end
end

function D.MarkRulesDirty()
    D.State.dirty.rulesSave = not P:IsWriteFenced("rules")
    D.State.timers.rulesSave = 0
    D.State.dirty.view = true
    if P:IsWriteFenced("rules") then P:WarnWriteFence("rules") end
end

------------------------------------------------------------------------
-- Session-only damage analysis filters
--
-- Exclusions are a view projection over the complete raw PVE friendly damage
-- table. Boss focus is an exact cumulative target projection: selecting a
-- target restores all retained PVE-friendly damage to that normalized target
-- and continues incrementally. Per-target historical active time is unavailable,
-- so the Boss projection intentionally hides DPS instead of presenting a false rate.
------------------------------------------------------------------------
D.Analysis = D.Analysis or {}
local A = D.Analysis
A.excludedPveDamageTargets = type(A.excludedPveDamageTargets) == "table" and A.excludedPveDamageTargets or {}
A.bossTarget = type(A.bossTarget) == "table" and A.bossTarget or nil
A.revision = math.max(0, tonumber(A.revision) or 0)

local ANALYSIS_PLACEHOLDERS = {
    [U.NormalizeName("其他")] = true,
    [U.NormalizeName("环境")] = true,
    [U.NormalizeName("未知")] = true,
    [U.NormalizeName("未知目标")] = true,
    [U.NormalizeName("未识别目标")] = true,
}

local function AnalysisTargetKey(name)
    local displayName = U.SafeName(name, "")
    local key = U.NormalizeName(displayName)
    if key == "" or ANALYSIS_PLACEHOLDERS[key] == true then return nil, nil end
    return key, displayName
end

-- Normalize hot-reloaded session state. This data is intentionally not written
-- to the persistent config/statistics schemas.
do
    local cleaned = {}
    local count = 0
    for key, entry in pairs(A.excludedPveDamageTargets) do
        local normalized, displayName = AnalysisTargetKey(type(entry) == "table" and entry.name or key)
        if normalized ~= nil and cleaned[normalized] == nil and count < 500 then
            cleaned[normalized] = { key = normalized, name = displayName }
            count = count + 1
        end
    end
    A.excludedPveDamageTargets = cleaned
    A.excludedCount = count
    local boss = A.bossTarget
    if type(boss) ~= "table" or AnalysisTargetKey(boss.name or boss.key) == nil
        or type(boss.contributions) ~= "table" or type(boss.active) ~= "table"
        or tonumber(boss.selectedAt) == nil then
        A.bossTarget = nil
    end
end

function A:IsExcluded(name)
    local key = AnalysisTargetKey(name)
    return key ~= nil and self.excludedPveDamageTargets[key] ~= nil
end

function A:GetExcludedCount()
    local cached = tonumber(self.excludedCount)
    if cached ~= nil and cached >= 0 then return math.floor(cached) end
    cached = U.TableCount(self.excludedPveDamageTargets)
    self.excludedCount = cached
    return cached
end

function A:GetBossTarget()
    local target = self.bossTarget
    if type(target) ~= "table" or U.Trim(target.key) == "" then return nil end

    -- v0.2.30 迁移：旧 Boss 语义只统计点击后的新事件。热重载可能保留
    -- repdpsRuntimeSanitized=true，因此迁移必须独立于普通清洗标记执行。
    if tonumber(target.projectionVersion) ~= 2 then
        target.projectionVersion = 2
        target.historicalIncluded = true
        target.rateUnavailable = true
        target.needsHistoricalRebuild = true
        target.repdpsRuntimeSanitized = nil
    end

    -- Hot reload can preserve a partially written runtime table. Sanitize it
    -- once, then keep all steady-state reads O(1). Rebuilding the contribution
    -- map on every ranking row would turn a 200-player Boss refresh into O(n²).
    if target.repdpsRuntimeSanitized ~= true then
        local normalizedKey, displayName = AnalysisTargetKey(target.name or target.key)
        if normalizedKey == nil then
            self.bossTarget = nil
            return nil
        end
        target.key = normalizedKey
        target.name = displayName
        local cleaned = {}
        local total = 0
        for key, value in pairs(type(target.contributions) == "table" and target.contributions or {}) do
            local amount = U.FiniteNumber(value, nil)
            if type(key) == "string" and key ~= "" and amount ~= nil and amount > 0 then
                cleaned[key] = amount
                total = total + amount
            end
        end
        target.contributions = cleaned
        target.total = total
        target.active = type(target.active) == "table" and target.active or { total = 0, last = nil, startedAt = nil }
        target.active.total = math.max(0, U.FiniteNumber(target.active.total, 0) or 0)
        target.active.last = U.FiniteNumber(target.active.last, nil)
        target.active.startedAt = U.FiniteNumber(target.active.startedAt, nil)
        if target.active.last == nil or target.active.startedAt == nil or target.active.last < target.active.startedAt then
            target.active.last = nil
            target.active.startedAt = nil
        end
        target.eventCount = math.max(0, math.floor(U.FiniteNumber(target.eventCount, 0) or 0))
        target.selectedAt = math.max(0, U.FiniteNumber(target.selectedAt, 0) or 0)
        -- v0.2.30 起 Boss 视图包含设置前已经累计的目标伤害。旧版的
        target.historicalIncluded = true
        target.rateUnavailable = true
        target.repdpsRuntimeSanitized = true
    end
    return target
end

function A:IsBoss(name)
    local key = AnalysisTargetKey(name)
    local boss = self:GetBossTarget()
    return key ~= nil and boss ~= nil and boss.key == key
end

function A:ClearBossTarget(markDirty)
    if self.bossTarget == nil then return false end
    self.bossTarget = nil
    self.revision = self.revision + 1
    if markDirty ~= false then D.MarkViewDirty() end
    return true
end

function A:ClearExclusions(markDirty)
    if self:GetExcludedCount() <= 0 then return false end
    self.excludedPveDamageTargets = {}
    self.excludedCount = 0
    self.revision = self.revision + 1
    if markDirty ~= false then D.MarkViewDirty() end
    return true
end

function A:SetExcluded(name, excluded)
    local key, displayName = AnalysisTargetKey(name)
    if key == nil then return false, "该行不是可过滤的具体目标" end
    excluded = excluded == true
    local changed = false
    if excluded then
        if self.excludedPveDamageTargets[key] == nil then
            if self:GetExcludedCount() >= 500 then return false, "排除目标已达到上限" end
            self.excludedPveDamageTargets[key] = { key = key, name = displayName }
            changed = true
        end
        -- Boss focus and exclusion filtering are two different projections of
        -- the same PVE-friendly damage table. They must be globally exclusive;
        -- otherwise an exclusion click can report success while Boss focus hides
        -- it, then unexpectedly reactivate after Boss is cancelled.
        if self.bossTarget ~= nil then
            self.bossTarget = nil
            changed = true
        end
    elseif self.excludedPveDamageTargets[key] ~= nil then
        self.excludedPveDamageTargets[key] = nil
        changed = true
    end
    if changed then
        self.excludedCount = U.TableCount(self.excludedPveDamageTargets)
        self.revision = self.revision + 1
        D.MarkViewDirty()
    end
    return true, changed
end

function A:ToggleExcluded(name)
    return self:SetExcluded(name, not self:IsExcluded(name))
end

function A:RebuildBossFromStats()
    local boss = self:GetBossTarget()
    if boss == nil then return false end

    -- Boss 专注是当前累计统计的一个投影视图，而不是“从点击以后开始”的
    -- 独立新场次。PVE 友军伤害目标明细为无损保存，因此可以按规范化目标名
    -- 从当前统计中精确恢复此前已经造成的伤害，不需要扫描整本事件日志。
    local contributions = {}
    local total = 0
    local modeStats = D.State and D.State.stats and D.State.stats.PVE or nil
    local actors = modeStats and modeStats.friendly and modeStats.friendly.actors or {}
    for actorKey, actor in pairs(actors) do
        local value = 0
        if D.Stats ~= nil and D.Stats.GetTargetDamageAmount ~= nil then
            value = D.Stats:GetTargetDamageAmount(actor, boss.key)
        else
            local targets = actor and actor.details and actor.details.damage and actor.details.damage.targets or {}
            for targetName, amount in pairs(targets) do
                if AnalysisTargetKey(targetName) == boss.key then
                    value = value + math.max(0, tonumber(amount) or 0)
                end
            end
        end
        if value > 0 then
            contributions[actorKey] = value
            total = total + value
        end
    end
    boss.contributions = contributions
    boss.total = total
    boss.historicalIncluded = true
    boss.rateUnavailable = true
    boss.eventCount = math.max(0, tonumber(boss.eventCount) or 0)
    boss.active = type(boss.active) == "table" and boss.active
        or { total = 0, last = nil, startedAt = nil }
    boss.projectionVersion = 2
    boss.needsHistoricalRebuild = false
    boss.repdpsRuntimeSanitized = true
    return true
end

function A:SetBossTarget(name)
    local key, displayName = AnalysisTargetKey(name)
    if key == nil then return false, "该行不是可设置的具体 Boss 目标" end
    local current = self:GetBossTarget()
    if current ~= nil and current.key == key then
        self.bossTarget = nil
    else
        self.bossTarget = {
            key = key,
            name = displayName,
            selectedAt = U.NowMs(),
            contributions = {},
            total = 0,
            eventCount = 0,
            active = { total = 0, last = nil, startedAt = nil },
            historicalIncluded = true,
            rateUnavailable = true,
            projectionVersion = 2,
            needsHistoricalRebuild = false,
            repdpsRuntimeSanitized = true,
        }
        if self:GetExcludedCount() > 0 then
            self.excludedPveDamageTargets = {}
            self.excludedCount = 0
        end
        self:RebuildBossFromStats()
    end
    self.revision = self.revision + 1
    D.MarkViewDirty()
    return true, self.bossTarget ~= nil
end

function A:GetBossContribution(actorKey)
    local boss = self:GetBossTarget()
    if boss == nil or actorKey == nil then return 0 end
    if boss.needsHistoricalRebuild == true then self:RebuildBossFromStats() end
    boss = self:GetBossTarget()
    return boss ~= nil and math.max(0, tonumber(boss.contributions[actorKey]) or 0) or 0
end

function A:TrackBossDamage(mode, sideName, actor, targetName, amount, event)
    local boss = self:GetBossTarget()
    if boss == nil or mode ~= "PVE" or sideName ~= "friendly" or type(actor) ~= "table" then return false end
    local targetKey = AnalysisTargetKey(targetName)
    if targetKey == nil or targetKey ~= boss.key then return false end

    -- 完整重算期间统计写入工作副本；Boss 投影在提交后从最终统计一次重建。
    -- 这里若继续增量写入，会把旧投影与重放事件叠加，导致贡献翻倍。
    if D.State ~= nil and D.State.runtime ~= nil and D.State.runtime.replaying == true then
        return false
    end

    local value = math.max(0, tonumber(amount) or 0)
    if value <= 0 then return false end
    local actorKey = tostring(actor.key or "")
    if actorKey == "" then return false end
    boss.contributions[actorKey] = math.max(0, tonumber(boss.contributions[actorKey]) or 0) + value
    boss.total = boss.total + value
    boss.eventCount = boss.eventCount + 1
    if D.Stats ~= nil and D.Stats.TouchActive ~= nil then
        D.Stats:TouchActive(boss.active, tonumber(event and event.timestamp) or U.NowMs(), D.State.config.sideWindowMs)
    end
    return true
end

function A:MergeBossActorKey(oldKey, newKey)
    local boss = self:GetBossTarget()
    if boss == nil or oldKey == nil or newKey == nil or oldKey == newKey then return end
    local oldValue = math.max(0, tonumber(boss.contributions[oldKey]) or 0)
    if oldValue > 0 then
        boss.contributions[newKey] = math.max(0, tonumber(boss.contributions[newKey]) or 0) + oldValue
        boss.contributions[oldKey] = nil
    end
end

function A:SnapshotBossRuntime()
    local boss = self:GetBossTarget()
    return boss ~= nil and U.DeepCopy(boss) or nil
end

function A:PrepareBossReplay()
    local boss = self:GetBossTarget()
    if boss == nil then return end
    boss.contributions = {}
    boss.total = 0
    boss.eventCount = 0
    boss.active = { total = 0, last = nil, startedAt = nil }
end

function A:RestoreBossRuntime(snapshot)
    self.bossTarget = type(snapshot) == "table" and U.DeepCopy(snapshot) or nil
    if self.bossTarget ~= nil then self.bossTarget.repdpsRuntimeSanitized = nil end
end

function A:Reset()
    self.excludedPveDamageTargets = {}
    self.excludedCount = 0
    self.bossTarget = nil
    self.revision = self.revision + 1
    D.MarkViewDirty()
end

function A:IsPveFriendlyDamageScope(mode, sideName, page)
    return mode == "PVE" and sideName == "friendly" and (page == nil or page == "DAMAGE")
end

-- Classification changes can require replaying a very large journal. Route all
-- user/rule corrections through the runtime scheduler so a 200-player battle is
-- not interrupted by a synchronous full replay. When already idle, the runtime
-- is still allowed to rebuild immediately.
function D.RequestReclassify(preferImmediate, reason, affectedActor)
    D.State.dirty.reclassify = true
    local runtime = D.Runtime
    if runtime ~= nil and runtime.RequestReclassify ~= nil then
        return runtime:RequestReclassify(preferImmediate == true, reason, affectedActor)
    end
    return false
end

-- Official roster/sight evidence usually only needs unresolved events retried.
-- Keep that path separate from user/rule corrections, which require a full
-- historical replay. This prevents a crowded sight scan from rebuilding tens of
-- thousands of already-applied events every few seconds.
function D.RequestPendingReclassify()
    D.State.dirty.reclassify = true
    local runtime = D.Runtime
    if runtime ~= nil and runtime.RequestPendingReclassify ~= nil then
        return runtime:RequestPendingReclassify()
    end
    return false
end

------------------------------------------------------------------------
-- Relation conflicts and deterministic combat evidence
------------------------------------------------------------------------

D.RelationConflicts = D.RelationConflicts or {
    entries = {},
    byKey = {},
    nextId = 1,
}
local Conflicts = D.RelationConflicts

local function ConflictEntityKey(entity)
    return type(entity) == "table" and tostring(entity.key or entity.name or "unknown") or "unknown"
end

-- 冲突可能在多人混战中高频出现。这里直接处理单个实体，避免每次
-- Record 都创建 `{ source, target }` 临时数组并交给 GC。
local function MarkConflictEntity(entity, counterpartKey, entry, now, shouldCount)
    if type(entity) ~= "table" then return end
    entity.flags = entity.flags or {}
    entity.flags.relationConflict = true
    if E ~= nil and E.conflictKeys ~= nil then E.conflictKeys[entity.key] = true end
    if shouldCount then
        entity.flags.relationConflictCount = (tonumber(entity.flags.relationConflictCount) or 0) + 1
        entity.flags.lastRelationConflictAt = now
        entity.flags.lastRelationConflictKind = entry.kind
        entity.flags.lastRelationConflictWith = counterpartKey
    end
end

function Conflicts:Record(kind, source, target, event, detail)
    local sourceKey = ConflictEntityKey(source)
    local targetKey = ConflictEntityKey(target)
    local key = table.concat({ tostring(kind or "RELATION"), sourceKey, targetKey }, "|")
    local now = U.TimestampOrNow(event and event.timestamp)
    local numericEventId = U.FiniteNumber(event and event.eventId, nil)
    if numericEventId ~= nil then numericEventId = math.floor(numericEventId) end
    local entry = self.byKey[key]
    if type(entry) ~= "table" then
        entry = {
            conflictId = tostring(self.nextId),
            kind = tostring(kind or "RELATION"),
            sourceKey = sourceKey,
            targetKey = targetKey,
            sourceName = source and source.name or "未知来源",
            targetName = target and target.name or "未知目标",
            firstAt = now,
            lastAt = now,
            count = 0,
            maxEventIdSeen = 0,
        }
        self.nextId = (tonumber(self.nextId) or 1) + 1
        self.byKey[key] = entry
        self.entries[#self.entries + 1] = entry
    end
    local shouldCount = numericEventId == nil or numericEventId > (tonumber(entry.maxEventIdSeen) or 0)
    if shouldCount then
        entry.count = (tonumber(entry.count) or 0) + 1
        if numericEventId ~= nil then entry.maxEventIdSeen = numericEventId end
        entry.lastAt = math.max(tonumber(entry.lastAt) or now, now)
        entry.lastAbility = event and event.abilityName or entry.lastAbility
        entry.lastEventId = event and event.eventId or entry.lastEventId
        entry.detail = tostring(detail or entry.detail or "")
    end
    MarkConflictEntity(source, targetKey, entry, now, shouldCount)
    MarkConflictEntity(target, sourceKey, entry, now, shouldCount)
    -- Keep a little hysteresis. In a multi-faction raid, enemy-vs-enemy pairs
    -- can create hundreds of distinct conflicts. Removing index 1 for every new
    -- pair shifts the entire array each time and becomes a hidden O(n) hot path.
    if #self.entries > 360 then
        local firstKept = #self.entries - 300 + 1
        local compacted = {}
        for index = 1, firstKept - 1 do
            local removed = self.entries[index]
            if removed ~= nil then
                local removedKey = table.concat({ tostring(removed.kind), tostring(removed.sourceKey), tostring(removed.targetKey) }, "|")
                if self.byKey[removedKey] == removed then self.byKey[removedKey] = nil end
            end
        end
        for index = firstKept, #self.entries do
            compacted[#compacted + 1] = self.entries[index]
        end
        self.entries = compacted
    end
    if shouldCount then
        D.Diagnostics.counters.relationConflicts = (tonumber(D.Diagnostics.counters.relationConflicts) or 0) + 1
        D.MarkViewDirty()
    end
    return entry
end

function Conflicts:Reset()
    self.entries = {}
    self.byKey = {}
    self.nextId = 1
    -- v0.2.25（问题 13）：只遍历登记过冲突的实体，不再扫描全部历史实体。
    local conflictKeys = D.Entities and D.Entities.conflictKeys or nil
    if type(conflictKeys) == "table" then
        local keys = {}
        for key in pairs(conflictKeys) do keys[#keys + 1] = key end
        for _, key in ipairs(keys) do
            local entity = D.Entities.byKey[key]
            if type(entity) == "table" and type(entity.flags) == "table" then
                entity.flags.relationConflict = nil
                entity.flags.relationConflictCount = nil
                entity.flags.lastRelationConflictAt = nil
                entity.flags.lastRelationConflictKind = nil
                entity.flags.lastRelationConflictWith = nil
            end
            conflictKeys[key] = nil
        end
    end
    D.Diagnostics.counters.relationConflicts = 0
end

------------------------------------------------------------------------
-- Persistent manual classification / ignore rules
------------------------------------------------------------------------

D.Rules = D.Rules or {
    byId = {},
    byStableId = {},
    byName = {},
}
local Rules = D.Rules

local function RuleEnabled(rule)
    return type(rule) == "table" and rule.enabled ~= false
end

local function UnsafePersistentRuleName(name)
    local normalized = U.NormalizeName(name)
    if normalized == "" then return true end
    if normalized == "环境" or normalized == "未知" or normalized == "未识别来源" or normalized == "未识别目标" then return true end
    if string.find(normalized, "未识别来源(", 1, true) == 1 then return true end
    if string.find(normalized, "未识别目标(", 1, true) == 1 then return true end
    return false
end

local function IsProtectedSelfEntity(entity)
    if type(entity) ~= "table" or D.Identity == nil then return false end
    if entity.key == D.Identity.entityKey or entity.hardRelation == "SELF" then return true end
    local normalized = entity.normalizedName or U.NormalizeName(entity.name)
    if normalized == "" then return false end
    return normalized == U.NormalizeName(D.Identity.playerName)
        or normalized == U.NormalizeName(D.Identity.playerNameWithWorld)
end

function Rules:Reindex()
    self.byId = {}
    self.byStableId = {}
    self.byName = {}
    D.State.rules = type(D.State.rules) == "table" and D.State.rules or { entries = {}, nextId = 1, revision = 0 }

    local source = U.OrderedArrayValues(D.State.rules.entries)
    local normalized = {}
    local pruned = 0
    local metadataCleaned = 0
    local maxNumericRuleId = 0
    local maxSequence = 0
    local maxRuleNumber = 2000000000
    local maxRuleSequence = 9000000000000000

    for order, rule in ipairs(source) do
        if type(rule) == "table" and U.Trim(rule.ruleId) ~= "" then
            rule.ruleId = tostring(rule.ruleId)
            local numericId = U.FiniteNumber(string.match(rule.ruleId, "^R(%d+)$"), nil)
            if numericId ~= nil and numericId >= 0 and numericId <= maxRuleNumber then
                maxNumericRuleId = math.max(maxNumericRuleId, math.floor(numericId))
            end
            rule.matchType = rule.matchType == "ID" and "ID" or "NAME"
            rule.matchValue = tostring(rule.matchValue or "")
            if rule.matchType == "NAME" then rule.matchValue = U.NormalizeName(rule.matchValue) end
            rule.displayName = U.SafeName(rule.displayName, rule.matchValue)
            rule.enabled = rule.enabled ~= false
            if rule.kind ~= "PLAYER" and rule.kind ~= "NPC" and rule.kind ~= "MATE"
                and rule.kind ~= "SLAVE" and rule.kind ~= "OTHER" then rule.kind = nil end
            if rule.relation ~= "FRIENDLY" and rule.relation ~= "OPPONENT"
                and rule.relation ~= "NEUTRAL" then rule.relation = nil end
            rule.ignored = rule.ignored == true
            -- Arbitrary-player guild identity is not in the official API contract.
            -- Remove old intent-only metadata instead of presenting it as a feature.
            if rule.guildSyncRequested ~= nil or rule.guildSyncStatus ~= nil
                or rule.guildSyncRequestedSeq ~= nil or rule.guildSourcePlayerId ~= nil
                or rule.guildSourcePlayerName ~= nil then
                metadataCleaned = metadataCleaned + 1
            end
            rule.guildSyncRequested = nil
            rule.guildSyncStatus = nil
            rule.guildSyncRequestedSeq = nil
            rule.guildSourcePlayerId = nil
            rule.guildSourcePlayerName = nil

            local created = U.Clamp(math.floor(U.FiniteNumber(rule.createdSeq, 0) or 0), 0, maxRuleSequence)
            local updated = U.Clamp(math.floor(U.FiniteNumber(rule.updatedSeq, created) or created), created, maxRuleSequence)
            rule.createdSeq = created
            rule.updatedSeq = updated
            maxSequence = math.max(maxSequence, updated)

            local unsafeName = rule.matchType == "NAME" and UnsafePersistentRuleName(rule.matchValue)
            if rule.matchValue ~= "" and not unsafeName
                and (rule.kind ~= nil or rule.relation ~= nil or rule.ignored) then
                normalized[#normalized + 1] = {
                    rule = rule,
                    order = order,
                    seq = updated,
                    matchKey = rule.matchType .. ":" .. rule.matchValue,
                }
            else
                pruned = pruned + 1
            end
        else
            pruned = pruned + 1
        end
    end

    local function Newer(left, right)
        if right == nil then return true end
        if left.seq ~= right.seq then return left.seq > right.seq end
        return left.order > right.order
    end

    -- Resolve duplicate IDs first, then duplicate match keys. The most recently
    -- updated valid rule wins; sparse or corrupted persisted arrays cannot make
    -- later rules disappear behind an ipairs hole.
    local latestById = {}
    for _, item in ipairs(normalized) do
        local id = item.rule.ruleId
        if Newer(item, latestById[id]) then
            if latestById[id] ~= nil then pruned = pruned + 1 end
            latestById[id] = item
        else
            pruned = pruned + 1
        end
    end
    local latestByMatch = {}
    for _, item in pairs(latestById) do
        if Newer(item, latestByMatch[item.matchKey]) then
            if latestByMatch[item.matchKey] ~= nil then pruned = pruned + 1 end
            latestByMatch[item.matchKey] = item
        else
            pruned = pruned + 1
        end
    end

    local selected = {}
    for _, item in pairs(latestByMatch) do selected[#selected + 1] = item end
    table.sort(selected, function(a, b)
        if a.seq ~= b.seq then return a.seq > b.seq end
        return a.order > b.order
    end)
    while #selected > D.Const.MAX_PERSISTENT_RULES do
        selected[#selected] = nil
        pruned = pruned + 1
    end
    table.sort(selected, function(a, b) return a.order < b.order end)

    local clean = {}
    for _, item in ipairs(selected) do
        local rule = item.rule
        clean[#clean + 1] = rule
        self.byId[rule.ruleId] = rule
        if rule.matchType == "ID" then self.byStableId[rule.matchValue] = rule
        else self.byName[rule.matchValue] = rule end
    end
    D.State.rules.entries = clean
    local nextId = U.Clamp(math.floor(U.FiniteNumber(D.State.rules.nextId, 1) or 1), 1, maxRuleNumber)
    local revision = U.Clamp(math.floor(U.FiniteNumber(D.State.rules.revision, 0) or 0), 0, maxRuleSequence)
    D.State.rules.nextId = math.min(maxRuleNumber, math.max(1, maxNumericRuleId + 1, nextId))
    D.State.rules.revision = math.min(maxRuleSequence, math.max(0, maxSequence, revision))

    if (pruned > 0 or metadataCleaned > 0) and D.State.dirty ~= nil then
        D.State.dirty.rulesSave = true
        if pruned > 0 and D.Diagnostics ~= nil and D.Diagnostics.AddWarning ~= nil then
            D.Diagnostics:AddWarning("rules", "已清理重复、超限或无效名单规则：" .. tostring(pruned))
        end
        if metadataCleaned > 0 and D.Diagnostics ~= nil and D.Diagnostics.AddInfo ~= nil then
            D.Diagnostics:AddInfo("rules", "已移除未实现的公会同步元数据：" .. tostring(metadataCleaned))
        end
    end
end

function Rules:List()
    local result = U.OrderedArrayValues(D.State.rules.entries)
    table.sort(result, function(a, b)
        local au = tonumber(a.updatedSeq) or tonumber(a.createdSeq) or 0
        local bu = tonumber(b.updatedSeq) or tonumber(b.createdSeq) or 0
        if au == bu then return tostring(a.displayName) < tostring(b.displayName) end
        return au > bu
    end)
    return result
end

function Rules:GetById(ruleId)
    return ruleId ~= nil and self.byId[tostring(ruleId)] or nil
end

function Rules:FindForEntity(entity)
    if entity == nil then return nil, nil end
    entity.flags = entity.flags or {}
    entity.flags.ruleAmbiguous = false
    if entity.stringId ~= nil then
        local byId = self.byStableId[tostring(entity.stringId)]
        if RuleEnabled(byId) then return byId, "ID" end
    end
    local normalized = U.NormalizeName(entity.name)
    local byName = normalized ~= "" and self.byName[normalized] or nil
    if RuleEnabled(byName) then
        local conflict = entity.flags.nameConflict == true
            or (D.Entities ~= nil and D.Entities.nameConflicts ~= nil and D.Entities.nameConflicts[normalized] == true)
        local sharedNonPlayerRule = byName.kind == "NPC" or byName.kind == "MATE"
            or byName.kind == "SLAVE" or byName.kind == "OTHER"
        if conflict then
            if not sharedNonPlayerRule then
                entity.flags.ruleAmbiguous = true
                return nil, "AMBIGUOUS_NAME"
            end
            -- A broad NPC/summon name rule may safely cover multiple instances
            -- of the same non-player type, but it must never overwrite a known
            -- player (or a different known non-player type) sharing that name.
            local concreteKind = entity.hardKind or entity.kind
            if concreteKind == nil or concreteKind == "UNKNOWN" then
                -- Defer a broad non-player rule until sight/target evidence tells
                -- us what this newly discovered same-name unit actually is.
                entity.flags.ruleAmbiguous = true
                return nil, "AMBIGUOUS_NAME_KIND_PENDING"
            end
            if concreteKind ~= byName.kind then
                entity.flags.ruleAmbiguous = true
                return nil, "AMBIGUOUS_NAME_KIND"
            end
            if byName.relation ~= nil and entity.hardRelation ~= nil then
                local function RelationBucket(relation)
                    if relation == "SELF" or relation == "TEAM" or relation == "FRIENDLY" then return "FRIENDLY" end
                    if relation == "OPPONENT" then return "OPPONENT" end
                    if relation == "NEUTRAL" then return "NEUTRAL" end
                    return nil
                end
                local ruleBucket = RelationBucket(byName.relation)
                local hardBucket = RelationBucket(entity.hardRelation)
                if ruleBucket ~= nil and hardBucket ~= nil and ruleBucket ~= hardBucket then
                    entity.flags.ruleAmbiguous = true
                    return nil, "AMBIGUOUS_NAME_RELATION"
                end
            end
        end
        return byName, "NAME"
    end
    return nil, nil
end

local function RuleRevisionValue()
    return math.max(0, math.floor(tonumber(D.State.rules and D.State.rules.revision) or 0))
end

local function RuleApplicationInputsMatch(entity, revision)
    if type(entity) ~= "table" then return false end
    local normalized = entity.normalizedName or U.NormalizeName(entity.name)
    local stableId = entity.stringId ~= nil and tostring(entity.stringId) or ""
    local conflict = entity.flags ~= nil and entity.flags.nameConflict == true
        or (D.Entities ~= nil and D.Entities.nameConflicts ~= nil
            and D.Entities.nameConflicts[normalized] == true)
    return tonumber(entity.repdpsRuleRevision) == revision
        and tostring(entity.repdpsRuleNormalizedName or "") == tostring(normalized or "")
        and tostring(entity.repdpsRuleStableId or "") == stableId
        and tostring(entity.repdpsRuleHardKind or "") == tostring(entity.hardKind or "")
        and tostring(entity.repdpsRuleHardRelation or "") == tostring(entity.hardRelation or "")
        and entity.repdpsRuleNameConflict == conflict
end

local function StampRuleApplicationInputs(entity, revision)
    if type(entity) ~= "table" then return end
    local normalized = entity.normalizedName or U.NormalizeName(entity.name)
    local conflict = entity.flags ~= nil and entity.flags.nameConflict == true
        or (D.Entities ~= nil and D.Entities.nameConflicts ~= nil
            and D.Entities.nameConflicts[normalized] == true)
    entity.repdpsRuleRevision = revision
    entity.repdpsRuleNormalizedName = normalized
    entity.repdpsRuleStableId = entity.stringId ~= nil and tostring(entity.stringId) or ""
    entity.repdpsRuleHardKind = entity.hardKind
    entity.repdpsRuleHardRelation = entity.hardRelation
    entity.repdpsRuleNameConflict = conflict
end

function Rules:ApplyToEntity(entity, force)
    if entity == nil then return false end
    local revision = RuleRevisionValue()
    -- 名单只会在 revision 或实体匹配输入改变后产生不同结果。旧实现对
    -- 每条战斗事件的来源/目标重复执行名称规范化和规则表查询，长时间
    -- Boss 战会制造大量无意义短命字符串与表访问。
    if force ~= true and RuleApplicationInputsMatch(entity, revision) then return false end
    StampRuleApplicationInputs(entity, revision)
    local isSelf = IsProtectedSelfEntity(entity)
    if isSelf then
        local changed = entity.manualOverride ~= nil or entity.kind ~= "PLAYER" or entity.relation ~= "SELF"
        entity.manualOverride = nil
        entity.persistentRuleId = nil
        entity.kind = "PLAYER"
        entity.relation = "SELF"
        entity.flags = entity.flags or {}
        entity.flags.ruleMatchMode = nil
        entity.flags.ruleAmbiguous = false
        return changed
    end
    if entity.manualOverride ~= nil and entity.manualOverride.source == "session" then
        -- A session edit overlays only the fields the user actually touched.
        -- When a base rule is changed/disabled/removed, rebase those edits onto
        -- the new rule/automatic state instead of freezing copied old values.
        if D.Entities ~= nil and type(D.Entities.RebaseSessionOverride) == "function"
            and entity.repdpsRebasingSessionOverride ~= true then
            entity.repdpsRebasingSessionOverride = true
            local changed = D.Entities:RebaseSessionOverride(entity)
            entity.repdpsRebasingSessionOverride = nil
            return changed == true
        end
        return false
    end
    local rule, matchMode = self:FindForEntity(entity)
    local old = entity.manualOverride
    if rule == nil then
        entity.flags = entity.flags or {}
        entity.flags.ruleMatchMode = nil
        -- A removed/disabled rule can leave persistentRuleId behind when a
        -- session overlay was rebased after the rule disappeared.  The stale ID
        -- does not own any state, but keeping it makes later save/remove and UI
        -- decisions depend on a rule that no longer exists.  Clear it whenever
        -- no current rule matches, regardless of the old override source.
        local staleRuleId = entity.persistentRuleId ~= nil
        entity.persistentRuleId = nil
        if old ~= nil and old.source == "rule" then
            entity.manualOverride = nil
            entity.kind = entity.hardKind or entity.inferredKind or "UNKNOWN"
            entity.relation = entity.hardRelation or entity.historyRelation or "UNKNOWN"
            if D.Entities ~= nil and D.Entities.Resolve ~= nil then D.Entities:Resolve(entity) end
            return true
        end
        return staleRuleId
    end
    local same = old ~= nil and old.source == "rule" and old.ruleId == rule.ruleId
        and old.kind == rule.kind and old.relation == rule.relation and old.ignored == rule.ignored
    if same then return false end
    entity.manualOverride = {
        kind = rule.kind,
        relation = rule.relation,
        ignored = rule.ignored == true,
        source = "rule",
        ruleId = rule.ruleId,
        matchMode = matchMode,
        at = U.NowMs(),
    }
    entity.persistentRuleId = rule.ruleId
    entity.flags = entity.flags or {}
    entity.flags.ruleAmbiguous = false
    entity.flags.ruleMatchMode = matchMode
    if D.Entities ~= nil and D.Entities.Resolve ~= nil then D.Entities:Resolve(entity) end
    return true
end

function Rules:ApplyAll(force)
    local changed = false
    local entities = {}
    for _, entity in pairs(D.Entities and D.Entities.byKey or {}) do
        entities[#entities + 1] = entity
    end
    -- First settle every rule baseline, then reconcile cross-entity mirrors.
    -- Interleaving the two made the final result depend on pairs() order.
    for _, entity in ipairs(entities) do
        changed = self:ApplyToEntity(entity, force) == true or changed
    end
    if D.Entities ~= nil and type(D.Entities.SyncPlayerHistoryCorrection) == "function" then
        for _, entity in ipairs(entities) do
            local mirrorChanged = D.Entities:SyncPlayerHistoryCorrection(entity)
            changed = mirrorChanged == true or changed
        end
    end
    if changed then
        D.MarkViewDirty()
        D.RequestReclassify(true, "PERSISTENT_RULE_APPLY")
    end
    return changed
end

function Rules:GetForEntity(entity)
    if entity == nil then return nil, nil end
    if entity.persistentRuleId ~= nil then
        local current = self:GetById(entity.persistentRuleId)
        if current ~= nil then return current, entity.manualOverride and entity.manualOverride.matchMode or nil end
    end
    return self:FindForEntity(entity)
end

function Rules:PredictMatchType(entity, override, requestedMatchType)
    if requestedMatchType == "ID" and entity ~= nil and entity.stringId ~= nil and tostring(entity.stringId) ~= "" then return "ID" end
    if requestedMatchType == "NAME" then return "NAME" end
    override = type(override) == "table" and override or {}
    local kind = override.kind or (entity and entity.kind)
    if kind == "NPC" or kind == "MATE" or kind == "SLAVE" or kind == "OTHER" then
        return "NAME"
    end
    if entity ~= nil and entity.stringId ~= nil and tostring(entity.stringId) ~= "" then return "ID" end
    return "NAME"
end

function Rules:AllocateRuleId()
    local maxRuleNumber = 2000000000
    local candidate = U.Clamp(math.floor(U.FiniteNumber(D.State.rules.nextId, 1) or 1), 1, maxRuleNumber)
    -- At most MAX_PERSISTENT_RULES IDs can be occupied, so bounded probing is
    -- sufficient even after a corrupted save pushed nextId onto an existing ID.
    for _ = 1, (D.Const.MAX_PERSISTENT_RULES or 500) + 1 do
        local ruleId = string.format("R%06d", candidate)
        if self.byId[ruleId] == nil then
            D.State.rules.nextId = candidate >= maxRuleNumber and 1 or candidate + 1
            return ruleId
        end
        candidate = candidate >= maxRuleNumber and 1 or candidate + 1
    end
    return nil
end

function Rules:UpsertFromEntity(entity, requestedMatchType)
    if entity == nil then return nil, "单位不存在" end
    local override = entity.manualOverride
    if type(override) ~= "table" or (override.kind == nil and override.relation == nil and override.ignored ~= true) then
        return nil, "请先设置友军、敌军、类型或忽略状态"
    end
    if override.source == "rule" then
        local existingRule = self:GetById(override.ruleId or entity.persistentRuleId)
        if existingRule ~= nil then
            -- The formal rule already owns exactly this state. Treat a repeated
            -- save as idempotent instead of incrementing revision and replaying
            -- the correction journal for no semantic change.
            return existingRule, existingRule.matchType
        end
    end
    if UnsafePersistentRuleName(entity.name) then
        return nil, "未识别/环境占位名称不能保存为永久规则"
    end
    local matchType = self:PredictMatchType(entity, override, requestedMatchType)
    local desiredKind = override.kind or entity.kind
    if matchType == "NAME" and desiredKind == "PLAYER" then
        return nil, "玩家永久规则必须使用单位ID；当前仅可保留本次人工纠错"
    end
    if matchType == "NAME" and entity.flags ~= nil and entity.flags.nameConflict == true then
        -- NPC/召唤物通常需要名称规则来跨实例复用，因此不能因为
        -- 多个同名实例就一概禁止。但若当前已知同名候选的类型或
        -- 关系互相冲突，保存宽泛名称规则会把人工纠错扩散到错误对象。
        local candidates = D.Entities ~= nil and D.Entities.GetCandidatesByName ~= nil
            and D.Entities:GetCandidatesByName(entity.name) or {}
        local concreteRelations = { SELF = true, TEAM = true, FRIENDLY = true, OPPONENT = true, NEUTRAL = true }
        for _, candidate in ipairs(candidates) do
            if candidate.key ~= entity.key then
                local candidateOverride = candidate.manualOverride or {}
                local candidateKind = candidateOverride.kind or candidate.kind
                local candidateRelation = candidateOverride.relation or candidate.relation
                if override.kind ~= nil and candidateKind ~= nil and candidateKind ~= "UNKNOWN"
                    and candidateKind ~= override.kind then
                    return nil, "同名单位存在类型冲突，不能保存宽泛名称规则"
                end
                if override.relation ~= nil and concreteRelations[candidateRelation] == true
                    and candidateRelation ~= override.relation then
                    return nil, "同名单位存在关系冲突，不能保存宽泛名称规则"
                end
                if override.ignored == true then
                    return nil, "同名单位不止一个，不能保存宽泛的忽略规则"
                end
            end
        end
    end
    local matchValue
    if matchType == "ID" then
        if entity.stringId == nil or tostring(entity.stringId) == "" then return nil, "当前单位没有可用单位ID" end
        matchValue = tostring(entity.stringId)
    else
        matchValue = U.NormalizeName(entity.name)
        if matchValue == "" then return nil, "当前单位名称不可用" end
    end

    local existing = nil
    if override.baseRuleId ~= nil then existing = self:GetById(override.baseRuleId) end
    if existing == nil and entity.persistentRuleId ~= nil then existing = self:GetById(entity.persistentRuleId) end
    if existing == nil then existing = matchType == "ID" and self.byStableId[matchValue] or self.byName[matchValue] end
    if existing == nil and matchType == "NAME" and entity.stringId ~= nil then
        existing = self.byStableId[tostring(entity.stringId)]
    end
    -- Only player/name rules are upgraded to a stable ID. NPCs, summons and
    -- scene objects commonly respawn with a different instance ID, so their
    -- explicit name rule must remain broad enough to match the next instance.
    if existing == nil and matchType == "ID" and entity.flags.nameConflict ~= true then
        local nameRule = self.byName[U.NormalizeName(entity.name)]
        if nameRule ~= nil and (nameRule.kind == nil or nameRule.kind == "PLAYER") then existing = nameRule end
    end
    if existing == nil and #(D.State.rules.entries or {}) >= D.Const.MAX_PERSISTENT_RULES then
        return nil, "名单已达到上限"
    end
    D.State.rules.revision = (tonumber(D.State.rules.revision) or 0) + 1
    local seq = D.State.rules.revision
    local rule = existing
    if rule == nil then
        local ruleId = self:AllocateRuleId()
        if ruleId == nil then return nil, "无法分配新的名单编号，请先删除无效规则" end
        rule = { ruleId = ruleId, createdSeq = seq, enabled = true }
        D.State.rules.entries[#D.State.rules.entries + 1] = rule
    end
    rule.matchType = matchType
    rule.matchValue = matchValue
    rule.displayName = entity.name
    rule.kind = override.kind
    rule.relation = override.relation
    rule.ignored = override.ignored == true
    rule.enabled = true
    rule.updatedSeq = seq
    self:Reindex()
    entity.manualOverride = nil
    self:ApplyToEntity(entity, true)
    local replayEntity = entity
    if D.Entities ~= nil and type(D.Entities.SyncPlayerHistoryCorrection) == "function" then
        local mirrorChanged, mirrorEntity = D.Entities:SyncPlayerHistoryCorrection(entity)
        if mirrorChanged == true and mirrorEntity ~= nil then replayEntity = mirrorEntity end
    end
    D.MarkRulesDirty()
    D.RequestReclassify(true, "PERSISTENT_RULE_SAVE", {
        key = replayEntity.key, name = replayEntity.name, boundId = replayEntity.stringId,
    })
    return rule, matchType
end

function Rules:SetEnabled(ruleId, enabled)
    local rule = self:GetById(ruleId)
    if rule == nil then return false end
    local nextEnabled = enabled == true
    if (rule.enabled ~= false) == nextEnabled then return true, "NO_CHANGE" end
    rule.enabled = nextEnabled
    D.State.rules.revision = (tonumber(D.State.rules.revision) or 0) + 1
    rule.updatedSeq = D.State.rules.revision
    self:Reindex()
    self:ApplyAll(true)
    -- Rule Authority changed even when no matching entity is currently visible.
    -- Retained event facts may still match this rule during replay, so do not
    -- make reclassification conditional on ApplyAll observing a live row.
    D.RequestReclassify(true, nextEnabled and "PERSISTENT_RULE_ENABLE" or "PERSISTENT_RULE_DISABLE")
    D.MarkRulesDirty()
    return true
end

function Rules:Remove(ruleId)
    local id = tostring(ruleId or "")
    local removed = false
    local kept = {}
    for _, rule in ipairs(U.OrderedArrayValues(D.State.rules.entries)) do
        if type(rule) == "table" and tostring(rule.ruleId) == id then removed = true else kept[#kept + 1] = rule end
    end
    if not removed then return false end
    D.State.rules.entries = kept
    D.State.rules.revision = (tonumber(D.State.rules.revision) or 0) + 1
    self:Reindex()
    self:ApplyAll(true)
    D.RequestReclassify(true, "PERSISTENT_RULE_REMOVE")
    D.MarkRulesDirty()
    return true
end

function Rules:RemoveForEntity(entity)
    local rule = self:GetForEntity(entity)
    if rule == nil then return false end
    return self:Remove(rule.ruleId)
end

function Rules:ClearAll()
    if #(D.State.rules.entries or {}) == 0 then return false end
    D.State.rules.entries = {}
    D.State.rules.revision = (tonumber(D.State.rules.revision) or 0) + 1
    self:Reindex()
    self:ApplyAll(true)
    D.RequestReclassify(true, "PERSISTENT_RULE_CLEAR_ALL")
    D.MarkRulesDirty()
    return true
end

Rules:Reindex()

D.Entities = D.Entities or {
    byKey = {},
    byName = {},
    nameConflicts = {},
    nameBindings = {},
    aliases = {},
    roster = {},
    -- Current official roster aliases (short name / Name@World) mapped to one
    -- canonical team entity. This is separate from byName: roster aliases are
    -- temporal TEAM evidence only and must never make a broad permanent merge.
    teamNameAliases = {},
    teamMissingSince = {},
    evidenceCooldowns = {},
    -- v0.2.25（问题 13）：软证据实体集合。只有真正持有"可重置的软证据"
    -- 的实体才会进入对应集合；清空/重放时只遍历这些集合，不再扫描全部
    -- 历史实体。实体被重置后会从集合移除，避免集合永久增长。
    --   softEvidenceKeys        持有关系评分/敌对窗口等软证据
    --   transientRelationKeys   持有 strongRelation 派生关系
    --   conflictKeys            持有 relationConflict 标记
    softEvidenceKeys = {},
    transientRelationKeys = {},
    conflictKeys = {},
}

local E = D.Entities
E.nameBindings = E.nameBindings or {}
E.teamNameAliases = type(E.teamNameAliases) == "table" and E.teamNameAliases or {}
E.softEvidenceKeys = type(E.softEvidenceKeys) == "table" and E.softEvidenceKeys or {}
E.transientRelationKeys = type(E.transientRelationKeys) == "table" and E.transientRelationKeys or {}
E.conflictKeys = type(E.conflictKeys) == "table" and E.conflictKeys or {}

-- 登记实体进入软证据集合（幂等）。软证据写入点（AddScore、强关系、
-- 敌对窗口、冲突标记）必须在修改状态前调用，保证重置能精确覆盖。
-- 同时暴露为方法供 Runtime 的敌对窗口等写入点使用。
local function MarkSoftEvidence(entity)
    if type(entity) == "table" and entity.key ~= nil then
        E.softEvidenceKeys[entity.key] = true
    end
end
E.MarkSoftEvidence = MarkSoftEvidence

local function UnmarkSoftEvidence(entity)
    if type(entity) == "table" and entity.key ~= nil then
        E.softEvidenceKeys[entity.key] = nil
        E.transientRelationKeys[entity.key] = nil
        E.conflictKeys[entity.key] = nil
    end
end

local function NewEntity(key, name)
    return {
        key = key,
        name = U.SafeName(name, "未知"),
        normalizedName = U.NormalizeName(name),
        nameWithWorld = nil,
        stringId = nil,
        kind = "UNKNOWN",
        hardKind = nil,
        inferredKind = nil,
        inferredKindReason = nil,
        inferredKindAt = nil,
        relation = "UNKNOWN",
        hardRelation = nil,
        strongRelation = nil,
        strongRelationSince = nil,
        strongRelationLastSeenAt = nil,
        strongRelationReason = nil,
        historyRelation = "UNKNOWN",
        relationHistory = {},
        relationSince = nil,
        firstRelationEvidenceAt = nil,
        lastHardRelationEndedAt = 0,
        relationScores = { friendly = 0, opponent = 0, neutral = 0 },
        evidenceKinds = {},
        relationEvidenceKinds = {},
        firstSeenAt = U.NowMs(),
        lastSeenAt = U.NowMs(),
        lastEvidenceAt = 0,
        lastScoreDecayAt = nil,
        flags = {},
        manualOverride = nil,
    }
end

-- Record only identity observations obtained from official unit APIs that expose
-- both a visible name and a stable string ID. Combat log names alone must never
-- create a binding. The bounded history lets a later replay ask which ID, if
-- any, was uniquely visible around the original event time.
function E:RecordNameBinding(name, stringId, kind, source, seenAt, deferReclassify, kindSource)
    local normalized = U.NormalizeName(name)
    local stableId = stringId ~= nil and tostring(stringId) ~= "" and tostring(stringId) or nil
    if normalized == "" or stableId == nil then return nil, false end

    local now = U.TimestampOrNow(seenAt)
    local materialChanged = false
    self.nameBindings = self.nameBindings or {}
    local bucket = self.nameBindings[normalized]
    if type(bucket) ~= "table" then
        bucket = { byId = {}, updatedAt = now }
        self.nameBindings[normalized] = bucket
    end
    bucket.byId = type(bucket.byId) == "table" and bucket.byId or {}

    local record = bucket.byId[stableId]
    if type(record) ~= "table" then
        materialChanged = true
        record = {
            stringId = stableId,
            firstSeenAt = now,
            lastSeenAt = now,
            segments = { { from = now, to = now } },
            kind = nil,
            source = tostring(source or "unit_api"),
        }
        bucket.byId[stableId] = record
    else
        record.firstSeenAt = math.min(U.FiniteNumber(record.firstSeenAt, now) or now, now)
        record.lastSeenAt = math.max(U.FiniteNumber(record.lastSeenAt, now) or now, now)
        record.source = tostring(source or record.source or "unit_api")
        record.segments = type(record.segments) == "table" and record.segments or {}
        local lastSegment = record.segments[#record.segments]
        local gapLimit = math.max(1000, tonumber(D.Const.NAME_BINDING_SEGMENT_GAP_MS) or 8000)
        local lastTo = U.FiniteNumber(lastSegment and lastSegment.to, nil)
        if lastSegment ~= nil and lastTo ~= nil and now - lastTo <= gapLimit then
            lastSegment.to = math.max(lastTo, now)
        else
            materialChanged = true
            record.segments[#record.segments + 1] = { from = now, to = now }
        end
        local segmentLimit = math.max(4, tonumber(D.Const.MAX_NAME_BINDING_SEGMENTS) or 12)
        while #record.segments > segmentLimit do table.remove(record.segments, 1) end
    end
    if kind == "PLAYER" or kind == "NPC" or kind == "MATE" or kind == "SLAVE" or kind == "OTHER" then
        if record.kind ~= kind then materialChanged = true end
        record.kind = kind
        -- Identity observation source and kind evidence source are different
        -- Authorities. A later target/name refresh may update `source` without
        -- being allowed to inherit or rewrite an older type claim.
        record.kindSource = tostring(kindSource or source or "unit_api")
    end
    bucket.updatedAt = math.max(U.FiniteNumber(bucket.updatedAt, now) or now, now)

    local retention = math.max(30000, tonumber(D.Const.NAME_BINDING_RETENTION_MS) or 180000)
    local records = {}
    for id, item in pairs(bucket.byId) do
        local lastSeen = U.FiniteNumber(item and item.lastSeenAt, 0) or 0
        if now - lastSeen <= retention then
            records[#records + 1] = item
        else
            bucket.byId[id] = nil
            materialChanged = true
        end
    end
    table.sort(records, function(a, b)
        return (tonumber(a.lastSeenAt) or 0) > (tonumber(b.lastSeenAt) or 0)
    end)
    local limit = math.max(4, tonumber(D.Const.MAX_NAME_BINDINGS_PER_NAME) or 16)
    for index = limit + 1, #records do
        bucket.byId[tostring(records[index].stringId)] = nil
        materialChanged = true
    end
    if next(bucket.byId) == nil then self.nameBindings[normalized] = nil end
    if materialChanged and deferReclassify ~= true then D.RequestPendingReclassify() end
    return record, materialChanged
end

function E:ResolveNameBinding(name, timestamp)
    local normalized = U.NormalizeName(name)
    if normalized == "" then return nil, nil, "NO_NAME" end
    local bucket = self.nameBindings and self.nameBindings[normalized] or nil
    if type(bucket) ~= "table" or type(bucket.byId) ~= "table" then return nil, nil, "NO_BINDING" end

    local at = U.TimestampOrNow(timestamp)
    local pastWindow = math.max(0, tonumber(D.Const.NAME_BINDING_PAST_MS) or 15000)
    local futureWindow = math.max(0, tonumber(D.Const.NAME_BINDING_FUTURE_MS) or 5000)
    local candidates = {}
    for _, record in pairs(bucket.byId) do
        local matched = false
        local segments = type(record and record.segments) == "table" and record.segments or nil
        if segments ~= nil and #segments > 0 then
            for _, segment in ipairs(segments) do
                local from = U.FiniteNumber(segment and segment.from, nil)
                local to = U.FiniteNumber(segment and segment.to, nil)
                if from ~= nil and to ~= nil and at >= from - futureWindow and at <= to + pastWindow then
                    matched = true
                    break
                end
            end
        else
            local firstSeen = U.FiniteNumber(record and record.firstSeenAt, nil)
            local lastSeen = U.FiniteNumber(record and record.lastSeenAt, nil)
            matched = firstSeen ~= nil and lastSeen ~= nil
                and at >= firstSeen - futureWindow and at <= lastSeen + pastWindow
        end
        if matched then
            candidates[#candidates + 1] = record
        end
    end
    if #candidates == 1 then
        local only = candidates[1]
        return tostring(only.stringId), only.kind, "UNIQUE_TIME_BINDING"
    end
    if #candidates > 1 then return nil, nil, "AMBIGUOUS_TIME_BINDING" end
    return nil, nil, "NO_TIME_BINDING"
end

-- Resolve a current official roster alias without promoting it into the broad
-- byName Authority. UnitName and UnitNameWithWorld can expose different spellings
-- for the same party member, especially in cross-world instances. The roster
-- builder publishes an alias only when exactly one current roster entity owns it.
-- A collision is omitted from the map, so a short name shared by two worlds stays
-- unresolved rather than being assigned to an arbitrary player.
function E:ResolveTeamNameAlias(name, timestamp)
    local normalized = U.NormalizeName(name)
    if normalized == "" then return nil end
    local key = type(self.teamNameAliases) == "table" and self.teamNameAliases[normalized] or nil
    if type(key) ~= "string" or key == "" then return nil end
    local entity = self:GetByKey(key) or self.byKey[key]
    if type(entity) ~= "table" then return nil end

    -- teamNameAliases itself is published only from the current official roster
    -- and removes collisions before publication. Identity alias ownership must
    -- therefore not depend on the entity's *effective relation*: manually
    -- changing TEAM to FRIENDLY/OPPONENT is a classification decision, not proof
    -- that Name and Name@World stopped being the same roster unit. Coupling these
    -- layers made cross-world history/projection correction disappear immediately
    -- after the very manual relation edit that needed the alias.
    return entity
end

-- Resolve only the unit kind for a combat-log name at an event timestamp. This
-- deliberately does not choose a concrete ID. Multiple same-name players are
-- still safely PLAYER; a player/NPC name collision remains UNKNOWN. The source
-- data comes exclusively from official team/target/sight observations recorded
-- by RecordNameBinding.
function E:ResolveNameKind(name, timestamp)
    local normalized = U.NormalizeName(name)
    if normalized == "" then return nil, "NO_NAME" end
    local at = U.TimestampOrNow(timestamp)

    local mappedKey = self.byName and self.byName[normalized] or nil
    local mapped = mappedKey ~= nil and self:GetByKey(mappedKey) or nil
    if mapped ~= nil and self.nameConflicts[normalized] ~= true then
        local relationAt = self:GetRelationAt(mapped, at)
        if relationAt == "SELF" or relationAt == "TEAM" then
            return "PLAYER", "OFFICIAL_TEAM_KIND"
        end
    end
    local rosterAliasEntity = self:ResolveTeamNameAlias(name, at)
    if rosterAliasEntity ~= nil then
        return "PLAYER", "OFFICIAL_TEAM_ALIAS_KIND"
    end
    local teamNameEntity = self.byKey and self.byKey["teamname:" .. normalized] or nil
    if teamNameEntity ~= nil and self.nameConflicts[normalized] ~= true
        and self:GetRelationAt(teamNameEntity, at) == "TEAM" then
        return "PLAYER", "OFFICIAL_TEAM_NAME_KIND"
    end

    local bucket = self.nameBindings and self.nameBindings[normalized] or nil
    if type(bucket) ~= "table" or type(bucket.byId) ~= "table" then return nil, "NO_KIND_BINDING" end
    local pastWindow = math.max(0, tonumber(D.Const.NAME_KIND_PAST_MS) or 30000)
    local futureWindow = math.max(0, tonumber(D.Const.NAME_KIND_FUTURE_MS) or 15000)
    local kinds = {}
    local matched = 0
    local unknownMatched = 0
    for _, record in pairs(bucket.byId) do
        local overlaps = false
        local segments = type(record and record.segments) == "table" and record.segments or nil
        if segments ~= nil and #segments > 0 then
            for _, segment in ipairs(segments) do
                local from = U.FiniteNumber(segment and segment.from, nil)
                local to = U.FiniteNumber(segment and segment.to, nil)
                if from ~= nil and to ~= nil and at >= from - futureWindow and at <= to + pastWindow then
                    overlaps = true
                    break
                end
            end
        else
            local firstSeen = U.FiniteNumber(record and record.firstSeenAt, nil)
            local lastSeen = U.FiniteNumber(record and record.lastSeenAt, nil)
            overlaps = firstSeen ~= nil and lastSeen ~= nil
                and at >= firstSeen - futureWindow and at <= lastSeen + pastWindow
        end
        local kind = record and record.kind or nil
        if overlaps then
            matched = matched + 1
            if kind == "PLAYER" or kind == "NPC" or kind == "MATE"
                or kind == "SLAVE" or kind == "OTHER" then
                kinds[kind] = true
            else
                unknownMatched = unknownMatched + 1
            end
        end
    end
    local only = nil
    local kindCount = 0
    for kind in pairs(kinds) do
        only = kind
        kindCount = kindCount + 1
    end
    if kindCount == 1 and unknownMatched == 0 then
        return only, matched > 1 and "MULTI_ID_SAME_KIND" or "UNIQUE_OBSERVED_KIND"
    end
    if kindCount > 1 then return nil, "CONFLICTING_OBSERVED_KINDS" end
    if unknownMatched > 0 then return nil, "INCOMPLETE_OBSERVED_KINDS" end
    return nil, "NO_TIME_KIND"
end

-- Return a dedicated entity for combat-log rows that expose only a visible
-- name. It is intentionally separate from byName aliases and concrete id:*
-- entities: seeing one unique unit with that name later does not prove that an
-- older name-only event belonged to it. A later official observation whose
-- time window overlaps the event can still move the event to a stable ID during
-- replay.
local function ScheduleRuleEntityReclassify(entity, reason)
    local runtime = D.Runtime
    if type(entity) ~= "table" or type(runtime) ~= "table"
        or runtime.started ~= true then
        return false
    end
    local replayEntity = entity
    if type(E.SyncPlayerHistoryCorrectionsByName) == "function" then
        local mirrorChanged, mirrorEntity = E:SyncPlayerHistoryCorrectionsByName(entity.name)
        if mirrorChanged == true and type(mirrorEntity) == "table" then
            replayEntity = mirrorEntity
        end
    end
    local affected = {
        key = replayEntity.key,
        name = replayEntity.name,
        boundId = replayEntity.stringId,
    }
    if runtime.replaying == true or runtime.replayJob ~= nil then
        -- A stable ID/rule can become available while the current replay has
        -- already passed older name-only events.  Suppressing the request here
        -- makes the just-committed projection stale until another unrelated
        -- correction occurs. Queue one follow-up replay instead of cancelling
        -- the current transaction from inside its own event loop.
        runtime:RequestReclassify(false,
            reason or "PERSISTENT_RULE_ENTITY_MATCH_DURING_REPLAY", affected)
        return true
    end
    D.RequestReclassify(true, reason or "PERSISTENT_RULE_ENTITY_MATCH", affected)
    return true
end

function E:GetHistoricalNameEntity(name, seenAt)
    local cleanName = U.SafeName(name, "未知")
    local normalized = U.NormalizeName(cleanName)
    local key = "history:" .. normalized
    local entity = self.byKey[key]
    if entity == nil then
        entity = NewEntity(key, cleanName)
        entity.flags.historicalNameAggregate = true
        entity.flags.identityQuality = "NAME_ONLY_HISTORY"
        self.byKey[key] = entity
    end
    entity.name = cleanName
    entity.normalizedName = normalized
    entity.lastSeenAt = U.TimestampOrNow(seenAt)
    entity.flags = entity.flags or {}
    entity.flags.historicalNameAggregate = true
    entity.flags.identityQuality = "NAME_ONLY_HISTORY"
    if self.nameConflicts[normalized] == true then entity.flags.nameConflict = true end
    local ruleChanged = false
    if D.Rules ~= nil and D.Rules.ApplyToEntity ~= nil then
        ruleChanged = D.Rules:ApplyToEntity(entity, false) == true
    end
    if entity.manualOverride ~= nil then self:Resolve(entity) end
    if ruleChanged then
        ScheduleRuleEntityReclassify(entity, "PERSISTENT_RULE_HISTORY_MATCH")
    end
    return entity
end

-- A roster slot can expose a reliable team name even when the client does not
-- expose a stable ID. Keep that evidence in a dedicated entity so a later sight
-- ID with the same name cannot silently inherit the entire team history.
function E:GetTeamNameEntity(name, seenAt)
    local cleanName = U.SafeName(name, "未知")
    local normalized = U.NormalizeName(cleanName)
    local key = "teamname:" .. normalized
    local entity = self.byKey[key]
    if entity == nil then
        entity = NewEntity(key, cleanName)
        entity.flags.nameOnlyTeam = true
        self.byKey[key] = entity
    end
    entity.name = cleanName
    entity.normalizedName = normalized
    entity.lastSeenAt = U.TimestampOrNow(seenAt)
    entity.flags = entity.flags or {}
    entity.flags.nameOnlyTeam = true
    return entity
end

function E:ResolveEventEntity(name, eventKey, timestamp, storedBoundId, lockedAmbiguous, keyAuthoritative)
    local cleanName = U.SafeName(name, "未知")
    local keyText = tostring(eventKey or "")
    local normalized = U.NormalizeName(cleanName)

    -- COMBAT_MSG exposes names but no documented stable source/target ID. An
    -- id:* key stored by an older replay is therefore advisory unless the caller
    -- explicitly marks it authoritative. This prevents a former unique name
    -- alias from permanently pinning history to the wrong same-name unit.
    if keyAuthoritative == true then
        local explicitId = string.match(keyText, "^id:(.+)$")
        if explicitId ~= nil then
            return self:GetOrCreate(cleanName, explicitId, timestamp), "EVENT_ID", explicitId
        end
    end

    -- The local player is the one name-only identity that is always
    -- authoritative. A team member without an exposed stable ID is also safe
    -- while the official roster relation interval covers the event timestamp.
    local nameMappedKey = normalized ~= "" and self.byName[normalized] or nil
    local nameMapped = nameMappedKey ~= nil and self:GetByKey(nameMappedKey) or nil
    if nameMapped ~= nil and self.nameConflicts[normalized] ~= true then
        local relationAt = self:GetRelationAt(nameMapped, timestamp)
        if relationAt == "SELF" then return nameMapped, "SELF_NAME", nameMapped.stringId end
        -- v0.2.20 promoted official teamname:* rows to stable id:* rows, but the
        -- event resolver only followed SELF here. After promotion, a team member
        -- could therefore stop being friendly whenever the short ID-binding
        -- window missed, which dropped most heals and all dependent PVP rows.
        -- The official TEAM relation interval is itself authoritative.
        if relationAt == "TEAM" then return nameMapped, "TEAM_STABLE_NAME", nameMapped.stringId end
        if type(nameMapped.manualOverride) == "table"
            and nameMapped.manualOverride.relation ~= nil then
            return nameMapped, "MANUAL_UNIQUE_NAME", nameMapped.stringId
        end
    end
    local rosterAliasEntity = self:ResolveTeamNameAlias(cleanName, timestamp)
    if rosterAliasEntity ~= nil then
        return rosterAliasEntity, "TEAM_ROSTER_ALIAS", rosterAliasEntity.stringId
    end
    local teamNameEntity = self.byKey["teamname:" .. normalized]
    if teamNameEntity ~= nil and self.nameConflicts[normalized] ~= true
        and self:GetRelationAt(teamNameEntity, timestamp) == "TEAM" then
        return teamNameEntity, "TEAM_NAME", nil
    end

    -- A user can open a name-history ranking row and correct it directly even
    -- when a short-lived unit ID is also known. The old resolver consulted the
    -- temporal ID binding first, so replay silently moved the event away from
    -- the corrected history:* entity and kept the old enemy projection. A direct
    -- manual/rule decision on the unambiguous history aggregate owns name-only
    -- combat facts and must be checked before advisory ID binding. Exact SELF and
    -- official TEAM paths above remain stronger. Known same-name conflicts stay
    -- fail-closed and continue to require a concrete-ID correction.
    local historyEntity = self.byKey["history:" .. normalized]
    local historyOverride = type(historyEntity) == "table"
        and type(historyEntity.manualOverride) == "table"
        and historyEntity.manualOverride or nil
    local historyHasDecision = historyOverride ~= nil
        and (historyOverride.kind ~= nil or historyOverride.relation ~= nil
            or historyOverride.ignored == true)
    local historyHasDirectDecision = historyOverride ~= nil and (
        (historyOverride.kind ~= nil and historyOverride.mirroredKind ~= true)
        or (historyOverride.relation ~= nil and historyOverride.mirroredRelation ~= true)
        or historyOverride.ignored == true)
    if historyHasDecision and (self.nameConflicts[normalized] ~= true
        or historyHasDirectDecision) then
        -- A direct edit of the history:* row is an explicit adjudication of the
        -- ambiguous name-only facts themselves, so it remains authoritative even
        -- when several concrete IDs share the name. Only a synthetic mirror from
        -- one exact ID is blocked by a known conflict.
        return historyEntity,
            historyHasDirectDecision and "MANUAL_HISTORY_DIRECT_SCOPE"
                or "MANUAL_HISTORY_NAME_SCOPE",
            historyEntity.stringId
    end

    if lockedAmbiguous == true then
        return self:GetHistoricalNameEntity(cleanName, timestamp), "LOCKED_AMBIGUOUS_BINDING", nil
    end

    local rememberedId = storedBoundId ~= nil and tostring(storedBoundId) ~= "" and tostring(storedBoundId) or nil
    local boundId, _, quality = self:ResolveNameBinding(cleanName, timestamp)
    if boundId ~= nil then
        -- If a compacted/old event remembers a different unit that was uniquely
        -- observed at the same time, pruning one side of a crowded same-name
        -- cache must not silently transfer the history to the survivor.
        if rememberedId ~= nil and tostring(boundId) ~= rememberedId then
            return self:GetHistoricalNameEntity(cleanName, timestamp), "AMBIGUOUS_TIME_BINDING", nil
        end
        return self:GetOrCreate(cleanName, boundId, timestamp), quality, boundId
    end
    if quality == "AMBIGUOUS_TIME_BINDING" then
        return self:GetHistoricalNameEntity(cleanName, timestamp), quality, nil
    end

    -- A unique binding captured at event time remains useful after the bounded
    -- live observation cache expires. It is used only when no newer observation
    -- now proves ambiguity at that same timestamp.
    if rememberedId ~= nil then
        return self:GetOrCreate(cleanName, rememberedId, timestamp), "STORED_TIME_BINDING", rememberedId
    end

    -- Do not follow a broad name:* alias to a concrete ID here. Such an alias is
    -- useful for current UI/entity lookup, but it is not temporal evidence that
    -- an old combat-log row belonged to the currently visible unit.
    return self:GetHistoricalNameEntity(cleanName, timestamp), quality or "NO_TIME_BINDING", nil
end

function E:GetOrCreate(name, stringId, seenAt)
    self.nameConflicts = self.nameConflicts or {}
    local newNameConflict = false
    local cleanName = U.SafeName(name, "未知")
    local normalized = U.NormalizeName(cleanName)
    local stableId = stringId ~= nil and tostring(stringId) ~= "" and tostring(stringId) or nil
    local conflictedName = normalized ~= "" and self.nameConflicts[normalized] == true
    local key
    if stableId ~= nil then key = "id:" .. stableId
    elseif conflictedName then key = "ambiguous:" .. normalized
    else key = "name:" .. normalized end
    local alias = self.aliases[key]
    if alias ~= nil then key = alias end

    local entity = self.byKey[key]
    local nameMappedKey = not conflictedName and normalized ~= "" and self.byName[normalized] or nil
    local nameMapped = nameMappedKey ~= nil and self.byKey[nameMappedKey] or nil

    if entity == nil and nameMapped ~= nil then
        if stableId ~= nil and nameMapped.stringId ~= nil and tostring(nameMapped.stringId) ~= stableId then
            self.nameConflicts[normalized] = true
            newNameConflict = true
            nameMapped.flags.nameConflict = true
            -- A former unique name may have been upgraded to the first stable
            -- ID through aliases["name:..."] = "id:...". Once another stable
            -- ID with the same name appears, name-only combat events are no
            -- longer attributable to either concrete unit. Remove that alias so
            -- replay resolves them through the explicit ambiguous name entity.
            self.aliases["name:" .. normalized] = nil
            self.aliases["ambiguous:" .. normalized] = nil
            -- A previously applied broad name rule may become unsafe the moment
            -- a second stable unit with another kind appears. Re-evaluate the
            -- original entity immediately instead of waiting for a later scan.
            if D.Rules ~= nil and D.Rules.ApplyToEntity ~= nil then
                local changed = D.Rules:ApplyToEntity(nameMapped, true)
                if changed then
                    D.MarkViewDirty()
                    D.RequestReclassify(true, "NAME_CONFLICT")
                end
            end
            entity = NewEntity("id:" .. stableId, cleanName)
            entity.stringId = stableId
            entity.flags.nameConflict = true
            self.byKey[entity.key] = entity
            self.byName[normalized] = nil
            conflictedName = true
        else
            entity = nameMapped
        end
    end

    if entity == nil then
        entity = NewEntity(key, cleanName)
        if conflictedName then entity.flags.nameConflict = true end
        self.byKey[key] = entity
    end
    entity.lastSeenAt = U.TimestampOrNow(seenAt)
    if cleanName ~= "未知" then
        entity.name = cleanName
        entity.normalizedName = normalized
        if self.nameConflicts[normalized] == true then entity.flags.nameConflict = true end
        if entity.flags.nameConflict ~= true and self.nameConflicts[normalized] ~= true then
            self.byName[normalized] = entity.key
        end
    end
    if stableId ~= nil then
        entity.stringId = stableId
        local stableKey = "id:" .. stableId
        if entity.key ~= stableKey and self.byKey[stableKey] == nil then
            local oldKey = entity.key
            self.byKey[stableKey] = entity
            self.aliases[oldKey] = stableKey
            self.byKey[oldKey] = nil
            entity.key = stableKey
            if D.Identity ~= nil and D.Identity.entityKey == oldKey then D.Identity.entityKey = stableKey end
            if self.roster[oldKey] ~= nil then self.roster[stableKey] = self.roster[oldKey] self.roster[oldKey] = nil end
            if self.teamMissingSince[oldKey] ~= nil then self.teamMissingSince[stableKey] = self.teamMissingSince[oldKey] self.teamMissingSince[oldKey] = nil end
            if D.Stats ~= nil and D.Stats.MergeActorKey ~= nil then D.Stats:MergeActorKey(oldKey, stableKey, entity.name) end
            if normalized ~= "" and entity.flags.nameConflict ~= true and self.nameConflicts[normalized] ~= true then self.byName[normalized] = stableKey end
        end
    end
    local ruleChanged = false
    if D.Rules ~= nil and D.Rules.ApplyToEntity ~= nil then
        ruleChanged = D.Rules:ApplyToEntity(entity, false) == true
    end
    if entity.manualOverride ~= nil then self:Resolve(entity) end
    if ruleChanged then
        ScheduleRuleEntityReclassify(entity, "PERSISTENT_RULE_ENTITY_MATCH")
    end
    if newNameConflict and type(self.SyncPlayerHistoryCorrectionsByName) == "function" then
        local mirrorChanged, mirrorEntity = self:SyncPlayerHistoryCorrectionsByName(cleanName)
        if mirrorChanged == true then
            D.MarkViewDirty()
            D.RequestReclassify(true, "NAME_CONFLICT_HISTORY_MIRROR", {
                key = mirrorEntity and mirrorEntity.key or entity.key,
                name = cleanName,
                boundId = entity.stringId,
            })
        end
    end
    return entity
end


-- Promote an official name-only team roster identity to a validated stable ID.
--
-- Why this exists:
-- Some client builds temporarily expose a team slot name before GetUnitId starts
-- returning a value. Combat events recorded during that window are stored under
-- teamname:<name>. When the same official roster entry later exposes a validated
-- ID, leaving both keys alive creates two ranking rows for the same player.
--
-- Accuracy rules:
-- * promotion is allowed only for a current official team observation;
-- * GetUnitNameById validation is performed by the Runtime caller first;
-- * a known same-name conflict or more than one observed stable ID blocks it;
-- * only the dedicated teamname:* aggregate is promoted. Generic history:* rows
--   remain separate because COMBAT_MSG does not expose authoritative IDs.
local function StatsRootHasActorKey(statsRoot, actorKey)
    if type(statsRoot) ~= "table" then return false end
    for _, modeName in ipairs({ "PVP", "PVE" }) do
        local modeStats = statsRoot[modeName]
        if type(modeStats) == "table" then
            for _, sideName in ipairs({ "friendly", "enemy" }) do
                local side = modeStats[sideName]
                if type(side) == "table" and type(side.actors) == "table"
                    and side.actors[actorKey] ~= nil then
                    return true
                end
            end
        end
    end
    return false
end

local function OverlayOfficialRelationInterval(entity, relation, validFrom, reason)
    if type(entity) ~= "table" then return end
    local from = math.max(0, U.TimestampOrNow(validFrom))
    local kept = {}
    for _, interval in ipairs(type(entity.relationHistory) == "table" and entity.relationHistory or {}) do
        if type(interval) == "table" then
            local intervalFrom = math.max(0, U.FiniteNumber(interval.validFrom, 0) or 0)
            local intervalTo = interval.validTo ~= nil and U.FiniteNumber(interval.validTo, nil) or nil
            if intervalTo ~= nil and intervalTo <= from then
                kept[#kept + 1] = U.DeepCopy(interval)
            elseif intervalFrom < from then
                local left = U.DeepCopy(interval)
                left.validTo = from
                kept[#kept + 1] = left
            end
        end
    end
    relation = relation == "SELF" and "SELF" or "TEAM"
    kept[#kept + 1] = {
        relation = relation,
        validFrom = from,
        validTo = nil,
        reason = reason or "team_name_promoted",
    }
    table.sort(kept, function(a, b)
        return (tonumber(a.validFrom) or 0) < (tonumber(b.validFrom) or 0)
    end)
    entity.relationHistory = kept
    -- v0.2.25（问题 12）：sort 后按 validFrom 升序，缓存有序标志。
    entity.repdpsRelationHistorySorted = true
    entity.hardRelation = relation
    entity.historyRelation = relation
    entity.relationSince = from
    if not (type(entity.manualOverride) == "table" and entity.manualOverride.relation ~= nil) then
        entity.relation = relation
        entity.flags = entity.flags or {}
        entity.flags.relationReason = reason or "team_name_promoted"
    end
end

local function RewritePromotedEventEndpoint(event, prefix, oldKey, oldEntity, stableEntity, stableId)
    if type(event) ~= "table" then return false end
    local keyField = prefix .. "Key"
    local resolvedField = prefix .. "ResolvedKey"
    local entityField = prefix .. "Entity"
    local rawEntityField = prefix == "source" and "rawSourceEntity" or nil
    local matches = tostring(event[keyField] or "") == oldKey
        or tostring(event[resolvedField] or "") == oldKey
        or event[entityField] == oldEntity
        or (rawEntityField ~= nil and event[rawEntityField] == oldEntity)
    if not matches then return false end

    event[keyField] = stableEntity.key
    local classifications = D.EventClassifications
    if type(classifications) == "table" and type(classifications.SetMany) == "function" then
        classifications:SetMany(event, "IDENTITY_PROMOTION",
            resolvedField, stableEntity.key,
            prefix .. "BoundId", stableId,
            prefix .. "BindingQuality", "OFFICIAL_TEAM_SLOT_PROMOTION",
            prefix .. "BindingAmbiguous", false,
            prefix .. "KeyAuthoritative", true)
    else
        -- Bootstrap-only fallback. The production runtime always loads the
        -- sidecar before any roster promotion can execute.
        event[resolvedField] = stableEntity.key
        event[prefix .. "BoundId"] = stableId
        event[prefix .. "BindingQuality"] = "OFFICIAL_TEAM_SLOT_PROMOTION"
        event[prefix .. "BindingAmbiguous"] = false
        event[prefix .. "KeyAuthoritative"] = true
    end
    event[entityField] = stableEntity
    if rawEntityField ~= nil then event[rawEntityField] = stableEntity end
    return true
end

function E:PromoteTeamNameToStableId(name, stringId, rosterToken, seenAt)
    local cleanName = U.SafeName(name, "未知")
    local normalized = U.NormalizeName(cleanName)
    local stableId = stringId ~= nil and tostring(stringId) ~= "" and tostring(stringId) or nil
    if normalized == "" or stableId == nil then return self:GetOrCreate(cleanName, stableId), false end

    local stableEntity = self:GetOrCreate(cleanName, stableId)
    local stableKey = stableEntity.key
    local oldKey = "teamname:" .. normalized
    if oldKey == stableKey or self.nameConflicts[normalized] == true then return stableEntity, false end

    -- A second stable ID with the same normalized name makes historical name-only
    -- attribution unsafe. Keep the rows separate until the user resolves it.
    local bindingBucket = self.nameBindings and self.nameBindings[normalized] or nil
    local distinctIds = 0
    if type(bindingBucket) == "table" and type(bindingBucket.byId) == "table" then
        for observedId in pairs(bindingBucket.byId) do
            if tostring(observedId) ~= "" then distinctIds = distinctIds + 1 end
        end
    end
    if distinctIds > 1 then return stableEntity, false end

    local oldEntity = self.byKey[oldKey]
    local oldRoster = self.roster and self.roster[oldKey] or nil
    local hasPersistedStats = StatsRootHasActorKey(D.State and D.State.stats, oldKey)
        or StatsRootHasActorKey(D.EventStore and D.EventStore.baselineStats, oldKey)
    if oldEntity == nil and oldRoster == nil and not hasPersistedStats then return stableEntity, false end
    if oldEntity ~= nil and oldEntity.flags ~= nil and oldEntity.flags.nameConflict == true then
        return stableEntity, false
    end
    if oldRoster ~= nil and U.NormalizeName(oldRoster.name) ~= normalized then
        return stableEntity, false
    end

    local now = U.TimestampOrNow(seenAt)
    local earliest = now
    if oldEntity ~= nil then
        earliest = math.min(earliest, U.FiniteNumber(oldEntity.firstSeenAt, earliest) or earliest)
        for _, interval in ipairs(type(oldEntity.relationHistory) == "table" and oldEntity.relationHistory or {}) do
            if type(interval) == "table" and interval.relation == "TEAM" then
                earliest = math.min(earliest, U.FiniteNumber(interval.validFrom, earliest) or earliest)
            end
        end
        stableEntity.firstSeenAt = math.min(
            U.FiniteNumber(stableEntity.firstSeenAt, earliest) or earliest,
            earliest
        )
        stableEntity.lastSeenAt = math.max(
            U.FiniteNumber(stableEntity.lastSeenAt, now) or now,
            U.FiniteNumber(oldEntity.lastSeenAt, now) or now,
            now
        )
        local selfIdentity = D.Identity ~= nil and (stableEntity.key == D.Identity.entityKey
            or stableEntity.hardRelation == "SELF"
            or normalized == U.NormalizeName(D.Identity.playerName)
            or normalized == U.NormalizeName(D.Identity.playerNameWithWorld))
        if not selfIdentity and stableEntity.manualOverride == nil and oldEntity.manualOverride ~= nil then
            stableEntity.manualOverride = U.DeepCopy(oldEntity.manualOverride)
        end
    elseif oldRoster ~= nil then
        earliest = math.min(earliest, U.FiniteNumber(oldRoster.seenAt, earliest) or earliest)
    end

    -- Backfill the validated binding to the interval in which the same official
    -- team roster identity was already visible by name. This keeps a later full
    -- replay from recreating the duplicate teamname:* row.
    if type(bindingBucket) == "table" and type(bindingBucket.byId) == "table" then
        local record = bindingBucket.byId[stableId]
        if type(record) == "table" then
            record.firstSeenAt = math.min(U.FiniteNumber(record.firstSeenAt, earliest) or earliest, earliest)
            record.lastSeenAt = math.max(U.FiniteNumber(record.lastSeenAt, now) or now, now)
            record.segments = type(record.segments) == "table" and record.segments or {}
            if #record.segments == 0 then
                record.segments[1] = { from = earliest, to = now }
            else
                local first = record.segments[1]
                first.from = math.min(U.FiniteNumber(first.from, earliest) or earliest, earliest)
                first.to = math.max(U.FiniteNumber(first.to, now) or now, now)
            end
            record.source = "team_slot_promoted"
            record.kind = "PLAYER"
        end
    end

    local isSelfIdentity = D.Identity ~= nil and (stableEntity.key == D.Identity.entityKey
        or stableEntity.hardRelation == "SELF"
        or normalized == U.NormalizeName(D.Identity.playerName)
        or normalized == U.NormalizeName(D.Identity.playerNameWithWorld))
    local promotedRelation = isSelfIdentity and "SELF" or "TEAM"
    OverlayOfficialRelationInterval(stableEntity, promotedRelation, earliest,
        isSelfIdentity and "self_team_slot_promoted" or "team_slot_promoted")
    stableEntity.hardKind = "PLAYER"
    stableEntity.flags = stableEntity.flags or {}
    stableEntity.flags.kindProvisional = nil
    stableEntity.flags.kindEvidenceRank = 100
    stableEntity.flags.hardKindReason = isSelfIdentity and "self_team_slot_promoted" or "team_slot_promoted"
    stableEntity.flags.kindReason = stableEntity.flags.hardKindReason
    if not (type(stableEntity.manualOverride) == "table" and stableEntity.manualOverride.kind ~= nil) then
        stableEntity.kind = "PLAYER"
        stableEntity.flags = stableEntity.flags or {}
        stableEntity.flags.kindReason = "team_slot_promoted"
    end

    if D.Stats ~= nil and D.Stats.MergeActorKey ~= nil then
        D.Stats:MergeActorKey(oldKey, stableKey, cleanName)
    end

    self.aliases[oldKey] = stableKey
    self.byKey[oldKey] = nil
    if normalized ~= "" and self.nameConflicts[normalized] ~= true then
        self.byName[normalized] = stableKey
    end

    if oldRoster ~= nil then
        self.roster[stableKey] = {
            token = rosterToken or oldRoster.token,
            name = cleanName,
            id = stableId,
            seenAt = now,
        }
        self.roster[oldKey] = nil
    end
    if self.teamMissingSince ~= nil then
        self.teamMissingSince[stableKey] = nil
        self.teamMissingSince[oldKey] = nil
    end

    -- Rewrite only events that had already resolved through the exact official
    -- teamname:* identity. Generic history:* events are intentionally untouched.
    --
    -- v0.2.26：索引只保存尚未升级的 teamname:* 事件序号，且为稠密数组。
    -- 如果热重载后的索引尚未重建完，不再为了本次升级同步扫描整本日志；
    -- aliases[oldKey] 已经指向 stableKey，后续重放仍能正确解析旧事件。
    -- 已完成索引的那部分会立即原地改写，剩余旧键只是可读历史表示，不影响
    -- 当前统计或之后的重放正确性。
    local store = D.EventStore
    local rewritten = 0
    local visited = {}
    local function RewriteEvent(event)
        if type(event) ~= "table" or visited[event] == true then return false end
        visited[event] = true
        local changed = false
        if RewritePromotedEventEndpoint(event, "source", oldKey, oldEntity, stableEntity, stableId) then
            changed = true
        end
        if RewritePromotedEventEndpoint(event, "target", oldKey, oldEntity, stableEntity, stableId) then
            changed = true
        end
        if changed then rewritten = rewritten + 1 end
        return changed
    end

    if type(store) == "table" and type(store.sessionEvents) == "table" then
        local index = store.identityIndex
        local indexedReady = false
        if type(index) == "table" and store.EnsureIdentityIndex ~= nil then
            -- 先补足索引（若热重载后尚未重建）；预算内完成即可用索引路径。
            indexedReady = store:EnsureIdentityIndex(4000, store.identityGeneration)
        end
        -- 无论索引是否已全部完成，都可以安全处理当前已登记的 oldKey 列表。
        -- 稠密数组天然有序、无重复，不再创建 ordered 临时表或 table.sort。
        local eventSlots = type(index) == "table" and index.byKey
            and index.byKey[oldKey] or nil
        if type(eventSlots) == "table" then
            for listIndex = 1, #eventSlots do
                local eventId = eventSlots[listIndex]
                RewriteEvent(store.sessionEvents[eventId])
            end
        end
        if indexedReady ~= true and D.State.config.diagnosticsEnabled == true then
            D.Diagnostics:AddInfo("team_identity_promoted",
                "identity index still rebuilding; alias preserves unrevised history")
        end
        if store.RetargetIdentityIndex ~= nil then
            store:RetargetIdentityIndex(oldKey, stableKey, normalized, stableEntity.normalizedName)
        end
        -- pending / raw 是 sessionEvents 的子集或诊断环，重写同一事件对象
        -- 即可生效，不需要再遍历；但老版本可能留下游离引用，逐一检查
        -- 仍是 O(有界)（pending ≤ 3000、raw ≤ 1200），不会随历史线性增长。
        local function RewriteBoundedList(list)
            for _, event in ipairs(type(list) == "table" and list or {}) do
                RewriteEvent(event)
            end
        end
        RewriteBoundedList(store.pending)
        RewriteBoundedList(store.raw)
        -- v0.2.25（问题 10）：候选窗口已改为环形缓冲，物理数组长度固定，
        -- 不能再用 ipairs 遍历整个槽数组（会扫 2000 个 nil 槽且顺序失真）。
        -- 按逻辑顺序遍历有效条目（从最新到最旧，与死亡匹配一致）。
        do
            local slots = type(store.recentDamageCandidates) == "table" and store.recentDamageCandidates or {}
            local count = math.max(0, math.floor(tonumber(store.recentDamageCount) or 0))
            local cap = D.Const.MAX_RECENT_DAMAGE_CANDIDATES or 2000
            local tail = math.max(1, math.floor(tonumber(store.recentDamageTail) or 1))
            local function RingPrev(index)
                return index <= 1 and cap or index - 1
            end
            local index = RingPrev(tail)
            for _ = 1, count do
                local candidate = slots[index]
                if type(candidate) == "table" then
                    if tostring(candidate.targetKey or "") == oldKey then
                        candidate.targetKey = stableKey
                        candidate.targetId = stableId
                    end
                    RewriteEvent(candidate.event)
                end
                index = RingPrev(index)
            end
        end
    end

    D.State.dirty.reclassify = true
    D.State.dirty.statsSave = true
    D.MarkViewDirty()
    if D.Diagnostics ~= nil and D.Diagnostics.counters ~= nil then
        D.Diagnostics.counters.identityUpgradeEventsRewritten =
            (tonumber(D.Diagnostics.counters.identityUpgradeEventsRewritten) or 0) + rewritten
    end
    if D.State.config.diagnosticsEnabled == true then
        D.Diagnostics:AddInfo(
            "team_identity_promoted",
            string.format("%s: %s -> %s | events=%d", cleanName, oldKey, stableKey, rewritten)
        )
    end
    return stableEntity, true
end

-- Repair duplicate teamname:/id: rows left by a previous hot reload or by a
-- roster slot that exposed its stable ID only after statistics had already been
-- persisted. Only official SELF/TEAM stable identities are eligible.
function E:RepairOfficialTeamNameDuplicates(seenAt)
    local candidates = {}
    for _, entity in pairs(self.byKey or {}) do
        if type(entity) == "table" and entity.stringId ~= nil
            and (entity.hardRelation == "SELF" or entity.hardRelation == "TEAM") then
            candidates[#candidates + 1] = {
                name = entity.name,
                stringId = tostring(entity.stringId),
                token = self.roster and self.roster[entity.key] and self.roster[entity.key].token or nil,
            }
        end
    end
    local changed = false
    for _, item in ipairs(candidates) do
        local _, promoted = self:PromoteTeamNameToStableId(
            item.name, item.stringId, item.token, seenAt or U.NowMs()
        )
        changed = promoted == true or changed
    end
    return changed
end

function E:GetByKey(key)
    if key == nil then return nil end
    local resolved = self.aliases[tostring(key)] or tostring(key)
    return self.byKey[resolved]
end

-- Low-frequency helper used only after a user clicks a target/source detail
-- row. Combat log events expose names but not a reliable per-event unit ID, so
-- the safe behavior is to enumerate the currently known entities sharing that
-- name and let the user choose when more than one stable ID exists. The combat
-- hot path never scans this table.
function E:GetCandidatesByName(name)
    local normalized = U.NormalizeName(name)
    if normalized == "" then return {} end
    local candidates, seen = {}, {}

    -- Combat-log events can remain name-only even when one concrete unit with
    -- that name is currently visible. Keep the historical aggregate as an
    -- explicit candidate whenever it already exists; create it when a confirmed
    -- same-name conflict proves that such an aggregate is required.
    local aggregateKey = "history:" .. normalized
    local aggregate = self.byKey[aggregateKey]
    if aggregate == nil and self.nameConflicts[normalized] == true then
        aggregate = self:GetHistoricalNameEntity(name)
    end
    if aggregate ~= nil then
        aggregate.flags = aggregate.flags or {}
        aggregate.flags.historicalNameAggregate = true
        candidates[#candidates + 1] = aggregate
        seen[aggregate.key] = true
    end
    for key, entity in pairs(self.byKey or {}) do
        if type(entity) == "table" and U.NormalizeName(entity.name) == normalized then
            local canonical = self:GetByKey(key) or entity
            if canonical ~= nil and seen[canonical.key] ~= true then
                seen[canonical.key] = true
                candidates[#candidates + 1] = canonical
            end
        end
    end

    -- Cross-world instances often expose Name@World in the unit API and Name in
    -- COMBAT_MSG. Surface the exact current roster/verified binding candidate in
    -- the low-frequency detail selector without broadening byName. Collision-
    -- checked roster aliases and unique temporal bindings are both fail-closed.
    local rosterAlias = self:ResolveTeamNameAlias(name, U.NowMs())
    if type(rosterAlias) == "table" and seen[rosterAlias.key] ~= true then
        seen[rosterAlias.key] = true
        candidates[#candidates + 1] = rosterAlias
    end
    local boundId = self:ResolveNameBinding(name, U.NowMs())
    if boundId ~= nil then
        local boundEntity = self:GetByKey("id:" .. tostring(boundId))
        if type(boundEntity) == "table" and seen[boundEntity.key] ~= true then
            seen[boundEntity.key] = true
            candidates[#candidates + 1] = boundEntity
        end
    end

    table.sort(candidates, function(a, b)
        local aAggregate = a.flags ~= nil and a.flags.historicalNameAggregate == true
        local bAggregate = b.flags ~= nil and b.flags.historicalNameAggregate == true
        if aAggregate ~= bAggregate then return aAggregate end
        local aStable = a.stringId ~= nil and tostring(a.stringId) ~= ""
        local bStable = b.stringId ~= nil and tostring(b.stringId) ~= ""
        if aStable ~= bStable then return aStable end
        local aSeen = tonumber(a.lastSeenAt) or 0
        local bSeen = tonumber(b.lastSeenAt) or 0
        if aSeen ~= bSeen then return aSeen > bSeen end
        return tostring(a.key) < tostring(b.key)
    end)

    -- A history:* aggregate and a current id:* unit answer different questions,
    -- so both remain selectable. Remove only obsolete synthetic placeholders
    -- that are neither the historical aggregate nor the best available concrete
    -- identity.
    local hasStable = false
    for _, entity in ipairs(candidates) do
        if entity.stringId ~= nil and tostring(entity.stringId) ~= "" then hasStable = true break end
    end
    if #candidates > 1 then
        local filtered = {}
        for _, entity in ipairs(candidates) do
            local keyText = tostring(entity.key or "")
            local isHistory = entity.flags ~= nil and entity.flags.historicalNameAggregate == true
            local obsoletePlaceholder = string.sub(keyText, 1, 5) == "name:"
                or string.sub(keyText, 1, 10) == "ambiguous:"
            if isHistory or not obsoletePlaceholder or not hasStable then
                filtered[#filtered + 1] = entity
            end
        end
        if #filtered > 0 then candidates = filtered end
    end
    return candidates
end

-- Hot reload can carry aliases created by an older build before a same-name
-- conflict was discovered. Remove those unsafe broad aliases immediately so
-- name-only historical events resolve to the explicit ambiguous aggregate.
for normalized, conflicted in pairs(E.nameConflicts or {}) do
    if conflicted == true and tostring(normalized) ~= "" then
        E.aliases["name:" .. tostring(normalized)] = nil
        E.aliases["ambiguous:" .. tostring(normalized)] = nil
        E.byName[tostring(normalized)] = nil
    end
end

-- Older builds allowed combat behavior to infer PLAYER/NPC kinds. Those scores
-- had no reliable producer in the current architecture and are not authoritative.
-- Remove the legacy state while preserving official sight/roster/manual/rule kinds.
for _, entity in pairs(E.byKey or {}) do
    if type(entity) == "table" then
        entity.kindScores = nil
        entity.kindEvidenceKinds = nil
        if entity.inferredKind ~= "PLAYER" then
            entity.inferredKind = nil
            entity.inferredKindReason = nil
            entity.inferredKindAt = nil
        end
        if entity.hardKind == nil
            and not (type(entity.manualOverride) == "table" and entity.manualOverride.kind ~= nil) then
            local fallbackKind = entity.inferredKind or "UNKNOWN"
            if entity.kind ~= fallbackKind then
                entity.kind = fallbackKind
                D.State.dirty.reclassify = true
            end
        end
    end
end

-- Remove hard enemy relations created by older builds from combat behavior.
-- They were not official API facts and could survive a hot reload indefinitely.
local INVALID_COMBAT_HARD_REASONS = {
    nearby_pve_target = true,
    nearby_pve_source = true,
    npc_attacked_friendly = true,
    npc_attacked_by_friendly = true,
}
for _, entity in pairs(E.byKey or {}) do
    if type(entity) == "table" and entity.hardRelation == "OPPONENT"
        and INVALID_COMBAT_HARD_REASONS[tostring(entity.flags and entity.flags.relationReason or "")] then
        entity.hardRelation = nil
        local kept = {}
        for _, interval in ipairs(type(entity.relationHistory) == "table" and entity.relationHistory or {}) do
            if not INVALID_COMBAT_HARD_REASONS[tostring(interval and interval.reason or "")] then
                kept[#kept + 1] = interval
            end
        end
        entity.relationHistory = kept
        -- v0.2.25（问题 12）：过滤可能破坏有序性，置 nil 重新验证。
        entity.repdpsRelationHistorySorted = nil
        entity.relation = "UNKNOWN"
        entity.historyRelation = "UNKNOWN"
        entity.relationSince = nil
        entity.flags.relationReason = "legacy_combat_hard_relation_removed"
        D.State.dirty.reclassify = true
    end
end

-- Remove only relation evidence derived from combat-log inference. Official
-- self/team intervals, manual overrides and persistent rules are preserved. This
-- makes a full replay transactional: if a later same-name observation changes an
-- event's identity, stale hostility/friendliness scores do not remain attached
-- to the previously selected ID.
--
-- v0.2.25（问题 13）：重置完成后从软证据集合移除该实体，防止集合永久增长。
function E:ResetSoftRelationEvidence(entity)
    if type(entity) ~= "table" then return end
    entity.relationScores = { friendly = 0, opponent = 0, neutral = 0 }
    entity.relationEvidenceKinds = {}
    entity.evidenceKinds = {}
    entity.firstRelationEvidenceAt = nil
    entity.lastEvidenceAt = 0
    entity.lastScoreDecayAt = nil
    entity.combatContext = nil
    entity.strongRelation = nil
    entity.strongRelationSince = nil
    entity.strongRelationLastSeenAt = nil
    entity.strongRelationReason = nil

    local preserved = {}
    for _, interval in ipairs(type(entity.relationHistory) == "table" and entity.relationHistory or {}) do
        local reason = type(interval) == "table" and tostring(interval.reason or "") or ""
        if type(interval) == "table" and reason ~= "score_resolve"
            and string.sub(reason, 1, 7) ~= "strong_" then
            preserved[#preserved + 1] = U.DeepCopy(interval)
        end
    end
    entity.relationHistory = preserved
    -- v0.2.25（问题 12）：保留的区间顺序可能与全局有序性不一致
    -- （过滤可能删除中间区间），置 nil 让 GetRelationAt 重新验证。
    entity.repdpsRelationHistorySorted = nil

    local openRelation = "UNKNOWN"
    local openFrom = nil
    for index = #preserved, 1, -1 do
        local interval = preserved[index]
        if interval.validTo == nil then
            openRelation = interval.relation or "UNKNOWN"
            openFrom = interval.validFrom
            break
        end
    end
    entity.historyRelation = openRelation
    entity.relationSince = openFrom

    if entity.manualOverride ~= nil and entity.manualOverride.relation ~= nil then
        entity.relation = entity.manualOverride.relation
        entity.flags.relationReason = "manual_override"
    elseif entity.hardRelation ~= nil then
        entity.relation = entity.hardRelation
        entity.historyRelation = entity.hardRelation
        entity.flags.relationReason = "hard_relation"
    else
        entity.relation = openRelation
        entity.flags.relationReason = openRelation ~= "UNKNOWN" and "preserved_history" or "soft_evidence_reset"
    end
    UnmarkSoftEvidence(entity)
end

-- v0.2.25（问题 13）：只遍历持有软证据的实体，不再扫描全部历史实体。
function E:ResetAllSoftRelationEvidence()
    self.evidenceCooldowns = {}
    -- 集合在遍历时可能被 ResetSoftRelationEvidence 清空（Unmark），
    -- 因此先取出键列表再遍历，避免 next 在修改中的表上行为不确定。
    local keys = {}
    for key in pairs(self.softEvidenceKeys or {}) do keys[#keys + 1] = key end
    for _, key in ipairs(keys) do
        local entity = self.byKey[key]
        if type(entity) == "table" then self:ResetSoftRelationEvidence(entity) end
    end
    self.softEvidenceKeys = {}
    self.transientRelationKeys = {}
    self.conflictKeys = {}
end

-- 分帧版软证据重置（问题 7/13）：重放与清空都可能需要重置大量实体的
-- 软证据；同步遍历全部历史实体会在长期累计后造成单帧峰值。job 结构：
-- { root = softEvidenceKeys 引用, lastKey = 游标, cooldownDone = 是否已清冷却表 }。
function E:BeginResetSoftEvidence()
    return { root = self.softEvidenceKeys, lastKey = nil, cooldownDone = false }
end

function E:StepResetSoftEvidence(job, entityBudget)
    job = type(job) == "table" and job or self:BeginResetSoftEvidence()
    local budget = math.max(1, math.floor(tonumber(entityBudget) or 160))
    local processed = 0
    local root = type(job.root) == "table" and job.root or self.softEvidenceKeys
    -- ResetSoftRelationEvidence 会从集合中 Unmark，导致遍历中的表被修改；
    -- 每次 next 失败时回退到集合当前快照，避免无限循环或跳过条目。
    if job.root ~= self.softEvidenceKeys then
        job.root = self.softEvidenceKeys
        job.lastKey = nil
    end
    while processed < budget do
        local ok, key, entity = pcall(next, root, job.lastKey)
        if not ok then key = nil end
        if key == nil then break end
        job.lastKey = key
        local resolved = self:GetByKey(key) or self.byKey[key]
        if type(resolved) == "table" then
            self:ResetSoftRelationEvidence(resolved)
        else
            -- 键指向已删除的实体：直接从集合清除。
            root[key] = nil
        end
        processed = processed + 1
    end
    if not job.cooldownDone then
        self.evidenceCooldowns = {}
        job.cooldownDone = true
    end
    -- 遍历结束：lastKey 之后的 next 返回 nil 且本帧预算已消耗或恰好耗尽。
    local exhausted = next(root, job.lastKey) == nil
    local done = exhausted and processed <= budget
    return done, processed, job
end

function E:IsIgnored(entity)
    return entity ~= nil and entity.manualOverride ~= nil and entity.manualOverride.ignored == true
end

function E:TransitionRelation(entity, relation, validFrom, reason)
    if entity == nil then return false end
    if relation ~= "UNKNOWN" and relation ~= "SELF" and relation ~= "TEAM"
        and relation ~= "FRIENDLY" and relation ~= "OPPONENT" then
        return false
    end

    local now = U.NowMs()
    local from = tonumber(validFrom) or now
    local history = entity.relationHistory or {}
    entity.relationHistory = history
    local last = history[#history]
    local oldHistoryRelation = entity.historyRelation
    if oldHistoryRelation == nil then
        oldHistoryRelation = last ~= nil and last.validTo == nil and last.relation
            or entity.relation or "UNKNOWN"
    end
    local oldEffectiveRelation = entity.relation
    local historyMutated = false

    -- Relationship intervals are ordered by validFrom and non-overlapping. Live
    -- callbacks normally append monotonically; replay/baseline queues can deliver
    -- an older timestamp and must splice it without changing the present relation.
    local ordered = last == nil or from >= (tonumber(last.validFrom) or 0)
    if ordered then
        local lastFrom = type(last) == "table" and (tonumber(last.validFrom) or 0) or nil
        if type(last) == "table" and lastFrom == from then
            -- One row per boundary. UNKNOWN at the same boundary removes the row
            -- and leaves a gap; another relation replaces it in place.
            if relation == "UNKNOWN" then
                table.remove(history, #history)
                historyMutated = true
            elseif last.relation ~= relation or last.reason ~= reason then
                last.relation = relation
                last.reason = reason
                historyMutated = true
            end
        elseif type(last) == "table" and last.validTo == nil and last.relation == relation then
            -- Same open relation: no structural change.
        else
            if type(last) == "table" and last.validTo == nil then
                last.validTo = math.max(lastFrom or 0, from)
                historyMutated = true
            end
            if relation ~= "UNKNOWN" then
                history[#history + 1] = {
                    relation = relation, validFrom = from, validTo = nil, reason = reason,
                }
                historyMutated = true
            end
        end
    else
        -- Bounded histories are normally only a few rows, so reverse linear
        -- lookup is cheaper and safer than maintaining another mutable index.
        local insertAt = #history
        while insertAt >= 1 do
            local existing = history[insertAt]
            if (tonumber(existing.validFrom) or 0) <= from then break end
            insertAt = insertAt - 1
        end
        local previous = insertAt >= 1 and history[insertAt] or nil
        local following = history[insertAt + 1]
        local previousFrom = type(previous) == "table" and (tonumber(previous.validFrom) or 0) or nil
        local previousTo = type(previous) == "table" and tonumber(previous.validTo) or nil
        local previousCoversFrom = type(previous) == "table"
            and previousFrom <= from and (previousTo == nil or from < previousTo)

        if type(previous) == "table" and previousFrom == from then
            if relation == "UNKNOWN" then
                table.remove(history, insertAt)
                historyMutated = true
            elseif previous.relation ~= relation or previous.reason ~= reason then
                previous.relation = relation
                previous.reason = reason
                historyMutated = true
            end
        elseif previousCoversFrom and previous.relation == relation then
            -- The requested historical instant already has this relation.
        elseif relation == "UNKNOWN" then
            -- Create an explicit unknown gap by ending the covering predecessor.
            if type(previous) == "table" and (previous.validTo == nil or previous.validTo > from) then
                previous.validTo = from
                historyMutated = true
            end
        elseif type(following) == "table" and following.relation == relation then
            -- Merge with the next same-relation interval by extending it backward.
            if type(previous) == "table" and (previous.validTo == nil or previous.validTo > from) then
                previous.validTo = from
            end
            following.validFrom = from
            historyMutated = true
        else
            if type(previous) == "table" and (previous.validTo == nil or previous.validTo > from) then
                previous.validTo = from
            end
            local followingFrom = type(following) == "table"
                and (tonumber(following.validFrom) or from) or nil
            table.insert(history, insertAt + 1, {
                relation = relation,
                validFrom = from,
                validTo = followingFrom,
                reason = reason,
            })
            historyMutated = true
        end

        -- Legacy hot-reload state may already contain overlaps. Repair the small
        -- neighborhood touched by the splice and ensure no non-tail row is open.
        local repairFrom = math.max(1, insertAt - 1)
        local repairTo = math.min(#history - 1, insertAt + 2)
        for index = repairFrom, repairTo do
            local current = history[index]
            local nextRow = history[index + 1]
            if type(current) == "table" and type(nextRow) == "table" then
                local nextFrom = tonumber(nextRow.validFrom) or 0
                if current.validTo == nil or tonumber(current.validTo) > nextFrom then
                    current.validTo = nextFrom
                    historyMutated = true
                end
            end
        end
        entity.flags = entity.flags or {}
        entity.flags.relationHistoryReordered = true
    end

    entity.repdpsRelationHistorySorted = true

    -- Historical insertion must not make a past relation become the entity's
    -- current relation. Derive current state from the latest still-open interval.
    local currentRow = nil
    for index = #history, 1, -1 do
        local row = history[index]
        if type(row) == "table" and row.validTo == nil then
            currentRow = row
            break
        end
    end
    local currentHistoryRelation = currentRow ~= nil and currentRow.relation or "UNKNOWN"
    entity.historyRelation = currentHistoryRelation
    entity.relationSince = currentRow ~= nil and currentRow.validFrom or nil
    entity.flags = entity.flags or {}

    local effectiveRelation = currentHistoryRelation
    if entity.manualOverride ~= nil and entity.manualOverride.relation ~= nil then
        effectiveRelation = entity.manualOverride.relation
        entity.flags.relationReason = "manual_override"
    elseif entity.hardRelation ~= nil then
        effectiveRelation = entity.hardRelation
        entity.flags.relationReason = "hard_relation"
    else
        entity.flags.relationReason = currentRow ~= nil
            and tostring(currentRow.reason or reason or "relation_history")
            or tostring(reason or "relation_unknown")
    end

    local changed = historyMutated
        or oldHistoryRelation ~= currentHistoryRelation
        or oldEffectiveRelation ~= effectiveRelation
    entity.relation = effectiveRelation
    if changed then
        D.State.dirty.reclassify = true
        D.MarkViewDirty()
    end
    return changed
end

local function RelationSide(relation)
    if relation == "SELF" or relation == "TEAM" or relation == "FRIENDLY" then return "FRIENDLY" end
    if relation == "OPPONENT" then return "OPPONENT" end
    return nil
end

-- Apply a deterministic relationship learned from an effective heal or a
-- direct damage event anchored to a known side. This is stronger than score
-- inference but deliberately remains separate from official SELF/TEAM and from
-- manual/persistent rules. A contradictory known relation becomes a conflict
-- for user review instead of silently flipping a friend list entry.
function E:ApplyStrongRelation(entity, relation, reason, timestamp, counterpart, event)
    if type(entity) ~= "table" or (relation ~= "FRIENDLY" and relation ~= "OPPONENT") then return false end
    -- v0.2.25（问题 13）：强关系是派生软证据，写入前登记实体。
    MarkSoftEvidence(entity)
    self.transientRelationKeys[entity.key] = true
    if self:IsIgnored(entity) then return false end
    local at = U.TimestampOrNow(timestamp)
    local desiredSide = RelationSide(relation)
    local currentRelation = self:GetRelationAt(entity, at)
    local currentSide = RelationSide(currentRelation)
    if currentSide ~= nil and currentSide ~= desiredSide then
        if D.RelationConflicts ~= nil then
            D.RelationConflicts:Record("STRONG_RELATION_CONFLICT", entity, counterpart, event,
                tostring(currentRelation) .. " vs " .. tostring(relation) .. " | " .. tostring(reason))
        end
        return false
    end

    -- SELF/TEAM and manual/persistent relations are already stronger than this
    -- inferred edge. Record recency only; never downgrade their exact label to
    -- a generic FRIENDLY relation.
    local manualRelation = entity.manualOverride ~= nil and entity.manualOverride.relation or nil
    if currentRelation == "SELF" or currentRelation == "TEAM" or manualRelation ~= nil then
        entity.flags = entity.flags or {}
        entity.flags.lastStrongRelationEvidenceAt = at
        entity.flags.lastStrongRelationEvidenceReason = tostring(reason or "strong_combat_evidence")
        return false
    end

    local newlyEstablished = entity.strongRelation ~= relation
    if newlyEstablished then
        entity.strongRelation = relation
        entity.strongRelationSince = at
        entity.strongRelationReason = tostring(reason or "strong_combat_evidence")
        if desiredSide == "FRIENDLY" then
            D.Diagnostics.counters.strongFriendlyRelations =
                (tonumber(D.Diagnostics.counters.strongFriendlyRelations) or 0) + 1
        else
            D.Diagnostics.counters.strongOpponentRelations =
                (tonumber(D.Diagnostics.counters.strongOpponentRelations) or 0) + 1
        end
    end
    entity.strongRelationLastSeenAt = at
    entity.flags = entity.flags or {}
    entity.flags.lastStrongRelationEvidenceAt = at
    entity.flags.lastStrongRelationEvidenceReason = tostring(reason or "strong_combat_evidence")
    if newlyEstablished then entity.flags.relationReason = entity.strongRelationReason end

    if currentSide == desiredSide then
        -- Promote a score-derived relation to deterministic evidence without
        -- opening a duplicate relation-history interval.
        return newlyEstablished
    end
    local changed = self:TransitionRelation(entity, relation, at, entity.strongRelationReason)
    if changed then D.RequestPendingReclassify() end
    return changed or newlyEstablished
end

function E:GetRelationAt(entity, timestamp)
    if entity == nil then return "UNKNOWN" end
    if entity.manualOverride ~= nil and entity.manualOverride.relation ~= nil then
        return entity.manualOverride.relation
    end
    local at = tonumber(timestamp) or U.NowMs()
    local history = entity.relationHistory or {}
    local count = #history
    if count == 0 then return "UNKNOWN" end

    -- v0.2.25（问题 12）：二分查找计数（诊断用，不改变结果）。
    if D.State ~= nil and D.State.config ~= nil
        and D.State.config.diagnosticsEnabled == true
        and D.Diagnostics ~= nil and D.Diagnostics.counters ~= nil then
        D.Diagnostics.counters.relationBinaryLookups =
            (tonumber(D.Diagnostics.counters.relationBinaryLookups) or 0) + 1
    end

    -- 当前开放区间快速路径：大多数实时查询落在最后一个区间的有效期内。
    local latest = history[count]
    if type(latest) == "table" and latest.validTo == nil
        and at >= (tonumber(latest.validFrom) or 0) then
        return latest.relation or "UNKNOWN"
    end

    -- v0.2.25（问题 12）：二分查找要求区间按 validFrom 升序且互斥。
    -- 正常运行时 TransitionRelation/OverlayOfficialRelationInterval 保证
    -- 该性质；但历史遗留或人工修改可能产生乱序/重叠。逐实体缓存
    -- "已验证有序"标志：有序才走二分，否则线性倒扫，保证查询结果
    -- 与旧实现完全一致（对照测试覆盖 10 万随机时间点）。
    local sorted = entity.repdpsRelationHistorySorted
    if sorted == nil then
        sorted = true
        local previousTo = 0
        local previousFrom = 0
        for index = 1, count do
            local interval = history[index]
            if type(interval) ~= "table" then sorted = false break end
            local from = tonumber(interval.validFrom) or 0
            local to = interval.validTo ~= nil and tonumber(interval.validTo) or math.huge
            -- 有效区间：validTo 不得早于 validFrom（除非开放）。
            if to ~= math.huge and to < from then sorted = false break end
            -- 二分前提：validFrom 单调非递减（升序）且区间互斥不重叠。
            if index > 1 then
                if from < previousFrom then sorted = false break end
                if from < previousTo then sorted = false break end
            end
            -- 开放区间必须位于末尾（其后不得再有区间）。
            if to == math.huge and index < count then sorted = false break end
            previousTo = to
            previousFrom = from
        end
        entity.repdpsRelationHistorySorted = sorted
    end
    if sorted ~= true then
        -- 乱序/重叠数据：线性倒扫（与 v0.2.24 语义逐项一致）。
        for index = count, 1, -1 do
            local interval = history[index]
            local from = tonumber(interval.validFrom) or 0
            local to = interval.validTo ~= nil and tonumber(interval.validTo) or math.huge
            if at >= from and at < to then return interval.relation end
        end
        return "UNKNOWN"
    end

    -- 二分查找最后一个 validFrom <= at 的区间。
    local low, high = 1, count
    local candidate = 0
    while low <= high do
        local mid = math.floor((low + high) / 2)
        local interval = history[mid]
        if (tonumber(interval.validFrom) or 0) <= at then
            candidate = mid
            low = mid + 1
        else
            high = mid - 1
        end
    end
    for i = candidate, 1, -1 do
        local interval = history[i]
        local from = tonumber(interval.validFrom) or 0
        local to = interval.validTo ~= nil and tonumber(interval.validTo) or math.huge
        if at >= from and at < to then return interval.relation end
    end
    return "UNKNOWN"
end

local function IsExplicitUnitInfoKindSource(reason)
    local text = string.lower(tostring(reason or ""))
    return string.sub(text, -19) == "_explicit_unit_type"
end

local function IsRejectedHardKindSource(reason)
    local text = string.lower(tostring(reason or ""))
    if IsExplicitUnitInfoKindSource(text) then return false end
    return string.find(text, "_official", 1, true) ~= nil
        or (string.find(text, "sight_", 1, true) == 1
            and string.find(text, "_type_", 1, true) ~= nil)
end

local function HardKindEvidenceRank(reason)
    local text = string.lower(tostring(reason or ""))
    if text == "self" or text == "team_slot" or text == "team_slot_promoted"
        or text == "self_team_slot_promoted" or text == "environmental_damage" then
        return 100
    end
    if IsExplicitUnitInfoKindSource(text) then return 90 end
    if string.find(text, "_type_", 1, true) ~= nil then return 90 end
    if string.find(text, "_official", 1, true) ~= nil then return 70 end
    if text == "chinese_name_server_rule" then return 20 end
    return 50
end

function E:SetHardKind(entity, kind, reason)
    if entity == nil then return false end
    entity.flags = entity.flags or {}
    -- Authority-level fail closed: only the dedicated explicit-field parser
    -- may promote GetUnitInfoById data into formal kind evidence. Legacy generic
    -- `_official` parsers and undeclared GetUnitsInSight type rows remain blocked.
    if kind ~= nil and IsRejectedHardKindSource(reason) then
        entity.flags.kindEvidenceConflict = {
            kept = entity.hardKind,
            rejected = kind,
            keptReason = entity.flags.hardKindReason or entity.flags.kindReason,
            rejectedReason = tostring(reason or "unknown"),
        }
        if D.State.config.diagnosticsEnabled then
            D.Diagnostics:AddWarning("hard_kind_untrusted_source",
                tostring(entity.name) .. " rejected " .. tostring(kind)
                .. " from " .. tostring(reason))
        end
        return false
    end
    local incomingRank = HardKindEvidenceRank(reason)
    local currentReason = entity.flags.hardKindReason or entity.flags.kindReason
    local currentRank = tonumber(entity.flags.kindEvidenceRank)
        or (entity.hardKind ~= nil and HardKindEvidenceRank(currentReason) or 0)
    if entity.hardKind == "PLAYER"
        and (entity.hardRelation == "SELF" or entity.hardRelation == "TEAM") then
        currentRank = math.max(currentRank, 100)
    end

    -- Do not let a weaker configured heuristic overwrite stronger SELF/TEAM
    -- identity evidence. Undocumented API sources are rejected above before
    -- they reach this priority comparison.
    if entity.hardKind ~= nil and kind ~= nil and entity.hardKind ~= kind
        and currentRank > incomingRank then
        entity.flags.kindEvidenceConflict = {
            kept = entity.hardKind,
            rejected = kind,
            keptReason = currentReason,
            rejectedReason = tostring(reason or "unknown"),
        }
        if D.State.config.diagnosticsEnabled then
            D.Diagnostics:AddWarning("hard_kind_priority",
                tostring(entity.name) .. " kept " .. tostring(entity.hardKind)
                .. " (" .. tostring(currentReason) .. ") over " .. tostring(kind)
                .. " (" .. tostring(reason) .. ")")
        end
        return false
    end

    if tostring(reason or "") ~= "chinese_name_server_rule" then
        entity.flags.chineseNameNpcApplied = nil
    end
    local hardChanged = entity.hardKind ~= kind
    entity.hardKind = kind
    if kind ~= nil then
        entity.flags.kindProvisional = nil
        if incomingRank >= currentRank or hardChanged then
            entity.flags.kindEvidenceRank = incomingRank
            entity.flags.hardKindReason = reason
            entity.flags.kindReason = reason
        end
    else
        entity.flags.kindEvidenceRank = nil
        entity.flags.hardKindReason = nil
        entity.flags.kindReason = nil
    end
    local effectiveKind = kind or entity.inferredKind or "UNKNOWN"
    if entity.manualOverride ~= nil and entity.manualOverride.kind ~= nil then
        effectiveKind = entity.manualOverride.kind
    end
    local effectiveChanged = entity.kind ~= effectiveKind
    entity.kind = effectiveKind
    if entity.manualOverride ~= nil and entity.manualOverride.kind ~= nil then
        entity.flags.kindReason = "manual_override"
    end
    local changed = hardChanged or effectiveChanged
    if changed and D.State.config.diagnosticsEnabled then
        D.Diagnostics:AddInfo("hard_kind", tostring(entity.name) .. "=" .. tostring(kind) .. " | " .. tostring(reason))
    end
    if hardChanged and D.Rules ~= nil and D.Rules.ApplyToEntity ~= nil
        and ((entity.manualOverride ~= nil and entity.manualOverride.source == "rule")
            or (entity.flags ~= nil and entity.flags.nameConflict == true)) then
        changed = D.Rules:ApplyToEntity(entity, true) or changed
    end
    if changed then
        D.State.dirty.reclassify = true
        D.MarkViewDirty()
    end
    return changed
end

-- Compatibility no-op. Combat patterns cannot prove PLAYER because NPCs also
-- retaliate. Unit type Authority is restricted to SELF/TEAM, explicit user
-- rules and the optional configured Chinese-name NPC rule.
function E:SetInferredKind(_entity, _kind, _reason, _seenAt, _deferReclassify)
    return false
end

-- Apply or revoke the RU-localization Chinese-name NPC heuristic. The
-- heuristic owns only hard kinds whose reason is exactly
-- chinese_name_server_rule; SELF/TEAM and manual PLAYER evidence is never
-- overwritten or cleared by this option.
function E:ApplyChineseNameKind(entity)
    if type(entity) ~= "table" or D.State.config.inferChineseNamesAsNpc ~= true then return false end
    if not U.ContainsChineseCharacter(entity.name) then return false end
    entity.flags = entity.flags or {}
    local manualKind = type(entity.manualOverride) == "table" and entity.manualOverride.kind or nil
    if entity.hardKind == "PLAYER" or manualKind == "PLAYER" then
        entity.flags.chineseNameKindConflict = true
        if D.State.config.diagnosticsEnabled and entity.flags.chineseNameConflictReported ~= true then
            entity.flags.chineseNameConflictReported = true
            D.Diagnostics:AddWarning("chinese_name_kind_conflict",
                tostring(entity.name) .. " authoritative PLAYER conflicts with Chinese-name NPC option")
        end
        return false
    end
    -- Reciprocal-damage PLAYER inference is deliberately weaker than the
    -- explicit Chinese-name NPC option. If the user enables that option after
    -- an earlier provisional duel inference, discard only the provisional kind
    -- and let the configured NPC evidence take ownership.
    if entity.inferredKind == "PLAYER" then
        entity.inferredKind = nil
        entity.inferredKindReason = nil
        entity.inferredKindAt = nil
        entity.flags.kindProvisional = nil
    end
    -- Do not claim ownership of an NPC type already established by an official
    -- sight/target category. Turning the option off must never erase that fact.
    if entity.hardKind == "NPC" then return false end
    local changed = self:SetHardKind(entity, "NPC", "chinese_name_server_rule")
    entity.flags.chineseNameNpcApplied = true
    entity.flags.chineseNameKindConflict = nil
    return changed
end

function E:RefreshChineseNameKinds(enabled)
    local useRule = enabled == true
    local changed = false
    for _, entity in pairs(self.byKey or {}) do
        if type(entity) == "table" then
            entity.flags = entity.flags or {}
            if useRule then
                changed = self:ApplyChineseNameKind(entity) or changed
            elseif entity.hardKind == "NPC" and entity.flags.chineseNameNpcApplied == true then
                entity.hardKind = nil
                entity.flags.kindReason = nil
                entity.flags.hardKindReason = nil
                entity.flags.kindEvidenceRank = nil
                entity.flags.chineseNameNpcApplied = nil
                entity.flags.chineseNameKindConflict = nil
                entity.flags.chineseNameConflictReported = nil
                if entity.manualOverride ~= nil and entity.manualOverride.kind ~= nil then
                    entity.kind = entity.manualOverride.kind
                else
                    entity.kind = entity.inferredKind or "UNKNOWN"
                    self:Resolve(entity)
                end
                changed = true
            end
        end
    end
    if changed then
        D.MarkViewDirty()
        D.RequestReclassify(false, "KIND_POLICY")
    end
    return changed
end

function E:SetHardRelation(entity, relation, reason, validFrom)
    if entity == nil then return false end
    local hardChanged = entity.hardRelation ~= relation
    entity.hardRelation = relation
    if hardChanged and D.State.config.diagnosticsEnabled then
        D.Diagnostics:AddInfo("hard_relation", tostring(entity.name) .. "=" .. tostring(relation) .. " | " .. tostring(reason))
    end
    local transitionChanged = self:TransitionRelation(entity, relation, validFrom or U.NowMs(), reason)
    local ruleChanged = false
    if hardChanged and entity.manualOverride ~= nil and entity.manualOverride.source == "rule"
        and D.Rules ~= nil and D.Rules.ApplyToEntity ~= nil then
        ruleChanged = D.Rules:ApplyToEntity(entity, true) == true
    end
    if ruleChanged then
        D.State.dirty.reclassify = true
        D.MarkViewDirty()
    end
    return hardChanged or transitionChanged or ruleChanged
end

-- Apply the same score decay in live processing and historical replay. Older
-- builds decayed on a wall-clock timer but rebuilt all past evidence at full
-- strength, so an unrelated reclassification could resurrect a relationship
-- that had already faded. The per-entity clock makes the result deterministic.
function E:DecayEntityScoresTo(entity, decayAt)
    if type(entity) ~= "table" then return false end
    local override = type(entity.manualOverride) == "table" and entity.manualOverride or nil
    if override ~= nil and (override.relation ~= nil or override.ignored == true) then return false end
    local at = U.TimestampOrNow(decayAt)
    local interval = 30000
    local last = U.FiniteNumber(entity.lastScoreDecayAt, nil)
    if last == nil or last <= 0 then
        local evidenceAt = U.FiniteNumber(entity.lastEvidenceAt, nil)
        entity.lastScoreDecayAt = evidenceAt ~= nil and evidenceAt > 0 and evidenceAt or at
        return false
    end
    if at < last then
        entity.lastScoreDecayAt = at
        return false
    end
    local steps = math.floor((at - last) / interval)
    if steps <= 0 then return false end

    local relationFactor = math.pow(0.95, steps)
    entity.relationScores.friendly = (tonumber(entity.relationScores.friendly) or 0) * relationFactor
    entity.relationScores.opponent = (tonumber(entity.relationScores.opponent) or 0) * relationFactor
    entity.relationScores.neutral = (tonumber(entity.relationScores.neutral) or 0) * relationFactor
    entity.lastScoreDecayAt = last + steps * interval

    local changed = self:Resolve(entity, at)
    local strongestRelation = math.max(
        tonumber(entity.relationScores.friendly) or 0,
        tonumber(entity.relationScores.opponent) or 0,
        tonumber(entity.relationScores.neutral) or 0
    )
    if strongestRelation < D.Const.SUSPECT_THRESHOLD then
        entity.relationScores = { friendly = 0, opponent = 0, neutral = 0 }
        entity.relationEvidenceKinds = {}
        entity.evidenceKinds = {}
        entity.firstRelationEvidenceAt = nil
                changed = self:Resolve(entity, at) or changed
    end
    return changed
end

function E:AddRelationScore(entity, key, baseGain, evidenceKind, cooldownKey, evidenceAt)
    if entity == nil then return false end
    local override = type(entity.manualOverride) == "table" and entity.manualOverride or nil
    if override ~= nil and (override.relation ~= nil or override.ignored == true) then return false end
    -- Only social-friendly prior currently uses the score engine. Kind is never
    -- inferred from combat behavior; official observation/manual rules own it.
    MarkSoftEvidence(entity)
    local now = U.TimestampOrNow(evidenceAt)
    self:DecayEntityScoresTo(entity, now)
    local cooldownId = entity.key .. "|" .. tostring(cooldownKey or evidenceKind or key)
    local last = self.evidenceCooldowns[cooldownId]
    if last ~= nil and now - last < D.Const.EVIDENCE_COOLDOWN_MS then return false end
    self.evidenceCooldowns[cooldownId] = now
    if entity.firstRelationEvidenceAt == nil then entity.firstRelationEvidenceAt = now end
    local current = tonumber(entity.relationScores[key]) or 0
    local gain = (tonumber(baseGain) or 0) * (1 - current / 100)
    entity.relationScores[key] = U.Clamp(current + gain, 0, 100)
    local evidenceName = tostring(evidenceKind or key)
    entity.evidenceKinds[evidenceName] = true
    entity.relationEvidenceKinds[evidenceName] = true
    entity.lastEvidenceAt = now
    entity.lastScoreDecayAt = now
    if D.State.config.diagnosticsEnabled then
        D.Diagnostics:AddInfo("evidence", string.format(
            "%s | relation.%s %.1f→%.1f | %s",
            tostring(entity.name), tostring(key), current, entity.relationScores[key], evidenceName
        ))
    end
    return self:Resolve(entity, now)
end

function E:Resolve(entity, resolveAt)
    if entity == nil then return false end
    local resolveTime = U.TimestampOrNow(resolveAt)
    local changed = false
    local override = type(entity.manualOverride) == "table" and entity.manualOverride or nil
    entity.flags = entity.flags or {}

    -- Manual intervention is a per-property overlay, not ownership of the whole
    -- entity. Setting only FRIENDLY/OPPONENT must not freeze later PLAYER/NPC
    -- evidence, and setting only a type must not freeze team/opponent history.
    -- The old early-return implementation made untouched properties stale until
    -- the whole manual override was cleared.
    local baseKind = entity.hardKind or entity.inferredKind or "UNKNOWN"
    local effectiveKind = override ~= nil and override.kind or baseKind
    local effectiveKindReason
    if override ~= nil and override.kind ~= nil then
        entity.flags.kindProvisional = nil
        effectiveKindReason = "manual_override"
    else
        effectiveKindReason = entity.hardKind ~= nil
            and (entity.flags.hardKindReason or "hard_kind")
            or (entity.inferredKindReason or "unknown")
    end
    if entity.kind ~= effectiveKind then
        entity.kind = effectiveKind
        changed = true
    end
    -- kindReason describes the current effective view, while hardKindReason
    -- preserves the Authority provenance. Refresh it even when the enum itself
    -- did not change (for example after clearing a manual override).
    if entity.flags.kindReason ~= effectiveKindReason then
        entity.flags.kindReason = effectiveKindReason
        changed = true
    end
    if effectiveKind == "PLAYER" and A ~= nil and A.IsBoss ~= nil and A:IsBoss(entity.name) then
        -- A Boss name that is now confirmed as a player is invalid Authority.
        -- Clear the projection immediately instead of leaving an empty/stale PVE
        -- focus after the manual PLAYER correction migrates events into PVP.
        changed = A:ClearBossTarget(false) or changed
    end

    if override ~= nil and override.relation ~= nil then
        -- Do not rewrite authoritative relationHistory. This is only the current
        -- effective view; clearing the relation override restores the base path.
        if entity.relation ~= override.relation then
            entity.relation = override.relation
            changed = true
        end
        if entity.flags.relationReason ~= "manual_override" then
            entity.flags.relationReason = "manual_override"
            changed = true
        end
    elseif entity.hardRelation ~= nil then
        if entity.relation ~= entity.hardRelation then
            self:TransitionRelation(entity, entity.hardRelation, resolveTime,
                entity.flags.hardRelationReason or "hard_relation")
            changed = true
        end
    elseif entity.strongRelation ~= nil then
        if entity.relation ~= entity.strongRelation then
            self:TransitionRelation(entity, entity.strongRelation, entity.strongRelationSince or resolveTime,
                entity.strongRelationReason or "strong_combat_evidence")
            changed = true
        end
    else
        local friendly = tonumber(entity.relationScores.friendly) or 0
        local opponent = tonumber(entity.relationScores.opponent) or 0
        local diff = opponent - friendly
        local evidenceCount = U.TableCount(entity.relationEvidenceKinds)
        local nextRelation = entity.relation
        if math.abs(diff) < D.Const.SCORE_CONFLICT_GAP and math.max(friendly, opponent) >= D.Const.SUSPECT_THRESHOLD then
            nextRelation = "CONFLICT"
        elseif entity.relation == "OPPONENT" then
            if diff < D.Const.EXIT_THRESHOLD then nextRelation = "UNKNOWN" end
        elseif entity.relation == "FRIENDLY" then
            if -diff < D.Const.EXIT_THRESHOLD then nextRelation = "UNKNOWN" end
        elseif diff >= D.Const.ENTRY_THRESHOLD and evidenceCount >= 2 then
            nextRelation = "OPPONENT"
        elseif -diff >= D.Const.ENTRY_THRESHOLD and evidenceCount >= 2 then
            nextRelation = "FRIENDLY"
        elseif math.max(friendly, opponent) >= D.Const.SUSPECT_THRESHOLD then
            nextRelation = diff >= 0 and "SUSPECT_OPPONENT" or "SUSPECT_FRIENDLY"
        else
            nextRelation = "UNKNOWN"
        end
        if nextRelation ~= entity.relation then
            local relationFrom = resolveTime
            if nextRelation == "OPPONENT" or nextRelation == "FRIENDLY" then
                relationFrom = math.max(tonumber(entity.firstRelationEvidenceAt) or resolveTime, tonumber(entity.lastHardRelationEndedAt) or 0)
            else
                relationFrom = resolveTime
            end
            self:TransitionRelation(entity, nextRelation, relationFrom, "score_resolve")
            changed = true
        end
    end

    if changed then
        D.State.dirty.reclassify = true
        D.MarkViewDirty()
    end
    return changed
end

function E:BeginDecayScores(decayAt)
    if type(self.decayJob) == "table" then return false end
    self.decayJob = {
        phase = "entities",
        at = U.TimestampOrNow(decayAt),
        lastKey = nil,
        entitiesRoot = self.byKey,
        cooldownRoot = self.evidenceCooldowns,
    }
    return true
end

local function SafeNextForMaintenance(root, lastKey)
    root = type(root) == "table" and root or {}
    local ok, key, value = pcall(next, root, lastKey)
    if ok then return key, value end
    return next(root, nil)
end

function E:DecayScoresStep(entityBudget)
    local budget = math.max(1, math.floor(tonumber(entityBudget) or 100))
    local job = self.decayJob
    if type(job) ~= "table" then return true, 0 end
    local processed = 0

    while processed < budget and job.phase == "entities" do
        if job.entitiesRoot ~= self.byKey then
            job.entitiesRoot = self.byKey
            job.lastKey = nil
        end
        local key, entity = SafeNextForMaintenance(job.entitiesRoot, job.lastKey)
        if key == nil then
            job.phase = "cooldowns"
            job.lastKey = nil
            job.cooldownRoot = self.evidenceCooldowns
        else
            job.lastKey = key
            self:DecayEntityScoresTo(entity, job.at)
            processed = processed + 1
        end
    end

    while processed < budget and job.phase == "cooldowns" do
        if job.cooldownRoot ~= self.evidenceCooldowns then
            job.cooldownRoot = self.evidenceCooldowns
            job.lastKey = nil
        end
        local key, at = SafeNextForMaintenance(job.cooldownRoot, job.lastKey)
        if key == nil then
            job.phase = "name_bindings"
            job.lastKey = nil
            job.bindingRoot = self.nameBindings
            break
        end
        job.lastKey = key
        if job.at - (tonumber(at) or 0) > D.Const.MAX_TRANSIENT_CACHE_AGE_MS then
            job.cooldownRoot[key] = nil
        end
        processed = processed + 1
    end

    while processed < budget and job.phase == "name_bindings" do
        if job.bindingRoot ~= self.nameBindings then
            job.bindingRoot = self.nameBindings
            job.lastKey = nil
        end
        local normalized, bucket = SafeNextForMaintenance(job.bindingRoot, job.lastKey)
        if normalized == nil then
            self.decayJob = nil
            D.Diagnostics.counters.decayPasses =
                (tonumber(D.Diagnostics.counters.decayPasses) or 0) + 1
            return true, processed
        end
        job.lastKey = normalized
        local byId = type(bucket) == "table" and type(bucket.byId) == "table" and bucket.byId or nil
        if byId == nil then
            job.bindingRoot[normalized] = nil
        else
            local retention = math.max(30000, tonumber(D.Const.NAME_BINDING_RETENTION_MS) or 180000)
            for id, record in pairs(byId) do
                local lastSeen = U.FiniteNumber(record and record.lastSeenAt, 0) or 0
                if job.at - lastSeen > retention then byId[id] = nil end
            end
            if next(byId) == nil then job.bindingRoot[normalized] = nil end
        end
        processed = processed + 1
    end

    self.decayJob = job
    return false, processed
end

function E:RegisterSelf()
    local entity = self:GetOrCreate(D.Identity.playerNameWithWorld)
    if U.NormalizeName(entity.name) ~= U.NormalizeName(D.Identity.playerName) then
        self.byName[U.NormalizeName(D.Identity.playerName)] = entity.key
    end
    self:SetHardKind(entity, "PLAYER", "self")
    self:SetHardRelation(entity, "SELF", "self", 0)
    D.Identity.entityKey = entity.key
end

local VALID_MANUAL_KINDS = { PLAYER = true, NPC = true, MATE = true, SLAVE = true, OTHER = true }
local VALID_MANUAL_RELATIONS = { FRIENDLY = true, OPPONENT = true, NEUTRAL = true }

-- Find the history:* owner that actually carries name-only combat facts for a
-- concrete identity. Cross-world instances can expose Name@World through the
-- official unit API while COMBAT_MSG keeps only Name. Prefer an already-existing
-- history row whose current collision-checked team alias resolves to this exact
-- canonical entity. Never strip @World by string convention alone. If multiple
-- existing aliases would qualify, fail closed rather than choosing one.
local function ResolvePlayerHistoricalAlias(entity, createIfMissing)
    if type(entity) ~= "table" then return nil end
    local normalized = U.NormalizeName(entity.name)
    if normalized == "" then return nil end
    local exact = E.byKey and E.byKey["history:" .. normalized] or nil
    if type(exact) == "table" then return exact end

    local canonical = E:GetByKey(entity.key) or entity
    local canonicalKey = tostring(canonical.key or "")
    local matched = nil
    for aliasName, aliasKey in pairs(type(E.teamNameAliases) == "table" and E.teamNameAliases or {}) do
        local aliasEntity = E:GetByKey(aliasKey) or (E.byKey and E.byKey[aliasKey])
        if type(aliasEntity) == "table" and tostring(aliasEntity.key or "") == canonicalKey then
            local history = E.byKey and E.byKey["history:" .. tostring(aliasName)] or nil
            if type(history) == "table" then
                if matched ~= nil and matched ~= history then return nil end
                matched = history
            end
        end
    end
    if matched ~= nil then return matched end
    if createIfMissing == true then return E:GetHistoricalNameEntity(entity.name) end
    return nil
end

-- Combat logs are frequently name-only while sight/target APIs may expose a
-- concrete id:* entity. If the user marks that concrete row as PLAYER but the
-- retained combat events belong to namehistory:*, changing only the concrete
-- entity cannot affect replay. Propagate PLAYER identity and the user-owned fields that can be proven to refer
-- to the same unique player into the name-history owner. Relation may use a
-- same-relation consensus across concrete IDs; ignore is mirrored only when the
-- selected exact player is the sole concrete same-name identity. Synthetic
-- mirrors are reversible and never become broad persistent name rules. This keeps name-only events correctable without turning a broad name
-- into a permanent player rule.
local function PlayerHistoryCorrectionTarget(entity)
    if type(entity) ~= "table" or U.NormalizeName(entity.name) == "" then return nil end
    local history = ResolvePlayerHistoricalAlias(entity, true)
    if type(history) ~= "table" or history.key == entity.key then return nil end

    -- A direct manual/rule non-player decision on the historical aggregate is
    -- stronger than a concrete player's convenience mirror. Never overwrite it.
    local historyOverride = type(history.manualOverride) == "table" and history.manualOverride or nil
    local historyKind = historyOverride ~= nil and historyOverride.kind or history.hardKind or history.kind
    if historyKind ~= nil and historyKind ~= "UNKNOWN" and historyKind ~= "PLAYER" then return nil end

    local candidates = E:GetCandidatesByName(history.name) or {}
    for _, candidate in ipairs(candidates) do
        if type(candidate) == "table" and candidate.key ~= entity.key and candidate.key ~= history.key then
            local overrideKind = type(candidate.manualOverride) == "table" and candidate.manualOverride.kind or nil
            local candidateKind = overrideKind or candidate.hardKind or candidate.kind
            local keyText = tostring(candidate.key or "")
            local concreteStable = candidate.stringId ~= nil and tostring(candidate.stringId) ~= ""
                or string.sub(keyText, 1, 3) == "id:"
            -- A second concrete ID whose type is still unknown makes even the
            -- broad PLAYER kind unsafe. Fail closed until official/manual kind
            -- evidence arrives; a later kind observation re-runs mirror sync.
            if concreteStable and (candidateKind == nil or candidateKind == "UNKNOWN") then
                return nil
            end
            if candidateKind ~= nil and candidateKind ~= "UNKNOWN" and candidateKind ~= "PLAYER" then
                return nil
            end
        end
    end
    return history
end

local function IsConcretePlayerIdentityCandidate(candidate)
    if type(candidate) ~= "table" then return false end
    local flags = type(candidate.flags) == "table" and candidate.flags or nil
    if flags ~= nil and (flags.historicalNameAggregate == true
        or flags.nameOnlyTeam == true) then
        return false
    end
    local keyText = tostring(candidate.key or "")
    -- teamname:/history:/name:/ambiguous: are representations of a name, not
    -- independent people. Counting them as same-name concrete players made an
    -- official TEAM placeholder with no manual relation veto the correction of
    -- the exact id:* player. Only a stable id:* identity can create a real
    -- same-name ambiguity at this gate.
    return candidate.stringId ~= nil and tostring(candidate.stringId) ~= ""
        or string.sub(keyText, 1, 3) == "id:"
end

local function PlayerHistoryRelationCorrectionTarget(entity, relation)
    if VALID_MANUAL_RELATIONS[relation] ~= true then return nil end
    local history = PlayerHistoryCorrectionTarget(entity)
    if type(history) ~= "table" then return nil end

    -- Relation is more specific than PLAYER kind. A name-only event may inherit
    -- an exact-ID relation when the selected player is the only concrete ID, or
    -- every other concrete same-name PLAYER carries the same explicit relation.
    -- Synthetic roster/name representations are deliberately ignored here: they
    -- describe the same combat-log name and must not veto the user's exact-ID
    -- correction merely because TEAM is stored as hard relation rather than a
    -- manual FRIENDLY overlay.
    local candidates = E:GetCandidatesByName(history.name) or {}
    local concreteCount = 0
    for _, candidate in ipairs(candidates) do
        if type(candidate) == "table" and candidate.key ~= history.key
            and IsConcretePlayerIdentityCandidate(candidate) then
            concreteCount = concreteCount + 1
            local candidateOverride = type(candidate.manualOverride) == "table"
                and candidate.manualOverride or nil
            local candidateKind = candidateOverride ~= nil and candidateOverride.kind
                or candidate.hardKind or candidate.kind
            local candidateRelation = candidateOverride ~= nil and candidateOverride.relation or nil
            if candidateKind ~= "PLAYER" then return nil end
            if candidate.key ~= entity.key and candidateRelation ~= relation then return nil end
        end
    end
    if concreteCount < 1 then return nil end
    return history
end

local function PlayerHistoryIgnoreCorrectionTarget(entity)
    local history = PlayerHistoryCorrectionTarget(entity)
    if type(history) ~= "table" then return nil end

    -- Ignore removes data rather than merely moving it between sides, so it must
    -- be stricter than relation mirroring. Only one concrete stable player may
    -- own the combat-log name; otherwise a name-only row cannot be safely erased
    -- on behalf of one of several same-name players.
    local concreteCount = 0
    for _, candidate in ipairs(E:GetCandidatesByName(history.name) or {}) do
        if type(candidate) == "table" and candidate.key ~= history.key
            and IsConcretePlayerIdentityCandidate(candidate) then
            concreteCount = concreteCount + 1
            if candidate.key ~= entity.key then return nil end
            local candidateOverride = type(candidate.manualOverride) == "table"
                and candidate.manualOverride or nil
            local candidateKind = candidateOverride ~= nil and candidateOverride.kind
                or candidate.hardKind or candidate.kind
            if candidateKind ~= "PLAYER" then return nil end
        end
    end
    if concreteCount ~= 1 then return nil end
    return history
end

local function SessionBaseRule(entity, override)
    if D.Rules == nil or type(D.Rules.GetById) ~= "function" then return nil end
    local ruleId = type(override) == "table"
        and (override.baseRuleId or override.ruleId) or entity.persistentRuleId
    return ruleId ~= nil and D.Rules:GetById(ruleId) or nil
end

local function InferSessionEditFlags(entity, previous)
    if type(previous) ~= "table" or previous.source ~= "session" then
        return false, false, false
    end
    local baseRule = SessionBaseRule(entity, previous)
    local kindEdited = previous.editedKind
    local relationEdited = previous.editedRelation
    local ignoredEdited = previous.editedIgnored
    if kindEdited == nil then
        if baseRule ~= nil then kindEdited = previous.kind ~= baseRule.kind
        else kindEdited = previous.kind ~= nil end
    end
    if relationEdited == nil then
        if baseRule ~= nil then relationEdited = previous.relation ~= baseRule.relation
        else relationEdited = previous.relation ~= nil end
    end
    if ignoredEdited == nil then
        if baseRule ~= nil then ignoredEdited = (previous.ignored == true) ~= (baseRule.ignored == true)
        else ignoredEdited = previous.ignored == true end
    end
    return kindEdited == true, relationEdited == true, ignoredEdited == true
end

local function ApplySessionManualOverride(entity, kind, relation, ignored, options)
    options = type(options) == "table" and options or {}
    local previous = type(entity.manualOverride) == "table" and entity.manualOverride or {}
    local editedKind, editedRelation, editedIgnored = InferSessionEditFlags(entity, previous)
    local nextKind = previous.kind
    local nextRelation = previous.relation
    local nextIgnored = previous.ignored == true
    local mirroredKind = previous.mirroredKind == true
    local mirroredRelation = previous.mirroredRelation == true
    local mirroredIgnored = previous.mirroredIgnored == true
    local projectionScoped = previous.projectionScoped == true
    local projectionOwnerKey = previous.projectionOwnerKey
    local projectionRuleId = previous.projectionRuleId

    -- A ranking row can be a history:/teamname:/old-id projection of a newer
    -- canonical entity.  Keep that relationship explicit so save/disable/remove
    -- and "恢复自动判断" can clean up both representations as one user action.
    if options.projectionScope == true then
        projectionScoped = true
        projectionOwnerKey = tostring(options.projectionOwnerKey or projectionOwnerKey or "")
        if projectionOwnerKey == "" then projectionOwnerKey = nil end
        projectionRuleId = options.projectionRuleId or projectionRuleId
    elseif options.keepProjectionScope ~= true
        and (kind ~= nil or relation ~= nil or ignored ~= nil) then
        projectionScoped = false
        projectionOwnerKey = nil
        projectionRuleId = nil
    end

    if kind ~= nil then
        nextKind = kind
        if options.mirrorKind == true then
            mirroredKind = true
            editedKind = false
        else
            editedKind = options.projectionDerived ~= true
            mirroredKind = false
        end
    end
    if relation ~= nil then
        nextRelation = relation
        if options.mirrorRelation == true then
            mirroredRelation = true
            editedRelation = false
        else
            editedRelation = options.projectionDerived ~= true
            mirroredRelation = false
        end
    end
    if ignored ~= nil then
        nextIgnored = ignored == true
        if options.mirrorIgnore == true then
            mirroredIgnored = true
            editedIgnored = false
        else
            editedIgnored = options.projectionDerived ~= true
            mirroredIgnored = false
        end
    end

    local baseRuleId = options.projectionRuleId
        or previous.ruleId or previous.baseRuleId or entity.persistentRuleId
    local stateChanged = previous.source ~= "session"
        or previous.kind ~= nextKind
        or previous.relation ~= nextRelation
        or (previous.ignored == true) ~= nextIgnored
        or previous.baseRuleId ~= baseRuleId
        or (previous.editedKind == true) ~= (editedKind == true)
        or (previous.editedRelation == true) ~= (editedRelation == true)
        or (previous.editedIgnored == true) ~= (editedIgnored == true)
        or (previous.mirroredKind == true) ~= (mirroredKind == true)
        or (previous.mirroredRelation == true) ~= (mirroredRelation == true)
        or (previous.mirroredIgnored == true) ~= (mirroredIgnored == true)
        or (previous.projectionScoped == true) ~= (projectionScoped == true)
        or tostring(previous.projectionOwnerKey or "") ~= tostring(projectionOwnerKey or "")
        or tostring(previous.projectionRuleId or "") ~= tostring(projectionRuleId or "")
    if stateChanged then
        entity.manualOverride = {
            kind = nextKind,
            relation = nextRelation,
            ignored = nextIgnored,
            source = "session",
            ruleId = nil,
            baseRuleId = baseRuleId,
            editedKind = editedKind == true,
            editedRelation = editedRelation == true,
            editedIgnored = editedIgnored == true,
            mirroredKind = mirroredKind == true,
            mirroredRelation = mirroredRelation == true,
            mirroredIgnored = mirroredIgnored == true,
            projectionScoped = projectionScoped == true,
            projectionOwnerKey = projectionOwnerKey,
            projectionRuleId = projectionRuleId,
            at = U.NowMs(),
        }
        entity.persistentRuleId = baseRuleId
        entity.flags = entity.flags or {}
    end
    return E:Resolve(entity) or stateChanged
end

local function RestoreUnderlyingWithSessionFields(entity, keepKind, keepRelation, keepIgnored)
    local previous = type(entity.manualOverride) == "table" and entity.manualOverride or nil
    if previous == nil then return false end
    local editedKind, editedRelation, editedIgnored = InferSessionEditFlags(entity, previous)
    local previousKind = previous.kind
    local previousRelation = previous.relation
    local previousIgnored = previous.ignored == true
    local baseRuleId = previous.baseRuleId or previous.ruleId or entity.persistentRuleId

    entity.manualOverride = nil
    entity.persistentRuleId = baseRuleId
    entity.kind = entity.hardKind or entity.inferredKind or "UNKNOWN"
    entity.relation = entity.hardRelation or entity.historyRelation or "UNKNOWN"
    local changed = false
    if D.Rules ~= nil and D.Rules.ApplyToEntity ~= nil then
        changed = D.Rules:ApplyToEntity(entity, true) == true or changed
    end
    changed = E:Resolve(entity) or changed

    local kindValue = keepKind == true and editedKind and previousKind or nil
    local relationValue = keepRelation == true and editedRelation and previousRelation or nil
    local ignoredValue = keepIgnored == true and editedIgnored and previousIgnored or nil
    if kindValue ~= nil or relationValue ~= nil or ignoredValue ~= nil then
        local projectionOptions = previous.projectionScoped == true and {
            projectionScope = true,
            keepProjectionScope = true,
            projectionOwnerKey = previous.projectionOwnerKey,
            projectionRuleId = previous.projectionRuleId,
        } or nil
        changed = ApplySessionManualOverride(
            entity, kindValue, relationValue, ignoredValue, projectionOptions) or changed
    end
    return changed
end

function E:RebaseSessionOverride(entity)
    local override = type(entity) == "table" and entity.manualOverride or nil
    if type(override) ~= "table" or override.source ~= "session" then return false end

    -- A projection correction promoted to a persistent rule is derived state,
    -- not an independent permanent edit on the old actor key.  While the rule is
    -- enabled it follows the rule fields; disabling/removing the rule removes the
    -- projection layer as well.
    if override.projectionScoped == true and override.projectionRuleId ~= nil then
        local rule = D.Rules ~= nil and D.Rules:GetById(override.projectionRuleId) or nil
        local ownerKey = override.projectionOwnerKey
        local changed = RestoreUnderlyingWithSessionFields(entity, false, false, false)
        if RuleEnabled(rule) then
            changed = ApplySessionManualOverride(entity,
                rule.kind, rule.relation, rule.ignored == true, {
                    projectionScope = true,
                    projectionDerived = true,
                    projectionOwnerKey = ownerKey,
                    projectionRuleId = rule.ruleId,
                }) or changed
        end
        return changed
    end

    local hadMirroredKind = override.mirroredKind == true
    local hadMirroredRelation = override.mirroredRelation == true
    local hadMirroredIgnored = override.mirroredIgnored == true
    local changed = RestoreUnderlyingWithSessionFields(entity, true, true, true)
    if hadMirroredKind and type(entity.repdpsPlayerHistoryMirrorOwners) == "table"
        and next(entity.repdpsPlayerHistoryMirrorOwners) ~= nil then
        changed = ApplySessionManualOverride(entity, "PLAYER", nil, nil, { mirrorKind = true }) or changed
    end
    if hadMirroredRelation
        and type(entity.repdpsPlayerHistoryRelationMirrorOwners) == "table" then
        local consensus = nil
        local conflict = false
        for _, relation in pairs(entity.repdpsPlayerHistoryRelationMirrorOwners) do
            if VALID_MANUAL_RELATIONS[relation] == true then
                if consensus == nil then consensus = relation
                elseif consensus ~= relation then conflict = true break end
            end
        end
        if consensus ~= nil and not conflict then
            changed = ApplySessionManualOverride(
                entity, nil, consensus, nil, { mirrorRelation = true }) or changed
        end
    end
    if hadMirroredIgnored
        and type(entity.repdpsPlayerHistoryIgnoreMirrorOwners) == "table"
        and next(entity.repdpsPlayerHistoryIgnoreMirrorOwners) ~= nil then
        changed = ApplySessionManualOverride(
            entity, nil, nil, true, { mirrorIgnore = true }) or changed
    end
    return changed
end

local function RawHistoricalEntity(entity)
    return ResolvePlayerHistoricalAlias(entity, false)
end

local function HasPlayerHistoryMirrorOwners(history)
    return type(history) == "table"
        and type(history.repdpsPlayerHistoryMirrorOwners) == "table"
        and next(history.repdpsPlayerHistoryMirrorOwners) ~= nil
end

local function PlayerHistoryRelationConsensus(history)
    if type(history) ~= "table"
        or type(history.repdpsPlayerHistoryRelationMirrorOwners) ~= "table" then
        return nil, false
    end
    local consensus = nil
    local conflict = false
    local invalidOwners = nil
    for ownerKey, relation in pairs(history.repdpsPlayerHistoryRelationMirrorOwners) do
        if VALID_MANUAL_RELATIONS[relation] ~= true then
            invalidOwners = invalidOwners or {}
            invalidOwners[#invalidOwners + 1] = ownerKey
        elseif consensus == nil then
            consensus = relation
        elseif consensus ~= relation then
            conflict = true
        end
    end
    if invalidOwners ~= nil then
        for _, ownerKey in ipairs(invalidOwners) do
            history.repdpsPlayerHistoryRelationMirrorOwners[ownerKey] = nil
        end
    end
    if conflict then return nil, true end
    return consensus, false
end

-- Name-only combat facts and a later exact id:* observation may refer to the
-- same player, but only while no same-name non-player conflict is known.  The
-- exact player type and an explicit manual/persistent relation are mirrored to
-- the history:* aggregate as synthetic session fields.  They are not editable
-- user state on the aggregate: direct aggregate edits/rules always win, multiple
-- exact players with conflicting relations disable the relation mirror, and
-- clearing/disabling the concrete rule removes the synthetic fields again.
local function RefreshPlayerHistoryMirror(history)
    if type(history) ~= "table" then return false end
    history.flags = history.flags or {}

    local hasKindOwners = HasPlayerHistoryMirrorOwners(history)
    local relationConsensus, relationConflict = PlayerHistoryRelationConsensus(history)
    local hasIgnoreOwners = type(history.repdpsPlayerHistoryIgnoreMirrorOwners) == "table"
        and next(history.repdpsPlayerHistoryIgnoreMirrorOwners) ~= nil
    local override = type(history.manualOverride) == "table" and history.manualOverride or nil
    local directKind = override ~= nil and override.kind ~= nil and override.mirroredKind ~= true
    local directRelation = override ~= nil and override.relation ~= nil
        and override.mirroredRelation ~= true
    local directIgnored = override ~= nil and override.ignored == true
        and override.mirroredIgnored ~= true
    local desiredKind = hasKindOwners and not directKind and "PLAYER" or nil
    local desiredRelation = relationConsensus ~= nil and not relationConflict
        and not directRelation and relationConsensus or nil
    local desiredIgnored = hasIgnoreOwners and not directIgnored and true or nil

    local changed = false
    local previousConflict = history.flags.historyRelationMirrorConflict == true
    history.flags.historyRelationMirrorConflict = relationConflict == true and true or nil
    if previousConflict ~= (relationConflict == true) then changed = true end

    -- Remove only synthetic components before rebuilding the effective mirror.
    -- Independently edited relation/ignore fields and the underlying persistent
    -- rule are restored by RestoreUnderlyingWithSessionFields.
    override = type(history.manualOverride) == "table" and history.manualOverride or nil
    local hadMirroredKind = override ~= nil and override.mirroredKind == true
    local hadMirroredRelation = override ~= nil and override.mirroredRelation == true
    local hadMirroredIgnored = override ~= nil and override.mirroredIgnored == true
    if hadMirroredKind or hadMirroredRelation or hadMirroredIgnored then
        changed = RestoreUnderlyingWithSessionFields(
            history, not hadMirroredKind, not hadMirroredRelation, not hadMirroredIgnored) or changed
    end

    override = type(history.manualOverride) == "table" and history.manualOverride or nil
    directKind = override ~= nil and override.kind ~= nil and override.mirroredKind ~= true
    directRelation = override ~= nil and override.relation ~= nil
        and override.mirroredRelation ~= true
    directIgnored = override ~= nil and override.ignored == true
        and override.mirroredIgnored ~= true
    if desiredKind ~= nil and not directKind then
        changed = ApplySessionManualOverride(
            history, desiredKind, nil, nil, { mirrorKind = true }) or changed
    end
    if desiredRelation ~= nil and not directRelation then
        changed = ApplySessionManualOverride(
            history, nil, desiredRelation, nil, { mirrorRelation = true }) or changed
    end
    if desiredIgnored == true and not directIgnored then
        changed = ApplySessionManualOverride(
            history, nil, nil, true, { mirrorIgnore = true }) or changed
    end
    return changed
end

function E:SyncPlayerHistoryCorrection(entity)
    if type(entity) ~= "table" or (entity.flags and entity.flags.historicalNameAggregate == true) then
        return false, nil
    end
    local ownerKey = tostring(entity.key or "")
    if ownerKey == "" then return false, nil end

    local override = type(entity.manualOverride) == "table" and entity.manualOverride or nil
    local kindOwner = override ~= nil and override.kind == "PLAYER"
    local effectiveKind = override ~= nil and override.kind or entity.hardKind or entity.kind
    local relationOwner = nil
    if effectiveKind == "PLAYER" and override ~= nil
        and VALID_MANUAL_RELATIONS[override.relation] == true then
        relationOwner = override.relation
    end
    local ignoreOwner = effectiveKind == "PLAYER" and override ~= nil
        and override.ignored == true

    local kindHistory = kindOwner and PlayerHistoryCorrectionTarget(entity) or nil
    local relationHistory = relationOwner ~= nil
        and PlayerHistoryRelationCorrectionTarget(entity, relationOwner) or nil
    local ignoreHistory = ignoreOwner and PlayerHistoryIgnoreCorrectionTarget(entity) or nil
    local rawHistory = RawHistoricalEntity(entity)
    local changed = false
    local affected = nil

    -- A direct non-player type decision on the aggregate temporarily blocks the
    -- safe target. Keep the exact-player kind owner dormant so clearing that
    -- direct decision can restore the mirror. Relation ownership is deliberately
    -- not kept across ambiguous same-name candidates.
    local rawHistoryOverride = type(rawHistory) == "table"
        and type(rawHistory.manualOverride) == "table" and rawHistory.manualOverride or nil
    local keepDormantKindOwner = kindHistory == nil and kindOwner
        and rawHistoryOverride ~= nil and rawHistoryOverride.kind ~= nil
        and rawHistoryOverride.mirroredKind ~= true

    if type(rawHistory) == "table" then
        local ownerChanged = false
        if rawHistory ~= kindHistory and keepDormantKindOwner ~= true
            and type(rawHistory.repdpsPlayerHistoryMirrorOwners) == "table"
            and rawHistory.repdpsPlayerHistoryMirrorOwners[ownerKey] ~= nil then
            rawHistory.repdpsPlayerHistoryMirrorOwners[ownerKey] = nil
            ownerChanged = true
        elseif not kindOwner and type(rawHistory.repdpsPlayerHistoryMirrorOwners) == "table"
            and rawHistory.repdpsPlayerHistoryMirrorOwners[ownerKey] ~= nil then
            rawHistory.repdpsPlayerHistoryMirrorOwners[ownerKey] = nil
            ownerChanged = true
        end

        if rawHistory ~= relationHistory
            and type(rawHistory.repdpsPlayerHistoryRelationMirrorOwners) == "table"
            and rawHistory.repdpsPlayerHistoryRelationMirrorOwners[ownerKey] ~= nil then
            rawHistory.repdpsPlayerHistoryRelationMirrorOwners[ownerKey] = nil
            ownerChanged = true
        elseif relationOwner == nil
            and type(rawHistory.repdpsPlayerHistoryRelationMirrorOwners) == "table"
            and rawHistory.repdpsPlayerHistoryRelationMirrorOwners[ownerKey] ~= nil then
            rawHistory.repdpsPlayerHistoryRelationMirrorOwners[ownerKey] = nil
            ownerChanged = true
        end

        if rawHistory ~= ignoreHistory
            and type(rawHistory.repdpsPlayerHistoryIgnoreMirrorOwners) == "table"
            and rawHistory.repdpsPlayerHistoryIgnoreMirrorOwners[ownerKey] ~= nil then
            rawHistory.repdpsPlayerHistoryIgnoreMirrorOwners[ownerKey] = nil
            ownerChanged = true
        elseif not ignoreOwner
            and type(rawHistory.repdpsPlayerHistoryIgnoreMirrorOwners) == "table"
            and rawHistory.repdpsPlayerHistoryIgnoreMirrorOwners[ownerKey] ~= nil then
            rawHistory.repdpsPlayerHistoryIgnoreMirrorOwners[ownerKey] = nil
            ownerChanged = true
        end

        if ownerChanged then
            changed = RefreshPlayerHistoryMirror(rawHistory) or changed
            affected = rawHistory
        end
    end

    local desiredHistories = {}
    if kindHistory ~= nil then desiredHistories[kindHistory] = true end
    if relationHistory ~= nil then desiredHistories[relationHistory] = true end
    if ignoreHistory ~= nil then desiredHistories[ignoreHistory] = true end
    for history in pairs(desiredHistories) do
        local ownerChanged = false
        history.repdpsPlayerHistoryMirrorOwners =
            type(history.repdpsPlayerHistoryMirrorOwners) == "table"
            and history.repdpsPlayerHistoryMirrorOwners or {}
        history.repdpsPlayerHistoryRelationMirrorOwners =
            type(history.repdpsPlayerHistoryRelationMirrorOwners) == "table"
            and history.repdpsPlayerHistoryRelationMirrorOwners or {}
        history.repdpsPlayerHistoryIgnoreMirrorOwners =
            type(history.repdpsPlayerHistoryIgnoreMirrorOwners) == "table"
            and history.repdpsPlayerHistoryIgnoreMirrorOwners or {}

        if history == kindHistory and kindOwner then
            if history.repdpsPlayerHistoryMirrorOwners[ownerKey] ~= true then
                history.repdpsPlayerHistoryMirrorOwners[ownerKey] = true
                ownerChanged = true
            end
        elseif history.repdpsPlayerHistoryMirrorOwners[ownerKey] ~= nil then
            history.repdpsPlayerHistoryMirrorOwners[ownerKey] = nil
            ownerChanged = true
        end

        if history == relationHistory and relationOwner ~= nil then
            if history.repdpsPlayerHistoryRelationMirrorOwners[ownerKey] ~= relationOwner then
                history.repdpsPlayerHistoryRelationMirrorOwners[ownerKey] = relationOwner
                ownerChanged = true
            end
        elseif history.repdpsPlayerHistoryRelationMirrorOwners[ownerKey] ~= nil then
            history.repdpsPlayerHistoryRelationMirrorOwners[ownerKey] = nil
            ownerChanged = true
        end

        if history == ignoreHistory and ignoreOwner then
            if history.repdpsPlayerHistoryIgnoreMirrorOwners[ownerKey] ~= true then
                history.repdpsPlayerHistoryIgnoreMirrorOwners[ownerKey] = true
                ownerChanged = true
            end
        elseif history.repdpsPlayerHistoryIgnoreMirrorOwners[ownerKey] ~= nil then
            history.repdpsPlayerHistoryIgnoreMirrorOwners[ownerKey] = nil
            ownerChanged = true
        end

        local effectiveChanged = RefreshPlayerHistoryMirror(history)
        changed = ownerChanged or effectiveChanged or changed
        if ownerChanged or effectiveChanged then affected = history end
    end
    return changed, affected
end

function E:SyncPlayerHistoryCorrectionsByName(name)
    local changed = false
    local affected = nil
    local candidates = self:GetCandidatesByName(name)
    for _, candidate in ipairs(candidates) do
        if type(candidate) == "table"
            and not (candidate.flags and candidate.flags.historicalNameAggregate == true) then
            local candidateChanged, candidateAffected = self:SyncPlayerHistoryCorrection(candidate)
            if candidateChanged == true then
                changed = true
                affected = candidateAffected or affected
            end
        end
    end
    return changed, affected
end

local function ActorHasProjectedValue(actor)
    return type(actor) == "table" and (
        (tonumber(actor.damage) or 0) ~= 0
        or (tonumber(actor.taken) or 0) ~= 0
        or (tonumber(actor.heal) or 0) ~= 0
        or (tonumber(actor.kills) or 0) ~= 0)
end

local function StatsRootHasActorOnSide(statsRoot, sideName, actorKey)
    if type(statsRoot) ~= "table" or type(actorKey) ~= "string" or actorKey == "" then return false end
    for _, modeName in ipairs({ "PVP", "PVE" }) do
        local mode = statsRoot[modeName]
        local side = type(mode) == "table" and mode[sideName] or nil
        local actor = type(side) == "table" and type(side.actors) == "table"
            and side.actors[actorKey] or nil
        if ActorHasProjectedValue(actor) then return true end
    end
    local shared = statsRoot.sharedHealing
    local sharedSide = type(shared) == "table" and shared[sideName] or nil
    local sharedActor = type(sharedSide) == "table" and type(sharedSide.actors) == "table"
        and sharedSide.actors[actorKey] or nil
    return ActorHasProjectedValue(sharedActor)
end

local function AddEquivalentActorKeys(keys, seen, candidate)
    local first = type(candidate) == "table" and tostring(candidate.key or "")
        or tostring(candidate or "")
    if first == "" then return end
    local aliases = type(E.aliases) == "table" and E.aliases or {}
    local pending = { first }
    local head = 1
    local visited = 0
    while head <= #pending and visited < 128 do
        local current = tostring(pending[head] or "")
        head = head + 1
        if current ~= "" and seen[current] ~= true then
            seen[current] = true
            keys[#keys + 1] = current
            visited = visited + 1
            local forward = aliases[current]
            if forward ~= nil then pending[#pending + 1] = tostring(forward) end
            -- Actor rows can survive under any pre-promotion key in an old
            -- baseline or replay working tree. Reverse aliases are examined only
            -- on explicit user actions, never on the combat hot path.
            for aliasKey, targetKey in pairs(aliases) do
                if tostring(targetKey or "") == current then
                    pending[#pending + 1] = tostring(aliasKey)
                end
            end
        end
    end
end

-- A rule can become effective only after a later stable-ID observation. In that
-- case the detail header already shows FRIENDLY/OPPONENT while older retained
-- projection rows still sit on the previous side. Re-clicking the same button
-- must reassert the correction instead of returning NO_CHANGE forever.
local function ManualRelationProjectionMismatch(entity, relation, mirrorEntity, projectionEntity)
    if relation ~= "FRIENDLY" and relation ~= "OPPONENT" then return false end
    local wrongSide = relation == "FRIENDLY" and "enemy" or "friendly"
    local keys = {}
    local seen = {}
    AddEquivalentActorKeys(keys, seen, entity)
    AddEquivalentActorKeys(keys, seen, mirrorEntity)
    -- A direct clicked history:/teamname:/old-id projection can still own the
    -- wrong-side Actor even when a synthetic history mirror was also touched.
    -- rc24 passed `mirrorEntity or projectionEntity`, so the projection vanished
    -- from this audit whenever both existed and a repeated FRIENDLY/OPPONENT
    -- click could incorrectly return NO_CHANGE. Keep both identities in the
    -- explicit-user, low-frequency closure.
    AddEquivalentActorKeys(keys, seen, projectionEntity)
    local history = RawHistoricalEntity(entity)
    if type(history) == "table" then
        local owners = history.repdpsPlayerHistoryRelationMirrorOwners
        if type(owners) == "table" and owners[tostring(entity.key or "")] == relation then
            AddEquivalentActorKeys(keys, seen, history)
        end
    end
    local roots = {
        D.State and D.State.stats or nil,
        D.Stats and D.Stats.replayWorkingStats or nil,
        D.EventStore and D.EventStore.baselineStats or nil,
    }
    for _, actorKey in ipairs(keys) do
        for _, root in ipairs(roots) do
            if StatsRootHasActorOnSide(root, wrongSide, actorKey) then return true end
        end
    end
    return false
end

local function ManualProjectionIdentityMatches(ownerEntity, projectionEntity)
    if type(ownerEntity) ~= "table" or type(projectionEntity) ~= "table" then return false end
    if U.NormalizeName(projectionEntity.name) == U.NormalizeName(ownerEntity.name) then return true end

    local ownerId = ownerEntity.stringId ~= nil and tostring(ownerEntity.stringId) or ""
    local projectionId = projectionEntity.stringId ~= nil and tostring(projectionEntity.stringId) or ""
    if ownerId ~= "" and projectionId ~= "" and ownerId == projectionId then return true end

    -- Name@World and the short COMBAT_MSG name are accepted only when current
    -- Authority proves they converge to this exact owner. Never broad-match by
    -- stripping '@World' alone: two worlds can legitimately contain the same
    -- short player name.
    if ownerId ~= "" and type(E.ResolveNameBinding) == "function" then
        local boundId = E:ResolveNameBinding(projectionEntity.name, U.NowMs())
        if boundId ~= nil and tostring(boundId) == ownerId then return true end
    end
    if type(E.ResolveTeamNameAlias) == "function" then
        local rosterEntity = E:ResolveTeamNameAlias(projectionEntity.name, U.NowMs())
        if type(rosterEntity) == "table" and tostring(rosterEntity.key or "") == tostring(ownerEntity.key or "") then
            return true
        end
    end
    return false
end

local function ResolveManualProjectionEntity(ownerEntity, projectionKey)
    if type(ownerEntity) ~= "table" then return nil end
    local projectionText = tostring(projectionKey or "")
    if projectionText == "" or projectionText == tostring(ownerEntity.key or "") then return nil end
    -- Read the exact pre-canonical row first. GetByKey may follow aliases and
    -- would otherwise return the owner again, losing the clicked projection.
    local projectionEntity = type(E.byKey) == "table" and E.byKey[projectionText] or nil
    if projectionEntity == nil then projectionEntity = E:GetByKey(projectionText) end
    if type(projectionEntity) ~= "table"
        or projectionEntity == ownerEntity
        or not ManualProjectionIdentityMatches(ownerEntity, projectionEntity)
        or IsProtectedSelfEntity(projectionEntity) then
        return nil
    end
    return projectionEntity
end

function E:ApplyManualByKey(key, kind, relation, ignored, projectionKey)
    local entity = self:GetByKey(key)
    if entity == nil then return false, "单位不存在" end
    if kind ~= nil and VALID_MANUAL_KINDS[kind] ~= true then return false, "无效单位类型" end
    if relation ~= nil and VALID_MANUAL_RELATIONS[relation] ~= true then return false, "无效敌我关系" end
    local isSelf = IsProtectedSelfEntity(entity)
    if isSelf and (kind ~= nil or relation ~= nil or ignored == true) then
        return false, "自己不能修改类型、敌我关系或忽略状态"
    end

    -- The detail panel can resolve a clicked ranking actor to a newer canonical
    -- id:* entity. Keep the original projection key as explicit user context:
    -- retained combat facts may still be owned by history:/teamname:/an old id:.
    -- Updating only the canonical entity makes the header show FRIENDLY while the
    -- clicked enemy row survives every replay. Apply the same per-property session
    -- decision to that exact projection owner when it is a same-name non-self
    -- representation. This is user-directed scope, not automatic broad matching.
    local projectionEntity = ResolveManualProjectionEntity(entity, projectionKey)

    local function RequestAlreadyExplicit(target)
        local existing = type(target) == "table" and type(target.manualOverride) == "table"
            and target.manualOverride or nil
        if existing == nil then return false end
        if kind ~= nil and existing.kind ~= kind then return false end
        if relation ~= nil and existing.relation ~= relation then return false end
        if ignored ~= nil and (existing.ignored == true) ~= (ignored == true) then return false end
        -- Synthetic history mirrors are derived convenience state. If the user
        -- clicks the same value on that row, promote it to a direct session
        -- adjudication instead of returning NO_CHANGE; otherwise a later
        -- same-name conflict can legitimately withdraw the mirror and appear to
        -- undo an explicit user action.
        if kind ~= nil and existing.mirroredKind == true then return false end
        if relation ~= nil and existing.mirroredRelation == true then return false end
        if ignored == true and existing.mirroredIgnored == true then return false end
        return true
    end

    -- A value already owned by a session/persistent rule needs no second
    -- session layer. Besides avoiding a full replay on repeated clicks, this
    -- prevents clicking "忽略" on an already permanently ignored row from
    -- creating a fake "本次忽略" that cannot actually be recovered.
    local stateChanged = RequestAlreadyExplicit(entity) ~= true
        and ApplySessionManualOverride(entity, kind, relation, ignored) or false
    local projectionChanged = projectionEntity ~= nil
        and RequestAlreadyExplicit(projectionEntity) ~= true
        and ApplySessionManualOverride(projectionEntity, kind, relation, ignored, {
            projectionScope = true,
            projectionOwnerKey = entity.key,
        }) or false

    -- Keep concrete-player mirror ownership while a direct historical override
    -- is active. The direct type wins, but preserving the dormant owner set lets
    -- "恢复自动判断" reveal the still-valid concrete PLAYER correction again.
    -- Deleting the owner set here made the restoration permanently forget it.
    local mirrorChanged, mirrorEntity = self:SyncPlayerHistoryCorrectionsByName(entity.name)
    local replayEntity = projectionChanged and projectionEntity
        or (mirrorChanged and mirrorEntity or entity)
    local projectionMismatch = ManualRelationProjectionMismatch(
        entity, relation, mirrorEntity, projectionEntity)
    if stateChanged ~= true and projectionChanged ~= true
        and mirrorChanged ~= true and projectionMismatch ~= true then
        return true, "NO_CHANGE"
    end

    D.MarkViewDirty()
    D.RequestReclassify(true,
        projectionMismatch == true and "MANUAL_RELATION_REASSERT"
            or (projectionChanged == true and "MANUAL_PROJECTION_SCOPE" or "MANUAL_OVERRIDE"), {
        key = replayEntity.key, name = replayEntity.name, boundId = replayEntity.stringId,
    })
    return true
end

function E:SaveManualRuleByKey(key, preferredMatchType, projectionKey)
    local entity = self:GetByKey(key)
    if entity == nil or D.Rules == nil then return nil, "单位不存在" end
    local projectionEntity = ResolveManualProjectionEntity(entity, projectionKey)
    local rule, matchTypeOrError = D.Rules:UpsertFromEntity(entity, preferredMatchType)
    if rule ~= nil then
        -- Convert the exact clicked projection from an independent session edit
        -- into rule-derived scope. It remains effective while the rule is enabled
        -- and is removed automatically when the rule is disabled/deleted.
        if projectionEntity ~= nil then
            ApplySessionManualOverride(projectionEntity,
                rule.kind, rule.relation, rule.ignored == true, {
                    projectionScope = true,
                    projectionDerived = true,
                    projectionOwnerKey = entity.key,
                    projectionRuleId = rule.ruleId,
                })
        end
        local mirrorChanged, mirrorEntity = self:SyncPlayerHistoryCorrectionsByName(entity.name)
        if mirrorChanged and mirrorEntity ~= nil then
            D.RequestReclassify(true, "PERSISTENT_RULE_HISTORY_SYNC", {
                key = mirrorEntity.key, name = mirrorEntity.name, boundId = mirrorEntity.stringId,
            })
        elseif projectionEntity ~= nil then
            D.RequestReclassify(true, "PERSISTENT_RULE_PROJECTION_SYNC", {
                key = projectionEntity.key, name = projectionEntity.name,
                boundId = projectionEntity.stringId,
            })
        end
    end
    return rule, matchTypeOrError
end

-- Return the session/rule override visible in the user's exact detail context.
-- Prefer canonical Authority state, but fall back to the original projection
-- when upgrading history:/teamname: to id:* left an older projection-owned
-- layer behind. This is a read-only UI/recovery helper and never widens identity.
function E:GetManualOverrideByKey(key, projectionKey)
    local entity = self:GetByKey(key)
    if entity == nil then return nil end
    local override = type(entity.manualOverride) == "table" and entity.manualOverride or nil
    if override ~= nil then return override end
    local projectionEntity = ResolveManualProjectionEntity(entity, projectionKey)
    if projectionEntity ~= nil and type(projectionEntity.manualOverride) == "table" then
        return projectionEntity.manualOverride
    end
    return nil
end

-- Read the persistent rule that owns the user's current detail context. The
-- canonical id:* entity and the exact clicked projection may temporarily differ
-- while aliases are promoted/replayed; UI state must not claim "未保存到名单"
-- merely because the rule is attached to the projection side of that identity.
function E:GetPersistentRuleByKey(key, projectionKey)
    local entity = self:GetByKey(key)
    if entity == nil or D.Rules == nil then return nil, nil end
    local rule, matchMode = D.Rules:GetForEntity(entity)
    if rule ~= nil then return rule, matchMode end
    local projectionEntity = ResolveManualProjectionEntity(entity, projectionKey)
    if projectionEntity ~= nil then
        return D.Rules:GetForEntity(projectionEntity)
    end
    return nil, nil
end

function E:RemovePersistentRuleByKey(key, projectionKey)
    local entity = self:GetByKey(key)
    if entity == nil or D.Rules == nil then return false end
    local projectionEntity = ResolveManualProjectionEntity(entity, projectionKey)
    local rule = D.Rules:GetForEntity(entity)
    if rule == nil and projectionEntity ~= nil then
        rule = D.Rules:GetForEntity(projectionEntity)
    end
    if rule == nil then return false end
    local removed = D.Rules:Remove(rule.ruleId)
    if removed then
        self:SyncPlayerHistoryCorrectionsByName(entity.name)
        if projectionEntity ~= nil and U.NormalizeName(projectionEntity.name) ~= U.NormalizeName(entity.name) then
            self:SyncPlayerHistoryCorrectionsByName(projectionEntity.name)
        end
    end
    return removed
end

function E:ClearSessionIgnoreByKey(key, projectionKey)
    local entity = self:GetByKey(key)
    if entity == nil then return false, "单位不存在" end
    local projectionEntity = ResolveManualProjectionEntity(entity, projectionKey)
    local targets = { entity }
    if projectionEntity ~= nil then targets[#targets + 1] = projectionEntity end

    local cleared = false
    local semanticChanged = false
    local restoredRuleIgnore = false
    local affectedNames = {}
    for _, target in ipairs(targets) do
        local override = type(target.manualOverride) == "table" and target.manualOverride or nil
        if override ~= nil and override.source == "session" and override.ignored == true then
            local _, _, ignoredEdited = InferSessionEditFlags(target, override)
            if ignoredEdited == true then
                local beforeIgnored = self:IsIgnored(target) == true
                local beforeKind = target.kind
                local beforeRelation = target.relation
                RestoreUnderlyingWithSessionFields(target, true, true, false)
                local afterIgnored = self:IsIgnored(target) == true
                restoredRuleIgnore = restoredRuleIgnore or afterIgnored
                semanticChanged = semanticChanged
                    or beforeIgnored ~= afterIgnored
                    or beforeKind ~= target.kind
                    or beforeRelation ~= target.relation
                affectedNames[U.NormalizeName(target.name)] = target.name
                cleared = true
            end
        end
    end
    if not cleared then
        return false, "当前单位没有可恢复的本次忽略标记；名单忽略请从名单移除或停用规则"
    end

    local replayEntity = projectionEntity or entity
    for _, name in pairs(affectedNames) do
        local mirrorChanged, mirrorEntity = self:SyncPlayerHistoryCorrectionsByName(name)
        if mirrorChanged == true then
            semanticChanged = true
            replayEntity = mirrorEntity or replayEntity
        end
    end
    D.MarkViewDirty()
    if semanticChanged then
        D.RequestReclassify(true, "MANUAL_CLEAR_SINGLE_IGNORE", {
            key = replayEntity.key, name = replayEntity.name, boundId = replayEntity.stringId,
        })
    end
    return true, restoredRuleIgnore and "RESTORED_RULE_IGNORE" or nil
end

function E:ClearSessionIgnores()
    local count = 0
    local touched = 0
    local affectedNames = {}
    local entities = {}
    for _, entity in pairs(self.byKey or {}) do entities[#entities + 1] = entity end
    for _, entity in ipairs(entities) do
        local override = entity.manualOverride
        if type(override) == "table" and override.source == "session" and override.ignored == true then
            local _, _, ignoredEdited = InferSessionEditFlags(entity, override)
            if ignoredEdited == true then
                -- Clear only an ignore state that was actually edited in this
                -- session. A session overlay may inherit ignored=true from its
                -- base rule while the user edits another field; counting that as
                -- a recoverable temporary ignore produces a false-success UI.
                local baseRule = SessionBaseRule(entity, override)
                local remainsIgnored = baseRule ~= nil and baseRule.ignored == true
                RestoreUnderlyingWithSessionFields(entity, true, true, false)
                affectedNames[U.NormalizeName(entity.name)] = entity.name
                touched = touched + 1
                if not remainsIgnored and not self:IsIgnored(entity) then
                    count = count + 1
                end
            end
        end
    end
    if touched > 0 then
        for _, name in pairs(affectedNames) do
            self:SyncPlayerHistoryCorrectionsByName(name)
        end
        D.MarkViewDirty()
        if count > 0 then D.RequestReclassify(true, "MANUAL_CLEAR_SESSION_IGNORE") end
    end
    return count
end

function E:ClearManualByKey(key, projectionKey)
    local entity = self:GetByKey(key)
    if entity == nil then return false end
    local projectionEntity = ResolveManualProjectionEntity(entity, projectionKey)
    local targets = { entity }
    if projectionEntity ~= nil then targets[#targets + 1] = projectionEntity end

    local cleared = false
    local affectedNames = {}
    local replayEntity = projectionEntity or entity
    for _, target in ipairs(targets) do
        local override = type(target.manualOverride) == "table" and target.manualOverride or nil
        if override ~= nil and override.source == "session" then
            RestoreUnderlyingWithSessionFields(target, false, false, false)
            affectedNames[U.NormalizeName(target.name)] = target.name
            replayEntity = target
            cleared = true
        end
    end
    if not cleared then return false end

    for _, name in pairs(affectedNames) do
        local mirrorChanged, mirrorEntity = self:SyncPlayerHistoryCorrectionsByName(name)
        local history = self.byKey and self.byKey["history:" .. U.NormalizeName(name)] or nil
        if type(history) == "table" then
            mirrorChanged = RefreshPlayerHistoryMirror(history) or mirrorChanged
            if mirrorChanged then mirrorEntity = history end
        end
        if mirrorChanged and mirrorEntity ~= nil then replayEntity = mirrorEntity end
    end
    D.MarkViewDirty()
    D.RequestReclassify(true, "MANUAL_CLEAR", {
        key = replayEntity.key, name = replayEntity.name, boundId = replayEntity.stringId,
    })
    return true
end

E:RegisterSelf()
if D.Rules ~= nil and D.Rules.ApplyAll ~= nil then D.Rules:ApplyAll(true) end

local function NewMetricBreakdown(counterpartKey)
    local result = { abilities = {} }
    result[counterpartKey] = {}
    return result
end

local ACTOR_DETAILS_READY = setmetatable({}, { __mode = "k" })

local function NewActorStats(name)
    local actor = {
        name = U.SafeName(name, "未知"),
        damage = 0,
        taken = 0,
        heal = 0,
        kills = 0,
        provisional = false,
        details = {
            damage = NewMetricBreakdown("targets"),
            taken = NewMetricBreakdown("sources"),
            heal = NewMetricBreakdown("targets"),
            -- Last-hit collection is disabled.  Do not allocate three empty
            -- kill-breakdown tables for every new actor; old persisted kill
            -- rows are restored lazily by EnsureKillDetails when present.
        },
        active = {
            damage = { total = 0, last = nil, startedAt = nil },
            taken = { total = 0, last = nil, startedAt = nil },
            heal = { total = 0, last = nil, startedAt = nil },
        },
    }
    ACTOR_DETAILS_READY[actor] = true
    return actor
end

local function EnsureKillDetails(actor)
    actor.details = type(actor.details) == "table" and actor.details or {}
    local kills = actor.details.kills
    if type(kills) ~= "table" then
        kills = NewMetricBreakdown("targets")
        actor.details.kills = kills
    end
    kills.abilities = type(kills.abilities) == "table" and kills.abilities or {}
    kills.targets = type(kills.targets) == "table" and kills.targets or {}
    return kills
end

local function EnsureActorDetails(actor)
    if ACTOR_DETAILS_READY[actor] == true then return actor.details end
    actor.details = actor.details or {}
    actor.details.damage = actor.details.damage or NewMetricBreakdown("targets")
    actor.details.taken = actor.details.taken or NewMetricBreakdown("sources")
    actor.details.heal = actor.details.heal or NewMetricBreakdown("targets")
    actor.details.damage.abilities = actor.details.damage.abilities or {}
    actor.details.damage.targets = actor.details.damage.targets or {}
    actor.details.taken.abilities = actor.details.taken.abilities or {}
    actor.details.taken.sources = actor.details.taken.sources or {}
    actor.details.heal.abilities = actor.details.heal.abilities or {}
    actor.details.heal.targets = actor.details.heal.targets or {}
    if type(actor.details.kills) == "table" or (tonumber(actor.kills) or 0) > 0 then
        EnsureKillDetails(actor)
    end
    ACTOR_DETAILS_READY[actor] = true
    return actor.details
end

local function NewSideStats()
    return {
        actors = {},
        totals = { damage = 0, taken = 0, heal = 0, kills = 0 },
        active = {
            damage = { total = 0, last = nil, startedAt = nil },
            taken = { total = 0, last = nil, startedAt = nil },
            heal = { total = 0, last = nil, startedAt = nil },
        },
    }
end

local function NewModeStats(mode)
    return {
        schemaVersion = 2,
        mode = mode,
        epochStart = 0,
        friendly = NewSideStats(),
        enemy = NewSideStats(),
        pending = { events = 0, damage = 0, taken = 0, heal = 0 },
        thirdParty = { events = 0, damage = 0, taken = 0, heal = 0 },
        closure = { friendlyDamageVsEnemyTaken = 100, enemyDamageVsFriendlyTaken = 100 },
    }
end

local function NewSharedHealingStats()
    return {
        schemaVersion = 1,
        friendly = NewSideStats(),
        enemy = NewSideStats(),
    }
end

local function NewIdentityProjectionStats()
    return {
        schemaVersion = 1,
        nextActorId = 0,
        nextTargetRefId = 0,
        actorIdByToken = {},
        targetRefIdByToken = {},
        actorsById = {},
        targetRefsById = {},
        breakdowns = {
            PVP = { friendly = { actors = {} }, enemy = { actors = {} } },
            PVE = { friendly = { actors = {} }, enemy = { actors = {} } },
        },
        migration = {
            sourceSchema = 2,
            legacyModeBucketsRetained = true,
            legacyNameBreakdownsRetained = true,
        },
        projectionState = "READY",
        needsRebuild = false,
    }
end

local function NewStatsV2Root()
    return {
        schemaVersion = 2,
        PVP = NewModeStats("PVP"),
        PVE = NewModeStats("PVE"),
        lastSaveAt = 0,
    }
end

local function NewStatsV3Root()
    return {
        schemaVersion = 3,
        PVP = NewModeStats("PVP"),
        PVE = NewModeStats("PVE"),
        sharedHealing = NewSharedHealingStats(),
        identityProjection = NewIdentityProjectionStats(),
        lastSaveAt = 0,
    }
end

local defaultStats = NewStatsV3Root()

local function NonNegativeNumber(value, fallback)
    local number = U.FiniteNumber(value, U.FiniteNumber(fallback, 0)) or 0
    return math.max(0, number)
end

local function SanitizeNumberMap(source)
    local result = {}
    if type(source) ~= "table" then return result end
    for key, value in pairs(source) do
        local keyType = type(key)
        local amount = U.FiniteNumber(value, nil)
        if (keyType == "string" or keyType == "number") and amount ~= nil and amount >= 0 then
            local normalizedKey = tostring(key)
            result[normalizedKey] = (result[normalizedKey] or 0) + amount
        end
    end
    return result
end

local function SanitizeActive(source)
    source = type(source) == "table" and source or {}
    local active = {
        total = NonNegativeNumber(source.total, 0),
        last = U.FiniteNumber(source.last, nil),
        startedAt = U.FiniteNumber(source.startedAt, nil),
    }
    if active.last == nil or active.startedAt == nil or active.last < active.startedAt then
        active.last = nil
        active.startedAt = nil
    end
    return active
end

local function SanitizeActorV2(source, fallbackName)
    if type(source) ~= "table" then return nil end
    local actor = NewActorStats(U.SafeName(source.name, fallbackName or "未知"))
    for _, metric in ipairs({ "damage", "taken", "heal", "kills" }) do
        actor[metric] = NonNegativeNumber(source[metric], 0)
    end
    actor.provisional = source.provisional == true
    actor.legacyDetailsDiscarded = source.legacyDetailsDiscarded == true
    local sourceActive = type(source.active) == "table" and source.active or {}
    actor.active.damage = SanitizeActive(sourceActive.damage)
    actor.active.taken = SanitizeActive(sourceActive.taken)
    actor.active.heal = SanitizeActive(sourceActive.heal)

    local details = type(source.details) == "table" and source.details or {}
    local damage = type(details.damage) == "table" and details.damage or {}
    local taken = type(details.taken) == "table" and details.taken or {}
    local heal = type(details.heal) == "table" and details.heal or {}
    local kills = type(details.kills) == "table" and details.kills or nil
    actor.details.damage.abilities = SanitizeNumberMap(damage.abilities)
    actor.details.damage.targets = SanitizeNumberMap(damage.targets)
    actor.details.taken.abilities = SanitizeNumberMap(taken.abilities)
    actor.details.taken.sources = SanitizeNumberMap(taken.sources)
    actor.details.heal.abilities = SanitizeNumberMap(heal.abilities)
    actor.details.heal.targets = SanitizeNumberMap(heal.targets)
    if kills ~= nil or actor.kills > 0 then
        local killDetails = EnsureKillDetails(actor)
        killDetails.abilities = SanitizeNumberMap(kills and kills.abilities)
        killDetails.targets = SanitizeNumberMap(kills and kills.targets)
    end
    return actor
end

local function MergeSharedActiveForMigration(first, second, windowMs)
    first = type(first) == "table" and first or {}
    second = type(second) == "table" and second or {}
    local total = NonNegativeNumber(first.total, 0) + NonNegativeNumber(second.total, 0)
    local leftStart = U.FiniteNumber(first.startedAt, nil)
    local leftLast = U.FiniteNumber(first.last, nil)
    local rightStart = U.FiniteNumber(second.startedAt, nil)
    local rightLast = U.FiniteNumber(second.last, nil)
    if leftStart == nil or leftLast == nil or leftLast < leftStart then
        if rightStart == nil or rightLast == nil or rightLast < rightStart then
            return { total = total, last = nil, startedAt = nil }
        end
        return { total = total, last = rightLast, startedAt = rightStart }
    end
    if rightStart == nil or rightLast == nil or rightLast < rightStart then
        return { total = total, last = leftLast, startedAt = leftStart }
    end
    windowMs = math.max(0, tonumber(windowMs) or 0)
    local olderStart, olderLast, newerStart, newerLast = leftStart, leftLast, rightStart, rightLast
    if rightStart < leftStart then
        olderStart, olderLast, newerStart, newerLast = rightStart, rightLast, leftStart, leftLast
    end
    if newerStart <= olderLast + windowMs then
        return {
            total = total,
            startedAt = math.min(olderStart, newerStart),
            last = math.max(olderLast, newerLast),
        }
    end
    total = total + math.max(0, olderLast + windowMs - olderStart)
    return { total = total, startedAt = newerStart, last = newerLast }
end

local function MergeHealingMap(target, source)
    target = type(target) == "table" and target or {}
    for key, value in pairs(type(source) == "table" and source or {}) do
        local amount = NonNegativeNumber(value, 0)
        if amount > 0 then target[tostring(key)] = (tonumber(target[tostring(key)]) or 0) + amount end
    end
    return target
end

local function MergeHealingActorForMigration(target, source, displayName)
    if type(source) ~= "table" then return target end
    if type(target) ~= "table" then target = NewActorStats(displayName or source.name) end
    target.name = U.SafeName(displayName or target.name or source.name, "未知")
    target.heal = (tonumber(target.heal) or 0) + NonNegativeNumber(source.heal, 0)
    target.provisional = target.provisional == true or source.provisional == true
    target.legacyDetailsDiscarded = target.legacyDetailsDiscarded == true or source.legacyDetailsDiscarded == true
    local targetDetails = EnsureActorDetails(target)
    local sourceHeal = source.details and source.details.heal or nil
    if type(sourceHeal) == "table" then
        targetDetails.heal.abilities = MergeHealingMap(targetDetails.heal.abilities, sourceHeal.abilities)
        targetDetails.heal.targets = MergeHealingMap(targetDetails.heal.targets, sourceHeal.targets)
    end
    target.active.heal = MergeSharedActiveForMigration(
        target.active and target.active.heal,
        source.active and source.active.heal,
        D.State.config.personalWindowMs
    )
    target.repdpsSharedHealing = true
    target.repdpsDetailRevision = (tonumber(target.repdpsDetailRevision) or 0) + 1
    return target
end

local function BuildSharedHealingFromLegacy(statsRoot)
    local shared = NewSharedHealingStats()
    for _, sideName in ipairs({ "friendly", "enemy" }) do
        local targetSide = shared[sideName]
        local pvpSide = statsRoot and statsRoot.PVP and statsRoot.PVP[sideName] or nil
        local pveSide = statsRoot and statsRoot.PVE and statsRoot.PVE[sideName] or nil
        targetSide.totals.heal = NonNegativeNumber(pvpSide and pvpSide.totals and pvpSide.totals.heal, 0)
            + NonNegativeNumber(pveSide and pveSide.totals and pveSide.totals.heal, 0)
        targetSide.active.heal = MergeSharedActiveForMigration(
            pvpSide and pvpSide.active and pvpSide.active.heal,
            pveSide and pveSide.active and pveSide.active.heal,
            D.State.config.sideWindowMs
        )
        local pvpActors = type(pvpSide) == "table" and type(pvpSide.actors) == "table" and pvpSide.actors or {}
        local pveActors = type(pveSide) == "table" and type(pveSide.actors) == "table" and pveSide.actors or {}
        for key, actor in pairs(pvpActors) do
            targetSide.actors[key] = MergeHealingActorForMigration(targetSide.actors[key], actor, actor and actor.name)
        end
        for key, actor in pairs(pveActors) do
            targetSide.actors[key] = MergeHealingActorForMigration(targetSide.actors[key], actor, actor and actor.name)
        end
    end
    return shared
end

local function SanitizeSharedHealingV1(source, fallbackStats)
    if type(source) ~= "table" or tonumber(source.schemaVersion) ~= 1 then
        return BuildSharedHealingFromLegacy(fallbackStats)
    end
    local result = NewSharedHealingStats()
    for _, sideName in ipairs({ "friendly", "enemy" }) do
        local sourceSide = type(source[sideName]) == "table" and source[sideName] or {}
        local side = result[sideName]
        local sourceActive = type(sourceSide.active) == "table" and sourceSide.active or {}
        side.active.heal = SanitizeActive(sourceActive.heal)
        local sum = 0
        for key, sourceActor in pairs(type(sourceSide.actors) == "table" and sourceSide.actors or {}) do
            if type(key) == "string" and key ~= "" then
                local actor = SanitizeActorV2(sourceActor, key)
                if actor ~= nil and actor.heal > 0 then
                    actor.damage, actor.taken, actor.kills = 0, 0, 0
                    side.actors[key] = actor
                    sum = sum + actor.heal
                end
            end
        end
        side.totals.heal = math.max(NonNegativeNumber(sourceSide.totals and sourceSide.totals.heal, 0), sum)
    end
    return result
end

local function SanitizeIdentityProjectionV1(source)
    if type(source) ~= "table" or tonumber(source.schemaVersion) ~= 1 then
        return NewIdentityProjectionStats()
    end
    local result = NewIdentityProjectionStats()
    local maxActorId = 0
    local maxTargetRefId = 0

    -- Rebuild the token dictionaries from the sanitized descriptors instead of
    -- trusting persisted reverse maps. This prevents a corrupt token map from
    -- aliasing a future ActorId/TargetRefId to the wrong descriptor.
    for idKey, descriptor in pairs(type(source.actorsById) == "table" and source.actorsById or {}) do
        local id = math.floor(tonumber(idKey) or 0)
        if id > 0 and type(descriptor) == "table" then
            local identityToken = tostring(descriptor.identityToken or "")
            local sanitized = {
                actorId = id,
                identityToken = identityToken,
                canonicalKey = descriptor.canonicalKey ~= nil and tostring(descriptor.canonicalKey) or nil,
                stableId = descriptor.stableId ~= nil and tostring(descriptor.stableId) or nil,
                displayName = U.SafeName(descriptor.displayName, "未知"),
                normalizedName = tostring(descriptor.normalizedName or ""),
                identityQuality = tostring(descriptor.identityQuality or "UNKNOWN_KEY"),
            }
            result.actorsById[tostring(id)] = sanitized
            if identityToken ~= "" then
                local existing = tonumber(result.actorIdByToken[identityToken])
                if existing == nil or id < existing then result.actorIdByToken[identityToken] = id end
            end
            maxActorId = math.max(maxActorId, id)
        end
    end
    for idKey, descriptor in pairs(type(source.targetRefsById) == "table" and source.targetRefsById or {}) do
        local id = math.floor(tonumber(idKey) or 0)
        if id > 0 and type(descriptor) == "table" then
            local actorId = math.floor(tonumber(descriptor.actorId) or 0)
            local identityToken = tostring(descriptor.identityToken or "")
            local sanitized = {
                refId = id,
                identityToken = identityToken,
                kind = descriptor.kind == "ACTOR" and "ACTOR" or "NAME_HISTORY",
                actorId = actorId > 0 and actorId or nil,
                canonicalKey = descriptor.canonicalKey ~= nil and tostring(descriptor.canonicalKey) or nil,
                displayName = U.SafeName(descriptor.displayName, "未知"),
                normalizedName = tostring(descriptor.normalizedName or ""),
                resolutionQuality = tostring(descriptor.resolutionQuality or "UNKNOWN_KEY"),
            }
            result.targetRefsById[tostring(id)] = sanitized
            if identityToken ~= "" then
                local existing = tonumber(result.targetRefIdByToken[identityToken])
                if existing == nil or id < existing then result.targetRefIdByToken[identityToken] = id end
            end
            maxTargetRefId = math.max(maxTargetRefId, id)
            if actorId > 0 then maxActorId = math.max(maxActorId, actorId) end
        end
    end
    local sourceBreakdowns = type(source.breakdowns) == "table" and source.breakdowns or {}
    for _, mode in ipairs({ "PVP", "PVE" }) do
        for _, sideName in ipairs({ "friendly", "enemy" }) do
            local sourceSide = sourceBreakdowns[mode] and sourceBreakdowns[mode][sideName] or nil
            local targetActors = result.breakdowns[mode][sideName].actors
            for actorIdKey, actorRow in pairs(type(sourceSide) == "table" and type(sourceSide.actors) == "table" and sourceSide.actors or {}) do
                local actorId = math.floor(tonumber(actorIdKey) or 0)
                if actorId > 0 and type(actorRow) == "table" then
                    local targetRow = { actorId = actorId, metrics = {} }
                    local metrics = type(actorRow.metrics) == "table" and actorRow.metrics or {}
                    for _, metric in ipairs({ "damage", "taken", "heal", "kills" }) do
                        local sourceMetric = type(metrics[metric]) == "table" and metrics[metric] or nil
                        if sourceMetric ~= nil then
                            local counterparts = SanitizeNumberMap(sourceMetric.counterparts)
                            targetRow.metrics[metric] = {
                                amount = NonNegativeNumber(sourceMetric.amount, 0),
                                abilities = SanitizeNumberMap(sourceMetric.abilities),
                                counterparts = counterparts,
                            }
                            for refIdKey in pairs(counterparts) do
                                local refId = math.floor(tonumber(refIdKey) or 0)
                                if refId > 0 then maxTargetRefId = math.max(maxTargetRefId, refId) end
                            end
                        end
                    end
                    targetActors[tostring(actorId)] = targetRow
                    maxActorId = math.max(maxActorId, actorId)
                end
            end
        end
    end
    result.nextActorId = math.max(
        maxActorId,
        math.max(0, math.floor(tonumber(source.nextActorId) or 0)))
    result.nextTargetRefId = math.max(
        maxTargetRefId,
        math.max(0, math.floor(tonumber(source.nextTargetRefId) or 0)))
    result.migration = type(source.migration) == "table" and U.DeepCopy(source.migration) or result.migration
    result.projectionState = source.projectionState == "DEGRADED" and "DEGRADED" or "READY"
    result.needsRebuild = source.needsRebuild == true
    result.structureRevision = math.max(0, math.floor(tonumber(source.structureRevision) or 0))
    return result
end

local function PairClosure(left, right)
    left = NonNegativeNumber(left, 0)
    right = NonNegativeNumber(right, 0)
    local maximum = math.max(left, right)
    if maximum <= 0 then return 100 end
    return math.min(left, right) / maximum * 100
end

local function IsStoredNonNegativeNumber(value)
    return type(value) == "number" and value == value
        and value ~= math.huge and value ~= -math.huge and value >= 0
end

local function ValidateStoredNumberMap(source)
    if type(source) ~= "table" then return false end
    for key, value in pairs(source) do
        local keyType = type(key)
        if (keyType ~= "string" and keyType ~= "number")
            or not IsStoredNonNegativeNumber(value) then
            return false
        end
    end
    return true
end

local function ValidateStoredActive(source)
    if type(source) ~= "table" or not IsStoredNonNegativeNumber(source.total) then return false end
    local last = source.last
    local startedAt = source.startedAt
    if last == nil and startedAt == nil then return true end
    return type(last) == "number" and last == last and last ~= math.huge and last ~= -math.huge
        and type(startedAt) == "number" and startedAt == startedAt
        and startedAt ~= math.huge and startedAt ~= -math.huge and last >= startedAt
end

local function ValidateStoredActor(source)
    if type(source) ~= "table" or type(source.name) ~= "string" then return false end
    for _, metric in ipairs({ "damage", "taken", "heal", "kills" }) do
        if not IsStoredNonNegativeNumber(source[metric]) then return false end
    end
    local active = source.active
    if type(active) ~= "table"
        or not ValidateStoredActive(active.damage)
        or not ValidateStoredActive(active.taken)
        or not ValidateStoredActive(active.heal) then
        return false
    end
    local details = source.details
    if type(details) ~= "table" then return false end
    local required = {
        { "damage", "abilities", "targets" },
        { "taken", "abilities", "sources" },
        { "heal", "abilities", "targets" },
    }
    for _, spec in ipairs(required) do
        local row = details[spec[1]]
        if type(row) ~= "table"
            or not ValidateStoredNumberMap(row[spec[2]])
            or not ValidateStoredNumberMap(row[spec[3]]) then
            return false
        end
    end
    local kills = details.kills
    if kills ~= nil then
        if type(kills) ~= "table"
            or not ValidateStoredNumberMap(kills.abilities)
            or not ValidateStoredNumberMap(kills.targets) then
            return false
        end
    elseif (tonumber(source.kills) or 0) > 0 then
        -- Old non-zero kill totals must keep their historical breakdown.
        return false
    end
    return true
end

-- Current rotating snapshots are produced only by this addon. Validate every
-- persisted actor and detail value without allocating a second full statistics
-- tree, then adopt the already deserialized payload directly. A malformed or
-- legacy payload still falls back to the repairing sanitizer below. This keeps
-- the trust boundary while avoiding a two-copy memory peak on large lifetime
-- saves.
local function ValidateStoredLegacyStats(source, expectedSchema)
    if type(source) ~= "table" or tonumber(source.schemaVersion) ~= tonumber(expectedSchema)
        or not IsStoredNonNegativeNumber(source.lastSaveAt) then
        return false
    end
    for _, modeName in ipairs({ "PVP", "PVE" }) do
        local mode = source[modeName]
        if type(mode) ~= "table" or not IsStoredNonNegativeNumber(mode.epochStart) then return false end
        for _, summaryName in ipairs({ "pending", "thirdParty" }) do
            local summary = mode[summaryName]
            if type(summary) ~= "table" then return false end
            for _, metric in ipairs({ "events", "damage", "taken", "heal" }) do
                if not IsStoredNonNegativeNumber(summary[metric]) then return false end
            end
        end
        if type(mode.closure) ~= "table"
            or not IsStoredNonNegativeNumber(mode.closure.friendlyDamageVsEnemyTaken)
            or not IsStoredNonNegativeNumber(mode.closure.enemyDamageVsFriendlyTaken) then
            return false
        end
        for _, sideName in ipairs({ "friendly", "enemy" }) do
            local side = mode[sideName]
            if type(side) ~= "table" or type(side.totals) ~= "table"
                or type(side.active) ~= "table" or type(side.actors) ~= "table" then
                return false
            end
            for _, metric in ipairs({ "damage", "taken", "heal", "kills" }) do
                if not IsStoredNonNegativeNumber(side.totals[metric]) then return false end
            end
            if not ValidateStoredActive(side.active.damage)
                or not ValidateStoredActive(side.active.taken)
                or not ValidateStoredActive(side.active.heal) then
                return false
            end
            for key, actor in pairs(side.actors) do
                if type(key) ~= "string" or key == "" or not ValidateStoredActor(actor) then
                    return false
                end
            end
        end
    end
    return true
end

local function ValidateStoredStatsV2(source)
    return ValidateStoredLegacyStats(source, 2)
end

local function ValidateStoredSharedHealingV1(source)
    if type(source) ~= "table" or tonumber(source.schemaVersion) ~= 1 then return false end
    for _, sideName in ipairs({ "friendly", "enemy" }) do
        local side = source[sideName]
        if type(side) ~= "table" or type(side.actors) ~= "table"
            or type(side.totals) ~= "table" or type(side.active) ~= "table" then return false end
        if not IsStoredNonNegativeNumber(side.totals.heal)
            or not ValidateStoredActive(side.active.heal) then return false end
        for key, actor in pairs(side.actors) do
            if type(key) ~= "string" or key == "" or not ValidateStoredActor(actor) then return false end
        end
    end
    return true
end

local function ValidateStoredStatsV3(source)
    if not ValidateStoredLegacyStats(source, 3) then return false end
    if not ValidateStoredSharedHealingV1(source.sharedHealing) then return false end
    local projection = source.identityProjection
    if type(projection) ~= "table" or tonumber(projection.schemaVersion) ~= 1
        or type(projection.actorIdByToken) ~= "table"
        or type(projection.targetRefIdByToken) ~= "table"
        or type(projection.actorsById) ~= "table"
        or type(projection.targetRefsById) ~= "table"
        or type(projection.breakdowns) ~= "table" then return false end
    -- A degraded projection is never a valid fast-adoption candidate. Force the
    -- sanitizer to rebuild SharedHealing from the compatibility buckets and to
    -- reset the identity projection rather than preserving partial v3 writes.
    if projection.needsRebuild == true or projection.projectionState == "DEGRADED" then return false end
    return true
end

local function SanitizeStatsV2(source)
    if type(source) ~= "table" or tonumber(source.schemaVersion) ~= 2 then return nil end
    local result = U.DeepCopy(defaultStats)
    local repaired = 0
    result.lastSaveAt = NonNegativeNumber(source.lastSaveAt, 0)

    for _, modeName in ipairs({ "PVP", "PVE" }) do
        if source[modeName] ~= nil and type(source[modeName]) ~= "table" then repaired = repaired + 1 end
        local sourceMode = type(source[modeName]) == "table" and source[modeName] or {}
        local mode = result[modeName]
        mode.epochStart = NonNegativeNumber(sourceMode.epochStart, 0)
        for _, summaryName in ipairs({ "pending", "thirdParty" }) do
            if sourceMode[summaryName] ~= nil and type(sourceMode[summaryName]) ~= "table" then repaired = repaired + 1 end
            local sourceSummary = type(sourceMode[summaryName]) == "table" and sourceMode[summaryName] or {}
            local summary = mode[summaryName]
            for _, metric in ipairs({ "events", "damage", "taken", "heal" }) do
                summary[metric] = NonNegativeNumber(sourceSummary[metric], 0)
            end
        end

        for _, sideName in ipairs({ "friendly", "enemy" }) do
            if sourceMode[sideName] ~= nil and type(sourceMode[sideName]) ~= "table" then repaired = repaired + 1 end
            local sourceSide = type(sourceMode[sideName]) == "table" and sourceMode[sideName] or {}
            local side = mode[sideName]
            local sourceSideActive = type(sourceSide.active) == "table" and sourceSide.active or {}
            if sourceSide.active ~= nil and type(sourceSide.active) ~= "table" then repaired = repaired + 1 end
            side.active.damage = SanitizeActive(sourceSideActive.damage)
            side.active.taken = SanitizeActive(sourceSideActive.taken)
            side.active.heal = SanitizeActive(sourceSideActive.heal)
            local sums = { damage = 0, taken = 0, heal = 0, kills = 0 }
            if sourceSide.actors ~= nil and type(sourceSide.actors) ~= "table" then repaired = repaired + 1 end
            local sourceActors = type(sourceSide.actors) == "table" and sourceSide.actors or {}
            for key, sourceActor in pairs(sourceActors) do
                -- Runtime actor keys are stable string IDs/names. Reject exotic
                -- table/function keys from a damaged save instead of allowing them
                -- to leak into sorting, alias resolution or the serializer.
                if type(key) == "string" and key ~= "" then
                    local actor = SanitizeActorV2(sourceActor, key)
                    if actor ~= nil then
                        side.actors[key] = actor
                        for metric in pairs(sums) do sums[metric] = sums[metric] + actor[metric] end
                    else
                        repaired = repaired + 1
                    end
                else
                    repaired = repaired + 1
                end
            end
            if sourceSide.totals ~= nil and type(sourceSide.totals) ~= "table" then repaired = repaired + 1 end
            local sourceTotals = type(sourceSide.totals) == "table" and sourceSide.totals or {}
            for metric in pairs(sums) do
                local stored = NonNegativeNumber(sourceTotals[metric], 0)
                -- Keep a larger aggregate if one actor row was damaged, but never
                -- allow the side total to be lower than the surviving ranking rows.
                side.totals[metric] = math.max(stored, sums[metric])
                if stored < sums[metric] then repaired = repaired + 1 end
            end
        end

        mode.closure.friendlyDamageVsEnemyTaken = PairClosure(
            mode.friendly.totals.damage, mode.enemy.totals.taken)
        mode.closure.enemyDamageVsFriendlyTaken = PairClosure(
            mode.enemy.totals.damage, mode.friendly.totals.taken)
    end

    if repaired > 0 then
        if D.State ~= nil and D.State.dirty ~= nil then D.State.dirty.statsSave = true end
        if D.Diagnostics ~= nil and D.Diagnostics.AddWarning ~= nil then
            D.Diagnostics:AddWarning("stats", "已修复损坏的统计记录：" .. tostring(repaired))
        end
    end
    return result
end

local function MigrateStatsV2ToV3(source)
    local legacy = nil
    if ValidateStoredStatsV2(source) then
        legacy = source
    else
        legacy = SanitizeStatsV2(source)
    end
    if legacy == nil then return nil end
    legacy.schemaVersion = 3
    legacy.sharedHealing = BuildSharedHealingFromLegacy(legacy)
    legacy.identityProjection = NewIdentityProjectionStats()
    legacy.identityProjection.migration.sourceSchema = 2
    return legacy
end

local function SanitizeStatsV3(source)
    if type(source) ~= "table" or tonumber(source.schemaVersion) ~= 3 then return nil end
    local legacySource = {
        schemaVersion = 2,
        PVP = source.PVP,
        PVE = source.PVE,
        lastSaveAt = source.lastSaveAt,
    }
    local result = SanitizeStatsV2(legacySource)
    if result == nil then return nil end
    result.schemaVersion = 3
    result.sharedHealing = SanitizeSharedHealingV1(source.sharedHealing, result)
    result.identityProjection = SanitizeIdentityProjectionV1(source.identityProjection)
    if result.identityProjection.needsRebuild == true
        or result.identityProjection.projectionState == "DEGRADED" then
        result.sharedHealing = BuildSharedHealingFromLegacy(result)
        result.identityProjection = NewIdentityProjectionStats()
        result.identityProjection.projectionState = "READY"
        result.identityProjection.needsRebuild = false
    end
    return result
end

local function MigrateActorStatsV1(source)
    local actor = NewActorStats(source and source.name or "未知")
    source = type(source) == "table" and source or {}
    actor.damage = tonumber(source.damage) or 0
    actor.taken = tonumber(source.taken) or 0
    actor.heal = tonumber(source.heal) or 0
    actor.kills = tonumber(source.kills) or 0
    actor.provisional = source.provisional == true
    actor.active = U.MergeDefaults(U.DeepCopy(source.active or {}), actor.active)
    actor.legacyDetailsDiscarded = true
    return actor
end

local function MigrateStatsV1(source)
    if type(source) ~= "table" or tonumber(source.schemaVersion) ~= 1 then return nil end
    local migrated = NewStatsV2Root()
    migrated.lastSaveAt = tonumber(source.lastSaveAt) or 0
    for _, modeName in ipairs({ "PVP", "PVE" }) do
        local oldMode = source[modeName]
        local newMode = migrated[modeName]
        if type(oldMode) == "table" then
            newMode.epochStart = tonumber(oldMode.epochStart) or newMode.epochStart
            newMode.pending = U.MergeDefaults(U.DeepCopy(oldMode.pending or {}), newMode.pending)
            newMode.thirdParty = U.MergeDefaults(U.DeepCopy(oldMode.thirdParty or {}), newMode.thirdParty)
            newMode.closure = U.MergeDefaults(U.DeepCopy(oldMode.closure or {}), newMode.closure)
            for _, sideName in ipairs({ "friendly", "enemy" }) do
                local oldSide = oldMode[sideName]
                local newSide = newMode[sideName]
                if type(oldSide) == "table" then
                    newSide.totals = U.MergeDefaults(U.DeepCopy(oldSide.totals or {}), newSide.totals)
                    newSide.active = U.MergeDefaults(U.DeepCopy(oldSide.active or {}), newSide.active)
                    for key, oldActor in pairs(type(oldSide.actors) == "table" and oldSide.actors or {}) do
                        if type(key) == "string" and key ~= "" and type(oldActor) == "table" then
                            newSide.actors[key] = MigrateActorStatsV1(oldActor)
                        end
                    end
                end
            end
        end
    end
    migrated.schemaVersion = 2
    -- Migration is not a trust boundary. Old saves may contain negative,
    -- non-finite or type-corrupted fields, so pass the converted structure
    -- through the v2 sanitizer and then construct the explicit v3 projections.
    local sanitized = SanitizeStatsV2(migrated) or NewStatsV2Root()
    return MigrateStatsV2ToV3(sanitized) or U.DeepCopy(defaultStats)
end

local function ParseStoredStatsCandidate(raw, slot, countDiagnostics)
    local payload, sequence, enveloped = P.UnwrapStatsPayload(raw)
    local sanitized = nil
    local suffix = ""
    local repaired = false
    local migratedFrom = nil
    local payloadSchema = type(payload) == "table" and tonumber(payload.schemaVersion) or nil
    if payloadSchema == 3 then
        if ValidateStoredStatsV3(payload) then
            sanitized = payload
            suffix = "_v3_fast"
            if countDiagnostics ~= false then
                D.Diagnostics.counters.fastStatsLoads =
                    (tonumber(D.Diagnostics.counters.fastStatsLoads) or 0) + 1
            end
        else
            sanitized = SanitizeStatsV3(payload) or U.DeepCopy(defaultStats)
            suffix = "_v3_repaired"
            repaired = true
            if countDiagnostics ~= false then
                D.Diagnostics.counters.repairedStatsLoads =
                    (tonumber(D.Diagnostics.counters.repairedStatsLoads) or 0) + 1
            end
        end
    elseif payloadSchema == 2 then
        sanitized = MigrateStatsV2ToV3(payload)
        if sanitized ~= nil then
            suffix = "_v2"
            migratedFrom = 2
        end
    else
        sanitized = MigrateStatsV1(payload)
        if sanitized ~= nil then
            suffix = "_v1"
            migratedFrom = 1
        end
    end
    if sanitized == nil then return nil end
    return {
        data = sanitized,
        slot = slot,
        sequence = sequence,
        enveloped = enveloped,
        payloadSchema = payloadSchema,
        repaired = repaired,
        migratedFrom = migratedFrom,
        source = tostring(slot or "unknown") .. suffix,
    }
end

local function LoadStatsWithMigration()
    if type(D.State.stats) == "table" then
        local memorySchema = tonumber(D.State.stats.schemaVersion)
        if memorySchema == 3 then
            if ValidateStoredStatsV3(D.State.stats) then
                D.Diagnostics.counters.fastStatsLoads =
                    (tonumber(D.Diagnostics.counters.fastStatsLoads) or 0) + 1
                return D.State.stats, "memory_v3_fast"
            end
            D.Diagnostics.counters.repairedStatsLoads =
                (tonumber(D.Diagnostics.counters.repairedStatsLoads) or 0) + 1
            return SanitizeStatsV3(D.State.stats) or U.DeepCopy(defaultStats), "memory_v3"
        elseif memorySchema == 2 then
            local migrated = MigrateStatsV2ToV3(D.State.stats)
            if migrated ~= nil then return migrated, "memory_v2" end
        end
        local migrated = MigrateStatsV1(D.State.stats)
        if migrated ~= nil then return migrated, "memory_v1" end
    end

    local function ParseCandidate(raw, slot)
        return ParseStoredStatsCandidate(raw, slot, true)
    end

    local head = P.LoadRaw(P.Key("stats_head", "primary"))
    if type(head) == "table" and tonumber(head.schemaVersion) == 1
        and (head.slot == "primary" or head.slot == "backup") then
        local candidate = ParseCandidate(P.LoadRaw(P.Key("stats", head.slot)), head.slot)
        if candidate ~= nil and candidate.enveloped
            and candidate.sequence == math.max(0, math.floor(tonumber(head.sequence) or -1)) then
            P.statsSequence = candidate.sequence
            P.statsActiveSlot = candidate.slot
            D.Diagnostics.counters.statsHeadHits =
                (tonumber(D.Diagnostics.counters.statsHeadHits) or 0) + 1
            return candidate.data, candidate.source .. "_rotating"
        end
    end
    D.Diagnostics.counters.statsHeadFallbacks =
        (tonumber(D.Diagnostics.counters.statsHeadFallbacks) or 0) + 1

    local loaded = {}
    for _, slot in ipairs({ "primary", "backup", "pending" }) do
        local candidate = ParseCandidate(P.LoadRaw(P.Key("stats", slot)), slot)
        if candidate ~= nil then loaded[#loaded + 1] = candidate end
    end

    local best = nil
    for _, candidate in ipairs(loaded) do
        if candidate.enveloped then
            if best == nil or not best.enveloped
                or candidate.sequence > best.sequence then
                best = candidate
            end
        elseif best == nil then
            best = candidate
        elseif not best.enveloped then
            local priority = { primary = 3, pending = 2, backup = 1 }
            if (priority[candidate.slot] or 0) > (priority[best.slot] or 0) then
                best = candidate
            end
        end
    end
    if best ~= nil then
        P.statsSequence = best.enveloped and best.sequence or 0
        P.statsActiveSlot = (best.slot == "primary" or best.slot == "backup") and best.slot or nil
        return best.data, best.source .. (best.enveloped and "_rotating" or "")
    end
    P.statsSequence = 0
    P.statsActiveSlot = nil
    return U.DeepCopy(defaultStats), "default"
end

D.State.stats, D.State.statsLoadSource = LoadStatsWithMigration()


-- v0.1.8 deliberately performs no automatic subtraction based on ability
-- name/id -1. The closed combat API does not prove that -1 uniquely identifies
-- fall or other environmental damage, so destructive migration would risk
-- deleting legitimate player, unknown-source or special-skill statistics.

local function ResetTransientStatsTiming(statsRoot)
    for _, modeName in ipairs({ "PVP", "PVE" }) do
        local modeStats = type(statsRoot) == "table" and statsRoot[modeName] or nil
        if type(modeStats) == "table" then
            modeStats.epochStart = 0
            for _, sideName in ipairs({ "friendly", "enemy" }) do
                local side = modeStats[sideName]
                if type(side) == "table" then
                    for _, metric in ipairs({ "damage", "taken", "heal" }) do
                        if side.active and side.active[metric] then
                            side.active[metric].last = nil
                            side.active[metric].startedAt = nil
                        end
                    end
                    for _, actor in pairs(side.actors or {}) do
                        for _, metric in ipairs({ "damage", "taken", "heal" }) do
                            if actor.active and actor.active[metric] then
                                actor.active[metric].last = nil
                                actor.active[metric].startedAt = nil
                            end
                        end
                    end
                end
            end
        end
    end
    local shared = type(statsRoot) == "table" and statsRoot.sharedHealing or nil
    if type(shared) == "table" then
        for _, sideName in ipairs({ "friendly", "enemy" }) do
            local side = shared[sideName]
            if type(side) == "table" then
                if side.active and side.active.heal then
                    side.active.heal.last = nil
                    side.active.heal.startedAt = nil
                end
                for _, actor in pairs(side.actors or {}) do
                    if actor.active and actor.active.heal then
                        actor.active.heal.last = nil
                        actor.active.heal.startedAt = nil
                    end
                end
            end
        end
    end
end

-- A persisted session may have been saved with a process-local clock. Totals
-- remain valid, but open active segments and clear cut-offs do not.
if not string.find(tostring(D.State.statsLoadSource or ""), "memory_", 1, true) then
    ResetTransientStatsTiming(D.State.stats)
end
if string.find(tostring(D.State.statsLoadSource or ""), "v1", 1, true) ~= nil
    or string.find(tostring(D.State.statsLoadSource or ""), "v2", 1, true) ~= nil
    or string.find(tostring(D.State.statsLoadSource or ""), "repaired", 1, true) ~= nil then
    D.State.dirty.statsSave = true
end

D.Stats = D.Stats or {}
local S = D.Stats
S.breakdownMutationRevision = math.max(0, math.floor(tonumber(S.breakdownMutationRevision) or 0))
S.breakdownCompactedRevision = tonumber(S.breakdownCompactedRevision)
S.breakdownCompactedStatsRoot = S.breakdownCompactedStatsRoot == D.State.stats and D.State.stats or nil
S.breakdownDirtyActors = {}
S.breakdownDirtyQueue = {}
S.breakdownDirtyQueueHead = 1
S.breakdownDirtyQueueTail = 0
S.breakdownFullAuditRequested = S.breakdownCompactedStatsRoot ~= D.State.stats
S.statsMutationRevision = math.max(0, math.floor(tonumber(S.statsMutationRevision) or 0))
S.closureDirty = type(S.closureDirty) == "table" and S.closureDirty or {}
S.persistenceSnapshotJob = nil
S.persistenceReadyPayload = nil
D.Diagnostics.counters.sharedHealingAuthorityWrites =
    tonumber(D.Diagnostics.counters.sharedHealingAuthorityWrites) or 0

function S:MigrateStatsV2ToV3ForTests(source)
    return MigrateStatsV2ToV3(U.DeepCopy(source))
end

function S:SanitizeStatsV3ForTests(source)
    return SanitizeStatsV3(U.DeepCopy(source))
end

function S:BuildSharedHealingFromLegacyForTests(source)
    return BuildSharedHealingFromLegacy(source)
end

-- prep16 audit adapter: unwrap a detached formal Stats v3 candidate without
-- synchronously validating or copying the full tree in an OnUpdate step. Exact
-- validity is established by the incremental path comparison against a fully
-- validated shard recovery. Legacy v1/v2 slots are reported explicitly and
-- must first pass the existing startup migration plus one formal v3 save before
-- they can participate in a shard switch candidate.
function S:ParsePersistedStatsCandidateForAudit(raw, slot)
    local payload, sequence, enveloped = P.UnwrapStatsPayload(raw)
    if type(payload) ~= "table" then return nil end
    local payloadSchema = tonumber(payload.schemaVersion)
    return {
        data = payloadSchema == 3 and payload or nil,
        slot = slot or "audit",
        sequence = sequence,
        enveloped = enveloped,
        payloadSchema = payloadSchema,
        repaired = false,
        migratedFrom = nil,
        legacyRequiresMigration = payloadSchema == 1 or payloadSchema == 2,
        source = tostring(slot or "audit") .. "_v" .. tostring(payloadSchema or "unknown"),
    }
end


-- Formal persisted-root adoption boundary. The shard switch module may call
-- this only before Runtime starts and only after full source/digest equality is
-- proven. All product caches are invalidated as one transaction; any failure
-- restores the rotating root and re-invalidates derived state.
function S:AdoptPersistedStatsRoot(root, source)
    if type(root) ~= "table" or tonumber(root.schemaVersion) ~= 3
        or not ValidateStoredStatsV3(root) then
        return false, "INVALID_PERSISTED_STATS_ROOT"
    end
    if D.Runtime ~= nil and D.Runtime.started == true then
        return false, "RUNTIME_ALREADY_STARTED"
    end

    local previousRoot = D.State.stats
    local previousSource = D.State.statsLoadSource
    local previousDirty = D.State.dirty and D.State.dirty.statsSave
    local ok, err = xpcall(function()
        D.State.stats = root
        D.State.statsLoadSource = tostring(source or "shard_formal")
        self.replayWorkingStats = nil
        self:MarkBreakdownsMutated(true)
        if D.StatsV3 ~= nil and type(D.StatsV3.OnAuthorityRootReplaced) == "function" then
            D.StatsV3:OnAuthorityRootReplaced(root, "PERSISTED_ROOT_ADOPTED")
        end
        if D.StatsRead ~= nil and type(D.StatsRead.OnAuthorityRootReplaced) == "function" then
            D.StatsRead:OnAuthorityRootReplaced(root)
        end
        if D.IdentityShadow ~= nil and type(D.IdentityShadow.OnAuthorityRootReplaced) == "function" then
            D.IdentityShadow:OnAuthorityRootReplaced(root)
        end
        if D.Analysis ~= nil and type(D.Analysis.RebuildBossFromStats) == "function" then
            D.Analysis:RebuildBossFromStats()
        end
        if D.State.dirty ~= nil then D.State.dirty.statsSave = previousDirty == true end
        D.MarkViewDirty()
    end, Boot.SafeTraceback)
    if ok then return true, previousRoot, previousSource end

    D.State.stats = previousRoot
    D.State.statsLoadSource = previousSource
    self.replayWorkingStats = nil
    self:MarkBreakdownsMutated(true)
    if D.StatsV3 ~= nil and type(D.StatsV3.OnAuthorityRootReplaced) == "function" then
        pcall(D.StatsV3.OnAuthorityRootReplaced, D.StatsV3, previousRoot, "PERSISTED_ROOT_ROLLBACK")
    end
    if D.State.dirty ~= nil then D.State.dirty.statsSave = previousDirty == true end
    D.MarkViewDirty()
    return false, tostring(err)
end

-- ActorId/TargetRef preparation observer. The authoritative write always
-- completes first. The observer is invoked only in diagnostics mode and is
-- protected so a shadow-model defect can never interrupt production totals.
S.identityShadowObserver = nil
S.statsV3Observer = nil

function S:SetStatsV3Observer(observer)
    if observer ~= nil and type(observer) ~= "table" then return false end
    self.statsV3Observer = observer
    return true
end

function S:SetIdentityShadowObserver(observer)
    if observer ~= nil and type(observer) ~= "table" then return false end
    self.identityShadowObserver = observer
    return true
end

local function NotifyStatsV3(stats, mode, sideName, entity, metric, amount, event, actor, side)
    local observer = stats.statsV3Observer
    if type(observer) ~= "table" or observer.failed == true
        or type(observer.OnLegacyMetricApplied) ~= "function" then return end
    local authorityRoot = stats.replayWorkingStats or D.State.stats
    local ok, err = pcall(
        observer.OnLegacyMetricApplied, observer,
        mode, sideName, entity, metric, amount, event, actor, side, authorityRoot
    )
    if not ok then
        if type(observer.DisableAfterFailure) == "function" then
            pcall(observer.DisableAfterFailure, observer, err, authorityRoot)
        elseif D.Diagnostics ~= nil and type(D.Diagnostics.AddWarning) == "function" then
            D.Diagnostics:AddWarning("stats_v3", "Stats v3 观察器异常：" .. tostring(err))
        end
    end
end

local function NotifyIdentityShadow(stats, mode, sideName, entity, metric, amount, event, actor, side)
    if D.State == nil or D.State.config == nil or D.State.config.diagnosticsEnabled ~= true then return end
    local observer = stats.identityShadowObserver
    if type(observer) ~= "table" or observer.failed == true
        or type(observer.OnLegacyMetricApplied) ~= "function" then return end
    local authorityRoot = stats.replayWorkingStats or D.State.stats
    local ok, err = pcall(
        observer.OnLegacyMetricApplied, observer,
        mode, sideName, entity, metric, amount, event, actor, side, authorityRoot
    )
    if not ok then
        if type(observer.DisableAfterFailure) == "function" then
            pcall(observer.DisableAfterFailure, observer, err)
        elseif D.Diagnostics ~= nil and type(D.Diagnostics.AddWarning) == "function" then
            D.Diagnostics:AddWarning("identity_shadow", "影子观察器异常：" .. tostring(err))
        end
    end
end

------------------------------------------------------------------------
-- 排行榜增量索引（问题 2 修复）
--
-- 数据所有权：本缓存归 D.Stats 所有，是统计树的派生视图，绝不反向持有
--   统计树（只保存 item.key 与 item.actor 引用，后者由统计树本身拥有）。
-- 生命周期：随统计树同生共死；ClearAll/恢复快照时通过版本号自动失效。
-- 是否允许失效：允许。缓存只是加速 UI 读取，任何时刻都可安全回退为
--   一次完整 BuildRankingFull 重建，结果完全一致。
-- 是否可重建：可。事件到达只递增 statsMutationRevision 并标记对应角色
--   为脏（AddMetric → MarkBreakdownsMutated），UI 读取已提交的排行榜；
--   空闲帧由 Runtime 调用 StepRankingRebuild 按预算分帧重算。
-- 为什么不能全表扫描：长期累计后历史角色可能上万，每次 UI 刷新（每
--   500ms）全量遍历会持续制造 CPU 峰值；缓存把"遍历全部历史角色"限制
--   在版本变更后的空闲分帧重建，UI 刷新本身是 O(缓存行数)。
-- 单帧预算：StepRankingRebuild 每帧只处理固定数量的 actor（高负载时
--   减半），重建期间旧缓存继续供 UI 显示，完成后原子切换。
------------------------------------------------------------------------
local RANKING_CACHE_LAYOUT_VERSION = 2
if tonumber(S.rankingCacheLayoutVersion) ~= RANKING_CACHE_LAYOUT_VERSION then
    -- 排行榜缓存是可重建派生数据。布局升级时直接丢弃旧缓存，避免热重载
    -- 后为了迁移一个可能很大的 dirty 哈希表而在单帧做全量扫描。
    S.rankingCache = {}
end
S.rankingCacheLayoutVersion = RANKING_CACHE_LAYOUT_VERSION
S.rankingCache = type(S.rankingCache) == "table" and S.rankingCache or {}
S.rankingCachesDirty = false
S.rankingStructureRevision = math.max(0, math.floor(tonumber(S.rankingStructureRevision) or 0))
S.rankingRebuildJobs = {}
S.rankingRebuildQueue = {}
S.rankingRebuildQueueHead = 1
S.rankingRebuildQueueTail = 0
S.rankingRebuildJob = nil
S.rankingPatchCursorKey = nil
-- 缓存键由 (mode, sideName, page, alwaysShowSelf) 组成；版本号由
-- statsMutationRevision（任何统计变更）与 A.revision（排除/Boss 投影
-- 变更）共同决定。命中时 UI 刷新不触碰任何历史角色表。
local RANKING_CACHE_KEY_LOOKUP = {}
for _, modeName in ipairs({ "PVP", "PVE" }) do
    RANKING_CACHE_KEY_LOOKUP[modeName] = {}
    for _, sideValue in ipairs({ "friendly", "enemy" }) do
        local sideLookup = {}
        RANKING_CACHE_KEY_LOOKUP[modeName][sideValue] = sideLookup
        for _, pageValue in ipairs({ "DAMAGE", "TAKEN", "HEAL", "KILLS" }) do
            sideLookup[pageValue] = {
                [false] = modeName .. "|" .. sideValue .. "|" .. pageValue .. "|0",
                [true] = modeName .. "|" .. sideValue .. "|" .. pageValue .. "|1",
            }
        end
    end
end

function S:RankingCacheKey(mode, sideName, page)
    local byMode = RANKING_CACHE_KEY_LOOKUP[mode]
    local bySide = byMode and byMode[sideName] or nil
    local byPage = bySide and bySide[page] or nil
    if byPage ~= nil then return byPage[D.State.config.alwaysShowSelf == true] end
    -- 仅兼容未知扩展页面；正式四种榜单全部命中上面的常量字符串。
    return tostring(mode or "") .. "|" .. tostring(sideName or "") .. "|"
        .. tostring(page or "") .. "|" .. (D.State.config.alwaysShowSelf == true and "1" or "0")
end

function S:RankingVersion()
    -- 普通累计值变化由 actor 脏集合增量修补，不再让所有排行榜版本失效。
    -- 只有统计树引用变化或分析过滤语义变化才触发全量分帧重建。
    return tostring(tonumber(self.rankingStructureRevision) or 0)
        .. ":" .. tostring(tonumber(A and A.revision) or 0)
end

local RankingItemBetter

-- 刷新已缓存 item 的动态显示字段（rate/percent/rank）。排序顺序与累计值
-- 由缓存保证；rate 依赖当前活动时间窗口。治疗榜切换到 SharedHealing
-- Authority 后，item.actor 同样直接引用正式治疗 actor，因此所有非 kills
-- 指标都可以 O(1) 精确刷新活动速率，不再保留旧双桶合成快照。
local function RefreshRankingItemDynamicFields(self, item, now, total, metric)
    if metric ~= "kills" and type(item.actor) == "table" then
        local actorActive = item.actor.active and item.actor.active[metric]
        if type(actorActive) == "table" then
            local activeMs = self:GetActiveMs(actorActive, now, D.State.config.personalWindowMs)
            item.rate = (tonumber(item.value) or 0) / math.max(activeMs / 1000, 1)
        end
    end
    item.percent = total > 0 and (tonumber(item.value) or 0) / total * 100 or 0
end


local function RankingMetricForPage(page)
    if page == "TAKEN" then return "taken" end
    if page == "HEAL" then return "heal" end
    if page == "KILLS" then return "kills" end
    return "damage"
end

local function RankingCacheMatchesMetric(cache, mode, sideName, metric)
    if type(cache) ~= "table" or cache.sideName ~= sideName or cache.metric ~= metric then return false end
    if metric == "heal" then return true end
    return cache.mode == mode
end

-- 计算单个 actor 的当前排行榜行。该函数只读取一个 actor（治疗读取同 key
-- 的 PVP/PVE 两个 actor），用于把热事件的影响增量修补进 ≤150 行缓存。
function S:BuildRankingItemForKey(mode, sideName, page, key, now)
    now = tonumber(now) or U.NowMs()
    local metric = RankingMetricForPage(page)
    local value, activeMs, actorView, name, rawValue, provisional, actor
    local side
    if metric == "heal" then
        local reads = D.StatsRead
        local sharedSide = type(reads) == "table" and reads:GetSharedHealingSide(sideName) or nil
        actor = sharedSide and sharedSide.actors and sharedSide.actors[key] or nil
        value = tonumber(actor and actor.heal) or 0
        if value <= 0 then return nil end
        activeMs = self:GetActiveMs(actor.active and actor.active.heal,
            now, D.State.config.personalWindowMs)
        name = type(reads) == "table" and reads:GetSharedHealingDisplayName(key, actor)
            or (actor.name or "未知")
        rawValue = value
        provisional = actor.provisional == true
    else
        local modeStats = self:GetMode(mode)
        side = modeStats and modeStats[sideName] or nil
        actor = side and side.actors and side.actors[key] or nil
        value = tonumber(actor and actor[metric]) or 0
        if value <= 0 then return nil end
        activeMs = metric ~= "kills" and self:GetActiveMs(actor.active and actor.active[metric],
            now, D.State.config.personalWindowMs) or 0
        rawValue = value
        name = actor.name or "未知"
        provisional = actor.provisional == true
        if metric == "damage" then
            value, activeMs, actorView = self:GetDamageAnalysisValue(mode, sideName, actor, side, now, key)
            if value <= 0 then return nil end
        end
    end
    local rateUnavailable = type(actorView) == "table" and actorView.rateUnavailable == true
    return {
        key = key,
        name = name,
        value = value,
        rawValue = rawValue,
        rate = metric ~= "kills" and not rateUnavailable and value / math.max(activeMs / 1000, 1) or 0,
        percent = 0,
        actor = actor,
        analysisView = actorView,
    }
end

local function IsRankingSelfItem(item)
    if type(item) ~= "table" then return false end
    local normalized = U.NormalizeName(item.name)
    return item.key == D.Identity.entityKey
        or normalized == U.NormalizeName(D.Identity.playerName)
        or normalized == U.NormalizeName(D.Identity.playerNameWithWorld)
end

local function QueueRankingDirtyActor(container, actorKey)
    container.dirtyActors = type(container.dirtyActors) == "table" and container.dirtyActors or {}
    if container.dirtyActors[actorKey] == true then return false end
    container.dirtyActors[actorKey] = true
    container.dirtyActorQueue = type(container.dirtyActorQueue) == "table" and container.dirtyActorQueue or {}
    local tail = (tonumber(container.dirtyActorQueueTail) or 0) + 1
    container.dirtyActorQueueTail = tail
    container.dirtyActorQueue[tail] = actorKey
    container.dirtyActorQueueHead = math.max(1, math.floor(tonumber(container.dirtyActorQueueHead) or 1))
    return true
end

-- 只修补固定数量的脏 actor。隐藏窗口可能数分钟不读取，旧实现会在再次
-- 打开时一次处理所有累计脏角色；现在脏集合拥有显式队列，UI 与 OnUpdate
-- 每次只消费有限数量，结果在数个小批次内逐步追上实时统计。
function S:PatchRankingCache(cache, actorBudget)
    if type(cache) ~= "table" then return true, 0 end
    local dirty = cache.dirtyActors
    local queue = cache.dirtyActorQueue
    local head = math.max(1, math.floor(tonumber(cache.dirtyActorQueueHead) or 1))
    local tail = math.max(0, math.floor(tonumber(cache.dirtyActorQueueTail) or 0))
    if type(dirty) ~= "table" or type(queue) ~= "table" or head > tail then
        return true, 0
    end

    local budget = math.max(1, math.floor(tonumber(actorBudget) or 32))
    local result = type(cache.result) == "table" and cache.result or {}
    local now = U.NowMs()
    local processed = 0
    while processed < budget and head <= tail do
        local key = queue[head]
        queue[head] = nil
        head = head + 1
        if key ~= nil and dirty[key] == true then
            dirty[key] = nil
            for index = #result, 1, -1 do
                if result[index].key == key then table.remove(result, index) end
            end
            local item = self:BuildRankingItemForKey(cache.mode, cache.sideName, cache.page, key, now)
            if item ~= nil then result[#result + 1] = item end
            processed = processed + 1
        end
    end
    cache.dirtyActorQueueHead = head
    if head > tail then
        cache.dirtyActors = {}
        cache.dirtyActorQueue = {}
        cache.dirtyActorQueueHead = 1
        cache.dirtyActorQueueTail = 0
    elseif head > 2048 and head > math.floor(tail / 2) then
        -- 持续团战中脏 actor 队列可能永远无法完全清空，head/tail 会不断
        -- 增长并把一张只有几十到几百个活跃项的队列表扩成很大的稀疏数组。
        -- 低频压缩只复制仍然有效的尾部项，规模受当前脏 actor 数量约束，
        -- 不扫描历史统计，也不会改变处理顺序。
        local compacted = {}
        local newTail = 0
        for index = head, tail do
            local queuedKey = queue[index]
            if queuedKey ~= nil and dirty[queuedKey] == true then
                newTail = newTail + 1
                compacted[newTail] = queuedKey
            end
        end
        cache.dirtyActorQueue = compacted
        cache.dirtyActorQueueHead = 1
        cache.dirtyActorQueueTail = newTail
        queue = compacted
        head = 1
        tail = newTail
    end

    if processed > 0 or (tonumber(cache.pendingTotalDelta) or 0) ~= 0 then
        -- 总量读取 O(1)。排除目标投影无法从 side.totals 直接推导，因此使用
        -- AddMetric 精确累计的 pendingTotalDelta。
        if cache.metric == "heal" then
            local pvp = self:GetMode("PVP")
            local pve = self:GetMode("PVE")
            cache.total = (tonumber(pvp and pvp[cache.sideName] and pvp[cache.sideName].totals.heal) or 0)
                + (tonumber(pve and pve[cache.sideName] and pve[cache.sideName].totals.heal) or 0)
        elseif cache.analysisKind == "BOSS" then
            local boss = A:GetBossTarget()
            cache.total = tonumber(boss and boss.total) or 0
        elseif cache.analysisKind == "EXCLUDED" then
            cache.total = math.max(0, (tonumber(cache.total) or 0)
                + (tonumber(cache.pendingTotalDelta) or 0))
        else
            local modeStats = self:GetMode(cache.mode)
            cache.total = tonumber(modeStats and modeStats[cache.sideName]
                and modeStats[cache.sideName].totals[cache.metric]) or 0
        end
        cache.pendingTotalDelta = 0

        table.sort(result, RankingItemBetter)
        local limit = math.max(1, tonumber(D.Const.MAX_RANKING_ROWS) or 150)
        local pinnedSelf = nil
        if cache.sideName == "friendly" and D.State.config.alwaysShowSelf then
            for _, item in ipairs(result) do
                if IsRankingSelfItem(item) then pinnedSelf = item break end
            end
        end
        while #result > limit do table.remove(result) end
        if pinnedSelf ~= nil then
            local included = false
            for _, item in ipairs(result) do if item == pinnedSelf then included = true break end end
            if not included then result[#result + 1] = pinnedSelf end
        end
        for index, item in ipairs(result) do
            item.rank = index
            RefreshRankingItemDynamicFields(self, item, now, cache.total or 0, cache.metric)
        end
        cache.result = result
        cache.version = self:RankingVersion()
    end
    return head > tail, processed
end

function S:StepRankingCachePatches(actorBudget)
    if self.rankingCachesDirty ~= true then return true, 0 end
    local remaining = math.max(1, math.floor(tonumber(actorBudget) or 64))
    local processed = 0
    local allDone = true
    local caches = self.rankingCache or {}
    local startKey = self.rankingPatchCursorKey
    -- Lua 5.1 的 next(table, key) 要求 key 仍存在于 table。缓存被页面切换、
    -- 清空或重算替换后，旧游标可能已失效；直接调用会抛出 invalid key to next，
    -- 进而让全局 OnUpdate 熔断。这里只在低频分帧调度入口保护一次。
    local okNext, key = pcall(next, caches, startKey)
    if not okNext then
        self.rankingPatchCursorKey = nil
        key = next(caches, nil)
    end
    if key == nil then key = next(caches, nil) end
    local visited = 0
    local cacheCount = U.TableCount(caches)
    while key ~= nil and visited < cacheCount do
        local cache = caches[key]
        local done, used = self:PatchRankingCache(cache, remaining)
        used = tonumber(used) or 0
        processed = processed + used
        remaining = math.max(0, remaining - used)
        if done ~= true then allDone = false end
        self.rankingPatchCursorKey = key
        visited = visited + 1
        if remaining <= 0 then
            allDone = false
            break
        end
        key = next(caches, key)
        if key == nil then key = next(caches, nil) end
    end
    if cacheCount == 0 or allDone then
        self.rankingCachesDirty = false
        self.rankingPatchCursorKey = nil
    end
    return allDone, processed
end

local function MarkRankingContainerDirty(self, container, isCache, mode, sideName, metric,
    actorKey, amount, event)
    if not RankingCacheMatchesMetric(container, mode, sideName, metric) then return end
    if QueueRankingDirtyActor(container, actorKey) and isCache == true then
        self.rankingCachesDirty = true
    end
    if metric == "damage" and container.analysisKind == "EXCLUDED"
        and not A:IsExcluded(event and event.targetName) then
        container.pendingTotalDelta = (tonumber(container.pendingTotalDelta) or 0)
            + (tonumber(amount) or 0)
    end
end

local RANKING_PAGE_BY_METRIC = {
    damage = "DAMAGE",
    taken = "TAKEN",
    heal = "HEAL",
    kills = "KILLS",
}

local function MarkRankingKeyDirty(self, key, mode, sideName, metric, actorKey, amount, event)
    local cache = type(self.rankingCache) == "table" and self.rankingCache[key] or nil
    if type(cache) == "table" then
        MarkRankingContainerDirty(self, cache, true, mode, sideName, metric, actorKey, amount, event)
    end
    local job = type(self.rankingRebuildJobs) == "table" and self.rankingRebuildJobs[key] or nil
    if type(job) == "table" then
        MarkRankingContainerDirty(self, job, false, mode, sideName, metric, actorKey, amount, event)
    end
end

function S:MarkRankingMetricDirty(mode, sideName, metric, actorKey, amount, event)
    if self.replayWorkingStats ~= nil or actorKey == nil then return end
    -- 热路径只直达实际受影响的缓存键。旧实现每次指标变化都会遍历所有
    -- 排行榜缓存与重建任务；页面/阵营越多，单条战斗事件的固定开销越大。
    -- 治疗结果在两个模式页共享，因此同时标记两个 mode 缓存键；其他指标只命中一个键。
    local page = RANKING_PAGE_BY_METRIC[metric]
    if page == nil then return end
    if metric == "heal" then
        MarkRankingKeyDirty(self, self:RankingCacheKey("PVP", sideName, page),
            mode, sideName, metric, actorKey, amount, event)
        MarkRankingKeyDirty(self, self:RankingCacheKey("PVE", sideName, page),
            mode, sideName, metric, actorKey, amount, event)
        return
    end
    MarkRankingKeyDirty(self, self:RankingCacheKey(mode, sideName, page),
        mode, sideName, metric, actorKey, amount, event)
end

function S:MarkStatsMutated(statsRootChanged)
    self.statsMutationRevision = (tonumber(self.statsMutationRevision) or 0) + 1
    if statsRootChanged == true then
        self.modeCacheRoot = nil
        self.modeCache = {}
        self.rankingStructureRevision = (tonumber(self.rankingStructureRevision) or 0) + 1
        self.rankingCache = {}
        self.rankingRebuildJobs = {}
        self.rankingRebuildQueue = {}
        self.rankingRebuildQueueHead = 1
        self.rankingRebuildQueueTail = 0
        self.rankingRebuildJob = nil
        self.rankingCachesDirty = false
        self.rankingPatchCursorKey = nil
    end
    if self.persistenceSnapshotJob ~= nil or self.persistenceReadyPayload ~= nil then
        self.persistenceSnapshotJob = nil
        self.persistenceReadyPayload = nil
        D.Diagnostics.counters.cancelledStatsSnapshots =
            (tonumber(D.Diagnostics.counters.cancelledStatsSnapshots) or 0) + 1
    end
end

function S:MarkBreakdownsMutated(statsRootChanged)
    self.breakdownMutationRevision = (tonumber(self.breakdownMutationRevision) or 0) + 1
    self.breakdownCompactedRevision = nil
    self.breakdownCompactedStatsRoot = nil
    -- 此入口用于整棵统计树替换、角色键合并或旧格式修复，影响范围未知，
    -- 必须安排一次分帧全审计。普通热事件使用 MarkActorBreakdownMutated。
    self.breakdownFullAuditRequested = true
    if statsRootChanged == true then
        self.breakdownCompactState = nil
        self.breakdownDirtyActors = {}
        self.breakdownDirtyQueue = {}
        self.breakdownDirtyQueueHead = 1
        self.breakdownDirtyQueueTail = 0
    end
    self:MarkStatsMutated(statsRootChanged)
end

function S:MarkActorBreakdownMutated(mode, sideName, actorKey, actor, deferStatsMutation)
    self.breakdownMutationRevision = (tonumber(self.breakdownMutationRevision) or 0) + 1
    self.breakdownCompactedRevision = nil
    self.breakdownCompactedStatsRoot = nil
    local composite = table.concat({ tostring(mode), tostring(sideName), tostring(actorKey) }, "|")
    if self.breakdownDirtyActors[composite] == nil then
        local tail = (tonumber(self.breakdownDirtyQueueTail) or 0) + 1
        self.breakdownDirtyQueueTail = tail
        self.breakdownDirtyQueue[tail] = composite
    end
    self.breakdownDirtyActors[composite] = {
        mode = mode, sideName = sideName, actorKey = actorKey,
        actor = actor, statsRoot = D.State.stats,
    }
    if deferStatsMutation ~= true then self:MarkStatsMutated(false) end
end


function S:IsBreakdownCompactionCurrent()
    return self.breakdownCompactState == nil
        and self.breakdownCompactedStatsRoot == D.State.stats
        and tonumber(self.breakdownCompactedRevision) == tonumber(self.breakdownMutationRevision)
end

local function MergeNumberMap(target, source)
    target = type(target) == "table" and target or {}
    source = type(source) == "table" and source or {}
    for key, value in pairs(source) do
        target[key] = (tonumber(target[key]) or 0) + (tonumber(value) or 0)
    end
    return target
end

local function CleanActorActive(active)
    active = type(active) == "table" and active or {}
    local total = math.max(0, U.FiniteNumber(active.total, 0) or 0)
    local startedAt = U.FiniteNumber(active.startedAt, nil)
    local last = U.FiniteNumber(active.last, nil)
    if startedAt == nil or last == nil or last < startedAt then
        startedAt, last = nil, nil
    end
    return { total = total, startedAt = startedAt, last = last }
end

local function MergeActorActive(first, second, windowMs)
    first = CleanActorActive(first)
    second = CleanActorActive(second)
    windowMs = math.max(0, U.FiniteNumber(windowMs, 0) or 0)
    local total = first.total + second.total
    if first.startedAt == nil then
        second.total = total
        return second
    end
    if second.startedAt == nil then
        first.total = total
        return first
    end

    local older, newer = first, second
    if second.startedAt < first.startedAt then older, newer = second, first end
    if newer.startedAt <= older.last + windowMs then
        return {
            total = total,
            startedAt = math.min(older.startedAt, newer.startedAt),
            last = math.max(older.last, newer.last),
        }
    end

    -- The intervals are disjoint. Close the older one at its full idle window
    -- and keep only the newer interval open; using min(start)/max(last) here
    -- would incorrectly count the inactive gap as combat time.
    total = total + math.max(0, older.last + windowMs - older.startedAt)
    return { total = total, startedAt = newer.startedAt, last = newer.last }
end

local function MergeActorRecord(target, source, displayName)
    if type(source) ~= "table" then return type(target) == "table" and target or nil end
    if type(target) ~= "table" then
        target = U.DeepCopy(source)
        if target ~= nil and displayName ~= nil then target.name = displayName end
        return target
    end
    if source == nil then return target end
    target.name = displayName or target.name or source.name
    for _, metric in ipairs({ "damage", "taken", "heal", "kills" }) do
        target[metric] = (tonumber(target[metric]) or 0) + (tonumber(source[metric]) or 0)
    end
    local targetDetails = EnsureActorDetails(target)
    local sourceDetails = EnsureActorDetails(source)
    for _, metric in ipairs({ "damage", "taken", "heal" }) do
        targetDetails[metric].abilities = MergeNumberMap(targetDetails[metric].abilities, sourceDetails[metric].abilities)
    end
    targetDetails.damage.targets = MergeNumberMap(targetDetails.damage.targets, sourceDetails.damage.targets)
    targetDetails.taken.sources = MergeNumberMap(targetDetails.taken.sources, sourceDetails.taken.sources)
    targetDetails.heal.targets = MergeNumberMap(targetDetails.heal.targets, sourceDetails.heal.targets)
    if type(sourceDetails.kills) == "table" or type(targetDetails.kills) == "table"
        or (tonumber(source.kills) or 0) > 0 or (tonumber(target.kills) or 0) > 0 then
        local targetKills = EnsureKillDetails(target)
        local sourceKills = type(sourceDetails.kills) == "table" and sourceDetails.kills
            or { abilities = {}, targets = {} }
        targetKills.abilities = MergeNumberMap(targetKills.abilities, sourceKills.abilities)
        targetKills.targets = MergeNumberMap(targetKills.targets, sourceKills.targets)
    end
    target.active = target.active or {}
    for _, metric in ipairs({ "damage", "taken", "heal" }) do
        target.active[metric] = MergeActorActive(
            target.active[metric],
            source.active and source.active[metric] or nil,
            D.State.config.personalWindowMs
        )
    end
    target.repdpsDetailRevision = math.max(
        tonumber(target.repdpsDetailRevision) or 0,
        tonumber(source.repdpsDetailRevision) or 0
    ) + 1
    return target
end

local function MergeStatsRoot(target, source)
    local function NormalizeRoot(value)
        local schema = type(value) == "table" and tonumber(value.schemaVersion) or nil
        if schema == 3 then return SanitizeStatsV3(value) end
        if schema == 2 then return MigrateStatsV2ToV3(value) end
        if schema == 1 then return MigrateStatsV1(value) end
        return nil
    end
    target = NormalizeRoot(target) or U.DeepCopy(defaultStats)
    source = NormalizeRoot(source) or U.DeepCopy(defaultStats)
    target.lastSaveAt = math.max(tonumber(target.lastSaveAt) or 0, tonumber(source.lastSaveAt) or 0)

    for _, modeName in ipairs({ "PVP", "PVE" }) do
        local targetMode = target[modeName]
        local sourceMode = source[modeName]
        if type(sourceMode) == "table" then
            for _, summaryName in ipairs({ "pending", "thirdParty" }) do
                local targetSummary = targetMode[summaryName] or { events = 0, damage = 0, taken = 0, heal = 0 }
                local sourceSummary = sourceMode[summaryName] or {}
                for _, metric in ipairs({ "events", "damage", "taken", "heal" }) do
                    targetSummary[metric] = (tonumber(targetSummary[metric]) or 0) + (tonumber(sourceSummary[metric]) or 0)
                end
                targetMode[summaryName] = targetSummary
            end

            for _, sideName in ipairs({ "friendly", "enemy" }) do
                local targetSide = targetMode[sideName]
                local sourceSide = sourceMode[sideName]
                if type(sourceSide) == "table" then
                    targetSide.totals = targetSide.totals or { damage = 0, taken = 0, heal = 0, kills = 0 }
                    for _, metric in ipairs({ "damage", "taken", "heal", "kills" }) do
                        targetSide.totals[metric] = (tonumber(targetSide.totals[metric]) or 0)
                            + (tonumber(sourceSide.totals and sourceSide.totals[metric]) or 0)
                    end

                    targetSide.active = targetSide.active or {}
                    for _, metric in ipairs({ "damage", "taken", "heal" }) do
                        local targetActive = targetSide.active[metric] or { total = 0, last = nil, startedAt = nil }
                        local sourceActive = sourceSide.active and sourceSide.active[metric] or nil
                        targetActive.total = (tonumber(targetActive.total) or 0)
                            + (tonumber(sourceActive and sourceActive.total) or 0)
                        targetActive.last = nil
                        targetActive.startedAt = nil
                        targetSide.active[metric] = targetActive
                    end

                    targetSide.actors = targetSide.actors or {}
                    for key, sourceActor in pairs(type(sourceSide.actors) == "table" and sourceSide.actors or {}) do
                        local merged = MergeActorRecord(targetSide.actors[key], sourceActor, sourceActor and sourceActor.name)
                        if merged ~= nil then
                            merged.provisional = merged.provisional == true or (sourceActor and sourceActor.provisional == true)
                            targetSide.actors[key] = merged
                        end
                    end
                end
            end
        end
    end

    target.schemaVersion = 3
    target.sharedHealing = BuildSharedHealingFromLegacy(target)
    target.identityProjection = NewIdentityProjectionStats()
    ResetTransientStatsTiming(target)
    return target
end

function S:MergeStatsRoot(target, source)
    return MergeStatsRoot(target, source)
end

local function RewriteBreakdownKey(map, oldKey, newKey)
    if type(map) ~= "table" or oldKey == newKey or map[oldKey] == nil then return false end
    map[newKey] = (tonumber(map[newKey]) or 0) + (tonumber(map[oldKey]) or 0)
    map[oldKey] = nil
    return true
end

local function RewriteActorCounterpartKeys(actor, oldKey, newKey)
    if type(actor) ~= "table" or type(actor.details) ~= "table" then return false end
    local details = actor.details
    local changed = false
    if type(details.damage) == "table" then
        changed = RewriteBreakdownKey(details.damage.targets, oldKey, newKey) or changed
    end
    if type(details.taken) == "table" then
        changed = RewriteBreakdownKey(details.taken.sources, oldKey, newKey) or changed
    end
    if type(details.heal) == "table" then
        changed = RewriteBreakdownKey(details.heal.targets, oldKey, newKey) or changed
    end
    if type(details.kills) == "table" then
        changed = RewriteBreakdownKey(details.kills.targets, oldKey, newKey) or changed
    end
    if changed then
        actor.repdpsDetailRevision = (tonumber(actor.repdpsDetailRevision) or 0) + 1
    end
    return changed
end

local function RewriteStatsCounterpartKeys(statsRoot, oldKey, newKey)
    if type(statsRoot) ~= "table" then return false end
    local changed = false
    for _, mode in ipairs({ "PVP", "PVE" }) do
        local modeStats = statsRoot[mode]
        if type(modeStats) == "table" then
            for _, sideName in ipairs({ "friendly", "enemy" }) do
                local side = modeStats[sideName]
                for _, actor in pairs(type(side) == "table" and type(side.actors) == "table"
                    and side.actors or {}) do
                    changed = RewriteActorCounterpartKeys(actor, oldKey, newKey) or changed
                end
            end
        end
    end
    local shared = statsRoot.sharedHealing
    if type(shared) == "table" then
        for _, sideName in ipairs({ "friendly", "enemy" }) do
            local side = shared[sideName]
            for _, actor in pairs(type(side) == "table" and type(side.actors) == "table"
                and side.actors or {}) do
                changed = RewriteActorCounterpartKeys(actor, oldKey, newKey) or changed
            end
        end
    end
    return changed
end

local function MergeActorKeyInStats(statsRoot, oldKey, newKey, displayName)
    if type(statsRoot) ~= "table" or oldKey == newKey then return false end
    local changed = false
    for _, mode in ipairs({ "PVP", "PVE" }) do
        local modeStats = statsRoot[mode]
        if type(modeStats) == "table" then
            for _, sideName in ipairs({ "friendly", "enemy" }) do
                local side = modeStats[sideName]
                if type(side) == "table" and type(side.actors) == "table" and side.actors[oldKey] ~= nil then
                    side.actors[newKey] = MergeActorRecord(side.actors[newKey], side.actors[oldKey], displayName)
                    side.actors[oldKey] = nil
                    changed = true
                end
            end
        end
    end
    -- SharedHealing is now a production Authority, so actor-key migration is
    -- owned by the same core transaction as the compatibility buckets. It must
    -- not depend on the optional StatsV3 projection observer being healthy.
    local shared = statsRoot.sharedHealing
    if type(shared) == "table" then
        for _, sideName in ipairs({ "friendly", "enemy" }) do
            local side = shared[sideName]
            if type(side) == "table" and type(side.actors) == "table" and side.actors[oldKey] ~= nil then
                side.actors[newKey] = MergeActorRecord(side.actors[newKey], side.actors[oldKey], displayName)
                side.actors[oldKey] = nil
                changed = true
            end
        end
    end
    -- The actor row is only half of an identity migration. Every other actor's
    -- target/source maps can still reference the old key; leaving those entries
    -- behind produces duplicate detail rows and makes later manual operations
    -- appear to affect the ranking but not its target/source breakdown.
    changed = RewriteStatsCounterpartKeys(statsRoot, oldKey, newKey) or changed
    return changed
end

function S:MergeActorKey(oldKey, newKey, displayName)
    if oldKey == nil or newKey == nil then return end
    oldKey = tostring(oldKey)
    newKey = tostring(newKey)
    if oldKey == "" or newKey == "" or oldKey == newKey then return end

    local roots = {}
    local seenRoots = {}
    local function AddRoot(root)
        if type(root) == "table" and seenRoots[root] ~= true then
            seenRoots[root] = true
            roots[#roots + 1] = root
        end
    end
    AddRoot(D.State.stats)
    AddRoot(D.EventStore ~= nil and D.EventStore.baselineStats or nil)
    AddRoot(self.replayWorkingStats)

    local changed = false
    for _, root in ipairs(roots) do
        changed = MergeActorKeyInStats(root, oldKey, newKey, displayName) or changed
    end
    local observer = self.statsV3Observer
    if type(observer) == "table" and type(observer.OnLegacyActorKeyMerged) == "function" then
        for _, root in ipairs(roots) do
            pcall(observer.OnLegacyActorKeyMerged, observer, oldKey, newKey, displayName, root)
        end
    end
    if A ~= nil and A.MergeBossActorKey ~= nil then A:MergeBossActorKey(oldKey, newKey) end
    if changed then
        self:MarkBreakdownsMutated(true)
        D.MarkViewDirty()
        D.State.dirty.statsSave = true
    end
end

local function EnsureModeStatsShape(modeStats, mode)
    if type(modeStats) ~= "table" then return NewModeStats(mode) end
    modeStats.schemaVersion = 2
    modeStats.mode = mode
    modeStats.epochStart = U.FiniteNumber(modeStats.epochStart, 0) or 0
    for _, sideName in ipairs({ "friendly", "enemy" }) do
        local side = modeStats[sideName]
        if type(side) ~= "table" then
            side = NewSideStats()
            modeStats[sideName] = side
        end
        if type(side.actors) ~= "table" then side.actors = {} end
        if type(side.totals) ~= "table" then
            side.totals = { damage = 0, taken = 0, heal = 0, kills = 0 }
        else
            for _, metric in ipairs({ "damage", "taken", "heal", "kills" }) do
                side.totals[metric] = NonNegativeNumber(side.totals[metric], 0)
            end
        end
        -- 合法存档会由加载校验器提供 active。这里是热路径防御修复，只补
        -- 统计必需的 actors/totals；不要给历史半结构强行开启活动时钟，否则
        -- 一次兼容性修复会改变保存调度与DPS时间语义。AddMetric 对缺失 active
        -- 本来就安全跳过。
    end
    if type(modeStats.pending) ~= "table" then
        modeStats.pending = { events = 0, damage = 0, taken = 0, heal = 0 }
    end
    if type(modeStats.thirdParty) ~= "table" then
        modeStats.thirdParty = { events = 0, damage = 0, taken = 0, heal = 0 }
    end
    if type(modeStats.closure) ~= "table" then
        modeStats.closure = { friendlyDamageVsEnemyTaken = 100, enemyDamageVsFriendlyTaken = 100 }
    end
    return modeStats
end

function S:GetMode(mode, forWrite)
    mode = mode == "PVE" and "PVE" or "PVP"
    -- 分帧重放期间：写入路径（forWrite=true，重放事件/收尾）必须落到
    -- "单工作副本"（replayWorkingStats），而读取路径（forWrite 缺省，
    -- UI 排行榜/详情/摘要）必须始终读 D.State.stats——否则 UI 会在重放
    -- 中途看到半重放的混合统计。提交时才把工作副本原子替换为 D.State.stats。
    local root
    if forWrite == true and self.replayWorkingStats ~= nil then
        root = self.replayWorkingStats
    else
        root = D.State.stats
    end
    if type(root) ~= "table" then
        root = U.DeepCopy(defaultStats)
        if forWrite == true and self.replayWorkingStats ~= nil then
            self.replayWorkingStats = root
        else
            D.State.stats = root
        end
    end

    -- Normal combat writes repeatedly request the same two mode tables. Once a
    -- root has passed shape repair, return the cached table directly instead of
    -- revalidating both sides, four totals, pending and closure on every metric.
    self.modeCache = type(self.modeCache) == "table" and self.modeCache or {}
    if self.modeCacheRoot == root and self.modeCache[mode] == root[mode] then
        return self.modeCache[mode]
    end
    root[mode] = EnsureModeStatsShape(root[mode], mode)
    self.modeCacheRoot = root
    self.modeCache[mode] = root[mode]
    return root[mode]
end

function S:GetActor(side, entity)
    local key = entity ~= nil and entity.key or "unknown"
    local actor = side.actors[key]
    if actor == nil then
        actor = NewActorStats(entity ~= nil and entity.name or "未知")
        side.actors[key] = actor
    elseif entity ~= nil then
        actor.name = entity.name
    end
    EnsureActorDetails(actor)
    return actor
end

local function ActiveSegmentMs(active, now, windowMs)
    if type(active) ~= "table" or active.last == nil or active.startedAt == nil then return 0 end
    now = tonumber(now) or U.NowMs()
    windowMs = math.max(0, tonumber(windowMs) or 0)
    local segmentEnd = math.min(now, (tonumber(active.last) or now) + windowMs)
    return math.max(0, segmentEnd - (tonumber(active.startedAt) or segmentEnd))
end

function S:GetActiveMs(active, now, windowMs)
    return math.max(0, tonumber(active and active.total) or 0) + ActiveSegmentMs(active, now, windowMs)
end

-- UI/诊断读取必须兼容旧存档、迁移中统计树和事务重放的半成品视图。
-- side.active 不属于总量正确性的必要字段，缺失时只表示速率时间不可用，
-- 不能因为直接索引 nil 而中断整个 OnUpdate 与排行榜刷新链路。
function S:GetSideMetricActiveMs(side, metric, now)
    local active = type(side) == "table" and type(side.active) == "table"
        and side.active[metric] or nil
    if type(active) ~= "table" then return 0 end
    return self:GetActiveMs(active, now, D.State.config.sideWindowMs)
end

function S:IsActiveClockChanging(active, now, windowMs, graceMs)
    if type(active) ~= "table" or active.last == nil or active.startedAt == nil then return false end
    now = tonumber(now) or U.NowMs()
    return now <= (tonumber(active.last) or 0) + math.max(0, tonumber(windowMs) or 0) + math.max(0, tonumber(graceMs) or 0)
end

function S:TouchActive(active, now, windowMs)
    if type(active) ~= "table" then return end
    now = tonumber(now) or U.NowMs()
    windowMs = math.max(0, tonumber(windowMs) or 0)
    active.total = math.max(0, tonumber(active.total) or 0)
    if active.last == nil or active.startedAt == nil then
        active.startedAt = now
        active.last = now
        return
    end
    if now - (tonumber(active.last) or now) > windowMs then
        active.total = active.total + ActiveSegmentMs(active, (tonumber(active.last) or now) + windowMs, windowMs)
        active.startedAt = now
    end
    active.last = now
end

local function FinalizeActive(active, now, windowMs)
    if type(active) ~= "table" then return end
    active.total = math.max(0, tonumber(active.total) or 0) + ActiveSegmentMs(active, now, windowMs)
    active.last = nil
    active.startedAt = nil
end

function S:FinalizeOpenActives(statsRoot, now)
    if type(statsRoot) ~= "table" then return end
    now = tonumber(now) or U.NowMs()
    for _, modeName in ipairs({ "PVP", "PVE" }) do
        local modeStats = statsRoot[modeName]
        for _, sideName in ipairs({ "friendly", "enemy" }) do
            local side = type(modeStats) == "table" and modeStats[sideName] or nil
            if type(side) == "table" then
                for _, metric in ipairs({ "damage", "taken", "heal" }) do
                    FinalizeActive(side.active and side.active[metric], now, D.State.config.sideWindowMs)
                end
                for _, actor in pairs(side.actors or {}) do
                    for _, metric in ipairs({ "damage", "taken", "heal" }) do
                        FinalizeActive(actor.active and actor.active[metric], now, D.State.config.personalWindowMs)
                    end
                end
            end
        end
    end
end

local function CloseExpiredActive(active, now, windowMs)
    if type(active) ~= "table" or active.last == nil or active.startedAt == nil then return false end
    local closeAt = (tonumber(active.last) or 0) + math.max(0, tonumber(windowMs) or 0)
    if now < closeAt then return false end
    FinalizeActive(active, closeAt, windowMs)
    return true
end

function S:HasChangingActives(statsRoot, now)
    if type(statsRoot) ~= "table" then return false end
    now = tonumber(now) or U.NowMs()
    for _, modeName in ipairs({ "PVP", "PVE" }) do
        local modeStats = statsRoot[modeName]
        for _, sideName in ipairs({ "friendly", "enemy" }) do
            local side = type(modeStats) == "table" and modeStats[sideName] or nil
            if type(side) == "table" then
                for _, metric in ipairs({ "damage", "taken", "heal" }) do
                    if self:IsActiveClockChanging(side.active and side.active[metric], now, D.State.config.sideWindowMs, 0) then return true end
                end
            end
        end
    end
    return false
end

-- Healing is a relation-based statistic, not a PVP/PVE statistic. Historical
-- saves may still contain healing in both legacy mode buckets, so the read layer
-- combines them. New runtime events use one canonical backing bucket; this keeps
-- the existing statistics schema compatible without continuing the ambiguity.
local function OpenActiveInterval(active, now, windowMs)
    if type(active) ~= "table" or active.last == nil or active.startedAt == nil then return nil, nil end
    now = tonumber(now) or U.NowMs()
    windowMs = math.max(0, tonumber(windowMs) or 0)
    local first = tonumber(active.startedAt)
    local last = tonumber(active.last)
    if first == nil or last == nil then return nil, nil end
    local finish = math.min(now, last + windowMs)
    if finish <= first then return nil, nil end
    return first, finish
end

-- Exact for the currently open segments. Persisted closed time from old PVP and
-- PVE buckets has no interval history, so it must be added as recorded. Once all
-- new healing uses the canonical bucket, no new cross-bucket overlap is created.
local function SharedActiveMs(first, second, now, windowMs)
    now = tonumber(now) or U.NowMs()
    local total = math.max(0, tonumber(first and first.total) or 0)
        + math.max(0, tonumber(second and second.total) or 0)
    local firstFrom, firstTo = OpenActiveInterval(first, now, windowMs)
    local secondFrom, secondTo = OpenActiveInterval(second, now, windowMs)
    if firstFrom == nil then
        return total + (secondFrom ~= nil and math.max(0, secondTo - secondFrom) or 0)
    end
    if secondFrom == nil then
        return total + math.max(0, firstTo - firstFrom)
    end
    -- There are at most two open intervals. Calculate their union directly
    -- instead of allocating an array and sorting it for every healer on every
    -- UI refresh and persistence snapshot.
    if secondFrom < firstFrom then
        firstFrom, secondFrom = secondFrom, firstFrom
        firstTo, secondTo = secondTo, firstTo
    end
    total = total + math.max(0, firstTo - firstFrom)
    if secondFrom <= firstTo then
        total = total + math.max(0, secondTo - math.max(firstTo, secondFrom))
    else
        total = total + math.max(0, secondTo - secondFrom)
    end
    return total
end

-- Create a self-contained persisted/snapshot copy. Damage and taken can be
-- finalized per mode, but healing is shared across PVP/PVE: two open legacy
-- healing intervals must be unioned before their timestamps are removed, or a
-- save/clear/restore cycle can double the HPS denominator.
function S:FinalizeForPersistence(statsRoot, now)
    if type(statsRoot) ~= "table" then return end
    now = U.TimestampOrNow(now)

    for _, sideName in ipairs({ "friendly", "enemy" }) do
        local pvpSide = statsRoot.PVP and statsRoot.PVP[sideName] or nil
        local pveSide = statsRoot.PVE and statsRoot.PVE[sideName] or nil
        if type(pvpSide) == "table" and type(pveSide) == "table" then
            local sharedSideTotal = SharedActiveMs(
                pvpSide.active and pvpSide.active.heal,
                pveSide.active and pveSide.active.heal,
                now,
                D.State.config.sideWindowMs
            )
            local pvpActors = type(pvpSide.actors) == "table" and pvpSide.actors or {}
            local pveActors = type(pveSide.actors) == "table" and pveSide.actors or {}

            local function FinalizeSharedActor(key, pvpActor, pveActor)
                local total = SharedActiveMs(
                    pvpActor and pvpActor.active and pvpActor.active.heal,
                    pveActor and pveActor.active and pveActor.active.heal,
                    now,
                    D.State.config.personalWindowMs
                )
                local canonical, legacy
                if pveActor ~= nil then
                    canonical = pveActor
                    legacy = pvpActor
                else
                    canonical = pvpActor
                    legacy = nil
                end
                if type(canonical) == "table" then
                    canonical.active = type(canonical.active) == "table" and canonical.active or {}
                    canonical.active.heal = { total = total, last = nil, startedAt = nil }
                end
                if type(legacy) == "table" then
                    legacy.active = type(legacy.active) == "table" and legacy.active or {}
                    legacy.active.heal = { total = 0, last = nil, startedAt = nil }
                end
            end

            for key, pvpActor in pairs(pvpActors) do
                FinalizeSharedActor(key, pvpActor, pveActors[key])
            end
            for key, pveActor in pairs(pveActors) do
                if pvpActors[key] == nil then FinalizeSharedActor(key, nil, pveActor) end
            end

            pvpSide.active = type(pvpSide.active) == "table" and pvpSide.active or {}
            pveSide.active = type(pveSide.active) == "table" and pveSide.active or {}
            pvpSide.active.heal = { total = 0, last = nil, startedAt = nil }
            pveSide.active.heal = { total = sharedSideTotal, last = nil, startedAt = nil }
        end
    end

    -- The independent v3 SharedHealing projection owns its own clocks. Close
    -- them directly; rebuilding from the legacy buckets here would discard the
    -- persisted v3 identity and detail delta state.
    local shared = statsRoot.sharedHealing
    if type(shared) == "table" then
        for _, sideName in ipairs({ "friendly", "enemy" }) do
            local side = shared[sideName]
            if type(side) == "table" then
                FinalizeActive(side.active and side.active.heal, now, D.State.config.sideWindowMs)
                for _, actor in pairs(type(side.actors) == "table" and side.actors or {}) do
                    FinalizeActive(actor.active and actor.active.heal, now, D.State.config.personalWindowMs)
                end
            end
        end
    end

    -- Damage/taken clocks and any noncanonical legacy branches can now be
    -- finalized in-place. Healing clocks above are already closed, so this pass
    -- does not need a second actor-sized union map.
    self:FinalizeOpenActives(statsRoot, now)
end

------------------------------------------------------------------------
-- 分帧最终整理（问题 11 修复）
--
-- 数据所有权：job 归 D.Stats 所有，持有待持久化的快照 payload 引用。
-- 生命周期：一次保存任务一个 job；统计变更（MarkStatsMutated）会作废
--   整个快照任务（含 finalize），与旧快照作废语义一致。
-- 是否允许失效：允许。finalize 只是把"开放活动段"落成持久化闭段，
--   任何时刻中断都不损坏 live 统计；任务作废后由下次保存重新开始。
-- 是否可重建：可。BeginFinalizeForPersistence 可随时重新发起。
-- 为什么不能单帧扫描：长期数据下 actor 数量上万，关闭活动时间与合并
--   共享治疗需要遍历全部 actor；单帧完成会与战斗事件争抢主线程。
-- 单帧预算：StepFinalizeForPersistence 按 actorBudget 分批处理。
------------------------------------------------------------------------
local FINALIZE_SIDES = { "friendly", "enemy" }
local FINALIZE_MODES = { "PVP", "PVE" }
local FINALIZE_METRICS = { "damage", "taken", "heal" }

function S:BeginFinalizeForPersistence(statsRoot, now)
    return {
        statsRoot = statsRoot,
        now = U.TimestampOrNow(now),
        phase = "HEALING_SHARED_SIDE",
        sideIndex = 1,
        healingSideIndex = 1,
        healingPass = "PVP",
        modeIndex = 1,
        actorLastKey = nil,
        actorTable = nil,
    }
end

-- 推进一帧 finalize。返回 true 表示全部完成。
function S:StepFinalizeForPersistence(job, actorBudget)
    if type(job) ~= "table" then return true end
    local budget = math.max(1, math.floor(tonumber(actorBudget) or 300))
    local statsRoot = job.statsRoot
    local now = job.now
    local processed = 0
    local sides = FINALIZE_SIDES
    local modes = FINALIZE_MODES

    -- 阶段一：共享治疗 side 级归并（固定只有友军/敌军两项）。
    if job.phase == "HEALING_SHARED_SIDE" then
        while job.sideIndex <= #sides do
            local sideName = sides[job.sideIndex]
            job.sideIndex = job.sideIndex + 1
            local pvpSide = statsRoot.PVP and statsRoot.PVP[sideName] or nil
            local pveSide = statsRoot.PVE and statsRoot.PVE[sideName] or nil
            if type(pvpSide) == "table" and type(pveSide) == "table" then
                local sharedSideTotal = SharedActiveMs(
                    pvpSide.active and pvpSide.active.heal,
                    pveSide.active and pveSide.active.heal,
                    now,
                    D.State.config.sideWindowMs
                )
                pvpSide.active = type(pvpSide.active) == "table" and pvpSide.active or {}
                pveSide.active = type(pveSide.active) == "table" and pveSide.active or {}
                pvpSide.active.heal = { total = 0, last = nil, startedAt = nil }
                pveSide.active.heal = { total = sharedSideTotal, last = nil, startedAt = nil }
            end
        end
        job.phase = "HEALING_SHARED_ACTOR"
    end

    -- 阶段二：逐 actor 合并共享治疗活动时间。
    -- v0.2.27 把所有 actor 写进临时 sideKey 表，随后每帧重新收集并排序
    -- 全部键。大型存档会形成 O(帧数 × n log n) 的保存尾段和大量 GC。
    -- 这里严格复现同步版的两趟语义：PVP actor 读取对应 PVE actor 后一次
    -- 写回两边，再处理 PVE 独有 actor；每个 actor 只访问一次。
    if job.phase == "HEALING_SHARED_ACTOR" then
        while processed < budget do
            local sideName = sides[job.healingSideIndex]
            if sideName == nil then
                job.phase = "FINALIZE_OPEN_ACTIVES"
                job.modeIndex = 1
                job.sideIndex = 1
                job.actorLastKey = nil
                job.actorTable = nil
                break
            end

            local pvpSide = statsRoot.PVP and statsRoot.PVP[sideName] or nil
            local pveSide = statsRoot.PVE and statsRoot.PVE[sideName] or nil
            local pvpActors = type(pvpSide and pvpSide.actors) == "table" and pvpSide.actors or {}
            local pveActors = type(pveSide and pveSide.actors) == "table" and pveSide.actors or {}
            local actors = job.healingPass == "PVP" and pvpActors or pveActors

            if job.actorTable ~= actors then
                job.actorTable = actors
                job.actorLastKey = nil
            end
            local ok, key = pcall(next, actors, job.actorLastKey)
            if not ok then key = nil end
            if key == nil then
                job.actorLastKey = nil
                job.actorTable = nil
                if job.healingPass == "PVP" then
                    job.healingPass = "PVE_ONLY"
                else
                    job.healingPass = "PVP"
                    job.healingSideIndex = job.healingSideIndex + 1
                end
            else
                job.actorLastKey = key
                local shouldProcess = job.healingPass == "PVP" or pvpActors[key] == nil
                if shouldProcess then
                    local pvpActor = pvpActors[key]
                    local pveActor = pveActors[key]
                    local total = SharedActiveMs(
                        pvpActor and pvpActor.active and pvpActor.active.heal,
                        pveActor and pveActor.active and pveActor.active.heal,
                        now,
                        D.State.config.personalWindowMs
                    )
                    local canonical = pveActor or pvpActor
                    local legacy = pveActor ~= nil and pvpActor or nil
                    if type(canonical) == "table" then
                        canonical.active = type(canonical.active) == "table" and canonical.active or {}
                        canonical.active.heal = { total = total, last = nil, startedAt = nil }
                    end
                    if type(legacy) == "table" then
                        legacy.active = type(legacy.active) == "table" and legacy.active or {}
                        legacy.active.heal = { total = 0, last = nil, startedAt = nil }
                    end
                end
                processed = processed + 1
            end
        end
        if job.phase == "HEALING_SHARED_ACTOR" then return false end
    end

    -- 阶段三：关闭全部开放活动段（分帧遍历所有 side/actor）。
    if job.phase == "FINALIZE_OPEN_ACTIVES" then
        if D.Diagnostics ~= nil and D.Diagnostics.counters ~= nil then
            D.Diagnostics.counters.saveFinalizeFrames =
                (tonumber(D.Diagnostics.counters.saveFinalizeFrames) or 0) + 1
        end
        while processed < budget do
            local modeName = modes[job.modeIndex]
            if modeName == nil then
                job.phase = "FINALIZE_SHARED_V3"
                job.sideIndex = 1
                job.actorLastKey = nil
                job.actorTable = nil
                break
            end
            local modeStats = statsRoot[modeName]
            local sideName = sides[job.sideIndex]
            if sideName == nil then
                job.modeIndex = job.modeIndex + 1
                job.sideIndex = 1
                job.actorLastKey = nil
                job.actorTable = nil
            else
                local side = type(modeStats) == "table" and modeStats[sideName] or nil
                if type(side) == "table" then
                    for _, metric in ipairs(FINALIZE_METRICS) do
                        FinalizeActive(side.active and side.active[metric], now, D.State.config.sideWindowMs)
                    end
                    local actors = type(side.actors) == "table" and side.actors or {}
                    if job.actorTable ~= actors then
                        job.actorTable = actors
                        job.actorLastKey = nil
                    end
                    local ok, key, actor = pcall(next, actors, job.actorLastKey)
                    if not ok then key = nil end
                    if key == nil then
                        job.actorLastKey = nil
                        job.actorTable = nil
                        job.sideIndex = job.sideIndex + 1
                    else
                        job.actorLastKey = key
                        if type(actor) == "table" and type(actor.active) == "table" then
                            for _, metric in ipairs(FINALIZE_METRICS) do
                                FinalizeActive(actor.active[metric], now, D.State.config.personalWindowMs)
                            end
                        end
                        processed = processed + 1
                        if D.Diagnostics ~= nil and D.Diagnostics.counters ~= nil then
                            D.Diagnostics.counters.saveFinalizeActors =
                                (tonumber(D.Diagnostics.counters.saveFinalizeActors) or 0) + 1
                        end
                    end
                else
                    job.sideIndex = job.sideIndex + 1
                end
            end
        end
        if job.phase == "FINALIZE_OPEN_ACTIVES" then return false end
    end

    -- 阶段四：关闭独立 SharedHealing v3 投影的 side/actor 活动段。该阶段
    -- 使用同一 actorBudget，不在保存尾帧同步扫描全部治疗者。
    if job.phase == "FINALIZE_SHARED_V3" then
        local shared = statsRoot.sharedHealing
        while processed < budget do
            local sideName = sides[job.sideIndex]
            if sideName == nil then
                job.phase = "DONE"
                break
            end
            local side = type(shared) == "table" and shared[sideName] or nil
            if type(side) ~= "table" then
                job.sideIndex = job.sideIndex + 1
                job.actorLastKey = nil
                job.actorTable = nil
            else
                if job.actorTable ~= side.actors then
                    FinalizeActive(side.active and side.active.heal, now, D.State.config.sideWindowMs)
                    job.actorTable = type(side.actors) == "table" and side.actors or {}
                    job.actorLastKey = nil
                end
                local ok, key, actor = pcall(next, job.actorTable, job.actorLastKey)
                if not ok then key = nil end
                if key == nil then
                    job.sideIndex = job.sideIndex + 1
                    job.actorLastKey = nil
                    job.actorTable = nil
                else
                    job.actorLastKey = key
                    FinalizeActive(actor and actor.active and actor.active.heal,
                        now, D.State.config.personalWindowMs)
                    processed = processed + 1
                end
            end
        end
        if job.phase ~= "DONE" then return false end
    end

    return true
end


local function SharedHealingDisplayName(key, first, second)
    local entity = D.Entities ~= nil and D.Entities.GetByKey ~= nil and D.Entities:GetByKey(key) or nil
    if entity ~= nil and U.Trim(entity.name) ~= "" then return entity.name end
    local firstName = first ~= nil and U.Trim(first.name) or ""
    local secondName = second ~= nil and U.Trim(second.name) or ""
    if firstName ~= "" and firstName ~= "未知" then return firstName end
    if secondName ~= "" then return secondName end
    return firstName ~= "" and firstName or "未知"
end

local function MergeSharedHealingActor(target, source)
    if type(source) ~= "table" then return target end
    if target == nil then target = NewActorStats(source.name) end
    target.heal = (tonumber(target.heal) or 0) + (tonumber(source.heal) or 0)
    target.provisional = target.provisional == true or source.provisional == true
    target.legacyDetailsDiscarded = target.legacyDetailsDiscarded == true or source.legacyDetailsDiscarded == true

    -- Detail maps are merged only for the one selected actor. Ranking refreshes
    -- deliberately use lightweight records to avoid copying every healer's
    -- ability/target maps every UI interval during a large battle.
    local sourceHeal = source.details and source.details.heal or nil
    if type(sourceHeal) == "table" then
        local targetDetails = EnsureActorDetails(target)
        targetDetails.heal.abilities = MergeNumberMap(targetDetails.heal.abilities, sourceHeal.abilities)
        targetDetails.heal.targets = MergeNumberMap(targetDetails.heal.targets, sourceHeal.targets)
    end
    target.repdpsSharedHealing = true
    return target
end

-- Product read compatibility entry. Since prep5 this delegates to the
-- independent SharedHealing Authority. The old PVP/PVE merge remains available
-- only through GetLegacySharedHealingActorForReference and D.StatsRead audits.
function S:GetSharedHealingActor(sideName, key, now)
    local reads = D.StatsRead
    if type(reads) ~= "table" or type(reads.GetSharedHealingActor) ~= "function" then return nil end
    return reads:GetSharedHealingActor(sideName == "enemy" and "enemy" or "friendly", key)
end

function S:GetLegacySharedHealingActorForReference(sideName, key, now)
    if key == nil then return nil end
    sideName = sideName == "enemy" and "enemy" or "friendly"
    now = tonumber(now) or U.NowMs()
    local pvpMode = self:GetMode("PVP")
    local pveMode = self:GetMode("PVE")
    local pvpActor = pvpMode and pvpMode[sideName] and pvpMode[sideName].actors
        and pvpMode[sideName].actors[key] or nil
    local pveActor = pveMode and pveMode[sideName] and pveMode[sideName].actors
        and pveMode[sideName].actors[key] or nil
    if (tonumber(pvpActor and pvpActor.heal) or 0) <= 0
        and (tonumber(pveActor and pveActor.heal) or 0) <= 0 then return nil end

    local merged = nil
    merged = MergeSharedHealingActor(merged, pvpActor)
    merged = MergeSharedHealingActor(merged, pveActor)
    merged.name = SharedHealingDisplayName(key, pvpActor, pveActor)
    merged.repdpsDetailRevision = tostring(tonumber(pvpActor and pvpActor.repdpsDetailRevision) or 0)
        .. ":" .. tostring(tonumber(pveActor and pveActor.repdpsDetailRevision) or 0)
    merged.active.heal = {
        total = SharedActiveMs(
            pvpActor and pvpActor.active and pvpActor.active.heal,
            pveActor and pveActor.active and pveActor.active.heal,
            now,
            D.State.config.personalWindowMs
        ),
        last = nil,
        startedAt = nil,
    }
    return merged
end

function S:AddBreakdown(map, key, amount)
    -- 返回是否创建了新键。已有键仅数值增长，不会增加明细表基数，因此不应
    -- 让全局明细压缩版本在每条战斗事件上失效。
    local text = tostring(key or "")
    if text == "" then text = "未知" end
    local isNew = map[text] == nil
    map[text] = (tonumber(map[text]) or 0) + amount
    return isNew
end

local function AddBoundedSharedHealingBreakdown(map, key, amount)
    local text = tostring(key or "")
    if text == "" then text = "未知" end
    if map[text] ~= nil then
        map[text] = (tonumber(map[text]) or 0) + amount
        return false
    end
    local count = 0
    local limit = math.max(8, math.floor(tonumber(D.Const.MAX_BREAKDOWN_KEYS) or 120))
    for _ in pairs(map) do
        count = count + 1
        if count >= limit then break end
    end
    if count >= limit then
        map.__other__ = (tonumber(map.__other__) or 0) + amount
        return false
    end
    map[text] = amount
    return true
end

local function GetStatsWriteRoot(stats)
    return stats.replayWorkingStats or D.State.stats
end

-- SharedHealing product Authority write. This path is deliberately owned by
-- D.Stats rather than the optional StatsV3 identity observer: a TargetRef
-- projection failure may disable identity diagnostics, but it cannot freeze the
-- formal treatment leaderboard or detail totals.
function S:AddSharedHealingMetricAuthority(sideName, entity, amount, event)
    local root = GetStatsWriteRoot(self)
    if type(root) ~= "table" or tonumber(root.schemaVersion) ~= 3 then
        error("SharedHealing Authority requires Stats Schema v3")
    end
    local shared = root.sharedHealing
    if type(shared) ~= "table" or tonumber(shared.schemaVersion) ~= 1 then
        error("SharedHealing Authority is unavailable")
    end
    sideName = sideName == "enemy" and "enemy" or "friendly"
    local side = shared[sideName]
    if type(side) ~= "table" then
        side = NewSideStats()
        shared[sideName] = side
    end
    side.actors = type(side.actors) == "table" and side.actors or {}
    side.totals = type(side.totals) == "table" and side.totals
        or { damage = 0, taken = 0, heal = 0, kills = 0 }
    side.active = type(side.active) == "table" and side.active or {}
    side.active.heal = type(side.active.heal) == "table" and side.active.heal
        or { total = 0, last = nil, startedAt = nil }

    local key = tostring(entity and entity.key or "")
    if key == "" then error("SharedHealing actor key unavailable") end
    local actor = side.actors[key]
    if type(actor) ~= "table" then
        actor = NewActorStats(entity and entity.name or "未知")
        side.actors[key] = actor
    else
        actor.name = entity and entity.name or actor.name
        EnsureActorDetails(actor)
    end
    actor.active = type(actor.active) == "table" and actor.active or {}
    actor.active.heal = type(actor.active.heal) == "table" and actor.active.heal
        or { total = 0, last = nil, startedAt = nil }
    amount = tonumber(amount) or 0
    actor.heal = (tonumber(actor.heal) or 0) + amount
    side.totals.heal = (tonumber(side.totals.heal) or 0) + amount
    actor.provisional = actor.provisional == true or (event and event.modeProvisional == true)
    self:TouchActive(actor.active.heal, event and event.timestamp, D.State.config.personalWindowMs)
    self:TouchActive(side.active.heal, event and event.timestamp, D.State.config.sideWindowMs)
    local details = actor.details.heal
    local ability = event and event.abilityName or "未知"
    local target = event and event.targetName or "未知"
    local shapeChanged = AddBoundedSharedHealingBreakdown(details.abilities, ability, amount)
    shapeChanged = AddBoundedSharedHealingBreakdown(details.targets, target, amount) or shapeChanged
    actor.repdpsDetailRevision = (tonumber(actor.repdpsDetailRevision) or 0) + 1
    actor.repdpsSharedHealing = true
    D.Diagnostics.counters.sharedHealingAuthorityWrites =
        (tonumber(D.Diagnostics.counters.sharedHealingAuthorityWrites) or 0) + 1
    return side, actor, shapeChanged
end

function S:AddMetric(mode, sideName, entity, metric, amount, event, deferStatsMutation)
    local modeStats = self:GetMode(mode, true)
    local side = modeStats[sideName]
    if side == nil then return end
    local actor = self:GetActor(side, entity)
    amount = tonumber(amount) or 0
    actor[metric] = (tonumber(actor[metric]) or 0) + amount
    side.totals[metric] = (tonumber(side.totals[metric]) or 0) + amount
    if event ~= nil and event.modeProvisional == true then
        actor.provisional = true
    end
    if metric ~= "kills" then
        local windowMs = D.State.config.personalWindowMs
        -- v0.2.25（防御）：重放工作副本可能来自旧版保存结构，active 段可能缺失。
        -- 缺失时跳过触摸，避免 nil 索引崩溃；正常路径行为不变。
        if type(actor.active) == "table" then
            self:TouchActive(actor.active[metric], event.timestamp, windowMs)
        end
        if type(side.active) == "table" then
            self:TouchActive(side.active[metric], event.timestamp, D.State.config.sideWindowMs)
        end
    end
    -- GetActor 已保证 details 完整；不要在每次指标写入时重复执行整套
    -- EnsureActorDetails 检查（一次伤害通常会调用 AddMetric 两次）。
    local details = actor.details
    local metricDetails = metric == "kills" and EnsureKillDetails(actor) or details[metric]
    local breakdownShapeChanged = false
    if metric == "damage" then
        breakdownShapeChanged = self:AddBreakdown(metricDetails.abilities, event.abilityName, amount) or breakdownShapeChanged
        breakdownShapeChanged = self:AddBreakdown(metricDetails.targets, event.targetName, amount) or breakdownShapeChanged
        if tonumber(actor.repdpsExcludedRevision) == tonumber(A.revision) and A:IsExcluded(event.targetName) then
            actor.repdpsExcludedDamage = (tonumber(actor.repdpsExcludedDamage) or 0) + amount
        end
        if A ~= nil and A.TrackBossDamage ~= nil then
            A:TrackBossDamage(mode, sideName, entity, event.targetName, amount, event)
        end
    elseif metric == "heal" then
        breakdownShapeChanged = self:AddBreakdown(metricDetails.abilities, event.abilityName, amount) or breakdownShapeChanged
        breakdownShapeChanged = self:AddBreakdown(metricDetails.targets, event.targetName, amount) or breakdownShapeChanged
    elseif metric == "taken" then
        breakdownShapeChanged = self:AddBreakdown(metricDetails.abilities, event.abilityName, amount) or breakdownShapeChanged
        breakdownShapeChanged = self:AddBreakdown(metricDetails.sources, event.sourceName, amount) or breakdownShapeChanged
    elseif metric == "kills" then
        local killAbility = tostring(event.abilityName or "")
        if killAbility == "" then killAbility = "未知技能" end
        local killTarget = tostring(event.targetName or "")
        if killTarget == "" then killTarget = "未知目标" end
        breakdownShapeChanged = self:AddBreakdown(metricDetails.abilities, killAbility, amount) or breakdownShapeChanged
        breakdownShapeChanged = self:AddBreakdown(metricDetails.targets, killTarget, amount) or breakdownShapeChanged
    end
    actor.repdpsDetailRevision = (tonumber(actor.repdpsDetailRevision) or 0) + 1
    if metric == "heal" then
        local _, _, sharedShapeChanged = self:AddSharedHealingMetricAuthority(sideName, entity, amount, event)
        breakdownShapeChanged = sharedShapeChanged or breakdownShapeChanged
    end
    NotifyStatsV3(self, mode, sideName, entity, metric, amount, event, actor, side)
    NotifyIdentityShadow(self, mode, sideName, entity, metric, amount, event, actor, side)
    self:MarkRankingMetricDirty(mode, sideName, metric, entity and entity.key, amount, event)
    if breakdownShapeChanged then
        self:MarkActorBreakdownMutated(mode, sideName, entity and entity.key, actor,
            deferStatsMutation)
    elseif deferStatsMutation ~= true then
        self:MarkStatsMutated(false)
    end
end

local function PairClosurePercent(left, right)
    left = tonumber(left) or 0
    right = tonumber(right) or 0
    local maximum = math.max(left, right)
    if maximum <= 0 then return 100 end
    return math.min(left, right) / maximum * 100
end

function S:MarkClosureDirty(mode)
    -- During full replay AddMetric writes into replayWorkingStats. Its closure
    -- is finalized explicitly before commit and must not dirty the visible
    -- root's lazy UI cache.
    if self.replayWorkingStats ~= nil then return end
    mode = mode == "PVE" and "PVE" or "PVP"
    self.closureDirty = type(self.closureDirty) == "table" and self.closureDirty or {}
    self.closureDirty[mode] = true
end

function S:UpdateClosure(mode, forWrite)
    -- Closure is a derived UI/persistence value. Recomputing it after every
    -- damage event duplicated mode lookups and floating-point work in the
    -- hottest path. Damage now marks it dirty; UI/save/replay finalization
    -- refreshes it on demand. forWrite=true deliberately targets the replay
    -- working root; ordinary UI/save reads always target the committed root.
    mode = mode == "PVE" and "PVE" or "PVP"
    local m = self:GetMode(mode, forWrite == true)
    if type(m) ~= "table" then return nil end
    m.closure = type(m.closure) == "table" and m.closure or {}
    m.closure.friendlyDamageVsEnemyTaken = PairClosurePercent(m.friendly.totals.damage, m.enemy.totals.taken)
    m.closure.enemyDamageVsFriendlyTaken = PairClosurePercent(m.enemy.totals.damage, m.friendly.totals.taken)
    if forWrite ~= true then
        self.closureDirty = type(self.closureDirty) == "table" and self.closureDirty or {}
        self.closureDirty[mode] = nil
    end
    return m.closure
end

function S:EnsureClosureCurrent(mode)
    mode = mode == "PVE" and "PVE" or "PVP"
    self.closureDirty = type(self.closureDirty) == "table" and self.closureDirty or {}
    if self.closureDirty[mode] == true then return self:UpdateClosure(mode, false) end
    local m = self:GetMode(mode, false)
    return m and m.closure or nil
end

function S:ClearMode(mode)
    mode = mode == "PVE" and "PVE" or "PVP"
    local now = U.NowMs()
    -- v0.2.25（问题 9）：引用交换。旧统计直接作为恢复快照保留，不做
    -- 同步深拷贝；清空后所有新事件只会写入新统计表。恢复时由
    -- RestoreLastClear 统一做一次性深拷贝与清洗。
    D.State.lastClearSnapshot = { mode = mode, data = D.State.stats[mode], savedAt = now }
    local fresh = NewModeStats(mode)
    fresh.epochStart = now
    D.State.stats[mode] = fresh
    D.State.stats.sharedHealing = BuildSharedHealingFromLegacy(D.State.stats)
    D.State.stats.identityProjection = NewIdentityProjectionStats()
    self:MarkBreakdownsMutated(true)
    -- Retained for compatibility with old snapshots and external callers. The
    -- visible clear button now uses ClearAll so PVP/PVE are reset together.
    D.State.dirty.statsSave = true
    D.MarkViewDirty()
    -- v0.2.25（清空修复）：快照持久化改为延迟保存——序列化旧统计可能是
    -- 同步大事务，在按钮点击路径上执行会卡顿甚至因 SaveData 失败抛错中断
    -- 清空链路（导致 ClearAllCombatData 未运行、旧日志回流）。此处只登记
    -- 待保存快照（引用，不序列化），由 OnUpdate 在空闲帧持久化。
    D.State.pendingClearSnapshot = { schemaVersion = 4, snapshot = D.State.lastClearSnapshot }
    D.State.dirty.snapshotSave = true
    return true
end

function S:ClearAll()
    local now = U.NowMs()
    if A ~= nil and A.Reset ~= nil then A:Reset() end
    -- v0.2.25（问题 9）：引用交换。旧统计直接作为恢复快照保留，不做
    -- 同步深拷贝——长期数据下深拷贝整棵统计树是清空按钮卡顿的根源。
    -- 快照只读；清空后所有新事件只写入新统计；第二次清空会覆盖上一次
    -- 快照（旧快照失去引用后由 GC 回收）。
    D.State.lastClearSnapshot = {
        scope = "ALL",
        mode = "ALL",
        data = D.State.stats,
        savedAt = now,
    }

    local fresh = U.DeepCopy(defaultStats)
    fresh.PVP.epochStart = now
    fresh.PVE.epochStart = now
    fresh.lastSaveAt = 0
    D.State.stats = fresh
    self:MarkBreakdownsMutated(true)
    D.State.dirty.statsSave = true
    D.MarkViewDirty()
    -- v0.2.25（清空修复）：快照持久化改为延迟保存（见 ClearMode 注释）。
    -- 清空按钮的确认路径（ClearAll → ClearAllCombatData）不再包含任何同步
    -- 大序列化，旧统计引用在空闲帧才被序列化持久化；保存失败只影响重启后
    -- 的“恢复上一次清空”，不影响本次清空与统计正确性。
    D.State.pendingClearSnapshot = { schemaVersion = 4, snapshot = D.State.lastClearSnapshot }
    D.State.dirty.snapshotSave = true
    return true
end

function S:RestoreLastClear()
    local snapshot = D.State.lastClearSnapshot
    if snapshot == nil then
        for _, slot in ipairs({ "primary", "pending", "backup" }) do
            local saved = P.LoadRaw(P.Key("snapshot", slot))
            if type(saved) == "table" and type(saved.snapshot) == "table" then
                snapshot = saved.snapshot
                break
            end
        end
    end
    if type(snapshot) ~= "table" or type(snapshot.data) ~= "table" then return false end

    local scope = snapshot.scope or snapshot.mode
    if scope == "ALL" then
        local restored = U.DeepCopy(snapshot.data)
        local restoredSchema = tonumber(restored.schemaVersion)
        if restoredSchema == 1 then
            restored = MigrateStatsV1(restored)
        elseif restoredSchema == 2 then
            restored = MigrateStatsV2ToV3(restored)
        elseif restoredSchema == 3 then
            restored = SanitizeStatsV3(restored)
        else
            restored = nil
        end
        if restored == nil then
            D.State.lastClearSnapshot = nil
            P.ClearSlots("snapshot")
            return false
        end
        ResetTransientStatsTiming(restored)
        D.State.stats = restored
        self:MarkBreakdownsMutated(true)
        D.State.lastClearSnapshot = nil
        P.ClearSlots("snapshot")
        D.State.dirty.statsSave = true
        D.MarkViewDirty()
        return "ALL"
    end

    if snapshot.mode ~= "PVP" and snapshot.mode ~= "PVE" then
        D.State.lastClearSnapshot = nil
        P.ClearSlots("snapshot")
        return false
    end
    local restored = U.DeepCopy(snapshot.data)
    local restoredSchema = tonumber(restored.schemaVersion)
    if restoredSchema == 1 then
        local wrapper = { schemaVersion = 1 }
        wrapper[snapshot.mode] = restored
        local migrated = MigrateStatsV1(wrapper)
        if migrated ~= nil then restored = migrated[snapshot.mode] end
    elseif restoredSchema ~= 2 then
        D.State.lastClearSnapshot = nil
        P.ClearSlots("snapshot")
        return false
    end
    local wrapper = NewStatsV2Root()
    wrapper[snapshot.mode] = restored
    local sanitized = MigrateStatsV2ToV3(wrapper)
    if sanitized == nil then
        D.State.lastClearSnapshot = nil
        P.ClearSlots("snapshot")
        return false
    end
    local timingRoot = { PVP = NewModeStats("PVP"), PVE = NewModeStats("PVE") }
    timingRoot[snapshot.mode] = sanitized[snapshot.mode]
    ResetTransientStatsTiming(timingRoot)
    D.State.stats[snapshot.mode] = timingRoot[snapshot.mode]
    D.State.stats.sharedHealing = BuildSharedHealingFromLegacy(D.State.stats)
    D.State.stats.identityProjection = NewIdentityProjectionStats()
    self:MarkBreakdownsMutated(true)
    D.State.lastClearSnapshot = nil
    P.ClearSlots("snapshot")
    D.State.dirty.statsSave = true
    D.MarkViewDirty()
    return snapshot.mode
end

function S:GetTargetDamageAmount(actor, normalizedTarget)
    if type(actor) ~= "table" or U.Trim(normalizedTarget) == "" then return 0 end
    local targets = actor.details and actor.details.damage and actor.details.damage.targets or {}
    local total = 0
    for name, value in pairs(targets) do
        if U.NormalizeName(name) == normalizedTarget then
            total = total + math.max(0, tonumber(value) or 0)
        end
    end
    return total
end

function S:GetExcludedTargetDamage(actor)
    if type(actor) ~= "table" or A:GetExcludedCount() <= 0 then return 0 end
    local revision = tonumber(A.revision) or 0
    if tonumber(actor.repdpsExcludedRevision) == revision then
        return math.max(0, tonumber(actor.repdpsExcludedDamage) or 0)
    end
    local targets = actor.details and actor.details.damage and actor.details.damage.targets or {}
    local total = 0
    for name, value in pairs(targets) do
        if A:IsExcluded(name) then total = total + math.max(0, tonumber(value) or 0) end
    end
    actor.repdpsExcludedRevision = revision
    actor.repdpsExcludedDamage = total
    return total
end

function S:GetDamageAnalysisValue(mode, sideName, actor, side, now, actorKey)
    local rawValue = math.max(0, tonumber(actor and actor.damage) or 0)
    local activeMs = self:GetActiveMs(actor and actor.active and actor.active.damage, now, D.State.config.personalWindowMs)
    local view = { enabled = false, rawValue = rawValue, activeMs = activeMs }
    if not A:IsPveFriendlyDamageScope(mode, sideName, "DAMAGE") then return rawValue, activeMs, view end

    local boss = A:GetBossTarget()
    if boss ~= nil then
        local value = A:GetBossContribution(actorKey or (actor and actor.key))
        local bossActiveMs = self:GetActiveMs(boss.active, now, D.State.config.sideWindowMs)
        view.enabled = true
        view.kind = "BOSS"
        view.bossTarget = boss
        view.activeMs = bossActiveMs
        view.historicalIncluded = true
        -- 当前持久统计没有保存“每个目标独立的活动时间”。伤害可以从无损
        -- 目标明细精确恢复，但用全局或点击后的时间计算 BossDPS 会误导。
        view.rateUnavailable = true
        return value, bossActiveMs, view
    end

    local excludedCount = A:GetExcludedCount()
    if excludedCount > 0 then
        local excluded = self:GetExcludedTargetDamage(actor)
        local value = math.max(0, rawValue - excluded)
        view.enabled = true
        view.kind = "EXCLUDED"
        view.excludedCount = excludedCount
        view.excludedValue = excluded
        -- The target totals are exact, but persisted actor activity does not
        -- retain per-target time intervals. Reusing the raw active time would
        -- present a mathematically false filtered DPS, so the UI deliberately
        -- hides rate values while retrospective exclusions are active.
        view.rateUnavailable = true
        return value, activeMs, view
    end
    return rawValue, activeMs, view
end

RankingItemBetter = function(left, right)
    if right == nil then return true end
    if left.value ~= right.value then return left.value > right.value end
    return tostring(left.name) < tostring(right.name)
end

local function RankingItemWorse(left, right)
    return RankingItemBetter(right, left)
end

local function HeapPushWorstFirst(heap, item)
    heap[#heap + 1] = item
    local index = #heap
    while index > 1 do
        local parent = math.floor(index / 2)
        if not RankingItemWorse(heap[index], heap[parent]) then break end
        heap[index], heap[parent] = heap[parent], heap[index]
        index = parent
    end
end

local function HeapReplaceWorst(heap, item)
    heap[1] = item
    local index = 1
    while true do
        local left = index * 2
        if left > #heap then break end
        local right = left + 1
        local worse = left
        if right <= #heap and RankingItemWorse(heap[right], heap[left]) then worse = right end
        if not RankingItemWorse(heap[worse], heap[index]) then break end
        heap[index], heap[worse] = heap[worse], heap[index]
        index = worse
    end
end


------------------------------------------------------------------------
-- 排行榜增量索引：分帧重建状态机与缓存读取
--
-- 结构：S.rankingRebuildJob 保存一次分帧重建的中间状态，包括跨帧遍历
--   两张 actor 表（PVP/PVE 共享治疗）的游标、堆、投影累计值。每次
--   StepRankingRebuild 只处理固定数量的 actor，完成后把结果写入
--   S.rankingCache[key] 并原子切换版本。
-- 正确性：增量只发生在"事件→脏标记→分帧重算"，重算本身与
--   BuildRankingFull 完全一致（同一套收集器），因此最终排行榜数值
--   与全量实现逐项相同；UI 在重建完成前读到的是上一版本的缓存。
------------------------------------------------------------------------

-- 新建一次分帧重建任务。返回 job；调用方逐帧驱动 StepRankingRebuild。
function S:BeginRankingRebuild(mode, sideName, page)
    local now = U.NowMs()
    local metric = "damage"
    if page == "TAKEN" then metric = "taken"
    elseif page == "HEAL" then metric = "heal"
    elseif page == "KILLS" then metric = "kills" end

    local job = {
        mode = mode,
        sideName = sideName,
        page = page,
        metric = metric,
        key = self:RankingCacheKey(mode, sideName, page),
        version = self:RankingVersion(),
        startedAt = now,
        phase = "COLLECT",
        -- 跨帧遍历游标。治疗榜从 prep5 起直接遍历 SharedHealing
        -- Authority 的单张 actor 表；healUnion 仅保留给旧任务结构兼容。
        healUnion = false,
        sourceTableIndex = 1,
        lastKey = nil,
        actors1 = {},
        actors2 = {},
        heap = {},
        projectedTotal = 0,
        positiveActorCount = 0,
        pinnedSelf = nil,
        rankingLimit = math.max(1, tonumber(D.Const.MAX_RANKING_ROWS) or 150),
        side = nil,
        rawTotal = 0,
        analysisView = { enabled = false, metric = metric },
        projectionEnabled = false,
        bossTarget = nil,
        excludedCount = 0,
        normalizedSelf = U.NormalizeName(D.Identity.playerName),
        normalizedSelfWithWorld = U.NormalizeName(D.Identity.playerNameWithWorld),
    }

    if metric == "heal" then
        local reads = D.StatsRead
        job.side = type(reads) == "table" and reads:GetSharedHealingSide(sideName) or nil
        job.actors1 = job.side and job.side.actors or {}
        job.actors2 = {}
    else
        local modeStats = self:GetMode(mode)
        job.side = modeStats[sideName]
        job.actors1 = job.side and job.side.actors or {}
        job.actors2 = {}
    end
    job.rawTotal = tonumber(job.side and job.side.totals and job.side.totals[metric]) or 0

    local bossTarget = A:GetBossTarget()
    local excludedCount = A:GetExcludedCount()
    job.bossTarget = bossTarget
    job.excludedCount = excludedCount
    local analysisView = { enabled = false, metric = metric }
    local projectionEnabled = metric == "damage" and A:IsPveFriendlyDamageScope(mode, sideName, page)
        and (bossTarget ~= nil or excludedCount > 0)
    job.projectionEnabled = projectionEnabled
    if projectionEnabled then
        if bossTarget ~= nil then
            analysisView = {
                enabled = true,
                metric = metric,
                kind = "BOSS",
                bossTarget = bossTarget,
                historicalIncluded = true,
                rateUnavailable = true,
                selectedAt = bossTarget.selectedAt,
                eventCount = bossTarget.eventCount,
            }
        else
            analysisView = {
                enabled = true,
                metric = metric,
                kind = "EXCLUDED",
                excludedCount = excludedCount,
                rateUnavailable = true,
            }
        end
    end
    job.analysisView = analysisView
    job.analysisKind = analysisView and analysisView.kind or nil
    job.dirtyActors = {}
    job.dirtyActorQueue = {}
    job.dirtyActorQueueHead = 1
    job.dirtyActorQueueTail = 0
    job.pendingTotalDelta = 0
    return job
end

-- 处理一个 actor（与 BuildRankingFull 的 ProcessActor 完全同语义）。
local function RankingProcessActor(self, job, key, first, second)
    local metric = job.metric
    local now = job.startedAt
    local value, activeMs, actorView, name, rawValue, provisional, revision, actor
    if metric == "heal" then
        actor = first
        value = tonumber(actor and actor.heal) or 0
        activeMs = self:GetActiveMs(actor and actor.active and actor.active.heal,
            now, D.State.config.personalWindowMs)
        local reads = D.StatsRead
        name = type(reads) == "table" and reads:GetSharedHealingDisplayName(key, actor)
            or (actor and actor.name or "未知")
        provisional = actor and actor.provisional == true or false
        revision = actor and actor.repdpsDetailRevision or nil
        rawValue = value
    else
        actor = first
        value = tonumber(actor and actor[metric]) or 0
        activeMs = metric ~= "kills"
            and self:GetActiveMs(actor and actor.active and actor.active[metric], now, D.State.config.personalWindowMs) or 0
        actorView = nil
        if job.projectionEnabled then
            value, activeMs, actorView = self:GetDamageAnalysisValue(
                job.mode, job.sideName, actor, job.side, now, key)
        end
        name = actor and actor.name or "未知"
        rawValue = tonumber(actor and actor[metric]) or 0
        provisional = actor and actor.provisional == true or false
        revision = actor and actor.repdpsDetailRevision or nil
    end
    if value <= 0 then return end
    job.positiveActorCount = job.positiveActorCount + 1
    job.projectedTotal = job.projectedTotal + value

    local isSelf = false
    if job.sideName == "friendly" and D.State.config.alwaysShowSelf then
        local normalizedName = U.NormalizeName(name)
        isSelf = key == D.Identity.entityKey
            or normalizedName == job.normalizedSelf
            or normalizedName == job.normalizedSelfWithWorld
    end
    local entersHeap = #job.heap < job.rankingLimit
    if not entersHeap then
        local worst = job.heap[1]
        entersHeap = worst == nil or value > (tonumber(worst.value) or 0)
            or (value == (tonumber(worst.value) or 0) and tostring(name) < tostring(worst.name))
    end
    local item = nil
    if isSelf or entersHeap then
        local rateUnavailable = type(actorView) == "table" and actorView.rateUnavailable == true
        local rate = metric ~= "kills" and not rateUnavailable
            and value / math.max(activeMs / 1000, 1) or 0
        item = {
            key = key,
            name = name,
            value = value,
            rawValue = rawValue,
            rate = rate,
            percent = 0,
            actor = actor,
            analysisView = actorView,
        }
    end
    if isSelf then job.pinnedSelf = item end
    if #job.heap < job.rankingLimit then
        HeapPushWorstFirst(job.heap, item)
    elseif entersHeap then
        HeapReplaceWorst(job.heap, item)
    end
end

function S:RequestRankingRebuild(mode, sideName, page)
    local key = self:RankingCacheKey(mode, sideName, page)
    if type(self.rankingRebuildJobs[key]) == "table" then return self.rankingRebuildJobs[key] end
    local job = self:BeginRankingRebuild(mode, sideName, page)
    self.rankingRebuildJobs[key] = job
    local tail = (tonumber(self.rankingRebuildQueueTail) or 0) + 1
    self.rankingRebuildQueueTail = tail
    self.rankingRebuildQueue[tail] = key
    return job
end

function S:ActivateNextRankingRebuild()
    if type(self.rankingRebuildJob) == "table" then return self.rankingRebuildJob end
    local head = math.max(1, math.floor(tonumber(self.rankingRebuildQueueHead) or 1))
    local tail = math.max(0, math.floor(tonumber(self.rankingRebuildQueueTail) or 0))
    while head <= tail do
        local key = self.rankingRebuildQueue[head]
        self.rankingRebuildQueue[head] = nil
        head = head + 1
        local job = self.rankingRebuildJobs[key]
        if type(job) == "table" then
            self.rankingRebuildQueueHead = head
            self.rankingRebuildJob = job
            return job
        end
    end
    self.rankingRebuildQueue = {}
    self.rankingRebuildQueueHead = 1
    self.rankingRebuildQueueTail = 0
    return nil
end

-- 单帧推进分帧重建。多个窗口的友军/敌军任务进入队列，不能互相覆盖。
function S:StepRankingRebuild(budget)
    local job = self:ActivateNextRankingRebuild()
    if type(job) ~= "table" then return true end
    budget = math.max(1, math.floor(tonumber(budget) or 400))
    local processed = 0
    while processed < budget and job.phase == "COLLECT" do
        local actors = job.sourceTableIndex == 1 and job.actors1 or job.actors2
        if type(actors) ~= "table" then actors = {} end
        local ok, key, actor = pcall(next, actors, job.lastKey)
        if not ok then key = nil end
        if key == nil then
            if job.healUnion and job.sourceTableIndex == 1 then
                -- 第一张表结束：切到 PVE 表，跳过已在 PVP 表中出现过的 key。
                job.sourceTableIndex = 2
                job.lastKey = nil
                actors = job.actors2
                local ok2, key2, actor2 = pcall(next, actors, nil)
                if not ok2 then
                    key = nil
                else
                    key, actor = key2, actor2
                end
            end
            if key == nil then
                job.phase = "FINALIZE"
                break
            end
        end
        job.lastKey = key
        if job.sourceTableIndex == 1 or job.actors1[key] == nil then
            local second = job.sourceTableIndex == 2 and actor or nil
            local first = job.sourceTableIndex == 1 and actor or nil
            if job.sourceTableIndex == 1 then
                second = job.actors2[key]
            else
                first = nil
            end
            RankingProcessActor(self, job, key, first, second)
        end
        processed = processed + 1
    end

    if job.phase == "FINALIZE" and job.pinnedSelf ~= nil
        and job.positiveActorCount > job.rankingLimit then
        local included = false
        for _, item in ipairs(job.heap) do
            if item == job.pinnedSelf or item.key == job.pinnedSelf.key then included = true break end
        end
        if not included then
            job.phase = "SELF_RANK"
            job.selfRankSource = 1
            job.selfRankLastKey = nil
            job.selfExactRank = 1
        end
    end

    while processed < budget and job.phase == "SELF_RANK" do
        local actors = job.selfRankSource == 1 and job.actors1 or job.actors2
        local ok, key, actor = pcall(next, actors, job.selfRankLastKey)
        if not ok then key = nil end
        if key == nil then
            if job.healUnion and job.selfRankSource == 1 then
                job.selfRankSource = 2
                job.selfRankLastKey = nil
            else
                job.phase = "COMMIT"
                break
            end
        else
            job.selfRankLastKey = key
            if key ~= job.pinnedSelf.key
                and (job.selfRankSource == 1 or job.actors1[key] == nil) then
                local first = job.selfRankSource == 1 and actor or nil
                local second = job.selfRankSource == 1 and job.actors2[key] or actor
                local value, name
                if job.metric == "heal" then
                    value = tonumber(first and first.heal) or 0
                    local reads = D.StatsRead
                    name = type(reads) == "table" and reads:GetSharedHealingDisplayName(key, first)
                        or (first and first.name or "未知")
                else
                    local item = self:BuildRankingItemForKey(job.mode, job.sideName, job.page, key, U.NowMs())
                    value = tonumber(item and item.value) or 0
                    name = item and item.name or "未知"
                end
                local pinned = job.pinnedSelf
                if value > 0 and (value > pinned.value
                    or (value == pinned.value and tostring(name) < tostring(pinned.name))) then
                    job.selfExactRank = job.selfExactRank + 1
                end
            end
            processed = processed + 1
        end
    end

    if job.phase == "FINALIZE" or job.phase == "COMMIT" then
        local result = job.heap
        local total = job.projectionEnabled and job.projectedTotal or job.rawTotal
        if job.projectionEnabled then
            local analysisView = job.analysisView
            analysisView.rawTotal = job.rawTotal
            analysisView.total = total
            if analysisView.kind == "BOSS" then
                analysisView.rateUnavailable = true
                analysisView.totalActiveMs = nil
                analysisView.eventCount = job.bossTarget and job.bossTarget.eventCount or 0
            else
                analysisView.excludedCount = job.excludedCount
                analysisView.rateUnavailable = true
                analysisView.totalActiveMs = nil
            end
        end
        local selfIncluded = false
        if job.pinnedSelf ~= nil then
            for _, item in ipairs(result) do
                if item == job.pinnedSelf or item.key == job.pinnedSelf.key then selfIncluded = true break end
            end
            if not selfIncluded then result[#result + 1] = job.pinnedSelf end
        end
        for _, item in ipairs(result) do
            item.percent = total > 0 and item.value / total * 100 or 0
        end
        table.sort(result, RankingItemBetter)
        for index, item in ipairs(result) do item.rank = index end
        if job.pinnedSelf ~= nil and not selfIncluded and job.selfExactRank ~= nil then
            job.pinnedSelf.rank = job.selfExactRank
        end
        local cache = {
            key = job.key,
            version = self:RankingVersion(),
            result = result,
            total = total,
            metric = job.metric,
            mode = job.mode,
            sideName = job.sideName,
            page = job.page,
            side = job.side,
            analysisView = job.analysisView,
            analysisKind = job.analysisKind,
            dirtyActors = job.dirtyActors or {},
            dirtyActorQueue = job.dirtyActorQueue or {},
            dirtyActorQueueHead = job.dirtyActorQueueHead or 1,
            dirtyActorQueueTail = job.dirtyActorQueueTail or 0,
            pendingTotalDelta = job.pendingTotalDelta or 0,
            rebuiltAt = U.NowMs(),
        }
        self.rankingCache[job.key] = cache
        if (tonumber(cache.dirtyActorQueueTail) or 0) >= (tonumber(cache.dirtyActorQueueHead) or 1) then
            self.rankingCachesDirty = true
            self:PatchRankingCache(cache, 32)
        end
        self.rankingRebuildJobs[job.key] = nil
        self.rankingRebuildJob = nil
        D.Diagnostics.counters.rankingRebuilds =
            (tonumber(D.Diagnostics.counters.rankingRebuilds) or 0) + 1
        -- UI 可能在旧缓存返回后已经清除了 view dirty。分帧任务完成时必须
        -- 主动唤醒一次刷新，否则新榜单要等下一条战斗事件或人工操作才显示。
        D.MarkViewDirty()
        return true
    end
    self.rankingRebuildJob = job
    return false
end

-- 缓存优先的排行榜读取（问题 2 修复）：UI 每 500ms 调用本函数。缓存命中
-- 时只刷新 ≤150 行的动态字段，绝不遍历全部历史角色；未命中时若空闲则
-- 启动分帧重建并返回旧缓存，否则同步全量构建一次作为基准。
function S:BuildRanking(mode, sideName, page)
    local cacheKey = self:RankingCacheKey(mode, sideName, page)
    local version = self:RankingVersion()
    local cache = self.rankingCache[cacheKey]
    if type(cache) == "table" and cache.version == version then
        self:PatchRankingCache(cache, 24)
        -- UI 会截断/置顶修改返回数组，必须浅拷贝，否则污染缓存。
        local now = U.NowMs()
        local copy = {}
        for index, item in ipairs(cache.result) do
            copy[index] = item
            RefreshRankingItemDynamicFields(self, item, now, cache.total, cache.metric)
        end
        return copy, cache.total, cache.metric, cache.side, cache.analysisView
    end

    -- 版本过期：由 OnUpdate 空闲帧调用 StepRankingRebuild 分帧推进，
    -- UI 读取路径不做重活。这里仅确保重建任务已启动。
    self:RequestRankingRebuild(mode, sideName, page)
    -- 返回上一版本缓存（若有），保证 UI 持续有数据显示。
    if type(cache) == "table" then
        local now = U.NowMs()
        local copy = {}
        for index, item in ipairs(cache.result) do
            copy[index] = item
            RefreshRankingItemDynamicFields(self, item, now, cache.total, cache.metric)
        end
        return copy, cache.total, cache.metric, cache.side, cache.analysisView
    end

    -- 首次构建也必须有界。先在当前调用中推进一个小批次：小团队通常可
    -- 立即得到完整榜单；大型历史存档只处理固定数量角色，余下交给 OnUpdate。
    local job = self.rankingRebuildJobs[cacheKey] or self:RequestRankingRebuild(mode, sideName, page)
    self:StepRankingRebuild(160)
    cache = self.rankingCache[cacheKey]
    if type(cache) == "table" then
        self:PatchRankingCache(cache, 24)
        local now = U.NowMs()
        local copy = {}
        for index, item in ipairs(cache.result) do
            copy[index] = item
            RefreshRankingItemDynamicFields(self, item, now, cache.total, cache.metric)
        end
        return copy, cache.total, cache.metric, cache.side, cache.analysisView
    end
    return {}, 0, job and job.metric or RankingMetricForPage(page),
        job and job.side or nil, job and job.analysisView or { enabled = false }

end


function S:IsRankingCacheCurrent(mode, sideName, page)
    local key = self:RankingCacheKey(mode, sideName, page)
    local cache = self.rankingCache and self.rankingCache[key] or nil
    if type(cache) ~= "table" or cache.version ~= self:RankingVersion() then return false end
    if type(self.rankingRebuildJobs) == "table" and self.rankingRebuildJobs[key] ~= nil then return false end
    local head = math.max(1, math.floor(tonumber(cache.dirtyActorQueueHead) or 1))
    local tail = math.max(0, math.floor(tonumber(cache.dirtyActorQueueTail) or 0))
    return head > tail and (tonumber(cache.pendingTotalDelta) or 0) == 0
end

function S:BuildRankingFull(mode, sideName, page)
    local now = U.NowMs()
    local metric = "damage"
    if page == "TAKEN" then metric = "taken"
    elseif page == "HEAL" then metric = "heal"
    elseif page == "KILLS" then metric = "kills" end

    local side
    local iterateActors
    if metric == "heal" then
        -- SharedHealing is the sole production Authority for healing reads.
        -- The compatibility PVP/PVE buckets are audited separately and never
        -- unioned into the product ranking after prep5.
        local reads = D.StatsRead
        side = type(reads) == "table" and reads:GetSharedHealingSide(sideName) or nil
        side = side or { actors = {}, totals = { heal = 0 }, active = { heal = { total = 0 } } }
        iterateActors = function(visitor)
            for key, actor in pairs(type(side.actors) == "table" and side.actors or {}) do
                visitor(key, actor, nil)
            end
        end
    else
        local modeStats = self:GetMode(mode)
        side = modeStats[sideName]
        iterateActors = function(visitor)
            for key, actor in pairs(side.actors) do visitor(key, actor, nil) end
        end
    end

    local bossTarget = A:GetBossTarget()
    local excludedCount = A:GetExcludedCount()
    local analysisView = { enabled = false, metric = metric }
    local projectionEnabled = metric == "damage" and A:IsPveFriendlyDamageScope(mode, sideName, page)
        and (bossTarget ~= nil or excludedCount > 0)
    if projectionEnabled then
        if bossTarget ~= nil then
            analysisView = {
                enabled = true,
                metric = metric,
                kind = "BOSS",
                bossTarget = bossTarget,
                historicalIncluded = true,
                rateUnavailable = true,
                selectedAt = bossTarget.selectedAt,
                eventCount = bossTarget.eventCount,
            }
        else
            analysisView = {
                enabled = true,
                metric = metric,
                kind = "EXCLUDED",
                excludedCount = excludedCount,
                rateUnavailable = true,
            }
        end
    end

    local rankingLimit = math.max(1, tonumber(D.Const.MAX_RANKING_ROWS) or 150)
    local heap = {}
    local projectedTotal = 0
    local rawTotal = tonumber(side.totals[metric]) or 0
    local positiveActorCount = 0
    local pinnedSelf = nil
    local normalizedSelf = U.NormalizeName(D.Identity.playerName)
    local normalizedSelfWithWorld = U.NormalizeName(D.Identity.playerNameWithWorld)

    local function CandidateBetterThanItem(value, name, item)
        if item == nil then return true end
        if value ~= item.value then return value > item.value end
        return tostring(name) < tostring(item.name)
    end

    local function ReadActor(key, first, second)
        if metric == "heal" then
            local actor = first
            local value = tonumber(actor and actor.heal) or 0
            local activeMs = self:GetActiveMs(actor and actor.active and actor.active.heal,
                now, D.State.config.personalWindowMs)
            local reads = D.StatsRead
            local name = type(reads) == "table" and reads:GetSharedHealingDisplayName(key, actor)
                or (actor and actor.name or "未知")
            local provisional = actor and actor.provisional == true or false
            return value, activeMs, nil, name, value, provisional,
                actor and actor.repdpsDetailRevision or nil, actor
        end

        local actor = first
        local value = tonumber(actor and actor[metric]) or 0
        local activeMs = metric ~= "kills"
            and self:GetActiveMs(actor and actor.active and actor.active[metric], now, D.State.config.personalWindowMs) or 0
        local actorView = nil
        if projectionEnabled then
            value, activeMs, actorView = self:GetDamageAnalysisValue(mode, sideName, actor, side, now, key)
        end
        return value, activeMs, actorView, actor and actor.name or "未知",
            tonumber(actor and actor[metric]) or 0,
            actor and actor.provisional == true or false,
            actor and actor.repdpsDetailRevision or nil,
            actor
    end

    local function NewRankingItem(key, first, second, value, activeMs, actorView, name, rawValue, provisional, revision, actor)
        local rateUnavailable = type(actorView) == "table" and actorView.rateUnavailable == true
        local rate = metric ~= "kills" and not rateUnavailable
            and value / math.max(activeMs / 1000, 1) or 0
        return {
            key = key,
            name = name,
            value = value,
            rawValue = rawValue,
            rate = rate,
            percent = 0,
            actor = actor,
            analysisView = actorView,
        }
    end

    local function ProcessActor(key, first, second)
        local value, activeMs, actorView, name, rawValue, provisional, revision, actor = ReadActor(key, first, second)
        if value <= 0 then return end
        positiveActorCount = positiveActorCount + 1
        projectedTotal = projectedTotal + value

        local isSelf = false
        if sideName == "friendly" and D.State.config.alwaysShowSelf then
            local normalizedName = U.NormalizeName(name)
            isSelf = key == D.Identity.entityKey
                or normalizedName == normalizedSelf
                or normalizedName == normalizedSelfWithWorld
        end
        local entersHeap = #heap < rankingLimit or CandidateBetterThanItem(value, name, heap[1])
        local item = nil
        if isSelf or entersHeap then
            item = NewRankingItem(key, first, second, value, activeMs, actorView, name,
                rawValue, provisional, revision, actor)
        end
        if isSelf then pinnedSelf = item end
        if #heap < rankingLimit then
            HeapPushWorstFirst(heap, item)
        elseif entersHeap then
            HeapReplaceWorst(heap, item)
        end
    end

    iterateActors(ProcessActor)

    local result = heap
    local total = projectionEnabled and projectedTotal or rawTotal
    if projectionEnabled then
        analysisView.rawTotal = rawTotal
        analysisView.total = total
        if analysisView.kind == "BOSS" then
            analysisView.rateUnavailable = true
            analysisView.totalActiveMs = nil
            analysisView.eventCount = bossTarget.eventCount
        else
            analysisView.excludedCount = excludedCount
            analysisView.rateUnavailable = true
            analysisView.totalActiveMs = nil
        end
    end

    local selfIncluded = false
    if pinnedSelf ~= nil then
        for _, item in ipairs(result) do
            if item == pinnedSelf or item.key == pinnedSelf.key then selfIncluded = true break end
        end
        if not selfIncluded then result[#result + 1] = pinnedSelf end
    end

    for _, item in ipairs(result) do
        item.percent = total > 0 and item.value / total * 100 or 0
    end
    table.sort(result, RankingItemBetter)
    for index, item in ipairs(result) do item.rank = index end

    if pinnedSelf ~= nil and not selfIncluded and positiveActorCount > rankingLimit then
        local exactRank = 1
        iterateActors(function(key, first, second)
            if key == pinnedSelf.key then return end
            local value, _, _, name = ReadActor(key, first, second)
            if value > 0 and CandidateBetterThanItem(value, name, pinnedSelf) then
                exactRank = exactRank + 1
            end
        end)
        pinnedSelf.rank = exactRank
    end
    return result, total, metric, side, analysisView
end

D.EventStore = D.EventStore or {
    nextId = 1,
    raw = {},
    pending = {},
    pendingCursor = 1,
    recentDamageCandidates = {},
    recentDamageHead = 1,
    recentDamageTail = 1,
    recentDamageCount = 0,
}
D.EventStore.raw = D.EventStore.raw or {}
D.EventStore.rawRingCapacity = math.max(0, math.floor(tonumber(D.EventStore.rawRingCapacity) or 0))
D.EventStore.rawRingCount = math.max(0, math.floor(tonumber(D.EventStore.rawRingCount) or 0))
D.EventStore.rawRingWrite = math.max(1, math.floor(tonumber(D.EventStore.rawRingWrite) or 1))
D.EventStore.pending = D.EventStore.pending or {}
D.EventStore.pendingCursor = math.max(1, math.floor(tonumber(D.EventStore.pendingCursor) or 1))
D.EventStore.recentDamageHead = math.max(1, math.floor(tonumber(D.EventStore.recentDamageHead) or 1))
D.EventStore.recentDamageTail = math.max(1, math.floor(tonumber(D.EventStore.recentDamageTail) or 1))
D.EventStore.recentDamageCount = math.max(0, math.floor(tonumber(D.EventStore.recentDamageCount) or 0))
D.EventStore.historyCoverageComplete = D.EventStore.historyCoverageComplete ~= false
D.EventStore.historyCoverageReason = D.EventStore.historyCoverageComplete
    and nil or tostring(D.EventStore.historyCoverageReason or "ROLLED_CORRECTION_WINDOW")
-- When the full correction history has rolled, a detached baseline snapshot can
-- still make the *current* bounded window safely replayable.  This flag is an
-- Authority safety property, not a UI hint: it must only be true when
-- baselineStats is a distinct frozen tree that excludes sessionEvents.
D.EventStore.windowReplaySafe = D.EventStore.historyCoverageComplete == true
    or (D.EventStore.windowReplaySafe == true
        and type(D.EventStore.baselineStats) == "table"
        and D.EventStore.baselineStats ~= D.State.stats)

------------------------------------------------------------------------
-- 事件反向索引（问题 1 修复）
--
-- 数据所有权：本索引归 D.EventStore 所有，是 sessionEvents 的派生视图。
-- 生命周期：与 sessionEvents 同生共死；清空/接管日志时必须同步重置。
-- 是否允许失效：允许。索引只是加速身份升级的缓存，语义上任何时刻都可
--   以安全回退为"整本扫描一次并重建索引"，结果完全一致。
-- 是否可重建：可。BuildIdentityIndex/EnsureIdentityIndex 提供重建入口，
--   热重载后由 Runtime 分帧重建，避免单帧扫描十万条事件。
-- 为什么不能全表扫描：100 人团队逐人从名称升级到稳定 ID 时，全表扫描
--   会变成 100 × 全部历史事件数 的 O(n²) 峰值；索引把每次升级限制为
--   只处理与该名称/临时键相关的少量事件。
-- 单帧预算：重建由 Runtime 按每帧事件预算分批推进，不阻塞主线程。
------------------------------------------------------------------------
D.EventStore.identityIndex = D.EventStore.identityIndex or {}
D.EventStore.identityIndex.version = math.max(0, math.floor(tonumber(D.EventStore.identityIndex.version) or 0))
D.EventStore.identityIndex.byKey = type(D.EventStore.identityIndex.byKey) == "table"
    and D.EventStore.identityIndex.byKey or {}
D.EventStore.identityIndex.maxIndexedEventId = math.max(0,
    math.floor(tonumber(D.EventStore.identityIndex.maxIndexedEventId) or 0))
-- 日志版本：sessionEvents 被整体替换（热重载、清空、接管基线）时必须
-- 递增，EnsureIdentityIndex 以此判断索引是否仍属于当前日志。
D.EventStore.identityGeneration = math.max(0,
    math.floor(tonumber(D.EventStore.identityGeneration) or 0))

-- 事件追加的唯一入口都会调用本函数：把事件端点（source/target 的 key 与
-- 名称）登记进反向索引。升级身份时只需要取出该名称/key 相关的事件集合，
-- 不再遍历整本日志。索引为"名称→事件序号集合"与"key→事件序号集合"两层；
-- key 变化（例如 teamname:<名> → id:<稳定ID>）时两层的序号集合都会被迁移。
local function IsPendingTeamIdentityKey(key)
    return type(key) == "string" and string.sub(key, 1, 9) == "teamname:"
        and not (D.Entities ~= nil and D.Entities.aliases ~= nil
            and D.Entities.aliases[key] ~= nil)
end

local function AppendIdentityIndexSlot(index, key, slot)
    if not IsPendingTeamIdentityKey(key) then return false end
    local list = index.byKey[key]
    if type(list) ~= "table" then
        list = {}
        index.byKey[key] = list
    end
    if list[#list] ~= slot then list[#list + 1] = slot end
    return true
end

function D.EventStore:IndexEvent(event)
    if type(event) ~= "table" then return end
    local index = self.identityIndex
    local slot = math.floor(U.FiniteNumber(event.repdpsSessionIndex, 0) or 0)
    if slot < 1 then slot = math.floor(U.FiniteNumber(event.eventId, 0) or 0) end
    if slot < 1 then return end

    -- 该入口位于每条战斗事件热路径。v0.2.27 在函数内部声明两个局部
    -- helper，Lua 会为每条事件创建新的闭包，即使端点早已是稳定 ID、根本
    -- 不会写入索引。helper 已提升为文件级函数；稳定 ID 事件只执行固定次数
    -- 的前缀判断，不产生临时表或闭包。
    local sourceKey = type(event.sourceKey) == "string" and event.sourceKey or ""
    local targetKey = type(event.targetKey) == "string" and event.targetKey or ""
    local sourceResolvedKey = type(event.sourceResolvedKey) == "string" and event.sourceResolvedKey or ""
    local targetResolvedKey = type(event.targetResolvedKey) == "string" and event.targetResolvedKey or ""

    AppendIdentityIndexSlot(index, sourceKey, slot)
    if targetKey ~= sourceKey then AppendIdentityIndexSlot(index, targetKey, slot) end
    if sourceResolvedKey ~= sourceKey and sourceResolvedKey ~= targetKey then
        AppendIdentityIndexSlot(index, sourceResolvedKey, slot)
    end
    if targetResolvedKey ~= sourceKey and targetResolvedKey ~= targetKey
        and targetResolvedKey ~= sourceResolvedKey then
        AppendIdentityIndexSlot(index, targetResolvedKey, slot)
    end

    index.maxIndexedEventId = math.max(index.maxIndexedEventId, slot)
    if D.Diagnostics ~= nil and D.Diagnostics.counters ~= nil then
        D.Diagnostics.counters.identityIndexEvents =
            (tonumber(D.Diagnostics.counters.identityIndexEvents) or 0) + 1
    end
end

-- 升级身份时迁移索引：把 oldKey 下的所有事件序号重新登记到 newKey 下，
-- 同时把 oldName 的事件序号迁移到 newName（若提供）。这是 O(受影响事件数)
-- 的操作，避免了整本日志扫描。
function D.EventStore:RetargetIdentityIndex(oldKey, newKey, oldName, newName)
    local index = self.identityIndex
    -- 稳定 ID 不需要再次升级，因此无需把整组事件序号复制到 newKey。
    -- 删除旧 teamname 列表即可；后续 IndexEvent 看到 aliases[oldKey]
    -- 已存在也不会重新登记。
    if type(oldKey) == "string" and oldKey ~= "" then index.byKey[oldKey] = nil end
end

-- 重建整个反向索引。返回处理了多少事件；调用方需要分帧驱动，直到返回值
-- 表示全部完成。rebuildFrom 支持从中断点继续（热重载分帧重建）。
function D.EventStore:BuildIdentityIndex(batchLimit, rebuildFrom)
    local events = self.sessionEvents or {}
    batchLimit = math.max(1, math.floor(tonumber(batchLimit) or 500))
    local startAt = math.max(1, math.floor(tonumber(rebuildFrom) or 1))
    local index = self.identityIndex
    -- 重新开始时必须清空旧索引，避免残留陈旧事件序号。
    if startAt <= 1 then
        index.byKey = {}
        index.maxIndexedEventId = 0
    end
    local processed = 0
    local cursor = startAt
    local count = #events
    while cursor <= count and processed < batchLimit do
        local event = events[cursor]
        if type(event) == "table" then
            -- 重建时确保每个事件有数组下标（IndexEvent 用它作索引键）。
            if event.repdpsSessionIndex == nil or math.floor(tonumber(event.repdpsSessionIndex) or 0) ~= cursor then
                event.repdpsSessionIndex = cursor
            end
            self:IndexEvent(event)
        end
        cursor = cursor + 1
        processed = processed + 1
    end
    return cursor > count, cursor
end

-- 惰性确保索引可用：日志清空/热重载后第一次需要索引时调用。返回 true
-- 表示索引已就绪（无需重建或本次批次已完成）。generation 由调用方传入，
-- 等于当前日志的 identityGeneration 时索引可信。
function D.EventStore:EnsureIdentityIndex(batchLimit, generation)
    local events = self.sessionEvents or {}
    local index = self.identityIndex
    local currentGeneration = math.max(0, math.floor(tonumber(generation) or self.identityGeneration))
    if index.version == currentGeneration and index.complete == true then
        return true
    end
    if #events == 0 then
        index.byKey = {}
        index.maxIndexedEventId = 0
        index.complete = true
        index.version = currentGeneration
        return true
    end
    if index.version ~= currentGeneration then
        index.byKey = {}
        index.maxIndexedEventId = 0
        index.complete = false
        index.version = currentGeneration
        self.identityIndexBuildCursor = 1
    end
    local nextBatch = math.max(1, math.floor(tonumber(self.identityIndexBuildCursor) or 1))
    local done, cursor = self:BuildIdentityIndex(batchLimit, nextBatch)
    if done then
        self.identityIndexBuildCursor = nil
        index.maxIndexedEventId = #events
        index.complete = true
        return true
    end
    self.identityIndexBuildCursor = cursor
    index.complete = false
    return false
end

-- 日志被整体替换时调用：递增代次并让索引惰性重建。
-- 旧索引序号集合会错误指向新日志，因此必须标记失效；重建由
-- EnsureIdentityIndex 在下次身份升级时按版本号差异自动触发。
function D.EventStore:ResetIdentityIndex()
    self.identityGeneration = math.max(0, math.floor(tonumber(self.identityGeneration) or 0)) + 1
    self.identityIndexBuildCursor = nil
    self.identityIndex.version = 0
    self.identityIndex.maxIndexedEventId = 0
    self.identityIndex.complete = false
end
D.EventStore.recentDamageCandidates = D.EventStore.recentDamageCandidates or {}
D.EventStore.recentDamageHead = math.max(1, tonumber(D.EventStore.recentDamageHead) or 1)

------------------------------------------------------------------------
-- 事件日志状态（问题 4 修复）
--
-- 取值：
--   ValidatedDense  — 日志为稠密、按 eventId 递增有序的数组，正常运行
--                     新增事件只会追加，无需任何修复。重放前跳过全量检查。
--   ValidatedSparse — 日志曾经稀疏/乱序但已被 NormalizeEventStore 修复为
--                     有效顺序；同样视为已验证，重放前不重复全量扫描。
--   NeedsRepair     — 检测到数组空洞、重复 eventId、顺序错误或损坏，
--                     重放前必须执行分帧修复（NormalizeEventStore）。
--   IndexDirty      — 日志本身有效，但身份反向索引已失效（热重载/清空），
--                     索引在 OnUpdate 中分帧重建，不影响统计正确性。
--
-- 数据所有权：归 D.EventStore；热重载时由 NormalizeEventStore 重设。
-- 生命周期：随日志生命周期；每次 NormalizeEventStore 后重新评估。
-- 是否允许失效：允许。状态只是"是否需要修复"的缓存，语义上任何时刻
--   都能安全地重新运行 NormalizeEventStore 并得到一致结果。
-- 是否可重建：可。NormalizeEventStore 完成后重算状态。
------------------------------------------------------------------------
D.EventStore.journalState = D.EventStore.journalState or "NeedsRepair"
D.EventStore.journalStateVersion = math.max(0, math.floor(tonumber(D.EventStore.journalStateVersion) or 0))

-- EventStore owns journal ordering. Formal Fact and Classification Authorities
-- must both accept a row before it becomes visible. The diagnostic observer is
-- notified only after publish/index and can never veto a formal append.
function D.EventStore:SetFactAuthority(authority)
    self.factAuthority = type(authority) == "table" and authority or nil
end

function D.EventStore:SetClassificationAuthority(authority)
    self.classificationAuthority = type(authority) == "table" and authority or nil
end

function D.EventStore:SetEventBlockObserver(observer)
    self.eventBlockObserver = type(observer) == "table" and observer or nil
end

function D.EventStore:SetEventShadowObserver(observer)
    self.eventShadowObserver = type(observer) == "table" and observer or nil
end

local function NotifyFactAppend(store, event, sessionIndex)
    local authority = store.factAuthority
    if type(authority) ~= "table" or type(authority.OnLegacyEventAppended) ~= "function" then return end
    authority:OnLegacyEventAppended(event, sessionIndex)
end

local function NotifyClassificationAppend(store, event, sessionIndex)
    local authority = store.classificationAuthority
    if type(authority) ~= "table" or type(authority.OnLegacyEventAppended) ~= "function" then return end
    authority:OnLegacyEventAppended(event, sessionIndex)
end

local function NotifyEventBlockAppend(store, event, sessionIndex)
    if D.State == nil or D.State.config == nil
        or D.State.config.diagnosticsEnabled ~= true then return end
    local observer = store.eventBlockObserver
    if type(observer) ~= "table" or type(observer.OnLegacyEventAppended) ~= "function" then return end
    local ok, err = pcall(observer.OnLegacyEventAppended, observer, event, sessionIndex)
    if not ok and type(observer.DisableAfterFailure) == "function" then
        pcall(observer.DisableAfterFailure, observer, err)
    end
end

local function NotifyEventShadowAppend(store, event, sessionIndex)
    if D.State == nil or D.State.config == nil
        or D.State.config.diagnosticsEnabled ~= true then return end
    local observer = store.eventShadowObserver
    if type(observer) ~= "table" or type(observer.OnLegacyEventAppended) ~= "function" then return end
    local ok, err = pcall(observer.OnLegacyEventAppended, observer, event, sessionIndex)
    if not ok and type(observer.DisableAfterFailure) == "function" then
        pcall(observer.DisableAfterFailure, observer, err)
    end
end

-- 事件追加的统一入口：先确认日志状态允许追加（稠密追加），再登记索引。
-- 返回追加后的数组下标；返回 0 表示日志需要修复，调用方应先修复再追加。
function D.EventStore:AppendSessionEvent(event)
    if type(event) ~= "table" then return 0 end
    self.sessionEvents = self.sessionEvents or {}
    local events = self.sessionEvents
    if self.journalState ~= "ValidatedDense" and self.journalState ~= "ValidatedSparse" then
        -- 日志处于修复中：禁止直接追加，避免写入一半的数组。
        return 0
    end
    local index = #events + 1
    -- Immutable Fact ownership is acquired first, then mutable Classification.
    -- repdpsSessionIndex is intentionally assigned only after both succeed, so
    -- a Classification failure can discard the unjournaled Fact atomically.
    NotifyFactAppend(self, event, index)
    local ok, err = pcall(NotifyClassificationAppend, self, event, index)
    if not ok then
        local authority = self.factAuthority
        if type(authority) == "table" and type(authority.DiscardUnjournaled) == "function" then
            pcall(authority.DiscardUnjournaled, authority, event, "CLASSIFICATION_APPEND_FAILED")
        end
        error(err, 0)
    end
    event.repdpsSessionIndex = index
    events[index] = event
    if self.IndexEvent ~= nil then self:IndexEvent(event) end
    -- EventBlock is diagnostic-only and is notified after the formal journal
    -- append. It can never veto EventStore, Fact or Classification ownership.
    NotifyEventBlockAppend(self, event, index)
    NotifyEventShadowAppend(self, event, index)
    return index
end

-- 标记日志需要修复（检测到空洞/重复/乱序/损坏时调用）。
if type(D.EventStore.baselineStats) == "table" then
    local baselineSchema = tonumber(D.EventStore.baselineStats.schemaVersion)
    if baselineSchema == 1 then
        D.EventStore.baselineStats = MigrateStatsV1(D.EventStore.baselineStats)
    elseif baselineSchema == 2 then
        D.EventStore.baselineStats = MigrateStatsV2ToV3(D.EventStore.baselineStats)
    elseif baselineSchema == 3 then
        D.EventStore.baselineStats = SanitizeStatsV3(D.EventStore.baselineStats)
    else
        D.EventStore.baselineStats = nil
    end
end
if D.State.statsLoadSource == "memory_v1" and type(D.EventStore.baselineStats) == "table" and #(D.EventStore.sessionEvents or {}) > 0 then
    D.State.stats = U.DeepCopy(D.EventStore.baselineStats)
    D.State.dirty.reclassify = true
end

-- Return raw diagnostic events in chronological order. Normal combat never calls
-- this helper; it exists for hot reload/diagnostic readers, so the one bounded
-- result allocation does not sit on the combat hot path.
function D.EventStore:GetRawOrdered()
    local capacity = math.max(0, math.floor(tonumber(self.rawRingCapacity) or 0))
    local count = math.max(0, math.floor(tonumber(self.rawRingCount) or 0))
    local write = math.max(1, math.floor(tonumber(self.rawRingWrite) or 1))
    if capacity <= 0 or count <= 0 then
        return U.OrderedArrayValues(self.raw)
    end
    count = math.min(count, capacity)
    local result = {}
    local oldest = count < capacity and 1 or write
    for offset = 0, count - 1 do
        local index = ((oldest - 1 + offset) % capacity) + 1
        local event = self.raw[index]
        if event ~= nil then result[#result + 1] = event end
    end
    return result
end

function D.EventStore:EnsureRawRing(limit)
    limit = U.Clamp(limit or D.Const.MAX_RAW_EVENTS, 100, D.Const.MAX_RAW_EVENTS)
    local capacity = math.max(0, math.floor(tonumber(self.rawRingCapacity) or 0))
    local count = math.max(0, math.floor(tonumber(self.rawRingCount) or 0))
    local write = math.max(1, math.floor(tonumber(self.rawRingWrite) or 1))
    if capacity == limit and count <= capacity and write <= capacity then return end

    local ordered = self:GetRawOrdered()
    local startAt = math.max(1, #ordered - limit + 1)
    self.raw = {}
    local kept = 0
    for index = startAt, #ordered do
        kept = kept + 1
        self.raw[kept] = ordered[index]
    end
    self.rawRingCapacity = limit
    self.rawRingCount = kept
    self.rawRingWrite = kept < limit and (kept + 1) or 1
end

function D.EventStore:ResetRawRing()
    self.raw = {}
    self.rawRingCapacity = 0
    self.rawRingCount = 0
    self.rawRingWrite = 1
end

function D.EventStore:PushRaw(event)
    -- The raw journal is diagnostic-only. v0.2.27 periodically copied roughly
    -- 90% of the whole array whenever it crossed the configured limit. With
    -- diagnostics enabled in a raid, that produced a regular allocation/GC spike.
    -- A fixed-capacity ring overwrites exactly one reference per combat event.
    if D.State.config.diagnosticsEnabled ~= true then return end
    local limit = U.Clamp(D.State.config.rawEventLimit or D.Const.MAX_RAW_EVENTS, 100, D.Const.MAX_RAW_EVENTS)
    self:EnsureRawRing(limit)
    local write = math.max(1, math.floor(tonumber(self.rawRingWrite) or 1))
    self.raw[write] = event
    write = write + 1
    if write > limit then write = 1 end
    self.rawRingWrite = write
    self.rawRingCount = math.min(limit, math.max(0, math.floor(tonumber(self.rawRingCount) or 0)) + 1)
end

function D.EventStore:PushPending(event)
    -- Summary bookkeeping and bounded eviction are owned by Runtime so dropped
    -- entries can be subtracted or safely aggregated without corrupting totals.
    self.pending[#self.pending + 1] = event
    D.Diagnostics.counters.pendingEvents = #self.pending
end

D.Runtime = D.Runtime or {
    uiReady = false,
    started = false,
    eventHandlers = {},
    lastModeEpoch = { PVP = 0, PVE = 0 },
}

Boot.onLauncherDragStop = function(widget)
    U.StoreRect(D.State.ui.launcher, widget)
    D.MarkUiDirty()
end

function D.SaveConfigNow()
    if P:IsWriteFenced("config") then
        P:WarnWriteFence("config")
        D.State.dirty.configSave = false
        D.State.timers.configSave = 0
        return false
    end
    D.State.config.schemaVersion = D.Const.CONFIG_SCHEMA_VERSION
    local ok = P.SaveTransactional("config", D.State.config)
    D.State.timers.configSave = 0
    if ok then D.State.dirty.configSave = false end
    return ok
end

function D.SaveUiNow()
    if P:IsWriteFenced("ui") then
        P:WarnWriteFence("ui")
        D.State.dirty.uiSave = false
        D.State.timers.uiSave = 0
        return false
    end
    D.State.ui.schemaVersion = 1
    local ok = P.SaveTransactional("ui", D.State.ui)
    D.State.timers.uiSave = 0
    if ok then D.State.dirty.uiSave = false end
    return ok
end

function D.SaveRulesNow()
    if P:IsWriteFenced("rules") then
        P:WarnWriteFence("rules")
        D.State.dirty.rulesSave = false
        D.State.timers.rulesSave = 0
        return false
    end
    D.State.rules.schemaVersion = D.Const.RULES_SCHEMA_VERSION
    local ok = P.SaveTransactional("rules", D.State.rules)
    D.State.timers.rulesSave = 0
    if ok then D.State.dirty.rulesSave = false end
    return ok
end

local function CompactNumberMap(map, limit)
    if type(map) ~= "table" or U.TableCount(map) <= limit then return map end
    local entries = {}
    local existingOther = tonumber(map["其他"]) or 0
    for key, value in pairs(map) do
        if key ~= "其他" then entries[#entries + 1] = { key = key, value = tonumber(value) or 0 } end
    end
    table.sort(entries, function(a, b) return a.value > b.value end)
    local compacted = {}
    local other = existingOther
    for index, entry in ipairs(entries) do
        if index <= limit - 1 then compacted[entry.key] = entry.value
        else other = other + entry.value end
    end
    if other > 0 then compacted["其他"] = other end
    return compacted
end

local function CompactDamageTargetMap(map, limit)
    if type(map) ~= "table" or U.TableCount(map) <= limit then return map end
    local protected = {}
    local normal = {}
    local existingOther = tonumber(map["其他"]) or 0
    for key, value in pairs(map) do
        if key ~= "其他" then
            local entry = { key = key, value = tonumber(value) or 0 }
            if A:IsExcluded(key) or A:IsBoss(key) then protected[#protected + 1] = entry
            else normal[#normal + 1] = entry end
        end
    end
    table.sort(protected, function(a, b) return a.value > b.value end)
    table.sort(normal, function(a, b) return a.value > b.value end)
    local compacted = {}
    for _, entry in ipairs(protected) do compacted[entry.key] = entry.value end
    local normalLimit = math.max(0, limit - #protected - 1)
    local other = existingOther
    for index, entry in ipairs(normal) do
        if index <= normalLimit then compacted[entry.key] = entry.value
        else other = other + entry.value end
    end
    if other > 0 then compacted["其他"] = other end
    return compacted
end

local function CompactActorBreakdowns(modeName, sideName, actor)
    local details = EnsureActorDetails(actor)
    local changed = false
    for _, metric in ipairs({ "damage", "taken", "heal" }) do
        local previous = details[metric].abilities
        local compacted = CompactNumberMap(previous, D.Const.MAX_BREAKDOWN_KEYS)
        if compacted ~= previous then changed = true end
        details[metric].abilities = compacted
    end
    if type(details.kills) == "table" then
        local previous = details.kills.abilities
        local compacted = CompactNumberMap(previous, D.Const.MAX_BREAKDOWN_KEYS)
        if compacted ~= previous then changed = true end
        details.kills.abilities = compacted
    end
    -- PVE friendly damage targets are the source of truth for retrospective
    -- exclusion. Keep that one map lossless; all other high-cardinality detail
    -- maps are bounded continuously, not only when persistence eventually runs.
    if modeName ~= "PVE" or sideName ~= "friendly" then
        local previous = details.damage.targets
        local compacted = CompactDamageTargetMap(previous, D.Const.MAX_BREAKDOWN_KEYS)
        if compacted ~= previous then changed = true end
        details.damage.targets = compacted
    end
    local previous = details.taken.sources
    local compacted = CompactNumberMap(previous, D.Const.MAX_BREAKDOWN_KEYS)
    if compacted ~= previous then changed = true end
    details.taken.sources = compacted

    previous = details.heal.targets
    compacted = CompactNumberMap(previous, D.Const.MAX_BREAKDOWN_KEYS)
    if compacted ~= previous then changed = true end
    details.heal.targets = compacted

    if type(details.kills) == "table" then
        previous = details.kills.targets
        compacted = CompactNumberMap(previous, D.Const.MAX_BREAKDOWN_KEYS)
        if compacted ~= previous then changed = true end
        details.kills.targets = compacted
    end
    if changed then
        actor.repdpsDetailRevision = (tonumber(actor.repdpsDetailRevision) or 0) + 1
    end
    return changed
end

function S:CompactBreakdowns()
    for _, modeName in ipairs({ "PVP", "PVE" }) do
        local modeStats = D.State.stats[modeName]
        for _, sideName in ipairs({ "friendly", "enemy" }) do
            local side = modeStats and modeStats[sideName] or nil
            for _, actor in pairs(side and side.actors or {}) do
                CompactActorBreakdowns(modeName, sideName, actor)
            end
        end
    end
    self.breakdownCompactState = nil
    self.breakdownCompactedRevision = tonumber(self.breakdownMutationRevision) or 0
    self.breakdownCompactedStatsRoot = D.State.stats
end

function S:CompactBreakdownsStep(actorBudget)
    local budget = math.max(1, math.floor(tonumber(actorBudget) or 12))
    local processed = 0

    -- 先处理真正新增过明细键的 actor。热路径不再因为一个玩家新增一种技能
    -- 就扫描所有历史角色；每个 dirty actor 最多入队一次，更新其引用即可。
    local head = math.max(1, math.floor(tonumber(self.breakdownDirtyQueueHead) or 1))
    local tail = math.max(0, math.floor(tonumber(self.breakdownDirtyQueueTail) or 0))
    while processed < budget and head <= tail do
        local composite = self.breakdownDirtyQueue[head]
        self.breakdownDirtyQueue[head] = nil
        head = head + 1
        local entry = self.breakdownDirtyActors[composite]
        self.breakdownDirtyActors[composite] = nil
        if type(entry) == "table" and entry.statsRoot == D.State.stats then
            local modeStats = D.State.stats[entry.mode]
            local side = modeStats and modeStats[entry.sideName]
            local current = side and side.actors and side.actors[entry.actorKey]
            if current == entry.actor then
                CompactActorBreakdowns(entry.mode, entry.sideName, current)
            end
        end
        processed = processed + 1
    end
    self.breakdownDirtyQueueHead = head
    if head > tail then
        self.breakdownDirtyQueue = {}
        self.breakdownDirtyQueueHead = 1
        self.breakdownDirtyQueueTail = 0
    end

    if processed >= budget then return false, processed end
    if self.breakdownFullAuditRequested ~= true and self.breakdownCompactState == nil then
        self.breakdownCompactedRevision = tonumber(self.breakdownMutationRevision) or 0
        self.breakdownCompactedStatsRoot = D.State.stats
        return true, processed
    end

    local modes = { "PVP", "PVE" }
    local sides = { "friendly", "enemy" }
    local statsRoot = D.State.stats
    local state = self.breakdownCompactState
    if type(state) ~= "table" or state.statsRoot ~= statsRoot then
        state = { modeIndex = 1, sideIndex = 1, lastKey = nil, statsRoot = statsRoot }
    end

    while processed < budget and state.modeIndex <= #modes do
        local modeName = modes[state.modeIndex]
        local sideName = sides[state.sideIndex]
        local modeStats = statsRoot[modeName]
        local side = modeStats and modeStats[sideName] or nil
        local actors = side and side.actors or {}
        local ok, key, actor = pcall(next, actors, state.lastKey)
        if not ok then state.lastKey = nil; key, actor = next(actors, nil) end
        if key == nil then
            state.lastKey = nil
            state.sideIndex = state.sideIndex + 1
            if state.sideIndex > #sides then state.sideIndex = 1; state.modeIndex = state.modeIndex + 1 end
        else
            state.lastKey = key
            CompactActorBreakdowns(modeName, sideName, actor)
            processed = processed + 1
        end
    end

    if state.modeIndex > #modes then
        self.breakdownCompactState = nil
        self.breakdownFullAuditRequested = false
        -- 全审计期间新增的键会进入 dirty 队列；若队列此刻为空，则本版本已
        -- 完整压缩。否则下一帧先处理队列后再标记 current。
        if (tonumber(self.breakdownDirtyQueueTail) or 0) == 0 then
            self.breakdownCompactedRevision = tonumber(self.breakdownMutationRevision) or 0
            self.breakdownCompactedStatsRoot = D.State.stats
        end
        D.Diagnostics.counters.breakdownCompactPasses =
            (tonumber(D.Diagnostics.counters.breakdownCompactPasses) or 0) + 1
        return true, processed
    end
    self.breakdownCompactState = state
    return false, processed
end


function S:BeginPersistenceSnapshot()
    if self.persistenceReadyPayload ~= nil then return nil end
    if self.persistenceSnapshotJob ~= nil then return self.persistenceSnapshotJob end
    -- Persist closure derived values only once per snapshot, never once per
    -- combat event. This touches the committed root before the incremental
    -- copy captures it.
    self:EnsureClosureCurrent("PVP")
    self:EnsureClosureCurrent("PVE")
    local job = {
        statsRoot = D.State.stats,
        revision = tonumber(self.statsMutationRevision) or 0,
        copy = U.BeginIncrementalDeepCopy(D.State.stats),
        startedAt = U.NowMs(),
    }
    self.persistenceSnapshotJob = job
    D.Diagnostics.counters.incrementalStatsSnapshots =
        (tonumber(D.Diagnostics.counters.incrementalStatsSnapshots) or 0) + 1
    return job
end

function S:CancelPersistenceSnapshot()
    if self.persistenceSnapshotJob == nil and self.persistenceReadyPayload == nil then return false end
    self.persistenceSnapshotJob = nil
    self.persistenceReadyPayload = nil
    D.Diagnostics.counters.cancelledStatsSnapshots =
        (tonumber(D.Diagnostics.counters.cancelledStatsSnapshots) or 0) + 1
    return true
end

function S:StepPersistenceSnapshot(budget)
    if self.persistenceReadyPayload ~= nil then return true, self.persistenceReadyPayload, nil end
    local job = self.persistenceSnapshotJob or self:BeginPersistenceSnapshot()
    if job == nil then return false, nil, "NO_JOB" end
    if job.statsRoot ~= D.State.stats
        or tonumber(job.revision) ~= (tonumber(self.statsMutationRevision) or 0) then
        self:CancelPersistenceSnapshot()
        return false, nil, "STALE"
    end

    -- 阶段一：分帧深拷贝统计快照。
    if job.copy ~= nil then
        local done, processed, err = U.StepIncrementalDeepCopy(job.copy, budget)
        D.Diagnostics.counters.statsSnapshotFields =
            (tonumber(D.Diagnostics.counters.statsSnapshotFields) or 0) + (tonumber(processed) or 0)
        if err ~= nil then
            self:CancelPersistenceSnapshot()
            return false, nil, err
        end
        if not done then return false, nil, nil end
        local payload = job.copy.result
        job.copy = nil
        job.payload = payload
        local now = U.NowMs()
        payload.schemaVersion = D.Const.STATS_SCHEMA_VERSION
        payload.sharedHealing = SanitizeSharedHealingV1(payload.sharedHealing, payload)
        payload.identityProjection = SanitizeIdentityProjectionV1(payload.identityProjection)
        payload.lastSaveAt = now
        -- v0.2.25（问题 11）：快照复制完成后，最终整理（关闭活动时间、
        -- 共享治疗合并、细节收尾）不再单帧扫描全部 actor，改为分帧推进。
        job.finalize = self:BeginFinalizeForPersistence(payload, now)
        return false, nil, nil
    end

    -- 阶段二：分帧执行最终整理。
    if job.finalize ~= nil then
        local doneFinalize = self:StepFinalizeForPersistence(job.finalize, budget)
        if not doneFinalize then return false, nil, nil end
        local payload = job.payload
        self.persistenceSnapshotJob = nil
        self.persistenceReadyPayload = payload
        return true, payload, nil
    end

    return false, nil, "NO_STATE"
end

local function CommitStatsPayload(payload, discardPreviousRecoverySlots)
    local now = U.NowMs()
    local ok = P.SaveRotatingStats(payload)
    if ok and discardPreviousRecoverySlots == true then
        local obsoleteSlot = P.statsActiveSlot == "primary" and "backup" or "primary"
        P.ClearRaw(P.Key("stats", obsoleteSlot))
        P.ClearRaw(P.Key("stats", "pending"))
    end
    if ok then
        D.State.stats.lastSaveAt = tonumber(payload and payload.lastSaveAt) or now
        -- The shard shadow receives the detached, finalized payload only after
        -- the formal rotating slot is durable. Any shadow failure is isolated
        -- and cannot change the formal save result.
        P:NotifyStatsShardObserver(payload, {
            reason = "FORMAL_ROTATING_SAVE",
            sequence = P.statsSequence,
            slot = P.statsActiveSlot,
            envelopeVersion = P.STATS_ENVELOPE_VERSION,
        })
        -- A save during an active segment is only an intermediate checkpoint.
        -- Keep one later save scheduled so the final idle-window duration is
        -- persisted even when no further combat event arrives.
        D.State.dirty.statsSave = S:HasChangingActives(D.State.stats, now)
    end
    return ok
end

function D.SavePreparedStats(payload, discardPreviousRecoverySlots)
    if type(payload) ~= "table" then return false end
    local ok = CommitStatsPayload(payload, discardPreviousRecoverySlots)
    if ok and S.persistenceReadyPayload == payload then S.persistenceReadyPayload = nil end
    return ok
end

function D.QueueStatsSave()
    D.State.dirty.statsSave = true
    D.State.timers = D.State.timers or {}
    local interval = tonumber(D.State.config and D.State.config.persistenceMs) or 0
    D.State.timers.save = math.max(tonumber(D.State.timers.save) or 0, interval)
    return true
end

function D.SaveStatsNow(discardPreviousRecoverySlots)
    S:CancelPersistenceSnapshot()
    local now = U.NowMs()
    -- Do not scan every historical actor merely to close expired live clocks.
    -- GetActiveMs/TouchActive already handle an open-but-expired segment
    -- correctly, and the persistence copy is finalized below. Avoiding this
    -- redundant pass removes one O(all actors) save-time spike.
    if not S:IsBreakdownCompactionCurrent() then S:CompactBreakdowns() end
    D.State.stats.schemaVersion = D.Const.STATS_SCHEMA_VERSION
    D.State.stats.sharedHealing = SanitizeSharedHealingV1(D.State.stats.sharedHealing, D.State.stats)
    D.State.stats.identityProjection = SanitizeIdentityProjectionV1(D.State.stats.identityProjection)
    D.State.stats.lastSaveAt = now
    -- Persist a finalized copy so process-local open segments are never restored
    -- with stale timestamps. The live in-memory segment remains open and keeps
    -- counting smoothly after the save.
    local payload = U.DeepCopy(D.State.stats)
    S:FinalizeForPersistence(payload, now)
    return CommitStatsPayload(payload, discardPreviousRecoverySlots)
end

Boot:CompletePhase("CORE_READY")
D.Diagnostics.status = "CORE_READY"
