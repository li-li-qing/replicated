------------------------------------------------------------------------
-- Replicated Suite V3 - Raid Readiness Store
--
-- Account-scoped permanent preferences only. Scan results are session facts and
-- are never persisted. Required Aura IDs are user supplied / imported facts;
-- this store intentionally ships with no guessed Buff IDs.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local P = S.Persistence
if type(P) ~= "table" or type(P.RegisterV3Store) ~= "function" then return end

S.Features = S.Features or {}
S.Features.RaidReadiness = S.Features.RaidReadiness or {}
local F = S.Features.RaidReadiness
local U = S.Utils

local STORE_ID = "v3.raid_readiness"
local SCHEMA = 1
local MAX_REQUIRED_AURAS = 24

local function DeepCopy(value)
    if U ~= nil and type(U.DeepCopy) == "function" then return U.DeepCopy(value) end
    return value
end

local function ClampInt(value, minimum, maximum, fallback)
    local n = math.floor(tonumber(value) or tonumber(fallback) or minimum)
    if n < minimum then n = minimum end
    if n > maximum then n = maximum end
    return n
end

local function NormalizeAuraIds(value)
    local out, seen = {}, {}
    if type(value) == "string" then
        local parsed = {}
        for token in string.gmatch(value, "%d+") do parsed[#parsed + 1] = tonumber(token) end
        value = parsed
    end
    for _, raw in ipairs(type(value) == "table" and value or {}) do
        local id = math.floor(tonumber(raw) or 0)
        if id > 0 and seen[id] ~= true and #out < MAX_REQUIRED_AURAS then
            seen[id] = true
            out[#out + 1] = id
        end
    end
    table.sort(out)
    return out
end

local function NormalizeSettings(value)
    value = type(value) == "table" and value or {}
    return {
        minGearScore = ClampInt(value.minGearScore, 0, 50000, 0),
        requiredAuraIds = NormalizeAuraIds(value.requiredAuraIds),
        includeHidden = value.includeHidden ~= false,
        showOnlyIssues = value.showOnlyIssues == true,
    }
end

local function NormalizeState(value)
    value = type(value) == "table" and value or {}
    return { settings = NormalizeSettings(value.settings) }
end

F.StoreId = STORE_ID
F.MaxRequiredAuras = MAX_REQUIRED_AURAS
F.State = NormalizeState(F.State)
F.StoreLoaded = F.StoreLoaded == true

local function ApplyState(value) F.State = NormalizeState(value) end

if P:GetStore(STORE_ID) == nil then
    local store, err = P:RegisterV3Store({
        id = STORE_ID,
        owner = "v3.raid_readiness",
        scope = P.Scope and P.Scope.Account or "account",
        lifetime = P.Lifetime and P.Lifetime.Permanent or "permanent",
        schemaVersion = SCHEMA,
        legacySchemaVersion = 0,
        key = P.V3KeyPrefix and (P.V3KeyPrefix .. "raid_readiness") or "v3.raid_readiness",
        budget = { maxDepth = 4, maxNodes = 180, maxStringBytes = 1200, maxEntriesPerTable = 32 },
        default = function() return NormalizeState(nil) end,
        get = function() return NormalizeState(F.State) end,
        apply = ApplyState,
        migrate = function(value) return NormalizeState(value) end,
    })
    if store == nil and S.DiagnosticsManager ~= nil and type(S.DiagnosticsManager.Error) == "function" then
        S.DiagnosticsManager:Error("raid_readiness_v3", "RAID_READINESS_STORE_REGISTER_FAILED", "团队战备检查设置存档注册失败", { error = tostring(err) })
    end
end

function F:GetSettings() return self.State.settings end
function F:GetRequiredAuraText()
    local parts = {}
    for _, id in ipairs(self.State.settings.requiredAuraIds or {}) do parts[#parts + 1] = tostring(id) end
    return table.concat(parts, ",")
end

function F:ApplySettingRaw(key, value)
    local settings = self.State.settings
    key = tostring(key or "")
    if key == "minGearScore" then settings.minGearScore = ClampInt(value, 0, 50000, 0)
    elseif key == "requiredAuraIds" then settings.requiredAuraIds = NormalizeAuraIds(value)
    elseif key == "includeHidden" then settings.includeHidden = value == true
    elseif key == "showOnlyIssues" then settings.showOnlyIssues = value == true
    else return false, "unknown raid readiness setting: " .. key end
    return true
end

function F:EnsureStoreLoaded()
    if self.StoreLoaded == true then return true end
    local store = P:GetStore(STORE_ID)
    if store == nil then return false, "团队战备检查设置存档不可用" end
    local status, _, err = P:LoadStore(STORE_ID)
    if status ~= true and status ~= "empty" then return false, err or tostring(status or "读取失败") end
    if status == "empty" then ApplyState(nil) end
    self.StoreLoaded = true
    return true
end

function F:MarkStoreDirty(delayMs, reason)
    return P:MarkDirty(STORE_ID, tonumber(delayMs) or 300, reason or "raid_readiness_changed")
end

local function PublishSettingChanged(key)
    if S.Events ~= nil and type(S.Events.Publish) == "function" then
        S.Events:Publish("v3.raid_readiness.settings", tostring(key or ""))
    end
end

-- Persistent RSUI bindings own the write-fence + MarkDirty transaction. This
-- path only mutates the in-memory setting and publishes the projection change.
function F:ApplySettingFromBinding(key, value)
    local ok, err = self:ApplySettingRaw(key, value)
    if ok ~= true then return false, err end
    PublishSettingChanged(key)
    return true
end

-- Non-RSUI callers have no persistent binding around them, so queue the Store
-- write here and restore the previous settings atomically if the write is fenced.
function F:SetSettingValue(key, value)
    local before = DeepCopy(self.State.settings)
    local ok, err = self:ApplySettingRaw(key, value)
    if ok ~= true then return false, err end
    local marked, markErr = self:MarkStoreDirty(300, "raid_readiness_setting:" .. tostring(key))
    if marked ~= true then self.State.settings = before; return false, markErr end
    PublishSettingChanged(key)
    return true
end
