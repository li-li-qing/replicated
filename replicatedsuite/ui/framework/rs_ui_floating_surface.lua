------------------------------------------------------------------------
-- Replicated Suite - RSUI Floating Surface Foundation v8
--
-- Thin state/persistence binding layer above WindowShellV3 + Windowing.
-- It does NOT create a second window authority. WindowShell owns chrome and
-- Windowing owns native drag/resize transactions; FloatingSurface only maps
-- shared HUD presentation state (placement/size/minimize/lock/opacity/font scale) to the
-- feature-owned persistent table.
--
-- No permanent Tick/OnUpdate. Screen snapping is optional and only evaluated
-- when a native drag transaction commits.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local UI, RSUI = S.UI, S.RSUI
if type(UI) ~= "table" or type(RSUI) ~= "table" or type(UI.CreateWindowShell) ~= "function" then return end

local generation = tonumber(S.Generation) or 0
if type(RSUI.FloatingSurface) ~= "table" or tonumber(RSUI.FloatingSurface.generation) ~= generation then
    RSUI.FloatingSurface = {
        version = 12,
        generation = generation,
        instances = setmetatable({}, { __mode = "v" }),
        metrics = {
            created = 0, stateWrites = 0, geometryCommits = 0, resets = 0,
            appearanceChanges = 0, lockChanges = 0, minimizeChanges = 0,
            responsiveLayouts = 0, snapCommits = 0, failures = 0,
            closeRequests = 0, closeVetoes = 0, closedCallbacks = 0,
        },
    }
end
RSUI.FloatingSurface.version = 12
RSUI.FloatingSurface.IdempotentMutationContractVersion = 1
RSUI.FloatingSurface.CompactMinimizeContractVersion = 1
RSUI.FloatingSurface.TitleAppearanceContractVersion = 1
RSUI.FloatingSurface.DetachedStateContractVersion = 1
RSUI.FloatingSurface.StateMutationTransactionContractVersion = 1
RSUI.FloatingSurface.ResponsivePlacementIntentContractVersion = 1
RSUI.FloatingSurface.CommittedGeometryPersistenceContractVersion = 1
RSUI.FloatingSurface.generation = generation
local F = RSUI.FloatingSurface

local STATE_KEYS = {
    "width", "height", "minimized", "locked",
    "overallOpacity", "backgroundOpacity", "textOpacity", "fontScale", "userMoved",
    "x", "y", "anchorH", "anchorV", "offsetX", "offsetY",
    "coordinateSpace", "savedUiScale",
    "savedLogicalWidth", "savedLogicalHeight", "normalizedCenterX", "normalizedCenterY",
}

local function Clamp(value, minimum, maximum, fallback)
    local n = tonumber(value) or tonumber(fallback) or minimum
    if n < minimum then n = minimum end
    if maximum ~= nil and n > maximum then n = maximum end
    return n
end

local function FirstNonNil(primary, secondary)
    if primary ~= nil then return primary end
    return secondary
end

local function SafeCall(fn, ...)
    if type(fn) ~= "function" then return true end
    local args, count = { ... }, select("#", ...)
    local ok, a, b = xpcall(function() return fn(unpack(args, 1, count)) end, S.SafeTraceback)
    if ok ~= true then return false, tostring(a or "floating callback failed") end
    if a == false then return false, tostring(b or "floating callback failed") end
    return true, a
end

local function ReadPolicy(policy)
    policy = type(policy) == "table" and policy or {}
    return {
        defaultWidth = math.max(1, tonumber(policy.defaultWidth) or tonumber(policy.width) or 420),
        defaultHeight = math.max(1, tonumber(policy.defaultHeight) or tonumber(policy.height) or 286),
        minWidth = math.max(1, tonumber(policy.minWidth) or 1),
        minHeight = math.max(1, tonumber(policy.minHeight) or 1),
        maxWidth = tonumber(policy.maxWidth),
        maxHeight = tonumber(policy.maxHeight),
        defaultOverallOpacity = Clamp(FirstNonNil(policy.defaultOverallOpacity, policy.overallOpacity), 0, 1, 0.94),
        defaultBackgroundOpacity = Clamp(FirstNonNil(policy.defaultBackgroundOpacity, policy.backgroundOpacity), 0, 1, 1.0),
        defaultTextOpacity = Clamp(FirstNonNil(policy.defaultTextOpacity, policy.textOpacity), 0, 1, 1.0),
        minFontScale = Clamp(policy.minFontScale, 0.50, 2.00, 0.75),
        maxFontScale = Clamp(policy.maxFontScale, 0.50, 2.00, 1.50),
        defaultFontScale = Clamp(FirstNonNil(policy.defaultFontScale, policy.fontScale), 0.50, 2.00, 1.0),
        defaultMinimized = policy.defaultMinimized == true,
        defaultLocked = policy.defaultLocked == true,
    }
end

function F:NormalizeState(value, policy)
    value = type(value) == "table" and value or {}
    local p = ReadPolicy(policy)
    if p.maxWidth ~= nil then p.maxWidth = math.max(p.minWidth, p.maxWidth) end
    if p.maxHeight ~= nil then p.maxHeight = math.max(p.minHeight, p.maxHeight) end
    if p.maxFontScale < p.minFontScale then p.minFontScale, p.maxFontScale = p.maxFontScale, p.minFontScale end
    p.defaultFontScale = Clamp(p.defaultFontScale, p.minFontScale, p.maxFontScale, 1.0)

    local moved = value.userMoved == true
    local free = moved and tostring(value.coordinateSpace or "") == "logical-free-v2"
        and tonumber(value.x) ~= nil and tonumber(value.y) ~= nil
    local overall = tonumber(value.overallOpacity)
    if overall == nil then overall = tonumber(value.opacity) end

    return {
        width = Clamp(value.width, p.minWidth, p.maxWidth, p.defaultWidth),
        height = Clamp(value.height, p.minHeight, p.maxHeight, p.defaultHeight),
        minimized = value.minimized == true or (value.minimized == nil and p.defaultMinimized),
        locked = value.locked == true or (value.locked == nil and p.defaultLocked),
        overallOpacity = Clamp(overall, 0, 1, p.defaultOverallOpacity),
        backgroundOpacity = Clamp(value.backgroundOpacity, 0, 1, p.defaultBackgroundOpacity),
        textOpacity = Clamp(value.textOpacity, 0, 1, p.defaultTextOpacity),
        fontScale = Clamp(value.fontScale, p.minFontScale, p.maxFontScale, p.defaultFontScale),
        userMoved = moved,
        x = free and tonumber(value.x) or nil,
        y = free and tonumber(value.y) or nil,
        anchorH = moved and not free and (tostring(value.anchorH or "") == "RIGHT" and "RIGHT" or "LEFT") or nil,
        anchorV = moved and not free and (tostring(value.anchorV or "") == "BOTTOM" and "BOTTOM" or "TOP") or nil,
        offsetX = moved and not free and math.max(0, tonumber(value.offsetX) or 0) or nil,
        offsetY = moved and not free and math.max(0, tonumber(value.offsetY) or 0) or nil,
        coordinateSpace = moved and (free and "logical-free-v2" or "logical-edge-v1") or nil,
        savedUiScale = moved and tonumber(value.savedUiScale) or nil,
        savedLogicalWidth = free and tonumber(value.savedLogicalWidth) or nil,
        savedLogicalHeight = free and tonumber(value.savedLogicalHeight) or nil,
        normalizedCenterX = free and tonumber(value.normalizedCenterX) or nil,
        normalizedCenterY = free and tonumber(value.normalizedCenterY) or nil,
    }
end

-- 维护（viewport-recovery-1）：NormalizeState 是现有持久化指纹契约，保持原函数不变。
-- UI 只读必须用分离副本；原 Read 在没有 setter 时直接补齐 Store，可能污染验签/默认 intent。
-- 以下仅用于运行时：过滤异常数、兼容未带 userMoved 的早期 xy/edge，不保存任何新字段。
function F:ReadRuntimeState(value, policy)
    value = type(value) == "table" and value or {}
    local copy = {}
    for k,v in pairs(value) do copy[k]=v end
    for _,key in ipairs({"width","height","x","y","offsetX","offsetY","savedUiScale","savedLogicalWidth","savedLogicalHeight",
        "normalizedCenterX","normalizedCenterY","overallOpacity","backgroundOpacity","textOpacity","fontScale"}) do
        local n=tonumber(copy[key])
        if n==nil or n~=n or n==math.huge or n==-math.huge then copy[key]=nil else copy[key]=n end
    end
    if value.userMoved == nil and (copy.x ~= nil and copy.y ~= nil or value.anchorH ~= nil or value.anchorV ~= nil) then copy.userMoved=true end
    if copy.x ~= nil and copy.y ~= nil and copy.coordinateSpace == nil then copy.coordinateSpace="logical-free-v2" end
    return self:NormalizeState(copy,policy)
end

function F:ApplyNormalizedState(target, normalized)
    if type(target) ~= "table" or type(normalized) ~= "table" then return false end
    for _, key in ipairs(STATE_KEYS) do target[key] = normalized[key] end
    return true
end

function F:ResetState(target, policy, options)
    if type(target) ~= "table" then return false end
    options = type(options) == "table" and options or {}
    local keepLocked = options.preserveLocked ~= false and target.locked == true
    local normalized = self:NormalizeState(nil, policy)
    if keepLocked then normalized.locked = true end
    self:ApplyNormalizedState(target, normalized)
    return true, target
end

local function PersistSpec(spec, reason)
    F.metrics.stateWrites = (tonumber(F.metrics.stateWrites) or 0) + 1
    -- 维护（2026-09-16，geometry-edge-durability-1）：拖动/缩放结束属于低频用户事务边沿。
    -- 位置若仍等默认 250ms Dirty 窗口，紧接退出客户端时可能只移动了 Native 却没来得及进入
    -- 持久化调度。geometry 使用 delay=0 只推进已有 Persistence scheduler，不增加 Tick；透明度/
    -- 字体等连续调整仍保留去抖，避免高频写入。
    local delay = tostring(reason or "") == "geometry" and 0 or math.max(0, tonumber(spec.persistDelayMs) or 250)
    local ok, err = SafeCall(spec.persist, tostring(reason or "state"), delay)
    if ok ~= true then
        F.metrics.failures = (tonumber(F.metrics.failures) or 0) + 1
        return false, err
    end
    return true
end

function F:CreateStateAdapter(spec)
    spec = type(spec) == "table" and spec or {}
    local policy = spec.statePolicy or spec.sizePolicy or {}

    local function Read()
        local value = type(spec.getState) == "function" and spec.getState() or spec.state
        if type(value) ~= "table" then return nil end
        return F:ReadRuntimeState(value, policy)
    end

    local function Commit(value, reason)
        if type(value) ~= "table" then return false, "floating surface state unavailable" end
        -- 维护：只读不再原地归一化；显式 mutation 才将副本提交回 Feature-owned Store。
        if type(spec.setState) ~= "function" then
            local target=type(spec.getState)=="function" and spec.getState() or spec.state
            return F:ApplyNormalizedState(target,F:NormalizeState(value,policy))
        end
        local ok, result, err = xpcall(function()
            return spec.setState(F:NormalizeState(value, policy), tostring(reason or "state"))
        end, S.SafeTraceback)
        if ok ~= true then return false, tostring(result or "floating state commit failed") end
        if result == false then return false, tostring(err or "floating state commit rejected") end
        return true
    end

    -- 维护：Adapter 与已创建 Surface 采用同样的原始快照回滚；失败不能补默认键改变 fingerprint。
    local function RawSnapshot()
        local raw=type(spec.getState)=="function" and spec.getState() or spec.state
        local before={};if type(raw)=="table" then for _,key in ipairs(STATE_KEYS)do before[key]=raw[key] end end
        return before
    end
    local function RestoreRaw(value,reason)
        if type(spec.setState)=="function" then return pcall(spec.setState,value,reason) end
        local raw=type(spec.getState)=="function" and spec.getState() or spec.state
        return F:ApplyNormalizedState(raw,value)
    end

    local function State()
        return Read()
    end

    local function Mutate(reason, fn, persist)
        local state = State()
        if state == nil then return false, "floating surface state unavailable" end
        local before = RawSnapshot()
        fn(state)
        local committed, commitErr = Commit(state, reason)
        if committed ~= true then return false, commitErr end
        if persist == false then return true end
        local saved, saveErr = PersistSpec(spec, reason)
        if saved ~= true then
            RestoreRaw(before, tostring(reason or "state") .. ":rollback")
            return false, saveErr
        end
        return true
    end

    return {
        getLocked = function() local s = State(); return s ~= nil and s.locked == true end,
        setLocked = function(value, persist) return Mutate("locked", function(s) s.locked = value == true end, persist) end,
        getMinimized = function() local s = State(); return s ~= nil and s.minimized == true end,
        setMinimized = function(value, persist) return Mutate("minimized", function(s) s.minimized = value == true end, persist) end,
        getOverallOpacity = function() local s = State(); return s and tonumber(s.overallOpacity) or 0.94 end,
        setOverallOpacity = function(value, persist) return Mutate("overall_opacity", function(s) s.overallOpacity = Clamp(value, 0, 1, s.overallOpacity or 0.94) end, persist) end,
        getOpacity = function() local s = State(); return s and tonumber(s.overallOpacity) or 0.94 end,
        setOpacity = function(value, persist) return Mutate("overall_opacity", function(s) s.overallOpacity = Clamp(value, 0, 1, s.overallOpacity or 0.94) end, persist) end,
        getBackgroundOpacity = function() local s = State(); return s and tonumber(s.backgroundOpacity) or 1.0 end,
        setBackgroundOpacity = function(value, persist) return Mutate("background_opacity", function(s) s.backgroundOpacity = Clamp(value, 0, 1, s.backgroundOpacity or 1.0) end, persist) end,
        getTextOpacity = function() local s = State(); return s and tonumber(s.textOpacity) or 1.0 end,
        setTextOpacity = function(value, persist) return Mutate("text_opacity", function(s) s.textOpacity = Clamp(value, 0, 1, s.textOpacity or 1.0) end, persist) end,
        getFontScale = function() local s = State(); return s and tonumber(s.fontScale) or ReadPolicy(policy).defaultFontScale end,
        setFontScale = function(value, persist)
            local p = ReadPolicy(policy)
            if p.maxFontScale < p.minFontScale then p.minFontScale, p.maxFontScale = p.maxFontScale, p.minFontScale end
            return Mutate("font_scale", function(s) s.fontScale = Clamp(value, p.minFontScale, p.maxFontScale, s.fontScale or p.defaultFontScale) end, persist)
        end,
        resetLayout = function()
            local state = State()
            if state == nil then return false, "floating surface state unavailable" end
            local before = RawSnapshot()
            F:ResetState(state, policy, { preserveLocked = spec.preserveLockedOnReset ~= false })
            local committed, commitErr = Commit(state, "layout_reset")
            if committed ~= true then return false, commitErr end
            local saved, saveErr = PersistSpec(spec, "layout_reset")
            if saved ~= true then
                RestoreRaw(before, "layout_reset:rollback")
                return false, saveErr
            end
            return true
        end,
    }
end

local function ResolveDefaultPosition(spec, context, width, height)
    local safeLeft = tonumber(context.safeLeft) or 0
    local safeTop = tonumber(context.safeTop) or 0
    local safeRight = tonumber(context.safeRight) or 0
    local safeBottom = tonumber(context.safeBottom) or 0
    local logicalWidth = tonumber(context.logicalWidth) or 1024
    local logicalHeight = tonumber(context.logicalHeight) or 768
    if type(spec.defaultPosition) == "function" then
        local ok, x, y = pcall(spec.defaultPosition, context, width, height)
        if ok and tonumber(x) ~= nil and tonumber(y) ~= nil then return tonumber(x), tonumber(y) end
    end
    local placement = tostring(spec.defaultPlacement or "center")
    if placement == "top-right" then
        return logicalWidth - safeRight - width, safeTop
    elseif placement == "top-left" then
        return safeLeft, safeTop
    elseif placement == "bottom-right" then
        return logicalWidth - safeRight - width, logicalHeight - safeBottom - height
    elseif placement == "bottom-left" then
        return safeLeft, logicalHeight - safeBottom - height
    elseif placement == "safe-spawn" and S.Layout ~= nil and type(S.Layout.GetSafeSpawn) == "function" then
        return S.Layout:GetSafeSpawn(tonumber(spec.spawnIndex) or 1, width, height, spec.spawnOptions)
    end
    return safeLeft + (logicalWidth - safeLeft - safeRight - width) * 0.5,
        safeTop + (logicalHeight - safeTop - safeBottom - height) * 0.5
end

function F:Create(spec)
    spec = type(spec) == "table" and spec or {}
    local id = tostring(spec.id or "")
    local owner = tostring(spec.owner or "")
    if id == "" or owner == "" then return nil, "floating surface identity required" end
    if self.instances[id] ~= nil then return self.instances[id] end

    local policy = ReadPolicy(spec.statePolicy or spec.sizePolicy)
    local state = type(spec.getState) == "function" and spec.getState() or spec.state
    if type(state) ~= "table" then return nil, "floating surface state unavailable" end
    state = self:ReadRuntimeState(state, policy)

    local context = S.Layout and S.Layout:GetContext(true) or { logicalWidth = 1024, logicalHeight = 768, addonScale = 1 }
    local scale = spec.scaleWithAddon == false and 1 or math.max(0.01, tonumber(context.addonScale) or 1)
    local width = math.max(1, tonumber(state.width) or policy.defaultWidth) * scale
    local height = math.max(1, tonumber(state.height) or policy.defaultHeight) * scale
    local defaultX, defaultY = ResolveDefaultPosition(spec, context, math.min(width,context.usableWidth),math.min(height,context.usableHeight))
    local x,y,meta
    -- 维护：消费 ResolvePlacement 的全部四个几何返回值，过去只取 x/y，尺寸 fit 被丢弃。
    x,y,width,height,meta = S.Layout:ResolvePlacement(state.userMoved and state or nil,width,height,defaultX,defaultY,
        {mode=tostring(spec.boundaryMode or "free"),topLevel=true,topReachHeight=tonumber(spec.titleHeight) or 24})

    local surface = {
        id = id, owner = owner, spec = spec, statePolicy = policy, visible = false,
        snapId = tostring(spec.snapId or ("floating:" .. id)),
    }

    local function CurrentState()
        local target = type(spec.getState) == "function" and spec.getState() or spec.state
        if type(target) ~= "table" then return nil end
        return F:ReadRuntimeState(target, policy)
    end

    local function CommitState(reason, candidate, persist)
        local rawState = type(spec.getState) == "function" and spec.getState() or spec.state
        if type(rawState) ~= "table" then return false, "floating surface state unavailable" end
        -- 维护：失败回滚保留原始字段/缺失键；不能用补默认后的副本覆盖旧 Store。
        local previous = {}
        for _,key in ipairs(STATE_KEYS) do previous[key]=rawState[key] end
        local nextState = type(candidate) == "table" and F:NormalizeState(candidate, policy) or F:NormalizeState(rawState, policy)
        if type(nextState) ~= "table" then return false, "floating surface state unavailable" end

        if type(spec.setState) == "function" then
            local callOk, result, resultErr = xpcall(function()
                return spec.setState(nextState, tostring(reason or "state"))
            end, S.SafeTraceback)
            if callOk ~= true then return false, tostring(result or "floating state commit failed") end
            if result == false then return false, tostring(resultErr or "floating state commit rejected") end
        else
            F:ApplyNormalizedState(rawState, nextState)
        end

        if persist ~= false then
            local ok, err = PersistSpec(spec, reason)
            if ok ~= true then
                if type(spec.setState) == "function" then
                    pcall(spec.setState, previous, tostring(reason or "state") .. ":rollback")
                else
                    F:ApplyNormalizedState(rawState, previous)
                end
                return false, err
            end
        end
        SafeCall(spec.onStateChanged, surface, CurrentState(), tostring(reason or "state"))
        return true
    end

    local function Save(reason, candidate) return CommitState(reason, candidate, true) end
    local function Stage(reason, candidate) return CommitState(reason, candidate, false) end

    local shell, shellErr = UI:CreateWindowShell({
        id = id,
        owner = owner,
        title = tostring(spec.title or id),
        status = tostring(spec.status or ""),
        layerRole = "floating",
        width = width,
        height = height,
        minWidth = policy.minWidth,
        minHeight = policy.minHeight,
        maxWidth = policy.maxWidth,
        maxHeight = policy.maxHeight,
        resizable = spec.resizable ~= false,
        movable = spec.movable ~= false,
        footer = spec.footer ~= false,
        closeButton = spec.closeButton ~= false,
        -- Shared HUD chrome owns the appearance editor. Every FloatingSurface
        -- gets the same title-bar entry unless a rare surface explicitly opts
        -- out; feature widgets must not re-invent opacity/font controls.
        appearanceControls = spec.appearanceControls ~= false,
        appearancePanelWidth = tonumber(spec.appearancePanelWidth),
        -- Floating HUD surfaces use the compact chrome profile. Normal state is
        -- intentionally shorter than application dialogs; compact minimization
        -- collapses the whole chrome into a draggable square restore button.
        compactChrome = true,
        minimizedSize = tonumber(spec.minimizedSize) or 30,
        titleHeight = tonumber(spec.titleHeight) or 24,
        titleFontSize = tonumber(spec.titleFontSize) or 11,
        titlePadding = tonumber(spec.titlePadding) or 2,
        titleGap = tonumber(spec.titleGap) or 3,
        titleControlWidth = tonumber(spec.titleControlWidth) or 22,
        footerHeight = tonumber(spec.footerHeight) or 22,
        footerPadding = tonumber(spec.footerPadding) or 3,
        padding = tonumber(spec.padding) or 6,
        gap = tonumber(spec.gap) or 4,
        minimized = state.minimized == true,
        minimizeMode = tostring(spec.minimizeMode or "compact"),
        locked = state.locked == true,
        opacity = state.overallOpacity,
        backgroundOpacity = state.backgroundOpacity,
        textOpacity = state.textOpacity,
        fontScale = state.fontScale,
        boundaryMode = tostring(spec.boundaryMode or "free"),
        placementManagedExternally = true,
        scaleWithAddon = spec.scaleWithAddon ~= false,
        initialRect = { x = x, y = y, width = width, height = height },
        allowCloseVeto = spec.allowCloseVeto == true,
        onAppearanceReset = function() return surface:ResetLayout(true) end,
        onClose = function(_, reason)
            if type(spec.onClose) == "function" then return spec.onClose(surface, tostring(reason or "close")) end
            return true
        end,
        onClosed = function(_, reason)
            -- The native chrome already hid the window before this runs. Keep
            -- the Surface's own logical visibility in step with the native
            -- window, otherwise `ResetLayout`/responsive reflow would believe
            -- a closed window is still on screen.
            surface.visible = false
            F.metrics.closedCallbacks = (tonumber(F.metrics.closedCallbacks) or 0) + 1
            if type(spec.onClosed) == "function" then return spec.onClosed(surface, tostring(reason or "close")) end
            return true
        end,
        onStateChanged = function(_, snapshot)
            local current = CurrentState()
            if current == nil then return false end
            local target = F:NormalizeState(current, policy)
            local reason = tostring(snapshot and snapshot.reason or "state")
            target.minimized = snapshot.minimized == true
            target.locked = snapshot.locked == true
            target.overallOpacity = Clamp(snapshot.overallOpacity, 0, 1, FirstNonNil(target.overallOpacity, policy.defaultOverallOpacity))
            target.backgroundOpacity = Clamp(snapshot.backgroundOpacity, 0, 1, FirstNonNil(target.backgroundOpacity, policy.defaultBackgroundOpacity))
            target.textOpacity = Clamp(snapshot.textOpacity, 0, 1, FirstNonNil(target.textOpacity, policy.defaultTextOpacity))
            target.fontScale = Clamp(snapshot.fontScale, policy.minFontScale, policy.maxFontScale, FirstNonNil(target.fontScale, policy.defaultFontScale))

            if reason == "geometry" then
                -- 维护（2026-09-16，floating-committed-geometry-1）：WindowShell 传入的 snapshot
                -- 是 Windowing 事务提交后的唯一几何事实。旧代码在这里再次 GetLogicalRect，正是钓鱼
                -- 等悬浮窗重登漂移的来源。若启用吸附，CommitScreenSnap 也消费同一矩形并把解析后的
                -- x/y 返回，再以 StorePlacementRect 写入原 Feature-owned widgetWindow。没有新增坐标 Store。
                local placementX = tonumber(snapshot.x) or 0
                local placementY = tonumber(snapshot.y) or 0
                local placementW = math.max(1, tonumber(snapshot.width) or tonumber(snapshot.normalWidth) or width)
                local placementH = math.max(1, tonumber(snapshot.height) or tonumber(snapshot.normalHeight) or height)
                if spec.snappable == true and tostring(snapshot.geometryKind or "") == "drag" and type(UI.CommitScreenSnap) == "function" then
                    local snapEnabled = spec.snapEnabled
                    if type(spec.snapEnabledProvider) == "function" then
                        local ok, value = pcall(spec.snapEnabledProvider)
                        snapEnabled = ok and value == true
                    end
                    local committed, resolvedX, resolvedY, snapped = UI:CommitScreenSnap(surface.snapId, surface.shell.window, {
                        owner = owner,
                        enabled = snapEnabled ~= false,
                        group = tostring(spec.snapGroup or "hud_panels"),
                        kind = tostring(spec.snapKind or "window"),
                        distance = tonumber(spec.snapDistance),
                        gap = tonumber(spec.snapGap),
                        x = placementX, y = placementY, width = placementW, height = placementH,
                    })
                    -- 维护：拒绝的吸附事务不得保存成成功几何；原 Store 仍是 authoritative intent。
                    if committed ~= true then return false,"snap_geometry_rejected" end
                    if committed == true then
                        placementX = tonumber(resolvedX) or placementX
                        placementY = tonumber(resolvedY) or placementY
                    end
                    if snapped == true then F.metrics.snapCommits = (tonumber(F.metrics.snapCommits) or 0) + 1 end
                end
                local liveContext = S.Layout:GetContext()
                local liveScale = spec.scaleWithAddon == false and 1 or math.max(0.01, tonumber(liveContext.addonScale) or 1)
                -- 维护：拖动 compact/低分辨率拟合窗只更新位置，不永久缩小 preferred size。
                -- addonScale 只在设计尺寸入/出边界一次；uiScale 不参与本次已校准逻辑坐标。
                if tostring(snapshot.geometryKind) == "resize" then
                    target.width = math.max(policy.minWidth, (tonumber(snapshot.normalWidth) or placementW) / liveScale)
                    target.height = math.max(policy.minHeight, (tonumber(snapshot.normalHeight) or placementH) / liveScale)
                end
                if type(S.Layout.StorePlacementRect) == "function" then
                    S.Layout:StorePlacementRect(target, placementX, placementY, placementW, placementH, { mode = tostring(spec.boundaryMode or "free") })
                elseif type(S.Layout.StorePlacement) == "function" then
                    -- Compatibility only for a partially-upgraded development tree; release toc always loads StorePlacementRect.
                    S.Layout:StorePlacement(target, surface.shell.window, { mode = tostring(spec.boundaryMode or "free") })
                end
                target.userMoved = true
                F.metrics.geometryCommits = (tonumber(F.metrics.geometryCommits) or 0) + 1
            end
            local saved = Save(reason, target)
            -- 维护：用户提交后的元数据立即进入冷诊断快照；不能等下次重排仍报告上次保存的中心。
            -- 只复制标量，不追加历史，不读取磁盘；迁移本身仍不会触发 Save。
            if saved==true and reason=="geometry" and surface.shell and surface.shell.placementInfo then
                local info=surface.shell.placementInfo
                for _,key in ipairs({"savedUiScale","savedLogicalWidth","savedLogicalHeight","normalizedCenterX","normalizedCenterY"})do info[key]=target[key] end
                info.lastUserGeometryKind=tostring(snapshot.geometryKind or "")
            end
            return saved == true
        end,
    })
    if shell == nil then
        self.metrics.failures = (tonumber(self.metrics.failures) or 0) + 1
        return nil, shellErr or "floating window shell create failed"
    end
    surface.shell = shell
    surface.window = shell.window
    surface.windowController = shell.windowController
    shell.placementInfo = meta
    shell.placementDelegate = function(changed,reason) return surface:ApplyLayout(changed,reason) end
    shell.resetDelegate = function(persist) return surface:ResetLayout(persist) end
    function surface:GetPlacementDiagnostics() return self.shell:GetPlacementDiagnostics() end

    if spec.snappable == true and type(UI.RegisterScreenSnap) == "function" then
        UI:RegisterScreenSnap(surface.snapId, shell.window, {
            snapGroup = tostring(spec.snapGroup or "hud_panels"),
            snapKind = tostring(spec.snapKind or "window"),
            snapEnabled = spec.snapEnabled ~= false,
            snapEnabledProvider = spec.snapEnabledProvider,
            snapDistance = tonumber(spec.snapDistance),
            snapGap = tonumber(spec.snapGap) or 0,
        })
    end

    function surface:GetState() return CurrentState() end
    -- Floating feature content is RSUI presentation, not raw Native UI. Return
    -- the logical shell body so all descendants participate in the shared
    -- Measure/Arrange/Release tree. Keep an explicit Native accessor only for
    -- rare adapter-level use that genuinely needs the engine widget.
    function surface:GetContentRoot()
        if type(self.shell.GetContentComponent) == "function" then return self.shell:GetContentComponent() end
        return self.shell:GetContentRoot()
    end
    function surface:GetNativeContentRoot()
        if type(self.shell.GetNativeContentRoot) == "function" then return self.shell:GetNativeContentRoot() end
        return self.shell:GetContentRoot()
    end
    function surface:GetWindow() return self.shell:GetWindow() end
    function surface:SetStatus(text, tone) return self.shell:SetStatus(text, tone) end
    function surface:IsLocked() return self.shell:IsLocked() end
    function surface:IsMinimized() return self.shell.minimized == true end

    function surface:ApplyLayout(fromMetricsChange, reason, stateOverride)
        local target = stateOverride or CurrentState()
        if target == nil or self.shell == nil then return false end
        if self.windowController ~= nil and self.windowController:IsInteracting() == true then
            -- 维护：普通内容重排可能来自高频刷新，不得取消手势或采样 metrics。
            if fromMetricsChange == true then self.windowController.pendingPlacement=true end
            return true
        end
        local live = S.Layout:GetContext(reason == "show" or reason == "explicit_reset")
        local liveScale = spec.scaleWithAddon == false and 1 or math.max(0.01, tonumber(live.addonScale) or 1)
        local pw = math.max(policy.minWidth, tonumber(target.width) or policy.defaultWidth) * liveScale
        local ph = math.max(policy.minHeight, tonumber(target.height) or policy.defaultHeight) * liveScale
        local w,h = math.min(pw,live.usableWidth),math.min(ph,live.usableHeight)
        local compact = target.minimized == true and self.shell.minimizeMode == "compact"
        local placementW,placementH = compact and self.shell.minimizedWidth or pw,compact and self.shell.minimizedSize or ph
        local dx,dy = ResolveDefaultPosition(spec,live,compact and placementW or w,compact and placementH or h)
        local px,py,_,_,info = S.Layout:ResolvePlacement(target.userMoved and target or nil,placementW,placementH,dx,dy,
            {mode=tostring(spec.boundaryMode or "free"),topLevel=true,topReachHeight=tonumber(spec.titleHeight) or 24,reason=reason})
        info.preferredNormalWidth,info.preferredNormalHeight = pw,ph
        local previousMin = self.shell.minimized
        self.shell.minimized = target.minimized == true
        local placed,placeErr = self.shell:ApplyPlacementRect(px,py,w,h,info,fromMetricsChange==true or reason=="explicit_reset" or reason=="show")
        if placed ~= true then self.shell.minimized=previousMin;return false,placeErr end
        local lockOk, lockErr = self.shell:SetLocked(target.locked == true, false)
        if lockOk ~= true then return false, lockErr or "floating_lock_apply_failed" end
        local overallOk, overallErr = self.shell:SetOverallOpacity(target.overallOpacity, false)
        if overallOk ~= true then return false, overallErr or "floating_overall_opacity_apply_failed" end
        local backgroundOk, backgroundErr = self.shell:SetBackgroundOpacity(target.backgroundOpacity, false)
        if backgroundOk ~= true then return false, backgroundErr or "floating_background_opacity_apply_failed" end
        local textOk, textErr = self.shell:SetTextOpacity(target.textOpacity, false)
        if textOk ~= true then return false, textErr or "floating_text_opacity_apply_failed" end
        if type(self.shell.SetFontScale) == "function" then
            local fontOk, fontErr = self.shell:SetFontScale(target.fontScale, false)
            if fontOk ~= true then return false, fontErr or "floating_font_scale_apply_failed" end
        end
        if self.shell.minimized ~= (target.minimized == true) then
            local minimizeOk, minimizeErr = self.shell:SetMinimized(target.minimized == true, false)
            if minimizeOk ~= true then return false, minimizeErr or "floating_minimize_apply_failed" end
        end
        self.shell.minimizeButton:SetText(self.shell.minimized and "+" or "—")
        if fromMetricsChange == true then F.metrics.responsiveLayouts = (tonumber(F.metrics.responsiveLayouts) or 0) + 1 end
        return true
    end

    function surface:Show(visible)
        local desired = visible ~= false
        -- 维护：Shell Show 调 placementDelegate，一次 fresh sample 即可，不重复采样/重放。
        local shown, showErr = self.shell:Show(desired)
        if shown ~= true then return false, showErr end
        self.visible = desired
        return true
    end

    function surface:SetLocked(value, persist)
        local target = CurrentState(); if target == nil then return false end
        local previous = target.locked == true
        local nextValue = value == true
        if previous == nextValue and self.shell:IsLocked() == nextValue then return true, false end
        local shellOk, shellErr = self.shell:SetLocked(nextValue, false)
        if shellOk ~= true then return false, shellErr end
        local candidate = F:NormalizeState(target, policy); candidate.locked = nextValue
        local stateOk, stateErr = persist ~= false and Save("locked", candidate) or Stage("locked", candidate)
        if stateOk ~= true then self.shell:SetLocked(previous, false); return false, stateErr end
        F.metrics.lockChanges = (tonumber(F.metrics.lockChanges) or 0) + 1
        return true, true
    end

    function surface:SetMinimized(value, persist)
        local target = CurrentState(); if target == nil then return false end
        local previous = target.minimized == true
        local nextValue = value == true
        if previous == nextValue and self.shell.minimized == nextValue then return true, false end
        local shellOk, shellErr = self.shell:SetMinimized(nextValue, false)
        if shellOk ~= true then return false, shellErr end
        local candidate = F:NormalizeState(target, policy); candidate.minimized = nextValue
        local stateOk, stateErr = persist ~= false and Save("minimized", candidate) or Stage("minimized", candidate)
        if stateOk ~= true then self.shell:SetMinimized(previous, false); return false, stateErr end
        F.metrics.minimizeChanges = (tonumber(F.metrics.minimizeChanges) or 0) + 1
        return true, true
    end

    function surface:SetOverallOpacity(value, persist)
        local target = CurrentState(); if target == nil then return false end
        local previous = tonumber(target.overallOpacity) or policy.defaultOverallOpacity
        local nextValue = Clamp(value, 0, 1, FirstNonNil(target.overallOpacity, policy.defaultOverallOpacity))
        if math.abs(nextValue - previous) <= 0.0001 then return true, nextValue, false end
        local shellOk, shellErr = self.shell:SetOverallOpacity(nextValue, false)
        if shellOk ~= true then return false, shellErr end
        local candidate = F:NormalizeState(target, policy); candidate.overallOpacity = nextValue
        local stateOk, stateErr = persist ~= false and Save("overall_opacity", candidate) or Stage("overall_opacity", candidate)
        if stateOk ~= true then self.shell:SetOverallOpacity(previous, false); return false, stateErr end
        F.metrics.appearanceChanges = (tonumber(F.metrics.appearanceChanges) or 0) + 1
        return true, nextValue, true
    end

    function surface:GetOverallOpacity() local s = CurrentState(); if s ~= nil and s.overallOpacity ~= nil then return s.overallOpacity end; return policy.defaultOverallOpacity end
    function surface:SetOpacity(value, persist) return self:SetOverallOpacity(value, persist) end
    function surface:GetOpacity() return self:GetOverallOpacity() end

    function surface:SetBackgroundOpacity(value, persist)
        local target = CurrentState(); if target == nil then return false end
        local previous = tonumber(target.backgroundOpacity) or policy.defaultBackgroundOpacity
        local nextValue = Clamp(value, 0, 1, FirstNonNil(target.backgroundOpacity, policy.defaultBackgroundOpacity))
        if math.abs(nextValue - previous) <= 0.0001 then return true, nextValue, false end
        local shellOk, shellErr = self.shell:SetBackgroundOpacity(nextValue, false)
        if shellOk ~= true then return false, shellErr end
        local candidate = F:NormalizeState(target, policy); candidate.backgroundOpacity = nextValue
        local stateOk, stateErr = persist ~= false and Save("background_opacity", candidate) or Stage("background_opacity", candidate)
        if stateOk ~= true then self.shell:SetBackgroundOpacity(previous, false); return false, stateErr end
        F.metrics.appearanceChanges = (tonumber(F.metrics.appearanceChanges) or 0) + 1
        return true, nextValue, true
    end

    function surface:GetBackgroundOpacity() local s = CurrentState(); if s ~= nil and s.backgroundOpacity ~= nil then return s.backgroundOpacity end; return policy.defaultBackgroundOpacity end

    function surface:SetTextOpacity(value, persist)
        local target = CurrentState(); if target == nil then return false end
        local previous = tonumber(target.textOpacity) or policy.defaultTextOpacity
        local nextValue = Clamp(value, 0, 1, FirstNonNil(target.textOpacity, policy.defaultTextOpacity))
        if math.abs(nextValue - previous) <= 0.0001 then return true, nextValue, false end
        local shellOk, shellErr = self.shell:SetTextOpacity(nextValue, false)
        if shellOk ~= true then return false, shellErr end
        local candidate = F:NormalizeState(target, policy); candidate.textOpacity = nextValue
        local stateOk, stateErr = persist ~= false and Save("text_opacity", candidate) or Stage("text_opacity", candidate)
        if stateOk ~= true then self.shell:SetTextOpacity(previous, false); return false, stateErr end
        F.metrics.appearanceChanges = (tonumber(F.metrics.appearanceChanges) or 0) + 1
        return true, nextValue, true
    end

    function surface:GetTextOpacity() local s = CurrentState(); if s ~= nil and s.textOpacity ~= nil then return s.textOpacity end; return policy.defaultTextOpacity end

    function surface:SetFontScale(value, persist)
        local target = CurrentState(); if target == nil then return false end
        local previous = tonumber(target.fontScale) or policy.defaultFontScale
        local nextValue = Clamp(value, policy.minFontScale, policy.maxFontScale, FirstNonNil(target.fontScale, policy.defaultFontScale))
        if math.abs(nextValue - previous) <= 0.0001 then return true, nextValue, false end
        if type(self.shell.SetFontScale) ~= "function" then return false, "floating_font_scale_contract_unavailable" end
        local shellOk, shellErr = self.shell:SetFontScale(nextValue, false)
        if shellOk ~= true then return false, shellErr end
        local candidate = F:NormalizeState(target, policy); candidate.fontScale = nextValue
        local stateOk, stateErr = persist ~= false and Save("font_scale", candidate) or Stage("font_scale", candidate)
        if stateOk ~= true then self.shell:SetFontScale(previous, false); return false, stateErr end
        F.metrics.appearanceChanges = (tonumber(F.metrics.appearanceChanges) or 0) + 1
        return true, nextValue, true
    end

    function surface:GetFontScale() local s = CurrentState(); if s ~= nil and s.fontScale ~= nil then return s.fontScale end; return policy.defaultFontScale end

    function surface:SetSize(designWidth, designHeight, persist)
        local target = CurrentState(); if target == nil then return false end
        local before = F:NormalizeState(target, policy)
        local nextWidth = Clamp(designWidth, policy.minWidth, policy.maxWidth, target.width or policy.defaultWidth)
        local nextHeight = Clamp(designHeight, policy.minHeight, policy.maxHeight, target.height or policy.defaultHeight)
        local changed = math.abs(nextWidth - (tonumber(target.width) or nextWidth)) > 0.0001
            or math.abs(nextHeight - (tonumber(target.height) or nextHeight)) > 0.0001
            or target.minimized == true or self.shell.minimized == true
        if changed ~= true then return true, target.width, target.height, false end

        local candidate = F:NormalizeState(target, policy)
        candidate.width, candidate.height, candidate.minimized = nextWidth, nextHeight, false
        if self.shell.minimized == true then
            local restoreOk, restoreErr = self.shell:SetMinimized(false, false)
            if restoreOk ~= true then return false, restoreErr end
        end
        local stateOk, stateErr = persist ~= false and Save("size", candidate) or Stage("size", candidate)
        if stateOk ~= true then
            if before.minimized == true then self.shell:SetMinimized(true, false) end
            return false, stateErr
        end
        local layoutOk, layoutErr = self:ApplyLayout(false)
        if layoutOk ~= true then
            if persist ~= false then Save("size_rollback", before) else Stage("size_rollback", before) end
            self:ApplyLayout(false)
            return false, layoutErr or "floating_size_layout_failed"
        end
        return true, nextWidth, nextHeight, true
    end

    function surface:ResetLayout(persist)
        local target = CurrentState(); if target == nil then return false end
        -- 维护：硬恢复先 Native 再持久化；清除 placement intent 的完整字段和 minimized，
        -- 当前 viewport 下重算默认。异常旧 xy/metadata 无法通过缓存再次把窗口拖回屏幕外。
        -- 失败不改变 Store；仅用户明确 Reset 才正常提交 schema 原有字段。
        S.Layout:GetContext(true)
        if self.windowController then self.windowController:CancelInteraction() end
        local before = F:NormalizeState(target,policy)
        local candidate = F:NormalizeState(target,policy)
        F:ResetState(candidate,policy,{preserveLocked=spec.preserveLockedOnReset~=false})
        candidate.minimized=false
        local visible = self.visible == true or self.shell.visible == true
        local ok,err = self:ApplyLayout(true,"explicit_reset",candidate)
        if ok ~= true then return false,err end
        if visible then
            if type(UI.InvalidateNativeState)=="function" then UI:InvalidateNativeState(self.window,"visible") end
            local shown,_,showErr = UI:EnsureVisible(self.window,true,owner)
            if shown ~= true then self:ApplyLayout(true,"rollback",before);return false,showErr end
            self.visible,self.shell.visible=true,true
            self.windowController:BringToFront()
        end
        local saved,saveErr
        if persist ~= false then saved,saveErr=Save("layout_reset",candidate) else saved,saveErr=Stage("layout_reset",candidate) end
        if saved ~= true then self:ApplyLayout(true,"rollback",before);return false,saveErr end
        F.metrics.resets=(tonumber(F.metrics.resets) or 0)+1
        return true
    end

    -- Public close entry. Goes through the WindowShell close contract so the
    -- X button and any programmatic close share one chain:
    --   shell:Close -> onClose (veto only when opted in) -> hide -> onClosed.
    function surface:Close(reason)
        F.metrics.closeRequests = (tonumber(F.metrics.closeRequests) or 0) + 1
        local closed, closeErr = self.shell:Close(tostring(reason or "close"))
        if closed ~= true then
            if self.shell.allowCloseVeto == true or (self.shell.spec ~= nil and self.shell.spec.allowCloseVeto == true) then
                F.metrics.closeVetoes = (tonumber(F.metrics.closeVetoes) or 0) + 1
                return false, closeErr or "floating window close vetoed"
            end
            -- fail-open: a veto-less window must never become undismissable
            -- because a business callback failed. Force the visual close and
            -- still run the closed cleanup chain.
            self.visible = false
            self.shell:Show(false)
            if type(spec.onClosed) == "function" then
                F.metrics.closedCallbacks = (tonumber(F.metrics.closedCallbacks) or 0) + 1
                SafeCall(spec.onClosed, surface, tostring(reason or "close"))
            end
        end
        return true
    end

    function surface:Destroy()
        if type(UI.UnregisterScreenSnap) == "function" and spec.snappable == true then UI:UnregisterScreenSnap(self.snapId) end
        F.instances[self.id] = nil
        return self.shell and self.shell:Destroy() or 0
    end

    self.instances[id] = surface
    self.metrics.created = (tonumber(self.metrics.created) or 0) + 1
    return surface
end

function F:GetSnapshot()
    local active = 0
    for _ in pairs(self.instances or {}) do active = active + 1 end
    return {
        version = self.version,
        detachedStateContract = tonumber(self.DetachedStateContractVersion) or 0,
        active = active,
        created = tonumber(self.metrics.created) or 0,
        stateWrites = tonumber(self.metrics.stateWrites) or 0,
        geometryCommits = tonumber(self.metrics.geometryCommits) or 0,
        resets = tonumber(self.metrics.resets) or 0,
        appearanceChanges = tonumber(self.metrics.appearanceChanges) or 0,
        lockChanges = tonumber(self.metrics.lockChanges) or 0,
        minimizeChanges = tonumber(self.metrics.minimizeChanges) or 0,
        responsiveLayouts = tonumber(self.metrics.responsiveLayouts) or 0,
        snapCommits = tonumber(self.metrics.snapCommits) or 0,
        failures = tonumber(self.metrics.failures) or 0,
        closeRequests = tonumber(self.metrics.closeRequests) or 0,
        closeVetoes = tonumber(self.metrics.closeVetoes) or 0,
        closedCallbacks = tonumber(self.metrics.closedCallbacks) or 0,
    }
end

function F:ResetMetrics()
    for key in pairs(self.metrics) do self.metrics[key] = 0 end
    return true
end

function UI:CreateFloatingSurface(spec) return F:Create(spec) end
