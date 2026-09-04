------------------------------------------------------------------------
-- Replicated Suite V3 - remaining business Feature authorities
--
-- This is a collection of small, explicit authorities, not a generic
-- placeholder.  Each spec below names its data source and normalizes a bounded
-- projection.  Features whose RU contract is still unprovable remain live as
-- an honest Runtime Blocked projection, so they no longer masquerade as
-- planned while consuming zero game APIs.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local P, Runtime, Demand = S.Persistence, S.FeatureRuntime, S.Demand
if type(P) ~= "table" or type(Runtime) ~= "table" or type(Demand) ~= "table" then return end
local UnitApi = rawget(_G, "X2Unit")
local TeamApi = rawget(_G, "X2Team")
local AuctionApi = rawget(_G, "X2Auction")
local BagApi = rawget(_G, "X2Bag")
local BankApi = rawget(_G, "X2Bank")
local CofferApi = rawget(_G, "X2Coffer")
local AddonApi = rawget(_G, "ADDON")
local FriendApi = rawget(_G, "X2Friend")
local CraftApi = rawget(_G, "X2Craft")
local ReinforceApi = rawget(_G, "X2EquipSlotReinforce")
local OptionApi = rawget(_G, "X2Option")

S.Features = S.Features or {}
local function Copy(value, seen)
    if S.Utils and type(S.Utils.DeepCopy) == "function" then return S.Utils.DeepCopy(value) end
    if type(value) ~= "table" then return value end
    seen = seen or {}
    if seen[value] ~= nil then return seen[value] end
    local out = {}; seen[value] = out
    for key, child in pairs(value) do out[Copy(key, seen)] = Copy(child, seen) end
    return out
end
local function Call(capability, object, method, ...)
    if S.Api == nil or type(S.Api.CallCapability) ~= "function" then return false, nil, "API boundary unavailable" end
    return S.Api:CallCapability(capability, object, method, ...)
end
local function Action(capability, object, method, ...)
    if S.Api == nil or type(S.Api.ActionCapability) ~= "function" then return false, "API boundary unavailable" end
    return S.Api:ActionCapability(capability, object, method, ...)
end
local function RegisterStore(id, owner, default, get, apply)
    if P:GetStore(id) == nil then
        local store, err = P:RegisterV3Store({ id = id, owner = owner, scope = P.Scope.Account, lifetime = P.Lifetime.Permanent,
            schemaVersion = 1, legacySchemaVersion = 0, key = P.V3KeyPrefix .. id:gsub("[^%w]", "_"),
            budget = { maxDepth = 5, maxNodes = 240, maxStringBytes = 4096, maxEntriesPerTable = 96 },
            default = default, get = get, apply = apply, migrate = function(value) return value end })
        if store == nil then error(err or id .. " store register failed") end
    end
end
local function Load(feature)
    if feature.storeLoaded then return true end
    local status, _, err = P:LoadStore(feature.storeId)
    if status ~= true and status ~= "empty" then return false, err or tostring(status or "store load failed") end
    feature.storeLoaded = true
    return true
end
local function Text(value, fallback) return value == nil and (fallback or "") or tostring(value) end
local function Number(value) local n = tonumber(value); return n and n == n and n or nil end
local function TeamCommandInteger(value, label, maximum)
    local number = Number(value)
    if number == nil or number < 1 or number > maximum or number ~= math.floor(number) then
        return nil, label .. " 必须是 1-" .. tostring(maximum) .. " 的正整数"
    end
    return math.floor(number)
end
local BAG_SCAN_LIMIT = 240
local BLACKLIST_MAX_ENTRIES = 64
local BATCH_DEFAULT_LIMIT = 20
local BATCH_MAX_MOVES = 40
local BAG_BATCH_TASK = "v3_business_bag_category_batch"
local BAG_QUICK_OBSERVE_TASK = "v3_business_bag_quick_observe"
local BAG_QUICK_MOVE_TASK = "v3_business_bag_quick_move"
local BAG_QUICK_LIMIT = 40

-- The active V3 contract can safely observe the native bag window, but it
-- does not prove a supported native parent/embedding operation. Keep this
-- diagnostic read-only and fail closed when any part of the getter contract
-- is unavailable or malformed.
local function ReadBagWindowContext()
    local context = { status = "unknown", visible = nil, follow = "diagnostic_only", embed = "fail_closed", reason = nil }
    local addonApi = AddonApi or rawget(_G, "ADDON")
    local bagContentId = rawget(_G, "UIC_BAG")
    if addonApi == nil or bagContentId == nil then context.reason = "ADDON/UIC_BAG 不可用"; return context end
    if S.Api == nil or type(S.Api.IsCapabilityAllowed) ~= "function"
        or S.Api:IsCapabilityAllowed("ADDON:GetContentMainScriptPosVis") ~= true then
        context.reason = "原生窗口可见性 API 未获能力许可"; return context
    end
    if type(addonApi.GetContentMainScriptPosVis) ~= "function" then
        context.reason = "原生窗口可见性 getter 不可用"; return context
    end
    local ok, x, y, width, height, visible = pcall(function()
        return addonApi:GetContentMainScriptPosVis(bagContentId)
    end)
    x, y, width, height = Number(x), Number(y), Number(width), Number(height)
    if ok ~= true or x == nil or y == nil or width == nil or height == nil or type(visible) ~= "boolean" then
        context.reason = "原生窗口几何/可见性返回值未知"; return context
    end
    local layoutContext = S.Layout ~= nil and type(S.Layout.GetContext) == "function" and S.Layout:GetContext() or {}
    local logicalWidth = tonumber(layoutContext.logicalWidth) or 1024
    local logicalHeight = tonumber(layoutContext.logicalHeight) or 768
    if width <= 0 or height <= 0 or width > logicalWidth * 2 or height > logicalHeight * 2
        or x < -width or y < -height or x > logicalWidth + width or y > logicalHeight + height then
        context.reason = "原生窗口几何超出安全范围"; return context
    end
    context.status, context.visible = "ready", visible
    context.x, context.y, context.width, context.height = x, y, width, height
    return context
end

local function ReadStorageWindowContext(target)
    local addonApi = AddonApi or rawget(_G, "ADDON")
    local contentId = target == "bank" and rawget(_G, "UIC_BANK") or target == "coffer" and rawget(_G, "UIC_COFFER") or nil
    if addonApi == nil or contentId == nil or type(addonApi.GetContentMainScriptPosVis) ~= "function" then return nil end
    if S.Api == nil or type(S.Api.IsCapabilityAllowed) ~= "function" or S.Api:IsCapabilityAllowed("ADDON:GetContentMainScriptPosVis") ~= true then return nil end
    local ok, x, y, width, height, visible = pcall(function() return addonApi:GetContentMainScriptPosVis(contentId) end)
    x,y,width,height = Number(x),Number(y),Number(width),Number(height)
    if ok~=true or x==nil or y==nil or width==nil or height==nil or type(visible)~="boolean" or width<=0 or height<=0 then return nil end
    return { kind=target, x=x, y=y, width=width, height=height, visible=visible }
end

local function CurrentStorageContext()
    local bank = ReadStorageWindowContext("bank")
    if type(bank)=="table" and bank.visible==true then return bank end
    local coffer = ReadStorageWindowContext("coffer")
    if type(coffer)=="table" and coffer.visible==true then return coffer end
    return nil
end

local function RequireStorageWindow(target)
    local addonApi = AddonApi or rawget(_G, "ADDON")
    local contentId = target == "bank" and rawget(_G, "UIC_BANK") or target == "coffer" and rawget(_G, "UIC_COFFER") or nil
    if addonApi == nil or contentId == nil then return false, "仓储窗口标识不可用，已安全拒绝" end
    if S.Api == nil or type(S.Api.IsCapabilityAllowed) ~= "function"
        or S.Api:IsCapabilityAllowed("ADDON:GetContentMainScriptPosVis") ~= true then
        return false, "仓储窗口可见性 API 未获能力许可，已安全拒绝"
    end
    if type(addonApi.GetContentMainScriptPosVis) ~= "function" then return false, "仓储窗口可见性 getter 不可用，已安全拒绝" end
    local ok, _, _, width, height, visible = pcall(function()
        return addonApi:GetContentMainScriptPosVis(contentId)
    end)
    width, height = Number(width), Number(height)
    if ok ~= true or width == nil or height == nil or width <= 0 or height <= 0 or type(visible) ~= "boolean" then
        return false, "仓储窗口可见性/几何返回值未知，已安全拒绝"
    end
    if visible ~= true then return false, "请先打开对应的银行/箱子窗口；窗口状态无法确认时安全拒绝" end
    return true
end

local function Trim(value)
    return (tostring(value or ""):match("^%s*(.-)%s*$")) or ""
end

local function Scalar(value)
    if type(value) ~= "table" then return value end
    for _, key in ipairs({ "value", "id", "type", "itemType", "itemTypeId", "category", "category_id" }) do
        local child = value[key]
        if type(child) == "number" or type(child) == "string" then return child end
    end
    return nil
end

local function NormalizeBoolean(value)
    if value == true or value == 1 then return true end
    if value == false or value == 0 then return false end
    local text = Trim(value):lower()
    if text == "true" or text == "on" or text == "enabled" or text == "1" then return true end
    if text == "false" or text == "off" or text == "disabled" or text == "0" or text == "" then return false end
    return nil
end

local function NormalizeScope(value)
    if value == 1 or Trim(value):lower() == "bank" then return "bank" end
    if value == 2 or Trim(value):lower() == "coffer" then return "coffer" end
    return nil
end

local function NormalizeItemType(value)
    local raw = Scalar(value)
    if type(raw) == "number" then
        if raw ~= raw or raw < 1 or raw ~= math.floor(raw) then return nil end
        return tostring(math.floor(raw))
    end
    local text = Trim(raw)
    if text == "" or not text:match("^%d+$") then return nil end
    local number = tonumber(text)
    if number == nil or number < 1 or number ~= math.floor(number) then return nil end
    return tostring(math.floor(number))
end

local function NormalizeCategory(value)
    local text = Trim(Scalar(value))
    if text == "" or #text > 64 or text:find("[%c]") ~= nil then return nil end
    return text
end

local function IsEnabledMarker(value)
    if value == true or value == 1 then return true end
    local text = Trim(value):lower()
    return text == "true" or text == "on" or text == "1"
end

local function NormalizeMap(source, normalizer)
    local candidates, seen = {}, {}
    if type(source) ~= "table" then return {} end
    for key, value in pairs(source) do
        local candidate = IsEnabledMarker(value) and key or value
        local normalized = normalizer(candidate)
        if normalized ~= nil and not seen[normalized] then
            seen[normalized] = true
            candidates[#candidates + 1] = normalized
        end
    end
    table.sort(candidates)
    local output = {}
    for index = 1, math.min(BLACKLIST_MAX_ENTRIES, #candidates) do output[candidates[index]] = true end
    return output
end

local function ScopeSource(source, scope, index)
    if type(source) ~= "table" then return {} end
    if type(source[scope]) == "table" then return source[scope] end
    if type(source[index]) == "table" then return source[index] end
    return {}
end

local function FirstMap(source, keys)
    local empty
    for _, key in ipairs(keys) do
        if type(source) == "table" and type(source[key]) == "table" then
            empty = empty or source[key]
            if next(source[key]) ~= nil then return source[key] end
        end
    end
    return empty or {}
end

local function NormalizeBlacklist(value)
    local source = type(value) == "table" and value or {}
    local normalized = {
        enabled = NormalizeBoolean(source.enabled) == true,
        activeScope = NormalizeScope(source.activeScope) or "bank",
        bank = { itemType = {}, category = {} },
        coffer = { itemType = {}, category = {} },
    }
    for scope, index in pairs({ bank = 1, coffer = 2 }) do
        local sourceScope = ScopeSource(source, scope, index)
        normalized[scope].itemType = NormalizeMap(FirstMap(sourceScope, { "itemType", "itemTypes", "items" }), NormalizeItemType)
        normalized[scope].category = NormalizeMap(FirstMap(sourceScope, { "category", "categories" }), NormalizeCategory)
    end
    return normalized
end

local function BlacklistDefault()
    return NormalizeBlacklist({ enabled = false })
end

local function ApplyBlacklistState(value, state)
    local source = type(value) == "table" and value.blacklist or value
    state.blacklist = NormalizeBlacklist(source)
end

local function BlacklistEntryCount(config)
    local total = 0
    for _, scope in ipairs({ "bank", "coffer" }) do
        local bucket = type(config) == "table" and config[scope] or nil
        for _, field in ipairs({ "itemType", "category" }) do
            for _ in pairs(type(bucket) == "table" and bucket[field] or {}) do total = total + 1 end
        end
    end
    return total
end

local function MutateBlacklist(feature, reason, mutator)
    if type(P.MutateStore) ~= "function" then return false, "黑名单持久化事务不可用" end
    local marked, mutationErr, changed = P:MutateStore(feature.storeId, function()
        local result, changedOrError = mutator(feature.State.blacklist)
        if result ~= true then return false, tostring(changedOrError or "黑名单修改失败") end
        return true, nil, changedOrError == true
    end, { delayMs = 300, reason = tostring(reason or "blacklist_changed") })
    if marked ~= true then return false, tostring(mutationErr or "黑名单未保存，已回滚") end
    return true, nil, changed
end

local function ReadItemField(info, keys, normalizer)
    if type(info) ~= "table" then return nil end
    for _, key in ipairs(keys) do
        local value = normalizer(info[key])
        if value ~= nil then return value end
    end
    return nil
end

local function SourceIdentity(info)
    return ReadItemField(info, { "itemType", "itemTypeId", "typeId", "item_type" }, NormalizeItemType),
        ReadItemField(info, { "category_id", "categoryId", "categoryID", "category" }, NormalizeCategory)
end

local function ReadMoveSource(scope, slot)
    local capability, object, method, firstArg
    if scope == "bank" then
        capability, object, method = "X2Bank:GetBagItemInfo", BankApi, "GetBagItemInfo"
    elseif scope == "coffer" then
        capability, object, method = "X2Coffer:GetBagItemInfo", CofferApi, "GetBagItemInfo"
    else
        return nil, "黑名单检查失败：未知仓储范围"
    end
    if scope == "bank" or scope == "coffer" then
        firstArg = slot
    end
    return Call(capability, object, method, firstArg)
end

local function MapContains(map, key)
    return type(map) == "table" and key ~= nil and (map[key] == true or map[tostring(key)] == true)
end

local function HasRules(map)
    return type(map) == "table" and next(map) ~= nil
end

local SourceSlot

local function CheckBlacklist(feature, scope, info)
    local config = feature.State.blacklist
    if type(config) ~= "table" or config.enabled ~= true then return true end
    local bucket = config[scope]
    if type(bucket) ~= "table" then return true end
    local itemType, category = SourceIdentity(info)
    local scopeName = scope == "bank" and "银行" or (scope == "coffer" and "箱子" or tostring(scope))
    local itemRules, categoryRules = bucket.itemType, bucket.category
    if HasRules(itemRules) and itemType == nil then return false, "已拒绝：物品编号不可读，黑名单检查失败" end
    if HasRules(categoryRules) and category == nil then return false, "已拒绝：类别编号不可读，黑名单检查失败" end
    if MapContains(itemRules, itemType) then return false, "已拒绝：命中 " .. scopeName .. " 物品编号黑名单（" .. tostring(itemType) .. "）" end
    if MapContains(categoryRules, category) then return false, "已拒绝：命中 " .. scopeName .. " 类别编号黑名单（" .. tostring(category) .. "）" end
    return true
end

local function GuardedMove(feature, sourceScope, blacklistScope, capability, object, method, slot)
    local sourceSlot, slotErr = SourceSlot(slot)
    if sourceSlot == nil then return false, slotErr end
    local callOk, item, readErr
    if sourceScope == "bag" then
        callOk, item, readErr = Call("X2Bag:GetBagItemInfo", BagApi, "GetBagItemInfo", 0, sourceSlot)
    elseif sourceScope == "bank" or sourceScope == "coffer" then
        callOk, item, readErr = ReadMoveSource(sourceScope, sourceSlot)
    else
        return false, "黑名单检查失败：未知源容器"
    end
    if callOk ~= true or type(item) ~= "table" or next(item) == nil then
        return false, "黑名单检查失败：源槽位物品读取失败（" .. tostring(readErr or "空或不可读") .. "）"
    end
    if blacklistScope ~= "bank" and blacklistScope ~= "coffer" then return false, "黑名单检查失败：未知策略范围" end
    local allowed, blockErr = CheckBlacklist(feature, blacklistScope, item)
    if allowed ~= true then return false, blockErr end
    return Action(capability, object, method, sourceSlot)
end
SourceSlot = function(value)
    local slot = Number(value)
    if slot == nil or slot < 1 or slot ~= math.floor(slot) then return nil, "源槽位必须是正整数" end
    return slot
end
local function BagQuickRunning(feature)
    if type(feature) ~= "table" then return false end
    if feature._quickQueue ~= nil or feature._quickPending ~= nil then return true end
    local overlay = feature._quickOverlay
    local status = type(overlay) == "table" and tostring(overlay.status or "") or ""
    return status == "正在取出" or status == "正在放入"
end

local function BagBatchRunning(feature)
    return type(feature) == "table" and type(feature.State) == "table"
        and type(feature.State.batch) == "table" and feature.State.batch.status == "running"
end

local function CheckedMove(feature, sourceScope, blacklistScope, capability, object, method, slot)
    if BagQuickRunning(feature) then return false, "快捷取放正在运行，请先停止" end
    if BagBatchRunning(feature) then return false, "类别批量整理正在运行，请先停止" end
    return GuardedMove(feature, sourceScope, blacklistScope, capability, object, method, slot)
end

local function NormalizeBatchLimit(value)
    local n = Number(value)
    if n == nil or n < 1 or n ~= math.floor(n) then return nil end
    return math.min(BATCH_MAX_MOVES, math.floor(n))
end

local function ApplyBagState(value, state)
    ApplyBlacklistState(value, state)
    local source = type(value) == "table" and value or {}
    state.batchCategory = NormalizeCategory(source.batchCategory)
    state.batchTarget = NormalizeScope(source.batchTarget) or "bank"
    state.batchLimit = NormalizeBatchLimit(source.batchLimit) or BATCH_DEFAULT_LIMIT
    state.batch = { status = "idle", moved = 0, skipped = 0, queued = 0, error = nil }
end

local function BagCategoryLabel(value)
    local names = S.Data and S.Data.CategoryNames or nil
    if type(names) == "table" and type(names.Name) == "function" then
        local ok, label = pcall(names.Name, value)
        if ok == true and type(label) == "string" and label ~= "" then return label end
    end
    return "类别 " .. tostring(value or "?")
end

local function BatchProjection(feature)
    local windowContext = ReadBagWindowContext()
    local categoryOptions, seen = {}, {}
    for _, row in ipairs(type(feature.Authority) == "table" and type(feature.Authority.rows) == "table" and feature.Authority.rows or {}) do
        local category = row and row.category
        if category ~= nil then
            local key = tostring(category)
            if seen[key] ~= true then
                seen[key] = true
                categoryOptions[#categoryOptions + 1] = { value = key, text = BagCategoryLabel(category) .. "（" .. key .. "）" }
            end
        end
    end
    table.sort(categoryOptions, function(a, b) return tostring(a.text or "") < tostring(b.text or "") end)
    return { blacklist = feature.State.blacklist, batchCategory = feature.State.batchCategory,
        batchTarget = feature.State.batchTarget, batchLimit = feature.State.batchLimit,
        batch = feature.State.batch, batchCategoryOptions = categoryOptions,
        windowContext = windowContext,
        quickOverlay = Copy(feature._quickOverlay or { visible=false, storageKind=nil, status="等待仓库/箱子", moved=0, queued=0 }),
        quickButtons = {
            mode = "native_window_follow_v3", status = "ready", requiresSourceSlot = false,
            reason = "打开银行/箱子时在背包上方提供取/放；显式点击才扫描物品",
            actions = { "QuickWithdraw", "QuickDeposit", "QuickCancel" },
        }, }
end
local PersistStateMutation

local function SetBatchConfig(feature, category, target, limit)
    category, target, limit = NormalizeCategory(category), NormalizeScope(target), NormalizeBatchLimit(limit)
    if category == nil or target == nil or limit == nil then return false, "批量设置无效" end
    return PersistStateMutation(feature, "bag_category_batch_settings", function(state)
        state.batchCategory, state.batchTarget, state.batchLimit = category, target, limit
        return true
    end)
end

local function SetBatchCategory(feature, category)
    category = NormalizeCategory(category)
    if category == nil then return false, "请选择有效的物品类别" end
    return PersistStateMutation(feature, "bag_category_batch_category", function(state) state.batchCategory = category; return true end)
end

local function SetBatchTarget(feature, target)
    target = NormalizeScope(target)
    if target == nil then return false, "整理目标必须是银行或箱子" end
    return PersistStateMutation(feature, "bag_category_batch_target", function(state) state.batchTarget = target; return true end)
end

local function SetBatchLimit(feature, limit)
    limit = NormalizeBatchLimit(limit)
    if limit == nil then return false, "最多移动数量必须是 1-40 的整数" end
    return PersistStateMutation(feature, "bag_category_batch_limit", function(state) state.batchLimit = limit; return true end)
end
local function IsEmptyBagInfo(info)
    return type(info) == "table" and next(info) == nil
end

local function StopBagBatch(feature, status, errorText)
    if S.Scheduler ~= nil and type(S.Scheduler.RemoveTask) == "function" then S.Scheduler:RemoveTask(BAG_BATCH_TASK) end
    feature._batchQueue, feature._batchIndex, feature._batchTarget, feature._batchPending, feature._batchSourceCount = nil, nil, nil, nil, nil
    feature.State.batch = type(feature.State.batch) == "table" and feature.State.batch or { moved = 0, skipped = 0, queued = 0 }
    feature.State.batch.status = status or "stopped"
    feature.State.batch.error = errorText
    return true
end

local function PublishBagOverlay(feature, reason)
    if S.Events ~= nil and type(S.Events.Publish)=="function" then
        S.Events:Publish(feature.UpdateTopic, feature.Authority.revision, tostring(reason or "bag_overlay"))
    end
end

local function StopBagQuick(feature, status, errorText)
    if S.Scheduler ~= nil and type(S.Scheduler.RemoveTask)=="function" then S.Scheduler:RemoveTask(BAG_QUICK_MOVE_TASK) end
    feature._quickQueue, feature._quickIndex, feature._quickPending, feature._quickSourceCounts = nil, nil, nil, nil
    feature._quickOverlay = type(feature._quickOverlay)=="table" and feature._quickOverlay or {}
    feature._quickOverlay.status = status or "停止"
    feature._quickOverlay.error = errorText
    feature._quickOverlay.queued = 0
    PublishBagOverlay(feature,"bag_quick_stop")
    return true
end

local BagMoveRuntime = {}

function BagMoveRuntime.ScopeReader(scope)
    if scope == "bag" then
        return "X2Bag:Capacity", "X2Bag:GetBagItemInfo", BagApi, "Capacity", "GetBagItemInfo", true
    elseif scope == "bank" then
        return "X2Bank:Capacity", "X2Bank:GetBagItemInfo", BankApi, "Capacity", "GetBagItemInfo", false
    elseif scope == "coffer" then
        return "X2Coffer:Capacity", "X2Coffer:GetBagItemInfo", CofferApi, "Capacity", "GetBagItemInfo", false
    end
    return nil
end

function BagMoveRuntime.ReadScopeSlot(scope, slot)
    local _, readCapability, object, _, readMethod, bagFirst = BagMoveRuntime.ScopeReader(scope)
    if readCapability == nil then return false, nil, "未知容器" end
    if bagFirst then return Call(readCapability, object, readMethod, 0, slot) end
    return Call(readCapability, object, readMethod, slot)
end

function BagMoveRuntime.ReadScopeCapacity(scope)
    local capCapability, _, object, capMethod = BagMoveRuntime.ScopeReader(scope)
    if capCapability == nil then return nil, "未知容器" end
    local ok, capacity, err = Call(capCapability, object, capMethod)
    capacity = Number(capacity)
    if ok ~= true or capacity == nil or capacity < 0 then return nil, "容量不可读：" .. tostring(err or scope) end
    capacity = math.floor(capacity)
    return math.min(BAG_SCAN_LIMIT, capacity), nil, capacity > BAG_SCAN_LIMIT
end

local function BagIdentitySet(scope)
    local set, rows, readErrors, counts = {}, {}, 0, {}
    local capacity, capacityErr = BagMoveRuntime.ReadScopeCapacity(scope)
    if capacity == nil then return nil,nil,1,capacityErr,nil end
    for slot=1,capacity do
        local ok, info = BagMoveRuntime.ReadScopeSlot(scope, slot)
        if ok~=true then readErrors=readErrors+1
        elseif type(info)=="table" and next(info)~=nil then
            local itemType=SourceIdentity(info)
            if itemType~=nil then
                set[itemType]=true
                counts[itemType]=(tonumber(counts[itemType]) or 0)+1
                rows[#rows+1]={slot=slot,itemType=itemType,info=info}
            end
        end
    end
    if readErrors>0 then return set,rows,readErrors,"有槽位读取失败",counts end
    return set,rows,0,nil,counts
end

-- MoveToEmpty* can cause the client to compact/reproject bag slots. Slot numbers
-- are therefore a transient locator, never item identity. Quick/batch plans keep
-- stable itemType/category intent and resolve the live source slot immediately
-- before each write. This prevents a successful first move from invalidating the
-- rest of a precomputed slot queue.
function BagMoveRuntime.FindLiveMoveSource(feature, sourceScope, blacklistScope, itemType, category)
    local capacity, capacityErr = BagMoveRuntime.ReadScopeCapacity(sourceScope)
    if capacity == nil then return nil, nil, capacityErr end
    local readErrors = 0
    for slot = 1, capacity do
        local ok, info = BagMoveRuntime.ReadScopeSlot(sourceScope, slot)
        if ok ~= true then
            readErrors = readErrors + 1
        elseif type(info) == "table" and next(info) ~= nil then
            local currentType, currentCategory = SourceIdentity(info)
            local identityMatch = itemType ~= nil and currentType == itemType or itemType == nil and currentCategory == category
            if identityMatch then
                local allowed, deny = CheckBlacklist(feature, blacklistScope, info)
                if allowed == true then return slot, info, nil end
                if deny ~= nil then -- keep scanning: another same-category row may still be allowed
                    -- no-op; deny is intentionally row-local
                end
            end
        end
    end
    if readErrors > 0 then return nil, nil, "源容器有槽位读取失败，已安全停止" end
    return nil, nil, "没有剩余可移动的匹配物品"
end

function BagMoveRuntime.CountLiveMatches(scope, itemType, category)
    local capacity, capacityErr = BagMoveRuntime.ReadScopeCapacity(scope)
    if capacity == nil then return nil, capacityErr end
    local count, readErrors = 0, 0
    for slot = 1, capacity do
        local ok, info = BagMoveRuntime.ReadScopeSlot(scope, slot)
        if ok ~= true then
            readErrors = readErrors + 1
        elseif type(info) == "table" and next(info) ~= nil then
            local currentType, currentCategory = SourceIdentity(info)
            if (itemType ~= nil and currentType == itemType) or (itemType == nil and currentCategory == category) then count = count + 1 end
        end
    end
    if readErrors > 0 then return nil, "源容器有槽位读取失败，无法确认移动结果" end
    return count, nil
end

local function BeginBagQuick(feature, direction)
    if BagBatchRunning(feature) then return false,"类别批量整理正在运行，请先停止" end
    if BagQuickRunning(feature) then return false,"快捷取放已经在运行，请先停止" end
    local bagWindow=ReadBagWindowContext(); local storage=CurrentStorageContext()
    if type(bagWindow)~="table" or bagWindow.status~="ready" or bagWindow.visible~=true then return false,"请先打开背包" end
    if type(storage)~="table" then return false,"请先打开银行或箱子" end
    local target=storage.kind
    local bagSet,bagRows,bagErrors,bagErr,bagCounts=BagIdentitySet("bag")
    local storageSet,storageRows,storageErrors,storageErr,storageCounts=BagIdentitySet(target)
    if bagSet==nil or storageSet==nil then return false,bagErr or storageErr or "容器读取失败" end
    if bagErrors>0 or storageErrors>0 then return false,"物品槽位存在读取失败，已安全拒绝取放" end
    local queue={}
    local sourceCounts
    if direction=="withdraw" then
        sourceCounts=storageCounts or {}
        for _,row in ipairs(storageRows) do
            if bagSet[row.itemType] and #queue<BAG_QUICK_LIMIT then
                local allowed=CheckBlacklist(feature,target,row.info)
                if allowed==true then queue[#queue+1]={itemType=row.itemType,source=target,dest="bag"} end
            end
        end
    elseif direction=="deposit" then
        sourceCounts=bagCounts or {}
        for _,row in ipairs(bagRows) do
            if storageSet[row.itemType] and #queue<BAG_QUICK_LIMIT then
                local allowed=CheckBlacklist(feature,target,row.info)
                if allowed==true then queue[#queue+1]={itemType=row.itemType,source="bag",dest=target} end
            end
        end
    else return false,"未知快捷动作" end
    feature._quickOverlay=type(feature._quickOverlay)=="table" and feature._quickOverlay or {}
    feature._quickOverlay.status=#queue>0 and (direction=="withdraw" and "正在取出" or "正在放入") or "没有可匹配的同类物品"
    feature._quickOverlay.error=nil; feature._quickOverlay.queued=#queue; feature._quickOverlay.moved=0
    feature._quickQueue,feature._quickIndex,feature._quickPending=queue,0,nil
    feature._quickSourceCounts=Copy(sourceCounts)
    PublishBagOverlay(feature,"bag_quick_start")
    if #queue==0 then return true,0 end
    if S.Scheduler==nil or type(S.Scheduler.AddTask)~="function" then
        StopBagQuick(feature,"已停止","调度器不可用")
        return false,"调度器不可用"
    end
    S.Scheduler:RemoveTask(BAG_QUICK_MOVE_TASK)
    local added=S.Scheduler:AddTask(BAG_QUICK_MOVE_TASK,250,function()
        local current=CurrentStorageContext()
        if type(current)~="table" or current.kind~=target then StopBagQuick(feature,"已停止","仓库/箱子已关闭或切换"); return end
        local pending=feature._quickPending
        if pending~=nil then
            local ok,info,readErr=BagMoveRuntime.ReadScopeSlot(pending.source,pending.slot)
            if ok~=true then StopBagQuick(feature,"已停止","移动后源槽读取失败："..tostring(readErr or "unknown")); return end
            local afterType=SourceIdentity(info)
            local moved = type(info)~="table" or next(info)==nil or afterType~=pending.itemType
            if moved~=true then
                -- A successful move may compact another identical stack into the
                -- same slot. Only when the locator remains ambiguous do a bounded
                -- identity-count verification instead of treating slot equality
                -- as proof that the write failed.
                local liveCount,countErr=BagMoveRuntime.CountLiveMatches(pending.source,pending.itemType,nil)
                if liveCount==nil then StopBagQuick(feature,"已停止",countErr or "移动结果无法确认"); return end
                moved=liveCount < (tonumber(pending.beforeCount) or 0)
            end
            if moved~=true then StopBagQuick(feature,"已停止","移动后源容器数量未减少，已安全停止"); return end
            local beforeCount=tonumber(pending.beforeCount) or 1
            feature._quickSourceCounts=type(feature._quickSourceCounts)=="table" and feature._quickSourceCounts or {}
            feature._quickSourceCounts[pending.itemType]=math.max(0,beforeCount-1)
            feature._quickOverlay.moved=(tonumber(feature._quickOverlay.moved) or 0)+1
            feature._quickPending=nil
        end
        local entry=feature._quickQueue[feature._quickIndex+1]
        if entry==nil then StopBagQuick(feature,"已完成",nil); return end
        local slot,info,sourceErr=BagMoveRuntime.FindLiveMoveSource(feature,entry.source,target,entry.itemType,nil)
        if slot==nil then
            feature._quickIndex=feature._quickIndex+1
            if sourceErr~="没有剩余可移动的匹配物品" then
                StopBagQuick(feature,"已停止",sourceErr or "源物品解析失败")
            else
                PublishBagOverlay(feature,"bag_quick_skip")
            end
            return
        end
        local counts=type(feature._quickSourceCounts)=="table" and feature._quickSourceCounts or {}
        local beforeCount=tonumber(counts[entry.itemType]) or 0
        if beforeCount<1 then
            local liveCount,countErr=BagMoveRuntime.CountLiveMatches(entry.source,entry.itemType,nil)
            if liveCount==nil then StopBagQuick(feature,"已停止",countErr or "源数量不可读"); return end
            beforeCount=liveCount
            counts[entry.itemType]=liveCount
            feature._quickSourceCounts=counts
        end
        local actionOk,actionErr
        if entry.source=="bag" and target=="bank" then actionOk,actionErr=Action("X2Bag:MoveToEmptyBankSlot",BagApi,"MoveToEmptyBankSlot",slot)
        elseif entry.source=="bag" then actionOk,actionErr=Action("X2Bag:MoveToEmptyCofferSlot",BagApi,"MoveToEmptyCofferSlot",slot)
        elseif entry.source=="bank" then actionOk,actionErr=Action("X2Bank:MoveToEmptyBagSlot",BankApi,"MoveToEmptyBagSlot",slot)
        else actionOk,actionErr=Action("X2Coffer:MoveToEmptyBagSlot",CofferApi,"MoveToEmptyBagSlot",slot) end
        if actionOk~=true then StopBagQuick(feature,"已停止",actionErr or "移动失败"); return end
        feature._quickPending={slot=slot,itemType=entry.itemType,source=entry.source,beforeCount=beforeCount}
        feature._quickIndex=feature._quickIndex+1
        PublishBagOverlay(feature,"bag_quick_step")
    end,false,feature,"P1")
    if added~=true then StopBagQuick(feature,"已停止","快捷取放任务创建失败"); return false,"快捷取放任务创建失败" end
    if type(S.Scheduler.SetTaskModule)=="function" then S.Scheduler:SetTaskModule(BAG_QUICK_MOVE_TASK,"tools_bag",true) end
    return true,#queue
end

local function RefreshBagQuickOverlay(feature)
    local bag=ReadBagWindowContext(); local storage=CurrentStorageContext()
    local visible=type(bag)=="table" and bag.status=="ready" and bag.visible==true and type(storage)=="table"
    local old=feature._quickOverlay or {}
    local nextState=Copy(old)
    nextState.visible=visible==true; nextState.storageKind=storage and storage.kind or nil
    if visible then
        nextState.x=bag.x; nextState.y=math.max(0,(tonumber(bag.y) or 0)-36); nextState.width=math.max(190,math.min(260,tonumber(bag.width) or 220)); nextState.height=32
        if nextState.status==nil or nextState.status=="等待仓库/箱子" then nextState.status="可快捷取放" end
    elseif nextState.status~="正在取出" and nextState.status~="正在放入" then nextState.status="等待仓库/箱子" end
    local changed = old.visible~=nextState.visible or old.storageKind~=nextState.storageKind or old.x~=nextState.x or old.y~=nextState.y or old.width~=nextState.width
    feature._quickOverlay=nextState
    if changed then PublishBagOverlay(feature,"bag_quick_window") end
    return true
end

local function StartBagQuick(feature, direction)
    if BagBatchRunning(feature) then return false,"类别批量整理正在运行，请先停止" end
    if BagQuickRunning(feature) then return false,"快捷取放已经在运行，请先停止" end
    local ok, err = BeginBagQuick(feature, direction)
    if ok ~= true then
        -- Same visibility contract as BatchMove: overlay/status text must show
        -- why the quick action refused to start instead of failing silently.
        feature._quickOverlay = type(feature._quickOverlay) == "table" and feature._quickOverlay or {}
        feature._quickOverlay.status = tostring(err or "失败")
        feature._quickOverlay.error = tostring(err or "失败")
        if type(PublishBagOverlay) == "function" then PublishBagOverlay(feature, "bag_quick_preflight_stop") end
    end
    return ok, err
end

local function StartBagQuickObserver(feature)
    feature._quickOverlay=feature._quickOverlay or { visible=false,status="等待仓库/箱子",moved=0,queued=0 }
    RefreshBagQuickOverlay(feature)
    if S.Scheduler==nil or type(S.Scheduler.AddTask)~="function" then return false,"背包窗口观察调度器不可用" end
    S.Scheduler:RemoveTask(BAG_QUICK_OBSERVE_TASK)
    local added=S.Scheduler:AddTask(BAG_QUICK_OBSERVE_TASK,200,function() return RefreshBagQuickOverlay(feature) end,false,feature,"P3")
    if added~=true then return false,"背包窗口观察任务创建失败" end
    if type(S.Scheduler.SetTaskModule)=="function" then S.Scheduler:SetTaskModule(BAG_QUICK_OBSERVE_TASK,"tools_bag",true) end
    return true
end

local function StopBagQuickAll(feature, reason)
    if S.Scheduler~=nil then S.Scheduler:RemoveTask(BAG_QUICK_OBSERVE_TASK) end
    StopBagQuick(feature,"已停止",reason)
    feature._quickOverlay.visible=false
    PublishBagOverlay(feature,"bag_quick_disable")
    return true
end

local function BeginBatchMove(feature, target, category, requestedLimit)
    category, requestedLimit = NormalizeCategory(category), NormalizeBatchLimit(requestedLimit)
    if category == nil then return false, "请选择有效的物品类别" end
    if requestedLimit == nil then return false, "批量上限必须是 1-40 的整数" end
    local targetObject, targetCapMethod, targetReadCapability, targetApi
    if target == "bank" then targetApi, targetObject, targetCapMethod, targetReadCapability = BankApi, BankApi, "Capacity", "X2Bank:GetBagItemInfo"
    elseif target == "coffer" then targetApi, targetObject, targetCapMethod, targetReadCapability = CofferApi, CofferApi, "Capacity", "X2Coffer:GetBagItemInfo"
    else return false, "目标仓储必须是银行或箱子" end
    local windowOk, windowErr = RequireStorageWindow(target)
    if windowOk ~= true then return false, windowErr end
    local okCap, cap, capErr = Call("X2" .. (target == "bank" and "Bank" or "Coffer") .. ":Capacity", targetObject, targetCapMethod)
    cap = Number(cap)
    if okCap ~= true or cap == nil or cap < 0 then return false, "目标容量不可读：" .. Text(capErr, "容量读取失败") end
    cap = math.floor(cap)
    local free, targetReadErrors = cap, 0
    for slot = 1, math.min(cap, BAG_SCAN_LIMIT) do
        local ok, info = Call(targetReadCapability, targetApi, "GetBagItemInfo", slot)
        if ok ~= true then targetReadErrors = targetReadErrors + 1
        elseif type(info) == "table" and next(info) ~= nil then free = free - 1 end
    end
    if targetReadErrors > 0 or cap > BAG_SCAN_LIMIT then return false, "目标空槽语义不可完整验证，已安全停止" end
    if free <= 0 then return false, "目标仓储没有可验证的空槽" end

    local queue, skipped, readErrors, sourceCategoryCount = {}, 0, 0, 0
    local okBagCap, bagCap = Call("X2Bag:Capacity", BagApi, "Capacity")
    bagCap = Number(bagCap)
    if okBagCap ~= true or bagCap == nil then return false, "背包容量不可读，无法建立批量队列" end
    local queueLimit = math.min(requestedLimit, free)
    for slot = 1, math.min(BAG_SCAN_LIMIT, math.floor(bagCap)) do
        local ok, info = Call("X2Bag:GetBagItemInfo", BagApi, "GetBagItemInfo", 0, slot)
        if ok ~= true then
            readErrors = readErrors + 1
        elseif type(info) == "table" and next(info) ~= nil then
            local _, itemCategory = SourceIdentity(info)
            if itemCategory == nil then
                skipped = skipped + 1
            elseif itemCategory == category then
                sourceCategoryCount = sourceCategoryCount + 1
                if #queue < queueLimit then
                    local allowed = CheckBlacklist(feature, target, info)
                    if allowed == true then
                        -- Queue stable intent, not a transient slot locator. The
                        -- live bag slot is resolved again immediately before each
                        -- write because ArcheAge may compact slots after a move.
                        queue[#queue + 1] = { category = category }
                    else
                        skipped = skipped + 1
                    end
                end
            end
        end
    end
    feature.State.batch = { status = #queue == 0 and "empty" or "running", moved = 0, skipped = skipped, queued = #queue, error = readErrors > 0 and "部分源槽位不可读，已跳过" or nil }
    feature._batchQueue, feature._batchIndex, feature._batchTarget, feature._batchPending = queue, 0, target, nil
    feature._batchSourceCount = sourceCategoryCount
    if #queue == 0 then return true, 0 end
    if S.Scheduler == nil or type(S.Scheduler.AddTask) ~= "function" then
        StopBagBatch(feature, "stopped", "批量队列调度器不可用，安全拒绝")
        return false, "批量队列调度器不可用，安全拒绝"
    end
    S.Scheduler:RemoveTask(BAG_BATCH_TASK)
    local taskAdded = S.Scheduler:AddTask(BAG_BATCH_TASK, 250, function()
        if feature.State.batch.status ~= "running" then S.Scheduler:RemoveTask(BAG_BATCH_TASK); return end
        local schedulerWindowOk, schedulerWindowErr = RequireStorageWindow(feature._batchTarget)
        if schedulerWindowOk ~= true then
            feature.State.batch.status, feature.State.batch.error = "stopped", schedulerWindowErr or "仓储窗口已关闭或目标改变"
            S.Scheduler:RemoveTask(BAG_BATCH_TASK); feature.Authority:Refresh("batch_window_stop"); return
        end
        local pending = feature._batchPending
        if pending ~= nil then
            local ok, info, readErr = BagMoveRuntime.ReadScopeSlot("bag", pending.slot)
            if ok ~= true then
                feature.State.batch.status, feature.State.batch.error = "stopped", "移动后源槽读取失败：" .. tostring(readErr or "unknown read error")
                S.Scheduler:RemoveTask(BAG_BATCH_TASK); feature.Authority:Refresh("batch_verify_read_stop"); return
            end
            local moved = IsEmptyBagInfo(info)
            if moved ~= true then
                -- Slot compaction can put another item into the just-vacated
                -- locator. Confirm the category population decreased before
                -- deciding the move failed.
                local liveCount, countErr = BagMoveRuntime.CountLiveMatches("bag", nil, pending.category)
                if liveCount == nil then
                    feature.State.batch.status, feature.State.batch.error = "stopped", countErr or "移动结果无法确认"
                    S.Scheduler:RemoveTask(BAG_BATCH_TASK); feature.Authority:Refresh("batch_verify_count_stop"); return
                end
                moved = liveCount < (tonumber(pending.beforeCount) or 0)
            end
            if moved ~= true then
                feature.State.batch.status, feature.State.batch.error = "stopped", "移动后源类别数量未减少，已安全停止"
                S.Scheduler:RemoveTask(BAG_BATCH_TASK); feature.Authority:Refresh("batch_verify_stop"); return
            end
            local beforeCount = tonumber(pending.beforeCount) or 1
            feature._batchSourceCount = math.max(0, beforeCount - 1)
            feature.State.batch.moved = feature.State.batch.moved + 1
            feature._batchPending = nil
        end

        local entry = feature._batchQueue[feature._batchIndex + 1]
        if entry == nil then
            feature.State.batch.status = "complete"
            S.Scheduler:RemoveTask(BAG_BATCH_TASK)
            feature.Authority:Refresh("batch_complete")
            return
        end
        local slot, info, sourceErr = BagMoveRuntime.FindLiveMoveSource(feature, "bag", target, nil, category)
        if slot == nil then
            feature.State.batch.skipped = feature.State.batch.skipped + 1
            feature._batchIndex = feature._batchIndex + 1
            if sourceErr ~= "没有剩余可移动的匹配物品" then
                feature.State.batch.status, feature.State.batch.error = "stopped", sourceErr or "源物品解析失败"
                S.Scheduler:RemoveTask(BAG_BATCH_TASK)
                feature.Authority:Refresh("batch_source_stop")
            else
                feature.Authority:Refresh("batch_skip")
            end
            return
        end
        local beforeCount = tonumber(feature._batchSourceCount) or 0
        if beforeCount < 1 then
            local liveCount, countErr = BagMoveRuntime.CountLiveMatches("bag", nil, category)
            if liveCount == nil then
                feature.State.batch.status, feature.State.batch.error = "stopped", countErr or "源类别数量不可读"
                S.Scheduler:RemoveTask(BAG_BATCH_TASK); feature.Authority:Refresh("batch_count_stop"); return
            end
            beforeCount = liveCount
            feature._batchSourceCount = liveCount
        end
        local capability = target == "bank" and "X2Bag:MoveToEmptyBankSlot" or "X2Bag:MoveToEmptyCofferSlot"
        local actionOk, actionErr = Action(capability, BagApi, target == "bank" and "MoveToEmptyBankSlot" or "MoveToEmptyCofferSlot", slot)
        if actionOk ~= true then
            feature.State.batch.status, feature.State.batch.error = "stopped", actionErr or "移动失败"
            S.Scheduler:RemoveTask(BAG_BATCH_TASK); feature.Authority:Refresh("batch_action_stop"); return
        end
        feature._batchPending = { slot = slot, category = category, beforeCount = beforeCount }
        feature._batchIndex = feature._batchIndex + 1
        feature.Authority:Refresh("batch_step")
    end, false, feature, "P1")
    if taskAdded ~= true then
        StopBagBatch(feature, "stopped", "批量队列任务创建失败，已清理运行态")
        return false, "批量队列任务创建失败，安全拒绝"
    end
    if type(S.Scheduler.SetTaskModule) == "function" then local transient = true; S.Scheduler:SetTaskModule(BAG_BATCH_TASK, "tools_bag", transient) end
    return true, #queue
end

local function BatchMove(feature, target, category, requestedLimit)
    if BagQuickRunning(feature) then return false, "快捷取放正在运行，请先停止" end
    if BagBatchRunning(feature) then return false, "类别批量整理已经在运行，请先停止" end
    local ok, err = BeginBatchMove(feature, target, category, requestedLimit)
    if ok ~= true then
        -- Preflight rejections must stay visible: without this record the page
        -- status text kept showing the idle "等待操作" line, which read as a
        -- dead button (CURRENT_REBUILD_STATUS §9.3 bag regression).
        feature.State.batch = { status = "stopped", moved = 0, skipped = 0, queued = 0, error = err }
        if type(feature.Authority) == "table" and type(feature.Authority.Refresh) == "function" then
            feature.Authority:Refresh("batch_preflight_stop")
        end
    end
    return ok, err
end

local function RestoreState(state, snapshot)
    for key in pairs(state) do state[key] = nil end
    for key, value in pairs(type(snapshot) == "table" and snapshot or {}) do state[key] = Copy(value) end
end

PersistStateMutation = function(feature, reason, mutator)
    if type(feature) ~= "table" or type(feature.State) ~= "table" or type(mutator) ~= "function" then return false, "持久化事务参数无效" end
    if type(P.MutateStore) ~= "function" then return false, "Persistence mutation transaction unavailable" end
    return P:MutateStore(feature.storeId, function()
        return mutator(feature.State)
    end, { delayMs = 300, reason = tostring(reason or "feature_mutation") })
end

local function PersistentState(state, defaults)
    local out = {}
    -- Store only fields declared by the Feature's permanent default contract.
    -- Runtime projection/batch/query state may live beside them in State, but
    -- must never silently become permanent configuration. Dynamic containers
    -- (for example blacklist maps) are copied as values at the declared key.
    for key in pairs(type(defaults) == "table" and defaults or {}) do out[key] = Copy(state[key]) end
    return out
end

local function NewFeature(id, spec)
    local feature = { Id = id, storeId = "v3.business." .. id, enabled = false, storeLoaded = false, State = spec.state or {}, Authority = { version = 1, revision = 0, rows = {}, status = "idle", error = nil } }
    feature.UpdateTopic = "v3.business." .. tostring(id) .. ".updated"
    feature.ObservationContractVersion = tonumber(spec.observationContractVersion) or 0
    S.Features[id] = feature
    local authority, state = feature.Authority, feature.State
    RegisterStore(feature.storeId, "v3." .. id, function() return Copy(spec.default or {}) end, function() return PersistentState(state, spec.default) end, function(value)
        if type(spec.apply) == "function" then return spec.apply(value, state) end
        value = type(value) == "table" and value or {}
        for key, default in pairs(spec.default or {}) do state[key] = value[key] == nil and default or value[key] end
    end)
    feature.ApiDependencies = spec.apiDependencies or {}
    function authority:Refresh(reason)
        if spec.blocker ~= nil then
            self.rows = { { key = id .. ":blocked", name = "运行时阻塞", text = spec.blocker, statusText = "Runtime Blocked", tone = "warn" } }
            self.status, self.error = "runtime_blocked", spec.blocker
        else
            local rows, status, err = spec.read(feature)
            self.rows, self.status, self.error = type(rows) == "table" and rows or {}, status or "ready", err
        end
        self.revision = self.revision + 1
        if S.Events ~= nil and type(S.Events.Publish) == "function" then
            S.Events:Publish(feature.UpdateTopic, self.revision, tostring(reason or "refresh"))
        end
        return true
    end
    function feature:Initialize() return Load(self) end
    function feature:ReconcileDemand(_, before, after)
        local beforeCount = tonumber(before and before.count) or 0
        local afterCount = tonumber(after and after.count) or 0
        local customReconciled = false
        if type(spec.reconcileDemand) == "function" then
            local ok, err = spec.reconcileDemand(self, before, after)
            if ok ~= true then return false, err end
            customReconciled = true
        end
        if beforeCount <= 0 and afterCount > 0 then
            if spec.event and S.Events ~= nil then
                S.Events:BindOwner(self, self.Id)
                local subscribed = S.Events:SubscribeOptional(spec.event, self, function(_, ...)
                    if self.enabled and (tonumber(self.consumerCount) or 0) > 0 and type(spec.onEvent) == "function" then
                        return spec.onEvent(self, ...)
                    end
                end)
                if subscribed ~= true then
                    -- Demand acquisition is one transaction. If the generic event
                    -- edge cannot be established, reverse any custom observation
                    -- resource created earlier in the same 0->1 transition (for
                    -- example the target-monitor distance Scheduler task).
                    S.Events:UnsubscribeOwner(self)
                    if customReconciled == true and type(spec.reconcileDemand) == "function" then
                        pcall(spec.reconcileDemand, self, after, before)
                    end
                    return false, "可选事件订阅失败：" .. tostring(spec.event)
                end
            end
            self.Authority:Refresh("consumer_acquire")
        elseif beforeCount > 0 and afterCount <= 0 and spec.event and S.Events ~= nil then
            S.Events:UnsubscribeOwner(self)
        end
        return true
    end
    function feature:Enable(reason)
        if self.enabled == true then return true end
        self.enabled = true
        if type(spec.onEnable) == "function" then
            local hookOk, hookErr = spec.onEnable(self, reason or "business_feature_enable")
            if hookOk ~= true then
                self.enabled = false
                if S.Scheduler ~= nil and type(S.Scheduler.RemoveOwner) == "function" then S.Scheduler:RemoveOwner(self) end
                if S.Events ~= nil then S.Events:UnsubscribeOwner(self); S.Events:UnsubscribeInternalOwner(self) end
                return false, hookErr or "Feature enable hook failed"
            end
        end
        return true
    end
    function feature:Disable(reason)
        local ok, err = self.Demand:Clear(reason or "business_feature_disable"); if ok ~= true then return false, err end
        if type(spec.onDisable) == "function" then
            local hookOk, hookErr = spec.onDisable(self, reason or "business_feature_disable")
            if hookOk ~= true then return false, hookErr end
        end
        if S.Events ~= nil then S.Events:UnsubscribeOwner(self) end
        self.enabled = false; return true
    end
    function feature:AcquireConsumer(token) if not self.enabled then return false, "功能已关闭" end return self.Demand:Acquire(token, {}, "business_consumer") end
    function feature:ReleaseConsumer(token) return self.Demand:Release(token, "business_consumer") end
    function feature:Refresh(reason) local consumerCount = tonumber(self.consumerCount) or tonumber(self.Demand and self.Demand.count) or 0; if not self.enabled or consumerCount <= 0 then return true end return self.Authority:Refresh(reason or "manual") end
    function feature:GetProjection()
        local projection = { revision = authority.revision, rows = Copy(authority.rows), status = authority.status, error = authority.error }
        if type(spec.projection) == "function" then
            local extra = spec.projection(feature)
            if type(extra) == "table" then for key, value in pairs(extra) do projection[key] = Copy(value) end end
        end
        return projection
    end
    feature.Commands = { Refresh = function(_, reason) return feature:Refresh(reason) end }
    for name, fn in pairs(spec.commands or {}) do feature.Commands[name] = function(_, ...) return fn(feature, ...) end end
    local lease, leaseErr = Demand:Create({ id = "feature:" .. id, owner = feature, projectionOwner = feature, projectionConsumersField = "consumers", projectionCountField = "consumerCount", reconcile = function(l, before, after) return feature:ReconcileDemand(l, before, after) end })
    if lease == nil then error(leaseErr) end
    feature.Demand = lease
    local ok, err = Runtime:RegisterImplementation(id, feature); if ok ~= true then error(err) end
    return feature
end

-- Boss mechanics: static catalog is verified data; realtime trigger facts remain
-- partial. HUD display itself is real and testable through the shared Alerts
-- service, so users can validate placement/size without inventing combat facts.
local BossAlerts = NewFeature("combat_boss_alerts", {
    apiDependencies = {},
    state = { hudEnabled = true, hudAnchor = "center", hudFontSize = 34, hudDurationMs = 3000 },
    default = { hudEnabled = true, hudAnchor = "center", hudFontSize = 34, hudDurationMs = 3000 },
    read = function()
        local rows = {}
        for index, value in ipairs(S.Data and S.Data.BossAlerts or {}) do
            local row = type(value) == "table" and value or {}
            local key = tostring(row.key or index)
            local kind = tostring(row.kind or "unknown")
            local triggerText
            if kind == "cast" then
                local names = {}
                for nameIndex = 1, math.min(3, #(type(row.names) == "table" and row.names or {})) do
                    names[#names + 1] = tostring(row.names[nameIndex])
                end
                triggerText = "施法识别：" .. (#names > 0 and table.concat(names, " / ") or "名称待补")
            elseif kind == "debuff" then
                triggerText = "Debuff ID：" .. tostring(row.debuffId or "--")
            else
                triggerText = "触发事实：待确认"
            end
            rows[#rows + 1] = {
                key = "boss:" .. key,
                name = tostring(row.alert or key),
                text = triggerText,
                statusText = tostring(row.style) == "countdown" and "倒计时 HUD" or "大字 HUD",
                tone = tostring(row.style) == "countdown" and "yellow" or "orange",
                mechanicKey = key, kind = kind, style = tostring(row.style or "bigtext"), debuffId = tonumber(row.debuffId),
            }
        end
        return rows, #rows > 0 and "partial" or "empty",
            #rows > 0 and "规则目录与 HUD 可测试；实时触发仍等待已验证的施法/Aura 事实桥" or "BossAlerts 静态目录为空"
    end,
    projection = function(feature)
        return { hudEnabled = feature.State.hudEnabled == true, hudAnchor = feature.State.hudAnchor,
            hudFontSize = tonumber(feature.State.hudFontSize) or 34, hudDurationMs = tonumber(feature.State.hudDurationMs) or 3000 }
    end,
    commands = {
        SetHudEnabled = function(feature, value)
            return PersistStateMutation(feature, "boss_hud_enabled", function(state) state.hudEnabled = value == true; return true end)
        end,
        SetHudAnchor = function(feature, value)
            value = value == "top" and "top" or "center"
            return PersistStateMutation(feature, "boss_hud_anchor", function(state) state.hudAnchor = value; return true end)
        end,
        SetHudFontSize = function(feature, value)
            value = math.max(18, math.min(56, math.floor(tonumber(value) or 34)))
            return PersistStateMutation(feature, "boss_hud_font", function(state) state.hudFontSize = value; return true end)
        end,
        SetHudDurationMs = function(feature, value)
            value = math.max(1000, math.min(10000, math.floor(tonumber(value) or 3000)))
            return PersistStateMutation(feature, "boss_hud_duration", function(state) state.hudDurationMs = value; return true end)
        end,
        TestBigText = function(feature)
            if feature.State.hudEnabled ~= true then return false, "请先启用首领机制 HUD" end
            local alerts = S.Services and S.Services.Alerts or nil
            if type(alerts) ~= "table" or type(alerts.Push) ~= "function" then return false, "AlertsService 不可用" end
            return alerts:Push({ text = "首领机制 HUD 测试", style = "bigtext", durationMs = feature.State.hudDurationMs,
                presentationConfig = { anchorMode = feature.State.hudAnchor, fontSize = feature.State.hudFontSize } }) == true
        end,
        TestCountdown = function(feature)
            if feature.State.hudEnabled ~= true then return false, "请先启用首领机制 HUD" end
            local alerts = S.Services and S.Services.Alerts or nil
            if type(alerts) ~= "table" or type(alerts.Push) ~= "function" then return false, "AlertsService 不可用" end
            local duration = math.max(3000, tonumber(feature.State.hudDurationMs) or 3000)
            return alerts:Push({ text = "机制倒计时", style = "countdown", durationMs = duration, remainingMs = duration,
                presentationConfig = { anchorMode = feature.State.hudAnchor, fontSize = feature.State.hudFontSize } }) == true
        end,
    },
})
BossAlerts.HudContractVersion = 1
local TARGET_MONITOR_TASK = "v3_business_target_monitor_distance"
NewFeature("combat_target_monitor", { apiDependencies = { "X2Unit:GetTargetUnitId", "X2Unit:UnitName", "X2Unit:UnitDistance" },
    observationContractVersion = 1,
    event = "TARGET_CHANGED",
    reconcileDemand = function(feature, before, after)
        local beforeCount = tonumber(before and before.count) or 0
        local afterCount = tonumber(after and after.count) or 0
        if beforeCount <= 0 and afterCount > 0 then
            if S.Scheduler == nil or type(S.Scheduler.AddTask) ~= "function" then return false, "目标距离刷新 Scheduler 不可用" end
            local added = S.Scheduler:AddTask(TARGET_MONITOR_TASK, 500, function()
                if feature.enabled == true and (tonumber(feature.consumerCount) or 0) > 0 then feature.Authority:Refresh("target_distance") end
            end, false, feature, "P1", 1)
            if added ~= true then return false, "目标距离刷新任务创建失败" end
            if type(S.Scheduler.SetTaskModule) == "function" then S.Scheduler:SetTaskModule(TARGET_MONITOR_TASK, feature.Id, false) end
        elseif beforeCount > 0 and afterCount <= 0 and S.Scheduler ~= nil and type(S.Scheduler.RemoveTask) == "function" then
            S.Scheduler:RemoveTask(TARGET_MONITOR_TASK)
        end
        return true
    end,
    onDisable = function()
        if S.Scheduler ~= nil and type(S.Scheduler.RemoveTask) == "function" then S.Scheduler:RemoveTask(TARGET_MONITOR_TASK) end
        return true
    end,
    onEvent = function(feature) return feature.Authority:Refresh("target_changed") end,
    read = function()
        local okId, id = Call("X2Unit:GetTargetUnitId", UnitApi, "GetTargetUnitId")
        local okName, name = Call("X2Unit:UnitName", UnitApi, "UnitName", "target")
        local okDistance, distance = Call("X2Unit:UnitDistance", UnitApi, "UnitDistance", "target")
        local has = okId and id ~= nil or okName and name ~= nil
        if not has then return {}, "empty", "当前没有可读目标" end
        return { { key = "target", name = Text(name, "目标"), text = "ID：" .. Text(id, "--"), statusText = okDistance and Text(distance, "--") or "--", tone = "default" } }, "ready"
    end,
})
local BUFF_CAP_REFRESH_TASK = "v3_business_buff_cap_refresh"
NewFeature("combat_buff_cap", { apiDependencies = { "X2Unit:UnitBuffCount", "X2Unit:UnitHiddenBuffCount" },
    observationContractVersion = 1,
    event = "BUFF_UPDATE",
    reconcileDemand = function(_, before, after)
        local beforeCount = tonumber(before and before.count) or 0
        local afterCount = tonumber(after and after.count) or 0
        if beforeCount <= 0 and afterCount > 0 then
            if S.Scheduler == nil or type(S.Scheduler.AddOneShot) ~= "function" then return false, "增益容量刷新 Scheduler 不可用" end
        elseif beforeCount > 0 and afterCount <= 0 and S.Scheduler ~= nil and type(S.Scheduler.RemoveTask) == "function" then
            S.Scheduler:RemoveTask(BUFF_CAP_REFRESH_TASK)
        end
        return true
    end,
    onDisable = function()
        if S.Scheduler ~= nil and type(S.Scheduler.RemoveTask) == "function" then S.Scheduler:RemoveTask(BUFF_CAP_REFRESH_TASK) end
        return true
    end,
    onEvent = function(feature)
        if S.Scheduler == nil or type(S.Scheduler.AddOneShot) ~= "function" then return false, "增益容量刷新 Scheduler 不可用" end
        S.Scheduler:RemoveTask(BUFF_CAP_REFRESH_TASK)
        local added = S.Scheduler:AddOneShot(BUFF_CAP_REFRESH_TASK, 150, function()
            if feature.enabled == true and (tonumber(feature.consumerCount) or 0) > 0 then feature.Authority:Refresh("buff_update") end
        end, feature, "P2", 1)
        return added == true, added == true and nil or "增益容量合并刷新任务创建失败"
    end,
    read = function()
        local okA, normal = Call("X2Unit:UnitBuffCount", UnitApi, "UnitBuffCount", "player")
        local okB, hidden = Call("X2Unit:UnitHiddenBuffCount", UnitApi, "UnitHiddenBuffCount", "player")
        if not okA and not okB then return {}, "unavailable", "普通/隐藏增益数量均不可读" end
        local total = (Number(normal) or 0) + (Number(hidden) or 0)
        return { { key = "buff_cap", name = "自身增益", text = "普通 " .. Text(normal, "--") .. " · 隐藏 " .. Text(hidden, "--"), statusText = "总计 " .. tostring(total), tone = "default" } }, "partial", "当前只证明增益数量读取；RU 容量/顶替阈值未验证，不生成风险告警"
    end,
})
local TEAM_ROLE_MAX_TEAMS, TEAM_ROLE_MAX_MEMBERS = 2, 50
local TEAM_ROLE_MAX_ROWS = TEAM_ROLE_MAX_TEAMS * TEAM_ROLE_MAX_MEMBERS
local TEAM_ROLE_ROSTER_TOKEN = "combat_team_tools:roster"

local function TeamRosterV3()
    return S.Services and S.Services.TeamRosterV3 or nil
end

local function NormalizeTeamRoleIndex(value)
    local number = Number(value)
    if number == nil or number ~= math.floor(number) then return nil end
    return math.floor(number)
end

local function TeamRoleKeyPart(value)
    local text = Trim(value)
    if text == "" then return "-" end
    return (text:gsub("[^%w_%-]", "_"))
end

local function BuildTeamRoleKey(member, ordinal, duplicateCount)
    local teamIndex = NormalizeTeamRoleIndex(type(member) == "table" and member.teamIndex or nil)
    local memberIndex = NormalizeTeamRoleIndex(type(member) == "table" and member.memberIndex or nil)
    local token = type(member) == "table" and Trim(member.unitToken) or ""
    local name = type(member) == "table" and Trim(member.name) or ""
    local identity = TeamRoleKeyPart(token ~= "" and token or name)
    local base = string.format("team_role:%s:%s:%s", tostring(teamIndex or 0), tostring(memberIndex or 0), identity)
    if (tonumber(duplicateCount) or 0) > 0 then base = base .. ":duplicate:" .. tostring(duplicateCount) end
    if base == "team_role:0:0:-" then base = base .. ":row:" .. tostring(ordinal) end
    return base
end

local function TeamRoleDisplayName(member)
    if type(member) ~= "table" then return "无效成员" end
    local name = Trim(member.name)
    if name ~= "" then return name end
    local token = Trim(member.unitToken)
    return token ~= "" and token or "未知成员"
end

local function TeamRoleReadRow(member, ordinal, slotCounts)
    local row = type(member) == "table" and member or {}
    local teamIndex = NormalizeTeamRoleIndex(row.teamIndex)
    local memberIndex = NormalizeTeamRoleIndex(row.memberIndex)
    local unitToken = Trim(row.unitToken)
    local name = TeamRoleDisplayName(member)
    local slotKey = teamIndex ~= nil and memberIndex ~= nil and string.format("%d:%d", teamIndex, memberIndex) or nil
    local duplicateCount = 0
    if slotKey ~= nil then
        duplicateCount = tonumber(slotCounts[slotKey]) or 0
        slotCounts[slotKey] = duplicateCount + 1
    end
    local rowKey = BuildTeamRoleKey(row, ordinal, duplicateCount)
    local result = {
        key = rowKey,
        name = name,
        unitToken = unitToken,
        teamIndex = teamIndex,
        memberIndex = memberIndex,
        role = nil,
        roleStatus = "invalid_index",
        roleText = "索引无效",
        text = string.format("%s · team %s / member %s · 职责：索引无效", unitToken ~= "" and unitToken or "unitToken 未知", tostring(teamIndex or "--"), tostring(memberIndex or "--")),
        statusText = "索引无效",
        tone = "warn",
    }

    if type(member) ~= "table" then
        result.roleStatus = "invalid_member"
        result.roleText, result.statusText = "成员记录无效", "成员无效"
        result.text = result.text:gsub(" · 职责：.*$", "") .. " · 职责：" .. result.roleText
        return result, "invalid"
    end
    if teamIndex == nil or memberIndex == nil or teamIndex < 1 or teamIndex > TEAM_ROLE_MAX_TEAMS or memberIndex < 1 or memberIndex > TEAM_ROLE_MAX_MEMBERS then
        return result, "invalid"
    end

    local ok, role, err = Call("X2Team:GetRole", TeamApi, "GetRole", teamIndex, memberIndex)
    if ok ~= true then
        result.roleStatus = "read_failed"
        result.roleText, result.statusText = "读取失败", "职责读取失败"
        result.error = Text(err, "X2Team:GetRole 未返回职责")
        result.text = result.text:gsub(" · 职责：.*$", "") .. " · 职责：" .. result.roleText
        result.tone = "warn"
        return result, "failed"
    end
    if role == nil then
        result.roleStatus = "empty"
        result.roleText, result.statusText = "未返回职责", "待确认"
        result.text = result.text:gsub(" · 职责：.*$", "") .. " · 职责：" .. result.roleText
        result.tone = "warn"
        return result, "failed"
    end

    result.role = role
    result.roleText = Text(role, "已读取")
    result.statusText = "已读取"
    result.text = result.text:gsub(" · 职责：.*$", "") .. " · 职责：" .. result.roleText
    result.tone = "default"
    if duplicateCount > 0 then
        result.roleStatus = "duplicate_slot"
        result.statusText = "重复槽位"
        result.tone = "warn"
        return result, "invalid"
    end
    result.roleStatus = "ready"
    return result, "ready"
end

local function ReadTeamRoleRoster(feature)
    local roster = TeamRosterV3()
    if type(roster) ~= "table" or type(roster.GetSnapshot) ~= "function" then
        feature.TeamRoleScan = { rosterRevision = 0, total = 0, ready = 0, failed = 0, invalid = 0, truncated = false, diagnostic = "TeamRosterV3 快照不可用" }
        return { { key = "team_role:unavailable", name = "当前团队职责", text = "TeamRosterV3 快照不可用", statusText = "不可用", tone = "warn", roleStatus = "roster_unavailable" } }, "unavailable", "TeamRosterV3:GetSnapshot 不可用"
    end

    local snapshot = roster:GetSnapshot()
    if type(snapshot) ~= "table" then
        feature.TeamRoleScan = { rosterRevision = 0, total = 0, ready = 0, failed = 0, invalid = 0, truncated = false, diagnostic = "团队名单快照返回无效" }
        return { { key = "team_role:unavailable", name = "当前团队职责", text = "团队名单快照返回无效", statusText = "不可用", tone = "warn", roleStatus = "roster_invalid" } }, "unavailable", "TeamRosterV3:GetSnapshot 返回无效值"
    end

    local members = snapshot.members
    if type(members) ~= "table" then members = {} end
    local rows, slotCounts = {}, {}
    local ready, failed, invalid = 0, 0, 0
    local limit = math.min(#members, TEAM_ROLE_MAX_ROWS)
    for ordinal = 1, limit do
        local row, result = TeamRoleReadRow(members[ordinal], ordinal, slotCounts)
        rows[#rows + 1] = row
        if result == "ready" then ready = ready + 1
        elseif result == "failed" then failed = failed + 1
        else invalid = invalid + 1 end
    end
    local truncated = #members > TEAM_ROLE_MAX_ROWS
    if truncated then
        rows[#rows + 1] = { key = "team_role:truncated", name = "当前团队职责", text = string.format("名单超过上限 %d，已截断", TEAM_ROLE_MAX_ROWS), statusText = "已截断", roleStatus = "truncated", tone = "warn" }
    end

    local rosterRevision = tonumber(snapshot.revision) or 0
    local total = #members
    if total == 0 then
        local diagnostic = "当前团队为空"
        feature.TeamRoleScan = { rosterRevision = rosterRevision, total = 0, ready = 0, failed = 0, invalid = 0, truncated = false, empty = true, diagnostic = diagnostic }
        return { { key = "team_role:empty", name = "当前团队职责", text = diagnostic, statusText = "空团队", roleStatus = "empty_team", tone = "muted" } }, "empty", diagnostic
    end

    local diagnosticParts = {}
    if failed > 0 then diagnosticParts[#diagnosticParts + 1] = "职责读取失败 " .. tostring(failed) end
    if invalid > 0 then diagnosticParts[#diagnosticParts + 1] = "无效/重复槽位 " .. tostring(invalid) end
    if truncated then diagnosticParts[#diagnosticParts + 1] = "名单已按 " .. tostring(TEAM_ROLE_MAX_ROWS) .. " 条截断" end
    local diagnostic = #diagnosticParts > 0 and table.concat(diagnosticParts, "；") or nil
    feature.TeamRoleScan = { rosterRevision = rosterRevision, total = total, returned = limit, ready = ready, failed = failed, invalid = invalid, truncated = truncated, diagnostic = diagnostic }
    if diagnostic ~= nil then return rows, "partial", diagnostic end
    return rows, "ready", nil
end

local function SubscribeTeamRoleRoster(feature)
    if feature.TeamRoleRosterSubscribed == true then return true end
    if S.Events == nil or type(S.Events.SubscribeInternal) ~= "function" then return false, "团队名单内部事件总线不可用" end
    local subscribed = S.Events:SubscribeInternal("v3.team_roster.updated", feature, function(_, revision, reason)
        if feature.enabled == true and (tonumber(feature.consumerCount) or 0) > 0 then
            return feature.Authority:Refresh("team_roster_updated:" .. tostring(reason or revision or "update"))
        end
    end)
    if subscribed ~= true then return false, "团队名单更新订阅失败" end
    feature.TeamRoleRosterSubscribed = true
    return true
end

local function UnsubscribeTeamRoleRoster(feature)
    if feature.TeamRoleRosterSubscribed == true and S.Events ~= nil and type(S.Events.UnsubscribeInternal) == "function" then
        S.Events:UnsubscribeInternal("v3.team_roster.updated", feature)
    end
    feature.TeamRoleRosterSubscribed = false
    return true
end

local function AcquireTeamRoleRoster(feature, before, after)
    local beforeCount = tonumber(before and before.count) or 0
    local afterCount = tonumber(after and after.count) or 0
    if beforeCount <= 0 and afterCount > 0 then
        local roster = TeamRosterV3()
        if type(roster) ~= "table" or type(roster.AcquireConsumer) ~= "function" then return false, "团队名单服务不可用" end
        local ok, err = roster:AcquireConsumer(TEAM_ROLE_ROSTER_TOKEN, { purpose = "combat_team_tools_roles" })
        if ok ~= true then return false, err or "团队名单服务获取失败" end
        feature.TeamRoleRosterHeld = true
        local subscribed, subscribeErr = SubscribeTeamRoleRoster(feature)
        if subscribed ~= true then
            if type(roster.ReleaseConsumer) == "function" then pcall(roster.ReleaseConsumer, roster, TEAM_ROLE_ROSTER_TOKEN) end
            feature.TeamRoleRosterHeld = false
            UnsubscribeTeamRoleRoster(feature)
            return false, subscribeErr
        end
    elseif beforeCount > 0 and afterCount <= 0 then
        if feature.TeamRoleRosterHeld == true then
            local roster = TeamRosterV3()
            if type(roster) ~= "table" or type(roster.ReleaseConsumer) ~= "function" then return false, "团队名单服务释放不可用" end
            local ok, err = roster:ReleaseConsumer(TEAM_ROLE_ROSTER_TOKEN)
            if ok ~= true then return false, err or "团队名单服务释放失败" end
            feature.TeamRoleRosterHeld = false
        end
        UnsubscribeTeamRoleRoster(feature)
    end
    return true
end

local function ReleaseTeamRoleRoster(feature)
    if feature.TeamRoleRosterHeld == true then
        local roster = TeamRosterV3()
        if type(roster) ~= "table" or type(roster.ReleaseConsumer) ~= "function" then return false, "团队名单服务释放不可用" end
        local ok, err = roster:ReleaseConsumer(TEAM_ROLE_ROSTER_TOKEN)
        if ok ~= true then return false, err or "团队名单服务释放失败" end
        feature.TeamRoleRosterHeld = false
    end
    UnsubscribeTeamRoleRoster(feature)
    return true
end

local function TeamRoleValues()
    local rows, seen = {}, {}
    for _, spec in ipairs({
        { key = "none", global = "TMROLE_NONE", label = "未标记" },
        { key = "tank", global = "TMROLE_TANKER", label = "坦克" },
        { key = "healer", global = "TMROLE_HEALER", label = "治疗" },
        { key = "dealer", global = "TMROLE_DEALER", label = "输出" },
        { key = "ranged", global = "TMROLE_RANGED_DEALER", label = "远程输出" },
    }) do
        local value = Number(rawget(_G, spec.global))
        if value ~= nil and not seen[value] then seen[value] = true; rows[#rows + 1] = { key = spec.key, value = value, text = spec.label } end
    end
    return rows
end
local function NormalizeTeamRole(value)
    local number = Number(value)
    for _, row in ipairs(TeamRoleValues()) do if row.value == number then return row.value end end
    return nil
end

local TeamTools = NewFeature("combat_team_tools", { apiDependencies = { "X2Team:GetRole", "X2Team:SetRole", "X2Unit:GetTargetAbilityTemplates", "X2Unit:UnitName" },
    state = { role = nil, autoRoleEnabled = true }, default = { role = nil, autoRoleEnabled = true },
    reconcileDemand = AcquireTeamRoleRoster,
    onDisable = ReleaseTeamRoleRoster,
    projection = function(feature)
        local scan = feature.TeamRoleScan or {}
        return { teamRoleScan = Copy(scan), rosterRevision = tonumber(scan.rosterRevision) or 0, roleOptions = TeamRoleValues(), memberMoveAvailable = false,
            autoRoleEnabled = feature.State.autoRoleEnabled ~= false, autoRoleStatus = tostring(feature.AutoRoleStatus or "等待团队/职业变化"),
            autoRoleClassKey = feature.AutoRoleClassKey, autoRoleLabel = feature.AutoRoleLabel }
    end,
    read = ReadTeamRoleRoster,
    commands = {
        SetAutoRoleEnabled = function(feature, value)
            local ok, err = PersistStateMutation(feature, "team_auto_role", function(state) state.autoRoleEnabled = value == true; return true end)
            if ok ~= true then return false, err end
            if feature.State.autoRoleEnabled == true and type(feature.ScheduleAutoRole) == "function" then feature:ScheduleAutoRole("setting_enabled", 100) end
            return true
        end,
        SetRole = function(_, role)
            local value = NormalizeTeamRole(role)
            if value == nil then return false, "职责必须来自当前客户端 TMROLE_* 枚举" end
            return Action("X2Team:SetRole", TeamApi, "SetRole", value)
        end,
        MoveMember = function(_, from, to)
            local fromMember, err = TeamCommandInteger(from, "源成员", 50); if fromMember == nil then return false, err end
            local toMember; toMember, err = TeamCommandInteger(to, "目标成员", 50); if toMember == nil then return false, err end
            return false, "成员移动已安全停用：当前 RU 没有允许使用的队长/权限 getter，不能证明写操作权限"
        end,
        MoveMemberToParty = function(_, fromMember, toParty)
            local value, err = TeamCommandInteger(fromMember, "成员", 50); if value == nil then return false, err end
            toParty, err = TeamCommandInteger(toParty, "小队", 50); if toParty == nil then return false, err end
            return false, "成员移入小队已安全停用：当前 RU 没有允许使用的队长/权限 getter，不能证明写操作权限"
        end,
    },
})
TeamTools.TeamRoleRosterHeld = false
TeamTools.TeamRoleRosterSubscribed = false
TeamTools.TeamRoleContractVersion = 2
TeamTools.AutoRoleCatalogContractVersion = 1

local TEAM_AUTO_ROLE_TASK="v3_team_auto_role_apply"
local function TeamAutoRoleCatalog() return S.Data and S.Data.TeamAutoRoleCatalog or nil end
local function ResolveAutoRole(feature)
    local ok,templates,err=Call("X2Unit:GetTargetAbilityTemplates",rawget(_G,"X2Unit"),"GetTargetAbilityTemplates","player")
    if ok~=true or type(templates)~="table" then return nil,nil,nil,"职业树不可读："..tostring(err or "unknown") end
    local indices={}
    for i=1,3 do local n=tonumber(type(templates[i])=="table" and templates[i].index or nil); if n==nil then return nil,nil,nil,"职业树返回不完整" end; indices[#indices+1]=math.floor(n) end
    table.sort(indices)
    local key=string.format("name_%d_%d_%d",indices[1],indices[2],indices[3])
    local catalog=TeamAutoRoleCatalog(); local row=type(catalog)=="table" and type(catalog.byClassKey)=="table" and catalog.byClassKey[key] or nil
    if type(row)~="table" then return NormalizeTeamRole(rawget(_G,"TMROLE_NONE")),key,"未标记","职业组合尚未登记" end
    local globalByRole={tank="TMROLE_TANKER",healer="TMROLE_HEALER",dealer="TMROLE_DEALER",ranged="TMROLE_RANGED_DEALER",none="TMROLE_NONE"}
    local role=NormalizeTeamRole(rawget(_G,globalByRole[row.role] or "TMROLE_NONE"))
    return role,key,({tank="坦克",healer="治疗",dealer="输出",ranged="远程输出",none="未标记"})[row.role] or "未标记",nil
end
local function FindPlayerRoleSlot()
    local roster=TeamRosterV3(); if type(roster)~="table" or type(roster.GetSnapshot)~="function" then return nil,nil,"团队名单不可用" end
    local ok,name,err=Call("X2Unit:UnitName",rawget(_G,"X2Unit"),"UnitName","player")
    name=ok==true and tostring(name or "") or ""; if name=="" then return nil,nil,"当前玩家名称不可读："..tostring(err or "unknown") end
    local snap=roster:GetSnapshot(); for _,member in ipairs(type(snap)=="table" and type(snap.members)=="table" and snap.members or {}) do
        if tostring(member.name or "")==name then return tonumber(member.teamIndex),tonumber(member.memberIndex),nil end
    end
    return nil,nil,"当前玩家尚未进入团队名单"
end
function TeamTools:ApplyAutoRole(reason)
    if self.enabled~=true or self.State.autoRoleEnabled==false then self.AutoRoleStatus="自动职责已关闭"; return true end
    local desired,classKey,label,resolveErr=ResolveAutoRole(self)
    self.AutoRoleClassKey,self.AutoRoleLabel=classKey,label
    if desired==nil then self.AutoRoleStatus=resolveErr or "无法识别职责"; return false,self.AutoRoleStatus end
    local teamIndex,memberIndex,slotErr=FindPlayerRoleSlot()
    if teamIndex==nil or memberIndex==nil then self.AutoRoleStatus=slotErr or "未在团队"; return true end
    local ok,current,currentErr=Call("X2Team:GetRole",TeamApi,"GetRole",teamIndex,memberIndex)
    if ok==true and tonumber(current)==tonumber(desired) then self.AutoRoleStatus="已匹配："..tostring(label); return true end
    local wrote,writeErr=Action("X2Team:SetRole",TeamApi,"SetRole",desired)
    if wrote~=true then self.AutoRoleStatus="设置失败："..tostring(writeErr or currentErr or "unknown"); return false,writeErr end
    self.AutoRoleStatus="已请求："..tostring(label).."（等待团队同步）"
    return true
end
function TeamTools:ScheduleAutoRole(reason,delayMs)
    if self.enabled~=true or self.State.autoRoleEnabled==false then return true end
    if S.Scheduler==nil or type(S.Scheduler.AddOneShot)~="function" then return false,"自动职责 Scheduler 不可用" end
    S.Scheduler:RemoveTask(TEAM_AUTO_ROLE_TASK)
    local ok=S.Scheduler:AddOneShot(TEAM_AUTO_ROLE_TASK,math.max(100,tonumber(delayMs) or 180),function() return TeamTools:ApplyAutoRole(reason) end,self,"P2",1)
    if ok==true and type(S.Scheduler.SetTaskModule)=="function" then S.Scheduler:SetTaskModule(TEAM_AUTO_ROLE_TASK,self.Id,true) end
    return ok==true,ok==true and nil or "自动职责任务创建失败"
end
function TeamTools:StartAutoRoleObservation()
    if self.AutoRoleSubscribed==true then return true end
    if S.Events==nil then return false,"自动职责事件总线不可用" end
    S.Events:BindOwner(self,self.Id)
    local ok1=S.Events:SubscribeOptional("ABILITY_SET_CHANGED",self,function() TeamTools:ScheduleAutoRole("ability_set",150) end)
    local ok2=S.Events:SubscribeOptional("ABILITY_CHANGED",self,function() TeamTools:ScheduleAutoRole("ability",150) end)
    local ok3=type(S.Events.SubscribeInternal)=="function" and S.Events:SubscribeInternal("v3.team_roster.updated",self,function() TeamTools:ScheduleAutoRole("team_roster",250) end) or false
    if ok1~=true or ok2~=true or ok3~=true then S.Events:UnsubscribeOwner(self); if type(S.Events.UnsubscribeInternalOwner)=="function" then S.Events:UnsubscribeInternalOwner(self) end; return false,"自动职责事件订阅失败" end
    self.AutoRoleSubscribed=true; self:ScheduleAutoRole("enable",300); return true
end
function TeamTools:StopAutoRoleObservation()
    if S.Scheduler and type(S.Scheduler.RemoveTask)=="function" then S.Scheduler:RemoveTask(TEAM_AUTO_ROLE_TASK) end
    if S.Events then if type(S.Events.UnsubscribeOwner)=="function" then S.Events:UnsubscribeOwner(self) end; if type(S.Events.UnsubscribeInternalOwner)=="function" then S.Events:UnsubscribeInternalOwner(self) end end
    self.AutoRoleSubscribed=false; return true
end
local TeamToolsBaseEnable,TeamToolsBaseDisable=TeamTools.Enable,TeamTools.Disable
function TeamTools:Enable(reason)
    local ok,err=TeamToolsBaseEnable(self,reason); if ok~=true then return false,err end
    if self.State.autoRoleEnabled~=false then local obs,obsErr=self:StartAutoRoleObservation(); if obs~=true then TeamToolsBaseDisable(self,"auto_role_start_rollback"); return false,obsErr end end
    return true
end
function TeamTools:Disable(reason)
    self:StopAutoRoleObservation()
    return TeamToolsBaseDisable(self,reason)
end
TeamTools.AutoRoleContractVersion=1
NewFeature("combat_raid_recruitment", { apiDependencies = { "X2Team:RaidRecruitDel", "X2Team:RaidApplicantList" },
    read = function(feature)
        local ok, list, callErr = Call("X2Team:RaidApplicantList", TeamApi, "RaidApplicantList")
        if not ok then
            if tostring(callErr or ""):find("capability cooldown active", 1, true) then
                -- A fast manual refresh must not erase the last proven applicant
                -- projection just because the official query pacing window is
                -- still active. Keep stale-but-honest rows and surface the gate.
                return Copy(feature.Authority.rows), "partial", "申请列表刷新冷却中；保留上一份投影：" .. tostring(callErr)
            end
            return {}, "unavailable", "招募申请列表不可用：" .. tostring(callErr or "native read failed")
        end
        local rows = {}
        for key, value in pairs(type(list) == "table" and list or {}) do rows[#rows + 1] = { key = "applicant:" .. tostring(key), name = Text(value and (value.name or value.characterName), key), text = Text(value and (value.level or value.gearScore), "申请人"), statusText = "只读申请", tone = "default" } end
        return rows, "partial", "当前只安全读取申请列表并允许关闭招募；创建 9 字段语义与 charIds 写入形态仍待 RU 验证"
    end,
    commands = {
        Create = function() return false, "创建招募已安全停用：RaidRecruitAdd 需要 type/subType/headcount/limitLevel/autoJoin/msg/hour/minute/limitGearPoint 共 9 个已验证字段" end,
        Close = function(_) return Action("X2Team:RaidRecruitDel", TeamApi, "RaidRecruitDel") end,
        Accept = function() return false, "接受申请已安全停用：RaidApplicantAccept(charIds) 的 charIds 形态尚未实机验证" end,
        Reject = function() return false, "拒绝申请已安全停用：RaidApplicantReject(charIds) 的 charIds 形态尚未实机验证" end,
    },
})

-- Life/tools data reads with an explicit craft context.  The native craft
-- payloads are not a stable Lua schema, so this deliberately keeps a small
-- bounded extractor here instead of presenting an opaque "list returned"
-- string as a completed product capability.  The same read/command/projection
-- objects are registered for both craft features below.
local CRAFT_MAX_TYPES = 16
local CRAFT_MAX_ROWS = 64
local CRAFT_MAX_NODES = 256
local CRAFT_TEXT_LIMIT = 768
local CRAFT_ITEM_TYPE_KEYS = { "itemType", "itemTypeId", "item_type", "typeId" }
local CRAFT_NAME_KEYS = { "name", "itemName", "displayName", "title" }
local CRAFT_COUNT_KEYS = { "count", "amount", "requiredCount", "requireCount", "needCount", "itemCount", "stackCount", "quantity", "num" }
local CRAFT_GRADE_KEYS = { "itemGrade", "grade", "item_grade", "gradeId" }

local function CraftInteger(value, allowZero)
    local n = Number(Scalar(value))
    if n == nil or n ~= math.floor(n) or (allowZero and n < 0 or not allowZero and n < 1) then return nil end
    return math.floor(n)
end

local function CraftText(value, fallback)
    local text = value == nil and (fallback or "") or tostring(value)
    if #text <= CRAFT_TEXT_LIMIT then return text, false end
    return text:sub(1, CRAFT_TEXT_LIMIT) .. "…", true
end

local function CraftNumberField(value, keys)
    if type(value) ~= "table" then return nil end
    for _, key in ipairs(keys or {}) do
        local number = CraftInteger(value[key], false)
        if number ~= nil then return number end
    end
    return nil
end

local function CraftTextField(value, keys)
    if type(value) ~= "table" then return nil end
    for _, key in ipairs(keys or {}) do
        local text = value[key]
        if type(text) == "string" and text ~= "" then return text end
    end
    return nil
end

local function CraftRecord(value, inheritedCount)
    if type(value) ~= "table" then return nil end
    local itemType = CraftNumberField(value, CRAFT_ITEM_TYPE_KEYS)
    local name = CraftTextField(value, CRAFT_NAME_KEYS)
    local count = CraftNumberField(value, CRAFT_COUNT_KEYS) or inheritedCount
    local grade = CraftNumberField(value, CRAFT_GRADE_KEYS)
    for _, key in ipairs({ "itemInfo", "item", "info", "productInfo", "materialInfo" }) do
        local child = value[key]
        if type(child) == "table" then
            itemType = itemType or CraftNumberField(child, CRAFT_ITEM_TYPE_KEYS)
            name = name or CraftTextField(child, CRAFT_NAME_KEYS)
            count = count or CraftNumberField(child, CRAFT_COUNT_KEYS)
            grade = grade or CraftNumberField(child, CRAFT_GRADE_KEYS)
        end
    end
    -- A few native bindings expose { itemType, count } pairs instead of named
    -- fields.  Accept that shape only when the first scalar is a positive ID.
    if itemType == nil and type(value[1]) ~= "table" then itemType = CraftInteger(value[1], false) end
    if count == nil and type(value[2]) ~= "table" then count = CraftInteger(value[2], true) end
    if itemType == nil and name == nil and count == nil then return nil end
    return {
        itemType = itemType,
        name = name,
        count = count,
        grade = grade,
        status = itemType ~= nil and name ~= nil and count ~= nil and "ready" or "missing",
    }
end

local function CraftCollectRecords(payload)
    local rows, seen, diagnostics = {}, {}, { sourceCount = 0, truncated = false, nodes = 0 }
    local function visit(value, inheritedCount, depth)
        if type(value) ~= "table" then return end
        if depth > 8 or seen[value] then return end
        seen[value] = true
        diagnostics.nodes = diagnostics.nodes + 1
        if diagnostics.nodes > CRAFT_MAX_NODES then diagnostics.truncated = true; return end
        local record = CraftRecord(value, inheritedCount)
        if record ~= nil then
            diagnostics.sourceCount = diagnostics.sourceCount + 1
            if #rows < CRAFT_MAX_ROWS then rows[#rows + 1] = record else diagnostics.truncated = true end
        end
        -- Visit arrays first for deterministic native list order, then named
        -- children.  Identity wrappers are already folded into this record.
        for index, child in ipairs(value) do
            if type(child) == "table" then visit(child, CraftNumberField(value, CRAFT_COUNT_KEYS), depth + 1) end
        end
        for key, child in pairs(value) do
            if type(child) == "table" and type(key) ~= "number" and key ~= "itemInfo" and key ~= "item" and key ~= "info" and key ~= "productInfo" and key ~= "materialInfo" then
                visit(child, CraftNumberField(value, CRAFT_COUNT_KEYS), depth + 1)
            end
        end
    end
    visit(payload, nil, 0)
    return rows, diagnostics
end

local CRAFT_STATUS_ZH = {
    ready = "可用", incomplete = "部分可用", failed = "读取失败", empty = "暂无数据",
    opaque = "字段待核", partial = "部分可用", unavailable = "不可用", resolved = "已匹配",
    missing = "字段不完整", idle = "等待选择",
}
local CRAFT_ZONE_ZH = {
    [1]="格威尔森林", [2]="玛瑞诺普", [3]="碎石平原", [4]="黎明半岛", [5]="索兹里德半岛",
    [6]="黎利尔丘陵", [7]="彩虹荒野", [8]="双冠丘陵", [9]="摩哈特比", [10]="空气之原",
    [11]="猎鹰高原", [12]="咏唱之地", [13]="烈日峡谷", [14]="风刃废墟", [15]="棋盘石林",
    [16]="洛卡棋盘", [17]="伊尼斯泰尔", [18]="白雪森林", [19]="埋骨之地", [20]="十字星平原",
    [21]="珊瑚海岸北部", [22]="黄金平原", [23]="翡翠谷", [24]="虎脊山脉", [25]="古代森林",
    [26]="地狱沼泽", [27]="珊瑚海岸", [54]="墟境之口", [56]="煦日之野", [57]="黄金废墟",
    [93]="安息之地", [99]="洛卡山脉", [102]="海之烛台", [103]="鲸鱼歌湾",
}
local function CraftStatusText(value) return CRAFT_STATUS_ZH[tostring(value or "")] or tostring(value or "未知") end
local function CraftItemName(itemType, nativeName)
    local id = tonumber(itemType)
    if id ~= nil and S.Localization ~= nil and type(S.Localization.GetName) == "function" then
        local ok, value = pcall(S.Localization.GetName, S.Localization, "item", id, nil)
        if ok == true and type(value) == "string" and value ~= "" then return value end
    end
    if type(nativeName) == "string" and nativeName ~= "" and nativeName:find("[\128-\255]") ~= nil then return nativeName end
    return id ~= nil and "已识别物品" or "物品"
end
local function CraftFamilyLabel(record)
    local name = tostring(type(record)=="table" and record.legacyName or "")
    if name:find("Gilda Specialty",1,true) then return "特制特产" end
    if name:find("Local Specialty",1,true) then return "传统特产" end
    if name:find("Fertilizer Specialty",1,true) then return "肥料特产" end
    return "特产"
end
local CRAFT_RECIPE_OPTIONS
local function CraftRecipeOptions()
    if type(CRAFT_RECIPE_OPTIONS)=="table" then return CRAFT_RECIPE_OPTIONS end
    local rows = {}
    local static = S.StaticDataV2
    if type(static)=="table" and type(static.List)=="function" then
        for _, record in ipairs(static:List("trade_recipe")) do
            local craftId = tonumber(record and record.craftId)
            if craftId ~= nil and type(record.key)=="string" then
                local zone = CRAFT_ZONE_ZH[tonumber(record.originZoneId)] or "已核地区"
                rows[#rows+1] = { value=record.key, text=zone .. " · " .. CraftFamilyLabel(record), craftId=math.floor(craftId) }
            end
        end
    end
    table.sort(rows,function(a,b) if a.text==b.text then return tostring(a.value)<tostring(b.value) end return a.text<b.text end)
    CRAFT_RECIPE_OPTIONS = rows
    return CRAFT_RECIPE_OPTIONS
end
local function SelectedCraftRecipe(feature)
    local key = type(feature.State)=="table" and feature.State.selectedRecipeKey or nil
    if type(key)~="string" or key=="" or S.StaticDataV2==nil or type(S.StaticDataV2.Get)~="function" then return nil end
    return S.StaticDataV2:Get("trade_recipe",key)
end
local function CraftStaticItems(recipe)
    local rows = {}
    if type(recipe)~="table" or type(recipe.ingredients)~="table" then return rows end
    for _, ingredient in ipairs(recipe.ingredients) do
        local material = S.StaticDataV2 and type(S.StaticDataV2.Get)=="function" and S.StaticDataV2:Get("trade_material",ingredient.materialKey) or nil
        local itemType = tonumber(material and material.itemId)
        rows[#rows+1] = {
            itemType=itemType, count=tonumber(ingredient.count), name=CraftItemName(itemType,nil),
            status=itemType~=nil and "ready" or "missing", source="TradeStaticV2",
        }
    end
    return rows
end
local function CraftItemText(item)
    local name = CraftItemName(item and item.itemType, item and item.name)
    local count = item and item.count ~= nil and tostring(item.count) or "数量待核"
    local held = item and item.held ~= nil and (" · 持有 " .. tostring(item.held)) or ""
    local shortage = item and item.shortage ~= nil and (" · 缺口 " .. tostring(item.shortage)) or ""
    return name .. " × " .. count .. held .. shortage
end

local function CraftQuote(item)
    if item == nil or item.itemType == nil then return nil, "identity_unknown" end
    -- GetLowestPrice is a cooldown-bound server query. A craft graph can contain
    -- many materials, so ordinary Refresh must never fan out one request per row.
    -- Pricing belongs to the explicit, rate-limited PriceQuoteQueueV3 service:
    -- the user triggers QuoteMaterial per material, the queue serializes + paces
    -- + async-callbacks the result, and the completed price is exposed through
    -- the shared itemType read model. Here we only READ that read model — never
    -- issue a server request from a Refresh.
    local queue = S.Services ~= nil and S.Services.PriceQuoteQueueV3 or nil
    local price
    if type(queue) == "table" and type(queue.GetPriceByItemType) == "function" then
        price = queue:GetPriceByItemType(item.itemType, item.itemGrade)
    end
    if price ~= nil then return price, "quoted" end
    return nil, "explicit_quote_required", "最低价需显式询价"
end

local function CraftHeldCounts()
    local held, diagnostics = {}, { status = "unknown", scanned = 0, readErrors = 0, unknownOccupied = 0, capacity = nil }
    if BagApi == nil then return held, diagnostics end
    local ok, capacity = Call("X2Bag:Capacity", BagApi, "Capacity")
    capacity = CraftInteger(capacity, true)
    if ok ~= true or capacity == nil then diagnostics.error = "背包容量未知"; return held, diagnostics end
    diagnostics.capacity = math.min(capacity, BAG_SCAN_LIMIT); diagnostics.status = "ready"
    for slot = 1, diagnostics.capacity do
        local itemOk, info = Call("X2Bag:GetBagItemInfo", BagApi, "GetBagItemInfo", 0, slot)
        diagnostics.scanned = diagnostics.scanned + 1
        if itemOk ~= true then
            diagnostics.readErrors = diagnostics.readErrors + 1
        elseif type(info) == "table" then
            local id = CraftNumberField(info, CRAFT_ITEM_TYPE_KEYS)
            local count = CraftNumberField(info, CRAFT_COUNT_KEYS)
            if id ~= nil and count ~= nil then held[id] = (held[id] or 0) + count
            elseif next(info) ~= nil then diagnostics.unknownOccupied = diagnostics.unknownOccupied + 1 end
        elseif info ~= nil then
            diagnostics.unknownOccupied = diagnostics.unknownOccupied + 1
        end
    end
    if diagnostics.readErrors > 0 or diagnostics.unknownOccupied > 0 or capacity > BAG_SCAN_LIMIT then
        diagnostics.status = "incomplete"
        diagnostics.error = diagnostics.readErrors > 0 and "背包槽位读取失败" or diagnostics.unknownOccupied > 0 and "背包存在身份未知的非空槽位" or "背包扫描达到上限"
    end
    return held, diagnostics
end

local function CraftEnrichItems(items, held, bagDiagnostics)
    local incomplete = bagDiagnostics.status ~= "ready"
    for _, item in ipairs(items or {}) do
        item.held = item.itemType ~= nil and held[item.itemType] or nil
        item.shortage = item.count ~= nil and item.held ~= nil and math.max(0, item.count - item.held) or nil
        item.unitCost, item.costStatus = CraftQuote(item)
        item.lineCost = item.unitCost ~= nil and item.count ~= nil and item.unitCost * item.count or nil
        item.status = (item.itemType ~= nil and item.count ~= nil and item.unitCost ~= nil and item.held ~= nil) and "ready" or "incomplete"
        if bagDiagnostics.status ~= "ready" then item.status = "incomplete" end
        if item.status ~= "ready" then incomplete = true end
    end
    return incomplete
end

local function CraftSection(kind, ok, payload, errorText, craftType, doodadId)
    local section = {
        kind = kind, source = "X2Craft:GetCraft" .. (kind == "base" and "BaseInfo" or kind == "product" and "ProductInfo" or "MaterialInfo"),
        craftType = craftType, doodadId = doodadId, failed = false, empty = false, opaque = false,
        truncated = false, sourceCount = 0, items = {}, status = "empty",
    }
    if ok ~= true then
        section.failed = true; section.status = "failed"; section.error = Text(errorText, "原生数据读取失败")
        section.text = (kind == "product" and "产物" or "材料") .. "读取失败：" .. section.error
        return section
    end
    if payload == nil then
        section.empty = true; section.text = (kind == "product" and "产物" or "材料") .. "暂无数据"
        return section
    end
    if type(payload) ~= "table" then
        section.opaque = true; section.status = "opaque"
        section.text, section.textTruncated = CraftText((kind == "product" and "产物" or "材料") .. "返回字段待核", nil)
        return section
    end
    if next(payload) == nil then
        section.empty = true; section.text = (kind == "product" and "产物" or "材料") .. "暂无数据"
        return section
    end
    local records, diagnostics = CraftCollectRecords(payload)
    section.items, section.sourceCount, section.truncated = records, diagnostics.sourceCount, diagnostics.truncated
    if #records == 0 then
        section.opaque = true; section.status = "opaque"
        section.text = (kind == "product" and "产物" or "材料") .. "返回结构待核"
        return section
    end
    section.status = "ready"
    local parts = {}
    for index, item in ipairs(records) do parts[index] = CraftItemText(item) end
    if section.truncated then
        local suffix = "已截断，原始记录 " .. tostring(section.sourceCount) .. " 条"
        local prefixLimit = math.max(32, CRAFT_TEXT_LIMIT - #suffix - #kind - 6)
        local prefix = ((kind == "product" and "产物：" or "材料：") .. table.concat(parts, "；")):sub(1, prefixLimit)
        section.text = prefix .. "… " .. suffix
        section.textTruncated = true
    else
        section.text, section.textTruncated = CraftText((kind == "product" and "产物：" or "材料：") .. table.concat(parts, "；"), nil)
    end
    return section
end

local function CraftBaseSection(ok, payload, errorText, craftType)
    local section = { kind = "base", source = "X2Craft:GetCraftBaseInfo", craftType = craftType, failed = false, empty = false, opaque = false, truncated = false, fields = {}, status = "empty" }
    if ok ~= true then section.failed = true; section.status = "failed"; section.error = Text(errorText, "读取失败"); section.text = "基础信息读取失败：" .. section.error; return section end
    if payload == nil then section.empty = true; section.text = "基础信息暂无数据"; return section end
    if type(payload) ~= "table" then section.opaque = true; section.status = "opaque"; section.text, section.textTruncated = CraftText("基础信息返回字段待核", nil); return section end
    if next(payload) == nil then section.empty = true; section.text = "基础信息暂无数据"; return section end
    for _, key in ipairs({ "craftType", "craftTypeId", "name", "title", "itemType", "itemTypeId", "level", "duration", "doodadId" }) do
        local value = payload[key]
        if type(value) == "number" or type(value) == "string" then section.fields[key] = value end
    end
    if next(section.fields) == nil then section.opaque = true; section.status = "opaque"; section.text = "基础信息返回结构待核"; return section end
    section.status = "ready"
    local parts = {}
    for _, key in ipairs({ "craftType", "craftTypeId", "name", "title", "itemType", "itemTypeId", "level", "duration", "doodadId" }) do
        if section.fields[key] ~= nil then parts[#parts + 1] = key .. "=" .. tostring(section.fields[key]) end
    end
    section.text, section.textTruncated = CraftText("基础信息已读取（详细字段仅用于诊断）", nil)
    return section
end

local function CraftCollectTypeIds(value, output, seen, depth)
    if #output >= CRAFT_MAX_TYPES or depth > 6 then return end
    local scalar = CraftInteger(value, false)
    if scalar ~= nil and type(value) ~= "table" then
        if not seen[scalar] then seen[scalar] = true; output[#output + 1] = scalar end
        return
    end
    if type(value) ~= "table" or seen[value] then return end
    seen[value] = true
    for _, key in ipairs({ "craftType", "craftTypeId", "craft_type" }) do
        local id = CraftInteger(value[key], false)
        if id ~= nil and not seen[id] then seen[id] = true; output[#output + 1] = id end
    end
    for key, child in pairs(value) do
        if type(key) == "number" or key == "craftTypes" or key == "types" or key == "list" then CraftCollectTypeIds(child, output, seen, depth + 1) end
    end
end

-- Bounded graph projection over records already returned by the verified
-- X2Craft getters. This deliberately does not enumerate the catalog or issue
-- recursive API calls: unknown children remain visible as unresolved leaves.
local CRAFT_GRAPH_MAX_DEPTH = 6
local CRAFT_GRAPH_MAX_NODES = 256
local CRAFT_GRAPH_MAX_QUANTITY = 1000000000

local function CraftGraphInteger(value)
    local n = tonumber(value)
    if n == nil or n ~= math.floor(n) or n < 1 then return nil end
    return math.floor(n)
end

local function CraftGraphRecordMap(records, diagnostics)
    local byProduct, ambiguous = {}, {}
    for _, recipe in ipairs(type(records) == "table" and records or {}) do
        local craftType = CraftGraphInteger(recipe and recipe.craftType)
        local products = recipe and recipe.product and recipe.product.items
        if craftType == nil or type(products) ~= "table" then
            diagnostics.missingRecords = diagnostics.missingRecords + 1
        else
            for _, product in ipairs(products) do
                local itemType = CraftGraphInteger(product and product.itemType)
                if itemType ~= nil then
                    if byProduct[itemType] ~= nil and byProduct[itemType] ~= craftType then
                        ambiguous[itemType] = true
                    else
                        byProduct[itemType] = craftType
                    end
                else
                    diagnostics.malformedProducts = diagnostics.malformedProducts + 1
                end
            end
        end
    end
    for itemType in pairs(ambiguous) do byProduct[itemType] = nil; diagnostics.ambiguous = diagnostics.ambiguous + 1 end
    return byProduct
end

function S.BuildCraftRecipeGraph(records, roots)
    local diagnostics = {
        status = "ready", nodes = 0, edges = 0, maxDepth = 0, unresolved = 0,
        cycles = 0, ambiguous = 0, missingRecords = 0, malformedProducts = 0,
        malformedMaterials = 0, quantityOverflow = 0, truncated = false,
    }
    local byCraft, byProduct = {}, CraftGraphRecordMap(records, diagnostics)
    for _, recipe in ipairs(type(records) == "table" and records or {}) do
        local craftType = CraftGraphInteger(recipe and recipe.craftType)
        if craftType ~= nil then byCraft[craftType] = recipe end
    end
    local graph = { roots = {}, nodes = {}, edges = {}, diagnostics = diagnostics, maxDepth = CRAFT_GRAPH_MAX_DEPTH, maxNodes = CRAFT_GRAPH_MAX_NODES }
    local function visit(itemType, quantity, depth, path)
        if diagnostics.nodes >= CRAFT_GRAPH_MAX_NODES then diagnostics.truncated = true; return nil end
        local item = CraftGraphInteger(itemType); local amount = CraftGraphInteger(quantity)
        if item == nil or amount == nil then diagnostics.malformedMaterials = diagnostics.malformedMaterials + 1; return nil end
        if amount > CRAFT_GRAPH_MAX_QUANTITY then diagnostics.quantityOverflow = diagnostics.quantityOverflow + 1; return nil end
        diagnostics.nodes = diagnostics.nodes + 1; diagnostics.maxDepth = math.max(diagnostics.maxDepth, depth)
        local node = { itemType = item, quantity = amount, depth = depth, status = "unresolved" }
        graph.nodes[#graph.nodes + 1] = node
        local craftType = byProduct[item]
        if depth >= CRAFT_GRAPH_MAX_DEPTH then diagnostics.truncated = true; node.status = "depth_limit"; diagnostics.unresolved = diagnostics.unresolved + 1; return node end
        if craftType == nil then diagnostics.unresolved = diagnostics.unresolved + 1; return node end
        if path[craftType] then diagnostics.cycles = diagnostics.cycles + 1; node.status = "cycle"; diagnostics.unresolved = diagnostics.unresolved + 1; return node end
        local recipe = byCraft[craftType]; local materials = recipe and recipe.materials and recipe.materials.items
        if type(materials) ~= "table" or recipe.materials.failed == true or recipe.materials.opaque == true then
            diagnostics.unresolved = diagnostics.unresolved + 1; node.status = "missing_materials"; return node
        end
        node.status = "expanded"; node.craftType = craftType
        local nextPath = {}; for key, value in pairs(path) do nextPath[key] = value end; nextPath[craftType] = true
        for _, material in ipairs(materials) do
            local materialType = CraftGraphInteger(material and material.itemType)
            local required = CraftGraphInteger(material and material.count)
            if materialType == nil or required == nil then
                diagnostics.malformedMaterials = diagnostics.malformedMaterials + 1
            else
                local productCount = 1
                local productItems = recipe.product and recipe.product.items or {}
                for _, product in ipairs(productItems) do if CraftGraphInteger(product.itemType) == item then productCount = CraftGraphInteger(product.count) or 1; break end end
                local craftCount = math.floor((amount + productCount - 1) / productCount)
                local total = required
                if craftCount > math.floor(CRAFT_GRAPH_MAX_QUANTITY / math.max(1, required)) then total = CRAFT_GRAPH_MAX_QUANTITY + 1 else total = required * craftCount end
                if total > CRAFT_GRAPH_MAX_QUANTITY then diagnostics.quantityOverflow = diagnostics.quantityOverflow + 1
                else graph.edges[#graph.edges + 1] = { from = item, to = materialType, quantity = total, craftType = craftType }; diagnostics.edges = diagnostics.edges + 1; visit(materialType, total, depth + 1, nextPath) end
            end
        end
        return node
    end
    for _, root in ipairs(type(roots) == "table" and roots or {}) do
        local itemType = CraftGraphInteger(root and root.itemType or root)
        local quantity = CraftGraphInteger(root and root.quantity or 1)
        if itemType ~= nil and quantity ~= nil then graph.roots[#graph.roots + 1] = visit(itemType, quantity, 0, {}) else diagnostics.malformedMaterials = diagnostics.malformedMaterials + 1 end
    end
    if diagnostics.truncated or diagnostics.quantityOverflow > 0 or diagnostics.cycles > 0 or diagnostics.ambiguous > 0 or diagnostics.unresolved > 0 then diagnostics.status = "partial" end
    return graph
end

local function CraftResolveTypes(feature)
    local state = feature.State or {}
    local itemType = state.itemType == nil and nil or CraftInteger(state.itemType, false)
    local craftType = state.craftType == nil and nil or CraftInteger(state.craftType, false)
    if (state.itemType ~= nil and itemType == nil) or (state.craftType ~= nil and craftType == nil) then return {}, { status = "failed", error = "制作物内部标识无效，请重新选择" } end
    if itemType ~= nil and craftType ~= nil then return {}, { status = "failed", error = "制作物上下文冲突，请重新选择" } end
    if craftType ~= nil then return { craftType }, { status = "ready", source = "已选制作物", itemType = nil, craftType = craftType } end
    if itemType == nil then return {}, { status = "empty", source = "未选择制作物", itemType = nil } end
    local ok, first, errorText, second, third, fourth = Call("X2Craft:GetCraftTypeByItemType", CraftApi, "GetCraftTypeByItemType", itemType)
    if ok ~= true then return {}, { status = "failed", source = "X2Craft:GetCraftTypeByItemType", itemType = itemType, error = Text(errorText, "制作配方查询失败") } end
    local types, seen = {}, {}
    for _, value in ipairs({ first, second, third, fourth }) do CraftCollectTypeIds(value, types, seen, 0) end
    if #types == 0 then return {}, { status = "empty", source = "X2Craft:GetCraftTypeByItemType", itemType = itemType, error = "当前物品没有返回可用制作配方" } end
    return types, { status = "ready", source = "X2Craft:GetCraftTypeByItemType", itemType = itemType, craftTypes = Copy(types) }
end

local function CraftRead(feature)
    local rows, recipes = {}, {}
    local selectedRecipe = SelectedCraftRecipe(feature)
    if selectedRecipe ~= nil and tonumber(selectedRecipe.craftId) ~= nil then
        feature.State.craftType = math.floor(tonumber(selectedRecipe.craftId))
        feature.State.itemType = nil
    end
    local craftTypes, resolution = CraftResolveTypes(feature)
    if #craftTypes == 0 then
        rows[#rows + 1] = { key = "craft:resolution", name = "制作上下文", text = resolution.status == "empty" and "请从上方制作物列表选择需要规划的配方" or Text(resolution.error, "制作上下文不可用"), statusText = CraftStatusText(resolution.status), tone = resolution.status == "failed" and "warn" or "default", source = resolution.source, failed = resolution.status == "failed", empty = resolution.status == "empty" }
        feature.CraftProjection = { context = resolution, recipes = {}, source = resolution.source, status = resolution.status, error = resolution.error }
        return rows, resolution.status == "empty" and "empty" or "unavailable", resolution.error
    end
    rows[#rows + 1] = { key = "craft:resolution", name = "当前制作物", text = selectedRecipe ~= nil and ((CRAFT_ZONE_ZH[tonumber(selectedRecipe.originZoneId)] or "已核地区") .. " · " .. CraftFamilyLabel(selectedRecipe)) or "已读取当前制作上下文", statusText = "已匹配", tone = "default", source = resolution.source, itemType = resolution.itemType, craftTypes = Copy(craftTypes) }
    local anyReadable, anyReady, errors = false, false, {}
    local held, bagDiagnostics = CraftHeldCounts()
    local doodadId = feature.State.doodadId == nil and 0 or CraftInteger(feature.State.doodadId, true)
    if doodadId == nil then doodadId = 0 end
    for _, craftType in ipairs(craftTypes) do
        local okBase, base, baseError = Call("X2Craft:GetCraftBaseInfo", CraftApi, "GetCraftBaseInfo", craftType)
        local okProduct, product, productError = Call("X2Craft:GetCraftProductInfo", CraftApi, "GetCraftProductInfo", craftType)
        local okMaterial, material, materialError = Call("X2Craft:GetCraftMaterialInfo", CraftApi, "GetCraftMaterialInfo", craftType, doodadId)
        local recipe = { craftType = craftType, base = CraftBaseSection(okBase, base, baseError, craftType), product = CraftSection("product", okProduct, product, productError, craftType, doodadId), materials = CraftSection("materials", okMaterial, material, materialError, craftType, doodadId) }
        if selectedRecipe ~= nil and tonumber(selectedRecipe.craftId) == tonumber(craftType) then
            if (recipe.product.failed or recipe.product.opaque or #(recipe.product.items or {}) == 0) and tonumber(selectedRecipe.productItemId) ~= nil then
                recipe.product = { kind="product", source="TradeStaticV2", craftType=craftType, doodadId=doodadId, failed=false, empty=false, opaque=false, truncated=false, sourceCount=1, status="ready", items={{ itemType=tonumber(selectedRecipe.productItemId), count=1, name=CraftItemName(selectedRecipe.productItemId,nil), status="ready", source="TradeStaticV2" }}, text="产物：" .. CraftItemName(selectedRecipe.productItemId,nil) .. " × 1", staticFallback=true }
            end
            if recipe.materials.failed or recipe.materials.opaque or #(recipe.materials.items or {}) == 0 then
                local staticItems = CraftStaticItems(selectedRecipe)
                if #staticItems > 0 then
                    local parts={}; for _, item in ipairs(staticItems) do parts[#parts+1]=CraftItemText(item) end
                    recipe.materials = { kind="materials", source="TradeStaticV2", craftType=craftType, doodadId=doodadId, failed=false, empty=false, opaque=false, truncated=false, sourceCount=#staticItems, status="ready", items=staticItems, text="材料：" .. table.concat(parts,"；"), staticFallback=true }
                end
            end
        end
        recipe.product.incomplete = CraftEnrichItems(recipe.product.items, held, bagDiagnostics)
        recipe.materials.incomplete = CraftEnrichItems(recipe.materials.items, held, bagDiagnostics)
        recipes[#recipes + 1] = recipe
        for _, section in ipairs({ recipe.base, recipe.product, recipe.materials }) do
            if section.failed then errors[#errors + 1] = section.kind .. "(" .. tostring(craftType) .. "): " .. tostring(section.error) else anyReadable = true end
            if section.status == "ready" then anyReady = true end
        end
        rows[#rows + 1] = { key = "craft:" .. tostring(craftType) .. ":base", name = "制作基础", text = recipe.base.text, statusText = CraftStatusText(recipe.base.status), tone = recipe.base.failed and "warn" or "default", source = recipe.base.source, fields = Copy(recipe.base.fields), failed = recipe.base.failed, empty = recipe.base.empty, opaque = recipe.base.opaque }
        rows[#rows + 1] = { key = "craft:" .. tostring(craftType) .. ":product", name = "制作产物", text = recipe.product.text, statusText = recipe.product.incomplete and "部分可用" or CraftStatusText(recipe.product.status), tone = recipe.product.failed and "warn" or "default", source = recipe.product.source, items = Copy(recipe.product.items), sourceCount = recipe.product.sourceCount, truncated = recipe.product.truncated, failed = recipe.product.failed, empty = recipe.product.empty, opaque = recipe.product.opaque, cost = recipe.product.items }
        rows[#rows + 1] = { key = "craft:" .. tostring(craftType) .. ":materials", name = "所需材料", text = recipe.materials.text, statusText = recipe.materials.incomplete and "部分可用" or CraftStatusText(recipe.materials.status), tone = recipe.materials.failed and "warn" or "default", source = recipe.materials.source, items = Copy(recipe.materials.items), sourceCount = recipe.materials.sourceCount, truncated = recipe.materials.truncated, failed = recipe.materials.failed, empty = recipe.materials.empty, opaque = recipe.materials.opaque, cost = recipe.materials.items }
    end
    local graphRoots = {}
    for _, recipe in ipairs(recipes) do
        for _, product in ipairs(recipe.product.items or {}) do
            if product.itemType ~= nil and product.count ~= nil then graphRoots[#graphRoots + 1] = { itemType = product.itemType, quantity = product.count } end
        end
    end
    local graph = S.BuildCraftRecipeGraph(recipes, graphRoots)
    local gd = graph.diagnostics
    rows[#rows + 1] = { key = "craft:graph", name = "成本图", text = "已知记录内展开 " .. tostring(gd.nodes) .. " 节点 / " .. tostring(gd.edges) .. " 边；未解析 " .. tostring(gd.unresolved) .. "，循环 " .. tostring(gd.cycles) .. "，歧义 " .. tostring(gd.ambiguous) .. (gd.truncated and "；已截断" or "；不代表完整目录"), statusText = CraftStatusText(gd.status), tone = gd.status == "ready" and "default" or "warn", source = "bounded_known_x2craft_records", graph = graph }
    local status = anyReady and "ready" or anyReadable and "empty" or "unavailable"
    local errorText = #errors > 0 and table.concat(errors, "; ") or nil
    feature.CraftProjection = { context = resolution, doodadId = doodadId, recipes = recipes, graph = graph, held = held, bag = bagDiagnostics, source = "X2Craft", status = status, error = errorText }
    return rows, status, errorText
end

local function CraftProjection(feature)
    return {
        craft = Copy(feature.CraftProjection or { context = { status = "idle" }, recipes = {} }),
        recipeOptions = Copy(CraftRecipeOptions()),
        selectedRecipeKey = feature.State.selectedRecipeKey,
    }
end

local function CraftPersist(feature, reason, mutator)
    if type(P.MutateStore) ~= "function" then return false, "制作上下文持久化事务不可用" end
    local marked, markErr = P:MutateStore(feature.storeId, function()
        mutator()
        return true
    end, { delayMs = 300, reason = tostring(reason or "craft_changed") })
    if marked ~= true then return false, "制作上下文未保存，已回滚：" .. tostring(markErr or "store write rejected") end
    return feature:Refresh(reason)
end

local function CraftCommands()
    return {
        SelectRecipe = function(feature, value)
            local key = tostring(value or "")
            local record = S.StaticDataV2 ~= nil and type(S.StaticDataV2.Get)=="function" and S.StaticDataV2:Get("trade_recipe", key) or nil
            local craftId = tonumber(record and record.craftId)
            if type(record)~="table" or craftId==nil then return false, "所选制作物没有已核配方" end
            return CraftPersist(feature, "craft_recipe_select", function()
                feature.State.selectedRecipeKey = record.key
                feature.State.craftType = math.floor(craftId)
                feature.State.itemType = nil
                feature.State.doodadId = 0
            end)
        end,
        SetCraftType = function(feature, value)
            local craftType = CraftInteger(value, false); if craftType == nil then return false, "制作配方编号必须是正整数" end
            return CraftPersist(feature, "craft_type", function() feature.State.craftType = craftType; feature.State.itemType = nil; feature.State.selectedRecipeKey = nil end)
        end,
        SetItemType = function(feature, value)
            local itemType = CraftInteger(value, false); if itemType == nil then return false, "物品编号必须是正整数" end
            return CraftPersist(feature, "craft_item_type", function() feature.State.itemType = itemType; feature.State.craftType = nil; feature.State.selectedRecipeKey = nil end)
        end,
        SetDoodadId = function(feature, value)
            local doodadId = CraftInteger(value, true); if doodadId == nil then return false, "制作台对象编号必须是非负整数" end
            return CraftPersist(feature, "craft_doodad", function() feature.State.doodadId = doodadId end)
        end,
        -- Explicit single-material lowest-price quote. Ordinary Refresh never
        -- fans out GetLowestPrice; the user triggers a quote per material here,
        -- and the shared PriceQuoteQueueV3 serializes + paces + async-callbacks
        -- the result (see "explicit + async" quote semantics).
        QuoteMaterial = function(_, itemType, itemGrade)
            local queue = S.Services ~= nil and S.Services.PriceQuoteQueueV3 or nil
            if type(queue) ~= "table" or type(queue.RequestQuote) ~= "function" then return false, "报价服务不可用" end
            local ok, status = queue:RequestQuote("tools_craft", itemType, itemGrade, nil)
            if ok ~= true then return false, status or "报价请求失败" end
            return true, status or "queued"
        end,
    }
end

local CRAFT_API_DEPENDENCIES = { "X2Craft:GetCraftBaseInfo", "X2Craft:GetCraftMaterialInfo", "X2Craft:GetCraftProductInfo", "X2Craft:GetCraftTypeByItemType", "X2Bag:Capacity", "X2Bag:GetBagItemInfo" }
local CraftPlanner = NewFeature("life_craft_planner", { apiDependencies = CRAFT_API_DEPENDENCIES, state = { selectedRecipeKey = nil, craftType = nil, itemType = nil, doodadId = 0 }, default = { selectedRecipeKey = nil, craftType = nil, itemType = nil, doodadId = 0 }, read = CraftRead, projection = CraftProjection, commands = CraftCommands() })
local CraftAssistant = NewFeature("tools_craft", { apiDependencies = CRAFT_API_DEPENDENCIES, state = { selectedRecipeKey = nil, craftType = nil, itemType = nil, doodadId = 0 }, default = { selectedRecipeKey = nil, craftType = nil, itemType = nil, doodadId = 0 }, read = CraftRead, projection = CraftProjection, commands = CraftCommands() })
CraftPlanner.CraftUserSelectionContractVersion = 1
CraftAssistant.CraftUserSelectionContractVersion = 1

local function EnsureBlacklist(feature)
    if type(feature.State.blacklist) ~= "table" then feature.State.blacklist = BlacklistDefault() end
    return feature.State.blacklist
end

local function SetBlacklistEnabled(feature, value)
    local enabled = NormalizeBoolean(value)
    if enabled == nil then return false, "黑名单开关必须是 true/false" end
    return MutateBlacklist(feature, "bag_blacklist_enabled", function(config)
        local changed = config.enabled ~= enabled
        config.enabled = enabled
        return true, changed
    end)
end

local function SetBlacklistScope(feature, value)
    local scope = NormalizeScope(value)
    if scope == nil then return false, "范围必须是 bank 或 coffer" end
    return MutateBlacklist(feature, "bag_blacklist_scope", function(config)
        local changed = config.activeScope ~= scope
        config.activeScope = scope
        return true, changed
    end)
end

local function AddBlacklistValue(feature, scopeValue, field, value, normalizer, reason)
    local scope = NormalizeScope(scopeValue)
    if scope == nil then return false, "范围必须是 bank 或 coffer" end
    local key = normalizer(value)
    if key == nil then
        return false, field == "itemType" and "物品编号必须是正整数" or "物品类别编号必须是 1-64 个可见字符"
    end
    EnsureBlacklist(feature)
    return MutateBlacklist(feature, reason, function(config)
        local bucket = config[scope]
        local map = bucket[field]
        if MapContains(map, key) then return true, false end
        if BlacklistEntryCount(config) >= BLACKLIST_MAX_ENTRIES then return false, "黑名单条目已达上限（64）" end
        map[key] = true
        return true, true
    end)
end

local function RemoveBlacklistValue(feature, scopeValue, field, value, normalizer, reason)
    local scope = NormalizeScope(scopeValue)
    if scope == nil then return false, "范围必须是 bank 或 coffer" end
    local key = normalizer(value)
    if key == nil then
        return false, field == "itemType" and "物品编号必须是正整数" or "物品类别编号必须是 1-64 个可见字符"
    end
    EnsureBlacklist(feature)
    return MutateBlacklist(feature, reason, function(config)
        local map = config[scope][field]
        if not MapContains(map, key) then return false, "黑名单中不存在该条目" end
        map[key], map[tonumber(key)] = nil, nil
        return true, true
    end)
end

-- compatibility contract: state = { blacklist = BlacklistDefault() }
-- compatibility contract: default = { blacklist = BlacklistDefault() }
local BagTools = NewFeature("tools_bag", { apiDependencies = {
    "X2Bag:GetBagItemInfo", "X2Bag:Capacity",
    "X2Bag:MoveToEmptyBankSlot", "X2Bag:MoveToEmptyCofferSlot",
    "X2Bank:GetBagItemInfo", "X2Bank:Capacity", "X2Bank:MoveToEmptyBagSlot",
    "X2Coffer:GetBagItemInfo", "X2Coffer:Capacity", "X2Coffer:MoveToEmptyBagSlot",
    "ADDON:GetContentMainScriptPosVis",
}, state = { blacklist = BlacklistDefault(), batchCategory = nil, batchTarget = "bank", batchLimit = BATCH_DEFAULT_LIMIT }, default = { blacklist = BlacklistDefault(), batchCategory = nil, batchTarget = "bank", batchLimit = BATCH_DEFAULT_LIMIT }, apply = ApplyBagState,
onEnable = function(feature) return StartBagQuickObserver(feature) end,
onDisable = function(feature) StopBagBatch(feature, "stopped", "功能关闭，批量任务已释放"); return StopBagQuickAll(feature, "功能关闭，快捷取放已释放") end,
projection = BatchProjection, read = function()
    -- Demand/Refresh is the only entry point for this snapshot.  Keep the
    -- full read bounded by the live bag capacity and a fixed product limit;
    -- do not turn this into an OnUpdate poller.
    local okCap, cap, capErr = Call("X2Bag:Capacity", BagApi, "Capacity")
    local capacity = Number(cap)
    if not okCap or capacity == nil or capacity < 0 then
        return {
            { key = "bag:scan", name = "背包扫描", text = "容量读取失败，未读取槽位", statusText = "读取失败", tone = "warn" },
        }, "unavailable", "背包容量不可读：" .. Text(capErr, "Capacity failed")
    end

    capacity = math.floor(capacity)
    local maxSlot = math.min(BAG_SCAN_LIMIT, capacity)
    local rows, readCount, readErrors = {}, 0, 0
    for slot = 1, maxSlot do
        local ok, item = Call("X2Bag:GetBagItemInfo", BagApi, "GetBagItemInfo", 0, slot)
        if ok then
            readCount = readCount + 1
            if type(item) == "table" and next(item) ~= nil then
                local itemType, category = SourceIdentity(item)
                local categoryText = category ~= nil and (BagCategoryLabel(category) .. "（" .. tostring(category) .. "）") or "类别未知"
                rows[#rows + 1] = {
                    key = "bag:" .. slot, name = Text(item.name or item.itemName, "槽位 " .. slot),
                    text = "物品编号：" .. Text(itemType or item.itemType or item.itemTypeId, "--") .. " · " .. categoryText,
                    statusText = "数量 " .. Text(item.stackCount or item.count, "--"), tone = "default",
                    itemType = itemType, category = category, slot = slot,
                }
            end
        else
            readErrors = readErrors + 1
        end
    end

    local truncated = capacity > BAG_SCAN_LIMIT
    local scanText = "已读槽位 " .. tostring(readCount) .. "/" .. tostring(capacity)
    if truncated then scanText = scanText .. "（上限 " .. tostring(BAG_SCAN_LIMIT) .. "，已截断）" end
    if readErrors > 0 then scanText = scanText .. "；读取失败 " .. tostring(readErrors) .. " 槽" end
    table.insert(rows, 1, {
        key = "bag:scan", name = "背包扫描", text = scanText,
        statusText = truncated and "已截断" or (readErrors > 0 and "部分失败" or "完整读取"),
        tone = (truncated or readErrors > 0) and "warn" or "default",
        capacity = capacity, scannedSlots = maxSlot, readCount = readCount,
        readErrors = readErrors, truncated = truncated,
    })
    if maxSlot == 0 then return rows, "empty", nil end
    if readCount == 0 then return rows, "unavailable", "背包槽位当前不可读" end
    local diagnostic = readErrors > 0 and ("背包有 " .. tostring(readErrors) .. " 个槽位读取失败") or nil
    return rows, "ready", diagnostic
end, commands = {
    SetBlacklistEnabled = SetBlacklistEnabled,
    SetBlacklistScope = SetBlacklistScope,
    AddBlacklistItem = function(feature, scope, value) return AddBlacklistValue(feature, scope, "itemType", value, NormalizeItemType, "bag_blacklist_item_add") end,
    RemoveBlacklistItem = function(feature, scope, value) return RemoveBlacklistValue(feature, scope, "itemType", value, NormalizeItemType, "bag_blacklist_item_remove") end,
    AddBlacklistCategory = function(feature, scope, value) return AddBlacklistValue(feature, scope, "category", value, NormalizeCategory, "bag_blacklist_category_add") end,
    RemoveBlacklistCategory = function(feature, scope, value) return RemoveBlacklistValue(feature, scope, "category", value, NormalizeCategory, "bag_blacklist_category_remove") end,
    DepositCategoryBank = function(feature, category, limit) return BatchMove(feature, "bank", category, limit) end,
    DepositCategoryCoffer = function(feature, category, limit) return BatchMove(feature, "coffer", category, limit) end,
    CancelCategoryBatch = function(feature) return StopBagBatch(feature, "cancelled", "用户取消") end,
    QuickWithdraw = function(feature) return StartBagQuick(feature,"withdraw") end,
    QuickDeposit = function(feature) return StartBagQuick(feature,"deposit") end,
    QuickCancel = function(feature) return StopBagQuick(feature,"已取消","用户取消") end,
    SetBatchConfig = SetBatchConfig,
    SetBatchCategory = SetBatchCategory,
    SetBatchTarget = SetBatchTarget,
    SetBatchLimit = SetBatchLimit,
    DepositBank = function(feature, slot) return CheckedMove(feature, "bag", "bank", "X2Bag:MoveToEmptyBankSlot", BagApi, "MoveToEmptyBankSlot", slot) end,
    DepositCoffer = function(feature, slot) return CheckedMove(feature, "bag", "coffer", "X2Bag:MoveToEmptyCofferSlot", BagApi, "MoveToEmptyCofferSlot", slot) end,
    WithdrawBank = function(feature, slot) return CheckedMove(feature, "bank", "bank", "X2Bank:MoveToEmptyBagSlot", BankApi, "MoveToEmptyBagSlot", slot) end,
    WithdrawCoffer = function(feature, slot) return CheckedMove(feature, "coffer", "coffer", "X2Coffer:MoveToEmptyBagSlot", CofferApi, "MoveToEmptyBagSlot", slot) end,
} })
BagTools.BagMoveContractVersion = 5
BagTools.BatchLifecycleContractVersion = 5
BagTools.NativeWindowQuickContractVersion = 3
BagTools.DynamicSourceResolutionContractVersion = 1
BagTools.BagTaskMutexContractVersion = 1
local AUCTION_FAVORITE_MAX, AUCTION_KEYWORD_MAX = 20, 64
local AUCTION_RESULT_LIMIT_MAX = 30
local function NormalizeAuctionKeyword(value)
    local text = Trim(value)
    if text == "" or #text > AUCTION_KEYWORD_MAX or text:find("[%c]") ~= nil then return nil end
    return text
end
local function NormalizeAuctionFavorites(value)
    local out, seen = {}, {}
    if type(value) ~= "table" then return out end
    for _, raw in ipairs(value) do
        local item = NormalizeAuctionKeyword(raw)
        if item ~= nil and not seen[item] and #out < AUCTION_FAVORITE_MAX then seen[item]=true; out[#out+1]=item end
    end
    return out
end
local function NormalizeAuctionResultLimit(value)
    local n=tonumber(value); if n==nil or n~=math.floor(n) then return nil end
    return math.max(5,math.min(AUCTION_RESULT_LIMIT_MAX,math.floor(n)))
end
local function ApplyAuctionState(value,state)
    value=type(value)=="table" and value or {}
    state.keyword=NormalizeAuctionKeyword(value.keyword) or ""
    state.favorites=NormalizeAuctionFavorites(value.favorites)
    state.exactMatch=value.exactMatch==true
    state.resultLimit=NormalizeAuctionResultLimit(value.resultLimit) or 20
    state.searchStatus="idle"
end
local function AuctionDefault() return { keyword="",favorites={},exactMatch=false,resultLimit=20 } end
local function AuctionQueryService() return S.Services and S.Services.AuctionQueryV3 or nil end
local function AuctionQueryReconcile(feature,before,after)
    local a=tonumber(before and before.count) or 0; local b=tonumber(after and after.count) or 0
    if a<=0 and b>0 then
        if S.Events==nil or type(S.Events.SubscribeInternal)~="function" then return false,"拍卖查询内部事件不可用" end
        local ok=S.Events:SubscribeInternal("v3.auction_query.updated",feature,function(_,requester)
            if tostring(requester or "")==feature.Id and feature.enabled==true and (tonumber(feature.consumerCount) or 0)>0 then
                return feature.Authority:Refresh("auction_query_updated")
            end
        end)
        if ok~=true then return false,"拍卖查询结果订阅失败" end
        if type(S.Events.SubscribeInternal)=="function" then
            -- Lowest-price quotes complete asynchronously on the shared queue;
            -- without this edge the result would never reach the projection.
            S.Events:SubscribeInternal("v3.price_quote.completed",feature,function()
                if feature.enabled==true and (tonumber(feature.consumerCount) or 0)>0 then
                    return feature.Authority:Refresh("price_quote_completed")
                end
            end)
            feature.PriceQuoteSubscribed=true
        end
        feature.AuctionQuerySubscribed=true
    elseif a>0 and b<=0 and feature.AuctionQuerySubscribed==true and S.Events~=nil then
        S.Events:UnsubscribeInternal("v3.auction_query.updated",feature); feature.AuctionQuerySubscribed=false
        if feature.PriceQuoteSubscribed==true and type(S.Events.UnsubscribeInternal)=="function" then
            S.Events:UnsubscribeInternal("v3.price_quote.completed",feature); feature.PriceQuoteSubscribed=false
        end
    end
    return true
end
local function AuctionSnapshot(feature)
    local query=AuctionQueryService()
    if type(query)~="table" or type(query.GetSnapshot)~="function" then return {status="unavailable",rows={},count=0,error="AuctionQueryV3 不可用"} end
    return query:GetSnapshot(feature.Id)
end
local function AuctionSearch(feature,value)
    local keyword=NormalizeAuctionKeyword(value==nil and feature.State.keyword or value)
    if keyword==nil then feature.State.searchStatus="failed"; return false,"搜索关键词必须是 1-64 个可见字符" end
    local persisted,persistErr=PersistStateMutation(feature,"auction_keyword",function(state) state.keyword=keyword; return true end)
    if persisted~=true then feature.State.searchStatus="failed"; return false,persistErr or "搜索关键词保存失败" end
    local query=AuctionQueryService(); if type(query)~="table" or type(query.Search)~="function" then return false,"拍卖查询服务不可用" end
    local ok,result=query:Search(feature.Id,keyword,{exactMatch=feature.State.exactMatch==true,resultLimit=feature.State.resultLimit})
    feature.State.searchStatus=ok==true and "waiting" or "failed"
    if feature.Authority then feature.Authority:Refresh("auction_search_requested") end
    return ok,result
end
local function AuctionRows(feature,includeFavorites)
    local rows={}
    if includeFavorites then
        for index,value in ipairs(feature.State.favorites or {}) do rows[#rows+1]={key="favorite:"..index,favoriteIndex=index,name=Text(value),text="收藏关键词 · 点击搜索可读取当前挂单",statusText="收藏",tone="default",kind="favorite"} end
    end
    local snapshot=AuctionSnapshot(feature)
    for _,row in ipairs(type(snapshot.rows)=="table" and snapshot.rows or {}) do
        local copy=Copy(row); copy.kind="result"; rows[#rows+1]=copy
    end
    return rows,snapshot
end
local function AuctionProjection(feature)
    local snapshot=AuctionSnapshot(feature)
    -- Lowest-price quote result (explicit + async via PriceQuoteQueueV3). The
    -- queue is the single authority; this only mirrors its snapshot for the
    -- page, never issues server queries.
    local quote=S.Services ~= nil and S.Services.PriceQuoteQueueV3 or nil
    local quoteSnapshot=type(quote)=="table" and type(quote.GetSnapshot)=="function" and quote:GetSnapshot(feature.Id) or nil
    return { keyword=feature.State.keyword,favoriteCount=#(feature.State.favorites or {}),favoriteMax=AUCTION_FAVORITE_MAX,
        exactMatch=feature.State.exactMatch==true,resultLimit=feature.State.resultLimit,
        searchStatus=snapshot.status or feature.State.searchStatus or "idle",resultStatus=snapshot.status or "idle",
        resultCount=tonumber(snapshot.count) or 0,queryError=snapshot.error,queryContract=snapshot.contract,
        quoteStatus=quoteSnapshot and quoteSnapshot.status or "idle",
        quotePrice=quoteSnapshot and tonumber(quoteSnapshot.price) or nil,
        quoteError=quoteSnapshot and quoteSnapshot.error or nil }
end
local function AuctionSettingsCommands()
    return {
        SetKeyword=function(feature,value) local keyword=NormalizeAuctionKeyword(value); if keyword==nil then return false,"搜索关键词必须是 1-64 个可见字符" end; return PersistStateMutation(feature,"auction_keyword",function(state) state.keyword=keyword; return true end) end,
        SetExactMatch=function(feature,value) return PersistStateMutation(feature,"auction_exact",function(state) state.exactMatch=value==true; return true end) end,
        SetResultLimit=function(feature,value) local n=NormalizeAuctionResultLimit(value); if n==nil then return false,"结果数量必须是 5-30" end; return PersistStateMutation(feature,"auction_limit",function(state) state.resultLimit=n; return true end) end,
        Search=AuctionSearch,
    }
end
local auctionCommands=AuctionSettingsCommands()
-- Lowest-price quotes are explicit + rate-limited + asynchronous. They are
-- owned by the shared PriceQuoteQueueV3 service, never issued here via a direct
-- X2Auction:GetLowestPrice call (which would bypass serialization and the
-- official 500ms cooldown contract).
auctionCommands.Quote=function(_,itemType,grade)
    local queue = S.Services ~= nil and S.Services.PriceQuoteQueueV3 or nil
    if type(queue) ~= "table" or type(queue.RequestQuote) ~= "function" then return false, "报价服务不可用" end
    local ok, status = queue:RequestQuote("tools_auction", itemType, grade, nil)
    if ok ~= true then return false, status or "报价请求失败" end
    return true, status or "queued"
end
auctionCommands.AddFavorite=function(feature,value)
    local keyword=NormalizeAuctionKeyword(value); if keyword==nil then return false,"收藏关键词必须是 1-64 个可见字符" end
    if #feature.State.favorites>=AUCTION_FAVORITE_MAX then return false,"收藏已达到上限" end
    for _,item in ipairs(feature.State.favorites) do if item==keyword then return false,"收藏关键词已存在" end end
    return PersistStateMutation(feature,"auction_favorite",function(state) state.favorites[#state.favorites+1]=keyword; return true end)
end
auctionCommands.RemoveFavorite=function(feature,index)
    index=tonumber(index); if index==nil or index~=math.floor(index) or index<1 or index>#feature.State.favorites then return false,"收藏索引无效" end
    return PersistStateMutation(feature,"auction_favorite_remove",function(state) table.remove(state.favorites,index); return true end)
end
local AUCTION_API_DEPENDENCIES={"X2Auction:SearchAuctionArticle","X2Auction:GetSearchedItemCount","X2Auction:GetSearchedItemInfo","X2Auction:GetLowestPrice"}
local AuctionFavorites = NewFeature("tools_auction",{apiDependencies=AUCTION_API_DEPENDENCIES,state={keyword="",favorites={},exactMatch=false,resultLimit=20,searchStatus="idle"},default=AuctionDefault(),apply=ApplyAuctionState,
    reconcileDemand=AuctionQueryReconcile,read=function(feature) local rows,snapshot=AuctionRows(feature,true); local status=snapshot.status=="failed" and (#rows>0 and "partial" or "unavailable") or (#rows>0 and "ready" or "empty"); return rows,status,snapshot.error end,
    projection=AuctionProjection,commands=auctionCommands})

local marketCommands=AuctionSettingsCommands()
local MarketAnalysis = NewFeature("tools_market_analysis",{apiDependencies={"X2Auction:SearchAuctionArticle","X2Auction:GetSearchedItemCount","X2Auction:GetSearchedItemInfo"},state={keyword="",exactMatch=false,resultLimit=20},default={keyword="",exactMatch=false,resultLimit=20},
    reconcileDemand=AuctionQueryReconcile,read=function(feature)
        local rows,snapshot=AuctionRows(feature,false)
        if #rows==0 and snapshot.status~="waiting" then rows[1]={key="market:hint",name="当前拍卖挂单",text="输入物品名称后显式查询；这里展示当前搜索结果，不把挂单伪装成历史成交价。",statusText="按需查询",tone="muted"} end
        local status=snapshot.status=="failed" and "unavailable" or snapshot.status=="waiting" and "partial" or #rows>0 and "ready" or "empty"
        return rows,status,snapshot.error
    end,projection=AuctionProjection,commands=marketCommands})
AuctionFavorites.AuctionQueryContractVersion = 1
MarketAnalysis.AuctionQueryContractVersion = 1

------------------------------------------------------------------------
-- tools_social: friend / block / mute lists over X2Friend. The RU list
-- return shape is not yet runtime-verified, so every read goes through a
-- conservative normalizer instead of trusting one guessed shape:
--   * array-of-tables, array-of-names and name-keyed tables all normalize;
--   * entries without a usable name become explicit "未识别条目" rows (never
--     rendered as raw table addresses) and degrade the status to partial;
--   * lists are bounded (SOCIAL_LIST_MAX_ROWS) with an explicit truncation
--     note, so a huge roster cannot flood the projection;
--   * per-list failures aggregate into ready/partial/empty/unavailable --
--     a failed read must never present itself as an empty list.
-- Signatures are the client export manifest (api_functions.lua):
-- GetFriendList(allMember) / GetBlockList() / GetMuteList().
------------------------------------------------------------------------
local SOCIAL_LIST_MAX_ROWS = 200
local SOCIAL_LIST_SCAN_LIMIT = 1000
local SOCIAL_LISTS = {
    { key = "好友", capability = "X2Friend:GetFriendList", method = "GetFriendList", allMember = true },
    { key = "屏蔽", capability = "X2Friend:GetBlockList", method = "GetBlockList", toneUnknown = "warn" },
    { key = "静音", capability = "X2Friend:GetMuteList", method = "GetMuteList", toneUnknown = "orange" },
}
local function SocialMemberName(value)
    if type(value) == "string" then
        local name = value:match("^%s*(.-)%s*$")
        return name ~= "" and name or nil
    end
    if type(value) ~= "table" then return nil end
    for _, field in ipairs({ "name", "characterName", "memberName", "charName" }) do
        local candidate = value[field]
        if type(candidate) == "string" then
            local name = candidate:match("^%s*(.-)%s*$")
            if name ~= "" then return name end
        end
    end
    return nil
end
local function SocialListEntries(list)
    -- Array part first (ipairs semantics); only a purely name-keyed table
    -- falls back to sorted string keys. Scalar hash fields such as a native
    -- `count` are metadata, not entries, and are skipped in both shapes.
    local arrayCount = 0
    for index = 1, SOCIAL_LIST_SCAN_LIMIT do
        if list[index] == nil then break end
        arrayCount = index
    end
    if arrayCount > 0 then
        local entries = {}
        for index = 1, arrayCount do entries[index] = { value = list[index], key = nil } end
        return entries
    end
    local keys = {}
    for key, value in pairs(list) do
        if type(key) == "string" and (type(value) == "table" or type(value) == "string") then keys[#keys + 1] = key end
    end
    table.sort(keys)
    local entries = {}
    for index, key in ipairs(keys) do entries[index] = { value = list[key], key = key } end
    return entries
end
local function AppendSocialList(rows, spec, list)
    local stats = { recognized = 0, unrecognized = 0, truncated = false }
    if type(list) ~= "table" then return stats end
    local entries = SocialListEntries(list)
    stats.truncated = #entries > SOCIAL_LIST_MAX_ROWS
    for index = 1, math.min(#entries, SOCIAL_LIST_MAX_ROWS) do
        local entry = entries[index]
        local name = SocialMemberName(entry.value)
        if name == nil then
            stats.unrecognized = stats.unrecognized + 1
            rows[#rows + 1] = { key = "social:" .. spec.key .. ":" .. index, memberName = nil, listKind = spec.key,
                name = "未识别条目 " .. tostring(entry.key or index), text = "返回形态未识别；待 RU 实证后修正",
                statusText = spec.key, tone = "muted" }
        else
            stats.recognized = stats.recognized + 1
            local online, level
            if type(entry.value) == "table" then
                for _, field in ipairs({ "online", "isOnline", "loggedIn" }) do
                    local flag = entry.value[field]
                    if type(flag) == "boolean" then online = flag; break end
                end
                for _, field in ipairs({ "level", "growLevel" }) do
                    local n = tonumber(entry.value[field])
                    if n ~= nil then level = math.floor(n); break end
                end
            end
            local fact = online == nil and "在线状态未知" or (online and "在线" or "离线")
            if level ~= nil then fact = fact .. " · 等级 " .. tostring(level) end
            local tone = spec.toneUnknown or "default"
            if spec.key == "好友" then tone = (online == true and "green") or (online == false and "muted") or "default" end
            rows[#rows + 1] = { key = "social:" .. spec.key .. ":" .. index, memberName = name, listKind = spec.key,
                name = name, text = fact, statusText = spec.key, tone = tone }
        end
    end
    return stats
end
local function SocialRosterAction(capability, method, name)
    local member = SocialMemberName(name)
    if member == nil then return false, "角色名不能为空" end
    return Action(capability, FriendApi, method, member)
end

NewFeature("tools_social", { apiDependencies = { "X2Friend:IsMyFriend", "X2Friend:GetFriendList", "X2Friend:GetBlockList", "X2Friend:GetMuteList", "X2Friend:BlockUser", "X2Friend:UnblockUser", "X2Friend:MuteUser", "X2Friend:UnmuteUser" }, read = function()
    local rows, failed, anyOk = {}, {}, false
    local unrecognized, truncated = 0, false
    for _, spec in ipairs(SOCIAL_LISTS) do
        local ok, list, callErr
        if spec.allMember == true then
            ok, list, callErr = Call(spec.capability, FriendApi, spec.method, true)
        else
            -- GetBlockList()/GetMuteList() take no argument (client export
            -- manifest); do not pass a nil that would change the native arity.
            ok, list, callErr = Call(spec.capability, FriendApi, spec.method)
        end
        if ok ~= true then
            failed[#failed + 1] = spec.key .. "（" .. tostring(callErr or "读取失败") .. "）"
        else
            anyOk = true
            local stats = AppendSocialList(rows, spec, list)
            unrecognized = unrecognized + stats.unrecognized
            truncated = truncated or stats.truncated
        end
    end
    local status = "ready"
    if not anyOk then status = "unavailable"
    elseif #failed > 0 or unrecognized > 0 then status = "partial"
    elseif #rows == 0 then status = "empty" end
    local notes = {}
    if #failed > 0 then notes[#notes + 1] = "读取失败：" .. table.concat(failed, "；") end
    if unrecognized > 0 then notes[#notes + 1] = "返回形态未识别 " .. tostring(unrecognized) .. " 条（RU 契约待实证）" end
    if truncated then notes[#notes + 1] = "单名单超过 " .. tostring(SOCIAL_LIST_MAX_ROWS) .. " 条已截断显示" end
    return rows, status, (#notes > 0 and table.concat(notes, "；") or nil)
end, commands = {
    Block = function(_, name) return SocialRosterAction("X2Friend:BlockUser", "BlockUser", name) end,
    Unblock = function(_, name) return SocialRosterAction("X2Friend:UnblockUser", "UnblockUser", name) end,
    Mute = function(_, name) return SocialRosterAction("X2Friend:MuteUser", "MuteUser", name) end,
    Unmute = function(_, name) return SocialRosterAction("X2Friend:UnmuteUser", "UnmuteUser", name) end,
    IsFriend = function(_, name)
        local member = SocialMemberName(name)
        if member == nil then return false, "角色名不能为空" end
        local ok, result, callErr = Call("X2Friend:IsMyFriend", FriendApi, "IsMyFriend", member)
        if ok ~= true then return false, tostring(callErr or "查询失败") end
        if result == true then return true, "是好友" end
        if result == false then return true, "非好友" end
        return true, "好友状态未知（返回形态待 RU 实证）"
    end,
} })

-- Honest runtime-blocked surfaces: pages and lifecycle are real, only the
-- last unproven sub-capability is fenced.
local UNIT_LINE_TASK = "v3_business_unit_lines_refresh"
local UNIT_LINE_PAIRS = {
    { key="target", label="自己 ↔ 当前目标", from="player", to="target", setting="showTarget" },
    { key="targettarget", label="当前目标 ↔ 目标的目标", from="target", to="targettarget", setting="showTargetTarget" },
    { key="focus", label="自己 ↔ 焦点目标", from="player", to="watchtarget", setting="showFocusTarget" },
    { key="focustarget", label="焦点目标 ↔ 焦点目标的目标", from="watchtarget", to="watchtargettarget", setting="showFocusTargetTarget" },
}
-- Refresh floor is 1 ms (never clamped up): the unit-line overlay must be able
-- to follow the target at frame cadence. The high-frequency scheduler lane
-- still respects the user-selected cadence and only enables sub-16 ms when the
-- user actually asks for it.
local function UnitLineInterval(feature)
    return math.max(1, math.min(1000, math.floor(tonumber(feature.State.refreshMs) or 100)))
end
local function StartUnitLineTask(feature)
    if S.Scheduler == nil or type(S.Scheduler.AddHighFrequencyTask) ~= "function" then return false, "单位连线 Scheduler 不可用" end
    local added = S.Scheduler:AddHighFrequencyTask(UNIT_LINE_TASK, UnitLineInterval(feature), function()
        if feature.enabled == true and (tonumber(feature.consumerCount) or 0) > 0 then feature.Authority:Refresh("visual_tick") end
    end, false, feature, "P1", 1)
    if added ~= true then return false, "单位连线刷新任务创建失败" end
    if type(S.Scheduler.SetTaskModule) == "function" then S.Scheduler:SetTaskModule(UNIT_LINE_TASK, feature.Id) end
    return true
end
local UNIT_LINE_DEFAULT_COLORS = {
    target = { 1.00, 0.72, 0.12 },
    targettarget = { 0.94, 0.42, 0.20 },
    focus = { 0.35, 0.82, 1.00 },
    focustarget = { 0.67, 0.52, 1.00 },
}
local function NormalizeUnitLineColors(value)
    local out = {}
    for key, default in pairs(UNIT_LINE_DEFAULT_COLORS) do
        local entry = type(value) == "table" and value[key] or nil
        if type(entry) == "table" then
            out[key] = {
                math.max(0, math.min(1, tonumber(entry[1]) or default[1])),
                math.max(0, math.min(1, tonumber(entry[2]) or default[2])),
                math.max(0, math.min(1, tonumber(entry[3]) or default[3])),
            }
        else
            out[key] = { default[1], default[2], default[3] }
        end
    end
    return out
end
local UnitLines = NewFeature("combat_unit_lines", {
    apiDependencies = { "X2Unit:GetUnitScreenPosition", "X2Unit:GetUnitWorldPositionByTarget" },
    state = { pointCount = 24, pointSize = 4, opacity = 0.78, refreshMs = 100,
        showTarget = true, showTargetTarget = true, showFocusTarget = true, showFocusTargetTarget = true,
        colors = Copy(UNIT_LINE_DEFAULT_COLORS),
        points = {}, sizes = {},
        pairPoints = Copy({ target = 24, targettarget = 24, focus = 24, focustarget = 24 }),
        pairSizes = Copy({ target = 4, targettarget = 4, focus = 4, focustarget = 4 }) },
    default = { pointCount = 24, pointSize = 4, opacity = 0.78, refreshMs = 100,
        showTarget = true, showTargetTarget = true, showFocusTarget = true, showFocusTargetTarget = true,
        colors = Copy(UNIT_LINE_DEFAULT_COLORS),
        points = {}, sizes = {},
        pairPoints = Copy({ target = 24, targettarget = 24, focus = 24, focustarget = 24 }),
        pairSizes = Copy({ target = 4, targettarget = 4, focus = 4, focustarget = 4 }) },
    observationContractVersion = 2,
    reconcileDemand = function(feature, before, after)
        local b, a = tonumber(before and before.count) or 0, tonumber(after and after.count) or 0
        if b <= 0 and a > 0 then return StartUnitLineTask(feature)
        elseif b > 0 and a <= 0 and S.Scheduler ~= nil then S.Scheduler:RemoveTask(UNIT_LINE_TASK) end
        return true
    end,
    onDisable = function() if S.Scheduler ~= nil then S.Scheduler:RemoveTask(UNIT_LINE_TASK) end return true end,
    read = function(feature)
        local projection = S.Services and S.Services.ScreenProjectionV3 or nil
        if type(projection) ~= "table" or type(projection.ProjectUnitBatch) ~= "function" then return {}, "unavailable", "ScreenProjectionV3 v5 不可用" end
        local rows, attempted, failed, tokens = {}, 0, {}, {}
        local seen = {}
        for _, pair in ipairs(UNIT_LINE_PAIRS) do
            if feature.State[pair.setting] ~= false then
                attempted = attempted + 1
                if seen[pair.from]~=true then seen[pair.from]=true; tokens[#tokens+1]=pair.from end
                if seen[pair.to]~=true then seen[pair.to]=true; tokens[#tokens+1]=pair.to end
            end
        end
        if attempted == 0 then return {}, "empty", "所有连线类型均已关闭" end
        local projected,batchErr = projection:ProjectUnitBatch(tokens,{ requireFrontHemisphere=true, worldZOffset=1, validateNativeAgainstCamera=true, reconcileNativeScale=true })
        projected=type(projected)=="table" and projected or {}
        for _, pair in ipairs(UNIT_LINE_PAIRS) do
            if feature.State[pair.setting] ~= false then
                local a,b=projected[pair.from],projected[pair.to]
                if type(a)=="table" and a.visible==true and type(b)=="table" and b.visible==true then
                    rows[#rows+1] = { key="unit_line:"..pair.key, pairKey=pair.key, name=pair.label,
                        text=pair.label, statusText="可绘制", tone="green", x1=a.x,y1=a.y,x2=b.x,y2=b.y,
                        source1=a.source, source2=b.source, fromToken=pair.from, toToken=pair.to }
                else
                    local reason=(type(a)=="table" and a.reason) or (type(b)=="table" and b.reason) or batchErr or "当前无单位"
                    if reason=="behind_camera" then reason="单位在相机背后（不绘制）" end
                    failed[#failed+1] = pair.label .. "（" .. tostring(reason) .. "）"
                end
            end
        end
        if #rows == 0 then return {}, "empty", table.concat(failed, "；") end
        return rows, (#failed > 0 and "partial" or "ready"), (#failed > 0 and table.concat(failed, "；") or nil)
    end,
    projection = function(feature) return { pointCount=feature.State.pointCount, pointSize=feature.State.pointSize, opacity=feature.State.opacity,
        refreshMs=UnitLineInterval(feature), showTarget=feature.State.showTarget~=false, showTargetTarget=feature.State.showTargetTarget~=false,
        showFocusTarget=feature.State.showFocusTarget~=false, showFocusTargetTarget=feature.State.showFocusTargetTarget~=false,
        colors=NormalizeUnitLineColors(feature.State.colors),
        pairPoints=feature.State.pairPoints or {}, pairSizes=feature.State.pairSizes or {},
        samplingMode="adaptive_screen_space", pointBudgetMode="cadence_pressure_bounded", refreshPriority="P1_visual" } end,
    commands = {
        SetPointCount = function(feature, value) value=math.max(8,math.min(48,math.floor(tonumber(value) or 24))); return PersistStateMutation(feature,"unit_lines_points",function(state) state.pointCount=value; return true end) end,
        SetPointSize = function(feature, value) value=math.max(2,math.min(10,math.floor(tonumber(value) or 4))); return PersistStateMutation(feature,"unit_lines_size",function(state) state.pointSize=value; return true end) end,
        SetOpacity = function(feature, value) value=math.max(0.1,math.min(1,tonumber(value) or 0.78)); return PersistStateMutation(feature,"unit_lines_opacity",function(state) state.opacity=value; return true end) end,
        SetRefreshMs = function(feature, value)
            value=math.max(1,math.min(1000,math.floor(tonumber(value) or 100)))
            local ok,err=PersistStateMutation(feature,"unit_lines_refresh",function(state) state.refreshMs=value; return true end)
            if ok~=true then return false,err end
            if feature.enabled==true and (tonumber(feature.consumerCount) or 0)>0 then return StartUnitLineTask(feature) end
            return true
        end,
        SetPairEnabled = function(feature, key, value)
            local map={target="showTarget",targettarget="showTargetTarget",focus="showFocusTarget",focustarget="showFocusTargetTarget"}
            local field=map[tostring(key or "")]; if field==nil then return false,"未知连线类型" end
            return PersistStateMutation(feature,"unit_lines_pair_"..tostring(key),function(state) state[field]=value==true; return true end)
        end,
        SetPairColor = function(feature, key, r, g, b)
            key=tostring(key or "")
            if UNIT_LINE_DEFAULT_COLORS[key] == nil then return false,"未知连线类型" end
            r=math.max(0,math.min(1,tonumber(r) or 1)); g=math.max(0,math.min(1,tonumber(g) or 1)); b=math.max(0,math.min(1,tonumber(b) or 1))
            return PersistStateMutation(feature,"unit_lines_color_"..key,function(state)
                state.colors = state.colors or {}
                state.colors[key] = { r, g, b }
                return true
            end)
        end,
        SetPairPoints = function(feature, key, value)
            key=tostring(key or "")
            if UNIT_LINE_DEFAULT_COLORS[key] == nil then return false,"未知连线类型" end
            value=math.max(8,math.min(48,math.floor(tonumber(value) or 24)))
            return PersistStateMutation(feature,"unit_lines_pair_points_"..key,function(state)
                state.pairPoints = state.pairPoints or {}
                state.pairPoints[key] = value
                return true
            end)
        end,
        SetPairSize = function(feature, key, value)
            key=tostring(key or "")
            if UNIT_LINE_DEFAULT_COLORS[key] == nil then return false,"未知连线类型" end
            value=math.max(2,math.min(10,math.floor(tonumber(value) or 4)))
            return PersistStateMutation(feature,"unit_lines_pair_size_"..key,function(state)
                state.pairSizes = state.pairSizes or {}
                state.pairSizes[key] = value
                return true
            end)
        end,
    },
})
UnitLines.VisualGuideContractVersion = 4
UnitLines.AdaptiveDensityContractVersion = 2
UnitLines.SmoothRefreshContractVersion = 1
UnitLines.FrontHemisphereContractVersion = 1
UnitLines.ProjectionConsistencyContractVersion = 1

local RANGE_ASSIST_TASK = "v3_business_range_assist_refresh"
local RangeAssist = NewFeature("combat_range_assist", {
    apiDependencies = { "X2Unit:GetUnitWorldPositionByTarget" },
    state = { radius = 10, pointCount = 24, pointSize = 4, opacity = 0.68, color = { 0.20, 0.82, 1.00 } },
    default = { radius = 10, pointCount = 24, pointSize = 4, opacity = 0.68, color = { 0.20, 0.82, 1.00 } },
    observationContractVersion = 2,
    reconcileDemand = function(feature, before, after)
        local b, a = tonumber(before and before.count) or 0, tonumber(after and after.count) or 0
        if b <= 0 and a > 0 then
            if S.Scheduler == nil or type(S.Scheduler.AddTask) ~= "function" then return false, "范围辅助 Scheduler 不可用" end
            local added = S.Scheduler:AddTask(RANGE_ASSIST_TASK, 200, function()
                if feature.enabled == true and (tonumber(feature.consumerCount) or 0) > 0 then feature.Authority:Refresh("visual_tick") end
            end, false, feature, "P4", 1)
            if added ~= true then return false, "范围辅助刷新任务创建失败" end
            if type(S.Scheduler.SetTaskModule) == "function" then S.Scheduler:SetTaskModule(RANGE_ASSIST_TASK, feature.Id) end
        elseif b > 0 and a <= 0 and S.Scheduler ~= nil then S.Scheduler:RemoveTask(RANGE_ASSIST_TASK) end
        return true
    end,
    onDisable = function() if S.Scheduler ~= nil then S.Scheduler:RemoveTask(RANGE_ASSIST_TASK) end return true end,
    read = function(feature)
        local projection = S.Services and S.Services.ScreenProjectionV3 or nil
        if type(projection) ~= "table" or type(projection.GetUnitWorldPosition) ~= "function" or type(projection.ProjectWorldBatch) ~= "function" then return {}, "unavailable", "ScreenProjectionV3 不可用" end
        local px,py,pz,posErr = projection:GetUnitWorldPosition("player", true)
        if px == nil then return {}, "unavailable", "自身世界坐标不可读：" .. tostring(posErr or "unknown") end
        local count=math.max(12,math.min(48,math.floor(tonumber(feature.State.pointCount) or 24)))
        local radius=math.max(1,math.min(100,tonumber(feature.State.radius) or 10))
        local worldPoints={}
        for index=1,count do
            local angle=((index-1)/count)*math.pi*2
            worldPoints[index]={x=px+math.cos(angle)*radius,y=py+math.sin(angle)*radius,z=pz+0.1}
        end
        -- Range geometry is an RSUI overlay; force logical camera projection so
        -- the circle center cannot drift with physical-pixel/UI-scale mismatch.
        local projected, batchSource = projection:ProjectWorldBatch(worldPoints,{preferLogicalCamera=true})
        local points={}
        for _,screenPoint in ipairs(type(projected)=="table" and projected or {}) do
            if type(screenPoint)=="table" and tonumber(screenPoint.x)~=nil and tonumber(screenPoint.y)~=nil
                and (tonumber(screenPoint.depth)==nil or tonumber(screenPoint.depth)>0) then
                points[#points+1]={x=screenPoint.x,y=screenPoint.y}
            end
        end
        if #points < 3 then return {}, "partial", "范围圆投影没有足够可见点；请确认当前 RU 相机投影能力" end
        return {{ key="self_radius", name="自身范围圆", text=string.format("半径 %.1fm · 可见点 %d/%d · %s",radius,#points,count,tostring(batchSource or "projection")), statusText="实时", tone="green", points=points, radius=radius }}, "ready"
    end,
    projection = function(feature)
        local color = type(feature.State.color) == "table" and feature.State.color or { 0.20, 0.82, 1.00 }
        return {
            radius=feature.State.radius, pointCount=feature.State.pointCount, pointSize=feature.State.pointSize, opacity=feature.State.opacity,
            color={
                math.max(0,math.min(1,tonumber(color[1]) or 0.20)),
                math.max(0,math.min(1,tonumber(color[2]) or 0.82)),
                math.max(0,math.min(1,tonumber(color[3]) or 1.00)),
            },
        }
    end,
    commands = {
        SetRadius = function(feature,value) value=math.max(1,math.min(100,tonumber(value) or 10)); return PersistStateMutation(feature,"range_radius",function(state) state.radius=value; return true end) end,
        SetPointCount = function(feature,value) value=math.max(12,math.min(48,math.floor(tonumber(value) or 24))); return PersistStateMutation(feature,"range_points",function(state) state.pointCount=value; return true end) end,
        SetPointSize = function(feature,value) value=math.max(2,math.min(10,math.floor(tonumber(value) or 4))); return PersistStateMutation(feature,"range_size",function(state) state.pointSize=value; return true end) end,
        SetOpacity = function(feature,value) value=math.max(0.1,math.min(1,tonumber(value) or 0.68)); return PersistStateMutation(feature,"range_opacity",function(state) state.opacity=value; return true end) end,
        SetColor = function(feature,r,g,b)
            r=math.max(0,math.min(1,tonumber(r) or 0.20)); g=math.max(0,math.min(1,tonumber(g) or 0.82)); b=math.max(0,math.min(1,tonumber(b) or 1.00))
            return PersistStateMutation(feature,"range_color",function(state) state.color={r,g,b}; return true end)
        end,
    },
})
RangeAssist.VisualGuideContractVersion = 3
NewFeature("combat_siege_readiness", { blocker = "GetEquippedItemTooltipInfo 的槽位/装分字段和攻城上下文未在当前 RU 实机确认；不猜测装备状态" })
NewFeature("tools_hotkey_profiles", { blocker = "当前 RU API 没有动作名称枚举；GetOptionBinding 只能读取已知 action/index，无法安全导出完整快捷键方案" })
------------------------------------------------------------------------
-- tools_reinforce_analysis: read-only equipment-reinforcement analysis over
-- X2EquipSlotReinforce.
--
-- Evidence basis (reconciled 2026-09-03 against the RU client export manifest
-- api_functions.lua, section "X2EquipSlotReinforce", lines 1855-1878): every
-- getter used below is listed under "Allowed functions". The same section
-- places all mutators (StartReinforceAddExp / StartReinforceLevelup /
-- ChangeLevelEffect / EnableLevelUp) under "Available/not allowed", so the
-- analysis is read-only by construction: no write capability is registered and
-- no write path exists to misuse.
--
-- What remains unproven and is therefore never guessed:
--   * the legal equipSlotIndex range -- the manifest exports no slot
--     enumeration API, so slots are discovered by a BOUNDED probe and each
--     index is classified explicitly (no data / unresolved shape / resolved);
--   * the exact return field names of GetReinforceInfo and GetMaterialInfo --
--     a narrow candidate whitelist is used and anything outside it renders as
--     "待确认" while degrading the whole projection to partial.
-- A failed read degrades to unavailable/partial, never to an empty table.
------------------------------------------------------------------------
-- A single table namespace instead of one local per helper: this file's main
-- chunk sits at the Lua 5.1 limit of 200 locals per function, so every helper
-- must live on one table rather than adding its own local.
local REINFORCE_SLOT_PROBE_MAX = 32
local Reinforce = {
    attributes = {
        { key = "offence", label = "攻击", global = "ESRA_OFFENCE" },
        { key = "defence", label = "防御", global = "ESRA_DEFENCE" },
        { key = "support", label = "支援", global = "ESRA_SUPPORT" },
    },
}
-- Attribute labels resolve by EXACT match against the client's own ESRA_*
-- constants, never by index arithmetic: ESRA_* numbering is not proven to be
-- 0-based or contiguous, so an off-by-one would silently mislabel a slot.
function Reinforce:AttributeLabel(value)
    if value == nil then return nil end
    for _, attribute in ipairs(self.attributes) do
        local constant = rawget(_G, attribute.global)
        if constant ~= nil and constant == value then return attribute.label end
    end
    return nil
end
function Reinforce:Number(source, fields)
    if type(source) ~= "table" then return nil end
    for _, field in ipairs(fields) do
        local value = tonumber(source[field])
        if value ~= nil then return value end
    end
    return nil
end
function Reinforce:Text(source, fields)
    if type(source) ~= "table" then return nil end
    for _, field in ipairs(fields) do
        local value = source[field]
        if type(value) == "string" then
            local text = value:match("^%s*(.-)%s*$")
            if text ~= "" then return text end
        end
    end
    return nil
end
-- Returns nil for "no data" and for shapes that cannot be trusted. Callers
-- distinguish the two by checking whether the raw value was nil.
function Reinforce:NormalizeInfo(value)
    if value == nil then return nil end
    if type(value) == "number" then return { level = math.floor(value) } end
    if type(value) ~= "table" then return nil end
    local level = self:Number(value, { "level", "reinforceLevel", "curLevel", "currentLevel" })
    local name = self:Text(value, { "name", "slotName", "equipSlotName" })
    if level == nil and name == nil then return nil end
    return {
        level = level,
        maxLevel = self:Number(value, { "maxLevel", "maxReinforceLevel", "limitLevel" }),
        exp = self:Number(value, { "exp", "curExp", "currentExp" }),
        maxExp = self:Number(value, { "maxExp", "needExp", "requireExp" }),
        attributeType = self:Number(value, { "attributeType", "type" }),
        name = name,
    }
end
function Reinforce:NormalizeMaterial(value)
    if type(value) ~= "table" then return nil end
    local name = self:Text(value, { "name", "itemName", "materialName" })
    local count = self:Number(value, { "count", "needCount", "amount", "itemCount" })
    if name == nil and count == nil then return nil end
    return { name = name, count = count }
end
function Reinforce:MaterialSummary(slotIndex, level)
    -- GetMaterialInfo(equipSlotIndex, level) is an official Allowed getter, but
    -- its payload shape is unverified; a non-normalizable payload is reported as
    -- "形态待 RU 实证" instead of being silently omitted or rendered as a raw
    -- table address.
    local ok, payload, callErr = Call("X2EquipSlotReinforce:GetMaterialInfo", ReinforceApi, "GetMaterialInfo", slotIndex, level)
    if ok ~= true then return nil, tostring(callErr or "读取失败") end
    if payload == nil then return nil, nil end
    if type(payload) ~= "table" then return nil, "返回形态未识别" end
    local rows = payload
    if payload[1] == nil and (self:Text(payload, { "name", "itemName", "materialName" }) ~= nil or self:Number(payload, { "count", "needCount", "amount", "itemCount" }) ~= nil) then
        rows = { payload }
    end
    local parts, unresolved, scanned = {}, 0, 0
    for index = 1, 8 do
        local entry = rows[index]
        if entry == nil then break end
        scanned = scanned + 1
        local material = self:NormalizeMaterial(entry)
        if material == nil then
            unresolved = unresolved + 1
        else
            parts[#parts + 1] = (material.name or "材料") .. " ×" .. tostring(material.count or "?")
        end
    end
    if scanned == 0 then return nil, "返回形态未识别" end
    if unresolved > 0 then parts[#parts + 1] = "另有 " .. tostring(unresolved) .. " 条形态待 RU 实证" end
    return table.concat(parts, "；"), (unresolved > 0 and "形态待 RU 实证" or nil)
end
function Reinforce:AppendFact(rows, key, name, facts, tone, statusText)
    rows[#rows + 1] = { key = key, name = name, text = table.concat(facts, " · "), statusText = statusText or "已识别", tone = tone or "default" }
end
NewFeature("tools_reinforce_analysis", {
    -- Exactly the capabilities this read path calls -- no speculative entries.
    apiDependencies = {
        "X2EquipSlotReinforce:GetReinforceInfo", "X2EquipSlotReinforce:GetMaterialInfo",
        "X2EquipSlotReinforce:GetTotalReinforceLevel",
        "X2EquipSlotReinforce:GetAttributeTotalLevel", "X2EquipSlotReinforce:GetNextSetApplyLevel",
        "X2EquipSlotReinforce:HasNextSetEffect", "X2EquipSlotReinforce:SuitableLevelForEquipSlotReinforce",
        "X2EquipSlotReinforce:GetBundleEffectTopLevel",
    },
    read = function()
        local rows, failures, unresolved = {}, {}, 0
        local anyOk = false
        if ReinforceApi == nil then
            return rows, "unavailable", "X2EquipSlotReinforce 在当前客户端不可用（未导出）"
        end
        -- 1) Aggregate overview. Each getter is independent: one failure must
        --    not blank the others, and an unknown value is displayed as 待确认.
        local okTotal, totalLevel, totalErr = Call("X2EquipSlotReinforce:GetTotalReinforceLevel", ReinforceApi, "GetTotalReinforceLevel")
        if okTotal == true then
            anyOk = true
            local total = tonumber(totalLevel)
            if total == nil then unresolved = unresolved + 1 end
            Reinforce:AppendFact(rows, "reinforce:total", "总强化等级", { total ~= nil and ("等级 " .. tostring(math.floor(total))) or "返回形态待 RU 实证" },
                total ~= nil and "green" or "warn", total ~= nil and "已识别" or "待确认")
        else
            failures[#failures + 1] = "总强化等级（" .. tostring(totalErr or "读取失败") .. "）"
        end
        local okSuit, suitLevel, suitErr = Call("X2EquipSlotReinforce:SuitableLevelForEquipSlotReinforce", ReinforceApi, "SuitableLevelForEquipSlotReinforce")
        if okSuit == true then
            anyOk = true
            local level = tonumber(suitLevel)
            if level == nil then unresolved = unresolved + 1 end
            Reinforce:AppendFact(rows, "reinforce:suitable", "装备强化适用等级", { level ~= nil and ("等级 " .. tostring(math.floor(level))) or "返回形态待 RU 实证" },
                "muted", level ~= nil and "已识别" or "待确认")
        else
            failures[#failures + 1] = "适用等级（" .. tostring(suitErr or "读取失败") .. "）"
        end
        for _, attribute in ipairs(Reinforce.attributes) do
            local attributeType = rawget(_G, attribute.global)
            if attributeType == nil then
                Reinforce:AppendFact(rows, "reinforce:attr:" .. attribute.key, attribute.label .. "系合计", { "属性类型常量 " .. attribute.global .. " 未导出，无法查询" }, "muted", "未提供")
            else
                local okLevel, levelValue, levelErr = Call("X2EquipSlotReinforce:GetAttributeTotalLevel", ReinforceApi, "GetAttributeTotalLevel", attributeType)
                if okLevel ~= true then
                    failures[#failures + 1] = attribute.label .. "系合计（" .. tostring(levelErr or "读取失败") .. "）"
                else
                    anyOk = true
                    local facts = {}
                    local level = tonumber(levelValue)
                    if level == nil then unresolved = unresolved + 1 end
                    facts[#facts + 1] = level ~= nil and ("合计等级 " .. tostring(math.floor(level))) or "合计等级待 RU 实证"
                    local okNext, nextValue = Call("X2EquipSlotReinforce:GetNextSetApplyLevel", ReinforceApi, "GetNextSetApplyLevel", attributeType)
                    if okNext == true then
                        local nextLevel = tonumber(nextValue)
                        if nextLevel == nil then unresolved = unresolved + 1 end
                        facts[#facts + 1] = nextLevel ~= nil and ("下一套装档位 " .. tostring(math.floor(nextLevel))) or "下一套装档位待 RU 实证"
                    else
                        failures[#failures + 1] = attribute.label .. "系下一档位"
                    end
                    local okHas, hasValue = Call("X2EquipSlotReinforce:HasNextSetEffect", ReinforceApi, "HasNextSetEffect", attributeType)
                    if okHas == true then
                        if hasValue == true then facts[#facts + 1] = "存在下一档套装效果"
                        elseif hasValue == false then facts[#facts + 1] = "已达当前套装上限"
                        else
                            unresolved = unresolved + 1
                            facts[#facts + 1] = "下一档套装效果状态待 RU 实证"
                        end
                    else
                        failures[#failures + 1] = attribute.label .. "系套装效果状态"
                    end
                    Reinforce:AppendFact(rows, "reinforce:attr:" .. attribute.key, attribute.label .. "系合计", facts, "default",
                        (level ~= nil and "已识别" or "待确认"))
                end
            end
        end
        local okBundle, bundleTop = Call("X2EquipSlotReinforce:GetBundleEffectTopLevel", ReinforceApi, "GetBundleEffectTopLevel")
        if okBundle == true then
            anyOk = true
            local top = tonumber(bundleTop)
            if top == nil then unresolved = unresolved + 1 end
            Reinforce:AppendFact(rows, "reinforce:bundle", "组合效果上限", { top ~= nil and ("最高等级 " .. tostring(math.floor(top))) or "返回形态待 RU 实证" },
                "muted", top ~= nil and "已识别" or "待确认")
        else
            failures[#failures + 1] = "组合效果上限"
        end
        -- 2) Bounded per-slot probe. The manifest exports no slot enumeration
        --    API, so the range is deliberately bounded rather than guessed from
        --    numbering conventions. Indexes are classified, never assumed:
        --      ok + nil          -> no data for that index (not an error)
        --      ok + unusable     -> unresolved shape, counted and disclosed
        --      not ok            -> read failure, aggregated
        local slotRows, slotFailures = {}, 0
        for index = 0, REINFORCE_SLOT_PROBE_MAX - 1 do
            local ok, info, callErr = Call("X2EquipSlotReinforce:GetReinforceInfo", ReinforceApi, "GetReinforceInfo", index)
            if ok ~= true then
                slotFailures = slotFailures + 1
                -- Record the slot-probe failure once; 32 identical notes would
                -- bury the real diagnostics.
                if slotFailures == 1 then
                    failures[#failures + 1] = "槽位读取（" .. tostring(callErr or "读取失败") .. "）"
                end
            elseif info == nil then
                anyOk = true
            else
                anyOk = true
                local normalized = Reinforce:NormalizeInfo(info)
                if normalized == nil then
                    unresolved = unresolved + 1
                else
                    local facts = {}
                    if normalized.level == nil then unresolved = unresolved + 1 end
                    facts[#facts + 1] = normalized.level ~= nil and ("强化等级 " .. tostring(normalized.level) .. (normalized.maxLevel ~= nil and ("/" .. tostring(normalized.maxLevel)) or "")) or "强化等级待 RU 实证"
                    if normalized.exp ~= nil then
                        facts[#facts + 1] = "经验 " .. tostring(normalized.exp) .. (normalized.maxExp ~= nil and ("/" .. tostring(normalized.maxExp)) or "")
                    end
                    local attributeLabel = Reinforce:AttributeLabel(normalized.attributeType)
                    if attributeLabel ~= nil then
                        facts[#facts + 1] = "属性系 " .. attributeLabel
                    elseif normalized.attributeType ~= nil then
                        unresolved = unresolved + 1
                        facts[#facts + 1] = "属性系编号 " .. tostring(normalized.attributeType) .. "（未匹配 ESRA_* 常量，待 RU 实证）"
                    end
                    if normalized.level ~= nil then
                        local summary, shapeNote = Reinforce:MaterialSummary(index, normalized.level)
                        if summary ~= nil then
                            facts[#facts + 1] = "下一级材料：" .. summary
                            if shapeNote ~= nil then unresolved = unresolved + 1 end
                        elseif shapeNote ~= nil then
                            facts[#facts + 1] = "下一级材料：" .. shapeNote
                            unresolved = unresolved + 1
                        end
                    end
                    slotRows[#slotRows + 1] = {
                        key = "reinforce:slot:" .. tostring(index),
                        name = "槽位 " .. tostring(index) .. (normalized.name ~= nil and (" · " .. normalized.name) or ""),
                        text = table.concat(facts, " · "),
                        statusText = "已识别",
                        tone = "default",
                    }
                end
            end
        end
        for _, row in ipairs(slotRows) do rows[#rows + 1] = row end
        local status = "ready"
        if not anyOk then status = "unavailable"
        elseif #failures > 0 or unresolved > 0 then status = "partial"
        elseif #rows == 0 then status = "empty" end
        local notes = {}
        if #failures > 0 then notes[#notes + 1] = "读取失败：" .. table.concat(failures, "；") end
        if unresolved > 0 then notes[#notes + 1] = "返回形态未识别 " .. tostring(unresolved) .. " 处（RU 契约待实证，未伪造数值）" end
        notes[#notes + 1] = "只读分析：探测 " .. tostring(REINFORCE_SLOT_PROBE_MAX) .. " 个槽位上限，不执行任何强化写入"
        return rows, status, table.concat(notes, "；")
    end,
})
NewFeature("tools_portal_profiles", { blocker = "X2Option optionType/返回值语义和个人传送候选集合未在当前 RU 客户端验证；禁止执行猜测写入" })
