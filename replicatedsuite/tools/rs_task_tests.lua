-- Restored in Phase 0 from current production contracts; offline fixture only.
local H=dofile('tools/rs_fixture_contract_helpers.lua')
H.Contains('features/life/tasks/rs_task_feature.lua',{'AcquireConsumer','ReleaseConsumer','Commands'})
H.Contains('features/life/tasks/rs_task_acceptance.lua',{'v3_m1_tasks'})
H.Pass('task tracker contract')
