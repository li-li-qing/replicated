------------------------------------------------------------------------
-- Replicated Suite V3 - Team Sacrifice Dance head overlay (.18.122)
--
-- 中文维护（2026-10-02）：只消费独立牺牲之舞 Feature，职责关闭不释放此视觉池。
-- Presentation-only consumer of combat_sac_highlight.sacActive. Domain owns
-- roster/class/Aura facts; this file owns the short visual projection cadence.
-- It creates no Native widget inside Tick/task execution: pool allocation occurs
-- only on projection/lifecycle edges.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local Feature = S.Features and S.Features.combat_sac_highlight or nil
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
    return S.FeatureRuntime ~= nil and S.FeatureRuntime:IsEnabled(Feature.Id) == true
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
    if S.Theme and S.Theme.SetWorldTextPalette then S.Theme:SetWorldTextPalette(label) end
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
    if type(projection) ~= "table" or type(projection.ProjectUnitBatch) ~= "function" then self.lastError="screen_projection_unavailable"; self:HideAll(); return false end -- 中文维护：无显示时必须区分没有 Buff 与投影服务缺失，导出只读此事实。
    local tokens = {}
    for index = 1, math.min(#self.active, #self.pool) do tokens[index] = self.active[index].unitToken end
    -- 中文维护（2026-10-03，sac-native-screen-authority）：真机报告证明本人 Buff 已命中，但严格相机世界门
    -- 算出 forward=-2026.44，先于 Native screen 读取直接隐藏。RU 相机/单位 world 空间不能在本高亮中混用。
    -- 与 UnitLines/BuffDisplay 一样以共享服务的原生 screen 坐标为 Authority；非正 Native depth 和读不到点
    -- 仍由 ScreenProjectionV3 拒绝。这里不猜相机偏移、不改全局 strict 契约，也不对本人伪造固定屏幕位置。
    local points, batchStatus = projection:ProjectUnitBatch(tokens, {
        worldZOffset = 1,
    })
    self.metrics.ticks = (tonumber(self.metrics.ticks) or 0) + 1
    self.metrics.projections = (tonumber(self.metrics.projections) or 0) + #tokens
    local visible = 0
    self.lastError=nil -- 中文维护：投影服务恢复后清掉当前错误；每个隐藏原因仍由 lastPoints 保留。
    self.lastBatchStatus=batchStatus
    self.lastProjectionAt=S.NowMs and S.NowMs()
    self.lastPoints=points -- 中文维护：每帧替换最多16点，仅保留坐标/失败原因；不积累帧日志或额外发起投影查询。
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
    if ok ~= true then self.lastError=err; self:Stop("pool_failed"); return false, err end
    self.active = active
    -- 中文维护：重复投影边沿保留待执行视觉任务；只有从无活跃成员进入活跃状态才分配调度资源。
    if self.running ~= true or not (S.Scheduler.tasks and S.Scheduler.tasks[self.taskName]) then
        ok = S.Scheduler:AddTask(self.taskName, 50, function() return P:VisualTick() end, false, self, "P4", 1)
    end
    if ok ~= true then self.lastError="team sac overlay task failed"; self:Stop("task_failed"); return false, self.lastError end
    if type(S.Scheduler.SetTaskModule) == "function" then S.Scheduler:SetTaskModule(self.taskName, Feature.Id, true) end
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
        visible=self.lastVisible,lastError=self.lastError,hidden=tonumber(self.metrics.hidden) or 0,
        lastBatchStatus=self.lastBatchStatus,lastProjectionAt=self.lastProjectionAt, -- 中文维护：读者可识别报告中的坐标是何时采集，避免把技能结束后的历史点误判为当前活跃。
        lastPoints=S.Utils and S.Utils.DeepCopy and S.Utils.DeepCopy(self.lastPoints or {}) or self.lastPoints, -- 中文维护：导出包含每个活跃成员为何隐藏；缓存归渲染器，不能由诊断修改。
    }
end

if S.Events ~= nil and type(S.Events.SubscribeInternal) == "function" then
    S.Events:SubscribeInternal(Feature.UpdateTopic, P, function() P:Reconcile("team_tools_projection") end)
    S.Events:SubscribeInternal((S.FeatureRuntime and S.FeatureRuntime.LifecycleTopic) or "v3.feature.lifecycle", P,
        function(_, featureId) if tostring(featureId or "") == Feature.Id then P:Reconcile("sac_lifecycle") end end)
end
P:Reconcile("bootstrap")
P.TeamSacPresentationContractVersion = 1
