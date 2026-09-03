------------------------------------------------------------------------
-- Replicated Suite - Professional module status/control service
-- Author: Replicated
--
-- Direct in-addon control surface. There is no addon discovery, Content-ID
-- proxy, load request, or ReplicatedIntegration bridge in the consolidated
-- architecture.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
S.Services = S.Services or {}
S.Services.Professional = { started = false }
local P = S.Services.Professional
local ORDER = { "dps", "healer", "gear", "plates" }

local function BuildSignature(data)
    local parts = {}
    for _, id in ipairs(ORDER) do
        local detail = data.details[id] or {}
        parts[#parts + 1] = table.concat({
            id,
            detail.enabled == true and "1" or "0",
            tostring(detail.state or ""),
            tostring(detail.lastError or ""),
            tostring(detail.scopeMode or ""),
            detail.running == true and "1" or "0",
        }, "|")
    end
    return table.concat(parts, ";")
end

function P:Refresh()
    local data = { details = {} }
    for _, id in ipairs(ORDER) do
        local detail = S.ModuleManager and S.ModuleManager:Describe(id) or nil
        data[id] = detail ~= nil and detail.enabled == true
        data.details[id] = detail or { id=id, state="Unavailable", enabled=false, lastError="模块未注册" }
    end
    local signature = BuildSignature(data)
    S.State.data.combat = data
    if signature ~= self.lastSignature then
        self.lastSignature = signature
        S.State:MarkDirty("combat")
    end
    return data
end

function P:SetEnabled(id, enabled)
    if S.ModuleManager == nil then return false, "module manager unavailable" end
    local ok, err = S.ModuleManager:SetEnabled(id, enabled == true)
    self:Refresh()
    return ok, err
end

function P:Open(id)
    if S.ModuleManager == nil then return false, "module manager unavailable" end
    local ok, err = S.ModuleManager:OpenSettings(id)
    self:Refresh()
    return ok, err
end

function P:Start()
    if self.started == true then return true end
    self.started = true
    self:Refresh()
    if S.Scheduler ~= nil then
        S.Scheduler:AddTask("professional_status", 1000, function() P:Refresh() end, false, self, "P5")
    end
    return true
end

function P:Stop()
    self.started = false
    if S.Scheduler ~= nil then S.Scheduler:RemoveOwner(self) end
    return true
end
