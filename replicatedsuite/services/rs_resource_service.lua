------------------------------------------------------------------------
-- Replicated Suite - Resource Authority
-- Author: Replicated
--
-- IMPORTANT:
-- The supplied RU API whitelist only allows X2Bag:GetBagItemInfo(bagId, slot)
-- for bag reads. Convenience APIs such as CountBagItemByItemType, Capacity,
-- CountEmptyBagSlots and GetCurrency are explicitly listed as not allowed.
-- This service therefore fails closed: unsupported values are shown as "--"
-- instead of probing blocked APIs or fabricating data.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
S.Services = S.Services or {}
S.Services.Resource = { bagSlots = 150, bagSnapshot = nil, bagDirty = true, activeBagId = nil }
local R = S.Services.Resource
R.presentationBoundary = "service_only"
R.presentationDebt = nil
local DAILY_PERIOD_POLICY = { kind = "server_date" }

local function Diagnostic(level, code, message, context, rateMs)
    local d = S.DiagnosticsManager
    if type(d) ~= "table" then return end
    if rateMs ~= nil and type(d.RateLimited) == "function" then
        d:RateLimited(level, "resource", code, rateMs, message, context)
    elseif type(d.Emit) == "function" then
        d:Emit(level, "resource", code, message, context)
    end
end

local function Primitive(value)
    if type(value) == "number" or type(value) == "string" then return value end
    if type(value) ~= "table" then return nil end
    for _, key in ipairs({ "value", "amount", "count", "stackCount", "stack", "number" }) do
        if type(value[key]) == "number" or type(value[key]) == "string" then return value[key] end
    end
    return nil
end

local function ExtractBagType(info)
    if type(info) ~= "table" then return nil end
    -- GetBagItemInfo's table contract is not documented in the supplied API
    -- dump. These field names are compatibility observations from the user's
    -- existing ReplicatedGear and public RU addons, not an assumed contract.
    for _, key in ipairs({ "itemType", "itemTypeId", "typeId", "item_type" }) do
        local value = tonumber(Primitive(info[key]))
        if value ~= nil and value > 0 then return math.floor(value) end
    end
    return nil
end

local function ExtractBagCount(info)
    if type(info) ~= "table" then return nil end
    for _, key in ipairs({ "stackCount", "stack", "count", "amount", "itemCount" }) do
        local value = tonumber(Primitive(info[key]))
        if value ~= nil and value > 0 then return math.floor(value) end
    end
    -- Never convert an unknown stack field to 1: one slot may contain a large
    -- stack of bonds, and doing so would silently publish a wrong number.
    return nil
end

function R:EnsureDate()
    local key = nil
    if type(S.Persistence) == "table" and type(S.Persistence.GetPeriodId) == "function" then
        key = select(1, S.Persistence:GetPeriodId(S.Persistence.Lifetime.Daily, DAILY_PERIOD_POLICY))
    end
    if key == nil then key = S.Utils.ServerDateKey() end
    -- Guard (2026-08-24 hotfix): right after login / before ENTERED_WORLD the
    -- server time table may not be available yet, so ServerDateKey() returns
    -- "unknown". Resetting on that value wiped the saved daily counters every
    -- relog (dateKey "unknown" != stored "2026-08-24" -> zeroed + overwritten).
    -- Only roll the day when we actually KNOW a new date; while the key is
    -- unreliable keep the previous counters untouched and wait for the next
    -- Refresh after the world finishes loading.
    if key == nil or key == "" or key == "unknown" then return end

    local counters = S.State.dailyCounters
    if type(counters) ~= "table" then counters = {}; S.State.dailyCounters = counters end
    local current = tostring(counters.dateKey or "unknown")

    local function Snapshot()
        local snap = {}
        for _, name in ipairs({ "gold", "honor", "vocation", "exp" }) do
            snap[name] = tonumber(counters[name]) or 0
        end
        return snap
    end

    -- Cold-state guard (2026-08-24 second hotfix, hardened): a UI reload
    -- rebuilds State from defaults, so dailyCounters can sit at
    -- {dateKey="unknown"} even though the disk still holds the real day's
    -- earnings (Storage:Load may have failed transiently during the refresh).
    -- The decisive rule: a day rollover may ONLY be decided from a
    -- *successful* read of the persisted counters. When the disk cannot be
    -- read (nil/false payload or read error -- indistinguishable from a fresh
    -- install while the addon storage is re-mounting), never reset and never
    -- write; retry on a later Refresh instead.
    if current == "unknown" then
        local pending = Snapshot()
        local verdict = false
        if S.Storage ~= nil and type(S.Storage.RestoreDailyCounters) == "function" then
            local ok, result = pcall(function() return S.Storage:RestoreDailyCounters() end)
            verdict = ok and result or false
        end
        if verdict == true then
            -- Recovery succeeded: merge any deltas that arrived while the
            -- counters were still cold so the restore cannot swallow them.
            for _, name in ipairs({ "gold", "honor", "vocation", "exp" }) do
                counters[name] = (tonumber(counters[name]) or 0) + (pending[name] or 0)
            end
            current = tostring(counters.dateKey or "unknown")
            Diagnostic("info", "DAILY_COUNTERS_RECOVERED", "已从独立/兼容存档恢复每日计数", {
                period = current, gold = tonumber(counters.gold) or 0, honor = tonumber(counters.honor) or 0,
                vocation = tonumber(counters.vocation) or 0, exp = tonumber(counters.exp) or 0,
            })
        elseif verdict == "empty" then
            -- Storage confirmed a payload WITHOUT any saved counters: this is a
            -- definitive first run. Initialize today, keeping only deltas that
            -- arrived during the cold window, and write the dedicated save key
            -- IMMEDIATELY so even a reload right now cannot lose the init.
            counters.dateKey = key
            counters.gold, counters.honor, counters.vocation, counters.exp =
                pending.gold, pending.honor, pending.vocation, pending.exp
            local seeded = S.Storage ~= nil and type(S.Storage.PersistDailyCounters) == "function"
                and S.Storage:PersistDailyCounters(counters) == true
            S.Storage:RequestSave(0)
            Diagnostic(seeded == true and "info" or "warning", "DAILY_COUNTERS_INITIALIZED",
                seeded == true and "首次每日计数已初始化并写入独立 Store" or "首次每日计数已初始化，但独立 Store 写入失败", {
                    period = key, storageLoadFailed = S.Storage ~= nil and S.Storage.loadFailed == true or false,
                })
            return
        else
            -- Could not confirm what the disk holds. Never zero, never write;
            -- re-enter this path shortly (bounded by resource_debounce).
            Diagnostic("warning", "DAILY_COUNTERS_UNREADABLE",
                "重载后无法确认每日计数存档，已保持原值且禁止清零", { period = key }, 5000)
            self:RequestRefresh(3000)
            return
        end
    end

    -- Roll only forward: an older/equal key (server time rewind, same day)
    -- must never zero the counters. A real newer day resets them once.
    if key == current then return end
    if current ~= "unknown" and key < current then return end
    counters.dateKey = key
    counters.gold, counters.honor, counters.vocation, counters.exp = 0, 0, 0, 0
    S.Storage:RequestSave(0)
    Diagnostic("info", "DAILY_PERIOD_ROLLOVER", "服务器日周期变化，今日收益已重置", { oldPeriod = current, newPeriod = key })
end

function R:BuildBagSnapshot()
    if self.bagDirty ~= true and self.bagSnapshot ~= nil then return self.bagSnapshot end
    if S.Api == nil or type(S.Api.IsCapabilityAllowed) ~= "function"
        or S.Api:IsCapabilityAllowed("X2Bag:GetBagItemInfo") ~= true then return nil end

    local maxSlot = math.max(1, math.floor(tonumber(self.bagSlots) or 150))

    local function Scan(bagId)
        local snapshot = {
            bagId = bagId,
            readable = false,
            occupied = 0,
            typedItems = 0,
            counts = {},
            unreliableCounts = {},
            items = {},
        }
        for slot = 1, maxSlot do
            local ok, info = S.Api:CallCapability("X2Bag:GetBagItemInfo", X2Bag, "GetBagItemInfo", bagId, slot)
            if ok then
                snapshot.readable = true
                if type(info) == "table" and next(info) ~= nil then
                    snapshot.occupied = snapshot.occupied + 1
                    local itemType = ExtractBagType(info)
                    local stackCountForItem = ExtractBagCount(info)
                    -- Keep only primitive fields needed by sibling services. We
                    -- never retain the full API table, so bag snapshots remain
                    -- bounded and do not accidentally pin UI/native objects.
                    snapshot.items[#snapshot.items + 1] = {
                        bagId = bagId, slot = slot, itemType = itemType,
                        stackCount = stackCountForItem, name = tostring(info.name or info.itemName or ""),
                        longitudeDir = info.longitudeDir, longitudeDeg = info.longitudeDeg, longitudeMin = info.longitudeMin, longitudeSec = info.longitudeSec,
                        latitudeDir = info.latitudeDir, latitudeDeg = info.latitudeDeg, latitudeMin = info.latitudeMin, latitudeSec = info.latitudeSec,
                    }
                    if itemType ~= nil then
                        snapshot.typedItems = snapshot.typedItems + 1
                        local stackCount = stackCountForItem
                        if stackCount ~= nil then
                            snapshot.counts[itemType] = (snapshot.counts[itemType] or 0) + stackCount
                        else
                            snapshot.unreliableCounts[itemType] = true
                        end
                    end
                end
            end
        end
        snapshot.typeReliable = snapshot.occupied == 0 or snapshot.typedItems == snapshot.occupied
        return snapshot
    end

    -- RU clients expose multiple bag namespaces. ReplicatedGear's current
    -- physical-bag Authority is bagId 0, so probe it first once per world entry.
    -- After a namespace is selected, BAG_UPDATE refreshes scan only that namespace
    -- instead of paying for two full 150-slot scans every time. If the selected
    -- namespace ever becomes unreadable, clear the runtime choice and reprobe.
    local chosen
    local active = tonumber(self.activeBagId)
    if active ~= nil then
        local snapshot = Scan(active)
        if snapshot.readable then
            chosen = snapshot
        else
            self.activeBagId = nil
        end
    end

    if chosen == nil then
        local zero = Scan(0)
        if zero.readable and zero.occupied > 0 and zero.typeReliable == true then
            -- Fast path confirmed by current ReplicatedGear/RU client tests.
            chosen = zero
        else
            -- Only pay for the second namespace when bag 0 is empty or does not
            -- expose a complete itemType table. This preserves the older
            -- correctness fallback without making 300 slot reads the steady
            -- state cost.
            local one = Scan(1)
            local populated = {}
            if zero.occupied > 0 then populated[#populated + 1] = zero end
            if one.occupied > 0 then populated[#populated + 1] = one end
            if #populated > 0 then
                table.sort(populated, function(a, b)
                    if a.typeReliable ~= b.typeReliable then return a.typeReliable == true end
                    local ar = a.occupied > 0 and (a.typedItems / a.occupied) or 0
                    local br = b.occupied > 0 and (b.typedItems / b.occupied) or 0
                    if ar ~= br then return ar > br end
                    if a.typedItems ~= b.typedItems then return a.typedItems > b.typedItems end
                    if a.occupied ~= b.occupied then return a.occupied > b.occupied end
                    return a.bagId == 0 and b.bagId ~= 0
                end)
                chosen = populated[1]
            elseif zero.readable then
                chosen = zero
            elseif one.readable then
                chosen = one
            else
                return nil
            end
        end
        self.activeBagId = chosen.bagId
    end

    self.bagSnapshot = chosen
    self.bagDirty = false
    return chosen
end

function R:ReadItemCountFromSnapshot(snapshot, itemType)
    if snapshot == nil or snapshot.typeReliable ~= true then return nil end
    itemType = tonumber(itemType)
    if itemType == nil then return nil end
    if snapshot.unreliableCounts[itemType] == true then return nil end
    return tonumber(snapshot.counts[itemType]) or 0
end

function R:Refresh()
    self:EnsureDate()

    local snapshot = self:BuildBagSnapshot()
    local bonds = self:ReadItemCountFromSnapshot(snapshot, S.Constants.BlueSaltBondItemType)
    local materialCounts = {}
    for key, itemType in pairs(S.Constants.BondMaterialItemTypes or {}) do
        materialCounts[key] = self:ReadItemCountFromSnapshot(snapshot, itemType)
    end
    local c = S.State.dailyCounters

    -- Labor, currency balance and bag capacity/empty slots are intentionally
    -- unavailable here: their convenience methods are in the supplied RU API
    -- dump's "Available/not allowed" section. We surface "--" until a legal,
    -- verified Authority is identified.
    local resources = {}
    -- Information density order requested by the product UI: daily deltas first,
    -- then authoritative bag resources. Warehouse counts are deliberately not
    -- shown because X2Bank has no allowed read functions in the RU Addon API.
    local function SignedInteger(value)
        local n = math.floor(tonumber(value) or 0)
        if n > 0 then return "+" .. tostring(n) end
        return tostring(n)
    end
    local netGold = tonumber(c.gold) or 0
    local exp = tonumber(c.exp) or 0
    local honor = tonumber(c.honor) or 0
    local vocation = tonumber(c.vocation) or 0
    -- Daily deltas stay grouped at the top. Experience is event-accumulated from
    -- EXP_CHANGED, matching the working RU InfoTracker contract (_, delta).
    resources[#resources + 1] = { name = "今日金币变化", status = S.Utils.FormatCompactMoney(netGold, true), tone = netGold > 0 and "green" or netGold < 0 and "red" or "muted" }
    resources[#resources + 1] = { name = "今日经验获得", status = SignedInteger(exp), tone = exp > 0 and "green" or exp < 0 and "red" or "muted" }
    resources[#resources + 1] = { name = "今日荣誉", status = SignedInteger(honor), tone = honor > 0 and "purple" or honor < 0 and "red" or "muted" }
    resources[#resources + 1] = { name = "今日生活点", status = SignedInteger(vocation), tone = vocation > 0 and "blue" or vocation < 0 and "red" or "muted" }
    if bonds ~= nil then resources[#resources + 1] = { name = "背包中蓝盐债券数量", status = tostring(math.floor(bonds)), tone = "blue" } end
    local materialLabels = { leather = "背包中皮革数量", fabric = "背包中布料数量", lumber = "背包中木材数量", iron = "背包中铁锭数量" }
    for _, key in ipairs({ "leather", "fabric", "lumber", "iron" }) do
        local value = materialCounts[key]
        if value ~= nil then resources[#resources + 1] = { name = materialLabels[key], status = tostring(math.floor(value)), tone = "text" } end
    end
    -- Unsupported values (labor, total money, bag empty slots) are omitted
    -- entirely instead of publishing placeholder rows.
    S.State.data.resources = resources
    S.State.data.summary.bonds = bonds
    S.State.data.bondBoard.materials = materialCounts
    S.State:MarkDirty("resources")
end

function R:AddCounter(name, delta)
    self:EnsureDate()
    local n = tonumber(delta)
    if n == nil then return end
    S.State.dailyCounters[name] = (tonumber(S.State.dailyCounters[name]) or 0) + n
    S.Storage:RequestSave(300)
    self:RequestRefresh(120)
end

function R:AddGoldDelta(delta)
    self:EnsureDate()
    local n = tonumber(delta)
    if n == nil then return end
    -- PLAYER_MONEY and PLAYER_BANK_MONEY are both deltas. Summing both makes a
    -- bank deposit/withdrawal net to zero instead of being misreported as daily
    -- income or expense. This is therefore a net-gold-change counter, not gross
    -- revenue.
    S.State.dailyCounters.gold = (tonumber(S.State.dailyCounters.gold) or 0) + n
    S.Storage:RequestSave(300)
    self:RequestRefresh(120)
end

function R:RequestRefresh(delayMs)
    S.Scheduler:AddTask("resource_debounce", math.max(100, tonumber(delayMs) or 250), function()
        S.Scheduler:RemoveTask("resource_debounce")
        R:Refresh()
    end, true, self, "P2")
end

local function FirstNumeric(...)
    local count = select("#", ...)
    for index = 1, count do
        local value = select(index, ...)
        local n = tonumber(value)
        if n ~= nil then return n end
    end
    return nil
end

function R:Start()
    S.Events:Subscribe("BAG_UPDATE", self, function()
        R.bagDirty = true
        R:RequestRefresh(250)
    end)
    S.Events:Subscribe("ENTERED_WORLD", self, function()
        R.activeBagId = nil
        R.bagSnapshot = nil
        R.bagDirty = true
        R:RequestRefresh(500)
    end)
    S.Events:Subscribe("PLAYER_MONEY", self, function(_, delta) R:AddGoldDelta(delta) end)
    S.Events:Subscribe("PLAYER_BANK_MONEY", self, function(_, delta) R:AddGoldDelta(delta) end)
    S.Events:Subscribe("PLAYER_HONOR_POINT", self, function(_, delta) R:AddCounter("honor", delta) end)
    S.Events:Subscribe("PLAYER_LIVING_POINT", self, function(_, delta) R:AddCounter("vocation", delta) end)
    -- Working RU InfoTracker receives EXP_CHANGED as (ignored, delta).
    S.Events:Subscribe("EXP_CHANGED", self, function(_, first, second, third)
        local delta = FirstNumeric(second, third)
        if delta ~= nil then R:AddCounter("exp", delta) end
    end)
    S.Scheduler:AddTask("resource_safety", S.Constants.Refresh.resourceSafetyMs, function() R:Refresh() end, false, self, "P3")
    local probe = S.State and S.State.dailyCounters or {}
    Diagnostic("info", "DAILY_COUNTERS_RUNTIME_READY", "每日计数 Runtime 已加载", {
        period = tostring(probe.dateKey or "unknown"), gold = tonumber(probe.gold) or 0,
        honor = tonumber(probe.honor) or 0, vocation = tonumber(probe.vocation) or 0, exp = tonumber(probe.exp) or 0,
    })
    self:Refresh()
end
