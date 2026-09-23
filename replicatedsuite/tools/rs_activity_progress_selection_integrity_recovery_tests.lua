------------------------------------------------------------------------
-- Replicated Suite - Activity Progress Selection Schema1 Integrity Recovery
--
-- Offline cold-start persistence test. It writes the exact published schema1
-- codec1 Store through the real Persistence v4 pipeline, then boots the current
-- schema2 Store and proves old-canonical authentication happens before migrate.
------------------------------------------------------------------------
local passed, failed = 0, 0
local function Test(name, fn)
    local ok, err = xpcall(fn, debug.traceback)
    if ok then passed = passed + 1; print("PASS activity_progress_integrity " .. name)
    else failed = failed + 1; print("FAIL activity_progress_integrity " .. name .. ": " .. tostring(err)) end
end
local function Copy(value, seen)
    if type(value) ~= "table" then return value end
    seen = seen or {}; if seen[value] ~= nil then return seen[value] end
    local out = {}; seen[value] = out
    for key, item in pairs(value) do out[Copy(key, seen)] = Copy(item, seen) end
    return out
end
local function FloatingNormalize(_, value, policy)
    value, policy = type(value) == "table" and value or {}, type(policy) == "table" and policy or {}
    return {
        width = tonumber(value.width) or tonumber(policy.defaultWidth) or 430,
        height = tonumber(value.height) or tonumber(policy.defaultHeight) or 276,
        minimized = value.minimized == true, locked = value.locked == true,
        overallOpacity = tonumber(value.overallOpacity) or tonumber(policy.defaultOverallOpacity) or 0.94,
        backgroundOpacity = tonumber(value.backgroundOpacity) or tonumber(policy.defaultBackgroundOpacity) or 1,
        textOpacity = tonumber(value.textOpacity) or tonumber(policy.defaultTextOpacity) or 1,
        fontScale = tonumber(value.fontScale) or tonumber(policy.defaultFontScale) or 1,
        userMoved = value.userMoved == true,
    }
end
local function Boot(disk)
    local io = { disk = disk or {}, reads = 0, writes = 0, clears = 0 }
    ADDON = {
        LoadData = function(_, key) io.reads = io.reads + 1; return Copy(io.disk[key]) end,
        SaveData = function(_, key, value) io.writes = io.writes + 1; io.disk[key] = Copy(value); return true end,
        ClearData = function() io.clears = io.clears + 1; error("test must not clear user saves") end,
    }
    ReplicatedSuite = {
        Features = {}, Services = {}, UI = {}, RSUI = { FloatingSurface = { NormalizeState = FloatingNormalize } },
        NowMs = function() return 1000 end,
        FeatureRuntime = { RegisterImplementation = function() return true end },
    }
    dofile("core/rs_utils.lua")
    dofile("core/rs_reuse.lua")
    dofile("core/rs_demand.lua")
    dofile("core/rs_api.lua")
    dofile("core/rs_api_capabilities.lua")
    dofile("core/rs_persistence.lua")
    return ReplicatedSuite, ReplicatedSuite.Persistence, io
end

local STORE_ID = "v3.activities.detail_tracking"
local function RegisterPublishedSchema1(P)
    local state = { groups = {} }
    local function NormalizeToken(value)
        local token = tostring(value or "")
        if token == "" or #token > 128 then return nil end
        return token
    end
    local function Normalize(value)
        value = type(value) == "table" and value or {}
        local source = type(value.groups) == "table" and value.groups or {}
        local groups, groupCount = {}, 0
        for rawKey, rawBucket in pairs(source) do
            local groupKey = tostring(rawKey or "")
            if groupKey ~= "" and #groupKey <= 96 and groupCount < 64 then
                local tokens, tokenCount = {}, 0
                for rawToken, enabled in pairs(type(rawBucket) == "table" and rawBucket or {}) do
                    local candidate = nil
                    if enabled == true then candidate = rawToken
                    elseif type(rawToken) == "number" and type(enabled) == "string" then candidate = enabled end
                    local token = NormalizeToken(candidate)
                    if token ~= nil and tokens[token] ~= true and tokenCount < 24 then
                        tokens[token] = true; tokenCount = tokenCount + 1
                    end
                end
                if tokenCount > 0 then groups[groupKey] = tokens; groupCount = groupCount + 1 end
            end
        end
        return { groups = groups }
    end
    local function Encode(value)
        local normalized, keys = Normalize(value), {}
        for key in pairs(normalized.groups) do keys[#keys + 1] = key end
        table.sort(keys)
        local rows = {}
        for _, key in ipairs(keys) do
            local tokens = {}; for token in pairs(normalized.groups[key]) do tokens[#tokens + 1] = token end
            table.sort(tokens); rows[#rows + 1] = { key = key, tokens = tokens }
        end
        return { codec = 1, payload = { groups = rows } }
    end
    local function Decode(raw)
        if type(raw) ~= "table" then return nil, "payload_required" end
        local payload = type(raw.payload) == "table" and raw.payload or raw
        local rows = type(payload.groups) == "table" and payload.groups or {}
        local domain = { groups = {} }
        if rows[1] ~= nil then
            for _, row in ipairs(rows) do
                if type(row) == "table" then
                    local key = tostring(row.key or "")
                    if key ~= "" and type(row.tokens) == "table" then domain.groups[key] = row.tokens end
                end
            end
        else domain.groups = rows end
        return Normalize(domain), nil
    end
    return assert(P:RegisterV3Store({
        id = STORE_ID, owner = "v3.activities.detail_tracking",
        scope = P.Scope.Account, lifetime = P.Lifetime.Permanent,
        schemaVersion = 1, legacySchemaVersion = 0,
        key = P.V3KeyPrefix .. "activities_detail_tracking",
        budget = { maxDepth = 6, maxNodes = 4096, maxStringBytes = 262144, maxEntriesPerTable = 256 },
        default = function() return Normalize(nil) end,
        get = function() return Normalize(state) end,
        apply = function(value) state = Normalize(value) end,
        encode = Encode, decode = Decode, migrate = function(value) return Normalize(value) end,
        allowIntegrityUpgrade = true,
    }))
end

Test("real schema1 empty save reproduces reported 1013634B stamp", function()
    local _, P, io = Boot()
    local store = RegisterPublishedSchema1(P)
    assert(P:LoadStore(STORE_ID) == "empty")
    local ok, err = P:SaveStore(STORE_ID, { force = true, durable = true })
    assert(ok, err)
    local key = assert(P:ResolveStoreKey(store))
    local raw = assert(P:DecodePhysicalEnvelope(io.disk[key]))
    assert(raw.__rsmeta.schema == 1 and raw.codec == 1, "schema1 fixture generation failed")
    assert(raw.__rsmeta.encodedFingerprint == "1013634B", "unexpected published schema1 fingerprint: " .. tostring(raw.__rsmeta.encodedFingerprint))
end)

Test("current schema2 authenticates schema1 before migration and removes write fence", function()
    local _, oldP, oldIo = Boot()
    local oldStore = RegisterPublishedSchema1(oldP)
    assert(oldP:LoadStore(STORE_ID) == "empty")
    assert(oldP:SaveStore(STORE_ID, { force = true, durable = true }))
    local disk = Copy(oldIo.disk)

    local S, P = Boot(disk)
    dofile("features/life/activities/rs_activity_store.lua")
    local store = assert(P:GetStore(STORE_ID))
    local loaded, _, err = P:LoadStore(STORE_ID)
    assert(loaded == true, err)
    assert(store.writeFenced ~= true, "healthy schema1 save stayed fenced")
    assert(tostring(store.lastHistoricalRecoveryProbe or ""):find("activity_progress_schema1/candidate", 1, true), "historical schema1 bridge did not run")
    assert(store.lastIntegrityStatus == "historical_canonical_recovery", "wrong integrity recovery status: " .. tostring(store.lastIntegrityStatus))
    assert(store.dirty == true and store.lastDirtyReason == "integrity_v4_upgrade", "recovered store must queue immediate current restamp")
    assert(next(S.Features.Activities.DetailTrackingState.groups) == nil, "schema1 bookmark semantics must migrate to implicit default-all")
end)

Test("restamped schema2 reloads strictly with codec2 fingerprint 5CF32E2D", function()
    local _, oldP, oldIo = Boot()
    local oldStore = RegisterPublishedSchema1(oldP)
    assert(oldP:LoadStore(STORE_ID) == "empty")
    assert(oldP:SaveStore(STORE_ID, { force = true, durable = true }))

    local S, P, io = Boot(Copy(oldIo.disk))
    dofile("features/life/activities/rs_activity_store.lua")
    local store = assert(P:GetStore(STORE_ID))
    assert(P:LoadStore(STORE_ID))
    local ok, err = P:SaveStore(STORE_ID, { force = true, durable = true })
    assert(ok, err)
    local key = assert(P:ResolveStoreKey(store))
    local raw = assert(P:DecodePhysicalEnvelope(io.disk[key]))
    assert(raw.__rsmeta.schema == 2 and raw.codec == 2, "schema2 restamp missing")
    assert(raw.__rsmeta.encodedFingerprint == "5CF32E2D", "unexpected schema2 empty fingerprint: " .. tostring(raw.__rsmeta.encodedFingerprint))

    local freshS, freshP = Boot(Copy(io.disk))
    dofile("features/life/activities/rs_activity_store.lua")
    local freshStore = assert(freshP:GetStore(STORE_ID))
    local loaded, _, loadErr = freshP:LoadStore(STORE_ID)
    assert(loaded == true, loadErr)
    assert(freshStore.writeFenced ~= true and freshStore.lastIntegrityStatus == "verified_canonical", "restamped schema2 did not strict-load")
    assert(next(freshS.Features.Activities.DetailTrackingState.groups) == nil, "fresh default-all state changed")
end)

print(string.format("ACTIVITY PROGRESS INTEGRITY RESULT: %d passed, %d failed", passed, failed))
if failed > 0 then error("activity progress integrity recovery failures: " .. tostring(failed), 0) end
