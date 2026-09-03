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

function A:IsCapabilityAllowed(name)
    if S.ApiCapabilities == nil or type(S.ApiCapabilities.IsAllowed) ~= "function" then
        return false, "capability registry unavailable"
    end
    return S.ApiCapabilities:IsAllowed(name)
end

function A:CallCapability(name, object, methodName, ...)
    local allowed, reason = self:IsCapabilityAllowed(name)
    if allowed ~= true then return false, nil, "capability blocked: " .. tostring(reason or name) end
    return self:Call(object, methodName, ...)
end

function A:ActionCapability(name, object, methodName, ...)
    local allowed, reason = self:IsCapabilityAllowed(name)
    if allowed ~= true then return false, "capability blocked: " .. tostring(reason or name) end
    return self:Action(object, methodName, ...)
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
function A:Validate()
    local required={{ADDON,"LoadData","ADDON:LoadData"},{ADDON,"SaveData","ADDON:SaveData"},{UIParent,"CreateWidget","UIParent:CreateWidget"}}
    for _,i in ipairs(required) do if i[1]==nil or type(i[1][i[2]])~="function" then return false,i[3].." unavailable" end end
    return true
end
