-- Restored in Phase 0 from current production contracts; offline fixture only.
local H=dofile('tools/rs_fixture_contract_helpers.lua')
H.Contains('features/combat/raid_readiness/rs_raid_readiness_feature.lua',{'RunScan','AcquireAuraLease','ReleaseAuraLease'})
H.Contains('features/combat/raid_readiness/rs_raid_readiness_acceptance.lua',{'v3_m16_14_raid_readiness_contract'})
H.Pass('raid readiness on-demand contract')
