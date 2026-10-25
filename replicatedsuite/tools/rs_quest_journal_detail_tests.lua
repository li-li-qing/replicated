-- Replicated Suite · 任务日志详情测试
-- 作者：Replicated
-- QQ群：1104129461
-- 按当前生产契约构造的离线测试数据，不能替代实机证据。
local H=dofile('tools/rs_fixture_contract_helpers.lua')
H.Contains('services/rs_quest_progress_v3.lua',{'GetGroupDetail','GetProgress'})
H.Pass('quest journal detail service')
