------------------------------------------------------------------------
-- Replicated Suite - Shared screen-alert channel (report 七-方案A)
-- Author: Replicated
--
-- S.Services.Alerts:Push({text, style, durationMs, sound}) is the single
-- screen-wide notification channel. Combat alerts are the first consumer
-- (旧 plates rp_runtime, 已删除); event reminders ("screen" tier) and fishing/trade
-- feedback can join later without duplicating the host window.
--
-- Design:
--   * Push-driven, NEVER polled. The host window is shown by Push and hidden
--     by one Scheduler task. A replacement owns its own deadline; same-key
--     repeats may extend their deadline, so producers deduplicate cast segments.
--   * Same-text alerts overwrite (re-arm the timer) instead of stacking.
--   * style "countdown" renders "text  N" (remaining seconds) updated by the
--     same scheduler tick; "bigtext" renders plain text.
--   * anchorMode, fontSize, width and signed offsets are presentation options;
--     the Feature owns persistent configuration, the Presenter owns the host.
--   * Explicit layout editing leases mouse input through shared Windowing.
--     Normal alerts are click-through; no native widget is owned by this service.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
S.Services = S.Services or {}
S.Services.Alerts = {
    started = false,
    presenter = nil,
    currentText = nil,
    currentStyle = nil,
    expiresAt = 0,
    remainingMs = 0,
    tickTask = nil,
    -- 中文维护：提示来源和计时只属于 Alerts 状态，不属于业务开关或 Native UI。
    -- source/key 仅用于取消自有提示；旧调用不传它们仍兼容，不能全局 Hide 清掉其他模块提醒。
    currentOwnerKey = nil, currentAlertKey = nil, countdownEndsAt = nil, tickGeneration = 0,
    ticks = 0, timerRepairs = 0, presentationFailures = 0, consecutiveTextFailures = 0,
}
local A = S.Services.Alerts
A.presentationBoundary = "service_only"
A.presentationDebt = nil

local TICK_INTERVAL_MS = 100
local DEFAULT_DURATION_MS = 3000
local MAX_DURATION_MS = 15000

local Trim = S.Reuse.Text.Trim

-- Presentation is injected by a host-side presenter.  The service owns only
-- alert state/timing; it never creates or mutates Native UI.  This dependency
-- inversion lets Legacy and V3 presenters consume the same service without
-- making the service depend on either presentation stack.
function A:SetPresenter(presenter)
    if presenter ~= nil and type(presenter) ~= "table" then return false end
    if self.presenter ~= nil and self.presenter ~= presenter and type(self.presenter.Hide) == "function" then
        pcall(self.presenter.Hide, self.presenter)
    end
    self.presenter = presenter
    return true
end

function A:_Present(method, ...)
    local presenter = self.presenter
    local fn = presenter ~= nil and presenter[method] or nil
    if type(fn) ~= "function" then return false end
    local ok, result, detail = pcall(fn, presenter, ...)
    if not ok or result == false then
        -- 中文维护（boss-hud-clock-1）：原来 Native 写入拒绝被 Presenter 吞掉后仍记作成功；
        -- 统一保留拒绝证据，不依赖游戏内用户抢在冻结前复制。固定计数，不累积无限日志。
        self.presentationFailures = self.presentationFailures + 1
        self.lastPresentationError = tostring(ok and (detail or "presenter_rejected") or result)
        self.lastPresentationMethod = tostring(method)
        if S.DiagnosticsManager ~= nil and type(S.DiagnosticsManager.ErrorRateLimited) == "function" then
            S.DiagnosticsManager:ErrorRateLimited("alerts", "PRESENTER_CALL_FAILED", 3000,
                "Presenter 调用失败：" .. tostring(method), { error = self.lastPresentationError, method = tostring(method) })
        end
        return false
    end
    return result ~= false
end

-- Push one alert (no stacking). Same owner/key/text may extend the expiry;
-- a replacement uses its own duration. Returns true only after accepted Show.
function A:Push(payload)
    if self.started ~= true then return false, "alerts_not_started" end
    if type(payload) ~= "table" then return false, "invalid_alert" end
    local text = Trim(payload.text)
    if text == "" then return false, "empty_alert" end
    local cfg = type(payload.presentationConfig) == "table" and payload.presentationConfig
        or ((S.Services and S.Services.PlatesCfg and S.Services.PlatesCfg()) or nil)
    local style = tostring(payload.style or "bigtext")
    local durationMs = math.max(500, math.min(MAX_DURATION_MS, tonumber(payload.durationMs) or DEFAULT_DURATION_MS))
    local now = S.NowMs()
    local remainingMs = math.max(0, math.min(300000, tonumber(payload.remainingMs) or 0))
    -- 中文维护：倒计时按观察剩余时间存活（最大五分钟技术保护），普通大字仍沿用原时长。
    -- 不从技能名推算未来 CD；长读条不再被默认三秒文字提示寿命提前收走。
    if style == "countdown" and remainingMs > 0 then durationMs = math.max(500, remainingMs) end
    local ownerKey = payload.ownerKey ~= nil and tostring(payload.ownerKey) or nil
    local alertKey = payload.alertKey ~= nil and tostring(payload.alertKey) or nil
    local labelText = text
    if style == "countdown" and remainingMs > 0 then
        labelText = string.format("%s  %d", text, math.max(1, math.ceil(remainingMs / 1000)))
    end

    -- 中文维护：校验真实调度任务而非仅信任 tickTask 布尔值；被维护工具清掉任务后
    -- 新提示必须重新注册。服务仍是唯一计时 Authority；不让页面 OnUpdate 自建第二个时钟。
    local scheduled, created = self:EnsureTimer(true)
    if scheduled ~= true then return false, created end
    if self:_Present("Show", labelText, cfg) ~= true then
        -- 中文维护：若修复的是旧提示丢失的计时器，新提示拒绝也必须保留旧截止点的回收任务。
        if created and self.currentText == nil then
            S.Scheduler:RemoveTask("alerts_tick")
            self.tickTask = nil
            self.tickGeneration = self.tickGeneration + 1
        end
        return false, "alert_presenter_rejected"
    end
    local sameText = self.currentText == text and self.currentOwnerKey == ownerKey and self.currentAlertKey == alertKey
    self.currentText, self.currentStyle, self.currentRemainingMs = text, style, remainingMs
    self.currentOwnerKey, self.currentAlertKey = ownerKey, alertKey
    self.expiresAt = sameText and math.max(now + durationMs, self.expiresAt) or (now + durationMs)
    -- 中文维护：显示寿命与机制剩余时间是两条独立时间轴；3 秒 HUD 不能把真实 6 秒读条改成 3 秒。
    -- 倒计时只扣单调时钟，不推断技能 CD；expiresAt 仍决定何时收回窗口。
    self.countdownEndsAt = remainingMs > 0 and (now + remainingMs) or nil
    self.labelLastText = labelText
    self.consecutiveTextFailures = 0
    return true
end

-- 中文维护：只注册一个 P1 可见告警任务，100ms 检查但整数秒变化才写文本。
-- GetTaskState 为公开只读接口；不绕过正在工作的 scheduler 熔断。仅显式 Push 可恢复 disabled 任务。
function A:EnsureTimer(explicitPush)
    local scheduler = S.Scheduler
    if scheduler == nil or type(scheduler.AddTask) ~= "function" then return false, "alert_scheduler_unavailable" end
    local state = type(scheduler.GetTaskState) == "function" and scheduler:GetTaskState("alerts_tick") or nil
    local missing = type(state) == "table" and state.registered ~= true
    local disabled = type(state) == "table" and state.registered == true and state.enabled ~= true
    if self.tickTask == true and not missing and not (explicitPush and disabled) then return true, false end
    if self.tickTask == true then self.timerRepairs = self.timerRepairs + 1 end
    self.tickGeneration = self.tickGeneration + 1
    local generation = self.tickGeneration
    local added = scheduler:AddTask("alerts_tick", TICK_INTERVAL_MS, function()
        if A.tickGeneration ~= generation or A.tickTask ~= true or S.Services.Alerts ~= A then return end
        A:Tick()
    end, false, self, "P1", 1)
    if added ~= true then return false, "alert_schedule_failed" end
    self.tickTask = true
    return true, true
end

-- 中文维护：已有业务观察回调可请求修复丢失的任务，不改原倒计时截止时间，不增加后台心跳。
function A:Maintain(ownerKey)
    if self.started ~= true or self.currentText == nil or self.currentOwnerKey ~= tostring(ownerKey) then return true end
    local ok, repaired = self:EnsureTimer(false)
    if ok == true and repaired == true then self:Tick() end
    return ok, repaired
end

function A:Tick()
    local now = S.NowMs()
    self.ticks, self.lastTickAt = self.ticks + 1, now
    if now >= self.expiresAt or self.currentText == nil then return self:Hide() end
    if self.currentStyle == "countdown" and self.countdownEndsAt ~= nil then
        local left = math.max(0, math.ceil((self.countdownEndsAt - now) / 1000))
        local text = self.currentText .. "  " .. left
        if self.labelLastText ~= text then
            -- 中文维护：只有 Presenter 接收成功才推进文字缓存，拒绝写入可由下一次既有 tick 重试。
            if self:_Present("UpdateText", text) == true then
                self.labelLastText, self.consecutiveTextFailures = text, 0
            else
                self.consecutiveTextFailures = self.consecutiveTextFailures + 1
                -- 中文维护：连续拒写时撤掉失真的倒计时，错误保留在 Describe；不永远卡着旧秒数。
                if self.consecutiveTextFailures >= 3 then return self:Hide() end
            end
        end
    end
end

function A:Hide()
    -- 中文维护：失效旧 tick 闭包，防止停止后再次 Push 时，旧闭包操作新提示。
    self.tickGeneration = self.tickGeneration + 1
    self.currentText, self.currentRemainingMs, self.countdownEndsAt = nil, nil, nil
    self.currentOwnerKey, self.currentAlertKey = nil, nil
    self.expiresAt = 0
    self:_Present("Hide")
    if self.tickTask == true and S.Scheduler ~= nil and type(S.Scheduler.RemoveTask) == "function" then
        S.Scheduler:RemoveTask("alerts_tick")
    end
    self.tickTask = nil
    return true
end

-- 中文维护：Feature/逐条规则关闭只撤回自己仍占用的提示；单通道被别的业务替换后不能误清。
function A:HideOwner(ownerKey, alertKey)
    if ownerKey == nil then return false, "alert_owner_required" end
    -- 中文维护：关闭整个拥有者要释放校准鼠标租约；关闭单条规则不影响显式校准。
    if alertKey == nil and self.editOwnerKey == tostring(ownerKey) then self:SetLayoutEditor(ownerKey, false) end
    if self.currentOwnerKey == tostring(ownerKey)
        and (alertKey == nil or self.currentAlertKey == tostring(alertKey)) then return self:Hide() end
    return true
end

-- 中文维护：Feature 通过服务注入持久化回调，Presenter/Windowing 只呈现并提交几何。
-- 校准状态仅会话内持有，不能写入配置或跨停用存活；普通告警仍保持穿透。
function A:SetLayoutEditor(ownerKey, enabled, cfg, onCommit)
    if ownerKey == nil then return false, "alert_owner_required" end
    ownerKey = tostring(ownerKey)
    if not enabled and self.editOwnerKey ~= ownerKey then return true end
    if enabled and self.editOwnerKey ~= nil and self.editOwnerKey ~= ownerKey then return false, "layout_editor_busy" end
    if self:_Present("EditLayout", enabled == true, cfg, onCommit) ~= true then return false, self.lastPresentationError end
    self.editOwnerKey = enabled == true and ownerKey or nil
    return true
end

function A:ConfigureOwner(ownerKey, cfg)
    if self.currentOwnerKey ~= tostring(ownerKey) and self.editOwnerKey ~= tostring(ownerKey) then return true end
    if self:_Present("ApplyLayout", cfg) ~= true then return false, self.lastPresentationError end
    return true
end

function A:Describe()
    local scheduler = S.Scheduler
    local task = scheduler and type(scheduler.GetTaskState) == "function" and scheduler:GetTaskState("alerts_tick") or {registered=false}
    local presenter
    if self.presenter and type(self.presenter.Describe) == "function" then
        local ok, value = pcall(self.presenter.Describe, self.presenter); if ok then presenter = value end
    end
    return {patch="boss-hud-clock-1", started=self.started, ticks=self.ticks, lastTickAt=self.lastTickAt,
        nowMs=S.NowMs(), expiresAt=self.expiresAt, countdownEndsAt=self.countdownEndsAt,
        owner=self.currentOwnerKey, alertKey=self.currentAlertKey, renderedText=self.labelLastText,
        timerRepairs=self.timerRepairs, presentationFailures=self.presentationFailures,
        lastPresentationError=self.lastPresentationError, lastPresentationMethod=self.lastPresentationMethod,
        editingOwner=self.editOwnerKey, task=task, presenter=presenter}
end

function A:Start()
    if self.started == true then return true end
    self.started = true
    return true
end

function A:Stop()
    if self.editOwnerKey ~= nil then self:SetLayoutEditor(self.editOwnerKey, false) end
    self.started = false
    self:Hide()
    return true
end
