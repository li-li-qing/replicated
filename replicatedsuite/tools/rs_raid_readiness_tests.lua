------------------------------------------------------------------------
-- Replicated Suite · 团队就绪测试
-- 作者：Replicated
-- QQ群：1104129461
--
-- 按当前生产契约构造的离线测试数据，不能替代实机证据。
------------------------------------------------------------------------
local H=dofile('tools/rs_fixture_contract_helpers.lua')
H.Contains('features/combat/raid_readiness/rs_raid_readiness_feature.lua',{'RunScan','AcquireAuraLease','ReleaseAuraLease'})
H.Contains('features/combat/raid_readiness/rs_raid_readiness_acceptance.lua',{'v3_m16_14_raid_readiness_contract'})
H.Pass('raid readiness on-demand contract')
