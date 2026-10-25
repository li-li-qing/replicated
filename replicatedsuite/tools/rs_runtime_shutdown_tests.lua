-- Replicated Suite · Runtime 关闭失败传播回归
-- 作者：Replicated
-- QQ群：1104129461
-- 执行真实 Runtime / Demand / Events / Scheduler，Native 和外壳仅作宿主。
-- 共享服务释放失败仍须完成后续静默，但不能向热重载调用者报告关闭成功；不接触玩家存档。
local function Copy(value)
    if type(value) ~= 'table' then return value end
    local out = {}; for key, item in pairs(value) do out[key] = Copy(item) end; return out
end
local function Boot()
    local S = { Generation = 1, SafeTraceback = debug.traceback, Utils = { DeepCopy = Copy },
        Constants = { Refresh = {} }, SafeChat = function() end, WarnOnce = function() end,
        PhysicalId = function(id) return id end, NowMs = function() return 0 end }
    ReplicatedSuite = S
    local function Host()
        return { SetHandler = function() return true end, Show = function() return true end,
            SetExtent = function() return true end, AddAnchor = function() return true end }
    end
    S.NativeObjectFactory = { CreateWindow = Host, CreateEmptyWidget = Host }
    S.Api = { Validate = function() return true end }
    S.AppState = { EnsureLoaded = function() return true end }
    S.Layout = { Invalidate = function() end, PrimeCurrentSignature = function() end }
    S.Persistence = { Flush = function() return true end }
    S.FeatureRuntime = { EnableDefaults = function() return true end, DisableAll = function() return true end }
    S.UIHostManager = { IsRegistered = function(_, id) return id == 'v3' end, Ensure = function() return {} end,
        RefreshData = function() return true end, ApplyResponsiveLayout = function() return true end,
        HideAll = function(self) self.hidden = true end }
    dofile('core/rs_demand.lua'); dofile('core/rs_events.lua'); dofile('core/rs_scheduler.lua')
    dofile('core/rs_refresh_coordinator.lua'); dofile('core/rs_runtime.lua')
    assert(S.Ready and S.Runtime.started, S.BootError)
    return S
end
local S = Boot()
local stopped = 0
local lease = assert(S.Demand:Create({ id = 'service:shutdown_probe',
    reconcile = function(_, _, after) if after.count == 0 then return false, 'release rejected' end; return true end,
    quiesce = function() stopped = stopped + 1; return false, 'native cleanup rejected' end }))
assert(lease:Acquire('view'))
local ok, err = S.Runtime:Stop()
assert(stopped == 1 and not S.Ready and not S.Runtime.started)
assert(not S.Events.running and not S.Scheduler.running and next(S.Scheduler.tasks) == nil and S.UIHostManager.hidden)
assert(ok == false and type(err) == 'string', 'Runtime Stop concealed failed shared-service cleanup')
local healthy = Boot(); assert(healthy.Runtime:Stop()); assert(healthy.Runtime:Stop())
print('RUNTIME SHUTDOWN RESULT 2 passed / 0 failed (' .. _VERSION .. ')')
