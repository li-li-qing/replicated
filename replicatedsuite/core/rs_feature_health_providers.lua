-- Replicated Suite · 功能健康提供器
-- 作者：Replicated
-- QQ群：1104129461
-- Feature 按用途名注册 provider，Core 每次实时读取；同 key 后注册者覆盖，重载后重建。
-- provider 异常时返回 nil 并计 errors，不能拖垮整份快照；健康判定仍由 Feature 负责。
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
