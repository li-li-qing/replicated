------------------------------------------------------------------------
-- Replicated Suite V3 - Fishing Hotkey Transaction Service
--
-- Authority: this service owns ONLY reversible action-bar hotkey mutation for
-- the Fishing feature. Fish/Buff recognition stays in the Feature; persistence
-- stays in the Fishing store. The service never polls and never owns UI.
--
-- Maintenance contract (RU ArcheRage):
--   * Every Native write crosses S.Api capability gating.
--   * Combat is fail-closed: if PlayerInCombat cannot be read, no hotkey write.
--   * The caller MUST durably persist the recovery snapshot before the first
--     write and before first touching each destination slot.
--   * Empty original slots are restored with RemoveOptionBinding; if that API is
--     unavailable the transaction refuses to arm instead of guessing.
--   * A failed write never discards the snapshot. Recovery remains authoritative
--     until exact source/destination restoration succeeds and the caller clears
--     the durable record.
------------------------------------------------------------------------
-- 中文维护总约束（2026-09-13 Fishing Auto-R 恢复）：
-- 1) 问题原因：V3 重构曾把旧版可工作的自动 R 全局封死，只留下动作提示；用户侧表现就是“钓鱼功能没用”。
-- 2) Authority：本 Service 只拥有“动作栏按键的可逆事务”；鱼 Buff/区域判断属于 Fishing Feature，持久化属于 v3.life.fishing Store，UI 只能读 projection。
-- 3) 数据流：Feature 先构造完整槽位快照 -> durable SaveData/readback -> AdoptRecovery -> MoveR -> SaveHotKey -> Native readback；任一步失败都保留恢复权威。
-- 4) 兼容边界：只使用 core/rs_api_capabilities.lua 已 OfficialEnabled 的 Hotkey/PlayerInCombat 能力；禁止因为旧代码能调用就绕过 S.Api，也禁止读取 not-allowed Getter。
-- 5) 战斗边界：RU 对热键写 API 有战斗限制。无法可靠读取战斗状态时一律按“在战斗中”处理，不做任何写入；恢复可延迟到脱战，但恢复快照不能丢。
-- 6) 空槽边界：只有 RemoveOptionBinding 可用时才允许把 R 移入原本未绑定的槽；否则拒绝 Arm，避免关闭后无法精确还原用户键位。
-- 7) 维护风险：不要把本 Service 改成轮询器、页面状态源或独立 SaveData key；否则会重新制造双 Authority、常驻 CPU 和升级恢复不一致。
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
S.Services = S.Services or {}

local H = {
    Id = "v3.fishing_hotkey",
    version = 3,
    TransactionContractVersion = 3,
    SnapshotContractVersion = 3,
    ReadbackContractVersion = 1,
    presentationBoundary = "service_only",
    ActionBar = "mode_action_bar_button",
    ScanMax = 12,
    FishingSlots = { 2, 3, 4, 5, 6, 7 },
    ReadOptions = { false, true, 0, 1 },
    sessionSnapshot = nil,
    currentSlot = nil,
    pendingRecovery = false,
    stats = {
        reads = 0, writes = 0, removes = 0, saves = 0,
        readbackChecks = 0, readbackFailures = 0,
        moveAttempts = 0, moveFailures = 0,
        restoreAttempts = 0, restoreFailures = 0,
    },
}
S.Services.FishingHotkeyV3 = H

local function Copy(value)
    if S.Utils ~= nil and type(S.Utils.DeepCopy) == "function" then return S.Utils.DeepCopy(value) end
    if type(value) ~= "table" then return value end
    local out = {}
    for k, v in pairs(value) do out[k] = Copy(v) end
    return out
end

local function Host(name)
    return rawget(_G, tostring(name or ""))
end

local function Call(capability, hostName, method, ...)
    if S.Api == nil or type(S.Api.CallCapability) ~= "function" then return false, nil, "API boundary unavailable" end
    return S.Api:CallCapability(capability, Host(hostName), method, ...)
end

local function Action(capability, hostName, method, ...)
    if S.Api == nil or type(S.Api.ActionCapability) ~= "function" then return false, "API boundary unavailable" end
    return S.Api:ActionCapability(capability, Host(hostName), method, ...)
end

local function BindingText(value)
    if type(value) == "string" or type(value) == "number" then return tostring(value) end
    if type(value) == "table" then
        for _, key in ipairs({ "key", "binding", "text", "value", "name" }) do
            if type(value[key]) == "string" or type(value[key]) == "number" then return tostring(value[key]) end
        end
    end
    return nil
end

function H:NormalizeBinding(value)
    local text = BindingText(value)
    if text == nil then return nil end
    text = tostring(text):gsub("^%s+", ""):gsub("%s+$", "")
    if text == "" then return nil end
    return text
end

function H:IsR(value)
    local text = self:NormalizeBinding(value)
    if text == nil then return false end
    text = string.upper((text:gsub("%s+", "")))
    return text == "R" or text == "KEY_R"
end

function H:IsCapabilityAllowed(name)
    return S.Api ~= nil and type(S.Api.IsCapabilityAllowed) == "function" and S.Api:IsCapabilityAllowed(name) == true
end

function H:IsSupported()
    -- Maintenance: read + set + save + combat guard are mandatory. Remove is
    -- conditionally mandatory only when a snapshotted destination is unbound;
    -- BuildSessionSnapshot performs that exact preflight.
    for _, name in ipairs({
        "X2Hotkey:GetOptionBinding",
        "X2Hotkey:SetOptionBindingWithIndex",
        "X2Hotkey:SaveHotKey",
        "X2Player:PlayerInCombat",
    }) do
        if self:IsCapabilityAllowed(name) ~= true then return false, name .. " 未通过能力门" end
    end
    return true
end

function H:InCombat()
    if self:IsCapabilityAllowed("X2Player:PlayerInCombat") ~= true then return true end
    local ok, value = Call("X2Player:PlayerInCombat", "X2Player", "PlayerInCombat")
    if ok ~= true or value == nil then return true end
    return value == true
end

function H:ReadActionSlotBinding(slot)
    slot = tonumber(slot)
    if slot == nil or self:IsCapabilityAllowed("X2Hotkey:GetOptionBinding") ~= true then return nil end
    slot = math.floor(slot)
    for _, option in ipairs(self.ReadOptions) do
        self.stats.reads = (tonumber(self.stats.reads) or 0) + 1
        local ok, value = Call("X2Hotkey:GetOptionBinding", "X2Hotkey", "GetOptionBinding", self.ActionBar, 1, option, slot)
        if ok == true and value ~= nil then
            local text = self:NormalizeBinding(value)
            if text ~= nil then return text end
        end
    end
    return nil
end

function H:FindOriginalRSlot()
    for slot = 1, self.ScanMax do
        if self:IsR(self:ReadActionSlotBinding(slot)) then return slot end
    end
    return nil
end

function H:CanRemoveSlotBinding()
    return self:IsCapabilityAllowed("X2Hotkey:RemoveOptionBinding") == true
end

function H:BeginHotkeyEdit()
    if self:InCombat() then return false, "战斗中不能修改按键" end
    if self:IsCapabilityAllowed("X2Hotkey:SetOptionBindingWithIndex") ~= true then return false, "X2Hotkey:SetOptionBindingWithIndex 不可用" end
    if self:IsCapabilityAllowed("X2Hotkey:BindingToOption") == true then
        local ok, err = Action("X2Hotkey:BindingToOption", "X2Hotkey", "BindingToOption")
        if ok ~= true then return false, err end
    end
    return true
end

function H:SetSlotBindingNoSave(slot, key)
    slot, key = tonumber(slot), self:NormalizeBinding(key)
    if slot == nil then return false, "技能栏位置无效" end
    if key == nil then return false, "缺少按键，拒绝写入" end
    self.stats.writes = (tonumber(self.stats.writes) or 0) + 1
    return Action("X2Hotkey:SetOptionBindingWithIndex", "X2Hotkey", "SetOptionBindingWithIndex", self.ActionBar, key, 1, math.floor(slot))
end

function H:RemoveSlotBindingNoSave(slot)
    slot = tonumber(slot)
    if slot == nil then return false, "技能栏位置无效" end
    if self:CanRemoveSlotBinding() ~= true then return false, "X2Hotkey:RemoveOptionBinding 不可用" end
    self.stats.removes = (tonumber(self.stats.removes) or 0) + 1
    return Action("X2Hotkey:RemoveOptionBinding", "X2Hotkey", "RemoveOptionBinding", self.ActionBar, 1, math.floor(slot))
end

function H:SaveHotkeys()
    if self:IsCapabilityAllowed("X2Hotkey:SaveHotKey") ~= true then return false, "X2Hotkey:SaveHotKey 不可用" end
    self.stats.saves = (tonumber(self.stats.saves) or 0) + 1
    return Action("X2Hotkey:SaveHotKey", "X2Hotkey", "SaveHotKey")
end

function H:GetSnapshotSlot(snapshot, slot)
    snapshot = snapshot or self.sessionSnapshot
    if type(snapshot) ~= "table" or type(snapshot.slots) ~= "table" then return nil end
    slot = tonumber(slot)
    if slot == nil then return nil end
    return snapshot.slots[slot] or snapshot.slots[tostring(math.floor(slot))]
end

function H:BuildSessionSnapshot(originalRSlot)
    local supported, supportErr = self:IsSupported()
    if supported ~= true then return nil, supportErr end
    originalRSlot = tonumber(originalRSlot)
    if originalRSlot == nil then return nil, "原 R 槽位无效" end
    originalRSlot = math.floor(originalRSlot)

    local snapshot = {
        contractVersion = self.SnapshotContractVersion,
        sourceSlot = originalRSlot,
        sourceBinding = self:ReadActionSlotBinding(originalRSlot) or "R",
        slots = {},
        touched = {},
    }
    if self:IsR(snapshot.sourceBinding) ~= true then return nil, "原 R 槽位读回不一致" end

    for _, slot in ipairs(self.FishingSlots) do
        local binding = self:ReadActionSlotBinding(slot)
        if binding == nil and slot ~= originalRSlot and self:CanRemoveSlotBinding() ~= true then
            return nil, "槽位 " .. tostring(slot) .. " 原本未绑定按键，且 RemoveOptionBinding 不可用"
        end
        snapshot.slots[slot] = { slot = slot, binding = binding, wasUnbound = binding == nil }
    end
    if snapshot.slots[originalRSlot] == nil then
        snapshot.slots[originalRSlot] = { slot = originalRSlot, binding = snapshot.sourceBinding, wasUnbound = false }
    else
        snapshot.slots[originalRSlot].binding = snapshot.sourceBinding
        snapshot.slots[originalRSlot].wasUnbound = false
    end
    return snapshot
end

function H:RestoreSnapshotSlot(item)
    if type(item) ~= "table" then return false, "恢复记录无效" end
    if item.wasUnbound == true or self:NormalizeBinding(item.binding) == nil then
        return self:RemoveSlotBindingNoSave(item.slot)
    end
    return self:SetSlotBindingNoSave(item.slot, item.binding)
end

function H:BindingMatches(slot, expected)
    self.stats.readbackChecks = (tonumber(self.stats.readbackChecks) or 0) + 1
    local actual = self:ReadActionSlotBinding(slot)
    local wanted = self:NormalizeBinding(expected)
    local ok
    if wanted == nil then ok = actual == nil
    elseif self:IsR(wanted) then ok = self:IsR(actual)
    else ok = self:NormalizeBinding(actual) == wanted end
    if ok ~= true then self.stats.readbackFailures = (tonumber(self.stats.readbackFailures) or 0) + 1 end
    return ok, actual
end

function H:VerifySnapshotRestored(snapshot)
    local sourceSlot = tonumber(snapshot and snapshot.sourceSlot)
    if sourceSlot == nil then return false, "恢复记录缺少原 R 槽位" end
    local touched = type(snapshot.touched) == "table" and snapshot.touched or {}
    for slotKey, touchedValue in pairs(touched) do
        local slot = tonumber(slotKey)
        if touchedValue == true and slot ~= nil and slot ~= sourceSlot then
            local item = self:GetSnapshotSlot(snapshot, slot)
            if type(item) ~= "table" then return false, "槽位 " .. tostring(slot) .. " 缺少恢复记录" end
            local expected = item.wasUnbound == true and nil or item.binding
            local ok, actual = self:BindingMatches(slot, expected)
            if ok ~= true then return false, "槽位 " .. tostring(slot) .. " 恢复读回不一致:" .. tostring(actual) end
        end
    end
    local sourceOk, sourceActual = self:BindingMatches(sourceSlot, snapshot.sourceBinding or "R")
    if sourceOk ~= true then return false, "原 R 槽位恢复读回不一致:" .. tostring(sourceActual) end
    return true
end

function H:RestoreSnapshot(snapshot)
    if type(snapshot) ~= "table" then return true end
    self.stats.restoreAttempts = (tonumber(self.stats.restoreAttempts) or 0) + 1
    if self:InCombat() then self.pendingRecovery = true; return false, "战斗中不能恢复按键" end
    local sourceSlot = tonumber(snapshot.sourceSlot)
    if sourceSlot == nil then return false, "恢复记录缺少原 R 槽位" end

    local ok, err = self:BeginHotkeyEdit()
    if ok ~= true then self.stats.restoreFailures = (tonumber(self.stats.restoreFailures) or 0) + 1; return false, err end

    local touched = type(snapshot.touched) == "table" and snapshot.touched or {}
    for slotKey, touchedValue in pairs(touched) do
        local slot = tonumber(slotKey)
        if touchedValue == true and slot ~= nil and slot ~= sourceSlot then
            local item = self:GetSnapshotSlot(snapshot, slot)
            if type(item) ~= "table" then self.stats.restoreFailures = (tonumber(self.stats.restoreFailures) or 0) + 1; return false, "槽位 " .. tostring(slot) .. " 缺少恢复记录" end
            ok, err = self:RestoreSnapshotSlot(item)
            if ok ~= true then self.stats.restoreFailures = (tonumber(self.stats.restoreFailures) or 0) + 1; return false, err end
        end
    end

    ok, err = self:SetSlotBindingNoSave(sourceSlot, snapshot.sourceBinding or "R")
    if ok ~= true then self.stats.restoreFailures = (tonumber(self.stats.restoreFailures) or 0) + 1; return false, err end
    ok, err = self:SaveHotkeys()
    if ok ~= true then self.stats.restoreFailures = (tonumber(self.stats.restoreFailures) or 0) + 1; return false, err end
    ok, err = self:VerifySnapshotRestored(snapshot)
    if ok ~= true then self.stats.restoreFailures = (tonumber(self.stats.restoreFailures) or 0) + 1; return false, err end
    self.pendingRecovery = false
    self.currentSlot = nil
    return true
end

function H:AdoptRecovery(snapshot)
    if type(snapshot) ~= "table" or tonumber(snapshot.sourceSlot) == nil then return false, "恢复记录无效" end
    self.sessionSnapshot = Copy(snapshot)
    self.currentSlot = nil
    self.pendingRecovery = true
    return true
end

function H:ResetSession()
    self.sessionSnapshot = nil
    self.currentSlot = nil
    self.pendingRecovery = false
    return true
end

function H:IsRecoveryPending()
    return self.pendingRecovery == true or type(self.sessionSnapshot) == "table"
end

function H:MoveR(slot, persistTouch)
    self.stats.moveAttempts = (tonumber(self.stats.moveAttempts) or 0) + 1
    slot = tonumber(slot)
    if slot == nil then self.stats.moveFailures = self.stats.moveFailures + 1; return false, "技能栏位置无效" end
    slot = math.floor(slot)
    local snapshot = self.sessionSnapshot
    if type(snapshot) ~= "table" then self.stats.moveFailures = self.stats.moveFailures + 1; return false, "缺少钓鱼改键恢复快照" end
    if tonumber(self.currentSlot) == slot then return true end
    if self:InCombat() then self.pendingRecovery = true; self.stats.moveFailures = self.stats.moveFailures + 1; return false, "战斗中不能修改按键" end

    local sourceSlot = tonumber(snapshot.sourceSlot)
    local targetItem = self:GetSnapshotSlot(snapshot, slot)
    if slot ~= sourceSlot then
        if type(targetItem) ~= "table" then self.stats.moveFailures = self.stats.moveFailures + 1; return false, "槽位 " .. tostring(slot) .. " 没有备份记录" end
        if (targetItem.wasUnbound == true or self:NormalizeBinding(targetItem.binding) == nil) and self:CanRemoveSlotBinding() ~= true then
            self.stats.moveFailures = self.stats.moveFailures + 1
            return false, "槽位 " .. tostring(slot) .. " 原本未绑定按键，且 RemoveOptionBinding 不可用"
        end
        if snapshot.touched[slot] ~= true and snapshot.touched[tostring(slot)] ~= true then
            if type(persistTouch) ~= "function" then self.stats.moveFailures = self.stats.moveFailures + 1; return false, "缺少恢复快照持久化回调" end
            local nextSnapshot = Copy(snapshot)
            nextSnapshot.touched[slot] = true
            local persisted, persistErr = persistTouch(nextSnapshot)
            if persisted ~= true then self.stats.moveFailures = self.stats.moveFailures + 1; return false, persistErr or "恢复快照持久化失败" end
            self.sessionSnapshot = nextSnapshot
            snapshot = nextSnapshot
        end
    end

    local ok, err = self:BeginHotkeyEdit()
    if ok ~= true then self.stats.moveFailures = self.stats.moveFailures + 1; return false, err end

    local previousSlot = tonumber(self.currentSlot)
    if previousSlot ~= nil and previousSlot ~= sourceSlot then
        local previousItem = self:GetSnapshotSlot(snapshot, previousSlot)
        if type(previousItem) ~= "table" then self.stats.moveFailures = self.stats.moveFailures + 1; return false, "上一个槽位缺少恢复记录" end
        ok, err = self:RestoreSnapshotSlot(previousItem)
        if ok ~= true then self.stats.moveFailures = self.stats.moveFailures + 1; return false, err end
    end

    ok, err = self:SetSlotBindingNoSave(sourceSlot, snapshot.sourceBinding or "R")
    if ok ~= true then self.stats.moveFailures = self.stats.moveFailures + 1; return false, err end
    if slot ~= sourceSlot then
        ok, err = self:SetSlotBindingNoSave(slot, "R")
        if ok ~= true then self.stats.moveFailures = self.stats.moveFailures + 1; return false, err end
    end
    ok, err = self:SaveHotkeys()
    if ok ~= true then self.stats.moveFailures = self.stats.moveFailures + 1; return false, err end

    local targetOk, actual = self:BindingMatches(slot, "R")
    if targetOk ~= true then self.stats.moveFailures = self.stats.moveFailures + 1; return false, "R 写入读回失败:" .. tostring(actual) end
    if previousSlot ~= nil and previousSlot ~= sourceSlot and previousSlot ~= slot then
        local previousItem = self:GetSnapshotSlot(snapshot, previousSlot)
        local expected = previousItem and (previousItem.wasUnbound == true and nil or previousItem.binding) or nil
        local previousOk, previousActual = self:BindingMatches(previousSlot, expected)
        if previousOk ~= true then self.stats.moveFailures = self.stats.moveFailures + 1; return false, "上一个槽位恢复读回失败:" .. tostring(previousActual) end
    end

    self.currentSlot = slot
    self.pendingRecovery = true
    return true
end

function H:GetDiagnostics()
    return {
        version = self.version,
        contract = self.TransactionContractVersion,
        currentSlot = self.currentSlot,
        recoveryPending = self:IsRecoveryPending(),
        sourceSlot = type(self.sessionSnapshot) == "table" and self.sessionSnapshot.sourceSlot or nil,
        stats = Copy(self.stats),
    }
end
