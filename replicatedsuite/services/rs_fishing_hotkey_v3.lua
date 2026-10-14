------------------------------------------------------------------------
-- Replicated Suite · 钓鱼热键恢复事务
-- 作者：Replicated
-- QQ群：1104129461
--
-- 钓鱼热键事务只拥有可逆动作栏按键修改；鱼/Buff/区域识别归 Fishing Feature，持久化归 v3.life.fishing Store
-- ，UI 只读 projection。无轮询、不拥有 UI、不另建 SaveData key。每次 Native 写通过 S.Api 能力门禁，只使用
-- OfficialEnabled Hotkey/PlayerInCombat，禁止 not-allowed getter。Feature 先完整槽位快照 -> 耐久 SaveData/
-- 读回 -> AdoptRecovery -> MoveR -> SaveHotKey -> Native 读回；首次写及首次触碰每个目标槽前都须持久化恢复快
-- 照。战斗状态读不到视为战斗中，不写热键；恢复可延至脱战但快照保留。空槽只能用 RemoveOptionBinding 精确恢复
-- ，接口不可用时拒绝 Arm。写失败不丢快照，精确恢复来源/目标且调用者清除耐久记录后才释放恢复权威。不能将服务
-- 变成轮询器、页面状态源或第二持久化权威。
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
        sameSlotChecks = 0, bindingDrifts = 0,
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
    -- read/set/save/战斗 guard 必需；仅快照目标未绑定时 Remove 才必需，BuildSessionSnapshot 进行精确预检。
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
    if slot == nil or self:IsCapabilityAllowed("X2Hotkey:GetOptionBinding") ~= true then return nil, false end
    slot = math.floor(slot)
    local readSucceeded = false
    for _, option in ipairs(self.ReadOptions) do
        self.stats.reads = (tonumber(self.stats.reads) or 0) + 1
        local ok, value = Call("X2Hotkey:GetOptionBinding", "X2Hotkey", "GetOptionBinding", self.ActionBar, 1, option, slot)
        if ok == true then readSucceeded = true end
        if ok == true and value ~= nil then
            local text = self:NormalizeBinding(value)
            if text ~= nil then return text, true end
        end
    end
    -- （2026-10-07）第二返回值区分“确实未绑定”和“Getter 全部失败”。
    -- 原有快照调用仍取第一返回值；同槽复核不能把读取失败当成缺键授权重写。
    return nil, readSucceeded
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

    -- （2026-10-07，发布复核）恢复依据必须是成功读取的原键位，
    -- 不把 Getter 失败补成 R/空槽；否则关闭时可能删除用户原有的非 R 按键。
    local sourceBinding, sourceReadOk = self:ReadActionSlotBinding(originalRSlot)
    if sourceReadOk ~= true then return nil, "原 R 槽位读取失败，拒绝建立恢复快照" end
    if self:IsR(sourceBinding) ~= true then return nil, "原 R 槽位读回不一致" end

    local snapshot = {
        contractVersion = self.SnapshotContractVersion,
        sourceSlot = originalRSlot,
        sourceBinding = sourceBinding,
        slots = {},
        touched = {},
    }
    for _, slot in ipairs(self.FishingSlots) do
        local binding, readOk = self:ReadActionSlotBinding(slot)
        if readOk ~= true then return nil, "槽位 " .. tostring(slot) .. " 读取失败，拒绝建立恢复快照" end
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
    local actual, readOk = self:ReadActionSlotBinding(slot)
    -- 未能读回与“确认空槽”不同；不能凭失败 nil
    -- 宣告恢复成功并清除 durable 快照，等待原生读回可验证后再完成恢复。
    if readOk ~= true then
        self.stats.readbackFailures = (tonumber(self.stats.readbackFailures) or 0) + 1
        return false, actual
    end
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
    -- （2026-10-07，多鱼切换）currentSlot 只记录上次成功事务，不证明原生
    -- 动作栏仍保留 R。切到另一条鱼（含相同 Buff），或切换事件后动作栏才重设时，
    -- 由现有 Feature 事件/100ms 兜底复核当前槽位；保持 R 时只读，丢失时重走原事务。
    -- 不清 currentSlot：它仍负责恢复上一槽位；不建新轮询，也不重复写稳定键位。
    if tonumber(self.currentSlot) == slot then
        self.stats.sameSlotChecks = (tonumber(self.stats.sameSlotChecks) or 0) + 1
        local binding, readOk = self:ReadActionSlotBinding(slot)
        if readOk ~= true then
            self.stats.moveFailures = self.stats.moveFailures + 1
            return false, "当前 R 槽位读取失败，拒绝重写"
        end
        if self:IsR(binding) then return true end
        self.stats.bindingDrifts = (tonumber(self.stats.bindingDrifts) or 0) + 1
    end
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
