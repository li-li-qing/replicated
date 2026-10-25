-- Replicated Suite · 语义导航路由
-- 作者：Replicated
-- QQ群：1104129461
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local Features = S.FeatureRegistry
if type(Features) ~= "table" then return end

S.UIV3 = S.UIV3 or {}
S.UIV3.Router = {
    version = 2, -- v2 增加导航排序和标签投影。
    routes = {},
    order = {},
    current = nil,
}
local R = S.UIV3.Router
R.DevelopmentOrderContractVersion = 1 -- 此版本号用于检查导航排序接口，不表示 Feature 的完成度。

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
        title = tostring(spec.title or route), -- title 保留页面原名，navigationTitle 供左侧导航显示开发标签。
        -- 开发状态直接取 Registry，避免两处判定不一致。
        navigationTitle = tostring(spec.navigationTitle or spec.title or route),
        navigationIncomplete = spec.navigationIncomplete == true,
        category = tostring(spec.category or "system"),
        featureId = spec.featureId,
        order = tonumber(spec.order) or 100,
        group = tostring(spec.group or spec.category or "system"),
        groupOrder = tonumber(spec.groupOrder) or 100,
        groupItemOrder = tonumber(spec.groupItemOrder) or tonumber(spec.order) or 100,
        visible = spec.visible ~= false,
        navigationParentRoute = tostring(spec.navigationParentRoute or ""), -- 路由只透传父导航提示，PageHost 仍以当前 route 作为真实页面生命周期键。
    }
    self.routes[route] = row
    self.order[#self.order + 1] = route
    return row
end

-- 语义子页、收藏、旧启动路由也必须经 Registry 开放边界；不把普通隐藏导航当受限功能。
function R:Get(route)
    local row = self.routes[Normalize(route)]
    if row and row.featureId and not Features:IsAccessible(row.featureId) then return nil end
    return row
end
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
        -- 自定义导航/收藏/方案均消费同一可见目录，用户存档不能重新展示受限项。
        if row.visible and (not row.featureId or Features:IsAccessible(row.featureId)) and (category == nil or row.category == category) then rows[#rows + 1] = row end
    end
    table.sort(rows, function(a, b)
        if a.navigationIncomplete ~= b.navigationIncomplete then return a.navigationIncomplete ~= true end -- 左侧导航先列已完成功能；排序不影响路由注册和页面生命周期。
        if a.groupOrder ~= b.groupOrder then return a.groupOrder < b.groupOrder end
        if a.groupItemOrder ~= b.groupItemOrder then return a.groupItemOrder < b.groupItemOrder end
        if a.order ~= b.order then return a.order < b.order end
        return a.id < b.id
    end)
    return rows
end

for _, feature in ipairs(Features:List()) do
    local row, err = R:Register(feature.route, {
        title = feature.name, -- “未完成”只加在左侧导航名后；页面标题保留原名，开发状态沿用 Registry。
        navigationTitle = feature.name .. (feature.navigationIncomplete == true and "（未完成）" or ""),
        navigationIncomplete = feature.navigationIncomplete == true,
        category = feature.category,
        featureId = feature.id,
        order = feature.order,
        group = feature.group,
        groupOrder = feature.groupOrder,
        groupItemOrder = feature.groupItemOrder,
        visible = feature.navigationVisible ~= false,
        navigationParentRoute = feature.navigationParentRoute, -- 从 FeatureRegistry 复制展示归属，禁止在 Router 内硬编码团队中心等业务页面。
    })
    if row == nil then error(err) end
end
