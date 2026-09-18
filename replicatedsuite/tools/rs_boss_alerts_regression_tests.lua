-- 中文维护：仅开发期回归，不进入 toc.g。被测链为真实 Casting/Alerts/Demand/Events/Store/Feature；
-- Native 施法、Aura 快照、磁盘和 Presenter 是可控替身；这些结果不等于 RU 客户端验收。
-- 每例新建 generation，覆盖逐条规则、耐久回读、同机制提示合并、计时与停止后迟到回调。
local passed, failed = 0, 0
local function Test(name, fn)
    local ok, err = pcall(fn)
    if ok then passed = passed + 1; print('PASS boss-alerts ' .. name)
    else failed = failed + 1; print('FAIL boss-alerts ' .. name .. ': ' .. tostring(err)) end
end
local H = dofile('tools/rs_udf_numeric_test_host.lua')
local function Boot(disk)
    local S, P, io = H.Boot(disk)
    local c = { now = 1000, casts = {}, reads = 0, shows = {}, updates = {}, hides = 0,
        debuffs = {}, complete = true, auraReads = 0, rejectShow = false }
    S.SafeTraceback = debug.traceback
    S.NowMs = function() return c.now end
    dofile('core/rs_events.lua'); dofile('core/rs_scheduler.lua')
    X2Unit = { UnitCastingInfo = function(_, scope)
        c.reads = c.reads + 1
        return H.Copy(c.casts[scope])
    end }
    local aura = {}
    aura.Demand = assert(S.Demand:Create({id = 'test:boss:aura', owner = aura}))
    function aura:AcquireConsumer(token, options) return self.Demand:Acquire(token, options) end
    function aura:ReleaseConsumer(token) return self.Demand:Release(token) end
    function aura:GetSnapshot()
        c.auraReads = c.auraReads + 1
        return { map = H.Copy(c.debuffs), complete = c.complete }
    end
    function aura:GetStatusMap(snapshot)
        return snapshot.map, { available = snapshot.complete, complete = snapshot.complete, reliable = snapshot.complete }
    end
    S.Services.AuraObservationV3 = aura
    dofile('services/rs_casting_observation_v3.lua')
    dofile('services/rs_alerts_service.lua')
    local A = S.Services.Alerts
    A:SetPresenter({ Show = function(_, text)
        if c.rejectShow then return false end
        c.shows[#c.shows + 1] = text; return true
    end, UpdateText = function(_, text) c.updates[#c.updates + 1] = text; return true end,
    Hide = function() c.hides = c.hides + 1; return true end })
    assert(A:Start())
    dofile('data/rs_boss_alerts.lua')
    local originalCatalog = H.Copy(S.Data.BossAlerts)
    dofile('features/rs_business_bridge.lua')
    local F = S.Features.combat_boss_alerts
    assert(F:Initialize()); assert(F:Enable())
    c.originalCatalog = originalCatalog
    function c:Cast(scope, current, total, name)
        self.casts[scope] = { spellName = name or 'Smash Earth', currCastingTime = current or 0, castingTime = total or 6000 }
    end
    function c:Step(ms)
        self.now = self.now + (ms or 100)
        S.Services.CastingObservationV3:Refresh('test')
        local task = S.Scheduler.tasks.v3_business_boss_alert_observe
        if task then task.callback() end
    end
    return S, F, c, P, io, A
end
local function Row(F, key)
    for _, row in ipairs(F:GetProjection().rows or {}) do if row.mechanicKey == key then return row end end
    error('missing rule ' .. key)
end
local function Set(F, key, enabled)
    assert(type(F.Commands.SetRuleEnabled) == 'function', 'missing SetRuleEnabled command')
    return F.Commands:SetRuleEnabled(key, enabled)
end
Test('compiling indexes leaves the static catalog immutable', function()
    local S, F, c = Boot(); assert(H.Eq(S.Data.BossAlerts, c.originalCatalog), 'runtime wrote into static BossAlerts rows')
end)
Test('all five catalog rules expose an enabled management row', function()
    local S, F = Boot(); local p = F:GetProjection()
    assert(#p.rows == 5 and p.enabledRuleCount == 5, 'missing rule-count projection')
    for _, row in ipairs(p.rows) do assert(row.enabled == true and row.mechanicKey ~= nil) end
    assert(p.error == nil, 'ready rule catalog carries a false empty-catalog error')
end)
Test('one disabled rule is durable and remains disabled after reload', function()
    local S, F, c, P, io = Boot(); assert(Set(F, 'smash_earth', false))
    assert(Row(F, 'smash_earth').enabled == false and io.writes == 1, 'not a single durable save')
    local _, F2 = Boot(io.disk)
    assert(Row(F2, 'smash_earth').enabled == false and Row(F2, 'ghost_hit').enabled == true)
end)
Test('unchanged rule does not rewrite the store', function()
    local S, F, c, P, io = Boot(); assert(Set(F, 'smash_earth', false)); local n = io.writes
    assert(Set(F, 'smash_earth', false)); assert(io.writes == n, 'no-op rewrites storage')
end)
Test('invalid identity or non-boolean state cannot mutate the store', function()
    local S, F, c, P, io = Boot()
    assert(Set(F, 'not_a_rule', false) == false); assert(Set(F, 'ghost_hit', 'false') == false)
    assert(io.writes == 0 and Row(F, 'ghost_hit').enabled == true)
end)
Test('failed durable write rolls the rule back and preserves the original save', function()
    local S, F, c, P, io = Boot(); assert(Set(F, 'smash_earth', false)); local disk = H.Copy(io.disk)
    ADDON.SaveData = function() return false end
    local ok = Set(F, 'ghost_hit', false)
    assert(ok == false and Row(F, 'ghost_hit').enabled == true and H.Eq(disk, io.disk))
end)
Test('old HUD-only schema still loads with all rules enabled', function()
    local S, F, c, P, io = Boot()
    assert(P:SaveValue(F.storeId, {hudEnabled = true, hudAnchor = 'top', hudFontSize = 40, hudDurationMs = 2500}, {durable = true, verifyAfterSave = true}))
    local _, F2 = Boot(io.disk); local p = F2:GetProjection()
    assert(p.hudAnchor == 'top' and p.hudFontSize == 40 and p.enabledRuleCount == 5)
end)
Test('all-rules action commits once and releases unnecessary observation', function()
    local S, F, c, P, io = Boot()
    assert(type(F.Commands.SetAllRulesEnabled) == 'function', 'missing bulk rule command')
    assert(F.Commands:SetAllRulesEnabled(false)); assert(io.writes == 1)
    assert(F:GetProjection().enabledRuleCount == 0 and F:GetProjection().realtime == false)
    assert(S.Scheduler.tasks.v3_business_boss_alert_observe == nil)
    assert(S.Services.CastingObservationV3.Demand.count == 0 and S.Services.AuraObservationV3.Demand.count == 0)
    assert(F.Commands:SetAllRulesEnabled(true)); assert(io.writes == 2 and F:GetProjection().realtime == true)
end)
Test('disabled cast and debuff rules cannot emit live alerts', function()
    local S, F, c = Boot(); assert(Set(F, 'smash_earth', false)); assert(Set(F, 'ghost_hit', false))
    c:Cast('target', 0); c.debuffs[23474] = {}; c:Step(350)
    assert(#c.shows == 0)
end)
Test('test selected rule refuses disabled and unknown rules', function()
    local S, F, c = Boot(); assert(Set(F, 'ghost_hit', false))
    assert(type(F.Commands.TestRule) == 'function', 'missing TestRule command')
    assert(F.Commands:TestRule('ghost_hit') == false and F.Commands:TestRule('unknown') == false)
    assert(#c.shows == 0)
end)
Test('test selected rule uses stable catalog identity', function()
    local S, F, c = Boot(); assert(type(F.Commands.TestRule) == 'function', 'missing TestRule command')
    assert(F.Commands:TestRule('underwater')); assert(c.shows[1] == '下水！')
end)
Test('simulation also obeys per-rule disable', function()
    local S, F, c = Boot(); assert(Set(F, 'smash_earth', false))
    assert(F.Commands:SimulateCast('smash_earth') == false and #c.shows == 0)
end)
Test('four aliases observing a mechanic produce one notification, not four', function()
    local S, F, c = Boot()
    for _, scope in ipairs({'target', 'targettarget', 'watchtarget', 'player'}) do c:Cast(scope, 0) end
    c:Step(); assert(#c.shows == 1, 'same mechanic rendered ' .. #c.shows .. ' times')
end)
Test('ongoing cast does not re-arm every observation tick', function()
    local S, F, c = Boot(); c:Cast('target', 0); c:Step()
    for i = 1, 6 do c:Cast('target', i * 100); c:Step() end
    assert(#c.shows == 1)
end)
Test('back-to-back same-name casts re-arm without an idle sample', function()
    local S, F, c = Boot(); c:Cast('target', 4500); c:Step()
    c:Cast('target', 0); c:Step(); assert(#c.shows == 2, 'second cast was swallowed')
end)
Test('moving the observed mechanic between scopes does not fabricate a recast', function()
    local S, F, c = Boot(); c:Cast('target', 500); c:Step()
    c.casts.target = nil; c:Cast('watchtarget', 600); c:Step()
    assert(#c.shows == 1)
end)
Test('malformed timing is unavailable rather than a fabricated one-ms cast', function()
    local S, F, c = Boot(); c.casts.target = {spellName = 'Smash Earth'}; c:Step()
    assert(#c.shows == 0)
    assert(type(S.Services.CastingObservationV3.GetCoverage) == 'function', 'missing cast coverage')
    assert(S.Services.CastingObservationV3:GetCoverage('target').available == false)
end)
Test('unreliable cast read does not create a false end and duplicate restart', function()
    local S, F, c = Boot(); c:Cast('target', 500); c:Step()
    c.casts.target = {spellName = 'Smash Earth', castingTime = 0/0}; c:Step()
    c:Cast('target', 700); c:Step(); assert(#c.shows == 1)
end)
Test('real empty cast observation allows the next cast to alert again', function()
    local S, F, c = Boot(); c:Cast('target', 500); c:Step()
    c.casts.target = nil; c:Step(); c:Cast('target', 0); c:Step(); assert(#c.shows == 2)
end)
Test('debuff disappearance requires reliable complete coverage', function()
    local S, F, c = Boot(); c.debuffs[23474] = {}; c:Step(350)
    c.complete = false; c.debuffs = {}; c:Step(350)
    c.complete = true; c.debuffs[23474] = {}; c:Step(350)
    assert(#c.shows == 1)
    c.debuffs = {}; c:Step(350); c.debuffs[23474] = {}; c:Step(350)
    assert(#c.shows == 2)
end)
Test('scope-only consumer does not force unrelated target reads', function()
    local S, F, c = Boot(); assert(F:Disable())
    local C = S.Services.CastingObservationV3
    assert(C:AcquireConsumer('focus_only', {target = false, watchtarget = true}))
    assert(C.scopes.target == false and C.scopes.watchtarget == true, 'focus-only lease unexpectedly acquired target')
end)
Test('adding and removing a non-primary scope reconciles the live polling set', function()
    local S, F, c = Boot(); assert(F:Disable()); local C = S.Services.CastingObservationV3
    assert(C:AcquireConsumer('target_only', {target = true, intervalMs = 100}))
    assert(C:AcquireConsumer('more', {target = true, targettarget = true, intervalMs = 100}))
    assert(C.scopes.targettarget == true, 'scope change did not update active task')
    assert(C:ReleaseConsumer('more')); assert(C.scopes.targettarget == false)
end)
Test('retired casting task cannot read again after a later acquisition', function()
    local S, F, c = Boot(); local old = S.Scheduler.tasks.v3_casting_observation_refresh.callback
    assert(F:Disable()); assert(F:Enable()); local n = c.reads
    old(); assert(c.reads == n, 'old task executed in a new observation generation')
end)
Test('retired mechanic task cannot observe after feature restarts', function()
    local S, F, c = Boot(); local old = S.Scheduler.tasks.v3_business_boss_alert_observe.callback
    assert(F:Disable()); assert(F:Enable()); c.now = c.now + 1000
    local n = c.auraReads; old(); assert(c.auraReads == n, 'old mechanic task reused new leases')
end)
Test('HUD off dismisses its current alert immediately', function()
    local S, F, c, P, io, A = Boot(); assert(F.Commands:TestCountdown()); assert(A.currentText ~= nil)
    assert(F.Commands:SetHudEnabled(false)); assert(A.currentText == nil and S.Scheduler.tasks.alerts_tick == nil)
end)
Test('feature disable does not dismiss another owners alert', function()
    local S, F, c, P, io, A = Boot()
    assert(A:Push({text = '其他模块提醒', ownerKey = 'other', durationMs = 5000}))
    assert(F:Disable()); assert(A.currentText == '其他模块提醒')
end)
Test('disabled selected rule dismisses only its own active notification', function()
    local S, F, c, P, io, A = Boot(); c:Cast('target', 0); c:Step(); assert(A.currentText ~= nil)
    assert(Set(F, 'smash_earth', false)); assert(A.currentText == nil)
end)
Test('countdown uses the true remaining time rather than display lifetime', function()
    local S, F, c, P, io, A = Boot()
    assert(A:Push({text = '倒计时', style = 'countdown', durationMs = 3000, remainingMs = 6000}))
    assert(c.shows[#c.shows] == '倒计时  6')
    c.now = c.now + 1000; A:Tick(); assert(c.updates[#c.updates] == '倒计时  5', 'display duration replaced skill time')
    -- 中文维护（boss-hud-clock-1）：新需求要求完整读条，不再按普通三秒文字时长提前隐藏。
    c.now = c.now + 2000; A:Tick(); assert(A.currentText ~= nil and c.updates[#c.updates] == '倒计时  3')
    c.now = c.now + 3000; A:Tick(); assert(A.currentText == nil)
end)
Test('presenter rejection is visible to the rule-test command', function()
    local S, F, c, P, io, A = Boot(); c.rejectShow = true
    assert(F.Commands:SimulateCast('smash_earth') == false, 'failed presentation reported success')
    assert(A.currentText == nil and S.Scheduler.tasks.alerts_tick == nil)
end)
Test('alert scheduler rejection does not leave an immortal notification', function()
    local S, F, c, P, io, A = Boot(); local add = S.Scheduler.AddTask
    S.Scheduler.AddTask = function(self, key, ...)
        if key == 'alerts_tick' then return false end
        return add(self, key, ...)
    end
    assert(F.Commands:TestCountdown() == false and A.currentText == nil)
end)
Test('old alert callback cannot tick a newer alert generation', function()
    local S, F, c, P, io, A = Boot(); assert(F.Commands:TestCountdown())
    local old = S.Scheduler.tasks.alerts_tick.callback
    A:Hide(); assert(A:Push({text = '新提示', durationMs = 3000})); c.now = c.now + 4000
    old(); assert(A.currentText == '新提示', 'retired alert callback affected new alert')
end)
Test('projection reads perform neither native calls nor persistence writes', function()
    local S, F, c, P, io = Boot(); local n, a, w = c.reads, c.auraReads, io.writes
    for i = 1, 20 do F:GetProjection() end
    assert(c.reads == n and c.auraReads == a and io.writes == w)
end)
print(string.format('BOSS ALERTS TESTS: %d passed, %d failed (runtime=%s)', passed, failed, _VERSION))
if failed > 0 then error('boss alerts regressions failed: ' .. failed) end
