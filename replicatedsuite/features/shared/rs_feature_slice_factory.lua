------------------------------------------------------------------------
-- Replicated Suite V3 - Feature Slice Factory（Phase 1，2026-09-28）
--
-- 中文维护注释（FND-001 / Phase 1 Batch A）：rs_business_bridge.lua 已接近 Lua 5.1
-- 单 chunk 的 local 配额上限，继续往同一个 chunk 加 Feature 会让整片业务同时不可编。
-- 因此把“与业务无关的装配骨架”收敛到这里，让每个 Feature 可以在自己的文件里注册。
--
-- Authority 边界（不得被后续维护破坏）：
--   * 本文件只认识 Core / Persistence / FeatureRuntime / Demand / Events / API boundary；
--   * 不认识 Bag / Auction / Craft / UnitLines / RangeAssist 等任何业务 State；
--   * 不持有任何 Consumer 业务真相，不建立第二个 Registry / Runtime / Demand / Scheduler；
--   * 不改变 Store ID/Schema、Demand owner、UpdateTopic、task name、Commands、Projection shape。
-- 允许包含（经代码证明通用）：基础 Copy、统一 capability Call/Action 适配、
-- 通用 RegisterStore wrapper、通用 Load feature store、PersistentState 白名单快照、NewFeature 装配骨架。
-- 不允许包含：Bag 扫描/搬运、Craft 配方解析、Auction 搜索/报价、Range 圆数学、
-- Unit line 投影、Boss 规则表、Team 角色逻辑等任何业务判断。
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local P, Runtime, Demand = S.Persistence, S.FeatureRuntime, S.Demand
if type(P) ~= "table" or type(Runtime) ~= "table" or type(Demand) ~= "table" then return end

S.Features = S.Features or {}

local F = {}

function F.Copy(value, seen)
    if S.Utils and type(S.Utils.DeepCopy) == "function" then return S.Utils.DeepCopy(value) end
    if type(value) ~= "table" then return value end
    seen = seen or {}
    if seen[value] ~= nil then return seen[value] end
    local out = {}; seen[value] = out
    for key, child in pairs(value) do out[F.Copy(key, seen)] = F.Copy(child, seen) end
    return out
end

-- 中文维护注释：capability 的真实 host 可能为 nil；旧实现的语义是“用能力名前缀回退到同名全局”，
-- 例如 X2Friend:GetFriendList -> rawget(_G,"X2Friend")。必须保持这一语义，否则 Feature 取消
-- 显式传入宿主时会静默变成 api 不可用。
function F.Call(capability, object, method, ...)
    if S.Api == nil or type(S.Api.CallCapability) ~= "function" then return false, nil, "API boundary unavailable" end
    local host = object
    if host == nil or (method and host[method] == nil) then
        local capPrefix = capability and capability:match("^([^:]+)")
        if capPrefix then host = rawget(_G, capPrefix) or host end
    end
    return S.Api:CallCapability(capability, host, method, ...)
end

function F.Action(capability, object, method, ...)
    if S.Api == nil or type(S.Api.ActionCapability) ~= "function" then return false, "API boundary unavailable" end
    local host = object
    if host == nil or (method and host[method] == nil) then
        local capPrefix = capability and capability:match("^([^:]+)")
        if capPrefix then host = rawget(_G, capPrefix) or host end
    end
    return S.Api:ActionCapability(capability, host, method, ...)
end

-- 中文维护注释（2026-09-28，Phase 1 Batch A）：以下三个是无状态的通用值工具，被 bridge 内
-- 十余处 Feature 与拆分出的 Feature 同时使用（Trim 17 处 / Text 15 处 / Number 13 处）。
-- 放进工厂是为了避免“拆一个 Feature 就复制一份字符串兜底逻辑”，它们不携带任何业务判断。
function F.Text(value, fallback) return value == nil and (fallback or "") or tostring(value) end

function F.Number(value) local n = tonumber(value); return n and n == n and n or nil end

function F.Trim(value)
    return (tostring(value or ""):match("^%s*(.-)%s*$")) or ""
end

-- 中文维护注释（2026-09-28，Phase 1 Batch D 补漏）：Scalar 是“从常见键名里取出第一个标量值”的
-- 无状态归一工具，被 bridge 内 bag 帮助函数与拆分出的 tools_craft 同时使用（本轮搬迁时依赖
-- 分析脚本第一版漏掉了 `local function` 定义，导致 tools_craft 运行期才暴露）。与 Text/Number/Trim
-- 同族，放工厂避免复制；它不做任何业务判断。
function F.Scalar(value)
    if type(value) ~= "table" then return value end
    for _, key in ipairs({ "value", "id", "type", "itemType", "itemTypeId", "category", "category_id" }) do
        local child = value[key]
        if type(child) == "number" or type(child) == "string" then return child end
    end
    return nil
end

-- 通用 Store 注册：参数/Schema 与拆分前逐字一致。业务 Feature 只声明 id/owner/get/apply。
function F.RegisterStore(id, owner, default, get, apply)
    if P:GetStore(id) == nil then
        local store, err = P:RegisterV3Store({ id = id, owner = owner, scope = P.Scope.Account, lifetime = P.Lifetime.Permanent,
            schemaVersion = 1, legacySchemaVersion = 0, key = P.V3KeyPrefix .. id:gsub("[^%w]", "_"),
            budget = { maxDepth = 5, maxNodes = 240, maxStringBytes = 4096, maxEntriesPerTable = 96 },
            default = default, get = get, apply = apply, migrate = function(value) return value end })
        if store == nil then error(err or id .. " store register failed") end
    end
end

function F.Load(feature)
    if feature.storeLoaded then return true end
    local status, _, err = P:LoadStore(feature.storeId)
    if status ~= true and status ~= "empty" then return false, err or tostring(status or "store load failed") end
    feature.storeLoaded = true
    return true
end

-- 通用持久化事务包装：只负责把 mutator 放进 Persistence 的 MutateStore 事务，
-- 不决定字段白名单、不改变 Store 归属、不绕过 write fence。delayMs/reason 与拆分前逐字一致。
-- 中文维护注释：它是“Feature State 快照事务”的唯一写法入口，被拆出的 Feature 必须复用这一份，
-- 不允许各自写一个 SaveData 旁路。
function F.PersistStateMutation(feature, reason, mutator)
    if type(feature) ~= "table" or type(feature.State) ~= "table" or type(mutator) ~= "function" then return false, "持久化事务参数无效" end
    if type(P.MutateStore) ~= "function" then return false, "Persistence mutation transaction unavailable" end
    return P:MutateStore(feature.storeId, function()
        return mutator(feature.State)
    end, { delayMs = 300, reason = tostring(reason or "feature_mutation") })
end

-- 中文维护注释：Lua table literal 无法真正声明 `key = nil`，所以仅 pairs(default)
-- 不能作为永久字段完整白名单。制作选择、团队角色、整理背包类别等 nullable 配置
-- 必须通过 explicitKeys 声明；这里仍只复制白名单，Runtime projection/batch/query
-- 状态不会被误写入永久 Store。Authority 仍是 Feature State，Persistence 仅负责快照。
function F.PersistentState(state, defaults, explicitKeys)
    local out, keys = {}, {}
    for key in pairs(type(defaults) == "table" and defaults or {}) do keys[key] = true end
    for _, key in ipairs(type(explicitKeys) == "table" and explicitKeys or {}) do
        key = tostring(key or "")
        if key ~= "" then keys[key] = true end
    end
    for key in pairs(keys) do out[key] = F.Copy(state[key]) end
    return out
end

-- 通用 Feature 装配骨架：Store / Authority / Demand / Runtime 注册顺序与被拆文件一致。
-- 中文维护注释：它不认识任何具体业务，只按 spec 组装；“谁拥有什么事实”仍由各 Feature 文件决定。
function F.NewFeature(id, spec)
    local feature = { Id = id, storeId = "v3.business." .. id, enabled = false, storeLoaded = false, State = spec.state or {}, Authority = { version = 1, revision = 0, rows = {}, status = "idle", error = nil } }
    feature.UpdateTopic = "v3.business." .. tostring(id) .. ".updated"
    feature.ObservationContractVersion = tonumber(spec.observationContractVersion) or 0
    S.Features[id] = feature
    local authority, state = feature.Authority, feature.State
    feature._persistentKeys = {}
    for key in pairs(type(spec.default) == "table" and spec.default or {}) do feature._persistentKeys[key] = true end
    for _, key in ipairs(type(spec.persistentKeys) == "table" and spec.persistentKeys or {}) do
        key = tostring(key or "")
        if key ~= "" then feature._persistentKeys[key] = true end
    end
    F.RegisterStore(feature.storeId, "v3." .. id, function() return F.Copy(spec.default or {}) end, function() return F.PersistentState(state, spec.default, spec.persistentKeys) end, function(value)
        if type(spec.apply) == "function" then return spec.apply(value, state) end
        value = type(value) == "table" and value or {}
        -- 中文维护注释：apply 与 get 必须使用同一字段契约。显式 nullable 字段在存档缺失时
        -- 恢复 nil，而不是保留本会话旧选择；非 nil 默认值继续按原默认恢复。
        for key in pairs(feature._persistentKeys) do
            -- 维护（2026-09-30）：and/or 不能模拟含 false 的三元选择；缺字段应恢复
            -- false 默认，显式 false/0/空串也必须保留，nullable 缺省仍清为 nil。
            local saved = value[key]
            if saved == nil and type(spec.default) == "table" then saved = spec.default[key] end
            state[key] = F.Copy(saved)
        end
    end)
    feature.ApiDependencies = spec.apiDependencies or {}
    function authority:Refresh(reason)
        if spec.blocker ~= nil then
            self.rows = { { key = id .. ":blocked", name = "运行时阻塞", text = spec.blocker, statusText = "Runtime Blocked", tone = "warn" } }
            self.status, self.error = "runtime_blocked", spec.blocker
        else
            local rows, status, err = spec.read(feature)
            self.rows, self.status, self.error = type(rows) == "table" and rows or {}, status or "ready", err
        end
        self.revision = self.revision + 1
        if S.Events ~= nil and type(S.Events.Publish) == "function" then
            S.Events:Publish(feature.UpdateTopic, self.revision, tostring(reason or "refresh"))
        end
        return true
    end
    function feature:Initialize() return F.Load(self) end
    function feature:ReconcileDemand(_, before, after)
        local beforeCount = tonumber(before and before.count) or 0
        local afterCount = tonumber(after and after.count) or 0
        local customReconciled = false
        if type(spec.reconcileDemand) == "function" then
            local ok, err = spec.reconcileDemand(self, before, after)
            if ok ~= true then return false, err end
            customReconciled = true
        end
        if beforeCount <= 0 and afterCount > 0 then
            if spec.event and S.Events ~= nil then
                S.Events:BindOwner(self, self.Id)
                local subscribed = S.Events:SubscribeOptional(spec.event, self, function(_, ...)
                    if self.enabled and (tonumber(self.consumerCount) or 0) > 0 and type(spec.onEvent) == "function" then
                        return spec.onEvent(self, ...)
                    end
                end)
                if subscribed ~= true then
                    -- Demand acquisition is one transaction. If the generic event
                    -- edge cannot be established, reverse any custom observation
                    -- resource created earlier in the same 0->1 transition (for
                    -- example the target-monitor distance Scheduler task).
                    S.Events:UnsubscribeOwner(self)
                    if customReconciled == true and type(spec.reconcileDemand) == "function" then
                        pcall(spec.reconcileDemand, self, after, before)
                    end
                    return false, "可选事件订阅失败：" .. tostring(spec.event)
                end
            end
            self.Authority:Refresh("consumer_acquire")
        elseif beforeCount > 0 and afterCount <= 0 and spec.event and S.Events ~= nil then
            S.Events:UnsubscribeOwner(self)
        end
        return true
    end
    function feature:Enable(reason)
        if self.enabled == true then return true end
        self.enabled = true
        if type(spec.onEnable) == "function" then
            local hookOk, hookErr = spec.onEnable(self, reason or "business_feature_enable")
            if hookOk ~= true then
                self.enabled = false
                if S.Scheduler ~= nil and type(S.Scheduler.RemoveOwner) == "function" then S.Scheduler:RemoveOwner(self) end
                if S.Events ~= nil then S.Events:UnsubscribeOwner(self); S.Events:UnsubscribeInternalOwner(self) end
                return false, hookErr or "Feature enable hook failed"
            end
        end
        return true
    end
    function feature:Disable(reason)
        local ok, err = self.Demand:Clear(reason or "business_feature_disable"); if ok ~= true then return false, err end
        if type(spec.onDisable) == "function" then
            local hookOk, hookErr = spec.onDisable(self, reason or "business_feature_disable")
            if hookOk ~= true then return false, hookErr end
        end
        if S.Events ~= nil then S.Events:UnsubscribeOwner(self) end
        self.enabled = false; return true
    end
    function feature:AcquireConsumer(token) if not self.enabled then return false, "功能已关闭" end return self.Demand:Acquire(token, {}, "business_consumer") end
    function feature:ReleaseConsumer(token) return self.Demand:Release(token, "business_consumer") end
    function feature:HasConsumer(token) return self.Demand ~= nil and type(self.Demand.Has) == "function" and self.Demand:Has(token) == true end
    function feature:Refresh(reason) local consumerCount = tonumber(self.consumerCount) or tonumber(self.Demand and self.Demand.count) or 0; if not self.enabled or consumerCount <= 0 then return true end return self.Authority:Refresh(reason or "manual") end
    function feature:GetProjection()
        local projection = { revision = authority.revision, rows = F.Copy(authority.rows), status = authority.status, error = authority.error }
        if type(spec.projection) == "function" then
            local extra = spec.projection(feature)
            if type(extra) == "table" then for key, value in pairs(extra) do projection[key] = F.Copy(value) end end
        end
        return projection
    end
    feature.Commands = { Refresh = function(_, reason) return feature:Refresh(reason) end }
    for name, fn in pairs(spec.commands or {}) do feature.Commands[name] = function(_, ...) return fn(feature, ...) end end
    local lease, leaseErr = Demand:Create({ id = "feature:" .. id, owner = feature, projectionOwner = feature, projectionConsumersField = "consumers", projectionCountField = "consumerCount", reconcile = function(l, before, after) return feature:ReconcileDemand(l, before, after) end })
    if lease == nil then error(leaseErr) end
    feature.Demand = lease
    local ok, err = Runtime:RegisterImplementation(id, feature); if ok ~= true then error(err) end
    return feature
end

S.FeatureSliceFactory = F
