-- Current Registry + Router + Workspace + Feature + real Persistence.
-- Runtime enabled facts are controlled; no game hotkey APIs are called by functional presets.
local h=dofile('tools/rs_gear_page_test_host.lua')();local S=h.S
local enabled={life_tasks=true,combat_buff_cap=true,combat_stats=true}
local targets
function S.FeatureRuntime:IsImplemented()return true end
function S.FeatureRuntime:IsEnabled(id)return enabled[id]==true end
function S.FeatureRuntime:GetPreferredEnabled(id)return enabled[id]==true end
function S.FeatureRuntime:ApplyPreferenceTargets(value)targets=h.Copy(value);return true end
dofile('features/rs_feature_registry.lua');dofile('presentation/v3/navigation/rs_v3_router.lua')
dofile('presentation/v3/rs_v3_workspace.lua');assert(S.UIV3.Workspace:EnsureLoaded())
dofile('core/rs_demand.lua');dofile('features/tools/rs_feature_profiles_feature.lua')
local F=S.Features.tools_feature_profiles;assert(F:Initialize());assert(F:Enable())
local function Row(id)
 for _,row in ipairs(F:GetProjection().moduleRows)do if row.featureId==id then return row end end
end
assert(Row('life_tasks').name=='任务追踪');assert(Row('combat_buff_cap').name=='增益容量监控')
assert(Row('combat_boss_alerts').name=='首领机制 / 战斗警报','completed boss feature still has unfinished suffix in functional profiles')
for _,id in ipairs({'tools_portal_profiles','tools_reinforce_analysis','tools_random_shop','tools_hotkey_profiles','combat_analytics'})do
 assert(Row(id)==nil,'retired/internal feature in visible directory: '..id)
end
local ok,id=F.Commands:CreateProfile('目录同步');assert(ok,id)
assert(F:Persist('test_retired_feature_profile_fixture',function(state)
 state.profiles[1].modules={tools_portal_profiles=true,tools_random_shop=true,tools_hotkey_profiles=true,combat_analytics=true}
 return true
end))
local legacyStore=S.Persistence:GetStore(F.storeId);legacyStore.loaded=false;F.storeLoaded=false
assert(F:EnsureStoreLoaded());assert(legacyStore.writeFenced~=true,'retired module invalidated stamped functional profile')
assert(F.State.profiles[1].modules.tools_hotkey_profiles==true,'canonical old module record changed before integrity verification')
assert(F.Commands:ApplyProfile(id));assert(targets.tools_hotkey_profiles==nil,'old functional profile attempted retired hotkey module')
local captured,message=F.Commands:CaptureCurrent(id);assert(captured,message)
local p=F.State.profiles[1]
for id in pairs(enabled)do assert(p.modules[id]==true,'enabled current feature omitted: '..id)end
for _,id in ipairs({'tools_portal_profiles','tools_random_shop','tools_hotkey_profiles','combat_analytics'})do assert(p.modules[id]==nil,'old feature resurrected: '..id)end
assert(tostring(message):find('最新功能目录',1,true),'capture receipt must describe synchronized scope')
assert(F.Commands:ApplyProfile(id));assert(targets.tools_hotkey_profiles==nil and targets.combat_stats==true)
assert(targets.tools_portal_profiles==nil and targets.combat_analytics==nil)
assert(F:Disable('test_offline_directory_read'))
assert(S.UIV3.Workspace:SetNavigation('combat.stats','hidden',true))
assert(Row('combat_stats')==nil,'disabled functional preset returned stale navigation rows')
assert(F.Commands:CaptureCurrent(id));assert(F.State.profiles[1].modules.combat_stats==nil)
local store=S.Persistence:GetStore(F.storeId);store.loaded=false;F.storeLoaded=false
assert(F:EnsureStoreLoaded());assert(F.State.profiles[1].modules.life_tasks==true)
assert(h.clears==0)
print('FEATURE PROFILE CATALOG SYNC: PASS (current names, completion, retirements, merged statistics, capture/apply, live navigation, real reload)')
