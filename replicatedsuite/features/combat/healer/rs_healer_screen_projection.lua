-- Replicated Suite · 治疗助手屏幕投影
-- 作者：Replicated
-- QQ群：1104129461
-- Head Marker 使用的窄 Feature Native 观察桥。Presentation 禁止直接调用 X2Unit；对已提交候选只做一次无副作用 world→screen 查询，不拥有循环、缓存、名单、健康或 Aura 状态。
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
S.Features = S.Features or {}
S.Features.HealerScreenProjection = S.Features.HealerScreenProjection or {}
local B = S.Features.HealerScreenProjection

B.version = 1
B.metrics = B.metrics or { reads = 0, failures = 0, unavailable = 0 }

function B:ProjectUnit(unitToken)
    local projection = S.Services and S.Services.ScreenProjectionV3 or nil
    if type(projection) ~= "table" or type(projection.ProjectUnit) ~= "function" then
        self.metrics.unavailable = (tonumber(self.metrics.unavailable) or 0) + 1
        return nil, nil, nil, "screen_projection_service_unavailable"
    end
    self.metrics.reads = (tonumber(self.metrics.reads) or 0) + 1
    local x, y, z, err = projection:ProjectUnit(unitToken)
    if x == nil or y == nil then
        self.metrics.failures = (tonumber(self.metrics.failures) or 0) + 1
        return nil, nil, nil, err or "screen_projection_failed"
    end
    return x, y, z
end

function B:GetHealth()
    return {
        version = tonumber(self.version) or 1,
        reads = tonumber(self.metrics.reads) or 0,
        failures = tonumber(self.metrics.failures) or 0,
        unavailable = tonumber(self.metrics.unavailable) or 0,
    }
end

-- 只向 Foundation 提供实时能力诊断；ProjectUnit 契约由 rs_healer_aura_acceptance.lua 的 visual_consumer_contract 检查。
local providers = S.FeatureHealthProviders
if type(providers) == "table" then
    providers:Register("healer_screen_capable", function()
        local feature = S.Features and S.Features.HealerScreenProjection or nil
        return type(feature) == "table" and type(feature.ProjectUnit) == "function" or false
    end)
end
