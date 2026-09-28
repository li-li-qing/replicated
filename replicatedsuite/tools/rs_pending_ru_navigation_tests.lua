-- Restored in Phase 0 from current production contracts; offline fixture only.
local H=dofile('tools/rs_fixture_contract_helpers.lua')
H.Contains('features/rs_feature_registry.lua',{'implemented_pending_ru'})
H.Contains('tools/rs_navigation_status_acceptance_tests.lua',{'navigation'})
H.Pass('pending-RU navigation state contract')
