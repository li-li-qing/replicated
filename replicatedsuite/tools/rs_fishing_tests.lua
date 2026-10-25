-- Replicated Suite · 钓鱼测试
-- 作者：Replicated
-- QQ群：1104129461
-- 钓鱼和自动 R 回归，覆盖 RU 已证明的钓鱼动作 Buff 映射及可撤销热键事务。
-- 原生替身按生产能力参数形状模拟，不能视为 RU 客户端测试。
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
-- 使用真实模块报告与详情格式器，证明取证接入用户现有导出入口，翻页不会再次采样 Native。
dofile("core/rs_report_copy_transport.lua")
dofile("core/rs_diagnostic_detail.lua")
dofile("core/rs_module_diagnostics.lua")

local combat = false
local zoneGroup = 1
local targetBuffs = {}
local bindings = { [1] = "R", [2] = "2", [3] = "3", [4] = "4", [5] = "5", [6] = "6", [7] = "7", [8] = "8", [9] = "9", [10] = "0", [11] = "-", [12] = "=" }
local nativeLog = {}
local failSetSlot = nil
local failSaveHotkey = false
local failBindingRead = false
local failBindingReadSlot = nil
local firstModeSkill, failModeRead, failModeEstablish = 21571, false, false
local failModeReadSlot = nil
local probeCreates, probeReads, probeWidget = 0, 0, nil
local modeRows, tooltipReads, failTooltip = {}, 0, false

-- 构造/导入走真实工厂，只有客户端Slot是替身；槽类型故意不用真实常量，验证生产读取导出值。
_G.ISLOT_MODE_ACTION = 600
dofile("native/rs_native_contract.lua")
S.NativeImports = { AcquireObject = function(_, owner, name, required)
    assert(owner == "native_factory" and name == "SLOT" and required == false)
    assert(S.NativeContract:GetObject(name).id == 47, "Slot must use the source-verified optional ABI")
    return true
end }
S.PhysicalId = function(logical)
    assert(logical == "service:fishing_hotkey:mode_probe")
    return "rs_fishing_probe"
end
_G.UIParent = { CreateWidget = function(_, kind, id, parent)
    assert(kind == "slot" and id == "rs_fishing_probe" and parent == "UIParent")
    probeCreates = probeCreates + 1
    local slot = { shown = true, pickable = true }
    function slot:Show(value) self.shown = value; return value end
    function slot:EnablePick(value) self.pickable = value; return value end
    function slot:DisableDefaultClick() self.defaultClickDisabled = true end
    function slot:EstablishSlot(slotType, index)
        assert(slotType == ISLOT_MODE_ACTION and index >= 1 and index <= 8, "mode probe must stay within eight diagnostic slots")
        assert(not self.shown and not self.pickable and self.defaultClickDisabled, "probe must be inert before binding")
        if failModeEstablish then return false end
        self.established, self.slotIndex = true, index
    end
    function slot:GetSkillType()
        assert(self.established)
        probeReads = probeReads + 1
        if failModeRead or self.slotIndex == failModeReadSlot then error("mode skill unavailable") end
        if self.slotIndex == 1 then return firstModeSkill end
        if self.slotIndex == 2 and modeRows[2] == nil and firstModeSkill ~= 21571 then return 21571 end
        return modeRows[self.slotIndex] and modeRows[self.slotIndex].skillId
    end
    function slot:GetTooltip()
        assert(self.established, "read tooltip before ReleaseSlot")
        tooltipReads = tooltipReads + 1
        if failTooltip then error("tooltip unavailable") end
        if self.slotIndex == 1 then
            if modeRows[1] ~= nil then return modeRows[1] end
            -- 同日两份RU诊断的放生ID不同，名称、描述和图标一致。
            if firstModeSkill == 22548 or firstModeSkill == 22544 then
                return { name = "放生", description = "放生大鱼。", path = "Game/ui/icon/icon_skill_fishing_08.dds" }
            end
            return { name = firstModeSkill == 22538 and "放生" or "测试技能名" .. tostring(firstModeSkill), skillType = firstModeSkill }
        end
        return modeRows[self.slotIndex]
    end
    function slot:ReleaseSlot() self.established = false end
    probeWidget = slot
    return slot
end }
dofile("native/rs_native_object_factory.lua")

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
    failBindingRead = false
    failBindingReadSlot = nil
    firstModeSkill, failModeRead, failModeEstablish = 21571, false, false
    failModeReadSlot = nil
    modeRows, failTooltip = {}, false
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
        if failBindingRead or tonumber(failBindingReadSlot) == tonumber(slot) then error("injected binding read failure") end
        return bindings[slot]
    end,
    BindingToOption = function()
        nativeLog[#nativeLog + 1] = { op = "begin" }
        return true
    end,
    SetOptionBindingWithIndex = function(_, action, key, index, slot)
        nativeLog[#nativeLog + 1] = { op = "set", slot = slot, key = key }
        if tonumber(failSetSlot) == tonumber(slot) then return false end
        -- 模拟客户端一个键只绑定一个动作的行为：把按键分配到新动作槽时，从旧槽移除该按键。
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

-- 覆盖旧 r2 基线：没有事务服务时必须拒绝自动 R。
local serviceOk, serviceErr = pcall(dofile, "services/rs_fishing_hotkey_v3.lua")
assert(serviceOk, "FishingHotkeyV3 service must exist: " .. tostring(serviceErr))
assert(type(S.Services and S.Services.FishingHotkeyV3) == "table", "FishingHotkeyV3 service must register")

dofile("features/life/shared/rs_life_slice_factory.lua")

-- life_trade 已拆到独立文件，rs_life_m16_bundle.lua 退役删除。
dofile("features/life/trade/rs_trade_feature.lua")

dofile("features/life/fishing/rs_fishing_feature.lua")

dofile("features/life/treasure/rs_treasure_feature.lua")

dofile("features/life/bonds/rs_bonds_feature.lua")

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
    assert(Fishing.Patch == "fishing-slot-anchor-21571-1", "fishing patch marker must identify the fishing-slot anchor build")
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

Test("T3b: Failed source read cannot synthesize R in a recovery snapshot", function()
    resetNative()
    failBindingReadSlot = 1
    local snapshot = Hotkey:BuildSessionSnapshot(1)
    failBindingReadSlot = nil
    assert(snapshot == nil, "source getter failure must not fall back to an invented R")
end)

Test("T3c: Unreadable nonempty destination prevents arming without any write", function()
    resetNative()
    bindings[4] = "Q"
    setFishBuff(5264)
    assert(Fishing:AcquireConsumer("test:preflight-read-failure"))
    failBindingReadSlot = 4
    local ok = Fishing:ArmAuto()
    local writes = findLog("set") ~= nil or findLog("remove") ~= nil or findLog("save_hotkey") ~= nil
    failBindingReadSlot = nil
    assert(Fishing:DisarmAuto(true))
    assert(Fishing:ReleaseConsumer("test:preflight-read-failure"))
    assert(ok ~= true and not writes, "unverified destination must refuse the transaction before mutation")
    assert(bindings[4] == "Q", "original Q must survive unreadable destination preflight")
end)

Test("T3d: Failed getter cannot certify restoration of an originally empty slot", function()
    resetNative()
    failBindingReadSlot = 4
    local matches = Hotkey:BindingMatches(4, nil)
    failBindingReadSlot = nil
    assert(matches == false, "restore verification must distinguish unreadable from confirmed empty")
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
    -- 断言前清理新旧实现，避免一个失败用例污染后续测试。
    if Fishing:IsAutoArmed() then Fishing:DisarmAuto(true) end
    local pollReleasedAfterDisarm = S.Scheduler.tasks["v3_life_fishing_poll"] == nil
    assert(armedAfterPageClose, "Auto-R must remain armed after the main page consumer closes")
    assert(pollStillRunning, "Auto-R lease must keep the demand-scoped observation task alive")
    assert(pollReleasedAfterDisarm, "disarming the last Auto-R consumer must release the observation task")
end)

-- 真实 Events / Scheduler / Demand / Store / 热键服务驱动两条鱼切换。
-- Native 桩只模拟“动作栏键位被客户端重设”，不能把离线模型称为 RU 实测。
local function WithArmedFishing(token, fn)
    resetNative()
    setFishBuff(5264)
    assert(Fishing:AcquireConsumer(token))
    assert(Fishing:ArmAuto())
    local ok, err = xpcall(fn, debug.traceback)
    combat, failSetSlot, failSaveHotkey, failBindingRead, h.failSave = false, nil, false, false, false
    assert(Fishing:DisarmAuto(true))
    assert(Fishing:ReleaseConsumer(token))
    assertBindings({ [1] = "R", [3] = "3", [4] = "4", [5] = "5" })
    assert(Fishing.consumerCount == 0 and S.Scheduler.tasks["v3_life_fishing_poll"] == nil)
    if not ok then error(err) end
end

local function ResetMappedR()
    -- 原生动作栏变化时，两条鱼可能请求同一动作。
    bindings[4], bindings[1] = "4", "R"
end

-- 用户实测：切目标时先恢复同一会话的原按键，不能让上一条鱼的R跨过新目标的Buff空档。
-- 下一次真实观察才允许重新映射；原始快照和Auto-R租约必须保留，不能用重新Arm覆盖恢复基线。
Test("T4m: Target switch restores original keys before mapping the next fish", function()
    WithArmedFishing("test:target-reset-before-remap", function()
        local diskBefore = h.writes
        local sourceBefore = Hotkey.sessionSnapshot.sourceSlot
        setFishBuff(5265)
        S.Events:Dispatch("TARGET_CHANGED", "target")
        assertBindings({ [1] = "R", [3] = "3", [4] = "4" })
        assert(Fishing:IsAutoArmed() and Hotkey.currentSlot == nil)
        assert(Hotkey.sessionSnapshot.sourceSlot == sourceBefore and h.writes == diskBefore)
        assert(Fishing:GetProjection().slot == nil, "switch event must not remap from an unsettled buff snapshot")
        assert(S.Scheduler:RunTask("v3_life_fishing_poll"))
        assertBindings({ [3] = "R", [4] = "4" })
    end)
end)

Test("T4n: Clearing target restores the real source R and waits without repeated writes", function()
    WithArmedFishing("test:target-reset-empty", function()
        setFishBuff(nil)
        S.Events:Dispatch("TARGET_CHANGED", "target")
        assertBindings({ [1] = "R", [4] = "4" })
        local writesBefore, savesBefore = Hotkey.stats.writes, Hotkey.stats.saves
        for _ = 1, 10 do assert(S.Scheduler:RunTask("v3_life_fishing_poll")) end
        assert(Fishing:IsAutoArmed() and Hotkey.currentSlot == nil)
        assert(Hotkey.stats.writes == writesBefore and Hotkey.stats.saves == savesBefore)
        setFishBuff(5264)
        assert(S.Scheduler:RunTask("v3_life_fishing_poll"))
        assert(bindings[4] == "R", "another fish must resume from the retained original session")
    end)
end)

Test("T4c: Switching fish with the same buff rechecks and repairs native R", function()
    WithArmedFishing("test:same-buff-target", function()
        local resetsBefore = Hotkey.stats.targetResets or 0
        ResetMappedR()
        S.Events:Dispatch("TARGET_CHANGED", "target")
        local p = Fishing:GetProjection()
        assert(p.lastRefreshReason == "target_changed" and p.buffId == nil and Hotkey.currentSlot == nil)
        assertBindings({ [1] = "R", [4] = "4" }) -- 即使原生已重置，同动作换鱼也先明确退出上一条鱼的映射状态。
        assert(S.Scheduler:RunTask("v3_life_fishing_poll"))
        assert(bindings[4] == "R", "same action on another fish must repair the lost R mapping")
        assert(Fishing:IsAutoArmed() == true)
        assert((Fishing:GetProjection().hotkey.stats.targetResets or 0) == resetsBefore + 1, "diagnostics must record target initialization")
    end)
end)

Test("T4d: Poll repairs a bar reset occurring after the target event", function()
    WithArmedFishing("test:delayed-bar-reset", function()
        S.Events:Dispatch("TARGET_CHANGED", "target")
        ResetMappedR()
        assert(S.Scheduler:RunTask("v3_life_fishing_poll"))
        assert(bindings[4] == "R", "late native resets must be detected by the existing poll")
        assert(Fishing:GetProjection().lastRefreshReason == "poll")
    end)
end)

Test("T4e: Empty target then delayed buffs keeps Auto-R armed for both fish", function()
    WithArmedFishing("test:two-fish-buff-gap", function()
        setFishBuff(nil)
        ResetMappedR()
        local writesBefore = Hotkey.stats.writes
        S.Events:Dispatch("TARGET_CHANGED", "target")
        assert(Fishing:IsAutoArmed() == true and Fishing:GetProjection().slot == nil)
        assert(Hotkey.stats.writes == writesBefore, "a target without a fish action must not trigger new writes")
        setFishBuff(5264)
        S.Events:Dispatch("BUFF_UPDATE", "target")
        assert(S.Scheduler:RunTask("v3_life_fishing_event_refresh"))
        assert(bindings[4] == "R", "delayed buff arrival must repair the same cached slot")
        setFishBuff(5265)
        S.Events:Dispatch("TARGET_CHANGED", "target")
        assertBindings({ [1] = "R", [4] = "4" })
        assert(S.Scheduler:RunTask("v3_life_fishing_poll"))
        assert(bindings[3] == "R" and bindings[4] == "4")
        setFishBuff(5264)
        S.Events:Dispatch("TARGET_CHANGED", "target")
        assertBindings({ [1] = "R", [3] = "3" })
        assert(S.Scheduler:RunTask("v3_life_fishing_poll"))
        assert(bindings[4] == "R" and bindings[3] == "3")
    end)
end)

Test("T4f: Stable native R only reads and never rewrites or resaves", function()
    WithArmedFishing("test:stable-bar", function()
        local writesBefore, savesBefore, diskBefore = Hotkey.stats.writes, Hotkey.stats.saves, h.writes
        local readsBefore = Hotkey.stats.reads
        for _ = 1, 10 do assert(S.Scheduler:RunTask("v3_life_fishing_poll")) end
        assert(Hotkey.stats.reads == readsBefore + 10, "stable R should use one bounded slot read per refresh")
        assert(Hotkey.stats.writes == writesBefore and Hotkey.stats.saves == savesBefore and h.writes == diskBefore)
    end)
end)

Test("T4g: Drift during combat performs zero writes and recovers after combat", function()
    WithArmedFishing("test:drift-combat", function()
        ResetMappedR()
        combat = true
        local writesBefore, savesBefore = Hotkey.stats.writes, Hotkey.stats.saves
        S.Events:Dispatch("TARGET_CHANGED", "target")
        assert(Hotkey.stats.writes == writesBefore and Hotkey.stats.saves == savesBefore)
        assert(Fishing:IsAutoArmed() == false and Fishing:IsRecoveryPending() == true)
        combat = false
        assert(S.Scheduler:RunTask("v3_life_fishing_recovery"))
        assertBindings({ [1] = "R", [4] = "4" })
        assert(Fishing:IsRecoveryPending() == false)
    end)
end)

Test("T4h: Unreadable cached binding cannot authorize a new hotkey write", function()
    WithArmedFishing("test:binding-unreadable", function()
        failBindingRead = true
        local writesBefore, savesBefore = Hotkey.stats.writes, Hotkey.stats.saves
        local ok = Hotkey:MoveR(4, function() error("existing touched slot must not repersist") end)
        assert(ok ~= true, "unknown native binding must surface a verification failure")
        assert(Hotkey.stats.writes == writesBefore and Hotkey.stats.saves == savesBefore)
        assert(Fishing:IsRecoveryPending() == true, "read failure must retain the durable restore record")
    end)
end)

Test("T4i: First touch of another fish action stays durable before writing", function()
    WithArmedFishing("test:touch-persist-failure", function()
        h.failSave = true
        setFishBuff(5267)
        local ok = Fishing:Refresh("poll") -- 首次触碰发生在初始化之后的实际观察，仍须先持久化再写新槽。
        assert(ok ~= true and Fishing:IsAutoArmed() == false)
        for _, row in ipairs(nativeLog) do
            assert(not (row.op == "set" and row.slot == 5), "failed durable backup must prevent touching the new action")
        end
        assert(bindings[5] == "5")
        assert(Fishing:IsRecoveryPending() == true)
    end)
end)

Test("T4j: All five fish actions switch repeatedly in normal and Mirage bars", function()
    WithArmedFishing("test:all-fish-actions", function()
        local actions = { { 5264, 4 }, { 5265, 3 }, { 5267, 5 }, { 5266, 6 }, { 5508, 7 } }
        for _, zone in ipairs({ 1, 49 }) do
            zoneGroup = zone
            for _, action in ipairs(actions) do
                local slot = action[2] - (zone == 49 and 1 or 0)
                setFishBuff(action[1])
                S.Events:Dispatch("TARGET_CHANGED", "target")
                assert(bindings[1] == "R" and Hotkey.currentSlot == nil)
                assert(S.Scheduler:RunTask("v3_life_fishing_poll"))
                assert(Fishing:IsAutoArmed() == true and bindings[slot] == "R")
                -- 动作栏重置后，另一条鱼再次请求完全相同的动作。
                bindings[slot], bindings[1] = tostring(slot), "R"
                S.Events:Dispatch("TARGET_CHANGED", "target")
                assert(bindings[1] == "R" and Hotkey.currentSlot == nil)
                assert(S.Scheduler:RunTask("v3_life_fishing_poll"))
                assert(bindings[slot] == "R" and Fishing:GetProjection().slot == slot)
            end
        end
        assert(Fishing:DisarmAuto(true))
        assertBindings({ [1] = "R", [2] = "2", [3] = "3", [4] = "4", [5] = "5", [6] = "6", [7] = "7" })
    end)
end)

Test("R1: Both observed release variants and compatibility IDs shift all five actions in normal and Mirage zones", function()
    WithArmedFishing("test:release-all-actions", function()
        for _, releaseId in ipairs({22544,22548,22536,22538}) do
        firstModeSkill = releaseId
        for _, zone in ipairs({ 1, 49 }) do
            zoneGroup = zone
            for _, action in ipairs({ {5264,4}, {5265,3}, {5267,5}, {5266,6}, {5508,7} }) do
                setFishBuff(action[1])
                S.Events:Dispatch("TARGET_CHANGED", "target")
                assert(bindings[1] == "R" and Hotkey.currentSlot == nil)
                assert(S.Scheduler:RunTask("v3_life_fishing_poll"))
                local slot = action[2] - (zone == 49 and 1 or 0) + 1
                local p = Fishing:GetProjection()
                assert(p.slot == slot and bindings[slot] == "R", "release must shift the actual requested action")
                assert(p.actionBarLayout.firstSkillId == releaseId and p.actionBarLayout.slotOffset == 1)
            end
        end
        end
        assert(Fishing:DisarmAuto(true))
        assertBindings({ [1]="R", [2]="2", [3]="3", [4]="4", [5]="5", [6]="6", [7]="7", [8]="8" })
    end)
end)

Test("R2: Picking up and dropping fish remaps the same buff and restores the old destination", function()
    WithArmedFishing("test:release-transition", function()
        assert(bindings[4] == "R")
        firstModeSkill = 22544
        assert(S.Scheduler:RunTask("v3_life_fishing_poll"))
        assertBindings({ [4]="4", [5]="R" })
        local writes = Hotkey.stats.writes
        for _, releaseId in ipairs({22536,22538,22548,22544}) do
            firstModeSkill = releaseId
            assert(S.Scheduler:RunTask("v3_life_fishing_poll"))
        end
        assert(Hotkey.stats.writes == writes, "equivalent release IDs must not rewrite a correct destination")
        firstModeSkill = 21571 -- 新RU报告中未背鱼钓鱼阶段的首槽；不能因接近候选ID而误判偏移。
        assert(S.Scheduler:RunTask("v3_life_fishing_poll"))
        assertBindings({ [4]="R", [5]="5" })
        assert(Fishing:IsAutoArmed())
    end)
end)

Test("R3: Slot eight is backed up before writes and unbound state survives release recovery", function()
    resetNative(); bindings[8] = nil; firstModeSkill = 22548; setFishBuff(5508)
    assert(Fishing:AcquireConsumer("test:release-eight"))
    local ok, err = xpcall(function()
        local originalSet = X2Hotkey.SetOptionBindingWithIndex
        X2Hotkey.SetOptionBindingWithIndex = function(self, action, key, index, slot)
            if slot == 8 then
                local snapshot = Fishing.State.recovery.snapshot
                assert(snapshot.slots[8].wasUnbound and snapshot.touched[8], "slot eight must have durable original evidence")
                assert(h.disk ~= nil and h.writes > 0)
            end
            return originalSet(self, action, key, index, slot)
        end
        local armed, armErr = Fishing:ArmAuto()
        X2Hotkey.SetOptionBindingWithIndex = originalSet
        assert(armed, armErr)
        assert(bindings[8] == "R")
        assert(Fishing:DisarmAuto(true))
        assert(bindings[1] == "R" and bindings[8] == nil)
    end, debug.traceback)
    Fishing:DisarmAuto(true); Fishing:ReleaseConsumer("test:release-eight")
    if not ok then error(err) end
end)

Test("R4: Unreadable layout restores the previous mapping, waits and resumes without a new backup", function()
    WithArmedFishing("test:release-unavailable", function()
        local source = Hotkey.sessionSnapshot.sourceSlot
        for _, value in ipairs({ 0, -1, math.huge, "unknown" }) do
            firstModeSkill = value
            assert(Fishing:Refresh("poll"))
            assert(Fishing:GetProjection().slot == nil and Fishing:IsAutoArmed())
            assertBindings({ [1]="R", [4]="4" })
        end
        firstModeSkill, failModeRead = 22538, true
        local writes, disk = Hotkey.stats.writes, h.writes
        assert(Fishing:Refresh("poll"))
        assert(Hotkey.stats.writes == writes and h.writes == disk, "unknown layout must not repeatedly write")
        failModeRead, failModeEstablish = false, true
        assert(Fishing:Refresh("poll"))
        assert(Fishing:GetProjection().slot == nil, "failed EstablishSlot cannot reuse an old skill id")
        failModeEstablish = false
        assert(Fishing:Refresh("poll"))
        assertBindings({ [5]="R", [4]="4" })
        assert(Hotkey.sessionSnapshot.sourceSlot == source and Fishing:IsAutoArmed())
    end)
end)

Test("R5: Missing mode constant blocks mapping without guessing a slot type", function()
    WithArmedFishing("test:release-no-constant", function()
        local saved = _G.ISLOT_MODE_ACTION
        _G.ISLOT_MODE_ACTION = nil
        local ok, err = xpcall(function()
            assert(Fishing:Refresh("poll"))
            assert(Fishing:GetProjection().slot == nil and bindings[1] == "R")
            assert(Fishing:GetProjection().actionBarLayout.status == "unavailable")
        end, debug.traceback)
        _G.ISLOT_MODE_ACTION = saved
        if not ok then error(err) end
    end)
end)

Test("R8: Fishing 21571 in slot two shifts an arbitrary first skill without needing release tooltips", function()
    WithArmedFishing("test:fishing-anchor", function()
        firstModeSkill = 90042 -- 首格身份未知；仅第二格钓鱼21571证明偏移。
        modeRows[2] = { skillId = 21571 }
        failTooltip = true
        local tips = tooltipReads
        assert(S.Scheduler:RunTask("v3_life_fishing_poll"))
        assertBindings({ [4]="4", [5]="R" })
        assert(Fishing:GetProjection().actionBarLayout.fishingSlot == 2)
        for _ = 1, 5 do assert(S.Scheduler:RunTask("v3_life_fishing_poll")) end
        assert(tooltipReads == tips, "runtime layout reads only skill identities, never release names/icons")
        firstModeSkill = 21571
        assert(S.Scheduler:RunTask("v3_life_fishing_poll"))
        assertBindings({ [4]="R", [5]="5" })
        failTooltip = false
    end)
end)

Test("R9: Missing or unreadable slot-two fishing anchor waits even for an old release ID", function()
    WithArmedFishing("test:fishing-anchor-unavailable", function()
        firstModeSkill = 22544
        modeRows[2] = { skillId = 38924 }
        assert(S.Scheduler:RunTask("v3_life_fishing_poll"))
        assert(Fishing:GetProjection().slot == nil and Fishing:IsAutoArmed())
        assertBindings({ [1]="R", [4]="4", [5]="5" })
        modeRows[2] = { skillId = 21571 }
        failModeReadSlot = 2
        assert(S.Scheduler:RunTask("v3_life_fishing_poll"))
        assert(Fishing:GetProjection().slot == nil)
        failModeReadSlot = nil
        assert(S.Scheduler:RunTask("v3_life_fishing_poll"))
        assertBindings({ [4]="4", [5]="R" })
    end)
end)

Test("R6: Optional Slot import failure is cached and cannot reach the constructor or hotkey writes", function()
    resetNative()
    local previous, acquire = S.Services.FishingHotkeyV3, S.NativeImports.AcquireObject
    local attempts, creates = 0, probeCreates
    S.NativeImports.AcquireObject = function(_, _, name, required)
        assert(name == "SLOT" and required == false)
        attempts = attempts + 1
        return false, "slot import rejected"
    end
    dofile("services/rs_fishing_hotkey_v3.lua")
    local reader = S.Services.FishingHotkeyV3
    local ok, err = xpcall(function()
        for _ = 1, 10 do
            local layout = reader:ReadActionBarLayout()
            assert(layout.status == "unavailable" and layout.slotOffset == nil and layout.reason == "slot import rejected")
        end
        assert(attempts == 1 and probeCreates == creates and findLog("set") == nil)
        assert(S.BootError == nil, "optional mode probe must not fail the Suite boot")
    end, debug.traceback)
    S.Services.FishingHotkeyV3, S.NativeImports.AcquireObject = previous, acquire
    if not ok then error(err) end
end)

Test("R7: Slot eight read failure and old snapshots cannot authorize unbacked writes", function()
    resetNative()
    failBindingReadSlot = 8
    local snapshot = Hotkey:BuildSessionSnapshot(1)
    assert(snapshot == nil and findLog("set") == nil, "every destination must have a readable original binding")
    failBindingReadSlot = nil
    snapshot = assert(Hotkey:BuildSessionSnapshot(1))
    snapshot.slots[8] = nil -- 模拟重载前旧版的恢复记录；恢复旧槽仍可用，不能捏造第8槽原始按键。
    assert(Hotkey:AdoptRecovery(snapshot))
    local moved = Hotkey:MoveR(8, function() error("missing backup must not be persisted as valid") end)
    assert(not moved and bindings[8] == "8" and findLog("set") == nil)
    assert(Hotkey:RestoreSnapshot(snapshot))
    Hotkey:ResetSession()
end)

Test("T4k: Confirmed unbound R destination is repaired; KEY_R stays read-only", function()
    WithArmedFishing("test:empty-native-binding", function()
        bindings[4], bindings[1] = nil, "R"
        S.Events:Dispatch("TARGET_CHANGED", "target")
        assert(bindings[1] == "R" and Hotkey.currentSlot == nil)
        assert(S.Scheduler:RunTask("v3_life_fishing_poll"))
        assert(Fishing:IsAutoArmed() == true and bindings[4] == "R")
        bindings[4] = "KEY_R"
        local writesBefore, savesBefore = Hotkey.stats.writes, Hotkey.stats.saves
        assert(S.Scheduler:RunTask("v3_life_fishing_poll"))
        assert(Hotkey.stats.writes == writesBefore and Hotkey.stats.saves == savesBefore)
    end)
end)

Test("T4l: Failed target initialization stops mapping and retains exact recovery", function()
    WithArmedFishing("test:repair-write-fault", function()
        -- 保持旧R仍在槽4，迫使切目标执行真实恢复；故障不能被“Native已自行复原”短路。
        failSetSlot = 4
        S.Events:Dispatch("TARGET_CHANGED", "target")
        assert(Fishing:IsAutoArmed() == false and Fishing:IsRecoveryPending() == true)
        assert(type(Fishing.State.recovery) == "table" and Fishing.State.recovery.pending == true)
        failSetSlot = nil
        assert(Fishing:ProcessPendingRecovery(true, "test_repair_fault_cleared"))
        assertBindings({ [1] = "R", [4] = "4" })
        assert(Fishing:IsRecoveryPending() == false)
    end)
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
    -- 原生 API 故障导致补偿失败时，允许事务保持待恢复；故障解除后显式恢复必须还原原绑定，无须重载。
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
    -- 模拟进程内会话状态丢失，但持久化恢复记录仍存在。
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

-- 仅替换 RU Native getter；事务、能力门、Feature、报告和持久化沿用真实实现。
-- 每例还原宿主与开关，避免诊断故障注入污染原有 Auto-R 回归。
local function WithFishingDiagnostics(fn)
    resetNative()
    local savedUnit, savedEquipment, savedImports = Copy(X2Unit), X2Equipment, S.ApiImports
    local savedSlot, savedSlotType = _G.ES_BACKPACK, _G.EST_BACKPACK
    local calls = { buffs = 0, equipment = 0, imports = 0, identity = 0 }
    local playerBuffs = { { buff_id = 91001, timeLeft = 600 } }
    local playerDebuffs = { { buff_id = 91002, timeLeft = 500 } }
    local function Buffs(unit, debuff)
        if unit == "player" then return debuff and playerDebuffs or playerBuffs end
        return debuff and {} or targetBuffs
    end
    X2Unit.UnitBuffCount = function(_, unit) calls.buffs = calls.buffs + 1; return #Buffs(unit, false) end
    X2Unit.UnitBuff = function(_, unit, index) calls.buffs = calls.buffs + 1; return Copy(Buffs(unit, false)[index]) end
    X2Unit.UnitDeBuffCount = function(_, unit) calls.buffs = calls.buffs + 1; return #Buffs(unit, true) end
    X2Unit.UnitDeBuff = function(_, unit, index) calls.buffs = calls.buffs + 1; return Copy(Buffs(unit, true)[index]) end
    X2Unit.GetTargetUnitId = function() calls.identity = calls.identity + 1; return "fish:1" end
    X2Unit.UnitName = function(_, unit) assert(unit == "target"); return "测试鱼" end
    _G.ES_BACKPACK, _G.EST_BACKPACK = 27, 127
    X2Equipment = { GetEquippedItemType = function(_, slot)
        assert(slot == 27, "diagnostics must use ES_BACKPACK, never EST_BACKPACK")
        calls.equipment = calls.equipment + 1
        return 92001
    end }
    S.ApiImports = { Acquire = function(_, owner, dependencies)
        assert(owner == "feature:life_fishing:diagnostics" and dependencies[1] == "X2Equipment:GetEquippedItemType")
        calls.imports = calls.imports + 1
        return true
    end }
    setFishBuff(5264)
    local ok, err = xpcall(function() fn(calls, playerBuffs, playerDebuffs) end, debug.traceback)
    for key in pairs(X2Unit) do X2Unit[key] = nil end
    for key, value in pairs(savedUnit) do X2Unit[key] = value end
    X2Equipment, S.ApiImports = savedEquipment, savedImports
    _G.ES_BACKPACK, _G.EST_BACKPACK = savedSlot, savedSlotType
    Fishing.enabled = true
    if not ok then error(err) end
end

Test("D1: Explicit fishing diagnostics captures carry evidence without remapping or saving", function()
    WithFishingDiagnostics(function(calls)
        -- 原观察遇到匹配 Buff 后会停止；诊断必须保留其后的陌生 ID，不能照搬该短路扫描。
        targetBuffs[2] = { buff_id = 91999, timeLeft = 300, stack = 2 }
        bindings[8], bindings[9] = "KEY_R", nil
        failBindingReadSlot = 10
        local diskBefore, revisionBefore, consumersBefore = h.writes, Fishing.Authority.revision, Fishing.consumerCount
        local d = Fishing:DescribeDiagnosticDetail()
        assert(d.targetBuffs.rows[2].fields.buff_id == 91999 and d.targetBuffs.scannedCount == 2)
        assert(d.playerBuffs.rows[1].fields.buff_id == 91001 and d.playerDebuffs.rows[1].fields.buff_id == 91002)
        assert(d.backpack.slot == 27 and d.backpack.itemType == 92001 and d.backpack.status == "equipped")
        assert(d.target.stable == true and d.zone.value == 1 and d.combat.value == false)
        assert(d.hotkey.slots[8].isR == true and d.hotkey.slots[9].status == "unbound")
        assert(d.hotkey.slots[10].status == "unreadable" and #d.hotkey.slots == 12)
        assert(d.actionBarLayout.status == "captured_first_slot" and d.actionBarLayout.slotOffset == 0)
        assert(calls.imports == 1 and calls.equipment == 1)
        assert(findLog("set") == nil and findLog("remove") == nil and findLog("save_hotkey") == nil)
        assert(h.writes == diskBefore and Fishing.Authority.revision == revisionBefore and Fishing.consumerCount == consumersBefore)
        assert(d.observed ~= Fishing.Authority, "frozen evidence must not retain the mutable Authority table")
    end)
end)

Test("D2: Fishing report samples once; projection, summary and paging never trigger diagnostics", function()
    WithFishingDiagnostics(function(calls)
        Fishing:GetProjection()
        assert(S.ModuleDiagnosticsHub:BuildReport("life_fishing"))
        assert(calls.buffs == 0 and calls.imports == 0, "ordinary projection/summary must not sample diagnostic Native")
        local snapshot = assert(S.ModuleDiagnosticsHub:Capture("life_fishing", 900))
        assert(snapshot.exportReport:find("provider.fishing_action_evidence", 1, true))
        assert(snapshot.exportReport:find("92001", 1, true) and snapshot.exportReport:find("91002", 1, true))
        assert(calls.imports == 1, "one detailed report must sample fishing evidence exactly once")
        local samples = calls.buffs
        assert(S.ModuleDiagnosticsHub:GetPage(snapshot, 1))
        assert(S.ModuleDiagnosticsHub:Repage(snapshot, 700))
        assert(calls.buffs == samples and calls.imports == 1, "frozen report paging must not sample again")
    end)
end)

Test("D3: Disabled fishing diagnostics does not activate or import anything", function()
    WithFishingDiagnostics(function(calls)
        Fishing.enabled = false
        local consumersBefore = Fishing.consumerCount -- Demand允许“尚无投影”为nil；验证不取得新Consumer，而非强造零值。
        local d = Fishing:DescribeDiagnosticDetail()
        assert(d.liveStatus == "not_sampled_feature_disabled")
        assert(calls.buffs == 0 and calls.imports == 0 and calls.identity == 0 and #nativeLog == 0)
        assert(Fishing.consumerCount == consumersBefore)
    end)
end)

Test("D4: Missing API and bad reads remain unknown instead of empty or unbound", function()
    WithFishingDiagnostics(function()
        X2Unit.UnitBuffCount = function() error("buff count unavailable") end
        X2Equipment.GetEquippedItemType = function() error("equipment unavailable") end
        local d = Fishing:DescribeDiagnosticDetail()
        assert(d.targetBuffs.status == "unavailable" and d.targetBuffs.reportedCount == nil)
        assert(d.targetBuffs.error ~= nil and d.backpack.status == "unavailable" and d.backpack.itemType == nil)
        X2Equipment.GetEquippedItemType = function() return nil end
        S.ApiCapabilities:MarkRuntime("X2Equipment:GetEquippedItemType", "Unknown")
        _G.ES_BACKPACK = nil
        d = Fishing:DescribeDiagnosticDetail()
        assert(d.backpack.slot == 27 and d.backpack.status == "empty")
    end)
end)

Test("D5: Target changes and oversized buff lists are explicit in fishing evidence", function()
    WithFishingDiagnostics(function(calls)
        X2Unit.GetTargetUnitId = function() calls.identity = calls.identity + 1; return "fish:" .. calls.identity end
        for i = 2, 140 do targetBuffs[i] = { buff_id = 93000 + i } end
        local d = Fishing:DescribeDiagnosticDetail()
        assert(d.target.stable == false and d.target.status == "changed_during_capture")
        assert(d.targetBuffs.reportedCount == 140 and d.targetBuffs.scannedCount == 128 and d.targetBuffs.truncated == true)
        targetBuffs[1].buff_id = 1
        assert(d.targetBuffs.rows[1].fields.buff_id == 5264, "captured buff evidence must be detached")
    end)
end)

Test("D6: Diagnostic equipment import failure cannot block fishing or read an unowned API", function()
    WithFishingDiagnostics(function(calls)
        S.ApiImports.Acquire = function() return false, "equipment import rejected" end
        local d = Fishing:DescribeDiagnosticDetail()
        assert(d.backpack.status == "unavailable" and d.backpack.error == "equipment import rejected")
        assert(calls.equipment == 0 and Fishing.enabled == true)
        assert(d.targetBuffs.rows[1].fields.buff_id == 5264)
    end)
end)

Test("D7: Diagnostic history retains target switches, empty buff gaps and same-action recovery", function()
    WithFishingDiagnostics(function()
        WithArmedFishing("test:diagnostic-target-sequence", function()
            setFishBuff(nil)
            S.Events:Dispatch("TARGET_CHANGED", "target")
            setFishBuff(5264)
            S.Events:Dispatch("BUFF_UPDATE", "target")
            assert(S.Scheduler:RunTask("v3_life_fishing_event_refresh"))
            S.Events:Dispatch("TARGET_CHANGED", "target")
            assert(S.Scheduler:RunTask("v3_life_fishing_poll"))
            local writesBefore, diskBefore = Hotkey.stats.writes, h.writes
            local d = Fishing:DescribeDiagnosticDetail()
            assert(Hotkey.stats.writes == writesBefore and h.writes == diskBefore and Fishing:IsAutoArmed(),
                "capturing an armed session must not remap, restore, disarm or save")
            local gap, delayed, sameActionSwitch = false, false, false
            for _, row in ipairs(d.recentObservations.rows) do
                if row.reason == "target_changed" and row.buffId == nil and row.autoArmed == true then gap = true end
                if gap and row.reason == "buff_update" and row.buffId == 5264 and row.mappedSlot == 4 then delayed = true end
                if delayed and row.reason == "target_changed" and row.buffId == nil and row.mappedSlot == nil then sameActionSwitch = true end
            end
            assert(gap and delayed and sameActionSwitch, "history lost the target/buff transition being diagnosed")
            assert(#d.recentObservations.rows <= 32 and d.recentObservations.targetIdentityScope == "event_sequence_only")
            local capturedTotal = d.recentObservations.total
            for _ = 1, 40 do S.Events:Dispatch("TARGET_CHANGED", "target") end
            local full = Fishing:DescribeDiagnosticDetail()
            assert(#full.recentObservations.rows == 32 and full.recentObservations.dropped > 0)
            assert(d.recentObservations.total == capturedTotal and d.recentObservations.rows[#d.recentObservations.rows].sequence == capturedTotal
                and full.recentObservations.total > capturedTotal, "later events mutated already captured history")
        end)
    end)
end)

Test("D8: Zone, carried item and current-target buff combinations remain independently observable", function()
    WithFishingDiagnostics(function()
        for _, zone in ipairs({ 1, 49 }) do
            zoneGroup = zone
            for _, itemType in ipairs({ 0, 92001 }) do
                X2Equipment.GetEquippedItemType = function() return itemType end
                for _, buffId in ipairs({ 0, 5264, 5265 }) do
                    setFishBuff(buffId ~= 0 and buffId or nil)
                    local d = Fishing:DescribeDiagnosticDetail()
                    assert(d.zone.value == zone and d.backpack.status == (itemType == 0 and "empty" or "equipped"))
                    if buffId == 0 then assert(#d.candidateActions == 0)
                    else
                        local normalSlots, mirageSlots = { [5264] = 4, [5265] = 3 }, { [5264] = 3, [5265] = 2 }
                        local expected = (zone == 49 and mirageSlots or normalSlots)[buffId]
                        assert(d.candidateActions[1].buffId == buffId and d.candidateActions[1].slot == expected)
                    end
                    assert(d.actionBarLayout.slotOffset == 0, "carrying an item must not fabricate a shifted action slot")
                end
            end
        end
        -- 同一目标同时命中多个动作时保留Native顺序，便于核对现有“首个命中”规则。
        targetBuffs = { { buff_id = 5265 }, { buff_id = 5264 } }
        local d = Fishing:DescribeDiagnosticDetail()
        assert(#d.candidateActions == 2 and d.candidateActions[1].buffId == 5265 and d.candidateActions[2].buffId == 5264)
    end)
end)

Test("D9: A confirmed empty target is distinct from an unavailable identity getter", function()
    WithFishingDiagnostics(function()
        setFishBuff(nil)
        X2Unit.GetTargetUnitId = function() return nil end
        X2Unit.UnitName = function() return nil end
        local d = Fishing:DescribeDiagnosticDetail()
        assert(d.target.status == "no_target" and d.target.stable == true and #d.candidateActions == 0)
        X2Unit.UnitName = function() return "渔船梯子" end
        d = Fishing:DescribeDiagnosticDetail()
        assert(d.target.status == "named_target_without_unit_id" and d.target.stable == nil,
            "a named interactable without UnitId must not be reported as an empty target")
        X2Unit.GetTargetUnitId = function() error("identity read failed") end
        d = Fishing:DescribeDiagnosticDetail()
        assert(d.target.status == "identity_unavailable" and d.target.stable == nil)
    end)
end)

Test("D10: Owned hidden probe finds fishing in slot two without changing hotkeys or cached observations", function()
    WithFishingDiagnostics(function()
        local reads, creates = probeReads, probeCreates
        local observed = Copy(Fishing:GetProjection())
        firstModeSkill = 22538
        local d = Fishing:DescribeDiagnosticDetail()
        assert(d.actionBarLayout.releasePresent and d.actionBarLayout.firstSkillId == 22538)
        assert(d.actionBarLayout.releaseMatch == "fishing_anchor_slot_2"
            and d.actionBarLayout.fishingSlot == 2 and d.actionBarLayout.fishingSkillId == 21571)
        assert(d.actionBarLayout.slotOffset == 1 and d.candidateActions[1].baseSlot == 4 and d.candidateActions[1].slot == 5)
        assert(probeReads == reads + 8 and probeCreates == creates, "one detailed report reads eight slots using one inert probe")
        assert(not probeWidget.shown and not probeWidget.pickable and not probeWidget.established)
        assert(Fishing:GetProjection().slot == observed.slot, "explicit report must not change observation authority")
        assert(findLog("set") == nil and findLog("remove") == nil)
        firstModeSkill = nil
        d = Fishing:DescribeDiagnosticDetail()
        assert(d.actionBarLayout.slotOffset == nil and d.actionBarLayout.releasePresent == nil)
        assert(d.candidateActions[1].slot == nil and d.candidateActions[1].baseSlot == 4)
        failModeRead = true
        d = Fishing:DescribeDiagnosticDetail()
        assert(d.actionBarLayout.status == "unavailable" and d.backpack.status == "equipped")
        assert(not probeWidget.established, "failed reads must release the probe too")
    end)
end)

Test("D11: Fishing anchor drives offset while optional diagnostic tooltips preserve adjacent skill order", function()
    WithFishingDiagnostics(function()
        firstModeSkill = 22536
        modeRows = { [2] = { skillId = 21571, name = "钓鱼" }, [5] = { skillId = 90005, name = "向左拉" } }
        local tips, reads, writes = tooltipReads, probeReads, Hotkey.stats.writes
        local d = Fishing:DescribeDiagnosticDetail()
        local layout = d.actionBarLayout
        assert(layout.firstSkillId == 22536 and layout.slotOffset == 1 and layout.releaseMatch == "fishing_anchor_slot_2")
        assert(layout.fishingSkillId == 21571 and layout.fishingSlot == 2)
        assert(layout.firstSkillName == "测试技能名22536", "do not fabricate a release name for the trial ID")
        assert(layout.slots[2].skillId == 21571 and layout.slots[2].name == "钓鱼")
        assert(layout.slots[5].skillId == 90005 and layout.slots[5].name == "向左拉")
        assert(probeReads == reads + 8 and tooltipReads == tips + 3 and Hotkey.stats.writes == writes)
        assert(not probeWidget.established and not probeWidget.shown)
        failTooltip = true
        layout = Fishing:DescribeDiagnosticDetail().actionBarLayout
        assert(layout.firstSkillId == 22536 and layout.slotOffset == 1 and layout.slots[1].tooltipStatus == "unavailable")
        assert(layout.slots[1].tooltipError and not probeWidget.established, "failed optional tooltip must not abort or retain the probe")
        failTooltip = false
        -- 日常观察最多读取前两槽ID，不读取提示名。
        tips, reads = tooltipReads, probeReads
        assert(Fishing:AcquireConsumer("test:diagnostic-mode-neighbors"))
        assert(Fishing:Refresh("poll"))
        assert(tooltipReads == tips and probeReads == reads + 4)
        assert(Fishing:ReleaseConsumer("test:diagnostic-mode-neighbors"))
    end)
end)

Test("D12: RU slot 22548 is release evidence and the reported reel-out action shifts from five to six", function()
    WithFishingDiagnostics(function()
        firstModeSkill = 22548
        modeRows = { [2] = { skillId = 21571, name = "钓鱼" }, [3] = { skillId = 38924, name = "钓大鱼" } }
        setFishBuff(5267)
        local observed, writes, reads, tips = Copy(Fishing:GetProjection()), Hotkey.stats.writes, probeReads, tooltipReads
        local d = Fishing:DescribeDiagnosticDetail()
        local layout = d.actionBarLayout
        assert(layout.firstSkillId == 22548 and layout.firstSkillName == "放生" and layout.releasePresent,
            "the captured RU first-slot identity must be recognized as release")
        assert(layout.releaseMatch == "fishing_anchor_slot_2" and layout.fishingSkillId == 21571 and layout.fishingSlot == 2)
        assert(layout.slotOffset == 1 and d.candidateActions[1].buffId == 5267
            and d.candidateActions[1].baseSlot == 5 and d.candidateActions[1].slot == 6,
            "the reported reel-out action must address actual slot six while carrying fish")
        assert(probeReads == reads + 8 and tooltipReads == tips + 3 and Hotkey.stats.writes == writes)
        assert(Fishing:GetProjection().slot == observed.slot and not probeWidget.established,
            "diagnostic capture must remain read-only and release its slot probe")
    end)
end)

Test("T11: Registry exposes reversible Auto-R instead of runtime-block metadata", function()
    local text = ReadText("features/rs_feature_registry.lua")
    local block = text:match('Add%("life_fishing".-\n%}%)') or ""
    assert(block:find("Runtime Blocked", 1, true) == nil, "registry must not advertise fishing Auto-R as Runtime Blocked")
    assert(block:find("X2Hotkey:SetOptionBindingWithIndex", 1, true) ~= nil, "registry must declare hotkey write dependency")
    assert(block:find("demand_scoped_reversible_hotkey_transaction", 1, true) ~= nil, "registry must expose transaction policy")
end)

Test("T12: Fishing Hotkey v3 transaction is owned by the Feature acceptance, not the Foundation gate", function()
    local gate = ReadText("core/rs_foundation_gate.lua")
    assert(gate:find("life_fishing:auto_r_runtime_block", 1, true) == nil, "old runtime-block gate must be removed")
    -- 该契约的 Authority 已从
    -- Foundation 搬到 Feature 自己的 acceptance。断言强度不变，只是换成"Foundation 不得再拥有它，
    -- 而 acceptance 必须拥有它"——原来只证明契约存在，现在同时证明 Core 不再认识这个业务 Feature。
    assert(gate:find("life_fishing:auto_r_transaction", 1, true) == nil,
        "foundation must no longer own the fishing auto-R transaction contract")
    assert(gate:find("FishingHotkeyV3", 1, true) == nil,
        "foundation must no longer read the fishing hotkey service")
    local acceptance = ReadText("features/life/fishing/rs_fishing_acceptance.lua")
    assert(acceptance:find("v3_life_fishing_auto_r_transaction_contract", 1, true) ~= nil,
        "the acceptance must own the Auto-R transaction contract")
    assert(acceptance:find("FishingHotkeyV3", 1, true) ~= nil, "the acceptance must validate the transaction service")
    assert(acceptance:find("HotkeyContractVersion", 1, true) ~= nil, "the acceptance must validate the hotkey contract version")
    assert(acceptance:find("auto_r_hard_blocked", 1, true) ~= nil, "the acceptance must keep the no-hard-block assertion")
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
    local text = ReadText("../Docs/README.md") -- 当前文档根目录位于运行时插件目录之外。
    assert(text:find("Fishing full R source-slot enumeration/snapshot | SPECIFIC_RUNTIME_BLOCKED", 1, true) == nil, "README must remove obsolete fishing blocker")
    assert(text:find("HotkeyContractVersion = 3", 1, true) ~= nil, "README must record the v3 reversible transaction contract")
end)

Test("unchanged polls still scan native buffs but coalesce display revisions", function()
    resetNative();setFishBuff(5264)
    Fishing.State.autoPreference=false;Fishing.Authority.lastDisplayState=nil
    local scans=0;local original=X2Unit.UnitBuffCount
    X2Unit.UnitBuffCount=function(...)scans=scans+1;return original(...)end
    assert(Fishing.Authority:Refresh('poll'));local revision=Fishing.Authority.revision
    for i=1,10 do assert(Fishing.Authority:Refresh('poll'))end
    assert(scans==11 and Fishing.Authority.revision==revision,'same polls must scan without redrawing')
    setFishBuff(5265);assert(Fishing.Authority:Refresh('poll'))
    assert(scans==12 and Fishing.Authority.revision==revision+1 and Fishing.Authority.buffId==5265,'changed action must publish immediately')
    X2Unit.UnitBuffCount=original
end)

print(string.format("=== RESULT: %d/%d PASS ===", passed, total))
if passed ~= total then error(string.format("Fishing tests failed: %d/%d", passed, total)) end
