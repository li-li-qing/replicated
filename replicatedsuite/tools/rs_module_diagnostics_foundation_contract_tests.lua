-- Partial overlay protection: Foundation Gate must block if any module diagnostics
-- architecture component is missing, so users never get a half-upgraded UI.
local passed,failed=0,0
local function Test(name,fn)local ok,err=pcall(fn);if ok then passed=passed+1;print('PASS module-diag-foundation '..name)else failed=failed+1;print('FAIL module-diag-foundation '..name..': '..tostring(err))end end
local f=assert(io.open('core/rs_foundation_gate.lua','rb'));local s=f:read('*a');f:close()
Test('foundation gate owns one module diagnostics contract check',function()
  assert(s:find('v3_module_diagnostics_contract',1,true),'gate check missing')
end)
Test('gate requires hub copybox page context design header and floating window contracts',function()
  for _,word in ipairs({'ModuleDiagnosticsHub','DiagnosticCopyBoxContractVersion','buildContextContractVersion','diagnosticHeaderContractVersion','ModuleDiagnosticsWindowV3','diagnosticSources','buff_display_v3'}) do
    assert(s:find(word,1,true),'missing gate dependency '..word)
  end
end)
print('MODULE DIAGNOSTICS FOUNDATION CONTRACT RESULT '..passed..' passed / '..failed..' failed ('.._VERSION..')')
if failed>0 then error('module diagnostics foundation gate failures: '..failed)end
