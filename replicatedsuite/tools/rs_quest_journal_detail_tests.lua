-- Restored in Phase 0 from current production contracts; offline fixture only.
local H=dofile('tools/rs_fixture_contract_helpers.lua')
H.Contains('services/rs_quest_progress_v3.lua',{'GetGroupDetail','GetProgress'})
H.Pass('quest journal detail service')
