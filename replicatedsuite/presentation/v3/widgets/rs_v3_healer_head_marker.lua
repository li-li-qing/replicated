------------------------------------------------------------------------
-- Replicated Suite V3 - Healer Head Marker Consumer (M1.16.0.18)
--
-- Independent Presentation Consumer. Recommendation facts are cached only on
-- Domain publish. The 50ms visual task performs bounded world->screen projection
-- and Diff writes; it never creates Native widgets or reads Health/Aura/Roster.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local Feature = S.Features and S.Features.Healer or nil
if type(Feature) ~= "table" or type(S.UI) ~= "table" or type(S.Scheduler) ~= "table" then return end
local FEATURE_ID = "combat_healer"

S.UIV3 = S.UIV3 or {}
S.UIV3.HealerHeadMarker = S.UIV3.HealerHeadMarker or {}
local P = S.UIV3.HealerHeadMarker

P.version = 1
P.owner = "v3:healer_head_marker"
P.consumerToken = "presentation:healer_head_marker"
P.taskName = "v3_healer_head_marker_visual"
P.running = P.running == true
P.consumerHeld = P.consumerHeld == true
P.taskActive = P.taskActive == true
P.pool = P.pool or {}
P.candidates = P.candidates or {}
P.settings = P.settings or nil
P.lastActive = tonumber(P.lastActive) or 0
P.metrics = P.metrics or { starts=0, stops=0, refreshes=0, ticks=0, projections=0, projectionFailures=0, allocated=0 }
P.activeOwner = P.activeOwner or {}

local function N(value, fallback) return tonumber(value) or tonumber(fallback) or 0 end
local function Settings()
    local value = type(Feature.GetPresentationProjection) == "function" and Feature:GetPresentationProjection("head") or nil
    return type(value) == "table" and value or { enabled=false, count=5, effectMode=1, shapeMode=4, sizes={18,24,30,36}, refreshMs=50 }
end
local function FeatureEnabled()
    return S.FeatureRuntime ~= nil and S.FeatureRuntime:IsEnabled(FEATURE_ID) == true
end
local function AnimatedAlpha(color, mode, nowMs)
    local base = math.max(0.05, math.min(1, N(color and color.a, 1)))
    mode = math.floor(N(mode, 1))
    if mode == 2 then return base * (0.65 + 0.35 * ((math.sin(N(nowMs) / 180) + 1) * 0.5)) end
    if mode == 3 then return base * (((math.floor(N(nowMs) / 300) % 2) == 0) and 1 or 0.48) end
    return base
end

local function NewColorDrawable(parent, layer)
    if parent == nil or type(parent.CreateColorDrawable) ~= "function" then return nil end
    local ok, drawable = pcall(function() return parent:CreateColorDrawable(1, 1, 1, 1, layer or "overlay") end)
    return ok and drawable or nil
end

local function MakeMarker(rank)
    local root, err = S.UI:CreateEmptyWidget(UIParent, "v3_healer_head_marker_" .. tostring(rank), 0, 0, 150, 36, false, P.owner)
    if root == nil then return nil, err end
    root.rsUiOwner = P.owner
    local parts = {}
    for index = 1, 4 do parts[index] = NewColorDrawable(root, "overlay") end
    local infoBg = NewColorDrawable(root, "artwork")
    local rankLabel = S.UI:CreateLabel(root, "v3_healer_head_rank_" .. tostring(rank), tostring(rank), 0, 0, 36, 36, 14, "strong", "CENTER", true)
    local infoLabel = S.UI:CreateLabel(root, "v3_healer_head_info_" .. tostring(rank), "", 40, 0, 110, 36, 10, "default", "LEFT", true)
    if rankLabel == nil or infoLabel == nil or infoBg == nil or parts[1] == nil or parts[2] == nil or parts[3] == nil or parts[4] == nil then
        S.UI:SetVisible(root, false, P.owner)
        return nil, "head_marker_child_create_failed"
    end
    S.UI:SetVisible(root, false, P.owner)
    return { window=root, parts=parts, infoBg=infoBg, rankLabel=rankLabel, infoLabel=infoLabel, layout={} }
end

function P:EnsurePool(count)
    count = math.max(0, math.min(50, math.floor(N(count))))
    for rank = #self.pool + 1, count do
        local marker, err = MakeMarker(rank)
        if marker == nil then return false, err end
        self.pool[rank] = marker
        self.metrics.allocated = #self.pool
    end
    return true
end

local function AnchorPart(part, parent, x, y, width, height)
    if part == nil then return end
    S.UI:SetAnchor(part, parent, x, y, P.owner)
    S.UI:SetExtent(part, math.max(1, width), math.max(1, height), P.owner)
    S.UI:SetVisible(part, true, P.owner)
end

function P:LayoutMarker(marker, candidate, settings)
    local sizes = type(settings.sizes) == "table" and settings.sizes or {18,24,30,36}
    local level = math.max(1, math.min(4, math.floor(N(candidate.level, 1))))
    local size = math.max(12, math.floor(N(sizes[level], 18)))
    local showName, showDistance, showScore = settings.showName == true, settings.showDistance == true, settings.showScore == true
    local showExtra = showName or showDistance or showScore
    local infoWidth = showExtra and 130 or 66
    local width = size + 4 + infoWidth
    local shape = math.max(1, math.min(4, math.floor(N(settings.shapeMode, 4))))
    local cache = marker.layout
    if cache.size == size and cache.shape == shape and cache.showName == showName
        and cache.showDistance == showDistance and cache.showScore == showScore then
        return cache.width, cache.height
    end
    cache.size, cache.shape = size, shape
    cache.showName, cache.showDistance, cache.showScore = showName, showDistance, showScore
    cache.width, cache.height = width, size

    S.UI:SetExtent(marker.window, width, size, P.owner)
    S.UI:SetAnchor(marker.rankLabel, marker.window, 0, 0, P.owner)
    S.UI:SetExtent(marker.rankLabel, size, size, P.owner)
    S.UI:SetFontSize(marker.rankLabel, math.max(9, math.floor(size * 0.38)), P.owner)
    S.UI:SetAnchor(marker.infoLabel, marker.window, size + 4, 0, P.owner)
    S.UI:SetExtent(marker.infoLabel, infoWidth, size, P.owner)
    S.UI:SetFontSize(marker.infoLabel, math.max(8, math.floor(size * 0.28)), P.owner)

    local visible = { false, false, false, false }
    local infoVisible = false
    if shape == 1 then
        visible[1] = true; AnchorPart(marker.parts[1], marker.window, 0, 0, width, size)
    elseif shape == 2 then
        local inset = math.max(2, math.floor(size * 0.08))
        visible[1], infoVisible = true, true
        AnchorPart(marker.parts[1], marker.window, inset, inset, size - inset * 2, size - inset * 2)
        AnchorPart(marker.infoBg, marker.window, size + 2, 1, width - size - 2, size - 2)
    elseif shape == 3 then
        local thickness, inset = math.max(4, math.floor(size * 0.28)), math.max(2, math.floor(size * 0.08))
        visible[1], visible[2], infoVisible = true, true, true
        AnchorPart(marker.parts[1], marker.window, math.floor((size-thickness)/2), inset, thickness, size-inset*2)
        AnchorPart(marker.parts[2], marker.window, inset, math.floor((size-thickness)/2), size-inset*2, thickness)
        AnchorPart(marker.infoBg, marker.window, size + 2, 1, width - size - 2, size - 2)
    else
        local stemWidth = math.max(4, math.floor(size * 0.22))
        local stemHeight = math.max(5, math.floor(size * 0.38))
        local barHeight = math.max(3, math.floor(size * 0.13))
        visible[1], visible[2], visible[3], visible[4], infoVisible = true, true, true, true, true
        AnchorPart(marker.parts[1], marker.window, math.floor((size-stemWidth)/2), 1, stemWidth, stemHeight)
        AnchorPart(marker.parts[2], marker.window, math.floor(size*0.12), stemHeight, math.floor(size*0.76), barHeight)
        AnchorPart(marker.parts[3], marker.window, math.floor(size*0.24), stemHeight+barHeight, math.floor(size*0.52), barHeight)
        AnchorPart(marker.parts[4], marker.window, math.floor(size*0.38), stemHeight+barHeight*2, math.floor(size*0.24), barHeight)
        AnchorPart(marker.infoBg, marker.window, size + 2, 1, width - size - 2, size - 2)
    end
    for index = 1, 4 do S.UI:SetVisible(marker.parts[index], visible[index], P.owner) end
    S.UI:SetVisible(marker.infoBg, infoVisible, P.owner)
    return width, size
end

function P:RefreshProjection()
    if self.running ~= true then return false end
    local settings = self.settings or Settings()
    local projection = Feature:GetProjection(math.max(1, math.floor(N(settings.count, 5))))
    self.candidates = type(projection) == "table" and type(projection.recommendations) == "table" and projection.recommendations or {}
    for rank, candidate in ipairs(self.candidates) do
        local text = string.format("%.0f%%", N(candidate.healthPercent))
        if settings.showName == true then text = text .. " " .. tostring(candidate.name or "") end
        if settings.showDistance == true then text = text .. string.format(" %.0fm", N(candidate.distance)) end
        if settings.showScore == true then text = text .. string.format(" %.0f分", N(candidate.finalScore)) end
        candidate.markerText = text
        candidate.markerRankText = tostring(candidate.rank or rank)
    end
    self.metrics.refreshes = (tonumber(self.metrics.refreshes) or 0) + 1
    return true
end

function P:VisualTick()
    if self.running ~= true then return false end
    self.metrics.ticks = (tonumber(self.metrics.ticks) or 0) + 1
    local settings = self.settings
    if type(settings) ~= "table" then return false end
    local count = math.min(math.floor(N(settings.count, 5)), #self.candidates, #self.pool)
    local maxTouched = math.max(count, tonumber(self.lastActive) or 0)
    for rank = count + 1, maxTouched do
        local marker = self.pool[rank]
        if marker ~= nil then S.UI:SetVisible(marker.window, false, self.owner) end
    end
    local nowMs = S.NowMs and S.NowMs() or 0
    for rank = 1, count do
        local candidate, marker = self.candidates[rank], self.pool[rank]
        local screenX, screenY, screenZ = nil, nil, nil
        if candidate ~= nil then screenX, screenY, screenZ = Feature:ProjectUnitToScreen(candidate.unitToken) end
        self.metrics.projections = (tonumber(self.metrics.projections) or 0) + 1
        if screenX ~= nil and screenY ~= nil and N(screenZ) > 0 then
            local width, height = self:LayoutMarker(marker, candidate, settings)
            local color = type(candidate.color) == "table" and candidate.color or {r=1,g=0.2,b=0.2,a=0.9}
            local alpha = AnimatedAlpha(color, settings.effectMode, nowMs)
            for _, part in ipairs(marker.parts) do S.UI:SetColor(part, N(color.r,1), N(color.g,0.2), N(color.b,0.2), alpha, self.owner) end
            S.UI:SetColor(marker.infoBg, 0.02, 0.025, 0.035, 0.72, self.owner)
            S.UI:SetText(marker.rankLabel, candidate.markerRankText or tostring(candidate.rank or rank), self.owner)
            S.UI:SetText(marker.infoLabel, candidate.markerText or "", self.owner)
            S.UI:SetAnchor(marker.window, "UIParent", math.floor(N(screenX)-width/2), math.floor(N(screenY)-height-38), self.owner)
            S.UI:SetVisible(marker.window, true, self.owner)
        else
            self.metrics.projectionFailures = (tonumber(self.metrics.projectionFailures) or 0) + 1
            if marker ~= nil then S.UI:SetVisible(marker.window, false, self.owner) end
        end
    end
    self.lastActive = count
    return true
end

function P:HideAll()
    for _, marker in ipairs(self.pool) do S.UI:SetVisible(marker.window, false, self.owner) end
    self.lastActive = 0
end

function P:Start(reason)
    if self.running == true then return true end
    if not FeatureEnabled() then return false, "治疗辅助未启用" end
    local settings = Settings()
    self.settings = settings
    if settings.enabled ~= true then return true end
    local ok, err = self:EnsurePool(settings.count)
    if ok ~= true then return false, err end
    ok, err = Feature:AcquireConsumer(self.consumerToken)
    if ok ~= true then return false, err end
    self.consumerHeld = true
    if S.Events == nil or type(S.Events.SubscribeInternal) ~= "function" then Feature:ReleaseConsumer(self.consumerToken); self.consumerHeld=false; return false, "event bus unavailable" end
    ok = S.Events:SubscribeInternal("v3.healer.updated", self.activeOwner, function() self:RefreshProjection() end)
    if ok ~= true then Feature:ReleaseConsumer(self.consumerToken); self.consumerHeld=false; return false, "head marker event subscribe failed" end
    local interval = math.max(50, math.floor(N(settings.refreshMs, 50)))
    ok = S.Scheduler:AddTask(self.taskName, interval, function() return self:VisualTick() end, false, self, "P4", 1)
    if ok ~= true then
        if type(S.Events.UnsubscribeInternalOwner) == "function" then S.Events:UnsubscribeInternalOwner(self.activeOwner) end
        Feature:ReleaseConsumer(self.consumerToken); self.consumerHeld=false
        return false, "head marker scheduler failed"
    end
    self.taskActive, self.running = true, true
    self.metrics.starts = (tonumber(self.metrics.starts) or 0) + 1
    self:RefreshProjection()
    return true
end

function P:Stop(reason)
    if self.running ~= true and self.consumerHeld ~= true and self.taskActive ~= true then self:HideAll(); return true end
    -- Release Demand first while the visual task/subscription is still intact.
    -- If Demand rejects the transition, keep the old Presentation state rather
    -- than ending in a half-stopped marker with a leaked consumer token.
    if self.consumerHeld == true then
        local ok, err = Feature:ReleaseConsumer(self.consumerToken)
        if ok ~= true and FeatureEnabled() then return false, err end
        self.consumerHeld = false
    end
    if self.taskActive == true then S.Scheduler:RemoveTask(self.taskName); self.taskActive = false end
    if S.Events ~= nil and type(S.Events.UnsubscribeInternalOwner) == "function" then S.Events:UnsubscribeInternalOwner(self.activeOwner) end
    self:HideAll()
    self.running = false
    self.candidates = {}
    self.metrics.stops = (tonumber(self.metrics.stops) or 0) + 1
    return true
end

function P:Reconcile(reason)
    local settings = Settings()
    self.settings = settings
    if FeatureEnabled() and settings.enabled == true then
        if self.running ~= true then return self:Start(reason) end
        local ok, err = self:EnsurePool(settings.count)
        if ok ~= true then return false, err end
        -- AddTask is an atomic replace-by-name in the shared Scheduler; do not
        -- remove the old task first or a rejected update would create a gap.
        if self.taskActive == true then
            self.taskActive = S.Scheduler:AddTask(self.taskName, math.max(50, math.floor(N(settings.refreshMs,50))), function() return self:VisualTick() end, false, self, "P4", 1) == true
        end
        self:RefreshProjection()
        return self.taskActive == true
    end
    return self:Stop(reason)
end

function P:Describe()
    return {
        version=self.version, running=self.running==true, consumerHeld=self.consumerHeld==true,
        taskActive=self.taskActive==true, allocated=#self.pool, active=tonumber(self.lastActive) or 0,
        refreshes=tonumber(self.metrics.refreshes) or 0, ticks=tonumber(self.metrics.ticks) or 0,
        projections=tonumber(self.metrics.projections) or 0, projectionFailures=tonumber(self.metrics.projectionFailures) or 0,
    }
end

-- Dormant controller only: no Native work, no Demand lease, no Scheduler. It
-- exists so Feature lifecycle and display-setting changes can start/stop the
-- independent consumer without a Domain->Presentation direct call.
if S.Events ~= nil and type(S.Events.SubscribeInternal) == "function" then
    S.Events:SubscribeInternal((S.FeatureRuntime and S.FeatureRuntime.LifecycleTopic) or "v3.feature.lifecycle", P,
        function(_, featureId) if tostring(featureId or "") == FEATURE_ID then P:Reconcile("feature_lifecycle") end end)
    S.Events:SubscribeInternal("v3.healer.presentation", P,
        function(_, scope) if tostring(scope or "") == "head" then P:Reconcile("head_settings") end end)
end
P:Reconcile("bootstrap")
