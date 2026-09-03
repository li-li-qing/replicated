------------------------------------------------------------------------
-- Replicated Suite V3 - Healer Raid Overlay Consumer (Panel A/B refactor)
--
-- Independent Presentation Consumer. The overlay consumes committed Healer
-- Recommendation + Roster projections only.
--
-- Architecture (this refactor):
--   RaidTeam   = team identity (TeamRosterV3 authority; teamIndex 1/2)
--   RaidPanel  = screen container A/B, each with its own rectangular geometry
--   Calibration= the panel rectangle; one rect per panel, cells are derived
--
-- A panel's bound team (which RaidTeam it shows) can change at runtime WITHOUT
-- any geometry change. Geometry is owned by the panel, not by the team. Single
-- list mode shows Panel A only; dual list mode shows A and B. Each panel holds
-- 50 pooled slots created once. Highlighting is event-driven (v3.healer.updated),
-- not a per-frame full scan.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local Feature = S.Features and S.Features.Healer or nil
if type(Feature) ~= "table" or type(S.UI) ~= "table" or type(S.Scheduler) ~= "table" then return end
local FEATURE_ID = "combat_healer"

S.UIV3 = S.UIV3 or {}
S.UIV3.HealerRaidOverlay = S.UIV3.HealerRaidOverlay or {}
local P = S.UIV3.HealerRaidOverlay

P.version = 2
P.owner = "v3:healer_raid_overlay"
P.consumerToken = "presentation:healer_raid_overlay"
P.taskName = "v3_healer_raid_overlay_effect"
P.running = P.running == true
P.consumerHeld = P.consumerHeld == true
P.taskActive = P.taskActive == true
P.calibrationMode = P.calibrationMode == true
P.panels = P.panels or {}
P.bindings = P.bindings or {}
P.candidates = P.candidates or {}
P.displayRows = P.displayRows or {}
P.activePanels = P.activePanels or {}
P.rosterCount = tonumber(P.rosterCount) or 0
P.selfSlot = P.selfSlot or nil
P.locateUntil = tonumber(P.locateUntil) or 0
P.metrics = P.metrics or { starts=0, stops=0, refreshes=0, effectTicks=0, allocatedPanels=0, dragCommits=0 }
P.activeOwner = P.activeOwner or {}

local SLOTS_PER_PANEL = 50
local COLS, ROWS = 10, 5
local function N(value, fallback) return tonumber(value) or tonumber(fallback) or 0 end
local function FeatureEnabled() return S.FeatureRuntime ~= nil and S.FeatureRuntime:IsEnabled(FEATURE_ID) == true end
local function Settings()
    local value = type(Feature.GetPresentationProjection) == "function" and Feature:GetPresentationProjection("raid") or nil
    return type(value) == "table" and value or {
        enabled=false, effectMode=1, showRanks=true, rankCount=10, rankFontSize=10,
        calibration=false, proximityMode=true, mode="auto", singleTeamId=0,
        testColors=false, slotNumbers=true, showMyself=false, panels={},
    }
end

-- Deterministic HSL->RGB for test-color mode (h in [0,1]).
local function HslColor(h, s, l)
    h = (h % 1 + 1) % 1
    local r, g, b
    if s <= 0 then r, g, b = l, l, l
    else
        local q = l < 0.5 and l * (1 + s) or l + s - l * s
        local p = 2 * l - q
        local function Hue(pq, tt)
            if tt < 0 then tt = tt + 1 end
            if tt > 1 then tt = tt - 1 end
            if tt < 1/6 then return pq + (q - pq) * 6 * tt end
            if tt < 1/2 then return q end
            if tt < 2/3 then return pq + (q - pq) * (2/3 - tt) * 6 end
            return pq
        end
        r, g, b = Hue(p, h + 1/3), Hue(p, h), Hue(p, h - 1/3)
    end
    return r, g, b
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

function P:MakePanel(id)
    local settings = Settings()
    local bindings = self.bindings or {}
    local geometry = nil
    for _, b in ipairs(bindings) do if b.id == id then geometry = b.geometry; break end end
    if geometry == nil then
        local raid = type(settings.panels) == "table" and settings.panels[id] or nil
        geometry = type(raid) == "table" and raid.geometry or { x=0, y=140, width=340, height=400 }
    end
    local root, err
    local adapter = S.UIV3NativeAdapter
    if type(adapter) == "table" and type(adapter.CreateRootWindow) == "function" then
        root, err = adapter:CreateRootWindow("v3_healer_raid_panel_" .. tostring(id), P.owner)
    end
    if root == nil then
        root, err = S.UI:CreateEmptyWidget(UIParent, "v3_healer_raid_panel_" .. tostring(id), N(geometry.x), N(geometry.y), N(geometry.width,340), N(geometry.height,400), false, P.owner)
    end
    if root == nil then return nil, err end
    root.rsUiOwner = P.owner
    local calibrationBg = NewColorDrawable(root, "artwork")
    local borders = { NewColorDrawable(root,"overlay"), NewColorDrawable(root,"overlay"), NewColorDrawable(root,"overlay"), NewColorDrawable(root,"overlay") }
    local title = S.UI:CreateLabel(root, "v3_healer_raid_title_" .. tostring(id), "队伍面板 " .. tostring(id), 5, 2, 180, 18, 10, "strong", "LEFT", true)
    local slots, ranks, calibrationLabels = {}, {}, {}
    for localIndex = 1, SLOTS_PER_PANEL do
        slots[localIndex] = NewColorDrawable(root, "overlay")
        ranks[localIndex] = S.UI:CreateLabel(root, "v3_healer_raid_rank_" .. tostring(id) .. "_" .. tostring(localIndex), "", 0, 0, 24, 14, 10, "strong", "CENTER", true)
        calibrationLabels[localIndex] = S.UI:CreateLabel(root, "v3_healer_raid_cal_" .. tostring(id) .. "_" .. tostring(localIndex), tostring(localIndex), 0, 0, 24, 14, 8, "muted", "CENTER", false)
        if slots[localIndex] == nil or ranks[localIndex] == nil or calibrationLabels[localIndex] == nil then
            S.UI:SetVisible(root, false, P.owner)
            return nil, "raid_overlay_child_create_failed"
        end
    end
    local panel = { id=id, window=root, calibrationBg=calibrationBg, borders=borders, title=title, slots=slots, ranks=ranks, calibrationLabels=calibrationLabels, moving=false }
    S.UI:SetVisible(root, false, P.owner)
    S.UI:SetPickable(root, false, P.owner)

    S.UI:SafeHandler(root, "OnDragStart", function()
        local current = Settings()
        if current.calibration ~= true then return false end
        panel.moving = true
        if type(S.UI.BeginNativeGeometryLease) == "function" then S.UI:BeginNativeGeometryLease(root, P.owner, "healer_raid_calibration") end
        if type(root.StartMoving) == "function" then pcall(function() root:StartMoving() end) end
        return true
    end, "v3_healer_raid_drag_start_" .. tostring(id))
    S.UI:SafeHandler(root, "OnDragStop", function()
        if panel.moving ~= true then return false end
        if type(root.StopMovingOrSizing) == "function" then pcall(function() root:StopMovingOrSizing() end) end
        if type(S.UI.EndNativeGeometryLease) == "function" then S.UI:EndNativeGeometryLease(root, P.owner) end
        panel.moving = false
        if S.Layout ~= nil and type(S.Layout.GetLogicalRect) == "function" then
            local x, y, width, height = S.Layout:GetLogicalRect(root)
            local ok = Feature.Commands:SetRaidPanelRect(id, { x=x, y=y, width=width, height=height })
            if ok == true then P.metrics.dragCommits = (tonumber(P.metrics.dragCommits) or 0) + 1 end
        end
        P:LayoutPanel(id)
        return true
    end, "v3_healer_raid_drag_stop_" .. tostring(id))
    self.panels[id] = panel
    return panel
end

function P:EnsurePanels(bindings)
    local ok = true
    local err = nil
    for _, b in ipairs(bindings) do
        if self.panels[b.id] == nil then
            local panel, perr = self:MakePanel(b.id)
            if panel == nil then ok = false; err = perr end
        end
    end
    self.metrics.allocatedPanels = 0
    for _ in pairs(self.panels) do self.metrics.allocatedPanels = self.metrics.allocatedPanels + 1 end
    return ok, err
end

function P:LayoutPanel(id)
    local panel = self.panels[id]
    if panel == nil or panel.moving == true then return true end
    local settings = Settings()
    local geometry = nil
    for _, b in ipairs(self.bindings) do if b.id == id then geometry = b.geometry; break end end
    if geometry == nil then
        local raid = type(settings.panels) == "table" and settings.panels[id] or nil
        geometry = type(raid) == "table" and raid.geometry or { x=0, y=140, width=340, height=400 }
    end
    if type(geometry) ~= "table" then return false end
    local width, height = math.max(120, N(geometry.width, 340)), math.max(80, N(geometry.height, 400))
    S.UI:SetAnchor(panel.window, "UIParent", N(geometry.x), N(geometry.y), self.owner)
    S.UI:SetExtent(panel.window, width, height, self.owner)
    if panel.calibrationBg ~= nil then
        S.UI:SetAnchor(panel.calibrationBg, panel.window, 0, 0, self.owner); S.UI:SetExtent(panel.calibrationBg, width, height, self.owner)
    end
    S.UI:SetAnchor(panel.borders[1], panel.window, 0, 0, self.owner); S.UI:SetExtent(panel.borders[1], width, 2, self.owner)
    S.UI:SetAnchor(panel.borders[2], panel.window, 0, height - 2, self.owner); S.UI:SetExtent(panel.borders[2], width, 2, self.owner)
    S.UI:SetAnchor(panel.borders[3], panel.window, 0, 0, self.owner); S.UI:SetExtent(panel.borders[3], 2, height, self.owner)
    S.UI:SetAnchor(panel.borders[4], panel.window, width - 2, 0, self.owner); S.UI:SetExtent(panel.borders[4], 2, height, self.owner)
    S.UI:SetAnchor(panel.title, panel.window, 5, 2, self.owner)

    local outerPad, topPad, cellGapX, cellGapY = 4, 22, 1, 1
    local cellW = math.max(6, math.floor((width - outerPad * 2 - (COLS - 1) * cellGapX) / COLS))
    local cellH = math.max(6, math.floor((height - topPad - outerPad - (ROWS - 1) * cellGapY) / ROWS))
    for i = 1, SLOTS_PER_PANEL do
        local col = (i - 1) % COLS
        local row = math.floor((i - 1) / COLS)
        local x = outerPad + col * (cellW + cellGapX)
        local y = topPad + row * (cellH + cellGapY)
        S.UI:SetAnchor(panel.slots[i], panel.window, x, y, self.owner)
        S.UI:SetExtent(panel.slots[i], cellW, cellH, self.owner)
        S.UI:SetAnchor(panel.calibrationLabels[i], panel.window, x, y, self.owner)
        S.UI:SetExtent(panel.calibrationLabels[i], cellW, cellH, self.owner)
        local rw, rh = math.max(18, N(settings.rankFontSize, 10) * 2), math.max(12, N(settings.rankFontSize, 10) + 4)
        local corner = math.floor(N(settings.rankCorner, 2))
        local rx = (corner == 2 or corner == 4) and (x + cellW - rw - N(settings.rankOffsetX, 1)) or (x + N(settings.rankOffsetX, 1))
        local ry = (corner == 3 or corner == 4) and (y + cellH - rh - N(settings.rankOffsetY, 1)) or (y + N(settings.rankOffsetY, 1))
        S.UI:SetAnchor(panel.ranks[i], panel.window, rx, ry, self.owner)
        S.UI:SetExtent(panel.ranks[i], rw, rh, self.owner)
        S.UI:SetFontSize(panel.ranks[i], N(settings.rankFontSize, 10), self.owner)
    end
    return true
end

function P:LayoutAll()
    for id in pairs(self.panels) do self:LayoutPanel(id) end
end

-- Map a roster member to its panel + local slot index. The binding is by team
-- identity; the player (teamIndex 0 / isSelf) resolves to the single-only panel.
function P:GetOverlaySlot(member)
    local team = tonumber(member and member.teamIndex) or 0
    local memberIndex = tonumber(member and member.memberIndex) or 0
    if memberIndex < 1 or memberIndex > SLOTS_PER_PANEL then return nil, nil end
    for _, b in ipairs(self.bindings) do
        if b.team == team or (team == 0 and b.isOnly == true) then
            local panel = self.panels[b.id]
            if panel ~= nil then return panel, memberIndex end
        end
    end
    return nil, nil
end

function P:RefreshProjection()
    if self.running ~= true then return false end
    local projection = type(Feature.GetRaidOverlayProjection) == "function" and Feature:GetRaidOverlayProjection() or nil
    self.displayRows = type(projection) == "table" and type(projection.rows) == "table" and projection.rows or {}
    self.candidates = {}
    self.activePanels = {}
    self.selfSlot = nil
    for _, row in ipairs(self.displayRows) do
        local panel = self:GetOverlaySlot(row)
        if panel ~= nil then self.activePanels[panel.id] = true end
        if row.isCandidate == true then self.candidates[#self.candidates + 1] = row end
        if row.isSelf == true then self.selfSlot = panel ~= nil and { id = panel.id, index = tonumber(row.memberIndex) or 0 } or nil end
    end
    self.rosterCount = type(projection) == "table" and tonumber(projection.rosterCount) or 0
    self.metrics.refreshes = (tonumber(self.metrics.refreshes) or 0) + 1
    self:RefreshHighlights()
    return true
end

function P:RefreshHighlights(nowMs)
    if self.running ~= true then return false end
    local settings = Settings()
    local calibration = settings.calibration == true
    local useRaidRuntime = self.rosterCount > 1
    for id, panel in pairs(self.panels) do
        local isActive = self.activePanels[id] == true or calibration == true
        local show = calibration == true or (useRaidRuntime and self.activePanels[id] == true)
        S.UI:SetVisible(panel.window, show, self.owner)
        S.UI:SetPickable(panel.window, calibration, self.owner)
        if type(panel.window.EnableDrag) == "function" then pcall(function() panel.window:EnableDrag(calibration) end) end
        if show then
            S.UI:TrySetUILayer(panel.window, "system")
            if type(panel.window.Raise) == "function" then pcall(function() panel.window:Raise() end) end
        end
        S.UI:SetVisible(panel.calibrationBg, calibration, self.owner)
        if panel.calibrationBg ~= nil then S.UI:SetColor(panel.calibrationBg, 0.04, 0.30, 0.58, 0.52, self.owner) end
        S.UI:SetVisible(panel.title, calibration, self.owner)
        for _, border in ipairs(panel.borders) do
            S.UI:SetVisible(border, calibration, self.owner)
            S.UI:SetColor(border, 0.18, 0.82, 1.00, 0.92, self.owner)
        end
        for i = 1, SLOTS_PER_PANEL do
            S.UI:SetVisible(panel.ranks[i], false, self.owner)
            S.UI:SetVisible(panel.calibrationLabels[i], calibration, self.owner)
            S.UI:SetVisible(panel.slots[i], calibration, self.owner)
            if calibration then S.UI:SetColor(panel.slots[i], 0.18, 0.72, 1.00, 0.16, self.owner) end
        end
    end
    if not useRaidRuntime and not calibration then return true end
    nowMs = nowMs or (S.NowMs and S.NowMs() or 0)
    local testColors = settings.testColors == true
    for _, row in ipairs(self.displayRows) do
        local panel, localIndex = self:GetOverlaySlot(row)
        if panel ~= nil and localIndex ~= nil then
            local slot = panel.slots[localIndex]
            if slot ~= nil then
                if calibration then
                    S.UI:SetVisible(slot, true, self.owner)
                else
                    local r, g, b, a
                    if testColors then
                        local hue = ((tonumber(row.teamIndex) or 1) - 1) * 0.5 + (tonumber(row.memberIndex) or 1) / (SLOTS_PER_PANEL + 1)
                        r, g, b = HslColor(hue, 0.65, 0.55)
                        a = 0.55
                    else
                        local color = type(row.color) == "table" and row.color or { r=1, g=0.2, b=0.2, a=0.9 }
                        r, g, b = N(color.r, 1), N(color.g, 0.2), N(color.b, 0.2)
                        a = row.isCandidate == true and AnimatedAlpha(color, settings.effectMode, nowMs) or N(color.a, 0.42)
                    end
                    S.UI:SetColor(slot, r, g, b, a, self.owner)
                    S.UI:SetVisible(slot, true, self.owner)
                    if row.isCandidate == true and not calibration and settings.showRanks == true and N(row.rank, 99) <= N(settings.rankCount, 10) then
                        S.UI:SetText(panel.ranks[localIndex], tostring(row.rank or ""), self.owner)
                        if panel.ranks[localIndex].style ~= nil then S.UI:SetColor(panel.ranks[localIndex].style, 1, 1, 1, N(settings.rankAlpha, 1), self.owner) end
                        S.UI:SetVisible(panel.ranks[localIndex], true, self.owner)
                    end
                end
            end
        end
    end
    -- Locate-self diagnostic flash.
    if nowMs < self.locateUntil and self.selfSlot ~= nil then
        local panel = self.panels[self.selfSlot.id]
        local slot = panel and panel.slots[self.selfSlot.index]
        if slot ~= nil then
            S.UI:SetColor(slot, 1, 1, 0.2, 0.95, self.owner)
            S.UI:SetVisible(slot, true, self.owner)
        end
    end
    return true
end

function P:AnimateTick()
    if self.running ~= true then return false end
    local settings = Settings()
    if math.floor(N(settings.effectMode, 1)) == 1 then return true end
    local nowMs = S.NowMs and S.NowMs() or 0
    for _, candidate in ipairs(self.candidates) do
        local panel, localIndex = self:GetOverlaySlot(candidate)
        if panel ~= nil and localIndex ~= nil then
            local slot = panel.slots[localIndex]
            if slot ~= nil then
                local color = type(candidate.color) == "table" and candidate.color or { r=1, g=0.2, b=0.2, a=0.9 }
                S.UI:SetColor(slot, N(color.r, 1), N(color.g, 0.2), N(color.b, 0.2), AnimatedAlpha(color, settings.effectMode, nowMs), self.owner)
            end
        end
    end
    return true
end

function P:ReconcileEffectTask()
    local settings = Settings()
    local needTask = self.running == true and self.calibrationMode ~= true and math.floor(N(settings.effectMode, 1)) ~= 1
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
    self.bindings = type(Feature.GetEffectivePanelBindings) == "function" and Feature:GetEffectivePanelBindings() or {}
    if calibration ~= true and runtimeMode ~= true then return true end
    local ok, err = self:EnsurePanels(self.bindings)
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
    ok = S.Events:SubscribeInternal("v3.healer.locate_self", self.activeOwner, function() self.locateUntil = (S.NowMs and S.NowMs() or 0) + 2500; self:RefreshHighlights() end)
    if ok ~= true then Feature:ReleaseConsumer(self.consumerToken); self.consumerHeld=false; return false,"raid overlay locate event subscribe failed" end
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
    for _, panel in pairs(self.panels) do S.UI:SetVisible(panel.window, false, self.owner); S.UI:SetPickable(panel.window, false, self.owner) end
    if self.running == true then self.metrics.stops = (tonumber(self.metrics.stops) or 0) + 1 end
    self.running=false; self.calibrationMode=false; self.candidates={}; self.displayRows={}; self.rosterCount=0; self.selfSlot=nil
    return true
end

function P:Reconcile(reason)
    local settings = Settings()
    self.settings = settings
    self.bindings = type(Feature.GetEffectivePanelBindings) == "function" and Feature:GetEffectivePanelBindings() or {}
    local calibration = settings.calibration == true
    local shouldRun = calibration or (FeatureEnabled() and settings.enabled == true)
    if shouldRun then
        if self.running == true and self.calibrationMode ~= calibration then
            local stopped, stopErr = self:Stop("raid_overlay_mode_switch")
            if stopped ~= true then return false, stopErr end
        end
        if self.running ~= true then
            local ok, err = self:Start(reason)
            if ok ~= true then return false, err end
        end
        local ok, err = self:EnsurePanels(self.bindings)
        if ok ~= true then return false, err end
        if calibration == true and type(Feature.HasConsumer) == "function" and Feature:HasConsumer(self.consumerToken) ~= true then
            ok, err = Feature:AcquirePreviewConsumer(self.consumerToken)
            if ok ~= true then return false, err end
            self.consumerHeld = true
            if S.Events ~= nil and type(S.Events.SubscribeInternal) == "function" then
                S.Events:SubscribeInternal("v3.healer.updated", self.activeOwner, function() self:RefreshProjection() end)
                S.Events:SubscribeInternal("v3.healer.locate_self", self.activeOwner, function() self.locateUntil = (S.NowMs and S.NowMs() or 0) + 2500; self:RefreshHighlights() end)
            end
        end
        self:LayoutAll(); self:RefreshProjection(); return self:ReconcileEffectTask()
    end
    return self:Stop(reason)
end

function P:Describe()
    return {
        version=self.version, running=self.running==true, calibrationMode=self.calibrationMode==true, consumerHeld=self.consumerHeld==true,
        taskActive=self.taskActive==true, allocatedPanels=self.metrics.allocatedPanels, rosterCount=tonumber(self.rosterCount) or 0,
        refreshes=tonumber(self.metrics.refreshes) or 0, effectTicks=tonumber(self.metrics.effectTicks) or 0,
        dragCommits=tonumber(self.metrics.dragCommits) or 0, bindings=#self.bindings,
    }
end

if S.Events ~= nil and type(S.Events.SubscribeInternal) == "function" then
    S.Events:SubscribeInternal((S.FeatureRuntime and S.FeatureRuntime.LifecycleTopic) or "v3.feature.lifecycle", P,
        function(_, featureId) if tostring(featureId or "") == FEATURE_ID then P:Reconcile("feature_lifecycle") end end)
    S.Events:SubscribeInternal("v3.healer.presentation", P,
        function(_, scope) if tostring(scope or "") == "raid" then P:Reconcile("raid_settings") end end)
end
P:Reconcile("bootstrap")
