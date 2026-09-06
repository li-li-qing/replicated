------------------------------------------------------------------------
-- Replicated Suite V3 - Craft Assistant Native-Surface Lifecycle Extension
--
-- Keeps native-window observation owned by tools_craft rather than Presentation.
-- The Feature Store persists only the user's autoSidecar preference; the native
-- window snapshot and sidecar session-dismiss state remain transient.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local Feature = S.Features and S.Features.tools_craft or nil
local P = S.Persistence
local Surface = S.Services and S.Services.CraftSurfaceV3 or nil
if type(Feature) ~= "table" or type(P) ~= "table" or type(Surface) ~= "table" then return end

local function PersistAuto(value)
    value = value == true
    if type(P.MutateStore) ~= "function" then return false, "制作台助手设置持久化事务不可用" end
    local ok, err = P:MutateStore(Feature.storeId, function() Feature.State.autoSidecar = value; return true end,
        { delayMs = 300, reason = "craft_auto_sidecar" })
    if ok ~= true then return false, tostring(err or "自动侧窗设置保存失败") end
    if Feature.enabled == true then
        if value then Surface:Start() else Surface:Stop("auto_sidecar_disabled") end
    end
    Feature:Refresh("craft_auto_sidecar")
    return true
end

local baseProjection = Feature.GetProjection
function Feature:GetProjection()
    local projection = baseProjection(self) or {}
    projection.autoSidecar = self.State.autoSidecar ~= false
    projection.craftSurface = Surface:GetSnapshot()
    return projection
end

function Feature.Commands:SetAutoSidecar(value) return PersistAuto(value == true) end

local baseEnable = Feature.Enable
function Feature:Enable(reason)
    local ok, err = baseEnable(self, reason)
    if ok ~= true then return ok, err end
    if self.State.autoSidecar ~= false then Surface:Start() end
    return true
end

local baseDisable = Feature.Disable
function Feature:Disable(reason)
    Surface:Stop("feature_disabled")
    return baseDisable(self, reason)
end

Feature.CraftSidecarContractVersion = 1
