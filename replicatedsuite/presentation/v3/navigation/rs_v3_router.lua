------------------------------------------------------------------------
-- Replicated Suite V3 - Semantic Router
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local Features = S.FeatureRegistry
if type(Features) ~= "table" then return end

S.UIV3 = S.UIV3 or {}
S.UIV3.Router = {
    version = 2, -- 中文维护注释：v2 仅增加开发态导航排序/标签投影；route identity、PageHost 生命周期和 Feature Authority 完全不变。
    routes = {},
    order = {},
    current = nil,
}
local R = S.UIV3.Router
R.DevelopmentOrderContractVersion = 1 -- 中文维护注释：运行时门禁可验证“完成在上/未完成在下”的 Router 契约仍存在；该版本不代表 Feature 完成度本身。

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
        title = tostring(spec.title or route), -- 中文维护注释：title 保持页面语义原名，避免“未完成”开发标签污染页面标题、团队子页或其它 Router Consumer。
        navigationTitle = tostring(spec.navigationTitle or spec.title or route), -- 中文维护注释：navigationTitle 只供左侧 Shell 展示；开发标签不得改 FeatureRegistry.name 或任何持久化键。
        navigationIncomplete = spec.navigationIncomplete == true, -- 中文维护注释：Router 只消费 Registry 已判定的开发态布尔值，不在 Presentation 重复解析 status/readiness，避免双 Authority。
        category = tostring(spec.category or "system"),
        featureId = spec.featureId,
        order = tonumber(spec.order) or 100,
        group = tostring(spec.group or spec.category or "system"),
        groupOrder = tonumber(spec.groupOrder) or 100,
        groupItemOrder = tonumber(spec.groupItemOrder) or tonumber(spec.order) or 100,
        visible = spec.visible ~= false,
        navigationParentRoute = tostring(spec.navigationParentRoute or ""), -- 中文维护注释：路由只透传父导航提示，PageHost 仍以当前 route 作为真实页面生命周期键。
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
        if a.navigationIncomplete ~= b.navigationIncomplete then return a.navigationIncomplete ~= true end -- 中文维护注释：同一分类先展示已完成功能，再展示开发中功能；只重排左侧展示，不改变 route 注册顺序或 Feature 生命周期。
        if a.groupOrder ~= b.groupOrder then return a.groupOrder < b.groupOrder end
        if a.groupItemOrder ~= b.groupItemOrder then return a.groupItemOrder < b.groupItemOrder end
        if a.order ~= b.order then return a.order < b.order end
        return a.id < b.id
    end)
    return rows
end

for _, feature in ipairs(Features:List()) do
    local row, err = R:Register(feature.route, {
        title = feature.name, -- 中文维护注释：页面语义标题继续使用原 Feature 名称，不附加开发标签。
        navigationTitle = feature.name .. (feature.navigationIncomplete == true and "（未完成）" or ""), -- 中文维护注释：用户要求“未完成”只显示在左侧选项卡名称后；完成 Feature 保持原名，配置/route/id 不变。
        navigationIncomplete = feature.navigationIncomplete == true, -- 中文维护注释：透传 Registry 的唯一开发态结果，Router 排序与 Shell 标签共享同一事实。
        category = feature.category,
        featureId = feature.id,
        order = feature.order,
        group = feature.group,
        groupOrder = feature.groupOrder,
        groupItemOrder = feature.groupItemOrder,
        visible = feature.navigationVisible ~= false,
        navigationParentRoute = feature.navigationParentRoute, -- 中文维护注释：从 FeatureRegistry 复制展示归属，禁止在 Router 内硬编码团队中心等业务页面。
    })
    if row == nil then error(err) end
end
