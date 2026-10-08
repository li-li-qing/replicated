-- 开发期回归：真实 Feature / Casting / Aura / Alerts / Scheduler / HUD Presenter。
-- 仅替换 Native API、绘制和存储宿主；假时钟驱动真实 OnUpdate，不修改标签冒充走秒。
-- 不访问玩家 UDF，不进入 toc.g；离线通过不代表 RU 客户端验收。
local passed, failed = 0, 0
local function Test(name, fn)
    local ok, err = xpcall(fn, debug.traceback)
    if ok then passed=passed+1; print('PASS boss-simulation '..name)
    else failed=failed+1; print('FAIL boss-simulation '..name..': '..tostring(err)) end
end
local Host = dofile('tools/rs_gear_page_test_host.lua')
local function Boot()
    local h=Host(); local S=h.S
    h.casts={}; h.unavailable={}; h.castReads=0;h.debuffs={}
    X2Unit.UnitCastingInfo=function(_,scope)
        h.castReads=h.castReads+1
        if h.unavailable[scope] then error('unreadable '..scope) end
        return h.casts[scope]
    end
    X2Unit.UnitDeBuffCount=function()return #h.debuffs end
    X2Unit.UnitDeBuff=function(_,scope,index)return h.debuffs[index]end
    X2Unit.UnitDeBuffTooltip=function(_,scope,index)return h.debuffs[index]end
    UIParent=h.Native(nil,'boss_test_viewport',0,0,1024,768)
    function UIParent:GetScreenWidth()return 1024 end
    function UIParent:GetScreenHeight()return 768 end
    S.UI.TrySetUILayer=function()return true end
    S.PhysicalId=function(id)return 'boss_test_'..id end
    -- 假单调时钟独立于 Scheduler 的积压上限，长帧只执行一次调度。
    S.AdvanceClock=function()end
    S.NativeObjectFactory={CreateEmptyWidget=function()return h.Native(nil,'boss_test_scheduler')end}
    dofile('core/rs_demand.lua')
    dofile('features/shared/rs_feature_slice_factory.lua')
    dofile('data/rs_boss_alerts.lua')
    dofile('services/rs_casting_observation_v3.lua')
    dofile('services/rs_aura_observation_v3.lua')
    dofile('services/rs_alerts_service.lua')
    dofile('presentation/v3/widgets/rs_v3_alert_hud.lua')
    dofile('features/combat/boss_alerts/rs_boss_alerts_feature.lua')
    h.B=S.Features.combat_boss_alerts; h.A=S.Services.Alerts; h.P=S.UIV3.AlertHudV3
    assert(h.A:Start()); assert(h.B:Initialize()); assert(h.B:Enable()); assert(S.Scheduler:Start())
    assert(h.B._bossObservationStarted and h.B.consumerCount>0)
    assert(S.Services.CastingObservationV3:GetCoverage('target').available,'empty native cast must be readable')
    function h:Step(ms)
        self.ms=self.ms+ms
        S.Scheduler.driver.events.OnUpdate(S.Scheduler.driver,ms)
        for name,task in pairs(S.Scheduler.tasks) do assert(task.enabled,name..' task failed: '..tostring(task.lastError)) end
    end
    function h:AssertShown(seconds)
        assert(self.A.currentText~=nil and self.P.visible and self.P.root.shown,'HUD vanished before its deadline')
        if seconds then assert(self.P.label.text:match('  '..seconds..'$'),'unexpected countdown: '..self.P.label.text) end
    end
    function h:AssertHidden()
        assert(self.A.currentText==nil and not self.P.visible and not self.P.root.shown,'expired/cancelled HUD is still visible')
    end
    return h
end

Test('simulation survives empty observation and counts six seconds',function()
    local h=Boot(); local writes=h.writes
    assert(h.B.Commands:SimulateCast()); h:AssertShown(6)
    h:Step(100); h:AssertShown(6)
    h:Step(900); h:AssertShown(5)
    for seconds=4,1,-1 do h:Step(1000); h:AssertShown(seconds) end
    h:Step(1000); h:AssertHidden()
    assert((h.B._bossDiag.delivered or 0)==0 and next(h.B._bossActiveCasts)==nil,'simulation leaked into real facts')
    assert(h.writes==writes,'simulation wrote persistent data')
    assert(h.S.Scheduler:GetTaskState('alerts_tick').registered==false,'expired timer was not released')
end)

Test('long frame preserves the original deadline',function()
    local h=Boot(); assert(h.B.Commands:SimulateCast())
    local deadline=h.A.expiresAt
    h:Step(2500); h:AssertShown(4); assert(h.A.expiresAt==deadline)
    h:Step(3500); h:AssertHidden()
end)

Test('selected cast rule uses the same simulation lifetime',function()
    local h=Boot(); assert(h.B.Commands:TestRule('sea_of_death'))
    h:Step(100); h:AssertShown(6); h:Step(5900); h:AssertHidden()
end)

Test('debuff simulation respects configured big text duration',function()
    local h=Boot(); assert(h.B.Commands:SetHudDurationMs(4000)); assert(h.B.Commands:SimulateDebuff())
    h:Step(3000); h:AssertShown(); h:Step(1000); h:AssertHidden()
    assert((h.B._bossDiag.delivered or 0)==0,'simulated debuff counted as a real hit')
end)

Test('disabling matching rule cancels its simulation',function()
    local h=Boot(); assert(h.B.Commands:SimulateCast('smash_earth'))
    assert(h.B.Commands:SetRuleEnabled('smash_earth',false)); h:AssertHidden()
    assert(h.B.Commands:SimulateCast('smash_earth')==false,'disabled rule can still simulate')
end)

Test('disabling unrelated rule preserves simulation deadline',function()
    local h=Boot(); assert(h.B.Commands:SimulateCast('smash_earth')); local deadline=h.A.expiresAt
    assert(h.B.Commands:SetRuleEnabled('sea_of_death',false)); h:Step(100); h:AssertShown(6)
    assert(h.A.expiresAt==deadline); h:Step(5900); h:AssertHidden()
end)

Test('all rules off cancels simulation and releases observers',function()
    local h=Boot(); assert(h.B.Commands:SimulateCast()); assert(h.B.Commands:SetAllRulesEnabled(false))
    h:AssertHidden(); assert(not h.B._bossObservationStarted)
    assert(h.S.Services.CastingObservationV3.Demand.count==0)
end)

Test('HUD off cancels the test immediately',function()
    local h=Boot(); assert(h.B.Commands:SimulateCast()); assert(h.B.Commands:SetHudEnabled(false)); h:AssertHidden()
    assert(h.B.Commands:SimulateCast()==false)
end)

Test('feature disable releases observers and test timer',function()
    local h=Boot(); assert(h.B.Commands:SimulateCast()); assert(h.B:Disable()); h:AssertHidden()
    for _,name in ipairs({'alerts_tick','v3_business_boss_alert_observe','v3_casting_observation_refresh'}) do
        assert(h.S.Scheduler:GetTaskState(name).registered==false,'leaked '..name)
    end
end)

Test('rule cancellation cannot clear another owner notification',function()
    local h=Boot(); assert(h.A:Push({text='other feature',ownerKey='other',alertKey='smash_earth',durationMs=5000}))
    assert(h.B.Commands:SetRuleEnabled('smash_earth',false)); assert(h.B:Disable()); h:AssertShown()
    assert(h.A.currentOwnerKey=='other'); h:Step(5000); h:AssertHidden()
end)

Test('real cast replaces simulation and ends on real empty observation',function()
    local h=Boot(); assert(h.B.Commands:SimulateCast())
    h.casts.target={spellName='Smash Earth',currCastingTime=1000,castingTime=7000}
    h:Step(100); h:Step(100); h:AssertShown(6)
    assert(h.A.currentAlertKey=='smash_earth' and h.B._bossActiveCasts.smash_earth=='target','real alert was not delivered')
    assert(h.B._bossDiag.delivered==1)
    h.casts.target=nil; h:Step(100); h:Step(100); h:AssertHidden()
end)

Test('incomplete unrelated scope does not freeze real cast cancellation',function()
    local h=Boot(); h.unavailable.watchtarget=true
    h.casts.target={spellName='Smash Earth',currCastingTime=0,castingTime=6000}
    h:Step(100); h:Step(100); h:AssertShown(6)
    h.casts.target=nil; h:Step(100); h:Step(100); h:AssertHidden()
end)

Test('click again starts a fresh six second simulation',function()
    local h=Boot(); assert(h.B.Commands:SimulateCast()); h:Step(1000); h:AssertShown(5)
    assert(h.B.Commands:SimulateCast()); h:AssertShown(6)
    h:Step(5000); h:AssertShown(1); h:Step(1000); h:AssertHidden()
end)

Test('missing timer repair keeps simulation deadline',function()
    local h=Boot(); assert(h.B.Commands:SimulateCast()); local deadline=h.A.expiresAt
    h.S.Scheduler:RemoveTask('alerts_tick'); h:Step(1000); h:AssertShown(5)
    assert(h.A.expiresAt==deadline and h.A.timerRepairs==1)
    h:Step(5000); h:AssertHidden()
end)

Test('existing generic countdown still counts normally',function()
    local h=Boot(); assert(h.B.Commands:TestCountdown()); h:Step(1000); h:AssertShown(5)
    h:Step(5000); h:AssertHidden()
end)

Test('all fifteen cast names match through the native observation path',function()
    local h=Boot();local matched=0
    for _,rule in ipairs(h.S.Data.BossAlerts)do
        if rule.kind=='cast' then
            for _,name in ipairs(rule.names)do
                local before=h.B._bossDiag.delivered
                h.casts.target={spellName=name,currCastingTime=0,castingTime=6000}
                h:Step(100);h:Step(100);h:AssertShown(6)
                assert(h.A.currentAlertKey==rule.key and h.B._bossDiag.delivered==before+1,name..' did not match')
                local deadline=h.A.expiresAt
                h.casts.target.currCastingTime=1000;h:Step(1000);h:AssertShown(5)
                assert(h.B._bossDiag.delivered==before+1 and h.A.expiresAt==deadline,'steady observation reset '..name)
                h.casts.target=nil;h:Step(100);h:Step(100);h:AssertHidden();matched=matched+1
            end
        end
    end
    assert(matched==15)
end)
Test('self debuff IDs alert once and rearm after a verified disappearance',function()
    local h=Boot()
    for _,rule in ipairs(h.S.Data.BossAlerts)do
        if rule.kind=='debuff' then
            local before=h.B._bossDiag.delivered
            h.debuffs={{buff_id=rule.debuffId,name='Native debuff',timeLeft=10000}}
            h:Step(400);h:AssertShown()
            assert(h.A.currentAlertKey==rule.key and h.B._bossDiag.delivered==before+1,'missing ID '..rule.debuffId)
            h:Step(400);assert(h.B._bossDiag.delivered==before+1,'persistent debuff spammed alerts')
            h.debuffs={};h:Step(400)
            h.debuffs={{buff_id=rule.debuffId,name='Native debuff',timeLeft=10000}}
            h:Step(400);assert(h.B._bossDiag.delivered==before+2,'debuff never rearmed')
            h.debuffs={};h:Step(400)
        end
    end
end)
Test('rule settings and HUD layout survive a fresh real store reload',function()
    local h=Boot()
    assert(h.B.Commands:SetRuleEnabled('ghost_hit',false))
    assert(h.B.Commands:SetHudFontSize(31));assert(h.B.Commands:SetHudDurationMs(4500))
    local before=h.Copy(h.B.State)
    for key in pairs(h.B.State)do h.B.State[key]=nil end
    h.B.storeLoaded=false;h.S.Persistence:GetStore(h.B.storeId).loaded=false
    assert(h.B:Initialize());assert(h.B.State.items.ghost_hit==false)
    assert(h.B.State.hudFontSize==before.hudFontSize and h.B.State.hudDurationMs==before.hudDurationMs,'boss layout lost')
end)

print('RESULT boss-simulation passed='..passed..' failed='..failed)
if failed>0 then os.exit(1) end
