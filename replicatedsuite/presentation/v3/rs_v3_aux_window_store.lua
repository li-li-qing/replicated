-- Replicated Suite · 辅助窗口位置存储
-- 作者：Replicated
-- QQ群：1104129461
-- 辅助窗只保存几何，首次打开才加载 Store，避免隐藏详情和诊断窗产生读盘成本。
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local P = S.Persistence
local Floating = S.RSUI and S.RSUI.FloatingSurface or nil
if type(P) ~= "table" or type(P.RegisterV3Store) ~= "function" or type(Floating) ~= "table" then return end

S.UIV3 = S.UIV3 or {}
local V3 = S.UIV3
local STORE_ID = "v3.presentation.aux_windows"
local SCHEMA = 2

-- 只收纳可拖动或缩放、且没有 Feature Store 的辅助窗；业务字段留在 Feature。
local POLICIES = {
    trade_detail = {
        defaultWidth = 620, defaultHeight = 440, minWidth = 470, minHeight = 300,
        defaultOverallOpacity = 0.96, defaultBackgroundOpacity = 1.0, defaultTextOpacity = 1.0,
        defaultFontScale = 1.0, minFontScale = 0.80, maxFontScale = 1.25,
    },
    trade_diagnostics = {
        defaultWidth = 700, defaultHeight = 520, minWidth = 520, minHeight = 340,
        defaultOverallOpacity = 0.96, defaultBackgroundOpacity = 1.0, defaultTextOpacity = 1.0,
        defaultFontScale = 1.0, minFontScale = 0.80, maxFontScale = 1.25,
    },
    quest_detail = {
        defaultWidth = 560, defaultHeight = 420, minWidth = 420, minHeight = 260,
        defaultOverallOpacity = 0.96, defaultBackgroundOpacity = 1.0, defaultTextOpacity = 1.0,
        defaultFontScale = 1.0, minFontScale = 0.80, maxFontScale = 1.25,
    },
    -- 诊断窗只保存几何；报告、页码和 moduleId 都是本次会话的冻结快照。
    module_diagnostics = {
        defaultWidth = 760, defaultHeight = 590, minWidth = 560, minHeight = 380,
        defaultOverallOpacity = 0.98, defaultBackgroundOpacity = 1.0, defaultTextOpacity = 1.0,
        defaultFontScale = 1.0, minFontScale = 0.85, maxFontScale = 1.20,
    },
    trade_settings = { defaultWidth=380, defaultHeight=320, minWidth=320, minHeight=294 },
    bonds_settings = { defaultWidth=380, defaultHeight=210, minWidth=320, minHeight=190 },
    bag_settings = { defaultWidth=530, defaultHeight=430, minWidth=410, minHeight=300 },
    player_notes = { defaultWidth=420, defaultHeight=460, minWidth=420, maxWidth=1000, minHeight=460, maxHeight=1000, defaultLocked=false },
}

local function Copy(value)
    if S.Utils ~= nil and type(S.Utils.DeepCopy) == "function" then return S.Utils.DeepCopy(value) end
    if type(value) ~= "table" then return value end
    local out = {}
    for key, item in pairs(value) do out[key] = Copy(item) end
    return out
end

local function NormalizeWindow(id, value)
    local policy = POLICIES[tostring(id or "")]
    if policy == nil then return nil end
    return Floating:NormalizeState(value, policy)
end

local CURRENT_POLICY_IDS = { "trade_detail", "trade_diagnostics", "quest_detail", "module_diagnostics" }
local OPTIONAL_POLICY_IDS = { "trade_settings", "bonds_settings", "bag_settings", "player_notes" }
local HISTORICAL_POLICY_SETS = {
    -- schema1 后新增 quest_detail，旧规范会为缺失窗口补默认表，改变健康旧档的 canonical。
    -- 以下集合对应实际发布过的 policy 组合，只在重新计算精确命中旧章时恢复。
    { id = "pre_quest_detail", policies = { "trade_detail", "trade_diagnostics", "module_diagnostics" } },
    { id = "pre_module_diagnostics", policies = { "trade_detail", "trade_diagnostics" } },
    -- 原档 RS-20261002-195813-365029-1.2 已有 quest_detail、没有 module_diagnostics。
    -- 三窗 canonical 重现旧章 782943CD，补第四窗后为 188C8DDF，Transport3 数值未丢失。
    -- 仅补有此证据的 policy 集合；已有诊断窗时不能忽略它来求匹配。
    { id = "schema1_quest_without_module", policies = { "trade_detail", "trade_diagnostics", "quest_detail" }, absentWindow = "module_diagnostics" },
}

local function NormalizeStateWithPolicies(value, ids)
    value = type(value) == "table" and value or {}
    local out = {}
    for _, id in ipairs(type(ids) == "table" and ids or {}) do
        if POLICIES[id] ~= nil then out[id] = NormalizeWindow(id, value[id]) end
    end
    return out
end

local function NormalizeState(value)
    local out = NormalizeStateWithPolicies(value, CURRENT_POLICY_IDS)
    -- 新增辅助窗仅在首次真实提交后进入存档；缺失项不补默认，保持已发布 schema2 的旧 canonical 完全不变。
    for _, id in ipairs(OPTIONAL_POLICY_IDS) do
        if type(value) == "table" and type(value[id]) == "table" then out[id] = NormalizeWindow(id, value[id]) end
    end
    return out
end

local function RebuildHistoricalCanonical(decoded, stampedFingerprint, _currentCanonical, raw)
    -- schema1 历史指纹从未覆盖这些新增窗口；不能在恢复旧章时夹带未经校验的新布局。
    for _, id in ipairs(OPTIONAL_POLICY_IDS) do if type(decoded) == "table" and decoded[id] ~= nil then return nil end end
    local meta = type(raw) == "table" and raw.__rsmeta or nil
    local store = P:GetStore(STORE_ID)
    if type(store) ~= "table" then return nil end
    if type(meta) ~= "table" or tostring(meta.store or "") ~= STORE_ID
        or tostring(meta.owner or "") ~= "v3.presentation.aux_windows" or tonumber(meta.schema) ~= 1 then
        store.lastHistoricalRecoveryProbe = "aux_policy/skip_generation"
        return nil
    end
    for _, candidateSpec in ipairs(HISTORICAL_POLICY_SETS) do
        -- 缺失窗口是这代结构的前置条件；只在真实缺失时构造历史见证。
        -- Core 仍负责整份旧章、身份/envelope/预算校验，匹配后才允许迁移并恢复原有写入生命周期。
        local eligible = candidateSpec.absentWindow == nil or (type(decoded) == "table" and decoded[candidateSpec.absentWindow] == nil)
        local candidate = eligible and NormalizeStateWithPolicies(decoded, candidateSpec.policies) or nil
        local fingerprint = P:FingerprintCanonicalValue(store, candidate)
        if fingerprint ~= nil and tostring(fingerprint) == tostring(stampedFingerprint) then
            store.lastHistoricalRecoveryProbe = "aux_policy/" .. tostring(candidateSpec.id) .. "/match"
            -- 第二返回值是当前 Domain：保留历史窗口几何，并按 schema2 增加 quest_detail 默认窗口。
            return candidate, NormalizeState(decoded)
        end
    end
    store.lastHistoricalRecoveryProbe = "aux_policy/no_match"
    return nil
end

V3.AuxWindowStoreV3 = type(V3.AuxWindowStoreV3) == "table" and V3.AuxWindowStoreV3 or {
    version = 2,
    contractVersion = 2,
    storeId = STORE_ID,
    loaded = false,
    state = NormalizeState(nil),
}
local A = V3.AuxWindowStoreV3
A.version = 2
A.contractVersion = 2
A.HistoricalPolicyRecoveryContractVersion = 1
A.storeId = STORE_ID
A.policies = POLICIES

local function Apply(value)
    A.state = NormalizeState(value)
end

if P:GetStore(STORE_ID) == nil then
    local store, err = P:RegisterV3Store({
        id = STORE_ID,
        owner = "v3.presentation.aux_windows",
        scope = P.Scope.Account,
        lifetime = P.Lifetime.Permanent,
        schemaVersion = SCHEMA,
        legacySchemaVersion = 1,
        key = P.V3KeyPrefix .. "presentation_aux_windows",
        budget = { maxDepth = 6, maxNodes = 320, maxStringBytes = 4096, maxEntriesPerTable = 64 },
        default = function() return NormalizeState(nil) end,
        get = function() return NormalizeState(A.state) end,
        apply = Apply,
        migrate = function(value) return NormalizeState(value) end,
        rebuildCanonicalForIntegrity = RebuildHistoricalCanonical,
        allowIntegrityUpgrade = true,
    })
    if store == nil and S.DiagnosticsManager ~= nil and type(S.DiagnosticsManager.Error) == "function" then
        S.DiagnosticsManager:Error("ui_v3", "AUX_WINDOW_STORE_REGISTER_FAILED",
            "辅助悬浮窗布局存档注册失败", { error = tostring(err or "unknown") })
    end
end

function A:EnsureLoaded()
    if self.loaded == true and type(P.IsStoreLoaded) == "function" and P:IsStoreLoaded(STORE_ID) == true then return true end
    local status, _, err = P:LoadStore(STORE_ID)
    if status ~= true and status ~= "empty" then return false, err or tostring(status or "辅助窗口布局读取失败") end
    if status == "empty" then Apply(nil) end
    self.loaded = true
    return true
end

function A:GetPolicy(id)
    return Copy(POLICIES[tostring(id or "")])
end

function A:GetWindowState(id, legacyWindowId)
    id = tostring(id or "")
    if POLICIES[id] == nil then return nil, "unknown auxiliary window: " .. id end
    local ok, err = self:EnsureLoaded()
    if ok ~= true then return nil, err end
    local state = Copy(NormalizeWindow(id, self.state[id]))
    -- 原会话设置窗的小锁已由 Chrome 保存；首次提交完整布局前继承它，之后只由本 Store 持有窗口状态。
    local preferences = S.RSUI and S.RSUI.WindowPreferences
    if self.state[id] == nil and legacyWindowId ~= nil and type(preferences) == "table" and type(preferences.GetLocked) == "function" then
        state.locked = preferences:GetLocked(legacyWindowId) == true
    end
    return state
end

function A:SetWindowState(id, value, reason)
    id = tostring(id or "")
    if POLICIES[id] == nil then return false, "unknown auxiliary window: " .. id end
    local ok, err = self:EnsureLoaded()
    if ok ~= true then return false, err end
    -- FloatingSurface 先 Commit state、再调用 Persist；这里只更新
    -- Presentation Domain，不直接 SaveData。若后续 MarkDirty 失败，Floating transaction
    -- 会把 before-state 回滚回来，因此不会出现“视觉位置已变、Store Authority 未提交”。
    self.state[id] = NormalizeWindow(id, value)
    return true
end

function A:PersistWindow(id, reason, delayMs)
    id = tostring(id or "")
    if POLICIES[id] == nil then return false, "unknown auxiliary window: " .. id end
    local ok, err = self:EnsureLoaded()
    if ok ~= true then return false, err end
    -- 详情/诊断窗也必须跨立即重载保留位置；不依赖下一次保存心跳。
    -- 辅助窗小锁归本 Store；标题按钮 lock 与公开 API locked 均须在返回前写入并回读，保留 false 解锁值。
    -- NumericField 连续预览不走此入口；外观最终提交须立即回读，保留原 Store Authority 与失败回滚。
    if reason == "geometry" or reason == "layout_reset" or reason == "minimized" or reason == "locked" or reason == "lock"
        or reason == "overall_opacity" or reason == "background_opacity" or reason == "text_opacity" or reason == "font_scale" then
        return P:SaveStore(STORE_ID, { durable=true, consumeDirty=true, reason="aux_window:" .. id .. ":" .. reason })
    end
    return P:MarkDirty(STORE_ID, tonumber(delayMs) or 250,
        "aux_window:" .. id .. ":" .. tostring(reason or "state"))
end
