------------------------------------------------------------------------
-- Replicated Suite V3 - Healer Screen Projection Bridge (M1.16.0.18)
--
-- Narrow Feature-side Native observation used by Head Marker Presentation.
-- Presentation is not allowed to call X2Unit directly. This bridge performs
-- one side-effect-free world->screen query for an already-committed candidate
-- and owns no loop, cache, roster, health or Aura state.
------------------------------------------------------------------------
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
