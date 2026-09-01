------------------------------------------------------------------------
-- Replicated Suite - UI Information Architecture Catalog
--
-- Single Presentation Authority for main navigation, page labels and stable
-- aliases. Business/Runtime ownership remains in Services/ModuleManager.
-- Persisted page keys are intentionally unchanged for upgrade compatibility.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite

S.UICatalog = S.UICatalog or {}
local C = S.UICatalog
C.version = 1

C.Pages = {
    life          = { group="首页", title="今日综合工作台", navText="今日总览", iconKind="home" },

    team          = { group="战斗", title="团队辅助", navText="团队辅助", iconKind="team" },
    dps           = { group="战斗", title="伤害统计", navText="伤害统计", iconKind="dps" },
    healer        = { group="战斗", title="治疗辅助", navText="治疗辅助", iconKind="healer" },
    plates        = { group="战斗", title="BUFF显示 / 战斗信息", navText="BUFF显示", iconKind="buff" },
    gear          = { group="战斗", title="一键换装", navText="一键换装", iconKind="gear" },

    life_activity = { group="生活", title="活动 / 世界状态", navText="活动", iconKind="activity" },
    life_trade    = { group="生活", title="跑商", navText="跑商", iconKind="trade" },
    life_bond     = { group="生活", title="债券 / 居民板", navText="债券 / 居民板", iconKind="bond" },
    life_tasks    = { group="生活", title="任务追踪", navText="任务追踪", iconKind="task" },
    life_treasure = { group="生活", title="寻宝", navText="寻宝", iconKind="treasure" },
    life_fishing  = { group="生活", title="钓鱼", navText="钓鱼", iconKind="fishing" },

    bagorganizer  = { group="工具", title="整理背包", navText="整理背包", iconKind="bag" },
    quick         = { group="工具", title="实用工具", navText="实用工具", iconKind="quick" },

    hud           = { group="系统", title="悬浮窗管理", navText="悬浮窗管理", iconKind="hud" },
    modules       = { group="系统", title="功能开关 / 方案", navText="功能开关 / 方案", iconKind="modules" },
    settings      = { group="系统", title="全局设置", navText="全局设置", iconKind="settings" },
    diagnostics   = { group="系统", title="诊断与维护", navText="诊断与维护", iconKind="diagnostics" },
}

C.Groups = {
    { id="home", title="首页", pages={ "life" } },
    { id="combat", title="战斗", pages={ "team", "dps", "healer", "plates", "gear" } },
    { id="life", title="生活", pages={ "life_activity", "life_trade", "life_bond", "life_tasks", "life_treasure", "life_fishing" } },
    { id="tools", title="工具", pages={ "bagorganizer", "quick" } },
    { id="system", title="系统", pages={ "hud", "modules", "settings", "diagnostics" } },
}

-- Never remove old route keys from compatibility handling. They are normalized
-- only at the Presentation boundary; saved config/domain data is not rewritten.
C.Aliases = {
    activity = "life",
    target = "plates",
}

C.StartPages = {
    "life",
    "life_activity", "life_trade", "life_bond", "life_tasks", "life_treasure", "life_fishing",
    "team", "dps", "healer", "plates", "gear",
    "bagorganizer", "quick",
    "hud", "modules", "settings", "diagnostics",
    "last",
}

function C:NormalizePage(pageKey)
    local key = tostring(pageKey or "life")
    return self.Aliases[key] or key
end

function C:GetPage(pageKey)
    return self.Pages[self:NormalizePage(pageKey)]
end

function C:GetPageLabel(pageKey)
    if tostring(pageKey or "") == "last" then return "上次页面" end
    local page = self:GetPage(pageKey)
    return page and tostring(page.navText or page.title or pageKey) or tostring(pageKey or "")
end

function C:GetPageMeta()
    local result = {}
    for key, page in pairs(self.Pages) do
        result[key] = { group = page.group, title = page.title }
    end
    return result
end

function C:GetNavGroups()
    local result = {}
    for _, group in ipairs(self.Groups) do
        local entries = {}
        for _, pageKey in ipairs(group.pages or {}) do
            local page = self.Pages[pageKey]
            if page ~= nil then
                entries[#entries + 1] = {
                    key = pageKey,
                    text = tostring(page.navText or page.title or pageKey),
                    iconKind = page.iconKind,
                    kind = "page",
                    page = pageKey,
                }
            end
        end
        result[#result + 1] = { id = group.id, title = group.title, entries = entries }
    end
    return result
end

function C:GetStartPages()
    local result = {}
    for _, key in ipairs(self.StartPages) do result[#result + 1] = key end
    return result
end

function C:GetModuleCategoryLabel(category)
    local labels = { combat="战斗", life="生活", utility="工具", common="基础", internal="内部" }
    return labels[tostring(category or "")] or "其他"
end
