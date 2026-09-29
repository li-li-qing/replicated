-- Restored in Phase 0 from current production contracts; offline fixture only.
-- 中文维护注释（2026-09-30，giant-file-1）：Transport 编解码已拆到 rs_persistence_transport.lua，
-- 但 writeFenced/integrity 的完整性事实仍在 rs_persistence.lua 主文件 —— fixture 的契约检查不变。
local H=dofile('tools/rs_fixture_contract_helpers.lua')
H.Contains('core/rs_persistence.lua',{'writeFenced','integrity'})
H.Contains('presentation/v3/pages/rs_v3_foundation_pages.lua',{'上一页','下一页'})
H.Pass('F2 protected diagnostics paging')
