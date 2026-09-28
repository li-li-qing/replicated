-- Restored in Phase 0 from current production contracts; offline fixture only.
local H=dofile('tools/rs_fixture_contract_helpers.lua')
H.Contains('features/life/rs_daily_income_source.lua',{'DailyIncome','Get'})
H.Pass('daily income source authority')
