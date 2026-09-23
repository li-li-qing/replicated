------------------------------------------------------------------------
-- Replicated Suite - module toolbar late-binding regression tests
-- Synthetic RSUI only. Verifies the logical action remains replaceable while
-- the toolbar Button keeps the same creation-time trampoline for its lifetime.
------------------------------------------------------------------------
local passed = 0
local function Eq(a,b,msg) assert(a==b,(msg or 'mismatch')..' expected='..tostring(b)..' actual='..tostring(a)) end
local function Test(name,fn)
    local ok,err=xpcall(fn,debug.traceback)
    if not ok then io.stderr:write('FAIL module-toggle ',name,': ',tostring(err),'\n'); os.exit(1) end
    passed=passed+1
end

ReplicatedSuite={BootError=nil,UIV3={},DiagnosticsManager={Error=function()end}}
local S=ReplicatedSuite
local runtimeEnabled={}
S.FeatureRuntime={
    IsEnabled=function(_,id)return runtimeEnabled[id]==true end,
    GetControlState=function(_,id)return {implemented=true,initialized=false,enabled=runtimeEnabled[id]==true,faulted=false} end,
    SetPreferredEnabled=function(_,id,value)runtimeEnabled[id]=value==true;return true end,
}
S.FeatureRegistry={Get=function(_,id)return {id=id,runtimeBlocked=false,performanceLabel='低'}end}

local function Component(spec)
    local c={spec=spec or {},onClick=spec and spec.onClick or nil,enabled=true,text=spec and spec.text or ''}
    function c:GetOnClick()if type(self.onClick)=='function'then return self.onClick end;if self.spec and type(self.spec.onClick)=='function'then return self.spec.onClick end end
    function c:SetOnClick(fn)self.onClick=fn;self.spec.onClick=fn;return true end
    function c:Click(...)local fn=self:GetOnClick();if type(fn)~='function'then return false end;return fn(...) end
    function c:SetText(v)self.text=tostring(v or '');return true end
    function c:SetEnabled(v)self.enabled=v~=false;return true end
    function c:SetStatusTone()return true end
    return c
end
S.RSUI={}
function S.RSUI:HorizontalBox(spec)return Component(spec)end
function S.RSUI:Button(spec)return Component(spec)end
function S.RSUI:Text(spec)return Component(spec)end
setmetatable(S.RSUI,{__index=function(_,key)return function(_,spec)return Component(spec)end end})

dofile('presentation/v3/shell/rs_v3_module_controls.lua')
local M=assert(S.UIV3.ModuleControlsV3)
local currentContext=nil
S.UIV3.PageHost={GetBuildContext=function()return currentContext end}
dofile('ui/design_system/rs_ui_design_system_v3.lua')
local D=assert(S.UIV3Design)

local function Meta(id)return {id=id,category='combat',lifecycle='independent',runtimeBlocked=false,performanceLabel='低'}end

Test('inline DesignSystem action keeps creation trampoline',function()
    local meta=Meta('combat_nameplate_visuals')
    local bar=assert(M:Create({},'combat.nameplate_visuals',meta))
    local created=bar.toggle:GetOnClick()
    Eq(created,bar.trampoline,'creation callback')
    local called=0
    currentContext={controlBar=bar,moduleId=meta.id,route='combat.nameplate_visuals',feature=meta}
    local adopted=D:ModuleToggleButton({id='ignored',onClick=function()called=called+1;return true end})
    currentContext=nil
    Eq(adopted,bar.toggle,'adopted button')
    Eq(bar.toggle:GetOnClick(),bar.trampoline,'DesignSystem must not replace trampoline')
    assert(M:Finish(bar,{Refresh=function()return true end}))
    Eq(bar.toggle:GetOnClick(),bar.trampoline,'Finish must keep trampoline')
    assert(bar.toggle:Click())
    Eq(called,1,'page action calls')
    Eq(bar.actionMetrics.clicks,1,'click metric')
    Eq(bar.actionMetrics.completed,1,'completed metric')
end)

Test('legacy spec-only late action remains compatible',function()
    local meta=Meta('combat_dps')
    local bar=assert(M:Create({},'combat.dps',meta))
    currentContext={controlBar=bar,moduleId=meta.id,route='combat.dps',feature=meta}
    local adopted=D:ModuleToggleButton({id='ignored'})
    currentContext=nil
    local called=0
    adopted.spec.onClick=function()called=called+1;return true end
    assert(M:Finish(bar,{}))
    Eq(adopted:GetOnClick(),bar.trampoline,'legacy action is captured then trampoline restored')
    assert(adopted:Click())
    Eq(called,1,'legacy spec action calls')
end)

Test('legacy direct component action remains compatible',function()
    local meta=Meta('life_housing')
    local bar=assert(M:Create({},'life.housing',meta))
    currentContext={controlBar=bar,moduleId=meta.id,route='life.housing',feature=meta}
    local adopted=D:ModuleToggleButton({id='ignored'})
    currentContext=nil
    local called=0
    adopted.onClick=function()called=called+1;return true end
    assert(M:Finish(bar,{}))
    Eq(adopted:GetOnClick(),bar.trampoline,'legacy direct action is captured then trampoline restored')
    assert(adopted:Click())
    Eq(called,1,'legacy direct action calls')
end)

Test('no page action falls back to FeatureRuntime toggle',function()
    local meta=Meta('combat_gear')
    local bar=assert(M:Create({},'combat.gear',meta))
    assert(M:Finish(bar,{}))
    Eq(runtimeEnabled[meta.id],nil)
    assert(bar.toggle:Click())
    Eq(runtimeEnabled[meta.id],true,'fallback enable')
    assert(bar.toggle:Click())
    Eq(runtimeEnabled[meta.id],false,'fallback disable')
end)

print('MODULE_TOGGLE_TRAMPOLINE_TESTS PASS: '..tostring(passed))
