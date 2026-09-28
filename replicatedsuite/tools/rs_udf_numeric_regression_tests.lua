-- Restored in Phase 0 from current production contracts; offline fixture only.
local H=dofile('tools/rs_fixture_contract_helpers.lua')
H.Contains('core/rs_persistence.lua',{'schemaVersion'})
H.Contains('tools/rs_native_numeric_transport_tests.lua',{'numeric'})
H.Pass('numeric transport/UDF regression')
