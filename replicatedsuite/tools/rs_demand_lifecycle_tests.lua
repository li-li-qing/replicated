------------------------------------------------------------------------
-- Replicated Suite · Demand 事务与失败清理回归
-- 只加载真实 Demand；依赖替身仅提供深拷贝、诊断和可注入的资源失败。
-- 权威边界：消费者快照不等于下游已释放，故障标识必须跨空租约清理存活。
------------------------------------------------------------------------
local passed, failed = 0, 0
local function Test(name, callback)
    local ok, err = xpcall(callback, debug.traceback)
    if ok then passed=passed+1; print('PASS demand-lifecycle '..name)
    else failed=failed+1; print('FAIL demand-lifecycle '..name..': '..tostring(err)) end
end
local function Equal(actual, expected, message)
    assert(actual==expected, (message or 'unexpected value')..': expected '..tostring(expected)..', got '..tostring(actual))
end
local function Copy(value, seen)
    if type(value)~='table' then return value end
    seen=seen or {}; if seen[value] then return seen[value] end
    local out={};seen[value]=out
    for key,item in pairs(value) do out[Copy(key,seen)]=Copy(item,seen) end
    return out
end
local function Boot()
    ReplicatedSuite={Generation=1,Utils={DeepCopy=Copy},SafeTraceback=debug.traceback,
        DiagnosticsManager={Emit=function() end}}
    dofile('core/rs_demand.lua')
    return ReplicatedSuite
end

Test('healthy repeated acquisition and empty clear stay idempotent',function()
    local S=Boot();local calls=0
    local lease=assert(S.Demand:Create({id='probe',reconcile=function() calls=calls+1;return true end}))
    local ok,changed=lease:Clear();Equal(ok,true);Equal(changed,false)
    assert(lease:Acquire('a',{purpose='test'}));local before=calls
    ok,changed=lease:Acquire('a',{purpose='test'});Equal(ok,true);Equal(changed,false);Equal(calls,before)
    assert(lease:Release('a'));Equal(lease:Release('a'),false)
end)

Test('failed reverse reconciliation is retried even with zero consumers',function()
    local S=Boot();local running=false;local quietCalls=0
    local lease=assert(S.Demand:Create({id='probe',
        reconcile=function(_,before,after,context)
            if context.rollback then return false,'injected rollback failure' end
            running=true;return false,'injected start failure'
        end,
        quiesce=function() quietCalls=quietCalls+1;running=false;return true end}))
    Equal(lease:Acquire('a',{}),false);Equal(lease.count,0);Equal(running,true)
    Equal(lease.needsQuiesce,true,'lost failed cleanup evidence')
    assert(lease:Clear('retry'));Equal(running,false);Equal(quietCalls,1);Equal(lease.needsQuiesce,false)
end)

Test('force quiesce failure remains retryable after logical force clear',function()
    local S=Boot();local attempts=0;local running=true
    local lease=assert(S.Demand:Create({id='probe',quiesce=function()
        attempts=attempts+1;if attempts<=2 then return false,'injected quiesce failure' end
        running=false;return true
    end}))
    assert(lease:Acquire('a',{}));Equal(lease:ForceQuiesce('shutdown'),false)
    Equal(lease.count,0);Equal(lease.needsQuiesce,true)
    Equal(S.Demand:ClearAll('retry_failed'),false,'shutdown concealed failed cleanup')
    Equal(lease.needsQuiesce,true);Equal(running,true)
    assert(S.Demand:ClearAll('retry_success'));Equal(running,false);Equal(lease.needsQuiesce,false)
end)

Test('missing quiesce cannot erase a failed rollback',function()
    local S=Boot()
    local lease=assert(S.Demand:Create({id='probe',reconcile=function() return false,'injected failure' end}))
    Equal(lease:Acquire('a',{}),false);Equal(lease.needsQuiesce,true)
    assert(lease:ForceClear());Equal(lease.needsQuiesce,true,'logical clear erased cleanup fault')
    Equal(lease:ForceQuiesce('shutdown'),false);Equal(lease.needsQuiesce,true)
    Equal(S.Demand:ClearAll('shutdown'),false);Equal(lease.needsQuiesce,true)
end)

Test('faulted lease cannot advertise new successful demand before quiesce',function()
    local S=Boot();local breakReconcile=true
    local lease=assert(S.Demand:Create({id='probe',reconcile=function() return not breakReconcile end,
        quiesce=function() return true end}))
    Equal(lease:Acquire('a',{}),false);breakReconcile=false
    Equal(lease:Acquire('b',{}),false);Equal(lease.count,0)
    assert(lease:Clear());assert(lease:Acquire('b',{}));Equal(lease.count,1)
end)

Test('nested acquisition cannot succeed and then vanish on outer rollback',function()
    local S=Boot();local nestedOk,nestedErr
    local lease=assert(S.Demand:Create({id='probe',reconcile=function(self,_,_,context)
        if context.token=='outer' and not context.rollback then
            nestedOk,nestedErr=self:Acquire('inner',{},'nested');return false,'injected outer failure'
        end
        return true
    end}))
    Equal(lease:Acquire('outer',{}),false);Equal(nestedOk,false,'nested mutation was committed')
    assert(tostring(nestedErr):find('progress',1,true));Equal(lease.count,0)
end)

for _,method in ipairs({'Release','Clear','ForceClear','ForceQuiesce'}) do
    Test('nested '..method..' cannot invalidate the active transaction',function()
        local S=Boot();local nestedOk
        local lease=assert(S.Demand:Create({id='probe',reconcile=function(self,_,_,context)
            if context.action=='acquire' then nestedOk=self[method](self,'outer') end
            return true
        end}))
        assert(lease:Acquire('outer',{}));Equal(nestedOk,false,'nested mutation bypassed transaction')
        Equal(lease:Has('outer'),true);Equal(lease.count,1)
    end)
end

Test('duplicate uncommitted token cannot claim success before the outer transaction fails',function()
    local S=Boot();local nestedOk,nestedChanged
    local lease=assert(S.Demand:Create({id='probe',reconcile=function(self,_,_,context)
        if context.action=='acquire' and not context.rollback then
            nestedOk,nestedChanged=self:Acquire('outer',{purpose='test'});return false,'injected outer failure'
        end
        return true
    end}))
    Equal(lease:Acquire('outer',{purpose='test'}),false);Equal(nestedOk,false,'uncommitted duplicate claimed success')
    Equal(lease.count,0);Equal(lease.transitions,1)
end)

Test('previously committed unchanged token stays idempotent during an unrelated failed transaction',function()
    local S=Boot();local nestedOk,nestedChanged
    local lease=assert(S.Demand:Create({id='probe',reconcile=function(self,_,_,context)
        if context.token=='outer' and not context.rollback then
            nestedOk,nestedChanged=self:Acquire('committed',{purpose='test'});return false,'injected outer failure'
        end
        return true
    end}))
    assert(lease:Acquire('committed',{purpose='test'}));Equal(lease:Acquire('outer',{}),false)
    Equal(nestedOk,true);Equal(nestedChanged,false);Equal(lease:Has('committed'),true);Equal(lease.count,1)
end)

Test('duplicate pending options update cannot claim success before rollback',function()
    local S=Boot();local nestedOk
    local lease=assert(S.Demand:Create({id='probe',reconcile=function(self,_,_,context)
        if context.action=='update' and not context.rollback then
            nestedOk=self:Acquire('a',{purpose='pending'});return false,'injected update failure'
        end
        return true
    end}))
    assert(lease:Acquire('a',{purpose='committed'}));Equal(lease:Acquire('a',{purpose='pending'}),false)
    Equal(nestedOk,false,'uncommitted options claimed success');Equal(lease:Get('a').purpose,'committed')
end)

Test('quiesce callback cannot reacquire the lease it is shutting down',function()
    local S=Boot();local nestedOk
    local lease=assert(S.Demand:Create({id='probe',quiesce=function(self)
        nestedOk=self:Acquire('new',{});return true
    end}))
    assert(lease:Acquire('a',{}));assert(lease:ForceQuiesce());Equal(nestedOk,false);Equal(lease.count,0)
    assert(lease:Acquire('new',{}),'successful quiesce retained a busy flag')
end)

Test('successful rollback keeps healthy lease available for retry',function()
    local S=Boot();local failOnce=true
    local lease=assert(S.Demand:Create({id='probe',reconcile=function(_,_,_,context)
        if failOnce and not context.rollback then failOnce=false;return false,'injected start failure' end
        return true
    end}))
    Equal(lease:Acquire('a',{}),false);assert(lease.needsQuiesce~=true)
    assert(lease:Acquire('a',{}));assert(lease:Release('a'))
end)

Test('throwing quiesce callback leaves cleanup evidence and releases its execution guard',function()
    local S=Boot();local failOnce=true
    local lease=assert(S.Demand:Create({id='probe',quiesce=function()
        if failOnce then failOnce=false;error('injected quiesce exception') end
        return true
    end}))
    assert(lease:Acquire('a',{}));Equal(lease:ForceQuiesce(),false);Equal(lease.needsQuiesce,true)
    Equal(lease:Describe().needsQuiesce,true);assert(lease:Clear())
    Equal(lease:Describe().needsQuiesce,false);assert(lease:Acquire('a',{}))
end)

Test('real Healer rollback failure releases roster and aura on a later global clear',function()
    local S=Boot();local rosterHeld,auraHeld,stopCalls=0,0,0
    S.FeatureRuntime={RegisterImplementation=function() return true end}
    S.Services={TeamRosterV3={AcquireConsumer=function() rosterHeld=rosterHeld+1;return true end,
        ReleaseConsumer=function() rosterHeld=rosterHeld-1;return true end}}
    S.Events={SubscribeInternal=function() return true end,UnsubscribeInternal=function() return true end}
    S.Features={HealerAuraBridge={ReadAccurate=function() end,Start=function() auraHeld=auraHeld+1;return true end,
        Stop=function() auraHeld=auraHeld-1;return true end},
        Healer={EnsureStoreLoaded=function() return true end,Roster={},Recommendation={},
            HealthRuntime={running=false,Start=function() return false,'injected start failure' end,
                Stop=function() stopCalls=stopCalls+1;return false,'injected reverse cleanup failure' end}}}
    -- 生产 Healer 依次获取 Team/Aura/事件；逆向 Stop 首步失败时，后续 quiesce 必须独立重试其它释放。
    dofile('features/combat/healer/rs_healer_feature.lua')
    local healer=S.Features.Healer
    Equal(healer:Enable('test'),false);Equal(healer.Demand.count,0);Equal(healer.Demand.needsQuiesce,true)
    Equal(rosterHeld,1);Equal(auraHeld,1);Equal(stopCalls,1)
    assert(S.Demand:ClearAll('retry_shutdown'));Equal(rosterHeld,0);Equal(auraHeld,0)
    Equal(healer.Demand.needsQuiesce,false)
end)

print('DEMAND LIFECYCLE RESULT '..passed..' passed / '..failed..' failed (Lua '.._VERSION..')')
if failed>0 then os.exit(1) end
