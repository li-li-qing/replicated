------------------------------------------------------------------------
-- Replicated Suite V3 - Bootstrap Recovery Entry Installer
-- Loaded immediately after the Native Foundation so later TOC failures still
-- leave one minimal in-game entry owned by Replicated Suite itself.
------------------------------------------------------------------------
if ReplicatedSuite == nil then return end
local S = ReplicatedSuite
if type(S.InstallBootstrapRecoveryEntry) == "function" then
    local ok, err = pcall(function() return S.InstallBootstrapRecoveryEntry() end)
    if ok ~= true and type(S.SafeChat) == "function" then
        S.SafeChat("恢复入口安装失败：" .. tostring(err or "unknown"), "error", "native")
    end
end
