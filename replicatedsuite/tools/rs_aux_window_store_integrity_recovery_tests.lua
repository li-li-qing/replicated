------------------------------------------------------------------------
-- Replicated Suite - Auxiliary Window Store historical policy recovery
--
-- Offline Persistence v4 regression. The schema1 Store originally normalized
-- only the auxiliary window types that existed at that time. Adding quest_detail
-- later changed canonical output without a schema bump and could fence healthy
-- users. This test writes the published pre-quest-detail shape, then boots the
-- current schema2 Store and proves exact historical authentication + restamp.
------------------------------------------------------------------------
local passed, failed = 0, 0
local function Test(name, fn)
    local ok, err = xpcall(fn, debug.traceback)
    if ok then passed = passed + 1; print("PASS aux_window_integrity " .. name)
    else failed = failed + 1; print("FAIL aux_window_integrity " .. name .. ": " .. tostring(err)) end
end
local function Copy(value, seen)
    if type(value) ~= "table" then return value end
    seen = seen or {}; if seen[value] ~= nil then return seen[value] end
    local out = {}; seen[value] = out
    for key, item in pairs(value) do out[Copy(key, seen)] = Copy(item, seen) end
    return out
end
local function Clamp(value, minimum, maximum, fallback)
    local n = tonumber(value) or tonumber(fallback) or minimum
    if n < minimum then n = minimum end
    if maximum ~= nil and n > maximum then n = maximum end
    return n
end
local function FloatingNormalize(_, value, policy)
    value, policy = type(value) == "table" and value or {}, type(policy) == "table" and policy or {}
    local minW, minH = math.max(1, tonumber(policy.minWidth) or 1), math.max(1, tonumber(policy.minHeight) or 1)
    local maxW, maxH = tonumber(policy.maxWidth), tonumber(policy.maxHeight)
    local minFont, maxFont = Clamp(policy.minFontScale, .5, 2, .75), Clamp(policy.maxFontScale, .5, 2, 1.5)
    local defaultFont = Clamp(policy.defaultFontScale or policy.fontScale, minFont, maxFont, 1)
    local moved = value.userMoved == true
    local free = moved and tostring(value.coordinateSpace or "") == "logical-free-v2"
        and tonumber(value.x) ~= nil and tonumber(value.y) ~= nil
    local overall = tonumber(value.overallOpacity); if overall == nil then overall = tonumber(value.opacity) end
    return {
        width = Clamp(value.width, minW, maxW, policy.defaultWidth or policy.width or 420),
        height = Clamp(value.height, minH, maxH, policy.defaultHeight or policy.height or 286),
        minimized = value.minimized == true or (value.minimized == nil and policy.defaultMinimized),
        locked = value.locked == true or (value.locked == nil and policy.defaultLocked),
        overallOpacity = Clamp(overall, 0, 1, policy.defaultOverallOpacity or policy.overallOpacity or .94),
        backgroundOpacity = Clamp(value.backgroundOpacity, 0, 1, policy.defaultBackgroundOpacity or policy.backgroundOpacity or 1),
        textOpacity = Clamp(value.textOpacity, 0, 1, policy.defaultTextOpacity or policy.textOpacity or 1),
        fontScale = Clamp(value.fontScale, minFont, maxFont, defaultFont),
        userMoved = moved,
        x = free and tonumber(value.x) or nil, y = free and tonumber(value.y) or nil,
        anchorH = moved and not free and (tostring(value.anchorH or "") == "RIGHT" and "RIGHT" or "LEFT") or nil,
        anchorV = moved and not free and (tostring(value.anchorV or "") == "BOTTOM" and "BOTTOM" or "TOP") or nil,
        offsetX = moved and not free and math.max(0, tonumber(value.offsetX) or 0) or nil,
        offsetY = moved and not free and math.max(0, tonumber(value.offsetY) or 0) or nil,
        coordinateSpace = moved and (free and "logical-free-v2" or "logical-edge-v1") or nil,
        savedUiScale = moved and tonumber(value.savedUiScale) or nil,
        savedLogicalWidth = free and tonumber(value.savedLogicalWidth) or nil,
        savedLogicalHeight = free and tonumber(value.savedLogicalHeight) or nil,
        normalizedCenterX = free and tonumber(value.normalizedCenterX) or nil,
        normalizedCenterY = free and tonumber(value.normalizedCenterY) or nil,
    }
end
local function Boot(disk)
    local io = { disk = disk or {}, reads = 0, writes = 0 }
    ADDON = {
        LoadData = function(_, key) io.reads = io.reads + 1; return Copy(io.disk[key]) end,
        SaveData = function(_, key, value) io.writes = io.writes + 1; io.disk[key] = Copy(value); return true end,
        ClearData = function() error("aux recovery test must not clear saves") end,
    }
    ReplicatedSuite = {
        Features = {}, Services = {}, UI = {}, UIV3 = {}, RSUI = { FloatingSurface = { NormalizeState = FloatingNormalize } },
        NowMs = function() return 1000 end,
    }
    dofile("core/rs_utils.lua"); dofile("core/rs_reuse.lua"); dofile("core/rs_demand.lua")
    dofile("core/rs_api.lua"); dofile("core/rs_api_capabilities.lua"); dofile("core/rs_persistence.lua")
    return ReplicatedSuite, ReplicatedSuite.Persistence, io
end

local STORE_ID = "v3.presentation.aux_windows"
local POLICIES = {
    trade_detail = { defaultWidth=620, defaultHeight=440, minWidth=470, minHeight=300, defaultOverallOpacity=.96, defaultBackgroundOpacity=1, defaultTextOpacity=1, defaultFontScale=1, minFontScale=.8, maxFontScale=1.25 },
    trade_diagnostics = { defaultWidth=700, defaultHeight=520, minWidth=520, minHeight=340, defaultOverallOpacity=.96, defaultBackgroundOpacity=1, defaultTextOpacity=1, defaultFontScale=1, minFontScale=.8, maxFontScale=1.25 },
    quest_detail = { defaultWidth=560, defaultHeight=420, minWidth=420, minHeight=260, defaultOverallOpacity=.96, defaultBackgroundOpacity=1, defaultTextOpacity=1, defaultFontScale=1, minFontScale=.8, maxFontScale=1.25 },
    module_diagnostics = { defaultWidth=760, defaultHeight=590, minWidth=560, minHeight=380, defaultOverallOpacity=.98, defaultBackgroundOpacity=1, defaultTextOpacity=1, defaultFontScale=1, minFontScale=.85, maxFontScale=1.2 },
}
local function NormalizeWith(ids, value)
    value = type(value) == "table" and value or {}; local out = {}
    for _, id in ipairs(ids) do out[id] = FloatingNormalize(nil, value[id], POLICIES[id]) end
    return out
end
local PRE_QUEST = { "trade_detail", "trade_diagnostics", "module_diagnostics" }
local CURRENT = { "trade_detail", "trade_diagnostics", "quest_detail", "module_diagnostics" }

local function RegisterSchema1(P, ids, initial)
    local state = NormalizeWith(ids, initial)
    return assert(P:RegisterV3Store({
        id=STORE_ID, owner="v3.presentation.aux_windows", scope=P.Scope.Account, lifetime=P.Lifetime.Permanent,
        schemaVersion=1, legacySchemaVersion=0, key=P.V3KeyPrefix .. "presentation_aux_windows",
        budget={ maxDepth=6, maxNodes=320, maxStringBytes=4096, maxEntriesPerTable=64 },
        default=function() return NormalizeWith(ids, initial) end,
        get=function() return NormalizeWith(ids, state) end,
        apply=function(v) state=NormalizeWith(ids, v) end,
        migrate=function(v) return NormalizeWith(ids, v) end,
        allowIntegrityUpgrade=true,
    }))
end

Test("pre-quest-detail schema1 authenticates then migrates to schema2", function()
    local _, oldP, oldIo = Boot()
    local oldStore = RegisterSchema1(oldP, PRE_QUEST, {
        trade_detail={ width=688, height=455, userMoved=true, coordinateSpace="logical-free-v2", x=122, y=84, savedLogicalWidth=1920, savedLogicalHeight=1080, normalizedCenterX=.24, normalizedCenterY=.29 },
        module_diagnostics={ width=810, height=620 },
    })
    assert(oldP:LoadStore(STORE_ID) == "empty")
    assert(oldP:SaveStore(STORE_ID, { force=true, durable=true }))
    local key = assert(oldP:ResolveStoreKey(oldStore))
    local oldRaw = assert(oldP:DecodePhysicalEnvelope(oldIo.disk[key]))
    local oldStamp = assert(oldRaw.__rsmeta.encodedFingerprint)

    local S, P = Boot(Copy(oldIo.disk))
    dofile("presentation/v3/rs_v3_aux_window_store.lua")
    local store = assert(P:GetStore(STORE_ID))
    local loaded, _, err = P:LoadStore(STORE_ID)
    assert(loaded == true, err)
    assert(store.writeFenced ~= true, "healthy historical aux layout stayed fenced")
    assert(tostring(store.lastHistoricalRecoveryProbe or ""):find("aux_policy/pre_quest_detail/match", 1, true), "historical policy candidate did not match")
    assert(store.lastIntegrityStatus == "historical_canonical_recovery", "wrong recovery status: " .. tostring(store.lastIntegrityStatus))
    local state = S.UIV3.AuxWindowStoreV3.state
    assert(state.trade_detail.width == 688 and state.trade_detail.x == 122, "historical geometry was not preserved")
    assert(type(state.quest_detail) == "table" and state.quest_detail.width == 560, "quest_detail default not added by schema2 migration")
    assert(store.dirty == true, "recovered schema1 must queue restamp")
    assert(tostring(store.lastIntegrityFingerprint or "") == tostring(oldStamp), "old stamp evidence changed")
end)

Test("schema2 restamp reloads strictly without historical hook", function()
    local _, oldP, oldIo = Boot()
    local oldStore = RegisterSchema1(oldP, PRE_QUEST, { trade_detail={ width=688, height=455 } })
    assert(oldP:LoadStore(STORE_ID) == "empty")
    assert(oldP:SaveStore(STORE_ID, { force=true, durable=true }))

    local S, P, io = Boot(Copy(oldIo.disk))
    dofile("presentation/v3/rs_v3_aux_window_store.lua")
    local store = assert(P:GetStore(STORE_ID)); assert(P:LoadStore(STORE_ID))
    local ok, err = P:SaveStore(STORE_ID, { force=true, durable=true }); assert(ok, err)
    local key = assert(P:ResolveStoreKey(store)); local raw = assert(P:DecodePhysicalEnvelope(io.disk[key]))
    assert(raw.__rsmeta.schema == 2, "aux store did not restamp schema2")

    local freshS, freshP = Boot(Copy(io.disk))
    dofile("presentation/v3/rs_v3_aux_window_store.lua")
    local freshStore = assert(freshP:GetStore(STORE_ID))
    local loaded, _, loadErr = freshP:LoadStore(STORE_ID); assert(loaded == true, loadErr)
    assert(freshStore.writeFenced ~= true and freshStore.lastIntegrityStatus == "verified_canonical", "schema2 aux store did not strict-load")
    assert(freshS.UIV3.AuxWindowStoreV3.state.trade_detail.width == 688, "restamped geometry changed")
end)

Test("late schema1 already containing quest_detail migrates without historical reconstruction", function()
    local _, oldP, oldIo = Boot()
    local oldStore = RegisterSchema1(oldP, CURRENT, { quest_detail={ width=610, height=450 } })
    assert(oldP:LoadStore(STORE_ID) == "empty")
    assert(oldP:SaveStore(STORE_ID, { force=true, durable=true }))

    local S, P = Boot(Copy(oldIo.disk)); dofile("presentation/v3/rs_v3_aux_window_store.lua")
    local store = assert(P:GetStore(STORE_ID)); local loaded, _, err = P:LoadStore(STORE_ID); assert(loaded == true, err)
    assert(store.writeFenced ~= true, "late schema1 layout fenced")
    assert(S.UIV3.AuxWindowStoreV3.state.quest_detail.width == 610, "late schema1 quest detail geometry lost")
end)

print(string.format("AUX WINDOW INTEGRITY RESULT: %d passed, %d failed", passed, failed))
if failed > 0 then error("aux window integrity recovery failures: " .. tostring(failed), 0) end
