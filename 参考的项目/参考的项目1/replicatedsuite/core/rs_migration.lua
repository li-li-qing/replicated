------------------------------------------------------------------------
-- Replicated Suite - Migration diagnostics
--
-- Official ArcheRage ADDON storage exposes LoadData(key)/SaveData(key, table)
-- only. There is no documented parameter for explicitly opening another
-- addon's storage namespace. Embedded professional Domains therefore probe the
-- same historical keys directly; if the client storage is globally keyed the
-- data is recovered automatically, while a client-private namespace cannot be
-- targeted safely without an official API. Old runtimes are never re-enabled
-- merely to migrate data.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
S.Migration = {}
local M = S.Migration

function M:Describe()
    local current = S.Constants and tonumber(S.Constants.SaveSchemaVersion) or 0
    local loaded = S.State and tonumber(S.State.lastLoadedSchema) or nil
    local suiteStatus = "new/default"
    if loaded ~= nil then
        if loaded < current then suiteStatus = "upgraded " .. tostring(loaded) .. "→" .. tostring(current)
        elseif loaded == current then suiteStatus = "current " .. tostring(current)
        else suiteStatus = "newer-source " .. tostring(loaded) end
    end
    return {
        suiteStatus = suiteStatus,
        legacyProfessionalKeyProbe = true,
        explicitCrossAddonNamespaceApi = false,
        legacyRuntimeRequired = false,
        summary = "旧专业模块沿用历史数据键直接探测；官方 LoadData 只有 key 参数，无法显式指定其他 Addon 命名空间。",
    }
end
