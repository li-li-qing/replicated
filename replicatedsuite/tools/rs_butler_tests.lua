-- 维护（2026-10-07 发布复核）：用户 2026-10-02 已删除管家助手；验收退休边界，
-- 不重新创建旧 Feature 来满足历史只读测试，也不触碰保留的玩家存档。
local H=dofile('tools/rs_fixture_contract_helpers.lua')
local paths={'features/life/butler/rs_butler_feature.lua','features/life/butler/rs_butler_acceptance.lua','presentation/v3/pages/rs_v3_butler_page.lua'}
H.NotContains('toc.g',paths)
H.NotContains('features/rs_feature_registry.lua',{'Add("life_butler"'})
for _,path in ipairs(paths)do
 local f=io.open(path,'rb');if f then f:close();error('retired butler runtime source remains: '..path)end
end
H.Pass('butler retired from source, TOC and feature directory')
