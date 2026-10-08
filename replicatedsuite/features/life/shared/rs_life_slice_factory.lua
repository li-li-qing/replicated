------------------------------------------------------------------------
-- Replicated Suite V3 - Life Slice Factory（Phase 2 Step 1，2026-09-28）
--
-- 中文维护注释（FND-002 / Phase 2）：rs_life_m16_bundle.lua（5633 行 / 4 个 Feature）正按 §24 的
-- 固定顺序（Treasure → Fishing → Bonds → Trade）拆成独立源码单元。与 Phase 1 的做法一致，
-- 先把 bundle 头部的共享装配 helper 原样收敛到这里，让每个 life Feature 在自己的文件里注册。
--
-- Authority 边界（与 Phase 1 工厂同一条纪律）：
--   * 本文件只认识 Core / Persistence / FeatureRuntime / Demand / Events / RSUI FloatingSurface / API boundary；
--   * 不认识 Trade / Bonds / Treasure / Fishing 的任何业务 State；
--   * 不建立第二个 Registry/Runtime/Demand，不改变 Store ID/Schema、Demand owner、UpdateTopic、Commands。
-- 注意：这些 helper 的行为与拆分前逐字一致，**没有**与 Phase 1 的 rs_feature_slice_factory.lua 合并 ——
-- 两者的 Copy/RegisterStore/LoadStore 语义不同（life 版 migrate/canonical/budget 参数是 §24.3 的冻结契约）。
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local P = S.Persistence
if type(P) ~= "table" then return end

local function Copy(value)
    if S.Utils and type(S.Utils.DeepCopy) == "function" then return S.Utils.DeepCopy(value) end
    return value
end

local function Call(capability, object, method, ...)
    if S.Api == nil or type(S.Api.CallCapability) ~= "function" then
        return false, nil, "API boundary unavailable"
    end
    -- API namespaces are imported lazily by FeatureRuntime after this file is
    -- loaded. A load-time rawget may therefore be nil even though the namespace
    -- becomes valid before the first feature read. Let the central API boundary
    -- resolve a nil host from the registered capability at call time.
    local host = object
    if host == nil or (method and host[method] == nil) then
        local ns = capability:match("^([^:]+)")
        if ns then host = rawget(_G, ns) or host end
    end
    return S.Api:CallCapability(capability, host, method, ...)
end

local function Action(capability, object, method, ...)
    if S.Api == nil or type(S.Api.ActionCapability) ~= "function" then
        return false, "API boundary unavailable"
    end
    local host = object
    if host == nil or (method and host[method] == nil) then
        local ns = capability:match("^([^:]+)")
        if ns then host = rawget(_G, ns) or host end
    end
    return S.Api:ActionCapability(capability, host, method, ...)
end

local function PersistLifeMutation(feature, reason, mutator)
    if type(P.MutateStore) ~= "function" then return false, "Persistence mutation transaction unavailable" end
    return P:MutateStore(feature.storeId, function()
        return mutator(feature.State)
    end, { delayMs = 300, reason = reason or "life_feature_changed" })
end

local function InstallLifeWidgetContract(feature, policy)
    feature.WidgetWindowPolicy = policy
    function feature:GetWidgetWindowPolicy() return Copy(self.WidgetWindowPolicy) end
    function feature:GetWidgetVisible() return self.State and self.State.widgetVisible == true or false end
    function feature:GetWidgetWindowState()
        local value = self.State and self.State.widgetWindow or nil
        local floating = S.RSUI and S.RSUI.FloatingSurface or nil
        if type(floating) == "table" and type(floating.NormalizeState) == "function" then
            return Copy(floating:NormalizeState(value, self:GetWidgetWindowPolicy()))
        end
        return Copy(value)
    end
    function feature:SetWidgetWindowState(value, reason)
        if type(value) ~= "table" or type(self.State) ~= "table" then return false, "生活悬浮窗状态不可用" end
        if type(P.PrepareWrite) == "function" then
            local prepared, prepareErr = P:PrepareWrite(self.storeId)
            if prepared ~= true then return false, prepareErr or "生活悬浮窗配置尚未安全读取" end
        end
        local floating = S.RSUI and S.RSUI.FloatingSurface or nil
        self.State.widgetWindow = type(floating) == "table" and type(floating.NormalizeState) == "function"
            and floating:NormalizeState(value, self:GetWidgetWindowPolicy()) or Copy(value)
        return true
    end
    function feature:SetWidgetVisible(value, reason)
        return PersistLifeMutation(self, "widget_" .. tostring(reason or "visibility"), function(state)
            state.widgetVisible = value == true
            return true
        end)
    end
    function feature:MarkStoreDirty(delayMs, reason)
        -- 中文维护（2026-10-04）：跑商/钓鱼/债券/藏宝共享的位置事务必须在返回前落盘回读。
        -- 精确限定用户窗口边沿，业务快照和连续外观调整继续走既有 debounce。
        if reason == "widget_geometry" or reason == "widget_layout_reset" or reason == "widget_minimized" then
            return P:SaveStore(self.storeId, { durable=true, consumeDirty=true, reason=reason })
        end
        if P and type(P.MarkDirty) == "function" then return P:MarkDirty(self.storeId, tonumber(delayMs) or 250, reason or "life_widget_state") end
        return false, "persistence unavailable"
    end
end

local function PublishFeatureUpdate(feature, revision, reason)
    if type(feature) ~= "table" or type(feature.UpdateTopic) ~= "string" then return false end
    if S.Events ~= nil and type(S.Events.Publish) == "function" then
        return S.Events:Publish(feature.UpdateTopic, tonumber(revision) or 0, tostring(reason or "refresh"))
    end
    return false
end

-- migrate MUST be a pure per-value normalizer: it doubles as the Integrity v3
-- canonical function. The old `migrate = default` passed a function that
-- IGNORES its input and always builds a fresh default table, which made the
-- canonical fingerprint CONTENT-BLIND (every value hashed to the default
-- shape, so real corruption verified as healthy).
-- 维护：历史桥作为 Store 声明注册，不在运行中偷偷修改 Core/其他模块。旧调用参数仍兼容。
local function RegisterStore(id, owner, default, get, apply, migrate, budget, rebuildCanonicalForIntegrity)
    if P:GetStore(id) == nil then
        local store, err = P:RegisterV3Store({
            id = id, owner = owner, scope = P.Scope.Account, lifetime = P.Lifetime.Permanent,
            schemaVersion = 1, legacySchemaVersion = 0, key = P.V3KeyPrefix .. id:gsub("[^%w]", "_"),
            budget = budget or { maxDepth = 6, maxNodes = 320, maxStringBytes = 8192, maxEntriesPerTable = 160 },
            default = default, get = get, apply = apply, migrate = migrate or default,
            rebuildCanonicalForIntegrity = rebuildCanonicalForIntegrity, -- 维护：仅显式声明的 Store 启用；其他生活模块不受影响。
        })
        if store == nil then error(err or ("store register failed: " .. id)) end
    end
end

local function LoadStore(feature)
    if feature.storeLoaded == true then return true end
    if P:GetStore(feature.storeId) == nil then return false, "store unavailable: " .. feature.storeId end
    -- 维护（2026-10-07）：设置页可能先完成回读/修改。启动只要求 Domain 就绪，
    -- 不能再次物理 Load 覆盖未提交设置或触发 unverified store reload rejected。
    local status, err = P:PrepareRead(feature.storeId)
    if status ~= true then return false, err or "store read preparation failed" end
    feature.storeLoaded = true
    return true
end

local function Number(v) return tonumber(v) end
local function Text(v, fallback)
    if v == nil then return fallback or "" end
    return tostring(v)
end

local function Money(v, fallback)
    if v == nil then return fallback or "--" end
    local utils = S.Utils
    if type(utils) == "table" and type(utils.FormatMoney) == "function" then
        local n = tonumber(v)
        if n ~= nil then
            local ok, text = pcall(utils.FormatMoney, n)
            if ok and type(text) == "string" and text ~= "" then return text end
        end
    end
    return tostring(v)
end

local LF = {
    Copy = Copy, Call = Call, Action = Action,
    PersistLifeMutation = PersistLifeMutation,
    InstallLifeWidgetContract = InstallLifeWidgetContract,
    PublishFeatureUpdate = PublishFeatureUpdate,
    RegisterStore = RegisterStore, LoadStore = LoadStore,
    Number = Number, Text = Text, Money = Money,
}
S.LifeSliceFactory = LF
