-- Restored in Phase 0 from current production contracts; offline fixture only.
local H=dofile('tools/rs_fixture_contract_helpers.lua')
H.Contains('presentation/v3/pages/rs_v3_home_overview.lua',{'projection','AcquireConsumer'})
H.Contains('services/rs_price_quote_queue_v3.lua',{'RequestQuote','CancelRequester'})
H.Pass('overview quote integration')
