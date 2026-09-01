------------------------------------------------------------------------
-- Replicated Suite - Presentation Host Manager
--
-- Presentation is replaceable. Core/Services/Module adapters must not depend
-- on one concrete window/page implementation. Legacy UI and V3 UI register
-- independent hosts; Runtime and semantic navigation talk only to this layer.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite

S.UIHostManager = {
    version = 2,
    hosts = {},
    order = {},
    activeId = nil,
    defaultId = "v3",
    stats = {
        registered = 0, created = 0, opens = 0, closes = 0, switches = 0,
        navigations = 0, routeFailures = 0, routeFallbacks = 0, failures = 0,
    },
}
local H = S.UIHostManager

local function NormalizeId(value)
    local id = tostring(value or ""):lower():gsub("[^%w_%.%-]", "_"):gsub("_+", "_")
    id = id:gsub("^_+", ""):gsub("_+$", "")
    return id
end

local function NormalizeRoute(value)
    local route = tostring(value or ""):lower():gsub("[\r\n]+", "")
    route = route:gsub("[^%w_%.:%-/%_]", "_"):gsub("_+", "_")
    route = route:gsub("^[_/]+", ""):gsub("[_/]+$", "")
    return route
end

local function Emit(level, code, message, context)
    local d = S.DiagnosticsManager
    if type(d) == "table" and type(d.Emit) == "function" then
        d:Emit(level, "ui_host", code, message, context)
    end
end

local function Call(host, method, ...)
    local fn = host and host.spec and host.spec[method]
    if type(fn) ~= "function" then return true, nil end
    local args, count = { ... }, select("#", ...)
    local ok, a, b = xpcall(function() return fn(host.spec, unpack(args, 1, count)) end, S.SafeTraceback)
    if not ok then
        H.stats.failures = (tonumber(H.stats.failures) or 0) + 1
        host.lastError = tostring(a)
        Emit("error", "HOST_" .. string.upper(method) .. "_FAILED", "Presentation Host 调用失败", {
            host = host.id,
            method = method,
            error = host.lastError,
        })
        return false, a
    end
    return a ~= false, b
end

local function ValidateSpec(spec)
    local contractVersion = math.max(1, math.floor(tonumber(spec.contractVersion) or 1))
    if contractVersion >= 2 then
        for _, method in ipairs({ "create", "getWindow", "open", "close", "navigate" }) do
            if type(spec[method]) ~= "function" then return false, "V2 host requires " .. method .. "()" end
        end
    end
    return true, nil
end

function H:Register(id, spec)
    id = NormalizeId(id)
    if id == "" then return nil, "host id required" end
    if type(spec) ~= "table" then return nil, "host spec required" end
    if self.hosts[id] ~= nil then return nil, "duplicate host: " .. id end
    local valid, validationErr = ValidateSpec(spec)
    if valid ~= true then return nil, validationErr end

    local host = {
        id = id,
        name = tostring(spec.name or id),
        version = tostring(spec.version or "1"),
        contractVersion = math.max(1, math.floor(tonumber(spec.contractVersion) or 1)),
        spec = spec,
        created = false,
        available = spec.available ~= false,
        lastError = nil,
        lastRoute = nil,
    }
    self.hosts[id] = host
    self.order[#self.order + 1] = id
    table.sort(self.order)
    self.stats.registered = (tonumber(self.stats.registered) or 0) + 1
    if self.activeId == nil and id == tostring(self.defaultId or "v3") then self.activeId = id end
    return host
end

function H:Get(id)
    return self.hosts[NormalizeId(id)]
end

function H:IsRegistered(id)
    return self:Get(id) ~= nil
end

function H:SetDefault(id)
    local normalized = NormalizeId(id)
    if self.hosts[normalized] == nil then return false, "unknown host" end
    self.defaultId = normalized
    if self.activeId == nil then self.activeId = normalized end
    return true
end

function H:Ensure(id)
    local host = self:Get(id)
    if host == nil then return nil, "unknown host" end
    if host.available ~= true then return nil, "host unavailable" end
    if host.created == true then return host end

    local ok, err = Call(host, "create")
    if ok ~= true then return nil, err or "host create failed" end
    host.created = true
    host.lastError = nil
    self.stats.created = (tonumber(self.stats.created) or 0) + 1
    return host
end

function H:SetActive(id, closePrevious)
    local host, err = self:Ensure(id)
    if host == nil then return false, err end
    local previous = self.activeId and self.hosts[self.activeId] or nil
    if closePrevious ~= false and previous ~= nil and previous ~= host and previous.created == true then
        Call(previous, "close")
    end
    if self.activeId ~= host.id then self.stats.switches = (tonumber(self.stats.switches) or 0) + 1 end
    self.activeId = host.id
    return true
end

function H:GetActive()
    return self.activeId and self.hosts[self.activeId] or nil
end

function H:GetWindow(id)
    local host = self:Get(id or self.activeId)
    if host == nil or host.created ~= true then return nil end
    local fn = host.spec and host.spec.getWindow
    if type(fn) ~= "function" then return nil end
    local ok, value = pcall(fn, host.spec)
    return ok and value or nil
end

function H:Open(id)
    local target = id or self.activeId or self.defaultId
    local ok, err = self:SetActive(target, true)
    if not ok then return false, err end
    local host = self:GetActive()
    local result, callErr = Call(host, "open")
    if result then self.stats.opens = (tonumber(self.stats.opens) or 0) + 1 end
    return result, callErr
end

function H:Close(id)
    local host = self:Get(id or self.activeId)
    if host == nil or host.created ~= true then return true end
    local ok, err = Call(host, "close")
    if ok then self.stats.closes = (tonumber(self.stats.closes) or 0) + 1 end
    return ok, err
end

function H:Toggle(id)
    local target = id or self.activeId or self.defaultId
    local targetHost = self:Get(target)
    if targetHost == nil then return false, "unknown host" end
    if self.activeId ~= targetHost.id then
        local switched, switchErr = self:SetActive(targetHost.id, true)
        if switched ~= true then return false, switchErr end
    end
    local host, err = self:Ensure(targetHost.id)
    if host == nil then return false, err end
    if type(host.spec.toggle) == "function" then return Call(host, "toggle") end
    local window = self:GetWindow(host.id)
    if window ~= nil and type(window.IsVisible) == "function" then
        local ok, visible = pcall(function() return window:IsVisible() end)
        if ok and visible == true then return self:Close(host.id) end
    end
    return self:Open(host.id)
end

-- Semantic navigation Authority. Callers describe WHAT they want to open;
-- concrete hosts decide HOW that intent maps to their own pages/presenters.
-- A fallback host is never implicit: migration code must opt in explicitly so
-- V3 cannot silently leak back into Legacy presentation.
function H:Navigate(routeId, context, options)
    routeId = NormalizeRoute(routeId)
    if routeId == "" then return false, "route required" end
    context = type(context) == "table" and context or {}
    options = type(options) == "table" and options or {}

    local function TryHost(hostId, isFallback)
        local host, err = self:Ensure(hostId)
        if host == nil then return false, err end
        if type(host.spec.navigate) ~= "function" then return false, "host navigation unavailable" end
        local switched, switchErr = self:SetActive(host.id, options.closePrevious ~= false)
        if switched ~= true then return false, switchErr end
        -- Route ownership includes visibility. A settings route may open a
        -- standalone presenter without showing the host shell, while a normal
        -- page route may open the shell first. HostManager must not guess.
        -- Callers can still explicitly request shell opening for special flows.
        if options.openHost == true then
            local opened, openErr = Call(host, "open")
            if opened ~= true then return false, openErr or "host open failed" end
        end
        local ok, routeErr = Call(host, "navigate", routeId, context)
        if ok == true then
            host.lastRoute = routeId
            self.stats.navigations = (tonumber(self.stats.navigations) or 0) + 1
            if isFallback then self.stats.routeFallbacks = (tonumber(self.stats.routeFallbacks) or 0) + 1 end
            return true
        end
        return false, routeErr or "route rejected"
    end

    local target = NormalizeId(options.hostId or self.activeId or self.defaultId)
    local ok, err = TryHost(target, false)
    if ok == true then return true end

    local fallback = NormalizeId(options.fallbackHost)
    if fallback ~= "" and fallback ~= target then
        local fallbackOk, fallbackErr = TryHost(fallback, true)
        if fallbackOk == true then return true end
        err = fallbackErr or err
    end

    self.stats.routeFailures = (tonumber(self.stats.routeFailures) or 0) + 1
    Emit("warning", "HOST_ROUTE_FAILED", "Presentation route 无法打开", {
        route = routeId,
        host = target,
        fallback = fallback ~= "" and fallback or nil,
        error = tostring(err or "unknown"),
    })
    return false, err or "route failed"
end

function H:OpenPage(pageId, context, options)
    return self:Navigate("page:" .. NormalizeId(pageId), context, options)
end

function H:OpenSettings(moduleId, context, options)
    return self:Navigate("settings:" .. NormalizeId(moduleId), context, options)
end

function H:OpenProfessional(moduleId, section, options)
    return self:Navigate("professional:" .. NormalizeId(moduleId), { section = section }, options)
end

function H:HideAll(preserveEntry)
    for _, id in ipairs(self.order) do
        local host = self.hosts[id]
        if host ~= nil and host.created == true then
            if type(host.spec.hideAll) == "function" then
                local ok = xpcall(function() host.spec:hideAll(preserveEntry == true) end, S.SafeTraceback)
                if not ok then self.stats.failures = (tonumber(self.stats.failures) or 0) + 1 end
            else
                Call(host, "close")
            end
        end
    end
end

function H:ApplyResponsiveLayout(fromMetricsChange)
    local host = self:GetActive()
    if host == nil or host.created ~= true then return false, "active host unavailable" end
    local ok, err = Call(host, "applyLayout", fromMetricsChange == true)
    if ok ~= true then return false, err end
    local widgetHost = S.UIV3 and S.UIV3.WidgetHost or nil
    if widgetHost ~= nil and type(widgetHost.ApplyResponsiveLayout) == "function" then
        local widgetOk, widgetErr = widgetHost:ApplyResponsiveLayout(fromMetricsChange == true)
        if widgetOk ~= true then return false, widgetErr or "floating widget responsive layout failed" end
    end
    return true
end

function H:RefreshData(dirty)
    local host = self:GetActive()
    if host == nil or host.created ~= true then return false, "active host unavailable" end
    return Call(host, "refreshData", dirty)
end

function H:Describe()
    local rows = {}
    local contractV2, navigationReady = 0, 0
    for _, id in ipairs(self.order) do
        local host = self.hosts[id]
        if (tonumber(host.contractVersion) or 1) >= 2 then contractV2 = contractV2 + 1 end
        if type(host.spec.navigate) == "function" then navigationReady = navigationReady + 1 end
        rows[#rows + 1] = {
            id = host.id,
            name = host.name,
            version = host.version,
            contractVersion = host.contractVersion,
            active = host.id == self.activeId,
            created = host.created == true,
            available = host.available == true,
            navigationReady = type(host.spec.navigate) == "function",
            lastRoute = host.lastRoute,
            lastError = host.lastError,
        }
    end
    return {
        version = self.version,
        activeId = self.activeId,
        defaultId = self.defaultId,
        total = #rows,
        contractV2 = contractV2,
        navigationReady = navigationReady,
        rows = rows,
        stats = {
            registered = tonumber(self.stats.registered) or 0,
            created = tonumber(self.stats.created) or 0,
            opens = tonumber(self.stats.opens) or 0,
            closes = tonumber(self.stats.closes) or 0,
            switches = tonumber(self.stats.switches) or 0,
            navigations = tonumber(self.stats.navigations) or 0,
            routeFailures = tonumber(self.stats.routeFailures) or 0,
            routeFallbacks = tonumber(self.stats.routeFallbacks) or 0,
            failures = tonumber(self.stats.failures) or 0,
        },
    }
end
