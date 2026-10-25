-- Replicated Suite · 装备页面回归测试
-- 作者：Replicated
-- QQ群：1104129461
-- 按当前生产契约构造的离线测试数据，不能替代实机证据。
local H=dofile('tools/rs_fixture_contract_helpers.lua')
H.Contains('presentation/v3/pages/rs_v3_gear_page.lua',{'Feature','Commands'})
H.Contains('features/combat/gear/rs_gear_feature.lua',{'Commands'})
H.Pass('gear page public boundary')
