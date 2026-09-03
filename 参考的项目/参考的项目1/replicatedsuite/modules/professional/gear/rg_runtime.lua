ReplicatedSuiteModuleSandbox:Enter('gear', {'ReplicatedGear', 'ReplicatedGearConfig'})
------------------------------------------------------------------------
-- Replicated Gear - Swap queue runtime
------------------------------------------------------------------------

if ReplicatedGear == nil or ReplicatedGear.BootError ~= nil or ReplicatedGear.UI == nil or ReplicatedGear.Core == nil then return end
local G = ReplicatedGear
local C = G.Core
local A = G.Api
local U = G.UI
local runtimeGeneration = G.Generation

G.Runtime = {
    generation = runtimeGeneration,
    session = nil,
    busy = false,
    index = 1,
    stage = "IDLE",
    nextAt = 0,
    stageStartedAt = 0,
    sessionStartedAt = 0,
    elapsedMs = 0,
    currentStep = nil,

    -- Runtime scheduling deliberately uses OnUpdate(dt), not
    -- UI:GetCurrentTimeStamp().  Some ArcheRage builds expose the official
    -- timestamp API but do not advance it reliably inside Addon UI execution.
    -- A frozen timestamp used to leave rc4 forever in VERIFY after the first
    -- EquipBagItem call.
    -- Fast path: a normally accepted equip should be confirmed on the next
    -- few frames and immediately advance.  The old rc15 timings imposed about
    -- 360ms of artificial latency per successful item (190ms verify + 170ms
    -- inter-item delay), which made an 8-piece loadout feel much slower than
    -- manual clicking.  Keep the normal path fast, while retaining a longer
    -- bounded slow path only when the client has not reflected the change yet.
    actionDelayMs = 0,
    -- Public GearSwap currently waits >200ms before issuing EquipBagItem.  Do the
    -- same for the weapon compatibility path instead of firing at t=0 directly
    -- into a possible previous EquipBagItem cooldown window.
    initialWeaponDelayMs = 220,
    verifyDelayMs = 40,
    verifyPollMs = 70,
    maxVerifyPolls = 7,
    -- Weapon work follows the current community GearSwap transaction model:
    -- issue one EquipBagItem at a time, then reconcile the missing weapon set.
    -- The API's published cooldown was 100ms; current GearSwap intentionally uses
    -- a 200ms cadence.  220ms gives a small frame/scheduler margin and avoids
    -- sitting exactly on the server cooldown boundary.
    weaponInterActionDelayMs = 220,
    weaponPassVerifyDelayMs = 220,
    weaponRetryDelayMs = 220,
    maxWeaponActionAttempts = 3,
    maxWeaponDependencyDeferrals = 2,
    finalVerifyPollMs = 90,
    maxFinalVerifyPolls = 2,
    titleVerifyPollMs = 100,
    -- 500ms verification window (report 八-P0-2): 100ms x 5 polls. The RU title
    -- change API can take several polls to reflect; wider window than titleswap's
    -- single read-back, still far below stageTimeoutMs.
    maxTitleVerifyPolls = 5,

    -- Hard safety budgets.  No stage is allowed to remain in "切换中"
    -- forever even if a client API becomes inconsistent.
    stageTimeoutMs = 8000,
    sessionTimeoutMs = 60000,
    maxUpdateDeltaMs = 1000,
    defaultUpdateDeltaMs = 16,

    finalVerifyPolls = 0,
    titleVerifyPolls = 0,
}
local R = G.Runtime

function R:IsBusy() return self.busy == true end

local function FiniteNumber(value)
    local n = tonumber(value)
    if n == nil or n ~= n or n == math.huge or n == -math.huge then return nil end
    return n
end

local function DeltaMs(dt, fallback, maximum)
    local n = FiniteNumber(dt)
    if n == nil or n <= 0 then return fallback end
    -- ArcheRage addon examples exist with OnUpdate dt treated as milliseconds,
    -- while some UI runtimes conventionally deliver fractional seconds.  Accept
    -- both forms: 0.016 -> 16ms, 16 -> 16ms.
    if n > 0 and n < 1 then n = n * 1000 end
    if n < 1 then n = 1 end
    if n > maximum then n = maximum end
    return n
end

local function DescribeBlocked(session)
    local items = {}
    for _, item in ipairs(session.missing or {}) do
        items[#items + 1] = tostring(item.slotName or "装备") .. ":" .. tostring(item.name or "未知")
    end
    for _, item in ipairs(session.ambiguous or {}) do
        items[#items + 1] = tostring(item.slotName or "装备") .. ":" .. tostring(item.name or "未知") .. "(同名歧义)"
    end
    for _, item in ipairs(session.readErrors or {}) do
        items[#items + 1] = tostring(item.slotName or "装备") .. ":" .. tostring(item.name or "未知") .. "(背包读取不完整)"
    end
    for _, item in ipairs(session.reposition or {}) do
        items[#items + 1] = tostring(item.slotName or "装备") .. ":" .. tostring(item.name or "未知") .. "(当前穿在其他槽)"
    end
    return table.concat(items, "、")
end

function R:RuntimeNow()
    return math.max(0, FiniteNumber(self.elapsedMs) or 0)
end

function R:Schedule(stage, now, delayMs)
    now = FiniteNumber(now) or self:RuntimeNow()
    stage = tostring(stage or "IDLE")
    if self.stage ~= stage then
        self.stageStartedAt = now
    end
    self.stage = stage
    self.nextAt = now + math.max(0, FiniteNumber(delayMs) or 0)
end

function R:ReportProgress(phase)
    if type(U.OnRuntimeProgress) ~= "function" then return end
    local session = self.session
    if session == nil then return end
    pcall(function()
        U:OnRuntimeProgress(session, self.index, #(session.queue or {}), phase or self.stage)
    end)
end

local function IsWeaponStep(step)
    if type(step) ~= "table" then return false end
    if step.weapon ~= nil then return step.weapon == true end
    local saved = step.saved
    return type(saved) == "table" and C:IsWeaponSlot(saved.slot) or false
end

-- Runtime owns the execution-order invariant too.  Core normally emits this order,
-- but keeping a second fence here prevents a future/preload/UI merge from silently
-- reintroducing the old rc6 regression where an armor refusal stopped the weapon
-- phase before it was reached.
local function NormalizeExecutionQueue(session)
    if type(session) ~= "table" then return end
    local weapons, others = {}, {}
    for _, step in ipairs(session.queue or {}) do
        if IsWeaponStep(step) then
            weapons[#weapons + 1] = step
        else
            others[#others + 1] = step
        end
    end
    table.sort(weapons, function(a, b)
        local aSlot = tonumber(a and (a.slot or (a.saved and a.saved.slot))) or 999
        local bSlot = tonumber(b and (b.slot or (b.saved and b.saved.slot))) or 999
        local ap = type(C.GetWeaponPriority) == "function" and C:GetWeaponPriority(aSlot) or aSlot
        local bp = type(C.GetWeaponPriority) == "function" and C:GetWeaponPriority(bSlot) or bSlot
        if ap ~= bp then return ap < bp end
        return aSlot < bSlot
    end)
    session.queue = {}
    for _, step in ipairs(weapons) do session.queue[#session.queue + 1] = step end
    for _, step in ipairs(others) do session.queue[#session.queue + 1] = step end
    session.weaponQueued = #weapons
    session.nonWeaponQueued = #others
    session.runtimeWeaponFenceApplied = true
end

local function WeaponActionDiagnostic(step)
    if type(step) ~= "table" then return "" end
    local attempts = tonumber(step.actionAttempts) or 0
    local accepted
    if step.lastActionAccepted == true then accepted = "接受"
    elseif step.lastActionAccepted == false then accepted = "拒绝"
    else accepted = "未知" end
    local err = step.lastActionError and tostring(step.lastActionError) or "无"
    local bagSlot = tostring(step.lastActionBagSlot or step.bagSlot or "?")
    local alt = step.lastActionAlternative == true and "true" or "false"
    local compat = step.compatibilityMatch == true and "/兼容匹配=是" or ""
    local bagView = tostring(step.lastActionBagId or step.bagId or step.weaponBagView or "?")
    local history = type(step.actionHistory) == "table" and table.concat(step.actionHistory, ",") or ""
    return "调用" .. tostring(attempts) .. "次/bagId=" .. bagView .. "/背包槽=" .. bagSlot .. "/alt=" .. alt
        .. "/最近返回=" .. accepted .. compat .. (history ~= "" and "/尝试=" .. history or "") .. "/错误=" .. err
end

local function PendingKey(slot)
    return tostring(tonumber(slot) or slot or "")
end

local function UpsertPending(session, saved, reason, skipped)
    if type(session) ~= "table" then return end
    session.pendingFailures = session.pendingFailures or {}
    local slot = saved and saved.slot or nil
    local key = PendingKey(slot)
    for _, entry in ipairs(session.pendingFailures) do
        if PendingKey(entry.slot) == key then
            entry.slotName = (saved and saved.slotName) or entry.slotName
            entry.name = (saved and saved.name) or entry.name or "未知装备"
            entry.reason = tostring(reason or entry.reason or "未完成")
            if skipped == true then entry.skipped = true end
            return
        end
    end
    session.pendingFailures[#session.pendingFailures + 1] = {
        slot = slot,
        slotName = saved and saved.slotName or nil,
        name = saved and saved.name or "未知装备",
        reason = tostring(reason or "未完成"),
        skipped = skipped == true,
    }
end

function R:EnsureWeaponPhase(now)
    local session = self.session
    if session == nil or session.weaponPhaseDone == true then return false end

    local queued = session.queue and session.queue[self.index] or nil
    if queued ~= nil and IsWeaponStep(queued) then return false end

    local missing = type(C.GetWeaponMismatches) == "function" and C:GetWeaponMismatches(session.set) or {}
    if #missing == 0 then
        session.weaponPhaseDone = true
        session.weaponFinalMissing = 0
        return false
    end

    local pass = tonumber(session.weaponPass) or 1
    if pass >= self.maxWeaponActionAttempts then
        for _, saved in ipairs(missing) do
            local key = tostring(tonumber(saved and saved.slot) or "?")
            local log = session.weaponDispatchLog and session.weaponDispatchLog[key] or nil
            local suffix = type(log) == "table" and #log > 0 and ("；直调用=" .. table.concat(log, " > ")) or ""
            UpsertPending(session, saved,
                "武器直调用完成3轮后仍未达到目标状态" .. suffix, false)
        end
        session.weaponFinalMissing = #missing
        session.partial = true
        session.weaponPhaseDone = true
        return false
    end

    session.weaponPass = pass + 1
    local retrySteps = type(C.BuildCommunityWeaponRetrySteps) == "function"
        and C:BuildCommunityWeaponRetrySteps(missing) or {}
    for i = #retrySteps, 1, -1 do
        table.insert(session.queue, self.index, retrySteps[i])
    end
    session.weaponQueued = (tonumber(session.weaponQueued) or 0) + #retrySteps
    session.weaponRetryPasses = (tonumber(session.weaponRetryPasses) or 0) + 1
    self.currentStep = nil
    self:ReportProgress("WEAPON_PASS_RETRY")
    self:Schedule("ACTION", now, self.weaponPassVerifyDelayMs)
    return true
end

local function ReconcileActualGear(session, fallbackReason)
    local valid, mismatches = C:ValidateSetEquipped(session and session.set or nil)
    mismatches = type(mismatches) == "table" and mismatches or {}

    local oldBySlot = {}
    for _, entry in ipairs(session.pendingFailures or {}) do
        oldBySlot[PendingKey(entry.slot)] = entry
    end

    local pending = {}
    for _, item in ipairs(mismatches) do
        local previous = oldBySlot[PendingKey(item.slot)]
        pending[#pending + 1] = {
            slot = item.slot,
            slotName = item.slotName,
            name = item.name,
            reason = tostring(previous and previous.reason or fallbackReason or "最终对账仍未达到目标状态"),
            skipped = previous and previous.skipped == true or false,
            preflight = previous and previous.preflight == true or false,
        }
    end

    session.pendingFailures = pending
    session.nonWeaponFailures = {}
    for _, entry in ipairs(pending) do
        if not C:IsWeaponSlot(entry.slot) then
            session.nonWeaponFailures[#session.nonWeaponFailures + 1] = entry
        end
    end

    local managed = tonumber(session.managedCount) or C:CountManagedItems(session.set)
    local unresolved = #pending
    session.actualManaged = managed
    session.actualPending = unresolved
    session.actualMatched = math.max(0, managed - unresolved)
    session.failed = unresolved
    session.partial = unresolved > 0
    return valid == true and unresolved == 0, pending
end

local function PendingDetails(session, limit)
    local parts = {}
    local pending = session and session.pendingFailures or {}
    local maxItems = math.max(1, tonumber(limit) or 3)
    for index, entry in ipairs(pending) do
        if index > maxItems then break end
        parts[#parts + 1] = tostring(entry.slotName or "装备") .. "：" .. tostring(entry.name or "未知")
    end
    if #pending > maxItems then
        parts[#parts + 1] = "另 " .. tostring(#pending - maxItems) .. " 件"
    end
    return table.concat(parts, "、")
end

local function PartialMessage(session)
    local count = tonumber(session and session.actualPending) or #(session and session.pendingFailures or {})
    if count <= 0 then return nil end
    local managed = tonumber(session.actualManaged) or tonumber(session.managedCount) or C:CountManagedItems(session.set)
    local matched = tonumber(session.actualMatched) or math.max(0, managed - count)
    local detail = PendingDetails(session, 3)
    local suffix = detail ~= "" and ("；未完成：" .. detail) or ""
    local weaponDiagnostic = session and session.lastWeaponFailureReason or nil
    if weaponDiagnostic ~= nil and tostring(weaponDiagnostic) ~= "" then
        suffix = suffix .. "；武器诊断：" .. tostring(weaponDiagnostic)
    end
    return "当前实际装备为部分完成 " .. tostring(matched) .. "/" .. tostring(managed)
        .. "；仍有 " .. tostring(count) .. " 个参与槽位未完成。再次点击同一方案只会补齐这些槽位" .. suffix
end

function R:MarkPendingAndContinue(step, reason, now, skipped)
    local session = self.session
    if session == nil or step == nil then
        self:Finish(false, "Pending 状态丢失")
        return
    end

    UpsertPending(session, step.saved or step, reason, skipped)
    if IsWeaponStep(step) then
        session.lastWeaponFailureReason = tostring(reason or "武器未完成")
    end
    session.partial = true
    if step.bagSlot ~= nil then session.reserved[step.bagSlot] = nil end
    step.bagSlot = nil
    self.index = self.index + 1
    self.currentStep = nil
    self:ReportProgress("PENDING")
    self:Schedule("ACTION", now, 0)
end


-- Combat safety -------------------------------------------------------------
-- The former COMBAT_DIRECT retry path was removed after live-client testing
-- showed X2Bag:EquipBagItem is rejected in combat. Manual backpack/shortcut
-- weapon use follows a different client path; this Addon does not emulate it.

function R:Start(setId)
    if ReplicatedSuiteEmbedded == true and self.moduleEnabled ~= true then
        U:SetQuickStatus("已关闭")
        U:SetStatus("换装模块当前已关闭", "请先在 Replicated Suite → 战斗中心启用换装模块")
        return false
    end
    if self.busy then
        U:SetQuickStatus("忙")
        U:SetStatus("当前已有换装任务正在执行", "请等待完成后再切换")
        return false
    end

    -- Since the June 2026 RU change, X2Bag:EquipBagItem is rejected while the
    -- player is in combat.  Manual backpack/shortcut weapon use is a different
    -- client path and remains possible, but ReplicatedGear must not spam a known
    -- blocked Addon API.  If the requested set already matches, treat the click
    -- as a harmless no-op; otherwise ask the player to retry after combat.
    if A ~= nil and type(A.IsPlayerInCombat) == "function" and A:IsPlayerInCombat() == true then
        local set = C:GetSetCopy(setId)
        if type(set) ~= "table" or set.configured ~= true then
            U:SetStatus("无法开始换装", "换装方案不存在或尚未保存")
            return false
        end
        local gearMatched = C:ValidateSetEquipped(set)
        local titleMatched = C:CurrentTitleMatches(set)
        if gearMatched == true and titleMatched == true then
            U:SetQuickStatus("已就绪")
            U:SetStatus("当前方案已经处于目标状态", "")
            return true
        end
        U:SetQuickStatus("战斗中")
        U:SetStatus(
            "战斗中无法自动换装",
            "当前客户端会拒绝 Addon 的自动装备接口；武器仍可通过背包/快捷栏手动切换。脱战后再次点击方案可自动补齐。"
        )
        return false
    end

    local session, err = C:BuildSwapSession(setId)
    if session == nil then
        U:SetStatus("无法开始换装：" .. tostring(err or "未知错误"), "")
        return false
    end
    if session.blocked then
        U:OnRuntimeBlocked(session)
        local detail = DescribeBlocked(session)
        if detail ~= "" then G.SafeChat(detail) end
        return false
    end

    -- Commit fence: execution order is normalized again at the Runtime boundary.
    -- Weapons (main/off-hand/ranged/instrument) can therefore never sit behind
    -- armor/accessories because of a Core/UI merge regression.
    NormalizeExecutionQueue(session)

    self.session = session
    self.busy = true
    self.index = 1
    self.currentStep = nil
    self.finalVerifyPolls = 0
    self.titleVerifyPolls = 0
    session.pendingFailures = session.pendingFailures or {}
    session.nonWeaponFailures = session.nonWeaponFailures or {}
    session.partial = #session.pendingFailures > 0
    session.weaponPass = 1
    session.weaponRetryPasses = 0
    session.weaponPhaseDone = (tonumber(session.weaponQueued) or 0) == 0
    session.weaponFinalMissing = 0
    session.weaponDispatchLog = {}
    self.elapsedMs = 0
    self.sessionStartedAt = 0
    self.stageStartedAt = 0
    -- This path runs only outside combat; actual equipped-slot reconciliation
    -- remains the Authority.
    local firstStep = session.queue and session.queue[1] or nil
    self:Schedule("ACTION", 0, IsWeaponStep(firstStep) and self.initialWeaponDelayMs or 0)
    U:OnRuntimeStarted(session)
    self:ReportProgress("START")
    return true
end

function R:Finish(ok, message)
    local session = self.session
    self.busy = false
    self.stage = "IDLE"
    self.currentStep = nil
    self.nextAt = 0
    self.stageStartedAt = 0
    self.sessionStartedAt = 0
    self.session = nil
    if session ~= nil then U:OnRuntimeFinished(session, ok == true, message) end
end

function R:ResolveCurrentStep()
    local session = self.session
    local step = session and session.queue[self.index] or nil
    if step == nil then return nil, nil end

    if IsWeaponStep(step) then
        -- Critical parity with public ArcheRage GearSwap: once a weapon bag
        -- position has been queued, do not re-read/fingerprint-gate it immediately
        -- before EquipBagItem.  Those extra checks were the last major behavioral
        -- difference from the known-working addon.
        if step.bagSlot == nil then
            local ok, reason = C:RefreshStepCandidate(session, step)
            if not ok then return nil, reason or "MISSING" end
        end
        return step, nil
    end

    if step.bagSlot ~= nil then
        local bagId = session.bag and session.bag.bagId or 1
        local stillMatches = C:BagSlotMatches(step.saved, bagId, step.bagSlot)
        if not stillMatches then
            session.reserved[step.bagSlot] = nil
            step.bagSlot = nil
            step.bagId = nil
        end
    end
    if step.bagSlot == nil then
        local ok, reason = C:RefreshStepCandidate(session, step)
        if not ok then return nil, reason or "MISSING" end
    end
    return step, nil
end

function R:Advance(now)
    local session = self.session
    local step = self.currentStep
    if session and step and step.bagSlot then session.reserved[step.bagSlot] = nil end
    self.index = self.index + 1
    self.currentStep = nil
    local delay = self.actionDelayMs
    if IsWeaponStep(step) then delay = self.weaponInterActionDelayMs end
    self:Schedule("ACTION", now, delay)
end

-- A desired weapon can temporarily be absent from the bag because it is still
-- equipped in another weapon slot.  Do not permanently fail that step before a
-- later hand action has had a chance to release it.  Move it behind the remaining
-- weapon work, but still ahead of armor/accessories, and bound the number of such
-- dependency deferrals so malformed state cannot loop forever.
function R:DeferWeaponDependency(step, now, reason)
    local session = self.session
    if session == nil or type(step) ~= "table" then return false end
    step.dependencyDeferrals = (tonumber(step.dependencyDeferrals) or 0) + 1
    if step.dependencyDeferrals > self.maxWeaponDependencyDeferrals then return false end

    if step.bagSlot ~= nil then session.reserved[step.bagSlot] = nil end
    step.bagSlot = nil
    step.bagId = nil
    step.verifyPolls = 0

    table.remove(session.queue, self.index)
    local insertAt = #session.queue + 1
    for i = self.index, #session.queue do
        if not IsWeaponStep(session.queue[i]) then
            insertAt = i
            break
        end
    end
    table.insert(session.queue, insertAt, step)
    self.currentStep = nil
    self:ReportProgress("WEAPON_DEPENDENCY")
    self:Schedule("ACTION", now, self.weaponRetryDelayMs)
    return true
end

function R:FinalizeGear(now)
    local session = self.session
    if session == nil then self:Finish(false, "内部会话丢失") return end

    local valid = C:ValidateSetEquipped(session.set)
    if not valid and session.combatDeferredNonWeapon ~= true then
        self.finalVerifyPolls = (tonumber(self.finalVerifyPolls) or 0) + 1
        if self.finalVerifyPolls <= self.maxFinalVerifyPolls then
            self:Schedule("FINAL_VERIFY", now, self.finalVerifyPollMs)
            self:ReportProgress("FINAL_VERIFY")
            return
        end
    end

    -- Final equipped state is the Authority. Any earlier API refusal/failure is
    -- discarded if the slot is now actually correct, and any still-mismatched
    -- managed slot becomes Pending regardless of weapon/non-weapon category.
    ReconcileActualGear(session, "最终对账仍未达到目标状态")
    self.finalVerifyPolls = 0

    -- Title is strictly the last phase. Unlike weapon slots, titles cannot be
    -- changed in combat, so skip only this phase when combat is positively
    -- detected. An unavailable combat API never blocks the action.
    local title = type(session.set) == "table" and session.set.title or nil
    local titleManaged = type(title) == "table" and title.apply == true
    if titleManaged and A ~= nil and type(A.IsPlayerInCombat) == "function" then
        local inCombat = A:IsPlayerInCombat()
        if inCombat == true then
            session.combatDeferredTitle = true
            local partial = PartialMessage(session)
            if partial ~= nil then
                self:Finish(true, tostring(partial) .. "；称号：战斗中已跳过，脱战后再次点击补齐")
            else
                self:Finish(true, "装备已完成；称号：战斗中已跳过，脱战后再次点击补齐")
            end
            return
        end
    end

    local ok, reason = C:ApplySavedTitle(session.set)
    if not ok then
        if session.partial == true then
            self:Finish(true, tostring(PartialMessage(session) or "部分完成") .. "；称号切换失败：" .. tostring(reason or "unknown"))
        else
            self:Finish(false, "装备已切换，但称号切换失败：" .. tostring(reason or "unknown"))
        end
        return
    end
    if reason == "SKIPPED" or reason == "ALREADY" then
        self:Finish(true, PartialMessage(session))
        return
    end
    self.titleVerifyPolls = 0
    self:Schedule("TITLE_VERIFY", now, self.titleVerifyPollMs)
    self:ReportProgress("TITLE_VERIFY")
end

function R:VerifyTitle(now)
    local session = self.session
    if session == nil then self:Finish(false, "称号验证会话丢失") return end
    local matched, reason = C:CurrentTitleMatches(session.set)
    if matched == true then
        self:Finish(true, PartialMessage(session))
        return
    end
    self.titleVerifyPolls = (tonumber(self.titleVerifyPolls) or 0) + 1
    if self.titleVerifyPolls <= self.maxTitleVerifyPolls then
        self:Schedule("TITLE_VERIFY", now, self.titleVerifyPollMs)
        return
    end
    if session.partial == true then
        self:Finish(true, tostring(PartialMessage(session) or "部分完成") .. "；称号验证失败：" .. tostring(reason or "客户端未切换到保存的称号"))
    else
        self:Finish(false, "装备已切换，但称号验证失败：" .. tostring(reason or "客户端未切换到保存的称号"))
    end
end

function R:DoAction(now)
    local session = self.session
    if session == nil then self:Finish(false, "内部会话丢失") return end

    local queued = session.queue and session.queue[self.index] or nil

    -- Combat may begin halfway through a loadout.  Stop *before* weapon retry
    -- reconciliation so no EquipBagItem call (weapon or armor) is issued after
    -- combat becomes true.  Already-correct steps are still skipped normally;
    -- every remaining mismatch becomes Pending for the next out-of-combat click.
    if A ~= nil and type(A.IsPlayerInCombat) == "function" and A:IsPlayerInCombat() == true then
        session.weaponPhaseDone = true
        session.combatDeferredGear = true
        session.combatDeferredNonWeapon = true -- also suppress pointless final-verify waiting
        if queued == nil then
            self:Schedule("FINAL_VERIFY", now, 0)
            self:FinalizeGear(now)
            return
        end
        if C:CurrentItemMatches(queued.saved) then
            if queued.bagSlot ~= nil then session.reserved[queued.bagSlot] = nil end
            queued.bagSlot = nil
            session.skipped = (session.skipped or 0) + 1
            session.runtimeSkipped = (session.runtimeSkipped or 0) + 1
            self.index = self.index + 1
            self.currentStep = nil
            self:Schedule("ACTION", now, 0)
            return
        end
        self:MarkPendingAndContinue(queued,
            "战斗中已暂停自动换装；脱战后再次点击补齐", now, true)
        return
    end

    -- Weapon Authority is a whole-pass reconciliation outside combat.  Do not
    -- stop on one weapon before the remaining weapon actions have been issued.
    if session.weaponPhaseDone ~= true and (queued == nil or not IsWeaponStep(queued)) then
        if self:EnsureWeaponPhase(now) then return end
    end

    if self.index > #session.queue then
        self:Schedule("FINAL_VERIFY", now, 0)
        self:FinalizeGear(now)
        return
    end

    queued = session.queue[self.index]
    local queuedIsWeapon = IsWeaponStep(queued)

    -- Re-check before every action. Earlier equipment changes can make later
    -- slots correct, so redundant calls are skipped without changing pass order.
    if queued ~= nil and C:CurrentItemMatches(queued.saved) then
        if queued.bagSlot ~= nil then session.reserved[queued.bagSlot] = nil end
        queued.bagSlot = nil
        session.skipped = (session.skipped or 0) + 1
        session.runtimeSkipped = (session.runtimeSkipped or 0) + 1
        self:ReportProgress("SKIP")
        self.index = self.index + 1
        self.currentStep = nil
        self:Schedule("ACTION", now, 0)
        return
    end

    local step, reason = self:ResolveCurrentStep()
    if step == nil then
        local unresolved = session.queue[self.index]
        if IsWeaponStep(unresolved) then
            -- Missing from the bag in this pass is not a terminal failure.  Another
            -- weapon action in the same pass may release it; whole-pass retry will
            -- re-scan bagId=1 afterwards.
            unresolved.lastActionError = "本轮未找到背包位置（" .. tostring(reason or "MISSING") .. "）"
            unresolved.lastActionBagId = 1
            unresolved.lastActionAccepted = nil
            self.currentStep = unresolved
            self:ReportProgress("WEAPON_PASS_MISSING")
            self:Advance(now)
            return
        end
        self:MarkPendingAndContinue(unresolved,
            "执行时目标装备不可用（" .. tostring(reason or "MISSING") .. "）", now, false)
        return
    end

    self.currentStep = step
    step.verifyPolls = 0
    step.actionAttempts = (tonumber(step.actionAttempts) or 0) + 1
    step.lastActionBagSlot = step.bagSlot
    step.lastActionBagId = queuedIsWeapon and 1 or (step.bagId or step.weaponBagView)
    step.lastActionAlternative = step.alternative == true
    self:ReportProgress("ACTION")

    if queuedIsWeapon then
        local callOk, rawValue, callErr
        if A ~= nil and type(A.EquipBagItemDirect) == "function" then
            callOk, rawValue, callErr = A:EquipBagItemDirect(step.bagSlot, step.alternative)
        else
            local ok, err = A:EquipBagItem(step.bagSlot, step.alternative)
            callOk, rawValue, callErr = ok == true, nil, err
        end
        step.lastActionAccepted = callOk == true
        step.lastActionRawReturn = rawValue
        step.lastActionError = callErr
        step.actionHistory = type(step.actionHistory) == "table" and step.actionHistory or {}
        step.actionHistory[#step.actionHistory + 1] = "v1:s" .. tostring(step.lastActionBagSlot or "?") .. ":" .. (callOk and "sent" or "error")
        session.weaponDispatchLog = type(session.weaponDispatchLog) == "table" and session.weaponDispatchLog or {}
        local logKey = tostring(tonumber(step.slot or (step.saved and step.saved.slot)) or "?")
        local slotLog = session.weaponDispatchLog[logKey]
        if type(slotLog) ~= "table" then slotLog = {}; session.weaponDispatchLog[logKey] = slotLog end
        slotLog[#slotLog + 1] = "bag1/pos" .. tostring(step.lastActionBagSlot or "?")
            .. "/alt=" .. tostring(step.lastActionAlternative == true)
            .. "/call=" .. (callOk and "sent" or ("error:" .. tostring(callErr or "unknown")))
            .. "/ret=" .. tostring(rawValue)

        -- Do not VERIFY/WAIT this individual weapon.  Send the rest of the weapon
        -- pass first; then EnsureWeaponPhase checks the actual equipped slots and
        -- re-queues only what is still missing, up to three passes.
        self:Advance(now)
        return
    end

    local ok, err = A:EquipBagItem(step.bagSlot, step.alternative)
    step.lastActionAccepted = ok == true
    step.lastActionError = err
    step.actionHistory = type(step.actionHistory) == "table" and step.actionHistory or {}
    step.actionHistory[#step.actionHistory + 1] = "v" .. tostring(step.lastActionBagId or "?") .. ":s" .. tostring(step.lastActionBagSlot or "?") .. ":" .. (ok and "ok" or "no")
    if not ok then
        self:MarkPendingAndContinue(step,
            "EquipBagItem 被客户端拒绝：" .. tostring(err or "unknown"), now, false)
        return
    end
    self:Schedule("VERIFY", now, self.verifyDelayMs)
    self:ReportProgress("VERIFY")
end


function R:Verify(now)
    local session, step = self.session, self.currentStep
    if session == nil or step == nil then self:Finish(false, "验证状态丢失") return end
    if C:CurrentItemMatches(step.saved) then
        session.success = (session.success or 0) + 1
        self:Advance(now)
        return
    end

    step.verifyPolls = (tonumber(step.verifyPolls) or 0) + 1
    if step.verifyPolls <= self.maxVerifyPolls then
        self:Schedule("VERIFY", now, self.verifyPollMs)
        return
    end

    -- Weapons get one extra candidate refresh/retry because their slot changes
    -- can relocate each other. A final refusal still becomes Pending instead of
    -- aborting independent weapons or the rest of the loadout.
    if IsWeaponStep(step) then
        step.retries = (tonumber(step.retries) or 0) + 1
        local attempts = tonumber(step.actionAttempts) or 0
        if attempts < self.maxWeaponActionAttempts then
            if step.bagSlot then session.reserved[step.bagSlot] = nil end
            local lastView = tonumber(step.lastActionBagId)
            step.preferredWeaponBagView = lastView == 0 and 1 or 0
            step.bagSlot = nil
            step.bagId = nil
            step.verifyPolls = 0
            local ok, reason = C:RefreshStepCandidate(session, step)
            if ok then
                self.currentStep = nil
                self:Schedule("ACTION", now, self.weaponRetryDelayMs)
                return
            end
            if C:IsDesiredEquippedElsewhere(step.saved)
                and self:DeferWeaponDependency(step, now, reason) then
                return
            end
            self:MarkPendingAndContinue(step,
                "武器未生效，重新查找失败（" .. tostring(reason or "MISSING") .. "）；" .. WeaponActionDiagnostic(step), now, false)
            return
        end
        self:MarkPendingAndContinue(step,
            "武器连续3次未生效；" .. WeaponActionDiagnostic(step), now, false)
        return
    end

    self:MarkPendingAndContinue(step,
        "装备未生效，客户端未接受或实际装备状态未变化", now, false)
end

function R:FinishFromWatchdog(message)
    local session = self.session
    if session == nil then self:Finish(false, tostring(message or "换装超时")) return end

    -- Watchdog termination is also a transaction boundary. Never trust the
    -- interrupted stage as the result; reconcile the actual equipped state and
    -- report COMPLETE/PARTIAL from that state.
    ReconcileActualGear(session, tostring(message or "换装超时"))
    if session.partial == true then
        self:Finish(true, tostring(PartialMessage(session) or "部分完成") .. "；" .. tostring(message or "换装超时"))
        return
    end

    local titleMatched, titleReason = C:CurrentTitleMatches(session.set)
    if titleMatched == true then
        self:Finish(true, "最终装备状态已全部对账完成；" .. tostring(message or "换装超时"))
    else
        self:Finish(false, "装备已全部到位，但" .. tostring(message or "换装超时") .. "；称号未完成：" .. tostring(titleReason or "unknown"))
    end
end

function R:CheckWatchdog(now)
    if not self.busy then return false end
    local total = now - (FiniteNumber(self.sessionStartedAt) or 0)
    if total > self.sessionTimeoutMs then
        self:FinishFromWatchdog("换装总超时（" .. tostring(math.floor(total)) .. "ms），阶段=" .. tostring(self.stage)
            .. "，进度=" .. tostring(self.index) .. "/" .. tostring(self.session and #(self.session.queue or {}) or 0))
        return true
    end
    local stageElapsed = now - (FiniteNumber(self.stageStartedAt) or now)
    if self.stage ~= "IDLE" and stageElapsed > self.stageTimeoutMs then
        self:FinishFromWatchdog("换装阶段超时：" .. tostring(self.stage) .. "（" .. tostring(math.floor(stageElapsed))
            .. "ms），进度=" .. tostring(self.index) .. "/" .. tostring(self.session and #(self.session.queue or {}) or 0))
        return true
    end
    return false
end

function R:OnUpdate(dt)
    -- A hot reload creates a new generation but ArcheRage can keep old hidden
    -- widgets and their OnUpdate handlers alive.  Old drivers must become inert
    -- immediately so two generations can never equip items concurrently.
    if G.Generation ~= runtimeGeneration then
        self.busy = false
        self.session = nil
        self.stage = "IDLE"
        return
    end
    if type(G.AdvanceClock) == "function" then G.AdvanceClock(dt) end
    if not self.busy then return end

    self.elapsedMs = self:RuntimeNow() + DeltaMs(dt, self.defaultUpdateDeltaMs, self.maxUpdateDeltaMs)
    local now = self:RuntimeNow()
    if self:CheckWatchdog(now) then return end
    if now < (self.nextAt or 0) then return end

    if self.stage == "ACTION" then
        self:DoAction(now)
    elseif self.stage == "VERIFY" then
        self:Verify(now)
    elseif self.stage == "FINAL_VERIFY" then
        self:FinalizeGear(now)
    elseif self.stage == "TITLE_VERIFY" then
        self:VerifyTitle(now)
    else
        self:Finish(false, "未知换装阶段：" .. tostring(self.stage))
    end
end

local function GearRuntimeUpdateHandler(_, dt)
    if G.Generation ~= runtimeGeneration or R.moduleEnabled ~= true then return end
    local token = G.PerformanceMonitor and G.PerformanceMonitor:Begin("onupdate:gear_runtime") or nil
    local ok, err = pcall(R.OnUpdate, R, dt)
    if G.PerformanceMonitor ~= nil then G.PerformanceMonitor:End(token) end
    if not ok then R:Finish(false, "运行时错误：" .. tostring(err)) end
end

local SharedRuntimeHost = rawget(_G, "ReplicatedSuiteShared")
SharedRuntimeHost = SharedRuntimeHost and SharedRuntimeHost.NativeRuntimeHost or nil
local driverHost = SharedRuntimeHost and type(SharedRuntimeHost.Acquire) == "function"
    and SharedRuntimeHost.Acquire({ id = "rg_runtime_driver_g" .. tostring(G.Generation), parent = "UIParent", visible = false }) or nil

local driverOk, driverOrErr = xpcall(function()
    local driver
    if driverHost ~= nil then
        local ready, result = driverHost:Ensure()
        if ready ~= true then error(tostring(result or "runtime driver unavailable")) end
        driver = result
    else
        driver = CreateEmptyWindow("rg_runtime_driver_g" .. tostring(G.Generation), "UIParent")
        driver:SetExtent(1, 1)
        driver:AddAnchor("TOPLEFT", "UIParent", 0, 0)
        if driver.EnablePick ~= nil then driver:EnablePick(false, true) end
        if driver.Clickable ~= nil then driver:Clickable(false, true) end
        driver:Show(false)
    end
    U.windows.runtimeDriver = driver
    return driver
end, G.SafeTraceback)

if not driverOk then
    G.BootError = "runtime: " .. tostring(driverOrErr)
    G.SafeChat("运行时初始化失败：" .. tostring(driverOrErr))
    return
end
R.driverHost = driverHost

R.moduleEnabled = ReplicatedSuiteEmbedded ~= true

function R:EnableModuleRuntime()
    if G.BootError ~= nil then return false end
    self.moduleEnabled = true
    local driver = U.windows and U.windows.runtimeDriver or nil
    if driver ~= nil and type(driver.SetHandler) == "function" then
        local bindOk, bindResult
        if self.driverHost ~= nil then
            bindOk, bindResult = self.driverHost:Bind("OnUpdate", GearRuntimeUpdateHandler)
        else
            if driver.HasHandler ~= nil and driver:HasHandler("OnUpdate") and driver.ReleaseHandler ~= nil then
                pcall(function() driver:ReleaseHandler("OnUpdate") end)
            end
            bindOk, bindResult = pcall(driver.SetHandler, driver, "OnUpdate", GearRuntimeUpdateHandler)
        end
        if not bindOk or bindResult == false then
            self.moduleEnabled = false
            pcall(function() driver:Show(false) end)
            U:SetStatus("换装运行时启动失败", bindOk and "OnUpdate SetHandler returned false" or tostring(bindResult))
            return false
        end
        if self.driverHost ~= nil then self.driverHost:Show(true) else driver:Show(true) end
    else
        self.moduleEnabled = false
        return false
    end
    G.Ready = true
    return true
end

function R:DisableModuleRuntime(reason)
    self.moduleEnabled = false
    if U ~= nil and type(U.SetSuiteHudVisible) == "function" then U:SetSuiteHudVisible(false) end
    if self.busy == true then
        self.busy = false
        self.session = nil
        self.currentStep = nil
        self.stage = "IDLE"
        U:SetQuickStatus("已停止")
        U:SetStatus("换装模块已关闭", tostring(reason or "Suite lifecycle"))
    end
    local driver = U.windows and U.windows.runtimeDriver or nil
    if driver ~= nil then
        if self.driverHost ~= nil then self.driverHost:Release()
        else
            driver:Show(false)
            if driver.HasHandler ~= nil and driver:HasHandler("OnUpdate") and driver.ReleaseHandler ~= nil then
                pcall(function() driver:ReleaseHandler("OnUpdate") end)
            end
        end
    end
    return true
end

if ReplicatedSuiteEmbedded ~= true then
    R:EnableModuleRuntime()
end
G.Ready = G.BootError == nil
