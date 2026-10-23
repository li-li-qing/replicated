------------------------------------------------------------------------
-- Replicated Suite · 逻辑布局与分辨率安全
-- 作者：Replicated
-- QQ群：1104129461
--
-- 响应式布局权威。
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

-- ArcheAge/CryEngine UI 逻辑坐标约定：原点为视口左上角，X 向右递增，Y 向下递增。功能和布局代码不得猜测“上移
-- 图标”等人类指令的符号。
L.CoordinateSystemContractVersion = 1
L.RectTransformTransactionContractVersion = 2
L.ScreenToWidgetLocalContractVersion = 2
L.ResponsivePlacementIntentContractVersion = 1
L.ViewportLogicalRectContractVersion = 1
L.EffectiveGeometryCalibrationContractVersion = 1 -- 保留 RU Effective Geometry 单位校准契约，供外部原生控件和诊
                                                  -- 断继续使用。
L.SuiteOwnedViewportAnchorContractVersion = 1 -- 从 .18.190 起，Suite 自己创建并由 Diff Authority 布局的控件
                                              -- ，Popup 锚点必须优先使用完整 NativeStateCache 父链，而不能继
                                              -- 续猜测 GetEffectiveOffset 的单位。
L.StartupMetricsSettleContractVersion = 1 -- 启动/重登后的 UIParent 与 UI Scale 允许晚于插件加载稳定；只做有
                                          -- 界 one-shot 复采样，不引入永久 Poll/Tick。
L.UiEnvironmentRevisionContractVersion = 1 -- （2026-09-24，visual-guide-resolution-style-recovery-1）分辨率
                                           -- /UI Scale/原生 UI 重载可能在几何签名不变时仍重置 TextStyle。
                                           -- Layout 只发布“UI 环境已发生边沿”的 session revision，不拥有业
                                           -- 务样式；高频 Presenter 可据此一次性失效自己的 Native diff
                                           -- cache，而不是每帧重写字体。
L.uiEnvironmentRevision = tonumber(L.uiEnvironmentRevision) or 0
L.lastUiEnvironmentReason = L.lastUiEnvironmentReason or "bootstrap"
L.coordinateSystem = {
    origin = "top_left",
    xPositive = "right",
    xNegative = "left",
    yPositive = "down",
    yNegative = "up",
}
L.geometryMetrics = { transformBegins = 0, transformPreviews = 0, transformOverrides = 0, transformCommits = 0, transformCancels = 0, transformRejects = 0 }

-- 仅在几何入口做有限数过滤；nil/NaN/Infinity 不能
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

-- 按语义移动点，距离作为大小，符号由辅助函数决定；本坐标系的上移须减去 Y。
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

-- 供编辑器类 UI 使用的纯 RectTransform 事务，只拥有数学及回滚语义；原生鼠标捕获归 Windowing/Input。delta 始
-- 终相对 Begin() 计算，不逐帧累加。
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
        -- 吸附缩放覆盖值被夹紧时，须像 PreviewDelta() 一样固定对侧边缘，避免选择框越过用户保持不动的边缘。
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
    -- V3 Shell 几何归 v3.shell；Layout 仅为纯 metrics 权威，不回读已删除 S.State 的旧状态树。
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

-- 合成逻辑视口只供按需 M6 验收诊断使用；有意绕开 S.Api，不更新 L.context/lastSignature。
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
        -- 物理尺寸与断点不变时 logical viewport 仍可变化。签名必须含完整坐标空间，
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

-- （2026-09-24，visual-guide-resolution-style-recovery-1）这个 revision 只表示 Native/UI
-- 环境出现了可能使“已写入的视觉样式”失真的边沿，不代表 Feature 数据变化。Authority 仍是
-- Layout 对 viewport/scale 的事实；调用者只能把它用于丢弃 Presentation cache，禁止据此改用户配置。
-- 之所以不能只看 MakeSignature：切换画质或 UI_RELOADED 可能保持相同分辨率，却让 Native TextStyle
-- 回到创建时默认字号。revision 是 session-only 标量，不持久化，也不触发任何额外扫描。
function L:BumpUiEnvironmentRevision(reason)
    self.uiEnvironmentRevision = (tonumber(self.uiEnvironmentRevision) or 0) + 1
    self.lastUiEnvironmentReason = tostring(reason or "unknown")
    return self.uiEnvironmentRevision
end

function L:GetUiEnvironmentRevision()
    return tonumber(self.uiEnvironmentRevision) or 0, tostring(self.lastUiEnvironmentReason or "unknown")
end

-- 一次响应式表现事务在 V3 重建模式下由 UIHostManager 拥有，不走旧 UI 工厂。此桥接避免分辨率或 UI 缩放变化落
-- 入依赖已删除 S.State 的旧代码。
function L:ApplyResponsivePresentation(fromMetricsChange)
    -- 顶层窗注册表独立于主窗口生命周期。以前 main host 缺失会提前 return，
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

-- 应用 UI 设置使用立即刷新，当前即更新 signature，避免下一次原生或生命周期事件重复不变的 reflow。这里只更新
-- 事件身份，不进行后台 metrics 轮询。
function L:RefreshNow(fromMetricsChange)
    local fresh = self:GetContext(true)
    self.lastSignature = self:MakeSignature(fresh)
    self.invalidated = false
    -- 即使 viewport signature 不变，应用字号或插件缩放也会改变原生 label 样式；须在 reflow 前发布视觉环境边沿。
    self:BumpUiEnvironmentRevision(fromMetricsChange == true and "refresh_now_metrics" or "refresh_now")
    return self:ApplyResponsivePresentation(fromMetricsChange == true)
end

-- 保留 PollChanges 名称供旧调用/离线验收；Runtime 已移除周期注册。
-- 只由生命周期边沿调用；即使签名不变也发布新 context，避免 forced read 与 lastSignature 脱节。
function L:PollChanges()
    local fresh = self:BuildContext()
    local signature = self:MakeSignature(fresh)
    local changed = signature ~= self.lastSignature
    self.context, self.invalidated, self.lastSignature = fresh, false, signature
    if changed then
        self.metricsRevision = (tonumber(self.metricsRevision) or 0) + 1
        self:BumpUiEnvironmentRevision("metrics_signature_changed")
        self:ApplyResponsivePresentation(true)
    end
    return changed
end

-- （2026-09-22，relog-floating-placement-settle-1）ArcheRage RU 登录/切角色期间，
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
-- viewport 与已存在窗口的只读几何；仅发现偏移才重放同一矩形，不触发业务刷新。
-- Generation/epoch/serial 三层隔离保证重载或
-- Stop 后的迟到回调不能继续改布局。风险仅是启动期增加少量低频 UI metrics 读取。
local METRICS_SETTLE_DELAYS_MS = { 150, 350, 700, 1200, 1800, 2600, 3600, 5000 }

-- （2026-09-30，ui-position-reload-1）尺寸签名相同不等于 Native 窗口未被重置。
-- 复用 Windowing 现有 owner/cache，在启动有界观察窗口内独立核对几何；不启用业务、不保存位置。
function L:ReconcileWindowGeometry(reason)
    local windowing = S.RSUI and S.RSUI.Windowing
    if not windowing or type(windowing.ReconcileIdleGeometry) ~= "function" then return true end
    local ok, accepted, repaired, failures = pcall(windowing.ReconcileIdleGeometry, windowing, reason)
    if type(self.metricsNotifications) == "table" then
        self.metricsNotifications.geometryReconciles = (tonumber(self.metricsNotifications.geometryReconciles) or 0) + 1
        self.metricsNotifications.geometryReconcileError = (not ok or accepted ~= true)
            and tostring(ok and failures or accepted or "geometry_reconcile_failed") or nil
    end
    return ok and accepted == true, repaired, failures
end

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
                local changed = L:PollChanges()
                if changed ~= true then L:ReconcileWindowGeometry("metrics_settle:" .. tostring(attempt)) end
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
        -- 绑定成功与实际收到回调是两种证据；只保留计数和末次原因，不存事件历史。
        L.metricsNotifications.signals=L.metricsNotifications.signals+1
        if reason=="native_on_scale" then L.metricsNotifications.nativeScaleDeliveryObserved=true end
        -- PollChanges 在 viewport/signature 真变化时会 bump revision；若签名不变（典型：画质切换
        -- / UI_RELOADED 只重置 TextStyle），仍必须发布一次 UI 环境 revision，供手工样式 Presenter
        -- 失效旧 Native cache。禁止在这里直接操作任何 Feature/UI 控件。
        local changed = L:PollChanges()
        if changed ~= true then
            L:BumpUiEnvironmentRevision("native_signal:" .. tostring(reason or "unknown"))
            L:ReconcileWindowGeometry("native_signal:" .. tostring(reason or "unknown"))
        end
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


-- 独立弹窗/UIParent 坐标归一化不能改造旧 GetLogicalRect() 语义，因为 Windowing/拖动/吸附调用者已依赖它。弹
-- 窗需要更严格契约：实时控件矩形只转换一次到 UIParent 视口逻辑坐标。RU 的
-- GetEffectiveOffset/GetEffectiveExtent 可能返回逻辑或 UI 缩放单位，须由多项有界事实校准，不能无条件除
-- uiScale。Suite 缓存的逻辑 extent 最可靠：raw 接近 logical 时 scale=1，raw 接近 logical*uiScale 时
-- scale=uiScale；UIParent effective extent 和物理/逻辑视口比例仅作兜底证据。
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

    -- 每个候选与同单位事实逐一评分；Suite 缓存 extent 权重最高，它是通过 Diff 权威实际写入的逻辑值。只有控
    -- 件缺少可用 effective extent 时，根节点或屏幕比例才用于打破平局。
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

local function ResolveCachedViewportRect(widget) -- 沿 UI Diff Authority 已提交的真实 NativeStateCache 父链累加
                                                 -- 逻辑坐标，得到相对 UIParent 的唯一可证明锚点。
    local cache = S.UI and S.UI.NativeStateCache or nil -- NativeStateCache 是 UI:SetAnchor/UI:SetExtent 的写入镜像，因
                                                        -- 此对 Suite-owned 控件比 RU GetEffectiveOffset 的单位猜测更可
                                                        -- 靠。
    if type(cache) ~= "table" or widget == nil then return nil end -- 没有缓存表或目标控件时无法证明完整父链，必须 fail-closed。
    local x, y = 0, 0 -- 从目标控件开始累计每一级 TOPLEFT 逻辑偏移，最终得到 UIParent-local X/Y。
    local current, guard = widget, 0 -- current 保存当前父链节点，guard 防止异常父链形成死循环。
    local first = cache[current] -- 目标节点自身的缓存行提供 Popup 需要的宽高。
    local width = type(first) == "table" and tonumber(first.width) or nil -- 宽度直接使用 Diff Authority 写入的逻辑宽度，不再根据 UI
                                                                          -- Scale 二次换算。
    local height = type(first) == "table" and tonumber(first.height) or nil -- 高度同样使用逻辑高度，保证 Dropdown 行高和触发器高度处于同一
                                                                            -- 坐标空间。
    while current ~= nil and current ~= UIParent and current ~= "UIParent" and guard < 64 do -- 只有父链最终确实抵达 UIParent 才允许作为 detached Popup 的屏
                                                                                             -- 幕锚点。
        guard = guard + 1 -- 每向上追溯一级就增加保护计数，64 层远高于当前 RSUI 树深度。
        local row = cache[current] -- 读取当前节点最后一次由 Diff Authority 或 Native Primitive Factory 成功
                                   -- 提交的 Native 几何状态。
        if type(row) ~= "table" then return nil end -- 当前节点连缓存行都不存在时父链不可证明，必须立即 fail-closed
                                                    -- 。
        local parent = row.anchorParent -- 优先读取 DiffRenderer v2 使用的标量父节点字段，这是后续布局写入的
                                        -- 标准形式。
        local anchorX = tonumber(row.anchorX) -- 优先读取标量逻辑 X；保持与 UI:SetAnchor 写入单位完全一致。
        local anchorY = tonumber(row.anchorY) -- 优先读取标量逻辑 Y；保持与 UI:SetAnchor 写入单位完全一致。
        local legacy = type(row.anchorTopLeft) == "table" and row.anchorTopLeft or nil -- Native Primitive Factory 初次创建控件时可能只 Prime `
                                                                                       -- anchorTopLeft`，即使后续位置未变化也不会强制迁移成标量字段。
        if parent == nil and legacy ~= nil then parent = legacy.parent end -- 仅当标准父字段缺失时读取兼容父节点，避免覆盖已经由
                                                                           -- DiffRenderer 更新的新 Authority。
        if anchorX == nil and legacy ~= nil then anchorX = tonumber(legacy.x) end -- 仅在标量 X 缺失时读取初始 Prime 的逻辑 X，保证未发生重排的控
                                                                                  -- 件也能组成完整父链。
        if anchorY == nil and legacy ~= nil then anchorY = tonumber(legacy.y) end -- 仅在标量 Y 缺失时读取初始 Prime 的逻辑 Y，保证首次打开 Popup
                                                                                  -- 不依赖先发生一次布局变更。
        if parent == nil then return nil end -- 标准字段和兼容字段都无法证明父节点时，禁止退回
                                             -- EffectiveOffset 猜坐标。
        x = x + (anchorX or 0) -- 累加当前节点相对父节点的逻辑 X；项目统一左上角原点，向右为正。
        y = y + (anchorY or 0) -- 累加当前节点相对父节点的逻辑 Y；项目统一左上角原点，向下为正。
        current = parent -- 继续沿已经明确解析出的真实缓存父节点追溯，直到 UIParent。
    end -- 结束父链追溯循环。
    if current ~= UIParent and current ~= "UIParent" then return nil end -- 未在保护深度内抵达 UIParent 时视为不可证明坐标，直接拒绝。
    return x, y, math.max(1, width or 1), math.max(1, height or 1), guard -- 返回 UIParent-local 逻辑矩形和父链深度，父链深度用于诊断，不
                                                                          -- 参与业务判断。
end -- 结束缓存父链解析 helper。

function L:ResolveSuiteOwnedViewportLogicalRect(widget) -- 这是 .18.190 新增的 Suite-owned Popup 锚点 Authority，只接受
                                                        -- 完整 Diff cache 父链。
    if widget == nil then return nil, nil, nil, nil, { source = "suite_widget_missing", coordinateSpace = "viewport-logical-v1" } end -- 目标为空时明确返回不可用来源，避免上层退回魔法偏移。
    local x, y, width, height, depth = ResolveCachedViewportRect(widget) -- 直接消费完整缓存父链，不读取 RU EffectiveOffset，因此不会再
                                                                         -- 被 UI Scale/分辨率语义差异污染。
    if x == nil then return nil, nil, nil, nil, { source = "suite_anchor_chain_unavailable", coordinateSpace = "viewport-logical-v1" } end -- 父链不完整时 fail-closed，让 PopupPositioning 决定是否允许外
                                                                                                                                           -- 部原生车道兜底。
    return x, y, width, height, { -- 返回已经处于 UIParent viewport-logical-v1 的最终锚点，Consumer 禁止再次
                                  -- 乘除 uiScale。
        source = "suite_native_state_anchor_chain", -- 明确记录 Authority 来源，实机诊断可直接区分 cache 父链与
                                                    -- 实际生效的 API。
        coordinateSpace = "viewport-logical-v1", -- 标记唯一允许 detached Popup 消费的逻辑视口坐标空间。
        effectiveScale = 1, -- 缓存父链本身已经是 UI:SetAnchor 接收的逻辑单位，因此这里不存在二次 Effective scale。
        scaleSource = "diff_authority_logical", -- 诊断说明此次没有执行 RU EffectiveGeometry 单位猜测。
        anchorDepth = tonumber(depth) or 0, -- 记录从 Trigger 到 UIParent 的完整父链层数，方便定位未来断链问题。
    } -- 结束元数据表。
end -- Suite 自有视口逻辑矩形权威段结束。

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

    -- Suite 节点的 effective API 暂不可用（如祖先切换可见性）时使用有界兜底。不可混用局部 effective 结果；
    -- 完整矩形只能归一个完整来源，遵守单次转换。
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

-- Windowing 专用 live geometry，区别于 Popup 的缓存锚点。
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


-- 屏幕/Overlay 坐标适配复用已校准的视口逻辑权威：先减 UIParent 原始原点，再只转换一次。ScreenProjectionV3
-- 输出 UIParent 本地逻辑坐标；不能先走无条件除 uiScale 的旧 GetLogicalRect() 再除 UIParent 原点，否则
-- effective API 已返回逻辑单位的 RU 客户端在 UI Scale != 1 时会发生双重偏移。
function L:GetUiParentLocalOrigin(widget)
    if widget == nil then return 0, 0, false, "widget_missing" end
    local widgetX, widgetY, _, _, info = self:ResolveViewportLogicalRect(widget)
    widgetX, widgetY = tonumber(widgetX), tonumber(widgetY)
    if widgetX == nil or widgetY == nil then
        return 0, 0, false, type(info) == "table" and tostring(info.source or "origin_unavailable") or "origin_unavailable"
    end
    -- （2026-09-22，screen-origin-authority-2）ResolveViewportLogicalRect 的返回值已经是
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

-- 分辨率安全层只保证实时表现能在当前 UIParent 逻辑画布上操作。Suite 位置、DPS 矩形、Gear 快捷位置、Healer
-- 锚点等持久化仍归各 Domain；分辨率兜底不持久化，除非用户在该分辨率显式拖动或保存。
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

-- 小浮控件的纯同级吸附解算器，不写几何、不夹紧屏幕位置、不持久化，权威归调用者。候选保持调用者设定的横/纵间
-- 隙，只有两轴都在阈值内才吸附，避免跳到远处行列。
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

            -- 横向相邻项：右/左侧保持稳定视觉间隙。
            for _, ay in ipairs(yAlign) do
                Consider(ox + ow + gapX, ay, index)
                Consider(ox - width - gapX, ay, index)
            end
            -- 纵向相邻项：下/上侧保持稳定视觉间隙。
            for _, ax in ipairs(xAlign) do
                Consider(ax, oy + oh + gapY, index)
                Consider(ax, oy - height - gapY, index)
            end
        end
    end

    return bestX, bestY, bestScore ~= nil, bestIndex
end

-- 顶层窗口完全可见约束须分别使用四条 SafeInset；RU 窗口模式、UI Scale 和系统栏组合下四边未必对称，不能将
-- safeLeft 当统一 edge。Layout context 只影响实时几何，不写 Store。options.edge 保留显式对称覆盖，未传时严
-- 格消费当前四边安全区。
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

-- V3 自由放置不要求正常拖动时整窗留在视口，仅在即将无法恢复访问时介入：至少保留少量横向握持区和部分顶部拖动
-- 条可达。允许部分出屏，同时避免当前分辨率下永久不可访问的位置。
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

    -- 横向恢复可使用标题或拖动面的任一侧。
    local minX = left - width + visibleX
    local maxX = right - visibleX

    -- 外窗的拖动条位于顶部，须保留可达条带，不能只留任意正文在屏幕内。整面可拖控件（如 R 启动器）使用
    -- topReachHeight == height。
    local minY = top - topReachHeight + visibleY
    local maxY = bottom - visibleY

    return Clamp(tonumber(x) or left, minX, math.max(minX, maxX)),
        Clamp(tonumber(y) or top, minY, math.max(minY, maxY))
end

-- （2026-09-25，screen-buttons-deoverlap-1）独立屏幕按钮（Gear / 功能方案）共享同一
-- screen_buttons 吸附组，但恢复时每个按钮各自 ResolvePlacement；当新 viewport 比保存时更窄
-- （或临时 viewport 与最终 viewport 不一致）时，多个 RIGHT/BOTTOM 锚点会被 ClampTopLeft 压到
-- 完全相同的矩形，用户只能看到最上面的一个。本 solver 只在“已经重叠”时移动矩形：
-- 输入/输出都是纯数据，不读 Native、不写 Store、不注册任何周期任务，调用方保留几何提交权。
-- 顺序保持输入顺序（= 方案顺序），候选位移只取相邻 blocker 的右侧/下方/左侧/上方，
-- 并选择位移最小且完全落在当前 safe viewport 内的解；无解时做有界网格扫描。
-- 没有重叠时结果与输入逐字节相同，因此“同分辨率精确恢复”不受影响。
L.ScreenDeoverlapContractVersion = 1
L.screenDeoverlapMetrics = L.screenDeoverlapMetrics or { solves = 0, adjusted = 0, unresolved = 0 }

local function ScreenRectsOverlap(ax, ay, aw, ah, bx, by, bw, bh, gapX, gapY)
    return ax < bx + bw + gapX and bx < ax + aw + gapX
        and ay < by + bh + gapY and by < ay + ah + gapY
end

function L:DeoverlapScreenRects(items, options)
    local results = {}
    if type(items) ~= "table" or #items == 0 then return results end
    options = type(options) == "table" and options or {}
    local context = self:GetContext()
    local gapX = math.max(0, Finite(options.gapX, 0))
    local gapY = math.max(0, Finite(options.gapY, 0))
    local clampOptions = tonumber(options.edge) ~= nil and { edge = tonumber(options.edge) } or nil
    local accepted = {}
    self.screenDeoverlapMetrics.solves = (tonumber(self.screenDeoverlapMetrics.solves) or 0) + 1

    local function Occupied(x, y, width, height)
        for _, other in ipairs(accepted) do
            if ScreenRectsOverlap(x, y, width, height, other.x, other.y, other.width, other.height, gapX, gapY) then
                return true
            end
        end
        return false
    end

    for index, item in ipairs(items) do
        if type(item) ~= "table" then return results end
        local width = math.max(1, Finite(item.width, 1))
        local height = math.max(1, Finite(item.height, 1))
        local x, y = self:ClampTopLeft(Finite(item.x, context.safeLeft), Finite(item.y, context.safeTop), width, height, clampOptions)
        local candidate = {
            key = item.key, index = index, order = tonumber(item.order) or index,
            x = x, y = y, width = width, height = height, adjusted = false,
        }
        if Occupied(x, y, width, height) then
            local best, bestScore = nil, nil
            local function Consider(cx, cy)
                local fx, fy = self:ClampTopLeft(cx, cy, width, height, clampOptions)
                -- 只有“请求点本身就在 safe viewport 内”才接受，避免用 clamp 制造假解。
                if math.abs(fx - cx) > 0.5 or math.abs(fy - cy) > 0.5 then return end
                if Occupied(fx, fy, width, height) then return end
                local dx, dy = fx - x, fy - y
                local score = dx * dx + dy * dy
                if bestScore == nil or score < bestScore - 0.0001 then best, bestScore = { x = fx, y = fy }, score end
            end
            for _, other in ipairs(accepted) do
                Consider(other.x + other.width + gapX, y)
                Consider(x, other.y + other.height + gapY)
                Consider(other.x - width - gapX, y)
                Consider(x, other.y - height - gapY)
            end
            if best == nil then
                -- 有界兜底：粗网格从左上到右下找第一个空位，最多 1024 个采样点。
                local step = math.max(4, math.floor(math.min(width, height) / 2))
                local maxX = math.max(context.safeLeft, context.logicalWidth - (tonumber(context.safeRight) or 0) - width)
                local maxY = math.max(context.safeTop, context.logicalHeight - (tonumber(context.safeBottom) or 0) - height)
                local probes = 0
                local gx = context.safeLeft
                while gx <= maxX and best == nil and probes < 1024 do
                    local gy = context.safeTop
                    while gy <= maxY and probes < 1024 do
                        probes = probes + 1
                        if not Occupied(gx, gy, width, height) then best = { x = gx, y = gy }; break end
                        gy = gy + step
                    end
                    gx = gx + step
                end
            end
            if best ~= nil then
                candidate.x, candidate.y, candidate.adjusted = best.x, best.y, true
                self.screenDeoverlapMetrics.adjusted = (tonumber(self.screenDeoverlapMetrics.adjusted) or 0) + 1
            else
                -- 实在无解（例如 viewport 比按钮本身还小）时保留原投影，绝不隐藏该按钮。
                self.screenDeoverlapMetrics.unresolved = (tonumber(self.screenDeoverlapMetrics.unresolved) or 0) + 1
            end
        end
        accepted[#accepted + 1] = candidate
        results[#results + 1] = candidate
    end
    return results
end

function L:GetScreenDeoverlapSnapshot()
    return {
        contractVersion = tonumber(self.ScreenDeoverlapContractVersion) or 0,
        solves = tonumber(self.screenDeoverlapMetrics.solves) or 0,
        adjusted = tonumber(self.screenDeoverlapMetrics.adjusted) or 0,
        unresolved = tonumber(self.screenDeoverlapMetrics.unresolved) or 0,
    }
end

function L:IsRectFullyVisible(x, y, width, height, options)
    options = type(options) == "table" and options or {}
    local context = self:GetContext()
    local edge=Finite(options.edge)
    if edge~=nil then edge=math.max(0,edge) end
    local left,top=edge or context.safeLeft,edge or context.safeTop
    local right,bottom=edge or context.safeRight,edge or context.safeBottom
    x, y = tonumber(x), tonumber(y)
    width, height = math.max(1, tonumber(width) or 1), math.max(1, tonumber(height) or 1)
    if x == nil or y == nil then return false end
    -- Effective 坐标换算会产生约 1e-13 的浮点尾数；只吞数值误差，不容忍真实像素越界。
    local epsilon=1e-7
    return x >= left-epsilon and y >= top-epsilon
        and x + width <= context.logicalWidth - right+epsilon
        and y + height <= context.logicalHeight - bottom+epsilon
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
            -- V3 浮面默认自由放置；旧版或例外调用者须显式请求安全约束。
            self:EnsureWidgetVisible(widget, item.options)
        end
    end
    return true
end

function L:UnregisterFloating(id)
    self.floatingRegistry[tostring(id or "")] = nil
end

-- 屏幕吸附登记表与 floatingRegistry 分开；后者拥有分辨率安全回调，ScreenSnapRegistry 只负责发现吸附目标。生
-- 命周期独立可避免模块加入屏幕按钮吸附时误替换安全回调。
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

-- 通用屏幕控件吸附解算器只拥有跨模块目标发现和几何；用户设置与持久化归业务模块。排除隐藏控件，因此禁用功能
-- 不增加候选成本。snapGroup 隔离无关表面，必要时 snapKind 再区分按钮和窗口。
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
                -- peer 与拖动源必须处于相同 logical 空间；不能一端校准、一端再 /uiScale。
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
    -- 安全拖动时目标锚定原生移动代理，由 CryEngine 按原生帧率跟随，不做 Lua 轮询。此函数保留为兼容查询点，
    -- 只报告当前逻辑位置。
    local drag = self.safeDrag
    if type(drag) ~= "table" or drag.target == nil then return false end
    local x, y = self:GetLogicalRect(drag.target)
    drag.lastX, drag.lastY = tonumber(x) or drag.startX, tonumber(y) or drag.startY
    return true
end

function L:BeginSafeMove(key, target, options)
    -- 不能把已进行的拖动手势转交另一个不可见窗口：ArcheRage RU 不能可靠地把当前捕获移给未收到 OnDragStart
    -- 的代理。代理不动却返回成功会使 Suite/Gear/Healer/Plates/HUD 跳过可靠的原生 StartMoving() 兜底，导致无
    -- 法拖动。分辨率安全集中在 RegisterFloating()/RefreshFloatingSafety()/EnsureWidgetVisible() 和拖动停止
    -- 夹紧中；除非模块拥有完整代理事务（DPS 排名窗含自身帧驱动），消费者须走原生拖动路径。返回 false 是显式
    -- 能力结果，不是错误。
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

-- Windowing 提交拖动/缩放时产生唯一逻辑 x/y/width/height，StorePlacementRect 只消费此矩形，不能再
-- GetLogicalRect(widget) 读取 Native，以免 UI Scale 或更新时序导致实时位置与存档漂移。StorePlacement 仅为无
-- 显式事务矩形的低频兼容入口。权威链：Windowing committed rect -> Layout -> Feature/UI Store；持久字段、
-- coordinateSpace、响应式中心比例不变，不触碰 schema。
function L:StorePlacementRect(target, x, y, width, height, options)
    if type(target) ~= "table" then return end
    options = type(options) == "table" and options or {}
    local context = self:GetContext()
    x, y = tonumber(x) or 0, tonumber(y) or 0
    local mode = tostring(options.mode or "free")
    width = math.max(1, tonumber(width) or 1)
    height = math.max(1, tonumber(height) or 1)

    -- 自由且可恢复的放置允许大于视口；严格或边缘放置继续适配当前分辨率。
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
        -- 分辨率无关放置意图保留权威逻辑 x/y，以准确恢复相同视口，同时将窗口中心保存为当前 UIParent 比例。
        -- 分辨率变化后按比例投影到新视口，不把旧绝对像素当作新画布坐标，也不使用分辨率查询表。
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
    -- 边缘意图自包含；从旧自由放置切换时删除自由面的 viewport 元数据，避免同一工作表携带两套竞争定位权威。
    target.savedLogicalWidth, target.savedLogicalHeight = nil, nil
    target.normalizedCenterX, target.normalizedCenterY = nil, nil
    return x, y, width, height
end

function L:StorePlacement(target, widget, options)
    if type(target) ~= "table" or widget == nil then return end
    local x, y, width, height = self:GetLogicalRect(widget)
    return self:StorePlacementRect(target, x, y, width, height, options)
end

-- 此策略仅用于 persistent/session 顶层窗口，不替换 Popup/HUD。
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

-- 普通窗口松手吸附安全视口边缘。阈值使用逻辑单位，Native/UI Scale 仅在统一读几何入口换算。
-- 每轴独立选择最近边；不更改尺寸，也不写存档。兄弟控件吸附仍由原 ScreenSnap 管理。
function L:ResolveWindowEdgeSnap(x,y,width,height,distance)
    local c=self:GetContext()
    local d=math.max(0,Finite(distance,12))
    local left,top=c.safeLeft,c.safeTop
    local right,bottom=math.max(left,c.logicalWidth-c.safeRight-width),math.max(top,c.logicalHeight-c.safeBottom-height)
    local function Axis(v,a,b)
        if math.abs(v-a)<=d and math.abs(v-a)<=math.abs(v-b) then return a end
        if math.abs(v-b)<=d then return b end
        return v
    end
    return Axis(x,left,right),Axis(y,top,bottom)
end

-- 展开/缩小时保留旧矩形已贴住的边缘，其余位置保留左上角；随后按新可见尺寸夹紧。
-- 贴边识别容差小于一个逻辑像素，不能把普通靠近边缘的自由位置悄悄当作吸附。
function L:GetWindowEdgeAffinity(x,y,width,height,hintH,hintV)
    local c=self:GetContext()
    local left,right=math.abs(x-c.safeLeft)<.01,math.abs(x+width-(c.logicalWidth-c.safeRight))<.01
    local top,bottom=math.abs(y-c.safeTop)<.01,math.abs(y+height-(c.logicalHeight-c.safeBottom))<.01
    local eh=left and right and (hintH or "LEFT") or (left and "LEFT" or (right and "RIGHT" or nil))
    local ev=top and bottom and (hintV or "TOP") or (top and "TOP" or (bottom and "BOTTOM" or nil))
    return eh,ev
end

-- 窗口拟合后恰好占满某轴时，x/y+中心比例无法区分原来贴左还是贴右。
-- 仅这种有歧义的提交使用已有 logical-edge-v1 表达边缘意图；不增加持久字段或改变规范化契约。
function L:StoreWindowPlacementRect(target,x,y,width,height,options)
    if type(target)~="table" then return end
    options=options or {}
    local c=self:GetContext()
    local ambiguous=(options.edgeH~=nil and math.abs(width-c.usableWidth)<.01)
        or (options.edgeV~=nil and math.abs(height-c.usableHeight)<.01)
    if ambiguous and (options.mode==nil or options.mode=="free" or options.mode=="strict") then
        self:StorePlacementRect(target,x,y,width,height,{mode="edge"})
        if options.edgeH then target.anchorH=options.edgeH;target.offsetX=0 end
        if options.edgeV then target.anchorV=options.edgeV;target.offsetY=0 end
        return
    end
    return self:StorePlacementRect(target,x,y,width,height,options)
end

function L:ResolveWindowSizeTransition(x,y,oldWidth,oldHeight,width,height,hintH,hintV)
    local c=self:GetContext()
    width,height=math.min(width,c.usableWidth),math.min(height,c.usableHeight)
    local eh,ev=self:GetWindowEdgeAffinity(x,y,oldWidth,oldHeight,hintH,hintV)
    if eh=="RIGHT" then x=c.logicalWidth-c.safeRight-width end
    if ev=="BOTTOM" then y=c.logicalHeight-c.safeBottom-height end
    x,y=self:ClampTopLeft(x,y,width,height)
    return x,y,width,height,eh,ev
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
    -- UIParent 整数 extent 的像素级舍入（如 1280/1279）
    -- 不能触发“旧展开中心 - 当前 compact 半宽”，否则 1px 度量差会放大为上百像素位移。
    -- 容差仅吞掉约一个原生像素；真实分辨率迁移仍按中心比例，边界安全夹紧仍照常执行。
    local roundingTolerance = math.max(1,1/math.max(.2,c.uiScale),1/math.max(.2,ss or c.uiScale))
    local logicalChanged = known and (math.abs(sw-c.logicalWidth)>roundingTolerance or math.abs(sh-c.logicalHeight)>roundingTolerance) or false
    local scaleChanged = ss ~= nil and ss > 0 and math.abs(ss-c.uiScale)>=0.0005 or false
    local changed = logicalChanged or scaleChanged
    local source = "default"
    local edgeH,edgeV
    local rx, ry = p and Finite(p.normalizedCenterX), p and Finite(p.normalizedCenterY)
    if rx ~= nil and (rx < -2 or rx > 3) then rx = nil end
    if ry ~= nil and (ry < -2 or ry > 3) then ry = nil end
    local hasXY = p and Finite(p.x) ~= nil and Finite(p.y) ~= nil
    local intent = p and p.userMoved ~= false and reason ~= "explicit_reset"
    if intent and hasXY then
        x, y = Finite(p.x), Finite(p.y)
        source = known and "same_viewport_exact" or "legacy_recovery"
        -- （2026-09-30，ui-position-reload-1）只有逻辑视口变化才重投影中心。
        -- UI Scale 变化但 logical canvas 相同，x/y 本来就是同一单位；若上次保存时为展开窗、
        -- 此时已最小化，拿旧中心减新半宽会凭空右移 (旧宽-新宽)/2。反向展开也会左移。
        if logicalChanged and rx ~= nil and ry ~= nil then
            x, y = rx*c.logicalWidth-w*0.5, ry*c.logicalHeight-h*0.5
            source = "normalized_reproject"
        elseif changed and not known then source = "legacy_recovery" end
        -- 已有 x/y + 保存视口 + 中心比例足以还原当时的实际可见矩形，无需给冻结存档加字段。
        -- 仅精确贴边的矩形保留边缘；自由位置继续按现有中心比例投影。展开与 compact 都使用本次尺寸。
        if known and rx ~= nil and ry ~= nil then
            local oldW,oldH=2*(rx*sw-Finite(p.x)),2*(ry*sh-Finite(p.y))
            if oldW>0 and oldW<=sw and oldH>0 and oldH<=sh then
                if math.abs(Finite(p.x)-c.safeLeft)<.01 then x=c.safeLeft;edgeH="LEFT"
                elseif math.abs(Finite(p.x)+oldW-(sw-c.safeRight))<.01 then x=c.logicalWidth-c.safeRight-w;edgeH="RIGHT" end
                if math.abs(Finite(p.y)-c.safeTop)<.01 then y=c.safeTop;edgeV="TOP"
                elseif math.abs(Finite(p.y)+oldH-(sh-c.safeBottom))<.01 then y=c.logicalHeight-c.safeBottom-h;edgeV="BOTTOM" end
            end
        end
    elseif intent and (p.anchorH ~= nil or p.anchorV ~= nil or p.offsetX ~= nil or p.offsetY ~= nil) then
        local ox, oy = math.max(0,Finite(p.offsetX,0)), math.max(0,Finite(p.offsetY,0))
        x = p.anchorH == "RIGHT" and c.logicalWidth-c.safeRight-ox-w or c.safeLeft+ox
        y = p.anchorV == "BOTTOM" and c.logicalHeight-c.safeBottom-oy-h or c.safeTop+oy
        if ox==0 then edgeH=p.anchorH=="RIGHT" and "RIGHT" or "LEFT" end
        if oy==0 then edgeV=p.anchorV=="BOTTOM" and "BOTTOM" or "TOP" end
        source = "legacy_recovery"
    end
    if reason == "explicit_reset" then source = "explicit_reset" end
    local recoverable = self:IsWindowRecoverable(x,y,w,h,options.topReachHeight)
    local fit = w ~= pw or h ~= ph
    -- （2026-09-22，viewport-contained-floating-1）普通 FloatingSurface 的 boundaryMode=free
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
        logicalViewportChanged=logicalChanged, uiScaleChanged=scaleChanged, logicalRoundingTolerance=roundingTolerance,
        savedX=p and Finite(p.x), savedY=p and Finite(p.y),
        migrationApplied=changed or clamped or fit, clampApplied=clamped, fitApplied=fit, recoveryReason=recovery,
        preferredWidth=pw,preferredHeight=ph,savedLogicalWidth=sw,savedLogicalHeight=sh,savedUiScale=ss,
        normalizedCenterX=rx,normalizedCenterY=ry,currentLogicalWidth=c.logicalWidth,currentLogicalHeight=c.logicalHeight,
        currentUiScale=c.uiScale,currentScreenWidth=c.screenWidth,currentScreenHeight=c.screenHeight,
        metricsSource=c.metricsSource,fullyVisible=self:IsRectFullyVisible(x,y,w,h),
        edgeH=edgeH,edgeV=edgeV,
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

        -- 响应式放置中，相同来源视口下精确 x/y 仍是权威；逻辑分辨率真正变化时把保存的中心比例重投影到当前
        -- UIParent，实现浮窗跨分辨率放置而不强迫采用按钮边缘锚定语义。
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
            -- 旧 free-v2 行没有来源视口，不能推算精确跨分辨率位置；只在实时表现中确保控件可恢复访问，避免高
            -- 分辨率绝对坐标完全出屏。只有用户拖动才更改持久化。
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

    -- HUD 吸附仅供编辑器；正常解锁拖动保持自由，避免突然跳窗。Suite 主窗保留既有边缘吸附。
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
                otherValue,                         -- 左/上对齐。
                otherValue + otherSize - size,      -- 右/下对齐。
                otherValue + otherSize,             -- 放到后方。
                otherValue - size,                  -- 放到前方。
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

    -- 持久化及实时结果都须在安全区中保留可操作区域。
    x = Clamp(x, left, math.max(left, right))
    y = Clamp(y, top, math.max(top, bottom))

    if widget.RemoveAllAnchors ~= nil then widget:RemoveAllAnchors() end
    widget:AddAnchor("TOPLEFT", "UIParent", x, y)
    self:StorePlacement(target, widget)
end

-- 纯主窗规格解算器独立于 GetMainSpec 暴露，供 M6 Diagnostics 模拟分辨率/UI 缩放矩阵而不改 UIParent 或玩家设
-- 置。运行时复用同一解算器，避免验收矩阵形成第二套布局实现。
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

    -- 外表面尺寸由用户决定；下方响应式断点只控制内部内容重排，不得悄悄将窗口夹回当前视口或历史 1180x900 默
    -- 认值。技术缩放下限及限制另归原生 Windowing。
    local width = designWidth * scale
    local height = designHeight * scale

    -- 列数依据用户实际调整后的主窗尺寸，而不只看物理显示器；窄窗保持卡片可读，宽窗可展示更多内容。
    local actualDesignWidth = width / scale
    -- 应用外壳采用分组导航栏；宽窗保持可读，随用户缩窄逐步压缩。页面内容始终是弹性部分，不硬编码特定分辨率分支。
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

