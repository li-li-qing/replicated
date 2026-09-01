------------------------------------------------------------------------
-- Replicated Suite - World Observation Service
-- Shared lightweight reads/cache/subscriptions only; never owns Domain truth.
--
-- ReadField is deliberately a very short TTL read-through cache. It removes
-- duplicate Name/ID/Health/Distance calls made by enabled modules in the same
-- observation window without freezing target changes or turning cached facts
-- into business conclusions. Expensive Buff/Tooltip queries remain explicitly
-- requested by the owning module and use argument-qualified cache keys.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
S.Observation = { cache = {}, readCache = {}, subscriptions = {}, revision = 0, readHits = 0, readMisses = 0 }
local O = S.Observation

local function OwnerKey(owner) return tostring(owner or "anonymous") end
local function ActorKey(actor) return tostring(actor or "") end
local function Count(value) local n=0; if type(value)=="table" then for _ in pairs(value) do n=n+1 end end; return n end

function O:Subscribe(owner, fields)
    local key = OwnerKey(owner)
    local set = {}
    if type(fields) == "table" then for _, field in ipairs(fields) do set[tostring(field)] = true end end
    self.subscriptions[key] = set
    return true
end

function O:Unsubscribe(owner)
    self.subscriptions[OwnerKey(owner)] = nil
    return true
end

function O:IsFieldRequested(field)
    field = tostring(field or "")
    for _, set in pairs(self.subscriptions) do if set[field] == true then return true end end
    return false
end

local function EffectiveTtl(actorKey, ttlMs)
    local ttl = math.max(0, tonumber(ttlMs) or 75)
    local lower = tostring(actorKey or ""):lower()
    -- target/targettarget are volatile aliases. Only share reads that happen in
    -- the exact same timestamp; never retain them across target switches.
    if lower == "target" or lower == "targettarget" or lower == "mouseover" then return 0 end
    return ttl
end

function O:ReadField(owner, actor, field, fetchFn, ttlMs)
    if type(fetchFn) ~= "function" then return nil end
    local actorKey, fieldKey = ActorKey(actor), tostring(field or "")
    if actorKey == "" or fieldKey == "" then
        local ok, value = pcall(fetchFn); return ok and value or nil
    end
    local now = S.NowMs and S.NowMs() or 0
    local ttl = EffectiveTtl(actorKey, ttlMs)
    local key = actorKey .. "\31" .. fieldKey
    local cached = self.readCache[key]
    if type(cached) == "table" and now - (tonumber(cached.at) or 0) <= ttl then
        self.readHits = self.readHits + 1
        return cached.value
    end
    local ok, value = pcall(fetchFn)
    if not ok then return nil end
    self.readCache[key] = { value = value, at = now, owner = OwnerKey(owner), actor = actorKey, field = fieldKey }
    self.readMisses = self.readMisses + 1
    return value
end

function O:Publish(source, actorKey, snapshot)
    actorKey = ActorKey(actorKey)
    if actorKey == "" or type(snapshot) ~= "table" then return false end
    local row = self.cache[actorKey]
    if type(row) ~= "table" then row = { sources={} }; self.cache[actorKey] = row end
    row.sources[tostring(source or "unknown")] = true
    row.lastSeenAt = S.NowMs and S.NowMs() or 0
    for key, value in pairs(snapshot) do
        if key ~= "domain" and key ~= "stats" and key ~= "ranking" then row[key] = value end
    end
    self.revision = self.revision + 1
    return true
end

function O:Get(actorKey) return self.cache[ActorKey(actorKey)] end

function O:Prune(maxAgeMs)
    maxAgeMs = math.max(5000, tonumber(maxAgeMs) or 120000)
    local now = S.NowMs and S.NowMs() or 0
    for key, row in pairs(self.cache) do
        if now - (tonumber(row.lastSeenAt) or 0) > maxAgeMs then self.cache[key] = nil end
    end
    -- Read-through facts are intentionally much shorter lived. Prune stale
    -- entries in bounded background maintenance, never from a combat callback.
    for key, row in pairs(self.readCache) do
        if now - (tonumber(row.at) or 0) > 5000 then self.readCache[key] = nil end
    end
end

function O:Describe()
    local actors, subscribers, reads = Count(self.cache), Count(self.subscriptions), Count(self.readCache)
    return {
        actors=actors, subscribers=subscribers, revision=self.revision,
        cacheCount=actors, subscriberCount=subscribers, readCacheCount=reads,
        readHits=tonumber(self.readHits) or 0, readMisses=tonumber(self.readMisses) or 0,
    }
end
