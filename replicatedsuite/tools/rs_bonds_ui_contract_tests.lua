-- Restored in Phase 0 from current production contracts; offline fixture only.
local H=dofile('tools/rs_fixture_contract_helpers.lua')
H.Contains('presentation/v3/pages/rs_v3_life_m16_pages.lua',{'life.bonds'})
H.Contains('features/life/bonds/rs_bonds_acceptance.lua',{'bonds'})
H.Pass('bonds UI contract')
