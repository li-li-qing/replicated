------------------------------------------------------------------------
-- Replicated Suite V3 - Activity Feature Store
--
-- Owns Activity presentation preferences only. Schema v8 freezes the Store-owned
-- FloatingSurface v11 field projection; schema v7 remains a historical canonical
-- generation used only for exact integrity recovery. Activity window geometry,
-- opacity and minimized state remain Presentation preferences, while gameplay truth
-- continues to belong exclusively to ActivityAuthority.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local P = S.Persistence
if type(P) ~= "table" or type(P.RegisterV3Store) ~= "function" then return end

S.Features = S.Features or {}
S.Features.Activities = S.Features.Activities or {}
local F = S.Features.Activities
F.WidgetWindowSizePolicy = {
    defaultWidth = 430,
    defaultHeight = 276,
    minWidth = 1,
    minHeight = 1,
}
local WINDOW_SIZE = F.WidgetWindowSizePolicy

F.State = type(F.State) == "table" and F.State or {
    widgetVisible = false,
    widgetRows = 8,
    hiddenEvents = {},
    widgetWindow = { width = WINDOW_SIZE.defaultWidth, height = WINDOW_SIZE.defaultHeight, minimized = false, locked = false, overallOpacity = 0.94, backgroundOpacity = 1.0, textOpacity = 1.0, userMoved = false },
}

local STORE_ID = "v3.activities" -- 中文维护注释：活动偏好继续使用原物理 Store ID，schema 升级只改变 canonical generation，绝不换 key 或清用户配置。
local STORE_SCHEMA = 8 -- 中文维护注释：.18.193 冻结 FloatingSurface v11 窗口字段为 schema8；以后共享窗口 normalizer 再增字段必须先显式升 schema，禁止同 schema 偷换指纹语义。
local LEGACY_SCHEMA = 7 -- 中文维护注释：最近一代带元数据的活动 Store 是 schema7；LoadStore 仍可通过 migrate 处理更早 schema，当前常量只描述直接升级边界。
local ACTIVITY_BUDGET = { maxDepth = 7, maxNodes = 200, maxStringBytes = 4096, maxEntriesPerTable = 112 } -- 中文维护注释：复用既有活动 Store 预算作为恢复后的 Domain/指纹上限，已知旧盖章桥不得绕开 bounded persistence。
local Floating = S.RSUI and S.RSUI.FloatingSurface or nil
if type(Floating) ~= "table" or type(Floating.NormalizeState) ~= "function" then error("FloatingSurface unavailable for Activities store") end

local function NormalizeWindow(value)
    return Floating:NormalizeState(value, {
        defaultWidth = WINDOW_SIZE.defaultWidth, defaultHeight = WINDOW_SIZE.defaultHeight,
        minWidth = WINDOW_SIZE.minWidth, minHeight = WINDOW_SIZE.minHeight,
        defaultOverallOpacity = 0.94, defaultBackgroundOpacity = 1.0, defaultTextOpacity = 1.0,
    })
end

local CURRENT_WINDOW_KEYS = { -- 中文维护注释：schema8 自己声明可持久化的窗口字段集合，避免未来 FloatingSurface Foundation 新增成员后静默改变活动 Store canonical。
    "width", "height", "minimized", "locked", -- 中文维护注释：基础尺寸与交互状态属于活动 HUD 的长期用户偏好，继续参与完整性指纹。
    "overallOpacity", "backgroundOpacity", "textOpacity", "fontScale", "userMoved", -- 中文维护注释：外观与“用户是否主动移动”属于 Presentation 偏好，不进入活动 Gameplay Authority。
    "x", "y", "anchorH", "anchorV", "offsetX", "offsetY", "coordinateSpace", "savedUiScale", -- 中文维护注释：保留既有自由/边缘定位字段，保证旧分辨率布局可继续恢复。
    "savedLogicalWidth", "savedLogicalHeight", "normalizedCenterX", "normalizedCenterY", -- 中文维护注释：FloatingSurface v11 响应式位置意图从 schema8 起正式进入活动 Store 契约。
} -- 中文维护注释：结束 schema8 窗口字段白名单；新增字段必须伴随下一次 schema bump 与历史 canonical。
local HISTORICAL_V7_WINDOW_KEYS = { -- 中文维护注释：冻结 schema7 时代的窗口 canonical，只用于 Load 边界精确复原旧盖章，不作为当前 Domain 写入格式。
    "width", "height", "minimized", "locked", -- 中文维护注释：schema7 历史窗口保留当时已存在的基础字段。
    "overallOpacity", "backgroundOpacity", "textOpacity", "fontScale", "userMoved", -- 中文维护注释：schema7 历史外观字段必须保持不变，才能让 Core 用旧 stamp 做逐字 Hash 证明。
    "x", "y", "anchorH", "anchorV", "offsetX", "offsetY", "coordinateSpace", "savedUiScale", -- 中文维护注释：schema7 不包含后加入的 source-viewport 响应式元数据。
} -- 中文维护注释：历史字段表是只读迁移证据，未来维护禁止为了“统一”把 schema8 新字段补回这里。

local function ProjectWindow(normalized, keys) -- 中文维护注释：把共享 Floating normalizer 的结果投影到 Store 自己的 schema 字段，Foundation 负责语义归一，Store 负责持久化形状 Authority。
    local out = {} -- 中文维护注释：创建全新 bounded 表，避免把共享 normalizer 将来新增的未知字段原样漏进当前 schema。
    for _, key in ipairs(keys) do -- 中文维护注释：字段数固定且仅在 Save/Load 边界执行，不进入 Tick/活动刷新热路径。
        if normalized[key] ~= nil then out[key] = normalized[key] end -- 中文维护注释：Lua nil 不落盘；显式 false/0 仍保留给 canonical normalizer 与当前业务语义。
    end -- 中文维护注释：结束固定窗口字段投影。
    return out -- 中文维护注释：返回 schema-owned 窗口副本，调用者不得反向修改 FloatingSurface Foundation。
end -- 中文维护注释：结束窗口 schema 投影 helper。

local function NormalizeWindowV8(value) -- 中文维护注释：当前活动 Store 唯一窗口 canonical 入口；共享语义归一后只保留 schema8 白名单。
    return ProjectWindow(NormalizeWindow(value), CURRENT_WINDOW_KEYS) -- 中文维护注释：先复用 Foundation 的坐标/透明度规则，再冻结物理持久化形状，兼顾 UI 一致性与升级稳定性。
end -- 中文维护注释：结束 schema8 窗口规范化。

local function NormalizeWindowHistoricalV7(value) -- 中文维护注释：仅供旧 schema7 完整性恢复，禁止 Feature/Widget 正常读写调用。
    return ProjectWindow(NormalizeWindow(value), HISTORICAL_V7_WINDOW_KEYS) -- 中文维护注释：去掉 schema8 响应式字段以重建旧 canonical；Core 仍要求候选 Hash 精确命中旧 stamp。
end -- 中文维护注释：结束 schema7 历史窗口规范化。

local function Normalize(value)
    value = type(value) == "table" and value or {}
    local hidden = {}
    for key, enabled in pairs(type(value.hiddenEvents) == "table" and value.hiddenEvents or {}) do
        key = tostring(key or "")
        if key ~= "" and enabled == true then hidden[key] = true end
    end
    return {
        widgetVisible = value.widgetVisible == true,
        widgetRows = math.max(3, math.min(16, math.floor(tonumber(value.widgetRows) or 8))),
        hiddenEvents = hidden,
        widgetWindow = NormalizeWindowV8(value.widgetWindow), -- 中文维护注释：当前活动状态必须经过 schema8 冻结投影，禁止直接把可演进的共享 FloatingSurface 表作为持久化 canonical。
    }
end

local function NormalizeHistoricalV7(value) -- 中文维护注释：重建 schema7 的旧 canonical 时复用当前业务字段 Normalize，只替换历史窗口投影，避免复制第二套活动业务规则。
    local normalized = Normalize(value) -- 中文维护注释：hiddenEvents/widgetRows/widgetVisible 的业务含义未变，继续由当前 Domain normalizer 统一约束。
    normalized.widgetWindow = NormalizeWindowHistoricalV7(type(value) == "table" and value.widgetWindow or nil) -- 中文维护注释：只有窗口 canonical generation 回退到 schema7，恢复路径不猜活动事件或其它用户设置。
    return normalized -- 中文维护注释：候选本身没有信任权，Persistence Core 会重新 Hash 并要求精确匹配旧 stamp。
end -- 中文维护注释：结束 schema7 历史 canonical helper。

local ACTIVITY_TOP_KEYS = { widgetVisible = true, widgetRows = true, hiddenEvents = true, widgetWindow = true } -- 中文维护注释：已知旧盖章桥只接受活动 Store 的四个历史业务根字段，未知字段继续 fail-closed。
local ACTIVITY_WINDOW_KEYS = { opacity = true } -- 中文维护注释：兼容早期 overallOpacity 前的 opacity 别名；它只参与旧形验证，当前保存仍统一 overallOpacity。
for _, key in ipairs(CURRENT_WINDOW_KEYS) do ACTIVITY_WINDOW_KEYS[key] = true end -- 中文维护注释：允许 schema8 已知窗口字段，循环固定约 21 项且只在脚本加载时执行一次。

local function HasOnlyKeys(value, allowed) -- 中文维护注释：旧盖章恢复必须先做 Store-owned 结构白名单，防止 exact stamp allowlist 变成通用损坏吞错通道。
    if type(value) ~= "table" then return false end -- 中文维护注释：非表 payload 不是合法活动 Store，直接拒绝恢复。
    for key in pairs(value) do if allowed[key] ~= true then return false end end -- 中文维护注释：任何未知根/窗口字段都保持 write fence，不做“尽量读取”。
    return true -- 中文维护注释：仅说明字段名形状合法，具体类型仍由下层验证。
end -- 中文维护注释：结束字段白名单验证。

local function ValidateKnownV7Payload(value) -- 中文维护注释：验证 `.18.192` 实机事故对应 schema7 磁盘 Domain；只验证表示形状，不读取游戏 API 或活动 Runtime。
    if HasOnlyKeys(value, ACTIVITY_TOP_KEYS) ~= true then return false end -- 中文维护注释：根字段必须完全属于活动偏好契约。
    if value.widgetVisible ~= nil and type(value.widgetVisible) ~= "boolean" then return false end -- 中文维护注释：悬浮窗显隐只允许布尔；数值/字符串漂移视为真实损坏。
    if value.widgetRows ~= nil and tonumber(value.widgetRows) == nil then return false end -- 中文维护注释：行数允许 RU 数值表示归一，但必须仍可解释为数字。
    if value.hiddenEvents ~= nil then -- 中文维护注释：隐藏活动集合是 bounded string->true map，恢复时禁止接受嵌套/任意对象。
        if type(value.hiddenEvents) ~= "table" then return false end -- 中文维护注释：集合容器类型改变属于不可证明损坏。
        for key, enabled in pairs(value.hiddenEvents) do -- 中文维护注释：最多受 Store budget 限制；该遍历只发生在一次性失败恢复边界。
            if type(key) ~= "string" or key == "" or enabled ~= true then return false end -- 中文维护注释：正常 Normalize 只保存非空字符串键与 true，其他形状不进入 known-stamp 通道。
        end -- 中文维护注释：结束隐藏活动集合逐项验证。
    end -- 中文维护注释：结束可选 hiddenEvents 验证。
    if value.widgetWindow ~= nil then -- 中文维护注释：窗口可为空/缺失，但存在时必须严格限制为已知 Floating 字段。
        if HasOnlyKeys(value.widgetWindow, ACTIVITY_WINDOW_KEYS) ~= true then return false end -- 中文维护注释：未知窗口成员可能代表未来 schema 或损坏，不能被旧桥吞掉。
        for _, key in ipairs({ "minimized", "locked", "userMoved" }) do if value.widgetWindow[key] ~= nil and type(value.widgetWindow[key]) ~= "boolean" then return false end end -- 中文维护注释：交互布尔保持严格类型，避免 0/1 被误当 Lua true。
        for _, key in ipairs({ "width", "height", "opacity", "overallOpacity", "backgroundOpacity", "textOpacity", "fontScale", "x", "y", "offsetX", "offsetY", "savedUiScale", "savedLogicalWidth", "savedLogicalHeight", "normalizedCenterX", "normalizedCenterY" }) do if value.widgetWindow[key] ~= nil and tonumber(value.widgetWindow[key]) == nil then return false end end -- 中文维护注释：几何/透明度允许 RU 数值表示变化，但拒绝不可解析文本。
        for _, key in ipairs({ "anchorH", "anchorV", "coordinateSpace" }) do if value.widgetWindow[key] ~= nil and type(value.widgetWindow[key]) ~= "string" then return false end end -- 中文维护注释：锚点/坐标空间必须仍是字符串枚举形态。
    end -- 中文维护注释：结束窗口结构验证。
    return true -- 中文维护注释：通过仅表示“形状符合已知 schema7”，最终还必须匹配实机 old/new fingerprint pair。
end -- 中文维护注释：结束活动 known-stamp 形状验证。

local KNOWN_V7_STAMP = "6271E40B" -- 中文维护注释：2026-09-09 RU Fresh Reload 实机重复报告的活动 schema7 旧 v4 盖章；只允许这一精确值进入一次性迁移。
local KNOWN_V8_CANONICAL = "7E85D975" -- 中文维护注释：同一事故磁盘数据经当前 schema8 canonical 得到的 Hash；old 与 new 必须同时命中才允许保留数据。

local function RecoverKnownV7Canonical(decoded, stampedFingerprint, currentCanonical, raw) -- 中文维护注释：Store-owned 一次性恢复桥只处理已证明的 schema7→8 canonical generation 事故，不改变 Persistence Core 通用 fail-closed。
    local meta = type(raw) == "table" and raw.__rsmeta or nil -- 中文维护注释：先读取已被 Envelope Seal 验证过的元数据，用它限定 Store/owner/schema 身份。
    if type(meta) ~= "table" or tonumber(meta.schema) ~= 7 or tostring(meta.store or "") ~= STORE_ID or tostring(meta.owner or "") ~= "v3.activities" then return nil end -- 中文维护注释：任何非 schema7 活动 Store 都不具备该迁移资格。
    if tostring(stampedFingerprint or "") ~= KNOWN_V7_STAMP then return nil end -- 中文维护注释：未知旧指纹继续由 Core 维持 integrity_failed/write fence。
    local source = type(raw.payload) == "table" and raw.payload or nil -- 中文维护注释：plain Store 的真实业务数据只允许来自 Persistence 包封的 payload，禁止从其它字段猜值。
    if source == nil or ValidateKnownV7Payload(source) ~= true then return nil end -- 中文维护注释：即使 stamp 命中，业务形状异常也必须拒绝恢复。
    local currentFingerprint = P:FingerprintDurablePayload(currentCanonical, ACTIVITY_BUDGET) -- 中文维护注释：再次验证当前 canonical 正好等于实机观察的 new Hash，防止同 old stamp 下内容已发生真实变化。
    if tostring(currentFingerprint or "") ~= KNOWN_V8_CANONICAL then return nil end -- 中文维护注释：old/new pair 不完整即 fail-closed，绝不泛化为“活动 Store mismatch 都接受”。
    return Normalize(decoded), "activities_schema7_known_pair_6271E40B_7E85D975" -- 中文维护注释：只返回当前 Domain normalizer 保留下来的用户偏好；Core 仍会预算、migrate、apply 并重盖 schema8。
end -- 中文维护注释：结束活动已知旧盖章一次性恢复桥。

F.PersistenceStoreSchemaContractVersion = STORE_SCHEMA -- 中文维护注释：暴露给 Acceptance/Foundation 的活动 Store schema 契约版本，防止后续增量包漏改测试而静默回退。
F.PersistenceWindowCanonicalContractVersion = 1 -- 中文维护注释：标记活动窗口 canonical 已从共享可演进表收敛为 Store-owned 字段投影。
F.KnownLegacyCanonicalRecoveryContractVersion = 1 -- 中文维护注释：标记活动 Store 注册了 exact old/new pair 恢复能力，诊断可据此区分旧包与新包。

local function Apply(value)
    local normalized = Normalize(value)
    F.State.widgetVisible = normalized.widgetVisible
    F.State.widgetRows = normalized.widgetRows
    F.State.hiddenEvents = normalized.hiddenEvents
    F.State.widgetWindow = normalized.widgetWindow
end

if P:GetStore(STORE_ID) == nil then
    local store, err = P:RegisterV3Store({
        id = STORE_ID,
        owner = "v3.activities",
        scope = P.Scope.Account,
        lifetime = P.Lifetime.Permanent,
        schemaVersion = STORE_SCHEMA, -- 中文维护注释：schema8 是当前活动 canonical generation；旧 schema7 只通过下方历史恢复/迁移读取。
        legacySchemaVersion = LEGACY_SCHEMA, -- 中文维护注释：声明直接上一代 schema7，未盖元数据的更早历史档仍由 migrate/空档规则按 Core 契约处理。
        key = P.V3KeyPrefix .. "activities",
        budget = ACTIVITY_BUDGET, -- 中文维护注释：恢复与正常保存共享同一 bounded Domain 预算，known-stamp 不能扩大活动 Store 内存/序列化上限。
        default = function() return Normalize(nil) end,
        get = function() return Normalize(F.State) end,
        apply = Apply,
        migrate = function(value) return Normalize(value) end, -- 中文维护注释：schema7→8 只做纯 Presentation 偏好归一，不触碰活动进度/Quest Authority，也不读取 Native API。
        rebuildCanonicalForIntegrity = function(decoded, _stampedFingerprint, _currentCanonical, raw) -- 中文维护注释：current-v4 mismatch 时优先尝试可证明的 schema7 历史 canonical，known-pair 只是 exact 重建失败后的最后桥。
            local meta = type(raw) == "table" and raw.__rsmeta or nil -- 中文维护注释：历史候选必须绑定旧元数据 schema，禁止当前/future schema 借用旧 normalizer。
            if type(meta) ~= "table" or tonumber(meta.schema) ~= 7 then return nil end -- 中文维护注释：仅 schema7 候选有资格剥离 schema8 新窗口字段。
            return NormalizeHistoricalV7(decoded) -- 中文维护注释：Core 会自行计算候选 Hash；只有逐字等于旧 stamp 才把它视为认证历史逻辑值。
        end, -- 中文维护注释：结束活动 schema7 exact historical canonical hook。
        recoverKnownLegacyCanonical = RecoverKnownV7Canonical, -- 中文维护注释：仅处理 6271E40B→7E85D975 已知实机 pair；未知 mismatch 继续 Fence。
        allowIntegrityUpgrade = true, -- 中文维护注释：允许通过 Envelope Seal + Store-owned 严格 hook 后一次性重盖；正常 schema8 仍按 Integrity v4 严格验证。
    })
    if store == nil and S.DiagnosticsManager ~= nil and type(S.DiagnosticsManager.Error) == "function" then
        S.DiagnosticsManager:Error("activities_v3", "ACTIVITY_STORE_REGISTER_FAILED", "活动模块存档注册失败", { error = tostring(err) })
    end
end

F.StoreId = STORE_ID
F.StoreLoaded = F.StoreLoaded == true

function F:EnsureStoreLoaded()
    if type(P.IsStoreLoaded) == "function" and P:IsStoreLoaded(STORE_ID) == true then self.StoreLoaded = true; return true end
    local store = P:GetStore(STORE_ID)
    if store == nil then return false, "活动模块存档不可用" end
    local status, _, err = P:LoadStore(STORE_ID)
    if status == true or status == "empty" then
        if status == "empty" then Apply(nil) end
        self.StoreLoaded = true
        return true
    end
    return false, err or tostring(status or "读取失败")
end

function F:MarkStoreDirty(delayMs, reason)
    return P:MarkDirty(STORE_ID, tonumber(delayMs) or 500, reason or "activity_changed")
end

function F:MutateStore(mutator, delayMs, reason, durable)
    if type(P.MutateStore) ~= "function" then return false, "活动持久化事务不可用" end
    return P:MutateStore(STORE_ID, function() return mutator() end, {
        delayMs = tonumber(delayMs) or 500, reason = tostring(reason or "activity_changed"), durable = durable == true,
    })
end
