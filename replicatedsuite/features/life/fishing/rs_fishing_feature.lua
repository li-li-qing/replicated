------------------------------------------------------------------------
-- Replicated Suite V3 - life_fishing Feature Authority
--
-- Phase 2 Step 2（2026-09-28，§24.1 固定顺序第二步）：从 features/life/rs_life_m16_bundle.lua
-- 机械搬迁。只改变源码边界，不改业务行为：Feature ID、Store ID/Schema（v3.life.fishing）、
-- UpdateTopic、Demand owner、Commands、Projection shape、ApiDependencies、
-- Patch=fishing-auto-r-transaction-1 与 Auto-R 事务/恢复契约全部逐字一致。
--
-- §24.3 红线：Fishing Auto-R 的 hotkey transaction/recovery 契约冻结；
-- 共享装配 helper 来自 features/life/shared/rs_life_slice_factory.lua（toc.g 已保证先加载）。
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local P, Runtime, Demand = S.Persistence, S.FeatureRuntime, S.Demand
if type(P) ~= "table" or type(Runtime) ~= "table" or type(Demand) ~= "table" then return end
local UnitApi = rawget(_G, "X2Unit")
local LF = S.LifeSliceFactory
if type(LF) ~= "table" then error("LifeSliceFactory unavailable for life_fishing") end
local Copy, Call = LF.Copy, LF.Call
local Number, Text = LF.Number, LF.Text
local InstallLifeWidgetContract, PublishFeatureUpdate = LF.InstallLifeWidgetContract, LF.PublishFeatureUpdate
local RegisterStore, LoadStore = LF.RegisterStore, LF.LoadStore

------------------------------------------------------------------------
-- Fishing (Demand-scoped observation + reversible Auto-R hotkey transaction)
------------------------------------------------------------------------
local Fishing = { Id = "life_fishing", storeId = "v3.life.fishing", enabled = false, storeLoaded = false, autoArmed = false, autoLeaseHeld = false, recoveryNativeRestored = false } -- 中文维护：Fishing Feature 继续拥有业务生命周期；Auto-R 会话状态只在本模块存活，持久恢复证据进入 v3.life.fishing Store。
S.Features.Fishing = Fishing -- 中文维护：保持现有 FeatureRuntime/Presentation Authority 名称，用户升级无需迁移导航或 Consumer token。
Fishing.Patch = "fishing-auto-r-transaction-1" -- 中文维护：实机诊断必须能区分本轮完整 Auto-R 事务与旧 Runtime-Blocked 版本，避免覆盖错误时继续猜根因。
Fishing.UpdateTopic = "v3.life.fishing.updated" -- 中文维护：页面与悬浮窗继续消费同一更新主题；识别/改键不能创建第二套 UI 状态源。
Fishing.ObservationContractVersion = 2 -- 中文维护：v2 表示 TARGET/BUFF 事件 + 100ms Demand-scoped 兜底扫描；避免 RU 漏 BUFF_UPDATE 时长期不刷新。
Fishing.HotkeyContractVersion = 3 -- 中文维护：v3 表示恢复旧版已验证的完整 R 快照/恢复事务，并要求持久化 durability barrier + Native readback。
Fishing.HotkeyRuntimeBlocked = false -- 中文维护：旧版实机实现和当前 Capability 面已补足缺失证据；若运行时能力/存档不可用仍由事务 fail-closed，不再全局硬禁用。
Fishing.State = { autoPreference = false, widgetVisible = false, widgetWindow = nil, recovery = nil } -- 中文维护：recovery 是唯一持久恢复 Authority；模块关闭仍保留直到原按键已确认恢复。
InstallLifeWidgetContract(Fishing, { defaultWidth = 360, defaultHeight = 190, minWidth = 230, minHeight = 110, defaultOverallOpacity = 0.94, defaultBackgroundOpacity = 1.0, defaultTextOpacity = 1.0 })

local FishingHotkey = S.Services and S.Services.FishingHotkeyV3 or nil -- 中文维护：Feature 只编排事务，不直接复制 Native Hotkey 细节；服务缺失时观察仍可用、Auto-R fail-closed。
local FISH_NORMAL_MAP = { [5264] = { slot = 4, text = "向左拉" }, [5265] = { slot = 3, text = "向右拉" }, [5267] = { slot = 5, text = "放线" }, [5266] = { slot = 6, text = "收线" }, [5508] = { slot = 7, text = "提竿" } } -- 中文维护：来源为用户提供的可用旧版 + GitHub FishBuddy/Nuzi 同组 Buff；只迁移行为语义，不搬旧生命周期。
local FISH_MIRAGE_MAP = { [5264] = { slot = 3, text = "向左拉" }, [5265] = { slot = 2, text = "向右拉" }, [5267] = { slot = 4, text = "放线" }, [5266] = { slot = 5, text = "收线" }, [5508] = { slot = 6, text = "提竿" } } -- 中文维护：ZoneGroup 49 使用旧版已验证的幻想岛槽位偏移；不能把普通区域映射硬套过去。
local FISHING_POLL_TASK = "v3_life_fishing_poll" -- 中文维护：100ms 兜底仅在 Consumer>0 运行；隐藏/关闭后必须释放，避免生活模块常驻扫描 Buff。
local FISHING_EVENT_TASK = "v3_life_fishing_event_refresh" -- 中文维护：BUFF_UPDATE 可爆发，事件边沿合并为单次 50ms 扫描，和周期兜底共享同一 Authority。
local FISHING_AUTO_CONSUMER = "auto:r" -- 中文维护：Auto-R 自身就是独立 Demand consumer；关闭主菜单不能终止已明确启用的自动钓鱼，Disarm 后必须释放。
local FISHING_RECOVERY_TASK = "v3_life_fishing_recovery" -- 中文维护：仅“战斗中等待恢复/恢复记录清理失败”时存在；不扫描 Buff，只保障用户键位最终恢复。
local FISHING_POLL_MS = 100 -- 中文维护：自动 R 需要比旧 500ms 更及时；任务严格 Demand-scoped，成本边界是最多每秒 10 次目标 Buff 扫描。
local FISHING_RECOVERY_MS = 250 -- 中文维护：恢复任务只检查战斗状态/重试事务，无需高频；250ms 兼顾脱战恢复体验与开销。

Fishing.Authority = {
    version = 2, revision = 0, status = "idle", message = "尚未观察目标鱼动作",
    buffId = nil, slot = nil, zoneGroup = nil, autoArmed = false, autoAvailable = false, autoBlockedReason = nil,
    lastScanCount = 0, lastObservedIds = {}, lastRefreshAt = 0, lastRefreshReason = "init",
    polls = 0, nativeEventRefreshes = 0, writeFailures = 0, lastWriteError = nil,
} -- 中文维护：诊断保留“事件/兜底/动作/写失败”边界，后续 RU 报告可以直接区分没事件、ID 不对还是 Hotkey 事务失败。
local FA = Fishing.Authority

local function NormalizeFishingSnapshot(snapshot) -- 中文维护：恢复快照经过持久化后不信任表形；只接受 v3 所需标量/槽位，防止旧实验记录触发 Native 写入。
    if type(snapshot) ~= "table" or (tonumber(snapshot.contractVersion) or 0) < 3 then return nil end
    local sourceSlot = Number(snapshot.sourceSlot)
    if sourceSlot == nil then return nil end
    sourceSlot = math.floor(sourceSlot)
    if sourceSlot < 1 or sourceSlot > 12 then return nil end
    local out = { contractVersion = 3, sourceSlot = sourceSlot, sourceBinding = Text(snapshot.sourceBinding, "R"), slots = {}, touched = {} }
    for key, item in pairs(type(snapshot.slots) == "table" and snapshot.slots or {}) do
        if type(item) == "table" then
            local slot = Number(item.slot or key)
            if slot ~= nil then
                slot = math.floor(slot)
                if slot >= 1 and slot <= 12 then out.slots[slot] = { slot = slot, binding = item.binding ~= nil and tostring(item.binding) or nil, wasUnbound = item.wasUnbound == true } end
            end
        end
    end
    for key, touched in pairs(type(snapshot.touched) == "table" and snapshot.touched or {}) do
        local slot = Number(key)
        if touched == true and slot ~= nil then out.touched[math.floor(slot)] = true end
    end
    if type(out.slots[sourceSlot]) ~= "table" then out.slots[sourceSlot] = { slot = sourceSlot, binding = out.sourceBinding, wasUnbound = false } end
    return out
end

local function NormalizeFishingRecovery(recovery) -- 中文维护：只把 pending=true + contractVersion>=3 视为可执行恢复权威；旧版/损坏形状保留给诊断但绝不自动写键。
    if type(recovery) ~= "table" then return nil end
    local snapshot = NormalizeFishingSnapshot(recovery.snapshot)
    if recovery.pending ~= true or snapshot == nil then return Copy(recovery) end
    return { pending = true, snapshot = snapshot }
end

local function HasValidFishingRecovery(value) -- 中文维护：所有自动恢复入口共用一个验证条件，避免 UI/Initialize/Disable 对同一存档形状做不同判断。
    return type(value) == "table" and value.pending == true and NormalizeFishingSnapshot(value.snapshot) ~= nil
end

local function CurrentFishingMap() -- 中文维护：ZoneGroup 读取是业务事实；失败时回退普通映射而不阻断动作提示，Zone 49 只有明确读到时才启用特殊偏移。
    local zoneId = nil
    if S.Api ~= nil and S.Api:IsCapabilityAllowed("X2Unit:GetCurrentZoneGroup") == true then
        local okZone, value = Call("X2Unit:GetCurrentZoneGroup", UnitApi, "GetCurrentZoneGroup")
        if okZone == true then zoneId = Number(value) end
    end
    zoneId = zoneId ~= nil and math.floor(zoneId) or nil
    FA.zoneGroup = zoneId
    return zoneId == 49 and FISH_MIRAGE_MAP or FISH_NORMAL_MAP
end

function Fishing:PersistRecoverySnapshot(snapshot, reason) -- 中文维护：每次首次触碰新槽位前走 durable=true；SaveData+readback 未通过就拒绝 Native 改键，不允许“稍后再存”。
    local normalized = NormalizeFishingSnapshot(snapshot)
    if normalized == nil then return false, "钓鱼恢复快照无效" end
    return P:MutateStore(self.storeId, function()
        self.State.recovery = { pending = true, snapshot = Copy(normalized) }
        self.State.autoPreference = true
        return true
    end, { durable = true, reason = reason or "fishing_hotkey_recovery" })
end

function Fishing:ClearRecoveryRecord(reason) -- 中文维护：必须在 Native 完整恢复成功之后才清；清理也要求持久读回，防止 Reload 又看到伪清理状态。
    return P:MutateStore(self.storeId, function()
        self.State.recovery = nil
        self.State.autoPreference = false
        return true
    end, { durable = true, reason = reason or "fishing_hotkey_recovery_clear" })
end

function Fishing:RefreshAutoAvailability() -- 中文维护：按钮可用性来自当前 Capability/战斗/恢复状态，不把失败藏在 onClick；观察功能即使 Auto-R 不可用仍保持工作。
    local supported, supportErr = false, "FishingHotkeyV3 服务不可用"
    if type(FishingHotkey) == "table" and type(FishingHotkey.IsSupported) == "function" then supported, supportErr = FishingHotkey:IsSupported() end
    local invalidRecovery = type(self.State.recovery) == "table" and not HasValidFishingRecovery(self.State.recovery)
    -- 中文维护：Lua 的 `a and b or true` 会在 b=false 时重新落到 true；此前因此把“未战斗”也判成战斗中，Auto-R UI 永远不可用。
    -- Authority：战斗状态只由 FishingHotkeyV3 的 capability-gated PlayerInCombat 读取；服务缺失时才 fail-closed 为 true。
    local inCombat = true
    if type(FishingHotkey) == "table" and type(FishingHotkey.InCombat) == "function" then
        inCombat = FishingHotkey:InCombat() == true
    end
    FA.autoArmed = self.autoArmed == true
    FA.autoAvailable = supported == true and invalidRecovery ~= true and inCombat ~= true and (self:IsRecoveryPending() ~= true or self.autoArmed == true)
    if invalidRecovery then FA.autoBlockedReason = "检测到无法验证的旧版自动 R 恢复记录；为避免误删按键，本次拒绝改键。请先确认游戏按键并重置钓鱼配置。"
    elseif supported ~= true then FA.autoBlockedReason = tostring(supportErr or "自动 R API 不可用")
    elseif inCombat then FA.autoBlockedReason = "战斗中不能修改按键"
    elseif self:IsRecoveryPending() and self.autoArmed ~= true then FA.autoBlockedReason = "正在恢复原 R 键，请稍候"
    else FA.autoBlockedReason = nil end
    return FA.autoAvailable
end

function Fishing:IsRecoveryPending() -- 中文维护：持久 Store 和服务内存任一仍有恢复义务，都视为 pending；UI 关闭不能抹掉这个安全状态。
    if self.recoveryNativeRestored == true then return true end
    if HasValidFishingRecovery(self.State.recovery) then return true end
    return type(FishingHotkey) == "table" and type(FishingHotkey.IsRecoveryPending) == "function" and FishingHotkey:IsRecoveryPending() == true or false
end

function Fishing:CancelRecoveryTask() -- 中文维护：恢复完成后主动释放低频安全任务；不会让生活功能关闭后留下永久 Scheduler 消费者。
    if S.Scheduler ~= nil and type(S.Scheduler.RemoveTask) == "function" then S.Scheduler:RemoveTask(FISHING_RECOVERY_TASK) end
end

function Fishing:EnsureRecoveryTask() -- 中文维护：仅在确有恢复义务时创建；即使 Feature 被关闭也允许此安全任务继续，直到用户原键位恢复。
    if self:IsRecoveryPending() ~= true then self:CancelRecoveryTask(); return true end
    if S.Scheduler == nil or type(S.Scheduler.AddTask) ~= "function" then return false, "钓鱼按键恢复 Scheduler 不可用" end
    if S.Scheduler.tasks and S.Scheduler.tasks[FISHING_RECOVERY_TASK] ~= nil then return true end
    local added = S.Scheduler:AddTask(FISHING_RECOVERY_TASK, FISHING_RECOVERY_MS, function()
        if Fishing:IsRecoveryPending() ~= true then Fishing:CancelRecoveryTask(); return true end
        if type(FishingHotkey) == "table" and FishingHotkey:InCombat() == true then return true end
        Fishing:ProcessPendingRecovery(true, "recovery_task")
        return true
    end, false, self, "P1", 1)
    if added == true and type(S.Scheduler.SetTaskModule) == "function" then S.Scheduler:SetTaskModule(FISHING_RECOVERY_TASK, self.Id, false) end
    return added == true, added == true and nil or "钓鱼按键恢复任务创建失败"
end

function Fishing:ProcessPendingRecovery(silent, reason) -- 中文维护：Native 恢复与持久 recovery 清理分两段；任一失败都保留 Authority，下一 tick 可重试，不会宣称已恢复。
    local recovery = HasValidFishingRecovery(self.State.recovery) and self.State.recovery or nil
    local snapshot = recovery and NormalizeFishingSnapshot(recovery.snapshot) or nil
    if snapshot == nil and type(FishingHotkey) == "table" and type(FishingHotkey.sessionSnapshot) == "table" then snapshot = NormalizeFishingSnapshot(FishingHotkey.sessionSnapshot) end
    if snapshot == nil then
        self.recoveryNativeRestored = false
        if type(FishingHotkey) == "table" and type(FishingHotkey.ResetSession) == "function" then FishingHotkey:ResetSession() end
        self:CancelRecoveryTask()
        self:RefreshAutoAvailability()
        return true
    end
    if type(FishingHotkey) ~= "table" then self:EnsureRecoveryTask(); return false, "FishingHotkeyV3 服务不可用" end
    if FishingHotkey:InCombat() == true then
        FishingHotkey:AdoptRecovery(snapshot)
        FishingHotkey.pendingRecovery = true
        self.autoArmed = false
        FA.autoArmed = false
        FA.status, FA.message = "recovering", "战斗中不能改键 · 等待脱战恢复原 R"
        self:EnsureRecoveryTask()
        self:RefreshAutoAvailability()
        return false, "战斗中等待恢复"
    end
    if FishingHotkey.sessionSnapshot == nil then FishingHotkey:AdoptRecovery(snapshot) end
    if self.recoveryNativeRestored ~= true then
        local restored, restoreErr = FishingHotkey:RestoreSnapshot(snapshot)
        if restored ~= true then
            FA.status, FA.message = "error", "恢复原按键失败：" .. tostring(restoreErr or "unknown")
            FA.lastWriteError = tostring(restoreErr or "restore failed")
            self:EnsureRecoveryTask()
            self:RefreshAutoAvailability()
            if silent ~= true then S.SafeChat(FA.message) end
            return false, restoreErr
        end
        self.recoveryNativeRestored = true
    end
    local cleared, clearErr = self:ClearRecoveryRecord("fishing_recovery_clear:" .. tostring(reason or "manual"))
    if cleared ~= true then
        FA.status, FA.message = "recovering", "原按键已恢复，但恢复记录保存失败；将继续重试"
        FA.lastWriteError = tostring(clearErr or "recovery clear failed")
        self:EnsureRecoveryTask()
        self:RefreshAutoAvailability()
        return false, clearErr
    end
    self.recoveryNativeRestored = false
    self.autoArmed = false
    FishingHotkey:ResetSession()
    self:CancelRecoveryTask()
    FA.autoArmed = false
    FA.status, FA.message = "waiting", "自动 R 已关闭 · 已恢复原按键"
    FA.lastWriteError = nil
    self:RefreshAutoAvailability()
    FA.revision = FA.revision + 1
    PublishFeatureUpdate(self, FA.revision, "fishing_hotkey_restored")
    if silent ~= true then S.SafeChat("钓鱼自动 R 已关闭，原按键已恢复。") end
    return true
end

function FA:Refresh(reason) -- 中文维护：鱼动作识别是唯一 projection Authority；事件刷新和 100ms 兜底都走这里，防止 UI 与 Auto-R 读取不同 Buff 快照。
    reason = tostring(reason or "manual")
    self.buffId, self.slot = nil, nil
    self.lastScanCount, self.lastObservedIds = 0, {}
    self.lastRefreshAt = S.NowMs and S.NowMs() or 0
    self.lastRefreshReason = reason
    if reason == "poll" then self.polls = (tonumber(self.polls) or 0) + 1 else self.nativeEventRefreshes = (tonumber(self.nativeEventRefreshes) or 0) + 1 end
    if S.Api:IsCapabilityAllowed("X2Unit:UnitBuffCount") ~= true or S.Api:IsCapabilityAllowed("X2Unit:UnitBuff") ~= true then
        self.status, self.message = "unavailable", "当前 RU 能力面未证明目标 Buff 读取"
        Fishing:RefreshAutoAvailability()
        self.revision = self.revision + 1
        PublishFeatureUpdate(Fishing, self.revision, "fishing_observation_unavailable")
        return false
    end
    local map = CurrentFishingMap()
    local ok, count = Call("X2Unit:UnitBuffCount", UnitApi, "UnitBuffCount", "target")
    count = ok and Number(count) or 0
    count = math.max(0, math.min(128, math.floor(count or 0)))
    self.lastScanCount = count
    for index = 1, count do
        local readOk, buff = Call("X2Unit:UnitBuff", UnitApi, "UnitBuff", "target", index)
        local id = readOk and type(buff) == "table" and Number(buff.buff_id or buff.buffId or buff.type or buff.id) or nil
        if id ~= nil and #self.lastObservedIds < 16 then self.lastObservedIds[#self.lastObservedIds + 1] = math.floor(id) end
        if id and map[id] then self.buffId, self.slot = math.floor(id), map[id].slot; break end
    end
    self.status = self.buffId and "ready" or "waiting"
    if self.buffId then
        self.message = map[self.buffId].text .. " · 技能栏 " .. tostring(self.slot) .. (Fishing.autoArmed and " · R 已自动映射" or "")
    else
        self.message = Fishing.autoArmed and "等待鱼的动作 Buff · R 保持当前映射" or "选中正在挣扎的鱼后显示推荐技能"
    end

    if Fishing.autoArmed == true and self.slot ~= nil then
        if type(FishingHotkey) ~= "table" then
            self.writeFailures = (tonumber(self.writeFailures) or 0) + 1
            self.lastWriteError = "FishingHotkeyV3 服务不可用"
            Fishing.autoArmed = false
            Fishing:ReleaseAutoLease("fishing_auto_missing_service")
            self.status, self.message = "error", "自动 R 不可用：FishingHotkeyV3 服务缺失"
            Fishing:RefreshAutoAvailability()
            self.revision = self.revision + 1
            PublishFeatureUpdate(Fishing, self.revision, "fishing_auto_missing_service")
            return false
        end
        local moved, moveErr = FishingHotkey:MoveR(self.slot, function(snapshot)
            return Fishing:PersistRecoverySnapshot(snapshot, "fishing_hotkey_touch_slot")
        end)
        if moved ~= true then
            self.writeFailures = (tonumber(self.writeFailures) or 0) + 1
            self.lastWriteError = tostring(moveErr or "hotkey move failed")
            Fishing.autoArmed = false
            self.autoArmed = false
            Fishing:ReleaseAutoLease("fishing_auto_write_failure")
            self.status, self.message = "error", "自动 R 设置失败：" .. self.lastWriteError
            Fishing:EnsureRecoveryTask()
            -- 中文维护：写入失败后不丢恢复快照；非战斗状态立即尝试回滚，战斗状态交给独立恢复任务，绝不继续切换新槽位。
            if FishingHotkey:InCombat() ~= true then Fishing:ProcessPendingRecovery(true, "auto_move_failure") end
            Fishing:RefreshAutoAvailability()
            self.revision = self.revision + 1
            PublishFeatureUpdate(Fishing, self.revision, "fishing_auto_write_failed")
            return false
        end
    end

    Fishing:RefreshAutoAvailability()
    self.revision = self.revision + 1
    PublishFeatureUpdate(Fishing, self.revision, "fishing_observation:" .. reason)
    return true
end

function FA:GetProjection() -- 中文维护：Presentation 只读 detached projection；Hotkey 服务内部快照/真实按键内容永不暴露给 UI。
    local hotkeyDiag = type(FishingHotkey) == "table" and type(FishingHotkey.GetDiagnostics) == "function" and FishingHotkey:GetDiagnostics() or nil
    return {
        patch = Fishing.Patch, revision = self.revision, status = self.status, message = self.message, buffId = self.buffId, slot = self.slot, zoneGroup = self.zoneGroup,
        autoArmed = Fishing.autoArmed == true, autoAvailable = self.autoAvailable == true, autoBlockedReason = self.autoBlockedReason,
        lastScanCount = self.lastScanCount, lastObservedIds = Copy(self.lastObservedIds), lastRefreshAt = self.lastRefreshAt, lastRefreshReason = self.lastRefreshReason,
        polls = self.polls, nativeEventRefreshes = self.nativeEventRefreshes, writeFailures = self.writeFailures, lastWriteError = self.lastWriteError,
        recoveryPending = Fishing:IsRecoveryPending(), hotkey = hotkeyDiag,
    }
end

function Fishing:AcquireAutoLease() -- 中文维护：Auto-R 持有自己的 Demand lease，避免用户关闭主页面后 consumer=0 导致刚启用的 R 映射立即被恢复。
    if self.autoLeaseHeld == true and self.Demand:Has(FISHING_AUTO_CONSUMER) then return true end
    local ok, err = self.Demand:Acquire(FISHING_AUTO_CONSUMER, { autoR = true }, "fishing_auto_r")
    if ok == true then self.autoLeaseHeld = true end
    return ok, err
end

function Fishing:ReleaseAutoLease(reason) -- 中文维护：先清本地 held 标志再 Release，防止 1→0 reconcile 回调再次进入 Disarm 形成递归；失败时恢复标志供后续清理。
    if self.autoLeaseHeld ~= true and self.Demand:Has(FISHING_AUTO_CONSUMER) ~= true then return true end
    self.autoLeaseHeld = false
    local ok, err = self.Demand:Release(FISHING_AUTO_CONSUMER, reason or "fishing_auto_r_release")
    if ok ~= true and self.Demand:Has(FISHING_AUTO_CONSUMER) then self.autoLeaseHeld = true end
    return ok, err
end

function Fishing:ArmAuto() -- 中文维护：启用流程固定为“能力/战斗检查→找到原 R→全槽快照→durable recovery→进入会话→按当前 Buff 映射”；顺序不可反转。
    if self.autoArmed == true then return true end
    if self.enabled ~= true or (tonumber(self.consumerCount) or 0) <= 0 then return false, "请先打开钓鱼页面或悬浮窗，再启用自动 R" end
    if type(FishingHotkey) ~= "table" then return false, "FishingHotkeyV3 服务不可用" end
    if type(self.State.recovery) == "table" and HasValidFishingRecovery(self.State.recovery) ~= true then
        self:RefreshAutoAvailability()
        return false, FA.autoBlockedReason or "旧版恢复记录无法验证"
    end
    if self:IsRecoveryPending() == true then
        local recovered, recoverErr = self:ProcessPendingRecovery(true, "before_arm")
        if recovered ~= true then return false, recoverErr or "仍有未完成的按键恢复" end
    end
    local supported, supportErr = FishingHotkey:IsSupported()
    if supported ~= true then self:RefreshAutoAvailability(); return false, supportErr end
    if FishingHotkey:InCombat() == true then self:RefreshAutoAvailability(); return false, "战斗中不能修改按键" end
    local original = FishingHotkey:FindOriginalRSlot()
    if original == nil then return false, "无法可靠读取当前 R 键所在动作栏位置，因此不会修改键位" end
    local snapshot, snapshotErr = FishingHotkey:BuildSessionSnapshot(original)
    if snapshot == nil then return false, snapshotErr end
    local persisted, persistErr = self:PersistRecoverySnapshot(snapshot, "fishing_hotkey_arm")
    if persisted ~= true then return false, "无法持久保存改键恢复快照，因此拒绝修改按键：" .. tostring(persistErr or "unknown") end
    local adopted, adoptErr = FishingHotkey:AdoptRecovery(snapshot)
    if adopted ~= true then return false, adoptErr end
    local leased, leaseErr = self:AcquireAutoLease()
    if leased ~= true then
        -- 中文维护：此时尚未执行 Native 写键；若独立 Auto-R Demand 无法建立，撤销内存会话并 durable 清除恢复记录，不能留下“其实没改键”的幽灵 recovery。
        FishingHotkey:ResetSession()
        self:ClearRecoveryRecord("fishing_auto_lease_rollback")
        return false, leaseErr or "自动 R 生命周期启动失败"
    end
    self.autoArmed = true
    self.recoveryNativeRestored = false
    FA.autoArmed = true
    FA.status, FA.message = "waiting", "自动 R 已启用 · 等待鱼动作"
    FA.lastWriteError = nil
    self:RefreshAutoAvailability()
    local refreshed, refreshErr = FA:Refresh("arm_auto")
    if refreshed ~= true then return false, refreshErr or FA.lastWriteError or "自动 R 初次映射失败" end
    S.SafeChat("钓鱼自动 R 已启用；关闭功能/悬浮窗或切换区域时会恢复原按键。")
    return true
end

function Fishing:DisarmAuto(silent) -- 中文维护：关闭时先停止新映射并释放 Auto-R 自有 Demand，再恢复；战斗中只标记 pending，不触碰受限 Hotkey API，脱战由恢复任务处理。
    self.autoArmed = false
    FA.autoArmed = false
    self:ReleaseAutoLease("fishing_auto_disarm")
    if self:IsRecoveryPending() ~= true then
        self:RefreshAutoAvailability()
        return true
    end
    if type(FishingHotkey) ~= "table" then return false, "FishingHotkeyV3 服务不可用" end
    if FishingHotkey:InCombat() == true then
        FishingHotkey.pendingRecovery = true
        FA.status, FA.message = "recovering", "战斗中不能改键 · 等待脱战恢复原 R"
        self:EnsureRecoveryTask()
        self:RefreshAutoAvailability()
        if silent ~= true then S.SafeChat("战斗中不能修改按键，脱战后自动恢复原 R。") end
        return false, "战斗中等待恢复"
    end
    return self:ProcessPendingRecovery(silent, "disarm")
end

function Fishing:IsAutoArmed() return self.autoArmed == true end -- 中文维护：Presentation 只查询 Feature 会话状态，不直接读 Hotkey 服务内部字段。

local function NormalizeFishingState(value) -- 中文维护：旧 Store schema 继续兼容；新增 recovery 仍在同一 schema 的可选字段，不删除窗口/用户偏好。
    value = type(value) == "table" and value or {}
    return {
        autoPreference = value.autoPreference == true,
        widgetVisible = value.widgetVisible == true,
        widgetWindow = type(value.widgetWindow) == "table" and Copy(value.widgetWindow) or nil,
        recovery = NormalizeFishingRecovery(value.recovery),
    }
end
RegisterStore(Fishing.storeId, "v3.life.fishing", function() return NormalizeFishingState(nil) end, function() return Copy(Fishing.State) end, function(value)
    value = NormalizeFishingState(value)
    Fishing.State.autoPreference = value.autoPreference == true
    Fishing.State.widgetVisible = value.widgetVisible == true
    Fishing.State.widgetWindow = type(value.widgetWindow) == "table" and Copy(value.widgetWindow) or nil
    Fishing.State.recovery = type(value.recovery) == "table" and Copy(value.recovery) or nil
end, NormalizeFishingState)
Fishing.ApiDependencies = { "X2Unit:UnitBuffCount", "X2Unit:UnitBuff", "X2Unit:GetCurrentZoneGroup", "X2Hotkey:GetOptionBinding", "X2Hotkey:BindingToOption", "X2Hotkey:SetOptionBindingWithIndex", "X2Hotkey:RemoveOptionBinding", "X2Hotkey:SaveHotKey", "X2Player:PlayerInCombat" } -- 中文维护：Registry/诊断必须公开真实依赖，不能再次把 Auto-R 写能力隐藏成“只读功能”。

function Fishing:Initialize() -- 中文维护：Reload 时先加载 Store，再优先修复未完成 Hotkey 事务；不会因为 autoPreference=true 自动重新改键。
    local ok, err = LoadStore(self)
    if ok ~= true then return ok, err end
    self.autoArmed = false
    if HasValidFishingRecovery(self.State.recovery) then
        if type(FishingHotkey) ~= "table" then return false, "检测到钓鱼按键恢复记录，但 FishingHotkeyV3 服务不可用" end
        local adopted, adoptErr = FishingHotkey:AdoptRecovery(NormalizeFishingSnapshot(self.State.recovery.snapshot))
        if adopted ~= true then return false, adoptErr end
        local recovered = self:ProcessPendingRecovery(true, "initialize_reload")
        if recovered ~= true then self:EnsureRecoveryTask() end
    elseif type(self.State.recovery) == "table" then
        -- 中文维护：历史实验记录不满足 v3 SnapshotContract，绝不自动解释/删除；这是最后一道防止误删真实用户按键的兼容边界。
        FA.status = "blocked"
        FA.message = "检测到无法验证的旧版自动 R 恢复记录"
        self:RefreshAutoAvailability()
        S.SafeChat(FA.autoBlockedReason or FA.message)
    else
        self:RefreshAutoAvailability()
    end
    return true
end

function Fishing:HandleWorldBoundary(reason) -- 中文维护：切地图/进入世界会改变动作栏上下文；先终止 Auto-R 并恢复，再重新观察，禁止携带旧槽位映射跨区域。
    if self.autoArmed == true or self:IsRecoveryPending() == true then self:DisarmAuto(true) end
    if self.enabled == true and (tonumber(self.consumerCount) or 0) > 0 then return FA:Refresh(reason or "world_boundary") end
    return true
end

function Fishing:ReconcileDemand(_, before, after) -- 中文维护：观察扫描严格由 Consumer 生命周期驱动；Auto-R 关闭/页面关闭时释放高频读，只有安全恢复任务可短暂独立存在。
    local beforeCount = tonumber(before and before.count) or 0
    local afterCount = tonumber(after and after.count) or 0
    if beforeCount <= 0 and afterCount > 0 then
        if S.Events == nil or S.Scheduler == nil or type(S.Scheduler.AddTask) ~= "function" or type(S.Scheduler.AddOneShot) ~= "function" then return false, "钓鱼观察事件/Scheduler 不可用" end
        S.Events:BindOwner(self, self.Id)
        local targetOk = S.Events:SubscribeOptional("TARGET_CHANGED", self, function(_)
            if Fishing.enabled and Fishing.consumerCount > 0 then return FA:Refresh("target_changed") end
            return true
        end)
        local buffOk = S.Events:SubscribeOptional("BUFF_UPDATE", self, function(_)
            if Fishing.enabled and Fishing.consumerCount > 0 then
                S.Scheduler:AddOneShot(FISHING_EVENT_TASK, 50, function()
                    if Fishing.enabled and Fishing.consumerCount > 0 then return FA:Refresh("buff_update") end
                    return true
                end, Fishing, "P1", 1)
            end
            return true
        end)
        local worldOk = S.Events:SubscribeOptional("ENTERED_WORLD", self, function(_) return Fishing:HandleWorldBoundary("entered_world") end)
        local zoneOk = S.Events:SubscribeOptional("ENTER_ANOTHER_ZONEGROUP", self, function(_) return Fishing:HandleWorldBoundary("zone_changed") end)
        if targetOk ~= true or buffOk ~= true or worldOk ~= true or zoneOk ~= true then S.Events:UnsubscribeOwner(self); return false, "钓鱼目标/Buff/区域事件订阅失败" end
        local added = S.Scheduler:AddTask(FISHING_POLL_TASK, FISHING_POLL_MS, function()
            if Fishing.enabled == true and (tonumber(Fishing.consumerCount) or 0) > 0 then return FA:Refresh("poll") end
            return true
        end, false, self, "P2", 1)
        if added ~= true then S.Events:UnsubscribeOwner(self); return false, "钓鱼 100ms 兜底扫描任务创建失败" end
        if type(S.Scheduler.SetTaskModule) == "function" then S.Scheduler:SetTaskModule(FISHING_POLL_TASK, self.Id, false); S.Scheduler:SetTaskModule(FISHING_EVENT_TASK, self.Id, false) end
        return FA:Refresh("consumer_start")
    elseif beforeCount > 0 and afterCount <= 0 then
        -- 中文维护：Auto-R 有自己的 lease；正常页面关闭不会走到 0。真正 0-consumer 时仅在仍 armed 的异常路径执行 Disarm，避免 ReleaseAutoLease 的 1→0 转换递归。
        if self.autoArmed == true then self:DisarmAuto(true) end
        if S.Events ~= nil then S.Events:UnsubscribeOwner(self) end
        if S.Scheduler ~= nil and type(S.Scheduler.RemoveTask) == "function" then S.Scheduler:RemoveTask(FISHING_POLL_TASK); S.Scheduler:RemoveTask(FISHING_EVENT_TASK) end
        if self:IsRecoveryPending() then self:EnsureRecoveryTask() end
    end
    return true
end

function Fishing:Enable() self.enabled = true; self:RefreshAutoAvailability(); return true end
function Fishing:Disable(reason) -- 中文维护：Disable 先清 Demand/停止扫描，再恢复 R；若战斗阻止恢复，低频 recovery task 继续到成功，不能因 Feature off 丢失恢复义务。
    self.autoLeaseHeld = false -- 中文维护：Demand:Clear 会原子删除 Auto-R token；先清本地标志，避免 reconcile 中 Disarm 再尝试 Release 已被 Clear 的 token。
    local ok, err = self.Demand:Clear(reason or "fishing_disable")
    if ok ~= true then return false, err end
    if S.Events then S.Events:UnsubscribeOwner(self) end
    if S.Scheduler and type(S.Scheduler.RemoveTask) == "function" then S.Scheduler:RemoveTask(FISHING_POLL_TASK); S.Scheduler:RemoveTask(FISHING_EVENT_TASK) end
    local restored, restoreErr = self:DisarmAuto(true)
    self.enabled = false
    if restored ~= true and self:IsRecoveryPending() then self:EnsureRecoveryTask() end
    return restored ~= false or self:IsRecoveryPending(), restoreErr
end
function Fishing:AcquireConsumer(token) if not self.enabled then return false, "钓鱼功能已关闭" end return self.Demand:Acquire(token, {}, "fishing_consumer") end
function Fishing:ReleaseConsumer(token) return self.Demand:Release(token, "fishing_consumer") end
function Fishing:Refresh(reason) if not self.enabled or self.consumerCount <= 0 then return true end return FA:Refresh(reason or "manual") end
function Fishing:GetProjection() return FA:GetProjection() end
Fishing.Commands = {
    Refresh = function(_, reason) return Fishing:Refresh(reason) end,
    ArmAuto = function() return Fishing:ArmAuto() end,
    DisarmAuto = function() return Fishing:DisarmAuto() end,
    GetWidgetVisible = function() return Fishing:GetWidgetVisible() end,
    SetWidgetVisible = function(_, value, reason) return Fishing:SetWidgetVisible(value, reason) end,
    SetWidgetWindowState = function(_, value, reason) return Fishing:SetWidgetWindowState(value, reason) end,
    MarkStoreDirty = function(_, delayMs, reason) return Fishing:MarkStoreDirty(delayMs, reason) end,
}
local fishingDemand, fishingErr = Demand:Create({ id = "feature:" .. Fishing.Id, owner = Fishing, projectionOwner = Fishing, projectionConsumersField = "consumers", projectionCountField = "consumerCount", reconcile = function(lease, before, after) return Fishing:ReconcileDemand(lease, before, after) end })
if fishingDemand == nil then error(fishingErr) end
Fishing.Demand = fishingDemand
ok, err = Runtime:RegisterImplementation(Fishing.Id, Fishing); if ok ~= true then error(err) end
