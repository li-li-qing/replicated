------------------------------------------------------------------------
-- Replicated Suite V3 - Semantic Router
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local Features = S.FeatureRegistry
if type(Features) ~= "table" then return end

S.UIV3 = S.UIV3 or {}
S.UIV3.Router = {
    version = 1,
    routes = {},
    order = {},
    current = nil,
}
local R = S.UIV3.Router

local function Normalize(value)
    local route = tostring(value or ""):lower():gsub("[\r\n]+", "")
    route = route:gsub("[^%w_%.%-]", "_"):gsub("_+", "_")
    return route:gsub("^[%._%-]+", ""):gsub("[%._%-]+$", "")
end

function R:Register(route, spec)
    route = Normalize(route)
    if route == "" then return nil, "route required" end
    if self.routes[route] ~= nil then return nil, "duplicate route: " .. route end
    spec = type(spec) == "table" and spec or {}
    local row = {
        id = route,
        title = tostring(spec.title or route),
        category = tostring(spec.category or "system"),
        featureId = spec.featureId,
        order = tonumber(spec.order) or 100,
        group = tostring(spec.group or spec.category or "system"),
        groupOrder = tonumber(spec.groupOrder) or 100,
        groupItemOrder = tonumber(spec.groupItemOrder) or tonumber(spec.order) or 100,
        visible = spec.visible ~= false,
    }
    self.routes[route] = row
    self.order[#self.order + 1] = route
    return row
end

function R:Get(route) return self.routes[Normalize(route)] end
function R:Resolve(value)
    value = tostring(value or "")
    if value:match("^page:") then value = value:sub(6) end
    if value == "foundation:probe" then return { id = "foundation:probe", probe = true } end
    if value == "page:foundation" or value == "foundation" then value = "home" end
    return self:Get(value)
end

function R:List(category)
    local rows = {}
    for _, route in ipairs(self.order) do
        local row = self.routes[route]
        if row.visible and (category == nil or row.category == category) then rows[#rows + 1] = row end
    end
    table.sort(rows, function(a, b)
        if a.groupOrder ~= b.groupOrder then return a.groupOrder < b.groupOrder end
        if a.groupItemOrder ~= b.groupItemOrder then return a.groupItemOrder < b.groupItemOrder end
        if a.order ~= b.order then return a.order < b.order end
        return a.id < b.id
    end)
    return rows
end

for _, feature in ipairs(Features:List()) do
    local row, err = R:Register(feature.route, {
        title = feature.name,
        category = feature.category,
        featureId = feature.id,
        order = feature.order,
        group = feature.group,
        groupOrder = feature.groupOrder,
        groupItemOrder = feature.groupItemOrder,
    })
    if row == nil then error(err) end
end
