local ROOT = './'

local function deepcopy(v, seen)
    if type(v) ~= 'table' then return v end
    seen = seen or {}; if seen[v] then return seen[v] end
    local out = {}; seen[v] = out
    for k, x in pairs(v) do out[deepcopy(k, seen)] = deepcopy(x, seen) end
    return out
end
local function eq(a,b,msg) if a ~= b then error((msg or 'assert') .. ': expected='..tostring(b)..' actual='..tostring(a), 2) end end
local function truth(v,msg) if v ~= true then error((msg or 'assert true')..': '..tostring(v), 2) end end

ReplicatedSuite = {
    SafeTraceback = debug.traceback,
    Utils = { DeepCopy = deepcopy },
    DiagnosticsManager = { Emit = function() end },
    Features = {},
}
local S = ReplicatedSuite

local diagnosticProviders = {}
S.ModuleDiagnosticsHub = { RegisterProvider=function(_, _, name, fn) diagnosticProviders[name]=fn;return true end }

-- Minimal internal event bus with the same owner-first callback contract used by the suite.
S.Events = { listeners = {} }
function S.Events:SubscribeInternal(topic, owner, cb)
    self.listeners[topic] = self.listeners[topic] or {}
    table.insert(self.listeners[topic], { owner=owner, cb=cb })
    return true
end
function S.Events:UnsubscribeInternalOwner(owner)
    for topic, rows in pairs(self.listeners) do
        for i=#rows,1,-1 do if rows[i].owner == owner then table.remove(rows,i) end end
    end
    return true
end
function S.Events:Publish(topic, ...)
    local rows = {}; for _, row in ipairs(self.listeners[topic] or {}) do rows[#rows+1]=row end
    for _, row in ipairs(rows) do row.cb(row.owner, ...) end
    return true
end

local metas = {
    { id='tools_feature_profiles', route='tools.feature_profiles', name='功能方案', category='tools', lifecycle='independent', controlFeatureId='tools_feature_profiles', defaultEnabled=true },
    { id='life_trade', route='life.trade', name='跑商', category='life', lifecycle='independent', controlFeatureId='life_trade', defaultEnabled=false },
    { id='life_bonds', route='life.bonds', name='债券', category='life', lifecycle='independent', controlFeatureId='life_bonds', defaultEnabled=false },
    { id='tools_bag_organizer', route='tools.bag_organizer', name='整理背包', category='tools', lifecycle='independent', controlFeatureId='tools_bag_organizer', defaultEnabled=false },
    { id='combat_range_assist', route='combat.range_assist', name='范围辅助', category='combat', lifecycle='independent', controlFeatureId='combat_range_assist', defaultEnabled=false },
    { id='combat_unit_lines', route='combat.unit_lines', name='单位连线', category='combat', lifecycle='independent', controlFeatureId='combat_unit_lines', defaultEnabled=false },
    { id='shell_settings', route='settings', name='设置', category='tools', lifecycle='shell', controlFeatureId='', defaultEnabled=true },
}
local byId = {}; for _,m in ipairs(metas) do byId[m.id]=m end
S.FeatureRegistry = { categories={life={name='生活'},combat={name='战斗'},tools={name='工具'}} }
function S.FeatureRegistry:Get(id) return byId[id] end
function S.FeatureRegistry:List() return metas end

S.Persistence = {
    Scope={Account='account'}, Lifetime={Permanent='permanent'}, V3KeyPrefix='rs.v3.',
    stores={}, disk={}, failNext={}, mutateCount={}, durableCount={},
}
local P=S.Persistence
function P:GetStore(id) return self.stores[id] end
function P:RegisterV3Store(spec)
    if self.stores[spec.id] then return nil,'duplicate' end
    self.stores[spec.id]=spec
    return spec
end
function P:LoadStore(id)
    local spec=self.stores[id]; if not spec then return false,nil,'missing' end
    if self.disk[id] ~= nil then spec.apply(deepcopy(self.disk[id])); return true end
    local d = type(spec.default)=='function' and spec.default() or {}
    spec.apply(deepcopy(d)); self.disk[id]=deepcopy(d); return 'empty'
end
function P:CanWrite(id) return self.stores[id] ~= nil, self.stores[id] and nil or 'missing' end
function P:FingerprintCanonicalValue() return 'not-used' end
function P:MutateStore(id, mutator, opts)
    local spec=self.stores[id]; if not spec then return false,'missing' end
    self.mutateCount[id]=(self.mutateCount[id] or 0)+1
    if opts and opts.durable then self.durableCount[id]=(self.durableCount[id] or 0)+1 end
    local before=deepcopy(spec.get())
    local ok, a, b = pcall(mutator)
    if not ok or a == false then spec.apply(before); return false, ok and b or a end
    if self.failNext[id] then self.failNext[id]=nil; spec.apply(before); return false,'forced_persist_failure' end
    self.disk[id]=deepcopy(spec.get())
    return true,b
end

S.Demand = { leases={} }
function S.Demand:Create(spec)
    local lease={ id=spec.id, owner=spec.owner, spec=spec, count=0, tokens={} }
    function lease:_apply(nextCount, reason)
        local before={count=self.count}; local after={count=nextCount}
        if type(self.spec.reconcile)=='function' then
            local ok,err=self.spec.reconcile(self,before,after,reason); if ok==false then return false,err end
        end
        self.count=nextCount
        if type(self.spec.projectionOwner)=='table' then
            local po=self.spec.projectionOwner
            po[self.spec.projectionCountField or 'consumerCount']=nextCount
        end
        return true
    end
    function lease:Acquire(token)
        if self.tokens[token] then return true end
        local ok,err=self:_apply(self.count+1,'acquire'); if ok~=true then return false,err end
        self.tokens[token]=true; return true
    end
    function lease:Release(token)
        if not self.tokens[token] then return true end
        local ok,err=self:_apply(math.max(0,self.count-1),'release'); if ok~=true then return false,err end
        self.tokens[token]=nil; return true
    end
    function lease:Clear(reason)
        local ok,err=self:_apply(0,reason or 'clear'); if ok~=true then return false,err end
        self.tokens={}; return true
    end
    self.leases[spec.id]=lease
    return lease
end
function S.Demand:Get(id) return self.leases[id] end

dofile(ROOT..'features/rs_feature_runtime.lua')
local Runtime=S.FeatureRuntime

dofile(ROOT..'features/tools/rs_feature_profiles_feature.lua')
local Profiles=S.Features.FeatureProfiles

local fake={}
local function RegisterFake(id)
    local impl={enabled=false, failEnable=false, failDisable=false}
    function impl:Initialize() return true end
    function impl:Enable() if self.failEnable then return false,'forced enable failure' end; self.enabled=true; return true end
    function impl:Disable() if self.failDisable then return false,'forced disable failure' end; self.enabled=false; return true end
    truth(Runtime:RegisterImplementation(id,impl), 'register '..id)
    fake[id]=impl
end
for _,id in ipairs({'life_trade','life_bonds','tools_bag_organizer','combat_range_assist','combat_unit_lines'}) do RegisterFake(id) end

truth(Runtime:Enable('tools_feature_profiles','test_start'),'enable feature profiles')
eq(#Profiles:GetProjection().rows,0,'no hardcoded default profiles')

local ok, livingId=Profiles.Commands:CreateProfile('生活'); truth(ok,'create living profile')
truth(Profiles.Commands:SetModule(livingId,'life_trade',true),'select trade')
truth(Profiles.Commands:SetModule(livingId,'life_bonds',true),'select bonds')
truth(Profiles.Commands:SetModule(livingId,'tools_bag_organizer',true),'select bag')
local beforeFeatureStoreMutates=P.mutateCount['v3.features'] or 0
local applied, detail=Profiles.Commands:ApplyProfile(livingId); truth(applied,'apply living')
eq(P.mutateCount['v3.features'], beforeFeatureStoreMutates+1, 'profile apply writes feature preferences once')
truth(Runtime:IsEnabled('life_trade'),'trade on')
truth(Runtime:IsEnabled('life_bonds'),'bonds on')
truth(Runtime:IsEnabled('tools_bag_organizer'),'bag on')
eq(Runtime:IsEnabled('combat_range_assist'),false,'range off')
eq(Runtime:IsEnabled('combat_unit_lines'),false,'unit lines off')
truth(Runtime:IsEnabled('tools_feature_profiles'),'profile feature must not disable itself')
eq(Profiles:GetProjection().dirty,false,'freshly applied profile clean')

-- Manual user toggle must only mark the last-applied profile dirty; it must not rewrite the profile.
truth(Runtime:SetPreferredEnabled('combat_range_assist',true,'manual_test'),'manual range enable')
local projection=Profiles:GetProjection(); truth(projection.dirty,'manual module toggle marks profile dirty')
local row=nil; for _,m in ipairs(projection.moduleRows) do if m.featureId=='combat_range_assist' then row=m end end
truth(row ~= nil,'range row present'); eq(row.targetEnabled,false,'saved profile not silently overwritten'); eq(row.runtimeEnabled,true,'runtime reflects manual toggle')

-- Capture is the explicit overwrite path.
truth(Profiles.Commands:CaptureCurrent(livingId),'capture current')
projection=Profiles:GetProjection(); eq(projection.dirty,false,'capture makes profile match current')

-- A second profile proves full-state semantics: unselected controllable modules are targets=false.
local ok2, battleId=Profiles.Commands:CreateProfile('战斗'); truth(ok2,'create battle')
truth(Profiles.Commands:SetModule(battleId,'combat_unit_lines',true),'select unit lines')

local function snapshotStates()
    local out={}
    for _,id in ipairs({'life_trade','life_bonds','tools_bag_organizer','combat_range_assist','combat_unit_lines','tools_feature_profiles'}) do out[id]=Runtime:IsEnabled(id) end
    return out
end
local function assertStates(expected,label)
    for id,v in pairs(expected) do eq(Runtime:IsEnabled(id),v,(label or 'state')..' '..id) end
end

-- Lifecycle failure must roll back already-transitioned modules.
local before=snapshotStates()
fake.life_trade.failDisable=true
local failOk=Profiles.Commands:ApplyProfile(battleId)
eq(failOk,false,'lifecycle failure propagates')
fake.life_trade.failDisable=false
assertStates(before,'lifecycle rollback')

-- Durable v3.features persistence failure must also restore all lifecycle transitions.
before=snapshotStates(); local prefsBefore=deepcopy(Runtime.preferences)
P.failNext['v3.features']=true
local persistOk=Profiles.Commands:ApplyProfile(battleId)
eq(persistOk,false,'persistence failure propagates')
assertStates(before,'persistence rollback')
for id,v in pairs(prefsBefore) do eq(Runtime.preferences[id],v,'preference rollback '..id) end
for id,v in pairs(Runtime.preferences) do eq(v,prefsBefore[id],'preference rollback no new key '..id) end

-- Successful battle profile now closes everything else and only leaves unit-lines among controllable rows.
truth(Profiles.Commands:ApplyProfile(battleId),'apply battle after rollback tests')
eq(Runtime:IsEnabled('life_trade'),false,'battle closes trade')
eq(Runtime:IsEnabled('life_bonds'),false,'battle closes bonds')
eq(Runtime:IsEnabled('tools_bag_organizer'),false,'battle closes bag')
eq(Runtime:IsEnabled('combat_range_assist'),false,'battle closes range because not selected')
truth(Runtime:IsEnabled('combat_unit_lines'),'battle opens unit lines')
truth(Runtime:IsEnabled('tools_feature_profiles'),'profile feature remains enabled after battle')

eq(#Profiles:GetQuickRows(),2,'both user-created profiles default to quick buttons')
-- 维护（2026-09-30，feature-profile-failure-evidence-1）：原子事务遇到坏业务 Store 时，
-- 应准确报告失败目标/阶段/回滚结果，不自动删掉方案所选项，也不把未完成回滚写成成功。
local failures, addedPassed = 0, 0
local function Case(name, fn)
    local success, err = pcall(fn)
    if success then addedPassed=addedPassed+1; print('PASS profile-failure '..name)
    else failures=failures+1; print('FAIL profile-failure '..name..': '..tostring(err)) end
end
local deathMeta={id='combat_death_review',route='combat.death_review',name='死亡回顾',category='combat',
    lifecycle='independent',controlFeatureId='combat_death_review',defaultEnabled=false}
metas[#metas+1]=deathMeta;byId[deathMeta.id]=deathMeta
local death={enabled=false,initializations=0}
function death:Initialize() self.initializations=self.initializations+1;return false,'integrity_failed:fingerprint_mismatch:SYNTHETIC' end
function death:Enable() error('fenced Store must not enable') end
function death:Disable() self.enabled=false;return true end
truth(Runtime:RegisterImplementation(deathMeta.id,death))
truth(Profiles.Commands:SetModule(livingId,deathMeta.id,true))
Case('failed target is structured and saved profile choices stay intact',function()
    local states=snapshotStates();local preferences=deepcopy(Runtime.preferences)
    local ok, message=Profiles.Commands:ApplyProfile(livingId);eq(ok,false)
    assertStates(states,'failed Store rollback')
    for id,v in pairs(preferences) do eq(Runtime.preferences[id],v,'unchanged preference') end
    local failure=Profiles:GetProjection().lastApplyFailure
    truth(type(failure)=='table','missing structured failure')
    eq(failure.featureId,deathMeta.id);eq(failure.featureName,'死亡回顾')
    eq(failure.route,'combat.death_review');eq(failure.targetEnabled,true)
    eq(failure.stage,'lifecycle');eq(failure.rollbackSucceeded,true)
    truth(failure.error:find('integrity_failed',1,true)~=nil)
    truth(message:find('死亡回顾',1,true)~=nil,'user error must name the actual module')
    eq(Profiles:GetProjection().applyStatus,'failed')
    local stored=P.disk[Profiles.storeId];local found
    for _,pr in ipairs(stored.profiles) do if pr.id==livingId then found=pr.modules[deathMeta.id] end end
    eq(found,true,'must not auto-remove failed module from saved profile')
    failure.featureId='changed by caller'
    eq(Profiles:GetProjection().lastApplyFailure.featureId,deathMeta.id,'projection must be detached')
end)
Case('failure diagnostic is detached and does not load or initialize the target',function()
    local oldLoad,oldInit=P.LoadStore,Runtime.Initialize
    P.LoadStore=function()error('diagnostic must not load stores')end
    Runtime.Initialize=function()error('diagnostic must not initialize features')end
    local ok,report=pcall(diagnosticProviders.feature_profile_state)
    P.LoadStore,Runtime.Initialize=oldLoad,oldInit
    truth(ok,tostring(report));eq(report.lastApplyFailure.featureId,deathMeta.id)
    eq(report.applyStatus,'failed');eq(Profiles:GetHealth().applyStatus,'failed')
    report.lastApplyFailure.featureId='caller mutation'
    eq(Profiles:GetProjection().lastApplyFailure.featureId,deathMeta.id)
end)
Case('explicitly excluding the failed feature permits other requested features',function()
    truth(Profiles.Commands:SetModule(livingId,deathMeta.id,false))
    local attempts=death.initializations
    truth(Profiles.Commands:ApplyProfile(livingId),'unselected fenced feature must not block')
    eq(death.initializations,attempts,'must not initialize disabled target')
    eq(Runtime:IsEnabled(deathMeta.id),false)
    truth(Runtime:IsEnabled('life_trade'));truth(Runtime:IsEnabled('life_bonds'))
    eq(Profiles:GetProjection().lastApplyFailure,nil);eq(Profiles:GetProjection().applyStatus,'applied')
end)
Case('preference persistence failure identifies phase without inventing a feature',function()
    local states=snapshotStates();P.failNext['v3.features']=true
    eq(Profiles.Commands:ApplyProfile(battleId),false);assertStates(states,'save failure rollback')
    local failure=Profiles:GetProjection().lastApplyFailure
    truth(type(failure)=='table');eq(failure.stage,'persist');eq(failure.featureId,nil)
    eq(failure.rollbackSucceeded,true)
    truth(Profiles.Commands:ApplyProfile(battleId),'retry remains available')
end)
Case('runtime distinguishes preflight and preserves false disable targets',function()
    local writes=P.mutateCount['v3.features'] or 0
    local ok,err,detail=Runtime:ApplyPreferenceTargets({life_trade='invalid'})
    eq(ok,false);truth(err:find('boolean',1,true)~=nil);eq(detail.stage,'preflight')
    eq(P.mutateCount['v3.features'] or 0,writes,'preflight must not persist')
    local wasEnabled=Runtime:IsEnabled('life_trade');truth(Runtime:Enable('life_trade'))
    fake.life_trade.failDisable=true
    ok,err,detail=Runtime:ApplyPreferenceTargets({life_trade=false})
    fake.life_trade.failDisable=false
    if not wasEnabled then truth(Runtime:Disable('life_trade')) end
    eq(ok,false);truth(err:find('life_trade:',1,true)~=nil,'legacy second return changed')
    eq(detail.stage,'lifecycle');eq(detail.targetEnabled,false,'false must not become nil')
    eq(detail.rollbackAttempted,false);eq(detail.rollbackSucceeded,true)
end)
Case('incomplete rollback is reported as incomplete rather than success',function()
    local m={id='aaa_probe',route='tools.probe',name='回滚样本',category='tools',lifecycle='independent',controlFeatureId='aaa_probe'}
    metas[#metas+1]=m;byId[m.id]=m;RegisterFake(m.id)
    truth(Runtime:Enable(m.id));fake[m.id].failEnable=true
    truth(Profiles.Commands:SetModule(livingId,deathMeta.id,true))
    local ok,message=Profiles.Commands:ApplyProfile(livingId);eq(ok,false)
    local failure=Profiles:GetProjection().lastApplyFailure
    truth(type(failure)=='table');eq(failure.rollbackSucceeded,false)
    truth(failure.rollbackError:find('aaa_probe',1,true)~=nil)
    truth(message:find('回滚未完成',1,true)~=nil,'message falsely claims rollback success')
    fake[m.id].failEnable=false
end)
print('FEATURE_PROFILES_FAILURE_TESTS: '..addedPassed..' passed / '..failures..' failed')
assert(failures==0,'feature profile failure regressions')
print('FEATURE_PROFILES_RUNTIME_TEST PASS')

-- 中文维护（2026-10-02）：使用真实 Router/Workspace 验证名单、标签、个人排序/隐藏，
-- 并检查旧团队开启位的兼容解释与独立关闭的持久表达；不按实现代码硬造期望名单。
do
    local function Add(meta)
        metas[#metas+1]=meta;byId[meta.id]=meta
        if meta.lifecycle~='shell' then RegisterFake(meta.id) end
    end
    Add({id='combat_team_tools',route='combat.team_tools',name='职责设置',category='combat',lifecycle='independent',controlFeatureId='combat_team_tools'})
    Add({id='combat_sac_highlight',route='combat.sac_highlight',name='牺牲之舞',category='combat',lifecycle='independent',controlFeatureId='combat_sac_highlight'})
    Add({id='life_butler',route='life.butler',name='管家助手',category='life',lifecycle='independent',navigationVisible=false})
    Add({id='home',route='home',name='今日总览',category='home',lifecycle='shell',controlFeatureId=''})
    function S.FeatureRegistry:GetByRoute(route)
        for _,meta in ipairs(metas)do if meta.route==route then return meta end end
    end
    dofile('presentation/v3/navigation/rs_v3_router.lua')
    dofile('presentation/v3/rs_v3_workspace.lua')
    local W=S.UIV3.Workspace;truth(W:EnsureLoaded())
    truth(W:SetNavigation('combat.sac_highlight','favorite',true))
    truth(W:SetNavigation('combat.unit_lines','hidden',true))
    local expected=W:GetNavigation('custom');local actual=Profiles:GetNavigationFeatureRows()
    eq(#actual,#expected,'same visible directory')
    for i,row in ipairs(expected)do
        eq(actual[i].id,row.featureId,'same order');eq(actual[i].name,row.navigationTitle,'same label')
    end
    local ok,id=Profiles.Commands:CreateProfile('拆分回归');truth(ok)
    local profile;for _,p in ipairs(Profiles.State.profiles)do if p.id==id then profile=p end end
    profile.modules={combat_team_tools=true} -- 原存档 canonical；加载时不增加链接字段。
    Profiles.Authority:Refresh('legacy_split')
    local projections=Profiles:GetProjection().moduleRows;local sac,own
    for _,row in ipairs(projections)do
        if row.featureId=='combat_sac_highlight'then sac=row end
        if row.featureId=='tools_feature_profiles'then own=row end
        assert(row.featureId~='life_butler' and row.featureId~='combat_unit_lines')
    end
    truth(sac.targetEnabled,'legacy combined intent');eq(profile.modules.team_feature_split_linked,nil,'read cannot alter canonical')
    eq(own.controllable,false,'own page stays read-only')
    truth(Profiles.Commands:SetModule(id,'combat_sac_highlight',false))
    eq(profile.modules.combat_team_tools,true);eq(profile.modules.combat_sac_highlight,nil)
    truth(profile.modules.team_feature_split_linked)
    local capture;local apply=Runtime.ApplyPreferenceTargets
    Runtime.ApplyPreferenceTargets=function(_,targets)capture=targets;return true end
    truth(Profiles.Commands:ApplyProfile(id));Runtime.ApplyPreferenceTargets=apply
    eq(capture.combat_team_tools,true);eq(capture.combat_sac_highlight,false)
    eq(capture.life_butler,nil);eq(capture.combat_unit_lines,nil);eq(capture.tools_feature_profiles,nil)
    eq(Profiles.Commands:SetModule(id,'life_butler',true),false)
    print('FEATURE_PROFILE_NAVIGATION_AND_SPLIT_COMPATIBILITY PASS')
end
