-- Development only: real Persistence and Feature Slice Factory.
-- Models settings edited before feature startup; never writes game UDF files.
local passed,failed=0,0
local function Test(name,fn)
    local ok,err=pcall(fn)
    if ok then passed=passed+1;print('PASS feature-load '..name)
    else failed=failed+1;print('FAIL feature-load '..name..': '..tostring(err)) end
end
local function Boot(team)
    local h=dofile('tools/rs_gear_page_test_host.lua')()
    dofile('core/rs_demand.lua');dofile('features/shared/rs_feature_slice_factory.lua')
    local S=h.S
    local feature
    if team then
        dofile('features/combat/team_tools/rs_team_tools_feature.lua')
        feature=S.Features.combat_team_tools
    else
        feature=S.FeatureSliceFactory.NewFeature('readiness_probe',{
            state={flag=true},default={flag=true},read=function()return {}end,
        })
    end
    return h,S,feature,S.Persistence:GetStore(feature.storeId)
end
Test('team role starts after settings save awaiting barrier, without reloading or clearing obligation',function()
    local h,S,F,store=Boot(true)
    assert(S.Persistence:PrepareRead(F.storeId));assert(not F.storeLoaded)
    assert(F.Commands:SetAutoRoleEnabled(false));assert(S.Persistence:SaveStore(F.storeId,{force=true}))
    assert(store.needsBarrierVerify and not store.dirty)
    local reads,writes=h.reads,h.writes
    local ok,err=F:Initialize();assert(ok,err)
    assert(F.storeLoaded and F.State.autoRoleEnabled==false)
    assert(h.reads==reads and h.writes==writes,'Initialize performed Native IO')
    assert(store.needsBarrierVerify,'Initialize discarded pending durability proof')
end)
Test('feature starts with dirty settings and preserves pending mutation',function()
    local h,S,F,store=Boot()
    assert(S.Persistence:PrepareRead(F.storeId))
    assert(S.FeatureSliceFactory.PersistStateMutation(F,'before_start',function(state)state.flag=false;return true end))
    assert(store.dirty);local reads,writes=h.reads,h.writes
    local ok,err=F:Initialize();assert(ok,err)
    assert(F.State.flag==false and store.dirty and h.reads==reads and h.writes==writes)
end)
Test('cold store still physically loads once before feature initialization succeeds',function()
    local h,S,F=Boot();local reads=h.reads
    local ok,err=F:Initialize();assert(ok,err);assert(h.reads==reads+1)
    assert(F:Initialize());assert(h.reads==reads+1)
end)
Test('corrupt terminal store remains rejected without rereading or clearing it',function()
    local h,S,F,store=Boot();store.loaded=true;store.loadStatus='integrity_failed'
    store.writeFenced=true;store.writeFenceReason='integrity_failed';store.lastError='synthetic integrity failure'
    local reads,writes=h.reads,h.writes
    local ok,err=F:Initialize();assert(not ok and err=='synthetic integrity failure',tostring(err))
    assert(not F.storeLoaded and store.writeFenced and h.reads==reads and h.writes==writes)
end)
Test('explicit disk reload remains blocked while durability proof is pending',function()
    local h,S,F,store=Boot();assert(S.Persistence:PrepareRead(F.storeId))
    assert(S.Persistence:SaveStore(F.storeId,{force=true}));assert(store.needsBarrierVerify)
    local ok,_,err=S.Persistence:LoadStore(F.storeId)
    assert(not ok and err=='unverified store reload rejected',tostring(err))
    assert(store.needsBarrierVerify)
end)
print('FEATURE LOAD READINESS RESULT '..passed..' passed / '..failed..' failed (Lua '.._VERSION..')')
if failed>0 then os.exit(1) end
