------------------------------------------------------------------------
-- Replicated Suite V3 - Combat Event Bus / Combat Facts Foundation
--
-- One Native combat-event Authority for independent consumers such as
-- DeathReview, DPS, Healer combat reactions and Boss mechanics.
--
-- Transport contract:
--   * private hidden widget COMBAT_MSG: reliable SELF-endpoint safety slice.
--   * global UI/UIParent COMBAT_MSG: enabled only when any consumer asks for
--     scope="all"; live RU evidence says team-only rows may exist only here.
--   * global route filters SELF rows, so private/global slices stay disjoint.
--   * UI + UIParent duplicates are paired/deduped only across different hosts;
--     repeated identical rows from the same host are never suppressed.
--
-- Fact contract:
--   * native payload normalization only (kind/category/amount/raw fields).
--   * no faction, PVP/PVE, friendly/opponent, ranking or healer conclusions.
--   * raw unit id binds source/target only through UnitIdentityV3 verified name.
--
-- No Tick / OnUpdate. Native handlers exist only while consumers are leased,
-- except on client builds that lack explicit release APIs; those fall back to
-- hidden parked compatibility mode with generation/runtime guards.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
S.Services = S.Services or {}

local C = {
    Id = "v3.combat_event_bus",
    version = 6,
    running = false,
    privateHost = nil,
    privateHandlerAttached = false,
    privateEvents = {},
    privateParked = false,
    globalHandlers = {},
    globalActive = false,
    globalParkedHosts = 0,
    subscribers = {},
    subscriberOrder = {},
    subscriberCount = 0,
    subscriberSerial = 0,
    subscriberTombstones = 0,
    dispatchDepth = 0,
    sequence = 0,
    received = 0,
    delivered = 0,
    callbackErrors = 0,
    unknownKinds = 0,
    privateRows = 0,
    globalRows = 0,
    globalSelfFiltered = 0,
    globalNoIdentitySuppressed = 0, -- historical counter name; now counts cold-path journaled rows
    globalCrossHostDuplicates = 0,
    globalCrossHostEvicted = 0,
    factMutationErrors = 0,
    journal = {},
    journalHead = 1,
    journalMax = 256,
    journalTtlMs = 1500,
    journalQueued = 0,
    journalReplayed = 0,
    journalDropped = 0,
    journalDroppedCurrent = 0,
    globalHostCoverage = { UI = false, UIParent = false },
    startFailures = 0,
    stopFailures = 0,
    forcedInert = 0,
    releaseApiMissing = 0,
    releaseCallFailures = 0,
    scopeFiltered = 0,
    lastPlayerRefreshAt = -1,
    pairDedup = {},
    pairOrder = {},
    pairHead = 1,
    pairSerial = 0,
    pairPendingCount = 0,
    pairMax = 256,
    pairTtlMs = 50,
}
C.presentationBoundary = "service_only"
S.Services.CombatEventBusV3 = C

local U = S.Utils
local Identity = S.Services.UnitIdentityV3
local function NowMs() return math.max(0, tonumber(S.NowMs and S.NowMs()) or 0) end
local function Trim(value) return U and U.Trim and U.Trim(value) or (tostring(value or ""):match("^%s*(.-)%s*$") or "") end

local function Emit(level, code, message, context)
    local diag = S.DiagnosticsManager
    if type(diag) == "table" and type(diag.Emit) == "function" then
        diag:Emit(level, "combat_bus", code, message, context)
    end
end

-- Combat rows can arrive at hundreds per second. Never let a misbehaving
-- consumer turn the hot path into hundreds of log writes per second; counters
-- stay exact while the log row is rate limited.
local function EmitRateLimited(level, code, message, context)
    local diag = S.DiagnosticsManager
    if type(diag) == "table" and type(diag.RateLimited) == "function" then
        return diag:RateLimited(level, "combat_bus", code, 3000, message, context)
    end
    return Emit(level, code, message, context)
end

local EVENT_TYPE_CACHE, EVENT_TYPE_CACHE_COUNT, EVENT_TYPE_CACHE_MAX = {}, 0, 128
local function MatchesQualified(upper, token)
    if upper == token then return true end
    if #upper <= #token then return false end
    local suffix = string.sub(upper, -#token - 1)
    return suffix == "." .. token or suffix == ":" .. token or suffix == "/" .. token or suffix == "_" .. token
end

function C:DescribeEventType(eventType)
    local raw = tostring(eventType or "")
    local cached = EVENT_TYPE_CACHE[raw]
    if cached ~= nil then return cached end
    local upper = string.upper(Trim(raw))
    local row = { kind = "other", category = "other", environmental = false, auraType = nil }
    -- Aura facts are intentionally conservative: only explicit apply/remove
    -- event types are normalized. Unknown BUFF/DEBUFF-like strings stay other.
    if string.find(upper, "DEBUFF_APPLIED", 1, true) ~= nil or string.find(upper, "DEBUFF_ADDED", 1, true) ~= nil then
        row.kind, row.category, row.auraType = "aura_apply", "aura", "debuff"
    elseif string.find(upper, "BUFF_APPLIED", 1, true) ~= nil or string.find(upper, "BUFF_ADDED", 1, true) ~= nil then
        row.kind, row.category, row.auraType = "aura_apply", "aura", "buff"
    elseif string.find(upper, "DEBUFF_REMOVED", 1, true) ~= nil or string.find(upper, "DEBUFF_FADED", 1, true) ~= nil then
        row.kind, row.category, row.auraType = "aura_remove", "aura", "debuff"
    elseif string.find(upper, "BUFF_REMOVED", 1, true) ~= nil or string.find(upper, "BUFF_FADED", 1, true) ~= nil then
        row.kind, row.category, row.auraType = "aura_remove", "aura", "buff"
    elseif string.find(upper, "MELEE_DAMAGE", 1, true) ~= nil then
        row.kind, row.category = "melee_damage", "damage"
    elseif string.find(upper, "SPELL_DAMAGE", 1, true) ~= nil then
        row.kind, row.category = "spell_damage", "damage"
    elseif MatchesQualified(upper, "ENVIRONMENTAL_DAMAGE") or MatchesQualified(upper, "ENVIRONMENTAL_DMANAGE") then
        row.kind, row.category, row.environmental = "environmental_damage", "damage", true
    elseif string.find(upper, "SPELL_HEALED", 1, true) ~= nil or string.find(upper, "HEALED", 1, true) ~= nil then
        row.kind, row.category = "heal", "heal"
    elseif string.find(upper, "MISSED", 1, true) ~= nil then
        row.kind, row.category = "miss", "miss"
    elseif string.find(upper, "DEAD", 1, true) ~= nil then
        row.kind, row.category = "death", "death"
    end
    if EVENT_TYPE_CACHE_COUNT < EVENT_TYPE_CACHE_MAX then
        EVENT_TYPE_CACHE[raw] = row
        EVENT_TYPE_CACHE_COUNT = EVENT_TYPE_CACHE_COUNT + 1
    end
    return row
end

function C:ParseAmount(eventType, abilityId, damageType, effectType)
    local descriptor = self:DescribeEventType(eventType)
    if descriptor.kind == "melee_damage" then return math.abs(tonumber(abilityId) or 0) end
    if descriptor.kind == "spell_damage" or descriptor.kind == "heal" then return math.abs(tonumber(effectType) or 0) end
    if descriptor.kind == "environmental_damage" then return math.abs(tonumber(damageType) or 0) end
    return 0
end

local function NormalizeDemandOptions(options)
    options = type(options) == "table" and options or {}
    local scope = tostring(options.scope or "self"):lower()
    if scope ~= "all" then scope = "self" end
    return { scope = scope }
end

local function NeedsAll(snapshot)
    snapshot = type(snapshot) == "table" and snapshot or {}
    local consumers = type(snapshot.consumers) == "table" and snapshot.consumers or snapshot.consumerOptions
    for _, options in pairs(type(consumers) == "table" and consumers or {}) do
        if type(options) == "table" and options.scope == "all" then return true end
    end
    return false
end

function C:_ReleasePrivateHost()
    local host = self.privateHost
    if host == nil then return true end
    local errors, remaining = {}, {}
    local retainedEvents, retainedHandler = false, false
    for eventName in pairs(self.privateEvents) do
        if type(host.UnregisterEvent) == "function" then
            local ok, result = pcall(host.UnregisterEvent, host, eventName)
            if ok ~= true or result == false then
                remaining[eventName] = true
                errors[#errors + 1] = "UnregisterEvent(" .. tostring(eventName) .. ")=" .. tostring(ok and result or "error")
            end
        else
            -- Case B: this RU build simply does not expose the release API.
            -- That is a capability gap, NOT a failed business transaction.
            -- Keep the lease-local host parked and hidden; callbacks stay inert
            -- through the runtime/generation guard. Feature shutdown must not
            -- report failure here, and the user's action must not be blocked.
            remaining[eventName] = true
            retainedEvents = true
        end
    end
    self.privateEvents = remaining
    if self.privateHandlerAttached == true then
        if type(host.ReleaseHandler) == "function" then
            local ok, result = pcall(host.ReleaseHandler, host, "OnEvent")
            if ok == true and result ~= false then
                self.privateHandlerAttached = false
            else
                errors[#errors + 1] = "ReleaseHandler=" .. tostring(ok and result or "error")
            end
        else
            retainedHandler = true
        end
    end
    if type(host.Show) == "function" then pcall(function() host:Show(false) end) end
    -- RU exposes no project-verified DestroyWidget. Keep the generation-local
    -- native host hidden and reuse it on the next 0->1 Demand transition;
    -- recreating the same physical id inside one generation would be rejected.
    self.privateParked = retainedEvents or retainedHandler
    if retainedEvents == true or retainedHandler == true then
        self.releaseApiMissing = self.releaseApiMissing + 1
    end
    if #errors > 0 then
        self.releaseCallFailures = self.releaseCallFailures + #errors
    end
    if self.privateParked == true and S.DiagnosticsManager ~= nil and type(S.DiagnosticsManager.WarningRateLimited) == "function" then
        S.DiagnosticsManager:WarningRateLimited("combat_event_bus_v3", "COMBAT_EVENT_BUS_PRIVATE_HOST_RETAINED", 3000,
            "战斗事件总线释放时缺少原生反注册接口，已转为隐藏停放兼容模式。", {
                retainedEvents = retainedEvents == true,
                retainedHandler = retainedHandler == true,
            })
    end
    if #errors > 0 then return false, table.concat(errors, ";") end
    return true
end

function C:_StartPrivateHost()
    local factory = S.NativeObjectFactory
    if type(factory) ~= "table" or type(factory.CreateWindow) ~= "function" then return false, "NativeObjectFactory unavailable" end
    local host = self.privateHost
    if host == nil then
        local createErr
        host, createErr = factory:CreateWindow(S.PhysicalId("combat_event_bus"), "UIParent", "")
        if host == nil then return false, createErr or "combat event host create failed" end
        self.privateHost = host
    end
    if type(host.SetHandler) ~= "function" or type(host.RegisterEvent) ~= "function" then
        if type(host.Show) == "function" then pcall(function() host:Show(false) end) end
        return false, "combat event host methods unavailable"
    end
    if type(host.SetExtent) == "function" then pcall(function() host:SetExtent(1, 1) end) end
    if type(host.EnablePick) == "function" then pcall(function() host:EnablePick(false) end) end
    if self.privateHandlerAttached ~= true then
        local generation = S.Generation
        local ok, result = pcall(host.SetHandler, host, "OnEvent", function(_, eventName,
            a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13, a14, a15)
            if C:_IsCurrentGeneration(generation) ~= true or C.running ~= true then return end
            if eventName == "COMBAT_MSG" then
                C.privateRows = C.privateRows + 1
                C:_OnCombatRaw("private", a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13, a14, a15)
            elseif eventName == "UNIT_DEAD_NOTICE" then
                C:_OnDeathNotice(a1, a2, a3, a4, a5)
            end
        end)
        if ok ~= true or result == false then
            if type(host.Show) == "function" then pcall(function() host:Show(false) end) end
            return false, tostring(ok and "OnEvent returned false" or result)
        end
        self.privateHandlerAttached = true
    end
    for _, eventName in ipairs({ "COMBAT_MSG", "UNIT_DEAD_NOTICE" }) do
        if self.privateEvents[eventName] ~= true then
            local registerOk, registerResult = pcall(function() return host:RegisterEvent(eventName) end)
            if registerOk ~= true or registerResult == false then
                return false, eventName .. " registration failed: " .. tostring(registerOk and "returned false" or registerResult)
            end
            self.privateEvents[eventName] = true
        end
    end
    self.privateParked = false
    return true
end

local function EventCapability(hostLabel, action)
    return tostring(hostLabel) .. ":" .. tostring(action)
end

function C:_ReleaseGlobalBridge()
    local errors, remaining = {}, {}
    local retainedLabels = {}
    for label, row in pairs(self.globalHandlers) do
        local host, handler = row.host, row.handler
        local released, releaseErr, retained = false, nil, false
        if host ~= nil and handler ~= nil and S.Api ~= nil then
            local cap = EventCapability(label, "ReleaseEventHandler")
            if S.Api:IsCapabilityAllowed(cap) == true then
                released, releaseErr = S.Api:Action(host, "ReleaseEventHandler", row.eventConstant, handler)
            elseif type(host.ReleaseEventHandler) == "function" then
                local ok, result = pcall(host.ReleaseEventHandler, host, row.eventConstant, handler)
                released = ok == true and result ~= false
                if released ~= true then releaseErr = ok and "ReleaseEventHandler returned false" or tostring(result) end
            else
                -- Case B: the build registers a global COMBAT_MSG bridge but
                -- exposes no way to release it. Park the inert handler instead
                -- of failing the caller's feature toggle.
                retained = true
            end
        elseif host ~= nil and handler ~= nil then
            retained = true
        else
            releaseErr = "global handler unavailable"
        end
        if released ~= true and retained ~= true then
            remaining[label] = row
            errors[#errors + 1] = tostring(label) .. "=" .. tostring(releaseErr or "release failed")
        elseif retained == true then
            remaining[label] = row
            retainedLabels[#retainedLabels + 1] = tostring(label)
        end
    end
    self.globalHandlers = remaining
    self.globalActive = false
    self.globalParkedHosts = #retainedLabels
    self.globalHostCoverage = { UI = remaining.UI ~= nil, UIParent = remaining.UIParent ~= nil }
    self.pairDedup, self.pairOrder, self.pairHead, self.pairPendingCount = {}, {}, 1, 0
    self.journal, self.journalHead = {}, 1
    self.journalDroppedCurrent = 0
    self.releaseApiMissing = self.releaseApiMissing + #retainedLabels
    self.releaseCallFailures = self.releaseCallFailures + #errors
    if #retainedLabels > 0 and S.DiagnosticsManager ~= nil and type(S.DiagnosticsManager.WarningRateLimited) == "function" then
        S.DiagnosticsManager:WarningRateLimited("combat_event_bus_v3", "COMBAT_EVENT_BUS_GLOBAL_BRIDGE_RETAINED", 3000,
            "战斗事件总线全局桥释放时缺少 ReleaseEventHandler，已转为隐藏停放兼容模式。", {
                retained = table.concat(retainedLabels, ","),
            })
    end
    if #errors > 0 then return false, table.concat(errors, ";") end
    return true
end

function C:_RegisterGlobalHost(label, host, eventConstant)
    if host == nil or S.Api == nil then return false, "host unavailable" end
    local capability = EventCapability(label, "SetEventHandler")
    if S.Api:IsCapabilityAllowed(capability) ~= true then return false, "capability unavailable" end
    local generation = S.Generation
    local handler = function(a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13, a14, a15)
        if C:_IsCurrentGeneration(generation) ~= true or C.running ~= true or C.globalActive ~= true then return end
        C:_OnGlobalCombat(label, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13, a14, a15)
    end
    local ok, result, err = S.Api:Call(host, "SetEventHandler", eventConstant, handler)
    if ok ~= true or result == false then return false, err or "SetEventHandler returned false" end
    self.globalHandlers[label] = { host = host, handler = handler, eventConstant = eventConstant }
    return true
end

function C:_StartGlobalBridge()
    if Identity ~= nil and type(Identity.RefreshPlayerIdentity) == "function" then Identity:RefreshPlayerIdentity(true) end
    local eventConstant = UIEVENT_TYPE ~= nil and UIEVENT_TYPE.COMBAT_MSG or "COMBAT_MSG"
    local wasActive = self.globalActive == true
    if wasActive ~= true then
        self.journal, self.journalHead = {}, 1
        self.journalDroppedCurrent = 0
    end
    local successCount, errors = 0, {}
    if self.globalHandlers.UI ~= nil then
        successCount = successCount + 1
    elseif UI ~= nil then
        local ok, err = self:_RegisterGlobalHost("UI", UI, eventConstant)
        if ok then successCount = successCount + 1 else errors[#errors + 1] = "UI=" .. tostring(err) end
    end
    if self.globalHandlers.UIParent ~= nil then
        successCount = successCount + 1
    elseif UIParent ~= nil then
        local ok, err = self:_RegisterGlobalHost("UIParent", UIParent, eventConstant)
        if ok then successCount = successCount + 1 else errors[#errors + 1] = "UIParent=" .. tostring(err) end
    end
    self.globalHostCoverage = { UI = self.globalHandlers.UI ~= nil, UIParent = self.globalHandlers.UIParent ~= nil }
    if successCount <= 0 then
        self:_ReleaseGlobalBridge()
        return false, "global COMBAT_MSG unavailable: " .. table.concat(errors, ";")
    end
    self.globalActive = true
    self.globalParkedHosts = 0
    return true
end

function C:_Start()
    if self.running == true then return self:_StartPrivateHost() end
    local ok, err = self:_StartPrivateHost()
    if ok ~= true then self.startFailures = self.startFailures + 1; return false, err end
    self.running = true
    if S.Events == nil or type(S.Events.Subscribe) ~= "function" then
        self.running = false
        self:_ReleasePrivateHost()
        self.startFailures = self.startFailures + 1
        return false, "core event bus unavailable"
    end
    local subscribed = S.Events:Subscribe("ENTERED_WORLD", self, function()
        if Identity ~= nil and type(Identity.RefreshPlayerIdentity) == "function" then
            Identity:RefreshPlayerIdentity(true)
            if type(Identity.IsPlayerIdentityReady) == "function" and Identity:IsPlayerIdentityReady() == true then C:_FlushPreIdentityJournal(NowMs()) end
        end
    end)
    if subscribed ~= true then
        self.running = false
        self:_ReleasePrivateHost()
        self.startFailures = self.startFailures + 1
        return false, "ENTERED_WORLD subscribe failed"
    end
    return true
end

function C:_Stop()
    local globalOk, globalErr = self:_ReleaseGlobalBridge()
    if S.Events ~= nil and type(S.Events.UnsubscribeOwner) == "function" then S.Events:UnsubscribeOwner(self) end
    local privateOk, privateErr = self:_ReleasePrivateHost()
    if globalOk ~= true then self.stopFailures = self.stopFailures + 1; return false, globalErr end
    if privateOk ~= true then self.stopFailures = self.stopFailures + 1; return false, privateErr end
    self.running = false
    return true
end

-- Force the bus inert without pretending the native release succeeded.
--
-- Demand may fall back to ForceQuiesce when a normal Clear fails (for example
-- because a release API exists but returned false). In that path the consumer
-- projection is dropped regardless, so callbacks MUST stop doing business work
-- even though the native host could not be detached. `running`/`globalActive`
-- are the lease-independent guards the native closures check first.
function C:_MarkInert()
    self.forcedInert = self.forcedInert + 1
    self.running = false
    self.globalActive = false
    self.globalHostCoverage = { UI = false, UIParent = false }
    self.pairDedup, self.pairOrder, self.pairHead, self.pairPendingCount = {}, {}, 1, 0
    self.journal, self.journalHead = {}, 1
    self.journalDroppedCurrent = 0
    return true
end

-- Generation guard helper used by both transports. A stale generation means a
-- previous addon load still owns the native handler; it must never dispatch.
function C:_IsCurrentGeneration(generation)
    return tonumber(S.Generation) == tonumber(generation)
end

local function TransportIsPrivate(transport)
    transport = tostring(transport or "")
    return transport == "private" or transport:sub(1, 8) == "private:" or transport == "death_notice"
end

-- Scope is part of the subscribe contract, not only a transport hint:
--   * scope=self  -> private slice only (reliable SELF endpoint facts)
--   * scope=all   -> private + global slices
-- Without this filter a low-cost self-scope consumer would pay for every
-- all-scope row as soon as any DPS-like consumer enables the global bridge.
-- Exposed as a method so the acceptance harness can assert it without
-- registering a native host.
function C:AcceptsTransport(options, transport)
    if type(options) ~= "table" then return true end
    if options.scope == "all" then return true end
    if TransportIsPrivate(transport) then return true end
    return false
end
local AcceptsTransport = function(options, transport) return C:AcceptsTransport(options, transport) end

local function BuildSignature(unitId, eventType, sourceName, targetName, abilityId, abilityName, damageType, effectType, isActive, more, more2, more3, more4, more5)
    local sep = "\31"
    return tostring(unitId or "") .. sep .. tostring(eventType or "") .. sep
        .. tostring(sourceName or "") .. sep .. tostring(targetName or "") .. sep
        .. tostring(abilityId or "") .. sep .. tostring(abilityName or "") .. sep
        .. tostring(damageType or "") .. sep .. tostring(effectType or "") .. sep
        .. tostring(isActive or "") .. sep .. tostring(more or "") .. sep
        .. tostring(more2 or "") .. sep .. tostring(more3 or "") .. sep
        .. tostring(more4 or "") .. sep .. tostring(more5 or "")
end

local function CompactPairOrder(bus)
    if bus.pairHead <= 256 or bus.pairHead <= (#bus.pairOrder / 2) then return end
    local compact = {}
    for index = bus.pairHead, #bus.pairOrder do
        local token = bus.pairOrder[index]
        if token ~= nil and token.active == true then compact[#compact + 1] = token end
    end
    bus.pairOrder, bus.pairHead = compact, 1
end

local function AdvancePairHead(bus)
    local head = math.max(1, tonumber(bus.pairHead) or 1)
    while head <= #bus.pairOrder do
        local token = bus.pairOrder[head]
        if token ~= nil and token.active == true then break end
        head = head + 1
    end
    bus.pairHead = head
    if head > #bus.pairOrder then
        bus.pairOrder, bus.pairHead = {}, 1
        return
    end
    CompactPairOrder(bus)
end

local function QueueHasActive(queue)
    if type(queue) ~= "table" then return false end
    local head = math.max(1, tonumber(queue.head) or 1)
    for index = head, #queue do
        local token = queue[index]
        if token ~= nil and token.active == true then return true end
    end
    return false
end

local function EntryHasActive(entry)
    if type(entry) ~= "table" or type(entry.hosts) ~= "table" then return false end
    for _, queue in pairs(entry.hosts) do if QueueHasActive(queue) then return true end end
    return false
end

local function PopMatchingToken(bus, queue, now)
    if type(queue) ~= "table" then return nil end
    local ttl = math.max(1, tonumber(bus.pairTtlMs) or 50)
    local head = math.max(1, tonumber(queue.head) or 1)
    while head <= #queue do
        local token = queue[head]
        head = head + 1
        queue.head = head
        if token ~= nil and token.active == true then
            local age = now - (tonumber(token.at) or 0)
            if age <= ttl and age >= 0 then
                token.active = false
                bus.pairPendingCount = math.max(0, (tonumber(bus.pairPendingCount) or 0) - 1)
                return token
            end
            token.active = false
            bus.pairPendingCount = math.max(0, (tonumber(bus.pairPendingCount) or 0) - 1)
            bus.globalCrossHostEvicted = bus.globalCrossHostEvicted + 1
        end
    end
    return nil
end

local function ExpireOldestPairTokens(bus, now)
    local ttl = math.max(1, tonumber(bus.pairTtlMs) or 50)
    local head = math.max(1, tonumber(bus.pairHead) or 1)
    while head <= #bus.pairOrder do
        local token = bus.pairOrder[head]
        if token == nil or token.active ~= true then
            head = head + 1
        else
            local age = now - (tonumber(token.at) or 0)
            if age <= ttl then break end
            token.active = false
            bus.pairPendingCount = math.max(0, (tonumber(bus.pairPendingCount) or 0) - 1)
            bus.globalCrossHostEvicted = bus.globalCrossHostEvicted + 1
            local entry = bus.pairDedup[token.key]
            if EntryHasActive(entry) ~= true then bus.pairDedup[token.key] = nil end
            head = head + 1
        end
    end
    bus.pairHead = head
    AdvancePairHead(bus)
end

local function EvictOldestPairToken(bus)
    while bus.pairHead <= #bus.pairOrder do
        local token = bus.pairOrder[bus.pairHead]
        bus.pairHead = bus.pairHead + 1
        if token ~= nil and token.active == true then
            token.active = false
            bus.pairPendingCount = math.max(0, (tonumber(bus.pairPendingCount) or 0) - 1)
            bus.globalCrossHostEvicted = bus.globalCrossHostEvicted + 1
            local entry = bus.pairDedup[token.key]
            if EntryHasActive(entry) ~= true then bus.pairDedup[token.key] = nil end
            AdvancePairHead(bus)
            return true
        end
    end
    CompactPairOrder(bus)
    return false
end

function C:_IsCrossHostDuplicate(hostLabel, signature, now)
    hostLabel = tostring(hostLabel or "")
    now = tonumber(now) or NowMs()
    ExpireOldestPairTokens(self, now)
    local entry = self.pairDedup[signature]
    if type(entry) ~= "table" then
        entry = { hosts = {} }
        self.pairDedup[signature] = entry
    end

    -- Pair one logical row with exactly one occurrence from another host. The
    -- old single-slot map lost multiplicity: UI,UI,UIParent,UIParent could leak
    -- the fourth row as a duplicate. Per-host FIFO tokens preserve same-host
    -- repeated hits while still deduping each mirrored host occurrence 1:1.
    for otherHost, queue in pairs(entry.hosts) do
        if otherHost ~= hostLabel then
            local token = PopMatchingToken(self, queue, now)
            if token ~= nil then
                self.globalCrossHostDuplicates = self.globalCrossHostDuplicates + 1
                if EntryHasActive(entry) ~= true then self.pairDedup[signature] = nil end
                AdvancePairHead(self)
                return true
            end
        end
    end

    while (tonumber(self.pairPendingCount) or 0) >= self.pairMax do
        if EvictOldestPairToken(self) ~= true then break end
    end
    self.pairSerial = self.pairSerial + 1
    local token = { key = signature, host = hostLabel, at = now, serial = self.pairSerial, active = true }
    local queue = entry.hosts[hostLabel]
    if type(queue) ~= "table" then queue = { head = 1 }; entry.hosts[hostLabel] = queue end
    queue[#queue + 1] = token
    self.pairOrder[#self.pairOrder + 1] = token
    self.pairPendingCount = (tonumber(self.pairPendingCount) or 0) + 1
    CompactPairOrder(self)
    return false
end

local function JournalActiveCount(bus)
    return math.max(0, #bus.journal - (tonumber(bus.journalHead) or 1) + 1)
end

function C:_DropExpiredJournal(now)
    now = tonumber(now) or NowMs()
    local head = math.max(1, tonumber(self.journalHead) or 1)
    while head <= #self.journal do
        local row = self.journal[head]
        if row ~= nil and now - (tonumber(row.at) or 0) <= self.journalTtlMs then break end
        head = head + 1
        self.journalDropped = self.journalDropped + 1
        self.journalDroppedCurrent = self.journalDroppedCurrent + 1
    end
    self.journalHead = head
end

function C:_JournalGlobal(hostLabel, now, ...)
    self:_DropExpiredJournal(now)
    while JournalActiveCount(self) >= self.journalMax do
        self.journalHead = self.journalHead + 1
        self.journalDropped = self.journalDropped + 1
        self.journalDroppedCurrent = self.journalDroppedCurrent + 1
    end
    self.journal[#self.journal + 1] = { host = hostLabel, at = now, args = { ... } }
    self.journalQueued = self.journalQueued + 1
    self.globalNoIdentitySuppressed = self.globalNoIdentitySuppressed + 1
    if self.journalHead > 256 and self.journalHead > (#self.journal / 2) then
        local compact = {}
        for index = self.journalHead, #self.journal do compact[#compact + 1] = self.journal[index] end
        self.journal, self.journalHead = compact, 1
    end
    return true
end

function C:_ProcessGlobalCombat(hostLabel, receivedAt, unitId, eventType, sourceName, targetName, abilityId, abilityName, damageType, effectType, isActive, more, more2, more3, more4, more5)
    local now = tonumber(receivedAt) or NowMs()
    if Identity:IsPlayerName(sourceName) or Identity:IsPlayerName(targetName) then
        self.globalSelfFiltered = self.globalSelfFiltered + 1
        return false, "self_filtered"
    end
    local signature = BuildSignature(unitId, eventType, sourceName, targetName, abilityId, abilityName, damageType, effectType, isActive, more, more2, more3, more4, more5)
    if self:_IsCrossHostDuplicate(hostLabel, signature, now) then return false, "cross_host_duplicate" end
    self.globalRows = self.globalRows + 1
    self:_OnCombatRaw("global:" .. tostring(hostLabel), unitId, eventType, sourceName, targetName, abilityId, abilityName, damageType, effectType, isActive, more, more2, more3, more4, more5, now)
    return true
end

function C:_FlushPreIdentityJournal(now)
    if Identity == nil or type(Identity.IsPlayerIdentityReady) ~= "function" or Identity:IsPlayerIdentityReady() ~= true then return false, "identity_not_ready" end
    now = tonumber(now) or NowMs()
    self:_DropExpiredJournal(now)
    local head, last = math.max(1, tonumber(self.journalHead) or 1), #self.journal
    if head > last then self.journal, self.journalHead = {}, 1; return true, 0 end
    local replayed = 0
    for index = head, last do
        local row = self.journal[index]
        if row ~= nil then
            if now - (tonumber(row.at) or 0) <= self.journalTtlMs then
                self:_ProcessGlobalCombat(row.host, row.at, unpack(row.args or {}))
                replayed = replayed + 1
            else
                self.journalDropped = self.journalDropped + 1
                self.journalDroppedCurrent = self.journalDroppedCurrent + 1
            end
        end
    end
    self.journal, self.journalHead = {}, 1
    self.journalReplayed = self.journalReplayed + replayed
    return true, replayed
end

function C:GetCoverageState()
    if self.globalActive ~= true then return "INACTIVE" end
    if Identity == nil or type(Identity.IsPlayerIdentityReady) ~= "function" or Identity:IsPlayerIdentityReady() ~= true then return "IDENTITY_COLD" end
    local ui, parent = self.globalHostCoverage.UI == true, self.globalHostCoverage.UIParent == true
    if ui ~= true and parent ~= true then return "UNAVAILABLE" end
    if self.journalDroppedCurrent > 0 or not (ui and parent) then return "DEGRADED" end
    return "FULL"
end

function C:_OnGlobalCombat(hostLabel, unitId, eventType, sourceName, targetName, abilityId, abilityName, damageType, effectType, isActive, more, more2, more3, more4, more5)
    local now = NowMs()
    local playerReady = Identity ~= nil and type(Identity.IsPlayerIdentityReady) == "function" and Identity:IsPlayerIdentityReady() == true
    if playerReady ~= true then
        if now - (tonumber(self.lastPlayerRefreshAt) or -1) >= 1000 and Identity ~= nil and type(Identity.RefreshPlayerIdentity) == "function" then
            self.lastPlayerRefreshAt = now
            Identity:RefreshPlayerIdentity(true)
            playerReady = Identity:IsPlayerIdentityReady() == true
        end
        if playerReady ~= true then
            return self:_JournalGlobal(hostLabel, now, unitId, eventType, sourceName, targetName, abilityId, abilityName, damageType, effectType, isActive, more, more2, more3, more4, more5)
        end
    end
    self:_FlushPreIdentityJournal(now)
    return self:_ProcessGlobalCombat(hostLabel, now, unitId, eventType, sourceName, targetName, abilityId, abilityName, damageType, effectType, isActive, more, more2, more3, more4, more5)
end

function C:_NormalizeCombatFact(transport, unitId, eventType, sourceName, targetName, abilityId, abilityName, damageType, effectType, isActive, more, more2, more3, more4, more5, receivedAt)
    local descriptor = self:DescribeEventType(eventType)
    self.sequence = self.sequence + 1
    local fact = {
        schemaVersion = 1,
        sequence = self.sequence,
        receivedAt = tonumber(receivedAt) or NowMs(),
        transport = tostring(transport or "unknown"),
        kind = descriptor.kind,
        category = descriptor.category,
        environmental = descriptor.environmental == true,
        amount = self:ParseAmount(eventType, abilityId, damageType, effectType),
        sourceName = Trim(sourceName),
        targetName = Trim(targetName),
        abilityName = Trim(abilityName),
        rawUnitId = unitId ~= nil and tostring(unitId) or nil,
        rawEventType = eventType,
        rawAbilityId = abilityId,
        rawDamageType = damageType,
        rawEffectType = effectType,
        rawIsActive = isActive,
        rawMore1 = more,
        rawMore2 = more2,
        rawMore3 = more3,
        rawMore4 = more4,
        rawMore5 = more5,
        auraType = descriptor.auraType,
        auraId = descriptor.category == "aura" and tonumber(abilityId) or nil,
        auraName = descriptor.category == "aura" and Trim(abilityName) or nil,
        auraEvidence = descriptor.category == "aura" and "event_type" or nil,
    }
    if descriptor.kind == "other" then self.unknownKinds = self.unknownKinds + 1 end
    if Identity ~= nil and type(Identity.ResolveCombatEndpoint) == "function" then
        local binding = Identity:ResolveCombatEndpoint(unitId, fact.sourceName, fact.targetName)
        if binding ~= nil then
            fact.boundRole = binding.role
            fact.boundConfidence = binding.confidence
            if binding.role == "source" then fact.sourceId = binding.id else fact.targetId = binding.id end
            -- UnitIdentity owns explicit kind reads and caches them by stable ID.
            -- The CombatFact carries that verified fact forward so every consumer
            -- does not repeat GetUnitInfoById or invent its own PLAYER/NPC logic.
            if type(Identity.GetById) == "function" then
                local info = Identity:GetById(binding.id, { includeKind = true })
                if type(info) == "table" and info.kindReliable == true then
                    if binding.role == "source" then fact.sourceKind = info.kind else fact.targetKind = info.kind end
                end
            end
        end
    end
    return fact
end

local function RestorePrimaryFact(fact, schemaVersion, sequence, receivedAt, transport, kind, category, amount, sourceName, targetName, sourceId, targetId, sourceKind, targetKind, abilityName, environmental, boundRole, boundConfidence)
    fact.schemaVersion, fact.sequence, fact.receivedAt = schemaVersion, sequence, receivedAt
    fact.transport, fact.kind, fact.category, fact.amount = transport, kind, category, amount
    fact.sourceName, fact.targetName, fact.sourceId, fact.targetId = sourceName, targetName, sourceId, targetId
    fact.sourceKind, fact.targetKind = sourceKind, targetKind
    fact.abilityName, fact.environmental = abilityName, environmental
    fact.boundRole, fact.boundConfidence = boundRole, boundConfidence
end

local function RestoreRawFact(fact, rawUnitId, rawEventType, rawAbilityId, rawDamageType, rawEffectType, rawIsActive, rawMore1, rawMore2, rawMore3, rawMore4, rawMore5, subjectName, rawNotice2, rawNotice3, rawNotice4, rawNotice5)
    fact.rawUnitId, fact.rawEventType, fact.rawAbilityId = rawUnitId, rawEventType, rawAbilityId
    fact.rawDamageType, fact.rawEffectType, fact.rawIsActive = rawDamageType, rawEffectType, rawIsActive
    fact.rawMore1, fact.rawMore2, fact.rawMore3, fact.rawMore4, fact.rawMore5 = rawMore1, rawMore2, rawMore3, rawMore4, rawMore5
    fact.subjectName = subjectName
    fact.rawNotice2, fact.rawNotice3, fact.rawNotice4, fact.rawNotice5 = rawNotice2, rawNotice3, rawNotice4, rawNotice5
end

function C:_CompactSubscriberOrder()
    if self.dispatchDepth > 0 or self.subscriberTombstones <= 0 then return end
    local compact = {}
    for _, row in ipairs(self.subscriberOrder) do
        if row ~= nil and row.active == true and self.subscribers[row.owner] == row then compact[#compact + 1] = row end
    end
    self.subscriberOrder = compact
    self.subscriberTombstones = 0
end

function C:_DispatchFact(fact)
    self.received = self.received + 1
    local delivered = 0
    self.dispatchDepth = self.dispatchDepth + 1
    local limit = #self.subscriberOrder
    for index = 1, limit do
        local row = self.subscriberOrder[index]
        local owner = row and row.owner or nil
        if row ~= nil and row.active == true and owner ~= nil and self.subscribers[owner] == row and type(row.callback) == "function" then
            if AcceptsTransport(row.options, fact.transport) ~= true then
                self.scopeFiltered = self.scopeFiltered + 1
            else
            -- CombatFact is borrowed + immutable. Capture primary semantic fields
            -- so a buggy consumer cannot contaminate later consumers without
            -- paying for a DeepCopy on every all-scope combat row.
            local schemaVersion, sequence, receivedAt = fact.schemaVersion, fact.sequence, fact.receivedAt
            local transport, kind, category, amount = fact.transport, fact.kind, fact.category, fact.amount
            local sourceName, targetName, sourceId, targetId = fact.sourceName, fact.targetName, fact.sourceId, fact.targetId
            local sourceKind, targetKind = fact.sourceKind, fact.targetKind
            local abilityName, environmental = fact.abilityName, fact.environmental
            local boundRole, boundConfidence = fact.boundRole, fact.boundConfidence
            local rawUnitId, rawEventType, rawAbilityId = fact.rawUnitId, fact.rawEventType, fact.rawAbilityId
            local rawDamageType, rawEffectType, rawIsActive = fact.rawDamageType, fact.rawEffectType, fact.rawIsActive
            local rawMore1, rawMore2, rawMore3, rawMore4, rawMore5 = fact.rawMore1, fact.rawMore2, fact.rawMore3, fact.rawMore4, fact.rawMore5
            local subjectName = fact.subjectName
            local rawNotice2, rawNotice3, rawNotice4, rawNotice5 = fact.rawNotice2, fact.rawNotice3, fact.rawNotice4, fact.rawNotice5
            local auraType, auraId, auraName, auraEvidence = fact.auraType, fact.auraId, fact.auraName, fact.auraEvidence
            local token = S.PerformanceMonitor and S.PerformanceMonitor:Begin(row.performanceLabel or "combat_fact:consumer", row.label or "combat") or nil
            local ok, err = xpcall(function() row.callback(owner, fact) end, S.SafeTraceback)
            if S.PerformanceMonitor ~= nil then S.PerformanceMonitor:End(token) end
            local mutated = fact.schemaVersion ~= schemaVersion or fact.sequence ~= sequence or fact.receivedAt ~= receivedAt
                or fact.transport ~= transport or fact.kind ~= kind or fact.category ~= category or fact.amount ~= amount
                or fact.sourceName ~= sourceName or fact.targetName ~= targetName or fact.sourceId ~= sourceId or fact.targetId ~= targetId
                or fact.sourceKind ~= sourceKind or fact.targetKind ~= targetKind
                or fact.abilityName ~= abilityName or fact.environmental ~= environmental or fact.boundRole ~= boundRole or fact.boundConfidence ~= boundConfidence
                or fact.rawUnitId ~= rawUnitId or fact.rawEventType ~= rawEventType or fact.rawAbilityId ~= rawAbilityId
                or fact.rawDamageType ~= rawDamageType or fact.rawEffectType ~= rawEffectType or fact.rawIsActive ~= rawIsActive
                or fact.rawMore1 ~= rawMore1 or fact.rawMore2 ~= rawMore2 or fact.rawMore3 ~= rawMore3 or fact.rawMore4 ~= rawMore4 or fact.rawMore5 ~= rawMore5
                or fact.subjectName ~= subjectName or fact.rawNotice2 ~= rawNotice2 or fact.rawNotice3 ~= rawNotice3
                or fact.rawNotice4 ~= rawNotice4 or fact.rawNotice5 ~= rawNotice5
                or fact.auraType ~= auraType or fact.auraId ~= auraId or fact.auraName ~= auraName or fact.auraEvidence ~= auraEvidence
            if mutated then
                self.factMutationErrors = self.factMutationErrors + 1
                RestorePrimaryFact(fact, schemaVersion, sequence, receivedAt, transport, kind, category, amount, sourceName, targetName, sourceId, targetId, sourceKind, targetKind, abilityName, environmental, boundRole, boundConfidence)
                RestoreRawFact(fact, rawUnitId, rawEventType, rawAbilityId, rawDamageType, rawEffectType, rawIsActive, rawMore1, rawMore2, rawMore3, rawMore4, rawMore5, subjectName, rawNotice2, rawNotice3, rawNotice4, rawNotice5)
                fact.auraType, fact.auraId, fact.auraName, fact.auraEvidence = auraType, auraId, auraName, auraEvidence
                EmitRateLimited("error", "COMBAT_FACT_MUTATED", "战斗事实消费者修改了共享 CombatFact，已恢复全部公开事实字段", { consumer = tostring(row.label or "unknown"), sequence = tostring(sequence or "?") })
            end
            if ok then delivered = delivered + 1 else
                self.callbackErrors = self.callbackErrors + 1
                EmitRateLimited("error", "COMBAT_CONSUMER_CALLBACK_FAILED", "战斗事实消费者回调失败", { consumer = tostring(row.label or "unknown"), error = tostring(err) })
            end
            end
        end
    end
    self.dispatchDepth = math.max(0, self.dispatchDepth - 1)
    self:_CompactSubscriberOrder()
    self.delivered = self.delivered + delivered
    return delivered
end

function C:_OnCombatRaw(transport, unitId, eventType, sourceName, targetName, abilityId, abilityName, damageType, effectType, isActive, more, more2, more3, more4, more5, receivedAt)
    -- Lease-independent gate. The native closures already check running before
    -- calling in, but this second fence makes the contract hold for every
    -- internal path too (journal replay, forced quiesce, parked hosts). A
    -- consumer whose lease was dropped must never receive combat work.
    if self.running ~= true then return 0 end
    local fact = self:_NormalizeCombatFact(transport, unitId, eventType, sourceName, targetName, abilityId, abilityName, damageType, effectType, isActive, more, more2, more3, more4, more5, receivedAt)
    return self:_DispatchFact(fact)
end

function C:_OnDeathNotice(info1, info2, info3, info4, info5)
    if self.running ~= true then return 0 end
    self.sequence = self.sequence + 1
    local fact = {
        schemaVersion = 1,
        sequence = self.sequence,
        receivedAt = NowMs(),
        transport = "private",
        kind = "death_notice",
        category = "death",
        subjectName = Trim(info1),
        rawNotice2 = info2,
        rawNotice3 = info3,
        rawNotice4 = info4,
        rawNotice5 = info5,
    }
    return self:_DispatchFact(fact)
end

function C:_ReconcileDemand(_, before, after, context)
    local beforeCount, afterCount = tonumber(before and before.count) or 0, tonumber(after and after.count) or 0
    if beforeCount <= 0 and afterCount > 0 then
        local ok, err = self:_Start()
        if ok ~= true then return false, err end
    end
    local wantAll = NeedsAll(after)
    if wantAll then
        local ok, err = self:_StartGlobalBridge()
        if ok ~= true then return false, err end
    elseif self.globalActive == true then
        local ok, err = self:_ReleaseGlobalBridge()
        if ok ~= true then return false, err end
    end
    if beforeCount > 0 and afterCount <= 0 then
        local ok, err = self:_Stop()
        if ok ~= true then return false, err end
    end
    return true
end

if S.Demand ~= nil and type(S.Demand.Create) == "function" then
    C.demand = S.Demand:Create({
        id = "service.combat_event_bus",
        owner = C,
        normalize = NormalizeDemandOptions,
        reconcile = function(lease, before, after, context) return C:_ReconcileDemand(lease, before, after, context) end,
        -- Best-effort native detach. Whatever the outcome, the bus becomes
        -- inert so no business callback survives a forced quiesce, and the
        -- real release error is still reported (never silently swallowed).
        quiesce = function()
            local released, releaseErr = C:_Stop()
            C:_MarkInert()
            return released, releaseErr
        end,
        projectionOwner = C,
        projectionConsumersField = "consumerOptions",
        projectionCountField = "consumerCount",
    })
end

function C:Subscribe(owner, callback, options)
    if owner == nil or type(callback) ~= "function" then return false, "owner/callback required" end
    if self.demand == nil then return false, "combat demand unavailable" end
    local existing = self.subscribers[owner]
    local token = existing and existing.token or ("combat:" .. tostring(self.subscriberSerial + 1))
    local ok, err = self.demand:Acquire(token, options, "combat_subscribe")
    if ok ~= true then return false, err end
    if existing == nil then
        self.subscriberSerial = self.subscriberSerial + 1
        self.subscriberCount = self.subscriberCount + 1
        existing = { token = token, owner = owner, serial = self.subscriberSerial, active = true }
        self.subscribers[owner] = existing
        self.subscriberOrder[#self.subscriberOrder + 1] = existing
    end
    existing.active = true
    existing.callback = callback
    existing.options = NormalizeDemandOptions(options)
    existing.label = tostring((type(owner) == "table" and (owner.Id or owner.id or owner.Name or owner.name)) or owner or token)
    existing.performanceLabel = "combat_fact:" .. existing.label
    return true
end

function C:Unsubscribe(owner)
    local row = owner ~= nil and self.subscribers[owner] or nil
    if row == nil then return false, "consumer not subscribed" end
    local ok, err = self.demand:Release(row.token, "combat_unsubscribe")
    if ok ~= true then return false, err end
    self.subscribers[owner] = nil
    row.active = false
    self.subscriberTombstones = self.subscriberTombstones + 1
    self.subscriberCount = math.max(0, self.subscriberCount - 1)
    self:_CompactSubscriberOrder()
    return true
end

function C:GetHealth()
    return {
        version = self.version,
        running = self.running == true,
        consumers = tonumber(self.consumerCount) or 0,
        subscribers = self.subscriberCount,
        globalActive = self.globalActive == true,
        coverageState = self:GetCoverageState(),
        globalHosts = (self.globalHandlers.UI and 1 or 0) + (self.globalHandlers.UIParent and 1 or 0),
        globalUI = self.globalHostCoverage.UI == true,
        globalUIParent = self.globalHostCoverage.UIParent == true,
        privateParked = self.privateParked == true,
        globalParkedHosts = tonumber(self.globalParkedHosts) or 0,
        scope = NeedsAll(self) and "all" or (self.subscriberCount > 0 and "self" or "none"),
        scopeFiltered = self.scopeFiltered,
        releaseApiMissing = self.releaseApiMissing,
        releaseCallFailures = self.releaseCallFailures,
        stopFailures = self.stopFailures,
        forcedInert = self.forcedInert,
        journalPending = JournalActiveCount(self),
        journalQueued = self.journalQueued,
        journalReplayed = self.journalReplayed,
        journalDropped = self.journalDropped,
        received = self.received,
        delivered = self.delivered,
        privateRows = self.privateRows,
        globalRows = self.globalRows,
        globalSelfFiltered = self.globalSelfFiltered,
        globalNoIdentitySuppressed = self.globalNoIdentitySuppressed,
        globalCrossHostDuplicates = self.globalCrossHostDuplicates,
        globalCrossHostPending = tonumber(self.pairPendingCount) or 0,
        globalCrossHostEvicted = self.globalCrossHostEvicted,
        callbackErrors = self.callbackErrors,
        factMutationErrors = self.factMutationErrors,
        unknownKinds = self.unknownKinds,
        startFailures = self.startFailures,
    }
end
