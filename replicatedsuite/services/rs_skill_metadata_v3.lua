------------------------------------------------------------------------
-- Replicated Suite V3 - Skill Metadata Service
--
-- Shared, lazy skill metadata resolver for Presentation drill-downs.
-- Runtime combat callbacks must never call this service: native X2Skill lookups
-- are intentionally deferred until a user opens/refreshes a skill detail view.
-- The cache is bounded and caches negative results as well as successes.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
S.Services = S.Services or {}

local M = {
    Id = "v3.skill_metadata",
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
S.Services.SkillMetadataV3 = M

local UNKNOWN_ICON = "ui/icon/icon_unknown_item.dds"
local function NormalizeId(value)
    local id = tonumber(value)
    if id == nil or id <= 0 then return nil end
    return math.floor(id + 0.5)
end
local function NormalizePath(value)
    return type(value) == "string" and value ~= "" and value or nil
end
local function FirstIconPath(info)
    if type(info) ~= "table" then return nil end
    return NormalizePath(info.path)
        or NormalizePath(info.iconPath)
        or NormalizePath(info.icon_path)
        or NormalizePath(info.icon)
        or NormalizePath(info.skillIcon)
        or NormalizePath(info.skill_icon)
        or NormalizePath(info.texture)
end
local function FirstName(info)
    if type(info) ~= "table" then return nil end
    local value = info.name or info.skillName or info.skill_name
    value = tostring(value or "")
    return value ~= "" and value or nil
end
local function SafeInvoke(object, methodName, ...)
    if object == nil then return false, nil, "object unavailable" end
    local method = object[methodName]
    if type(method) ~= "function" then return false, nil, tostring(methodName) .. " unavailable" end
    local args = { ... }
    local count = select("#", ...)
    local ok, a, b = pcall(function() return method(object, unpack(args, 1, count)) end)
    if ok ~= true then return false, nil, tostring(a) end
    return true, a, b
end
local function StaticSkill(id)
    local catalog = S.Data and S.Data.CombatAbilityCatalog or nil
    if type(catalog) == "table" and type(catalog.GetSkill) == "function" then return catalog:GetSkill(id) end
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
            local entry = self.order[index]
            if entry ~= nil then compact[#compact + 1] = entry end
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
function M:GetSkillInfo(skillId, fallbackName)
    local id = NormalizeId(skillId)
    if id == nil then
        return { skillId = nil, name = tostring(fallbackName or "普通攻击/未知技能"), iconPath = UNKNOWN_ICON, resolved = false, source = "no_skill_id" }
    end
    local key = tostring(id)
    local cached = self.cache[key]
    if type(cached) == "table" then
        self.hits = self.hits + 1
        return {
            skillId = cached.skillId, name = cached.name, iconPath = cached.iconPath,
            resolved = cached.resolved, source = cached.source,
        }
    end
    self.misses = self.misses + 1

    local static = StaticSkill(id)
    local name = type(static) == "table" and tostring(static.name or "") or ""
    if name == "" then name = tostring(fallbackName or "") end
    local iconPath = nil
    local source = type(static) == "table" and "catalog" or "fallback"
    local nativeResolved = false

    if X2Skill ~= nil then
        if type(X2Skill.Info) == "function" then
            self.nativeLookups = self.nativeLookups + 1
            local ok, info = SafeInvoke(X2Skill, "Info", id)
            if ok and type(info) == "table" then
                name = FirstName(info) or name
                iconPath = FirstIconPath(info) or iconPath
                nativeResolved = name ~= "" or iconPath ~= nil
                if nativeResolved then source = "x2skill_info" end
            elseif ok ~= true then
                self.nativeFailures = self.nativeFailures + 1
            end
        end
        if (name == "" or iconPath == nil) and type(X2Skill.GetSkillTooltip) == "function" then
            self.nativeLookups = self.nativeLookups + 1
            local ok, tip = SafeInvoke(X2Skill, "GetSkillTooltip", id)
            if ok and type(tip) == "table" then
                name = FirstName(tip) or name
                iconPath = FirstIconPath(tip) or iconPath
                if name ~= "" or iconPath ~= nil then
                    nativeResolved = true
                    source = source == "x2skill_info" and "x2skill_info+tooltip" or "x2skill_tooltip"
                end
            elseif ok ~= true then
                self.nativeFailures = self.nativeFailures + 1
            end
        end
    end

    if name == "" then name = "技能 " .. key end
    local row = self:_Store(id, {
        skillId = id,
        name = name,
        iconPath = iconPath or UNKNOWN_ICON,
        resolved = nativeResolved or type(static) == "table",
        source = source,
    })
    return { skillId = row.skillId, name = row.name, iconPath = row.iconPath, resolved = row.resolved, source = row.source }
end
function M:GetHealth()
    return {
        version = self.version,
        cacheCount = self.cacheCount,
        cacheMax = self.cacheMax,
        hits = self.hits,
        misses = self.misses,
        nativeLookups = self.nativeLookups,
        nativeFailures = self.nativeFailures,
        evictions = self.evictions,
        x2Info = X2Skill ~= nil and type(X2Skill.Info) == "function",
        x2Tooltip = X2Skill ~= nil and type(X2Skill.GetSkillTooltip) == "function",
    }
end
