-- Restored in Phase 0 from current production contracts; offline fixture only.
local H=dofile('tools/rs_fixture_contract_helpers.lua')
H.Contains('core/rs_report_copy_transport.lua',{'BuildTextPages','GetTextPage'})
H.Contains('core/rs_self_check_report.lua',{'Build'})
H.Pass('report failure delivery')
