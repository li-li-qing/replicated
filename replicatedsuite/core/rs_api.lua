------------------------------------------------------------------------
-- Replicated Suite - Official API boundary
-- Optional game APIs use the central Capability Registry at feature boundaries.
-- Call/Action remain the low-level protected invocation primitives for hot paths
-- that already passed a capability gate.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S=ReplicatedSuite
S.Api={}
local A=S.Api
A.CapabilityCooldownContractVersion = 1
A.capabilityLastAttemptAt = {}

local function CapabilityCooldownInfo(name)
    if S.ApiCapabilities == nil or type(S.ApiCapabilities.Get) ~= "function" then return nil, 0 end
    local info = S.ApiCapabilities:Get(name)
    local cooldown = type(info) == "table" and math.max(0, tonumber(info.Cooldown) or 0) or 0
    return info, cooldown
end

function A:GetCapabilityCooldownState(name)
    local info, cooldown = CapabilityCooldownInfo(name)
    local key = type(info) == "table" and tostring(info.Name or name or "") or tostring(name or "")
    local now = type(S.NowMs) == "function" and math.max(0, tonumber(S.NowMs()) or 0) or 0
    local last = self.capabilityLastAttemptAt[key]
    local remaining = 0
    if cooldown > 0 and last ~= nil then remaining = math.max(0, cooldown - math.max(0, now - last)) end
    return { name = key, cooldownMs = cooldown, lastAttemptAt = last, remainingMs = remaining }
end

function A:ConsumeCapabilityCooldown(name)
    local info, cooldown = CapabilityCooldownInfo(name)
    if cooldown <= 0 then return true end
    if type(S.NowMs) ~= "function" then return false, "capability clock unavailable" end
    local now = math.max(0, tonumber(S.NowMs()) or 0)
    local key = type(info) == "table" and tostring(info.Name or name or "") or tostring(name or "")
    local last = self.capabilityLastAttemptAt[key]
    if last ~= nil then
        local elapsed = math.max(0, now - last)
        if elapsed < cooldown then return false, "capability cooldown active: " .. tostring(math.ceil(cooldown - elapsed)) .. "ms remaining" end
    end
    -- Consume before the native invocation. A thrown/false native call must not
    -- be spam-retried faster than the official RU contract permits.
    self.capabilityLastAttemptAt[key] = now
    return true
end

function A:IsCapabilityAllowed(name)
    if S.ApiCapabilities == nil or type(S.ApiCapabilities.IsAllowed) ~= "function" then
        return false, "capability registry unavailable"
    end
    return S.ApiCapabilities:IsAllowed(name)
end

function A:ResolveCapabilityHost(name, fallback)
    if fallback ~= nil then return fallback end
    local info = S.ApiCapabilities ~= nil and type(S.ApiCapabilities.Get) == "function" and S.ApiCapabilities:Get(name) or nil
    local namespace = type(info) == "table" and tostring(info.Namespace or "") or tostring(name or ""):match("^([^:]+):")
    if namespace == nil or namespace == "" then return nil end
    if namespace == "ADDON" then return ADDON end
    if namespace == "UI" then return UI end
    if namespace == "UIParent" then return UIParent end
    return rawget(_G, namespace)
end

function A:CallCapability(name, object, methodName, ...)
    local allowed, reason = self:IsCapabilityAllowed(name)
    if allowed ~= true then return false, nil, "capability blocked: " .. tostring(reason or name) end
    object = self:ResolveCapabilityHost(name, object)
    if object == nil then return false, nil, "capability host unavailable: " .. tostring(name) end
    local paced, paceErr = self:ConsumeCapabilityCooldown(name)
    if paced ~= true then return false, nil, paceErr end
    return self:Call(object, methodName, ...)
end

function A:ActionCapability(name, object, methodName, ...)
    local allowed, reason = self:IsCapabilityAllowed(name)
    if allowed ~= true then return false, "capability blocked: " .. tostring(reason or name) end
    object = self:ResolveCapabilityHost(name, object)
    if object == nil then return false, "capability host unavailable: " .. tostring(name) end
    local paced, paceErr = self:ConsumeCapabilityCooldown(name)
    if paced ~= true then return false, paceErr end
    return self:Action(object, methodName, ...)
end

-- Global-function capabilities (for example ConvertWorldToScreen) do not use
-- Lua method-call semantics and therefore must not pass _G as an implicit first
-- argument. Keep this as a separate primitive so ordinary X2*/UI object calls
-- retain the proven colon-style contract.
function A:CallGlobalCapability(name, ...)
    local allowed, reason = self:IsCapabilityAllowed(name)
    if allowed ~= true then return false, nil, "capability blocked: " .. tostring(reason or name) end
    local info = S.ApiCapabilities ~= nil and type(S.ApiCapabilities.Get) == "function" and S.ApiCapabilities:Get(name) or nil
    local methodName = type(info) == "table" and tostring(info.Method or "") or ""
    local fn = methodName ~= "" and rawget(_G, methodName) or nil
    if type(fn) ~= "function" then return false, nil, "global capability unavailable: " .. tostring(name) end
    local paced, paceErr = self:ConsumeCapabilityCooldown(name)
    if paced ~= true then return false, nil, paceErr end
    local args, argCount = { ... }, select("#", ...)
    local ok, a, b, c, d = pcall(function() return fn(unpack(args, 1, argCount)) end)
    if not ok then return false, nil, tostring(a) end
    return true, a, nil, b, c, d
end

function A:Call(object, methodName, ...)
    if object==nil then return false,nil,"object unavailable" end
    local method=object[methodName]; if type(method)~="function" then return false,nil,methodName.." unavailable" end
    local args={...}; local argCount=select("#", ...)
    local ok,a,b,c,d=pcall(function() return method(object,unpack(args,1,argCount)) end)
    if not ok then return false,nil,tostring(a) end
    return true,a,nil,b,c,d
end
function A:Action(object,methodName,...)
    local ok,value,err=self:Call(object,methodName,...); if not ok then return false,err end; if value==false then return false,methodName.." returned false" end; return true,value
end
function A:LoadData(key)
    local ok, value, err = self:CallCapability("ADDON:LoadData", ADDON, "LoadData", key)
    if not ok then return nil, err end
    return value, nil
end
function A:SaveData(key, value)
    return self:ActionCapability("ADDON:SaveData", ADDON, "SaveData", key, value)
end
function A:ClearData(key)
    return self:ActionCapability("ADDON:ClearData", ADDON, "ClearData", key)
end

local function UiNumber(host,name)
    if host==nil or type(host[name])~="function" then return nil end
    local ok,v=pcall(function() return host[name](host) end); v=ok and tonumber(v) or nil
    if v==nil or v~=v or v<=0 then return nil end return v
end
function A:GetUiMetrics()
    -- UIParent:GetExtent() is the reliable logical-coordinate Authority used
    -- by the user's existing Replicated Gear on RU ArcheRage.  GetScreenWidth
    -- may already be scaled on some client/UI-size combinations; dividing it
    -- blindly caused 1024x768 floating widgets to be clamped against the wrong
    -- space and appear off-screen.
    local scale=UiNumber(UIParent,"GetUIScale") or UiNumber(UI,"GetUIScale") or 1
    if scale<=0 then scale=1 end

    local logicalW,logicalH=nil,nil
    if UIParent~=nil and type(UIParent.GetExtent)=="function" then
        local ok,w,h=pcall(function() return UIParent:GetExtent() end)
        if ok then
            logicalW=tonumber(w); logicalH=tonumber(h)
            if logicalW~=nil and logicalW<=0 then logicalW=nil end
            if logicalH~=nil and logicalH<=0 then logicalH=nil end
        end
    end
    logicalW=logicalW or UiNumber(UIParent,"GetWidth")
    logicalH=logicalH or UiNumber(UIParent,"GetHeight")

    local screenW=UiNumber(UI,"GetScreenWidth") or UiNumber(UIParent,"GetScreenWidth")
    local screenH=UiNumber(UI,"GetScreenHeight") or UiNumber(UIParent,"GetScreenHeight")
    if logicalW==nil then logicalW=(screenW and screenW/scale) or 1024 end
    if logicalH==nil then logicalH=(screenH and screenH/scale) or 768 end
    screenW=screenW or logicalW*scale
    screenH=screenH or logicalH*scale
    return screenW,screenH,scale,logicalW,logicalH
end

-- Pointer coordinates are requested only by event-driven UI interactions such
-- as Tooltip OnEnter. ArcheRage RU officially enabled X2Input:GetMousePos on
-- 2026-08-26. The client may report either logical UI coordinates or physical
-- screen pixels depending on UI scale, so normalize conservatively here and
-- keep that ambiguity out of presentation code.
function A:GetMouseLogicalPosition()
    if X2Input == nil then return nil, nil, "X2Input unavailable" end
    local ok, first, err, second = self:CallCapability("X2Input:GetMousePos", X2Input, "GetMousePos")
    if ok ~= true then return nil, nil, err end

    local x, y
    if type(first) == "table" then
        x = tonumber(first.x or first[1])
        y = tonumber(first.y or first[2])
    else
        x = tonumber(first)
        y = tonumber(second)
    end
    if x == nil or y == nil or x ~= x or y ~= y then return nil, nil, "mouse position unavailable" end

    local screenW, screenH, scale, logicalW, logicalH = self:GetUiMetrics()
    scale = tonumber(scale) or 1
    logicalW, logicalH = tonumber(logicalW) or 1024, tonumber(logicalH) or 768
    screenW, screenH = tonumber(screenW) or logicalW * scale, tonumber(screenH) or logicalH * scale

    -- Prefer already-logical values. Only divide by scale when the values exceed
    -- the logical viewport while still fitting the physical screen bounds.
    if scale > 0 and scale ~= 1 and (x > logicalW + 2 or y > logicalH + 2)
        and x <= screenW + 2 and y <= screenH + 2 then
        x, y = x / scale, y / scale
    end
    return x, y, nil
end

function A:Validate()
    local required={{ADDON,"LoadData","ADDON:LoadData"},{ADDON,"SaveData","ADDON:SaveData"}}
    for _,i in ipairs(required) do if i[1]==nil or type(i[1][i[2]])~="function" then return false,i[3].." unavailable" end end
    if S.NativeCapabilities == nil or type(S.NativeCapabilities.Validate) ~= "function" then return false, "NativeCapabilities unavailable" end
    return S.NativeCapabilities:Validate()
end
