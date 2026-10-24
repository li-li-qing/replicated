------------------------------------------------------------------------
-- Replicated Suite · 光环只读观察
-- 作者：Replicated
-- QQ群：1104129461
--
-- Aura 观察领域共享 Buff/Debuff/Hidden Buff 只读事实缓存，只拥有原生观察事实；Healer/Plates/Boss 等保留业务
-- 解释。没有 Tick 或后台扫描，消费者显式请求快照，短期有界缓存合并重复读取。
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
S.Services = S.Services or {}

local A = {
    Id = "v3.aura_observation",
    version = 2,
    cache = {},
    cacheCount = 0,
    cacheMax = 96,
    defaultTtlMs = 120,
    revision = 0,
    nativeReads = 0,
    tooltipFallbacks = 0,
    scanFailures = 0,
}
A.presentationBoundary = "service_only"
S.Services.AuraObservationV3 = A

local LANES = {
    buff = { count = "UnitBuffCount", data = "UnitBuff", tip = "UnitBuffTooltip", sourceMask = 1 },
    debuff = { count = "UnitDeBuffCount", data = "UnitDeBuff", tip = "UnitDeBuffTooltip", sourceMask = 2 },
    hidden = { count = "UnitHiddenBuffCount", data = "UnitHiddenBuff", tip = "UnitHiddenBuffTooltip", sourceMask = 4 },
}

local STATUS_KEYS = {
    stack = { "stack", "stackCount", "count" },
    timeLeft = { "timeLeft", "time_left", "remainTime", "remainingTime", "remain_time" },
    name = { "name", "buffName" },
    icon = { "path", "iconPath", "icon_path", "icon", "skillIcon", "skill_icon", "texture" },
}

local function NowMs() return math.max(0, tonumber(S.NowMs and S.NowMs()) or 0) end
local function Clamp(value, minimum, maximum)
    value = math.floor(tonumber(value) or minimum)
    if value < minimum then return minimum end
    if value > maximum then return maximum end
    return value
end

local function CopyShallow(value)
    if type(value) ~= "table" then return value end
    local out = {}
    for key, item in pairs(value) do
        if type(item) ~= "table" then out[key] = item end
    end
    return out
end

local function PickEffectId(row)
    -- 优先 buff_id：唯一有实机证据的字段，wbdebuff/buffblackdragon.lua:46 用 UnitDeBuff(...)["buff_id"] 匹
    -- 配 23474/25846。若 effectId 与其不同，不能拿来作状态 map 键，否则数字 ID 规则全部静默失配。
    if type(row) ~= "table" then return nil end
    return tonumber(row.buff_id or row.buffId or row.buffID or row.effectId or row.effect_id or row.id or row.buffType or row.buff_type or row.type)
end

local function ExtractEffectId(data, tooltip)
    return PickEffectId(data) or PickEffectId(tooltip)
end

-- 每行会多次提取字段；直接检查两份原始来源，避免反复创建捕获keys的临时闭包。
-- 仍先完整扫描primary的别名，再扫描secondary；0有效，false/非法数字不阻止后续别名。
local function PickNumber(primary, secondary, keys)
    if type(primary) == "table" then
        for _, key in ipairs(keys) do
            local value = tonumber(primary[key])
            if value ~= nil then return value end
        end
    end
    if type(secondary) == "table" then
        for _, key in ipairs(keys) do
            local value = tonumber(secondary[key])
            if value ~= nil then return value end
        end
    end
    return nil
end

local function PickString(primary, secondary, keys)
    if type(primary) == "table" then
        for _, key in ipairs(keys) do
            local value = primary[key]
            if type(value) == "string" and value ~= "" then return value end
        end
    end
    if type(secondary) == "table" then
        for _, key in ipairs(keys) do
            local value = secondary[key]
            if type(value) == "string" and value ~= "" then return value end
        end
    end
    return nil
end

-- Buff ID 到名称/图标解析归共享 BuffMetadataV3，通过 X2Ability:GetBuffTooltip、有界缓存及负缓存；此文件只保
-- 留薄访问器，降低扫描成本。
local function BuffMeta()
    return S.Services ~= nil and S.Services.BuffMetadataV3 or nil
end
local function PeekBuffInfo(id)
    local meta = BuffMeta()
    if meta == nil or type(meta.GetCached) ~= "function" then return nil end
    return meta:GetCached(id)
end

-- 保守提取原生尾部返回中的名称（A:Call 最多额外三个值）。名称须为短非数字字符串，不含路径分隔或扩展名；ID、
-- 图标路径、整段 tooltip 文本均拒绝，不能猜。
local function NameFromExtra(extra)
    if type(extra) ~= "table" then return nil end
    for i = 1, #extra do
        local v = extra[i]
        if type(v) == "string" and v ~= "" and #v <= 64
            and string.match(v, "^%d+$") == nil
            and string.find(v, "/", 1, true) == nil
            and string.find(v, "\\", 1, true) == nil
            and string.find(v, ".dds", 1, true) == nil
            and string.find(v, "\n", 1, true) == nil then
            return v
        end
    end
    return nil
end


local function AddSourceMask(mask, sourceMask)
    mask = math.max(0, math.floor(tonumber(mask) or 0))
    sourceMask = math.max(1, math.floor(tonumber(sourceMask) or 1))
    if math.floor(mask / sourceMask) % 2 == 0 then mask = mask + sourceMask end
    return mask
end

local function CopyLane(row)
    if type(row) ~= "table" then return { available = false, reliable = false, count = 0, scanned = 0, limit = 0, rows = {} } end
    local out = {
        available = row.available == true,
        reliable = row.reliable == true,
        complete = row.complete == true,
        count = tonumber(row.count) or 0,
        scanned = tonumber(row.scanned) or 0,
        limit = tonumber(row.limit) or 0,
        at = tonumber(row.at) or 0,
        rows = {},
    }
    for index, item in ipairs(type(row.rows) == "table" and row.rows or {}) do
        out.rows[index] = {
            index = tonumber(item.index) or index,
            effectId = item.effectId,
            data = CopyShallow(item.data),
            tooltip = CopyShallow(item.tooltip),
            extra = CopyShallow(item.extra),
            tooltipExtra = CopyShallow(item.tooltipExtra),
        }
    end
    return out
end

function A:_CacheKey(unitId)
    return tostring(unitId or "")
end

function A:_PruneOne()
    local oldestKey, oldestAt
    for key, entry in pairs(self.cache) do
        local at = tonumber(entry and entry.at) or 0
        if oldestAt == nil or at < oldestAt then oldestKey, oldestAt = key, at end
    end
    if oldestKey ~= nil then self.cache[oldestKey] = nil; self.cacheCount = math.max(0, self.cacheCount - 1) end
end

function A:_Store(key, entry)
    if self.cache[key] == nil then self.cacheCount = self.cacheCount + 1 end
    self.cache[key] = entry
    while self.cacheCount > self.cacheMax do self:_PruneOne() end
end

function A:_LaneGate(lane)
    local spec = LANES[lane]
    if spec == nil or S.Api == nil or X2Unit == nil then return nil, false, false, false end
    local prefix = "X2Unit:"
    local canCount = S.Api:IsCapabilityAllowed(prefix .. spec.count) == true
    local canData = S.Api:IsCapabilityAllowed(prefix .. spec.data) == true
    local canTip = S.Api:IsCapabilityAllowed(prefix .. spec.tip) == true
    return spec, canCount, canData, canTip
end

function A:_ScanLane(unitId, lane, limit)
    local spec, canCount, canData, canTip = self:_LaneGate(lane)
    if spec == nil or canCount ~= true then return { available = false, reliable = false, count = 0, scanned = 0, limit = limit, rows = {} } end

    self.nativeReads = self.nativeReads + 1
    local okCount, rawCount = S.Api:Call(X2Unit, spec.count, unitId)
    if okCount ~= true then
        self.scanFailures = self.scanFailures + 1
        return { available = false, reliable = false, count = 0, scanned = 0, limit = limit, rows = {} }
    end

    local count = math.max(0, math.floor(tonumber(rawCount) or 0))
    local scanned = math.min(count, limit)
    local rows, reliable = {}, canData == true
    if canData ~= true and canTip ~= true then reliable = false end

    local dataWorking, tipWorking = canData == true, canTip == true
    for index = 1, scanned do
        local data, tooltip = nil, nil
        local dataExtra, tipExtra = nil, nil
        if dataWorking then
            self.nativeReads = self.nativeReads + 1
            -- A:Call 在第 4-6 位暴露原生额外返回；部分 RU 把显示名移出行表放到第二返回值，须捕获而非丢弃。
            local okData, value, _, b2, c2, d2 = S.Api:Call(X2Unit, spec.data, unitId, index)
            if okData == true then
                data = value
                if b2 ~= nil or c2 ~= nil or d2 ~= nil then dataExtra = { b2, c2, d2 } end
            else
                dataWorking, reliable = false, false
            end
        end
        local effectId = ExtractEffectId(data, nil)
        -- RU 单位行常省略 name。ID 缺失，或行无可用 name 且 ability-tooltip 缓存尚不能解析时，才读取已有
        -- plates 证据支持的 tooltip 行。稳态扫描通过缓存门禁免于重复读取；新 ID 首次承担一次 tooltip，随后
        -- 由能力缓存回答。
        local rowName = PickString(data, nil, STATUS_KEYS.name) or NameFromExtra(dataExtra)
        if tipWorking and (effectId == nil or (rowName == nil and PeekBuffInfo(effectId) == nil)) then
            self.nativeReads = self.nativeReads + 1
            self.tooltipFallbacks = self.tooltipFallbacks + 1
            local okTip, value, _, tb, tc, td = S.Api:Call(X2Unit, spec.tip, unitId, index)
            if okTip == true then
                tooltip = value
                if tb ~= nil or tc ~= nil or td ~= nil then tipExtra = { tb, tc, td } end
            else
                tipWorking, reliable = false, false
            end
            if effectId == nil then effectId = ExtractEffectId(data, tooltip) end
        end
        rows[#rows + 1] = {
            index = index,
            effectId = effectId,
            data = CopyShallow(data),
            tooltip = CopyShallow(tooltip),
            extra = dataExtra,
            tooltipExtra = tipExtra,
        }
    end
    local complete = scanned >= count
    if complete ~= true then reliable = false end
    return { available = true, reliable = reliable, complete = complete, count = count, scanned = scanned, limit = limit, rows = rows }
end

function A:AcquireConsumer(token, options)
    if self.Demand == nil then return false, "aura demand unavailable" end
    return self.Demand:Acquire(token, options, "aura_consumer")
end

function A:ReleaseConsumer(token)
    if self.Demand == nil then return false, "aura demand unavailable" end
    return self.Demand:Release(token, "aura_consumer")
end

function A:ClearCache()
    self.cache, self.cacheCount = {}, 0
    return true
end

function A:GetSnapshot(unitId, options)
    options = type(options) == "table" and options or {}
    if self.Demand == nil or self.Demand.count <= 0 then return nil, "aura service has no consumer" end
    local key = self:_CacheKey(unitId)
    if key == "" then return nil, "unit id required" end

    local ttlMs = Clamp(options.ttlMs or self.defaultTtlMs, 0, 2000)
    local requested = {
        buff = options.buff ~= false and Clamp(options.buffLimit or options.limit or 64, 0, 256) or 0,
        debuff = options.debuff ~= false and Clamp(options.debuffLimit or options.limit or 64, 0, 256) or 0,
        hidden = options.hidden == true and Clamp(options.hiddenLimit or options.limit or 64, 0, 256) or 0,
    }
    local now = NowMs()
    local cached = self.cache[key]
    local entry = type(cached) == "table" and cached or { unitId = key }
    local changed = false
    for lane, limit in pairs(requested) do
        if limit > 0 then
            local existing = entry[lane]
            -- 留存模式的Buff/DeBuff事件可能在同一时钟刻度内增删；ttl=0仍会命中旧缓存。
            -- 仅显式forceRefresh绕过缓存，其他消费者/常规轮询继续共享TTL，不改事实分类。
            local fresh = options.forceRefresh~=true and type(existing) == "table" and now - (tonumber(existing.at) or 0) <= ttlMs
            local covered = fresh and (existing.complete == true or (tonumber(existing.limit) or 0) >= limit)
            if covered ~= true then
                local scanned = self:_ScanLane(unitId, lane, limit)
                scanned.at = now
                entry[lane] = scanned
                changed = true
            end
        end
    end

    if changed == true or cached == nil then
        entry.at = now
        self.revision = self.revision + 1
        entry.revision = self.revision
        self:_Store(key, entry)
        cached = entry
    else
        cached = entry
    end

    return {
        unitId = key,
        revision = tonumber(cached.revision) or 0,
        at = tonumber(cached.at) or 0,
        buff = requested.buff > 0 and CopyLane(cached.buff) or nil,
        debuff = requested.debuff > 0 and CopyLane(cached.debuff) or nil,
        hidden = requested.hidden > 0 and CopyLane(cached.hidden) or nil,
    }
end

-- 从已捕获快照构建归一化只读状态投影，不读取 Native，也不拥有业务含义。Healer/Plates/Raid Readiness 自行判
-- 断效果；投影提供 id/source/stack/time/name/icon 稳定事实，消费者无需重扫 X2Unit。
function A:GetStatusMap(snapshot, options)
    snapshot = type(snapshot) == "table" and snapshot or {}
    options = type(options) == "table" and options or {}
    local requested = {
        buff = options.buff ~= false,
        debuff = options.debuff == true,
        hidden = options.hidden == true,
    }
    local map = {}
    local meta = { available = true, complete = true, reliable = true, rows = 0, lanes = 0 }

    for _, lane in ipairs({ "buff", "debuff", "hidden" }) do
        if requested[lane] == true then
            meta.lanes = meta.lanes + 1
            local laneRow = snapshot[lane]
            if type(laneRow) ~= "table" or laneRow.available ~= true then
                meta.available, meta.complete, meta.reliable = false, false, false
            else
                if laneRow.complete ~= true then meta.complete = false end
                if laneRow.reliable ~= true then meta.reliable = false end
                local laneSpec = LANES[lane]
                for _, item in ipairs(type(laneRow.rows) == "table" and laneRow.rows or {}) do
                    meta.rows = meta.rows + 1
                    local id = tonumber(item.effectId) or ExtractEffectId(item.data, item.tooltip)
                    if id ~= nil then
                        local data, tooltip = item.data, item.tooltip
                        local stack = PickNumber(tooltip, data, STATUS_KEYS.stack) or 1
                        local timeLeft = PickNumber(tooltip, data, STATUS_KEYS.timeLeft)
                        local name = PickString(tooltip, data, STATUS_KEYS.name) or ""
                        local iconPath = PickString(tooltip, data, STATUS_KEYS.icon) or ""
                        -- 当前 RU 单位行常无 name，偶尔无 icon。名称只是原始 ID 占位或 icon 缺失时触发缓存
                        -- ability-tooltip；先检查零额外读取成本的原生尾部返回。
                        if name == "" or name == tostring(id) then
                            local extraName = NameFromExtra(item.extra) or NameFromExtra(item.tooltipExtra)
                            if extraName ~= nil then name = extraName end
                        end
                        if name == "" or name == tostring(id) or iconPath == "" then
                            local resolved = BuffMeta() ~= nil and BuffMeta():GetInfo(id) or nil
                            if resolved ~= nil then
                                if name == "" or name == tostring(id) then name = resolved.name end
                                if iconPath == "" then iconPath = resolved.iconPath end
                            end
                        end
                        if name == "" then name = tostring(id) end
                        -- 把从单位行或 tooltip 得到的有效解析通过 Remember 交回共享元数据服务，使已知名称
                        -- ID 的 PeekBuffInfo 门禁停止重新读取 tooltip。
                        if name ~= tostring(id) then
                            local meta = BuffMeta()
                            if meta ~= nil and meta.Remember ~= nil then
                                meta:Remember(id, name, iconPath)
                            end
                        end
                        local entry = map[id]
                        if entry == nil then
                            entry = {
                                id = id, stack = stack, timeLeft = timeLeft, timeKnown = timeLeft ~= nil,
                                sourceMask = 0, sources = {}, name = name, iconPath = iconPath,
                            }
                            map[id] = entry
                        else
                            entry.stack = math.max(tonumber(entry.stack) or 1, stack)
                            if (entry.name == nil or entry.name == "" or entry.name == tostring(entry.id)) and name ~= "" then entry.name = name end
                            if (entry.iconPath == nil or entry.iconPath == "") and iconPath ~= "" then entry.iconPath = iconPath end
                            if timeLeft ~= nil and (entry.timeKnown ~= true or timeLeft > (tonumber(entry.timeLeft) or 0)) then
                                entry.timeLeft, entry.timeKnown = timeLeft, true
                            end
                        end
                        entry.sourceMask = AddSourceMask(entry.sourceMask, laneSpec and laneSpec.sourceMask or 1)
                        entry.sources[lane] = true
                    end
                end
            end
        end
    end
    if meta.lanes == 0 then meta.available, meta.complete, meta.reliable = false, false, false end
    return map, meta
end

-- 存在性判断保守：所需 ID 未观察到且请求 lane 不完整或不可靠时，返回未知 ok=nil，不能伪造失败。供团队就绪及
-- Healer/Plates 消费。
function A:EvaluateRequiredEffects(snapshot, requiredIds, options)
    requiredIds = type(requiredIds) == "table" and requiredIds or {}
    local statusMap, meta = self:GetStatusMap(snapshot, options)
    local present, missing, seen = {}, {}, {}
    for _, rawId in ipairs(requiredIds) do
        local id = tonumber(rawId)
        if id ~= nil and id > 0 and seen[id] ~= true then
            seen[id] = true
            if statusMap[id] ~= nil then present[#present + 1] = id else missing[#missing + 1] = id end
        end
    end
    local configured = next(seen) ~= nil
    local ok = true
    if #missing > 0 then
        if meta.available == true and meta.complete == true and meta.reliable == true then ok = false else ok = nil end
    end
    return { configured = configured, ok = ok, present = present, missing = missing, meta = meta, statusMap = statusMap }
end

function A:GetHealth()
    return {
        ok = self.Demand ~= nil,
        consumers = self.Demand and self.Demand.count or 0,
        cache = self.cacheCount,
        revision = self.revision,
        nativeReads = self.nativeReads,
        tooltipFallbacks = self.tooltipFallbacks,
        scanFailures = self.scanFailures,
    }
end

if S.Demand ~= nil and type(S.Demand.Create) == "function" then
    local lease, err = S.Demand:Create({
        id = A.Id,
        owner = A,
        projectionOwner = A,
        projectionConsumersField = "consumers",
        projectionCountField = "consumerCount",
        normalize = function(options)
            options = type(options) == "table" and options or {}
            return { purpose = tostring(options.purpose or "generic") }
        end,
        reconcile = function(_, before, after)
            if (tonumber(after.count) or 0) == 0 and (tonumber(before.count) or 0) > 0 then A:ClearCache() end
            return true
        end,
        quiesce = function() A:ClearCache(); return true end,
    })
    if lease == nil then error(err) end
    A.Demand = lease
else
    error("Demand foundation unavailable for AuraObservationV3")
end
