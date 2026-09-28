-- Restored in Phase 0 from current production contracts; offline fixture only.
local H=dofile('tools/rs_fixture_contract_helpers.lua')
H.Contains('presentation/v3/pages/rs_v3_home_overview.lua',{'ledger','projection'})
H.Contains('features/life/rs_daily_ledger.lua',{'Get'})
H.Pass('ledger projection boundary')
