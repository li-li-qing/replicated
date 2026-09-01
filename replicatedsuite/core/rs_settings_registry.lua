------------------------------------------------------------------------
-- Replicated Suite - Settings Registry / Search Router
-- Suite Authority indexes settings; Module Authority still owns values.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
S.SettingsRegistry = { entries = {}, order = {} }
local R = S.SettingsRegistry

local function Normalize(value)
    return string.lower(tostring(value or ""))
end

function R:Register(def)
    if type(def) ~= "table" then return false end
    local id = tostring(def.Id or "")
    if id == "" or self.entries[id] ~= nil then return false end
    def.Id = id
    def.Title = tostring(def.Title or id)
    def.Keywords = tostring(def.Keywords or "")
    def.Category = tostring(def.Category or "常用")
    self.entries[id] = def
    self.order[#self.order + 1] = id
    return true
end

function R:RegisterModule(moduleId, title, keywords)
    return self:Register({
        Id = "module:" .. tostring(moduleId), Title = tostring(title),
        Keywords = tostring(keywords or ""), Category = "模块", ModuleId = tostring(moduleId),
        Open = function()
            if S.ModuleManager ~= nil then return S.ModuleManager:OpenSettings(moduleId) end
            return false
        end,
    })
end

function R:RegisterSetting(moduleId, settingId, title, keywords, open)
    moduleId = tostring(moduleId or "")
    settingId = tostring(settingId or "")
    if moduleId == "" or settingId == "" then return false end
    return self:Register({
        Id = "setting:" .. moduleId .. ":" .. settingId,
        Title = tostring(title or settingId),
        Keywords = tostring(keywords or ""), Category = "设置", ModuleId = moduleId,
        Open = function()
            if type(open) == "function" then
                local value = open()
                if value ~= nil then return value end
            end
            if S.ModuleManager ~= nil then return S.ModuleManager:OpenSettings(moduleId) end
            return false
        end,
    })
end

function R:Search(query, limit)
    query = Normalize(query)
    limit = math.max(1, math.floor(tonumber(limit) or 8))
    local result = {}
    if query == "" then return result end
    for _, id in ipairs(self.order) do
        local def = self.entries[id]
        local haystack = Normalize(table.concat({ def.Title or "", def.Keywords or "", def.Category or "", def.ModuleId or "" }, " "))
        if string.find(haystack, query, 1, true) ~= nil then
            result[#result + 1] = def
            if #result >= limit then break end
        end
    end
    return result
end

function R:Open(id)
    local def = self.entries[tostring(id or "")]
    if def == nil then return false end
    if type(def.Open) == "function" then
        local ok, value = xpcall(def.Open, S.SafeTraceback)
        return ok and value ~= false, ok and nil or value
    end
    if def.Page ~= nil and S.UIHostManager ~= nil and type(S.UIHostManager.OpenPage) == "function" then
        return S.UIHostManager:OpenPage(def.Page) == true
    end
    if def.ModuleId ~= nil and S.ModuleManager ~= nil then return S.ModuleManager:OpenSettings(def.ModuleId) end
    return false
end

-- Suite-native searchable settings. Professional settings are registered below
-- by module Id and remain discoverable even while their runtime is disabled.
local native = {
    {"suite:scale","界面缩放","缩放 大小 UI","设置","settings"},
    {"suite:font","全局字体","字体 字号 HUD","设置","settings"},
    {"suite:opacity","主面板透明度","透明度 背景","设置","settings"},
    {"suite:hud","HUD管理","悬浮窗 布局 位置 缩放 透明度 字体","HUD","hud"},
    {"suite:event","活动时间","活动 倒计时 鲸鱼 烛台 庭院 提醒 隐藏","生活","life_activity"},
    {"suite:trade","跑商货率","跑商 货率 材料 价格 拍卖 排序 自动刷新","生活","life_trade"},
    {"suite:bonds","债券居民板","债券 居民板 20 60 100 原大陆","生活","life_bond"},
    {"suite:tasks","任务追踪","日常 追踪 自定义 完成 未完成","生活","life_tasks"},
    {"suite:treasure","寻宝助手","藏宝图 坐标 距离 方向","生活","life_treasure"},
    {"suite:fishing","钓鱼辅助","钓鱼 按键 R Auto-R","生活","life_fishing"},
    {"suite:diagnostics","诊断","错误 API Capability Runtime 模块","诊断","diagnostics"},
}
for _, row in ipairs(native) do
    R:Register({ Id=row[1], Title=row[2], Keywords=row[3], Category=row[4], Page=row[5] })
end
