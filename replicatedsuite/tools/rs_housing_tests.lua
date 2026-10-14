------------------------------------------------------------------------
-- Replicated Suite · 住宅测试
-- 作者：Replicated
-- QQ群：1104129461
--
-- 按当前生产契约构造的离线测试数据，不能替代实机证据。
------------------------------------------------------------------------
local H=dofile('tools/rs_fixture_contract_helpers.lua')
H.Contains('features/life/housing/rs_housing_feature.lua',{'GetProjection','Commands'})
H.Contains('features/life/housing/rs_housing_acceptance.lua',{'v3_housing_read_only_contract'})
H.Pass('housing read-only contract')
