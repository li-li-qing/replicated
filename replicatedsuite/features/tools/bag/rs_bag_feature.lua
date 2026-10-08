------------------------------------------------------------------------
-- Replicated Suite V3 - tools_bag Feature Authority
--
-- Phase 1 Batch E（2026-09-28）：从 features/rs_business_bridge.lua 机械搬迁（最后一批）。
-- 只改变源码边界，不改业务行为：Feature ID、Store ID/Schema、UpdateTopic、Demand owner、
-- Commands、Projection shape、ApiDependencies、三个 Scheduler task name
-- （v3_business_bag_category_batch / v3_business_bag_quick_observe / v3_business_bag_quick_move）、
-- 黑名单/搬运事务/快捷按钮语义全部与被搬迁前逐字一致。
--
-- Authority 边界：背包/仓储事实来自 InventorySnapshotV3 与 X2Bag/X2Bank/X2Coffer 只读接口；
-- 搬运类 Native 调用仍走能力门 + 冷却契约。背包扫描上界来自 features/shared/rs_shared_bounds.lua，
-- 禁止在本文件另写数字。
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local FSF = S.FeatureSliceFactory
if type(FSF) ~= "table" then error("FeatureSliceFactory unavailable for tools_bag") end
local Copy, Call, Action, Text, Number, Trim, Scalar = FSF.Copy, FSF.Call, FSF.Action, FSF.Text, FSF.Number, FSF.Trim, FSF.Scalar
local Load, PersistStateMutation, NewFeature = FSF.Load, FSF.PersistStateMutation, FSF.NewFeature
local P = S.Persistence
local BagApi = rawget(_G, "X2Bag")
local BankApi = rawget(_G, "X2Bank")
local CofferApi = rawget(_G, "X2Coffer")
local AddonApi = rawget(_G, "ADDON")

local BAG_SCAN_LIMIT = S.SharedBounds and S.SharedBounds.BagScanLimit
if type(BAG_SCAN_LIMIT) ~= "number" then error("SharedBounds.BagScanLimit unavailable for business bridge") end
local BLACKLIST_MAX_ENTRIES = 64
local BATCH_DEFAULT_LIMIT = 20
local BATCH_MAX_MOVES = 40
local BAG_BATCH_TASK = "v3_business_bag_category_batch"
local BAG_QUICK_OBSERVE_TASK = "v3_business_bag_quick_observe"
local BAG_QUICK_MOVE_TASK = "v3_business_bag_quick_move"
local BAG_QUICK_LIMIT = 40
-- 对齐当前 Capability Registry 的 MoveToEmpty* 200ms 冷却；仍通过 Api
-- 能力门执行，首拍也先读剩余冷却，不能把快速开始误判为物品拒收。
local BAG_MOVE_INTERVAL_MS = 200
local BAG_VERIFY_GRACE_MS = 250

-- The active V3 contract can safely observe the native bag window, but it
-- does not prove a supported native parent/embedding operation. Keep this
-- diagnostic read-only and fail closed when any part of the getter contract
-- is unavailable or malformed.
local function ReadBagWindowContext()
    local context = { status = "unknown", visible = nil, surfaceVisible = false, follow = "diagnostic_only", embed = "fail_closed", source = "none", surfaceSource = "none", visibilityConflict = false, reason = nil }
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

    local layoutContext = S.Layout ~= nil and type(S.Layout.GetContext) == "function" and S.Layout:GetContext() or {}
    local logicalWidth = math.max(320, tonumber(layoutContext.logicalWidth) or 1024)
    local logicalHeight = math.max(240, tonumber(layoutContext.logicalHeight) or 768)
    local function PlausibleRect(x, y, width, height)
        x, y, width, height = Number(x), Number(y), Number(width), Number(height)
        if x == nil or y == nil or width == nil or height == nil or width <= 0 or height <= 0 then return false end
        if width > logicalWidth * 2 or height > logicalHeight * 2 then return false end
        if x < -width or y < -height or x > logicalWidth + width or y > logicalHeight + height then return false end
        return true
    end
    -- RU native getters are inconsistent about boolean shape.  Treat only
    -- explicit boolean-like values as authoritative; unknown values remain
    -- unknown instead of being collapsed to false.
    local function NativeFlag(value)
        if type(value) == "boolean" then return true, value == true end
        if type(value) == "number" and (value == 0 or value == 1) then return true, value == 1 end
        if type(value) == "string" then
            local text = value:lower():gsub("^%s+", ""):gsub("%s+$", "")
            if text == "1" or text == "true" or text == "on" or text == "show" or text == "visible" then return true, true end
            if text == "0" or text == "false" or text == "off" or text == "hide" or text == "hidden" then return true, false end
        end
        return false, false
    end
    local function Content()
        if S.Api:IsCapabilityAllowed("ADDON:GetContent") ~= true or type(addonApi.GetContent) ~= "function" then return nil end
        local ok, value = S.Api:CallCapability("ADDON:GetContent", addonApi, "GetContent", bagContentId)
        return ok == true and value or nil
    end
    local function ChainVisible(content)
        local node, anyKnown = content, false
        for _ = 0, 8 do
            if node == nil then break end
            if type(node.IsVisible) == "function" then
                local ok, rawVisible = pcall(function() return node:IsVisible() end)
                if ok == true then
                    local known, isVisible = NativeFlag(rawVisible)
                    if known == true then
                        anyKnown = true
                        if isVisible == true then return true, true end
                    end
                end
            end
            if type(node.GetParent) ~= "function" then break end
            local ok, parent = pcall(function() return node:GetParent() end)
            if ok ~= true or parent == nil or parent == node then break end
            node = parent
        end
        return anyKnown, false
    end
    local function ContentRect(content, mainX, mainY, mainWidth, mainHeight)
        local node, candidate = content, nil
        local function MatchesMainRect(rx, ry, rw, rh)
            return mainX ~= nil and mainY ~= nil and mainWidth ~= nil and mainHeight ~= nil
                and math.abs(mainX-rx)<=2 and math.abs(mainY-ry)<=2
                and math.abs(mainWidth-rw)<=2 and math.abs(mainHeight-rh)<=2
        end
        for depth = 0, 8 do
            if node == nil or node == UIParent then break end
            if S.Layout ~= nil and (type(S.Layout.ResolveViewportLogicalRect) == "function" or type(S.Layout.GetLogicalRect) == "function") then
                -- 维护（2026-09-22，external-surface-geometry-1）：外部原生内容坐标最终用于 UIParent 侧栏锚定，
                -- 必须优先走已校准的 viewport-logical-v1；旧 GetLogicalRect 会在部分 RU UI Scale 语义下
                -- 重复除缩放。兼容测试/旧引导环境时才退回 legacy helper，不改变 Native ADDON Authority。
                local ok, x, y, width, height, geometry = pcall(function()
                    if type(S.Layout.ResolveViewportLogicalRect) == "function" then return S.Layout:ResolveViewportLogicalRect(node) end
                    return S.Layout:GetLogicalRect(node)
                end)
                -- 中文维护（2026-10-03）：UIC_BAG 可能是零点/全屏代理，不能把它或
                -- UIParent 当成背包。最多向上找 8 层实际窗口，坐标只由 Layout 校准一次。
                local scale=type(geometry)=="table" and tonumber(geometry.effectiveScale) or 1
                scale=scale or 1
                local rootX=type(geometry)=="table" and tonumber(geometry.uiParentRawX) or 0
                local rootY=type(geometry)=="table" and tonumber(geometry.uiParentRawY) or 0
                local originIsActual=x==0 and y==0 and (
                    MatchesMainRect(0,0,tonumber(width) or 0,tonumber(height) or 0)
                    or MatchesMainRect(rootX or 0,rootY or 0,(tonumber(width) or 0)*scale,(tonumber(height) or 0)*scale))
                local proxyOrigin = x == 0 and y == 0 and not originIsActual
                local viewportSized = (tonumber(width) or 0) >= logicalWidth - 2 and (tonumber(height) or 0) >= logicalHeight - 2
                if ok == true and PlausibleRect(x, y, width, height)
                    and (tonumber(width) or 0) >= 32 and (tonumber(height) or 0) >= 32 and not proxyOrigin and not viewportSized then
                    -- 中文维护（2026-10-04）：GetContent 也可能返回有效但带内边距的物品格子。
                    -- 优先匹配 MainScript 外窗矩形（逻辑或已校准 Native 单位），否则继续沿同一
                    -- 父链选最外层有效窗；不能见到第一个非零矩形就把内部区域当背包左上角。
                    candidate = { x=Number(x), y=Number(y), width=Number(width), height=Number(height),
                        source=depth == 0 and "bag-content" or ("bag-parent-" .. tostring(depth)), geometry=geometry, node=node }
                    local matches = MatchesMainRect(x,y,width,height)
                        or MatchesMainRect((rootX or 0)+x*scale,(rootY or 0)+y*scale,width*scale,height*scale)
                    if type(geometry)=="table" then geometry.bagAnchorSelection=matches and "main-script-match" or "outermost-content-parent" end
                    if matches then return candidate.x,candidate.y,candidate.width,candidate.height,candidate.source,geometry,node end
                end
            end
            if type(node.GetParent) ~= "function" then break end
            local ok, parent = pcall(function() return node:GetParent() end)
            if ok ~= true or parent == nil or parent == node then break end
            node = parent
        end
        if candidate then return candidate.x,candidate.y,candidate.width,candidate.height,candidate.source,candidate.geometry,candidate.node end
        return nil
    end

    local content = Content()
    local contentKnown, contentVisible = ChainVisible(content)
    local ok, x, y, width, height, visible = pcall(function()
        return addonApi:GetContentMainScriptPosVis(bagContentId)
    end)
    x, y, width, height = Number(x), Number(y), Number(width), Number(height)
    local mainRect = ok == true and PlausibleRect(x, y, width, height)
    local nativeKnown, nativeVisible = NativeFlag(visible)
    local resolvedVisible
    if nativeKnown == true then
        resolvedVisible = nativeVisible == true
    elseif contentVisible == true then
        resolvedVisible = true
    elseif mainRect == true then
        -- A hidden/non-visual ADDON content proxy must not veto a valid native
        -- MainScript rectangle.  This was the remaining RU bag/bank failure:
        -- GetContent() could expose a proxy whose IsVisible=false while the
        -- actual MainScript window was open and returned valid geometry.
        resolvedVisible = true
    elseif contentKnown == true then
        resolvedVisible = false
    else
        resolvedVisible = false
    end
    -- Presentation and native writes deliberately use different facts. During
    -- the RU open animation MainScript may still report explicit hidden/0 for
    -- one beat after the ADDON content chain is already visibly on screen. That
    -- stale native flag must not suppress the harmless 取/放 surface, but it
    -- remains authoritative for every inventory write (`visible`).
    local surfaceVisible = nativeVisible == true or contentVisible == true
        or (nativeKnown ~= true and mainRect == true)
    local px, py, pw, ph, source, geometry, anchor = ContentRect(content, x, y, width, height)
    if mainRect == true then
        context.status, context.visible, context.surfaceVisible = "ready", resolvedVisible, surfaceVisible
        context.visibilityConflict = surfaceVisible == true and resolvedVisible ~= true
        context.mainScriptRect = { x = x, y = y, width = width, height = height }
        -- 中文维护（2026-10-03）：MainScript 继续决定可见性和搬运安全；摆放优先
        -- 使用实际 Native 窗口的 viewport-logical 几何。没有可证明控件时保留既有
        -- MainScript 回退并在诊断中明确标为未校准，不能对未知单位一律再除 UI Scale。
        context.x, context.y, context.width, context.height = px or x, py or y, pw or width, ph or height
        context.geometrySource = source or "main-script-unverified-fallback"
        context.geometry = geometry
        context.source = nativeKnown and "main-script" or (contentVisible and "main-script+content-visible" or (contentKnown and "main-script-geometry-over-proxy" or "main-script-geometry"))
        context.surfaceSource = context.visibilityConflict and "content-visible-over-native-hidden" or context.source
        return context, anchor
    end

    if px ~= nil then
        context.status, context.visible, context.surfaceVisible = "ready", contentVisible == true, contentVisible == true
        context.x, context.y, context.width, context.height, context.source, context.surfaceSource = px, py, pw, ph, source, source
        context.geometrySource, context.geometry = source, geometry
        return context, anchor
    end
    if contentKnown == true and contentVisible ~= true then
        context.status, context.visible, context.surfaceVisible, context.source, context.surfaceSource, context.reason = "ready", false, false, "content-hidden", "content-hidden", nil
        return context
    end
    context.reason = ok ~= true and "原生窗口几何读取失败" or "原生窗口几何/可见性返回值未知"
    return context
end

local function ReadStorageWindowContext(target)
    local addonApi = AddonApi or rawget(_G, "ADDON")
    local contentId = target == "bank" and rawget(_G, "UIC_BANK") or target == "coffer" and rawget(_G, "UIC_COFFER") or nil
    local result = { kind = target, status = "unknown", visible = false, surfaceVisible = false, source = "none", surfaceSource = "none", visibilityConflict = false, reason = nil }
    if addonApi == nil or contentId == nil then result.reason = "仓储窗口标识不可用"; return result end
    if S.Api == nil or type(S.Api.IsCapabilityAllowed) ~= "function"
        or S.Api:IsCapabilityAllowed("ADDON:GetContentMainScriptPosVis") ~= true
        or type(addonApi.GetContentMainScriptPosVis) ~= "function" then
        result.reason = "仓储窗口几何 API 不可用"; return result
    end

    local layoutContext = S.Layout ~= nil and type(S.Layout.GetContext) == "function" and S.Layout:GetContext() or {}
    local logicalWidth = math.max(320, tonumber(layoutContext.logicalWidth) or 1024)
    local logicalHeight = math.max(240, tonumber(layoutContext.logicalHeight) or 768)
    local function PlausibleRect(x, y, width, height)
        x, y, width, height = Number(x), Number(y), Number(width), Number(height)
        return x ~= nil and y ~= nil and width ~= nil and height ~= nil and width > 0 and height > 0
            and width <= logicalWidth * 2 and height <= logicalHeight * 2
            and x >= -width and y >= -height and x <= logicalWidth + width and y <= logicalHeight + height
    end
    local function NativeFlag(value)
        if type(value) == "boolean" then return true, value == true end
        if type(value) == "number" and (value == 0 or value == 1) then return true, value == 1 end
        if type(value) == "string" then
            local text = value:lower():gsub("^%s+", ""):gsub("%s+$", "")
            if text == "1" or text == "true" or text == "on" or text == "show" or text == "visible" then return true, true end
            if text == "0" or text == "false" or text == "off" or text == "hide" or text == "hidden" then return true, false end
        end
        return false, false
    end

    local content
    if S.Api:IsCapabilityAllowed("ADDON:GetContent") == true and type(addonApi.GetContent) == "function" then
        local contentOk, value = S.Api:CallCapability("ADDON:GetContent", addonApi, "GetContent", contentId)
        if contentOk == true then content = value end
    end
    local contentKnown, contentVisible = false, false
    local node = content
    for _ = 0, 8 do
        if node == nil then break end
        if type(node.IsVisible) == "function" then
            local visOk, rawVisible = pcall(function() return node:IsVisible() end)
            if visOk == true then
                local known, isVisible = NativeFlag(rawVisible)
                if known == true then
                    contentKnown = true
                    if isVisible == true then contentVisible = true; break end
                end
            end
        end
        if type(node.GetParent) ~= "function" then break end
        local parentOk, parent = pcall(function() return node:GetParent() end)
        if parentOk ~= true or parent == nil or parent == node then break end
        node = parent
    end

    local ok, x, y, width, height, visible = pcall(function() return addonApi:GetContentMainScriptPosVis(contentId) end)
    x, y, width, height = Number(x), Number(y), Number(width), Number(height)
    local mainRect = ok == true and PlausibleRect(x, y, width, height)
    local nativeKnown, nativeVisible = NativeFlag(visible)
    local resolvedVisible
    if nativeKnown == true then resolvedVisible = nativeVisible == true
    elseif contentVisible == true then resolvedVisible = true
    elseif mainRect == true then resolvedVisible = true
    elseif contentKnown == true then resolvedVisible = false
    else resolvedVisible = false end
    local surfaceVisible = nativeVisible == true or contentVisible == true
        or (nativeKnown ~= true and mainRect == true)

    if mainRect == true then
        result.status, result.visible, result.surfaceVisible = "ready", resolvedVisible, surfaceVisible
        result.visibilityConflict = surfaceVisible == true and resolvedVisible ~= true
        result.x, result.y, result.width, result.height = x, y, width, height
        result.source = nativeKnown and "main-script" or (contentVisible and "main-script+content-visible" or (contentKnown and "main-script-geometry-over-proxy" or "main-script-geometry"))
        result.surfaceSource = result.visibilityConflict and "content-visible-over-native-hidden" or result.source
        return result
    end
    -- Storage geometry is not required to anchor the quick bar; the bag owns
    -- presentation geometry. A positively visible content chain is sufficient
    -- to prove that bank/coffer actions are currently meaningful.
    if contentVisible == true then
        result.status, result.visible, result.surfaceVisible, result.source, result.surfaceSource = "ready", true, true, "content-visible", "content-visible"
        return result
    end
    if contentKnown == true then
        result.status, result.visible, result.surfaceVisible, result.source, result.surfaceSource, result.reason = "ready", false, false, "content-hidden", "content-hidden", nil
        return result
    end
    result.reason = ok ~= true and "仓储窗口几何读取失败" or "仓储窗口几何/可见性返回值未知"
    return result
end

local function CurrentStorageContext()
    local bank = ReadStorageWindowContext("bank")
    if type(bank)=="table" and bank.status=="ready" and bank.visible==true then return bank end
    local coffer = ReadStorageWindowContext("coffer")
    if type(coffer)=="table" and coffer.status=="ready" and coffer.visible==true then return coffer end
    return nil
end

local function RequireStorageWindow(target)
    local context = ReadStorageWindowContext(target)
    if type(context) ~= "table" or context.status ~= "ready" then
        return false, tostring(context and context.reason or "仓储窗口可见性/几何返回值未知") .. "，已安全拒绝"
    end
    if context.visible ~= true then return false, "请先打开对应的银行/箱子窗口；窗口状态无法确认时安全拒绝" end
    return true
end

-- 中文维护注释（2026-09-28，Phase 1 Batch A）：Trim 已由工厂提供。

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
        -- itemName is Presentation metadata only. Runtime blocking continues to
        -- use itemType/category as the sole Authority, so a localized-name
        -- change can never make a blacklisted item pass the write gate.
        bank = { itemType = {}, category = {}, itemName = {} },
        coffer = { itemType = {}, category = {}, itemName = {} },
    }
    for scope, index in pairs({ bank = 1, coffer = 2 }) do
        local sourceScope = ScopeSource(source, scope, index)
        normalized[scope].itemType = NormalizeMap(FirstMap(sourceScope, { "itemType", "itemTypes", "items" }), NormalizeItemType)
        normalized[scope].category = NormalizeMap(FirstMap(sourceScope, { "category", "categories" }), NormalizeCategory)
        local nameSource = FirstMap(sourceScope, { "itemName", "itemNames", "names" })
        for rawId, rawName in pairs(type(nameSource) == "table" and nameSource or {}) do
            local itemType, itemName = NormalizeItemType(rawId), Trim(rawName)
            if itemType ~= nil and itemName ~= "" and #itemName <= 96 and itemName:find("[%c]") == nil then
                normalized[scope].itemName[itemType] = itemName
            end
        end
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
    -- User-facing blacklist rules are global to the organizer. A single item is
    -- mirrored into bank+coffer for backwards-compatible runtime enforcement,
    -- but it must count as one logical rule rather than consuming two slots.
    local total, seen = 0, {}
    for _, scope in ipairs({ "bank", "coffer" }) do
        local bucket = type(config) == "table" and config[scope] or nil
        for _, field in ipairs({ "itemType", "category" }) do
            for key in pairs(type(bucket) == "table" and bucket[field] or {}) do
                local token = tostring(field) .. ":" .. tostring(key)
                if seen[token] ~= true then seen[token] = true; total = total + 1 end
            end
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
    -- 中文维护（2026-10-03）：黑名单是全放的保护条件；点击成功时必须耐久保存，
    -- 不能在退出后悄悄失去保护。共享事件只发布已提交事实，不在此增加背包扫描。
    end, { durable = true, reason = tostring(reason or "blacklist_changed") })
    if marked ~= true then return false, tostring(mutationErr or "黑名单未保存，已回滚") end
    if changed == true and S.Events ~= nil then
        feature.Authority.revision = (tonumber(feature.Authority.revision) or 0) + 1
        S.Events:Publish(feature.UpdateTopic, feature.Authority.revision, "blacklist_changed")
    end
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
    local inventory = S.Services and S.Services.InventorySnapshotV3 or nil
    if type(inventory) == "table" and type(inventory.ExtractItemType) == "function" and type(inventory.ExtractCategory) == "function" then
        return inventory:ExtractItemType(info), inventory:ExtractCategory(info)
    end
    return nil, nil
end

-- Same-item quick take/put must survive RU builds that occasionally omit
-- itemType on bag-like container rows.  The preferred identity remains the
-- numeric itemType.  Only when that field is absent do we fall back to the
-- client-provided localized name + grade + category tuple that the previous
-- production implementation already used.  This fallback is used only to
-- compare two read-only slot records; it never invents an itemType and never
-- bypasses the per-storage blacklist check before a native write.
local function StableItemIdentity(info)
    local inventory = S.Services and S.Services.InventorySnapshotV3 or nil
    if type(inventory) == "table" and type(inventory.StableIdentity) == "function" then
        return inventory:StableIdentity(info)
    end
    return nil, nil, nil, nil
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
        local inventory = S.Services and S.Services.InventorySnapshotV3 or nil
        if type(inventory) ~= "table" or type(inventory.ReadPhysicalBagSlot) ~= "function" then
            return false, "黑名单检查失败：InventorySnapshotV3 不可用"
        end
        callOk, item, readErr = inventory:ReadPhysicalBagSlot(sourceSlot)
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
-- NOTE: the declaration of `BagMoveRuntime` moved here from further down.  This
-- chunk is one function scope and Lua allows 200 locals per function; the file
-- already sits at that ceiling (195 top-level declarations).  Every quick-run
-- helper below therefore lives as a BagMoveRuntime *field* instead of a new
-- file-scope local, which is also why CheckedMove/BatchMove/Refresh can reach
-- the reclaim without a forward-declared local.
local BagMoveRuntime = {}
BagMoveRuntime.QuickObserverIntervalMs = 100

-- Product UX helpers for the organizer blacklist. These live on BagMoveRuntime
-- instead of adding more file-scope locals: rs_business_bridge.lua is already
-- close to Lua 5.1's 200-local main-chunk ceiling. All scans below are bounded
-- and only run after an explicit user action or page refresh; never from the
-- 100ms native-window observer.
function BagMoveRuntime.NormalizeBlacklistItemName(value)
    local name = Trim(value)
    if name == "" or #name > 96 or name:find("[%c]") ~= nil then return nil end
    return name
end

function BagMoveRuntime.KnownBlacklistItemName(feature, itemType)
    local key = NormalizeItemType(itemType)
    if key == nil then return nil end
    for _, row in ipairs(type(feature) == "table" and type(feature.Authority) == "table" and type(feature.Authority.rows) == "table" and feature.Authority.rows or {}) do
        if NormalizeItemType(row and row.itemType) == key then
            local name = BagMoveRuntime.NormalizeBlacklistItemName(row.itemName or row.name)
            if name ~= nil then return name end
        end
    end
    local config = type(feature) == "table" and type(feature.State) == "table" and feature.State.blacklist or nil
    for _, scope in ipairs({ "bank", "coffer" }) do
        local bucket = type(config) == "table" and config[scope] or nil
        local name = type(bucket) == "table" and type(bucket.itemName) == "table" and bucket.itemName[key] or nil
        name = BagMoveRuntime.NormalizeBlacklistItemName(name)
        if name ~= nil then return name end
    end
    return nil
end

function BagMoveRuntime.AddGlobalBlacklistItem(feature, itemType, itemName)
    local key = NormalizeItemType(itemType)
    if key == nil then return false, "物品ID必须是正整数" end
    local safeName = BagMoveRuntime.NormalizeBlacklistItemName(itemName)
    return MutateBlacklist(feature, "bag_blacklist_item_global_add", function(config)
        local alreadyKnown = MapContains(config.bank and config.bank.itemType, key) or MapContains(config.coffer and config.coffer.itemType, key)
        if alreadyKnown ~= true and BlacklistEntryCount(config) >= BLACKLIST_MAX_ENTRIES then return false, "黑名单条目已达上限（64）" end
        local changed = config.enabled ~= true
        config.enabled = true
        for _, scope in ipairs({ "bank", "coffer" }) do
            local bucket = config[scope]
            bucket.itemType = type(bucket.itemType) == "table" and bucket.itemType or {}
            bucket.itemName = type(bucket.itemName) == "table" and bucket.itemName or {}
            if MapContains(bucket.itemType, key) ~= true then bucket.itemType[key] = true; changed = true end
            if safeName ~= nil and bucket.itemName[key] ~= safeName then bucket.itemName[key] = safeName; changed = true end
        end
        return true, changed
    end)
end

function BagMoveRuntime.RemoveGlobalBlacklistItem(feature, itemType)
    local key = NormalizeItemType(itemType)
    if key == nil then return false, "请选择有效的黑名单物品" end
    return MutateBlacklist(feature, "bag_blacklist_item_global_remove", function(config)
        local changed = false
        for _, scope in ipairs({ "bank", "coffer" }) do
            local bucket = config[scope]
            if type(bucket) == "table" then
                local itemMap = type(bucket.itemType) == "table" and bucket.itemType or {}
                local nameMap = type(bucket.itemName) == "table" and bucket.itemName or {}
                if MapContains(itemMap, key) then itemMap[key], itemMap[tonumber(key)] = nil, nil; changed = true end
                if nameMap[key] ~= nil or nameMap[tonumber(key)] ~= nil then nameMap[key], nameMap[tonumber(key)] = nil, nil; changed = true end
            end
        end
        if changed ~= true then return false, "黑名单中不存在该物品" end
        return true, true
    end)
end

function BagMoveRuntime.ResolveAndAddBlacklistItem(feature, query)
    local raw = Trim(query)
    if raw == "" or #raw > 96 or raw:find("[%c]") ~= nil then return false, "请输入物品ID或物品名称" end

    -- A numeric ItemID is already an authoritative identity. Do not make the
    -- explicit-ID workflow depend on a readable bag/storage snapshot: this is
    -- important for users who know the ID but do not currently own the item.
    local numeric = NormalizeItemType(raw)
    if numeric ~= nil then
        return BagMoveRuntime.AddGlobalBlacklistItem(feature, numeric, BagMoveRuntime.KnownBlacklistItemName(feature, numeric))
    end

    -- Name lookup is intentionally evidence-bound to the current bag and the
    -- currently open storage. It runs only on this explicit button press.
    local inventory = S.Services and S.Services.InventorySnapshotV3 or nil
    if type(inventory) ~= "table" or type(inventory.BuildSnapshot) ~= "function" then return false, "背包快照服务不可用；可直接输入物品ID" end

    local candidates, byId = {}, {}
    local function collect(snapshot)
        for _, row in ipairs(type(snapshot) == "table" and snapshot.rows or {}) do
            local id = NormalizeItemType(row and row.itemType)
            local name = BagMoveRuntime.NormalizeBlacklistItemName(row and row.name)
            if id ~= nil and byId[id] == nil then
                byId[id] = { itemType = id, name = name }
                candidates[#candidates + 1] = byId[id]
            elseif id ~= nil and name ~= nil and byId[id] ~= nil and byId[id].name == nil then
                byId[id].name = name
            end
        end
    end

    local bagSnapshot = inventory:BuildSnapshot("bag", { maxSlots = BAG_SCAN_LIMIT })
    if type(bagSnapshot) == "table" then collect(bagSnapshot) end
    local storage = CurrentStorageContext()
    if type(storage) == "table" and (storage.kind == "bank" or storage.kind == "coffer") then
        local storageSnapshot = inventory:BuildSnapshot(storage.kind, { maxSlots = BAG_SCAN_LIMIT })
        if type(storageSnapshot) == "table" then collect(storageSnapshot) end
    end

    local queryLower, exact, partial = raw:lower(), {}, {}
    for _, row in ipairs(candidates) do
        local name = BagMoveRuntime.NormalizeBlacklistItemName(row.name)
        if name ~= nil then
            local lowered = name:lower()
            if lowered == queryLower then exact[#exact + 1] = row
            elseif lowered:find(queryLower, 1, true) ~= nil then partial[#partial + 1] = row end
        end
    end
    local matches = #exact > 0 and exact or partial
    if #matches == 1 then return BagMoveRuntime.AddGlobalBlacklistItem(feature, matches[1].itemType, matches[1].name) end
    if #matches > 1 then return false, "匹配到 " .. tostring(#matches) .. " 个物品，请输入更完整的名称或从背包列表选择" end
    return false, "当前背包/仓储中未找到该名称；可直接输入物品ID"
end

function BagMoveRuntime.BlacklistRows(feature)
    local config = type(feature) == "table" and type(feature.State) == "table" and feature.State.blacklist or nil
    local keys, seen = {}, {}
    for _, scope in ipairs({ "bank", "coffer" }) do
        local bucket = type(config) == "table" and config[scope] or nil
        for key in pairs(type(bucket) == "table" and type(bucket.itemType) == "table" and bucket.itemType or {}) do
            local normalized = NormalizeItemType(key)
            if normalized ~= nil and seen[normalized] ~= true then seen[normalized] = true; keys[#keys + 1] = normalized end
        end
    end
    table.sort(keys, function(a, b) return (tonumber(a) or math.huge) < (tonumber(b) or math.huge) end)
    local rows = {}
    for _, key in ipairs(keys) do
        local bank = type(config) == "table" and type(config.bank) == "table" and MapContains(config.bank.itemType, key) or false
        local coffer = type(config) == "table" and type(config.coffer) == "table" and MapContains(config.coffer.itemType, key) or false
        local scopeText = bank and coffer and "全部仓储" or (bank and "银行" or "箱子")
        local name = BagMoveRuntime.KnownBlacklistItemName(feature, key) or "名称待识别"
        rows[#rows + 1] = { value = key, text = tostring(key) .. " · " .. name, itemType = key, itemName = name, scopeText = scopeText }
    end
    return rows
end

-- An installed queue table is NOT proof of a running move: BeginBagQuick used to
-- assign the (empty) queue table before its `plannedMoves == 0` early return, so
-- one click that matched nothing held the quick mutex for the rest of the
-- session.  Every later 取/放 click, direct move and category batch was then
-- refused with "已经在运行" while the refused click still reported success -
-- exactly the reported "sometimes 取/放 does nothing, it must be stuck".
function BagMoveRuntime.QuickQueueActive(feature)
    if type(feature) ~= "table" then return false end
    if feature._quickPending ~= nil then return true end
    return type(feature._quickQueue) == "table" and #feature._quickQueue > 0
end

local function BagQuickRunning(feature)
    if type(feature) ~= "table" then return false end
    if BagMoveRuntime.QuickQueueActive(feature) == true then return true end
    local overlay = feature._quickOverlay
    local status = type(overlay) == "table" and tostring(overlay.status or "") or ""
    return status == "正在取出" or status == "正在放入"
end

-- Evidence window for the serialized 250 ms queue.  A healthy step touches the
-- task every 250 ms, so eight seconds of silence can only mean the queue stopped
-- progressing.  Reclaiming loses nothing: no item is dropped, only the mutex is
-- released and the reason published; the next click rebuilds the plan from live
-- container state, which is how every single step already works.
BagMoveRuntime.QuickRunStaleMs = 8000
BagMoveRuntime.QuickDirectionLabel = { withdraw = "取出", deposit = "存入", deposit_all = "全部存入" }

function BagMoveRuntime.QuickRunEvidence(feature)
    local state = (S.Scheduler ~= nil and type(S.Scheduler.GetTaskState) == "function")
        and S.Scheduler:GetTaskState(BAG_QUICK_MOVE_TASK) or nil
    local telemetry = type(state) == "table"
    -- `registered ~= true` is an immediate orphan: AddTask happens synchronously
    -- with acquiring the mutex, so a missing task can only mean a reload/owner
    -- cleanup removed it while the queue state survived.
    if telemetry == true and state.registered ~= true then return false, "移动任务未注册（已被重载或关闭清理）" end
    local now = type(S.NowMs) == "function" and tonumber(S.NowMs()) or 0
    -- Without scheduler telemetry the queue's own step stamp is the only honest
    -- evidence.  "no data" must never mean "reclaim": that would kill every
    -- healthy run on a scheduler build that stops exposing GetTaskState.
    local anchor = math.max(tonumber(telemetry and state.lastRunAtMs) or 0, tonumber(feature._quickLastStepAt) or 0)
    if anchor <= 0 then return false, "没有任何执行证据" end
    local idle = now - anchor
    if idle < (tonumber(BagMoveRuntime.QuickRunStaleMs) or 8000) then return true, nil end
    local reason = "移动任务已 " .. tostring(math.floor(idle / 1000)) .. " 秒未推进"
    if telemetry == true and state.enabled ~= true then reason = reason .. "（连续异常已暂停）" end
    if telemetry == true and type(state.lastError) == "string" and state.lastError ~= "" then
        reason = reason .. "：" .. state.lastError
    end
    return false, reason
end

-- 高级整理目标 = 当前真正开着的那个仓储窗口。银行与箱子在 RU 里不会同时打开，
-- 让用户在「目标：银行 / 目标：箱子」之间二选一只会制造歧义（用户原话：用户看不
-- 懂这个）。快捷取放早已用同一个 CurrentStorageContext 事实，这里不再另立一套。
function BagMoveRuntime.ResolveBatchTarget()
    local storage = CurrentStorageContext()
    if type(storage) ~= "table" then
        return nil, "请先打开银行或箱子；两者不会同时开着，整理目标就是当前打开的那个"
    end
    return storage.kind, nil
end

-- The floating bar status label is at least 132 px wide (240 - 104 - 4), i.e.
-- roughly twelve 9 px CJK glyphs.  Long technical detail stays in
-- `overlay.error` (page status line + diagnostics); the bar shows one short,
-- still meaningful clause.
BagMoveRuntime.QuickStatusSeparators = { "（", "，", ",", "；", ";", "。", ":", "：" }
function BagMoveRuntime.QuickStatusText(reason)
    local text = tostring(reason or "失败")
    -- Split on the first separator with plain (whole-string) find.  A negated
    -- byte class like `[^（，。]` looks equivalent but is not: Lua patterns work
    -- on bytes, so every CJK character that happens to contain one of those
    -- bytes (刻 = E5 88 BB shares 0x88 with 「（」) gets cut in half and the
    -- label renders mojibake.  Proven by the behaviour simulator.
    local head, headAt = text, nil
    for _, separator in ipairs(BagMoveRuntime.QuickStatusSeparators) do
        local at = string.find(text, separator, 1, true)
        if at ~= nil and (headAt == nil or at < headAt) then headAt, head = at, string.sub(text, 1, at - 1) end
    end
    if head == nil or head == "" then head = text end
    local out, count = "", 0
    -- One UTF-8 codepoint per iteration: an ASCII byte, or a lead byte 192-244
    -- plus its continuation bytes.  A "[\1-\127]" class alone silently skips
    -- every CJK glyph, which made the first version of this counter report
    -- length 0 for Chinese text (caught by the behaviour simulator, not by the
    -- eye -- the truncated label looked "short" and passed).
    for glyph in string.gmatch(head, "[\1-\127\192-\244][\128-\191]*") do
        count = count + 1
        if count > 11 then return out .. "…" end
        out = out .. glyph
    end
    return out
end

local function BagBatchRunning(feature)
    return type(feature) == "table" and type(feature.State) == "table"
        and type(feature.State.batch) == "table" and feature.State.batch.status == "running"
end

local function CheckedMove(feature, sourceScope, blacklistScope, capability, object, method, slot)
    BagMoveRuntime.ReclaimStaleBagQuickRun(feature)
    if BagQuickRunning(feature) then return false, "快捷取放正在运行，再点一次「取」或「放」可停止" end
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
    local bagById = {}
    for _, row in ipairs(type(feature.Authority) == "table" and type(feature.Authority.rows) == "table" and feature.Authority.rows or {}) do
        local category = row and row.category
        if category ~= nil then
            local key = tostring(category)
            if seen[key] ~= true then
                seen[key] = true
                categoryOptions[#categoryOptions + 1] = { value = key, text = BagCategoryLabel(category) .. "（" .. key .. "）" }
            end
        end
        local itemType = NormalizeItemType(row and row.itemType)
        if itemType ~= nil then
            local entry = bagById[itemType]
            if entry == nil then
                local itemName = BagMoveRuntime.NormalizeBlacklistItemName(row.itemName or row.name) or "名称未知"
                entry = { itemType = itemType, itemName = itemName, stack = 0, category = category }
                bagById[itemType] = entry
            end
            entry.stack = (tonumber(entry.stack) or 0) + math.max(1, tonumber(row.stack) or 1)
            if (entry.itemName == nil or entry.itemName == "名称未知") then
                entry.itemName = BagMoveRuntime.NormalizeBlacklistItemName(row.itemName or row.name) or entry.itemName
            end
            entry.category = entry.category or category
        end
    end
    table.sort(categoryOptions, function(a, b) return tostring(a.text or "") < tostring(b.text or "") end)

    -- Presentation projection for the product page: one row per itemType, not one
    -- row per physical slot. This is derived from the already-demanded bag
    -- Authority, so no extra inventory scan is introduced by rendering the page.
    local bagItemRows, bagItemOptions, bagKeys = {}, {}, {}
    for key in pairs(bagById) do bagKeys[#bagKeys + 1] = key end
    table.sort(bagKeys, function(a, b) return (tonumber(a) or math.huge) < (tonumber(b) or math.huge) end)
    for _, key in ipairs(bagKeys) do
        local item = bagById[key]
        local display = tostring(key) .. " · " .. tostring(item.itemName or "名称未知")
        local categoryText = item.category ~= nil and BagCategoryLabel(item.category) or "类别未知"
        bagItemRows[#bagItemRows + 1] = {
            key = "bag:item:" .. tostring(key), name = display, text = categoryText,
            statusText = "×" .. tostring(math.max(1, math.floor(tonumber(item.stack) or 1))), tone = "default",
            itemType = key, itemName = item.itemName, category = item.category, stack = item.stack,
        }
        bagItemOptions[#bagItemOptions + 1] = { value = key, text = display .. "  ×" .. tostring(math.max(1, math.floor(tonumber(item.stack) or 1))) }
    end

    local blacklistRows = BagMoveRuntime.BlacklistRows(feature)
    local blacklistOptions = {}
    for _, row in ipairs(blacklistRows) do
        blacklistOptions[#blacklistOptions + 1] = { value = row.value, text = row.text .. "  · " .. tostring(row.scopeText or "全部仓储") }
    end
    local legacyCategoryCount, legacySeen = 0, {}
    local blacklist = type(feature.State.blacklist) == "table" and feature.State.blacklist or {}
    for _, scope in ipairs({ "bank", "coffer" }) do
        local bucket = type(blacklist[scope]) == "table" and blacklist[scope] or {}
        for key in pairs(type(bucket.category) == "table" and bucket.category or {}) do
            local token = tostring(key)
            if legacySeen[token] ~= true then legacySeen[token] = true; legacyCategoryCount = legacyCategoryCount + 1 end
        end
    end

    local openStorage = CurrentStorageContext()
    local resolvedTarget = type(openStorage) == "table" and openStorage.kind or nil
    local quickOverlay = Copy(feature._quickOverlay or { visible=false, storageKind=nil, status="等待仓库/箱子", moved=0, skipped=0, queued=0 })
    -- running/direction are derived facts, never stored state: an orphaned queue
    -- must not keep advertising itself as running to the presentation layer.
    quickOverlay.running = BagQuickRunning(feature) == true
    quickOverlay.direction = feature._quickDirection
    return { blacklist = feature.State.blacklist, blacklistRows = blacklistRows, blacklistOptions = blacklistOptions,
        blacklistLegacyCategoryCount = legacyCategoryCount, bagItemRows = bagItemRows, bagItemOptions = bagItemOptions,
        bagItemCount = #bagItemRows, batchCategory = feature.State.batchCategory,
        -- Legacy category-batch state/Commands remain public for upgrade/API
        -- compatibility, but the normal player page no longer exposes them.
        batchTarget = feature.State.batchTarget, batchTargetMode = "auto_open_storage",
        batchTargetResolved = resolvedTarget,
        batchTargetLabel = resolvedTarget == "coffer" and "箱子" or (resolvedTarget == "bank" and "银行" or nil),
        batchLimit = feature.State.batchLimit,
        batch = feature.State.batch, batchCategoryOptions = categoryOptions,
        windowContext = windowContext,
        quickOverlay = quickOverlay,
        quickButtons = {
            mode = "free_floating_bar_v1", status = "ready", requiresSourceSlot = false,
            reason = "打开仓库/箱子后显示取、放、全放和设置；拖动左侧 ≡ 调整并保存位置；放只移同类，全放尝试所有非黑名单物品；运行中再点同一个动作停止，点另一个切换",
            actions = { "QuickWithdraw", "QuickDeposit", "QuickDepositAll" },
        }, }
end
-- 中文维护注释（2026-09-28，Phase 1 Batch A）：原 `local PersistStateMutation` 前向声明已删除，
-- 现在指向工厂实现（见文件顶部别名），调用点行为不变。

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
    feature._batchQueue, feature._batchIndex, feature._batchTarget, feature._batchPending, feature._batchSourceCount, feature._batchBagId = nil, nil, nil, nil, nil, nil
    feature._batchBlockedIdentities = nil
    feature.State.batch = type(feature.State.batch) == "table" and feature.State.batch or { moved = 0, skipped = 0, queued = 0 }
    feature.State.batch.status = status or "stopped"
    feature.State.batch.error = errorText
    local performance = feature.State.batch.performance
    if type(performance) == "table" then
        performance.elapsedMs = math.max(0, (type(S.NowMs) == "function" and tonumber(S.NowMs()) or 0) - performance.startedAt)
    end
    return true
end

local function PublishBagOverlay(feature, reason)
    if S.Events ~= nil and type(S.Events.Publish)=="function" then
        S.Events:Publish(feature.UpdateTopic, feature.Authority.revision, tostring(reason or "bag_overlay"))
    end
end

local function StopBagQuick(feature, status, errorText)
    local overlay = type(feature._quickOverlay)=="table" and feature._quickOverlay or {}
    if feature._quickDirection~=nil then
        -- 有界 Session 摘要留给完整诊断；不是永久配置，也不增加历史队列。
        overlay.lastRun={direction=feature._quickDirection,status=status or "停止",planned=tonumber(overlay.queued) or 0,
            moved=tonumber(overlay.moved) or 0,skipped=tonumber(overlay.skipped) or 0,
            reason=errorText or overlay.error,finishedAt=type(S.NowMs)=="function" and tonumber(S.NowMs()) or 0}
        if type(feature._quickPerformance) == "table" then
            local performance = Copy(feature._quickPerformance)
            performance.elapsedMs = math.max(0, overlay.lastRun.finishedAt - performance.startedAt)
            overlay.lastRun.performance = performance
        end
    end
    if S.Scheduler ~= nil and type(S.Scheduler.RemoveTask)=="function" then S.Scheduler:RemoveTask(BAG_QUICK_MOVE_TASK) end
    feature._quickQueue, feature._quickIndex, feature._quickPending, feature._quickSourceCounts, feature._quickBagId = nil, nil, nil, nil, nil
    feature._quickDirection, feature._quickLastStepAt = nil, nil
    feature._quickSlotHint = nil
    feature._quickPerformance = nil
    feature._quickOverlay = overlay
    feature._quickOverlay.status = status or "停止"
    feature._quickOverlay.error = errorText
    feature._quickOverlay.queued = 0
    -- Timestamp every status write: the floating bar shows a refusal/stop line
    -- for a bounded window and then goes quiet again (quiet-by-default surface).
    feature._quickOverlay.statusAt = type(S.NowMs) == "function" and tonumber(S.NowMs()) or 0
    PublishBagOverlay(feature,"bag_quick_stop")
    return true
end

-- Self-heal: a quick queue that lost its executor (reload, owner cleanup, a
-- permanently faulted scheduler task) used to block the whole Feature until a
-- reload, because the only unlock was the third 停 button the user reports as
-- useless.  With two buttons the state machine has to recover on its own, so
-- this runs from the 100 ms window observer and from every click.
function BagMoveRuntime.ReclaimStaleBagQuickRun(feature)
    if BagQuickRunning(feature) ~= true then return false end
    local alive, evidence = BagMoveRuntime.QuickRunEvidence(feature)
    if alive == true then return false end
    local overlay = type(feature._quickOverlay) == "table" and feature._quickOverlay or {}
    local moved = tonumber(overlay.moved) or 0
    StopBagQuick(feature, "已自动停止", "取放队列失去执行证据（" .. tostring(evidence or "unknown")
        .. "），已自动释放；本轮已移动 " .. tostring(moved) .. " 个，可再点一次「取」或「放」继续")
    return true
end


function BagMoveRuntime.ReadScopeSlot(scope, slot, bagId)
    local inventory = S.Services and S.Services.InventorySnapshotV3 or nil
    if type(inventory) ~= "table" or type(inventory.ReadSlot) ~= "function" then
        return false, nil, "InventorySnapshotV3 unavailable"
    end
    return inventory:ReadSlot(scope, slot, bagId)
end

function BagMoveRuntime.ReadScopeCapacity(scope)
    local inventory = S.Services and S.Services.InventorySnapshotV3 or nil
    if type(inventory) ~= "table" or type(inventory.ReadCapacity) ~= "function" then
        return nil, "InventorySnapshotV3 unavailable"
    end
    local scanSlots, err, truncated = inventory:ReadCapacity(scope, BAG_SCAN_LIMIT)
    return scanSlots, err, truncated
end

local function BagIdentitySet(scope)
    local inventory = S.Services and S.Services.InventorySnapshotV3 or nil
    if type(inventory) ~= "table" or type(inventory.BuildSnapshot) ~= "function" then
        return nil, nil, 1, "InventorySnapshotV3 unavailable", nil, nil, nil
    end
    local snapshot, snapshotErr = inventory:BuildSnapshot(scope, { maxSlots = BAG_SCAN_LIMIT })
    if type(snapshot) ~= "table" then
        return nil, nil, 1, snapshotErr or "容器快照读取失败", nil, nil, nil
    end
    local rows = {}
    for _, row in ipairs(snapshot.rows or {}) do
        rows[#rows + 1] = {
            slot = row.slot, identity = row.identity, identityMode = row.identityMode,
            itemType = row.itemType, category = row.category, info = row,
        }
    end
    local readErrors = tonumber(snapshot.readErrors) or 0
    local err = readErrors > 0 and "有槽位读取失败" or nil
    if snapshot.truncated == true then
        readErrors = readErrors + 1
        err = "容器容量超过安全扫描上限，已安全拒绝"
    end
    return Copy(snapshot.identitySet or {}), rows, readErrors, err, Copy(snapshot.identityCount or {}), snapshot.bagId, snapshot
end

-- MoveToEmpty* can compact/reproject slots.  The plan therefore keeps only
-- stable identity/category intent plus a scan hint.  InventorySnapshotV3 checks
-- the hinted slot first and wraps through the bounded container only when the
-- hint is stale; slot numbers never become persistent identity.
function BagMoveRuntime.FindLiveMoveSource(feature, sourceScope, blacklistScope, identity, category, bagId, startSlot, blockedIdentities, alternateSlot)
    local inventory = S.Services and S.Services.InventorySnapshotV3 or nil
    if type(inventory) ~= "table" or type(inventory.FindLiveRow) ~= "function" then
        return nil, nil, "InventorySnapshotV3 unavailable"
    end
    local row, _, err = inventory:FindLiveRow(sourceScope, function(candidate)
        if type(blockedIdentities) == "table" and candidate.identity ~= nil and blockedIdentities[candidate.identity] == true then return false end
        local identityMatch = identity ~= nil and candidate.identity == identity or identity == nil and candidate.category == category
        if identityMatch ~= true then return false end
        local allowed = CheckBlacklist(feature, blacklistScope, candidate)
        return allowed == true
    end, { bagId = bagId, startSlot = startSlot, alternateSlot = alternateSlot, maxSlots = BAG_SCAN_LIMIT })
    if type(row) ~= "table" then return nil, nil, err end
    return row.slot, row, nil
end

-- A false return from an existing native MoveToEmpty* method is a per-item
-- rejection (most commonly: no empty slot and the destination stack for this
-- identity cannot accept more). Missing capability/API errors remain fatal.
function BagMoveRuntime.IsNativeMoveRejected(err)
    return type(err) == "string" and string.find(err, " returned false", 1, true) ~= nil
end

function BagMoveRuntime.SkipQuickIdentity(feature, entry, reason)
    if type(entry) ~= "table" then return false end
    local skipped = math.max(1, tonumber(entry.remaining) or 1)
    feature._quickOverlay = type(feature._quickOverlay) == "table" and feature._quickOverlay or {}
    feature._quickOverlay.skipped = (tonumber(feature._quickOverlay.skipped) or 0) + skipped
    entry.remaining = 0
    feature._quickPending = nil
    feature._quickIndex = math.max(tonumber(feature._quickIndex) or 0, tonumber(entry.queueIndex) or 0)
    feature._quickOverlay.error = reason
    PublishBagOverlay(feature, "bag_quick_identity_skipped")
    return true
end

function BagMoveRuntime.BlockBatchIdentity(feature, entry, identity, reason)
    if type(entry) ~= "table" or identity == nil then return false, "无法安全识别被拒绝的物品" end
    local count, countErr = BagMoveRuntime.CountLiveMatches("bag", identity, nil, feature._batchBagId, nil)
    if count == nil then return false, countErr or "被拒绝物品数量不可读" end
    local skipCount = math.min(math.max(1, tonumber(count) or 1), math.max(1, tonumber(entry.remaining) or 1))
    feature._batchBlockedIdentities = type(feature._batchBlockedIdentities) == "table" and feature._batchBlockedIdentities or {}
    feature._batchBlockedIdentities[identity] = true
    entry.remaining = math.max(0, (tonumber(entry.remaining) or 0) - skipCount)
    -- The rejected stacks remain in the bag; do not decrement the actual
    -- category source count. They are excluded only by identity for this run.
    feature.State.batch.skipped = (tonumber(feature.State.batch.skipped) or 0) + skipCount
    feature.State.batch.error = reason
    feature._batchPending = nil
    return true, skipCount
end

function BagMoveRuntime.CountLiveMatches(scope, identity, category, bagId, stopAt)
    local inventory = S.Services and S.Services.InventorySnapshotV3 or nil
    if type(inventory) ~= "table" or type(inventory.CountLive) ~= "function" then
        return nil, "InventorySnapshotV3 unavailable"
    end
    return inventory:CountLive(scope, function(row)
        return (identity ~= nil and row.identity == identity) or (identity == nil and row.category == category)
    end, { bagId = bagId, stopAt = stopAt, maxSlots = BAG_SCAN_LIMIT })
end

function BagMoveRuntime.IssueQuickMove(entry, target, slot)
    if entry.source == "bag" and target == "bank" then return Action("X2Bag:MoveToEmptyBankSlot", BagApi, "MoveToEmptyBankSlot", slot) end
    if entry.source == "bag" then return Action("X2Bag:MoveToEmptyCofferSlot", BagApi, "MoveToEmptyCofferSlot", slot) end
    if entry.source == "bank" then return Action("X2Bank:MoveToEmptyBagSlot", BankApi, "MoveToEmptyBagSlot", slot) end
    return Action("X2Coffer:MoveToEmptyBagSlot", CofferApi, "MoveToEmptyBagSlot", slot)
end

function BagMoveRuntime.MoveReady(source, target)
    local capability = source == "bag" and (target == "bank" and "X2Bag:MoveToEmptyBankSlot" or "X2Bag:MoveToEmptyCofferSlot")
        or (source == "bank" and "X2Bank:MoveToEmptyBagSlot" or "X2Coffer:MoveToEmptyBagSlot")
    if S.Api ~= nil and type(S.Api.GetCapabilityCooldownState) == "function" then
        local cooldown = S.Api:GetCapabilityCooldownState(capability)
        if type(cooldown) == "table" and (tonumber(cooldown.remainingMs) or 0) > 0 then return false end
    end
    return true
end

local function BeginBagQuick(feature, direction)
    if BagBatchRunning(feature) then return false, "高级整理正在运行，请先停止批量" end
    -- Last-resort guard: StartBagQuick resolves a live run by stop/switch before
    -- reaching here, so hitting this means a caller bypassed the action path.
    if BagQuickRunning(feature) then return false, "快捷取放正在运行，再点一次「取」或「放」可停止" end
    local storage = CurrentStorageContext()
    if type(storage) ~= "table" then return false, "请先打开银行或箱子（窗口刚打开时请稍后再试）" end

    -- Action Authority is the open storage session plus the physical container
    -- reads below, not UIC_BAG's presentation visibility bit. RU can show the
    -- physical bag beside a coffer while UIC_BAG still reports hidden/proxy; in
    -- that state the old preflight rejected a perfectly readable bag before the
    -- bounded InventorySnapshot had a chance to prove it. If either container
    -- is unreadable, BagIdentitySet still fails closed before any native write.
    local target = storage.kind
    local planLimit = direction == "deposit_all" and BAG_SCAN_LIMIT or BAG_QUICK_LIMIT
    local bagSet, bagRows, bagErrors, bagErr, bagCounts, bagId = BagIdentitySet("bag")
    local storageSet, storageRows, storageErrors, storageErr, storageCounts = BagIdentitySet(target)
    if bagSet == nil or storageSet == nil then return false, bagErr or storageErr or "容器读取失败" end
    if bagErrors > 0 or storageErrors > 0 then return false, bagErr or storageErr or "物品槽位存在读取失败，已安全拒绝取放" end

    -- One-click transfer plan v7: group by stable identity instead of storing one
    -- queue record per physical slot.  The `remaining` count is the business
    -- intent; `slotHint` is only an optimization and is revalidated before every
    -- write.  This survives slot compaction and avoids a large duplicate queue.
    local queue, queueByIdentity, sourceCounts, plannedMoves = {}, {}, nil, 0
    local function AddIntent(row, source, dest)
        if plannedMoves >= planLimit or type(row) ~= "table" or row.identity == nil then return end
        local allowed = CheckBlacklist(feature, target, row.info)
        if allowed ~= true then return end
        local index = queueByIdentity[row.identity]
        local entry = index ~= nil and queue[index] or nil
        if entry == nil then
            entry = {
                identity = row.identity, identityMode = row.identityMode, itemType = row.itemType,
                source = source, dest = dest, remaining = 0, slotHint = row.slot,
            }
            queue[#queue + 1] = entry
            queueByIdentity[row.identity] = #queue
        end
        entry.remaining = (tonumber(entry.remaining) or 0) + 1
        plannedMoves = plannedMoves + 1
    end

    if direction == "withdraw" then
        sourceCounts = storageCounts or {}
        for _, row in ipairs(storageRows) do
            if row.identity ~= nil and bagSet[row.identity] == true then AddIntent(row, target, "bag") end
            if plannedMoves >= BAG_QUICK_LIMIT then break end
        end
    elseif direction == "deposit" or direction == "deposit_all" then
        sourceCounts = bagCounts or {}
        for _, row in ipairs(bagRows) do
            if row.identity ~= nil and (direction == "deposit_all" or storageSet[row.identity] == true) then AddIntent(row, "bag", target) end
            if plannedMoves >= planLimit then break end
        end
    else
        return false, "未知快捷动作"
    end

    feature._quickOverlay = type(feature._quickOverlay) == "table" and feature._quickOverlay or {}
    feature._quickOverlay.error = nil
    feature._quickOverlay.queued = plannedMoves
    feature._quickOverlay.moved = 0
    feature._quickOverlay.skipped = 0
    if plannedMoves <= 0 then
        -- Empty plan == no business work == no mutex.  Installing the empty queue
        -- table here (the old behaviour) locked 取/放/direct-move/category-batch for
        -- the rest of the session while the click reported success.
        feature._quickQueue, feature._quickIndex, feature._quickPending = nil, nil, nil
        feature._quickSourceCounts, feature._quickBagId = nil, nil
        feature._quickDirection, feature._quickLastStepAt = nil, nil
        feature._quickOverlay.status = direction == "deposit_all" and "没有可存物品" or "没有同类物品"
        feature._quickOverlay.statusAt = type(S.NowMs) == "function" and tonumber(S.NowMs()) or 0
        feature._quickOverlay.error = direction == "deposit_all" and "背包中没有可识别且未被黑名单排除的物品"
            or "背包与" .. (target == "coffer" and "箱子" or "银行")
            .. "没有共同的同类物品；快捷取放只移动两边都存在的同类，整类收纳请用下方「高级整理」"
        PublishBagOverlay(feature, "bag_quick_empty_plan")
        return true, 0
    end
    feature._quickOverlay.status = direction == "withdraw" and "正在取出" or "正在放入"
    feature._quickOverlay.statusAt = type(S.NowMs) == "function" and tonumber(S.NowMs()) or 0
    feature._quickQueue, feature._quickIndex, feature._quickPending = queue, 0, nil
    feature._quickSourceCounts = Copy(sourceCounts)
    feature._quickBagId = bagId
    feature._quickDirection = direction
    feature._quickSlotHint = nil
    feature._quickLastStepAt = type(S.NowMs) == "function" and tonumber(S.NowMs()) or 0
    -- 单次会话的有界证据，只进入完整诊断；不存档、不新增后台采样。
    feature._quickPerformance = { startedAt = feature._quickLastStepAt, intervalMs = BAG_MOVE_INTERVAL_MS,
        actionAttempts = 0, verificationScans = 0, retries = 0 }
    PublishBagOverlay(feature, "bag_quick_start")
    if S.Scheduler == nil or type(S.Scheduler.AddTask) ~= "function" then
        StopBagQuick(feature, "已停止", "调度器不可用")
        return false, "调度器不可用"
    end

    S.Scheduler:RemoveTask(BAG_QUICK_MOVE_TASK)
    local added = S.Scheduler:AddTask(BAG_QUICK_MOVE_TASK, BAG_MOVE_INTERVAL_MS, function()
        feature._quickLastStepAt = type(S.NowMs) == "function" and tonumber(S.NowMs()) or 0
        local current = CurrentStorageContext()
        if type(current) ~= "table" or current.kind ~= target then
            StopBagQuick(feature, "已停止", "仓库/箱子已关闭或切换")
            return
        end

        local pending = feature._quickPending
        if pending ~= nil then
            local ok, info, readErr = BagMoveRuntime.ReadScopeSlot(pending.source, pending.slot, pending.bagId)
            if ok ~= true then
                StopBagQuick(feature, "已停止", "移动后源槽读取失败：" .. tostring(readErr or "unknown"))
                return
            end
            local afterIdentity = StableItemIdentity(info)
            local moved = type(info) ~= "table" or next(info) == nil or afterIdentity ~= pending.identity
            if moved ~= true then
                -- Ambiguous same-slot/same-item state occurs when RU compacts a
                -- later identical stack into the just-vacated slot. Count only
                -- in this ambiguous branch and stop as soon as the old count is
                -- reached in the no-progress case.
                local liveCount, countErr = BagMoveRuntime.CountLiveMatches(
                    pending.source, pending.identity, nil, pending.bagId, pending.beforeCount)
                feature._quickPerformance.verificationScans = feature._quickPerformance.verificationScans + 1
                if liveCount == nil then
                    StopBagQuick(feature, "已停止", countErr or "移动结果无法确认")
                    return
                end
                moved = liveCount < (tonumber(pending.beforeCount) or 0)
            end
            if moved ~= true then
                -- 200ms 动作节奏不缩短旧的未生效确认窗口；冷却等待不是失败。
                local now = type(S.NowMs) == "function" and tonumber(S.NowMs()) or 0
                if now < (tonumber(pending.verifyAt) or 0) or BagMoveRuntime.MoveReady(pending.source, target) ~= true then return end
                local retries = tonumber(pending.retries) or 0
                if retries < 2 then
                    feature._quickPerformance.actionAttempts = feature._quickPerformance.actionAttempts + 1
                    feature._quickPerformance.retries = feature._quickPerformance.retries + 1
                    local retryOk, retryErr = BagMoveRuntime.IssueQuickMove({ source = pending.source }, target, pending.slot)
                    if retryOk ~= true then
                        local group = type(feature._quickQueue) == "table" and feature._quickQueue[pending.queueIndex] or nil
                        if group ~= nil then
                            group.queueIndex = pending.queueIndex
                            if BagMoveRuntime.IsNativeMoveRejected(retryErr) then
                                BagMoveRuntime.SkipQuickIdentity(feature, group, "该类物品当前无法放入目标容器，已跳过并继续后续物品")
                            else
                                BagMoveRuntime.SkipQuickIdentity(feature, group, "移动重试异常，已跳过该类物品并继续：" .. tostring(retryErr or "unknown"))
                            end
                            return
                        end
                        StopBagQuick(feature, "已停止", "移动重试失败：" .. tostring(retryErr or "unknown"))
                        return
                    end
                    pending.retries = retries + 1
                    pending.verifyAt = now + BAG_VERIFY_GRACE_MS
                    PublishBagOverlay(feature, "bag_quick_retry")
                    return
                end
                local group = type(feature._quickQueue) == "table" and feature._quickQueue[pending.queueIndex] or nil
                if type(group) ~= "table" then
                    StopBagQuick(feature, "已停止", "移动后源容器数量连续未减少且队列身份丢失")
                    return
                end
                group.queueIndex = pending.queueIndex
                BagMoveRuntime.SkipQuickIdentity(feature, group, "该类物品当前无法继续堆叠，已跳过并继续后续物品")
                return
            end

            local beforeCount = tonumber(pending.beforeCount) or 1
            feature._quickSourceCounts = type(feature._quickSourceCounts) == "table" and feature._quickSourceCounts or {}
            feature._quickSourceCounts[pending.identity] = math.max(0, beforeCount - 1)
            feature._quickOverlay.moved = (tonumber(feature._quickOverlay.moved) or 0) + 1
            local group = type(feature._quickQueue) == "table" and feature._quickQueue[pending.queueIndex] or nil
            if type(group) == "table" then
                group.remaining = math.max(0, (tonumber(group.remaining) or 1) - 1)
                -- After compaction the same physical locator is the best next
                -- hint; if it no longer matches FindLiveRow wraps safely.
                group.slotHint = pending.slot
                if group.remaining <= 0 then feature._quickIndex = pending.queueIndex end
            else
                feature._quickIndex = math.max(feature._quickIndex or 0, pending.queueIndex or 0)
            end
            feature._quickPending = nil
            feature._quickSlotHint = pending.slot
        end

        local entry = feature._quickQueue[feature._quickIndex + 1]
        if entry == nil then StopBagQuick(feature, "已完成", nil); return end
        if (tonumber(entry.remaining) or 0) <= 0 then
            feature._quickIndex = feature._quickIndex + 1
            PublishBagOverlay(feature, "bag_quick_group_complete")
            return
        end

        local sourceBagId = entry.source == "bag" and feature._quickBagId or nil
        if BagMoveRuntime.MoveReady(entry.source, target) ~= true then return end
        local slot, _, sourceErr = BagMoveRuntime.FindLiveMoveSource(
            feature, entry.source, target, entry.identity, nil, sourceBagId, entry.slotHint, nil, feature._quickSlotHint)
        if slot == nil then
            entry.remaining = 0
            feature._quickIndex = feature._quickIndex + 1
            if sourceErr ~= "没有剩余可移动的匹配物品" then
                StopBagQuick(feature, "已停止", sourceErr or "源物品解析失败")
            else
                PublishBagOverlay(feature, "bag_quick_skip")
            end
            return
        end

        local counts = type(feature._quickSourceCounts) == "table" and feature._quickSourceCounts or {}
        local beforeCount = tonumber(counts[entry.identity]) or 0
        if beforeCount < 1 then
            local liveCount, countErr = BagMoveRuntime.CountLiveMatches(entry.source, entry.identity, nil, sourceBagId, nil)
            if liveCount == nil then StopBagQuick(feature, "已停止", countErr or "源数量不可读"); return end
            beforeCount = liveCount
            counts[entry.identity] = liveCount
            feature._quickSourceCounts = counts
        end
        feature._quickPerformance.actionAttempts = feature._quickPerformance.actionAttempts + 1
        local actionOk, actionErr = BagMoveRuntime.IssueQuickMove(entry, target, slot)
        if actionOk ~= true then
            entry.queueIndex = feature._quickIndex + 1
            if BagMoveRuntime.IsNativeMoveRejected(actionErr) then
                BagMoveRuntime.SkipQuickIdentity(feature, entry, "该类物品当前无法放入目标容器，已跳过并继续后续物品")
                return
            end
            -- Uncertain dispatch failure (pcall/capability error text): the
            -- post-write verification of every later step re-reads live state,
            -- so skipping THIS identity is safe. Stopping the whole queue made
            -- one bad call end the entire run.
            BagMoveRuntime.SkipQuickIdentity(feature, entry, "移动调用异常，已跳过该类物品并继续：" .. tostring(actionErr or "unknown"))
            return
        end
        feature._quickPending = {
            slot = slot, identity = entry.identity, identityMode = entry.identityMode, itemType = entry.itemType,
            source = entry.source, beforeCount = beforeCount, retries = 0, bagId = sourceBagId,
            verifyAt = feature._quickLastStepAt + BAG_VERIFY_GRACE_MS,
            queueIndex = feature._quickIndex + 1,
        }
        PublishBagOverlay(feature, "bag_quick_step")
    end, true, feature, "P1")
    if added ~= true then
        StopBagQuick(feature, "已停止", "快捷取放任务创建失败")
        return false, "快捷取放任务创建失败"
    end
    if type(S.Scheduler.SetTaskModule) == "function" then S.Scheduler:SetTaskModule(BAG_QUICK_MOVE_TASK, "tools_bag", true) end
    return true, plannedMoves
end

local function RefreshBagQuickOverlay(feature)
    -- The 100 ms window observer doubles as the quick-run watchdog: no new Tick
    -- and no new scheduler task, and an orphaned mutex can never outlive its
    -- task (see BagMoveRuntime.ReclaimStaleBagQuickRun).
    BagMoveRuntime.ReclaimStaleBagQuickRun(feature)
    local bag, bagAnchor=ReadBagWindowContext()
    -- 仅保存当代 Native 锚点引用，不进入 Projection/Store/诊断序列化。
    feature._quickBagAnchor=bagAnchor
    local bank=ReadStorageWindowContext("bank")
    local coffer=ReadStorageWindowContext("coffer")
    -- Surface visibility is presentation evidence only. Native move Authority
    -- continues to use `visible` via CurrentStorageContext/RequireStorageWindow.
    local storage=type(bank)=="table" and bank.status=="ready" and bank.surfaceVisible==true and bank
        or type(coffer)=="table" and coffer.status=="ready" and coffer.surfaceVisible==true and coffer or nil
    -- Storage windows open together with the physical bag, but RU does not
    -- guarantee that UIC_BAG itself flips to visible: it may remain a hidden
    -- proxy while GetContentMainScriptPosVis still exposes the real bag rect.
    -- For Presentation only, a live storage surface + a validated bag rectangle
    -- is therefore sufficient to place the harmless 取/放 bar. Native move
    -- Authority remains CurrentStorageContext() + bounded physical reads.
    local bagMainScriptAnchor=type(bag)=="table" and tostring(bag.source or ""):sub(1,11)=="main-script"
    local bagAnchorReady=bagMainScriptAnchor==true and bag.status=="ready"
        and tonumber(bag.x)~=nil and tonumber(bag.y)~=nil
        and (tonumber(bag.width) or 0)>0 and (tonumber(bag.height) or 0)>0
    local storageSessionBagFallback=type(storage)=="table" and bagAnchorReady==true and bag.surfaceVisible~=true
    local bagSurfaceEffectiveVisible=type(bag)=="table" and (bag.surfaceVisible==true or storageSessionBagFallback==true)
    local bagSurfaceEffectiveSource=storageSessionBagFallback==true
        and ("storage-session+"..tostring(bag.source or "bag-geometry"))
        or (bag and bag.surfaceSource or "none")
    local visible=bagSurfaceEffectiveVisible==true and type(storage)=="table"
    local old=feature._quickOverlay or {}
    local nextState=Copy(old)
    nextState.observerRuns=(tonumber(old.observerRuns) or 0)+1
    nextState.lastObserverAt=type(S.NowMs)=="function" and tonumber(S.NowMs()) or 0
    nextState.featureEnabled=feature.enabled==true
    nextState.visible=visible==true; nextState.storageKind=storage and storage.kind or nil
    nextState.bagStatus=bag and bag.status or "unknown"
    nextState.bagVisible=bag and bag.visible==true or false
    nextState.bagSurfaceVisible=bag and bag.surfaceVisible==true or false
    nextState.bagSurfaceEffectiveVisible=bagSurfaceEffectiveVisible==true
    nextState.bagSurfaceFallback=storageSessionBagFallback==true
    nextState.bagVisibilityConflict=bag and bag.visibilityConflict==true or false
    nextState.bagSource=bag and bag.source or "none"
    nextState.bagSurfaceSource=bag and bag.surfaceSource or "none"
    nextState.bagSurfaceEffectiveSource=bagSurfaceEffectiveSource
    nextState.bagReason=bag and bag.reason or nil
    nextState.bagRect=bag and { x=bag.x, y=bag.y, width=bag.width, height=bag.height } or nil
    nextState.bagGeometrySource=bag and bag.geometrySource or nil
    nextState.bagGeometry=bag and Copy(bag.geometry) or nil
    nextState.bagMainScriptRect=bag and Copy(bag.mainScriptRect) or nil
    nextState.bankStatus=bank and bank.status or "unknown"
    nextState.bankVisible=bank and bank.visible==true or false
    nextState.bankSurfaceVisible=bank and bank.surfaceVisible==true or false
    nextState.bankVisibilityConflict=bank and bank.visibilityConflict==true or false
    nextState.bankSource=bank and bank.source or "none"
    nextState.bankSurfaceSource=bank and bank.surfaceSource or "none"
    nextState.bankReason=bank and bank.reason or nil
    nextState.cofferStatus=coffer and coffer.status or "unknown"
    nextState.cofferVisible=coffer and coffer.visible==true or false
    nextState.cofferSurfaceVisible=coffer and coffer.surfaceVisible==true or false
    nextState.cofferVisibilityConflict=coffer and coffer.visibilityConflict==true or false
    nextState.cofferSource=coffer and coffer.source or "none"
    nextState.cofferSurfaceSource=coffer and coffer.surfaceSource or "none"
    nextState.cofferReason=coffer and coffer.reason or nil
    if visible then
        nextState.x=bag.x; nextState.y=bag.y; nextState.width=math.max(240,math.min(300,tonumber(bag.width) or 240)); nextState.height=32
        if nextState.status==nil or nextState.status=="等待仓库/箱子" then nextState.status="可快捷取放" end
    elseif nextState.status~="正在取出" and nextState.status~="正在放入" then nextState.status="等待仓库/箱子" end
    local changed = old.visible~=nextState.visible or old.storageKind~=nextState.storageKind or old.x~=nextState.x or old.y~=nextState.y or old.width~=nextState.width
        or old.bagStatus~=nextState.bagStatus or old.bagVisible~=nextState.bagVisible or old.bagSurfaceVisible~=nextState.bagSurfaceVisible or old.bagSurfaceEffectiveVisible~=nextState.bagSurfaceEffectiveVisible or old.bagSurfaceFallback~=nextState.bagSurfaceFallback or old.bagVisibilityConflict~=nextState.bagVisibilityConflict or old.bagSource~=nextState.bagSource or old.bagSurfaceSource~=nextState.bagSurfaceSource or old.bagSurfaceEffectiveSource~=nextState.bagSurfaceEffectiveSource or old.bagReason~=nextState.bagReason
        or old.bankStatus~=nextState.bankStatus or old.bankVisible~=nextState.bankVisible or old.bankSurfaceVisible~=nextState.bankSurfaceVisible or old.bankVisibilityConflict~=nextState.bankVisibilityConflict or old.bankSource~=nextState.bankSource or old.bankSurfaceSource~=nextState.bankSurfaceSource or old.bankReason~=nextState.bankReason
        or old.cofferStatus~=nextState.cofferStatus or old.cofferVisible~=nextState.cofferVisible or old.cofferSurfaceVisible~=nextState.cofferSurfaceVisible or old.cofferVisibilityConflict~=nextState.cofferVisibilityConflict or old.cofferSource~=nextState.cofferSource or old.cofferSurfaceSource~=nextState.cofferSurfaceSource or old.cofferReason~=nextState.cofferReason
    feature._quickOverlay=nextState
    -- While the native storage surface is visible, emit a low-rate heartbeat
    -- even when geometry is unchanged. Presentation creation is a different
    -- failure domain from native-window observation; if the first WINDOW build
    -- is transiently rejected, the next 100 ms observation must get a chance to
    -- retry instead of waiting for the user to close/reopen the warehouse.
    if changed or visible==true then PublishBagOverlay(feature,changed and "bag_quick_window" or "bag_quick_visible_heartbeat") end
    return true
end

-- 取/放/全放共用动作契约：空闲点击开始，同动作再点停止，其他动作切换。
-- 设置入口只打开独立设置菜单，不改变正在运行的搬运方向。
local function StartBagQuick(feature, direction)
    if direction ~= "withdraw" and direction ~= "deposit" and direction ~= "deposit_all" then return false,"未知快捷动作" end
    BagMoveRuntime.ReclaimStaleBagQuickRun(feature)
    if BagBatchRunning(feature) then return false,"高级整理正在运行，请先停止批量" end
    local switchNote = nil
    if BagQuickRunning(feature) then
        local running = tostring(feature._quickDirection or "")
        local overlay = type(feature._quickOverlay) == "table" and feature._quickOverlay or {}
        local moved = tonumber(overlay.moved) or 0
        local labels = BagMoveRuntime.QuickDirectionLabel
        local runningLabel = labels[running] or "取放"
        local wantedLabel = labels[direction] or direction
        if running == direction then
            StopBagQuick(feature, "已停止", "已停止" .. runningLabel .. "（本轮已移动 " .. tostring(moved) .. " 个）")
            return true, moved
        end
        StopBagQuick(feature, "已停止", "已停止" .. runningLabel .. "，改为" .. wantedLabel)
        switchNote = "已切换为" .. wantedLabel .. "（上一次" .. runningLabel .. "移动 " .. tostring(moved) .. " 个）"
    end
    local ok, err = BeginBagQuick(feature, direction)
    if ok ~= true then
        -- Same visibility contract as BatchMove: overlay/status text must show
        -- why the quick action refused to start instead of failing silently.
        -- `status` stays short enough for the floating bar; the full reason lives
        -- in `error` for the page status line and diagnostics.
        feature._quickOverlay = type(feature._quickOverlay) == "table" and feature._quickOverlay or {}
        feature._quickOverlay.status = BagMoveRuntime.QuickStatusText(err)
        feature._quickOverlay.statusAt = type(S.NowMs) == "function" and tonumber(S.NowMs()) or 0
        feature._quickOverlay.error = tostring(err or "失败")
        if type(PublishBagOverlay) == "function" then PublishBagOverlay(feature, "bag_quick_preflight_stop") end
    elseif switchNote ~= nil then
        feature._quickOverlay.error = switchNote
        PublishBagOverlay(feature, "bag_quick_switched")
    end
    return ok, err
end

local function StartBagQuickObserver(feature)
    feature._quickOverlay=feature._quickOverlay or { visible=false,status="等待仓库/箱子",moved=0,skipped=0,queued=0 }
    RefreshBagQuickOverlay(feature)
    if S.Scheduler==nil or type(S.Scheduler.AddTask)~="function" then return false,"背包窗口观察调度器不可用" end
    S.Scheduler:RemoveTask(BAG_QUICK_OBSERVE_TASK)
    local added=S.Scheduler:AddTask(BAG_QUICK_OBSERVE_TASK,BagMoveRuntime.QuickObserverIntervalMs,function() return RefreshBagQuickOverlay(feature) end,false,feature,"P2",1)
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
    if target ~= "bank" and target ~= "coffer" then return false, "目标仓储必须是银行或箱子" end
    local windowOk, windowErr = RequireStorageWindow(target)
    if windowOk ~= true then return false, windowErr end

    local inventory = S.Services and S.Services.InventorySnapshotV3 or nil
    if type(inventory) ~= "table" or type(inventory.BuildSnapshot) ~= "function" then
        return false, "InventorySnapshotV3 unavailable"
    end
    local targetSnapshot, targetErr = inventory:BuildSnapshot(target, { maxSlots = BAG_SCAN_LIMIT })
    if type(targetSnapshot) ~= "table" then return false, targetErr or "目标仓储读取失败" end
    if targetSnapshot.truncated == true or (tonumber(targetSnapshot.readErrors) or 0) > 0 then
        return false, "目标空槽语义不可完整验证，已安全停止"
    end
    -- A full container can still accept items into existing partial stacks.
    -- Capacity is therefore not a valid global preflight rejection. Each
    -- identity is attempted independently and a rejected identity is skipped.

    local bagSnapshot, bagErr = inventory:BuildSnapshot("bag", { maxSlots = BAG_SCAN_LIMIT })
    if type(bagSnapshot) ~= "table" then return false, bagErr or "背包快照读取失败" end
    if bagSnapshot.truncated == true or (tonumber(bagSnapshot.readErrors) or 0) > 0 then
        return false, "背包槽位存在读取失败或被截断，无法建立安全批量计划"
    end

    local queueLimit = requestedLimit
    local skipped, plannedMoves, firstSlot = 0, 0, nil
    local sourceCategoryCount = tonumber((bagSnapshot.categoryCount or {})[category]) or 0
    for _, row in ipairs(bagSnapshot.rows or {}) do
        if row.category == nil then
            skipped = skipped + 1
        elseif row.category == category then
            local allowed = CheckBlacklist(feature, target, row)
            if allowed == true and plannedMoves < queueLimit then
                plannedMoves = plannedMoves + 1
                firstSlot = firstSlot or row.slot
            elseif allowed ~= true then
                skipped = skipped + 1
            end
        end
    end

    local queue = plannedMoves > 0 and { { category = category, remaining = plannedMoves, slotHint = firstSlot or 1 } } or {}
    feature.State.batch = {
        status = plannedMoves == 0 and "empty" or "running",
        moved = 0, skipped = skipped, queued = plannedMoves, error = nil,
        performance = { startedAt = type(S.NowMs) == "function" and tonumber(S.NowMs()) or 0,
            intervalMs = BAG_MOVE_INTERVAL_MS, actionAttempts = 0, verificationScans = 0, baselineScans = 0, retries = 0 },
    }
    feature._batchQueue, feature._batchIndex, feature._batchTarget, feature._batchPending = queue, 0, target, nil
    feature._batchSourceCount = sourceCategoryCount
    feature._batchBagId = bagSnapshot.bagId
    feature._batchBlockedIdentities = {}
    if plannedMoves == 0 then return true, 0 end
    if S.Scheduler == nil or type(S.Scheduler.AddTask) ~= "function" then
        StopBagBatch(feature, "stopped", "批量队列调度器不可用，安全拒绝")
        return false, "批量队列调度器不可用，安全拒绝"
    end

    S.Scheduler:RemoveTask(BAG_BATCH_TASK)
    local taskAdded = S.Scheduler:AddTask(BAG_BATCH_TASK, BAG_MOVE_INTERVAL_MS, function()
        if feature.State.batch.status ~= "running" then S.Scheduler:RemoveTask(BAG_BATCH_TASK); return end
        local schedulerWindowOk, schedulerWindowErr = RequireStorageWindow(feature._batchTarget)
        if schedulerWindowOk ~= true then
            StopBagBatch(feature, "stopped", schedulerWindowErr or "仓储窗口已关闭或目标改变")
            feature.Authority:Refresh("batch_window_stop")
            return
        end

        local pending = feature._batchPending
        if pending ~= nil then
            local ok, info, readErr = BagMoveRuntime.ReadScopeSlot("bag", pending.slot, pending.bagId)
            if ok ~= true then
                StopBagBatch(feature, "stopped", "移动后源槽读取失败：" .. tostring(readErr or "unknown read error"))
                feature.Authority:Refresh("batch_verify_read_stop")
                return
            end
            local afterIdentity = StableItemIdentity(info)
            local moved = IsEmptyBagInfo(info) or afterIdentity ~= pending.identity
            if moved ~= true then
                local liveCount, countErr = BagMoveRuntime.CountLiveMatches(
                    "bag", pending.identity, nil, pending.bagId, pending.beforeCount)
                feature.State.batch.performance.verificationScans = feature.State.batch.performance.verificationScans + 1
                if liveCount == nil then
                    StopBagBatch(feature, "stopped", countErr or "移动结果无法确认")
                    feature.Authority:Refresh("batch_verify_count_stop")
                    return
                end
                moved = liveCount < (tonumber(pending.beforeCount) or 0)
            end
            if moved ~= true then
                local now = type(S.NowMs) == "function" and tonumber(S.NowMs()) or 0
                if now < (tonumber(pending.verifyAt) or 0) or BagMoveRuntime.MoveReady("bag", target) ~= true then return end
                local retries = tonumber(pending.retries) or 0
                if retries < 2 then
                    feature.State.batch.performance.actionAttempts = feature.State.batch.performance.actionAttempts + 1
                    feature.State.batch.performance.retries = feature.State.batch.performance.retries + 1
                    local capability = target == "bank" and "X2Bag:MoveToEmptyBankSlot" or "X2Bag:MoveToEmptyCofferSlot"
                    local retryOk, retryErr = Action(capability, BagApi, target == "bank" and "MoveToEmptyBankSlot" or "MoveToEmptyCofferSlot", pending.slot)
                    if retryOk ~= true then
                        if BagMoveRuntime.IsNativeMoveRejected(retryErr) then
                            local group = type(feature._batchQueue) == "table" and feature._batchQueue[pending.queueIndex] or nil
                            local skippedOk, skippedErr = BagMoveRuntime.BlockBatchIdentity(feature, group, pending.identity, "该类物品目标堆已满，已跳过并继续")
                            if skippedOk == true then feature.Authority:Refresh("batch_identity_skipped"); return end
                            StopBagBatch(feature, "stopped", skippedErr or "无法安全跳过被拒绝物品")
                            feature.Authority:Refresh("batch_retry_skip_failed")
                            return
                        end
                        StopBagBatch(feature, "stopped", "移动重试失败：" .. tostring(retryErr or "unknown"))
                        feature.Authority:Refresh("batch_retry_failed")
                        return
                    end
                    pending.retries = retries + 1
                    pending.verifyAt = now + BAG_VERIFY_GRACE_MS
                    PublishBagOverlay(feature, "batch_retry")
                    return
                end
                local group = type(feature._batchQueue) == "table" and feature._batchQueue[pending.queueIndex] or nil
                local skippedOk, skippedErr = BagMoveRuntime.BlockBatchIdentity(feature, group, pending.identity, "该类物品当前无法继续堆叠，已跳过并继续")
                if skippedOk == true then feature.Authority:Refresh("batch_verify_identity_skipped"); return end
                StopBagBatch(feature, "stopped", skippedErr or "移动后源类别数量连续未减少，且无法安全跳过")
                feature.Authority:Refresh("batch_verify_stop")
                return
            end

            local beforeCount = tonumber(pending.beforeCount) or 1
            feature._batchSourceCount = math.max(0, beforeCount - 1)
            feature.State.batch.moved = (tonumber(feature.State.batch.moved) or 0) + 1
            local group = type(feature._batchQueue) == "table" and feature._batchQueue[pending.queueIndex] or nil
            if type(group) == "table" then
                group.remaining = math.max(0, (tonumber(group.remaining) or 1) - 1)
                group.slotHint = pending.slot
                if group.remaining <= 0 then feature._batchIndex = pending.queueIndex end
            else
                feature._batchIndex = math.max(feature._batchIndex or 0, pending.queueIndex or 0)
            end
            feature._batchPending = nil
        end

        local entry = feature._batchQueue[feature._batchIndex + 1]
        if entry == nil then
            StopBagBatch(feature, "complete", nil)
            feature.Authority:Refresh("batch_complete")
            return
        end
        if (tonumber(entry.remaining) or 0) <= 0 then
            feature._batchIndex = feature._batchIndex + 1
            PublishBagOverlay(feature, "batch_group_complete")
            return
        end

        if BagMoveRuntime.MoveReady("bag", target) ~= true then return end
        local slot, sourceRow, sourceErr = BagMoveRuntime.FindLiveMoveSource(
            feature, "bag", target, nil, category, feature._batchBagId, entry.slotHint, feature._batchBlockedIdentities)
        if slot == nil then
            entry.remaining = 0
            feature._batchIndex = feature._batchIndex + 1
            if sourceErr ~= "没有剩余可移动的匹配物品" then
                StopBagBatch(feature, "stopped", sourceErr or "源物品解析失败")
                feature.Authority:Refresh("batch_source_stop")
            else
                feature.State.batch.skipped = (tonumber(feature.State.batch.skipped) or 0) + 1
                feature.Authority:Refresh("batch_skip")
            end
            return
        end

        local sourceIdentity = sourceRow and sourceRow.identity or nil
        if sourceIdentity == nil then
            StopBagBatch(feature, "stopped", "源物品缺少稳定身份，无法安全验证批量移动")
            feature.Authority:Refresh("batch_identity_missing_stop")
            return
        end
        local beforeCount, countErr = BagMoveRuntime.CountLiveMatches("bag", sourceIdentity, nil, feature._batchBagId, nil)
        feature.State.batch.performance.baselineScans = feature.State.batch.performance.baselineScans + 1
        if beforeCount == nil then
            StopBagBatch(feature, "stopped", countErr or "源物品数量不可读")
            feature.Authority:Refresh("batch_count_stop")
            return
        end
        local capability = target == "bank" and "X2Bag:MoveToEmptyBankSlot" or "X2Bag:MoveToEmptyCofferSlot"
        feature.State.batch.performance.actionAttempts = feature.State.batch.performance.actionAttempts + 1
        local actionOk, actionErr = Action(capability, BagApi, target == "bank" and "MoveToEmptyBankSlot" or "MoveToEmptyCofferSlot", slot)
        if actionOk ~= true then
            local skipReason = BagMoveRuntime.IsNativeMoveRejected(actionErr)
                and "该类物品目标堆已满，已跳过并继续"
                or "移动调用异常，已跳过该类物品并继续：" .. tostring(actionErr or "unknown")
            local skippedOk, skippedErr = BagMoveRuntime.BlockBatchIdentity(feature, entry, sourceRow and sourceRow.identity or nil, skipReason)
            if skippedOk == true then feature.Authority:Refresh("batch_action_identity_skipped"); return end
            StopBagBatch(feature, "stopped", skippedErr or "无法安全跳过被拒绝物品")
            feature.Authority:Refresh("batch_action_skip_failed")
            return
        end
        feature._batchPending = {
            slot = slot, identity = sourceIdentity, category = category, beforeCount = beforeCount, retries = 0,
            verifyAt = (type(S.NowMs) == "function" and tonumber(S.NowMs()) or 0) + BAG_VERIFY_GRACE_MS,
            bagId = feature._batchBagId, queueIndex = feature._batchIndex + 1,
        }
        -- 进度是 State.batch 的临时事实。每拍只发布进度，结束/停止仍完整
        -- 刷新背包读模型；避免为每次进度显示再扫描所有槽位。
        PublishBagOverlay(feature, "batch_step")
    end, true, feature, "P1")
    if taskAdded ~= true then
        StopBagBatch(feature, "stopped", "批量队列任务创建失败，已清理运行态")
        return false, "批量队列任务创建失败，安全拒绝"
    end
    if type(S.Scheduler.SetTaskModule) == "function" then
        local transient = true
        S.Scheduler:SetTaskModule(BAG_BATCH_TASK, "tools_bag", transient)
    end
    return true, plannedMoves
end

-- `target == nil` means "use whatever storage window is actually open"; the page
-- entry point relies on that, while the explicit DepositCategoryBank/Coffer
-- commands stay for callers that really do know which one they mean.
local function BatchMove(feature, target, category, requestedLimit)
    BagMoveRuntime.ReclaimStaleBagQuickRun(feature)
    if BagQuickRunning(feature) then return false, "快捷取放正在运行，再点一次「取」或「放」可停止" end
    if BagBatchRunning(feature) then return false, "类别批量整理已经在运行，请先停止" end
    if target == nil then
        local resolved, resolveErr = BagMoveRuntime.ResolveBatchTarget()
        if resolved == nil then
            -- A refused batch must be visible in the status line, exactly like the
            -- other preflight rejections (CURRENT_REBUILD_STATUS §9.3 lesson).
            feature.State.batch = { status = "stopped", moved = 0, skipped = 0, queued = 0, error = resolveErr }
            if type(feature.Authority) == "table" and type(feature.Authority.Refresh) == "function" then
                feature.Authority:Refresh("batch_target_unresolved")
            end
            return false, resolveErr
        end
        target = resolved
    end
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

-- 中文维护注释（2026-09-28，Phase 1 Batch A）：PersistStateMutation 的实现已移到
-- features/shared/rs_feature_slice_factory.lua，本文件用顶部别名调用，不再在此重复定义。

-- 中文维护注释（2026-09-28，Phase 1 Batch A）：白名单快照逻辑已由工厂提供，别名保持调用点不变。
local PersistentState = FSF.PersistentState

-- 中文维护注释（2026-09-28，Phase 1 Batch A / FND-001）：Feature 装配骨架已由工厂拥有。
-- 这里只保留别名，本文件剩余 Feature 的注册路径、Store/Authority/Demand 顺序逐字不变。
local NewFeature = FSF.NewFeature

-- 中文维护注释（2026-09-28，Phase 1 Batch C）：combat_boss_alerts 已机械搬迁到 features/combat/boss_alerts/rs_boss_alerts_feature.lua；
-- toc.g 只登记一次，禁止在此重新注册（它的私有 helper 与 task 名都随文件搬走）。

-- 中文维护注释（2026-09-28，Phase 1 Batch C）：combat_target_monitor 已机械搬迁到 features/combat/target_monitor/rs_target_monitor_feature.lua；
-- toc.g 只登记一次，禁止在此重新注册（它的私有 helper 与 task 名都随文件搬走）。
-- 中文维护注释（2026-09-28，Phase 1 Batch C）：combat_buff_cap 已机械搬迁到 features/combat/buff_cap/rs_buff_cap_feature.lua；
-- toc.g 只登记一次，禁止在此重新注册（它的私有 helper 与 task 名都随文件搬走）。
-- 中文维护注释（2026-09-28，Phase 1 Batch D）：combat_team_tools 已机械搬迁到 features/combat/team_tools/rs_team_tools_feature.lua；
-- toc.g 只登记一次，禁止在此重新注册。
-- 中文维护注释（2026-09-28，Phase 1 Batch C）：combat_raid_recruitment 已机械搬迁到 features/combat/raid_recruitment/rs_raid_recruitment_feature.lua；
-- toc.g 只登记一次，禁止在此重新注册（它的私有 helper 与 task 名都随文件搬走）。

-- 中文维护注释（2026-09-28，Phase 1 Batch D）：tools_craft 已机械搬迁到 features/tools/craft/rs_craft_feature.lua；
-- toc.g 只登记一次，禁止在此重新注册。

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
    "ADDON:GetContent", "ADDON:GetContentMainScriptPosVis",
}, persistenceBudget = { maxDepth = 5, maxNodes = 768, maxStringBytes = 16384, maxEntriesPerTable = 96 },
state = { blacklist = BlacklistDefault(), batchCategory = nil, batchTarget = "bank", batchLimit = BATCH_DEFAULT_LIMIT }, default = { blacklist = BlacklistDefault(), batchCategory = nil, batchTarget = "bank", batchLimit = BATCH_DEFAULT_LIMIT }, persistentKeys = { "batchCategory" }, apply = ApplyBagState,
onEnable = function(feature) return StartBagQuickObserver(feature) end,
onDisable = function(feature) StopBagBatch(feature, "stopped", "功能关闭，批量任务已释放"); return StopBagQuickAll(feature, "功能关闭，快捷取放已释放") end,
projection = BatchProjection, read = function()
    -- Demand/Refresh is the only entry point for this snapshot.  Reuse the
    -- shared physical-bag Authority so the page and write workflows cannot
    -- disagree on bagId.  InventorySnapshotV3 builds all row indexes in the
    -- same bounded pass and never polls in the background.
    local inventory = S.Services and S.Services.InventorySnapshotV3 or nil
    if type(inventory) ~= "table" or type(inventory.BuildSnapshot) ~= "function" then
        return {
            { key = "bag:scan", name = "背包扫描", text = "共享背包快照服务不可用", statusText = "读取失败", tone = "warn" },
        }, "unavailable", "InventorySnapshotV3 unavailable"
    end
    local snapshot, snapshotErr = inventory:BuildSnapshot("bag", { maxSlots = BAG_SCAN_LIMIT })
    if type(snapshot) ~= "table" then
        return {
            { key = "bag:scan", name = "背包扫描", text = "容量/槽位读取失败", statusText = "读取失败", tone = "warn" },
        }, "unavailable", tostring(snapshotErr or "背包快照不可读")
    end

    local rows = {}
    for _, item in ipairs(snapshot.rows or {}) do
        local categoryText = item.category ~= nil and (BagCategoryLabel(item.category) .. "（" .. tostring(item.category) .. "）") or "类别未知"
        rows[#rows + 1] = {
            key = "bag:" .. tostring(item.slot), name = Text(item.name, "槽位 " .. tostring(item.slot)),
            text = "物品编号：" .. Text(item.itemType, "--") .. " · " .. categoryText,
            statusText = "数量 " .. Text(item.stack, "--"), tone = "default",
            itemType = item.itemType, itemName = Text(item.name, ""), category = item.category, stack = item.stack, slot = item.slot, bagId = snapshot.bagId,
        }
    end

    local capacity = math.max(0, math.floor(tonumber(snapshot.capacity) or 0))
    local scanned = math.max(0, math.floor(tonumber(snapshot.scannedSlots) or 0))
    local readErrors = math.max(0, math.floor(tonumber(snapshot.readErrors) or 0))
    local scanText = "已读槽位 " .. tostring(scanned) .. "/" .. tostring(capacity) .. " · 物理背包视图 " .. tostring(snapshot.bagId or "--")
    if snapshot.fallbackUsed == true then scanText = scanText .. "（兼容回退）" end
    if snapshot.truncated == true then scanText = scanText .. "（上限 " .. tostring(BAG_SCAN_LIMIT) .. "，已截断）" end
    if readErrors > 0 then scanText = scanText .. "；读取失败 " .. tostring(readErrors) .. " 槽" end
    table.insert(rows, 1, {
        key = "bag:scan", name = "背包扫描", text = scanText,
        statusText = snapshot.truncated == true and "已截断" or (readErrors > 0 and "部分失败" or "完整读取"),
        tone = (snapshot.truncated == true or readErrors > 0) and "warn" or "default",
        capacity = capacity, scannedSlots = scanned, readCount = scanned - readErrors,
        readErrors = readErrors, truncated = snapshot.truncated == true, bagId = snapshot.bagId,
    })
    if capacity == 0 then return rows, "empty", nil end
    if readErrors > 0 and #(snapshot.rows or {}) == 0 then return rows, "unavailable", "背包槽位当前不可读" end
    local diagnostic = readErrors > 0 and ("背包有 " .. tostring(readErrors) .. " 个槽位读取失败") or nil
    return rows, "ready", diagnostic
end, commands = {
    SetBlacklistEnabled = SetBlacklistEnabled,
    SetBlacklistScope = SetBlacklistScope,
    AddBlacklistItem = function(feature, scope, value) return AddBlacklistValue(feature, scope, "itemType", value, NormalizeItemType, "bag_blacklist_item_add") end,
    RemoveBlacklistItem = function(feature, scope, value) return RemoveBlacklistValue(feature, scope, "itemType", value, NormalizeItemType, "bag_blacklist_item_remove") end,
    -- Product-facing commands: a blacklist item applies to both storage kinds.
    -- Name lookup is bounded and explicit; itemType remains the enforcement key.
    ResolveAndAddBlacklistItem = function(feature, query) return BagMoveRuntime.ResolveAndAddBlacklistItem(feature, query) end,
    AddGlobalBlacklistItem = function(feature, itemType, itemName) return BagMoveRuntime.AddGlobalBlacklistItem(feature, itemType, itemName) end,
    RemoveGlobalBlacklistItem = function(feature, itemType) return BagMoveRuntime.RemoveGlobalBlacklistItem(feature, itemType) end,
    AddBlacklistCategory = function(feature, scope, value) return AddBlacklistValue(feature, scope, "category", value, NormalizeCategory, "bag_blacklist_category_add") end,
    RemoveBlacklistCategory = function(feature, scope, value) return RemoveBlacklistValue(feature, scope, "category", value, NormalizeCategory, "bag_blacklist_category_remove") end,
    -- The page entry point: target is the open storage window, not a user guess.
    DepositCategoryCurrent = function(feature, category, limit) return BatchMove(feature, nil, category, limit) end,
    DepositCategoryBank = function(feature, category, limit) return BatchMove(feature, "bank", category, limit) end,
    DepositCategoryCoffer = function(feature, category, limit) return BatchMove(feature, "coffer", category, limit) end,
    CancelCategoryBatch = function(feature) return StopBagBatch(feature, "cancelled", "用户取消") end,
    QuickWithdraw = function(feature) return StartBagQuick(feature,"withdraw") end,
    QuickDeposit = function(feature) return StartBagQuick(feature,"deposit") end,
    QuickDepositAll = function(feature) return StartBagQuick(feature,"deposit_all") end,
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
BagTools.BagMoveContractVersion = 8
BagTools.FullStorageContinuationContractVersion = 1
BagTools.BatchLifecycleContractVersion = 5
BagTools.NativeWindowQuickContractVersion = 7
BagTools.ReloadQuickObserverContractVersion = 3
BagTools.ResponsiveWindowObserverContractVersion = 1
BagTools.ProductBlacklistUxContractVersion = 1
BagTools.BlacklistNameMetadataContractVersion = 1
BagTools.BlacklistExplicitLookupContractVersion = 1
BagTools.RUFourValueWindowVisibilityContractVersion = 2
BagTools.NativeVisibilityShapeContractVersion = 1
BagTools.SurfaceVisibilitySplitContractVersion = 1
-- A storage session can expose a real bag rectangle while UIC_BAG remains a
-- hidden proxy; Presentation may use that rectangle, while native move safety
-- is still proven by storage Authority + bounded physical reads.
BagTools.StorageSessionBagSurfaceContractVersion = 1
BagTools.BagActionPhysicalReadAuthorityContractVersion = 1
BagTools.VisiblePresenterRetryContractVersion = 1
BagTools.DynamicSourceResolutionContractVersion = 3
BagTools.QuickIdentityFallbackContractVersion = 1
-- Mutex v2: an empty plan never holds the mutex, and a queue that lost its
-- executor is reclaimed by the observer / next click instead of blocking the
-- whole Feature until reload.
BagTools.BagTaskMutexContractVersion = 2
BagTools.QuickRunSelfHealContractVersion = 1
BagTools.QuickTwoButtonContractVersion = 1
BagTools.AllDepositContractVersion = 1
BagTools.NativeBagAnchorContractVersion = 1
function BagTools:GetQuickBagAnchor()
    if self.enabled == true and type(self._quickOverlay) == "table" and self._quickOverlay.visible == true then return self._quickBagAnchor end
    return nil
end
-- Refusal text is split into a short overlay `status` plus a long diagnostic
-- `error`; a click is never a silent no-op.
BagTools.QuickReasonVisibilityContractVersion = 1
-- Status writes carry their own timestamp so the bar can expire a message
-- instead of wearing it for the rest of the session.
BagTools.QuickStatusTimestampContractVersion = 1
-- Category batch targets the storage window that is actually open; the old
-- bank/coffer toggle is removed from the page (ambiguous: both cannot be open).
BagTools.BatchTargetAutoContractVersion = 1
BagTools.InventorySnapshotContractVersion = 1
BagTools.GroupedIntentQueueContractVersion = 1
-- 模块完整 TXT 收录单次搬运证据；只复制缓存，不为导出再扫描物品。
if type(S.ModuleDiagnosticsHub) == "table" and type(S.ModuleDiagnosticsHub.RegisterProvider) == "function" then
    S.ModuleDiagnosticsHub:RegisterProvider(BagTools.Id, "bag_transfer_runtime", function()
        return { batch = Copy(BagTools.State.batch),
            quickLastRun = Copy(BagTools._quickOverlay and BagTools._quickOverlay.lastRun),
            quickActivePerformance = Copy(BagTools._quickPerformance) }
    end, 50, { detailOnly = true })
end
-- 中文维护注释（2026-09-28，Phase 1 Batch D）：tools_auction 已机械搬迁到 features/tools/auction/rs_auction_feature.lua；
-- toc.g 只登记一次，禁止在此重新注册。
-- 中文维护注释（2026-09-28，Phase 1 Batch A）：tools_market_analysis 已机械搬迁到
-- features/tools/market_analysis/rs_market_analysis_feature.lua（与 tools_auction 共用上面的
-- AuctionReadModel 读模型；Feature ID / Store ID / UpdateTopic / Commands / Projection 全部不变）。
-- 这里不再注册它，禁止在此重新注册一遍。
-- 中文维护注释（2026-09-28，Phase 1 Batch D）：tools_auction 已机械搬迁到 features/tools/auction/rs_auction_feature.lua；
-- toc.g 只登记一次，禁止在此重新注册。

------------------------------------------------------------------------
-- Phase 1 Batch A（2026-09-28）：tools_social 已机械搬迁到
-- features/tools/social/rs_social_feature.lua（Feature ID / Store ID / UpdateTopic /
-- Demand owner / Commands / Projection shape / ApiDependencies 全部不变）。
-- 这里不再定义它的任何 helper 或实现，禁止在此重新注册一遍。
------------------------------------------------------------------------
