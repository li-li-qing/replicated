-- Restored in Phase 0 from current production contracts; offline fixture only.
local H=dofile('tools/rs_fixture_contract_helpers.lua')
H.Contains('features/life/rs_daily_ledger.lua',{'DailyLedger','Get'})
H.Pass('daily ledger authority')
