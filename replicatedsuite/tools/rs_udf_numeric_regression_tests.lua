-- Replicated Suite · UDF数值回归测试
-- 作者：Replicated
-- QQ群：1104129461
-- 按当前生产契约构造的离线测试数据，不能替代实机证据。
local H=dofile('tools/rs_fixture_contract_helpers.lua')
H.Contains('core/rs_persistence.lua',{'schemaVersion'})
H.Contains('tools/rs_native_numeric_transport_tests.lua',{'numeric'})
H.Pass('numeric transport/UDF regression')
