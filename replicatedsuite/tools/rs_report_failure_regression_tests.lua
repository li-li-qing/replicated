------------------------------------------------------------------------
-- Replicated Suite · 报告失败回归测试
-- 作者：Replicated
-- QQ群：1104129461
--
-- 按当前生产契约构造的离线测试数据，不能替代实机证据。
------------------------------------------------------------------------
local H=dofile('tools/rs_fixture_contract_helpers.lua')
H.Contains('core/rs_report_copy_transport.lua',{'BuildTextPages','GetTextPage'})
H.Contains('core/rs_self_check_report.lua',{'Build'})
H.Pass('report failure delivery')
