------------------------------------------------------------------------
-- Replicated Suite V3 - Native nameplate visual settings store
--
-- 维护（2026-09-20，nameplate-mark-ratio-3）：
-- 1) 这里只保存用户希望写入的“绝对客户端显示值”，不保存运行时 CVar 当前值。
--    原因：ReloadAddon / ENTERED_WORLD 后当前值可能来自 system.cfg 或其它插件，若把
--    当前值当缩放基线反复相乘会出现 1.5x -> 2.25x 的累乘漂移。
-- 2) Native 写入 Authority 在独立文件，Store 不接触 X2Option；加载配置本身不能产生
--    客户端副作用，也不能因为打开设置页就改变头标/血条。
-- 3) schema1 为已发布兼容边界，本轮不升 schema：markerWidth/markerHeight/markerOffset 三个字段
--    继续保留原 canonical 形状。18.273 起 Native 只用 markerWidth/46 计算 name_tag_mark_size_ratio；
--    markerHeight 仍由百分比预设同步保存，markerOffset 仅作为旧配置兼容保留，不再写入无效 CVar。
--    这样旧用户存档指纹不会因为字段增删而触发 fence。
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local P = S.Persistence
S.Features = S.Features or {}
S.Features.NameplateVisuals = S.Features.NameplateVisuals or {}
local F = S.Features.NameplateVisuals
if type(P) ~= "table" then return end

F.StoreId = "v3.nameplate_visuals"
F.StoreSchema = 1
F.Defaults = {
    markerWidth = 46,
    markerHeight = 50,
    markerOffset = 10,
    markerFixedSize = true,
    hpWidth = 70,
    hpHeight = 7,
    bgHpWidth = 158,
    bgHpHeight = 38,
}
-- 维护：这些上下限是插件自己的安全 UI/配置预算，不宣称是 CryEngine 或 RU 客户端
-- 的硬限制。范围故意留有较大余量，同时阻止负尺寸、NaN、无穷等坏值进入 Native。
F.Limits = {
    markerWidth = { 20, 220 },
    markerHeight = { 20, 240 },
    markerOffset = { -80, 160 },
    hpWidth = { 30, 360 },
    hpHeight = { 2, 48 },
    bgHpWidth = { 60, 480 },
    bgHpHeight = { 8, 140 },
}
F.settings = F.settings or {}

local function FiniteInteger(value, minimum, maximum, fallback)
    local n = tonumber(value)
    if n == nil or n ~= n or n == math.huge or n == -math.huge then return fallback end
    n = n >= 0 and math.floor(n + 0.5) or math.ceil(n - 0.5)
    if n < minimum then n = minimum end
    if n > maximum then n = maximum end
    return n
end

function F:NormalizeSettings(value)
    value = type(value) == "table" and value or {}
    local out = {}
    for _, key in ipairs({ "markerWidth", "markerHeight", "markerOffset", "hpWidth", "hpHeight", "bgHpWidth", "bgHpHeight" }) do
        local range = self.Limits[key]
        out[key] = FiniteInteger(value[key], range[1], range[2], self.Defaults[key])
    end
    if value.markerFixedSize == nil then out.markerFixedSize = self.Defaults.markerFixedSize
    else out.markerFixedSize = value.markerFixedSize == true end
    return out
end

if P:GetStore(F.StoreId) == nil then
    local store, err = P:RegisterV3Store({
        id = F.StoreId,
        owner = "v3.nameplate_visuals",
        scope = P.Scope.Account,
        lifetime = P.Lifetime.Permanent,
        schemaVersion = F.StoreSchema,
        legacySchemaVersion = 0,
        key = P.V3KeyPrefix .. "nameplate_visuals",
        budget = { maxDepth = 3, maxNodes = 48, maxStringBytes = 256, maxEntriesPerTable = 16 },
        default = function() return F:NormalizeSettings(nil) end,
        get = function() return F:NormalizeSettings(F.settings) end,
        apply = function(value)
            F.settings = F:NormalizeSettings(value)
            return true
        end,
        migrate = function(value) return F:NormalizeSettings(value) end,
    })
    if store == nil then error(err or "nameplate visuals store registration failed") end
end

function F:EnsureStoreLoaded()
    local store = P:GetStore(self.StoreId)
    if store == nil then return false, "头顶显示设置 Store 不可用" end
    if store.writeFenced == true then
        self.settingsError = tostring(store.writeFenceReason or "设置写保护")
        return false, self.settingsError
    end
    if self.storeLoaded == true and store.loaded == true then return true end
    local ok, _, err = P:LoadStore(self.StoreId)
    if ok ~= true and ok ~= "empty" then
        self.settingsError = tostring(err or ok or "设置读取失败")
        return false, self.settingsError
    end
    if ok == "empty" then self.settings = self:NormalizeSettings(nil) end
    self.storeLoaded, self.settingsError = true, nil
    return true
end

function F:GetSettings()
    return self:NormalizeSettings(self.settings)
end

-- 维护：所有写入走 Persistence 的事务 + durable readback；Presentation 不允许直接改
-- F.settings，否则 UI 显示成功但 ReloadAddon 后回退会破坏用户升级兼容。
function F:CommitSettings(mutator, reason)
    local loaded, loadErr = self:EnsureStoreLoaded()
    if loaded ~= true then return false, loadErr end
    if type(mutator) ~= "function" then return false, "设置修改器无效" end
    return P:MutateStore(self.StoreId, function()
        local working = self:NormalizeSettings(self.settings)
        local ok, err = mutator(working)
        if ok == false then return false, err end
        self.settings = self:NormalizeSettings(working)
        return true
    end, { delayMs = 0, durable = true, reason = tostring(reason or "nameplate_visuals_settings") })
end
