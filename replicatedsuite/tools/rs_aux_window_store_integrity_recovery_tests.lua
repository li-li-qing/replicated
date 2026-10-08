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
local function Boot(disk)
    local io = { disk = disk or {}, reads = 0, writes = 0 }
    ADDON = {
        LoadData = function(_, key) io.reads = io.reads + 1; return Copy(io.disk[key]) end,
        SaveData = function(_, key, value) io.writes = io.writes + 1; io.disk[key] = Copy(value); return true end,
        ClearData = function() error("aux recovery test must not clear saves") end,
    }
    ReplicatedSuite = {
        -- 中文维护注释（2026-10-02）：校验的就是 Floating 的生产 canonical，禁止测试替身复制
        -- NormalizeState；只隔离 Native 创建窗口，Persistence/Transport/Floating/Aux 全部加载真实实现。
        Features = {}, Services = {}, UI = { CreateWindowShell=function() error("storage test must not create Native windows") end }, UIV3 = {}, RSUI = {},
        NowMs = function() return 1000 end,
    }
    dofile("core/rs_utils.lua"); dofile("core/rs_reuse.lua"); dofile("core/rs_demand.lua")
    dofile("core/rs_api.lua"); dofile("core/rs_api_capabilities.lua"); dofile("core/rs_persistence_transport.lua"); dofile("core/rs_persistence.lua")
    dofile("ui/framework/rs_ui_floating_surface.lua")
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
    for _, id in ipairs(ids) do out[id] = ReplicatedSuite.RSUI.FloatingSurface:NormalizeState(value[id], POLICIES[id]) end
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

-- 中文维护注释（2026-10-02）：真实报告 RS-20261002-195813-365029-1.2.txt 中的 Aux 快照；
-- 原文件 SHA256=8c87537f0f1ce83b31249b0243fa2ad4aec42d291d5c4927b8a8f57c4263d302。
-- 用受限 T/S/D/B 数据语法解码，未执行报告文本；原始 metadata、Transport3 数字字符串与两份指纹保持原样。
local REPORT_SCHEMA1 = {
    ["__rsmeta"] = {
        ["contractVersion"] = 3,
        ["encodedFingerprint"] = "782943CD",
        ["envelopeFingerprint"] = "7D263FA3",
        ["envelopeIntegrityVersion"] = 1,
        ["framework"] = 3,
        ["integrityVersion"] = 4,
        ["lifetime"] = "Permanent",
        ["owner"] = "v3.presentation.aux_windows",
        ["periodId"] = "permanent",
        ["reliabilityContract"] = 8,
        ["schema"] = 1,
        ["scope"] = "Account",
        ["store"] = "v3.presentation.aux_windows",
        ["transportVersion"] = 3,
    },
    ["payload"] = {
        ["quest_detail"] = {
            ["backgroundOpacity"] = 1,
            ["coordinateSpace"] = "logical-free-v2",
            ["fontScale"] = 1,
            ["height"] = "__rs_t3:n420.00002670285539",
            ["locked"] = "__rs_t3:f",
            ["minimized"] = "__rs_t3:f",
            ["normalizedCenterX"] = "__rs_t3:n0.48749960660934449",
            ["normalizedCenterY"] = "__rs_t3:n0.49791634877522789",
            ["overallOpacity"] = "__rs_t3:n0.95999999999999996",
            ["savedLogicalHeight"] = "__rs_t3:n1439.998626710294",
            ["savedLogicalWidth"] = "__rs_t3:n2559.9975585960783",
            ["savedUiScale"] = "__rs_t3:n1.0000009536743164",
            ["textOpacity"] = 1,
            ["userMoved"] = true,
            ["width"] = "__rs_t3:n560.00001525877451",
            ["x"] = "__rs_t3:n967.99779510708322",
            ["y"] = "__rs_t3:n506.99884510150423",
        },
        ["trade_detail"] = {
            ["backgroundOpacity"] = 1,
            ["fontScale"] = 1,
            ["height"] = 440,
            ["locked"] = "__rs_t3:f",
            ["minimized"] = "__rs_t3:f",
            ["overallOpacity"] = "__rs_t3:n0.95999999999999996",
            ["textOpacity"] = 1,
            ["userMoved"] = "__rs_t3:f",
            ["width"] = 620,
        },
        ["trade_diagnostics"] = {
            ["backgroundOpacity"] = 1,
            ["fontScale"] = 1,
            ["height"] = 520,
            ["locked"] = "__rs_t3:f",
            ["minimized"] = "__rs_t3:f",
            ["overallOpacity"] = "__rs_t3:n0.95999999999999996",
            ["textOpacity"] = 1,
            ["userMoved"] = "__rs_t3:f",
            ["width"] = 700,
        },
    },
}
local REPORT_KEY = "replicated_suite_v1_v3_presentation_aux_windows"
Test("real three-window schema1 reproduces original stamp and preserves quest geometry", function()
    local S,P,io=Boot({[REPORT_KEY]=Copy(REPORT_SCHEMA1)})
    dofile("presentation/v3/rs_v3_aux_window_store.lua")
    local store=P:GetStore(STORE_ID)
    local decoded=assert(S.PersistenceTransport.DecodeV3(REPORT_SCHEMA1.payload))
    local original=NormalizeWith({"trade_detail","trade_diagnostics","quest_detail"},decoded)
    assert(P:FingerprintCanonicalValue(store,original)=="782943CD", "real original canonical was not reproduced")
    assert(P:FingerprintCanonicalValue(store,NormalizeWith(CURRENT,decoded))=="188C8DDF", "reported new canonical was not reproduced")
    local ok,err=S.UIV3.AuxWindowStoreV3:EnsureLoaded();assert(ok,err)
    assert(not store.writeFenced)
    assert(store.lastHistoricalRecoveryProbe=="aux_policy/schema1_quest_without_module/match")
    assert(store.lastIntegrityFingerprint=="782943CD", "old stamp proof was replaced")
    local q=S.UIV3.AuxWindowStoreV3.state.quest_detail
    assert(q.x==original.quest_detail.x and q.y==original.quest_detail.y and q.width==original.quest_detail.width)
    assert(q.coordinateSpace=="logical-free-v2" and q.normalizedCenterX==original.quest_detail.normalizedCenterX)
    assert(S.UIV3.AuxWindowStoreV3.state.module_diagnostics.width==760)
    local saved,why=P:SaveStore(STORE_ID,{force=true,durable=true});assert(saved,why)
    local freshS,freshP=Boot(Copy(io.disk));dofile("presentation/v3/rs_v3_aux_window_store.lua")
    local loaded,loadErr=freshS.UIV3.AuxWindowStoreV3:EnsureLoaded();assert(loaded,loadErr)
    assert(freshP:GetStore(STORE_ID).lastIntegrityStatus=="verified_canonical")
    assert(freshS.UIV3.AuxWindowStoreV3.state.quest_detail.x==q.x)
    assert(freshP:GetStore(STORE_ID).writeFenced~=true)
end)
Test("three-window recovery refuses altered geometry or already present module state", function()
    for _,kind in ipairs({"quest_position","quest_width","module_present","wrong_stamp","schema2"}) do
        local raw=Copy(REPORT_SCHEMA1)
        if kind=="quest_position" then raw.payload.quest_detail.x="__rs_t3:n968.99779510708322"
        elseif kind=="quest_width" then raw.payload.quest_detail.width="__rs_t3:n561.00001525877451"
        elseif kind=="module_present" then raw.payload.module_diagnostics={width=801,height=620}
        elseif kind=="wrong_stamp" then raw.__rsmeta.encodedFingerprint="DEADBEEF"
        elseif kind=="schema2" then raw.__rsmeta.schema=2 end
        local S,P,io=Boot({[REPORT_KEY]=raw});dofile("presentation/v3/rs_v3_aux_window_store.lua")
        local ok=S.UIV3.AuxWindowStoreV3:EnsureLoaded()
        assert(ok~=true,"unproven recovery accepted: "..kind)
        assert(P:GetStore(STORE_ID).writeFenced==true,"bad input lost fence: "..kind)
        assert(io.writes==0,"rejected evidence must never be written")
    end
end)

print(string.format("AUX WINDOW INTEGRITY RESULT: %d passed, %d failed", passed, failed))
if failed > 0 then error("aux window integrity recovery failures: " .. tostring(failed), 0) end
