------------------------------------------------------------------------
-- Replicated Suite V3 - Healer Aura Bridge (Phase 12B)
--
-- Feature-domain adapter between the legacy Healer status-cache contract and
-- AuraObservationV3. It owns only the Healer Aura consumer lease and normalized
-- status reads. Healing score/rules/distance/priority remain Healer Domain
-- authority. No Tick and no background scan are introduced here.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
S.Features = S.Features or {}

local B = {
    Id = "combat_healer_aura_bridge",
    version = 2,
    consumerToken = "feature:combat_healer:aura",
    held = false,
    metrics = {
        acquires = 0,
        releases = 0,
        reads = 0,
        accepted = 0,
        degraded = 0,
        failures = 0,
        accurateReads = 0,
        nativeFallbacks = 0,
        nativeFallbackFailures = 0,
        nativeFallbackReads = 0,
        nativeFallbackUnresolved = 0,
    },
}
B.presentationBoundary = "feature_domain_support"
S.Features.HealerAuraBridge = B

local function Aura()
    return S.Services and S.Services.AuraObservationV3 or nil
end

local function NormalizeLimit(value)
    value = math.floor(tonumber(value) or 256)
    if value < 1 then return 1 end
    if value > 256 then return 256 end
    return value
end

local function NormalizeTtl(value)
    value = math.floor(tonumber(value) or 80)
    if value < 0 then return 0 end
    if value > 2000 then return 2000 end
    return value
end

function B:Start(reason)
    if self.held == true then return true end
    local aura = Aura()
    if type(aura) ~= "table" or type(aura.AcquireConsumer) ~= "function" then
        self.metrics.failures = (tonumber(self.metrics.failures) or 0) + 1
        return false, "AuraObservationV3 unavailable"
    end
    local ok, err = aura:AcquireConsumer(self.consumerToken, {
        purpose = "healer_status",
        reason = tostring(reason or "healer_enable"),
    })
    if ok ~= true then
        self.metrics.failures = (tonumber(self.metrics.failures) or 0) + 1
        return false, err or "healer aura acquire failed"
    end
    self.held = true
    self.metrics.acquires = (tonumber(self.metrics.acquires) or 0) + 1
    return true
end

function B:Stop(reason)
    if self.held ~= true then return true end
    local aura = Aura()
    if type(aura) ~= "table" or type(aura.ReleaseConsumer) ~= "function" then
        self.metrics.failures = (tonumber(self.metrics.failures) or 0) + 1
        return false, "AuraObservationV3 unavailable"
    end
    local ok, err = aura:ReleaseConsumer(self.consumerToken)
    if ok ~= true then
        self.metrics.failures = (tonumber(self.metrics.failures) or 0) + 1
        return false, err or "healer aura release failed"
    end
    self.held = false
    self.metrics.releases = (tonumber(self.metrics.releases) or 0) + 1
    return true
end

function B:Read(unitToken, options)
    self.metrics.reads = (tonumber(self.metrics.reads) or 0) + 1
    if self.held ~= true then
        self.metrics.failures = (tonumber(self.metrics.failures) or 0) + 1
        return nil, nil, "healer aura lease not held"
    end

    unitToken = tostring(unitToken or "")
    if unitToken == "" then
        self.metrics.failures = (tonumber(self.metrics.failures) or 0) + 1
        return nil, nil, "unit token required"
    end

    local aura = Aura()
    if type(aura) ~= "table" or type(aura.GetSnapshot) ~= "function" or type(aura.GetStatusMap) ~= "function" then
        self.metrics.failures = (tonumber(self.metrics.failures) or 0) + 1
        return nil, nil, "AuraObservationV3 status projection unavailable"
    end

    options = type(options) == "table" and options or {}
    local limit = NormalizeLimit(options.limit)
    local ttlMs = NormalizeTtl(options.ttlMs)
    local snapshot, snapshotErr = aura:GetSnapshot(unitToken, {
        buff = true,
        debuff = true,
        hidden = true,
        buffLimit = NormalizeLimit(options.buffLimit or limit),
        debuffLimit = NormalizeLimit(options.debuffLimit or limit),
        hiddenLimit = NormalizeLimit(options.hiddenLimit or limit),
        ttlMs = ttlMs,
    })
    if type(snapshot) ~= "table" then
        self.metrics.failures = (tonumber(self.metrics.failures) or 0) + 1
        return nil, nil, snapshotErr or "aura snapshot unavailable"
    end

    local statusMap, meta = aura:GetStatusMap(snapshot, { buff = true, debuff = true, hidden = true })
    meta = type(meta) == "table" and meta or { available = false, complete = false, reliable = false }
    local coverage = {
        available = meta.available == true,
        complete = meta.complete == true,
        reliable = meta.reliable == true,
        rows = tonumber(meta.rows) or 0,
        scannedAt = tonumber(snapshot.at) or 0,
        revision = tonumber(snapshot.revision) or 0,
        buffCount = type(snapshot.buff) == "table" and tonumber(snapshot.buff.count) or 0,
        debuffCount = type(snapshot.debuff) == "table" and tonumber(snapshot.debuff.count) or 0,
        hiddenCount = type(snapshot.hidden) == "table" and tonumber(snapshot.hidden.count) or 0,
    }

    if coverage.available == true and coverage.complete == true and coverage.reliable == true then
        self.metrics.accepted = (tonumber(self.metrics.accepted) or 0) + 1
    else
        self.metrics.degraded = (tonumber(self.metrics.degraded) or 0) + 1
    end
    return type(statusMap) == "table" and statusMap or {}, coverage, nil
end



local DIRECT_LANES = {
    { name = "buff", count = "UnitBuffCount", data = "UnitBuff", tooltip = "UnitBuffTooltip", mask = 1 },
    { name = "debuff", count = "UnitDeBuffCount", data = "UnitDeBuff", tooltip = "UnitDeBuffTooltip", mask = 2 },
    { name = "hidden", count = "UnitHiddenBuffCount", data = "UnitHiddenBuff", tooltip = "UnitHiddenBuffTooltip", mask = 4 },
}

local function PickNumber(first, second, keys)
    local function Pick(source)
        if type(source) == "table" then
            for _, key in ipairs(keys) do
                local value = tonumber(source[key])
                if value ~= nil then return value end
            end
        end
        return nil
    end
    return Pick(first) or Pick(second)
end

local function PickString(first, second, keys)
    local function Pick(source)
        if type(source) == "table" then
            for _, key in ipairs(keys) do
                local value = source[key]
                if type(value) == "string" and value ~= "" then return value end
            end
        end
        return nil
    end
    return Pick(first) or Pick(second)
end

local function AddMask(mask, bit)
    mask = math.max(0, math.floor(tonumber(mask) or 0))
    if math.floor(mask / bit) % 2 == 0 then mask = mask + bit end
    return mask
end

local function CapRead(capability, method, ...)
    if S.Api == nil or type(S.Api.CallCapability) ~= "function" then return nil, "api unavailable" end
    local ok, value, err = S.Api:CallCapability("X2Unit:" .. capability, X2Unit, method, ...)
    if ok ~= true then return nil, err or (method .. " failed") end
    return value, nil
end

local function ExtractId(data, tooltip)
    return PickNumber(tooltip, data, { "buff_id", "buffId", "buffID", "effectId", "effect_id", "id", "buffType", "buff_type", "type" })
end

function B:_ReadDirect(unitToken)
    local statuses = {}
    local counts = { buff = 0, debuff = 0, hidden = 0 }
    local nativeReads = 0
    for _, lane in ipairs(DIRECT_LANES) do
        local count, countErr = CapRead(lane.count, lane.count, unitToken)
        if countErr ~= nil then return nil, nil, countErr end
        if tonumber(count) == nil then return nil, nil, lane.name .. " status count unavailable" end
        count = math.max(0, math.floor(tonumber(count) or 0))
        counts[lane.name] = count
        nativeReads = nativeReads + 1
        for index = 1, count do
            local data, dataErr = CapRead(lane.data, lane.data, unitToken, index)
            nativeReads = nativeReads + 1
            local tooltip, tooltipErr = CapRead(lane.tooltip, lane.tooltip, unitToken, index)
            nativeReads = nativeReads + 1
            if dataErr ~= nil and tooltipErr ~= nil then
                return nil, nil, tostring(dataErr or tooltipErr or (lane.name .. " status row unavailable"))
            end
            local id = ExtractId(data, tooltip)
            if id == nil then
                self.metrics.nativeFallbackUnresolved = (tonumber(self.metrics.nativeFallbackUnresolved) or 0) + 1
                return nil, nil, lane.name .. " status id unresolved at index " .. tostring(index)
            end
            if id ~= nil then
                local stack = PickNumber(tooltip, data, { "stack", "stackCount", "count" }) or 1
                local timeLeft = PickNumber(tooltip, data, { "timeLeft", "time_left", "remainTime", "remainingTime", "remain_time" })
                local name = PickString(tooltip, data, { "name", "buffName", "buff_name" }) or tostring(id)
                local iconPath = PickString(tooltip, data, { "path", "iconPath", "icon_path", "icon", "skillIcon", "skill_icon", "texture" }) or ""
                local entry = statuses[id]
                if entry == nil then
                    entry = { id = id, stack = stack, timeLeft = timeLeft, timeKnown = timeLeft ~= nil, sourceMask = 0, sources = {}, name = name, iconPath = iconPath }
                    statuses[id] = entry
                else
                    entry.stack = math.max(tonumber(entry.stack) or 1, stack)
                    if timeLeft ~= nil and (entry.timeKnown ~= true or timeLeft > (tonumber(entry.timeLeft) or 0)) then entry.timeLeft, entry.timeKnown = timeLeft, true end
                    if (entry.name == nil or entry.name == "" or entry.name == tostring(entry.id)) and name ~= "" then entry.name = name end
                    if (entry.iconPath == nil or entry.iconPath == "") and iconPath ~= "" then entry.iconPath = iconPath end
                end
                entry.sourceMask = AddMask(entry.sourceMask, lane.mask)
                entry.sources[lane.name] = true
            end
        end
    end
    self.metrics.nativeFallbackReads = (tonumber(self.metrics.nativeFallbackReads) or 0) + nativeReads
    local rows = 0
    for _ in pairs(statuses) do rows = rows + 1 end
    return statuses, {
        available = true, complete = true, reliable = true, source = "native_fallback",
        rows = rows, scannedAt = math.max(0, tonumber(S.NowMs and S.NowMs()) or 0),
        buffCount = counts.buff, debuffCount = counts.debuff, hiddenCount = counts.hidden,
        nativeReads = nativeReads,
    }, nil
end

-- Accuracy-first Healer read. Shared Aura facts are always attempted first. A
-- degraded shared snapshot is NOT treated as proof of absence; only that case
-- falls back to a full native read. This keeps the duplicate scanner cold on
-- normal paths while preserving the historical recommendation semantics.
function B:ReadAccurate(unitToken, options)
    self.metrics.accurateReads = (tonumber(self.metrics.accurateReads) or 0) + 1
    local statuses, coverage, err = self:Read(unitToken, options)
    if type(statuses) == "table" and type(coverage) == "table"
        and coverage.available == true and coverage.complete == true and coverage.reliable == true then
        coverage.source = "aura_v3"
        return statuses, coverage, nil
    end
    local direct, directCoverage, directErr = self:_ReadDirect(tostring(unitToken or ""))
    if type(direct) ~= "table" then
        self.metrics.nativeFallbackFailures = (tonumber(self.metrics.nativeFallbackFailures) or 0) + 1
        return nil, coverage, directErr or err or "healer status read failed"
    end
    self.metrics.nativeFallbacks = (tonumber(self.metrics.nativeFallbacks) or 0) + 1
    return direct, directCoverage, nil
end

function B:GetHealth()
    local aura = Aura()
    local auraHealth = type(aura) == "table" and type(aura.GetHealth) == "function" and aura:GetHealth() or nil
    return {
        version = self.version,
        held = self.held == true,
        acquires = tonumber(self.metrics.acquires) or 0,
        releases = tonumber(self.metrics.releases) or 0,
        reads = tonumber(self.metrics.reads) or 0,
        accepted = tonumber(self.metrics.accepted) or 0,
        degraded = tonumber(self.metrics.degraded) or 0,
        failures = tonumber(self.metrics.failures) or 0,
        accurateReads = tonumber(self.metrics.accurateReads) or 0,
        nativeFallbacks = tonumber(self.metrics.nativeFallbacks) or 0,
        nativeFallbackFailures = tonumber(self.metrics.nativeFallbackFailures) or 0,
        nativeFallbackReads = tonumber(self.metrics.nativeFallbackReads) or 0,
        nativeFallbackUnresolved = tonumber(self.metrics.nativeFallbackUnresolved) or 0,
        auraConsumers = type(auraHealth) == "table" and tonumber(auraHealth.consumers) or 0,
    }
end
