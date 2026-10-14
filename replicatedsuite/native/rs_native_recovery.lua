------------------------------------------------------------------------
-- Replicated Suite · 引导恢复入口
-- 作者：Replicated
-- QQ群：1104129461
--
-- 引导恢复入口在 Native Foundation 后立即安装，使后续 TOC 故障仍保留 Suite 自有最小游戏内恢复控件。
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

-- 恢复命令栏独立于 R 启动器安装；按钮输入失效而 EditBox 仍健康时，用户仍可在游戏内重载，无需重启客户端。
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
