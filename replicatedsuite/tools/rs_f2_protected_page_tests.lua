-- Restored in Phase 0 from current production contracts; offline fixture only.
local H=dofile('tools/rs_fixture_contract_helpers.lua')
H.Contains('core/rs_persistence.lua',{'writeFenced','integrity'})
H.Contains('presentation/v3/pages/rs_v3_foundation_pages.lua',{'上一页','下一页'})
H.Pass('F2 protected diagnostics paging')
