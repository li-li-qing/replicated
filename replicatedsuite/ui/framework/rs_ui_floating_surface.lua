-- Replicated Suite · 悬浮窗口状态绑定
-- 作者：Replicated
-- QQ群：1104129461
-- WindowShellV3/Windowing 上的轻量状态与持久化绑定，不新增窗口权威。WindowShell 负责外框，Windowing 负责原生拖动/缩放；
-- FloatingSurface 仅映射位置、大小、最小化、锁定、透明度、字体倍率到 Feature 持久表。
-- 无永久 Tick/OnUpdate；屏幕吸附可选，仅原生拖动提交时判断。
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local UI, RSUI = S.UI, S.RSUI
if type(UI) ~= "table" or type(RSUI) ~= "table" or type(UI.CreateWindowShell) ~= "function" then return end

local generation = tonumber(S.Generation) or 0
if type(RSUI.FloatingSurface) ~= "table" or tonumber(RSUI.FloatingSurface.generation) ~= generation then
    RSUI.FloatingSurface = {
        version = 13,
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
RSUI.FloatingSurface.version = 13
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

-- NormalizeState 参与持久化指纹，不能随 UI 需求改形状。
-- 运行时读取使用副本，过滤异常并兼容早期 xy/edge；直接给 Store 补字段会污染验签和默认位置意图。
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

-- 这些原因只来自外观最终 setter；拖动预览由 NumericField.onPreview 直接写 Native，不进入 Store。
local APPEARANCE_REASONS = { overall_opacity=true, background_opacity=true, text_opacity=true, font_scale=true }
local function PersistSpec(spec, reason)
    F.metrics.stateWrites = (tonumber(F.metrics.stateWrites) or 0) + 1
    -- 拖动、缩放、锁定和最终外观提交都须由 Owner 当场保存并回读。
    -- MarkDirty(0) 只排期，仍可能在立即退出时丢值；连续预览不写盘。
    local immediate=reason=="geometry" or reason=="minimized" or reason=="locked" or reason=="lock" or APPEARANCE_REASONS[reason]==true
    local delay = immediate and 0 or math.max(0, tonumber(spec.persistDelayMs) or 250)
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
        -- 只读不再原地归一化；显式 mutation 才将副本提交回 Feature-owned Store。
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

    -- Adapter 与已创建 Surface 采用同样的原始快照回滚；失败不能补默认键改变 fingerprint。
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

    -- 未创建窗口的设置 Adapter 也可能先 Stage 再 final；回滚基线必须是首个预览前原始字段。
    local stagedAppearance
    local function Mutate(reason, fn, persist)
        local state = State()
        if state == nil then return false, "floating surface state unavailable" end
        local before = persist ~= false and stagedAppearance or RawSnapshot()
        fn(state)
        local committed, commitErr = Commit(state, reason)
        if committed ~= true then return false, commitErr end
        if persist == false then
            if APPEARANCE_REASONS[reason] == true and stagedAppearance == nil then stagedAppearance = before end -- 连续草稿不覆盖已提交基线。
            return true
        end
        local saved, saveErr = PersistSpec(spec, reason)
        if saved ~= true then
            RestoreRaw(before, tostring(reason or "state") .. ":rollback")
            stagedAppearance = nil -- 失败已恢复提交前状态，后续同值重试必须重新走真正保存。
            return false, saveErr
        end
        stagedAppearance = nil -- 保存整个窗口快照成功后，全部外观草稿已成为原 Store 的已提交值。
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
            local before = stagedAppearance or RawSnapshot() -- 默认布局失败也要恢复预览前真实值。
            F:ResetState(state, policy, { preserveLocked = spec.preserveLockedOnReset ~= false })
            local committed, commitErr = Commit(state, "layout_reset")
            if committed ~= true then return false, commitErr end
            local saved, saveErr = PersistSpec(spec, "layout_reset")
            if saved ~= true then
                RestoreRaw(before, "layout_reset:rollback")
                stagedAppearance = nil -- 重置失败不可遗留过期草稿基线。
                return false, saveErr
            end
            stagedAppearance = nil -- 重置成功消费全部暂存外观。
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
    -- 明确为会话状态的设置窗复用 Chrome 偏好保存小锁；不覆盖 Feature/AuxWindow 的持久锁 Authority。
    local sessionLockPreferences
    if spec.persistSessionLock == true then
        sessionLockPreferences = RSUI.WindowPreferences
        if type(sessionLockPreferences) ~= "table" or type(sessionLockPreferences.GetLocked) ~= "function"
            or type(sessionLockPreferences.SetLocked) ~= "function" then return nil, "session_window_lock_preferences_unavailable" end
        state.locked = sessionLockPreferences:GetLocked(id)
    end
    state = self:ReadRuntimeState(state, policy)

    local context = S.Layout and S.Layout:GetContext(true) or { logicalWidth = 1024, logicalHeight = 768, addonScale = 1 }
    local scale = spec.scaleWithAddon == false and 1 or math.max(0.01, tonumber(context.addonScale) or 1)
    local width = math.max(1, tonumber(state.width) or policy.defaultWidth) * scale
    local height = math.max(1, tonumber(state.height) or policy.defaultHeight) * scale
    local initialCompact=state.minimized==true and tostring(spec.minimizeMode or "compact")=="compact"
    local placementW=initialCompact and math.max(136,tonumber(spec.minimizedWidth) or 156) or width
    local placementH=initialCompact and math.max(30,tonumber(spec.minimizedSize) or 30) or height
    if state.minimized and tostring(spec.minimizeMode)=="collapse" then placementH=tonumber(spec.titleHeight) or 24 end
    local defaultX, defaultY = ResolveDefaultPosition(spec, context, math.min(placementW,context.usableWidth),math.min(placementH,context.usableHeight))
    -- 初载按当前可见尺寸定位；normal 尺寸单独拟合，不能把 compact 的尺寸当成展开偏好。
    local x,y,_,_,meta = S.Layout:ResolvePlacement(state.userMoved and state or nil,placementW,placementH,defaultX,defaultY,
        {mode=tostring(spec.boundaryMode or "free"),topLevel=true,topReachHeight=tonumber(spec.titleHeight) or 24})
    width,height=math.min(width,context.usableWidth),math.min(height,context.usableHeight)

    local surface = {
        id = id, owner = owner, spec = spec, statePolicy = policy, visible = false,
        snapId = tostring(spec.snapId or ("floating:" .. id)),
    }

    local function CurrentState()
        local target = type(spec.getState) == "function" and spec.getState() or spec.state
        if type(target) ~= "table" then return nil end
        return F:ReadRuntimeState(target, policy)
    end

    -- 公开 persist=false 外观 API 会暂存 Domain；保存首个草稿前的原始字段（含缺失键），
    -- 同值最终提交仍须保存，失败不能把最后一个预览值冒充为已提交值；任一成功持久提交会消费全部草稿。
    local stagedAppearance
    local function CommitState(reason, candidate, persist)
        local rawState = type(spec.getState) == "function" and spec.getState() or spec.state
        if type(rawState) ~= "table" then return false, "floating surface state unavailable" end
        -- 失败回滚保留原始字段/缺失键；不能用补默认后的副本覆盖旧 Store。
        local previous = {}
        for _,key in ipairs(STATE_KEYS) do previous[key]=rawState[key] end
        local rollbackState = persist ~= false and stagedAppearance or previous -- 草稿只覆盖回滚基线，不创建第二份持久化 Authority。
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
            if ok == true and sessionLockPreferences and (reason == "lock" or reason == "locked") then
                ok, err = sessionLockPreferences:SetLocked(id, nextState.locked, true) -- 一次锁动作只提交一份 Chrome 偏好，拒绝时沿用 Surface/Shell 回滚。
            end
            if ok ~= true then
                if type(spec.setState) == "function" then
                    pcall(spec.setState, rollbackState, tostring(reason or "state") .. ":rollback")
                else
                    F:ApplyNormalizedState(rawState, rollbackState)
                end
                local hadDraft = stagedAppearance ~= nil
                stagedAppearance = nil -- 拒绝动作撤销草稿后允许显式重试，不能留下未保存值触发幂等成功。
                if hadDraft and surface.shell then surface:ApplyLayout(false, "appearance_rollback") end -- 同时撤销其它通道草稿的 Native 表现。
                return false, err
            end
            stagedAppearance = nil -- 当前窗口快照已整体保存并回读，不能让旧草稿覆盖下一次真实提交。
        elseif APPEARANCE_REASONS[reason] == true and stagedAppearance == nil then
            stagedAppearance = previous -- 只记录第一次成功 Stage；连续预览始终回到真实提交前的字段形状。
        end
        SafeCall(spec.onStateChanged, surface, CurrentState(), tostring(reason or "state"))
        return true
    end

    local function Save(reason, candidate) return CommitState(reason, candidate, true) end
    local function Stage(reason, candidate) return CommitState(reason, candidate, false) end
    local function CommitSameAppearance(reason, candidate, value, persist)
        if persist ~= false and stagedAppearance ~= nil then
            local ok, err = Save(reason, candidate) -- 草稿值相同仍是一次完成动作；无草稿的重复调用维持零 IO。
            if ok ~= true then return false, err end
            return true, value, true
        end
        return true, value, false
    end

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
        -- 共享 HUD 外框持有外观编辑器；除明确退出的特殊窗口外，各 FloatingSurface 使用同一标题入口，功能组件不能另造透明度/字体控件。
        appearanceControls = spec.appearanceControls ~= false,
        appearancePanelWidth = tonumber(spec.appearancePanelWidth),
        -- 悬浮 HUD 使用紧凑外框，普通状态比应用对话框低；紧凑最小化把全部外框折成可拖动方形恢复按钮。
        compactChrome = true,
        minimizedSize = tonumber(spec.minimizedSize) or 30,
        minimizedWidth = tonumber(spec.minimizedWidth),
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
        -- 原生 Escape 关闭由 WindowShell 收口，并沿既有 onClosed 同步 Surface/Host 与租约。
        closeOnEscape = spec.closeOnEscape == true,
        onAppearanceReset = function() return surface:ResetLayout(true) end,
        onClose = function(_, reason)
            if type(spec.onClose) == "function" then return spec.onClose(surface, tostring(reason or "close")) end
            return true
        end,
        onClosed = function(_, reason)
            -- 原生外框在此之前已隐藏；Surface 逻辑可见性须同步，避免 ResetLayout/响应重排误认为关闭窗口仍在屏幕。
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
            if reason=="minimize" then reason="minimized" end
            -- 标题按钮与公开 Surface/Adapter API 共用 locked 原因，避免 Owner 只认其中一个入口而漏存小锁。
            if reason=="lock" then reason="locked" end
            if reason=="opacity" then reason="overall_opacity" end -- 标题整体透明度与公开 Surface API 共用同一最终提交原因。
            target.minimized = snapshot.minimized == true
            target.locked = snapshot.locked == true
            target.overallOpacity = Clamp(snapshot.overallOpacity, 0, 1, FirstNonNil(target.overallOpacity, policy.defaultOverallOpacity))
            target.backgroundOpacity = Clamp(snapshot.backgroundOpacity, 0, 1, FirstNonNil(target.backgroundOpacity, policy.defaultBackgroundOpacity))
            target.textOpacity = Clamp(snapshot.textOpacity, 0, 1, FirstNonNil(target.textOpacity, policy.defaultTextOpacity))
            target.fontScale = Clamp(snapshot.fontScale, policy.minFontScale, policy.maxFontScale, FirstNonNil(target.fontScale, policy.defaultFontScale))

            if reason == "geometry" or reason == "minimized" then
                -- snapshot 已是 Windowing 提交的最终矩形，不能再 GetLogicalRect；重复读取曾造成重登漂移。
                -- 吸附也消费同一矩形，再由 StorePlacementRect 写入原 widgetWindow。
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
                    -- 拒绝的吸附事务不得保存成成功几何；原 Store 仍是 authoritative intent。
                    if committed ~= true then return false,"snap_geometry_rejected" end
                    if committed == true then
                        placementX = tonumber(resolvedX) or placementX
                        placementY = tonumber(resolvedY) or placementY
                    end
                    if snapped == true then F.metrics.snapCommits = (tonumber(F.metrics.snapCommits) or 0) + 1 end
                end
                local liveContext = S.Layout:GetContext()
                local liveScale = spec.scaleWithAddon == false and 1 or math.max(0.01, tonumber(liveContext.addonScale) or 1)
                -- 拖动 compact/低分辨率拟合窗只更新位置，不永久缩小 preferred size。
                -- addonScale 只在设计尺寸入/出边界一次；uiScale 不参与本次已校准逻辑坐标。
                if tostring(snapshot.geometryKind) == "resize" then
                    target.width = math.max(policy.minWidth, (tonumber(snapshot.normalWidth) or placementW) / liveScale)
                    target.height = math.max(policy.minHeight, (tonumber(snapshot.normalHeight) or placementH) / liveScale)
                end
                if type(S.Layout.StoreWindowPlacementRect) == "function" then
                    S.Layout:StoreWindowPlacementRect(target,placementX,placementY,placementW,placementH,{mode=tostring(spec.boundaryMode or "free"),edgeH=snapshot.edgeH,edgeV=snapshot.edgeV})
                elseif type(S.Layout.StorePlacementRect) == "function" then
                    S.Layout:StorePlacementRect(target,placementX,placementY,placementW,placementH,{mode=tostring(spec.boundaryMode or "free")})
                elseif type(S.Layout.StorePlacement) == "function" then
                    -- 仅兼容部分升级的开发树；发布 toc 始终加载 StorePlacementRect。
                    S.Layout:StorePlacement(target, surface.shell.window, { mode = tostring(spec.boundaryMode or "free") })
                end
                target.userMoved = true
                F.metrics.geometryCommits = (tonumber(F.metrics.geometryCommits) or 0) + 1
            end
            local saved = Save(reason, target)
            -- 用户提交后的元数据立即进入冷诊断快照；不能等下次重排仍报告上次保存的中心。
            -- 只复制标量，不追加历史，不读取磁盘；迁移本身仍不会触发 Save。
            if saved==true and reason=="geometry" and surface.shell and surface.shell.placementInfo then
                local info=surface.shell.placementInfo
                -- 只更新诊断镜像；真实 x/y 已由原 StorePlacementRect 提交。
                info.savedX,info.savedY=target.x,target.y
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
    -- 悬浮功能内容属于 RSUI 表现，返回逻辑 Shell body，让后代参与共享 Measure/Arrange/Release；显式 Native 访问器仅用于确需引擎控件的适配器。
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
            -- 普通内容重排可能来自高频刷新，不得取消手势或采样 metrics。
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
        if target.minimized and self.shell.minimizeMode=="collapse" then placementH=tonumber(spec.titleHeight) or 24 end
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
        -- Shell Show 调 placementDelegate，一次 fresh sample 即可，不重复采样/重放。
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
        -- 不能用 and/or 模拟分支；Save 拒绝必须保留 false 并回滚 Native，不得转入 Stage 后报成功。
        local stateOk, stateErr
        if persist ~= false then stateOk, stateErr = Save("locked", candidate) else stateOk, stateErr = Stage("locked", candidate) end
        if stateOk ~= true then self.shell:SetLocked(previous, false); return false, stateErr end
        F.metrics.lockChanges = (tonumber(F.metrics.lockChanges) or 0) + 1
        return true, true
    end

    function surface:SetMinimized(value, persist)
        local target = CurrentState(); if target == nil then return false end
        local previous = target.minimized == true
        local nextValue = value == true
        -- 同一种设置窗的两个入口共享 Aux 状态；隐藏实例的 Shell 可能仍是旧形态。
        -- 先消费最新状态再执行动作，不能让 Shell 的无变化返回跳过本次 Store 提交。
        if previous == nextValue and self.shell.minimized == nextValue then return true, false end
        local synced,syncErr=self:ApplyLayout(false,"state_sync",target)
        if synced~=true then return false,syncErr end
        local candidate = F:NormalizeState(target, policy); candidate.minimized = nextValue
        local shellOk, shellErr = self.shell:SetMinimized(nextValue, false, function(rect)
            S.Layout:StoreWindowPlacementRect(candidate,rect.x,rect.y,rect.width,rect.height,{mode=tostring(spec.boundaryMode or "free"),edgeH=rect.edgeH,edgeV=rect.edgeV})
            candidate.userMoved=true
            if persist~=false then return Save("minimized",candidate) end
            return Stage("minimized",candidate)
        end)
        if shellOk ~= true then return false, shellErr end
        F.metrics.minimizeChanges = (tonumber(F.metrics.minimizeChanges) or 0) + 1
        return true, true
    end

    function surface:SetOverallOpacity(value, persist)
        local target = CurrentState(); if target == nil then return false end
        local previous = tonumber(target.overallOpacity) or policy.defaultOverallOpacity
        local nextValue = Clamp(value, 0, 1, FirstNonNil(target.overallOpacity, policy.defaultOverallOpacity))
        if math.abs(nextValue - previous) <= 0.0001 then return CommitSameAppearance("overall_opacity", target, nextValue, persist) end
        local shellOk, shellErr = self.shell:SetOverallOpacity(nextValue, false)
        if shellOk ~= true then return false, shellErr end
        local candidate = F:NormalizeState(target, policy); candidate.overallOpacity = nextValue
        -- 持久化失败保持拒绝，预览仅在调用者显式 persist=false 时进入 Stage。
        local stateOk, stateErr
        if persist ~= false then stateOk, stateErr = Save("overall_opacity", candidate) else stateOk, stateErr = Stage("overall_opacity", candidate) end
        if stateOk ~= true then self:ApplyLayout(false, "appearance_rollback"); return false, stateErr end -- 恢复 Authority 快照，不能退回上一帧草稿。
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
        if math.abs(nextValue - previous) <= 0.0001 then return CommitSameAppearance("background_opacity", target, nextValue, persist) end
        local shellOk, shellErr = self.shell:SetBackgroundOpacity(nextValue, false)
        if shellOk ~= true then return false, shellErr end
        local candidate = F:NormalizeState(target, policy); candidate.backgroundOpacity = nextValue
        -- 预览不写盘，最终提交由原 Owner 同步耐久；拒绝不能隐式降级为成功预览。
        local stateOk, stateErr
        if persist ~= false then stateOk, stateErr = Save("background_opacity", candidate) else stateOk, stateErr = Stage("background_opacity", candidate) end
        if stateOk ~= true then self:ApplyLayout(false, "appearance_rollback"); return false, stateErr end -- 多通道草稿需一并撤销到真实提交值。
        F.metrics.appearanceChanges = (tonumber(F.metrics.appearanceChanges) or 0) + 1
        return true, nextValue, true
    end

    function surface:GetBackgroundOpacity() local s = CurrentState(); if s ~= nil and s.backgroundOpacity ~= nil then return s.backgroundOpacity end; return policy.defaultBackgroundOpacity end

    function surface:SetTextOpacity(value, persist)
        local target = CurrentState(); if target == nil then return false end
        local previous = tonumber(target.textOpacity) or policy.defaultTextOpacity
        local nextValue = Clamp(value, 0, 1, FirstNonNil(target.textOpacity, policy.defaultTextOpacity))
        if math.abs(nextValue - previous) <= 0.0001 then return CommitSameAppearance("text_opacity", target, nextValue, persist) end
        local shellOk, shellErr = self.shell:SetTextOpacity(nextValue, false)
        if shellOk ~= true then return false, shellErr end
        local candidate = F:NormalizeState(target, policy); candidate.textOpacity = nextValue
        -- 保留 Save 的失败结果，让既有 Native/Store 回滚生效。
        local stateOk, stateErr
        if persist ~= false then stateOk, stateErr = Save("text_opacity", candidate) else stateOk, stateErr = Stage("text_opacity", candidate) end
        if stateOk ~= true then self:ApplyLayout(false, "appearance_rollback"); return false, stateErr end -- Native 与 Domain 使用相同回滚快照。
        F.metrics.appearanceChanges = (tonumber(F.metrics.appearanceChanges) or 0) + 1
        return true, nextValue, true
    end

    function surface:GetTextOpacity() local s = CurrentState(); if s ~= nil and s.textOpacity ~= nil then return s.textOpacity end; return policy.defaultTextOpacity end

    function surface:SetFontScale(value, persist)
        local target = CurrentState(); if target == nil then return false end
        local previous = tonumber(target.fontScale) or policy.defaultFontScale
        local nextValue = Clamp(value, policy.minFontScale, policy.maxFontScale, FirstNonNil(target.fontScale, policy.defaultFontScale))
        if math.abs(nextValue - previous) <= 0.0001 then return CommitSameAppearance("font_scale", target, nextValue, persist) end
        if type(self.shell.SetFontScale) ~= "function" then return false, "floating_font_scale_contract_unavailable" end
        local shellOk, shellErr = self.shell:SetFontScale(nextValue, false)
        if shellOk ~= true then return false, shellErr end
        local candidate = F:NormalizeState(target, policy); candidate.fontScale = nextValue
        -- 字体提交失败不能被 Stage 覆盖，否则 UI 看似成功但下次冷启动恢复旧值。
        local stateOk, stateErr
        if persist ~= false then stateOk, stateErr = Save("font_scale", candidate) else stateOk, stateErr = Stage("font_scale", candidate) end
        if stateOk ~= true then self:ApplyLayout(false, "appearance_rollback"); return false, stateErr end -- 字号布局按已恢复的 Authority 重新应用。
        F.metrics.appearanceChanges = (tonumber(F.metrics.appearanceChanges) or 0) + 1
        return true, nextValue, true
    end

    function surface:GetFontScale() local s = CurrentState(); if s ~= nil and s.fontScale ~= nil then return s.fontScale end; return policy.defaultFontScale end

    function surface:SetSize(designWidth, designHeight, persist)
        local target = CurrentState(); if target == nil then return false end
        if self.windowController and self.windowController:IsInteracting() then return false,"window_interacting" end
        local nextWidth = Clamp(designWidth, policy.minWidth, policy.maxWidth, target.width or policy.defaultWidth)
        local nextHeight = Clamp(designHeight, policy.minHeight, policy.maxHeight, target.height or policy.defaultHeight)
        local changed = math.abs(nextWidth - (tonumber(target.width) or nextWidth)) > 0.0001
            or math.abs(nextHeight - (tonumber(target.height) or nextHeight)) > 0.0001
            or target.minimized == true or self.shell.minimized == true
        if changed ~= true then return true, target.width, target.height, false end

        local candidate = F:NormalizeState(target, policy)
        candidate.width, candidate.height, candidate.minimized = nextWidth, nextHeight, false
        local bx,by,bw,bh=self.shell:GetPlacementRect()
        if bx==nil or by==nil or bw==nil or bh==nil then return false,"window_geometry_unavailable" end
        local oldMin,oldW,oldH,oldInfo=self.shell.minimized,self.shell.normalWidth,self.shell.normalHeight,self.shell.placementInfo
        local function Rollback(err)
            self.shell.minimized=oldMin
            local ok=self.shell:ApplyPlacementRect(bx,by,oldW,oldH,oldInfo,true)
            self.shell.minimizeButton:SetText(oldMin and "+" or "—")
            return false,tostring(err or "floating_size_rejected")..(ok~=true and ":rollback_rejected" or "")
        end
        -- 按候选展开尺寸先验证 Native；保存失败绝不能通过 and/or 再执行 Stage 冒充成功。
        local layoutOk, layoutErr = self:ApplyLayout(false,"size",candidate)
        if layoutOk ~= true then
            return Rollback(layoutErr)
        end
        local x,y,w,h=self.shell:GetPlacementRect()
        local info=self.shell.placementInfo or {}
        S.Layout:StoreWindowPlacementRect(candidate,x,y,w,h,{mode=tostring(spec.boundaryMode or "free"),edgeH=info.edgeH,edgeV=info.edgeV})
        candidate.userMoved=true
        local stateOk,stateErr
        if persist~=false then stateOk,stateErr=Save("size",candidate) else stateOk,stateErr=Stage("size",candidate) end
        if stateOk~=true then return Rollback(stateErr) end
        return true, nextWidth, nextHeight, true
    end

    function surface:ResetLayout(persist)
        local target = CurrentState(); if target == nil then return false end
        -- 硬恢复先 Native 再持久化；清除 placement intent 的完整字段和 minimized，
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

    -- 公开关闭经 WindowShell 契约，与 X 按钮共用 shell:Close -> onClose（仅选择启用时可否决）-> hide -> onClosed。
    function surface:Close(reason)
        F.metrics.closeRequests = (tonumber(F.metrics.closeRequests) or 0) + 1
        local closed, closeErr = self.shell:Close(tostring(reason or "close"))
        if closed ~= true then
            if self.shell.allowCloseVeto == true or (self.shell.spec ~= nil and self.shell.spec.allowCloseVeto == true) then
                F.metrics.closeVetoes = (tonumber(F.metrics.closeVetoes) or 0) + 1
                return false, closeErr or "floating window close vetoed"
            end
            -- 无否决窗口默认允许关闭；业务回调失败不能阻止关闭，强制视觉隐藏并继续关闭清理链。
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
