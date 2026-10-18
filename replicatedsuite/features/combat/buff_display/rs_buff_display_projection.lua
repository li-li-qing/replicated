------------------------------------------------------------------------
-- Replicated Suite · 状态显示只读投影
-- 作者：Replicated
-- QQ群：1104129461
--
-- 无Native/API访问，将AuraObservationV3 StatusMap和Feature通道数据转为有界独立页面/Widget行。
-- 分类契约：category为buff/debuff/unknown，Auto是追踪桶；hidden/special_rule为共享StatusClassificationV3检测来源，不能作用户分类；传入预建索引时追踪查询为O(1)。
-- 合并后须核对冲突标记、toc.g完整性和Lua语法，再验收；禁止清配置、跳加载或恢复Legacy绕过原Authority/存档协议。
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
S.Features = S.Features or {}
S.Features.BuffDisplay = S.Features.BuffDisplay or {}
local F = S.Features.BuffDisplay

local function Classification()
    return S.Services and S.Services.StatusClassificationV3 or nil
end

-- O(1) 追踪索引：{ buff = {[id]=true}, debuff = {[id]=true} }；调用方未传入时从 settings.tracked 构建。
local function BuildTrackedIndex(settings)
    local index = { player={buff={},debuff={},auto={}}, target={buff={},debuff={},auto={}}, buff={},debuff={},auto={} }
    settings = type(settings) == "table" and settings or {}
    local tracked = type(settings.tracked) == "table" and settings.tracked or {}
    -- 索引 Authority 是 schema8 player/target 六通道；兼容平面数据只走 scoped 分支。
    -- 不能在循环后再次追加旧 tracked.auto，否则混入第二套平面选择；这里仍为按设置变化重建，不加采样。
    local nested = type(tracked.player)=="table" or type(tracked.target)=="table"
    for _,scope in ipairs({"player","target"}) do
        local scoped=nested and (type(tracked[scope])=="table" and tracked[scope] or {}) or tracked
        for _,category in ipairs({"buff","debuff","auto"}) do
            for _,id in ipairs(type(scoped[category])=="table" and scoped[category] or {}) do
                id=math.floor(tonumber(id) or 0)
                if id>0 then index[scope][category][id]=true;index[category][id]=true end
            end
        end
    end
    return index
end
-- 头顶图标与表格行的紧凑时间格式，输入 timeLeft 为毫秒。
-- ≥60s 显示 M.SS.cc，例如 1.20.10 表示1分20秒10厘秒；<60s 显示 S.c，例如 10.0 表示10秒0厘秒；nil 显示 --。
local function FormatCompactTime(ms)
    if ms == nil then return "--" end
    local totalCs = math.max(0, math.floor(ms / 10))  -- 厘秒。
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

-- 将 AuraObservationV3 的 StatusMap 事实转为独立展示行；签名为 (statusMap, meta, settings, scope, limit, trackedIndex)。
function F.ProjectStatusMap(statusMap, meta, settings, scope, limit, trackedIndex)
    statusMap, settings = type(statusMap) == "table" and statusMap or {}, type(settings) == "table" and settings or {}
    trackedIndex = type(trackedIndex) == "table" and trackedIndex or BuildTrackedIndex(settings)
    local classification = Classification()
    local rows, seen = {}, {}
    for id, entry in pairs(statusMap) do
        local kind = classification ~= nil and classification:ClassifyEntry(entry, settings.classification)
            -- 混合版本/分类服务缺席也必须 fail-closed，不能通过旧 fallback 把 Hidden 变成 Buff。
            or { category = "unknown",
                 detectionSource = entry.sources and entry.sources.hidden == true and "hidden" or "normal" }
        local category = kind.category or "unknown"
        -- Hidden为独立事实来源，禁止被Buff/Debuff分类开关压掉；仅页面只看隐藏筛选拥有这组行，用户关闭一个分类时不能让隐藏效果消失。
        local hiddenSource = kind.detectionSource == "hidden"
        local allowed = category == "unknown" or hiddenSource == true
            or (category == "buff" and settings.showBuffs ~= false)
            or (category == "debuff" and settings.showDebuffs ~= false)
        if allowed == true and seen[id] ~= true then
            seen[id] = true
            local timeLeft = tonumber(entry.timeLeft)
            local idNum = math.floor(tonumber(id) or 0)
            -- 实时列表的“已追踪”标志必须读取当前单位 scope，
            -- 不能读取 player/target 的兼容 union。否则“仅目标 Buff”会在自身实时列表也显示已追踪，
            -- 虽然 HUD 白名单正确但管理语义错误。兼容旧纯函数调用：没有嵌套 scope 时回退旧平面索引。
            local scopedTracked = (scope == "player" or scope == "target") and trackedIndex[scope] or nil
            scopedTracked = type(scopedTracked) == "table" and scopedTracked or trackedIndex
            local tracked = (scopedTracked.buff ~= nil and scopedTracked.buff[idNum] == true)
                or (scopedTracked.debuff ~= nil and scopedTracked.debuff[idNum] == true)
                or (scopedTracked.auto ~= nil and scopedTracked.auto[idNum] == true)
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

-- 头顶投影的 laneData 来自 Feature 通道：{ buffRows, debuffRows, distance, class, gearScore, mainHand={icon,gradeIconPath,name}, offHand, ranged, wings, cast={casting,spellName,currMs,totalMs} }。
-- 只返回启用组件，各组件追踪行有上界。headShowAll 是显式选项，可展示普通未追踪 Buff/Debuff，但 Hidden 来源始终不能绕过显式追踪白名单；观察 Hidden 与展示 Hidden 必须分开。
local function BoundedTracked(rows, settings, category, trackedIndex, scope)
    rows = type(rows) == "table" and rows or {}
    trackedIndex = type(trackedIndex) == "table" and trackedIndex or BuildTrackedIndex(settings)
    local component = type(settings.components) == "table" and settings.components[category == "debuff" and "debuffs" or "buffs"] or nil
    component = type(component) == "table" and component or {}
    -- 标准容量来自可见组件的行几何，禁止另建 headMaxIcons 权威；渲染器和投影共用同一数据。
    local perRow = math.max(1, math.min(16, math.floor(tonumber(component.maxPerRow) or 8)))
    local maxRows = math.max(1, math.min(4, math.floor(tonumber(component.maxRows) or 2)))
    local maxIcons = math.min(64, perRow * maxRows)
    local out = {}
    local showAll = settings.headShowAll == true
    for _, row in ipairs(rows) do
        local idNum = math.floor(tonumber(row.id) or 0)
        -- HUD 白名单同时接受 Auto；lane 分流仍由真实分类决定，不能把 unknown 塞入 Buff。
        local scoped = (scope=="player" or scope=="target") and trackedIndex[scope] or nil
        scoped = type(scoped)=="table" and scoped or trackedIndex
        local isTracked = (scoped[category] ~= nil and scoped[category][idNum] == true)
            or (scoped.auto ~= nil and scoped.auto[idNum] == true)
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

-- 复制组件，禁止投影暴露实时 Store 表；Presentation 只读独立快照，不能通过投影持有或修改权威状态。
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

-- 目标装备 API 可能实际返回自己装备，不能用于敌人。
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

-- 距离/施法的格式化共用同一纯投影；局部读取不复制Buff、
-- 装备、追踪配置，不读取Native。返回新的小表，不暴露lane facts给Renderer反向修改。
function F.ProjectDynamicPlates(laneData)
    laneData=type(laneData)=="table" and laneData or {}
    local out={}
    local distance = tonumber(laneData.distance)
    if distance ~= nil then
        if distance < 1000 then
            out.distance = { value = string.format("%.1f", distance) .. "m", meters=distance }
        else
            out.distance = { value = string.format("%.2f", distance / 1000) .. "km", meters=distance }
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

function F.ProjectPlates(laneData, settings, trackedIndex, scope)
    laneData, settings = type(laneData) == "table" and laneData or {}, type(settings) == "table" and settings or {}
    local components = CopyComponents(settings.components)
    -- Feature 已维护 O(1) trackedIndex 时直接复用，
    -- 避免 50ms HUD 刷新反复复制/遍历最多 2048 个追踪 ID；纯函数调用仍可省略第三参
    -- 并从 settings.tracked 构建，保持旧 acceptance/调用方兼容。
    trackedIndex = type(trackedIndex) == "table" and trackedIndex or BuildTrackedIndex(settings)
    local out = { components = components, buffs = {}, debuffs = {}, cooldowns = {} }
    local dynamic=F.ProjectDynamicPlates(laneData)
    out.distance,out.cast=dynamic.distance,dynamic.cast
    if out.distance==nil and type(settings.placement)=='table'and settings.placement.mode=='fixed'then out.distance={value='--m',unknown=true}end
    out.buffs = BoundedTracked(laneData.buffRows, settings, "buff", trackedIndex, scope)
    out.debuffs = BoundedTracked(laneData.debuffRows, settings, "debuff", trackedIndex, scope)
    -- cooldownRows 已由 CooldownObservationV3
    -- 过滤成“当前真正处于 CD”的本机 Native 事实。这里只做有界 detached copy，不查询 API、
    -- 不把静态 expectedSec 当 Authority，也绝不把 player CD 复制到 target scope。
    if scope == "player" and type(laneData.cooldownRows) == "table" then
        local cfg = type(components.cooldowns) == "table" and components.cooldowns or {}
        local maxPerRow = math.max(1, math.min(16, math.floor(tonumber(cfg.maxPerRow) or 8)))
        local maxRows = math.max(1, math.min(4, math.floor(tonumber(cfg.maxRows) or 2)))
        local limit = math.min(64, maxPerRow * maxRows)
        for _, row in ipairs(laneData.cooldownRows) do
            local copy = {}
            for key, value in pairs(row) do copy[key] = value end
            out.cooldowns[#out.cooldowns + 1] = copy
            if #out.cooldowns >= limit then break end
        end
    end

    if laneData.class ~= nil then
        local class = type(laneData.class) == "table" and laneData.class or { name = laneData.class }
        -- 职业中文名和职业类别图标来自同一个 Metadata 快照；未知类别只显示文字。
        out.class = { value = tostring(class.name or ""), icon = class.icon, key = class.key }
    end
    if laneData.gearScore ~= nil then out.gearScore = { value = tostring(math.floor(tonumber(laneData.gearScore) or 0)) } end
    -- 别名已在 TARGET_CHANGED/用户操作边由 Store O(1) 解析；
    -- Projection 仅复制字符串，严禁在 HUD 热路径读取 UnitName 或遍历持久化备注表。
    if scope == "target" and type(laneData.targetAlias) == "string" and laneData.targetAlias ~= "" then
        -- 别名几何随 scope settings 的小快照进入 Projection；
        -- Renderer 只消费 detached 值，不直接访问 Persistence。enabled=false 时 Resolve 已让 alias 为空，
        -- 这里仍携带 hud 只是为了校准/兼容调用保持同一数据结构，不增加 Native 查询。
        local hud = type(settings.targetAlias) == "table" and settings.targetAlias or {}
        out.alias = {
            value = tostring(laneData.targetAlias),
            targetName = tostring(laneData.targetName or ""),
            hud = {
                enabled = hud.enabled ~= false,
                x = tonumber(hud.x) or 0,
                y = tonumber(hud.y) or -94,
                fontSize = tonumber(hud.fontSize) or 12,
                alpha = tonumber(hud.alpha) or 1.0,
            },
        }
    end
    for _, key in ipairs({ "mainHand", "offHand", "ranged", "wings" }) do
        local item = type(laneData[key]) == "table" and laneData[key] or nil
        -- 复用已有目标主/副手的布局开关与位置，避免升级重排用户校准/修改存档规范化。
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
    return out
end

F.ProjectPlatesContractVersion = 7
