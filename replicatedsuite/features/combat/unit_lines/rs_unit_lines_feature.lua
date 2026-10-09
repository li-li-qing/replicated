------------------------------------------------------------------------
-- Replicated Suite V3 - combat_unit_lines Feature Authority
--
-- Phase 1 Batch E（2026-09-28）：从 features/rs_business_bridge.lua 机械搬迁。
-- 只改变源码边界，不改业务行为：Feature ID、Store ID/Schema、UpdateTopic、Demand owner、
-- Commands、Projection shape、ApiDependencies、Scheduler task name
-- （v3_business_unit_lines_refresh，1ms 下限的高频车道）与 VisualGuideLimits 默认值全部逐字一致。
--
-- Authority 边界：单位屏幕/世界坐标事实来自 ScreenProjectionV3 的已校准读数；
-- 本文件只做连线投影与颜色归一，不做全单位枚举。
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local FSF = S.FeatureSliceFactory
if type(FSF) ~= "table" then error("FeatureSliceFactory unavailable for combat_unit_lines") end
local Copy, Call, Action, Text, Number, Trim, Scalar = FSF.Copy, FSF.Call, FSF.Action, FSF.Text, FSF.Number, FSF.Trim, FSF.Scalar
local Load, PersistStateMutation, NewFeature = FSF.Load, FSF.PersistStateMutation, FSF.NewFeature
local UnitApi = rawget(_G, "X2Unit")

local UNIT_LINE_TASK = "v3_business_unit_lines_refresh"
local UNIT_LINE_PAIRS = {
    { key="target", label="自己 ↔ 当前目标", from="player", to="target", setting="showTarget" },
    { key="targettarget", label="当前目标 ↔ 目标的目标", from="target", to="targettarget", setting="showTargetTarget" },
    { key="focus", label="自己 ↔ 焦点目标", from="player", to="watchtarget", setting="showFocusTarget" },
    { key="focustarget", label="焦点目标 ↔ 焦点目标的目标", from="watchtarget", to="watchtargettarget", setting="showFocusTargetTarget" },
}
-- Refresh floor is 1 ms (never clamped up): the unit-line overlay must be able
-- to follow the target at frame cadence. The high-frequency scheduler lane
-- still respects the user-selected cadence and only enables sub-16 ms when the
-- user actually asks for it.

local function UnitLineInterval(feature)
    -- 2026-09-15: 1000ms is only the recommended slider ceiling. Slower user
    -- cadences are safe and reduce work, so the Domain accepts them up to the
    -- shared technical envelope instead of mirroring the old UI maximum.
    return math.max(S.VisualGuideLimits.refreshMsHardMin or 1, math.min(S.VisualGuideLimits.refreshMsHardMax or 60000,
        math.floor(tonumber(feature.State.refreshMs) or 100)))
end
local function StartUnitLineTask(feature)
    if S.Scheduler == nil or type(S.Scheduler.AddHighFrequencyTask) ~= "function" then return false, "单位连线 Scheduler 不可用" end
    local added = S.Scheduler:AddHighFrequencyTask(UNIT_LINE_TASK, UnitLineInterval(feature), function()
        if feature.enabled == true and (tonumber(feature.consumerCount) or 0) > 0 then feature.Authority:Refresh("visual_tick") end
    end, false, feature, "P1", 1)
    if added ~= true then return false, "单位连线刷新任务创建失败" end
    if type(S.Scheduler.SetTaskModule) == "function" then S.Scheduler:SetTaskModule(UNIT_LINE_TASK, feature.Id) end
    return true
end
local UNIT_LINE_DEFAULT_COLORS = {
    target = { 1.00, 0.72, 0.12 },
    targettarget = { 0.94, 0.42, 0.20 },
    focus = { 0.35, 0.82, 1.00 },
    focustarget = { 0.67, 0.52, 1.00 },
}
S.VisualGuideLimits = S.VisualGuideLimits or (S.Constants and S.Constants.VisualGuide) or {
    pointSizeMin = 2, pointSizeDefaultMax = 10, pointSizeHardMax = 24,
    unitLineDensityHardMin = 2, unitLineDensityHardMax = 160,
    rangeDensityHardMin = 3, rangeDensityHardMax = 192,
    rangeRadiusHardMin = 0.5, rangeRadiusHardMax = 1000,
    refreshMsHardMin = 1, refreshMsHardMax = 60000,
}

local function NormalizeUnitLineColors(value)
    local out = {}
    for key, default in pairs(UNIT_LINE_DEFAULT_COLORS) do
        local entry = type(value) == "table" and value[key] or nil
        if type(entry) == "table" then
            out[key] = {
                math.max(0, math.min(1, tonumber(entry[1]) or default[1])),
                math.max(0, math.min(1, tonumber(entry[2]) or default[2])),
                math.max(0, math.min(1, tonumber(entry[3]) or default[3])),
            }
        else
            out[key] = { default[1], default[2], default[3] }
        end
    end
    return out
end
local UnitLines = NewFeature("combat_unit_lines", {
    apiDependencies = { "X2Unit:GetUnitScreenPosition", "X2Unit:GetUnitWorldPositionByTarget" },
    state = { pointCount = 24, pointSize = 4, opacity = 0.78, refreshMs = 100,
        showTarget = true, showTargetTarget = true, showFocusTarget = true, showFocusTargetTarget = true,
        colors = Copy(UNIT_LINE_DEFAULT_COLORS),
        points = {}, sizes = {},
        pairPoints = Copy({ target = 24, targettarget = 24, focus = 24, focustarget = 24 }),
        pairSizes = Copy({ target = 4, targettarget = 4, focus = 4, focustarget = 4 }) },
    default = { pointCount = 24, pointSize = 4, opacity = 0.78, refreshMs = 100,
        showTarget = true, showTargetTarget = true, showFocusTarget = true, showFocusTargetTarget = true,
        colors = Copy(UNIT_LINE_DEFAULT_COLORS),
        points = {}, sizes = {},
        pairPoints = Copy({ target = 24, targettarget = 24, focus = 24, focustarget = 24 }),
        pairSizes = Copy({ target = 4, targettarget = 4, focus = 4, focustarget = 4 }) },
    observationContractVersion = 2,
    reconcileDemand = function(feature, before, after)
        local b, a = tonumber(before and before.count) or 0, tonumber(after and after.count) or 0
        if b <= 0 and a > 0 then return StartUnitLineTask(feature)
        elseif b > 0 and a <= 0 and S.Scheduler ~= nil then S.Scheduler:RemoveTask(UNIT_LINE_TASK) end
        return true
    end,
    onDisable = function() if S.Scheduler ~= nil then S.Scheduler:RemoveTask(UNIT_LINE_TASK) end return true end,
    read = function(feature)
        -- Bounded runtime diagnostics for the RU acceptance workflow; lives on
        -- the Feature object, never persisted, never printed per frame.
        local dia = feature.Diagnostics
        if dia == nil then
            dia = { enabled = false, consumerCount = 0, attemptedPairs = 0, drawnRows = 0,
                lastStatus = "idle", lastFailureReason = nil, lastReadAt = 0, lastSuccessAt = 0,
                endpointCollapsed = 0, projection = nil }
            feature.Diagnostics = dia
        end
        dia.enabled = feature.enabled == true
        dia.consumerCount = tonumber(feature.consumerCount) or 0
        dia.lastReadAt = (S.NowMs and S.NowMs() or 0)
        dia.attemptedPairs = 0
        dia.drawnRows = 0
        dia.endpointCollapsed = 0
        dia.endpoints = {} -- 维护：最多五个配置token，本次刷新覆盖；不写State/Store、不累计历史目标。
        local projection = S.Services and S.Services.ScreenProjectionV3 or nil
        if type(projection) ~= "table" or type(projection.ProjectUnitBatch) ~= "function" then
            dia.lastStatus = "unavailable"
            dia.lastFailureReason = "SCREEN_PROJECTION_UNAVAILABLE"
            return {}, "unavailable", "ScreenProjectionV3 v7 不可用"
        end
        local rows, attempted, failed, tokens = {}, 0, {}, {}
        local seen = {}
        for _, pair in ipairs(UNIT_LINE_PAIRS) do
            if feature.State[pair.setting] ~= false then
                attempted = attempted + 1
                if seen[pair.from]~=true then seen[pair.from]=true; tokens[#tokens+1]=pair.from end
                if seen[pair.to]~=true then seen[pair.to]=true; tokens[#tokens+1]=pair.to end
            end
        end
        dia.attemptedPairs = attempted
        if attempted == 0 then
            dia.lastStatus = "empty"
            dia.lastFailureReason = "ALL_PAIRS_DISABLED"
            return {}, "empty", "所有连线类型均已关闭"
        end
        -- .18.131b reference alignment (rp_api.lua UnitScreenPoint): the
        -- working references draw lines from RAW native screen positions and
        -- cull only depth<=0 — there is NO world-vs-camera front-hemisphere
        -- gate. That gate classified the PLAYER endpoint as "相机背后" on the
        -- live client (self↔target died with 单位在相机背后), because the
        -- GetViewCameraPos basis and GetUnitWorldPositionByTarget(false) world
        -- space do not agree on RU. Native depth is the proven behind-cull.
        local projected,batchErr = projection:ProjectUnitBatch(tokens,{ worldZOffset=1 })
        projected=type(projected)=="table" and projected or {}
        -- 维护：健康计数必须在本次采集之后读取，旧实现报告的是上一批。端点来自Service事实，
        -- 保存screen/world各自的错误给统一诊断，避免焦点缺失永远只有一个泛化字符串。
        dia.projection = projection.GetHealth ~= nil and projection:GetHealth() or nil
        for _,token in ipairs(tokens) do
            local point=projected[token]
            if type(point)=="table" then
                dia.endpoints[token]={visible=point.visible==true,x=point.x,y=point.y,depth=point.depth,
                    source=point.source,reason=point.reason,nativeError=point.nativeError,worldError=point.worldError}
            end
        end
        for _, pair in ipairs(UNIT_LINE_PAIRS) do
            if feature.State[pair.setting] ~= false then
                local a,b=projected[pair.from],projected[pair.to]
                if type(a)=="table" and a.visible==true and type(b)=="table" and b.visible==true then
                    -- Collapse guard uses SEGMENT LENGTH, not per-axis deltas:
                    -- a 2-4px near-coincident segment passed the old <=1px
                    -- filter and the renderer then stacked ~24 dots inside
                    -- those few pixels -- visually "the whole line is one
                    -- dot". Anything shorter than two dot widths is invisible
                    -- anyway.
                    local collapseLimit = math.max(4, (tonumber(feature.State.pointSize) or 4) * 2)
                    local segDx = (tonumber(a.x) or 0) - (tonumber(b.x) or 0)
                    local segDy = (tonumber(a.y) or 0) - (tonumber(b.y) or 0)
                    if (segDx * segDx + segDy * segDy) <= collapseLimit * collapseLimit then
                        dia.endpointCollapsed = (tonumber(dia.endpointCollapsed) or 0) + 1
                        failed[#failed+1] = pair.label .. "（端点重合，跳过绘制）"
                    else
                        rows[#rows+1] = { key="unit_line:"..pair.key, pairKey=pair.key, name=pair.label,
                            text=pair.label, statusText="可绘制", tone="green", x1=a.x,y1=a.y,x2=b.x,y2=b.y,
                            source1=a.source, source2=b.source, fromToken=pair.from, toToken=pair.to }
                    end
                else
                    local reason=(type(a)=="table" and a.reason) or (type(b)=="table" and b.reason) or batchErr or "当前无单位"
                    if reason=="behind_camera" then reason="单位在相机背后（不绘制）" end
                    failed[#failed+1] = pair.label .. "（" .. tostring(reason) .. "）"
                end
            end
        end
        dia.drawnRows = #rows
        if #rows == 0 then
            dia.lastStatus = "empty"
            dia.lastFailureReason = failed[1] and tostring(failed[1]) or tostring(batchErr or "EMPTY")
            return {}, "empty", table.concat(failed, "；")
        end
        dia.lastStatus = (#failed > 0 and "partial" or "ready")
        dia.lastFailureReason = (#failed > 0 and tostring(failed[1]) or nil)
        dia.lastSuccessAt = dia.lastReadAt
        return rows, (#failed > 0 and "partial" or "ready"), (#failed > 0 and table.concat(failed, "；") or nil)
    end,
    projection = function(feature) return { pointCount=feature.State.pointCount, pointSize=feature.State.pointSize, opacity=feature.State.opacity,
        pointSizeMin=S.VisualGuideLimits.pointSizeMin, pointSizeDefaultMax=S.VisualGuideLimits.pointSizeDefaultMax, pointSizeHardMax=S.VisualGuideLimits.pointSizeHardMax,
        pointCountHardMin=S.VisualGuideLimits.unitLineDensityHardMin, pointCountHardMax=S.VisualGuideLimits.unitLineDensityHardMax,
        refreshHardMin=S.VisualGuideLimits.refreshMsHardMin, refreshHardMax=S.VisualGuideLimits.refreshMsHardMax,
        refreshMs=UnitLineInterval(feature), showTarget=feature.State.showTarget~=false, showTargetTarget=feature.State.showTargetTarget~=false,
        showFocusTarget=feature.State.showFocusTarget~=false, showFocusTargetTarget=feature.State.showFocusTargetTarget~=false,
        colors=NormalizeUnitLineColors(feature.State.colors),
        pairPoints=feature.State.pairPoints or {}, pairSizes=feature.State.pairSizes or {},
        samplingMode="adaptive_screen_space", pointBudgetMode="cadence_pressure_bounded", refreshPriority="P1_visual" } end,
    commands = {
        SetPointCount = function(feature, value)
            -- 8..48 is Presentation guidance only; Feature owns the real safety
            -- envelope so exact entry (e.g. 58) is persisted and renderer-visible.
            value=math.max(S.VisualGuideLimits.unitLineDensityHardMin or 2,math.min(S.VisualGuideLimits.unitLineDensityHardMax or 160,math.floor(tonumber(value) or 24)))
            return PersistStateMutation(feature,"unit_lines_points",function(state) state.pointCount=value; return true end)
        end,
        SetPointSize = function(feature, value) value=math.max(S.VisualGuideLimits.pointSizeMin,math.min(S.VisualGuideLimits.pointSizeHardMax,math.floor(tonumber(value) or 4))); return PersistStateMutation(feature,"unit_lines_size",function(state) state.pointSize=value; return true end) end,
        SetOpacity = function(feature, value) value=math.max(0.1,math.min(1,tonumber(value) or 0.78)); return PersistStateMutation(feature,"unit_lines_opacity",function(state) state.opacity=value; return true end) end,
        SetRefreshMs = function(feature, value)
            value=math.max(S.VisualGuideLimits.refreshMsHardMin or 1,math.min(S.VisualGuideLimits.refreshMsHardMax or 60000,math.floor(tonumber(value) or 100)))
            local ok,err=PersistStateMutation(feature,"unit_lines_refresh",function(state) state.refreshMs=value; return true end)
            if ok~=true then return false,err end
            if feature.enabled==true and (tonumber(feature.consumerCount) or 0)>0 then return StartUnitLineTask(feature) end
            return true
        end,
        SetPairEnabled = function(feature, key, value)
            local map={target="showTarget",targettarget="showTargetTarget",focus="showFocusTarget",focustarget="showFocusTargetTarget"}
            local field=map[tostring(key or "")]; if field==nil then return false,"未知连线类型" end
            return PersistStateMutation(feature,"unit_lines_pair_"..tostring(key),function(state) state[field]=value==true; return true end)
        end,
        SetPairColor = function(feature, key, r, g, b)
            key=tostring(key or "")
            if UNIT_LINE_DEFAULT_COLORS[key] == nil then return false,"未知连线类型" end
            r=math.max(0,math.min(1,tonumber(r) or 1)); g=math.max(0,math.min(1,tonumber(g) or 1)); b=math.max(0,math.min(1,tonumber(b) or 1))
            return PersistStateMutation(feature,"unit_lines_color_"..key,function(state)
                state.colors = state.colors or {}
                state.colors[key] = { r, g, b }
                return true
            end)
        end,
        SetPairPoints = function(feature, key, value)
            key=tostring(key or "")
            if UNIT_LINE_DEFAULT_COLORS[key] == nil then return false,"未知连线类型" end
            value=math.max(S.VisualGuideLimits.unitLineDensityHardMin or 2,math.min(S.VisualGuideLimits.unitLineDensityHardMax or 160,math.floor(tonumber(value) or 24)))
            return PersistStateMutation(feature,"unit_lines_pair_points_"..key,function(state)
                state.pairPoints = state.pairPoints or {}
                state.pairPoints[key] = value
                return true
            end)
        end,
        SetPairSize = function(feature, key, value)
            key=tostring(key or "")
            if UNIT_LINE_DEFAULT_COLORS[key] == nil then return false,"未知连线类型" end
            value=math.max(S.VisualGuideLimits.pointSizeMin,math.min(S.VisualGuideLimits.pointSizeHardMax,math.floor(tonumber(value) or 4)))
            return PersistStateMutation(feature,"unit_lines_pair_size_"..key,function(state)
                state.pairSizes = state.pairSizes or {}
                state.pairSizes[key] = value
                return true
            end)
        end,
    },
})
UnitLines.VisualGuideContractVersion = 5
UnitLines.AdaptiveDensityContractVersion = 2
UnitLines.SmoothRefreshContractVersion = 1
UnitLines.FrontHemisphereContractVersion = 1
UnitLines.ProjectionConsistencyContractVersion = 1
-- 中文维护（performance-visual-hotpath-1）：绘制只复制端点、密度和样式；完整页面投影仍
-- 使用原GetProjection。每次独立快照不暴露Authority/State，不缓存玩家或目标的实时事实。
UnitLines.RenderProjectionContractVersion = 1
function UnitLines:GetRenderProjection()
    local state=self.State
    local snapshot={revision=self.Authority.revision,status=self.Authority.status,error=self.Authority.error,
        rows={},pointCount=state.pointCount,pointSize=state.pointSize,opacity=state.opacity,
        refreshMs=UnitLineInterval(self),colors=NormalizeUnitLineColors(state.colors),
        pairPoints=Copy(state.pairPoints or {}),pairSizes=Copy(state.pairSizes or {})}
    for i,row in ipairs(self.Authority.rows) do
        snapshot.rows[i]={key=row.key,pairKey=row.pairKey,x1=row.x1,y1=row.y1,x2=row.x2,y2=row.y2}
    end
    return snapshot
end
-- UnitLines.Diagnostics is attached lazily by read() (Lua 5.1 main-chunk local budget)

-- 中文维护注释（Phase 3 Batch G，2026-09-29，core-feature-decoupling-1）：把 Diagnostics 投影注册到
-- Core 的取值表。原先 core/rs_diagnostics.lua 直接按 id 读取它（属 CORE_FEATURE 债务）；
-- 现在 Core 只按“用途名”取值，业务 Feature id 只出现在本目录。provider 每次实时调用、不缓存：
-- Diagnostics 是 read() 惰性挂上的，取值时必须现读，不能在注册时抓一份快照。
local providers = S.FeatureHealthProviders
if type(providers) == "table" then
    providers:Register("unit_lines_diagnostics", function()
        local feature = S.Features and S.Features.combat_unit_lines or nil
        return type(feature) == "table" and type(feature.Diagnostics) == "table" and feature.Diagnostics or nil
    end)
end
