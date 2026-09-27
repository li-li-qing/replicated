local ROOT = './'
local function eq(a, b, message)
    if a ~= b then error((message or 'assert') .. ': expected=' .. tostring(b) .. ' actual=' .. tostring(a), 2) end
end
local function truth(value, message)
    if value ~= true then error((message or 'assert true') .. ': ' .. tostring(value), 2) end
end

ReplicatedSuite = {
    RSUI = {},
    UIV3 = {},
    SafeTraceback = debug.traceback,
    Generation = 1,
}
local S = ReplicatedSuite

S.Events = { listeners = {} }
function S.Events:SubscribeInternal(topic, owner, callback)
    self.listeners[topic] = self.listeners[topic] or {}
    self.listeners[topic][#self.listeners[topic] + 1] = { owner = owner, callback = callback }
    return true
end
function S.Events:Publish(topic, ...)
    local snapshot = {}
    for _, row in ipairs(self.listeners[topic] or {}) do snapshot[#snapshot + 1] = row end
    for _, row in ipairs(snapshot) do row.callback(row.owner, ...) end
    return true
end

local runtimeEnabled = true
S.FeatureRuntime = { LifecycleTopic = 'v3.feature.lifecycle' }
function S.FeatureRuntime:IsEnabled(id) return id == 'life_trade' and runtimeEnabled == true end

local held = {}
local acquireCount, releaseCount = 0, 0
local demand = {}
function demand:Has(token) return held[token] == true end

local feature = { Id = 'life_trade', Demand = demand }
function feature:AcquireConsumer(token)
    acquireCount = acquireCount + 1
    held[token] = true
    return true
end
function feature:ReleaseConsumer(token)
    if held[token] ~= true then return false, 'consumer not held' end
    releaseCount = releaseCount + 1
    held[token] = nil
    return true
end

-- PageHost has no load-time Native dependency; this executes only the shared
-- Presentation lifecycle contract under a strict Demand model.
dofile(ROOT .. 'presentation/v3/shell/rs_v3_page_host.lua')
local Host = S.UIV3.PageHost
truth(type(Host) == 'table', 'PageHost loaded')
eq(Host.featureConsumerLifecycleContractVersion, 1, 'contract version')

local refreshCount = 0
local page = { route = 'life.trade', consumerHeld = false }
function page:Refresh() refreshCount = refreshCount + 1; return true end
local binding = {
    feature = feature,
    featureId = 'life_trade',
    token = 'page:trade',
    refresh = function(p) return p:Refresh() end,
}

truth(Host:BindFeatureConsumerLifecycle(page, binding), 'bind lifecycle')
truth(Host:SyncFeatureConsumer(page, binding, 'activate'), 'initial acquire')
eq(acquireCount, 1, 'initial acquire count')
truth(held['page:trade'], 'token held after activation')
truth(page.consumerHeld, 'page mirrors held token')

-- FeatureRuntime/Feature Disable owns Demand:Clear and publishes lifecycle only
-- afterwards. Simulate that exact ordering; the page must NOT double-release.
held = {}
runtimeEnabled = false
truth(S.Events:Publish('v3.feature.lifecycle', 'life_trade', 'disabled', 'profile_apply'), 'publish disabled')
eq(releaseCount, 0, 'disable callback never double releases cleared Demand')
eq(page.consumerHeld, false, 'page stale lease flag cleared')
truth(Host:ReleaseFeatureConsumer(page, binding, 'deactivate_while_disabled'), 'disabled page release is idempotent')
eq(releaseCount, 0, 'disabled deactivation still does not double release')

-- Re-enable while page remains active. The lifecycle edge must reacquire the
-- same token automatically; no page activation or manual toggle is required.
runtimeEnabled = true
truth(S.Events:Publish('v3.feature.lifecycle', 'life_trade', 'enabled', 'profile_apply'), 'publish enabled')
eq(acquireCount, 2, 're-enable reacquires page token')
truth(held['page:trade'], 'token restored after profile enable')
truth(page.consumerHeld, 'page lease restored')

-- Unrelated feature lifecycle events cannot perturb this page.
truth(S.Events:Publish('v3.feature.lifecycle', 'life_bonds', 'disabled', 'profile_apply'), 'publish unrelated')
eq(acquireCount, 2, 'unrelated lifecycle no acquire')
eq(releaseCount, 0, 'unrelated lifecycle no release')

truth(Host:ReleaseFeatureConsumer(page, binding, 'page_deactivated'), 'normal release')
eq(releaseCount, 1, 'normal release exactly once')
eq(page.consumerHeld, false, 'page release mirrors token')

print('FEATURE_CONSUMER_LIFECYCLE_RUNTIME_TEST PASS')
