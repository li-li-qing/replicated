------------------------------------------------------------------------
-- Replicated Suite - Smart Fishing Helper
--
-- Auto-R is a reversible hotkey transaction:
--   1) Read the current R source slot and snapshot every fishing target slot.
--   2) Before moving R, restore the previously occupied target slot first.
--   3) Re-establish R on its original source, then move it to the next target.
--   4) Disable/close/world-change restores every touched slot plus the R source.
--   5) A persisted recovery snapshot repairs keys after an unexpected addon reload.
--
-- Empty destination slots are supported only when the current client exposes
-- RemoveOptionBinding, so the pre-session binding state remains exactly restorable.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end

local S = ReplicatedSuite
S.Services = S.Services or {}
S.Services.Fishing = {
    autoArmed = false,
    originalRSlot = nil,
    currentSlot = nil,
    sessionSnapshot = nil,
    pendingCombatRestore = false,
}
local F = S.Services.Fishing

local ACTION_BAR = "mode_action_bar_button"
local ACTION_SCAN_MAX = 12
local RECOVERY_KEY = tostring(S.SaveKey or "replicated_suite_v1") .. "_fishing_hotkey_recovery"
local READ_OPTIONS = { false, true, 0, 1 }

local NORMAL = { [5264] = 4, [5265] = 3, [5267] = 5, [5266] = 6, [5508] = 7 }
local MIRAGE = { [5264] = 3, [5265] = 2, [5267] = 4, [5266] = 5, [5508] = 6 }
local BUFF_LABEL = { [5264] = "向左拉", [5265] = "向右拉", [5267] = "放线", [5266] = "收线", [5508] = "提竿" }
local FISHING_SLOTS = { 2, 3, 4, 5, 6, 7 }

local function BindingText(value)
    if type(value) == "string" or type(value) == "number" then return tostring(value) end
    if type(value) == "table" then
        for _, key in ipairs({ "key", "binding", "text", "value", "name" }) do
            if type(value[key]) == "string" or type(value[key]) == "number" then return tostring(value[key]) end
        end
    end
    return nil
end

-- Combat guard for the auto-R hotkey transaction (RU 2026-08-19: the four
-- hotkey write APIs are restricted in combat). Uses the capability boundary
-- with a safe read; when the read is unavailable or fails, the write path
-- must fail closed (treat as in-combat).
function F:InCombat()
    if S.Api == nil or type(S.Api.IsCapabilityAllowed) ~= "function"
        or S.Api:IsCapabilityAllowed("X2Player:PlayerInCombat") ~= true then
        return true  -- fail closed: no safe combat read -> no hotkey writes
    end
    local ok, inCombat = S.Api:CallCapability("X2Player:PlayerInCombat", X2Player, "PlayerInCombat")
    if ok ~= true or inCombat == nil then return true end
    return inCombat == true
end

local function NormalizeBinding(value)
    local text = BindingText(value)
    if text == nil then return nil end
    text = tostring(text):gsub("^%s+", ""):gsub("%s+$", "")
    if text == "" then return nil end
    return text
end

local function IsR(value)
    local text = NormalizeBinding(value)
    if text == nil then return false end
    text = string.upper((text:gsub("%s+", "")))
    return text == "R" or text == "KEY_R"
end

function F:ReadActionSlotBinding(slot)
    if S.Api == nil or type(S.Api.IsCapabilityAllowed) ~= "function"
        or S.Api:IsCapabilityAllowed("X2Hotkey:GetOptionBinding") ~= true then return nil end
    for _, option in ipairs(READ_OPTIONS) do
        local ok, value = S.Api:CallCapability("X2Hotkey:GetOptionBinding", X2Hotkey, "GetOptionBinding", ACTION_BAR, 1, option, slot)
        if ok and value ~= nil then
            local text = NormalizeBinding(value)
            if text ~= nil then return text end
        end
    end
    return nil
end

function F:FindOriginalRSlot()
    for slot = 1, ACTION_SCAN_MAX do
        local binding = self:ReadActionSlotBinding(slot)
        if IsR(binding) then return slot end
    end
    return nil
end

function F:BeginHotkeyEdit()
    if self:InCombat() then
        return false, "战斗中不能修改按键"
    end
    if S.Api == nil or type(S.Api.IsCapabilityAllowed) ~= "function"
        or S.Api:IsCapabilityAllowed("X2Hotkey:SetOptionBindingWithIndex") ~= true then
        return false, "X2Hotkey 不可用"
    end
    if S.Api:IsCapabilityAllowed("X2Hotkey:BindingToOption") == true then
        local ok, result = S.Api:ActionCapability("X2Hotkey:BindingToOption", X2Hotkey, "BindingToOption")
        if not ok then return false, result end
    end
    return true
end

function F:SetSlotBindingNoSave(slot, key)
    slot = tonumber(slot)
    key = NormalizeBinding(key)
    if slot == nil then return false, "技能栏位置无效" end
    if key == nil then return false, "缺少原按键，无法安全恢复" end
    return S.Api:ActionCapability("X2Hotkey:SetOptionBindingWithIndex", X2Hotkey, "SetOptionBindingWithIndex", ACTION_BAR, key, 1, math.floor(slot))
end

function F:CanRemoveSlotBinding()
    return S.Api ~= nil and type(S.Api.IsCapabilityAllowed) == "function"
        and S.Api:IsCapabilityAllowed("X2Hotkey:RemoveOptionBinding") == true
end

function F:RemoveSlotBindingNoSave(slot)
    slot = tonumber(slot)
    if slot == nil then return false, "技能栏位置无效" end
    if not self:CanRemoveSlotBinding() then return false, "RemoveOptionBinding 不可用" end
    return S.Api:ActionCapability("X2Hotkey:RemoveOptionBinding", X2Hotkey, "RemoveOptionBinding", ACTION_BAR, 1, math.floor(slot))
end

function F:RestoreSnapshotSlot(item)
    if type(item) ~= "table" then return true end
    if item.wasUnbound == true or NormalizeBinding(item.binding) == nil then
        return self:RemoveSlotBindingNoSave(item.slot)
    end
    return self:SetSlotBindingNoSave(item.slot, item.binding)
end

function F:SaveHotkeys()
    if S.Api ~= nil and type(S.Api.IsCapabilityAllowed) == "function"
        and S.Api:IsCapabilityAllowed("X2Hotkey:SaveHotKey") == true then
        local ok, result = S.Api:ActionCapability("X2Hotkey:SaveHotKey", X2Hotkey, "SaveHotKey")
        if not ok then return false, result end
    end
    return true
end

function F:BuildSessionSnapshot(originalRSlot)
    originalRSlot = tonumber(originalRSlot)
    if originalRSlot == nil then return nil, "原 R 槽位无效" end

    local snapshot = {
        sourceSlot = math.floor(originalRSlot),
        sourceBinding = "R",
        slots = {},
        touched = {},
    }

    for _, slot in ipairs(FISHING_SLOTS) do
        local binding = self:ReadActionSlotBinding(slot)
        snapshot.slots[slot] = {
            slot = slot,
            binding = binding,
            wasUnbound = binding == nil,
        }
    end

    -- The R source may be outside the fishing target range. Keep it explicitly
    -- so final restore is independent from whichever slot happened to be active.
    if snapshot.slots[snapshot.sourceSlot] == nil then
        local binding = self:ReadActionSlotBinding(snapshot.sourceSlot)
        snapshot.slots[snapshot.sourceSlot] = {
            slot = snapshot.sourceSlot,
            binding = binding,
            wasUnbound = binding == nil,
        }
    end
    snapshot.slots[snapshot.sourceSlot].binding = snapshot.slots[snapshot.sourceSlot].binding or "R"

    return snapshot
end

function F:GetSnapshotSlot(slot)
    local snapshot = self.sessionSnapshot
    if type(snapshot) ~= "table" or type(snapshot.slots) ~= "table" then return nil end
    return snapshot.slots[tonumber(slot)]
end

function F:WriteRecovery(snapshot)
    if type(snapshot) ~= "table" then return false end
    local payload = {
        pending = true,
        snapshot = S.Utils and S.Utils.DeepCopy and S.Utils.DeepCopy(snapshot) or snapshot,
    }
    local ok = S.Api:SaveData(RECOVERY_KEY, payload)
    return ok == true
end

function F:ClearRecovery()
    S.Api:SaveData(RECOVERY_KEY, { pending = false })
end

function F:LoadRecovery()
    local value = S.Api:LoadData(RECOVERY_KEY)
    if type(value) == "table" and value.pending == true and type(value.snapshot) == "table" then
        return value.snapshot
    end
    return nil
end

function F:RestoreSnapshot(snapshot)
    if type(snapshot) ~= "table" then return true end
    local sourceSlot = tonumber(snapshot.sourceSlot)
    if sourceSlot == nil then return false, "恢复记录缺少原 R 槽位" end

    local ok, err = self:BeginHotkeyEdit()
    if not ok then return false, err end

    local touched = type(snapshot.touched) == "table" and snapshot.touched or {}
    local slots = type(snapshot.slots) == "table" and snapshot.slots or {}

    -- Restore every destination that this session actually modified. Do not
    -- rewrite untouched slots, so unrelated user key changes remain intact.
    for slotKey, wasTouched in pairs(touched) do
        local slot = tonumber(slotKey)
        if wasTouched == true and slot ~= nil and slot ~= sourceSlot then
            local item = slots[slot] or slots[slotKey]
            if type(item) ~= "table" then return false, "槽位 " .. tostring(slot) .. " 缺少恢复记录" end
            item.slot = tonumber(item.slot) or slot
            ok, err = self:RestoreSnapshotSlot(item)
            if not ok then return false, err end
        end
    end

    ok, err = self:SetSlotBindingNoSave(sourceSlot, snapshot.sourceBinding or "R")
    if not ok then return false, err end

    ok, err = self:SaveHotkeys()
    if not ok then return false, err end
    return true
end

function F:RecoverPendingOnLoad()
    local snapshot = self:LoadRecovery()
    if snapshot == nil then return true end
    -- Combat guard: never write hotkeys in combat, even during addon-reload
    -- recovery. Keep the recovery Authority and let the poll restore later.
    if self:InCombat() then
        self.sessionSnapshot = snapshot
        self.pendingCombatRestore = true
        S.SafeChat("检测到未完成的钓鱼改键，但当前在战斗中，脱战后自动恢复。")
        return false
    end
    local ok, err = self:RestoreSnapshot(snapshot)
    if ok then
        self:ClearRecovery()
        S.SafeChat("检测到上次未完成的钓鱼改键，已恢复原按键。")
        return true
    end
    S.SafeChat("检测到未完成的钓鱼改键，但自动恢复失败：" .. tostring(err))
    return false
end

function F:SetRSlot(slot)
    slot = tonumber(slot)
    if slot == nil then return false, "技能栏位置无效" end
    slot = math.floor(slot)

    local snapshot = self.sessionSnapshot
    if type(snapshot) ~= "table" then return false, "缺少钓鱼改键快照" end
    if tonumber(self.currentSlot) == slot then return true end

    local sourceSlot = tonumber(snapshot.sourceSlot)
    local targetItem = self:GetSnapshotSlot(slot)
    if slot ~= sourceSlot then
        if targetItem == nil then return false, "槽位 " .. tostring(slot) .. " 没有备份记录" end
        if NormalizeBinding(targetItem.binding) == nil and not self:CanRemoveSlotBinding() then
            return false, "槽位 " .. tostring(slot) .. " 原本未绑定按键，且 RemoveOptionBinding 不可用"
        end

        -- Commit recovery intent only the first time this destination is ever
        -- touched in the session. This keeps persistent writes bounded to at
        -- most one write per fishing slot instead of writing every poll/change.
        if snapshot.touched[slot] ~= true then
            snapshot.touched[slot] = true
            if not self:WriteRecovery(snapshot) then
                snapshot.touched[slot] = nil
                return false, "无法保存改键恢复快照，因此拒绝修改按键"
            end
        end
    end

    local ok, err = self:BeginHotkeyEdit()
    if not ok then return false, err end

    -- First restore the slot R occupied during the previous fishing action.
    local previousSlot = tonumber(self.currentSlot)
    if previousSlot ~= nil and previousSlot ~= sourceSlot then
        local previousItem = self:GetSnapshotSlot(previousSlot)
        if type(previousItem) ~= "table" then return false, "上一个槽位缺少恢复记录" end
        ok, err = self:RestoreSnapshotSlot(previousItem)
        if not ok then return false, err end
    end

    -- Re-establish the original R source before moving R to the new target.
    -- This prevents the client-side one-key-one-binding rule from leaving the
    -- previous destination in an orphaned state.
    ok, err = self:SetSlotBindingNoSave(sourceSlot, snapshot.sourceBinding or "R")
    if not ok then return false, err end

    if slot ~= sourceSlot then
        ok, err = self:SetSlotBindingNoSave(slot, "R")
        if not ok then return false, err end
    end

    ok, err = self:SaveHotkeys()
    if not ok then return false, err end

    self.currentSlot = slot
    return true
end

function F:ArmAuto()
    if self.autoArmed then return true end
    if self:InCombat() then
        S.SafeChat("战斗中不能修改按键，自动 R 未启用。")
        return false
    end

    -- A failed restore keeps the original snapshot in memory. Never overwrite
    -- that Authority with a snapshot of already-modified hotkeys.
    if type(self.sessionSnapshot) == "table" then
        if not self:DisarmAuto(false) then return false end
    end

    local original = self:FindOriginalRSlot()
    if original == nil then
        S.SafeChat("钓鱼自动R未启用：无法可靠读取当前 R 键所在动作栏位置，因此不会修改键位。")
        return false
    end

    local snapshot, err = self:BuildSessionSnapshot(original)
    if snapshot == nil then
        S.SafeChat("钓鱼自动R未启用：" .. tostring(err))
        return false
    end

    self.originalRSlot = original
    self.sessionSnapshot = snapshot
    self.autoArmed = true
    self.currentSlot = nil
    if not self:WriteRecovery(snapshot) then
        self.originalRSlot = nil
        self.sessionSnapshot = nil
        self.autoArmed = false
        S.SafeChat("钓鱼自动R未启用：无法保存恢复快照，因此不会修改键位。")
        return false
    end

    S.State.data.fishing.auto = true
    S.State.data.fishing.message = "自动R已启用 · 原R槽位 " .. tostring(original)
    S.State:MarkDirty("fishing")
    self:Poll(true)
    return true
end

function F:DisarmAuto(silent)
    local snapshot = self.sessionSnapshot
    if self.autoArmed ~= true and type(snapshot) ~= "table" then
        S.State.data.fishing.auto = false
        return true
    end

    -- Combat guard: while in combat the hotkey write APIs are restricted, so
    -- we never write keys here. We keep the snapshot/recovery Authority and
    -- mark a pending restore; the poll loop restores once combat ends. The
    -- auto-R flag is turned off so the poll never issues new writes either.
    if self:InCombat() and type(snapshot) == "table" then
        self.autoArmed = false
        self.pendingCombatRestore = true
        S.State.data.fishing.auto = false
        S.State.data.fishing.message = "战斗中不能改键 · 等待脱战恢复"
        S.State:MarkDirty("fishing")
        if silent ~= true then
            S.SafeChat("战斗中不能修改按键，原按键将在脱战后自动恢复。")
        end
        return false
    end

    local restored, err = true, nil
    if type(snapshot) == "table" then restored, err = self:RestoreSnapshot(snapshot) end

    self.autoArmed = false
    self.pendingCombatRestore = false
    S.State.data.fishing.auto = false

    if restored then
        self.originalRSlot = nil
        self.currentSlot = nil
        self.sessionSnapshot = nil
        self:ClearRecovery()
        S.State.data.fishing.message = "自动R已关闭 · 已恢复原按键"
    else
        -- Keep the snapshot/recovery Authority so a retry or next addon load
        -- can still restore the exact pre-fishing bindings.
        S.State.data.fishing.message = "自动R已关闭 · 恢复按键失败"
    end
    S.State:MarkDirty("fishing")

    if silent ~= true and not restored then
        S.SafeChat("钓鱼助手关闭时未能恢复原按键：" .. tostring(err))
    end
    return restored
end

function F:ToggleAuto()
    if self.autoArmed then return self:DisarmAuto(false) end
    return self:ArmAuto()
end

function F:Detect()
    if S.Api == nil or type(S.Api.IsCapabilityAllowed) ~= "function"
        or S.Api:IsCapabilityAllowed("X2Unit:UnitBuffCount") ~= true
        or S.Api:IsCapabilityAllowed("X2Unit:UnitBuff") ~= true then return nil, nil end
    local ok, count = S.Api:CallCapability("X2Unit:UnitBuffCount", X2Unit, "UnitBuffCount", "target")
    count = ok and tonumber(count) or nil
    if count == nil or count <= 0 then return nil, nil end

    local okZone, zoneId = S.Api:CallCapability("X2Unit:GetCurrentZoneGroup", X2Unit, "GetCurrentZoneGroup")
    local map = (okZone and tonumber(zoneId) == 49) and MIRAGE or NORMAL
    for i = 1, math.min(128, math.floor(count)) do
        local okBuff, buff = S.Api:CallCapability("X2Unit:UnitBuff", X2Unit, "UnitBuff", "target", i)
        if okBuff and type(buff) == "table" then
            local id = tonumber(buff.buff_id or buff.buffId or buff.type or buff.id)
            local slot = id and map[id] or nil
            if slot ~= nil then return id, slot end
        end
    end
    return nil, nil
end

function F:Poll(force)
    local place = S.State.ui and S.State.ui.widgets and S.State.ui.widgets.fishing
    -- A pending combat restore must keep polling even when the HUD is hidden:
    -- the original key bindings are only repaired once combat ends.
    if force ~= true and self.autoArmed ~= true and self.pendingCombatRestore ~= true
        and (place == nil or place.visible ~= true) then return end

    -- Combat transition handling: while in combat we never issue hotkey writes
    -- (RU 2026-08-19 restriction). If an armed session enters combat, we stop
    -- switching and flag a pending restore; once combat ends we restore the
    -- original bindings exactly once and clear the recovery.
    if self.pendingCombatRestore == true and not self:InCombat() then
        local snapshot = self.sessionSnapshot
        if type(snapshot) == "table" then
            local restored, err = self:RestoreSnapshot(snapshot)
            if restored then
                self.pendingCombatRestore = false
                self.autoArmed = false
                self.originalRSlot = nil
                self.currentSlot = nil
                self.sessionSnapshot = nil
                self:ClearRecovery()
                S.State.data.fishing.message = "自动R已关闭 · 脱战后已恢复原按键"
                S.State:MarkDirty("fishing")
                S.SafeChat("脱战后已恢复原按键。")
            else
                S.State.data.fishing.message = "自动R已关闭 · 脱战恢复失败：" .. tostring(err)
                S.State:MarkDirty("fishing")
            end
        else
            self.pendingCombatRestore = false
        end
    end

    if self.autoArmed and place and place.visible ~= true then
        self:DisarmAuto(true)
        return
    end
    if self.autoArmed and self:InCombat() then
        -- In combat: zero hotkey writes. Keep the snapshot/recovery and flag a
        -- pending restore for the out-of-combat poll tick.
        self.pendingCombatRestore = true
        local d0 = S.State.data.fishing
        if d0.message ~= "战斗中不能改键 · 等待脱战恢复" then
            d0.message = "战斗中不能改键 · 等待脱战恢复"
            S.State:MarkDirty("fishing")
        end
        return
    end

    local id, slot = self:Detect()
    local d = S.State.data.fishing
    local changed = d.buffId ~= id or d.slot ~= slot or d.auto ~= (self.autoArmed == true)
    d.buffId = id
    d.slot = slot
    d.auto = self.autoArmed == true

    if id ~= nil then
        d.status = "ready"
        d.message = (BUFF_LABEL[id] or ("Buff " .. tostring(id))) .. " · 技能栏 " .. tostring(slot)
        if self.autoArmed and self.currentSlot ~= slot then
            local okSet, setErr = self:SetRSlot(slot)
            if not okSet then
                local reason = "自动R设置失败：" .. tostring(setErr)
                local restored = self:DisarmAuto(true)
                d.status = "error"
                d.message = reason .. (restored and " · 已恢复原按键" or " · 恢复按键也失败")
                S.SafeChat(d.message)
                S.State:MarkDirty("fishing")
                return
            end
        end
    else
        d.status = "waiting"
        d.message = self.autoArmed and "等待鱼的动作Buff · R保持当前映射" or "选中正在挣扎的鱼后显示推荐技能"
    end

    if changed or force == true then S.State:MarkDirty("fishing") end
end

function F:Stop()
    self:DisarmAuto(true)
end

function F:Start()
    self:RecoverPendingOnLoad()
    S.Events:Subscribe("ENTERED_WORLD", self, function()
        F:DisarmAuto(true)
        F:Poll(true)
    end)
    S.Events:Subscribe("ENTER_ANOTHER_ZONEGROUP", self, function()
        F:DisarmAuto(true)
        F:Poll(true)
    end)
    S.Scheduler:AddTask("fishing_poll", S.Constants.Refresh.fishingPollMs or 500, function() F:Poll(false) end, false, self, "P2")
    self:Poll(true)
end
