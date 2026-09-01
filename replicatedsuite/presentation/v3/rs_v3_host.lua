------------------------------------------------------------------------
-- Replicated Suite V3 - Presentation Host Adapter
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local H = S.UIHostManager
local Shell = S.UIV3 and S.UIV3.Shell or nil
if type(H) ~= "table" or type(H.Register) ~= "function" or type(Shell) ~= "table" then return end

-- Keep the V3 adapter available even when a hot-reload generation finds the
-- host already registered. Sequence/diagnostic modules load after this file and
-- must not lose their runtime adapter merely because HostManager preserved the
-- existing registration.
S.UIV3Host = S.UIV3Host or { version = 1, shell = Shell }
S.UIV3Host.version = 1
S.UIV3Host.shell = Shell
local V = S.UIV3Host

function V:Create() return self.shell:Create() end
function V:GetWindow() return self.shell.window end
function V:Open() return self.shell:Open() end
function V:Close() return self.shell:Close("host_close") end
function V:Toggle()
    local snapshot = self.shell:GetSnapshot()
    if snapshot.visible then return self:Close() end
    return self:Open()
end
function V:Navigate(routeId, context) return self.shell:Navigate(routeId, context) end
function V:ApplyLayout(fromMetricsChange) return self.shell:ApplyLayout(fromMetricsChange == true) end
function V:RefreshData(dirty) return self.shell:RefreshData(dirty) end
function V:HideAll() return self:Close() end

-- A preserved HostManager registration already points at the same Shell
-- contract. Do not register a duplicate, but keep S.UIV3Host above alive.
if H:IsRegistered("v3") then return end

local host, err = H:Register("v3", {
    contractVersion = 2,
    name = "Replicated Suite V3",
    version = tostring(S.BuildTag or "v3"),
    create = function() return V:Create() end,
    getWindow = function() return V:GetWindow() end,
    open = function() return V:Open() end,
    close = function() return V:Close() end,
    toggle = function() return V:Toggle() end,
    navigate = function(_, routeId, context) return V:Navigate(routeId, context) end,
    hideAll = function() return V:HideAll() end,
    applyLayout = function(_, fromMetricsChange) return V:ApplyLayout(fromMetricsChange) end,
    refreshData = function(_, dirty) return V:RefreshData(dirty) end,
})
if host == nil and S.DiagnosticsManager ~= nil and type(S.DiagnosticsManager.Error) == "function" then
    S.DiagnosticsManager:Error("ui_v3", "HOST_REGISTER_FAILED", "新版界面宿主注册失败", { error = tostring(err) })
end
