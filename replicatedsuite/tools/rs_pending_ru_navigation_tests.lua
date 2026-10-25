-- Replicated Suite · 待验证RU导航测试
-- 作者：Replicated
-- QQ群：1104129461
-- 按当前生产契约构造的离线测试数据，不能替代实机证据。
local H=dofile('tools/rs_fixture_contract_helpers.lua')
H.Contains('features/rs_feature_registry.lua',{'implemented_pending_ru'})
H.Contains('tools/rs_navigation_status_acceptance_tests.lua',{'navigation'})
H.Pass('pending-RU navigation state contract')
