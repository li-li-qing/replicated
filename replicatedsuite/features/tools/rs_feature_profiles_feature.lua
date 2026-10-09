------------------------------------------------------------------------
-- Replicated Suite V3 - Feature Profiles
--
-- 用户自定义“功能方案”Authority：一个方案只保存“哪些可控业务 Feature 应开启”。
-- 应用时当前 Registry 中其它可控业务 Feature 一律关闭；方案本身不硬编码“生活/战斗”等语义。
--
-- 关键边界：
-- * FeatureRuntime 是启停/偏好唯一 Authority，本模块绝不直接调用其它 Feature:Enable/Disable。
-- * 方案只控制 Enabled/PreferredEnabled，不删除任何 Feature 自己的永久配置、窗口位置或业务 Store。
-- * 批量切换使用 FeatureRuntime:ApplyPreferenceTargets 单事务提交，失败反向回滚，禁止半套状态。
-- * 快捷按钮只是 Presentation Proxy；本文件只保存方案/按钮位置并发布投影事件，不创建 Native UI。
-- * 无 Tick/OnUpdate；仅用户操作、Feature lifecycle 事件和页面 Consumer 边沿刷新。
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local P, Runtime, Registry, Demand = S.Persistence, S.FeatureRuntime, S.FeatureRegistry, S.Demand
if type(P) ~= "table" or type(Runtime) ~= "table" or type(Registry) ~= "table" or type(Demand) ~= "table" then return end

S.Features = S.Features or {}
local F = {
    Id = "tools_feature_profiles",
    storeId = "v3.business.tools_feature_profiles",
    UpdateTopic = "v3.feature_profiles.updated",
    ContractVersion = 1,
    enabled = false,
    storeLoaded = false,
    consumerCount = 0,
    consumers = {},
    applying = false,
    pendingLifecycleRefresh = false,
    State = { profiles = {}, nextId = 1, selectedId = nil },
    RuntimeState = { lastAppliedId = nil, activeProfileId = nil, dirty = false },
    Authority = { revision = 0, rows = {}, moduleRows = {}, status = "idle", error = nil, lastOperation = nil },
    Stats = { applies = 0, applyFailures = 0, rollbacks = 0, creates = 0, deletes = 0, mutations = 0 },
    QuickButtonPolicy = { width = 104, height = 26, gapX = 6, gapY = 4, defaultBaseX = 300, defaultBaseY = 136, maxColumns = 4 },
}
S.Features.FeatureProfiles = F
S.Features[F.Id] = F

local MAX_PROFILES = 16

local function Emit(level, code, message, context)
    local d = S.DiagnosticsManager
    if type(d) == "table" and type(d.Emit) == "function" then
        d:Emit(level, "feature_profiles_v3", code, message, context)
    end
end

local function Copy(value, seen)
    if S.Utils ~= nil and type(S.Utils.DeepCopy) == "function" then return S.Utils.DeepCopy(value) end
    if type(value) ~= "table" then return value end
    seen = seen or {}; if seen[value] then return nil end; seen[value] = true
    local out = {}; for key, child in pairs(value) do out[Copy(key, seen)] = Copy(child, seen) end
    return out
end

local function Trim(value)
    return tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function NormalizeId(value)
    return tostring(value or ""):lower():gsub("[^%w_%.%-]", "_"):gsub("_+", "_"):gsub("^_+", ""):gsub("_+$", "")
end

local function FiniteNumber(value)
    local n = tonumber(value)
    if n == nil or n ~= n or n == math.huge or n == -math.huge then return nil end
    return n
end

local function Round(value, scale)
    return math.floor(value * scale + 0.5) / scale
end

local function NormalizePlacement(value)
    value = type(value) == "table" and value or {}
    local x, y = tonumber(value.quickX), tonumber(value.quickY)
    local customized = value.quickPositionCustomized == true and x ~= nil and y ~= nil
    local coordinateSpace = tostring(value.quickCoordinateSpace or "")
    local anchorH, anchorV = tostring(value.quickAnchorH or ""), tostring(value.quickAnchorV or "")
    local offsetX, offsetY = tonumber(value.quickOffsetX), tonumber(value.quickOffsetY)
    local responsive = customized and coordinateSpace == "logical-edge-v1"
        and (anchorH == "LEFT" or anchorH == "RIGHT") and (anchorV == "TOP" or anchorV == "BOTTOM")
        and offsetX ~= nil and offsetY ~= nil

    -- 维护（2026-09-25，feature-profile-quick-viewport-intent-1）：屏幕快捷按钮除了
    -- “最近边锚点”之外，还必须保留产生该位置的 source viewport identity（逻辑宽高 +
    -- 中心比例 + uiScale）。否则同一个分辨率重登时只能靠边锚点反推，一旦恢复期 viewport
    -- 与保存期不同（登录期临时 canvas / 窗口模式变化），右侧按钮就会被推到真实窗口之外；
    -- 而且每次重新投影都会以“上一次投影结果”为输入，产生累计漂移。
    -- 这里只做读取归一化：绝不根据旧 edge 值合成新语义（启动期不升级旧配置），
    -- 只有用户真实拖动提交 SetQuickPosition 时才会写入这组字段。
    local savedW, savedH = FiniteNumber(value.quickSavedLogicalWidth), FiniteNumber(value.quickSavedLogicalHeight)
    local savedScale = FiniteNumber(value.quickSavedUiScale)
    local centerX, centerY = FiniteNumber(value.quickNormalizedCenterX), FiniteNumber(value.quickNormalizedCenterY)
    local viewportIntent = customized and savedW ~= nil and savedH ~= nil and savedW > 0 and savedH > 0
        and centerX ~= nil and centerY ~= nil
        and centerX >= -2 and centerX <= 3 and centerY >= -2 and centerY <= 3

    return {
        quickX = customized and math.floor(x + 0.5) or nil,
        quickY = customized and math.floor(y + 0.5) or nil,
        quickPositionCustomized = customized,
        quickCoordinateSpace = responsive and "logical-edge-v1" or nil,
        quickAnchorH = responsive and anchorH or nil,
        quickAnchorV = responsive and anchorV or nil,
        quickOffsetX = responsive and math.max(0, math.floor(offsetX + 0.5)) or nil,
        quickOffsetY = responsive and math.max(0, math.floor(offsetY + 0.5)) or nil,
        quickSavedLogicalWidth = viewportIntent and Round(savedW, 1) or nil,
        quickSavedLogicalHeight = viewportIntent and Round(savedH, 1) or nil,
        quickSavedUiScale = (viewportIntent and savedScale ~= nil and savedScale > 0) and Round(savedScale, 10000) or nil,
        quickNormalizedCenterX = viewportIntent and Round(centerX, 1000000) or nil,
        quickNormalizedCenterY = viewportIntent and Round(centerY, 1000000) or nil,
    }
end

local function NormalizeModules(value)
    local out = {}
    for rawId, enabled in pairs(type(value) == "table" and value or {}) do
        local id = NormalizeId(rawId)
        -- Store 只保存“开启集合”。false/nil 都表示应用时关闭，减少动态模块 schema 噪声。
        if id ~= "" and enabled == true then out[id] = true end
    end
    return out
end

local function NormalizeProfile(value, index)
    value = type(value) == "table" and value or {}
    local id = math.max(1, math.floor(tonumber(value.id) or tonumber(index) or 1))
    local name = Trim(value.name)
    if name == "" then name = "方案 " .. tostring(id) end
    if #name > 32 then name = string.sub(name, 1, 32) end
    local placement = NormalizePlacement(value)
    return {
        id = id,
        name = name,
        modules = NormalizeModules(value.modules),
        quick = value.quick ~= false,
        quickX = placement.quickX, quickY = placement.quickY,
        quickPositionCustomized = placement.quickPositionCustomized,
        quickCoordinateSpace = placement.quickCoordinateSpace,
        quickAnchorH = placement.quickAnchorH, quickAnchorV = placement.quickAnchorV,
        quickOffsetX = placement.quickOffsetX, quickOffsetY = placement.quickOffsetY,
        quickSavedLogicalWidth = placement.quickSavedLogicalWidth,
        quickSavedLogicalHeight = placement.quickSavedLogicalHeight,
        quickSavedUiScale = placement.quickSavedUiScale,
        quickNormalizedCenterX = placement.quickNormalizedCenterX,
        quickNormalizedCenterY = placement.quickNormalizedCenterY,
    }
end

local function NormalizeState(value)
    value = type(value) == "table" and value or {}
    local out, used, maxId = { profiles = {}, nextId = 1, selectedId = nil }, {}, 0
    for index, raw in ipairs(type(value.profiles) == "table" and value.profiles or {}) do
        if #out.profiles >= MAX_PROFILES then break end
        local profile = NormalizeProfile(raw, index)
        while used[profile.id] do profile.id = profile.id + 1 end
        used[profile.id] = true; maxId = math.max(maxId, profile.id)
        out.profiles[#out.profiles + 1] = profile
    end
    local selected = tonumber(value.selectedId)
    if selected ~= nil and used[math.floor(selected)] then out.selectedId = math.floor(selected) end
    if out.selectedId == nil and out.profiles[1] ~= nil then out.selectedId = out.profiles[1].id end
    out.nextId = math.max(maxId + 1, math.floor(tonumber(value.nextId) or 1), 1)
    return out
end

local function ApplyState(value)
    F.State = NormalizeState(value)
end

local function PersistentState()
    return NormalizeState(F.State)
end

if type(P.RegisterV3Store) == "function" and P:GetStore(F.storeId) == nil then
    local store, err = P:RegisterV3Store({
        id = F.storeId,
        owner = "v3.feature_profiles",
        scope = P.Scope.Account,
        lifetime = P.Lifetime.Permanent,
        schemaVersion = 1,
        legacySchemaVersion = 0,
        key = P.V3KeyPrefix .. "feature_profiles",
        budget = { maxDepth = 8, maxNodes = 2200, maxStringBytes = 16384, maxEntriesPerTable = 128 },
        default = function() return { profiles = {}, nextId = 1, selectedId = nil } end,
        get = PersistentState,
        apply = ApplyState,
    })
    if store == nil then error(err or "feature profile store register failed") end
end

function F:EnsureStoreLoaded()
    if self.storeLoaded == true then return true end
    local status, _, err = P:LoadStore(self.storeId)
    if status ~= true and status ~= "empty" then return false, err or tostring(status or "store load failed") end
    if status == "empty" then ApplyState({}) end
    self.storeLoaded = true
    return true
end

function F:Persist(reason, mutator)
    local loaded, loadErr = self:EnsureStoreLoaded(); if loaded ~= true then return false, loadErr end
    if type(mutator) ~= "function" then return false, "profile mutator required" end
    local ok, err = P:MutateStore(self.storeId, function()
        local changed, detail = mutator(self.State)
        if changed == false then return false, detail end
        self.State = NormalizeState(self.State)
        return true, detail
    end, { durable = true, reason = tostring(reason or "feature_profile_mutation") })
    if ok == true then self.Stats.mutations = (tonumber(self.Stats.mutations) or 0) + 1 end
    return ok, err
end

local function ProfileById(profileId)
    local wanted = math.floor(tonumber(profileId) or 0)
    for index, profile in ipairs(F.State.profiles or {}) do
        if tonumber(profile.id) == wanted then return profile, index end
    end
    return nil, nil
end

local function IsControllable(meta)
    if type(meta) ~= "table" then return false end
    if meta.navigationVisible == false or meta.category == "system" then return false end -- 中文维护：已从左侧删除的内部 Feature 不再被方案隐式开启/关闭。
    local id = NormalizeId(meta.id)
    if id == "" or id == F.Id then return false end
    if tostring(meta.lifecycle or "") == "shell" or tostring(meta.controlFeatureId or id) == "" then return false end
    if meta.runtimeBlocked == true then return false end
    return Runtime:IsImplemented(id) == true
end

-- 中文维护（2026-10-02）：展示目录使用与左栏相同的 Workspace/Router 投影，
-- 名称含同一开发态标签，顺序跟随个人重排/隐藏；基础页/本方案仍展示但只读。
-- 初始化早于 UI 装配时只用 Registry 可见目录降级，不读取游戏 API，不另存名单。
function F:GetNavigationFeatureRows()
    local rows = {}
    local workspace = S.UIV3 and S.UIV3.Workspace or nil
    local nav = type(workspace) == "table" and type(workspace.GetNavigation) == "function" and workspace:GetNavigation("custom") or nil
    local catalog = nav or Registry:ListAccessible() -- 中文维护：无工作台的回退目录也遵守手工开放，方案不应列出隐藏模块。
    for _, entry in ipairs(catalog) do
        local meta = nav and Registry:Get(entry.featureId) or entry
        if meta and Registry:IsAccessible(meta.id) and meta.navigationVisible ~= false and meta.category ~= "system" then -- 中文维护：旧导航输入同样不能恢复受限条目。
            local category = Registry.categories and Registry.categories[meta.category] or nil
            rows[#rows + 1] = {
                id = meta.id,
                name = tostring(entry.navigationTitle or (meta.name .. (meta.navigationIncomplete == true and "（未完成）" or ""))),
                category = tostring(meta.category or ""),
                categoryName = tostring(category and category.name or meta.category or ""),
                route = tostring(meta.route or ""),
                controllable = IsControllable(meta), controlId = meta.controlFeatureId or meta.id,
            }
        end
    end
    return rows
end
function F:GetControllableFeatureRows()
    local rows = {}
    for _, row in ipairs(self:GetNavigationFeatureRows()) do if row.controllable then rows[#rows + 1] = row end end
    return rows
end

-- 中文维护：旧方案只保存团队中心一个开启位，拆分前同时启用职责/视觉。
-- 读取时解释历史意图，不改 canonical；用户编辑或捕获时才提交独立链接位，
-- 使“职责开、牺牲关”可持久表达，且旧指纹无需猜测/批量重写。
local function ProfileTarget(profile, id)
    local modules = type(profile) == "table" and profile.modules or {}
    -- 合并功能以 Registry 的组元数据解释旧开启集合，不改旧方案存档。
    -- 旧方案只选分析子页时，主功能应继承开启意图；以后捕获只保存一个可见功能。
    local meta=Registry:Get(id)
    local group=meta and meta.preferenceGroup
    if type(group)=="table" and group[1]==id then
        for _,member in ipairs(group) do if modules[member]==true then return true end end
        return false
    end
    if id == "combat_sac_highlight" and modules.team_feature_split_linked ~= true then
        return modules.combat_sac_highlight == true or modules.combat_team_tools == true
    end
    return modules[id] == true
end

local function BuildModuleRows(selected,navigationRows)
    local rows={}
    for _,row in ipairs(navigationRows)do
        local target=row.controllable and ProfileTarget(selected,row.id) or false
        local current=Runtime:IsEnabled(row.controlId)==true
        rows[#rows+1]={
            featureId=row.id,name=row.name,category=row.categoryName,controllable=row.controllable,
            targetEnabled=target,targetText=row.controllable and (target and "开启" or "关闭") or "不参与",
            runtimeEnabled=current,runtimeText=current and "已开" or "已关",
            matches=not row.controllable or target==current,tone=target and "success" or "muted",
        }
    end
    return rows
end

local function BuildTargets(profile)
    local targets = {}
    for _, row in ipairs(F:GetControllableFeatureRows()) do
        targets[row.id] = ProfileTarget(profile, row.id)
    end
    return targets
end

local function ProfileMatchesRuntime(profile, controllable)
    if type(profile) ~= "table" then return false end
    for _, row in ipairs(controllable or F:GetControllableFeatureRows()) do
        local target = ProfileTarget(profile, row.id)
        if Runtime:IsEnabled(row.id) ~= target then return false end
    end
    return true
end

function F:RecomputeRuntimeMatch()
    local controllable = self:GetControllableFeatureRows()
    local last = self.RuntimeState.lastAppliedId and ProfileById(self.RuntimeState.lastAppliedId) or nil
    if last ~= nil and ProfileMatchesRuntime(last, controllable) then
        self.RuntimeState.activeProfileId = last.id
        self.RuntimeState.dirty = false
        return last.id, false
    end
    if self.RuntimeState.lastAppliedId ~= nil then
        self.RuntimeState.activeProfileId = nil
        self.RuntimeState.dirty = true
        return nil, true
    end
    for _, profile in ipairs(self.State.profiles or {}) do
        if ProfileMatchesRuntime(profile, controllable) then
            self.RuntimeState.activeProfileId = profile.id
            self.RuntimeState.dirty = false
            return profile.id, false
        end
    end
    self.RuntimeState.activeProfileId = nil
    self.RuntimeState.dirty = false
    return nil, false
end

local function Publish(reason)
    if type(S.Events) == "table" and type(S.Events.Publish) == "function" then
        S.Events:Publish(F.UpdateTopic, F.Authority.revision, tostring(reason or "refresh"))
    end
end

function F.Authority:Refresh(reason)
    local loaded, loadErr = F:EnsureStoreLoaded()
    if loaded ~= true then
        self.error, self.status = loadErr, "unavailable"
        self.revision = (tonumber(self.revision) or 0) + 1
        Publish(reason); return false, loadErr
    end
    F:RecomputeRuntimeMatch()
    local controllable = F:GetControllableFeatureRows()
    local selected = ProfileById(F.State.selectedId)
    local rows = {}
    for _, profile in ipairs(F.State.profiles or {}) do
        local enabledCount = 0
        for _, row in ipairs(controllable) do if ProfileTarget(profile, row.id) then enabledCount = enabledCount + 1 end end
        local active = tonumber(F.RuntimeState.activeProfileId) == tonumber(profile.id)
        local dirty = tonumber(F.RuntimeState.lastAppliedId) == tonumber(profile.id) and F.RuntimeState.dirty == true
        rows[#rows + 1] = {
            profileId = profile.id,
            name = profile.name,
            moduleCount = enabledCount,
            totalModuleCount = #controllable,
            moduleText = tostring(enabledCount) .. "/" .. tostring(#controllable),
            quick = profile.quick ~= false,
            quickText = profile.quick ~= false and "显示" or "隐藏",
            active = active,
            dirty = dirty,
            statusText = active and "当前" or (dirty and "已偏离" or (tonumber(F.State.selectedId) == tonumber(profile.id) and "已选择" or "")),
            tone = active and "success" or (dirty and "warn" or "muted"),
            quickX = profile.quickX, quickY = profile.quickY,
            quickPositionCustomized = profile.quickPositionCustomized == true,
            quickCoordinateSpace = profile.quickCoordinateSpace,
            quickAnchorH = profile.quickAnchorH, quickAnchorV = profile.quickAnchorV,
            quickOffsetX = profile.quickOffsetX, quickOffsetY = profile.quickOffsetY,
            quickSavedLogicalWidth = profile.quickSavedLogicalWidth,
            quickSavedLogicalHeight = profile.quickSavedLogicalHeight,
            quickSavedUiScale = profile.quickSavedUiScale,
            quickNormalizedCenterX = profile.quickNormalizedCenterX,
            quickNormalizedCenterY = profile.quickNormalizedCenterY,
        }
    end
    local moduleRows = BuildModuleRows(selected,F:GetNavigationFeatureRows())
    self.rows, self.moduleRows = rows, moduleRows
    self.status = #rows > 0 and "ready" or "empty"
    self.error = nil
    self.revision = (tonumber(self.revision) or 0) + 1
    Publish(reason)
    return true
end

function F:GetProjection()
    if self.storeLoaded ~= true then self:EnsureStoreLoaded() end
    local selected = ProfileById(self.State.selectedId)
    -- 2026-10-06：Disable 会释放导航订阅；不能继续返回上次事件留下的旧 moduleRows。
    -- Projection 按请求从同一个 Registry/Workspace/Runtime 只读投影名单与开关，启用/关闭均一致。
    -- 不为了名单更新重新启用模块、订阅事件、写Store或注册轮询；不从这里 Publish 造成页面重入。
    local navigationRows=self:GetNavigationFeatureRows()
    local controllableCount=0
    for _,row in ipairs(navigationRows)do if row.controllable then controllableCount=controllableCount+1 end end
    local rows=Copy(self.Authority.rows)
    for _,row in ipairs(rows or {})do
        local profile=ProfileById(row.profileId);local enabledCount=0
        for _,module in ipairs(navigationRows)do
            if module.controllable and ProfileTarget(profile,module.id) then enabledCount=enabledCount+1 end
        end
        row.moduleCount,row.totalModuleCount=enabledCount,controllableCount
        row.moduleText=enabledCount.."/"..controllableCount
    end
    return {
        revision = self.Authority.revision,
        rows = rows, moduleRows = BuildModuleRows(selected,navigationRows),
        status = self.Authority.status, error = self.Authority.error,
        selectedId = self.State.selectedId,
        selectedName = selected and selected.name or nil,
        profileCount = #(self.State.profiles or {}), profileLimit = MAX_PROFILES,
        activeProfileId = self.RuntimeState.activeProfileId,
        lastAppliedId = self.RuntimeState.lastAppliedId,
        dirty = self.RuntimeState.dirty == true,
        controllableCount = controllableCount,
        lastOperation = self.Authority.lastOperation,
        -- 维护（feature-profile-failure-evidence-1）：管理页 ready 不等于上次应用成功；
        -- 分开投影最后一次操作结果，且返回分离副本，UI/诊断不能改写 Domain 证据。
        applyStatus = self.applying == true and "applying" or (self.RuntimeState.lastApplyFailure ~= nil and "failed" or (self.RuntimeState.lastAppliedId ~= nil and "applied" or "idle")),
        lastApplyFailure = Copy(self.RuntimeState.lastApplyFailure),
        enabled = self.enabled == true,
    }
end

function F:GetQuickRows()
    local projection = self:GetProjection()
    local rows = {}
    for _, row in ipairs(projection.rows or {}) do if row.quick == true then rows[#rows + 1] = row end end
    return rows, projection.revision
end

function F:GetQuickButtonPolicy() return Copy(self.QuickButtonPolicy) end

function F:ShouldShowQuickButtons()
    if self.enabled ~= true then return false end
    for _, profile in ipairs(self.State.profiles or {}) do if profile.quick ~= false then return true end end
    return false
end

function F:_SubscribeLifecycle()
    if self.lifecycleSubscribed == true then return true end
    if type(S.Events) ~= "table" or type(S.Events.SubscribeInternal) ~= "function" then return false, "feature lifecycle event bus unavailable" end
    local ok = S.Events:SubscribeInternal(Runtime.LifecycleTopic or "v3.feature.lifecycle", self, function(_, featureId)
        if tostring(featureId or "") == F.Id then return end
        if F.applying == true then F.pendingLifecycleRefresh = true; return end
        F.Authority:Refresh("feature_lifecycle")
    end)
    if ok ~= true then return false, "feature lifecycle subscribe failed" end
    -- 中文维护：个人导航隐藏/排序修改后立即重建同源目录；只在已启用方案时订阅，
    -- 复用现有 owner 清理，不新增轮询或另外一份导航持久事实。
    local navOk = S.Events:SubscribeInternal("v3.workspace.updated", self, function(_, kind)
        if kind == "navigation" then F.Authority:Refresh("navigation_updated") end
    end)
    if navOk ~= true then self:_UnsubscribeLifecycle(); return false, "navigation lifecycle subscribe failed" end
    self.lifecycleSubscribed = true
    return true
end

function F:_UnsubscribeLifecycle()
    if type(S.Events) == "table" and type(S.Events.UnsubscribeInternalOwner) == "function" then S.Events:UnsubscribeInternalOwner(self) end
    self.lifecycleSubscribed = false
    return true
end

function F:Initialize()
    local ok, err = self:EnsureStoreLoaded(); if ok ~= true then return false, err end
    return self.Authority:Refresh("initialize")
end

function F:Enable()
    self.enabled = true
    local subscribed, subErr = self:_SubscribeLifecycle()
    if subscribed ~= true then self.enabled = false; return false, subErr end
    return self.Authority:Refresh("enable")
end

function F:Disable(reason)
    local cleared, clearErr = self.Demand:Clear(reason or "feature_profiles_disable")
    if cleared ~= true then return false, clearErr end
    self:_UnsubscribeLifecycle()
    self.enabled = false
    self.RuntimeState.activeProfileId = nil
    self.RuntimeState.dirty = false
    self.Authority:Refresh("disable")
    return true
end

function F:ReconcileDemand(_, before, after)
    self.consumerCount = tonumber(after and after.count) or 0
    if (tonumber(before and before.count) or 0) <= 0 and self.consumerCount > 0 then return self.Authority:Refresh("consumer_acquire") end
    return true
end

function F:AcquireConsumer(token)
    if self.enabled ~= true then return false, "功能方案已关闭" end
    return self.Demand:Acquire(token, {}, "feature_profile_consumer")
end
function F:ReleaseConsumer(token) return self.Demand:Release(token, "feature_profile_consumer") end
function F:Refresh(reason)
    if self.enabled ~= true and (tonumber(self.consumerCount) or 0) <= 0 then return true end
    return self.Authority:Refresh(reason or "manual")
end

local function NormalizeResponsivePlacement(placement)
    if type(placement) ~= "table" or tostring(placement.coordinateSpace or "") ~= "logical-edge-v1" then return nil end
    local anchorH, anchorV = tostring(placement.anchorH or ""), tostring(placement.anchorV or "")
    local offsetX, offsetY = tonumber(placement.offsetX), tonumber(placement.offsetY)
    if (anchorH ~= "LEFT" and anchorH ~= "RIGHT") or (anchorV ~= "TOP" and anchorV ~= "BOTTOM") or offsetX == nil or offsetY == nil then return nil end
    return { coordinateSpace = "logical-edge-v1", anchorH = anchorH, anchorV = anchorV,
        offsetX = math.max(0, math.floor(offsetX + 0.5)), offsetY = math.max(0, math.floor(offsetY + 0.5)) }
end

-- 维护（2026-09-25，feature-profile-quick-viewport-intent-1）：真实拖动提交时由 Widget 传入
-- 的 source-viewport intent（Layout logical-free-v2 projection 的 Feature 侧镜像）。
-- 只接受完整、有限、可信的一组值；任何缺失都整体拒绝，避免生成“半套” viewport 身份。
local function NormalizeViewportIntent(intent)
    if type(intent) ~= "table" then return nil end
    local width, height = FiniteNumber(intent.savedLogicalWidth), FiniteNumber(intent.savedLogicalHeight)
    local scale = FiniteNumber(intent.savedUiScale)
    local centerX, centerY = FiniteNumber(intent.normalizedCenterX), FiniteNumber(intent.normalizedCenterY)
    if width == nil or height == nil or width <= 0 or height <= 0 then return nil end
    if centerX == nil or centerY == nil or centerX < -2 or centerX > 3 or centerY < -2 or centerY > 3 then return nil end
    return {
        savedLogicalWidth = Round(width, 1),
        savedLogicalHeight = Round(height, 1),
        savedUiScale = (scale ~= nil and scale > 0) and Round(scale, 10000) or nil,
        normalizedCenterX = Round(centerX, 1000000),
        normalizedCenterY = Round(centerY, 1000000),
    }
end

F.Commands = {}
function F.Commands:Refresh(reason) return F:Refresh(reason) end
function F.Commands:SelectProfile(profileId)
    local profile = ProfileById(profileId); if profile == nil then return false, "方案不存在" end
    F.State.selectedId = profile.id
    F.Authority:Refresh("profile_select")
    return true
end
function F.Commands:CreateProfile(name)
    name = Trim(name)
    if name == "" then return false, "请输入方案名称" end
    if #name > 32 then return false, "方案名称最多 32 个字符" end
    if #(F.State.profiles or {}) >= MAX_PROFILES then return false, "最多创建 " .. tostring(MAX_PROFILES) .. " 个方案" end
    local newId = math.max(1, math.floor(tonumber(F.State.nextId) or 1))
    local ok, err = F:Persist("feature_profile_create", function(state)
        state.profiles[#state.profiles + 1] = { id = newId, name = name, modules = { team_feature_split_linked = true }, quick = true } -- 中文维护：新方案独立记录两个团队功能，标记不属于可控模块。
        state.nextId, state.selectedId = newId + 1, newId
        return true
    end)
    if ok == true then
        F.Stats.creates = (tonumber(F.Stats.creates) or 0) + 1
        F.Authority.lastOperation = "已创建方案“" .. name .. "”；默认所有可控功能为关闭，可按需要勾选。"
        Emit("info", "FEATURE_PROFILE_CREATED", "已创建功能方案", { profileId = newId, name = name })
        F.Authority:Refresh("profile_created")
        return true, newId
    end
    return false, err
end
function F.Commands:RenameProfile(profileId, name)
    name = Trim(name); if name == "" then return false, "请输入方案名称" end
    if #name > 32 then return false, "方案名称最多 32 个字符" end
    local profile = ProfileById(profileId); if profile == nil then return false, "方案不存在" end
    local ok, err = F:Persist("feature_profile_rename", function() profile.name = name; return true end)
    if ok == true then F.Authority.lastOperation = "方案已重命名为“" .. name .. "”"; F.Authority:Refresh("profile_renamed") end
    return ok, err
end
function F.Commands:DeleteProfile(profileId)
    local profile, index = ProfileById(profileId); if profile == nil then return false, "方案不存在" end
    local deletedName = profile.name
    local ok, err = F:Persist("feature_profile_delete", function(state)
        table.remove(state.profiles, index)
        if tonumber(state.selectedId) == tonumber(profileId) then state.selectedId = state.profiles[1] and state.profiles[1].id or nil end
        return true
    end)
    if ok == true then
        if tonumber(F.RuntimeState.lastAppliedId) == tonumber(profileId) then F.RuntimeState.lastAppliedId = nil end
        if tonumber(F.RuntimeState.activeProfileId) == tonumber(profileId) then F.RuntimeState.activeProfileId = nil end
        F.Stats.deletes = (tonumber(F.Stats.deletes) or 0) + 1
        F.Authority.lastOperation = "已删除方案“" .. tostring(deletedName) .. "”；当前功能运行状态未改变。"
        Emit("info", "FEATURE_PROFILE_DELETED", "已删除功能方案", { profileId = profileId, name = deletedName })
        F.Authority:Refresh("profile_deleted")
    end
    return ok, err
end
function F.Commands:SetModule(profileId, featureId, enabled)
    local profile = ProfileById(profileId); if profile == nil then return false, "请先选择方案" end
    featureId = NormalizeId(featureId)
    local meta = Registry:Get(featureId)
    if IsControllable(meta) ~= true then return false, "该功能不允许加入方案控制：" .. tostring(featureId) end
    local visible = false
    for _, row in ipairs(F:GetControllableFeatureRows()) do if row.id == featureId then visible = true; break end end
    if not visible then return false, "该功能已从当前左侧导航隐藏" end -- 中文维护：旧页面选择/陈旧调用不得越过当前导航目录。
    local target = enabled == true
    local ok, err = F:Persist("feature_profile_module:" .. featureId, function()
        profile.modules = type(profile.modules) == "table" and profile.modules or {}
        if profile.modules.team_feature_split_linked ~= true then
            if ProfileTarget(profile, "combat_sac_highlight") then profile.modules.combat_sac_highlight = true end
            profile.modules.team_feature_split_linked = true -- 中文维护：先保留历史双开语义，再修改当前用户指定的单个功能。
        end
        if target then profile.modules[featureId] = true else profile.modules[featureId] = nil end
        return true
    end)
    if ok == true then
        F.Authority.lastOperation = "方案“" .. tostring(profile.name) .. "”：" .. tostring(meta.name) .. " → " .. (target and "开启" or "关闭")
        F.Authority:Refresh("profile_module_changed")
    end
    return ok, err
end
function F.Commands:CaptureCurrent(profileId)
    local profile = ProfileById(profileId); if profile == nil then return false, "请先选择方案" end
    -- 2026-10-06：获取当前始终重读同源导航目录，不复用上一次页面 moduleRows。
    -- 删除/合并模块、完成标签和个人隐藏由 Registry/Workspace 解释；显式捕获才替换旧开启集合。
    -- 功能方案仍只捕获 FeatureRuntime 开关，不跨权威读取/写入游戏键位或业务配置。
    local currentRows=F:GetControllableFeatureRows()
    local enabledCount=0
    local nextModules = { team_feature_split_linked = true } -- 中文维护：捕获真实独立开关，不借旧团队中心位推断视觉开关。
    for _, row in ipairs(currentRows) do
        if Runtime:IsEnabled(row.id) == true then nextModules[row.id] = true;enabledCount=enabledCount+1 end
    end
    local ok, err = F:Persist("feature_profile_capture_current", function() profile.modules = nextModules; return true end)
    if ok == true then
        F.Authority.lastOperation = "已按最新功能目录同步方案“"..tostring(profile.name).."”：开启 "..enabledCount.."/"..#currentRows.." 项。"
        F.Authority:Refresh("profile_captured")
        return true,F.Authority.lastOperation
    end
    return ok, err
end
function F.Commands:SetQuick(profileId, visible)
    local profile = ProfileById(profileId); if profile == nil then return false, "请先选择方案" end
    local target = visible == true
    local ok, err = F:Persist("feature_profile_quick_visibility", function() profile.quick = target; return true end)
    if ok == true then
        F.Authority.lastOperation = "方案快捷按钮已" .. (target and "显示" or "隐藏")
        F.Authority:Refresh("profile_quick_visibility")
    end
    return ok, err
end
function F.Commands:MoveProfile(profileId, delta)
    local _, index = ProfileById(profileId); if index == nil then return false, "方案不存在" end
    delta = tonumber(delta); if delta == nil or delta == 0 then return false, "移动方向无效" end
    local target = index + (delta < 0 and -1 or 1)
    if target < 1 or target > #(F.State.profiles or {}) then return false, "方案已在边界" end
    local ok, err = F:Persist("feature_profile_move", function(state)
        state.profiles[index], state.profiles[target] = state.profiles[target], state.profiles[index]
        return true
    end)
    if ok == true then F.Authority:Refresh("profile_moved") end
    return ok, err
end
function F.Commands:ApplyProfile(profileId)
    local profile = ProfileById(profileId); if profile == nil then return false, "请选择要应用的方案" end
    if type(Runtime.ApplyPreferenceTargets) ~= "function" then return false, "FeatureRuntime 批量事务能力不可用" end
    local targets = BuildTargets(profile)
    F.applying, F.pendingLifecycleRefresh = true, false
    local ok, detail, failure = Runtime:ApplyPreferenceTargets(targets, "feature_profile:" .. tostring(profile.id))
    F.applying = false
    if ok ~= true then
        F.Stats.applyFailures = (tonumber(F.Stats.applyFailures) or 0) + 1
        -- 维护（feature-profile-failure-evidence-1）：失败目标由 Runtime 的结构化结果给出，
        -- 不从错误字符串猜 id，不忽略故障模块，也不偷偷取消用户的方案勾选。
        failure = type(failure) == "table" and Copy(failure) or { stage = "unknown" }
        failure.profileId, failure.profileName = profile.id, profile.name
        failure.error = tostring(detail or "未知原因")
        local meta = failure.featureId ~= nil and Registry:Get(failure.featureId) or nil
        failure.featureName = meta and tostring(meta.name or failure.featureId) or failure.featureId
        failure.route = meta and tostring(meta.route or "") or nil
        local message
        if failure.featureName ~= nil then
            message = "应用失败：" .. failure.featureName .. (failure.targetEnabled == true and "无法开启" or "无法关闭")
        elseif failure.stage == "persist" then message = "应用失败：功能开关保存失败"
        elseif failure.stage == "preflight" then message = "应用未开始：功能开关预检失败"
        else message = "应用失败：请查看模块诊断" end
        if failure.rollbackSucceeded == false then message = message .. "；回滚未完成，请检查诊断。"
        elseif failure.rollbackSucceeded == true and failure.rollbackAttempted == true then message = message .. "；已回滚本次开关变更。"
        elseif failure.rollbackSucceeded == true then message = message .. "；未提交开关变更。" end
        failure.message = message
        F.RuntimeState.lastApplyFailure = failure
        F.Authority.lastOperation = message
        F.pendingLifecycleRefresh = false
        Emit("error", "FEATURE_PROFILE_APPLY_FAILED", "功能方案应用失败；失败目标与回滚结果见证据", {
            profileId = profile.id, name = profile.name, error = failure.error,
            featureId = failure.featureId, targetEnabled = failure.targetEnabled, stage = failure.stage,
            rollbackSucceeded = failure.rollbackSucceeded, rollbackError = failure.rollbackError,
        })
        F.Authority:Refresh("profile_apply_failed")
        return false, message, Copy(failure)
    end
    F.RuntimeState.lastApplyFailure = nil -- 只在实际应用成功后解除上次失败状态；历史错误池不清除。
    F.State.selectedId = profile.id
    F.RuntimeState.lastAppliedId = profile.id
    F.Stats.applies = (tonumber(F.Stats.applies) or 0) + 1
    F.Authority.lastOperation = "已应用方案“" .. tostring(profile.name) .. "”：开启已选功能，关闭其它可控功能。"
    Emit("info", "FEATURE_PROFILE_APPLIED", "功能方案已应用", {
        profileId = profile.id, name = profile.name,
        targets = type(detail) == "table" and detail.targets or nil,
        changed = type(detail) == "table" and detail.changed or nil,
    })
    F.pendingLifecycleRefresh = false
    F.Authority:Refresh("profile_applied")
    return true, F.Authority.lastOperation
end
function F.Commands:SetQuickPosition(profileId, x, y, placement, viewportIntent)
    local profile = ProfileById(profileId); if profile == nil then return false, "方案不存在" end
    local nx, ny = tonumber(x), tonumber(y); if nx == nil or ny == nil then return false, "按钮位置无效" end
    local responsive = NormalizeResponsivePlacement(placement)
    local intent = NormalizeViewportIntent(viewportIntent)
    local ok, err = F:Persist("feature_profile_quick_position", function()
        profile.quickX, profile.quickY = math.floor(nx + 0.5), math.floor(ny + 0.5)
        profile.quickPositionCustomized = true
        profile.quickCoordinateSpace = responsive and responsive.coordinateSpace or nil
        profile.quickAnchorH = responsive and responsive.anchorH or nil
        profile.quickAnchorV = responsive and responsive.anchorV or nil
        profile.quickOffsetX = responsive and responsive.offsetX or nil
        profile.quickOffsetY = responsive and responsive.offsetY or nil
        -- 维护：viewport intent 只能来自真实拖动提交。旧 edge-only 行保持 nil，绝不在启动/重排时补写。
        profile.quickSavedLogicalWidth = intent and intent.savedLogicalWidth or nil
        profile.quickSavedLogicalHeight = intent and intent.savedLogicalHeight or nil
        profile.quickSavedUiScale = intent and intent.savedUiScale or nil
        profile.quickNormalizedCenterX = intent and intent.normalizedCenterX or nil
        profile.quickNormalizedCenterY = intent and intent.normalizedCenterY or nil
        return true
    end)
    if ok == true then F.Authority:Refresh("profile_quick_position") end
    return ok, err
end
function F.Commands:ResetQuickPositions()
    local changed = false
    for _, profile in ipairs(F.State.profiles or {}) do
        if profile.quickPositionCustomized == true or profile.quickX ~= nil or profile.quickY ~= nil or profile.quickCoordinateSpace ~= nil then changed = true; break end
    end
    if not changed then return true end
    local ok, err = F:Persist("feature_profile_quick_positions_reset", function(state)
        for _, profile in ipairs(state.profiles or {}) do
            profile.quickX, profile.quickY, profile.quickPositionCustomized = nil, nil, false
            profile.quickCoordinateSpace, profile.quickAnchorH, profile.quickAnchorV = nil, nil, nil
            profile.quickOffsetX, profile.quickOffsetY = nil, nil
            profile.quickSavedLogicalWidth, profile.quickSavedLogicalHeight, profile.quickSavedUiScale = nil, nil, nil
            profile.quickNormalizedCenterX, profile.quickNormalizedCenterY = nil, nil
        end
        return true
    end)
    if ok == true then F.Authority:Refresh("profile_quick_positions_reset") end
    return ok, err
end

function F:GetHealth()
    return {
        ok = self.Authority.error == nil,
        status = self.Authority.status,
        profileCount = #(self.State.profiles or {}),
        controllableCount = #(self:GetControllableFeatureRows()),
        consumerCount = tonumber(self.consumerCount) or 0,
        applies = tonumber(self.Stats.applies) or 0,
        applyFailures = tonumber(self.Stats.applyFailures) or 0,
        applyStatus = self.RuntimeState.lastApplyFailure ~= nil and "failed" or (self.RuntimeState.lastAppliedId ~= nil and "applied" or "idle"),
        lastOperation = self.Authority.lastOperation,
    }
end

-- 中文维护注释（2026-09-25，feature-profile-diagnostics-1）：模块诊断 Provider 只读取已经存在的
-- Store/Runtime 投影，不主动 LoadStore、不切 Feature、不创建 UI。这样方案应用失败时可以从模块右上角
-- 诊断直接区分“存档未加载 / 最近方案已偏离 / 正在批量切换”等状态，而不会让诊断本身成为第二 Authority。
if type(S.ModuleDiagnosticsHub) == "table" and type(S.ModuleDiagnosticsHub.RegisterProvider) == "function" then
    S.ModuleDiagnosticsHub:RegisterProvider(F.Id, "feature_profile_state", function()
        local profileStore = type(P.GetStore) == "function" and P:GetStore(F.storeId) or nil
        local preferenceStore = type(P.GetStore) == "function" and P:GetStore(Runtime.preferenceStoreId) or nil
        -- 维护（2026-09-25，feature-profile-store-evidence-1）：方案 Store 是否真的落到
        -- SaveData 必须可直接从诊断读出，而不是靠“重启后按钮没了”反推。这里只读已存在的
        -- Persistence Store 元数据（key/loadStatus/dirty/revision/lastError），不 LoadStore、
        -- 不 MarkDirty、不写任何存档。
        local quickRows = {}
        for _, profile in ipairs(F.State.profiles or {}) do
            quickRows[#quickRows + 1] = {
                profileId = tonumber(profile.id),
                name = tostring(profile.name or ""),
                quick = profile.quick ~= false,
                customized = profile.quickPositionCustomized == true,
                x = profile.quickX, y = profile.quickY,
                edge = profile.quickCoordinateSpace,
                anchorH = profile.quickAnchorH, anchorV = profile.quickAnchorV,
                offsetX = profile.quickOffsetX, offsetY = profile.quickOffsetY,
                viewportWidth = profile.quickSavedLogicalWidth,
                viewportHeight = profile.quickSavedLogicalHeight,
                viewportUiScale = profile.quickSavedUiScale,
                centerX = profile.quickNormalizedCenterX,
                centerY = profile.quickNormalizedCenterY,
                hasViewportIntent = profile.quickSavedLogicalWidth ~= nil and profile.quickNormalizedCenterX ~= nil,
            }
        end
        return {
            contractVersion = F.ContractVersion,
            storeLoaded = F.storeLoaded == true,
            storeStatus = type(profileStore) == "table" and tostring(profileStore.loadStatus or "registered") or "unavailable",
            storeKey = type(profileStore) == "table" and tostring(profileStore.key or "") or "",
            storeResolvedKey = type(profileStore) == "table" and tostring(profileStore.resolvedKey or "") or "",
            storeFenced = type(profileStore) == "table" and profileStore.writeFenced == true or false,
            storeFenceReason = type(profileStore) == "table" and tostring(profileStore.writeFenceReason or "") or "",
            storeLastError = type(profileStore) == "table" and tostring(profileStore.lastError or "") or "",
            storeDirtyRevision = type(profileStore) == "table" and tonumber(profileStore.dirtyRevision) or nil,
            storeLastSavedRevision = type(profileStore) == "table" and tonumber(profileStore.lastSavedRevision) or nil,
            storeSaveFailures = type(profileStore) == "table" and tonumber(profileStore.consecutiveSaveFailures) or nil,
            storeDirty = type(profileStore) == "table" and profileStore.dirty == true or false,
            quickPlacements = quickRows,
            preferenceLoaded = Runtime.preferencesLoaded == true,
            preferenceStatus = type(preferenceStore) == "table" and tostring(preferenceStore.loadStatus or "registered") or "unavailable",
            preferenceFenced = type(preferenceStore) == "table" and preferenceStore.writeFenced == true or false,
            profileCount = #(F.State.profiles or {}),
            selectedId = F.State.selectedId,
            activeProfileId = F.RuntimeState.activeProfileId,
            lastAppliedId = F.RuntimeState.lastAppliedId,
            dirty = F.RuntimeState.dirty == true,
            applying = F.applying == true,
            consumerCount = tonumber(F.consumerCount) or 0,
            controllableCount = #(F:GetControllableFeatureRows()),
            applies = tonumber(F.Stats.applies) or 0,
            applyFailures = tonumber(F.Stats.applyFailures) or 0,
            -- 维护（feature-profile-failure-evidence-1）：只读本次会话已有证据；不为收集
            -- 失败目标而 GetHealth/LoadStore/Initialize，也不把本模块正常 Store 当作故障来源。
            applyStatus = F.RuntimeState.lastApplyFailure ~= nil and "failed" or (F.RuntimeState.lastAppliedId ~= nil and "applied" or "idle"),
            lastApplyFailure = Copy(F.RuntimeState.lastApplyFailure),
            mutations = tonumber(F.Stats.mutations) or 0,
            lastOperation = F.Authority.lastOperation,
            lastError = F.Authority.error,
        }
    end, 35)
end

local lease, leaseErr = Demand:Create({
    id = "feature:" .. F.Id,
    owner = F,
    projectionOwner = F,
    projectionConsumersField = "consumers",
    projectionCountField = "consumerCount",
    reconcile = function(l, before, after) return F:ReconcileDemand(l, before, after) end,
})
if lease == nil then error(leaseErr or "feature profile demand failed") end
F.Demand = lease

local registered, registerErr = Runtime:RegisterImplementation(F.Id, F)
if registered ~= true then error(registerErr or "feature profile runtime registration failed") end
