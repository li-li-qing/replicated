-- Replicated Suite · 模块诊断页面覆盖测试
-- 作者：Replicated
-- QQ群：1104129461
-- 每个页面必须提供共享模块诊断入口：标准页由 D:PageHeader 注入，自定义页头放置 D:ModuleDiagnosticsButton，不能自行实现点击逻辑。
local passed,failed=0,0
local function Test(name,fn)local ok,err=pcall(fn);if ok then passed=passed+1;print('PASS module-diag-coverage '..name)else failed=failed+1;print('FAIL module-diag-coverage '..name..': '..tostring(err))end end
local function Read(path)local f=assert(io.open(path,'rb'));local s=f:read('*a');f:close();return s end
Test('all V3 page files use shared diagnostic placement',function()
  local p=assert(io.popen("find presentation/v3/pages -maxdepth 1 -name '*.lua' -print | sort"))
  local missing={}
  for path in p:lines() do
    local s=Read(path)
    -- 仅注册的页面文件仍由工厂提供 PageHeader；自定义页头必须使用共享辅助函数，不能重复 Window:Open 逻辑。
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
