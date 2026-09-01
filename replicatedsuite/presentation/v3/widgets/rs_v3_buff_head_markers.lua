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
P.version = 4
P.owner = "v3:buff_head_markers"
P.consumerToken = "presentation:buff_head_markers"
P.running = P.running == true
P.consumerHeld = P.consumerHeld == true
P.pools = P.pools or { player = { icons = {}, labels = {}, cast = nil, plate = nil, info = nil }, target = { icons = {}, labels = {}, cast = nil, plate = nil, info = nil } }
P.lifecycleOwner = P.lifecycleOwner or {}
P.metrics = P.metrics or { starts=0, stops=0, ticks=0, projections=0, allocated=0, anchorFailures={} }

local SCOPES = { "player", "target" }
local RENDERABLE_KEYS = { "buffs", "debuffs", "distance", "class", "gearScore", "mainHand", "offHand", "ranged", "wings", "castBar", "plate", "info" }
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
    local markerW = size
    local markerH = size + (showTime and 12 or 0)
    local clampedX, clampedY = ClampToScreen(x, y, markerW, markerH)
    S.UI:SetAnchor(marker.root, UIParent, clampedX, clampedY, P.owner)
    S.UI:SetVisible(marker.root, true, P.owner)
end

-- Render a horizontal icon row for a component; returns how many slots used.
-- rowY overrides cfg.y so the caller can auto-stack rows; explicit size/gap
-- support per-row layout (MaxPerRow / MaxRows) without mutating the store.
local function RenderIconRow(scope, pool, rows, cfg, centerX, rowY, showStacks, showTime, slotOffset, size, gap)
    local used = 0
    size = math.max(8, math.floor(tonumber(size) or N(cfg.size, 24)))
    gap = math.max(0, math.floor(tonumber(gap) or N(cfg.spacing, 2)))
    local count = math.min(#rows, 16)
    local totalW = count * size + math.max(0, count - 1) * gap
    local startX = math.floor(centerX + N(cfg.x, 0) - totalW / 2)
    -- Keep the whole row inside the logical screen: a centered row whose anchor
    -- sits near a screen edge would otherwise push half the icons off-screen.
    local rowW = totalW
    local screenW = 1024
    if S.Api ~= nil and type(S.Api.GetUiMetrics) == "function" then
        local sw, sh, scale, lw, lh = S.Api:GetUiMetrics()
        scale = tonumber(scale) or 1
        screenW = tonumber(lw) or ((tonumber(sw) or 1024) / math.max(0.001, scale))
    end
    if rowW < math.max(40, screenW - 4) then
        startX = math.floor(math.max(2, math.min(math.max(2, screenW - rowW - 2), startX)))
    end
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

-- Render one equipment icon flanking the plate. direction -1 stacks leftward
-- (each new icon further left), +1 stacks rightward. Returns the new slot count
-- and the new outward edge so consecutive slots never overlap.
local function RenderEquipSlot(scope, pool, item, cfg, edgeX, centerY, direction, slot, scale)
    if item == nil or item.icon == nil or cfg == nil or cfg.enabled == false then return slot, edgeX end
    local marker = pool.icons[slot + 1]
    if marker == nil then return slot, edgeX end
    local size = math.max(8, math.floor(N(cfg.size, 22) * (scale or 1)))
    local gap = math.max(1, math.floor(N(cfg.gap or cfg.spacing, 4) * (scale or 1)))
    local x
    if direction < 0 then
        x = edgeX - gap - size
    else
        x = edgeX + gap
    end
    local y = centerY - math.floor(size / 2)
    ApplyIcon(marker, { iconPath = item.icon, gradeIconPath = item.gradeIconPath, stack = nil, timeText = nil }, size, cfg, x, y, false, false)
    local newEdge = direction < 0 and x or (x + size)
    return slot + 1, newEdge
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
    local plateCfg = type(settings.plate) == "table" and settings.plate or {}
    local infoCfg = type(settings.info) == "table" and settings.info or {}
    local scale = math.max(0.5, math.min(2, tonumber(settings.plateScale) or 1))
    local showStacks = settings.headShowStacks ~= false
    local showTime = settings.headShowTime ~= false

    -- === Layout: the native health bar is the single anchor ===
    -- The RU API exposes no native unit-frame rectangle, so the anchor is the
    -- unit screen position with a user-adjustable virtual rect (width/height/
    -- x/y) that the player aligns onto the game's own health bar. Nothing is
    -- drawn here — the native bar draws itself.
    local healthW = math.max(24, math.floor(N(plateCfg.width, 150) * scale))
    local healthH = math.max(8, math.floor(N(plateCfg.height, 20) * scale))
    local plateX = anchorX + math.floor(N(plateCfg.x, 0) * scale)
    local plateCenterY = anchorY + math.floor(N(plateCfg.y, 0) * scale)
    local plateLeft = plateX - math.floor(healthW / 2)
    local plateRight = plateLeft + healthW
    local plateTopY = plateCenterY - math.floor(healthH / 2)
    local plateBottomY = plateCenterY + math.floor(healthH / 2)

    -- Buff rows above the plate, stacking upward, bounded by MaxPerRow/MaxRows.
    local buffCfg = components.buffs or {}
    local buffSize = math.max(8, math.floor(N(buffCfg.size, 24) * scale))
    local buffSpacing = math.max(0, math.floor(N(buffCfg.spacing, 2) * scale))
    local buffMaxPerRow = math.max(1, math.min(16, math.floor(N(buffCfg.maxPerRow, 8))))
    local buffMaxRows = math.max(1, math.min(4, math.floor(N(buffCfg.maxRows, 2))))
    local buffRowGap = math.max(1, buffSize + buffSpacing)
    local buffExtraY = math.floor(N(buffCfg.y, 0) * scale)
    local buffFirstTop = plateTopY - buffRowGap + buffExtraY  -- first row above plate

    -- Debuff rows below the plate.
    local debuffCfg = components.debuffs or {}
    local debuffSize = math.max(8, math.floor(N(debuffCfg.size, 24) * scale))
    local debuffSpacing = math.max(0, math.floor(N(debuffCfg.spacing, 2) * scale))
    local debuffMaxPerRow = math.max(1, math.min(16, math.floor(N(debuffCfg.maxPerRow, 8))))
    local debuffMaxRows = math.max(1, math.min(4, math.floor(N(debuffCfg.maxRows, 2))))
    local debuffRowGap = math.max(1, debuffSize + debuffSpacing)
    local debuffExtraY = math.floor(N(debuffCfg.y, 0) * scale)
    local debuffFirstTop = plateBottomY + debuffRowGap + debuffExtraY

    -- Info row above the highest buff row (auto-raises with extra buff rows).
    local infoFont = math.max(8, math.floor(N(infoCfg.fontSize, 10) * scale))
    local infoH = infoFont + 4
    local highestBuffTop = buffFirstTop - (buffMaxRows - 1) * buffRowGap
    local infoY = highestBuffTop - infoH - math.max(3, math.floor(2 * scale)) + math.floor(N(infoCfg.y, 0) * scale)

    -- === Render ===
    local slot = 0
    -- Buff rows
    if buffCfg.enabled ~= false then
        slot = slot + RenderRows(scope, pool, plates.buffs or {}, buffCfg, plateX, buffFirstTop, showStacks, showTime, slot, buffSize, buffSpacing, buffMaxPerRow, buffMaxRows, buffRowGap, -1)
    end
    -- Debuff rows
    if debuffCfg.enabled ~= false then
        slot = slot + RenderRows(scope, pool, plates.debuffs or {}, debuffCfg, plateX, debuffFirstTop, showStacks, showTime, slot, debuffSize, debuffSpacing, debuffMaxPerRow, debuffMaxRows, debuffRowGap, 1)
    end
    -- Equipment left flank (mainHand, offHand): offHand sits right next to the
    -- plate, mainHand further left; each stacks outward from the previous edge.
    local leftEdge = plateLeft
    for _, key in ipairs({ "offHand", "mainHand" }) do
        local cfg = components[key] or {}
        slot, leftEdge = RenderEquipSlot(scope, pool, plates[key], cfg, leftEdge, plateCenterY, -1, slot, scale)
    end
    -- Equipment right flank (wings, ranged): wings next to the plate, ranged
    -- further right; each stacks outward from the previous edge.
    local rightEdge = plateRight
    for _, key in ipairs({ "wings", "ranged" }) do
        local cfg = components[key] or {}
        slot, rightEdge = RenderEquipSlot(scope, pool, plates[key], cfg, rightEdge, plateCenterY, 1, slot, scale)
    end
    -- Class role icon above the info text (optional, mirrors old behavior)
    local classCfg = components.class or {}
    local classPlates = type(plates.class) == "table" and plates.class or {}
    if classCfg.enabled ~= false and type(classPlates.icon) == "string" and classPlates.icon ~= "" then
        local csize = math.max(12, math.floor(N(classCfg.size, 14) * scale))
        local marker = pool.icons[slot + 1]
        if marker ~= nil then
            ApplyIcon(marker, { iconPath = classPlates.icon, stack = nil, timeText = nil }, csize, classCfg, plateX - math.floor(csize / 2), infoY, false, false)
            slot = slot + 1
        end
    end
    for index = slot + 1, #pool.icons do HideIcon(pool.icons[index]) end

    -- Info row
    if infoCfg.enabled ~= false then
        RenderInfo(scope, plates, infoCfg, components, plateX, infoY, infoFont)
    else
        local info = pool.info
        if info then S.UI:SetVisible(info.root, false, P.owner) end
    end

    -- Cast bar (below debuff rows; hidden when casting ends)
    local castCfg = components.castBar or {}
    if castCfg.enabled ~= false and plates.cast ~= nil then
        RenderCastBar(scope, plates.cast, castCfg, plateX, debuffFirstTop + (debuffCfg.enabled ~= false and (debuffMaxRows * debuffRowGap) or 0) + 6, scale)
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

-- Contract 4: render gate is decoupled from tracked state, stale text is
-- fail-closed, and failed Consumer release remains observable/retryable.
Feature.BuffHeadMarkerContractVersion = 4
P:Reconcile("load")
