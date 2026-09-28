-- Restored in Phase 0 from current production contracts; offline fixture only.
local H=dofile('tools/rs_fixture_contract_helpers.lua')
H.Contains('features/life/housing/rs_housing_feature.lua',{'GetProjection','Commands'})
H.Contains('features/life/housing/rs_housing_acceptance.lua',{'v3_housing_read_only_contract'})
H.Pass('housing read-only contract')
