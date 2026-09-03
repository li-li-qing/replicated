------------------------------------------------------------------------
-- Replicated Suite - Professional module sandbox
-- Author: Replicated
--
-- ArcheRage normally gives standalone addons separate Lua environments. Once
-- DPS/Gear/Healer/Plates are consolidated into one addon, their historical
-- file-level globals would otherwise collide. Each professional module gets a
-- persistent Lua 5.1 environment whose reads fall back to the Suite addon
-- environment while writes stay module-local. Only explicit namespace exports
-- are mirrored to the Suite root for lifecycle adapters.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
if S.PerformanceMonitor ~= nil and type(S.PerformanceMonitor.MarkStartup) == "function" then S.PerformanceMonitor:MarkStartup("professional_begin") end

local ROOT = _G
local previousSandbox = rawget(ROOT, "ReplicatedSuiteModuleSandbox")

-- A Suite hot reload is a new Authority generation. Reusing the previous
-- professional environments would keep deleted/renamed file globals alive and
-- can also expose a stale module export if the new generation fails halfway
-- through loading. The previous Runtime has already been quiesced by
-- replicatedsuite.lua before this file is reached, so it is safe to revoke the
-- old explicit exports and create clean per-module environments here.
if type(previousSandbox) == "table" and tonumber(previousSandbox.generation) ~= tonumber(S.Generation) then
    for _, allowed in pairs(type(previousSandbox.exports) == "table" and previousSandbox.exports or {}) do
        if type(allowed) == "table" then
            for exportName, enabled in pairs(allowed) do
                if enabled == true and tostring(exportName or "") ~= "" then
                    rawset(ROOT, tostring(exportName), nil)
                end
            end
        end
    end
    previousSandbox = nil
end

ReplicatedSuiteModuleSandbox = previousSandbox or {
    environments = {},
    exports = {},
    generation = S.Generation,
}
ReplicatedSuiteModuleSandbox.generation = S.Generation
local Sandbox = ReplicatedSuiteModuleSandbox

local function NormalizeId(value)
    return tostring(value or ""):lower():gsub("[^%w_%-]", "")
end

local function EnsureEnvironment(id, exportNames)
    id = NormalizeId(id)
    if id == "" then error("professional module sandbox id is required") end
    local env = Sandbox.environments[id]
    if env == nil then
        local allowed = {}
        env = {
            __RS_MODULE_ID = id,
            ReplicatedSuiteEmbedded = true,
        }
        setmetatable(env, {
            __index = ROOT,
            __newindex = function(target, key, value)
                rawset(target, key, value)
                if allowed[key] == true then rawset(ROOT, key, value) end
            end,
        })
        env._G = env
        env.__RS_EXPORTS = allowed
        Sandbox.environments[id] = env
        Sandbox.exports[id] = allowed
    end
    local allowed = rawget(env, "__RS_EXPORTS") or {}
    for _, name in ipairs(exportNames or {}) do
        name = tostring(name or "")
        if name ~= "" then
            allowed[name] = true
            local current = rawget(env, name)
            if current ~= nil then rawset(ROOT, name, current) end
        end
    end
    return env
end

function Sandbox:Enter(id, exportNames)
    local env = EnsureEnvironment(id, exportNames)

    -- ArcheRage builds have historically exposed Lua 5.1 setfenv, but the
    -- consolidated Suite must not make the whole professional layer depend on
    -- that single runtime detail.  Newer Lua runtimes represent a chunk's
    -- environment through the _ENV upvalue instead.  Support both forms while
    -- keeping the professional file isolated from the Suite root.
    if type(setfenv) == "function" then
        -- Enter() is called by the top-level file chunk, therefore stack level 2
        -- is exactly that chunk.
        setfenv(2, env)
        self.environmentMode = "setfenv"
        return env
    end

    if debug ~= nil and type(debug.getinfo) == "function" and type(debug.getupvalue) == "function" and type(debug.setupvalue) == "function" then
        local info = debug.getinfo(2, "f")
        local caller = info and info.func or nil
        if type(caller) == "function" then
            local index = 1
            while index <= 64 do
                local name = debug.getupvalue(caller, index)
                if name == nil then break end
                if name == "_ENV" then
                    debug.setupvalue(caller, index, env)
                    self.environmentMode = "_ENV"
                    return env
                end
                index = index + 1
            end
        end
    end

    error("professional module isolation unavailable: neither setfenv nor writable _ENV is exposed")
end

function Sandbox:Get(id)
    return self.environments[NormalizeId(id)]
end

function Sandbox:GetExport(id, name)
    id = NormalizeId(id)
    name = tostring(name or "")
    if id == "" or name == "" then return nil end

    local env = self:Get(id)
    local value = env ~= nil and rawget(env, name) or nil
    if value ~= nil then return value end

    -- Some ArcheRage loaders mirror an explicitly exported value into the addon
    -- root even when the chunk-local environment does not retain a raw slot.
    -- Only names declared in this module's export contract may use this fallback;
    -- arbitrary root globals are never exposed as professional Domain objects.
    local allowed = self.exports and self.exports[id] or nil
    if type(allowed) == "table" and allowed[name] == true then
        value = rawget(ROOT, name)
        if value ~= nil then
            if env ~= nil then rawset(env, name, value) end
            return value
        end
    end
    return nil
end

function Sandbox:DescribeExport(id, name)
    id = NormalizeId(id)
    name = tostring(name or "")
    local env = self:Get(id)
    local allowed = self.exports and self.exports[id] or nil
    return {
        moduleId = id,
        exportName = name,
        environmentMode = tostring(self.environmentMode or "unknown"),
        hasEnvironment = env ~= nil,
        allowed = type(allowed) == "table" and allowed[name] == true or false,
        localPresent = env ~= nil and rawget(env, name) ~= nil or false,
        rootPresent = rawget(ROOT, name) ~= nil,
    }
end
