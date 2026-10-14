------------------------------------------------------------------------
-- Replicated Suite · 总览报价测试
-- 作者：Replicated
-- QQ群：1104129461
--
-- 按当前生产契约构造的离线测试数据，不能替代实机证据。
------------------------------------------------------------------------
local H=dofile('tools/rs_fixture_contract_helpers.lua')
H.Contains('presentation/v3/pages/rs_v3_home_overview.lua',{'projection','AcquireConsumer'})
H.Contains('services/rs_price_quote_queue_v3.lua',{'RequestQuote','CancelRequester'})
H.Pass('overview quote integration')
