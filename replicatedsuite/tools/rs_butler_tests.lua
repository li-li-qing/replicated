-- Restored in Phase 0 from current production contracts; offline fixture only.
local H=dofile('tools/rs_fixture_contract_helpers.lua')
H.Contains('features/life/butler/rs_butler_feature.lua',{'GetProjection','Commands'})
H.Contains('features/life/butler/rs_butler_acceptance.lua',{'v3_butler_read_only_contract'})
H.Pass('butler read-only contract')
