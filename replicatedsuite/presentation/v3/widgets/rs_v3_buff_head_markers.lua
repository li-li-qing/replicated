------------------------------------------------------------------------
-- Replicated Suite V3 - Enhanced Plates Head Renderer (v2)
--
-- Ten independent world-space components over the player/target head:
-- Buffs / Debuffs / Distance / Class / Gear Score / Main Hand / Off Hand /
-- Ranged / Wings / Cast Bar. Every component reads its own enabled flag,
-- position (x/y), size, font size and alpha from the BuffDisplay store, and
-- is rendered only when it is enabled AND the owning runtime lane published
-- fresh data. The Feature owns all scheduler lanes; this presenter only keeps
-- bounded widget pools and re-renders on the "plates.updated" event, so
-- disabling a component releases its data immediately and stops its lane.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local Feature = S.Features and S.Features.BuffDisplay or nil
if type(Feature) ~= "table" or type(S.UI) ~= "table" or type(S.Events) ~= "table" then return end

S.UIV3 = S.UIV3 or {}
S.UIV3.BuffHeadMarkersV3 = S.UIV3.BuffHeadMarkersV3 or {}
local P = S.UIV3.BuffHeadMarkersV3
P.version = 2
P.owner = "v3:buff_head_markers"
P.consumerToken = "presentation:buff_head_markers"
P.running = P.running == true
P.consumerHeld = P.consumerHeld == true
P.pools = P.pools or { player = { icons = {}, labels = {}, cast = nil }, target = { icons = {}, labels = {}, cast = nil } }
P.lifecycleOwner = P.lifecycleOwner or {}
P.metrics = P.metrics or { starts=0, stops=0, ticks=0, projections=0, allocated=0, anchorFailures={} }

local SCOPES = { "player", "target" }
local ICON_COMPONENTS = { "buffs", "debuffs", "mainHand", "offHand", "ranged", "wings" }
local TEXT_COMPONENTS = { "distance", "class", "gearScore" }
-- Every head component; used by the render gate so non-tracked components
-- (distance/class/gearScore/equipment/castBar) keep rendering even when the
-- user's tracked buff/debuff list is empty (reference-addon "showall" semantics).
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
local function HasTracked(settings)
    local tracked = type(settings.tracked) == "table" and settings.tracked or {}
    return (type(tracked.buff) == "table" and #tracked.buff > 0) or (type(tracked.debuff) == "table" and #tracked.debuff > 0)
end
-- Render gate: the head display must start as long as headEnabled and at least
-- one component is enabled. HasTracked() is deliberately NOT a gate here --
-- buffs/debuffs rows are bounded by ProjectPlates to tracked rows, so an empty
-- tracked list simply renders zero icons while distance/class/gearScore/
-- equipment/castBar keep working (mirrors the reference addons' show-all mode).
local function HasRenderableComponents(settings)
    local components = type(settings.components) == "table" and settings.components or {}
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
    local stack = S.UI:CreateLabel(root, "v3_buff_head_" .. scope .. "_stack_" .. tostring(index), "", 0, 0, 18, 14, 9, "strong", "RIGHT", true)
    local time = S.UI:CreateLabel(root, "v3_buff_head_" .. scope .. "_time_" .. tostring(index), "", 0, 0, 40, 12, 8, "default", "CENTER", true)
    if icon == nil or stack == nil or time == nil then
        S.UI:SetVisible(root, false, P.owner)
        return nil, "buff_head_marker_child_create_failed"
    end
    S.UI:SetVisible(root, false, P.owner)
    return { root=root, icon=icon, stack=stack, time=time, iconPath=nil, layout={} }
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

local function RequiredIconCount(settings)
    local maxIcons = math.max(1, math.min(12, math.floor(N(settings.headMaxIcons, 8))))
    return maxIcons * 2 + 4
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
        for index = #pool.labels + 1, #TEXT_COMPONENTS do
            local label, err = MakeLabel(scope, index)
            if label == nil then return false, err end
            pool.labels[index] = label
            self.metrics.allocated = self.metrics.allocated + 1
        end
        if pool.cast == nil then
            local cast, err = MakeCastBar(scope)
            if cast == nil then return false, err end
            pool.cast = cast
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
    for _, label in ipairs(pool.labels) do if label.root then S.UI:SetVisible(label.root, false, P.owner) end end
    if pool.cast then S.UI:SetVisible(pool.cast.root, false, P.owner) end
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
    local totalH = size + (showTime and 12 or 0)
    S.UI:SetExtent(marker.root, size, totalH, P.owner)
    S.UI:SetExtent(marker.icon, size, size, P.owner)
    S.UI:SetAnchor(marker.icon, marker.root, 0, 0, P.owner)
    S.UI:SetAnchor(marker.stack, marker.root, 0, 0, P.owner)
    S.UI:SetExtent(marker.stack, size - 2, math.max(12, math.floor(size * 0.5)), P.owner)
    S.UI:SetAnchor(marker.time, marker.root, 0, size, P.owner)
    S.UI:SetExtent(marker.time, size, 12, P.owner)
    S.UI:SetFontSize(marker.stack, math.max(8, math.floor(size * 0.34)), P.owner)
    S.UI:SetFontSize(marker.time, math.max(7, math.floor(size * 0.3)), P.owner)
    S.UI:SetVisible(marker.stack, showStacks, P.owner)
    S.UI:SetVisible(marker.time, showTime, P.owner)
end

local function TextWidth(text, fontSize)
    return math.max(24, math.floor(#tostring(text or "") * (fontSize or 10) * 0.62) + 8)
end

local function ApplyIcon(marker, row, size, cfg, x, y, showStacks, showTime)
    LayoutIcon(marker, size, showStacks, showTime)
    if type(cfg) == "table" then S.UI:SetAlpha(marker.root, math.max(0.1, math.min(1, N(cfg.alpha, 1))), P.owner) end
    local path = tostring(row and row.iconPath or "")
    if path ~= marker.iconPath then
        S.UI:SetIconTexture(marker.icon, path ~= "" and path or UNKNOWN_ICON, P.owner)
        marker.iconPath = path
    end
    marker.stack:SetText((showStacks and N(row.stack, 1) > 1) and tostring(math.floor(N(row.stack, 1))) or "")
    marker.time:SetText(showTime and tostring(row.timeText or "--") or "")
    S.UI:SetAnchor(marker.root, UIParent, x, y, P.owner)
    S.UI:SetVisible(marker.root, true, P.owner)
end

-- Render a horizontal icon row for a component; returns how many slots used.
local function RenderIconRow(scope, pool, rows, cfg, anchorX, anchorY, showStacks, showTime, slotOffset)
    local used = 0
    local size = math.max(8, math.floor(N(cfg.size, 24)))
    local gap = 2
    local count = math.min(#rows, math.floor(N(pool.maxIcons or 8, 8)))
    local totalW = count * size + math.max(0, count - 1) * gap
    local startX = math.floor(anchorX + N(cfg.x, 0) - totalW / 2)
    local startY = math.floor(anchorY + N(cfg.y, -54))
    for index = 1, count do
        local marker = pool.icons[slotOffset + index]
        if marker == nil then break end
        ApplyIcon(marker, rows[index], size, cfg, startX + (index - 1) * (size + gap), startY, showStacks, showTime)
        used = used + 1
    end
    return used
end

------------------------------------------------------------------------
-- Render
------------------------------------------------------------------------

local function RenderCastBar(scope, cast, cfg, anchorX, anchorY)
    local pool = P.pools[scope]
    if pool == nil or pool.cast == nil or cast == nil then return end
    local bar = pool.cast
    local barW = 120
    local barH = math.max(4, math.floor(N(cfg.size, 6)))
    local alpha = math.max(0.1, math.min(1, N(cfg.alpha, 1)))
    local ratio = math.max(0, math.min(1, cast.totalMs > 0 and (cast.currMs / cast.totalMs) or 0))
    local x = math.floor(anchorX + N(cfg.x, 0) - barW / 2)
    local y = math.floor(anchorY + N(cfg.y, -40))
    local cache = bar.layout
    if cache.alpha ~= alpha then S.UI:SetAlpha(bar.root, alpha, P.owner); cache.alpha = alpha end
    S.UI:SetAnchor(bar.root, UIParent, x, y, P.owner)
    S.UI:SetExtent(bar.root, barW, barH, P.owner)
    S.UI:SetAnchor(bar.bg, bar.root, 0, 0, P.owner)
    S.UI:SetExtent(bar.bg, barW, barH, P.owner)
    S.UI:SetAnchor(bar.fill, bar.root, 0, 0, P.owner)
    S.UI:SetExtent(bar.fill, math.max(1, math.floor(barW * ratio)), barH, P.owner)
    bar.text:SetText(cast.spellName or "")
    S.UI:SetFontSize(bar.text, math.max(8, math.floor(N(cfg.fontSize, 10))), P.owner)
    S.UI:SetAnchor(bar.text, bar.root, 0, barH + 1, P.owner)
    S.UI:SetExtent(bar.text, barW, 14, P.owner)
    S.UI:SetVisible(bar.root, true, P.owner)
end

local function RenderTextComponent(scope, key, value, cfg, anchorX, anchorY)
    local pool = P.pools[scope]
    if pool == nil or value == nil then return end
    local index = 1
    for i, componentKey in ipairs(TEXT_COMPONENTS) do if componentKey == key then index = i break end end
    local label = pool.labels[index]
    if label == nil then return end
    local fontSize = math.max(7, math.floor(N(cfg.fontSize, 10)))
    local width = TextWidth(value, fontSize)
    label.root:SetText(tostring(value))
    S.UI:SetFontSize(label.root, fontSize, P.owner)
    S.UI:SetAlpha(label.root, math.max(0.1, math.min(1, N(cfg.alpha, 1))), P.owner)
    S.UI:SetExtent(label.root, width, math.max(12, fontSize + 4), P.owner)
    S.UI:SetAnchor(label.root, UIParent, math.floor(anchorX + N(cfg.x, 0) - width / 2), math.floor(anchorY + N(cfg.y, 0)), P.owner)
    S.UI:SetVisible(label.root, true, P.owner)
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
    local showStacks = settings.headShowStacks ~= false
    local showTime = settings.headShowTime ~= false
    local maxIcons = math.max(1, math.min(12, math.floor(N(settings.headMaxIcons, 8))))
    pool.maxIcons = maxIcons

    -- icon components: buffs/debuffs rows + equipment singles
    local slot = 0
    local buffCfg = components.buffs or {}
    local debuffCfg = components.debuffs or {}
    if buffCfg.enabled ~= false then
        slot = slot + RenderIconRow(scope, pool, plates.buffs or {}, buffCfg, anchorX, anchorY, showStacks, showTime, slot)
    end
    if debuffCfg.enabled ~= false then
        slot = slot + RenderIconRow(scope, pool, plates.debuffs or {}, debuffCfg, anchorX, anchorY, showStacks, showTime, slot)
    end
    for _, key in ipairs({ "mainHand", "offHand", "ranged", "wings" }) do
        local cfg = components[key] or {}
        local item = plates[key] or {}
        if cfg.enabled ~= false and item.icon ~= nil then
            local marker = pool.icons[slot + 1]
            if marker ~= nil then
                local size = math.max(8, math.floor(N(cfg.size, 18)))
                local x = math.floor(anchorX + N(cfg.x, 0) - size / 2)
                local y = math.floor(anchorY + N(cfg.y, 0))
                ApplyIcon(marker, { iconPath = item.icon, stack = nil, timeText = nil }, size, cfg, x, y, false, false)
                slot = slot + 1
            end
        end
    end
    for index = slot + 1, #pool.icons do HideIcon(pool.icons[index]) end

    -- text components
    for _, key in ipairs(TEXT_COMPONENTS) do
        local cfg = components[key] or {}
        local value = plates[key] and plates[key].value or nil
        if cfg.enabled ~= false then
            RenderTextComponent(scope, key, value, cfg, anchorX, anchorY)
        end
    end
    for _, label in ipairs(pool.labels) do
        local key = TEXT_COMPONENTS[_]
        local cfg = type(components[key]) == "table" and components[key] or {}
        if cfg.enabled == false or (plates[key] and plates[key].value == nil) then
            S.UI:SetVisible(label.root, false, P.owner)
        end
    end

    -- cast bar
    local castCfg = components.castBar or {}
    if castCfg.enabled ~= false and plates.cast ~= nil then
        RenderCastBar(scope, plates.cast, castCfg, anchorX, anchorY)
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
    -- cadence (down to 1 ms); the renderer is event-driven, no own task.
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
    if self.consumerHeld then Feature:ReleaseConsumer(self.consumerToken) end
    self.consumerHeld, self.running = false, false
    self:HideAll()
    self.metrics.stops = self.metrics.stops + 1
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

-- Contract 3: render gate decoupled from the tracked list (HasRenderableComponents
-- replaces HasTracked as the start gate) + GetDiagnostics() triage surface +
-- metrics.anchorFailures trail on hidden scopes.
Feature.BuffHeadMarkerContractVersion = 3
P:Reconcile("load")
