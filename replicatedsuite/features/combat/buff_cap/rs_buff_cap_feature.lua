------------------------------------------------------------------------
-- Replicated Suite V3 - combat_buff_cap Feature Authority
--
-- Phase 1 Batch C（2026-09-28）：从 features/rs_business_bridge.lua 机械搬迁（整块 do..end 原样搬运）。
-- 只改变源码边界，不改业务行为：Feature ID、Store ID/Schema、UpdateTopic、Demand owner、
-- Commands、Projection shape、ApiDependencies、两个 Scheduler task name
-- （v3_business_buff_cap_refresh / v3_business_buff_cap_poll）全部与被搬迁前逐字一致。
--
-- Authority 边界：本文件只拥有自身两种计数与用户阈值，不推断 RU 的 Buff 总容量、
-- 普通/隐藏是否共享槽位或顶替顺序，也不扫描 Aura 明细。
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local FSF = S.FeatureSliceFactory
if type(FSF) ~= "table" then error("FeatureSliceFactory unavailable for combat_buff_cap") end
local Call, Copy, Load, Text, NewFeature = FSF.Call, FSF.Copy, FSF.Load, FSF.Text, FSF.NewFeature
local P = S.Persistence
local UnitApi = rawget(_G, "X2Unit")

do
    -- 中文维护（2026-09-12，个人数量提醒）：此模块只拥有自身两种计数与用户阈值，
    -- 不推断 RU 的 Buff 总容量、普通/隐藏是否共享槽位或顶替顺序，也不扫描 Aura 明细。
    -- 复用原 Feature/Store ID；Permanent 仅三项设置，计数/峰值/提示边沿属于本次启用会话。
    local BUFF_CAP_REFRESH_TASK = "v3_business_buff_cap_refresh"
    local BUFF_CAP_POLL_TASK = "v3_business_buff_cap_poll"
    local REMINDER_TOKEN = "buff_cap:reminders"
    local CHANNELS = { "normal", "hidden" }
    local LABELS = { normal = "普通增益", hidden = "隐藏增益" }
    local POLL_MS, EDGE_MS, REMINDER_GAP_MS = 1000, 150, 5000

    local function Count(value)
        local n = tonumber(value)
        if n == nil or n ~= n or n == math.huge or n < 0 or n ~= math.floor(n) then return nil end
        return n -- 中文维护：0 是可靠读数；失败/nil/小数不是零，不把两类未知数相加冒充总量。
    end
    local function Threshold(value)
        local n = Count(value)
        if n == nil or n > 1000 then return nil end
        return n -- 中文维护：1000 仅是本地输入预算，绝非服务器容量；0 明确关闭该类提醒。
    end
    local function NewSession()
        return { counts = {}, peaks = {}, latched = {}, readErrors = {}, samples = 0,
            failedSamples = 0, delivered = 0, deliveryFailures = 0, observing = false }
    end
    local function HideOwn(feature, alertKey)
        local alerts = S.Services and S.Services.Alerts
        if alerts and type(alerts.HideOwner) == "function" then return alerts:HideOwner(feature.Id, alertKey) end
        return true -- 中文维护：缺来源级取消时不能退回全局 Hide，避免撤回首领警报。
    end
    local function Wanted(feature)
        return feature.enabled == true and feature.State.reminderEnabled == true
            and ((tonumber(feature.State.normalThreshold) or 0) > 0 or (tonumber(feature.State.hiddenThreshold) or 0) > 0)
    end
    local function Rows(feature)
        local session, rows = feature._buffCap, {}
        for _, key in ipairs(CHANNELS) do
            local count, peak = session.counts[key], session.peaks[key]
            local threshold = tonumber(feature.State[key .. "Threshold"]) or 0
            local high = count ~= nil and threshold > 0 and count >= threshold
            local text = threshold == 0 and "未设个人阈值" or ("个人阈值 " .. tostring(threshold))
            if feature.State.reminderEnabled ~= true then text = "提醒关闭 · " .. text
            elseif high then text = "已达到 · " .. text end
            if count == nil then text = session.observing and "读数不可用" or "未观察" end
            rows[#rows + 1] = { key = "buff_cap:" .. key, name = LABELS[key], count = count, peak = peak,
                available = count ~= nil, threshold = threshold, aboveThreshold = high,
                text = "当前 " .. Text(count, "未知") .. " · 本次启用峰值 " .. Text(peak, "--"),
                statusText = text, tone = count == nil and "muted" or (high and feature.State.reminderEnabled == true and "warn" or "default") }
        end
        if not session.observing then return rows, feature.enabled and "idle" or "stopped", session.lifecycleError end
        local normal, hidden = session.counts.normal, session.counts.hidden
        local status = normal ~= nil and hidden ~= nil and "ready" or (normal ~= nil or hidden ~= nil) and "partial" or "unavailable"
        local errors = {}
        for _, key in ipairs(CHANNELS) do
            if session.readErrors[key] ~= nil then errors[#errors + 1] = LABELS[key] .. "：" .. session.readErrors[key] end
        end
        if session.scheduleError ~= nil then errors[#errors + 1] = session.scheduleError end
        if session.lifecycleError ~= nil then errors[#errors + 1] = session.lifecycleError end
        return rows, status, #errors > 0 and table.concat(errors, "；") or nil
    end
    local function Publish(feature, reason)
        -- 中文维护：设置/停止/峰值重置只重新投影，不在 UI 命令回执或 Getter 偷读 Native。
        local authority = feature.Authority
        authority.rows, authority.status, authority.error = Rows(feature)
        authority.revision = authority.revision + 1
        if S.Events and type(S.Events.Publish) == "function" then S.Events:Publish(feature.UpdateTopic, authority.revision, reason) end
    end
    local function ChannelFree(feature)
        local alerts = S.Services and S.Services.Alerts
        if alerts == nil or type(alerts.Push) ~= "function" then return false, "AlertsService 不可用" end
        -- 中文维护：Alerts 是单通道；低优先级个人数量提醒不得替换首领等其它来源。
        -- 只观察服务公开状态，不改它的计时；等待期间每次重新核对当前可靠数量，不缓存旧告警文本。
        if alerts.currentText ~= nil and alerts.currentOwnerKey ~= feature.Id then return false, "其他提示正在显示", true end
        return true, alerts
    end
    local function Evaluate(feature)
        local session = feature._buffCap
        if not Wanted(feature) or not session.observing then return end
        local eligible, anyHigh = {}, false
        for _, key in ipairs(CHANNELS) do
            local threshold, count = tonumber(feature.State[key .. "Threshold"]) or 0, session.counts[key]
            if threshold <= 0 then session.latched[key] = nil
            elseif count ~= nil then
                if count < threshold then session.latched[key] = nil
                else
                    anyHigh = true
                    if session.latched[key] ~= true then eligible[#eligible + 1] = key end
                end
            end -- 中文维护：未知不等于状态消失，不重置已通知边沿，避免 API 暂时失败后重复响。
        end
        -- 中文维护：低于阈值只撤回自动提醒，不能在下一次采样误清仍处于3秒展示期的手动测试。
        -- Stop/关闭设置仍不传 key，以释放本模块全部提示；其它 owner 始终受 HideOwner 保护。
        if not anyHigh then HideOwn(feature, "personal_threshold") end
        if #eligible == 0 then return end
        local now = tonumber(S.NowMs and S.NowMs()) or 0
        if session.lastAttemptAt ~= nil and now - session.lastAttemptAt < REMINDER_GAP_MS then return end
        local free, alerts, busy = ChannelFree(feature)
        if busy then return end
        local parts = {}
        for _, key in ipairs(eligible) do
            parts[#parts + 1] = LABELS[key] .. " " .. tostring(session.counts[key]) .. "（个人阈值 " .. tostring(feature.State[key .. "Threshold"]) .. "）"
            session.latched[key] = true
        end
        -- 中文维护：两类同批越线合并一次。真正投递失败也消耗本次边沿并留下错误，不能每秒重试刷屏。
        session.lastAttemptAt = now
        local ok, err = false, alerts
        if free then
            ok, err = alerts:Push({ text = "增益数量提醒：" .. table.concat(parts, " · "), style = "bigtext",
                durationMs = 3000, ownerKey = feature.Id, alertKey = "personal_threshold",
                presentationConfig = { anchorMode = "top", fontSize = 28 } })
        end
        if ok == true then session.delivered = session.delivered + 1; session.reminderError = nil
        else session.deliveryFailures = session.deliveryFailures + 1; session.reminderError = tostring(err or "提醒投递失败") end
    end
    local function Sample(feature)
        local session = feature._buffCap
        if not session.observing or feature.enabled ~= true or (tonumber(feature.consumerCount) or 0) <= 0 then return Rows(feature) end
        local okA, a, errA = Call("X2Unit:UnitBuffCount", UnitApi, "UnitBuffCount", "player")
        local okB, b, errB = Call("X2Unit:UnitHiddenBuffCount", UnitApi, "UnitHiddenBuffCount", "player")
        session.counts.normal = okA == true and Count(a) or nil
        session.counts.hidden = okB == true and Count(b) or nil
        session.readErrors.normal = nil; session.readErrors.hidden = nil
        if session.counts.normal == nil then session.readErrors.normal = tostring(errA or "返回值不是有效非负整数") end
        if session.counts.hidden == nil then session.readErrors.hidden = tostring(errB or "返回值不是有效非负整数") end
        for _, key in ipairs(CHANNELS) do
            local count = session.counts[key]
            if count ~= nil then session.peaks[key] = math.max(count, session.peaks[key] or count) end
        end
        session.samples = session.samples + 1
        if session.counts.normal == nil or session.counts.hidden == nil then session.failedSamples = session.failedSamples + 1 end
        Evaluate(feature)
        return Rows(feature)
    end
    local function CancelEdge(feature)
        feature._buffCapEdgeSerial = (feature._buffCapEdgeSerial or 0) + 1
        feature._buffCapEdgePending = false
        if S.Scheduler and type(S.Scheduler.RemoveTask) == "function" then S.Scheduler:RemoveTask(BUFF_CAP_REFRESH_TASK) end
    end
    local function Stop(feature)
        -- 中文维护：先撤销 epoch 再删任务，旧回调即使被宿主持有也不得访问重启后的会话。
        feature._buffCapEpoch = (feature._buffCapEpoch or 0) + 1
        feature._buffCap.observing = false
        feature._buffCap.counts, feature._buffCap.readErrors, feature._buffCap.latched = {}, {}, {}
        CancelEdge(feature)
        if S.Scheduler and type(S.Scheduler.RemoveTask) == "function" then S.Scheduler:RemoveTask(BUFF_CAP_POLL_TASK) end
        HideOwn(feature)
        return true
    end
    local function Live(feature, epoch, generation)
        return ReplicatedSuite == S and S.Features.combat_buff_cap == feature and S.Generation == generation
            and feature.enabled == true and feature._buffCap.observing == true
            and feature._buffCapEpoch == epoch and (tonumber(feature.consumerCount) or 0) > 0
    end
    local function Reconcile(feature, before, after)
        local previous, nextCount = tonumber(before.count) or 0, tonumber(after.count) or 0
        if previous > 0 and nextCount <= 0 then Stop(feature); Publish(feature, "buff_cap_observation_stopped"); return true end
        if previous > 0 or nextCount <= 0 then return true end
        if S.Scheduler == nil or type(S.Scheduler.AddTask) ~= "function" then return false, "增益计数 Scheduler 不可用" end
        feature._buffCapEpoch = (feature._buffCapEpoch or 0) + 1
        local epoch, generation = feature._buffCapEpoch, S.Generation
        feature._buffCap.observing = true
        local added = S.Scheduler:AddTask(BUFF_CAP_POLL_TASK, POLL_MS, function()
            if not Live(feature, epoch, generation) then return end
            CancelEdge(feature) -- 中文维护：兜底已经取样时合并尚未执行的事件刷新，避免同帧双读。
            feature.Authority:Refresh("buff_cap_fallback")
        end, false, feature, "P2", 1)
        if added ~= true then Stop(feature); return false, "增益计数兜底任务创建失败" end
        if type(S.Scheduler.SetTaskModule) == "function" then S.Scheduler:SetTaskModule(BUFF_CAP_POLL_TASK, feature.Id, true) end
        return true
    end
    local function OnEvent(feature)
        -- 中文维护：旧代码反复 Remove/Add 尾沿 debounce，在连续 BUFF_UPDATE 下会一直延后。
        -- 首次事件安排150ms刷新，后续只合并；不猜事件参数身份，读取范围始终只有 player 两个 getter。
        if feature._buffCapEdgePending then return true end
        if S.Scheduler == nil or type(S.Scheduler.AddTask) ~= "function" then return false, "增益计数 Scheduler 不可用" end
        local epoch, generation = feature._buffCapEpoch, S.Generation
        feature._buffCapEdgeSerial = (feature._buffCapEdgeSerial or 0) + 1
        local serial = feature._buffCapEdgeSerial
        feature._buffCapEdgePending = true
        -- 中文维护：在同名任务移除之前核对代次；通用 AddOneShot 会先移除同名任务，
        -- 迟到旧 wrapper 可能误删新任务。这里复用 Scheduler 的有限自移除任务，不另建计时器。
        local added = S.Scheduler:AddTask(BUFF_CAP_REFRESH_TASK, EDGE_MS, function()
            if not Live(feature, epoch, generation) or feature._buffCapEdgeSerial ~= serial then return end
            CancelEdge(feature)
            feature.Authority:Refresh("buff_cap_event")
        end, false, feature, "P2", 1)
        if added ~= true then
            feature._buffCapEdgePending = false
            feature._buffCap.scheduleError = "事件合并任务创建失败，保留1秒兜底"
            Publish(feature, "buff_cap_schedule_failed")
            return false, feature._buffCap.scheduleError
        end
        feature._buffCap.scheduleError = nil
        if type(S.Scheduler.SetTaskModule) == "function" then S.Scheduler:SetTaskModule(BUFF_CAP_REFRESH_TASK, feature.Id, true) end
        return true
    end
    local function SyncReminder(feature)
        local wanted, held = Wanted(feature), feature.Demand:Has(REMINDER_TOKEN)
        if wanted and not held then return feature.Demand:Acquire(REMINDER_TOKEN, {}, "buff_cap_reminder") end
        if not wanted and held then return feature.Demand:Release(REMINDER_TOKEN, "buff_cap_reminder_off") end
        return true
    end
    local function Commit(feature, key, value)
        local loaded, loadErr = Load(feature); if loaded ~= true then return false, loadErr end
        local changed = feature.State[key] ~= value
        if changed then
            -- 中文维护：先耐久保存和回读，再切换需求/提示；失败由原 Store 事务还原，不能提前执行副作用。
            local ok, err = P:MutateStore(feature.storeId, function() feature.State[key] = value; return true end,
                { durable = true, reason = "buff_cap_settings" })
            if ok ~= true then return false, err end
            -- 中文维护：两个个人阈值是独立业务通道；修改隐藏阈值不能重新通知已越线的普通增益。
            -- 只重新准备被编辑通道；总开关才清两类边沿，保留原5秒投递节流及来源级撤回。
            if key == "normalThreshold" then feature._buffCap.latched.normal = nil
            elseif key == "hiddenThreshold" then feature._buffCap.latched.hidden = nil
            else feature._buffCap.latched = {} end
            HideOwn(feature)
        end
        -- 中文维护：无变化也允许恢复上次启动失败的观察，但不重复写盘；已保存与运行失败分开回执。
        local synced, syncErr = SyncReminder(feature)
        feature._buffCap.lifecycleError = synced ~= true and tostring(syncErr or "观察切换失败") or nil
        if synced == true then Evaluate(feature) end
        Publish(feature, "buff_cap_settings")
        if synced ~= true then return false, "设置已保存，但观察切换失败：" .. tostring(syncErr) end
        return true
    end

    local BuffCap = NewFeature("combat_buff_cap", {
        apiDependencies = { "X2Unit:UnitBuffCount", "X2Unit:UnitHiddenBuffCount" }, observationContractVersion = 2,
        state = { reminderEnabled = false, normalThreshold = 0, hiddenThreshold = 0 },
        default = { reminderEnabled = false, normalThreshold = 0, hiddenThreshold = 0 },
        apply = function(value, state)
            -- 中文维护：旧 schema1 空配置沿原 key 读取；缺省关闭，不自动写迁移、不把显式 false/0 改为开启。
            value = type(value) == "table" and value or {}
            state.reminderEnabled = value.reminderEnabled == true
            state.normalThreshold = Threshold(value.normalThreshold) or 0
            state.hiddenThreshold = Threshold(value.hiddenThreshold) or 0
        end,
        onEnable = function(feature)
            local ok, err = Load(feature); if ok ~= true then return false, err end
            feature._buffCap = NewSession()
            return SyncReminder(feature)
        end,
        onDisable = function(feature) Stop(feature); Publish(feature, "buff_cap_disabled"); return true end,
        reconcileDemand = Reconcile, event = "BUFF_UPDATE", onEvent = OnEvent, read = Sample,
        projection = function(feature)
            local session = feature._buffCap
            local rows, status = Rows(feature)
            return { rows = rows, status = status, observing = session.observing,
                reminderEnabled = feature.State.reminderEnabled == true,
                normalThreshold = feature.State.normalThreshold, hiddenThreshold = feature.State.hiddenThreshold,
                samples = session.samples, failedSamples = session.failedSamples, delivered = session.delivered,
                deliveryFailures = session.deliveryFailures, reminderError = session.reminderError }
        end,
        commands = {
            SetReminderEnabled = function(feature, value)
                if type(value) ~= "boolean" then return false, "提醒开关必须为布尔值" end
                return Commit(feature, "reminderEnabled", value)
            end,
            SetThreshold = function(feature, key, value)
                if key ~= "normal" and key ~= "hidden" then return false, "请选择普通或隐藏增益" end
                local number = Threshold(value)
                if number == nil then return false, "个人阈值必须为0-1000的整数；0表示关闭该类提醒" end
                return Commit(feature, key .. "Threshold", number)
            end,
            ResetPeaks = function(feature)
                -- 中文维护：仅重置本次启用的历史统计，不清配置、不重读、不重新准备提醒边沿。
                feature._buffCap.peaks = Copy(feature._buffCap.counts)
                Publish(feature, "buff_cap_peaks_reset")
                return true
            end,
            TestReminder = function(feature)
                if feature.enabled ~= true then return false, "请先启用增益容量监控" end
                local free, alerts = ChannelFree(feature)
                if free ~= true then return false, alerts end
                -- 中文维护：手动路径只证明 Presenter，不注入虚假计数、峰值或自动提醒成功统计。
                return alerts:Push({ text = "增益数量提醒测试（非容量警报）", style = "bigtext", durationMs = 3000,
                    ownerKey = feature.Id, alertKey = "manual_test", presentationConfig = { anchorMode = "top", fontSize = 28 } })
            end,
        },
    })
    BuffCap._buffCap = NewSession()
    BuffCap.PersonalReminderContractVersion = 1 -- 中文维护：局部交付标识，不提升为 RU 实机通过或改变全局 BuildTag。
end
