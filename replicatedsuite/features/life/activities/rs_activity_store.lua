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
local KNOWN_V8_TRANSPORT_V1_STAMP = "6963CEA5" -- 中文维护注释：2026-09-10 RU 实机在 Framework3/Transport v1 上保存活动设置后记录的原 canonical 指纹；它不是通用“活动坏档”白名单。
local KNOWN_V8_TRANSPORT_V1_READBACK = "109696BD" -- 中文维护注释：同一次 SaveData→LoadData 回读后活动 payload 经 schema8 canonical 得到的实机 Hash；必须与上面的 old stamp 成对命中。
local KNOWN_V8_TRANSPORT_V2_STAMP = "4195953A" -- 中文维护注释：`.18.198` 实机第二轮——`.18.197` 已按 Transport v2 重写过的活动存档再次出现跨重载指纹漂移；磁盘取证确认字段完整、值为 float32 舍入形态，漂移机制仍未完全定位，但内容完好可证明。
local KNOWN_V8_TRANSPORT_V2_READBACK = "5804B4B5" -- 中文维护注释：与 4195953A 成对的当前重算 Hash；两者必须同时命中才允许一次性迁移。

local function RecoverKnownActivityCanonical(decoded, stampedFingerprint, currentCanonical, raw) -- 中文维护注释：活动 Store 自己拥有已知 canonical/transport 事故的恢复资格；Core 只负责机制与最终 exact-hash 证明，Feature/UI 不参与。
    local meta = type(raw) == "table" and raw.__rsmeta or nil -- 中文维护注释：该 raw 已经过 Core 的物理预算、Transport 解码与 Envelope Seal 验证；这里仍再次限定 Store/owner/schema/transport，避免跨 Store 借用恢复。
    if type(meta) ~= "table" or tostring(meta.store or "") ~= STORE_ID or tostring(meta.owner or "") ~= "v3.activities" then return nil end -- 中文维护注释：任何其它 Store/owner 即使碰巧 Hash 相同也必须 fail-closed。
    local source = type(raw.payload) == "table" and raw.payload or nil -- 中文维护注释：plain Store 的业务 Authority 只来自 Persistence envelope.payload；禁止根据 UI 当前值或默认值猜测磁盘内容。
    if source == nil or ValidateKnownV7Payload(source) ~= true then return nil end -- 中文维护注释：schema7/8 共享同一 bounded 字段形状；未知根字段/非法类型一律拒绝恢复，防止损坏数据被吞掉。
    local currentFingerprint = P:FingerprintDurablePayload(currentCanonical, ACTIVITY_BUDGET) -- 中文维护注释：恢复资格必须同时证明“当前磁盘解码内容”正好落在已观测的新 Hash，而不是只看旧 stamp。

    if tonumber(meta.schema) == 7 and tostring(stampedFingerprint or "") == KNOWN_V7_STAMP
        and tostring(currentFingerprint or "") == KNOWN_V8_CANONICAL then -- 中文维护注释：保留 `.18.192` schema7→8 canonical generation 的旧 exact pair；其它 schema7 mismatch 继续 Fence。
        return Normalize(decoded), "activities_schema7_known_pair_6271E40B_7E85D975" -- 中文维护注释：恢复后仅保留 Normalize 可证明的用户偏好，由 Core 立即按当前 schema/canonical 重盖。
    end

    if tonumber(meta.schema) == STORE_SCHEMA and tonumber(meta.framework) == 3 and tonumber(meta.transportVersion) == 1
        and tostring(stampedFingerprint or "") == KNOWN_V8_TRANSPORT_V1_STAMP
        and tostring(currentFingerprint or "") == KNOWN_V8_TRANSPORT_V1_READBACK then -- 中文维护注释：`.18.196` 新事故必须同时满足 schema8 + Framework3 + Transport v1 + exact old/readback Hash，禁止放宽成 wildcard。
        return Normalize(decoded), "activities_schema8_transport1_known_pair_6963CEA5_109696BD" -- 中文维护注释：Transport v1 已经物理丢失的字段无法从 32 位 Hash 反推；这里保留磁盘仍能严格解释的全部设置，并让 Core 以 Transport v2 重新持久化，阻断同类再次发生。
    end

    if tonumber(meta.schema) == STORE_SCHEMA and tonumber(meta.framework) == 3 and tonumber(meta.transportVersion) == 2
        and tostring(stampedFingerprint or "") == KNOWN_V8_TRANSPORT_V2_STAMP
        and tostring(currentFingerprint or "") == KNOWN_V8_TRANSPORT_V2_READBACK then -- 中文维护注释：`.18.198` 第二轮实机事故——Transport v2 重写后的存档仍跨重载漂移，说明 RU udf 的表示损失不止已知的哨兵类别；磁盘取证确认业务字段完整，因此继续 exact pair 一次性迁移并保留数据。
        return Normalize(decoded), "activities_schema8_transport2_known_pair_4195953A_5804B4B5" -- 中文维护注释：恢复后由 Core 立即重盖；漂移的根因已列入下一轮磁盘取证计划（udf 数字为 float32 形态已实证）。
    end
    return nil -- 中文维护注释：任何未知 mismatch 都继续进入 Persistence write fence；以后必须依赖新版 readback divergence 证据定位真实字段，不能继续追加宽泛容错。
end -- 中文维护注释：结束活动已知事故恢复桥；本函数只在 integrity mismatch 冷路径执行，不进入活动刷新/Tick。

F.PersistenceStoreSchemaContractVersion = STORE_SCHEMA -- 中文维护注释：暴露给 Acceptance/Foundation 的活动 Store schema 契约版本，防止后续增量包漏改测试而静默回退。
F.PersistenceWindowCanonicalContractVersion = 1 -- 中文维护注释：标记活动窗口 canonical 已从共享可演进表收敛为 Store-owned 字段投影。
F.KnownLegacyCanonicalRecoveryContractVersion = 3 -- 中文维护注释：v3 在 v2 的两个 exact-pair 之上，新增 Framework3 + Transport v1 的**零值省略结构化恢复**；内容相关的 known-pair 退回为更早世代的兜底，未知 mismatch 仍由 Core Fence。
F.TransportV1ZeroOmissionRecoveryContractVersion = 1 -- 中文维护注释：单独暴露 `.18.198` 的 Transport v1 零值省略恢复契约，让 Foundation/Acceptance 钉死「可结构化证明的恢复优先于 known-pair 白名单」这一边界；该路径不读取 Native 游戏状态、不改变活动业务 Authority、只在完整性 mismatch 冷启动执行。

-- 中文维护注释：`.18.198` 活动 Store 的零值省略结构化恢复。活动 HUD 窗口与 DeathReview 使用同一套 FloatingSurface 字段，
-- 因此同样受 Transport v1「不保护数值 0」影响：窗口贴左/上边缘时 x 或 y 合法为 0，被 RU SaveData 省略后
-- `free = moved and coordinateSpace=="logical-free-v2" and tonumber(value.x) ~= nil and tonumber(value.y) ~= nil`
-- 判定失败，x/y/coordinateSpace/savedLogicalWidth/Height/normalizedCenterX/Y 整组自由定位字段一起塌成 nil。
-- 本恢复器只做「把被省略的 0 补回去」这一件可证明的事，候选仍必须由 Core 用旧 stamped fingerprint 做完整
-- exact Hash 校验；命不中即保持 integrity_failed + write fence，绝不放宽成通配接受。
local TRANSPORT_V1_ZERO_WINDOW_KEYS = { -- 中文维护注释：判定依据是 FloatingSurface:NormalizeState 的实际表达式，不是直觉——依赖 free 的字段会随 x/y 塌陷而连带变 nil，不依赖 free 的字段原值为 0 时也会直接丢成 nil。
    "x", "y", -- 中文维护注释：free 分支的唯一前置条件，0 表示贴左/上边缘。
    "normalizedCenterX", "normalizedCenterY", -- 中文维护注释：跨分辨率归一化中心，拖到边界时为 0。
    "savedLogicalWidth", "savedLogicalHeight", -- 中文维护注释：`free and tonumber(...) or nil`，x/y 塌陷时连带丢失。
    "overallOpacity", "backgroundOpacity", "textOpacity", -- 中文维护注释：Clamp fallback 为 0.94/1.0/1.0，与用户显式设置的 0 无法在磁盘上区分。
    "savedUiScale", -- 中文维护注释：不依赖 free；原值为 0 时会直接丢成 nil。
    "offsetX", "offsetY", -- 中文维护注释：fallback 也是 0，理论安全，纳入枚举成本极低。
} -- 中文维护注释：结束可省略零值字段白名单。
local MAX_TRANSPORT_V1_ZERO_CANDIDATES = 1024 -- 中文维护注释：候选上限 2^10；实际数量由「磁盘上真正缺失的字段数」决定，通常远小于此。只在 mismatch 冷启动跑一次。

local function RebuildTransportV1ZeroOmission(decoded, stampedFingerprint, rawEnvelope) -- 中文维护注释：活动 Store 版本的零值恢复；plain Store 没有 codec 包装，因此候选直接构造 Domain 后交给 Normalize。
    local store = P:GetStore(STORE_ID) -- 中文维护注释：提前取 Store 引用，使每个早退分支都能写 runtime-only probe。
    local function Probe(reason, extra) -- 中文维护注释：probe 只写字段名、计数与元数据，绝不输出玩家名、活动内容或自由文本配置。
        if type(store) ~= "table" then return end -- 中文维护注释：Store 未注册时不做写入。
        store.lastHistoricalRecoveryProbe = "transportV1Zero/" .. tostring(reason)
            .. (extra ~= nil and ("/" .. tostring(extra)) or "") -- 中文维护注释：保持单行可复制。
    end
    local meta = type(rawEnvelope) == "table" and rawEnvelope.__rsmeta or nil -- 中文维护注释：恢复资格必须绑定已通过 Envelope Seal 的真实元数据。
    local metaSchema = meta ~= nil and tonumber(meta.schema) or nil
    local metaFramework = meta ~= nil and tonumber(meta.framework) or nil
    local metaTransport = meta ~= nil and tonumber(meta.transportVersion) or nil
    local metaDesc = "schema=" .. tostring(metaSchema) .. "/fw=" .. tostring(metaFramework) .. "/tv=" .. tostring(metaTransport) -- 中文维护注释：一次性记录真实世代，避免以后靠猜。
    if type(meta) ~= "table" or metaSchema ~= STORE_SCHEMA or metaFramework ~= 3 then -- 中文维护注释：只接受当前 schema8 + Framework3；schema7 已有专用历史恢复器。
        Probe("skip_generation", metaDesc)
        return nil
    end
    if metaTransport ~= 1 then -- 中文维护注释：只有 Transport v1 存在数值 0 未保护缺陷；v2 写入后仍 mismatch 说明是真实内容损坏，必须继续 Fence。
        Probe("skip_transport_v2", metaDesc)
        return nil
    end
    local payload = type(rawEnvelope) == "table" and rawEnvelope.payload or nil -- 中文维护注释：plain Store 的业务 Authority 只来自 envelope.payload，禁止从 UI 当前值或默认值猜磁盘内容。
    if type(payload) ~= "table" then -- 中文维护注释：payload 缺失属于损坏 envelope，不恢复。
        Probe("skip_no_payload", metaDesc)
        return nil
    end
    local rawWindow = type(payload.widgetWindow) == "table" and payload.widgetWindow or nil -- 中文维护注释：窗口缺失时不构造候选。
    if rawWindow == nil then -- 中文维护注释：保持 fail-closed，不凭空合成窗口子树。
        Probe("skip_no_window", metaDesc)
        return nil
    end
    local missing, present = {}, {} -- 中文维护注释：分别记录缺失与存在的候选字段，用于诊断判断这一层到底漂移了多少。
    for _, key in ipairs(TRANSPORT_V1_ZERO_WINDOW_KEYS) do -- 中文维护注释：固定小列表遍历。
        if rawWindow[key] == nil then missing[#missing + 1] = key else present[#present + 1] = key end -- 中文维护注释：只把 nil 记为候选位，已存在字段保持磁盘原值不动。
    end -- 中文维护注释：结束字段分类。
    if #missing == 0 then -- 中文维护注释：没有缺失说明本机制不适用。
        Probe("skip_no_missing_zero_key", metaDesc .. "/present=" .. table.concat(present, ","))
        return nil
    end
    local zeroKeys = #missing -- 中文维护注释：缓存候选位数量。
    local combinations = 2 ^ zeroKeys -- 中文维护注释：2^n 枚举「哪些缺失字段原本是 0」。
    if combinations > MAX_TRANSPORT_V1_ZERO_CANDIDATES then -- 中文维护注释：超出预算即放弃，宁可 Fence 也不做无界暴力枚举。
        Probe("skip_too_many", metaDesc .. "/missing=" .. table.concat(missing, ","))
        return nil
    end
    local baseDomain = { -- 中文维护注释：业务字段全部取自 decoded（即磁盘 payload），只有窗口参与候选变化。
        widgetVisible = payload.widgetVisible, -- 中文维护注释：可见性属于活动 HUD 用户偏好，原样保留。
        widgetRows = payload.widgetRows, -- 中文维护注释：行数属于有界整数偏好，原样保留。
        hiddenEvents = payload.hiddenEvents, -- 中文维护注释：隐藏活动集合原样保留，不新增也不删除任何用户数据。
        widgetWindow = rawWindow, -- 中文维护注释：窗口占位，随后按候选替换。
    } -- 中文维护注释：结束候选基础 Domain。
    for mask = 1, combinations - 1 do -- 中文维护注释：mask=0 与当前 canonical 等价，无需重复校验。
        local candidateWindow = DeepCopy(rawWindow) -- 中文维护注释：每个候选独立副本，禁止跨候选共享引用。
        local bits = mask -- 中文维护注释：逐位解释；第 i 位为 1 表示 missing[i] 原本是 0。
        for index = 1, zeroKeys do -- 中文维护注释：最多 #missing 次循环。
            if bits % 2 == 1 then candidateWindow[missing[index]] = 0 end -- 中文维护注释：把被省略的 0 补回。
            bits = math.floor(bits / 2) -- 中文维护注释：右移一位继续。
        end -- 中文维护注释：结束单个候选的字段补零。
        local candidateDomain = { -- 中文维护注释：其他字段复用 baseDomain，避免重复构造整份隐藏集合。
            widgetVisible = baseDomain.widgetVisible,
            widgetRows = baseDomain.widgetRows,
            hiddenEvents = baseDomain.hiddenEvents,
            widgetWindow = candidateWindow,
        } -- 中文维护注释：结束单个候选 Domain。
        local candidateCanonical = Normalize(candidateDomain) -- 中文维护注释：候选必须走当前 Store normalizer，与真实保存路径完全一致（例如补回 x=0 会让 free 分支重新成立）。
        local candidateFingerprint = P:FingerprintCanonicalValue(store, candidateCanonical) -- 中文维护注释：候选没有信任权，只有与旧 stamp 逐字相等才可能被 Core 接受。
        if candidateFingerprint ~= nil and tostring(candidateFingerprint) == tostring(stampedFingerprint) then -- 中文维护注释：exact match 是唯一接受条件。
            Probe("match", "mask=" .. tostring(mask) .. "/keys=" .. tostring(zeroKeys) .. "/missing=" .. table.concat(missing, ",") .. "/" .. metaDesc)
            return candidateCanonical, Normalize(candidateDomain) -- 中文维护注释：Core 随后仍会预算、Apply 并按当前 Transport 版本重盖。
        end -- 中文维护注释：结束候选采纳分支。
    end -- 中文维护注释：结束候选枚举。
    Probe("no_match", "tried=" .. tostring(combinations - 1) .. "/missing=" .. table.concat(missing, ",") .. "/present=" .. table.concat(present, ",") .. "/" .. metaDesc) -- 中文维护注释：全部候选未命中时记录完整上下文，作为「真实差异不在零值省略」的证据。
    return nil -- 中文维护注释：未命中即返回 nil，Core 继续维持 integrity_failed + write fence。
end -- 中文维护注释：结束活动 Store 的 Transport v1 零值省略恢复器。

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
        rebuildCanonicalForIntegrity = function(decoded, stampedFingerprint, _currentCanonical, raw) -- 中文维护注释：current-v4 mismatch 时优先尝试可证明的结构化历史 canonical，known-pair 只是 exact 重建失败后的最后桥。
            local meta = type(raw) == "table" and raw.__rsmeta or nil -- 中文维护注释：历史候选必须绑定旧元数据 schema，禁止当前/future schema 借用旧 normalizer。
            if type(meta) == "table" and tonumber(meta.schema) == 7 then -- 中文维护注释：仅 schema7 候选有资格剥离 schema8 新窗口字段。
                return NormalizeHistoricalV7(decoded) -- 中文维护注释：Core 会自行计算候选 Hash；只有逐字等于旧 stamp 才把它视为认证历史逻辑值。
            end -- 中文维护注释：结束 schema7 历史候选分支。
            -- 中文维护注释：`.18.198` 新增分支——schema8 + Framework3 + Transport v1 下，FloatingSurface 窗口中合法为 0 的字段会被原生 serializer 省略；该机制可结构化证明，因此先于内容相关的 known-pair。
            return RebuildTransportV1ZeroOmission(decoded, stampedFingerprint, raw)
        end, -- 中文维护注释：结束活动 Store 的历史 canonical 恢复入口；两条分支都必须由 Core 重新 Hash 认证。
        recoverKnownLegacyCanonical = RecoverKnownActivityCanonical, -- 中文维护注释：只处理两个已实证 exact pair：6271E40B→7E85D975 与 schema8/Transport-v1 的 6963CEA5→109696BD；其余 mismatch 继续 Fence。
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

------------------------------------------------------------------------
-- Activity personal progress-selection preferences (isolated Store)
--
-- 中文维护注释（2026-09-21，activity-progress-selection-1）：
-- 问题原因：上一版把“追踪”做成纯详情收藏，因此征兆无论用户勾选几项都固定显示 0/6；真实需求是
-- “被勾选的主任务就是个人进度集合”，例如只保留后三阶段时必须显示 0/3。Authority：本 Store 只拥有
-- “哪些 Activity main objective 计入个人 x/y”的偏好；Quest 完成/进行中/可交付事实仍由 QuestProgressV3
-- 独占，related/Boss 旁支若在 relatedObjectives 中则永远只是参考，不能进入分母。数据流：QuestProgressV3
-- 发布稳定 main token + 状态 -> Activities Feature 用本 Store 选择集合投影 personalized progress -> Activity
-- Authority/详情 UI 只消费投影。兼容边界：物理 Store ID 保持 `v3.activities.detail_tracking`，但 schema1 的
-- “详情收藏”语义错误，schema2 迁移时明确重置为“未配置=默认全选”，避免旧收藏突然改变玩家 0/6；主
-- `v3.activities` schema8、窗口几何、hiddenEvents 均不触碰。实现理由：未配置用“隐式全选”，只有用户
-- 第一次取消某项才物化子集，既满足旧用户默认 0/6，也减少持久化体积。风险/维护：当前只允许静态组显式
-- opt-in（首个是 crimson）；未来其它活动必须先核验其主任务语义后再开启，禁止全局自动套用。
------------------------------------------------------------------------
local DETAIL_TRACKING_STORE_ID = "v3.activities.detail_tracking"
local DETAIL_TRACKING_SCHEMA = 2
local DETAIL_TRACKING_CODEC = 2
local DETAIL_TRACKING_MAX_GROUPS = 64
local DETAIL_TRACKING_MAX_TOKENS = 24

local function NormalizeDetailTrackingToken(value)
    local token = tostring(value or "")
    if token == "" or #token > 128 then return nil end
    return token
end

local function NormalizeDetailTracking(value)
    value = type(value) == "table" and value or {}
    local source = type(value.groups) == "table" and value.groups or {}
    local groups, groupCount = {}, 0
    for rawKey, rawBucket in pairs(source) do
        local groupKey = tostring(rawKey or "")
        if groupKey ~= "" and #groupKey <= 96 and groupCount < DETAIL_TRACKING_MAX_GROUPS then
            local tokens, tokenCount = {}, 0
            local tokenSource = type(rawBucket) == "table" and rawBucket or {}
            for rawToken, enabled in pairs(tokenSource) do
                local candidate = nil
                if enabled == true then candidate = rawToken
                elseif type(rawToken) == "number" and type(enabled) == "string" then candidate = enabled end
                local token = NormalizeDetailTrackingToken(candidate)
                -- schema2 只持久化主进度身份；任何旧 related 收藏在迁移/归一时都丢弃，避免旁支进入分母。
                if token ~= nil and string.sub(token, 1, 5) == "main:" and tokens[token] ~= true
                    and tokenCount < DETAIL_TRACKING_MAX_TOKENS then
                    tokens[token] = true
                    tokenCount = tokenCount + 1
                end
            end
            -- 空 bucket 不落盘：缺失 group 就是“未配置，默认全选”。显式 0 项没有业务意义，Command
            -- 也会拒绝取消最后一项，因此这里不需要第二种空集合表示。
            if tokenCount > 0 then
                groups[groupKey] = tokens
                groupCount = groupCount + 1
            end
        end
    end
    return { groups = groups }
end

local function SortedDetailTrackingGroups(value)
    local normalized = NormalizeDetailTracking(value)
    local keys = {}
    for key in pairs(normalized.groups) do keys[#keys + 1] = key end
    table.sort(keys)
    local out = {}
    for _, key in ipairs(keys) do
        local tokens = {}
        for token in pairs(normalized.groups[key]) do tokens[#tokens + 1] = token end
        table.sort(tokens)
        out[#out + 1] = { key = key, tokens = tokens }
    end
    return out
end

local function EncodeDetailTracking(value)
    return {
        codec = DETAIL_TRACKING_CODEC,
        payload = { groups = SortedDetailTrackingGroups(value) },
    }
end

local function DecodeDetailTracking(raw)
    if type(raw) ~= "table" then return nil, "activity_progress_selection_payload_required" end
    local payload = type(raw.payload) == "table" and raw.payload or raw
    local rows = type(payload.groups) == "table" and payload.groups or {}
    local domain = { groups = {} }
    if rows[1] ~= nil then
        for _, row in ipairs(rows) do
            if type(row) == "table" then
                local key = tostring(row.key or "")
                if key ~= "" and type(row.tokens) == "table" then domain.groups[key] = row.tokens end
            end
        end
    else
        domain.groups = rows
    end
    return NormalizeDetailTracking(domain), nil
end

-- 中文维护注释（2026-09-21，activity-progress-selection-schema1-integrity-recovery）：
-- 问题原因：detail_tracking 的 schema1 使用 codec=1，schema2 为了改变“收藏”语义升级为 codec=2。Persistence
-- Integrity v4 会在 schema migration **之前**用当前 typed codec 重建 canonical，因此一个完全健康的 schema1
-- 空 Store 会从旧指纹 1013634B 被当前 codec 重算成 5CF32E2D 并正确触发 fence。Authority：这组 helper
-- 只重建 schema1 自己当时的逻辑/编码形状，不能读取当前 UI、Quest 状态或用户默认值；Core 仍必须用磁盘
-- stamped fingerprint 做 exact match 后才允许继续。数据流：raw schema1 envelope -> 历史 decoder/normalizer ->
-- codec1 canonical -> Core exact hash 认证 -> 现有 migrate(value,1,2) -> schema2“未配置=默认全选” -> 立即重盖。
-- 兼容边界：schema2/current/future schema、非本 Store/owner、非 codec1 一律不进入恢复；旧 schema1 即使曾收藏
-- related task，也只用于复现旧章，随后仍由既有 migration 明确丢弃，绝不把旧收藏偷渡成新 denominator。
-- 实现理由：结构化历史 canonical 比硬编码某一 old>new Hash 对更稳健，既能覆盖空 Store，也能覆盖 schema1
-- 里任意合法 bounded 收藏组合。风险/维护：未来若再次升级 typed codec，必须保留对应旧 generation 的只读
-- canonical helper；禁止修改本 schema1 helper 来“统一”新格式，否则已发布旧章将再次无法认证。
local DETAIL_TRACKING_HISTORICAL_V1_CODEC = 1

local function NormalizeDetailTrackingHistoricalV1(value)
    value = type(value) == "table" and value or {}
    local source = type(value.groups) == "table" and value.groups or {}
    local groups, groupCount = {}, 0
    for rawKey, rawBucket in pairs(source) do
        local groupKey = tostring(rawKey or "")
        if groupKey ~= "" and #groupKey <= 96 and groupCount < DETAIL_TRACKING_MAX_GROUPS then
            local tokens, tokenCount = {}, 0
            local tokenSource = type(rawBucket) == "table" and rawBucket or {}
            for rawToken, enabled in pairs(tokenSource) do
                local candidate = nil
                if enabled == true then candidate = rawToken
                elseif type(rawToken) == "number" and type(enabled) == "string" then candidate = enabled end
                local token = NormalizeDetailTrackingToken(candidate)
                -- schema1 的真实业务语义允许 main/related/其它已核验详情 token；这里必须原样保留该历史规则，
                -- 否则 related 收藏会在 old-hash 认证前被当前 schema2 normalizer 删除，无法证明旧数据健康。
                if token ~= nil and tokens[token] ~= true and tokenCount < DETAIL_TRACKING_MAX_TOKENS then
                    tokens[token] = true
                    tokenCount = tokenCount + 1
                end
            end
            if tokenCount > 0 then
                groups[groupKey] = tokens
                groupCount = groupCount + 1
            end
        end
    end
    return { groups = groups }
end

local function EncodeDetailTrackingHistoricalV1(value)
    local normalized = NormalizeDetailTrackingHistoricalV1(value)
    local groupKeys = {}
    for key in pairs(normalized.groups) do groupKeys[#groupKeys + 1] = key end
    table.sort(groupKeys)
    local rows = {}
    for _, key in ipairs(groupKeys) do
        local tokens = {}
        for token in pairs(normalized.groups[key]) do tokens[#tokens + 1] = token end
        table.sort(tokens)
        rows[#rows + 1] = { key = key, tokens = tokens }
    end
    return { codec = DETAIL_TRACKING_HISTORICAL_V1_CODEC, payload = { groups = rows } }
end

local function DecodeDetailTrackingHistoricalV1(raw)
    if type(raw) ~= "table" then return nil, "schema1_raw_required" end
    local payload = type(raw.payload) == "table" and raw.payload or raw
    if payload.groups ~= nil and type(payload.groups) ~= "table" then return nil, "schema1_groups_invalid" end
    local rows = type(payload.groups) == "table" and payload.groups or {}
    local domain = { groups = {} }
    if rows[1] ~= nil then
        for _, row in ipairs(rows) do
            if type(row) ~= "table" then return nil, "schema1_group_row_invalid" end
            local key = tostring(row.key or "")
            if key ~= "" then
                if type(row.tokens) ~= "table" then return nil, "schema1_tokens_invalid" end
                domain.groups[key] = row.tokens
            end
        end
    else
        -- schema1 decoder 曾显式接受 bare map 作为中断开发版本的兼容表示；历史 canonical 也必须保留这一
        -- 读取边界，但最终候选仍会重新编码成正式 codec1 排序数组并由旧 stamp 精确认证。
        domain.groups = rows
    end
    return NormalizeDetailTrackingHistoricalV1(domain), nil
end

local function RebuildDetailTrackingSchema1Canonical(_decoded, stampedFingerprint, _currentCanonical, raw)
    local store = P:GetStore(DETAIL_TRACKING_STORE_ID)
    local function Probe(reason, extra)
        if type(store) ~= "table" then return end
        store.lastHistoricalRecoveryProbe = "activity_progress_schema1/" .. tostring(reason)
            .. (extra ~= nil and ("/" .. tostring(extra)) or "")
    end
    local meta = type(raw) == "table" and raw.__rsmeta or nil
    if type(meta) ~= "table"
        or tostring(meta.store or "") ~= DETAIL_TRACKING_STORE_ID
        or tostring(meta.owner or "") ~= "v3.activities.detail_tracking"
        or tonumber(meta.schema) ~= 1 then
        Probe("skip_generation", "schema=" .. tostring(meta and meta.schema or nil))
        return nil
    end
    if tonumber(raw.codec) ~= DETAIL_TRACKING_HISTORICAL_V1_CODEC then
        Probe("skip_codec", "codec=" .. tostring(raw.codec))
        return nil
    end
    local historicalDomain, decodeErr = DecodeDetailTrackingHistoricalV1(raw)
    if type(historicalDomain) ~= "table" then
        Probe("decode_failed", tostring(decodeErr or "unknown"))
        return nil
    end
    local historicalCanonical = EncodeDetailTrackingHistoricalV1(historicalDomain)
    -- Store hook 自己先做一次 exact match，可把“不适用”与“候选不匹配”写进模块诊断；Persistence Core
    -- 随后还会独立重算并再次要求同一 old stamp，故此处不是绕过完整性层。
    local candidateFingerprint = type(P.FingerprintCanonicalValue) == "function"
        and P:FingerprintCanonicalValue(store, historicalCanonical) or nil
    if candidateFingerprint ~= nil and tostring(candidateFingerprint) ~= tostring(stampedFingerprint or "") then
        Probe("candidate_mismatch", "old=" .. tostring(stampedFingerprint) .. "/cand=" .. tostring(candidateFingerprint))
        return nil
    end
    Probe("candidate", "old=" .. tostring(stampedFingerprint) .. "/cand=" .. tostring(candidateFingerprint or "defer_core"))
    return historicalCanonical, historicalDomain
end

local function NormalizeEligibleTokens(values)
    local ordered, set = {}, {}
    for _, raw in ipairs(type(values) == "table" and values or {}) do
        local token = NormalizeDetailTrackingToken(type(raw) == "table" and raw.trackingKey or raw)
        if token ~= nil and string.sub(token, 1, 5) == "main:" and set[token] ~= true then
            ordered[#ordered + 1] = token
            set[token] = true
        end
    end
    return ordered, set
end

local function CopyTokenSet(source)
    local out = {}
    for token, enabled in pairs(type(source) == "table" and source or {}) do if enabled == true then out[token] = true end end
    return out
end

local function CountTokenSet(source)
    local count = 0
    for _, enabled in pairs(type(source) == "table" and source or {}) do if enabled == true then count = count + 1 end end
    return count
end

F.DetailTrackingState = NormalizeDetailTracking(F.DetailTrackingState)
F.DetailTrackingStoreId = DETAIL_TRACKING_STORE_ID
F.DetailTrackingStoreLoaded = F.DetailTrackingStoreLoaded == true
F.DetailTrackingContractVersion = 3
F.ProgressSelectionContractVersion = 2 -- v2: all verified multi-objective event groups use personal denominator selection; one-objective groups stay fixed.

local function ApplyDetailTracking(value)
    F.DetailTrackingState = NormalizeDetailTracking(value)
end

if P:GetStore(DETAIL_TRACKING_STORE_ID) == nil then
    local detailStore, detailStoreErr = P:RegisterV3Store({
        id = DETAIL_TRACKING_STORE_ID,
        owner = "v3.activities.detail_tracking",
        scope = P.Scope.Account,
        lifetime = P.Lifetime.Permanent,
        schemaVersion = DETAIL_TRACKING_SCHEMA,
        legacySchemaVersion = 1,
        key = P.V3KeyPrefix .. "activities_detail_tracking",
        budget = { maxDepth = 6, maxNodes = 4096, maxStringBytes = 262144, maxEntriesPerTable = 256 },
        default = function() return NormalizeDetailTracking(nil) end,
        get = function() return NormalizeDetailTracking(F.DetailTrackingState) end,
        apply = ApplyDetailTracking,
        encode = EncodeDetailTracking,
        decode = DecodeDetailTracking,
        migrate = function(value, fromSchema)
            -- schema1 是错误的“详情收藏”语义。不能把其中用户随手收藏的一两个任务直接解释成新
            -- denominator，否则升级后征兆可能从 0/6 突然变成 0/1。明确重置为未配置=默认全选。
            if tonumber(fromSchema) == 1 then return NormalizeDetailTracking(nil) end
            return NormalizeDetailTracking(value)
        end,
        -- typed-codec schema 升级发生在 Integrity v4 校验之后；必须先用发布过的 codec1 精确重建旧 canonical，
        -- 让 Core 验证旧 stamp，再进入上面的 1→2 migration。否则健康 schema1 会因 codec=1→2 被永久 fence。
        rebuildCanonicalForIntegrity = RebuildDetailTrackingSchema1Canonical,
        allowIntegrityUpgrade = true,
    })
    if detailStore == nil and S.DiagnosticsManager ~= nil and type(S.DiagnosticsManager.Error) == "function" then
        S.DiagnosticsManager:Error("activities_v3", "ACTIVITY_PROGRESS_SELECTION_STORE_REGISTER_FAILED",
            "活动个人进度选择存档注册失败", { error = tostring(detailStoreErr or "unknown") })
    end
end

function F:EnsureDetailTrackingLoaded()
    if self.DetailTrackingStoreLoaded == true and type(P.IsStoreLoaded) == "function"
        and P:IsStoreLoaded(DETAIL_TRACKING_STORE_ID) == true then return true end
    if P:GetStore(DETAIL_TRACKING_STORE_ID) == nil then return false, "活动个人进度选择存档不可用" end
    local status, _, err = P:LoadStore(DETAIL_TRACKING_STORE_ID)
    if status == true or status == "empty" then
        if status == "empty" then ApplyDetailTracking(nil) end
        self.DetailTrackingStoreLoaded = true
        return true
    end
    return false, err or tostring(status or "活动个人进度选择读取失败")
end

-- Read projection: missing bucket means default-all. A Store read failure also falls back to default-all for
-- gameplay display so a Presentation preference fence can never erase the canonical 0/6 progress; callers get
-- `available=false` and can disable editing while still showing truthful default progress.
function F:GetDetailProgressSelection(eventKey, eligibleTokens)
    eventKey = tostring(eventKey or "")
    local ordered, eligible = NormalizeEligibleTokens(eligibleTokens)
    local defaults = {}; for _, token in ipairs(ordered) do defaults[token] = true end
    if eventKey == "" or #ordered == 0 then return defaults, false, false, "no_eligible_progress_tasks" end
    local loaded, loadErr = self:EnsureDetailTrackingLoaded()
    if loaded ~= true then return defaults, false, false, loadErr or "活动个人进度选择读取失败" end
    local bucket = type(self.DetailTrackingState.groups[eventKey]) == "table" and self.DetailTrackingState.groups[eventKey] or nil
    if bucket == nil then return defaults, false, true, nil end
    local selected = {}
    for token in pairs(eligible) do if bucket[token] == true then selected[token] = true end end
    -- Stale/unknown-only bucket cannot produce 0/0. Treat it as unconfigured default-all; the next explicit edit
    -- will canonicalize the bucket from the current verified objective catalog.
    if next(selected) == nil then return defaults, false, true, nil end
    return selected, true, true, nil
end

function F:SetDetailProgressTaskSelected(eventKey, token, enabled, eligibleTokens, source)
    eventKey, token = tostring(eventKey or ""), NormalizeDetailTrackingToken(token)
    if eventKey == "" or #eventKey > 96 or token == nil or string.sub(token, 1, 5) ~= "main:" then
        return false, "活动个人进度任务身份无效"
    end
    local ordered, eligible = NormalizeEligibleTokens(eligibleTokens)
    if #ordered == 0 or eligible[token] ~= true then return false, "该任务不属于当前活动主进度集合" end
    if #ordered > DETAIL_TRACKING_MAX_TOKENS then return false, "单个活动可选主任务超过存档上限" end
    local selected, _, available, selectionErr = self:GetDetailProgressSelection(eventKey, ordered)
    if available ~= true then return false, selectionErr or "活动个人进度选择不可用" end
    local target = enabled == true
    local current = selected[token] == true
    if current == target then return true end
    if target ~= true and CountTokenSet(selected) <= 1 then return false, "至少保留 1 个活动进度任务" end
    if type(P.MutateStore) ~= "function" then return false, "活动个人进度持久化事务不可用" end

    local nextSelected = CopyTokenSet(selected)
    if target then nextSelected[token] = true else nextSelected[token] = nil end
    local selectedCount = CountTokenSet(nextSelected)
    local changed, changeErr = P:MutateStore(DETAIL_TRACKING_STORE_ID, function()
        local groups = self.DetailTrackingState.groups
        local existingBucket = type(groups[eventKey]) == "table" and groups[eventKey] or nil
        if existingBucket == nil and selectedCount < #ordered then
            local groupCount = 0
            for _, candidate in pairs(groups) do
                if type(candidate) == "table" and next(candidate) ~= nil then groupCount = groupCount + 1 end
            end
            if groupCount >= DETAIL_TRACKING_MAX_GROUPS then return false, "活动个人进度分组已达到上限" end
        end
        -- Full selection is canonicalized back to nil: no config == all main objectives selected.
        if selectedCount == #ordered then groups[eventKey] = nil
        else groups[eventKey] = CopyTokenSet(nextSelected) end
        return true
    end, {
        delayMs = 250,
        reason = "activity_progress_selection:" .. tostring(source or "detail"),
        durable = false,
    })
    if changed ~= true then return false, changeErr or "活动个人进度选择未保存，已回滚" end
    if S.Events ~= nil and type(S.Events.Publish) == "function" then
        S.Events:Publish("v3.activities.progress_selection", eventKey, token, target, tostring(source or "detail"))
    end
    return true
end

-- Compatibility names remain narrow wrappers for this development generation. They intentionally require the
-- current eligible catalog so no caller can recreate the old “arbitrary related-task bookmark” semantics.
function F:GetDetailTrackedKeys(eventKey, eligibleTokens)
    local selected = self:GetDetailProgressSelection(eventKey, eligibleTokens)
    return selected
end

function F:IsDetailTaskTracked(eventKey, token, eligibleTokens)
    local selected = self:GetDetailProgressSelection(eventKey, eligibleTokens)
    return type(selected) == "table" and selected[tostring(token or "")] == true or false
end
