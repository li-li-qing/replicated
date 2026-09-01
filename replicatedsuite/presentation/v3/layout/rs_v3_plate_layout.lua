------------------------------------------------------------------------
-- Replicated Suite V3 - Plate Layout Model (Modern V2)
--
-- Pure geometry module. No widgets, no native API, no store mutation.
--
-- Architecture:
--   Settings → BuildPolicy → PlateSnapshot → ComputeLocalLayout
--   → cached LocalGeometry → ScreenAnchor → ProjectToScreen → Diff → Pool
--
-- Region model (content-driven, adaptive):
--   Plate
--   ├── TopInfoRegion     (class · gear · distance segments)
--   ├── BuffRegion        (multi-row, upward from bar)
--   ├── CoreRegion        (leftEquip | healthBarProxy | rightEquip)
--   ├── CastRegion        (between bar and debuff; collapses when idle)
--   └── DebuffRegion      (multi-row, downward from bar/cast)
--
-- All coordinates are LOCAL to the bar center. Screen projection is a
-- separate step so anchor movement never triggers layout recomputation.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite

S.UIV3 = S.UIV3 or {}
S.UIV3.PlateLayout = S.UIV3.PlateLayout or {}
local L = S.UIV3.PlateLayout
L.version = 2

local function N(v, fb) return tonumber(v) or tonumber(fb) or 0 end
local function Clamp(v, lo, hi, fb)
    v = tonumber(v) or tonumber(fb) or lo
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end
local function Max(a, b) return a > b and a or b end
local function Min(a, b) return a < b and a or b end
local function Floor(v) return math.floor(v + 0.5) end

------------------------------------------------------------------------
-- Presets
------------------------------------------------------------------------

-- All presets use 1.5× baseline sizes (icons 36, equip 33) as the new default.
L.PRESETS = {
    compact = {
        label = "紧凑",
        plateScale = 0.85,
        plate = { width = 180, height = 24 },
        info = { fontSize = 13 },
        buffs = { size = 27, spacing = 2, maxPerRow = 6, maxRows = 1 },
        debuffs = { size = 27, spacing = 2, maxPerRow = 6, maxRows = 1 },
        equipment = { size = 27, gap = 3 },
        castBar = { width = 135, height = 6, fontSize = 12 },
        gaps = { buffToBar = 8, debuffToBar = 8, infoToBuff = 6, equipToBar = 6, castToBar = 6, castToDebuff = 5, rowGap = 3 },
    },
    standard = {
        label = "标准",
        plateScale = 1.0,
        plate = { width = 225, height = 30 },
        info = { fontSize = 15 },
        buffs = { size = 36, spacing = 3, maxPerRow = 8, maxRows = 2 },
        debuffs = { size = 36, spacing = 3, maxPerRow = 8, maxRows = 2 },
        equipment = { size = 33, gap = 5 },
        castBar = { width = 180, height = 9, fontSize = 15 },
        gaps = { buffToBar = 11, debuffToBar = 11, infoToBuff = 9, equipToBar = 9, castToBar = 8, castToDebuff = 6, rowGap = 5 },
    },
    information = {
        label = "信息",
        plateScale = 1.1,
        plate = { width = 270, height = 33 },
        info = { fontSize = 18 },
        buffs = { size = 39, spacing = 3, maxPerRow = 10, maxRows = 3 },
        debuffs = { size = 39, spacing = 3, maxPerRow = 10, maxRows = 3 },
        equipment = { size = 36, gap = 5 },
        castBar = { width = 225, height = 11, fontSize = 17 },
        gaps = { buffToBar = 12, debuffToBar = 12, infoToBuff = 11, equipToBar = 11, castToBar = 9, castToDebuff = 8, rowGap = 5 },
    },
}

-- Apply a preset as a one-shot write into settings. Does NOT lock future edits.
function L.ApplyPreset(presetName, currentSettings)
    local preset = L.PRESETS[presetName]
    if preset == nil then return currentSettings end
    local out = type(currentSettings) == "table" and currentSettings or {}
    out.plateScale = preset.plateScale
    out.plate = out.plate or {}
    out.plate.width = preset.plate.width
    out.plate.height = preset.plate.height
    out.info = out.info or {}
    out.info.fontSize = preset.info.fontSize
    -- Components
    out.components = out.components or {}
    for _, key in ipairs({ "buffs", "debuffs" }) do
        out.components[key] = out.components[key] or {}
        out.components[key].size = preset[key].size
        out.components[key].spacing = preset[key].spacing
        out.components[key].maxPerRow = preset[key].maxPerRow
        out.components[key].maxRows = preset[key].maxRows
    end
    for _, key in ipairs({ "mainHand", "offHand", "wings", "ranged" }) do
        out.components[key] = out.components[key] or {}
        out.components[key].size = preset.equipment.size
    end
    out.components.castBar = out.components.castBar or {}
    out.components.castBar.width = preset.castBar.width
    out.components.castBar.size = preset.castBar.height
    out.components.castBar.fontSize = preset.castBar.fontSize
    -- Gaps stored as region offsets for advanced users
    out.gaps = preset.gaps
    out.layoutPresetName = presetName
    return out
end

------------------------------------------------------------------------
-- BuildPolicy: settings → resolved layout parameters
------------------------------------------------------------------------

-- User-verified equipment grouping (M1.16.0.18.50+):
--   Visual L→R : [mainHand][offHand][ranged] [bar] [wings]
--   Left flank build order is reversed because EquipSlots() places the first
--   item closest to the bar edge (direction=-1 moves leftward).
--   Right flank : wings only.
local SLOT_ORDER_LEFT = { "ranged", "offHand", "mainHand" }
local SLOT_ORDER_RIGHT = { "wings" }

function L.BuildPolicy(settings)
    settings = type(settings) == "table" and settings or {}
    local scale = Clamp(N(settings.plateScale), 0.5, 2.0, 1.0)
    local components = type(settings.components) == "table" and settings.components or {}
    local plateCfg = type(settings.plate) == "table" and settings.plate or {}
    local infoCfg = type(settings.info) == "table" and settings.info or {}
    local gaps = type(settings.gaps) == "table" and settings.gaps or L.PRESETS.standard.gaps

    local function Comp(key) return type(components[key]) == "table" and components[key] or {} end
    local function Gap(name) return Max(0, Floor(N(gaps[name], L.PRESETS.standard.gaps[name]) * scale)) end

    local buffCfg = Comp("buffs")
    local debuffCfg = Comp("debuffs")
    local buffSize = Max(8, Floor(N(buffCfg.size, 36) * scale))
    local debuffSize = Max(8, Floor(N(debuffCfg.size, 36) * scale))
    local equipSize = Max(8, Floor(N(Comp("mainHand").size, 33) * scale))
    local equipGap = Max(1, Floor(N(gaps.equipToBar, 9) * scale))

    return {
        scale = scale,
        bar = {
            width = Max(24, Floor(N(plateCfg.width, 225) * scale)),
            height = Max(8, Floor(N(plateCfg.height, 30) * scale)),
            offsetX = Floor(N(plateCfg.x, 0) * scale),
            offsetY = Floor(N(plateCfg.y, 22) * scale),
        },
        info = {
            enabled = infoCfg.enabled ~= false,
            fontSize = Max(8, Floor(N(infoCfg.fontSize, 15) * scale)),
            showClass = infoCfg.showClass ~= false,
            showGear = infoCfg.showGear ~= false,
            showDistance = infoCfg.showDistance ~= false,
            offsetX = Floor(N(infoCfg.x, 0) * scale),
            offsetY = Floor(N(infoCfg.y, 0) * scale),
        },
        buff = {
            enabled = buffCfg.enabled ~= false,
            size = buffSize,
            spacing = Max(0, Floor(N(buffCfg.spacing, 3) * scale)),
            maxPerRow = Clamp(N(buffCfg.maxPerRow, 8), 1, 16),
            maxRows = Clamp(N(buffCfg.maxRows, 2), 1, 4),
            rowPitch = buffSize + Gap("rowGap"),
            gapToBar = Gap("buffToBar"),
            offsetX = Floor(N(buffCfg.x, 0) * scale),
            offsetY = Floor(N(buffCfg.y, 0) * scale),
        },
        debuff = {
            enabled = debuffCfg.enabled ~= false,
            size = debuffSize,
            spacing = Max(0, Floor(N(debuffCfg.spacing, 3) * scale)),
            maxPerRow = Clamp(N(debuffCfg.maxPerRow, 8), 1, 16),
            maxRows = Clamp(N(debuffCfg.maxRows, 2), 1, 4),
            rowPitch = debuffSize + Gap("rowGap"),
            gapToBar = Gap("debuffToBar"),
            offsetX = Floor(N(debuffCfg.x, 0) * scale),
            offsetY = Floor(N(debuffCfg.y, 0) * scale),
        },
        equip = {
            size = equipSize,
            gap = Max(1, Floor(N(gaps.equipToBar, 3) * scale)),
            gapToBar = equipGap,
            leftOrder = SLOT_ORDER_LEFT,
            rightOrder = SLOT_ORDER_RIGHT,
        },
        cast = {
            enabled = Comp("castBar").enabled ~= false,
            width = Max(24, Floor(N(Comp("castBar").width, 180) * scale)),
            height = Max(3, Floor(N(Comp("castBar").size, 9) * scale)),
            fontSize = Max(8, Floor(N(Comp("castBar").fontSize, 15) * scale)),
            showText = Comp("castBar").showText ~= false,
            gapToBar = Gap("castToBar"),
            gapToDebuff = Gap("castToDebuff"),
            offsetX = Floor(N(Comp("castBar").x, 0) * scale),
            offsetY = Floor(N(Comp("castBar").y, 0) * scale),
        },
        gaps = {
            infoToBuff = Gap("infoToBuff"),
            infoToBar = Max(4, Floor(N(gaps.infoToBuff, 8) * scale)),
        },
    }
end

------------------------------------------------------------------------
-- Info Segments (priority-ordered, degradable)
------------------------------------------------------------------------

local INFO_SEGMENTS = {
    { key = "class",    priority = 1, field = "value" },
    { key = "gearScore", priority = 2, field = "value" },
    { key = "distance",  priority = 3, field = "value" },
}

-- Build info text with graceful degradation when space is tight.
-- Returns { text, segmentCount }.
function L.BuildInfoText(snapshot, policy, maxWidth)
    if policy.info.enabled ~= true then return "", 0 end
    maxWidth = tonumber(maxWidth) or 300
    local parts = {}
    local count = 0
    for _, seg in ipairs(INFO_SEGMENTS) do
        local cfgKey = seg.key
        local showKey = "show" .. cfgKey:sub(1, 1):upper() .. cfgKey:sub(2)
        if policy.info[showKey] ~= false then
            local data = type(snapshot[cfgKey]) == "table" and snapshot[cfgKey] or {}
            local val = data[seg.field]
            if val ~= nil and tostring(val) ~= "" then
                parts[#parts + 1] = tostring(val)
                count = count + 1
            end
        end
    end
    if count == 0 then return "", 0 end
    -- Try full text first; degrade by dropping lowest-priority segments
    local text = table.concat(parts, " · ")
    local estWidth = #text * (policy.info.fontSize or 10) * 0.62 + 8
    while estWidth > maxWidth and #parts > 1 do
        parts[#parts] = nil
        count = count - 1
        text = table.concat(parts, " · ")
        estWidth = #text * (policy.info.fontSize or 10) * 0.62 + 8
    end
    return text, count
end

------------------------------------------------------------------------
-- Stable Buff/Debuff Sort Key
------------------------------------------------------------------------

-- Produces a stable sort key so icons never shuffle between frames.
-- Priority: tracked > configured priority > id (stable).
-- Time changes do NOT affect order.
function L.StableSortKey(row, trackedSet)
    local id = tonumber(row and row.id) or 0
    local tracked = trackedSet and trackedSet[id] == true
    local priority = tonumber(row and row.priority) or 0
    -- Tracked items sort first (tracked=0 < untracked=1), then by configured
    -- priority descending, then by id ascending for stability.
    return string.format("%d:%04d:%08d", tracked and 0 or 1, 9999 - priority, id)
end

-- Sort rows in-place using stable keys. Returns the same table.
function L.SortRowsStable(rows, trackedSet)
    if type(rows) ~= "table" or #rows <= 1 then return rows end
    local keys = {}
    for i, row in ipairs(rows) do keys[i] = L.StableSortKey(row, trackedSet) end
    table.sort(rows, function(a, b)
        local ka = keys[a._origIndex] or L.StableSortKey(a, trackedSet)
        local kb = keys[b._origIndex] or L.StableSortKey(b, trackedSet)
        return ka < kb
    end)
    return rows
end

------------------------------------------------------------------------
-- ComputeLocalLayout: pure geometry, all coords relative to bar center
------------------------------------------------------------------------

-- Inputs:
--   policy    : from BuildPolicy()
--   snapshot  : { buffs={}, debuffs={}, class={}, gearScore={}, distance={},
--               mainHand={}, offHand={}, wings={}, ranged={}, cast={} }
-- Returns:
--   layout    : { bar, info, buff, debuff, cast, leftEquip, rightEquip, bounds }
--   All x/y are LOCAL offsets from bar center (0,0).
function L.ComputeLocalLayout(policy, snapshot)
    policy = type(policy) == "table" and policy or L.BuildPolicy({})
    snapshot = type(snapshot) == "table" and snapshot or {}

    local barW = policy.bar.width
    local barH = policy.bar.height
    local bar = { x = 0, y = 0, width = barW, height = barH,
                  left = -Floor(barW / 2), right = Floor(barW / 2),
                  top = -Floor(barH / 2), bottom = Floor(barH / 2) }

    -- Equipment slots (flow layout, collapse absent slots)
    local function EquipSlots(order, direction)
        local slots = {}
        local edge = direction < 0 and bar.left or bar.right
        for _, key in ipairs(order) do
            local item = snapshot[key]
            if item ~= nil and item.icon ~= nil then
                local size = policy.equip.size
                local gap = policy.equip.gap
                local x
                if direction < 0 then
                    x = edge - gap - size
                else
                    x = edge + gap
                end
                local y = -Floor(size / 2)  -- vertically centered on bar
                slots[#slots + 1] = { key = key, x = x, y = y, size = size }
                edge = direction < 0 and x or (x + size)
            end
        end
        return slots
    end
    local leftSlots = EquipSlots(policy.equip.leftOrder, -1)
    local rightSlots = EquipSlots(policy.equip.rightOrder, 1)

    -- Buff rows (upward from bar.top)
    local buffRows = type(snapshot.buffs) == "table" and snapshot.buffs or {}
    local buffCount = policy.buff.enabled and #buffRows or 0
    local buffTotal = Min(buffCount, policy.buff.maxPerRow * policy.buff.maxRows)
    local buffActualRows = buffTotal > 0 and Min(policy.buff.maxRows, math.ceil(buffTotal / policy.buff.maxPerRow)) or 0
    local buffFirstTop = bar.top - policy.buff.gapToBar - policy.buff.size
    local buffTopMostTop = buffFirstTop - (buffActualRows - 1) * policy.buff.rowPitch

    -- Cast region (between bar and debuff; collapses when not casting)
    local castActive = policy.cast.enabled and snapshot.cast ~= nil
    local castY = bar.bottom + policy.cast.gapToBar
    local castH = castActive and policy.cast.height or 0

    -- Debuff rows (downward from cast bottom or bar.bottom)
    local debuffBaseBottom = castActive and (castY + castH + policy.cast.gapToDebuff) or bar.bottom
    local debuffRows = type(snapshot.debuffs) == "table" and snapshot.debuffs or {}
    local debuffCount = policy.debuff.enabled and #debuffRows or 0
    local debuffTotal = Min(debuffCount, policy.debuff.maxPerRow * policy.debuff.maxRows)
    local debuffActualRows = debuffTotal > 0 and Min(policy.debuff.maxRows, math.ceil(debuffTotal / policy.debuff.maxPerRow)) or 0
    local debuffFirstTop = debuffBaseBottom + policy.debuff.gapToBar

    -- Info row (above topmost actual buff row, or above bar if no buffs)
    local infoH = policy.info.fontSize + 4
    local infoRefTop = buffActualRows > 0 and buffTopMostTop or bar.top
    local infoGap = buffActualRows > 0 and policy.gaps.infoToBuff or policy.gaps.infoToBar
    local infoTop = infoRefTop - infoGap - infoH

    -- Bounds (for screen-safe clamping)
    local boundsLeft = bar.left
    local boundsRight = bar.right
    for _, s in ipairs(leftSlots) do boundsLeft = Min(boundsLeft, s.x) end
    for _, s in ipairs(rightSlots) do boundsRight = Max(boundsRight, s.x + s.size) end
    local boundsTop = infoTop
    local boundsBottom = debuffFirstTop + debuffActualRows * policy.debuff.rowPitch

    return {
        bar = bar,
        info = {
            visible = policy.info.enabled,
            x = policy.info.offsetX,
            y = infoTop + policy.info.offsetY,
            width = 0,  -- computed at render time from text
            height = infoH,
            font = policy.info.fontSize,
        },
        buff = {
            visible = buffActualRows > 0,
            firstTop = buffFirstTop + policy.buff.offsetY,
            rowPitch = policy.buff.rowPitch,
            size = policy.buff.size,
            spacing = policy.buff.spacing,
            maxPerRow = policy.buff.maxPerRow,
            actualRows = buffActualRows,
            totalIcons = buffTotal,
            topMostTop = buffTopMostTop,
            centerX = policy.buff.offsetX,
        },
        debuff = {
            visible = debuffActualRows > 0,
            firstTop = debuffFirstTop + policy.debuff.offsetY,
            rowPitch = policy.debuff.rowPitch,
            size = policy.debuff.size,
            spacing = policy.debuff.spacing,
            maxPerRow = policy.debuff.maxPerRow,
            actualRows = debuffActualRows,
            totalIcons = debuffTotal,
            centerX = policy.debuff.offsetX,
        },
        cast = {
            visible = castActive,
            x = policy.cast.offsetX,
            y = castY + policy.cast.offsetY,
            width = policy.cast.width,
            height = policy.cast.height,
            font = policy.cast.fontSize,
            showText = policy.cast.showText,
        },
        leftEquip = { slots = leftSlots },
        rightEquip = { slots = rightSlots },
        bounds = { left = boundsLeft, right = boundsRight, top = boundsTop, bottom = boundsBottom },
        scale = policy.scale,
    }
end

------------------------------------------------------------------------
-- ProjectToScreen: local layout + anchor → screen coordinates
------------------------------------------------------------------------

function L.ProjectToScreen(localLayout, anchorX, anchorY)
    if localLayout == nil then return nil end
    local ax = Floor(N(anchorX))
    local ay = Floor(N(anchorY))
    -- Deep copy with offset applied. Only the top-level position fields need
    -- translation; internal relative positions stay as-is.
    local out = {}
    for k, v in pairs(localLayout) do out[k] = v end
    out.screenAnchor = { x = ax, y = ay }
    out.bar = {
        x = ax, y = ay,
        width = localLayout.bar.width, height = localLayout.bar.height,
        left = ax + localLayout.bar.left, right = ax + localLayout.bar.right,
        top = ay + localLayout.bar.top, bottom = ay + localLayout.bar.bottom,
    }
    out.info = {
        visible = localLayout.info.visible,
        x = ax + localLayout.info.x,
        y = ay + localLayout.info.y,
        width = localLayout.info.width,
        height = localLayout.info.height,
        font = localLayout.info.font,
    }
    out.buff = localLayout.buff
    out.buff.screenFirstTop = ay + localLayout.buff.firstTop
    out.debuff = localLayout.debuff
    out.debuff.screenFirstTop = ay + localLayout.debuff.firstTop
    out.cast = {
        visible = localLayout.cast.visible,
        x = ax + localLayout.cast.x - Floor(localLayout.cast.width / 2),
        y = ay + localLayout.cast.y,
        width = localLayout.cast.width,
        height = localLayout.cast.height,
        font = localLayout.cast.font,
        showText = localLayout.cast.showText,
    }
    -- Equipment slots: translate each slot's local x/y to screen
    local function TranslateSlots(slots)
        local out = {}
        for i, s in ipairs(slots) do
            out[i] = { key = s.key, x = ax + s.x, y = ay + s.y, size = s.size }
        end
        return out
    end
    out.leftEquip = { slots = TranslateSlots(localLayout.leftEquip.slots) }
    out.rightEquip = { slots = TranslateSlots(localLayout.rightEquip.slots) }
    out.bounds = {
        left = ax + localLayout.bounds.left,
        right = ax + localLayout.bounds.right,
        top = ay + localLayout.bounds.top,
        bottom = ay + localLayout.bounds.bottom,
    }
    return out
end

------------------------------------------------------------------------
-- Screen-safe clamping (group-level, never per-icon)
------------------------------------------------------------------------

function L.ClampLayoutToScreen(layout, screenWidth, screenHeight, padding)
    if layout == nil then return layout end
    padding = N(padding, 2)
    local sw = N(screenWidth, 1024)
    local sh = N(screenHeight, 768)
    -- Horizontal: shift entire layout if bounds exceed screen edges.
    -- Bar anchor stays fixed; only extension regions shift.
    local dx = 0
    if layout.bounds.left < padding then
        dx = padding - layout.bounds.left
    elseif layout.bounds.right > sw - padding then
        dx = (sw - padding) - layout.bounds.right
    end
    if dx ~= 0 then
        -- Shift info, buff rows, debuff rows, equipment groups horizontally.
        -- Bar stays at its anchor position.
        layout.info.x = layout.info.x + dx
        layout.buff.centerX = (layout.buff.centerX or 0) + dx
        layout.debuff.centerX = (layout.debuff.centerX or 0) + dx
        layout.cast.x = layout.cast.x + dx
        for _, s in ipairs(layout.leftEquip.slots) do s.x = s.x + dx end
        for _, s in ipairs(layout.rightEquip.slots) do s.x = s.x + dx end
        layout.bounds.left = layout.bounds.left + dx
        layout.bounds.right = layout.bounds.right + dx
    end
    -- Vertical: clamp top/bottom bounds (info may go off-screen top)
    if layout.bounds.top < padding then
        local dy = padding - layout.bounds.top
        layout.info.y = layout.info.y + dy
        layout.buff.screenFirstTop = (layout.buff.screenFirstTop or 0) + dy
        layout.bounds.top = layout.bounds.top + dy
    end
    if layout.bounds.bottom > sh - padding then
        local dy = (sh - padding) - layout.bounds.bottom
        layout.debuff.screenFirstTop = (layout.debuff.screenFirstTop or 0) + dy
        layout.bounds.bottom = layout.bounds.bottom + dy
    end
    return layout
end

------------------------------------------------------------------------
-- Preview Snapshot Builder (pure function, no native reads)
------------------------------------------------------------------------

function L.BuildPreviewSnapshot(options)
    options = type(options) == "table" and options or {}
    local buffCount = N(options.buffCount, 8)
    local debuffCount = N(options.debuffCount, 3)
    local buffs = {}
    for i = 1, buffCount do
        buffs[i] = {
            id = 900000 + i,
            name = "Preview Buff " .. i,
            iconPath = "ui/icon/icon_skill_buff26.dds",
            stack = (i % 3 == 0) and 3 or 1,
            timeLeft = (10 - i) * 1000,
            timeText = tostring(10 - i),
            category = "buff",
            tracked = i <= 3,
        }
    end
    local debuffs = {}
    for i = 1, debuffCount do
        debuffs[i] = {
            id = 800000 + i,
            name = "Preview Debuff " .. i,
            iconPath = "ui/icon/icon_unknown_item.dds",
            stack = 1,
            timeLeft = (20 - i) * 1000,
            timeText = tostring(20 - i),
            category = "debuff",
        }
    end
    return {
        buffs = buffs,
        debuffs = debuffs,
        class = { value = N(options.className, "幽影刺客") },
        gearScore = { value = N(options.gearScore, 15767) },
        distance = { value = N(options.distance, "18.4m") },
        mainHand = { icon = "ui/icon/icon_weapon_sword.dds", gradeIconPath = "" },
        offHand = { icon = "ui/icon/icon_weapon_shield.dds", gradeIconPath = "" },
        wings = { icon = "ui/icon/icon_equipment_wing.dds", gradeIconPath = "" },
        cast = options.showCast and { spellName = "模拟施法", currMs = 1800, totalMs = 3000 } or nil,
    }
end

------------------------------------------------------------------------
-- Layout Dirty Flag helpers
------------------------------------------------------------------------

-- Generate a cache key from geometry-affecting settings only. Content changes
-- (buff time, distance value) do NOT invalidate the layout cache.
function L.LayoutCacheKey(policy, buffCount, debuffCount, equipMask, castActive)
    return string.format("v2:%.2f:%dx%d:%d/%d:%d/%d:%d:%d:%s",
        policy.scale,
        policy.bar.width, policy.bar.height,
        buffCount, policy.buff.maxPerRow,
        debuffCount, policy.debuff.maxPerRow,
        equipMask or 0,
        castActive and 1 or 0,
        tostring(policy.layoutPresetName or "custom"))
end

-- Equipment bitmask for cache key
function L.EquipMask(snapshot)
    local mask = 0
    if snapshot.mainHand and snapshot.mainHand.icon then mask = mask + 1 end
    if snapshot.offHand and snapshot.offHand.icon then mask = mask + 2 end
    if snapshot.wings and snapshot.wings.icon then mask = mask + 4 end
    if snapshot.ranged and snapshot.ranged.icon then mask = mask + 8 end
    return mask
end

------------------------------------------------------------------------
-- Debug Dump (single-line diagnostic)
------------------------------------------------------------------------

function L.DumpLayout(scope, layout)
    if layout == nil then return string.format("Plate %s: nil", scope or "?") end
    local b = layout.bar or {}
    local buf = layout.buff or {}
    local deb = layout.debuff or {}
    local inf = layout.info or {}
    local cst = layout.cast or {}
    return string.format("Plate %s Bar[%d,%d,%d,%d] Info[y=%d vis=%s] Buff[rows=%d top=%d pitch=%d] Cast[vis=%s y=%d] Debuff[rows=%d top=%d] LeftEq=%d RightEq=%d Bounds[%d,%d,%d,%d]",
        scope or "?",
        b.left or 0, b.top or 0, b.right or 0, b.bottom or 0,
        inf.y or 0, tostring(inf.visible),
        buf.actualRows or 0, buf.firstTop or 0, buf.rowPitch or 0,
        tostring(cst.visible), cst.y or 0,
        deb.actualRows or 0, deb.firstTop or 0,
        #(layout.leftEquip and layout.leftEquip.slots or {}),
        #(layout.rightEquip and layout.rightEquip.slots or {}),
        layout.bounds and layout.bounds.left or 0,
        layout.bounds and layout.bounds.top or 0,
        layout.bounds and layout.bounds.right or 0,
        layout.bounds and layout.bounds.bottom or 0)
end

-- Expose for acceptance tests
L.SLOT_ORDER_LEFT = SLOT_ORDER_LEFT
L.SLOT_ORDER_RIGHT = SLOT_ORDER_RIGHT
