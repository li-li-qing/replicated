------------------------------------------------------------------------
-- Replicated Suite V3 - Buff Display Target Alias Store (schema 2)
--
-- 中文维护注释（2026-09-27，target-alias-hud-2）：
-- 问题原因：目标“自定义名字”既包含“真实名字 -> 本地备注”的业务映射，也包含该备注在目标
-- HUD 上的显示开关/位置/字号/透明度。名字映射仍然必须独立于 BuffDisplay 大 Store 与 Aura
-- 事实，但 HUD 校准需要有一个可持久化、可撤销的独立几何 Authority；因此 schema2 在同一
-- 小 Store 中增加 hud 配置，不触碰 v3.buff_display / layout / tracking 的历史 canonical。
--
-- Authority：
--   * entries：真实 UnitName -> 本地 alias，账户级永久数据；
--   * enabled/hud：目标自定义名字这一独立 HUD 组件的显示与几何；
--   * Feature 只在 TARGET_CHANGED / 显式编辑边读取 UnitName，并把已解析字符串与 HUD 配置投影
--     给 Presentation；Renderer 不直接访问 Store，也不修改真实角色名。
--
-- 数据流：UnitName(target) -> O(1) TargetAliasIndex -> lane targetAlias -> ProjectPlates
--       + TargetAliasState.hud -> target alias projection -> BuffHeadMarkers。
--
-- 性能边界：最多 256 条，索引只在 Load/显式保存删除时重建；任何 PositionTick / VisualTick /
-- Aura 高频路径禁止遍历 entries 或调用 UnitName。HUD 配置是 4 个标量，投影仅做 O(1) 拷贝。
--
-- 兼容边界：schema1 只有 { enabled, entries }。schema2 通过冻结的 schema1 normalizer 重建旧
-- canonical，并且只有旧 fingerprint 精确命中才允许升级；升级后 hud 取当前发布默认值，既不删除
-- 用户备注也不改变原 enabled。Store 故障只禁用别名编辑/显示，不得阻断状态显示本体。
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local P = S.Persistence
S.Features = S.Features or {}
S.Features.BuffDisplay = S.Features.BuffDisplay or {}
local F = S.Features.BuffDisplay
if type(P) ~= "table" then return end

local STORE_ID = "v3.buff_display.aliases"
local STORE_SCHEMA = 2
local MAX_ENTRIES = 256
local MAX_NAME_BYTES = 96
local MAX_ALIAS_BYTES = 48
local HUD_DEFAULTS = { x = 0, y = -94, fontSize = 12, alpha = 1.0 }

F.TargetAliasStoreId = STORE_ID
F.TargetAliasStoreContractVersion = 2
F.TargetAliasHudCalibrationContractVersion = 1
F.TargetAliasState = type(F.TargetAliasState) == "table" and F.TargetAliasState or { enabled = true, hud = {}, entries = {} }
F.TargetAliasIndex = type(F.TargetAliasIndex) == "table" and F.TargetAliasIndex or {}
F.TargetAliasStoreLoaded = F.TargetAliasStoreLoaded == true
F.TargetAliasStoreError = F.TargetAliasStoreError

local function Copy(value)
    if type(S.Utils) == "table" and type(S.Utils.DeepCopy) == "function" then return S.Utils.DeepCopy(value) end
    if type(value) ~= "table" then return value end
    local out = {}; for key, item in pairs(value) do out[key] = Copy(item) end; return out
end
local function ClampInt(value, lo, hi, fallback)
    local n = math.floor(tonumber(value) or tonumber(fallback) or lo)
    if n < lo then n = lo elseif n > hi then n = hi end
    return n
end
local function ClampFloat(value, lo, hi, fallback)
    local n = tonumber(value) or tonumber(fallback) or lo
    if n < lo then n = lo elseif n > hi then n = hi end
    return n
end
local function Trim(value)
    if type(S.Utils) == "table" and type(S.Utils.Trim) == "function" then return S.Utils.Trim(value) end
    return tostring(value or ""):match("^%s*(.-)%s*$")
end
local function Truncate(value, limit)
    value = tostring(value or "")
    if type(S.Utils) == "table" and type(S.Utils.TruncateUtf8) == "function" then
        return S.Utils.TruncateUtf8(value, limit, "")
    end
    return #value <= limit and value or value:sub(1, limit)
end
local function CleanName(value) return Truncate(Trim(value), MAX_NAME_BYTES) end
local function CleanAlias(value) return Truncate(Trim(value), MAX_ALIAS_BYTES) end

local function NormalizeEntries(value)
    local out, seen = {}, {}
    for _, row in ipairs(type(value) == "table" and value or {}) do
        if #out >= MAX_ENTRIES then break end
        if type(row) == "table" then
            local name, alias = CleanName(row.name), CleanAlias(row.alias)
            if name ~= "" and alias ~= "" and seen[name] ~= true then
                seen[name] = true
                out[#out + 1] = { name = name, alias = alias }
            end
        end
    end
    table.sort(out, function(a, b) return tostring(a.name) < tostring(b.name) end)
    return out
end

local function NormalizeHud(value)
    value = type(value) == "table" and value or {}
    return {
        -- x/y 均是相对目标血条中心的逻辑像素，最终由 Renderer 乘 target plateScale。
        -- y 负值向屏幕上；默认 -94 复现 .18.321 旧“Info 上方固定槽”的视觉位置。
        x = ClampInt(value.x, -400, 400, HUD_DEFAULTS.x),
        y = ClampInt(value.y, -400, 400, HUD_DEFAULTS.y),
        fontSize = ClampInt(value.fontSize, 8, 32, HUD_DEFAULTS.fontSize),
        alpha = ClampFloat(value.alpha, 0.1, 1.0, HUD_DEFAULTS.alpha),
    }
end

-- schema1 冻结 normalizer：严禁以后随 schema2 字段变化修改。Integrity Core 只在旧 schema1
-- envelope 上调用它，并要求该候选重新命中旧 stamped fingerprint，不能成为通用“猜测恢复”。
local function NormalizeSchema1State(value)
    value = type(value) == "table" and value or {}
    return { enabled = value.enabled ~= false, entries = NormalizeEntries(value.entries) }
end

local function NormalizeState(value)
    value = type(value) == "table" and value or {}
    return {
        enabled = value.enabled ~= false,
        hud = NormalizeHud(value.hud),
        entries = NormalizeEntries(value.entries),
    }
end

local function RebuildSchema1Canonical(decoded, stampedFingerprint, _currentCanonical, raw)
    local meta = type(raw) == "table" and raw.__rsmeta or nil
    if type(meta) ~= "table"
        or tostring(meta.store or "") ~= STORE_ID
        or tostring(meta.owner or "") ~= "v3.buff_display.aliases"
        or tonumber(meta.schema) ~= 1 then return nil end
    local historical = NormalizeSchema1State(decoded)
    local store = P:GetStore(STORE_ID)
    if type(store) == "table" and type(P.FingerprintCanonicalValue) == "function" then
        local fp = P:FingerprintCanonicalValue(store, historical)
        if fp ~= nil and tostring(fp) ~= tostring(stampedFingerprint or "") then return nil end
    end
    -- recoveredDomain 必须是 schema2 当前 Domain；Core 会再次 canonicalize 并按当前 schema 迁移。
    return historical, NormalizeState(historical)
end

local function RebuildIndex()
    local index = {}
    for _, row in ipairs(F.TargetAliasState.entries or {}) do
        if type(row) == "table" and type(row.name) == "string" and row.name ~= "" then index[row.name] = row.alias end
    end
    F.TargetAliasIndex = index
end

if P:GetStore(STORE_ID) == nil then
    local store, err = P:RegisterV3Store({
        id = STORE_ID,
        owner = "v3.buff_display.aliases",
        scope = P.Scope and P.Scope.Account or "account",
        lifetime = P.Lifetime and P.Lifetime.Permanent or "permanent",
        schemaVersion = STORE_SCHEMA,
        legacySchemaVersion = 1,
        key = P.V3KeyPrefix and (P.V3KeyPrefix .. "buff_display_aliases") or STORE_ID,
        budget = { maxDepth = 5, maxNodes = 1800, maxStringBytes = 32768, maxEntriesPerTable = 512 },
        default = function() return NormalizeState(nil) end,
        get = function() return NormalizeState(F.TargetAliasState) end,
        apply = function(value)
            F.TargetAliasState = NormalizeState(value)
            RebuildIndex()
            if type(F.InvalidateSettingsCache) == "function" then F:InvalidateSettingsCache() end
            return true
        end,
        migrate = function(value, _fromSchema) return NormalizeState(value) end,
        rebuildCanonicalForIntegrity = RebuildSchema1Canonical,
        allowIntegrityUpgrade = true,
    })
    if store == nil then error(err or "buff display target alias store registration failed") end
end

function F:EnsureTargetAliasStoreLoaded()
    local store = P:GetStore(STORE_ID)
    if store == nil then
        self.TargetAliasStoreError = "目标自定义名字 Store 不可用"
        return false, self.TargetAliasStoreError
    end
    if store.writeFenced == true then
        self.TargetAliasStoreError = tostring(store.writeFenceReason or "目标自定义名字存档写保护")
        return false, self.TargetAliasStoreError
    end
    if self.TargetAliasStoreLoaded == true and store.loaded == true then return true end
    local ok, _, err = P:LoadStore(STORE_ID)
    if ok ~= true and ok ~= "empty" then
        self.TargetAliasStoreError = tostring(err or ok or "目标自定义名字存档读取失败")
        return false, self.TargetAliasStoreError
    end
    if ok == "empty" then self.TargetAliasState = NormalizeState(nil) end
    self.TargetAliasState = NormalizeState(self.TargetAliasState)
    RebuildIndex()
    if type(self.InvalidateSettingsCache) == "function" then self:InvalidateSettingsCache() end
    self.TargetAliasStoreLoaded, self.TargetAliasStoreError = true, nil
    return true
end

function F:GetTargetAliasStoreProjection()
    local loaded, err = self:EnsureTargetAliasStoreLoaded()
    return {
        available = loaded == true,
        enabled = self.TargetAliasState.enabled ~= false,
        hud = Copy(NormalizeHud(self.TargetAliasState.hud)),
        count = #(self.TargetAliasState.entries or {}),
        error = loaded == true and nil or tostring(err or self.TargetAliasStoreError or "存档不可用"),
    }
end

function F:GetTargetAliasHudConfigProjection()
    local state = type(self.TargetAliasState) == "table" and self.TargetAliasState or {}
    local hud = NormalizeHud(state.hud)
    return {
        enabled = state.enabled ~= false,
        x = hud.x, y = hud.y, fontSize = hud.fontSize, alpha = hud.alpha,
    }
end

function F:GetDefaultTargetAliasHudConfig()
    local hud = NormalizeHud(nil)
    return { enabled = true, x = hud.x, y = hud.y, fontSize = hud.fontSize, alpha = hud.alpha }
end

function F:ResolveTargetAlias(name)
    name = CleanName(name)
    if name == "" or self.TargetAliasState.enabled == false then return nil end
    local alias = self.TargetAliasIndex[name]
    return type(alias) == "string" and alias ~= "" and alias or nil
end

function F:IsTargetAliasHeadEnabled()
    return self.TargetAliasState.enabled ~= false and #(self.TargetAliasState.entries or {}) > 0
end

local function Commit(mutator, reason)
    local loaded, loadErr = F:EnsureTargetAliasStoreLoaded()
    if loaded ~= true then return false, loadErr end
    local ok, err = P:MutateStore(STORE_ID, function()
        local working = NormalizeState(F.TargetAliasState)
        local changed, changeErr = mutator(working)
        if changed == false then return false, changeErr end
        F.TargetAliasState = NormalizeState(working)
        return true
    end, { delayMs = 0, durable = true, reason = tostring(reason or "target_alias_changed") })
    -- Persistence 负责事务回滚；无论成功失败都以事务后的实际 State 重建索引/配置缓存，避免旁路缓存失配。
    F.TargetAliasState = NormalizeState(F.TargetAliasState)
    RebuildIndex()
    if type(F.InvalidateSettingsCache) == "function" then F:InvalidateSettingsCache() end
    if ok == true then F.TargetAliasStoreError = nil end
    return ok == true, err
end

function F:SetTargetAliasDisplayEnabled(value, reason)
    local enabled = value == true
    return Commit(function(state) state.enabled = enabled; return true end, reason or "target_alias_display")
end

function F:PersistTargetAliasHudConfig(value, reason)
    value = type(value) == "table" and value or {}
    local enabled = value.enabled ~= false
    local normalizedHud = NormalizeHud(value)
    if type(value.hud) == "table" then normalizedHud = NormalizeHud(value.hud) end
    return Commit(function(state)
        state.enabled = enabled
        state.hud = normalizedHud
        return true
    end, reason or "target_alias_hud")
end

function F:UpsertTargetAlias(name, alias, reason)
    name, alias = CleanName(name), CleanAlias(alias)
    if name == "" then return false, "当前目标名字不可用" end
    if alias == "" then return false, "自定义名字不能为空" end
    return Commit(function(state)
        local found = false
        for _, row in ipairs(state.entries) do
            if row.name == name then row.alias, found = alias, true; break end
        end
        if not found then
            if #state.entries >= MAX_ENTRIES then return false, "自定义名字已达到 256 条上限" end
            state.entries[#state.entries + 1] = { name = name, alias = alias }
        end
        return true
    end, reason or "target_alias_upsert")
end

function F:RemoveTargetAlias(name, reason)
    name = CleanName(name)
    if name == "" then return false, "当前目标名字不可用" end
    return Commit(function(state)
        for index = #state.entries, 1, -1 do
            if state.entries[index].name == name then table.remove(state.entries, index); return true end
        end
        return true -- 删除不存在项保持幂等，避免重复点击制造错误。
    end, reason or "target_alias_remove")
end
