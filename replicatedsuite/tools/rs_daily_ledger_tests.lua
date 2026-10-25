-- Replicated Suite · 每日账本测试
-- 作者：Replicated
-- QQ群：1104129461
-- 按当前生产契约构造的离线测试数据，不能替代实机证据。
local H=dofile('tools/rs_fixture_contract_helpers.lua')
H.Contains('features/life/rs_daily_ledger.lua',{'DailyLedger','Get'})
H.Pass('daily ledger authority')
