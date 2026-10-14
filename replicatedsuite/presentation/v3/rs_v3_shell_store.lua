------------------------------------------------------------------------
-- Replicated Suite · 主窗口状态存储
-- 作者：Replicated
-- QQ群：1104129461
--
-- 仅保存应用窗口偏好，不存 Domain/Feature 状态。Schema v7 保留显式 V3 自由位置和响应式来源视口信息；
-- Schema v6 是精确完整性恢复的只读历史规范，不升 schema 不能改变规范形状。旧边缘位置仅重新居中一次，避免继承左上角默认值；Windowing 仅在调用方明确选择时添加语义最小/最大值。
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local P = S.Persistence
if type(P) ~= "table" or type(P.RegisterV3Store) ~= "function" then return end

S.UIV3 = S.UIV3 or {}
local V3 = S.UIV3
V3.ShellSizePolicy = {
    defaultWidth = 1040,
    defaultHeight = 700,
    minWidth = 1,
    minHeight = 1,
}
local SIZE = V3.ShellSizePolicy
V3.ShellState = type(V3.ShellState) == "table" and V3.ShellState or {
    width = SIZE.defaultWidth,
    height = SIZE.defaultHeight,
    lastRoute = "home",
    minimized = false,
    locked = false,
    userMoved = false,
}

local STORE_ID = "v3.shell"
local function AtLeast(value, minimum, fallback)
    local number = tonumber(value) or tonumber(fallback) or minimum
    return math.max(minimum, number)
end
local function NormalizeState(value)
    value = type(value) == "table" and value or {}
    local requestedMoved = value.userMoved == true
    local free = requestedMoved and tostring(value.coordinateSpace or "") == "logical-free-v2"
        and tonumber(value.x) ~= nil and tonumber(value.y) ~= nil
    -- Edge-v1 属于废弃 Shell 位置模型；旧 LEFT/TOP 零偏移会让重建菜单持续在角落打开，只有显式 V3 自由位置才具有权威性。
    local moved = free
    return {
        width = AtLeast(value.width, SIZE.minWidth, SIZE.defaultWidth),
        height = AtLeast(value.height, SIZE.minHeight, SIZE.defaultHeight),
        lastRoute = (tostring(value.lastRoute or "home") == "foundation") and "home" or tostring(value.lastRoute or "home"),
        minimized = value.minimized == true,
        locked = value.locked == true,
        userMoved = moved,
        x = moved and tonumber(value.x) or nil,
        y = moved and tonumber(value.y) or nil,
        anchorH = nil,
        anchorV = nil,
        offsetX = nil,
        offsetY = nil,
        coordinateSpace = moved and "logical-free-v2" or nil,
        savedUiScale = moved and tonumber(value.savedUiScale) or nil,
        savedLogicalWidth = moved and tonumber(value.savedLogicalWidth) or nil,
        savedLogicalHeight = moved and tonumber(value.savedLogicalHeight) or nil,
        normalizedCenterX = moved and tonumber(value.normalizedCenterX) or nil,
        normalizedCenterY = moved and tonumber(value.normalizedCenterY) or nil,
    }
end

-- 历史 schema-v6 规范必须保持不可变且边界严格：旧版本添加响应式元数据却未升级 schema，Lua 会省略 nil 字段，不能保证所有旧载荷失配，也失去代际区分。
-- Persistence 仅在当前 v4 不匹配后尝试，并要求逐字节重现已标记旧指纹且独立封印有效；未知/损坏载荷仍拒绝。
local function NormalizeHistoricalV6(value)
    value = type(value) == "table" and value or {}
    local requestedMoved = value.userMoved == true
    local free = requestedMoved and tostring(value.coordinateSpace or "") == "logical-free-v2"
        and tonumber(value.x) ~= nil and tonumber(value.y) ~= nil
    local moved = free
    return {
        width = AtLeast(value.width, SIZE.minWidth, SIZE.defaultWidth),
        height = AtLeast(value.height, SIZE.minHeight, SIZE.defaultHeight),
        lastRoute = (tostring(value.lastRoute or "home") == "foundation") and "home" or tostring(value.lastRoute or "home"),
        minimized = value.minimized == true,
        locked = value.locked == true,
        userMoved = moved,
        x = moved and tonumber(value.x) or nil,
        y = moved and tonumber(value.y) or nil,
        anchorH = nil,
        anchorV = nil,
        offsetX = nil,
        offsetY = nil,
        coordinateSpace = moved and "logical-free-v2" or nil,
        savedUiScale = moved and tonumber(value.savedUiScale) or nil,
    }
end

V3.ShellCanonicalMigrationContractVersion = 1
V3.ShellStoreSchemaContractVersion = 7
V3.ShellKnownLegacyRecoveryContractVersion = 1

-- 实机事件身份：在 `.18.184` 与 `.18.187` 观测结果一致；stamped v4 = 2EA0A82A，current canonical = 2EC2F5C5。
--
-- 此处不是通用 Shell 失配放行口；Persistence 仅在封印、元数据、解码、预算和精确历史重建按要求检查后调用。额外要求精确新旧指纹对与 schema 6；
-- 按 Death Review 的一次性 Store 迁移模式保留已验证 UI 载荷，立即重标 schema 7，未知指纹继续隔离。
local KNOWN_V6_STAMP = "2EA0A82A"
local KNOWN_V7_CANONICAL = "2EC2F5C5"
local SHELL_BUDGET = { maxDepth = 5, maxNodes = 80, maxStringBytes = 2048, maxEntriesPerTable = 40 }

local function RecoverKnownV6Shell(decoded, stampedFingerprint, currentCanonical, raw)
    local meta = type(raw) == "table" and raw.__rsmeta or nil
    if type(meta) ~= "table" or tonumber(meta.schema) ~= 6
        or tostring(meta.store or "") ~= STORE_ID
        or tostring(meta.owner or "") ~= "v3.shell" then
        return nil
    end
    if tostring(stampedFingerprint or "") ~= KNOWN_V6_STAMP then return nil end
    if type(decoded) ~= "table" or type(currentCanonical) ~= "table" then return nil end

    -- 再次规范化，不能返回原始解码数据；恢复前由当前 schema 权威层丢弃未知/旧 key。
    local normalized = NormalizeState(decoded)
    local currentFingerprint = P:FingerprintDurablePayload(normalized, SHELL_BUDGET)
    if tostring(currentFingerprint or "") ~= KNOWN_V7_CANONICAL then return nil end
    return normalized, "shell_v6_known_stamp_2EA0A82A"
end

local function Apply(value)
    local normalized = NormalizeState(value)
    for key in pairs(V3.ShellState) do V3.ShellState[key] = nil end
    for key, item in pairs(normalized) do V3.ShellState[key] = item end
end

if P:GetStore(STORE_ID) == nil then
    local store, err = P:RegisterV3Store({
        id = STORE_ID,
        owner = "v3.shell",
        scope = P.Scope.Account,
        lifetime = P.Lifetime.Permanent,
        schemaVersion = 7,
        legacySchemaVersion = 6,
        key = P.V3KeyPrefix .. "shell",
        budget = SHELL_BUDGET,
        default = function() return NormalizeState(nil) end,
        get = function() return NormalizeState(V3.ShellState) end,
        apply = Apply,
        migrate = function(value) return NormalizeState(value) end,
        -- 精确 v6 -> v7 规范桥；原始元数据检查防止当前/未来 schema 使用历史候选。Persistence 自行计算候选哈希，仅等于已标记旧指纹时接受。
        rebuildCanonicalForIntegrity = function(decoded, _stampedFingerprint, _currentCanonical, raw)
            local meta = type(raw) == "table" and raw.__rsmeta or nil
            if type(meta) ~= "table" or tonumber(meta.schema) ~= 6 then return nil end
            return NormalizeHistoricalV6(decoded)
        end,
        -- 已知 `.18.184/.18.187` RU 事件的一次性桥：上方精确历史重建优先，此钩子仅处理已知指纹对，否则返回 nil。
        recoverKnownLegacyCanonical = RecoverKnownV6Shell,
    })
    if store == nil and S.DiagnosticsManager ~= nil and type(S.DiagnosticsManager.Error) == "function" then
        S.DiagnosticsManager:Error("ui_v3", "SHELL_STORE_REGISTER_FAILED", "新版主窗口存档注册失败", { error = tostring(err) })
    end
end

V3.ShellStoreId = STORE_ID
V3.ShellStoreLoaded = V3.ShellStoreLoaded == true
V3.ShellStoreSessionFallback = V3.ShellStoreSessionFallback == true
V3.ShellStoreLoadError = V3.ShellStoreLoadError

function V3:UseShellSessionDefaults(reason)
    Apply(nil)
    self.ShellStoreLoaded = true
    self.ShellStoreSessionFallback = true
    self.ShellStoreLoadError = tostring(reason or "shell store load failed")
    if S.DiagnosticsManager ~= nil and type(S.DiagnosticsManager.Warn) == "function" then
        S.DiagnosticsManager:Warn("ui_v3", "SHELL_STORE_SESSION_FALLBACK",
            "主窗口存档读取失败；本次会话使用默认窗口状态，原存档不会因降级启动被主动覆盖",
            { error = self.ShellStoreLoadError })
    end
    return true
end

function V3:EnsureShellStoreLoaded()
    if self.ShellStoreLoaded == true then return true end
    local store = P:GetStore(STORE_ID)
    if store == nil then return self:UseShellSessionDefaults("新版主窗口存档不可用") end
    local status, _, err = P:LoadStore(STORE_ID)
    if status == true or status == "empty" then
        if status == "empty" then Apply(nil) end
        self.ShellStoreLoaded = true
        self.ShellStoreSessionFallback = false
        self.ShellStoreLoadError = nil
        return true
    end
    return self:UseShellSessionDefaults(err or tostring(status or "读取失败"))
end

function V3:MarkShellStoreDirty(delayMs, reason)
    if P:GetStore(STORE_ID) == nil then return false, "新版主窗口存档不可用" end
    -- 会话兜底仅在内存中生效；导航/几何可继续变化，但不能把受保护的读取失败变成 WRITE_BEFORE_LOAD 噪声或覆盖最后可恢复存档。
    if self.ShellStoreSessionFallback == true then return true, "session_fallback_no_persist" end
    return P:MarkDirty(STORE_ID, tonumber(delayMs) or 750, reason or "shell_changed")
end
