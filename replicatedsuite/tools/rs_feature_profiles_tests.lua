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
print('FEATURE_PROFILES_RUNTIME_TEST PASS')
