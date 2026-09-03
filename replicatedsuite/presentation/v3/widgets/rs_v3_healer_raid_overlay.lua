------------------------------------------------------------------------
-- Replicated Suite V3 - Healer Raid Overlay Consumer (M1.16.0.18)
--
-- Independent Presentation Consumer. The overlay consumes committed Healer
-- Recommendation + Roster projections only. It owns 4x25 visual slots and an
-- optional bounded alpha-animation task; it never scans Health/Aura/Roster.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local Feature = S.Features and S.Features.Healer or nil
if type(Feature) ~= "table" or type(S.UI) ~= "table" or type(S.Scheduler) ~= "table" then return end
local FEATURE_ID = "combat_healer"

S.UIV3 = S.UIV3 or {}
S.UIV3.HealerRaidOverlay = S.UIV3.HealerRaidOverlay or {}
local P = S.UIV3.HealerRaidOverlay

P.version = 1
P.owner = "v3:healer_raid_overlay"
P.consumerToken = "presentation:healer_raid_overlay"
P.taskName = "v3_healer_raid_overlay_effect"
P.running = P.running == true
P.consumerHeld = P.consumerHeld == true
P.taskActive = P.taskActive == true
P.calibrationMode = P.calibrationMode == true
P.sections = P.sections or {}
P.candidates = P.candidates or {}
P.displayRows = P.displayRows or {}
P.settings = P.settings or nil
P.activeSections = P.activeSections or {}
P.rosterCount = tonumber(P.rosterCount) or 0
P.metrics = P.metrics or { starts=0, stops=0, refreshes=0, effectTicks=0, allocatedSections=0, dragCommits=0 }
P.activeOwner = P.activeOwner or {}

local MEMBERS_PER_SECTION, GROUPS_PER_SECTION, MEMBERS_PER_GROUP = 25, 5, 5
local function N(value, fallback) return tonumber(value) or tonumber(fallback) or 0 end
local function FeatureEnabled() return S.FeatureRuntime ~= nil and S.FeatureRuntime:IsEnabled(FEATURE_ID) == true end
local function Settings()
    local value = type(Feature.GetPresentationProjection) == "function" and Feature:GetPresentationProjection("raid") or nil
    return type(value) == "table" and value or { enabled=false, effectMode=1, showRanks=true, rankCount=10, rankFontSize=10, rankAlpha=1, sections={} }
end
local function AnimatedAlpha(color, mode, nowMs)
    local base = math.max(0.05, math.min(1, N(color and color.a, 1)))
    mode = math.floor(N(mode, 1))
    if mode == 2 then return base * (0.65 + 0.35 * ((math.sin(N(nowMs) / 180) + 1) * 0.5)) end
    if mode == 3 then return base * (((math.floor(N(nowMs) / 300) % 2) == 0) and 1 or 0.48) end
    return base
end
local function InCalibrationScope(index, scope)
    scope = math.floor(N(scope, 1))
    if scope == 2 then return index <= 2 end
    if scope == 3 then return index >= 3 end
    return true
end
local function NewColorDrawable(parent, layer)
    if parent == nil or type(parent.CreateColorDrawable) ~= "function" then return nil end
    local ok, drawable = pcall(function() return parent:CreateColorDrawable(1, 1, 1, 1, layer or "overlay") end)
    return ok and drawable or nil
end

local function SectionFirstMember(index) return (index % 2 == 0) and 26 or 1 end

function P:GetOverlaySlot(raidIndex, memberIndex)
    raidIndex, memberIndex = math.floor(N(raidIndex,1)), math.floor(N(memberIndex,0))
    if raidIndex < 1 or raidIndex > 2 or memberIndex < 1 or memberIndex > 50 then return nil, nil end
    local sectionIndex = (raidIndex - 1) * 2 + (memberIndex > 25 and 2 or 1)
    return self.sections[sectionIndex], memberIndex - SectionFirstMember(sectionIndex) + 1
end

local function MakeSection(index)
    local settings = P.settings or Settings()
    local rect = type(settings.sections) == "table" and settings.sections[index] or nil
    rect = type(rect) == "table" and rect or { x=(index>2 and 360 or 0), y=(index%2==0 and 344 or 140), width=340, height=196 }
    -- RU exposes SetUILayer only on Window-kind widgets (ui_functions.lua:
    -- Widgetbase has GetUILayer/Raise/Lower but no SetUILayer). A section root
    -- created via CreateEmptyWidget (emptywidget kind) can therefore never leave
    -- the ordinary layer, no matter how often TrySetUILayer is called: the
    -- native raid frame raises itself above the overlay whenever a member row is
    -- clicked, and the overlay only pops back on the next data refresh -- the
    -- visible "flicker on click". Create the root through the V3 native adapter
    -- (Window kind, SetUILayer("system") applied at creation), matching the
    -- proven legacy overlay implementation.
    local root, err
    local adapter = S.UIV3NativeAdapter
    if type(adapter) == "table" and type(adapter.CreateRootWindow) == "function" then
        root, err = adapter:CreateRootWindow("v3_healer_raid_overlay_" .. tostring(index), P.owner)
    end
    if root == nil then
        root, err = S.UI:CreateEmptyWidget(UIParent, "v3_healer_raid_overlay_" .. tostring(index), rect.x, rect.y, rect.width, rect.height, false, P.owner)
    end
    if root == nil then return nil, err end
    root.rsUiOwner = P.owner
    local calibrationBg = NewColorDrawable(root, "artwork")
    local borders = { NewColorDrawable(root,"overlay"), NewColorDrawable(root,"overlay"), NewColorDrawable(root,"overlay"), NewColorDrawable(root,"overlay") }
    local title = S.UI:CreateLabel(root, "v3_healer_raid_title_" .. tostring(index), "团队覆盖 " .. tostring(index), 5, 2, 180, 18, 10, "strong", "LEFT", true)
    local slots, ranks, calibrationLabels = {}, {}, {}
    for localIndex = 1, MEMBERS_PER_SECTION do
        slots[localIndex] = NewColorDrawable(root, "overlay")
        ranks[localIndex] = S.UI:CreateLabel(root, "v3_healer_raid_rank_" .. tostring(index) .. "_" .. tostring(localIndex), "", 0, 0, 24, 14, 10, "strong", "CENTER", true)
        calibrationLabels[localIndex] = S.UI:CreateLabel(root, "v3_healer_raid_cal_" .. tostring(index) .. "_" .. tostring(localIndex), tostring(SectionFirstMember(index)+localIndex-1), 0, 0, 24, 14, 8, "muted", "CENTER", false)
        if slots[localIndex] == nil or ranks[localIndex] == nil or calibrationLabels[localIndex] == nil then
            S.UI:SetVisible(root, false, P.owner)
            return nil, "raid_overlay_child_create_failed"
        end
    end
    local section = { index=index, window=root, calibrationBg=calibrationBg, borders=borders, title=title, slots=slots, ranks=ranks, calibrationLabels=calibrationLabels, moving=false }
    S.UI:SetVisible(root, false, P.owner)
    S.UI:SetPickable(root, false, P.owner)

    S.UI:SafeHandler(root, "OnDragStart", function()
        local current = Settings()
        if current.calibration ~= true then return false end
        section.moving = true
        if type(S.UI.BeginNativeGeometryLease) == "function" then S.UI:BeginNativeGeometryLease(root, P.owner, "healer_raid_calibration") end
        if type(root.StartMoving) == "function" then pcall(function() root:StartMoving() end) end
        return true
    end, "v3_healer_raid_drag_start_" .. tostring(index))
    S.UI:SafeHandler(root, "OnDragStop", function()
        if section.moving ~= true then return false end
        if type(root.StopMovingOrSizing) == "function" then pcall(function() root:StopMovingOrSizing() end) end
        if type(S.UI.EndNativeGeometryLease) == "function" then S.UI:EndNativeGeometryLease(root, P.owner) end
        section.moving = false
        if S.Layout ~= nil and type(S.Layout.GetLogicalRect) == "function" then
            local x, y, width, height = S.Layout:GetLogicalRect(root)
            local ok = Feature.Commands:SetRaidSectionRect(index, { x=x, y=y, width=width, height=height })
            if ok == true then P.metrics.dragCommits = (tonumber(P.metrics.dragCommits) or 0) + 1 end
        end
        P:LayoutSection(index)
        return true
    end, "v3_healer_raid_drag_stop_" .. tostring(index))
    return section
end

function P:EnsureSections()
    for index = #self.sections + 1, 4 do
        local section, err = MakeSection(index)
        if section == nil then return false, err end
        self.sections[index] = section
    end
    self.metrics.allocatedSections = #self.sections
    return true
end

function P:LayoutSection(index)
    local section = self.sections[index]
    if section == nil or section.moving == true then return true end
    local settings = self.settings or Settings()
    local rect = type(settings.sections) == "table" and settings.sections[index] or nil
    if type(rect) ~= "table" then return false end
    local width, height = math.max(120,N(rect.width,340)), math.max(80,N(rect.height,196))
    S.UI:SetAnchor(section.window, "UIParent", N(rect.x), N(rect.y), self.owner)
    S.UI:SetExtent(section.window, width, height, self.owner)
    if section.calibrationBg ~= nil then
        S.UI:SetAnchor(section.calibrationBg, section.window, 0, 0, self.owner); S.UI:SetExtent(section.calibrationBg, width, height, self.owner)
    end
    local borders = section.borders
    if borders[1] then S.UI:SetAnchor(borders[1], section.window,0,0,self.owner); S.UI:SetExtent(borders[1],width,2,self.owner) end
    if borders[2] then S.UI:SetAnchor(borders[2], section.window,0,height-2,self.owner); S.UI:SetExtent(borders[2],width,2,self.owner) end
    if borders[3] then S.UI:SetAnchor(borders[3], section.window,0,0,self.owner); S.UI:SetExtent(borders[3],2,height,self.owner) end
    if borders[4] then S.UI:SetAnchor(borders[4], section.window,width-2,0,self.owner); S.UI:SetExtent(borders[4],2,height,self.owner) end
    S.UI:SetAnchor(section.title, section.window, 5, 2, self.owner)

    local outerPad, topPad, groupGap, rowGap = 4, 22, 4, 1
    local groupWidth = math.max(24, math.floor((width - outerPad*2 - groupGap*(GROUPS_PER_SECTION-1))/GROUPS_PER_SECTION))
    local slotHeight = math.max(8, math.floor((height - topPad - outerPad - rowGap*(MEMBERS_PER_GROUP-1))/MEMBERS_PER_GROUP))
    for localIndex = 1, MEMBERS_PER_SECTION do
        local groupIndex = math.floor((localIndex-1)/MEMBERS_PER_GROUP)
        local rowIndex = (localIndex-1)%MEMBERS_PER_GROUP
        local x = outerPad + groupIndex*(groupWidth+groupGap)
        local y = topPad + rowIndex*(slotHeight+rowGap)
        S.UI:SetAnchor(section.slots[localIndex], section.window, x, y, self.owner)
        S.UI:SetExtent(section.slots[localIndex], groupWidth, slotHeight, self.owner)
        S.UI:SetAnchor(section.calibrationLabels[localIndex], section.window, x, y, self.owner)
        S.UI:SetExtent(section.calibrationLabels[localIndex], groupWidth, slotHeight, self.owner)
        local rw, rh = math.max(18,N(settings.rankFontSize,10)*2), math.max(12,N(settings.rankFontSize,10)+4)
        local corner = math.floor(N(settings.rankCorner,2))
        local rx = (corner==2 or corner==4) and (x+groupWidth-rw-N(settings.rankOffsetX,1)) or (x+N(settings.rankOffsetX,1))
        local ry = (corner==3 or corner==4) and (y+slotHeight-rh-N(settings.rankOffsetY,1)) or (y+N(settings.rankOffsetY,1))
        S.UI:SetAnchor(section.ranks[localIndex], section.window, rx, ry, self.owner)
        S.UI:SetExtent(section.ranks[localIndex], rw, rh, self.owner)
        S.UI:SetFontSize(section.ranks[localIndex], N(settings.rankFontSize,10), self.owner)
    end
    return true
end

function P:LayoutAll()
    for index = 1, #self.sections do self:LayoutSection(index) end
end

function P:RefreshProjection()
    if self.running ~= true then return false end
    local projection = type(Feature.GetRaidOverlayProjection) == "function" and Feature:GetRaidOverlayProjection() or nil
    self.displayRows = type(projection) == "table" and type(projection.rows) == "table" and projection.rows or {}
    self.candidates = {}
    self.activeSections = {}
    for _, row in ipairs(self.displayRows) do
        local section = self:GetOverlaySlot(row.raidIndex, row.memberIndex)
        if section ~= nil then self.activeSections[section.index] = true end
        if row.isCandidate == true then self.candidates[#self.candidates + 1] = row end
    end
    self.rosterCount = type(projection) == "table" and tonumber(projection.rosterCount) or 0
    self.metrics.refreshes = (tonumber(self.metrics.refreshes) or 0) + 1
    self:RefreshHighlights()
    return true
end

function P:RefreshHighlights(nowMs)
    if self.running ~= true then return false end
    local settings = self.settings or Settings()
    local calibration = settings.calibration == true
    -- Runtime overlay requires at least one teammate. The legacy implementation
    -- (reference project) shows the overlay whenever rosterMode is "raid" or
    -- "coraid" - including 5-man dungeon parties - with NO minimum-size gate.
    -- The previous >5 check regressed that: a 5-man dungeon party (player + 4)
    -- never satisfied it, so the overlay never appeared inside instances while
    -- it worked fine in the open world / large raids. Rows are only generated
    -- for members with valid health and in-range distance, so a 2-man party
    -- still renders only the members that actually need a color block.
    local useRaidRuntime = self.rosterCount > 1
    for index, section in ipairs(self.sections) do
        local calibrationVisible = calibration and InCalibrationScope(index, settings.calibrationScope)
        local runtimeHasCandidate = not calibration and useRaidRuntime and self.activeSections[index] == true
        local show = calibrationVisible or runtimeHasCandidate
        local changed = S.UI:SetVisible(section.window, show, self.owner)
        S.UI:SetPickable(section.window, calibrationVisible, self.owner)
        if type(section.window.EnableDrag) == "function" then pcall(function() section.window:EnableDrag(calibrationVisible) end) end
        -- Always reassert Z-order for visible sections, not just on visibility
        -- change. The native team list / tooltips can raise above us at any time;
        -- periodic Raise() keeps our overlay on top without waiting for a
        -- lifecycle boundary.
        if show then
            S.UI:TrySetUILayer(section.window, "system")
            if type(section.window.Raise) == "function" then pcall(function() section.window:Raise() end) end
        end
        S.UI:SetVisible(section.calibrationBg, calibrationVisible, self.owner)
        if section.calibrationBg ~= nil then S.UI:SetColor(section.calibrationBg, 0.04,0.30,0.58,0.52,self.owner) end
        S.UI:SetVisible(section.title, calibrationVisible, self.owner)
        for _, border in ipairs(section.borders) do
            S.UI:SetVisible(border, calibrationVisible, self.owner)
            S.UI:SetColor(border, 0.18,0.82,1.00,0.92,self.owner)
        end
        for localIndex = 1, MEMBERS_PER_SECTION do
            S.UI:SetVisible(section.ranks[localIndex], false, self.owner)
            S.UI:SetVisible(section.calibrationLabels[localIndex], calibrationVisible, self.owner)
            S.UI:SetVisible(section.slots[localIndex], calibrationVisible, self.owner)
            if calibrationVisible then S.UI:SetColor(section.slots[localIndex],0.18,0.72,1.00,0.16,self.owner) end
        end
    end
    if not useRaidRuntime and not calibration then return true end
    nowMs = nowMs or (S.NowMs and S.NowMs() or 0)
    for _, row in ipairs(self.displayRows) do
        local section, localIndex = self:GetOverlaySlot(row.raidIndex, row.memberIndex)
        if section ~= nil and localIndex ~= nil and (not calibration or InCalibrationScope(section.index, settings.calibrationScope)) then
            local color = type(row.color) == "table" and row.color or {r=1,g=0.2,b=0.2,a=0.9}
            local alpha = row.isCandidate == true and AnimatedAlpha(color, settings.effectMode, nowMs) or N(color.a, 0.42)
            S.UI:SetColor(section.slots[localIndex], N(color.r,1),N(color.g,0.2),N(color.b,0.2), alpha, self.owner)
            S.UI:SetVisible(section.slots[localIndex], true, self.owner)
            if row.isCandidate == true and not calibration and settings.showRanks == true and N(row.rank,99) <= N(settings.rankCount,10) then
                S.UI:SetText(section.ranks[localIndex], tostring(row.rank or ""), self.owner)
                if section.ranks[localIndex].style ~= nil then S.UI:SetColor(section.ranks[localIndex].style,1,1,1,N(settings.rankAlpha,1),self.owner) end
                S.UI:SetVisible(section.ranks[localIndex], true, self.owner)
            end
        end
    end
    return true
end

function P:AnimateTick()
    if self.running ~= true then return false end
    local settings = self.settings
    if type(settings) ~= "table" then return false end
    if math.floor(N(settings.effectMode,1)) == 1 then return true end
    local nowMs = S.NowMs and S.NowMs() or 0
    for _, candidate in ipairs(self.candidates) do
        local section, localIndex = self:GetOverlaySlot(candidate.raidIndex, candidate.memberIndex)
        if section ~= nil and localIndex ~= nil then
            local color = type(candidate.color) == "table" and candidate.color or {r=1,g=0.2,b=0.2,a=0.9}
            S.UI:SetColor(section.slots[localIndex], N(color.r,1),N(color.g,0.2),N(color.b,0.2), AnimatedAlpha(color, settings.effectMode, nowMs), self.owner)
        end
    end
    return true
end

function P:ReconcileEffectTask()
    local settings = self.settings or Settings()
    local needTask = self.running == true and self.calibrationMode ~= true and math.floor(N(settings.effectMode,1)) ~= 1
    if needTask and self.taskActive ~= true then
        self.taskActive = S.Scheduler:AddTask(self.taskName, 100, function()
            self.metrics.effectTicks = (tonumber(self.metrics.effectTicks) or 0) + 1
            return self:AnimateTick()
        end, false, self, "P4", 1) == true
    elseif not needTask and self.taskActive == true then
        S.Scheduler:RemoveTask(self.taskName); self.taskActive = false
    end
    return needTask == false or self.taskActive == true
end

function P:Start(reason)
    if self.running == true then return true end
    local settings = Settings()
    self.settings = settings
    local calibration = settings.calibration == true
    local runtimeMode = FeatureEnabled() and settings.enabled == true
    if calibration ~= true and runtimeMode ~= true then return true end
    local ok, err = self:EnsureSections()
    if ok ~= true then return false, err end
    self:LayoutAll()
    self.calibrationMode = calibration
    if calibration == true then
        ok, err = Feature:AcquirePreviewConsumer(self.consumerToken)
    else
        ok, err = Feature:AcquireConsumer(self.consumerToken)
    end
    if ok ~= true then return false, err end
    self.consumerHeld = true
    if S.Events == nil or type(S.Events.SubscribeInternal) ~= "function" then Feature:ReleaseConsumer(self.consumerToken); self.consumerHeld=false; return false,"event bus unavailable" end
    ok = S.Events:SubscribeInternal("v3.healer.updated", self.activeOwner, function() self:RefreshProjection() end)
    if ok ~= true then Feature:ReleaseConsumer(self.consumerToken); self.consumerHeld=false; return false,"raid overlay event subscribe failed" end
    self.running = true
    self.metrics.starts = (tonumber(self.metrics.starts) or 0) + 1
    self:RefreshProjection()
    if self:ReconcileEffectTask() ~= true then self:Stop("effect_task_failed"); return false,"raid overlay effect scheduler failed" end
    return true
end

function P:Stop(reason)
    if self.consumerHeld == true then
        local ok, err = Feature:ReleaseConsumer(self.consumerToken)
        if ok ~= true and FeatureEnabled() then return false, err end
        self.consumerHeld=false
    end
    if self.taskActive == true then S.Scheduler:RemoveTask(self.taskName); self.taskActive=false end
    if S.Events ~= nil and type(S.Events.UnsubscribeInternalOwner) == "function" then S.Events:UnsubscribeInternalOwner(self.activeOwner) end
    for _, section in ipairs(self.sections) do S.UI:SetVisible(section.window,false,self.owner); S.UI:SetPickable(section.window,false,self.owner) end
    if self.running == true then self.metrics.stops = (tonumber(self.metrics.stops) or 0) + 1 end
    self.running=false; self.calibrationMode=false; self.candidates={}; self.displayRows={}; self.rosterCount=0
    return true
end

function P:Reconcile(reason)
    local settings = Settings()
    self.settings = settings
    local calibration = settings.calibration == true
    local shouldRun = calibration or (FeatureEnabled() and settings.enabled == true)
    if shouldRun then
        -- Switching between standalone calibration and live healing overlay must
        -- also switch resource ownership: calibration owns one temporary preview Consumer and never changes the user Feature preference.
        if self.running == true and self.calibrationMode ~= calibration then
            local stopped, stopErr = self:Stop("raid_overlay_mode_switch")
            if stopped ~= true then return false, stopErr end
        end
        if self.running ~= true then return self:Start(reason) end
        local ok, err = self:EnsureSections(); if ok ~= true then return false, err end
        if calibration == true and type(Feature.HasConsumer) == "function" and Feature:HasConsumer(self.consumerToken) ~= true then
            ok, err = Feature:AcquirePreviewConsumer(self.consumerToken)
            if ok ~= true then return false, err end
            self.consumerHeld = true
            if S.Events ~= nil and type(S.Events.SubscribeInternal) == "function" then
                S.Events:SubscribeInternal("v3.healer.updated", self.activeOwner, function() self:RefreshProjection() end)
            end
        end
        self:LayoutAll(); self:RefreshProjection(); return self:ReconcileEffectTask()
    end
    return self:Stop(reason)
end

function P:Describe()
    return {
        version=self.version, running=self.running==true, calibrationMode=self.calibrationMode==true, consumerHeld=self.consumerHeld==true,
        taskActive=self.taskActive==true, allocatedSections=#self.sections, rosterCount=tonumber(self.rosterCount) or 0,
        refreshes=tonumber(self.metrics.refreshes) or 0, effectTicks=tonumber(self.metrics.effectTicks) or 0,
        dragCommits=tonumber(self.metrics.dragCommits) or 0,
    }
end

if S.Events ~= nil and type(S.Events.SubscribeInternal) == "function" then
    S.Events:SubscribeInternal((S.FeatureRuntime and S.FeatureRuntime.LifecycleTopic) or "v3.feature.lifecycle", P,
        function(_, featureId) if tostring(featureId or "") == FEATURE_ID then P:Reconcile("feature_lifecycle") end end)
    S.Events:SubscribeInternal("v3.healer.presentation", P,
        function(_, scope) if tostring(scope or "") == "raid" then P:Reconcile("raid_settings") end end)
end
P:Reconcile("bootstrap")
