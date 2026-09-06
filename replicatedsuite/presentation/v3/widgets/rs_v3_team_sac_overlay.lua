------------------------------------------------------------------------
-- Replicated Suite V3 - Team Sacrifice Dance head overlay (.18.122)
--
-- Presentation-only consumer of combat_team_tools.sacActive.  Domain owns
-- roster/class/Aura facts; this file owns the short visual projection cadence.
-- It creates no Native widget inside Tick/task execution: pool allocation occurs
-- only on projection/lifecycle edges.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local Feature = S.Features and S.Features.combat_team_tools or nil
if type(Feature) ~= "table" or type(S.UI) ~= "table" or type(S.Scheduler) ~= "table" then return end

S.UIV3 = S.UIV3 or {}
S.UIV3.TeamSacOverlay = S.UIV3.TeamSacOverlay or {}
local P = S.UIV3.TeamSacOverlay

P.version = 1
P.owner = "v3:team_sac_overlay"
P.taskName = "v3_team_sac_overlay_visual"
P.pool = P.pool or {}
P.active = P.active or {}
P.running = P.running == true
P.lastVisible = tonumber(P.lastVisible) or 0
P.metrics = P.metrics or { allocations = 0, ticks = 0, projections = 0, hidden = 0 }

local function FeatureEnabled()
    return S.FeatureRuntime ~= nil and S.FeatureRuntime:IsEnabled("combat_team_tools") == true
end

local function NewColorDrawable(parent, layer)
    if parent == nil or type(parent.CreateColorDrawable) ~= "function" then return nil end
    local ok, drawable = pcall(function() return parent:CreateColorDrawable(1, 1, 1, 1, layer or "artwork") end)
    return ok and drawable or nil
end

local function MakeMarker(index)
    local root, err = S.UI:CreateEmptyWidget(UIParent, "v3_team_sac_marker_" .. tostring(index), 0, 0, 154, 27, false, P.owner)
    if root == nil then return nil, err end
    root.rsUiOwner = P.owner
    local bg = NewColorDrawable(root, "artwork")
    local accent = NewColorDrawable(root, "overlay")
    local label = S.UI:CreateLabel(root, "v3_team_sac_label_" .. tostring(index), "SAC", 8, 0, 142, 27, 10, "strong", "LEFT", true)
    if bg == nil or accent == nil or label == nil then S.UI:SetVisible(root, false, P.owner); return nil, "team_sac_marker_child_create_failed" end
    S.UI:SetAnchor(bg, root, 0, 2, P.owner)
    S.UI:SetExtent(bg, 154, 23, P.owner)
    S.UI:SetColor(bg, 0.02, 0.025, 0.035, 0.80, P.owner)
    S.UI:SetVisible(bg, true, P.owner)
    S.UI:SetAnchor(accent, root, 0, 2, P.owner)
    S.UI:SetExtent(accent, 4, 23, P.owner)
    S.UI:SetColor(accent, 1, 0.78, 0.12, 0.96, P.owner)
    S.UI:SetVisible(accent, true, P.owner)
    S.UI:SetVisible(root, false, P.owner)
    return { window = root, label = label, bg = bg, accent = accent }
end

function P:EnsurePool(count)
    count = math.max(0, math.min(16, math.floor(tonumber(count) or 0)))
    for index = #self.pool + 1, count do
        local marker, err = MakeMarker(index)
        if marker == nil then return false, err end
        self.pool[index] = marker
        self.metrics.allocations = #self.pool
    end
    return true
end

function P:HideAll()
    for _, marker in ipairs(self.pool) do S.UI:SetVisible(marker.window, false, self.owner) end
    self.lastVisible = 0
end

function P:Stop(reason)
    if self.running == true then S.Scheduler:RemoveTask(self.taskName) end
    self.running = false
    self.active = {}
    self:HideAll()
    return true
end

function P:VisualTick()
    if self.running ~= true or #self.active == 0 then return true end
    local projection = S.Services and S.Services.ScreenProjectionV3 or nil
    if type(projection) ~= "table" or type(projection.ProjectUnitBatch) ~= "function" then self:HideAll(); return false end
    local tokens = {}
    for index = 1, math.min(#self.active, #self.pool) do tokens[index] = self.active[index].unitToken end
    local points = projection:ProjectUnitBatch(tokens, {
        requireFrontHemisphere = true,
        worldZOffset = 1,
        validateNativeAgainstCamera = true,
        reconcileNativeScale = true,
    })
    self.metrics.ticks = (tonumber(self.metrics.ticks) or 0) + 1
    self.metrics.projections = (tonumber(self.metrics.projections) or 0) + #tokens
    local visible = 0
    for index = 1, math.min(#self.active, #self.pool) do
        local row, marker = self.active[index], self.pool[index]
        local point = type(points) == "table" and points[row.unitToken] or nil
        if type(point) == "table" and point.visible == true and tonumber(point.x) ~= nil and tonumber(point.y) ~= nil then
            local name = tostring(row.name or row.unitToken or "")
            S.UI:SetText(marker.label, "牺牲之舞 · " .. name, self.owner)
            S.UI:SetAnchor(marker.window, "UIParent", math.floor(tonumber(point.x) - 77), math.floor(tonumber(point.y) - 62), self.owner)
            S.UI:SetVisible(marker.window, true, self.owner)
            visible = visible + 1
        else
            S.UI:SetVisible(marker.window, false, self.owner)
            self.metrics.hidden = (tonumber(self.metrics.hidden) or 0) + 1
        end
    end
    for index = #self.active + 1, math.max(self.lastVisible, #self.pool) do
        local marker = self.pool[index]
        if marker ~= nil then S.UI:SetVisible(marker.window, false, self.owner) end
    end
    self.lastVisible = visible
    return true
end

function P:Reconcile(reason)
    local projection = type(Feature.GetProjection) == "function" and Feature:GetProjection() or {}
    local enabled = FeatureEnabled() and projection.sacEnabled == true
    local active = enabled and type(projection.sacActive) == "table" and projection.sacActive or {}
    if enabled ~= true or #active == 0 then return self:Stop(reason) end
    local ok, err = self:EnsurePool(#active)
    if ok ~= true then self:Stop("pool_failed"); return false, err end
    self.active = active
    ok = S.Scheduler:AddTask(self.taskName, 50, function() return P:VisualTick() end, false, self, "P4", 1)
    if ok ~= true then self:Stop("task_failed"); return false, "team sac overlay task failed" end
    if type(S.Scheduler.SetTaskModule) == "function" then S.Scheduler:SetTaskModule(self.taskName, "combat_team_tools", true) end
    self.running = true
    return self:VisualTick()
end

function P:Describe()
    return {
        version = self.version,
        running = self.running == true,
        active = #self.active,
        allocated = #self.pool,
        ticks = tonumber(self.metrics.ticks) or 0,
        projections = tonumber(self.metrics.projections) or 0,
    }
end

if S.Events ~= nil and type(S.Events.SubscribeInternal) == "function" then
    S.Events:SubscribeInternal(Feature.UpdateTopic, P, function() P:Reconcile("team_tools_projection") end)
    S.Events:SubscribeInternal((S.FeatureRuntime and S.FeatureRuntime.LifecycleTopic) or "v3.feature.lifecycle", P,
        function(_, featureId) if tostring(featureId or "") == "combat_team_tools" then P:Reconcile("team_tools_lifecycle") end end)
end
P:Reconcile("bootstrap")
P.TeamSacPresentationContractVersion = 1
