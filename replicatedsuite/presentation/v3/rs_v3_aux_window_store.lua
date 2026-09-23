------------------------------------------------------------------------
-- Replicated Suite V3 - Auxiliary Floating Window Store
--
-- Presentation-only persistence for movable auxiliary surfaces that do not own
-- business data.  The Store is registered at startup but loaded lazily on the
-- first auxiliary-window open, so a hidden detail/diagnostics surface has zero
-- SaveData read cost.  Feature/Service Authorities remain unchanged.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local P = S.Persistence
local Floating = S.RSUI and S.RSUI.FloatingSurface or nil
if type(P) ~= "table" or type(P.RegisterV3Store) ~= "function" or type(Floating) ~= "table" then return end

S.UIV3 = S.UIV3 or {}
local V3 = S.UIV3
local STORE_ID = "v3.presentation.aux_windows"
local SCHEMA = 2

-- 中文维护注释：只有真实可拖动/缩放、且没有自己 Feature Store 的辅助窗进入此表。
-- 不允许业务字段加入这里，否则会形成 Presentation 与 Feature 的双 Authority。
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
    -- 中文维护注释（2026-09-18，module-diagnostics-1）：模块诊断窗只有 Presentation 几何进入
    -- AuxWindow Store；报告正文、页码、moduleId 都是 Session 冷快照，禁止持久化，避免诊断自己污染业务/存档。
    module_diagnostics = {
        defaultWidth = 760, defaultHeight = 590, minWidth = 560, minHeight = 380,
        defaultOverallOpacity = 0.98, defaultBackgroundOpacity = 1.0, defaultTextOpacity = 1.0,
        defaultFontScale = 1.0, minFontScale = 0.85, maxFontScale = 1.20,
    },
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
local HISTORICAL_POLICY_SETS = {
    -- 中文维护注释（2026-09-22，aux-window-canonical-recovery-1）：quest_detail 在原 schema1 发布后
    -- 才加入 POLICIES，但旧 NormalizeState 会对“缺失窗口”主动补默认表。于是仅新增一个窗口类型就改变了
    -- 整个 Store canonical，旧用户即使磁盘内容完全健康也会被 Integrity v4 fence。以下历史集合冻结真实
    -- 发布过的 Presentation policy 代际；候选只有重新计算后精确命中旧 stamped fingerprint 才能恢复。
    { id = "pre_quest_detail", policies = { "trade_detail", "trade_diagnostics", "module_diagnostics" } },
    { id = "pre_module_diagnostics", policies = { "trade_detail", "trade_diagnostics" } },
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
    return NormalizeStateWithPolicies(value, CURRENT_POLICY_IDS)
end

local function RebuildHistoricalCanonical(decoded, stampedFingerprint, _currentCanonical, raw)
    local meta = type(raw) == "table" and raw.__rsmeta or nil
    local store = P:GetStore(STORE_ID)
    if type(store) ~= "table" then return nil end
    if type(meta) ~= "table" or tostring(meta.store or "") ~= STORE_ID
        or tostring(meta.owner or "") ~= "v3.presentation.aux_windows" or tonumber(meta.schema) ~= 1 then
        store.lastHistoricalRecoveryProbe = "aux_policy/skip_generation"
        return nil
    end
    for _, candidateSpec in ipairs(HISTORICAL_POLICY_SETS) do
        local candidate = NormalizeStateWithPolicies(decoded, candidateSpec.policies)
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

function A:GetWindowState(id)
    id = tostring(id or "")
    if POLICIES[id] == nil then return nil, "unknown auxiliary window: " .. id end
    local ok, err = self:EnsureLoaded()
    if ok ~= true then return nil, err end
    return Copy(NormalizeWindow(id, self.state[id]))
end

function A:SetWindowState(id, value, reason)
    id = tostring(id or "")
    if POLICIES[id] == nil then return false, "unknown auxiliary window: " .. id end
    local ok, err = self:EnsureLoaded()
    if ok ~= true then return false, err end
    -- 中文维护注释：FloatingSurface 先 Commit state、再调用 Persist；这里只更新
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
    return P:MarkDirty(STORE_ID, tonumber(delayMs) or 250,
        "aux_window:" .. id .. ":" .. tostring(reason or "state"))
end
