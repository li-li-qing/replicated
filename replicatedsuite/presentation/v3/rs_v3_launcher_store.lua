-- Replicated Suite · 启动器位置存储
-- 作者：Replicated
-- QQ群：1104129461
-- R 入口早于 Persistence 创建；Foundation 就绪后再接账户 Store，启动失败时仍须可用。
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local P = S.Persistence
if type(P) ~= "table" or type(P.RegisterV3Store) ~= "function" then return end

S.UIV3 = S.UIV3 or {}
local V3 = S.UIV3
V3.LauncherState = type(V3.LauncherState) == "table" and V3.LauncherState or {
    userMoved = false,
}

local STORE_ID = "v3.launcher"
local LAUNCHER_LOGICAL_SIZE = 30
local function Normalize(value)
    value = type(value) == "table" and value or {}
    local moved = value.userMoved == true
    local free = moved and tostring(value.coordinateSpace or "") == "logical-free-v2"
        and tonumber(value.x) ~= nil and tonumber(value.y) ~= nil
    return {
        userMoved = moved,
        locked = value.locked == true and true or nil, -- 未锁定不写新键，旧 schema2 位置 canonical 保持不变。
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

local function Apply(value)
    local normalized = Normalize(value)
    for k in pairs(V3.LauncherState) do V3.LauncherState[k] = nil end
    for k,v in pairs(normalized) do V3.LauncherState[k] = v end
end

if P:GetStore(STORE_ID) == nil then
    P:RegisterV3Store({
        id = STORE_ID,
        owner = "v3.launcher",
        scope = P.Scope.Account,
        lifetime = P.Lifetime.Permanent,
        schemaVersion = 2,
        legacySchemaVersion = 1,
        key = P.V3KeyPrefix .. "launcher",
        budget = { maxDepth = 4, maxNodes = 40, maxStringBytes = 512, maxEntriesPerTable = 24 },
        default = function() return Normalize(nil) end,
        get = function() return Normalize(V3.LauncherState) end,
        apply = Apply,
        migrate = function(value) return Normalize(value) end,
    })
end

V3.LauncherStoreId = STORE_ID
V3.LauncherStoreLoaded = V3.LauncherStoreLoaded == true
V3.LauncherStoreSessionFallback = V3.LauncherStoreSessionFallback == true
V3.LauncherStoreLoadError = V3.LauncherStoreLoadError

function V3:UseLauncherSessionDefaults(reason)
    Apply(nil)
    self.LauncherStoreLoaded = true
    self.LauncherStoreSessionFallback = true
    self.LauncherStoreLoadError = tostring(reason or "launcher store load failed")
    if S.DiagnosticsManager ~= nil and type(S.DiagnosticsManager.Warn) == "function" then
        S.DiagnosticsManager:Warn("ui_v3", "LAUNCHER_STORE_SESSION_FALLBACK",
            "启动按钮存档读取失败；本次会话使用默认位置，不以降级值主动覆盖原存档",
            { error = self.LauncherStoreLoadError })
    end
    return true
end

function V3:EnsureLauncherStoreLoaded()
    if self.LauncherStoreLoaded == true then return true end
    local store = P:GetStore(STORE_ID)
    if store == nil then return self:UseLauncherSessionDefaults("启动按钮存档不可用") end
    local status, _, err = P:LoadStore(STORE_ID)
    if status == true or status == "empty" then
        if status == "empty" then Apply(nil) end
        self.LauncherStoreLoaded = true
        self.LauncherStoreSessionFallback = false
        self.LauncherStoreLoadError = nil
        return true
    end
    return self:UseLauncherSessionDefaults(err or tostring(status or "读取失败"))
end

function V3:MarkLauncherStoreDirty(delayMs, reason)
    if self.LauncherStoreSessionFallback == true then return true, "session_fallback_no_persist" end
    -- 拖动结束、锁定和恢复须在返回前写盘并回读；MarkDirty(0) 仍等下一帧，立即退出可能丢值。
    -- 拒写时回滚 Native 与 LauncherState；普通显示和视口重排不写盘。

    if reason == "launcher_drag" or reason == "launcher_lock" or reason == "launcher_reset" then return P:SaveStore(STORE_ID, { durable=true, consumeDirty=true, reason=reason }) end
    return P:MarkDirty(STORE_ID, tonumber(delayMs) or 250, reason or "launcher_changed")
end

-- R 是独立屏幕按钮，不是内容窗口；只由 Layout 解析 logical 坐标，Windowing 提交 Native。
-- 空/未拖动 Store 必须传默认 intent，旧 ApplyPlacement({userMoved=false}) 会误落入 LEFT/TOP=0。
-- UI Scale 不再乘除 x/y，30 是 logical 尺寸；创建/明确恢复才补采样，metrics 回调复用当前 context。
local function ApplyLauncherRect(state, reason, fresh)
    local button, L = S.RecoveryEntry, S.Layout
    if button == nil or L == nil then return false, "launcher_geometry_unavailable" end
    L:GetContext(fresh == true)
    local x,y,w,h,info = L:ResolvePlacement(state,LAUNCHER_LOGICAL_SIZE,LAUNCHER_LOGICAL_SIZE,300,100,
        {mode="strict",topLevel=true,topReachHeight=LAUNCHER_LOGICAL_SIZE,reason=reason})
    local windowing = S.RSUI and S.RSUI.Windowing
    local ok,err
    if windowing and type(windowing.ApplyGeometry)=="function" then
        ok,err = windowing:ApplyGeometry(button,"v3:launcher",x,y,w,h,true)
    else
        -- Bootstrap 早于 RSUI；仅保留同一 solver 结果的最小 Native 提交，不能增加第二套坐标算法。
        -- nil 返回仍兼容 RU setters；显式 false/异常必须向恢复入口反馈，不以假成功写 Store。
        ok,err = pcall(function()
            if button:SetExtent(w,h)==false then error("launcher_extent_rejected") end
            if button:RemoveAllAnchors()==false then error("launcher_clear_anchor_rejected") end
            if button:AddAnchor("TOPLEFT","UIParent",x,y)==false then error("launcher_anchor_rejected") end
        end)
    end
    V3.LauncherPlacementInfo=info
    if info then info.nativeError=ok~=true and tostring(err or "launcher_geometry_rejected") or nil end
    return ok==true,err
end

function V3:ApplyLauncherPlacement()
    local ok,err=ApplyLauncherRect(self.LauncherState,"show",true)
    -- 恢复入口仍由 Bootstrap 持有 Native 拖动；读取存档后同步已有 EnableDrag，不改变点击/恢复用途。
    if S.RecoveryEntry and type(S.RecoveryEntry.EnableDrag) == "function" then
        local called, accepted = pcall(S.RecoveryEntry.EnableDrag, S.RecoveryEntry, self.LauncherState.locked ~= true)
        if not called or accepted == false then return false, "启动按钮锁状态应用失败" end
    end
    if S.Layout and type(S.Layout.RegisterFloating)=="function" and S.RecoveryEntry then
        S.Layout:RegisterFloating("v3_launcher",S.RecoveryEntry,{
            ensureNow=false,onlyWhenVisible=true,
            -- R 入口复用全局有界恢复，但绝不接管原生拖动。
            positionOwner="v3:launcher",
            isPositionInteracting=function()return S.RecoveryEntry.rsMoving==true end,
            getPlacementDiagnostics=function()return V3.LauncherPlacementInfo end,
            onMetricsChanged=function()return ApplyLauncherRect(V3.LauncherState,"resolution_migration",false)end,
        })
    end
    if S.Layout and type(S.Layout.RegisterScreenSnap)=="function" and S.RecoveryEntry then
        S.Layout:RegisterScreenSnap("v3_launcher",S.RecoveryEntry,{
            snapGroup="screen_buttons",snapKind="button",snapDistance=16,snapGap=0,
        })
    end
    return ok,err
end

function V3:SetLauncherLocked(value)
    -- 锁状态沿用 Launcher Store；先接受 Native 再提交偏好，失败恢复同一状态，不增加窗口位置副本。
    local loaded, loadErr = self:EnsureLauncherStoreLoaded(); if loaded ~= true then return false, loadErr end
    local button, state = S.RecoveryEntry, self.LauncherState
    if button == nil or type(button.EnableDrag) ~= "function" then return false, "启动按钮拖动能力不可用" end
    if button.rsMoving == true then return false, "请先结束启动按钮拖动" end
    local locked, previous = value == true, state.locked
    local called, accepted = pcall(button.EnableDrag, button, not locked)
    if not called or accepted == false then return false, "启动按钮锁状态应用失败" end
    state.locked = locked and true or nil
    local ok, err = self:MarkLauncherStoreDirty(0, "launcher_lock")
    if ok ~= true then state.locked = previous; pcall(button.EnableDrag, button, previous ~= true); return false, err end
    return true
end

function V3:ResetLauncherPlacement(persist)
    local state,button=self.LauncherState,S.RecoveryEntry
    if type(state)~="table" or button==nil then return false,"launcher_unavailable" end
    -- 显式 Reset 先撤销手势资格，Native 接受后才改 Store；旧 metadata 不参与默认解析。
    -- 不在普通 Show/metrics 写入，失败保留原始缺失键；schema/Normalize 完全不变。
    if button.rsMoving and type(button.StopMovingOrSizing)=="function" then pcall(button.StopMovingOrSizing,button) end
    button.rsMoving,button.rsIgnoreClick=false,false
    button.rsDragStartX,button.rsDragStartY,button.rsGeometryUnitScale,button.rsDragViewport=nil,nil,nil,nil
    local before={};for k,v in pairs(state)do before[k]=v end
    local ok,err=ApplyLauncherRect({userMoved=false},"explicit_reset",true)
    if ok~=true then return false,err end
    if S.UI and type(S.UI.EnsureVisible)=="function" then
        if type(S.UI.InvalidateNativeState)=="function" then S.UI:InvalidateNativeState(button,"visible") end
        local accepted,_,detail=S.UI:EnsureVisible(button,true,"v3:launcher")
        ok,err=accepted,detail
    else
        local called,result=pcall(button.Show,button,true);ok=called and result~=false;err=result
    end
    if ok~=true then ApplyLauncherRect(before,"reset_rollback",false);return false,err or "launcher_show_rejected" end
    Apply({locked=before.locked}) -- 恢复位置保留用户的锁偏好，与 FloatingSurface reset 一致；不能只清偏好而留下 Native 禁止拖动。
    if persist~=false then ok,err=self:MarkLauncherStoreDirty(0,"launcher_reset") end
    if ok~=true then
        for k in pairs(state)do state[k]=nil end;for k,v in pairs(before)do state[k]=v end
        ApplyLauncherRect(before,"reset_rollback",false)
        return false,err
    end
    return true
end
