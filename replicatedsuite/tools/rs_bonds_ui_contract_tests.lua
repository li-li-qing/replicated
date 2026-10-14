------------------------------------------------------------------------
-- Replicated Suite · 债券界面契约测试
-- 作者：Replicated
-- QQ群：1104129461
--
-- 按当前生产契约构造的离线测试数据，不能替代实机证据。
------------------------------------------------------------------------
local H=dofile('tools/rs_fixture_contract_helpers.lua')
H.Contains('presentation/v3/pages/rs_v3_life_m16_pages.lua',{'life.bonds'})
H.Contains('features/life/bonds/rs_bonds_acceptance.lua',{'bonds'})
H.Pass('bonds UI contract')
