------------------------------------------------------------------------
-- Replicated Suite V3 - combat_range_assist Feature Authority
--
-- Phase 1 Batch E（2026-09-28）：从 features/rs_business_bridge.lua 机械搬迁（最后一批，
-- rs_business_bridge.lua 至此退役）。只改变源码边界，不改业务行为：Feature ID、Store ID/Schema、
-- UpdateTopic、Demand owner、Commands、Projection shape、ApiDependencies、
-- Scheduler task name（v3_business_range_assist_refresh，16ms）与九个契约版本号全部逐字一致。
--
-- Authority 边界：圆几何只做本地数学（圆心/半径/点密度），世界距离标定来自
-- ScreenProjectionV3 的 metric calibration；本文件不做单位枚举、不做写操作。
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local FSF = S.FeatureSliceFactory
if type(FSF) ~= "table" then error("FeatureSliceFactory unavailable for combat_range_assist") end
local Copy, Call, Action, Text, Number, Trim, Scalar = FSF.Copy, FSF.Call, FSF.Action, FSF.Text, FSF.Number, FSF.Trim, FSF.Scalar
local Load, PersistStateMutation, NewFeature = FSF.Load, FSF.PersistStateMutation, FSF.NewFeature
local UnitApi = rawget(_G, "X2Unit")

local RANGE_ASSIST_TASK = "v3_business_range_assist_refresh"
local RANGE_ASSIST_REFRESH_MS = 16
-- 中文维护注释（range-multi-circle-local-budget-1）：rs_business_bridge.lua 是 Lua 5.1 单一主 chunk，
-- 原文件已经长期接近 200 个活跃顶层 local 的硬上限。本次多圆不能把常量/Normalize/Find 等辅助项
-- 继续声明在主 chunk，否则整个 business bridge 会在编译期失败，范围辅助、背包、拍卖、制造、团队等
-- 同文件 Feature 会一起“implementation unavailable”。因此多圆内部 Authority/迁移/命令辅助全部封进
-- 这个 IIFE 的子函数作用域；主 chunk 只增加/保留 RangeAssist 一个引用。数据流仍是
-- Persistence -> Feature.State.circles -> Authority rows -> Presenter rangePools，不改变任何其它业务 Feature。
-- 后续维护若要增加多圆 helper，也必须放在此内部作用域或对象字段，禁止再消耗主 chunk local 预算。
local RangeAssist = (function()
local RANGE_ASSIST_DEFAULT_RADIUS = 10
local RANGE_ASSIST_DEFAULT_POINT_COUNT = 24
local RANGE_ASSIST_DEFAULT_POINT_SIZE = 4
local RANGE_ASSIST_DEFAULT_OPACITY = 0.68
local RANGE_ASSIST_DEFAULT_COLOR = { 0.20, 0.82, 1.00 }
local RANGE_ASSIST_TOTAL_POINT_BUDGET = 192
local RANGE_ASSIST_POINT_HARD_MIN = math.max(3, math.floor(tonumber(S.VisualGuideLimits.rangeDensityHardMin) or 3))
local RANGE_ASSIST_POINT_HARD_MAX = math.min(RANGE_ASSIST_TOTAL_POINT_BUDGET,
    math.max(RANGE_ASSIST_POINT_HARD_MIN, math.floor(tonumber(S.VisualGuideLimits.rangeDensityHardMax) or RANGE_ASSIST_TOTAL_POINT_BUDGET)))
local RANGE_ASSIST_RADIUS_HARD_MIN = tonumber(S.VisualGuideLimits.rangeRadiusHardMin) or 0.5
local RANGE_ASSIST_RADIUS_HARD_MAX = tonumber(S.VisualGuideLimits.rangeRadiusHardMax) or 1000
local RANGE_ASSIST_METRIC_CALIBRATION_MS = 500

local function RangeAssistClampColor(color)
    return {
        math.max(0, math.min(1, tonumber(type(color) == "table" and color[1]) or RANGE_ASSIST_DEFAULT_COLOR[1])),
        math.max(0, math.min(1, tonumber(type(color) == "table" and color[2]) or RANGE_ASSIST_DEFAULT_COLOR[2])),
        math.max(0, math.min(1, tonumber(type(color) == "table" and color[3]) or RANGE_ASSIST_DEFAULT_COLOR[3])),
    }
end

local function RangeAssistNormalizeCircle(circle, fallbackId)
    local id = math.floor(tonumber(type(circle) == "table" and circle.id or fallbackId) or 0)
    if id <= 0 then id = math.max(1, math.floor(tonumber(fallbackId) or 1)) end
    return {
        id = id,
        name = tostring(type(circle) == "table" and circle.name or ("范围圆 " .. tostring(id))),
        enabled = type(circle) ~= "table" or circle.enabled ~= false,
        -- Recommended UI window remains radius 1..100 / density 12..48, but
        -- normalization must preserve any exact value accepted inside the true
        -- renderer safety envelope. Otherwise Reload would silently undo the
        -- user's dynamic-slider expansion.
        radius = math.max(RANGE_ASSIST_RADIUS_HARD_MIN, math.min(RANGE_ASSIST_RADIUS_HARD_MAX, tonumber(type(circle) == "table" and circle.radius) or RANGE_ASSIST_DEFAULT_RADIUS)),
        pointCount = math.max(RANGE_ASSIST_POINT_HARD_MIN, math.min(RANGE_ASSIST_POINT_HARD_MAX, math.floor(tonumber(type(circle) == "table" and circle.pointCount) or RANGE_ASSIST_DEFAULT_POINT_COUNT))),
        pointSize = math.max(S.VisualGuideLimits.pointSizeMin, math.min(S.VisualGuideLimits.pointSizeHardMax,
            math.floor(tonumber(type(circle) == "table" and circle.pointSize) or RANGE_ASSIST_DEFAULT_POINT_SIZE))),
        opacity = math.max(0.1, math.min(1, tonumber(type(circle) == "table" and circle.opacity) or RANGE_ASSIST_DEFAULT_OPACITY)),
        color = RangeAssistClampColor(type(circle) == "table" and circle.color or nil),
    }
end

local function RangeAssistCopyCircles(circles)
    local out = {}
    local maxId = 0
    for index, circle in ipairs(type(circles) == "table" and circles or {}) do
        local normalized = RangeAssistNormalizeCircle(circle, index)
        if normalized.id > maxId then maxId = normalized.id end
        out[#out + 1] = normalized
    end
    return out, maxId
end

local function RangeAssistResolveCircles(state)
    local circles, maxId = RangeAssistCopyCircles(type(state) == "table" and state.circles or nil)
    if type(state) == "table" then
        state.circles = circles
        state.nextCircleId = math.max(maxId + 1, math.floor(tonumber(state.nextCircleId) or 1))
    end
    return circles
end

local function RangeAssistFindCircle(circles, circleId)
    local id = math.floor(tonumber(circleId) or 0)
    if id <= 0 then return nil end
    for index, circle in ipairs(type(circles) == "table" and circles or {}) do
        if tonumber(circle.id) == id then return index, circle end
    end
    return nil
end

local function RangeAssistFirstCircle(circles)
    return type(circles) == "table" and circles[1] or nil
end

local function RangeAssistMutateCircle(feature, circleId, reason, mutator)
    local id = math.floor(tonumber(circleId) or 0)
    if id <= 0 then return false, "范围圆编号无效" end
    local circles = RangeAssistResolveCircles(feature.State)
    local index = RangeAssistFindCircle(circles, id)
    if index == nil then return false, "范围圆不存在" end
    return PersistStateMutation(feature, reason, function(state)
        local working = RangeAssistResolveCircles(state)
        local workingIndex = RangeAssistFindCircle(working, id)
        if workingIndex == nil then return false, "范围圆不存在" end
        local nextCircle = RangeAssistNormalizeCircle(working[workingIndex], id)
        local ok, err = mutator(nextCircle)
        if ok ~= true then return false, err end
        working[workingIndex] = RangeAssistNormalizeCircle(nextCircle, id)
        state.circles = working
        return true
    end)
end

local function RangeAssistLegacyCircleId(feature)
    local first = RangeAssistFirstCircle(RangeAssistResolveCircles(feature.State))
    if first == nil then return nil, "请先新增范围圆" end
    return tonumber(first.id)
end

-- 维护（2026-09-18，range-motion-cadence-1）：范围圆以前固定 50ms（20Hz）刷新，镜头旋转时即使
-- 投影坐标本身正确，也会表现为每 3 帧左右跳一次。Scheduler 仍只保留一个 16ms 高频任务，真正
-- Authority 刷新根据本次启用点总量自适应：常规 <=48 点跟随帧级；中等密度 32ms；高密度 48ms。
-- 32/48 都是 16ms Scheduler lane 可实现的整数倍，避免配置“25/33ms”却实际只能在 32/48ms 才调度，
-- 让诊断显示与真实节奏一致。
-- 数据流：Demand Consumer -> 单 Scheduler task -> Authority Refresh；关闭/无 Consumer 仍释放任务。
-- 这里只控制会话刷新节奏，不改 circle.pointCount 持久配置，也不在循环内做额外 Static/API 查找。
local function RangeAssistRefreshInterval(feature)
    local total = 0
    -- 热路径只读已经由 Apply/Commands 归一化的 State，不再调用 RangeAssistResolveCircles。
    -- ResolveCircles 会复制整个 circles 数组并回写 state；放在 16ms cadence gate 会制造持续分配、
    -- GC 压力和无意义的配置表替换。损坏/旧状态在加载和显式配置事务边界统一归一化即可。
    local circles = feature and type(feature.State) == "table" and feature.State.circles or nil
    if type(circles) == "table" then
        for _, circle in ipairs(circles) do
            if type(circle) == "table" and circle.enabled ~= false then
                total = total + (tonumber(circle.pointCount) or RANGE_ASSIST_DEFAULT_POINT_COUNT)
            end
        end
    end
    if total <= 48 then return 16 end
    if total <= 96 then return 32 end
    return 48
end

return NewFeature("combat_range_assist", {
    apiDependencies = { "X2Unit:GetUnitWorldPositionByTarget", "X2Unit:GetUnitScreenPosition", "X2Unit:UnitDistance" },
    state = { circles = {}, nextCircleId = 1 },
    default = { circles = {}, nextCircleId = 1 },
    persistentKeys = { "circles", "nextCircleId" },
    apply = function(value, state)
        value = type(value) == "table" and value or {}
        -- 中文维护注释（range-multi-circle-store-1）：默认空 circles 才符合“新用户不送圆”的产品要求；
        -- 但老版本只存一组 radius/pointCount/...，这里要做单次兼容迁移，避免已有玩家的半径/颜色设置在升级后丢失。
        -- Authority 仍是 feature.State.circles；Persistence 只负责把旧单圆快照转为新数组快照，不自动为真正新用户造圆。
        if type(value.circles) == "table" then
            state.circles = RangeAssistResolveCircles({ circles = value.circles, nextCircleId = value.nextCircleId })
            state.nextCircleId = math.max(1, math.floor(tonumber(value.nextCircleId) or 1))
            RangeAssistResolveCircles(state)
            return true
        end
        local legacyDefined = value.radius ~= nil or value.pointCount ~= nil or value.pointSize ~= nil or value.opacity ~= nil or type(value.color) == "table"
        if legacyDefined == true then
            state.circles = { RangeAssistNormalizeCircle({ id = 1, radius = value.radius, pointCount = value.pointCount,
                pointSize = value.pointSize, opacity = value.opacity, color = value.color }, 1) }
            state.nextCircleId = 2
            return true
        end
        state.circles = {}
        state.nextCircleId = 1
        return true
    end,
    observationContractVersion = 4,
    reconcileDemand = function(feature, before, after)
        local b, a = tonumber(before and before.count) or 0, tonumber(after and after.count) or 0
        if b <= 0 and a > 0 then
            if S.Scheduler == nil or type(S.Scheduler.AddHighFrequencyTask) ~= "function" then return false, "范围辅助高频 Scheduler 不可用" end
            local added = S.Scheduler:AddHighFrequencyTask(RANGE_ASSIST_TASK, RANGE_ASSIST_REFRESH_MS, function()
                if feature.enabled ~= true or (tonumber(feature.consumerCount) or 0) <= 0 then return true end
                feature.RangeRefreshHealth = type(feature.RangeRefreshHealth) == "table" and feature.RangeRefreshHealth
                    or { attempts=0, successes=0, failures=0, consecutiveFailures=0, skippedByCadence=0 }
                local health=feature.RangeRefreshHealth
                local targetInterval=RangeAssistRefreshInterval(feature)
                local cadenceDivisor=math.max(1,math.floor((targetInterval/RANGE_ASSIST_REFRESH_MS)+0.5))
                health.targetIntervalMs=targetInterval
                -- 维护（range-motion-cadence-2）：Scheduler 已经负责约 16ms 基础节奏；低密度不再额外用
                -- NowMs 做第二道 >=16ms 门，否则 15.xms 的正常调度抖动会被放大成 30ms 视觉卡顿。
                -- 中/高密度按 2/3 个 Scheduler callback 分频，避免“目标32/48ms”因墙钟微抖再多跳一帧。
                -- 这里只保存三个数字，不分配表、不读取 Native；密度档位变化时从下一次回调立即重新起相位。
                if tonumber(health.cadenceDivisor)~=cadenceDivisor then
                    health.cadenceDivisor=cadenceDivisor
                    health.cadencePhase=0
                end
                local cadencePhase=math.max(0,math.floor(tonumber(health.cadencePhase) or 0))
                if cadencePhase>0 then
                    health.cadencePhase=cadencePhase-1
                    health.skippedByCadence=(tonumber(health.skippedByCadence) or 0)+1
                    return true
                end
                health.cadencePhase=cadenceDivisor-1
                health.lastDispatchAtMs=S.NowMs and math.max(0,tonumber(S.NowMs()) or 0) or 0
                health.attempts=(tonumber(health.attempts) or 0)+1
                local callOk, refreshResult = xpcall(function()
                    return feature.Authority:Refresh("visual_tick")
                end, S.SafeTraceback)
                if callOk==true then
                    health.successes=(tonumber(health.successes) or 0)+1
                    health.consecutiveFailures=0
                    health.lastSuccessAtMs=S.NowMs and S.NowMs() or 0
                    return refreshResult
                end

                health.failures=(tonumber(health.failures) or 0)+1
                health.consecutiveFailures=(tonumber(health.consecutiveFailures) or 0)+1
                health.lastErrorAtMs=S.NowMs and S.NowMs() or 0
                health.lastError=tostring(refreshResult or "unknown")
                if health.consecutiveFailures==1 then
                    feature.Authority.rows={}
                    feature.Authority.status="unavailable"
                    feature.Authority.error="范围辅助刷新异常："..health.lastError
                    feature.Authority.revision=(tonumber(feature.Authority.revision) or 0)+1
                    if S.Events~=nil and type(S.Events.Publish)=="function" then
                        pcall(S.Events.Publish,S.Events,feature.UpdateTopic,feature.Authority.revision,"visual_tick_error")
                    end
                end
                if S.DiagnosticsManager~=nil and type(S.DiagnosticsManager.WarnRateLimited)=="function" then
                    S.DiagnosticsManager:WarnRateLimited("range_assist","REFRESH_EXCEPTION",10000,
                        "范围辅助刷新异常，已隐藏旧圆并保持自适应高频重试",{error=health.lastError})
                end
                return true
            end, false, feature, "P1", 1)
            if added ~= true then return false, "范围辅助刷新任务创建失败" end
            if type(S.Scheduler.SetTaskModule) == "function" then S.Scheduler:SetTaskModule(RANGE_ASSIST_TASK, feature.Id) end
        elseif b > 0 and a <= 0 and S.Scheduler ~= nil then S.Scheduler:RemoveTask(RANGE_ASSIST_TASK) end
        return true
    end,
    onDisable = function() if S.Scheduler ~= nil then S.Scheduler:RemoveTask(RANGE_ASSIST_TASK) end return true end,
    read = function(feature)
        local projection = S.Services and S.Services.ScreenProjectionV3 or nil
        if type(projection) ~= "table" or type(projection.GetUnitWorldPosition) ~= "function" or type(projection.ProjectWorldBatch) ~= "function" then return {}, "unavailable", "ScreenProjectionV3 不可用" end
        -- 高频读取只消费加载/配置事务已经归一化的 circles；禁止每帧复制并回写配置数组。
        local circles = type(feature.State) == "table" and type(feature.State.circles) == "table" and feature.State.circles or {}
        local enabledCircles = {}
        local totalRequestedPoints = 0
        for _, circle in ipairs(circles) do
            if circle.enabled ~= false then
                enabledCircles[#enabledCircles + 1] = circle
                totalRequestedPoints = totalRequestedPoints + (tonumber(circle.pointCount) or 0)
            end
        end
        if #enabledCircles <= 0 then return {}, "ready" end
        local px,py,pz,posErr = projection:GetUnitWorldPosition("player", true)
        if px == nil then return {}, "unavailable", "自身世界坐标不可读：" .. tostring(posErr or "unknown") end
        -- 中文维护注释（2026-09-15，range-real-meter-1）：配置里的 circle.radius 永远保存“游戏米”，
        -- 不把历史用户配置迁移成世界单位。真正绘制前才向 ScreenProjectionV3 请求受控标定：
        -- UnitDistance(target) 是米数 Authority，player/target world delta 只计算 worldUnitsPerMeter；
        -- Camera fallback 的 screen scale 也是 Session-only 校准。无目标/样本不可信时都回退 1:1，
        -- 因而旧配置、无目标场景和 Native ConvertWorldToScreen 可用场景不会被错误永久放大/缩小。
        local metricCalibration = { worldUnitsPerMeter=1, projectionScale=1, worldScaleStatus="default", projectionScaleStatus="default",
            worldSampleCount=0, projectionSampleCount=0 }
        if type(projection.GetRangeMetricCalibration) == "function" then
            local okMetric, measured = pcall(projection.GetRangeMetricCalibration, projection, {
                anchorUnit="player", targetUnit="target", anchorWorld={x=px,y=py,z=pz}, worldZOffset=0.25,
                intervalMs=RANGE_ASSIST_METRIC_CALIBRATION_MS, aspectSafeCamera=true,
            })
            if okMetric == true and type(measured) == "table" then metricCalibration = measured end
        end
        local worldUnitsPerMeter = tonumber(metricCalibration.worldUnitsPerMeter) or 1
        if worldUnitsPerMeter <= 0 or worldUnitsPerMeter ~= worldUnitsPerMeter then worldUnitsPerMeter = 1 end
        local metricScreenScale = tonumber(metricCalibration.projectionScale) or 1
        if metricScreenScale <= 0 or metricScreenScale ~= metricScreenScale then metricScreenScale = 1 end
        local budgetScale = totalRequestedPoints > RANGE_ASSIST_TOTAL_POINT_BUDGET
            and (RANGE_ASSIST_TOTAL_POINT_BUDGET / math.max(1, totalRequestedPoints)) or 1
        local rows, partialCount = {}, 0
        local plans, allWorldPoints = {}, {}
        for _, circle in ipairs(enabledCircles) do
            local requestedCount = math.max(RANGE_ASSIST_POINT_HARD_MIN, math.min(RANGE_ASSIST_POINT_HARD_MAX,
                math.floor(tonumber(circle.pointCount) or RANGE_ASSIST_DEFAULT_POINT_COUNT)))
            local renderCount = requestedCount
            if budgetScale < 1 then
                renderCount = math.max(RANGE_ASSIST_POINT_HARD_MIN, math.min(requestedCount, math.floor(requestedCount * budgetScale + 0.5)))
            end
            renderCount = math.max(RANGE_ASSIST_POINT_HARD_MIN, math.min(RANGE_ASSIST_POINT_HARD_MAX, renderCount))
            local worldRadius = circle.radius * worldUnitsPerMeter
            local firstIndex = #allWorldPoints + 1
            for index = 1, renderCount do
                local angle = ((index - 1) / renderCount) * math.pi * 2
                allWorldPoints[#allWorldPoints + 1] = { x = px + math.cos(angle) * worldRadius, y = py + math.sin(angle) * worldRadius, z = pz + 0.25 }
            end
            plans[#plans + 1] = { circle=circle, requestedCount=requestedCount, renderCount=renderCount,
                worldRadius=worldRadius, firstIndex=firstIndex }
        end

        -- 维护（2026-09-18，range-rigid-frame-1）：所有启用圆在同一次 Authority 刷新中必须共享
        -- 同一个 Camera frame / Native-anchor 校准。旧实现“每个圆各投影一次”，旋转镜头时多个圆可能
        -- 分别采到不同相机姿态；同时逐点 Native->Camera fallback 还会让单个圆内部混用两套坐标。
        -- 现在最多 192 个点整批投影一次，ScreenProjectionV3 的 rigidBatch 在 Native 任一点失败时
        -- 整批回退到单 Camera frame，并对 player 锚点平移差做会话稳定化。这样既减少 Native/Camera
        -- 调用次数，又避免点/圆之间的相对抽动；半径与世界坐标 Authority 完全不变。
        local projected, batchSource, ringBatch = projection:ProjectWorldBatch(allWorldPoints, {
            easyPullCompat = true, rigidBatch = true, stabilizeAnchor = true, aspectSafeCamera = true,
            anchorUnit = "player", anchorWorld = { x = px, y = py, z = pz + 0.25 },
            metricScreenScale = metricScreenScale,
        })
        projected = type(projected) == "table" and projected or {}
        local batch = type(ringBatch) == "table" and ringBatch or {}
        local depthBand = (batch.depthMin ~= nil) and string.format("%.0f..%.0f", batch.depthMin, batch.depthMax) or "-"
        local refresh = type(feature.RangeRefreshHealth) == "table" and feature.RangeRefreshHealth or {}
        local calibration = "-"
        if tostring(batch.calibrationStatus or "") == "applied" then
            calibration = string.format("%d,%d", math.floor((tonumber(batch.calibrationDx) or 0) + 0.5), math.floor((tonumber(batch.calibrationDy) or 0) + 0.5))
        elseif batch.calibrationStatus ~= nil then
            calibration = tostring(batch.calibrationStatus)
            if batch.calibrationErr ~= nil then calibration = calibration .. ":" .. tostring(batch.calibrationErr) end
        end
        local metricFacts = string.format("米标定=%.4fwu/m[%s/%d] · 屏标定=%.3f[%s/%d/%s]",
            worldUnitsPerMeter, tostring(metricCalibration.worldScaleStatus or "default"), tonumber(metricCalibration.worldSampleCount) or 0,
            metricScreenScale, tostring(metricCalibration.projectionScaleStatus or "default"), tonumber(metricCalibration.projectionSampleCount) or 0,
            tostring(batch.metricScreenScaleStatus or "-"))
        local anchorFacts = ""
        if tonumber(batch.calibrationRawDy) ~= nil and tonumber(batch.calibrationStableDy) ~= nil then
            anchorFacts = string.format(" · 锚Y %.2f>%.2f[%s]", tonumber(batch.calibrationRawDy), tonumber(batch.calibrationStableDy), tostring(batch.calibrationStableSamples or 0))
        end
        local aspectFacts = batch.aspectSafeCamera==true and string.format("正交相机/dir=%.4f", tonumber(batch.rawCameraDirLength) or 1) or "兼容相机"
        local projFacts = string.format("刚性%s · %s · EasyPull原生%d/相机%d/原拒%d/相拒%d 深度%s · 锚校%s%s · %s · 刷新%dms 尝试%d/失%d/连续%d · 样本%s",
            tostring(batch.rigidSource or "-"), aspectFacts, tonumber(batch.native) or 0, tonumber(batch.camera) or 0, tonumber(batch.nativeRejected) or 0, tonumber(batch.cameraRejected) or 0, depthBand,
            tostring(batch.calibrationStatus or "-"), anchorFacts, metricFacts, tonumber(refresh.targetIntervalMs) or RANGE_ASSIST_REFRESH_MS,
            tonumber(refresh.attempts) or 0, tonumber(refresh.failures) or 0, tonumber(refresh.consecutiveFailures) or 0,
            tostring(batch.sample or "-"))

        for _, plan in ipairs(plans) do
            local circle=plan.circle
            local points={}
            local lastIndex=plan.firstIndex+plan.renderCount-1
            for index=plan.firstIndex,lastIndex do
                local screenPoint=projected[index]
                if type(screenPoint)=="table" and tonumber(screenPoint.x)~=nil and tonumber(screenPoint.y)~=nil
                    and screenPoint.visible~=false and tonumber(screenPoint.depth)~=nil and tonumber(screenPoint.depth)>0 then
                    points[#points+1]={x=screenPoint.x,y=screenPoint.y}
                end
            end
            if #points < 3 then partialCount = partialCount + 1 end
            local meterVerified = tostring(metricCalibration.worldScaleStatus or "") == "calibrated"
            local cameraCount = tonumber(batch.camera) or 0
            local screenVerified = cameraCount <= 0 or tostring(batch.metricScreenScaleStatus or "") == "applied"
                or tostring(batch.metricScreenScaleStatus or "") == "identity"
            local metricVerified = meterVerified and screenVerified
            rows[#rows + 1] = {
                key = "self_radius_" .. tostring(circle.id), circleId = circle.id, circleKey = "circle_" .. tostring(circle.id),
                name = tostring(circle.name or ("范围圆 " .. tostring(circle.id))),
                text = string.format("半径 %.1fm · 可见点 %d/%d · %s", circle.radius, #points, plan.renderCount, tostring(batchSource or "projection")),
                statusText = #points >= 3 and (metricVerified and "实时 · 米已校准" or "实时 · 待米校准") or "投影不足",
                tone = #points >= 3 and (metricVerified and "green" or "warn") or "warn",
                points = points, radius = circle.radius, worldRadius = plan.worldRadius, calibration = calibration, projFacts = projFacts,
                metricVerified = metricVerified,
                worldUnitsPerMeter = worldUnitsPerMeter, projectionScale = metricScreenScale,
                metricWorldStatus = metricCalibration.worldScaleStatus, metricProjectionStatus = metricCalibration.projectionScaleStatus,
                color = { circle.color[1], circle.color[2], circle.color[3] }, pointSize = circle.pointSize, opacity = circle.opacity,
                requestedPointCount = plan.requestedCount, renderPointCount = plan.renderCount, visibleCount = #points,
            }
        end
        if #rows <= 0 then return {}, "ready" end
        if partialCount > 0 then
            return rows, "partial", "部分范围圆投影点不足；已保留有效圆并按自适应高频节奏继续重试"
        end
        return rows, "ready"
    end,
    projection = function(feature)
        -- Presentation projection 同样是只读路径，不在刷新时重写配置 Authority。
        local circles = type(feature.State) == "table" and type(feature.State.circles) == "table" and feature.State.circles or {}
        local projectionCircles = {}
        local enabledCircleCount, totalConfiguredPoints = 0, 0
        for _, circle in ipairs(circles) do
            if circle.enabled ~= false then enabledCircleCount = enabledCircleCount + 1 end
            totalConfiguredPoints = totalConfiguredPoints + (tonumber(circle.pointCount) or 0)
            projectionCircles[#projectionCircles + 1] = {
                id = circle.id, name = circle.name, enabled = circle.enabled ~= false, radius = circle.radius,
                pointCount = circle.pointCount, pointSize = circle.pointSize, opacity = circle.opacity,
                color = { circle.color[1], circle.color[2], circle.color[3] },
            }
        end
        return {
            circles = projectionCircles,
            circleCount = #projectionCircles,
            enabledCircleCount = enabledCircleCount,
            totalConfiguredPoints = totalConfiguredPoints,
            totalPointBudget = RANGE_ASSIST_TOTAL_POINT_BUDGET,
            refreshMs = tonumber(feature.RangeRefreshHealth and feature.RangeRefreshHealth.targetIntervalMs) or RangeAssistRefreshInterval(feature),
            pointCountHardMin = RANGE_ASSIST_POINT_HARD_MIN, pointCountHardMax = RANGE_ASSIST_POINT_HARD_MAX,
            radiusHardMin = RANGE_ASSIST_RADIUS_HARD_MIN, radiusHardMax = RANGE_ASSIST_RADIUS_HARD_MAX,
            pointSizeMin = S.VisualGuideLimits.pointSizeMin,
            pointSizeDefaultMax = S.VisualGuideLimits.pointSizeDefaultMax,
            pointSizeHardMax = S.VisualGuideLimits.pointSizeHardMax,
        }
    end,
    commands = {
        AddCircle = function(feature)
            return PersistStateMutation(feature, "range_add_circle", function(state)
                local circles = RangeAssistResolveCircles(state)
                local nextId = math.max(1, math.floor(tonumber(state.nextCircleId) or 1))
                circles[#circles + 1] = RangeAssistNormalizeCircle({ id = nextId, name = "范围圆 " .. tostring(#circles + 1) }, nextId)
                state.circles = circles
                state.nextCircleId = nextId + 1
                return true
            end)
        end,
        RemoveCircle = function(feature, circleId)
            local circles = RangeAssistResolveCircles(feature.State)
            local index = RangeAssistFindCircle(circles, circleId)
            if index == nil then return false, "范围圆不存在" end
            return PersistStateMutation(feature, "range_remove_circle", function(state)
                local working = RangeAssistResolveCircles(state)
                local workingIndex = RangeAssistFindCircle(working, circleId)
                if workingIndex == nil then return false, "范围圆不存在" end
                table.remove(working, workingIndex)
                state.circles = working
                return true
            end)
        end,
        SetCircleEnabled = function(feature, circleId, value)
            return RangeAssistMutateCircle(feature, circleId, "range_circle_enabled", function(circle)
                circle.enabled = value == true
                return true
            end)
        end,
        SetCircleRadius = function(feature, circleId, value)
            value = math.max(RANGE_ASSIST_RADIUS_HARD_MIN, math.min(RANGE_ASSIST_RADIUS_HARD_MAX, tonumber(value) or RANGE_ASSIST_DEFAULT_RADIUS))
            return RangeAssistMutateCircle(feature, circleId, "range_circle_radius", function(circle)
                circle.radius = value
                return true
            end)
        end,
        SetCirclePointCount = function(feature, circleId, value)
            value = math.max(RANGE_ASSIST_POINT_HARD_MIN, math.min(RANGE_ASSIST_POINT_HARD_MAX,
                math.floor(tonumber(value) or RANGE_ASSIST_DEFAULT_POINT_COUNT)))
            return RangeAssistMutateCircle(feature, circleId, "range_circle_points", function(circle)
                circle.pointCount = value
                return true
            end)
        end,
        SetCirclePointSize = function(feature, circleId, value)
            value = math.max(S.VisualGuideLimits.pointSizeMin, math.min(S.VisualGuideLimits.pointSizeHardMax,
                math.floor(tonumber(value) or RANGE_ASSIST_DEFAULT_POINT_SIZE)))
            return RangeAssistMutateCircle(feature, circleId, "range_circle_size", function(circle)
                circle.pointSize = value
                return true
            end)
        end,
        SetCircleOpacity = function(feature, circleId, value)
            value = math.max(0.1, math.min(1, tonumber(value) or RANGE_ASSIST_DEFAULT_OPACITY))
            return RangeAssistMutateCircle(feature, circleId, "range_circle_opacity", function(circle)
                circle.opacity = value
                return true
            end)
        end,
        SetCircleColor = function(feature, circleId, r, g, b)
            local color = RangeAssistClampColor({ r, g, b })
            return RangeAssistMutateCircle(feature, circleId, "range_circle_color", function(circle)
                circle.color = color
                return true
            end)
        end,
        -- 中文维护注释（range-legacy-command-1）：保留旧单圆命令名字给旧页面/脚本兼容；
        -- 但新默认是空 circles，不允许隐式造圆，以免“新用户默认没有圆”的产品规则被兼容层破坏。
        SetRadius = function(feature, value)
            local circleId, err = RangeAssistLegacyCircleId(feature)
            if circleId == nil then return false, err end
            return feature.Commands:SetCircleRadius(circleId, value)
        end,
        SetPointCount = function(feature, value)
            local circleId, err = RangeAssistLegacyCircleId(feature)
            if circleId == nil then return false, err end
            return feature.Commands:SetCirclePointCount(circleId, value)
        end,
        SetPointSize = function(feature, value)
            local circleId, err = RangeAssistLegacyCircleId(feature)
            if circleId == nil then return false, err end
            return feature.Commands:SetCirclePointSize(circleId, value)
        end,
        SetOpacity = function(feature, value)
            local circleId, err = RangeAssistLegacyCircleId(feature)
            if circleId == nil then return false, err end
            return feature.Commands:SetCircleOpacity(circleId, value)
        end,
        SetColor = function(feature, r, g, b)
            local circleId, err = RangeAssistLegacyCircleId(feature)
            if circleId == nil then return false, err end
            return feature.Commands:SetCircleColor(circleId, r, g, b)
        end,
    },
})
end)()
RangeAssist.VisualGuideContractVersion = 9
RangeAssist.WorldSpaceContractVersion = 3
RangeAssist.ProjectionFactsContractVersion = 7
RangeAssist.RefreshCadenceContractVersion = 2
RangeAssist.MotionStabilityContractVersion = 1
RangeAssist.AspectSafeProjectionContractVersion = 1
RangeAssist.AnchorCalibrationContractVersion = 2
RangeAssist.MetricDistanceContractVersion = 1
RangeAssist.MultiCircleContractVersion = 1
