-- Every page implementation must expose the shared module diagnostics affordance.
-- Standard pages get it from D:PageHeader; custom header pages must place the
-- shared D:ModuleDiagnosticsButton helper. No page may reimplement the click logic.
local passed,failed=0,0
local function Test(name,fn)local ok,err=pcall(fn);if ok then passed=passed+1;print('PASS module-diag-coverage '..name)else failed=failed+1;print('FAIL module-diag-coverage '..name..': '..tostring(err))end end
local function Read(path)local f=assert(io.open(path,'rb'));local s=f:read('*a');f:close();return s end
Test('all V3 page files use shared diagnostic placement',function()
  local p=assert(io.popen("find presentation/v3/pages -maxdepth 1 -name '*.lua' -print | sort"))
  local missing={}
  for path in p:lines() do
    local s=Read(path)
    -- registration-only files still contain PageHeader through their factories; custom
    -- headers must opt into the one shared helper, never duplicate Window:Open logic.
    if not s:find('D:PageHeader(',1,true) and not s:find('D:ModuleDiagnosticsButton(',1,true) then
      missing[#missing+1]=path
    end
  end
  p:close()
  assert(#missing==0,'missing shared module diagnostics entry: '..table.concat(missing,','))
end)
Test('business page files never open module diagnostics window directly',function()
  local p=assert(io.popen("find presentation/v3/pages -maxdepth 1 -name '*.lua' -print | sort"))
  local bad={}
  for path in p:lines() do
    local s=Read(path)
    if s:find('ModuleDiagnosticsWindowV3',1,true) then bad[#bad+1]=path end
  end
  p:close();assert(#bad==0,'direct diagnostics window coupling: '..table.concat(bad,','))
end)
print('MODULE DIAGNOSTICS PAGE COVERAGE RESULT '..passed..' passed / '..failed..' failed ('.._VERSION..')')
if failed>0 then error('module diagnostics page coverage failures: '..failed)end
