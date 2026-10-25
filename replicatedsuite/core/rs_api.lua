-- Replicated Suite · 官方 API 调用边界
-- 作者：Replicated
-- QQ群：1104129461
-- 可选 API 先经过 Capability Registry；Call/Action 负责底层受保护调用。
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
    -- 调用前扣除额度；抛错或返回 false 也占用冷却，避免失败重试超过 RU 限频。
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

-- 全局函数（如 ConvertWorldToScreen）不传 _G 作 self；X2*/UI 方法仍显式传宿主。
function A:CallGlobalCapability(name, ...)
    local allowed, reason = self:IsCapabilityAllowed(name)
    if allowed ~= true then return false, nil, "capability blocked: " .. tostring(reason or name) end
    local info = S.ApiCapabilities ~= nil and type(S.ApiCapabilities.Get) == "function" and S.ApiCapabilities:Get(name) or nil
    local methodName = type(info) == "table" and tostring(info.Method or "") or ""
    local fn = methodName ~= "" and rawget(_G, methodName) or nil
    if type(fn) ~= "function" then return false, nil, "global capability unavailable: " .. tostring(name) end
    local paced, paceErr = self:ConsumeCapabilityCooldown(name)
    if paced ~= true then return false, nil, paceErr end
    -- Lua 5.1 的 pcall 可原样传入参数，包括中间和末尾的 nil，无需另建参数表或闭包。
    local ok, a, b, c, d = pcall(fn, ...)
    if not ok then return false, nil, tostring(a) end
    return true, a, nil, b, c, d
end

function A:Call(object, methodName, ...)
    if object==nil then return false,nil,"object unavailable" end
    local method=object[methodName]; if type(method)~="function" then return false,nil,methodName.." unavailable" end
    local ok,a,b,c,d=pcall(method,object,...)
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
    if v==nil or v~=v or v<=0 or v==math.huge then return nil end return v
end
function A:GetUiMetrics()
    -- UIParent:GetExtent() 返回逻辑尺寸；部分客户端的 GetScreenWidth 已缩放，再除缩放会把浮窗夹到屏幕外。
    local scale=UiNumber(UIParent,"GetUIScale") or UiNumber(UI,"GetUIScale") or 1
    if scale<=0 then scale=1 end

    -- 先排除无效 extent/scale，防止 NaN 绕过 Layout 夹紧。
    -- 来源只供诊断；screen 未必是物理像素，已知逻辑坐标不能再除 uiScale。
    local logicalW,logicalH=nil,nil
    local source = "uiparent"
    if UIParent~=nil and type(UIParent.GetExtent)=="function" then
        local ok,w,h=pcall(function() return UIParent:GetExtent() end)
        if ok then
            logicalW=tonumber(w); logicalH=tonumber(h)
            if logicalW~=nil and (logicalW<=0 or logicalW~=logicalW or logicalW==math.huge) then logicalW=nil end
            if logicalH~=nil and (logicalH<=0 or logicalH~=logicalH or logicalH==math.huge) then logicalH=nil end
        end
    end
    logicalW=logicalW or UiNumber(UIParent,"GetWidth")
    logicalH=logicalH or UiNumber(UIParent,"GetHeight")

    local screenW=UiNumber(UI,"GetScreenWidth") or UiNumber(UIParent,"GetScreenWidth")
    local screenH=UiNumber(UI,"GetScreenHeight") or UiNumber(UIParent,"GetScreenHeight")
    if logicalW==nil or logicalH==nil then source = (screenW and screenH) and "screen_fallback" or "bootstrap_fallback" end
    if logicalW==nil then logicalW=(screenW and screenW/scale) or 1024 end
    if logicalH==nil then logicalH=(screenH and screenH/scale) or 768 end
    screenW=screenW or logicalW*scale
    screenH=screenH or logicalH*scale
    return screenW,screenH,scale,logicalW,logicalH,{ source=source, ready=source=="uiparent" }
end

-- X2Input:GetMousePos（RU 2026-08-26 开放）只在交互事件中读取。
-- 不同 UI 缩放下可能返回逻辑坐标或物理像素，统一在此归一化。
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

    -- 优先保留已是逻辑单位的值；只有值超出逻辑视口但仍位于物理屏幕内时才除以缩放。
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

-- 不替换 UIParent 或其它插件的 Handler。RU 的 OnScale 权限与触发仍需实测；
-- 安装失败时由 Layout 报告，并在 UI_RELOADED、进入世界及创建/显示/重置时重新采样。
-- Stop 先废弃 epoch，防止迟到通知触发布局。
function A:StartUiMetricsNotifications(callback)
    if type(callback) ~= "function" then return false, "metrics_callback_required" end
    self:StopUiMetricsNotifications()
    local factory = S.NativeObjectFactory
    if type(factory) ~= "table" or type(factory.CreateWindow) ~= "function" then return false, "metrics_host_factory_unavailable" end
    local host = self.metricsHost
    if host == nil then
        host = factory:CreateWindow(S.PhysicalId("ui_metrics_host"), "UIParent", "")
        self.metricsHost = host
    end
    if host == nil or type(host.SetHandler) ~= "function" then return false, "metrics_host_unavailable" end
    if type(host.Show) == "function" then pcall(function() host:Show(false) end) end
    local epoch, generation = self.metricsEpoch, S.Generation
    local ok, result = pcall(function()
        return host:SetHandler("OnScale", function()
            if A.metricsEpoch ~= epoch or S.Generation ~= generation or A.metricsListening ~= true then return end
            callback("native_on_scale")
        end)
    end)
    self.metricsListening = ok and result ~= false
    -- Lua 的 true and nil or error 会恒选 error；成功必须显式返回 nil。
    if self.metricsListening then return true,nil end
    return false,"native_on_scale_unavailable"
end

function A:StopUiMetricsNotifications()
    self.metricsEpoch = (tonumber(self.metricsEpoch) or 0) + 1
    self.metricsListening = false
    if self.metricsHost ~= nil and type(self.metricsHost.ReleaseHandler) == "function" then
        pcall(function() self.metricsHost:ReleaseHandler("OnScale") end)
    end
    return true
end
