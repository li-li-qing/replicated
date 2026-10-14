------------------------------------------------------------------------
-- Replicated Suite · 生活功能通用装配
-- 作者：Replicated
-- QQ群：1104129461
--
-- 生活Feature各自独立注册，本文件只提供共享装配。仅认识Core/Persistence/FeatureRuntime/Demand/Events/RSUI FloatingSurface/API边界，不认识Trade/Bonds/Treasure/Fishing业务State。
-- 禁止另建Registry/Runtime/Demand，也不能改变Store ID/Schema、Demand所有者、UpdateTopic或Commands。
-- 与features/shared/rs_feature_slice_factory.lua的Copy/RegisterStore/LoadStore语义不同，生活版migrate/canonical/budget为独立契约，禁止未经验证合并。
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
    -- FeatureRuntime 在本文件加载后惰性导入 API，加载时 rawget 可能nil，但首次读取前宿主已有效；让统一 API 边界调用时通过已注册能力解析 nil 宿主。
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
        -- 跑商/钓鱼/债券/藏宝共享的位置事务必须在返回前落盘回读。
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

-- migrate必须是逐值纯normalizer，也作为Integrity v3 canonical函数；禁止使用忽略输入的新默认构造器，否则所有值哈希成默认形态，损坏也被误验健康。
-- 历史桥以Store声明注册，禁止运行时偷偷改Core/其他模块；旧调用参数仍兼容。
local function RegisterStore(id, owner, default, get, apply, migrate, budget, rebuildCanonicalForIntegrity)
    if P:GetStore(id) == nil then
        local store, err = P:RegisterV3Store({
            id = id, owner = owner, scope = P.Scope.Account, lifetime = P.Lifetime.Permanent,
            schemaVersion = 1, legacySchemaVersion = 0, key = P.V3KeyPrefix .. id:gsub("[^%w]", "_"),
            budget = budget or { maxDepth = 6, maxNodes = 320, maxStringBytes = 8192, maxEntriesPerTable = 160 },
            default = default, get = get, apply = apply, migrate = migrate or default,
            rebuildCanonicalForIntegrity = rebuildCanonicalForIntegrity, -- 仅显式声明的 Store 启用；其他生活模块不受影响。
        })
        if store == nil then error(err or ("store register failed: " .. id)) end
    end
end

local function LoadStore(feature)
    if feature.storeLoaded == true then return true end
    if P:GetStore(feature.storeId) == nil then return false, "store unavailable: " .. feature.storeId end
    -- 设置页可能先完成回读/修改。启动只要求 Domain 就绪，
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
