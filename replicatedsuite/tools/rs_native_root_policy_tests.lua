-- Replicated Suite · 原生根窗口策略诊断回归
-- 作者：Replicated
-- QQ群：1104129461
-- 真实 Adapter/Foundation Gate；Native 仅模拟 Esc 接口接受/拒绝。
-- 主 Shell 显式启用 Esc 时，不应因没有禁用 Esc 的其它根窗口而误报阻断。
local Boot = dofile('tools/rs_window_viewport_test_host.lua')
local passed, failed = 0, 0
local function Test(name, fn)
    local ok, err = xpcall(fn, debug.traceback)
    if ok then passed=passed+1; print('PASS native root policy '..name)
    else failed=failed+1; print('FAIL native root policy '..name..': '..tostring(err)) end
end
local function Host(options)
    local h=Boot(); local S=h.S
    local registered={}
    function S.UI:Register(id,window)
        assert(registered[id]==nil,'fixture duplicate root registration')
        registered[id]=window; return window
    end
    S.Features={}; S.Services={}
    S.UIHostManager={Describe=function()return {total=1,activeId='v3'} end,
        IsRegistered=function(_,id)return id=='v3' end}
    local create=S.NativeObjectFactory.CreateWindow
    function S.NativeObjectFactory:CreateWindow(...)
        local window=create(self,...)
        if options=='missing' then window.SetCloseOnEscape=nil
        elseif options=='reject' then window.SetCloseOnEscape=function()return false end
        else window.SetCloseOnEscape=function(self,value)self.closeOnEscape=value;return value end end
        return window
    end
    dofile('presentation/v3/rs_v3_native_adapter.lua')
    dofile('core/rs_foundation_gate.lua')
    return S,S.UIV3NativeAdapter
end
local function Check(S)
    local report=S.FoundationGate:Run({skipSequences=true})
    for _,row in ipairs(report.checks) do if row.id=='v3_native_root_policy' then return row end end
    error('native root policy check missing')
end

Test('only Esc enabled main root passes the real gate',function()
    local S,A=Host()
    local root=assert(A:CreateRootWindow('main','v3:main','normal',{closeOnEscape=true}))
    assert(root.closeOnEscape==true)
    local check=Check(S)
    assert(check.ok,check.detail)
    local d=A:Describe()
    assert(d.nativeEscapeCloseEnabled==1 and d.nativeEscapeCloseDisabled==0,'enabled policy evidence missing')
    assert(check.detail:find('escapeEnabled=1',1,true),'diagnostic must explain enabled policy')
end)
Test('default Esc disabled root still passes including native false state result',function()
    local S,A=Host()
    local root=assert(A:CreateRootWindow('hud','v3:hud'))
    assert(root.closeOnEscape==false)
    assert(Check(S).ok)
    local d=A:Describe()
    assert(d.nativeEscapeCloseEnabled==0 and d.nativeEscapeCloseDisabled==1)
end)
Test('mixed explicit policies preserve separate evidence',function()
    local S,A=Host()
    assert(A:CreateRootWindow('main','v3:main','normal',{closeOnEscape=true}))
    assert(A:CreateRootWindow('hud','v3:hud'))
    local d=A:Describe()
    assert(d.rootsCreated==2 and d.nativeEscapeCloseEnabled==1 and d.nativeEscapeCloseDisabled==1)
    assert(Check(S).ok)
end)
Test('native rejection of requested Esc enable remains blocked',function()
    local S,A=Host('reject')
    local root,err=A:CreateRootWindow('main','v3:main','normal',{closeOnEscape=true})
    assert(root==nil and err=='v3 root escape policy rejected')
    assert(not Check(S).ok)
end)
Test('missing requested Esc capability remains blocked',function()
    local S,A=Host('missing')
    local root,err=A:CreateRootWindow('main','v3:main','normal',{closeOnEscape=true})
    assert(root==nil and err=='v3 root escape policy rejected')
    assert(not Check(S).ok)
end)
Test('created root without native policy evidence remains blocked',function()
    local S,A=Host('missing')
    assert(A:CreateRootWindow('hud','v3:hud'))
    assert(not Check(S).ok,'rootsCreated alone cannot prove Esc policy')
end)
Test('no roots remains blocked',function()
    local S=Host()
    assert(not Check(S).ok)
end)
print(string.format('NATIVE ROOT POLICY RESULT %d passed / %d failed (%s)',passed,failed,_VERSION))
assert(failed==0,'native root policy regression failures: '..failed)
