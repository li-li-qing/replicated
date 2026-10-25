-- Replicated Suite · 账本投影测试
-- 作者：Replicated
-- QQ群：1104129461
-- 按当前生产契约构造的离线测试数据，不能替代实机证据。
local H=dofile('tools/rs_fixture_contract_helpers.lua')
H.Contains('presentation/v3/pages/rs_v3_home_overview.lua',{'ledger','projection'})
H.Contains('features/life/rs_daily_ledger.lua',{'Get'})
H.Pass('ledger projection boundary')
