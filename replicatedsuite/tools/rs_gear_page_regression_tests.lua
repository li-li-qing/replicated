-- Restored in Phase 0 from current production contracts; offline fixture only.
local H=dofile('tools/rs_fixture_contract_helpers.lua')
H.Contains('presentation/v3/pages/rs_v3_gear_page.lua',{'Feature','Commands'})
H.Contains('features/combat/gear/rs_gear_feature.lua',{'Commands'})
H.Pass('gear page public boundary')
