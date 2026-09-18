-- 模块诊断基础设施离线契约：只验证归属/有界性/按需 Provider/固定分页，不能替代 RU UI 实机复制验收。
local passed,failed=0,0
local function Test(name,fn)
    local ok,err=pcall(fn)
    if ok then passed=passed+1;print('PASS module-diagnostics '..name)
    else failed=failed+1;print('FAIL module-diagnostics '..name..': '..tostring(err)) end
end
local function Boot()
    ReplicatedSuite={Generation=1,BuildTag='v3-test',Version='3',SafeTraceback=function(e)return tostring(e)end,
        NowMs=(function() local n=0;return function()n=n+1;return n end end)(),Utils={}}
    local S=ReplicatedSuite
    dofile('core/rs_utils.lua')
    S.FeatureRegistry={
        order={'feature_a','feature_b','system_diagnostics'},
        features={
            feature_a={id='feature_a',route='combat.a',name='模块A',authority='v3.a',category='combat',diagnosticSources={'feature_a_v3'}},
            feature_b={id='feature_b',route='life.b',name='模块B',authority='v3.b',category='life'},
            system_diagnostics={id='system_diagnostics',route='system.diagnostics',name='系统诊断',authority='diagnostics',category='system'},
        },
    }
    function S.FeatureRegistry:Get(id)return self.features[id]end
    function S.FeatureRegistry:GetByRoute(route)for _,id in ipairs(self.order)do local r=self.features[id];if r.route==route then return r end end end
    function S.FeatureRegistry:List()local out={};for _,id in ipairs(self.order)do out[#out+1]=self.features[id]end;return out end
    S.FeatureRuntime={state={feature_a={initialized=false,enabled=false,faulted=false},feature_b={initialized=true,enabled=true,faulted=false}},implementations={feature_a={},feature_b={}}}
    function S.FeatureRuntime:IsEnabled(id)local r=self.state[id];return r and r.enabled==true or false end
    function S.FeatureRuntime:IsImplemented(id)return self.implementations[id]~=nil end
    S.Persistence={}
    function S.Persistence:Describe()return {rows={
        {id='v3.a.settings',owner='v3.a',loadStatus='loaded',writeFenced=false,consecutiveSaveFailures=0,lastIntegrityStatus='ok'},
        {id='v3.b.settings',owner='v3.b',loadStatus='loaded',writeFenced=false,consecutiveSaveFailures=0,lastIntegrityStatus='ok'},
    }}end
    S.ReportCopyTransport={}
    function S.ReportCopyTransport:BuildTextPages(text,capacity,id)
        local pages={};local chunk=math.max(1,math.min(700,capacity-100))
        for i=1,#text,chunk do pages[#pages+1]=text:sub(i,i+chunk-1)end
        if #pages==0 then pages[1]='' end
        return {kind='test',id=id,parts=#pages,pages=pages,text=text,capacity=capacity}
    end
    function S.ReportCopyTransport:GetTextPage(session,index)return session.pages[index] end
    dofile('core/rs_diagnostics.lua')
    dofile('core/rs_module_diagnostics.lua')
    return S
end

Test('route context isolates module error rings',function()
    local S=Boot();local D=S.DiagnosticsManager;local H=S.ModuleDiagnosticsHub
    D:Error('feature','A_FAIL','a exploded',{route='combat.a'})
    D:Error('feature','B_FAIL','b exploded',{route='life.b'})
    local a=H:GetRecent('feature_a');local b=H:GetRecent('feature_b')
    assert(#a==1 and a[1].code=='A_FAIL');assert(#b==1 and b[1].code=='B_FAIL')
    assert(not tostring(H:BuildReport('feature_a')):find('B_FAIL',1,true),'B error leaked into A report')
end)

Test('feature registry diagnostic source alias routes exact module-owned errors',function()
    local S=Boot();local D=S.DiagnosticsManager;local H=S.ModuleDiagnosticsHub
    D:Error('feature_a_v3','ALIAS_FAIL','alias source failure',{})
    local rows=H:GetRecent('feature_a');assert(#rows==1 and rows[1].code=='ALIAS_FAIL')
end)

Test('persistence store owner routes only to matching feature',function()
    local S=Boot();local D=S.DiagnosticsManager;local H=S.ModuleDiagnosticsHub
    D:Error('persistence','STORE_FAIL','store failed',{store='v3.a.settings'})
    assert(#H:GetRecent('feature_a')==1);assert(#H:GetRecent('feature_b')==0)
end)

Test('unknown shared error stays in system ring',function()
    local S=Boot();local D=S.DiagnosticsManager;local H=S.ModuleDiagnosticsHub
    D:Error('persistence','UNKNOWN','no store context',{})
    assert(#H:GetRecent('feature_a')==0 and #H:GetRecent('feature_b')==0)
    assert(#H:GetRecent('system')==1)
end)

Test('per-module ring remains bounded at 32',function()
    local S=Boot();local D=S.DiagnosticsManager;local H=S.ModuleDiagnosticsHub
    for i=1,40 do D:Warn('combat.a','E'..i,'m'..i,{route='combat.a'}) end
    local rows=H:GetRecent('feature_a');assert(#rows==32);assert(rows[1].code=='E9' and rows[32].code=='E40')
end)

Test('capture reattributes bounded global errors emitted before registry was available',function()
    local S=Boot();local D=S.DiagnosticsManager;local H=S.ModuleDiagnosticsHub;local registry=S.FeatureRegistry
    S.FeatureRegistry=nil
    D:Error('persistence','EARLY_STORE_FAIL','early store failed',{store='v3.a.settings'})
    S.FeatureRegistry=registry
    assert(#H:GetRecent('feature_a')==0,'early error should have entered system ring before registry existed')
    local text=assert(H:BuildReport('feature_a'))
    assert(text:find('EARLY_STORE_FAIL',1,true),'cold capture did not reattribute retained global error')
end)

Test('provider is cold and disabled feature is never initialized',function()
    local S=Boot();local H=S.ModuleDiagnosticsHub;local calls=0;local init=0
    S.FeatureRuntime.Initialize=function()init=init+1;return true end
    assert(H:RegisterProvider('feature_a','probe',function()calls=calls+1;return {value=7}end))
    assert(calls==0 and init==0)
    local text=assert(H:BuildReport('feature_a'))
    assert(calls==1 and init==0);assert(text:find('value=7',1,true))
end)

Test('report includes only module-owned store rows',function()
    local S=Boot();local text=assert(S.ModuleDiagnosticsHub:BuildReport('feature_a'))
    assert(text:find('v3.a.settings',1,true));assert(not text:find('v3.b.settings',1,true))
end)

Test('capture freezes report and paging does not recapture providers',function()
    local S=Boot();local H=S.ModuleDiagnosticsHub;local calls=0
    H:RegisterProvider('feature_a','probe',function()calls=calls+1;return {serial=calls,payload=string.rep('X',1600)}end)
    local snap=assert(H:Capture('feature_a',900));assert(calls==1 and snap.parts>1)
    local first=assert(H:GetPage(snap,1));local second=assert(H:GetPage(snap,2));assert(calls==1)
    S.DiagnosticsManager:Error('combat.a','LATE','late',{route='combat.a'})
    assert(H:GetPage(snap,1)==first and H:GetPage(snap,2)==second and calls==1)
end)

Test('real feature registry declares exact aliases for legacy module diagnostic sources',function()
    ReplicatedSuite={}
    dofile('features/rs_feature_registry.lua')
    local expected={combat_buff_display='buff_display_v3',combat_stats='dps_v3',combat_healer='healer_v3',
        combat_death_review='death_review_v3',combat_gear='gear_v3',combat_raid_readiness='raid_readiness_v3',
        life_activities='activities_v3',life_tasks='tasks_v3',life_trade='trade_material_identity',tools_auction='auction'}
    for id,source in pairs(expected) do
        local row=assert(ReplicatedSuite.FeatureRegistry:Get(id),id)
        local found=false;for _,v in ipairs(row.diagnosticSources or {})do if v==source then found=true end end
        assert(found,id..' missing diagnostic source '..source)
    end
end)

print('MODULE DIAGNOSTICS RESULT '..passed..' passed / '..failed..' failed ('.._VERSION..')')
if failed>0 then error('module diagnostics failures: '..failed)end
