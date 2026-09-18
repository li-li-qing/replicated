-- Development-only regression: real Store/Core and page factory/BuildScope, synthetic Native UI.
-- Reproduces build-time persistent-toggle reads on a fenced index. Does not assume F2's cause.
local passed,failed=0,0
local function Test(name,fn)
    local ok,err=pcall(fn)
    if ok then passed=passed+1;print('PASS F2 page '..name)
    else failed=failed+1;print('FAIL F2 page '..name..': '..tostring(err))end
end
local function Copy(x) if type(x)~='table' then return x end;local y={};for k,v in pairs(x)do y[k]=Copy(v)end;return y end
local function Boot(bad)
    local disk,c={}, {reads=0,writes=0,clears=0,toggles=0,subscriptions=0,commands=0,settings=0}
    ADDON={LoadData=function(_,key)c.reads=c.reads+1;return Copy(disk[key])end,
        SaveData=function(_,key,value)c.writes=c.writes+1;disk[key]=Copy(value);return true end,
        ClearData=function()c.clears=c.clears+1;error('must not clear')end}
    ReplicatedSuite={Features={},Services={},UI={CreateWindowShell=function()error('no HUD')end},RSUI={},NowMs=function()return 1000 end,Generation=5,
        SafeTraceback=function(err)return tostring(err)end,FeatureRuntime={RegisterImplementation=function()return true end}}
    local S=ReplicatedSuite
    dofile('core/rs_utils.lua');dofile('core/rs_reuse.lua');dofile('core/rs_demand.lua')
    dofile('core/rs_api.lua');dofile('core/rs_api_capabilities.lua');dofile('core/rs_persistence.lua')
    dofile('ui/framework/rs_ui_floating_surface.lua');dofile('features/combat/death_review/rs_death_review_store.lua')
    local P,F=S.Persistence,S.Features.DeathReview;local st=P:GetStore('v3.death_review')
    assert(P:LoadStore(st.id));st.apply(st.default());assert(P:SaveStore(st.id,{force=true,verifyAfterSave=true}))
    local key=P:ResolveStoreKey(st)
    if bad then
        local raw=assert(P:DecodePhysicalEnvelope(Copy(disk[key])))
        raw.__rsmeta.encodedFingerprint='00000000';raw.__rsmeta.envelopeFingerprint=assert(P:FingerprintEnvelopeIntegrity(raw))
        disk[key]=assert(P:EncodePhysicalEnvelope(raw));assert(not P:LoadStore(st.id,{discardDirty=true,discardUnverified=true,revalidateTerminal=true}))
    else st.loaded=false end
    local floating=S.RSUI.FloatingSurface;dofile('ui/framework/rs_ui_component_core.lua');S.RSUI.FloatingSurface=floating
    local h=dofile('tools/rs_status_ui_test_host.lua')(S)
    S.UIV3Design.ScrollablePageRoot=S.UIV3Design.PageRoot
    S.UIV3Design.NumericSetting=function(_,parent,spec)return h.Node(spec)end
    local box=S.RSUI.VerticalBox;S.RSUI.VerticalBox=function(self,spec)local n=box(self,spec);n.SetVisible=function(o,v)o.visible=v end;return n end
    F.GetSettingsProjection=function(self)c.settings=c.settings+1;return self:GetSettings()end
    F.Commands=setmetatable({},{__index=function()return function()c.commands=c.commands+1;error('no write commands during build')end end})
    S.Events={SubscribeInternal=function()c.subscriptions=c.subscriptions+1 end,UnsubscribeInternalOwner=function()c.subscriptions=c.subscriptions-1 end}
    local toggle=S.RSUI.Toggle
    S.RSUI.Toggle=function(self,spec)
        c.toggles=c.toggles+1
        assert(P:IsStoreLoaded(st.id)==true,'toggle constructed before store preparation')
        return toggle(self,spec)
    end
    dofile('presentation/v3/shell/rs_v3_page_host.lua');dofile('presentation/v3/pages/rs_v3_death_review_page.lua')
    local H=S.UIV3.PageHost;assert(H:Attach(h.Node({id='parent'})))
    S.UIV3.Navigate=function(_,route,context)c.navigation=route;return H:Navigate(route,context)end
    H:RegisterFactory('system.diagnostics',function()return h.Node({id='diagnostics'})end)
    H:RegisterFactory('home',function()return h.Node({id='home'})end)
    c.reads,c.writes=0,0
    return S,P,F,st,c,h,H
end
Test('healthy index is prepared before first bound toggle',function()
    local _,_,_,st,c,_,H=Boot(false)
    local page,err=H:CreatePage('combat.death_review');assert(page,err)
    assert(not page.persistenceUnavailable and c.toggles==2 and st.loadStatus=='loaded')
    assert(c.writes==0 and c.commands==0)
end)
Test('fenced index constructs a read-only page without bound controls or repeated reads',function()
    local _,_,_,st,c,h,H=Boot(true)
    local page,err=H:CreatePage('combat.death_review');assert(page,err)
    assert(page.persistenceUnavailable==true and st.writeFenced)
    assert(c.toggles==0 and c.settings==0 and c.writes==0 and c.reads==0 and c.commands==0)
    assert(h.widgets.v3_death_review_clear==nil and h.widgets.v3_death_review_enable==nil)
    assert(page:OnActivated() and page:OnDeactivated());assert(c.subscriptions==0 and c.reads==0)
end)
Test('real PageHost and BuildScope commit the protected route without quarantine',function()
    local S,_,_,st,c,_,H=Boot(true)
    assert(H:Navigate('home'));local ok,err=H:Navigate('combat.death_review');assert(ok,err)
    assert(H.stats.buildFailures==0 and next(H.failedPages)==nil and #S.RSUI.buildScopeStack==0)
    assert(S.RSUI.metrics.buildTransactionFailures==0 and st.writeFenced)
    assert(H:Navigate('home'));assert(H:Navigate('combat.death_review'));assert(c.reads==0 and c.writes==0)
end)
Test('protected page navigates through V3 rather than invoking another feature',function()
    local _,_,_,st,c,h,H=Boot(true);assert(H:Navigate('combat.death_review'))
    local b=assert(h.widgets.v3_death_review_diagnostics,'single diagnostic navigation absent')
    assert(b.onClick());assert(c.navigation=='system.diagnostics' and st.writeFenced)
    assert(c.commands==0 and c.reads==0 and c.writes==0)
end)
Test('throwing preparation is isolated before binding creation',function()
    local _,_,F,_,c,_,H=Boot(true);F.EnsureStoreLoaded=function()error('synthetic load exception')end
    local ok,err=H:Navigate('combat.death_review');assert(ok,err)
    assert(H.pages['combat.death_review'].persistenceUnavailable and c.toggles==0)
end)
Test('missing preparation is not treated as permission to show default editors',function()
    local _,_,F,_,c,_,H=Boot(true);F.EnsureStoreLoaded=nil
    local ok,err=H:Navigate('combat.death_review');assert(ok,err)
    assert(H.pages['combat.death_review'].persistenceUnavailable and c.toggles==0)
end)
Test('real construction errors still cause a build failure',function()
    local S,_,_,_,_,_,H=Boot(true)
    S.UIV3Design.ScrollablePageRoot=function()return nil,'injected root failure'end
    local ok,err=H:Navigate('combat.death_review');assert(not ok and H.stats.buildFailures==1)
    assert(tostring(err):find('injected root failure',1,true),'unrelated failure masked construction regression')
end)
Test('numeric evidence reports actual float-first candidates instead of a misleading no-alternative',function()
    local _,P,_,st=Boot(true)
    local raw={codec=1,__rsmeta={store=st.id,owner=st.owner,framework=3,transportVersion=2,schema=2,integrityVersion=4},
        payload={widgetWindow={userMoved=true,coordinateSpace='logical-free-v2',normalizedCenterX=0.82991701364517212,normalizedCenterY=0.19861100614070892}}}
    local canonical={codec=1,payload=Copy(raw.payload)}
    assert(P:RebuildFixed6WindowCanonical(st,Copy(raw.payload),'695423CD',canonical,raw,2,1)==nil)
    local proof=st.lastWindowNumericEvidence
    assert(proof.attempts>0 and proof.attempts<=32 and proof.matches==0)
    -- 维护：udf已证明Float32先行会产生旧模型没有的候选，这里确认计数真的执行。
    assert(proof.fields.normalizedCenterX.reason=='tested','eligible candidate was not tested')
    assert(proof.fields.normalizedCenterY.reason=='tested' or proof.fields.normalizedCenterY.reason=='no_alternative')
end)
print('F2 PAGE RESULT '..passed..' passed / '..failed..' failed ('.._VERSION..')')
assert(failed==0,'F2 page failures')
