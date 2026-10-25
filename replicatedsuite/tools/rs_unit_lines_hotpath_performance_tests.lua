-- 单位连线热路径专项：真实 Feature/Factory/Projection/Demand；仅替换 Native 与时钟。
-- 计数与分配证据不等于 RU 帧率；不进 TOC，不访问游戏或玩家 UDF。
local passed,failed=0,0
local source=(arg and arg[1]) or 'features/combat/unit_lines/rs_unit_lines_feature.lua'
local measureOnly=arg and arg[2]=='--measure'
local benchmarkOnly=arg and arg[2]=='--benchmark'
local H=dofile('tools/rs_udf_numeric_test_host.lua')
local keys={'target','targettarget','focus','focustarget'}
local flags={'showTarget','showTargetTarget','showFocusTarget','showFocusTargetTarget'}
local from={'player','target','player','watchtarget'}
local to={'target','targettarget','watchtarget','watchtargettarget'}
local function Test(name,fn)
    local ok,err=xpcall(fn,debug.traceback)
    if ok then passed=passed+1;print('PASS unit-lines-hotpath '..name)
    else failed=failed+1;print('FAIL unit-lines-hotpath '..name..': '..tostring(err))end
end
local function Boot()
    local c={native=0,world=0,batches=0,now=0,screen={
        player={200,300,1},target={600,400,1},targettarget={1000,500,1},
        watchtarget={300,700,1},watchtargettarget={800,800,1}}}
    X2Unit={GetUnitScreenPosition=function(_,token)
        c.native=c.native+1;local p=c.screen[token];if p then return p[1],p[2],p[3]end
    end,GetUnitWorldPositionByTarget=function()c.world=c.world+1;return nil end}
    UIParent={GetScreenWidth=function()return 1920 end,GetScreenHeight=function()return 1080 end}
    ConvertWorldToScreen=nil
    local S,_,disk=H.Boot()
    S.NowMs=function()c.now=c.now+1;return c.now end
    S.SafeTraceback=debug.traceback
    S.Scheduler={tasks={},AddHighFrequencyTask=function(self,id,ms,fn)
        self.tasks[id]={ms=ms,fn=fn};return true
    end,RemoveTask=function(self,id)self.tasks[id]=nil;return true end,SetTaskModule=function()return true end}
    dofile('services/rs_screen_projection_v3.lua')
    dofile('features/shared/rs_feature_slice_factory.lua')
    dofile(source)
    local F=S.Features.combat_unit_lines
    assert(F:Initialize());assert(F:Enable());assert(F:AcquireConsumer('hotpath'))
    local P=S.Services.ScreenProjectionV3
    local real=P.ProjectUnitBatch
    P.ProjectUnitBatch=function(self,tokens,options)
        c.batches=c.batches+1
        if c.onBatch then c.onBatch(tokens,options)end
        return real(self,tokens,options)
    end
    return S,F,P,c,disk
end
local function Clamps(fn)
    local old=math.min;local calls=0
    math.min=function(a,b,...)if a==1 then calls=calls+1 end;return old(a,b,...)end
    local ok,err=pcall(fn);math.min=old;assert(ok,err);return calls
end
local function CollapseMath(fn)
    local old=math.max;local calls=0
    math.max=function(a,b,...)if a==4 then calls=calls+1 end;return old(a,b,...)end
    local ok,err=pcall(fn);math.max=old;assert(ok,err);return calls
end
local function SameArray(actual,expected)
    assert(#actual==#expected,'token count '..#actual..' ~= '..#expected)
    for i=1,#expected do assert(actual[i]==expected[i],'token order '..i)end
end
local function Measure()
    local S,F,P,c,disk=Boot()
    F:GetProjection();F:GetRenderProjection();F.Authority:Refresh('warm')
    local native,world,batches=c.native,c.world,c.batches
    local clamps=Clamps(function()for i=1,100 do F:GetRenderProjection()end end)
    local collapse=CollapseMath(function()for i=1,100 do assert(F.Authority:Refresh('count'))end end)
    local refreshNative,refreshWorld,refreshBatches=c.native-native,c.world-world,c.batches-batches
    collectgarbage('collect');collectgarbage('stop')
    local before=collectgarbage('count')
    for i=1,100 do assert(F.Authority:Refresh('allocation'));F:GetRenderProjection()end
    local allocated=collectgarbage('count')-before
    collectgarbage('restart');collectgarbage('collect')
    print(string.format('MEASURE unit-lines-hotpath frames=100 allocated_kb=%.3f color_min=%d collapse_max=%d native=%d world=%d batches=%d',
        allocated,clamps,collapse,refreshNative,refreshWorld,refreshBatches))
    assert(disk.writes==0 and disk.clears==0)
end
-- CPU 由父任务在所有专项停止后串行运行；默认专项只给操作/分配计数，避免并发噪声。
if benchmarkOnly then
    local S,F=Boot()
    for i=1,100 do F.Authority:Refresh('warm');F:GetRenderProjection()end
    local cycles=tonumber(arg[3]) or 10000
    for round=1,3 do
        collectgarbage('collect')
        local started=os.clock()
        for i=1,cycles do F.Authority:Refresh('benchmark');F:GetRenderProjection()end
        print(string.format('BENCH unit-lines-hotpath round=%d cycles=%d seconds=%.6f',round,cycles,os.clock()-started))
    end
    return
end
if measureOnly then Measure();return end

Test('unchanged active styles avoid repeating twelve channel clamps',function()
    local S,F=Boot();F:GetRenderProjection()
    local n=Clamps(function()F:GetRenderProjection();F:GetProjection()end)
    assert(n==0,'unchanged style color clamps='..n)
end)
Test('collapse width is resolved once for the current four-pair batch',function()
    local S,F=Boot()
    local n=CollapseMath(function()assert(F.Authority:Refresh('collapse'))end)
    assert(n==1,'collapse width math='..n)
    assert(#F.Authority.rows==4)
end)
Test('all sixteen enabled topologies keep ordered unique current native reads',function()
    local S,F,P,c=Boot()
    for mask=0,15 do
        local expected,seen={},{}
        for i=1,4 do
            local enabled=math.floor(mask/2^(i-1))%2==1
            F.State[flags[i]]=enabled
            if enabled then
                for _,token in ipairs({from[i],to[i]})do
                    if not seen[token]then seen[token]=true;expected[#expected+1]=token end
                end
            end
        end
        local requested
        c.onBatch=function(tokens)requested=tokens end
        local native,world,batches=c.native,c.world,c.batches
        assert(F.Authority:Refresh('topology'))
        if #expected==0 then assert(requested==nil and c.batches==batches)
        else SameArray(requested,expected);assert(c.batches==batches+1)end
        assert(c.native-native==#expected and c.world-world==#expected)
        local active=0;for i=1,4 do if F.State[flags[i]]then active=active+1 end end
        assert(#F.Authority.rows==active)
    end
end)
Test('batch provider mutation cannot poison next input or its topology',function()
    local S,F,P,c=Boot();local previous
    c.onBatch=function(tokens)
        assert(tokens~=previous,'provider received a prior mutable array')
        previous=tokens
        tokens[1]='provider-mutated';tokens[2]=nil
    end
    F.Authority:Refresh('mutated')
    c.onBatch=function(tokens)
        assert(tokens~=previous)
        SameArray(tokens,{'player','target','targettarget','watchtarget','watchtargettarget'})
    end
    F.Authority:Refresh('recovered');assert(#F.Authority.rows==4)
end)
Test('synchronous nested refresh and config changes preserve each call input',function()
    local S,F,P,c=Boot();local outer,inner,entered
    c.onBatch=function(tokens)
        if not entered then
            entered=true;outer=tokens
            F.State.showFocusTarget=false;F.State.showFocusTargetTarget=false
            assert(F.Authority:Refresh('nested'))
            F.State.showFocusTarget=true;F.State.showFocusTargetTarget=true
        else inner=tokens;SameArray(tokens,{'player','target','targettarget'})end
    end
    assert(F.Authority:Refresh('outer'));assert(outer~=inner)
    SameArray(outer,{'player','target','targettarget','watchtarget','watchtargettarget'})
    assert(#F.Authority.rows==4)
    c.onBatch=nil;assert(F.Authority:Refresh('after_nested'));assert(#F.Authority.rows==4)
end)
Test('provider changes to enabled flags still apply to current row production',function()
    local S,F,P,c=Boot()
    c.onBatch=function()F.State.showFocusTarget=false;F.State.showFocusTargetTarget=false end
    assert(F.Authority:Refresh('config_callback'));assert(#F.Authority.rows==2)
    assert(F.Diagnostics.attemptedPairs==4)
end)
Test('changed target coordinates and disappearance are observed on next batch',function()
    local S,F,P,c=Boot();F.Authority:Refresh('before');local previous=F:GetRenderProjection()
    c.screen.target={1200,200,1};assert(F.Authority:Refresh('switched'))
    assert(F.Authority.rows[1].x2==1200 and previous.rows[1].x2==600)
    c.screen.target=nil;assert(F.Authority:Refresh('gone'))
    assert(#F.Authority.rows==2 and F.Authority.rows[1].pairKey=='focus')
    assert(F.Diagnostics.endpoints.target.visible==false and F.Authority.status=='partial')
end)
Test('point width changes keep the exact collapse rule immediately',function()
    local S,F,P,c=Boot();c.screen.target={208,300,1}
    F.State.showTargetTarget=false;F.State.showFocusTarget=false;F.State.showFocusTargetTarget=false
    F.State.pointSize=4;F.Authority:Refresh('collapsed');assert(#F.Authority.rows==0)
    F.State.pointSize=2;F.Authority:Refresh('visible');assert(#F.Authority.rows==1)
end)
Test('style raw scalars change without stale normalization or snapshot sharing',function()
    local S,F=Boot();local previous=F:GetRenderProjection()
    F.State.colors.target[1]=0.19;F.State.colors.target[2]='0.41';F.State.colors.target[3]=2
    F.State.pairPoints.target=58;F.State.pairSizes.target=8;F.State.opacity=0.31;F.State.refreshMs=7
    local current=F:GetRenderProjection()
    assert(current.colors.target[1]==0.19 and current.colors.target[2]==0.41 and current.colors.target[3]==1)
    assert(current.pairPoints.target==58 and current.pairSizes.target==8 and current.opacity==0.31 and current.refreshMs==7)
    assert(previous.colors.target[1]==1 and previous.pairPoints.target==24)
    current.colors.target[1]=0;current.pairPoints.target=2;current.rows[1].x1=-100
    local public=F:GetProjection();public.colors.target[2]=0
    local nextSnapshot=F:GetRenderProjection()
    assert(nextSnapshot.colors.target[1]==0.19 and nextSnapshot.colors.target[2]==0.41)
    assert(nextSnapshot.pairPoints.target==58 and nextSnapshot.rows[1].x1==200)
    local n=Clamps(function()F:GetRenderProjection()end);assert(n==0,'settled changed styles still clamp='..n)
end)
Test('malformed and replaced color tables preserve original defaults and clamping',function()
    local S,F=Boot();F:GetRenderProjection()
    F.State.colors={target={-1,'bad',0.2},targettarget=false,focus={0/0,math.huge,-math.huge}}
    local p=F:GetRenderProjection()
    assert(p.colors.target[1]==0 and p.colors.target[2]==0.72 and p.colors.target[3]==0.2)
    assert(p.colors.targettarget[1]==0.94 and p.colors.focustarget[3]==1)
    assert(p.colors.focus[1]==math.max(0,math.min(1,0/0)) and p.colors.focus[2]==1 and p.colors.focus[3]==0)
    F.State.colors=nil;local q=F:GetRenderProjection()
    assert(q.colors.target[1]==1 and q.colors.target[2]==0.72 and q.colors.focus[3]==1)
end)
Test('malformed color channels cannot retain unrelated object graphs in preparation',function()
    local S,F=Boot()
    local invalid={payload={}}
    local weak=setmetatable({invalid},{__mode='v'})
    F.State.colors.target[1]=invalid;F:GetRenderProjection()
    F.State.colors.target[1]=nil;invalid=nil
    collectgarbage('collect')
    assert(weak[1]==nil,'non-scalar color source retained by preparation')
end)
Test('last demand release and disable discard active style cache and stop reads',function()
    local S,F,P,c=Boot();F:GetRenderProjection()
    local task=assert(S.Scheduler.tasks.v3_business_unit_lines_refresh)
    assert(F:ReleaseConsumer('hotpath'));local native=c.native;task.fn();assert(c.native==native)
    local cold=Clamps(function()F:GetRenderProjection();F:GetRenderProjection()end)
    assert(cold==24,'idle getters retained a normalized cache: '..cold)
    assert(F:AcquireConsumer('hotpath'));F:GetRenderProjection()
    assert(Clamps(function()F:GetRenderProjection()end)==0)
    assert(F:Disable());assert(S.Scheduler.tasks.v3_business_unit_lines_refresh==nil)
    assert(Clamps(function()F:GetRenderProjection();F:GetRenderProjection()end)==24)
end)
Test('commands retain settings and refresh cadence without changing persistence schema',function()
    local S,F,P,c,disk=Boot();local version=S.P and S.P.version
    assert(F.Commands:SetPairEnabled('focus',false));assert(F.State.showFocusTarget==false)
    assert(F.Commands:SetPairColor('target',0.2,0.3,0.4))
    assert(F.Commands:SetRefreshMs(1));assert(S.Scheduler.tasks.v3_business_unit_lines_refresh.ms==1)
    assert(F:GetRenderProjection().colors.target[1]==0.2)
    assert(F.Commands:SetRefreshMs(60000));assert(S.Scheduler.tasks.v3_business_unit_lines_refresh.ms==60000)
    assert(disk.clears==0 and (not S.P or S.P.version==version))
end)
Measure()
print('UNIT LINES HOTPATH RESULT '..passed..' passed / '..failed..' failed ('.._VERSION..')')
if failed>0 then error('unit-lines hotpath regressions failed: '..failed)end
