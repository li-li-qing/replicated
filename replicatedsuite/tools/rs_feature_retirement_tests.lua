-- 用户 2026-10-06 删除三个工具功能，2026-10-07 删除快捷键方案；检查目录/路由/旧存档兼容。
local h=dofile('tools/rs_gear_page_test_host.lua')();local S=h.S
dofile('features/rs_feature_registry.lua')
local retired={tools_portal_profiles='tools.portal_profiles',tools_reinforce_analysis='tools.reinforce_analysis',tools_random_shop='tools.random_shop',tools_hotkey_profiles='tools.hotkey_profiles'}
local paths={
 'features/tools/portal_profiles/rs_portal_profiles_feature.lua',
 'features/tools/reinforce_analysis/rs_reinforce_analysis_feature.lua',
 'features/tools/reinforce_analysis/rs_reinforce_analysis_acceptance.lua',
 'features/tools/random_shop/rs_random_shop_authority.lua',
 'features/tools/random_shop/rs_random_shop_feature.lua',
 'features/tools/random_shop/rs_random_shop_acceptance.lua',
 'presentation/v3/pages/rs_v3_random_shop_page.lua',
 'features/tools/rs_hotkey_profiles_feature.lua',
 'tools/rs_hotkey_profiles_tests.lua',
 'tools/fixtures/hotkey_schema2_native_20261006.lua',
}
local file=assert(io.open('toc.g','rb'));local toc=file:read('*a');file:close()
for _,path in ipairs(paths)do
 assert(not toc:find(path,1,true),'retired file remains in TOC '..path)
 local stale=io.open(path,'rb');if stale then stale:close();error('retired source remains '..path)end
end
for id,route in pairs(retired)do
 assert(S.FeatureRegistry:Get(id)==nil,'retired feature remains '..id)
 for _,meta in ipairs(S.FeatureRegistry:List())do assert(meta.route~=route,'retired route remains '..route)end
end
for _,id in ipairs({'life_tasks','combat_buff_cap'})do assert(S.FeatureRegistry:Get(id).navigationDevelopmentState=='complete','completion flag missing '..id)end
dofile('presentation/v3/pages/rs_v3_business_pages.lua')
for _,route in pairs(retired)do assert(S.UIV3.PageHost.factories[route]==nil,'retired page factory remains '..route)end
assert(S.UIV3.PageHost.factories['tools.social'],'remaining tools route lost')
assert(S.FeatureRegistry:Get('tools_feature_profiles'),'functional profiles must remain')
dofile('presentation/v3/navigation/rs_v3_router.lua');dofile('presentation/v3/rs_v3_workspace.lua')
assert(S.UIV3.Workspace:EnsureLoaded())
S.UIV3.Workspace.state.navigation.favorite['tools.hotkey_profiles']=true
for _,mode in ipairs({'all','custom','favorites','enabled'})do
 for _,row in ipairs(S.UIV3.Workspace:GetNavigation(mode))do assert(row.id~='tools.hotkey_profiles','old favorite resurrected retired navigation')end
end
assert(S.UIV3.Router:Get('tools.hotkey_profiles')==nil,'retired Router entry remains')
dofile('presentation/v3/rs_v3_acceptance.lua')
for _,row in ipairs(S.UIV3Acceptance.migratedPresentation)do assert(row.route~='tools.hotkey_profiles','retired route remains mandatory acceptance')end
assert(S.ApiCapabilities:Get('X2Option:GetHotkeyInfo')==nil,'retired metadata probe registration remains')
assert(S.ApiCapabilities:Get('X2Hotkey:GetOptionBinding'),'shared fishing hotkey capability lost')
dofile('features/rs_feature_runtime.lua')
local runtime=S.FeatureRuntime;assert(runtime:EnsurePreferencesLoaded())
-- 真实旧开关记录的读取：删除模块后继续加载其它偏好，不把旧开关误判为全局存档损坏。
for id,route in pairs(retired)do S.FeatureRegistry.features[id]={id=id,route=route}end
local ok,err=S.Persistence:MutateStore(runtime.preferenceStoreId,function()
 runtime.preferences={life_tasks=false,combat_buff_cap=true,tools_portal_profiles=true,tools_reinforce_analysis=true,tools_random_shop=true,tools_hotkey_profiles=true}
 return true
end,{durable=true,reason='test_retired_preferences_fixture'});assert(ok,err)
for id in pairs(retired)do S.FeatureRegistry.features[id]=nil end
S.Persistence:GetStore(runtime.preferenceStoreId).loaded=false;runtime.preferencesLoaded=false
assert(runtime:EnsurePreferencesLoaded());assert(runtime.preferences.life_tasks==false and runtime.preferences.combat_buff_cap==true)
for id in pairs(retired)do assert(runtime.preferences[id]==nil,'retired preference was activated '..id)end
assert(S.Features.tools_hotkey_profiles==nil);assert(S.Persistence:GetStore('v3.business.tools_hotkey_profiles')==nil)
assert(h.clears==0,'retirement must not clear saved data')
print('FEATURE RETIREMENT: PASS (sources, TOC, registry, page factories, completion flags)')
