-- Replicated Suite · 活动追踪设置存储
-- 作者：Replicated
-- QQ群：1104129461
-- 仅拥有活动表现偏好。schema8 固定 Store 所有的 FloatingSurface v11 字段投影，schema7 仅为精确完整性恢复保留历史 canonical Generation。
-- 窗口几何、透明度、最小化属 Presentation 偏好，Gameplay 事实只归 ActivityAuthority。
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

local STORE_ID = "v3.activities" -- 保留原 Store key，不清旧配置。
local STORE_SCHEMA = 8 -- schema8 冻结窗口字段；共享 normalizer 加字段时须显式升 schema。
local LEGACY_SCHEMA = 7 -- 直接上一代为 schema7，更早无元数据旧档仍由 Core 迁移。
local ACTIVITY_BUDGET = { maxDepth = 7, maxNodes = 200, maxStringBytes = 4096, maxEntriesPerTable = 112 }
local Floating = S.RSUI and S.RSUI.FloatingSurface or nil
if type(Floating) ~= "table" or type(Floating.NormalizeState) ~= "function" then error("FloatingSurface unavailable for Activities store") end

local function NormalizeWindow(value)
    return Floating:NormalizeState(value, {
        defaultWidth = WINDOW_SIZE.defaultWidth, defaultHeight = WINDOW_SIZE.defaultHeight,
        minWidth = WINDOW_SIZE.minWidth, minHeight = WINDOW_SIZE.minHeight,
        defaultOverallOpacity = 0.94, defaultBackgroundOpacity = 1.0, defaultTextOpacity = 1.0,
    })
end

local CURRENT_WINDOW_KEYS = { -- 冻结 schema8 字段，避免共享 FloatingSurface 扩展改变旧章。
    "width", "height", "minimized", "locked",
    "overallOpacity", "backgroundOpacity", "textOpacity", "fontScale", "userMoved",
    "x", "y", "anchorH", "anchorV", "offsetX", "offsetY", "coordinateSpace", "savedUiScale",
    "savedLogicalWidth", "savedLogicalHeight", "normalizedCenterX", "normalizedCenterY",
}
local HISTORICAL_V7_WINDOW_KEYS = { -- schema7 历史字段，只用于旧章恢复。
    "width", "height", "minimized", "locked",
    "overallOpacity", "backgroundOpacity", "textOpacity", "fontScale", "userMoved",
    "x", "y", "anchorH", "anchorV", "offsetX", "offsetY", "coordinateSpace", "savedUiScale",
}

local function ProjectWindow(normalized, keys)
    local out = {}
    for _, key in ipairs(keys) do
        if normalized[key] ~= nil then out[key] = normalized[key] end -- 保留显式 false/0。
    end
    return out
end

local function NormalizeWindowV8(value)
    return ProjectWindow(NormalizeWindow(value), CURRENT_WINDOW_KEYS)
end

local function NormalizeWindowHistoricalV7(value) -- 只供 schema7 恢复，正常读写不能调用。
    return ProjectWindow(NormalizeWindow(value), HISTORICAL_V7_WINDOW_KEYS)
end

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
        widgetWindow = NormalizeWindowV8(value.widgetWindow),
    }
end

local function NormalizeHistoricalV7(value)
    local normalized = Normalize(value)
    normalized.widgetWindow = NormalizeWindowHistoricalV7(type(value) == "table" and value.widgetWindow or nil)
    return normalized
end

local ACTIVITY_TOP_KEYS = { widgetVisible = true, widgetRows = true, hiddenEvents = true, widgetWindow = true }
local ACTIVITY_WINDOW_KEYS = { opacity = true } -- 早期 opacity 别名仅用于旧形验证。
for _, key in ipairs(CURRENT_WINDOW_KEYS) do ACTIVITY_WINDOW_KEYS[key] = true end

local function HasOnlyKeys(value, allowed)
    if type(value) ~= "table" then return false end
    for key in pairs(value) do if allowed[key] ~= true then return false end end
    return true
end

local function ValidateKnownV7Payload(value)
    if HasOnlyKeys(value, ACTIVITY_TOP_KEYS) ~= true then return false end
    if value.widgetVisible ~= nil and type(value.widgetVisible) ~= "boolean" then return false end
    if value.widgetRows ~= nil and tonumber(value.widgetRows) == nil then return false end
    if value.hiddenEvents ~= nil then
        if type(value.hiddenEvents) ~= "table" then return false end
        for key, enabled in pairs(value.hiddenEvents) do
            if type(key) ~= "string" or key == "" or enabled ~= true then return false end
        end
    end
    if value.widgetWindow ~= nil then
        if HasOnlyKeys(value.widgetWindow, ACTIVITY_WINDOW_KEYS) ~= true then return false end
        for _, key in ipairs({ "minimized", "locked", "userMoved" }) do if value.widgetWindow[key] ~= nil and type(value.widgetWindow[key]) ~= "boolean" then return false end end
        for _, key in ipairs({ "width", "height", "opacity", "overallOpacity", "backgroundOpacity", "textOpacity", "fontScale", "x", "y", "offsetX", "offsetY", "savedUiScale", "savedLogicalWidth", "savedLogicalHeight", "normalizedCenterX", "normalizedCenterY" }) do if value.widgetWindow[key] ~= nil and tonumber(value.widgetWindow[key]) == nil then return false end end
        for _, key in ipairs({ "anchorH", "anchorV", "coordinateSpace" }) do if value.widgetWindow[key] ~= nil and type(value.widgetWindow[key]) ~= "string" then return false end end
    end
    return true
end

local KNOWN_V7_STAMP = "6271E40B" -- 2026-09-09 RU schema7 已核实旧章。
local KNOWN_V8_CANONICAL = "7E85D975" -- 同一事故的当前 canonical，须与旧章同时命中。
local KNOWN_V8_TRANSPORT_V1_STAMP = "6963CEA5" -- 2026-09-10 Framework3/Transport1 实机旧章。
local KNOWN_V8_TRANSPORT_V1_READBACK = "109696BD" -- 同次回读当前章，只接受精确 pair。
local KNOWN_V8_TRANSPORT_V2_STAMP = "4195953A" -- Transport2 重写后仍漂移的实机旧章；字段完整，数字呈 float32 形态，机制未完全确认。
local KNOWN_V8_TRANSPORT_V2_READBACK = "5804B4B5" -- 4195953A 的配对当前章。

local function RecoverKnownActivityCanonical(decoded, stampedFingerprint, currentCanonical, raw) -- 仅接受已核实事故的精确 old/new pair，Core 仍作最终验证。
    local meta = type(raw) == "table" and raw.__rsmeta or nil
    if type(meta) ~= "table" or tostring(meta.store or "") ~= STORE_ID or tostring(meta.owner or "") ~= "v3.activities" then return nil end
    local source = type(raw.payload) == "table" and raw.payload or nil -- 候选只能来自 envelope.payload，不能取当前 UI 或默认值。
    if source == nil or ValidateKnownV7Payload(source) ~= true then return nil end
    local currentFingerprint = P:FingerprintDurablePayload(currentCanonical, ACTIVITY_BUDGET)

    if tonumber(meta.schema) == 7 and tostring(stampedFingerprint or "") == KNOWN_V7_STAMP
        and tostring(currentFingerprint or "") == KNOWN_V8_CANONICAL then
        return Normalize(decoded), "activities_schema7_known_pair_6271E40B_7E85D975"
    end

    if tonumber(meta.schema) == STORE_SCHEMA and tonumber(meta.framework) == 3 and tonumber(meta.transportVersion) == 1
        and tostring(stampedFingerprint or "") == KNOWN_V8_TRANSPORT_V1_STAMP
        and tostring(currentFingerprint or "") == KNOWN_V8_TRANSPORT_V1_READBACK then
        return Normalize(decoded), "activities_schema8_transport1_known_pair_6963CEA5_109696BD" -- 已物理丢失的字段无法由 Hash 反推；保留可解释设置，由 Core 用当前 Transport 重写。
    end

    if tonumber(meta.schema) == STORE_SCHEMA and tonumber(meta.framework) == 3 and tonumber(meta.transportVersion) == 2
        and tostring(stampedFingerprint or "") == KNOWN_V8_TRANSPORT_V2_STAMP
        and tostring(currentFingerprint or "") == KNOWN_V8_TRANSPORT_V2_READBACK then
        return Normalize(decoded), "activities_schema8_transport2_known_pair_4195953A_5804B4B5"
    end
    return nil
end

F.PersistenceStoreSchemaContractVersion = STORE_SCHEMA
F.PersistenceWindowCanonicalContractVersion = 1
F.KnownLegacyCanonicalRecoveryContractVersion = 3 -- 结构化零值恢复优先，known-pair 仅为旧代兜底。
F.TransportV1ZeroOmissionRecoveryContractVersion = 1

-- Transport1 可能省略合法 x/y=0，导致 logical-free-v2 的整组定位字段不被识别。
-- 只枚举补回 0 的候选，Core 必须用原 stamped fingerprint 精确验证；无命中继续写保护，不能通配接受。
local TRANSPORT_V1_ZERO_WINDOW_KEYS = { -- free 依赖 x/y：缺一个会连带丢掉整个自由定位分支。
    "x", "y", -- free 分支的唯一前置条件，0 表示贴左/上边缘。
    "normalizedCenterX", "normalizedCenterY", -- 跨分辨率归一化中心，拖到边界时为 0。
    "savedLogicalWidth", "savedLogicalHeight", -- `free and tonumber(...) or nil`，x/y 塌陷时连带丢失。
    "overallOpacity", "backgroundOpacity", "textOpacity", -- Clamp fallback 为 0.94/1.0/1.0，与用户显式设置的 0 无法在磁盘上区分。
    "savedUiScale", -- 不依赖 free；原值为 0 时会直接丢成 nil。
    "offsetX", "offsetY", -- fallback 也是 0，理论安全，纳入枚举成本极低。
}
local MAX_TRANSPORT_V1_ZERO_CANDIDATES = 1024 -- 最多 2^10 候选，只按实际缺失字段枚举。

local function RebuildTransportV1ZeroOmission(decoded, stampedFingerprint, rawEnvelope)
    local store = P:GetStore(STORE_ID)
    local function Probe(reason, extra)
        if type(store) ~= "table" then return end
        store.lastHistoricalRecoveryProbe = "transportV1Zero/" .. tostring(reason)
            .. (extra ~= nil and ("/" .. tostring(extra)) or "")
    end
    local meta = type(rawEnvelope) == "table" and rawEnvelope.__rsmeta or nil
    local metaSchema = meta ~= nil and tonumber(meta.schema) or nil
    local metaFramework = meta ~= nil and tonumber(meta.framework) or nil
    local metaTransport = meta ~= nil and tonumber(meta.transportVersion) or nil
    local metaDesc = "schema=" .. tostring(metaSchema) .. "/fw=" .. tostring(metaFramework) .. "/tv=" .. tostring(metaTransport)
    if type(meta) ~= "table" or metaSchema ~= STORE_SCHEMA or metaFramework ~= 3 then -- 仅当前 schema8/Framework3，schema7 走专用恢复。
        Probe("skip_generation", metaDesc)
        return nil
    end
    if metaTransport ~= 1 then -- 仅 Transport1 未保护 0；其它世代不能借此恢复。
        Probe("skip_transport_v2", metaDesc)
        return nil
    end
    local payload = type(rawEnvelope) == "table" and rawEnvelope.payload or nil
    if type(payload) ~= "table" then
        Probe("skip_no_payload", metaDesc)
        return nil
    end
    local rawWindow = type(payload.widgetWindow) == "table" and payload.widgetWindow or nil
    if rawWindow == nil then -- 窗口子树缺失不能凭空合成。
        Probe("skip_no_window", metaDesc)
        return nil
    end
    local missing, present = {}, {}
    for _, key in ipairs(TRANSPORT_V1_ZERO_WINDOW_KEYS) do
        if rawWindow[key] == nil then missing[#missing + 1] = key else present[#present + 1] = key end -- 只枚举 nil，磁盘已有字段不动。
    end
    if #missing == 0 then
        Probe("skip_no_missing_zero_key", metaDesc .. "/present=" .. table.concat(present, ","))
        return nil
    end
    local zeroKeys = #missing
    local combinations = 2 ^ zeroKeys
    if combinations > MAX_TRANSPORT_V1_ZERO_CANDIDATES then
        Probe("skip_too_many", metaDesc .. "/missing=" .. table.concat(missing, ","))
        return nil
    end
    local baseDomain = {
        widgetVisible = payload.widgetVisible,
        widgetRows = payload.widgetRows,
        hiddenEvents = payload.hiddenEvents,
        widgetWindow = rawWindow,
    }
    for mask = 1, combinations - 1 do -- mask=0 就是刚失败的当前 canonical，无需重试。
        local candidateWindow = DeepCopy(rawWindow)
        local bits = mask
        for index = 1, zeroKeys do
            if bits % 2 == 1 then candidateWindow[missing[index]] = 0 end
            bits = math.floor(bits / 2)
        end
        local candidateDomain = {
            widgetVisible = baseDomain.widgetVisible,
            widgetRows = baseDomain.widgetRows,
            hiddenEvents = baseDomain.hiddenEvents,
            widgetWindow = candidateWindow,
        }
        local candidateCanonical = Normalize(candidateDomain) -- 补 0 后仍走正式 normalizer，可能重新满足 free 条件。
        local candidateFingerprint = P:FingerprintCanonicalValue(store, candidateCanonical)
        if candidateFingerprint ~= nil and tostring(candidateFingerprint) == tostring(stampedFingerprint) then
            Probe("match", "mask=" .. tostring(mask) .. "/keys=" .. tostring(zeroKeys) .. "/missing=" .. table.concat(missing, ",") .. "/" .. metaDesc)
            return candidateCanonical, Normalize(candidateDomain)
        end
    end
    Probe("no_match", "tried=" .. tostring(combinations - 1) .. "/missing=" .. table.concat(missing, ",") .. "/present=" .. table.concat(present, ",") .. "/" .. metaDesc)
    return nil
end

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
        schemaVersion = STORE_SCHEMA,
        legacySchemaVersion = LEGACY_SCHEMA,
        key = P.V3KeyPrefix .. "activities",
        budget = ACTIVITY_BUDGET,
        default = function() return Normalize(nil) end,
        get = function() return Normalize(F.State) end,
        apply = Apply,
        migrate = function(value) return Normalize(value) end,
        rebuildCanonicalForIntegrity = function(decoded, stampedFingerprint, _currentCanonical, raw)
            local meta = type(raw) == "table" and raw.__rsmeta or nil
            if type(meta) == "table" and tonumber(meta.schema) == 7 then
                return NormalizeHistoricalV7(decoded)
            end
            -- `.18.198` 新增分支——schema8 + Framework3 + Transport v1 下，FloatingSurface 窗口中合法为 0 的字段会被原生 serializer 省略；该机制可结构化证明，因此先于内容相关的 known-pair。
            return RebuildTransportV1ZeroOmission(decoded, stampedFingerprint, raw)
        end,
        recoverKnownLegacyCanonical = RecoverKnownActivityCanonical, -- 仅注册过的精确 pair 可恢复，其它 mismatch 保留 Fence。
        allowIntegrityUpgrade = true,
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
    -- 位置、折叠、锁定和外观最终提交立即保存/回读；连续预览不走此入口。
    if reason == "widget_geometry" or reason == "widget_layout_reset" or reason == "widget_minimized" or reason == "widget_locked" or reason == "widget_lock"
        or reason == "widget_overall_opacity" or reason == "widget_background_opacity" or reason == "widget_text_opacity" or reason == "widget_font_scale" then
        return P:SaveStore(STORE_ID, { durable=true, consumeDirty=true, reason=reason })
    end
    return P:MarkDirty(STORE_ID, tonumber(delayMs) or 500, reason or "activity_changed")
end

function F:MutateStore(mutator, delayMs, reason, durable)
    if type(P.MutateStore) ~= "function" then return false, "活动持久化事务不可用" end
    return P:MutateStore(STORE_ID, function() return mutator() end, {
        delayMs = tonumber(delayMs) or 500, reason = tostring(reason or "activity_changed"), durable = durable == true,
    })
end

-- 独立 v3.activities.detail_tracking 只保存哪些 main objective 计入个人 x/y，任务事实仍归 QuestProgressV3，related/Boss 不入分母。
-- schema1 详情收藏迁移到 schema2 时重置为未配置=全选，避免旧收藏意外改变 0/6；首次取消才保存子集，空集合有效。
-- 只允许静态组 opt-in，当前为 crimson；主 Store schema8 和窗口/隐藏偏好不受影响。
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

-- Integrity 在迁移前重建 canonical，schema1 必须用原 codec1 验证，不能直接用 codec2 将健康旧档判坏。
-- 仅原 Store/owner、schema1/codec1 可走此历史 helper；先精确命中旧章，再迁移为 schema2 默认全选并重盖。
-- 旧 related 收藏仅用于复现旧章，迁移后不进入新分母；未来 codec 升级也须保留各代只读 canonical。
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
F.ProgressSelectionContractVersion = 2 -- 所有已验证多目标活动采用个人分母选择；单目标保持固定分母。

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
        -- 先用发布过的 codec1 精确验证 schema1 旧章，再执行 1→2；Integrity 校验早于迁移。
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

-- 缺选择桶或 Store 读取失败时，Gameplay 展示回退默认全选，偏好写保护不能抹去标准0/6。返回 available=false，调用方可禁用编辑但仍展示真实默认进度。
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
    -- 陈旧/仅未知 token 桶不能产生0/0，按未配置全选处理；下次显式编辑再按当前已核实目录生成标准桶。
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
        -- 全选归一化为 nil；无配置表示全部主目标选中。
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

-- 兼容名称仅为窄包装，必须提供当前合格目录，禁止恢复任意关联任务书签的旧语义。
function F:GetDetailTrackedKeys(eventKey, eligibleTokens)
    local selected = self:GetDetailProgressSelection(eventKey, eligibleTokens)
    return selected
end

function F:IsDetailTaskTracked(eventKey, token, eligibleTokens)
    local selected = self:GetDetailProgressSelection(eventKey, eligibleTokens)
    return type(selected) == "table" and selected[tostring(token or "")] == true or false
end
