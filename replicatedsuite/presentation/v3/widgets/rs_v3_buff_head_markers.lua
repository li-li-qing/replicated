------------------------------------------------------------------------
-- Replicated Suite V3 - Plate Head Renderer (v4)
--
-- The health-bar plate is the single layout anchor. Everything is positioned
-- relative to its rectangle:
--
--   InfoRow (class · gear · distance)   ← above buffs, auto-raises with rows
--   BuffRow(s)                           ← above the plate, maxRows upward
--   [LeftEquip] [    plate    ] [RightEquip]  ← equipment flanks the plate
--   DebuffRow(s)                         ← below the plate, maxRows downward
--
-- The Feature owns all scheduler lanes; this presenter only keeps bounded
-- widget pools, computes a cached layout per render, and applies diffs.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local Feature = S.Features and S.Features.BuffDisplay or nil
if type(Feature) ~= "table" or type(S.UI) ~= "table" or type(S.Events) ~= "table" then return end

S.UIV3 = S.UIV3 or {}
S.UIV3.BuffHeadMarkersV3 = S.UIV3.BuffHeadMarkersV3 or {}
local P = S.UIV3.BuffHeadMarkersV3
P.version = 5
P.owner = "v3:buff_head_markers"
P.consumerToken = "presentation:buff_head_markers"
P.running = P.running == true
P.consumerHeld = P.consumerHeld == true
P.pools = P.pools or { player = { icons = {}, labels = {}, cast = nil, plate = nil, info = nil }, target = { icons = {}, labels = {}, cast = nil, plate = nil, info = nil } }
P.lifecycleOwner = P.lifecycleOwner or {}
P.metrics = P.metrics or { starts=0, stops=0, ticks=0, projections=0, allocated=0, anchorFailures={} }

local SCOPES = { "player", "target" }
local RENDERABLE_KEYS = { "buffs", "debuffs", "distance", "class", "gearScore", "mainHand", "offHand", "ranged", "wings", "castBar" }
local UNKNOWN_ICON = "ui/icon/icon_unknown_item.dds"

local function N(v, fallback) return tonumber(v) or tonumber(fallback) or 0 end
local function Settings()
    local value = type(Feature.GetSettingsProjection) == "function" and Feature:GetSettingsProjection() or nil
    return type(value) == "table" and value or {}
end
local function FeatureEnabled()
    return S.FeatureRuntime ~= nil and S.FeatureRuntime:IsEnabled("combat_buff_display") == true
end
local function ScopeEnabled(scope, settings)
    return scope == "player" and settings.headPlayer ~= false or scope == "target" and settings.headTarget ~= false
end
-- Render gate: the head display starts when headEnabled and at least one
-- component is enabled. Buff/debuff whitelist decisions stay in ProjectPlates;
-- presentation never owns or bypasses tracking policy.
local function HasRenderableComponents(settings)
    local components = type(settings.components) == "table" and settings.components or {}
    local plate = type(settings.plate) == "table" and settings.plate or {}
    local info = type(settings.info) == "table" and settings.info or {}
    if plate.enabled ~= false or info.enabled ~= false then return true end
    for _, key in ipairs(RENDERABLE_KEYS) do
        local component = components[key]
        if component == nil or component.enabled ~= false then return true end
    end
    return false
end

------------------------------------------------------------------------
-- Pools
------------------------------------------------------------------------

local function MakeIcon(scope, index)
    local root, err = S.UI:CreateEmptyWidget(UIParent, "v3_buff_head_" .. scope .. "_icon_" .. tostring(index), 0, 0, 40, 40, false, P.owner)
    if root == nil then return nil, err end
    root.rsUiOwner = P.owner
    local icon = root.CreateIconDrawable and root:CreateIconDrawable("artwork") or nil
    -- Equipment quality uses a second texture over the base item icon. It is
    -- allocated lazily only when this pooled marker actually renders equipment,
    -- so ordinary Aura-only slots do not pay an extra drawable allocation.
    local stack = S.UI:CreateLabel(root, "v3_buff_head_" .. scope .. "_stack_" .. tostring(index), "", 0, 0, 18, 14, 9, "strong", "RIGHT", true)
    local time = S.UI:CreateLabel(root, "v3_buff_head_" .. scope .. "_time_" .. tostring(index), "", 0, 0, 40, 12, 8, "default", "RIGHT", true)
    if icon == nil or stack == nil or time == nil then
        S.UI:SetVisible(root, false, P.owner)
        return nil, "buff_head_marker_child_create_failed"
    end
    S.UI:SetVisible(root, false, P.owner)
    return { root=root, icon=icon, grade=nil, stack=stack, time=time, iconPath=nil, gradePath=nil, layout={} }
end

local function MakeLabel(scope, index)
    local label, err = S.UI:CreateLabel(UIParent, "v3_buff_head_" .. scope .. "_label_" .. tostring(index), "", 0, 0, 120, 16, 10, "strong", "CENTER", true)
    if label == nil then return nil, err end
    S.UI:SetVisible(label, false, P.owner)
    return { root=label, text="" }
end

local function MakeCastBar(scope)
    local root, err = S.UI:CreateEmptyWidget(UIParent, "v3_buff_head_" .. scope .. "_castbar", 0, 0, 120, 8, false, P.owner)
    if root == nil then return nil, err end
    root.rsUiOwner = P.owner
    local bg = root.CreateColorDrawable and root:CreateColorDrawable(0.10, 0.10, 0.12, 0.85, "overlay") or nil
    local fill = root.CreateColorDrawable and root:CreateColorDrawable(0.96, 0.72, 0.12, 0.95, "overlay") or nil
    local text = S.UI:CreateLabel(root, "v3_buff_head_" .. scope .. "_cast_text", "", 0, 0, 120, 14, 10, "default", "CENTER", true)
    if bg == nil or fill == nil or text == nil then
        S.UI:SetVisible(root, false, P.owner)
        return nil, "buff_head_castbar_child_create_failed"
    end
    S.UI:SetVisible(root, false, P.owner)
    return { root=root, bg=bg, fill=fill, text=text, barW=120, layout={} }
end

local function MakeInfo(scope)
    local label, err = S.UI:CreateLabel(UIParent, "v3_buff_head_" .. scope .. "_info", "", 0, 0, 220, 16, 10, "default", "CENTER", true)
    if label == nil then return nil, err end
    S.UI:SetVisible(label, false, P.owner)
    return { root=label, text="" }
end

local function RequiredIconCount(settings)
    settings = type(settings) == "table" and settings or Settings()
    local components = type(settings.components) == "table" and settings.components or {}
    local buff = components.buffs or {}
    local debuff = components.debuffs or {}
    local buffMax = math.max(1, math.min(64, math.floor(N(buff.maxPerRow, 8) * N(buff.maxRows, 2))))
    local debuffMax = math.max(1, math.min(64, math.floor(N(debuff.maxPerRow, 8) * N(debuff.maxRows, 2))))
    return buffMax + debuffMax + 8
end

function P:EnsurePools(settings)
    settings = type(settings) == "table" and settings or Settings()
    local iconCount = RequiredIconCount(settings)
    for _, scope in ipairs(SCOPES) do
        local pool = self.pools[scope]
        for index = #pool.icons + 1, iconCount do
            local marker, err = MakeIcon(scope, index)
            if marker == nil then return false, err end
            pool.icons[index] = marker
            self.metrics.allocated = self.metrics.allocated + 1
        end
        if pool.cast == nil then
            local cast, err = MakeCastBar(scope)
            if cast == nil then return false, err end
            pool.cast = cast
            self.metrics.allocated = self.metrics.allocated + 1
        end
        if pool.info == nil then
            local info, err = MakeInfo(scope)
            if info == nil then return false, err end
            pool.info = info
            self.metrics.allocated = self.metrics.allocated + 1
        end
    end
    return true
end

local function HideIcon(marker)
    if marker and marker.root then S.UI:SetVisible(marker.root, false, P.owner) end
end
local function HideScope(scope)
    local pool = P.pools[scope]
    if pool == nil then return end
    for _, marker in ipairs(pool.icons) do HideIcon(marker) end
    if pool.labels then for _, label in ipairs(pool.labels) do if label.root then S.UI:SetVisible(label.root, false, P.owner) end end end
    if pool.cast then S.UI:SetVisible(pool.cast.root, false, P.owner) end
    if pool.info then S.UI:SetVisible(pool.info.root, false, P.owner) end
end
function P:HideAll()
    for _, scope in ipairs(SCOPES) do HideScope(scope) end
    return true
end

------------------------------------------------------------------------
-- Layout helpers
------------------------------------------------------------------------

-- Clamp a whole horizontal group into the logical screen. Members keep their
-- fixed relative spacing; only the group origin moves. This is the only
-- horizontal clamp path — individual icons are never clamped separately
-- (per-icon clamping would pile icons up at the screen edge).
local function ClampHorizontalGroup(groupLeft, groupWidth, screenWidth)
    if groupWidth == nil or groupWidth <= 0 then return groupLeft end
    if groupWidth >= screenWidth - 4 then return math.max(2, groupLeft) end
    return math.max(2, math.min(math.max(2, screenWidth - groupWidth - 2), groupLeft))
end

local function LogicalScreenWidth()
    local screenW = 1024
    if S.Api ~= nil and type(S.Api.GetUiMetrics) == "function" then
        local sw, sh, scale, lw, lh = S.Api:GetUiMetrics()
        scale = tonumber(scale) or 1
        screenW = tonumber(lw) or ((tonumber(sw) or 1024) / math.max(0.001, scale))
    end
    return screenW
end

local function LayoutIcon(marker, size, showStacks, showTime)
    local cache = marker.layout
    if cache.size == size and cache.showStacks == showStacks and cache.showTime == showTime then return end
    cache.size, cache.showStacks, cache.showTime = size, showStacks, showTime
    -- Remaining-time label is embedded at the icon's bottom-right (no extra row
    -- height) so it is always visible without pushing rows apart; the stack
    -- counter stays at the top-right.
    local totalH = size
    S.UI:SetExtent(marker.root, size, totalH, P.owner)
    S.UI:SetExtent(marker.icon, size, size, P.owner)
    S.UI:SetAnchor(marker.icon, marker.root, 0, 0, P.owner)
    if marker.grade ~= nil then
        S.UI:SetExtent(marker.grade, size, size, P.owner)
        S.UI:SetAnchor(marker.grade, marker.root, 0, 0, P.owner)
    end
    S.UI:SetAnchor(marker.stack, marker.root, 0, 0, P.owner)
    S.UI:SetExtent(marker.stack, size - 2, math.max(12, math.floor(size * 0.5)), P.owner)
    S.UI:SetAnchor(marker.time, marker.root, 0, math.max(0, size - 10), P.owner)
    S.UI:SetExtent(marker.time, size - 1, 10, P.owner)
    S.UI:SetFontSize(marker.stack, math.max(8, math.floor(size * 0.34)), P.owner)
    S.UI:SetFontSize(marker.time, math.max(8, math.floor(size * 0.32)), P.owner)
    S.UI:SetVisible(marker.stack, showStacks, P.owner)
    S.UI:SetVisible(marker.time, showTime, P.owner)
end

local function TextWidth(text, fontSize)
    return math.max(24, math.floor(#tostring(text or "") * (fontSize or 10) * 0.62) + 8)
end

-- Clamp a marker's top-left into the logical screen so a centered icon row can
-- never overflow off-screen when the anchored unit is near a screen edge (the
-- "only a few icons visible / position out of bounds" symptom). Layout remains
-- free within the screen; only off-screen placement is pulled back.
local function ClampToScreen(x, y, w, h)
    local screenW, screenH = 1024, 768
    if S.Api ~= nil and type(S.Api.GetUiMetrics) == "function" then
        local sw, sh, scale, lw, lh = S.Api:GetUiMetrics()
        scale = tonumber(scale) or 1
        screenW = tonumber(lw) or ((tonumber(sw) or 1024) / math.max(0.001, scale))
        screenH = tonumber(lh) or ((tonumber(sh) or 768) / math.max(0.001, scale))
    end
    x = math.floor(math.max(2, math.min(math.max(2, screenW - (tonumber(w) or 0) - 2), x)))
    y = math.floor(math.max(2, math.min(math.max(2, screenH - (tonumber(h) or 0) - 2), y)))
    return x, y
end

local function ApplyIcon(marker, row, size, cfg, x, y, showStacks, showTime)
    LayoutIcon(marker, size, showStacks, showTime)
    if type(cfg) == "table" then S.UI:SetAlpha(marker.root, math.max(0.1, math.min(1, N(cfg.alpha, 1))), P.owner) end
    local path = tostring(row and row.iconPath or "")
    if path ~= marker.iconPath then
        S.UI:SetIconTexture(marker.icon, path ~= "" and path or UNKNOWN_ICON, P.owner)
        marker.iconPath = path
    end
    local gradePath = tostring(row and row.gradeIconPath or "")
    if gradePath ~= "" and marker.grade == nil and marker.root ~= nil and type(marker.root.CreateIconDrawable) == "function" then
        marker.grade = marker.root:CreateIconDrawable("artwork")
        if marker.grade ~= nil then
            S.UI:SetExtent(marker.grade, size, size, P.owner)
            S.UI:SetAnchor(marker.grade, marker.root, 0, 0, P.owner)
            S.UI:SetVisible(marker.grade, false, P.owner)
        end
    end
    if marker.grade ~= nil then
        if gradePath ~= marker.gradePath then
            if gradePath ~= "" then S.UI:SetIconTexture(marker.grade, gradePath, P.owner) end
            marker.gradePath = gradePath
        end
        S.UI:SetVisible(marker.grade, gradePath ~= "", P.owner)
    end
    marker.stack:SetText((showStacks and N(row.stack, 1) > 1) and tostring(math.floor(N(row.stack, 1))) or "")
    marker.time:SetText(showTime and tostring(row.timeText or "--") or "")
    -- Group-level clamping already kept the whole row/group inside the screen;
    -- each icon is placed at its exact computed slot so members never pile up.
    S.UI:SetAnchor(marker.root, UIParent, x, y, P.owner)
    S.UI:SetVisible(marker.root, true, P.owner)
end

-- Render a horizontal icon row for a component; returns how many slots used.
-- The WHOLE row is clamped as one group; individual icons keep exact spacing.
local function RenderIconRow(scope, pool, rows, cfg, centerX, rowY, showStacks, showTime, slotOffset, size, gap)
    local used = 0
    size = math.max(8, math.floor(tonumber(size) or N(cfg.size, 24)))
    gap = math.max(0, math.floor(tonumber(gap) or N(cfg.spacing, 2)))
    local count = math.min(#rows, 16)
    local totalW = count * size + math.max(0, count - 1) * gap
    local startX = math.floor(centerX + N(cfg.x, 0) - totalW / 2)
    startX = ClampHorizontalGroup(startX, totalW, LogicalScreenWidth())
    local startY = math.floor(tonumber(rowY) or 0)
    for index = 1, count do
        local marker = pool.icons[slotOffset + index]
        if marker == nil then break end
        ApplyIcon(marker, rows[index], size, cfg, startX + (index - 1) * (size + gap), startY, showStacks, showTime)
        used = used + 1
    end
    return used
end

-- Multi-row buff/debuff rendering: rows stack upward (buff) or downward
-- (debuff) from the plate edge, bounded by MaxPerRow and MaxRows.
local function RenderRows(scope, pool, rows, cfg, centerX, firstRowTop, showStacks, showTime, slotOffset, size, spacing, maxPerRow, maxRows, rowGap, direction)
    local used = 0
    local all = type(rows) == "table" and rows or {}
    local total = math.min(#all, maxPerRow * maxRows)
    if total <= 0 then return 0 end
    for r = 0, maxRows - 1 do
        local start = r * maxPerRow + 1
        local count = math.min(maxPerRow, total - r * maxPerRow)
        if count <= 0 then break end
        local rowTop = firstRowTop + direction * (r * rowGap)
        local slice = {}
        for i = 1, count do slice[i] = all[start + i - 1] end
        used = used + RenderIconRow(scope, pool, slice, cfg, centerX, rowTop, showStacks, showTime, slotOffset + used, size, spacing)
    end
    return used
end

------------------------------------------------------------------------
-- Layout geometry (pure)
------------------------------------------------------------------------

-- Default visual spacing (verified defaults; derived from the legacy
-- Professional Plates section-flow experience, widened for clear layering).
-- Buff/Debuff/Info/equipment are all computed from the bar rect only.
-- Gap constants scaled 1.5× to match the new default icon sizes.
local BUFF_TO_BAR = 11       -- first buff row bottom -> bar.top
local BUFF_ROW_GAP = 5       -- between buff rows
local DEBUFF_TO_BAR = 11     -- first debuff row top -> bar.bottom
local DEBUFF_ROW_GAP = 5     -- between debuff rows
local INFO_TO_BUFF = 9       -- info bottom -> top-most actual buff row top
local INFO_TO_BAR = 12       -- info bottom -> bar.top when no buffs
local EQUIP_TO_BAR = 9       -- equipment inner edge -> bar side
local EQUIP_GAP = 5          -- between two equipment icons

-- Pure layout computation. No widgets, no native reads, no store mutation.
-- Inputs are the projected anchor (unit screen position), settings, and the
-- actual visible row/equipment counts. Returns a geometry table the renderer
-- applies verbatim. This is the single authority for "where does X go".
--
--   anchorX, anchorY : unit screen projection point (ScreenProjectionV3 space)
--   settings         : BuffDisplay settings projection (plate/info/components)
--   buffCount        : visible buff rows count (already bounded)
--   debuffCount      : visible debuff rows count
--   equip            : { mainHand=bool, offHand=bool, ranged=bool, wings=bool }
function ComputePlateLayout(anchorX, anchorY, settings, buffCount, debuffCount, equip)
    settings = type(settings) == "table" and settings or {}
    local plateCfg = type(settings.plate) == "table" and settings.plate or {}
    local infoCfg = type(settings.info) == "table" and settings.info or {}
    local components = type(settings.components) == "table" and settings.components or {}
    local scale = math.max(0.5, math.min(2, tonumber(settings.plateScale) or 1))

    -- NativeBarProxy rectangle: the single geometric anchor. Only plate.x/y
    -- offset the bar; headOffsetY is legacy-only and never enters this chain.
    local barW = math.max(24, math.floor(N(plateCfg.width, 225) * scale))
    local barH = math.max(8, math.floor(N(plateCfg.height, 30) * scale))
    local centerX = math.floor((tonumber(anchorX) or 0) + N(plateCfg.x, 0) * scale)
    local centerY = math.floor((tonumber(anchorY) or 0) + N(plateCfg.y, 0) * scale)
    local left = centerX - math.floor(barW / 2)
    local right = left + barW
    local top = centerY - math.floor(barH / 2)
    local bottom = centerY + math.floor(barH / 2)
    local bar = { centerX = centerX, centerY = centerY, left = left, right = right, top = top, bottom = bottom, width = barW, height = barH }

    -- Buff rows: row1.bottom = bar.top - BuffToBarGap; extra rows stack upward
    -- at BuffRowGap. Component y is a local micro offset only.
    local buffCfg = components.buffs or {}
    local buffSize = math.max(8, math.floor(N(buffCfg.size, 36) * scale))
    local buffSpacing = math.max(0, math.floor(N(buffCfg.spacing, 3) * scale))
    local buffMaxPerRow = math.max(1, math.min(16, math.floor(N(buffCfg.maxPerRow, 8))))
    local buffMaxRows = math.max(1, math.min(4, math.floor(N(buffCfg.maxRows, 2))))
    local buffGap = BUFF_TO_BAR * scale + math.floor(N(buffCfg.y, 0) * scale)
    local buffRowGap = BUFF_ROW_GAP * scale
    local buffFirstTop = bar.top - buffGap - buffSize          -- row1.top
    local buffActualRows = math.min(buffMaxRows, math.ceil(buffCount / buffMaxPerRow))
    local buffTopMostTop = buffFirstTop - (buffActualRows - 1) * buffRowGap

    -- Debuff rows: row1.top = bar.bottom + DebuffToBarGap; extra rows stack
    -- downward at DebuffRowGap.
    local debuffCfg = components.debuffs or {}
    local debuffSize = math.max(8, math.floor(N(debuffCfg.size, 36) * scale))
    local debuffSpacing = math.max(0, math.floor(N(debuffCfg.spacing, 3) * scale))
    local debuffMaxPerRow = math.max(1, math.min(16, math.floor(N(debuffCfg.maxPerRow, 8))))
    local debuffMaxRows = math.max(1, math.min(4, math.floor(N(debuffCfg.maxRows, 2))))
    local debuffGap = DEBUFF_TO_BAR * scale + math.floor(N(debuffCfg.y, 0) * scale)
    local debuffRowGap = DEBUFF_ROW_GAP * scale
    local debuffFirstTop = bar.bottom + debuffGap

    -- Info row: above the top-most ACTUAL buff row; above the bar when no buffs.
    local infoFont = math.max(8, math.floor(N(infoCfg.fontSize, 15) * scale))
    local infoH = infoFont + 4
    local infoGap = (buffActualRows > 0 and INFO_TO_BUFF or INFO_TO_BAR) * scale
    local infoTop = (buffActualRows > 0 and buffTopMostTop or bar.top) - infoGap - infoH
    infoTop = infoTop + math.floor(N(infoCfg.y, 0) * scale)

    -- Equipment flanks. Left: offHand closest to bar, mainHand further left.
    -- Right: wings closest to bar, ranged further right. Component x/y are
    -- local micro offsets. Slots are returned UNCLAMPED with their absolute
    -- origin; the renderer clamps each group as a whole (never per-icon).
    local function EquipSlots(edgeStart, direction, keys)
        local slots = {}
        local edge = edgeStart
        for _, key in ipairs(keys) do
            local cfg = components[key] or {}
            local enabled = equip[key] == true
            if enabled then
                local size = math.max(8, math.floor(N(cfg.size, 33) * scale))
                local gap = math.max(1, math.floor(N(cfg.gap or cfg.spacing, EQUIP_GAP) * scale))
                local x
                if direction < 0 then x = edge - gap - size else x = edge + gap end
                x = x + math.floor(N(cfg.x, 0) * scale)
                local y = bar.centerY - math.floor(size / 2) + math.floor(N(cfg.y, 0) * scale)
                slots[#slots + 1] = { key = key, x = x, y = y, size = size }
                edge = direction < 0 and x or (x + size)
            end
        end
        return slots
    end
    local leftSlots = EquipSlots(bar.left, -1, { "offHand", "mainHand" })
    local rightSlots = EquipSlots(bar.right, 1, { "wings", "ranged" })
    local function GroupRect(slots)
        if #slots == 0 then return nil end
        local minX, maxX, maxW = math.huge, -math.huge, 0
        for _, s in ipairs(slots) do
            minX = math.min(minX, s.x); maxX = math.max(maxX, s.x + s.size); maxW = math.max(maxW, s.size)
        end
        return { left = minX, width = maxX - minX, maxW = maxW }
    end

    return {
        bar = bar,
        buff = { firstTop = buffFirstTop, rowGap = buffRowGap, size = buffSize, spacing = buffSpacing,
                 maxPerRow = buffMaxPerRow, maxRows = buffMaxRows, actualRows = buffActualRows, topMostTop = buffTopMostTop },
        debuff = { firstTop = debuffFirstTop, rowGap = debuffRowGap, size = debuffSize, spacing = debuffSpacing,
                   maxPerRow = debuffMaxPerRow, maxRows = debuffMaxRows, actualRows = math.min(debuffMaxRows, math.ceil(debuffCount / debuffMaxPerRow)) },
        info = { top = infoTop, font = infoFont, height = infoH },
        equip = { mainHand = equip.mainHand == true, offHand = equip.offHand == true, ranged = equip.ranged == true, wings = equip.wings == true },
        leftGroup = { slots = leftSlots, rect = GroupRect(leftSlots) },
        rightGroup = { slots = rightSlots, rect = GroupRect(rightSlots) },
        scale = scale,
    }
end

-- Expose the pure layout function for acceptance geometry tests and any other
-- consumer that needs the plate geometry without touching widgets.
P.ComputePlateLayout = ComputePlateLayout

------------------------------------------------------------------------
-- Render
------------------------------------------------------------------------

local function RenderCastBar(scope, cast, cfg, centerX, y, scale)
    local pool = P.pools[scope]
    if pool == nil or pool.cast == nil or cast == nil then return end
    local bar = pool.cast
    scale = tonumber(scale) or 1
    local barW = math.max(24, math.floor(N(cfg.width, 120) * scale))
    local barH = math.max(4, math.floor(N(cfg.size, 6) * scale))
    local showText = cfg.showText ~= false
    local alpha = math.max(0.1, math.min(1, N(cfg.alpha, 1)))
    local ratio = math.max(0, math.min(1, cast.totalMs > 0 and (cast.currMs / cast.totalMs) or 0))
    local x = math.floor(centerX + N(cfg.x, 0) * scale - barW / 2)
    local cache = bar.layout
    if cache.alpha ~= alpha then S.UI:SetAlpha(bar.root, alpha, P.owner); cache.alpha = alpha end
    if cache.barW ~= barW then cache.barW = barW end
    local clampedX, clampedY = ClampToScreen(x, math.floor(y), barW, barH)
    S.UI:SetAnchor(bar.root, UIParent, clampedX, clampedY, P.owner)
    S.UI:SetExtent(bar.root, barW, barH, P.owner)
    S.UI:SetAnchor(bar.bg, bar.root, 0, 0, P.owner)
    S.UI:SetExtent(bar.bg, barW, barH, P.owner)
    S.UI:SetAnchor(bar.fill, bar.root, 0, 0, P.owner)
    S.UI:SetExtent(bar.fill, math.max(1, math.floor(barW * ratio)), barH, P.owner)
    bar.text:SetText(showText and (cast.spellName or "") or "")
    S.UI:SetFontSize(bar.text, math.max(8, math.floor(N(cfg.fontSize, 10) * scale)), P.owner)
    S.UI:SetAnchor(bar.text, bar.root, 0, barH + 1, P.owner)
    S.UI:SetExtent(bar.text, barW, 14, P.owner)
    S.UI:SetVisible(bar.root, true, P.owner)
end

-- Record why a scope's plates were hidden so RU-side triage has a visible
-- trail (projection service down, unit off-screen, depth filtered, ...).
local function RecordAnchorFailure(scope, reason)
    local entry = P.metrics.anchorFailures[scope]
    if type(entry) ~= "table" then entry = { count = 0, lastAt = 0, lastErr = nil }; P.metrics.anchorFailures[scope] = entry end
    entry.count = (tonumber(entry.count) or 0) + 1
    entry.lastAt = S.NowMs and S.NowMs() or 0
    entry.lastErr = tostring(reason or "anchor_unavailable")
end

-- Apply a pre-computed equipment group (left or right flank). The whole group
-- is clamped as one unit (only the group origin moves); members keep their
-- exact relative slots, so icons never pile at a screen edge.
local function ApplyEquipGroup(scope, pool, plates, components, group, slotStart)
    local slots = type(group) == "table" and group.slots or nil
    if slots == nil or #slots == 0 then return 0 end
    local used = 0
    local dx = 0
    local rect = type(group) == "table" and group.rect or nil
    if rect ~= nil then
        dx = ClampHorizontalGroup(rect.left, rect.width, LogicalScreenWidth()) - rect.left
    end
    for _, s in ipairs(slots) do
        local marker = pool.icons[slotStart + used + 1]
        if marker == nil then break end
        local item = type(plates) == "table" and plates[s.key] or {}
        local cfg = type(components) == "table" and components[s.key] or {}
        ApplyIcon(marker, { iconPath = item.icon, gradeIconPath = item.gradeIconPath, stack = nil, timeText = nil }, s.size, cfg, s.x + dx, s.y, false, false)
        used = used + 1
    end
    return used
end

-- Info row: class · gear score · distance, dynamically concatenated.
local function RenderInfo(scope, plates, infoCfg, components, centerX, y, fontSize)
    local pool = P.pools[scope]
    if pool == nil or pool.info == nil then return end
    local info = pool.info
    local parts = {}
    local classPart, gearPart, distancePart = nil, nil, nil
    local classCfg = components.class or {}
    if infoCfg.showClass ~= false and classCfg.enabled ~= false then
        local c = type(plates.class) == "table" and plates.class or {}
        if c.value ~= nil and tostring(c.value) ~= "" then classPart = tostring(c.value) end
    end
    local gearCfg = components.gearScore or {}
    if infoCfg.showGear ~= false and gearCfg.enabled ~= false then
        local g = type(plates.gearScore) == "table" and plates.gearScore or {}
        if g.value ~= nil then gearPart = tostring(g.value) end
    end
    local distCfg = components.distance or {}
    if infoCfg.showDistance ~= false and distCfg.enabled ~= false then
        local d = type(plates.distance) == "table" and plates.distance or {}
        if d.value ~= nil then distancePart = tostring(d.value) end
    end
    if classPart ~= nil then parts[#parts + 1] = classPart end
    if gearPart ~= nil then parts[#parts + 1] = gearPart end
    if distancePart ~= nil then parts[#parts + 1] = distancePart end
    local text = table.concat(parts, " · ")
    local width = math.max(24, TextWidth(text, fontSize))
    if text ~= info.text or info.fontSize ~= fontSize then
        info.text, info.fontSize = text, fontSize
        info.root:SetText(text)
        S.UI:SetFontSize(info.root, fontSize, P.owner)
    end
    local x = math.floor(centerX + N(infoCfg.x, 0) - width / 2)
    local clampedX, clampedY = ClampToScreen(x, math.floor(y), width, fontSize + 4)
    S.UI:SetExtent(info.root, width, math.max(12, fontSize + 4), P.owner)
    S.UI:SetAnchor(info.root, UIParent, clampedX, clampedY, P.owner)
    S.UI:SetVisible(info.root, text ~= "", P.owner)
end

local function RenderScope(scope, settings)
    local pool = P.pools[scope]
    if pool == nil then return end
    if ScopeEnabled(scope, settings) ~= true then HideScope(scope); return end
    local plates = Feature:GetPlatesProjection(scope)
    local anchorX, anchorY, depth = Feature:GetPlatesAnchor(scope)
    P.metrics.projections = P.metrics.projections + 1
    if anchorX == nil or anchorY == nil then
        RecordAnchorFailure(scope, "anchor_unavailable")
        HideScope(scope)
        return
    end
    if N(depth, 1) <= 0 then
        RecordAnchorFailure(scope, "depth_non_positive")
        HideScope(scope)
        return
    end
    local components = type(settings.components) == "table" and settings.components or {}
    local infoCfg = type(settings.info) == "table" and settings.info or {}
    local showStacks = settings.headShowStacks ~= false
    local showTime = settings.headShowTime ~= false

    -- Equipment visibility: collapse slots that have no item. Ranged stays an
    -- independent opt-in component (default off); wings is the default right slot.
    local equip = {}
    for _, key in ipairs({ "mainHand", "offHand", "ranged", "wings" }) do
        local cfg = components[key] or {}
        local item = plates[key]
        equip[key] = cfg.enabled ~= false and item ~= nil and item.icon ~= nil
    end

    local buffRows = plates.buffs or {}
    local debuffRows = plates.debuffs or {}
    local buffEnabled = (components.buffs or {}).enabled ~= false
    local debuffEnabled = (components.debuffs or {}).enabled ~= false
    local buffCount = buffEnabled and #buffRows or 0
    local debuffCount = debuffEnabled and #debuffRows or 0

    -- Single pure layout authority.
    local L = ComputePlateLayout(anchorX, anchorY, settings, buffCount, debuffCount, equip)
    local bar = L.bar
    local scale = L.scale

    local slot = 0
    -- Buff rows (stack upward from bar.top).
    if buffEnabled then
        slot = slot + RenderRows(scope, pool, buffRows, components.buffs or {}, bar.centerX, L.buff.firstTop, showStacks, showTime, slot, L.buff.size, L.buff.spacing, L.buff.maxPerRow, L.buff.maxRows, L.buff.rowGap, -1)
    end
    -- Debuff rows (stack downward from bar.bottom).
    if debuffEnabled then
        slot = slot + RenderRows(scope, pool, debuffRows, components.debuffs or {}, bar.centerX, L.debuff.firstTop, showStacks, showTime, slot, L.debuff.size, L.debuff.spacing, L.debuff.maxPerRow, L.debuff.maxRows, L.debuff.rowGap, 1)
    end
    -- Equipment flanks: pre-computed groups applied as whole units (group clamp).
    slot = slot + ApplyEquipGroup(scope, pool, plates, components, L.leftGroup, slot)
    slot = slot + ApplyEquipGroup(scope, pool, plates, components, L.rightGroup, slot)
    for index = slot + 1, #pool.icons do HideIcon(pool.icons[index]) end

    -- Info row (class name · gear score · distance), auto-placed above actual rows.
    if infoCfg.enabled ~= false then
        RenderInfo(scope, plates, infoCfg, components, bar.centerX, L.info.top, L.info.font)
    else
        local info = pool.info
        if info then S.UI:SetVisible(info.root, false, P.owner) end
    end

    -- Cast bar below the debuff rows (hidden when not casting).
    local castCfg = components.castBar or {}
    if castCfg.enabled ~= false and plates.cast ~= nil then
        local castY = bar.bottom + (debuffEnabled and (L.debuff.actualRows * L.debuff.rowGap) or 0) + 6 * scale
        RenderCastBar(scope, plates.cast, castCfg, bar.centerX, castY, scale)
    else
        local cast = pool.cast
        if cast then S.UI:SetVisible(cast.root, false, P.owner) end
    end
end

function P:VisualTick()
    if self.running ~= true then return false end
    self.metrics.ticks = self.metrics.ticks + 1
    local settings = Settings()
    if settings.headEnabled == false or not HasRenderableComponents(settings) then self:HideAll(); return true end
    for _, scope in ipairs(SCOPES) do RenderScope(scope, settings) end
    return true
end

function P:Start()
    if self.running == true then return true end
    if not FeatureEnabled() then return false, "状态显示功能已关闭" end
    local settings = Settings()
    if settings.headEnabled == false or not HasRenderableComponents(settings) then self:HideAll(); return true end
    local ok, err = self:EnsurePools(settings)
    if ok ~= true then return false, err end
    local acquired, acquireErr = Feature:AcquireConsumer(self.consumerToken)
    if acquired ~= true then return false, acquireErr end
    self.consumerHeld = true
    -- The Feature position lane publishes plates.updated at the configured
    -- cadence; the renderer is event-driven and owns no periodic scheduler.
    if type(S.Events.SubscribeInternal) == "function" then
        S.Events:UnsubscribeInternalOwner(self)
        S.Events:SubscribeInternal("v3.buff_display.plates.updated", self, function() return P:VisualTick() end)
    end
    self.running = true
    self.metrics.starts = self.metrics.starts + 1
    self:VisualTick()
    return true
end

function P:Stop(reason)
    if S.Events ~= nil and type(S.Events.UnsubscribeInternalOwner) == "function" then S.Events:UnsubscribeInternalOwner(self) end
    local releaseOk, releaseErr = true, nil
    if self.consumerHeld then
        releaseOk, releaseErr = Feature:ReleaseConsumer(self.consumerToken)
        if releaseOk == true then self.consumerHeld = false end
    end
    self.running = false
    self:HideAll()
    self.metrics.stops = self.metrics.stops + 1
    -- Keep consumerHeld true on a failed release so diagnostics/reconcile retain
    -- evidence of the leaked lease and a later Stop can retry the release.
    if releaseOk ~= true then return false, releaseErr or "状态显示 Consumer 释放失败" end
    return true
end

function P:Reconcile(reason)
    local settings = Settings()
    local shouldRun = FeatureEnabled() and settings.headEnabled ~= false and HasRenderableComponents(settings)
    if shouldRun then
        if self.running ~= true then return self:Start() end
        local ok, err = self:EnsurePools(settings)
        if ok ~= true then return false, err end
        return self:VisualTick()
    end
    return self:Stop(reason or "reconcile")
end

-- RU-side triage surface: answers "is the head renderer running, and if the
-- plates are hidden, why?" without needing in-game console digging.
function P:GetDiagnostics()
    local laneData = Feature and Feature.laneData or nil
    local function Lane(scope) return type(laneData) == "table" and laneData[scope] or nil end
    return {
        version = self.version,
        running = self.running == true,
        consumerHeld = self.consumerHeld == true,
        poolsAllocated = tonumber(self.metrics.allocated) or 0,
        starts = tonumber(self.metrics.starts) or 0,
        stops = tonumber(self.metrics.stops) or 0,
        ticks = tonumber(self.metrics.ticks) or 0,
        projections = tonumber(self.metrics.projections) or 0,
        anchorFailures = self.metrics.anchorFailures,
        source = { player = Lane("player") and Lane("player").source or nil,
                   target = Lane("target") and Lane("target").source or nil },
        anchor = { player = Lane("player") and Lane("player").x or nil,
                   target = Lane("target") and Lane("target").x or nil },
        projectError = { player = Lane("player") and Lane("player").projectErr or nil,
                         target = Lane("target") and Lane("target").projectErr or nil },
    }
end

if type(S.Events.SubscribeInternal) == "function" then
    if type(S.Events.UnsubscribeInternalOwner) == "function" then S.Events:UnsubscribeInternalOwner(P.lifecycleOwner) end
    S.Events:SubscribeInternal("v3.feature.lifecycle", P.lifecycleOwner, function(_, featureId)
        if tostring(featureId or "") == "combat_buff_display" then P:Reconcile("feature_lifecycle") end
    end)
    S.Events:SubscribeInternal("v3.buff_display.settings", P.lifecycleOwner, function() P:Reconcile("settings_global") end)
end

-- Contract 5: health-bar proxy anchor layout via pure ComputePlateLayout;
-- class contributes name text only (no role icon); equipment collapses when
-- absent; right flank defaults to wings (ranged opt-in); x/y are local offsets.
Feature.BuffHeadMarkerContractVersion = 5
P:Reconcile("load")
