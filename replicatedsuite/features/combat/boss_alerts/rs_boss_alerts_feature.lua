------------------------------------------------------------------------
-- Replicated Suite V3 - combat_boss_alerts Feature Authority
--
-- Phase 1 Batch C（2026-09-28）：从 features/rs_business_bridge.lua 机械搬迁（整块 do..end 原样搬运）。
-- 只改变源码边界，不改业务行为：Feature ID、Store ID/Schema、UpdateTopic、Demand owner、
-- Commands、Projection shape、ApiDependencies、Scheduler task name、Event 订阅全部与被搬迁前逐字一致。
--
-- Authority 边界：本文件不拥有 Combat 事实（事实归 CastingObservationV3 / AuraObservationV3 与
-- AlertsService），只按固定目录/四个 scope 做有界观察，并把“没证据”如实标成未知。
--------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local FSF = S.FeatureSliceFactory
if type(FSF) ~= "table" then error("FeatureSliceFactory unavailable for combat_boss_alerts") end
local Load, NewFeature = FSF.Load, FSF.NewFeature
local P = S.Persistence

do
    -- 中文维护（2026-09-12）：首领规则是 Feature 的业务 Authority；Casting/Aura 仅供事实，
    -- Alerts 仅负责提示寿命。逐条开关用稳定 key 持久化，目录不被写入；默认缺省=启用，兼容旧 HUD-only 存档。
    local BOSS_OBSERVE_TASK = "v3_business_boss_alert_observe"
    local BOSS_AURA_INTERVAL_MS = 300
    local BOSS_CAST_SCOPES = { "target", "targettarget", "watchtarget", "player" }
    local function NormalizeCastKey(value)
        return string.lower(tostring(value or ""):gsub("^%s*(.-)%s*$", "%1"))
    end
    local BossCastIndex, BossDebuffIndex, BossRuleIndex, BossRules = {}, {}, {}, {}
    for _, value in ipairs(S.Data and S.Data.BossAlerts or {}) do
        local row = type(value) == "table" and value or {}
        local key = tostring(row.key or "")
        if key ~= "" and BossRuleIndex[key] == nil then
            BossRuleIndex[key] = row
            BossRules[#BossRules + 1] = row
            if row.kind == "cast" then
                for _, name in ipairs(type(row.names) == "table" and row.names or {}) do
                    local normalized = NormalizeCastKey(name)
                    if normalized ~= "" then BossCastIndex[normalized] = row end
                end
            elseif row.kind == "debuff" and tonumber(row.debuffId) ~= nil then
                BossDebuffIndex[tonumber(row.debuffId)] = row
            end
        end
    end

    local function BossRuleEnabled(feature, key)
        return not (type(feature.State.items) == "table" and feature.State.items[key] == false)
    end
    local function BossEnabledCount(feature)
        local count = 0
        for _, rule in ipairs(BossRules) do if BossRuleEnabled(feature, rule.key) then count = count + 1 end end
        return count
    end
    local function BossHide(feature, key)
        local alerts = S.Services and S.Services.Alerts
        if alerts and type(alerts.HideOwner) == "function" then return alerts:HideOwner(feature.Id, key) end
        return true -- 中文维护：旧服务无按 owner 隐藏时不退回全局 Hide，避免清除别的业务提示。
    end
    local function BossTestKey(key) return "__boss_test:" .. tostring(key) end
    -- 中文维护（boss-hud-clock-1）：可选字段避免改动旧 HUD-only 存档的缺省形状；
    -- Feature 是设置 Authority，服务/Presenter 接收分离配置，不得反向写 State。
    local function BossHudConfig(feature)
        return {anchorMode=feature.State.hudAnchor, fontSize=feature.State.hudFontSize,
            offsetX=feature.State.hudOffsetX, offsetY=feature.State.hudOffsetY, width=feature.State.hudWidth}
    end
    local function BossSaveLayout(feature, mutator)
        local loaded, loadErr = Load(feature); if loaded ~= true then return false, loadErr end
        local ok, err = P:MutateStore(feature.storeId, function() return mutator(feature.State) end,
            {durable=true, reason="boss_hud_layout"})
        if ok ~= true then return false, err end
        local alerts = S.Services and S.Services.Alerts
        local applied, applyErr = true, nil
        if alerts and type(alerts.ConfigureOwner) == "function" then applied, applyErr = alerts:ConfigureOwner(feature.Id, BossHudConfig(feature)) end
        feature.Authority:Refresh("boss_hud_layout_saved")
        if applied ~= true then return false, "设置已保存，但 HUD 布局未应用：" .. tostring(applyErr) end
        return true
    end
    local function BossNumber(value, low, high)
        local n = tonumber(value)
        if n == nil or n ~= n or n == math.huge or n == -math.huge then return nil end
        return math.floor(math.max(low, math.min(high, n)))
    end
    local function BossPush(feature, rule, remainingMs, alertKey)
        if feature.State.hudEnabled ~= true then return false, "请先启用首领机制 HUD" end
        if type(rule) ~= "table" then return false, "首领规则不存在" end
        if not BossRuleEnabled(feature, rule.key) then return false, "该规则已关闭" end
        local alerts = S.Services and S.Services.Alerts
        if type(alerts) ~= "table" or type(alerts.Push) ~= "function" then return false, "AlertsService 不可用" end
        local style = tostring(rule.style or "bigtext")
        local duration = math.max(1000, math.min(10000, math.floor(tonumber(feature.State.hudDurationMs) or 3000)))
        local remaining = math.max(0, math.floor(tonumber(remainingMs) or 0))
        -- 中文维护：读条必须覆盖实际剩余时间；hudDurationMs 仅控制普通大字提示，不截断长读条。
        if style == "countdown" and remaining > 0 then duration = remaining end
        -- 中文维护：不把显示时长当作读条剩余时间；来源/key 让停用只回收当前规则的提示。
        return alerts:Push({ text = tostring(rule.alert or rule.key), style = style, durationMs = duration,
            remainingMs = style == "countdown" and remaining or 0, ownerKey = feature.Id, alertKey = alertKey or rule.key,
            presentationConfig = BossHudConfig(feature) })
    end
    local function BossDeliver(feature, rule, remaining, source)
        local dia = feature._bossDiag
        dia.lastFactSource, dia.matchedRule = source, tostring(rule.key)
        dia.lastMechanicAt = math.max(0, tonumber(S.NowMs and S.NowMs()) or 0)
        local ok, err = BossPush(feature, rule, remaining)
        -- 中文维护：失败也消费本次观察边沿，防止 100ms 无限重试；保留可见失败证据，不虚报已显示。
        if ok == true then
            dia.delivered = (tonumber(dia.delivered) or 0) + 1
            dia.lastDeliveryError = nil
        else
            dia.deliveryFailures = (tonumber(dia.deliveryFailures) or 0) + 1
            dia.lastDeliveryError = tostring(err or "提示显示失败")
        end
    end

    local function BossObserve(feature)
        if feature.enabled ~= true or feature._bossObservationStarted ~= true
            or (tonumber(feature.consumerCount) or 0) <= 0 or feature.State.hudEnabled ~= true then return true end
        local dia = feature._bossDiag
        dia.observeTicks = (tonumber(dia.observeTicks) or 0) + 1
        local alerts = S.Services and S.Services.Alerts
        -- 中文维护：恢复被维护清理掉的计时任务，不重复 Push、不延后真实截止点。
        if alerts and type(alerts.Maintain) == "function" then alerts:Maintain(feature.Id) end
        local casting = S.Services and S.Services.CastingObservationV3
        if type(casting) == "table" and type(casting.Get) == "function" then
            local previous, matches, restarts = feature._bossCastSignatures, feature._bossCastMatches, feature._bossCastRestarts
            for key in pairs(matches) do matches[key] = nil end
            for key in pairs(restarts) do restarts[key] = nil end
            local complete, observed = true, nil
            for _, scope in ipairs(BOSS_CAST_SCOPES) do
                local coverage = type(casting.GetCoverage) == "function" and casting:GetCoverage(scope) or nil
                local available = type(coverage) == "table" and coverage.available == true
                complete = complete and available
                local cast = casting:Get(scope)
                if available and type(cast) == "table" and cast.casting == true then
                    local rule = BossCastIndex[NormalizeCastKey(cast.spellName)]
                    local old = previous[scope]
                    -- 中文维护：未收录读条只来自当前目标/关注目标的真实观测，不猜 Boss ID/未来 CD；
                    -- 不把自己的技能、目标的目标混作机制。固定两个候选，不全单位扫描。
                    if rule == nil and feature.State.showObservedCasts == true and observed == nil
                        and (scope == "target" or scope == "watchtarget") then
                        observed = {scope=scope, serial=cast.serial, spellName=cast.spellName, remaining=cast.remainingMs}
                    end
                    if rule ~= nil then
                        if matches[rule.key] == nil then matches[rule.key] = { rule = rule, remaining = cast.remainingMs, source = scope } end
                        if old ~= nil and old.ruleKey == rule.key and old.serial ~= cast.serial then restarts[rule.key] = true end
                    end
                    previous[scope] = { ruleKey = rule and rule.key or nil, serial = cast.serial }
                    dia.lastFactSource, dia.castingSkill = scope, tostring(cast.spellName)
                    local ring = dia.castNames
                    if ring[cast.spellName] ~= true then
                        ring[cast.spellName] = true; ring[#ring + 1] = cast.spellName
                        if #ring > 8 then ring[table.remove(ring, 1)] = nil end
                    end
                elseif available then previous[scope] = nil end
            end
            dia.castCoverageComplete = complete
            -- 中文维护：同机制同时出现在多个 scope 时只合并“提示”，不宣称它们是同一实体。
            -- 真实空观察可结束通知段；同 scope 读条进度回退可重开一段；未知读取不得伪造结束。
            -- 固定目录/四个 scope 有界遍历，精确索引匹配；不做全单位枚举、Tag 模糊匹配或热路径保存。
            for _, rule in ipairs(BossRules) do
                if rule.kind == "cast" then
                    local match = matches[rule.key]
                    if match ~= nil and BossRuleEnabled(feature, rule.key) then
                        if not feature._bossActiveCasts[rule.key] or restarts[rule.key] then
                            BossDeliver(feature, rule, match.remaining, match.source)
                        end
                        feature._bossActiveCasts[rule.key] = match.source
                    else
                        -- 中文维护（boss-hud-clock-1）：以前要求四个 scope 都可读才能结束段；
                        -- 无关注目标/无效第三方读条会让已结束规则永远处于 active，漏掉下次施法。
                        -- 只让本提示实际观测来源的“已可读且不再匹配”结束段；未知不伪造打断。
                        local source = feature._bossActiveCasts[rule.key]
                        local ownCoverage = type(source) == "string" and casting:GetCoverage(source) or nil
                        if complete or (ownCoverage and ownCoverage.available) or not BossRuleEnabled(feature, rule.key) then
                            feature._bossActiveCasts[rule.key] = nil
                            BossHide(feature, rule.key)
                        end
                    end
                end
            end
            -- 中文维护：已知机制/手动测试/其他模块提示优先，泛化读条不得抢占它们。
            -- 只按 scope+serial 建立一次倒计时；后续采样不反复重置，断读仅按已有截止点失效。
            local activeKey = alerts and alerts.currentAlertKey or nil
            local isObserved = alerts and alerts.currentOwnerKey == feature.Id
                and type(activeKey) == "string" and activeKey:sub(1,9) == "observed:"
            if observed ~= nil then
                local old = feature._bossObserved
                local changed = old == nil or old.scope ~= observed.scope or old.serial ~= observed.serial or old.spellName ~= observed.spellName
                if changed and alerts and (alerts.currentText == nil or isObserved) then
                    BossDeliver(feature, {key="observed:" .. observed.scope, alert="读条：" .. tostring(observed.spellName), style="countdown"},
                        observed.remaining, observed.scope)
                    feature._bossObserved = observed
                end
            elseif feature._bossObserved ~= nil then
                local old = feature._bossObserved
                local coverage = casting:GetCoverage(old.scope)
                if coverage and coverage.available then
                    BossHide(feature, "observed:" .. old.scope); feature._bossObserved = nil
                end
            end
        end
        local now = math.max(0, tonumber(S.NowMs and S.NowMs()) or 0)
        if now < feature._bossNextAuraAt then return true end
        feature._bossNextAuraAt = now + BOSS_AURA_INTERVAL_MS
        local aura = S.Services and S.Services.AuraObservationV3
        if type(aura) ~= "table" or type(aura.GetSnapshot) ~= "function" or type(aura.GetStatusMap) ~= "function" then return true end
        local snapshot = aura:GetSnapshot("player", { buff = false, debuff = true, hidden = false, debuffLimit = 64, ttlMs = 250 })
        if type(snapshot) ~= "table" then return true end
        local statusMap, meta = aura:GetStatusMap(snapshot, { buff = false, debuff = true, hidden = false })
        statusMap = type(statusMap) == "table" and statusMap or {}
        dia.auraCoverageComplete = type(meta) == "table" and meta.available == true and meta.complete == true and meta.reliable == true
        for id, rule in pairs(BossDebuffIndex) do
            if statusMap[id] ~= nil and BossRuleEnabled(feature, rule.key) then
                if not feature._bossActiveDebuffs[id] then
                    feature._bossActiveDebuffs[id] = true
                    dia.playerDebuff = tostring(id)
                    BossDeliver(feature, rule, 0, "player_debuff")
                end
            elseif dia.auraCoverageComplete or not BossRuleEnabled(feature, rule.key) then feature._bossActiveDebuffs[id] = nil end
        end
        return true
    end

    local function BossStopObservation(feature)
        -- 中文维护：先使回调代次失效，再释放租约；旧闭包不能在下次启用时复用新需求。
        feature._bossObservationGeneration = (tonumber(feature._bossObservationGeneration) or 0) + 1
        feature._bossObservationStarted = false
        if S.Scheduler ~= nil and type(S.Scheduler.RemoveTask) == "function" then S.Scheduler:RemoveTask(BOSS_OBSERVE_TASK) end
        local firstErr
        for _, pair in ipairs({ {field = "_bossAuraHeld", service = "AuraObservationV3", token = "boss_alerts:aura"},
            {field = "_bossCastingHeld", service = "CastingObservationV3", token = "boss_alerts:casting"} }) do
            local service = S.Services and S.Services[pair.service]
            if feature[pair.field] == true then
                local ok, err = false, "观察服务释放入口不可用"
                if service and type(service.ReleaseConsumer) == "function" then ok, err = service:ReleaseConsumer(pair.token) end
                if ok == true then feature[pair.field] = false else firstErr = firstErr or err end
            end
        end
        feature._bossCastSignatures, feature._bossActiveCasts, feature._bossActiveDebuffs = {}, {}, {}
        feature._bossCastMatches, feature._bossCastRestarts, feature._bossNextAuraAt = {}, {}, 0
        feature._bossObserved = nil
        BossHide(feature)
        return firstErr == nil, firstErr
    end
    local function BossStartObservation(feature)
        if feature._bossObservationStarted then return true end
        local casting, aura = S.Services and S.Services.CastingObservationV3, S.Services and S.Services.AuraObservationV3
        if type(casting) ~= "table" or type(casting.AcquireConsumer) ~= "function" then return false, "CastingObservationV3 不可用" end
        if type(aura) ~= "table" or type(aura.AcquireConsumer) ~= "function" then return false, "AuraObservationV3 不可用" end
        local ok, err = casting:AcquireConsumer("boss_alerts:casting", {player = true, target = true, targettarget = true, watchtarget = true, intervalMs = 100, purpose = "boss_alerts"})
        if ok ~= true then return false, err end
        feature._bossCastingHeld = true
        ok, err = aura:AcquireConsumer("boss_alerts:aura", {purpose = "boss_alerts"})
        if ok ~= true then BossStopObservation(feature); return false, err end
        feature._bossAuraHeld = true
        if S.Scheduler == nil or type(S.Scheduler.AddTask) ~= "function" then BossStopObservation(feature); return false, "首领机制 Scheduler 不可用" end
        feature._bossObservationGeneration = (tonumber(feature._bossObservationGeneration) or 0) + 1
        local generation = feature._bossObservationGeneration
        ok = S.Scheduler:AddTask(BOSS_OBSERVE_TASK, 100, function()
            if feature._bossObservationGeneration ~= generation or S.Features[feature.Id] ~= feature then return true end
            return BossObserve(feature)
        end, false, feature, "P2", 1)
        if ok ~= true then BossStopObservation(feature); return false, "首领机制观察任务创建失败" end
        if type(S.Scheduler.SetTaskModule) == "function" then S.Scheduler:SetTaskModule(BOSS_OBSERVE_TASK, feature.Id, false) end
        feature._bossObservationStarted = true
        feature._bossCastSignatures, feature._bossActiveCasts, feature._bossActiveDebuffs = {}, {}, {}
        feature._bossCastMatches, feature._bossCastRestarts, feature._bossNextAuraAt = {}, {}, 0
        feature._bossDiag = feature._bossDiag or {observeTicks = 0, delivered = 0, deliveryFailures = 0,
            lastFactSource = "none", castingSkill = "", playerDebuff = "", matchedRule = "", lastMechanicAt = 0, castNames = {}}
        return BossObserve(feature)
    end
    local function BossSyncObservation(feature)
        if feature.enabled == true and (tonumber(feature.consumerCount) or 0) > 0
            and feature.State.hudEnabled == true and (BossEnabledCount(feature) > 0 or feature.State.showObservedCasts == true) then
            return BossStartObservation(feature)
        end
        return BossStopObservation(feature)
    end
    local function BossCommitRules(feature, key, enabled)
        if type(enabled) ~= "boolean" then return false, "规则开关必须为布尔值" end
        if key ~= nil and BossRuleIndex[key] == nil then return false, "首领规则不存在：" .. tostring(key) end
        local loaded, loadErr = Load(feature)
        if not loaded then return false, loadErr end
        local changed = false
        for _, rule in ipairs(BossRules) do
            if (key == nil or rule.key == key) and BossRuleEnabled(feature, rule.key) ~= enabled then changed = true end
        end
        if not changed then return true end
        -- 中文维护：用户显式开关必须经过现有耐久事务及回读；失败回滚 State，不更新投影/观察。
        -- 全部启停仅提交一次；nil key 仅是私有批量入口，不把用户输入作为任意存档字段名。
        local ok, err = P:MutateStore(feature.storeId, function()
            feature.State.items = type(feature.State.items) == "table" and feature.State.items or {}
            for _, rule in ipairs(BossRules) do
                if key == nil or rule.key == key then
                    if enabled then feature.State.items[rule.key] = nil else feature.State.items[rule.key] = false end
                end
            end
            return true
        end, {durable = true, reason = "boss_rule_settings"})
        if ok ~= true then return false, err end
        if enabled ~= true then
            BossHide(feature, key)
            -- 中文维护（2026-10-07）：逐条关闭同时取消对应测试；nil key 已按 owner 清除全部提示。
            if key ~= nil then BossHide(feature, BossTestKey(key)) end
        end
        -- 中文维护：重新启用可提示仍在观察到的当前机制；这是设置操作边沿，不修改事实或伪造状态。
        for _, rule in ipairs(BossRules) do
            if key == nil or rule.key == key then
                if feature._bossActiveCasts then feature._bossActiveCasts[rule.key] = nil end
                if feature._bossActiveDebuffs and rule.debuffId then feature._bossActiveDebuffs[rule.debuffId] = nil end
            end
        end
        local started, startErr = BossSyncObservation(feature)
        feature.Authority:Refresh("boss_rules_saved")
        if started ~= true then return false, "规则已保存，但观察启动/停止失败：" .. tostring(startErr) end
        return true
    end
    local function BossTestRule(feature, key, kind)
        local rule = key ~= nil and BossRuleIndex[tostring(key)] or nil
        if key == nil then
            for _, candidate in ipairs(BossRules) do
                if (kind == nil or candidate.kind == kind) and BossRuleEnabled(feature, candidate.key) then rule = candidate; break end
            end
        end
        if rule == nil or (kind ~= nil and rule.kind ~= kind) then return false, "未找到可测试的对应规则" end
        -- 中文维护（2026-10-07）：仿真独立提示 key，让真实“未施法”观察不能在下个 tick 撤掉测试。
        -- 寿命仍归共享 Alerts 的原截止点；不写真实观察事实/诊断，不自建计时或证明 RU Boss 已触发。
        return BossPush(feature, rule, rule.kind == "cast" and 6000 or 0, BossTestKey(rule.key))
    end

    -- 中文维护：静态规则配置不依赖启用/消费租约；首次打开已关闭功能也要能配置。
    -- 纯投影读 State，不触发 Native/Store/事件；运行期 read 与初始目录回退复用同一构建函数。
    local function BossRuleRows(feature)
        local rows = {}
        for _, rule in ipairs(BossRules) do
            local trigger
            if rule.kind == "cast" then
                trigger = "施法：" .. table.concat(rule.names or {}, " / ")
            else trigger = "自身 Debuff ID：" .. tostring(rule.debuffId or "--") end
            local enabled = BossRuleEnabled(feature, rule.key)
            rows[#rows + 1] = {key = "boss:" .. rule.key, name = tostring(rule.alert or rule.key), text = trigger,
                enabled = enabled, statusText = enabled and (rule.style == "countdown" and "已启用 · 倒计时" or "已启用 · 大字") or "已关闭",
                tone = enabled and "success" or "muted", mechanicKey = rule.key, kind = rule.kind, style = rule.style, debuffId = tonumber(rule.debuffId)}
        end
        if #rows == 0 then return rows, "empty", "BossAlerts 静态目录为空" end
        return rows, "ready" -- 中文维护：避免 `true and nil or error` 把成功投影也写成错误。
    end

    local BossAlerts = NewFeature("combat_boss_alerts", {
        apiDependencies = { "X2Unit:UnitCastingInfo", "X2Unit:UnitDeBuffCount", "X2Unit:UnitDeBuff", "X2Unit:UnitDeBuffTooltip" },
        observationContractVersion = 3,
        onEnable = function(feature)
            -- 中文维护：关闭设置页不等于关闭警报；运行期租约只随 Feature 停用/重载清除。
            if feature.Demand:Has("boss_alerts:runtime") then return true end
            return feature.Demand:Acquire("boss_alerts:runtime", {}, "boss_alert_runtime")
        end,
        -- 中文维护：新增可选字段只有显式调整时写入；不向旧完整性快照强加非 nil 默认字段。
        persistentKeys = {"hudOffsetX", "hudOffsetY", "hudWidth", "showObservedCasts"},
        state = { hudEnabled = true, hudAnchor = "center", hudFontSize = 34, hudDurationMs = 3000, items = {} },
        default = { hudEnabled = true, hudAnchor = "center", hudFontSize = 34, hudDurationMs = 3000, items = {} },
        reconcileDemand = function(feature) return BossSyncObservation(feature) end,
        onDisable = function(feature) return BossStopObservation(feature) end,
        read = BossRuleRows,
        projection = function(feature)
            local initialRows
            if #feature.Authority.rows == 0 then initialRows = BossRuleRows(feature) end
            return {rows = initialRows, hudEnabled = feature.State.hudEnabled == true, hudAnchor = feature.State.hudAnchor,
                hudFontSize = tonumber(feature.State.hudFontSize) or 34, hudDurationMs = tonumber(feature.State.hudDurationMs) or 3000,
                enabledRuleCount = BossEnabledCount(feature), ruleCount = #BossRules,
                realtime = feature._bossObservationStarted == true, diag = feature._bossDiag,
                showObservedCasts = feature.State.showObservedCasts == true,
                hudOffsetX = tonumber(feature.State.hudOffsetX) or 0, hudOffsetY = tonumber(feature.State.hudOffsetY) or 0,
                hudWidth = tonumber(feature.State.hudWidth) or 720,
                hudEditing = S.Services and S.Services.Alerts and S.Services.Alerts.editOwnerKey == feature.Id,
                hudHealth = S.Services and S.Services.Alerts and type(S.Services.Alerts.Describe) == "function" and S.Services.Alerts:Describe() or nil}
        end,
        commands = {
            SetRuleEnabled = function(feature, key, value)
                if type(key) ~= "string" or key == "" then return false, "请选择有效规则" end
                return BossCommitRules(feature, key, value)
            end,
            SetAllRulesEnabled = function(feature, value) return BossCommitRules(feature, nil, value) end,
            TestRule = function(feature, key)
                if type(key) ~= "string" or key == "" then return false, "请先选择规则" end
                return BossTestRule(feature, key)
            end,
            SetHudEnabled = function(feature, value)
                if type(value) ~= "boolean" then return false, "HUD 开关必须为布尔值" end
                -- 中文维护：低频显式开关先耐久保存，保存失败不改变观察/提示生命周期。
                local ok, err = P:MutateStore(feature.storeId, function() feature.State.hudEnabled = value; return true end,
                    {durable = true, reason = "boss_hud_enabled"})
                if ok ~= true then return false, err end
                local synced, syncErr = BossSyncObservation(feature)
                feature.Authority:Refresh("boss_hud_saved")
                if synced ~= true then return false, "HUD 设置已保存，但观察切换失败：" .. tostring(syncErr) end
                return true
            end,
            SetHudAnchor = function(feature, value)
                return BossSaveLayout(feature, function(state)
                    state.hudAnchor = value == "top" and "top" or "center"
                    state.hudOffsetX, state.hudOffsetY = nil, nil; return true
                end)
            end,
            SetHudFontSize = function(feature, value)
                local n = BossNumber(value, 18, 56); if n == nil then return false, "请输入有效字号" end
                return BossSaveLayout(feature, function(state) state.hudFontSize=n; return true end)
            end,
            SetHudDurationMs = function(feature, value)
                local n = BossNumber(value, 1000, 10000); if n == nil then return false, "请输入有效显示时长" end
                return BossSaveLayout(feature, function(state) state.hudDurationMs=n; return true end)
            end,
            SetHudOffsetX = function(feature, value)
                local n = BossNumber(value, -8192, 8192); if n == nil then return false, "请输入有效水平偏移" end
                return BossSaveLayout(feature, function(state) state.hudOffsetX=n; return true end)
            end,
            SetHudOffsetY = function(feature, value)
                local n = BossNumber(value, -8192, 8192); if n == nil then return false, "请输入有效垂直偏移" end
                return BossSaveLayout(feature, function(state) state.hudOffsetY=n; return true end)
            end,
            SetHudWidth = function(feature, value)
                local n = BossNumber(value, 280, 1200); if n == nil then return false, "请输入有效宽度" end
                return BossSaveLayout(feature, function(state) state.hudWidth=n; return true end)
            end,
            ResetHudLayout = function(feature)
                return BossSaveLayout(feature, function(state)
                    state.hudOffsetX,state.hudOffsetY,state.hudWidth=nil,nil,nil
                    state.hudAnchor,state.hudFontSize="center",34; return true
                end)
            end,
            SetHudEditing = function(feature, enabled)
                if type(enabled) ~= "boolean" then return false, "校准开关必须为布尔值" end
                local alerts = S.Services and S.Services.Alerts
                if not alerts or type(alerts.SetLayoutEditor) ~= "function" then return false, "HUD 校准服务不可用" end
                local ok, err = alerts:SetLayoutEditor(feature.Id, enabled, BossHudConfig(feature), function(x,y,width)
                    x,y,width=BossNumber(x,-8192,8192),BossNumber(y,-8192,8192),BossNumber(width,280,1200)
                    if x == nil or y == nil or width == nil then return false, "HUD 几何无效，未保存" end
                    return BossSaveLayout(feature, function(state)
                        state.hudOffsetX,state.hudOffsetY,state.hudWidth=BossNumber(x,-8192,8192),BossNumber(y,-8192,8192),BossNumber(width,280,1200)
                        return true
                    end)
                end)
                feature.Authority:Refresh("boss_hud_editor")
                return ok, err
            end,
            SetShowObservedCasts = function(feature, enabled)
                if type(enabled) ~= "boolean" then return false, "观察开关必须为布尔值" end
                local ok, err = P:MutateStore(feature.storeId, function()feature.State.showObservedCasts=enabled;return true end,
                    {durable=true,reason="boss_observed_casts"})
                if ok ~= true then return false, err end
                if not enabled then
                    BossHide(feature,"observed:target");BossHide(feature,"observed:watchtarget");feature._bossObserved=nil
                end
                local synced, syncErr = BossSyncObservation(feature);feature.Authority:Refresh("boss_observed_casts_saved")
                return synced, syncErr
            end,
            TestBigText = function(feature)
                return BossPush(feature, {key = "__hud_test_big", alert = "首领机制 HUD 测试", style = "bigtext"}, 0)
            end,
            TestCountdown = function(feature)
                return BossPush(feature, {key = "__hud_test_countdown", alert = "机制倒计时", style = "countdown"},
                    6000) -- 中文维护：固定六秒，6/5/4/3/2/1 后隐藏，便于验证实际调度而非静态标签。
            end,
            SimulateCast = function(feature, key) return BossTestRule(feature, key, "cast") end,
            SimulateDebuff = function(feature, key) return BossTestRule(feature, key, "debuff") end,
        },
    })
    BossAlerts.HudContractVersion = 4 -- 中文维护：可校准 HUD、调度健康证据、可选未收录读条；旧命令兼容。
    BossAlerts.RealtimeFactBridgeContractVersion = 2
    BossAlerts.RuleManagementContractVersion = 1
end

-- 中文维护注释（Phase 3 Batch G，2026-09-29，core-feature-decoupling-1）：把首领机制的诊断投影
-- 注册到 Core 的取值表。原先 core/rs_diagnostics.lua 直接按 id 读取它（属 CORE_FEATURE 债务）；
-- 现在 Core 只按“用途名”取值，业务 Feature id 只出现在本目录。provider 每次实时调用、不缓存。
local providers = S.FeatureHealthProviders
if type(providers) == "table" then
    providers:Register("boss_alerts_diagnostics", function()
        local feature = S.Features and S.Features.combat_boss_alerts or nil
        return type(feature) == "table" and type(feature._bossDiag) == "table" and feature._bossDiag or nil
    end)
end
