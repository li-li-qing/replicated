-- Buff Feature 合并读取回归：真实 Feature/Projection，受控服务只提供独立事实。
-- 保留 TTL/强刷/目标撤销/旧宿主回退，不因省中间副本重复采样；不进入 TOC。
local Host = dofile('tools/rs_pvp_hud_test_host.lua')
local passed, failed = 0, 0
local function Test(name, fn)
    local ok, err = xpcall(fn, debug.traceback)
    if ok then passed=passed+1; print('PASS buff-normalized-read '..name)
    else failed=failed+1; print('FAIL buff-normalized-read '..name..': '..tostring(err)) end
end
local function Copy(value)
    if type(value)~='table' then return value end
    local out={}; for key,item in pairs(value) do out[key]=Copy(item) end; return out
end
local function Equal(a,b)
    assert(type(a)==type(b),'types differ')
    if type(a)~='table' then assert(a==b,'values differ'); return end
    for key,value in pairs(a) do Equal(value,b[key]) end
    for key in pairs(b) do assert(a[key]~=nil,'extra key '..tostring(key)) end
end
local function Boot(combined)
    local h,S,F=Host({runtimeHud=true,noRenderer=true})
    h.reads,h.snapshots,h.maps=0,0,0
    h.statuses={[101]={id=101,name='Observed',iconPath='observed.dds',stack=2,timeLeft=700,
        sources={buff=true},sourceMask=1}}
    h.meta={available=true,complete=true,reliable=true,rows=1,lanes=3}
    h.summary={unitId='target',at=1234,revision=71,
        buff={count=1},debuff={count=2},hidden={count=3}}
    local A={}
    function A:GetSnapshot(scope,options)
        h.snapshots=h.snapshots+1; h.scope,h.options=scope,Copy(options)
        if h.legacyError then return nil,h.legacyError end
        assert(not h.forbidLegacy,'legacy snapshot copied on combined path')
        return Copy(h.summary)
    end
    function A:GetStatusMap(snapshot,options)
        h.maps=h.maps+1; assert(not h.forbidLegacy,'legacy map used on combined path')
        return Copy(h.statuses),Copy(h.meta)
    end
    if combined then
        function A:GetUnitStatusMap(scope,options)
            h.reads=h.reads+1; h.scope,h.options=scope,Copy(options)
            if h.readError then return nil,nil,nil,h.readError end
            return Copy(h.statuses),Copy(h.meta),Copy(h.summary),nil
        end
    end
    S.Services.AuraObservationV3=A
    return h,S,F,A
end
local function View(F)
    return {rows=Copy(F.projections.target),coverage=Copy(F.coverage.target),lane=Copy(F.laneData.target)}
end

Test('combined read skips the raw snapshot copy chain and preserves coverage',function()
    local h,S,F=Boot(true); h.forbidLegacy=true
    assert(F:RefreshScope('target'))
    assert(h.reads==1 and h.snapshots==0 and h.maps==0,'combined path not selected')
    assert(#F.projections.target==1 and F.projections.target[1].id==101)
    assert(F.coverage.target.revision==71 and F.coverage.target.scannedAt==1234)
    assert(F.coverage.target.buffCount==1 and F.coverage.target.debuffCount==2 and F.coverage.target.hiddenCount==3)
end)
Test('legacy providers and combined providers produce the same public rows and lane data',function()
    local old,oldS,oldF=Boot(false); assert(oldF:RefreshScope('target')); local expected=View(oldF)
    local h,S,F=Boot(true); assert(F:RefreshScope('target')); Equal(expected,View(F))
    assert(old.snapshots==1 and old.maps==1 and h.reads==1 and h.snapshots==0)
end)
Test('force refresh and target invalidation retain the same single request options',function()
    local h,S,F=Boot(true); assert(F:RefreshScope('target'))
    assert(h.scope=='target' and h.options.buff and h.options.debuff and h.options.hidden)
    assert(h.options.forceRefresh==false and h.options.ttlMs>0)
    local expectedTtl,expectedLimit=h.options.ttlMs,h.options.limit
    assert(F:RefreshScope('target',true)); assert(h.options.forceRefresh==true)
    F.targetInvalidated=true; assert(F:RefreshScope('target'))
    assert(h.options.forceRefresh==true and F.targetInvalidated==false)
    assert(h.options.ttlMs==expectedTtl and h.options.limit==expectedLimit and h.reads==3 and h.snapshots==0)
end)
Test('combined read failure clears live target data without retrying the old scan',function()
    local h,S,F=Boot(true); assert(F:RefreshScope('target'))
    F.targetInvalidated=true; h.readError='lease unavailable'; h.forbidLegacy=true
    local ok,err=F:RefreshScope('target')
    assert(ok==false and err=='lease unavailable')
    assert(#F.projections.target==0 and #F.laneData.target.buffRows==0 and #F.laneData.target.debuffRows==0)
    assert(not F.coverage.target.available and F.coverage.target.error==err and F.targetInvalidated==true)
    assert(next(F.laneData.target.targetLoadout)==nil and h.reads==2 and h.snapshots==0 and h.maps==0)
end)
Test('recovery and partial coverage show current observed facts without retaining the old target',function()
    local h,S,F=Boot(true); assert(F:RefreshScope('target')); h.readError='missing'; assert(not F:RefreshScope('target'))
    h.readError=nil; h.statuses[202]=h.statuses[101]; h.statuses[101]=nil; h.statuses[202].id=202
    h.statuses[202].name='New target'; h.meta.complete,h.meta.reliable=false,false
    h.summary.at,h.summary.revision=1500,72
    assert(F:RefreshScope('target',true))
    assert(#F.projections.target==1 and F.projections.target[1].id==202 and F.projections.target[1].name=='New target')
    assert(F.coverage.target.available and not F.coverage.target.complete and not F.coverage.target.reliable)
    assert(F.coverage.target.revision==72 and F.coverage.target.scannedAt==1500)
end)
Test('legacy read failures do not normalize unavailable snapshots',function()
    local h,S,F=Boot(false); assert(F:RefreshScope('target')); h.legacyError='legacy missing'
    local ok,err=F:RefreshScope('target'); assert(ok==false and err=='legacy missing')
    assert(h.snapshots==2 and h.maps==1 and #F.projections.target==0 and #F.laneData.target.buffRows==0)
end)
Test('a target change during the combined read rejects the superseded target',function()
    local h,S,F,A=Boot(true); assert(F:RefreshScope('target'))
    local read=A.GetUnitStatusMap
    function A:GetUnitStatusMap(scope,options)
        local map,meta,summary,err=read(self,scope,options)
        F.pvpMetrics.targetInvalidations=F.pvpMetrics.targetInvalidations+1
        F.targetInvalidated=true
        return map,meta,summary,err
    end
    local ok,err=F:RefreshScope('target')
    assert(ok==false and err=='target changed during aura read')
    assert(F.targetInvalidated==true and #F.projections.target==0 and #F.laneData.target.buffRows==0)
    assert(h.reads==2 and h.snapshots==0)
end)
Test('initialization and refresh accept a combined-only provider',function()
    local h,S,F,A=Boot(true); A.GetSnapshot,A.GetStatusMap=nil,nil
    assert(F:Initialize()); assert(F:RefreshScope('target'))
    assert(h.reads==1 and #F.projections.target==1)
end)
Test('invalid scopes never enter either service path',function()
    local h,S,F=Boot(true); local ok,err=F:RefreshScope('unknown')
    assert(ok==false and err=='invalid buff display scope' and h.reads==0 and h.snapshots==0 and h.maps==0)
end)
print('BUFF_NORMALIZED_READ_RESULT passed='..passed..' failed='..failed)
if failed>0 then os.exit(1) end
