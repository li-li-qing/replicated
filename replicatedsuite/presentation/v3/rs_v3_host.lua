------------------------------------------------------------------------
-- Replicated Suite · 应用宿主适配
-- 作者：Replicated
-- QQ群：1104129461
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local H = S.UIHostManager
local Shell = S.UIV3 and S.UIV3.Shell or nil
if type(H) ~= "table" or type(H.Register) ~= "function" or type(Shell) ~= "table" then return end

-- 热重载发现宿主已注册时仍须保留 V3 适配器；序列/诊断模块稍后加载，不能因为 HostManager 保留注册而丢失运行适配器。
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

-- 保留的 HostManager 注册已指向相同 Shell 契约；不重复注册，但须保留上方 S.UIV3Host。
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
