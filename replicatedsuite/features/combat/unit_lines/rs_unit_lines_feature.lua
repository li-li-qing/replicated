-- Replicated Suite · 单位连线功能入口
-- 作者：Replicated
-- QQ群：1104129461
-- 屏幕/世界坐标来自 ScreenProjectionV3，此处只做连线与颜色投影，不枚举全部单位。
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
-- 刷新下限1ms，不向上钳制，连线可跟随目标帧节奏；高频 Scheduler 仍遵守用户设置，仅用户实际要求时启用低于16ms节奏。

-- 只保留当前四开关的静态拓扑和十二个颜色原值；不保留单位/屏幕事实，最后一个 Consumer 释放即清空。
local unitLineTopology, unitLineColorCache
local function ClearUnitLinePreparation()
    unitLineTopology, unitLineColorCache = nil, nil
end
local function UnitLineTopology(feature)
    local state = feature.State
    -- 每次现读四个开关，直接修改 State 和同步回调改配置都不能等事件或 TTL 才生效。
    local mask = (state.showTarget ~= false and 1 or 0) + (state.showTargetTarget ~= false and 2 or 0)
        + (state.showFocusTarget ~= false and 4 or 0) + (state.showFocusTargetTarget ~= false and 8 or 0)
    local active = feature.enabled == true and (tonumber(feature.consumerCount) or 0) > 0
    if not active then unitLineTopology = nil end
    if unitLineTopology ~= nil and unitLineTopology.mask == mask then return unitLineTopology end
    local plan, seen = { mask=mask, tokens={}, attempted=0 }, {}
    for _, pair in ipairs(UNIT_LINE_PAIRS) do
        if state[pair.setting] ~= false then
            plan.attempted = plan.attempted + 1
            if seen[pair.from] ~= true then seen[pair.from]=true; plan.tokens[#plan.tokens+1]=pair.from end
            if seen[pair.to] ~= true then seen[pair.to]=true; plan.tokens[#plan.tokens+1]=pair.to end
        end
    end
    if active then unitLineTopology = plan end
    return plan
end

local function UnitLineInterval(feature)
    -- 1000ms 仅为滑条推荐上限；更慢节奏安全且减少工作，Domain 接受共享技术范围内数值，不照搬旧 UI 上限。
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
local function PreparedUnitLineColors(feature, isolated)
    local value = feature.State.colors
    -- 非活跃读取仍给独立的即时值，不因诊断/页面读取在无 Demand 时重新建立缓存。
    if feature.enabled ~= true or (tonumber(feature.consumerCount) or 0) <= 0 then
        unitLineColorCache = nil
        return NormalizeUnitLineColors(value)
    end
    local cache = unitLineColorCache
    if cache == nil then cache={ raw={}, colors={} }; unitLineColorCache=cache end
    -- 渲染只复制四组固定 RGB 标量，不为无环颜色数据建立通用 DeepCopy 的 seen 表与递归。
    local out = isolated == true and {} or cache.colors
    for key, default in pairs(UNIT_LINE_DEFAULT_COLORS) do
        local entry = type(value) == "table" and value[key] or nil
        local r, g, b
        if type(entry) == "table" then r,g,b=entry[1],entry[2],entry[3] end
        local raw = cache.raw[key]
        -- 比较原始标量而非表身份：in-place 编辑、字符串数值、nil 和 NaN 都沿用原归一规则。
        if raw == nil or raw[1] ~= r or raw[2] ~= g or raw[3] ~= b then
            cache.raw[key] = { r, g, b }
            -- 畸形通道仍按旧 tonumber 规则回退，但不可让这十二个槽保留任意表/闭包/Native 对象图。
            -- 非标量不记比较键，下次允许重算；正常标量热路径不增加类型检查。
            for i=1,3 do
                local kind = type(cache.raw[key][i])
                if kind ~= "number" and kind ~= "string" and kind ~= "boolean" then cache.raw[key][i]=nil end
            end
            cache.colors[key] = {
                math.max(0, math.min(1, tonumber(r) or default[1])),
                math.max(0, math.min(1, tonumber(g) or default[2])),
                math.max(0, math.min(1, tonumber(b) or default[3])),
            }
        end
        if isolated == true then
            local color = cache.colors[key]
            out[key] = { color[1], color[2], color[3] }
        end
    end
    -- 此表只交给工厂的拷贝边界或本文件渲染快照的拷贝边界，禁止直接公开。
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
        elseif b > 0 and a <= 0 then
            ClearUnitLinePreparation()
            if S.Scheduler ~= nil then S.Scheduler:RemoveTask(UNIT_LINE_TASK) end
        end
        return true
    end,
    -- 关闭与 Demand 归零共用同一释放边界；保留用户 State/Store，只丢本代纯准备结果。
    onDisable = function() ClearUnitLinePreparation(); if S.Scheduler ~= nil then S.Scheduler:RemoveTask(UNIT_LINE_TASK) end return true end,
    read = function(feature)
        -- RU 验收的有界运行诊断保存在 Feature 上，禁止持久化与逐帧打印。
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
        dia.endpoints = {} -- 最多五个配置token，本次刷新覆盖；不写State/Store、不累计历史目标。
        local projection = S.Services and S.Services.ScreenProjectionV3 or nil
        if type(projection) ~= "table" or type(projection.ProjectUnitBatch) ~= "function" then
            dia.lastStatus = "unavailable"
            dia.lastFailureReason = "SCREEN_PROJECTION_UNAVAILABLE"
            return {}, "unavailable", "ScreenProjectionV3 v7 不可用"
        end
        local plan = UnitLineTopology(feature)
        local rows, attempted, failed = {}, plan.attempted, nil
        dia.attemptedPairs = attempted
        if attempted == 0 then
            dia.lastStatus = "empty"
            dia.lastFailureReason = "ALL_PAIRS_DISABLED"
            return {}, "empty", "所有连线类型均已关闭"
        end
        -- Provider 可同步改参/重入；每批仍给新数组，私有拓扑绝不能借给公共服务后污染下一批。
        local source = plan.tokens
        local tokens = { source[1], source[2], source[3], source[4], source[5] }
        -- rp_api.lua 参考仅按 Native depth<=0 裁剪；RU 相机基向量与 world position 空间不一致，额外前半球判断会把 player 误裁。
        local projected,batchErr = projection:ProjectUnitBatch(tokens,{ worldZOffset=1 })
        projected=type(projected)=="table" and projected or {}
        -- 健康计数必须在本次采集之后读取，旧实现报告的是上一批。端点来自Service事实，
        -- 保存screen/world各自的错误给统一诊断，避免焦点缺失永远只有一个泛化字符串。
        dia.projection = projection.GetHealth ~= nil and projection:GetHealth() or nil
        for _,token in ipairs(tokens) do
            local point=projected[token]
            if type(point)=="table" then
                dia.endpoints[token]={visible=point.visible==true,x=point.x,y=point.y,depth=point.depth,
                    source=point.source,reason=point.reason,nativeError=point.nativeError,worldError=point.worldError}
            end
        end
        -- 本批所有线共享点宽；仅省重复纯计算，不改变原来的长度/两点宽度塌缩门槛。
        local collapseLimit = math.max(4, (tonumber(feature.State.pointSize) or 4) * 2)
        local collapseLimitSq = collapseLimit * collapseLimit
        for _, pair in ipairs(UNIT_LINE_PAIRS) do
            -- Provider 返回后仍现读开关，保持同步回调修改配置对当前批次的既有语义。
            if feature.State[pair.setting] ~= false then
                local a,b=projected[pair.from],projected[pair.to]
                if type(a)=="table" and a.visible==true and type(b)=="table" and b.visible==true then
                    -- 塌缩保护按线段长度判定，不能仅看各轴差。2-4px 近重合线段会把约24点堆到几像素内；短于两点宽度的段本来也不可辨认，应隐藏。
                    local segDx = (tonumber(a.x) or 0) - (tonumber(b.x) or 0)
                    local segDy = (tonumber(a.y) or 0) - (tonumber(b.y) or 0)
                    if (segDx * segDx + segDy * segDy) <= collapseLimitSq then
                        dia.endpointCollapsed = (tonumber(dia.endpointCollapsed) or 0) + 1
                        -- 成功批次不需要失败列表；失败路径仍即时分配并保持原诊断顺序。
                        failed = failed or {}
                        failed[#failed+1] = pair.label .. "（端点重合，跳过绘制）"
                    else
                        rows[#rows+1] = { key="unit_line:"..pair.key, pairKey=pair.key, name=pair.label,
                            text=pair.label, statusText="可绘制", tone="green", x1=a.x,y1=a.y,x2=b.x,y2=b.y,
                            source1=a.source, source2=b.source, fromToken=pair.from, toToken=pair.to }
                    end
                else
                    local reason=(type(a)=="table" and a.reason) or (type(b)=="table" and b.reason) or batchErr or "当前无单位"
                    if reason=="behind_camera" then reason="单位在相机背后（不绘制）" end
                    failed = failed or {}
                    failed[#failed+1] = pair.label .. "（" .. tostring(reason) .. "）"
                end
            end
        end
        dia.drawnRows = #rows
        if #rows == 0 then
            dia.lastStatus = "empty"
            dia.lastFailureReason = failed and failed[1] and tostring(failed[1]) or tostring(batchErr or "EMPTY")
            return {}, "empty", failed and table.concat(failed, "；") or ""
        end
        -- 失败列表仅在失败时存在；所有公开状态/错误文本保持原值，不能把空批次冒充可用。
        dia.lastStatus = (failed ~= nil and "partial" or "ready")
        dia.lastFailureReason = (failed ~= nil and tostring(failed[1]) or nil)
        dia.lastSuccessAt = dia.lastReadAt
        return rows, (failed ~= nil and "partial" or "ready"), (failed ~= nil and table.concat(failed, "；") or nil)
    end,
    projection = function(feature) return { pointCount=feature.State.pointCount, pointSize=feature.State.pointSize, opacity=feature.State.opacity,
        pointSizeMin=S.VisualGuideLimits.pointSizeMin, pointSizeDefaultMax=S.VisualGuideLimits.pointSizeDefaultMax, pointSizeHardMax=S.VisualGuideLimits.pointSizeHardMax,
        pointCountHardMin=S.VisualGuideLimits.unitLineDensityHardMin, pointCountHardMax=S.VisualGuideLimits.unitLineDensityHardMax,
        refreshHardMin=S.VisualGuideLimits.refreshMsHardMin, refreshHardMax=S.VisualGuideLimits.refreshMsHardMax,
        refreshMs=UnitLineInterval(feature), showTarget=feature.State.showTarget~=false, showTargetTarget=feature.State.showTargetTarget~=false,
        showFocusTarget=feature.State.showFocusTarget~=false, showFocusTargetTarget=feature.State.showFocusTargetTarget~=false,
        -- 工厂会逐字段深拷贝；私有颜色准备结果不得越过 GetProjection 的隔离边界。
        colors=PreparedUnitLineColors(feature),
        pairPoints=feature.State.pairPoints or {}, pairSizes=feature.State.pairSizes or {},
        samplingMode="adaptive_screen_space", pointBudgetMode="cadence_pressure_bounded", refreshPriority="P1_visual" } end,
    commands = {
        SetPointCount = function(feature, value)
            -- 8..48 仅为 Presentation 建议；真实安全范围归 Feature，58 等精确输入仍可持久化并交给渲染器。
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
-- 绘制只复制端点、密度和样式；完整页面投影仍
-- 使用原GetProjection。每次独立快照不暴露Authority/State，不缓存玩家或目标的实时事实。
UnitLines.RenderProjectionContractVersion = 1
function UnitLines:GetRenderProjection()
    local state=self.State
    local snapshot={revision=self.Authority.revision,status=self.Authority.status,error=self.Authority.error,
        rows={},pointCount=state.pointCount,pointSize=state.pointSize,opacity=state.opacity,
        -- 渲染快照同样独立；颜色缓存只省纯归一计算，调用方改表不能污染下一次快照。
        refreshMs=UnitLineInterval(self),colors=PreparedUnitLineColors(self,true),
        pairPoints=Copy(state.pairPoints or {}),pairSizes=Copy(state.pairSizes or {})}
    for i,row in ipairs(self.Authority.rows) do
        snapshot.rows[i]={key=row.key,pairKey=row.pairKey,x1=row.x1,y1=row.y1,x2=row.x2,y2=row.y2}
    end
    return snapshot
end
-- Diagnostics 由 read() 惰性挂载，provider 必须每次现读，不能在注册时捕获空快照；不增加顶层 local。
local providers = S.FeatureHealthProviders
if type(providers) == "table" then
    providers:Register("unit_lines_diagnostics", function()
        local feature = S.Features and S.Features.combat_unit_lines or nil
        return type(feature) == "table" and type(feature.Diagnostics) == "table" and feature.Diagnostics or nil
    end)
end
