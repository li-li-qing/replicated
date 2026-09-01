------------------------------------------------------------------------
-- Replicated Suite V3 - Buff Metadata Service
--
-- Shared, lazy buff-id -> (name/icon) resolver. Runtime combat callbacks must
-- not spam it: lookups are cached (success AND miss) and gated by the
-- capability registry, so one unknown id costs at most a few native reads per
-- session. This is the single Authority for effect metadata; consumers
-- (AuraObservationV3, future plates/healer rebuilds) must not keep private
-- copies of the same chain.
--
-- Native source: X2Ability:GetBuffTooltip(buffType, itemLevel) — the RU-enabled
-- probe chain proven by the mature Plates module. Some RU builds return tooltip
-- TEXT (a string) instead of a table; the first line of a buff tooltip is the
-- buff name, so that shape is accepted too.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
S.Services = S.Services or {}

local M = {
    Id = "v3.buff_metadata",
    version = 1,
    cache = {},
    order = {},
    orderHead = 1,
    serial = 0,
    cacheCount = 0,
    cacheMax = 512,
    hits = 0,
    misses = 0,
    nativeLookups = 0,
    nativeFailures = 0,
    evictions = 0,
}
M.presentationBoundary = "service_only"
S.Services.BuffMetadataV3 = M

local function NormalizeId(value)
    local id = tonumber(value)
    if id == nil or id <= 0 then return nil end
    return math.floor(id + 0.5)
end
local function FirstIconPath(info)
    if type(info) ~= "table" then return nil end
    local path = info.path or info.iconPath or info.icon_path or info.icon
        or info.skillIcon or info.skill_icon or info.texture
    return type(path) == "string" and path ~= "" and path or nil
end
local function NameFromInfo(info)
    if type(info) ~= "table" then return nil end
    for _, key in ipairs({ "name", "buffName" }) do
        local value = info[key]
        if type(value) == "string" and value ~= "" then return value end
    end
    return nil
end

function M:_EvictIfNeeded()
    while self.cacheCount >= self.cacheMax do
        local entry = self.order[self.orderHead]
        self.order[self.orderHead] = nil
        self.orderHead = self.orderHead + 1
        if type(entry) == "table" then
            local cached = self.cache[entry.key]
            if type(cached) == "table" and cached.__cacheSerial == entry.serial then
                self.cache[entry.key] = nil
                self.cacheCount = math.max(0, self.cacheCount - 1)
                self.evictions = self.evictions + 1
                break
            end
        elseif self.orderHead > #self.order + 1 then
            break
        end
    end
    if self.orderHead > 256 and self.orderHead > (#self.order / 2) then
        local compact = {}
        for index = self.orderHead, #self.order do
            if self.order[index] ~= nil then compact[#compact + 1] = self.order[index] end
        end
        self.order, self.orderHead = compact, 1
    end
end

function M:_Store(id, row)
    local key = tostring(id)
    self:_EvictIfNeeded()
    self.serial = self.serial + 1
    row.__cacheSerial = self.serial
    self.cache[key] = row
    self.cacheCount = self.cacheCount + 1
    self.order[#self.order + 1] = { key = key, serial = self.serial }
    return row
end

-- Peek: cached result only. Never issues native reads, never caches a miss.
-- Scan paths use this to decide whether a (more expensive) tooltip row fetch is
-- still worthwhile for an id.
function M:GetCached(id)
    local cached = self.cache[tostring(id)]
    if cached == nil then return nil end
    if cached == false then return nil end
    self.hits = self.hits + 1
    return { name = cached.name, iconPath = cached.iconPath }
end

-- Remember a POSITIVE resolution learned outside this service (e.g. a name
-- read straight off a UnitBuffTooltip row). Upgrades an earlier miss (false)
-- but never overwrites a different positive entry.
function M:Remember(id, name, iconPath)
    local numeric = NormalizeId(id)
    if numeric == nil then return false end
    local key = tostring(numeric)
    local existing = self.cache[key]
    if type(existing) == "table" then return false end
    local cleanName = type(name) == "string" and name or ""
    if cleanName == "" or cleanName == key then return false end
    local row = { name = cleanName, iconPath = type(iconPath) == "string" and iconPath or "" }
    if existing == false then
        self.serial = self.serial + 1
        row.__cacheSerial = self.serial
        self.cache[key] = row
        return true
    end
    self:_Store(key, row)
    return true
end

function M:GetInfo(id)
    local numeric = NormalizeId(id)
    if numeric == nil then return nil end
    local key = tostring(numeric)
    local cached = self.cache[key]
    if cached ~= nil then
        self.hits = self.hits + 1
        if cached == false then return nil end
        return { name = cached.name, iconPath = cached.iconPath }
    end
    self.misses = self.misses + 1

    local api = S.Api
    local gateOpen = type(api) == "table" and type(api.CallCapability) == "function"
        and X2Ability ~= nil
        and (type(api.IsCapabilityAllowed) ~= "function"
            or api:IsCapabilityAllowed("X2Ability:GetBuffTooltip") == true)
    if gateOpen ~= true then
        self.cache[key], self.cacheCount = false, self.cacheCount + 1
        self.nativeFailures = self.nativeFailures + 1
        return nil
    end

    -- Item level is irrelevant for ordinary combat auras on current RU; probe
    -- the cheap/common values and stop on the first structurally useful return.
    for _, itemLevel in ipairs({ 0, 1, 55 }) do
        self.nativeLookups = self.nativeLookups + 1
        local ok, info = api:CallCapability("X2Ability:GetBuffTooltip", X2Ability, "GetBuffTooltip", numeric, itemLevel)
        if ok == true and type(info) == "string" and info ~= "" then
            local firstLine = string.match(info, "^([^\r\n]+)") or ""
            firstLine = string.match(firstLine, "^%s*(.-)%s*$") or ""
            if firstLine ~= "" and string.match(firstLine, "^%d+$") == nil then
                local resolved = { name = firstLine, iconPath = "" }
                self:_Store(key, resolved)
                return { name = resolved.name, iconPath = "" }
            end
        end
        if ok == true and type(info) == "table" then
            local iconPath = FirstIconPath(info)
            local name = NameFromInfo(info)
            if iconPath ~= nil or name ~= "" then
                local resolved = { name = name or "", iconPath = iconPath or "" }
                self:_Store(key, resolved)
                return { name = resolved.name, iconPath = resolved.iconPath }
            end
        end
    end
    self.cache[key], self.cacheCount = false, self.cacheCount + 1
    return nil
end

function M:GetHealth()
    return {
        ok = true,
        cached = self.cacheCount,
        cacheMax = self.cacheMax,
        hits = self.hits,
        misses = self.misses,
        nativeLookups = self.nativeLookups,
        nativeFailures = self.nativeFailures,
        evictions = self.evictions,
    }
end

return
