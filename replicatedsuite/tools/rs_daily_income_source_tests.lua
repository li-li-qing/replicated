-- Replicated Suite · 每日收益来源测试
-- 作者：Replicated
-- QQ群：1104129461
-- 按当前生产契约构造的离线测试数据，不能替代实机证据。
local H=dofile('tools/rs_fixture_contract_helpers.lua')
H.Contains('features/life/rs_daily_income_source.lua',{'DailyIncome','Get'})
H.Pass('daily income source authority')
