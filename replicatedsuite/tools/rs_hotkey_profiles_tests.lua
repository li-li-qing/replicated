------------------------------------------------------------------------
-- Replicated Suite - Hotkey Profiles v2 offline contract tests
-- Synthetic X2Hotkey only. Proves bounded whitelist/migration/transaction
-- semantics; it is NOT an RU-client acceptance claim for team_target/marker.
------------------------------------------------------------------------
local function DeepCopy(v)
    if type(v) ~= "table" then return v end
    local out = {}; for k,x in pairs(v) do out[DeepCopy(k)] = DeepCopy(x) end; return out
end
local function Eq(a,b,msg) assert(a==b,(msg or "mismatch").." expected="..tostring(b).." actual="..tostring(a)) end
local function Contains(text,part,msg) assert(tostring(text or ""):find(part,1,true)~=nil,(msg or "missing text")..": "..tostring(text)) end
local tests, passed = {}, 0
local function Test(name,fn) tests[#tests+1]={name=name,fn=fn} end

local native = {
    mode_action_bar_button = {}, team_target = {}, over_head_marker = {},
}
for i=1,12 do native.mode_action_bar_button[i] = tostring(i) end
for i=1,4 do native.team_target[i] = "F"..tostring(i+1) end
for i=1,3 do native.over_head_marker[i] = "F"..tostring(i+5) end
local valid = { mode_action_bar_button=true, team_target=true, over_head_marker=true }
local overridable = { mode_action_bar_button=true, team_target=true, over_head_marker=true }
local inCombat, owner = false, "Alpha@RU"
local saveCount, writeCount, removeCount = 0, 0, 0
local failOnce = nil

X2Hotkey = {}
function X2Hotkey:GetOptionBinding(action,index,option,arg)
    local group=native[action]; if group==nil then return nil end
    return group[tonumber(arg)]
end
function X2Hotkey:IsValidActionName(action) return valid[action] == true end
function X2Hotkey:IsOverridableAction(action) return overridable[action] == true end
function X2Hotkey:BindingToOption() return true end
function X2Hotkey:SetOptionBindingWithIndex(action,key,index,arg)
    writeCount=writeCount+1
    if failOnce and failOnce.action==action and failOnce.arg==tonumber(arg) and failOnce.key==tostring(key) then
        failOnce=nil; error("synthetic write failure")
    end
    assert(native[action]~=nil,"unknown action write")
    native[action][tonumber(arg)] = tostring(key)
    return true
end
function X2Hotkey:RemoveOptionBinding(action,index,arg)
    removeCount=removeCount+1; assert(native[action]~=nil,"unknown action remove")
    native[action][tonumber(arg)] = nil; return true
end
function X2Hotkey:SaveHotKey() saveCount=saveCount+1; return true end
X2Player = { PlayerInCombat=function() return inCombat end }
X2Unit = { UnitNameWithWorld=function(_,unit) assert(unit=="player"); return owner end }

ReplicatedSuite = {
    BootError=nil, Features={}, Services={}, Utils={DeepCopy=DeepCopy},
    Api={}, Events={Publish=function() return true end},
}
local S=ReplicatedSuite
function S.Api:IsCapabilityAllowed(name) return true end
function S.Api:CallCapability(name,obj,method,...)
    if obj==nil or type(obj[method])~="function" then return false,nil,"missing "..tostring(method) end
    local ok,a=pcall(obj[method],obj,...); if not ok then return false,nil,a end
    return true,a,nil
end
function S.Api:ActionCapability(name,obj,method,...)
    local ok,value,err=self:CallCapability(name,obj,method,...)
    if ok~=true then return false,err end
    if value==false then return false,method.." returned false" end
    return true,value
end

local stores={}
S.Persistence={ Scope={Account="account"}, Lifetime={Permanent="permanent"}, V3KeyPrefix="rs.v3." }
function S.Persistence:GetStore(id) return stores[id] end
function S.Persistence:RegisterV3Store(def) stores[def.id]=def; return def end
function S.Persistence:LoadStore(id)
    local st=assert(stores[id]); st.apply(st.default()); return "empty",nil,nil
end
function S.Persistence:MutateStore(id,mutator,opts)
    local st=assert(stores[id]); local before=DeepCopy(st.get())
    local ok,a,b=pcall(mutator)
    if not ok or a==false then st.apply(before); return false,ok and b or a end
    return true,a,b
end
S.FeatureRuntime={ implementations={} }
function S.FeatureRuntime:RegisterImplementation(id,impl) self.implementations[id]=impl; return true end
S.Demand={}
function S.Demand:Create(spec)
    local lease={ tokens={}, spec=spec }
    function lease:Acquire(token)
        local before={count=self:Count()}; self.tokens[token]=true; local after={count=self:Count()}
        if self.spec.reconcile then return self.spec.reconcile(self,before,after) end
        return true
    end
    function lease:Release(token)
        local before={count=self:Count()}; self.tokens[token]=nil; local after={count=self:Count()}
        if self.spec.reconcile then return self.spec.reconcile(self,before,after) end
        return true
    end
    function lease:Clear()
        local before={count=self:Count()}; self.tokens={}; local after={count=0}
        if self.spec.reconcile then return self.spec.reconcile(self,before,after) end
        return true
    end
    function lease:Has(token) return self.tokens[token]==true end
    function lease:Count() local n=0; for _ in pairs(self.tokens) do n=n+1 end; return n end
    return lease
end

dofile("features/tools/rs_hotkey_profiles_feature.lua")
local F=assert(S.Features.tools_hotkey_profiles)
local store=assert(stores[F.storeId])

Test("schema2 migrates v1 slots without inventing extension groups",function()
    Eq(store.schemaVersion,2); Eq(store.legacySchemaVersion,1)
    local migrated=store.migrate({
        profiles={{id=3,name="旧方案",slots={[1]="Q",[2]=false,[12]="R"}}}, nextId=4, selectedId=3,
        pendingRecovery={owner="Alpha@RU",profileId=3,slots={[1]="1",[2]=false}},
    },1)
    Eq(migrated.profiles[1].groups.main.slots[1],"Q")
    Eq(migrated.profiles[1].groups.main.slots[2],false)
    Eq(migrated.profiles[1].groups.teamTarget,nil,"v1 must not grow team group")
    Eq(migrated.profiles[1].groups.overHeadMarker,nil,"v1 must not grow marker group")
    Eq(migrated.pendingRecovery.groups.main.slots[1],"1")
end)

Test("initialize and save capture all runtime-validated groups",function()
    local ok,err=F:Initialize(); assert(ok,err); F:Enable()
    local beforeWrites=writeCount
    local saved,msg=F.Commands:SaveProfile("完整方案")
    assert(saved,msg); Eq(writeCount,beforeWrites,"save must be read-only")
    Contains(msg,"主动作栏 12/12"); Contains(msg,"队伍目标 4/4"); Contains(msg,"头顶标记 3/3")
    local p=F.State.profiles[1]
    assert(p.groups.main and p.groups.teamTarget and p.groups.overHeadMarker,"all safe groups missing")
end)

Test("invalid extension action is skipped instead of saved as empty",function()
    valid.over_head_marker=false
    local ok,msg=F.Commands:SaveProfile("无头标方案")
    assert(ok,msg); Contains(msg,"未纳入：头顶标记")
    local p=F.State.profiles[2]
    assert(p.groups.main and p.groups.teamTarget,"expected groups missing")
    Eq(p.groups.overHeadMarker,nil,"invalid action must be omitted")
    valid.over_head_marker=true
end)

Test("apply changes only stored groups and clears durable recovery",function()
    native.mode_action_bar_button[1]="ALT-1"; native.team_target[1]="ALT-F2"; native.over_head_marker[1]="ALT-F6"
    owner="Beta@RU"
    local beforeSave=saveCount
    local ok,msg=F.Commands:ApplyProfile(F.State.profiles[1].id)
    assert(ok,msg); Contains(msg,"读回校验")
    Eq(native.mode_action_bar_button[1],"1")
    Eq(native.team_target[1],"F2")
    Eq(native.over_head_marker[1],"F6")
    Eq(saveCount,beforeSave+1,"one SaveHotKey expected")
    Eq(F.State.pendingRecovery,nil,"recovery must clear after commit")
end)

Test("write failure rolls back every touched group",function()
    local oldMain,oldTeam,oldMark="OLD-MAIN","OLD-TEAM","OLD-MARK"
    native.mode_action_bar_button[1]=oldMain; native.team_target[1]=oldTeam; native.over_head_marker[1]=oldMark
    failOnce={action="team_target",arg=2,key="F3"}
    local ok,err=F.Commands:ApplyProfile(F.State.profiles[1].id)
    Eq(ok,false); Contains(err,"已恢复应用前键位")
    Eq(native.mode_action_bar_button[1],oldMain)
    Eq(native.team_target[1],oldTeam)
    Eq(native.over_head_marker[1],oldMark)
    Eq(F.State.pendingRecovery,nil,"successful rollback must clear recovery")
end)

Test("runtime preflight fails before writes when stored extension becomes unsafe",function()
    valid.team_target=false
    local before=writeCount+removeCount
    local ok,err=F.Commands:ApplyProfile(F.State.profiles[1].id)
    Eq(ok,false); Contains(err,"队伍目标预检失败")
    Eq(writeCount+removeCount,before,"preflight failure must not write")
    valid.team_target=true
end)

Test("v1-style migrated profile applies main only",function()
    local migrated=store.migrate({profiles={{id=50,name="旧主栏",slots={[1]="LEGACY-Q",[2]="LEGACY-W"}}},nextId=51},1)
    store.apply(migrated)
    native.mode_action_bar_button[1]="NOW-MAIN"; native.team_target[1]="KEEP-TEAM"; native.over_head_marker[1]="KEEP-MARK"
    local ok,err=F.Commands:ApplyProfile(50); assert(ok,err)
    Eq(native.mode_action_bar_button[1],"LEGACY-Q")
    Eq(native.team_target[1],"KEEP-TEAM","legacy apply must not touch new group")
    Eq(native.over_head_marker[1],"KEEP-MARK","legacy apply must not touch new group")
end)

Test("combat blocks writes but not read-only save; fishing transaction blocks save",function()
    inCombat=true
    local before=writeCount+removeCount
    local ok,err=F.Commands:ApplyProfile(50); Eq(ok,false); Contains(err,"战斗中")
    Eq(writeCount+removeCount,before)
    ok,err=F.Commands:SaveProfile("战斗只读保存"); assert(ok,err) -- 中文维护：RU 只限制 Hotkey 写函数，GetOptionBinding 仍是安全只读。
    inCombat=false
    S.Services.FishingHotkeyV3={sessionSnapshot={}}
    ok,err=F.Commands:SaveProfile("冲突"); Eq(ok,false); Contains(err,"Auto-R")
    S.Services.FishingHotkeyV3=nil
end)

Test("pending recovery is character-bound",function()
    store.apply(store.migrate({profiles={{id=60,name="P",slots={[1]="A"}}},nextId=61,
        pendingRecovery={owner="Alpha@RU",slots={[1]="RESTORE"}}},1))
    owner="Beta@RU"
    local ok,err=F.Commands:RecoverPending(); Eq(ok,false); Contains(err,"其他角色")
    owner="Alpha@RU"
    ok,err=F.Commands:RecoverPending(); assert(ok,err); Eq(native.mode_action_bar_button[1],"RESTORE")
end)

for _,t in ipairs(tests) do
    local ok,err=pcall(t.fn)
    if not ok then io.stderr:write("FAIL ",t.name,": ",tostring(err),"\n"); os.exit(1) end
    passed=passed+1; io.write("PASS ",t.name,"\n")
end
io.write("hotkey profiles tests: ",tostring(passed),"/",tostring(#tests)," passed\n")
