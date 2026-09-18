-- System diagnostics remains a Foundation maintenance surface. Business failures
-- should be directed to the per-module diagnostics entry to avoid giant reports.
local passed,failed=0,0
local function Test(name,fn)local ok,err=pcall(fn);if ok then passed=passed+1;print('PASS module-diag-system-scope '..name)else failed=failed+1;print('FAIL module-diag-system-scope '..name..': '..tostring(err))end end
local f=assert(io.open('presentation/v3/pages/rs_v3_foundation_pages.lua','rb'));local s=f:read('*a');f:close()
Test('system page explicitly identifies foundation scope',function()
  assert(s:find('系统诊断与维护',1,true),'system diagnostics title did not move to foundation scope')
end)
Test('system page directs business module faults to module diagnostic button',function()
  assert(s:find('业务模块',1,true) and s:find('右上角',1,true) and s:find('诊断',1,true),'module diagnostics guidance missing')
end)
Test('full maintenance report remains available',function()
  assert(s:find('完整报告',1,true) and s:find('PrintPagedSelfCheckReport',1,true),'full maintenance path removed')
end)
print('MODULE DIAGNOSTICS SYSTEM SCOPE RESULT '..passed..' passed / '..failed..' failed ('.._VERSION..')')
if failed>0 then error('module diagnostics system scope failures: '..failed)end
