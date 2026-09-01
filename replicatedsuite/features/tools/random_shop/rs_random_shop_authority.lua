------------------------------------------------------------------------
-- Replicated Suite V3 - Random Shop Read-only Authority
--
-- The current RU contract exposes only the refresh-count getter. Keep this
-- projection intentionally narrow: shop-open state, item rows and refresh
-- actions are not inferred from unavailable APIs.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
S.Features = S.Features or {}
S.Features.RandomShop = S.Features.RandomShop or {}
local F = S.Features.RandomShop
local A = { version = 1, revision = 0, snapshot = nil, metrics = { refreshes = 0, failures = 0 } }
F.Authority = A

local function Read()
    if S.Api == nil or type(S.Api.CallCapability) ~= "function" or X2Store == nil then return nil, "random shop API unavailable" end
    local ok, value, err = S.Api:CallCapability("X2Store:GetRandomShopStoreRefreshCount", X2Store, "GetRandomShopStoreRefreshCount")
    if ok ~= true then return nil, err or "random shop getter failed" end
    local count = tonumber(value)
    if count == nil or count < 0 or count ~= count then return nil, "random shop getter returned non-numeric data" end
    return math.floor(count + 0.5), nil
end

function A:Refresh(reason)
    local count, err = Read()
    self.revision = self.revision + 1
    self.metrics.refreshes = self.metrics.refreshes + 1
    if count == nil then self.metrics.failures = self.metrics.failures + 1 end
    self.snapshot = {
        revision = self.revision,
        available = count ~= nil,
        status = count ~= nil and "ready" or "unavailable",
        refreshCount = count,
        error = err,
        source = "X2Store:GetRandomShopStoreRefreshCount",
        reason = tostring(reason or "refresh"),
    }
    return true
end

function A:GetProjection()
    local p = self.snapshot or { revision = 0, available = false, status = "unavailable", refreshCount = nil }
    return { revision = p.revision, available = p.available, status = p.status, refreshCount = p.refreshCount, error = p.error, source = p.source, reason = p.reason }
end
function A:GetHealth()
    return { version = self.version, revision = self.revision, available = self.snapshot ~= nil and self.snapshot.available == true, refreshes = self.metrics.refreshes, failures = self.metrics.failures }
end
