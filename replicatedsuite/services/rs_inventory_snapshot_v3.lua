------------------------------------------------------------------------
-- Replicated Suite V3 - Inventory Snapshot Service
--
-- Shared, read-only inventory/container Authority used by Feature modules that
-- need a bounded snapshot before an explicit action.  This service deliberately
-- owns only observation and normalization; business rules (blacklists, move
-- direction, user limits, UI state) remain in the consuming Feature.
--
-- Architecture / performance contract:
--   * Never polls on Tick / OnUpdate.
--   * A full scan happens only when a Feature explicitly asks for a snapshot.
--   * Bag physical-slot authority follows the verified GearV3 rule: bagId=1 is
--     preferred, bagId=0 is a bounded fallback only when the preferred view has
--     no readable items.  This prevents each Feature from guessing a bagId.
--   * Native item tables are normalized immediately into detached primitives;
--     callers never retain native return tables between scheduler steps.
--   * One snapshot builds identity/category indexes in the same pass so callers
--     do not rescan the same container merely to answer "does this item exist?".
--   * Slot numbers are locators only.  Stable identity is itemType first, with a
--     conservative name+grade+category fallback when RU omits itemType.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
S.Services = S.Services or {}

local I = {
    Id = "v3.inventory_snapshot",
    version = 1,
    SnapshotContractVersion = 1,
    PhysicalBagAuthorityContractVersion = 1,
    IndexContractVersion = 1,
    presentationBoundary = "service_only",
    PreferredBagId = 1,
    FallbackBagId = 0,
    MaxSlots = 240,
}
S.Services.InventorySnapshotV3 = I

local BagApi = rawget(_G, "X2Bag")
local BankApi = rawget(_G, "X2Bank")
local CofferApi = rawget(_G, "X2Coffer")

local function Call(capability, object, method, ...)
    if S.Api == nil or type(S.Api.CallCapability) ~= "function" then
        return false, nil, "API boundary unavailable"
    end
    return S.Api:CallCapability(capability, object, method, ...)
end

local function Trim(value)
    return (tostring(value or ""):match("^%s*(.-)%s*$")) or ""
end

local function Scalar(value)
    if type(value) ~= "table" then return value end
    for _, key in ipairs({ "value", "id", "type", "itemType", "itemTypeId", "category", "category_id", "count", "amount" }) do
        local child = value[key]
        if type(child) == "number" or type(child) == "string" then return child end
    end
    return nil
end

local function PositiveInteger(value, allowZero)
    local number = tonumber(Scalar(value))
    if number == nil or number ~= number or number ~= math.floor(number) then return nil end
    if allowZero == true then
        if number < 0 then return nil end
    elseif number < 1 then
        return nil
    end
    return math.floor(number)
end

function I:NormalizeItemType(value)
    local number = PositiveInteger(value, false)
    return number ~= nil and tostring(number) or nil
end

function I:NormalizeCategory(value)
    local text = Trim(Scalar(value))
    if text == "" or #text > 64 or text:find("[%c]") ~= nil then return nil end
    return text
end

function I:ExtractItemType(info)
    if type(info) ~= "table" then return nil end
    for _, key in ipairs({ "itemType", "itemTypeId", "typeId", "item_type" }) do
        local value = self:NormalizeItemType(info[key])
        if value ~= nil then return value end
    end
    return nil
end

function I:ExtractCategory(info)
    if type(info) ~= "table" then return nil end
    for _, key in ipairs({ "category_id", "categoryId", "categoryID", "category" }) do
        local value = self:NormalizeCategory(info[key])
        if value ~= nil then return value end
    end
    return nil
end

function I:ExtractGrade(info)
    if type(info) ~= "table" then return nil end
    for _, key in ipairs({ "itemGrade", "grade" }) do
        local value = PositiveInteger(info[key], true)
        if value ~= nil then return value end
    end
    return nil
end

function I:ExtractStack(info)
    if type(info) ~= "table" then return 1 end
    for _, key in ipairs({ "stackCount", "stack", "count", "itemCount", "amount", "stackSize" }) do
        local value = PositiveInteger(info[key], false)
        if value ~= nil then return value end
    end
    return 1
end

function I:StableIdentity(info)
    if type(info) ~= "table" or next(info) == nil then return nil, nil, nil, nil end
    local itemType = self:ExtractItemType(info)
    local category = self:ExtractCategory(info)
    if itemType ~= nil then return "type:" .. tostring(itemType), "type", itemType, category end

    local name = Trim(info.name or info.itemName)
    if name == "" then return nil, nil, nil, category end
    local grade = self:ExtractGrade(info)
    return table.concat({ "fallback", name, tostring(grade or ""), tostring(category or "") }, "\31"), "fallback", nil, category
end

function I:NormalizeRow(slot, info, bagId)
    if type(info) ~= "table" or next(info) == nil then return nil end
    local identity, identityMode, itemType, category = self:StableIdentity(info)
    return {
        slot = math.max(1, math.floor(tonumber(slot) or 1)),
        bagId = bagId ~= nil and math.floor(tonumber(bagId) or 0) or nil,
        identity = identity,
        identityMode = identityMode,
        itemType = itemType,
        category = category,
        grade = self:ExtractGrade(info),
        stack = self:ExtractStack(info),
        name = Trim(info.name or info.itemName),
    }
end

function I:ScopeReader(scope)
    if scope == "bag" then
        return "X2Bag:Capacity", "X2Bag:GetBagItemInfo", BagApi, "Capacity", "GetBagItemInfo", true
    elseif scope == "bank" then
        return "X2Bank:Capacity", "X2Bank:GetBagItemInfo", BankApi, "Capacity", "GetBagItemInfo", false
    elseif scope == "coffer" then
        return "X2Coffer:Capacity", "X2Coffer:GetBagItemInfo", CofferApi, "Capacity", "GetBagItemInfo", false
    end
    return nil
end

function I:ReadCapacity(scope, requestedMax)
    local capCapability, _, object, capMethod = self:ScopeReader(scope)
    if capCapability == nil then return nil, "未知容器" end
    local ok, capacity, err = Call(capCapability, object, capMethod)
    capacity = tonumber(capacity)
    if ok ~= true or capacity == nil or capacity ~= capacity or capacity < 0 then
        return nil, "容量不可读：" .. tostring(err or scope)
    end
    capacity = math.floor(capacity)
    local maxSlots = math.max(1, math.min(self.MaxSlots, math.floor(tonumber(requestedMax) or self.MaxSlots)))
    return math.min(capacity, maxSlots), nil, capacity > maxSlots, capacity
end

function I:ReadSlot(scope, slot, bagId)
    slot = PositiveInteger(slot, false)
    if slot == nil then return false, nil, "槽位必须是正整数" end
    local _, readCapability, object, _, readMethod, bagFirst = self:ScopeReader(scope)
    if readCapability == nil then return false, nil, "未知容器" end
    if bagFirst == true then
        bagId = math.floor(tonumber(bagId) or self.PreferredBagId)
        return Call(readCapability, object, readMethod, bagId, slot)
    end
    return Call(readCapability, object, readMethod, slot)
end

-- Single-slot helper for explicit UI actions.  Prefer the physical bag view used
-- by GearV3, but if that exact locator is unreadable/empty, probe the bounded
-- compatibility view once.  This is not a scan and never runs on a timer.
function I:ReadPhysicalBagSlot(slot, bagIdHint)
    local preferredId = math.floor(tonumber(bagIdHint) or self.PreferredBagId)
    local ok, info, err = self:ReadSlot("bag", slot, preferredId)
    if ok == true and type(info) == "table" and next(info) ~= nil then
        return true, info, nil, preferredId
    end
    local fallbackId = preferredId == self.FallbackBagId and self.PreferredBagId or self.FallbackBagId
    local fallbackOk, fallbackInfo, fallbackErr = self:ReadSlot("bag", slot, fallbackId)
    if fallbackOk == true and type(fallbackInfo) == "table" and next(fallbackInfo) ~= nil then
        return true, fallbackInfo, nil, fallbackId
    end
    if ok == true then return true, info, nil, preferredId end
    if fallbackOk == true then return true, fallbackInfo, nil, fallbackId end
    return false, nil, tostring(err or fallbackErr or "背包槽位读取失败"), preferredId
end

function I:_BuildScopeWithBagId(scope, bagId, requestedMax)
    local scanSlots, capacityErr, truncated, physicalCapacity = self:ReadCapacity(scope, requestedMax)
    if scanSlots == nil then return nil, capacityErr end
    local snapshot = {
        scope = scope,
        bagId = scope == "bag" and bagId or nil,
        capacity = physicalCapacity,
        scannedSlots = scanSlots,
        truncated = truncated == true,
        occupied = 0,
        typed = 0,
        fallback = 0,
        unknown = 0,
        readErrors = 0,
        firstReadError = nil,
        rows = {},
        identitySet = {},
        identityCount = {},
        identityStack = {},
        categoryCount = {},
        categoryStack = {},
    }
    for slot = 1, scanSlots do
        local ok, info, err = self:ReadSlot(scope, slot, bagId)
        if ok ~= true then
            snapshot.readErrors = snapshot.readErrors + 1
            snapshot.firstReadError = snapshot.firstReadError or tostring(err or "read failed")
        elseif type(info) == "table" and next(info) ~= nil then
            snapshot.occupied = snapshot.occupied + 1
            local row = self:NormalizeRow(slot, info, bagId)
            if row ~= nil then
                snapshot.rows[#snapshot.rows + 1] = row
                if row.identityMode == "type" then snapshot.typed = snapshot.typed + 1
                elseif row.identityMode == "fallback" then snapshot.fallback = snapshot.fallback + 1
                else snapshot.unknown = snapshot.unknown + 1 end
                if row.identity ~= nil then
                    snapshot.identitySet[row.identity] = true
                    snapshot.identityCount[row.identity] = (tonumber(snapshot.identityCount[row.identity]) or 0) + 1
                    snapshot.identityStack[row.identity] = (tonumber(snapshot.identityStack[row.identity]) or 0) + (tonumber(row.stack) or 1)
                end
                if row.category ~= nil then
                    snapshot.categoryCount[row.category] = (tonumber(snapshot.categoryCount[row.category]) or 0) + 1
                    snapshot.categoryStack[row.category] = (tonumber(snapshot.categoryStack[row.category]) or 0) + (tonumber(row.stack) or 1)
                end
            end
        end
    end
    return snapshot
end

function I:BuildSnapshot(scope, options)
    options = type(options) == "table" and options or {}
    local requestedMax = tonumber(options.maxSlots) or self.MaxSlots
    if scope ~= "bag" then return self:_BuildScopeWithBagId(scope, nil, requestedMax) end

    local preferredId = math.floor(tonumber(options.bagId) or self.PreferredBagId)
    local preferred, preferredErr = self:_BuildScopeWithBagId("bag", preferredId, requestedMax)
    if preferred ~= nil and #preferred.rows > 0 then
        preferred.fallbackUsed = false
        return preferred
    end

    local fallbackId = preferredId == self.FallbackBagId and self.PreferredBagId or self.FallbackBagId
    local fallback, fallbackErr = self:_BuildScopeWithBagId("bag", fallbackId, requestedMax)
    if fallback ~= nil and #fallback.rows > 0 then
        fallback.fallbackUsed = true
        fallback.preferredBagId = preferredId
        fallback.preferredReadErrors = preferred and preferred.readErrors or nil
        fallback.preferredError = preferredErr
        return fallback
    end

    if fallback ~= nil and preferred ~= nil then
        if (tonumber(fallback.readErrors) or 0) < (tonumber(preferred.readErrors) or 0) then
            fallback.fallbackUsed = true
            fallback.preferredBagId = preferredId
            return fallback
        end
        preferred.fallbackUsed = false
        return preferred
    end
    return preferred or fallback, preferredErr or fallbackErr
end

-- Live resolver used by serialized write workflows. `startSlot` is only a scan
-- hint, never identity: we check it first, then wrap once through the bounded
-- physical container. This makes the common post-compaction case O(1) while
-- preserving correctness when the client sorted or compacted elsewhere.
function I:FindLiveRow(scope, matcher, options)
    if type(matcher) ~= "function" then return nil, nil, "匹配器不可用" end
    options = type(options) == "table" and options or {}
    local scanSlots, err = self:ReadCapacity(scope, options.maxSlots)
    if scanSlots == nil then return nil, nil, err end
    local bagId = scope == "bag" and math.floor(tonumber(options.bagId) or self.PreferredBagId) or nil
    local startSlot = math.max(1, math.min(scanSlots, math.floor(tonumber(options.startSlot) or 1)))

    local function Probe(slot)
        local ok, info, readErr = self:ReadSlot(scope, slot, bagId)
        if ok ~= true then return nil, "read_error:" .. tostring(readErr or "unknown") end
        local row = self:NormalizeRow(slot, info, bagId)
        if row ~= nil and matcher(row, info) == true then return row, nil end
        return false, nil
    end

    local readErrors = 0
    for slot = startSlot, scanSlots do
        local row, readErr = Probe(slot)
        if type(row) == "table" then return row, nil, nil end
        if type(readErr) == "string" then readErrors = readErrors + 1 end
    end
    if startSlot > 1 then
        for slot = 1, startSlot - 1 do
            local row, readErr = Probe(slot)
            if type(row) == "table" then return row, nil, nil end
            if type(readErr) == "string" then readErrors = readErrors + 1 end
        end
    end
    if readErrors > 0 then return nil, nil, "源容器有槽位读取失败，已安全停止" end
    return nil, nil, "没有剩余可移动的匹配物品"
end

-- Count only when a post-write slot remains ambiguous. `stopAt` allows the
-- no-progress case to short-circuit as soon as the previous population has been
-- observed, avoiding an unconditional full rescan after every move.
function I:CountLive(scope, matcher, options)
    if type(matcher) ~= "function" then return nil, "匹配器不可用" end
    options = type(options) == "table" and options or {}
    local scanSlots, err = self:ReadCapacity(scope, options.maxSlots)
    if scanSlots == nil then return nil, err end
    local bagId = scope == "bag" and math.floor(tonumber(options.bagId) or self.PreferredBagId) or nil
    local stopAt = tonumber(options.stopAt)
    if stopAt ~= nil then stopAt = math.max(1, math.floor(stopAt)) end
    local count, readErrors = 0, 0
    for slot = 1, scanSlots do
        local ok, info = self:ReadSlot(scope, slot, bagId)
        if ok ~= true then
            readErrors = readErrors + 1
        else
            local row = self:NormalizeRow(slot, info, bagId)
            if row ~= nil and matcher(row, info) == true then
                count = count + 1
                if stopAt ~= nil and count >= stopAt then return count, nil, true end
            end
        end
    end
    if readErrors > 0 then return nil, "源容器有槽位读取失败，无法确认移动结果" end
    return count, nil, false
end

function I:Describe()
    return {
        version = self.version,
        preferredBagId = self.PreferredBagId,
        fallbackBagId = self.FallbackBagId,
        maxSlots = self.MaxSlots,
        contract = "explicit bounded snapshots; single-pass indexes; bagId=1 authority with bagId=0 fallback; no polling",
    }
end
