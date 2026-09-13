------------------------------------------------------------------------
-- Replicated Suite V3 - Buff Display Pure Projection
-- No Native/API access. Converts AuraObservationV3 StatusMap facts and
-- Feature runtime-lane data into bounded detached rows for Page/Widget
-- consumers.
--
-- Classification contract (schema 6):
--   * category is "buff" | "debuff" | "unknown"; Auto is a tracking bucket
--   * hidden / special_rule are detection sources resolved by the shared
--     StatusClassificationV3 service, never user-facing categories
--   * tracked lookups use a prebuilt O(1) index when provided
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
S.Features = S.Features or {}
S.Features.BuffDisplay = S.Features.BuffDisplay or {}
local F = S.Features.BuffDisplay

local function Classification()
    return S.Services and S.Services.StatusClassificationV3 or nil
end

-- O(1) tracked index: { buff = {[id]=true}, debuff = {[id]=true} }.
-- Falls back to building from settings.tracked when callers pass nothing.
local function BuildTrackedIndex(settings)
    local index = { buff = {}, debuff = {}, auto = {} }
    settings = type(settings) == "table" and settings or {}
    local tracked = type(settings.tracked) == "table" and settings.tracked or {}
    for _, id in ipairs(type(tracked.buff) == "table" and tracked.buff or {}) do
        id = math.floor(tonumber(id) or 0)
        if id > 0 then index.buff[id] = true end
    end
    for _, id in ipairs(type(tracked.debuff) == "table" and tracked.debuff or {}) do
        id = math.floor(tonumber(id) or 0)
        if id > 0 then index.debuff[id] = true end
    end
    -- 中文维护注释：Auto 是追踪选择，不是极性；只在 Native 分类已知后进入对应 HUD。
    for _, id in ipairs(type(tracked.auto) == "table" and tracked.auto or {}) do
        id = math.floor(tonumber(id) or 0); if id > 0 then index.auto[id] = true end
    end
    return index
end

-- Compact time display for head-plate icons and table rows.
--   >= 60s  → M.SS.cc  (e.g. 1.20.10 = 1 min 20 sec 10 cs)
--   <  60s  → S.c      (e.g. 10.0 = 10 sec 0 cs)
--   nil     → "--"
-- Input: timeLeft in milliseconds.
local function FormatCompactTime(ms)
    if ms == nil then return "--" end
    local totalCs = math.max(0, math.floor(ms / 10))  -- centiseconds
    local sec = math.floor(totalCs / 100)
    local cs = totalCs % 100
    if sec >= 60 then
        local min = math.floor(sec / 60)
        sec = sec % 60
        return string.format("%d.%02d.%02d", min, sec, cs)
    end
    return string.format("%d.%d", sec, math.floor(cs / 10))
end

local function SortRows(a, b)
    local at, bt = tonumber(a.timeLeft), tonumber(b.timeLeft)
    if at ~= nil and bt ~= nil and at ~= bt then return at < bt end
    if at ~= nil and bt == nil then return true end
    if at == nil and bt ~= nil then return false end
    return (tonumber(a.id) or 0) < (tonumber(b.id) or 0)
end

-- Convert a StatusMap (AuraObservationV3 facts) into detached display rows.
-- signature: (statusMap, meta, settings, scope, limit, trackedIndex)
function F.ProjectStatusMap(statusMap, meta, settings, scope, limit, trackedIndex)
    statusMap, settings = type(statusMap) == "table" and statusMap or {}, type(settings) == "table" and settings or {}
    trackedIndex = type(trackedIndex) == "table" and trackedIndex or BuildTrackedIndex(settings)
    local classification = Classification()
    local rows, seen = {}, {}
    for id, entry in pairs(statusMap) do
        local kind = classification ~= nil and classification:ClassifyEntry(entry, settings.classification)
            -- 中文维护注释：混合版本/分类服务缺席也必须 fail-closed，不能通过旧 fallback 把 Hidden 变成 Buff。
            or { category = "unknown",
                 detectionSource = entry.sources and entry.sources.hidden == true and "hidden" or "normal" }
        local category = kind.category or "unknown"
        -- Hidden-sourced statuses are an independent fact source: they must never
        -- be suppressed by the buff/debuff category toggles (the page's 只看隐藏
        -- filter owns them), otherwise a hidden effect the player wants to inspect
        -- silently vanishes the moment one category is toggled off.
        local hiddenSource = kind.detectionSource == "hidden"
        local allowed = category == "unknown" or hiddenSource == true
            or (category == "buff" and settings.showBuffs ~= false)
            or (category == "debuff" and settings.showDebuffs ~= false)
        if allowed == true and seen[id] ~= true then
            seen[id] = true
            local timeLeft = tonumber(entry.timeLeft)
            local idNum = math.floor(tonumber(id) or 0)
            local tracked = (trackedIndex[category] ~= nil and trackedIndex[category][idNum] == true)
                or (trackedIndex.auto ~= nil and trackedIndex.auto[idNum] == true)
            rows[#rows + 1] = {
                key = tostring(scope or "unit") .. ":" .. tostring(id), id = idNum,
                name = tostring(entry.name or id), iconPath = tostring(entry.iconPath or ""),
                category = category, detectionSource = kind.detectionSource or "normal",
                confidence = kind.confidence or "unknown", classificationSource = kind.source,
                effectType = category, effectTypeText = category == "debuff" and "Debuff" or (category == "buff" and "Buff" or "待分类"),
                stack = math.max(1, math.floor(tonumber(entry.stack) or 1)), timeLeft = timeLeft,
                timeText = FormatCompactTime(timeLeft),
                sourceMask = tonumber(entry.sourceMask) or 0, timeKnown = timeLeft ~= nil,
                tracked = tracked == true,
                trackedText = tracked == true and "已追踪" or "",
            }
        end
    end
    table.sort(rows, SortRows)
    limit = math.max(1, math.floor(tonumber(limit) or #rows))
    while #rows > limit do rows[#rows] = nil end
    return rows, {
        available = type(meta) == "table" and meta.available == true,
        complete = type(meta) == "table" and meta.complete == true,
        reliable = type(meta) == "table" and meta.reliable == true,
        total = #rows, revision = type(meta) == "table" and tonumber(meta.revision) or 0,
    }
end

------------------------------------------------------------------------
-- Head-plate projection. `laneData` is produced by the Feature runtime lanes:
--   { buffRows, debuffRows, distance, class, gearScore,
--     mainHand={icon,gradeIconPath,name}, offHand, ranged, wings,
--     cast={casting, spellName, currMs, totalMs} }
-- Returns only enabled components; tracked rows are bounded per component.
--
-- show-all semantics: headShowAll is an explicit opt-in. It can show ordinary
-- untracked Buff/Debuff rows, but a Hidden-sourced status NEVER bypasses the
-- explicit tracked whitelist. This keeps "observed Hidden" separate from
-- "displayed Hidden" even when the user enables show-all mode.
------------------------------------------------------------------------
local function BoundedTracked(rows, settings, category, trackedIndex)
    rows = type(rows) == "table" and rows or {}
    trackedIndex = type(trackedIndex) == "table" and trackedIndex or BuildTrackedIndex(settings)
    local component = type(settings.components) == "table" and settings.components[category == "debuff" and "debuffs" or "buffs"] or nil
    component = type(component) == "table" and component or {}
    -- Canonical capacity = the visible component's row geometry. No parallel
    -- headMaxIcons authority: renderer and projection now consume the same data.
    local perRow = math.max(1, math.min(16, math.floor(tonumber(component.maxPerRow) or 8)))
    local maxRows = math.max(1, math.min(4, math.floor(tonumber(component.maxRows) or 2)))
    local maxIcons = math.min(64, perRow * maxRows)
    local out = {}
    local showAll = settings.headShowAll == true
    for _, row in ipairs(rows) do
        local idNum = math.floor(tonumber(row.id) or 0)
        -- 中文维护注释：HUD 白名单同时接受 Auto；lane 分流仍由真实分类决定，不能把 unknown 塞入 Buff。
        local isTracked = (trackedIndex[category] ~= nil and trackedIndex[category][idNum] == true)
            or (trackedIndex.auto ~= nil and trackedIndex.auto[idNum] == true)
        local hiddenSource = row.detectionSource == "hidden"
        if isTracked == true or (showAll == true and hiddenSource ~= true) then
            local copy = {}
            for key, value in pairs(row) do copy[key] = value end
            out[#out + 1] = copy
            if #out >= maxIcons then break end
        end
    end
    return out
end

-- Components are copied so the projection never exposes the live store table;
-- presentation reads a detached snapshot (boundary rule: consumers never own or
-- mutate Authority-owned state through a projection).
local function CopyComponents(components)
    local out = {}
    for key, component in pairs(type(components) == "table" and components or {}) do
        if type(component) == "table" then
            local copy = {}
            for field, value in pairs(component) do copy[field] = value end
            out[key] = copy
        else
            out[key] = component
        end
    end
    return out
end

-- 中文维护（2026-09-13，enemy-loadout-1）：目标装备 API 可能实际返回自己装备，不能用于敌人。
-- 这里的 Authority 仅是本次 Aura 实时事实 -> 中央 ID 类型关系；不读 API、不读留存/追踪列表。
-- 两类各六个固定候选 O(1)；同类兼容 ID 可合并，不同类型同时存在则拒绝推断并保留冲突标志。
-- 图标只用实际 Buff 元数据；缺图标保留类型名，不伪造具体装备/品阶。缓存/存档由上层拥有。
function F.ProjectTargetLoadout(statusMap)
    statusMap = type(statusMap) == "table" and statusMap or {}
    local ids = S.GameIds and S.GameIds.Plates or {}
    local function Resolve(priority, names)
        local selected, conflict
        for _, id in ipairs(priority or {}) do
            local fact = statusMap[id]
            local sources = type(fact) == "table" and fact.sources or nil
            if type(sources) == "table" and (sources.buff == true or sources.hidden == true) then
                local name = names and names[id]
                if name ~= nil then
                    if selected ~= nil and selected.name ~= name then conflict = true end
                    if selected == nil then
                        selected = { name = name, icon = tostring(fact.iconPath or ""), gradeIconPath = "",
                            source = "observed_buff", buffId = id }
                    elseif selected.name == name and selected.icon == "" and type(fact.iconPath) == "string" then
                        selected.icon, selected.buffId = fact.iconPath, id
                    end
                end
            end
        end
        if conflict then return nil, true end
        return selected, false
    end
    local weapon, weaponConflict = Resolve(ids.TargetWeaponPriority, ids.TargetWeaponStyleByBuff)
    local armor, armorConflict = Resolve(ids.TargetArmorPriority, ids.TargetArmorByBuff)
    return { weapon = weapon, armor = armor, weaponConflict = weaponConflict, armorConflict = armorConflict }
end

function F.ProjectPlates(laneData, settings, trackedIndex)
    laneData, settings = type(laneData) == "table" and laneData or {}, type(settings) == "table" and settings or {}
    local components = CopyComponents(settings.components)
    -- 中文维护注释（高频 HUD 投影）：Feature 已维护 O(1) trackedIndex 时直接复用，
    -- 避免 50ms HUD 刷新反复复制/遍历最多 2048 个追踪 ID；纯函数调用仍可省略第三参
    -- 并从 settings.tracked 构建，保持旧 acceptance/调用方兼容。
    trackedIndex = type(trackedIndex) == "table" and trackedIndex or BuildTrackedIndex(settings)
    local out = { components = components, buffs = {}, debuffs = {} }
    out.buffs = BoundedTracked(laneData.buffRows, settings, "buff", trackedIndex)
    out.debuffs = BoundedTracked(laneData.debuffRows, settings, "debuff", trackedIndex)

    local distance = tonumber(laneData.distance)
    if distance ~= nil then
        if distance < 1000 then
            out.distance = { value = string.format("%.1f", distance) .. "m" }
        else
            out.distance = { value = string.format("%.2f", distance / 1000) .. "km" }
        end
    end
    if laneData.class ~= nil then
        local class = type(laneData.class) == "table" and laneData.class or { name = laneData.class }
        -- 中文维护：职业中文名和职业类别图标来自同一个 Metadata 快照；未知类别只显示文字。
        out.class = { value = tostring(class.name or ""), icon = class.icon, key = class.key }
    end
    if laneData.gearScore ~= nil then out.gearScore = { value = tostring(math.floor(tonumber(laneData.gearScore) or 0)) } end
    for _, key in ipairs({ "mainHand", "offHand", "ranged", "wings" }) do
        local item = type(laneData[key]) == "table" and laneData[key] or nil
        -- 中文维护：复用已有目标主/副手的布局开关与位置，避免升级重排用户校准/修改存档规范化。
        -- targetLoadout 只在 target lane 创建；分别呈现武器类型/防具类型，自己仍呈现实际物品。
        if type(laneData.targetLoadout) == "table" then
            item = key == "mainHand" and laneData.targetLoadout.weapon or nil
            if key == "offHand" then item = laneData.targetLoadout.armor end
        end
        if item ~= nil and (item.icon ~= nil or item.name ~= nil) then
            out[key] = {
                icon = tostring(item.icon or ""),
                gradeIconPath = tostring(item.gradeIconPath or ""),
                name = tostring(item.name or ""), source = item.source, buffId = item.buffId,
            }
        end
    end
    if type(laneData.cast) == "table" and laneData.cast.casting == true then
        out.cast = {
            spellName = tostring(laneData.cast.spellName or ""),
            currMs = math.max(0, math.floor(tonumber(laneData.cast.currMs) or 0)),
            totalMs = math.max(1, math.floor(tonumber(laneData.cast.totalMs) or 1)),
        }
    end
    return out
end

F.ProjectPlatesContractVersion = 4
