------------------------------------------------------------------------
-- Replicated Suite · 任务测试
-- 作者：Replicated
-- QQ群：1104129461
--
-- 按当前生产契约构造的离线测试数据，不能替代实机证据。
------------------------------------------------------------------------
local H=dofile('tools/rs_fixture_contract_helpers.lua')
H.Contains('features/life/tasks/rs_task_feature.lua',{'AcquireConsumer','ReleaseConsumer','Commands'})
H.Contains('features/life/tasks/rs_task_acceptance.lua',{'v3_m1_tasks'})
H.Pass('task tracker contract')
