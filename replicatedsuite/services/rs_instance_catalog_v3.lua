------------------------------------------------------------------------
-- Replicated Suite V3 - Instance Catalog Service
--
-- Sole read-only Authority for X2BattleField instance entrance data.
--
-- Namespace contract:
--   * runtimeInstanceType = X2BattleField entry.type (session observation).
--   * databaseZoneId      = static ArcheRage map database Zone ID.
-- These identities are never promoted/interchanged automatically.
--
-- Performance:
--   * No Tick / OnUpdate.
--   * Full kind/list discovery on first consumer, explicit refresh, empty
--     catalog recovery, or at most once per 5 minutes while observed.
--   * Detail counters refresh every 30s while a consumer exists and react to
--     visit-count/reset events through a 200ms debounce.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
S.Services = S.Services or {}

local C = {
    Id = "v3.instance_catalog",
    consumers = {},
    consumerCount = 0,
    running = false,
    revision = 0,
    updatedAtMs = -1,
    lastDiscoveryAtMs = -300000,
    rows = {},
    byType = {},
    kinds = {},
    refreshFailures = 0,
    discoveryFailures = 0,
    detailFailures = 0,
    staleDetailMisses = {},
    safetyTask = "v3_instance_catalog_safety",
    pendingFullRefresh = false,
}
C.presentationBoundary = "service_only"
S.Services.InstanceCatalogV3 = C

local INSTANCE_EVENTS = {
    "UPDATE_INSTANCE_VISIT_COUNT",
    "INSTANT_GAME_VISIT_COUNT_RESET",
    "ENTERED_WORLD",
}

local function NowMs()
    return math.max(0, tonumber(S.NowMs and S.NowMs()) or 0)
end

local function Capability(name)
    return S.Api ~= nil and type(S.Api.IsCapabilityAllowed) == "function"
        and S.Api:IsCapabilityAllowed(name) == true
end

local function NormalizeText(value)
    return string.lower(tostring(value or ""))
end

local function CopyRow(value)
    if type(value) ~= "table" then return nil end
    local out = {}
    for key, item in pairs(value) do out[key] = item end
    return out
end

local function RowEqual(a, b)
    if a == b then return true end
    if type(a) ~= "table" or type(b) ~= "table" then return false end
    return a.instanceType == b.instanceType
        and a.kindType == b.kindType
        and a.kindName == b.kindName
        and a.name == b.name
        and a.enterCount == b.enterCount
        and a.maxEnterCount == b.maxEnterCount
        and a.available == b.available
        and a.detailAvailable == b.detailAvailable
        and a.staticKey == b.staticKey
        and a.databaseZoneId == b.databaseZoneId
        and a.identityStatus == b.identityStatus
end

local function RowsEqual(left, right)
    if type(left) ~= "table" or type(right) ~= "table" or #left ~= #right then return false end
    for index = 1, #left do
        if RowEqual(left[index], right[index]) ~= true then return false end
    end
    return true
end

local function AliasMatches(name, aliases)
    local normalized = NormalizeText(name)
    if normalized == "" then return false end
    for _, alias in ipairs(type(aliases) == "table" and aliases or {}) do
        local candidate = NormalizeText(alias)
        if candidate ~= "" and (normalized == candidate
            or string.find(normalized, candidate, 1, true) ~= nil
            or string.find(candidate, normalized, 1, true) ~= nil) then
            return true
        end
    end
    return false
end

local function ResolveStaticIdentity(name)
    local ids = S.GameIds and S.GameIds.Instance or nil
    local byKey = type(ids) == "table" and ids.ByKey or nil
    if type(byKey) ~= "table" then return nil, "static_registry_unavailable" end

    local matches = {}
    for key, row in pairs(byKey) do
        if type(row) == "table" and AliasMatches(name, row.matchNames) then
            matches[#matches + 1] = { key = tostring(key), row = row }
        end
    end
    if #matches == 1 then return matches[1], "matched" end
    if #matches > 1 then return nil, "ambiguous" end
    return nil, "unmapped"
end

local function NormalizeKindName(kind)
    if type(kind) ~= "table" then return "未分类" end
    local value = kind.name or kind.title or kind.label
    value = tostring(value or "")
    if value ~= "" then return value end
    return "分类 " .. tostring(kind.type or "?")
end

local function EntryText(enterCount, maxEnterCount)
    enterCount = math.max(0, math.floor(tonumber(enterCount) or 0))
    maxEnterCount = math.max(0, math.floor(tonumber(maxEnterCount) or 0))
    if maxEnterCount == 1000 then return tostring(enterCount) .. "/不限" end
    if maxEnterCount > 0 then return tostring(math.min(enterCount, maxEnterCount)) .. "/" .. tostring(maxEnterCount) end
    return "--"
end

local function ApplyDisplayFields(row)
    local maxEntry = math.max(0, math.floor(tonumber(row.maxEnterCount) or 0))
    local entered = math.max(0, math.floor(tonumber(row.enterCount) or 0))
    row.entryText = EntryText(entered, maxEntry)
    row.limited = maxEntry > 0 and maxEntry ~= 1000
    row.remaining = row.limited and math.max(0, maxEntry - entered) or nil
    row.limitUsed = row.limited and entered >= maxEntry or false
    if row.detailAvailable ~= true then
        row.availabilityText, row.availabilityTone = "数据未就绪", "muted"
    elseif row.available == true then
        row.availabilityText, row.availabilityTone = "可进入", "green"
    elseif row.available == false then
        row.availabilityText, row.availabilityTone = "当前不可进入", "muted"
    else
        row.availabilityText, row.availabilityTone = "--", "muted"
    end
    if row.staticKey ~= nil then
        row.identityText = "已关联静态身份"
        row.identityTone = "green"
    elseif row.identityStatus == "ambiguous" then
        row.identityText = "名称映射冲突"
        row.identityTone = "orange"
    else
        row.identityText = "运行时ID待核验"
        row.identityTone = "yellow"
    end
    return row
end

function C:BuildRow(kind, entry, battleField)
    if type(entry) ~= "table" or tonumber(entry.type) == nil then return nil end
    local instanceType = math.floor(tonumber(entry.type))
    local name = ""
    if Capability("X2BattleField:GetInstanceName") then
        local okName, value = S.Api:CallCapability("X2BattleField:GetInstanceName", battleField, "GetInstanceName", instanceType)
        if okName == true and type(value) == "string" then name = value end
    end

    local detail = nil
    if Capability("X2BattleField:GetDetailInstanceInfo") then
        local okDetail, value = S.Api:CallCapability("X2BattleField:GetDetailInstanceInfo", battleField, "GetDetailInstanceInfo", instanceType)
        if okDetail == true and type(value) == "table" then detail = value end
    end
    if name == "" and type(detail) == "table" and type(detail.name) == "string" then name = detail.name end
    if name == "" then name = "副本 #" .. tostring(instanceType) end

    local identity, identityStatus = ResolveStaticIdentity(name)
    local row = {
        id = "instance:" .. tostring(instanceType),
        instanceType = instanceType,
        kindType = type(kind) == "table" and kind.type or nil,
        kindName = NormalizeKindName(kind),
        name = name,
        detailAvailable = detail ~= nil,
        enterCount = type(detail) == "table" and math.max(0, tonumber(detail.enterCount) or 0) or 0,
        maxEnterCount = type(detail) == "table" and math.max(0, tonumber(detail.maxEnterCount) or 0) or 0,
        available = type(detail) == "table" and detail.available or nil,
        staticKey = identity and identity.key or nil,
        databaseZoneId = identity and tonumber(identity.row.databaseZoneId) or nil,
        identityStatus = identityStatus,
        observedAtMs = NowMs(),
    }
    if identity ~= nil then
        local ids = S.GameIds and S.GameIds.Instance or nil
        if type(ids) == "table" and type(ids.ObserveRuntimeCandidate) == "function" then
            ids:ObserveRuntimeCandidate(identity.key, instanceType, name)
        end
    end
    return ApplyDisplayFields(row)
end

function C:PublishIfChanged(nextRows, reason)
    table.sort(nextRows, function(a, b)
        local ak, bk = tostring(a.kindName or ""), tostring(b.kindName or "")
        if ak ~= bk then return ak < bk end
        local an, bn = tostring(a.name or ""), tostring(b.name or "")
        if an ~= bn then return an < bn end
        return (tonumber(a.instanceType) or 0) < (tonumber(b.instanceType) or 0)
    end)
    local changed = RowsEqual(self.rows, nextRows) ~= true
    self.rows = nextRows
    self.byType = {}
    for _, row in ipairs(nextRows) do self.byType[row.instanceType] = row end
    self.updatedAtMs = NowMs()
    if changed then
        self.revision = (tonumber(self.revision) or 0) + 1
        if S.Events ~= nil and type(S.Events.Publish) == "function" then
            S.Events:Publish("v3.instances.updated", self.revision, tostring(reason or "refresh"))
        end
    end
    return true, changed
end

function C:Discover(reason)
    if Capability("X2BattleField:GetInstanceUiKindList") ~= true
        or Capability("X2BattleField:GetInstanceListByKind") ~= true
        or Capability("X2BattleField:GetDetailInstanceInfo") ~= true then
        return false, "instance capabilities unavailable"
    end
    local battleField = rawget(_G, "X2BattleField")
    if battleField == nil then return false, "X2BattleField unavailable" end

    local okKinds, kinds = S.Api:CallCapability("X2BattleField:GetInstanceUiKindList", battleField, "GetInstanceUiKindList")
    if okKinds ~= true or type(kinds) ~= "table" then
        self.discoveryFailures = (tonumber(self.discoveryFailures) or 0) + 1
        return false, "instance kind list unavailable"
    end

    local nextRows, kindRows = {}, {}
    for _, kind in ipairs(kinds) do
        if type(kind) == "table" and kind.type ~= nil then
            kindRows[#kindRows + 1] = { type = kind.type, name = NormalizeKindName(kind) }
            local okList, list = S.Api:CallCapability("X2BattleField:GetInstanceListByKind", battleField, "GetInstanceListByKind", kind.type)
            if okList == true and type(list) == "table" then
                for _, entry in ipairs(list) do
                    local row = self:BuildRow(kind, entry, battleField)
                    if row ~= nil then nextRows[#nextRows + 1] = row end
                end
            end
        end
    end
    if #nextRows == 0 and #self.rows > 0 then
        self.discoveryFailures = (tonumber(self.discoveryFailures) or 0) + 1
        return false, "instance discovery returned empty catalog"
    end
    self.kinds = kindRows
    self.lastDiscoveryAtMs = NowMs()
    return self:PublishIfChanged(nextRows, reason or "discovery")
end

function C:RefreshDetails(reason)
    if #self.rows == 0 then return self:Discover(reason or "detail_empty") end
    local battleField = rawget(_G, "X2BattleField")
    if battleField == nil or Capability("X2BattleField:GetDetailInstanceInfo") ~= true then
        return false, "instance detail API unavailable"
    end

    local nextRows = {}
    for _, previous in ipairs(self.rows) do
        local row = CopyRow(previous)
        local okInfo, info = S.Api:CallCapability("X2BattleField:GetDetailInstanceInfo", battleField, "GetDetailInstanceInfo", row.instanceType)
        if okInfo == true and type(info) == "table" then
            self.staleDetailMisses[row.instanceType] = nil
            row.detailAvailable = true
            row.enterCount = math.max(0, tonumber(info.enterCount) or 0)
            row.maxEnterCount = math.max(0, tonumber(info.maxEnterCount) or 0)
            row.available = info.available
            if type(info.name) == "string" and info.name ~= "" and tostring(row.name or "") ~= info.name then
                row.name = info.name
                local identity, identityStatus = ResolveStaticIdentity(row.name)
                row.staticKey = identity and identity.key or nil
                row.databaseZoneId = identity and tonumber(identity.row.databaseZoneId) or nil
                row.identityStatus = identityStatus
                if identity ~= nil and S.GameIds and S.GameIds.Instance and type(S.GameIds.Instance.ObserveRuntimeCandidate) == "function" then
                    S.GameIds.Instance:ObserveRuntimeCandidate(identity.key, row.instanceType, row.name)
                end
            end
            row.observedAtMs = NowMs()
        else
            self.detailFailures = (tonumber(self.detailFailures) or 0) + 1
            local misses = (tonumber(self.staleDetailMisses[row.instanceType]) or 0) + 1
            self.staleDetailMisses[row.instanceType] = misses
            if misses >= 3 then
                row.detailAvailable = false
                -- Force the next safety refresh back through kind/list discovery;
                -- a stale runtime type may have disappeared after server reset.
                self.lastDiscoveryAtMs = -300000
            end
        end
        nextRows[#nextRows + 1] = ApplyDisplayFields(row)
    end
    return self:PublishIfChanged(nextRows, reason or "details")
end

function C:Refresh(reason, fullDiscovery)
    local ok, a, b = xpcall(function()
        local now = NowMs()
        local needsDiscovery = fullDiscovery == true or #self.rows == 0
            or now - (tonumber(self.lastDiscoveryAtMs) or -300000) >= 300000
        if needsDiscovery then return self:Discover(reason or "refresh_full") end
        return self:RefreshDetails(reason or "refresh_details")
    end, S.SafeTraceback)
    if ok ~= true then
        self.refreshFailures = (tonumber(self.refreshFailures) or 0) + 1
        if S.DiagnosticsManager ~= nil and type(S.DiagnosticsManager.Record) == "function" then
            S.DiagnosticsManager:Record("warning", self.Id, "副本目录刷新失败: " .. tostring(a))
        end
        return false, a
    end
    if a ~= true then
        self.refreshFailures = (tonumber(self.refreshFailures) or 0) + 1
        return false, b
    end
    return true
end

function C:RequestRefresh(delayMs, reason, fullDiscovery)
    if self.running ~= true or self.consumerCount <= 0 then return false end
    self.pendingFullRefresh = self.pendingFullRefresh == true or fullDiscovery == true
    local coordinator = S.RefreshCoordinator
    if type(coordinator) ~= "table" or type(coordinator.Request) ~= "function" then
        local full = self.pendingFullRefresh
        self.pendingFullRefresh = false
        return self:Refresh(reason or "request", full)
    end
    return coordinator:Request({
        key = "instance_catalog",
        owner = self,
        delayMs = math.max(100, tonumber(delayMs) or 200),
        reason = reason or "instance_event",
        moduleId = self.Id,
        priority = "P2",
        cost = 2,
        callback = function(reasons, latestReason)
            local full = C.pendingFullRefresh
            C.pendingFullRefresh = false
            return C:Refresh(latestReason or "instance_event", full)
        end,
    })
end

function C:Start()
    if self.running == true then return true end
    if S.Events == nil or S.Scheduler == nil then return false, "event/scheduler unavailable" end
    S.Events:BindOwner(self, self.Id)
    for _, eventName in ipairs(INSTANCE_EVENTS) do
        local subscribed = S.Events:Subscribe(eventName, self, function()
            C:RequestRefresh(200, eventName, eventName == "ENTERED_WORLD")
        end)
        if subscribed ~= true then
            S.Events:UnsubscribeOwner(self)
            return false, "instance event subscribe failed: " .. tostring(eventName)
        end
    end
    local added = S.Scheduler:AddTask(self.safetyTask, 30000, function()
        if C.consumerCount > 0 then C:Refresh("safety", false) end
    end, false, self, "P3", 2)
    if added ~= true then
        S.Events:UnsubscribeOwner(self)
        return false, "instance safety task registration failed"
    end
    S.Scheduler:SetTaskModule(self.safetyTask, self.Id)
    self.running = true
    local now = NowMs()
    local full = #self.rows == 0 or now - (tonumber(self.lastDiscoveryAtMs) or -300000) >= 300000
    return self:Refresh("start", full)
end

function C:Stop()
    if self.running ~= true then return true end
    self.running = false
    self.pendingFullRefresh = false
    if S.Events ~= nil then S.Events:UnsubscribeOwner(self) end
    if S.RefreshCoordinator ~= nil and type(S.RefreshCoordinator.Cancel) == "function" then
        S.RefreshCoordinator:Cancel(self, "instance_catalog")
    end
    if S.Scheduler ~= nil then S.Scheduler:RemoveTask(self.safetyTask) end
    return true
end

function C:ReconcileDemand(before, after)
    local beforeCount = tonumber(before and before.count) or 0
    local afterCount = tonumber(after and after.count) or 0
    if beforeCount == 0 and afterCount > 0 then return self:Start() end
    if beforeCount > 0 and afterCount == 0 then return self:Stop() end
    return true
end

function C:QuiesceDemand(reason, cause)
    local ok = self:Stop() == true
    self.pendingFullRefresh = false
    return ok
end

if S.Demand == nil or type(S.Demand.Create) ~= "function" then error("Demand unavailable for InstanceCatalogV3") end
local instanceDemand, instanceDemandErr = S.Demand:Create({
    id = C.Id,
    owner = C,
    projectionOwner = C,
    projectionConsumersField = "consumers",
    projectionCountField = "consumerCount",
    reconcile = function(_, before, after) return C:ReconcileDemand(before, after) end,
    quiesce = function(_, reason, cause) return C:QuiesceDemand(reason, cause) end,
})
if instanceDemand == nil then error(instanceDemandErr) end
C.Demand = instanceDemand

function C:AcquireConsumer(token)
    return self.Demand:Acquire(token, {}, "instance_catalog_consumer")
end

function C:ReleaseConsumer(token)
    return self.Demand:Release(token, "instance_catalog_consumer")
end

function C:GetRows()
    local out = {}
    for _, row in ipairs(self.rows) do out[#out + 1] = CopyRow(row) end
    return out, self.revision
end

function C:GetRowByType(instanceType)
    return CopyRow(self.byType[tonumber(instanceType)])
end

function C:FindByAliases(aliases)
    for _, row in ipairs(self.rows) do
        if AliasMatches(row.name, aliases) then return CopyRow(row) end
    end
    return nil
end

function C:GetEntryProgress(aliases, fallbackMax)
    local row = self:FindByAliases(aliases)
    fallbackMax = math.max(1, math.floor(tonumber(fallbackMax) or 1))
    if row == nil or row.detailAvailable ~= true then
        return { available = false, completed = 0, total = 1, text = "--", tone = "muted" }
    end
    local enterCount = math.max(0, math.floor(tonumber(row.enterCount) or 0))
    local rawMax = math.max(0, math.floor(tonumber(row.maxEnterCount) or 0))
    local finite = rawMax > 0 and rawMax ~= 1000
    local displayMax = finite and rawMax or fallbackMax
    local entered = finite and enterCount >= rawMax
    return {
        kind = "instanceRaid",
        available = true,
        instanceAvailable = row.available,
        instanceType = row.instanceType,
        name = row.name,
        enterCount = enterCount,
        maxEnterCount = rawMax,
        completed = entered and 1 or 0,
        total = 1,
        activeCount = 0,
        readyCount = 0,
        relatedActiveCount = 0,
        relatedReadyCount = 0,
        tailInFlightCount = 0,
        text = entered and ("1/" .. tostring(displayMax)) or ("0/" .. tostring(displayMax)),
        tone = entered and "green" or "muted",
    }
end

function C:GetHealth()
    local mapped, unmapped, detailReady = 0, 0, 0
    for _, row in ipairs(self.rows) do
        if row.staticKey ~= nil then mapped = mapped + 1 else unmapped = unmapped + 1 end
        if row.detailAvailable == true then detailReady = detailReady + 1 end
    end
    return {
        ok = self.running == true or self.consumerCount == 0,
        running = self.running == true,
        consumers = self.consumerCount,
        revision = self.revision,
        total = #self.rows,
        mapped = mapped,
        unmapped = unmapped,
        detailReady = detailReady,
        kinds = #self.kinds,
        refreshFailures = self.refreshFailures,
        discoveryFailures = self.discoveryFailures,
        detailFailures = self.detailFailures,
        updatedAtMs = self.updatedAtMs,
        lastDiscoveryAtMs = self.lastDiscoveryAtMs,
    }
end
