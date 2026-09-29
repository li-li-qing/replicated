------------------------------------------------------------------------
-- Replicated Suite - Feature Health / Diagnostics Projection Registry
--
-- Phase 3 Batch G（2026-09-29，core-feature-decoupling-1）
--
-- 背景：core/rs_diagnostics.lua 原先按 id 直接读具体业务 Feature 的 health / 诊断投影
-- （例如取 BuffDisplay 的 health、取单位连线的 Diagnostics 表）。那是 CORE_FEATURE 债务
-- 在 core 里的最后一块，也是 §25.2 descriptor 里 RuntimeHealthProvider 字段的实际用途。
--
-- 现在改成：**Feature 自己把投影注册进来，Core 只按“用途名”取值** ——
-- Core 不再出现任何业务 Feature 的 id 或实现表访问。
--
-- 边界（刻意保持最小，不做成 DSL）：
--   * 只保存“去调用某个 Feature 的哪个投影”这一层间接。Get 每次**实时调用** provider，
--     不缓存结果 —— 与原先 Core 直接取健康投影的取值时机和新鲜度完全一致，
--     不引入第二份事实、不建立第二个诊断 Authority。
--   * provider 由 Feature 侧注册（写在 features/** 里），所以业务 Feature id 只出现在 Feature 目录。
--   * 注册可覆盖：同一 key 重复注册以最后一次为准；每次重载（Generation 变化）自然重建。
--   * provider 抛错时隔离为 nil 并计入 errors —— 单个模块的诊断投影坏掉不应该让整份
--     Snapshot 崩掉（这是相对旧行为的健壮性改进；正常路径的返回值不变）。
--     注意：这里只做“取值”，不做健康判定；判定仍归各 Feature 的 health 自身。
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite

local R = {
    ContractVersion = 1,
    generation = tonumber(S.Generation) or 0,
    providers = {},
    order = {},
    calls = 0,
    errors = 0,
    lastErrorKey = nil,
}
S.FeatureHealthProviders = R

local function Key(value)
    local text = tostring(value or "")
    if text == "" then return nil end
    return text
end

-- Feature 侧调用：Register("buff_display_health", function() ... end)
function R:Register(key, provider)
    key = Key(key)
    if key == nil or type(provider) ~= "function" then return false, "invalid_registration" end
    if self.providers[key] == nil then
        self.order[#self.order + 1] = key
        table.sort(self.order)
    end
    self.providers[key] = provider
    return true
end

-- Core 侧调用：Get("buff_display_health") —— 未注册或 provider 返回 nil 时都得到 nil。
function R:Get(key)
    local name = Key(key)
    local fn = name ~= nil and self.providers[name] or nil
    if type(fn) ~= "function" then return nil end
    self.calls = self.calls + 1
    local ok, value = pcall(fn)
    if ok ~= true then
        self.errors = self.errors + 1
        self.lastErrorKey = name
        return nil
    end
    return value
end

function R:Has(key)
    local name = Key(key)
    return name ~= nil and type(self.providers[name]) == "function"
end

function R:Describe()
    local keys = {}
    for _, name in ipairs(self.order) do keys[#keys + 1] = name end
    return {
        contractVersion = self.ContractVersion,
        registered = #keys,
        keys = keys,
        calls = self.calls,
        errors = self.errors,
        lastErrorKey = self.lastErrorKey,
    }
end
