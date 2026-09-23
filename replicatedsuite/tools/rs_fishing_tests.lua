------------------------------------------------------------------------
-- Replicated Suite V3 - Fishing / Auto-R Regression Tests
--
-- Covers the RU-proven fishing action buff mapping and the reversible Auto-R
-- hotkey transaction.  Native calls are mocked at the exact capability shapes
-- used by production; this is not a RU client test.
------------------------------------------------------------------------

unpack = unpack or table.unpack
if not math.frexp then math.frexp = function(x) if x == 0 then return 0, 0 end local e = math.floor(math.log(math.abs(x)) / math.log(2)) + 1 return x / (2^e), e end end
if not math.ldexp then math.ldexp = function(m, e) return m * (2^e) end end

local passed, total = 0, 0
local function Test(name, fn)
    total = total + 1
    local ok, err = xpcall(fn, debug.traceback)
    if ok then
        passed = passed + 1
        print(string.format("  PASS [%02d] %s", total, name))
    else
        print(string.format("  FAIL [%02d] %s: %s", total, name, tostring(err)))
    end
end

print("=== Replicated Suite: Fishing / Auto-R Tests ===")

local h = dofile("tools/rs_gear_page_test_host.lua")({})
local S = h.S
S.SafeChat = function(message) h.logs[#h.logs + 1] = { "chat", tostring(message) } end

dofile("core/rs_demand.lua")
dofile("features/rs_feature_registry.lua")

local combat = false
local zoneGroup = 1
local targetBuffs = {}
local bindings = { [1] = "R", [2] = "2", [3] = "3", [4] = "4", [5] = "5", [6] = "6", [7] = "7", [8] = "8", [9] = "9", [10] = "0", [11] = "-", [12] = "=" }
local nativeLog = {}
local failSetSlot = nil
local failSaveHotkey = false

local function Copy(value)
    if type(value) ~= "table" then return value end
    local out = {}
    for k, v in pairs(value) do out[k] = Copy(v) end
    return out
end

local function resetNative()
    combat = false
    zoneGroup = 1
    targetBuffs = {}
    bindings = { [1] = "R", [2] = "2", [3] = "3", [4] = "4", [5] = "5", [6] = "6", [7] = "7", [8] = "8", [9] = "9", [10] = "0", [11] = "-", [12] = "=" }
    nativeLog = {}
    failSetSlot = nil
    failSaveHotkey = false
end

_G.X2Player = {
    PlayerInCombat = function() return combat end,
}
_G.X2Unit = {
    UnitNameWithWorld = function() return "FishingTest@World" end,
    UnitBuffCount = function(_, unit) return unit == "target" and #targetBuffs or 0 end,
    UnitBuff = function(_, unit, index) return unit == "target" and Copy(targetBuffs[index]) or nil end,
    GetCurrentZoneGroup = function() return zoneGroup end,
}
_G.X2Hotkey = {
    GetOptionBinding = function(_, action, index, option, slot)
        nativeLog[#nativeLog + 1] = { op = "read", slot = slot, option = option }
        return bindings[slot]
    end,
    BindingToOption = function()
        nativeLog[#nativeLog + 1] = { op = "begin" }
        return true
    end,
    SetOptionBindingWithIndex = function(_, action, key, index, slot)
        nativeLog[#nativeLog + 1] = { op = "set", slot = slot, key = key }
        if tonumber(failSetSlot) == tonumber(slot) then return false end
        -- Mirror the client's one-key-one-binding behavior: assigning a key to a
        -- new action slot removes that same key from the previous slot.
        for existingSlot, existingKey in pairs(bindings) do
            if tostring(existingKey) == tostring(key) then bindings[existingSlot] = nil end
        end
        bindings[slot] = key
        return true
    end,
    RemoveOptionBinding = function(_, action, index, slot)
        nativeLog[#nativeLog + 1] = { op = "remove", slot = slot }
        bindings[slot] = nil
        return true
    end,
    SaveHotKey = function()
        nativeLog[#nativeLog + 1] = { op = "save_hotkey" }
        if failSaveHotkey then return false end
        return true
    end,
}

-- Baseline RED gate: r2 had no transaction service and deliberately blocked Auto-R.
local serviceOk, serviceErr = pcall(dofile, "services/rs_fishing_hotkey_v3.lua")
assert(serviceOk, "FishingHotkeyV3 service must exist: " .. tostring(serviceErr))
assert(type(S.Services and S.Services.FishingHotkeyV3) == "table", "FishingHotkeyV3 service must register")

dofile("features/life/rs_life_m16_bundle.lua")
local Fishing = assert(S.Features.Fishing, "Fishing feature failed to load")
Fishing.enabled = true
assert(Fishing:Initialize(), "Fishing Initialize failed")

local Hotkey = assert(S.Services.FishingHotkeyV3)

local function setFishBuff(id, timeLeft)
    targetBuffs = id and { { buff_id = id, timeLeft = timeLeft or 1800, path = "test/" .. tostring(id) .. ".dds" } } or {}
end

local function findLog(op, slot)
    for i, row in ipairs(nativeLog) do
        if row.op == op and (slot == nil or tonumber(row.slot) == tonumber(slot)) then return i, row end
    end
    return nil
end

local function assertBindings(expected)
    for slot, key in pairs(expected) do
        assert(bindings[slot] == key, string.format("slot %s expected %s got %s", tostring(slot), tostring(key), tostring(bindings[slot])))
    end
end

Test("T1: Auto-R is runtime-enabled behind transaction contract", function()
    assert(Fishing.Patch == "fishing-auto-r-transaction-1", "fishing patch marker must identify the Auto-R transaction build")
    assert(Fishing.HotkeyRuntimeBlocked == false, "Auto-R must no longer be hard-blocked")
    assert((tonumber(Fishing.HotkeyContractVersion) or 0) >= 3, "HotkeyContractVersion must be >=3")
    assert((tonumber(Hotkey.TransactionContractVersion) or 0) >= 3, "transaction service contract must be >=3")
end)

Test("T1b: Auto-R availability is true out of combat with an active consumer", function()
    resetNative()
    assert(Fishing:AcquireConsumer("test:availability"))
    local p = Fishing:GetProjection()
    assert(p.autoAvailable == true, "out-of-combat supported Auto-R must be available: " .. tostring(p.autoBlockedReason))
    assert(Fishing:ReleaseConsumer("test:availability"))
end)

Test("T2: Normal and Mirage fishing action maps match RU legacy behavior", function()
    resetNative()
    setFishBuff(5264)
    zoneGroup = 1
    assert(Fishing:AcquireConsumer("test:t2"))
    assert(Fishing:Refresh())
    local p = Fishing:GetProjection()
    assert(p.buffId == 5264 and p.slot == 4, "normal 5264 must map to slot 4")
    zoneGroup = 49
    assert(Fishing:Refresh())
    p = Fishing:GetProjection()
    assert(p.buffId == 5264 and p.slot == 3, "Mirage 5264 must map to slot 3")
    setFishBuff(5508)
    assert(Fishing:Refresh())
    p = Fishing:GetProjection()
    assert(p.slot == 6, "Mirage 5508 must map to slot 6")
    assert(Fishing:ReleaseConsumer("test:t2"))
end)

Test("T3: ArmAuto durably stores recovery before first hotkey write", function()
    resetNative()
    setFishBuff(5264)
    assert(Fishing:AcquireConsumer("test:t3"))
    local originalSaveData = ADDON.SaveData
    local order = {}
    ADDON.SaveData = function(self, key, value)
        order[#order + 1] = "persist"
        return originalSaveData(self, key, value)
    end
    local originalSet = X2Hotkey.SetOptionBindingWithIndex
    X2Hotkey.SetOptionBindingWithIndex = function(self, action, key, index, slot)
        order[#order + 1] = "set:" .. tostring(slot)
        return originalSet(self, action, key, index, slot)
    end

    local ok, err = Fishing:ArmAuto()
    assert(ok == true, tostring(err))
    assert(Fishing:IsAutoArmed() == true, "must arm")
    assert(type(Fishing.State.recovery) == "table" and Fishing.State.recovery.pending == true, "durable recovery must be present")
    assert(order[1] == "persist", "recovery persistence must occur before any hotkey mutation")

    ADDON.SaveData = originalSaveData
    X2Hotkey.SetOptionBindingWithIndex = originalSet
    assert(Fishing:DisarmAuto())
    assert(Fishing:ReleaseConsumer("test:t3"))
end)

Test("T4: Active action moves R and action changes restore previous destination", function()
    resetNative()
    setFishBuff(5264)
    assert(Fishing:AcquireConsumer("test:t4"))
    assert(Fishing:ArmAuto())
    assert(bindings[4] == "R", "5264 must move R to slot 4")
    setFishBuff(5265)
    assert(Fishing:Refresh())
    assert(bindings[4] == "4", "old slot 4 must be restored before moving")
    assert(bindings[3] == "R", "5265 must move R to slot 3")
    assert(Fishing:DisarmAuto())
    assertBindings({ [1] = "R", [3] = "3", [4] = "4" })
    assert(Fishing:ReleaseConsumer("test:t4"))
end)

Test("T4b: Armed Auto-R owns a demand lease after the page consumer closes", function()
    resetNative()
    setFishBuff(5264)
    assert(Fishing:AcquireConsumer("test:page-close"))
    assert(Fishing:ArmAuto())
    assert(Fishing:ReleaseConsumer("test:page-close"))
    local armedAfterPageClose = Fishing:IsAutoArmed() == true
    local pollStillRunning = S.Scheduler.tasks["v3_life_fishing_poll"] ~= nil
    -- Clean up both old and new implementations before asserting so one RED case cannot pollute later tests.
    if Fishing:IsAutoArmed() then Fishing:DisarmAuto(true) end
    local pollReleasedAfterDisarm = S.Scheduler.tasks["v3_life_fishing_poll"] == nil
    assert(armedAfterPageClose, "Auto-R must remain armed after the main page consumer closes")
    assert(pollStillRunning, "Auto-R lease must keep the demand-scoped observation task alive")
    assert(pollReleasedAfterDisarm, "disarming the last Auto-R consumer must release the observation task")
end)

Test("T5: Originally unbound fishing slot is restored to unbound", function()
    resetNative()
    bindings[4] = nil
    setFishBuff(5264)
    assert(Fishing:AcquireConsumer("test:t5"))
    assert(Fishing:ArmAuto())
    assert(bindings[4] == "R", "slot 4 must receive R")
    assert(Fishing:DisarmAuto())
    assert(bindings[1] == "R", "source R must be restored")
    assert(bindings[4] == nil, "originally empty destination must be empty after restore")
    assert(findLog("remove", 4) ~= nil, "RemoveOptionBinding must be used for empty destination restore")
    assert(Fishing:ReleaseConsumer("test:t5"))
end)

Test("T6: Combat blocks arming without any hotkey write", function()
    resetNative()
    combat = true
    setFishBuff(5264)
    local ok = Fishing:ArmAuto()
    assert(ok ~= true, "arm must fail in combat")
    assert(findLog("set") == nil and findLog("remove") == nil and findLog("save_hotkey") == nil, "combat guard must emit zero hotkey writes")
end)

Test("T7: Disarm in combat defers restore and recovery completes after combat", function()
    resetNative()
    setFishBuff(5264)
    assert(Fishing:AcquireConsumer("test:t7"))
    assert(Fishing:ArmAuto())
    assert(bindings[4] == "R")
    combat = true
    local ok = Fishing:DisarmAuto()
    assert(ok ~= true, "combat disarm must defer native restore")
    assert(Fishing:IsAutoArmed() == false, "new mappings must stop immediately")
    assert(Fishing:IsRecoveryPending() == true, "pending restore must remain authoritative")
    combat = false
    assert(Fishing:ProcessPendingRecovery())
    assertBindings({ [1] = "R", [4] = "4" })
    assert(Fishing:IsRecoveryPending() == false, "pending recovery must clear after restore")
    assert(Fishing:ReleaseConsumer("test:t7"))
end)

Test("T8: Hotkey write failure fails closed and restores session", function()
    resetNative()
    setFishBuff(nil)
    assert(Fishing:AcquireConsumer("test:t8"))
    assert(Fishing:ArmAuto())
    failSetSlot = 4
    setFishBuff(5264)
    local ok = Fishing:Refresh()
    assert(ok ~= true, "Refresh must surface Auto-R write failure")
    assert(Fishing:IsAutoArmed() == false, "Auto-R must disarm after write failure")
    failSetSlot = nil
    -- The transaction is allowed to keep recovery pending if compensation could
    -- not use the failing native API. Once the fault clears, explicit recovery
    -- must restore the original map without requiring a reload.
    assert(Fishing:ProcessPendingRecovery())
    assertBindings({ [1] = "R", [4] = "4" })
    assert(Fishing:ReleaseConsumer("test:t8"))
end)

Test("T9: Demand-scoped observation task starts and stops with consumers", function()
    resetNative()
    assert(Fishing:AcquireConsumer("test:fishing"))
    assert(S.Scheduler.tasks["v3_life_fishing_poll"] ~= nil, "fishing poll task must exist while demanded")
    assert(Fishing:ReleaseConsumer("test:fishing"))
    assert(S.Scheduler.tasks["v3_life_fishing_poll"] == nil, "fishing poll task must release at zero consumers")
end)

Test("T10: Persisted recovery can be adopted and restored without re-arming", function()
    resetNative()
    setFishBuff(5264)
    assert(Fishing:AcquireConsumer("test:t10"))
    assert(Fishing:ArmAuto())
    local recovery = Copy(Fishing.State.recovery)
    assert(type(recovery) == "table" and recovery.pending == true)
    -- Simulate process-local session loss while the durable recovery record survives.
    Hotkey:ResetSession()
    Fishing.autoArmed = false
    assert(Hotkey:AdoptRecovery(recovery.snapshot))
    assert(Fishing:ProcessPendingRecovery())
    assertBindings({ [1] = "R", [4] = "4" })
    assert(Fishing:ReleaseConsumer("test:t10"))
end)


local function ReadText(path)
    local f = assert(io.open(path, "rb"), "cannot open " .. tostring(path))
    local text = f:read("*a")
    f:close()
    return text
end

Test("T11: Registry exposes reversible Auto-R instead of runtime-block metadata", function()
    local text = ReadText("features/rs_feature_registry.lua")
    local block = text:match('Add%("life_fishing".-\n%}%)') or ""
    assert(block:find("Runtime Blocked", 1, true) == nil, "registry must not advertise fishing Auto-R as Runtime Blocked")
    assert(block:find("X2Hotkey:SetOptionBindingWithIndex", 1, true) ~= nil, "registry must declare hotkey write dependency")
    assert(block:find("demand_scoped_reversible_hotkey_transaction", 1, true) ~= nil, "registry must expose transaction policy")
end)

Test("T12: Foundation gate requires Fishing Hotkey v3 transaction instead of old block fence", function()
    local text = ReadText("core/rs_foundation_gate.lua")
    assert(text:find("life_fishing:auto_r_runtime_block", 1, true) == nil, "old runtime-block gate must be removed")
    assert(text:find("life_fishing:auto_r_transaction", 1, true) ~= nil, "foundation must enforce the v3 transaction contract")
    assert(text:find("FishingHotkeyV3", 1, true) ~= nil, "foundation must validate the transaction service")
end)

Test("T13: Fishing page presents Auto-R as usable capability, not blocked copy", function()
    local text = ReadText("presentation/v3/pages/rs_v3_life_m16_pages.lua")
    assert(text:find("自动 R 已阻塞", 1, true) == nil, "page must remove stale blocked copy")
    assert(text:find("启用自动 R", 1, true) ~= nil, "page must expose the enable action")
    assert(text:find("自动 R 不可用", 1, true) ~= nil, "page must distinguish temporary unavailability from runtime block")
end)

Test("T13b: Fishing page keeps the close action clickable while Auto-R is armed", function()
    local text = ReadText("presentation/v3/pages/rs_v3_life_m16_pages.lua")
    assert(text:find("armed or projection.autoAvailable == true", 1, true) ~= nil, "armed Auto-R must keep the close action enabled even when combat blocks new writes")
    assert(text:find('armed and "关闭自动 R"', 1, true) ~= nil, "armed state must keep the close label authoritative")
end)

Test("T14: Acceptance validates fishing Hotkey v3 contract", function()
    local text = ReadText("presentation/v3/rs_v3_acceptance.lua")
    assert(text:find("fishing_hotkey_transaction_contract", 1, true) ~= nil, "acceptance must enforce fishing hotkey transaction contract")
    assert(text:find("FishingHotkeyV3", 1, true) ~= nil, "acceptance must validate service presence")
end)

Test("T15: Diagnostics exposes fishing observation and hotkey recovery state", function()
    local text = ReadText("core/rs_diagnostics.lua")
    assert(text:find('FeatureRow("fishing", "钓鱼"', 1, true) ~= nil, "diagnostics must include fishing row")
    assert(text:find("writeFailures", 1, true) ~= nil, "diagnostics must surface hotkey write failures")
end)

Test("T16: Documentation no longer lists fishing Auto-R as SPECIFIC_RUNTIME_BLOCKED", function()
    local text = ReadText("Docs/README.md")
    assert(text:find("Fishing full R source-slot enumeration/snapshot | SPECIFIC_RUNTIME_BLOCKED", 1, true) == nil, "README must remove obsolete fishing blocker")
    assert(text:find("HotkeyContractVersion = 3", 1, true) ~= nil, "README must record the v3 reversible transaction contract")
end)

print(string.format("=== RESULT: %d/%d PASS ===", passed, total))
if passed ~= total then error(string.format("Fishing tests failed: %d/%d", passed, total)) end
