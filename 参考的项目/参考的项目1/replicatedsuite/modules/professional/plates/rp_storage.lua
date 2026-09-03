ReplicatedSuiteModuleSandbox:Enter('plates', {'ReplicatedPlates'})
------------------------------------------------------------------------
-- Replicated Plates - Settings Authority / persistence
-- Schema v19: AuraLibrary becomes the single Buff/Debuff Authority with chunk-safe transfer.
------------------------------------------------------------------------
if ReplicatedPlates == nil or ReplicatedPlates.BootError ~= nil or ReplicatedPlates.Api == nil then return end
local P = ReplicatedPlates
local A = P.Api

P.Storage = {
    settings = nil, dirty = false, trackingDirty = false, trackingSharded = false,
    auraDirty = false, auraSharded = false,
    writeFenceReason = nil, writeFenceWarned = false, futureSchemaVersion = nil,
    trackingFutureVersion = nil, auraFutureVersion = nil,
}
local S = P.Storage

local function Clamp(value, minimum, maximum, fallback)
    value = tonumber(value)
    if value == nil then value = fallback end
    if value < minimum then value = minimum end
    if value > maximum then value = maximum end
    return value
end

local function CopyColor(value, fallback)
    local source = type(value) == "table" and value or type(fallback) == "table" and fallback or {}
    local function channel(key, index, default)
        local raw = source[key]
        if raw == nil then raw = source[index] end
        raw = tonumber(raw)
        if raw == nil then raw = default end
        return math.max(0, math.min(1, raw))
    end
    return {
        r = channel("r", 1, 1),
        g = channel("g", 2, 1),
        b = channel("b", 3, 1),
        a = channel("a", 4, 1),
    }
end

local function OptionalBoolean(value)
    if value == nil then return nil end
    return value == true
end

local function CopyEntry(value)
    if type(value) ~= "table" then return { name = "", iconPath = "", enabled = true, priority = 0 } end
    local result = {
        name = tostring(value.name or ""),
        customName = tostring(value.customName or ""),
        iconPath = tostring(value.iconPath or value.icon or value.path or ""),
        category = tostring(value.category or ""),
        enabled = value.enabled ~= false,
        priority = math.floor(Clamp(value.priority, -100, 100, 0) + 0.5),
        showDuration = OptionalBoolean(value.showDuration),
        showStack = OptionalBoolean(value.showStack),
        showBorder = OptionalBoolean(value.showBorder),
        showTooltip = OptionalBoolean(value.showTooltip),
        iconSize = value.iconSize ~= nil and Clamp(value.iconSize, 18, 42, 24) or nil,
        expireEnabled = OptionalBoolean(value.expireEnabled),
        expireThreshold = value.expireThreshold ~= nil and Clamp(value.expireThreshold, 1, 60, 5) or nil,
    }
    if type(value.borderColor) == "table" then result.borderColor = CopyColor(value.borderColor) end
    if type(value.expireColor) == "table" then result.expireColor = CopyColor(value.expireColor) end
    return result
end

local EFFECT_DEFAULT_COLORS = {
    buff = { r = 0.24, g = 0.82, b = 0.44, a = 0.92 },
    debuff = { r = 0.96, g = 0.30, b = 0.28, a = 0.92 },
    hidden = { r = 0.72, g = 0.38, b = 0.94, a = 0.92 },
}

local function EffectDefaults(effectType)
    return {
        iconSize = effectType == "hidden" and 23 or 24,
        fontSize = 10,
        maxCount = 8,
        columns = 6,
        gap = 2,
        rowGap = 2,
        direction = "RIGHT",
        offsetX = 0,
        offsetY = 0,
        showDuration = true,
        showStack = true,
        showBorder = true,
        showTooltip = false,
        borderColor = CopyColor(EFFECT_DEFAULT_COLORS[effectType] or EFFECT_DEFAULT_COLORS.buff),
        expireEnabled = false,
        expireThreshold = 5,
        expireColor = { r = 1, g = 0.28, b = 0.18, a = 1 },
    }
end

local function PlateDefaults(scope)
    local base = {
        -- The professional module itself is disabled by Suite on fresh installs,
        -- so a second hidden-by-default gate only creates a "module enabled but
        -- nothing visible" failure mode. HUD Manager remains the visibility Authority.
        enabled = true,
        offsetX = -126,
        offsetY = -34,
        width = 286,
        anchorMode = "TOP",
        sectionGap = 4,
        showBuffs = true,
        showDebuffs = true,
        showHidden = false,
        showCast = false,
        showDistance = false,
        -- Tracking is the display whitelist by default. An empty library means
        -- "show no effects", never "fall back to every live aura". Users can still
        -- explicitly switch Buff/Debuff筛选 to 全部 when they really want that mode.
        trackedOnly = true,
        -- Session discovery only feeds the manager/detection UI. It never
        -- bypasses explicit tracking or injects effects into the HUD; Hidden in
        -- particular remains a strict whitelist even while discovery is enabled.
        autoPvPRelevant = true,
        distance = { fontSize = 12, offsetX = 0, offsetY = 0, warningAt = 25, dangerAt = 30 },
        effects = {
            buff = EffectDefaults("buff"),
            debuff = EffectDefaults("debuff"),
            hidden = EffectDefaults("hidden"),
        },
    }
    if scope == "player" then
        base.offsetX, base.offsetY, base.width = -126, -92, 286
        base.anchorMode = "TOP"
        base.showHidden = true
        -- Equipment icons are optional cosmetic HUD content.  Fresh profiles
        -- must not force four equipment slots onto the screen before the user
        -- explicitly asks for them.  Existing saved choices remain authoritative
        -- because ApplyPlateSaved() still restores saved.showEquipment below.
        base.showEquipment = false
        base.showImportantCooldowns = true
        base.cooldowns = {
            iconSize = 24, fontSize = 10, maxCount = 8, columns = 6,
            gap = 2, rowGap = 2, direction = "RIGHT", offsetX = 0, offsetY = 0,
        }
        base.equipment = {
            iconSize = 26, direction = "RIGHT", offsetX = 0, offsetY = 0,
            showGlider = true, showMainhand = true, showOffhand = true, showRanged = true,
        }
    else
        -- Target HUD is anchored by its BOTTOM edge. As Buff/Debuff rows grow,
        -- the frame expands upward instead of covering the native nameplate.
        base.anchorMode = "BOTTOM"
        base.showCast = true
        base.showDistance = true
        base.showHidden = false
        base.showGear = true
        base.showLoadout = true
        base.showClass = true
        base.showTargetOfTarget = false
        base.targetOfTarget = { fontSize = 10, offsetX = 0, offsetY = 0 }
        base.class = { showIcon = true, showName = true, iconSize = 26, fontSize = 12, offsetX = 0, offsetY = 0 }
        base.gear = { fontSize = 12, offsetX = 0, offsetY = 0 }
        base.loadout = { fontSize = 11, offsetX = 0, offsetY = 0 }
        base.cast = {
            width = 0, height = 16, iconSize = 20, offsetX = 0, offsetY = 0,
            showName = true, nameFontSize = 9, nameOffsetX = 0, nameOffsetY = -2,
            showTime = true, timeFontSize = 9, timeOffsetX = 0, timeOffsetY = -2,
        }
    end
    return base
end

local function EmptyTracking()
    return {
        target = { buff = {}, debuff = {}, hidden = {} },
        player = { buff = {}, debuff = {}, hidden = {} },
    }
end

-- Tracking data is intentionally persisted outside the main settings object.
-- ArcheRage RU silently truncates sufficiently large nested SaveData payloads.
-- V1 split by scope/effect (6 shards); V2 partitioned each bucket four ways.
-- V3 persisted a compact category tag and partitioned every bucket eight ways.
-- V4 uses sixteen partitions (96 shards per bank) because the V5 PvP library is
-- substantially larger and every row can carry a localized name/icon/category.
-- Old V1/V2/V3 manifests remain readable and are migrated atomically on the next
-- tracking write. Writes are infrequent user/config actions, so the extra SaveData
-- calls buy a much larger safety margin without affecting combat-frame performance.
local TRACKING_STORAGE_VERSION = 4
local TRACKING_PARTITIONS = 16
local TRACKING_SCOPES = { "target", "player" }
local TRACKING_EFFECTS = { "buff", "debuff", "hidden" }

local function TrackingManifestKey()
    return P.SaveKey .. "_tracking_manifest"
end

local function TrackingShardKey(bank, scope, effectType, partition, version)
    if tonumber(version) ~= nil and tonumber(version) >= 2 then
        return P.SaveKey .. "_tracking_" .. tostring(bank) .. "_" .. tostring(scope) .. "_" .. tostring(effectType) .. "_p" .. tostring(partition)
    end
    -- V1 compatibility key; read-only after migration.
    return P.SaveKey .. "_tracking_" .. tostring(bank) .. "_" .. tostring(scope) .. "_" .. tostring(effectType)
end

local function TrackingPartition(id)
    local numeric = tonumber(id) or 0
    return (math.floor(math.abs(numeric)) % TRACKING_PARTITIONS) + 1
end

local function SplitBucket(bucket)
    local result = {}
    for part = 1, TRACKING_PARTITIONS do result[part] = {} end
    for id, entry in pairs(bucket or {}) do
        local key = tostring(id or "")
        if key:match("^%d+$") then result[TrackingPartition(key)][key] = CopyEntry(entry) end
    end
    return result
end

local function CopyTracking(source)
    local result = EmptyTracking()
    if type(source) ~= "table" then return result end
    for _, scope in ipairs(TRACKING_SCOPES) do
        for _, effectType in ipairs(TRACKING_EFFECTS) do
            local bucket = type(source[scope]) == "table" and source[scope][effectType] or nil
            if type(bucket) == "table" then
                for id, entry in pairs(bucket) do
                    local key = tostring(id or "")
                    if key:match("^%d+$") then result[scope][effectType][key] = CopyEntry(entry) end
                end
            end
        end
    end
    return result
end

local function BucketCount(bucket)
    local count = 0
    if type(bucket) == "table" then for _ in pairs(bucket) do count = count + 1 end end
    return count
end

local function SameColor(left, right)
    if left == nil and right == nil then return true end
    if type(left) ~= "table" or type(right) ~= "table" then return false end
    for _, key in ipairs({ "r", "g", "b", "a" }) do
        if math.abs((tonumber(left[key]) or 0) - (tonumber(right[key]) or 0)) > 0.0001 then return false end
    end
    return true
end

local function SameBucket(left, right)
    if BucketCount(left) ~= BucketCount(right) then return false end
    for id, entry in pairs(left or {}) do
        local other = type(right) == "table" and right[id] or nil
        if type(other) ~= "table" then return false end
        for _, key in ipairs({ "name", "customName", "iconPath", "category" }) do
            if tostring(entry[key] or "") ~= tostring(other[key] or "") then return false end
        end
        for _, key in ipairs({ "enabled", "priority", "showDuration", "showStack", "showBorder", "showTooltip", "iconSize", "expireEnabled", "expireThreshold" }) do
            if entry[key] ~= other[key] then return false end
        end
        if not SameColor(entry.borderColor, other.borderColor) or not SameColor(entry.expireColor, other.expireColor) then return false end
    end
    return true
end

local function LoadTrackingManifest()
    local manifest, err = A:LoadData(TrackingManifestKey())
    if type(manifest) ~= "table" then return nil, err end
    local active = tostring(manifest.active or "")
    if active ~= "a" and active ~= "b" then return nil, "tracking manifest active bank invalid" end
    return { version = tonumber(manifest.version) or 0, active = active }, nil
end

local function ReadTrackingBank(bank, version)
    if bank ~= "a" and bank ~= "b" then return nil, "tracking bank invalid" end
    version = tonumber(version) or 1
    local result = EmptyTracking()
    for _, scope in ipairs(TRACKING_SCOPES) do
        for _, effectType in ipairs(TRACKING_EFFECTS) do
            local partitionCount = version >= 4 and TRACKING_PARTITIONS or (version >= 3 and 8 or (version >= 2 and 4 or 1))
            for part = 1, partitionCount do
                local key = TrackingShardKey(bank, scope, effectType, part, version)
                local value, err = A:LoadData(key)
                if err ~= nil then return nil, tostring(scope) .. "/" .. tostring(effectType) .. "/p" .. tostring(part) .. ": " .. tostring(err) end
                if type(value) ~= "table" then return nil, tostring(scope) .. "/" .. tostring(effectType) .. "/p" .. tostring(part) .. ": shard missing" end
                for id, entry in pairs(value) do
                    local idKey = tostring(id or "")
                    if idKey:match("^%d+$") then result[scope][effectType][idKey] = CopyEntry(entry) end
                end
            end
        end
    end
    return result, nil
end

local function ReadCommittedTracking()
    local manifest, manifestErr = LoadTrackingManifest()
    if manifest == nil then return nil, manifestErr end
    return ReadTrackingBank(manifest.active, manifest.version)
end

-- Aura Library v1 ---------------------------------------------------------
-- Normal Buff/Debuff IDs are stored exactly once. Scope/effect membership is
-- represented by a 4-bit mask:
--   0x1 player Buff, 0x2 player Debuff, 0x4 target Buff, 0x8 target Debuff.
-- Hidden effects deliberately stay on the legacy whitelist because they use a
-- separate diagnostic/visibility contract.
local AURA_STORAGE_VERSION = 1
local AURA_PARTITIONS = 32
local AURA_LANES = {
    { scope = "player", effect = "buff", bit = 1, syncKey = "playerBuff" },
    { scope = "player", effect = "debuff", bit = 2, syncKey = "playerDebuff" },
    { scope = "target", effect = "buff", bit = 4, syncKey = "targetBuff" },
    { scope = "target", effect = "debuff", bit = 8, syncKey = "targetDebuff" },
}

local function AuraLaneBit(scope, effectType)
    if scope == "player" and effectType == "buff" then return 1 end
    if scope == "player" and effectType == "debuff" then return 2 end
    if scope == "target" and effectType == "buff" then return 4 end
    if scope == "target" and effectType == "debuff" then return 8 end
    return nil
end

local function MaskHas(mask, bit)
    mask = math.max(0, math.min(15, math.floor(tonumber(mask) or 0)))
    return math.floor(mask / bit) % 2 == 1
end

local function MaskAdd(mask, bit)
    mask = math.max(0, math.min(15, math.floor(tonumber(mask) or 0)))
    if MaskHas(mask, bit) then return mask end
    return mask + bit
end

local function MaskRemove(mask, bit)
    mask = math.max(0, math.min(15, math.floor(tonumber(mask) or 0)))
    if not MaskHas(mask, bit) then return mask end
    return mask - bit
end

local function AuraManifestKey()
    return P.SaveKey .. "_aura_manifest"
end

local function AuraShardKey(bank, partition)
    return P.SaveKey .. "_aura_" .. tostring(bank) .. "_p" .. tostring(partition)
end

local function AuraPartition(id)
    local numeric = tonumber(id) or 0
    return (math.floor(math.abs(numeric)) % AURA_PARTITIONS) + 1
end

local function SameRuleEntry(left, right)
    if type(left) ~= "table" or type(right) ~= "table" then return false end
    for _, key in ipairs({ "name", "customName", "iconPath", "category" }) do
        if tostring(left[key] or "") ~= tostring(right[key] or "") then return false end
    end
    for _, key in ipairs({ "enabled", "priority", "showDuration", "showStack", "showBorder", "showTooltip", "iconSize", "expireEnabled", "expireThreshold" }) do
        if left[key] ~= right[key] then return false end
    end
    return SameColor(left.borderColor, right.borderColor) and SameColor(left.expireColor, right.expireColor)
end

local function CopyAuraEntry(value)
    value = type(value) == "table" and value or {}
    local mask = math.max(0, math.min(15, math.floor(tonumber(value.mask or value.m) or 0)))
    local base = CopyEntry(value.base or value.b)
    local overrides = {}
    local sourceOverrides = type(value.overrides) == "table" and value.overrides or type(value.o) == "table" and value.o or nil
    if type(sourceOverrides) == "table" then
        for bitKey, entry in pairs(sourceOverrides) do
            local bit = tonumber(bitKey)
            if (bit == 1 or bit == 2 or bit == 4 or bit == 8) and MaskHas(mask, bit) and type(entry) == "table" then
                local copy = CopyEntry(entry)
                if not SameRuleEntry(copy, base) then overrides[tostring(bit)] = copy end
            end
        end
    end
    return { mask = mask, base = base, overrides = overrides }
end

local function AuraLaneEntry(aura, bit)
    aura = CopyAuraEntry(aura)
    local override = aura.overrides[tostring(bit)]
    return CopyEntry(type(override) == "table" and override or aura.base)
end

local function CopyAuraLibrary(source)
    local result = {}
    if type(source) ~= "table" then return result end
    for id, value in pairs(source) do
        local key = tostring(id or "")
        if key:match("^%d+$") then
            local entry = CopyAuraEntry(value)
            if entry.mask > 0 then result[key] = entry end
        end
    end
    return result
end

local function AuraLibraryCount(source)
    local count = 0
    for _, value in pairs(source or {}) do
        if type(value) == "table" and (tonumber(value.mask or value.m) or 0) > 0 then count = count + 1 end
    end
    return count
end

local function SameAuraEntry(left, right)
    local a, b = CopyAuraEntry(left), CopyAuraEntry(right)
    if a.mask ~= b.mask or not SameRuleEntry(a.base, b.base) then return false end
    for _, lane in ipairs(AURA_LANES) do
        if MaskHas(a.mask, lane.bit) then
            if not SameRuleEntry(AuraLaneEntry(a, lane.bit), AuraLaneEntry(b, lane.bit)) then return false end
        end
    end
    return true
end

local function SameAuraBucket(left, right)
    if BucketCount(left) ~= BucketCount(right) then return false end
    for id, entry in pairs(left or {}) do
        local other = type(right) == "table" and right[id] or nil
        if type(other) ~= "table" or not SameAuraEntry(entry, other) then return false end
    end
    return true
end

local function SplitAuraLibrary(source)
    local result = {}
    for part = 1, AURA_PARTITIONS do result[part] = {} end
    for id, value in pairs(source or {}) do
        local key = tostring(id or "")
        if key:match("^%d+$") then
            local entry = CopyAuraEntry(value)
            if entry.mask > 0 then
                local compact = { m = entry.mask, b = entry.base }
                if next(entry.overrides) ~= nil then compact.o = entry.overrides end
                result[AuraPartition(key)][key] = compact
            end
        end
    end
    return result
end

local function LoadAuraManifest()
    local manifest, err = A:LoadData(AuraManifestKey())
    if type(manifest) ~= "table" then return nil, err end
    local active = tostring(manifest.active or "")
    if active ~= "a" and active ~= "b" then return nil, "aura manifest active bank invalid" end
    return { version = tonumber(manifest.version) or 0, active = active }, nil
end

local function ReadAuraBank(bank, version)
    if bank ~= "a" and bank ~= "b" then return nil, "aura bank invalid" end
    version = tonumber(version) or 1
    if version ~= AURA_STORAGE_VERSION then return nil, "unsupported aura storage version: " .. tostring(version) end
    local result = {}
    for part = 1, AURA_PARTITIONS do
        local key = AuraShardKey(bank, part)
        local value, err = A:LoadData(key)
        if err ~= nil then return nil, "aura/p" .. tostring(part) .. ": " .. tostring(err) end
        if type(value) ~= "table" then return nil, "aura/p" .. tostring(part) .. ": shard missing" end
        for id, entry in pairs(value) do
            local idKey = tostring(id or "")
            if idKey:match("^%d+$") then
                local copy = CopyAuraEntry(entry)
                if copy.mask > 0 then result[idKey] = copy end
            end
        end
    end
    return result, nil
end

local function ReadCommittedAuraLibrary()
    local manifest, manifestErr = LoadAuraManifest()
    if manifest == nil then return nil, manifestErr end
    return ReadAuraBank(manifest.active, manifest.version)
end

local function BuildAuraLibraryFromTracking(tracking)
    local result = {}
    for _, lane in ipairs(AURA_LANES) do
        local bucket = type(tracking) == "table" and type(tracking[lane.scope]) == "table" and tracking[lane.scope][lane.effect] or nil
        if type(bucket) == "table" then
            for id, row in pairs(bucket) do
                local key = tostring(id or "")
                if key:match("^%d+$") and type(row) == "table" then
                    local aura = result[key]
                    if type(aura) ~= "table" then
                        aura = { mask = 0, base = CopyEntry(row), overrides = {} }
                        result[key] = aura
                    end
                    aura.mask = MaskAdd(aura.mask, lane.bit)
                    local copy = CopyEntry(row)
                    if not SameRuleEntry(copy, aura.base) then aura.overrides[tostring(lane.bit)] = copy end
                end
            end
        end
    end
    return result
end

local function BuildEffectiveTracking(hiddenSource, auraLibrary)
    local result = EmptyTracking()
    for _, scope in ipairs(TRACKING_SCOPES) do
        local hidden = type(hiddenSource) == "table" and type(hiddenSource[scope]) == "table" and hiddenSource[scope].hidden or nil
        if type(hidden) == "table" then
            for id, entry in pairs(hidden) do
                local key = tostring(id or "")
                if key:match("^%d+$") then result[scope].hidden[key] = CopyEntry(entry) end
            end
        end
    end
    for id, auraValue in pairs(auraLibrary or {}) do
        local key = tostring(id or "")
        local aura = CopyAuraEntry(auraValue)
        if key:match("^%d+$") and aura.mask > 0 then
            for _, lane in ipairs(AURA_LANES) do
                if MaskHas(aura.mask, lane.bit) then result[lane.scope][lane.effect][key] = AuraLaneEntry(aura, lane.bit) end
            end
        end
    end
    return result
end

local function CopyTrackingForPersistence(source)
    local result = EmptyTracking()
    for _, scope in ipairs(TRACKING_SCOPES) do
        local hidden = type(source) == "table" and type(source[scope]) == "table" and source[scope].hidden or nil
        if type(hidden) == "table" then
            for id, entry in pairs(hidden) do
                local key = tostring(id or "")
                if key:match("^%d+$") then result[scope].hidden[key] = CopyEntry(entry) end
            end
        end
    end
    return result
end

local function Defaults()
    return {
        schemaVersion = P.SchemaVersion,
        target = PlateDefaults("target"),
        player = PlateDefaults("player"),
        tracking = EmptyTracking(),
        -- AuraLibrary is the single Authority for normal Buff/Debuff IDs.
        -- Each ID is stored once with a 4-bit scope mask; the legacy tracking
        -- table is rebuilt as a runtime/UI compatibility Proxy. Hidden remains
        -- on the legacy whitelist because it has different diagnostic semantics.
        auraLibrary = {},
        auraSync = { enabled = false, mode = "same", playerBuff = true, playerDebuff = true, targetBuff = true, targetDebuff = true },
        manager = { x = 190, y = 120, activeScope = "target", activeEffect = "buff" },
        hudLayout = { x = 230, y = 110 },
        transfer = { x = 300, y = 190 },
        diagnostics = { x = 300, y = 150 },
        launcher = { x = 300, y = 100 },
        settingsWindow = { x = 260, y = 180 },
        colorPresets = {},
        -- Opt-out projection fallback for plate anchoring (D-2). Default ON;
        -- missing config (nil) also means ON - only explicit false disables.
        positionProjection = true,
        -- Buff-count cap warning (report 八-P0-1). Default ON is a report-level
        -- decision. threshold=36 warns "close to cap"; real cap (~40) is
        -- verified on live client and the default is adjusted afterwards.
        buffcap = { enabled = true, threshold = 36, fontSize = 12, offsetX = 0, offsetY = 8 },
        -- Magic-circle distance tracker (report 八-P1-1). Default OFF (report
        -- decision). The buff IDs are data-driven because they are only
        -- verified on a live client; warn/max thresholds are in metres and the
        -- offset anchors to the player plate (C10: plate-relative coordinates,
        -- plates carry no global SetScale).
        magiccircle = { enabled = false, offsetX = 200, offsetY = -6, fontSize = 11, alpha = 95,
                        warnM = 25, maxM = 29.9, buffIds = { 19037, 25850, 25851 } },
        -- watchtarget aggro/distance mini-windows (report 七-C). Both default
        -- OFF; distance colour thresholds in metres. Availability of the
        -- watchtarget token family is ⚠️ runtime verified.
        watchtarget = { aggroEnabled = false, distEnabled = false, orangeAt = 150, redAt = 200 },
        -- Combat alerts (report 七-方案A). The alerts window itself is owned
        -- by the shared S.Services.Alerts channel; this top-level block is the
        -- plates consumer configuration. items = { [alertKey]=bool } per-alert
        -- switches (missing -> enabled); custom = { [debuffId]=text } extra
        -- debuff alerts. Default OFF for the whole feature.
        alerts = {
            enabled = false,
            style = "countdown",
            anchorMode = "center",
            scale = 100,
            scope = "target+player",
            items = {},
            custom = {},
        },
        -- Unit connection lines (report 七-方案B). 4 pre-created dot pools (one
        -- per pair, <=64 dots each); pairs select which connections render.
        -- targetFromPlayer/watchFromPlayer start from the player instead of the
        -- origin unit. All defaults OFF except target + target-of-target.
        lines = {
            enabled = false,
            pairs = { target = true, targetoftarget = true, watchtarget = false, watchtargettarget = false },
            targetFromPlayer = false,
            watchFromPlayer = false,
            minDots = 8,
            maxDots = 64,
            dotFontSize = 15,
            dotAlpha = 100,
            -- Optimize 1: configurable update cadence (ms). 100 = smooth but
            -- heavier; higher values are lighter on weak machines. Applied by
            -- the runtime lane interval.
            updateMs = 100,
            -- Player-centred distance circle (F5, easypull safe adaptation).
            -- World-space horizontal circle projected to screen; depth>0 dots
            -- only (camera-behind culling). Sizes honour addonScale (C10).
            circle = {
                enabled = false,
                radiusM = 20,
                dots = 72,
                zOffset = 0.8,
            },
        },
    }
end

local function ApplyEffectLayout(target, saved)
    if type(saved) ~= "table" then return end
    target.iconSize = Clamp(saved.iconSize, 18, 42, target.iconSize)
    target.fontSize = Clamp(saved.fontSize, 8, 18, target.fontSize or 10)
    target.maxCount = math.floor(Clamp(saved.maxCount or saved.max, 1, 12, target.maxCount) + 0.5)
    target.columns = math.floor(Clamp(saved.columns, 1, 12, target.columns or 6) + 0.5)
    target.gap = math.floor(Clamp(saved.gap, 0, 12, target.gap or 2) + 0.5)
    target.rowGap = math.floor(Clamp(saved.rowGap, 0, 12, target.rowGap or 2) + 0.5)
    local direction = tostring(saved.direction or target.direction)
    target.direction = (direction == "LEFT" or direction == "UP" or direction == "DOWN") and direction or "RIGHT"
    target.offsetX = Clamp(saved.offsetX, -300, 300, target.offsetX)
    target.offsetY = Clamp(saved.offsetY, -300, 300, target.offsetY)
    if saved.showDuration ~= nil then target.showDuration = saved.showDuration ~= false end
    if saved.showStack ~= nil then target.showStack = saved.showStack ~= false end
    if saved.showBorder ~= nil then target.showBorder = saved.showBorder ~= false end
    if saved.showTooltip ~= nil then target.showTooltip = saved.showTooltip ~= false end
    if type(saved.borderColor) == "table" then target.borderColor = CopyColor(saved.borderColor, target.borderColor) end
    if saved.expireEnabled ~= nil then target.expireEnabled = saved.expireEnabled == true end
    target.expireThreshold = Clamp(saved.expireThreshold, 1, 60, target.expireThreshold or 5)
    if type(saved.expireColor) == "table" then target.expireColor = CopyColor(saved.expireColor, target.expireColor) end
end

local function ApplyPlateSaved(target, saved, scope)
    if type(saved) ~= "table" then return end
    if saved.enabled ~= nil then target.enabled = saved.enabled ~= false end
    target.offsetX = Clamp(saved.offsetX, -1200, 1200, target.offsetX)
    target.offsetY = Clamp(saved.offsetY, -1200, 1200, target.offsetY)
    target.width = Clamp(saved.width, 230, 460, target.width)
    if saved.anchorMode ~= nil then
        local anchorMode = tostring(saved.anchorMode)
        target.anchorMode = anchorMode == "BOTTOM" and "BOTTOM" or "TOP"
    end
    target.sectionGap = math.floor(Clamp(saved.sectionGap, 0, 20, target.sectionGap or 4) + 0.5)
    if saved.showBuffs ~= nil then target.showBuffs = saved.showBuffs ~= false end
    if saved.showDebuffs ~= nil then target.showDebuffs = saved.showDebuffs ~= false end
    if saved.showHidden ~= nil then target.showHidden = saved.showHidden == true end
    if saved.showCast ~= nil then target.showCast = saved.showCast == true end
    if saved.showDistance ~= nil then target.showDistance = saved.showDistance == true end
    if saved.trackedOnly ~= nil then target.trackedOnly = saved.trackedOnly == true end
    if saved.autoPvPRelevant ~= nil then target.autoPvPRelevant = saved.autoPvPRelevant == true end
    if type(saved.distance) == "table" then
        target.distance.fontSize = Clamp(saved.distance.fontSize, 8, 24, target.distance.fontSize)
        target.distance.offsetX = Clamp(saved.distance.offsetX, -300, 300, target.distance.offsetX)
        target.distance.offsetY = Clamp(saved.distance.offsetY, -300, 300, target.distance.offsetY)
        target.distance.warningAt = Clamp(saved.distance.warningAt, 0, 200, target.distance.warningAt)
        target.distance.dangerAt = Clamp(saved.distance.dangerAt, target.distance.warningAt, 300, target.distance.dangerAt)
    end

    -- Schema v2 migration: one shared iconSize/max* per plate.
    local legacyIconSize = tonumber(saved.iconSize)
    for _, effectType in ipairs({ "buff", "debuff", "hidden" }) do
        if legacyIconSize ~= nil then target.effects[effectType].iconSize = Clamp(legacyIconSize, 18, 42, target.effects[effectType].iconSize) end
    end
    if saved.maxBuffs ~= nil then target.effects.buff.maxCount = math.floor(Clamp(saved.maxBuffs, 1, 12, 8) + 0.5) end
    if saved.maxDebuffs ~= nil then target.effects.debuff.maxCount = math.floor(Clamp(saved.maxDebuffs, 1, 12, 8) + 0.5) end
    if saved.maxHidden ~= nil then target.effects.hidden.maxCount = math.floor(Clamp(saved.maxHidden, 1, 12, 8) + 0.5) end
    if type(saved.effects) == "table" then
        for _, effectType in ipairs({ "buff", "debuff", "hidden" }) do ApplyEffectLayout(target.effects[effectType], saved.effects[effectType]) end
    end

    if scope == "target" then
        if saved.showTargetOfTarget ~= nil then target.showTargetOfTarget = saved.showTargetOfTarget == true end
        if type(saved.targetOfTarget) == "table" and type(target.targetOfTarget) == "table" then
            target.targetOfTarget.fontSize = Clamp(saved.targetOfTarget.fontSize, 8, 18, target.targetOfTarget.fontSize or 10)
            target.targetOfTarget.offsetX = Clamp(saved.targetOfTarget.offsetX, -300, 300, target.targetOfTarget.offsetX)
            target.targetOfTarget.offsetY = Clamp(saved.targetOfTarget.offsetY, -300, 300, target.targetOfTarget.offsetY)
        end
        if saved.showGear ~= nil then target.showGear = saved.showGear == true end
        if saved.showLoadout ~= nil then target.showLoadout = saved.showLoadout == true end
        if saved.showClass ~= nil then target.showClass = saved.showClass == true end
        if type(saved.class) == "table" then
            if saved.class.showIcon ~= nil then target.class.showIcon = saved.class.showIcon == true end
            if saved.class.showName ~= nil then target.class.showName = saved.class.showName == true end
            target.class.iconSize = Clamp(saved.class.iconSize, 18, 36, target.class.iconSize)
            target.class.fontSize = Clamp(saved.class.fontSize, 9, 20, target.class.fontSize or 12)
            target.class.offsetX = Clamp(saved.class.offsetX, -300, 300, target.class.offsetX)
            target.class.offsetY = Clamp(saved.class.offsetY, -300, 300, target.class.offsetY)
        end
        if type(saved.gear) == "table" then
            target.gear.fontSize = Clamp(saved.gear.fontSize, 9, 20, target.gear.fontSize or 12)
            target.gear.offsetX = Clamp(saved.gear.offsetX, -300, 300, target.gear.offsetX)
            target.gear.offsetY = Clamp(saved.gear.offsetY, -300, 300, target.gear.offsetY)
        end
        if type(saved.loadout) == "table" then
            target.loadout.fontSize = Clamp(saved.loadout.fontSize, 9, 20, target.loadout.fontSize or 11)
            target.loadout.offsetX = Clamp(saved.loadout.offsetX, -300, 300, target.loadout.offsetX)
            target.loadout.offsetY = Clamp(saved.loadout.offsetY, -300, 300, target.loadout.offsetY)
        end
        if type(saved.cast) == "table" then
            target.cast.width = Clamp(saved.cast.width, 0, 450, target.cast.width)
            target.cast.height = Clamp(saved.cast.height, 10, 40, target.cast.height)
            target.cast.iconSize = Clamp(saved.cast.iconSize, 16, 42, target.cast.iconSize)
            target.cast.offsetX = Clamp(saved.cast.offsetX, -300, 300, target.cast.offsetX)
            target.cast.offsetY = Clamp(saved.cast.offsetY, -300, 300, target.cast.offsetY)
            if saved.cast.showName ~= nil then target.cast.showName = saved.cast.showName ~= false end
            target.cast.nameFontSize = Clamp(saved.cast.nameFontSize, 8, 24, target.cast.nameFontSize or 9)
            target.cast.nameOffsetX = Clamp(saved.cast.nameOffsetX, -300, 300, target.cast.nameOffsetX or 0)
            target.cast.nameOffsetY = Clamp(saved.cast.nameOffsetY, -300, 300, target.cast.nameOffsetY or -2)
            if saved.cast.showTime ~= nil then target.cast.showTime = saved.cast.showTime ~= false end
            target.cast.timeFontSize = Clamp(saved.cast.timeFontSize, 8, 24, target.cast.timeFontSize or 9)
            target.cast.timeOffsetX = Clamp(saved.cast.timeOffsetX, -300, 300, target.cast.timeOffsetX or 0)
            target.cast.timeOffsetY = Clamp(saved.cast.timeOffsetY, -300, 300, target.cast.timeOffsetY or -2)
        end
    elseif scope == "player" then
        if saved.showEquipment ~= nil then target.showEquipment = saved.showEquipment == true end
        if saved.showImportantCooldowns ~= nil then target.showImportantCooldowns = saved.showImportantCooldowns == true end
        if type(saved.cooldowns) == "table" and type(target.cooldowns) == "table" then ApplyEffectLayout(target.cooldowns, saved.cooldowns) end
        if type(saved.equipment) == "table" then
            local eq = saved.equipment
            target.equipment.iconSize = Clamp(eq.iconSize, 18, 42, target.equipment.iconSize)
            local direction = tostring(eq.direction or target.equipment.direction)
            target.equipment.direction = (direction == "LEFT" or direction == "UP" or direction == "DOWN") and direction or "RIGHT"
            target.equipment.offsetX = Clamp(eq.offsetX, -300, 300, target.equipment.offsetX)
            target.equipment.offsetY = Clamp(eq.offsetY, -300, 300, target.equipment.offsetY)
            for _, key in ipairs({ "showGlider", "showMainhand", "showOffhand", "showRanged" }) do
                if eq[key] ~= nil then target.equipment[key] = eq[key] == true end
            end
        end
    end
end

local function ApplyTracking(target, saved)
    if type(saved) ~= "table" then return end
    for scope, effectBuckets in pairs(target) do
        local savedScope = saved[scope]
        if type(savedScope) == "table" then
            for effectType, bucket in pairs(effectBuckets) do
                local savedBucket = savedScope[effectType]
                if type(savedBucket) == "table" then
                    for id, value in pairs(savedBucket) do
                        local key = tostring(id or "")
                        if key:match("^%d+$") then bucket[key] = CopyEntry(value) end
                    end
                end
            end
        end
    end
end

local function ApplyWindowPosition(target, saved, key)
    if type(saved) ~= "table" then return end
    target[key].x = Clamp(saved.x, 0, 10000, target[key].x)
    target[key].y = Clamp(saved.y, 0, 10000, target[key].y)
end

local function ApplySaved(target, saved)
    if type(saved) ~= "table" then return end
    local savedSchema = math.max(0, math.floor(tonumber(saved.schemaVersion) or 0))
    ApplyPlateSaved(target.target, saved.target, "target")
    ApplyPlateSaved(target.player, saved.player, "player")
    -- Schema 8 fixes the old untouched target defaults that placed gear score
    -- and distance in the same top-right area and rendered metadata too small.
    -- Only migrate values that exactly match the previous product defaults so
    -- deliberate user sizing remains authoritative.
    if savedSchema < 8 then
        if tonumber(target.target.distance.fontSize) == 10 then target.target.distance.fontSize = 12 end
        if tonumber(target.target.class.iconSize) == 22 then target.target.class.iconSize = 26 end
        if tonumber(target.target.class.fontSize) == nil then target.target.class.fontSize = 12 end
        if tonumber(target.target.gear.fontSize) == nil then target.target.gear.fontSize = 12 end
    end
    -- Schema 10 changes target positioning semantics only for untouched/default
    -- profiles: target.offsetY becomes the BOTTOM-edge clearance from the native
    -- unit screen point. This makes variable-height Buff/Debuff rows expand up.
    -- Old custom whole-HUD positions stay TOP-anchored to avoid jumping.
    if savedSchema < 10 then
        local savedTarget = type(saved.target) == "table" and saved.target or nil
        local oldY = savedTarget and tonumber(savedTarget.offsetY) or nil
        local oldAnchor = savedTarget and savedTarget.anchorMode or nil
        if oldAnchor == nil then
            if oldY == nil or oldY == -86 or oldY == -118 then
                target.target.anchorMode = "BOTTOM"
                target.target.offsetY = -34
            else
                target.target.anchorMode = "TOP"
            end
        end
    end
    -- Schema 15 repairs the consolidated-build double visibility gate. Older
    -- builds could persist both legacy HUD flags off while the Suite module was
    -- enabled, making the feature appear completely broken. Repair only the
    -- all-off legacy state once; later user choices remain authoritative.
    if savedSchema < 15 and target.target.enabled ~= true and target.player.enabled ~= true then
        target.target.enabled = true
        target.player.enabled = true
    end

    -- Schema 17 stops forcing the four Player equipment icons on screen.  Older
    -- builds persisted the old all-on defaults even when the user never chose
    -- them, so migrate only the exact untouched legacy shape.  Any customized
    -- size/direction/offset/slot selection remains authoritative.
    if savedSchema < 17 then
        local savedPlayer = type(saved.player) == "table" and saved.player or nil
        local savedEq = savedPlayer and type(savedPlayer.equipment) == "table" and savedPlayer.equipment or nil
        local legacyUntouched = savedPlayer ~= nil
            and savedPlayer.showEquipment ~= false
            and (savedEq == nil or (
                (savedEq.showGlider == nil or savedEq.showGlider == true)
                and (savedEq.showMainhand == nil or savedEq.showMainhand == true)
                and (savedEq.showOffhand == nil or savedEq.showOffhand == true)
                and (savedEq.showRanged == nil or savedEq.showRanged == true)
                and (savedEq.iconSize == nil or tonumber(savedEq.iconSize) == 26)
                and (savedEq.direction == nil or tostring(savedEq.direction) == "RIGHT")
                and (savedEq.offsetX == nil or tonumber(savedEq.offsetX) == 0)
                and (savedEq.offsetY == nil or tonumber(savedEq.offsetY) == 0)
            ))
        if legacyUntouched then target.player.showEquipment = false end
    end

    -- v5 product default: every scope starts in tracked-only mode. Existing v4
    -- test profiles are migrated once so the new default is visible immediately;
    -- after the v5 save, any user toggle is preserved normally.
    if savedSchema < 5 then
        target.target.trackedOnly = true
        target.player.trackedOnly = true
    end
    ApplyTracking(target.tracking, saved.tracking)
    for _, key in ipairs({ "launcher", "settingsWindow", "manager", "hudLayout", "transfer", "diagnostics" }) do
        ApplyWindowPosition(target, saved[key], key)
    end
    -- schema 6: move only the untouched v5 BUFF launcher into the shared
    -- Replicated launcher cluster. A player-dragged launcher is preserved.
    if savedSchema < 6 and type(saved.launcher) == "table" then
        local lx, ly = tonumber(saved.launcher.x), tonumber(saved.launcher.y)
        if lx ~= nil and ly ~= nil and math.abs(lx - 12) < 0.01 and math.abs(ly - 202) < 0.01 then
            target.launcher.x = 300
            target.launcher.y = 100
        end
    end
    if type(saved.auraSync) == "table" then
        target.auraSync.enabled = saved.auraSync.enabled == true
        target.auraSync.mode = tostring(saved.auraSync.mode or target.auraSync.mode)=="all" and "all" or "same"
        for _, key in ipairs({ "playerBuff", "playerDebuff", "targetBuff", "targetDebuff" }) do
            if saved.auraSync[key] ~= nil then target.auraSync[key] = saved.auraSync[key] == true end
        end
    end

    if type(saved.colorPresets) == "table" then
        target.colorPresets = {}
        for _, preset in ipairs(saved.colorPresets) do
            if type(preset) == "table" and tostring(preset.name or "") ~= "" and #target.colorPresets < 24 then
                target.colorPresets[#target.colorPresets + 1] = {
                    name = tostring(preset.name):sub(1, 24),
                    color = CopyColor(preset.color),
                }
            end
        end
    end

    if type(saved.manager) == "table" then
        local scope = tostring(saved.manager.activeScope or "target")
        local effectType = tostring(saved.manager.activeEffect or "buff")
        if target.tracking[scope] ~= nil and target.tracking[scope][effectType] ~= nil then
            target.manager.activeScope, target.manager.activeEffect = scope, effectType
        end
    end

    -- watchtarget mini-windows (report 七-C): booleans default off, distance
    -- thresholds clamped so orange < red always holds.
    if type(saved.watchtarget) == "table" then
        local wt = saved.watchtarget
        if wt.aggroEnabled ~= nil then target.watchtarget.aggroEnabled = wt.aggroEnabled == true end
        if wt.distEnabled ~= nil then target.watchtarget.distEnabled = wt.distEnabled == true end
        target.watchtarget.orangeAt = Clamp(wt.orangeAt, 10, 500, target.watchtarget.orangeAt)
        target.watchtarget.redAt = Clamp(wt.redAt, target.watchtarget.orangeAt, 500, target.watchtarget.redAt)
    end

    -- Combat alerts (report 七-方案A): scalars + per-key switches + custom
    -- debuff map. items/custom accept any saved shape; a missing key means
    -- "enabled by default" at match time.
    if type(saved.alerts) == "table" then
        local al = saved.alerts
        if al.enabled ~= nil then target.alerts.enabled = al.enabled == true end
        local style = tostring(al.style or "")
        if style == "countdown" or style == "bigtext" then target.alerts.style = style end
        local anchor = tostring(al.anchorMode or "")
        if anchor == "center" or anchor == "top" then target.alerts.anchorMode = anchor end
        target.alerts.scale = Clamp(al.scale, 60, 200, target.alerts.scale)
        local scope = tostring(al.scope or "")
        if scope == "target" or scope == "player" or scope == "target+player" then target.alerts.scope = scope end
        if type(al.items) == "table" then
            target.alerts.items = {}
            for key, value in pairs(al.items) do
                if type(key) == "string" and key ~= "" then target.alerts.items[key] = value == true end
            end
        end
        if type(al.custom) == "table" then
            target.alerts.custom = {}
            for id, text in pairs(al.custom) do
                local numeric = tonumber(id)
                if numeric ~= nil and tostring(text) ~= "" then
                    target.alerts.custom[tostring(math.floor(numeric))] = tostring(text)
                end
            end
        end
    end

    -- Unit connection lines (report 七-方案B): scalars + per-pair switches.
    if type(saved.lines) == "table" then
        local ln = saved.lines
        if ln.enabled ~= nil then target.lines.enabled = ln.enabled == true end
        if type(ln.pairs) == "table" then
            for key in pairs(target.lines.pairs) do
                if ln.pairs[key] ~= nil then target.lines.pairs[key] = ln.pairs[key] == true end
            end
        end
        if ln.targetFromPlayer ~= nil then target.lines.targetFromPlayer = ln.targetFromPlayer == true end
        if ln.watchFromPlayer ~= nil then target.lines.watchFromPlayer = ln.watchFromPlayer == true end
        target.lines.minDots = math.floor(Clamp(ln.minDots, 4, 128, target.lines.minDots) + 0.5)
        target.lines.maxDots = math.floor(Clamp(ln.maxDots, target.lines.minDots, 128, target.lines.maxDots) + 0.5)
        target.lines.dotFontSize = math.floor(Clamp(ln.dotFontSize, 8, 40, target.lines.dotFontSize) + 0.5)
        target.lines.dotAlpha = math.floor(Clamp(ln.dotAlpha, 20, 100, target.lines.dotAlpha) + 0.5)
        -- Optimize 1: update cadence 50-500ms.
        target.lines.updateMs = math.floor(Clamp(ln.updateMs, 50, 500, target.lines.updateMs) + 0.5)
        -- Player-centred distance circle (F5).
        if type(ln.circle) == "table" then
            local circ = ln.circle
            if circ.enabled ~= nil then target.lines.circle.enabled = circ.enabled == true end
            target.lines.circle.radiusM = Clamp(circ.radiusM, 5, 50, target.lines.circle.radiusM)
            local dots = math.floor(Clamp(circ.dots, 24, 128, target.lines.circle.dots) + 0.5)
            target.lines.circle.dots = dots - (dots % 4) -- step 4
            target.lines.circle.zOffset = Clamp(circ.zOffset, 0, 5, target.lines.circle.zOffset)
        end
    end
end

function S:Load()
    self.writeFenceReason = nil
    self.writeFenceWarned = false
    self.futureSchemaVersion = nil
    self.trackingFutureVersion = nil
    self.auraFutureVersion = nil
    local settings = Defaults()
    local saved, err = A:LoadData(P.SaveKey)
    local settingsReadErr = err
    if type(saved) ~= "table" then
        local backup, backupErr = A:LoadData(P.BackupSaveKey)
        if type(backup) == "table" then
            saved, err, settingsReadErr = backup, nil, nil
            P.SafeChat("主设置不可用，已从上一版安全备份恢复。")
        else
            settingsReadErr = settingsReadErr or backupErr
        end
        if type(backup) ~= "table" and err ~= nil then
            P.SafeChat("读取设置失败，将使用默认值：" .. tostring(err))
        elseif type(backup) ~= "table" and backupErr ~= nil then
            P.SafeChat("读取设置备份失败，将使用默认值：" .. tostring(backupErr))
        end
    end
    local savedSchema = type(saved) == "table" and math.max(0, math.floor(tonumber(saved.schemaVersion) or 0)) or 0
    if savedSchema > P.SchemaVersion then
        self.futureSchemaVersion = savedSchema
        self.writeFenceReason = "future_settings_schema:" .. tostring(savedSchema) .. ">" .. tostring(P.SchemaVersion)
        P.SafeChat("检测到更高版本 BUFF 配置，已读取已知字段但不会覆盖原保存。")
        self.writeFenceWarned = true
    elseif type(saved) ~= "table" and settingsReadErr ~= nil then
        self.writeFenceReason = "load_failed"
        P.SafeChat("BUFF 配置读取失败，原保存已进入写保护。")
        self.writeFenceWarned = true
    end
    ApplySaved(settings, saved)

    -- Schema 12+ tracking authority lives in verified shards. If no manifest
    -- exists yet, keep the legacy tracking embedded in the primary settings;
    -- the next save will migrate it without requiring user action.
    local manifest, manifestErr = LoadTrackingManifest()
    if type(manifest) == "table" and (tonumber(manifest.version) or 0) > TRACKING_STORAGE_VERSION then
        self.trackingFutureVersion = tonumber(manifest.version)
        self.writeFenceReason = self.writeFenceReason or ("future_tracking_schema:" .. tostring(manifest.version) .. ">" .. tostring(TRACKING_STORAGE_VERSION))
        if self.writeFenceWarned ~= true then
            P.SafeChat("检测到更高版本 BUFF 追踪存档，当前版本不会覆盖原保存。")
            self.writeFenceWarned = true
        end
    end
    local committedTracking, trackingErr = nil, manifestErr
    if type(manifest) == "table" and self.trackingFutureVersion == nil then
        committedTracking, trackingErr = ReadTrackingBank(manifest.active, manifest.version)
    end
    if type(committedTracking) == "table" then
        settings.tracking = committedTracking
        self.trackingSharded = true
    else
        self.trackingSharded = false
        if trackingErr ~= nil then
            self.writeFenceReason = self.writeFenceReason or "tracking_load_failed"
            if self.writeFenceWarned ~= true then
                P.SafeChat("BUFF 追踪存档读取不完整，原保存已进入写保护。")
                self.writeFenceWarned = true
            end
            local manifest = A:LoadData(TrackingManifestKey())
            if type(manifest) == "table" then
                P.SafeChat("追踪数据分片读取失败，暂用旧配置：" .. tostring(trackingErr))
            end
        end
    end

    -- AuraLibrary becomes the Buff/Debuff Authority. Existing profiles are
    -- migrated in memory from the old four tracking buckets, but no write is
    -- performed during Load(). The next explicit settings/tracking save commits
    -- the Aura shards and clears duplicated Buff/Debuff rows from legacy shards.
    local auraManifest, auraManifestErr = LoadAuraManifest()
    if type(auraManifest) == "table" and (tonumber(auraManifest.version) or 0) > AURA_STORAGE_VERSION then
        self.auraFutureVersion = tonumber(auraManifest.version)
        self.writeFenceReason = self.writeFenceReason or ("future_aura_schema:" .. tostring(auraManifest.version) .. ">" .. tostring(AURA_STORAGE_VERSION))
        if self.writeFenceWarned ~= true then
            P.SafeChat("检测到更高版本 BUFF 状态库，当前版本不会覆盖原保存。")
            self.writeFenceWarned = true
        end
    end
    local committedAura, auraErr = nil, auraManifestErr
    if type(auraManifest) == "table" and self.auraFutureVersion == nil then
        committedAura, auraErr = ReadAuraBank(auraManifest.active, auraManifest.version)
    end
    local migratedAura = false
    if type(committedAura) == "table" then
        settings.auraLibrary = committedAura
        self.auraSharded = true
    else
        self.auraSharded = false
        settings.auraLibrary = BuildAuraLibraryFromTracking(settings.tracking)
        migratedAura = AuraLibraryCount(settings.auraLibrary) > 0
        if type(auraManifest) == "table" and auraErr ~= nil then
            self.writeFenceReason = self.writeFenceReason or "aura_load_failed"
            if self.writeFenceWarned ~= true then
                P.SafeChat("BUFF 状态库存档读取不完整，原保存已进入写保护。")
                self.writeFenceWarned = true
            end
        end
    end

    settings.tracking = BuildEffectiveTracking(settings.tracking, settings.auraLibrary)
    self.settings = settings
    self.dirty = false
    self.auraDirty = migratedAura
    -- Migration also rewrites the old tracking shards once so persisted normal
    -- Buff/Debuff rows are removed; only Hidden stays there afterwards.
    self.trackingDirty = migratedAura
    return settings
end

function S:Get() if self.settings == nil then return self:Load() end return self.settings end
function S:GetPlate(scope) return self:Get()[scope] end
function S:MarkDirty() self.dirty = true end
function S:MarkTrackingDirty() self.dirty = true; self.trackingDirty = true end
function S:MarkAuraDirty() self.dirty = true; self.auraDirty = true end
function S:ReadCommittedTracking() return ReadCommittedTracking() end
function S:ReadCommittedAuraLibrary() return ReadCommittedAuraLibrary() end

local function ClearVerified(key)
    if ADDON == nil or type(ADDON.ClearData) ~= "function" then return true end
    local cleared, clearErr = A:ClearData(key)
    if cleared then return true end
    -- Some RU client builds return false when the key was already empty. Only
    -- treat it as a blocker if data is still present after the clear attempt.
    local remaining, loadErr = A:LoadData(key)
    if loadErr ~= nil then return false, "clear verification load failed: " .. tostring(loadErr) end
    if remaining ~= nil then return false, clearErr or "clear failed" end
    return true
end

local function BuildPrimarySnapshot(settings)
    local snapshot = {}
    for key, value in pairs(settings or {}) do
        if key ~= "tracking" and key ~= "auraLibrary" then snapshot[key] = value end
    end
    snapshot.trackingStorageVersion = TRACKING_STORAGE_VERSION
    snapshot.auraStorageVersion = AURA_STORAGE_VERSION
    return snapshot
end

local function RestoreTrackingManifest(previousManifest)
    local key = TrackingManifestKey()
    local cleared, clearErr = ClearVerified(key)
    if not cleared then return false, clearErr end
    if type(previousManifest) ~= "table" then return true end
    local saved, saveErr = A:SaveData(key, previousManifest)
    if not saved then return false, saveErr end
    return true
end

local function SaveTrackingCommit(tracking)
    local previousManifest = nil
    local existing, existingErr = A:LoadData(TrackingManifestKey())
    if existingErr ~= nil then return false, "load tracking manifest failed: " .. tostring(existingErr) end
    if type(existing) == "table" then
        local active = tostring(existing.active or "")
        if active == "a" or active == "b" then
            previousManifest = { version = tonumber(existing.version) or TRACKING_STORAGE_VERSION, active = active }
        end
    end

    local nextBank = previousManifest ~= nil and (previousManifest.active == "a" and "b" or "a") or "a"
    local snapshot = CopyTrackingForPersistence(tracking)

    -- Stage all current-version partitions into the inactive bank. The manifest is not
    -- switched until every partition can be read back byte-for-byte.
    for _, scope in ipairs(TRACKING_SCOPES) do
        for _, effectType in ipairs(TRACKING_EFFECTS) do
            local partitions = SplitBucket(snapshot[scope][effectType])
            for part = 1, TRACKING_PARTITIONS do
                local key = TrackingShardKey(nextBank, scope, effectType, part, TRACKING_STORAGE_VERSION)
                local cleared, clearErr = ClearVerified(key)
                if not cleared then return false, "clear tracking shard failed: " .. tostring(clearErr or key), previousManifest end
                local saved, saveErr = A:SaveData(key, partitions[part])
                if not saved then return false, "save tracking shard failed: " .. tostring(saveErr or key), previousManifest end
                local persisted, loadErr = A:LoadData(key)
                if loadErr ~= nil then return false, "verify tracking shard failed: " .. tostring(loadErr), previousManifest end
                if type(persisted) ~= "table" or not SameBucket(partitions[part], persisted) then
                    return false, "verify tracking shard mismatch: " .. tostring(scope) .. "/" .. tostring(effectType) .. "/p" .. tostring(part) .. " (" .. tostring(BucketCount(type(persisted) == "table" and persisted or nil)) .. "/" .. tostring(BucketCount(partitions[part])) .. ")", previousManifest
                end
            end
        end
    end

    local manifestKey = TrackingManifestKey()
    local cleared, clearErr = ClearVerified(manifestKey)
    if not cleared then return false, "clear tracking manifest failed: " .. tostring(clearErr or "unknown"), previousManifest end
    local manifest = { version = TRACKING_STORAGE_VERSION, active = nextBank }
    local saved, saveErr = A:SaveData(manifestKey, manifest)
    if not saved then
        RestoreTrackingManifest(previousManifest)
        return false, "save tracking manifest failed: " .. tostring(saveErr or "unknown"), previousManifest
    end
    local verified, verifyErr = ReadTrackingBank(nextBank, TRACKING_STORAGE_VERSION)
    if verifyErr ~= nil or type(verified) ~= "table" then
        RestoreTrackingManifest(previousManifest)
        return false, "tracking commit verify failed: " .. tostring(verifyErr or "empty"), previousManifest
    end
    return true, nil, previousManifest
end

local function RestoreAuraManifest(previousManifest)
    local key = AuraManifestKey()
    local cleared, clearErr = ClearVerified(key)
    if not cleared then return false, clearErr end
    if type(previousManifest) ~= "table" then return true end
    local saved, saveErr = A:SaveData(key, previousManifest)
    if not saved then return false, saveErr end
    return true
end

local function SaveAuraCommit(auraLibrary)
    local previousManifest = nil
    local existing, existingErr = A:LoadData(AuraManifestKey())
    if existingErr ~= nil then return false, "load aura manifest failed: " .. tostring(existingErr) end
    if type(existing) == "table" then
        local active = tostring(existing.active or "")
        if active == "a" or active == "b" then
            previousManifest = { version = tonumber(existing.version) or AURA_STORAGE_VERSION, active = active }
        end
    end

    local nextBank = previousManifest ~= nil and (previousManifest.active == "a" and "b" or "a") or "a"
    local partitions = SplitAuraLibrary(CopyAuraLibrary(auraLibrary))
    for part = 1, AURA_PARTITIONS do
        local key = AuraShardKey(nextBank, part)
        local cleared, clearErr = ClearVerified(key)
        if not cleared then return false, "clear aura shard failed: " .. tostring(clearErr or key), previousManifest end
        local saved, saveErr = A:SaveData(key, partitions[part])
        if not saved then return false, "save aura shard failed: " .. tostring(saveErr or key), previousManifest end
        local persisted, loadErr = A:LoadData(key)
        if loadErr ~= nil then return false, "verify aura shard failed: " .. tostring(loadErr), previousManifest end
        if type(persisted) ~= "table" or not SameAuraBucket(partitions[part], persisted) then
            return false, "verify aura shard mismatch: p" .. tostring(part) .. " (" .. tostring(BucketCount(type(persisted) == "table" and persisted or nil)) .. "/" .. tostring(BucketCount(partitions[part])) .. ")", previousManifest
        end
    end

    local manifestKey = AuraManifestKey()
    local cleared, clearErr = ClearVerified(manifestKey)
    if not cleared then return false, "clear aura manifest failed: " .. tostring(clearErr or "unknown"), previousManifest end
    local manifest = { version = AURA_STORAGE_VERSION, active = nextBank }
    local saved, saveErr = A:SaveData(manifestKey, manifest)
    if not saved then
        RestoreAuraManifest(previousManifest)
        return false, "save aura manifest failed: " .. tostring(saveErr or "unknown"), previousManifest
    end
    local verified, verifyErr = ReadAuraBank(nextBank, AURA_STORAGE_VERSION)
    if verifyErr ~= nil or type(verified) ~= "table" or AuraLibraryCount(verified) ~= AuraLibraryCount(auraLibrary) then
        RestoreAuraManifest(previousManifest)
        return false, "aura commit verify failed: " .. tostring(verifyErr or "count mismatch"), previousManifest
    end
    return true, nil, previousManifest
end

local function PreservePreviousRevision()
    local previous, loadErr = A:LoadData(P.SaveKey)
    if type(previous) ~= "table" then
        -- No previous committed revision means there is nothing to protect. A
        -- load error is not treated as "empty" because clearing the primary in
        -- that state could destroy data we simply failed to read.
        if loadErr ~= nil then return false, "load previous failed: " .. tostring(loadErr) end
        return true
    end
    local canWrite, clearErr = ClearVerified(P.BackupSaveKey)
    if not canWrite then return false, "clear backup failed: " .. tostring(clearErr or "unknown") end
    local saved, saveErr = A:SaveData(P.BackupSaveKey, previous)
    if not saved then return false, "save backup failed: " .. tostring(saveErr or "unknown") end
    return true
end

function S:Save(force)
    if self.writeFenceReason ~= nil then
        if self.writeFenceWarned ~= true then
            self.writeFenceWarned = true
            P.SafeChat("BUFF 配置处于写保护，本次会话不会覆盖原保存：" .. tostring(self.writeFenceReason))
        end
        return false, "storage write protected: " .. tostring(self.writeFenceReason)
    end
    if self.settings == nil then return false, "settings unavailable" end
    if force ~= true and self.dirty ~= true then return true end
    self.settings.schemaVersion = P.SchemaVersion

    local committedAura, previousAuraManifest = false, nil
    if self.auraDirty == true or self.auraSharded ~= true then
        local auraOk, auraErr, priorAura = SaveAuraCommit(self.settings.auraLibrary)
        if not auraOk then return false, auraErr end
        committedAura, previousAuraManifest = true, priorAura
        self.auraSharded = true
    end

    local committedTracking, previousManifest = false, nil
    if self.trackingDirty == true or self.trackingSharded ~= true then
        local trackingOk, trackingErr, prior = SaveTrackingCommit(self.settings.tracking)
        if not trackingOk then
            if committedAura then RestoreAuraManifest(previousAuraManifest); self.auraSharded = previousAuraManifest ~= nil end
            return false, trackingErr
        end
        committedTracking, previousManifest = true, prior
        self.trackingSharded = true
    end

    -- Commit fence: never clear the current primary revision unless the
    -- previous committed value is safely preserved first. Large Aura/Hidden
    -- authorities are excluded from this primary payload and have their own
    -- verified double-bank commits above.
    local protected, protectErr = PreservePreviousRevision()
    if not protected then
        if committedTracking then RestoreTrackingManifest(previousManifest); self.trackingSharded = previousManifest ~= nil end
        if committedAura then RestoreAuraManifest(previousAuraManifest); self.auraSharded = previousAuraManifest ~= nil end
        return false, protectErr
    end
    local cleared, clearErr = ClearVerified(P.SaveKey)
    if not cleared then
        if committedTracking then RestoreTrackingManifest(previousManifest); self.trackingSharded = previousManifest ~= nil end
        if committedAura then RestoreAuraManifest(previousAuraManifest); self.auraSharded = previousAuraManifest ~= nil end
        return false, "clear failed: " .. tostring(clearErr or "unknown")
    end
    local saved, saveErr = A:SaveData(P.SaveKey, BuildPrimarySnapshot(self.settings))
    if not saved then
        if committedTracking then RestoreTrackingManifest(previousManifest); self.trackingSharded = previousManifest ~= nil end
        if committedAura then RestoreAuraManifest(previousAuraManifest); self.auraSharded = previousAuraManifest ~= nil end
        return false, saveErr
    end
    self.dirty, self.trackingDirty, self.auraDirty = false, false, false
    return true
end

function S:UpdatePosition(bucketName, x, y)
    local bucket = self:Get()[bucketName]
    if type(bucket) ~= "table" then return false, "bucket unavailable" end
    local oldX, oldY, oldDirty = bucket.x, bucket.y, self.dirty
    bucket.x = math.max(0, math.floor((tonumber(x) or 0) + 0.5))
    bucket.y = math.max(0, math.floor((tonumber(y) or 0) + 0.5))
    self:MarkDirty()
    local ok, err = self:Save(true)
    if not ok then
        bucket.x, bucket.y, self.dirty = oldX, oldY, oldDirty
        return false, err
    end
    return true
end

function S:ResetPlateOffset(scope)
    local cfg, defaults = self:Get()[scope], PlateDefaults(scope)
    if type(cfg) ~= "table" then return false, "scope unavailable" end
    local oldX, oldY, oldAnchor, oldDirty = cfg.offsetX, cfg.offsetY, cfg.anchorMode, self.dirty
    cfg.offsetX, cfg.offsetY, cfg.anchorMode = defaults.offsetX, defaults.offsetY, defaults.anchorMode
    self:MarkDirty()
    local ok, err = self:Save(true)
    if not ok then
        cfg.offsetX, cfg.offsetY, cfg.anchorMode, self.dirty = oldX, oldY, oldAnchor, oldDirty
        return false, err
    end
    return true
end

function S:GetEffectLayout(scope, effectType)
    local cfg = self:Get()[scope]
    return type(cfg) == "table" and type(cfg.effects) == "table" and cfg.effects[effectType] or nil
end

function S:ResetEffectLayout(scope, effectType)
    local layout = self:GetEffectLayout(scope, effectType)
    if type(layout) ~= "table" then return false, "layout unavailable" end
    local defaults = EffectDefaults(effectType)
    local old, oldDirty = {}, self.dirty
    for key, value in pairs(layout) do
        old[key] = type(value) == "table" and CopyColor(value) or value
    end
    for key, value in pairs(defaults) do
        layout[key] = type(value) == "table" and CopyColor(value) or value
    end
    self:MarkDirty()
    local ok, err = self:Save(true)
    if not ok then
        for key in pairs(layout) do layout[key] = nil end
        for key, value in pairs(old) do layout[key] = type(value) == "table" and CopyColor(value) or value end
        self.dirty = oldDirty
        return false, err
    end
    return true
end

function S:GetEffectLimit(scope, effectType)
    local cfg, layout = self:Get()[scope], self:GetEffectLayout(scope, effectType)
    if type(cfg) ~= "table" or type(layout) ~= "table" then return 0 end
    local size = tonumber(layout.iconSize) or 24
    local gap = tonumber(layout.gap) or 2
    local maxCount = math.max(0, math.min(12, math.floor(tonumber(layout.maxCount) or 0)))
    if layout.direction == "UP" or layout.direction == "DOWN" then return maxCount end
    -- Horizontal effect lanes wrap to additional rows. Width therefore limits
    -- the number of icons PER ROW, not the total effect count.
    local fit = math.floor(math.max(0, (tonumber(cfg.width) or 250) - 4) / math.max(1, size + gap))
    local columns = math.max(1, math.min(12, math.floor(tonumber(layout.columns) or 6)))
    if math.min(fit, columns) <= 0 then return 0 end
    return maxCount
end

local function RebuildAuraProxyId(settings, id)
    id = tostring(id or "")
    if id == "" then return end
    for _, lane in ipairs(AURA_LANES) do
        if type(settings.tracking[lane.scope]) == "table" and type(settings.tracking[lane.scope][lane.effect]) == "table" then
            settings.tracking[lane.scope][lane.effect][id] = nil
        end
    end
    local aura = type(settings.auraLibrary) == "table" and settings.auraLibrary[id] or nil
    if type(aura) ~= "table" then return end
    aura = CopyAuraEntry(aura)
    settings.auraLibrary[id] = aura
    for _, lane in ipairs(AURA_LANES) do
        if MaskHas(aura.mask, lane.bit) then settings.tracking[lane.scope][lane.effect][id] = AuraLaneEntry(aura, lane.bit) end
    end
end

local function RebuildAllAuraProxies(settings)
    settings.tracking = BuildEffectiveTracking(settings.tracking, settings.auraLibrary)
end

local function MergeEntryMetadata(base, incoming)
    base, incoming = CopyEntry(base), CopyEntry(incoming)
    local baseName, incomingName = tostring(base.name or ""), tostring(incoming.name or "")
    if (baseName == "" or baseName:find("^手动 ID ")) and incomingName ~= "" then base.name = incomingName end
    if tostring(base.iconPath or "") == "" and tostring(incoming.iconPath or "") ~= "" then base.iconPath = incoming.iconPath end
    if tostring(base.category or "") == "" and tostring(incoming.category or "") ~= "" then base.category = incoming.category end
    return base
end

function S:GetAuraLibrary() return self:Get().auraLibrary or {} end
function S:AuraCount() return AuraLibraryCount(self:GetAuraLibrary()) end
function S:GetAuraEntry(id) return self:GetAuraLibrary()[tostring(id or "")] end
function S:GetAuraMask(id)
    local entry = self:GetAuraEntry(id)
    return type(entry) == "table" and math.max(0, math.min(15, math.floor(tonumber(entry.mask or entry.m) or 0))) or 0
end
function S:AuraLaneBit(scope, effectType) return AuraLaneBit(scope, effectType) end
function S:AuraMaskHas(mask, bit) return MaskHas(mask, bit) end

function S:GetAuraSyncMask(scope, effectType)
    local cfg = self:Get().auraSync or {}
    if tostring(cfg.mode or "same") ~= "all" then
        if effectType=="buff" then return 1+4 end
        if effectType=="debuff" then return 2+8 end
    end
    local mask = 0
    for _, lane in ipairs(AURA_LANES) do if cfg[lane.syncKey] ~= false then mask = MaskAdd(mask, lane.bit) end end
    return mask
end

function S:GetAuraSyncMode()
    local cfg=self:Get().auraSync or {};return tostring(cfg.mode or "same")=="all" and "all" or "same"
end

function S:SetAuraSyncMode(mode)
    local cfg=self:Get().auraSync;if type(cfg)~="table" then self:Get().auraSync={};cfg=self:Get().auraSync end
    mode=tostring(mode)=="all" and "all" or "same"
    local previous,previousDirty=cfg.mode,self.dirty;cfg.mode=mode;self:MarkDirty()
    local ok,err=self:Save(true);if not ok then cfg.mode,self.dirty=previous,previousDirty;return false,err end
    return true
end

function S:IsAuraSyncEnabled()
    local cfg = self:Get().auraSync
    return type(cfg) == "table" and cfg.enabled == true
end

function S:SetAuraSyncEnabled(enabled)
    local cfg = self:Get().auraSync
    if type(cfg) ~= "table" then self:Get().auraSync = {}; cfg = self:Get().auraSync end
    local previous, previousDirty = cfg.enabled, self.dirty
    cfg.enabled = enabled == true
    self:MarkDirty()
    local ok, err = self:Save(true)
    if not ok then cfg.enabled, self.dirty = previous, previousDirty; return false, err end
    return true
end

function S:SetAuraSyncLane(scope, effectType, enabled)
    local bit = AuraLaneBit(scope, effectType)
    if bit == nil then return false, "同步范围无效" end
    local syncKey = nil
    for _, lane in ipairs(AURA_LANES) do if lane.bit == bit then syncKey = lane.syncKey; break end end
    if syncKey == nil then return false, "同步范围无效" end
    local cfg = self:Get().auraSync
    local previous, previousDirty = cfg[syncKey], self.dirty
    cfg[syncKey] = enabled == true
    self:MarkDirty()
    local ok, err = self:Save(true)
    if not ok then cfg[syncKey], self.dirty = previous, previousDirty; return false, err end
    return true
end

function S:AddAuraMasked(id, entry, mask)
    local key = tostring(id or "")
    if not key:match("^%d+$") then return false, "ID 必须是数字" end
    mask = math.max(0, math.min(15, math.floor(tonumber(mask) or 0)))
    if mask <= 0 then return false, "同步范围为空" end
    local settings = self:Get()
    local previous = settings.auraLibrary[key] ~= nil and CopyAuraEntry(settings.auraLibrary[key]) or nil
    local previousDirty, previousAuraDirty = self.dirty, self.auraDirty
    local incoming = CopyEntry(entry)
    local aura = previous ~= nil and CopyAuraEntry(previous) or { mask = 0, base = incoming, overrides = {} }
    aura.base = MergeEntryMetadata(aura.base, incoming)
    for _, lane in ipairs(AURA_LANES) do if MaskHas(mask, lane.bit) then aura.mask = MaskAdd(aura.mask, lane.bit) end end
    settings.auraLibrary[key] = aura
    RebuildAuraProxyId(settings, key)
    self:MarkAuraDirty()
    local ok, err = self:Save(true)
    if not ok then
        settings.auraLibrary[key] = previous
        RebuildAuraProxyId(settings, key)
        self.dirty, self.auraDirty = previousDirty, previousAuraDirty
        return false, err
    end
    return true
end

function S:SetAuraMask(id, mask)
    local key = tostring(id or "")
    local current = self:GetAuraEntry(key)
    if type(current) ~= "table" then return false, "状态 ID 不存在" end
    mask = math.max(0, math.min(15, math.floor(tonumber(mask) or 0)))
    local settings = self:Get()
    local previous, previousDirty, previousAuraDirty = CopyAuraEntry(current), self.dirty, self.auraDirty
    if mask <= 0 then
        settings.auraLibrary[key] = nil
    else
        local aura = CopyAuraEntry(current); aura.mask = mask
        for bitKey in pairs(aura.overrides) do if not MaskHas(mask, tonumber(bitKey) or 0) then aura.overrides[bitKey] = nil end end
        settings.auraLibrary[key] = aura
    end
    RebuildAuraProxyId(settings, key)
    self:MarkAuraDirty()
    local ok, err = self:Save(true)
    if not ok then
        settings.auraLibrary[key] = previous; RebuildAuraProxyId(settings, key)
        self.dirty, self.auraDirty = previousDirty, previousAuraDirty
        return false, err
    end
    return true
end

-- Replace/merge a compact ID->ScopeMask set. Used by the chunked AuraLibrary
-- transfer protocol; no names/icons are transmitted, so existing local metadata
-- is preserved and new rows are resolved lazily from the live client.
function S:ImportAuraMasks(maskMap, policy)
    if type(maskMap) ~= "table" then return false, "状态库为空" end
    policy = policy == "replace" and "replace" or "merge"
    local settings = self:Get()
    local previousLib = CopyAuraLibrary(settings.auraLibrary)
    local previousTracking = CopyTracking(settings.tracking)
    local previousDirty, previousAuraDirty = self.dirty, self.auraDirty
    local nextLib = policy == "replace" and {} or CopyAuraLibrary(settings.auraLibrary)
    for id, mask in pairs(maskMap) do
        local key = tostring(id or "")
        local numericMask = math.max(0, math.min(15, math.floor(tonumber(mask) or 0)))
        if key:match("^%d+$") and numericMask > 0 then
            local existing = nextLib[key]
            if type(existing) == "table" then
                local aura = CopyAuraEntry(existing)
                for _, lane in ipairs(AURA_LANES) do if MaskHas(numericMask, lane.bit) then aura.mask = MaskAdd(aura.mask, lane.bit) end end
                nextLib[key] = aura
            else
                local old = previousLib[key]
                local base = type(old) == "table" and CopyAuraEntry(old).base or CopyEntry({ name = "", iconPath = "", category = "" })
                nextLib[key] = { mask = numericMask, base = base, overrides = {} }
            end
        end
    end
    settings.auraLibrary = nextLib
    RebuildAllAuraProxies(settings)
    self:MarkAuraDirty()
    local ok, err = self:Save(true)
    if not ok then
        settings.auraLibrary = previousLib; settings.tracking = previousTracking
        self.dirty, self.auraDirty = previousDirty, previousAuraDirty
        return false, err
    end
    return true, nil, { before = AuraLibraryCount(previousLib), after = AuraLibraryCount(nextLib) }
end

-- Adopt a legacy/full tracking table into the new model without saving yet.
-- Manager import paths use this so Aura + Hidden + layout can still share one
-- outer commit/rollback fence.
function S:AdoptTracking(tracking)
    if type(tracking) ~= "table" then return false, "追踪数据无效" end
    local settings = self:Get()
    settings.auraLibrary = BuildAuraLibraryFromTracking(tracking)
    settings.tracking = BuildEffectiveTracking(tracking, settings.auraLibrary)
    self:MarkAuraDirty()
    self:MarkTrackingDirty()
    return true
end

function S:GetTracked(scope, effectType)
    local tracking = self:Get().tracking
    if type(tracking[scope]) ~= "table" or type(tracking[scope][effectType]) ~= "table" then return {} end
    return tracking[scope][effectType]
end

function S:TrackedCount(scope, effectType)
    local count = 0
    for _ in pairs(self:GetTracked(scope, effectType)) do count = count + 1 end
    return count
end

function S:IsTracked(scope, effectType, id)
    local entry = self:GetTracked(scope, effectType)[tostring(id or "")]
    return type(entry) == "table" and entry.enabled ~= false
end

function S:GetTrackedEntry(scope, effectType, id)
    return self:GetTracked(scope, effectType)[tostring(id or "")]
end

function S:ActiveTrackedCount(scope, effectType)
    local count = 0
    for _, entry in pairs(self:GetTracked(scope, effectType)) do
        if type(entry) == "table" and entry.enabled ~= false then count = count + 1 end
    end
    return count
end

local function MutableTrackedBucket(self, scope, effectType)
    local tracking = self:Get().tracking
    if type(tracking) ~= "table" or type(tracking[scope]) ~= "table" or type(tracking[scope][effectType]) ~= "table" then return nil end
    return tracking[scope][effectType]
end

local function SnapshotTrackedBucket(bucket)
    local snapshot = {}
    for key, entry in pairs(bucket or {}) do snapshot[key] = CopyEntry(entry) end
    return snapshot
end

local function RestoreTrackedBucket(bucket, snapshot)
    for key in pairs(bucket or {}) do bucket[key] = nil end
    for key, entry in pairs(snapshot or {}) do bucket[key] = CopyEntry(entry) end
end

function S:AddTracked(scope, effectType, id, entry)
    local auraBit = AuraLaneBit(scope, effectType)
    if auraBit ~= nil then return self:AddAuraMasked(id, entry, auraBit) end
    local key = tostring(id or "")
    if not key:match("^%d+$") then return false, "ID 必须是数字" end
    local bucket = MutableTrackedBucket(self, scope, effectType)
    if bucket == nil then return false, "分类不可用" end
    local previous, previousDirty, previousTrackingDirty = bucket[key] ~= nil and CopyEntry(bucket[key]) or nil, self.dirty, self.trackingDirty
    bucket[key] = CopyEntry(entry)
    self:MarkTrackingDirty()
    local ok, err = self:Save(true)
    if not ok then
        bucket[key] = previous
        self.dirty, self.trackingDirty = previousDirty, previousTrackingDirty
        return false, err
    end
    return true
end

function S:UpdateTracked(scope, effectType, id, changes, clearFields)
    local auraBit = AuraLaneBit(scope, effectType)
    if auraBit ~= nil then
        local key = tostring(id or "")
        local settings = self:Get()
        local currentAura = settings.auraLibrary[key]
        if type(currentAura) ~= "table" or not MaskHas(currentAura.mask, auraBit) then return false, "追踪项不存在" end
        local previousAura = CopyAuraEntry(currentAura)
        local previousDirty, previousAuraDirty = self.dirty, self.auraDirty
        local merged = AuraLaneEntry(currentAura, auraBit)
        if type(changes) == "table" then for field, value in pairs(changes) do merged[field] = value end end
        if type(clearFields) == "table" then for _, field in ipairs(clearFields) do if type(field) == "string" then merged[field] = nil end end end
        merged = CopyEntry(merged)
        local aura = CopyAuraEntry(currentAura)
        if SameRuleEntry(merged, aura.base) then aura.overrides[tostring(auraBit)] = nil else aura.overrides[tostring(auraBit)] = merged end
        settings.auraLibrary[key] = aura
        RebuildAuraProxyId(settings, key)
        self:MarkAuraDirty()
        local ok, err = self:Save(true)
        if not ok then
            settings.auraLibrary[key] = previousAura; RebuildAuraProxyId(settings, key)
            self.dirty, self.auraDirty = previousDirty, previousAuraDirty
            return false, err
        end
        return true
    end

    local bucket = MutableTrackedBucket(self, scope, effectType)
    local key = tostring(id or "")
    if bucket == nil or type(bucket[key]) ~= "table" then return false, "追踪项不存在" end
    local previous, previousDirty, previousTrackingDirty = CopyEntry(bucket[key]), self.dirty, self.trackingDirty
    local merged = CopyEntry(bucket[key])
    if type(changes) == "table" then
        for field, value in pairs(changes) do merged[field] = value end
    end
    if type(clearFields) == "table" then
        for _, field in ipairs(clearFields) do if type(field)=="string" then merged[field]=nil end end
    end
    bucket[key] = CopyEntry(merged)
    self:MarkTrackingDirty()
    local ok, err = self:Save(true)
    if not ok then
        bucket[key] = previous
        self.dirty, self.trackingDirty = previousDirty, previousTrackingDirty
        return false, err
    end
    return true
end

function S:GetColorPresets() return self:Get().colorPresets or {} end

function S:AddColorPreset(name, color)
    name = tostring(name or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if name == "" then return false, "请输入预设名称" end
    local list = self:Get().colorPresets
    if type(list) ~= "table" then self:Get().colorPresets = {}; list = self:Get().colorPresets end
    local old, oldDirty = {}, self.dirty
    for i, preset in ipairs(list) do old[i] = { name = tostring(preset.name or ""), color = CopyColor(preset.color) } end
    local replaced = false
    for _, preset in ipairs(list) do
        if tostring(preset.name or "") == name then preset.color = CopyColor(color); replaced = true; break end
    end
    if not replaced then
        if #list >= 24 then return false, "自定义颜色预设最多 24 个" end
        list[#list + 1] = { name = name:sub(1, 24), color = CopyColor(color) }
    end
    self:MarkDirty()
    local ok, err = self:Save(true)
    if not ok then self:Get().colorPresets = old; self.dirty = oldDirty; return false, err end
    return true
end

function S:RemoveColorPreset(name)
    name = tostring(name or "")
    local list = self:Get().colorPresets or {}
    local old, oldDirty = {}, self.dirty
    for i, preset in ipairs(list) do old[i] = { name = tostring(preset.name or ""), color = CopyColor(preset.color) } end
    local removed = false
    for i = #list, 1, -1 do if tostring(list[i].name or "") == name then table.remove(list, i); removed = true; break end end
    if not removed then return false, "预设不存在" end
    self:MarkDirty()
    local ok, err = self:Save(true)
    if not ok then self:Get().colorPresets = old; self.dirty = oldDirty; return false, err end
    return true
end

function S:RemoveTracked(scope, effectType, id)
    local auraBit = AuraLaneBit(scope, effectType)
    if auraBit ~= nil then
        local key = tostring(id or "")
        local mask = self:GetAuraMask(key)
        if mask <= 0 or not MaskHas(mask, auraBit) then return true end
        return self:SetAuraMask(key, MaskRemove(mask, auraBit))
    end
    local bucket = MutableTrackedBucket(self, scope, effectType)
    if bucket == nil then return false, "分类不可用" end
    local key, previousDirty, previousTrackingDirty = tostring(id or ""), self.dirty, self.trackingDirty
    local previous = bucket[key] ~= nil and CopyEntry(bucket[key]) or nil
    bucket[key] = nil
    self:MarkTrackingDirty()
    local ok, err = self:Save(true)
    if not ok then
        bucket[key] = previous
        self.dirty, self.trackingDirty = previousDirty, previousTrackingDirty
        return false, err
    end
    return true
end

function S:ReplaceTracked(scope, effectType, entries)
    local auraBit = AuraLaneBit(scope, effectType)
    if auraBit ~= nil then
        local settings = self:Get()
        local previousLib, previousTracking = CopyAuraLibrary(settings.auraLibrary), CopyTracking(settings.tracking)
        local previousDirty, previousAuraDirty = self.dirty, self.auraDirty
        local effective = CopyTracking(settings.tracking)
        effective[scope][effectType] = {}
        if type(entries) == "table" then
            for id, entry in pairs(entries) do
                local key = tostring(id or "")
                if key:match("^%d+$") then effective[scope][effectType][key] = CopyEntry(entry) end
            end
        end
        settings.auraLibrary = BuildAuraLibraryFromTracking(effective)
        settings.tracking = BuildEffectiveTracking(effective, settings.auraLibrary)
        self:MarkAuraDirty()
        local ok, err = self:Save(true)
        if not ok then
            settings.auraLibrary, settings.tracking = previousLib, previousTracking
            self.dirty, self.auraDirty = previousDirty, previousAuraDirty
            return false, err
        end
        return true
    end

    local bucket = MutableTrackedBucket(self, scope, effectType)
    if bucket == nil then return false, "分类不可用" end
    local snapshot, previousDirty, previousTrackingDirty = SnapshotTrackedBucket(bucket), self.dirty, self.trackingDirty
    for key in pairs(bucket) do bucket[key] = nil end
    if type(entries) == "table" then
        for id, entry in pairs(entries) do
            local key = tostring(id or "")
            if key:match("^%d+$") then bucket[key] = CopyEntry(entry) end
        end
    end
    self:MarkTrackingDirty()
    local ok, err = self:Save(true)
    if not ok then
        RestoreTrackedBucket(bucket, snapshot)
        self.dirty, self.trackingDirty = previousDirty, previousTrackingDirty
        return false, err
    end
    return true
end

function S:ClearAllTracked(scope)
    -- 清空「全部 HUD」（自身 + 目标）下所有已追踪的 Buff/Debuff/Hidden。
    -- 不再只清当前 scope：否则导入时合并会保留另一个 HUD 里的旧 ID，造成"清了还进旧的"。
    -- 复用 ReplaceTracked(scope, effectType, {}) 走既有的 mask/桶 两套存储路径，
    -- 并各自触发一次保存（危险操作，宁可慢也要保证落盘）。
    local total = 0
    for _, s in ipairs({ "target", "player" }) do
        for _, effectType in ipairs({ "buff", "debuff", "hidden" }) do
            local n = self:TrackedCount(s, effectType)
            if n > 0 then
                local ok, err = self:ReplaceTracked(s, effectType, {})
                if not ok then return nil, err end
                total = total + n
            end
        end
    end
    return total
end

function S:ResetTargetOffset() return self:ResetPlateOffset("target") end
