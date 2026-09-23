local path='presentation/v3/pages/rs_v3_foundation_pages.lua'
local f=assert(io.open(path,'rb'))
local text=f:read('*a')
f:close()
local printBlock=text:match("printButton%.onClick=function%(%)(.-)fullReportButton%.onClick=function%(") or ''
assert(printBlock:find("PrintPagedSelfCheckReport",1,true),'diagnostics default print must use complete paged fault report')
assert(not printBlock:find("PrintFocusedSelfCheckReport",1,true),'diagnostics default print must not use clipped focused compatibility report')
print('DIAGNOSTIC DEFAULT PAGED RESULT 2 passed / 0 failed ('.._VERSION..')')
