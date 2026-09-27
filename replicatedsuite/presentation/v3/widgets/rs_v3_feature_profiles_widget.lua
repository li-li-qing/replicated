------------------------------------------------------------------------
-- Replicated Suite V3 - Feature Profile Screen Buttons
--
-- One user profile -> one compact draggable screen button. The Feature owns
-- profile data/lifecycle intent; this widget only projects and forwards clicks.
--
-- 维护（2026-09-25，feature-profile-quick-relog-1）:
--  * 恢复优先级：source-viewport intent（logical-free-v2，同分辨率精确、跨分辨率按中心比例
--    重投影）> 旧 logical-edge-v1 边锚点 > 旧 quickX/quickY 绝对坐标 > 默认出生点。
--    旧存档只在内存里做兼容投影，加载/重排阶段绝不写 Store、绝不升级格式。
--  * 组级去重叠：同一 screen_buttons 组先各自 ResolvePlacement，再交给 Layout 纯 solver
--    消解重叠；无重叠时结果逐像素不变。
--  * 可见性 fail-soft：原生几何被拒绝不再隐藏按钮、也不再让整个 widget 显示失败（否则
--    WidgetHost 会把它从 ApplyResponsiveLayout 名单里排除，临时 viewport 投影永远无法自愈）。
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local UI = S.UI
local Host = S.UIV3 and S.UIV3.WidgetHost or nil
local Feature = S.Features and S.Features.FeatureProfiles or nil
if type(UI) ~= "table" or type(Host) ~= "table" or type(Feature) ~= "table" then return end

local WIDGET_ID = "tools.feature_profiles.quick"
local OWNER = "v3:feature_profile_quick_buttons"
local DIAGNOSTIC_EVENT_LIMIT = 8
local CREATE_ATTEMPT_LIMIT = 2

local function LogicalRect(widget, pinnedScale)
    if S.Layout and type(S.Layout.GetWindowLogicalRect) == "function" then
        return S.Layout:GetWindowLogicalRect(widget, pinnedScale)
    end
    return nil, nil, nil, nil
end

local function PlacementFromMeta(meta)
    if type(meta) ~= "table" or tostring(meta.quickCoordinateSpace or "") ~= "logical-edge-v1" then return nil end
    local anchorH, anchorV = tostring(meta.quickAnchorH or ""), tostring(meta.quickAnchorV or "")
    local offsetX, offsetY = tonumber(meta.quickOffsetX), tonumber(meta.quickOffsetY)
    if (anchorH ~= "LEFT" and anchorH ~= "RIGHT") or (anchorV ~= "TOP" and anchorV ~= "BOTTOM")
        or offsetX == nil or offsetY == nil then return nil end
    return {
        coordinateSpace = "logical-edge-v1", anchorH = anchorH, anchorV = anchorV,
        offsetX = math.max(0, offsetX), offsetY = math.max(0, offsetY),
    }
end

-- 维护：Feature-owned 的 source-viewport intent 是同一分辨率精确恢复的唯一 Authority。
-- 只有完整的一组值（x/y + 逻辑宽高 + 中心比例）才被接受，避免产生半套 viewport 身份。
local function ViewportIntentFromMeta(meta)
    if type(meta) ~= "table" then return nil end
    local x, y = tonumber(meta.quickX), tonumber(meta.quickY)
    local width, height = tonumber(meta.quickSavedLogicalWidth), tonumber(meta.quickSavedLogicalHeight)
    local centerX, centerY = tonumber(meta.quickNormalizedCenterX), tonumber(meta.quickNormalizedCenterY)
    if x == nil or y == nil or width == nil or height == nil or width <= 0 or height <= 0 then return nil end
    if centerX == nil or centerY == nil or centerX < -2 or centerX > 3 or centerY < -2 or centerY > 3 then return nil end
    return {
        coordinateSpace = "logical-free-v2", userMoved = true, x = x, y = y,
        savedLogicalWidth = width, savedLogicalHeight = height,
        savedUiScale = tonumber(meta.quickSavedUiScale),
        normalizedCenterX = centerX, normalizedCenterY = centerY,
    }
end

-- 维护：一次捕获两套 intent —— 旧 edge schema（Store 兼容字段）与新的 source-viewport
-- intent（同分辨率精确恢复 + 跨分辨率安全重投影）。两者都只从已提交的 committed rect 派生。
local function BuildPlacements(x, y, width, height)
    if not (S.Layout and type(S.Layout.StorePlacementRect) == "function") then return nil end
    local edge = {}
    local px, py = S.Layout:StorePlacementRect(edge, x, y, width, height, { mode = "strict" })
    local intentSource = {}
    S.Layout:StorePlacementRect(intentSource, x, y, width, height, { mode = "free" })
    return edge, px, py, {
        savedLogicalWidth = tonumber(intentSource.savedLogicalWidth),
        savedLogicalHeight = tonumber(intentSource.savedLogicalHeight),
        savedUiScale = tonumber(intentSource.savedUiScale),
        normalizedCenterX = tonumber(intentSource.normalizedCenterX),
        normalizedCenterY = tonumber(intentSource.normalizedCenterY),
    }
end

local function DefaultPosition(index)
    local policy = Feature:GetQuickButtonPolicy() or {}
    if S.Layout and type(S.Layout.GetSafeSpawn) == "function" then
        local ok, x, y = pcall(function()
            return S.Layout:GetSafeSpawn(index, policy.width or 104, policy.height or 26, {
                baseX = policy.defaultBaseX or 300, baseY = policy.defaultBaseY or 136,
                gapX = policy.gapX or 6, gapY = policy.gapY or 4,
                maxColumns = policy.maxColumns or 4, edge = 8,
            })
        end)
        if ok and tonumber(x) ~= nil and tonumber(y) ~= nil then return math.floor(x + 0.5), math.floor(y + 0.5) end
    end
    local n = math.max(0, (tonumber(index) or 1) - 1)
    local cols = math.max(1, tonumber(policy.maxColumns) or 4)
    local width, height = tonumber(policy.width) or 104, tonumber(policy.height) or 26
    return (tonumber(policy.defaultBaseX) or 300) + (n % cols) * (width + (tonumber(policy.gapX) or 0)),
        (tonumber(policy.defaultBaseY) or 136) + math.floor(n / cols) * (height + (tonumber(policy.gapY) or 0))
end

local function CreateWidget()
    local instance = { id = WIDGET_ID, visible = false, subscribed = false, buttons = {}, rows = {},
        diagnostics = {}, createAttempts = {}, metrics = {
            plans = 0, geometryApplies = 0, geometryRejects = 0, deoverlaps = 0, reflows = 0,
            createFailures = 0, fallbackPlacements = 0,
        } }

    -- 中文维护注释（2026-09-25，feature-profile-screen-snap-1）：功能方案按钮与换装按钮属于同一
    -- screen_buttons 吸附组；Layout 只负责几何/邻居发现，方案 Store 仍独立保存最终位置。隐藏按钮会被
    -- ScreenSnapRegistry 自动排除，因此不会因保留 Native 实例而产生不可见吸附目标。
    function instance:RegisterSnapRecord(record)
        if type(record) ~= "table" or record.button == nil then return false end
        if record.snapRegistered == true then return true end
        local snapId = tostring(record.snapId or "")
        if snapId == "" then return false end
        local options = { ensureNow = false, snapGroup = "screen_buttons", snapKind = "button" }
        local ok = false
        if type(UI.RegisterScreenSnap) == "function" then
            ok = UI:RegisterScreenSnap(snapId, record.button, options) == true
        elseif S.Layout ~= nil and type(S.Layout.RegisterScreenSnap) == "function" then
            ok = S.Layout:RegisterScreenSnap(snapId, record.button, options) == true
        end
        record.snapRegistered = ok
        return ok
    end

    function instance:PushDiagnostic(kind, detail)
        local row = {
            kind = tostring(kind or "event"),
            at = type(S.NowMs) == "function" and tonumber(S.NowMs()) or nil,
            detail = detail,
        }
        self.diagnostics[#self.diagnostics + 1] = row
        if #self.diagnostics > DIAGNOSTIC_EVENT_LIMIT then table.remove(self.diagnostics, 1) end
        return row
    end

    -- 维护：几何事件只保留有界计数 + 最近一条原因，绝不进入热路径、不读 Native。
    function instance:NoteGeometryFailure(record, err)
        self.metrics.geometryRejects = (tonumber(self.metrics.geometryRejects) or 0) + 1
        self:PushDiagnostic("geometry_rejected", {
            profileId = record and record.profileId or nil,
            error = tostring(err or "geometry_rejected"),
            lastX = record and record.lastX or nil, lastY = record and record.lastY or nil,
        })
    end

    function instance:ResolvePosition(meta, index, record)
        local policy = Feature:GetQuickButtonPolicy() or {}
        local width, height = tonumber(policy.width) or 104, tonumber(policy.height) or 26
        local defaultX, defaultY = DefaultPosition(index)
        local customized = type(meta) == "table" and meta.quickPositionCustomized == true
        local placement, source = nil, "default"
        if customized then
            local intent = ViewportIntentFromMeta(meta)
            if intent ~= nil then
                placement, source = intent, "viewport-intent"
            else
                local edge = PlacementFromMeta(meta)
                if edge ~= nil then
                    placement, source = edge, "edge-anchor"
                elseif record ~= nil and record.legacyPlacement ~= nil then
                    placement, source = record.legacyPlacement, "runtime-edge"
                elseif tonumber(meta.quickX) ~= nil and tonumber(meta.quickY) ~= nil then
                    placement, source = { x = tonumber(meta.quickX), y = tonumber(meta.quickY),
                        userMoved = true, coordinateSpace = "logical-free-v2" }, "absolute-legacy"
                end
            end
        end
        if S.Layout and type(S.Layout.ResolvePlacement) == "function" then
            local x, y, w, h, info = S.Layout:ResolvePlacement(placement, width, height, defaultX, defaultY,
                { mode = "strict", topLevel = true, topReachHeight = height })
            if type(info) == "table" then info.intentSource = source end
            -- 只有“用户确实自定义过位置，却没有任何可用 intent”才算 fallback（意图丢失证据）；
            -- 从未移动过的方案走默认出生点属于正常路径。
            if source == "default" and customized == true then
                self.metrics.fallbackPlacements = (tonumber(self.metrics.fallbackPlacements) or 0) + 1
            end
            return x, y, customized, w, h, info
        end
        return defaultX, defaultY, false, width, height
    end

    function instance:EnsureButton(meta, index)
        local id = tostring(meta.profileId or "")
        if id == "" then return nil end
        local record = self.buttons[id]
        if record ~= nil then return record end
        local attempts = tonumber(self.createAttempts[id]) or 0
        if attempts >= CREATE_ATTEMPT_LIMIT then
            return nil, "feature_profile_button_create_budget_exhausted"
        end
        self.createAttempts[id] = attempts + 1
        local policy = Feature:GetQuickButtonPolicy() or {}
        local x, y, customized = self:ResolvePosition(meta, index, nil)
        local button = UI:CreateButton("UIParent", "v3_feature_profile_quick_" .. id, tostring(meta.name or "方案"), x, y,
            tonumber(policy.width) or 104, tonumber(policy.height) or 26, 10, false, true, OWNER)
        if button == nil then
            self.metrics.createFailures = (tonumber(self.metrics.createFailures) or 0) + 1
            self:PushDiagnostic("create_failed", { profileId = meta.profileId, name = tostring(meta.name or "") })
            return nil, "feature_profile_button_create_failed"
        end

        record = { button = button, profileId = tonumber(meta.profileId), dragging = false, ignoreClick = false, present = true,
            lastX = x, lastY = y, customized = customized, snapId = "screen_snap:feature_profile:" .. id, snapRegistered = false }
        if customized == true and PlacementFromMeta(meta) == nil and ViewportIntentFromMeta(meta) == nil then
            record.legacyPlacement = select(1, BuildPlacements(x, y, tonumber(policy.width) or 104, tonumber(policy.height) or 26))
        end
        self.buttons[id] = record
        button.rsHudOwner = "feature_profile_quick_button"
        self:RegisterSnapRecord(record)

        local function FailInteraction(detail)
            if record.snapRegistered == true then
                if type(UI.UnregisterScreenSnap) == "function" then UI:UnregisterScreenSnap(record.snapId)
                elseif S.Layout ~= nil and type(S.Layout.UnregisterScreenSnap) == "function" then S.Layout:UnregisterScreenSnap(record.snapId) end
            end
            record.snapRegistered = false
            UI:SetVisible(button, false, OWNER)
            self.buttons[id] = nil
            self:PushDiagnostic("interaction_failed", { profileId = meta.profileId, error = tostring(detail or "") })
            return nil, tostring(detail or "feature_profile_quick_interaction_failed")
        end
        if type(UI.TryInteractionCall) ~= "function" or type(UI.RequireHandler) ~= "function" then
            return FailInteraction("critical_interaction_contract_unavailable")
        end
        local dragEnabled, dragErr = UI:TryInteractionCall(button, "EnableDrag", true)
        if dragEnabled ~= true then return FailInteraction("feature_profile_enable_drag_failed:" .. tostring(dragErr or "rejected")) end
        if button.SetDragCondition ~= nil and DC_ALWAYS ~= nil then
            local conditionOk, conditionErr = UI:TryInteractionCall(button, "SetDragCondition", DC_ALWAYS)
            if conditionOk ~= true then return FailInteraction("feature_profile_drag_condition_failed:" .. tostring(conditionErr or "rejected")) end
        end

        local dragStartOk, dragStartErr = UI:RequireHandler(button, "OnDragStart", function()
            if instance.visible ~= true then return false end
            local moving = UI:TryInteractionCall(button, "StartMoving")
            if moving ~= true then return false end
            local _, _, _, _, unit = LogicalRect(button)
            record.geometryUnitScale = unit and unit.effectiveScale or nil
            record.dragViewport = S.Layout and S.Layout:MakeSignature(S.Layout:GetContext()) or nil
            record.dragging, record.ignoreClick = true, false
            return true
        end, "v3_feature_profile_quick:drag_start:" .. id)

        local dragStopOk, dragStopErr = UI:RequireHandler(button, "OnDragStop", function()
            if record.dragging ~= true then return true end
            if type(button.StopMovingOrSizing) == "function" then pcall(button.StopMovingOrSizing, button) end
            record.dragging, record.ignoreClick = false, true
            local x2, y2, width, height = LogicalRect(button, record.geometryUnitScale)
            record.geometryUnitScale = nil
            local context = S.Layout and S.Layout:GetContext(true) or nil
            local changed = record.pendingPlacement or (context and record.dragViewport ~= S.Layout:MakeSignature(context))
            record.dragViewport, record.pendingPlacement = nil, nil
            if changed then return instance:ApplyLayout(true) end
            if x2 == nil or y2 == nil then return false, "feature_profile_drag_rect_unavailable" end
            if S.Layout ~= nil and type(S.Layout.ResolveScreenSnap) == "function" then
                local sx, sy, snapped = S.Layout:ResolveScreenSnap(record.snapId, x2, y2, width, height, {
                    group = "screen_buttons", kind = "button",
                })
                if snapped == true then x2, y2 = sx, sy end
            end
            -- 维护（feature-profile-quick-relog-1）：用户真实拖动是唯一允许升级持久化格式的边沿。
            -- 提交前把 committed rect 夹进 safe viewport，使 Store 里的 intent 永远至少完整可见，
            -- 之后无论重登还是重投影都从这份 intent 出发，不会以“上次投影结果”为输入累积漂移。
            local clampX, clampY = x2, y2
            if S.Layout ~= nil and type(S.Layout.ClampTopLeft) == "function" then
                clampX, clampY = S.Layout:ClampTopLeft(x2, y2, width, height)
            end
            local placement, placementX, placementY, viewportIntent = BuildPlacements(clampX, clampY, width, height)
            local windowing = S.RSUI and S.RSUI.Windowing or nil
            if placement == nil or windowing == nil then return false, "feature_profile_drag_commit_unavailable" end
            local accepted, geometryErr = windowing:ApplyGeometry(button, OWNER, placementX, placementY, width, height, true)
            if accepted ~= true then return false, geometryErr end
            local ok, saveErr = Feature.Commands:SetQuickPosition(record.profileId, placementX, placementY, placement, viewportIntent)
            if ok ~= true then instance:ApplyLayout(true); return false, saveErr end
            record.legacyPlacement = placement
            record.lastX, record.lastY, record.customized = placementX, placementY, true
            return true
        end, "v3_feature_profile_quick:drag_stop:" .. id)

        local clickOk, clickErr = UI:RequireHandler(button, "OnClick", function()
            if record.dragging == true then return false end
            if record.ignoreClick == true then record.ignoreClick = false; return false end
            local ok, applyErr = Feature.Commands:ApplyProfile(record.profileId)
            instance:Refresh()
            return ok, applyErr
        end, "v3_feature_profile_quick:click:" .. id)

        if dragStartOk ~= true or dragStopOk ~= true or clickOk ~= true then
            return FailInteraction(dragStartErr or dragStopErr or clickErr or "feature_profile_required_handler_failed")
        end
        self:PushDiagnostic("created", { profileId = meta.profileId, name = tostring(meta.name or ""), x = x, y = y })
        return record
    end

    -- 维护：解析阶段只做纯投影（无 Native 写入、无 Store 写入）。createAllowed=false 用于
    -- metrics 重排：只重排已存在按钮，绝不在重排里创建 Native 控件。
    function instance:BuildPlan(createAllowed)
        local plan = {}
        self.metrics.plans = (tonumber(self.metrics.plans) or 0) + 1
        for index, meta in ipairs(self.rows or {}) do
            local id = tostring(meta.profileId or "")
            if id ~= "" then
                local record = self.buttons[id]
                if record == nil and createAllowed == true then record = self:EnsureButton(meta, index) end
                if record ~= nil then
                    record.present, record.profileId = true, tonumber(meta.profileId)
                    self:RegisterSnapRecord(record)
                    local x, y, customized, width, height, info = self:ResolvePosition(meta, index, record)
                    plan[#plan + 1] = { record = record, meta = meta, index = index, x = x, y = y, width = width,
                        height = height, customized = customized, info = info, deoverlapped = false }
                end
            end
        end
        if #plan > 1 and S.Layout ~= nil and type(S.Layout.DeoverlapScreenRects) == "function" then
            local items = {}
            for position, row in ipairs(plan) do
                items[position] = { key = tostring(row.meta.profileId or position), order = position,
                    x = row.x, y = row.y, width = row.width, height = row.height }
            end
            -- 维护：间距参数必须为 0。用户用吸附把按钮紧贴排列时，两矩形只是“相邻”而不是
            -- “重叠”；若这里强制 gap，恢复过程会把用户排好的贴合布局每次推开几个像素。
            local solved = S.Layout:DeoverlapScreenRects(items, { gapX = 0, gapY = 0 })
            for position, row in ipairs(solved) do
                if plan[position] ~= nil and row.adjusted == true then
                    self.metrics.deoverlaps = (tonumber(self.metrics.deoverlaps) or 0) + 1
                    plan[position].x, plan[position].y, plan[position].deoverlapped = row.x, row.y, true
                end
            end
        end
        return plan
    end

    function instance:ApplyPlan(plan, force)
        local failures = {}
        for _, row in ipairs(plan) do
            local record = row.record
            if record.dragging == true then
                if force == true then record.pendingPlacement = true end
            else
                local windowing = S.RSUI and S.RSUI.Windowing or nil
                if not (windowing and type(windowing.ApplyGeometry) == "function") then
                    record.lastGeometryError = "feature_profile_geometry_transaction_unavailable"
                    failures[#failures + 1] = tostring(row.meta.name or row.meta.profileId) .. "(几何契约)"
                else
                    local ok, err = windowing:ApplyGeometry(record.button, OWNER, row.x, row.y, row.width, row.height, force == true)
                    record.placementInfo = row.info
                    if ok == true then
                        record.lastGeometryError = nil
                        record.lastX, record.lastY, record.customized = row.x, row.y, row.customized
                        record.deoverlapped = row.deoverlapped == true
                        record.applyCount = (tonumber(record.applyCount) or 0) + 1
                        self.metrics.geometryApplies = (tonumber(self.metrics.geometryApplies) or 0) + 1
                    else
                        record.lastGeometryError = tostring(err or "geometry_rejected")
                        failures[#failures + 1] = tostring(row.meta.name or row.meta.profileId) .. "(" .. record.lastGeometryError .. ")"
                        self:NoteGeometryFailure(record, err)
                    end
                end
            end
        end
        return failures
    end

    function instance:Refresh()
        self.rows = Feature:GetQuickRows() or {}
        local plan = self:BuildPlan(true)
        local planned, failures = {}, {}
        for _, row in ipairs(plan) do planned[tostring(row.meta.profileId or "")] = true end
        for _, row in ipairs(plan) do
            local record, meta = row.record, row.meta
            local prefix = meta.active and "● " or (meta.dirty and "* " or "")
            UI:SetText(record.button, prefix .. tostring(meta.name or "方案"), OWNER)
            if type(UI.EnsureEnabled) == "function" then
                local enabled = UI:EnsureEnabled(record.button, true, OWNER)
                if enabled ~= true then failures[#failures + 1] = tostring(meta.name or meta.profileId) .. "(启用状态)" end
            end
            UI:SetButtonActive(record.button, meta.active == true, OWNER)
        end
        local geometryFailures = self:ApplyPlan(plan, false)
        for _, reason in ipairs(geometryFailures) do failures[#failures + 1] = reason end
        -- 维护（feature-profile-quick-relog-1）：几何失败绝不隐藏按钮。旧实现把 placed==false
        -- 的按钮设为不可见，并让 Show() 整体失败，于是 WidgetHost 认为 widget 不可见 →
        -- 之后的 ApplyResponsivePresentation 再也不会把 ApplyLayout 送到这里，临时 viewport
        -- 投影就永久留在屏幕外（用户看到的现象正是“只剩第一个按钮”）。
        for _, row in ipairs(plan) do
            local record = row.record
            UI:SetVisible(record.button, self.visible == true, OWNER)
            if self.visible == true and record.button.Raise ~= nil then pcall(function() record.button:Raise() end) end
        end
        for id, record in pairs(self.buttons) do
            if planned[id] ~= true and record.button ~= nil then UI:SetVisible(record.button, false, OWNER) end
        end
        if #failures > 0 then
            self:PushDiagnostic("refresh_degraded", { failures = table.concat(failures, "、"), rowCount = #self.rows })
            if S.DiagnosticsManager ~= nil and type(S.DiagnosticsManager.WarningRateLimited) == "function" then
                S.DiagnosticsManager:WarningRateLimited("feature_profiles_v3", "FEATURE_PROFILE_QUICK_REFRESH_DEGRADED", 5000,
                    "功能方案快捷按钮刷新降级（按钮仍保持可见）", { detail = table.concat(failures, "、"), rows = #self.rows })
            end
        end
        if #plan == 0 then
            -- 维护（feature-profile-quick-relog-1）：没有任何可显示按钮时也必须返回成功。
            -- 让 Show() 失败会把 widget 从 WidgetHost 的可见/重排名单里摘掉，随后用户新建方案
            -- 或 viewport 恢复都不会再触发这里，形成“必须重启才可能出现”的死状态。这里只记录
            -- 有界诊断（真实创建失败仍由 EnsureButton/ApplyPlan 逐条上报）。
            self:PushDiagnostic("empty_projection", { rowCount = #self.rows, failures = #failures })
            if S.DiagnosticsManager ~= nil and type(S.DiagnosticsManager.WarningRateLimited) == "function" then
                S.DiagnosticsManager:WarningRateLimited("feature_profiles_v3", "FEATURE_PROFILE_QUICK_EMPTY", 5000,
                    "功能方案快捷按钮当前没有可显示方案", { rows = #self.rows })
            end
            return true
        end
        return true
    end

    function instance:Subscribe()
        if self.subscribed == true then return true end
        if not (S.Events and type(S.Events.SubscribeInternal) == "function") then return false, "feature profile quick event bus unavailable" end
        local ok = S.Events:SubscribeInternal(Feature.UpdateTopic, self, function()
            if instance.visible == true then instance:Refresh() end
        end)
        if ok ~= true then return false, "feature profile quick event subscription failed" end
        self.subscribed = true
        return true
    end

    function instance:Unsubscribe()
        if S.Events and type(S.Events.UnsubscribeInternalOwner) == "function" then S.Events:UnsubscribeInternalOwner(self) end
        self.subscribed = false
        return true
    end

    function instance:Show()
        if S.Layout then S.Layout:GetContext(true) end
        self.visible = true
        local subscribed, subErr = self:Subscribe()
        if subscribed ~= true then self.visible = false; return false, subErr end
        local ok, err = self:Refresh()
        if ok ~= true then self.visible = false; self:Unsubscribe(); return false, err end
        self:PushDiagnostic("show", { rows = #self.rows })
        return true
    end

    function instance:Hide()
        self.visible = false
        self:Unsubscribe()
        for _, record in pairs(self.buttons) do
            record.dragging = false
            if record.button ~= nil then
                if type(record.button.StopMovingOrSizing) == "function" then pcall(record.button.StopMovingOrSizing, record.button) end
                UI:SetVisible(record.button, false, OWNER)
            end
        end
        return true
    end

    -- 维护：metrics/分辨率边沿只重排已存在按钮；不创建 Native、不读装备/投影、不写 Store。
    function instance:ApplyLayout(fromMetrics)
        if fromMetrics == true then self.metrics.reflows = (tonumber(self.metrics.reflows) or 0) + 1 end
        local plan = self:BuildPlan(false)
        local failures = self:ApplyPlan(plan, fromMetrics == true)
        if #failures > 0 then
            self:PushDiagnostic("reflow_degraded", { failures = table.concat(failures, "、"), rows = #self.rows })
        end
        if S.Layout ~= nil and type(S.Layout.MakeSignature) == "function" then
            self.lastLayoutSignature = S.Layout:MakeSignature(S.Layout:GetContext())
        end
        return true
    end

    function instance:ResetLayout()
        if S.Layout then S.Layout:GetContext(true) end
        for _, record in pairs(self.buttons) do
            if record.dragging and type(record.button.StopMovingOrSizing) == "function" then pcall(record.button.StopMovingOrSizing, record.button) end
            record.dragging, record.pendingPlacement, record.dragViewport, record.geometryUnitScale, record.legacyPlacement = false, nil, nil, nil, nil
        end
        self.createAttempts = {}
        local ok, err = Feature.Commands:ResetQuickPositions()
        if ok ~= true then return false, err end
        local refreshed, refreshErr = self:Refresh()
        if refreshed ~= true then return false, refreshErr end
        return self:ApplyLayout(true)
    end

    ------------------------------------------------------------------------
    -- 诊断（按需读取，绝不进入热路径 / 绝不创建 Native / 绝不写 Store）
    ------------------------------------------------------------------------
    function instance:GetQuickButtonDiagnostics()
        local context = S.Layout and S.Layout:GetContext() or {}
        local layout = S.Layout
        local widthRatio = (tonumber(context.logicalWidth) or 0) > 0 and (tonumber(context.screenWidth) or 0) / tonumber(context.logicalWidth) or nil
        local heightRatio = (tonumber(context.logicalHeight) or 0) > 0 and (tonumber(context.screenHeight) or 0) / tonumber(context.logicalHeight) or nil
        -- 维护（2026-09-25，viewport-authority-evidence-1）：只做证据，不改 Authority。
        -- 如果 screen/uiScale 与 logical extent 的比例不一致，就说明当前 logical canvas 与真实
        -- 客户区不是同一个空间（"logical 内但物理窗外" 的必要条件）。真正修改 GetUiMetrics 之前
        -- 必须先有实机证据，本页只负责把它变成可读数字。
        local uiScale = tonumber(context.uiScale) or 1
        local tolerance = math.max(0.02, uiScale * 0.02)
        local payload = {
            contractVersion = 1,
            visible = self.visible == true,
            subscribed = self.subscribed == true,
            rowCount = #(self.rows or {}),
            context = {
                screenWidth = context.screenWidth, screenHeight = context.screenHeight,
                logicalWidth = context.logicalWidth, logicalHeight = context.logicalHeight,
                usableWidth = context.usableWidth, usableHeight = context.usableHeight,
                uiScale = context.uiScale, addonScale = context.addonScale,
                metricsSource = context.metricsSource, metricsReady = context.metricsReady,
                safeLeft = context.safeLeft, safeTop = context.safeTop,
                safeRight = context.safeRight, safeBottom = context.safeBottom,
                screenToLogicalWidthRatio = widthRatio, screenToLogicalHeightRatio = heightRatio,
                viewportAuthorityConsistent = widthRatio ~= nil and heightRatio ~= nil
                    and math.abs(widthRatio - uiScale) <= tolerance and math.abs(heightRatio - uiScale) <= tolerance or false,
                signature = layout and type(layout.MakeSignature) == "function" and layout:MakeSignature(context) or nil,
                lastAppliedSignature = self.lastLayoutSignature,
            },
            metrics = {
                plans = tonumber(self.metrics.plans) or 0,
                geometryApplies = tonumber(self.metrics.geometryApplies) or 0,
                geometryRejects = tonumber(self.metrics.geometryRejects) or 0,
                deoverlaps = tonumber(self.metrics.deoverlaps) or 0,
                reflows = tonumber(self.metrics.reflows) or 0,
                createFailures = tonumber(self.metrics.createFailures) or 0,
                fallbackPlacements = tonumber(self.metrics.fallbackPlacements) or 0,
            },
            deoverlap = layout and type(layout.GetScreenDeoverlapSnapshot) == "function" and layout:GetScreenDeoverlapSnapshot() or nil,
            buttons = {},
            events = {},
        }
        for _, event in ipairs(self.diagnostics or {}) do
            payload.events[#payload.events + 1] = { kind = event.kind, at = event.at, detail = event.detail }
        end
        local seen = {}
        local function Append(meta, record)
            local row = {
                profileId = tonumber(meta and meta.profileId) or (record and record.profileId),
                name = tostring((meta and meta.name) or ""),
                present = record ~= nil and record.present == true,
                created = record ~= nil,
                quick = meta and meta.quick == true or nil,
                quickPositionCustomized = meta and meta.quickPositionCustomized == true or nil,
                quickX = meta and meta.quickX or nil, quickY = meta and meta.quickY or nil,
                quickCoordinateSpace = meta and meta.quickCoordinateSpace or nil,
                quickAnchorH = meta and meta.quickAnchorH or nil, quickAnchorV = meta and meta.quickAnchorV or nil,
                quickOffsetX = meta and meta.quickOffsetX or nil, quickOffsetY = meta and meta.quickOffsetY or nil,
                hasViewportIntent = (ViewportIntentFromMeta(meta) ~= nil),
                intentSource = record and type(record.placementInfo) == "table" and record.placementInfo.intentSource or nil,
                placementSource = record and type(record.placementInfo) == "table" and record.placementInfo.placementSource or nil,
                viewportChanged = record and type(record.placementInfo) == "table" and record.placementInfo.viewportChanged or nil,
                clampApplied = record and type(record.placementInfo) == "table" and record.placementInfo.clampApplied or nil,
                fullyVisible = record and type(record.placementInfo) == "table" and record.placementInfo.fullyVisible or nil,
                deoverlapped = record and record.deoverlapped == true or false,
                resolvedX = record and record.lastX or nil, resolvedY = record and record.lastY or nil,
                geometryOk = record ~= nil and record.lastGeometryError == nil,
                geometryError = record and record.lastGeometryError or nil,
                visibleRequested = self.visible == true,
            }
            if record ~= nil and record.button ~= nil and layout ~= nil and type(layout.GetWindowLogicalRect) == "function" then
                local nx, ny, nw, nh = layout:GetWindowLogicalRect(record.button)
                row.nativeX, row.nativeY, row.nativeWidth, row.nativeHeight = nx, ny, nw, nh
                if type(record.button.IsVisible) == "function" then
                    local visibleOk, visibleValue = pcall(function() return record.button:IsVisible() end)
                    row.nativeVisible = visibleOk == true and visibleValue == true or false
                end
                if tonumber(nx) ~= nil and tonumber(ny) ~= nil and tonumber(nw) ~= nil and tonumber(nh) ~= nil then
                    row.inLogicalViewport = nx >= 0 and ny >= 0
                        and (nx + nw) <= (tonumber(context.logicalWidth) or 0) and (ny + nh) <= (tonumber(context.logicalHeight) or 0)
                    row.inPhysicalWindow = nx >= 0 and ny >= 0
                        and (nx + nw) <= (tonumber(context.screenWidth) or 0) and (ny + nh) <= (tonumber(context.screenHeight) or 0)
                end
            end
            payload.buttons[#payload.buttons + 1] = row
        end
        for _, meta in ipairs(self.rows or {}) do
            local id = tostring(meta.profileId or "")
            seen[id] = true
            Append(meta, self.buttons[id])
        end
        for id, record in pairs(self.buttons) do
            if seen[id] ~= true then Append(nil, record) end
        end
        return payload
    end

    return instance
end

local registered, registerErr = Host:Register(WIDGET_ID, {
    featureId = Feature.Id,
    create = CreateWidget,
    windowingRequired = false,
    ensurePreferences = function() return Feature:EnsureStoreLoaded() end,
    resettable = true,
    resetLayout = function()
        local instance = Host:GetInstance(WIDGET_ID)
        if instance and instance.ResetLayout then return instance:ResetLayout() end
        return Feature.Commands:ResetQuickPositions()
    end,
})
if registered ~= true then error(registerErr) end

-- 中文维护注释（2026-09-25，feature-profile-quick-diagnostics-1）：方案 Store 是否真的落盘、
-- 三个快捷按钮最终落在哪个 Native 矩形，必须能从模块诊断页直接读到。Provider 只读取已经存在的
-- widget 实例与缓存 rows，不 EnsureInstance、不创建 Native、不写 Store、不采样 metrics。
if type(S.ModuleDiagnosticsHub) == "table" and type(S.ModuleDiagnosticsHub.RegisterProvider) == "function" then
    S.ModuleDiagnosticsHub:RegisterProvider(Feature.Id, "feature_profile_quick_geometry", function()
        local instance = Host:GetInstance(WIDGET_ID)
        if instance == nil or type(instance.GetQuickButtonDiagnostics) ~= "function" then
            return { contractVersion = 1, created = false, note = "quick button widget instance not created yet" }
        end
        local payload = instance:GetQuickButtonDiagnostics()
        payload.created = true
        return payload
    end, 36)
end

------------------------------------------------------------------------
-- Presentation-owned visibility reaction. Profile mutations publish one
-- projection event; Host owns show/hide and lifecycle reactions.
------------------------------------------------------------------------
if S.Events and type(S.Events.SubscribeInternal) == "function" then
    local Reaction = { id = "v3:feature_profile_quick:host_reaction" }
    local function Sync(reason)
        local shouldShow = Feature:ShouldShowQuickButtons() == true
        if shouldShow == Host:IsVisible(WIDGET_ID) then
            if shouldShow then Host:NotifyProjectionChanged(WIDGET_ID, "profiles") end
            return true
        end
        local ok, err = Host:SetVisible(WIDGET_ID, shouldShow, { persist = false, source = tostring(reason or "feature_profile_sync") })
        if ok ~= true and S.DiagnosticsManager and type(S.DiagnosticsManager.ErrorRateLimited) == "function" then
            S.DiagnosticsManager:ErrorRateLimited("feature_profiles_v3", "FEATURE_PROFILE_QUICK_HOST_FAILED", 3000,
                "功能方案屏幕快捷按钮显示/隐藏失败", { error = tostring(err or "unknown"), reason = tostring(reason or "sync") })
        end
        return ok, err
    end

    Host:BindFeatureLifecycle(WIDGET_ID, {
        featureId = Feature.Id,
        enabled = function() return S.FeatureRuntime:IsEnabled(Feature.Id) == true end,
        preference = function() return Feature:ShouldShowQuickButtons() == true end,
    })
    S.Events:SubscribeInternal(Feature.UpdateTopic, Reaction, function(_, _, reason) Sync(reason) end)
    if S.FeatureRuntime:IsEnabled(Feature.Id) == true then Sync("feature_profile_widget_registered") end
end
