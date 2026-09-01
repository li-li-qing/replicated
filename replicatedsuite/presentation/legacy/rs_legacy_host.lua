------------------------------------------------------------------------
-- Replicated Suite - Legacy Presentation Host Adapter
--
-- This is the ONLY adapter that teaches Core UIHostManager how the historical
-- Suite presentation is constructed and navigated. New V3 presentation must
-- register a separate Host instead of importing these concrete pages.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local H = S.UIHostManager
if type(H) ~= "table" or type(H.Register) ~= "function" or H:IsRegistered("legacy") then return end

local function EnsureMainOpen()
    local window = S.UI and S.UI.windows and S.UI.windows.main or nil
    if window == nil then return false end
    if window:IsVisible() ~= true then
        if S.UI == nil or type(S.UI.ToggleMain) ~= "function" then return false end
        S.UI:ToggleMain()
    end
    return true
end

local function ShowPage(pageId, section)
    if EnsureMainOpen() ~= true then return false end
    if S.UI == nil or type(S.UI.ShowPage) ~= "function" then return false end
    if S.UI:ShowPage(pageId) ~= true then return false end
    if section ~= nil and S.ProfessionalPages ~= nil and type(S.ProfessionalPages.SetSection) == "function" then
        S.ProfessionalPages:SetSection(pageId, section)
    end
    return true
end

local function Navigate(_, routeId, context)
    routeId = tostring(routeId or "")
    context = type(context) == "table" and context or {}
    local kind, target = routeId:match("^([^:]+):(.+)$")
    if kind == "page" then return ShowPage(target, context.section) end
    if kind == "professional" then return ShowPage(target, context.section) end
    if kind == "settings" then
        if target == "tasks" then
            return ShowPage("life_tasks")
        elseif target == "bonds" then
            return ShowPage("life_bond")
        elseif target == "bag_organizer" or target == "bagorganizer" then
            return ShowPage("bagorganizer")
        elseif target == "team_utility" or target == "team" then
            return ShowPage("team")
        elseif target == "treasure" then
            return ShowPage("life_treasure")
        elseif target == "fishing" then
            return ShowPage("life_fishing")
        elseif target == "trade" then
            return ShowPage("life_trade")
        elseif target == "activities" or target == "activity" then
            return ShowPage("life_activity")
        elseif target == "dps" or target == "healer" or target == "gear" or target == "plates" then
            return ShowPage(target, context.section)
        end
        -- Built-ins without a feature-owned page stay in global settings.
        return ShowPage("settings")
    end
    return false
end

local host, err = H:Register("legacy", {
    contractVersion = 2,
    name = "Replicated Suite Legacy",
    version = tostring(S.BuildTag or "legacy"),
    create = function()
        S.MainWindow.Create()
        S.MainButton.Create()
        S.QuestDetailWindow.Create()
        S.DailyCustomWindow.Create()
        S.TradeDetailWindow.Create()
        S.UI:ApplyResponsiveLayout(false)
        return true
    end,
    getWindow = function()
        return S.UI and S.UI.windows and S.UI.windows.main or nil
    end,
    open = function()
        local window = S.UI and S.UI.windows and S.UI.windows.main or nil
        if window == nil then return false end
        if window:IsVisible() ~= true then S.UI:ToggleMain() end
        return true
    end,
    close = function()
        local window = S.UI and S.UI.windows and S.UI.windows.main or nil
        if window ~= nil and window:IsVisible() == true then S.UI:ToggleMain() end
        return true
    end,
    toggle = function()
        if S.UI == nil or type(S.UI.ToggleMain) ~= "function" then return false end
        S.UI:ToggleMain()
        return true
    end,
    navigate = Navigate,
    hideAll = function(_, preserveEntry)
        if S.UI ~= nil and type(S.UI.HideAll) == "function" then S.UI:HideAll(preserveEntry == true) end
        return true
    end,
    applyLayout = function(_, fromMetricsChange)
        if S.UI ~= nil and type(S.UI.ApplyResponsiveLayout) == "function" then S.UI:ApplyResponsiveLayout(fromMetricsChange == true) end
        return true
    end,
    refreshData = function(_, dirty)
        if S.UI ~= nil and type(S.UI.RefreshData) == "function" then S.UI:RefreshData(dirty) end
        return true
    end,
})

if host == nil then
    S.BootError = "legacy_host_register: " .. tostring(err or "unknown")
    return
end
H.defaultId = "legacy"
H.activeId = H.activeId or "legacy"
