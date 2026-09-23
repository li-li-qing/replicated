------------------------------------------------------------------------
-- Replicated Suite - Activity Personal Progress Selection Store Tests
--
-- Development-only offline suite; not loaded by toc.g. The Store owns only the
-- player's selected MAIN objectives. Quest completion truth remains QuestProgressV3.
------------------------------------------------------------------------
local passed, failed = 0, 0
local function Check(name, fn)
    local ok, err = pcall(fn)
    if ok then passed = passed + 1; print("PASS activity_progress_selection " .. name)
    else failed = failed + 1; print("FAIL activity_progress_selection " .. name .. ": " .. tostring(err)) end
end
local function Assert(value, message) if value ~= true then error(message or "assertion failed", 2) end end
local function Equal(actual, expected, message)
    if actual ~= expected then error((message or "values differ") .. ": expected=" .. tostring(expected) .. " actual=" .. tostring(actual), 2) end
end
local function Count(set)
    local n = 0; for _, enabled in pairs(type(set) == "table" and set or {}) do if enabled == true then n = n + 1 end end; return n
end
local function Copy(value, seen)
    if type(value) ~= "table" then return value end
    seen = seen or {}; if seen[value] ~= nil then return seen[value] end
    local out = {}; seen[value] = out
    for key, item in pairs(value) do out[Copy(key, seen)] = Copy(item, seen) end
    return out
end

local stores, loaded, dirty = {}, {}, {}
local publications = {}
ReplicatedSuite = {
    Features = {},
    Persistence = {
        Scope = { Account = "account" }, Lifetime = { Permanent = "permanent" }, V3KeyPrefix = "test:",
    },
    RSUI = { FloatingSurface = { NormalizeState = function(_, value, policy)
        value, policy = type(value) == "table" and value or {}, type(policy) == "table" and policy or {}
        return {
            width = tonumber(value.width) or tonumber(policy.defaultWidth) or 430,
            height = tonumber(value.height) or tonumber(policy.defaultHeight) or 276,
            minimized = value.minimized == true, locked = value.locked == true,
            overallOpacity = tonumber(value.overallOpacity) or tonumber(policy.defaultOverallOpacity) or 0.94,
            backgroundOpacity = tonumber(value.backgroundOpacity) or tonumber(policy.defaultBackgroundOpacity) or 1,
            textOpacity = tonumber(value.textOpacity) or tonumber(policy.defaultTextOpacity) or 1,
            userMoved = value.userMoved == true,
        }
    end } },
    Events = { Publish = function(_, name, ...)
        publications[#publications + 1] = { name = name, args = { ... } }; return true
    end },
}
local P = ReplicatedSuite.Persistence
function P:GetStore(id) return stores[id] end
function P:RegisterV3Store(spec) stores[spec.id] = spec; return spec end
function P:IsStoreLoaded(id) return loaded[id] == true end
function P:LoadStore(id)
    if stores[id] == nil then return false, nil, "unknown store" end
    loaded[id] = true; return "empty", nil, nil
end
function P:MarkDirty(id) dirty[id] = (dirty[id] or 0) + 1; return true end
function P:MutateStore(id, mutate, options)
    local store = stores[id]; if store == nil then return false, "unknown store" end
    local before = Copy(store.get())
    local ok, result, err = pcall(mutate, store)
    if ok ~= true or result == false then
        store.apply(before); return false, ok == true and (err or "mutation rejected") or result
    end
    return self:MarkDirty(id, options and options.delayMs, options and options.reason)
end
function P:FingerprintCanonicalValue() return "TEST" end
DeepCopy = Copy

dofile("features/life/activities/rs_activity_store.lua")
local F = ReplicatedSuite.Features.Activities
local detailStore = stores["v3.activities.detail_tracking"]
local eligible = { "main:101", "main:102", "main:103" }

Check("registers schema2 store and keeps main activities store independent", function()
    Assert(type(stores["v3.activities"]) == "table", "main activities store missing")
    Assert(type(detailStore) == "table", "progress selection store missing")
    Equal(detailStore.schemaVersion, 2, "progress selection schema")
    Equal(detailStore.legacySchemaVersion, 1, "legacy semantic boundary")
    Equal(F.DetailTrackingContractVersion, 3, "tracking contract")
    Equal(F.ProgressSelectionContractVersion, 2, "progress-selection contract")
end)

Check("unconfigured activity defaults every canonical main objective selected", function()
    F.DetailTrackingState = { groups = {} }; F.DetailTrackingStoreLoaded = true; loaded[F.DetailTrackingStoreId] = true
    local selected, configured, available, err = F:GetDetailProgressSelection("crimson", eligible)
    Assert(err == nil and available == true, "selection unavailable")
    Assert(configured == false, "default-all must remain implicit")
    Equal(Count(selected), 3, "default denominator")
    Assert(selected["main:101"] and selected["main:102"] and selected["main:103"], "default-all set incomplete")
end)

Check("deselect materializes subset and reselect-all canonicalizes back to implicit default", function()
    F.DetailTrackingState = { groups = {} }; F.DetailTrackingStoreLoaded = true; loaded[F.DetailTrackingStoreId] = true
    local ok, err = F:SetDetailProgressTaskSelected("crimson", "main:101", false, eligible, "test")
    Assert(ok == true, err)
    local selected, configured = F:GetDetailProgressSelection("crimson", eligible)
    Assert(configured == true, "subset should be explicit")
    Equal(Count(selected), 2, "subset denominator")
    Assert(selected["main:101"] ~= true and selected["main:102"] and selected["main:103"], "wrong subset")
    Assert(type(F.DetailTrackingState.groups.crimson) == "table", "subset bucket missing")
    Equal(publications[#publications].name, "v3.activities.progress_selection", "selection event name")

    ok, err = F:SetDetailProgressTaskSelected("crimson", "main:101", true, eligible, "test")
    Assert(ok == true, err)
    Assert(F.DetailTrackingState.groups.crimson == nil, "full selection should canonicalize to implicit all")
    selected, configured = F:GetDetailProgressSelection("crimson", eligible)
    Equal(Count(selected), 3, "restored default denominator")
    Assert(configured == false, "restored all should be implicit")
end)

Check("related task can never enter personal denominator", function()
    local before = Copy(F.DetailTrackingState)
    local ok, err = F:SetDetailProgressTaskSelected("crimson", "related:500", true, eligible, "test")
    Assert(ok == false, "related task unexpectedly accepted")
    Assert(tostring(err):find("主进度", 1, true) ~= nil or tostring(err):find("身份", 1, true) ~= nil, "missing authority error")
    Equal(Count(F.DetailTrackingState.groups.crimson), Count(before.groups.crimson), "rejected related task changed store")
end)

Check("cannot deselect final remaining main objective", function()
    F.DetailTrackingState = { groups = {} }; F.DetailTrackingStoreLoaded = true; loaded[F.DetailTrackingStoreId] = true
    Assert(F:SetDetailProgressTaskSelected("crimson", "main:101", false, eligible, "test"))
    Assert(F:SetDetailProgressTaskSelected("crimson", "main:102", false, eligible, "test"))
    local selected = F:GetDetailProgressSelection("crimson", eligible)
    Equal(Count(selected), 1, "expected one remaining task")
    local ok, err = F:SetDetailProgressTaskSelected("crimson", "main:103", false, eligible, "test")
    Assert(ok == false, "final task should not be removable")
    Assert(tostring(err):find("至少保留 1", 1, true) ~= nil, "missing minimum-selection message")
    selected = F:GetDetailProgressSelection("crimson", eligible)
    Equal(Count(selected), 1, "rejected final removal mutated denominator")
end)

Check("schema1 bookmark semantics migrate to unconfigured default-all", function()
    local migrated = detailStore.migrate({ groups = { crimson = { ["main:101"] = true, ["related:500"] = true } } }, 1, 2)
    Assert(type(migrated) == "table" and type(migrated.groups) == "table", "migration result invalid")
    Assert(next(migrated.groups) == nil, "old bookmark subset must not become new denominator")
end)

Check("schema1 codec canonical is authenticated before schema2 migration", function()
    local previousFingerprint = P.FingerprintCanonicalValue
    P.FingerprintCanonicalValue = function(_, _, canonical)
        if type(canonical) == "table" and tonumber(canonical.codec) == 1 then return "1013634B" end
        if type(canonical) == "table" and tonumber(canonical.codec) == 2 then return "5CF32E2D" end
        return nil
    end
    local raw = {
        codec = 1, payload = { groups = {} },
        __rsmeta = { store = "v3.activities.detail_tracking", owner = "v3.activities.detail_tracking", schema = 1 },
    }
    local currentCanonical = detailStore.encode({ groups = {} })
    Equal(P:FingerprintCanonicalValue(detailStore, currentCanonical), "5CF32E2D", "current schema2 empty canonical evidence")
    local historicalCanonical, historicalDomain = detailStore.rebuildCanonicalForIntegrity(
        { groups = {} }, "1013634B", currentCanonical, raw)
    Assert(type(historicalCanonical) == "table", "schema1 historical candidate missing")
    Equal(historicalCanonical.codec, 1, "historical codec")
    Equal(P:FingerprintCanonicalValue(detailStore, historicalCanonical), "1013634B", "historical empty canonical evidence")
    Assert(type(historicalDomain) == "table" and type(historicalDomain.groups) == "table", "historical domain missing")
    local migrated = detailStore.migrate(historicalDomain, 1, 2)
    Assert(next(migrated.groups) == nil, "authenticated schema1 data must still migrate to implicit default-all")
    P.FingerprintCanonicalValue = previousFingerprint
end)

Check("schema1 recovery proves old related bookmarks but migration never imports them into denominator", function()
    local previousFingerprint = P.FingerprintCanonicalValue
    P.FingerprintCanonicalValue = function(_, _, canonical)
        if type(canonical) == "table" and tonumber(canonical.codec) == 1 then return "LEGACY_OK" end
        return "CURRENT"
    end
    local raw = {
        codec = 1,
        payload = { groups = { { key = "crimson", tokens = { "main:101", "related:500" } } } },
        __rsmeta = { store = "v3.activities.detail_tracking", owner = "v3.activities.detail_tracking", schema = 1 },
    }
    local historicalCanonical, historicalDomain = detailStore.rebuildCanonicalForIntegrity(
        { groups = { crimson = { ["main:101"] = true } } }, "LEGACY_OK", detailStore.encode({ groups = {} }), raw)
    Assert(type(historicalCanonical) == "table" and historicalCanonical.codec == 1, "schema1 candidate rejected")
    Assert(historicalDomain.groups.crimson["main:101"] == true, "historical main token missing")
    Assert(historicalDomain.groups.crimson["related:500"] == true, "historical related token must survive old-hash proof")
    local migrated = detailStore.migrate(historicalDomain, 1, 2)
    Assert(next(migrated.groups) == nil, "legacy bookmark leaked into schema2 denominator")
    P.FingerprintCanonicalValue = previousFingerprint
end)

Check("codec writes deterministic main-only arrays and round-trips", function()
    F.DetailTrackingState = { groups = {
        zeta = { ["related:9"] = true, ["main:2"] = true, ["main:1"] = true },
        alpha = { ["main:8"] = true },
    } }
    local encoded = detailStore.encode(F.DetailTrackingState)
    Equal(encoded.codec, 2, "codec version")
    Equal(encoded.payload.groups[1].key, "alpha", "groups not sorted")
    Equal(encoded.payload.groups[2].key, "zeta", "groups not sorted")
    Equal(encoded.payload.groups[2].tokens[1], "main:1", "tokens not sorted")
    Equal(encoded.payload.groups[2].tokens[2], "main:2", "tokens not sorted")
    Equal(encoded.payload.groups[2].tokens[3], nil, "related token leaked into codec")
    local decoded, decodeErr = detailStore.decode(encoded)
    Assert(type(decoded) == "table", decodeErr)
    Assert(decoded.groups.alpha["main:8"] == true, "alpha round-trip failed")
    Assert(decoded.groups.zeta["main:1"] == true and decoded.groups.zeta["related:9"] ~= true, "main-only round-trip failed")
end)

Check("rejects objective catalogs above bounded per-activity limit", function()
    local tooMany = {}; for index = 1, 25 do tooMany[index] = "main:" .. tostring(index) end
    local ok, err = F:SetDetailProgressTaskSelected("crimson", "main:1", false, tooMany, "test")
    Assert(ok == false, "25-objective catalog should be rejected")
    Assert(tostring(err):find("上限", 1, true) ~= nil, "missing bounded-store error")
end)

print("ACTIVITY PROGRESS SELECTION STORE RESULT: " .. tostring(passed) .. " passed, " .. tostring(failed) .. " failed")
if failed > 0 then error("activity progress selection store tests failed", 0) end
