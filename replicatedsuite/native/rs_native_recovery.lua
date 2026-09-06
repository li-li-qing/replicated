------------------------------------------------------------------------
-- Replicated Suite V3 - Bootstrap Recovery Entry Installer
-- Loaded immediately after the Native Foundation so later TOC failures still
-- leave minimal in-game recovery controls owned by Replicated Suite itself.
------------------------------------------------------------------------
if ReplicatedSuite == nil then return end
local S = ReplicatedSuite

if type(S.InstallBootstrapRecoveryEntry) == "function" then
    local callOk, installed, installErr = pcall(function() return S.InstallBootstrapRecoveryEntry() end)
    if callOk ~= true or installed ~= true then
        local detail = callOk == true and tostring(installErr or "installer returned false") or tostring(installed or "unknown")
        S.RecoveryEntryHealthy = false
        S.RecoveryEntryError = detail
        if type(S.SafeChat) == "function" then
            S.SafeChat("恢复入口安装失败：" .. detail, "error", "native")
        end
    end
end

-- Recovery Command Bar is intentionally installed independently from the R
-- launcher. If button input is broken but EditBox input remains healthy, the
-- user still has an in-game reload path and does not need to restart the client.
if type(S.InstallRecoveryCommandBar) == "function" then
    local callOk, installed, installErr = pcall(function() return S.InstallRecoveryCommandBar() end)
    if callOk ~= true or installed ~= true then
        local detail = callOk == true and tostring(installErr or "command installer returned false") or tostring(installed or "unknown")
        S.RecoveryCommandHealthy = false
        S.RecoveryCommandError = detail
        if type(S.SafeChat) == "function" then
            S.SafeChat("恢复命令栏安装失败：" .. detail, "error", "native")
        end
    end
end
