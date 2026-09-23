------------------------------------------------------------------------
-- Replicated Suite - Responsive Layout Authority
------------------------------------------------------------------------

if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local C = S.Constants

S.Layout = {
    context = nil,
    invalidated = true,
    lastSignature = nil,
    defaultFloatingBoundary = "free",
}
local L = S.Layout

-- ArcheAge / CryEngine UI logical coordinate contract. The logical origin is
-- the viewport top-left. Positive X travels right; positive Y travels down.
-- Keep this explicit so feature/layout code never guesses the sign of a
-- human instruction such as "move this icon upward".
L.CoordinateSystemContractVersion = 1
L.RectTransformTransactionContractVersion = 2
L.ScreenToWidgetLocalContractVersion = 2
L.ResponsivePlacementIntentContractVersion = 1
L.ViewportLogicalRectContractVersion = 1
L.EffectiveGeometryCalibrationContractVersion = 1 -- 中文维护注释：保留 RU Effective Geometry 单位校准契约，供外部原生控件和诊断继续使用。
L.SuiteOwnedViewportAnchorContractVersion = 1 -- 中文维护注释：从 .18.190 起，Suite 自己创建并由 Diff Authority 布局的控件，Popup 锚点必须优先使用完整 NativeStateCache 父链，而不能继续猜测 GetEffectiveOffset 的单位。
L.StartupMetricsSettleContractVersion = 1 -- 中文维护注释：启动/重登后的 UIParent 与 UI Scale 允许晚于插件加载稳定；只做有界 one-shot 复采样，不引入永久 Poll/Tick。
L.coordinateSystem = {
    origin = "top_left",
    xPositive = "right",
    xNegative = "left",
    yPositive = "down",
    yNegative = "up",
}
L.geometryMetrics = { transformBegins = 0, transformPreviews = 0, transformOverrides = 0, transformCommits = 0, transformCancels = 0, transformRejects = 0 }

-- 维护（viewport-recovery-1）：仅在几何入口做有限数过滤；nil/NaN/Infinity 不能
-- 参与 clamp/signature。读取兼容不写存档，也不改变 Feature 的 canonical Normalize/schema。
local function Finite(value, fallback)
    local n = tonumber(value)
    if n == nil or n ~= n or n == math.huge or n == -math.huge then return fallback end
    return n
end

local function Clamp(value, minimum, maximum)
    local number = Finite(value, 0)
    if number < minimum then return minimum end
    if number > maximum then return maximum end
    return number
end

local function CopyRect(rect)
    rect = type(rect) == "table" and rect or {}
    return {
        x = tonumber(rect.x) or 0,
        y = tonumber(rect.y) or 0,
        width = math.max(1, tonumber(rect.width) or 1),
        height = math.max(1, tonumber(rect.height) or 1),
    }
end

local function NormalizeHandle(handle)
    handle = tostring(handle or ""):lower():gsub("%-", "_")
    local valid = {
        top = true, bottom = true, left = true, right = true,
        top_left = true, top_right = true, bottom_left = true, bottom_right = true,
    }
    if valid[handle] then return handle end
    return nil
end

function L:GetCoordinateSystemSnapshot()
    return {
        contractVersion = tonumber(self.CoordinateSystemContractVersion) or 0,
        origin = self.coordinateSystem.origin,
        xPositive = self.coordinateSystem.xPositive,
        xNegative = self.coordinateSystem.xNegative,
        yPositive = self.coordinateSystem.yPositive,
        yNegative = self.coordinateSystem.yNegative,
    }
end

-- Semantic point movement. Distance is treated as a magnitude; the helper owns
-- the sign. In this coordinate system Move Up therefore subtracts Y.
function L:OffsetPoint(x, y, direction, distance)
    x, y = tonumber(x) or 0, tonumber(y) or 0
    local d = math.max(0, tonumber(distance) or 0)
    direction = tostring(direction or ""):lower()
    if direction == "up" then return x, y - d end
    if direction == "down" then return x, y + d end
    if direction == "left" then return x - d, y end
    if direction == "right" then return x + d, y end
    return nil, nil, "coordinate_direction_invalid:" .. tostring(direction)
end

function L:MoveRect(rect, direction, distance)
    local out = CopyRect(rect)
    local x, y, err = self:OffsetPoint(out.x, out.y, direction, distance)
    if err ~= nil then return nil, err end
    out.x, out.y = x, y
    return out, nil
end

-- Pure RectTransform transaction used by editor-like UI. It owns only math and
-- rollback semantics; native pointer capture remains Windowing/Input authority.
-- Delta values are always measured from Begin(), never accumulated frame-to-frame.
function L:CreateRectTransformTransaction(spec)
    spec = type(spec) == "table" and spec or {}
    local tx = {
        active = false, kind = nil, handle = nil, revision = 0,
        minWidth = math.max(1, tonumber(spec.minWidth) or 1),
        minHeight = math.max(1, tonumber(spec.minHeight) or 1),
        maxWidth = tonumber(spec.maxWidth), maxHeight = tonumber(spec.maxHeight),
    }
    if tx.maxWidth ~= nil then tx.maxWidth = math.max(tx.minWidth, tx.maxWidth) end
    if tx.maxHeight ~= nil then tx.maxHeight = math.max(tx.minHeight, tx.maxHeight) end

    function tx:Begin(rect, kind, handle)
        if self.active == true then return false, "rect_transform_already_active" end
        kind = tostring(kind or "move"):lower()
        if kind ~= "move" and kind ~= "resize" then
            L.geometryMetrics.transformRejects = (tonumber(L.geometryMetrics.transformRejects) or 0) + 1
            return false, "rect_transform_kind_invalid:" .. kind
        end
        if kind == "resize" then
            handle = NormalizeHandle(handle)
            if handle == nil then
                L.geometryMetrics.transformRejects = (tonumber(L.geometryMetrics.transformRejects) or 0) + 1
                return false, "rect_transform_handle_invalid"
            end
        else
            handle = nil
        end
        self.startRect = CopyRect(rect)
        self.currentRect = CopyRect(rect)
        self.kind, self.handle, self.active = kind, handle, true
        self.revision = self.revision + 1
        L.geometryMetrics.transformBegins = (tonumber(L.geometryMetrics.transformBegins) or 0) + 1
        return true, CopyRect(self.currentRect)
    end

    local function ClampSize(value, minimum, maximum)
        value = math.max(minimum, tonumber(value) or minimum)
        if maximum ~= nil then value = math.min(value, maximum) end
        return value
    end

    function tx:PreviewDelta(deltaX, deltaY)
        if self.active ~= true or self.startRect == nil then return nil, "rect_transform_not_active" end
        local dx, dy = tonumber(deltaX) or 0, tonumber(deltaY) or 0
        local start = self.startRect
        local out = CopyRect(start)
        if self.kind == "move" then
            out.x, out.y = start.x + dx, start.y + dy
        else
            local left, top = start.x, start.y
            local right, bottom = start.x + start.width, start.y + start.height
            local h = self.handle or ""
            local usesLeft = h == "left" or h == "top_left" or h == "bottom_left"
            local usesRight = h == "right" or h == "top_right" or h == "bottom_right"
            local usesTop = h == "top" or h == "top_left" or h == "top_right"
            local usesBottom = h == "bottom" or h == "bottom_left" or h == "bottom_right"
            if usesLeft then left = left + dx end
            if usesRight then right = right + dx end
            if usesTop then top = top + dy end
            if usesBottom then bottom = bottom + dy end

            local width = ClampSize(right - left, self.minWidth, self.maxWidth)
            local height = ClampSize(bottom - top, self.minHeight, self.maxHeight)
            if usesLeft then left = right - width else right = left + width end
            if usesTop then top = bottom - height else bottom = top + height end
            out.x, out.y, out.width, out.height = left, top, width, height
        end
        self.currentRect = out
        self.revision = self.revision + 1
        L.geometryMetrics.transformPreviews = (tonumber(L.geometryMetrics.transformPreviews) or 0) + 1
        return CopyRect(out), nil
    end

    function tx:OverridePreview(rect)
        if self.active ~= true or self.currentRect == nil then return nil, "rect_transform_not_active" end
        if type(rect) ~= "table" or tonumber(rect.x) == nil or tonumber(rect.y) == nil
            or tonumber(rect.width) == nil or tonumber(rect.height) == nil then
            L.geometryMetrics.transformRejects = (tonumber(L.geometryMetrics.transformRejects) or 0) + 1
            return nil, "rect_transform_override_invalid"
        end
        local out = {
            x = tonumber(rect.x), y = tonumber(rect.y),
            width = ClampSize(rect.width, self.minWidth, self.maxWidth),
            height = ClampSize(rect.height, self.minHeight, self.maxHeight),
        }
        -- When a snapped resize override is clamped, keep the opposite edge
        -- fixed just like PreviewDelta(). This prevents the selection frame from
        -- jumping across the user's stationary edge.
        if self.kind == "resize" then
            local h = self.handle or ""
            local usesLeft = h == "left" or h == "top_left" or h == "bottom_left"
            local usesTop = h == "top" or h == "top_left" or h == "top_right"
            if usesLeft then
                local requestedRight = tonumber(rect.x) + tonumber(rect.width)
                out.x = requestedRight - out.width
            end
            if usesTop then
                local requestedBottom = tonumber(rect.y) + tonumber(rect.height)
                out.y = requestedBottom - out.height
            end
        end
        self.currentRect = out
        self.revision = self.revision + 1
        L.geometryMetrics.transformOverrides = (tonumber(L.geometryMetrics.transformOverrides) or 0) + 1
        return CopyRect(out), nil
    end

    function tx:Commit()
        if self.active ~= true or self.currentRect == nil then return nil, "rect_transform_not_active" end
        local result = CopyRect(self.currentRect)
        self.active = false
        self.startRect = nil
        self.currentRect = nil
        L.geometryMetrics.transformCommits = (tonumber(L.geometryMetrics.transformCommits) or 0) + 1
        return result, nil
    end

    function tx:Cancel()
        if self.active ~= true or self.startRect == nil then return nil, "rect_transform_not_active" end
        local result = CopyRect(self.startRect)
        self.active = false
        self.startRect = nil
        self.currentRect = nil
        L.geometryMetrics.transformCancels = (tonumber(L.geometryMetrics.transformCancels) or 0) + 1
        return result, nil
    end

    function tx:GetSnapshot()
        return {
            contractVersion = tonumber(L.RectTransformTransactionContractVersion) or 0,
            active = self.active == true,
            kind = self.kind, handle = self.handle, revision = tonumber(self.revision) or 0,
            rect = self.currentRect and CopyRect(self.currentRect) or nil,
            coordinateSystem = L:GetCoordinateSystemSnapshot(),
        }
    end
    return tx
end

function L:GetGeometryContractSnapshot()
    return {
        coordinate = self:GetCoordinateSystemSnapshot(),
        rectTransformTransactionContractVersion = tonumber(self.RectTransformTransactionContractVersion) or 0,
        metrics = {
            transformBegins = tonumber(self.geometryMetrics.transformBegins) or 0,
            transformPreviews = tonumber(self.geometryMetrics.transformPreviews) or 0,
            transformOverrides = tonumber(self.geometryMetrics.transformOverrides) or 0,
            transformCommits = tonumber(self.geometryMetrics.transformCommits) or 0,
            transformCancels = tonumber(self.geometryMetrics.transformCancels) or 0,
            transformRejects = tonumber(self.geometryMetrics.transformRejects) or 0,
        },
    }
end

local function ActiveSettings()
    if S.AppState ~= nil and type(S.AppState.settings) == "table" then return S.AppState.settings end
    return {}
end

local function ActiveMainPlacement()
    -- V3 Shell owns its geometry in v3.shell. Layout remains a pure metrics
    -- authority and must not reach back into retired state trees (S.State 已删除).
    return {}
end

function L:BuildContext()
    local screenWidth, screenHeight, uiScale, logicalWidth, logicalHeight, metricsInfo = S.Api:GetUiMetrics()
    logicalWidth, logicalHeight = math.max(1, Finite(logicalWidth, 1024)), math.max(1, Finite(logicalHeight, 768))
    uiScale = math.max(0.01, Finite(uiScale, 1))
    screenWidth, screenHeight = math.max(1, Finite(screenWidth, logicalWidth)), math.max(1, Finite(screenHeight, logicalHeight))
    local addonScale = Clamp(ActiveSettings().addonScale or 1, C.MinAddonScale, C.MaxAddonScale)
    local designWidth = logicalWidth / addonScale
    local designHeight = logicalHeight / addonScale

    local breakpoint = "ULTRAWIDE"
    if designWidth < C.Breakpoint.COMPACT then
        breakpoint = "COMPACT"
    elseif designWidth < C.Breakpoint.STANDARD then
        breakpoint = "STANDARD"
    elseif designWidth < C.Breakpoint.WIDE then
        breakpoint = "WIDE"
    end

    local columns = 3
    if breakpoint == "COMPACT" then
        columns = designWidth < C.Breakpoint.NARROW_ONE_COLUMN and 1 or 2
    end

    local safe = C.SafeArea
    return {
        -- 来源是本次读取事实，不持久化；early fallback → 真实 root 也是身份变化。
        metricsSource = type(metricsInfo) == "table" and metricsInfo.source or "api",
        metricsReady = type(metricsInfo) ~= "table" or metricsInfo.ready == true,
        screenWidth = screenWidth,
        screenHeight = screenHeight,
        uiScale = uiScale,
        addonScale = addonScale,
        effectiveScale = uiScale * addonScale,
        logicalWidth = logicalWidth,
        logicalHeight = logicalHeight,
        designWidth = designWidth,
        designHeight = designHeight,
        safeLeft = safe,
        safeTop = safe,
        safeRight = safe,
        safeBottom = safe,
        usableWidth = math.max(1, logicalWidth - safe * 2),
        usableHeight = math.max(1, logicalHeight - safe * 2),
        aspectRatio = logicalHeight > 0 and logicalWidth / logicalHeight or 1,
        breakpoint = breakpoint,
        columns = columns,
    }
end

function L:GetContext(force)
    if self.context == nil or self.invalidated == true or force == true then
        self.context = self:BuildContext()
        self.invalidated = false
    end
    return self.context
end

-- Synthetic logical viewport used only by on-demand M6 acceptance diagnostics.
-- It intentionally bypasses S.Api and does not update L.context / lastSignature.
function L:BuildSyntheticContext(logicalWidth, logicalHeight, addonScale)
    local width = math.max(1, tonumber(logicalWidth) or 1)
    local height = math.max(1, tonumber(logicalHeight) or 1)
    local scale = Clamp(tonumber(addonScale) or 1, C.MinAddonScale, C.MaxAddonScale)
    local designWidth = width / scale
    local designHeight = height / scale
    local breakpoint = "ULTRAWIDE"
    if designWidth < C.Breakpoint.COMPACT then breakpoint = "COMPACT"
    elseif designWidth < C.Breakpoint.STANDARD then breakpoint = "STANDARD"
    elseif designWidth < C.Breakpoint.WIDE then breakpoint = "WIDE" end
    local columns = 3
    if breakpoint == "COMPACT" then columns = designWidth < C.Breakpoint.NARROW_ONE_COLUMN and 1 or 2 end
    local safe = C.SafeArea
    return {
        screenWidth = width, screenHeight = height, uiScale = 1, addonScale = scale, effectiveScale = scale,
        logicalWidth = width, logicalHeight = height, designWidth = designWidth, designHeight = designHeight,
        safeLeft = safe, safeTop = safe, safeRight = safe, safeBottom = safe,
        usableWidth = math.max(1, width - safe * 2), usableHeight = math.max(1, height - safe * 2),
        aspectRatio = height > 0 and width / height or 1, breakpoint = breakpoint, columns = columns, synthetic = true,
    }
end

function L:Scale(value)
    return (tonumber(value) or 0) * self:GetContext().addonScale
end

function L:Invalidate()
    self.invalidated = true
end

function L:MakeSignature(context)
    return table.concat({
        tostring(math.floor((context.screenWidth or 0) + 0.5)),
        tostring(math.floor((context.screenHeight or 0) + 0.5)),
        string.format("%.4f", tonumber(context.uiScale) or 1),
        string.format("%.2f", tonumber(context.addonScale) or 1),
        -- 维护：物理尺寸与断点不变时 logical viewport 仍可变化。签名必须含完整坐标空间，
        -- 而不是只比较物理分辨率；比例只作身份依据，绝不再乘除已是 logical 的 x/y。
        string.format("%.3f", Finite(context.logicalWidth, 0)),
        string.format("%.3f", Finite(context.logicalHeight, 0)),
        tostring(context.metricsSource or "api"),
        tostring(context.breakpoint),
        tostring(context.columns),
    }, ":")
end

function L:PrimeCurrentSignature()
    local context = self:GetContext(true)
    self.lastSignature = self:MakeSignature(context)
    return context
end

-- Apply one responsive presentation transaction. In V3 rebuild mode the
-- active presentation Authority is UIHostManager, not the legacy UI factory.
-- Keeping this bridge here prevents resolution/UI-scale changes from falling
-- through into legacy state-dependent code (S.State 已删除, 不加载).
function L:ApplyResponsivePresentation(fromMetricsChange)
    -- 维护：顶层窗注册表独立于主窗口生命周期。以前 main host 缺失会提前 return，
    -- 使存在但离屏的 FloatingSurface 永远不接收新 viewport。这里只处理几何，无业务刷新。
    self:RefreshFloatingSafety(fromMetricsChange == true)
    if S.Theme ~= nil and type(S.Theme.RefreshTypography) == "function" then
        S.Theme:RefreshTypography()
    end
    if S.RSUI ~= nil and type(S.RSUI.RefreshResolutionRoots) == "function" then
        pcall(function() S.RSUI:RefreshResolutionRoots(true) end)
    end
    if tostring(S.ArchitectureMode or "") == "v3_rebuild" then
        if S.UIHostManager ~= nil and type(S.UIHostManager.ApplyResponsiveLayout) == "function"
            then
            return S.UIHostManager:ApplyResponsiveLayout(fromMetricsChange == true)
        end
        return false, "V3 presentation host unavailable"
    end
    if S.UI ~= nil and type(S.UI.ApplyResponsiveLayout) == "function" then
        return S.UI:ApplyResponsiveLayout(fromMetricsChange == true)
    end
    return false, "responsive presentation unavailable"
end

-- Immediate refresh used by application-level UI settings. It updates the
-- signature now so the next native/lifecycle event need not repeat an unchanged reflow.
-- 维护：这里只更新事件身份；不存在后台 metrics poll。
function L:RefreshNow(fromMetricsChange)
    local fresh = self:GetContext(true)
    self.lastSignature = self:MakeSignature(fresh)
    self.invalidated = false
    return self:ApplyResponsivePresentation(fromMetricsChange == true)
end

-- 维护：保留 PollChanges 名称供旧调用/离线验收；Runtime 已移除周期注册。
-- 只由生命周期边沿调用；即使签名不变也发布新 context，避免 forced read 与 lastSignature 脱节。
function L:PollChanges()
    local fresh = self:BuildContext()
    local signature = self:MakeSignature(fresh)
    local changed = signature ~= self.lastSignature
    self.context, self.invalidated, self.lastSignature = fresh, false, signature
    if changed then
        self.metricsRevision = (tonumber(self.metricsRevision) or 0) + 1
        self:ApplyResponsivePresentation(true)
    end
    return changed
end

-- 维护（2026-09-22，relog-floating-placement-settle-1）：ArcheRage RU 登录/切角色期间，
-- Addon 已经开始恢复悬浮窗时 UIParent:GetExtent()/GetUIScale() 仍可能只是“有效但临时”的值。
-- 旧实现仅在事件边沿即时采样一次，再固定 150ms 采样一次；若最终 viewport 在 150ms 之后
-- 才稳定，同时 OnScale/ENTERED_WORLD 又没有再次投递，所有 FloatingSurface 都会停留在临时
-- viewport 的 normalized projection 上。Store 本身没有被改写，因此下一次重登会按新的加载时序
-- 再投影一次，用户看到的结果就是“悬浮框每次上下线都会移位”。
--
-- Authority / 数据流：Native UIParent -> Api:GetUiMetrics -> Layout context/signature ->
-- RefreshFloatingSafety/WindowShell placementDelegate；Feature-owned widgetWindow 始终只是持久 intent，
-- 本稳定窗口绝不调用 StorePlacement/MarkDirty，也绝不把临时投影反写成用户位置。
--
-- 实现边界：生命周期 Signal 仍立即采样，但随后开启一个严格有界的 one-shot 序列；每次新 Signal
-- 都废弃并重启旧序列，使 ENTERED_WORLD/LEFT_LOADING 成为新的稳定观察起点。序列最多 8 次、约
-- 15.5 秒，足以覆盖慢登录/切角色，同时没有永久 Tick、没有 Feature 扫描循环；签名不变时只读取
-- 几个 viewport 标量，不触发 Presentation reflow。Generation/epoch/serial 三层隔离保证重载或
-- Stop 后的迟到回调不能继续改布局。风险仅是启动期增加少量低频 UI metrics 读取。
local METRICS_SETTLE_DELAYS_MS = { 150, 350, 700, 1200, 1800, 2600, 3600, 5000 }

function L:StartMetricsEvents()
    if self.metricsEventsRunning then return true end
    self.metricsEventsEpoch = (tonumber(self.metricsEventsEpoch) or 0) + 1
    local epoch, generation = self.metricsEventsEpoch, S.Generation
    self.metricsEventsRunning = true
    self.metricsSettleSerial = (tonumber(self.metricsSettleSerial) or 0) + 1
    self.metricsNotifications = {
        nativeScale = false, nativeScaleDeliveryObserved=false, signals=0, events = {},
        settleRuns=0, settleAttempts=0, settleScheduleFailures=0, settleCompleted=false,
        lastReady=false, lastSource="unknown",
    }

    local function ScheduleSettle(reason)
        local scheduler = S.Scheduler
        if scheduler == nil or type(scheduler.AddOneShot) ~= "function" then return false end

        -- 新生命周期边沿拥有新的 settle 序列；即使旧任务正 pending，也不能让旧的 150ms 预算
        -- 吞掉 ENTERED_WORLD 后真正需要的观察窗口。RemoveTask 只处理同一静态任务名，不泄露元数据。
        L.metricsSettleSerial = (tonumber(L.metricsSettleSerial) or 0) + 1
        local serial = L.metricsSettleSerial
        L.metricsSettlePending = false
        if type(scheduler.RemoveTask) == "function" then scheduler:RemoveTask("rsui_metrics_settle") end
        L.metricsNotifications.settleRuns = (tonumber(L.metricsNotifications.settleRuns) or 0) + 1
        L.metricsNotifications.settleCompleted = false
        L.metricsNotifications.settleReason = tostring(reason or "unknown")

        local function Queue(attempt)
            if not L.metricsEventsRunning or L.metricsEventsEpoch ~= epoch or S.Generation ~= generation
                or L.metricsSettleSerial ~= serial then return false end
            local delay = METRICS_SETTLE_DELAYS_MS[attempt]
            if delay == nil then
                L.metricsSettlePending = false
                L.metricsNotifications.settleCompleted = true
                return true
            end
            L.metricsSettlePending = true
            local ok = scheduler:AddOneShot("rsui_metrics_settle", delay, function()
                if not L.metricsEventsRunning or L.metricsEventsEpoch ~= epoch or S.Generation ~= generation
                    or L.metricsSettleSerial ~= serial then return true end
                L.metricsSettlePending = false
                L:PollChanges()
                local context = L:GetContext()
                L.metricsNotifications.settleAttempts = (tonumber(L.metricsNotifications.settleAttempts) or 0) + 1
                L.metricsNotifications.lastReady = context.metricsReady == true
                L.metricsNotifications.lastSource = tostring(context.metricsSource or "unknown")
                L.metricsNotifications.lastLogicalWidth = tonumber(context.logicalWidth)
                L.metricsNotifications.lastLogicalHeight = tonumber(context.logicalHeight)
                if METRICS_SETTLE_DELAYS_MS[attempt + 1] == nil then
                    L.metricsNotifications.settleCompleted = true
                    return true
                end
                Queue(attempt + 1)
                return true
            end, L, "P1", 1)
            if ok ~= true then
                L.metricsSettlePending = false
                L.metricsNotifications.settleScheduleFailures = (tonumber(L.metricsNotifications.settleScheduleFailures) or 0) + 1
                return false
            end
            return true
        end
        return Queue(1)
    end

    local function Signal(reason)
        if not L.metricsEventsRunning or L.metricsEventsEpoch ~= epoch or S.Generation ~= generation then return end
        L.lastMetricsReason = tostring(reason)
        -- 维护：绑定成功与实际收到回调是两种证据；只保留计数和末次原因，不存事件历史。
        L.metricsNotifications.signals=L.metricsNotifications.signals+1
        if reason=="native_on_scale" then L.metricsNotifications.nativeScaleDeliveryObserved=true end
        L:PollChanges()
        ScheduleSettle(reason)
    end
    if S.Api and type(S.Api.StartUiMetricsNotifications) == "function" then
        local ok, err = S.Api:StartUiMetricsNotifications(Signal)
        self.metricsNotifications.nativeScale, self.metricsNotifications.nativeError = ok == true, err
    end
    if S.Events and type(S.Events.SubscribeOptional) == "function" then
        for _, name in ipairs({ "UI_RELOADED", "ENTERED_WORLD", "LEFT_LOADING", "OPTION_RESET" }) do
            local eventName = name -- Lua 5.1 回调捕获稳定副本；不得添加未经证实的分辨率事件枚举。
            local ok = S.Events:SubscribeOptional(eventName, self, function() Signal(eventName) end)
            self.metricsNotifications.events[eventName] = ok == true
        end
    end
    Signal("addon_load")
    return true
end

function L:StopMetricsEvents()
    self.metricsEventsRunning = false
    self.metricsEventsEpoch = (tonumber(self.metricsEventsEpoch) or 0) + 1
    self.metricsSettleSerial = (tonumber(self.metricsSettleSerial) or 0) + 1
    self.metricsSettlePending = false
    if S.Events and type(S.Events.UnsubscribeOwner) == "function" then S.Events:UnsubscribeOwner(self) end
    if S.Scheduler and type(S.Scheduler.RemoveTask) == "function" then S.Scheduler:RemoveTask("rsui_metrics_settle") end
    if S.Api and type(S.Api.StopUiMetricsNotifications) == "function" then S.Api:StopUiMetricsNotifications() end
    return true
end


-- Detached Popup / UIParent coordinate normalization -----------------------
--
-- Do not retrofit this behaviour into GetLogicalRect().  That older helper is
-- consumed by Windowing/drag/snap code whose callers already depend on its
-- legacy semantics.  Popups need a stricter contract: a live widget rectangle
-- expressed in UIParent viewport-logical coordinates exactly once.
--
-- RU has returned GetEffectiveOffset/GetEffectiveExtent in both logical and
-- UI-scaled units.  We therefore calibrate the unit from multiple bounded facts
-- instead of dividing by uiScale unconditionally.  A Suite-owned widget's
-- cached logical extent is the strongest discriminator (raw extent ~= logical
-- extent => scale 1; raw extent ~= logical*uiScale => scale uiScale). UIParent
-- effective extent and physical/logical viewport ratios are fallback evidence.
local function ReadEffectivePair(widget, methodName)
    if widget == nil or type(widget[methodName]) ~= "function" then return nil, nil, false end
    local ok, a, b = pcall(function() return widget[methodName](widget) end)
    a, b = ok and tonumber(a) or nil, ok and tonumber(b) or nil
    if a == nil or b == nil or a ~= a or b ~= b then return nil, nil, false end
    return a, b, true
end

local function AddScaleCandidate(candidates, value, source)
    value = tonumber(value)
    if value == nil or value ~= value or value < 0.20 or value > 5.0 then return end
    for _, row in ipairs(candidates) do
        if math.abs(row.value - value) <= 0.0005 then return end
    end
    candidates[#candidates + 1] = { value = value, source = tostring(source or "candidate") }
end

function L:ResolveEffectiveGeometryScale(widget, rawWidth, rawHeight, context)
    context = type(context) == "table" and context or self:GetContext()
    local candidates = {}
    AddScaleCandidate(candidates, 1, "logical_1")
    AddScaleCandidate(candidates, context and context.uiScale, "ui_scale")
    local logicalW = math.max(1, tonumber(context and context.logicalWidth) or 1)
    local logicalH = math.max(1, tonumber(context and context.logicalHeight) or 1)
    local screenW = tonumber(context and context.screenWidth)
    local screenH = tonumber(context and context.screenHeight)
    if screenW ~= nil then AddScaleCandidate(candidates, screenW / logicalW, "screen_width_ratio") end
    if screenH ~= nil then AddScaleCandidate(candidates, screenH / logicalH, "screen_height_ratio") end

    local rootW, rootH, rootExtentKnown = ReadEffectivePair(UIParent, "GetEffectiveExtent")
    if rootExtentKnown then
        AddScaleCandidate(candidates, rootW / logicalW, "uiparent_effective_width")
        AddScaleCandidate(candidates, rootH / logicalH, "uiparent_effective_height")
    end

    local cachedW, cachedH = nil, nil
    local cache = S.UI and S.UI.NativeStateCache or nil
    local row = type(cache) == "table" and cache[widget] or nil
    if type(row) == "table" then
        cachedW, cachedH = tonumber(row.width), tonumber(row.height)
        if cachedW ~= nil and cachedW > 0 and tonumber(rawWidth) ~= nil then
            AddScaleCandidate(candidates, tonumber(rawWidth) / cachedW, "widget_cached_width")
        end
        if cachedH ~= nil and cachedH > 0 and tonumber(rawHeight) ~= nil then
            AddScaleCandidate(candidates, tonumber(rawHeight) / cachedH, "widget_cached_height")
        end
    end

    -- Score each candidate against every fact expressed in the same unit. The
    -- cached Suite extent is weighted highest because it is the actual logical
    -- value we wrote through the Diff Authority. Root/screen ratios only break
    -- ties when a widget does not expose a usable effective extent.
    local best, bestScore = nil, nil
    for _, candidate in ipairs(candidates) do
        local scale = candidate.value
        local score, evidence = 0, 0
        if cachedW ~= nil and cachedW > 0 and tonumber(rawWidth) ~= nil and tonumber(rawWidth) > 0 then
            score = score + math.abs((tonumber(rawWidth) / scale) - cachedW) / math.max(1, cachedW) * 8
            evidence = evidence + 8
        end
        if cachedH ~= nil and cachedH > 0 and tonumber(rawHeight) ~= nil and tonumber(rawHeight) > 0 then
            score = score + math.abs((tonumber(rawHeight) / scale) - cachedH) / math.max(1, cachedH) * 8
            evidence = evidence + 8
        end
        if rootExtentKnown and rootW > 0 and rootH > 0 then
            score = score + math.abs((rootW / scale) - logicalW) / logicalW * 2
            score = score + math.abs((rootH / scale) - logicalH) / logicalH * 2
            evidence = evidence + 4
        end
        if screenW ~= nil and screenH ~= nil and screenW > 0 and screenH > 0 then
            local screenScaleX, screenScaleY = screenW / logicalW, screenH / logicalH
            score = score + math.abs(scale - screenScaleX) / math.max(1, screenScaleX) * 0.20
            score = score + math.abs(scale - screenScaleY) / math.max(1, screenScaleY) * 0.20
            evidence = evidence + 0.40
        end
        if evidence == 0 then
            score = math.abs(scale - (tonumber(context and context.uiScale) or 1))
        end
        if bestScore == nil or score < bestScore then
            best, bestScore = candidate, score
        end
    end
    best = best or { value = math.max(0.001, tonumber(context and context.uiScale) or 1), source = "ui_scale_fallback" }
    return math.max(0.001, tonumber(best.value) or 1), tostring(best.source or "unknown"), tonumber(bestScore) or 0
end

local function ResolveCachedViewportRect(widget) -- 中文维护注释：沿 UI Diff Authority 已提交的真实 NativeStateCache 父链累加逻辑坐标，得到相对 UIParent 的唯一可证明锚点。
    local cache = S.UI and S.UI.NativeStateCache or nil -- 中文维护注释：NativeStateCache 是 UI:SetAnchor/UI:SetExtent 的写入镜像，因此对 Suite-owned 控件比 RU GetEffectiveOffset 的单位猜测更可靠。
    if type(cache) ~= "table" or widget == nil then return nil end -- 中文维护注释：没有缓存表或目标控件时无法证明完整父链，必须 fail-closed。
    local x, y = 0, 0 -- 中文维护注释：从目标控件开始累计每一级 TOPLEFT 逻辑偏移，最终得到 UIParent-local X/Y。
    local current, guard = widget, 0 -- 中文维护注释：current 保存当前父链节点，guard 防止异常父链形成死循环。
    local first = cache[current] -- 中文维护注释：目标节点自身的缓存行提供 Popup 需要的宽高。
    local width = type(first) == "table" and tonumber(first.width) or nil -- 中文维护注释：宽度直接使用 Diff Authority 写入的逻辑宽度，不再根据 UI Scale 二次换算。
    local height = type(first) == "table" and tonumber(first.height) or nil -- 中文维护注释：高度同样使用逻辑高度，保证 Dropdown 行高和触发器高度处于同一坐标空间。
    while current ~= nil and current ~= UIParent and current ~= "UIParent" and guard < 64 do -- 中文维护注释：只有父链最终确实抵达 UIParent 才允许作为 detached Popup 的屏幕锚点。
        guard = guard + 1 -- 中文维护注释：每向上追溯一级就增加保护计数，64 层远高于当前 RSUI 树深度。
        local row = cache[current] -- 中文维护注释：读取当前节点最后一次由 Diff Authority 或 Native Primitive Factory 成功提交的 Native 几何状态。
        if type(row) ~= "table" then return nil end -- 中文维护注释：当前节点连缓存行都不存在时父链不可证明，必须立即 fail-closed。
        local parent = row.anchorParent -- 中文维护注释：优先读取 DiffRenderer v2 使用的标量父节点字段，这是后续布局写入的标准形式。
        local anchorX = tonumber(row.anchorX) -- 中文维护注释：优先读取标量逻辑 X；保持与 UI:SetAnchor 写入单位完全一致。
        local anchorY = tonumber(row.anchorY) -- 中文维护注释：优先读取标量逻辑 Y；保持与 UI:SetAnchor 写入单位完全一致。
        local legacy = type(row.anchorTopLeft) == "table" and row.anchorTopLeft or nil -- 中文维护注释：Native Primitive Factory 初次创建控件时可能只 Prime `anchorTopLeft`，即使后续位置未变化也不会强制迁移成标量字段。
        if parent == nil and legacy ~= nil then parent = legacy.parent end -- 中文维护注释：仅当标准父字段缺失时读取兼容父节点，避免覆盖已经由 DiffRenderer 更新的新 Authority。
        if anchorX == nil and legacy ~= nil then anchorX = tonumber(legacy.x) end -- 中文维护注释：仅在标量 X 缺失时读取初始 Prime 的逻辑 X，保证未发生重排的控件也能组成完整父链。
        if anchorY == nil and legacy ~= nil then anchorY = tonumber(legacy.y) end -- 中文维护注释：仅在标量 Y 缺失时读取初始 Prime 的逻辑 Y，保证首次打开 Popup 不依赖先发生一次布局变更。
        if parent == nil then return nil end -- 中文维护注释：标准字段和兼容字段都无法证明父节点时，禁止退回 EffectiveOffset 猜坐标。
        x = x + (anchorX or 0) -- 中文维护注释：累加当前节点相对父节点的逻辑 X；项目统一左上角原点，向右为正。
        y = y + (anchorY or 0) -- 中文维护注释：累加当前节点相对父节点的逻辑 Y；项目统一左上角原点，向下为正。
        current = parent -- 中文维护注释：继续沿已经明确解析出的真实缓存父节点追溯，直到 UIParent。
    end -- 中文维护注释：结束父链追溯循环。
    if current ~= UIParent and current ~= "UIParent" then return nil end -- 中文维护注释：未在保护深度内抵达 UIParent 时视为不可证明坐标，直接拒绝。
    return x, y, math.max(1, width or 1), math.max(1, height or 1), guard -- 中文维护注释：返回 UIParent-local 逻辑矩形和父链深度，父链深度用于诊断，不参与业务判断。
end -- 中文维护注释：结束缓存父链解析 helper。

function L:ResolveSuiteOwnedViewportLogicalRect(widget) -- 中文维护注释：这是 .18.190 新增的 Suite-owned Popup 锚点 Authority，只接受完整 Diff cache 父链。
    if widget == nil then return nil, nil, nil, nil, { source = "suite_widget_missing", coordinateSpace = "viewport-logical-v1" } end -- 中文维护注释：目标为空时明确返回不可用来源，避免上层退回魔法偏移。
    local x, y, width, height, depth = ResolveCachedViewportRect(widget) -- 中文维护注释：直接消费完整缓存父链，不读取 RU EffectiveOffset，因此不会再被 UI Scale/分辨率语义差异污染。
    if x == nil then return nil, nil, nil, nil, { source = "suite_anchor_chain_unavailable", coordinateSpace = "viewport-logical-v1" } end -- 中文维护注释：父链不完整时 fail-closed，让 PopupPositioning 决定是否允许外部原生车道兜底。
    return x, y, width, height, { -- 中文维护注释：返回已经处于 UIParent viewport-logical-v1 的最终锚点，Consumer 禁止再次乘除 uiScale。
        source = "suite_native_state_anchor_chain", -- 中文维护注释：明确记录 Authority 来源，实机诊断可直接区分 cache 父链与 Effective API。
        coordinateSpace = "viewport-logical-v1", -- 中文维护注释：标记唯一允许 detached Popup 消费的逻辑视口坐标空间。
        effectiveScale = 1, -- 中文维护注释：缓存父链本身已经是 UI:SetAnchor 接收的逻辑单位，因此这里不存在二次 Effective scale。
        scaleSource = "diff_authority_logical", -- 中文维护注释：诊断说明此次没有执行 RU EffectiveGeometry 单位猜测。
        anchorDepth = tonumber(depth) or 0, -- 中文维护注释：记录从 Trigger 到 UIParent 的完整父链层数，方便定位未来断链问题。
    } -- 中文维护注释：结束元数据表。
end -- 中文维护注释：结束 Suite-owned viewport logical rect Authority。

function L:ResolveViewportLogicalRect(widget)
    if widget == nil then return nil, nil, nil, nil, { source = "widget_missing", coordinateSpace = "viewport-logical-v1" } end
    local context = self:GetContext()
    local rawX, rawY, offsetKnown = ReadEffectivePair(widget, "GetEffectiveOffset")
    local rawW, rawH, extentKnown = ReadEffectivePair(widget, "GetEffectiveExtent")
    if offsetKnown == true then
        local rootX, rootY, rootKnown = ReadEffectivePair(UIParent, "GetEffectiveOffset")
        if rootKnown ~= true then rootX, rootY = 0, 0 end
        local scale, scaleSource, score = self:ResolveEffectiveGeometryScale(widget, rawW, rawH, context)
        local x, y = (rawX - rootX) / scale, (rawY - rootY) / scale
        local width, height
        if extentKnown == true then
            width, height = rawW / scale, rawH / scale
        else
            local cache = S.UI and S.UI.NativeStateCache or nil
            local row = type(cache) == "table" and cache[widget] or nil
            width = type(row) == "table" and tonumber(row.width) or nil
            height = type(row) == "table" and tonumber(row.height) or nil
            if width == nil and type(widget.GetWidth) == "function" then pcall(function() width = tonumber(widget:GetWidth()) end) end
            if height == nil and type(widget.GetHeight) == "function" then pcall(function() height = tonumber(widget:GetHeight()) end) end
        end
        if tonumber(width) ~= nil and tonumber(height) ~= nil then
            return x, y, math.max(1, width), math.max(1, height), {
                source = "effective_calibrated",
                coordinateSpace = "viewport-logical-v1",
                effectiveScale = scale,
                scaleSource = scaleSource,
                calibrationScore = score,
                uiScale = tonumber(context.uiScale) or 1,
                uiParentRawX = rootX,
                uiParentRawY = rootY,
            }
        end
    end

    -- Bounded fallback for Suite-owned nodes whose effective API is temporarily
    -- unavailable (for example while an ancestor is transitioning visibility).
    -- Never mix this chain with a partial effective result: one complete source
    -- owns the whole rect, preserving the single-transform rule.
    local cx, cy, cw, ch = ResolveCachedViewportRect(widget)
    if cx ~= nil then
        return cx, cy, cw, ch, {
            source = "native_state_anchor_chain_fallback",
            coordinateSpace = "viewport-logical-v1",
            effectiveScale = 1,
            scaleSource = "cached_logical",
        }
    end
    return nil, nil, nil, nil, { source = "viewport_rect_unavailable", coordinateSpace = "viewport-logical-v1" }
end

-- 维护（viewport-recovery-1）：Windowing 专用 live geometry，区别于 Popup 的缓存锚点。
-- BeginInteraction 根据稳定 extent 校准并冻结 effective 单位；resize 中不能拿变化后的
-- extent 对比旧 Diff cache 再猜比例。最多一次转换，uiScale 不是无条件除数；不写 Store。
-- 未传冻结值时只允许在 create/show/drag-end/按需诊断等低频边沿调用。
function L:GetWindowLogicalRect(widget, pinnedScale)
    local scale = Finite(pinnedScale)
    if scale ~= nil and scale > 0 then
        local x, y, posKnown = ReadEffectivePair(widget, "GetEffectiveOffset")
        local w, h, sizeKnown = ReadEffectivePair(widget, "GetEffectiveExtent")
        if posKnown and sizeKnown then
            local ox, oy, originKnown = ReadEffectivePair(UIParent, "GetEffectiveOffset")
            if not originKnown then ox, oy = 0, 0 end
            return (x-ox)/scale, (y-oy)/scale, w/scale, h/scale,
                { effectiveScale=scale, source="gesture_pinned", coordinateSpace="viewport-logical-v1" }
        end
    end
    return self:ResolveViewportLogicalRect(widget)
end

function L:GetLogicalRect(widget)
    local context = self:GetContext()
    local x, y, width, height = nil, nil, nil, nil
    if widget ~= nil and widget.GetEffectiveOffset ~= nil then
        local ok, a, b = pcall(function() return widget:GetEffectiveOffset() end)
        if ok then x, y = tonumber(a), tonumber(b) end
    end
    if widget ~= nil and widget.GetEffectiveExtent ~= nil then
        local ok, a, b = pcall(function() return widget:GetEffectiveExtent() end)
        if ok then width, height = tonumber(a), tonumber(b) end
    end
    if x ~= nil and y ~= nil then
        x = x / context.uiScale
        y = y / context.uiScale
    else
        local ok, a, b = pcall(function() return widget:GetOffset() end)
        if ok then x, y = tonumber(a) or 0, tonumber(b) or 0 else x, y = 0, 0 end
    end
    if width ~= nil and height ~= nil then
        width = width / context.uiScale
        height = height / context.uiScale
    else
        width = tonumber(widget and widget:GetWidth()) or 1
        height = tonumber(widget and widget:GetHeight()) or 1
    end
    return x, y, width, height
end


-- Screen/Overlay coordinate adapter v2. ScreenProjectionV3 owns projected
-- UIParent-local logical coordinates. The old adapter first called legacy
-- GetLogicalRect() (which unconditionally divided EffectiveOffset by uiScale)
-- and then divided UIParent's origin again. On RU clients whose Effective API
-- is already logical, UI Scale != 1 therefore shifted unit-lines/range points
-- by a second transform. Reuse the calibrated viewport-logical Authority here:
-- it subtracts UIParent's raw origin before converting exactly once.
function L:GetUiParentLocalOrigin(widget)
    if widget == nil then return 0, 0, false, "widget_missing" end
    local widgetX, widgetY, _, _, info = self:ResolveViewportLogicalRect(widget)
    widgetX, widgetY = tonumber(widgetX), tonumber(widgetY)
    if widgetX == nil or widgetY == nil then
        return 0, 0, false, type(info) == "table" and tostring(info.source or "origin_unavailable") or "origin_unavailable"
    end
    -- 维护（2026-09-22，screen-origin-authority-2）：ResolveViewportLogicalRect 的返回值已经是
    -- UIParent-local viewport-logical-v1；这里绝不能再减一次 parent origin 或乘除 uiScale。
    -- parentX/Y 保留为 0 只为兼容 ScreenPointToWidgetLocal 的诊断元数据，不代表丢失 Native 原点。
    return widgetX, widgetY, true, nil, 0, 0
end

function L:ScreenPointToWidgetLocal(widget, screenX, screenY)
    screenX, screenY = tonumber(screenX), tonumber(screenY)
    if screenX == nil or screenY == nil then return nil, nil, nil, "screen_point_invalid" end
    local ox, oy, known, err, parentX, parentY = self:GetUiParentLocalOrigin(widget)
    if known ~= true then
        return screenX, screenY, { originX = 0, originY = 0, uiParentOriginX = 0, uiParentOriginY = 0, fallback = true }, err
    end
    return screenX - ox, screenY - oy, {
        originX = ox, originY = oy,
        uiParentOriginX = tonumber(parentX) or 0, uiParentOriginY = tonumber(parentY) or 0,
        fallback = false,
    }, nil
end

------------------------------------------------------------------------
-- Resolution Safety Authority
--
-- Persistence remains owned by each Domain (Suite placement, DPS rects, Gear
-- quick positions, Healer anchors, etc.).  This layer only guarantees that the
-- live presentation is operable on the CURRENT logical UIParent canvas.  A
-- resolution fallback is therefore deliberately non-persistent unless the user
-- explicitly drags/saves the control in that resolution.
------------------------------------------------------------------------
L.floatingRegistry = L.floatingRegistry or {}
L.screenSnapRegistry = L.screenSnapRegistry or {}
L.screenSnapMetrics = L.screenSnapMetrics or { resolves = 0, snaps = 0, candidates = 0 }
L.safeDrag = L.safeDrag or nil
L.safeDragProxy = L.safeDragProxy or nil

local function WidgetVisible(widget)
    if widget == nil then return false end
    if type(widget.IsVisible) ~= "function" then return true end
    local ok, value = pcall(function() return widget:IsVisible() end)
    return not ok or value == true
end

function L:GetSafeSpawn(index, width, height, options)
    options = type(options) == "table" and options or {}
    local context = self:GetContext()
    local safety = C.ResolutionSafety or {}
    local edge = math.max(0, tonumber(options.edge) or tonumber(safety.edge) or tonumber(C.SafeArea) or 12)
    width = math.max(1, tonumber(width) or 1)
    height = math.max(1, tonumber(height) or 1)
    local maxX = math.max(edge, context.logicalWidth - edge - width)
    local maxY = math.max(edge, context.logicalHeight - edge - height)
    local baseX = Clamp(tonumber(options.baseX) or tonumber(safety.spawnX) or 300, edge, maxX)
    local baseY = Clamp(tonumber(options.baseY) or tonumber(safety.spawnY) or 100, edge, maxY)
    local gapX = math.max(0, tonumber(options.gapX) or tonumber(safety.spawnGapX) or 8)
    local gapY = math.max(0, tonumber(options.gapY) or tonumber(safety.spawnGapY) or 8)
    local stepX = math.max(1, width + gapX)
    local stepY = math.max(1, height + gapY)
    local maxColumns = math.max(1, math.floor(tonumber(options.maxColumns) or tonumber(safety.maxColumns) or 4))
    local columnsThatFit = math.floor((context.logicalWidth - edge - baseX + gapX) / stepX)
    local columns = math.max(1, math.min(maxColumns, columnsThatFit))
    local n = math.max(0, math.floor(tonumber(index) or 1) - 1)
    local x = baseX + (n % columns) * stepX
    local y = baseY + math.floor(n / columns) * stepY
    return Clamp(x, edge, maxX), Clamp(y, edge, maxY)
end

-- Pure sibling-snap solver for small floating controls. It does not write
-- geometry, clamp screen placement, or persist state; callers retain Authority.
-- Candidate placements preserve a caller-defined horizontal/vertical gap and
-- snap only when BOTH axes are within the threshold, avoiding surprising jumps
-- to distant rows/columns.
function L:ResolveSiblingSnap(x, y, width, height, siblings, options)
    options = type(options) == "table" and options or {}
    x, y = tonumber(x), tonumber(y)
    width, height = math.max(1, tonumber(width) or 1), math.max(1, tonumber(height) or 1)
    if x == nil or y == nil then return x, y, false end

    local distance = math.max(0, tonumber(options.distance) or self:Scale(C.SnapDistance or 16))
    local gapX = math.max(0, tonumber(options.gapX) or 0)
    local gapY = math.max(0, tonumber(options.gapY) or 0)
    local bestX, bestY, bestScore, bestIndex = x, y, nil, nil

    local function Consider(cx, cy, index)
        cx, cy = tonumber(cx), tonumber(cy)
        if cx == nil or cy == nil then return end
        local dx, dy = math.abs(cx - x), math.abs(cy - y)
        if dx > distance or dy > distance then return end
        local score = dx * dx + dy * dy
        if bestScore == nil or score < bestScore then
            bestX, bestY, bestScore, bestIndex = cx, cy, score, index
        end
    end

    for index, other in ipairs(type(siblings) == "table" and siblings or {}) do
        local ox, oy = tonumber(other.x), tonumber(other.y)
        local ow, oh = math.max(1, tonumber(other.width) or width), math.max(1, tonumber(other.height) or height)
        if ox ~= nil and oy ~= nil then
            local yAlign = { oy, oy + oh - height, oy + (oh - height) * 0.5 }
            local xAlign = { ox, ox + ow - width, ox + (ow - width) * 0.5 }

            -- Horizontal neighbours: right/left with a stable visual gap.
            for _, ay in ipairs(yAlign) do
                Consider(ox + ow + gapX, ay, index)
                Consider(ox - width - gapX, ay, index)
            end
            -- Vertical neighbours: below/above with a stable visual gap.
            for _, ax in ipairs(xAlign) do
                Consider(ax, oy + oh + gapY, index)
                Consider(ax, oy - height - gapY, index)
            end
        end
    end

    return bestX, bestY, bestScore ~= nil, bestIndex
end

-- 维护（2026-09-22，viewport-contained-floating-1）：顶层窗口的“完全可见”约束必须
-- 使用四条独立 SafeInset，而不是把 safeLeft 当作四边统一 edge。ArcheRage RU 在窗口模式、
-- UI Scale 与部分系统栏组合下四边安全区未必对称；旧实现会在 safeRight/safeBottom 较大时
-- 仍把窗口夹到物理边缘之外。Authority：Layout context -> runtime geometry only；不写 Store。
-- 兼容边界：options.edge 仍保留为显式对称覆盖；未传 edge 时严格消费当前四边 safe inset。
function L:ClampTopLeft(x, y, width, height, options)
    options = type(options) == "table" and options or {}
    local context = self:GetContext()
    local explicitEdge = tonumber(options.edge)
    local fallbackEdge = math.max(0, tonumber(C.SafeArea) or 12)
    local left = math.max(0, explicitEdge or tonumber(context.safeLeft) or fallbackEdge)
    local top = math.max(0, explicitEdge or tonumber(context.safeTop) or fallbackEdge)
    local rightInset = math.max(0, explicitEdge or tonumber(context.safeRight) or fallbackEdge)
    local bottomInset = math.max(0, explicitEdge or tonumber(context.safeBottom) or fallbackEdge)
    width = math.max(1, tonumber(width) or 1)
    height = math.max(1, tonumber(height) or 1)
    local usableW = math.max(1, (tonumber(context.logicalWidth) or width) - left - rightInset)
    local usableH = math.max(1, (tonumber(context.logicalHeight) or height) - top - bottomInset)
    local fittedW = math.min(width, usableW)
    local fittedH = math.min(height, usableH)
    local maxX = math.max(left, (tonumber(context.logicalWidth) or fittedW) - rightInset - fittedW)
    local maxY = math.max(top, (tonumber(context.logicalHeight) or fittedH) - bottomInset - fittedH)
    return Clamp(tonumber(x) or left, left, maxX), Clamp(tonumber(y) or top, top, maxY)
end

-- V3 free-placement safety. Normal dragging is intentionally NOT clamped to
-- keep the full window inside the viewport. We only intervene when the window
-- would become unrecoverable: at least a small horizontal grip and a small
-- portion of the top drag handle must remain reachable. This preserves player
-- freedom (including partially off-screen windows) without creating settings
-- that can strand a window permanently outside the current resolution.
function L:ClampRecoverableTopLeft(x, y, width, height, options)
    options = type(options) == "table" and options or {}
    local context = self:GetContext()
    local left = tonumber(context.safeLeft) or 0
    local top = tonumber(context.safeTop) or 0
    local right = math.max(left + 1, (tonumber(context.logicalWidth) or width) - (tonumber(context.safeRight) or 0))
    local bottom = math.max(top + 1, (tonumber(context.logicalHeight) or height) - (tonumber(context.safeBottom) or 0))
    width = math.max(1, tonumber(width) or 1)
    height = math.max(1, tonumber(height) or 1)

    local visibleX = math.max(8, math.min(width, tonumber(options.visibleX) or 72))
    local visibleY = math.max(8, tonumber(options.visibleY) or 18)
    local topReachHeight = math.max(visibleY, math.min(height, tonumber(options.topReachHeight) or height))

    -- Horizontal recovery may use either side of the title/drag surface.
    local minX = left - width + visibleX
    local maxX = right - visibleX

    -- Vertically the drag handle lives at the top of outer windows. Keep a
    -- reachable strip of that handle visible rather than merely keeping some
    -- arbitrary part of the body on-screen. For widgets whose whole surface is
    -- draggable (for example the R launcher), topReachHeight == height.
    local minY = top - topReachHeight + visibleY
    local maxY = bottom - visibleY

    return Clamp(tonumber(x) or left, minX, math.max(minX, maxX)),
        Clamp(tonumber(y) or top, minY, math.max(minY, maxY))
end

function L:IsRectFullyVisible(x, y, width, height, options)
    options = type(options) == "table" and options or {}
    local context = self:GetContext()
    local edge = math.max(0, tonumber(options.edge) or context.safeLeft or C.SafeArea or 12)
    x, y = tonumber(x), tonumber(y)
    width, height = math.max(1, tonumber(width) or 1), math.max(1, tonumber(height) or 1)
    if x == nil or y == nil then return false end
    return x >= edge and y >= edge
        and x + width <= context.logicalWidth - edge
        and y + height <= context.logicalHeight - edge
end

function L:EnsureWidgetVisible(widget, options)
    options = type(options) == "table" and options or {}
    if widget == nil then return false end
    if options.onlyWhenVisible ~= false and not WidgetVisible(widget) then return false end
    local context = self:GetContext()
    local x, y, width, height = self:GetLogicalRect(widget)
    local edge = math.max(0, tonumber(options.edge) or context.safeLeft or C.SafeArea or 12)
    local targetWidth, targetHeight = width, height
    if options.fitSize == true then
        targetWidth = math.min(targetWidth, math.max(1, context.logicalWidth - edge * 2))
        targetHeight = math.min(targetHeight, math.max(1, context.logicalHeight - edge * 2))
    end
    local safeX, safeY = self:ClampTopLeft(x, y, targetWidth, targetHeight, { edge = edge })
    local changed = math.abs((tonumber(x) or 0) - safeX) >= 0.5 or math.abs((tonumber(y) or 0) - safeY) >= 0.5
        or math.abs((tonumber(width) or 1) - targetWidth) >= 0.5 or math.abs((tonumber(height) or 1) - targetHeight) >= 0.5
    if changed then
        if widget.RemoveAllAnchors ~= nil then widget:RemoveAllAnchors() end
        widget:AddAnchor("TOPLEFT", "UIParent", safeX, safeY)
        if options.fitSize == true and widget.SetExtent ~= nil then widget:SetExtent(targetWidth, targetHeight) end
    end
    return changed, safeX, safeY, targetWidth, targetHeight
end

function L:RegisterFloating(id, widget, options)
    id = tostring(id or "")
    if id == "" or widget == nil then return false end
    self.floatingRegistry[id] = { widget = widget, options = type(options) == "table" and options or {} }
    local item = self.floatingRegistry[id]
    if item.options.ensureNow ~= false then
        if type(item.options.onMetricsChanged) == "function" then
            pcall(item.options.onMetricsChanged, false)
        elseif tostring(item.options.safetyMode or "free") ~= "free" then
            -- V3 floating surfaces are free by default. Legacy/exceptional
            -- callers must explicitly request safety enforcement.
            self:EnsureWidgetVisible(widget, item.options)
        end
    end
    return true
end

function L:UnregisterFloating(id)
    self.floatingRegistry[tostring(id or "")] = nil
end

------------------------------------------------------------------------
-- Screen Snap Registry
--
-- Deliberately separate from floatingRegistry. FloatingRegistry owns
-- resolution-safety callbacks; ScreenSnapRegistry owns only snap discovery.
-- Keeping those lifecycles independent prevents a module from accidentally
-- replacing its safety callback when it opts into screen-button snapping.
------------------------------------------------------------------------
function L:RegisterScreenSnap(id, widget, options)
    id = tostring(id or "")
    if id == "" or widget == nil then return false end
    options = type(options) == "table" and options or {}
    self.screenSnapRegistry[id] = { id = id, widget = widget, options = options }
    return true
end

function L:UnregisterScreenSnap(id)
    self.screenSnapRegistry[tostring(id or "")] = nil
    return true
end

-- Generic screen-control snap solver. Business modules own persistence and
-- user settings; this layer owns only cross-module target discovery and
-- geometry. Hidden controls are excluded, so disabled features have no
-- candidate cost. snapGroup prevents unrelated surfaces from coupling;
-- snapKind can further separate buttons/windows when required.
function L:ResolveScreenSnap(id, x, y, width, height, overrides)
    id = tostring(id or "")
    overrides = type(overrides) == "table" and overrides or {}
    local active = self.screenSnapRegistry[id]
    local activeOptions = active and type(active.options) == "table" and active.options or {}
    local enabled = overrides.enabled
    if enabled == nil then enabled = activeOptions.snapEnabled end
    if enabled == nil then enabled = active ~= nil end
    if enabled == true and type(activeOptions.snapEnabledProvider) == "function" then
        local ok, value = pcall(activeOptions.snapEnabledProvider)
        enabled = ok == true and value == true
    end
    if enabled ~= true then return x, y, false, nil end

    local group = tostring(overrides.group or activeOptions.snapGroup or "screen_controls")
    local kind = tostring(overrides.kind or activeOptions.snapKind or "")
    local siblings, siblingIds = {}, {}
    for otherId, item in pairs(self.screenSnapRegistry or {}) do
        local opts = item and type(item.options) == "table" and item.options or {}
        local widget = item and item.widget or nil
        local targetEnabled = opts.snapEnabled ~= false
        if targetEnabled == true and type(opts.snapEnabledProvider) == "function" then
            local ok, value = pcall(opts.snapEnabledProvider)
            targetEnabled = ok == true and value == true
        end
        if tostring(otherId) ~= id and widget ~= nil and targetEnabled and WidgetVisible(widget) then
            local otherGroup = tostring(opts.snapGroup or "screen_controls")
            local otherKind = tostring(opts.snapKind or "")
            if otherGroup == group and (kind == "" or otherKind == "" or otherKind == kind) then
                -- 维护：peer 与拖动源必须处于相同 logical 空间；不能一端校准、一端再 /uiScale。
                local ox, oy, ow, oh = self:GetWindowLogicalRect(widget)
                if tonumber(ox) ~= nil and tonumber(oy) ~= nil then
                    siblings[#siblings + 1] = { x = ox, y = oy, width = ow, height = oh }
                    siblingIds[#siblings] = tostring(otherId)
                end
            end
        end
    end

    self.screenSnapMetrics.resolves = (tonumber(self.screenSnapMetrics.resolves) or 0) + 1
    self.screenSnapMetrics.candidates = (tonumber(self.screenSnapMetrics.candidates) or 0) + #siblings
    local gap = math.max(0, tonumber(overrides.gap) or tonumber(activeOptions.snapGap) or 0)
    local sx, sy, snapped, siblingIndex = self:ResolveSiblingSnap(x, y, width, height, siblings, {
        distance = math.max(0, tonumber(overrides.distance) or tonumber(activeOptions.snapDistance) or self:Scale(C.SnapDistance or 16)),
        gapX = math.max(0, tonumber(overrides.gapX) or gap),
        gapY = math.max(0, tonumber(overrides.gapY) or gap),
    })
    if snapped == true then self.screenSnapMetrics.snaps = (tonumber(self.screenSnapMetrics.snaps) or 0) + 1 end
    return sx, sy, snapped, siblingIds[tonumber(siblingIndex) or -1]
end

function L:GetScreenSnapSnapshot()
    local registered, visible = 0, 0
    for _, item in pairs(self.screenSnapRegistry or {}) do
        registered = registered + 1
        if item and item.widget ~= nil and WidgetVisible(item.widget) then visible = visible + 1 end
    end
    return {
        version = 1,
        registered = registered,
        visible = visible,
        resolves = tonumber(self.screenSnapMetrics.resolves) or 0,
        snaps = tonumber(self.screenSnapMetrics.snaps) or 0,
        candidates = tonumber(self.screenSnapMetrics.candidates) or 0,
    }
end

function L:RefreshFloatingSafety(metricsChanged)
    if self._refreshingFloatingSafety == true then return end
    self._refreshingFloatingSafety = true
    for _, item in pairs(self.floatingRegistry or {}) do
        local widget = item and item.widget or nil
        local options = item and item.options or nil
        if widget ~= nil and type(options) == "table" then
            if type(options.onMetricsChanged) == "function" then
                local ok, accepted, err = pcall(options.onMetricsChanged, metricsChanged == true)
                item.lastRevalidateError = (not ok or accepted == false) and tostring(err or accepted or "placement_rejected") or nil
            elseif tostring(options.safetyMode or "free") ~= "free" then
                self:EnsureWidgetVisible(widget, options)
            end
        end
    end
    self._refreshingFloatingSafety = false
end

local function EnsureSafeDragProxy()
    if L.safeDragProxy ~= nil then return L.safeDragProxy end
    local factory = S.NativeObjectFactory
    if type(factory) ~= "table" or type(factory.CreateEmptyWidget) ~= "function" then return nil end
    local proxy = factory:CreateEmptyWidget(S.PhysicalId("resolution_drag_proxy"), "UIParent")
    if proxy == nil then return nil end
    proxy:SetExtent(1, 1)
    proxy:AddAnchor("TOPLEFT", "UIParent", 0, 0)
    if proxy.Enable ~= nil then pcall(function() proxy:Enable(true) end) end
    if proxy.Clickable ~= nil then pcall(function() proxy:Clickable(false) end) end
    if proxy.EnablePick ~= nil then pcall(function() proxy:EnablePick(false) end) end
    proxy:Show(false)
    L.safeDragProxy = proxy
    return proxy
end

function L:StepSafeMove()
    -- During a safe drag the target is anchored to the native moving proxy, so
    -- CryEngine performs the visual follow at native frame rate with zero Lua
    -- polling. This function remains as a compatibility/query point and only
    -- reports the current logical target position.
    local drag = self.safeDrag
    if type(drag) ~= "table" or drag.target == nil then return false end
    local x, y = self:GetLogicalRect(drag.target)
    drag.lastX, drag.lastY = tonumber(x) or drag.startX, tonumber(y) or drag.startY
    return true
end

function L:BeginSafeMove(key, target, options)
    -- IMPORTANT: do not try to transfer an active drag gesture to a different
    -- invisible window here. ArcheRage RU does not reliably hand the current
    -- mouse-drag capture to a proxy that did not receive OnDragStart itself.
    -- The old global proxy path could therefore return success while the proxy
    -- never moved, which made every caller skip its proven native StartMoving()
    -- fallback and left Suite/Gear/Healer/Plates/HUD windows undraggable.
    --
    -- Resolution safety remains centralized in RegisterFloating(),
    -- RefreshFloatingSafety(), EnsureWidgetVisible() and the drag-stop clamps.
    -- Consumers must use their native drag path unless a module owns a complete
    -- proxy transaction (DPS ranking windows do, including their own frame
    -- driver). Returning false is an explicit capability result, not an error.
    return false
end

function L:EndSafeMove(key, cancel)
    local drag = self.safeDrag
    if type(drag) ~= "table" then return false end
    if key ~= nil and tostring(key) ~= tostring(drag.key) then return false end

    local x, y = drag.startX, drag.startY
    if cancel ~= true and drag.target ~= nil then
        local currentX, currentY = self:GetLogicalRect(drag.target)
        x, y = tonumber(currentX) or drag.startX, tonumber(currentY) or drag.startY
        if drag.clamp ~= false then
            x, y = self:ClampTopLeft(x, y, drag.width, drag.height, drag.options)
        end
    end

    if drag.proxy ~= nil then
        if drag.proxy.StopMovingOrSizing ~= nil then pcall(function() drag.proxy:StopMovingOrSizing() end) end
    end
    if drag.target ~= nil then
        if drag.target.RemoveAllAnchors ~= nil then drag.target:RemoveAllAnchors() end
        drag.target:AddAnchor("TOPLEFT", "UIParent", x, y)
    end
    if drag.proxy ~= nil then
        drag.proxy:Show(false)
        if drag.proxy.RemoveAllAnchors ~= nil then drag.proxy:RemoveAllAnchors() end
        drag.proxy:AddAnchor("TOPLEFT", "UIParent", 0, 0)
        if drag.proxy.SetExtent ~= nil then drag.proxy:SetExtent(1, 1) end
    end
    local width, height = drag.width, drag.height
    self.safeDrag = nil
    return true, x, y, width, height
end

-- 维护（2026-09-16，committed-geometry-authority-1）：Windowing 在拖动/缩放事务提交时已经
-- 产生唯一的逻辑坐标 x/y/width/height。此前调用方收到这组值后又通过 GetLogicalRect(widget)
-- 读取一次 Native，UI Scale/原生坐标更新时序可能让“屏幕上最终位置”和“写入 Store 的位置”不同，
-- 下次登录便出现悬浮窗漂移。StorePlacementRect 只消费事务已经提交的逻辑矩形；StorePlacement
-- 保留给没有显式事务矩形的低频兼容调用。Authority：Windowing committed rect -> Layout -> Feature/UI Store。
-- 兼容边界：持久化字段、coordinateSpace 和响应式中心比例完全不变，不触碰任何 Store schema。
function L:StorePlacementRect(target, x, y, width, height, options)
    if type(target) ~= "table" then return end
    options = type(options) == "table" and options or {}
    local context = self:GetContext()
    x, y = tonumber(x) or 0, tonumber(y) or 0
    local mode = tostring(options.mode or "free")
    width = math.max(1, tonumber(width) or 1)
    height = math.max(1, tonumber(height) or 1)

    -- Free/recoverable placement is allowed to be larger than the viewport.
    -- Strict/edge placement keeps the historical fit-to-current-resolution rule.
    if mode ~= "free" and mode ~= "recoverable" then
        width = Clamp(width, 1, context.usableWidth)
        height = Clamp(height, 1, context.usableHeight)
    end

    if mode == "free" or mode == "recoverable" then
        if mode == "recoverable" then
            x, y = self:ClampRecoverableTopLeft(x, y, width, height, options)
        end
        target.x = tonumber(x) or 0
        target.y = tonumber(y) or 0
        target.anchorH = nil
        target.anchorV = nil
        target.offsetX = nil
        target.offsetY = nil
        target.coordinateSpace = "logical-free-v2"
        target.savedUiScale = context.uiScale
        -- Resolution-independent placement intent v3. Keep the authoritative
        -- logical x/y for exact same-viewport restores, but also persist the
        -- window center as a ratio of the current logical UIParent. When the
        -- player changes resolution this ratio reprojects the surface into the
        -- new viewport instead of treating an old absolute pixel coordinate as
        -- if it belonged to the new canvas. No resolution lookup table is used.
        target.savedLogicalWidth = tonumber(context.logicalWidth)
        target.savedLogicalHeight = tonumber(context.logicalHeight)
        if tonumber(context.logicalWidth) ~= nil and tonumber(context.logicalWidth) > 0 then
            target.normalizedCenterX = Clamp((target.x + width * 0.5) / context.logicalWidth, -2, 3)
        else
            target.normalizedCenterX = nil
        end
        if tonumber(context.logicalHeight) ~= nil and tonumber(context.logicalHeight) > 0 then
            target.normalizedCenterY = Clamp((target.y + height * 0.5) / context.logicalHeight, -2, 3)
        else
            target.normalizedCenterY = nil
        end
        return target.x, target.y, width, height
    end

    x = Clamp(x, context.safeLeft, math.max(context.safeLeft, context.logicalWidth - context.safeRight - width))
    y = Clamp(y, context.safeTop, math.max(context.safeTop, context.logicalHeight - context.safeBottom - height))

    if x + width / 2 <= context.logicalWidth / 2 then
        target.anchorH = "LEFT"
        target.offsetX = math.max(0, x - context.safeLeft)
    else
        target.anchorH = "RIGHT"
        target.offsetX = math.max(0, context.logicalWidth - context.safeRight - x - width)
    end
    if y + height / 2 <= context.logicalHeight / 2 then
        target.anchorV = "TOP"
        target.offsetY = math.max(0, y - context.safeTop)
    else
        target.anchorV = "BOTTOM"
        target.offsetY = math.max(0, context.logicalHeight - context.safeBottom - y - height)
    end
    target.x, target.y = nil, nil
    target.coordinateSpace = "logical-edge-v1"
    target.savedUiScale = context.uiScale
    -- Edge intent is self-contained. Drop free-surface viewport metadata so a
    -- screen button cannot carry two competing placement Authorities in the
    -- same working table after switching from legacy free placement.
    target.savedLogicalWidth, target.savedLogicalHeight = nil, nil
    target.normalizedCenterX, target.normalizedCenterY = nil, nil
    return x, y, width, height
end

function L:StorePlacement(target, widget, options)
    if type(target) ~= "table" or widget == nil then return end
    local x, y, width, height = self:GetLogicalRect(widget)
    return self:StorePlacementRect(target, x, y, width, height, options)
end

-- 维护（viewport-recovery-1）：此策略仅用于 persistent/session 顶层窗口，不替换 Popup/HUD。
-- x/y 是 UIParent logical；addonScale 已在 preferred size 入口应用，uiScale 只判别 viewport。
-- 同 viewport 可拖回的部分离屏位置精确保留；跨 viewport/失去标题/显式恢复才严格夹紧。
-- fitted size 是返回值，绝不写回 placement；每次从原 intent 重新投影，往返不积累漂移。
function L:IsWindowRecoverable(x, y, width, height, titleHeight)
    local c = self:GetContext()
    x, y, width, height = Finite(x), Finite(y), Finite(width), Finite(height)
    if x == nil or y == nil or width == nil or height == nil or width <= 0 or height <= 0 then return false end
    local title = math.min(height, math.max(1, Finite(titleHeight, 24)))
    -- 普通拖动的可恢复性基于真实 viewport，而非迁移时的内边距；否则 -2px 的
    -- 合法部分离屏标题会在重登时漂移。迁移/Reset 才使用 SafeArea 严格夹紧。
    local vx = math.min(x+width, c.logicalWidth)-math.max(x,0)
    local vy = math.min(y+title, c.logicalHeight)-math.max(y,0)
    return vx >= math.min(72,width,c.usableWidth) and vy >= math.min(14,title,c.usableHeight)
end

function L:ResolveWindowPlacement(placement, width, height, defaultX, defaultY, options)
    options = type(options) == "table" and options or {}
    local c = self:GetContext()
    local p = type(placement) == "table" and placement or nil
    local pw, ph = math.max(1, Finite(width, 420)), math.max(1, Finite(height, 286))
    local w, h = math.min(pw,c.usableWidth), math.min(ph,c.usableHeight)
    local x, y = Finite(defaultX,c.safeLeft+(c.usableWidth-w)/2), Finite(defaultY,c.safeTop+(c.usableHeight-h)/2)
    local reason = tostring(options.reason or "restore")
    local sw, sh = p and Finite(p.savedLogicalWidth), p and Finite(p.savedLogicalHeight)
    local ss = p and Finite(p.savedUiScale)
    local known = sw ~= nil and sh ~= nil and sw > 0 and sh > 0
    local changed = known and (math.abs(sw-c.logicalWidth)>=0.5 or math.abs(sh-c.logicalHeight)>=0.5) or false
    if ss ~= nil and ss > 0 and math.abs(ss-c.uiScale)>=0.0005 then changed = true end
    local source = "default"
    local rx, ry = p and Finite(p.normalizedCenterX), p and Finite(p.normalizedCenterY)
    if rx ~= nil and (rx < -2 or rx > 3) then rx = nil end
    if ry ~= nil and (ry < -2 or ry > 3) then ry = nil end
    local hasXY = p and Finite(p.x) ~= nil and Finite(p.y) ~= nil
    local intent = p and p.userMoved ~= false and reason ~= "explicit_reset"
    if intent and hasXY then
        x, y = Finite(p.x), Finite(p.y)
        source = known and "same_viewport_exact" or "legacy_recovery"
        if changed and known and rx ~= nil and ry ~= nil then
            x, y = rx*c.logicalWidth-w*0.5, ry*c.logicalHeight-h*0.5
            source = "normalized_reproject"
        elseif changed then source = "legacy_recovery" end
    elseif intent and (p.anchorH ~= nil or p.anchorV ~= nil or p.offsetX ~= nil or p.offsetY ~= nil) then
        local ox, oy = math.max(0,Finite(p.offsetX,0)), math.max(0,Finite(p.offsetY,0))
        x = p.anchorH == "RIGHT" and c.logicalWidth-c.safeRight-ox-w or c.safeLeft+ox
        y = p.anchorV == "BOTTOM" and c.logicalHeight-c.safeBottom-oy-h or c.safeTop+oy
        source = "legacy_recovery"
    end
    if reason == "explicit_reset" then source = "explicit_reset" end
    local recoverable = self:IsWindowRecoverable(x,y,w,h,options.topReachHeight)
    local fit = w ~= pw or h ~= ph
    -- 维护（2026-09-22，viewport-contained-floating-1）：普通 FloatingSurface 的 boundaryMode=free
    -- 只表示“用户可自由拖动/缩放”，不再表示“允许把顶层窗口持久停在屏幕外”。过去 same_viewport_exact
    -- 与缺少 savedLogicalWidth/Height 的 legacy row 只要标题还剩一小条可抓取就不夹紧，因此切分辨率、
    -- 窗口模式或旧配置升级后会看到窗口大半甚至主体位于屏幕外。现在 top-level free/strict 都要求
    -- runtime rect 完整位于 safe viewport；recoverable 模式仍显式保留给确实需要部分离屏的特殊控件。
    -- 这是运行时投影，不回写 Feature-owned placement；只有真实用户 geometry commit 才更新 Store。
    local boundaryMode = tostring(options.mode or "free")
    local legacyIntent = intent and not known
    local strict = boundaryMode == "free" or boundaryMode == "strict" or changed or legacyIntent
        or not recoverable or fit or source == "default" or source == "explicit_reset"
    local bx, by = x, y
    if strict then x,y = self:ClampTopLeft(x,y,w,h) end
    local clamped = x ~= bx or y ~= by
    local recovery = source == "explicit_reset" and "explicit_reset"
        or (changed and "resolution_migration" or (not recoverable and "legacy_recovery" or (fit and "runtime_size_fit" or "none")))
    return x,y,w,h,{
        coordinateSpace="logical-free-v2", placementSource=source, viewportChanged=changed,
        migrationApplied=changed or clamped or fit, clampApplied=clamped, fitApplied=fit, recoveryReason=recovery,
        preferredWidth=pw,preferredHeight=ph,savedLogicalWidth=sw,savedLogicalHeight=sh,savedUiScale=ss,
        normalizedCenterX=rx,normalizedCenterY=ry,currentLogicalWidth=c.logicalWidth,currentLogicalHeight=c.logicalHeight,
        currentUiScale=c.uiScale,currentScreenWidth=c.screenWidth,currentScreenHeight=c.screenHeight,
        metricsSource=c.metricsSource,fullyVisible=self:IsRectFullyVisible(x,y,w,h),
        recoverable=self:IsWindowRecoverable(x,y,w,h,options.topReachHeight), x=x,y=y,width=w,height=h,
    }
end

function L:ResolvePlacement(placement, width, height, defaultX, defaultY, options)
    if type(options) == "table" and options.topLevel == true then
        return self:ResolveWindowPlacement(placement,width,height,defaultX,defaultY,options)
    end
    options = type(options) == "table" and options or {}
    local context = self:GetContext()
    local mode = tostring(options.mode or "free")
    width = math.max(1, tonumber(width) or 1)
    height = math.max(1, tonumber(height) or 1)
    if mode ~= "free" and mode ~= "recoverable" then
        width = Clamp(width, 1, context.usableWidth)
        height = Clamp(height, 1, context.usableHeight)
    end

    local x = tonumber(defaultX) or context.safeLeft
    local y = tonumber(defaultY) or context.safeTop
    if type(placement) == "table" and tostring(placement.coordinateSpace or "") == "logical-free-v2"
        and tonumber(placement.x) ~= nil and tonumber(placement.y) ~= nil then
        x = tonumber(placement.x)
        y = tonumber(placement.y)

        -- Responsive placement v3: exact x/y remain authoritative while the
        -- viewport matches the one that produced them. Across a real logical
        -- resolution change, reproject the saved center ratio into the current
        -- UIParent. This makes free floating windows resolution-independent
        -- without forcing them into edge-anchored button semantics.
        local savedW, savedH = tonumber(placement.savedLogicalWidth), tonumber(placement.savedLogicalHeight)
        local ratioX, ratioY = tonumber(placement.normalizedCenterX), tonumber(placement.normalizedCenterY)
        local viewportChanged = savedW ~= nil and savedH ~= nil
            and (math.abs(savedW - context.logicalWidth) >= 0.5 or math.abs(savedH - context.logicalHeight) >= 0.5)
        if viewportChanged and ratioX ~= nil and ratioY ~= nil then
            x = ratioX * context.logicalWidth - width * 0.5
            y = ratioY * context.logicalHeight - height * 0.5
        end

        if mode == "recoverable" then
            x, y = self:ClampRecoverableTopLeft(x, y, width, height, options)
        elseif mode == "strict" then
            x, y = self:ClampTopLeft(x, y, width, height, options)
        elseif mode == "free" and (viewportChanged or savedW == nil or savedH == nil) then
            -- Legacy free-v2 rows have no source viewport. We cannot infer a
            -- mathematically exact cross-resolution location, but we can keep
            -- the control recoverable rather than allowing a high-resolution
            -- absolute coordinate to strand it completely off-screen. This is
            -- a live safety fallback only; persistence changes only on user drag.
            x, y = self:ClampRecoverableTopLeft(x, y, width, height, options)
        end
        return x, y, width, height
    end

    if type(placement) == "table" then
        local offsetX = math.max(0, tonumber(placement.offsetX) or 0)
        local offsetY = math.max(0, tonumber(placement.offsetY) or 0)
        if placement.anchorH == "RIGHT" then
            x = context.logicalWidth - context.safeRight - offsetX - width
        else
            x = context.safeLeft + offsetX
        end
        if placement.anchorV == "BOTTOM" then
            y = context.logicalHeight - context.safeBottom - offsetY - height
        else
            y = context.safeTop + offsetY
        end
    end

    if mode == "recoverable" then
        x, y = self:ClampRecoverableTopLeft(x, y, width, height, options)
    elseif mode == "strict" then
        x = Clamp(x, context.safeLeft, math.max(context.safeLeft, context.logicalWidth - context.safeRight - width))
        y = Clamp(y, context.safeTop, math.max(context.safeTop, context.logicalHeight - context.safeBottom - height))
    end
    return x, y, width, height
end

function L:ApplyPlacement(widget, placement, width, height, defaultX, defaultY, options)
    if widget == nil then return end
    local x, y, resolvedWidth, resolvedHeight = self:ResolvePlacement(placement, width, height, defaultX, defaultY, options)
    if widget.RemoveAllAnchors ~= nil then widget:RemoveAllAnchors() end
    widget:AddAnchor("TOPLEFT", "UIParent", x, y)
    widget:SetExtent(resolvedWidth, resolvedHeight)
    return x, y, resolvedWidth, resolvedHeight
end

function L:SnapAndStore(target, widget)
    if widget == nil then return end
    local context = self:GetContext()
    local x, y, width, height = self:GetLogicalRect(widget)
    local snap = self:Scale(C.SnapDistance)
    local left = context.safeLeft
    local top = context.safeTop
    local right = context.logicalWidth - context.safeRight - width
    local bottom = context.logicalHeight - context.safeBottom - height

    -- HUD snapping is an editor-only affordance. Normal unlocked HUD dragging
    -- stays free, preventing the "window suddenly jumps" behavior called out in
    -- the v1.1 spec. The main Suite window keeps its historical edge snapping.
    local isHud = widget.rsHudOwner ~= nil
    local snapHud = isHud and S.HudManager ~= nil and S.HudManager:IsEditMode() == true
        and ActiveSettings().hudSnapEnabled ~= false
    local snapScreen = (not isHud) or snapHud

    if snapScreen then
        if math.abs(x - left) <= snap then x = left end
        if math.abs(x - right) <= snap then x = right end
        if math.abs(y - top) <= snap then y = top end
        if math.abs(y - bottom) <= snap then y = bottom end
    end

    if snapHud and type(S.HudManager.GetSnapWindows) == "function" then
        local function SnapAxis(value, size, otherValue, otherSize)
            local candidates = {
                otherValue,                         -- left/top align
                otherValue + otherSize - size,      -- right/bottom align
                otherValue + otherSize,             -- place after
                otherValue - size,                  -- place before
            }
            local best, bestDistance = value, snap + 0.001
            for _, candidate in ipairs(candidates) do
                local distance = math.abs(value - candidate)
                if distance <= snap and distance < bestDistance then best, bestDistance = candidate, distance end
            end
            return best
        end
        for _, other in ipairs(S.HudManager:GetSnapWindows(widget)) do
            local ox, oy, ow, oh = self:GetLogicalRect(other)
            x = SnapAxis(x, width, ox, ow)
            y = SnapAxis(y, height, oy, oh)
        end
    end

    -- Persisted/live result always keeps an operable area inside the safe area.
    x = Clamp(x, left, math.max(left, right))
    y = Clamp(y, top, math.max(top, bottom))

    if widget.RemoveAllAnchors ~= nil then widget:RemoveAllAnchors() end
    widget:AddAnchor("TOPLEFT", "UIParent", x, y)
    self:StorePlacement(target, widget)
end

-- Pure main-window spec solver. M6 exposes this separately from GetMainSpec so
-- Diagnostics can simulate the supported resolution / UI-scale matrix without
-- mutating UIParent or the player's saved settings. Runtime still calls the same
-- solver, therefore the acceptance matrix cannot drift into a second layout
-- implementation.
function L:BuildMainSpec(context, placement, fontScale)
    context = type(context) == "table" and context or self:GetContext()
    local scale = math.max(0.01, tonumber(context.addonScale) or 1)
    placement = type(placement) == "table" and placement or {}

    local defaultColumns = tonumber(context.columns) or 2
    local baseWidth, baseHeight
    if defaultColumns == 3 then
        baseWidth, baseHeight = C.MainWindow.threeColumnWidth, C.MainWindow.threeColumnHeight
    elseif defaultColumns == 2 then
        baseWidth, baseHeight = C.MainWindow.twoColumnWidth, C.MainWindow.twoColumnHeight
    else
        baseWidth, baseHeight = C.MainWindow.oneColumnWidth, C.MainWindow.oneColumnHeight
    end

    local designWidth = math.max(C.MainWindow.minWidth or 560, tonumber(placement.width) or baseWidth)
    local designHeight = math.max(C.MainWindow.minHeight or 600, tonumber(placement.height) or baseHeight)

    -- Outer-surface size is user authority. Responsive breakpoints below decide
    -- how content reflows INSIDE that surface; they must not silently clamp the
    -- window back to the current viewport or to historical 1180x900 defaults.
    -- Native Windowing owns the technical resize floor/limit separately.
    local width = designWidth * scale
    local height = designHeight * scale

    -- Column count is derived from the *actual* user-sized main window, not
    -- just the physical monitor. This keeps cards readable when the user
    -- narrows the dashboard and lets a wider resized dashboard expose more.
    local actualDesignWidth = width / scale
    -- M1 App Shell uses a real grouped navigation rail instead of the former
    -- 82px flat tab strip. Keep the rail readable on wide windows, then
    -- compress it progressively on narrow user-sized windows. The page content
    -- remains the flexible side of the split; no resolution-specific branch is
    -- hardcoded here.
    local navDesignWidth = 218
    if actualDesignWidth < 900 then navDesignWidth = 196 end
    if actualDesignWidth < 720 then navDesignWidth = 166 end
    local actualContentDesignWidth = math.max(1, actualDesignWidth - navDesignWidth - (C.Layout.margin or 10) * 3)
    local requestedFont = fontScale
    if requestedFont == nil then requestedFont = ActiveSettings().fontScale end
    local fontDensity = math.max(1.0, math.min(1.50, tonumber(requestedFont) or 1.2))
    local oneColumnThreshold = 400
    local threeColumnThreshold = 780 * fontDensity
    local columns = 3
    if actualContentDesignWidth < oneColumnThreshold then
        columns = 1
    elseif actualContentDesignWidth < threeColumnThreshold or context.breakpoint == "COMPACT" then
        columns = 2
    end

    local margin = C.Layout.margin * scale
    local titleHeight = C.Layout.titleHeight * scale * fontDensity
    local tabHeight = C.Layout.tabHeight * scale * math.max(1.0, math.min(1.15, fontDensity))
    local navWidth = navDesignWidth * scale
    local navGap = C.Layout.cardGap * scale
    return {
        width = width,
        height = height,
        columns = columns,
        margin = margin,
        titleHeight = titleHeight,
        tabHeight = tabHeight,
        navWidth = navWidth,
        navGap = navGap,
        contentX = margin + navWidth + navGap,
        contentY = titleHeight + margin,
        contentWidth = math.max(1, width - margin * 2 - navWidth - navGap),
        contentHeight = math.max(1, height - titleHeight - margin * 2),
        gap = C.Layout.cardGap * scale,
        rowHeight = C.Layout.rowHeight * scale * fontDensity,
        compactRowHeight = C.Layout.compactRowHeight * scale * fontDensity,
    }
end

function L:GetMainSpec()
    return self:BuildMainSpec(self:GetContext(), ActiveMainPlacement(), ActiveSettings().fontScale)
end

