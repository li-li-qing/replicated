-- Replicated Suite · F2受保护页面测试
-- 作者：Replicated
-- QQ群：1104129461
-- 按当前生产契约构造的离线测试数据，不能替代实机证据。
-- Transport 编解码已拆到 rs_persistence_transport.lua，
-- 但 writeFenced/integrity 的完整性事实仍在 rs_persistence.lua 主文件 —— fixture 的契约检查不变。
local H=dofile('tools/rs_fixture_contract_helpers.lua')
H.Contains('core/rs_persistence.lua',{'writeFenced','integrity'})
H.Contains('presentation/v3/pages/rs_v3_foundation_pages.lua',{'上一页','下一页'})
H.Pass('F2 protected diagnostics paging')
