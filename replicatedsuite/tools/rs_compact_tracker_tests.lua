-- Restored in Phase 0 from current production contracts; offline fixture only.
local H=dofile('tools/rs_fixture_contract_helpers.lua')
H.Contains('presentation/v3/pages/rs_v3_home_overview.lua',{'GetOverviewProjection','AcquireConsumer'})
H.Contains('features/life/tasks/rs_task_feature.lua',{'GetOverviewProjection'})
H.Pass('compact tracker integration')
